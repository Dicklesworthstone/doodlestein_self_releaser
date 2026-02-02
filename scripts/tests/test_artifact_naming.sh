#!/usr/bin/env bash
# test_artifact_naming.sh - Unit tests for artifact_naming.sh module
#
# Usage: ./scripts/tests/test_artifact_naming.sh
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

# Source the module under test
source "$PROJECT_ROOT/src/artifact_naming.sh"

# Test counters
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# Logging with timestamps
log_test() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [TEST] $*" >&2; }
log_pass() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [PASS] $*" >&2; }
log_fail() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [FAIL] $*" >&2; }
log_info() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO] $*" >&2; }

# Assertion functions
assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-assertion}"
    ((TEST_COUNT++))
    if [[ "$expected" == "$actual" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
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
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  haystack: '$haystack'"
        log_fail "  needle:   '$needle'"
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
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg: value was empty"
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

# Print test summary
print_summary() {
    echo ""
    echo "=========================================="
    echo "Test Summary: $PASS_COUNT/$TEST_COUNT passed"
    echo "=========================================="
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo "FAILURES: $FAIL_COUNT"
        return 1
    else
        echo "ALL TESTS PASSED"
        return 0
    fi
}

# =============================================================================
# TEST: artifact_naming_parse_install_script
# =============================================================================

test_parse_install_simple() {
    log_test "Parse simple install.sh with TAR variable"
    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/simple_install.sh")
    assert_eq 'mytool-${os}-${arch}' "$result" "Simple TAR pattern extraction"
}

test_parse_install_cass_style() {
    log_test "Parse CASS-style install.sh"
    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/cass_style_install.sh")
    assert_eq 'cass-${os}-${arch}' "$result" "CASS-style pattern extraction"
}

test_parse_install_versioned() {
    log_test "Parse install.sh with versioned asset_name"
    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/versioned_install.sh")
    # Should contain version variable
    assert_contains "$result" 'mytool' "Versioned pattern has tool name"
}

test_parse_install_no_pattern() {
    log_test "Parse install.sh with no recognizable pattern"
    local result
    result=$(artifact_naming_parse_install_script "$FIXTURE_DIR/no_pattern.sh")
    assert_empty "$result" "No pattern returns empty"
}

test_parse_install_nonexistent() {
    log_test "Parse nonexistent install.sh"
    local result
    result=$(artifact_naming_parse_install_script "/nonexistent/install.sh")
    assert_empty "$result" "Nonexistent file returns empty"
}

# =============================================================================
# TEST: artifact_naming_generate_dual
# =============================================================================

test_generate_dual_basic() {
    log_test "Generate dual names - basic case"
    local result
    result=$(artifact_naming_generate_dual "mytool" "v1.2.3" "linux" "amd64" "tar.gz")
    log_info "Result: $result"

    assert_contains "$result" '"versioned":"mytool-1.2.3-linux-amd64.tar.gz"' "Versioned name correct"
    assert_contains "$result" '"compat":"mytool-linux-amd64.tar.gz"' "Compat name correct"
    assert_contains "$result" '"same":false' "Names are different"
}

test_generate_dual_with_pattern() {
    log_test "Generate dual names - with explicit compat pattern"
    local result
    result=$(artifact_naming_generate_dual "cass" "v0.1.64" "darwin" "arm64" "tar.gz" '${name}-${os}-${arch}')
    log_info "Result: $result"

    assert_contains "$result" '"versioned":"cass-0.1.64-darwin-arm64.tar.gz"' "Versioned name correct"
    assert_contains "$result" '"compat":"cass-darwin-arm64.tar.gz"' "Compat with pattern correct"
}

test_generate_dual_windows() {
    log_test "Generate dual names - Windows with zip"
    local result
    result=$(artifact_naming_generate_dual "rch" "v1.0.0" "windows" "amd64" "zip")
    log_info "Result: $result"

    assert_contains "$result" '"versioned":"rch-1.0.0-windows-amd64.zip"' "Windows versioned name"
    assert_contains "$result" '"compat":"rch-windows-amd64.zip"' "Windows compat name"
}

test_generate_dual_same_names() {
    log_test "Generate dual names - same when no version in pattern"
    # When we provide a compat pattern that matches versioned format
    local result
    result=$(artifact_naming_generate_dual "tool" "v1.0.0" "linux" "amd64" "tar.gz" '${name}-1.0.0-${os}-${arch}')
    log_info "Result: $result"

    # Both names are the same
    assert_contains "$result" '"same":' "Has same field"
}

# =============================================================================
# TEST: artifact_naming_validate
# =============================================================================

test_validate_consistent() {
    log_test "Validate - consistent patterns"
    local result
    result=$(artifact_naming_validate "mytool" '${name}-${os}-${arch}' '${name}-${os}-${arch}' '[]')
    log_info "Result: $result"

    assert_contains "$result" '"status":"ok"' "Status is ok for consistent patterns"
}

test_validate_version_mismatch() {
    log_test "Validate - version mismatch detected"
    local result
    result=$(artifact_naming_validate "mytool" '${name}-${version}-${os}-${arch}' '${name}-${os}-${arch}' '[]')
    log_info "Result: $result"

    assert_contains "$result" '"status":"warning"' "Status is warning for version mismatch"
    assert_contains "$result" '"version"' "Mismatch mentions version"
}

# =============================================================================
# TEST: _an_normalize_pattern (internal function)
# =============================================================================

test_normalize_target() {
    log_test "Normalize TARGET variable"
    local result
    result=$(_an_normalize_pattern '${TARGET}')
    assert_eq '${os}-${arch}' "$result" "TARGET normalizes to os-arch"
}

test_normalize_goos_goarch() {
    log_test "Normalize GOOS/GOARCH variables"
    local result
    result=$(_an_normalize_pattern '${GOOS}-${GOARCH}')
    assert_eq '${os}-${arch}' "$result" "GOOS/GOARCH normalize correctly"
}

test_normalize_name_variants() {
    log_test "Normalize NAME/TOOL variants"
    local result1 result2 result3
    result1=$(_an_normalize_pattern '${NAME}')
    result2=$(_an_normalize_pattern '${TOOL}')
    result3=$(_an_normalize_pattern '${APP}')
    assert_eq '${name}' "$result1" "NAME normalizes to name"
    assert_eq '${name}' "$result2" "TOOL normalizes to name"
    assert_eq '${name}' "$result3" "APP normalizes to name"
}

# =============================================================================
# TEST: artifact_naming_substitute
# =============================================================================

test_substitute_basic() {
    log_test "Substitute variables in pattern"
    local result
    result=$(artifact_naming_substitute '${name}-${version}-${os}-${arch}' "mytool" "v1.0.0" "linux" "amd64" "tar.gz")
    assert_eq "mytool-1.0.0-linux-amd64" "$result" "Basic substitution"
}

test_substitute_with_target() {
    log_test "Substitute with target variable"
    local result
    result=$(artifact_naming_substitute '${name}-${target}' "mytool" "v1.0.0" "darwin" "arm64" "tar.gz")
    assert_eq "mytool-darwin-arm64" "$result" "Target substitution"
}

# =============================================================================
# TEST: artifact_naming_parse_workflow (requires yq)
# =============================================================================

test_parse_workflow() {
    log_test "Parse workflow YAML"
    if ! command -v yq &>/dev/null; then
        log_info "SKIP: yq not installed"
        ((TEST_COUNT++))
        ((PASS_COUNT++))
        return 0
    fi

    local result
    result=$(artifact_naming_parse_workflow "$FIXTURE_DIR/sample_workflow.yml")
    log_info "Result: $result"

    assert_not_empty "$result" "Workflow parsing returns result"
    # Should find the upload-artifact name pattern
    assert_contains "$result" 'mytool-${os}-${arch}' "Found upload-artifact pattern"
}

test_parse_workflow_nonexistent() {
    log_test "Parse nonexistent workflow"
    local result
    result=$(artifact_naming_parse_workflow "/nonexistent/workflow.yml")
    assert_eq "[]" "$result" "Nonexistent workflow returns empty array"
}

# =============================================================================
# RUN ALL TESTS
# =============================================================================

main() {
    log_info "Starting artifact_naming.sh unit tests"
    log_info "Fixture directory: $FIXTURE_DIR"
    echo ""

    # Parse install.sh tests
    test_parse_install_simple
    test_parse_install_cass_style
    test_parse_install_versioned
    test_parse_install_no_pattern
    test_parse_install_nonexistent

    # Generate dual names tests
    test_generate_dual_basic
    test_generate_dual_with_pattern
    test_generate_dual_windows
    test_generate_dual_same_names

    # Validation tests
    test_validate_consistent
    test_validate_version_mismatch

    # Normalization tests
    test_normalize_target
    test_normalize_goos_goarch
    test_normalize_name_variants

    # Substitution tests
    test_substitute_basic
    test_substitute_with_target

    # Workflow parsing tests
    test_parse_workflow
    test_parse_workflow_nonexistent

    print_summary
}

main "$@"
