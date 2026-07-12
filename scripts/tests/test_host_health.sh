#!/usr/bin/env bash
# test_host_health.sh - Tests for src/host_health.sh
#
# Run: ./scripts/tests/test_host_health.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }

# Setup test environment
TEMP_DIR=$(mktemp -d)
export DSR_STATE_DIR="$TEMP_DIR/state"
export DSR_CACHE_DIR="$TEMP_DIR/cache"
export DSR_CONFIG_DIR="$TEMP_DIR/config"
mkdir -p "$DSR_STATE_DIR" "$DSR_CACHE_DIR" "$DSR_CONFIG_DIR"

# Create mock hosts.yaml for testing
cat > "$DSR_CONFIG_DIR/hosts.yaml" << 'EOF'
schema_version: "1.0.0"

hosts:
  testlocal:
    platform: linux/amd64
    connection: local
    capabilities:
      - rust
      - go
      - docker
    concurrency: 2
    description: "Test local host"

  testremote:
    platform: darwin/arm64
    connection: ssh
    ssh_host: nonexistent.example.com
    ssh_timeout: 5
    capabilities:
      - rust
      - go
    concurrency: 1
    description: "Test remote host (will fail)"

platform_mapping:
  linux/amd64: testlocal
  darwin/arm64: testremote
EOF

# Create minimal config.yaml
cat > "$DSR_CONFIG_DIR/config.yaml" << 'EOF'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
EOF

export DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"
export DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"

# Source logging for the numeric-safe timestamp helper, then stub log output.
source "$PROJECT_ROOT/src/logging.sh"

# Stub logging functions
log_info() { :; }
log_warn() { :; }
log_error() { echo "ERROR: $*" >&2; }
log_debug() { :; }
export -f log_info log_warn log_error log_debug

# Source the modules
source "$PROJECT_ROOT/src/config.sh"
source "$PROJECT_ROOT/src/host_health.sh"

# ============================================================================
# Cache Tests
# ============================================================================

_test_health_result_json() {
    local hostname="$1"
    local status="$2"
    local healthy="$3"

    jq -nc \
        --arg hostname "$hostname" \
        --arg status "$status" \
        --argjson healthy "$healthy" \
        '{
            hostname: $hostname,
            platform: "linux/amd64",
            description: "test fixture",
            connection: "local",
            status: $status,
            healthy: $healthy,
            errors: (if $healthy then 0 else 1 end),
            warnings: 0,
            checks: {
                connectivity: {reachable: $healthy},
                disk_space: {status: $status, usage_percent: null},
                toolchains: {},
                docker: {},
                clock_drift: {}
            },
            checked_at: "2026-07-12T00:00:00Z"
        }'
}

test_cache_init() {
    ((TESTS_RUN++))

    _hh_init_cache

    if [[ -d "$DSR_CACHE_DIR/health" ]]; then
        pass "Cache directory created"
    else
        fail "Cache directory not created at $DSR_CACHE_DIR/health"
    fi
}

test_cache_write_and_read() {
    ((TESTS_RUN++))

    _hh_init_cache
    local test_data='{"hostname": "test", "healthy": true}'
    _hh_cache_write "testhost" "$test_data"

    local read_data
    read_data=$(_hh_cache_read "testhost")

    if [[ "$read_data" == "$test_data" ]]; then
        pass "Cache write and read works"
    else
        fail "Cache mismatch: expected '$test_data', got '$read_data'"
    fi
}

test_cache_validity() {
    ((TESTS_RUN++))

    _hh_init_cache
    _hh_cache_write "freshhost" "$(_test_health_result_json "freshhost" "ok" "true")"

    if _hh_cache_valid "freshhost"; then
        pass "Fresh cache is valid"
    else
        fail "Fresh cache should be valid"
    fi
}

test_cache_rejects_wrong_shape_or_hostname() {
    ((TESTS_RUN++))

    _hh_init_cache
    _hh_cache_write "wrongshape" '{"hostname": "wrongshape", "healthy": true}'
    _hh_cache_write "expectedhost" "$(_test_health_result_json "otherhost" "ok" "true")"

    if ! _hh_cache_valid "wrongshape" && ! _hh_cache_valid "expectedhost"; then
        pass "Cache requires the expected health-result shape and hostname"
    else
        fail "Cache should reject incomplete or mismatched health results"
    fi
}

test_cached_unhealthy_result_returns_nonzero() {
    ((TESTS_RUN++))

    _hh_init_cache
    _hh_cache_write "cachedunhealthy" "$(_test_health_result_json "cachedunhealthy" "error" "false")"

    local result status=0
    result=$(host_health_check "cachedunhealthy" --json 2>/dev/null) || status=$?

    if [[ $status -ne 0 ]] && echo "$result" | jq -e '.healthy == false and .status == "error"' &>/dev/null; then
        pass "Cached unhealthy result preserves nonzero status"
    else
        fail "Cached unhealthy result should return nonzero, got status=$status result=$result"
    fi
}

test_cache_rejects_invalid_json() {
    ((TESTS_RUN++))

    _hh_init_cache
    printf 'x' > "$(_hh_cache_file "invalidhost")"

    if ! _hh_cache_valid "invalidhost"; then
        pass "Fresh cache rejects one-byte invalid JSON"
    else
        fail "Fresh cache should reject one-byte invalid JSON"
    fi
}

test_cache_clear() {
    ((TESTS_RUN++))

    _hh_init_cache
    _hh_cache_write "clearme" '{"test": true}'

    host_health_clear_cache "clearme"

    if ! _hh_cache_valid "clearme"; then
        pass "Cache cleared successfully"
    else
        fail "Cache should be invalid after clear"
    fi
}

test_cache_clear_all() {
    ((TESTS_RUN++))

    _hh_init_cache
    _hh_cache_write "host1" '{"test": 1}'
    _hh_cache_write "host2" '{"test": 2}'

    host_health_clear_cache

    if ! _hh_cache_valid "host1" && ! _hh_cache_valid "host2"; then
        pass "All cache cleared"
    else
        fail "Not all cache cleared"
    fi
}

# ============================================================================
# Local Host Check Tests
# ============================================================================

test_standalone_source_ignores_caller_script_dir() {
    ((TESTS_RUN++))

    local result status=0
    result=$(
        SCRIPT_DIR="$TEMP_DIR/unrelated-caller" \
        DSR_CONFIG_DIR="$DSR_CONFIG_DIR" \
        DSR_CACHE_DIR="$DSR_CACHE_DIR" \
        DSR_STATE_DIR="$DSR_STATE_DIR" \
        bash -c 'source "$1/src/host_health.sh"; _get_ms_timestamp' _ "$PROJECT_ROOT" 2>&1
    ) || status=$?

    if [[ $status -eq 0 && "$result" =~ ^[0-9]+$ ]]; then
        pass "Standalone source resolves dependencies independently of caller SCRIPT_DIR"
    else
        fail "Standalone source should ignore caller SCRIPT_DIR, got status=$status result=$result"
    fi
}

test_local_connectivity() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_check_connectivity "testlocal" "local" "")

    if echo "$result" | jq -e '.reachable == true' &>/dev/null; then
        pass "Local connectivity check returns reachable"
    else
        fail "Local connectivity should always be reachable, got: $result"
    fi
}

test_remote_connectivity_handles_bsd_date_literal_nanoseconds() {
    ((TESTS_RUN++))

    local result
    result=$(
        (
            date() {
                case "${1:-}" in
                    +%s%3N) printf '1700000000%%3N\n' ;;
                    +%s) printf '1700000000\n' ;;
                    *) command date "$@" ;;
                esac
            }
            python3() { printf '1700000000123\n'; }
            _hh_run_with_timeout() { return 0; }
            _DSR_MS_TIMESTAMP_METHOD=""
            _hh_check_connectivity "testremote" "ssh" "example.invalid"
        )
    )

    if echo "$result" | jq -e '.reachable == true and (.latency_ms | type == "number")' &>/dev/null; then
        pass "Connectivity timing handles BSD date literal nanoseconds"
    else
        fail "Connectivity timing should remain numeric with BSD date, got: $result"
    fi
}

test_local_disk_space() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_check_disk_space "testlocal" "local" "")

    if echo "$result" | jq -e '.usage_percent' &>/dev/null; then
        pass "Disk space check returns usage_percent"
    else
        fail "Disk space check failed, got: $result"
    fi
}

test_local_disk_space_has_status() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_check_disk_space "testlocal" "local" "")
    local status
    status=$(echo "$result" | jq -r '.status')

    if [[ "$status" == "ok" || "$status" == "warning" || "$status" == "error" ]]; then
        pass "Disk space has valid status: $status"
    else
        fail "Disk space invalid status: $status"
    fi
}

test_disk_space_forces_kilobytes_with_512_byte_default() {
    ((TESTS_RUN++))

    local result
    result=$(
        (
            _hh_exec_on_host() {
                if [[ "$4" == *"df -Pk /"* ]]; then
                    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
                    printf '/dev/test 8388608 4194304 2097152 50%% /\n'
                else
                    printf 'Filesystem 512-blocks Used Available Capacity Mounted on\n'
                    printf '/dev/test 16777216 8388608 4194304 50%% /\n'
                fi
            }
            _hh_check_disk_space "testlocal" "local" ""
        )
    )

    if echo "$result" | jq -e '.usage_percent == 50 and .available_gb == 2' &>/dev/null; then
        pass "Disk space forces 1K blocks under a 512-byte default"
    else
        fail "Disk space should report 2 GiB from df -Pk output, got: $result"
    fi
}

test_disk_space_rejects_non_numeric_fields() {
    ((TESTS_RUN++))

    local result status=0
    result=$(
        (
            _hh_exec_on_host() {
                printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
                printf '/dev/test 8388608 4194304 invalid 50%% /\n'
            }
            _hh_check_disk_space "testlocal" "local" ""
        )
    ) || status=$?

    if [[ $status -ne 0 ]] && echo "$result" | jq -e '.status == "error" and .available_gb == null' &>/dev/null; then
        pass "Disk space rejects non-numeric fields"
    else
        fail "Disk space should reject non-numeric fields, got status=$status result=$result"
    fi
}

test_disk_space_rejects_numeric_output_from_failed_command() {
    ((TESTS_RUN++))

    local result status=0
    result=$(
        (
            _hh_exec_on_host() {
                printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
                printf '/dev/test 4194304 2097152 1048576 50%% /\n'
                return 23
            }
            _hh_check_disk_space "testlocal" "local" ""
        )
    ) || status=$?

    if [[ $status -ne 0 ]] && echo "$result" | jq -e '.status == "error" and .error == "Failed to get disk info"' &>/dev/null; then
        pass "Disk space preserves command failure despite numeric stdout"
    else
        fail "Disk space should fail when command returns nonzero, got status=$status result=$result"
    fi
}

test_human_disk_error_reports_probe_failure() {
    ((TESTS_RUN++))

    local result output
    result='{"hostname":"testlocal","platform":"linux/amd64","status":"error","healthy":false,"checks":{"connectivity":{"reachable":true},"disk_space":{"status":"error","usage_percent":null,"error":"Disk probe timed out"},"toolchains":{}}}'
    output=$(_hh_print_result "testlocal" "$result" 2>&1)

    if [[ "$output" == *"Disk probe timed out"* && "$output" != *"Disk usage >"* ]]; then
        pass "Human disk error reports the recorded probe failure"
    else
        fail "Human disk error should report recorded failure, got: $output"
    fi
}

test_local_toolchains_check() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_check_toolchains "testlocal" "local" "" "rust go docker")

    # Should at least return valid JSON with the capability keys
    if echo "$result" | jq -e 'keys | length > 0' &>/dev/null; then
        pass "Toolchain check returns valid JSON"
    else
        fail "Toolchain check failed, got: $result"
    fi
}

test_local_clock_drift() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_check_clock_drift "testlocal" "local" "")

    if echo "$result" | jq -e '.drift_seconds == 0' &>/dev/null; then
        pass "Local clock drift is 0"
    else
        fail "Local clock drift should be 0, got: $result"
    fi
}

# ============================================================================
# Full Host Health Check Tests
# ============================================================================

test_health_check_local_host() {
    ((TESTS_RUN++))

    # Clear any cached result first
    host_health_clear_cache "testlocal"

    local result
    result=$(host_health_check "testlocal" --no-cache --json 2>/dev/null)

    if echo "$result" | jq -e '.hostname == "testlocal"' &>/dev/null; then
        pass "Health check returns correct hostname"
    else
        fail "Health check hostname mismatch, got: $result"
    fi
}

test_health_check_returns_healthy_for_local() {
    ((TESTS_RUN++))

    host_health_clear_cache "testlocal"

    local result
    result=$(host_health_check "testlocal" --no-cache --json 2>/dev/null)

    if echo "$result" | jq -e '.healthy == true' &>/dev/null; then
        pass "Local host is healthy"
    else
        fail "Local host should be healthy, got: $(echo "$result" | jq '.healthy, .status')"
    fi
}

test_health_check_has_all_checks() {
    ((TESTS_RUN++))

    host_health_clear_cache "testlocal"

    local result
    result=$(host_health_check "testlocal" --no-cache --json 2>/dev/null)

    local has_connectivity has_disk has_toolchains has_clock
    has_connectivity=$(echo "$result" | jq -e '.checks.connectivity' &>/dev/null && echo "yes" || echo "no")
    has_disk=$(echo "$result" | jq -e '.checks.disk_space' &>/dev/null && echo "yes" || echo "no")
    has_toolchains=$(echo "$result" | jq -e '.checks.toolchains' &>/dev/null && echo "yes" || echo "no")
    has_clock=$(echo "$result" | jq -e '.checks.clock_drift' &>/dev/null && echo "yes" || echo "no")

    if [[ "$has_connectivity" == "yes" && "$has_disk" == "yes" && "$has_toolchains" == "yes" && "$has_clock" == "yes" ]]; then
        pass "Health check has all check categories"
    else
        fail "Missing checks: connectivity=$has_connectivity disk=$has_disk toolchains=$has_toolchains clock=$has_clock"
    fi
}

test_health_check_unknown_host() {
    ((TESTS_RUN++))

    local result
    result=$(host_health_check "nonexistent_host_xyz" --json 2>/dev/null)

    if echo "$result" | jq -e '.healthy == false' &>/dev/null; then
        pass "Unknown host returns unhealthy"
    else
        fail "Unknown host should be unhealthy, got: $result"
    fi
}

test_health_check_unreachable_host() {
    ((TESTS_RUN++))

    # testremote is configured with a nonexistent SSH host
    host_health_clear_cache "testremote"

    local result
    # This should timeout/fail since the host doesn't exist
    result=$(host_health_check "testremote" --no-cache --json 2>/dev/null)

    if echo "$result" | jq -e '.healthy == false' &>/dev/null; then
        pass "Unreachable host returns unhealthy"
    else
        fail "Unreachable host should be unhealthy, got: $result"
    fi
}

# ============================================================================
# Check All Hosts Tests
# ============================================================================

test_health_check_all_returns_summary() {
    ((TESTS_RUN++))

    local result
    result=$(host_health_check_all --json 2>/dev/null)

    if echo "$result" | jq -e '.summary.total > 0' &>/dev/null; then
        pass "Check all returns summary with total"
    else
        fail "Check all should have summary, got: $result"
    fi
}

test_health_check_all_has_hosts_array() {
    ((TESTS_RUN++))

    local result
    result=$(host_health_check_all --json 2>/dev/null)

    if echo "$result" | jq -e '.hosts | type == "array"' &>/dev/null; then
        pass "Check all has hosts array"
    else
        fail "Check all should have hosts array, got: $result"
    fi
}

# ============================================================================
# Healthy Hosts Tests
# ============================================================================

test_get_healthy_hosts() {
    ((TESTS_RUN++))

    local result
    result=$(host_health_get_healthy_hosts --json 2>/dev/null)

    # Should be a valid JSON array
    if echo "$result" | jq -e 'type == "array"' &>/dev/null; then
        pass "get_healthy_hosts returns array"
    else
        fail "get_healthy_hosts should return array, got: $result"
    fi
}

test_get_healthy_hosts_includes_local() {
    ((TESTS_RUN++))

    host_health_clear_cache "testlocal"

    local result
    result=$(host_health_get_healthy_hosts --json 2>/dev/null)

    if echo "$result" | jq -e 'map(select(. == "testlocal")) | length > 0' &>/dev/null; then
        pass "Healthy hosts includes testlocal"
    else
        fail "Healthy hosts should include testlocal, got: $result"
    fi
}

# ============================================================================
# Host Readiness Tests
# ============================================================================

test_host_is_ready_local() {
    ((TESTS_RUN++))

    host_health_clear_cache "testlocal"

    if host_health_is_ready "testlocal"; then
        pass "testlocal is ready"
    else
        fail "testlocal should be ready"
    fi
}

test_host_is_ready_unreachable() {
    ((TESTS_RUN++))

    host_health_clear_cache "testremote"

    if ! host_health_is_ready "testremote"; then
        pass "Unreachable host is not ready"
    else
        fail "Unreachable host should not be ready"
    fi
}

test_host_is_ready_unknown() {
    ((TESTS_RUN++))

    if ! host_health_is_ready "completely_unknown_host"; then
        pass "Unknown host is not ready"
    else
        fail "Unknown host should not be ready"
    fi
}

# ============================================================================
# Fallback Parser Tests
# ============================================================================

test_fallback_parser_basic() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_parse_host_fallback "testlocal")

    if echo "$result" | jq -e '.platform == "linux/amd64"' &>/dev/null; then
        pass "Fallback parser extracts platform"
    else
        fail "Fallback parser should extract platform, got: $result"
    fi
}

test_fallback_parser_connection() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_parse_host_fallback "testlocal")

    if echo "$result" | jq -e '.connection == "local"' &>/dev/null; then
        pass "Fallback parser extracts connection type"
    else
        fail "Fallback parser should extract connection, got: $result"
    fi
}

test_fallback_parser_capabilities() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_parse_host_fallback "testlocal")
    local caps
    caps=$(echo "$result" | jq -r '.capabilities')

    if [[ "$caps" == *"rust"* ]] && [[ "$caps" == *"go"* ]]; then
        pass "Fallback parser extracts capabilities"
    else
        fail "Fallback parser should extract capabilities, got: $caps"
    fi
}

test_fallback_parser_unknown_host() {
    ((TESTS_RUN++))

    if ! _hh_parse_host_fallback "this_host_does_not_exist" &>/dev/null; then
        pass "Fallback parser returns error for unknown host"
    else
        fail "Fallback parser should fail for unknown host"
    fi
}

test_fallback_list_hosts() {
    ((TESTS_RUN++))

    local hosts
    hosts=$(_hh_list_hosts_fallback | tr '\n' ' ')

    if [[ "$hosts" == *"testlocal"* ]] && [[ "$hosts" == *"testremote"* ]]; then
        pass "Fallback list returns all hosts"
    else
        fail "Fallback list should find both hosts, got: $hosts"
    fi
}

# ============================================================================
# Threshold Tests
# ============================================================================

test_disk_threshold_values() {
    ((TESTS_RUN++))

    # Verify thresholds are set
    if [[ $_HH_DISK_WARN_THRESHOLD -eq 90 ]] && [[ $_HH_DISK_ERROR_THRESHOLD -eq 95 ]]; then
        pass "Disk thresholds have expected defaults"
    else
        fail "Disk thresholds: warn=$_HH_DISK_WARN_THRESHOLD error=$_HH_DISK_ERROR_THRESHOLD"
    fi
}

test_ssh_timeout_value() {
    ((TESTS_RUN++))

    if [[ $_HH_SSH_TIMEOUT -eq 10 ]]; then
        pass "SSH timeout has expected default (10s)"
    else
        fail "SSH timeout should be 10, got: $_HH_SSH_TIMEOUT"
    fi
}

test_cache_ttl_value() {
    ((TESTS_RUN++))

    if [[ $_HH_CACHE_TTL -eq 300 ]]; then
        pass "Cache TTL has expected default (300s)"
    else
        fail "Cache TTL should be 300, got: $_HH_CACHE_TTL"
    fi
}

# ============================================================================
# Retry Logic Integration Tests
# ============================================================================

# Source build_state for retry tests
source "$PROJECT_ROOT/src/build_state.sh"

test_retry_backoff_calculation() {
    ((TESTS_RUN++))

    # shellcheck disable=SC2034  # Variable used by sourced module
    BUILD_RETRY_BASE_DELAY=1
    local delay0 delay1 delay2
    delay0=$(_build_calc_backoff 0)
    delay1=$(_build_calc_backoff 1)
    delay2=$(_build_calc_backoff 2)

    # Exponential: 1*2^0=1, 1*2^1=2, 1*2^2=4 (plus some jitter)
    if [[ "$delay0" -ge 1 ]] && [[ "$delay1" -ge "$delay0" ]] && [[ "$delay2" -ge "$delay1" ]]; then
        pass "Backoff calculation increases correctly"
    else
        fail "Backoff should increase: got $delay0, $delay1, $delay2"
    fi

    # shellcheck disable=SC2034  # Variable used by sourced module
    BUILD_RETRY_BASE_DELAY=5
}

test_retry_max_delay_cap() {
    ((TESTS_RUN++))

    BUILD_RETRY_BASE_DELAY=100
    BUILD_RETRY_MAX_DELAY=200
    local delay
    delay=$(_build_calc_backoff 5)  # 100 * 2^5 = 3200, should cap at 200

    if [[ "$delay" -le 250 ]]; then  # Allow some jitter margin
        pass "Backoff respects max delay cap"
    else
        fail "Backoff exceeded max: got $delay, max was $BUILD_RETRY_MAX_DELAY"
    fi

    BUILD_RETRY_BASE_DELAY=5
    BUILD_RETRY_MAX_DELAY=300
}

test_retry_with_success() {
    ((TESTS_RUN++))

    BUILD_RETRY_BASE_DELAY=0
    local attempt=0
    succeed_after_two() { ((attempt++)); [[ $attempt -ge 2 ]]; }

    if build_retry_with_backoff 3 succeed_after_two 2>/dev/null; then
        pass "Retry succeeds after transient failure"
    else
        fail "Retry should succeed when command eventually passes"
    fi

    # shellcheck disable=SC2034  # Variable used by sourced module
    BUILD_RETRY_BASE_DELAY=5
}

test_retry_state_recording() {
    ((TESTS_RUN++))

    build_state_init
    # shellcheck disable=SC2034  # run_id captured for debugging
    DSR_RUN_ID="test-retry-$$" build_state_create "retry-test" "v1.0.0" "trj" >/dev/null 2>&1

    build_state_update_host "retry-test" "v1.0.0" "trj" "running"
    build_state_record_retry "retry-test" "v1.0.0" "trj" 1 "SSH timeout"

    local count
    count=$(build_state_get_retry_count "retry-test" "v1.0.0" "trj")

    if [[ "$count" -eq 1 ]]; then
        pass "Retry attempt is recorded in state"
    else
        fail "Retry count should be 1, got: $count"
    fi
}

test_retry_limit_enforcement() {
    ((TESTS_RUN++))

    build_state_init
    DSR_RUN_ID="test-limit-$$" build_state_create "limit-test" "v1.0.0" "trj" >/dev/null 2>&1
    build_state_update_host "limit-test" "v1.0.0" "trj" "running"

    BUILD_RETRY_MAX=2
    build_state_record_retry "limit-test" "v1.0.0" "trj" 1 "error"
    build_state_record_retry "limit-test" "v1.0.0" "trj" 2 "error"

    if ! build_state_can_retry "limit-test" "v1.0.0" "trj"; then
        pass "Retry limit is enforced"
    else
        fail "Should not be able to retry after exceeding limit"
    fi

    # shellcheck disable=SC2034  # Variable used by sourced module
    BUILD_RETRY_MAX=3
}

test_resume_plan_generation() {
    ((TESTS_RUN++))

    build_state_init
    DSR_RUN_ID="test-resume-$$" build_state_create "resume-test" "v1.0.0" "trj,mmini" >/dev/null 2>&1
    build_state_update_status "resume-test" "v1.0.0" "running"
    build_state_update_host "resume-test" "v1.0.0" "trj" "completed"
    build_state_update_host "resume-test" "v1.0.0" "mmini" "failed"

    local plan
    plan=$(build_state_resume "resume-test" "v1.0.0")

    if echo "$plan" | jq -e '.can_resume == true' &>/dev/null; then
        local hosts_to_process
        hosts_to_process=$(echo "$plan" | jq -r '.hosts_to_process | length')
        if [[ "$hosts_to_process" -ge 1 ]]; then
            pass "Resume plan identifies hosts to process"
        else
            fail "Resume plan should have hosts to process"
        fi
    else
        fail "Resume should be possible for failed build, got: $plan"
    fi
}

test_health_check_with_retry_context() {
    ((TESTS_RUN++))

    # Test that health check results can be used in retry context
    build_state_init
    DSR_RUN_ID="test-health-retry-$$" build_state_create "health-retry" "v1.0.0" "testlocal" >/dev/null 2>&1

    host_health_clear_cache "testlocal"
    local health_result
    health_result=$(host_health_check "testlocal" --no-cache --json 2>/dev/null)

    local healthy
    healthy=$(echo "$health_result" | jq -r '.healthy')

    if [[ "$healthy" == "true" ]]; then
        build_state_update_host "health-retry" "v1.0.0" "testlocal" "completed"
        local state
        state=$(build_state_get "health-retry" "v1.0.0")
        local host_status
        host_status=$(echo "$state" | jq -r '.hosts.testlocal.status')

        if [[ "$host_status" == "completed" ]]; then
            pass "Health check integrates with build state"
        else
            fail "Build state should show completed, got: $host_status"
        fi
    else
        fail "testlocal should be healthy"
    fi
}

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== Host Health Module Tests ==="
echo ""

# Cache tests
test_cache_init
test_cache_write_and_read
test_cache_validity
test_cache_rejects_invalid_json
test_cache_rejects_wrong_shape_or_hostname
test_cached_unhealthy_result_returns_nonzero
test_cache_clear
test_cache_clear_all

# Local check tests
test_standalone_source_ignores_caller_script_dir
test_local_connectivity
test_remote_connectivity_handles_bsd_date_literal_nanoseconds
test_local_disk_space
test_local_disk_space_has_status
test_disk_space_forces_kilobytes_with_512_byte_default
test_disk_space_rejects_non_numeric_fields
test_disk_space_rejects_numeric_output_from_failed_command
test_human_disk_error_reports_probe_failure
test_local_toolchains_check
test_local_clock_drift

# Full health check tests
test_health_check_local_host
test_health_check_returns_healthy_for_local
test_health_check_has_all_checks
test_health_check_unknown_host
test_health_check_unreachable_host

# Check all tests
test_health_check_all_returns_summary
test_health_check_all_has_hosts_array

# Healthy hosts tests
test_get_healthy_hosts
test_get_healthy_hosts_includes_local

# Readiness tests
test_host_is_ready_local
test_host_is_ready_unreachable
test_host_is_ready_unknown

# Fallback parser tests
test_fallback_parser_basic
test_fallback_parser_connection
test_fallback_parser_capabilities
test_fallback_parser_unknown_host
test_fallback_list_hosts

# Threshold tests
test_disk_threshold_values
test_ssh_timeout_value
test_cache_ttl_value

# Retry logic tests
test_retry_backoff_calculation
test_retry_max_delay_cap
test_retry_with_success
test_retry_state_recording
test_retry_limit_enforcement
test_resume_plan_generation
test_health_check_with_retry_context

# Cleanup
rm -rf "$TEMP_DIR"

# Summary
echo ""
echo "=== Results ==="
echo "Tests run: $TESTS_RUN"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
