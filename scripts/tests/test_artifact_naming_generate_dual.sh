#!/usr/bin/env bash
# test_artifact_naming_generate_dual.sh - Unit tests for artifact_naming_generate_dual()
#
# Usage: ./scripts/tests/test_artifact_naming_generate_dual.sh [-v] [-vv] [--json]
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

assert_json_bool() {
    local json="$1"
    local field="$2"
    local expected="$3"  # "true" or "false"
    local msg="${4:-JSON bool assertion}"
    local actual
    actual=$(echo "$json" | jq -r ".$field" 2>/dev/null || echo "")
    ((TEST_COUNT++))
    if [[ "$expected" == "$actual" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        log_info "  $field: $actual"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  field: $field"
        log_fail "  expected: $expected"
        log_fail "  actual:   $actual"
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
# TEST: BASIC DUAL NAME GENERATION
# =============================================================================

test_basic_linux_amd64() {
    log_test "Basic dual name: Linux amd64 tar.gz"
    log_info "Input: tool=mytool version=v1.2.3 os=linux arch=amd64 ext=tar.gz"

    local result
    result=$(artifact_naming_generate_dual "mytool" "v1.2.3" "linux" "amd64" "tar.gz")
    log_debug "Result: $result"

    assert_valid_json "$result" "Output is valid JSON"
    assert_json_field "$result" "versioned" "mytool-1.2.3-linux-amd64.tar.gz" "Versioned name correct"
    assert_json_field "$result" "compat" "mytool-linux-amd64.tar.gz" "Compat name correct"
    assert_json_bool "$result" "same" "false" "Names are different"
}

test_basic_darwin_arm64() {
    log_test "Basic dual name: Darwin arm64 tar.gz"
    log_info "Input: tool=myapp version=v2.0.0 os=darwin arch=arm64 ext=tar.gz"

    local result
    result=$(artifact_naming_generate_dual "myapp" "v2.0.0" "darwin" "arm64" "tar.gz")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "myapp-2.0.0-darwin-arm64.tar.gz" "Versioned name correct"
    assert_json_field "$result" "compat" "myapp-darwin-arm64.tar.gz" "Compat name correct"
}

test_basic_windows_amd64() {
    log_test "Basic dual name: Windows amd64 zip"
    log_info "Input: tool=cli version=v0.5.1 os=windows arch=amd64 ext=zip"

    local result
    result=$(artifact_naming_generate_dual "cli" "v0.5.1" "windows" "amd64" "zip")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "cli-0.5.1-windows-amd64.zip" "Versioned name correct"
    assert_json_field "$result" "compat" "cli-windows-amd64.zip" "Compat name correct"
}

# =============================================================================
# TEST: VERSION STRIPPING
# =============================================================================

test_version_with_v_prefix() {
    log_test "Version stripping: v prefix removed"
    log_info "Input: version=v1.0.0"

    local result
    result=$(artifact_naming_generate_dual "tool" "v1.0.0" "linux" "amd64" "tar.gz")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "tool-1.0.0-linux-amd64.tar.gz" "v prefix stripped from versioned"
}

test_version_without_v_prefix() {
    log_test "Version stripping: no v prefix"
    log_info "Input: version=1.2.3"

    local result
    result=$(artifact_naming_generate_dual "tool" "1.2.3" "linux" "amd64" "tar.gz")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "tool-1.2.3-linux-amd64.tar.gz" "Version used as-is"
}

test_version_semver_prerelease() {
    log_test "Version: semver with prerelease"
    log_info "Input: version=v1.0.0-beta.1"

    local result
    result=$(artifact_naming_generate_dual "tool" "v1.0.0-beta.1" "linux" "amd64" "tar.gz")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "tool-1.0.0-beta.1-linux-amd64.tar.gz" "Prerelease version preserved"
}

# =============================================================================
# TEST: EXPLICIT COMPAT PATTERNS
# =============================================================================

test_compat_pattern_basic() {
    log_test "Explicit compat pattern: basic substitution"
    log_info "Input: compat_pattern='\${name}-\${os}-\${arch}'"

    local result
    result=$(artifact_naming_generate_dual "cass" "v0.1.64" "darwin" "arm64" "tar.gz" '${name}-${os}-${arch}')
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "cass-0.1.64-darwin-arm64.tar.gz" "Versioned name"
    assert_json_field "$result" "compat" "cass-darwin-arm64.tar.gz" "Compat with pattern"
}

test_compat_pattern_custom_format() {
    log_test "Explicit compat pattern: custom format"
    log_info "Input: compat_pattern='\${name}_\${os}_\${arch}'"

    local result
    result=$(artifact_naming_generate_dual "rch" "v1.0.0" "linux" "amd64" "tar.gz" '${name}_${os}_${arch}')
    log_debug "Result: $result"

    assert_json_field "$result" "compat" "rch_linux_amd64.tar.gz" "Compat with underscore pattern"
}

test_compat_pattern_with_version() {
    log_test "Explicit compat pattern: includes version"
    log_info "Input: compat_pattern='\${name}-v\${version}-\${os}-\${arch}'"

    # When compat pattern matches versioned format, same should be true
    local result
    result=$(artifact_naming_generate_dual "tool" "v1.0.0" "linux" "amd64" "tar.gz" '${name}-1.0.0-${os}-${arch}')
    log_debug "Result: $result"

    # Both should have same filename
    assert_json_bool "$result" "same" "true" "Names are same when pattern matches"
}

# =============================================================================
# TEST: SAME NAME DETECTION
# =============================================================================

test_same_detection_true() {
    log_test "Same name detection: true when names match"
    log_info "Providing compat pattern that matches versioned format"

    local result
    result=$(artifact_naming_generate_dual "tool" "v1.0.0" "linux" "amd64" "tar.gz" '${name}-1.0.0-${os}-${arch}')
    log_debug "Result: $result"

    assert_json_bool "$result" "same" "true" "Same is true when names identical"
}

test_same_detection_false() {
    log_test "Same name detection: false when names differ"
    log_info "Default behavior: versioned has version, compat doesn't"

    local result
    result=$(artifact_naming_generate_dual "tool" "v1.0.0" "linux" "amd64" "tar.gz")
    log_debug "Result: $result"

    assert_json_bool "$result" "same" "false" "Same is false when names differ"
}

# =============================================================================
# TEST: EXTENSION HANDLING
# =============================================================================

test_extension_tar_gz() {
    log_test "Extension: tar.gz"

    local result
    result=$(artifact_naming_generate_dual "tool" "v1.0.0" "linux" "amd64" "tar.gz")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "tool-1.0.0-linux-amd64.tar.gz" "tar.gz extension"
}

test_extension_zip() {
    log_test "Extension: zip"

    local result
    result=$(artifact_naming_generate_dual "tool" "v1.0.0" "windows" "amd64" "zip")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "tool-1.0.0-windows-amd64.zip" "zip extension"
}

test_extension_tgz() {
    log_test "Extension: tgz"

    local result
    result=$(artifact_naming_generate_dual "tool" "v1.0.0" "linux" "amd64" "tgz")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "tool-1.0.0-linux-amd64.tgz" "tgz extension"
}

test_extension_default() {
    log_test "Extension: default (tar.gz when not specified)"

    local result
    # Only pass 4 args - ext should default to tar.gz
    result=$(artifact_naming_generate_dual "tool" "v1.0.0" "linux" "amd64")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "tool-1.0.0-linux-amd64.tar.gz" "Default tar.gz extension"
}

# =============================================================================
# TEST: PLATFORM COMBINATIONS
# =============================================================================

test_platform_linux_arm64() {
    log_test "Platform: linux/arm64"

    local result
    result=$(artifact_naming_generate_dual "app" "v2.0.0" "linux" "arm64" "tar.gz")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "app-2.0.0-linux-arm64.tar.gz" "Linux ARM64"
}

test_platform_darwin_amd64() {
    log_test "Platform: darwin/amd64 (Intel Mac)"

    local result
    result=$(artifact_naming_generate_dual "app" "v2.0.0" "darwin" "amd64" "tar.gz")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "app-2.0.0-darwin-amd64.tar.gz" "Darwin AMD64"
}

test_platform_windows_arm64() {
    log_test "Platform: windows/arm64"

    local result
    result=$(artifact_naming_generate_dual "app" "v2.0.0" "windows" "arm64" "zip")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "app-2.0.0-windows-arm64.zip" "Windows ARM64"
}

test_platform_windows_arm64_target_triple() {
    log_test "Platform: windows/arm64 target triple"

    local result
    result=$(artifact_naming_substitute '${name}-${target_triple}.${ext}' \
        "app" "v2.0.0" "windows" "arm64" "exe" "missing-tool")
    log_debug "Result: $result"

    ((TEST_COUNT++))
    if [[ "$result" == "app-aarch64-pc-windows-msvc.exe" ]]; then
        ((PASS_COUNT++))
        log_pass "Windows ARM64 target triple"
    else
        ((FAIL_COUNT++))
        log_fail "Expected app-aarch64-pc-windows-msvc.exe, got: $result"
    fi
}

# =============================================================================
# TEST: EDGE CASES
# =============================================================================

test_tool_name_with_hyphen() {
    log_test "Edge case: tool name with hyphen"
    log_info "Input: tool=my-cli"

    local result
    result=$(artifact_naming_generate_dual "my-cli" "v1.0.0" "linux" "amd64" "tar.gz")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "my-cli-1.0.0-linux-amd64.tar.gz" "Hyphenated tool name"
}

test_tool_name_with_underscore() {
    log_test "Edge case: tool name with underscore"
    log_info "Input: tool=my_tool"

    local result
    result=$(artifact_naming_generate_dual "my_tool" "v1.0.0" "linux" "amd64" "tar.gz")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "my_tool-1.0.0-linux-amd64.tar.gz" "Underscored tool name"
}

test_version_major_only() {
    log_test "Edge case: major version only"
    log_info "Input: version=v1"

    local result
    result=$(artifact_naming_generate_dual "tool" "v1" "linux" "amd64" "tar.gz")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "tool-1-linux-amd64.tar.gz" "Major-only version"
}

test_long_tool_name() {
    log_test "Edge case: long tool name"
    log_info "Input: tool=super-long-tool-name-that-is-very-descriptive"

    local result
    result=$(artifact_naming_generate_dual "super-long-tool-name-that-is-very-descriptive" "v1.0.0" "linux" "amd64" "tar.gz")
    log_debug "Result: $result"

    assert_json_field "$result" "versioned" "super-long-tool-name-that-is-very-descriptive-1.0.0-linux-amd64.tar.gz" "Long tool name"
}

# =============================================================================
# TEST: JSON OUTPUT FORMAT
# =============================================================================

test_json_format_has_all_fields() {
    log_test "JSON format: has versioned, compat, same fields"

    local result
    result=$(artifact_naming_generate_dual "tool" "v1.0.0" "linux" "amd64" "tar.gz")
    log_debug "Result: $result"

    local versioned compat same
    versioned=$(echo "$result" | jq -r '.versioned' 2>/dev/null)
    compat=$(echo "$result" | jq -r '.compat' 2>/dev/null)
    same=$(echo "$result" | jq -r '.same' 2>/dev/null)

    ((TEST_COUNT++))
    if [[ -n "$versioned" && -n "$compat" && ("$same" == "true" || "$same" == "false") ]]; then
        ((PASS_COUNT++))
        log_pass "All required fields present"
        log_info "  versioned: $versioned"
        log_info "  compat: $compat"
        log_info "  same: $same"
    else
        ((FAIL_COUNT++))
        log_fail "Missing required fields in JSON output"
        log_fail "  result: $result"
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

        printf '{"test":"artifact_naming_generate_dual","phases":%s,"result":"%s","total_tests":%d,"passed":%d,"failed":%d,"total_duration_ms":%d}\n' \
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
        echo "[$(log_timestamp)] Starting artifact_naming_generate_dual unit tests" >&2
        echo "[$(log_timestamp)] Verbosity: $VERBOSE" >&2
    fi

    local phase_tests=0

    # Phase 1: Basic Dual Name Generation
    start_phase "basic_generation"
    phase_tests=$TEST_COUNT
    test_basic_linux_amd64
    test_basic_darwin_arm64
    test_basic_windows_amd64
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 2: Version Stripping
    start_phase "version_stripping"
    phase_tests=$TEST_COUNT
    test_version_with_v_prefix
    test_version_without_v_prefix
    test_version_semver_prerelease
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 3: Explicit Compat Patterns
    start_phase "compat_patterns"
    phase_tests=$TEST_COUNT
    test_compat_pattern_basic
    test_compat_pattern_custom_format
    test_compat_pattern_with_version
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 4: Same Name Detection
    start_phase "same_detection"
    phase_tests=$TEST_COUNT
    test_same_detection_true
    test_same_detection_false
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 5: Extension Handling
    start_phase "extension_handling"
    phase_tests=$TEST_COUNT
    test_extension_tar_gz
    test_extension_zip
    test_extension_tgz
    test_extension_default
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 6: Platform Combinations
    start_phase "platform_combinations"
    phase_tests=$TEST_COUNT
    test_platform_linux_arm64
    test_platform_darwin_amd64
    test_platform_windows_arm64
    test_platform_windows_arm64_target_triple
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 7: Edge Cases
    start_phase "edge_cases"
    phase_tests=$TEST_COUNT
    test_tool_name_with_hyphen
    test_tool_name_with_underscore
    test_version_major_only
    test_long_tool_name
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 8: JSON Output Format
    start_phase "json_format"
    phase_tests=$TEST_COUNT
    test_json_format_has_all_fields
    end_phase "pass" $((TEST_COUNT - phase_tests))

    print_summary
}

main "$@"
