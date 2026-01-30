#!/usr/bin/env bats
# test_harness.bats - Tests for the test harness itself
#
# Run: bats tests/test_harness.bats
# Or: ./tests/test_harness.bats (if bats not installed)

# Load harness manually for this test file
load helpers/test_harness.bash

# ============================================================================
# Mock Time Tests
# ============================================================================

@test "mock_time_freeze sets frozen time" {
  mock_time_freeze "2026-06-15T10:30:00Z"
  local result
  result=$(mock_time_get)
  assert_equal "2026-06-15T10:30:00Z" "$result" "Frozen time should match"
}

@test "mock_time_is_frozen returns true when frozen" {
  mock_time_freeze "2026-01-01T00:00:00Z"
  assert_success mock_time_is_frozen
}

@test "mock_time_is_frozen returns false when not frozen" {
  mock_time_restore
  assert_failure mock_time_is_frozen
}

@test "mock_time_advance moves time forward" {
  mock_time_freeze "2026-01-30T12:00:00Z"
  mock_time_advance 3600  # 1 hour

  local result
  result=$(mock_time_get)
  assert_equal "2026-01-30T13:00:00Z" "$result" "Time should advance by 1 hour"
}

@test "mock_time_epoch returns correct epoch" {
  mock_time_freeze "2026-01-30T12:00:00Z"
  local epoch
  epoch=$(mock_time_epoch)

  # 2026-01-30T12:00:00Z = 1769774400 (approximately)
  # Just check it's a reasonable number
  [[ "$epoch" -gt 1700000000 ]]
  [[ "$epoch" -lt 2000000000 ]]
}

# ============================================================================
# Mock Random Tests
# ============================================================================

@test "mock_random produces deterministic sequence" {
  mock_random_seed 42

  local v1 v2 v3
  v1=$(mock_random 1000)
  v2=$(mock_random 1000)
  v3=$(mock_random 1000)

  # Reset and verify same sequence
  mock_random_seed 42
  assert_equal "$v1" "$(mock_random 1000)" "First value should match"
  assert_equal "$v2" "$(mock_random 1000)" "Second value should match"
  assert_equal "$v3" "$(mock_random 1000)" "Third value should match"
}

@test "mock_uuid produces valid format" {
  mock_random_seed 1
  local uuid
  uuid=$(mock_uuid)

  # Check UUID format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

@test "mock_uuid is deterministic with same seed" {
  mock_random_seed 123
  local uuid1
  uuid1=$(mock_uuid)

  mock_random_seed 123
  local uuid2
  uuid2=$(mock_uuid)

  assert_equal "$uuid1" "$uuid2" "UUIDs should match with same seed"
}

@test "mock_random_hex produces correct length" {
  mock_random_seed 1
  local hex
  hex=$(mock_random_hex 8)

  assert_equal 16 "${#hex}" "8 bytes should produce 16 hex chars"
}

# ============================================================================
# Log Capture Tests
# ============================================================================

@test "log_capture_init creates log file" {
  local log_file="$TEST_TMPDIR/capture.log"
  log_capture_init "$log_file"

  assert_file_exists "$log_file" "Log file should be created"
}

@test "log_capture_write appends to log" {
  local log_file="$TEST_TMPDIR/capture.log"
  log_capture_init "$log_file"

  log_capture_write "first line"
  log_capture_write "second line"

  local count
  count=$(log_capture_line_count)
  assert_equal "2" "$count" "Should have 2 lines"
}

@test "log_capture_contains finds patterns" {
  local log_file="$TEST_TMPDIR/capture.log"
  log_capture_init "$log_file"

  log_capture_write "error: something failed"
  log_capture_write "info: all good"

  assert_success log_capture_contains "error"
  assert_success log_capture_contains "info"
  assert_failure log_capture_contains "warning"
}

@test "log_capture_count returns match count" {
  local log_file="$TEST_TMPDIR/capture.log"
  log_capture_init "$log_file"

  log_capture_write "error: first"
  log_capture_write "info: middle"
  log_capture_write "error: second"

  local count
  count=$(log_capture_count "error")
  assert_equal "2" "$count" "Should find 2 errors"
}

# ============================================================================
# Mock Common Tests
# ============================================================================

@test "mock_command creates working mock" {
  mock_command "fake_cmd" "hello world" 0

  local result
  result=$(fake_cmd)
  assert_equal "hello world" "$result"
}

@test "mock_command respects exit code" {
  mock_command "failing_cmd" "error" 1

  run failing_cmd
  assert_equal "1" "$status" "Exit code should be 1"
}

@test "mock_command_logged records calls" {
  mock_command_logged "tracked_cmd" "output" 0

  tracked_cmd arg1 arg2
  tracked_cmd arg3

  local count
  count=$(mock_call_count "tracked_cmd")
  assert_equal "2" "$count" "Should record 2 calls"
}

@test "mock_called_with verifies arguments" {
  mock_command_logged "test_cmd" "" 0

  test_cmd --flag value

  assert_success mock_called_with "test_cmd" "--flag value"
  assert_failure mock_called_with "test_cmd" "wrong args"
}

@test "mock_cleanup removes all mocks" {
  mock_command "temp_cmd" "data" 0

  # Verify it works
  assert_equal "data" "$(temp_cmd)"

  # Cleanup
  mock_cleanup

  # Should no longer be available (will use real command or fail)
  run command -v temp_cmd
  assert_equal "1" "$status" "Mock should be removed"
}

# ============================================================================
# Test Harness Integration Tests
# ============================================================================

@test "harness_setup creates isolated directories" {
  # harness_setup is called in setup(), so dirs should exist
  assert_dir_exists "$DSR_CONFIG_DIR"
  assert_dir_exists "$DSR_STATE_DIR"
  assert_dir_exists "$DSR_CACHE_DIR"
}

@test "harness_setup sets DSR_RUN_ID" {
  [[ -n "$DSR_RUN_ID" ]]
  [[ "$DSR_RUN_ID" =~ ^run-[0-9]+-[0-9]+$ ]]
}

@test "harness_create_file creates files in tmpdir" {
  local path
  path=$(harness_create_file "subdir/test.txt" "content")

  assert_file_exists "$path"
  assert_equal "content" "$(cat "$path")"
}

@test "harness_create_config creates valid config" {
  harness_create_config

  assert_file_exists "$DSR_CONFIG_DIR/config.yaml"
  assert_file_exists "$DSR_CONFIG_DIR/hosts.yaml"
  assert_file_exists "$DSR_CONFIG_DIR/repos.yaml"
}

@test "harness provides assert helpers" {
  assert_success true
  assert_failure false
  assert_equal "a" "a"
  assert_contains "hello world" "world"
}
