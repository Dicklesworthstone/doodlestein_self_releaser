#!/usr/bin/env bash
# e2e_status.sh - E2E tests for dsr status command
#
# Tests status output with real data sources and JSON schema validity.
# Verifies graceful handling of empty state.
#
# Run: ./scripts/tests/e2e_status.sh

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
# Tests: Help and Basic Invocation
# ============================================================================

test_status_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" status --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "status"; then
        pass "status --help shows usage information"
    else
        fail "status --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_status_runs_without_error() {
    ((TESTS_RUN++))
    harness_setup
    harness_create_config

    exec_run "$DSR_CMD" status
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "status runs without error"
    else
        fail "status should exit 0, got: $status"
        echo "stderr: $(exec_stderr)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Human-Readable Output
# ============================================================================

test_status_shows_run_id() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" status

    # Human output goes to stderr with [INFO] prefix
    if exec_stderr_contains "Run ID:"; then
        pass "status shows run ID"
    else
        fail "status should show run ID"
        echo "stderr: $(exec_stderr | head -20)"
    fi

    harness_teardown
}

test_status_shows_config_section() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" status

    # Human output goes to stderr with [INFO] prefix
    if exec_stderr_contains "Configuration:"; then
        pass "status shows configuration section"
    else
        fail "status should show configuration section"
    fi

    harness_teardown
}

test_status_shows_signing_section() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" status

    # Human output goes to stderr with [INFO] prefix
    if exec_stderr_contains "Signing:"; then
        pass "status shows signing section"
    else
        fail "status should show signing section"
    fi

    harness_teardown
}

# ============================================================================
# Tests: JSON Output
# ============================================================================

test_status_json_valid() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json status
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "status --json produces valid JSON"
    else
        fail "status --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_status_json_has_status_field() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json status
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.status' >/dev/null 2>&1; then
        pass "status JSON has status field"
    else
        fail "status JSON should have status field"
    fi

    harness_teardown
}

test_status_json_has_details() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json status
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.details' >/dev/null 2>&1; then
        pass "status JSON has details field"
    else
        fail "status JSON should have details field"
    fi

    harness_teardown
}

test_status_json_has_last_run() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json status
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.details.last_run' >/dev/null 2>&1; then
        pass "status JSON has details.last_run"
    else
        fail "status JSON should have details.last_run"
    fi

    harness_teardown
}

test_status_json_has_config() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json status
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.details.config' >/dev/null 2>&1; then
        pass "status JSON has details.config"
    else
        fail "status JSON should have details.config"
    fi

    harness_teardown
}

test_status_json_has_signing() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json status
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.details.signing' >/dev/null 2>&1; then
        pass "status JSON has details.signing"
    else
        fail "status JSON should have details.signing"
    fi

    harness_teardown
}

test_status_json_stderr_empty() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json status
    local stderr_content
    stderr_content=$(exec_stderr)

    # Stderr should be empty or contain only INFO/DEBUG messages
    # Filter out session logs
    local filtered_stderr
    filtered_stderr=$(echo "$stderr_content" | grep -v '^\[INFO\]' | grep -v '^\[DEBUG\]' | grep -v '^$' || true)

    if [[ -z "$filtered_stderr" ]]; then
        pass "status JSON has empty stderr (except INFO logs)"
    else
        fail "status JSON stderr should be empty"
        echo "stderr: $filtered_stderr"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Empty State Handling
# ============================================================================

test_status_empty_state_no_error() {
    ((TESTS_RUN++))
    harness_setup
    harness_create_config

    # Clear state directory completely
    rm -rf "${DSR_STATE_DIR:?}"/* 2>/dev/null || true

    exec_run "$DSR_CMD" status
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "status handles empty state without error"
    else
        fail "status should handle empty state gracefully (exit: $status)"
        echo "stderr: $(exec_stderr)"
    fi

    harness_teardown
}

test_status_empty_state_json_valid() {
    ((TESTS_RUN++))
    harness_setup

    rm -rf "${DSR_STATE_DIR:?}"/* 2>/dev/null || true

    exec_run "$DSR_CMD" --json status
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "status JSON valid with empty state"
    else
        fail "status JSON should be valid with empty state"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Exit Code
# ============================================================================

test_status_exit_code_zero() {
    ((TESTS_RUN++))
    harness_setup
    harness_create_config

    exec_run "$DSR_CMD" status
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "status exit code is 0 for a configured, healthy system"
    else
        fail "status should exit 0, got: $status"
    fi

    harness_teardown
}

# Contract exit codes: 3 unhealthy (no configuration), 1 degraded (the last
# command failed), with a matching overall_status and envelope status.
test_status_reports_health_in_exit_code() {
    ((TESTS_RUN++))
    harness_setup
    local problems=()

    exec_run "$DSR_CMD" --json status
    [[ "$(exec_status)" -eq 3 ]] || problems+=("no config exit $(exec_status)")
    exec_stdout | jq -e '.status == "error" and .exit_code == 3 and .details.overall_status == "error" and
        (.details.warnings | index("no configuration (run dsr config init)")) != null' >/dev/null ||
        problems+=("no-config details")

    harness_create_config
    # A usage error (exit 4) is recorded but is not a health problem.
    exec_run "$DSR_CMD" check --threshold soon
    exec_run "$DSR_CMD" --json status
    [[ "$(exec_status)" -eq 0 ]] || problems+=("usage error degraded status (exit $(exec_status))")
    exec_stdout | jq -e '.details.last_run.command == "check" and .details.last_run.exit_code == 4' >/dev/null ||
        problems+=("usage error not recorded: $(exec_stdout | jq -c '.details.last_run' 2>/dev/null)")

    # A check whose GitHub API calls fail (exit 8) is the last real command.
    export GH_RETRY_DELAY=0
    mock_command_script "gh" '[[ "$1" == auth ]] && exit 0; exit 1'
    exec_run "$DSR_CMD" check owner/repo
    local check_status
    check_status=$(exec_status)
    exec_run "$DSR_CMD" --json status
    [[ "$(exec_status)" -eq 1 ]] || problems+=("failed last command exit $(exec_status) (check exited $check_status)")
    exec_stdout | jq -e '.status == "partial" and
        .details.overall_status == "degraded" and .details.last_run.command == "check" and
        .details.last_run.exit_code == 8 and .details.last_run.status == "error"' >/dev/null ||
        problems+=("degraded details: $(exec_stdout | jq -c '.details.last_run' 2>/dev/null)")

    exec_run "$DSR_CMD" status --compact
    [[ "$(exec_status)" -eq 1 ]] && exec_stderr | grep -q '^dsr: degraded | config ok | hosts ' ||
        problems+=("compact line: $(exec_stderr | tail -1)")

    exec_run "$DSR_CMD" --json status --watch
    [[ "$(exec_status)" -eq 4 ]] || problems+=("--watch with --json exit $(exec_status)")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "status exit codes, overall_status, --compact and --watch follow the contract"
    else
        fail "status health reporting: ${problems[*]}"
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

echo "=== E2E: dsr status Tests ==="
echo ""

echo "Help and Basic Invocation:"
test_status_help
test_status_runs_without_error

echo ""
echo "Human-Readable Output:"
test_status_shows_run_id
test_status_shows_config_section
test_status_shows_signing_section

echo ""
echo "JSON Output:"
test_status_json_valid
test_status_json_has_status_field
test_status_json_has_details
test_status_json_has_last_run
test_status_json_has_config
test_status_json_has_signing
test_status_json_stderr_empty

echo ""
echo "Empty State Handling:"
test_status_empty_state_no_error
test_status_empty_state_json_valid

echo ""
echo "Exit Code:"
test_status_exit_code_zero
test_status_reports_health_in_exit_code

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
