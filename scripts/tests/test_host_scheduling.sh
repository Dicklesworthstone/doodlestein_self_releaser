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
printf 'Host scheduling: %s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
