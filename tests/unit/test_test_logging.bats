#!/usr/bin/env bats
# test_test_logging.bats - Tests for the test logging infrastructure
#
# bd-1nf: Tests for structured logging for tests
#
# Coverage:
# - Log initialization
# - Log levels (DEBUG, INFO, PASS, FAIL, SKIP)
# - Timestamps in ISO8601 format
# - Summary generation
# - Assertion helpers
#
# Run: bats tests/unit/test_test_logging.bats

# Load test harness
load ../helpers/test_harness.bash

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    harness_setup

    # Source the test logging module
    source "$PROJECT_ROOT/tests/helpers/test_logging.bash"

    # Set up isolated log directory
    export TEST_LOG_DIR="$TEST_TMPDIR/logs"
    mkdir -p "$TEST_LOG_DIR"
}

teardown() {
    test_log_reset
    harness_teardown
}

# ============================================================================
# Initialization Tests
# ============================================================================

@test "test_log_init creates log file" {
    test_log_init "example_test.sh"

    local log_file
    log_file=$(test_log_file)
    [[ -f "$log_file" ]]
}

@test "test_log_init creates log directory" {
    local custom_dir="$TEST_TMPDIR/custom_logs"
    export TEST_LOG_DIR="$custom_dir"

    test_log_init "example_test.sh"

    [[ -d "$custom_dir" ]]
}

@test "test_log_init sets test file name" {
    test_log_init "my_test.sh"

    local log_file
    log_file=$(test_log_file)
    assert_contains "$log_file" "my_test"
}

@test "test_log_init writes header to log file" {
    test_log_init "header_test.sh"

    local log_file
    log_file=$(test_log_file)
    local content
    content=$(cat "$log_file")

    assert_contains "$content" "Test Log:"
    assert_contains "$content" "header_test.sh"
}

# ============================================================================
# Log Level Tests
# ============================================================================

@test "test_log_debug writes DEBUG level" {
    test_log_init "debug_test.sh"

    export TEST_LOG_LEVEL="DEBUG"
    test_log_debug "Debug message"

    local log_file
    log_file=$(test_log_file)
    local content
    content=$(cat "$log_file")

    assert_contains "$content" "[DEBUG]"
    assert_contains "$content" "Debug message"
}

@test "test_log_info writes INFO level" {
    test_log_init "info_test.sh"

    test_log_info "Info message"

    local log_file
    log_file=$(test_log_file)
    local content
    content=$(cat "$log_file")

    assert_contains "$content" "[INFO]"
    assert_contains "$content" "Info message"
}

@test "test_log_pass writes PASS level" {
    test_log_init "pass_test.sh"

    test_log_pass "Test passed"

    local log_file
    log_file=$(test_log_file)
    local content
    content=$(cat "$log_file")

    assert_contains "$content" "[PASS]"
    assert_contains "$content" "Test passed"
}

@test "test_log_fail writes FAIL level" {
    test_log_init "fail_test.sh"

    test_log_fail "Test failed"

    local log_file
    log_file=$(test_log_file)
    local content
    content=$(cat "$log_file")

    assert_contains "$content" "[FAIL]"
    assert_contains "$content" "Test failed"
}

@test "test_log_skip writes SKIP level" {
    test_log_init "skip_test.sh"

    test_log_skip "Test skipped" "not implemented"

    local log_file
    log_file=$(test_log_file)
    local content
    content=$(cat "$log_file")

    assert_contains "$content" "[SKIP]"
    assert_contains "$content" "Test skipped"
}

# ============================================================================
# Timestamp Tests
# ============================================================================

@test "log entries include ISO8601 timestamps" {
    test_log_init "timestamp_test.sh"

    test_log_info "Timestamp test"

    local log_file
    log_file=$(test_log_file)
    local content
    content=$(cat "$log_file")

    # ISO8601 pattern: YYYY-MM-DDTHH:MM:SSZ
    [[ "$content" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
}

# ============================================================================
# Counter Tests
# ============================================================================

@test "test_log_pass increments pass counter" {
    test_log_init "counter_test.sh"

    test_log_pass "First pass"
    test_log_pass "Second pass"
    test_log_pass "Third pass"

    # Summary will show count - check by running summary
    run test_log_summary
    assert_contains "$output" "PASS: 3"
}

@test "test_log_fail increments fail counter" {
    test_log_init "fail_counter_test.sh"

    test_log_fail "First fail"
    test_log_fail "Second fail"

    run test_log_summary
    assert_contains "$output" "FAIL: 2"
}

@test "test_log_skip increments skip counter" {
    test_log_init "skip_counter_test.sh"

    test_log_skip "First skip"
    test_log_skip "Second skip"

    run test_log_summary
    assert_contains "$output" "SKIP: 2"
}

# ============================================================================
# Failure Context Tests
# ============================================================================

@test "test_log_fail includes location" {
    test_log_init "location_test.sh"

    test_log_fail "Assertion failed" "test_file.sh:42"

    local log_file
    log_file=$(test_log_file)
    local content
    content=$(cat "$log_file")

    assert_contains "$content" "test_file.sh:42"
}

@test "test_log_fail_assertion includes expected and actual" {
    test_log_init "assertion_test.sh"

    test_log_fail_assertion "Values mismatch" "expected_value" "actual_value"

    local log_file
    log_file=$(test_log_file)
    local content
    content=$(cat "$log_file")

    assert_contains "$content" "Expected: expected_value"
    assert_contains "$content" "Actual:   actual_value"
}

# ============================================================================
# Summary Tests
# ============================================================================

@test "test_log_summary shows all counts" {
    test_log_init "summary_test.sh"

    test_log_pass "Pass 1"
    test_log_pass "Pass 2"
    test_log_fail "Fail 1"
    test_log_skip "Skip 1"

    run test_log_summary
    assert_contains "$output" "PASS: 2"
    assert_contains "$output" "FAIL: 1"
    assert_contains "$output" "SKIP: 1"
    assert_contains "$output" "Total:  4"
}

@test "test_log_summary creates summary JSON" {
    test_log_init "json_summary_test.sh"

    test_log_pass "Test passed"
    test_log_summary

    local summary_file
    summary_file=$(test_log_summary_file)
    [[ -f "$summary_file" ]]

    # Verify it's valid JSON
    jq empty "$summary_file"
}

@test "test_log_summary JSON includes test file" {
    test_log_init "json_file_test.sh"

    test_log_pass "Test passed"
    test_log_summary

    local summary_file
    summary_file=$(test_log_summary_file)

    local test_file
    test_file=$(jq -r '.tests[0].file' "$summary_file")
    assert_equal "$test_file" "json_file_test.sh"
}

@test "test_log_summary returns success when all pass" {
    test_log_init "success_test.sh"

    test_log_pass "Pass 1"
    test_log_pass "Pass 2"

    run test_log_summary
    [[ "$status" -eq 0 ]]
}

@test "test_log_summary returns failure when any fail" {
    test_log_init "failure_test.sh"

    test_log_pass "Pass 1"
    test_log_fail "Fail 1"

    run test_log_summary
    [[ "$status" -ne 0 ]]
}

# ============================================================================
# Assertion Helper Tests
# ============================================================================

@test "test_assert_equal passes for equal values" {
    test_log_init "assert_equal_pass.sh"

    run test_assert_equal "foo" "foo" "Values should match"
    [[ "$status" -eq 0 ]]
}

@test "test_assert_equal fails for different values" {
    test_log_init "assert_equal_fail.sh"

    run test_assert_equal "foo" "bar" "Values should match"
    [[ "$status" -ne 0 ]]
}

@test "test_assert_contains passes when substring found" {
    test_log_init "assert_contains_pass.sh"

    run test_assert_contains "hello world" "world"
    [[ "$status" -eq 0 ]]
}

@test "test_assert_contains fails when substring not found" {
    test_log_init "assert_contains_fail.sh"

    run test_assert_contains "hello world" "missing"
    [[ "$status" -ne 0 ]]
}

@test "test_assert_file_exists passes for existing file" {
    test_log_init "assert_file_pass.sh"

    local test_file="$TEST_TMPDIR/exists.txt"
    echo "content" > "$test_file"

    run test_assert_file_exists "$test_file"
    [[ "$status" -eq 0 ]]
}

@test "test_assert_file_exists fails for missing file" {
    test_log_init "assert_file_fail.sh"

    run test_assert_file_exists "/nonexistent/file.txt"
    [[ "$status" -ne 0 ]]
}

@test "test_assert_dir_exists passes for existing directory" {
    test_log_init "assert_dir_pass.sh"

    run test_assert_dir_exists "$TEST_TMPDIR"
    [[ "$status" -eq 0 ]]
}

@test "test_assert_dir_exists fails for missing directory" {
    test_log_init "assert_dir_fail.sh"

    run test_assert_dir_exists "/nonexistent/directory"
    [[ "$status" -ne 0 ]]
}

# ============================================================================
# Reset Tests
# ============================================================================

@test "test_log_reset clears counters" {
    test_log_init "reset_test.sh"

    test_log_pass "Pass 1"
    test_log_fail "Fail 1"

    test_log_reset
    test_log_init "reset_test_2.sh"

    test_log_pass "New pass"

    run test_log_summary
    assert_contains "$output" "PASS: 1"
    assert_contains "$output" "FAIL: 0"
}
