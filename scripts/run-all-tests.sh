#!/usr/bin/env bash
# run-all-tests.sh - Unified test runner for dsr
#
# bd-2lm: Test infrastructure: run-all-tests.sh runner script
#
# Features:
# - Discovers and runs shell tests (scripts/tests/test_*.sh)
# - Discovers and runs BATS tests (tests/**/*.bats)
# - Parallel execution with configurable concurrency
# - Per-test log files with timestamps
# - JSON and human-readable summaries
# - CI-friendly output (JUnit XML, TAP)
# - Timeout enforcement per test
#
# Usage:
#   ./scripts/run-all-tests.sh              # Run all tests
#   ./scripts/run-all-tests.sh --filter "*version*"  # Filter by pattern
#   ./scripts/run-all-tests.sh --parallel 4 # Run 4 tests in parallel
#   ./scripts/run-all-tests.sh --ci         # CI mode with JUnit output
#   ./scripts/run-all-tests.sh --list       # List discovered tests

set -uo pipefail

# Get script directory (no global cd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
DEFAULT_TIMEOUT=120  # 2 minutes per test
LOG_DIR="${PROJECT_ROOT}/logs/tests"
DATE_DIR="$(date +%Y-%m-%d)"

# Runtime state
_FILTER=""
_EXCLUDE=""
_PARALLEL=1
_TIMEOUT=$DEFAULT_TIMEOUT
_CI_MODE=false
_LIST_MODE=false
_VERBOSE=false
_JUNIT_FILE=""
_TAP_MODE=false
_BATS_ONLY=false
_SHELL_ONLY=false

# Results
_TESTS_RUN=0
_TESTS_PASSED=0
_TESTS_FAILED=0
_TESTS_SKIPPED=0
_FAILED_TESTS=()
_TEST_RESULTS=()
_START_TIME=""

# Colors (disable if NO_COLOR set or not a terminal)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _RED=$'\033[0;31m'
    _GREEN=$'\033[0;32m'
    _YELLOW=$'\033[0;33m'
    _BLUE=$'\033[0;34m'
    _BOLD=$'\033[1m'
    _NC=$'\033[0m'
else
    _RED='' _GREEN='' _YELLOW='' _BLUE='' _BOLD='' _NC=''
fi

# ============================================================================
# Logging
# ============================================================================

_log_info()  { echo -e "${_BLUE}[tests]${_NC} $*" >&2; }
_log_ok()    { echo -e "${_GREEN}[tests]${_NC} $*" >&2; }
_log_warn()  { echo -e "${_YELLOW}[tests]${_NC} $*" >&2; }
_log_error() { echo -e "${_RED}[tests]${_NC} $*" >&2; }

_log_result() {
    local name="$1"
    local status="$2"
    local duration="$3"
    local tests="${4:-}"

    local status_str
    case "$status" in
        pass) status_str="${_GREEN}PASS${_NC}" ;;
        fail) status_str="${_RED}FAIL${_NC}" ;;
        skip) status_str="${_YELLOW}SKIP${_NC}" ;;
        *) status_str="$status" ;;
    esac

    if [[ -n "$tests" ]]; then
        printf "  %-40s %3s tests  %s  (%s)\n" "$name" "$tests" "$status_str" "$duration" >&2
    else
        printf "  %-40s %s  (%s)\n" "$name" "$status_str" "$duration" >&2
    fi
}

# ============================================================================
# Test Discovery
# ============================================================================

_discover_shell_tests() {
    local tests_dir="$PROJECT_ROOT/scripts/tests"
    local tests=()

    if [[ -d "$tests_dir" ]]; then
        while IFS= read -r -d '' file; do
            local name
            name=$(basename "$file")

            # Apply filter (quoted to prevent glob matching)
            if [[ -n "$_FILTER" && ! "$name" == "$_FILTER" ]]; then
                continue
            fi

            # Apply exclude (quoted to prevent glob matching)
            if [[ -n "$_EXCLUDE" && "$name" == "$_EXCLUDE" ]]; then
                continue
            fi

            tests+=("$file")
        done < <(find "$tests_dir" -maxdepth 1 -name "test_*.sh" -type f -print0 | sort -z)
    fi

    printf '%s\n' "${tests[@]}"
}

_discover_bats_tests() {
    local tests_dir="$PROJECT_ROOT/tests"
    local tests=()

    if [[ -d "$tests_dir" ]]; then
        while IFS= read -r -d '' file; do
            local name
            name=$(basename "$file")

            # Apply filter (quoted to prevent glob matching)
            if [[ -n "$_FILTER" && ! "$name" == "$_FILTER" ]]; then
                continue
            fi

            # Apply exclude (quoted to prevent glob matching)
            if [[ -n "$_EXCLUDE" && "$name" == "$_EXCLUDE" ]]; then
                continue
            fi

            tests+=("$file")
        done < <(find "$tests_dir" -name "*.bats" -type f -print0 | sort -z)
    fi

    printf '%s\n' "${tests[@]}"
}

_discover_all_tests() {
    if ! $_BATS_ONLY; then
        _discover_shell_tests
    fi
    if ! $_SHELL_ONLY; then
        _discover_bats_tests
    fi
}

# ============================================================================
# Test Execution
# ============================================================================

_run_shell_test() {
    local test_file="$1"
    local log_file="$2"
    local name
    name=$(basename "$test_file")

    # Run with timeout
    local exit_code=0
    local start_time end_time duration

    start_time=$(date +%s.%N)

    if timeout "$_TIMEOUT" bash "$test_file" </dev/null > "$log_file" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi

    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0.0")
    duration=$(printf "%.1fs" "$duration")

    # Check for skip marker in output
    if grep -q "^SKIP:" "$log_file" 2>/dev/null; then
        echo "skip|$name|$duration|0"
        return
    fi

    if [[ $exit_code -eq 0 ]]; then
        # Count passed tests from output if available
        local test_count
        test_count=$(grep -c "^ok " "$log_file" 2>/dev/null || echo "")
        echo "pass|$name|$duration|$test_count"
    elif [[ $exit_code -eq 124 ]]; then
        echo "fail|$name|timeout|0"
    else
        echo "fail|$name|$duration|0"
    fi
}

_run_bats_test() {
    local test_file="$1"
    local log_file="$2"
    local name
    name=$(basename "$test_file")

    # Check if bats is available
    if ! command -v bats &>/dev/null; then
        echo "skip|$name|0.0s|0"
        return
    fi

    local exit_code=0
    local start_time end_time duration

    start_time=$(date +%s.%N)

    if timeout "$_TIMEOUT" bats "$test_file" </dev/null > "$log_file" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi

    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0.0")
    duration=$(printf "%.1fs" "$duration")

    if [[ $exit_code -eq 0 ]]; then
        # Count tests from BATS output (TAP format: 1..N)
        local test_count
        test_count=$(grep -E "^1\.\.[0-9]+" "$log_file" 2>/dev/null | sed 's/1\.\.//')
        echo "pass|$name|$duration|$test_count"
    elif [[ $exit_code -eq 124 ]]; then
        echo "fail|$name|timeout|0"
    else
        echo "fail|$name|$duration|0"
    fi
}

_run_test() {
    local test_file="$1"
    local log_dir="$LOG_DIR/$DATE_DIR"
    mkdir -p "$log_dir"

    local name log_file
    name=$(basename "$test_file")
    log_file="$log_dir/${name%.sh}.log"
    log_file="${log_file%.bats}.log"

    if [[ "$test_file" == *.bats ]]; then
        _run_bats_test "$test_file" "$log_file"
    else
        _run_shell_test "$test_file" "$log_file"
    fi
}

_run_tests_sequential() {
    local tests=("$@")

    for test_file in "${tests[@]}"; do
        [[ -z "$test_file" ]] && continue

        local result
        result=$(_run_test "$test_file")

        IFS='|' read -r status name duration test_count <<< "$result"

        _log_result "$name" "$status" "$duration" "$test_count"

        _TEST_RESULTS+=("$result")
        ((_TESTS_RUN++))

        case "$status" in
            pass) ((_TESTS_PASSED++)) ;;
            fail)
                ((_TESTS_FAILED++))
                _FAILED_TESTS+=("$name")
                ;;
            skip) ((_TESTS_SKIPPED++)) ;;
        esac
    done
}

_run_tests_parallel() {
    local tests=("$@")
    local max_jobs=$_PARALLEL
    local pids=()
    local result_files=()
    local tmpdir
    tmpdir=$(mktemp -d)

    local i=0
    for test_file in "${tests[@]}"; do
        [[ -z "$test_file" ]] && continue

        local result_file="$tmpdir/result.$i"
        result_files+=("$result_file")

        (
            result=$(_run_test "$test_file")
            echo "$result" > "$result_file"
        ) &
        pids+=($!)

        ((i++))

        # Wait if we've hit max parallel jobs
        if [[ ${#pids[@]} -ge $max_jobs ]]; then
            wait "${pids[0]}"
            pids=("${pids[@]:1}")
        fi
    done

    # Wait for remaining jobs
    wait

    # Collect results
    for result_file in "${result_files[@]}"; do
        if [[ -f "$result_file" ]]; then
            local result
            result=$(cat "$result_file")

            IFS='|' read -r status name duration test_count <<< "$result"

            _log_result "$name" "$status" "$duration" "$test_count"

            _TEST_RESULTS+=("$result")
            ((_TESTS_RUN++))

            case "$status" in
                pass) ((_TESTS_PASSED++)) ;;
                fail)
                    ((_TESTS_FAILED++))
                    _FAILED_TESTS+=("$name")
                    ;;
                skip) ((_TESTS_SKIPPED++)) ;;
            esac
        fi
    done

    rm -rf "$tmpdir"
}

# ============================================================================
# Output Formats
# ============================================================================

_print_summary() {
    local end_time total_duration
    end_time=$(date +%s)
    total_duration=$((end_time - _START_TIME))

    echo "" >&2
    echo "${_BOLD}=== Summary ===${_NC}" >&2
    echo "Tests:   $_TESTS_RUN run, $_TESTS_PASSED passed, $_TESTS_FAILED failed, $_TESTS_SKIPPED skipped" >&2
    echo "Time:    ${total_duration}s" >&2

    if [[ ${#_FAILED_TESTS[@]} -gt 0 ]]; then
        echo "" >&2
        echo "${_RED}Failed tests:${_NC}" >&2
        for test in "${_FAILED_TESTS[@]}"; do
            echo "  - $test" >&2
        done
    fi
}

_print_json_summary() {
    local end_time total_duration
    end_time=$(date +%s)
    total_duration=$((end_time - _START_TIME))

    cat << EOF
{
  "tests_run": $_TESTS_RUN,
  "tests_passed": $_TESTS_PASSED,
  "tests_failed": $_TESTS_FAILED,
  "tests_skipped": $_TESTS_SKIPPED,
  "duration_seconds": $total_duration,
  "failed_tests": [$(printf '"%s",' "${_FAILED_TESTS[@]}" | sed 's/,$//')]
}
EOF
}

_print_junit_xml() {
    local output_file="$1"
    local end_time total_duration
    end_time=$(date +%s)
    total_duration=$((end_time - _START_TIME))

    cat > "$output_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="$_TESTS_RUN" failures="$_TESTS_FAILED" time="$total_duration">
  <testsuite name="dsr-tests" tests="$_TESTS_RUN" failures="$_TESTS_FAILED" skipped="$_TESTS_SKIPPED" time="$total_duration">
EOF

    for result in "${_TEST_RESULTS[@]}"; do
        IFS='|' read -r status name duration test_count <<< "$result"
        local time_val
        time_val=$(echo "$duration" | sed 's/s$//')

        echo "    <testcase name=\"$name\" time=\"$time_val\">" >> "$output_file"

        if [[ "$status" == "fail" ]]; then
            local log_file="$LOG_DIR/$DATE_DIR/${name%.sh}.log"
            log_file="${log_file%.bats}.log"
            local error_msg=""
            if [[ -f "$log_file" ]]; then
                error_msg=$(tail -20 "$log_file" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
            fi
            echo "      <failure message=\"Test failed\"><![CDATA[$error_msg]]></failure>" >> "$output_file"
        elif [[ "$status" == "skip" ]]; then
            echo "      <skipped/>" >> "$output_file"
        fi

        echo "    </testcase>" >> "$output_file"
    done

    cat >> "$output_file" << EOF
  </testsuite>
</testsuites>
EOF
}

_print_tap() {
    echo "TAP version 13"
    echo "1..$_TESTS_RUN"

    local i=1
    for result in "${_TEST_RESULTS[@]}"; do
        IFS='|' read -r status name duration test_count <<< "$result"

        case "$status" in
            pass) echo "ok $i - $name # $duration" ;;
            fail) echo "not ok $i - $name # $duration" ;;
            skip) echo "ok $i - $name # SKIP" ;;
        esac
        ((i++))
    done
}

# ============================================================================
# Main
# ============================================================================

_show_help() {
    cat << 'EOF'
run-all-tests.sh - Unified test runner for dsr

USAGE:
    ./scripts/run-all-tests.sh [options]

OPTIONS:
    --filter <pattern>    Filter tests by glob pattern (e.g., "*version*")
    --exclude <pattern>   Exclude tests by glob pattern
    --parallel <N>        Run N tests in parallel (default: 1)
    --timeout <sec>       Timeout per test in seconds (default: 120)
    --ci                  CI mode (enables JUnit output)
    --junit <file>        Output JUnit XML to file
    --tap                 Output TAP format
    --list                List discovered tests without running
    --verbose, -v         Show full test output
    --bats-only          Run only BATS tests
    --shell-only         Run only shell tests
    --help, -h           Show this help

EXAMPLES:
    ./scripts/run-all-tests.sh                  # Run all tests
    ./scripts/run-all-tests.sh --filter "*config*"  # Only config tests
    ./scripts/run-all-tests.sh --parallel 4     # 4 tests in parallel
    ./scripts/run-all-tests.sh --ci             # CI mode with JUnit
    ./scripts/run-all-tests.sh --list           # Show discovered tests

EXIT CODES:
    0  All tests passed
    1  One or more tests failed
    2  Invalid arguments
EOF
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --filter)
                _FILTER="$2"
                shift 2
                ;;
            --exclude)
                _EXCLUDE="$2"
                shift 2
                ;;
            --parallel)
                _PARALLEL="$2"
                shift 2
                ;;
            --timeout)
                _TIMEOUT="$2"
                shift 2
                ;;
            --ci)
                _CI_MODE=true
                _JUNIT_FILE="$LOG_DIR/$DATE_DIR/junit.xml"
                shift
                ;;
            --junit)
                _JUNIT_FILE="$2"
                shift 2
                ;;
            --tap)
                _TAP_MODE=true
                shift
                ;;
            --list)
                _LIST_MODE=true
                shift
                ;;
            --verbose|-v)
                _VERBOSE=true
                shift
                ;;
            --bats-only)
                _BATS_ONLY=true
                shift
                ;;
            --shell-only)
                _SHELL_ONLY=true
                shift
                ;;
            --help|-h)
                _show_help
                return 0
                ;;
            *)
                _log_error "Unknown option: $1"
                return 2
                ;;
        esac
    done

    # Discover tests
    local tests=()
    mapfile -t tests < <(_discover_all_tests)

    if [[ ${#tests[@]} -eq 0 ]]; then
        _log_warn "No tests found"
        return 0
    fi

    # List mode
    if $_LIST_MODE; then
        echo "Discovered ${#tests[@]} test files:"
        for test in "${tests[@]}"; do
            echo "  $(basename "$test")"
        done
        return 0
    fi

    # Run tests
    _START_TIME=$(date +%s)

    echo "${_BOLD}=== dsr Test Suite ===${_NC}" >&2
    echo "Running ${#tests[@]} test files..." >&2
    echo "" >&2

    mkdir -p "$LOG_DIR/$DATE_DIR"

    if [[ $_PARALLEL -gt 1 ]]; then
        _run_tests_parallel "${tests[@]}"
    else
        _run_tests_sequential "${tests[@]}"
    fi

    # Output results
    _print_summary

    if $_TAP_MODE; then
        _print_tap
    fi

    if [[ -n "$_JUNIT_FILE" ]]; then
        mkdir -p "$(dirname "$_JUNIT_FILE")"
        _print_junit_xml "$_JUNIT_FILE"
        _log_info "JUnit report: $_JUNIT_FILE"
    fi

    # JSON summary to stdout (parseable)
    _print_json_summary

    # Exit code
    if [[ $_TESTS_FAILED -gt 0 ]]; then
        return 1
    fi
    return 0
}

main "$@"
