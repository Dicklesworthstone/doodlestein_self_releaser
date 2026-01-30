#!/usr/bin/env bash
# test_harness_standalone.sh - Standalone tests for the test harness
#
# Run: ./scripts/tests/test_harness_standalone.sh
#
# These tests run without bats installed.

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

# Source the harness (but not the setup/teardown)
source "$PROJECT_ROOT/tests/helpers/mock_time.bash"
source "$PROJECT_ROOT/tests/helpers/mock_random.bash"
source "$PROJECT_ROOT/tests/helpers/log_capture.bash"
source "$PROJECT_ROOT/tests/helpers/mock_common.bash"

# Create temp directory for tests
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# ============================================================================
# Mock Time Tests
# ============================================================================

test_mock_time_freeze() {
  ((TESTS_RUN++))
  mock_time_freeze "2026-06-15T10:30:00Z"
  local result
  result=$(mock_time_get)
  mock_time_restore

  if [[ "$result" == "2026-06-15T10:30:00Z" ]]; then
    pass "mock_time_freeze sets frozen time"
  else
    fail "mock_time_freeze: expected 2026-06-15T10:30:00Z, got $result"
  fi
}

test_mock_time_is_frozen() {
  ((TESTS_RUN++))
  mock_time_freeze "2026-01-01T00:00:00Z"
  local frozen
  mock_time_is_frozen && frozen=true || frozen=false
  mock_time_restore

  if [[ "$frozen" == "true" ]]; then
    pass "mock_time_is_frozen returns true when frozen"
  else
    fail "mock_time_is_frozen should return true"
  fi
}

test_mock_time_advance() {
  ((TESTS_RUN++))
  mock_time_freeze "2026-01-30T12:00:00Z"
  mock_time_advance 3600  # 1 hour
  local result
  result=$(mock_time_get)
  mock_time_restore

  if [[ "$result" == "2026-01-30T13:00:00Z" ]]; then
    pass "mock_time_advance moves time forward"
  else
    fail "mock_time_advance: expected 2026-01-30T13:00:00Z, got $result"
  fi
}

# ============================================================================
# Mock Random Tests
# ============================================================================

test_mock_random_deterministic() {
  ((TESTS_RUN++))
  mock_random_seed 42
  local v1 v2 v3
  v1=$(mock_random 1000)
  v2=$(mock_random 1000)
  v3=$(mock_random 1000)

  mock_random_seed 42
  local v1b v2b v3b
  v1b=$(mock_random 1000)
  v2b=$(mock_random 1000)
  v3b=$(mock_random 1000)
  mock_random_reset

  if [[ "$v1" == "$v1b" && "$v2" == "$v2b" && "$v3" == "$v3b" ]]; then
    pass "mock_random produces deterministic sequence"
  else
    fail "mock_random not deterministic: $v1/$v1b, $v2/$v2b, $v3/$v3b"
  fi
}

test_mock_uuid_format() {
  ((TESTS_RUN++))
  mock_random_seed 1
  local uuid
  uuid=$(mock_uuid)
  mock_random_reset

  # Check UUID format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  if [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
    pass "mock_uuid produces valid format"
  else
    fail "mock_uuid invalid format: $uuid"
  fi
}

test_mock_uuid_deterministic() {
  ((TESTS_RUN++))
  mock_random_seed 123
  local uuid1
  uuid1=$(mock_uuid)

  mock_random_seed 123
  local uuid2
  uuid2=$(mock_uuid)
  mock_random_reset

  if [[ "$uuid1" == "$uuid2" ]]; then
    pass "mock_uuid is deterministic with same seed"
  else
    fail "mock_uuid not deterministic: $uuid1 != $uuid2"
  fi
}

test_mock_random_hex_length() {
  ((TESTS_RUN++))
  mock_random_seed 1
  local hex
  hex=$(mock_random_hex 8)
  mock_random_reset

  if [[ "${#hex}" -eq 16 ]]; then
    pass "mock_random_hex produces correct length"
  else
    fail "mock_random_hex: expected 16 chars, got ${#hex}"
  fi
}

# ============================================================================
# Log Capture Tests
# ============================================================================

test_log_capture_init() {
  ((TESTS_RUN++))
  local log_file="$TEMP_DIR/capture1.log"
  log_capture_init "$log_file"

  if [[ -f "$log_file" ]]; then
    pass "log_capture_init creates log file"
  else
    fail "log_capture_init should create file"
  fi
  log_capture_cleanup
}

test_log_capture_write() {
  ((TESTS_RUN++))
  local log_file="$TEMP_DIR/capture2.log"
  log_capture_init "$log_file"
  log_capture_write "first line"
  log_capture_write "second line"
  local count
  count=$(log_capture_line_count)
  log_capture_cleanup

  if [[ "$count" -eq 2 ]]; then
    pass "log_capture_write appends to log"
  else
    fail "log_capture_write: expected 2 lines, got $count"
  fi
}

test_log_capture_contains() {
  ((TESTS_RUN++))
  local log_file="$TEMP_DIR/capture3.log"
  log_capture_init "$log_file"
  log_capture_write "error: something failed"
  log_capture_write "info: all good"

  local has_error has_warning
  log_capture_contains "error" && has_error=true || has_error=false
  log_capture_contains "warning" && has_warning=true || has_warning=false
  log_capture_cleanup

  if [[ "$has_error" == "true" && "$has_warning" == "false" ]]; then
    pass "log_capture_contains finds patterns correctly"
  else
    fail "log_capture_contains: error=$has_error, warning=$has_warning"
  fi
}

test_log_capture_count() {
  ((TESTS_RUN++))
  local log_file="$TEMP_DIR/capture4.log"
  log_capture_init "$log_file"
  log_capture_write "error: first"
  log_capture_write "info: middle"
  log_capture_write "error: second"
  local count
  count=$(log_capture_count "error")
  log_capture_cleanup

  if [[ "$count" -eq 2 ]]; then
    pass "log_capture_count returns match count"
  else
    fail "log_capture_count: expected 2, got $count"
  fi
}

# ============================================================================
# Mock Common Tests
# ============================================================================

test_mock_command() {
  ((TESTS_RUN++))
  mock_command "fake_cmd_test" "hello world" 0
  local result
  result=$(fake_cmd_test)
  mock_cleanup

  if [[ "$result" == "hello world" ]]; then
    pass "mock_command creates working mock"
  else
    fail "mock_command: expected 'hello world', got '$result'"
  fi
}

test_mock_command_exit_code() {
  ((TESTS_RUN++))
  mock_command "failing_cmd_test" "error" 1
  local exit_code=0
  failing_cmd_test >/dev/null 2>&1 || exit_code=$?
  mock_cleanup

  if [[ "$exit_code" -eq 1 ]]; then
    pass "mock_command respects exit code"
  else
    fail "mock_command exit code: expected 1, got $exit_code"
  fi
}

test_mock_command_logged() {
  ((TESTS_RUN++))
  mock_command_logged "tracked_cmd_test" "output" 0
  tracked_cmd_test arg1 arg2 >/dev/null
  tracked_cmd_test arg3 >/dev/null
  local count
  count=$(mock_call_count "tracked_cmd_test")
  mock_cleanup

  if [[ "$count" -eq 2 ]]; then
    pass "mock_command_logged records calls"
  else
    fail "mock_command_logged: expected 2 calls, got $count"
  fi
}

test_mock_called_with() {
  ((TESTS_RUN++))
  mock_command_logged "verify_cmd_test" "" 0
  verify_cmd_test --flag value >/dev/null
  local found_correct found_wrong
  mock_called_with "verify_cmd_test" "--flag value" && found_correct=true || found_correct=false
  mock_called_with "verify_cmd_test" "wrong args" && found_wrong=true || found_wrong=false
  mock_cleanup

  if [[ "$found_correct" == "true" && "$found_wrong" == "false" ]]; then
    pass "mock_called_with verifies arguments"
  else
    fail "mock_called_with: correct=$found_correct, wrong=$found_wrong"
  fi
}

# ============================================================================
# Full Harness Integration Test
# ============================================================================

test_harness_integration() {
  ((TESTS_RUN++))

  # Source full harness
  source "$PROJECT_ROOT/tests/helpers/test_harness.bash"

  # Run setup
  harness_setup

  # Check directories exist
  local dirs_ok=true
  [[ -d "$DSR_CONFIG_DIR" ]] || dirs_ok=false
  [[ -d "$DSR_STATE_DIR" ]] || dirs_ok=false
  [[ -d "$DSR_CACHE_DIR" ]] || dirs_ok=false

  # Check run ID is set
  local run_id_ok=false
  [[ -n "$DSR_RUN_ID" && "$DSR_RUN_ID" =~ ^run-[0-9]+-[0-9]+$ ]] && run_id_ok=true

  # Cleanup
  harness_teardown

  if [[ "$dirs_ok" == "true" && "$run_id_ok" == "true" ]]; then
    pass "harness_setup/teardown integration"
  else
    fail "harness integration: dirs_ok=$dirs_ok, run_id_ok=$run_id_ok"
  fi
}

# ============================================================================
# Run All Tests
# ============================================================================

echo "Running test harness standalone tests..."
echo ""

# Mock Time
test_mock_time_freeze
test_mock_time_is_frozen
test_mock_time_advance

# Mock Random
test_mock_random_deterministic
test_mock_uuid_format
test_mock_uuid_deterministic
test_mock_random_hex_length

# Log Capture
test_log_capture_init
test_log_capture_write
test_log_capture_contains
test_log_capture_count

# Mock Common
test_mock_command
test_mock_command_exit_code
test_mock_command_logged
test_mock_called_with

# Full Integration
test_harness_integration

echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN"
echo "Passed:    $TESTS_PASSED"
echo "Failed:    $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
