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
        auth-like-transport) code=000; rc=3 ;;
        cooldown) code=429; extra=$'Retry-After: 86400\r\n' ;;
        unknown-cooldown) code=429; extra=$'Retry-After: Wed, 21 Oct 2030 07:28:00 GMT\r\n' ;;
        elapsed) code=429; extra=$'Retry-After: 0\r\n' ;;
        stall) sleep 4 ;;
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
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
[[ "$*" == 'auth token --hostname github.com' ]] || exit 9
if [[ "${DP_STDIN_CONSUMER:-}" == auth ]]; then
    cat >> "$DP_CASE/auth-stdin" || exit 9
fi
printf 'lookup\n' >> "$DP_CASE/auth-lookups"
lookups=$(wc -l < "$DP_CASE/auth-lookups")
if (( lookups == ${DP_AUTH_FAIL_AT:-0} )); then exit 1; fi
if (( lookups == ${DP_AUTH_STALL_AT:-0} )); then sleep 4; fi
printf '%s' fixture-token
GH
chmod +x "$WORK/bin/curl" "$WORK/bin/gh"
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
    unset DP_MODE DP_AUTH_FAIL_AT DP_AUTH_STALL_AT DP_PREPARE_FAIL DP_STDIN_CONSUMER DRY_RUN
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

# Auth lookup is an executable boundary. A counter survives the real nested
# subshells so failure can occur after intent publication, before any POST.
with_rotating_auth() (
    unset DSR_GH_TOKEN GITHUB_TOKEN GH_TOKEN
    unset -f gh secrets_get_gh_token
    "$@"
)

stdin_consuming_guard() {
    printf '%s\n' "$1" >> "$DP_CASE/guard-lookups"
    cat >> "$DP_CASE/guard-stdin"
}

stdin_six_release() {
    if [[ "$DP_STDIN_CONSUMER" == auth ]]; then
        with_rotating_auth release --repos "$stdin_six_repos"
    else
        _dp_config || return $?
        _dp_release_outbox "$stdin_six_plan" "$DSR_STATE_DIR/dispatch" \
            false false stdin_consuming_guard
    fi
}

# Captured from the unchanged default plan at 4008703. Retained outboxes must
# remain readable without changing request hashes or receiver delivery IDs.
new_case default-compatibility
legacy_payload='{"tool":"tool","version":"v1.0.0","sha":"1111111111111111111111111111111111111111","run_id":"tool-v1.0.0"}'
legacy_plan=$(_dp_release_plan owner/source owner/a "$legacy_payload")
check 'default request plan retains its previously published bytes' test "$(_dp_digest_text "$legacy_plan")" = 82a19ee88fab614615f32f5b942d493d18d4f19185d18d516aa7ae13b62106e9
check 'default outbox identity retains its exact previous encoding' test "$(_dp_outbox_identity "$legacy_plan")" = '{"run_id":"tool-v1.0.0","source_repo":"owner/source","tool":"tool","version":"v1.0.0"}'
check 'default plans do not acquire a release-ID field' jq -e 'has("release_id")|not' <<< "$legacy_plan"

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

# Authentication and guard descendants deliberately read the coordinator's
# stdin. Every planned destination must still get its own real HTTP attempt,
# including destinations after a definitive failure and on exact-plan resume.
stdin_six_repos=owner/a,owner/b,owner/c,owner/d,owner/e,owner/f
stdin_six_destinations='["owner/a","owner/b","owner/c","owner/d","owner/e","owner/f"]'
stdin_six_plan=$(_dp_release_plan owner/source "$(_dp_repos "$stdin_six_repos")" "$legacy_payload")
for stdin_consumer in auth guard; do
    for stdin_scenario in complete reject; do
        new_case "six-stdin-$stdin_consumer-$stdin_scenario"
        export DP_STDIN_CONSUMER="$stdin_consumer"
        stdin_rejected=false stdin_expected_rc=0 stdin_accepted=6 stdin_final_posts=6
        if [[ "$stdin_scenario" == reject ]]; then
            export DP_MODE=reject
            stdin_rejected=true stdin_expected_rc=1 stdin_accepted=5 stdin_final_posts=7
        fi
        capture stdin_six_release
        check "$stdin_consumer/$stdin_scenario preserves the aggregate outcome" \
            test "$status" -eq "$stdin_expected_rc"
        check "$stdin_consumer/$stdin_scenario dispatches all six destinations exactly once" \
            jq -es --argjson expected "$stdin_six_destinations" \
            'map(.destination) == $expected' "$CASE/calls.jsonl"
        STATE=$(state_path)
        check "$stdin_consumer/$stdin_scenario records only actual attempts and acknowledgements" \
            jq -e --argjson rejected "$stdin_rejected" '
                (.deliveries | length) == 6 and all(.deliveries[];
                    (.history | length) == 1 and .history[0].receipt.attempts == 1 and
                    .history[0].receipt.repo == .repo and
                    .history[0].outcome == (if $rejected and .repo == "owner/b" then "rejected" else "accepted" end) and
                    .history[0].receipt.exit_code == (if $rejected and .repo == "owner/b" then 7 else 0 end))
            ' "$STATE"
        check "$stdin_consumer/$stdin_scenario summary retains all attempted destinations" \
            jq -e --argjson accepted "$stdin_accepted" '
                (.results | length) == 6 and
                ([.results[] | select(.outcome == "accepted")] | length) == $accepted and
                all(.results[]; .invocations == 1 and .receipt.attempts == 1)
            ' "$CASE/out"
        if [[ "$stdin_consumer" == auth ]]; then
            check "$stdin_consumer/$stdin_scenario exercises every real token lookup" \
                test "$(wc -l < "$CASE/auth-lookups")" -eq 18
        else
            check "$stdin_consumer/$stdin_scenario exercises both guards for every POST" \
                test "$(wc -l < "$CASE/guard-lookups")" -eq 12
        fi
        stdin_accepted_before=$(jq -Sc '[.deliveries[] | select(.repo != "owner/b")]' "$STATE")
        unset DP_MODE
        capture stdin_six_release
        check "$stdin_consumer/$stdin_scenario exact-plan resume completes" test "$status" -eq 0
        check "$stdin_consumer/$stdin_scenario resume never duplicates accepted destinations" \
            test "$(count)" -eq "$stdin_final_posts"
        check "$stdin_consumer/$stdin_scenario accepted peers retain identical evidence" \
            test "$(jq -Sc '[.deliveries[] | select(.repo != "owner/b")]' "$STATE")" = "$stdin_accepted_before"
        check "$stdin_consumer/$stdin_scenario history records only the necessary retry" \
            jq -e --argjson rejected "$stdin_rejected" '
                (.deliveries | length) == 6 and all(.deliveries[];
                    (.history | length) == (if $rejected and .repo == "owner/b" then 2 else 1 end) and
                    .history[-1].outcome == "accepted" and
                    .history[-1].receipt.attempts == 1 and
                    .history[-1].receipt.exit_code == 0 and
                    .history[-1].resend_uncertain == false)
            ' "$STATE"
        check "$stdin_consumer/$stdin_scenario resumed summary reflects six actual acceptances" \
            jq -e '.status == "accepted" and .exit_code == 0 and
                (.results | length) == 6 and all(.results[];
                    .outcome == "accepted" and .receipt.http_status == "204")' "$CASE/out"
    done
done

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

new_case custom-event
export DP_MODE=uncertain
capture release --event dsr_release
check 'custom release event retains lost-acknowledgement failure' test "$status" -eq 8
STATE=$(state_path)
cp "$CASE/owner_b.json" "$CASE/b.before"
check 'custom event reaches every HTTP request unchanged' jq -e -s 'length==2 and all(.[];.event_type=="dsr_release")' "$CASE/calls.jsonl"
check 'custom event is bound to every saved receipt' jq -e 'all(.deliveries[].history[];.receipt.event_type=="dsr_release")' "$STATE"
unset DP_MODE
capture release --event dsr_release
check 'custom event restart does not replay uncertain work' test "$status" -eq 8
check 'custom event restart preserves acknowledged destinations' test "$(count)" -eq 2
capture release --event dsr_release --retry-uncertain
check 'custom event intentional retry completes the outbox' test "$status" -eq 0
check 'custom event intentional retry sends only uncertain work' test "$(count)" -eq 3
check 'custom event intentional retry uses the exact saved request bytes' cmp -s "$CASE/b.before" "$CASE/owner_b.json"
cp "$STATE" "$CASE/state.before"
capture release --event renamed-event
check 'changing an event conflicts with the original invocation' test "$status" -eq 2
check 'changing an event cannot cause duplicate delivery' test "$(count)" -eq 3
check 'changing an event preserves the original outbox bytes' cmp -s "$STATE" "$CASE/state.before"

new_case custom-event-guard
guard_plan=$(_dp_release_plan owner/source $'owner/a\nowner/b' "$legacy_payload" release-ready)
custom_guard() {
    printf '%s\n' "$2" >> "$CASE/guards"
    [[ "$2" == release-ready ]] && jq -e '.event_type=="release-ready"' <<< "$3" >/dev/null
}
export DP_MODE=elapsed
capture _dp_release_outbox "$guard_plan" "$DSR_STATE_DIR/dispatch" false false custom_guard
check 'rate-limited custom event remains incomplete' test "$status" -eq 1
check 'guards receive the saved custom event before sends and each rate-limit retry' test "$(wc -l < "$CASE/guards")" -eq 5
check 'custom event guard never receives the standalone default' test "$(sort -u "$CASE/guards")" = release-ready
check 'rate-limited custom event retains its receipt event' jq -e 'all(.results[].receipt;.event_type=="release-ready")' "$CASE/out"
unset -f custom_guard

new_case release-id-conflicts
release_plan=$(_dp_release_plan owner/source $'owner/a\nowner/b' "$legacy_payload" dsr_release 73)
capture _dp_release_outbox "$release_plan" "$DSR_STATE_DIR/dispatch" false false
check 'GitHub release-bound outbox can deliver its complete plan' test "$status" -eq 0
STATE=$(state_path); cp "$STATE" "$CASE/state.before"; before=$(count)
check 'GitHub release ID is retained as a safe numeric value' jq -e '.plan.release_id==73' "$STATE"
check 'release identity contains only normalized source and immutable release ID' test "$(_dp_outbox_identity "$release_plan")" = '{"release_id":73,"source_repo":"owner/source"}'
upper_plan=$(jq -c '.source_repo="OWNER/SOURCE"' <<< "$release_plan")
check 'release identity normalizes source repository case' test "$(_dp_outbox_identity "$upper_plan")" = "$(_dp_outbox_identity "$release_plan")"
for filter in '.tool="alias"' '.version="1.0.0"' '.run_id="different-invocation"' '.sha=("2"*40)' '.extra="changed"'; do
    changed_payload=$(jq -c "$filter" <<< "$legacy_payload")
    changed_plan=$(_dp_release_plan owner/source $'owner/a\nowner/b' "$changed_payload" dsr_release 73)
    capture _dp_release_outbox "$changed_plan" "$DSR_STATE_DIR/dispatch" false false
    check "same GitHub release rejects payload drift: $filter" test "$status" -eq 2
    check 'release payload drift never opens another delivery namespace' test "$(find "$DSR_STATE_DIR" -name state.json -type f | wc -l)" -eq 1
done
changed_plan=$(_dp_release_plan owner/source $'owner/a\nowner/b' "$legacy_payload" changed-event 73)
capture _dp_release_outbox "$changed_plan" "$DSR_STATE_DIR/dispatch" false false
check 'same GitHub release rejects event drift' test "$status" -eq 2
changed_plan=$(_dp_release_plan owner/source owner/a "$legacy_payload" dsr_release 73)
capture _dp_release_outbox "$changed_plan" "$DSR_STATE_DIR/dispatch" false false
check 'same GitHub release rejects destination drift' test "$status" -eq 2
check 'all release-bound plan conflicts stop before a POST' test "$(count)" -eq "$before"
check 'release-bound plan conflicts preserve the retained state' cmp -s "$STATE" "$CASE/state.before"

new_case invalid-release-id
for release_id in '' 0 -1 01 1.0 1e3 true 9007199254740992 999999999999999999999; do
    capture _dp_release_plan owner/source owner/a "$legacy_payload" dsr_release "$release_id"
    check "unsafe release ID is refused before plan creation: $release_id" test "$status" -eq 4
done
for release_id in 1 9007199254740991; do
    capture _dp_release_plan owner/source owner/a "$legacy_payload" dsr_release "$release_id"
    check "safe release ID boundary is accepted: $release_id" test "$status" -eq 0
    check 'safe release ID survives exact identity encoding' test "$(_dp_outbox_identity "$(cat "$CASE/out")")" = "{\"release_id\":$release_id,\"source_repo\":\"owner/source\"}"
done
for value in null '"73"' false 0 -1 1.5 9007199254740992; do
    malformed_plan=$(jq -c --argjson value "$value" '.release_id=$value' <<< "$legacy_plan")
    capture _dp_release_outbox "$malformed_plan" "$DSR_STATE_DIR/dispatch" false false
    check "malformed retained release ID fails closed: $value" test "$status" -eq 4
done
check 'invalid release identities never create outbox state' test ! -e "$DSR_STATE_DIR"
check 'invalid release identities never reach transport' test "$(count)" -eq 0

new_case recovery-state-loss
capture _dp_release_outbox "$release_plan" "$DSR_STATE_DIR/dispatch" false false
check 'recovery fixture starts with an accepted release outbox' test "$status" -eq 0
STATE=$(state_path); before=$(count)
capture without_auth _dp_release_outbox "$release_plan" "$DSR_STATE_DIR/dispatch" false false '' true
check 'existing accepted recovery needs neither credentials nor another POST' test "$status,$(count)" = "0,$before"
# Preserve the original instead of deleting it; recovery must still observe
# the absent authoritative pathname after taking its exclusive outbox lock.
mv "$STATE" "$CASE/retained-state.json"
capture _dp_release_outbox "$release_plan" "$DSR_STATE_DIR/dispatch" false false '' true
check 'recovery refuses an outbox lost before locking' test "$status" -eq 2
check 'recovery never recreates missing state as a new fan-out' test ! -e "$STATE"
check 'recovery of missing state sends no repeated events' test "$(count)" -eq "$before"
capture _dp_release_outbox "$release_plan" "$DSR_STATE_DIR/dispatch" false false '' maybe
check 'invalid recovery mode is rejected' test "$status" -eq 4

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
for filter in '.deliveries[1].history[0].receipt.http_status="204"' '.deliveries[0].history[0].request_sha256=("0"*64)' '.deliveries[1].history[0].sequence=9' '.deliveries[0].history[0].receipt.exit_code=7' '.deliveries[0].history[0].receipt.repo="owner/other"' '.deliveries[0].history[0].receipt.event_type="different-event"' '.deliveries[1].history[0].resend_uncertain=true' '.deliveries += [.deliveries[0]]'; do
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

for lookup in 2 3; do
    new_case "auth-after-intent-$lookup"
    export DP_AUTH_FAIL_AT="$lookup"
    capture with_rotating_auth release --repos owner/a
    check "auth lookup $lookup keeps the dependency exit" test "$status" -eq 3
    check "auth lookup $lookup starts no HTTP request" test "$(count)" -eq 0
    STATE=$(state_path)
    check "auth lookup $lookup records known unsent work" jq -e \
        '.deliveries[0].history[0] | .outcome=="blocked" and .receipt.attempts==0 and
         .receipt.exit_code==3 and .receipt.http_status==null' "$STATE"
    unset DP_AUTH_FAIL_AT
    capture with_rotating_auth release --repos owner/a
    check "auth lookup $lookup resumes without uncertain authorization" test "$status" -eq 0
    check "auth lookup $lookup recovery sends exactly one request" test "$(count)" -eq 1
    check "auth lookup $lookup preserves the zero-attempt refusal" jq -e \
        '.deliveries[0].history | length==2 and .[0].receipt.attempts==0 and
         .[1].receipt.attempts==1 and .[1].outcome=="accepted" and
         .[1].resend_uncertain==false' "$STATE"
done

for lookup in 1 2 3; do
    new_case "auth-deadline-$lookup"
    export DP_AUTH_STALL_AT="$lookup"
    started=$SECONDS
    DISPATCH_TIMEOUT=1 capture with_rotating_auth release --repos owner/a
    elapsed=$((SECONDS-started))
    check "auth deadline $lookup returns within its bound" test "$elapsed" -lt 4
    check "auth deadline $lookup preserves the dependency error" test "$status" -eq 3
    check "auth deadline $lookup starts no POST" test "$(count)" -eq 0
    STATE=$(state_path)
    if [[ "$lookup" == 1 ]]; then
        check 'preflight timeout leaves the outbox pending' jq -e \
            '.deliveries[0].history==[]' "$STATE"
    else
        check "auth deadline $lookup records a known-unsent intent" jq -e \
            '.deliveries[0].history[-1] | .outcome=="blocked" and
             .receipt.attempts==0 and .receipt.exit_code==3 and .receipt.http_status==null' "$STATE"
    fi
    unset DP_AUTH_STALL_AT
    capture with_rotating_auth release --repos owner/a
    check "auth deadline $lookup releases the lock and permits ordinary retry" test "$status" -eq 0
    check "auth deadline $lookup recovery sends exactly one POST" test "$(count)" -eq 1
    check "auth deadline $lookup needs no uncertain resend authorization" jq -e \
        '.deliveries[0].history[-1] | .outcome=="accepted" and .resend_uncertain==false' "$STATE"
done

new_case transport-deadline
export DP_MODE=stall
DISPATCH_TIMEOUT=1 capture release
check 'transport deadline preserves delivery uncertainty' test "$status" -eq 8
check 'transport deadline attempts each destination once' test "$(count)" -eq 2
STATE=$(state_path)
accepted_before=$(jq -Sc '.deliveries[0]' "$STATE")
check 'transport deadline preserves the accepted peer and attempted receipt' jq -e \
    '[.deliveries[].history[-1].outcome]==["accepted","uncertain"] and
     .deliveries[1].history[-1].receipt.attempts==1' "$STATE"
unset DP_MODE
capture release
check 'transport deadline can be inspected after releasing custody' test "$status" -eq 8
check 'ordinary restart does not replay a timed-out POST' test "$(count)" -eq 2
capture release --retry-uncertain
check 'explicit recovery retries the timed-out destination' test "$status" -eq 0
check 'explicit recovery does not resend accepted work' test "$(count)" -eq 3
check 'accepted peer evidence survives deadline and recovery' test "$(jq -Sc '.deliveries[0]' "$STATE")" = "$accepted_before"

new_case preflight-after-accepted-peer
export DP_AUTH_FAIL_AT=5
capture with_rotating_auth release
check 'late credential failure preserves the dependency exit' test "$status" -eq 3
check 'late credential failure never sends the unfinished destination' test "$(count)" -eq 1
STATE=$(state_path)
accepted_before=$(jq -Sc '.deliveries[0]' "$STATE")
check 'accepted and known-unsent destinations remain distinct' jq -e \
    '[.deliveries[].history[-1].outcome]==["accepted","blocked"] and
     .deliveries[1].history[-1].receipt.attempts==0' "$STATE"
unset DP_AUTH_FAIL_AT
capture with_rotating_auth release
check 'ordinary retry completes only known-unsent work' test "$status" -eq 0
check 'ordinary retry never duplicates the accepted peer' test "$(count)" -eq 2
check 'accepted peer retains its original evidence' test "$(jq -Sc '.deliveries[0]' "$STATE")" = "$accepted_before"
check 'safe retry does not claim uncertain-resend permission' jq -e \
    '.deliveries[1].history[1].outcome=="accepted" and
     .deliveries[1].history[1].resend_uncertain==false' "$STATE"

new_case auth-after-rate-limit
export DP_MODE=elapsed DP_AUTH_FAIL_AT=4
capture with_rotating_auth release --repos owner/b
check 'credential loss after rate limiting stays a dependency failure' test "$status" -eq 3
check 'credential loss does not invent a second POST' test "$(count)" -eq 1
STATE=$(state_path)
check 'blocked retry retains its actual earlier HTTP attempt' jq -e \
    '.deliveries[0].history[0] | .outcome=="blocked" and .receipt.attempts==1 and
     .receipt.exit_code==3 and .receipt.http_status==null' "$STATE"
unset DP_MODE DP_AUTH_FAIL_AT
capture with_rotating_auth release --repos owner/b
check 'definitively rejected earlier POST permits ordinary recovery' test "$status" -eq 0
check 'rate-limit recovery sends only the required next POST' test "$(count)" -eq 2
check 'rate-limit recovery needs no uncertain resend' jq -e \
    '.deliveries[0].history[1].resend_uncertain==false' "$STATE"

# Inject only local temporary-file preparation errors. The real outbox and
# delivery worker must retain blocked receipts before a transport can start.
for phase in directory body headers code; do
    new_case "prepare-$phase"
    export DP_PREPARE_FAIL="$phase"
    mktemp() {
        local selected
        if [[ "$*" == *"/dsr-dispatch.XXXXXXXX"* ]]; then
            [[ "$DP_PREPARE_FAIL" != directory ]] || return 19
            selected=$(command mktemp "$@") || return $?
            mkdir "$selected/$DP_PREPARE_FAIL" || return 1
            printf '%s\n' "$selected"
        else
            command mktemp "$@"
        fi
    }
    capture release --repos owner/a
    unset -f mktemp
    check "$phase preparation failure keeps its local error" test "$status" -eq 1
    check "$phase preparation failure starts no POST" test "$(count)" -eq 0
    STATE=$(state_path)
    check "$phase preparation failure retains a zero-attempt receipt" jq -e \
        '.deliveries[0].history[0] | .outcome=="blocked" and .receipt.attempts==0 and
         .receipt.exit_code==1 and .receipt.http_status==null' "$STATE"
    capture release --repos owner/a
    check "$phase preparation failure resumes without uncertain authorization" test "$status" -eq 0
    check "$phase recovery records only the actual HTTP attempt" jq -e \
        '.deliveries[0].history | length==2 and .[0].receipt.attempts==0 and
         .[1].receipt.attempts==1 and .[1].resend_uncertain==false' "$STATE"
    check "$phase recovery sends exactly once" test "$(count)" -eq 1
done

new_case transport-auth-like-exit
export DP_MODE=auth-like-transport
capture release
check 'a transport return code alone cannot prove that no POST ran' test "$status" -eq 8
check 'transport ambiguity retains its actual HTTP attempt' test "$(count)" -eq 2
STATE=$(state_path)
check 'nonempty transport status remains uncertain' jq -e \
    '.deliveries[1].history[0] | .outcome=="uncertain" and .receipt.attempts==1 and
     .receipt.exit_code==8' "$STATE"
unset DP_MODE
capture release
check 'ordinary retry never replays an ambiguous transport' test "$status,$(count)" = 8,2

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

new_case mismatched-receipt-event
_dp_deliver() { _dp_result "$1" dsr-release accepted 0 1 204; }
capture release --event release-ready
check 'wrong-event transport receipt cannot acknowledge a custom request' test "$status" -eq 8
STATE=$(state_path)
check 'wrong-event receipt retains uncertainty under the saved event' jq -e 'all(.deliveries[];.history[-1].outcome=="uncertain" and .history[-1].receipt.event_type=="release-ready")' "$STATE"
# Restore the module rather than duplicating the production function in tests.
# shellcheck source=/dev/null
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
