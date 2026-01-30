#!/usr/bin/env bash
# test_harness.bash - Core test harness for all dsr tests
#
# Provides:
#   - Isolated test environment (config, state, cache dirs)
#   - Time and random mocking for deterministic tests
#   - Log capture for debugging failures
#   - Automatic cleanup (unless DEBUG=1)
#
# Usage in tests:
#   source test_harness.bash
#   harness_setup  # Call in setup()
#   # ... run tests ...
#   harness_teardown  # Call in teardown()

set -uo pipefail

# Get the directory containing this script
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"

# Load all helper modules
source "$HARNESS_DIR/mock_time.bash"
source "$HARNESS_DIR/mock_random.bash"
source "$HARNESS_DIR/log_capture.bash"
source "$HARNESS_DIR/mock_common.bash"

# Export project root for tests
export DSR_PROJECT_ROOT="$PROJECT_ROOT"

# Test state
_HARNESS_TMPDIR=""
_HARNESS_START_TIME=""
_HARNESS_TEST_NAME=""

# Global test setup
# Call this at the beginning of each test or in a setup() function
harness_setup() {
  # Get test name if available (from bats or manual)
  _HARNESS_TEST_NAME="${BATS_TEST_NAME:-${TEST_NAME:-unknown}}"

  # Record start time
  _HARNESS_START_TIME=$(date +%s)

  # Create isolated test environment
  _HARNESS_TMPDIR="$(mktemp -d)"

  # Set up isolated XDG directories
  export TEST_TMPDIR="$_HARNESS_TMPDIR"
  export DSR_CONFIG_DIR="$_HARNESS_TMPDIR/config"
  export DSR_STATE_DIR="$_HARNESS_TMPDIR/state"
  export DSR_CACHE_DIR="$_HARNESS_TMPDIR/cache"

  # Also set XDG vars for dsr compatibility
  export XDG_CONFIG_HOME="$_HARNESS_TMPDIR/xdg_config"
  export XDG_STATE_HOME="$_HARNESS_TMPDIR/xdg_state"
  export XDG_CACHE_HOME="$_HARNESS_TMPDIR/xdg_cache"

  # Create directories
  mkdir -p "$DSR_CONFIG_DIR" "$DSR_STATE_DIR" "$DSR_CACHE_DIR"
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

  # Generate deterministic run ID
  mock_random_seed 42
  export DSR_RUN_ID="$(mock_run_id)"

  # Initialize log capture
  log_capture_init "$_HARNESS_TMPDIR/test.log"

  # Freeze time to known value (noon on Jan 30, 2026)
  mock_time_freeze "2026-01-30T12:00:00Z"

  # Reset random after using it for run ID
  mock_random_seed 42

  # Log test start
  log_capture_write "=== Test: $_HARNESS_TEST_NAME ==="
  log_capture_write "=== Run ID: $DSR_RUN_ID ==="
  log_capture_write "=== Started: $(date -Iseconds) ==="
  log_capture_write ""
}

# Global test teardown
# Call this at the end of each test or in a teardown() function
harness_teardown() {
  local exit_code="${BATS_ERROR_STATUS:-${TEST_EXIT_CODE:-0}}"
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - _HARNESS_START_TIME))

  # Log test end
  log_capture_write ""
  log_capture_write "=== Ended: $(date -Iseconds) ==="
  log_capture_write "=== Duration: ${duration}s ==="
  log_capture_write "=== Exit: $exit_code ==="

  # On failure, dump logs for debugging
  if [[ "$exit_code" -ne 0 ]]; then
    echo "" >&2
    echo "=== TEST FAILED: $_HARNESS_TEST_NAME ===" >&2
    log_capture_dump
    echo "=== END TEST FAILURE ===" >&2
    echo "" >&2
  fi

  # Restore mocks
  mock_time_restore
  mock_time_restore_date 2>/dev/null || true
  mock_random_reset
  mock_cleanup

  # Cleanup log capture
  log_capture_cleanup

  # Remove temp directory (unless DEBUG mode)
  if [[ -z "${DEBUG:-}" ]]; then
    if [[ -d "$_HARNESS_TMPDIR" ]]; then
      rm -rf "$_HARNESS_TMPDIR"
    fi
  else
    echo "DEBUG: Test artifacts preserved at $_HARNESS_TMPDIR" >&2
  fi

  _HARNESS_TMPDIR=""
}

# Get the temp directory for this test
harness_tmpdir() {
  echo "$_HARNESS_TMPDIR"
}

# Create a file in the test temp directory
# Args: relative_path content
harness_create_file() {
  local path="$1"
  local content="${2:-}"
  local full_path="$_HARNESS_TMPDIR/$path"

  mkdir -p "$(dirname "$full_path")"
  echo "$content" > "$full_path"
  echo "$full_path"
}

# Create a minimal dsr config for testing
harness_create_config() {
  mkdir -p "$DSR_CONFIG_DIR"

  cat > "$DSR_CONFIG_DIR/config.yaml" << 'EOF'
schema_version: "1.0.0"
threshold_seconds: 600
default_targets:
  - linux/amd64
  - darwin/arm64
signing:
  enabled: false
log_level: debug
EOF

  cat > "$DSR_CONFIG_DIR/hosts.yaml" << 'EOF'
hosts:
  trj:
    platform: linux/amd64
    connection: local
  mmini:
    platform: darwin/arm64
    connection: ssh
    ssh_host: mmini
  wlap:
    platform: windows/amd64
    connection: ssh
    ssh_host: wlap
EOF

  cat > "$DSR_CONFIG_DIR/repos.yaml" << 'EOF'
tools:
  test-tool:
    repo: test/test-tool
    local_path: /tmp/test-tool
    language: go
    targets:
      - linux/amd64
EOF
}

# Run dsr command in test environment
# Args: dsr arguments...
harness_run_dsr() {
  "$PROJECT_ROOT/dsr" "$@"
}

# Source a dsr module for testing
# Args: module_name (e.g., "config", "signing")
harness_source_module() {
  local module="$1"
  source "$PROJECT_ROOT/src/${module}.sh"
}

# Assert helper functions for simple test frameworks
# These complement bats assertions

# Assert that a command succeeds
# Args: command [args...]
assert_success() {
  if ! "$@"; then
    echo "FAIL: Command should succeed: $*" >&2
    return 1
  fi
}

# Assert that a command fails
# Args: command [args...]
assert_failure() {
  if "$@"; then
    echo "FAIL: Command should fail: $*" >&2
    return 1
  fi
}

# Assert string equality
# Args: expected actual [message]
assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="${3:-Values should be equal}"

  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: $message" >&2
    echo "  Expected: $expected" >&2
    echo "  Actual:   $actual" >&2
    return 1
  fi
}

# Assert string contains substring
# Args: string substring [message]
assert_contains() {
  local string="$1"
  local substring="$2"
  local message="${3:-String should contain substring}"

  if [[ "$string" != *"$substring"* ]]; then
    echo "FAIL: $message" >&2
    echo "  String:    $string" >&2
    echo "  Substring: $substring" >&2
    return 1
  fi
}

# Assert file exists
# Args: path [message]
assert_file_exists() {
  local path="$1"
  local message="${2:-File should exist: $path}"

  if [[ ! -f "$path" ]]; then
    echo "FAIL: $message" >&2
    return 1
  fi
}

# Assert directory exists
# Args: path [message]
assert_dir_exists() {
  local path="$1"
  local message="${2:-Directory should exist: $path}"

  if [[ ! -d "$path" ]]; then
    echo "FAIL: $message" >&2
    return 1
  fi
}

# Export functions
export -f harness_setup harness_teardown harness_tmpdir
export -f harness_create_file harness_create_config
export -f harness_run_dsr harness_source_module
export -f assert_success assert_failure assert_equal assert_contains
export -f assert_file_exists assert_dir_exists

# Export variables
export HARNESS_DIR PROJECT_ROOT DSR_PROJECT_ROOT
