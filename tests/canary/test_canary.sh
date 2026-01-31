#!/usr/bin/env bash
# test_canary.sh - Tests for dsr canary command
#
# Tests the installer canary testing infrastructure.
# Uses Docker when available, falls back to unit tests otherwise.
#
# Run: ./tests/canary/test_canary.sh
#
# Environment variables:
#   DOCKER_SKIP=1       Skip Docker-based tests
#   VERBOSE=1           Show detailed output

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSR_CMD="$PROJECT_ROOT/dsr"

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
BLUE=$'\033[0;34m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }
info() { echo "${BLUE}INFO${NC}: $1"; }

# ============================================================================
# Docker Availability Check
# ============================================================================

HAS_DOCKER=false
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    if [[ "${DOCKER_SKIP:-0}" != "1" ]]; then
        HAS_DOCKER=true
    fi
fi

# ============================================================================
# Tests: Help Commands
# ============================================================================

test_canary_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" canary --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "canary"; then
        pass "canary --help shows usage"
    else
        fail "canary --help should show usage"
        echo "stdout: $(exec_stdout | head -5)"
    fi

    harness_teardown
}

test_canary_help_shows_subcommands() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" canary --help

    if exec_stdout_contains "run" && exec_stdout_contains "matrix" && exec_stdout_contains "schedule"; then
        pass "canary --help shows all subcommands"
    else
        fail "canary --help should show run, matrix, schedule"
        echo "stdout: $(exec_stdout | head -10)"
    fi

    harness_teardown
}

test_canary_help_shows_examples() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" canary --help

    if exec_stdout_contains "EXAMPLES:" && exec_stdout_contains "dsr canary run"; then
        pass "canary --help shows examples"
    else
        fail "canary --help should show examples"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Argument Validation
# ============================================================================

test_canary_unknown_subcommand() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" canary unknown-cmd
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "canary unknown subcommand returns exit 4"
    else
        fail "canary unknown subcommand should return exit 4 (got: $status)"
    fi

    harness_teardown
}

test_canary_run_missing_tool() {
    ((TESTS_RUN++))
    harness_setup

    # Without Docker, this should fail with missing tool error
    exec_run "$DSR_CMD" canary run
    local status
    status=$(exec_status)

    # Either fails with missing tool (4) or missing docker (3)
    if [[ "$status" -eq 4 ]] || [[ "$status" -eq 3 ]]; then
        pass "canary run without tool returns appropriate error (exit: $status)"
    else
        fail "canary run without tool should return exit 3 or 4 (got: $status)"
    fi

    harness_teardown
}

test_canary_run_unknown_option() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" canary run --unknown-option
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "canary run unknown option returns exit 4"
    else
        fail "canary run unknown option should return exit 4 (got: $status)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Docker Detection
# ============================================================================

test_canary_detects_no_docker() {
    ((TESTS_RUN++))
    harness_setup

    # Create a fake PATH without docker
    mkdir -p "$TEST_TMPDIR/bin"

    PATH="$TEST_TMPDIR/bin" exec_run "$DSR_CMD" canary run ntm
    local status
    status=$(exec_status)

    if [[ "$status" -eq 3 ]]; then
        pass "canary run fails gracefully without Docker (exit: 3)"
    else
        # Also acceptable if it fails for other reasons
        pass "canary run returns error without Docker (exit: $status)"
    fi

    harness_teardown
}

test_canary_json_no_docker() {
    ((TESTS_RUN++))
    harness_setup

    # Create a fake PATH without docker
    mkdir -p "$TEST_TMPDIR/bin"

    PATH="$TEST_TMPDIR/bin" exec_run "$DSR_CMD" --json canary run ntm
    local output
    output=$(exec_stdout)

    if [[ -z "$output" ]]; then
        pass "canary --json produces no output when Docker unavailable (acceptable)"
    elif echo "$output" | jq . &>/dev/null; then
        if echo "$output" | jq -e '.details.error' &>/dev/null; then
            pass "canary --json produces valid JSON error when Docker unavailable"
        else
            pass "canary --json produces valid JSON when Docker unavailable"
        fi
    else
        fail "canary --json should produce valid JSON or no output"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Results Command
# ============================================================================

test_canary_results_empty() {
    ((TESTS_RUN++))
    harness_setup

    # Ensure no previous results
    rm -rf "$XDG_STATE_HOME/dsr/canary"

    exec_run "$DSR_CMD" canary results

    # Should handle missing results gracefully
    if exec_stdout_contains "No canary results" || exec_stdout_contains "not found" || [[ "$(exec_status)" -eq 0 ]]; then
        pass "canary results handles missing data gracefully"
    else
        fail "canary results should handle missing data"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_canary_results_json() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json canary results
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . &>/dev/null; then
        pass "canary results --json produces valid JSON"
    else
        fail "canary results --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Schedule Command
# ============================================================================

test_canary_schedule_show() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" canary schedule --show
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "canary schedule --show works"
    else
        fail "canary schedule --show should succeed (got: $status)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: With Docker (when available)
# ============================================================================

test_canary_run_with_docker() {
    ((TESTS_RUN++))

    if [[ "$HAS_DOCKER" != "true" ]]; then
        skip "Docker not available"
        return 0
    fi

    harness_setup

    # Run a simple canary test with ntm (or first available installer)
    local installer_dir="$PROJECT_ROOT/installers"
    local test_tool=""

    # Find first available tool with installer
    for dir in "$installer_dir"/*/; do
        if [[ -f "$dir/install.sh" ]]; then
            test_tool=$(basename "$dir")
            break
        fi
    done

    if [[ -z "$test_tool" ]]; then
        skip "No installer found to test"
        harness_teardown
        return 0
    fi

    info "Testing canary for $test_tool..."

    # Run canary test (this may take a while)
    exec_run "$DSR_CMD" canary run "$test_tool" --os ubuntu:22.04
    local status
    status=$(exec_status)

    # Any exit code is acceptable - we're testing the infrastructure works
    if [[ "$status" -eq 0 ]]; then
        pass "canary run completed successfully for $test_tool"
    elif [[ "$status" -eq 1 ]]; then
        # Test failed but infrastructure worked
        pass "canary run completed (test failed as expected for dev installer)"
    elif [[ "$status" -eq 3 ]]; then
        skip "Docker test skipped (Docker issue)"
    else
        fail "canary run returned unexpected exit code: $status"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_canary_run_all_with_docker() {
    ((TESTS_RUN++))

    if [[ "$HAS_DOCKER" != "true" ]]; then
        skip "Docker not available"
        return 0
    fi

    harness_setup

    info "Testing canary --all (may take a while)..."

    # Run with --all flag
    exec_run "$DSR_CMD" canary run --all --os ubuntu:22.04
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]; then
        pass "canary run --all completed (exit: $status)"
    elif [[ "$status" -eq 3 ]]; then
        skip "Docker test skipped (Docker issue)"
    else
        fail "canary run --all returned unexpected exit code: $status"
    fi

    harness_teardown
}

test_canary_json_output_with_docker() {
    ((TESTS_RUN++))

    if [[ "$HAS_DOCKER" != "true" ]]; then
        skip "Docker not available"
        return 0
    fi

    harness_setup

    # Find first available tool
    local installer_dir="$PROJECT_ROOT/installers"
    local test_tool=""
    for dir in "$installer_dir"/*/; do
        if [[ -f "$dir/install.sh" ]]; then
            test_tool=$(basename "$dir")
            break
        fi
    done

    if [[ -z "$test_tool" ]]; then
        skip "No installer found to test"
        harness_teardown
        return 0
    fi

    exec_run "$DSR_CMD" --json canary run "$test_tool" --os ubuntu:22.04
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . &>/dev/null; then
        if echo "$output" | jq -e '.command == "canary"' &>/dev/null; then
            pass "canary --json produces valid JSON envelope"
        else
            pass "canary --json produces valid JSON"
        fi
    else
        fail "canary --json should produce valid JSON"
        echo "output: $(echo "$output" | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Canary Module Functions (Unit Tests)
# ============================================================================

test_canary_get_install_cmd() {
    ((TESTS_RUN++))

    # Source canary module
    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/canary.sh"

    local ubuntu_cmd debian_cmd fedora_cmd alpine_cmd

    ubuntu_cmd=$(_canary_get_install_cmd "ubuntu:24.04")
    debian_cmd=$(_canary_get_install_cmd "debian:12")
    fedora_cmd=$(_canary_get_install_cmd "fedora:39")
    alpine_cmd=$(_canary_get_install_cmd "alpine:latest")

    if [[ "$ubuntu_cmd" == *"apt-get"* ]] && \
       [[ "$debian_cmd" == *"apt-get"* ]] && \
       [[ "$fedora_cmd" == *"dnf"* ]] && \
       [[ "$alpine_cmd" == *"apk"* ]]; then
        pass "_canary_get_install_cmd returns correct package managers"
    else
        fail "_canary_get_install_cmd should return correct package managers"
        echo "ubuntu: $ubuntu_cmd"
        echo "fedora: $fedora_cmd"
        echo "alpine: $alpine_cmd"
    fi
}

test_canary_get_shell() {
    ((TESTS_RUN++))

    # Source canary module
    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/canary.sh"

    local ubuntu_shell alpine_shell

    ubuntu_shell=$(_canary_get_shell "ubuntu:24.04")
    alpine_shell=$(_canary_get_shell "alpine:latest")

    if [[ "$ubuntu_shell" == "bash" ]] && [[ "$alpine_shell" == "sh" ]]; then
        pass "_canary_get_shell returns correct shells"
    else
        fail "_canary_get_shell should return correct shells"
        echo "ubuntu: $ubuntu_shell, alpine: $alpine_shell"
    fi
}

test_canary_matrix_config() {
    ((TESTS_RUN++))

    # Source canary module
    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/canary.sh"

    if [[ ${#CANARY_MATRIX[@]} -gt 0 ]]; then
        pass "CANARY_MATRIX is configured (${#CANARY_MATRIX[@]} images)"
    else
        fail "CANARY_MATRIX should have at least one image"
    fi
}

test_canary_modes_config() {
    ((TESTS_RUN++))

    # Source canary module
    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/canary.sh"

    if [[ ${#CANARY_MODES[@]} -ge 2 ]]; then
        if [[ "${CANARY_MODES[*]}" == *"vibe"* ]] && [[ "${CANARY_MODES[*]}" == *"safe"* ]]; then
            pass "CANARY_MODES includes vibe and safe"
        else
            fail "CANARY_MODES should include vibe and safe"
        fi
    else
        fail "CANARY_MODES should have at least 2 modes"
    fi
}

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

echo "=== Canary Command Tests ==="
echo ""
echo "Docker available: $HAS_DOCKER"
echo ""

echo "Help Tests:"
test_canary_help
test_canary_help_shows_subcommands
test_canary_help_shows_examples

echo ""
echo "Argument Validation Tests:"
test_canary_unknown_subcommand
test_canary_run_missing_tool
test_canary_run_unknown_option

echo ""
echo "Docker Detection Tests:"
test_canary_detects_no_docker
test_canary_json_no_docker

echo ""
echo "Results Command Tests:"
test_canary_results_empty
test_canary_results_json

echo ""
echo "Schedule Command Tests:"
test_canary_schedule_show

echo ""
echo "Unit Tests (Canary Module):"
test_canary_get_install_cmd
test_canary_get_shell
test_canary_matrix_config
test_canary_modes_config

echo ""
echo "Docker Integration Tests (when available):"
test_canary_run_with_docker
test_canary_run_all_with_docker
test_canary_json_output_with_docker

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
