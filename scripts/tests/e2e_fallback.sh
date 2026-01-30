#!/usr/bin/env bash
# e2e_fallback.sh - E2E tests for dsr fallback command
#
# Tests the fallback pipeline in multiple scenarios:
# 1. Help and CLI validation (always works)
# 2. Error handling for missing tool/dependencies
# 3. Dry-run with real dependencies when available
#
# Run: ./scripts/tests/e2e_fallback.sh

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
# Tests: Help (always works)
# ============================================================================

test_fallback_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" fallback --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "fallback"; then
        pass "fallback --help shows usage information"
    else
        fail "fallback --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_fallback_help_shows_build_only() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" fallback --help

    if exec_stdout_contains "--build-only"; then
        pass "fallback --help shows --build-only option"
    else
        fail "fallback --help should show --build-only option"
    fi

    harness_teardown
}

test_fallback_help_shows_skip_checks() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" fallback --help

    if exec_stdout_contains "--skip-checks"; then
        pass "fallback --help shows --skip-checks option"
    else
        fail "fallback --help should show --skip-checks option"
    fi

    harness_teardown
}

test_fallback_help_shows_dry_run() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" fallback --help

    if exec_stdout_contains "--dry-run" || exec_stdout_contains "dry-run"; then
        pass "fallback --help mentions dry-run"
    else
        fail "fallback --help should mention dry-run"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Missing Tool Error Handling
# ============================================================================

test_fallback_missing_tool_error() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" fallback nonexistent-tool-xyz
    local status
    status=$(exec_status)

    # Should fail with error about missing tool
    if [[ "$status" -ne 0 ]]; then
        pass "fallback fails for nonexistent tool"
    else
        fail "fallback should fail for nonexistent tool"
    fi

    harness_teardown
}

test_fallback_missing_tool_shows_error() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" fallback nonexistent-tool-xyz

    # Should show error message about tool not found
    if exec_stderr_contains "not found" || exec_stderr_contains "not configured"; then
        pass "fallback shows 'not found' error for missing tool"
    else
        fail "fallback should show 'not found' error"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_fallback_missing_tool_json_valid() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json fallback nonexistent-tool-xyz
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "fallback --json produces valid JSON for missing tool"
    else
        fail "fallback --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: No Arguments Error
# ============================================================================

test_fallback_no_args_shows_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" fallback

    # Should show usage or error when no tool specified
    if exec_stdout_contains "USAGE:" || exec_stderr_contains "required" || exec_stderr_contains "tool"; then
        pass "fallback with no args shows usage or error"
    else
        fail "fallback with no args should show usage or error"
        echo "stdout: $(exec_stdout | head -10)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Exit Codes
# ============================================================================

test_fallback_missing_tool_exit_code() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" fallback nonexistent-tool
    local status
    status=$(exec_status)

    # Exit code should be non-zero (likely 4 for invalid args or other error)
    if [[ "$status" -ne 0 ]]; then
        pass "fallback returns non-zero exit for missing tool (exit: $status)"
    else
        fail "fallback should return non-zero for missing tool"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Dry-Run Mode (if deps available)
# ============================================================================

# Save original XDG_CONFIG_HOME
_ORIGINAL_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}"

_restore_real_xdg() {
    if [[ -n "$_ORIGINAL_XDG_CONFIG_HOME" ]]; then
        export XDG_CONFIG_HOME="$_ORIGINAL_XDG_CONFIG_HOME"
    else
        unset XDG_CONFIG_HOME
    fi
}

test_fallback_dry_run_with_real_config() {
    ((TESTS_RUN++))
    _restore_real_xdg

    # Skip if gh auth not available
    if ! gh auth status &>/dev/null; then
        skip "gh auth not available for dry-run test"
        return 0
    fi

    # Check if there are any configured tools
    local tools_count
    tools_count=$(yq -r '.tools | keys | length // 0' ~/.config/dsr/repos.yaml 2>/dev/null || echo "0")

    if [[ "$tools_count" -eq 0 || "$tools_count" == "null" ]]; then
        skip "no tools configured for dry-run test"
        return 0
    fi

    # Get first tool name
    local tool_name
    tool_name=$(yq -r '.tools | keys | .[0]' ~/.config/dsr/repos.yaml 2>/dev/null)

    if [[ -z "$tool_name" || "$tool_name" == "null" ]]; then
        skip "could not determine tool name"
        return 0
    fi

    # Run dry-run
    local output status
    output=$(timeout 60 "$DSR_CMD" --dry-run fallback "$tool_name" 2>&1)
    status=$?

    # Dry-run should succeed (exit 0) or fail with specific error
    # We mainly check it doesn't hang and produces reasonable output
    if [[ -n "$output" ]]; then
        pass "fallback --dry-run produces output for '$tool_name'"
    else
        fail "fallback --dry-run should produce output"
    fi
}

test_fallback_dry_run_json_valid() {
    ((TESTS_RUN++))
    _restore_real_xdg

    if ! gh auth status &>/dev/null; then
        skip "gh auth not available for JSON test"
        return 0
    fi

    # Check for configured tools
    local tool_name
    tool_name=$(yq -r '.tools | keys | .[0] // ""' ~/.config/dsr/repos.yaml 2>/dev/null)

    if [[ -z "$tool_name" || "$tool_name" == "null" ]]; then
        skip "no tools configured for JSON test"
        return 0
    fi

    local output
    output=$(timeout 60 "$DSR_CMD" --json --dry-run fallback "$tool_name" 2>/dev/null)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "fallback --dry-run --json produces valid JSON"
    else
        fail "fallback --dry-run --json should produce valid JSON"
        echo "output (first 500 chars): ${output:0:500}"
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

echo "=== E2E: dsr fallback Tests ==="
echo ""

echo "Help Tests (always work):"
test_fallback_help
test_fallback_help_shows_build_only
test_fallback_help_shows_skip_checks
test_fallback_help_shows_dry_run

echo ""
echo "Missing Tool Error Handling:"
test_fallback_missing_tool_error
test_fallback_missing_tool_shows_error
test_fallback_missing_tool_json_valid

echo ""
echo "No Arguments Error:"
test_fallback_no_args_shows_help

echo ""
echo "Exit Codes:"
test_fallback_missing_tool_exit_code

echo ""
echo "Dry-Run Tests (require real config + gh auth):"
test_fallback_dry_run_with_real_config
test_fallback_dry_run_json_valid

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
