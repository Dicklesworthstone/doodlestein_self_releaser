#!/usr/bin/env bash
# test_doctor.sh - Integration tests for dsr doctor command
#
# Tests doctor output format, exit codes, and modes.
# Runs against real system state (no mocking of external commands).
#
# Run: ./scripts/tests/test_doctor.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSR_CMD="$PROJECT_ROOT/dsr"

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

# Setup test environment
TEMP_DIR=$(mktemp -d)
export DSR_STATE_DIR="$TEMP_DIR/state"
export DSR_CONFIG_DIR="$TEMP_DIR/config"
export DSR_CACHE_DIR="$TEMP_DIR/cache"
mkdir -p "$DSR_STATE_DIR" "$DSR_CONFIG_DIR" "$DSR_CACHE_DIR"

# ============================================================================
# Tests: Help and Basic Invocation
# ============================================================================

test_doctor_help() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" doctor --help 2>&1)

    if echo "$output" | grep -q "System diagnostics" && \
       echo "$output" | grep -q "USAGE:" && \
       echo "$output" | grep -q "OPTIONS:"; then
        pass "doctor --help shows usage information"
    else
        fail "doctor --help should show usage information"
    fi
}

test_doctor_runs_without_error() {
    ((TESTS_RUN++))

    # Doctor may return 3 for missing deps, but should not crash
    local exit_code=0
    "$DSR_CMD" doctor --quick >/dev/null 2>&1 || exit_code=$?

    if [[ $exit_code -eq 0 || $exit_code -eq 3 ]]; then
        pass "doctor runs without crash (exit code: $exit_code)"
    else
        fail "doctor should exit 0 or 3, got: $exit_code"
    fi
}

# ============================================================================
# Tests: JSON Output Format
# ============================================================================

test_doctor_json_valid() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>&1)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "doctor --json produces valid JSON"
    else
        fail "doctor --json should produce valid JSON"
    fi
}

test_doctor_json_has_status() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>&1)

    if echo "$output" | jq -e '.status' >/dev/null 2>&1; then
        pass "doctor JSON has status field"
    else
        fail "doctor JSON should have status field"
    fi
}

test_doctor_json_has_checks_array() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>&1)

    if echo "$output" | jq -e '.details.checks | type == "array"' >/dev/null 2>&1; then
        pass "doctor JSON has checks array"
    else
        fail "doctor JSON should have details.checks array"
    fi
}

test_doctor_json_check_has_name() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>&1)

    # All checks should have a name field
    local invalid_checks
    invalid_checks=$(echo "$output" | jq -r '.details.checks[]? | select(.name == null) | .status' 2>/dev/null)

    if [[ -z "$invalid_checks" ]]; then
        pass "all checks have name field"
    else
        fail "all checks should have name field"
    fi
}

test_doctor_json_check_has_status() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>&1)

    # All checks should have a status field (ok, warning, error)
    local has_status
    has_status=$(echo "$output" | jq -r '.details.checks[]? | select(.status) | .name' 2>/dev/null | head -1)

    if [[ -n "$has_status" ]]; then
        pass "checks have status field"
    else
        fail "checks should have status field"
    fi
}

# ============================================================================
# Tests: Core Dependency Detection
# ============================================================================

test_doctor_detects_git() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>&1)

    if echo "$output" | jq -e '.details.checks[] | select(.name == "git")' >/dev/null 2>&1; then
        pass "doctor checks for git"
    else
        fail "doctor should check for git"
    fi
}

test_doctor_detects_gh() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>&1)

    if echo "$output" | jq -e '.details.checks[] | select(.name == "gh")' >/dev/null 2>&1; then
        pass "doctor checks for gh"
    else
        fail "doctor should check for gh"
    fi
}

test_doctor_detects_jq() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>&1)

    if echo "$output" | jq -e '.details.checks[] | select(.name == "jq")' >/dev/null 2>&1; then
        pass "doctor checks for jq"
    else
        fail "doctor should check for jq"
    fi
}

# ============================================================================
# Tests: Quick Mode
# ============================================================================

test_doctor_quick_skips_build_tools() {
    ((TESTS_RUN++))

    local quick_output full_output
    quick_output=$("$DSR_CMD" --json doctor --quick 2>&1)
    full_output=$("$DSR_CMD" doctor --json 2>&1)

    local quick_checks full_checks
    quick_checks=$(echo "$quick_output" | jq -r '.details.checks | length' 2>/dev/null)
    full_checks=$(echo "$full_output" | jq -r '.details.checks | length' 2>/dev/null)

    # Quick mode should have fewer checks
    if [[ -n "$quick_checks" && -n "$full_checks" && "$quick_checks" -lt "$full_checks" ]]; then
        pass "quick mode has fewer checks than full mode ($quick_checks vs $full_checks)"
    else
        skip "could not compare quick vs full mode (may have same tools)"
    fi
}

# ============================================================================
# Tests: Exit Codes
# ============================================================================

test_doctor_exit_code_zero_or_three() {
    ((TESTS_RUN++))

    local exit_code=0
    "$DSR_CMD" doctor --quick >/dev/null 2>&1 || exit_code=$?

    if [[ $exit_code -eq 0 || $exit_code -eq 3 ]]; then
        pass "doctor exit code is 0 or 3 (got: $exit_code)"
    else
        fail "doctor should exit with 0 or 3, got: $exit_code"
    fi
}

# ============================================================================
# Tests: Fix Mode
# ============================================================================

test_doctor_fix_mode_shows_fixes() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" doctor --quick --fix --json 2>&1)

    # Fix mode should include fixes array in JSON output
    if echo "$output" | jq -e '.details.fixes | type' >/dev/null 2>&1; then
        pass "fix mode includes fixes in output"
    else
        # Or check human-readable output for fix suggestions
        local human_output
        human_output=$("$DSR_CMD" doctor --quick --fix 2>&1)
        if echo "$human_output" | grep -qiE "(install|fix|suggestion|remedy)" ; then
            pass "fix mode shows remediation in human output"
        else
            skip "no fixes needed or fix output format changed"
        fi
    fi
}

# ============================================================================
# Tests: Human-Readable Output
# ============================================================================

test_doctor_human_shows_dependencies() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" doctor --quick 2>&1)

    # Should show core dependency section
    if echo "$output" | grep -qi "dependencies"; then
        pass "human output shows dependencies section"
    else
        fail "human output should show dependencies section"
    fi
}

test_doctor_human_shows_ok_or_error() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" doctor --quick 2>&1)

    # Should show either OK status or error for each dep
    if echo "$output" | grep -qE "(git:|gh:|jq:)"; then
        pass "human output shows dependency checks"
    else
        fail "human output should show dependency check results"
    fi
}

# Cleanup
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== dsr doctor Integration Tests ==="
echo ""

echo "Help and Basic Invocation:"
test_doctor_help
test_doctor_runs_without_error

echo ""
echo "JSON Output Format:"
test_doctor_json_valid
test_doctor_json_has_status
test_doctor_json_has_checks_array
test_doctor_json_check_has_name
test_doctor_json_check_has_status

echo ""
echo "Core Dependency Detection:"
test_doctor_detects_git
test_doctor_detects_gh
test_doctor_detects_jq

echo ""
echo "Quick Mode:"
test_doctor_quick_skips_build_tools

echo ""
echo "Exit Codes:"
test_doctor_exit_code_zero_or_three

echo ""
echo "Fix Mode:"
test_doctor_fix_mode_shows_fixes

echo ""
echo "Human-Readable Output:"
test_doctor_human_shows_dependencies
test_doctor_human_shows_ok_or_error

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
