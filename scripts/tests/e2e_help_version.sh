#!/usr/bin/env bash
# e2e_help_version.sh - E2E smoke tests for dsr help and version
#
# Tests help and version output for all commands.
# Verifies exit codes, stream separation, and JSON validity.
#
# Run: ./scripts/tests/e2e_help_version.sh

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

# Subcommands to test (all from --help output)
SUBCOMMANDS=(
    "check"
    "watch"
    "build"
    "release"
    "fallback"
    "quality"
    "repos"
    "health"
    "prune"
    "config"
    "doctor"
    "signing"
    "status"
    "version"
)

# ============================================================================
# Tests: Main Help
# ============================================================================

test_main_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --help
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "dsr --help exits with 0"
    else
        fail "dsr --help should exit 0 (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_main_help_shows_usage() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "COMMANDS:"; then
        pass "dsr --help shows USAGE and COMMANDS"
    else
        fail "dsr --help should show USAGE and COMMANDS"
        echo "stdout: $(exec_stdout | head -10)"
    fi

    harness_teardown
}

test_main_help_shows_all_subcommands() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --help
    local output
    output=$(exec_stdout)

    local missing=()
    for cmd in "${SUBCOMMANDS[@]}"; do
        if ! echo "$output" | grep -q "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "dsr --help lists all subcommands"
    else
        fail "dsr --help missing commands: ${missing[*]}"
    fi

    harness_teardown
}

test_main_help_stream_separation() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --help
    local stderr_output
    stderr_output=$(exec_stderr)

    # Help goes to stdout, stderr should be empty (unless gum is used)
    # With gum, some output may go to stderr for formatting
    if [[ -z "$stderr_output" ]] || echo "$stderr_output" | grep -q "^$"; then
        pass "dsr --help has clean stderr"
    else
        # Allow gum-related output on stderr
        if echo "$stderr_output" | grep -qE "(gum|spinner|progress)"; then
            pass "dsr --help stderr only has gum formatting"
        else
            fail "dsr --help should have clean stderr"
            echo "stderr: $stderr_output"
        fi
    fi

    harness_teardown
}

# ============================================================================
# Tests: Main Version
# ============================================================================

test_version_exits_zero() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --version
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "dsr --version exits with 0"
    else
        fail "dsr --version should exit 0 (got: $status)"
    fi

    harness_teardown
}

test_version_shows_version_string() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --version
    local output
    output=$(exec_stdout)

    # Should contain "dsr" and a version-like string (e.g., v1.0.0 or 1.0.0)
    if echo "$output" | grep -qE "(dsr|[0-9]+\.[0-9]+\.[0-9]+|v[0-9])"; then
        pass "dsr --version shows version string"
    else
        fail "dsr --version should show version string"
        echo "stdout: $output"
    fi

    harness_teardown
}

test_version_json_valid() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json --version
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "dsr --json --version produces valid JSON"
    else
        fail "dsr --json --version should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_version_json_has_version_field() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json --version
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.version // .data.version // .details.version' >/dev/null 2>&1; then
        pass "dsr --json --version has version field"
    else
        fail "dsr --json --version should have version field"
        echo "output: $output"
    fi

    harness_teardown
}

test_version_json_on_stdout_only() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json --version
    local stdout_output stderr_output
    stdout_output=$(exec_stdout)
    stderr_output=$(exec_stderr)

    # JSON should be on stdout
    if echo "$stdout_output" | jq . >/dev/null 2>&1; then
        # stderr should not contain JSON
        if [[ -z "$stderr_output" ]] || ! echo "$stderr_output" | jq . >/dev/null 2>&1; then
            pass "dsr --json --version: JSON on stdout, not stderr"
        else
            fail "JSON should not be on stderr"
        fi
    else
        fail "No valid JSON on stdout"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Subcommand Help
# ============================================================================

test_subcommand_help() {
    local cmd="$1"
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" "$cmd" --help
    local status
    status=$(exec_status)

    # Allow exit 0 or exit 4 (some commands require args and show help anyway)
    if [[ "$status" -eq 0 ]] || [[ "$status" -eq 4 ]]; then
        # Check that help-like content appears
        if exec_stdout_contains "USAGE:" || exec_stdout_contains "$cmd" || \
           exec_stderr_contains "USAGE:" || exec_stderr_contains "$cmd"; then
            pass "dsr $cmd --help shows help (exit: $status)"
        else
            fail "dsr $cmd --help should show help content"
            echo "stdout: $(exec_stdout | head -5)"
            echo "stderr: $(exec_stderr | head -5)"
        fi
    else
        fail "dsr $cmd --help should exit 0 or 4 (got: $status)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Error Handling
# ============================================================================

test_unknown_command() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" nonexistent-command
    local status
    status=$(exec_status)

    # Should fail with exit 4 (invalid args)
    if [[ "$status" -eq 4 ]]; then
        pass "dsr unknown-command exits 4"
    else
        fail "dsr unknown-command should exit 4 (got: $status)"
    fi

    harness_teardown
}

test_unknown_command_shows_error() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" nonexistent-command

    if exec_stderr_contains "unknown" || exec_stderr_contains "Unknown" || \
       exec_stderr_contains "invalid" || exec_stderr_contains "Invalid" || \
       exec_stderr_contains "not recognized"; then
        pass "dsr unknown-command shows error message"
    else
        fail "dsr unknown-command should show error on stderr"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_help_flag_with_json() {
    ((TESTS_RUN++))
    harness_setup

    # --json with --help should still show help, not JSON
    exec_run "$DSR_CMD" --json --help
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "dsr --json --help exits 0"
    else
        fail "dsr --json --help should exit 0 (got: $status)"
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

echo "=== E2E: dsr Help/Version Smoke Tests ==="
echo ""

echo "Main Help Tests:"
test_main_help
test_main_help_shows_usage
test_main_help_shows_all_subcommands
test_main_help_stream_separation

echo ""
echo "Version Tests:"
test_version_exits_zero
test_version_shows_version_string
test_version_json_valid
test_version_json_has_version_field
test_version_json_on_stdout_only

echo ""
echo "Subcommand Help Tests:"
for cmd in "${SUBCOMMANDS[@]}"; do
    test_subcommand_help "$cmd"
done

echo ""
echo "Error Handling Tests:"
test_unknown_command
test_unknown_command_shows_error
test_help_flag_with_json

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
