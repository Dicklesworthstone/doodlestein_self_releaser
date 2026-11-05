#!/usr/bin/env bash
# Real parser/filesystem/probe regressions for GH #21. No fake yq or SSH.
# GH #51 public-capacity cases control only the external probe response;
# configuration, inventory validation, verdicts, caching and readiness are real.
# DSR_TEST_REQUIRE_YQ=1 makes an unavailable YAML parser a failing prerequisite.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo 'SKIP: jq is required' >&2; exit 3; }
TEST_ROOT=$(mktemp -d) || exit 1
trap 'if [[ "${DSR_TEST_KEEP_TEMP:-0}" == 1 ]]; then printf "Retained fixtures: %s\n" "$TEST_ROOT"; else rm -rf -- "$TEST_ROOT"; fi' EXIT
export DSR_CONFIG_DIR="$TEST_ROOT/config"
export DSR_CACHE_DIR="$TEST_ROOT/cache"
export DSR_STATE_DIR="$TEST_ROOT/state"
export DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"
export DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"
export DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
mkdir -p "$DSR_CONFIG_DIR" "$DSR_CACHE_DIR" "$DSR_STATE_DIR" || exit 1
# Run the exact same public admission matrix against an unchanged module when
# collecting a baseline; the default always exercises the checkout under test.
# shellcheck source=src/host_health.sh
source "${DSR_TEST_HOST_HEALTH_MODULE:-$PROJECT_ROOT/src/host_health.sh}"

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
    concurrency: 1
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
    # Use the actual capacity result with a valid floor above the fixture host.
    # This tests refusal, not a fabricated remote response or a filled disk.
    _HH_DISK_MIN_FREE_BYTES=9007199254740991
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
  concurrency: 1
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
    _HH_DISK_MIN_FREE_BYTES=21474836481
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
    _HH_DISK_MIN_FREE_BYTES=9007199254740991
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
    concurrency: 1
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

# Exercise selection through the real configuration, health, cache and selector
# modules. Only the external SSH transport is controlled; every contacted route
# is recorded, including failed connectivity. No real remote host is contacted.
selection_scope_fixture() {
    cat > "$DSR_HOSTS_FILE" <<'YAML'
hosts:
  primary:
    platform: linux/amd64
    connection: ssh
    ssh_host: primary-route
    concurrency: 1
    capabilities:
      - go
  backup:
    platform: linux/amd64
    connection: ssh
    ssh_host: backup-route
    concurrency: 1
    capabilities:
      - go
  other-os:
    platform: darwin/arm64
    connection: ssh
    ssh_host: other-os-route
    capabilities:
      - go
  other-tool:
    platform: linux/amd64
    connection: ssh
    ssh_host: other-tool-route
    capabilities:
      - rust
  disabled:
    platform: linux/amd64
    connection: ssh
    ssh_host: disabled-route
    enabled: false
    capabilities:
      - go
YAML
    SCOPE_TRACE="$TEST_ROOT/scope-probes-$RUN"
    SCOPE_FAILURE="${1:-backup}"
    SCOPE_DISK=$(jq -nc '{requested_paths:[],roles:(["root","home","build_root","cargo_home","temp"] | map(
        . as $role | (if $role == "root" then "/" else "/fixture/" + $role end) as $path |
        {role:$role,path:$path,probe_path:$path,filesystem_id:"10",capacity_group:"filesystem:10",
         available_bytes:192199786496,total_bytes:3958241859993,usage_percent:96}))}') || return 1
    # shellcheck disable=SC2317
    _hh_run_with_timeout() {
        [[ $# -eq 11 && "$2" == ssh && "$3" == -n ]] || return 91
        local route="${10}" command="${11}"
        printf '%s\n' "$route" >> "$SCOPE_TRACE" || return 92
        case "$route" in
            primary-route|backup-route) ;;
            *) return 1 ;;
        esac
        if [[ "$SCOPE_FAILURE" == all || "$route" == "$SCOPE_FAILURE-route" ]]; then
            return 1
        fi
        case "$command" in
            'echo ok') printf 'ok\n' ;;
            *DSR_UNIX_WRITABLE_PY*)
                if [[ "$route" == primary-route && "$SCOPE_FAILURE" == low-space ]]; then
                    jq '.roles |= map(.available_bytes=2147483648)' <<< "$SCOPE_DISK"
                else
                    printf '%s\n' "$SCOPE_DISK"
                fi
                ;;
            'go version 2>/dev/null')
                [[ "$route" != primary-route || "$SCOPE_FAILURE" != missing-tool ]] || return 1
                printf 'go version go1.25.0 linux/amd64\n' ;;
            'date +%s') date +%s ;;
            *) return 93 ;;
        esac
    }
    # shellcheck source=src/host_selector.sh
    source "$PROJECT_ROOT/src/host_selector.sh"
}

selection_scope_routes() {
    [[ -f "$SCOPE_TRACE" ]] || return 1
    [[ $(LC_ALL=C sort -u "$SCOPE_TRACE") == "$1" ]]
}

selection_scope_target() {
    selection_scope_fixture || return 1
    local chosen
    chosen=$(selector_choose_host --target linux/amd64 --capability go) || return 1
    [[ "$chosen" == primary ]] || return 1
    selection_scope_routes $'backup-route\nprimary-route'
}

selection_scope_os() {
    selection_scope_fixture || return 1
    local chosen
    chosen=$(selector_choose_host --target linux/amd64) || return 1
    [[ "$chosen" == primary ]] || return 1
    selection_scope_routes $'backup-route\nother-tool-route\nprimary-route'
}

selection_scope_capability() {
    selection_scope_fixture || return 1
    local hosts
    hosts=$(host_health_get_healthy_hosts --for-capability go --json) || return 1
    [[ $(jq -c . <<< "$hosts") == '["primary"]' ]] || return 1
    selection_scope_routes $'backup-route\nother-os-route\nprimary-route'
}

selection_scope_failover() {
    selection_scope_fixture "$1" || return 1
    local chosen
    chosen=$(selector_choose_host --target linux/amd64 --capability go --prefer primary) || return 1
    [[ "$chosen" == backup ]] || return 1
    selection_scope_routes $'backup-route\nprimary-route'
}

selection_scope_unhealthy() {
    selection_scope_fixture all || return 1
    reject 1 selector_choose_host --target linux/amd64 --capability go || return 1
    selection_scope_routes $'backup-route\nprimary-route'
}

selection_scope_fleet() {
    selection_scope_fixture || return 1
    local report status=0
    report=$(host_health_check_all --json --fail-unhealthy) || status=$?
    [[ $status -eq 1 ]] || return 1
    jq -e '.summary.total == 4 and .summary.healthy == 1 and .summary.unhealthy == 3 and
        (.hosts | map(.hostname) | sort) == ["backup","other-os","other-tool","primary"]' \
        <<< "$report" >/dev/null || return 1
    selection_scope_routes $'backup-route\nother-os-route\nother-tool-route\nprimary-route'
}

selection_scope_empty() {
    selection_scope_fixture || return 1
    local hosts report
    hosts=$(host_health_get_healthy_hosts --json "$@") || return 1
    [[ $(jq -c . <<< "$hosts") == '[]' ]] || return 1
    report=$(host_health_check_all --json --fail-unhealthy "$@") || return 1
    jq -e '.hosts == [] and .summary.total == 0 and .summary.unhealthy == 0' <<< "$report" >/dev/null || return 1
    [[ ! -e "$SCOPE_TRACE" ]]
}

selection_scope_invalid_option() {
    selection_scope_fixture || return 1
    reject 4 host_health_get_healthy_hosts --json "$@" || return 1
    reject 4 host_health_check_all --json "$@" || return 1
    [[ ! -e "$SCOPE_TRACE" ]]
}

selection_scope_invalid_host() {
    selection_scope_fixture || return 1
    # Append after all valid hosts so a streaming implementation would already
    # have emitted/probed candidates before discovering this unrelated error.
    printf '  invalid-elsewhere:\n    platform: darwin/arm64\n    enabled: %s\n    capabilities: go\n' \
        "$1" >> "$DSR_HOSTS_FILE" || return 1
    reject 4 selector_choose_host --target linux/amd64 --capability go || return 1
    [[ ! -e "$SCOPE_TRACE" ]]
}

selection_scope_aliases() {
    selection_scope_fixture || return 1
    cat > "$DSR_HOSTS_FILE" <<'YAML'
go-tools: &go_tools
  - go
hosts:
  primary:
    platform: linux/amd64
    connection: ssh
    ssh_host: primary-route
    concurrency: 1
    capabilities: *go_tools
  other-os:
    platform: darwin/arm64
    connection: ssh
    ssh_host: other-os-route
    capabilities: *go_tools
YAML
    local chosen
    chosen=$(selector_choose_host --target linux/amd64 --capability go) || return 1
    [[ "$chosen" == primary ]] || return 1
    selection_scope_routes primary-route
}

run_selection_scope_tests() {
    if ! $HAVE_YQ; then
        echo 'SKIP: install Mike Farah yq v4 for scoped selection integration tests'
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi
    run_test 'native selector probes only the requested OS and declared capability' selection_scope_target
    run_test 'OS-only selection still checks every eligible toolchain host' selection_scope_os
    run_test 'capability-only selection checks that capability on every OS' selection_scope_capability
    run_test 'unscoped fleet health still observes and reports unhealthy hosts' selection_scope_fleet
    run_test 'an unreachable preferred host routes to its healthy eligible backup' selection_scope_failover primary
    run_test 'a preferred host missing the requested tool routes to a qualified backup' selection_scope_failover missing-tool
    run_test 'a preferred host below the disk floor routes to an admitted backup' selection_scope_failover low-space
    run_test 'selection refuses when every eligible host is unreachable' selection_scope_unhealthy
    run_test 'an OS with no configured builders produces an empty inventory without probing' selection_scope_empty --for-os windows
    run_test 'an absent capability produces an empty inventory without probing' selection_scope_empty --for-capability bun
    run_test 'disjoint OS and capability scopes produce no probes' selection_scope_empty --for-os darwin --for-capability rust
    run_test 'missing OS scope fails before probing' selection_scope_invalid_option --for-os
    run_test 'empty OS scope fails before probing' selection_scope_invalid_option --for-os ''
    run_test 'an option cannot be interpreted as an OS scope' selection_scope_invalid_option --for-os --json
    run_test 'malformed OS scope fails before probing' selection_scope_invalid_option --for-os 'linux/amd64'
    run_test 'missing capability scope fails before probing' selection_scope_invalid_option --for-capability
    run_test 'empty capability scope fails before probing' selection_scope_invalid_option --for-capability ''
    run_test 'malformed capability scope fails before probing' selection_scope_invalid_option --for-capability 'go rust'
    run_test 'unknown scope option fails before probing' selection_scope_invalid_option --unknown
    run_test 'malformed out-of-scope host blocks selection before any probe' selection_scope_invalid_host true
    run_test 'malformed disabled host still blocks selection before any probe' selection_scope_invalid_host false
    run_test 'capability aliases resolve before scoped host selection' selection_scope_aliases
}

capacity_fixture() {
    local usage="$1" available="$2" slots="${3-1}"
    cat > "$DSR_HOSTS_FILE" <<'YAML'
hosts:
  capacity:
    platform: linux/amd64
    connection: local
    build_root: /fixture/build_root
YAML
    # Legacy floor cases select one build explicitly. The omitted-count cases
    # below exercise the scheduler's real default through public admission.
    if [[ "$slots" != omitted ]]; then
        printf '    concurrency: %s\n' "$slots" >> "$DSR_HOSTS_FILE"
    fi
    CAPACITY_TRACE="$TEST_ROOT/capacity-probes-$RUN"
    CAPACITY_PROBE_EXIT=0
    CAPACITY_DATA=$(jq -nc --argjson usage "$usage" --argjson available "$available" '
        {requested_paths:[],roles:(["root","home","build_root","cargo_home","temp"] | map(
            . as $role | (if $role == "root" then "/" else "/fixture/" + $role end) as $path |
            {role:$role,path:$path,probe_path:$path,filesystem_id:"10",capacity_group:"filesystem:10",
             available_bytes:$available,total_bytes:3958241859993,usage_percent:$usage}))}') || return 1
    _hh_exec_on_host() {
        [[ "$1" == capacity && "$2" == local &&
           "$4" == *"python3 -I - '/fixture/build_root'"* &&
           "$4" == *DSR_UNIX_WRITABLE_PY* ]] || return 91
        printf 'writable-probe\n' >> "$CAPACITY_TRACE" || return 92
        printf '%s\n' "$CAPACITY_DATA"
        return "$CAPACITY_PROBE_EXIT"
    }
}

capacity_outcome() {
    local usage="$1" available="$2" expected="$3" result status=0 readiness=0 human
    local slots="${4-1}" minimum="${5-21474836480}" expected_slots="${4-1}" check_slots=false
    (( $# < 4 )) || check_slots=true
    [[ "$expected_slots" != omitted ]] || expected_slots=2
    capacity_fixture "$usage" "$available" "$slots" || return 1
    result=$(host_health_check capacity --no-cache --json) || status=$?
    jq -e --arg expected "$expected" --argjson usage "$usage" --argjson available "$available" \
        --argjson minimum "$minimum" --argjson slots "$expected_slots" --argjson check_slots "$check_slots" '
        .hostname == "capacity" and .status == $expected and
        .healthy == ($expected != "error") and .errors == (if $expected == "error" then 1 else 0 end) and
        .checks.connectivity.reachable == true and .checks.disk_space.admission == "unix-writable-roles-v2" and
        (if $check_slots then .checks.disk_space.concurrent_builds == $slots else true end) and
        (.checks.disk_space.capacity_groups|length) == 1 and (.checks.disk_space.roles|length) == 5 and
        all(.checks.disk_space.roles[]; .status == $expected and .usage_percent == $usage and
            .available_bytes == $available and .min_free_bytes == $minimum)' <<< "$result" >/dev/null || return 1
    # Native writable-path requests demand a new observation even when their
    # current explicit list is empty. A cached healthy result cannot stand in.
    host_health_is_ready capacity --writable-paths '[]' || readiness=$?
    [[ $(wc -l < "$CAPACITY_TRACE") -eq 2 ]] || return 1
    if [[ "$expected" == error ]]; then
        [[ $status -eq 1 && $readiness -eq 1 ]] || return 1
        jq -e --argjson minimum "$minimum" '.warnings == 0 and
            (.checks.disk_space.error|contains(($minimum/1073741824|tostring) + " GiB required"))' \
            <<< "$result" >/dev/null
    else
        [[ $status -eq 0 && $readiness -eq 0 ]] || return 1
        jq -e '.warnings == 1' <<< "$result" >/dev/null || return 1
        human=$(_hh_print_result capacity "$result" 2>&1)
        [[ "$human" == *"root / $usage% used"* && "$human" == *"cargo_home /fixture/cargo_home"* &&
           "$human" == *"temp /fixture/temp"* && "$human" == *"GiB free: warning"* ]]
    fi
}

capacity_invalid_inventory() {
    local mode="$1" result status=0 readiness=0
    capacity_fixture 96 192199786496 || return 1
    case "$mode" in
        missing_role) CAPACITY_DATA=$(jq '.roles |= map(select(.role != "temp"))' <<< "$CAPACITY_DATA") || return 1 ;;
        malformed_count) CAPACITY_DATA=$(jq '.roles[0].available_bytes="plenty"' <<< "$CAPACITY_DATA") || return 1 ;;
        empty) CAPACITY_DATA='' ;;
        failed_probe) CAPACITY_PROBE_EXIT=23 ;;
        *) return 1 ;;
    esac
    result=$(host_health_check capacity --no-cache --json) || status=$?
    [[ $status -eq 1 ]] || return 1
    jq -e '.healthy == false and .status == "error" and .errors == 1 and
        .checks.connectivity.reachable == true and .checks.disk_space.status == "error" and
        (.checks.disk_space.error|type == "string" and length > 0)' <<< "$result" >/dev/null || return 1
    host_health_is_ready capacity --writable-paths '[]' || readiness=$?
    [[ $readiness -eq 1 && $(wc -l < "$CAPACITY_TRACE") -eq 2 ]]
}

capacity_cached_policy_change() {
    local before after status=0
    capacity_fixture 96 192199786496 || return 1
    before=$(host_health_check capacity --json) || return 1
    jq -e '.status == "warning" and .healthy == true' <<< "$before" >/dev/null || return 1
    [[ $(wc -l < "$CAPACITY_TRACE") -eq 1 ]] || return 1
    _HH_DISK_MIN_FREE_BYTES=214748364800
    after=$(host_health_check capacity --json) || status=$?
    [[ $status -eq 1 && $(wc -l < "$CAPACITY_TRACE") -eq 2 ]] || return 1
    jq -e --arg old "$(jq -r '.admission_fingerprint' <<< "$before")" '
        .healthy == false and .status == "error" and .admission_fingerprint != $old and
        all(.checks.disk_space.roles[]; .status == "error" and .min_free_bytes == 214748364800)' <<< "$after" >/dev/null || return 1
    ! host_health_is_ready capacity || return 1
    [[ $(wc -l < "$CAPACITY_TRACE") -eq 2 ]]
}

capacity_cached_concurrency_change() {
    local before after status=0
    capacity_fixture 96 192199786496 8 || return 1
    before=$(host_health_check capacity --json) || return 1
    jq -e '.status == "warning" and .healthy == true' <<< "$before" >/dev/null || return 1
    [[ $(wc -l < "$CAPACITY_TRACE") -eq 1 ]] || return 1
    # Preserve the same real cache and raw capacity while the configured
    # simultaneous build count crosses the available-space boundary.
    capacity_fixture 96 192199786496 9 || return 1
    after=$(host_health_check capacity --json) || status=$?
    if [[ $status -ne 1 ]]; then
        printf 'Nine-build admission must refuse 179 GiB; got exit %s: %s\n' "$status" \
            "$(jq -c '{status,healthy,minimum:.checks.disk_space.min_free_bytes}' <<< "$after")"
        return 1
    fi
    [[ $(wc -l < "$CAPACITY_TRACE") -eq 2 ]] || return 1
    jq -e --argjson before "$before" '
        $before.checks.disk_space.concurrent_builds == 8 and
        all($before.checks.disk_space.roles[]; .min_free_bytes == 171798691840) and
        .healthy == false and .status == "error" and .admission_fingerprint != $before.admission_fingerprint and
        .checks.disk_space.concurrent_builds == 9 and
        all(.checks.disk_space.roles[]; .status == "error" and .min_free_bytes == 193273528320)' \
        <<< "$after" >/dev/null || return 1
    ! host_health_is_ready capacity || return 1
    [[ $(wc -l < "$CAPACITY_TRACE") -eq 2 ]]
}

run_capacity_tests() {
    run_test 'public health and fresh readiness admit 96 percent usage with 179 GiB available as a warning' \
        capacity_outcome 96 192199786496 warning
    run_test 'public health and readiness keep exact-floor capacity at 100 percent usage as a warning' \
        capacity_outcome 100 21474836480 warning
    run_test 'public health and readiness refuse the reported 2.32 GiB low-space case' \
        capacity_outcome 84 2486128640 error
    run_test 'public health and readiness refuse one byte below the floor despite rounded 20 GiB display' \
        capacity_outcome 96 21474836479 error
    run_test 'public admission with an omitted slot count requires the scheduler default of 40 GiB' \
        capacity_outcome 96 21474836480 error omitted 42949672960
    run_test 'public admission with an omitted slot count accepts the exact 40 GiB floor with a warning' \
        capacity_outcome 100 42949672960 warning omitted 42949672960
    run_test 'public health and fresh readiness admit eight builds with 179 GiB available' \
        capacity_outcome 96 192199786496 warning 8 171798691840
    run_test 'public health and fresh readiness refuse nine builds with 179 GiB available' \
        capacity_outcome 96 192199786496 error 9 193273528320
    local mode
    for mode in missing_role malformed_count empty failed_probe; do
        run_test "public health and readiness refuse $mode capacity evidence" capacity_invalid_inventory "$mode"
    done
    run_test 'a tightened byte floor invalidates cached high-usage healthy admission before readiness' capacity_cached_policy_change
    run_test 'increasing concurrency from eight to nine invalidates cached admission at 179 GiB' capacity_cached_concurrency_change
}

if [[ "${1:-}" == --capacity-only ]]; then
    run_capacity_tests
    printf '\nPublic capacity admission: %s passed, %s failed\n' "$PASSED" "$FAILED"
    [[ $FAILED -eq 0 ]]
    exit $?
fi

if [[ "${1:-}" == --selection-only ]]; then
    run_selection_scope_tests
    printf '\nScoped host selection: %s passed, %s failed, %s skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
    [[ $FAILED -eq 0 ]]
    exit $?
fi

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
run_selection_scope_tests
run_capacity_tests
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
