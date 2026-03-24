#!/usr/bin/env bash
# test_e2e_release_parity_helpers.sh - Unit tests for e2e_release_parity helpers
#
# Run:
#   ./scripts/tests/test_e2e_release_parity_helpers.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/tests/helpers/test_harness.bash"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() { ((TESTS_PASSED++)); echo "PASS: $1"; }
fail() { ((TESTS_FAILED++)); echo "FAIL: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "SKIP: $1"; }

harness_setup
trap 'TEST_EXIT_CODE=$?; harness_teardown' EXIT

if ! require_command jq "jq" "Install jq"; then
  skip "jq missing"
  exit 0
fi
if ! require_command yq "yq" "Install yq"; then
  skip "yq missing"
  exit 0
fi

export DSR_E2E_SOURCE_ONLY=1
source "$PROJECT_ROOT/scripts/tests/e2e_release_parity.sh"

test_parse_scenarios() {
  ((TESTS_RUN++))
  local output expected
  output=$(parse_scenarios "base,prebuilt multi_variant")
  expected=$'base\nprebuilt\nmulti_variant'
  if [[ "$output" == "$expected" ]]; then
    pass "parse_scenarios handles commas and spaces"
  else
    fail "parse_scenarios output mismatch: $output"
  fi
}

test_ext_from_pattern() {
  ((TESTS_RUN++))
  local ext1 ext2 ext3
  ext1=$(_ext_from_pattern 'tool-${version}-linux-amd64.tar.xz')
  ext2=$(_ext_from_pattern 'tool-${version}-windows-amd64.zip')
  ext3=$(_ext_from_pattern 'tool-${version}-linux-amd64')
  if [[ "$ext1" == "tar.xz" && "$ext2" == "zip" && -z "$ext3" ]]; then
    pass "_ext_from_pattern handles tar.xz and zip"
  else
    fail "_ext_from_pattern unexpected: $ext1 / $ext2 / $ext3"
  fi
}

test_resolve_naming_ext() {
  ((TESTS_RUN++))
  local ext_win ext_linux
  ext_win=$(resolve_naming_ext "binary" "windows")
  ext_linux=$(resolve_naming_ext "binary" "linux")
  if [[ "$ext_win" == "exe" && -z "$ext_linux" ]]; then
    pass "resolve_naming_ext maps binary formats correctly"
  else
    fail "resolve_naming_ext unexpected: win=$ext_win linux=$ext_linux"
  fi
}

test_list_target_triples() {
  ((TESTS_RUN++))
  mkdir -p "$DSR_CONFIG_DIR/repos.d"
  cat > "$DSR_CONFIG_DIR/repos.d/mock_release_tool.yaml" << 'YAML'
target_triples:
  "linux/amd64":
    - x86_64-unknown-linux-gnu
    - x86_64-unknown-linux-musl
YAML

  mapfile -t triples < <(list_target_triples "mock_release_tool" "linux/amd64")
  if [[ "${#triples[@]}" -eq 2 && "${triples[0]}" == "x86_64-unknown-linux-gnu" ]]; then
    pass "list_target_triples reads list from config"
  else
    fail "list_target_triples unexpected: ${triples[*]}"
  fi
}

test_expected_assets_for_version() {
  ((TESTS_RUN++))
  # shellcheck disable=SC2034 # Used indirectly by sourced e2e_release_parity helpers.
  TOOL_NAME="mock_release_tool"
  LOCAL_PATH="$PROJECT_ROOT/scripts/tests/fixtures/mock_release_tool"
  TARGETS="linux/amd64"

  cat > "$DSR_CONFIG_DIR/repos.d/mock_release_tool.yaml" << 'YAML'
artifact_naming: "${name}-${version}-${target_triple}"
install_script_compat: "${name}-${target_triple}"
install_script_path: install.sh
archive_format:
  linux: tar.xz
target_triples:
  "linux/amd64":
    - x86_64-unknown-linux-gnu
    - x86_64-unknown-linux-musl
YAML

  local output
  output=$(expected_assets_for_version "v1.2.3" "$LOCAL_PATH" "$TARGETS")
  if echo "$output" | grep -q "mock_release_tool-1.2.3-x86_64-unknown-linux-gnu.tar.xz" && \
     echo "$output" | grep -q "mock_release_tool-1.2.3-x86_64-unknown-linux-musl.tar.xz"; then
    pass "expected_assets_for_version includes target triples"
  else
    fail "expected_assets_for_version missing target triples: $output"
  fi
}

test_parse_scenarios
test_ext_from_pattern
test_resolve_naming_ext
test_list_target_triples
test_expected_assets_for_version

if [[ "$TESTS_FAILED" -gt 0 ]]; then
  exit 1
fi

exit 0
