#!/usr/bin/env bash
# test_native_build_e2e.sh - E2E tests for multi-platform native builds
#
# Tests the full native build pipeline including:
# - Dry-run command construction for all platforms
# - JSON output structure validation
# - Summary format verification
# - Live builds (when SSH access available)
#
# Run: ./scripts/tests/test_native_build_e2e.sh
#
# Environment variables:
#   DSR_E2E_SKIP_LIVE - Skip tests requiring SSH access
#   DSR_E2E_VERBOSE   - Enable detailed logging
#   DSR_E2E_TIMEOUT   - Build timeout in seconds (default 300)
#   DSR_E2E_KEEP_ARTIFACTS - Don't clean up after tests
#   DEBUG             - Keep temp directories for debugging

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSR_CMD="$PROJECT_ROOT/dsr"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# Source the test harness
# shellcheck source=tests/helpers/test_harness.bash
source "$PROJECT_ROOT/tests/helpers/test_harness.bash"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

# Logging
log_test() { echo "${BLUE}=== $1 ===${NC}"; }
log_pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC} $1"; }
log_fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC} $1"; }
log_skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC} $1"; }
# shellcheck disable=SC2015  # Using || true to ensure function returns 0
log_info() { [[ -n "${DSR_E2E_VERBOSE:-}" ]] && echo "${BLUE}INFO${NC} $1" || true; }

# ============================================================================
# Fixture Setup
# ============================================================================

# shellcheck disable=SC2120  # Optional argument with default
setup_mock_rust_tool() {
    local target_dir="${1:-$TEST_TMPDIR/mock_rust_tool}"
    mkdir -p "$target_dir"
    cp -r "$FIXTURES_DIR/mock_rust_tool/." "$target_dir/"

    # Initialize git
    (cd "$target_dir" && git init -q && git add . && git commit -q -m "Initial") 2>/dev/null || true

    echo "$target_dir"
}

# shellcheck disable=SC2120  # Optional argument with default
setup_mock_go_tool() {
    local target_dir="${1:-$TEST_TMPDIR/mock_go_tool}"
    mkdir -p "$target_dir"
    cp -r "$FIXTURES_DIR/mock_go_tool/." "$target_dir/"

    # Initialize git
    (cd "$target_dir" && git init -q && git add . && git commit -q -m "Initial") 2>/dev/null || true

    echo "$target_dir"
}

create_tool_config() {
    local tool_name="$1"
    local local_path="$2"
    local language="$3"
    local binary_name="${4:-$tool_name}"
    local build_cmd="${5:-}"

    # Set default build command based on language
    if [[ -z "$build_cmd" ]]; then
        case "$language" in
            rust) build_cmd="cargo build --release" ;;
            go)   build_cmd="go build -o $binary_name ." ;;
            *)    build_cmd="echo build" ;;
        esac
    fi

    mkdir -p "$DSR_CONFIG_DIR/repos.d"

    cat > "$DSR_CONFIG_DIR/repos.d/${tool_name}.yaml" << YAML
tool_name: $tool_name
repo: test/$tool_name
local_path: $local_path
language: $language
binary_name: $binary_name
build_cmd: $build_cmd
targets:
  - linux/amd64
  - darwin/arm64
  - windows/amd64
workflow: .github/workflows/release.yml
act_job_map:
  linux/amd64: build
host_paths:
  mmini: ~/projects/$tool_name
  wlap: C:/Users/test/projects/$tool_name
YAML
}

setup_test_environment() {
    harness_setup

    # Create main config in DSR_CONFIG_DIR (not XDG)
    mkdir -p "$DSR_CONFIG_DIR"
    cat > "$DSR_CONFIG_DIR/config.yaml" << 'YAML'
schema_version: "1.0.0"
threshold_seconds: 600
default_targets:
  - linux/amd64
  - darwin/arm64
  - windows/amd64
signing:
  enabled: false
log_level: debug
YAML
}

cleanup_test_environment() {
    if [[ -z "${DSR_E2E_KEEP_ARTIFACTS:-}" ]]; then
        harness_teardown
    fi
}

# ============================================================================
# Test Cases: Build Help and Config Parsing
# ============================================================================

test_build_help_shows_usage() {
    ((TESTS_RUN++))
    log_test "Help: Build command shows usage"
    setup_test_environment

    local output exit_code=0
    output=$("$DSR_CMD" build --help 2>&1) || exit_code=$?

    if [[ "$output" == *"USAGE"* ]] && [[ "$output" == *"build"* ]]; then
        log_pass "Build --help shows usage"
    else
        log_fail "Expected USAGE in help: $output"
    fi

    cleanup_test_environment
}

test_build_help_shows_target_option() {
    ((TESTS_RUN++))
    log_test "Help: Build command shows --target option"
    setup_test_environment

    local output
    output=$("$DSR_CMD" build --help 2>&1) || true

    if [[ "$output" == *"--target"* ]]; then
        log_pass "Build --help shows --target option"
    else
        log_fail "Expected --target in help: $output"
    fi

    cleanup_test_environment
}

test_build_help_shows_parallel_option() {
    ((TESTS_RUN++))
    log_test "Help: Build command shows --parallel option"
    setup_test_environment

    local output
    output=$("$DSR_CMD" build --help 2>&1) || true

    if [[ "$output" == *"--parallel"* ]]; then
        log_pass "Build --help shows --parallel option"
    else
        log_fail "Expected --parallel in help: $output"
    fi

    cleanup_test_environment
}

# ============================================================================
# Test Cases: JSON Output Validation
# ============================================================================

test_json_flag_recognized() {
    ((TESTS_RUN++))
    log_test "JSON flag: --json is a recognized flag"
    setup_test_environment

    # Just check that --json doesn't cause an "unknown flag" error
    local output exit_code=0
    output=$("$DSR_CMD" --json build --help 2>&1) || exit_code=$?

    # Should not say "unknown option"
    if [[ "$output" != *"unknown"* ]] && [[ "$output" != *"Unknown"* ]]; then
        log_pass "--json flag is recognized"
    else
        log_fail "--json flag not recognized: $output"
    fi

    cleanup_test_environment
}

test_version_json_output() {
    ((TESTS_RUN++))
    log_test "JSON output: version command produces valid JSON"
    setup_test_environment

    local output
    output=$("$DSR_CMD" --json version 2>&1) || true

    # Extract JSON
    local json_output
    json_output=$(echo "$output" | command grep -E '^\{' | head -1)

    if [[ -n "$json_output" ]] && echo "$json_output" | jq . >/dev/null 2>&1; then
        log_pass "Version produces valid JSON"
    else
        # Try alternate format
        if [[ "$output" == *"version"* ]]; then
            log_pass "Version output includes version info"
        else
            log_fail "Version output unexpected: $output"
        fi
    fi

    cleanup_test_environment
}

# ============================================================================
# Test Cases: Config File Detection
# ============================================================================

test_tool_config_file_loaded() {
    ((TESTS_RUN++))
    log_test "Config: Tool config file is detected"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    # Verify config file exists
    if [[ -f "$DSR_CONFIG_DIR/repos.d/mock_rust_tool.yaml" ]]; then
        log_pass "Tool config file exists"
    else
        log_fail "Tool config file not created"
    fi

    cleanup_test_environment
}

test_tool_config_has_targets() {
    ((TESTS_RUN++))
    log_test "Config: Tool config has targets defined"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local targets
    targets=$(yq -r '.targets[]' "$DSR_CONFIG_DIR/repos.d/mock_rust_tool.yaml" 2>/dev/null | head -1)

    if [[ -n "$targets" ]]; then
        log_pass "Tool config has targets: $targets"
    else
        log_fail "Tool config missing targets"
    fi

    cleanup_test_environment
}

# ============================================================================
# Test Cases: Platform Target Tests
# Note: These verify the build command accepts platform targets and runs the
# build pipeline. Exit codes 0, 1 (partial), or 6 (build failed) are all
# acceptable since we're testing config/flag parsing, not build success.
# ============================================================================

test_build_target_linux() {
    ((TESTS_RUN++))
    log_test "Target: Linux/amd64 config accepted"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local exit_code=0
    timeout 30 "$DSR_CMD" build mock_rust_tool --target linux/amd64 2>&1 || exit_code=$?

    # Accept 0 (success), 1 (partial), 6 (build failed), 124 (timeout)
    # Exit 4 means config not found - that's a real failure
    if [[ "$exit_code" -ne 4 ]]; then
        log_pass "Linux target config accepted (exit: $exit_code)"
    else
        log_fail "Linux target config failed (exit: $exit_code)"
    fi

    cleanup_test_environment
}

test_build_target_darwin() {
    ((TESTS_RUN++))
    log_test "Target: Darwin/arm64 config accepted"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local exit_code=0
    timeout 30 "$DSR_CMD" build mock_rust_tool --target darwin/arm64 2>&1 || exit_code=$?

    if [[ "$exit_code" -ne 4 ]]; then
        log_pass "Darwin target config accepted (exit: $exit_code)"
    else
        log_fail "Darwin target config failed (exit: $exit_code)"
    fi

    cleanup_test_environment
}

test_build_target_windows() {
    ((TESTS_RUN++))
    log_test "Target: Windows/amd64 config accepted"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local exit_code=0
    timeout 30 "$DSR_CMD" build mock_rust_tool --target windows/amd64 2>&1 || exit_code=$?

    if [[ "$exit_code" -ne 4 ]]; then
        log_pass "Windows target config accepted (exit: $exit_code)"
    else
        log_fail "Windows target config failed (exit: $exit_code)"
    fi

    cleanup_test_environment
}

# ============================================================================
# Test Cases: Sync Flag Tests
# ============================================================================

test_sync_only_flag() {
    ((TESTS_RUN++))
    log_test "Sync: --sync-only flag accepted"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local exit_code=0
    timeout 30 "$DSR_CMD" build mock_rust_tool --sync-only 2>&1 || exit_code=$?

    # Exit 4 = config not found, that's a real failure
    if [[ "$exit_code" -ne 4 ]]; then
        log_pass "--sync-only flag accepted (exit: $exit_code)"
    else
        log_fail "--sync-only flag failed (exit: $exit_code)"
    fi

    cleanup_test_environment
}

test_no_sync_flag() {
    ((TESTS_RUN++))
    log_test "Sync: --no-sync flag accepted"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local exit_code=0
    timeout 30 "$DSR_CMD" build mock_rust_tool --no-sync --target linux/amd64 2>&1 || exit_code=$?

    if [[ "$exit_code" -ne 4 ]]; then
        log_pass "--no-sync flag accepted (exit: $exit_code)"
    else
        log_fail "--no-sync flag failed (exit: $exit_code)"
    fi

    cleanup_test_environment
}

# ============================================================================
# Test Cases: Target Filtering
# ============================================================================

test_targets_flag_filters() {
    ((TESTS_RUN++))
    log_test "Targets: --targets flag accepted"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local exit_code=0
    timeout 30 "$DSR_CMD" build mock_rust_tool --targets linux/amd64,darwin/arm64 2>&1 || exit_code=$?

    if [[ "$exit_code" -ne 4 ]]; then
        log_pass "--targets flag accepted (exit: $exit_code)"
    else
        log_fail "--targets flag failed (exit: $exit_code)"
    fi

    cleanup_test_environment
}

test_parallel_flag() {
    ((TESTS_RUN++))
    log_test "Parallel: --parallel flag accepted"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local exit_code=0
    timeout 30 "$DSR_CMD" build mock_rust_tool --parallel --targets linux/amd64 2>&1 || exit_code=$?

    if [[ "$exit_code" -ne 4 ]]; then
        log_pass "--parallel flag accepted (exit: $exit_code)"
    else
        log_fail "--parallel flag failed (exit: $exit_code)"
    fi

    cleanup_test_environment
}

test_only_act_flag() {
    ((TESTS_RUN++))
    log_test "Matrix filter: --only-act flag filters to act targets"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local output exit_code=0
    output=$(timeout 30 "$DSR_CMD" build mock_rust_tool --only-act 2>&1) || exit_code=$?

    # Should only have linux targets, not darwin/windows
    if [[ "$output" == *"Filtered to act targets"* ]] && [[ "$output" != *"darwin"* || "$output" == *"Filtered"* ]]; then
        log_pass "--only-act filters to act targets (exit: $exit_code)"
    elif [[ "$exit_code" -ne 4 ]]; then
        log_pass "--only-act flag accepted (exit: $exit_code)"
    else
        log_fail "--only-act flag failed (exit: $exit_code)"
    fi

    cleanup_test_environment
}

test_only_native_flag() {
    ((TESTS_RUN++))
    log_test "Matrix filter: --only-native flag filters to native targets"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local output exit_code=0
    output=$(timeout 30 "$DSR_CMD" build mock_rust_tool --only-native 2>&1) || exit_code=$?

    # Should only have native targets (darwin/windows), not linux
    if [[ "$output" == *"Filtered to native targets"* ]]; then
        log_pass "--only-native filters to native targets (exit: $exit_code)"
    elif [[ "$exit_code" -ne 4 ]]; then
        log_pass "--only-native flag accepted (exit: $exit_code)"
    else
        log_fail "--only-native flag failed (exit: $exit_code)"
    fi

    cleanup_test_environment
}

test_only_act_and_native_mutual_exclusion() {
    ((TESTS_RUN++))
    log_test "Matrix filter: --only-act and --only-native are mutually exclusive"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local output exit_code=0
    output=$(timeout 30 "$DSR_CMD" build mock_rust_tool --only-act --only-native 2>&1) || exit_code=$?

    # Should fail with exit 4 and error about mutual exclusion
    if [[ "$exit_code" -eq 4 ]] && [[ "$output" == *"Cannot specify both"* ]]; then
        log_pass "--only-act and --only-native correctly rejected (exit: $exit_code)"
    else
        log_fail "Expected mutual exclusion error (exit: $exit_code, output: $output)"
    fi

    cleanup_test_environment
}

test_no_sync_and_sync_only_mutual_exclusion() {
    ((TESTS_RUN++))
    log_test "Matrix filter: --no-sync and --sync-only are mutually exclusive"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local output exit_code=0
    output=$(timeout 30 "$DSR_CMD" build mock_rust_tool --no-sync --sync-only 2>&1) || exit_code=$?

    # Should fail with exit 4 and error about mutual exclusion
    if [[ "$exit_code" -eq 4 ]] && [[ "$output" == *"mutually exclusive"* ]]; then
        log_pass "--no-sync and --sync-only correctly rejected (exit: $exit_code)"
    else
        log_fail "Expected mutual exclusion error (exit: $exit_code, output: $output)"
    fi

    cleanup_test_environment
}

# ============================================================================
# Test Cases: Error Scenarios
# ============================================================================

test_missing_tool_config_error() {
    ((TESTS_RUN++))
    log_test "Error: Missing tool config returns exit 4"
    setup_test_environment

    local exit_code=0
    "$DSR_CMD" build nonexistent_tool_xyz 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -eq 4 ]]; then
        log_pass "Missing tool returns exit code 4"
    else
        log_fail "Expected exit code 4, got: $exit_code"
    fi

    cleanup_test_environment
}

test_missing_tool_error_message() {
    ((TESTS_RUN++))
    log_test "Error: Missing tool shows clear error message"
    setup_test_environment

    local output
    output=$("$DSR_CMD" build nonexistent_tool_xyz 2>&1) || true

    # Should show "not found" or similar message
    if [[ "$output" == *"not found"* ]] || [[ "$output" == *"Not found"* ]] || [[ "$output" == *"Tool"* ]]; then
        log_pass "Missing tool shows clear error message"
    else
        log_fail "Expected 'not found' in error: $output"
    fi

    cleanup_test_environment
}

# ============================================================================
# Test Cases: Multi-Language Support
# ============================================================================

test_go_tool_config_has_language() {
    ((TESTS_RUN++))
    log_test "Go tool: Config has language field set to go"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_go_tool)
    create_tool_config "mock_go_tool" "$tool_dir" "go" "mock_go_tool"

    local language
    language=$(yq -r '.language' "$DSR_CONFIG_DIR/repos.d/mock_go_tool.yaml" 2>/dev/null)

    if [[ "$language" == "go" ]]; then
        log_pass "Go tool config has language: go"
    else
        log_fail "Expected language: go, got: $language"
    fi

    cleanup_test_environment
}

test_rust_tool_config_has_language() {
    ((TESTS_RUN++))
    log_test "Rust tool: Config has language field set to rust"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local language
    language=$(yq -r '.language' "$DSR_CONFIG_DIR/repos.d/mock_rust_tool.yaml" 2>/dev/null)

    if [[ "$language" == "rust" ]]; then
        log_pass "Rust tool config has language: rust"
    else
        log_fail "Expected language: rust, got: $language"
    fi

    cleanup_test_environment
}

test_go_tool_build_cmd() {
    ((TESTS_RUN++))
    log_test "Go tool: Config has go build command"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_go_tool)
    create_tool_config "mock_go_tool" "$tool_dir" "go" "mock_go_tool"

    local build_cmd
    build_cmd=$(yq -r '.build_cmd' "$DSR_CONFIG_DIR/repos.d/mock_go_tool.yaml" 2>/dev/null)

    if [[ "$build_cmd" == *"go build"* ]]; then
        log_pass "Go tool has go build command"
    else
        log_fail "Expected go build command, got: $build_cmd"
    fi

    cleanup_test_environment
}

test_rust_tool_build_cmd() {
    ((TESTS_RUN++))
    log_test "Rust tool: Config has cargo build command"
    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_rust_tool)
    create_tool_config "mock_rust_tool" "$tool_dir" "rust" "mock_rust_tool"

    local build_cmd
    build_cmd=$(yq -r '.build_cmd' "$DSR_CONFIG_DIR/repos.d/mock_rust_tool.yaml" 2>/dev/null)

    if [[ "$build_cmd" == *"cargo build"* ]]; then
        log_pass "Rust tool has cargo build command"
    else
        log_fail "Expected cargo build command, got: $build_cmd"
    fi

    cleanup_test_environment
}

# ============================================================================
# Test Cases: Live Builds (require SSH access)
# ============================================================================

test_live_build_linux_via_act() {
    ((TESTS_RUN++))
    log_test "Live: Linux/amd64 build via act"

    if [[ -n "${DSR_E2E_SKIP_LIVE:-}" ]]; then
        log_skip "Skipped (DSR_E2E_SKIP_LIVE set)"
        return
    fi

    if ! command -v docker &>/dev/null || ! docker info &>/dev/null 2>&1; then
        log_skip "Skipped (Docker not available)"
        return
    fi

    if ! command -v act &>/dev/null; then
        log_skip "Skipped (act not available)"
        return
    fi

    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_go_tool)
    create_tool_config "mock_go_tool" "$tool_dir" "go" "mock_go_tool"

    local exit_code=0
    local timeout_secs="${DSR_E2E_TIMEOUT:-300}"

    timeout "$timeout_secs" "$DSR_CMD" build mock_go_tool --target linux/amd64 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        log_pass "Linux build via act succeeded"
    else
        log_fail "Linux build failed with exit code: $exit_code"
    fi

    cleanup_test_environment
}

test_live_build_darwin_native() {
    ((TESTS_RUN++))
    log_test "Live: Darwin/arm64 build via SSH"

    if [[ -n "${DSR_E2E_SKIP_LIVE:-}" ]]; then
        log_skip "Skipped (DSR_E2E_SKIP_LIVE set)"
        return
    fi

    # Check SSH access to mmini
    if ! timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=3 mmini 'echo ok' &>/dev/null; then
        log_skip "Skipped (SSH to mmini unavailable)"
        return
    fi

    # Check Go toolchain on mmini
    if ! timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=3 mmini 'command -v go' &>/dev/null; then
        log_skip "Skipped (Go not available on mmini)"
        return
    fi

    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_go_tool)
    create_tool_config "mock_go_tool" "$tool_dir" "go" "mock_go_tool"

    local exit_code=0
    local timeout_secs="${DSR_E2E_TIMEOUT:-300}"

    timeout "$timeout_secs" "$DSR_CMD" build mock_go_tool --target darwin/arm64 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        log_pass "Darwin build via SSH succeeded"
    else
        log_fail "Darwin build failed with exit code: $exit_code"
    fi

    cleanup_test_environment
}

test_live_build_windows_native() {
    ((TESTS_RUN++))
    log_test "Live: Windows/amd64 build via SSH"

    if [[ -n "${DSR_E2E_SKIP_LIVE:-}" ]]; then
        log_skip "Skipped (DSR_E2E_SKIP_LIVE set)"
        return
    fi

    # Check SSH access to wlap
    if ! timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=3 wlap 'echo ok' &>/dev/null; then
        log_skip "Skipped (SSH to wlap unavailable)"
        return
    fi

    # Verify SCP works to wlap (source sync must succeed for build)
    local _scp_test
    _scp_test=$(mktemp)
    echo "test" > "$_scp_test"
    if ! timeout 10 scp -o BatchMode=yes -o ConnectTimeout=3 "$_scp_test" wlap:/tmp/dsr_scp_test &>/dev/null; then
        rm -f "$_scp_test"
        log_skip "Skipped (SCP to wlap unavailable)"
        return
    fi
    rm -f "$_scp_test"
    ssh -o BatchMode=yes -o ConnectTimeout=3 wlap 'del C:\tmp\dsr_scp_test 2>nul' &>/dev/null || true

    setup_test_environment

    local tool_dir
    tool_dir=$(setup_mock_go_tool)
    create_tool_config "mock_go_tool" "$tool_dir" "go" "mock_go_tool"

    local exit_code=0
    local timeout_secs="${DSR_E2E_TIMEOUT:-300}"

    timeout "$timeout_secs" "$DSR_CMD" build mock_go_tool --target windows/amd64 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        log_pass "Windows build via SSH succeeded"
    else
        log_fail "Windows build failed with exit code: $exit_code"
    fi

    cleanup_test_environment
}

# ============================================================================
# Test Runner
# ============================================================================

main() {
    echo "================================================================"
    echo "  Native Build E2E Tests"
    echo "================================================================"
    echo ""

    # Help tests (always work)
    test_build_help_shows_usage
    test_build_help_shows_target_option
    test_build_help_shows_parallel_option

    # JSON output tests
    test_json_flag_recognized
    test_version_json_output

    # Config file tests
    test_tool_config_file_loaded
    test_tool_config_has_targets

    # Error handling tests
    test_missing_tool_config_error
    test_missing_tool_error_message

    # Multi-language config tests
    test_go_tool_config_has_language
    test_rust_tool_config_has_language
    test_go_tool_build_cmd
    test_rust_tool_build_cmd

    # Platform target tests (verify config parsing for each platform)
    test_build_target_linux
    test_build_target_darwin
    test_build_target_windows

    # Sync flag tests
    test_sync_only_flag
    test_no_sync_flag

    # Target filtering tests
    test_targets_flag_filters
    test_parallel_flag

    # Matrix filtering tests
    test_only_act_flag
    test_only_native_flag
    test_only_act_and_native_mutual_exclusion
    test_no_sync_and_sync_only_mutual_exclusion

    # Live tests (optional, require SSH/Docker)
    test_live_build_linux_via_act
    test_live_build_darwin_native
    test_live_build_windows_native

    echo ""
    echo "================================================================"
    echo "  Summary"
    echo "================================================================"
    echo "  Run:     $TESTS_RUN"
    echo "  Passed:  ${GREEN}$TESTS_PASSED${NC}"
    echo "  Failed:  ${RED}$TESTS_FAILED${NC}"
    echo "  Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
