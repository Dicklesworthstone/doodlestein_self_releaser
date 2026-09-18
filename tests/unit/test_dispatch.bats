#!/usr/bin/env bats
# Offline public API contracts. Transport and recovery cases live in
# scripts/tests/test_dispatch_delivery.sh and test_dispatch_outbox.sh.
load ../helpers/test_harness.bash

setup() {
    harness_setup
    harness_source_module "dispatch"
    unset DSR_GH_TOKEN GITHUB_TOKEN GH_TOKEN DRY_RUN
    export DSR_STATE_DIR="$TEST_TMPDIR/state"
    PIN=1111111111111111111111111111111111111111
}
teardown() { harness_teardown; }

@test "dispatch_check_auth fails without credentials" {
    function gh() { return 1; }
    export -f gh
    run dispatch_check_auth
    [[ "$status" -eq 3 ]]
}
@test "dispatch_check_auth succeeds with GITHUB_TOKEN" {
    export GITHUB_TOKEN=test-token
    run dispatch_check_auth
    [[ "$status" -eq 0 ]]
}
@test "explicit DSR token has priority" {
    export DSR_GH_TOKEN=first GITHUB_TOKEN=second GH_TOKEN=third
    run _dp_get_token
    [[ "$output" == first ]]
}
@test "dispatch_event fails without repo" {
    run dispatch_event
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Repository required"
}
@test "dispatch_event fails without event type" {
    run dispatch_event owner/repo
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Event type required"
}
@test "dispatch_event validates JSON payload" {
    run dispatch_event owner/repo test-event --payload 'invalid json' --dry-run
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Invalid JSON"
}
@test "dispatch_event accepts valid JSON without auth during dry-run" {
    run dispatch_event owner/repo test-event --payload '{"key":"value"}' --dry-run
    [[ "$status" -eq 0 ]]
}
@test "dispatch_event dry-run identifies planned destination and event" {
    run dispatch_event owner/repo test-event --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "dry-run"
    assert_contains "$output" "owner/repo"
    assert_contains "$output" "test-event"
    assert_contains "$output" "planned"
}
@test "dispatch_event requires authentication for a real POST" {
    function gh() { return 1; }
    export -f gh
    run dispatch_event owner/repo test-event
    [[ "$status" -eq 3 ]]
}
@test "dispatch_release help shows usage" {
    run dispatch_release --help
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "USAGE:"
    assert_contains "$output" "dispatch_release"
}
@test "dispatch_release fails without tool name" {
    run dispatch_release
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Tool name required"
}
@test "dispatch_release fails without version" {
    run dispatch_release test-tool
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Version required"
}
@test "dispatch_release previews an unresolved source without publishing" {
    run dispatch_release test-tool v1.0.0 --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "dry-run"
    assert_contains "$output" "test-tool"
    assert_contains "$output" "unresolved"
    [[ ! -d "$DSR_STATE_DIR" ]]
}
@test "dispatch_release normalizes version tag" {
    run dispatch_release test-tool 1.0.0 --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "v1.0.0"
}
@test "dispatch_release includes selected run ID" {
    run dispatch_release test-tool v1.0.0 --run-id test-run-123 --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "test-run-123"
}
@test "dispatch_release uses custom repos" {
    run dispatch_release test-tool v1.0.0 --repos owner/repo1,owner/repo2 --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "owner/repo1"
    assert_contains "$output" "owner/repo2"
}
@test "dispatch_release requires a full explicit SHA" {
    run dispatch_release test-tool v1.0.0 --sha abc123def456 --dry-run
    [[ "$status" -eq 4 ]]
    run dispatch_release test-tool v1.0.0 --sha "$PIN" --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "$PIN"
}
@test "dispatch_release never infers PWD for source identity" {
    run dispatch_release test-tool v1.0.0
    [[ "$status" -eq 4 ]]
}
@test "dispatch_batch fails without event type or repositories" {
    run dispatch_batch
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Event type required"
    run dispatch_batch test-event
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Repos required"
}
@test "dispatch_batch previews all repos" {
    run dispatch_batch test-event --repos owner/repo1,owner/repo2 --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "repo1"
    assert_contains "$output" "repo2"
}
@test "dispatch_batch validates every target before transport" {
    run dispatch_batch test-event --repos owner/valid,../invalid
    [[ "$status" -eq 4 ]]
}
@test "dispatch_release_json includes status duration and structured details" {
    run dispatch_release_json test-tool v1.0.0 --dry-run
    [[ "$status" -eq 0 ]]
    jq -e '.status=="success" and .exit_code==0 and
           (.duration_seconds|type)=="number" and .details.status=="planned"' <<< "$output"
}
@test "dispatch_release_json preserves failures" {
    run dispatch_release_json test-tool v1.0.0 --sha malformed
    [[ "$status" -eq 4 ]]
    jq -e '.status=="error" and .exit_code==4' <<< "$output"
}
@test "dispatch_release generates deterministic invocation ID" {
    run dispatch_release test-tool v1.0.0 --sha "$PIN" --dry-run
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "Run ID:"
}
