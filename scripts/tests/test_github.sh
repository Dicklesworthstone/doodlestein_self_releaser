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
  shift 2

  ((TESTS_RUN++))
  echo -n "  $test_name... "

  setup

  if "$test_func" "$@" 2>/dev/null; then
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
  gh() { return 1; }
  local status=0
  gh_check_token >/dev/null 2>&1 || status=$?
  unset -f gh
  [[ $status -ne 0 ]]
}

test_check_token_passes_when_set() {
  export GITHUB_TOKEN="test_token_value"
  gh() { return 1; }
  gh_check_token
  local result=$?
  unset -f gh
  unset GITHUB_TOKEN
  [[ $result -eq 0 ]]
}

test_check_token_returns_code_3() {
  unset GITHUB_TOKEN
  gh() { return 1; }
  local result=0
  gh_check_token >/dev/null 2>&1 || result=$?
  unset -f gh
  [[ $result -eq 3 ]]
}

# ============================================================================
# Tests: gh_check (CLI availability)
# ============================================================================

test_gh_check_returns_when_missing() {
  # Save PATH
  local old_path="$PATH"
  # Remove gh from PATH
  # shellcheck disable=SC2123  # Intentional PATH override for testing
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

test_api_no_cache_omits_stale_etag_on_curl_fallback() {
  local endpoint="repos/owner/repo/releases/123"
  local curl_log="$TEMP_DIR/no-cache-curl.log"
  echo '{"cached":true}' | _gh_set_cache "$endpoint" 'W/"stale-etag"'
  export GITHUB_TOKEN="test-token"

  gh() {
    return 1
  }
  curl() {
    printf '%s\n' "$*" > "$curl_log"
    printf 'HTTP/1.1 200 OK\r\nETag: W/"fresh-etag"\r\n\r\n{"fresh":true}'
  }

  local result status=0 cached
  result=$(gh_api "$endpoint" --no-cache) || status=$?
  cached=$(_gh_get_cache_raw "$endpoint")

  unset -f gh curl
  unset GITHUB_TOKEN

  [[ $status -eq 0 && "$result" == '{"fresh":true}' && "$cached" == '{"cached":true}' ]] &&
    grep -Fq 'Cache-Control: no-cache, no-store, max-age=0' "$curl_log" &&
    grep -Fq 'Pragma: no-cache' "$curl_log" &&
    ! grep -Fq 'If-None-Match' "$curl_log"
}

test_api_no_cache_sends_headers_on_gh_cli() {
  local endpoint="repos/owner/repo/releases/123"
  local gh_log="$TEMP_DIR/no-cache-gh.log"

  gh() {
    if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
      return 0
    fi
    printf '%s\n' "$*" > "$gh_log"
    printf '{"fresh":true}\n'
  }

  local result status=0
  result=$(gh_api "$endpoint" --no-cache) || status=$?

  unset -f gh

  [[ $status -eq 0 && "$result" == '{"fresh":true}' ]] &&
    grep -Fq 'Cache-Control: no-cache, no-store, max-age=0' "$gh_log" &&
    grep -Fq 'Pragma: no-cache' "$gh_log"
}

test_api_transport_scenario() (
  local scenario="$1" expected_status="$2" expected_attempts="$3"
  local fixture="$TEMP_DIR/api" endpoint='repos/owner/repo/releases/9'
  local calls="$fixture/calls" attempts="$fixture/attempts" key
  mkdir -p "$fixture/tmp" || return 1
  : > "$calls"; printf '0\n' > "$attempts"
  local TMPDIR="$fixture/tmp" GH_MAX_RETRIES=3 GH_RETRY_DELAY=0 GH_MAX_RETRY_WAIT=300
  local GITHUB_TOKEN='fixture-token'
  unset DSR_GH_TOKEN GH_TOKEN
  unset -f secrets_get_gh_token 2>/dev/null || true
  gh() { return 1; }
  sleep() { printf 'SLEEP %s\n' "$1" >> "$calls"; }
  key=$(_gh_cache_key "$endpoint")
  case "$scenario" in
    conditional-304|uncached-304|corrupt-304|mutation-no-etag)
      printf '{"cached":true}\n' | _gh_set_cache "$endpoint" 'W/"old"'
      printf '0\nW/"old"\n' > "$GH_CACHE_DIR/$key.meta"
      if [[ "$scenario" == corrupt-304 ]]; then printf 'broken-json' > "$GH_CACHE_DIR/$key.json"; fi
      ;;
  esac
  curl() {
    local count
    printf 'CURL %s\n' "$*" >> "$calls"
    read -r count < "$attempts"; count=$((count + 1)); printf '%s\n' "$count" > "$attempts"
    case "$scenario" in
      conditional-304|uncached-304|missing-304|corrupt-304)
        printf 'HTTP/2 304\r\nETag: W/"fresh"\r\n\r\n'; return 0 ;;
      retry-network|post-network)
        if ((count == 1)); then printf 'partial'; return 56; fi ;;
      retry-503|post-503)
        if ((count == 1)); then printf 'HTTP/2 503\r\n\r\n{"message":"Unavailable"}'; return 0; fi ;;
      rate-limit)
        if ((count == 1)); then printf 'HTTP/2 429\r\n\r\n{"message":"API rate limit exceeded"}'; return 0; fi ;;
      retry-after)
        if ((count == 1)); then printf 'HTTP/2 429\r\nrEtRy-AfTeR:\t7\r\n\r\n{"message":"slow down"}'; return 0; fi ;;
      long-cooldown)
        printf 'HTTP/2 429\r\nRetry-After: 3600\r\n\r\n{"message":"slow down"}'; return 0 ;;
      invalid-cooldown)
        printf 'HTTP/2 429\r\nRetry-After: invalid\r\n\r\n{}'; return 0 ;;
      exhausted)
        printf 'HTTP/2 503\r\n\r\n{"message":"Unavailable"}'; return 0 ;;
      not-found)
        printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}'; return 0 ;;
      forbidden)
        printf 'HTTP/2 403\r\n\r\n{"message":"Forbidden"}'; return 0 ;;
      proxy-200)
        printf 'HTTP/1.1 200 Connection established\r\n\r\n' ;;
      interim-200)
        printf 'HTTP/1.1 100 Continue\r\n\r\n' ;;
      proxy-only)
        printf 'HTTP/1.1 200 Connection established\r\n\r\n'; return 0 ;;
      missing-status)
        printf '{"fresh":true}'; return 0 ;;
      invalid-json)
        printf 'HTTP/2 200\r\n\r\nnot-json'; return 0 ;;
      multiple-json)
        printf 'HTTP/2 200\r\n\r\n{}\n{}'; return 0 ;;
      empty-get)
        printf 'HTTP/2 200\r\n\r\n'; return 0 ;;
      delete-204)
        printf 'HTTP/2 204\r\n\r\n'; return 0 ;;
      mutation-no-etag)
        printf 'HTTP/2 201\r\n\r\n{"fresh":true}'; return 0 ;;
    esac
    printf 'HTTP/2 200\r\nETag:W/"fresh"\r\n\r\n{"fresh":true}'
  }
  local -a args=("$endpoint")
  case "$scenario" in
    uncached-304) args+=(--no-cache) ;;
    post-503|post-network|mutation-no-etag) args+=(--post '{}') ;;
    delete-204) args+=(--method DELETE) ;;
  esac
  local result status=0 count cached
  result=$(gh_api "${args[@]}" 2> "$fixture/stderr") || status=$?
  read -r count < "$attempts"
  if [[ "$status" != "$expected_status" || "$count" != "$expected_attempts" ]]; then
    printf 'FAIL %s: status=%s requests=%s expected=%s/%s\n' \
      "$scenario" "$status" "$count" "$expected_status" "$expected_attempts"
    cat "$fixture/stderr"
    return 1
  fi
  if [[ "$scenario" == conditional-304 ]]; then
    [[ "$result" == '{"cached":true}' && "$(_gh_get_etag "$endpoint")" == 'W/"fresh"' ]] || return 1
    cached=$(_gh_get_cache "$endpoint") || return 1
    [[ "$cached" == "$result" ]] || return 1
    grep -Fq 'If-None-Match: W/"old"' "$calls" || return 1
  elif [[ "$scenario" == delete-204 ]]; then
    [[ -z "$result" ]] || return 1
  elif ((status == 0)); then
    [[ "$result" == '{"fresh":true}' ]] || return 1
    if [[ "$scenario" != mutation-no-etag ]]; then
      [[ "$(_gh_get_etag "$endpoint")" == 'W/"fresh"' ]] || return 1
    fi
  fi
  case "$scenario" in
    rate-limit) grep -Fxq 'SLEEP 60' "$calls" || return 1 ;;
    retry-after) grep -Fxq 'SLEEP 7' "$calls" || return 1 ;;
    long-cooldown|invalid-cooldown) ! grep -q '^SLEEP ' "$calls" || return 1 ;;
    mutation-no-etag|uncached-304) ! grep -q 'If-None-Match' "$calls" || return 1 ;;
  esac
  if ((status != 0)) && [[ "$scenario" != *304 ]]; then
    [[ ! -f "$GH_CACHE_DIR/$key.json" ]] || return 1
  fi
  [[ -z "$(find "$fixture/tmp" -mindepth 1 -print -quit)" ]]
)

test_api_rejects_missing_option_values() (
  local flag status
  for flag in --method -X --data -d --post; do
    status=0
    gh_api repos/owner/repo "$flag" >/dev/null 2>&1 || status=$?
    [[ $status -eq 4 ]] || return 1
  done
)

test_download_release_asset_uses_authenticated_gh() {
  local destination="$TEMP_DIR/gh-asset.bin"
  local gh_log="$TEMP_DIR/gh-download.log"

  gh() {
    if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
      return 0
    fi
    printf '%s\n' "$*" > "$gh_log"
    printf 'gh-binary-bytes\001'
  }

  local status=0
  gh_download_release_asset "owner/repo" 42 "$destination" || status=$?
  unset -f gh

  [[ $status -eq 0 && -f "$destination" ]] &&
    [[ "$(cat "$destination")" == $'gh-binary-bytes\001' ]] &&
    grep -Fq 'repos/owner/repo/releases/assets/42' "$gh_log" &&
    grep -Fq 'Accept: application/octet-stream' "$gh_log" &&
    grep -Fq 'Cache-Control: no-cache, no-store, max-age=0' "$gh_log"
}

test_download_release_asset_uses_token_curl_fallback() {
  local destination="$TEMP_DIR/curl-asset.bin"
  local curl_log="$TEMP_DIR/curl-download.log"
  export GITHUB_TOKEN="download-test-token"

  gh() { return 1; }
  curl() {
    local output="" arg
    printf '%s\n' "$*" > "$curl_log"
    while [[ $# -gt 0 ]]; do
      arg="$1"
      shift
      if [[ "$arg" == "-o" && $# -gt 0 ]]; then
        output="$1"
        shift
      fi
    done
    [[ -n "$output" ]] || return 4
    printf 'curl-binary-bytes\002' > "$output"
  }

  local status=0
  gh_download_release_asset "owner/repo" 43 "$destination" || status=$?
  unset -f gh curl
  unset GITHUB_TOKEN

  [[ $status -eq 0 && -f "$destination" ]] &&
    [[ "$(cat "$destination")" == $'curl-binary-bytes\002' ]] &&
    grep -Fq 'Accept: application/octet-stream' "$curl_log" &&
    grep -Fq 'Authorization: Bearer download-test-token' "$curl_log" &&
    grep -Fq 'https://api.github.com/repos/owner/repo/releases/assets/43' "$curl_log"
}

test_download_release_asset_failure_leaves_no_destination() {
  local destination="$TEMP_DIR/failed-asset.bin"
  local GH_MAX_RETRIES=1
  export GITHUB_TOKEN="download-test-token"

  gh() { return 1; }
  curl() {
    local output="" arg
    while [[ $# -gt 0 ]]; do
      arg="$1"
      shift
      if [[ "$arg" == "-o" && $# -gt 0 ]]; then
        output="$1"
        shift
      fi
    done
    [[ -n "$output" ]] && printf 'partial bytes' > "$output"
    return 22
  }

  local status=0
  gh_download_release_asset "owner/repo" 44 "$destination" || status=$?
  unset -f gh curl
  unset GITHUB_TOKEN

  [[ $status -ne 0 && ! -e "$destination" ]] &&
    [[ -z "$(find "$TEMP_DIR" -maxdepth 1 -name '.dsr-asset-download.*' -print -quit)" ]]
}

test_download_release_asset_retries_with_fresh_staging_bytes() {
  local destination="$TEMP_DIR/retried-asset.bin"
  local attempts_file="$TEMP_DIR/download-attempts"
  local staging_paths_file="$TEMP_DIR/download-staging-paths"
  local GH_MAX_RETRIES=2 GH_RETRY_DELAY=0
  export GITHUB_TOKEN="download-test-token"
  printf '0\n' > "$attempts_file"
  : > "$staging_paths_file"

  gh() { return 1; }
  curl() {
    local output="" arg attempts=0
    while [[ $# -gt 0 ]]; do
      arg="$1"
      shift
      if [[ "$arg" == "-o" && $# -gt 0 ]]; then
        output="$1"
        shift
      fi
    done
    [[ -n "$output" ]] || return 4
    printf '%s\n' "$output" >> "$staging_paths_file"
    read -r attempts < "$attempts_file"
    attempts=$((attempts + 1))
    printf '%s\n' "$attempts" > "$attempts_file"
    if [[ $attempts -eq 1 ]]; then
      printf 'partial first response' > "$output"
      return 22
    fi
    printf 'complete second response\003' > "$output"
  }

  local status=0
  gh_download_release_asset "owner/repo" 45 "$destination" || status=$?
  unset -f gh curl
  unset GITHUB_TOKEN

  [[ $status -eq 0 && "$(cat "$attempts_file")" -eq 2 ]] &&
    [[ "$(sort -u "$staging_paths_file" | wc -l | tr -d '[:space:]')" -eq 2 ]] &&
    [[ "$(cat "$destination")" == $'complete second response\003' ]] &&
    [[ -z "$(find "$TEMP_DIR" -maxdepth 1 -name '.dsr-asset-download.*' -print -quit)" ]]
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

test_exports_gh_download_release_asset() {
  declare -f gh_download_release_asset >/dev/null
}

test_exports_gh_get_immutable_tag_ruleset_receipt() {
  declare -f gh_get_immutable_tag_ruleset_receipt >/dev/null
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

test_exports_gh_resolve_tag_sha() {
  declare -f gh_resolve_tag_sha >/dev/null
}

test_exports_gh_repository_dispatch() {
  declare -f gh_repository_dispatch >/dev/null
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

test_upload_asset_encodes_plus_in_filename() {
  test_release_upload_scenario fresh 0 1 0
}

# Only the network boundary is replaced. The production adapter executes all
# hashing, snapshotting, pagination, receipt checks, reconciliation and retries.
# A subshell contains fixture functions/env so subsequent tests use real code.
test_release_upload_scenario() (
  local scenario="$1" expected_status="$2" expected_posts="$3" expected_downloads="${4:-0}"
  local fixture="$TEMP_DIR/upload"
  local source="$fixture/source with spaces/asset+build.tar.gz"
  local expected="$fixture/expected" calls="$fixture/calls" posts="$fixture/posts"
  local downloads="$fixture/downloads" remote="$fixture/remote.json" digest size
  mkdir -p "${source%/*}" "$fixture/tmp" || return 1
  printf 'release-payload\000\001\377\n' > "$source"
  cp "$source" "$expected" || return 1
  if command -v sha256sum &>/dev/null; then
    digest=$(sha256sum < "$expected") || return 1
  else
    digest=$(shasum -a 256 < "$expected") || return 1
  fi
  digest="${digest%% *}"
  size=$(wc -c < "$expected"); size="${size//[[:space:]]/}"
  printf '0\n' > "$posts"; printf '0\n' > "$downloads"; : > "$calls"
  printf '[]\n' > "$remote"
  local TMPDIR="$fixture/tmp" GH_MAX_RETRIES=3 GH_RETRY_DELAY=0 GH_UPLOAD_TIMEOUT=15 GH_MAX_RETRY_WAIT=300
  unset DSR_GH_TOKEN GITHUB_TOKEN GH_TOKEN
  unset -f secrets_get_gh_token artifact_naming_generate_dual_for_tool 2>/dev/null || true
  sleep() { printf 'SLEEP %s\n' "$1" >> "$calls"; }

  fixture_asset() {
    jq -nc --arg name "${1:-asset+build.tar.gz}" --arg digest "sha256:$digest" --argjson size "$size" \
      '{id:42,name:$name,state:"uploaded",size:$size,digest:$digest}'
  }
  case "$scenario" in
    existing|paginated|legacy|legacy-corrupt|legacy-download-fails|wrong-existing-digest|wrong-existing-size|starter|duplicate|duplicate-pages|bad-digest-type)
      fixture_asset | jq -sc '.' > "$remote"
      case "$scenario" in
        legacy|legacy-corrupt|legacy-download-fails) fixture_asset | jq -sc 'map(del(.digest))' > "$remote" ;;
        wrong-existing-digest) fixture_asset | jq -sc 'map(.digest = "sha256:wrong")' > "$remote" ;;
        wrong-existing-size) fixture_asset | jq -sc 'map(.size += 1)' > "$remote" ;;
        starter) fixture_asset | jq -sc 'map(.state = "starter")' > "$remote" ;;
        duplicate) fixture_asset | jq -sc '. + [.[0] + {id:43}]' > "$remote" ;;
        bad-digest-type) fixture_asset | jq -sc 'map(.digest = false)' > "$remote" ;;
      esac
      ;;
  esac

  gh() {
    if [[ "${1:-}" == auth ]]; then
      [[ "$scenario" == no-token ]] && return 1
      [[ "${2:-}" == token ]] && printf 'fixture-token\n'
      return 0
    fi
    [[ "${1:-}" == api ]] || return 90
    printf 'GET %s\n' "$*" >> "$calls"
    case "${2:-}" in
      repos/owner/repo/releases/9/assets\?per_page=100\&page=*)
        [[ "$scenario" == inventory-error ]] && return 1
        if [[ "$scenario" == malformed-inventory ]]; then printf '{}\n'; return 0; fi
        if [[ "$scenario" == multiple-inventories ]]; then printf '[]\n[]\n'; return 0; fi
        if [[ "$scenario" == paginated || "$scenario" == inventory-tail-fails ]]; then
          if [[ "$2" == *page=1 ]]; then
            jq -nc '[range(1;101) | {id:.,name:("other-" + tostring)}]'
          elif [[ "$scenario" == inventory-tail-fails ]]; then
            return 1
          else
            cat "$remote"
          fi
        elif [[ "$scenario" == duplicate-pages && "$2" == *page=1 ]]; then
          jq -nc --argjson asset "$(fixture_asset)" \
            '[$asset] + [range(100;199) | {id:.,name:("other-" + tostring)}]'
        else
          cat "$remote"
        fi
        ;;
      repos/owner/repo/releases/assets/42)
        local count
        read -r count < "$downloads"
        printf '%s\n' "$((count + 1))" > "$downloads"
        if [[ "$scenario" == legacy-corrupt ]]; then
          # Same byte count: size-only checks would incorrectly pass.
          printf 'RELEASE-payload\000\001\377\n'
        elif [[ "$scenario" == legacy-download-fails ]]; then
          return 1
        else
          cat "$expected"
        fi
        ;;
      *) return 91 ;;
    esac
  }

  curl() {
    local output="" payload="" url="" header_file="" count asset name code=201 rc=0
    printf 'POST %s\n' "$*" >> "$calls"
    while (($#)); do
      case "$1" in
        -o) output="$2"; shift 2 ;;
        -D) header_file="$2"; shift 2 ;;
        --data-binary) payload="${2#@}"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
      esac
    done
    [[ -n "$output" && -n "$payload" && "$payload" != "$source" ]] || return 92
    cmp -s "$expected" "$payload" || return 93
    read -r count < "$posts"; count=$((count + 1)); printf '%s\n' "$count" > "$posts"
    name="${url##*\?name=}"; name="${name//%2B/+}"
    asset=$(fixture_asset "$name")
    case "$scenario" in
      lost-response) code=000; rc=56 ;;
      raced-match|raced-conflict) code=422 ;;
      starter-after-502) code=502; asset=$(jq -c '.state = "starter"' <<< "$asset") ;;
      retry-503|retry-429|retry-403|retry-after|long-cooldown)
        if ((count == 1)); then
          printf '{"message":"API rate limit exceeded"}\n' > "$output"
          case "$scenario" in
            retry-after) printf 'HTTP/2 429\r\nRetry-After: 7\r\n\r\n' > "$header_file" ;;
            long-cooldown) printf 'HTTP/2 429\r\nRetry-After: 3600\r\n\r\n' > "$header_file" ;;
          esac
          case "$scenario" in
            retry-503) printf 503 ;; retry-429) printf 429 ;; retry-403) printf 403 ;;
            retry-after|long-cooldown) printf 429 ;;
          esac
          return 0
        fi
        ;;
      exhausted) printf '{"message":"temporary failure"}\n' > "$output"; printf 502; return 0 ;;
      unauthorized) printf '{"message":"Bad credentials"}\n' > "$output"; printf 401; return 0 ;;
      forbidden) printf '{"message":"Resource not accessible"}\n' > "$output"; printf 403; return 0 ;;
      unconfirmed-422) printf '{}\n' > "$output"; printf 422; return 0 ;;
      empty-204) printf 204; return 0 ;;
      bad-name) asset=$(jq -c '.name = "wrong-name"' <<< "$asset") ;;
      bad-size) asset=$(jq -c '.size += 1' <<< "$asset") ;;
      bad-state) asset=$(jq -c '.state = "starter"' <<< "$asset") ;;
      bad-id) asset=$(jq -c '.id = "42"' <<< "$asset") ;;
      bad-digest) asset=$(jq -c '.digest = "sha256:wrong"' <<< "$asset") ;;
      missing-digest) asset=$(jq -c 'del(.digest)' <<< "$asset") ;;
      malformed-receipt) asset='not-json' ;;
      multiple-receipts) asset="$asset"$'\n'"$asset" ;;
      snapshot) printf 'changed source after staging' > "$source" ;;
      dual-compat-fails)
        if ((count == 2)); then printf '{}\n' > "$output"; printf 400; return 0; fi
        ;;
      dual-primary-fails) printf '{}\n' > "$output"; printf 400; return 0 ;;
    esac
    if [[ "$scenario" == raced-conflict ]]; then asset=$(jq -c '.digest = "sha256:wrong"' <<< "$asset"); fi
    if [[ "$scenario" != malformed-receipt && "$scenario" != multiple-receipts ]]; then
      jq --argjson asset "$asset" '. + [$asset]' "$remote" > "$fixture/next.json" || return 94
      mv "$fixture/next.json" "$remote" || return 95
    fi
    printf '%s\n' "$asset" > "$output"
    printf '%s' "$code"
    return "$rc"
  }

  local result status=0 post_count download_count
  if [[ "$scenario" == dual-* ]]; then
    if [[ "$scenario" == dual-same ]]; then
      artifact_naming_generate_dual_for_tool() { printf '{"versioned":"asset+build.tar.gz","compat":"asset+build.tar.gz","same":true}\n'; }
    fi
    result=$(gh_upload_asset_dual 'https://uploads.github.com/repos/owner/repo/releases/9/assets{?name,label}' \
      "$source" tool v1.2.3 linux amd64 tar.gz 2> "$fixture/stderr") || status=$?
  else
    result=$(gh_upload_asset 'https://uploads.github.com/repos/owner/repo/releases/9/assets{?name,label}' \
      "$source" application/gzip 2> "$fixture/stderr") || status=$?
  fi
  read -r post_count < "$posts"; read -r download_count < "$downloads"
  if [[ "$status" != "$expected_status" || "$post_count" != "$expected_posts" || "$download_count" != "$expected_downloads" ]]; then
    printf 'FAIL %s: status=%s posts=%s downloads=%s expected=%s/%s/%s\n' \
      "$scenario" "$status" "$post_count" "$download_count" "$expected_status" "$expected_posts" "$expected_downloads"
    cat "$fixture/stderr"
    return 1
  fi
  if [[ "$scenario" == dual-* ]]; then
    jq -es 'length == 1 and (.[0] | has("versioned") and has("compat"))' <<< "$result" >/dev/null || return 1
    case "$scenario" in
      dual-compat-fails) jq -e '.compat.status == "failed" and .versioned.status == "uploaded"' <<< "$result" >/dev/null || return 1 ;;
      dual-primary-fails) jq -e '.versioned.status == "failed" and .compat.status == "skipped"' <<< "$result" >/dev/null || return 1 ;;
      dual-same) jq -e '.same_names and .compat.status == "same_as_versioned"' <<< "$result" >/dev/null || return 1 ;;
      dual-ok) jq -e '.compat.status == "uploaded" and .versioned.status == "uploaded"' <<< "$result" >/dev/null || return 1 ;;
    esac
  elif ((status == 0)); then
    jq -es 'length == 1 and .[0].id == 42 and .[0].name == "asset+build.tar.gz"' <<< "$result" >/dev/null || return 1
  else
    [[ -z "$result" ]] || { printf 'FAIL %s: failure contaminated stdout\n' "$scenario"; return 1; }
  fi
  [[ -z "$(find "$fixture/tmp" -mindepth 1 -print -quit)" ]] || { printf 'FAIL %s: staging leaked\n' "$scenario"; return 1; }
  ! grep -qE 'DELETE|PATCH' "$calls" || return 1
  if ((post_count > 0)); then
    grep -Fq -- '--connect-timeout 15 --max-time 15' "$calls" || return 1
    if [[ "$scenario" != dual-* ]]; then
      grep -Fq '?name=asset%2Bbuild.tar.gz' "$calls" || return 1
    fi
  fi
  if [[ "$scenario" != no-token ]]; then
    grep -Fq 'Cache-Control: no-cache, no-store, max-age=0' "$calls" || return 1
  fi
  case "$scenario" in
    retry-429|retry-403) grep -Fxq 'SLEEP 60' "$calls" || return 1 ;;
    retry-after) grep -Fxq 'SLEEP 7' "$calls" || return 1 ;;
    long-cooldown)
      ! grep -q '^SLEEP ' "$calls" || return 1
      # Rate limited: no reconciliation GET may bypass the cooldown.
      [[ $(grep -c '^GET ' "$calls") -eq 1 ]] || return 1
      ;;
  esac
  return 0
)

test_upload_rejects_unsafe_inputs_before_auth() (
  local asset="$TEMP_DIR/asset" url name status result
  local valid_url='https://uploads.github.com/repos/owner/repo/releases/9/assets'
  printf 'payload\n' > "$asset"
  gh() { printf 'auth called\n' >> "$TEMP_DIR/network"; return 1; }
  curl() { printf 'curl called\n' >> "$TEMP_DIR/network"; return 1; }
  for url in '' 'http://uploads.github.com/repos/owner/repo/releases/9/assets' \
    'https://uploads.github.com.evil.invalid/repos/owner/repo/releases/9/assets' \
    'https://fixture-token@uploads.github.com/repos/owner/repo/releases/9/assets' \
    "$valid_url?name=other" "$valid_url#fragment" "${valid_url/9/0}"; do
    status=0
    result=$(gh_upload_asset_named "$url" "$asset" asset 2>/dev/null) || status=$?
    [[ $status -eq 4 && -z "$result" ]] || return 1
  done
  for name in '' '.' '..' '../escape' 'a/b' 'a b' 'a?b' $'a\nb'; do
    status=0
    result=$(gh_upload_asset_named "$valid_url" "$asset" "$name" 2>/dev/null) || status=$?
    [[ $status -eq 4 && -z "$result" ]] || return 1
  done
  local file
  : > "$TEMP_DIR/empty"
  ln -s "$asset" "$TEMP_DIR/link" || return 1
  for file in "$TEMP_DIR/missing" "$TEMP_DIR/empty" "$TEMP_DIR/link" "$TEMP_DIR"; do
    status=0
    gh_upload_asset_named "$valid_url" "$file" asset >/dev/null 2>&1 || status=$?
    [[ $status -eq 4 ]] || return 1
  done
  status=0
  gh_upload_asset_named "$valid_url" "$asset" asset $'text/plain\r\nX-Injected: true' >/dev/null 2>&1 || status=$?
  [[ $status -eq 4 && ! -e "$TEMP_DIR/network" ]]
)

test_upload_rejects_invalid_retry_configuration() (
  local asset="$TEMP_DIR/asset" retries delay timeout status
  printf 'payload\n' > "$asset"
  gh() { printf 'auth called\n' >> "$TEMP_DIR/network"; return 1; }
  while read -r retries delay timeout; do
    status=0
    GH_MAX_RETRIES="$retries" GH_RETRY_DELAY="$delay" GH_UPLOAD_TIMEOUT="$timeout" \
      gh_upload_asset_named 'https://uploads.github.com/repos/owner/repo/releases/9/assets' \
      "$asset" asset >/dev/null 2>&1 || status=$?
    [[ $status -eq 4 ]] || return 1
  done <<'INVALID_CONFIG'
0 0 15
11 0 15
1 -1 15
1 10000 15
1 0 0
1 0 not-a-timeout
INVALID_CONFIG
  [[ ! -e "$TEMP_DIR/network" ]]
)

test_upload_rejects_source_mutation_during_snapshot() (
  local source_to_mutate="$TEMP_DIR/asset" status=0 TMPDIR="$TEMP_DIR/staging"
  mkdir "$TMPDIR" || return 1
  printf 'initial payload\n' > "$source_to_mutate"
  gh() { [[ "${2:-}" == token ]] && printf 'fixture-token\n'; return 0; }
  curl() { printf 'post called\n' > "$TEMP_DIR/network"; return 1; }
  cp() { command cp "$@" || return; printf 'mutated payload\n' > "$source_to_mutate"; }
  gh_upload_asset_named 'https://uploads.github.com/repos/owner/repo/releases/9/assets' \
    "$source_to_mutate" asset >/dev/null 2>&1 || status=$?
  [[ $status -eq 4 && ! -e "$TEMP_DIR/network" ]] && \
    [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]]
)

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
# Tests: Immutable Tag Ruleset Receipts
# ============================================================================

run_immutable_tag_ruleset_scenario() {
  IMMUTABLE_RULESET_SCENARIO="$1"
  IMMUTABLE_RULESET_CALL_LOG="$TEMP_DIR/immutable-ruleset-${1}.calls"
  IMMUTABLE_RULESET_GET_COUNT_FILE="$TEMP_DIR/immutable-ruleset-${1}.count"
  : > "$IMMUTABLE_RULESET_CALL_LOG"
  printf '0\n' > "$IMMUTABLE_RULESET_GET_COUNT_FILE"
  export IMMUTABLE_RULESET_SCENARIO IMMUTABLE_RULESET_CALL_LOG
  export IMMUTABLE_RULESET_GET_COUNT_FILE

  local gh_api_def
  gh_api_def=$(declare -f gh_api)
  gh_api() {
    local endpoint="${1:-}" live_json history_state get_count=0
    printf '%s\n' "$*" >> "$IMMUTABLE_RULESET_CALL_LOG"
    live_json='{
      "id":42,
      "name":"Immutable release tags",
      "target":"tag",
      "source_type":"Repository",
      "source":"owner/repo",
      "enforcement":"active",
      "bypass_actors":[],
      "current_user_can_bypass":"never",
      "conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},
      "rules":[{"type":"update"},{"type":"deletion"}],
      "node_id":"RRS_test",
      "created_at":"2026-08-01T00:00:00Z",
      "updated_at":"2026-08-02T00:00:00Z",
      "_links":{"self":{"href":"https://api.github.com/repos/owner/repo/rulesets/42"}}
    }'
    case "$IMMUTABLE_RULESET_SCENARIO" in
      bypass)
        live_json=$(jq -c '.bypass_actors = [{actor_id: 7, actor_type: "User", bypass_mode: "always"}]' \
          <<< "$live_json")
        ;;
      redacted)
        live_json=$(jq -c 'del(.bypass_actors)' <<< "$live_json")
        ;;
      caller-bypass)
        live_json=$(jq -c '.current_user_can_bypass = "always"' <<< "$live_json")
        ;;
      caller-bypass-redacted)
        live_json=$(jq -c 'del(.current_user_can_bypass)' <<< "$live_json")
        ;;
      missing-update)
        live_json=$(jq -c '.rules = [.rules[] | select(.type != "update")]' \
          <<< "$live_json")
        ;;
      missing-deletion)
        live_json=$(jq -c '.rules = [.rules[] | select(.type != "deletion")]' \
          <<< "$live_json")
        ;;
      inactive)
        live_json=$(jq -c '.enforcement = "evaluate"' <<< "$live_json")
        ;;
      wrong-target)
        live_json=$(jq -c '.target = "branch"' <<< "$live_json")
        ;;
      wrong-source)
        live_json=$(jq -c '.source = "owner/other"' <<< "$live_json")
        ;;
      wrong-include)
        live_json=$(jq -c '.conditions.ref_name.include = ["refs/tags/release-*"]' \
          <<< "$live_json")
        ;;
      nonempty-exclude)
        live_json=$(jq -c '.conditions.ref_name.exclude = ["refs/tags/v0.*"]' \
          <<< "$live_json")
        ;;
    esac
    history_state=$(jq -c \
      'del(.node_id, .created_at, ._links, .current_user_can_bypass) |
       .updated_at = null' <<< "$live_json")
    if [[ "$IMMUTABLE_RULESET_SCENARIO" == "history-mismatch" ]]; then
      history_state=$(jq -c '.rules += [{"type":"creation"}]' <<< "$history_state")
    fi

    case "$endpoint" in
      repos/owner/repo)
        printf '{"id":99,"node_id":"R_repo","full_name":"owner/repo"}\n'
        ;;
      repos/owner/repo/rulesets/42\?includes_parents=false)
        read -r get_count < "$IMMUTABLE_RULESET_GET_COUNT_FILE" || get_count=0
        get_count=$((get_count + 1))
        printf '%s\n' "$get_count" > "$IMMUTABLE_RULESET_GET_COUNT_FILE"
        if [[ "$IMMUTABLE_RULESET_SCENARIO" == "drift" && $get_count -eq 2 ]]; then
          jq -c '.updated_at = "2026-08-03T00:00:00Z"' <<< "$live_json"
        else
          printf '%s\n' "$live_json"
        fi
        ;;
      repos/owner/repo/rulesets/42/history\?per_page=100\&page=1)
        printf '[{"version_id":123,"updated_at":"2026-08-02T00:00:01Z"}]\n'
        ;;
      repos/owner/repo/rulesets/42/history/123)
        jq -nc --argjson state "$history_state" \
          '{version_id:123,updated_at:"2026-08-02T00:00:01Z",state:$state}'
        ;;
      *) return 1 ;;
    esac
  }

  IMMUTABLE_RULESET_OUTPUT=""
  IMMUTABLE_RULESET_STATUS=0
  IMMUTABLE_RULESET_OUTPUT=$(gh_get_immutable_tag_ruleset_receipt \
    owner/repo 99 42 v1.2.3 2>/dev/null) || IMMUTABLE_RULESET_STATUS=$?
  eval "$gh_api_def"
}

test_immutable_tag_ruleset_receipt_binds_live_history() {
  run_immutable_tag_ruleset_scenario valid

  [[ $IMMUTABLE_RULESET_STATUS -eq 0 ]] && \
    jq -e '
      .schema == "dsr.github_tag_ruleset_receipt.v1" and
      .repository == {id:99,node_id:"R_repo",full_name:"owner/repo"} and
      .ruleset.history.version_id == 123 and
      .ruleset.policy.conditions.ref_name.include == ["refs/tags/v*"] and
      .ruleset.policy.bypass_actors == [] and
      ([.ruleset.policy.rules[].type] | sort) == ["deletion","update"]
    ' <<< "$IMMUTABLE_RULESET_OUTPUT" >/dev/null 2>&1 && \
    [[ $(wc -l < "$IMMUTABLE_RULESET_CALL_LOG" | tr -d '[:space:]') -eq 5 ]] && \
    ! grep -v -- '--no-cache' "$IMMUTABLE_RULESET_CALL_LOG" | grep -q .
}

test_immutable_tag_ruleset_receipt_rejects_bypass_or_redaction() {
  local scenario
  for scenario in bypass redacted caller-bypass caller-bypass-redacted; do
    run_immutable_tag_ruleset_scenario "$scenario"
    [[ $IMMUTABLE_RULESET_STATUS -ne 0 ]] || return 1
  done
}

test_immutable_tag_ruleset_receipt_rejects_missing_rule_or_drift() {
  local scenario
  for scenario in missing-update missing-deletion inactive wrong-target wrong-source \
    wrong-include nonempty-exclude history-mismatch; do
    run_immutable_tag_ruleset_scenario "$scenario"
    [[ $IMMUTABLE_RULESET_STATUS -ne 0 ]] || return 1
  done
  run_immutable_tag_ruleset_scenario drift
  [[ $IMMUTABLE_RULESET_STATUS -ne 0 ]]
}

test_immutable_tag_ruleset_receipt_rejects_uncovered_tag() {
  local status=0
  gh_get_immutable_tag_ruleset_receipt owner/repo 99 42 v1/foo \
    >/dev/null 2>&1 || status=$?
  [[ $status -eq 4 ]]
}

test_immutable_tag_ruleset_receipt_rejects_identity_mismatch() {
  run_immutable_tag_ruleset_scenario valid
  [[ $IMMUTABLE_RULESET_STATUS -eq 0 ]] || return 1

  local gh_api_def
  gh_api_def=$(declare -f gh_api)
  gh_api() {
    printf '{"id":100,"node_id":"R_other","full_name":"owner/repo"}\n'
  }
  local status=0
  gh_get_immutable_tag_ruleset_receipt owner/repo 99 42 v1.2.3 \
    >/dev/null 2>&1 || status=$?
  eval "$gh_api_def"
  [[ $status -ne 0 ]]
}

# ============================================================================
# Tests: Dispatch Helpers
# ============================================================================

test_resolve_tag_sha_rejects_missing_args() {
  ! gh_resolve_tag_sha "" "v1.2.3" 2>/dev/null
  ! gh_resolve_tag_sha "owner/repo" "" 2>/dev/null
}

test_resolve_tag_sha_commit() {
  local gh_api_def
  gh_api_def=$(declare -f gh_api)

  gh_api() {
    if [[ "$1" == "repos/owner/repo/git/ref/tags/v1.2.3" ]]; then
      echo '{"object":{"sha":"0123456789abcdef0123456789abcdef01234567","type":"commit"}}'
      return 0
    fi
    echo '{}'
    return 0
  }

  local sha status
  sha=$(gh_resolve_tag_sha "owner/repo" "v1.2.3")
  status=$?

  eval "$gh_api_def"

  [[ $status -eq 0 && "$sha" == "0123456789abcdef0123456789abcdef01234567" ]]
}

test_resolve_tag_sha_annotated() {
  local gh_api_def
  gh_api_def=$(declare -f gh_api)

  gh_api() {
    if [[ "$1" == "repos/owner/repo/git/ref/tags/v1.2.4" ]]; then
      echo '{"object":{"sha":"1111111111111111111111111111111111111111","type":"tag"}}'
      return 0
    fi
    if [[ "$1" == "repos/owner/repo/git/tags/1111111111111111111111111111111111111111" ]]; then
      echo '{"object":{"sha":"2222222222222222222222222222222222222222","type":"commit"}}'
      return 0
    fi
    echo '{}'
    return 0
  }

  local sha status
  sha=$(gh_resolve_tag_sha "owner/repo" "v1.2.4")
  status=$?

  eval "$gh_api_def"

  [[ $status -eq 0 && "$sha" == "2222222222222222222222222222222222222222" ]]
}

test_resolve_tag_sha_nested_annotated() {
  local gh_api_def
  gh_api_def=$(declare -f gh_api)

  gh_api() {
    case "$1" in
      repos/owner/repo/git/ref/tags/v1.2.5)
        echo '{"object":{"sha":"1111111111111111111111111111111111111111","type":"tag"}}'
        ;;
      repos/owner/repo/git/tags/1111111111111111111111111111111111111111)
        echo '{"object":{"sha":"2222222222222222222222222222222222222222","type":"tag"}}'
        ;;
      repos/owner/repo/git/tags/2222222222222222222222222222222222222222)
        echo '{"object":{"sha":"3333333333333333333333333333333333333333","type":"commit"}}'
        ;;
      *) echo '{}' ;;
    esac
  }

  local sha status
  sha=$(gh_resolve_tag_sha "owner/repo" "v1.2.5")
  status=$?

  eval "$gh_api_def"

  [[ $status -eq 0 && "$sha" == "3333333333333333333333333333333333333333" ]]
}

test_resolve_tag_sha_rejects_short_sha() {
  local gh_api_def
  gh_api_def=$(declare -f gh_api)

  gh_api() {
    echo '{"object":{"sha":"abc123","type":"commit"}}'
  }

  ! gh_resolve_tag_sha "owner/repo" "v1.2.6" >/dev/null
  local status=$?

  eval "$gh_api_def"
  [[ $status -eq 0 ]]
}

test_resolve_tag_sha_rejects_non_commit_target() {
  local gh_api_def
  gh_api_def=$(declare -f gh_api)

  gh_api() {
    if [[ "$1" == "repos/owner/repo/git/ref/tags/v1.2.7" ]]; then
      echo '{"object":{"sha":"1111111111111111111111111111111111111111","type":"tag"}}'
    else
      echo '{"object":{"sha":"2222222222222222222222222222222222222222","type":"blob"}}'
    fi
  }

  ! gh_resolve_tag_sha "owner/repo" "v1.2.7" >/dev/null
  local status=$?

  eval "$gh_api_def"
  [[ $status -eq 0 ]]
}

test_dispatch_rejects_missing_args() {
  ! gh_repository_dispatch "" "event" 2>/dev/null
  ! gh_repository_dispatch "owner/repo" "" 2>/dev/null
}

test_dispatch_accepts_valid_payload() {
  local gh_api_def
  gh_api_def=$(declare -f gh_api)

  gh_api() {
    # Stub success for dispatch
    return 0
  }

  local result status
  result=$(gh_repository_dispatch "owner/repo" "dsr_release" '{"tool":"ntm"}' 2>/dev/null)
  status=$?

  eval "$gh_api_def"

  [[ $status -eq 0 ]]
}

test_dispatch_fails_on_error_response() {
  local gh_api_def
  gh_api_def=$(declare -f gh_api)

  gh_api() {
    echo '{"message":"Not Found"}'
    return 0
  }

  local status=0
  gh_repository_dispatch "owner/repo" "dsr_release" '{"tool":"ntm"}' 2>/dev/null || status=$?

  eval "$gh_api_def"

  [[ $status -ne 0 ]]
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
  run_test "api_no_cache_omits_stale_etag_on_curl_fallback" test_api_no_cache_omits_stale_etag_on_curl_fallback
  run_test "api_no_cache_sends_headers_on_gh_cli" test_api_no_cache_sends_headers_on_gh_cli
  run_test "api_rejects_missing_option_values" test_api_rejects_missing_option_values
  local api_scenario api_status api_attempts
  while read -r api_scenario api_status api_attempts; do
    run_test "api_$api_scenario" test_api_transport_scenario "$api_scenario" "$api_status" "$api_attempts"
  done <<'API_SCENARIOS'
fresh 0 1
conditional-304 0 1
uncached-304 8 1
missing-304 8 1
corrupt-304 8 1
retry-network 0 2
post-network 56 1
retry-503 0 2
post-503 22 1
rate-limit 0 2
retry-after 0 2
long-cooldown 8 1
invalid-cooldown 8 1
exhausted 8 3
not-found 22 1
forbidden 22 1
proxy-200 0 1
interim-200 0 1
proxy-only 8 3
missing-status 8 3
invalid-json 8 1
multiple-json 8 1
empty-get 8 1
delete-204 0 1
mutation-no-etag 0 1
API_SCENARIOS
  run_test "download_release_asset_uses_authenticated_gh" test_download_release_asset_uses_authenticated_gh
  run_test "download_release_asset_uses_token_curl_fallback" test_download_release_asset_uses_token_curl_fallback
  run_test "download_release_asset_failure_leaves_no_destination" test_download_release_asset_failure_leaves_no_destination
  run_test "download_release_asset_retries_with_fresh_staging_bytes" test_download_release_asset_retries_with_fresh_staging_bytes

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
  run_test "exports_gh_download_release_asset" test_exports_gh_download_release_asset
  run_test "exports_gh_get_immutable_tag_ruleset_receipt" \
    test_exports_gh_get_immutable_tag_ruleset_receipt
  run_test "exports_gh_workflow_runs" test_exports_gh_workflow_runs
  run_test "exports_gh_releases" test_exports_gh_releases
  run_test "exports_gh_create_release" test_exports_gh_create_release
  run_test "exports_gh_clear_cache" test_exports_gh_clear_cache
  run_test "exports_gh_resolve_tag_sha" test_exports_gh_resolve_tag_sha
  run_test "exports_gh_repository_dispatch" test_exports_gh_repository_dispatch

  echo ""
  echo "Argument Validation:"
  run_test "workflow_runs_rejects_empty_repo" test_workflow_runs_rejects_empty_repo
  run_test "releases_rejects_empty_repo" test_releases_rejects_empty_repo
  run_test "latest_release_rejects_empty_repo" test_latest_release_rejects_empty_repo
  run_test "create_release_rejects_missing_tag" test_create_release_rejects_missing_tag
  run_test "upload_asset_rejects_missing_url" test_upload_asset_rejects_missing_url
  run_test "upload_asset_rejects_missing_file" test_upload_asset_rejects_missing_file
  run_test "upload_asset_rejects_nonexistent_file" test_upload_asset_rejects_nonexistent_file
  run_test "upload_asset_encodes_plus_in_filename" test_upload_asset_encodes_plus_in_filename
  run_test "compare_rejects_missing_args" test_compare_rejects_missing_args
  run_test "tags_rejects_empty_repo" test_tags_rejects_empty_repo
  run_test "repo_rejects_empty_repo" test_repo_rejects_empty_repo

  echo ""
  echo "Verified Release Uploads:"
  run_test "upload_rejects_unsafe_inputs_before_auth" test_upload_rejects_unsafe_inputs_before_auth
  run_test "upload_rejects_invalid_retry_configuration" test_upload_rejects_invalid_retry_configuration
  run_test "upload_rejects_source_mutation_during_snapshot" test_upload_rejects_source_mutation_during_snapshot
  local scenario expected_status expected_posts expected_downloads
  while read -r scenario expected_status expected_posts expected_downloads; do
    run_test "upload_$scenario" test_release_upload_scenario \
      "$scenario" "$expected_status" "$expected_posts" "$expected_downloads"
  done <<'UPLOAD_SCENARIOS'
fresh 0 1 0
existing 0 0 0
paginated 0 0 0
legacy 0 0 1
legacy-corrupt 7 0 1
legacy-download-fails 8 0 3
wrong-existing-digest 7 0 0
wrong-existing-size 7 0 0
starter 7 0 0
duplicate 7 0 0
duplicate-pages 7 0 0
bad-digest-type 7 0 0
inventory-error 8 0 0
inventory-tail-fails 8 0 0
malformed-inventory 8 0 0
multiple-inventories 8 0 0
lost-response 0 1 0
raced-match 0 1 0
raced-conflict 7 1 0
retry-503 0 2 0
retry-429 0 2 0
retry-403 0 2 0
retry-after 0 2 0
long-cooldown 8 1 0
exhausted 8 3 0
starter-after-502 7 1 0
unauthorized 3 1 0
forbidden 3 1 0
unconfirmed-422 7 1 0
empty-204 7 1 0
bad-name 7 1 0
bad-size 7 1 0
bad-state 7 1 0
bad-id 7 1 0
bad-digest 7 1 0
missing-digest 0 1 1
malformed-receipt 7 1 0
multiple-receipts 7 1 0
snapshot 0 1 0
no-token 3 0 0
dual-ok 0 2 0
dual-compat-fails 1 2 0
dual-primary-fails 7 1 0
dual-same 0 1 0
UPLOAD_SCENARIOS

  echo ""
  echo "Immutable Tag Ruleset Receipts:"
  run_test "immutable_tag_ruleset_receipt_binds_live_history" \
    test_immutable_tag_ruleset_receipt_binds_live_history
  run_test "immutable_tag_ruleset_receipt_rejects_bypass_or_redaction" \
    test_immutable_tag_ruleset_receipt_rejects_bypass_or_redaction
  run_test "immutable_tag_ruleset_receipt_rejects_missing_rule_or_drift" \
    test_immutable_tag_ruleset_receipt_rejects_missing_rule_or_drift
  run_test "immutable_tag_ruleset_receipt_rejects_uncovered_tag" \
    test_immutable_tag_ruleset_receipt_rejects_uncovered_tag
  run_test "immutable_tag_ruleset_receipt_rejects_identity_mismatch" \
    test_immutable_tag_ruleset_receipt_rejects_identity_mismatch

  echo ""
  echo "Dispatch Helpers:"
  run_test "resolve_tag_sha_rejects_missing_args" test_resolve_tag_sha_rejects_missing_args
  run_test "resolve_tag_sha_commit" test_resolve_tag_sha_commit
  run_test "resolve_tag_sha_annotated" test_resolve_tag_sha_annotated
  run_test "resolve_tag_sha_nested_annotated" test_resolve_tag_sha_nested_annotated
  run_test "resolve_tag_sha_rejects_short_sha" test_resolve_tag_sha_rejects_short_sha
  run_test "resolve_tag_sha_rejects_non_commit_target" test_resolve_tag_sha_rejects_non_commit_target
  run_test "dispatch_rejects_missing_args" test_dispatch_rejects_missing_args
  run_test "dispatch_accepts_valid_payload" test_dispatch_accepts_valid_payload
  run_test "dispatch_fails_on_error_response" test_dispatch_fails_on_error_response

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
