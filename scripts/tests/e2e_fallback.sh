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
# Tests: Full Pipeline (mocked act + release)
# ============================================================================

seed_fallback_repo() {
    local repo_dir="$1"

    mkdir -p "$repo_dir/.github/workflows"
    cat > "$repo_dir/.github/workflows/release.yml" << 'YAML'
name: Release
on:
  push:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo "build"
YAML

    echo "test repo" > "$repo_dir/README.md"

    git -C "$repo_dir" init -q
    git -C "$repo_dir" config user.email "test@example.com"
    git -C "$repo_dir" config user.name "Test User"
    git -C "$repo_dir" add .
    git -C "$repo_dir" commit -m "init" -q
    git -C "$repo_dir" tag "v1.2.3"
}

seed_fallback_config() {
    local repo_dir="$1"

    mkdir -p "$DSR_CONFIG_DIR/repos.d"

    cat > "$DSR_CONFIG_DIR/repos.d/test-tool.yaml" << YAML
tool_name: test-tool
repo: testuser/test-tool
local_path: "$repo_dir"
language: go
workflow: .github/workflows/release.yml
targets:
  - linux/amd64
act_job_map:
  linux/amd64: build
# Non-interactive act fails closed without a runner image mapping.
act_overrides:
  platform_image: catthehacker/ubuntu:act-latest
YAML
}

setup_fallback_mocks() {
    mock_init

    export MOCK_LOG_DIR="$_MOCK_BIN_DIR"

    mock_command_script "act" "$(cat <<'EOF'
if [[ "${1:-}" == "--version" ]]; then
  echo "act version 0.2.87"
  exit 0
fi
echo "$@" >> "$MOCK_LOG_DIR/act.calls"
artifact_dir=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--artifact-server-path" ]]; then
    artifact_dir="$arg"
    break
  fi
  prev="$arg"
done
if [[ -n "$artifact_dir" ]]; then
  mkdir -p "$artifact_dir"
  parent_dir=$(dirname "$artifact_dir")
  name="${MOCK_TOOL_NAME:-mock-tool}-linux-amd64"
  echo "artifact" > "$artifact_dir/$name"
  echo "artifact" > "$parent_dir/$name"
fi
exit 0
EOF
)"

    # A small stateful GitHub: one release (id 123, tag v1.2.3) whose asset
    # inventory holds exactly what the verified uploader POSTed, with GitHub's
    # server-side digests, so release re-verification reads real state.
    mock_command_script "gh" "$(cat <<'EOF'
echo "$@" >> "$MOCK_LOG_DIR/gh.calls"
state="$MOCK_LOG_DIR/github-state"
mkdir -p "$state"
[[ -f "$state/assets.json" ]] || echo '[]' > "$state/assets.json"
release_json() {
  jq -nc --slurpfile assets "$state/assets.json" '{
    id: 123, tag_name: "v1.2.3", name: "v1.2.3", draft: false, prerelease: false,
    upload_url: "https://uploads.github.com/repos/testuser/test-tool/releases/123/assets{?name,label}",
    html_url: "https://github.com/testuser/test-tool/releases/tag/v1.2.3", assets: $assets[0]}'
}
if [[ "$1" == "auth" && "$2" == "status" ]]; then
  echo "Logged in"
  exit 0
fi
if [[ "$1" == "auth" && "$2" == "token" ]]; then
  echo "test-token"
  exit 0
fi
if [[ "$1" == "api" ]]; then
  endpoint="$2"
  shift 2
  method=GET
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X|--method) method="$2"; shift 2 ;;
      --input) cat >/dev/null; shift 2 ;;
      *) shift ;;
    esac
  done
  page="${endpoint##*page=}"
  case "$endpoint:$method" in
    repos/testuser/test-tool/releases:POST)
      : > "$state/created"; release_json ;;
    repos/testuser/test-tool/releases/123:GET)
      release_json ;;
    repos/testuser/test-tool/releases/tags/v1.2.3:GET)
      [[ -f "$state/created" ]] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
      release_json ;;
    repos/testuser/test-tool/releases\?per_page=100\&page=*:GET)
      if [[ -f "$state/created" && "$page" == 1 ]]; then release_json | jq -c '[.]'; else echo '[]'; fi ;;
    repos/testuser/test-tool/releases/123/assets\?per_page=100\&page=*:GET)
      if [[ "$page" == 1 ]]; then cat "$state/assets.json"; else echo '[]'; fi ;;
    repos/testuser/test-tool/releases/assets/*:GET)
      cat "$state/asset-${endpoint##*/}" ;;
    *)
      echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "{}"
exit 0
EOF
)"

    # The verified uploader's curl contract: body to -o, headers to -D, the
    # HTTP status alone on stdout. The asset enters the shared inventory.
    mock_command_script "curl" "$(cat <<'EOF'
echo "$@" >> "$MOCK_LOG_DIR/curl.calls"
response="" headers="" payload="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) response="$2"; shift 2 ;;
    -D) headers="$2"; shift 2 ;;
    --data-binary) payload="${2#@}"; shift 2 ;;
    https://uploads.github.com/*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$response" && -n "$headers" && -f "$payload" && -n "$url" ]] || exit 2
state="$MOCK_LOG_DIR/github-state"
mkdir -p "$state"
[[ -f "$state/assets.json" ]] || echo '[]' > "$state/assets.json"
name="${url##*\?name=}"
name="${name//%2B/+}"
id=$(( $(jq 'length' "$state/assets.json") + 1000 ))
cp "$payload" "$state/asset-$id"
sha=$(sha256sum "$payload" | awk '{print $1}')
size=$(wc -c < "$payload" | tr -d ' ')
jq -c --arg name "$name" --argjson id "$id" --argjson size "$size" --arg sha "$sha" \
  '. + [{id: $id, name: $name, state: "uploaded", size: $size, digest: ("sha256:" + $sha)}]' \
  "$state/assets.json" > "$state/assets.next" && mv "$state/assets.next" "$state/assets.json"
jq -c '.[-1]' "$state/assets.json" > "$response"
printf 'HTTP/1.1 201 Created\r\n\r\n' > "$headers"
printf '201'
exit 0
EOF
)"

    mock_command "docker" "Docker OK" 0
}

test_fallback_pipeline_mocked() {
    ((TESTS_RUN++))
    harness_setup

    if ! command -v yq &>/dev/null; then
        skip "yq not installed - skipping mocked pipeline test"
        harness_teardown
        return 0
    fi
    if ! command -v jq &>/dev/null; then
        skip "jq not installed - skipping mocked pipeline test"
        harness_teardown
        return 0
    fi
    if ! command -v git &>/dev/null; then
        skip "git not available - skipping mocked pipeline test"
        harness_teardown
        return 0
    fi
    if ! command -v timeout &>/dev/null; then
        skip "timeout not available - skipping mocked pipeline test"
        harness_teardown
        return 0
    fi

    local repo_dir
    repo_dir="$(harness_tmpdir)/repo"
    seed_fallback_repo "$repo_dir"
    seed_fallback_config "$repo_dir"

    export MOCK_TOOL_NAME="test-tool"
    export GITHUB_TOKEN="test-token"

    local output_dir="$DSR_STATE_DIR/artifacts/fallback-test"
    export ACT_ARTIFACTS_DIR="$output_dir"

    setup_fallback_mocks

    exec_run "$DSR_CMD" --json fallback test-tool --version 1.2.3 --skip-checks --output-dir "$output_dir"

    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "fallback pipeline exits successfully with mocks"
    else
        fail "fallback pipeline should succeed with mocks (exit: $status)"
        echo "stderr: $(exec_stderr | head -20)"
    fi

    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.command == "fallback"' >/dev/null 2>&1; then
        pass "fallback --json returns envelope"
    else
        fail "fallback --json should return valid envelope"
        echo "stdout: ${output:0:300}"
    fi

    if echo "$output" | jq -e '.details.phases.build == "success" and .details.phases.release == "success"' >/dev/null 2>&1; then
        pass "fallback phases report build + release success"
    else
        fail "fallback phases should report build + release success"
        echo "stdout: ${output:0:300}"
    fi

    if echo "$output" | jq -e '.details.phases.checks == "skipped"' >/dev/null 2>&1; then
        pass "fallback reports checks skipped when --skip-checks used"
    else
        fail "fallback should report checks skipped"
    fi

    if echo "$output" | jq -e '.details.artifacts_count >= 1' >/dev/null 2>&1; then
        pass "fallback reports at least one artifact"
    else
        fail "fallback should report artifacts_count >= 1"
    fi

    local act_calls gh_calls curl_calls
    act_calls=$(mock_call_count "act")
    gh_calls=$(mock_call_count "gh")
    curl_calls=$(mock_call_count "curl")

    if [[ "$act_calls" -gt 0 ]]; then
        pass "act invoked during fallback pipeline"
    else
        fail "act should be invoked during fallback pipeline"
    fi

    if [[ "$gh_calls" -gt 0 ]]; then
        pass "gh invoked during fallback release"
    else
        fail "gh should be invoked during fallback release"
    fi

    if [[ "$curl_calls" -gt 0 ]]; then
        pass "curl invoked to upload assets"
    else
        fail "curl should be invoked to upload assets"
    fi

    harness_teardown
}

test_fallback_build_only_mocked() {
    ((TESTS_RUN++))
    harness_setup

    if ! command -v yq &>/dev/null; then
        skip "yq not installed - skipping mocked build-only test"
        harness_teardown
        return 0
    fi
    if ! command -v jq &>/dev/null; then
        skip "jq not installed - skipping mocked build-only test"
        harness_teardown
        return 0
    fi
    if ! command -v git &>/dev/null; then
        skip "git not available - skipping mocked build-only test"
        harness_teardown
        return 0
    fi
    if ! command -v timeout &>/dev/null; then
        skip "timeout not available - skipping mocked build-only test"
        harness_teardown
        return 0
    fi

    local repo_dir
    repo_dir="$(harness_tmpdir)/repo-build-only"
    seed_fallback_repo "$repo_dir"
    seed_fallback_config "$repo_dir"

    export MOCK_TOOL_NAME="test-tool"
    export GITHUB_TOKEN="test-token"

    local output_dir="$DSR_STATE_DIR/artifacts/fallback-build-only"
    export ACT_ARTIFACTS_DIR="$output_dir"

    setup_fallback_mocks

    exec_run "$DSR_CMD" --json fallback test-tool --version 1.2.3 --skip-checks --build-only --output-dir "$output_dir"

    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "fallback --build-only exits successfully with mocks"
    else
        fail "fallback --build-only should succeed with mocks (exit: $status)"
        echo "stderr: $(exec_stderr | head -20)"
    fi

    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.details.phases.build == "success" and .details.phases.release == "skipped"' >/dev/null 2>&1; then
        pass "fallback --build-only reports build success and skipped release"
    else
        fail "fallback --build-only should report build success and skipped release"
        echo "stdout: ${output:0:300}"
    fi

    local act_calls gh_calls curl_calls
    act_calls=$(mock_call_count "act")
    gh_calls=$(mock_call_count "gh")
    curl_calls=$(mock_call_count "curl")

    if [[ "$act_calls" -gt 0 ]]; then
        pass "act invoked during fallback --build-only"
    else
        fail "act should be invoked during fallback --build-only"
    fi

    if [[ "$gh_calls" -eq 0 ]]; then
        pass "fallback --build-only skips GitHub release calls"
    else
        fail "fallback --build-only should not invoke gh release calls"
    fi

    if [[ "$curl_calls" -eq 0 ]]; then
        pass "fallback --build-only skips asset uploads"
    else
        fail "fallback --build-only should not upload assets"
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
echo "Full Pipeline (mocked act + release):"
test_fallback_pipeline_mocked
test_fallback_build_only_mocked

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
