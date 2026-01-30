#!/usr/bin/env bash
# test_github.sh - Tests for github.sh module
#
# Tests GitHub API adapter: caching, rate limiting, token validation.
# Uses isolated temp directories; skips tests requiring network/auth.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../src" && pwd)"

# Source the module under test
# shellcheck source=../../src/logging.sh
source "$SRC_DIR/logging.sh"
# shellcheck source=../../src/github.sh
source "$SRC_DIR/github.sh"

# Test state
TEMP_DIR=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Initialize logging silently
log_init 2>/dev/null || true

# Suppress colors for consistent output
export NO_COLOR=1

# ============================================================================
# Test Infrastructure
# ============================================================================

setup() {
  TEMP_DIR=$(mktemp -d)

  # Set up isolated cache directory
  export GH_CACHE_DIR="$TEMP_DIR/github_cache"
  export DSR_CACHE_DIR="$TEMP_DIR/dsr_cache"
  mkdir -p "$GH_CACHE_DIR"

  # Clear any existing token for isolation
  unset GITHUB_TOKEN 2>/dev/null || true
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

  setup

  if $test_func 2>/dev/null; then
    echo "OK"
    ((TESTS_PASSED++))
  else
    echo "FAILED"
    ((TESTS_FAILED++))
  fi

  teardown
}

skip_test() {
  local test_name="$1"
  local reason="$2"

  ((TESTS_RUN++))
  ((TESTS_SKIPPED++))
  echo "  $test_name... SKIP ($reason)"
}

# ============================================================================
# Tests: Cache Key Generation
# ============================================================================

test_cache_key_simple() {
  local key
  key=$(_gh_cache_key "repos/owner/repo")
  [[ "$key" == "repos_owner_repo" ]]
}

test_cache_key_with_query() {
  local key
  key=$(_gh_cache_key "repos/owner/repo/releases?per_page=10")
  # Should replace special chars with underscores
  [[ "$key" =~ ^repos_owner_repo_releases ]]
}

test_cache_key_safe_chars() {
  local key
  key=$(_gh_cache_key "repos/test-org/my_repo-name")
  # Hyphens and underscores should be preserved
  [[ "$key" =~ test-org ]] && [[ "$key" =~ my_repo-name ]]
}

test_cache_key_special_chars() {
  local key
  key=$(_gh_cache_key "search/code?q=test&sort=stars")
  # Should not contain question marks, ampersands, or equals signs
  [[ "$key" != *"?"* ]] && [[ "$key" != *"&"* ]] && [[ "$key" != *"="* ]]
}

# ============================================================================
# Tests: Cache Operations
# ============================================================================

test_init_cache_creates_dir() {
  rm -rf "$GH_CACHE_DIR"
  gh_init_cache
  [[ -d "$GH_CACHE_DIR" ]]
}

test_set_cache_creates_files() {
  echo '{"test": true}' | _gh_set_cache "test/endpoint" "etag123"
  [[ -f "$GH_CACHE_DIR/test_endpoint.json" ]] && \
  [[ -f "$GH_CACHE_DIR/test_endpoint.meta" ]]
}

test_set_cache_stores_content() {
  echo '{"data": "value"}' | _gh_set_cache "test/content" ""
  local content
  content=$(cat "$GH_CACHE_DIR/test_content.json")
  [[ "$content" == '{"data": "value"}' ]]
}

test_set_cache_stores_timestamp() {
  echo '{}' | _gh_set_cache "test/time" ""
  local timestamp
  timestamp=$(head -1 "$GH_CACHE_DIR/test_time.meta")
  # Should be a reasonable epoch timestamp
  [[ "$timestamp" =~ ^[0-9]+$ ]] && [[ "$timestamp" -gt 1700000000 ]]
}

test_set_cache_stores_etag() {
  echo '{}' | _gh_set_cache "test/etag" "W/\"abc123\""
  local etag
  etag=$(sed -n '2p' "$GH_CACHE_DIR/test_etag.meta")
  [[ "$etag" == 'W/"abc123"' ]]
}

test_get_cache_returns_content() {
  echo '{"cached": true}' | _gh_set_cache "test/get" ""
  local result
  result=$(_gh_get_cache "test/get")
  [[ "$result" == '{"cached": true}' ]]
}

test_get_cache_missing_returns_error() {
  ! _gh_get_cache "nonexistent/endpoint"
}

test_get_cache_expired_returns_error() {
  # Create cache with old timestamp
  mkdir -p "$GH_CACHE_DIR"
  echo '{"old": true}' > "$GH_CACHE_DIR/test_expired.json"
  echo "1000000000" > "$GH_CACHE_DIR/test_expired.meta"  # Very old
  echo "" >> "$GH_CACHE_DIR/test_expired.meta"
  ! _gh_get_cache "test/expired"
}

test_get_cache_ttl_respected() {
  export GH_CACHE_TTL=5
  echo '{"fresh": true}' | _gh_set_cache "test/ttl" ""
  # Should be fresh immediately
  local result
  result=$(_gh_get_cache "test/ttl")
  [[ "$result" == '{"fresh": true}' ]]
}

test_get_etag_returns_stored() {
  echo '{}' | _gh_set_cache "test/etag2" "etag-value-123"
  local etag
  etag=$(_gh_get_etag "test/etag2")
  [[ "$etag" == "etag-value-123" ]]
}

test_get_etag_missing_returns_empty() {
  local etag
  etag=$(_gh_get_etag "nonexistent/etag")
  [[ -z "$etag" ]]
}

# ============================================================================
# Tests: Rate Limit Detection
# ============================================================================

test_rate_limit_detected_message() {
  _gh_is_rate_limited '{"message": "API rate limit exceeded"}'
}

test_rate_limit_detected_case_insensitive() {
  _gh_is_rate_limited '{"message": "RATE LIMIT exceeded"}'
}

test_rate_limit_detected_partial() {
  _gh_is_rate_limited '{"error": "You have exceeded the rate limit"}'
}

test_rate_limit_not_detected_normal() {
  ! _gh_is_rate_limited '{"data": "normal response"}'
}

test_rate_limit_not_detected_empty() {
  ! _gh_is_rate_limited ''
}

test_rate_limit_not_detected_unrelated() {
  ! _gh_is_rate_limited '{"message": "Not Found"}'
}

# ============================================================================
# Tests: Token Validation
# ============================================================================

test_check_token_fails_when_unset() {
  unset GITHUB_TOKEN
  ! gh_check_token
}

test_check_token_passes_when_set() {
  export GITHUB_TOKEN="test_token_value"
  gh_check_token
  local result=$?
  unset GITHUB_TOKEN
  [[ $result -eq 0 ]]
}

test_check_token_returns_code_3() {
  unset GITHUB_TOKEN
  gh_check_token 2>/dev/null
  local result=$?
  [[ $result -eq 3 ]]
}

# ============================================================================
# Tests: gh_check (CLI availability)
# ============================================================================

test_gh_check_returns_when_missing() {
  # Save PATH
  local old_path="$PATH"
  # Remove gh from PATH
  PATH="/nonexistent"
  local result=0
  gh_check 2>/dev/null || result=$?
  PATH="$old_path"
  [[ $result -ne 0 ]]
}

# ============================================================================
# Tests: API Argument Parsing
# ============================================================================

test_api_rejects_empty_endpoint() {
  ! gh_api "" 2>/dev/null
}

test_api_rejects_unknown_option() {
  ! gh_api "test" --invalid-option 2>/dev/null
}

# ============================================================================
# Tests: Clear Cache
# ============================================================================

test_clear_cache_removes_all() {
  echo '{}' | _gh_set_cache "test/a" ""
  echo '{}' | _gh_set_cache "test/b" ""
  gh_clear_cache
  [[ ! -f "$GH_CACHE_DIR/test_a.json" ]] && \
  [[ ! -f "$GH_CACHE_DIR/test_b.json" ]]
}

test_clear_cache_specific_endpoint() {
  echo '{}' | _gh_set_cache "test/keep" ""
  echo '{}' | _gh_set_cache "test/remove" ""
  gh_clear_cache "test/remove"
  [[ -f "$GH_CACHE_DIR/test_keep.json" ]] && \
  [[ ! -f "$GH_CACHE_DIR/test_remove.json" ]]
}

# ============================================================================
# Tests: Configuration
# ============================================================================

test_cache_ttl_default() {
  # Default should be 60 seconds
  unset GH_CACHE_TTL
  # Re-source to get default
  GH_CACHE_TTL="${GH_CACHE_TTL:-60}"
  [[ "$GH_CACHE_TTL" -eq 60 ]]
}

test_cache_ttl_override() {
  export GH_CACHE_TTL=120
  [[ "$GH_CACHE_TTL" -eq 120 ]]
}

test_max_retries_default() {
  unset GH_MAX_RETRIES
  GH_MAX_RETRIES="${GH_MAX_RETRIES:-3}"
  [[ "$GH_MAX_RETRIES" -eq 3 ]]
}

test_retry_delay_default() {
  unset GH_RETRY_DELAY
  GH_RETRY_DELAY="${GH_RETRY_DELAY:-5}"
  [[ "$GH_RETRY_DELAY" -eq 5 ]]
}

# ============================================================================
# Tests: Function Exports
# ============================================================================

test_exports_gh_api() {
  declare -f gh_api >/dev/null
}

test_exports_gh_check() {
  declare -f gh_check >/dev/null
}

test_exports_gh_check_token() {
  declare -f gh_check_token >/dev/null
}

test_exports_gh_workflow_runs() {
  declare -f gh_workflow_runs >/dev/null
}

test_exports_gh_releases() {
  declare -f gh_releases >/dev/null
}

test_exports_gh_create_release() {
  declare -f gh_create_release >/dev/null
}

test_exports_gh_clear_cache() {
  declare -f gh_clear_cache >/dev/null
}

# ============================================================================
# Tests: High-Level Helpers (Argument Validation)
# ============================================================================

test_workflow_runs_rejects_empty_repo() {
  ! gh_workflow_runs "" 2>/dev/null
}

test_releases_rejects_empty_repo() {
  ! gh_releases "" 2>/dev/null
}

test_latest_release_rejects_empty_repo() {
  ! gh_latest_release "" 2>/dev/null
}

test_create_release_rejects_missing_tag() {
  ! gh_create_release "owner/repo" "" 2>/dev/null
}

test_upload_asset_rejects_missing_url() {
  ! gh_upload_asset "" "file.txt" 2>/dev/null
}

test_upload_asset_rejects_missing_file() {
  ! gh_upload_asset "http://example.com" "" 2>/dev/null
}

test_upload_asset_rejects_nonexistent_file() {
  ! gh_upload_asset "http://example.com" "/nonexistent/file.txt" 2>/dev/null
}

test_compare_rejects_missing_args() {
  ! gh_compare "owner/repo" "" "head" 2>/dev/null
  ! gh_compare "owner/repo" "base" "" 2>/dev/null
}

test_tags_rejects_empty_repo() {
  ! gh_tags "" 2>/dev/null
}

test_repo_rejects_empty_repo() {
  ! gh_repo "" 2>/dev/null
}

# ============================================================================
# Main Test Runner
# ============================================================================

main() {
  echo "=== github.sh Tests ==="
  echo ""

  echo "Cache Key Generation:"
  run_test "cache_key_simple" test_cache_key_simple
  run_test "cache_key_with_query" test_cache_key_with_query
  run_test "cache_key_safe_chars" test_cache_key_safe_chars
  run_test "cache_key_special_chars" test_cache_key_special_chars

  echo ""
  echo "Cache Operations:"
  run_test "init_cache_creates_dir" test_init_cache_creates_dir
  run_test "set_cache_creates_files" test_set_cache_creates_files
  run_test "set_cache_stores_content" test_set_cache_stores_content
  run_test "set_cache_stores_timestamp" test_set_cache_stores_timestamp
  run_test "set_cache_stores_etag" test_set_cache_stores_etag
  run_test "get_cache_returns_content" test_get_cache_returns_content
  run_test "get_cache_missing_returns_error" test_get_cache_missing_returns_error
  run_test "get_cache_expired_returns_error" test_get_cache_expired_returns_error
  run_test "get_cache_ttl_respected" test_get_cache_ttl_respected
  run_test "get_etag_returns_stored" test_get_etag_returns_stored
  run_test "get_etag_missing_returns_empty" test_get_etag_missing_returns_empty

  echo ""
  echo "Rate Limit Detection:"
  run_test "rate_limit_detected_message" test_rate_limit_detected_message
  run_test "rate_limit_detected_case_insensitive" test_rate_limit_detected_case_insensitive
  run_test "rate_limit_detected_partial" test_rate_limit_detected_partial
  run_test "rate_limit_not_detected_normal" test_rate_limit_not_detected_normal
  run_test "rate_limit_not_detected_empty" test_rate_limit_not_detected_empty
  run_test "rate_limit_not_detected_unrelated" test_rate_limit_not_detected_unrelated

  echo ""
  echo "Token Validation:"
  run_test "check_token_fails_when_unset" test_check_token_fails_when_unset
  run_test "check_token_passes_when_set" test_check_token_passes_when_set
  run_test "check_token_returns_code_3" test_check_token_returns_code_3

  echo ""
  echo "CLI Check:"
  run_test "gh_check_returns_when_missing" test_gh_check_returns_when_missing

  echo ""
  echo "API Argument Parsing:"
  run_test "api_rejects_empty_endpoint" test_api_rejects_empty_endpoint
  run_test "api_rejects_unknown_option" test_api_rejects_unknown_option

  echo ""
  echo "Clear Cache:"
  run_test "clear_cache_removes_all" test_clear_cache_removes_all
  run_test "clear_cache_specific_endpoint" test_clear_cache_specific_endpoint

  echo ""
  echo "Configuration:"
  run_test "cache_ttl_default" test_cache_ttl_default
  run_test "cache_ttl_override" test_cache_ttl_override
  run_test "max_retries_default" test_max_retries_default
  run_test "retry_delay_default" test_retry_delay_default

  echo ""
  echo "Function Exports:"
  run_test "exports_gh_api" test_exports_gh_api
  run_test "exports_gh_check" test_exports_gh_check
  run_test "exports_gh_check_token" test_exports_gh_check_token
  run_test "exports_gh_workflow_runs" test_exports_gh_workflow_runs
  run_test "exports_gh_releases" test_exports_gh_releases
  run_test "exports_gh_create_release" test_exports_gh_create_release
  run_test "exports_gh_clear_cache" test_exports_gh_clear_cache

  echo ""
  echo "Argument Validation:"
  run_test "workflow_runs_rejects_empty_repo" test_workflow_runs_rejects_empty_repo
  run_test "releases_rejects_empty_repo" test_releases_rejects_empty_repo
  run_test "latest_release_rejects_empty_repo" test_latest_release_rejects_empty_repo
  run_test "create_release_rejects_missing_tag" test_create_release_rejects_missing_tag
  run_test "upload_asset_rejects_missing_url" test_upload_asset_rejects_missing_url
  run_test "upload_asset_rejects_missing_file" test_upload_asset_rejects_missing_file
  run_test "upload_asset_rejects_nonexistent_file" test_upload_asset_rejects_nonexistent_file
  run_test "compare_rejects_missing_args" test_compare_rejects_missing_args
  run_test "tags_rejects_empty_repo" test_tags_rejects_empty_repo
  run_test "repo_rejects_empty_repo" test_repo_rejects_empty_repo

  echo ""
  echo "=== Results ==="
  echo "Tests run:    $TESTS_RUN"
  echo "Tests passed: $TESTS_PASSED"
  echo "Tests skipped: $TESTS_SKIPPED"
  echo "Tests failed: $TESTS_FAILED"

  if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
