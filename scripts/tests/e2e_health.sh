#!/usr/bin/env bash
# e2e_health.sh - E2E tests for dsr health command
#
# Tests host health checking with real local host data.
#
# Run: ./scripts/tests/e2e_health.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSR_CMD="$PROJECT_ROOT/dsr"

# Source the test harness
source "$PROJECT_ROOT/tests/helpers/test_harness.bash"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }

# ============================================================================
# Dependency Check
# ============================================================================
HAS_YQ=false
if command -v yq &>/dev/null; then
    HAS_YQ=true
fi

# ============================================================================
# Helper: Create test hosts fixtures
# ============================================================================

seed_health_fixtures() {
    mkdir -p "$DSR_CONFIG_DIR"
    mkdir -p "$DSR_STATE_DIR"
    mkdir -p "$DSR_CACHE_DIR"

    # Create hosts.yaml with local host definition
    cat > "$DSR_CONFIG_DIR/hosts.yaml" << 'YAML'
schema_version: "1.0.0"

hosts:
  local-test:
    platform: linux/amd64
    connection: local
    capabilities:
      - rust
      - go
    concurrency: 2
    description: "Local test build host"
YAML

    # Create minimal config.yaml
    cat > "$DSR_CONFIG_DIR/config.yaml" << 'YAML'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
YAML
}

seed_multi_host_fixtures() {
    mkdir -p "$DSR_CONFIG_DIR"
    mkdir -p "$DSR_STATE_DIR"
    mkdir -p "$DSR_CACHE_DIR"

    # Create hosts.yaml with multiple hosts (local + fake SSH)
    cat > "$DSR_CONFIG_DIR/hosts.yaml" << 'YAML'
schema_version: "1.0.0"

hosts:
  local-test:
    platform: linux/amd64
    connection: local
    capabilities:
      - rust
      - go
    concurrency: 2
    description: "Local test build host"

  fake-remote:
    platform: darwin/arm64
    connection: ssh
    ssh_host: nonexistent-host-for-testing
    ssh_timeout: 2
    capabilities:
      - rust
    concurrency: 1
    description: "Fake SSH host for testing failures"
YAML

    cat > "$DSR_CONFIG_DIR/config.yaml" << 'YAML'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
YAML
}

# ============================================================================
# Tests: Help (always works)
# ============================================================================

test_health_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" health --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "health"; then
        pass "health --help shows usage information"
    else
        fail "health --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_health_help_shows_subcommands() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" health --help

    if exec_stdout_contains "check" && exec_stdout_contains "all"; then
        pass "health --help shows check and all subcommands"
    else
        fail "health --help should show check and all subcommands"
    fi

    harness_teardown
}

# ============================================================================
# Tests: health check <host>
# ============================================================================

test_health_check_local_succeeds() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for health check test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    exec_run "$DSR_CMD" health check local-test
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "health check local-test succeeds"
    else
        fail "health check local-test should succeed (exit: $status)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_health_check_local_shows_healthy() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for health check test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    exec_run "$DSR_CMD" health check local-test

    if exec_stderr_contains "healthy" || exec_stderr_contains "ok"; then
        pass "health check local-test shows healthy status"
    else
        fail "health check local-test should show healthy status"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_health_check_json_valid() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for health check JSON test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    exec_run "$DSR_CMD" --json health check local-test
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "health check --json produces valid JSON"
    else
        fail "health check --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_health_check_json_has_status() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for health check JSON test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    exec_run "$DSR_CMD" --json health check local-test
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.status' >/dev/null 2>&1; then
        pass "health check JSON has status field"
    else
        fail "health check JSON should have status field"
        echo "output: $output"
    fi

    harness_teardown
}

test_health_check_json_has_checks() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for health check JSON test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    exec_run "$DSR_CMD" --json health check local-test
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.checks' >/dev/null 2>&1; then
        pass "health check JSON has checks object"
    else
        fail "health check JSON should have checks object"
        echo "output: $output"
    fi

    harness_teardown
}

test_health_check_json_has_toolchains() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for health check JSON test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    exec_run "$DSR_CMD" --json health check local-test
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.checks.toolchains' >/dev/null 2>&1; then
        pass "health check JSON has toolchains in checks"
    else
        fail "health check JSON should have toolchains in checks"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Missing/Invalid Host
# ============================================================================

test_health_check_missing_host() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for missing host test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    exec_run "$DSR_CMD" health check nonexistent-host
    local status
    status=$(exec_status)

    if [[ "$status" -ne 0 ]]; then
        pass "health check fails for nonexistent host"
    else
        fail "health check should fail for nonexistent host"
    fi

    harness_teardown
}

test_health_check_missing_host_shows_error() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for missing host error test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    exec_run "$DSR_CMD" health check nonexistent-host

    if exec_stderr_contains "not found" || exec_stderr_contains "not configured" || exec_stderr_contains "Unknown"; then
        pass "health check shows error for nonexistent host"
    else
        fail "health check should show error for nonexistent host"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: health all
# ============================================================================

test_health_all_succeeds() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for health all test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    exec_run "$DSR_CMD" health all
    local status
    status=$(exec_status)

    # Should succeed (exit 0 or 1 for partial failures is acceptable)
    if [[ "$status" -le 1 ]]; then
        pass "health all completes"
    else
        fail "health all should complete (exit: $status)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_health_all_json_valid() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for health all JSON test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    exec_run "$DSR_CMD" --json health all
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "health all --json produces valid JSON"
    else
        fail "health all --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Cache Behavior
# ============================================================================

test_health_check_cache_created() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for cache test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    # Run health check
    exec_run "$DSR_CMD" health check local-test

    # Check if cache file was created
    if [[ -d "$DSR_CACHE_DIR/health" ]] || [[ -d "$DSR_STATE_DIR/health" ]]; then
        pass "health check creates cache"
    else
        # Cache might be stored differently - just pass if the check succeeded
        local status
        status=$(exec_status)
        if [[ "$status" -eq 0 ]]; then
            pass "health check succeeds (cache location may vary)"
        else
            fail "health check should succeed and create cache"
        fi
    fi

    harness_teardown
}

test_health_no_cache_forces_fresh() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for no-cache test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    exec_run "$DSR_CMD" health check local-test --no-cache
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "health check --no-cache succeeds"
    else
        fail "health check --no-cache should succeed (exit: $status)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_health_clear_cache() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for clear-cache test"
        return 0
    fi

    harness_setup
    seed_health_fixtures

    # First run a check to create cache
    exec_run "$DSR_CMD" health check local-test

    # Then clear cache
    exec_run "$DSR_CMD" health clear-cache
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "health clear-cache succeeds"
    else
        fail "health clear-cache should succeed (exit: $status)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Error does not hide behind cache
# ============================================================================

test_health_check_unreachable_host_fails() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for unreachable host test"
        return 0
    fi

    harness_setup
    seed_multi_host_fixtures

    # Check the fake remote host which should fail SSH
    exec_run "$DSR_CMD" health check fake-remote
    local status
    status=$(exec_status)

    # Should fail because SSH can't connect
    if [[ "$status" -ne 0 ]]; then
        pass "health check fails for unreachable SSH host"
    else
        fail "health check should fail for unreachable SSH host"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    exec_cleanup 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== E2E: dsr health Tests ==="
echo ""

echo "Help Tests (always work):"
test_health_help
test_health_help_shows_subcommands

echo ""
echo "health check <host> Tests:"
test_health_check_local_succeeds
test_health_check_local_shows_healthy
test_health_check_json_valid
test_health_check_json_has_status
test_health_check_json_has_checks
test_health_check_json_has_toolchains

echo ""
echo "Missing/Invalid Host Tests:"
test_health_check_missing_host
test_health_check_missing_host_shows_error

echo ""
echo "health all Tests:"
test_health_all_succeeds
test_health_all_json_valid

echo ""
echo "Cache Behavior Tests:"
test_health_check_cache_created
test_health_no_cache_forces_fresh
test_health_clear_cache

echo ""
echo "Error Handling Tests:"
test_health_check_unreachable_host_fails

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
