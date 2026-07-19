#!/usr/bin/env bash
# test_quality_gates.sh - Unit tests for quality_gates.sh module
#
# Tests:
# - qg_get_checks: Parse checks from repos.yaml
# - _qg_run_single_check: Execute single check, capture output
# - qg_run_checks: Run all checks with options (--dry-run, --skip-checks)
#
# Run: ./scripts/tests/test_quality_gates.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test harness and module under test
source "$PROJECT_ROOT/tests/helpers/test_harness.bash"
source "$PROJECT_ROOT/src/quality_gates.sh"

# Test state
TESTS_RUN=0
TESTS_PASSED=0
TESTS_SKIPPED=0
TESTS_FAILED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }

# ============================================================================
# Setup / Teardown
# ============================================================================

setup_test_env() {
    TEST_TMPDIR=$(mktemp -d)
    export DSR_CONFIG_DIR="$TEST_TMPDIR/config"
    export DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
    mkdir -p "$DSR_CONFIG_DIR"
}

teardown_test_env() {
    if [[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

create_repos_yaml() {
    local content="$1"
    echo "$content" > "$DSR_REPOS_FILE"
}

run_single_check() {
    _qg_run_single_check "$1" "$2" "$3" "$TEST_TMPDIR/check.log"
}

# ============================================================================
# Tests: qg_get_checks
# ============================================================================

test_get_checks_with_yq() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "cargo test"
      - "cargo clippy"
'
    local checks
    checks=$(qg_get_checks "test-tool" 2>/dev/null)
    local count
    count=$(echo "$checks" | jq 'length')

    if [[ "$count" -eq 2 ]]; then
        pass "qg_get_checks returns configured checks"
    else
        fail "qg_get_checks: expected 2 checks, got $count"
    fi
    teardown_test_env
}

test_get_checks_empty_array() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks: []
'
    local checks
    checks=$(qg_get_checks "test-tool" 2>/dev/null)
    local count
    count=$(echo "$checks" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        pass "qg_get_checks returns empty array for empty checks"
    else
        fail "qg_get_checks: expected 0 checks, got $count"
    fi
    teardown_test_env
}

test_get_checks_missing_section() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    repo: foo/bar
'
    local checks
    checks=$(qg_get_checks "test-tool" 2>/dev/null)
    local count
    count=$(echo "$checks" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        pass "qg_get_checks returns empty array when checks section missing"
    else
        fail "qg_get_checks: expected 0 checks for missing section, got $count"
    fi
    teardown_test_env
}

test_get_checks_unknown_tool() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  known-tool:
    checks:
      - "echo test"
'
    local checks exit_code=0
    checks=$(qg_get_checks "unknown-tool" 2>/dev/null) || exit_code=$?

    if [[ "$exit_code" -eq 4 && -z "$checks" ]]; then
        pass "qg_get_checks fails closed for an unknown tool"
    else
        fail "qg_get_checks: expected rc=4 and no receipt, got rc=$exit_code checks=$checks"
    fi
    teardown_test_env
}

test_get_checks_missing_file() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    # Don't create the file
    rm -f "$DSR_REPOS_FILE"

    local checks exit_code=0
    checks=$(qg_get_checks "test-tool" 2>/dev/null) || exit_code=$?

    if [[ "$exit_code" -eq 4 && -z "$checks" ]]; then
        pass "qg_get_checks fails closed when the repos file is missing"
    else
        fail "qg_get_checks: expected rc=4 and no receipt, got rc=$exit_code checks=$checks"
    fi
    teardown_test_env
}

test_get_checks_multiple_checks() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "cargo test"
      - "cargo clippy --all-targets -- -D warnings"
      - "cargo fmt --check"
      - "cargo doc --no-deps"
'
    local checks
    checks=$(qg_get_checks "test-tool" 2>/dev/null)
    local count
    count=$(echo "$checks" | jq 'length')

    if [[ "$count" -eq 4 ]]; then
        pass "qg_get_checks returns all 4 configured checks"
    else
        fail "qg_get_checks: expected 4 checks, got $count"
    fi
    teardown_test_env
}

# ============================================================================
# Tests: _qg_run_single_check
# ============================================================================

test_run_single_check_success() {
    ((TESTS_RUN++))
    setup_test_env

    local result
    result=$(run_single_check "echo hello" "" "false" 2>/dev/null)

    local passed exit_code
    passed=$(echo "$result" | jq -r '.passed')
    exit_code=$(echo "$result" | jq -r '.exit_code')

    if [[ "$passed" == "true" && "$exit_code" == "0" ]]; then
        pass "_qg_run_single_check captures successful command"
    else
        fail "_qg_run_single_check: passed=$passed, exit_code=$exit_code"
    fi
    teardown_test_env
}

test_run_single_check_failure() {
    ((TESTS_RUN++))
    setup_test_env

    local result
    result=$(run_single_check "false" "" "false" 2>/dev/null)

    local passed exit_code
    passed=$(echo "$result" | jq -r '.passed')
    exit_code=$(echo "$result" | jq -r '.exit_code')

    if [[ "$passed" == "false" && "$exit_code" != "0" ]]; then
        pass "_qg_run_single_check captures failed command"
    else
        fail "_qg_run_single_check: expected failure, got passed=$passed"
    fi
    teardown_test_env
}

test_run_single_check_output_captured() {
    ((TESTS_RUN++))
    setup_test_env

    local result
    result=$(run_single_check "echo test_output_123" "" "false" 2>/dev/null)

    local output
    output=$(echo "$result" | jq -r '.output_preview')

    if [[ "$output" == *"test_output_123"* ]]; then
        pass "_qg_run_single_check captures command output"
    else
        fail "_qg_run_single_check: output not captured, got: $output"
    fi
    teardown_test_env
}

test_run_single_check_duration() {
    ((TESTS_RUN++))
    setup_test_env

    local result
    result=$(run_single_check "sleep 0.1" "" "false" 2>/dev/null)

    local duration_ms
    duration_ms=$(echo "$result" | jq -r '.duration_ms')

    if [[ "$duration_ms" -ge 50 ]]; then
        pass "_qg_run_single_check measures duration (${duration_ms}ms)"
    else
        fail "_qg_run_single_check: duration too short: ${duration_ms}ms"
    fi
    teardown_test_env
}

test_run_single_check_dry_run() {
    ((TESTS_RUN++))
    setup_test_env

    local result
    result=$(run_single_check "false" "" "true" 2>/dev/null)

    local passed executed status output
    passed=$(echo "$result" | jq -r '.passed')
    executed=$(echo "$result" | jq -r '.executed')
    status=$(echo "$result" | jq -r '.status')
    output=$(echo "$result" | jq -r '.output_preview')

    if [[ "$passed" == "false" && "$executed" == "false" && \
          "$status" == "planned" && "$output" == *"dry-run"* ]]; then
        pass "_qg_run_single_check records dry-run as planned and not executed"
    else
        fail "_qg_run_single_check dry-run: passed=$passed, output=$output"
    fi
    teardown_test_env
}

test_run_single_check_work_dir() {
    ((TESTS_RUN++))
    setup_test_env

    local work_dir="$TEST_TMPDIR/work"
    mkdir -p "$work_dir"

    local result
    result=$(run_single_check "pwd" "$work_dir" "false" 2>/dev/null)

    local output
    output=$(echo "$result" | jq -r '.output_preview')

    if [[ "$output" == *"$work_dir"* ]]; then
        pass "_qg_run_single_check runs in work directory"
    else
        fail "_qg_run_single_check work_dir: expected $work_dir, got $output"
    fi
    teardown_test_env
}

test_run_single_check_json_structure() {
    ((TESTS_RUN++))
    setup_test_env

    local result
    result=$(run_single_check "echo test" "" "false" 2>/dev/null)

    local has_command has_exit_code has_duration has_passed has_output has_log has_sha
    local log_path expected_sha actual_sha
    has_command=$(echo "$result" | jq 'has("command")')
    has_exit_code=$(echo "$result" | jq 'has("exit_code")')
    has_duration=$(echo "$result" | jq 'has("duration_ms")')
    has_passed=$(echo "$result" | jq 'has("passed")')
    has_output=$(echo "$result" | jq 'has("output_preview")')
    has_log=$(echo "$result" | jq 'has("log_path")')
    has_sha=$(echo "$result" | jq 'has("log_sha256")')
    log_path=$(echo "$result" | jq -r '.log_path')
    expected_sha=$(echo "$result" | jq -r '.log_sha256')
    actual_sha=$(_qg_sha256 "$log_path")

    if [[ "$has_command" == "true" && "$has_exit_code" == "true" && \
          "$has_duration" == "true" && "$has_passed" == "true" && \
          "$has_output" == "true" && "$has_log" == "true" && "$has_sha" == "true" && \
          -f "$log_path" && "$actual_sha" == "$expected_sha" ]]; then
        pass "_qg_run_single_check returns a complete hash-bound log receipt"
    else
        fail "_qg_run_single_check JSON: missing fields"
    fi
    teardown_test_env
}

test_run_single_check_requires_log_path() {
    ((TESTS_RUN++))
    setup_test_env

    local result exit_code=0
    result=$(_qg_run_single_check "true" "" "false" 2>/dev/null) || exit_code=$?

    if [[ "$exit_code" -eq 4 && -z "$result" ]]; then
        pass "_qg_run_single_check rejects execution without a durable log path"
    else
        fail "_qg_run_single_check accepted a missing log path: exit=$exit_code result=$result"
    fi
    teardown_test_env
}

test_run_single_check_nonzero_exit() {
    ((TESTS_RUN++))
    setup_test_env

    local result
    result=$(run_single_check "exit 42" "" "false" 2>/dev/null)

    local exit_code
    exit_code=$(echo "$result" | jq -r '.exit_code')

    if [[ "$exit_code" == "42" ]]; then
        pass "_qg_run_single_check captures specific exit code"
    else
        fail "_qg_run_single_check: expected exit 42, got $exit_code"
    fi
    teardown_test_env
}

# ============================================================================
# Tests: qg_run_checks
# ============================================================================

test_run_checks_no_tool_name() {
    ((TESTS_RUN++))
    setup_test_env

    if ! qg_run_checks 2>/dev/null; then
        pass "qg_run_checks fails without tool name"
    else
        fail "qg_run_checks should fail without tool name"
    fi
    teardown_test_env
}

test_run_checks_help_flag() {
    ((TESTS_RUN++))
    setup_test_env

    local output
    output=$(qg_run_checks --help 2>/dev/null)

    if [[ "$output" == *"Usage"* ]]; then
        pass "qg_run_checks --help shows usage"
    else
        fail "qg_run_checks --help: no usage text"
    fi
    teardown_test_env
}

test_run_checks_unknown_option() {
    ((TESTS_RUN++))
    setup_test_env

    if ! qg_run_checks --unknown-flag test-tool 2>/dev/null; then
        pass "qg_run_checks rejects unknown option"
    else
        fail "qg_run_checks should reject unknown option"
    fi
    teardown_test_env
}

test_run_checks_skip_checks() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "false"
'
    local result
    result=$(qg_run_checks test-tool --skip-checks 2>/dev/null)

    local skipped
    skipped=$(echo "$result" | jq -r '.skipped')

    if [[ "$skipped" == "true" ]]; then
        pass "qg_run_checks --skip-checks skips execution"
    else
        fail "qg_run_checks --skip-checks: skipped=$skipped"
    fi
    teardown_test_env
}

test_run_checks_dry_run() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "false"
'
    local result exit_code=0
    result=$(qg_run_checks test-tool --dry-run 2>/dev/null) || exit_code=$?

    local dry_run status passed planned executed
    dry_run=$(echo "$result" | jq -r '.dry_run')
    status=$(echo "$result" | jq -r '.status')
    passed=$(echo "$result" | jq -r '.passed')
    planned=$(echo "$result" | jq -r '.planned')
    executed=$(echo "$result" | jq -r '.checks[0].executed')

    if [[ "$exit_code" -eq 2 && "$dry_run" == "true" && "$status" == "planned" && \
          "$passed" == "0" && "$planned" == "1" && "$executed" == "false" ]]; then
        pass "qg_run_checks --dry-run is planned-only and cannot pass the gate"
    else
        fail "qg_run_checks --dry-run: exit=$exit_code status=$status dry_run=$dry_run passed=$passed planned=$planned executed=$executed"
    fi
    teardown_test_env
}

test_run_checks_no_checks_configured() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    repo: foo/bar
'
    local result exit_code=0
    result=$(qg_run_checks test-tool 2>/dev/null) || exit_code=$?

    local status total
    status=$(echo "$result" | jq -r '.status')
    total=$(echo "$result" | jq -r '.total')

    if [[ "$exit_code" -eq 4 && "$status" == "config-error" && "$total" == "0" ]]; then
        pass "qg_run_checks rejects a vacuous zero-check gate"
    else
        fail "qg_run_checks: expected config error for zero checks, got exit=$exit_code status=$status total=$total"
    fi
    teardown_test_env
}

test_run_checks_all_pass() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "true"
      - "echo ok"
'
    local result exit_code=0
    result=$(qg_run_checks test-tool 2>/dev/null) || exit_code=$?

    local passed failed total
    passed=$(echo "$result" | jq -r '.passed')
    failed=$(echo "$result" | jq -r '.failed')
    total=$(echo "$result" | jq -r '.total')

    if [[ "$passed" == "2" && "$failed" == "0" && "$total" == "2" && "$exit_code" -eq 0 ]]; then
        pass "qg_run_checks reports all checks passed"
    else
        fail "qg_run_checks: passed=$passed, failed=$failed, exit=$exit_code"
    fi
    teardown_test_env
}

test_run_checks_some_fail() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "true"
      - "false"
      - "echo ok"
'
    local result exit_code=0
    result=$(qg_run_checks test-tool 2>/dev/null) || exit_code=$?

    local passed failed total
    passed=$(echo "$result" | jq -r '.passed')
    failed=$(echo "$result" | jq -r '.failed')
    total=$(echo "$result" | jq -r '.total')

    if [[ "$passed" == "2" && "$failed" == "1" && "$exit_code" -ne 0 ]]; then
        pass "qg_run_checks reports partial failure"
    else
        fail "qg_run_checks partial: passed=$passed, failed=$failed, exit=$exit_code"
    fi
    teardown_test_env
}

test_run_checks_all_fail() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "false"
      - "exit 1"
'
    local result exit_code=0
    result=$(qg_run_checks test-tool 2>/dev/null) || exit_code=$?

    local passed failed
    passed=$(echo "$result" | jq -r '.passed')
    failed=$(echo "$result" | jq -r '.failed')

    if [[ "$passed" == "0" && "$failed" == "2" && "$exit_code" -ne 0 ]]; then
        pass "qg_run_checks reports all checks failed"
    else
        fail "qg_run_checks all fail: passed=$passed, failed=$failed, exit=$exit_code"
    fi
    teardown_test_env
}

test_run_checks_json_output_structure() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "echo test"
'
    local result
    result=$(qg_run_checks test-tool 2>/dev/null)

    local has_tool has_checks has_passed has_failed has_total has_duration
    has_tool=$(echo "$result" | jq 'has("tool")')
    has_checks=$(echo "$result" | jq 'has("checks")')
    has_passed=$(echo "$result" | jq 'has("passed")')
    has_failed=$(echo "$result" | jq 'has("failed")')
    has_total=$(echo "$result" | jq 'has("total")')
    has_duration=$(echo "$result" | jq 'has("duration_ms")')

    if [[ "$has_tool" == "true" && "$has_checks" == "true" && \
          "$has_passed" == "true" && "$has_failed" == "true" && \
          "$has_total" == "true" && "$has_duration" == "true" ]]; then
        pass "qg_run_checks returns complete JSON structure"
    else
        fail "qg_run_checks JSON: missing fields"
    fi
    teardown_test_env
}

test_run_checks_work_dir() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    local work_dir="$TEST_TMPDIR/work"
    mkdir -p "$work_dir"
    echo "marker_file_123" > "$work_dir/marker.txt"

    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "cat marker.txt"
'
    local result
    result=$(qg_run_checks test-tool --work-dir "$work_dir" 2>/dev/null)

    local output
    output=$(echo "$result" | jq -r '.checks[0].output_preview')

    if [[ "$output" == *"marker_file_123"* ]]; then
        pass "qg_run_checks --work-dir runs checks in specified directory"
    else
        fail "qg_run_checks --work-dir: output=$output"
    fi
    teardown_test_env
}

test_run_checks_duration_total() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "sleep 0.05"
      - "sleep 0.05"
'
    local result
    result=$(qg_run_checks test-tool 2>/dev/null)

    local duration_ms
    duration_ms=$(echo "$result" | jq -r '.duration_ms')

    if [[ "$duration_ms" -ge 80 ]]; then
        pass "qg_run_checks measures total duration (${duration_ms}ms)"
    else
        fail "qg_run_checks duration: expected >= 80ms, got ${duration_ms}ms"
    fi
    teardown_test_env
}

test_run_checks_tool_name_in_output() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  my-special-tool:
    checks:
      - "true"
'
    local result
    result=$(qg_run_checks my-special-tool 2>/dev/null)

    local tool
    tool=$(echo "$result" | jq -r '.tool')

    if [[ "$tool" == "my-special-tool" ]]; then
        pass "qg_run_checks includes tool name in output"
    else
        fail "qg_run_checks tool name: expected my-special-tool, got $tool"
    fi
    teardown_test_env
}

test_run_checks_continues_after_failure() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "false"
      - "echo ran_second"
      - "echo ran_third"
'
    local result
    result=$(qg_run_checks test-tool 2>/dev/null) || true

    local check_count
    check_count=$(echo "$result" | jq '.checks | length')

    if [[ "$check_count" == "3" ]]; then
        pass "qg_run_checks continues running checks after failure"
    else
        fail "qg_run_checks: expected 3 checks run, got $check_count"
    fi
    teardown_test_env
}

test_run_checks_checks_array_content() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "echo first"
      - "echo second"
'
    local result
    result=$(qg_run_checks test-tool 2>/dev/null)

    local first_cmd second_cmd
    first_cmd=$(echo "$result" | jq -r '.checks[0].command')
    second_cmd=$(echo "$result" | jq -r '.checks[1].command')

    if [[ "$first_cmd" == "echo first" && "$second_cmd" == "echo second" ]]; then
        pass "qg_run_checks records commands in checks array"
    else
        fail "qg_run_checks commands: first=$first_cmd, second=$second_cmd"
    fi
    teardown_test_env
}

# ============================================================================
# Tests: Exit Codes
# ============================================================================

test_exit_code_success() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "true"
'
    local exit_code=0
    qg_run_checks test-tool >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        pass "qg_run_checks exits 0 on success"
    else
        fail "qg_run_checks exit: expected 0, got $exit_code"
    fi
    teardown_test_env
}

test_exit_code_failure() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "false"
'
    local exit_code=0
    qg_run_checks test-tool >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 1 ]]; then
        pass "qg_run_checks exits 1 on check failure"
    else
        fail "qg_run_checks exit: expected 1, got $exit_code"
    fi
    teardown_test_env
}

test_exit_code_invalid_args() {
    ((TESTS_RUN++))
    setup_test_env

    local exit_code=0
    qg_run_checks --invalid-option test-tool >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 4 ]]; then
        pass "qg_run_checks exits 4 on invalid args"
    else
        fail "qg_run_checks exit: expected 4, got $exit_code"
    fi
    teardown_test_env
}

test_exit_code_skip_checks() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "false"
'
    local exit_code=0
    qg_run_checks test-tool --skip-checks >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        pass "qg_run_checks exits 0 when --skip-checks"
    else
        fail "qg_run_checks skip exit: expected 0, got $exit_code"
    fi
    teardown_test_env
}

# ============================================================================
# Tests: Edge Cases
# ============================================================================

test_check_with_special_chars() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "echo \"quoted string\""
'
    local result
    result=$(qg_run_checks test-tool 2>/dev/null)

    local output
    output=$(echo "$result" | jq -r '.checks[0].output_preview')

    if [[ "$output" == *"quoted string"* ]]; then
        pass "qg_run_checks handles special characters in check"
    else
        fail "qg_run_checks special chars: output=$output"
    fi
    teardown_test_env
}

test_check_with_pipe() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "echo hello | grep hello"
'
    local result exit_code=0
    result=$(qg_run_checks test-tool 2>/dev/null) || exit_code=$?

    local passed
    passed=$(echo "$result" | jq -r '.checks[0].passed')

    if [[ "$passed" == "true" && "$exit_code" -eq 0 ]]; then
        pass "qg_run_checks handles piped commands"
    else
        fail "qg_run_checks pipe: passed=$passed, exit=$exit_code"
    fi
    teardown_test_env
}

test_check_with_and() {
    ((TESTS_RUN++))
    if ! command -v yq &>/dev/null; then
        skip "yq not available"
        return
    fi

    setup_test_env
    create_repos_yaml 'tools:
  test-tool:
    checks:
      - "true && echo success"
'
    local result
    result=$(qg_run_checks test-tool 2>/dev/null)

    local output
    output=$(echo "$result" | jq -r '.checks[0].output_preview')

    if [[ "$output" == *"success"* ]]; then
        pass "qg_run_checks handles && in commands"
    else
        fail "qg_run_checks &&: output=$output"
    fi
    teardown_test_env
}

test_check_long_output_truncated() {
    ((TESTS_RUN++))
    setup_test_env

    # Generate long output (more than 1000 chars)
    local result
    result=$(run_single_check "yes | head -500" "" "false" 2>/dev/null)

    local output_len
    output_len=$(echo "$result" | jq -r '.output_preview | length')

    # Output should be truncated to ~1000 chars
    if [[ "$output_len" -le 1100 ]]; then
        pass "_qg_run_single_check truncates long output"
    else
        fail "_qg_run_single_check: output length $output_len exceeds limit"
    fi
    teardown_test_env
}

test_check_stderr_captured() {
    ((TESTS_RUN++))
    setup_test_env

    local result
    result=$(run_single_check "echo stderr_test >&2" "" "false" 2>/dev/null)

    local output
    output=$(echo "$result" | jq -r '.output_preview')

    if [[ "$output" == *"stderr_test"* ]]; then
        pass "_qg_run_single_check captures stderr"
    else
        fail "_qg_run_single_check stderr: output=$output"
    fi
    teardown_test_env
}

# ============================================================================
# Tests: yq Missing
# ============================================================================

test_get_checks_yq_missing() {
    ((TESTS_RUN++))

    # Skip if yq is available (we can't test missing yq scenario)
    if command -v yq &>/dev/null; then
        # Test by temporarily removing yq from PATH
        setup_test_env
        local old_path="$PATH"
        export PATH="/nonexistent"

        local checks exit_code=0
        checks=$(qg_get_checks "test-tool" 2>/dev/null) || exit_code=$?

        export PATH="$old_path"

        if [[ "$exit_code" -eq 3 && -z "$checks" ]]; then
            pass "qg_get_checks fails closed when yq is missing"
        else
            fail "qg_get_checks yq missing: exit=$exit_code, checks=$checks"
        fi
        teardown_test_env
    else
        # yq already missing, test directly
        setup_test_env
        local checks exit_code=0
        checks=$(qg_get_checks "test-tool" 2>/dev/null) || exit_code=$?

        if [[ "$exit_code" -eq 3 && -z "$checks" ]]; then
            pass "qg_get_checks fails closed when yq is missing"
        else
            fail "qg_get_checks yq missing: exit=$exit_code, checks=$checks"
        fi
        teardown_test_env
    fi
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
    echo "=== Quality Gates Module Tests ==="
    echo ""

    echo "qg_get_checks Tests:"
    test_get_checks_with_yq
    test_get_checks_empty_array
    test_get_checks_missing_section
    test_get_checks_unknown_tool
    test_get_checks_missing_file
    test_get_checks_multiple_checks

    echo ""
    echo "_qg_run_single_check Tests:"
    test_run_single_check_success
    test_run_single_check_failure
    test_run_single_check_output_captured
    test_run_single_check_duration
    test_run_single_check_dry_run
    test_run_single_check_work_dir
    test_run_single_check_json_structure
    test_run_single_check_requires_log_path
    test_run_single_check_nonzero_exit

    echo ""
    echo "qg_run_checks Tests:"
    test_run_checks_no_tool_name
    test_run_checks_help_flag
    test_run_checks_unknown_option
    test_run_checks_skip_checks
    test_run_checks_dry_run
    test_run_checks_no_checks_configured
    test_run_checks_all_pass
    test_run_checks_some_fail
    test_run_checks_all_fail
    test_run_checks_json_output_structure
    test_run_checks_work_dir
    test_run_checks_duration_total
    test_run_checks_tool_name_in_output
    test_run_checks_continues_after_failure
    test_run_checks_checks_array_content

    echo ""
    echo "Exit Code Tests:"
    test_exit_code_success
    test_exit_code_failure
    test_exit_code_invalid_args
    test_exit_code_skip_checks

    echo ""
    echo "Edge Case Tests:"
    test_check_with_special_chars
    test_check_with_pipe
    test_check_with_and
    test_check_long_output_truncated
    test_check_stderr_captured

    echo ""
    echo "yq Missing Tests:"
    test_get_checks_yq_missing

    echo ""
    echo "==========================================="
    echo "Tests run:    $TESTS_RUN"
    echo "Passed:       $TESTS_PASSED"
    echo "Skipped:      $TESTS_SKIPPED"
    echo "Failed:       $TESTS_FAILED"
    echo "==========================================="

    [[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
}

main "$@"
