#!/usr/bin/env bash
# Persistent fan-out tests. Files, Git, flock, hashing and concurrent/crashing
# shell processes are real. HTTP replies and selected I/O failures are fixtures.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MODULE="${DISPATCH_TEST_MODULE:-$ROOT/src/dispatch.sh}"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/cases"
export PATH="$WORK/bin:$PATH" DSR_GH_TOKEN=fixture-token
export DISPATCH_RETRY_DELAY=0 DISPATCH_MAX_RETRIES=2 DISPATCH_MAX_WAIT=0 DISPATCH_TIMEOUT=2
unset DISPATCH_STATE_DIR DRY_RUN
cat > "$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -uo pipefail
cat > /dev/null
url="${*: -1}"; body='' headers='' output=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-binary) body="${2#@}"; shift 2 ;;
        --dump-header) headers="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) shift ;;
    esac
done
repo="${url#https://api.github.com/repos/}"; repo="${repo%/dispatches}"
jq -c --arg repo "$repo" '.+{destination:$repo}' "$body" >> "$DP_CASE/calls.jsonl"
cp "$body" "$DP_CASE/${repo//\//_}.json"
if [[ "${DP_MODE:-}" == delay ]]; then sleep 0.15; fi
code=204 extra='' rc=0
if [[ "$repo" == owner/b ]]; then
    case "${DP_MODE:-}" in
        reject) code=422 ;;
        uncertain) code=000; rc=28 ;;
        cooldown) code=429; extra=$'Retry-After: 86400\r\n' ;;
        unknown-cooldown) code=429; extra=$'Retry-After: Wed, 21 Oct 2030 07:28:00 GMT\r\n' ;;
        elapsed) code=429; extra=$'Retry-After: 0\r\n' ;;
    esac
fi
if [[ "${DP_MODE:-}" == mutate ]]; then
    for file in "$DSR_STATE_DIR"/dispatch/*/state.json; do printf ' ' >> "$file"; done
fi
printf 'HTTP/2 %s\r\n%s\r\n' "$code" "$extra" > "$headers"
printf '{}' > "$output"
printf '%s' "$code"
exit "$rc"
CURL
chmod +x "$WORK/bin/curl"
# shellcheck source=/dev/null
source "$MODULE"
PIN=1111111111111111111111111111111111111111
checks=0 failures=0 CASE='' status=0 STATE=''
check() {
    local label="$1"; shift; checks=$((checks+1))
    if "$@" > "$WORK/check.out" 2>&1; then printf 'ok %s - %s\n' "$checks" "$label"
    else printf 'not ok %s - %s\n' "$checks" "$label"; cat "$WORK/check.out"; failures=$((failures+1)); fi
}
new_case() {
    CASE="$WORK/cases/$1"; mkdir "$CASE"
    export DP_CASE="$CASE" DSR_STATE_DIR="$CASE/state" DSR_GH_TOKEN=fixture-token
    unset DP_MODE DRY_RUN
    : > "$CASE/calls.jsonl"
}
capture() { status=0; "$@" > "$CASE/out" 2> "$CASE/err" || status=$?; }
release() { dispatch_release tool v1.0.0 --sha "$PIN" --source-repo owner/source --repos owner/a,owner/b "$@"; }
state_path() { find "$DSR_STATE_DIR" -name state.json -type f -print | head -1; }
count() { wc -l < "$CASE/calls.jsonl"; }
without_auth() (
    unset DSR_GH_TOKEN GITHUB_TOKEN GH_TOKEN
    gh() { return 1; }; secrets_get_gh_token() { return 1; }
    "$@"
)

new_case complete
capture release
check 'fresh release fan-out succeeds' test "$status" -eq 0
check 'both destinations receive exactly one request' test "$(count)" -eq 2
STATE=$(state_path)
check 'structured completion includes both accepted outcomes' jq -e '.status=="accepted" and (.results|length)==2 and all(.results[];.outcome=="accepted")' "$CASE/out"
check 'outbox persists source and full request plan' jq -e '.plan.source_repo=="owner/source" and (.plan.requests|length)==2' "$STATE"
check 'request carries stable receiver deduplication key' jq -e '.client_payload.delivery_id|test("^[0-9a-f]{64}$")' "$CASE/owner_a.json"
check 'each destination has a distinct delivery key' jq -e -s '.[0].client_payload.delivery_id!=.[1].client_payload.delivery_id' "$CASE/owner_a.json" "$CASE/owner_b.json"
check 'accepted evidence was preceded by a sending intent' jq -e 'all(.deliveries[];.history[0].sequence==1 and .history[0].receipt.http_status=="204")' "$STATE"
check 'outbox file permissions are private' test "$(stat -c %a "$STATE")" = 600
cp "$STATE" "$CASE/state.before"
inode=$(stat -c %i "$STATE")
capture without_auth release
check 'complete retry needs no credentials' test "$status" -eq 0
check 'complete retry sends nothing' test "$(count)" -eq 2
check 'complete retry preserves state bytes' cmp -s "$STATE" "$CASE/state.before"
check 'complete retry preserves state inode' test "$(stat -c %i "$STATE")" = "$inode"
capture without_auth release --status
check 'status is available without credentials' test "$status" -eq 0
check 'status is read-only' cmp -s "$STATE" "$CASE/state.before"

new_case rejected
export DP_MODE=reject
capture release
check 'one rejected destination leaves release incomplete' test "$status" -eq 1
STATE=$(state_path)
cp "$CASE/owner_b.json" "$CASE/b.before"
check 'partial outcome is durably retained' jq -e '[.deliveries[].history[-1].outcome]==["accepted","rejected"]' "$STATE"
unset DP_MODE
capture release
check 'retry recovers only definitively rejected work' test "$status" -eq 0
check 'retry does not replay accepted target' test "$(count)" -eq 3
check 'retry retains identical request bytes' cmp -s "$CASE/b.before" "$CASE/owner_b.json"
check 'retry history distinguishes first and second invocation' jq -e '[.deliveries[].history|length]==[1,2] and .deliveries[1].history[1].resend_uncertain==false' "$STATE"

new_case uncertain
export DP_MODE=uncertain
capture release
check 'lost acknowledgement remains an uncertain failure' test "$status" -eq 8
STATE=$(state_path)
cp "$CASE/owner_b.json" "$CASE/b.before"
unset DP_MODE
capture release
check 'ordinary restart does not replay uncertain POST' test "$(count)" -eq 2
check 'ordinary restart stays nonzero for uncertain delivery' test "$status" -eq 8
capture release --retry-uncertain
check 'explicit uncertain retry can recover' test "$status" -eq 0
check 'explicit uncertain retry sends only the uncertain target' test "$(count)" -eq 3
check 'explicit retry retains receiver delivery ID and exact payload' cmp -s "$CASE/b.before" "$CASE/owner_b.json"
check 'explicit uncertain retry is recorded in history' jq -e '.deliveries[1].history[1].resend_uncertain==true' "$STATE"

for mode in cooldown unknown-cooldown; do
    new_case "$mode"; export DP_MODE="$mode"
    capture release
    check "$mode returns incomplete" test "$status" -ne 0
    before=$(count); unset DP_MODE
    capture release
    check "$mode survives process restart without early replay" test "$(count)" -eq "$before"
    check "$mode remains explicit in status" jq -e '.results[1].outcome=="rate_limited"' "$CASE/out"
done
new_case elapsed
export DP_MODE=elapsed
capture release
before=$(count); unset DP_MODE
capture release
check 'elapsed cooldown permits safe retry' test "$status" -eq 0
check 'elapsed cooldown retries just the rejected target' test "$(count)" -eq "$((before+1))"

new_case plan-conflict
export DP_MODE=reject
capture release
STATE=$(state_path); cp "$STATE" "$CASE/state.before"; before=$(count)
unset DP_MODE
capture dispatch_release tool v1.0.0 --sha "$PIN" --source-repo owner/source --repos owner/a
check 'retry cannot silently omit an unfinished target' test "$status" -eq 2
capture dispatch_release tool v1.0.0 --sha "$PIN" --source-repo owner/source --repos owner/a,owner/b,owner/c
check 'retry cannot silently add destinations' test "$status" -eq 2
capture dispatch_release tool v1.0.0 --sha 2222222222222222222222222222222222222222 --source-repo owner/source --repos owner/a,owner/b
check 'changed commit conflicts with same release identity' test "$status" -eq 2
check 'all plan conflicts fail before dispatch' test "$(count)" -eq "$before"
check 'conflicting retries preserve original outbox' cmp -s "$STATE" "$CASE/state.before"
capture dispatch_release tool v1.0.0 --sha "$PIN" --source-repo OWNER/SOURCE --repos Owner/B,owner/A,owner/b
check 'normalized destination ordering still resumes' test "$status" -eq 0
check 'normalized retry dispatches only missing accepted acknowledgement' test "$(count)" -eq "$((before+1))"

new_case corrupted-state
export DP_MODE=reject
capture release
STATE=$(state_path); cp "$STATE" "$CASE/state.before"; before=$(count)
unset DP_MODE
for filter in '.deliveries[1].history[0].receipt.http_status="204"' '.deliveries[0].history[0].request_sha256=("0"*64)' '.deliveries[1].history[0].sequence=9' '.deliveries[0].history[0].receipt.exit_code=7' '.deliveries[0].history[0].receipt.repo="owner/other"' '.deliveries[1].history[0].resend_uncertain=true' '.deliveries += [.deliveries[0]]'; do
    jq "$filter" "$CASE/state.before" > "$STATE"
    capture release
    check "invalid state rejected: $filter" test "$status" -eq 2
    check 'invalid state never causes a partial resend' test "$(count)" -eq "$before"
done
cat "$CASE/state.before" "$CASE/state.before" > "$STATE"
capture release
check 'multi-document state rejected' test "$status" -eq 2
printf '{broken' > "$STATE"
capture release
check 'truncated state rejected without replacing it' test "$status" -eq 2
check 'truncated state is retained for diagnosis' grep -F '{broken' "$STATE"

new_case no-auth
capture without_auth release
check 'missing credentials leave a dependency error' test "$status" -eq 3
check 'missing credentials send no requests' test "$(count)" -eq 0
STATE=$(state_path)
check 'missing credentials do not mark pending work as uncertain' jq -e 'all(.deliveries[];.history==[])' "$STATE"
capture release
check 'adding credentials resumes initial plan' test "$status" -eq 0

new_case no-state
capture release --status
check 'unknown outbox inspection is not fake success' test "$status" -eq 4
check 'unknown outbox inspection creates no state directory' test ! -e "$DSR_STATE_DIR"
capture without_auth release --dry-run
check 'dry-run does not require credentials' test "$status" -eq 0
check 'dry-run does not create an outbox' test ! -e "$DSR_STATE_DIR"

new_case intent-write-failure
mv() {
    local src="${*: -2:1}"
    if [[ "$src" == */state.* ]] && jq -e 'any(.deliveries[];.history[-1].outcome=="sending")' "$src" >/dev/null 2>&1; then return 19; fi
    command mv "$@"
}
capture release
check 'failure to persist intent stops before POST' test "$(count)" -eq 0
check 'intent storage failure propagates' test "$status" -ne 0
unset -f mv
capture release
check 'unsent intent failure is safely retryable' test "$status" -eq 0

new_case acknowledgement-write-failure
mv() {
    local src="${*: -2:1}"
    if [[ "$src" == */state.* ]] && jq -e 'any(.deliveries[];.history[-1].outcome=="accepted")' "$src" >/dev/null 2>&1; then return 19; fi
    command mv "$@"
}
capture release
check 'failure to persist acknowledgement remains failure' test "$status" -ne 0
check 'ack storage failure happened after exactly one POST' test "$(count)" -eq 1
STATE=$(state_path)
check 'unrecorded acknowledgement leaves sending evidence' jq -e '.deliveries[0].history[-1].outcome=="sending"' "$STATE"
unset -f mv
capture release
check 'unrecorded acknowledgement is not replayed on restart' test "$(count)" -eq 2
check 'restart can send other unsent destinations while retaining uncertainty' jq -e '[.results[].outcome]==["uncertain","accepted"]' "$CASE/out"
capture release --retry-uncertain
check 'explicit reconciliation retry completes all targets' test "$status" -eq 0
check 'explicit retry only revisits the uncertain target' test "$(count)" -eq 3

new_case plan-write-failure
ln() { return 19; }
capture release
check 'failed initial state publication blocks every POST' test "$(count)" -eq 0
check 'failed initial state publication returns failure' test "$status" -ne 0
unset -f ln

new_case mutation
export DP_MODE=mutate
capture release
check 'external state mutation during POST prevents success' test "$status" -eq 2
check 'external state mutation stops later destinations' test "$(count)" -eq 1
STATE=$(state_path)
check 'external state mutation is not silently overwritten' jq -e '.deliveries[0].history[-1].outcome=="sending"' "$STATE"

new_case invalid-receipt
_dp_deliver() { printf '{}'; return 0; }
capture release
check 'false-success adapter becomes uncertainty not acceptance' test "$status" -eq 8
STATE=$(state_path)
check 'false-success adapter cannot create accepted evidence' jq -e 'all(.deliveries[];.history[-1].outcome=="uncertain")' "$STATE"
# Restore the module rather than duplicating the production function in tests.
source "$MODULE"

new_case filesystem
capture release
STATE=$(state_path)
cp "$STATE" "$CASE/real-state.json"
mv "$STATE" "$CASE/saved-state.json"
ln -s "$CASE/real-state.json" "$STATE"
before=$(count)
capture release
check 'linked outbox file is rejected' test "$status" -eq 2
check 'linked outbox cannot cause deliveries' test "$(count)" -eq "$before"

new_case crash
# Inject an actual worker SIGKILL immediately after the atomic sending-state
# rename. Its lock is released by the kernel; the persisted intent must survive.
cat > "$CASE/crash.sh" <<'CRASH'
#!/usr/bin/env bash
set -uo pipefail
source "$1"
mv() {
    local src="${*: -2:1}" sending=false parent
    if [[ "$src" == */state.* ]] && jq -e 'any(.deliveries[];.history[-1].outcome=="sending")' "$src" >/dev/null 2>&1; then sending=true; fi
    command mv "$@" || return $?
    if [[ "$sending" == true ]]; then
        parent=$(ps -o ppid= -p "$BASHPID") || return 1
        kill -KILL "$parent"
    fi
}
dispatch_release tool v1.0.0 --sha 1111111111111111111111111111111111111111 --source-repo owner/source --repos owner/a,owner/b
CRASH
capture bash "$CASE/crash.sh" "$MODULE"
check 'actual writer crash returns nonzero' test "$status" -ne 0
check 'writer crashed before its POST' test "$(count)" -eq 0
STATE=$(state_path)
check 'sending intent survives process death' jq -e '.deliveries[0].history[-1].outcome=="sending"' "$STATE"
capture release
check 'kernel releases crashed writer lock without manual lock removal' test "$status" -eq 8
check 'restart does not replay crashed ambiguous work' test "$(count)" -eq 1
capture release --retry-uncertain
check 'explicit retry recovers crashed worker plan' test "$status" -eq 0
check 'recovered crash has exactly the requested additional POST' test "$(count)" -eq 2

new_case concurrent
export DP_MODE=delay
pids=()
for i in 1 2 3 4 5 6; do
    bash "$MODULE" release tool v1.0.0 --sha "$PIN" --source-repo owner/source --repos owner/a,owner/b > "$CASE/worker-$i.out" 2> "$CASE/worker-$i.err" &
    pids+=("$!")
done
succeeded=0
for pid in "${pids[@]}"; do if wait "$pid"; then succeeded=$((succeeded+1)); fi; done
check 'at least one competing release sender completes' test "$succeeded" -ge 1
check 'concurrent processes never duplicate acknowledged destinations' test "$(count)" -eq 2
capture without_auth release
check 'concurrent completion remains resumable without credentials' test "$status" -eq 0
STATE=$(state_path)
check 'concurrent state contains exactly one accepted attempt per target' jq -e 'all(.deliveries[];(.history|length)==1 and .history[0].outcome=="accepted")' "$STATE"

printf '\nDispatch outbox checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
