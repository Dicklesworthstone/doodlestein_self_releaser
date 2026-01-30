#!/usr/bin/env bash
# test_git_ops.sh - Tests for git_ops.sh module
#
# Tests git plumbing operations for reproducible builds.
# Uses a temporary git repository for isolated testing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../src" && pwd)"

# Source the module under test
# shellcheck source=../../src/logging.sh
source "$SRC_DIR/logging.sh"
# shellcheck source=../../src/git_ops.sh
source "$SRC_DIR/git_ops.sh"

# Test state
TEMP_DIR=""
TEST_REPO=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Initialize logging silently
log_init 2>/dev/null || true

# ============================================================================
# Test Infrastructure
# ============================================================================

setup() {
  TEMP_DIR=$(mktemp -d)
  TEST_REPO="$TEMP_DIR/test-repo"

  # Create a test repository
  mkdir -p "$TEST_REPO"
  git -C "$TEST_REPO" init --quiet
  git -C "$TEST_REPO" config user.email "test@example.com"
  git -C "$TEST_REPO" config user.name "Test User"

  # Create initial commit
  echo "initial content" > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit --quiet -m "Initial commit"

  # Create a tag
  git -C "$TEST_REPO" tag v1.0.0

  # Create another commit and tag
  echo "version 1.1" >> "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit --quiet -m "Version 1.1"
  git -C "$TEST_REPO" tag -a v1.1.0 -m "Release v1.1.0"

  # Create a branch
  git -C "$TEST_REPO" checkout -b feature-branch --quiet
  echo "feature work" >> "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit --quiet -m "Feature work"

  # Return to main branch
  git -C "$TEST_REPO" checkout master --quiet 2>/dev/null || \
    git -C "$TEST_REPO" checkout main --quiet 2>/dev/null || true
}

teardown() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-assertion failed}"

  if [[ "$expected" != "$actual" ]]; then
    echo "  FAIL: $msg"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    return 1
  fi
  return 0
}

assert_true() {
  local condition="$1"
  local msg="${2:-expected true}"

  if ! eval "$condition"; then
    echo "  FAIL: $msg"
    return 1
  fi
  return 0
}

assert_false() {
  local condition="$1"
  local msg="${2:-expected false}"

  if eval "$condition"; then
    echo "  FAIL: $msg"
    return 1
  fi
  return 0
}

run_test() {
  local test_name="$1"
  local test_func="$2"

  ((TESTS_RUN++))
  echo -n "  $test_name... "

  if $test_func 2>/dev/null; then
    echo "OK"
    ((TESTS_PASSED++))
  else
    echo "FAILED"
    ((TESTS_FAILED++))
  fi
}

# ============================================================================
# Tests: Ref Resolution
# ============================================================================

test_resolve_tag() {
  local sha
  sha=$(git_ops_resolve_ref "$TEST_REPO" "v1.0.0")
  [[ -n "$sha" ]] && [[ ${#sha} -eq 40 ]]
}

test_resolve_annotated_tag() {
  local sha
  sha=$(git_ops_resolve_ref "$TEST_REPO" "v1.1.0")
  [[ -n "$sha" ]] && [[ ${#sha} -eq 40 ]]
}

test_resolve_branch() {
  local sha
  sha=$(git_ops_resolve_ref "$TEST_REPO" "feature-branch")
  [[ -n "$sha" ]] && [[ ${#sha} -eq 40 ]]
}

test_resolve_sha() {
  local head_sha short_sha resolved
  head_sha=$(git -C "$TEST_REPO" rev-parse HEAD)
  short_sha="${head_sha:0:12}"
  resolved=$(git_ops_resolve_ref "$TEST_REPO" "$short_sha")
  [[ "$resolved" == "$head_sha" ]]
}

test_resolve_invalid_ref() {
  ! git_ops_resolve_ref "$TEST_REPO" "nonexistent-ref" 2>/dev/null
}

test_version_to_tag() {
  local tag
  tag=$(git_ops_version_to_tag "1.2.3")
  assert_equals "v1.2.3" "$tag" "Should add v prefix"

  tag=$(git_ops_version_to_tag "v1.2.3")
  assert_equals "v1.2.3" "$tag" "Should not double v prefix"
}

# ============================================================================
# Tests: Dirty Tree Detection
# ============================================================================

test_clean_repo_not_dirty() {
  ! git_ops_is_dirty "$TEST_REPO"
}

test_modified_file_is_dirty() {
  echo "modified" >> "$TEST_REPO/file.txt"
  git_ops_is_dirty "$TEST_REPO"
  local result=$?
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null  # Cleanup
  [[ $result -eq 0 ]]
}

test_staged_file_is_dirty() {
  echo "new content" >> "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git_ops_is_dirty "$TEST_REPO"
  local result=$?
  git -C "$TEST_REPO" reset HEAD -- file.txt 2>/dev/null
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  [[ $result -eq 0 ]]
}

test_untracked_file_detection() {
  echo "untracked" > "$TEST_REPO/untracked.txt"
  git_ops_has_untracked "$TEST_REPO"
  local result=$?
  rm -f "$TEST_REPO/untracked.txt"
  [[ $result -eq 0 ]]
}

test_dirty_status_clean() {
  local status
  status=$(git_ops_dirty_status "$TEST_REPO")
  assert_equals "clean" "$status"
}

test_dirty_status_modified() {
  echo "modified" >> "$TEST_REPO/file.txt"
  local status
  status=$(git_ops_dirty_status "$TEST_REPO")
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  assert_equals "modified" "$status"
}

test_dirty_status_untracked() {
  echo "untracked" > "$TEST_REPO/new.txt"
  local status
  status=$(git_ops_dirty_status "$TEST_REPO")
  rm -f "$TEST_REPO/new.txt"
  assert_equals "untracked" "$status"
}

test_dirty_status_both() {
  echo "modified" >> "$TEST_REPO/file.txt"
  echo "untracked" > "$TEST_REPO/new.txt"
  local status
  status=$(git_ops_dirty_status "$TEST_REPO")
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  rm -f "$TEST_REPO/new.txt"
  assert_equals "modified+untracked" "$status"
}

# ============================================================================
# Tests: Tag Operations
# ============================================================================

test_tag_exists() {
  git_ops_tag_exists "$TEST_REPO" "v1.0.0"
}

test_tag_not_exists() {
  ! git_ops_tag_exists "$TEST_REPO" "v9.9.9"
}

test_tag_sha() {
  local sha
  sha=$(git_ops_tag_sha "$TEST_REPO" "v1.0.0")
  [[ -n "$sha" ]] && [[ ${#sha} -eq 40 ]]
}

test_annotated_tag_sha() {
  local sha
  sha=$(git_ops_tag_sha "$TEST_REPO" "v1.1.0")
  [[ -n "$sha" ]] && [[ ${#sha} -eq 40 ]]
}

test_list_tags() {
  local tags
  tags=$(git_ops_list_tags "$TEST_REPO")
  [[ "$tags" == *"v1.0.0"* ]] && [[ "$tags" == *"v1.1.0"* ]]
}

test_list_tags_pattern() {
  local tags
  tags=$(git_ops_list_tags "$TEST_REPO" "v1.0*")
  [[ "$tags" == *"v1.0.0"* ]] && [[ "$tags" != *"v1.1.0"* ]]
}

# ============================================================================
# Tests: Branch Operations
# ============================================================================

test_current_branch() {
  local branch
  branch=$(git_ops_current_branch "$TEST_REPO")
  [[ "$branch" == "master" || "$branch" == "main" ]]
}

test_head_sha() {
  local sha
  sha=$(git_ops_head_sha "$TEST_REPO")
  [[ -n "$sha" ]] && [[ ${#sha} -eq 40 ]]
}

# ============================================================================
# Tests: Build Info
# ============================================================================

test_get_build_info_tag() {
  local info
  info=$(git_ops_get_build_info "$TEST_REPO" "v1.0.0")
  echo "$info" | jq -e '.git_sha' >/dev/null
  echo "$info" | jq -e '.ref_type == "tag"' >/dev/null
}

test_get_build_info_sha() {
  local head_sha info
  head_sha=$(git -C "$TEST_REPO" rev-parse HEAD)
  info=$(git_ops_get_build_info "$TEST_REPO" "$head_sha")
  echo "$info" | jq -e '.ref_type == "commit"' >/dev/null
}

test_get_build_info_dirty_fails() {
  echo "modified" >> "$TEST_REPO/file.txt"
  local result
  git_ops_get_build_info "$TEST_REPO" "v1.0.0" 2>/dev/null
  result=$?
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  [[ $result -ne 0 ]]
}

test_get_build_info_allow_dirty() {
  echo "modified" >> "$TEST_REPO/file.txt"
  local info
  info=$(git_ops_get_build_info "$TEST_REPO" "v1.0.0" "--allow-dirty")
  local result=$?
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  [[ $result -eq 0 ]] && echo "$info" | jq -e '.dirty_status == "modified"' >/dev/null
}

# ============================================================================
# Tests: Validation
# ============================================================================

test_validate_for_build_success() {
  git_ops_validate_for_build "$TEST_REPO" "v1.0.0" 2>/dev/null
}

test_validate_for_build_missing_tag() {
  ! git_ops_validate_for_build "$TEST_REPO" "v9.9.9" 2>/dev/null
}

test_validate_for_build_dirty() {
  echo "modified" >> "$TEST_REPO/file.txt"
  local result
  git_ops_validate_for_build "$TEST_REPO" "v1.0.0" 2>/dev/null
  result=$?
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  [[ $result -ne 0 ]]
}

test_validate_for_build_allow_dirty() {
  echo "modified" >> "$TEST_REPO/file.txt"
  git_ops_validate_for_build "$TEST_REPO" "v1.0.0" "--allow-dirty" 2>/dev/null
  local result=$?
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  [[ $result -eq 0 ]]
}

# ============================================================================
# Main Test Runner
# ============================================================================

main() {
  echo "=== git_ops.sh Tests ==="
  echo ""

  setup

  echo "Ref Resolution:"
  run_test "resolve_tag" test_resolve_tag
  run_test "resolve_annotated_tag" test_resolve_annotated_tag
  run_test "resolve_branch" test_resolve_branch
  run_test "resolve_sha" test_resolve_sha
  run_test "resolve_invalid_ref" test_resolve_invalid_ref
  run_test "version_to_tag" test_version_to_tag

  echo ""
  echo "Dirty Tree Detection:"
  run_test "clean_repo_not_dirty" test_clean_repo_not_dirty
  run_test "modified_file_is_dirty" test_modified_file_is_dirty
  run_test "staged_file_is_dirty" test_staged_file_is_dirty
  run_test "untracked_file_detection" test_untracked_file_detection
  run_test "dirty_status_clean" test_dirty_status_clean
  run_test "dirty_status_modified" test_dirty_status_modified
  run_test "dirty_status_untracked" test_dirty_status_untracked
  run_test "dirty_status_both" test_dirty_status_both

  echo ""
  echo "Tag Operations:"
  run_test "tag_exists" test_tag_exists
  run_test "tag_not_exists" test_tag_not_exists
  run_test "tag_sha" test_tag_sha
  run_test "annotated_tag_sha" test_annotated_tag_sha
  run_test "list_tags" test_list_tags
  run_test "list_tags_pattern" test_list_tags_pattern

  echo ""
  echo "Branch Operations:"
  run_test "current_branch" test_current_branch
  run_test "head_sha" test_head_sha

  echo ""
  echo "Build Info:"
  run_test "get_build_info_tag" test_get_build_info_tag
  run_test "get_build_info_sha" test_get_build_info_sha
  run_test "get_build_info_dirty_fails" test_get_build_info_dirty_fails
  run_test "get_build_info_allow_dirty" test_get_build_info_allow_dirty

  echo ""
  echo "Validation:"
  run_test "validate_for_build_success" test_validate_for_build_success
  run_test "validate_for_build_missing_tag" test_validate_for_build_missing_tag
  run_test "validate_for_build_dirty" test_validate_for_build_dirty
  run_test "validate_for_build_allow_dirty" test_validate_for_build_allow_dirty

  teardown

  echo ""
  echo "=== Results ==="
  echo "Tests run:    $TESTS_RUN"
  echo "Tests passed: $TESTS_PASSED"
  echo "Tests failed: $TESTS_FAILED"

  if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
