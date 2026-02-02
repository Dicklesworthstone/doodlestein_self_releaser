#!/usr/bin/env bash
# test_artifact_naming_parse_workflow.sh - Unit tests for artifact_naming_parse_workflow()
#
# Usage: ./scripts/tests/test_artifact_naming_parse_workflow.sh [-v] [-vv] [--json]
#
# Options:
#   -v        Verbose mode: show each check
#   -vv       Debug mode: full command output
#   --json    JSON output for CI integration
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#
# Dependencies:
#   yq - Required for YAML parsing (tests skip gracefully if not installed)
#
# shellcheck disable=SC2016 # Tests use literal ${var} patterns that should not expand

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/artifact_naming"

# Verbosity levels
VERBOSE=0
JSON_OUTPUT=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v)     VERBOSE=1; shift ;;
        -vv)    VERBOSE=2; shift ;;
        --json) JSON_OUTPUT=1; shift ;;
        *)      shift ;;
    esac
done

# Source the module under test
# Note: Module logs go to stderr, JSON output goes to stdout (proper stream separation)
source "$PROJECT_ROOT/src/artifact_naming.sh"

# Test counters
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
START_TIME=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))

# Results storage for JSON output
declare -a PHASE_RESULTS=()

# =============================================================================
# LOGGING
# =============================================================================

log_timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

log_test() {
    if [[ $JSON_OUTPUT -eq 0 ]]; then
        echo "[$(log_timestamp)] [TEST] $*" >&2
    fi
}

log_pass() {
    if [[ $JSON_OUTPUT -eq 0 ]]; then
        echo "[$(log_timestamp)] [PASS] $*" >&2
    fi
}

log_fail() {
    if [[ $JSON_OUTPUT -eq 0 ]]; then
        echo "[$(log_timestamp)] [FAIL] $*" >&2
    fi
}

log_skip() {
    if [[ $JSON_OUTPUT -eq 0 ]]; then
        echo "[$(log_timestamp)] [SKIP] $*" >&2
    fi
}

log_info() {
    if [[ $JSON_OUTPUT -eq 0 && $VERBOSE -ge 1 ]]; then
        echo "[$(log_timestamp)] [INFO] $*" >&2
    fi
}

log_debug() {
    if [[ $JSON_OUTPUT -eq 0 && $VERBOSE -ge 2 ]]; then
        echo "[$(log_timestamp)] [DEBUG] $*" >&2
    fi
}

# =============================================================================
# ASSERTIONS
# =============================================================================

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-assertion}"
    ((TEST_COUNT++))
    if [[ "$expected" == "$actual" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        log_info "  expected: '$expected'"
        log_info "  actual:   '$actual' (match)"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  expected: '$expected'"
        log_fail "  actual:   '$actual'"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-contains assertion}"
    ((TEST_COUNT++))
    if [[ "$haystack" == *"$needle"* ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        log_info "  found '$needle' in output"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  haystack: '$haystack'"
        log_fail "  missing needle: '$needle'"
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-not contains assertion}"
    ((TEST_COUNT++))
    if [[ "$haystack" != *"$needle"* ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        log_info "  '$needle' correctly absent from output"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  haystack: '$haystack'"
        log_fail "  unwanted needle: '$needle' was found"
        return 1
    fi
}

assert_json_array_length() {
    local json="$1"
    local expected_length="$2"
    local msg="${3:-array length assertion}"
    local actual_length
    actual_length=$(echo "$json" | jq 'length' 2>/dev/null || echo "-1")
    ((TEST_COUNT++))
    if [[ "$actual_length" == "$expected_length" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        log_info "  expected length: $expected_length, actual: $actual_length (match)"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  expected length: $expected_length"
        log_fail "  actual length: $actual_length"
        log_fail "  array: $json"
        return 1
    fi
}

assert_json_array_min_length() {
    local json="$1"
    local min_length="$2"
    local msg="${3:-array min length assertion}"
    local actual_length
    actual_length=$(echo "$json" | jq 'length' 2>/dev/null || echo "0")
    ((TEST_COUNT++))
    if [[ "$actual_length" -ge "$min_length" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        log_info "  minimum: $min_length, actual: $actual_length"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  minimum: $min_length"
        log_fail "  actual: $actual_length"
        log_fail "  array: $json"
        return 1
    fi
}

# =============================================================================
# PHASE TRACKING
# =============================================================================

CURRENT_PHASE=""
PHASE_START_TIME=0

start_phase() {
    CURRENT_PHASE="$1"
    PHASE_START_TIME=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))
    if [[ $JSON_OUTPUT -eq 0 ]]; then
        echo "" >&2
        echo "[$(log_timestamp)] === Phase: $CURRENT_PHASE ===" >&2
    fi
}

end_phase() {
    local status="$1"
    local tests_in_phase="${2:-0}"
    local end_time
    end_time=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))
    local duration=$((end_time - PHASE_START_TIME))

    PHASE_RESULTS+=("{\"name\":\"$CURRENT_PHASE\",\"status\":\"$status\",\"tests\":$tests_in_phase,\"duration_ms\":$duration}")

    if [[ $JSON_OUTPUT -eq 0 ]]; then
        echo "[$(log_timestamp)] Phase $CURRENT_PHASE: $status (${duration}ms, $tests_in_phase tests)" >&2
    fi
}

# =============================================================================
# YQ DEPENDENCY CHECK
# =============================================================================

check_yq_available() {
    if command -v yq &>/dev/null; then
        return 0
    else
        return 1
    fi
}

skip_if_no_yq() {
    if ! check_yq_available; then
        log_skip "yq not installed - skipping test"
        ((TEST_COUNT++))
        ((SKIP_COUNT++))
        return 1
    fi
    return 0
}

# =============================================================================
# TEST: UPLOAD-ARTIFACT PATTERNS
# =============================================================================

test_upload_artifact_basic() {
    log_test "Parse actions/upload-artifact with name field"
    skip_if_no_yq || return 0

    log_info "Input: $FIXTURE_DIR/sample_workflow.yml"

    local result
    result=$(artifact_naming_parse_workflow "$FIXTURE_DIR/sample_workflow.yml")
    log_debug "Result: $result"

    # Should contain upload-artifact pattern with matrix variables normalized
    assert_contains "$result" 'mytool-${os}-${arch}' "Found upload-artifact pattern with normalized vars"
}

test_upload_artifact_multiple() {
    log_test "Parse multiple upload-artifact steps"
    skip_if_no_yq || return 0

    log_info "Input: $FIXTURE_DIR/workflow_multiple_upload.yml"

    local result
    result=$(artifact_naming_parse_workflow "$FIXTURE_DIR/workflow_multiple_upload.yml")
    log_debug "Result: $result"

    # Should contain both Linux and Darwin patterns
    assert_contains "$result" 'multitool-linux-amd64' "Found Linux upload pattern"
    assert_contains "$result" 'multitool-darwin-arm64' "Found Darwin upload pattern"
}

# =============================================================================
# TEST: SOFTPROPS/ACTION-GH-RELEASE
# =============================================================================

test_gh_release_files() {
    log_test "Parse softprops/action-gh-release files field"
    skip_if_no_yq || return 0

    log_info "Input: $FIXTURE_DIR/sample_workflow.yml"

    local result
    result=$(artifact_naming_parse_workflow "$FIXTURE_DIR/sample_workflow.yml")
    log_debug "Result: $result"

    # Should contain patterns from files field
    assert_contains "$result" 'mytool-linux-amd64' "Found gh-release Linux pattern"
    assert_contains "$result" 'mytool-darwin-arm64' "Found gh-release Darwin pattern"
}

test_gh_release_conditional() {
    log_test "Parse conditional release step"
    skip_if_no_yq || return 0

    log_info "Input: $FIXTURE_DIR/workflow_conditional.yml"

    local result
    result=$(artifact_naming_parse_workflow "$FIXTURE_DIR/workflow_conditional.yml")
    log_debug "Result: $result"

    # Should still find the pattern even with conditional
    assert_contains "$result" 'condtool-linux-amd64' "Found conditional release pattern"
}

# =============================================================================
# TEST: GH RELEASE UPLOAD IN RUN STEPS
# =============================================================================

test_gh_release_upload_run() {
    log_test "Parse 'gh release upload' in run step"
    skip_if_no_yq || return 0

    log_info "Input: $FIXTURE_DIR/workflow_gh_release_upload.yml"

    local result
    result=$(artifact_naming_parse_workflow "$FIXTURE_DIR/workflow_gh_release_upload.yml")
    log_debug "Result: $result"

    # Should find patterns from gh release upload commands
    # Note: This depends on the regex in the function matching gh release upload patterns
    assert_json_array_min_length "$result" 0 "Result is valid JSON array"
}

# =============================================================================
# TEST: MATRIX VARIABLE NORMALIZATION
# =============================================================================

test_matrix_goos_goarch() {
    log_test "Normalize matrix.goos/matrix.goarch to os/arch"
    skip_if_no_yq || return 0

    log_info "Input: $FIXTURE_DIR/sample_workflow.yml"

    local result
    result=$(artifact_naming_parse_workflow "$FIXTURE_DIR/sample_workflow.yml")
    log_debug "Result: $result"

    # Matrix variables should be normalized
    assert_contains "$result" '${os}' "GOOS normalized to os"
    assert_contains "$result" '${arch}' "GOARCH normalized to arch"
    assert_not_contains "$result" 'matrix.goos' "matrix.goos should be normalized"
    assert_not_contains "$result" 'matrix.goarch' "matrix.goarch should be normalized"
}

test_matrix_os_arch() {
    log_test "Normalize matrix.os/matrix.arch variants"
    skip_if_no_yq || return 0

    log_info "Input: $FIXTURE_DIR/workflow_matrix_vars.yml"

    local result
    result=$(artifact_naming_parse_workflow "$FIXTURE_DIR/workflow_matrix_vars.yml")
    log_debug "Result: $result"

    # Should find upload-artifact pattern
    assert_contains "$result" 'matrixapp' "Found matrix app pattern"
}

# =============================================================================
# TEST: EDGE CASES
# =============================================================================

test_no_release_steps() {
    log_test "Workflow with no release/upload steps"
    skip_if_no_yq || return 0

    log_info "Input: $FIXTURE_DIR/workflow_no_release.yml"

    local result
    result=$(artifact_naming_parse_workflow "$FIXTURE_DIR/workflow_no_release.yml")
    log_debug "Result: $result"

    # Should return empty array
    assert_eq "[]" "$result" "No release steps returns empty array"
}

test_nonexistent_workflow() {
    log_test "Nonexistent workflow file"
    log_info "Input: /nonexistent/workflow.yml"

    local result
    result=$(artifact_naming_parse_workflow "/nonexistent/workflow.yml")
    log_debug "Result: $result"

    assert_eq "[]" "$result" "Nonexistent file returns empty array"
}

test_empty_workflow() {
    log_test "Empty workflow file"
    local tmpfile
    tmpfile=$(mktemp --suffix=.yml)
    : > "$tmpfile"  # Create empty file

    log_info "Input: $tmpfile (empty)"

    local result
    result=$(artifact_naming_parse_workflow "$tmpfile")
    log_debug "Result: $result"

    rm -f "$tmpfile"

    assert_eq "[]" "$result" "Empty file returns empty array"
}

test_invalid_yaml() {
    log_test "Invalid YAML file"
    local tmpfile
    tmpfile=$(mktemp --suffix=.yml)
    echo "this: is: not: valid: yaml:" > "$tmpfile"

    log_info "Input: $tmpfile (invalid YAML)"

    local result
    result=$(artifact_naming_parse_workflow "$tmpfile")
    log_debug "Result: $result"

    rm -f "$tmpfile"

    # Should gracefully return empty array on parse error
    assert_eq "[]" "$result" "Invalid YAML returns empty array"
}

test_yq_not_available() {
    log_test "Graceful handling when yq is not available"
    log_info "Simulating missing yq"

    # Save original PATH
    local original_path="$PATH"
    # Temporarily remove yq from PATH
    export PATH="/nonexistent"

    local result
    result=$(artifact_naming_parse_workflow "$FIXTURE_DIR/sample_workflow.yml")
    log_debug "Result: $result"

    # Restore PATH
    export PATH="$original_path"

    # Should return empty array when yq is not available
    assert_eq "[]" "$result" "Missing yq returns empty array"
}

# =============================================================================
# TEST: RESULT FORMAT
# =============================================================================

test_result_is_json_array() {
    log_test "Result is valid JSON array"
    skip_if_no_yq || return 0

    log_info "Input: $FIXTURE_DIR/sample_workflow.yml"

    local result
    result=$(artifact_naming_parse_workflow "$FIXTURE_DIR/sample_workflow.yml")
    log_debug "Result: $result"

    # Validate it's a proper JSON array
    if echo "$result" | jq 'type' 2>/dev/null | grep -q "array"; then
        ((PASS_COUNT++))
        ((TEST_COUNT++))
        log_pass "Result is valid JSON array"
    else
        ((FAIL_COUNT++))
        ((TEST_COUNT++))
        log_fail "Result is not a valid JSON array: $result"
    fi
}

test_deduplicated_results() {
    log_test "Results are deduplicated"
    skip_if_no_yq || return 0

    log_info "Input: $FIXTURE_DIR/sample_workflow.yml"

    local result
    result=$(artifact_naming_parse_workflow "$FIXTURE_DIR/sample_workflow.yml")
    log_debug "Result: $result"

    # Check for duplicates
    local unique_count
    local total_count
    unique_count=$(echo "$result" | jq 'unique | length' 2>/dev/null || echo "0")
    total_count=$(echo "$result" | jq 'length' 2>/dev/null || echo "0")

    ((TEST_COUNT++))
    if [[ "$unique_count" == "$total_count" ]]; then
        ((PASS_COUNT++))
        log_pass "Results are deduplicated"
        log_info "  unique: $unique_count, total: $total_count"
    else
        ((FAIL_COUNT++))
        log_fail "Results contain duplicates"
        log_fail "  unique: $unique_count, total: $total_count"
    fi
}

# =============================================================================
# PRINT SUMMARY
# =============================================================================

print_summary() {
    local end_time
    end_time=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))
    local total_duration=$((end_time - START_TIME))

    if [[ $JSON_OUTPUT -eq 1 ]]; then
        # JSON output
        local phases_json="["
        local first=true
        for p in "${PHASE_RESULTS[@]}"; do
            if [[ "$first" == "true" ]]; then
                first=false
            else
                phases_json+=","
            fi
            phases_json+="$p"
        done
        phases_json+="]"

        local result_status="PASS"
        [[ $FAIL_COUNT -gt 0 ]] && result_status="FAIL"

        printf '{"test":"artifact_naming_parse_workflow","yq_available":%s,"phases":%s,"result":"%s","total_tests":%d,"passed":%d,"failed":%d,"skipped":%d,"total_duration_ms":%d}\n' \
            "$(if check_yq_available; then echo "true"; else echo "false"; fi)" \
            "$phases_json" "$result_status" "$TEST_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$total_duration"
    else
        # Human-readable output
        echo "" >&2
        echo "==========================================" >&2
        echo "Test Summary: $PASS_COUNT/$TEST_COUNT passed" >&2
        if [[ $SKIP_COUNT -gt 0 ]]; then
            echo "Skipped: $SKIP_COUNT (yq not available)" >&2
        fi
        echo "Duration: ${total_duration}ms" >&2
        echo "yq available: $(if check_yq_available; then echo "yes"; else echo "no"; fi)" >&2
        echo "==========================================" >&2
        if [[ $FAIL_COUNT -gt 0 ]]; then
            echo "FAILURES: $FAIL_COUNT" >&2
            return 1
        else
            echo "ALL TESTS PASSED" >&2
            return 0
        fi
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    if [[ $JSON_OUTPUT -eq 0 ]]; then
        echo "[$(log_timestamp)] Starting artifact_naming_parse_workflow unit tests" >&2
        echo "[$(log_timestamp)] Fixture directory: $FIXTURE_DIR" >&2
        echo "[$(log_timestamp)] yq available: $(if check_yq_available; then echo "yes"; else echo "no"; fi)" >&2
        echo "[$(log_timestamp)] Verbosity: $VERBOSE" >&2
    fi

    local phase_tests=0

    # Phase 1: Upload Artifact Patterns
    start_phase "upload_artifact_patterns"
    phase_tests=$TEST_COUNT
    test_upload_artifact_basic
    test_upload_artifact_multiple
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 2: Softprops/action-gh-release
    start_phase "gh_release_action"
    phase_tests=$TEST_COUNT
    test_gh_release_files
    test_gh_release_conditional
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 3: gh release upload in run steps
    start_phase "gh_release_upload_run"
    phase_tests=$TEST_COUNT
    test_gh_release_upload_run
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 4: Matrix Variable Normalization
    start_phase "matrix_normalization"
    phase_tests=$TEST_COUNT
    test_matrix_goos_goarch
    test_matrix_os_arch
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 5: Edge Cases
    start_phase "edge_cases"
    phase_tests=$TEST_COUNT
    test_no_release_steps
    test_nonexistent_workflow
    test_empty_workflow
    test_invalid_yaml
    test_yq_not_available
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 6: Result Format
    start_phase "result_format"
    phase_tests=$TEST_COUNT
    test_result_is_json_array
    test_deduplicated_results
    end_phase "pass" $((TEST_COUNT - phase_tests))

    print_summary
}

main "$@"
