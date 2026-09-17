#!/usr/bin/env bash
# Exercise real selector config parsing, filesystem slots and routing. Only the
# internal health provider is isolated: these tests must not contact SSH hosts.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${DSR_SELECTOR_MODULE:-$ROOT/src/host_selector.sh}"
command -v jq >/dev/null || { echo 'SKIP: jq is required'; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-scheduling.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
export DSR_CONFIG_DIR="$work/config" DSR_STATE_DIR="$work/state"
export DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"
mkdir -p "$DSR_CONFIG_DIR" || exit 1
# JSON is a YAML subset, so the actual config reader needs no yq for this input.
cat > "$DSR_HOSTS_FILE" <<'JSON'
{"hosts":{
  "alpha":{"platform":"linux/amd64","connection":"local","concurrency":1},
  "beta":{"platform":"darwin/arm64","connection":"ssh","concurrency":1},
  "gamma":{"platform":"linux/amd64","connection":"ssh","concurrency":1},
  "delta":{"platform":"linux/arm64","connection":"ssh","concurrency":1},
  "disabled":{"platform":"linux/amd64","connection":"local","concurrency":100,"enabled":false},
  "paused":{"platform":"linux/amd64","connection":"local","concurrency":0},
  "unknown-platform":{"connection":"local","concurrency":100}
}}
JSON
cp "$DSR_HOSTS_FILE" "$work/original.json"
HEALTH='["gamma","alpha","beta","disabled","paused","removed","unknown-platform"]'
HEALTH_STATUS=0
host_health_get_healthy_hosts() {
    if [[ "${1:-}" == --for-capability ]]; then
        [[ "${2:-}" == rust && "${3:-}" == --json ]] || return 4
        printf '%s\n' '["gamma"]'
    else
        [[ "${1:-}" == --json ]] || return 4
        printf '%s\n' "$HEALTH"
    fi
    return "$HEALTH_STATUS"
}
passed=0 failed=0
expect() {
    local label="$1" expected_status="$2" expected="$3" actual status=0
    shift 3
    actual=$("$@" 2>"$work/error") || status=$?
    if [[ "$status" == "$expected_status" && "$actual" == "$expected" ]]; then
        passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$label"
    else
        failed=$((failed + 1))
        printf 'FAIL %s: expected exit %s [%s], got %s [%s]\n' \
            "$label" "$expected_status" "$expected" "$status" "$actual" >&2
        cat "$work/error" >&2
    fi
}
projection() {
    local json
    json=$("${@:2}") || return $?
    jq -ces --arg filter "$1" 'if length == 1 then .[0] else error("multiple results") end' \
        <<< "$json" | jq -c "$1"
}
# Reproduce the original scoring bug independently of config dependencies.
full_local_case() (
    selector_get_candidates() {
        printf '%s\n' '[{"hostname":"alpha","score":120,"available":0},{"hostname":"gamma","score":110,"available":1}]'
    }
    selector_choose_host --target linux/amd64
)
expect 'full local does not hide free remote' 0 gamma full_local_case
expect 'configured limit parsed' 0 1 selector_get_limit alpha
expect 'disabled host has no capacity' 0 0 selector_get_limit disabled
expect 'explicit zero is retained' 0 0 selector_get_limit paused
expect 'synthetic act host uses default' 0 2 selector_get_limit act-local
expect 'choose configured local with capacity' 0 alpha selector_choose_host --target linux/amd64
expect 'capability passed through health provider' 0 gamma selector_choose_host --target linux/amd64 --capability rust
expect 'explicit preference with capacity' 0 gamma selector_choose_host --target linux/amd64 --prefer gamma
expect 'disabled preference cannot override policy' 0 alpha selector_choose_host --target linux/amd64 --prefer disabled
expect 'paused preference cannot override policy' 0 alpha selector_choose_host --target linux/amd64 --prefer paused
expect 'target OS filtering' 0 beta selector_choose_host --target darwin/arm64
expect 'ineligible target returns no host' 1 '' selector_choose_host --target windows/amd64
expect 'stale health entries excluded' 0 '["alpha","gamma"]' projection 'map(.hostname)' selector_get_candidates --target linux/amd64
selector_init || exit 1
selector_acquire_slot alpha held >/dev/null 2>&1 || exit 1
expect 'real saturated local routes to remote' 0 gamma selector_choose_host --target linux/amd64
expect 'full preferred host routes to free host' 0 gamma selector_choose_host --target linux/amd64 --prefer alpha
expect 'selection rationale matches actual decision' 0 '["gamma","highest score with capacity"]' \
    projection '[.selected,.reason]' selector_choose_host --target linux/amd64 --json
selector_acquire_slot gamma held >/dev/null 2>&1 || exit 1
expect 'all full retains wait-compatible host' 0 '["alpha","best available (at capacity)"]' \
    projection '[.selected,.reason]' selector_choose_host --target linux/amd64 --json
selector_release_slot gamma held >/dev/null 2>&1 || exit 1
HEALTH='["gamma","delta","gamma"]'
expect 'deduplication and deterministic tie break' 0 '["delta","gamma"]' projection 'map(.hostname)' selector_get_candidates --target linux/amd64
HEALTH='["delta","gamma"]'
expect 'tie independent of health ordering' 0 delta selector_choose_host --target linux/amd64
HEALTH_STATUS=8
expect 'health failure is not a successful inventory' 8 '' selector_get_candidates
expect 'health failure propagates through selection' 8 '' selector_choose_host
HEALTH_STATUS=0
for bad in 'null' '{}' '[42]' '["../escape"]' '["alpha\n"]' '[] []' ''; do
    HEALTH="$bad"
    expect "malformed health: $bad" 4 '' selector_choose_host
 done
HEALTH='[]'
expect 'empty health inventory is valid' 0 '[]' selector_get_candidates
expect 'empty inventory cannot choose a host' 1 '' selector_choose_host
for bad in -1 1.5 '"2"' null true 1025; do
    jq --argjson bad "$bad" '.hosts.alpha.concurrency=$bad' "$work/original.json" > "$DSR_HOSTS_FILE"
    expect "invalid concurrency $bad rejected" 4 '' selector_get_limit alpha
    expect "invalid concurrency $bad not retried as capacity" 4 '' selector_acquire_slot alpha malformed --wait
 done
for bad in '{"hosts":[]}' '{"hosts":null}' '{"hosts":{"../escape":{}}}' \
    '{"hosts":{"alpha":{"enabled":"false"}}}' '{"hosts":{"alpha":{"platform":42}}}' \
    '{"hosts":{"alpha":{"connection":"invalid"}}}' '[]' 'null'; do
    printf '%s\n' "$bad" > "$DSR_HOSTS_FILE"
    expect "invalid config $bad" 4 '' selector_get_candidates
 done
cp "$work/original.json" "$DSR_HOSTS_FILE"
for command in selector_choose_host selector_get_candidates; do
    expect "$command missing target" 4 '' "$command" --target
    expect "$command unknown option" 4 '' "$command" --typo
    expect "$command bad target" 4 '' "$command" --target ../bad
 done
expect 'invalid preference' 4 '' selector_choose_host --prefer ../bad
for command in selector_get_limit selector_get_usage selector_acquire_slot selector_release_slot; do
    expect "$command rejects path components" 4 '' "$command" ../escape run
 done
expect 'invalid slot id' 4 '' selector_acquire_slot alpha ../escape
selector_acquire_slot act-local synthetic >/dev/null 2>&1 || exit 1
expect 'status includes configured and synthetic active hosts' 0 \
    '["act-local","alpha","beta","delta","disabled","gamma","paused","unknown-platform"]' \
    projection 'map(.hostname)' selector_queue_status --json
expect 'status uses disabled policy too' 0 '[0,true]' \
    projection '.[] | select(.hostname == "disabled") | [.limit,.at_capacity]' selector_queue_status --json

# Each case runs in an isolated Bash process. These exercise the production
# mutex, process identity and atomic publication, not a mocked concurrency API.
lease_env() {
    export DSR_STATE_DIR="$work/$1" DSR_SELECTOR_LOCK_TIMEOUT=3 DSR_SELECTOR_WAIT_TIMEOUT=2
    selector_init || return 1
    export DSR_HOSTS_FILE="$DSR_STATE_DIR/hosts.json"
    cp "$work/original.json" "$DSR_HOSTS_FILE" || return 1
    if [[ -n "${2:-}" ]]; then
        printf '%s\n' "$2" > "$_SELECTOR_STATE_DIR/lock-backend"
    fi
}
lease_cycle() {
    lease_env cycle || return 1
    local owner="$BASHPID" status=0
    selector_acquire_slot gamma owned || return 1
    jq -e --argjson pid "$owner" '.schema == 1 and .pid == $pid and .run_id == "owned"' \
        "$_SELECTOR_LOCKS_DIR/gamma/owned.lock" >/dev/null || return 1
    selector_acquire_slot gamma owned || return 1
    touch -t 200001010000 "$_SELECTOR_LOCKS_DIR/gamma/owned.lock" || return 1
    [[ "$(selector_get_usage gamma)" == 1 ]] || return 1
    selector_acquire_slot gamma other || status=$?
    [[ $status -eq 2 ]] || return 1
    selector_release_slot gamma owned || return 1
    selector_release_slot gamma owned || return 1
    [[ "$(selector_get_usage gamma)" == 0 ]]
}
expect 'owned slots are idempotent, retain old live builds, and release cleanly' 0 '' lease_cycle

wait_file() {
    local file="$1" deadline=$((SECONDS + 8))
    while [[ ! -f "$file" ]]; do
        ((SECONDS < deadline)) || return 1
        sleep 0.05 || return 1
    done
}
lease_crash() {
    lease_env crash || return 1
    (
        selector_acquire_slot gamma crashed || exit 1
        : > "$DSR_STATE_DIR/ready"
        # The holder is bounded even if a test assertion fails.
        sleep 8
        :
    ) > "$DSR_STATE_DIR/holder.log" 2>&1 &
    local holder=$! status=0 before after
    wait_file "$DSR_STATE_DIR/ready" || return 1
    before=$(cat "$_SELECTOR_LOCKS_DIR/gamma/crashed.lock") || return 1
    selector_acquire_slot gamma crashed || status=$?
    [[ $status -eq 2 ]] || return 1
    status=0
    selector_release_slot gamma crashed || status=$?
    [[ $status -eq 2 ]] || return 1
    after=$(cat "$_SELECTOR_LOCKS_DIR/gamma/crashed.lock") || return 1
    [[ "$before" == "$after" ]] || return 1
    kill -TERM "$holder" || return 1
    wait "$holder" 2>/dev/null || true
    [[ "$(selector_get_usage gamma)" == 0 ]] || return 1
    # Status is read-only: it does not remove the stale evidence.
    [[ -f "$_SELECTOR_LOCKS_DIR/gamma/crashed.lock" ]] || return 1
    selector_acquire_slot gamma recovered || return 1
    [[ ! -e "$_SELECTOR_LOCKS_DIR/gamma/crashed.lock" ]] || return 1
    selector_release_slot gamma recovered
}
expect 'foreign ownership is protected and dead worker capacity is recovered' 0 '' lease_crash

lease_opaque() {
    lease_env opaque || return 1
    _sel_prepare_host gamma || return 1
    printf '%s\n' 'unrecognized-old-record' > "$_SELECTOR_LOCKS_DIR/gamma/unknown.lock"
    touch -t 200001010000 "$_SELECTOR_LOCKS_DIR/gamma/unknown.lock" || return 1
    [[ "$(selector_get_usage gamma)" == 1 ]] || return 1
    local status=0
    selector_acquire_slot gamma fresh || status=$?
    [[ $status -eq 2 && -s "$_SELECTOR_LOCKS_DIR/gamma/unknown.lock" ]]
}
expect 'unknown ownership never expires by timestamp' 0 '' lease_opaque

lease_identity() {
    lease_env identity || return 1
    selector_acquire_slot gamma recycled || return 1
    local path="$_SELECTOR_LOCKS_DIR/gamma/recycled.lock"
    jq '.start="proc:0"' "$path" > "$DSR_STATE_DIR/changed"
    mv "$DSR_STATE_DIR/changed" "$path" || return 1
    [[ "$(selector_get_usage gamma)" == 0 ]] || return 1
    selector_acquire_slot gamma next || return 1
    [[ ! -e "$path" ]] || return 1
    path="$_SELECTOR_LOCKS_DIR/gamma/next.lock"
    jq '.node="different-controller"' "$path" > "$DSR_STATE_DIR/changed"
    mv "$DSR_STATE_DIR/changed" "$path" || return 1
    [[ "$(selector_get_usage gamma)" == 1 ]]
}
expect 'start identity detects PID reuse while foreign-controller slots remain reserved' 0 '' lease_identity

lease_probe_failure() {
    lease_env probe || return 1
    selector_acquire_slot gamma uncertain || return 1
    _sel_process_start() { return 4; }
    [[ "$(selector_get_usage gamma)" == 1 && -f "$_SELECTOR_LOCKS_DIR/gamma/uncertain.lock" ]]
}
expect 'unavailable process probe preserves reserved capacity' 0 '' lease_probe_failure

lease_deadline() {
    lease_env deadline || return 1
    selector_acquire_slot gamma held || return 1
    local started=$SECONDS status=0
    DSR_SELECTOR_WAIT_TIMEOUT=1 selector_acquire_slot gamma waiting --wait || status=$?
    [[ $status -eq 2 && $((SECONDS - started)) -le 3 && ! -e "$_SELECTOR_LOCKS_DIR/gamma/waiting.lock" ]] || return 1
    selector_release_slot gamma held
}
expect 'capacity waits stop at a bounded deadline without creating a slot' 0 '' lease_deadline

lease_guard() {
    lease_env guard mkdir || return 1
    mkdir "$_SELECTOR_STATE_DIR/mutexes/gamma.d" || return 1
    touch -t 200001010000 "$_SELECTOR_STATE_DIR/mutexes/gamma.d" || return 1
    local status=0 started=$SECONDS
    DSR_SELECTOR_LOCK_TIMEOUT=1 selector_acquire_slot gamma blocked || status=$?
    [[ $status -eq 2 && $((SECONDS - started)) -le 3 ]] || return 1
    [[ -d "$_SELECTOR_STATE_DIR/mutexes/gamma.d" && ! -e "$_SELECTOR_LOCKS_DIR/gamma/blocked.lock" ]]
}
expect 'old mkdir guards are not stolen and lock waits are bounded' 0 '' lease_guard

lease_mkdir_cleanup() {
    lease_env 'fallback with spaces' mkdir || return 1
    trap ':' RETURN
    local before after
    before=$(trap -p RETURN)
    selector_acquire_slot gamma fallback || return 1
    [[ ! -e "$_SELECTOR_STATE_DIR/mutexes/gamma.d" ]] || return 1
    selector_release_slot gamma fallback || return 1
    after=$(trap -p RETURN)
    [[ "$before" == "$after" && ! -e "$_SELECTOR_STATE_DIR/mutexes/gamma.d" ]]
}
expect 'mkdir backend cleans up without changing caller traps or breaking spaced paths' 0 '' lease_mkdir_cleanup

lease_failed_lock() {
    lease_env failed-lock flock || return 1
    flock() { return 64; }
    local status=0
    selector_acquire_slot gamma denied || status=$?
    [[ $status -eq 4 && ! -e "$_SELECTOR_LOCKS_DIR/gamma/denied.lock" ]]
}
expect 'mutex acquisition failure cannot run the critical section' 0 '' lease_failed_lock

lease_failed_publish() {
    lease_env failed-publish mkdir || return 1
    ln() { return 1; }
    local status=0
    selector_acquire_slot gamma denied || status=$?
    [[ $status -eq 4 && ! -e "$_SELECTOR_LOCKS_DIR/gamma/denied.lock" && ! -e "$_SELECTOR_STATE_DIR/mutexes/gamma.d" ]]
}
expect 'failed atomic publication reports failure and releases the mutex' 0 '' lease_failed_publish

lease_symlink() {
    lease_env symlink || return 1
    mkdir "$DSR_STATE_DIR/outside" || return 1
    ln -s "$DSR_STATE_DIR/outside" "$_SELECTOR_LOCKS_DIR/gamma" || return 1
    local status=0
    selector_acquire_slot gamma unsafe || status=$?
    [[ $status -eq 4 && ! -e "$DSR_STATE_DIR/outside/unsafe.lock" ]]
}
expect 'host directory symlinks cannot redirect slot writes' 0 '' lease_symlink

lease_race() {
    local backend="$1"
    lease_env "race-$backend" "$backend" || return 1
    export DSR_SELECTOR_LOCK_TIMEOUT=10
    local -a pids=()
    local index pid count deadline
    for index in {1..12}; do
        (
            status=0
            selector_acquire_slot act-local "worker-$index" || status=$?
            printf '%s\n' "$status" > "$DSR_STATE_DIR/result-$index"
            if [[ $status -eq 0 ]]; then
                holder_deadline=$((SECONDS + 15))
                until [[ -e "$DSR_STATE_DIR/release" ]]; do
                    ((SECONDS < holder_deadline)) || exit 1
                    sleep 0.05 || exit 1
                done
                selector_release_slot act-local "worker-$index" || exit 1
            elif [[ $status -ne 2 ]]; then exit 1; fi
        ) > "$DSR_STATE_DIR/worker-$index.log" 2>&1 &
        pids+=("$!")
    done
    deadline=$((SECONDS + 12))
    while true; do
        count=$(find "$DSR_STATE_DIR" -name 'result-*' -type f | wc -l)
        [[ $count -eq 12 ]] && break
        if ((SECONDS >= deadline)); then
            : > "$DSR_STATE_DIR/release"
            for pid in "${pids[@]}"; do wait "$pid" || true; done
            return 1
        fi
        sleep 0.05 || return 1
    done
    count=$(grep -l '^0$' "$DSR_STATE_DIR"/result-* | wc -l)
    [[ $count -eq 2 && "$(selector_get_usage act-local)" == 2 ]] || {
        : > "$DSR_STATE_DIR/release"
        for pid in "${pids[@]}"; do wait "$pid" || true; done
        return 1
    }
    : > "$DSR_STATE_DIR/release"
    for pid in "${pids[@]}"; do wait "$pid" || return 1; done
    [[ "$(selector_get_usage act-local)" == 0 ]]
}
expect '12 competing processes respect the two-slot limit with flock' 0 '' lease_race flock
expect '12 competing processes respect the two-slot limit with mkdir' 0 '' lease_race mkdir
expect 'competing first-use processes agree on one mutex backend' 0 '' lease_race ''

lease_interrupt() {
    lease_env interrupt "$1" || return 1
    _sel_prepare_host gamma || return 1
    interrupt_self() { kill -TERM "$BASHPID"; }
    local status=0
    _sel_with_lock gamma 1 interrupt_self || status=$?
    [[ $status -eq 5 && ! -e "$_SELECTOR_STATE_DIR/mutexes/gamma.d" ]] || return 1
    selector_acquire_slot gamma after-signal || return 1
    selector_release_slot gamma after-signal
}
expect 'TERM releases flock mutex and preserves interrupt status' 0 '' lease_interrupt flock
expect 'TERM releases mkdir mutex and preserves interrupt status' 0 '' lease_interrupt mkdir

lease_wait_success() {
    lease_env wait-success || return 1
    (
        selector_acquire_slot gamma first || exit 1
        : > "$DSR_STATE_DIR/ready"
        sleep 0.3
        selector_release_slot gamma first
    ) > "$DSR_STATE_DIR/holder.log" 2>&1 &
    local holder=$!
    wait_file "$DSR_STATE_DIR/ready" || return 1
    selector_acquire_slot gamma second --wait || return 1
    wait "$holder" || return 1
    [[ "$(selector_get_usage gamma)" == 1 ]] || return 1
    selector_release_slot gamma second
}
expect 'waiting worker proceeds after the previous owner releases capacity' 0 '' lease_wait_success

lease_independent_hosts() {
    lease_env independent mkdir || return 1
    mkdir "$_SELECTOR_STATE_DIR/mutexes/alpha.d" || return 1
    DSR_SELECTOR_LOCK_TIMEOUT=0 selector_acquire_slot gamma independent || return 1
    selector_release_slot gamma independent
}
expect 'one blocked host mutex does not block another host' 0 '' lease_independent_hosts

lease_slot_link() {
    lease_env slot-link || return 1
    _sel_prepare_host gamma || return 1
    printf 'keep\n' > "$DSR_STATE_DIR/outside"
    ln -s "$DSR_STATE_DIR/outside" "$_SELECTOR_LOCKS_DIR/gamma/redirect.lock" || return 1
    local status=0
    selector_acquire_slot gamma redirect || status=$?
    [[ $status -eq 4 && "$(cat "$DSR_STATE_DIR/outside")" == keep ]]
}
expect 'slot symlinks are rejected without touching their target' 0 '' lease_slot_link

lease_disable_during_build() {
    lease_env disable-during-build || return 1
    selector_acquire_slot gamma existing || return 1
    jq '.hosts.gamma.enabled=false' "$DSR_HOSTS_FILE" > "$DSR_STATE_DIR/new-config"
    mv "$DSR_STATE_DIR/new-config" "$DSR_HOSTS_FILE" || return 1
    local status=0 started=$SECONDS
    selector_acquire_slot gamma new --wait || status=$?
    [[ $status -eq 2 && $((SECONDS - started)) -lt 2 && "$(selector_get_usage gamma)" == 1 ]] || return 1
    selector_release_slot gamma existing
}
expect 'disabled hosts refuse new work immediately while existing owners can release' 0 '' lease_disable_during_build

printf 'Host scheduling: %s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
