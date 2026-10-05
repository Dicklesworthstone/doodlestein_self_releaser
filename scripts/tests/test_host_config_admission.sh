#!/usr/bin/env bash
# Real parser/filesystem/probe regressions for GH #21. No fake yq or SSH.
# DSR_TEST_REQUIRE_YQ=1 makes an unavailable YAML parser a failing prerequisite.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo 'SKIP: jq is required' >&2; exit 3; }
TEST_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export DSR_CONFIG_DIR="$TEST_ROOT/config"
export DSR_CACHE_DIR="$TEST_ROOT/cache"
export DSR_STATE_DIR="$TEST_ROOT/state"
export DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"
export DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"
export DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
mkdir -p "$DSR_CONFIG_DIR" "$DSR_CACHE_DIR" "$DSR_STATE_DIR" || exit 1
source "$PROJECT_ROOT/src/host_health.sh"

RUN=0 PASSED=0 FAILED=0 SKIPPED=0
HAVE_YQ=false
if command -v yq >/dev/null 2>&1; then
    HAVE_YQ=true
elif [[ "${DSR_TEST_REQUIRE_YQ:-0}" == 1 ]]; then
    echo 'ERROR: install Mike Farah yq v4 to run the required parser regressions' >&2
    exit 3
fi

fixture() {
    cat > "$DSR_HOSTS_FILE" <<'YAML'
schema_version: "1.0.0"
hosts:
  local:
    platform: linux/amd64
    connection: local
    capabilities:
      - go
    description: "Live local probes"
  offline-builder:
    platform: linux/amd64
    connection: ssh
    ssh_host: dsr-health-test.invalid
    capabilities:
      - go
  disabled:
    platform: linux/amd64
    connection: local
    enabled: false
YAML
}

run_test() {
    local name="$1"
    shift
    RUN=$((RUN + 1))
    if (
        fixture || exit 1
        _HH_CACHE_DIR="$TEST_ROOT/cache/$RUN"
        _HH_SSH_TIMEOUT=1
        _HH_CMD_TIMEOUT=5
        "$@"
    ) > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/stderr"; then
        PASSED=$((PASSED + 1))
        printf 'PASS: %s\n' "$name"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n' "$name"
        cat "$TEST_ROOT/stdout" "$TEST_ROOT/stderr"
    fi
}

reject() {
    local expected="$1" output status=0
    shift
    output=$("$@") || status=$?
    [[ $status -eq $expected && -z "$output" ]]
}

normal_defaults() {
    local result
    result=$(_hh_normalize_host_config builder '{"platform":"linux/amd64"}') || return 1
    jq -e '.connection == "ssh" and .ssh_host == "builder" and
        .enabled == true and .capabilities == [] and .description == ""' <<< "$result" >/dev/null
}

normal_values() {
    local result
    result=$(_hh_normalize_host_config builder '{"platform":"darwin/arm64",
        "ssh_host":"user@build.example.invalid","capabilities":["rust","go"],
        "enabled":false,"description":"quoted \"host\""}') || return 1
    jq -e '.platform == "darwin/arm64" and .ssh_host == "user@build.example.invalid" and
        .capabilities == ["rust","go"] and .enabled == false and
        .description == "quoted \"host\""' <<< "$result" >/dev/null
}

simple_host() {
    local result
    result=$(_hh_get_host_config local) || return 1
    jq -e '.platform == "linux/amd64" and .connection == "local" and
        .capabilities == ["go"] and .enabled == true' <<< "$result" >/dev/null
}

remote_route() {
    local result
    result=$(_hh_get_host_config offline-builder) || return 1
    jq -e '.ssh_host == "dsr-health-test.invalid" and .connection == "ssh" and
        .capabilities == ["go"]' <<< "$result" >/dev/null
}

listing() {
    local result
    result=$(_hh_list_hosts) || return 1
    [[ $(printf '%s\n' "$result" | LC_ALL=C sort) == $'local\noffline-builder' ]]
}

fallback_simple() {
    local result
    result=$(_hh_parse_host_fallback local) || return 1
    jq -e '.connection == "local" and .capabilities == ["go"] and
        .enabled == true' <<< "$result" >/dev/null || return 1
    result=$(_hh_parse_host_fallback disabled) || return 1
    jq -e '.enabled == false and .capabilities == []' <<< "$result" >/dev/null
}

fallback_unsupported() {
    printf '%s\n' "$1" > "$DSR_HOSTS_FILE"
    reject 3 _hh_parse_host_fallback local
}

live_local() {
    command -v go >/dev/null 2>&1 || return 1
    local result
    result=$(host_health_check local --no-cache --json) || return 1
    jq -e '.healthy == true and .checks.connectivity.method == "local" and
        .checks.toolchains.go.status == "ok" and
        (.checks.toolchains.go.version | startswith("go version")) and
        (.checks.disk_space.usage_percent | type == "number")' <<< "$result" >/dev/null || return 1
    host_health_is_ready local --require go
}

live_disk_refusal() {
    # Use the actual df result with a test-only threshold below any real usage.
    # This tests refusal, not a fabricated remote response or a filled disk.
    _HH_DISK_ERROR_THRESHOLD=-1
    local result status=0
    result=$(host_health_check local --no-cache --json) || status=$?
    [[ $status -eq 1 ]] || return 1
    jq -e '.healthy == false and .checks.disk_space.status == "error" and
        (.checks.disk_space.usage_percent | type == "number")' <<< "$result" >/dev/null || return 1
    ! host_health_is_ready local
}

live_unreachable() {
    command -v ssh >/dev/null 2>&1 || return 1
    local result status=0
    result=$(host_health_check offline-builder --no-cache --json) || status=$?
    [[ $status -eq 1 ]] || return 1
    jq -e '.healthy == false and .checks.connectivity.reachable == false and
        .checks.disk_space.status == "unknown"' <<< "$result" >/dev/null
}

disabled() {
    local result
    result=$(host_health_check disabled --json) || return 1
    jq -e '.healthy == false and .status == "disabled" and .checks == {}' <<< "$result" >/dev/null || return 1
    ! host_health_is_ready disabled
}

invalid_name() {
    local result status=0
    result=$(host_health_check '../bad"host' --json) || status=$?
    [[ $status -eq 4 ]] || return 1
    jq -e '.healthy == false and .status == "error" and
        .hostname == "../bad\"host"' <<< "$result" >/dev/null
}

missing_host() {
    reject 1 _hh_get_host_config absent || return 1
    local result status=0
    result=$(host_health_check absent --json) || status=$?
    [[ $status -eq 4 ]] || return 1
    jq -e '.error == "Host not configured" and .healthy == false' <<< "$result" >/dev/null
}

alias_fixture() {
    cat > "$DSR_HOSTS_FILE" <<'YAML'
shared: &base
  platform: linux/amd64
  connection: local
  capabilities: &go_tools
    - go
hosts:
  local: *base
  local-two:
    <<: *base
  remote:
    platform: linux/amd64
    connection: ssh
    ssh_host: real-route.example.invalid
    capabilities: *go_tools
  disabled:
    <<: *base
    enabled: false
YAML
}

aliases() {
    alias_fixture || return 1
    local result
    result=$(_hh_get_host_config remote) || return 1
    jq -e '.ssh_host == "real-route.example.invalid" and .capabilities == ["go"] and
        .platform == "linux/amd64"' <<< "$result" >/dev/null || return 1
    result=$(_hh_get_host_config local-two) || return 1
    jq -e '.connection == "local" and .capabilities == ["go"]' <<< "$result" >/dev/null || return 1
    result=$(_hh_list_hosts) || return 1
    [[ "$result" == $'local\nlocal-two\nremote' ]] || return 1
    live_local
}

invalid_yaml() {
    printf '%s\n' "$1" > "$DSR_HOSTS_FILE"
    reject 4 _hh_get_host_config local || return 1
    reject 4 _hh_list_hosts || return 1
    local result status=0
    result=$(host_health_check local --json) || status=$?
    [[ $status -eq 4 ]] || return 1
    jq -e '.healthy == false and .error == "Invalid host configuration"' <<< "$result" >/dev/null
}

invalid_fields() {
    printf '{"hosts":{"local":%s}}\n' "$1" > "$DSR_HOSTS_FILE"
    invalid_yaml "$(cat "$DSR_HOSTS_FILE")"
}

invalid_beats_cache() {
    command -v go >/dev/null 2>&1 || return 1
    host_health_check local --json > /dev/null || return 1
    [[ -s "$(_hh_cache_file local)" ]] || return 1
    invalid_yaml 'hosts: [broken'
}

cache_fingerprint() {
    local config baseline changed fingerprint
    config=$(_hh_get_host_config local) || return 1
    baseline=$(_hh_admission_fingerprint "$config") || return 1
    [[ "$baseline" =~ ^[0-9a-f]{64}$ ]] || return 1
    fingerprint=$(_hh_admission_fingerprint "$(jq 'to_entries | reverse | from_entries' <<< "$config")") || return 1
    [[ "$baseline" == "$fingerprint" ]] || return 1
    for change in '.ssh_host = "new-route.invalid"' '.connection = "ssh"' \
        '.platform = "linux/arm64"' '.capabilities = ["rust"]' '.enabled = false'; do
        changed=$(jq "$change" <<< "$config") || return 1
        fingerprint=$(_hh_admission_fingerprint "$changed") || return 1
        [[ "$baseline" != "$fingerprint" ]] || return 1
    done
    _HH_DISK_ERROR_THRESHOLD=80
    fingerprint=$(_hh_admission_fingerprint "$config") || return 1
    [[ "$baseline" != "$fingerprint" ]]
}

cache_reuse() {
    local before after file held
    before=$(host_health_check local --no-cache --json) || return 1
    file=$(_hh_cache_file local) || return 1
    held="$TEST_ROOT/held-$RUN"
    ln "$file" "$held" || return 1
    after=$(host_health_check local --json) || return 1
    [[ "$after" == "$before" && "$file" -ef "$held" ]] || return 1
    jq -e '.admission_fingerprint | test("^[0-9a-f]{64}$")' <<< "$after" >/dev/null
}

cache_policy_refusal() {
    host_health_check local --json >/dev/null || return 1
    _HH_DISK_ERROR_THRESHOLD=-1
    local result status=0
    result=$(host_health_check local --json) || status=$?
    [[ $status -eq 1 ]] || return 1
    jq -e '.healthy == false and .checks.disk_space.status == "error"' <<< "$result" >/dev/null
}

cache_capability_change() {
    host_health_check local --json >/dev/null || return 1
    cat > "$DSR_HOSTS_FILE" <<'YAML'
hosts:
  local:
    platform: linux/amd64
    connection: local
YAML
    local result
    result=$(host_health_check local --json) || return 1
    jq -e '.checks.toolchains == {}' <<< "$result" >/dev/null || return 1
    ! host_health_is_ready local --require go
}

cache_legacy_refusal() {
    local original legacy result
    original=$(host_health_check local --json) || return 1
    legacy=$(jq 'del(.admission_fingerprint)' <<< "$original") || return 1
    _hh_cache_write local "$legacy" || return 1
    result=$(host_health_check local --json) || return 1
    jq -e '.admission_fingerprint | type == "string" and length == 64' <<< "$result" >/dev/null
}

cache_future_refusal() {
    host_health_check local --json >/dev/null || return 1
    touch -t 209901010000 "$(_hh_cache_file local)" || return 1
    ! _hh_cache_valid local
}

cache_atomic_writes() {
    _hh_init_cache || return 1
    local file held
    file=$(_hh_cache_file local) || return 1
    held="$TEST_ROOT/held-$RUN"
    _hh_cache_write local '{"generation":1}' || return 1
    ln "$file" "$held" || return 1
    _hh_cache_write local '{"generation":2}' || return 1
    [[ ! "$file" -ef "$held" ]] || return 1
    jq -e '.generation == 1' "$held" >/dev/null || return 1
    jq -e '.generation == 2' "$file" >/dev/null || return 1
    ! _hh_cache_write local 'broken JSON' || return 1
    ! _hh_cache_write local $'{}\n{}' || return 1
    jq -e '.generation == 2' "$file" >/dev/null || return 1
    [[ -z $(find "$_HH_CACHE_DIR" -name '.local.*' -print) ]]
}

cache_symlink_refusal() {
    _hh_init_cache || return 1
    local file victim="$TEST_ROOT/victim-$RUN"
    file=$(_hh_cache_file local) || return 1
    printf 'untouched\n' > "$victim" || return 1
    ln -s "$victim" "$file" || return 1
    ! _hh_cache_write local '{}' || return 1
    ! _hh_cache_valid local || return 1
    [[ $(cat "$victim") == untouched && -L "$file" ]]
}

cache_unavailable() {
    printf 'not a directory\n' > "$_HH_CACHE_DIR" || return 1
    local result
    result=$(host_health_check local --json) || return 1
    jq -e '.healthy == true and .checks.toolchains.go.status == "ok"' <<< "$result" >/dev/null
}

selection_error() {
    printf 'hosts: []\n' > "$DSR_HOSTS_FILE"
    reject 4 host_health_get_healthy_hosts --json
}

run_test 'normalization defaults apply only to missing fields' normal_defaults
run_test 'typed capabilities, SSH route and explicit false survive normalization' normal_values
for invalid in 'null' '[]' '{}' 'false' \
    '{"platform":"linux/amd64","enabled":"false"}' \
    '{"platform":"linux/amd64","connection":false}' \
    '{"platform":"linux/amd64","connection":"other"}' \
    '{"platform":"linux/amd64","capabilities":"go"}' \
    '{"platform":"linux/amd64","capabilities":false}' \
    '{"platform":"linux/amd64","capabilities":["go rust"]}' \
    '{"platform":"linux/amd64","capabilities":[2]}' \
    '{"platform":"linux/amd64","ssh_host":false}' \
    '{"platform":"linux/amd64","ssh_host":"-oProxyCommand=bad"}' \
    '{"platform":"linux/amd64","ssh_host":"two hosts"}' \
    '{"platform":"linux/amd64","description":{}}' \
    $'{"platform":"linux/amd64"}\n{"platform":"linux/amd64"}'; do
    run_test "reject invalid normalized input: $invalid" reject 4 _hh_normalize_host_config local "$invalid"
done
run_test 'ordinary list remains a typed capability array' simple_host
run_test 'logical host label never replaces configured SSH routing' remote_route
run_test 'host listing includes hyphenated names and excludes disabled hosts' listing
run_test 'simple fallback preserves list boundaries and enabled false' fallback_simple
run_test 'fallback refuses unresolved aliases' fallback_unsupported $'hosts:\n  local:\n    platform: linux/amd64\n    capabilities: *tools'
run_test 'fallback refuses flow collections' fallback_unsupported $'hosts:\n  local:\n    platform: linux/amd64\n    capabilities: [go]'
run_test 'fallback refuses additional YAML documents' fallback_unsupported $'hosts:\n  local:\n    platform: linux/amd64\n---\nhosts:'
run_test 'missing host is a configuration refusal' missing_host
run_test 'invalid label is rejected before cache access with valid JSON diagnostics' invalid_name
run_test 'disabled host is not build-ready' disabled
run_test 'cache identity binds canonical host configuration and admission policy' cache_fingerprint
run_test 'cache writes replace atomically and never truncate a held prior receipt' cache_atomic_writes
run_test 'linked cache destinations are neither followed nor replaced' cache_symlink_refusal
run_test 'cache paths reject traversal labels' reject 4 _hh_cache_file ../outside
run_test 'host selection propagates configuration errors instead of returning an empty success' selection_error
if command -v go >/dev/null 2>&1; then
    run_test 'real local toolchain is admitted and require-go succeeds' live_local
    run_test 'real disk probe still refuses insufficient headroom' live_disk_refusal
    run_test 'unchanged host and policy reuse the exact cache inode and receipt' cache_reuse
    run_test 'tightened disk policy cannot reuse a cached healthy decision' cache_policy_refusal
    run_test 'changed capabilities cannot reuse old build-readiness evidence' cache_capability_change
    run_test 'legacy unbound cache is replaced by fresh admission evidence' cache_legacy_refusal
    run_test 'future-dated cache is not considered fresh' cache_future_refusal
    run_test 'unavailable cache does not prevent real health probes' cache_unavailable
else
    echo 'SKIP: install Go for live local and disk-admission integration tests'
    SKIPPED=$((SKIPPED + 8))
fi
if command -v ssh >/dev/null 2>&1; then
    run_test 'real unreachable SSH destination remains rejected' live_unreachable
else
    echo 'SKIP: install an SSH client for the unreachable-host test'
    SKIPPED=$((SKIPPED + 1))
fi
if $HAVE_YQ; then
    run_test 'shared capability/host/merge aliases resolve before selection and live probing' aliases
    run_test 'malformed YAML cannot fall back to guessed defaults' invalid_yaml 'hosts: [broken'
    run_test 'dangling aliases fail configuration admission' invalid_yaml $'hosts:\n  local: *missing'
    run_test 'duplicate host keys are rejected before JSON collapse' invalid_yaml $'hosts:\n  local: {platform: linux/amd64}\n  local: {platform: linux/arm64}'
    run_test 'multiple documents are rejected without partial host output' invalid_yaml $'hosts:\n  local: {platform: linux/amd64}\n---\nhosts: {}'
    run_test 'scalar host mapping is rejected' invalid_yaml 'hosts: false'
    run_test 'invalid capability type cannot silently skip required tools' invalid_fields '{"platform":"linux/amd64","capabilities":"go"}'
    run_test 'invalid enabled type cannot silently disable or enable a host' invalid_fields '{"platform":"linux/amd64","enabled":"false"}'
    run_test 'cached success cannot bypass a later malformed configuration' invalid_beats_cache
else
    echo 'SKIP: install Mike Farah yq v4 for 9 full-YAML and alias regressions'
    SKIPPED=$((SKIPPED + 9))
fi
printf '\nHost configuration admission: %s passed, %s failed, %s skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
[[ $FAILED -eq 0 ]]
