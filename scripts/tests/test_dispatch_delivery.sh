#!/usr/bin/env bash
# Real Bash, jq, files and processes; curl is an explicit HTTP boundary fixture.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MODULE="${DISPATCH_TEST_MODULE:-$ROOT/src/dispatch.sh}"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/cases"
export PATH="$WORK/bin:$PATH" DISPATCH_TIMEOUT=2 DISPATCH_MAX_RETRIES=3
export DISPATCH_RETRY_DELAY=0 DISPATCH_MAX_WAIT=0 DISPATCH_PARALLELISM=2
export DSR_GH_TOKEN=dsr-explicit GITHUB_TOKEN=github-other GH_TOKEN=gh-other
export DP_TEST_ROOT="$WORK"
cat > "$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -uo pipefail
config=$(cat)
printf '%s\n' "$config" > "$DP_TEST_CASE/auth"
printf '%s\n' "$@" >> "$DP_TEST_CASE/argv"
body='' headers='' output='' url="${*: -1}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-binary) body="${2#@}"; shift 2 ;;
        --dump-header) headers="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) shift ;;
    esac
done
repo="${url#https://api.github.com/repos/}"; repo="${repo%/dispatches}"
printf '%s\n' "$repo" >> "$DP_TEST_CASE/calls"
cat "$body" > "$DP_TEST_CASE/body-${repo//\//_}.json"
code=204 rc=0 extra=''
case "${DP_MODE:-success}" in
    lost) code=000; rc=28 ;;
    server) code=503 ;;
    bad-ack) code=200 ;;
    forbidden) code=403 ;;
    unauthorized) code=401 ;;
    invalid) code=422 ;;
    redirect) code=307 ;;
    secret-error) code=000; rc=28; printf '%s\n' "$config" >&2 ;;
    rate)
        count=$(grep -c -F "$repo" "$DP_TEST_CASE/calls")
        if (( count < 3 )); then code=429; extra=$'Retry-After: 0\r\n'; fi ;;
    exhausted) code=429; extra=$'Retry-After: 0\r\n' ;;
    wait-too-long) code=429; extra=$'Retry-After: 86400\r\n' ;;
    forbidden-rate) code=403; extra=$'Retry-After: 0\r\n' ;;
    secondary) code=429 ;;
    mixed) [[ "$repo" != owner/b ]] || code=422 ;;
    delay) sleep 0.15 ;;
esac
printf 'HTTP/2 %s\r\n%s\r\n' "$code" "$extra" > "$headers"
printf '%s' '{"message":"fixture"}' > "$output"
printf '%s' "$code"
exit "$rc"
CURL
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DP_TEST_CASE/gh-calls"
[[ "$*" == 'auth token --hostname github.com' ]] || exit 9
printf '%s' 'stored-token'
GH
chmod +x "$WORK/bin/curl" "$WORK/bin/gh"
# shellcheck source=/dev/null
source "$MODULE"
checks=0 failures=0 CASE='' status=0
check() {
    local label="$1"; shift
    checks=$((checks+1))
    if "$@" > "$WORK/check.out" 2>&1; then printf 'ok %s - %s\n' "$checks" "$label"
    else printf 'not ok %s - %s\n' "$checks" "$label"; cat "$WORK/check.out"; failures=$((failures+1)); fi
}
new_case() {
    CASE="$WORK/cases/$1"; mkdir "$CASE"; export DP_TEST_CASE="$CASE"
    : > "$CASE/calls"; : > "$CASE/argv"; : > "$CASE/gh-calls"
    unset DP_MODE DRY_RUN
    export DSR_GH_TOKEN=dsr-explicit GITHUB_TOKEN=github-other GH_TOKEN=gh-other
}
capture() { status=0; "$@" > "$CASE/out" 2> "$CASE/err" || status=$?; }
count() { wc -l < "$CASE/calls"; }
contains() { grep -F -- "$2" "$1" >/dev/null; }
absent_text() { ! grep -F -- "$2" "$1" >/dev/null; }

new_case success
capture dispatch_event Owner/Repo release --payload '{"version":"v1.2.3"}'
check '204 is accepted' test "$status" -eq 0
check 'receipt contains normalized repo and acknowledgement only' jq -e '.repo=="owner/repo" and .outcome=="accepted" and .attempts==1 and .http_status=="204"' "$CASE/out"
check 'single acknowledgement uses exactly one POST' test "$(count)" -eq 1
check 'payload is delivered as one typed object' jq -e '.event_type=="release" and .client_payload.version=="v1.2.3"' "$CASE/body-owner_repo.json"
check 'documented explicit token has precedence' contains "$CASE/auth" 'Bearer dsr-explicit'
check 'token does not appear in process arguments' absent_text "$CASE/argv" dsr-explicit
check 'curlrc is disabled' test "$(head -1 "$CASE/argv")" = -q
check 'authenticated request disables built-in retries' contains "$CASE/argv" --retry
check 'auth is not redundantly checked through gh' test ! -s "$CASE/gh-calls"

for pair in lost:8 server:8 bad-ack:8 forbidden:3 unauthorized:3 invalid:7 redirect:8; do
    mode="${pair%:*}" expected="${pair#*:}"
    new_case "$mode"; export DP_MODE="$mode"
    capture dispatch_event owner/repo release
    check "$mode preserves failure exit" test "$status" -eq "$expected"
    check "$mode is not blindly replayed" test "$(count)" -eq 1
    check "$mode never reports acceptance" jq -e '.outcome!="accepted" and .exit_code!=0' "$CASE/out"
done

new_case rate; export DP_MODE=rate
capture dispatch_event owner/repo release
check 'explicit rate-limit rejection is retried' test "$(count)" -eq 3
check 'rate-limited delivery can recover' test "$status" -eq 0
check 'recovered receipt records all attempts' jq -e '.attempts==3 and .outcome=="accepted"' "$CASE/out"
for mode in exhausted forbidden-rate; do
    new_case "$mode"; export DP_MODE="$mode"
    capture dispatch_event owner/repo release
    check "$mode attempts are bounded" test "$(count)" -eq 3
    check "$mode has definitive rate-limited outcome" jq -e '.outcome=="rate_limited" and .attempts==3' "$CASE/out"
done
for mode in wait-too-long secondary; do
    new_case "$mode"; export DP_MODE="$mode"
    capture dispatch_event owner/repo release
    check "$mode is not retried earlier than allowed" test "$(count)" -eq 1
    check "$mode remains a failure" test "$status" -eq 8
done

new_case secret; export DP_MODE=secret-error
capture dispatch_event owner/repo release
check 'transport echo cannot leak credentials into stdout' absent_text "$CASE/out" dsr-explicit
check 'transport echo cannot leak credentials into stderr' absent_text "$CASE/err" dsr-explicit

new_case dry
unset DSR_GH_TOKEN GITHUB_TOKEN GH_TOKEN
capture dispatch_event owner/repo release --dry-run
check 'dry-run works without credentials' test "$status" -eq 0
check 'dry-run performs no POST' test "$(count)" -eq 0
check 'dry-run does not call auth helpers' test ! -s "$CASE/gh-calls"
check 'dry-run is explicitly planned, not accepted' jq -e '.outcome=="planned" and .attempts==0' "$CASE/out"
export DRY_RUN=true
capture dispatch_event owner/repo release
check 'global dry-run is honored' test "$(count)" -eq 0

for payload in 'null' '[]' 'true' '1' '{}'\$'\n''{}' 'garbage'; do
    new_case "payload-$checks"
    capture dispatch_event owner/repo release --payload "$payload" --dry-run
    check "invalid payload rejected ($payload)" test "$status" -eq 4
    check 'invalid payload cannot have side effects' test "$(count)" -eq 0
done
new_case limits
payload=$(jq -nc 'reduce range(11) as $i ({}; .[($i|tostring)]=$i)')
capture dispatch_event owner/repo release --payload "$payload"
check 'more than ten client keys are rejected' test "$status" -eq 4
payload=$(jq -nc '{text:("x"*65536)}')
capture dispatch_event owner/repo release --payload "$payload"
check 'oversized UTF8 payload is rejected' test "$status" -eq 4
event=$(printf '%0101d' 1)
capture dispatch_event owner/repo "$event"
check 'event longer than 100 characters rejected' test "$status" -eq 4
capture dispatch_event owner/repo $'event\nother'
check 'event control bytes rejected' test "$status" -eq 4
for repo in '../owner/repo' 'owner/repo?x' 'owner/..' '-owner/repo' 'https://evil.test/path'; do
    capture dispatch_event "$repo" release
    check "unsafe destination rejected: $repo" test "$status" -eq 4
done
for flag in --payload --unknown; do
    capture dispatch_event owner/repo release "$flag"
    check "bad option rejected: $flag" test "$status" -eq 4
done
DISPATCH_MAX_RETRIES=0 capture dispatch_event owner/repo release
check 'zero retries cannot become false success' test "$status" -eq 4
DISPATCH_TIMEOUT=garbage capture dispatch_event owner/repo release
check 'invalid timeout rejected before transport' test "$status" -eq 4

new_case batch-invalid
capture dispatch_batch release --repos 'owner/valid,../invalid' --payload '{}'
check 'invalid late target fails all-target preflight' test "$status" -ne 0
check 'invalid late target never dispatches earlier targets' test "$(count)" -eq 0
for repos in 'owner/a,' ',owner/a' 'owner/a,,owner/b'; do
    capture dispatch_batch release --repos "$repos"
    check "empty target rejected: $repos" test "$status" -eq 4
done

new_case batch
capture dispatch_batch release --repos 'Owner/A,owner/b,owner/a' --parallel
check 'parallel batch succeeds' test "$status" -eq 0
check 'case-insensitive duplicate destinations are coalesced' test "$(count)" -eq 2
check 'all-target structured outcomes are complete' jq -e '.status=="accepted" and (.results|length)==2' "$CASE/out"
export DP_MODE=mixed
capture dispatch_batch release --repos 'owner/a,owner/b' --parallel
check 'one failed target makes whole batch incomplete' test "$status" -eq 1
check 'partial batch includes both outcomes' jq -e '.status=="incomplete" and ([.results[].outcome]|sort)==["accepted","rejected"]' "$CASE/out"

new_case release
sha=$(printf '%040d' 1)
capture dispatch_release test-tool v1.2.3 --sha "$sha" --repos owner/downstream --dry-run
check 'explicit release pin is accepted' test "$status" -eq 0
capture dispatch_release test-tool v1.2.3 --sha abc123 --dry-run
check 'abbreviated release SHA is rejected' test "$status" -eq 4
capture dispatch_release test-tool v1.2.3
check 'release does not infer unrelated PWD commit' test "$status" -eq 4
check 'unbound release never sends an event' test "$(count)" -eq 0
mkdir "$CASE/git"
git -C "$CASE/git" init -q -b main
git -C "$CASE/git" -c user.name=Test -c user.email=test@example.test commit -q --allow-empty -m first
git -C "$CASE/git" -c user.name=Test -c user.email=test@example.test tag -a v1.2.3 -m release
pin=$(git -C "$CASE/git" rev-parse HEAD)
git -C "$CASE/git" -c user.name=Test -c user.email=test@example.test commit -q --allow-empty -m second
capture dispatch_release test-tool 1.2.3 --repo-path "$CASE/git" --repos owner/downstream
check 'explicit checkout resolves annotated release tag' test "$status" -eq 0
check 'release payload uses tag commit rather than current HEAD' jq -e --arg sha "$pin" '.client_payload.sha==$sha' "$CASE/body-owner_downstream.json"
cp "$CASE/body-owner_downstream.json" "$CASE/before.json"
capture dispatch_release test-tool 1.2.3 --repo-path "$CASE/git" --repos owner/downstream
check 'same release has stable payload bytes and invocation ID' cmp -s "$CASE/before.json" "$CASE/body-owner_downstream.json"
capture dispatch_release_json test-tool 1.2.3 --sha "$sha" --repos owner/downstream --dry-run
check 'JSON wrapper success is valid JSON' jq -e '.status=="success" and .details.status=="planned"' "$CASE/out"
capture dispatch_release_json test-tool 1.2.3 --sha invalid
check 'JSON wrapper preserves invalid argument exit' test "$status" -eq 4
check 'JSON wrapper error remains structured' jq -e '.status=="error" and .exit_code==4' "$CASE/out"

new_case exports
capture bash -c 'dispatch_event owner/repo release --dry-run'
check 'exported API includes all helper dependencies' test "$status" -eq 0
capture bash "$MODULE" event owner/repo release --dry-run
check 'standalone event CLI works' test "$status" -eq 0
capture bash "$MODULE" json test-tool 1.2.3 --sha bad
check 'standalone JSON CLI propagates failure' test "$status" -eq 4

printf '\nDispatch delivery checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
