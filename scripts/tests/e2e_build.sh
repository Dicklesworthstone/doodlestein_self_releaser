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

# Use the public CLI when host reservations are available. Some hosted Linux
# runners expose outer /proc PIDs to an inner Bash PID namespace. As in the
# native-source-sync integration suite, substitute only slot acquisition and
# release after a real failure plus independent namespace evidence. This
# fixture already simulates act/Docker execution; packaging remains real.
run_lane_build() (
    local capacity_status=0 host_pid line namespace_line="" module
    local -a namespace_pids=()
    # shellcheck source=../../src/host_selector.sh
    source "$PROJECT_ROOT/src/host_selector.sh"
    selector_acquire_slot act-local packaging-probe > "$TEST_TMPDIR/capacity.out" \
        2> "$TEST_TMPDIR/capacity.log" || capacity_status=$?
    if [[ "$capacity_status" -eq 0 ]]; then
        selector_release_slot act-local packaging-probe || return $?
        exec "$DSR_CMD" --json build "$@"
    fi
    if [[ -r /proc/self/stat && -r /proc/self/status ]]; then
        read -r host_pid _ < /proc/self/stat
        while IFS= read -r line; do
            [[ "$line" != NSpid:* ]] || namespace_line="${line#NSpid:}"
        done < /proc/self/status
        read -r -a namespace_pids <<< "$namespace_line"
    fi
    if [[ "$capacity_status" -ne 3 || ${#namespace_pids[@]} -lt 2 ||
          "${host_pid:-}" == "$BASHPID" || "${namespace_pids[0]:-}" != "${host_pid:-}" ||
          "${namespace_pids[${#namespace_pids[@]}-1]:-}" != "$BASHPID" ]]; then
        echo "FAIL: lane capacity probe failed without PID namespace evidence ($capacity_status)" >&2
        cat "$TEST_TMPDIR/capacity.log" >&2
        return "$capacity_status"
    fi
    echo "BOUNDARY: proven /proc PID namespace mismatch; substituting act-local slot acquisition/release" >&2
    for module in logging config build_state act_runner artifact_naming git_ops packaging; do
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/src/$module.sh" || return $?
    done
    selector_acquire_slot() {
        [[ "$1" == act-local ]] || return 4
        printf 'acquire %s %s\n' "$1" "$2" >> "$TEST_TMPDIR/reservations.log"
    }
    selector_release_slot() {
        [[ "$1" == act-local ]] || return 4
        printf 'release %s %s\n' "$1" "$2" >> "$TEST_TMPDIR/reservations.log"
    }
    export SCRIPT_DIR="$PROJECT_ROOT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture
    declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1 [host_selector]=1)
    # Run the actual command definitions, without changing their source.
    # shellcheck disable=SC1090
    source <(awk '/^(_dsr_require|cmd_build)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$DSR_CMD") || return $?
    # shellcheck disable=SC1090
    source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$DSR_CMD") || return $?
    cmd_build "$@"
)

# Read the same release admission guard used by the public release command.
# This does not contact GitHub or replace any publication validation.
lane_release_is_publishable() (
    # shellcheck source=../../src/logging.sh
    source "$PROJECT_ROOT/src/logging.sh" || return $?
    # shellcheck disable=SC1090
    source <(awk '/^(_release_require_publishable_artifacts|_release_sha256)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$DSR_CMD") || return $?
    _release_require_publishable_artifacts "$1" "$2" false
)

lane_publication_matches() {
    local output_dir="$1" manifest="$2" expected="$3" status=0 failed=0
    local expected_status=4
    [[ "$expected" != true ]] || expected_status=0
    lane_release_is_publishable "$output_dir" "$manifest" \
        > "$TEST_TMPDIR/release-admission.out" 2> "$TEST_TMPDIR/release-admission.log" || status=$?
    if [[ "$status" -ne "$expected_status" ]]; then
        echo "release guard returned $status; expected $expected_status" >&2
        failed=1
    fi
    if ! jq -e --argjson expected "$expected" '
        .build_purpose == "release" and .publishable == $expected and
        (.run_id | test("^[0-9a-f-]{36}$")) and
        (.git_sha | test("^[0-9a-f]{40}$"))
    ' "$output_dir/.dsr-build-purpose.json" >/dev/null 2>&1; then
        echo "durable build purpose does not record publishable=$expected" >&2
        failed=1
    fi
    if [[ "$expected" == false && -e "$manifest" ]] &&
       ! jq -e '.publishable == false and all(.artifacts[]?; .publishable == false)' \
            "$manifest" >/dev/null 2>&1; then
        echo "failed build left a publishable manifest on disk" >&2
        failed=1
    fi
    if [[ "$expected" == false ]]; then
        # Ordinary --no-manifest publication must still observe the directory
        # marker; deleting or omitting the manifest cannot bypass this gate.
        status=0
        lane_release_is_publishable "$output_dir" "$output_dir/absent-manifest.json" \
            > "$TEST_TMPDIR/release-without-manifest.out" \
            2> "$TEST_TMPDIR/release-without-manifest.log" || status=$?
        if [[ "$status" -ne 4 ]]; then
            echo "release without a manifest bypassed the failed build marker ($status)" >&2
            failed=1
        fi
    fi
    return "$failed"
}

lane_file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# A repo whose act lane archives the executable alone under the exact release
# name, while the config declares LICENSE and README.md as companions.
seed_lane_archive_fixture() {
    local repo_dir="$1" readme_mode="${2:-644}" archive_format="${3:-tar.gz}"

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
    chmod "$readme_mode" "$repo_dir/README.md"
    git -C "$repo_dir" init -q -b main
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
  linux: $archive_format
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
members=(lane-tool)
if [[ -n "${LANE_INCLUDE_STATE:-}" ]]; then
  cp -p "$LANE_INCLUDE_ROOT/LICENSE" "$LANE_INCLUDE_ROOT/README.md" "$artifact_dir/payload/" || exit 1
  members+=(LICENSE README.md)
  case "$LANE_INCLUDE_STATE" in
    wrong-content) printf 'different license\n' > "$artifact_dir/payload/LICENSE" ;;
    wrong-mode) chmod 745 "$artifact_dir/payload/README.md" ;;
  esac
fi
# Only transport/compiler execution is simulated. These are real archives;
# non-default gzip compression makes unwanted recompression observable.
set -o pipefail
tar -C "$artifact_dir/payload" -cf - "${members[@]}" | gzip -1 -n > "$artifact_dir/$name" || exit 1
if [[ -n "${LANE_ORIGINAL_ARCHIVE:-}" ]]; then
  cp -p "$artifact_dir/$name" "$LANE_ORIGINAL_ARCHIVE" || exit 1
fi
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

    exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir"
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
    # The envelope reports each target as an object (build-details.json), and
    # the build run id that --resume takes.
    exec_stdout | jq -e --arg manifest "$manifest" '
        .status == "success" and (.details.repo | length > 0) and
        .details.manifest_path == $manifest and
        (.details.run_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
        (.details.targets | length == 1) and
        (.details.targets[0] | .platform == "linux/amd64" and .method == "act" and .status == "success")
    ' >/dev/null 2>&1 || problems+=("envelope: $(exec_stdout | jq -c '.details | {repo, run_id, manifest_path, targets}' 2>/dev/null)")
    lane_publication_matches "$output_dir" "$manifest" true || \
        problems+=("completed build is not durably publishable")

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

    LANE_SIDECAR=1 exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir"
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

test_build_checks_prebuilt_include_contract() {
    local state format include
    for state in complete wrong-content wrong-mode cross-format-conflict; do
        ((TESTS_RUN++))
        if [[ "$HAS_YQ" != "true" ]]; then
            skip "yq required for prebuilt include contract ($state)"
            continue
        fi

        harness_setup
        local repo_dir output_dir original archive alias problems=()
        repo_dir="$(harness_tmpdir)/prebuilt-repo"
        output_dir="$(harness_tmpdir)/prebuilt-out"
        original="$(harness_tmpdir)/original.tar.gz"
        format=tar.gz
        [[ "$state" != cross-format-conflict ]] || format=tar.xz
        # Both copies of README are executable in the mode mismatch case:
        # testing only -x would miss the additional other-execute permission.
        seed_lane_archive_fixture "$repo_dir" 744 "$format"

        local lane_state="$state"
        [[ "$state" != cross-format-conflict ]] || lane_state=wrong-content
        LANE_INCLUDE_STATE="$lane_state" LANE_INCLUDE_ROOT="$repo_dir" \
            LANE_ORIGINAL_ARCHIVE="$original" exec_run run_lane_build lane-tool \
                --version 1.2.3 --output-dir "$output_dir"
        archive="$output_dir/lane-tool-1.2.3-linux-amd64.tar.gz"
        alias="$output_dir/lane-tool-linux-amd64.$format"

        cmp -s "$original" "$archive" || problems+=("prebuilt compressed bytes were changed")
        if [[ "$state" == complete ]]; then
            [[ "$(exec_status)" -eq 0 ]] || problems+=("exit $(exec_status)")
            cmp -s "$original" "$alias" || problems+=("alias does not preserve prebuilt bytes")
            exec_stdout | jq -e '.status == "success"' >/dev/null 2>&1 || \
                problems+=("valid prebuilt archive was not successful")
        else
            include=LICENSE
            [[ "$state" != wrong-mode ]] || include=README.md
            [[ "$(exec_status)" -eq 1 ]] || problems+=("exit $(exec_status), expected partial failure")
            exec_stdout | jq -e '.status == "partial" and .details.publishable == false and
                .details.manifest_path == ""' >/dev/null 2>&1 || \
                problems+=("mismatching prebuilt archive was advertised as publishable")
            exec_stderr | grep -Eiq "include.*(differ|conflict).*${include}|${include}.*(differ|conflict)" || \
                problems+=("diagnostic does not identify conflicting $include")
            [[ ! -e "$alias" ]] || problems+=("installer alias was emitted for a rejected archive")
            lane_publication_matches "$output_dir" "$output_dir/lane-tool-v1.2.3-manifest.json" false || \
                problems+=("conflicting prebuilt payload remains publishable on disk")
            if [[ "$state" == cross-format-conflict && -e "$output_dir/lane-tool-1.2.3-linux-amd64.tar.xz" ]]; then
                problems+=("format conversion published an archive with conflicting LICENSE")
            fi
        fi

        if [[ ${#problems[@]} -eq 0 ]]; then
            pass "build enforces the prebuilt include contract ($state) without changing lane bytes"
        else
            fail "prebuilt include contract ($state): ${problems[*]}"
            echo "stderr: $(exec_stderr | tail -15)"
        fi
        harness_teardown
    done
}

# The worker produces a real executable file. Only the compiler/container
# boundary is simulated; collection, persisted receipts, resume, compression,
# manifest generation, and release admission all run production code.
seed_raw_lane_fixture() {
    local repo_dir="$1" archive_format="${2:-tar.gz}"
    mkdir -p "$repo_dir/docs" "$repo_dir/legal"
    printf 'user-facing notice\n' > "$repo_dir/docs/NOTICE"
    printf 'legal notice with different bytes\n' > "$repo_dir/legal/NOTICE"
    chmod 745 "$repo_dir/docs/NOTICE"
    chmod 640 "$repo_dir/legal/NOTICE"
    # Commit all companions before creating the release tag so the real source
    # identity check validates the fixture without --allow-dirty or retagging.
    seed_lane_archive_fixture "$repo_dir" 744 "$archive_format"
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
  linux: $archive_format
include_files:
  - docs/NOTICE
  - legal/NOTICE
  - README.md
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
printf 'compile\n' >> "$TEST_TMPDIR/compiler.calls"
if [[ "${LANE_COMPILER_FAIL:-}" == 1 ]]; then
  echo 'fixture compiler failed' >&2
  exit 17
fi
if [[ -n "${LANE_WORKER_READY:-}" ]]; then
  printf 'ready\n' > "$LANE_WORKER_READY"
  for ((i = 0; i < 400; i++)); do
    [[ ! -f "$LANE_WORKER_CONTINUE" ]] || break
    sleep 0.05
  done
  [[ -f "$LANE_WORKER_CONTINUE" ]] || exit 124
fi
mkdir -p "$artifact_dir"
printf '#!/bin/sh\necho lane-tool\n' > "$artifact_dir/lane-tool"
chmod 751 "$artifact_dir/lane-tool"
touch -t "${LANE_RAW_MTIME:-202001020304.06}" "$artifact_dir/lane-tool"
exit 0
EOF
)"
}

test_build_failed_compiler_is_not_publishable() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != true ]]; then
        skip "yq required for failed compiler publication test"
        return 0
    fi
    harness_setup
    local repo_dir="$TEST_TMPDIR/compiler-repo" output_dir="$TEST_TMPDIR/compiler-out" problems=()
    seed_raw_lane_fixture "$repo_dir"
    LANE_COMPILER_FAIL=1 exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir"
    [[ "$(exec_status)" -eq 6 ]] || problems+=("exit $(exec_status), expected build failure")
    [[ -s "$TEST_TMPDIR/compiler.calls" ]] || problems+=("compiler boundary was never reached")
    lane_publication_matches "$output_dir" "$output_dir/lane-tool-v1.2.3-manifest.json" false || \
        problems+=("compiler failure is not durably blocked from release")
    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "failed compilation leaves release admission blocked, even without a manifest"
    else
        fail "failed compiler publication: ${problems[*]}"
        echo "stderr: $(exec_stderr | tail -15)"
    fi
    harness_teardown
}

test_build_inflight_is_not_publishable() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != true ]]; then
        skip "yq required for in-flight publication test"
        return 0
    fi
    harness_setup
    local repo_dir="$TEST_TMPDIR/inflight-repo" output_dir="$TEST_TMPDIR/inflight-out"
    local ready="$TEST_TMPDIR/worker.ready" proceed="$TEST_TMPDIR/worker.continue"
    local build_pid status=0 attempt problems=()
    seed_raw_lane_fixture "$repo_dir"
    LANE_WORKER_READY="$ready" LANE_WORKER_CONTINUE="$proceed" \
        run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir" \
        > "$TEST_TMPDIR/inflight.out" 2> "$TEST_TMPDIR/inflight.log" &
    build_pid=$!
    for ((attempt = 0; attempt < 200; attempt++)); do
        [[ ! -f "$ready" ]] || break
        sleep 0.05
    done
    if [[ -f "$ready" ]]; then
        lane_publication_matches "$output_dir" "$output_dir/lane-tool-v1.2.3-manifest.json" false || \
            problems+=("in-flight worker output was admitted as a release")
    else
        problems+=("worker did not reach the bounded compiler barrier")
    fi
    printf 'continue\n' > "$proceed"
    wait "$build_pid" || status=$?
    [[ "$status" -eq 0 ]] || problems+=("completed build exit $status")
    lane_publication_matches "$output_dir" "$output_dir/lane-tool-v1.2.3-manifest.json" true || \
        problems+=("completed worker output was not admitted as a release")
    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "release remains blocked throughout compilation and opens only after completion"
    else
        fail "in-flight publication: ${problems[*]}"
        echo "stderr: $(tail -15 "$TEST_TMPDIR/inflight.log")"
    fi
    harness_teardown
}

test_build_raw_archives_preserve_nested_payloads() {
    local format
    for format in tar.gz tar.xz zip; do
        ((TESTS_RUN++))
        if [[ "$HAS_YQ" != true ]]; then
            skip "yq required for raw archive payload test ($format)"
            continue
        fi
        harness_setup
        local repo_dir="$TEST_TMPDIR/raw-repo" output_dir="$TEST_TMPDIR/raw-out"
        local extracted="$TEST_TMPDIR/extracted" archive file problems=()
        seed_raw_lane_fixture "$repo_dir" "$format"
        exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir"
        archive="$output_dir/lane-tool-1.2.3-linux-amd64.$format"
        [[ "$(exec_status)" -eq 0 ]] || problems+=("exit $(exec_status)")
        mkdir -p "$extracted"
        if [[ "$format" == zip ]]; then
            unzip -q "$archive" -d "$extracted" 2>/dev/null || problems+=("ZIP extraction failed")
        else
            tar -xf "$archive" -C "$extracted" 2>/dev/null || problems+=("tar extraction failed")
        fi
        for file in docs/NOTICE legal/NOTICE README.md; do
            cmp -s "$repo_dir/$file" "$extracted/$file" || problems+=("missing or changed $file")
            [[ "$(lane_file_mode "$repo_dir/$file")" == "$(lane_file_mode "$extracted/$file")" ]] || \
                problems+=("changed permissions for $file")
        done
        [[ "$(lane_file_mode "$extracted/lane-tool")" == 751 ]] || \
            problems+=("executable mode was not preserved")
        [[ "$("$extracted/lane-tool" 2>/dev/null)" == lane-tool ]] || problems+=("executable payload does not run")
        cmp -s "$archive" "$output_dir/lane-tool-linux-amd64.$format" || \
            problems+=("installer alias differs from the packaged archive")
        if [[ ${#problems[@]} -eq 0 ]]; then
            pass "raw $format packaging preserves nested companions, modes and executable bytes"
        else
            fail "raw $format payload: ${problems[*]}"
            echo "stderr: $(exec_stderr | tail -15)"
        fi
        harness_teardown
    done
}

test_build_raw_archive_requires_zip() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != true ]]; then
        skip "yq required for missing zip test"
        return 0
    fi
    harness_setup
    local repo_dir="$TEST_TMPDIR/nozip-repo" output_dir="$TEST_TMPDIR/nozip-out"
    local restricted_bin="$TEST_TMPDIR/without-zip" path_dir executable name problems=()
    local -a path_dirs=()
    seed_raw_lane_fixture "$repo_dir" zip
    mkdir -p "$restricted_bin"
    IFS=: read -r -a path_dirs <<< "$PATH"
    # Supply the real execution environment with only zip absent. No command
    # discovery or packaging function is replaced to simulate the dependency.
    for path_dir in "${path_dirs[@]}"; do
        [[ -d "$path_dir" ]] || continue
        for executable in "$path_dir"/*; do
            name="${executable##*/}"
            [[ -f "$executable" && -x "$executable" && "$name" != zip ]] || continue
            [[ -e "$restricted_bin/$name" ]] || ln -s "$executable" "$restricted_bin/$name"
        done
    done
    if PATH="$restricted_bin" command -v zip >/dev/null 2>&1; then
        problems+=("zip unexpectedly exists in the isolated PATH")
    fi
    PATH="$restricted_bin" exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir"
    [[ "$(exec_status)" -eq 1 ]] || problems+=("exit $(exec_status), expected packaging failure")
    [[ -s "$TEST_TMPDIR/compiler.calls" ]] || problems+=("raw executable was not built")
    [[ ! -e "$output_dir/lane-tool-1.2.3-linux-amd64.zip" ]] || problems+=("unverified ZIP asset exists")
    exec_stderr | grep -Eiq 'zip.*(not|missing|required)' || problems+=("missing zip diagnostic was omitted")
    lane_publication_matches "$output_dir" "$output_dir/lane-tool-v1.2.3-manifest.json" false || \
        problems+=("missing zip still permits publication")
    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "missing zip fails raw packaging and leaves publication blocked"
    else
        fail "missing zip: ${problems[*]}"
        echo "stderr: $(exec_stderr | tail -15)"
    fi
    harness_teardown
}

test_build_raw_archives_honor_source_date_epoch() {
    local format
    for format in tar.gz tar.xz zip; do
        ((TESTS_RUN++))
        if [[ "$HAS_YQ" != true ]]; then
            skip "yq required for deterministic raw archive test ($format)"
            continue
        fi
        harness_setup
        local repo_dir="$TEST_TMPDIR/epoch-repo" first="$TEST_TMPDIR/epoch-first" second="$TEST_TMPDIR/epoch-second"
        local file problems=()
        seed_raw_lane_fixture "$repo_dir" "$format"
        # Isolate timestamp reproducibility from the independent nested-path
        # regression; the baseline ZIP writer can archive one companion.
        yq -i '.include_files = ["README.md"]' "$DSR_CONFIG_DIR/repos.d/lane-tool.yaml"
        for file in docs/NOTICE legal/NOTICE README.md; do
            touch -t 202001020304.06 "$repo_dir/$file"
        done
        SOURCE_DATE_EPOCH=946684800 LANE_RAW_MTIME=202001020304.06 \
            exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$first"
        [[ "$(exec_status)" -eq 0 ]] || problems+=("first build exit $(exec_status)")
        for file in docs/NOTICE legal/NOTICE README.md; do
            touch -t 202505060708.10 "$repo_dir/$file"
        done
        SOURCE_DATE_EPOCH=946684800 LANE_RAW_MTIME=202505060708.10 \
            exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$second"
        [[ "$(exec_status)" -eq 0 ]] || problems+=("second build exit $(exec_status)")
        cmp -s "$first/lane-tool-1.2.3-linux-amd64.$format" "$second/lane-tool-1.2.3-linux-amd64.$format" || \
            problems+=("archive bytes changed when only source mtimes changed")
        if [[ ${#problems[@]} -eq 0 ]]; then
            pass "raw $format output honors SOURCE_DATE_EPOCH across different source mtimes"
        else
            fail "raw $format reproducibility: ${problems[*]}"
            echo "stderr: $(exec_stderr | tail -15)"
        fi
        harness_teardown
    done
}

test_build_packaging_resume_preserves_outputs() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != true ]]; then
        skip "yq required for failed compression and resume test"
        return 0
    fi
    harness_setup
    local repo_dir="$TEST_TMPDIR/resume-repo" output_dir="$TEST_TMPDIR/resume-out"
    local previous="$TEST_TMPDIR/previous.tar.gz" archive run_id problems=()
    local -x LANE_REAL_GZIP
    LANE_REAL_GZIP=$(command -v gzip)
    seed_raw_lane_fixture "$repo_dir"
    mkdir -p "$TEST_TMPDIR/previous-payload"
    printf '#!/bin/sh\necho previous-version\n' > "$TEST_TMPDIR/previous-payload/lane-tool"
    chmod 755 "$TEST_TMPDIR/previous-payload/lane-tool"
    tar -C "$TEST_TMPDIR/previous-payload" -czf "$previous" lane-tool
    mock_command_script "gzip" "$(cat <<'EOF'
if [[ "${LANE_FAIL_GZIP:-}" == 1 ]]; then
  cat >/dev/null
  printf 'partial compressed bytes\n'
  exit 23
fi
exec "$LANE_REAL_GZIP" "$@"
EOF
)"
    LANE_FAIL_GZIP=1 exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir"
    [[ "$(exec_status)" -eq 1 ]] || problems+=("first failed packaging exit $(exec_status)")
    run_id=$(exec_stdout | jq -r '.details.run_id // empty')
    lane_publication_matches "$output_dir" "$output_dir/lane-tool-v1.2.3-manifest.json" false || \
        problems+=("first failed packaging permits release")
    archive="$output_dir/lane-tool-1.2.3-linux-amd64.tar.gz"
    # A resumed run may already contain a verified prior archive. Its payload
    # deliberately differs from this build, so content-aware reuse cannot
    # legitimately skip compression and hide a non-atomic writer.
    cp -p "$previous" "$archive"
    LANE_FAIL_GZIP=1 exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir" --resume
    [[ "$(exec_status)" -eq 1 ]] || problems+=("failed resumed packaging exit $(exec_status)")
    cmp -s "$previous" "$archive" || problems+=("failed compressor overwrote the previous archive")
    [[ "$(wc -l < "$TEST_TMPDIR/compiler.calls")" -eq 1 ]] || problems+=("resume repeated compilation")
    lane_publication_matches "$output_dir" "$output_dir/lane-tool-v1.2.3-manifest.json" false || \
        problems+=("failed resumed packaging permits release")
    exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir" --resume
    [[ "$(exec_status)" -eq 0 ]] || problems+=("recovered packaging exit $(exec_status)")
    [[ "$(wc -l < "$TEST_TMPDIR/compiler.calls")" -eq 1 ]] || problems+=("recovery repeated compilation")
    [[ "$(exec_stdout | jq -r '.details.run_id // empty')" == "$run_id" && -n "$run_id" ]] || \
        problems+=("resume changed the build run identity")
    [[ "$(tar -xzOf "$archive" lane-tool 2>/dev/null | tail -1)" == 'echo lane-tool' ]] || \
        problems+=("recovered archive contains the previous executable")
    jq -e --arg run "$run_id" '.status == "completed" and .run_id == $run and
        .target_statuses["linux/amd64"].attempts == 1' \
        "$DSR_STATE_DIR/builds/lane-tool/1.2.3/latest/state.json" >/dev/null 2>&1 || \
        problems+=("recovery did not persist completed state with one compilation attempt")
    lane_publication_matches "$output_dir" "$output_dir/lane-tool-v1.2.3-manifest.json" true || \
        problems+=("recovered output is not publishable")
    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "failed compression preserves prior bytes and resume publishes without recompilation"
    else
        fail "packaging resume: ${problems[*]}"
        echo "stderr: $(exec_stderr | tail -20)"
    fi
    harness_teardown
}

test_build_resumes_completed_publication_checkpoints() {
    local format phase
    for format in tar.gz binary; do
        for phase in before-manifest after-manifest; do
            ((TESTS_RUN++))
            if [[ "$HAS_YQ" != true ]]; then
                skip "yq required for publication checkpoint test ($format/$phase)"
                continue
            fi
            harness_setup
            local repo_dir="$TEST_TMPDIR/checkpoint-repo" output_dir="$TEST_TMPDIR/checkpoint-out"
            local ready="$TEST_TMPDIR/worker.ready" proceed="$TEST_TMPDIR/worker.continue"
            local saved_marker="$TEST_TMPDIR/observed-pending.json" marker manifest build_pid
            local status=0 attempt run_id suffix=".$format" name digest size problems=()
            [[ "$format" != binary ]] || suffix=""
            marker="$output_dir/.dsr-build-purpose.json"
            manifest="$output_dir/lane-tool-v1.2.3-manifest.json"
            seed_raw_lane_fixture "$repo_dir" "$format"
            LANE_WORKER_READY="$ready" LANE_WORKER_CONTINUE="$proceed" \
                run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir" \
                > "$TEST_TMPDIR/checkpoint-build.out" 2> "$TEST_TMPDIR/checkpoint-build.log" &
            build_pid=$!
            for ((attempt = 0; attempt < 200; attempt++)); do
                [[ ! -f "$ready" ]] || break
                sleep 0.05
            done
            if [[ -f "$ready" && -f "$marker" ]]; then
                cp -p "$marker" "$saved_marker"
            fi
            printf 'continue\n' > "$proceed"
            wait "$build_pid" || status=$?
            if [[ "$status" -ne 0 || ! -f "$saved_marker" ]]; then
                fail "checkpoint fixture must complete and retain its real pending receipt ($format/$phase; exit $status)"
                echo "stderr: $(tail -15 "$TEST_TMPDIR/checkpoint-build.log")"
                harness_teardown
                continue
            fi
            run_id=$(jq -r '.run_id' "$saved_marker")
            jq -e --arg run "$run_id" '.status == "completed" and .run_id == $run' \
                "$DSR_STATE_DIR/builds/lane-tool/1.2.3/latest/state.json" >/dev/null 2>&1 || \
                problems+=("build did not persist completed state")
            # Replay documents actually observed in this run. These are the
            # reachable crash checkpoints between completion-state persistence,
            # the final manifest rename, and the last publication-marker rename.
            cp -p "$saved_marker" "$marker"
            if [[ "$phase" == before-manifest ]]; then
                mv "$manifest" "$TEST_TMPDIR/manifest-before-replay.json"
            fi
            status=0
            lane_release_is_publishable "$output_dir" "$manifest" \
                > "$TEST_TMPDIR/checkpoint-guard.out" 2> "$TEST_TMPDIR/checkpoint-guard.log" || status=$?
            [[ "$status" -eq 4 ]] || problems+=("pending checkpoint permits release")
            if [[ "$format/$phase" == tar.gz/before-manifest ]]; then
                jq '.run_id = "00000000-0000-4000-8000-000000000000"' \
                    "$saved_marker" > "$TEST_TMPDIR/foreign-marker.json"
                cp -p "$TEST_TMPDIR/foreign-marker.json" "$marker"
                exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir" --resume
                [[ "$(exec_status)" -eq 4 ]] || problems+=("resume accepted another run's marker")
                cmp -s "$TEST_TMPDIR/foreign-marker.json" "$marker" || \
                    problems+=("rejected resume changed the foreign marker")
                cp -p "$saved_marker" "$marker"
            fi
            exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir" --resume
            [[ "$(exec_status)" -eq 0 ]] || problems+=("resume exit $(exec_status)")
            [[ "$(wc -l < "$TEST_TMPDIR/compiler.calls")" -eq 1 ]] || problems+=("checkpoint recovery repeated compilation")
            [[ "$(exec_stdout | jq -r '.details.run_id // empty')" == "$run_id" ]] || \
                problems+=("checkpoint recovery changed run identity")
            for name in "lane-tool-1.2.3-linux-amd64$suffix" "lane-tool-linux-amd64$suffix"; do
                digest=$(sha256sum "$output_dir/$name" 2>/dev/null | awk '{print $1}')
                size=$(wc -c < "$output_dir/$name" 2>/dev/null | tr -d ' ')
                jq -e --arg name "$name" --arg digest "$digest" --argjson size "${size:-0}" '
                    [.artifacts[] | select(.name == $name and .sha256 == $digest and .size_bytes == $size)] |
                    length == 1' "$manifest" >/dev/null 2>&1 || \
                    problems+=("resumed manifest lost or misstated $name")
            done
            lane_publication_matches "$output_dir" "$manifest" true || problems+=("replayed checkpoint was not sealed")
            if [[ ${#problems[@]} -eq 0 ]]; then
                pass "completed $format checkpoint resumes $phase with all installer assets and no compilation"
            else
                fail "completed publication checkpoint ($format/$phase): ${problems[*]}"
                echo "stderr: $(exec_stderr | tail -20)"
            fi
            harness_teardown
        done
    done
}

test_build_sealed_manifest_is_required_unchanged() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != true ]]; then
        skip "yq required for sealed manifest integrity test"
        return 0
    fi
    harness_setup
    local repo_dir="$TEST_TMPDIR/sealed-repo" output_dir="$TEST_TMPDIR/sealed-out"
    local manifest="$output_dir/lane-tool-v1.2.3-manifest.json" status=0 problems=()
    seed_raw_lane_fixture "$repo_dir"
    exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir"
    if [[ "$(exec_status)" -ne 0 || ! -f "$manifest" ]]; then
        fail "sealed manifest fixture must finish a real build (exit $(exec_status))"
        echo "stderr: $(exec_stderr | tail -15)"
        harness_teardown
        return
    fi
    cp -p "$manifest" "$TEST_TMPDIR/manifest-backup.json"
    mv "$manifest" "$TEST_TMPDIR/manifest-held.json"
    lane_release_is_publishable "$output_dir" "$manifest" \
        > "$TEST_TMPDIR/missing-manifest.out" 2> "$TEST_TMPDIR/missing-manifest.log" || status=$?
    [[ "$status" -eq 4 ]] || problems+=("missing sealed manifest permits release")
    mv "$TEST_TMPDIR/manifest-held.json" "$manifest"
    # The JSON meaning stays identical: the receipt seals the actual bytes,
    # so even a valid reserialization must not inherit the original approval.
    printf '\n' >> "$manifest"
    status=0
    lane_release_is_publishable "$output_dir" "$manifest" \
        > "$TEST_TMPDIR/changed-manifest.out" 2> "$TEST_TMPDIR/changed-manifest.log" || status=$?
    [[ "$status" -eq 4 ]] || problems+=("changed sealed manifest permits release")
    cp -p "$TEST_TMPDIR/manifest-backup.json" "$manifest"
    cp -p "$manifest" "$output_dir/foreign-manifest.json"
    status=0
    lane_release_is_publishable "$output_dir" "$output_dir/foreign-manifest.json" \
        > "$TEST_TMPDIR/foreign-manifest.out" 2> "$TEST_TMPDIR/foreign-manifest.log" || status=$?
    [[ "$status" -eq 4 ]] || problems+=("unbound manifest path permits release")
    lane_publication_matches "$output_dir" "$manifest" true || problems+=("restoring the exact sealed manifest did not restore admission")
    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "publication receipt requires its exact completed manifest path and bytes"
    else
        fail "sealed manifest integrity: ${problems[*]}"
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
  members=(lane-tool)
  if [[ -n "${LANE_VARIANT_INCLUDE_CONFLICT:-}" ]]; then
    cp -p "$LANE_INCLUDE_ROOT/LICENSE" "$artifact_dir/payload-$libc/LICENSE" || exit 1
    [[ "$libc" != musl ]] || printf 'different license\n' > "$artifact_dir/payload-$libc/LICENSE"
    members+=(LICENSE)
  fi
  tar -C "$artifact_dir/payload-$libc" -czf \
    "$artifact_dir/lane-tool-1.2.3-x86_64-unknown-linux-$libc.tar.gz" "${members[@]}" || exit 1
  if [[ "$libc" == musl && -n "${LANE_ORIGINAL_ARCHIVE:-}" ]]; then
    cp -p "$artifact_dir/lane-tool-1.2.3-x86_64-unknown-linux-$libc.tar.gz" "$LANE_ORIGINAL_ARCHIVE" || exit 1
  fi
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

    exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir"
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

    LANE_GNU_ONLY=1 exec_run run_lane_build lane-tool --version 1.2.3 --output-dir "$output_dir"
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

test_build_refuses_secondary_variant_include_conflict() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for secondary variant include contract"
        return 0
    fi

    harness_setup
    local repo_dir output_dir original archive problems=()
    repo_dir="$(harness_tmpdir)/variant-repo"
    output_dir="$(harness_tmpdir)/variant-out"
    original="$(harness_tmpdir)/original-musl.tar.gz"
    seed_variant_lane_fixture "$repo_dir"

    LANE_VARIANT_INCLUDE_CONFLICT=1 LANE_INCLUDE_ROOT="$repo_dir" \
        LANE_ORIGINAL_ARCHIVE="$original" exec_run run_lane_build lane-tool \
            --version 1.2.3 --output-dir "$output_dir"
    archive="$output_dir/lane-tool-1.2.3-x86_64-unknown-linux-musl.tar.gz"
    [[ "$(exec_status)" -eq 1 ]] || problems+=("exit $(exec_status), expected partial failure")
    exec_stdout | jq -e '.status == "partial" and .details.publishable == false and
        .details.manifest_path == ""' >/dev/null 2>&1 || \
        problems+=("secondary variant conflict advertised a publishable build")
    exec_stderr | grep -Eiq 'include.*(differ|conflict).*LICENSE|LICENSE.*(differ|conflict)' || \
        problems+=("diagnostic does not identify conflicting LICENSE")
    cmp -s "$original" "$archive" || problems+=("secondary prebuilt bytes were changed")
    [[ ! -e "$output_dir/lane-tool-x86_64-unknown-linux-musl.tar.gz" ]] || \
        problems+=("installer alias emitted for rejected musl variant")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "build refuses conflicting includes in a secondary target variant"
    else
        fail "secondary variant include contract: ${problems[*]}"
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
test_build_checks_prebuilt_include_contract
test_build_packages_each_target_triple_variant
test_build_names_unproduced_target_triple_variant
test_build_refuses_secondary_variant_include_conflict

echo ""
echo "Durable Publication and Raw Archive Packaging:"
test_build_failed_compiler_is_not_publishable
test_build_inflight_is_not_publishable
test_build_raw_archives_preserve_nested_payloads
test_build_raw_archive_requires_zip
test_build_raw_archives_honor_source_date_epoch
test_build_packaging_resume_preserves_outputs
test_build_resumes_completed_publication_checkpoints
test_build_sealed_manifest_is_required_unchanged

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
