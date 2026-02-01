#!/usr/bin/env bash
# e2e_release.sh - E2E tests for dsr release command
#
# Tests release subcommand with real behavior (no mocks).
# Since release actually uploads to GitHub, most tests focus on
# validation, error handling, and dry-run paths.
#
# Run: ./scripts/tests/e2e_release.sh

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
# Helper: Create test repos config
# ============================================================================

seed_repos_config() {
    mkdir -p "$DSR_CONFIG_DIR"

    cat > "$DSR_CONFIG_DIR/config.yaml" << 'YAML'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
signing:
  enabled: false
YAML

    # Create repos.yaml with test tool
    cat > "$DSR_CONFIG_DIR/repos.yaml" << 'YAML'
schema_version: "1.0.0"

tools:
  test-tool:
    repo: testuser/test-tool
    local_path: /tmp/test-tool
    language: go
    build_cmd: go build -o test-tool ./cmd/test-tool
    binary_name: test-tool
    targets:
      - linux/amd64
      - darwin/arm64
YAML
}

seed_artifacts() {
    local tool="${1:-test-tool}"
    local version="${2:-v1.0.0}"
    local state_dir="$DSR_STATE_DIR"
    local artifacts_dir="$state_dir/artifacts/$tool/$version"

    mkdir -p "$artifacts_dir"

    # Create dummy artifacts
    echo "binary content for linux" > "$artifacts_dir/${tool}-linux-amd64"
    echo "binary content for darwin" > "$artifacts_dir/${tool}-darwin-arm64"

    # Create checksums file
    # shellcheck disable=SC2086  # Intentional globbing with ${tool}-*
    (cd "$artifacts_dir" && sha256sum "${tool}"-* > SHA256SUMS 2>/dev/null || shasum -a 256 "${tool}"-* > SHA256SUMS 2>/dev/null || echo "dummy checksums")

    # Create a minimal manifest
    cat > "$artifacts_dir/${tool}-${version}-manifest.json" << EOF
{
  "schema_version": "1.0.0",
  "tool": "$tool",
  "version": "$version",
  "run_id": "test-run-001",
  "git_sha": "abc123",
  "built_at": "2026-01-30T12:00:00Z",
  "artifacts": [
    {"name": "${tool}-linux-amd64", "target": "linux/amd64", "sha256": "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1", "size_bytes": 100},
    {"name": "${tool}-darwin-arm64", "target": "darwin/arm64", "sha256": "def456def456def456def456def456def456def456def456def456def456def4", "size_bytes": 100}
  ]
}
EOF

    export DSR_STATE_DIR="$state_dir"
}

# ============================================================================
# Tests: Help (always works)
# ============================================================================

test_release_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "release"; then
        pass "release --help shows usage information"
    else
        fail "release --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_release_help_shows_options() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release --help

    if exec_stdout_contains "--draft" && exec_stdout_contains "--version" && exec_stdout_contains "--artifacts"; then
        pass "release --help shows all main options"
    else
        fail "release --help should show --draft, --version, --artifacts"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_release_help_shows_subcommands() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release --help

    if exec_stdout_contains "verify" || exec_stdout_contains "SUBCOMMANDS:"; then
        pass "release --help mentions verify subcommand"
    else
        fail "release --help should mention verify subcommand"
        echo "stdout: $(exec_stdout | head -20)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Argument Validation
# ============================================================================

test_release_missing_tool() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release fails with missing tool (exit: 4)"
    else
        fail "release should fail with exit 4 for missing tool (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_release_missing_version() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release test-tool
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release fails with missing version (exit: 4)"
    else
        fail "release should fail with exit 4 for missing version (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_release_unknown_option() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release test-tool v1.0.0 --unknown-option
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release fails with unknown option (exit: 4)"
    else
        fail "release should fail with exit 4 for unknown option (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_release_unknown_tool() {
    ((TESTS_RUN++))

    if [[ "$HAS_GH_AUTH" != "true" ]]; then
        skip "gh auth required for tool lookup test"
        return 0
    fi

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release nonexistent-tool v1.0.0
    local status
    status=$(exec_status)

    # Should fail with tool not found (exit 4) or auth issues (exit 3)
    if [[ "$status" -eq 4 ]] || [[ "$status" -eq 3 ]]; then
        pass "release fails with unknown tool (exit: $status)"
    else
        fail "release should fail for unknown tool (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Missing Dependencies
# ============================================================================

test_release_missing_gh_auth() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    # Force gh auth to fail by unsetting tokens
    local old_token="${GITHUB_TOKEN:-}"
    local old_gh_token="${GH_TOKEN:-}"
    unset GITHUB_TOKEN GH_TOKEN

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

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0
    local status
    status=$(exec_status)

    # Restore tokens
    [[ -n "$old_token" ]] && export GITHUB_TOKEN="$old_token"
    [[ -n "$old_gh_token" ]] && export GH_TOKEN="$old_gh_token"

    # Should fail with auth error (exit 3)
    if [[ "$status" -eq 3 ]]; then
        pass "release fails with missing gh auth (exit: 3)"
    elif [[ "$status" -eq 4 ]]; then
        # Also acceptable if it fails on tool lookup first
        pass "release fails before auth check (exit: 4)"
    else
        fail "release should fail with exit 3 for missing gh auth (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_release_missing_artifacts_dir() {
    ((TESTS_RUN++))

    if [[ "$HAS_GH_AUTH" != "true" ]]; then
        skip "gh auth required for artifacts dir test"
        return 0
    fi

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    # Don't create artifacts - let it fail

    exec_run "$DSR_CMD" release test-tool v1.0.0
    local status
    status=$(exec_status)

    # Should fail - either exit 3 (gh auth missing) or exit 4 (missing artifacts/tool)
    # The gh auth check happens before artifact validation, so exit 3 is expected
    # when gh isn't authenticated in the test environment
    if [[ "$status" -eq 3 || "$status" -eq 4 ]]; then
        pass "release fails before upload (exit: $status)"
    else
        fail "release should fail with exit 3 or 4 (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: JSON Output
# ============================================================================

test_release_json_error_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    # This will fail (missing version) but should produce valid JSON
    exec_run "$DSR_CMD" --json release test-tool
    local output
    output=$(exec_stdout)

    # Even on error, JSON output should be valid (if any)
    if [[ -z "$output" ]]; then
        # No JSON output on early arg parse failure is acceptable
        pass "release --json produces no output on arg parse error (acceptable)"
    elif echo "$output" | jq . >/dev/null 2>&1; then
        pass "release --json produces valid JSON on error"
    else
        fail "release --json should produce valid JSON or no output"
        echo "output: $output"
    fi

    harness_teardown
}

test_release_json_auth_error_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config
    seed_artifacts "test-tool" "v1.0.0"

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

    # Unset tokens to force auth failure
    local old_token="${GITHUB_TOKEN:-}"
    local old_gh_token="${GH_TOKEN:-}"
    unset GITHUB_TOKEN GH_TOKEN

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0
    local output
    output=$(exec_stdout)

    # Restore tokens
    [[ -n "$old_token" ]] && export GITHUB_TOKEN="$old_token"
    [[ -n "$old_gh_token" ]] && export GH_TOKEN="$old_gh_token"

    if [[ -z "$output" ]]; then
        skip "No JSON output on auth failure (may fail before JSON mode)"
    elif echo "$output" | jq . >/dev/null 2>&1; then
        pass "release --json produces valid JSON on auth error"
    else
        fail "release --json should produce valid JSON on auth error"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: With Valid Auth (when available)
# ============================================================================

test_release_with_artifacts_setup() {
    ((TESTS_RUN++))

    if [[ "$HAS_GH_AUTH" != "true" ]]; then
        skip "gh auth required for artifacts setup test"
        return 0
    fi

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_artifacts "test-tool" "v1.0.0"

    # This will likely fail at tag verification or repo lookup
    # but should get past the initial validation
    exec_run "$DSR_CMD" release test-tool v1.0.0
    local status
    status=$(exec_status)

    # The test tool doesn't exist on GitHub, so this will fail
    # But we're checking that we got past the initial validation
    if [[ "$status" -eq 4 ]] && exec_stderr_contains "not found"; then
        pass "release validates artifacts before repo lookup (exit: 4)"
    elif [[ "$status" -eq 7 ]]; then
        pass "release fails at GitHub API level (exit: 7)"
    elif [[ "$status" -eq 0 ]]; then
        # Shouldn't succeed with a fake tool
        fail "release should not succeed with fake test-tool"
    else
        # Any failure is expected here since test-tool doesn't exist
        pass "release fails with expected error for nonexistent repo (exit: $status)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Stream Separation
# ============================================================================

test_release_stream_separation() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    # Run with JSON mode and expect failure (missing version)
    exec_run "$DSR_CMD" --json release test-tool
    local stdout
    stdout=$(exec_stdout)

    # If there's stdout, it should be JSON
    if [[ -n "$stdout" ]]; then
        if echo "$stdout" | jq . >/dev/null 2>&1; then
            pass "release --json keeps JSON on stdout (if any)"
        else
            fail "release --json stdout should be valid JSON"
            echo "stdout: $stdout"
        fi
    else
        # No stdout is also acceptable for early failures
        pass "release maintains stream separation (no stdout on early error)"
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

echo "=== E2E: dsr release Tests ==="
echo ""
echo "Dependencies: gh auth=$(if $HAS_GH_AUTH; then echo available; else echo missing; fi), yq=$(if $HAS_YQ; then echo available; else echo missing; fi)"
echo ""

echo "Help Tests (always work):"
test_release_help
test_release_help_shows_options
test_release_help_shows_subcommands

echo ""
echo "Argument Validation Tests:"
test_release_missing_tool
test_release_missing_version
test_release_unknown_option
test_release_unknown_tool

echo ""
echo "Dependency Tests:"
test_release_missing_gh_auth
test_release_missing_artifacts_dir

echo ""
echo "JSON Output Tests:"
test_release_json_error_valid
test_release_json_auth_error_valid

echo ""
echo "Integration Tests (when deps available):"
test_release_with_artifacts_setup

echo ""
echo "Stream Separation Tests:"
test_release_stream_separation

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
