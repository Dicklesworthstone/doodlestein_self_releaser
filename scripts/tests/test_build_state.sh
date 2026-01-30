#!/usr/bin/env bash
# test_build_state.sh - Tests for src/build_state.sh
#
# Run: ./scripts/tests/test_build_state.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }

# Setup test environment
TEMP_DIR=$(mktemp -d)
export DSR_STATE_DIR="$TEMP_DIR/state"
DSR_RUN_ID="test-run-$(date +%s)-$$"
export DSR_RUN_ID

# Stub logging functions
log_info() { :; }
log_warn() { :; }
log_error() { echo "ERROR: $*" >&2; }
log_debug() { :; }
export -f log_info log_warn log_error log_debug

# Source the build_state module
source "$PROJECT_ROOT/src/build_state.sh"

# ============================================================================
# Lock Tests
# ============================================================================

test_build_lock_acquire() {
  ((TESTS_RUN++))
  build_state_init

  if build_lock_acquire "test-tool" "v1.0.0"; then
    pass "build_lock_acquire succeeds"
  else
    fail "build_lock_acquire should succeed"
  fi
  build_lock_release "test-tool" "v1.0.0"
}

test_build_lock_blocks_concurrent() {
  ((TESTS_RUN++))
  build_state_init

  build_lock_acquire "test-tool2" "v1.0.0" || true

  # Try to acquire same lock (should fail)
  if build_lock_acquire "test-tool2" "v1.0.0" 2>/dev/null; then
    fail "build_lock_acquire should fail for concurrent access"
    build_lock_release "test-tool2" "v1.0.0"
  else
    pass "build_lock_acquire blocks concurrent access"
  fi
  build_lock_release "test-tool2" "v1.0.0"
}

test_build_lock_release() {
  ((TESTS_RUN++))
  build_state_init

  build_lock_acquire "test-tool3" "v1.0.0" || true
  if build_lock_release "test-tool3" "v1.0.0"; then
    pass "build_lock_release succeeds"
  else
    fail "build_lock_release should succeed"
  fi
}

test_build_lock_check() {
  ((TESTS_RUN++))
  build_state_init

  # Should not be locked initially
  if build_lock_check "test-tool4" "v1.0.0"; then
    fail "build_lock_check should return false when not locked"
  else
    # Now acquire lock
    build_lock_acquire "test-tool4" "v1.0.0" || true
    if build_lock_check "test-tool4" "v1.0.0"; then
      pass "build_lock_check detects lock correctly"
    else
      fail "build_lock_check should detect lock"
    fi
    build_lock_release "test-tool4" "v1.0.0"
  fi
}

test_build_lock_info() {
  ((TESTS_RUN++))
  build_state_init

  build_lock_acquire "test-tool5" "v1.0.0" || true
  local info
  info=$(build_lock_info "test-tool5" "v1.0.0")

  if echo "$info" | jq -e '.locked == true' >/dev/null 2>&1; then
    pass "build_lock_info returns valid JSON"
  else
    fail "build_lock_info should return locked=true"
  fi
  build_lock_release "test-tool5" "v1.0.0"
}

# ============================================================================
# State Tests
# ============================================================================

test_build_state_create() {
  ((TESTS_RUN++))
  build_state_init

  local run_id
  run_id=$(build_state_create "ntm" "v1.2.3" "linux/amd64,darwin/arm64")

  if [[ -n "$run_id" && "$run_id" =~ ^(test-)?run- ]]; then
    pass "build_state_create returns run_id"
  else
    fail "build_state_create should return run_id, got: $run_id"
  fi
}

test_build_state_get() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm2" "v1.0.0" "linux/amd64" >/dev/null
  local state
  state=$(build_state_get "ntm2" "v1.0.0" "latest")

  if echo "$state" | jq -e '.tool == "ntm2"' >/dev/null 2>&1; then
    pass "build_state_get returns valid state"
  else
    fail "build_state_get should return tool name in state"
  fi
}

test_build_state_update_status() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm3" "v1.0.0" "" >/dev/null
  build_state_update_status "ntm3" "v1.0.0" "running"

  local state
  state=$(build_state_get "ntm3" "v1.0.0" "latest")

  if echo "$state" | jq -e '.status == "running"' >/dev/null 2>&1; then
    pass "build_state_update_status updates status"
  else
    fail "build_state_update_status should update status"
  fi
}

test_build_state_update_host() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm4" "v1.0.0" "linux/amd64" >/dev/null
  build_state_update_host "ntm4" "v1.0.0" "trj" "running"
  build_state_update_host "ntm4" "v1.0.0" "trj" "completed" '{"duration_ms": 5000}'

  local state
  state=$(build_state_get "ntm4" "v1.0.0" "latest")

  if echo "$state" | jq -e '.hosts.trj.status == "completed"' >/dev/null 2>&1; then
    if echo "$state" | jq -e '.hosts.trj.duration_ms == 5000' >/dev/null 2>&1; then
      pass "build_state_update_host updates host with extra data"
    else
      fail "build_state_update_host should preserve extra data"
    fi
  else
    fail "build_state_update_host should update host status"
  fi
}

test_build_state_add_artifact() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm5" "v1.0.0" "" >/dev/null
  build_state_add_artifact "ntm5" "v1.0.0" "ntm-linux-amd64" "/tmp/artifact" "abc123"

  local state
  state=$(build_state_get "ntm5" "v1.0.0" "latest")

  if echo "$state" | jq -e '.artifacts | length > 0' >/dev/null 2>&1; then
    pass "build_state_add_artifact adds artifact"
  else
    fail "build_state_add_artifact should add artifact"
  fi
}

# ============================================================================
# Resume Tests
# ============================================================================

test_build_state_can_resume() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm6" "v1.0.0" "" >/dev/null
  build_state_update_status "ntm6" "v1.0.0" "failed"

  if build_state_can_resume "ntm6" "v1.0.0"; then
    pass "build_state_can_resume returns true for failed build"
  else
    fail "build_state_can_resume should return true for failed"
  fi

  build_state_update_status "ntm6" "v1.0.0" "completed"
  if build_state_can_resume "ntm6" "v1.0.0"; then
    fail "build_state_can_resume should return false for completed"
  else
    pass "build_state_can_resume returns false for completed"
  fi
}

test_build_state_completed_hosts() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm7" "v1.0.0" "trj,mmini" >/dev/null
  build_state_update_host "ntm7" "v1.0.0" "trj" "completed"
  build_state_update_host "ntm7" "v1.0.0" "mmini" "failed"

  local completed
  completed=$(build_state_completed_hosts "ntm7" "v1.0.0")

  if [[ "$completed" == "trj" ]]; then
    pass "build_state_completed_hosts returns completed hosts"
  else
    fail "build_state_completed_hosts should return trj, got: $completed"
  fi
}

# ============================================================================
# Workspace Tests
# ============================================================================

test_build_state_workspace() {
  ((TESTS_RUN++))
  build_state_init

  local run_id
  run_id=$(build_state_create "ntm8" "v1.0.0" "")

  local workspace
  workspace=$(build_state_workspace "ntm8" "v1.0.0" "$run_id")

  if [[ -d "$workspace" && "$workspace" == *"$run_id"* ]]; then
    pass "build_state_workspace returns valid directory"
  else
    fail "build_state_workspace should return valid directory, got: $workspace"
  fi
}

test_build_state_artifacts_dir() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm9" "v1.0.0" "" >/dev/null

  local artifacts_dir
  artifacts_dir=$(build_state_artifacts_dir "ntm9" "v1.0.0")

  if [[ -d "$artifacts_dir" && "$artifacts_dir" == */artifacts ]]; then
    pass "build_state_artifacts_dir returns valid directory"
  else
    fail "build_state_artifacts_dir should return valid directory"
  fi
}

test_build_state_list() {
  ((TESTS_RUN++))
  build_state_init

  # Create multiple builds with unique run IDs
  DSR_RUN_ID="run-$(date +%s)-1" build_state_create "ntm10" "v1.0.0" "" >/dev/null
  sleep 0.1
  DSR_RUN_ID="run-$(date +%s)-2" build_state_create "ntm10" "v1.0.0" "" >/dev/null

  local builds
  builds=$(build_state_list "ntm10" "v1.0.0" | wc -l)

  if [[ "$builds" -ge 2 ]]; then
    pass "build_state_list returns all builds"
  else
    fail "build_state_list should return at least 2 builds, got: $builds"
  fi
}

# ============================================================================
# Retry and Recovery Tests
# ============================================================================

test_build_retry_backoff_calculation() {
  ((TESTS_RUN++))

  local delay0 delay1 delay2
  delay0=$(_build_calc_backoff 0)
  delay1=$(_build_calc_backoff 1)
  delay2=$(_build_calc_backoff 2)

  # Exponential: base * 2^attempt (default base=5)
  # delay0 ~= 5, delay1 ~= 10, delay2 ~= 20 (plus jitter)
  if [[ "$delay1" -ge "$delay0" && "$delay2" -ge "$delay1" ]]; then
    pass "_build_calc_backoff increases exponentially"
  else
    fail "_build_calc_backoff: delays should increase (got $delay0, $delay1, $delay2)"
  fi
}

test_build_retry_with_backoff_success() {
  ((TESTS_RUN++))

  local attempt_count=0
  test_cmd() { ((attempt_count++)); return 0; }
  export -f test_cmd

  if build_retry_with_backoff 3 test_cmd; then
    if [[ "$attempt_count" -eq 1 ]]; then
      pass "build_retry_with_backoff succeeds on first try"
    else
      fail "build_retry_with_backoff: expected 1 attempt, got $attempt_count"
    fi
  else
    fail "build_retry_with_backoff should succeed"
  fi
}

test_build_retry_with_backoff_failure() {
  ((TESTS_RUN++))

  # Override retry settings for faster test
  BUILD_RETRY_BASE_DELAY=0

  if ! build_retry_with_backoff 2 false 2>/dev/null; then
    pass "build_retry_with_backoff fails after max attempts"
  else
    fail "build_retry_with_backoff should fail"
  fi

  BUILD_RETRY_BASE_DELAY=5
}

test_build_state_record_retry() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "retry-tool1" "v1.0.0" "trj" >/dev/null
  build_state_update_host "retry-tool1" "v1.0.0" "trj" "running"
  build_state_record_retry "retry-tool1" "v1.0.0" "trj" 1 "connection timeout"

  local state
  state=$(build_state_get "retry-tool1" "v1.0.0")

  if echo "$state" | jq -e '.hosts.trj.retry_count == 1' >/dev/null 2>&1; then
    if echo "$state" | jq -e '.hosts.trj.last_error == "connection timeout"' >/dev/null 2>&1; then
      pass "build_state_record_retry records attempt and error"
    else
      fail "build_state_record_retry should record error message"
    fi
  else
    fail "build_state_record_retry should increment retry_count"
  fi
}

test_build_state_get_retry_count() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "retry-tool2" "v1.0.0" "trj" >/dev/null
  build_state_update_host "retry-tool2" "v1.0.0" "trj" "running"

  local count
  count=$(build_state_get_retry_count "retry-tool2" "v1.0.0" "trj")

  if [[ "$count" -eq 0 ]]; then
    # Now add a retry
    build_state_record_retry "retry-tool2" "v1.0.0" "trj" 1 "error"
    count=$(build_state_get_retry_count "retry-tool2" "v1.0.0" "trj")
    if [[ "$count" -eq 1 ]]; then
      pass "build_state_get_retry_count returns correct count"
    else
      fail "build_state_get_retry_count should return 1, got: $count"
    fi
  else
    fail "build_state_get_retry_count should return 0 initially"
  fi
}

test_build_state_can_retry() {
  ((TESTS_RUN++))
  build_state_init

  # Override max retries for test
  BUILD_RETRY_MAX=2

  build_state_create "retry-tool3" "v1.0.0" "trj" >/dev/null
  build_state_update_host "retry-tool3" "v1.0.0" "trj" "running"

  # Should be able to retry initially
  if build_state_can_retry "retry-tool3" "v1.0.0" "trj"; then
    # Add retries up to limit
    build_state_record_retry "retry-tool3" "v1.0.0" "trj" 1 "error"
    build_state_record_retry "retry-tool3" "v1.0.0" "trj" 2 "error"

    # Should not be able to retry now
    if ! build_state_can_retry "retry-tool3" "v1.0.0" "trj"; then
      pass "build_state_can_retry respects retry limit"
    else
      fail "build_state_can_retry should return false after max retries"
    fi
  else
    fail "build_state_can_retry should return true initially"
  fi

  BUILD_RETRY_MAX=3
}

test_build_state_resume() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "resume-tool" "v1.0.0" "trj,mmini,wlap" >/dev/null
  build_state_update_status "resume-tool" "v1.0.0" "running"
  build_state_update_host "resume-tool" "v1.0.0" "trj" "completed"
  build_state_update_host "resume-tool" "v1.0.0" "mmini" "failed"
  # wlap is still pending

  local resume_plan
  resume_plan=$(build_state_resume "resume-tool" "v1.0.0")

  if echo "$resume_plan" | jq -e '.can_resume == true' >/dev/null 2>&1; then
    local hosts_to_process
    hosts_to_process=$(echo "$resume_plan" | jq -r '.hosts_to_process | length')
    # Should process wlap (pending) and mmini (failed, retryable)
    if [[ "$hosts_to_process" -ge 1 ]]; then
      pass "build_state_resume generates valid resume plan"
    else
      fail "build_state_resume should identify hosts to process"
    fi
  else
    fail "build_state_resume should return can_resume=true"
  fi
}

test_build_state_exec_with_retry() {
  ((TESTS_RUN++))
  build_state_init

  # Override settings for faster test
  BUILD_RETRY_MAX=2
  BUILD_RETRY_BASE_DELAY=0

  build_state_create "exec-tool" "v1.0.0" "trj" >/dev/null

  # Test with command that succeeds
  if build_state_exec_with_retry "exec-tool" "v1.0.0" "trj" true 2>/dev/null; then
    local state
    state=$(build_state_get "exec-tool" "v1.0.0")
    if echo "$state" | jq -e '.hosts.trj.status == "completed"' >/dev/null 2>&1; then
      pass "build_state_exec_with_retry marks host completed on success"
    else
      fail "build_state_exec_with_retry should mark host as completed"
    fi
  else
    fail "build_state_exec_with_retry should succeed with true command"
  fi

  BUILD_RETRY_MAX=3
  BUILD_RETRY_BASE_DELAY=5
}

# Cleanup
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "Running build_state module tests..."
echo ""

# Lock tests
test_build_lock_acquire
test_build_lock_blocks_concurrent
test_build_lock_release
test_build_lock_check
test_build_lock_info

# State tests
test_build_state_create
test_build_state_get
test_build_state_update_status
test_build_state_update_host
test_build_state_add_artifact

# Resume tests
test_build_state_can_resume
test_build_state_completed_hosts

# Workspace tests
test_build_state_workspace
test_build_state_artifacts_dir
test_build_state_list

# Retry tests
test_build_retry_backoff_calculation
test_build_retry_with_backoff_success
test_build_retry_with_backoff_failure
test_build_state_record_retry
test_build_state_get_retry_count
test_build_state_can_retry
test_build_state_resume
test_build_state_exec_with_retry

echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN"
echo "Passed:    $TESTS_PASSED"
echo "Failed:    $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
