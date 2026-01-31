#!/usr/bin/env bats
# test_checksum_sync.bats - Unit tests for checksum auto-sync
#
# bd-1jt.3.5: Tests for checksum auto-sync across flywheel repos
#
# Coverage:
# - Checksum generation and verification
# - Protected path enforcement
# - Repository operations (clone, update)
# - External tool handling (issue creation)
# - JSON output structure
#
# Run: bats tests/unit/test_checksum_sync.bats

# Load test harness
load ../helpers/test_harness.bash

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    harness_setup

    # Source the checksum sync module
    harness_source_module "checksum_sync"

    # Create test artifacts directory
    TEST_ARTIFACTS="$TEST_TMPDIR/artifacts"
    mkdir -p "$TEST_ARTIFACTS"

    # Create sample binaries
    echo "binary1-content" > "$TEST_ARTIFACTS/tool-linux-amd64"
    echo "binary2-content" > "$TEST_ARTIFACTS/tool-darwin-arm64"
    echo "binary3-content" > "$TEST_ARTIFACTS/tool-windows-amd64.exe"
}

teardown() {
    harness_teardown
}

# ============================================================================
# Checksum Generation Tests
# ============================================================================

@test "checksum_generate creates SHA256 checksums" {
    run checksum_generate "$TEST_ARTIFACTS"
    [[ "$status" -eq 0 ]]

    # Should contain SHA256 hashes (64 hex chars)
    [[ "$output" =~ [a-f0-9]{64} ]]

    # Should contain filenames
    assert_contains "$output" "tool-linux-amd64"
}

@test "checksum_generate includes all artifact files" {
    run checksum_generate "$TEST_ARTIFACTS"
    [[ "$status" -eq 0 ]]

    # Count lines (3 artifacts)
    local line_count
    line_count=$(echo "$output" | grep -c '[a-f0-9]\{64\}')
    [[ "$line_count" -eq 3 ]]
}

@test "checksum_generate skips checksum files" {
    echo "existing checksums" > "$TEST_ARTIFACTS/SHA256SUMS.txt"
    echo "existing checksums" > "$TEST_ARTIFACTS/checksums.sha256"

    run checksum_generate "$TEST_ARTIFACTS"
    [[ "$status" -eq 0 ]]

    # Should not include .txt or .sha256 files
    [[ ! "$output" =~ SHA256SUMS ]]
    [[ ! "$output" =~ checksums\.sha256 ]]
}

@test "checksum_generate skips signature files" {
    echo "signature" > "$TEST_ARTIFACTS/tool-linux-amd64.minisig"
    echo "signature" > "$TEST_ARTIFACTS/tool-linux-amd64.sig"

    run checksum_generate "$TEST_ARTIFACTS"
    [[ "$status" -eq 0 ]]

    # Should not include signature files
    [[ ! "$output" =~ \.minisig ]]
    [[ ! "$output" =~ \.sig ]]
}

@test "checksum_generate skips provenance files" {
    echo '{"provenance": true}' > "$TEST_ARTIFACTS/tool-linux-amd64.intoto.jsonl"
    echo '{"sbom": true}' > "$TEST_ARTIFACTS/tool-linux-amd64.sbom.json"

    run checksum_generate "$TEST_ARTIFACTS"
    [[ "$status" -eq 0 ]]

    # Should not include provenance or SBOM files
    [[ ! "$output" =~ intoto ]]
    [[ ! "$output" =~ sbom ]]
}

@test "checksum_generate writes to output file" {
    local output_file="$TEST_TMPDIR/checksums.txt"

    run checksum_generate "$TEST_ARTIFACTS" --output "$output_file"
    [[ "$status" -eq 0 ]]

    assert_file_exists "$output_file"
    local content
    content=$(cat "$output_file")
    [[ "$content" =~ [a-f0-9]{64} ]]
}

@test "checksum_generate fails for nonexistent directory" {
    run checksum_generate "/nonexistent/path"
    [[ "$status" -ne 0 ]]
}

@test "checksum_generate fails without arguments" {
    run checksum_generate
    [[ "$status" -ne 0 ]]
}

# ============================================================================
# Checksum Verification Tests
# ============================================================================

@test "checksum_verify validates correct checksums" {
    # Generate checksums
    checksum_generate "$TEST_ARTIFACTS" --output "$TEST_TMPDIR/checksums.txt"

    run checksum_verify "$TEST_TMPDIR/checksums.txt" "$TEST_ARTIFACTS"
    [[ "$status" -eq 0 ]]
}

@test "checksum_verify fails on tampered file" {
    # Generate checksums
    checksum_generate "$TEST_ARTIFACTS" --output "$TEST_TMPDIR/checksums.txt"

    # Tamper with a file
    echo "modified" > "$TEST_ARTIFACTS/tool-linux-amd64"

    run checksum_verify "$TEST_TMPDIR/checksums.txt" "$TEST_ARTIFACTS"
    [[ "$status" -ne 0 ]]
}

@test "checksum_verify fails for missing checksums file" {
    run checksum_verify "/nonexistent/checksums.txt" "$TEST_ARTIFACTS"
    [[ "$status" -ne 0 ]]
}

@test "checksum_verify fails for missing directory" {
    echo "abc123 file.txt" > "$TEST_TMPDIR/checksums.txt"

    run checksum_verify "$TEST_TMPDIR/checksums.txt" "/nonexistent"
    [[ "$status" -ne 0 ]]
}

@test "checksum_verify handles missing files gracefully" {
    # Generate checksums then delete a file
    checksum_generate "$TEST_ARTIFACTS" --output "$TEST_TMPDIR/checksums.txt"
    rm "$TEST_ARTIFACTS/tool-linux-amd64"

    run checksum_verify "$TEST_TMPDIR/checksums.txt" "$TEST_ARTIFACTS"
    [[ "$status" -ne 0 ]]
}

# ============================================================================
# Protected Path Tests
# ============================================================================

@test "_cs_is_safe_path rejects /data/projects" {
    run _cs_is_safe_path "/data/projects/test"
    [[ "$status" -ne 0 ]]
}

@test "_cs_is_safe_path rejects \$HOME/projects" {
    run _cs_is_safe_path "$HOME/projects/test"
    [[ "$status" -ne 0 ]]
}

@test "_cs_is_safe_path accepts /tmp paths" {
    run _cs_is_safe_path "/tmp/safe-path"
    [[ "$status" -eq 0 ]]
}

@test "_cs_is_safe_path accepts temp directories" {
    local temp_dir
    temp_dir=$(mktemp -d)

    run _cs_is_safe_path "$temp_dir"
    [[ "$status" -eq 0 ]]

    rm -rf "$temp_dir"
}

# ============================================================================
# Sync Command Tests
# ============================================================================

@test "checksum_sync --help shows usage" {
    run checksum_sync --help
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "USAGE:"
    assert_contains "$output" "checksum_sync"
}

@test "checksum_sync fails without tool name" {
    run checksum_sync
    [[ "$status" -ne 0 ]]
}

@test "checksum_sync fails without version" {
    run checksum_sync "test-tool"
    [[ "$status" -ne 0 ]]
}

@test "checksum_sync --dry-run shows preview" {
    run checksum_sync "test-tool" "v1.0.0" --artifacts-dir "$TEST_ARTIFACTS" --dry-run
    # May fail without real repo, but should show dry-run output
    assert_contains "$output" "dry-run"
}

@test "checksum_sync uses artifacts directory when specified" {
    run checksum_sync "test-tool" "v1.0.0" --artifacts-dir "$TEST_ARTIFACTS" --dry-run
    # Should use the specified directory
    assert_contains "$output" "Generating checksums"
}

# ============================================================================
# JSON Output Tests
# ============================================================================

@test "checksum_sync_json returns valid JSON" {
    run checksum_sync_json "test-tool" "v1.0.0" --dry-run --artifacts-dir "$TEST_ARTIFACTS"

    # Should be valid JSON
    echo "$output" | jq empty
}

@test "checksum_sync_json includes status field" {
    run checksum_sync_json "test-tool" "v1.0.0" --dry-run --artifacts-dir "$TEST_ARTIFACTS"

    local json_status
    json_status=$(echo "$output" | jq -r '.status')
    [[ -n "$json_status" ]]
}

@test "checksum_sync_json includes duration" {
    run checksum_sync_json "test-tool" "v1.0.0" --dry-run --artifacts-dir "$TEST_ARTIFACTS"

    local duration
    duration=$(echo "$output" | jq -r '.duration_seconds')
    [[ "$duration" != "null" ]]
}

# ============================================================================
# Integration Tests
# ============================================================================

@test "checksum_sync workflow with local artifacts" {
    # Generate checksums
    local checksums
    checksums=$(checksum_generate "$TEST_ARTIFACTS")

    # Verify we got valid checksums
    [[ -n "$checksums" ]]

    # Count should match number of binaries
    local count
    count=$(echo "$checksums" | grep -c '[a-f0-9]\{64\}')
    [[ "$count" -eq 3 ]]
}

@test "checksum_sync handles empty artifacts directory" {
    local empty_dir="$TEST_TMPDIR/empty"
    mkdir -p "$empty_dir"

    run checksum_generate "$empty_dir"
    [[ "$status" -eq 0 ]]

    # Should return empty/no output
    [[ -z "$output" ]] || [[ "$output" == "" ]]
}

@test "checksum_generate maintains consistent output format" {
    run checksum_generate "$TEST_ARTIFACTS"
    [[ "$status" -eq 0 ]]

    # Each line should be: hash  filename (sha256sum format)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Should match: 64 hex chars, two spaces, filename
        [[ "$line" =~ ^[a-f0-9]{64}\ \ [^\ ]+$ ]]
    done <<< "$output"
}
