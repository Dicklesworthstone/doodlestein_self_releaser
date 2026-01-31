#!/usr/bin/env bats
# test_slsa.bats - Unit tests for SLSA provenance attestation
#
# bd-1jt.5.17: Tests for supply chain security (SLSA, SBOM, quality gates)
#
# Coverage:
# - SLSA v1 provenance generation
# - In-toto statement structure validation
# - Subject digest verification
# - Artifact tampering detection
#
# Run: bats tests/unit/test_slsa.bats

# Load test harness
load ../helpers/test_harness.bash

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    harness_setup

    # Source the SLSA module
    harness_source_module "slsa"
    harness_source_module "logging"

    # Create test artifacts directory
    TEST_ARTIFACTS="$TEST_TMPDIR/artifacts"
    mkdir -p "$TEST_ARTIFACTS"
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
# SLSA Generation Tests
# ============================================================================

@test "slsa_generate creates valid in-toto statement" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary content" > "$artifact"

    run slsa_generate "$artifact" --builder "dsr/v1"
    [[ "$status" -eq 0 ]]

    # Verify file created
    assert_file_exists "${artifact}.intoto.jsonl"

    # Verify JSON structure
    local stmt
    stmt="$(cat "${artifact}.intoto.jsonl")"

    # Check in-toto statement type
    local stmt_type
    stmt_type=$(echo "$stmt" | jq -r '._type')
    assert_equal "$stmt_type" "https://in-toto.io/Statement/v1"

    # Check predicate type
    local pred_type
    pred_type=$(echo "$stmt" | jq -r '.predicateType')
    assert_equal "$pred_type" "https://slsa.dev/provenance/v1"
}

@test "slsa_generate includes correct subject digest" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary content for hashing" > "$artifact"

    # Calculate expected SHA256
    local expected_sha256
    expected_sha256="$(sha256sum "$artifact" | cut -d' ' -f1)"

    run slsa_generate "$artifact"
    [[ "$status" -eq 0 ]]

    # Extract actual digest from provenance
    local actual_sha256
    actual_sha256="$(jq -r '.subject[0].digest.sha256' "${artifact}.intoto.jsonl")"

    assert_equal "$actual_sha256" "$expected_sha256"
}

@test "slsa_generate includes artifact name" {
    local artifact="$TEST_ARTIFACTS/my-tool-v1.0.0"
    echo "tool binary" > "$artifact"

    run slsa_generate "$artifact"
    [[ "$status" -eq 0 ]]

    local name
    name="$(jq -r '.subject[0].name' "${artifact}.intoto.jsonl")"
    assert_equal "$name" "my-tool-v1.0.0"
}

@test "slsa_generate includes builder ID" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary" > "$artifact"

    run slsa_generate "$artifact" --builder "https://example.com/builder/v2"
    [[ "$status" -eq 0 ]]

    local builder_id
    builder_id="$(jq -r '.predicate.runDetails.builder.id' "${artifact}.intoto.jsonl")"
    assert_equal "$builder_id" "https://example.com/builder/v2"
}

@test "slsa_generate includes invocation ID" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary" > "$artifact"

    run slsa_generate "$artifact" --invocation-id "test-run-12345"
    [[ "$status" -eq 0 ]]

    local invocation_id
    invocation_id="$(jq -r '.predicate.runDetails.metadata.invocationId' "${artifact}.intoto.jsonl")"
    assert_equal "$invocation_id" "test-run-12345"
}

@test "slsa_generate includes timestamps" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary" > "$artifact"

    run slsa_generate "$artifact"
    [[ "$status" -eq 0 ]]

    # Check startedOn and finishedOn exist and are valid ISO8601
    local started finished
    started="$(jq -r '.predicate.runDetails.metadata.startedOn' "${artifact}.intoto.jsonl")"
    finished="$(jq -r '.predicate.runDetails.metadata.finishedOn' "${artifact}.intoto.jsonl")"

    # Should be non-null
    [[ "$started" != "null" ]]
    [[ "$finished" != "null" ]]

    # Should match ISO8601 pattern (basic check)
    [[ "$started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
    [[ "$finished" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "slsa_generate includes build definition" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary" > "$artifact"

    run slsa_generate "$artifact" --build-type "ci-release"
    [[ "$status" -eq 0 ]]

    local build_type
    build_type="$(jq -r '.predicate.buildDefinition.buildType' "${artifact}.intoto.jsonl")"

    # Should contain the build type
    assert_contains "$build_type" "ci-release"
}

@test "slsa_generate with custom output path" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    local custom_output="$TEST_ARTIFACTS/custom-provenance.jsonl"
    echo "binary" > "$artifact"

    run slsa_generate "$artifact" --output "$custom_output"
    [[ "$status" -eq 0 ]]

    assert_file_exists "$custom_output"
    [[ ! -f "${artifact}.intoto.jsonl" ]]
}

@test "slsa_generate fails for missing artifact" {
    run slsa_generate "/nonexistent/artifact"
    [[ "$status" -ne 0 ]]
}

@test "slsa_generate fails without artifact argument" {
    run slsa_generate
    [[ "$status" -ne 0 ]]
}

# ============================================================================
# SLSA Batch Generation Tests
# ============================================================================

@test "slsa_generate_batch processes multiple artifacts" {
    mkdir -p "$TEST_ARTIFACTS/batch"
    echo "binary1" > "$TEST_ARTIFACTS/batch/tool1"
    echo "binary2" > "$TEST_ARTIFACTS/batch/tool2"
    echo "binary3" > "$TEST_ARTIFACTS/batch/tool3"

    run slsa_generate_batch "$TEST_ARTIFACTS/batch"
    [[ "$status" -eq 0 ]]

    assert_file_exists "$TEST_ARTIFACTS/batch/tool1.intoto.jsonl"
    assert_file_exists "$TEST_ARTIFACTS/batch/tool2.intoto.jsonl"
    assert_file_exists "$TEST_ARTIFACTS/batch/tool3.intoto.jsonl"
}

@test "slsa_generate_batch skips non-artifact files" {
    mkdir -p "$TEST_ARTIFACTS/batch"
    echo "binary" > "$TEST_ARTIFACTS/batch/tool"
    echo "checksum" > "$TEST_ARTIFACTS/batch/checksums.txt"
    echo "signature" > "$TEST_ARTIFACTS/batch/tool.sig"

    run slsa_generate_batch "$TEST_ARTIFACTS/batch"
    [[ "$status" -eq 0 ]]

    assert_file_exists "$TEST_ARTIFACTS/batch/tool.intoto.jsonl"
    [[ ! -f "$TEST_ARTIFACTS/batch/checksums.txt.intoto.jsonl" ]]
    [[ ! -f "$TEST_ARTIFACTS/batch/tool.sig.intoto.jsonl" ]]
}

@test "slsa_generate_batch skips existing provenance" {
    mkdir -p "$TEST_ARTIFACTS/batch"
    echo "binary" > "$TEST_ARTIFACTS/batch/tool"
    echo '{"existing": true}' > "$TEST_ARTIFACTS/batch/tool.intoto.jsonl"

    run slsa_generate_batch "$TEST_ARTIFACTS/batch"
    [[ "$status" -eq 0 ]]

    # Should not overwrite existing
    local content
    content="$(cat "$TEST_ARTIFACTS/batch/tool.intoto.jsonl")"
    assert_contains "$content" "existing"
}

# ============================================================================
# SLSA Verification Tests
# ============================================================================

@test "slsa_verify validates correct attestation" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary content" > "$artifact"

    # Generate provenance
    slsa_generate "$artifact"

    # Verify
    run slsa_verify "$artifact"
    [[ "$status" -eq 0 ]]
}

@test "slsa_verify fails on tampered artifact" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "original content" > "$artifact"

    # Generate provenance
    slsa_generate "$artifact"

    # Tamper with artifact
    echo "modified content" > "$artifact"

    # Verify should fail
    run slsa_verify "$artifact"
    [[ "$status" -ne 0 ]]
}

@test "slsa_verify fails with missing provenance" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary" > "$artifact"

    # No provenance generated
    run slsa_verify "$artifact"
    [[ "$status" -ne 0 ]]
}

@test "slsa_verify fails with invalid JSON" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary" > "$artifact"

    # Create invalid provenance
    echo "not valid json" > "${artifact}.intoto.jsonl"

    run slsa_verify "$artifact"
    [[ "$status" -ne 0 ]]
}

@test "slsa_verify fails with wrong statement type" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary" > "$artifact"

    # Create provenance with wrong type
    echo '{"_type": "https://wrong.type/v1", "subject": []}' > "${artifact}.intoto.jsonl"

    run slsa_verify "$artifact"
    [[ "$status" -ne 0 ]]
}

@test "slsa_verify fails with wrong predicate type" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    local sha256
    sha256=$(sha256sum "$artifact" 2>/dev/null | cut -d' ' -f1 || echo "abc123")
    echo "binary" > "$artifact"

    # Create provenance with wrong predicate type
    cat > "${artifact}.intoto.jsonl" << EOF
{
  "_type": "https://in-toto.io/Statement/v1",
  "predicateType": "https://wrong.predicate/v1",
  "subject": [{"name": "test-binary", "digest": {"sha256": "$sha256"}}]
}
EOF

    run slsa_verify "$artifact"
    [[ "$status" -ne 0 ]]
}

@test "slsa_verify with explicit provenance path" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    local provenance="$TEST_ARTIFACTS/custom.jsonl"
    echo "binary" > "$artifact"

    # Generate to custom path
    slsa_generate "$artifact" --output "$provenance"

    # Verify with explicit path
    run slsa_verify "$artifact" "$provenance"
    [[ "$status" -eq 0 ]]
}

# ============================================================================
# SLSA JSON Output Tests
# ============================================================================

@test "slsa_generate_json returns valid JSON" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary" > "$artifact"

    run slsa_generate_json "$artifact"
    [[ "$status" -eq 0 ]]

    # Should be valid JSON
    echo "$output" | jq empty
}

@test "slsa_generate_json includes status" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary" > "$artifact"

    run slsa_generate_json "$artifact"
    [[ "$status" -eq 0 ]]

    local json_status
    json_status=$(echo "$output" | jq -r '.status')
    assert_equal "$json_status" "success"
}

@test "slsa_generate_json reports error status on failure" {
    run slsa_generate_json "/nonexistent/file"

    local json_status
    json_status=$(echo "$output" | jq -r '.status')
    assert_equal "$json_status" "error"
}

@test "slsa_generate_json includes duration" {
    local artifact="$TEST_ARTIFACTS/test-binary"
    echo "binary" > "$artifact"

    run slsa_generate_json "$artifact"
    [[ "$status" -eq 0 ]]

    local duration
    duration=$(echo "$output" | jq -r '.duration_seconds')
    [[ "$duration" != "null" ]]
}
