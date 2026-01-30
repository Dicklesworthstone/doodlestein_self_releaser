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

    # Clear state directory completely
    rm -rf "$XDG_STATE_HOME/dsr"/* 2>/dev/null || true

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

    rm -rf "$XDG_STATE_HOME/dsr"/* 2>/dev/null || true

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

    exec_run "$DSR_CMD" status
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "status exit code is 0"
    else
        fail "status should exit 0, got: $status"
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

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
