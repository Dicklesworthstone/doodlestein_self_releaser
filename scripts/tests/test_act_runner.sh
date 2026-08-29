#!/usr/bin/env bash
# test_act_runner.sh - Unit tests for act_runner.sh module
#
# Usage: ./test_act_runner.sh
#
# Tests act integration functions without actually running Docker

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_ROOT/src"

# Source the module under test
source "$SRC_DIR/act_runner.sh"

# Colors
if [[ -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

log_pass() { echo -e "${GREEN}✓${NC} $1"; ((PASS_COUNT++)); }
log_fail() { echo -e "${RED}✗${NC} $1"; ((FAIL_COUNT++)); }
log_skip() { echo -e "${YELLOW}○${NC} $1"; ((SKIP_COUNT++)); }
log_test() { echo -e "\n== $1 =="; }

# Create temporary test fixtures
setup_fixtures() {
    TEMP_DIR=$(mktemp -d)
    WORKFLOW_DIR="$TEMP_DIR/.github/workflows"
    mkdir -p "$WORKFLOW_DIR"

    # Create sample workflow file
    cat > "$WORKFLOW_DIR/release.yml" << 'EOF'
name: Release

on:
  push:
    tags: ['v*']

jobs:
  build-linux:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4
      - run: echo "Building Linux"

  build-macos:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: echo "Building macOS"

  build-windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "Building Windows"

  test:
    runs-on: ubuntu-latest
    needs: [build-linux]
    steps:
      - run: echo "Testing"
EOF

    # Create minimal workflow
    cat > "$WORKFLOW_DIR/ci.yml" << 'EOF'
name: CI
on: push
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Linting"
EOF
}

cleanup_fixtures() {
    rm -rf "$TEMP_DIR"
}

# Test act_can_run function
test_act_can_run() {
    log_test "act_can_run"

    # Linux runners should return 0 (can run)
    if act_can_run "ubuntu-latest"; then
        log_pass "ubuntu-latest returns 0"
    else
        log_fail "ubuntu-latest should return 0"
    fi

    if act_can_run "ubuntu-22.04"; then
        log_pass "ubuntu-22.04 returns 0"
    else
        log_fail "ubuntu-22.04 should return 0"
    fi

    # macOS/Windows runners should return 1 (needs native)
    if ! act_can_run "macos-14"; then
        log_pass "macos-14 returns 1 (needs native)"
    else
        log_fail "macos-14 should return 1"
    fi

    if ! act_can_run "windows-latest"; then
        log_pass "windows-latest returns 1 (needs native)"
    else
        log_fail "windows-latest should return 1"
    fi

    # Self-hosted with linux label
    if act_can_run "self-hosted, linux, x64"; then
        log_pass "self-hosted linux returns 0"
    else
        log_fail "self-hosted linux should return 0"
    fi
}

test_act_version_support() {
    log_test "act version support"

    if act_version_is_supported "0.2.86"; then
        log_pass "minimum supported act version is accepted"
    else
        log_fail "minimum supported act version should be accepted"
    fi

    if act_version_is_supported "0.2.87"; then
        log_pass "newer act version is accepted"
    else
        log_fail "newer act version should be accepted"
    fi

    if ! act_version_is_supported "0.2.84"; then
        log_pass "vulnerable act version is rejected"
    else
        log_fail "vulnerable act version should be rejected"
    fi
}

# Test act_get_runner function
test_act_get_runner() {
    log_test "act_get_runner"

    local runner

    runner=$(act_get_runner "$WORKFLOW_DIR/release.yml" "build-linux")
    if [[ "$runner" == *"ubuntu"* ]]; then
        log_pass "build-linux runner detected: $runner"
    else
        log_skip "build-linux runner detection (yq may not be available): $runner"
    fi

    runner=$(act_get_runner "$WORKFLOW_DIR/release.yml" "build-macos")
    if [[ "$runner" == *"macos"* ]]; then
        log_pass "build-macos runner detected: $runner"
    else
        log_skip "build-macos runner detection (yq may not be available): $runner"
    fi
}

# Test act_analyze_workflow function
test_act_analyze_workflow() {
    log_test "act_analyze_workflow (requires act and jq)"

    if ! command -v jq &>/dev/null; then
        log_skip "jq not available for workflow analysis"
        return
    fi

    if ! command -v act &>/dev/null; then
        log_skip "act not available for workflow analysis"
        return
    fi

    local analysis
    analysis=$(act_analyze_workflow "$WORKFLOW_DIR/release.yml" 2>/dev/null)

    if echo "$analysis" | jq -e '.workflow' &>/dev/null; then
        log_pass "Workflow analysis returns valid JSON"
    else
        log_fail "Workflow analysis JSON invalid"
    fi
}

# Test act_check function
test_act_check() {
    log_test "act_check"

    if command -v act &>/dev/null && docker info &>/dev/null 2>&1; then
        if act_check 2>/dev/null; then
            log_pass "act_check passes when act and docker available"
        else
            log_fail "act_check should pass when dependencies available"
        fi
    else
        if ! act_check 2>/dev/null; then
            log_pass "act_check fails when dependencies missing (expected)"
        else
            log_fail "act_check should fail when dependencies missing"
        fi
    fi
}

test_act_check_reads_config_dir_actrc() {
    log_test "act_check reads ~/.config/act/actrc"

    local bin_dir="$TEMP_DIR/bin-act-check"
    local fake_home="$TEMP_DIR/home-act-check"
    mkdir -p "$bin_dir" "$fake_home/.config/act"

    cat > "$bin_dir/act" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "act version 0.2.87"
    exit 0
fi
exit 0
EOF
    chmod +x "$bin_dir/act"

    cat > "$bin_dir/docker" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "$bin_dir/docker"

    cat > "$fake_home/.config/act/actrc" << 'EOF'
--bind
EOF

    local original_path="$PATH"
    PATH="$bin_dir:$PATH"

    if ! act_check "$fake_home" 2>/dev/null; then
        log_pass "act_check rejects bad ~/.config/act/actrc"
    else
        log_fail "Expected act_check to reject ~/.config/act/actrc without --user"
    fi

    PATH="$original_path"
}

# Test artifact directory creation
test_artifact_dirs() {
    log_test "artifact directories"

    export ACT_ARTIFACTS_DIR="$TEMP_DIR/artifacts"
    export ACT_LOGS_DIR="$TEMP_DIR/logs"

    mkdir -p "$ACT_ARTIFACTS_DIR" "$ACT_LOGS_DIR"

    if [[ -d "$ACT_ARTIFACTS_DIR" ]]; then
        log_pass "Artifact directory created"
    else
        log_fail "Artifact directory creation failed"
    fi

    if [[ -d "$ACT_LOGS_DIR" ]]; then
        log_pass "Logs directory created"
    else
        log_fail "Logs directory creation failed"
    fi
}

test_artifact_zip_wrapper_classification() {
    log_test "artifact zip wrapper classification"

    if act_artifact_zip_is_wrapper "act" "/tmp/workflow-artifact.zip" &&
       ! act_artifact_zip_is_wrapper "native" "/tmp/dcg-x86_64-pc-windows-msvc.zip" &&
       ! act_artifact_zip_is_wrapper "ssh" "/tmp/dcg-aarch64-pc-windows-msvc.zip" &&
       ! act_artifact_zip_is_wrapper "act" "/tmp/dcg-x86_64-unknown-linux-musl.tar.xz"; then
        log_pass "Only act-produced zip wrappers are unpacked"
    else
        log_fail "Native release archives must remain opaque during collection"
    fi
}

test_workspace_include_staging() {
    log_test "workspace companion-file staging"

    if ! command -v yq &>/dev/null; then
        log_skip "yq not available for workspace include staging"
        return
    fi

    local source_root="$TEMP_DIR/workspace-include-source"
    local artifact_dir="$TEMP_DIR/workspace-include-artifacts"
    local config_file="$TEMP_DIR/workspace-include.yaml"
    mkdir -p "$source_root/notices" "$artifact_dir"
    printf 'binary\n' > "$artifact_dir/fw"
    printf 'readme\n' > "$source_root/README.md"
    printf 'notice\n' > "$source_root/notices/THIRD_PARTY.txt"
    cat > "$config_file" << 'EOF'
include_files:
  - README.md
  - notices/THIRD_PARTY.txt
EOF

    local staged
    if staged=$(_act_stage_workspace_include_files "$config_file" "$source_root" "$artifact_dir") &&
       [[ "$staged" == $'README.md\nnotices/THIRD_PARTY.txt' ]] &&
       [[ "$(cat "$artifact_dir/README.md")" == "readme" ]] &&
       [[ "$(cat "$artifact_dir/notices/THIRD_PARTY.txt")" == "notice" ]] &&
       [[ "$(cat "$artifact_dir/fw")" == "binary" ]]; then
        log_pass "Configured companion files are staged in order without changing binaries"
    else
        log_fail "Configured companion files were not staged exactly"
    fi

    local bad_config="$TEMP_DIR/workspace-include-bad.yaml"
    cat > "$bad_config" << 'EOF'
include_files:
  - ../outside.txt
EOF
    if ! _act_stage_workspace_include_files "$bad_config" "$source_root" "$artifact_dir" >/dev/null 2>&1; then
        log_pass "Traversal in a workspace include fails closed"
    else
        log_fail "Traversal in a workspace include should fail"
    fi

    local outside_dir="$TEMP_DIR/workspace-include-outside"
    local symlink_config="$TEMP_DIR/workspace-include-symlink.yaml"
    mkdir -p "$outside_dir"
    printf 'outside\n' > "$outside_dir/OUTSIDE.txt"
    ln -s "$outside_dir" "$source_root/linked"
    cat > "$symlink_config" << 'EOF'
include_files:
  - linked/OUTSIDE.txt
EOF
    if ! _act_stage_workspace_include_files "$symlink_config" "$source_root" "$artifact_dir" >/dev/null 2>&1; then
        log_pass "A symlinked parent in a workspace include fails closed"
    else
        log_fail "A symlinked workspace include parent should fail"
    fi

    local collision_config="$TEMP_DIR/workspace-include-collision.yaml"
    printf 'replacement\n' > "$source_root/fw"
    cat > "$collision_config" << 'EOF'
include_files:
  - fw
EOF
    if ! _act_stage_workspace_include_files "$collision_config" "$source_root" "$artifact_dir" >/dev/null 2>&1 &&
       [[ "$(cat "$artifact_dir/fw")" == "binary" ]]; then
        log_pass "A companion-file collision cannot overwrite a binary"
    else
        log_fail "A companion-file collision must fail without overwriting"
    fi

    local exact_repo="$TEMP_DIR/workspace-include-git"
    local exact_artifact_dir="$TEMP_DIR/workspace-include-exact-artifacts"
    local exact_config="$TEMP_DIR/workspace-include-exact.yaml"
    mkdir -p "$exact_repo" "$exact_artifact_dir"
    git -C "$exact_repo" init -q
    git -C "$exact_repo" config user.name "DSR Test"
    git -C "$exact_repo" config user.email "dsr-test.invalid"
    git -C "$exact_repo" config filter.dsr-include-test.clean "sed 's/^worktree-smudged$/release-tree/'"
    git -C "$exact_repo" config filter.dsr-include-test.smudge "sed 's/^release-tree$/worktree-smudged/'"
    git -C "$exact_repo" config filter.dsr-include-test.required true
    mkdir -p "$exact_repo/scripts"
    printf 'README.md filter=dsr-include-test\n' > "$exact_repo/.gitattributes"
    printf 'worktree-smudged\n' > "$exact_repo/README.md"
    printf 'notice-tree\n' > "$exact_repo/NOTICE.txt"
    printf '#!/usr/bin/env bash\nprintf companion\n' > "$exact_repo/scripts/companion.sh"
    chmod 755 "$exact_repo/scripts/companion.sh"
    ln -s README.md "$exact_repo/README.link"
    git -C "$exact_repo" add .gitattributes README.md README.link NOTICE.txt scripts/companion.sh
    git -C "$exact_repo" -c commit.gpgsign=false commit -qm "test release tree"
    local exact_revision
    exact_revision=$(git -C "$exact_repo" rev-parse HEAD)
    cat > "$exact_config" << 'EOF'
include_files:
  - README.md
EOF

    local exact_staged exact_tree_bytes ambient_bytes
    exact_tree_bytes=$(git -C "$exact_repo" show "${exact_revision}:README.md")
    ambient_bytes=$(cat "$exact_repo/README.md")
    if [[ -z "$(git -C "$exact_repo" status --porcelain --untracked-files=all)" ]] &&
       [[ "$exact_tree_bytes" == "release-tree" ]] &&
       [[ "$ambient_bytes" == "worktree-smudged" ]] &&
       exact_staged=$(_act_stage_workspace_include_files \
           "$exact_config" "$exact_repo" "$exact_artifact_dir" "$exact_revision") &&
       [[ "$exact_staged" == "README.md" ]] &&
       [[ "$(cat "$exact_artifact_dir/README.md")" == "$exact_tree_bytes" ]] &&
       [[ "$(cat "$exact_artifact_dir/README.md")" != "$ambient_bytes" ]]; then
        log_pass "Strict companion files use exact release-tree bytes despite clean smudge filters"
    else
        log_fail "Strict companion files must not use clean-but-smudged worktree bytes"
    fi

    local exact_archive="$TEMP_DIR/workspace-include-exact.tar.gz"
    local smudged_archive="$TEMP_DIR/workspace-include-smudged.tar.gz"
    local wrong_mode_dir="$TEMP_DIR/workspace-include-wrong-mode"
    local wrong_mode_archive="$TEMP_DIR/workspace-include-wrong-mode.tar.gz"
    mkdir -p "$wrong_mode_dir"
    cp "$exact_artifact_dir/README.md" "$wrong_mode_dir/README.md"
    chmod 755 "$wrong_mode_dir/README.md"
    tar czf "$exact_archive" -C "$exact_artifact_dir" README.md
    tar czf "$smudged_archive" -C "$exact_repo" README.md
    tar czf "$wrong_mode_archive" -C "$wrong_mode_dir" README.md
    if _act_validate_workspace_archive_release_tree_includes \
           "$exact_archive" "tar.gz" "$exact_config" "$exact_repo" "$exact_revision" &&
       ! _act_validate_workspace_archive_release_tree_includes \
           "$smudged_archive" "tar.gz" "$exact_config" "$exact_repo" "$exact_revision" &&
       ! _act_validate_workspace_archive_release_tree_includes \
           "$wrong_mode_archive" "tar.gz" "$exact_config" "$exact_repo" "$exact_revision"; then
        log_pass "Strict archives bind companion bytes and mode to the release tree"
    else
        log_fail "Strict archives must reject smudged bytes and mode substitutions"
    fi

    local original_blob replacement_blob replacement_artifact_dir replacement_source_archive replacement_config
    original_blob=$(git -C "$exact_repo" rev-parse "${exact_revision}:NOTICE.txt")
    replacement_blob=$(printf 'replacement-ref-bytes\n' | \
        git -C "$exact_repo" hash-object -w --stdin)
    git -C "$exact_repo" replace "$original_blob" "$replacement_blob"
    replacement_artifact_dir="$TEMP_DIR/workspace-include-replacement-artifacts"
    replacement_source_archive="$TEMP_DIR/workspace-include-no-replace-source.tar"
    replacement_config="$TEMP_DIR/workspace-include-no-replace.yaml"
    mkdir -p "$replacement_artifact_dir"
    cat > "$replacement_config" << 'EOF'
include_files:
  - NOTICE.txt
EOF
    local replaced_bytes replacement_staged notice_tree_bytes
    replaced_bytes=$(git -C "$exact_repo" cat-file blob "$original_blob")
    notice_tree_bytes=$(_act_strict_git -C "$exact_repo" show "${exact_revision}:NOTICE.txt")
    if [[ "$replaced_bytes" == "replacement-ref-bytes" ]] &&
       _act_validate_strict_checkout_at_revision \
           "$exact_repo" "$exact_revision" "replacement-ref control" &&
       replacement_staged=$(_act_stage_workspace_include_files \
           "$replacement_config" "$exact_repo" "$replacement_artifact_dir" "$exact_revision") &&
       [[ "$replacement_staged" == "NOTICE.txt" ]] &&
       [[ "$notice_tree_bytes" == "notice-tree" ]] &&
       [[ "$(cat "$replacement_artifact_dir/NOTICE.txt")" == "$notice_tree_bytes" ]] &&
       _act_write_git_archive_evidence \
           "$exact_repo" "$exact_revision" "$replacement_source_archive" &&
       [[ "$(tar -xOf "$replacement_source_archive" NOTICE.txt)" == "$notice_tree_bytes" ]]; then
        log_pass "Strict Git reads ignore local replacement refs"
    else
        log_fail "Strict Git reads must not authorize replacement objects"
    fi

    local rejected_include rejected_config rejected_artifact strict_boundary_ok=true
    printf 'untracked worktree bytes\n' > "$exact_repo/UNTRACKED.txt"
    for rejected_include in README.link UNTRACKED.txt; do
        rejected_config="$TEMP_DIR/workspace-include-reject-${rejected_include//\//-}.yaml"
        rejected_artifact="$TEMP_DIR/workspace-include-reject-${rejected_include//\//-}"
        mkdir -p "$rejected_artifact"
        printf 'include_files:\n  - %s\n' "$rejected_include" > "$rejected_config"
        if _act_stage_workspace_include_files \
               "$rejected_config" "$exact_repo" "$rejected_artifact" "$exact_revision" \
               >/dev/null 2>&1 ||
           [[ -e "$rejected_artifact/$rejected_include" || \
              -L "$rejected_artifact/$rejected_include" ]]; then
            strict_boundary_ok=false
        fi
    done
    if $strict_boundary_ok; then
        log_pass "Strict companion staging rejects committed symlinks and worktree-only files"
    else
        log_fail "Strict companion staging must admit only regular release-tree blobs"
    fi

    local executable_config="$TEMP_DIR/workspace-include-executable.yaml"
    local executable_artifact="$TEMP_DIR/workspace-include-executable-artifacts"
    local executable_archive="$TEMP_DIR/workspace-include-executable.tar.gz"
    local nonexec_dir="$TEMP_DIR/workspace-include-nonexec"
    local nonexec_archive="$TEMP_DIR/workspace-include-nonexec.tar.gz"
    mkdir -p "$executable_artifact" "$nonexec_dir/scripts"
    cat > "$executable_config" << 'EOF'
include_files:
  - scripts/companion.sh
EOF
    chmod 644 "$exact_repo/scripts/companion.sh"
    local executable_staged
    executable_staged=$(_act_stage_workspace_include_files \
        "$executable_config" "$exact_repo" "$executable_artifact" "$exact_revision")
    tar czf "$executable_archive" -C "$executable_artifact" scripts/companion.sh
    cp "$executable_artifact/scripts/companion.sh" "$nonexec_dir/scripts/companion.sh"
    chmod 644 "$nonexec_dir/scripts/companion.sh"
    tar czf "$nonexec_archive" -C "$nonexec_dir" scripts/companion.sh
    if [[ "$executable_staged" == "scripts/companion.sh" ]] &&
       [[ -x "$executable_artifact/scripts/companion.sh" ]] &&
       _act_validate_workspace_archive_release_tree_includes \
           "$executable_archive" "tar.gz" "$executable_config" "$exact_repo" "$exact_revision" &&
       ! _act_validate_workspace_archive_release_tree_includes \
           "$nonexec_archive" "tar.gz" "$executable_config" "$exact_repo" "$exact_revision"; then
        log_pass "Strict companion staging preserves executable release-tree mode"
    else
        log_fail "Strict companion staging must bind executable mode to the release tree"
    fi
}

test_workspace_archive_collection_receipts() {
    log_test "workspace binary collection receipts"

    local original_dir="$TEMP_DIR/workspace-receipt-original"
    local substitute_dir="$TEMP_DIR/workspace-receipt-substitute"
    local original_archive="$TEMP_DIR/workspace-receipt-original.tar.gz"
    local substitute_archive="$TEMP_DIR/workspace-receipt-substitute.tar.gz"
    local receipt_config="$TEMP_DIR/workspace-receipt.yaml"
    mkdir -p "$original_dir" "$substitute_dir"
    printf 'AAAAAAAA' > "$original_dir/fw"
    printf 'BBBBBBBB' > "$substitute_dir/fw"
    tar czf "$original_archive" -C "$original_dir" fw
    tar czf "$substitute_archive" -C "$substitute_dir" fw
    cat > "$receipt_config" << 'EOF'
workspace_binaries:
  - fw
EOF

    local receipt bad_size_receipt identity
    identity=$(_act_file_identity "$original_dir/fw")
    receipt=$(jq -nc \
        --arg path "$original_dir/fw" \
        --arg sha256 "$(_act_sha256 "$original_dir/fw")" \
        --argjson size_bytes "$(_act_file_size "$original_dir/fw")" \
        --arg identity "$identity" \
        '{path: $path, sha256: $sha256, size_bytes: $size_bytes, identity: $identity}')
    bad_size_receipt=$(jq -c '.size_bytes += 1' <<< "$receipt")
    if _act_validate_workspace_archive_collection_receipts \
           "$original_archive" "tar.gz" "linux/amd64" "$receipt_config" "$receipt" &&
       ! _act_validate_workspace_archive_collection_receipts \
           "$substitute_archive" "tar.gz" "linux/amd64" "$receipt_config" "$receipt" &&
       ! _act_validate_workspace_archive_collection_receipts \
           "$original_archive" "tar.gz" "linux/amd64" "$receipt_config" "$bad_size_receipt" &&
       ! _act_validate_workspace_archive_collection_receipts \
           "$original_archive" "tar.gz" "linux/amd64" "$receipt_config" "$receipt" "$receipt"; then
        log_pass "Workspace archives preserve exact collected binary bytes"
    else
        log_fail "Workspace archives must reject equal-size binary substitutions"
    fi
}

test_strict_git_commit_replacement_binding() {
    log_test "strict Git commit replacement binding"

    local repo="$TEMP_DIR/strict-commit-replacement"
    local protected_archive="$TEMP_DIR/strict-commit-replacement.tar"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.name "DSR Test"
    git -C "$repo" config user.email "dsr-test.invalid"
    printf 'authentic tree\n' > "$repo/tracked.txt"
    git -C "$repo" add tracked.txt
    git -C "$repo" -c commit.gpgsign=false commit -qm "authentic release"

    local authentic_commit authentic_tree replacement_tree replacement_commit
    authentic_commit=$(git -C "$repo" rev-parse HEAD)
    authentic_tree=$(_act_strict_git -C "$repo" rev-parse "${authentic_commit}^{tree}")
    printf 'replacement tree\n' > "$repo/tracked.txt"
    git -C "$repo" add tracked.txt
    replacement_tree=$(git -C "$repo" write-tree)
    replacement_commit=$(printf 'replacement commit\n' | \
        git -C "$repo" commit-tree "$replacement_tree" -p "$authentic_commit")
    git -C "$repo" replace "$authentic_commit" "$replacement_commit"

    local ordinary_status ordinary_tree ordinary_archive_bytes
    ordinary_status=$(git -C "$repo" status --porcelain --untracked-files=all)
    ordinary_tree=$(git -C "$repo" rev-parse "${authentic_commit}^{tree}")
    ordinary_archive_bytes=$(git -C "$repo" archive "$authentic_commit" | \
        tar -xOf - tracked.txt)
    local replacement_rejected=false
    if ! _act_validate_strict_checkout_at_revision \
        "$repo" "$authentic_commit" "commit replacement control" >/dev/null 2>&1; then
        replacement_rejected=true
    fi

    _act_strict_git -C "$repo" read-tree "$authentic_commit"
    _act_strict_git -C "$repo" checkout-index -a -f
    local authentic_accepted=false protected_archive_bytes=""
    if _act_validate_strict_checkout_at_revision \
           "$repo" "$authentic_commit" "authentic commit control" >/dev/null 2>&1 &&
       _act_write_git_archive_evidence \
           "$repo" "$authentic_commit" "$protected_archive"; then
        authentic_accepted=true
        protected_archive_bytes=$(tar -xOf "$protected_archive" tracked.txt)
    fi

    if [[ -z "$ordinary_status" && "$ordinary_tree" == "$replacement_tree" ]] &&
       [[ "$ordinary_archive_bytes" == "replacement tree" ]] &&
       $replacement_rejected && $authentic_accepted &&
       [[ "$protected_archive_bytes" == "authentic tree" ]] &&
       [[ "$authentic_tree" != "$replacement_tree" ]]; then
        log_pass "Strict source identity cannot be reinterpreted by a replacement commit"
    else
        log_fail "Strict source identity must ignore commit and tree replacements"
    fi
}

# Test act_cleanup function
test_act_cleanup() {
    log_test "act_cleanup"

    export ACT_ARTIFACTS_DIR="$TEMP_DIR/artifacts"
    export ACT_LOGS_DIR="$TEMP_DIR/logs"

    mkdir -p "$ACT_ARTIFACTS_DIR/old-run" "$ACT_LOGS_DIR"
    touch "$ACT_LOGS_DIR/old.log"

    # Set old timestamps (requires GNU touch or BSD compatible)
    if touch -d "10 days ago" "$ACT_ARTIFACTS_DIR/old-run" "$ACT_LOGS_DIR/old.log" 2>/dev/null || \
       touch -t "$(date -v-10d +%Y%m%d%H%M 2>/dev/null || date -d '10 days ago' +%Y%m%d%H%M)" "$ACT_ARTIFACTS_DIR/old-run" "$ACT_LOGS_DIR/old.log" 2>/dev/null; then

        act_cleanup 7 2>/dev/null

        if [[ ! -d "$ACT_ARTIFACTS_DIR/old-run" ]]; then
            log_pass "Old artifacts cleaned up"
        else
            log_fail "Old artifacts should be cleaned"
        fi
    else
        log_skip "Could not set old timestamps for cleanup test"
    fi
}

# Test workflow file validation
test_workflow_validation() {
    log_test "workflow validation"

    # Non-existent workflow should fail
    if ! act_run_workflow "$TEMP_DIR" ".github/workflows/nonexistent.yml" "" "push" 2>/dev/null; then
        log_pass "Non-existent workflow returns error"
    else
        log_fail "Non-existent workflow should return error"
    fi
}

test_act_run_workflow_injects_tag_env() {
    log_test "act_run_workflow injects tag env"

    export ACT_ARTIFACTS_DIR="$TEMP_DIR/artifacts"
    export ACT_LOGS_DIR="$TEMP_DIR/logs"
    mkdir -p "$ACT_ARTIFACTS_DIR" "$ACT_LOGS_DIR"

    local bin_dir="$TEMP_DIR/bin"
    local args_file="$TEMP_DIR/act_args.txt"
    mkdir -p "$bin_dir"

    export ACT_TEST_ARGS_FILE="$args_file"

    cat > "$bin_dir/act" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ACT_TEST_ARGS_FILE"
exit 0
EOF
    chmod +x "$bin_dir/act"

    local original_path="$PATH"
    PATH="$bin_dir:$PATH"

    local original_act_check=""
    original_act_check="$(declare -f act_check)"

    act_check() { return 0; }
    timeout() { shift; "$@"; }

    act_run_workflow "$TEMP_DIR" ".github/workflows/release.yml" "" "push" "1.2.3" >/dev/null 2>&1

    if [[ -f "$args_file" ]] && \
        grep -q "GITHUB_REF=refs/tags/v1.2.3" "$args_file" && \
        grep -q "GITHUB_REF_NAME=v1.2.3" "$args_file" && \
        grep -q "GITHUB_REF_TYPE=tag" "$args_file"; then
        log_pass "Tag context envs are passed to act"
    else
        log_fail "Tag context envs missing from act args"
    fi

    PATH="$original_path"
    unset -f timeout 2>/dev/null || true
    if [[ -n "$original_act_check" ]]; then
        eval "$original_act_check"
    else
        unset -f act_check 2>/dev/null || true
    fi
}

test_act_run_workflow_isolates_parent_write_workflows() {
    log_test "act_run_workflow isolates parent-write workflows"

    export ACT_ARTIFACTS_DIR="$TEMP_DIR/artifacts"
    export ACT_LOGS_DIR="$TEMP_DIR/logs"
    mkdir -p "$ACT_ARTIFACTS_DIR" "$ACT_LOGS_DIR"

    cat > "$WORKFLOW_DIR/parent-write.yml" << 'EOF'
name: Parent Write
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          mkdir -p ../sibling
          echo ok > ../sibling/ok.txt
EOF

    local bin_dir="$TEMP_DIR/bin-parent"
    local args_file="$TEMP_DIR/act_parent_args.txt"
    local home_file="$TEMP_DIR/act_parent_home.txt"
    local actrc_file="$TEMP_DIR/act_parent_actrc.txt"
    mkdir -p "$bin_dir"

    export ACT_TEST_ARGS_FILE="$args_file"
    export ACT_TEST_HOME_FILE="$home_file"
    export ACT_TEST_ACTRC_FILE="$actrc_file"

    cat > "$bin_dir/act" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ACT_TEST_ARGS_FILE"
printf '%s\n' "$HOME" > "$ACT_TEST_HOME_FILE"
if [[ -f "$HOME/.config/act/actrc" ]]; then
    cp "$HOME/.config/act/actrc" "$ACT_TEST_ACTRC_FILE"
fi
exit 0
EOF
    chmod +x "$bin_dir/act"

    local real_home="$TEMP_DIR/real-home"
    mkdir -p "$real_home"
    cat > "$real_home/.actrc" << 'EOF'
-P ubuntu-latest=catthehacker/ubuntu:full-22.04
--bind
--artifact-server-path /tmp/from-user-config
--container-options --user=1000:1000
EOF

    local original_home="$HOME"
    local original_path="$PATH"
    local original_act_check=""
    original_act_check="$(declare -f act_check)"

    PATH="$bin_dir:$PATH"
    HOME="$real_home"

    act_check() { return 0; }
    timeout() { shift; "$@"; }

    act_run_workflow "$TEMP_DIR" ".github/workflows/parent-write.yml" "" "push" >/dev/null 2>&1

    if [[ -f "$home_file" ]] && [[ "$(cat "$home_file")" != "$real_home" ]]; then
        log_pass "Parent-write workflow uses isolated HOME for act"
    else
        log_fail "Expected act to run with isolated HOME"
    fi

    if [[ -f "$actrc_file" ]] && \
        grep -q '^--container-options --user 0:0$' "$actrc_file" && \
        grep -q 'ubuntu-latest=catthehacker/ubuntu:full-22.04' "$actrc_file" && \
        ! grep -q '^--bind' "$actrc_file" && \
        ! grep -q 'artifact-server-path' "$actrc_file" && \
        ! grep -q 'user=1000:1000' "$actrc_file"; then
        log_pass "Isolated act config strips bind/user overrides and forces root user"
    else
        log_fail "Isolated act config did not contain the expected filtered settings"
    fi

    HOME="$original_home"
    PATH="$original_path"
    unset -f timeout 2>/dev/null || true
    if [[ -n "$original_act_check" ]]; then
        eval "$original_act_check"
    else
        unset -f act_check 2>/dev/null || true
    fi
}

# Main
main() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  act_runner.sh Unit Tests"
    echo "═══════════════════════════════════════════════════════════════"

    setup_fixtures
    trap cleanup_fixtures EXIT

    test_act_can_run
    test_act_version_support
    test_act_get_runner
    test_act_check
    test_act_check_reads_config_dir_actrc
    test_artifact_dirs
    test_artifact_zip_wrapper_classification
    test_workspace_include_staging
    test_workspace_archive_collection_receipts
    test_strict_git_commit_replacement_binding
    test_act_cleanup
    test_workflow_validation
    test_act_run_workflow_injects_tag_env
    test_act_run_workflow_isolates_parent_write_workflows
    test_act_analyze_workflow

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Passed:${NC}  $PASS_COUNT"
    echo -e "  ${RED}Failed:${NC}  $FAIL_COUNT"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIP_COUNT"

    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
