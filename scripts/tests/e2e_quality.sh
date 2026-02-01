#!/usr/bin/env bash
# e2e_quality.sh - E2E tests for dsr quality command
#
# Tests quality gate execution with real commands and config fixtures.
#
# Run: ./scripts/tests/e2e_quality.sh

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
# Helper: Create test repos fixtures with quality checks
# ============================================================================

seed_quality_fixtures() {
    mkdir -p "$DSR_CONFIG_DIR"

    # Create repos.yaml with test tool that has quality checks
    cat > "$DSR_CONFIG_DIR/repos.yaml" << 'YAML'
schema_version: "1.0.0"

tools:
  test-tool:
    repo: testuser/test-tool
    local_path: /tmp/test-tool
    language: go
    build_cmd: go build
    binary_name: test-tool
    checks:
      - "true"
      - "echo 'check passed'"

  failing-tool:
    repo: testuser/failing-tool
    local_path: /tmp/failing-tool
    language: rust
    build_cmd: cargo build
    binary_name: failing-tool
    checks:
      - "false"
YAML
}

seed_empty_checks_fixture() {
    mkdir -p "$DSR_CONFIG_DIR"

    cat > "$DSR_CONFIG_DIR/repos.yaml" << 'YAML'
schema_version: "1.0.0"

tools:
  no-checks-tool:
    repo: testuser/no-checks-tool
    local_path: /tmp/no-checks-tool
    language: python
    build_cmd: python setup.py build
    binary_name: no-checks-tool
YAML
}

# ============================================================================
# Tests: Help (always works)
# ============================================================================

test_quality_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" quality --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "quality"; then
        pass "quality --help shows usage information"
    else
        fail "quality --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_quality_help_shows_tool_option() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" quality --help

    if exec_stdout_contains "--tool"; then
        pass "quality --help shows --tool option"
    else
        fail "quality --help should show --tool option"
    fi

    harness_teardown
}

test_quality_help_shows_dry_run() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" quality --help

    if exec_stdout_contains "--dry-run"; then
        pass "quality --help shows --dry-run option"
    else
        fail "quality --help should show --dry-run option"
    fi

    harness_teardown
}

test_quality_help_shows_skip_checks() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" quality --help

    if exec_stdout_contains "--skip-checks"; then
        pass "quality --help shows --skip-checks option"
    else
        fail "quality --help should show --skip-checks option"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Missing Tool Error Handling
# ============================================================================

test_quality_no_tool_error() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" quality
    local status
    status=$(exec_status)

    # Should fail with exit code 4 (invalid arguments)
    if [[ "$status" -eq 4 ]]; then
        pass "quality without tool returns exit code 4"
    else
        fail "quality without tool should return exit code 4 (got: $status)"
    fi

    harness_teardown
}

test_quality_no_tool_shows_error() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" quality

    if exec_stderr_contains "required" || exec_stderr_contains "tool"; then
        pass "quality without tool shows helpful error"
    else
        fail "quality without tool should show helpful error"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_quality_missing_tool_error() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for missing tool test"
        return 0
    fi

    harness_setup
    seed_quality_fixtures

    exec_run "$DSR_CMD" quality --tool nonexistent-tool-xyz
    local status
    status=$(exec_status)

    # Nonexistent tool with no checks configured returns 0 (vacuous pass)
    if [[ "$status" -eq 0 ]]; then
        pass "quality returns 0 for tool with no checks (vacuous pass)"
    else
        fail "quality should return 0 for unknown tool with no checks (got: $status)"
    fi

    harness_teardown
}

test_quality_missing_tool_json_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_quality_fixtures

    exec_run "$DSR_CMD" --json quality --tool nonexistent-tool-xyz
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "quality --json produces valid JSON for missing tool"
    else
        fail "quality --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Dry-Run Mode
# ============================================================================

test_quality_dry_run() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for quality dry-run test"
        return 0
    fi

    harness_setup
    seed_quality_fixtures

    exec_run "$DSR_CMD" quality --tool test-tool --dry-run
    local status
    status=$(exec_status)

    # Dry-run should succeed
    if [[ "$status" -eq 0 ]]; then
        pass "quality --dry-run succeeds"
    else
        fail "quality --dry-run should succeed (exit: $status)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_quality_dry_run_shows_checks() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for dry-run checks test"
        return 0
    fi

    harness_setup
    seed_quality_fixtures

    exec_run "$DSR_CMD" quality --tool test-tool --dry-run

    # Should show the check commands
    if exec_stderr_contains "true" || exec_stderr_contains "check"; then
        pass "quality --dry-run shows check commands"
    else
        fail "quality --dry-run should show check commands"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_quality_dry_run_json_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_quality_fixtures

    exec_run "$DSR_CMD" --json quality --tool test-tool --dry-run
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "quality --dry-run --json produces valid JSON"
    else
        fail "quality --dry-run --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Skip-Checks Mode
# ============================================================================

test_quality_skip_checks() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for skip-checks test"
        return 0
    fi

    harness_setup
    seed_quality_fixtures

    exec_run "$DSR_CMD" quality --tool test-tool --skip-checks
    local status
    status=$(exec_status)

    # Skip-checks should succeed
    if [[ "$status" -eq 0 ]]; then
        pass "quality --skip-checks succeeds"
    else
        fail "quality --skip-checks should succeed (exit: $status)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_quality_skip_checks_json_has_status() {
    ((TESTS_RUN++))
    harness_setup
    seed_quality_fixtures

    exec_run "$DSR_CMD" --json quality --tool test-tool --skip-checks
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.status' >/dev/null 2>&1; then
        pass "quality --skip-checks JSON has status field"
    else
        fail "quality --skip-checks JSON should have status field"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Tool Without Checks
# ============================================================================

test_quality_no_checks_configured() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for no-checks test"
        return 0
    fi

    harness_setup
    seed_empty_checks_fixture

    exec_run "$DSR_CMD" quality --tool no-checks-tool
    local status
    status=$(exec_status)

    # Tool without checks should succeed (nothing to fail)
    if [[ "$status" -eq 0 ]]; then
        pass "quality for tool without checks succeeds"
    else
        fail "quality for tool without checks should succeed (exit: $status)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Exit Codes
# ============================================================================

test_quality_exit_code_zero_on_pass() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for exit code test"
        return 0
    fi

    harness_setup
    seed_quality_fixtures

    # test-tool has checks that all pass (true, echo)
    exec_run "$DSR_CMD" quality --tool test-tool
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "quality returns exit code 0 on pass"
    else
        fail "quality should return exit code 0 on pass (got: $status)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_quality_exit_code_nonzero_on_fail() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for failing check test"
        return 0
    fi

    harness_setup
    seed_quality_fixtures

    # failing-tool has a check that fails (false)
    exec_run "$DSR_CMD" quality --tool failing-tool
    local status
    status=$(exec_status)

    if [[ "$status" -ne 0 ]]; then
        pass "quality returns non-zero exit on failing check"
    else
        fail "quality should return non-zero on failing check"
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

echo "=== E2E: dsr quality Tests ==="
echo ""

echo "Help Tests (always work):"
test_quality_help
test_quality_help_shows_tool_option
test_quality_help_shows_dry_run
test_quality_help_shows_skip_checks

echo ""
echo "Missing Tool Error Handling:"
test_quality_no_tool_error
test_quality_no_tool_shows_error
test_quality_missing_tool_error
test_quality_missing_tool_json_valid

echo ""
echo "Dry-Run Mode:"
test_quality_dry_run
test_quality_dry_run_shows_checks
test_quality_dry_run_json_valid

echo ""
echo "Skip-Checks Mode:"
test_quality_skip_checks
test_quality_skip_checks_json_has_status

echo ""
echo "Tool Without Checks:"
test_quality_no_checks_configured

echo ""
echo "Exit Codes:"
test_quality_exit_code_zero_on_pass
test_quality_exit_code_nonzero_on_fail

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
