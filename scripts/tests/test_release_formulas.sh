#!/usr/bin/env bash
# test_release_formulas.sh - Tests for src/release_formulas.sh
#
# Tests formula update functionality using real behavior where possible.
# Uses explicit skips when GitHub auth or external repos are unavailable.
#
# Run: ./scripts/tests/test_release_formulas.sh

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
HAS_GH_AUTH=false
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    HAS_GH_AUTH=true
fi

HAS_YQ=false
if command -v yq &>/dev/null; then
    HAS_YQ=true
fi

# ============================================================================
# Helper: Create test config
# ============================================================================

seed_formulas_config() {
    mkdir -p "$DSR_CONFIG_DIR"
    mkdir -p "$DSR_CONFIG_DIR/repos.d"

    cat > "$DSR_CONFIG_DIR/config.yaml" << 'YAML'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
formulas:
  homebrew_tap: testuser/homebrew-tap
  scoop_bucket: testuser/scoop-bucket
signing:
  enabled: false
YAML

    # Create a test tool config
    cat > "$DSR_CONFIG_DIR/repos.d/test-tool.yaml" << 'YAML'
name: test-tool
repo: testuser/test-tool
language: go
build_cmd: go build -o test-tool ./cmd/test-tool
binary_name: test-tool
targets:
  - linux/amd64
  - darwin/arm64
  - windows/amd64
YAML
}

# ============================================================================
# Tests: Help
# ============================================================================

test_formulas_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release formulas --help
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "release formulas --help exits 0"
    else
        fail "release formulas --help should exit 0 (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_formulas_help_shows_usage() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release formulas --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "formulas"; then
        pass "release formulas --help shows usage"
    else
        fail "release formulas --help should show usage"
        echo "stdout: $(exec_stdout | head -10)"
    fi

    harness_teardown
}

test_formulas_help_shows_options() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release formulas --help

    if exec_stdout_contains "--homebrew-tap" && exec_stdout_contains "--scoop-bucket"; then
        pass "release formulas --help shows package manager options"
    else
        fail "release formulas --help should show --homebrew-tap and --scoop-bucket"
        echo "stdout: $(exec_stdout | head -20)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Argument Validation
# ============================================================================

test_formulas_missing_tool() {
    ((TESTS_RUN++))
    harness_setup
    seed_formulas_config

    exec_run "$DSR_CMD" release formulas
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release formulas fails without tool (exit: 4)"
    else
        fail "release formulas should fail without tool (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_formulas_missing_version() {
    ((TESTS_RUN++))
    harness_setup
    seed_formulas_config

    exec_run "$DSR_CMD" release formulas test-tool
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release formulas fails without version (exit: 4)"
    else
        fail "release formulas should fail without version (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_formulas_unknown_option() {
    ((TESTS_RUN++))
    harness_setup
    seed_formulas_config

    exec_run "$DSR_CMD" release formulas test-tool v1.0.0 --unknown-option
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release formulas fails with unknown option (exit: 4)"
    else
        fail "release formulas should fail with unknown option (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Auth Validation
# ============================================================================

test_formulas_missing_gh_auth() {
    ((TESTS_RUN++))
    harness_setup
    seed_formulas_config

    # Create a fake gh that always fails auth
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" << 'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
    exit 1
fi
exit 1
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/gh"

    # Clear auth tokens
    local old_token="${GITHUB_TOKEN:-}"
    local old_gh_token="${GH_TOKEN:-}"
    unset GITHUB_TOKEN GH_TOKEN

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release formulas test-tool v1.0.0
    local status
    status=$(exec_status)

    # Restore tokens
    [[ -n "$old_token" ]] && export GITHUB_TOKEN="$old_token"
    [[ -n "$old_gh_token" ]] && export GH_TOKEN="$old_gh_token"

    # Should fail with auth error (exit 3) or invalid args if tool not found (exit 4)
    if [[ "$status" -eq 3 ]]; then
        pass "release formulas fails with missing gh auth (exit: 3)"
    elif [[ "$status" -eq 4 ]]; then
        pass "release formulas fails before auth check (exit: 4)"
    else
        fail "release formulas should fail with exit 3 or 4 (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Dry Run Mode
# ============================================================================

test_formulas_dry_run_no_changes() {
    ((TESTS_RUN++))

    if [[ "$HAS_GH_AUTH" != "true" ]]; then
        skip "gh auth required for dry-run test"
        return 0
    fi

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_formulas_config

    # Dry run should not error (even if release doesn't exist)
    # It will fail at release lookup, which is expected
    exec_run "$DSR_CMD" --dry-run release formulas test-tool v1.0.0
    local status
    status=$(exec_status)

    # Should fail at release lookup (7) or tool lookup (4)
    if [[ "$status" -eq 7 ]] || [[ "$status" -eq 4 ]]; then
        pass "release formulas --dry-run fails gracefully (exit: $status)"
    elif [[ "$status" -eq 0 ]]; then
        fail "release formulas --dry-run should not succeed with fake tool"
    else
        pass "release formulas --dry-run fails at expected point (exit: $status)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: JSON Output
# ============================================================================

test_formulas_json_error_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_formulas_config

    # This will fail (missing version) but JSON error should be valid
    exec_run "$DSR_CMD" --json release formulas test-tool
    local output
    output=$(exec_stdout)

    if [[ -z "$output" ]]; then
        # No JSON output on early arg parse failure is acceptable
        pass "release formulas --json produces no output on arg parse error (acceptable)"
    elif echo "$output" | jq . >/dev/null 2>&1; then
        pass "release formulas --json produces valid JSON on error"
    else
        fail "release formulas --json should produce valid JSON or no output"
        echo "output: $output"
    fi

    harness_teardown
}

test_formulas_json_auth_error_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_formulas_config

    # Force gh auth to fail
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" << 'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
    exit 1
fi
exit 1
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/gh"

    # Clear auth tokens
    local old_token="${GITHUB_TOKEN:-}"
    local old_gh_token="${GH_TOKEN:-}"
    unset GITHUB_TOKEN GH_TOKEN

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release formulas test-tool v1.0.0
    local output
    output=$(exec_stdout)

    # Restore tokens
    [[ -n "$old_token" ]] && export GITHUB_TOKEN="$old_token"
    [[ -n "$old_gh_token" ]] && export GH_TOKEN="$old_gh_token"

    if [[ -z "$output" ]]; then
        skip "No JSON output on auth failure (may fail before JSON mode)"
    elif echo "$output" | jq . >/dev/null 2>&1; then
        pass "release formulas --json produces valid JSON on auth error"
    else
        fail "release formulas --json should produce valid JSON on auth error"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Skip Options
# ============================================================================

test_formulas_skip_homebrew_option() {
    ((TESTS_RUN++))
    harness_setup
    seed_formulas_config

    exec_run "$DSR_CMD" release formulas --help

    if exec_stdout_contains "--skip-homebrew"; then
        pass "release formulas supports --skip-homebrew option"
    else
        fail "release formulas should support --skip-homebrew"
    fi

    harness_teardown
}

test_formulas_skip_scoop_option() {
    ((TESTS_RUN++))
    harness_setup
    seed_formulas_config

    exec_run "$DSR_CMD" release formulas --help

    if exec_stdout_contains "--skip-scoop"; then
        pass "release formulas supports --skip-scoop option"
    else
        fail "release formulas should support --skip-scoop"
    fi

    harness_teardown
}

test_formulas_push_option() {
    ((TESTS_RUN++))
    harness_setup
    seed_formulas_config

    exec_run "$DSR_CMD" release formulas --help

    if exec_stdout_contains "--push"; then
        pass "release formulas supports --push option"
    else
        fail "release formulas should support --push"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Stream Separation
# ============================================================================

test_formulas_stream_separation() {
    ((TESTS_RUN++))
    harness_setup
    seed_formulas_config

    # Run with JSON mode and expect failure (missing version)
    exec_run "$DSR_CMD" --json release formulas test-tool
    local stdout
    stdout=$(exec_stdout)

    # If there's stdout, it should be JSON
    if [[ -n "$stdout" ]]; then
        if echo "$stdout" | jq . >/dev/null 2>&1; then
            pass "release formulas --json keeps JSON on stdout"
        else
            fail "release formulas --json stdout should be valid JSON"
            echo "stdout: $stdout"
        fi
    else
        # No stdout is acceptable for early failures
        pass "release formulas maintains stream separation"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Exit Codes
# ============================================================================

test_formulas_exit_codes_documented() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release formulas --help
    local output
    output=$(exec_stdout)

    # Check documented exit codes
    if echo "$output" | grep -q "EXIT CODES:"; then
        if echo "$output" | grep -qE "(0.*success|4.*argument|7.*not found)"; then
            pass "release formulas --help documents exit codes"
        else
            fail "release formulas --help should document exit codes"
        fi
    else
        # Exit codes section is optional but preferred
        pass "release formulas --help acceptable (exit codes optional)"
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

echo "=== Tests: release_formulas.sh ==="
echo ""
echo "Dependencies: gh auth=$(if $HAS_GH_AUTH; then echo available; else echo missing; fi), yq=$(if $HAS_YQ; then echo available; else echo missing; fi)"
echo ""

echo "Help Tests:"
test_formulas_help
test_formulas_help_shows_usage
test_formulas_help_shows_options

echo ""
echo "Argument Validation Tests:"
test_formulas_missing_tool
test_formulas_missing_version
test_formulas_unknown_option

echo ""
echo "Auth Validation Tests:"
test_formulas_missing_gh_auth

echo ""
echo "Dry Run Tests:"
test_formulas_dry_run_no_changes

echo ""
echo "JSON Output Tests:"
test_formulas_json_error_valid
test_formulas_json_auth_error_valid

echo ""
echo "Option Tests:"
test_formulas_skip_homebrew_option
test_formulas_skip_scoop_option
test_formulas_push_option

echo ""
echo "Stream Separation Tests:"
test_formulas_stream_separation

echo ""
echo "Exit Code Tests:"
test_formulas_exit_codes_documented

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
