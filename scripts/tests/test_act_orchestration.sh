#!/usr/bin/env bash
# test_act_orchestration.sh - Tests for hybrid build orchestration functions
#
# These tests verify the orchestration layer that coordinates act + SSH builds

set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { echo -e "${GREEN}✓${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}✗${NC} $1"; ((FAIL++)); }
skip() { echo -e "${YELLOW}○${NC} $1"; ((SKIP++)); }

# Setup test environment BEFORE sourcing (critical for config path resolution)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR=$(mktemp -d)

# These MUST be set before sourcing act_runner.sh as it calculates paths at load time
export DSR_STATE_DIR="$TEMP_DIR/state"
export DSR_CACHE_DIR="$TEMP_DIR/cache"
export DSR_CONFIG_DIR="$TEMP_DIR/config"
export DSR_STRICT_BUILD_ROOT="$TEMP_DIR/strict-build-root"

mkdir -p "$DSR_STATE_DIR" "$DSR_CACHE_DIR" "$DSR_CONFIG_DIR/repos.d"

cat > "$DSR_CONFIG_DIR/hosts.yaml" << 'EOF'
schema_version: "1.0.0"
hosts:
  trj:
    platform: linux/amd64
    connection: local
  mmini:
    platform: darwin/arm64
    connection: ssh
    ssh_host: mac-mini-max
  wlap:
    platform: windows/amd64
    connection: ssh
    ssh_host: surfacebookje
platform_mapping:
  linux/amd64: trj
  darwin/amd64: mmini
  darwin/arm64: mmini
  windows/amd64: wlap
  windows/arm64: wlap
EOF

# Source the modules (order matters - config dirs must be set first)
source "$SCRIPT_DIR/src/logging.sh"
source "$SCRIPT_DIR/src/config.sh"
source "$SCRIPT_DIR/src/build_state.sh"
source "$SCRIPT_DIR/src/act_runner.sh"

# Verify ACT_REPOS_DIR is correctly set from DSR_CONFIG_DIR
ACT_REPOS_DIR="$DSR_CONFIG_DIR/repos.d"

# Initialize logging (suppress output)
# Note: LOG_LEVEL is used by logging.sh
export LOG_LEVEL=0
log_init >/dev/null 2>&1

echo "═══════════════════════════════════════════════════════════════"
echo "  Hybrid Build Orchestration Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check if yq is available (required for YAML parsing)
if ! command -v yq &>/dev/null; then
    skip "yq not installed - skipping YAML-dependent tests"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Passed:${NC}  $PASS"
    echo -e "  ${RED}Failed:${NC}  $FAIL"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIP"
    echo ""
    echo "Note: Install yq to run full test suite: sudo snap install yq"
    exit 0
fi

# Create a test config
cat > "$ACT_REPOS_DIR/testool.yaml" << 'EOF'
tool_name: testool
repo: Test/testool
local_path: /tmp/testool
language: go
binary_name: testool
build_cmd: echo "building testool"
targets:
  - linux/amd64
  - darwin/arm64
  - windows/amd64
workflow: .github/workflows/release.yml
act_job_map:
  linux/amd64: build
  darwin/arm64: null
  windows/amd64: null
act_matrix:
  "linux/amd64":
    os: ubuntu-latest
    target: linux/amd64
env:
  CGO_ENABLED: "0"
cross_compile:
  darwin/arm64:
    method: native
    env:
      GOOS: darwin
      GOARCH: arm64
EOF

mkdir -p "$TEMP_DIR/source-repo"
cat > "$ACT_REPOS_DIR/focrtest.yaml" << EOF
tool_name: focrtest
repo: Test/focrtest
local_path: $TEMP_DIR/source-repo
language: rust
binary_name: focr
build_cmd: cargo build --release
targets:
  - linux/amd64
  - linux/arm64
  - darwin/amd64
  - darwin/arm64
  - windows/amd64
  - windows/arm64
workflow: .github/workflows/release.yml
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: focr-x86_64-unknown-linux-gnu
    linux/arm64: focr-aarch64-unknown-linux-gnu
    darwin/amd64: focr-x86_64-apple-darwin
    darwin/arm64: focr-aarch64-apple-darwin-neon-sdot-i8mm
    windows/amd64: focr-x86_64-pc-windows-msvc.exe
    windows/arm64: focr-aarch64-pc-windows-msvc.exe
EOF

echo "== act_get_build_cmd =="

# Test get_build_cmd
build_cmd=$(act_get_build_cmd "testool")
if [[ "$build_cmd" == 'echo "building testool"' ]]; then
    pass "act_get_build_cmd returns correct command"
else
    fail "act_get_build_cmd returned: $build_cmd"
fi

# Test missing tool
if ! act_get_build_cmd "nonexistent" &>/dev/null; then
    pass "act_get_build_cmd returns error for missing tool"
else
    fail "act_get_build_cmd should fail for missing tool"
fi

echo ""
echo "== act_get_build_env =="

# Test global env
env_vars=$(act_get_build_env "testool" "linux/amd64")
if [[ "$env_vars" == *"CGO_ENABLED=0"* ]]; then
    pass "act_get_build_env returns global env vars"
else
    fail "act_get_build_env missing global env: $env_vars"
fi

# Test platform-specific env
env_vars=$(act_get_build_env "testool" "darwin/arm64")
if [[ "$env_vars" == *"GOOS=darwin"* ]] && [[ "$env_vars" == *"GOARCH=arm64"* ]]; then
    pass "act_get_build_env returns platform-specific env vars"
else
    fail "act_get_build_env missing platform env: $env_vars"
fi

echo ""
echo "== act_get_local_path =="

local_path=$(act_get_local_path "testool")
if [[ "$local_path" == "/tmp/testool" ]]; then
    pass "act_get_local_path returns correct path"
else
    fail "act_get_local_path returned: $local_path"
fi

echo ""
echo "== act_get_flags (matrix) =="

matrix_flags=$(act_get_flags "testool" "linux/amd64")
if [[ "$matrix_flags" == *"--matrix os:ubuntu-latest"* ]] && [[ "$matrix_flags" == *"--matrix target:linux/amd64"* ]]; then
    pass "act_get_flags includes matrix filters"
else
    fail "act_get_flags missing matrix filters: $matrix_flags"
fi

echo ""
echo "== act_get_build_strategy =="

# Test act strategy
strategy=$(act_get_build_strategy "testool" "linux/amd64")
method=$(echo "$strategy" | jq -r '.method')
job=$(echo "$strategy" | jq -r '.job')
if [[ "$method" == "act" ]] && [[ "$job" == "build" ]]; then
    pass "act_get_build_strategy returns act method for linux"
else
    fail "act_get_build_strategy returned: $strategy"
fi

# Test native strategy
strategy=$(act_get_build_strategy "testool" "darwin/arm64")
method=$(echo "$strategy" | jq -r '.method')
host=$(echo "$strategy" | jq -r '.host')
if [[ "$method" == "native" ]] && [[ "$host" == "mmini" ]]; then
    pass "act_get_build_strategy returns native method for darwin"
else
    fail "act_get_build_strategy returned: $strategy"
fi

mmini_probe_args=$(
    (
        _act_run_with_timeout() { printf '%s\n' "$*"; }
        _act_has_rsync "mmini"
    ) 2>/dev/null
)
if [[ "$mmini_probe_args" == *"ssh"* && "$mmini_probe_args" == *"mac-mini-max"* && \
      "$mmini_probe_args" != *" mmini "* ]]; then
    pass "mmini health probes use configured SSH destination mac-mini-max"
else
    fail "mmini health probe used the logical key instead of ssh_host: $mmini_probe_args"
fi

wlap_exec_args=$(
    (
        _act_run_with_timeout() { printf '%s\n' "$*"; }
        _act_ssh_exec "wlap" "echo ready" 30
    ) 2>/dev/null
)
if [[ "$wlap_exec_args" == *"ssh"* && "$wlap_exec_args" == *"surfacebookje"* && \
      "$wlap_exec_args" != *" wlap "* ]]; then
    pass "wlap remote commands use configured SSH destination surfacebookje"
else
    fail "wlap remote command used the logical key instead of ssh_host: $wlap_exec_args"
fi

echo ""
echo "== act_build_matrix =="

matrix=$(act_build_matrix "testool")
count=$(echo "$matrix" | jq 'length')
if [[ "$count" -eq 3 ]]; then
    pass "act_build_matrix returns all 3 targets"
else
    fail "act_build_matrix returned $count targets"
fi

echo ""
echo "== act_generate_manifest =="

# Test manifest generation
artifact_path="$TEMP_DIR/artifacts/testool-linux-amd64.tar.gz"
mkdir -p "$(dirname "$artifact_path")"
echo "dummy artifact" > "$artifact_path"

test_result=$(jq -nc --arg path "$artifact_path" '{
  tool: "testool",
  version: "v1.0.0",
  run_id: "550e8400-e29b-41d4-a716-446655440010",
  git_sha: "1111111111111111111111111111111111111111",
  git_ref: "v1.0.0",
  status: "success",
  summary: {total: 1, success: 1, failed: 0},
  targets: [
    {
      platform: "linux/amd64",
      host: "trj",
      method: "act",
      status: "success",
      artifact_path: $path,
      duration_seconds: 10
    }
  ]
}')
manifest=$(act_generate_manifest "$test_result" "")
schema_ver=$(echo "$manifest" | jq -r '.schema_version')
artifacts_count=$(echo "$manifest" | jq '.artifacts | length')

if [[ "$schema_ver" == "1.0.0" ]] && [[ "$artifacts_count" -eq 1 ]]; then
    pass "act_generate_manifest generates valid manifest"
else
    fail "act_generate_manifest returned invalid manifest"
fi

# Regression: a matrix workflow under one act job emits the SAME set of
# cross-platform artifacts under multiple orchestration targets, and each
# matrix run lands them in its own per-target artifact_dir. So the manifest
# sees the same basename in multiple distinct paths, often with different
# content (each matrix run rebuilds, so SHAs drift slightly).
#
# Pre-fix, the path-based seen_paths dedup missed those (paths differ) and
# four orchestration iterations × four files each → 16 manifest entries with
# duplicate names + conflicting targets + conflicting SHAs. That cascaded
# into a SHA256SUMS that failed `sha256sum --check` on every collided name
# and into incorrect "target" labels in the manifest itself.
#
# Post-fix the basename-based dedup collapses the 16 to 4, and filename-
# inference labels each with the right canonical target.
mkdir -p "$TEMP_DIR/dup-artifacts/per-target/linux-amd64"
mkdir -p "$TEMP_DIR/dup-artifacts/per-target/linux-arm64"
mkdir -p "$TEMP_DIR/dup-artifacts/per-target/windows-amd64"
mkdir -p "$TEMP_DIR/dup-artifacts/per-target/darwin-arm64"

# Each per-target dir contains a full matrix output. Content varies per dir
# so SHAs differ — this is what defeats the path-based seen_paths dedup.
for d in linux-amd64 linux-arm64 windows-amd64 darwin-arm64; do
    base="$TEMP_DIR/dup-artifacts/per-target/$d"
    echo "linux-amd64-binary-from-$d"   > "$base/testool-v1.0.0-linux_amd64.tar.gz"
    echo "linux-arm64-binary-from-$d"   > "$base/testool-v1.0.0-linux_arm64.tar.gz"
    echo "darwin-arm64-binary-from-$d"  > "$base/testool-v1.0.0-darwin_arm64.tar.gz"
    echo "windows-amd64-binary-from-$d" > "$base/testool-v1.0.0-windows_amd64.tar.gz"
done

dup_result=$(jq -nc \
  --arg d_la "$TEMP_DIR/dup-artifacts/per-target/linux-amd64" \
  --arg d_lr "$TEMP_DIR/dup-artifacts/per-target/linux-arm64" \
  --arg d_w  "$TEMP_DIR/dup-artifacts/per-target/windows-amd64" \
  --arg d_d  "$TEMP_DIR/dup-artifacts/per-target/darwin-arm64" '{
  tool: "testool",
  version: "v1.0.0",
  run_id: "550e8400-e29b-41d4-a716-446655440011",
  git_sha: "1111111111111111111111111111111111111111",
  git_ref: "v1.0.0",
  status: "success",
  summary: {total: 4, success: 4, failed: 0},
  targets: [
    { platform: "linux/amd64",  host: "trj",   method: "act", status: "success", artifact_dir: $d_la },
    { platform: "linux/arm64",  host: "trj",   method: "act", status: "success", artifact_dir: $d_lr },
    { platform: "windows/amd64",host: "wlap",  method: "ssh", status: "success", artifact_dir: $d_w  },
    { platform: "darwin/arm64", host: "mmini", method: "ssh", status: "success", artifact_dir: $d_d  }
  ]
}')
dup_manifest=$(act_generate_manifest "$dup_result" "")
dup_total=$(echo "$dup_manifest" | jq '.artifacts | length')
dup_unique=$(echo "$dup_manifest" | jq '.artifacts | map(.name) | unique | length')

if [[ "$dup_total" -eq 4 ]] && [[ "$dup_unique" -eq 4 ]]; then
    pass "act_generate_manifest dedupes same-basename across distinct dirs (broken-v0.1.45 scenario)"
else
    fail "act_generate_manifest emitted $dup_total entries with $dup_unique unique names (expected 4/4)"
fi

# Critically: target labels must match the filename, not the orchestration-
# step target. Pre-fix, every artifact got the orchestration-step target
# attached (first iteration's "linux/amd64" for all four files).
linux_amd_target=$(echo "$dup_manifest" | jq -r '.artifacts[] | select(.name == "testool-v1.0.0-linux_amd64.tar.gz")   | .target')
linux_arm_target=$(echo "$dup_manifest" | jq -r '.artifacts[] | select(.name == "testool-v1.0.0-linux_arm64.tar.gz")   | .target')
windows_target=$(echo "$dup_manifest"   | jq -r '.artifacts[] | select(.name == "testool-v1.0.0-windows_amd64.tar.gz") | .target')
darwin_target=$(echo "$dup_manifest"    | jq -r '.artifacts[] | select(.name == "testool-v1.0.0-darwin_arm64.tar.gz")  | .target')

if [[ "$linux_amd_target" == "linux/amd64" ]] && \
   [[ "$linux_arm_target" == "linux/arm64" ]] && \
   [[ "$windows_target"   == "windows/amd64" ]] && \
   [[ "$darwin_target"    == "darwin/arm64" ]]; then
    pass "act_generate_manifest infers target from filename when matrix-shared"
else
    fail "act_generate_manifest mislabeled targets: linux_amd=$linux_amd_target linux_arm=$linux_arm_target windows=$windows_target darwin=$darwin_target"
fi

# Spot-check the musl filename pattern — it must collapse to "linux/<arch>"
# (libc choice is a filename detail, not a separate dsr target).
mkdir -p "$TEMP_DIR/musl"
echo "musl-amd64-binary" > "$TEMP_DIR/musl/testool-v1.0.0-linux_musl_amd64.tar.gz"
musl_result=$(jq -nc --arg dir "$TEMP_DIR/musl" '{
  tool: "testool", version: "v1.0.0", run_id: "550e8400-e29b-41d4-a716-446655440012",
  git_sha: "1111111111111111111111111111111111111111", git_ref: "v1.0.0",
  status: "success", summary: {total: 1, success: 1, failed: 0},
  targets: [{ platform: "linux/amd64", host: "trj", method: "act", status: "success", artifact_dir: $dir }]
}')
musl_target=$(act_generate_manifest "$musl_result" "" | jq -r '.artifacts[0].target')

if [[ "$musl_target" == "linux/amd64" ]]; then
    pass "act_generate_manifest maps linux_musl_amd64 → linux/amd64"
else
    fail "act_generate_manifest mapped musl variant to '$musl_target' (expected linux/amd64)"
fi

echo ""
echo "== strict release contract =="

write_minimal_target_binary() {
    local path="$1"
    local target="$2"
    local machine

    case "$target" in
        linux/amd64|linux/arm64)
            machine='\x3e\x00'
            [[ "$target" == "linux/arm64" ]] && machine='\xb7\x00'
            printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00%b' "$machine" > "$path"
            printf '\x00%.0s' {1..44} >> "$path"
            chmod +x "$path"
            ;;
        darwin/amd64|darwin/arm64)
            machine='\x07\x00\x00\x01'
            [[ "$target" == "darwin/arm64" ]] && machine='\x0c\x00\x00\x01'
            printf '\xcf\xfa\xed\xfe%b\x00\x00\x00\x00\x02\x00\x00\x00' "$machine" > "$path"
            printf '\x00%.0s' {1..16} >> "$path"
            chmod +x "$path"
            ;;
        windows/amd64|windows/arm64)
            machine='\x64\x86'
            [[ "$target" == "windows/arm64" ]] && machine='\x64\xaa'
            printf 'MZ' > "$path"
            printf '\x00%.0s' {1..58} >> "$path"
            printf '\x40\x00\x00\x00PE\x00\x00%b' "$machine" >> "$path"
            printf '\x00%.0s' {1..18} >> "$path"
            printf '\x0b\x02' >> "$path"
            ;;
        *)
            return 4
            ;;
    esac
}

with_collection_receipt() {
    local result_json="$1"
    local source_path="$2"
    local sha size identity
    sha=$(_act_sha256 "$source_path") || return 4
    size=$(_act_file_size "$source_path") || return 4
    identity=$(_act_file_identity "$source_path") || return 4
    jq -c \
        --arg sha "$sha" \
        --argjson size "$size" \
        --arg identity "$identity" '
        .collected_sha256 = $sha |
        .collected_size_bytes = $size |
        .collected_identity = $identity
    ' <<< "$result_json"
}

contract_sha="2222222222222222222222222222222222222222"
contract_ref="v1.0.0"
contract_raw_root="$TEMP_DIR/contract-raw"
mkdir -p "$contract_raw_root/shared-evidence"
printf '{"kind":"build-evidence"}\n' > "$contract_raw_root/shared-evidence/evidence.json"
printf 'unrelated matrix output\n' > "$contract_raw_root/shared-evidence/other-target-primary"
for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64 windows/arm64; do
    target_slug="${target//\//-}"
    raw_name="focr"
    [[ "$target" == windows/* ]] && raw_name="focr.exe"
    mkdir -p "$contract_raw_root/$target_slug"
    write_minimal_target_binary "$contract_raw_root/$target_slug/$raw_name" "$target"
done

missing_source_status=0
missing_source_result=$(
    (
        act_run_workflow() { return 99; }
        act_run_native_build() { return 99; }
        act_orchestrate_build "focrtest" "v1.0.0"
    ) 2>/dev/null
) || missing_source_status=$?
if [[ $missing_source_status -eq 4 ]] && \
   echo "$missing_source_result" | jq -e '.status == "error" and (.error | contains("source identity"))' &>/dev/null; then
    pass "strict orchestration rejects missing source identity before builds"
else
    fail "strict orchestration accepted missing source identity: status=$missing_source_status result=$missing_source_result"
fi

zero_source_status=0
zero_source_result=$(
    (
        act_run_workflow() { return 99; }
        act_run_native_build() { return 99; }
        act_orchestrate_build "focrtest" "v1.0.0" \
            --git-sha "0000000000000000000000000000000000000000" --git-ref "$contract_ref"
    ) 2>/dev/null
) || zero_source_status=$?
if [[ $zero_source_status -eq 4 ]] && echo "$zero_source_result" | jq -e '.status == "error"' &>/dev/null; then
    pass "strict orchestration rejects an all-zero source SHA before builds"
else
    fail "strict orchestration accepted an all-zero source SHA"
fi

for dirty_case in tracked untracked; do
    dirty_line=' M src/lib.rs'
    [[ "$dirty_case" == "untracked" ]] && dirty_line='?? untracked-release-input'
    dirty_source_status=0
    dirty_source_result=$(
        (
            git() {
                case "$*" in
                    *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                        printf '%s\n' "$contract_sha"
                        ;;
                    *"status --porcelain --untracked-files=all"*) printf '%s\n' "$dirty_line" ;;
                    *) return 1 ;;
                esac
            }
            act_run_workflow() { return 99; }
            act_run_native_build() { return 99; }
            act_orchestrate_build "focrtest" "v1.0.0" \
                --git-sha "$contract_sha" --git-ref "$contract_ref"
        ) 2>/dev/null
    ) || dirty_source_status=$?
    if [[ $dirty_source_status -eq 4 ]] && echo "$dirty_source_result" | jq -e '.status == "error"' &>/dev/null; then
        pass "strict orchestration rejects $dirty_case source-tree dirtiness before builds"
    else
        fail "strict orchestration accepted $dirty_case source-tree dirtiness"
    fi
done

noncanonical_root_status=0
noncanonical_root_result=$(
    (
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        act_platform_uses_act() { return 1; }
        act_get_native_host() { printf 'stub-host\n'; }
        act_run_native_build() { return 99; }
        act_orchestrate_build "focrtest" "v1.0.0" \
            --git-sha "$contract_sha" --git-ref "$contract_ref" \
            --run-id "550e8400-e29b-41d4-a716-446655440029" \
            --source-roots-json '{"stub-host":"/tmp/caller-chosen-root"}'
    ) 2>/dev/null
) || noncanonical_root_status=$?
if [[ $noncanonical_root_status -eq 4 ]] && \
   echo "$noncanonical_root_result" | jq -e '.status == "error"' &>/dev/null; then
    pass "strict orchestration rejects caller-chosen noncanonical source roots before builds"
else
    fail "strict orchestration accepted a noncanonical source root"
fi

contract_run_id="550e8400-e29b-41d4-a716-446655440030"
contract_source_root=$(_act_strict_source_root_path \
    "$TEMP_DIR/source-repo" "focrtest" "$contract_run_id")
contract_source_roots=$(jq -nc --arg path "$contract_source_root" '{"stub-host": $path}')
contract_result=$(
    (
        unset -f build_state_create build_state_update_status build_state_update_host
        unset -f build_lock_acquire build_lock_release

        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        act_platform_uses_act() { return 1; }
        act_get_native_host() { printf 'stub-host\n'; }
        _act_validate_strict_cargo_source_closure() { return 0; }
        _act_verify_strict_source_roots() { return 0; }
        act_run_native_build() {
            local target="$2"
            local remote_override="$5"
            local target_slug="${target//\//-}"
            local raw_name="focr"
            [[ "$target" == windows/* ]] && raw_name="focr.exe"
            local raw_path="$contract_raw_root/$target_slug/$raw_name"
            local native_result
            native_result=$(jq -nc \
                --arg platform "$target" \
                --arg path "$raw_path" \
                --arg dir "$contract_raw_root/shared-evidence" \
                --arg remote_override "$remote_override" \
                '{
                    platform: $platform,
                    host: "stub-host",
                    method: "native",
                    status: "success",
                    exit_code: 0,
                    duration_seconds: 1,
                    artifact_path: $path,
                    artifact_paths: [$path],
                    artifact_dir: $dir,
                    observed_remote_path: $remote_override
                }')
            with_collection_receipt "$native_result" "$raw_path"
        }

        act_orchestrate_build "focrtest" "v1.0.0" \
            --git-sha "$contract_sha" --git-ref "$contract_ref" \
            --run-id "$contract_run_id" \
            --source-roots-json "$contract_source_roots"
    ) 2>/dev/null
)

if echo "$contract_result" | jq -e \
    --arg sha "$contract_sha" --arg ref "$contract_ref" --arg source_root "$contract_source_root" '
        .status == "success" and
        .git_sha == $sha and
        .git_ref == $ref and
        (.run_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
        .source_dependencies == [] and
        .summary == {total: 6, success: 6, failed: 0} and
        (.targets | length) == 6 and
        all(.targets[]; .observed_remote_path == $source_root)
    ' &>/dev/null; then
    pass "strict orchestration retains supplied source and reports 6/6 success"
else
    fail "strict orchestration source/summary mismatch: $contract_result"
fi

staged_valid=true
while IFS=$'\t' read -r target staged_path; do
    expected_name=$(config_get_release_contract_json "focrtest" | \
        jq -r --arg target "$target" '.exact_primary_assets[$target]')
    if [[ ! -f "$staged_path" || -L "$staged_path" || "$(basename "$staged_path")" != "$expected_name" ]]; then
        staged_valid=false
    fi
done < <(echo "$contract_result" | jq -r '.targets[] | [.platform, .artifact_path] | @tsv')

if $staged_valid; then
    pass "strict orchestration stages raw native binaries under exact configured basenames"
else
    fail "strict orchestration did not stage every configured primary"
fi

changing_source="$TEMP_DIR/changing-source/focr"
mkdir -p "$(dirname "$changing_source")"
write_minimal_target_binary "$changing_source" "linux/amd64"
changing_result=$(jq -nc --arg path "$changing_source" '{
    platform: "linux/amd64",
    status: "success",
    artifact_path: $path,
    artifact_paths: [$path]
}')
changing_result=$(with_collection_receipt "$changing_result" "$changing_source")
changing_stage_status=0
(
    cat() {
        command cat "$@" || return
        printf 'changed during copy\n' >> "$changing_source"
    }
    _act_stage_contract_primary \
        "focrtest" "v1.0.0" "changing-source-run" "linux/amd64" \
        "$changing_result" "$(config_get_release_contract_json "focrtest")"
) >/dev/null 2>&1 || changing_stage_status=$?
if [[ $changing_stage_status -eq 4 ]]; then
    pass "strict staging rejects a source that changes during copy"
else
    fail "strict staging accepted a source that changed during copy"
fi

replaced_source="$TEMP_DIR/replaced-collected-source/focr"
mkdir -p "$(dirname "$replaced_source")"
write_minimal_target_binary "$replaced_source" "linux/amd64"
replaced_result=$(with_collection_receipt \
    "$(jq -nc --arg path "$replaced_source" '{
        platform: "linux/amd64", status: "success", artifact_path: $path, artifact_paths: [$path]
    }')" "$replaced_source")
mv "$replaced_source" "${replaced_source}.original"
write_minimal_target_binary "$replaced_source" "linux/amd64"
replaced_stage_status=0
_act_stage_contract_primary \
    "focrtest" "v1.0.0" "550e8400-e29b-41d4-a716-446655440024" "linux/amd64" \
    "$replaced_result" "$(config_get_release_contract_json "focrtest")" \
    >/dev/null 2>&1 || replaced_stage_status=$?
if [[ $replaced_stage_status -eq 4 ]]; then
    pass "strict staging rejects a pathname replaced after native collection"
else
    fail "strict staging accepted a post-collection pathname replacement"
fi

symlink_source="$TEMP_DIR/symlink-stage-source/focr"
symlink_stage_dir="$TEMP_DIR/precreated-stage-dir"
symlink_victim="$TEMP_DIR/stage-symlink-victim"
mkdir -p "$(dirname "$symlink_source")" "$symlink_stage_dir"
write_minimal_target_binary "$symlink_source" "linux/amd64"
printf 'must remain unchanged\n' > "$symlink_victim"
ln -s "$symlink_victim" "$symlink_stage_dir/focr-x86_64-unknown-linux-gnu"
symlink_result=$(jq -nc --arg path "$symlink_source" '{
    platform: "linux/amd64", status: "success", artifact_path: $path, artifact_paths: [$path]
}')
symlink_result=$(with_collection_receipt "$symlink_result" "$symlink_source")
symlink_stage_status=0
(
    mktemp() { printf '%s\n' "$symlink_stage_dir"; }
    _act_stage_contract_primary \
        "focrtest" "v1.0.0" "550e8400-e29b-41d4-a716-446655440020" "linux/amd64" \
        "$symlink_result" "$(config_get_release_contract_json "focrtest")"
) >/dev/null 2>&1 || symlink_stage_status=$?
if [[ $symlink_stage_status -eq 4 && "$(cat "$symlink_victim")" == "must remain unchanged" ]]; then
    pass "strict staging refuses a pre-created symlink destination"
else
    fail "strict staging followed or accepted a pre-created symlink destination"
fi

race_source="$TEMP_DIR/race-stage-source/focr"
race_stage_dir="$TEMP_DIR/race-stage-dir"
race_victim="$TEMP_DIR/race-stage-victim"
race_staged_path="$race_stage_dir/focr-x86_64-unknown-linux-gnu"
mkdir -p "$(dirname "$race_source")" "$race_stage_dir"
write_minimal_target_binary "$race_source" "linux/amd64"
printf 'race victim must remain unchanged\n' > "$race_victim"
race_result=$(jq -nc --arg path "$race_source" '{
    platform: "linux/amd64", status: "success", artifact_path: $path, artifact_paths: [$path]
}')
race_result=$(with_collection_receipt "$race_result" "$race_source")
race_stage_status=0
(
    mktemp() { printf '%s\n' "$race_stage_dir"; }
    cat() {
        mv "$race_staged_path" "$race_staged_path.opened" || return
        ln -s "$race_victim" "$race_staged_path" || return
        command cat "$@"
    }
    _act_stage_contract_primary \
        "focrtest" "v1.0.0" "550e8400-e29b-41d4-a716-446655440022" "linux/amd64" \
        "$race_result" "$(config_get_release_contract_json "focrtest")"
) >/dev/null 2>&1 || race_stage_status=$?
if [[ $race_stage_status -eq 4 && \
      "$(cat "$race_victim")" == "race victim must remain unchanged" ]]; then
    pass "strict staging keeps its exclusive file descriptor across a symlink race"
else
    fail "strict staging followed or accepted a destination symlink race"
fi

strict_stage_rejected() {
    local source_path="$1"
    local target="$2"
    local candidate
    candidate=$(jq -nc --arg path "$source_path" --arg target "$target" '{
        platform: $target, status: "success", artifact_path: $path, artifact_paths: [$path]
    }')
    candidate=$(with_collection_receipt "$candidate" "$source_path") || return 0
    ! _act_stage_contract_primary \
        "focrtest" "v1.0.0" "550e8400-e29b-41d4-a716-446655440021" "$target" \
        "$candidate" "$(config_get_release_contract_json "focrtest")" >/dev/null 2>&1
}

invalid_binary="$TEMP_DIR/invalid-binary/focr"
mkdir -p "$(dirname "$invalid_binary")"
printf 'not an executable format\n' > "$invalid_binary"
chmod +x "$invalid_binary"
if strict_stage_rejected "$invalid_binary" "linux/amd64"; then
    pass "strict staging rejects a non-ELF Linux primary"
else
    fail "strict staging accepted a non-ELF Linux primary"
fi

wrong_arch_binary="$TEMP_DIR/wrong-arch/focr"
mkdir -p "$(dirname "$wrong_arch_binary")"
write_minimal_target_binary "$wrong_arch_binary" "linux/arm64"
if strict_stage_rejected "$wrong_arch_binary" "linux/amd64"; then
    pass "strict staging rejects a binary whose architecture mismatches its target"
else
    fail "strict staging accepted a wrong-architecture binary"
fi

nonexec_binary="$TEMP_DIR/nonexec/focr"
mkdir -p "$(dirname "$nonexec_binary")"
write_minimal_target_binary "$nonexec_binary" "linux/amd64"
chmod 644 "$nonexec_binary"
if strict_stage_rejected "$nonexec_binary" "linux/amd64"; then
    pass "strict staging rejects a Unix primary without executable permission"
else
    fail "strict staging accepted a non-executable Unix primary"
fi

wrong_input_name="$TEMP_DIR/wrong-input-name/not-focr"
mkdir -p "$(dirname "$wrong_input_name")"
write_minimal_target_binary "$wrong_input_name" "linux/amd64"
if strict_stage_rejected "$wrong_input_name" "linux/amd64"; then
    pass "strict staging rejects a primary not named focr or focr.exe for its target"
else
    fail "strict staging accepted a wrong input basename"
fi

contract_manifest_input="$contract_result"

for dirty_case in tracked untracked; do
    dirty_line=' M src/lib.rs'
    [[ "$dirty_case" == "untracked" ]] && dirty_line='?? post-build-untracked-input'
    dirty_manifest_status=0
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) printf '%s\n' "$dirty_line" ;;
                *) return 1 ;;
            esac
        }
        act_generate_manifest "$contract_manifest_input" "" >/dev/null
    ) 2>/dev/null || dirty_manifest_status=$?
    if [[ $dirty_manifest_status -eq 4 ]]; then
        pass "strict manifest rejects $dirty_case source drift after orchestration"
    else
        fail "strict manifest accepted $dirty_case source drift after orchestration"
    fi
done
contract_manifest=$(
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        act_generate_manifest "$contract_manifest_input" ""
    ) 2>/dev/null
)

contract_json=$(config_get_release_contract_json "focrtest")
if echo "$contract_manifest" | jq -e \
    --arg sha "$contract_sha" --arg ref "$contract_ref" --argjson contract "$contract_json" '
        .status == "success" and
        .summary == {total: 6, success: 6, failed: 0} and
        .source == {git_sha: $sha, git_ref: $ref, dependencies: []} and
        (.artifacts | length) == 6 and
        all(.artifacts[];
            $contract.exact_primary_assets[.target] == .name and
            .archive_format == "binary" and
            (.sha256 | test("^[a-f0-9]{64}$")) and
            .size_bytes > 0
        )
    ' &>/dev/null; then
    pass "strict manifest finalizes the exact configured 6/6 primary rows"
else
    fail "strict manifest does not match release contract: $contract_manifest"
fi

dependency_sha="3333333333333333333333333333333333333333"
dependency_path="$TEMP_DIR/pinned-dependency"
dependency_json=$(jq -nc --arg sha "$dependency_sha" '[{relative_path: "frankentorch", git_sha: $sha}]')
dependency_checkouts=$(jq -nc --arg path "$dependency_path" --arg sha "$dependency_sha" \
    '[{relative_path: "frankentorch", local_path: $path, git_sha: $sha}]')

missing_dependency_status=0
(
    config_get_release_source_dependencies_json() { printf '%s\n' "$dependency_json"; }
    _config_get_release_source_dependency_checkouts_json() { printf '%s\n' "$dependency_checkouts"; }
    git() {
        case "$*" in
            *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                printf '%s\n' "$contract_sha"
                ;;
            *"status --porcelain --untracked-files=all"*) return 0 ;;
            *) return 1 ;;
        esac
    }
    _act_validate_contract_source_identity "v1.0.0" "$contract_sha" "$contract_ref" "focrtest"
) >/dev/null 2>&1 || missing_dependency_status=$?
if [[ $missing_dependency_status -eq 4 ]]; then
    pass "strict source validation rejects a missing pinned sibling checkout"
else
    fail "strict source validation accepted a missing pinned sibling checkout"
fi

mkdir -p "$dependency_path"
revision_mismatch_status=0
(
    config_get_release_source_dependencies_json() { printf '%s\n' "$dependency_json"; }
    _config_get_release_source_dependency_checkouts_json() { printf '%s\n' "$dependency_checkouts"; }
    git() {
        if [[ "${2:-}" == "$dependency_path" && "$*" == *"HEAD^{commit}"* ]]; then
            printf '%040d\n' 4
        elif [[ "${2:-}" == "$dependency_path" && "$*" == *"${dependency_sha}^{commit}"* ]]; then
            printf '%s\n' "$dependency_sha"
        else
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        fi
    }
    _act_validate_contract_source_identity "v1.0.0" "$contract_sha" "$contract_ref" "focrtest"
) >/dev/null 2>&1 || revision_mismatch_status=$?
if [[ $revision_mismatch_status -eq 4 ]]; then
    pass "strict source validation rejects a sibling at the wrong revision"
else
    fail "strict source validation accepted a sibling at the wrong revision"
fi

pinned_manifest_input=$(echo "$contract_manifest_input" | \
    jq --argjson dependencies "$dependency_json" '.source_dependencies = $dependencies')
pinned_manifest=$(
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        config_get_release_source_dependencies_json() { printf '%s\n' "$dependency_json"; }
        _config_get_release_source_dependency_checkouts_json() { printf '%s\n' "$dependency_checkouts"; }
        git() {
            if [[ "${2:-}" == "$dependency_path" ]]; then
                case "$*" in
                    *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify ${dependency_sha}^{commit}"*)
                        printf '%s\n' "$dependency_sha"
                        ;;
                    *"status --porcelain --untracked-files=all"*) return 0 ;;
                    *) return 1 ;;
                esac
            else
                case "$*" in
                    *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                        printf '%s\n' "$contract_sha"
                        ;;
                    *"status --porcelain --untracked-files=all"*) return 0 ;;
                    *) return 1 ;;
                esac
            fi
        }
        act_generate_manifest "$pinned_manifest_input" ""
    ) 2>/dev/null
)
if echo "$pinned_manifest" | jq -e --argjson dependencies "$dependency_json" \
    '.source.dependencies == $dependencies' &>/dev/null; then
    pass "strict manifest records canonical pinned sibling revisions"
else
    fail "strict manifest omitted or changed pinned sibling revisions: $pinned_manifest"
fi

dirty_dependency_status=0
(
    ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
    config_get_release_source_dependencies_json() { printf '%s\n' "$dependency_json"; }
    _config_get_release_source_dependency_checkouts_json() { printf '%s\n' "$dependency_checkouts"; }
    git() {
        if [[ "${2:-}" == "$dependency_path" ]]; then
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify ${dependency_sha}^{commit}"*)
                    printf '%s\n' "$dependency_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) printf '?? untracked-dependency-input\n' ;;
                *) return 1 ;;
            esac
        else
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        fi
    }
    act_generate_manifest "$pinned_manifest_input" "" >/dev/null
) 2>/dev/null || dirty_dependency_status=$?
if [[ $dirty_dependency_status -eq 4 ]]; then
    pass "strict manifest rejects post-build dirtiness in a pinned sibling checkout"
else
    fail "strict manifest accepted a dirty pinned sibling checkout"
fi

rehash_valid=true
while IFS=$'\t' read -r target manifest_sha manifest_size; do
    staged_path=$(echo "$contract_manifest_input" | jq -r --arg target "$target" \
        '.targets[] | select(.platform == $target) | .artifact_path')
    actual_sha=$(_act_sha256 "$staged_path")
    actual_size=$(_act_file_size "$staged_path")
    if [[ "$manifest_sha" != "$actual_sha" || "$manifest_size" != "$actual_size" ]]; then
        rehash_valid=false
    fi
done < <(echo "$contract_manifest" | jq -r '.artifacts[] | [.target, .sha256, (.size_bytes | tostring)] | @tsv')
if $rehash_valid; then
    pass "strict manifest recomputes staged file hashes and sizes"
else
    fail "strict manifest hash/size metadata does not match staged files"
fi

shared_manifest_dir="$TEMP_DIR/shared-manifest-artifacts"
mkdir -p "$shared_manifest_dir"
printf '{"kind":"evidence"}\n' > "$shared_manifest_dir/evidence.json"
while IFS=$'\t' read -r target expected_name; do
    write_minimal_target_binary "$shared_manifest_dir/$expected_name" "$target"
done < <(echo "$contract_json" | jq -r '.exact_primary_assets | to_entries[] | [.key, .value] | @tsv')
shared_manifest_input=$(echo "$contract_manifest_input" | jq --arg dir "$shared_manifest_dir" '
    .targets |= map(.artifact_path = "" | .artifact_paths = [] | .artifact_dir = $dir)
')
while IFS=$'\t' read -r target expected_name; do
    shared_path="$shared_manifest_dir/$expected_name"
    shared_sha=$(_act_sha256 "$shared_path")
    shared_size=$(_act_file_size "$shared_path")
    shared_identity=$(_act_file_identity "$shared_path")
    shared_manifest_input=$(echo "$shared_manifest_input" | jq \
        --arg target "$target" \
        --arg sha "$shared_sha" \
        --argjson size "$shared_size" \
        --arg identity "$shared_identity" '
            .targets |= map(
                if .platform == $target then
                    .staged_sha256 = $sha |
                    .staged_size_bytes = $size |
                    .staged_identity = $identity
                else . end
            )
        ')
done < <(echo "$contract_json" | jq -r '.exact_primary_assets | to_entries[] | [.key, .value] | @tsv')
shared_manifest=$(
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        act_generate_manifest "$shared_manifest_input" ""
    ) 2>/dev/null
)
if echo "$shared_manifest" | jq -e '.artifacts | length == 6' &>/dev/null; then
    pass "strict manifest selects exact primaries from a shared noisy artifact directory"
else
    fail "strict manifest rejected a valid shared artifact directory: $shared_manifest"
fi

strict_manifest_rejected() {
    local candidate="$1"
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        ! act_generate_manifest "$candidate" "" >/dev/null 2>&1
    )
}

mutated_staged_source="$TEMP_DIR/mutated-staged-source/focr"
mkdir -p "$(dirname "$mutated_staged_source")"
write_minimal_target_binary "$mutated_staged_source" "linux/amd64"
mutated_staged_result=$(_act_stage_contract_primary \
    "focrtest" "v1.0.0" "550e8400-e29b-41d4-a716-446655440023" "linux/amd64" \
    "$(with_collection_receipt "$(jq -nc --arg path "$mutated_staged_source" '{
        platform: "linux/amd64", status: "success", artifact_path: $path, artifact_paths: [$path]
    }')" "$mutated_staged_source")" "$(config_get_release_contract_json "focrtest")")
mutated_staged_input=$(echo "$contract_manifest_input" | jq \
    --argjson replacement "$mutated_staged_result" '
        .targets |= map(if .platform == "linux/amd64" then $replacement else . end)
    ')
mutated_staged_path=$(echo "$mutated_staged_result" | jq -r '.artifact_path')
printf 'different valid executable bytes\n' >> "$mutated_staged_path"
if strict_manifest_rejected "$mutated_staged_input"; then
    pass "strict manifest rejects valid-architecture bytes changed after staging"
else
    fail "strict manifest blessed an artifact that changed after staging"
fi

bad_summary=$(echo "$contract_manifest_input" | \
    jq '.status = "partial" | .summary = {total: 6, success: 5, failed: 1}')
if strict_manifest_rejected "$bad_summary"; then
    pass "strict manifest rejects non-N/N orchestration summary"
else
    fail "strict manifest accepted a non-N/N orchestration summary"
fi

missing_primary=$(echo "$contract_manifest_input" | \
    jq '.targets[0].artifact_path = "/nonexistent/focr" | .targets[0].artifact_paths = ["/nonexistent/focr"]')
if strict_manifest_rejected "$missing_primary"; then
    pass "strict manifest rejects a missing primary"
else
    fail "strict manifest accepted a missing primary"
fi

duplicate_dir="$TEMP_DIR/contract-duplicate"
mkdir -p "$duplicate_dir"
first_name=$(echo "$contract_manifest_input" | jq -r '.targets[0].artifact_path | split("/")[-1]')
printf 'duplicate primary\n' > "$duplicate_dir/$first_name"
duplicate_primary=$(echo "$contract_manifest_input" | jq \
    --arg duplicate "$duplicate_dir/$first_name" \
    '.targets[0].artifact_paths += [$duplicate]')
if strict_manifest_rejected "$duplicate_primary"; then
    pass "strict manifest rejects duplicate primaries"
else
    fail "strict manifest accepted duplicate primaries"
fi

extra_path="$TEMP_DIR/unexpected-evidence.json"
printf '{"evidence":true}\n' > "$extra_path"
extra_primary=$(echo "$contract_manifest_input" | jq --arg extra "$extra_path" \
    '.targets[0].artifact_paths += [$extra]')
if strict_manifest_rejected "$extra_primary"; then
    pass "strict manifest rejects explicit extra files"
else
    fail "strict manifest accepted an explicit extra file"
fi

wrong_target=$(echo "$contract_manifest_input" | jq \
    '.targets[0].artifact_path = .targets[1].artifact_path |
     .targets[0].artifact_paths = [.targets[1].artifact_path]')
if strict_manifest_rejected "$wrong_target"; then
    pass "strict manifest rejects a primary assigned to the wrong target"
else
    fail "strict manifest accepted a wrong-target primary"
fi

write_status=0
(
    ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
    git() {
        case "$*" in
            *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                printf '%s\n' "$contract_sha"
                ;;
            *"status --porcelain --untracked-files=all"*) return 0 ;;
            *) return 1 ;;
        esac
    }
    act_generate_manifest "$contract_manifest_input" "$TEMP_DIR" >/dev/null 2>&1
) || write_status=$?
if [[ $write_status -ne 0 ]]; then
    pass "manifest output write failures propagate"
else
    fail "manifest output write failure was swallowed"
fi

manifest_sentinel="$TEMP_DIR/manifest-sentinel"
manifest_symlink="$TEMP_DIR/manifest-link.json"
printf 'sentinel must survive\n' > "$manifest_sentinel"
ln -s "$manifest_sentinel" "$manifest_symlink"
symlink_write_status=0
(
    ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
    git() {
        case "$*" in
            *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                printf '%s\n' "$contract_sha"
                ;;
            *"status --porcelain --untracked-files=all"*) return 0 ;;
            *) return 1 ;;
        esac
    }
    act_generate_manifest "$contract_manifest_input" "$manifest_symlink" >/dev/null 2>&1
) || symlink_write_status=$?
if [[ $symlink_write_status -ne 0 && "$(cat "$manifest_sentinel")" == "sentinel must survive" ]]; then
    pass "strict manifest refuses a symlink destination without changing its target"
else
    fail "strict manifest followed a symlink destination"
fi

echo ""
echo "== strict Cargo source closure =="

closure_source_root="$TEMP_DIR/closure-snapshot/source"
closure_snapshot_parent="${closure_source_root%/*}"
closure_sha="4444444444444444444444444444444444444444"
closure_internal_metadata=$(jq -nc --arg root "$closure_source_root" '{
    workspace_root: $root,
    packages: [
        {manifest_path: ($root + "/Cargo.toml"), source: null},
        {manifest_path: ($root + "/crates/internal/Cargo.toml"), source: null},
        {manifest_path: "/cargo/registry/cache/Cargo.toml", source: "registry+https://github.com/rust-lang/crates.io-index"}
    ]
}')
if _act_validate_cargo_metadata_source_closure \
    "$closure_source_root" '[]' "$closure_internal_metadata" >/dev/null 2>&1; then
    pass "strict Cargo closure accepts internal workspace packages"
else
    fail "strict Cargo closure rejected internal workspace packages"
fi

closure_pins=$(jq -nc --arg path "$TEMP_DIR/local-frankentorch" --arg sha "$closure_sha" '[{
    relative_path: "frankentorch",
    local_path: $path,
    git_sha: $sha
}]')
closure_sibling_metadata=$(jq -nc \
    --arg root "$closure_source_root" \
    --arg sibling "$closure_snapshot_parent/frankentorch/crates/ft-core/Cargo.toml" '{
        workspace_root: $root,
        packages: [
            {manifest_path: ($root + "/Cargo.toml"), source: null},
            {manifest_path: $sibling, source: null}
        ]
    }')
if _act_validate_cargo_metadata_source_closure \
    "$closure_source_root" "$closure_pins" "$closure_sibling_metadata" >/dev/null 2>&1; then
    pass "strict Cargo closure accepts a configured pinned sibling workspace"
else
    fail "strict Cargo closure rejected a configured pinned sibling workspace"
fi

closure_unconfigured_metadata=$(jq -nc \
    --arg root "$closure_source_root" \
    --arg escaped "$closure_source_root/../../unconfigured/Cargo.toml" '{
        workspace_root: $root,
        packages: [
            {manifest_path: ($root + "/Cargo.toml"), source: null},
            {manifest_path: $escaped, source: null}
        ]
    }')
if ! _act_validate_cargo_metadata_source_closure \
    "$closure_source_root" '[]' "$closure_unconfigured_metadata" >/dev/null 2>&1; then
    pass "strict Cargo closure rejects canonicalized escaping and unconfigured package paths"
else
    fail "strict Cargo closure accepted an escaping unconfigured package path"
fi

closure_workspace_escape=$(jq -nc \
    --arg root "$closure_source_root" \
    --arg workspace "$closure_source_root/../outside-workspace" '{
        workspace_root: $workspace,
        packages: [{manifest_path: ($root + "/Cargo.toml"), source: null}]
    }')
if ! _act_validate_cargo_metadata_source_closure \
    "$closure_source_root" '[]' "$closure_workspace_escape" >/dev/null 2>&1; then
    pass "strict Cargo closure rejects a workspace root outside the fresh snapshot"
else
    fail "strict Cargo closure accepted an escaping workspace root"
fi

closure_two_pins=$(jq -nc --arg path "$TEMP_DIR/local-pins" --arg sha "$closure_sha" '[
    {relative_path: "frankentorch", local_path: ($path + "/frankentorch"), git_sha: $sha},
    {relative_path: "frankensqlite", local_path: ($path + "/frankensqlite"), git_sha: $sha}
]')
if ! _act_validate_cargo_metadata_source_closure \
    "$closure_source_root" "$closure_two_pins" "$closure_sibling_metadata" >/dev/null 2>&1; then
    pass "strict Cargo closure requires metadata-discovered siblings to equal manifest pins"
else
    fail "strict Cargo closure accepted a missing manifest pin"
fi

closure_metadata_command_file="$TEMP_DIR/strict-cargo-metadata-command"
closure_metadata_command_status=0
(
    _act_is_windows_host() { return 1; }
    _act_ssh_exec() {
        printf '%s\n' "$2" > "$closure_metadata_command_file"
        printf '%s\n%s\n' "$closure_source_root" "$closure_internal_metadata"
    }
    _act_validate_strict_cargo_source_closure \
        "stub-host" "$closure_source_root" '[]'
) >/dev/null 2>&1 || closure_metadata_command_status=$?
if [[ $closure_metadata_command_status -eq 0 ]] && \
   grep -Fq "ancestor='$closure_snapshot_parent'" "$closure_metadata_command_file" && \
   grep -Fq "cd '$closure_source_root'" "$closure_metadata_command_file" && \
   grep -Fq "CARGO_HOME=\"\$strict_home\" cargo metadata --locked --offline --all-features --format-version 1" \
        "$closure_metadata_command_file"; then
    pass "strict Cargo metadata uses the build cwd while isolating ancestor config"
else
    fail "strict Cargo metadata cwd/config isolation was not constructed"
fi

linux_identity_command="$(declare -f _act_file_identity); exec 9< /etc/os-release; path_identity=\$(_act_file_identity /etc/os-release); fd_identity=\$(_act_file_identity /dev/fd/9); exec 9<&-; printf '%s %s\\n' \"\$path_identity\" \"\$fd_identity\"; test \"\$path_identity\" = \"\$fd_identity\""
linux_identity_status=0
linux_identity_output=$(command ssh \
    -o BatchMode=yes -o ConnectTimeout=5 trj \
    "$linux_identity_command" 2>/dev/null) || linux_identity_status=$?
if [[ $linux_identity_status -eq 0 && \
      "$linux_identity_output" =~ ^gnu:[0-9]+:[1-9][0-9]*\ gnu:[0-9]+:[1-9][0-9]*$ ]]; then
    pass "GNU/Linux identity dereferences an open descriptor to device and inode"
elif [[ $linux_identity_status -ne 0 ]]; then
    skip "GNU/Linux identity host unavailable"
else
    fail "GNU/Linux descriptor identity did not match its path: $linux_identity_output"
fi

echo ""
echo "== strict fresh source sync =="

strict_sync_repo="$TEMP_DIR/strict-sync-repo"
strict_sync_base="$TEMP_DIR/strict-sync-remote/project"
strict_sync_run_id="550e8400-e29b-41d4-a716-446655440040"
strict_gitlink_repo="$TEMP_DIR/strict-gitlink-repo"
mkdir -p "$strict_gitlink_repo"
printf 'pinned submodule commit\n' > "$strict_gitlink_repo/README.md"
git -C "$strict_gitlink_repo" init -q
git -C "$strict_gitlink_repo" add README.md
git -C "$strict_gitlink_repo" -c user.name=DSR-Test -c user.email=dsr-test@example.invalid \
    commit -qm 'gitlink fixture'
strict_gitlink_sha=$(git -C "$strict_gitlink_repo" rev-parse HEAD)
mkdir -p "$strict_sync_repo"
printf 'tracked release bytes\n' > "$strict_sync_repo/tracked.txt"
printf 'ignored.cache\n' > "$strict_sync_repo/.gitignore"
printf 'must never reach a strict builder\n' > "$strict_sync_repo/ignored.cache"
git -C "$strict_sync_repo" init -q
git -C "$strict_sync_repo" add tracked.txt .gitignore
git -C "$strict_sync_repo" update-index --add \
    --cacheinfo "160000,$strict_gitlink_sha,vendor/submodule"
mkdir -p "$strict_sync_repo/vendor/submodule"
git -C "$strict_sync_repo" -c user.name=DSR-Test -c user.email=dsr-test@example.invalid \
    commit -qm 'strict sync fixture'
strict_sync_sha=$(git -C "$strict_sync_repo" rev-parse HEAD)

cat > "$ACT_REPOS_DIR/synctest.yaml" << EOF
tool_name: synctest
repo: Test/synctest
local_path: $strict_sync_repo
language: rust
binary_name: focr
build_cmd: cargo build --release
targets:
  - linux/amd64
act_job_map:
  linux/amd64: null
host_paths:
  trj: $strict_sync_base
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: focr-x86_64-unknown-linux-gnu
EOF

legacy_strict_sync_status=0
(
    rsync() { return 99; }
    act_sync_sources "synctest" "linux/amd64"
) >/dev/null 2>&1 || legacy_strict_sync_status=$?
if [[ $legacy_strict_sync_status -eq 4 ]]; then
    pass "strict tools refuse legacy source sync that could invoke rsync --delete"
else
    fail "strict tool accepted legacy source sync"
fi

archive_race_evidence_dir="$TEMP_DIR/archive-race-evidence"
archive_race_path="$archive_race_evidence_dir/source.tar"
archive_race_victim="$TEMP_DIR/archive-race-victim"
mkdir -p "$archive_race_evidence_dir"
printf 'archive victim must remain unchanged\n' > "$archive_race_victim"
archive_race_status=0
(
    mktemp() { printf '%s\n' "$archive_race_evidence_dir"; }
    git() {
        if [[ "$*" == *" archive --format=tar "* ]]; then
            mv "$archive_race_path" "$archive_race_path.opened" || return
            ln -s "$archive_race_victim" "$archive_race_path" || return
        fi
        command git "$@"
    }
    _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" \
        "$TEMP_DIR/archive-race-remote/run/source" "source.tar" "archive-race"
) >/dev/null 2>&1 || archive_race_status=$?
if [[ $archive_race_status -eq 4 && \
      "$(cat "$archive_race_victim")" == "archive victim must remain unchanged" ]]; then
    pass "strict evidence archive creation rejects a post-open symlink race"
else
    fail "strict evidence archive creation followed or accepted a symlink race"
fi

manifest_race_evidence_dir="$TEMP_DIR/manifest-race-evidence"
manifest_race_path="$manifest_race_evidence_dir/source.manifest"
manifest_race_victim="$TEMP_DIR/manifest-race-victim"
mkdir -p "$manifest_race_evidence_dir"
printf 'manifest victim must remain unchanged\n' > "$manifest_race_victim"
manifest_race_status=0
(
    mktemp() { printf '%s\n' "$manifest_race_evidence_dir"; }
    git() {
        if [[ "$*" == *" ls-tree -r --full-tree "* ]]; then
            mv "$manifest_race_path" "$manifest_race_path.opened" || return
            ln -s "$manifest_race_victim" "$manifest_race_path" || return
        fi
        command git "$@"
    }
    _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" \
        "$TEMP_DIR/manifest-race-remote/run/source" "source.tar" "manifest-race"
) >/dev/null 2>&1 || manifest_race_status=$?
if [[ $manifest_race_status -eq 4 && \
      "$(cat "$manifest_race_victim")" == "manifest victim must remain unchanged" ]]; then
    pass "strict evidence manifest creation rejects a post-open symlink race"
else
    fail "strict evidence manifest creation followed or accepted a symlink race"
fi

strict_sync_status=0
strict_sync_output=$(
    (
        rsync() { return 99; }
        act_sync_sources "synctest" --strict-release \
            --run-id "$strict_sync_run_id" --git-sha "$strict_sync_sha" -- "linux/amd64"
    ) 2>/dev/null
) || strict_sync_status=$?
strict_sync_root=$(echo "$strict_sync_output" | jq -r '.source_roots.trj // empty')
strict_sync_manifest="${strict_sync_root%/source}/.source.manifest"
strict_sync_object_count=$(_act_tracked_manifest_object_count "$strict_sync_manifest" 2>/dev/null || true)
if [[ $strict_sync_status -eq 0 && -n "$strict_sync_root" && \
      -f "$strict_sync_root/tracked.txt" && ! -e "$strict_sync_root/.git" && \
      ! -e "$strict_sync_root/ignored.cache" && \
      -d "$strict_sync_root/vendor/submodule" && \
      -z "$(find "$strict_sync_root/vendor/submodule" -mindepth 1 -print -quit)" && \
      "$strict_sync_object_count" == "4" ]] && \
   grep -Fq "$strict_gitlink_sha"$'\t160000\tvendor/submodule' "$strict_sync_manifest" && \
   echo "$strict_sync_output" | jq -e \
        '.status == "success" and (.source_roots | keys) == ["trj"]' &>/dev/null; then
    pass "strict sync authenticates gitlinks as empty directory placeholders"
else
    fail "strict fresh source sync failed: status=$strict_sync_status output=$strict_sync_output"
fi

ACT_REPO_LOCAL_PATH="$strict_sync_repo"
if _act_verify_strict_source_roots \
    "synctest" "$strict_sync_sha" "$(echo "$strict_sync_output" | jq -c '.source_roots')" \
    >/dev/null 2>&1; then
    pass "strict source-root verification accepts an unchanged transferred snapshot"
else
    fail "strict source-root verification rejected an unchanged transferred snapshot"
fi

strict_gitlink_tamper_root="$TEMP_DIR/strict-gitlink-tamper/run/source"
if _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_gitlink_tamper_root" \
        "source.tar" "gitlink-tamper" >/dev/null 2>&1; then
    printf 'must not enter a gitlink placeholder\n' > \
        "$strict_gitlink_tamper_root/vendor/submodule/injected.txt"
fi
if ! _act_verify_strict_checkout_snapshot \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_gitlink_tamper_root" \
        "source.tar" "gitlink-tamper" >/dev/null 2>&1; then
    pass "strict source verification rejects content beneath a gitlink placeholder"
else
    fail "strict source verification accepted content beneath a gitlink placeholder"
fi

strict_extra_file_root="$TEMP_DIR/strict-extra-file/run/source"
if _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_extra_file_root" \
        "source.tar" "extra-file" >/dev/null 2>&1; then
    printf 'post-build output\n' > "$strict_extra_file_root/post-build-output"
fi
if ! _act_verify_strict_checkout_snapshot \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_extra_file_root" \
        "source.tar" "extra-file" >/dev/null 2>&1; then
    pass "strict local source verification rejects an extra file"
else
    fail "strict local source verification accepted an extra file"
fi

strict_extra_symlink_root="$TEMP_DIR/strict-extra-symlink/run/source"
if _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_extra_symlink_root" \
        "source.tar" "extra-symlink" >/dev/null 2>&1; then
    ln -s "tracked.txt" "$strict_extra_symlink_root/post-build-link"
fi
if ! _act_verify_strict_checkout_snapshot \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_extra_symlink_root" \
        "source.tar" "extra-symlink" >/dev/null 2>&1; then
    pass "strict local source verification rejects an extra symlink"
else
    fail "strict local source verification accepted an extra symlink"
fi

strict_extra_dir_root="$TEMP_DIR/strict-extra-dir/run/source"
if _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_extra_dir_root" \
        "source.tar" "extra-directory" >/dev/null 2>&1; then
    mkdir "$strict_extra_dir_root/post-build-directory"
fi
if ! _act_verify_strict_checkout_snapshot \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_extra_dir_root" \
        "source.tar" "extra-directory" >/dev/null 2>&1; then
    pass "strict local source verification rejects an extra directory"
else
    fail "strict local source verification accepted an extra directory"
fi

strict_unix_file_root="$TEMP_DIR/strict-unix-file/run/source"
_act_sync_strict_checkout \
    "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_file_root" \
    "source.tar" "unix-extra-file" >/dev/null 2>&1
printf 'remote build output\n' > "$strict_unix_file_root/remote-output"
strict_unix_file_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 1; }
    _act_get_ssh_destination() { printf 'mock-unix\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command="${!#}"
        "$BASH" -c "$remote_command"
    }
    _act_verify_strict_checkout_snapshot \
        "mmini" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_file_root" \
        "source.tar" "unix-extra-file"
) >/dev/null 2>&1 || strict_unix_file_status=$?
if [[ $strict_unix_file_status -eq 4 ]]; then
    pass "strict mocked Unix SSH verification rejects an extra file"
else
    fail "strict mocked Unix SSH verification accepted an extra file"
fi

strict_unix_gitlink_root="$TEMP_DIR/strict-unix-gitlink/run/source"
_act_sync_strict_checkout \
    "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_gitlink_root" \
    "source.tar" "unix-gitlink" >/dev/null 2>&1
strict_unix_gitlink_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 1; }
    _act_get_ssh_destination() { printf 'mock-unix\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command="${!#}"
        "$BASH" -c "$remote_command"
    }
    _act_verify_strict_checkout_snapshot \
        "mmini" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_gitlink_root" \
        "source.tar" "unix-gitlink"
) >/dev/null 2>&1 || strict_unix_gitlink_status=$?
if [[ $strict_unix_gitlink_status -eq 0 ]]; then
    pass "strict mocked Unix SSH verification accepts an empty gitlink placeholder"
else
    fail "strict mocked Unix SSH verification rejected an empty gitlink placeholder"
fi

strict_unix_symlink_root="$TEMP_DIR/strict-unix-symlink/run/source"
_act_sync_strict_checkout \
    "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_symlink_root" \
    "source.tar" "unix-extra-symlink" >/dev/null 2>&1
ln -s "tracked.txt" "$strict_unix_symlink_root/remote-link"
strict_unix_symlink_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 1; }
    _act_get_ssh_destination() { printf 'mock-unix\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command="${!#}"
        "$BASH" -c "$remote_command"
    }
    _act_verify_strict_checkout_snapshot \
        "mmini" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_symlink_root" \
        "source.tar" "unix-extra-symlink"
) >/dev/null 2>&1 || strict_unix_symlink_status=$?
if [[ $strict_unix_symlink_status -eq 4 ]]; then
    pass "strict mocked Unix SSH verification rejects an extra symlink"
else
    fail "strict mocked Unix SSH verification accepted an extra symlink"
fi

strict_windows_archive_digest=$(_act_git_archive_sha256 "$strict_sync_repo" "$strict_sync_sha")
strict_windows_gitlink_command_file="$TEMP_DIR/strict-windows-gitlink-command"
strict_windows_gitlink_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 0; }
    _act_get_ssh_destination() { printf 'mock-windows\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command="${!#}" manifest_digest
        printf '%s\n' "$remote_command" > "$strict_windows_gitlink_command_file"
        manifest_digest=$(printf '%s\n' "$remote_command" | grep -Eo '[0-9a-f]{64}' | head -1)
        printf '%s %s\n' "$strict_windows_archive_digest" "$manifest_digest"
    }
    _act_verify_strict_checkout_snapshot \
        "wlap" "$strict_sync_repo" "$strict_sync_sha" \
        "C:/build/.dsr-release-snapshots/windows-gitlink/run/source" \
        "source.tar" "windows-gitlink"
) >/dev/null 2>&1 || strict_windows_gitlink_status=$?
if [[ $strict_windows_gitlink_status -eq 0 ]] && \
   grep -Fq "parts[1] -eq '160000'" "$strict_windows_gitlink_command_file" && \
   grep -Fq 'Get-ChildItem -LiteralPath $node -Force' "$strict_windows_gitlink_command_file"; then
    pass "strict Windows verification requires gitlinks to be empty plain directories"
else
    fail "strict Windows verification omitted the gitlink placeholder contract"
fi

strict_windows_verify_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 0; }
    _act_get_ssh_destination() { printf 'mock-windows\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command="${!#}" manifest_digest
        if [[ "$remote_command" == *"Get-ChildItem"* && "$remote_command" == *'.Count -ne '* ]]; then
            return 20
        fi
        manifest_digest=$(printf '%s\n' "$remote_command" | grep -Eo '[0-9a-f]{64}' | head -1)
        printf '%s %s\n' "$strict_windows_archive_digest" "$manifest_digest"
    }
    _act_verify_strict_checkout_snapshot \
        "wlap" "$strict_sync_repo" "$strict_sync_sha" \
        "C:/build/.dsr-release-snapshots/windows-extra/run/source" \
        "source.tar" "windows-extra-file"
) >/dev/null 2>&1 || strict_windows_verify_status=$?
if [[ $strict_windows_verify_status -eq 4 ]]; then
    pass "strict mocked Windows verification rejects an extra file"
else
    fail "strict mocked Windows verification accepted an extra file"
fi

strict_windows_reparse_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 0; }
    _act_get_ssh_destination() { printf 'mock-windows\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command="${!#}" manifest_digest
        if [[ "$remote_command" == *"ReparsePoint"* ]]; then
            return 21
        fi
        manifest_digest=$(printf '%s\n' "$remote_command" | grep -Eo '[0-9a-f]{64}' | head -1)
        printf '%s %s\n' "$strict_windows_archive_digest" "$manifest_digest"
    }
    _act_verify_strict_checkout_snapshot \
        "wlap" "$strict_sync_repo" "$strict_sync_sha" \
        "C:/build/.dsr-release-snapshots/windows-reparse/run/source" \
        "source.tar" "windows-extra-symlink"
) >/dev/null 2>&1 || strict_windows_reparse_status=$?
if [[ $strict_windows_reparse_status -eq 4 ]]; then
    pass "strict mocked Windows verification rejects a reparse-point symlink"
else
    fail "strict mocked Windows verification accepted a reparse-point symlink"
fi

strict_windows_sync_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 0; }
    _act_get_ssh_destination() { printf 'mock-windows\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command="${!#}"
        if [[ "$remote_command" == *"ReparsePoint"* ]]; then
            return 22
        fi
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum | awk '{print $1}'
        else
            shasum -a 256 | awk '{print $1}'
        fi
    }
    _act_sync_strict_checkout \
        "wlap" "$strict_sync_repo" "$strict_sync_sha" \
        "C:/build/.dsr-release-snapshots/windows-sync/run/source" \
        "source.tar" "windows-reparse-sync"
) >/dev/null 2>&1 || strict_windows_sync_status=$?
if [[ $strict_windows_sync_status -eq 4 ]]; then
    pass "strict mocked Windows sync rejects a reparse-point parent or component"
else
    fail "strict mocked Windows sync accepted a reparse-point parent or component"
fi

printf 'post-build mutation\n' >> "$strict_sync_root/tracked.txt"
if ! _act_verify_strict_source_roots \
    "synctest" "$strict_sync_sha" "$(echo "$strict_sync_output" | jq -c '.source_roots')" \
    >/dev/null 2>&1; then
    pass "strict source-root verification rejects changed remote tracked bytes"
else
    fail "strict source-root verification accepted changed remote tracked bytes"
fi

cat > "$ACT_REPOS_DIR/actsynctest.yaml" << EOF
tool_name: actsynctest
repo: Test/actsynctest
local_path: $strict_sync_repo
language: rust
binary_name: focr
build_cmd: cargo build --release
targets:
  - linux/amd64
act_job_map:
  linux/amd64: build-linux
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: focr-x86_64-unknown-linux-gnu
EOF
strict_act_sync_sentinel="$TEMP_DIR/strict-act-sync-ran"
strict_act_sync_status=0
strict_act_sync_output=$(
    (
        _act_sync_strict_checkout() {
            printf 'called\n' > "$strict_act_sync_sentinel"
            return 99
        }
        act_sync_sources "actsynctest" --strict-release \
            --run-id "550e8400-e29b-41d4-a716-446655440042" \
            --git-sha "$strict_sync_sha" -- "linux/amd64"
    ) 2>/dev/null
) || strict_act_sync_status=$?
if [[ $strict_act_sync_status -eq 4 && ! -e "$strict_act_sync_sentinel" ]] && \
   echo "$strict_act_sync_output" | jq -e \
        '.status == "error" and (.error | contains("native builds"))' &>/dev/null; then
    pass "strict source sync rejects act targets before creating a snapshot"
else
    fail "strict source sync reached act snapshot work: status=$strict_act_sync_status output=$strict_act_sync_output"
fi

strict_act_build_sentinel="$TEMP_DIR/strict-act-build-ran"
strict_act_build_status=0
strict_act_build_output=$(
    (
        act_run_workflow() {
            printf 'called\n' > "$strict_act_build_sentinel"
            return 99
        }
        act_orchestrate_build "actsynctest" "v1.0.0" "linux/amd64"
    ) 2>/dev/null
) || strict_act_build_status=$?
if [[ $strict_act_build_status -eq 4 && ! -e "$strict_act_build_sentinel" ]] && \
   echo "$strict_act_build_output" | jq -e \
        '.status == "error" and (.error | contains("native builds"))' &>/dev/null; then
    pass "strict orchestration rejects act targets before workflow execution"
else
    fail "strict orchestration reached act workflow work: status=$strict_act_build_status output=$strict_act_build_output"
fi

reused_sync_status=0
(
    rsync() { return 99; }
    act_sync_sources "synctest" --strict-release \
        --run-id "$strict_sync_run_id" --git-sha "$strict_sync_sha" -- "linux/amd64"
) >/dev/null 2>&1 || reused_sync_status=$?
if [[ $reused_sync_status -ne 0 ]]; then
    pass "strict sync refuses a pre-existing source root"
else
    fail "strict sync reused a pre-existing source root"
fi

printf '[dependencies]\nasupersync = { path = "/dp/asupersync" }\n' > "$strict_sync_repo/Cargo.toml"
git -C "$strict_sync_repo" add Cargo.toml
git -C "$strict_sync_repo" -c user.name=DSR-Test -c user.email=dsr-test@example.invalid \
    commit -qm 'absolute path rejection fixture'
absolute_path_sha=$(git -C "$strict_sync_repo" rev-parse HEAD)
absolute_path_status=0
(
    rsync() { return 99; }
    act_sync_sources "synctest" --strict-release \
        --run-id "550e8400-e29b-41d4-a716-446655440041" \
        --git-sha "$absolute_path_sha" -- "linux/amd64"
) >/dev/null 2>&1 || absolute_path_status=$?
if [[ $absolute_path_status -ne 0 ]]; then
    pass "strict sync rejects absolute Cargo sibling paths instead of rewriting tag bytes"
else
    fail "strict sync accepted and could mutate an absolute Cargo sibling path"
fi

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Summary"
echo "═══════════════════════════════════════════════════════════════"
echo -e "  ${GREEN}Passed:${NC}  $PASS"
echo -e "  ${RED}Failed:${NC}  $FAIL"
echo -e "  ${YELLOW}Skipped:${NC} $SKIP"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
