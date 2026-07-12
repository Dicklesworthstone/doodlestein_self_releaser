#!/usr/bin/env bash
# test_repos_validate.sh - Tests for dsr repos validate (including GoReleaser compatibility)
#
# Covers:
# - Target matrix comparison
# - Archive format matching
# - Artifact naming template matching
# - Missing repo/local_path errors

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test harness
source "$PROJECT_ROOT/tests/helpers/test_harness.bash"

# Test state
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Suppress colors for consistent output
export NO_COLOR=1

pass() { ((TESTS_PASSED++)); echo "PASS: $1"; }
fail() { ((TESTS_FAILED++)); echo "FAIL: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "SKIP: $1"; }

write_goreleaser_config() {
  local repo_dir="$1"
  local name_template="$2"
  local format="$3"
  local goos_list="$4"
  local goarch_list="$5"

  mkdir -p "$repo_dir"
  cat > "$repo_dir/.goreleaser.yaml" <<EOF_GORELEASER
project_name: testtool
builds:
  - goos: [$goos_list]
    goarch: [$goarch_list]
archives:
  - name_template: "$name_template"
    format: $format
EOF_GORELEASER
}

write_repos_yaml() {
  local tool_name="$1"
  local repo_path="$2"
  local artifact_pattern="$3"
  local linux_format="$4"
  local darwin_format="$5"
  shift 5
  local targets=("$@")

  mkdir -p "$DSR_CONFIG_DIR"
  {
    echo "tools:"
    echo "  $tool_name:"
    echo "    repo: example/$tool_name"
    echo "    local_path: $repo_path"
    echo "    language: go"
    echo "    targets:"
    for target in "${targets[@]}"; do
      echo "      - $target"
    done
    echo "    artifact_naming: \"$artifact_pattern\""
    echo "    archive_format:"
    echo "      linux: $linux_format"
    echo "      darwin: $darwin_format"
  } > "$DSR_CONFIG_DIR/repos.yaml"
}

run_validate() {
  local tool_name="$1"
  exec_run "$PROJECT_ROOT/dsr" --json repos validate "$tool_name"
  return 0
}

json_status() {
  echo "$(exec_stdout)" | jq -r '.details.validated[0].status'
}

json_message() {
  echo "$(exec_stdout)" | jq -r '.details.validated[0].message'
}

# ==========================================================================
# Tests
# ==========================================================================

test_validate_ok_with_matching_goreleaser() {
  if ! require_command yq "yq" "Install yq: brew install yq" 2>/dev/null; then
    return 2
  fi
  if ! require_command jq "jq" "Install jq: brew install jq" 2>/dev/null; then
    return 2
  fi

  local tool_name="testtool"
  local repo_dir
  repo_dir="$(harness_tmpdir)/repo"

  write_goreleaser_config "$repo_dir" "{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}" "tar.gz" "linux, darwin" "amd64"

  local artifact_pattern='${name}_${version}_${os}_${arch}'
  write_repos_yaml "$tool_name" "$repo_dir" "$artifact_pattern" "tar.gz" "tar.gz" \
    "linux/amd64" "darwin/amd64"

  run_validate "$tool_name"

  local status
  status=$(json_status)
  if [[ "$status" == "ok" ]]; then
    return 0
  fi

  echo "Unexpected status: $status" >&2
  echo "Message: $(json_message)" >&2
  return 1
}

test_validate_windows_arm64_target_triple() {
  if ! require_command yq "yq" "Install yq: brew install yq" 2>/dev/null; then
    return 2
  fi
  if ! require_command jq "jq" "Install jq: brew install jq" 2>/dev/null; then
    return 2
  fi

  local tool_name="testtool"
  local repo_dir
  repo_dir="$(harness_tmpdir)/repo"

  write_goreleaser_config "$repo_dir" "{{ .ProjectName }}_{{ .Version }}_aarch64-pc-windows-msvc" "zip" "windows" "arm64"

  mkdir -p "$DSR_CONFIG_DIR"
  cat > "$DSR_CONFIG_DIR/repos.yaml" <<EOF_REPOS
tools:
  $tool_name:
    repo: example/$tool_name
    local_path: $repo_dir
    language: go
    binary_name: testtool
    targets:
      - windows/arm64
    artifact_naming: "\${name}_\${version}_\${target_triple}"
    archive_format:
      windows: zip
EOF_REPOS

  run_validate "$tool_name"

  local status
  status=$(json_status)
  if [[ "$status" == "ok" ]]; then
    return 0
  fi

  echo "Unexpected status: $status" >&2
  echo "Message: $(json_message)" >&2
  return 1
}

test_validate_target_mismatch_warns() {
  if ! require_command yq "yq" "Install yq: brew install yq" 2>/dev/null; then
    return 2
  fi
  if ! require_command jq "jq" "Install jq: brew install jq" 2>/dev/null; then
    return 2
  fi

  local tool_name="testtool"
  local repo_dir
  repo_dir="$(harness_tmpdir)/repo"

  write_goreleaser_config "$repo_dir" "{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}" "tar.gz" "linux, darwin" "amd64"

  local artifact_pattern='${name}_${version}_${os}_${arch}'
  write_repos_yaml "$tool_name" "$repo_dir" "$artifact_pattern" "tar.gz" "tar.gz" \
    "linux/amd64"

  run_validate "$tool_name"

  local status message
  status=$(json_status)
  message=$(json_message)
  if [[ "$status" == "warn" && "$message" == *"Targets missing in dsr config"* ]]; then
    return 0
  fi

  echo "Unexpected status/message: $status / $message" >&2
  return 1
}

test_validate_archive_format_mismatch_warns() {
  if ! require_command yq "yq" "Install yq: brew install yq" 2>/dev/null; then
    return 2
  fi
  if ! require_command jq "jq" "Install jq: brew install jq" 2>/dev/null; then
    return 2
  fi

  local tool_name="testtool"
  local repo_dir
  repo_dir="$(harness_tmpdir)/repo"

  write_goreleaser_config "$repo_dir" "{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}" "zip" "linux" "amd64"

  local artifact_pattern='${name}_${version}_${os}_${arch}'
  write_repos_yaml "$tool_name" "$repo_dir" "$artifact_pattern" "tar.gz" "tar.gz" \
    "linux/amd64"

  run_validate "$tool_name"

  local status message
  status=$(json_status)
  message=$(json_message)
  if [[ "$status" == "warn" && "$message" == *"Archive format mismatch"* ]]; then
    return 0
  fi

  echo "Unexpected status/message: $status / $message" >&2
  return 1
}

test_validate_name_template_mismatch_warns() {
  if ! require_command yq "yq" "Install yq: brew install yq" 2>/dev/null; then
    return 2
  fi
  if ! require_command jq "jq" "Install jq: brew install jq" 2>/dev/null; then
    return 2
  fi

  local tool_name="testtool"
  local repo_dir
  repo_dir="$(harness_tmpdir)/repo"

  write_goreleaser_config "$repo_dir" "{{ .ProjectName }}-{{ .Version }}-{{ .Os }}-{{ .Arch }}" "tar.gz" "linux" "amd64"

  local artifact_pattern='${name}_${version}_${os}_${arch}'
  write_repos_yaml "$tool_name" "$repo_dir" "$artifact_pattern" "tar.gz" "tar.gz" \
    "linux/amd64"

  run_validate "$tool_name"

  local status message
  status=$(json_status)
  message=$(json_message)
  if [[ "$status" == "warn" && "$message" == *"Artifact name mismatch"* ]]; then
    return 0
  fi

  echo "Unexpected status/message: $status / $message" >&2
  return 1
}

test_validate_missing_repo_and_path_errors() {
  if ! require_command yq "yq" "Install yq: brew install yq" 2>/dev/null; then
    return 2
  fi
  if ! require_command jq "jq" "Install jq: brew install jq" 2>/dev/null; then
    return 2
  fi

  local tool_name="testtool"

  mkdir -p "$DSR_CONFIG_DIR"
  cat > "$DSR_CONFIG_DIR/repos.yaml" <<EOF_REPOS
tools:
  $tool_name:
    language: go
EOF_REPOS

  run_validate "$tool_name"

  local status message
  status=$(json_status)
  message=$(json_message)
  if [[ "$status" == "error" && "$message" == *"Missing both 'repo' and 'local_path'"* ]]; then
    return 0
  fi

  echo "Unexpected status/message: $status / $message" >&2
  return 1
}

run_test() {
  local name="$1"
  local func="$2"

  ((TESTS_RUN++))
  # shellcheck disable=SC2034  # Used by test_harness for logging
  TEST_NAME="$name"
  harness_setup

  if $func; then
    # shellcheck disable=SC2034  # Used by test_harness for failure logging
    TEST_EXIT_CODE=0
    pass "$name"
  else
    local rc=$?
    if [[ $rc -eq 2 ]]; then
      # shellcheck disable=SC2034  # Used by test_harness for failure logging
      TEST_EXIT_CODE=0
      skip "$name (prereqs missing)"
    else
      # shellcheck disable=SC2034  # Used by test_harness for failure logging
      TEST_EXIT_CODE=1
      fail "$name"
    fi
  fi

  harness_teardown
}

main() {
  run_test "validate_ok_with_matching_goreleaser" test_validate_ok_with_matching_goreleaser
  run_test "validate_windows_arm64_target_triple" test_validate_windows_arm64_target_triple
  run_test "validate_target_mismatch_warns" test_validate_target_mismatch_warns
  run_test "validate_archive_format_mismatch_warns" test_validate_archive_format_mismatch_warns
  run_test "validate_name_template_mismatch_warns" test_validate_name_template_mismatch_warns
  run_test "validate_missing_repo_and_path_errors" test_validate_missing_repo_and_path_errors

  echo ""
  echo "Tests run: $TESTS_RUN"
  echo "Passed:    $TESTS_PASSED"
  echo "Skipped:   $TESTS_SKIPPED"
  echo "Failed:    $TESTS_FAILED"

  if [[ $TESTS_FAILED -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
