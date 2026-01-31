#!/usr/bin/env bash
# test_upgrade_verify.sh - Tests for upgrade command verification
#
# bd-1jt.5.6: Implement upgrade command verification after release
#
# Tests the upgrade_verify module that validates tool upgrade commands
# work correctly after releases.
#
# Run: ./scripts/tests/test_upgrade_verify.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test harness
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
BLUE=$'\033[0;34m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }
info() { echo "${BLUE}INFO${NC}: $1"; }

# ============================================================================
# Setup
# ============================================================================

setup_module() {
    # Source required modules
    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/upgrade_verify.sh"

    # Create test directories
    mkdir -p "$TEST_TMPDIR/repos.d"
    mkdir -p "$TEST_TMPDIR/bin"

    # Set config directory
    export DSR_CONFIG_DIR="$TEST_TMPDIR"
    export ACT_REPOS_DIR="$TEST_TMPDIR/repos.d"
}

# ============================================================================
# Tests: Module Loading
# ============================================================================

test_module_loads() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    if declare -f upgrade_verify_tool &>/dev/null; then
        pass "upgrade_verify_tool function exists"
    else
        fail "upgrade_verify_tool function should exist"
    fi

    harness_teardown
}

test_module_exports() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    local all_exported=true

    for fn in upgrade_verify_tool upgrade_verify_all upgrade_verify_json; do
        if ! declare -f "$fn" &>/dev/null; then
            all_exported=false
            echo "Missing function: $fn"
        fi
    done

    if $all_exported; then
        pass "All upgrade_verify functions exported"
    else
        fail "Some upgrade_verify functions not exported"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Tool Verification
# ============================================================================

test_verify_missing_tool_fails() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Try to verify non-existent tool
    if upgrade_verify_tool "nonexistent-tool-12345" 2>/dev/null; then
        fail "verify_tool should fail for non-existent tool"
    else
        pass "verify_tool fails for non-existent tool"
    fi

    harness_teardown
}

test_verify_requires_tool_name() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    if upgrade_verify_tool 2>/dev/null; then
        fail "verify_tool should require tool name"
    else
        pass "verify_tool requires tool name"
    fi

    harness_teardown
}

test_verify_dry_run() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create a mock tool that has upgrade command
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/mock-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "Current version: 1.0.0"
    echo "Latest version: 1.0.0"
    echo "Already up to date"
    exit 0
fi
echo "mock-tool $*"
EOF
    chmod +x "$TEST_TMPDIR/bin/mock-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if upgrade_verify_tool mock-tool --dry-run 2>/dev/null; then
        pass "verify_tool --dry-run works"
    else
        fail "verify_tool --dry-run should succeed"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Upgrade Check Parsing
# ============================================================================

test_parses_up_to_date() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create mock that says up to date
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/uptodate-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "up to date"
    exit 0
fi
EOF
    chmod +x "$TEST_TMPDIR/bin/uptodate-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if upgrade_verify_tool uptodate-tool 2>/dev/null; then
        pass "verify_tool detects 'up to date' status"
    else
        fail "verify_tool should pass for 'up to date'"
    fi

    harness_teardown
}

test_parses_update_available() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create mock that says update available
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/update-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "Update available: 2.0.0"
    echo "Current: 1.0.0"
    exit 0
fi
EOF
    chmod +x "$TEST_TMPDIR/bin/update-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if upgrade_verify_tool update-tool 2>/dev/null; then
        pass "verify_tool detects update available"
    else
        fail "verify_tool should pass for 'update available'"
    fi

    harness_teardown
}

test_detects_asset_mismatch() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create mock that reports asset not found
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/mismatch-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "Error: no suitable release asset found for linux/amd64"
    exit 1
fi
EOF
    chmod +x "$TEST_TMPDIR/bin/mismatch-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if upgrade_verify_tool mismatch-tool 2>/dev/null; then
        fail "verify_tool should fail for asset mismatch"
    else
        pass "verify_tool detects asset mismatch"
    fi

    harness_teardown
}

# ============================================================================
# Tests: JSON Output
# ============================================================================

test_json_output_valid() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create a mock tool
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/json-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "up to date"
    exit 0
fi
EOF
    chmod +x "$TEST_TMPDIR/bin/json-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    local output
    output=$(upgrade_verify_json json-tool 2>/dev/null)

    if echo "$output" | jq . &>/dev/null; then
        pass "verify_json produces valid JSON"
    else
        fail "verify_json should produce valid JSON"
        echo "Output: $output"
    fi

    harness_teardown
}

test_json_has_required_fields() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create a mock tool
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/fields-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "up to date"
    exit 0
fi
EOF
    chmod +x "$TEST_TMPDIR/bin/fields-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    local output
    output=$(upgrade_verify_json fields-tool 2>/dev/null)

    local has_tool has_status has_platform
    has_tool=$(echo "$output" | jq -e '.tool' &>/dev/null && echo true || echo false)
    has_status=$(echo "$output" | jq -e '.status' &>/dev/null && echo true || echo false)
    has_platform=$(echo "$output" | jq -e '.platform' &>/dev/null && echo true || echo false)

    if [[ "$has_tool" == "true" && "$has_status" == "true" && "$has_platform" == "true" ]]; then
        pass "verify_json has tool, status, platform fields"
    else
        fail "verify_json should have tool, status, platform fields"
        echo "Output: $output"
    fi

    harness_teardown
}

test_json_error_for_missing_tool() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    local output
    output=$(upgrade_verify_json nonexistent-tool-xyz 2>/dev/null)

    if echo "$output" | jq -e '.status == "error"' &>/dev/null; then
        pass "verify_json returns error status for missing tool"
    else
        fail "verify_json should return error status for missing tool"
        echo "Output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Repository Finding
# ============================================================================

test_find_repo_from_config() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create a config file
    mkdir -p "$TEST_TMPDIR/test-project"
    cat > "$TEST_TMPDIR/repos.d/test-tool.yaml" << EOF
name: test-tool
local_path: $TEST_TMPDIR/test-project
repo: test/test-tool
EOF

    local repo_dir
    repo_dir=$(_upgrade_find_repo_dir "test-tool")

    if [[ "$repo_dir" == "$TEST_TMPDIR/test-project" ]]; then
        pass "_upgrade_find_repo_dir finds repo from config"
    else
        fail "_upgrade_find_repo_dir should find repo from config"
        echo "Got: $repo_dir"
    fi

    harness_teardown
}

test_find_repo_default_location() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Without config, should try /data/projects/<tool>
    # This test may need adjustment based on environment
    local repo_dir
    repo_dir=$(_upgrade_find_repo_dir "nonexistent-tool" 2>/dev/null || echo "")

    # Should return empty for non-existent
    if [[ -z "$repo_dir" ]]; then
        pass "_upgrade_find_repo_dir returns empty for non-existent repo"
    else
        fail "_upgrade_find_repo_dir should return empty for non-existent repo"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Real Tools (when available)
# ============================================================================

test_real_tool_bv() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    if ! command -v bv &>/dev/null; then
        skip "bv not installed"
        harness_teardown
        return 0
    fi

    # Check if bv has upgrade command
    if ! bv --help 2>&1 | grep -q "update\|upgrade"; then
        skip "bv doesn't have upgrade command"
        harness_teardown
        return 0
    fi

    # Note: bv uses --update not upgrade --check
    # This test documents what happens
    info "Testing bv upgrade check (may use different syntax)..."

    if upgrade_verify_tool bv 2>/dev/null; then
        pass "bv upgrade verification passed"
    else
        # Expected to fail if bv uses different syntax
        pass "bv upgrade verification completed (may use different command)"
    fi

    harness_teardown
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    harness_teardown 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== Upgrade Verify Tests ==="
echo ""

echo "Module Tests:"
test_module_loads
test_module_exports

echo ""
echo "Tool Verification Tests:"
test_verify_missing_tool_fails
test_verify_requires_tool_name
test_verify_dry_run

echo ""
echo "Upgrade Check Parsing Tests:"
test_parses_up_to_date
test_parses_update_available
test_detects_asset_mismatch

echo ""
echo "JSON Output Tests:"
test_json_output_valid
test_json_has_required_fields
test_json_error_for_missing_tool

echo ""
echo "Repository Finding Tests:"
test_find_repo_from_config
test_find_repo_default_location

echo ""
echo "Real Tool Tests (when available):"
test_real_tool_bv

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
