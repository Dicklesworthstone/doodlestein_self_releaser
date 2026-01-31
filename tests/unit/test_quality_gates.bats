#!/usr/bin/env bats
# test_quality_gates.bats - Unit tests for pre-release quality gates
#
# bd-1jt.5.17: Tests for supply chain security (SLSA, SBOM, quality gates)
#
# Coverage:
# - Quality gate check configuration loading
# - Check execution and result capture
# - Pass/fail/skip behavior
# - JSON output structure
#
# Run: bats tests/unit/test_quality_gates.bats

# Load test harness
load ../helpers/test_harness.bash

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    harness_setup

    # Source the quality gates module
    harness_source_module "quality_gates"

    # Create test config directory
    mkdir -p "$DSR_CONFIG_DIR"

    # Create test repos.yaml with checks
    cat > "$DSR_CONFIG_DIR/repos.yaml" << 'EOF'
tools:
  test-tool:
    repo: test/test-tool
    local_path: /tmp/test-tool
    language: go
    checks:
      - "echo 'check 1 passed'"
      - "echo 'check 2 passed'"

  failing-tool:
    repo: test/failing-tool
    checks:
      - "echo 'check 1 passed'"
      - "false"
      - "echo 'check 3 would run'"

  no-checks-tool:
    repo: test/no-checks-tool
    language: rust

  allow-fail-tool:
    repo: test/allow-fail
    checks:
      - "echo 'required check'"
EOF

    export DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
}

# Helper to skip if command not available
skip_unless_command() {
    local cmd="$1"
    local msg="${2:-$cmd not installed}"
    command -v "$cmd" &>/dev/null || skip "$msg"
}

teardown() {
    harness_teardown
}

# ============================================================================
# Check Configuration Tests
# ============================================================================

@test "qg_get_checks returns configured checks" {
    skip_unless_command yq "yq required for config parsing"

    run qg_get_checks "test-tool"
    [[ "$status" -eq 0 ]]

    # Should return JSON array
    echo "$output" | jq empty

    local count
    count=$(echo "$output" | jq 'length')
    assert_equal "$count" "2"
}

@test "qg_get_checks returns empty array for tool without checks" {
    skip_unless_command yq "yq required for config parsing"

    run qg_get_checks "no-checks-tool"
    [[ "$status" -eq 0 ]]

    local count
    count=$(echo "$output" | jq 'length')
    assert_equal "$count" "0"
}

@test "qg_get_checks returns empty array for unknown tool" {
    skip_unless_command yq "yq required for config parsing"

    run qg_get_checks "nonexistent-tool"
    [[ "$status" -eq 0 ]]

    local count
    count=$(echo "$output" | jq 'length')
    assert_equal "$count" "0"
}

@test "qg_get_checks warns when yq unavailable" {
    # Hide yq temporarily
    function command() {
        if [[ "$2" == "yq" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command

    run qg_get_checks "test-tool"
    # Should return exit code 3 when yq is unavailable
    [ "$status" -eq 3 ]

    # Output should contain empty JSON array (filter out log messages)
    # Note: log messages start with [quality] so we match exactly []
    local json_output
    json_output=$(echo "$output" | grep -E '^\[\]$' | head -1)
    [[ "$json_output" == "[]" ]]
}

# ============================================================================
# Check Execution Tests
# ============================================================================

@test "qg_run_checks executes all checks" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    # Should return JSON with results
    echo "$output" | jq empty

    local passed total
    passed=$(echo "$output" | jq '.passed')
    total=$(echo "$output" | jq '.total')

    assert_equal "$passed" "2"
    assert_equal "$total" "2"
}

@test "qg_run_checks reports failures" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "failing-tool"
    [[ "$status" -ne 0 ]]

    local failed
    failed=$(echo "$output" | jq '.failed')
    assert_equal "$failed" "1"
}

@test "qg_run_checks captures check output" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    # Check first result has output
    local first_output
    first_output=$(echo "$output" | jq -r '.checks[0].output')
    assert_contains "$first_output" "check 1 passed"
}

@test "qg_run_checks records duration" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    local duration
    duration=$(echo "$output" | jq '.duration_ms')
    [[ "$duration" != "null" ]]
    [[ "$duration" -ge 0 ]]
}

# ============================================================================
# Skip Checks Tests
# ============================================================================

@test "qg_run_checks --skip-checks returns success" {
    run qg_run_checks "failing-tool" --skip-checks
    [[ "$status" -eq 0 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output skipped
    json_output=$(echo "$output" | grep -E '^\{' | head -1)
    skipped=$(echo "$json_output" | jq '.skipped')
    assert_equal "$skipped" "true"
}

@test "qg_run_checks --skip-checks does not run checks" {
    run qg_run_checks "failing-tool" --skip-checks
    [[ "$status" -eq 0 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output total
    json_output=$(echo "$output" | grep -E '^\{' | head -1)
    total=$(echo "$json_output" | jq '.total')
    assert_equal "$total" "0"
}

@test "qg_run_checks with no configured checks succeeds" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "no-checks-tool"
    [[ "$status" -eq 0 ]]

    local total
    total=$(echo "$output" | jq '.total')
    assert_equal "$total" "0"
}

# ============================================================================
# Dry Run Tests
# ============================================================================

@test "qg_run_checks --dry-run does not execute checks" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "failing-tool" --dry-run
    [[ "$status" -eq 0 ]]

    # All checks should "pass" in dry-run
    local passed
    passed=$(echo "$output" | jq '.passed')
    assert_equal "$passed" "3"
}

@test "qg_run_checks --dry-run sets dry_run flag" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool" --dry-run
    [[ "$status" -eq 0 ]]

    local dry_run
    dry_run=$(echo "$output" | jq '.dry_run')
    assert_equal "$dry_run" "true"
}

@test "qg_run_checks --dry-run includes check commands" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool" --dry-run
    [[ "$status" -eq 0 ]]

    local cmd
    cmd=$(echo "$output" | jq -r '.checks[0].command')
    assert_contains "$cmd" "echo"
}

# ============================================================================
# Work Directory Tests
# ============================================================================

@test "qg_run_checks --work-dir runs in specified directory" {
    skip_unless_command yq "yq required for config parsing"

    # Create a tool config that uses pwd
    cat > "$DSR_CONFIG_DIR/repos.yaml" << 'EOF'
tools:
  pwd-tool:
    checks:
      - "pwd"
EOF

    local test_dir="$TEST_TMPDIR/work-test"
    mkdir -p "$test_dir"

    run qg_run_checks "pwd-tool" --work-dir "$test_dir"
    [[ "$status" -eq 0 ]]

    local output_content
    output_content=$(echo "$output" | jq -r '.checks[0].output')
    assert_contains "$output_content" "$test_dir"
}

# ============================================================================
# JSON Output Tests
# ============================================================================

@test "qg_run_checks returns valid JSON" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    # Should be valid JSON
    echo "$output" | jq empty
}

@test "qg_run_checks includes tool name" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    local tool
    tool=$(echo "$output" | jq -r '.tool')
    assert_equal "$tool" "test-tool"
}

@test "qg_run_checks checks array contains command and result" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    # Check first result structure
    local has_command has_exit_code has_passed
    has_command=$(echo "$output" | jq '.checks[0] | has("command")')
    has_exit_code=$(echo "$output" | jq '.checks[0] | has("exit_code")')
    has_passed=$(echo "$output" | jq '.checks[0] | has("passed")')

    assert_equal "$has_command" "true"
    assert_equal "$has_exit_code" "true"
    assert_equal "$has_passed" "true"
}

# ============================================================================
# Argument Validation Tests
# ============================================================================

@test "qg_run_checks fails without tool name" {
    run qg_run_checks
    [[ "$status" -ne 0 ]]
}

@test "qg_run_checks fails with unknown option" {
    run qg_run_checks "test-tool" --invalid-option
    [[ "$status" -ne 0 ]]
}

@test "qg_run_checks --help shows usage" {
    run qg_run_checks --help
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "Usage:"
}

# ============================================================================
# Integration Tests
# ============================================================================

@test "qg_run_checks integrates with dsr workflow" {
    skip_unless_command yq "yq required for config parsing"

    # Simulate a pre-release check workflow
    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    local passed failed
    passed=$(echo "$output" | jq '.passed')
    failed=$(echo "$output" | jq '.failed')

    # All checks passed
    assert_equal "$passed" "2"
    assert_equal "$failed" "0"
}

@test "qg_run_checks stops on first failure but reports all" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "failing-tool"
    [[ "$status" -ne 0 ]]

    # Should have run all checks
    local total
    total=$(echo "$output" | jq '.total')
    assert_equal "$total" "3"

    # Should report one failure
    local failed
    failed=$(echo "$output" | jq '.failed')
    assert_equal "$failed" "1"
}
