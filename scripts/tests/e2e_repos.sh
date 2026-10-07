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
    mkdir -p "$DSR_CONFIG_DIR"

    # Create repos.yaml with test tools
    cat > "$DSR_CONFIG_DIR/repos.yaml" << 'YAML'
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
    mkdir -p "$DSR_CONFIG_DIR"
    cat > "$DSR_CONFIG_DIR/repos.yaml" << 'YAML'
schema_version: "1.0.0"
tools: {}
YAML
}

seed_malformed_repos() {
    mkdir -p "$DSR_CONFIG_DIR"
    cat > "$DSR_CONFIG_DIR/repos.yaml" << 'YAML'
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

    if [[ "$(exec_status)" -eq 0 ]] && exec_stdout_contains "dsr repos list" && exec_stdout_contains "--format"; then
        pass "repos list --help shows output"
    else
        fail "repos list --help should show output"
        echo "stdout: $(exec_stdout | head -5)"
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

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos list with tools"
        return 0
    fi

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

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos info"
        return 0
    fi

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

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos validate"
        return 0
    fi

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
# Tests: discover filters and list formats
# ============================================================================

# Three local checkouts: Acme/alpha (rust), acme/beta (go), other/gamma (rust).
seed_discoverable_checkouts() {
    local root="$1" name
    mkdir -p "$root/alpha" "$root/beta" "$root/gamma"
    echo '[package]' > "$root/alpha/Cargo.toml"
    echo 'module beta' > "$root/beta/go.mod"
    echo '[package]' > "$root/gamma/Cargo.toml"
    for name in alpha beta gamma; do
        git -C "$root/$name" init -q
    done
    git -C "$root/alpha" remote add origin https://github.com/Acme/alpha.git
    git -C "$root/beta" remote add origin git@github.com:acme/beta
    git -C "$root/gamma" remote add origin https://github.com/other/gamma
}

test_repos_discover_filters_and_apply() {
    ((TESTS_RUN++))
    harness_setup
    harness_create_config
    local root="$TEST_TMPDIR/checkouts" problems=()
    seed_discoverable_checkouts "$root"

    exec_run "$DSR_CMD" --json repos discover --path "$root" --org acme --language rust
    exec_stdout | jq -e '[.details.discovered[].repo] == ["Acme/alpha"]' >/dev/null ||
        problems+=("--org/--language filter: $(exec_stdout | jq -c '[.details.discovered[].repo]' 2>/dev/null)")

    exec_run "$DSR_CMD" repos discover --path "$root" --frobnicate
    [[ "$(exec_status)" -eq 4 ]] || problems+=("unknown option exit $(exec_status)")

    # --apply registers each checkout with its GitHub repository.
    exec_run "$DSR_CMD" repos discover --path "$root" --org acme --apply
    exec_run "$DSR_CMD" repos list --format json
    exec_stdout | jq -e '.command == "repos" and
        ([.details.repos[] | select(.name == "alpha" or .name == "beta") | .repo] | sort) ==
            ["Acme/alpha", "acme/beta"] and ([.details.repos[].name] | index("gamma") == null)' >/dev/null ||
        problems+=("applied registry: $(exec_stdout | jq -c '[.details.repos[] | [.name, .repo]]' 2>/dev/null)")

    exec_run "$DSR_CMD" repos list --format xml
    [[ "$(exec_status)" -eq 4 ]] || problems+=("invalid --format exit $(exec_status)")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "repos discover honors --org/--language, --apply keeps repos; list --format json is JSON"
    else
        fail "repos discover/list: ${problems[*]}"
    fi
    harness_teardown
}

# ============================================================================
# Tests: dry runs, write failures and exit codes
# ============================================================================

test_repos_add_remove_dry_run_change_nothing() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos add/remove"
        return 0
    fi
    harness_setup
    seed_repos_fixtures
    local before problems=()
    before=$(sha256sum < "$DSR_CONFIG_DIR/repos.yaml")

    exec_run "$DSR_CMD" --json repos add acme/new-tool --dry-run
    [[ "$(exec_status)" -eq 0 ]] || problems+=("add --dry-run exit $(exec_status)")
    exec_stdout | jq -e '.details.dry_run == true and .details.added[0].repo == "acme/new-tool"' >/dev/null 2>&1 ||
        problems+=("add plan: $(exec_stdout | jq -c '.details' 2>/dev/null)")
    exec_run "$DSR_CMD" -n repos add acme/other-tool
    [[ "$(exec_status)" -eq 0 ]] || problems+=("-n add exit $(exec_status)")
    exec_run "$DSR_CMD" repos remove test-tool --dry-run
    [[ "$(exec_status)" -eq 0 ]] || problems+=("remove --dry-run exit $(exec_status)")
    exec_run "$DSR_CMD" -n repos remove test-tool
    [[ "$(exec_status)" -eq 0 ]] || problems+=("-n remove exit $(exec_status)")
    [[ "$(sha256sum < "$DSR_CONFIG_DIR/repos.yaml")" == "$before" ]] ||
        problems+=("dry runs changed repos.yaml: $(yq -o=json -I0 '.tools | keys' "$DSR_CONFIG_DIR/repos.yaml")")

    exec_run "$DSR_CMD" repos remove test-tool --frobnicate
    [[ "$(exec_status)" -eq 4 ]] || problems+=("remove unknown option exit $(exec_status)")

    exec_run "$DSR_CMD" --json repos remove test-tool
    exec_stdout | jq -e '.details.removed == [{name: "test-tool", repo: "testuser/test-tool"}] and
        .details.dry_run == false' >/dev/null 2>&1 || problems+=("remove: $(exec_stdout | jq -c '.details' 2>/dev/null)")
    exec_run "$DSR_CMD" repos add acme/new-tool --local-path "$TEST_TMPDIR"
    [[ "$(yq -o=json -I0 '.tools | keys' "$DSR_CONFIG_DIR/repos.yaml")" == '["another-tool","new-tool"]' &&
       "$(yq '.tools.new-tool.repo' "$DSR_CONFIG_DIR/repos.yaml")" == "acme/new-tool" ]] ||
        problems+=("real add/remove: $(yq -o=json -I0 '.tools' "$DSR_CONFIG_DIR/repos.yaml")")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "repos add/remove honor --dry-run and -n; real add/remove still write"
    else
        fail "repos add/remove dry runs: ${problems[*]}"
    fi
    harness_teardown
}

test_repos_validate_exit_codes() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos validate"
        return 0
    fi
    harness_setup
    seed_repos_fixtures
    local problems=()

    exec_run "$DSR_CMD" --json repos validate --repo test-tol --skip-naming
    [[ "$(exec_status)" -eq 4 ]] || problems+=("unknown --repo exit $(exec_status)")
    exec_stdout | jq -e '.status == "error" and .details.errors[0].repo == "test-tol"' >/dev/null 2>&1 ||
        problems+=("unknown --repo envelope: $(exec_stdout | head -c 300)")
    exec_run "$DSR_CMD" repos validate --frobnicate
    [[ "$(exec_status)" -eq 4 ]] || problems+=("unknown option exit $(exec_status)")

    # A registry entry with neither repo nor local_path is an error.
    yq -i '.tools.broken-tool = {"language": "go"}' "$DSR_CONFIG_DIR/repos.yaml"
    exec_run "$DSR_CMD" --json repos validate --repo broken-tool --skip-naming
    [[ "$(exec_status)" -eq 1 ]] || problems+=("json error exit $(exec_status)")
    exec_stdout | jq -e '.status == "error" and .exit_code == 1' >/dev/null 2>&1 ||
        problems+=("json error envelope: $(exec_stdout | head -c 300)")
    exec_run "$DSR_CMD" repos validate --repo broken-tool --skip-naming
    [[ "$(exec_status)" -eq 1 ]] || problems+=("human error exit $(exec_status)")
    [[ -z "$(exec_stdout)" ]] || problems+=("human mode wrote stdout")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "repos validate exits 1 on errors in JSON mode and 4 for an unknown --repo"
    else
        fail "repos validate exit codes: ${problems[*]}"
    fi
    harness_teardown
}

# gh stub: authenticated; test-tool resolves, another-tool fails.
make_sync_gh_stub() {
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" << 'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "auth status") exit 0 ;;
    "api repos/testuser/test-tool") echo '{"full_name":"testuser/test-tool","default_branch":"trunk"}'; exit 0 ;;
esac
echo '{"message":"Not Found"}'
exit 1
EOF
    chmod +x "$TEST_TMPDIR/bin/gh"
}

test_repos_sync_dry_run_and_partial_failure() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos sync"
        return 0
    fi
    harness_setup
    seed_repos_fixtures
    make_sync_gh_stub
    local before problems=()
    before=$(sha256sum < "$DSR_CONFIG_DIR/repos.yaml")

    PATH="$TEST_TMPDIR/bin:$PATH" GH_MAX_RETRIES=1 exec_run "$DSR_CMD" --json repos sync --dry-run
    [[ "$(exec_status)" -eq 1 ]] || problems+=("dry-run exit $(exec_status)")
    exec_stdout | jq -e '.status == "partial" and .details.synced == 1 and .details.failed == 1 and
        .details.dry_run == true and .details.errors[0].repo == "another-tool"' >/dev/null 2>&1 ||
        problems+=("dry-run envelope: $(exec_stdout | jq -c '{status, details}' 2>/dev/null)")
    [[ "$(sha256sum < "$DSR_CONFIG_DIR/repos.yaml")" == "$before" ]] || problems+=("--dry-run wrote repos.yaml")

    PATH="$TEST_TMPDIR/bin:$PATH" GH_MAX_RETRIES=1 exec_run "$DSR_CMD" repos sync
    [[ "$(exec_status)" -eq 1 ]] || problems+=("partial exit $(exec_status)")
    [[ "$(yq '.tools.test-tool.default_branch' "$DSR_CONFIG_DIR/repos.yaml")" == "trunk" ]] ||
        problems+=("default_branch not written")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "repos sync honors --dry-run and exits 1 when a repository fails"
    else
        fail "repos sync: ${problems[*]}"
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

    # Non-zero exit is acceptable when config is missing
    # We just verify it doesn't crash and produces some output
    if exec_stderr_contains "not found" || exec_stderr_contains "init" || exec_stderr_contains "Run:"; then
        pass "repos list shows helpful message when config missing"
    else
        fail "repos list should show helpful message when config missing"
        echo "stderr: $(exec_stderr | head -10)"
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
echo "repos discover/list formats:"
test_repos_discover_filters_and_apply

echo ""
echo "Dry runs and exit codes:"
test_repos_add_remove_dry_run_change_nothing
test_repos_validate_exit_codes
test_repos_sync_dry_run_and_partial_failure

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
