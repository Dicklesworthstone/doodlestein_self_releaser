#!/usr/bin/env bats
# test_dispatch.bats - Unit tests for repository dispatch
#
# bd-1jt.3.7: Tests for repository dispatch for cross-repo coordination
#
# Coverage:
# - Event dispatch with payload
# - Release dispatch with idempotent payload
# - Batch dispatch
# - Authentication checks
# - Dry-run mode
#
# Run: bats tests/unit/test_dispatch.bats

# Load test harness
load ../helpers/test_harness.bash

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    harness_setup

    # Source the dispatch module
    harness_source_module "dispatch"

    # Unset tokens for clean tests
    unset GITHUB_TOKEN
}

teardown() {
    harness_teardown
}

# ============================================================================
# Authentication Tests
# ============================================================================

@test "dispatch_check_auth fails without credentials" {
    # Hide gh CLI
    function gh() { return 1; }
    export -f gh

    unset GITHUB_TOKEN

    run dispatch_check_auth
    [[ "$status" -ne 0 ]]
}

@test "dispatch_check_auth succeeds with GITHUB_TOKEN" {
    export GITHUB_TOKEN="test-token"

    run dispatch_check_auth
    [[ "$status" -eq 0 ]]
}

# ============================================================================
# Event Dispatch Tests
# ============================================================================

@test "dispatch_event fails without repo" {
    run dispatch_event
    [[ "$status" -ne 0 ]]
    assert_contains "$output" "Repository required"
}

@test "dispatch_event fails without event type" {
    run dispatch_event "owner/repo"
    [[ "$status" -ne 0 ]]
    assert_contains "$output" "Event type required"
}

@test "dispatch_event validates JSON payload" {
    export GITHUB_TOKEN="test-token"

    run dispatch_event "owner/repo" "test-event" --payload "invalid json" --dry-run
    [[ "$status" -ne 0 ]]
    assert_contains "$output" "Invalid JSON"
}

@test "dispatch_event accepts valid JSON payload" {
    export GITHUB_TOKEN="test-token"

    run dispatch_event "owner/repo" "test-event" --payload '{"key": "value"}' --dry-run
    [[ "$status" -eq 0 ]]
}

@test "dispatch_event --dry-run shows preview" {
    export GITHUB_TOKEN="test-token"

    run dispatch_event "owner/repo" "test-event" --payload '{"foo": "bar"}' --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "dry-run"
    assert_contains "$output" "owner/repo"
    assert_contains "$output" "test-event"
}

@test "dispatch_event requires authentication" {
    # Hide gh CLI and unset token
    function gh() { return 1; }
    export -f gh
    unset GITHUB_TOKEN

    run dispatch_event "owner/repo" "test-event"
    [[ "$status" -ne 0 ]]
}

# ============================================================================
# Release Dispatch Tests
# ============================================================================

@test "dispatch_release --help shows usage" {
    run dispatch_release --help
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "USAGE:"
    assert_contains "$output" "dispatch_release"
}

@test "dispatch_release fails without tool name" {
    run dispatch_release
    [[ "$status" -ne 0 ]]
    assert_contains "$output" "Tool name required"
}

@test "dispatch_release fails without version" {
    run dispatch_release "test-tool"
    [[ "$status" -ne 0 ]]
    assert_contains "$output" "Version required"
}

@test "dispatch_release --dry-run shows preview" {
    export GITHUB_TOKEN="test-token"

    run dispatch_release "test-tool" "v1.0.0" --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "dry-run"
    assert_contains "$output" "test-tool"
    assert_contains "$output" "v1.0.0"
}

@test "dispatch_release normalizes version tag" {
    export GITHUB_TOKEN="test-token"

    # Version without 'v' prefix should be normalized
    run dispatch_release "test-tool" "1.0.0" --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "v1.0.0"
}

@test "dispatch_release includes run_id in output" {
    export GITHUB_TOKEN="test-token"

    run dispatch_release "test-tool" "v1.0.0" --run-id "test-run-123" --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "test-run-123"
}

@test "dispatch_release uses custom repos" {
    export GITHUB_TOKEN="test-token"

    run dispatch_release "test-tool" "v1.0.0" --repos "owner/repo1,owner/repo2" --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "owner/repo1"
    assert_contains "$output" "owner/repo2"
}

# ============================================================================
# Batch Dispatch Tests
# ============================================================================

@test "dispatch_batch fails without event type" {
    run dispatch_batch
    [[ "$status" -ne 0 ]]
    assert_contains "$output" "Event type required"
}

@test "dispatch_batch fails without repos" {
    run dispatch_batch "test-event"
    [[ "$status" -ne 0 ]]
    assert_contains "$output" "Repos required"
}

@test "dispatch_batch --dry-run dispatches to multiple repos" {
    export GITHUB_TOKEN="test-token"

    run dispatch_batch "test-event" --repos "owner/repo1,owner/repo2" --payload '{}' --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "repo1"
    assert_contains "$output" "repo2"
}

# ============================================================================
# JSON Output Tests
# ============================================================================

@test "dispatch_release_json returns valid JSON" {
    export GITHUB_TOKEN="test-token"

    run dispatch_release_json "test-tool" "v1.0.0" --dry-run
    [[ "$status" -eq 0 ]]

    # Should be valid JSON
    echo "$output" | jq empty
}

@test "dispatch_release_json includes status field" {
    export GITHUB_TOKEN="test-token"

    run dispatch_release_json "test-tool" "v1.0.0" --dry-run

    local json_status
    json_status=$(echo "$output" | jq -r '.status')
    [[ "$json_status" == "success" ]]
}

@test "dispatch_release_json includes duration" {
    export GITHUB_TOKEN="test-token"

    run dispatch_release_json "test-tool" "v1.0.0" --dry-run

    local duration
    duration=$(echo "$output" | jq -r '.duration_seconds')
    [[ "$duration" != "null" ]]
}

# ============================================================================
# Error Handling Tests
# ============================================================================

@test "dispatch_event handles empty payload gracefully" {
    export GITHUB_TOKEN="test-token"

    run dispatch_event "owner/repo" "test-event" --dry-run
    [[ "$status" -eq 0 ]]
}

@test "dispatch_release generates run_id when not provided" {
    export GITHUB_TOKEN="test-token"

    run dispatch_release "test-tool" "v1.0.0" --dry-run
    [[ "$status" -eq 0 ]]

    # Should show Run ID in output
    assert_contains "$output" "Run ID:"
}

@test "dispatch_release includes sha when available" {
    export GITHUB_TOKEN="test-token"

    run dispatch_release "test-tool" "v1.0.0" --sha "abc123def456" --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "abc123def456"
}
