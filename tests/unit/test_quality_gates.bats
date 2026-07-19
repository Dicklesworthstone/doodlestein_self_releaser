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

@test "qg_get_checks fails closed for an unknown tool" {
    skip_unless_command yq "yq required for config parsing"

    run qg_get_checks "nonexistent-tool"
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "not configured"
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

    assert_contains "$output" "yq required"
    ! echo "$output" | grep -Eq '^\[\]$'
}

# ============================================================================
# Check Execution Tests
# ============================================================================

@test "qg_run_checks executes all checks" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    # Should return valid JSON
    echo "$json_output" | jq empty

    local passed total
    passed=$(echo "$json_output" | jq '.passed')
    total=$(echo "$json_output" | jq '.total')

    assert_equal "$passed" "2"
    assert_equal "$total" "2"
}

@test "qg_run_checks reports failures" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "failing-tool"
    [[ "$status" -ne 0 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    local failed
    failed=$(echo "$json_output" | jq '.failed')
    assert_equal "$failed" "1"
}

@test "qg_run_checks captures check output" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    # Check first result has output
    local first_output
    first_output=$(echo "$json_output" | jq -r '.checks[0].output_preview')
    assert_contains "$first_output" "check 1 passed"
}

@test "qg_run_checks records duration" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    local duration
    duration=$(echo "$json_output" | jq '.duration_ms')
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

@test "qg_run_checks with no configured checks fails closed" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "no-checks-tool"
    [[ "$status" -eq 4 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    local total receipt_status
    total=$(echo "$json_output" | jq '.total')
    receipt_status=$(echo "$json_output" | jq -r '.status')
    assert_equal "$total" "0"
    assert_equal "$receipt_status" "config-error"
}

# ============================================================================
# Dry Run Tests
# ============================================================================

@test "qg_run_checks --dry-run does not execute checks" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "failing-tool" --dry-run
    [[ "$status" -eq 2 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    # Every check is planned and explicitly not executed; none passes.
    local passed planned executed receipt_status
    passed=$(echo "$json_output" | jq '.passed')
    planned=$(echo "$json_output" | jq '.planned')
    executed=$(echo "$json_output" | jq '[.checks[].executed] | any')
    receipt_status=$(echo "$json_output" | jq -r '.status')
    assert_equal "$passed" "0"
    assert_equal "$planned" "3"
    assert_equal "$executed" "false"
    assert_equal "$receipt_status" "planned"
}

@test "qg_run_checks --dry-run sets dry_run flag" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool" --dry-run
    [[ "$status" -eq 2 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    local dry_run
    dry_run=$(echo "$json_output" | jq '.dry_run')
    assert_equal "$dry_run" "true"
}

@test "qg_run_checks --dry-run includes check commands" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool" --dry-run
    [[ "$status" -eq 2 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    local cmd
    cmd=$(echo "$json_output" | jq -r '.checks[0].command')
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

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    local output_content
    output_content=$(echo "$json_output" | jq -r '.checks[0].output_preview')
    assert_contains "$output_content" "$test_dir"
}

# ============================================================================
# JSON Output Tests
# ============================================================================

@test "qg_run_checks returns valid JSON" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    # Should be valid JSON
    echo "$json_output" | jq empty
}

@test "qg_run_checks includes tool name" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    local tool
    tool=$(echo "$json_output" | jq -r '.tool')
    assert_equal "$tool" "test-tool"
}

@test "qg_run_checks checks array contains command and result" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "test-tool"
    [[ "$status" -eq 0 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    # Check first result structure
    local has_command has_exit_code has_passed has_log_path has_log_sha log_path expected_sha actual_sha
    has_command=$(echo "$json_output" | jq '.checks[0] | has("command")')
    has_exit_code=$(echo "$json_output" | jq '.checks[0] | has("exit_code")')
    has_passed=$(echo "$json_output" | jq '.checks[0] | has("passed")')
    has_log_path=$(echo "$json_output" | jq '.checks[0] | has("log_path")')
    has_log_sha=$(echo "$json_output" | jq '.checks[0] | has("log_sha256")')
    log_path=$(echo "$json_output" | jq -r '.checks[0].log_path')
    expected_sha=$(echo "$json_output" | jq -r '.checks[0].log_sha256')
    actual_sha=$(_qg_sha256 "$log_path")

    assert_equal "$has_command" "true"
    assert_equal "$has_exit_code" "true"
    assert_equal "$has_passed" "true"
    assert_equal "$has_log_path" "true"
    assert_equal "$has_log_sha" "true"
    [[ -f "$log_path" ]]
    assert_equal "$actual_sha" "$expected_sha"
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

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    local passed failed
    passed=$(echo "$json_output" | jq '.passed')
    failed=$(echo "$json_output" | jq '.failed')

    # All checks passed
    assert_equal "$passed" "2"
    assert_equal "$failed" "0"
}

@test "qg_run_checks continues after failure and reports all" {
    skip_unless_command yq "yq required for config parsing"

    run qg_run_checks "failing-tool"
    [[ "$status" -ne 0 ]]

    # Extract JSON from output (may have log messages mixed in)
    local json_output
    json_output=$(echo "$output" | grep -E '^\{' | head -1)

    # Should have run all checks
    local total
    total=$(echo "$json_output" | jq '.total')
    assert_equal "$total" "3"

    # Should report one failure
    local failed
    failed=$(echo "$json_output" | jq '.failed')
    assert_equal "$failed" "1"
}

@test "qg_run_checks invalidates a receipt when source moves" {
    skip_unless_command yq "yq required for config parsing"
    skip_unless_command git "git required for source snapshots"

    cat > "$DSR_CONFIG_DIR/repos.yaml" << 'EOF'
tools:
  moving-tool:
    checks:
      - "printf changed >> tracked.txt"
EOF

    local work_dir="$TEST_TMPDIR/moving-source"
    mkdir -p "$work_dir"
    git -C "$work_dir" init -q
    git -C "$work_dir" config user.name "DSR Test"
    git -C "$work_dir" config user.email "dsr-test@example.invalid"
    printf 'before\n' > "$work_dir/tracked.txt"
    git -C "$work_dir" add tracked.txt
    git -C "$work_dir" commit -qm baseline

    run qg_run_checks "moving-tool" --work-dir "$work_dir"
    [[ "$status" -eq 1 ]]

    local json_output receipt_status before after passed
    json_output=$(echo "$output" | grep -E '^\{' | head -1)
    receipt_status=$(echo "$json_output" | jq -r '.status')
    before=$(echo "$json_output" | jq -r '.source_before')
    after=$(echo "$json_output" | jq -r '.source_after')
    passed=$(echo "$json_output" | jq '.passed')

    assert_equal "$receipt_status" "invalidated-moving-source"
    [[ "$before" != "$after" ]]
    assert_equal "$passed" "1"
}
