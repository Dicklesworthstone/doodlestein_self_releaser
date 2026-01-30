#!/usr/bin/env bash
# e2e_repos.sh - E2E tests for dsr repos command
#
# Tests repos subcommands using real repos.yaml fixtures.
#
# Run: ./scripts/tests/e2e_repos.sh

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
# Helper: Create test repos fixtures
# ============================================================================

seed_repos_fixtures() {
    mkdir -p "$XDG_CONFIG_HOME/dsr"

    # Create repos.yaml with test tools
    cat > "$XDG_CONFIG_HOME/dsr/repos.yaml" << 'YAML'
schema_version: "1.0.0"

tools:
  test-tool:
    repo: testuser/test-tool
    local_path: /data/projects/test-tool
    language: go
    build_cmd: go build -o test-tool ./cmd/test-tool
    binary_name: test-tool
    targets:
      - linux/amd64
      - darwin/arm64
    workflow: .github/workflows/release.yml

  another-tool:
    repo: testuser/another-tool
    local_path: /data/projects/another-tool
    language: rust
    build_cmd: cargo build --release
    binary_name: another-tool
    targets:
      - linux/amd64
YAML
}

seed_empty_repos() {
    mkdir -p "$XDG_CONFIG_HOME/dsr"
    cat > "$XDG_CONFIG_HOME/dsr/repos.yaml" << 'YAML'
schema_version: "1.0.0"
tools: {}
YAML
}

seed_malformed_repos() {
    mkdir -p "$XDG_CONFIG_HOME/dsr"
    cat > "$XDG_CONFIG_HOME/dsr/repos.yaml" << 'YAML'
schema_version: "1.0.0"
tools:
  bad-tool:
    - this
    - is
    - not
    - valid
YAML
}

# ============================================================================
# Tests: Help (always works)
# ============================================================================

test_repos_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" repos --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "repos"; then
        pass "repos --help shows usage information"
    else
        fail "repos --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_repos_list_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" repos list --help

    if exec_stdout_contains "list" || exec_stdout_contains "List"; then
        pass "repos list --help shows usage"
    else
        fail "repos list --help should show usage"
    fi

    harness_teardown
}

# ============================================================================
# Tests: repos list
# ============================================================================

test_repos_list_empty() {
    ((TESTS_RUN++))
    harness_setup
    seed_empty_repos

    exec_run "$DSR_CMD" repos list
    local status
    status=$(exec_status)

    # Should succeed even with empty repos
    if [[ "$status" -eq 0 ]]; then
        pass "repos list succeeds with empty repos"
    else
        fail "repos list should succeed with empty repos (exit: $status)"
        echo "stderr: $(exec_stderr)"
    fi

    harness_teardown
}

test_repos_list_shows_tools() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_fixtures

    exec_run "$DSR_CMD" repos list

    if exec_stdout_contains "test-tool" || exec_stderr_contains "test-tool"; then
        pass "repos list shows configured tools"
    else
        fail "repos list should show configured tools"
        echo "stdout: $(exec_stdout | head -10)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_repos_list_json_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_fixtures

    exec_run "$DSR_CMD" --json repos list
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "repos list --json produces valid JSON"
    else
        fail "repos list --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: repos info
# ============================================================================

test_repos_info_shows_details() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_fixtures

    exec_run "$DSR_CMD" repos info test-tool

    # Should show tool details
    if exec_stdout_contains "test-tool" || exec_stderr_contains "test-tool"; then
        pass "repos info shows tool details"
    else
        fail "repos info should show tool details"
        echo "stdout: $(exec_stdout | head -10)"
    fi

    harness_teardown
}

test_repos_info_json_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_fixtures

    exec_run "$DSR_CMD" --json repos info test-tool
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "repos info --json produces valid JSON"
    else
        fail "repos info --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_repos_info_missing_tool() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_fixtures

    exec_run "$DSR_CMD" repos info nonexistent-tool
    local status
    status=$(exec_status)

    # Should fail for nonexistent tool
    if [[ "$status" -ne 0 ]]; then
        pass "repos info fails for nonexistent tool"
    else
        fail "repos info should fail for nonexistent tool"
    fi

    harness_teardown
}

# ============================================================================
# Tests: repos validate
# ============================================================================

test_repos_validate_valid_config() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_fixtures

    exec_run "$DSR_CMD" repos validate
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "repos validate succeeds for valid config"
    else
        fail "repos validate should succeed for valid config (exit: $status)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_repos_validate_json_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_fixtures

    exec_run "$DSR_CMD" --json repos validate
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "repos validate --json produces valid JSON"
    else
        fail "repos validate --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Error Handling
# ============================================================================

test_repos_list_no_config() {
    ((TESTS_RUN++))
    harness_setup
    # Don't create any config - XDG_CONFIG_HOME exists but no dsr dir

    exec_run "$DSR_CMD" repos list
    local status
    status=$(exec_status)

    # Should handle missing config gracefully (exit 0 or specific error)
    if [[ "$status" -eq 0 || "$status" -eq 3 ]]; then
        pass "repos list handles missing config (exit: $status)"
    else
        fail "repos list should handle missing config gracefully"
        echo "stderr: $(exec_stderr)"
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

echo "=== E2E: dsr repos Tests ==="
echo ""

echo "Help Tests (always work):"
test_repos_help
test_repos_list_help

echo ""
echo "repos list Tests:"
test_repos_list_empty
test_repos_list_shows_tools
test_repos_list_json_valid

echo ""
echo "repos info Tests:"
test_repos_info_shows_details
test_repos_info_json_valid
test_repos_info_missing_tool

echo ""
echo "repos validate Tests:"
test_repos_validate_valid_config
test_repos_validate_json_valid

echo ""
echo "Error Handling:"
test_repos_list_no_config

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
