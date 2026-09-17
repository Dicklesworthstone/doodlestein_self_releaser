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

test_build_state_rejects_run_collision() {
  ((TESTS_RUN++))
  build_state_init

  local first_state second_status=0
  build_state_create "collision-tool" "v1.0.0" "linux/amd64" >/dev/null
  first_state=$(build_state_get "collision-tool" "v1.0.0" "$DSR_RUN_ID")
  build_state_create "collision-tool" "v1.0.0" "darwin/arm64" >/dev/null 2>&1 || second_status=$?

  if [[ "$second_status" -ne 0 ]] &&
     [[ "$(build_state_get "collision-tool" "v1.0.0" "$DSR_RUN_ID")" == "$first_state" ]]; then
    pass "build_state_create preserves an existing immutable run namespace"
  else
    fail "build_state_create should reject a run ID collision without changing state"
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

test_build_state_update_preserves_private_mode() {
  ((TESTS_RUN++))
  build_state_init

  local run_id workspace state_file old_umask mode
  run_id=$(build_state_create "private-mode-tool" "v1.0.0" "linux/amd64")
  workspace=$(build_state_workspace "private-mode-tool" "v1.0.0" "$run_id")
  state_file="$workspace/state.json"
  old_umask=$(umask)
  umask 000
  build_state_update_status "private-mode-tool" "v1.0.0" "running" "$run_id"
  umask "$old_umask"
  mode=$(stat -c '%a' "$state_file" 2>/dev/null || stat -f '%Lp' "$state_file" 2>/dev/null)

  if [[ "$mode" == "600" ]]; then
    pass "atomic state updates retain mode 0600 under a permissive caller umask"
  else
    fail "atomic state update mode should be 600, got: $mode"
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

  ((TESTS_RUN++))
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

  # shellcheck disable=SC2034  # These are used by sourced build_state.sh
  BUILD_RETRY_MAX=3
  # shellcheck disable=SC2034
  BUILD_RETRY_BASE_DELAY=5
}

# Checkpoint transactions use real concurrent processes and files. Only the
# command boundary is replaced for deterministic write-failure/crash injection.
run_state_regression() {
  local name="$1"
  shift
  ((TESTS_RUN++))
  if ( "$@" ); then
    pass "$name"
  else
    fail "$name"
  fi
}

test_checkpoint_validation() {
  local dir="$TEMP_DIR/checkpoint-validation" filter before source status
  mkdir "$dir" || return 1
  source="$dir/state.json"
  before='{"run_id":"fixed","counter":0}'
  for filter in 'empty' '., .' '[]' 'null' 'true' '"text"' 'error("injected")' \
    '.run_id = "other"'; do
    printf '%s\n' "$before" > "$source"
    status=0
    _build_state_jq_update "$source" "$filter" 2>/dev/null || status=$?
    [[ $status -ne 0 && "$(cat "$source")" == "$before" ]] || return 1
  done
  for before in '' '{} {}' '[]' 'null' '{broken'; do
    printf '%s' "$before" > "$source"
    status=0
    _build_state_jq_update "$source" '{counter:1}' 2>/dev/null || status=$?
    [[ $status -ne 0 && "$(cat "$source")" == "$before" ]] || return 1
  done
  [[ -z "$(find "$dir" -mindepth 1 -type d -print)" ]]
}

test_checkpoint_foreign_temp_preserved() {
  local source="$TEMP_DIR/foreign-temp-state.json"
  printf '{"counter":0}\n' > "$source"
  printf 'another writer owns these bytes\n' > "$source.tmp.$$"
  _build_state_jq_update "$source" '.counter += 1' || return 1
  [[ "$(cat "$source.tmp.$$")" == 'another writer owns these bytes' ]] &&
    jq -e '.counter == 1' "$source" >/dev/null
}

test_checkpoint_descriptor_identity() {
  local source="$TEMP_DIR/descriptor-state.json" lock_identity
  printf '{"counter":0}\n' > "$source"
  : > "$source.update.lock"
  exec 9<> "$source.update.lock" || return 1
  lock_identity=$(_build_state_fd_identity 9) || return 1
  [[ "$lock_identity" == "$(_build_state_file_identity "$source.update.lock")" ]] || return 1
  mv "$source.update.lock" "$source.original-lock" || return 1
  : > "$source.update.lock"
  [[ "$lock_identity" == "$(_build_state_fd_identity 9)" ]] || return 1
  [[ "$lock_identity" != "$(_build_state_file_identity "$source.update.lock")" ]] || return 1
  exec 9>&-
  ! _build_state_fd_identity invalid 2>/dev/null
}

test_checkpoint_replaced_lock_rejected() {
  local source="$TEMP_DIR/replaced-lock-state.json" status=0
  printf '{"counter":0}\n' > "$source"
  _build_state_wait_lock() {
    mv "$source.update.lock" "$source.original-lock" || return 1
    : > "$source.update.lock"
  }
  _build_state_jq_update "$source" '.counter = 1' 2>/dev/null || status=$?
  [[ $status -ne 0 ]] && jq -e '.counter == 0' "$source" >/dev/null
}

test_checkpoint_concurrent_increments() {
  local source="$TEMP_DIR/concurrent-state.json" _worker _iteration pid result=0
  local -a pids=()
  printf '{"counter":0}\n' > "$source"
  for _worker in 1 2 3 4 5 6 7 8; do
    (
      for _iteration in 1 2 3 4 5 6; do
        _build_state_jq_update "$source" '.counter += 1' || exit 1
      done
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || result=1; done
  [[ $result -eq 0 ]] && jq -e '.counter == 48' "$source" >/dev/null
}

test_checkpoint_symlinks_rejected() {
  local original="$TEMP_DIR/symlink-original.json" source="$TEMP_DIR/symlink-state.json"
  printf '{"counter":0}\n' > "$original"
  ln -s "$original" "$source" || return 1
  ! _build_state_jq_update "$source" '.counter = 1' || return 1
  [[ -L "$source" ]] && jq -e '.counter == 0' "$original" >/dev/null || return 1
  source="$TEMP_DIR/symlink-lock-state.json"
  printf '{"counter":0}\n' > "$source"
  ln -s "$original" "$source.update.lock" || return 1
  ! _build_state_jq_update "$source" '.counter = 1' || return 1
  [[ -L "$source.update.lock" ]] && jq -e '.counter == 0' "$original" "$source" >/dev/null
}

test_checkpoint_publication_failure() {
  local source="$TEMP_DIR/failed-publication.json"
  printf '{"counter":0}\n' > "$source"
  mv() { return 1; }
  ! _build_state_jq_update "$source" '.counter = 1' || return 1
  unset -f mv
  jq -e '.counter == 0' "$source" >/dev/null || return 1
  _build_state_jq_update "$source" '.counter = 2' &&
    jq -e '.counter == 2' "$source" >/dev/null
}

test_checkpoint_external_write_detected() {
  local source="$TEMP_DIR/external-write.json" status=0
  printf '{"counter":0}\n' > "$source"
  jq() {
    if [[ "${1:-}" == '.counter = 99' ]]; then
      printf '{"counter":17}\n' > "$source"
    fi
    command jq "$@"
  }
  _build_state_jq_update "$source" '.counter = 99' 2>/dev/null || status=$?
  unset -f jq
  [[ $status -ne 0 ]] && jq -e '.counter == 17' "$source" >/dev/null
}

test_checkpoint_caller_scope_preserved() {
  local source="$TEMP_DIR/caller-scope.json" before after old_umask mode
  printf '{"counter":0}\n' > "$source"
  trap ':' INT TERM
  before=$(trap -p INT TERM)
  old_umask=$(umask)
  umask 000
  _build_state_jq_update "$source" '.counter = 1' || return 1
  [[ "$(umask)" == 0000 ]] || return 1
  umask "$old_umask"
  after=$(trap -p INT TERM)
  mode=$(stat -c %a "$source" 2>/dev/null || stat -f %Lp "$source")
  [[ "$before" == "$after" && "$mode" == 600 ]]
}

test_checkpoint_timeout_and_independent_files() {
  local label="${1:-native}"
  local source="$TEMP_DIR/$label-locked-state.json" other="$TEMP_DIR/$label-independent-state.json"
  local ready="$TEMP_DIR/$label-update-lock-ready" stop="$TEMP_DIR/$label-update-lock-stop"
  local pid _step status=0 result=0
  printf '{"counter":0}\n' > "$source"
  printf '{"counter":0}\n' > "$other"
  : > "$source.update.lock"
  (
    exec 9<> "$source.update.lock" || exit 1
    _build_state_wait_lock 9 1 || exit 1
    : > "$ready"
    for _step in {1..500}; do
      [[ -e "$stop" ]] && exit 0
      sleep 0.01
    done
    exit 1
  ) &
  pid=$!
  for _step in {1..300}; do [[ -e "$ready" ]] && break; sleep 0.01; done
  [[ -e "$ready" ]] || result=1
  DSR_STATE_LOCK_TIMEOUT=0 _build_state_jq_update "$source" '.counter = 1' \
    2>/dev/null || status=$?
  [[ $status -ne 0 ]] || result=1
  jq -e '.counter == 0' "$source" >/dev/null || result=1
  DSR_STATE_LOCK_TIMEOUT=0 _build_state_jq_update "$other" '.counter = 1' || result=1
  : > "$stop"
  wait "$pid" || result=1
  _build_state_jq_update "$source" '.counter = 2' || result=1
  [[ $result -eq 0 ]] && jq -e '.counter == 2' "$source" >/dev/null
}

test_checkpoint_crash_recovery() {
  local source="$TEMP_DIR/crashed-writer.json" status=0
  printf '{"counter":0}\n' > "$source"
  jq() {
    if [[ "${1:-}" == '.counter = 91' ]]; then
      # This is the isolated update subshell, never the caller/test runner.
      kill -KILL "$BASHPID"
    fi
    command jq "$@"
  }
  _build_state_jq_update "$source" '.counter = 91' 2>/dev/null || status=$?
  unset -f jq
  [[ $status -ne 0 ]] && jq -e '.counter == 0' "$source" >/dev/null || return 1
  DSR_STATE_LOCK_TIMEOUT=0 _build_state_jq_update "$source" '.counter = 1' &&
    jq -e '.counter == 1' "$source" >/dev/null
}

test_checkpoint_python_lock_backend() {
  command -v python3 >/dev/null || return 1
  # Hide only flock discovery; use the actual standard-library fallback and
  # actual inherited descriptors, not a mock lock implementation.
  command() {
    if [[ "$#" -eq 2 && "$1" == -v && "$2" == flock ]]; then return 1; fi
    builtin command "$@"
  }
  test_checkpoint_timeout_and_independent_files python
}

test_checkpoint_lock_config() {
  local source="$TEMP_DIR/invalid-lock-timeout.json" value
  printf '{"counter":0}\n' > "$source"
  for value in -1 1.5 nope 3601 99999; do
    ! DSR_STATE_LOCK_TIMEOUT="$value" _build_state_jq_update "$source" '.counter = 1' \
      2>/dev/null || return 1
  done
  DSR_STATE_LOCK_TIMEOUT=0000 _build_state_jq_update "$source" '.counter = 2' &&
    jq -e '.counter == 2' "$source" >/dev/null
}

# Resume/retry tests use actual checkpoints. Every fixture has a separate tool
# namespace so the suite can exercise latest-pointer changes without cross-talk.
seed_resume_fixture() {
  local tool="$1" targets="${2:-linux/amd64,darwin/arm64}"
  build_state_init || return 1
  DSR_RUN_ID="${tool}-run" build_state_create "$tool" v1.0.0 "$targets" >/dev/null || return 1
  RESUME_STATE_FILE="$_BUILD_STATE_DIR/$tool/v1.0.0/${tool}-run/state.json"
}

test_state_read_identity_and_shape() {
  seed_resume_fixture read-identity || return 1
  local before filter invalid output status
  before=$(cat "$RESUME_STATE_FILE")
  for filter in '.tool = "other"' '.version = "v9.0.0"' '.run_id = "other"' \
    '., .' '[]' 'null'; do
    jq "$filter" <<< "$before" > "$RESUME_STATE_FILE" || return 1
    status=0
    output=$(build_state_get read-identity v1.0.0 2>/dev/null) || status=$?
    [[ $status -ne 0 && -z "$output" ]] || return 1
  done
  for invalid in '' '{broken'; do
    printf '%s' "$invalid" > "$RESUME_STATE_FILE"
    ! build_state_get read-identity v1.0.0 >/dev/null 2>&1 || return 1
  done
  printf '%s\n' "$before" > "$RESUME_STATE_FILE"
  [[ "$(build_state_get read-identity v1.0.0)" == "$before" ]] || return 1
  ! build_state_get ../read-identity v1.0.0 >/dev/null 2>&1 || return 1
  ! build_state_get read-identity v1.0.0 ../outside >/dev/null 2>&1 || return 1
  mv "$RESUME_STATE_FILE" "$RESUME_STATE_FILE.saved" || return 1
  ln -s "$RESUME_STATE_FILE.saved" "$RESUME_STATE_FILE" || return 1
  ! build_state_get read-identity v1.0.0 >/dev/null 2>&1
}

test_resume_unknown_status_rejected() {
  seed_resume_fixture unknown-status || return 1
  local status plan code
  for status in completed cancelled unknown null; do
    _build_state_jq_update "$RESUME_STATE_FILE" --arg status "$status" '.status = $status' || return 1
    ! build_state_can_resume unknown-status v1.0.0 || return 1
    code=0
    plan=$(build_state_resume unknown-status v1.0.0 2>/dev/null) || code=$?
    [[ $code -ne 0 ]] && jq -es 'length == 1 and .[0].can_resume == false' \
      <<< "$plan" >/dev/null || return 1
  done
  for status in created running failed; do
    _build_state_jq_update "$RESUME_STATE_FILE" --arg status "$status" '.status = $status' || return 1
    build_state_can_resume unknown-status v1.0.0 || return 1
  done
  _build_state_jq_update "$RESUME_STATE_FILE" 'del(.status)' || return 1
  ! build_state_can_resume unknown-status v1.0.0
}

test_state_evidence_rejection() {
  seed_resume_fixture bad-evidence || return 1
  local evidence before
  before=$(cat "$RESUME_STATE_FILE")
  for evidence in '[]' 'null' 'true' '42' '{} {}' '{broken'; do
    ! build_state_update_host bad-evidence v1.0.0 trj completed "$evidence" \
      2>/dev/null || return 1
    ! build_state_update_target bad-evidence v1.0.0 linux/amd64 completed "$evidence" \
      2>/dev/null || return 1
    [[ "$(cat "$RESUME_STATE_FILE")" == "$before" ]] || return 1
  done
}

test_resume_single_snapshot_after_latest_moves() {
  seed_resume_fixture moving-latest linux/amd64 || return 1
  local first_state="$RESUME_STATE_FILE" second_state old_get calls="$TEMP_DIR/resume-read.calls"
  _build_state_jq_update "$first_state" '
    .hosts = {trj:{status:"failed",retry_count:1}} |
    .context = {target_hosts:{"linux/amd64":"trj"}, marker:"first"} |
    .target_statuses["linux/amd64"] = {status:"failed",attempts:1}' || return 1
  DSR_RUN_ID=second-run build_state_create moving-latest v1.0.0 darwin/arm64 >/dev/null || return 1
  second_state="$_BUILD_STATE_DIR/moving-latest/v1.0.0/second-run/state.json"
  _build_state_jq_update "$second_state" '
    .hosts = {mmini:{status:"completed"}} | .context = {marker:"second"}' || return 1
  ln -sfn moving-latest-run "$_BUILD_STATE_DIR/moving-latest/v1.0.0/latest"
  old_get=$(declare -f build_state_get)
  # Preserve the real reader and move latest only after it returns its snapshot.
  eval "${old_get/build_state_get ()/saved_build_state_get ()}"
  build_state_get() {
    local value
    value=$(saved_build_state_get "$@") || return 1
    printf 'read\n' >> "$calls"
    ln -sfn second-run "$_BUILD_STATE_DIR/moving-latest/v1.0.0/latest"
    printf '%s\n' "$value"
  }
  local plan
  plan=$(build_state_resume moving-latest v1.0.0) || return 1
  [[ "$(wc -l < "$calls")" -eq 1 ]] || return 1
  jq -e '.run_id == "moving-latest-run" and .context.marker == "first" and
    .failed_hosts == ["trj"] and .hosts_to_process == ["trj"] and
    .completed_hosts == [] and .targets_to_process == ["linux/amd64"]' <<< "$plan" >/dev/null
}

test_resume_host_routing_and_target_evidence() {
  seed_resume_fixture route-plan linux/amd64,darwin/arm64,windows/amd64 || return 1
  _build_state_jq_update "$RESUME_STATE_FILE" '
    .context.target_hosts = {"linux/amd64":"trj","darwin/arm64":"mmini","windows/amd64":"wlap"} |
    .hosts = {trj:{status:"completed"},mmini:{status:"running",retry_count:1}} |
    .target_statuses = {
      "linux/amd64":{status:"completed",attempts:1,result:{artifact:"candidate"}},
      "darwin/arm64":{status:"completed",attempts:1,result:{}},
      "windows/amd64":{status:"running",attempts:3}}' || return 1
  local plan pending completed
  plan=$(build_state_resume route-plan v1.0.0) || return 1
  pending=$(build_state_pending_hosts route-plan v1.0.0) || return 1
  completed=$(build_state_completed_targets route-plan v1.0.0) || return 1
  [[ "$pending" == $'mmini\nwlap' && "$completed" == linux/amd64 ]] || return 1
  jq -e '.completed_hosts == ["trj"] and .hosts_to_process == ["mmini","wlap"] and
    .completed_targets == ["linux/amd64"] and .targets_to_process == ["darwin/arm64"] and
    .exceeded_target_retry_limit == ["windows/amd64"]' <<< "$plan" >/dev/null || return 1
  seed_resume_fixture legacy-hosts trj,mmini,wlap || return 1
  build_state_update_host legacy-hosts v1.0.0 trj completed || return 1
  [[ "$(build_state_pending_hosts legacy-hosts v1.0.0)" == $'mmini\nwlap' ]]
}

test_resume_rejects_malformed_inventory() {
  seed_resume_fixture bad-plan || return 1
  local original filter status plan
  original=$(cat "$RESUME_STATE_FILE")
  for filter in '.targets = ["linux/amd64","linux/amd64"]' '.targets = null' \
    '.targets = [1]' '.hosts = []' '.hosts.trj = false' \
    '.hosts.trj = {status:"failed",retry_count:-1}' \
    '.hosts.trj = {status:"failed",retry_count:"0"}' \
    '.hosts.trj = {status:"running",retry_count:null}' \
    '.hosts.trj = {status:"mystery"}' '.target_statuses["linux/amd64"].attempts = 1.5' \
    '.target_statuses["linux/amd64"].attempts = false' '.target_statuses.other = {}' \
    '.context = []' '.context.target_hosts = {"linux/amd64":null}'; do
    jq "$filter" <<< "$original" > "$RESUME_STATE_FILE" || return 1
    status=0
    plan=$(build_state_resume bad-plan v1.0.0 2>/dev/null) || status=$?
    [[ $status -ne 0 ]] && jq -es 'length == 1 and .[0].can_resume == false' \
      <<< "$plan" >/dev/null || return 1
  done
}

test_retry_budget_validation() {
  local marker="$TEMP_DIR/invalid-retry-command" value status
  retry_command() { : > "$marker"; }
  for value in 0 -1 1.5 nope 1001; do
    status=0
    build_retry_with_backoff "$value" retry_command 2>/dev/null || status=$?
    [[ $status -eq 4 && ! -e "$marker" ]] || return 1
  done
  ! build_retry_with_backoff 2 '' 2>/dev/null || return 1
  status=0
  BUILD_RETRY_BASE_DELAY=0 build_retry_with_backoff 02 bash -c 'exit 17' \
    2>/dev/null || status=$?
  [[ $status -eq 17 ]]
}

test_retry_backoff_is_bounded() {
  local BUILD_RETRY_MAX=3 BUILD_RETRY_BASE_DELAY=5 BUILD_RETRY_MAX_DELAY=7
  local attempt _iteration delay
  for attempt in 0 1 2 63 64 1000; do
    for _iteration in 1 2 3 4 5 6 7 8; do
      delay=$(_build_calc_backoff "$attempt") || return 1
      [[ "$delay" =~ ^[0-9]+$ ]] && ((delay <= 7)) || return 1
    done
  done
  BUILD_RETRY_BASE_DELAY=0
  [[ "$(_build_calc_backoff 1000)" == 0 ]] || return 1
  BUILD_RETRY_BASE_DELAY=00005 BUILD_RETRY_MAX_DELAY=00000
  [[ "$(_build_calc_backoff 0001)" == 0 ]] || return 1
  BUILD_RETRY_BASE_DELAY=-1
  ! _build_calc_backoff 1 2>/dev/null
}

test_retry_unreadable_budget_blocks_execution() {
  seed_resume_fixture bad-budget || return 1
  local original value status marker="$TEMP_DIR/bad-budget-command"
  original=$(cat "$RESUME_STATE_FILE")
  retry_command() { : > "$marker"; }
  ! build_state_can_retry missing-tool v1.0.0 trj 2>/dev/null || return 1
  for value in null false '"0"' -1 1.5; do
    jq --argjson value "$value" '.hosts.trj = {status:"failed",retry_count:$value}' \
      <<< "$original" > "$RESUME_STATE_FILE" || return 1
    ! build_state_can_retry bad-budget v1.0.0 trj 2>/dev/null || return 1
    status=0
    build_state_exec_with_retry bad-budget v1.0.0 trj retry_command 2>/dev/null || status=$?
    [[ $status -ne 0 && ! -e "$marker" ]] || return 1
  done
  for value in null false '[]' '"invalid"'; do
    jq --argjson value "$value" '.hosts.trj = $value' \
      <<< "$original" > "$RESUME_STATE_FILE" || return 1
    ! build_state_can_retry bad-budget v1.0.0 trj 2>/dev/null || return 1
    status=0
    build_state_exec_with_retry bad-budget v1.0.0 trj retry_command 2>/dev/null || status=$?
    [[ $status -ne 0 && ! -e "$marker" ]] || return 1
  done
}

test_retry_preserves_exit_code_and_saved_budget() {
  seed_resume_fixture saved-budget trj || return 1
  _build_state_jq_update "$RESUME_STATE_FILE" '.hosts.trj = {status:"failed",retry_count:2}' || return 1
  local BUILD_RETRY_MAX=3 BUILD_RETRY_BASE_DELAY=0
  local marker="$TEMP_DIR/saved-budget-command" status=0
  retry_command() { printf 'attempt\n' >> "$marker"; return 17; }
  build_state_exec_with_retry saved-budget v1.0.0 trj retry_command 2>/dev/null || status=$?
  [[ $status -ne 0 && "$(wc -l < "$marker")" -eq 1 ]] || return 1
  jq -e '.hosts.trj.status == "failed" and .hosts.trj.retry_count == 3 and
    .hosts.trj.exit_code == 17 and .hosts.trj.retries[0].attempt == 3 and
    .hosts.trj.retries[0].error == "exit code 17"' "$RESUME_STATE_FILE" >/dev/null || return 1
  ! build_state_exec_with_retry saved-budget v1.0.0 trj retry_command 2>/dev/null || return 1
  [[ "$(wc -l < "$marker")" -eq 1 ]]
}

test_retry_success_and_failure_share_receipt() {
  seed_resume_fixture retry-success trj || return 1
  local BUILD_RETRY_MAX=3 BUILD_RETRY_BASE_DELAY=0 marker="$TEMP_DIR/retry-success-command"
  retry_command() {
    if [[ ! -e "$marker" ]]; then : > "$marker"; return 23; fi
    return 0
  }
  build_state_exec_with_retry retry-success v1.0.0 trj retry_command || return 1
  jq -e '.hosts.trj.status == "completed" and .hosts.trj.exit_code == 0 and
    .hosts.trj.retry_count == 0 and .hosts.trj.attempts_started == 2 and
    .hosts.trj.active_attempt == null and .hosts.trj.retries[0].exit_code == 23' \
    "$RESUME_STATE_FILE" >/dev/null
}

test_retry_reservation_failure_prevents_command() {
  seed_resume_fixture reservation-failure trj || return 1
  local marker="$TEMP_DIR/reservation-command" status=0
  retry_command() { : > "$marker"; }
  _build_state_jq_update() { return 1; }
  build_state_exec_with_retry reservation-failure v1.0.0 trj retry_command || status=$?
  [[ $status -ne 0 && ! -e "$marker" ]]
}

test_retry_receipt_failure_stops_execution() {
  local code tool marker status
  local BUILD_RETRY_BASE_DELAY=0
  for code in 0 17; do
    tool="receipt-failure-$code"
    seed_resume_fixture "$tool" trj || return 1
    marker="$TEMP_DIR/$tool-command"
    retry_command() { printf 'attempt\n' >> "$marker"; return "$code"; }
    mv() {
      [[ ! -e "$marker" ]] || return 1
      command mv "$@"
    }
    status=0
    build_state_exec_with_retry "$tool" v1.0.0 trj retry_command 2>/dev/null || status=$?
    unset -f mv
    [[ $status -ne 0 && "$(wc -l < "$marker")" -eq 1 ]] || return 1
    jq -e '.hosts.trj.status == "running" and .hosts.trj.retry_count == 1' \
      "$RESUME_STATE_FILE" >/dev/null || return 1
  done
}

test_retry_pins_run_when_latest_moves() {
  seed_resume_fixture retry-latest trj || return 1
  local first="$RESUME_STATE_FILE" second before
  DSR_RUN_ID=second-run build_state_create retry-latest v1.0.0 mmini >/dev/null || return 1
  second="$_BUILD_STATE_DIR/retry-latest/v1.0.0/second-run/state.json"
  before=$(cat "$second")
  ln -sfn retry-latest-run "$_BUILD_STATE_DIR/retry-latest/v1.0.0/latest"
  retry_command() {
    ln -sfn second-run "$_BUILD_STATE_DIR/retry-latest/v1.0.0/latest"
  }
  build_state_exec_with_retry retry-latest v1.0.0 trj retry_command || return 1
  [[ "$(cat "$second")" == "$before" ]] &&
    jq -e '.hosts.trj.status == "completed" and .hosts.trj.exit_code == 0' "$first" >/dev/null
}

test_retry_interruption_is_not_retried() {
  local code tool marker status
  local BUILD_RETRY_BASE_DELAY=0
  for code in 5 130 143; do
    tool="retry-interrupted-$code"
    seed_resume_fixture "$tool" trj || return 1
    marker="$TEMP_DIR/$tool-command"
    retry_command() { printf 'attempt\n' >> "$marker"; return "$code"; }
    status=0
    build_state_exec_with_retry "$tool" v1.0.0 trj retry_command 2>/dev/null || status=$?
    [[ $status -eq 5 && "$(wc -l < "$marker")" -eq 1 ]] || return 1
    jq -e --argjson code "$code" '.hosts.trj.status == "cancelled" and
      .hosts.trj.exit_code == $code and .hosts.trj.retry_count == 1' "$RESUME_STATE_FILE" \
      >/dev/null || return 1
  done
}

test_retry_host_execution_lock() {
  seed_resume_fixture host-execution trj,mmini || return 1
  local ready="$TEMP_DIR/host-execution-ready" stop="$TEMP_DIR/host-execution-stop"
  local forbidden="$TEMP_DIR/host-execution-duplicate" pid _step status=0 result=0
  slow_command() {
    : > "$ready"
    for _step in {1..1000}; do [[ -e "$stop" ]] && return 0; sleep 0.01; done
    return 19
  }
  duplicate_command() { : > "$forbidden"; }
  build_state_exec_with_retry host-execution v1.0.0 trj slow_command &
  pid=$!
  for _step in {1..500}; do [[ -e "$ready" ]] && break; sleep 0.01; done
  [[ -e "$ready" ]] || result=1
  build_state_exec_with_retry host-execution v1.0.0 trj duplicate_command \
    2>/dev/null || status=$?
  [[ $status -eq 2 && ! -e "$forbidden" ]] || result=1
  build_state_exec_with_retry host-execution v1.0.0 mmini true || result=1
  : > "$stop"
  wait "$pid" || result=1
  [[ $result -eq 0 ]] && jq -e '.hosts.trj.status == "completed" and
    .hosts.mmini.status == "completed"' "$RESUME_STATE_FILE" >/dev/null
}

test_retry_crash_consumes_reserved_attempt() {
  seed_resume_fixture retry-crash trj || return 1
  local status=0 marker="$TEMP_DIR/retry-crash-command" BUILD_RETRY_MAX=1
  crash_command() { kill -KILL "$BASHPID"; }
  retry_command() { : > "$marker"; }
  build_state_exec_with_retry retry-crash v1.0.0 trj crash_command \
    2>/dev/null || status=$?
  [[ $status -ne 0 ]] && jq -e '.hosts.trj.status == "running" and
    .hosts.trj.retry_count == 1' "$RESUME_STATE_FILE" >/dev/null || return 1
  ! build_state_exec_with_retry retry-crash v1.0.0 trj retry_command \
    2>/dev/null || return 1
  [[ ! -e "$marker" ]] || return 1
  BUILD_RETRY_MAX=2
  build_state_exec_with_retry retry-crash v1.0.0 trj retry_command || return 1
  [[ -e "$marker" ]] && jq -e '.hosts.trj.status == "completed" and
    .hosts.trj.attempts_started == 2' "$RESUME_STATE_FILE" >/dev/null
}

test_retry_record_failure_propagates() {
  seed_resume_fixture retry-record trj || return 1
  _build_state_jq_update() { return 1; }
  ! build_state_record_retry retry-record v1.0.0 trj 1 'failure'
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
test_build_state_rejects_run_collision
test_build_state_get
test_build_state_update_status
test_build_state_update_preserves_private_mode
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

# Checkpoint transaction regressions
run_state_regression "checkpoint rejects invalid input/output and identity drift" test_checkpoint_validation
run_state_regression "checkpoint preserves another writer's PID-named temporary file" test_checkpoint_foreign_temp_preserved
run_state_regression "descriptor identity matches its file and survives pathname replacement" test_checkpoint_descriptor_identity
run_state_regression "checkpoint rejects a replaced lock after opening its descriptor" test_checkpoint_replaced_lock_rejected
run_state_regression "48 overlapping checkpoint writes lose no updates" test_checkpoint_concurrent_increments
run_state_regression "checkpoint rejects source/lock symlinks without changing their targets" test_checkpoint_symlinks_rejected
run_state_regression "failed checkpoint publication preserves old state and permits retry" test_checkpoint_publication_failure
run_state_regression "checkpoint detects non-cooperating writes" test_checkpoint_external_write_detected
run_state_regression "checkpoint preserves caller traps/umask and mode 0600" test_checkpoint_caller_scope_preserved
run_state_regression "checkpoint lock wait is bounded and unrelated runs remain writable" test_checkpoint_timeout_and_independent_files
run_state_regression "killed checkpoint writer does not strand the lock" test_checkpoint_crash_recovery
run_state_regression "Python lock fallback retains the lock in the owning shell" test_checkpoint_python_lock_backend
run_state_regression "checkpoint validates bounded timeout configuration" test_checkpoint_lock_config

# Single-generation resume and durable retry execution regressions
run_state_regression "state reads reject malformed checkpoints and wrong run identities" test_state_read_identity_and_shape
run_state_regression "resume rejects unknown or terminal run statuses" test_resume_unknown_status_rejected
run_state_regression "state writes reject invalid supplied host/target evidence" test_state_evidence_rejection
run_state_regression "resume uses one checkpoint even when latest moves mid-read" test_resume_single_snapshot_after_latest_moves
run_state_regression "resume maps real hosts and rejects empty target completion evidence" test_resume_host_routing_and_target_evidence
run_state_regression "resume rejects malformed target/host inventories and counters" test_resume_rejects_malformed_inventory
run_state_regression "generic retry rejects zero or invalid budgets before execution" test_retry_budget_validation
run_state_regression "exponential retry backoff never exceeds its cap or overflows" test_retry_backoff_is_bounded
run_state_regression "missing or invalid saved retry budgets cannot launch commands" test_retry_unreadable_budget_blocks_execution
run_state_regression "retry execution preserves real exit codes and saved attempt budget" test_retry_preserves_exit_code_and_saved_budget
run_state_regression "retry success/failure receipts are complete and atomic" test_retry_success_and_failure_share_receipt
run_state_regression "failed attempt reservation prevents command execution" test_retry_reservation_failure_prevents_command
run_state_regression "failed completion receipt prevents success or another retry" test_retry_receipt_failure_stops_execution
run_state_regression "retry receipts stay bound to their original run after latest moves" test_retry_pins_run_when_latest_moves
run_state_regression "interrupted commands record cancellation and are not retried" test_retry_interruption_is_not_retried
run_state_regression "same-host execution is exclusive while other hosts overlap" test_retry_host_execution_lock
run_state_regression "killed retry execution consumes budget and releases its host lock" test_retry_crash_consumes_reserved_attempt
run_state_regression "retry history persistence errors propagate to the caller" test_retry_record_failure_propagates

echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN"
echo "Passed:    $TESTS_PASSED"
echo "Failed:    $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
