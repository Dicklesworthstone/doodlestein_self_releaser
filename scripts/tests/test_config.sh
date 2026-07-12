#!/usr/bin/env bash
# test_config.sh - Tests for config.sh module
#
# Tests XDG-compliant configuration management.
# Uses isolated temp directories for each test.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../src" && pwd)"

# Source the module under test
# shellcheck source=../../src/logging.sh
source "$SRC_DIR/logging.sh"
# shellcheck source=../../src/config.sh
source "$SRC_DIR/config.sh"

# Test state
TEMP_DIR=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Original XDG values (to restore after tests)
_ORIG_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}"
_ORIG_XDG_CACHE_HOME="${XDG_CACHE_HOME:-}"
_ORIG_XDG_STATE_HOME="${XDG_STATE_HOME:-}"

# Initialize logging silently
log_init 2>/dev/null || true

# Suppress colors for consistent output
export NO_COLOR=1

# ============================================================================
# Test Infrastructure
# ============================================================================

setup() {
  TEMP_DIR=$(mktemp -d)

  # Set up isolated XDG directories
  export XDG_CONFIG_HOME="$TEMP_DIR/config"
  export XDG_CACHE_HOME="$TEMP_DIR/cache"
  export XDG_STATE_HOME="$TEMP_DIR/state"

  # Re-initialize config module paths
  DSR_CONFIG_DIR="$XDG_CONFIG_HOME/dsr"
  DSR_CACHE_DIR="$XDG_CACHE_HOME/dsr"
  DSR_STATE_DIR="$XDG_STATE_HOME/dsr"
  DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"
  DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
  DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"

  # Reset config array
  DSR_CONFIG=()
}

teardown() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi

  # Restore original XDG values
  export XDG_CONFIG_HOME="$_ORIG_XDG_CONFIG_HOME"
  export XDG_CACHE_HOME="$_ORIG_XDG_CACHE_HOME"
  export XDG_STATE_HOME="$_ORIG_XDG_STATE_HOME"
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

write_contract_tool_config() {
  mkdir -p "$DSR_CONFIG_DIR/repos.d"
  cat > "$DSR_CONFIG_DIR/repos.d/contract-tool.yaml"
}

release_contract_test_deps_available() {
  command -v yq &>/dev/null && command -v jq &>/dev/null
}

run_test() {
  local test_name="$1"
  local test_func="$2"

  ((TESTS_RUN++))
  echo -n "  $test_name... "

  setup

  if $test_func 2>/dev/null; then
    echo "OK"
    ((TESTS_PASSED++))
  else
    echo "FAILED"
    ((TESTS_FAILED++))
  fi

  teardown
}

# ============================================================================
# Tests: Initialization (config_init)
# ============================================================================

test_init_creates_config_dir() {
  config_init
  [[ -d "$DSR_CONFIG_DIR" ]]
}

test_init_creates_cache_dir() {
  config_init
  [[ -d "$DSR_CACHE_DIR" ]]
}

test_init_creates_state_dir() {
  config_init
  [[ -d "$DSR_STATE_DIR" ]]
}

test_init_creates_subdirs() {
  config_init
  [[ -d "$DSR_STATE_DIR/logs" ]] && \
  [[ -d "$DSR_STATE_DIR/artifacts" ]] && \
  [[ -d "$DSR_STATE_DIR/manifests" ]] && \
  [[ -d "$DSR_CACHE_DIR/act" ]] && \
  [[ -d "$DSR_CACHE_DIR/builds" ]]
}

test_init_creates_config_yaml() {
  config_init
  [[ -f "$DSR_CONFIG_FILE" ]]
}

test_init_creates_hosts_yaml() {
  config_init
  [[ -f "$DSR_HOSTS_FILE" ]]
}

test_init_creates_repos_yaml() {
  config_init
  [[ -f "$DSR_REPOS_FILE" ]]
}

test_init_no_overwrite() {
  config_init
  # Write custom content
  echo "custom: value" > "$DSR_CONFIG_FILE"
  config_init  # Should not overwrite
  grep -q "custom: value" "$DSR_CONFIG_FILE"
}

test_init_force_overwrites() {
  config_init
  # Write custom content
  echo "custom: value" > "$DSR_CONFIG_FILE"
  config_init --force  # Should overwrite
  ! grep -q "custom: value" "$DSR_CONFIG_FILE"
}

test_init_config_has_schema_version() {
  config_init
  grep -q "schema_version:" "$DSR_CONFIG_FILE"
}

test_init_hosts_has_hosts() {
  config_init
  grep -q "hosts:" "$DSR_HOSTS_FILE"
}

test_init_repos_has_tools() {
  config_init
  grep -q "tools:" "$DSR_REPOS_FILE"
}

# ============================================================================
# Tests: Loading (config_load)
# ============================================================================

test_load_sets_defaults() {
  config_load
  [[ -n "${DSR_CONFIG[threshold_seconds]:-}" ]] && \
  [[ -n "${DSR_CONFIG[log_level]:-}" ]]
}

test_load_default_threshold() {
  config_load
  [[ "${DSR_CONFIG[threshold_seconds]}" == "600" ]]
}

test_load_default_log_level() {
  config_load
  [[ "${DSR_CONFIG[log_level]}" == "info" ]]
}

test_load_reads_config_file() {
  config_init
  # Add custom value to config
  echo "custom_key: custom_value" >> "$DSR_CONFIG_FILE"
  config_load
  [[ "${DSR_CONFIG[custom_key]:-}" == "custom_value" ]]
}

test_load_env_overrides_file() {
  config_init
  config_load
  # Set env var override
  export DSR_LOG_LEVEL="debug"
  config_load
  local result="${DSR_CONFIG[log_level]}"
  unset DSR_LOG_LEVEL
  [[ "$result" == "debug" ]]
}

test_load_threshold_env_override() {
  config_init
  export DSR_THRESHOLD="1200"
  config_load
  local result="${DSR_CONFIG[threshold_seconds]}"
  unset DSR_THRESHOLD
  [[ "$result" == "1200" ]]
}

test_load_signing_disabled_by_env() {
  config_init
  export DSR_NO_SIGN="1"
  config_load
  local result="${DSR_CONFIG[signing_enabled]}"
  unset DSR_NO_SIGN
  [[ "$result" == "false" ]]
}

test_load_resets_config() {
  config_load
  # shellcheck disable=SC2154  # test_key is a literal associative array key, not a variable
  DSR_CONFIG[test_key]="test_value"
  config_load  # Should reset
  # shellcheck disable=SC2154
  [[ -z "${DSR_CONFIG[test_key]:-}" ]]
}

# ============================================================================
# Tests: Get/Set (config_get, config_set)
# ============================================================================

test_get_returns_value() {
  config_load
  local result
  result=$(config_get "threshold_seconds")
  [[ "$result" == "600" ]]
}

test_get_returns_default() {
  config_load
  local result
  result=$(config_get "nonexistent_key" "default_value")
  [[ "$result" == "default_value" ]]
}

test_get_returns_empty_for_missing() {
  config_load
  local result
  result=$(config_get "nonexistent_key")
  [[ -z "$result" ]]
}

test_set_updates_value() {
  config_load
  config_set "threshold_seconds" "1800"
  local result
  result=$(config_get "threshold_seconds")
  [[ "$result" == "1800" ]]
}

test_set_creates_new_key() {
  config_load
  config_set "new_key" "new_value"
  local result
  result=$(config_get "new_key")
  [[ "$result" == "new_value" ]]
}

test_set_persist_requires_yq() {
  config_init
  config_load
  # This test just verifies the function doesn't crash
  # Actual persistence depends on yq availability
  config_set "test_key" "test_value" --persist || true
  [[ "${DSR_CONFIG[test_key]}" == "test_value" ]]
}

# ============================================================================
# Tests: Validation (config_validate)
# ============================================================================

test_validate_passes_with_init() {
  config_init
  config_load
  config_validate
}

test_validate_fails_missing_dir() {
  # Don't init, dir doesn't exist
  ! config_validate
}

test_validate_checks_schema_version() {
  config_init
  config_load
  # Remove schema_version
  DSR_CONFIG=()
  ! config_validate
}

# ============================================================================
# Tests: Show (config_show)
# ============================================================================

test_show_human_output() {
  config_init
  config_load
  local output
  output=$(config_show)
  [[ "$output" == *"dsr Configuration"* ]] && \
  [[ "$output" == *"Directories"* ]] && \
  [[ "$output" == *"Values"* ]]
}

test_show_json_output() {
  config_init
  config_load
  local output
  output=$(config_show --json)
  [[ "$output" == "{"* ]] && \
  [[ "$output" == *"config_dir"* ]] && \
  [[ "$output" == *"values"* ]]
}

test_show_specific_key() {
  config_init
  config_load
  local output
  output=$(config_show threshold_seconds)
  [[ "$output" == *"threshold_seconds"* ]] && \
  [[ "$output" == *"600"* ]]
}

test_show_json_specific_key() {
  config_init
  config_load
  local output
  output=$(config_show --json threshold_seconds)
  [[ "$output" == *"threshold_seconds"* ]]
}

# ============================================================================
# Tests: XDG Compliance
# ============================================================================

test_xdg_config_home_override() {
  local custom_config="$TEMP_DIR/custom_config"
  mkdir -p "$custom_config"
  export XDG_CONFIG_HOME="$custom_config"

  # Re-initialize paths
  DSR_CONFIG_DIR="$XDG_CONFIG_HOME/dsr"
  DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"

  config_init
  [[ -d "$custom_config/dsr" ]]
}

test_xdg_cache_home_override() {
  local custom_cache="$TEMP_DIR/custom_cache"
  mkdir -p "$custom_cache"
  export XDG_CACHE_HOME="$custom_cache"

  # Re-initialize paths
  DSR_CACHE_DIR="$XDG_CACHE_HOME/dsr"

  config_init
  [[ -d "$custom_cache/dsr" ]]
}

test_xdg_state_home_override() {
  local custom_state="$TEMP_DIR/custom_state"
  mkdir -p "$custom_state"
  export XDG_STATE_HOME="$custom_state"

  # Re-initialize paths
  DSR_STATE_DIR="$XDG_STATE_HOME/dsr"

  config_init
  [[ -d "$custom_state/dsr" ]]
}

# ============================================================================
# Tests: Host/Tool Configuration
# ============================================================================

test_get_host_for_platform_linux() {
  config_init
  local host
  host=$(config_get_host_for_platform "linux/amd64")
  [[ "$host" == "trj" || "$host" == "\"trj\"" ]]
}

test_get_host_for_platform_darwin() {
  config_init
  local host
  host=$(config_get_host_for_platform "darwin/arm64")
  [[ "$host" == "mmini" || "$host" == "\"mmini\"" ]]
}

test_get_host_for_platform_windows() {
  config_init
  local host
  host=$(config_get_host_for_platform "windows/amd64")
  [[ "$host" == "wlap" || "$host" == "\"wlap\"" ]]
}

test_list_hosts_returns_hosts() {
  config_init
  # Skip if yq not available
  command -v yq &>/dev/null || return 0
  local output
  output=$(config_list_hosts)
  [[ "$output" == *"trj"* ]] && \
  [[ "$output" == *"mmini"* ]] && \
  [[ "$output" == *"wlap"* ]]
}

test_get_host_returns_config() {
  config_init
  # Skip if yq not available
  command -v yq &>/dev/null || return 0
  local output
  output=$(config_get_host "trj")
  [[ "$output" == *"linux/amd64"* ]] || [[ "$output" == *"local"* ]]
}

# ============================================================================
# Tests: Release Contract
# ============================================================================

test_release_contract_absent_is_legacy_compatible() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets:
  - linux/amd64
YAML

  [[ "$(config_get_release_contract_json contract-tool)" == "null" ]] &&
    config_validate_release_contract contract-tool
}

test_release_contract_null_is_legacy_compatible() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets:
  - linux/amd64
release_contract: null
YAML

  [[ "$(config_get_release_contract_json contract-tool)" == "null" ]] &&
    config_validate_release_contract contract-tool
}

test_release_contract_rejects_non_object() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets:
  - linux/amd64
release_contract: sha256
YAML

  ! config_get_release_contract_json contract-tool >/dev/null &&
    ! config_validate_release_contract contract-tool
}

test_release_contract_valid_is_canonical_json() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets:
  - linux/amd64
  - darwin/arm64
release_contract:
  exact_primary_assets:
    linux/amd64: contract-tool-x86_64-unknown-linux-gnu
    darwin/arm64: contract-tool-aarch64-apple-darwin
  checksum_sidecar: sha256
YAML

  local expected
  expected='{"checksum_sidecar":"sha256","exact_primary_assets":{"darwin/arm64":"contract-tool-aarch64-apple-darwin","linux/amd64":"contract-tool-x86_64-unknown-linux-gnu"}}'
  [[ "$(config_get_release_contract_json contract-tool)" == "$expected" ]] &&
    config_validate_release_contract contract-tool
}

test_release_contract_registry_fallback() {
  release_contract_test_deps_available || return 0
  mkdir -p "$DSR_CONFIG_DIR"
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  contract-tool:
    targets:
      - linux/amd64
    release_contract:
      checksum_sidecar: sha256
      exact_primary_assets:
        linux/amd64: contract-tool-x86_64-unknown-linux-gnu
YAML

  [[ "$(config_get_release_contract_json contract-tool)" != "null" ]] &&
    config_validate_release_contract contract-tool
}

test_release_source_dependencies_absent_or_null_are_empty() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
YAML
  [[ "$(config_get_release_source_dependencies_json contract-tool)" == "[]" ]] || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates: null
YAML
  [[ "$(config_get_release_source_dependencies_json contract-tool)" == "[]" ]]
}

test_release_source_dependencies_are_canonical_and_sorted() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/zeta
    relative_path: zeta
    revision: "ffffffffffffffffffffffffffffffffffffffff"
    respect_gitignore: true
  - local_path: /src/alpha
    relative_path: alpha-core
    revision: "1111111111111111111111111111111111111111"
YAML

  local expected
  expected='[{"git_sha":"1111111111111111111111111111111111111111","relative_path":"alpha-core"},{"git_sha":"ffffffffffffffffffffffffffffffffffffffff","relative_path":"zeta"}]'
  [[ "$(config_get_release_source_dependencies_json contract-tool)" == "$expected" ]] || return 1

  expected='[{"git_sha":"1111111111111111111111111111111111111111","local_path":"/src/alpha","relative_path":"alpha-core"},{"git_sha":"ffffffffffffffffffffffffffffffffffffffff","local_path":"/src/zeta","relative_path":"zeta"}]'
  [[ "$(_config_get_release_source_dependency_checkouts_json contract-tool)" == "$expected" ]]
}

test_release_source_dependencies_registry_fallback_and_repo_precedence() {
  release_contract_test_deps_available || return 0
  mkdir -p "$DSR_CONFIG_DIR"
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  contract-tool:
    targets: [linux/amd64]
    sibling_crates:
      - local_path: /src/registry
        relative_path: registry
        revision: "3333333333333333333333333333333333333333"
YAML

  local expected
  expected='[{"git_sha":"3333333333333333333333333333333333333333","relative_path":"registry"}]'
  [[ "$(config_get_release_source_dependencies_json contract-tool)" == "$expected" ]] || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates: null
YAML
  [[ "$(config_get_release_source_dependencies_json contract-tool)" == "[]" ]]
}

test_release_source_dependencies_reject_missing_revision() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/alpha
    relative_path: alpha
YAML

  ! config_get_release_source_dependencies_json contract-tool >/dev/null
}

test_release_source_dependencies_require_absolute_nonroot_local_path() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: relative/alpha
    relative_path: alpha
    revision: "1111111111111111111111111111111111111111"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /
    relative_path: alpha
    revision: "1111111111111111111111111111111111111111"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null
}

test_release_source_dependencies_reject_unsafe_or_duplicate_paths() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/alpha
    relative_path: ../alpha
    revision: "1111111111111111111111111111111111111111"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/alpha
    relative_path: shared
    revision: "1111111111111111111111111111111111111111"
  - local_path: /src/beta
    relative_path: shared
    revision: "2222222222222222222222222222222222222222"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null
}

test_release_source_dependencies_reject_nonportable_path_aliases() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/alpha-upper
    relative_path: Alpha
    revision: "1111111111111111111111111111111111111111"
  - local_path: /src/alpha-lower
    relative_path: alpha
    revision: "2222222222222222222222222222222222222222"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/trailing-dot
    relative_path: alias.
    revision: "1111111111111111111111111111111111111111"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/device
    relative_path: CON.txt
    revision: "1111111111111111111111111111111111111111"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null
}

test_config_validate_rejects_invalid_strict_release_dependency() {
  release_contract_test_deps_available || return 0
  config_init
  config_load
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/alpha
    relative_path: alpha
    revision: ABCDEF1111111111111111111111111111111111
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML

  ! config_validate
}

test_release_contract_registry_false_is_rejected() {
  mkdir -p "$DSR_CONFIG_DIR"
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  contract-tool:
    targets: [linux/amd64]
    release_contract: false
YAML

  ! config_get_release_contract_json contract-tool >/dev/null &&
    ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_multiple_yaml_documents() {
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
---
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML

  ! config_get_release_contract_json contract-tool >/dev/null &&
    ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_non_mapping_yaml_roots() {
  write_contract_tool_config << 'YAML'
contract-tool
YAML
  ! config_get_release_contract_json contract-tool >/dev/null || return 1

  write_contract_tool_config << 'YAML'
- contract-tool
- linux/amd64
YAML
  ! config_get_release_contract_json contract-tool >/dev/null
}

test_release_contract_rejects_duplicate_yaml_keys() {
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract: null
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML
  ! config_get_release_contract_json contract-tool >/dev/null || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  checksum_sidecar: sha512
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML
  ! config_get_release_contract_json contract-tool >/dev/null
}

test_config_validate_rejects_invalid_repo_release_contract() {
  config_init
  config_load
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract: false
YAML

  ! config_validate
}

test_config_validate_rejects_invalid_registry_release_contract() {
  config_init
  config_load
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  contract-tool:
    targets: [linux/amd64]
    release_contract: false
YAML

  ! config_validate
}

test_config_validate_rejects_non_mapping_registry_tools() {
  config_init
  config_load
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools: []
YAML

  ! config_validate
}

test_release_contract_rejects_non_mapping_registry_tool() {
  mkdir -p "$DSR_CONFIG_DIR"
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  contract-tool: false
YAML

  ! config_get_release_contract_json contract-tool >/dev/null &&
    ! config_validate_release_contract contract-tool
}

test_config_validate_rejects_shadowed_non_mapping_registry_tool() {
  config_init
  config_load
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  contract-tool: false
YAML
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract: null
YAML

  ! config_validate
}

test_release_contract_rejects_non_sha256_sidecar() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha512
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_missing_target() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64, darwin/arm64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_extra_target() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
    windows/amd64: contract-tool-windows-amd64.exe
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_duplicate_primary_names() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64, darwin/arm64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool
    darwin/arm64: contract-tool
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_empty_primary_name() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: ""
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_unsafe_primary_name() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: "contract-tool;touch"
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_primary_path() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: dir/contract-tool
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_dotdot_primary() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool..exe
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_checksum_as_primary() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool.sha256
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_unsupported_mode() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  mode: exact
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_duplicate_configured_target() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64, linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML
  ! config_validate_release_contract contract-tool
}

# ============================================================================
# Tests: Edge Cases
# ============================================================================

test_load_handles_empty_config() {
  config_init
  # Create empty config file
  : > "$DSR_CONFIG_FILE"
  config_load  # Should not crash
  [[ -n "${DSR_CONFIG[threshold_seconds]:-}" ]]  # Defaults still applied
}

test_load_handles_comments() {
  config_init
  cat > "$DSR_CONFIG_FILE" << 'EOF'
# This is a comment
schema_version: "1.0.0"
# Another comment
threshold_seconds: 300
EOF
  config_load
  [[ "${DSR_CONFIG[threshold_seconds]}" == "300" ]]
}

test_load_handles_quoted_values() {
  config_init
  cat > "$DSR_CONFIG_FILE" << 'EOF'
schema_version: "1.0.0"
quoted_key: "quoted value"
single_quoted: 'single quoted'
EOF
  config_load
  [[ "${DSR_CONFIG[quoted_key]}" == "quoted value" ]] && \
  [[ "${DSR_CONFIG[single_quoted]}" == "single quoted" ]]
}

test_config_file_env_override() {
  config_init
  local custom_config="$TEMP_DIR/custom.yaml"
  cat > "$custom_config" << 'EOF'
schema_version: "1.0.0"
threshold_seconds: 9999
EOF
  export DSR_CONFIG_FILE="$custom_config"
  config_load
  local result="${DSR_CONFIG[threshold_seconds]}"
  unset DSR_CONFIG_FILE
  [[ "$result" == "9999" ]]
}

# ============================================================================
# Main Test Runner
# ============================================================================

main() {
  echo "=== config.sh Tests ==="
  echo ""

  if ! release_contract_test_deps_available; then
    echo "ERROR: release-contract tests require both yq and jq"
    return 1
  fi

  echo "Initialization Tests:"
  run_test "init_creates_config_dir" test_init_creates_config_dir
  run_test "init_creates_cache_dir" test_init_creates_cache_dir
  run_test "init_creates_state_dir" test_init_creates_state_dir
  run_test "init_creates_subdirs" test_init_creates_subdirs
  run_test "init_creates_config_yaml" test_init_creates_config_yaml
  run_test "init_creates_hosts_yaml" test_init_creates_hosts_yaml
  run_test "init_creates_repos_yaml" test_init_creates_repos_yaml
  run_test "init_no_overwrite" test_init_no_overwrite
  run_test "init_force_overwrites" test_init_force_overwrites
  run_test "init_config_has_schema_version" test_init_config_has_schema_version
  run_test "init_hosts_has_hosts" test_init_hosts_has_hosts
  run_test "init_repos_has_tools" test_init_repos_has_tools

  echo ""
  echo "Loading Tests:"
  run_test "load_sets_defaults" test_load_sets_defaults
  run_test "load_default_threshold" test_load_default_threshold
  run_test "load_default_log_level" test_load_default_log_level
  run_test "load_reads_config_file" test_load_reads_config_file
  run_test "load_env_overrides_file" test_load_env_overrides_file
  run_test "load_threshold_env_override" test_load_threshold_env_override
  run_test "load_signing_disabled_by_env" test_load_signing_disabled_by_env
  run_test "load_resets_config" test_load_resets_config

  echo ""
  echo "Get/Set Tests:"
  run_test "get_returns_value" test_get_returns_value
  run_test "get_returns_default" test_get_returns_default
  run_test "get_returns_empty_for_missing" test_get_returns_empty_for_missing
  run_test "set_updates_value" test_set_updates_value
  run_test "set_creates_new_key" test_set_creates_new_key
  run_test "set_persist_requires_yq" test_set_persist_requires_yq

  echo ""
  echo "Validation Tests:"
  run_test "validate_passes_with_init" test_validate_passes_with_init
  run_test "validate_fails_missing_dir" test_validate_fails_missing_dir
  run_test "validate_checks_schema_version" test_validate_checks_schema_version

  echo ""
  echo "Show Tests:"
  run_test "show_human_output" test_show_human_output
  run_test "show_json_output" test_show_json_output
  run_test "show_specific_key" test_show_specific_key
  run_test "show_json_specific_key" test_show_json_specific_key

  echo ""
  echo "XDG Compliance Tests:"
  run_test "xdg_config_home_override" test_xdg_config_home_override
  run_test "xdg_cache_home_override" test_xdg_cache_home_override
  run_test "xdg_state_home_override" test_xdg_state_home_override

  echo ""
  echo "Host/Tool Configuration Tests:"
  run_test "get_host_for_platform_linux" test_get_host_for_platform_linux
  run_test "get_host_for_platform_darwin" test_get_host_for_platform_darwin
  run_test "get_host_for_platform_windows" test_get_host_for_platform_windows
  run_test "list_hosts_returns_hosts" test_list_hosts_returns_hosts
  run_test "get_host_returns_config" test_get_host_returns_config

  echo ""
  echo "Release Contract Tests:"
  run_test "release_contract_absent_is_legacy_compatible" test_release_contract_absent_is_legacy_compatible
  run_test "release_contract_null_is_legacy_compatible" test_release_contract_null_is_legacy_compatible
  run_test "release_contract_rejects_non_object" test_release_contract_rejects_non_object
  run_test "release_contract_valid_is_canonical_json" test_release_contract_valid_is_canonical_json
  run_test "release_contract_registry_fallback" test_release_contract_registry_fallback
  run_test "release_source_dependencies_absent_or_null_are_empty" test_release_source_dependencies_absent_or_null_are_empty
  run_test "release_source_dependencies_are_canonical_and_sorted" test_release_source_dependencies_are_canonical_and_sorted
  run_test "release_source_dependencies_registry_fallback_and_repo_precedence" test_release_source_dependencies_registry_fallback_and_repo_precedence
  run_test "release_source_dependencies_reject_missing_revision" test_release_source_dependencies_reject_missing_revision
  run_test "release_source_dependencies_require_absolute_nonroot_local_path" test_release_source_dependencies_require_absolute_nonroot_local_path
  run_test "release_source_dependencies_reject_unsafe_or_duplicate_paths" test_release_source_dependencies_reject_unsafe_or_duplicate_paths
  run_test "release_source_dependencies_reject_nonportable_path_aliases" test_release_source_dependencies_reject_nonportable_path_aliases
  run_test "config_validate_rejects_invalid_strict_release_dependency" test_config_validate_rejects_invalid_strict_release_dependency
  run_test "release_contract_registry_false_is_rejected" test_release_contract_registry_false_is_rejected
  run_test "release_contract_rejects_multiple_yaml_documents" test_release_contract_rejects_multiple_yaml_documents
  run_test "release_contract_rejects_non_mapping_yaml_roots" test_release_contract_rejects_non_mapping_yaml_roots
  run_test "release_contract_rejects_duplicate_yaml_keys" test_release_contract_rejects_duplicate_yaml_keys
  run_test "config_validate_rejects_invalid_repo_release_contract" test_config_validate_rejects_invalid_repo_release_contract
  run_test "config_validate_rejects_invalid_registry_release_contract" test_config_validate_rejects_invalid_registry_release_contract
  run_test "config_validate_rejects_non_mapping_registry_tools" test_config_validate_rejects_non_mapping_registry_tools
  run_test "release_contract_rejects_non_mapping_registry_tool" test_release_contract_rejects_non_mapping_registry_tool
  run_test "config_validate_rejects_shadowed_non_mapping_registry_tool" test_config_validate_rejects_shadowed_non_mapping_registry_tool
  run_test "release_contract_rejects_non_sha256_sidecar" test_release_contract_rejects_non_sha256_sidecar
  run_test "release_contract_rejects_missing_target" test_release_contract_rejects_missing_target
  run_test "release_contract_rejects_extra_target" test_release_contract_rejects_extra_target
  run_test "release_contract_rejects_duplicate_primary_names" test_release_contract_rejects_duplicate_primary_names
  run_test "release_contract_rejects_empty_primary_name" test_release_contract_rejects_empty_primary_name
  run_test "release_contract_rejects_unsafe_primary_name" test_release_contract_rejects_unsafe_primary_name
  run_test "release_contract_rejects_primary_path" test_release_contract_rejects_primary_path
  run_test "release_contract_rejects_dotdot_primary" test_release_contract_rejects_dotdot_primary
  run_test "release_contract_rejects_checksum_as_primary" test_release_contract_rejects_checksum_as_primary
  run_test "release_contract_rejects_unsupported_mode" test_release_contract_rejects_unsupported_mode
  run_test "release_contract_rejects_duplicate_configured_target" test_release_contract_rejects_duplicate_configured_target

  echo ""
  echo "Edge Case Tests:"
  run_test "load_handles_empty_config" test_load_handles_empty_config
  run_test "load_handles_comments" test_load_handles_comments
  run_test "load_handles_quoted_values" test_load_handles_quoted_values
  run_test "config_file_env_override" test_config_file_env_override

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
