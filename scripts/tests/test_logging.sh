#!/usr/bin/env bash
# test_logging.sh - Tests for src/logging.sh
#
# Run: ./scripts/tests/test_logging.sh

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
export DSR_LOG_FILE="$TEMP_DIR/test.log"
export DSR_RUN_ID="test-run-12345"
export DSR_LOG_LEVEL="debug"

# Source the logging module
source "$PROJECT_ROOT/src/logging.sh"

# Test: log_init creates directories
test_log_init() {
    ((TESTS_RUN++))
    log_init
    if [[ -d "$DSR_STATE_DIR/logs" ]]; then
        pass "log_init creates log directory"
    else
        fail "log_init should create log directory"
    fi
}

# Test: log_info writes to file
test_log_info_writes_file() {
    ((TESTS_RUN++))
    > "$DSR_LOG_FILE"  # Clear log file
    log_info "Test message" 2>/dev/null
    if grep -q '"Test message"' "$DSR_LOG_FILE"; then
        pass "log_info writes to file"
    else
        fail "log_info should write to file"
    fi
}

# Test: log_error writes to file
test_log_error_writes_file() {
    ((TESTS_RUN++))
    > "$DSR_LOG_FILE"
    log_error "Error message" 2>/dev/null
    if grep -q '"level":"error"' "$DSR_LOG_FILE"; then
        pass "log_error sets level to error"
    else
        fail "log_error should set level to error"
    fi
}

# Test: log contains run_id
test_log_contains_run_id() {
    ((TESTS_RUN++))
    > "$DSR_LOG_FILE"
    log_info "Check run_id" 2>/dev/null
    if grep -q '"run_id":"test-run-12345"' "$DSR_LOG_FILE"; then
        pass "log contains run_id"
    else
        fail "log should contain run_id"
    fi
}

# Test: log contains timestamp
test_log_contains_timestamp() {
    ((TESTS_RUN++))
    > "$DSR_LOG_FILE"
    log_info "Check timestamp" 2>/dev/null
    if grep -qE '"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$DSR_LOG_FILE"; then
        pass "log contains ISO8601 timestamp"
    else
        fail "log should contain ISO8601 timestamp"
    fi
}

# Test: extra JSON fields
test_log_extra_fields() {
    ((TESTS_RUN++))
    > "$DSR_LOG_FILE"
    log_info "With extra" '"custom_key":"custom_value"' 2>/dev/null
    if grep -q '"custom_key":"custom_value"' "$DSR_LOG_FILE"; then
        pass "log accepts extra JSON fields"
    else
        fail "log should accept extra JSON fields"
    fi
}

# Test: log_set_command sets context
test_log_set_command() {
    ((TESTS_RUN++))
    > "$DSR_LOG_FILE"
    log_set_command "build"
    log_info "Command context" 2>/dev/null
    if grep -q '"cmd":"build"' "$DSR_LOG_FILE"; then
        pass "log_set_command sets cmd field"
    else
        fail "log_set_command should set cmd field"
    fi
}

# Test: log_set_tool sets context
test_log_set_tool() {
    ((TESTS_RUN++))
    > "$DSR_LOG_FILE"
    log_set_tool "ntm"
    log_info "Tool context" 2>/dev/null
    if grep -q '"tool":"ntm"' "$DSR_LOG_FILE"; then
        pass "log_set_tool sets tool field"
    else
        fail "log_set_tool should set tool field"
    fi
}

# Test: quiet mode suppresses info
test_quiet_mode() {
    ((TESTS_RUN++))
    > "$DSR_LOG_FILE"
    LOG_LEVEL="error"
    log_info "Should not appear" 2>/dev/null
    LOG_LEVEL="debug"  # Reset
    if ! grep -q "Should not appear" "$DSR_LOG_FILE"; then
        pass "quiet mode suppresses info"
    else
        fail "quiet mode should suppress info"
    fi
}

# Test: JSON escaping
test_json_escape() {
    ((TESTS_RUN++))
    > "$DSR_LOG_FILE"
    log_info 'Message with "quotes" and \backslash' 2>/dev/null
    if jq . "$DSR_LOG_FILE" >/dev/null 2>&1; then
        pass "log output is valid JSON"
    else
        fail "log output should be valid JSON"
    fi
}

# Test: log_get_run_id returns correct value
test_log_get_run_id() {
    ((TESTS_RUN++))
    local run_id
    run_id=$(log_get_run_id)
    if [[ "$run_id" == "test-run-12345" ]]; then
        pass "log_get_run_id returns correct value"
    else
        fail "log_get_run_id should return test-run-12345, got: $run_id"
    fi
}

# Test: log_timed captures duration
test_log_timed() {
    ((TESTS_RUN++))
    > "$DSR_LOG_FILE"
    log_timed sleep 0.1 2>/dev/null
    if grep -qE '"duration_ms":[0-9]+' "$DSR_LOG_FILE"; then
        pass "log_timed captures duration_ms"
    else
        fail "log_timed should capture duration_ms"
    fi
}

# Cleanup
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Run all tests
echo "Running logging module tests..."
echo ""

test_log_init
test_log_info_writes_file
test_log_error_writes_file
test_log_contains_run_id
test_log_contains_timestamp
test_log_extra_fields
test_log_set_command
test_log_set_tool
test_quiet_mode
test_json_escape
test_log_get_run_id
test_log_timed

echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN"
echo "Passed:    $TESTS_PASSED"
echo "Failed:    $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
