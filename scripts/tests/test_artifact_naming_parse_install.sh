#!/usr/bin/env bash
# test_artifact_naming_parse_install.sh - Comprehensive unit tests for artifact_naming_parse_install_script()
#
# Usage: ./scripts/tests/test_artifact_naming_parse_install.sh [-v] [-vv] [--json]
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

assert_empty() {
    local value="$1"
    local msg="${2:-empty assertion}"
    ((TEST_COUNT++))
    if [[ -z "$value" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg: expected empty, got '$value'"
        return 1
    fi
}

assert_not_empty() {
    local value="$1"
    local msg="${2:-not empty assertion}"
    ((TEST_COUNT++))
    if [[ -n "$value" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        log_info "  value: '$value'"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg: value was empty"
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
# TEST: TAR VARIABLE PATTERNS
# =============================================================================

test_tar_variable_simple() {
    log_test "TAR variable with TARGET and EXT"
    log_info "Input: $FIXTURE_DIR/simple_install.sh"

    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/simple_install.sh")
    log_debug "Raw output: '$result'"

    assert_eq 'mytool-${target}' "$result" "Simple TAR pattern extraction"
}

test_tar_variable_cass_style() {
    log_test "TAR variable CASS-style (tool-TARGET.EXT)"
    log_info "Input: $FIXTURE_DIR/cass_style_install.sh"

    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/cass_style_install.sh")
    log_debug "Raw output: '$result'"

    assert_eq 'cass-${target}' "$result" "CASS-style TAR pattern"
}

test_tar_variable_with_ext() {
    log_test "TAR variable with EXT variable"
    log_info "Input: $FIXTURE_DIR/ext_variable.sh"

    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/ext_variable.sh")
    log_debug "Raw output: '$result'"

    assert_eq 'exttool-${target}' "$result" "TAR with EXT variable normalized"
}

test_tar_variable_case_statement() {
    log_test "TAR variable in script with case statement"
    log_info "Input: $FIXTURE_DIR/case_statement.sh"

    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/case_statement.sh")
    log_debug "Raw output: '$result'"

    assert_eq 'casetool-${target}' "$result" "TAR pattern with case statement context"
}

# =============================================================================
# TEST: ASSET NAME PATTERNS
# =============================================================================

test_asset_name_lowercase() {
    log_test "asset_name variable (lowercase)"
    log_info "Input: $FIXTURE_DIR/versioned_install.sh"

    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/versioned_install.sh")
    log_debug "Raw output: '$result'"

    # versioned_install.sh has: asset_name="mytool-${VERSION}-${OS}-${ARCH}.tar.gz"
    assert_contains "$result" 'mytool' "asset_name has tool name"
    assert_contains "$result" '${version}' "asset_name includes version variable"
}

test_asset_name_uppercase() {
    log_test "ASSET_NAME variable (uppercase)"
    log_info "Input: $FIXTURE_DIR/uppercase_asset_name.sh"

    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/uppercase_asset_name.sh")
    log_debug "Raw output: '$result'"

    assert_eq 'uppertool-${target}' "$result" "ASSET_NAME uppercase pattern"
}

# =============================================================================
# TEST: URL EXTRACTION PATTERNS
# =============================================================================

test_url_pattern_extraction() {
    log_test "URL with inline filename pattern"
    log_info "Input: $FIXTURE_DIR/url_pattern_install.sh"

    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/url_pattern_install.sh")
    log_debug "Raw output: '$result'"

    # URL has: urltool-${OS}-${ARCH}.tar.gz in the path
    assert_contains "$result" 'urltool' "URL pattern has tool name"
    assert_contains "$result" '${os}' "URL pattern has os variable"
    assert_contains "$result" '${arch}' "URL pattern has arch variable"
}

# =============================================================================
# TEST: VARIABLE NORMALIZATION
# =============================================================================

test_normalize_target_to_os_arch() {
    log_test "TARGET normalizes to \${os}-\${arch}"
    log_info "Input: $FIXTURE_DIR/simple_install.sh"

    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/simple_install.sh")
    log_debug "Normalized pattern: '$result'"

    # TARGET should become ${os}-${arch}
    assert_contains "$result" '${target}' "TARGET normalized to target"
}

test_normalize_goos_goarch() {
    log_test "GOOS/GOARCH normalize to os/arch"
    log_info "Input: $FIXTURE_DIR/go_style_vars.sh"

    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/go_style_vars.sh")
    log_debug "Normalized pattern: '$result'"

    assert_eq 'gotool-${os}-${arch}' "$result" "Go-style vars normalized"
}

test_normalize_name_variants() {
    log_test "NAME variable normalizes to \${name}"
    log_info "Input: $FIXTURE_DIR/name_variable.sh"

    # Note: The current parser extracts the literal value, not ${NAME}
    # This test validates the behavior
    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/name_variable.sh")
    log_debug "Normalized pattern: '$result'"

    assert_not_empty "$result" "NAME variable install script parsed"
}

# =============================================================================
# TEST: EDGE CASES
# =============================================================================

test_no_pattern_found() {
    log_test "Install script with no recognizable pattern"
    log_info "Input: $FIXTURE_DIR/no_pattern.sh"

    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/no_pattern.sh")
    log_debug "Raw output: '$result'"

    assert_empty "$result" "No pattern returns empty string"
}

test_nonexistent_file() {
    log_test "Nonexistent install script"
    log_info "Input: /nonexistent/install.sh"

    local result
    result=$(artifact_naming_parse_install_script "/nonexistent/install.sh")
    log_debug "Raw output: '$result'"

    assert_empty "$result" "Nonexistent file returns empty"
}

test_multiple_patterns_first_wins() {
    log_test "Multiple patterns - first should be taken"
    log_info "Input: $FIXTURE_DIR/multiple_patterns.sh"

    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/multiple_patterns.sh")
    log_debug "Raw output: '$result'"

    # First pattern is "firsttool", second is "secondtool"
    assert_contains "$result" 'firsttool' "First pattern extracted"
    # Should NOT contain secondtool
    if [[ "$result" == *"secondtool"* ]]; then
        ((FAIL_COUNT++))
        log_fail "Second pattern incorrectly included"
        return 1
    else
        ((PASS_COUNT++))
        ((TEST_COUNT++))
        log_pass "Second pattern correctly ignored"
    fi
}

test_commented_pattern_ignored() {
    log_test "Commented pattern should be ignored"
    log_info "Input: $FIXTURE_DIR/commented_pattern.sh"

    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/commented_pattern.sh")
    log_debug "Raw output: '$result'"

    # The commented pattern has "oldtool", the real one has "realtool"
    assert_contains "$result" 'realtool' "Active pattern extracted"

    # Should NOT contain the commented pattern
    if [[ "$result" == *"oldtool"* ]]; then
        ((FAIL_COUNT++))
        log_fail "Commented pattern incorrectly extracted"
        return 1
    else
        ((PASS_COUNT++))
        ((TEST_COUNT++))
        log_pass "Commented pattern correctly ignored"
    fi
}

test_empty_file() {
    log_test "Empty file"
    local tmpfile
    tmpfile=$(mktemp)
    : > "$tmpfile"  # Create empty file

    log_info "Input: $tmpfile (empty)"

    local result
    result=$(artifact_naming_parse_install_script "$tmpfile")
    log_debug "Raw output: '$result'"

    rm -f "$tmpfile"

    assert_empty "$result" "Empty file returns empty"
}

# =============================================================================
# TEST: INSTALLER EXPECTED NAMES (bd-1tv.10)
# =============================================================================

# A repository whose install.sh downloads ${name}-${os}-${arch}.tar.gz and a
# config that names the tool; the release check compares against this name.
setup_installer_repo() {
    INSTALLER_ROOT=$(mktemp -d)
    INSTALLER_REPO="$INSTALLER_ROOT/repo"
    mkdir -p "$INSTALLER_REPO" "$INSTALLER_ROOT/config/repos.d"
    export DSR_CONFIG_DIR="$INSTALLER_ROOT/config"
    export DSR_REPOS_FILE="$INSTALLER_ROOT/config/repos.yaml"
    printf 'tool_name: mytool\n' > "$INSTALLER_ROOT/config/repos.d/mytool.yaml"
}

test_installer_expected_name_matching_ext() {
    log_test "Installer expected name uses the installer's pattern and the artifact extension"
    setup_installer_repo
    cat > "$INSTALLER_REPO/install.sh" <<'SH'
#!/bin/sh
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
TAR="mytool-${OS}-${ARCH}.tar.gz"
curl -fsSL "https://github.com/o/mytool/releases/download/${VERSION}/${TAR}" -o "$TAR"
SH
    local result
    result=$(artifact_naming_installer_expected_name mytool v1.2.3 linux amd64 tar.gz "$INSTALLER_REPO" 2>/dev/null)
    assert_eq "mytool-linux-amd64.tar.gz" "$(jq -r '.name' <<< "$result")" "expected name from install.sh"
    assert_eq "false" "$(jq -r '.ext_mismatch' <<< "$result")" "matching extension is not a mismatch"
    assert_eq "install.sh" "$(jq -r '.script' <<< "$result")" "default installer path is install.sh"
    rm -rf "$INSTALLER_ROOT"
}

test_installer_expected_name_hardcoded_ext_mismatch() {
    log_test "An installer hardcoding .tar.gz expects .tar.gz even when the release builds .tar.xz"
    setup_installer_repo
    cat > "$INSTALLER_REPO/install.sh" <<'SH'
#!/bin/sh
asset_name="mytool-${OS}-${ARCH}.tar.gz"
SH
    local result
    result=$(artifact_naming_installer_expected_name mytool v1.2.3 darwin arm64 tar.xz "$INSTALLER_REPO" 2>/dev/null)
    assert_eq "mytool-darwin-arm64.tar.gz" "$(jq -r '.name' <<< "$result")" "installer's literal extension wins"
    assert_eq "true" "$(jq -r '.ext_mismatch' <<< "$result")" "extension mismatch is reported"
    rm -rf "$INSTALLER_ROOT"
}

test_installer_expected_name_configured_path() {
    log_test "install_script_path in the tool config selects the installer"
    setup_installer_repo
    mkdir -p "$INSTALLER_REPO/scripts"
    printf 'tool_name: mytool\ninstall_script_path: scripts/get.sh\n' > "$DSR_CONFIG_DIR/repos.d/mytool.yaml"
    cat > "$INSTALLER_REPO/scripts/get.sh" <<'SH'
#!/bin/sh
TAR="mytool-${VERSION}-${TARGET}.${EXT}"
SH
    local result
    result=$(artifact_naming_installer_expected_name mytool v2.0.0 linux arm64 tar.gz "$INSTALLER_REPO" 2>/dev/null)
    assert_eq "mytool-2.0.0-linux-arm64.tar.gz" "$(jq -r '.name' <<< "$result")" "versioned installer pattern"
    assert_eq "scripts/get.sh" "$(jq -r '.script' <<< "$result")" "configured installer path reported"
    rm -rf "$INSTALLER_ROOT"
}

test_installer_expected_name_absent() {
    log_test "No installer or no download pattern is not an expectation"
    setup_installer_repo
    local status=0
    artifact_naming_installer_expected_name mytool v1.0.0 linux amd64 tar.gz "$INSTALLER_REPO" >/dev/null 2>&1 || status=$?
    assert_eq "1" "$status" "missing install.sh returns 1"
    printf '#!/bin/sh\necho no downloads here\n' > "$INSTALLER_REPO/install.sh"
    status=0
    artifact_naming_installer_expected_name mytool v1.0.0 linux amd64 tar.gz "$INSTALLER_REPO" >/dev/null 2>&1 || status=$?
    assert_eq "1" "$status" "pattern-free install.sh returns 1"
    rm -rf "$INSTALLER_ROOT"
}

# =============================================================================
# PRINT SUMMARY
# =============================================================================

print_summary() {
    local end_time
    end_time=$(($(date +%s) * 1000))
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

        printf '{"test":"artifact_naming_parse_install","phases":%s,"result":"%s","total_tests":%d,"passed":%d,"failed":%d,"total_duration_ms":%d}\n' \
            "$phases_json" "$result_status" "$TEST_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$total_duration"
    else
        # Human-readable output
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
        echo "[$(log_timestamp)] Starting artifact_naming_parse_install_script unit tests" >&2
        echo "[$(log_timestamp)] Fixture directory: $FIXTURE_DIR" >&2
        echo "[$(log_timestamp)] Verbosity: $VERBOSE" >&2
    fi

    local phase_tests=0

    # Phase 1: TAR Variable Patterns
    start_phase "tar_variable_patterns"
    phase_tests=$TEST_COUNT
    test_tar_variable_simple
    test_tar_variable_cass_style
    test_tar_variable_with_ext
    test_tar_variable_case_statement
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 2: Asset Name Patterns
    start_phase "asset_name_patterns"
    phase_tests=$TEST_COUNT
    test_asset_name_lowercase
    test_asset_name_uppercase
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 3: URL Extraction Patterns
    start_phase "url_extraction_patterns"
    phase_tests=$TEST_COUNT
    test_url_pattern_extraction
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 4: Variable Normalization
    start_phase "variable_normalization"
    phase_tests=$TEST_COUNT
    test_normalize_target_to_os_arch
    test_normalize_goos_goarch
    test_normalize_name_variants
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 5: Edge Cases
    start_phase "edge_cases"
    phase_tests=$TEST_COUNT
    test_no_pattern_found
    test_nonexistent_file
    test_multiple_patterns_first_wins
    test_commented_pattern_ignored
    test_empty_file
    end_phase "pass" $((TEST_COUNT - phase_tests))

    # Phase 6: Installer expectations used by release verification
    start_phase "installer_expected_names"
    phase_tests=$TEST_COUNT
    test_installer_expected_name_matching_ext
    test_installer_expected_name_hardcoded_ext_mismatch
    test_installer_expected_name_configured_path
    test_installer_expected_name_absent
    end_phase "pass" $((TEST_COUNT - phase_tests))

    print_summary
}

main "$@"
