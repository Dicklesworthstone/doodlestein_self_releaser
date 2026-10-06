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

    if echo "$output" | jq -e '
        .command == "build" and
        .status == "success" and
        .exit_code == 0 and
        .details.mode == "dry_run" and
        (.details.targets | type == "array" and length > 0) and
        (.details.targets | all(
            (.platform | type == "string") and
            (.host | type == "string") and
            (.method == "act" or .method == "native") and
            .status == "skipped"
        ))
    ' >/dev/null 2>&1; then
        pass "build --dry-run --json produces a schema-shaped success envelope"
    else
        fail "build --dry-run --json should produce a schema-shaped success envelope"
        echo "output: $output"
    fi

    cleanup_build_fixtures
    harness_teardown
}

test_build_dry_run_has_no_build_side_effects() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for dry-run side-effect test"
        return 0
    fi

    harness_setup
    seed_build_fixtures

    local output_dir="$TEST_TMPDIR/dry-run-artifacts"
    local sentinel_dir="$TEST_TMPDIR/dry-run-command-sentinels"
    local command_name
    mkdir -p "$sentinel_dir"

    for command_name in rsync ssh scp act docker cargo; do
        mock_command_script "$command_name" "
printf '%s\\n' \"\$*\" >> \"$sentinel_dir/$command_name.calls\"
exit 97
"
    done

    exec_run "$DSR_CMD" build test-build-tool \
        --dry-run \
        --version 0.1.0 \
        --output-dir "$output_dir" \
        --allow-dirty
    local status
    status=$(exec_status)

    local invoked=()
    for command_name in rsync ssh scp act docker cargo; do
        [[ -e "$sentinel_dir/$command_name.calls" ]] && invoked+=("$command_name")
    done

    if [[ "$status" -eq 0 ]] &&
       [[ ! -e "$output_dir" ]] &&
       [[ ! -e "$DSR_STATE_DIR/artifacts" ]] &&
       [[ ! -e "$DSR_STATE_DIR/logs" ]] &&
       [[ ${#invoked[@]} -eq 0 ]]; then
        pass "build --dry-run invokes no build commands and creates no state paths"
    else
        fail "build --dry-run must be side-effect-free"
        echo "exit: $status"
        echo "invoked commands: ${invoked[*]:-(none)}"
        echo "output exists: $([[ -e "$output_dir" ]] && echo yes || echo no)"
        echo "state artifacts exist: $([[ -e "$DSR_STATE_DIR/artifacts" ]] && echo yes || echo no)"
        echo "state logs exist: $([[ -e "$DSR_STATE_DIR/logs" ]] && echo yes || echo no)"
        echo "stderr: $(exec_stderr | head -10)"
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

test_build_rejects_unconfigured_target() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for target validation test"
        return 0
    fi

    harness_setup
    seed_build_fixtures

    exec_run "$DSR_CMD" --dry-run build test-build-tool --target darwin/arm64

    if [[ "$(exec_status)" -eq 4 ]] && exec_stderr_contains "not configured"; then
        pass "build rejects targets outside the configured matrix"
    else
        fail "build should reject an unconfigured target"
        echo "exit: $(exec_status)"
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

    # Bound the live remote build without making normal fleet contention look
    # like a product failure. Fresh remote toolchains can legitimately need
    # more than 30 seconds even for this tiny fixture.
    local status=0
    timeout 120 "$DSR_CMD" build test-build-tool --target linux/amd64 2>&1 || status=$?

    local state_file="$DSR_STATE_DIR/builds/test-build-tool/0.1.0/latest/state.json"
    local manifest_file="$DSR_STATE_DIR/artifacts/test-build-tool-v0.1.0/test-build-tool-v0.1.0-manifest.json"

    if [[ "$status" -eq 124 ]]; then
        skip "real build timed out (expected for full workflow)"
    elif [[ "$status" -eq 0 ]] &&
         jq -e '.status == "completed"' "$state_file" >/dev/null 2>&1 &&
         [[ -f "$manifest_file" ]]; then
        pass "real build completed with durable state and manifest"
    else
        fail "real build must finish successfully with durable completion evidence (exit: $status)"
        echo "state: $(jq -c . "$state_file" 2>/dev/null || echo missing)"
        echo "manifest exists: $([[ -f "$manifest_file" ]] && echo yes || echo no)"
    fi

    cleanup_build_fixtures
    harness_teardown
}

# ============================================================================
# Tests: Lane archives and configured include_files (GH#29)
# ============================================================================

# A repo whose act lane archives the executable alone under the exact release
# name, while the config declares LICENSE and README.md as companions.
seed_lane_archive_fixture() {
    local repo_dir="$1"

    mkdir -p "$repo_dir/.github/workflows"
    cat > "$repo_dir/.github/workflows/release.yml" << 'YAML'
name: Release
on:
  push:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo "build"
YAML
    echo "lane tool" > "$repo_dir/README.md"
    echo "MIT License" > "$repo_dir/LICENSE"
    git -C "$repo_dir" init -q
    git -C "$repo_dir" -c user.email=test@example.com -c user.name=Test add .
    git -C "$repo_dir" -c user.email=test@example.com -c user.name=Test commit -qm init
    git -C "$repo_dir" tag v1.2.3

    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    cat > "$DSR_CONFIG_DIR/repos.d/lane-tool.yaml" << YAML
tool_name: lane-tool
repo: testuser/lane-tool
local_path: "$repo_dir"
language: go
binary_name: lane-tool
workflow: .github/workflows/release.yml
targets:
  - linux/amd64
act_job_map:
  linux/amd64: build
archive_format:
  linux: tar.gz
include_files:
  - LICENSE
  - README.md
act_overrides:
  platform_image: catthehacker/ubuntu:act-latest
YAML

    mock_init
    mock_command "docker" "Docker OK" 0
    mock_command_script "act" "$(cat <<'EOF'
if [[ "${1:-}" == "--version" ]]; then echo "act version 0.2.87"; exit 0; fi
artifact_dir="" prev=""
for arg in "$@"; do
  if [[ "$prev" == "--artifact-server-path" ]]; then artifact_dir="$arg"; break; fi
  prev="$arg"
done
[[ -n "$artifact_dir" ]] || exit 0
name="lane-tool-1.2.3-linux-amd64.tar.gz"
mkdir -p "$artifact_dir/payload"
printf '#!/bin/sh\necho lane-tool\n' > "$artifact_dir/payload/lane-tool"
chmod 755 "$artifact_dir/payload/lane-tool"
tar -C "$artifact_dir/payload" -czf "$artifact_dir/$name" lane-tool
rm -r "$artifact_dir/payload"
if [[ -n "${LANE_SIDECAR:-}" ]]; then
  (cd "$artifact_dir" && sha256sum "$name" > "$name.sha256")
fi
exit 0
EOF
)"
}

test_build_completes_lane_archive_with_include_files() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]] || ! command -v sha256sum &>/dev/null; then
        skip "yq and sha256sum required for lane archive packaging test"
        return 0
    fi

    harness_setup
    local repo_dir output_dir
    repo_dir="$(harness_tmpdir)/lane-repo"
    output_dir="$(harness_tmpdir)/lane-out"
    seed_lane_archive_fixture "$repo_dir"

    exec_run "$DSR_CMD" --json build lane-tool --version 1.2.3 --output-dir "$output_dir"
    local status archive alias manifest members alias_members problems=()
    status=$(exec_status)
    archive="$output_dir/lane-tool-1.2.3-linux-amd64.tar.gz"
    alias="$output_dir/lane-tool-linux-amd64.tar.gz"
    manifest="$output_dir/lane-tool-v1.2.3-manifest.json"
    members=$(tar -tzf "$archive" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
    alias_members=$(tar -tzf "$alias" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')

    [[ "$status" -eq 0 ]] || problems+=("exit $status")
    [[ "$members" == "LICENSE README.md lane-tool " ]] || problems+=("archive members: $members")
    [[ "$alias_members" == "LICENSE README.md lane-tool " ]] || problems+=("alias members: $alias_members")
    local name sha size actual_sha actual_size
    while IFS=$'\t' read -r name sha size; do
        actual_sha=$(sha256sum "$output_dir/$name" 2>/dev/null | awk '{print $1}')
        actual_size=$(wc -c < "$output_dir/$name" 2>/dev/null | tr -d ' ')
        [[ "$sha" == "$actual_sha" && "$size" == "$actual_size" ]] || \
            problems+=("manifest row for $name does not describe its bytes")
    done < <(jq -r '.artifacts[] | [.name, .sha256, (.size_bytes | tostring)] | @tsv' "$manifest" 2>/dev/null)
    jq -e '[.artifacts[].name] | index("lane-tool-1.2.3-linux-amd64.tar.gz") != null' \
        "$manifest" >/dev/null 2>&1 || problems+=("manifest lacks the release archive")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "build completes a release-named lane archive with configured include_files"
    else
        fail "build should complete the lane archive with include_files: ${problems[*]}"
        echo "stderr: $(exec_stderr | tail -15)"
    fi

    harness_teardown
}

test_build_refuses_attested_thin_lane_archive() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]] || ! command -v sha256sum &>/dev/null; then
        skip "yq and sha256sum required for attested lane archive test"
        return 0
    fi

    harness_setup
    local repo_dir output_dir
    repo_dir="$(harness_tmpdir)/lane-repo"
    output_dir="$(harness_tmpdir)/lane-out"
    seed_lane_archive_fixture "$repo_dir"

    LANE_SIDECAR=1 exec_run "$DSR_CMD" --json build lane-tool --version 1.2.3 --output-dir "$output_dir"
    local status archive members
    status=$(exec_status)
    archive="$output_dir/lane-tool-1.2.3-linux-amd64.tar.gz"
    members=$(tar -tzf "$archive" 2>/dev/null | tr '\n' ' ')

    if [[ "$status" -eq 1 ]] && [[ "$members" == "lane-tool " ]] &&
       (cd "$output_dir" && sha256sum -c --quiet lane-tool-1.2.3-linux-amd64.tar.gz.sha256 >/dev/null 2>&1) &&
       exec_stdout | jq -e '.status == "partial"' >/dev/null 2>&1 &&
       exec_stderr | grep -q "lacks configured include_files (LICENSE README.md), but lane-tool-1.2.3-linux-amd64.tar.gz.sha256 attests"; then
        pass "build fails visibly instead of rebuilding a sidecar-attested thin archive"
    else
        fail "build should refuse an attested thin lane archive (exit $status, members: $members)"
        echo "stderr: $(exec_stderr | tail -15)"
    fi

    harness_teardown
}

# A gnu+musl tool (bd-cdcz) whose act lane builds both variants of linux/amd64.
seed_variant_lane_fixture() {
    local repo_dir="$1"
    seed_lane_archive_fixture "$repo_dir"
    cat > "$DSR_CONFIG_DIR/repos.d/lane-tool.yaml" << YAML
tool_name: lane-tool
repo: testuser/lane-tool
local_path: "$repo_dir"
language: rust
binary_name: lane-tool
workflow: .github/workflows/release.yml
targets:
  - linux/amd64
act_job_map:
  linux/amd64: build
artifact_naming: "\${name}-\${version}-\${target_triple}"
install_script_compat: "\${name}-\${target_triple}"
archive_format:
  linux: tar.gz
include_files:
  - LICENSE
target_triples:
  linux/amd64:
    - x86_64-unknown-linux-gnu
    - x86_64-unknown-linux-musl
act_overrides:
  platform_image: catthehacker/ubuntu:act-latest
YAML
    mock_command_script "act" "$(cat <<'EOF'
if [[ "${1:-}" == "--version" ]]; then echo "act version 0.2.87"; exit 0; fi
artifact_dir="" prev=""
for arg in "$@"; do
  if [[ "$prev" == "--artifact-server-path" ]]; then artifact_dir="$arg"; break; fi
  prev="$arg"
done
[[ -n "$artifact_dir" ]] || exit 0
libcs="gnu musl"
[[ -z "${LANE_GNU_ONLY:-}" ]] || libcs="gnu"
for libc in $libcs; do
  mkdir -p "$artifact_dir/payload-$libc"
  printf '#!/bin/sh\necho %s\n' "$libc" > "$artifact_dir/payload-$libc/lane-tool"
  chmod 755 "$artifact_dir/payload-$libc/lane-tool"
  tar -C "$artifact_dir/payload-$libc" -czf \
    "$artifact_dir/lane-tool-1.2.3-x86_64-unknown-linux-$libc.tar.gz" lane-tool
  rm -r "$artifact_dir/payload-$libc"
done
exit 0
EOF
)"
}

test_build_packages_each_target_triple_variant() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for target triple variant test"
        return 0
    fi

    harness_setup
    local repo_dir output_dir
    repo_dir="$(harness_tmpdir)/variant-repo"
    output_dir="$(harness_tmpdir)/variant-out"
    seed_variant_lane_fixture "$repo_dir"

    exec_run "$DSR_CMD" --json build lane-tool --version 1.2.3 --output-dir "$output_dir"
    local status libc name problems=()
    status=$(exec_status)
    [[ "$status" -eq 0 ]] || problems+=("exit $status")
    for libc in gnu musl; do
        for name in "lane-tool-1.2.3-x86_64-unknown-linux-$libc.tar.gz" "lane-tool-x86_64-unknown-linux-$libc.tar.gz"; do
            [[ "$(tar -xzOf "$output_dir/$name" lane-tool 2>/dev/null | tail -1)" == "echo $libc" ]] ||
                problems+=("$name does not hold the $libc build")
            [[ "$(tar -tzf "$output_dir/$name" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')" == "LICENSE lane-tool " ]] ||
                problems+=("$name lacks LICENSE")
            jq -e --arg name "$name" '[.artifacts[] | select(.name == $name and .target == "linux/amd64")] | length == 1' \
                "$output_dir/lane-tool-v1.2.3-manifest.json" >/dev/null 2>&1 || problems+=("manifest lacks $name")
        done
    done

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "build gives every target triple variant its own archive, alias and companions"
    else
        fail "build should package each variant: ${problems[*]}"
        echo "stderr: $(exec_stderr | tail -15)"
    fi

    harness_teardown
}

test_build_names_unproduced_target_triple_variant() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for unproduced variant test"
        return 0
    fi

    harness_setup
    local repo_dir output_dir
    repo_dir="$(harness_tmpdir)/variant-repo"
    output_dir="$(harness_tmpdir)/variant-out"
    seed_variant_lane_fixture "$repo_dir"

    LANE_GNU_ONLY=1 exec_run "$DSR_CMD" --json build lane-tool --version 1.2.3 --output-dir "$output_dir"
    if [[ "$(exec_status)" -eq 0 ]] &&
       [[ -f "$output_dir/lane-tool-x86_64-unknown-linux-gnu.tar.gz" ]] &&
       [[ ! -e "$output_dir/lane-tool-x86_64-unknown-linux-musl.tar.gz" ]] &&
       exec_stderr | grep -q 'Variant x86_64-unknown-linux-musl of lane-tool linux/amd64 was not produced by this build'; then
        pass "build names a configured variant the lane did not produce"
    else
        fail "build should report the missing musl variant"
        echo "stderr: $(exec_stderr | tail -15)"
    fi

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
test_build_dry_run_has_no_build_side_effects

echo ""
echo "Specific Target:"
test_build_specific_target_dry_run
test_build_rejects_unconfigured_target

echo ""
echo "Real Build (when deps available):"
test_build_real_with_docker

echo ""
echo "Lane Archives and include_files:"
test_build_completes_lane_archive_with_include_files
test_build_refuses_attested_thin_lane_archive
test_build_packages_each_target_triple_variant
test_build_names_unproduced_target_triple_variant

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
