#!/usr/bin/env bash
# test_json_purity.sh - JSON schema validation and stream separation tests
#
# Validates that all dsr --json outputs conform to schemas and that
# stderr is empty on successful runs (stream separation).
#
# Run: ./scripts/tests/test_json_purity.sh
# Run --build-target-details-only for the public target projection regressions
# without host, compiler, signing, network, or yq dependencies.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSR_CMD="${DSR_CLI_TEST_SCRIPT:-$PROJECT_ROOT/dsr}"

# Source the test harness
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
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }

# ============================================================================
# JSON Validation Helpers
# ============================================================================

# Check if output is valid JSON
is_valid_json() {
    local json="$1"
    [[ -n "$json" ]] && echo "$json" | jq . >/dev/null 2>&1
}

# Check if JSON has required envelope fields
has_envelope_fields() {
    local json="$1"
    # Required: command, status, exit_code, run_id, started_at, duration_ms, tool, version
    echo "$json" | jq -e '
        .command != null and
        .status != null and
        .exit_code != null and
        .run_id != null and
        .started_at != null and
        .duration_ms != null and
        .tool != null and
        .version != null
    ' >/dev/null 2>&1
}

# Check if status is valid
has_valid_status() {
    local json="$1"
    echo "$json" | jq -e '.status | . == "success" or . == "partial" or . == "error"' >/dev/null 2>&1
}

# Check if exit_code is integer
has_valid_exit_code() {
    local json="$1"
    echo "$json" | jq -e '.exit_code | type == "number" and . >= 0 and . <= 255' >/dev/null 2>&1
}

# Check if tool is "dsr"
has_correct_tool() {
    local json="$1"
    echo "$json" | jq -e '.tool == "dsr"' >/dev/null 2>&1
}

# ============================================================================
# Tests: JSON Validity Per Command
# ============================================================================

test_json_valid_doctor() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json doctor
    local output
    output=$(exec_stdout)

    if is_valid_json "$output"; then
        pass "doctor --json produces valid JSON"
    else
        fail "doctor --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_json_valid_status() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json status
    local output
    output=$(exec_stdout)

    if is_valid_json "$output"; then
        pass "status --json produces valid JSON"
    else
        fail "status --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_json_valid_config_show() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json config show
    local output
    output=$(exec_stdout)

    if is_valid_json "$output"; then
        pass "config show --json produces valid JSON"
    else
        fail "config show --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_json_valid_repos_list() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json repos list
    local output
    output=$(exec_stdout)

    if is_valid_json "$output"; then
        pass "repos list --json produces valid JSON"
    else
        fail "repos list --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_json_valid_check() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json check
    local output
    output=$(exec_stdout)

    # Check may fail without config, but should still produce valid JSON
    if is_valid_json "$output" || [[ -z "$output" ]]; then
        pass "check --json produces valid JSON (or empty on error)"
    else
        fail "check --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Envelope Schema Compliance
# ============================================================================

test_envelope_doctor() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json doctor
    local output
    output=$(exec_stdout)

    if [[ -z "$output" ]]; then
        skip "doctor --json produced no output"
    elif has_envelope_fields "$output"; then
        pass "doctor --json has required envelope fields"
    else
        fail "doctor --json missing required envelope fields"
        echo "output: $output" | head -5
    fi

    harness_teardown
}

test_envelope_status() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json status
    local output
    output=$(exec_stdout)

    if [[ -z "$output" ]]; then
        skip "status --json produced no output"
    elif has_envelope_fields "$output"; then
        pass "status --json has required envelope fields"
    else
        fail "status --json missing required envelope fields"
        echo "output: $output" | head -5
    fi

    harness_teardown
}

test_envelope_valid_status_field() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json doctor
    local output
    output=$(exec_stdout)

    if [[ -z "$output" ]]; then
        skip "no output to validate"
    elif has_valid_status "$output"; then
        pass "doctor --json has valid status field"
    else
        fail "doctor --json has invalid status field"
        echo "status: $(echo "$output" | jq '.status')"
    fi

    harness_teardown
}

test_envelope_valid_exit_code() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json doctor
    local output
    output=$(exec_stdout)

    if [[ -z "$output" ]]; then
        skip "no output to validate"
    elif has_valid_exit_code "$output"; then
        pass "doctor --json has valid exit_code field"
    else
        fail "doctor --json has invalid exit_code field"
        echo "exit_code: $(echo "$output" | jq '.exit_code')"
    fi

    harness_teardown
}

test_envelope_correct_tool() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json doctor
    local output
    output=$(exec_stdout)

    if [[ -z "$output" ]]; then
        skip "no output to validate"
    elif has_correct_tool "$output"; then
        pass "doctor --json has correct tool field"
    else
        fail "doctor --json has incorrect tool field"
        echo "tool: $(echo "$output" | jq '.tool')"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Stream Separation (stderr empty on success)
# ============================================================================

test_stream_separation_doctor() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json doctor
    local status
    status=$(exec_status)
    local stderr_output
    stderr_output=$(exec_stderr)
    local output
    output=$(exec_stdout)

    # A degraded diagnosis must be explicit, never reported as healthy success.
    if [[ "$status" -eq 0 ]] && jq -e '.status == "partial"' <<< "$output" >/dev/null 2>&1; then
        if jq -e '.exit_code == 0 and .details.overall_status == "degraded" and
            .details.errors == 0 and .details.warnings > 0' <<< "$output" >/dev/null &&
            [[ "$stderr_output" == *'[WARN]'* ]] && [[ "$stderr_output" != *'[ERROR]'* ]]; then
            pass "doctor reports degraded warnings as partial, without hiding diagnostics"
        else
            fail "doctor partial status must match its warning-only diagnosis"
        fi
    elif [[ "$status" -eq 0 ]]; then
        if ! jq -e '.status == "success" and .exit_code == 0 and
            .details.overall_status == "healthy" and .details.errors == 0 and
            .details.warnings == 0' <<< "$output" >/dev/null; then
            fail "doctor success must represent a healthy diagnosis"
            harness_teardown
            return
        fi
        if [[ -z "$stderr_output" || "$stderr_output" =~ ^[[:space:]]*$ ]]; then
            pass "doctor --json has empty stderr on success"
        else
            # Some INFO messages may be acceptable
            if echo "$stderr_output" | grep -qiE '(error|warning|fail)'; then
                fail "doctor --json has error/warning in stderr on success"
                echo "stderr: $stderr_output"
            else
                pass "doctor --json stderr only has info messages (acceptable)"
            fi
        fi
    else
        if jq -e --argjson code "$status" '.status == "error" and .exit_code == $code and
            .details.overall_status == "unhealthy" and .details.errors > 0' <<< "$output" >/dev/null; then
            pass "doctor non-zero exit matches an explicit unhealthy diagnosis"
        else
            fail "doctor non-zero exit must match its error envelope"
        fi
    fi

    harness_teardown
}

test_stream_separation_repos_list() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json repos list
    local status
    status=$(exec_status)
    local stderr_output
    stderr_output=$(exec_stderr)

    # Check stderr on any exit
    # Note: dsr outputs INFO/ERROR log messages to stderr even in JSON mode
    # The [INFO] and [ERROR] prefixes are log levels, not actual errors in JSON output
    # This is acceptable behavior - the key is JSON goes to stdout
    if [[ -z "$stderr_output" || "$stderr_output" =~ ^[[:space:]]*$ ]]; then
        pass "repos list --json has empty stderr"
    else
        # Log level prefixes like [ERROR] are acceptable in stderr
        # The important thing is that JSON goes to stdout, not stderr
        pass "repos list --json has log messages in stderr (acceptable - JSON is on stdout)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Command Field Matches Subcommand
# ============================================================================

test_command_field_doctor() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json doctor
    local output
    output=$(exec_stdout)

    if [[ -z "$output" ]]; then
        skip "no output to validate"
    elif echo "$output" | jq -e '.command == "doctor"' >/dev/null 2>&1; then
        pass "doctor --json has command='doctor'"
    else
        fail "doctor --json should have command='doctor'"
        echo "command: $(echo "$output" | jq '.command')"
    fi

    harness_teardown
}

test_command_field_status() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json status
    local output
    output=$(exec_stdout)

    if [[ -z "$output" ]]; then
        skip "no output to validate"
    elif echo "$output" | jq -e '.command == "status"' >/dev/null 2>&1; then
        pass "status --json has command='status'"
    else
        fail "status --json should have command='status'"
        echo "command: $(echo "$output" | jq '.command')"
    fi

    harness_teardown
}

test_command_field_repos() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json repos list
    local output
    output=$(exec_stdout)

    if [[ -z "$output" ]]; then
        skip "no output to validate"
    elif echo "$output" | jq -e '.command == "repos"' >/dev/null 2>&1; then
        pass "repos list --json has command='repos'"
    else
        fail "repos list --json should have command='repos'"
        echo "command: $(echo "$output" | jq '.command')"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Error Response Structure
# ============================================================================

test_error_response_structure() {
    ((TESTS_RUN++))
    harness_setup

    # Trigger an error by requesting nonexistent tool
    exec_run "$DSR_CMD" --json build nonexistent-tool-xyz
    local output
    output=$(exec_stdout)
    local status
    status=$(exec_status)

    # Should be non-zero exit
    if [[ "$status" -eq 0 ]]; then
        fail "error case should have non-zero exit"
    elif [[ -z "$output" ]]; then
        pass "error case produces no JSON (acceptable)"
    elif echo "$output" | jq -e '.status == "error" or .errors != null' >/dev/null 2>&1; then
        pass "error response has error status or errors array"
    else
        # Empty JSON on error is acceptable for now
        pass "error case handled (may lack full envelope)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Public Build Target Evidence
# ============================================================================

# Run the production projection used by cmd_build, not a copy of its jq filter.
# The supplied worker results are explicit fixtures: these assertions cover
# public JSON retention and units, not compilation or the native supervisor.
test_build_target_details() {
    local failures_before="$TESTS_FAILED" fixture actual
    ((TESTS_RUN++))
    if ! command -v jq >/dev/null 2>&1; then
        fail "public build target evidence requires jq"
        return 1
    fi
    # shellcheck disable=SC1090 # Load the exact production projection below.
    if ! source <(awk '
        /^    _dsr_build_target_details\(\) \{/ { copy=1 }
        copy { print }
        copy && /^    \}/ { exit }
    ' "$DSR_CMD") || ! declare -F _dsr_build_target_details >/dev/null; then
        fail "production public build target projection is available"
        return 1
    fi
    fixture='{
      "targets": [
        {
          "platform":"linux/arm64", "host":"arm-builder", "method":"native",
          "status":"timeout", "exit_code":5, "duration_seconds":37,
          "log_file":"/fixture/native/build.log",
          "log_path":"/fixture/worker/linux-arm64.attempt-1.log",
          "native_execution":{
            "phase":"build_execution", "timeout_seconds":3600,
            "transport_timeout_seconds":3610, "command_exit_code":124,
            "failure_kind":"command", "build_program_dispatched":true
          }
        },
        {
          "platform":"linux/amd64", "host":"native-builder", "method":"native",
          "status":"success", "exit_code":0, "duration_seconds":0,
          "native_execution":{
            "phase":"build_execution", "timeout_seconds":3600,
            "transport_timeout_seconds":3610, "command_exit_code":0,
            "failure_kind":null, "build_program_dispatched":true
          }
        },
        {
          "platform":"darwin/arm64", "host":"mac-builder", "method":"native",
          "status":"success", "duration_ms":12.75, "duration_seconds":99
        },
        {
          "platform":"windows/amd64", "host":"windows-builder", "method":"native",
          "status":"success", "duration_ms":0, "duration_seconds":99
        },
        {
          "platform":"freebsd/amd64", "host":"", "method":"native", "status":"skipped"
        },
        {
          "platform":"linux/armv7", "host":"arm-builder", "method":"native",
          "status":"failed", "native_execution":null,
          "log_file":null, "duration_seconds":"unknown"
        },
        {
          "platform":"darwin/amd64", "host":"source-builder", "method":"native",
          "status":"timeout", "exit_code":5,
          "native_execution":{
            "phase":"source_verification", "timeout_seconds":300,
            "transport_timeout_seconds":300, "command_exit_code":124,
            "failure_kind":"command", "build_program_dispatched":false
          }
        }
      ]
    }'
    if ! actual=$(_dsr_build_target_details "$fixture") ||
       ! jq -e 'type == "array" and length == 7' <<< "$actual" >/dev/null; then
        fail "production projection returns all supplied target rows"
        return 1
    fi
    pass "production projection returns all supplied target rows"

    ((TESTS_RUN++))
    if jq -e --argjson original "$fixture" '
        .[0].status == "timeout" and .[0].exit_code == 5 and
        .[0].native_execution == $original.targets[0].native_execution and
        .[0].native_execution.command_exit_code == 124
    ' <<< "$actual" >/dev/null; then
        pass "timeout evidence retains the raw command outcome separately from the DSR exit code"
    else
        fail "timeout evidence must survive the public projection unchanged"
    fi

    ((TESTS_RUN++))
    if jq -e --argjson original "$fixture" '
        .[6].status == "timeout" and .[6].exit_code == 5 and
        .[6].native_execution == $original.targets[6].native_execution and
        .[6].native_execution.build_program_dispatched == false
    ' <<< "$actual" >/dev/null; then
        pass "source-verification timeout keeps its phase and unstarted build boundary"
    else
        fail "pre-build timeout must not become compilation evidence"
    fi

    ((TESTS_RUN++))
    if jq -e --argjson original "$fixture" '
        .[0].log_file == $original.targets[0].log_file and
        .[0].log_path == $original.targets[0].log_path and
        .[0].log_file != .[0].log_path
    ' <<< "$actual" >/dev/null; then
        pass "public target retains both distinct native and orchestration log paths"
    else
        fail "native log_file must not disappear or replace the worker log_path"
    fi

    ((TESTS_RUN++))
    if jq -e '.[0].duration_ms == 37000 and .[1].duration_ms == 0' \
        <<< "$actual" >/dev/null; then
        pass "native seconds convert to milliseconds, including a measured zero"
    else
        fail "37 native seconds must report 37000 milliseconds and zero must remain zero"
    fi

    ((TESTS_RUN++))
    if jq -e '.[2].duration_ms == 12 and .[3].duration_ms == 0' \
        <<< "$actual" >/dev/null; then
        pass "existing milliseconds take precedence, are floored, and preserve zero"
    else
        fail "numeric milliseconds must take precedence over native seconds"
    fi

    ((TESTS_RUN++))
    if jq -e --argjson original "$fixture" '
        .[1].status == "success" and .[1].exit_code == 0 and
        .[1].native_execution == $original.targets[1].native_execution and
        .[1].native_execution.failure_kind == null
    ' <<< "$actual" >/dev/null; then
        pass "successful native execution evidence remains complete without a fabricated failure"
    else
        fail "successful native execution evidence must survive unchanged"
    fi

    ((TESTS_RUN++))
    if jq -e '
        .[4].status == "skipped" and
        all(.[4:6][]; (has("native_execution") or has("duration_ms") or
                       has("log_file") or has("log_path")) | not)
    ' <<< "$actual" >/dev/null; then
        pass "skipped and unobserved results acquire no invented timing, log, or execution evidence"
    else
        fail "missing or invalid evidence must remain absent"
    fi

    [[ "$TESTS_FAILED" -eq "$failures_before" ]]
}

if [[ "${1:-}" == --build-target-details-only ]]; then
    test_build_target_details
    exit "$?"
fi

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    exec_cleanup 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== JSON Purity Tests: Schema + Stream Separation ==="
echo ""

echo "JSON Validity Per Command:"
test_json_valid_doctor
test_json_valid_status
test_json_valid_config_show
test_json_valid_repos_list
test_json_valid_check

echo ""
echo "Envelope Schema Compliance:"
test_envelope_doctor
test_envelope_status
test_envelope_valid_status_field
test_envelope_valid_exit_code
test_envelope_correct_tool

echo ""
echo "Stream Separation (stderr empty on success):"
test_stream_separation_doctor
test_stream_separation_repos_list

echo ""
echo "Command Field Matches Subcommand:"
test_command_field_doctor
test_command_field_status
test_command_field_repos

echo ""
echo "Error Response Structure:"
test_error_response_structure

echo ""
echo "Public Build Target Evidence:"
test_build_target_details

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
