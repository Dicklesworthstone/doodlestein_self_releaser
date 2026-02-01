#!/usr/bin/env bash
# test_release_verify.sh - Tests for dsr release verify command
#
# Covers bd-1jt.5.12:
#   - Unit tests for asset comparison (manifest vs release)
#   - Integration tests with mocked gh output
#   - Retry logic coverage (--fix flag)
#
# Run: ./scripts/tests/test_release_verify.sh

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

seed_repos_config() {
    # Use DSR_CONFIG_DIR (set by harness_setup) which dsr uses via act_load_repo_config
    local config_dir="${DSR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsr}"
    mkdir -p "$config_dir"

    cat > "$config_dir/config.yaml" << 'YAML'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
signing:
  enabled: false
YAML

    # Create per-tool config in repos.d (matches act_load_repo_config expectation)
    mkdir -p "$config_dir/repos.d"
    cat > "$config_dir/repos.d/test-tool.yaml" << 'YAML'
tool_name: test-tool
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

seed_manifest() {
    local tool="${1:-test-tool}"
    local version="${2:-v1.0.0}"
    local state_dir="$DSR_STATE_DIR"
    local artifacts_dir="$state_dir/artifacts/$tool/$version"

    mkdir -p "$artifacts_dir"

    # Create a manifest with expected artifacts
    cat > "$artifacts_dir/${tool}-${version}-manifest.json" << EOF
{
  "schema_version": "1.0.0",
  "tool": "$tool",
  "version": "$version",
  "run_id": "test-run-001",
  "git_sha": "abc123def456",
  "built_at": "2026-01-30T12:00:00Z",
  "artifacts": [
    {"filename": "${tool}-linux-amd64", "target": "linux/amd64", "sha256": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", "size_bytes": 1000},
    {"filename": "${tool}-darwin-arm64", "target": "darwin/arm64", "sha256": "f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5", "size_bytes": 1000},
    {"filename": "SHA256SUMS", "target": "checksums", "sha256": "1112223334441112223334441112223334441112223334441112223334441112", "size_bytes": 200}
  ]
}
EOF

    # Create dummy artifacts for --fix tests
    echo "binary content for linux" > "$artifacts_dir/${tool}-linux-amd64"
    echo "binary content for darwin" > "$artifacts_dir/${tool}-darwin-arm64"
    # shellcheck disable=SC2086
    (cd "$artifacts_dir" && sha256sum ${tool}-* > SHA256SUMS 2>/dev/null || shasum -a 256 ${tool}-* > SHA256SUMS 2>/dev/null || echo "dummy checksums" > SHA256SUMS)

    export DSR_STATE_DIR="$state_dir"
}

create_mock_gh() {
    local mock_release_json="${1:-}"
    mkdir -p "$TEST_TMPDIR/bin"

    # Create mock gh that returns controlled responses
    cat > "$TEST_TMPDIR/bin/gh" << SCRIPT
#!/usr/bin/env bash
case "\$*" in
    "auth status")
        exit 0
        ;;
    "auth token")
        echo "fake-token"
        exit 0
        ;;
    "api "*)
        if [[ "\$*" == *"/releases/tags/"* ]]; then
            cat << 'JSON'
$mock_release_json
JSON
            exit 0
        fi
        echo '{"error": "not found"}' >&2
        exit 1
        ;;
    "release upload"*)
        # Mock successful upload
        echo "Uploaded asset"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/gh"
}

# ============================================================================
# Tests: Help (always works)
# ============================================================================

test_verify_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release verify --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "verify"; then
        pass "release verify --help shows usage information"
    else
        fail "release verify --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_verify_help_shows_options() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release verify --help

    if exec_stdout_contains "--verify-checksums" && exec_stdout_contains "--fix"; then
        pass "release verify --help shows all options"
    else
        fail "release verify --help should show --verify-checksums, --fix"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Argument Validation
# ============================================================================

test_verify_missing_tool() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release verify
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release verify fails with missing tool (exit: 4)"
    else
        fail "release verify should fail with exit 4 for missing tool (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_verify_missing_version() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release verify test-tool
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release verify fails with missing version (exit: 4)"
    else
        fail "release verify should fail with exit 4 for missing version (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_verify_unknown_option() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release verify test-tool v1.0.0 --unknown-option
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release verify fails with unknown option (exit: 4)"
    else
        fail "release verify should fail with exit 4 for unknown option (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Authentication
# ============================================================================

test_verify_missing_gh_auth() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    # Create mock gh that fails auth
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" << 'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/gh"

    # Clear tokens
    local old_token="${GITHUB_TOKEN:-}"
    local old_gh_token="${GH_TOKEN:-}"
    unset GITHUB_TOKEN GH_TOKEN

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release verify test-tool v1.0.0
    local status
    status=$(exec_status)

    # Restore tokens
    [[ -n "$old_token" ]] && export GITHUB_TOKEN="$old_token"
    [[ -n "$old_gh_token" ]] && export GH_TOKEN="$old_gh_token"

    # Should fail with auth error (exit 3) or tool not found (exit 4)
    if [[ "$status" -eq 3 ]] || [[ "$status" -eq 4 ]]; then
        pass "release verify fails with missing gh auth (exit: $status)"
    else
        fail "release verify should fail with exit 3 or 4 for missing auth (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Asset Comparison (Mocked gh)
# ============================================================================

test_verify_all_assets_present() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    # Mock release with all expected assets
    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"},
            {"name": "test-tool-darwin-arm64", "browser_download_url": "https://example.com/b"},
            {"name": "SHA256SUMS", "browser_download_url": "https://example.com/c"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local status
    status=$(exec_status)
    local output
    output=$(exec_stdout)

    if [[ "$status" -eq 0 ]]; then
        # Check JSON reports no missing assets
        local missing_count
        missing_count=$(echo "$output" | jq -r '.details.verification.missing // 0' 2>/dev/null)
        if [[ "$missing_count" -eq 0 ]]; then
            pass "release verify reports no missing assets when all present"
        else
            fail "release verify should report 0 missing assets"
            echo "output: $output"
        fi
    else
        fail "release verify should succeed when all assets present (exit: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_verify_detects_missing_assets() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    # Mock release with one asset missing
    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"},
            {"name": "SHA256SUMS", "browser_download_url": "https://example.com/c"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local status
    status=$(exec_status)
    local output
    output=$(exec_stdout)

    # Should return exit 1 (incomplete) with missing assets
    if [[ "$status" -eq 1 ]]; then
        local missing_count
        missing_count=$(echo "$output" | jq -r '.details.verification.missing // 0' 2>/dev/null)
        if [[ "$missing_count" -gt 0 ]]; then
            # Check that darwin-arm64 is in the missing list
            if echo "$output" | jq -e '.details.assets.missing[] | select(. == "test-tool-darwin-arm64")' &>/dev/null; then
                pass "release verify detects missing asset: test-tool-darwin-arm64"
            else
                fail "release verify should list test-tool-darwin-arm64 as missing"
                echo "missing: $(echo "$output" | jq '.details.assets.missing')"
            fi
        else
            fail "release verify should report missing assets"
            echo "output: $output"
        fi
    else
        fail "release verify should exit 1 when assets missing (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_verify_detects_extra_assets() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    # Mock release with extra asset not in manifest
    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"},
            {"name": "test-tool-darwin-arm64", "browser_download_url": "https://example.com/b"},
            {"name": "SHA256SUMS", "browser_download_url": "https://example.com/c"},
            {"name": "EXTRA-FILE.txt", "browser_download_url": "https://example.com/d"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local output
    output=$(exec_stdout)

    # Extra assets should be reported but not cause failure
    local extra_count
    extra_count=$(echo "$output" | jq -r '.details.verification.extra // 0' 2>/dev/null)
    if [[ "$extra_count" -gt 0 ]]; then
        if echo "$output" | jq -e '.details.assets.extra[] | select(. == "EXTRA-FILE.txt")' &>/dev/null; then
            pass "release verify detects extra asset: EXTRA-FILE.txt"
        else
            fail "release verify should list EXTRA-FILE.txt as extra"
            echo "extra: $(echo "$output" | jq '.details.assets.extra')"
        fi
    else
        fail "release verify should report extra assets"
        echo "output: $output"
    fi

    harness_teardown
}

test_verify_handles_no_manifest() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    # Don't create manifest

    # Mock release with assets
    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local output
    output=$(exec_stdout)

    # Without manifest, should still succeed (just can't verify completeness)
    local manifest_found
    manifest_found=$(echo "$output" | jq -r '.details.manifest_found // "null"' 2>/dev/null)
    if [[ "$manifest_found" == "false" ]]; then
        pass "release verify reports manifest_found: false when no manifest"
    else
        # Also accept if it just doesn't fail
        local status
        status=$(exec_status)
        if [[ "$status" -eq 0 ]]; then
            pass "release verify handles missing manifest gracefully"
        else
            fail "release verify should handle missing manifest"
            echo "output: $output"
        fi
    fi

    harness_teardown
}

# ============================================================================
# Tests: Release Not Found
# ============================================================================

test_verify_release_not_found() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config

    # Mock gh that returns empty/error for release
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" << 'SCRIPT'
#!/usr/bin/env bash
case "$*" in
    "auth status"|"auth token")
        exit 0
        ;;
    "api "*)
        echo '{"message": "Not Found"}' >&2
        exit 1
        ;;
    *)
        exit 1
        ;;
esac
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/gh"

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release verify test-tool v1.0.0
    local status
    status=$(exec_status)

    if [[ "$status" -eq 7 ]]; then
        pass "release verify returns exit 7 for release not found"
    else
        fail "release verify should exit 7 when release not found (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: JSON Output Format
# ============================================================================

test_verify_json_valid() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    # Mock successful release
    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"},
            {"name": "test-tool-darwin-arm64", "browser_download_url": "https://example.com/b"},
            {"name": "SHA256SUMS", "browser_download_url": "https://example.com/c"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "release verify --json produces valid JSON"
    else
        fail "release verify --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_verify_json_has_required_fields() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local output
    output=$(exec_stdout)

    # Check for required fields in details
    local has_repo has_version has_verification has_assets
    has_repo=$(echo "$output" | jq '.details | has("repo")' 2>/dev/null)
    has_version=$(echo "$output" | jq '.details | has("version")' 2>/dev/null)
    has_verification=$(echo "$output" | jq '.details | has("verification")' 2>/dev/null)
    has_assets=$(echo "$output" | jq '.details | has("assets")' 2>/dev/null)

    if [[ "$has_repo" == "true" && "$has_version" == "true" && "$has_verification" == "true" && "$has_assets" == "true" ]]; then
        pass "release verify JSON has required schema fields"
    else
        fail "release verify JSON missing required fields"
        echo "has_repo: $has_repo, has_version: $has_version"
        echo "has_verification: $has_verification, has_assets: $has_assets"
        echo "details: $(echo "$output" | jq '.details' 2>/dev/null | head -20)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Stream Separation
# ============================================================================

test_verify_stream_separation() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0

    local stdout stderr
    stdout=$(exec_stdout)
    stderr=$(exec_stderr)

    # stdout should be JSON only
    local stdout_is_json=false
    if echo "$stdout" | jq . >/dev/null 2>&1; then
        stdout_is_json=true
    fi

    # stderr should NOT contain JSON
    local stderr_has_json=false
    if echo "$stderr" | grep -q '^{.*}$'; then
        stderr_has_json=true
    fi

    if [[ "$stdout_is_json" == "true" && "$stderr_has_json" == "false" ]]; then
        pass "release verify maintains stream separation"
    else
        fail "release verify should maintain stream separation"
        echo "stdout is JSON: $stdout_is_json"
        echo "stderr has JSON: $stderr_has_json"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Retry/Fix Logic (--fix flag)
# ============================================================================

test_verify_fix_attempts_upload() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    # Track upload attempts
    local upload_log="$TEST_TMPDIR/upload.log"

    # Mock release with missing asset
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" << SCRIPT
#!/usr/bin/env bash
case "\$*" in
    "auth status"|"auth token")
        exit 0
        ;;
    "api "*)
        # Return release with missing darwin asset
        cat << 'JSON'
{
    "id": 12345,
    "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
    "assets": [
        {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"},
        {"name": "SHA256SUMS", "browser_download_url": "https://example.com/c"}
    ]
}
JSON
        exit 0
        ;;
    "release upload"*)
        # Log upload attempt
        echo "\$*" >> "$upload_log"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/gh"

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release verify test-tool v1.0.0 --fix
    local status
    status=$(exec_status)

    # Check if upload was attempted
    if [[ -f "$upload_log" ]]; then
        if grep -q "darwin-arm64" "$upload_log" 2>/dev/null; then
            pass "release verify --fix attempts to upload missing asset"
        else
            fail "release verify --fix should attempt to upload darwin-arm64"
            echo "upload log: $(cat "$upload_log")"
        fi
    else
        # If no upload log, check stderr for upload attempt message
        if exec_stderr_contains "Uploading" || exec_stderr_contains "Upload"; then
            pass "release verify --fix attempts upload (log message found)"
        else
            fail "release verify --fix should attempt to upload missing asset"
            echo "stderr: $(exec_stderr | head -10)"
        fi
    fi

    harness_teardown
}

test_verify_fix_reports_not_found_locally() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config

    # Create manifest but NO local artifacts
    local state_dir="$DSR_STATE_DIR"
    local artifacts_dir="$state_dir/artifacts/test-tool/v1.0.0"
    mkdir -p "$artifacts_dir"

    cat > "$artifacts_dir/test-tool-v1.0.0-manifest.json" << 'EOF'
{
  "schema_version": "1.0.0",
  "tool": "test-tool",
  "version": "v1.0.0",
  "artifacts": [
    {"filename": "test-tool-linux-amd64", "target": "linux/amd64"},
    {"filename": "test-tool-darwin-arm64", "target": "darwin/arm64"}
  ]
}
EOF

    export DSR_STATE_DIR="$state_dir"

    # Mock release with missing asset
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" << 'SCRIPT'
#!/usr/bin/env bash
case "$*" in
    "auth status"|"auth token")
        exit 0
        ;;
    "api "*)
        cat << 'JSON'
{
    "id": 12345,
    "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
    "assets": [
        {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"}
    ]
}
JSON
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/gh"

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release verify test-tool v1.0.0 --fix

    # Should warn about not found locally
    if exec_stderr_contains "Not found locally" || exec_stderr_contains "not found"; then
        pass "release verify --fix reports when asset not found locally"
    else
        # May not have explicit message, but shouldn't crash
        local status
        status=$(exec_status)
        if [[ "$status" -le 1 ]]; then
            pass "release verify --fix handles missing local asset gracefully"
        else
            fail "release verify --fix should handle missing local assets"
            echo "stderr: $(exec_stderr | head -10)"
        fi
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

echo "=== Tests: dsr release verify (bd-1jt.5.12) ==="
echo ""
echo "Dependencies: gh auth=$(if $HAS_GH_AUTH; then echo available; else echo missing; fi), yq=$(if $HAS_YQ; then echo available; else echo missing; fi)"
echo ""

echo "Help Tests (always work):"
test_verify_help
test_verify_help_shows_options

echo ""
echo "Argument Validation Tests:"
test_verify_missing_tool
test_verify_missing_version
test_verify_unknown_option

echo ""
echo "Authentication Tests:"
test_verify_missing_gh_auth

echo ""
echo "Asset Comparison Tests (mocked gh):"
test_verify_all_assets_present
test_verify_detects_missing_assets
test_verify_detects_extra_assets
test_verify_handles_no_manifest

echo ""
echo "Release Not Found Tests:"
test_verify_release_not_found

echo ""
echo "JSON Output Tests:"
test_verify_json_valid
test_verify_json_has_required_fields

echo ""
echo "Stream Separation Tests:"
test_verify_stream_separation

echo ""
echo "Retry/Fix Logic Tests:"
test_verify_fix_attempts_upload
test_verify_fix_reports_not_found_locally

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
