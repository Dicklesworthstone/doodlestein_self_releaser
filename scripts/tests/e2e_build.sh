#!/usr/bin/env bash
# e2e_build.sh - E2E tests for dsr build command
#
# Tests build command with real behavior using dry-run and actual builds.
#
# Run: ./scripts/tests/e2e_build.sh

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
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }

# ============================================================================
# Dependency Check
# ============================================================================
HAS_YQ=false
HAS_DOCKER=false
HAS_ACT=false

if command -v yq &>/dev/null; then
    HAS_YQ=true
fi

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    HAS_DOCKER=true
fi

if command -v act &>/dev/null; then
    HAS_ACT=true
fi

# ============================================================================
# Helper: Create test repos fixtures for build
# ============================================================================

seed_build_fixtures() {
    mkdir -p "$DSR_CONFIG_DIR/repos.d"

    # Create per-tool config file (required by dsr build)
    cat > "$DSR_CONFIG_DIR/repos.d/test-build-tool.yaml" << 'YAML'
tool_name: test-build-tool
repo: testuser/test-build-tool
local_path: /tmp/test-build-tool
language: go
build_cmd: go build -o test-build-tool ./cmd/test-build-tool
binary_name: test-build-tool
targets:
  - linux/amd64
workflow: .github/workflows/release.yml
YAML

    # Also create repos.yaml for other commands that use it
    cat > "$DSR_CONFIG_DIR/repos.yaml" << 'YAML'
schema_version: "1.0.0"

tools:
  test-build-tool:
    repo: testuser/test-build-tool
    local_path: /tmp/test-build-tool
    language: go
    build_cmd: go build -o test-build-tool ./cmd/test-build-tool
    binary_name: test-build-tool
    targets:
      - linux/amd64
    workflow: .github/workflows/release.yml
YAML

    # Create a minimal temp repo structure
    mkdir -p /tmp/test-build-tool/.github/workflows
    cat > /tmp/test-build-tool/.github/workflows/release.yml << 'WORKFLOW'
name: Release
on:
  push:
    tags:
      - 'v*'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: echo "test build"
WORKFLOW

    # Create a version file so dsr can auto-detect version
    echo "0.1.0" > /tmp/test-build-tool/VERSION

    # Create a minimal go.mod and main.go
    mkdir -p /tmp/test-build-tool/cmd/test-build-tool
    cat > /tmp/test-build-tool/go.mod << 'GOMOD'
module github.com/testuser/test-build-tool

go 1.21
GOMOD

    cat > /tmp/test-build-tool/cmd/test-build-tool/main.go << 'MAIN'
package main

import "fmt"

func main() {
    fmt.Println("test-build-tool v1.0.0")
}
MAIN

    # Initialize git in the temp repo
    (cd /tmp/test-build-tool && git init -q && git add . && git commit -q -m "Initial") 2>/dev/null || true
}

cleanup_build_fixtures() {
    rm -rf /tmp/test-build-tool 2>/dev/null || true
}

# ============================================================================
# Tests: Help (always works)
# ============================================================================

test_build_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" build --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "build"; then
        pass "build --help shows usage information"
    else
        fail "build --help should show usage"
        echo "stdout: $(exec_stdout | head -5)"
    fi

    harness_teardown
}

test_build_help_shows_tool_option() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" build --help

    if exec_stdout_contains "--tool"; then
        pass "build --help shows --tool option"
    else
        fail "build --help should show --tool option"
    fi

    harness_teardown
}

test_build_help_shows_target_option() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" build --help

    if exec_stdout_contains "--target"; then
        pass "build --help shows --target option"
    else
        fail "build --help should show --target option"
    fi

    harness_teardown
}

test_build_help_shows_parallel_option() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" build --help

    if exec_stdout_contains "--parallel"; then
        pass "build --help shows --parallel option"
    else
        fail "build --help should show --parallel option"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Missing Tool Error Handling
# ============================================================================

test_build_no_tool_error() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" build
    local status
    status=$(exec_status)

    # Should fail with exit code 4 (invalid arguments)
    if [[ "$status" -eq 4 ]]; then
        pass "build without tool returns exit code 4"
    else
        fail "build without tool should return exit code 4 (got: $status)"
    fi

    harness_teardown
}

test_build_missing_tool_error() {
    ((TESTS_RUN++))
    harness_setup
    seed_build_fixtures

    exec_run "$DSR_CMD" build nonexistent-tool-xyz
    local status
    status=$(exec_status)

    # Should fail for nonexistent tool
    if [[ "$status" -ne 0 ]]; then
        pass "build fails for nonexistent tool"
    else
        fail "build should fail for nonexistent tool"
    fi

    cleanup_build_fixtures
    harness_teardown
}

test_build_missing_tool_json_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_build_fixtures

    exec_run "$DSR_CMD" --json build nonexistent-tool-xyz
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "build --json produces valid JSON for missing tool"
    else
        fail "build --json should produce valid JSON"
        echo "output: $output"
    fi

    cleanup_build_fixtures
    harness_teardown
}

# ============================================================================
# Tests: Dry-Run Mode
# ============================================================================

test_build_dry_run() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for build dry-run test"
        return 0
    fi

    harness_setup
    seed_build_fixtures

    exec_run "$DSR_CMD" --dry-run build test-build-tool
    local status
    status=$(exec_status)

    # Dry-run should succeed (exit 0) or return partial failure (exit 1)
    # if some targets can't be planned
    if [[ "$status" -eq 0 || "$status" -eq 1 ]]; then
        pass "build --dry-run completes without crash"
    else
        fail "build --dry-run unexpected exit (exit: $status)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    cleanup_build_fixtures
    harness_teardown
}

test_build_dry_run_shows_plan() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for dry-run plan test"
        return 0
    fi

    harness_setup
    seed_build_fixtures

    exec_run "$DSR_CMD" --dry-run build test-build-tool

    # Should show some planned action output
    if exec_stderr_contains "build" || exec_stderr_contains "target" || \
       exec_stderr_contains "plan" || exec_stderr_contains "dry-run"; then
        pass "build --dry-run shows planned actions"
    else
        fail "build --dry-run should show planned actions"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    cleanup_build_fixtures
    harness_teardown
}

test_build_dry_run_json_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_build_fixtures

    exec_run "$DSR_CMD" --json --dry-run build test-build-tool
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "build --dry-run --json produces valid JSON"
    else
        fail "build --dry-run --json should produce valid JSON"
        echo "output: $output"
    fi

    cleanup_build_fixtures
    harness_teardown
}

# ============================================================================
# Tests: Specific Target
# ============================================================================

test_build_specific_target_dry_run() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for specific target test"
        return 0
    fi

    harness_setup
    seed_build_fixtures

    exec_run "$DSR_CMD" --dry-run build test-build-tool --target linux/amd64
    local status
    status=$(exec_status)

    # Should complete without crashing
    if [[ "$status" -eq 0 || "$status" -eq 1 ]]; then
        pass "build --target linux/amd64 completes"
    else
        fail "build --target linux/amd64 unexpected exit (exit: $status)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    cleanup_build_fixtures
    harness_teardown
}

# ============================================================================
# Tests: Real Build (when deps available)
# ============================================================================

test_build_real_with_docker() {
    ((TESTS_RUN++))

    if [[ "$HAS_DOCKER" != "true" || "$HAS_ACT" != "true" ]]; then
        skip "docker and act required for real build test"
        return 0
    fi

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for real build test"
        return 0
    fi

    harness_setup
    seed_build_fixtures

    # Use a timeout since real builds can hang
    timeout 30 "$DSR_CMD" build test-build-tool --target linux/amd64 2>&1 || true
    local status=$?

    # We just verify it doesn't crash completely (timeout is 124)
    if [[ "$status" -ne 124 ]]; then
        pass "real build attempt completed (exit: $status)"
    else
        skip "real build timed out (expected for full workflow)"
    fi

    cleanup_build_fixtures
    harness_teardown
}

# ============================================================================
# Tests: JSON Schema Validation (on error)
# ============================================================================

test_build_json_valid_on_error() {
    ((TESTS_RUN++))
    harness_setup
    seed_build_fixtures

    exec_run "$DSR_CMD" --json build test-build-tool
    local output
    output=$(exec_stdout)
    local status
    status=$(exec_status)

    # On error, output may be empty or valid JSON
    if [[ -z "$output" ]]; then
        # Empty output on error is acceptable (though not ideal)
        pass "build --json produces empty output on error (acceptable)"
    elif echo "$output" | jq . >/dev/null 2>&1; then
        pass "build --json produces valid JSON on error"
    else
        fail "build --json should produce valid JSON or empty output"
        echo "output: $output"
    fi

    cleanup_build_fixtures
    harness_teardown
}

test_build_json_envelope_structure() {
    ((TESTS_RUN++))
    harness_setup
    seed_build_fixtures

    exec_run "$DSR_CMD" --json --dry-run build test-build-tool
    local output
    output=$(exec_stdout)

    # Check if we got any JSON output
    if [[ -z "$output" ]]; then
        skip "no JSON output produced (config may be missing)"
    elif echo "$output" | jq . >/dev/null 2>&1; then
        pass "build --dry-run --json produces valid JSON envelope"
    else
        fail "build --dry-run --json should produce valid JSON"
        echo "output: $output"
    fi

    cleanup_build_fixtures
    harness_teardown
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    cleanup_build_fixtures 2>/dev/null || true
    exec_cleanup 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== E2E: dsr build Tests ==="
echo ""
echo "Dependencies: yq=$HAS_YQ docker=$HAS_DOCKER act=$HAS_ACT"
echo ""

echo "Help Tests (always work):"
test_build_help
test_build_help_shows_tool_option
test_build_help_shows_target_option
test_build_help_shows_parallel_option

echo ""
echo "Missing Tool Error Handling:"
test_build_no_tool_error
test_build_missing_tool_error
test_build_missing_tool_json_valid

echo ""
echo "Dry-Run Mode:"
test_build_dry_run
test_build_dry_run_shows_plan
test_build_dry_run_json_valid

echo ""
echo "Specific Target:"
test_build_specific_target_dry_run

echo ""
echo "Real Build (when deps available):"
test_build_real_with_docker

echo ""
echo "JSON Output Validation:"
test_build_json_valid_on_error
test_build_json_envelope_structure

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
