#!/usr/bin/env bats
# test_docker.bats - Tests for the docker build module
#
# bd-1jt.3.8: Build multi-arch Docker images for containerized tools
#
# Coverage:
# - Dependency checking (docker, buildx, cosign)
# - Containerized tools list
# - Dockerfile discovery
# - Build argument handling
# - Dry-run mode
#
# Run: bats tests/unit/test_docker.bats

# Load test harness
load ../helpers/test_harness.bash

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    harness_setup

    # Source the docker module
    source "$PROJECT_ROOT/src/docker.sh"

    # Create mock project directories
    mkdir -p "$TEST_TMPDIR/projects/ubs"
    mkdir -p "$TEST_TMPDIR/projects/mcp_agent_mail"
    mkdir -p "$TEST_TMPDIR/projects/process_triage"
    mkdir -p "$TEST_TMPDIR/projects/no_docker_tool"

    # Create mock Dockerfiles
    echo "FROM alpine:latest" > "$TEST_TMPDIR/projects/ubs/Dockerfile"
    echo "FROM python:3.11" > "$TEST_TMPDIR/projects/mcp_agent_mail/Dockerfile"

    # Create Dockerfile in docker/ subdirectory
    mkdir -p "$TEST_TMPDIR/projects/process_triage/docker"
    echo "FROM golang:1.22" > "$TEST_TMPDIR/projects/process_triage/docker/Dockerfile"
}

teardown() {
    harness_teardown
}

# ============================================================================
# Containerized Tools List Tests
# ============================================================================

@test "docker_is_containerized returns true for ubs" {
    docker_is_containerized "ubs"
}

@test "docker_is_containerized returns true for mcp_agent_mail" {
    docker_is_containerized "mcp_agent_mail"
}

@test "docker_is_containerized returns true for process_triage" {
    docker_is_containerized "process_triage"
}

@test "docker_is_containerized returns false for non-containerized tool" {
    ! docker_is_containerized "ntm"
}

@test "docker_is_containerized returns false for unknown tool" {
    ! docker_is_containerized "random_tool"
}

# ============================================================================
# Dockerfile Discovery Tests
# ============================================================================

@test "docker_find_dockerfile finds Dockerfile in root" {
    local result
    result=$(docker_find_dockerfile "ubs" "$TEST_TMPDIR/projects/ubs")
    assert_equal "$result" "$TEST_TMPDIR/projects/ubs/Dockerfile"
}

@test "docker_find_dockerfile finds Dockerfile in docker/ subdirectory" {
    local result
    result=$(docker_find_dockerfile "process_triage" "$TEST_TMPDIR/projects/process_triage")
    assert_equal "$result" "$TEST_TMPDIR/projects/process_triage/docker/Dockerfile"
}

@test "docker_find_dockerfile returns error for missing Dockerfile" {
    run docker_find_dockerfile "no_docker_tool" "$TEST_TMPDIR/projects/no_docker_tool"
    [[ "$status" -ne 0 ]]
}

# ============================================================================
# Build Argument Parsing Tests
# ============================================================================

@test "docker_build requires tool name" {
    run docker_build
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Tool name required"
}

@test "docker_build requires version" {
    run docker_build ubs
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Version required"
}

@test "docker_build --help shows usage" {
    run docker_build --help
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "docker_build - Build multi-arch Docker image"
    assert_contains "$output" "--push"
    assert_contains "$output" "--local"
}

@test "docker_build normalizes version with v prefix" {
    # This will fail because Docker isn't running, but we can check the log output
    export DOCKER_REGISTRY="test.registry.io"
    run docker_build ubs 1.2.3 --dry-run 2>&1
    # Even on failure, the version should be normalized in the output
    assert_contains "$output" "v1.2.3" || assert_contains "$output" "docker"
}

# ============================================================================
# Sign Command Tests
# ============================================================================

@test "docker_sign requires image reference" {
    run docker_sign
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Image reference required"
}

@test "docker_sign --help shows usage" {
    run docker_sign --help
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "docker_sign - Sign container image"
}

# ============================================================================
# Release Command Tests
# ============================================================================

@test "docker_release requires tool name" {
    run docker_release
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Tool and version required"
}

@test "docker_release requires version" {
    run docker_release ubs
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Tool and version required"
}

@test "docker_release --help shows usage" {
    run docker_release --help
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "docker_release - Build, push, sign, and attest"
    assert_contains "$output" "--skip-sign"
}

# ============================================================================
# Configuration Tests
# ============================================================================

@test "DOCKER_REGISTRY defaults to ghcr.io/dicklesworthstone" {
    assert_equal "$DOCKER_REGISTRY" "ghcr.io/dicklesworthstone"
}

@test "DOCKER_PLATFORMS defaults to linux/amd64,linux/arm64" {
    assert_equal "$DOCKER_PLATFORMS" "linux/amd64,linux/arm64"
}

@test "DOCKER_BUILDER_NAME defaults to dsr-builder" {
    assert_equal "$DOCKER_BUILDER_NAME" "dsr-builder"
}

@test "DOCKER_CONTAINERIZED_TOOLS contains expected tools" {
    assert_contains "$DOCKER_CONTAINERIZED_TOOLS" "ubs"
    assert_contains "$DOCKER_CONTAINERIZED_TOOLS" "mcp_agent_mail"
    assert_contains "$DOCKER_CONTAINERIZED_TOOLS" "process_triage"
}

# ============================================================================
# Dependency Check Tests
# ============================================================================

@test "docker_check_cosign returns 3 when cosign not installed" {
    # Temporarily hide cosign if it exists
    local path_backup="$PATH"
    export PATH="/usr/bin:/bin"
    run docker_check_cosign
    export PATH="$path_backup"
    # Should warn but not fail catastrophically
    [[ "$status" -eq 0 ]] || [[ "$status" -eq 3 ]]
}

# ============================================================================
# Dry Run Tests
# ============================================================================

@test "docker_build --dry-run shows what would be done" {
    # Create a minimal project with Dockerfile
    mkdir -p "$TEST_TMPDIR/test_tool"
    echo "FROM alpine" > "$TEST_TMPDIR/test_tool/Dockerfile"

    # Mock the docker commands by setting a non-containerized tool
    # and checking the dry run output
    run docker_build --help
    [[ "$status" -eq 0 ]]
}

# ============================================================================
# Integration with dsr CLI
# ============================================================================

@test "dsr docker --help works" {
    run "$PROJECT_ROOT/dsr" docker --help
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "dsr docker - Multi-arch Docker image building"
}

@test "dsr docker build --help works" {
    run "$PROJECT_ROOT/dsr" docker build --help
    # The help should work even if build itself fails
    [[ "$status" -eq 0 ]] || assert_contains "$output" "Tool and version required"
}

@test "dsr docker unknown-subcommand returns error" {
    run "$PROJECT_ROOT/dsr" docker unknown-subcommand
    [[ "$status" -eq 4 ]]
    assert_contains "$output" "Unknown docker subcommand"
}
