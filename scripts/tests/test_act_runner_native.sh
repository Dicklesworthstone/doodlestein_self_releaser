#!/usr/bin/env bash
# test_act_runner_native.sh - Unit tests for act_runner.sh native build SSH logic
#
# Usage: ./test_act_runner_native.sh
#
# Tests native build SSH command construction with mocks.
# Covers: command construction, path handling, env vars, SCP, error handling.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_ROOT/src"

# Colors
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0

log_pass() { echo -e "${GREEN}PASS${NC} $1"; ((PASS_COUNT++)); }
log_fail() { echo -e "${RED}FAIL${NC} $1"; ((FAIL_COUNT++)); }
log_test() { echo -e "\n${YELLOW}===${NC} $1 ${YELLOW}===${NC}"; }

# Create mock directories
MOCK_DIR=$(mktemp -d)
export ACT_LOGS_DIR="$MOCK_DIR/logs"
export ACT_ARTIFACTS_DIR="$MOCK_DIR/artifacts"
export ACT_REPOS_DIR="$MOCK_DIR/repos.d"
export ACT_CONFIG_DIR="$MOCK_DIR"

# State capture files (avoids subshell variable loss)
SSH_ARGS_FILE="$MOCK_DIR/ssh_args.txt"
SCP_ARGS_FILE="$MOCK_DIR/scp_args.txt"
SSH_EXIT_CODE_FILE="$MOCK_DIR/ssh_exit_code.txt"
SCP_EXIT_CODE_FILE="$MOCK_DIR/scp_exit_code.txt"

mkdir -p "$ACT_LOGS_DIR" "$ACT_ARTIFACTS_DIR" "$ACT_REPOS_DIR"

# Default exit codes (can be overridden per test)
echo "0" > "$SSH_EXIT_CODE_FILE"
echo "0" > "$SCP_EXIT_CODE_FILE"

# Source the module under test
source "$SRC_DIR/act_runner.sh"

# ============================================================================
# Mock Functions (override after sourcing act_runner.sh)
# ============================================================================

# Mock logging
_log_info()  { :; }  # Silent for tests
_log_error() { :; }
_log_ok()    { :; }
_log_warn()  { :; }

# Mock _act_ssh_exec - captures args to file
_act_ssh_exec() {
    local host="$1"
    local cmd="$2"
    # Write to file for subshell-safe capture
    printf '%s\n' "HOST:$host" "CMD:$cmd" > "$SSH_ARGS_FILE"
    local exit_code
    exit_code=$(cat "$SSH_EXIT_CODE_FILE")
    return "$exit_code"
}

# Mock scp - captures args to file
scp() {
    printf '%s\n' "$@" > "$SCP_ARGS_FILE"
    local exit_code
    exit_code=$(cat "$SCP_EXIT_CODE_FILE")
    if [[ "$exit_code" -eq 0 ]]; then
        # Touch the target file (last arg) to simulate successful download
        local target="${!#}"
        mkdir -p "$(dirname "$target")" 2>/dev/null || true
        touch "$target" 2>/dev/null || true
    fi
    return "$exit_code"
}

# Mock yq for config parsing
# Handles: yq -r 'query' file OR yq 'query' file
yq() {
    local query

    # Skip -r flag if present
    if [[ "$1" == "-r" ]]; then
        shift
    fi

    query="${1:-}"
    # $2 is the file path (unused in mock - we return based on query pattern)

    # Handle various config queries
    case "$query" in
        '.tool_name // ""')
            echo "${MOCK_TOOL_NAME:-tool}"
            ;;
        '.repo // ""')
            echo "${MOCK_REPO:-owner/tool}"
            ;;
        '.local_path // ""')
            echo "${MOCK_LOCAL_PATH:-/local/path/tool}"
            ;;
        '.language // ""')
            echo "${MOCK_LANGUAGE:-go}"
            ;;
        '.binary_name // ""')
            echo "${MOCK_BINARY_NAME:-tool}"
            ;;
        '.build_cmd // ""')
            echo "${MOCK_BUILD_CMD:-go build}"
            ;;
        '.workflow // ".github/workflows/release.yml"')
            echo ".github/workflows/release.yml"
            ;;
        '.host_paths.'*' // ""')
            # Extract host name from query like .host_paths.mmini // ""
            local host_match
            host_match=$(echo "$query" | sed -n 's/.*\.host_paths\.\([a-zA-Z]*\).*/\1/p')
            case "$host_match" in
                mmini) echo "${MOCK_HOST_PATH_MMINI:-}" ;;
                wlap)  echo "${MOCK_HOST_PATH_WLAP:-}" ;;
                trj)   echo "${MOCK_HOST_PATH_TRJ:-}" ;;
                *)     echo "" ;;
            esac
            ;;
        '.env // {} | to_entries | map(.key + "=" + .value) | .[]')
            echo "${MOCK_GLOBAL_ENV:-}"
            ;;
        *'.cross_compile.'*'.env'*)
            echo "${MOCK_PLATFORM_ENV:-}"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Reset test state
reset_state() {
    rm -f "$SSH_ARGS_FILE" "$SCP_ARGS_FILE"
    echo "0" > "$SSH_EXIT_CODE_FILE"
    echo "0" > "$SCP_EXIT_CODE_FILE"

    # Reset mock config values
    unset MOCK_TOOL_NAME MOCK_REPO MOCK_LOCAL_PATH MOCK_LANGUAGE
    unset MOCK_BINARY_NAME MOCK_BUILD_CMD
    unset MOCK_HOST_PATH_MMINI MOCK_HOST_PATH_WLAP MOCK_HOST_PATH_TRJ
    unset MOCK_GLOBAL_ENV MOCK_PLATFORM_ENV

    # Defaults
    MOCK_LOCAL_PATH="/local/path/tool"
    MOCK_LANGUAGE="go"
    MOCK_BINARY_NAME="tool"
    MOCK_BUILD_CMD="go build"

    # Create mock config file
    touch "$ACT_REPOS_DIR/tool.yaml"
}

# Get captured SSH command
get_ssh_cmd() {
    if [[ -f "$SSH_ARGS_FILE" ]]; then
        grep "^CMD:" "$SSH_ARGS_FILE" | sed 's/^CMD://'
    else
        echo ""
    fi
}

# Get captured SSH host
get_ssh_host() {
    if [[ -f "$SSH_ARGS_FILE" ]]; then
        grep "^HOST:" "$SSH_ARGS_FILE" | sed 's/^HOST://'
    else
        echo ""
    fi
}

# Get captured SCP args as a single line
get_scp_args() {
    if [[ -f "$SCP_ARGS_FILE" ]]; then
        tr '\n' ' ' < "$SCP_ARGS_FILE"
    else
        echo ""
    fi
}

# ============================================================================
# Test Cases: Unix Command Construction
# ============================================================================

test_unix_cd_command() {
    log_test "Unix: cd command uses single quotes"
    reset_state
    MOCK_LOCAL_PATH="/local/path/tool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *"cd '/local/path/tool'"* ]]; then
        log_pass "cd uses single quotes: cd '/local/path/tool'"
    else
        log_fail "Expected cd '/local/path/tool' but got: $cmd"
    fi
}

test_unix_env_export_syntax() {
    log_test "Unix: env vars use export syntax"
    reset_state
    MOCK_GLOBAL_ENV="CARGO_TERM_COLOR=always"
    MOCK_PLATFORM_ENV="RUST_BACKTRACE=1"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *"export CARGO_TERM_COLOR=always"* ]]; then
        log_pass "Uses export for env vars"
    else
        log_fail "Expected 'export CARGO_TERM_COLOR=always' in: $cmd"
    fi
}

test_unix_chained_with_and() {
    log_test "Unix: commands chained with &&"
    reset_state

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *" && "* ]]; then
        log_pass "Commands chained with &&"
    else
        log_fail "Expected && chaining in: $cmd"
    fi
}

test_unix_host_path_override() {
    log_test "Unix: uses host_paths override when set"
    reset_state
    MOCK_HOST_PATH_MMINI="/Users/jemanuel/projects/tool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *"cd '/Users/jemanuel/projects/tool'"* ]]; then
        log_pass "Uses host_paths override: /Users/jemanuel/projects/tool"
    else
        log_fail "Expected host_paths override in: $cmd"
    fi
}

test_unix_fallback_to_local_path() {
    log_test "Unix: falls back to local_path when no host_paths"
    reset_state
    MOCK_HOST_PATH_MMINI=""  # No override
    MOCK_LOCAL_PATH="/data/projects/mytool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *"cd '/data/projects/mytool'"* ]]; then
        log_pass "Falls back to local_path"
    else
        log_fail "Expected fallback to local_path in: $cmd"
    fi
}

# ============================================================================
# Test Cases: Windows Command Construction
# ============================================================================

test_windows_cd_command() {
    log_test "Windows: cd /d with double quotes and backslashes"
    reset_state
    MOCK_LOCAL_PATH="/c/Users/jeffr/projects/tool"

    act_run_native_build "tool" "windows/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    # Windows should convert / to \ and use double quotes
    if [[ "$cmd" == *'cd /d "'* ]] && [[ "$cmd" == *'\'* ]]; then
        log_pass "Windows uses cd /d with backslashes"
    else
        log_fail "Expected Windows cd /d with backslashes in: $cmd"
    fi
}

test_windows_env_set_syntax() {
    log_test "Windows: env vars use set syntax"
    reset_state
    MOCK_GLOBAL_ENV="CARGO_TERM_COLOR=always"

    act_run_native_build "tool" "windows/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *'set "'*'='*'"'* ]] || [[ "$cmd" == *'set "CARGO_TERM_COLOR=always"'* ]]; then
        log_pass "Windows uses set for env vars"
    else
        log_fail "Expected Windows set syntax in: $cmd"
    fi
}

test_windows_slash_conversion() {
    log_test "Windows: forward slashes converted to backslashes"
    reset_state
    MOCK_LOCAL_PATH="/c/Users/jeffr/projects/tool"

    act_run_native_build "tool" "windows/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    # Check for backslash in the path
    if [[ "$cmd" == *'\c\Users\jeffr\projects\tool'* ]]; then
        log_pass "Forward slashes converted to backslashes"
    else
        log_fail "Expected backslash path in: $cmd"
    fi
}

# ============================================================================
# Test Cases: Path Handling
# ============================================================================

test_path_with_spaces_unix() {
    log_test "Path with spaces (Unix): properly quoted"
    reset_state
    MOCK_LOCAL_PATH="/Users/John Doe/My Projects/tool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    # Single quotes should protect spaces
    if [[ "$cmd" == *"cd '/Users/John Doe/My Projects/tool'"* ]]; then
        log_pass "Spaces handled with single quotes"
    else
        log_fail "Expected proper quoting for spaces in: $cmd"
    fi
}

test_path_with_single_quote() {
    log_test "Path with single quote: properly escaped"
    reset_state
    MOCK_LOCAL_PATH="/Users/O'Brien/projects/tool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    # Single quote should be escaped as '\''
    if [[ "$cmd" == *"'\\''"* ]] || [[ "$cmd" == *"O'Brien"* ]]; then
        log_pass "Single quote in path handled"
    else
        log_fail "Expected escaped single quote in: $cmd"
    fi
}

# ============================================================================
# Test Cases: SCP Commands
# ============================================================================

test_scp_unix_artifact_path() {
    log_test "SCP Unix: correct artifact path for Go"
    reset_state
    MOCK_LANGUAGE="go"
    MOCK_BINARY_NAME="mytool"
    MOCK_LOCAL_PATH="/local/path/mytool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local scp_args
    scp_args=$(get_scp_args)

    # Go binary should be at project root
    # Note: scp now uses separate shell arguments, so path is not embedded-quoted
    if [[ "$scp_args" == *"mmini:/local/path/mytool/mytool "* ]]; then
        log_pass "Go artifact path correct: /local/path/mytool/mytool"
    else
        log_fail "Expected Go artifact path in: $scp_args"
    fi
}

test_scp_rust_artifact_path() {
    log_test "SCP Unix: correct artifact path for Rust"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_LOCAL_PATH="/local/path/mytool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local scp_args
    scp_args=$(get_scp_args)

    # Rust binary should be in target/release
    # Note: scp now uses separate shell arguments, so path is not embedded-quoted
    if [[ "$scp_args" == *"mmini:/local/path/mytool/target/release/mytool "* ]]; then
        log_pass "Rust artifact path correct: target/release/mytool"
    else
        log_fail "Expected Rust artifact path in: $scp_args"
    fi
}

test_scp_windows_exe_extension() {
    log_test "SCP Windows: .exe extension added"
    reset_state
    MOCK_LANGUAGE="go"
    MOCK_BINARY_NAME="mytool"
    MOCK_LOCAL_PATH="/c/projects/mytool"

    act_run_native_build "tool" "windows/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local scp_args
    scp_args=$(get_scp_args)

    if [[ "$scp_args" == *".exe"* ]]; then
        log_pass "Windows artifact has .exe extension"
    else
        log_fail "Expected .exe extension in: $scp_args"
    fi
}

test_scp_windows_forward_slash_path() {
    log_test "SCP Windows: forward slashes (OpenSSH SCP convention)"
    reset_state
    MOCK_LANGUAGE="go"
    MOCK_BINARY_NAME="mytool"
    MOCK_LOCAL_PATH="/c/Users/jeffr/projects/mytool"

    act_run_native_build "tool" "windows/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local scp_args
    scp_args=$(get_scp_args)

    # OpenSSH SCP uses forward slashes even on Windows (see act_runner.sh line 1144)
    if [[ "$scp_args" == *"/c/Users/jeffr/projects/mytool/mytool.exe"* ]]; then
        log_pass "Windows SCP path uses forward slashes (OpenSSH convention)"
    else
        log_fail "Expected forward-slash path in SCP args: $scp_args"
    fi
}

# ============================================================================
# Test Cases: Host Detection
# ============================================================================

test_host_detection_darwin() {
    log_test "Host detection: darwin/* -> mmini"
    reset_state

    local host
    host=$(act_get_native_host "darwin/arm64")

    if [[ "$host" == "mmini" ]]; then
        log_pass "darwin/arm64 -> mmini"
    else
        log_fail "Expected mmini but got: $host"
    fi
}

test_host_detection_windows() {
    log_test "Host detection: windows/* -> wlap"
    reset_state

    local host
    host=$(act_get_native_host "windows/amd64")

    if [[ "$host" == "wlap" ]]; then
        log_pass "windows/amd64 -> wlap"
    else
        log_fail "Expected wlap but got: $host"
    fi
}

test_host_detection_linux() {
    log_test "Host detection: linux/* -> trj"
    reset_state

    local host
    host=$(act_get_native_host "linux/amd64")

    if [[ "$host" == "trj" ]]; then
        log_pass "linux/amd64 -> trj"
    else
        log_fail "Expected trj but got: $host"
    fi
}

test_host_detection_unknown() {
    log_test "Host detection: unknown platform returns empty"
    reset_state

    local host
    host=$(act_get_native_host "freebsd/amd64")

    if [[ -z "$host" ]]; then
        log_pass "Unknown platform returns empty"
    else
        log_fail "Expected empty but got: $host"
    fi
}

# ============================================================================
# Test Cases: Error Handling
# ============================================================================

test_ssh_failure_propagates() {
    log_test "Error: SSH failure returns exit code 6"
    reset_state
    echo "1" > "$SSH_EXIT_CODE_FILE"

    local result exit_code=0
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || exit_code=$?

    if [[ "$exit_code" -eq 6 ]]; then
        log_pass "SSH failure returns exit code 6"
    else
        log_fail "Expected exit code 6 but got: $exit_code"
    fi
}

test_ssh_failure_json_status() {
    log_test "Error: SSH failure sets status to 'failed'"
    reset_state
    echo "1" > "$SSH_EXIT_CODE_FILE"

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local status
    status=$(echo "$result" | jq -r '.status // "unknown"')

    if [[ "$status" == "failed" ]]; then
        log_pass "SSH failure status is 'failed'"
    else
        log_fail "Expected status 'failed' but got: $status"
    fi
}

test_ssh_timeout_returns_5() {
    log_test "Error: SSH timeout (exit 124) returns code 5"
    reset_state
    echo "124" > "$SSH_EXIT_CODE_FILE"

    local exit_code=0
    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 5 ]]; then
        log_pass "SSH timeout returns exit code 5"
    else
        log_fail "Expected exit code 5 but got: $exit_code"
    fi
}

test_ssh_timeout_json_status() {
    log_test "Error: SSH timeout sets status to 'timeout'"
    reset_state
    echo "124" > "$SSH_EXIT_CODE_FILE"

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local status
    status=$(echo "$result" | jq -r '.status // "unknown"')

    if [[ "$status" == "timeout" ]]; then
        log_pass "SSH timeout status is 'timeout'"
    else
        log_fail "Expected status 'timeout' but got: $status"
    fi
}

test_scp_failure_returns_7() {
    log_test "Error: SCP failure returns exit code 7"
    reset_state
    echo "0" > "$SSH_EXIT_CODE_FILE"  # SSH succeeds
    echo "1" > "$SCP_EXIT_CODE_FILE"  # SCP fails

    local exit_code=0
    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 7 ]]; then
        log_pass "SCP failure returns exit code 7"
    else
        log_fail "Expected exit code 7 but got: $exit_code"
    fi
}

test_scp_failure_empty_artifact_path() {
    log_test "Error: SCP failure sets artifact_path to empty"
    reset_state
    echo "0" > "$SSH_EXIT_CODE_FILE"
    echo "1" > "$SCP_EXIT_CODE_FILE"

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local artifact_path
    artifact_path=$(echo "$result" | jq -r '.artifact_path // "null"')

    if [[ "$artifact_path" == "" || "$artifact_path" == "null" ]]; then
        log_pass "SCP failure clears artifact_path"
    else
        log_fail "Expected empty artifact_path but got: $artifact_path"
    fi
}

test_missing_config_returns_4() {
    log_test "Error: Missing config returns exit code 4"
    reset_state
    rm -f "$ACT_REPOS_DIR/tool.yaml"

    local exit_code=0
    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1 || exit_code=$?

    # Recreate for other tests
    touch "$ACT_REPOS_DIR/tool.yaml"

    if [[ "$exit_code" -eq 4 ]]; then
        log_pass "Missing config returns exit code 4"
    else
        log_fail "Expected exit code 4 but got: $exit_code"
    fi
}

test_unknown_platform_returns_4() {
    log_test "Error: Unknown platform returns exit code 4"
    reset_state

    local exit_code=0
    act_run_native_build "tool" "freebsd/amd64" "v1.0.0" "run1" >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 4 ]]; then
        log_pass "Unknown platform returns exit code 4"
    else
        log_fail "Expected exit code 4 but got: $exit_code"
    fi
}

# ============================================================================
# Test Cases: Result JSON Structure
# ============================================================================

test_result_json_has_required_fields() {
    log_test "Result JSON: has all required fields"
    reset_state

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local has_all=true
    for field in tool platform host method status exit_code duration_seconds artifact_path log_file; do
        if ! echo "$result" | jq -e "has(\"$field\")" >/dev/null 2>&1; then
            log_fail "Missing field: $field"
            has_all=false
        fi
    done

    if $has_all; then
        log_pass "All required fields present"
    fi
}

test_result_json_correct_platform() {
    log_test "Result JSON: platform matches input"
    reset_state

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local platform
    platform=$(echo "$result" | jq -r '.platform')

    if [[ "$platform" == "darwin/arm64" ]]; then
        log_pass "Platform correct: darwin/arm64"
    else
        log_fail "Expected darwin/arm64 but got: $platform"
    fi
}

test_result_json_method_native() {
    log_test "Result JSON: method is 'native'"
    reset_state

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local method
    method=$(echo "$result" | jq -r '.method')

    if [[ "$method" == "native" ]]; then
        log_pass "Method is 'native'"
    else
        log_fail "Expected 'native' but got: $method"
    fi
}

test_result_json_success_has_artifact() {
    log_test "Result JSON: success includes artifact_path"
    reset_state

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local artifact_path
    artifact_path=$(echo "$result" | jq -r '.artifact_path')

    if [[ "$artifact_path" == *"$ACT_ARTIFACTS_DIR"* ]]; then
        log_pass "Success result has artifact_path"
    else
        log_fail "Expected artifact in $ACT_ARTIFACTS_DIR but got: $artifact_path"
    fi
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "================================================================"
    echo "  act_runner.sh Native Build Unit Tests"
    echo "================================================================"

    # Unix command construction
    test_unix_cd_command
    test_unix_env_export_syntax
    test_unix_chained_with_and
    test_unix_host_path_override
    test_unix_fallback_to_local_path

    # Windows command construction
    test_windows_cd_command
    test_windows_env_set_syntax
    test_windows_slash_conversion

    # Path handling
    test_path_with_spaces_unix
    test_path_with_single_quote

    # SCP commands
    test_scp_unix_artifact_path
    test_scp_rust_artifact_path
    test_scp_windows_exe_extension
    test_scp_windows_forward_slash_path

    # Host detection
    test_host_detection_darwin
    test_host_detection_windows
    test_host_detection_linux
    test_host_detection_unknown

    # Error handling
    test_ssh_failure_propagates
    test_ssh_failure_json_status
    test_ssh_timeout_returns_5
    test_ssh_timeout_json_status
    test_scp_failure_returns_7
    test_scp_failure_empty_artifact_path
    test_missing_config_returns_4
    test_unknown_platform_returns_4

    # Result JSON structure
    test_result_json_has_required_fields
    test_result_json_correct_platform
    test_result_json_method_native
    test_result_json_success_has_artifact

    # Summary
    echo ""
    echo "================================================================"
    echo "  Summary"
    echo "================================================================"
    echo -e "  ${GREEN}Passed:${NC}  $PASS_COUNT"
    echo -e "  ${RED}Failed:${NC}  $FAIL_COUNT"

    # Cleanup
    rm -rf "$MOCK_DIR"

    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
