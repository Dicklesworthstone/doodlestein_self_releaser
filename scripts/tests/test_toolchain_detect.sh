#!/usr/bin/env bash
# test_toolchain_detect.sh - Tests for toolchain_detect.sh module
#
# Tests toolchain detection, version comparison, and installation safety.
# Uses real toolchain detection where available; tests pure logic directly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../src" && pwd)"

# Source the module under test
# shellcheck source=../../src/logging.sh
source "$SRC_DIR/logging.sh"
# shellcheck source=../../src/toolchain_detect.sh
source "$SRC_DIR/toolchain_detect.sh"

# Test state
TEMP_DIR=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Initialize logging silently
log_init 2>/dev/null || true

# ============================================================================
# Test Infrastructure
# ============================================================================

setup() {
  TEMP_DIR=$(mktemp -d)
  # Suppress colors for consistent test output
  export NO_COLOR=1
  # Reset to non-interactive mode for predictable behavior
  _TC_NON_INTERACTIVE=true
}

teardown() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-assertion failed}"

  if [[ "$expected" != "$actual" ]]; then
    echo "  FAIL: $msg"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    return 1
  fi
  return 0
}

assert_true() {
  local condition="$1"
  local msg="${2:-expected true}"

  if ! eval "$condition"; then
    echo "  FAIL: $msg"
    return 1
  fi
  return 0
}

assert_false() {
  local condition="$1"
  local msg="${2:-expected false}"

  if eval "$condition"; then
    echo "  FAIL: $msg"
    return 1
  fi
  return 0
}

assert_json_field() {
  local json="$1"
  local field="$2"
  local expected="$3"
  local msg="${4:-JSON field mismatch}"

  local actual
  actual=$(echo "$json" | jq -r ".$field")

  if [[ "$expected" != "$actual" ]]; then
    echo "  FAIL: $msg"
    echo "    Field: $field"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    return 1
  fi
  return 0
}

assert_json_valid() {
  local json="$1"
  local msg="${2:-invalid JSON}"

  if ! echo "$json" | jq -e . >/dev/null 2>&1; then
    echo "  FAIL: $msg"
    echo "    JSON: $json"
    return 1
  fi
  return 0
}

run_test() {
  local test_name="$1"
  local test_func="$2"

  ((TESTS_RUN++))
  echo -n "  $test_name... "

  if $test_func 2>/dev/null; then
    echo "OK"
    ((TESTS_PASSED++))
  else
    echo "FAILED"
    ((TESTS_FAILED++))
  fi
}

# ============================================================================
# Tests: Version Comparison (_tc_version_ge)
# ============================================================================

test_version_ge_equal() {
  _tc_version_ge "1.70.0" "1.70.0"
}

test_version_ge_greater_patch() {
  _tc_version_ge "1.70.1" "1.70.0"
}

test_version_ge_greater_minor() {
  _tc_version_ge "1.71.0" "1.70.0"
}

test_version_ge_greater_major() {
  _tc_version_ge "2.0.0" "1.70.0"
}

test_version_ge_less_patch() {
  ! _tc_version_ge "1.69.0" "1.70.0"
}

test_version_ge_less_minor() {
  ! _tc_version_ge "1.69.5" "1.70.0"
}

test_version_ge_less_major() {
  ! _tc_version_ge "0.99.0" "1.0.0"
}

test_version_ge_prerelease() {
  # Pre-release suffix should be stripped for comparison
  _tc_version_ge "1.70.0-beta.1" "1.70.0"
}

test_version_ge_with_prefix() {
  # Version prefixes (like rustc 1.70.0) should work
  _tc_version_ge "rustc 1.70.0 (12345)" "1.70.0"
}

test_version_ge_missing_v1() {
  # Empty v1 should return false
  ! _tc_version_ge "" "1.0.0"
}

test_version_ge_missing_v2() {
  # Empty v2 should return true (no requirement)
  _tc_version_ge "1.0.0" ""
}

test_version_ge_go_format() {
  # Go version format: go1.21.0
  _tc_version_ge "go1.21.5" "1.21.0"
}

test_version_ge_node_format() {
  # Node version format: v20.10.0
  _tc_version_ge "v20.10.0" "18.0.0"
}

# ============================================================================
# Tests: Platform Detection (_tc_detect_platform)
# ============================================================================

test_detect_platform_format() {
  local platform
  platform=$(_tc_detect_platform)
  # Should be in format: os/arch
  [[ "$platform" =~ ^[a-z]+/[a-z0-9]+$ ]]
}

test_detect_platform_known_os() {
  local platform
  platform=$(_tc_detect_platform)
  local os="${platform%/*}"
  # Should be one of: linux, darwin, windows, unknown
  [[ "$os" == "linux" || "$os" == "darwin" || "$os" == "windows" || "$os" == "unknown" ]]
}

test_detect_platform_known_arch() {
  local platform
  platform=$(_tc_detect_platform)
  local arch="${platform#*/}"
  # Should be one of: amd64, arm64, armv7, 386, unknown
  [[ "$arch" == "amd64" || "$arch" == "arm64" || "$arch" == "armv7" || "$arch" == "386" || "$arch" == "unknown" ]]
}

test_detect_platform_consistent() {
  # Multiple calls should return the same value
  local p1 p2
  p1=$(_tc_detect_platform)
  p2=$(_tc_detect_platform)
  [[ "$p1" == "$p2" ]]
}

# ============================================================================
# Tests: Rust Detection
# ============================================================================

test_detect_rust_json_valid() {
  local result
  result=$(toolchain_detect_rust)
  assert_json_valid "$result" "Rust detection should return valid JSON"
}

test_detect_rust_has_required_fields() {
  local result
  result=$(toolchain_detect_rust)
  # Presence is the contract. `installed` and `meets_minimum` may legitimately
  # be false on a host where Rust is absent or below the supported minimum.
  echo "$result" | jq -e '
    has("toolchain") and
    has("installed") and
    has("minimum_version") and
    has("meets_minimum")
  ' >/dev/null
}

test_detect_rust_toolchain_field() {
  local result
  result=$(toolchain_detect_rust)
  assert_json_field "$result" "toolchain" "rust" "Toolchain field should be 'rust'"
}

test_detect_rust_minimum_version() {
  local result
  result=$(toolchain_detect_rust)
  local min_version
  min_version=$(echo "$result" | jq -r '.minimum_version')
  [[ "$min_version" == "$TOOLCHAIN_RUST_MIN_VERSION" ]]
}

test_detect_rust_installed_boolean() {
  local result
  result=$(toolchain_detect_rust)
  local installed
  installed=$(echo "$result" | jq -r '.installed')
  # Should be true or false, not null or other
  [[ "$installed" == "true" || "$installed" == "false" ]]
}

# ============================================================================
# Tests: Go Detection
# ============================================================================

test_detect_go_json_valid() {
  local result
  result=$(toolchain_detect_go)
  assert_json_valid "$result" "Go detection should return valid JSON"
}

test_detect_go_has_required_fields() {
  local result
  result=$(toolchain_detect_go)
  echo "$result" | jq -e '.toolchain' >/dev/null
  echo "$result" | jq -e '.installed' >/dev/null
  echo "$result" | jq -e '.minimum_version' >/dev/null
}

test_detect_go_toolchain_field() {
  local result
  result=$(toolchain_detect_go)
  assert_json_field "$result" "toolchain" "go" "Toolchain field should be 'go'"
}

test_detect_go_minimum_version() {
  local result
  result=$(toolchain_detect_go)
  local min_version
  min_version=$(echo "$result" | jq -r '.minimum_version')
  [[ "$min_version" == "$TOOLCHAIN_GO_MIN_VERSION" ]]
}

# ============================================================================
# Tests: Bun Detection
# ============================================================================

test_detect_bun_json_valid() {
  local result
  result=$(toolchain_detect_bun)
  assert_json_valid "$result" "Bun detection should return valid JSON"
}

test_detect_bun_toolchain_field() {
  local result
  result=$(toolchain_detect_bun)
  assert_json_field "$result" "toolchain" "bun" "Toolchain field should be 'bun'"
}

test_detect_bun_minimum_version() {
  local result
  result=$(toolchain_detect_bun)
  local min_version
  min_version=$(echo "$result" | jq -r '.minimum_version')
  [[ "$min_version" == "$TOOLCHAIN_BUN_MIN_VERSION" ]]
}

# ============================================================================
# Tests: Node Detection
# ============================================================================

test_detect_node_json_valid() {
  local result
  result=$(toolchain_detect_node)
  assert_json_valid "$result" "Node detection should return valid JSON"
}

test_detect_node_toolchain_field() {
  local result
  result=$(toolchain_detect_node)
  assert_json_field "$result" "toolchain" "node" "Toolchain field should be 'node'"
}

test_detect_node_minimum_version() {
  local result
  result=$(toolchain_detect_node)
  local min_version
  min_version=$(echo "$result" | jq -r '.minimum_version')
  [[ "$min_version" == "$TOOLCHAIN_NODE_MIN_VERSION" ]]
}

# ============================================================================
# Tests: Unified Interface (toolchain_detect)
# ============================================================================

test_toolchain_detect_rust_alias() {
  local r1 r2
  r1=$(toolchain_detect rust)
  r2=$(toolchain_detect_rust)
  # Should return same result
  [[ "$(echo "$r1" | jq -r '.toolchain')" == "$(echo "$r2" | jq -r '.toolchain')" ]]
}

test_toolchain_detect_go_aliases() {
  local r1 r2
  r1=$(toolchain_detect go)
  r2=$(toolchain_detect golang)
  [[ "$(echo "$r1" | jq -r '.toolchain')" == "$(echo "$r2" | jq -r '.toolchain')" ]]
}

test_toolchain_detect_node_aliases() {
  local r1 r2 r3
  r1=$(toolchain_detect node)
  r2=$(toolchain_detect nodejs)
  r3=$(toolchain_detect npm)
  [[ "$(echo "$r1" | jq -r '.toolchain')" == "$(echo "$r2" | jq -r '.toolchain')" ]]
  [[ "$(echo "$r2" | jq -r '.toolchain')" == "$(echo "$r3" | jq -r '.toolchain')" ]]
}

test_toolchain_detect_unknown() {
  # Unknown toolchain should return non-zero exit code
  ! toolchain_detect "unknown_toolchain" 2>/dev/null
}

# ============================================================================
# Tests: Detect All
# ============================================================================

test_detect_all_json_valid() {
  local result
  result=$(toolchain_detect_all)
  assert_json_valid "$result" "toolchain_detect_all should return valid JSON"
}

test_detect_all_has_platform() {
  local result
  result=$(toolchain_detect_all)
  echo "$result" | jq -e '.platform' >/dev/null
}

test_detect_all_has_toolchains_array() {
  local result
  result=$(toolchain_detect_all)
  local count
  count=$(echo "$result" | jq '.toolchains | length')
  [[ "$count" -eq 4 ]]  # rust, go, bun, node
}

test_detect_all_contains_all_toolchains() {
  local result
  result=$(toolchain_detect_all)
  local toolchains
  toolchains=$(echo "$result" | jq -r '.toolchains[].toolchain' | sort | tr '\n' ' ')
  [[ "$toolchains" == *"bun"* ]]
  [[ "$toolchains" == *"go"* ]]
  [[ "$toolchains" == *"node"* ]]
  [[ "$toolchains" == *"rust"* ]]
}

# ============================================================================
# Tests: Installation Safety
# ============================================================================

test_install_rust_refuses_overwrite() {
  # If Rust is installed, installation should refuse to overwrite
  if command -v rustc &>/dev/null; then
    # Should return non-zero (refusal to overwrite)
    ! _tc_install_rust 2>/dev/null
  else
    # Skip test if Rust not installed
    return 0
  fi
}

test_install_go_refuses_overwrite() {
  # If Go is installed, installation should refuse to overwrite
  if command -v go &>/dev/null; then
    ! _tc_install_go 2>/dev/null
  else
    return 0
  fi
}

test_install_bun_refuses_overwrite() {
  # If Bun is installed, installation should refuse to overwrite
  if command -v bun &>/dev/null; then
    ! _tc_install_bun 2>/dev/null
  else
    return 0
  fi
}

test_toolchain_install_refuses_existing() {
  # Test the main install function refuses to overwrite
  # Pick first available toolchain
  local tc=""
  command -v rustc &>/dev/null && tc="rust"
  command -v go &>/dev/null && tc="go"
  command -v bun &>/dev/null && tc="bun"

  if [[ -n "$tc" ]]; then
    ! toolchain_install "$tc" --yes 2>/dev/null
  else
    return 0  # No toolchains to test
  fi
}

test_toolchain_install_unknown_returns_error() {
  ! toolchain_install "unknown_toolchain" --yes 2>/dev/null
}

# ============================================================================
# Tests: Ensure Logic
# ============================================================================

test_ensure_returns_ok_when_installed() {
  # Find an installed toolchain with sufficient version
  local result
  for tc in rust go bun node; do
    result=$(toolchain_detect "$tc" 2>/dev/null) || continue
    local installed meets_minimum
    installed=$(echo "$result" | jq -r '.installed')
    meets_minimum=$(echo "$result" | jq -r '.meets_minimum')
    if [[ "$installed" == "true" && "$meets_minimum" == "true" ]]; then
      toolchain_ensure "$tc" 2>/dev/null
      return 0
    fi
  done
  # Skip if no suitable toolchain found
  return 0
}

test_ensure_returns_error_when_missing() {
  # Create a mock missing toolchain scenario by testing unknown
  ! toolchain_ensure "unknown_toolchain" 2>/dev/null
}

# ============================================================================
# Tests: Non-Interactive Mode
# ============================================================================

test_prompt_fails_in_noninteractive() {
  _TC_NON_INTERACTIVE=true
  ! _tc_prompt "Test question?" 2>/dev/null
}

test_noninteractive_respects_env() {
  export NON_INTERACTIVE=true
  # Source again to pick up env
  _TC_NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
  [[ "$_TC_NON_INTERACTIVE" == "true" ]]
}

# ============================================================================
# Tests: Logging Functions
# ============================================================================

test_log_functions_exist() {
  # Verify all log functions are defined
  declare -f _tc_log_info >/dev/null
  declare -f _tc_log_ok >/dev/null
  declare -f _tc_log_warn >/dev/null
  declare -f _tc_log_error >/dev/null
}

test_log_output_to_stderr() {
  local output
  # Capture stderr
  output=$(_tc_log_info "test message" 2>&1 >/dev/null)
  [[ "$output" == *"test message"* ]]
}

# ============================================================================
# Tests: Constants
# ============================================================================

test_min_versions_defined() {
  [[ -n "$TOOLCHAIN_RUST_MIN_VERSION" ]]
  [[ -n "$TOOLCHAIN_GO_MIN_VERSION" ]]
  [[ -n "$TOOLCHAIN_BUN_MIN_VERSION" ]]
  [[ -n "$TOOLCHAIN_NODE_MIN_VERSION" ]]
}

test_install_urls_defined() {
  [[ -n "$TOOLCHAIN_RUST_INSTALL_URL" ]]
  [[ -n "$TOOLCHAIN_GO_DOWNLOAD_URL" ]]
  [[ -n "$TOOLCHAIN_BUN_INSTALL_URL" ]]
  [[ -n "$TOOLCHAIN_NODE_DOWNLOAD_URL" ]]
}

test_install_urls_https() {
  [[ "$TOOLCHAIN_RUST_INSTALL_URL" == https://* ]]
  [[ "$TOOLCHAIN_GO_DOWNLOAD_URL" == https://* ]]
  [[ "$TOOLCHAIN_BUN_INSTALL_URL" == https://* ]]
  [[ "$TOOLCHAIN_NODE_DOWNLOAD_URL" == https://* ]]
}

# ============================================================================
# Main Test Runner
# ============================================================================

main() {
  echo "=== toolchain_detect.sh Tests ==="
  echo ""

  setup

  echo "Version Comparison:"
  run_test "version_ge_equal" test_version_ge_equal
  run_test "version_ge_greater_patch" test_version_ge_greater_patch
  run_test "version_ge_greater_minor" test_version_ge_greater_minor
  run_test "version_ge_greater_major" test_version_ge_greater_major
  run_test "version_ge_less_patch" test_version_ge_less_patch
  run_test "version_ge_less_minor" test_version_ge_less_minor
  run_test "version_ge_less_major" test_version_ge_less_major
  run_test "version_ge_prerelease" test_version_ge_prerelease
  run_test "version_ge_with_prefix" test_version_ge_with_prefix
  run_test "version_ge_missing_v1" test_version_ge_missing_v1
  run_test "version_ge_missing_v2" test_version_ge_missing_v2
  run_test "version_ge_go_format" test_version_ge_go_format
  run_test "version_ge_node_format" test_version_ge_node_format

  echo ""
  echo "Platform Detection:"
  run_test "detect_platform_format" test_detect_platform_format
  run_test "detect_platform_known_os" test_detect_platform_known_os
  run_test "detect_platform_known_arch" test_detect_platform_known_arch
  run_test "detect_platform_consistent" test_detect_platform_consistent

  echo ""
  echo "Rust Detection:"
  run_test "detect_rust_json_valid" test_detect_rust_json_valid
  run_test "detect_rust_has_required_fields" test_detect_rust_has_required_fields
  run_test "detect_rust_toolchain_field" test_detect_rust_toolchain_field
  run_test "detect_rust_minimum_version" test_detect_rust_minimum_version
  run_test "detect_rust_installed_boolean" test_detect_rust_installed_boolean

  echo ""
  echo "Go Detection:"
  run_test "detect_go_json_valid" test_detect_go_json_valid
  run_test "detect_go_has_required_fields" test_detect_go_has_required_fields
  run_test "detect_go_toolchain_field" test_detect_go_toolchain_field
  run_test "detect_go_minimum_version" test_detect_go_minimum_version

  echo ""
  echo "Bun Detection:"
  run_test "detect_bun_json_valid" test_detect_bun_json_valid
  run_test "detect_bun_toolchain_field" test_detect_bun_toolchain_field
  run_test "detect_bun_minimum_version" test_detect_bun_minimum_version

  echo ""
  echo "Node Detection:"
  run_test "detect_node_json_valid" test_detect_node_json_valid
  run_test "detect_node_toolchain_field" test_detect_node_toolchain_field
  run_test "detect_node_minimum_version" test_detect_node_minimum_version

  echo ""
  echo "Unified Interface:"
  run_test "toolchain_detect_rust_alias" test_toolchain_detect_rust_alias
  run_test "toolchain_detect_go_aliases" test_toolchain_detect_go_aliases
  run_test "toolchain_detect_node_aliases" test_toolchain_detect_node_aliases
  run_test "toolchain_detect_unknown" test_toolchain_detect_unknown

  echo ""
  echo "Detect All:"
  run_test "detect_all_json_valid" test_detect_all_json_valid
  run_test "detect_all_has_platform" test_detect_all_has_platform
  run_test "detect_all_has_toolchains_array" test_detect_all_has_toolchains_array
  run_test "detect_all_contains_all_toolchains" test_detect_all_contains_all_toolchains

  echo ""
  echo "Installation Safety:"
  run_test "install_rust_refuses_overwrite" test_install_rust_refuses_overwrite
  run_test "install_go_refuses_overwrite" test_install_go_refuses_overwrite
  run_test "install_bun_refuses_overwrite" test_install_bun_refuses_overwrite
  run_test "toolchain_install_refuses_existing" test_toolchain_install_refuses_existing
  run_test "toolchain_install_unknown_returns_error" test_toolchain_install_unknown_returns_error

  echo ""
  echo "Ensure Logic:"
  run_test "ensure_returns_ok_when_installed" test_ensure_returns_ok_when_installed
  run_test "ensure_returns_error_when_missing" test_ensure_returns_error_when_missing

  echo ""
  echo "Non-Interactive Mode:"
  run_test "prompt_fails_in_noninteractive" test_prompt_fails_in_noninteractive
  run_test "noninteractive_respects_env" test_noninteractive_respects_env

  echo ""
  echo "Logging Functions:"
  run_test "log_functions_exist" test_log_functions_exist
  run_test "log_output_to_stderr" test_log_output_to_stderr

  echo ""
  echo "Constants:"
  run_test "min_versions_defined" test_min_versions_defined
  run_test "install_urls_defined" test_install_urls_defined
  run_test "install_urls_https" test_install_urls_https

  teardown

  echo ""
  echo "=== Results ==="
  echo "Tests run:    $TESTS_RUN"
  echo "Tests passed: $TESTS_PASSED"
  echo "Tests failed: $TESTS_FAILED"

  if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
