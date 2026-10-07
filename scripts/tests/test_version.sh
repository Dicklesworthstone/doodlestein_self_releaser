#!/usr/bin/env bash
# test_version.sh - Tests for src/version.sh
#
# Usage: ./scripts/tests/test_version.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source version module and dependencies
source "$PROJECT_ROOT/src/logging.sh"
source "$PROJECT_ROOT/src/git_ops.sh"
source "$PROJECT_ROOT/src/version.sh"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'
    RED=$'\033[0;31m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    GREEN='' RED='' YELLOW='' NC=''
fi

pass() { ((TESTS_PASSED++)); echo "${GREEN}✓${NC} $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}✗${NC} $1: $2"; }
skip() { echo "${YELLOW}○${NC} $1 (skipped: $2)"; }

run_test() {
    local name="$1"
    ((TESTS_RUN++))
    echo "Running: $name"
}

# ============================================================================
# Setup
# ============================================================================

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Create a mock Rust project
setup_rust_project() {
    local dir="$TEMP_DIR/rust_project"
    mkdir -p "$dir"
    git -C "$dir" init -q
    cat > "$dir/Cargo.toml" << 'EOF'
[package]
name = "test-tool"
version = "1.2.3"
edition = "2021"
EOF
    git -C "$dir" add .
    git -C "$dir" commit -q -m "Initial commit"
    echo "$dir"
}

# Create a mock Node.js project
setup_node_project() {
    local dir="$TEMP_DIR/node_project"
    mkdir -p "$dir"
    git -C "$dir" init -q
    cat > "$dir/package.json" << 'EOF'
{
  "name": "test-tool",
  "version": "2.0.0-beta.1"
}
EOF
    git -C "$dir" add .
    git -C "$dir" commit -q -m "Initial commit"
    echo "$dir"
}

# Create a mock Python project
setup_python_project() {
    local dir="$TEMP_DIR/python_project"
    mkdir -p "$dir"
    git -C "$dir" init -q
    cat > "$dir/pyproject.toml" << 'EOF'
[project]
name = "test-tool"
version = "0.9.5"
EOF
    git -C "$dir" add .
    git -C "$dir" commit -q -m "Initial commit"
    echo "$dir"
}

# Create a mock Go project with VERSION file
setup_go_project() {
    local dir="$TEMP_DIR/go_project"
    mkdir -p "$dir"
    git -C "$dir" init -q
    echo "3.1.4" > "$dir/VERSION"
    git -C "$dir" add .
    git -C "$dir" commit -q -m "Initial commit"
    echo "$dir"
}

# ============================================================================
# Tests
# ============================================================================

echo "========================================="
echo "Testing src/version.sh"
echo "========================================="
echo ""

# Test 1: Rust version detection
run_test "version_detect - Rust (Cargo.toml)"
rust_dir=$(setup_rust_project)
version=$(version_detect "$rust_dir" 2>/dev/null)
if [[ "$version" == "1.2.3" ]]; then
    pass "Detected Rust version: $version"
else
    fail "Rust version" "expected 1.2.3, got '$version'"
fi

# Test 2: Node.js version detection
run_test "version_detect - Node.js (package.json)"
node_dir=$(setup_node_project)
version=$(version_detect "$node_dir" 2>/dev/null)
if [[ "$version" == "2.0.0-beta.1" ]]; then
    pass "Detected Node.js version: $version"
else
    fail "Node.js version" "expected 2.0.0-beta.1, got '$version'"
fi

# Test 3: Python version detection
run_test "version_detect - Python (pyproject.toml)"
python_dir=$(setup_python_project)
version=$(version_detect "$python_dir" 2>/dev/null)
if [[ "$version" == "0.9.5" ]]; then
    pass "Detected Python version: $version"
else
    fail "Python version" "expected 0.9.5, got '$version'"
fi

# Test 4: Go version detection (VERSION file)
run_test "version_detect - Go (VERSION file)"
go_dir=$(setup_go_project)
version=$(version_detect "$go_dir" 2>/dev/null)
if [[ "$version" == "3.1.4" ]]; then
    pass "Detected Go version: $version"
else
    fail "Go version" "expected 3.1.4, got '$version'"
fi

# Test 5: version_needs_tag - no tag exists
run_test "version_needs_tag - tag does not exist"
if version_needs_tag "$rust_dir" 2>/dev/null; then
    pass "Correctly reports tag needed"
else
    fail "version_needs_tag" "should return 0 when tag doesn't exist"
fi

# Test 6: version_needs_tag - tag exists
run_test "version_needs_tag - tag exists"
git -C "$rust_dir" tag v1.2.3
if ! version_needs_tag "$rust_dir" 2>/dev/null; then
    pass "Correctly reports tag not needed"
else
    fail "version_needs_tag" "should return 1 when tag exists"
fi

# Test 7: version_create_tag - dry-run
run_test "version_create_tag - dry-run"
output=$(version_create_tag "$node_dir" --dry-run 2>&1)
if [[ "$output" == *"[DRY-RUN]"* && "$output" == *"v2.0.0-beta.1"* ]]; then
    pass "Dry-run outputs correct info"
else
    fail "version_create_tag --dry-run" "missing expected output"
fi

# Test 8: version_create_tag - actual tag
run_test "version_create_tag - creates tag"
if version_create_tag "$node_dir" 2>/dev/null; then
    if git -C "$node_dir" show-ref --tags --verify "refs/tags/v2.0.0-beta.1" &>/dev/null; then
        pass "Tag v2.0.0-beta.1 created successfully"
    else
        fail "version_create_tag" "tag not found in repo"
    fi
else
    fail "version_create_tag" "command failed"
fi

# Test 9: version_create_tag - tag already exists
run_test "version_create_tag - already exists"
output=$(version_create_tag "$node_dir" 2>&1)
if [[ "$output" == *"already exists"* ]]; then
    pass "Correctly handles existing tag"
else
    fail "version_create_tag" "should warn about existing tag"
fi

# Test 9b: --push on an existing local tag publishes it, once, and never
# replaces a different tag of the same name on origin.
run_test "version_create_tag --push - existing local tag reaches origin"
origin_dir="$TEMP_DIR/origin.git"
git init -q --bare "$origin_dir"
git -C "$node_dir" remote add origin "$origin_dir"
tag_ref="refs/tags/v2.0.0-beta.1"
local_tag_object=$(git -C "$node_dir" rev-parse "$tag_ref")
output=$(version_create_tag "$node_dir" --push --dry-run 2>&1)
if [[ "$output" == *"Would push existing tag"* ]] && ! git -C "$origin_dir" show-ref --verify -q "$tag_ref" &&
   version_create_tag "$node_dir" --push 2>/dev/null &&
   [[ "$(git -C "$origin_dir" rev-parse "$tag_ref" 2>/dev/null)" == "$local_tag_object" ]] &&
   version_create_tag "$node_dir" --push 2>/dev/null; then
    pass "Existing tag is pushed (dry run first pushes nothing; a repeat is a no-op)"
else
    fail "version_create_tag --push" "existing local tag did not reach origin: $output"
fi

run_test "version_create_tag --push - refuses a different tag on origin"
git -C "$origin_dir" tag -d v2.0.0-beta.1 >/dev/null
other_commit=$(git -C "$node_dir" commit-tree -m other "$(git -C "$node_dir" rev-parse 'HEAD^{tree}')")
git -C "$node_dir" push -q origin "$other_commit:refs/tags/v2.0.0-beta.1"
push_status=0
version_create_tag "$node_dir" --push >/dev/null 2>&1 || push_status=$?
if [[ $push_status -eq 2 && "$(git -C "$origin_dir" rev-parse "$tag_ref")" == "$other_commit" ]]; then
    pass "A conflicting origin tag is reported (exit 2) and left unchanged"
else
    fail "version_create_tag --push" "conflict exit $push_status, origin $(git -C "$origin_dir" rev-parse "$tag_ref")"
fi

# Test 10: version_info_json
run_test "version_info_json - returns valid JSON"
json=$(version_info_json "$rust_dir")
if echo "$json" | jq -e '.version == "1.2.3" and .tag == "v1.2.3"' &>/dev/null; then
    pass "JSON output is valid and correct"
else
    fail "version_info_json" "invalid JSON or wrong values"
fi

# Test 11: Language-specific detection
run_test "version_detect - language parameter"
version=$(version_detect "$rust_dir" rust 2>/dev/null)
if [[ "$version" == "1.2.3" ]]; then
    pass "Language-specific detection works"
else
    fail "version_detect with language" "expected 1.2.3, got '$version'"
fi

# Test 12: Non-existent directory
run_test "version_detect - non-existent directory"
if ! version_detect "/nonexistent/path" 2>/dev/null; then
    pass "Returns error for non-existent path"
else
    fail "version_detect" "should fail for non-existent directory"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "========================================="
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "${RED}$TESTS_FAILED test(s) failed${NC}"
    exit 1
else
    echo "${GREEN}All tests passed!${NC}"
    exit 0
fi
