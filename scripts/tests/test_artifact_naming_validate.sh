#!/usr/bin/env bash
# test_artifact_naming_validate.sh - Unit tests for artifact_naming_validate()
#
# Usage: ./scripts/tests/test_artifact_naming_validate.sh [-v] [-vv] [--json]
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
# shellcheck disable=SC2016 # Tests use literal ${var} patterns that should not expand

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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
source "$PROJECT_ROOT/src/artifact_naming.sh"

# Test counters
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0
START_TIME=$(($(date +%s) * 1000))

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

assert_json_field() {
    local json="$1"
    local field="$2"
    local expected="$3"
    local msg="${4:-JSON field assertion}"
    local actual
    actual=$(echo "$json" | jq -r ".$field" 2>/dev/null || echo "")
    ((TEST_COUNT++))
    if [[ "$expected" == "$actual" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        log_info "  $field: '$actual'"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  field: $field"
        log_fail "  expected: '$expected'"
        log_fail "  actual:   '$actual'"
        return 1
    fi
}

assert_json_contains() {
    local json="$1"
    local field="$2"
    local needle="$3"
    local msg="${4:-JSON contains assertion}"
    local value
    value=$(echo "$json" | jq -r ".$field" 2>/dev/null || echo "")
    ((TEST_COUNT++))
    if [[ "$value" == *"$needle"* ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        log_info "  found '$needle' in .$field"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  field: $field"
        log_fail "  value: '$value'"
        log_fail "  missing: '$needle'"
        return 1
    fi
}

assert_json_array_length() {
    local json="$1"
    local field="$2"
    local expected_length="$3"
    local msg="${4:-array length assertion}"
    local actual_length
    actual_length=$(echo "$json" | jq ".$field | length" 2>/dev/null || echo "-1")
    ((TEST_COUNT++))
    if [[ "$actual_length" == "$expected_length" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        log_info "  $field length: $actual_length"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  field: $field"
        log_fail "  expected length: $expected_length"
        log_fail "  actual length: $actual_length"
        return 1
    fi
}

assert_valid_json() {
    local json="$1"
    local msg="${2:-valid JSON assertion}"
    ((TEST_COUNT++))
    if echo "$json" | jq . >/dev/null 2>&1; then
        ((PASS_COUNT++))
        log_pass "$msg"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  invalid JSON: $json"
        return 1
    fi
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-exit code assertion}"
    ((TEST_COUNT++))
    if [[ "$expected" == "$actual" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        log_info "  exit code: $actual"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  expected exit code: $expected"
        log_fail "  actual exit code: $actual"
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
    PHASE_START_TIME=$(($(date +%s) * 1000))
    if [[ $JSON_OUTPUT -eq 0 ]]; then
        echo "" >&2
        echo "[$(log_timestamp)] === Phase: $CURRENT_PHASE ===" >&2
    fi
}

end_phase() {
    local status="$1"
    local tests_in_phase="${2:-0}"
    local end_time
    end_time=$(($(date +%s) * 1000))
    local duration=$((end_time - PHASE_START_TIME))

    PHASE_RESULTS+=("{\"name\":\"$CURRENT_PHASE\",\"status\":\"$status\",\"tests\":$tests_in_phase,\"duration_ms\":$duration}")

    if [[ $JSON_OUTPUT -eq 0 ]]; then
        echo "[$(log_timestamp)] Phase $CURRENT_PHASE: $status (${duration}ms, $tests_in_phase tests)" >&2
    fi
}

# =============================================================================
# TEST: CONSISTENT NAMING PASSES
# =============================================================================

test_consistent_naming_ok() {
    log_test "Consistent naming: all sources match"
    log_info "Input: config and install both use '\${name}-\${os}-\${arch}'"

    local result exit_code
    result=$(artifact_naming_validate "mytool" '${name}-${os}-${arch}' '${name}-${os}-${arch}' '[]')
    exit_code=$?
    log_debug "Result: $result"
    log_debug "Exit code: $exit_code"

    assert_valid_json "$result" "Output is valid JSON"
    assert_json_field "$result" "status" "ok" "Status is ok"
    assert_json_field "$result" "tool" "mytool" "Tool name preserved"
    assert_exit_code 0 $exit_code "Exit code is 0 for consistent naming"
}

test_consistent_with_version() {
    log_test "Consistent naming: both include version"
    log_info "Input: config and install both include '\${version}'"

    local result exit_code
    result=$(artifact_naming_validate "mytool" '${name}-${version}-${os}-${arch}' '${name}-${version}-${os}-${arch}' '[]')
    exit_code=$?
    log_debug "Result: $result"

    assert_json_field "$result" "status" "ok" "Status is ok when both have version"
    assert_exit_code 0 $exit_code "Exit code is 0"
}

# =============================================================================
# TEST: VERSION MISMATCH DETECTION
# =============================================================================

test_version_mismatch_config_has_install_not() {
    log_test "Version mismatch: config has version, install doesn't"
    log_info "Input: config='\${name}-\${version}-\${os}-\${arch}', install='\${name}-\${os}-\${arch}'"

    local result exit_code
    result=$(artifact_naming_validate "mytool" '${name}-${version}-${os}-${arch}' '${name}-${os}-${arch}' '[]')
    exit_code=$?
    log_debug "Result: $result"

    assert_json_field "$result" "status" "warning" "Status is warning for version mismatch"
    assert_json_contains "$result" "mismatches" "version" "Mismatch mentions version"
    assert_exit_code 1 $exit_code "Exit code is 1 for mismatch"
}

test_version_mismatch_install_has_config_not() {
    log_test "Version mismatch: install has version, config doesn't"
    log_info "Input: config='\${name}-\${os}-\${arch}', install='\${name}-\${version}-\${os}-\${arch}'"

    local result exit_code
    # Note: Current implementation only checks config_has_version && !install_has_version
    # This test documents current behavior
    result=$(artifact_naming_validate "mytool" '${name}-${os}-${arch}' '${name}-${version}-${os}-${arch}' '[]')
    exit_code=$?
    log_debug "Result: $result"

    # Current behavior: this is ok (install having version is fine)
    assert_valid_json "$result" "Output is valid JSON"
}

# =============================================================================
# TEST: SEPARATOR MISMATCH DETECTION
# =============================================================================

test_separator_mismatch_hyphen_underscore() {
    log_test "Separator mismatch: hyphen vs underscore"
    log_info "Input: config uses hyphen, install uses underscore"

    local result exit_code
    result=$(artifact_naming_validate "mytool" '${name}-${os}-${arch}' '${name}_${os}_${arch}' '[]')
    exit_code=$?
    log_debug "Result: $result"

    assert_json_field "$result" "status" "warning" "Status is warning for separator mismatch"
    assert_json_contains "$result" "mismatches" "separator" "Mismatch mentions separator"
}

test_separator_consistent_hyphen() {
    log_test "Separator consistent: both use hyphen"
    log_info "Input: both patterns use hyphen separator"

    local result exit_code
    result=$(artifact_naming_validate "mytool" '${name}-${os}-${arch}' '${name}-${os}-${arch}' '[]')
    exit_code=$?
    log_debug "Result: $result"

    assert_json_field "$result" "status" "ok" "Status is ok for consistent separators"
}

# =============================================================================
# TEST: MISSING SOURCES HANDLING
# =============================================================================

test_missing_install_pattern() {
    log_test "Missing install pattern: empty string"
    log_info "Input: install_pattern is empty"

    local result exit_code
    result=$(artifact_naming_validate "mytool" '${name}-${os}-${arch}' "" '[]')
    exit_code=$?
    log_debug "Result: $result"

    assert_valid_json "$result" "Output is valid JSON"
    # Missing install pattern should not cause errors
    assert_json_field "$result" "tool" "mytool" "Tool name preserved"
}

test_missing_config_pattern() {
    log_test "Missing config pattern: empty string"
    log_info "Input: config_pattern is empty"

    local result exit_code
    result=$(artifact_naming_validate "mytool" "" '${name}-${os}-${arch}' '[]')
    exit_code=$?
    log_debug "Result: $result"

    assert_valid_json "$result" "Output is valid JSON"
    assert_json_field "$result" "tool" "mytool" "Tool name preserved"
}

test_both_patterns_missing() {
    log_test "Both patterns missing: empty strings"
    log_info "Input: both config and install are empty"

    local result exit_code
    result=$(artifact_naming_validate "mytool" "" "" '[]')
    exit_code=$?
    log_debug "Result: $result"

    assert_valid_json "$result" "Output is valid JSON"
    # Should be ok since there's nothing to compare
    assert_json_field "$result" "status" "ok" "Status is ok when nothing to compare"
}

# =============================================================================
# TEST: WORKFLOW PATTERNS INTEGRATION
# =============================================================================

test_with_workflow_patterns() {
    log_test "Workflow patterns: included in sources"
    log_info "Input: workflow_json includes patterns"

    local result exit_code
    result=$(artifact_naming_validate "mytool" '${name}-${os}-${arch}' '${name}-${os}-${arch}' '["mytool-${os}-${arch}"]')
    exit_code=$?
    log_debug "Result: $result"

    assert_valid_json "$result" "Output is valid JSON"
    assert_json_contains "$result" "sources.workflow" "mytool" "Workflow patterns in sources"
}

test_empty_workflow_array() {
    log_test "Empty workflow array: valid input"
    log_info "Input: workflow_json is empty array"

    local result exit_code
    result=$(artifact_naming_validate "mytool" '${name}-${os}-${arch}' '${name}-${os}-${arch}' '[]')
    exit_code=$?
    log_debug "Result: $result"

    assert_valid_json "$result" "Output is valid JSON"
    assert_json_field "$result" "sources.workflow" "[]" "Workflow is empty array"
}

# =============================================================================
# TEST: RECOMMENDATIONS OUTPUT
# =============================================================================

test_recommendations_on_mismatch() {
    log_test "Recommendations: provided on mismatch"
    log_info "Input: version mismatch should trigger recommendation"

    local result exit_code
    result=$(artifact_naming_validate "mytool" '${name}-${version}-${os}-${arch}' '${name}-${os}-${arch}' '[]')
    exit_code=$?
    log_debug "Result: $result"

    # Check recommendations array is not empty
    local rec_count
    rec_count=$(echo "$result" | jq '.recommendations | length' 2>/dev/null || echo "0")
    ((TEST_COUNT++))
    if [[ "$rec_count" -gt 0 ]]; then
        ((PASS_COUNT++))
        log_pass "Recommendations provided on mismatch"
        log_info "  recommendation count: $rec_count"
    else
        ((FAIL_COUNT++))
        log_fail "Expected recommendations on mismatch"
    fi
}

test_no_recommendations_when_ok() {
    log_test "No recommendations when consistent"
    log_info "Input: consistent naming should have empty recommendations"

    local result exit_code
    result=$(artifact_naming_validate "mytool" '${name}-${os}-${arch}' '${name}-${os}-${arch}' '[]')
    exit_code=$?
    log_debug "Result: $result"

    assert_json_array_length "$result" "recommendations" 0 "No recommendations when consistent"
}

# =============================================================================
# TEST: JSON OUTPUT FORMAT
# =============================================================================

test_json_has_required_fields() {
    log_test "JSON format: has all required fields"
    log_info "Checking: tool, status, sources, mismatches, recommendations"

    local result
    result=$(artifact_naming_validate "mytool" '${name}-${os}-${arch}' '${name}-${os}-${arch}' '[]')
    log_debug "Result: $result"

    # Check each required field exists
    local tool status sources mismatches recommendations
    tool=$(echo "$result" | jq -r '.tool' 2>/dev/null)
    status=$(echo "$result" | jq -r '.status' 2>/dev/null)
    sources=$(echo "$result" | jq '.sources' 2>/dev/null)
    mismatches=$(echo "$result" | jq '.mismatches' 2>/dev/null)
    recommendations=$(echo "$result" | jq '.recommendations' 2>/dev/null)

    ((TEST_COUNT++))
    if [[ -n "$tool" && -n "$status" && "$sources" != "null" && "$mismatches" != "null" && "$recommendations" != "null" ]]; then
        ((PASS_COUNT++))
        log_pass "All required fields present"
        log_info "  tool: $tool"
        log_info "  status: $status"
    else
        ((FAIL_COUNT++))
        log_fail "Missing required fields"
        log_fail "  result: $result"
    fi
}

test_sources_has_subfields() {
    log_test "JSON sources: has config, install, workflow subfields"

    local result
    result=$(artifact_naming_validate "mytool" '${name}-${os}-${arch}' '${name}-${os}-${arch}' '["pattern1"]')
    log_debug "Result: $result"

    local config install workflow
    config=$(echo "$result" | jq -r '.sources.config' 2>/dev/null)
    install=$(echo "$result" | jq -r '.sources.install' 2>/dev/null)
    workflow=$(echo "$result" | jq '.sources.workflow' 2>/dev/null)

    ((TEST_COUNT++))
    if [[ "$config" != "null" && "$install" != "null" && "$workflow" != "null" ]]; then
        ((PASS_COUNT++))
        log_pass "Sources has all subfields"
        log_info "  config: $config"
        log_info "  install: $install"
    else
        ((FAIL_COUNT++))
        log_fail "Missing sources subfields"
    fi
}

# =============================================================================
# PRINT SUMMARY
# =============================================================================

print_summary() {
    local end_time
    end_time=$(($(date +%s) * 1000))
    local total_duration=$((end_time - START_TIME))

    if [[ $JSON_OUTPUT -eq 1 ]]; then
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

        printf '{"test":"artifact_naming_validate","phases":%s,"result":"%s","total_tests":%d,"passed":%d,"failed":%d,"total_duration_ms":%d}\n' \
            "$phases_json" "$result_status" "$TEST_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$total_duration"
    else
        echo "" >&2
        echo "==========================================" >&2
        echo "Test Summary: $PASS_COUNT/$TEST_COUNT passed" >&2
        echo "Duration: ${total_duration}ms" >&2
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
        echo "[$(log_timestamp)] Starting artifact_naming_validate unit tests" >&2
        echo "[$(log_timestamp)] Verbosity: $VERBOSE" >&2
    fi

    local phase_tests=0

    # Phase 1: Consistent Naming
    start_phase "consistent_naming"
    phase_tests=$TEST_COUNT
    test_consistent_naming_ok
    test_consistent_with_version
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 2: Version Mismatch Detection
    start_phase "version_mismatch"
    phase_tests=$TEST_COUNT
    test_version_mismatch_config_has_install_not
    test_version_mismatch_install_has_config_not
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 3: Separator Mismatch Detection
    start_phase "separator_mismatch"
    phase_tests=$TEST_COUNT
    test_separator_mismatch_hyphen_underscore
    test_separator_consistent_hyphen
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 4: Missing Sources
    start_phase "missing_sources"
    phase_tests=$TEST_COUNT
    test_missing_install_pattern
    test_missing_config_pattern
    test_both_patterns_missing
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 5: Workflow Patterns
    start_phase "workflow_patterns"
    phase_tests=$TEST_COUNT
    test_with_workflow_patterns
    test_empty_workflow_array
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 6: Recommendations
    start_phase "recommendations"
    phase_tests=$TEST_COUNT
    test_recommendations_on_mismatch
    test_no_recommendations_when_ok
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 7: JSON Format
    start_phase "json_format"
    phase_tests=$TEST_COUNT
    test_json_has_required_fields
    test_sources_has_subfields
    end_phase "pass" $((TEST_COUNT - phase_tests))

    print_summary
}

main "$@"
