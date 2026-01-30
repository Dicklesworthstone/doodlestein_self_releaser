#!/usr/bin/env bash
# e2e_watch.sh - E2E tests for dsr watch command
#
# Tests watch mode in two scenarios:
# 1. With real GH auth (full tests when credentials available)
# 2. Error handling tests (work in isolated XDG environment)
#
# Run: ./scripts/tests/e2e_watch.sh

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
if ! require_command gh "GitHub CLI" "Install: brew install gh OR apt install gh" 2>/dev/null; then
    echo "SKIP: gh is required for E2E watch tests"
    echo "  Install: brew install gh OR apt install gh"
    exit 0
fi

# ============================================================================
# Tests: Help (works in any environment)
# ============================================================================

test_watch_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" watch --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "watch"; then
        pass "watch --help shows usage information"
    else
        fail "watch --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_watch_help_shows_once_option() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" watch --help

    if exec_stdout_contains "--once"; then
        pass "watch --help shows --once option"
    else
        fail "watch --help should show --once option"
    fi

    harness_teardown
}

test_watch_help_shows_dry_run_option() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" watch --help

    if exec_stdout_contains "--dry-run"; then
        pass "watch --help shows --dry-run option"
    else
        fail "watch --help should show --dry-run option"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Preflight Failure Handling (isolated XDG environment)
# ============================================================================

test_watch_preflight_shows_error() {
    ((TESTS_RUN++))
    harness_setup
    # Note: In isolated XDG, gh auth will fail, so preflight fails

    exec_run timeout 30 "$DSR_CMD" watch --once --dry-run

    if exec_stderr_contains "preflight"; then
        pass "watch shows preflight message"
    else
        fail "watch should show preflight message"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_watch_preflight_failure_exits_cleanly() {
    ((TESTS_RUN++))
    harness_setup

    local start_time end_time
    start_time=$(date +%s)

    exec_run timeout 30 "$DSR_CMD" watch --once --dry-run

    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Should exit quickly on preflight failure (not hang)
    if [[ "$duration" -lt 5 ]]; then
        pass "watch exits quickly on preflight failure (${duration}s)"
    else
        fail "watch should exit quickly on preflight failure, took ${duration}s"
    fi

    harness_teardown
}

test_watch_preflight_failure_exit_code() {
    ((TESTS_RUN++))
    harness_setup

    exec_run timeout 30 "$DSR_CMD" watch --once --dry-run
    local status
    status=$(exec_status)

    # Exit code 3 = dependency error (expected when gh auth fails)
    if [[ "$status" -eq 3 ]]; then
        pass "watch returns exit code 3 on preflight failure"
    else
        fail "watch should return exit code 3 on preflight failure, got: $status"
    fi

    harness_teardown
}

test_watch_preflight_failure_json_valid() {
    ((TESTS_RUN++))
    harness_setup

    exec_run timeout 30 "$DSR_CMD" --json watch --once --dry-run
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "watch --json produces valid JSON even on preflight failure"
    else
        fail "watch --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_watch_creates_state_dir() {
    ((TESTS_RUN++))
    harness_setup

    exec_run timeout 30 "$DSR_CMD" watch --once --dry-run

    # State directory should be created even on preflight failure
    if [[ -d "$XDG_STATE_HOME/dsr" ]]; then
        pass "watch creates state directory"
    else
        fail "watch should create state directory"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Full Watch (requires real GH auth - run outside harness isolation)
# ============================================================================

# Save original XDG_CONFIG_HOME before any tests modify it
_ORIGINAL_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}"

_restore_real_xdg() {
    # Restore original XDG_CONFIG_HOME so gh auth works
    if [[ -n "$_ORIGINAL_XDG_CONFIG_HOME" ]]; then
        export XDG_CONFIG_HOME="$_ORIGINAL_XDG_CONFIG_HOME"
    else
        unset XDG_CONFIG_HOME
    fi
}

test_watch_with_real_auth() {
    ((TESTS_RUN++))
    _restore_real_xdg

    # Skip if gh auth not available in real environment
    if ! gh auth status &>/dev/null; then
        skip "gh auth not available for full watch test"
        return 0
    fi

    # Run with real GH auth (no harness isolation)
    local output status
    output=$(timeout 30 "$DSR_CMD" --json watch --once --dry-run 2>/dev/null)
    status=$?

    if [[ "$status" -eq 0 ]] && echo "$output" | jq -e '.status == "success"' >/dev/null 2>&1; then
        pass "watch --once --dry-run succeeds with real auth"
    else
        fail "watch with real auth should succeed"
        echo "exit: $status, output: $output"
    fi
}

test_watch_real_auth_json_has_details() {
    ((TESTS_RUN++))
    _restore_real_xdg

    if ! gh auth status &>/dev/null; then
        skip "gh auth not available for JSON details test"
        return 0
    fi

    local output
    output=$(timeout 30 "$DSR_CMD" --json watch --once --dry-run 2>/dev/null)

    if echo "$output" | jq -e '.details.mode == "once"' >/dev/null 2>&1; then
        pass "watch JSON has details.mode = once"
    else
        fail "watch JSON should have details.mode = once"
    fi
}

test_watch_real_auth_json_has_triggered_state() {
    ((TESTS_RUN++))
    _restore_real_xdg

    if ! gh auth status &>/dev/null; then
        skip "gh auth not available for triggered state test"
        return 0
    fi

    local output
    output=$(timeout 30 "$DSR_CMD" --json watch --once --dry-run 2>/dev/null)

    if echo "$output" | jq -e '.details.triggered_state' >/dev/null 2>&1; then
        pass "watch JSON has triggered_state"
    else
        fail "watch JSON should have triggered_state"
    fi
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

echo "=== E2E: dsr watch Tests ==="
echo ""

echo "Help Tests (always work):"
test_watch_help
test_watch_help_shows_once_option
test_watch_help_shows_dry_run_option

echo ""
echo "Preflight Failure Handling (isolated XDG):"
test_watch_preflight_shows_error
test_watch_preflight_failure_exits_cleanly
test_watch_preflight_failure_exit_code
test_watch_preflight_failure_json_valid
test_watch_creates_state_dir

echo ""
echo "Full Watch Tests (require real GH auth):"
test_watch_with_real_auth
test_watch_real_auth_json_has_details
test_watch_real_auth_json_has_triggered_state

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
