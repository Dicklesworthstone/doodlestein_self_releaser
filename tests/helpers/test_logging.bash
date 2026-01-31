#!/usr/bin/env bash
# test_logging.bash - Structured logging infrastructure for tests
#
# bd-1nf: Test infrastructure: structured logging for tests
#
# Provides consistent, detailed logging for all test files with:
# - Log levels: DEBUG, INFO, PASS, FAIL, SKIP
# - ISO8601 timestamps
# - Per-test log files and aggregated summary
# - Failure context with file:line information
#
# Usage:
#   source test_logging.bash
#   test_log_init "test_config.sh"
#   test_log_debug "Creating temp directory"
#   test_log_pass "config_init creates directories"
#   test_log_fail "Expected 'info' got 'debug'" "test_config.sh:45"
#   test_log_summary
#
# Integration:
#   Works with BATS and standalone shell tests

set -uo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Log directory (default: logs/tests/YYYY-MM-DD)
TEST_LOG_DIR="${TEST_LOG_DIR:-}"
TEST_LOG_LEVEL="${TEST_LOG_LEVEL:-INFO}"  # DEBUG, INFO, PASS, FAIL, SKIP

# Log colors (if terminal supports it)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _TL_RED=$'\033[0;31m'
    _TL_GREEN=$'\033[0;32m'
    _TL_YELLOW=$'\033[0;33m'
    _TL_BLUE=$'\033[0;34m'
    _TL_CYAN=$'\033[0;36m'
    _TL_GRAY=$'\033[0;90m'
    _TL_BOLD=$'\033[1m'
    _TL_NC=$'\033[0m'
else
    _TL_RED='' _TL_GREEN='' _TL_YELLOW='' _TL_BLUE='' _TL_CYAN='' _TL_GRAY='' _TL_BOLD='' _TL_NC=''
fi

# ============================================================================
# Internal State
# ============================================================================

_TL_INITIALIZED=false
_TL_TEST_FILE=""
_TL_LOG_FILE=""
_TL_SUMMARY_FILE=""
_TL_START_TIME=""

# Counters
_TL_PASS_COUNT=0
_TL_FAIL_COUNT=0
_TL_SKIP_COUNT=0
_TL_TOTAL_COUNT=0

# Failure details
declare -a _TL_FAILURES=()

# ============================================================================
# Initialization
# ============================================================================

# Initialize test logging for a test file
# Args: test_file_name
test_log_init() {
    local test_file="${1:-unknown}"
    _TL_TEST_FILE="$test_file"
    _TL_START_TIME=$(date +%s)

    # Reset counters
    _TL_PASS_COUNT=0
    _TL_FAIL_COUNT=0
    _TL_SKIP_COUNT=0
    _TL_TOTAL_COUNT=0
    _TL_FAILURES=()

    # Set up log directory
    if [[ -z "$TEST_LOG_DIR" ]]; then
        local base_dir="${DSR_STATE_DIR:-$HOME/.local/state/dsr}"
        TEST_LOG_DIR="$base_dir/logs/tests/$(date +%Y-%m-%d)"
    fi
    mkdir -p "$TEST_LOG_DIR"

    # Create log file for this test
    _TL_LOG_FILE="$TEST_LOG_DIR/${test_file%.*}.log"
    _TL_SUMMARY_FILE="$TEST_LOG_DIR/summary.json"

    # Initialize log file
    {
        echo "# Test Log: $test_file"
        echo "# Started: $(date -Iseconds)"
        echo "# Host: $(hostname)"
        echo ""
    } > "$_TL_LOG_FILE"

    _TL_INITIALIZED=true

    test_log_info "Starting tests from $test_file"
}

# ============================================================================
# Logging Functions
# ============================================================================

# Get current ISO8601 timestamp
_tl_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Internal log writer
# Args: level message [color]
_tl_log() {
    local level="$1"
    local message="$2"
    local color="${3:-$_TL_NC}"
    local timestamp
    timestamp=$(_tl_timestamp)

    # Check log level
    case "$TEST_LOG_LEVEL" in
        DEBUG) ;;  # Show all
        INFO)  [[ "$level" == "DEBUG" ]] && return ;;
        PASS)  [[ "$level" =~ ^(DEBUG|INFO)$ ]] && return ;;
        FAIL)  [[ "$level" =~ ^(DEBUG|INFO|PASS|SKIP)$ ]] && return ;;
        SKIP)  [[ "$level" =~ ^(DEBUG|INFO|PASS)$ ]] && return ;;
    esac

    # Format message
    local formatted="[$timestamp] [$level] $_TL_TEST_FILE: $message"

    # Write to log file
    if [[ -n "$_TL_LOG_FILE" ]]; then
        echo "$formatted" >> "$_TL_LOG_FILE"
    fi

    # Write to stderr with color
    echo "${color}${formatted}${_TL_NC}" >&2
}

# Log debug message
test_log_debug() {
    _tl_log "DEBUG" "$*" "$_TL_GRAY"
}

# Log info message
test_log_info() {
    _tl_log "INFO" "$*" "$_TL_BLUE"
}

# Log pass (successful assertion)
# Args: message [test_name]
test_log_pass() {
    local message="$1"
    local test_name="${2:-}"

    _TL_PASS_COUNT=$((_TL_PASS_COUNT + 1))
    _TL_TOTAL_COUNT=$((_TL_TOTAL_COUNT + 1))

    local full_message="$message"
    [[ -n "$test_name" ]] && full_message="$test_name: $message"

    _tl_log "PASS" "$full_message" "$_TL_GREEN"
}

# Log failure
# Args: message [location]
test_log_fail() {
    local message="$1"
    local location="${2:-}"

    _TL_FAIL_COUNT=$((_TL_FAIL_COUNT + 1))
    _TL_TOTAL_COUNT=$((_TL_TOTAL_COUNT + 1))

    local full_message="$message"
    if [[ -n "$location" ]]; then
        full_message+=$'\n'"  -> File: $location"
    fi

    _tl_log "FAIL" "$full_message" "$_TL_RED"

    # Store failure details
    local failure_entry
    failure_entry=$(jq -nc \
        --arg message "$message" \
        --arg location "${location:-}" \
        --arg timestamp "$(_tl_timestamp)" \
        '{message: $message, location: $location, timestamp: $timestamp}')
    _TL_FAILURES+=("$failure_entry")
}

# Log failed assertion with expected/actual
# Args: message expected actual [location]
test_log_fail_assertion() {
    local message="$1"
    local expected="$2"
    local actual="$3"
    local location="${4:-}"

    _TL_FAIL_COUNT=$((_TL_FAIL_COUNT + 1))
    _TL_TOTAL_COUNT=$((_TL_TOTAL_COUNT + 1))

    local full_message="$message"
    full_message+=$'\n'"  -> Expected: $expected"
    full_message+=$'\n'"  -> Actual:   $actual"
    [[ -n "$location" ]] && full_message+=$'\n'"  -> File: $location"

    _tl_log "FAIL" "$full_message" "$_TL_RED"

    # Store failure details
    local failure_entry
    failure_entry=$(jq -nc \
        --arg message "$message" \
        --arg expected "$expected" \
        --arg actual "$actual" \
        --arg location "${location:-}" \
        --arg timestamp "$(_tl_timestamp)" \
        '{message: $message, expected: $expected, actual: $actual, location: $location, timestamp: $timestamp}')
    _TL_FAILURES+=("$failure_entry")
}

# Log skip
# Args: message [reason]
test_log_skip() {
    local message="$1"
    local reason="${2:-}"

    _TL_SKIP_COUNT=$((_TL_SKIP_COUNT + 1))
    _TL_TOTAL_COUNT=$((_TL_TOTAL_COUNT + 1))

    local full_message="$message"
    [[ -n "$reason" ]] && full_message+=" ($reason)"

    _tl_log "SKIP" "$full_message" "$_TL_YELLOW"
}

# ============================================================================
# Environment Capture
# ============================================================================

# Capture environment snapshot for debugging
test_log_env_snapshot() {
    local label="${1:-Environment Snapshot}"

    test_log_debug "$label"
    test_log_debug "  PWD: $PWD"
    test_log_debug "  USER: ${USER:-unknown}"
    test_log_debug "  HOME: $HOME"
    [[ -n "${DSR_CONFIG_DIR:-}" ]] && test_log_debug "  DSR_CONFIG_DIR: $DSR_CONFIG_DIR"
    [[ -n "${DSR_STATE_DIR:-}" ]] && test_log_debug "  DSR_STATE_DIR: $DSR_STATE_DIR"
    [[ -n "${TEST_TMPDIR:-}" ]] && test_log_debug "  TEST_TMPDIR: $TEST_TMPDIR"
}

# Capture last N lines of a file for context
# Args: file [lines]
test_log_file_context() {
    local file="$1"
    local lines="${2:-20}"

    if [[ ! -f "$file" ]]; then
        test_log_debug "File not found: $file"
        return
    fi

    test_log_debug "Last $lines lines of $file:"
    while IFS= read -r line; do
        test_log_debug "  $line"
    done < <(tail -n "$lines" "$file")
}

# ============================================================================
# Summary
# ============================================================================

# Print and save test summary
test_log_summary() {
    if [[ "$_TL_INITIALIZED" != true ]]; then
        echo "test_log_summary: not initialized" >&2
        return 1
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - _TL_START_TIME))

    # Determine overall status
    local status="PASS"
    [[ $_TL_FAIL_COUNT -gt 0 ]] && status="FAIL"

    # Print summary
    echo "" >&2
    echo "${_TL_BOLD}=== Test Summary ===${_TL_NC}" >&2
    echo "File:     $_TL_TEST_FILE" >&2
    echo "Duration: ${duration}s" >&2
    echo "" >&2
    echo "${_TL_GREEN}PASS${_TL_NC}: $_TL_PASS_COUNT" >&2
    echo "${_TL_RED}FAIL${_TL_NC}: $_TL_FAIL_COUNT" >&2
    echo "${_TL_YELLOW}SKIP${_TL_NC}: $_TL_SKIP_COUNT" >&2
    echo "Total:  $_TL_TOTAL_COUNT" >&2
    echo "" >&2

    if [[ $_TL_FAIL_COUNT -gt 0 ]]; then
        echo "${_TL_RED}${_TL_BOLD}FAILED${_TL_NC}" >&2
    else
        echo "${_TL_GREEN}${_TL_BOLD}PASSED${_TL_NC}" >&2
    fi

    # Write to log file
    if [[ -n "$_TL_LOG_FILE" ]]; then
        {
            echo ""
            echo "# Summary"
            echo "# Status: $status"
            echo "# Pass: $_TL_PASS_COUNT"
            echo "# Fail: $_TL_FAIL_COUNT"
            echo "# Skip: $_TL_SKIP_COUNT"
            echo "# Total: $_TL_TOTAL_COUNT"
            echo "# Duration: ${duration}s"
            echo "# Finished: $(date -Iseconds)"
        } >> "$_TL_LOG_FILE"
    fi

    # Update summary JSON
    _tl_update_summary "$status" "$duration"

    # Return appropriate exit code
    [[ $_TL_FAIL_COUNT -eq 0 ]]
}

# Update aggregated summary JSON
_tl_update_summary() {
    local status="$1"
    local duration="$2"

    # Build failures array
    local failures_json="[]"
    if [[ ${#_TL_FAILURES[@]} -gt 0 ]]; then
        failures_json=$(printf '%s\n' "${_TL_FAILURES[@]}" | jq -s '.')
    fi

    # Create test entry
    local test_entry
    test_entry=$(jq -nc \
        --arg file "$_TL_TEST_FILE" \
        --arg status "$status" \
        --argjson pass "$_TL_PASS_COUNT" \
        --argjson fail "$_TL_FAIL_COUNT" \
        --argjson skip "$_TL_SKIP_COUNT" \
        --argjson total "$_TL_TOTAL_COUNT" \
        --argjson duration "$duration" \
        --argjson failures "$failures_json" \
        --arg timestamp "$(_tl_timestamp)" \
        '{
            file: $file,
            status: $status,
            pass: $pass,
            fail: $fail,
            skip: $skip,
            total: $total,
            duration_seconds: $duration,
            failures: $failures,
            timestamp: $timestamp
        }')

    # Append to or create summary file
    if [[ -f "$_TL_SUMMARY_FILE" ]]; then
        # Read existing and append
        local existing
        existing=$(cat "$_TL_SUMMARY_FILE")
        local new_tests
        new_tests=$(echo "$existing" | jq --argjson entry "$test_entry" '.tests += [$entry]')

        # Update totals
        local total_pass total_fail total_skip
        total_pass=$(echo "$new_tests" | jq '[.tests[].pass] | add')
        total_fail=$(echo "$new_tests" | jq '[.tests[].fail] | add')
        total_skip=$(echo "$new_tests" | jq '[.tests[].skip] | add')

        echo "$new_tests" | jq \
            --argjson pass "$total_pass" \
            --argjson fail "$total_fail" \
            --argjson skip "$total_skip" \
            '.total_pass = $pass | .total_fail = $fail | .total_skip = $skip | .updated_at = now | strftime("%Y-%m-%dT%H:%M:%SZ")' \
            > "$_TL_SUMMARY_FILE"
    else
        # Create new summary
        jq -nc \
            --argjson tests "[$test_entry]" \
            --argjson pass "$_TL_PASS_COUNT" \
            --argjson fail "$_TL_FAIL_COUNT" \
            --argjson skip "$_TL_SKIP_COUNT" \
            --arg timestamp "$(_tl_timestamp)" \
            '{
                tests: $tests,
                total_pass: $pass,
                total_fail: $fail,
                total_skip: $skip,
                created_at: $timestamp,
                updated_at: $timestamp
            }' > "$_TL_SUMMARY_FILE"
    fi
}

# ============================================================================
# Cleanup
# ============================================================================

# Reset test logging state
test_log_reset() {
    _TL_INITIALIZED=false
    _TL_TEST_FILE=""
    _TL_LOG_FILE=""
    _TL_START_TIME=""
    _TL_PASS_COUNT=0
    _TL_FAIL_COUNT=0
    _TL_SKIP_COUNT=0
    _TL_TOTAL_COUNT=0
    _TL_FAILURES=()
}

# Get log file path
test_log_file() {
    echo "$_TL_LOG_FILE"
}

# Get summary file path
test_log_summary_file() {
    echo "$_TL_SUMMARY_FILE"
}

# ============================================================================
# Assertions (optional convenience wrappers)
# ============================================================================

# Assert two values are equal
# Args: expected actual [message] [location]
test_assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"
    local location="${4:-}"

    if [[ "$expected" == "$actual" ]]; then
        test_log_pass "$message"
        return 0
    else
        test_log_fail_assertion "$message" "$expected" "$actual" "$location"
        return 1
    fi
}

# Assert string contains substring
# Args: string substring [message] [location]
test_assert_contains() {
    local string="$1"
    local substring="$2"
    local message="${3:-String should contain substring}"
    local location="${4:-}"

    if [[ "$string" == *"$substring"* ]]; then
        test_log_pass "$message"
        return 0
    else
        test_log_fail_assertion "$message" "contains '$substring'" "'$string'" "$location"
        return 1
    fi
}

# Assert file exists
# Args: path [message] [location]
test_assert_file_exists() {
    local path="$1"
    local message="${2:-File should exist: $path}"
    local location="${3:-}"

    if [[ -f "$path" ]]; then
        test_log_pass "$message"
        return 0
    else
        test_log_fail "$message" "$location"
        return 1
    fi
}

# Assert directory exists
# Args: path [message] [location]
test_assert_dir_exists() {
    local path="$1"
    local message="${2:-Directory should exist: $path}"
    local location="${3:-}"

    if [[ -d "$path" ]]; then
        test_log_pass "$message"
        return 0
    else
        test_log_fail "$message" "$location"
        return 1
    fi
}

# ============================================================================
# Exports
# ============================================================================

export -f test_log_init test_log_debug test_log_info test_log_pass test_log_fail
export -f test_log_fail_assertion test_log_skip test_log_summary test_log_reset
export -f test_log_env_snapshot test_log_file_context
export -f test_log_file test_log_summary_file
export -f test_assert_equal test_assert_contains test_assert_file_exists test_assert_dir_exists
