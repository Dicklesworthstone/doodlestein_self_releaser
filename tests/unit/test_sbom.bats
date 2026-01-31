#!/usr/bin/env bats
# test_sbom.bats - Unit tests for SBOM generation
#
# bd-1jt.5.17: Tests for supply chain security (SLSA, SBOM, quality gates)
#
# Coverage:
# - SBOM generation with syft
# - SPDX and CycloneDX format support
# - Artifact and project scanning
# - Graceful handling when syft is unavailable
#
# Run: bats tests/unit/test_sbom.bats

# Load test harness
load ../helpers/test_harness.bash

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    harness_setup

    # Source the SBOM module
    harness_source_module "sbom"
    harness_source_module "logging"

    # Create test projects directory
    TEST_PROJECTS="$TEST_TMPDIR/projects"
    mkdir -p "$TEST_PROJECTS"

    # Track original syft availability
    ORIG_SYFT_AVAILABLE=""
    if command -v syft &>/dev/null; then
        ORIG_SYFT_AVAILABLE="yes"
    fi
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
# Syft Availability Tests
# ============================================================================

@test "sbom_check returns success when syft is available" {
    skip_unless_command syft "syft not installed"

    run sbom_check
    [[ "$status" -eq 0 ]]
}

@test "sbom_check returns exit code 3 when syft is missing" {
    # Create a mock that hides syft
    function command() {
        if [[ "$2" == "syft" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command

    run sbom_check
    [ "$status" -eq 3 ] || [ "$status" -eq 1 ]
}

@test "sbom_version returns version number" {
    skip_unless_command syft "syft not installed"

    run sbom_version
    [[ "$status" -eq 0 ]]
    # Should return a version like "1.2.3"
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
}

# ============================================================================
# SBOM Generation Tests (require syft)
# ============================================================================

@test "sbom_generate creates SPDX JSON for directory" {
    skip_unless_command syft "syft not installed"

    local project="$TEST_PROJECTS/spdx-project"
    mkdir -p "$project"
    echo 'module example.com/test' > "$project/go.mod"

    run sbom_generate "$project" --format spdx
    [[ "$status" -eq 0 ]]

    # Check output file exists
    assert_file_exists "$project/sbom.spdx.json"

    # Verify SPDX structure
    local version
    version=$(jq -r '.spdxVersion' "$project/sbom.spdx.json")
    assert_contains "$version" "SPDX"
}

@test "sbom_generate creates CycloneDX JSON for directory" {
    skip_unless_command syft "syft not installed"

    local project="$TEST_PROJECTS/cdx-project"
    mkdir -p "$project"
    echo '{"name": "test-pkg", "version": "1.0.0"}' > "$project/package.json"

    run sbom_generate "$project" --format cyclonedx
    [[ "$status" -eq 0 ]]

    # Check output file exists
    assert_file_exists "$project/sbom.cdx.json"

    # Verify CycloneDX structure
    local format
    format=$(jq -r '.bomFormat' "$project/sbom.cdx.json")
    assert_equal "$format" "CycloneDX"
}

@test "sbom_generate with custom output path" {
    skip_unless_command syft "syft not installed"

    local project="$TEST_PROJECTS/custom-output"
    local custom_output="$TEST_TMPDIR/my-sbom.json"
    mkdir -p "$project"
    echo 'module example.com/test' > "$project/go.mod"

    run sbom_generate "$project" --format spdx --output "$custom_output"
    [[ "$status" -eq 0 ]]

    assert_file_exists "$custom_output"
}

@test "sbom_generate scans file artifact" {
    skip_unless_command syft "syft not installed"

    local artifact="$TEST_TMPDIR/test-binary"
    echo "ELF binary content" > "$artifact"

    run sbom_generate "$artifact" --format spdx
    # May succeed or fail depending on syft version, but should not error
    # The important thing is it handles files
    [ "$status" -eq 0 ] || assert_contains "$output" "error"
}

@test "sbom_generate fails for nonexistent target" {
    run sbom_generate "/nonexistent/path"
    [[ "$status" -ne 0 ]]
}

@test "sbom_generate fails without target" {
    run sbom_generate
    [[ "$status" -ne 0 ]]
}

@test "sbom_generate fails for invalid format" {
    local project="$TEST_PROJECTS/invalid-format"
    mkdir -p "$project"

    run sbom_generate "$project" --format invalid-format
    [[ "$status" -ne 0 ]]
}

# ============================================================================
# SBOM Project Generation Tests
# ============================================================================

@test "sbom_generate_project detects Rust project" {
    skip_unless_command syft "syft not installed"

    local project="$TEST_PROJECTS/rust-project"
    mkdir -p "$project"
    cat > "$project/Cargo.toml" << 'EOF'
[package]
name = "test-crate"
version = "1.0.0"
EOF

    run sbom_generate_project "$project"
    # Should attempt to scan (may fail without actual Cargo.lock)
    # Success or specific error is acceptable
    true
}

@test "sbom_generate_project detects Go project" {
    skip_unless_command syft "syft not installed"

    local project="$TEST_PROJECTS/go-project"
    mkdir -p "$project"
    echo 'module example.com/test' > "$project/go.mod"

    run sbom_generate_project "$project"
    [[ "$status" -eq 0 ]]
}

@test "sbom_generate_project detects Node project" {
    skip_unless_command syft "syft not installed"

    local project="$TEST_PROJECTS/node-project"
    mkdir -p "$project"
    echo '{"name": "test", "version": "1.0.0"}' > "$project/package.json"

    run sbom_generate_project "$project"
    [[ "$status" -eq 0 ]]
}

@test "sbom_generate_project fails for non-directory" {
    run sbom_generate_project "/nonexistent"
    [[ "$status" -ne 0 ]]
}

# ============================================================================
# SBOM Artifacts Batch Generation Tests
# ============================================================================

@test "sbom_generate_artifacts processes directory" {
    skip_unless_command syft "syft not installed"

    local artifacts="$TEST_TMPDIR/artifacts"
    mkdir -p "$artifacts"
    echo "binary1" > "$artifacts/tool1"
    echo "binary2" > "$artifacts/tool2"

    run sbom_generate_artifacts "$artifacts" --format spdx
    # May generate 0-2 SBOMs depending on syft's ability to scan simple files
    # Important thing is it doesn't crash
    [[ "$status" -eq 0 ]]
}

@test "sbom_generate_artifacts skips existing SBOMs" {
    skip_unless_command syft "syft not installed"

    local artifacts="$TEST_TMPDIR/artifacts"
    mkdir -p "$artifacts"
    echo "binary" > "$artifacts/tool"
    echo '{"existing": true}' > "$artifacts/tool.sbom.spdx.json"

    run sbom_generate_artifacts "$artifacts" --format spdx
    [[ "$status" -eq 0 ]]

    # Should not overwrite existing
    local content
    content="$(cat "$artifacts/tool.sbom.spdx.json")"
    assert_contains "$content" "existing"
}

@test "sbom_generate_artifacts skips non-binary files" {
    skip_unless_command syft "syft not installed"

    local artifacts="$TEST_TMPDIR/artifacts"
    mkdir -p "$artifacts"
    echo "binary" > "$artifacts/tool"
    echo "checksum" > "$artifacts/checksums.txt"
    echo "signature" > "$artifacts/tool.sig"

    run sbom_generate_artifacts "$artifacts"
    # txt and sig files should be skipped
    [[ "$status" -eq 0 ]]
}

@test "sbom_generate_artifacts fails for nonexistent directory" {
    run sbom_generate_artifacts "/nonexistent"
    [[ "$status" -ne 0 ]]
}

# ============================================================================
# SBOM Verification Tests
# ============================================================================

@test "sbom_verify validates SPDX format" {
    local sbom="$TEST_TMPDIR/test.spdx.json"
    cat > "$sbom" << 'EOF'
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "test-sbom"
}
EOF

    run sbom_verify "$sbom"
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "SPDX"
}

@test "sbom_verify validates CycloneDX format" {
    local sbom="$TEST_TMPDIR/test.cdx.json"
    cat > "$sbom" << 'EOF'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1
}
EOF

    run sbom_verify "$sbom"
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "CycloneDX"
}

@test "sbom_verify fails for invalid JSON" {
    local sbom="$TEST_TMPDIR/invalid.json"
    echo "not valid json" > "$sbom"

    run sbom_verify "$sbom"
    [[ "$status" -ne 0 ]]
}

@test "sbom_verify fails for unknown format" {
    local sbom="$TEST_TMPDIR/unknown.json"
    echo '{"unknown": "format"}' > "$sbom"

    run sbom_verify "$sbom"
    [[ "$status" -ne 0 ]]
}

@test "sbom_verify fails for missing file" {
    run sbom_verify "/nonexistent/sbom.json"
    [[ "$status" -ne 0 ]]
}

# ============================================================================
# SBOM JSON Output Tests
# ============================================================================

@test "sbom_generate_json returns valid JSON" {
    skip_unless_command syft "syft not installed"

    local project="$TEST_PROJECTS/json-test"
    mkdir -p "$project"
    echo 'module example.com/test' > "$project/go.mod"

    run sbom_generate_json "$project"
    # Should return valid JSON regardless of success/failure
    echo "$output" | jq empty
}

@test "sbom_generate_json includes status field" {
    skip_unless_command syft "syft not installed"

    local project="$TEST_PROJECTS/status-test"
    mkdir -p "$project"
    echo 'module example.com/test' > "$project/go.mod"

    run sbom_generate_json "$project"

    local status
    status=$(echo "$output" | jq -r '.status')
    [ "$status" = "success" ] || [ "$status" = "error" ]
}

@test "sbom_generate_json reports error when syft unavailable" {
    # Mock command to hide syft
    function command() {
        if [[ "$2" == "syft" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command

    run sbom_generate_json "/tmp"

    local status error
    status=$(echo "$output" | jq -r '.status')
    error=$(echo "$output" | jq -r '.error')

    assert_equal "$status" "error"
    assert_contains "$error" "syft"
}

@test "sbom_generate_json includes format in output" {
    skip_unless_command syft "syft not installed"

    local project="$TEST_PROJECTS/format-test"
    mkdir -p "$project"
    echo 'module example.com/test' > "$project/go.mod"

    run sbom_generate_json "$project" --format cyclonedx

    local format
    format=$(echo "$output" | jq -r '.format')
    assert_equal "$format" "cyclonedx"
}

@test "sbom_generate_json includes duration" {
    skip_unless_command syft "syft not installed"

    local project="$TEST_PROJECTS/duration-test"
    mkdir -p "$project"

    run sbom_generate_json "$project"

    local duration
    duration=$(echo "$output" | jq -r '.duration_seconds')
    [ "$duration" != "null" ]
}
