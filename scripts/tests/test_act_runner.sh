#!/usr/bin/env bash
# test_act_runner.sh - Unit tests for act_runner.sh module
#
# Usage: ./test_act_runner.sh [--workflow-isolation-only | --worker-admission-cancel-only | --typed-companions-only]
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
    if [[ "${DSR_TEST_KEEP_TMP:-0}" == "1" ]]; then
        echo "Retained test fixture: $TEMP_DIR" >&2
    else
        rm -rf "$TEMP_DIR"
    fi
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

# Regression: the strict include check used to pipe `tar -tv` into an awk that
# exited at the first match.  With a listing larger than a pipe buffer, tar
# then died of SIGPIPE and pipefail turned a valid archive into "Strict
# workspace archive includes do not match release tree" (slb on trj, 6/8
# runs).  The member-mode lookup must survive that, yet a reader that really
# fails must still reject the archive.
test_workspace_archive_include_mode_large_listing() {
    log_test "strict include mode check survives large archive listings"
    if ! command -v yq &>/dev/null; then
        log_skip "yq not available for strict include validation"
        return
    fi

    local repo="$TEMP_DIR/include-sigpipe-repo"
    local stage="$TEMP_DIR/include-sigpipe-stage"
    local config="$TEMP_DIR/include-sigpipe.yaml"
    local archive_gz="$TEMP_DIR/include-sigpipe.tar.gz"
    local archive_xz="$TEMP_DIR/include-sigpipe.tar.xz"
    mkdir -p "$repo" "$stage/padding"
    git -C "$repo" init -q
    git -C "$repo" config user.name "DSR Test"
    git -C "$repo" config user.email "dsr-test.invalid"
    printf 'release notes\n' > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" -c commit.gpgsign=false commit -qm "include sigpipe fixture"
    local revision
    revision=$(git -C "$repo" rev-parse HEAD)
    printf 'include_files:\n  - README.md\n' > "$config"
    cp "$repo/README.md" "$stage/README.md"
    chmod 644 "$stage/README.md"

    # README.md is archived first, followed by ~300 KiB of listing, so an
    # early-exiting consumer is guaranteed to close the pipe while tar still
    # has several pipe buffers of output left to write.
    local i pad
    pad=$(printf 'p%.0s' {1..120})
    for i in $(seq 1 2000); do
        : > "$stage/padding/${pad}-$i"
    done
    COPYFILE_DISABLE=1 tar --no-xattrs -czf "$archive_gz" -C "$stage" README.md padding
    COPYFILE_DISABLE=1 tar --no-xattrs -cJf "$archive_xz" -C "$stage" README.md padding

    local listing_bytes
    listing_bytes=$(tar -tvzf "$archive_gz" | wc -c | tr -d '[:space:]')
    if [[ "$listing_bytes" -gt 262144 ]]; then
        log_pass "fixture listing ($listing_bytes bytes) exceeds several pipe buffers"
    else
        log_fail "fixture listing too small to exercise SIGPIPE ($listing_bytes bytes)"
    fi

    local ok=true
    for _ in 1 2 3 4 5; do
        _act_validate_workspace_archive_release_tree_includes \
            "$archive_gz" tar.gz "$config" "$repo" "$revision" || ok=false
        _act_validate_workspace_archive_release_tree_includes \
            "$archive_xz" tar.xz "$config" "$repo" "$revision" || ok=false
    done
    if $ok && [[ "$(_act_archive_member_mode "$archive_gz" tar.gz README.md)" == -rw-* ]] &&
       [[ -z "$(_act_archive_member_mode "$archive_gz" tar.gz MISSING.md)" ]]; then
        log_pass "large-listing archives validate on every run (no SIGPIPE false failure)"
    else
        log_fail "large-listing archive was rejected; member-mode lookup is SIGPIPE-sensitive"
    fi

    # A tar that prints a correct listing but exits non-zero is a genuine
    # reader failure and must still reject the archive.
    local shim_dir="$TEMP_DIR/include-sigpipe-failing-tar" real_tar
    real_tar=$(command -v gtar || command -v tar)
    mkdir -p "$shim_dir"
    local shim
    for shim in tar gtar; do
        printf '#!/usr/bin/env bash\ncase "${1:-}" in -tv*) "%s" "$@"; exit 2 ;; esac\nexec "%s" "$@"\n' \
            "$real_tar" "$real_tar" > "$shim_dir/$shim"
        chmod 755 "$shim_dir/$shim"
    done
    if ( PATH="$shim_dir:$PATH"; hash -r
         ! _act_archive_member_mode "$archive_gz" tar.gz README.md >/dev/null &&
         ! _act_validate_workspace_archive_release_tree_includes \
             "$archive_gz" tar.gz "$config" "$repo" "$revision" ); then
        log_pass "a failing tar listing still rejects the archive"
    else
        log_fail "a failing tar listing must not be accepted"
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

test_workspace_archive_contract_format_and_members() {
    log_test "configured workspace archive format and fixed authority members"
    if ! command -v yq &>/dev/null; then
        log_skip "yq unavailable"
        return
    fi

    local config="$TEMP_DIR/process-family.yaml"
    local root="$TEMP_DIR/process-family"
    local archive="$TEMP_DIR/process-family.tar.xz"
    mkdir -p "$root"
    cat > "$config" <<'EOF'
workspace_binaries:
  - ft
  - frankenterm-mux-server
  - frankenterm-pty-guardian
workspace_archive_files:
  darwin/arm64:
    - name: verify-components.sh
      executable: true
    - name: ft-darwin-arm64.component-manifest.json
      executable: false
archive_format:
  darwin: tar.xz
  windows: zip
include_extra_files: false
EOF
    local binary
    for binary in ft frankenterm-mux-server frankenterm-pty-guardian; do
        printf '\xcf\xfa\xed\xfe\x0c\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' \
            > "$root/$binary"
        chmod 0755 "$root/$binary"
    done
    printf '#!/bin/sh\nexit 0\n' > "$root/verify-components.sh"
    chmod 0755 "$root/verify-components.sh"
    printf '{"schema_version":"ft.atomic_component_manifest.v1"}\n' \
        > "$root/ft-darwin-arm64.component-manifest.json"
    chmod 0644 "$root/ft-darwin-arm64.component-manifest.json"

    local receipt receipts=() identity
    for binary in ft frankenterm-mux-server frankenterm-pty-guardian; do
        identity=$(_act_file_identity "$root/$binary")
        receipt=$(jq -nc --arg path "$root/$binary" \
            --arg sha256 "$(_act_sha256 "$root/$binary")" \
            --argjson size_bytes "$(_act_file_size "$root/$binary")" \
            --arg identity "$identity" \
            '{path: $path, sha256: $sha256, size_bytes: $size_bytes, identity: $identity}')
        receipts+=("$receipt")
    done
    _act_stream_workspace_tar_xz "$root" \
        ft frankenterm-mux-server frankenterm-pty-guardian \
        verify-components.sh ft-darwin-arm64.component-manifest.json > "$archive"

    if [[ "$(_act_workspace_archive_format "$config" darwin/arm64)" == "tar.xz" &&
          "$(_act_workspace_archive_format "$config" windows/amd64)" == "zip" ]] && \
       _act_validate_workspace_archive \
           "$archive" tar.xz darwin/arm64 "$config" && \
       _act_validate_workspace_archive_collection_receipts \
           "$archive" tar.xz darwin/arm64 "$config" "${receipts[@]}"; then
        log_pass "configured tar.xz carries the exact three binaries, verifier, and manifest"
    else
        log_fail "configured tar.xz process-family closure was rejected"
    fi

    printf 'extra\n' > "$root/frankenterm-gui"
    chmod 0755 "$root/frankenterm-gui"
    _act_stream_workspace_tar_xz "$root" \
        ft frankenterm-mux-server frankenterm-pty-guardian \
        verify-components.sh ft-darwin-arm64.component-manifest.json \
        frankenterm-gui > "$TEMP_DIR/process-family-extra.tar.xz"
    if ! _act_validate_workspace_archive \
        "$TEMP_DIR/process-family-extra.tar.xz" tar.xz darwin/arm64 "$config"; then
        log_pass "process-family archive rejects a sixth uncontracted member"
    else
        log_fail "process-family archive accepted an uncontracted member"
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

    if [[ "${DSR_TEST_KEEP_TMP:-0}" == "1" ]]; then
        log_skip "Cleanup mutation disabled while retaining test fixtures"
        return
    fi

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

    # A runner-image mapping keeps non-interactive act out of its first-run
    # survey (see test_act_run_workflow_requires_runner_image_mapping).
    local original_home="$HOME"
    export HOME="$TEMP_DIR/home-tag-env"
    mkdir -p "$HOME"
    printf -- '-P ubuntu-latest=catthehacker/ubuntu:act-latest\n' > "$HOME/.actrc"

    act_run_workflow "$TEMP_DIR" ".github/workflows/release.yml" "" "push" "1.2.3" >/dev/null 2>&1 </dev/null
    export HOME="$original_home"

    if [[ -f "$args_file" ]] && \
        grep -q "GITHUB_REF=refs/tags/v1.2.3" "$args_file" && \
        grep -q "GITHUB_REF_NAME=v1.2.3" "$args_file" && \
        grep -q "GITHUB_REF_TYPE=tag" "$args_file"; then
        log_pass "Tag context envs are passed to act"
    else
        log_fail "Tag context envs missing from act args"
    fi

    PATH="$original_path"
    if [[ -n "$original_act_check" ]]; then
        eval "$original_act_check"
    else
        unset -f act_check 2>/dev/null || true
    fi
}

# bd-1d26: without any runner-image mapping, act opens a first-run image
# survey that exits on EOF. A non-interactive run must fail with dependency
# exit 3 and a remediation message before launching act, while a repo-level
# -P override or an operator actrc (either location) keeps working.
test_act_run_workflow_requires_runner_image_mapping() {
    log_test "act_run_workflow fails closed without a runner image mapping"

    export ACT_ARTIFACTS_DIR="$TEMP_DIR/artifacts"
    export ACT_LOGS_DIR="$TEMP_DIR/logs"
    mkdir -p "$ACT_ARTIFACTS_DIR" "$ACT_LOGS_DIR"
    local bin_dir="$TEMP_DIR/bin-image-mapping" marker="$TEMP_DIR/image-mapping-act-ran"
    local cwd="$TEMP_DIR/image-mapping-cwd" home status results=""
    mkdir -p "$bin_dir" "$cwd"
    printf '#!/usr/bin/env bash\nprintf ran > "%s"\nexit 0\n' "$marker" > "$bin_dir/act"
    chmod +x "$bin_dir/act"

    local scenario
    for scenario in none repo-override home-actrc xdg-actrc; do
        home="$TEMP_DIR/image-mapping-home-$scenario"
        mkdir -p "$home"
        rm -f "$marker"
        case "$scenario" in
            home-actrc) printf -- '--platform ubuntu-latest=img\n' > "$home/.actrc" ;;
            xdg-actrc) mkdir -p "$home/xdg/act"; printf -- '-P ubuntu-latest=img\n' > "$home/xdg/act/actrc" ;;
        esac
        status=0
        (
            cd "$cwd" || exit 99
            PATH="$bin_dir:$PATH"
            export HOME="$home"
            unset XDG_CONFIG_HOME CI
            [[ "$scenario" == xdg-actrc ]] && export XDG_CONFIG_HOME="$home/xdg"
            act_check() { return 0; }
            if [[ "$scenario" == repo-override ]]; then
                act_run_workflow "$TEMP_DIR" ".github/workflows/release.yml" "" "push" "" \
                    -P ubuntu-latest=img
            else
                act_run_workflow "$TEMP_DIR" ".github/workflows/release.yml" "" "push" ""
            fi
        ) > "$TEMP_DIR/image-mapping-$scenario.out" 2> "$TEMP_DIR/image-mapping-$scenario.err" </dev/null || status=$?
        results+="$scenario:$status:$([[ -f "$marker" ]] && echo ran || echo skipped) "
    done

    if [[ "$results" == "none:3:skipped repo-override:0:ran home-actrc:0:ran xdg-actrc:0:ran " ]] && \
       grep -q 'act has no runner image mapping' "$TEMP_DIR/image-mapping-none.err" && \
       grep -q 'act_overrides.platform_image' "$TEMP_DIR/image-mapping-none.err" && \
       [[ ! -s "$TEMP_DIR/image-mapping-none.out" ]]; then
        log_pass "Missing mapping fails with exit 3 before act; override and both actrc locations run"
    else
        log_fail "Runner image mapping gate wrong: $results"
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
    if [[ -n "$original_act_check" ]]; then
        eval "$original_act_check"
    else
        unset -f act_check 2>/dev/null || true
    fi
}

test_concurrent_workflow_isolation() {
    log_test "Concurrent act workflows retain separate uploads, logs and receipts"
    if python3 - "$SRC_DIR/act_runner.sh" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import zipfile

module = sys.argv[1]
root = Path(tempfile.mkdtemp(prefix='dsr-workflow-isolation-'))
print('Retained workflow isolation fixture:', root, flush=True)
failures = []
checks = 0

def check(label, condition):
    global checks
    checks += 1
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    if not condition:
        failures.append(label)

# The only simulated boundary is act's Docker transport. It receives the real
# production argv and writes a real upload ZIP. Workers, timeouts, run storage,
# result sidecars, and resume receipt validation remain production code.
transport = r'''#!/usr/bin/env python3
import json, os, sys, time, zipfile
from pathlib import Path
args = sys.argv[1:]
job = args[args.index('-j') + 1]
uploads = Path(args[args.index('--artifact-server-path') + 1])
root = Path(os.environ['DSR_WORKFLOW_FIXTURE'])
home = Path(os.environ['HOME'])
config = home / '.config' / 'act' / 'actrc'
(root / (job + '.launch.json')).write_text(json.dumps({
    'job': job, 'argv': args, 'artifact_dir': str(uploads), 'home': str(home),
    'config': config.read_text() if config.exists() else ''}))
(root / (job + '.started')).write_text('started\n')
gate = 'failure.started' if job == 'success' else 'release-failure'
if job != 'retry':
    deadline = time.monotonic() + 15
    while not (root / gate).exists():
        if time.monotonic() > deadline:
            raise SystemExit('fixture barrier timed out: ' + gate)
        time.sleep(0.01)
# All jobs intentionally upload the same wrapper basename. The failing job
# writes only after the successful worker has frozen its immutable receipt.
with zipfile.ZipFile(uploads / 'artifact.zip', 'w') as archive:
    archive.writestr('tool-v1.2.3.bin', (job + ' upload bytes\n').encode())
print(job + ' workflow log', flush=True)
raise SystemExit(9 if job == 'failure' else 0)
'''

driver = r'''source "${1%/*}/config.sh"
source "$1"
act_check() { return 0; }
act_platform_uses_act() { return 0; }
act_get_job_for_target() {
    case "$2" in
        linux/amd64) printf 'success\n' ;;
        linux/arm64) printf 'failure\n' ;;
        linux/386) printf 'retry\n' ;;
    esac
}
act_get_flags() { printf '%s\n' '-P ubuntu-latest=fixture'; }
# Sibling Bash workers inherit $$, even though their BASHPID values differ.
# Freeze only the naming clock so the old timestamp+$$ collision is certain.
date() {
    if [[ "${1:-}" == +%Y%m%d-%H%M%S ]]; then
        printf '20261031-120000\n'
    else
        command date "$@"
    fi
}
ACT_REPO_WORKFLOW=workflow.yml
ACT_REPO_LOCAL_PATH=$2
run_fixture_worker() {
    local label=$1 target=$2
    printf '%s %s\n' "$$" "$BASHPID" > "$ACT_REPO_LOCAL_PATH/$label.shell-pids"
    _act_run_target_worker fixture v1.2.3 44444444-4444-4444-8444-444444444444 \
        "$target" 1 "$ACT_REPO_LOCAL_PATH/$label.worker.log" \
        "$ACT_REPO_LOCAL_PATH/$label.result.json" false null '{}' '' '' act-local release
}
run_fixture_worker success linux/amd64 &
success_pid=$!
run_fixture_worker failure linux/arm64 &
failure_pid=$!
success_status=0
failure_status=0
wait "$success_pid" || success_status=$?
wait "$failure_pid" || failure_status=$?
retry_status=0
run_fixture_worker retry linux/386 || retry_status=$?
printf '%s %s %s\n' "$success_status" "$failure_status" "$retry_status" > "$2/worker-statuses"
'''

for case in ('ordinary', 'writable-parent'):
    directory = root / case
    directory.mkdir()
    home = directory / 'operator-home'
    home.mkdir()
    (home / '.actrc').write_text('-P ubuntu-latest=fixture\n')
    binary = directory / 'act'
    binary.write_text(transport)
    binary.chmod(0o755)
    (directory / 'workflow.yml').write_text(
        'name: fixture\n# ' + ('../sibling' if case == 'writable-parent' else 'ordinary') + '\n')
    # Real worker admission resolves the repository's complete workflow plan.
    # Keep that gate active and provide each fixture job's actual owner.
    repos = directory / 'repos.d'
    repos.mkdir()
    (repos / 'fixture.yaml').write_text(
        'targets: [linux/amd64, linux/arm64, linux/386]\n'
        'act_job_map:\n  linux/amd64: success\n  linux/arm64: failure\n  linux/386: retry\n')
    env = os.environ.copy()
    env.update(PATH=str(directory) + os.pathsep + env['PATH'], HOME=str(home),
               DSR_WORKFLOW_FIXTURE=str(directory), DSR_CACHE_DIR=str(directory / 'cache'),
               DSR_CONFIG_DIR=str(directory),
               ACT_ARTIFACTS_DIR=str(directory / 'artifacts'),
               ACT_LOGS_DIR=str(directory / 'logs'), ACT_TIMEOUT='20')
    output = open(directory / 'driver.log', 'wb')
    process = subprocess.Popen(['bash', '-c', driver, '_', module, str(directory)],
                               env=env, stdout=output, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        success_file = directory / 'success.result.json'
        deadline = time.monotonic() + 12
        success = None
        while time.monotonic() < deadline:
            try:
                success = json.loads(success_file.read_text())
                break
            except (FileNotFoundError, json.JSONDecodeError):
                if process.poll() is not None:
                    break
                time.sleep(0.02)
        check(case + ': successful worker completes while peer is still running',
              success is not None and success.get('status') == 'success' and process.poll() is None)
        if success is None:
            continue
        success_archive = Path(success['artifact_dir']) / 'artifact.zip'
        success_log = Path(success['log_file'])
        frozen_upload = success_archive.read_bytes()
        frozen_log = success_log.read_bytes()
        frozen_result = success_file.read_bytes()
        (directory / 'release-failure').write_text('release\n')
        status = process.wait(timeout=12)
        results = {name: json.loads((directory / (name + '.result.json')).read_text())
                   for name in ('success', 'failure', 'retry')}
        check(case + ': success, failure and retry retain their exit statuses',
              status == 0 and (directory / 'worker-statuses').read_text().split() == ['0', '6', '0'])
        pids = [(directory / (name + '.shell-pids')).read_text().split()
                for name in ('success', 'failure')]
        check(case + ': concurrent workers share $$ but have different process identities',
              pids[0][0] == pids[1][0] and pids[0][1] != pids[1][1])
        for field in ('run_id', 'artifact_dir', 'log_file'):
            check(case + ': each invocation owns a different ' + field,
                  len({result[field] for result in results.values()}) == 3)
        check(case + ': later failed upload and retry cannot mutate successful bytes',
              success_archive.read_bytes() == frozen_upload)
        check(case + ': later failed output and retry cannot mutate successful log',
              success_log.read_bytes() == frozen_log and frozen_log == b'success workflow log\n')
        check(case + ': successful result sidecar remains immutable',
              success_file.read_bytes() == frozen_result)
        receipts = success.get('resume_artifacts', [])
        check(case + ': successful receipt names only its own frozen upload',
              len(receipts) == 1 and receipts[0]['path'] == str(success_archive) and
              receipts[0]['sha256'] == hashlib.sha256(frozen_upload).hexdigest() and
              receipts[0]['size_bytes'] == len(frozen_upload))
        reusable = subprocess.run(
            ['bash', '-c', 'source "$1"; _act_target_result_available "$(cat "$2")"',
             '_', module, str(success_file)], env=env, capture_output=True)
        check(case + ': completed success is still reusable after failed peer and retry',
              reusable.returncode == 0)
        check(case + ': failed worker does not acquire a success receipt',
              results['failure']['status'] == 'failed' and
              not results['failure'].get('resume_artifacts'))
        for name, result in results.items():
            upload = Path(result['artifact_dir']) / 'artifact.zip'
            with zipfile.ZipFile(upload) as archive:
                payload = archive.read('tool-v1.2.3.bin')
            launch = json.loads((directory / (name + '.launch.json')).read_text())
            check(case + ': ' + name + ' upload and log belong to that job',
                  payload == (name + ' upload bytes\n').encode() and
                  Path(result['log_file']).read_text() == name + ' workflow log\n' and
                  result['artifact_count'] == 1 and launch['artifact_dir'] == result['artifact_dir'])
            check(case + ': ' + name + ' keeps requested job, workflow and release tag',
                  result['job'] == name and result['workflow'] == 'workflow.yml' and
                  'GITHUB_REF=refs/tags/v1.2.3' in launch['argv'] and
                  'GITHUB_REF_NAME=v1.2.3' in launch['argv'] and
                  'GITHUB_REF_TYPE=tag' in launch['argv'])
            check(case + ': ' + name + ' owns private artifact storage and log',
                  stat.S_IMODE(Path(result['artifact_dir']).stat().st_mode) == 0o700 and
                  stat.S_IMODE(Path(result['log_file']).stat().st_mode) == 0o600)
        if case == 'writable-parent':
            launches = [json.loads((directory / (name + '.launch.json')).read_text())
                        for name in results]
            check(case + ': isolated HOME is exclusive for each workflow',
                  len({launch['home'] for launch in launches}) == 3 and
                  all(Path(launch['home']) != home for launch in launches))
            check(case + ': each isolated config contains exactly its own settings',
                  all(launch['config'].splitlines() == [
                      '-P ubuntu-latest=fixture', '--container-options --user 0:0']
                      for launch in launches))
    finally:
        # Release only this fixture's waiting transport and retire its process
        # group if an assertion/setup failure prevented normal completion.
        if not (directory / 'release-failure').exists():
            (directory / 'release-failure').write_text('release\n')
        if process.poll() is None:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=8)
        output.close()

for field in ('ACT_ARTIFACTS_DIR', 'ACT_LOGS_DIR', 'DSR_CACHE_DIR'):
    directory = root / ('blocked-' + field.lower())
    directory.mkdir()
    blocked = directory / 'occupied'
    blocked.write_bytes(b'preexisting evidence\n')
    marker = directory / 'transport-started'
    binary = directory / 'act'
    binary.write_text('#!/usr/bin/env python3\nimport os\nfrom pathlib import Path\n'
                      "Path(os.environ['DSR_WORKFLOW_MARKER']).write_text('started\\n')\n")
    binary.chmod(0o755)
    (directory / 'workflow.yml').write_text('name: fixture\n# ../sibling\n')
    env = os.environ.copy()
    env.update(PATH=str(directory) + os.pathsep + env['PATH'],
               DSR_WORKFLOW_MARKER=str(marker), DSR_CACHE_DIR=str(directory / 'cache'),
               ACT_ARTIFACTS_DIR=str(directory / 'artifacts'),
               ACT_LOGS_DIR=str(directory / 'logs'))
    env[field] = str(blocked)
    result = subprocess.run(
        ['bash', '-c', 'source "$1"; act_check() { return 0; }; '
         'act_run_workflow "$2" workflow.yml success push v1.2.3 -P ubuntu-latest=fixture',
         '_', module, str(directory)], env=env, capture_output=True, timeout=5)
    (directory / 'stderr.log').write_bytes(result.stderr)
    check(field + ': unavailable storage fails before transport and preserves existing bytes',
          result.returncode == 1 and not marker.exists() and
          blocked.read_bytes() == b'preexisting evidence\n' and
          b'Failed to allocate' in result.stderr)

(root / 'summary.json').write_text(json.dumps({'checks': checks, 'failures': failures}) + '\n')
print('Workflow isolation: %d checks, %d failures' % (checks, len(failures)), flush=True)
sys.exit(bool(failures))
PY
    then
        log_pass "Concurrent and sequential workflows preserve independent evidence"
    else
        log_fail "Workflow artifact, log or isolated HOME namespace collision"
    fi
}

test_typed_workflow_companions() {
    log_test "Actual act workers preserve typed companions and both evidence inventories"
    if python3 - "$SRC_DIR/act_runner.sh" <<'PY'
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile

module = Path(sys.argv[1])
root = Path(tempfile.mkdtemp(prefix="dsr-typed-act-"))
print("Retained typed act fixture:", root, flush=True)
checks = 0
failures = []
run_id = "44444444-4444-4444-8444-444444444444"
arches = ("amd64", "arm64")
triples = {"amd64": "x86_64-unknown-linux-gnu", "arm64": "aarch64-unknown-linux-gnu"}

def check(label, condition):
    global checks
    checks += 1
    print(("PASS " if condition else "FAIL ") + label, flush=True)
    if not condition:
        failures.append(label)

def require(label, condition):
    check(label, condition)
    if not condition:
        raise AssertionError(label + "; retained evidence: " + str(root))

def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True) + "\n")

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

for dependency in ("bash", "git", "jq", "yq", "tar", "gzip", "unzip"):
    require("fixture dependency is available: " + dependency, shutil.which(dependency) is not None)

source = root / "source"
source.mkdir()
(source / "workflow.yml").write_text("name: typed transport fixture\non: push\njobs:\n"
    "  build-amd64:\n    runs-on: ubuntu-latest\n    steps: []\n"
    "  build-arm64:\n    runs-on: ubuntu-latest\n    steps: []\n")
(source / "README").write_text("Owned synthetic workflow fixture; no compilation or payload execution.\n")
for command in (("init", "--initial-branch=main"), ("add", "README", "workflow.yml"),
                ("-c", "user.name=DSR fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"),
                ("tag", "v1.0.0")):
    subprocess.run(["git", "-C", str(source), *command], check=True, capture_output=True)
source_pin = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()

def primary(arch):
    return "typedact-1.0.0-linux-" + arch + ".tar.gz"

def compat(arch):
    return "typedact-linux-" + arch + ".tar.gz"

def metadata(arch):
    # A filename's misleading ABI token must not override declared ownership.
    return "metadata-musl-" + arch + ".json"

def runtime(arch):
    return "runtime-" + arch + ".zip"

fixtures = root / "payload-fixtures"
fixtures.mkdir()
for arch, machine in (("amd64", 62), ("arm64", 183)):
    header = bytearray(64)
    header[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", header, 16, 2, machine, 1)
    header.extend(("inert " + arch + " header fixture\n").encode())
    with tarfile.open(fixtures / primary(arch), "w:gz") as archive:
        member = tarfile.TarInfo("typedact")
        member.size, member.mode, member.mtime = len(header), 0o755, 0
        archive.addfile(member, io.BytesIO(header))
    (fixtures / metadata(arch)).write_text(json.dumps({"target": "linux/" + arch, "fixture": True}) + "\n")
    with zipfile.ZipFile(fixtures / runtime(arch), "w", zipfile.ZIP_DEFLATED) as archive:
        member = zipfile.ZipInfo("runtime/info.json")
        member.create_system = 3
        member.external_attr = (stat.S_IFREG | 0o644) << 16
        archive.writestr(member, json.dumps({"runtime": arch}).encode())
    (fixtures / (primary(arch) + ".sha256")).write_text(digest(fixtures / primary(arch)) + "  " + primary(arch) + "\n")
(fixtures / "invalid.json").write_bytes(b'{"duplicate":1,"duplicate":2}\n')
(fixtures / "invalid.zip").write_bytes(b"PK\x03\x04truncated final ZIP companion")
(fixtures / "extra.txt").write_bytes(b"unexpected workflow upload\n")

base_config = dict(tool_name="typedact", repo="owner/typedact", language="go", binary_name="typedact",
    local_path=str(source), workflow="workflow.yml", targets=["linux/" + a for a in arches],
    target_triples={"linux/" + a: [triples[a]] for a in arches},
    act_job_map={"linux/" + a: "build-" + a for a in arches},
    act_overrides=dict(platform_image="fixture/no-image-download"), archive_format="tar.gz",
    artifact_naming="${name}-${version}-${os}-${arch}", install_script_compat="${name}-${os}-${arch}",
    workspace_additional_artifacts={"linux/" + a: [dict(name=metadata(a), format="json"),
                                                  dict(name=runtime(a), format="zip")] for a in arches})

# These are the only replaced execution boundaries. The actual act argv,
# config parser, worker, wrapper admission, architecture/content validators,
# collection receipts, manifest mapper, and SLSA mapper all remain production.
transport = r'''#!/usr/bin/env python3
import json, os, stat, sys, time, zipfile
from pathlib import Path
args = sys.argv[1:]
case = Path(os.environ["DSR_TYPED_ACT_CASE"])
fd = os.open(case / "requests.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
os.write(fd, (json.dumps(args) + "\n").encode())
os.close(fd)
if args == ["--version"]:
    print("act version 0.2.86")
    raise SystemExit(0)
job = args[args.index("-j") + 1]
assert job.startswith("build-")
arch = job[len("build-"):]
uploads = Path(args[args.index("--artifact-server-path") + 1])
(case / (arch + ".launch.json")).write_text(json.dumps({"argv": args, "uploads": str(uploads)}))
if os.environ.get("DSR_TYPED_ACT_BARRIER") == "1":
    (case / (arch + ".ready")).write_text("ready\n")
    deadline = time.monotonic() + 15
    while not all((case / (a + ".ready")).exists() for a in ("amd64", "arm64")):
        if time.monotonic() > deadline:
            raise SystemExit("concurrent typed transport peer did not start")
        time.sleep(.02)
for wrapper in json.loads((case / "uploads.json").read_text())[arch]:
    destination = uploads / wrapper["name"]
    output = case / (arch + "-linked-source.zip") if wrapper.get("linked") else destination
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for item in wrapper["members"]:
            info = zipfile.ZipInfo(item["name"])
            info.create_system = 3
            info.external_attr = ((stat.S_IFLNK | 0o777) if item.get("symlink") else (stat.S_IFREG | 0o644)) << 16
            archive.writestr(info, Path(item["source"]).read_bytes())
    if wrapper.get("linked"):
        destination.symlink_to(output)
print("typed fixture uploaded " + arch, flush=True)
'''
worker = r'''source "$1" || exit $?
act_load_repo_config typedact || exit $?
status=0
_act_run_target_worker typedact v1.0.0 44444444-4444-4444-8444-444444444444 \
    "linux/$3" 1 "$2/$3.worker.log" "$2/$3.result.json" false null '{}' '' '' act-local release || status=$?
[[ ! -f "$2/$3.result.json" ]] || cat "$2/$3.result.json"
exit "$status"
'''

def make_case(label, mode="valid", change=None):
    case = root / label
    (case / "config/repos.d").mkdir(parents=True)
    (case / "home").mkdir()
    (case / "bin").mkdir()
    for name, data in (("act", transport), ("docker", '#!/bin/sh\n[ "$1" = info ] || exit 98\n')):
        (case / "bin" / name).write_text(data)
        (case / "bin" / name).chmod(0o755)
    config = copy.deepcopy(base_config)
    if change:
        change(config)
    save(case / "config/repos.d/typedact.yaml", config)
    save(case / "config/config.yaml", {})
    save(case / "config/repos.yaml", {"tools": {}})
    uploads = {}
    for arch in arches:
        def entry(name, source_name=None, **extra):
            return dict(name=name, source=str(fixtures / (source_name or Path(name).name)), **extra)
        payload = [entry("dist/" + primary(arch)), entry("dist/" + compat(arch), primary(arch)),
                   entry("dist/" + primary(arch) + ".sha256")]
        companions = [entry("reports/" + metadata(arch)), entry("assets/" + runtime(arch))]
        if mode == "no-compat":
            payload = [e for e in payload if Path(e["name"]).name != compat(arch)]
        elif mode == "missing-primary":
            payload = [e for e in payload if Path(e["name"]).name != primary(arch)]
        elif mode == "missing-companion":
            companions = companions[1:]
        elif mode == "extra":
            companions.append(entry("extra.txt"))
        elif mode == "foreign":
            other = "arm64" if arch == "amd64" else "amd64"
            companions.append(entry(primary(other)))
        elif mode == "duplicate":
            companions.append(entry("another/" + primary(arch)))
        elif mode == "case-alias":
            payload.append(entry("other/" + metadata(arch).upper(), metadata(arch)))
        elif mode == "invalid-json":
            companions[0]["source"] = str(fixtures / "invalid.json")
        elif mode == "invalid-zip":
            companions[1]["source"] = str(fixtures / "invalid.zip")
        elif mode == "invalid-checksum":
            payload[2]["source"] = str(fixtures / "extra.txt")
        elif mode in ("wrong-machine", "wrong-compat-machine"):
            payload[0 if mode == "wrong-machine" else 1]["source"] = str(fixtures / primary("arm64" if arch == "amd64" else "amd64"))
        elif mode == "traversal":
            companions[0]["name"] = "../escaped-" + metadata(arch)
        elif mode == "member-symlink":
            companions[0]["symlink"] = True
        uploads[arch] = [dict(name="primary-upload.zip", members=payload),
                         dict(name="companion-upload.zip", members=companions)]
        if mode in ("colliding-wrapper-name", "missing-inner-zip"):
            uploads[arch] = [dict(name="primary-upload.zip", members=payload),
                             dict(name="metadata-upload.zip", members=companions[:1]),
                             dict(name=runtime(arch), members=companions[1:])]
            if mode == "missing-inner-zip":
                uploads[arch][2]["members"] = [entry("extra.txt")]
        if mode == "wrapper-symlink":
            uploads[arch][1]["linked"] = True
    save(case / "uploads.json", uploads)
    return case

def environment(case, concurrent=False):
    env = os.environ.copy()
    env.update(PATH=str(case / "bin") + os.pathsep + env["PATH"], HOME=str(case / "home"),
        XDG_CONFIG_HOME=str(case / "home/.config"), DSR_TYPED_ACT_CASE=str(case),
        DSR_TYPED_ACT_BARRIER="1" if concurrent else "0", DSR_CONFIG_DIR=str(case / "config"),
        DSR_CONFIG_FILE=str(case / "config/config.yaml"), DSR_REPOS_FILE=str(case / "config/repos.yaml"),
        DSR_HOSTS_FILE=str(case / "config/hosts.yaml"), DSR_STATE_DIR=str(case / "state"),
        DSR_CACHE_DIR=str(case / "cache"), ACT_ARTIFACTS_DIR=str(case / "artifacts"),
        ACT_LOGS_DIR=str(case / "logs"), ACT_TIMEOUT="25", NO_COLOR="1")
    return env

def launch(case, arch="amd64", concurrent=False):
    return subprocess.Popen(["bash", "-c", worker, "_", str(module), str(case), arch],
        env=environment(case, concurrent), stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)

def finish(case, arch, process):
    try:
        out, err = process.communicate(timeout=40)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        out, err = process.communicate(timeout=10)
        raise AssertionError("typed act worker timed out: " + str(case))
    (case / (arch + ".stdout")).write_bytes(out)
    (case / (arch + ".stderr")).write_bytes(err)
    result_path = case / (arch + ".result.json")
    return process.returncode, json.loads(result_path.read_text()) if result_path.is_file() else {}

def reusable(case, result):
    return subprocess.run(["bash", "-c", 'source "$1"; _act_target_result_available "$2"',
        "_", str(module), json.dumps(result)], env=environment(case), capture_output=True, timeout=10).returncode == 0

def manifest(case, results, label, expected=0):
    wanted = sorted(r["platform"] for r in results)
    inventory = dict(tool="typedact", version="v1.0.0", run_id=run_id, git_sha=source_pin, git_ref="v1.0.0",
        requested_targets=wanted, status="success", summary=dict(total=len(results), success=len(results), failed=0),
        build_purpose="release", publishable=True, source_dependencies=[], targets=results)
    selected, output = case / (label + "-inventory.json"), case / (label + "-manifest.json")
    save(selected, inventory)
    command = r'''source "$1" || exit $?
act_load_repo_config typedact || exit $?
act_generate_manifest "$(cat "$2")" "$3"
'''
    completed = subprocess.run(["bash", "-c", command, "_", str(module), str(selected), str(output)],
        env=environment(case), capture_output=True, timeout=30)
    (case / (label + "-manifest.stderr")).write_bytes(completed.stderr)
    check(label + ": real manifest admission has expected outcome",
          completed.returncode == expected and (output.is_file() if expected == 0 else not output.exists()))
    return output if completed.returncode == 0 else None

case = make_case("concurrent-success")
processes = {a: launch(case, a, True) for a in arches}
results = {}
try:
    for arch, process in processes.items():
        status, result = finish(case, arch, process)
        require(arch + ": actual concurrent worker accepts the complete typed output", status == 0 and result.get("status") == "success")
        results[arch] = result
finally:
    for process in processes.values():
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=10)

for arch, result in results.items():
    wrappers, payload = Path(result["workflow_artifact_dir"]), Path(result["workflow_payload_dir"])
    expected_payloads = {primary(arch), compat(arch), primary(arch) + ".sha256", metadata(arch), runtime(arch)}
    check(arch + ": bridge owns an exact flat materialized payload inventory",
          not result.get("artifact_dir") and {p.name for p in payload.iterdir()} == expected_payloads and
          all(p.is_file() and not p.is_symlink() for p in payload.iterdir()))
    check(arch + ": authoritative primaries do not duplicate typed companions",
          {Path(p).name for p in result["artifact_paths"]} == {primary(arch), compat(arch), primary(arch) + ".sha256"} and
          len(result["artifact_paths"]) == 3 and len(result["additional_artifacts"]) == 2 and
          {Path(r["path"]).name for r in result["additional_artifacts"]} == {metadata(arch), runtime(arch)})
    check(arch + ": final ZIP companion survives as exact bytes instead of being unwrapped",
          (payload / runtime(arch)).read_bytes() == (fixtures / runtime(arch)).read_bytes() and
          not (payload / "info.json").exists())
    check(arch + ": unversioned misleading-ABI JSON is preserved under its exact declared name",
          (payload / metadata(arch)).read_bytes() == (fixtures / metadata(arch)).read_bytes())
    actual_paths = {str(p) for directory in (wrappers, payload) for p in directory.rglob("*") if p.is_file()}
    receipts = result.get("resume_artifacts", [])
    check(arch + ": completion receipts bind every original wrapper and materialized payload",
          {r["path"] for r in receipts} == actual_paths and len(receipts) == len(actual_paths) and
          all(r["sha256"] == digest(Path(r["path"])) and r["size_bytes"] == Path(r["path"]).stat().st_size for r in receipts))
    check(arch + ": completed worker is reusable with both inventories intact", reusable(case, result))
    check(arch + ": ordinary JSON object key reordering preserves valid receipt semantics",
          reusable(case, json.loads(json.dumps(result, sort_keys=True))))
    launch_record = json.loads((case / (arch + ".launch.json")).read_text())
    check(arch + ": actual act subprocess retains target job, tag, and private upload directory",
          launch_record["uploads"] == str(wrappers) and "build-" + arch in launch_record["argv"] and
          "GITHUB_REF=refs/tags/v1.0.0" in launch_record["argv"])
check("concurrent targets retain separate wrapper and payload directories",
      all(len({results[a][field] for a in arches}) == 2 for field in ("workflow_artifact_dir", "workflow_payload_dir", "log_file")))
output = manifest(case, list(results.values()), "complete")
require("complete typed workflow manifest exists", output is not None)
records = json.loads(output.read_text())["artifacts"]
expected_names = {name for a in arches for name in (primary(a), compat(a), metadata(a), runtime(a))}
check("manifest includes every primary and typed companion exactly once, without transport ZIPs",
      {r["name"] for r in records} == expected_names and len(records) == len(expected_names))
for arch in arches:
    own = [r for r in records if r["name"] in (primary(arch), compat(arch), metadata(arch), runtime(arch))]
    check(arch + ": manifest uses configured GNU ownership despite companion musl filename",
          len(own) == 4 and all(r["target"] == "linux/" + arch and r["target_triple"] == triples[arch] for r in own))
    check(arch + ": manifest hashes exact materialized final ZIP and JSON bodies",
          all(r["sha256"] == digest(Path(results[arch]["workflow_payload_dir"]) / r["name"]) for r in own) and
          next(r for r in own if r["name"] == runtime(arch))["archive_format"] == "zip")
proof = case / "complete.intoto.jsonl"
with proof.open("wb") as out:
    statement_result = subprocess.run(["bash", "-c", 'source "$1/slsa.sh"; _slsa_manifest_statement "$2" owner/typedact dsr:typed-act-fixture',
        "_", str(module.parent), str(output)], stdout=out, stderr=subprocess.PIPE, env=environment(case), timeout=20)
(case / "proof.stderr").write_bytes(statement_result.stderr)
require("production SLSA mapper accepts complete typed workflow manifest", statement_result.returncode == 0)
statement = json.loads(proof.read_text())
check("SLSA subjects bind each complete payload digest exactly once",
      {s["name"]: s["digest"]["sha256"] for s in statement["subject"]} == {r["name"]: r["sha256"] for r in records} and
      len(statement["subject"]) == len(records))
check("SLSA preserves platform ownership and binds the manifest containing explicit GNU triples",
      {r["name"]: r["target"] for r in statement["dsr_evidence"]["artifacts"]} == {r["name"]: r["target"] for r in records} and
      statement["dsr_evidence"]["manifest_sha256"] == digest(output) and
      statement["predicate"]["runDetails"]["byproducts"][0]["digest"]["sha256"] == digest(output))

# Recheck real resume and manifest admission after mutations of either complete
# directory. Restore private evidence through renames; retain every adversarial
# object, including links, instead of deleting failed fixtures.
result = results["amd64"]
for index, mutation in enumerate(("wrapper-bytes", "wrapper-added", "wrapper-missing", "wrapper-link", "wrapper-dir-link",
                                  "payload-bytes", "payload-added", "payload-missing", "payload-link", "payload-dir-link")):
    wrappers, payload = Path(result["workflow_artifact_dir"]), Path(result["workflow_payload_dir"])
    directory = wrappers if mutation.startswith("wrapper") else payload
    selected = wrappers / "primary-upload.zip" if mutation.startswith("wrapper") else payload / metadata("amd64")
    held = case / ("held-" + mutation)
    if mutation.endswith("bytes"):
        original = selected.read_bytes()
        selected.write_bytes(original + b"same inode, changed evidence\n")
        restore = lambda p=selected, data=original: p.write_bytes(data)
    elif mutation.endswith("added"):
        selected = directory / ("unlisted.zip" if mutation.startswith("wrapper") else "unlisted.json")
        selected.write_bytes((fixtures / runtime("amd64")).read_bytes())
        restore = lambda p=selected, h=held: p.rename(h)
    elif mutation.endswith("missing"):
        selected.rename(held)
        restore = lambda p=selected, h=held: h.rename(p)
    else:
        if mutation.endswith("dir-link"):
            selected = directory
        selected.rename(held)
        selected.symlink_to(held, target_is_directory=held.is_dir())
        def restore(p=selected, h=held):
            p.rename(Path(str(h) + "-link"))
            h.rename(p)
    try:
        check(mutation + ": frozen worker cannot be resumed", not reusable(case, result))
        manifest(case, list(results.values()), "drift-" + str(index), 4)
    finally:
        restore()
    check(mutation + ": exact evidence restoration restores availability", reusable(case, result))

optional_case = make_case("optional-compat", "no-compat")
status, optional = finish(optional_case, "amd64", launch(optional_case))
check("configured compatibility primary remains optional", status == 0 and optional.get("status") == "success" and
      compat("amd64") not in {Path(p).name for p in optional.get("artifact_paths", [])})

named_case = make_case("colliding-wrapper-name", "colliding-wrapper-name")
status, named = finish(named_case, "amd64", launch(named_case))
require("transport wrapper may share the final ZIP companion's basename", status == 0 and named.get("status") == "success")
check("colliding wrapper name publishes exact inner ZIP bytes, never the transport container",
      (Path(named["workflow_payload_dir"]) / runtime("amd64")).read_bytes() == (fixtures / runtime("amd64")).read_bytes() and
      (Path(named["workflow_payload_dir"]) / runtime("amd64")).read_bytes() !=
      (Path(named["workflow_artifact_dir"]) / runtime("amd64")).read_bytes())
named_manifest = manifest(named_case, [named], "colliding-wrapper-name")
check("manifest retains the inner companion ZIP digest after colliding wrapper-name admission",
      named_manifest is not None and any(r["name"] == runtime("amd64") and r["sha256"] == digest(fixtures / runtime("amd64"))
                                        for r in json.loads(named_manifest.read_text())["artifacts"]))

for kind in ("wrapper", "payload"):
    linked_case = make_case("retained-" + kind + "-hardlink")
    status, linked = finish(linked_case, "amd64", launch(linked_case))
    require(kind + " hardlink control starts with an accepted actual worker", status == 0 and linked.get("status") == "success")
    selected = (Path(linked["workflow_artifact_dir"]) / "primary-upload.zip" if kind == "wrapper" else
                Path(linked["workflow_payload_dir"]) / metadata("amd64"))
    frozen = (selected.stat().st_ino, digest(selected), selected.stat().st_size)
    os.link(selected, linked_case / "external-hardlink")
    check(kind + " hardlink changes link count while retaining every frozen byte and file identity",
          selected.stat().st_nlink == 2 and frozen == (selected.stat().st_ino, digest(selected), selected.stat().st_size))
    check(kind + " hardlink blocks resume even without a byte change", not reusable(linked_case, linked))
    manifest(linked_case, [linked], "hardlink", 4)

for mode in ("missing-primary", "missing-companion", "extra", "foreign", "duplicate", "case-alias", "invalid-json", "invalid-zip", "invalid-checksum",
             "wrong-machine", "wrong-compat-machine", "traversal", "member-symlink", "wrapper-symlink", "missing-inner-zip"):
    rejected = make_case("reject-" + mode, mode)
    status, refused = finish(rejected, "amd64", launch(rejected))
    check(mode + ": invalid actual upload fails worker publication",
          status != 0 and refused.get("status") not in ("success", "ok", "passed") and not refused.get("resume_artifacts"))
    check(mode + ": test reached the real act subprocess without escaping its upload boundary",
          (rejected / "amd64.launch.json").is_file() and not list(root.rglob("escaped-*.json")))

def share_job_with_untyped_peer(config):
    config["act_job_map"]["linux/arm64"] = "build-amd64"
    config["workspace_additional_artifacts"]["linux/arm64"] = []

for label, change in (
    ("multiple-act-variants", lambda c: c["target_triples"]["linux/amd64"].append("x86_64-unknown-linux-musl")),
    ("nonselected-act-variants", lambda c: c["target_triples"]["linux/arm64"].append("aarch64-unknown-linux-musl")),
    ("ambiguous-primary-owner", lambda c: c.update(artifact_naming="${name}-${version}", install_script_compat="${name}")),
    ("shared-act-job", lambda c: c["act_job_map"].update({"linux/arm64": "build-amd64"})),
    ("shared-act-job-untyped-peer", share_job_with_untyped_peer),
    ("companion-primary-collision", lambda c: c["workspace_additional_artifacts"]["linux/arm64"].append(
        dict(name=primary("amd64"), format="tar.gz"))),
):
    rejected = make_case("preflight-" + label, change=change)
    status, refused = finish(rejected, "amd64", launch(rejected))
    check(label + ": invalid entire ownership plan rejects before any act invocation",
          status == 4 and not (rejected / "requests.jsonl").exists() and not refused.get("resume_artifacts"))

save(root / "summary.json", dict(checks=checks, failures=failures))
print("Typed act companions: %d checks, %d failures" % (checks, len(failures)), flush=True)
sys.exit(bool(failures))
PY
    then
        log_pass "Actual typed workflow workers preserve complete release and resume evidence"
    else
        log_fail "Typed workflow companion admission, publication or resume failed"
    fi
}

test_timeout_descendant_cancellation() {
    log_test "Real timeout descendant cancellation"
    if python3 - "$SRC_DIR/act_runner.sh" <<'PY'
import os
import signal
import subprocess
import sys
import tempfile
import time

module = sys.argv[1]
root = tempfile.mkdtemp(prefix="dsr-timeout-cancellation-")
print("retained timeout fixture:", root)
for case, seconds in (("cancel", 30), ("deadline", 1)):
    marker = os.path.join(root, case + ".pid")
    script = '''source "$1"
_act_run_with_timeout "$2" bash -c 'sleep 30 & echo $! > "$1"; wait' _ "$3"
'''
    wrapper = subprocess.Popen(
        ["bash", "-c", script, "_", module, str(seconds), marker],
        start_new_session=True,
    )
    child = None
    group = None
    try:
        for _ in range(100):
            if os.path.exists(marker) and os.path.getsize(marker):
                child = int(open(marker).read())
                break
            time.sleep(0.02)
        assert child is not None, "timeout child did not start"
        group = os.getpgid(child)
        assert group != wrapper.pid, "exercise timeout's nested process group"
        if case == "cancel":
            os.killpg(wrapper.pid, signal.SIGTERM)
        status = wrapper.wait(timeout=5)
        assert status in ((-signal.SIGTERM, 143) if case == "cancel" else (124,)), (case, status)
        for _ in range(100):
            state = subprocess.run(
                ["ps", "-o", "stat=", "-p", str(child)],
                capture_output=True, text=True,
            ).stdout.strip()
            if not state or state.startswith("Z"):
                break
            time.sleep(0.02)
        else:
            raise AssertionError(case + " left a running descendant")
    finally:
        # These process groups belong only to this newly spawned fixture.
        for owned in (wrapper.pid, group):
            if owned is not None:
                try:
                    os.killpg(owned, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        wrapper.wait(timeout=5)
result = subprocess.run(
    ["bash", "-c", 'source "$1"; _act_run_with_timeout 5 cat', "_", module],
    input="stdin remains available\n", text=True, capture_output=True,
)
assert result.returncode == 0 and result.stdout == "stdin remains available\n", result
result = subprocess.run(
    ["bash", "-c", 'source "$1"; _act_run_with_timeout 5 bash -c "exit 7"', "_", module]
)
assert result.returncode == 7, result.returncode
PY
    then
        log_pass "cancellation and deadline drain descendants; stdin and exit status survive"
    else
        log_fail "timeout subprocess lifetime regression"
    fi
}

test_timeout_owned_groups() {
    log_test "Real timeout groups retain descendants until cleanup"
    if python3 - "${DSR_TEST_ACT_RUNNER:-$SRC_DIR/act_runner.sh}" <<'PY'
import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

module = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix='dsr-timeout-owned-groups-'))
print('Retained timeout ownership fixture: ' + str(root), flush=True)
checks = failures = 0
if sys.platform.startswith('linux'):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'PR_SET_CHILD_SUBREAPER')


def check(label, valid):
    global checks, failures
    checks += 1
    failures += not valid
    print(('PASS: ' if valid else 'FAIL: ') + label, flush=True)


def alive(pid):
    state = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)],
                           capture_output=True, text=True).stdout.strip()
    return bool(state and not state.startswith('Z'))


def until(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def fixture_signals():
    # Bash cannot trap a signal that the invoking runtime ignored on entry.
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGHUP, signal.SIG_DFL)


probe = root / 'probe.py'
probe.write_text(r'''import json, os, pathlib, signal, subprocess, sys, time
case = pathlib.Path(sys.argv[1])
def alive(pid):
    state = subprocess.run(['ps','-o','stat=','-p',str(pid)],
                           capture_output=True,text=True).stdout.strip()
    return bool(state and not state.startswith('Z'))
if sys.argv[2] == 'child':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    (case / 'descendant.json').write_text(json.dumps(dict(pid=os.getpid(),pgid=os.getpgrp())))
    while True:
        time.sleep(0.05)
else:
    child=json.loads((case/'descendant.json').read_text())['pid']
    leader=int((case/'leader.pid').read_text())
    (case/'released.json').write_text(json.dumps(dict(alive=[p for p in (child,leader) if alive(p)])))
''')
leader = root / 'leader.bash'
leader.write_text(r'''set -uo pipefail
case_dir="$1" probe="$2" mode="$3"
printf '%s\n' "$BASHPID" > "$case_dir/leader.pid"
if [[ "$mode" == resistant_deadline ]]; then trap '' TERM HUP
else trap 'exit 17' TERM HUP; fi
python3 "$probe" "$case_dir" child &
child=$!
while [[ ! -s "$case_dir/descendant.json" ]]; do sleep 0.01; done
if [[ "$mode" == completed || "$mode" == worker_completed ]]; then exit 17; fi
wait "$child"
''')
driver = root / 'driver.bash'
driver.write_text(r'''set -uo pipefail
source "$1" || exit 90
case_dir="$2" mode="$3" probe="$4" leader="$5"
ACT_LOGS_DIR="$case_dir/logs"
mkdir "$ACT_LOGS_DIR"
seconds=30
[[ "$mode" != *deadline ]] || seconds=1
if [[ "$mode" == worker_* ]]; then
    act_platform_uses_act() { return 0; }
    selector_acquire_slot() { printf '%s\n' "$BASHPID" > "$case_dir/acquired"; }
    selector_release_slot() { python3 "$probe" "$case_dir" release; }
    _act_build_orchestration_target() {
        local status=0
        _act_run_with_timeout "$seconds" bash "$leader" "$case_dir" "$probe" "$mode" || status=$?
        jq -nc --argjson status "$status" \
            '{platform:"linux/amd64",host:"act-local",status:"failed",exit_code:$status,error:"fixture backend"}'
        return "$status"
    }
    _act_run_target_worker tool v1.0.0 run linux/amd64 1 \
        "$case_dir/attempt.log" "$case_dir/attempt.json" false '{}' '{}' '' '' act-local release
else
    # This driver must keep waiting for its managed helper when we signal the
    # whole invocation group; only the helper owns the cancellation result.
    trap ':' INT TERM HUP
    status=0
    _act_run_with_timeout "$seconds" bash "$leader" "$case_dir" "$probe" "$mode" || status=$?
    exit "$status"
fi
''')
sentinel = subprocess.Popen(['sleep', '90'], start_new_session=True)
try:
    for mode, expected in (('completed', 17), ('deadline', 124),
                           ('resistant_deadline', 137), ('cancel', 143), ('interrupt', 130),
                           ('hangup', 129), ('wrapper_lost', 137),
                           ('worker_cancel', 130), ('worker_deadline', 124),
                           ('worker_completed', 17)):
        case = root / mode
        case.mkdir()
        process = None
        child = None
        group = None
        with (case / 'transcript.log').open('w') as log:
            started = time.monotonic()
            try:
                process = subprocess.Popen(['bash', str(driver), str(module), str(case),
                                            mode, str(probe), str(leader)],
                                           stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                           start_new_session=True, preexec_fn=fixture_signals)
                if not until(lambda: (case / 'descendant.json').exists() and
                             (case / 'descendant.json').stat().st_size > 0):
                    raise RuntimeError('command descendant did not start')
                owned = json.loads((case / 'descendant.json').read_text())
                child, group = owned['pid'], owned['pgid']
                check(mode + ': exercise an owned nested group',
                      group != process.pid and os.getpgid(process.pid) == process.pid)
                if mode == 'cancel':
                    os.killpg(process.pid, signal.SIGTERM)
                elif mode == 'interrupt':
                    os.killpg(process.pid, signal.SIGINT)
                elif mode == 'hangup':
                    os.killpg(process.pid, signal.SIGHUP)
                elif mode == 'worker_cancel':
                    os.kill(process.pid, signal.SIGTERM)
                elif mode == 'wrapper_lost':
                    # The group anchor is a direct child of the managed
                    # timeout wrapper. Kill that exact parent, not a PID found
                    # by name, to exercise the parent-lifetime channel.
                    owner = int(subprocess.check_output(
                        ['ps', '-o', 'ppid=', '-p', str(group)], text=True).strip())
                    check('lost wrapper belongs to this invocation',
                          owner != process.pid and os.getpgid(owner) == process.pid)
                    os.kill(owner, signal.SIGKILL)
                status = process.wait(timeout=12)
                check(mode + ': preserve actual exit status ' + str(expected), status == expected)
                drained = until(lambda: not alive(child), 4) if mode == 'wrapper_lost' else not alive(child)
                check(mode + ': no running descendant after managed completion', drained)
                check(mode + ': cleanup is bounded', time.monotonic() - started < 10)
                if mode.startswith('worker_'):
                    receipt = json.loads((case / 'attempt.json').read_text())
                    released = json.loads((case / 'released.json').read_text())
                    check(mode + ': slot release follows descendant cleanup', released['alive'] == [])
                    check(mode + ': immutable receipt records actual failed attempt',
                          receipt.get('status') == 'failed' and receipt.get('exit_code') == expected and
                          receipt.get('platform') == 'linux/amd64' and not receipt.get('resume_artifacts'))
                check(mode + ': unrelated process survives', sentinel.poll() is None)
            except Exception as error:
                check(mode + ': ' + str(error), False)
            finally:
                # The fixture exclusively created these sessions/groups. With
                # Linux subreaping, exited anchors also stay unreusable until
                # reaped. Never search for processes by a shared program name.
                if process is not None and process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
                if child is not None and alive(child):
                    # A live, still-owned descendant keeps its process group
                    # from being reused even if its original leader exited.
                    if group is not None and os.getpgid(child) == group:
                        os.killpg(group, signal.SIGKILL)
                    else:
                        os.kill(child, signal.SIGKILL)
                while True:
                    try:
                        if os.waitpid(-1, os.WNOHANG)[0] == 0:
                            break
                    except ChildProcessError:
                        break

    io_driver = root / 'io.bash'
    io_driver.write_text(r'''set -uo pipefail
source "$1" || exit 90
case_dir="$2" monitor="$3"
[[ "$monitor" != on ]] || set -m
exec 10< "$case_dir/fd-input" 11> "$case_dir/fd-output"
coproc FOREIGN_TIMEOUT_TEST {
    IFS= read -r request
    printf 'foreign:%s\n' "$request"
    IFS= read -r acknowledged
}
foreign_pid="$FOREIGN_TIMEOUT_TEST_PID"
foreign_read="${FOREIGN_TIMEOUT_TEST[0]}" foreign_write="${FOREIGN_TIMEOUT_TEST[1]}"
before_flags="$-"
trap ':' HUP
before_trap=$(trap -p HUP)
status=0
_act_run_with_timeout 5 bash -c '
    printf "arg1=<%s> arg2=<%s> arg3=<%s>\n" "$1" "$2" "$3"
    cat
    cat <&10
    printf "fd-output\n" >&11
    printf "real-stderr\n" >&2
    exit 37' _ 'space argument' '' '$literal' || status=$?
[[ "$status" == 37 && "$before_flags" == "$-" && "$before_trap" == "$(trap -p HUP)" ]] || exit 91
printf 'intact\n' >&"$foreign_write"
IFS= read -r -u "$foreign_read" reply || exit 92
[[ "$reply" == foreign:intact ]] || exit 93
printf 'acknowledged\n' >&"$foreign_write"
wait "$foreign_pid" || exit 94
exit 37
''')
    for monitor in ('on', 'off'):
        case = root / ('streams-' + monitor)
        case.mkdir()
        (case / 'fd-input').write_text('fd-input\n')
        result = subprocess.run(['bash', str(io_driver), str(module), str(case), monitor],
                                input='real-stdin\n', text=True, capture_output=True, timeout=10,
                                preexec_fn=fixture_signals)
        (case / 'stdout').write_text(result.stdout)
        (case / 'stderr').write_text(result.stderr)
        check(monitor + ': preserve status, monitor, signal trap and foreign coprocess', result.returncode == 37)
        check(monitor + ': preserve argument boundaries and stdin/stdout',
              result.stdout == 'arg1=<space argument> arg2=<> arg3=<$literal>\nreal-stdin\nfd-input\n')
        check(monitor + ': preserve an occupied output descriptor',
              (case / 'fd-output').read_text() == 'fd-output\n')
        check(monitor + ': preserve real stderr', 'real-stderr\n' in result.stderr)
    fallback = subprocess.run(['bash', '-c', r'''source "$1"
_act_timeout_cmd() { printf ''; }
payload() { printf 'fallback:<%s>\n' "$1"; cat; return 23; }
_act_run_with_timeout 1 payload 'space argument'
''', '_', str(module)], input='fallback stdin\n', text=True, capture_output=True, timeout=5)
    check('missing timeout preserves direct function status', fallback.returncode == 23)
    check('missing timeout preserves direct function arguments and streams',
          fallback.stdout == 'fallback:<space argument>\nfallback stdin\n')
finally:
    if sentinel.poll() is None:
        sentinel.terminate()
    sentinel.wait(timeout=5)

(root / 'summary.json').write_text(json.dumps(dict(checks=checks, failures=failures)) + '\n')
print('Owned timeout groups: %d checks, %d failures' % (checks, failures), flush=True)
sys.exit(bool(failures))
PY
    then
        log_pass "timeout groups drain resistant descendants before returning or releasing slots"
    else
        log_fail "timeout group ownership regression"
    fi
}

test_workflow_process_cancellation() {
    log_test "Real workflow cancellation and bounded timeout escalation"
    if python3 - "$SRC_DIR/act_runner.sh" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

module = sys.argv[1]
root = Path(tempfile.mkdtemp(prefix='dsr-workflow-cancellation-'))
print('Retained workflow cancellation fixture:', root, flush=True)
failures = []
checks = 0

def check(label, condition):
    global checks
    checks += 1
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    if not condition:
        failures.append(label)

def running(pid):
    status = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)],
                            capture_output=True, text=True).stdout.strip()
    return bool(status) and not status.startswith('Z')

program = '''#!/usr/bin/env python3
import json, os, signal, time
from pathlib import Path
if os.environ['DSR_FIXTURE_RESIST_TERM'] == '1':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(os.environ['DSR_FIXTURE_MARKER']).write_text(json.dumps({'pid': os.getpid(), 'group': os.getpgrp()}))
with open(os.environ['DSR_FIXTURE_BEAT'], 'ab', buffering=0) as output:
    while True:
        output.write(b'x')
        time.sleep(0.02)
'''

sentinel = subprocess.Popen(['sleep', '300'], start_new_session=True)
try:
    for case, workflow, resistant, deadline, isolated in (
            ('helper-resistant-cancel', False, True, False, False),
            ('helper-resistant-deadline', False, True, True, False),
            ('workflow-cancel', True, False, False, False),
            ('workflow-isolated-cancel', True, False, False, True),
            ('workflow-resistant-cancel', True, True, False, False),
            ('workflow-resistant-deadline', True, True, True, False)):
        directory = root / case
        directory.mkdir()
        binary = directory / 'act'
        binary.write_text(program)
        binary.chmod(0o755)
        marker, heartbeat = directory / 'pid.json', directory / 'heartbeat'
        workflow_file = directory / 'workflow.yml'
        workflow_file.write_text('name: fixture\n# ' + ('../sibling' if isolated else 'ordinary') + '\n')
        # The production worker validates the complete workflow payload plan
        # before launching act. Supply a real untyped repository document so
        # these lifetime probes reach that launch through the actual gate.
        repos = directory / 'repos.d'
        repos.mkdir()
        (repos / 'fixture.yaml').write_text(
            'targets: [linux/amd64]\nact_job_map:\n  linux/amd64: fixture\n')
        env = os.environ.copy()
        env.update(PATH=str(directory) + os.pathsep + env['PATH'],
                   DSR_FIXTURE_MARKER=str(marker), DSR_FIXTURE_BEAT=str(heartbeat),
                   DSR_FIXTURE_RESIST_TERM='1' if resistant else '0',
                   DSR_CACHE_DIR=str(directory / 'cache'),
                   DSR_CONFIG_DIR=str(directory),
                   ACT_ARTIFACTS_DIR=str(directory / 'artifacts'),
                   ACT_LOGS_DIR=str(directory / 'logs'),
                   ACT_TIMEOUT='1' if deadline else '30')
        if workflow:
            script = '''source "${1%/*}/config.sh"
source "$1"
act_check() { return 0; }
act_platform_uses_act() { return 0; }
act_get_job_for_target() { printf 'fixture\\n'; }
act_get_flags() { printf '%s\\n' '-P ubuntu-latest=fixture'; }
ACT_REPO_WORKFLOW=workflow.yml
ACT_REPO_LOCAL_PATH=$2
_act_run_target_worker fixture v1 22222222-2222-4222-8222-222222222222 \\
    linux/amd64 1 "$2/worker.log" "$2/result.json" false null '{}' '' '' act-local release
'''
        else:
            script = '''source "$1"
_act_run_with_timeout "$ACT_TIMEOUT" act
'''
        output = open(directory / 'output.log', 'wb')
        process = subprocess.Popen(['bash', '-c', script, '_', module, str(directory)],
                                   env=env, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        target = None
        try:
            for _ in range(150):
                if marker.exists() and marker.stat().st_size:
                    target = json.loads(marker.read_text())
                    break
                if process.poll() is not None:
                    break
                time.sleep(0.02)
            check(case + ': real command started', target is not None)
            if target is None:
                continue
            check(case + ': timeout owns a nested group', target['group'] != process.pid)
            if not deadline:
                # This is the real orchestration worker for workflow cases;
                # helper cases model the enclosing orchestration group signal.
                if workflow:
                    process.send_signal(signal.SIGTERM)
                else:
                    os.killpg(process.pid, signal.SIGTERM)
            retired_by = time.monotonic() + 8
            while running(target['pid']) and time.monotonic() < retired_by:
                time.sleep(0.05)
            stopped = not running(target['pid'])
            check(case + ': command stops within bounded cleanup', stopped)
            if stopped:
                size = heartbeat.stat().st_size
                time.sleep(0.1)
                check(case + ': no post-cancellation work', heartbeat.stat().st_size == size)
            try:
                # The target may exit immediately, while the owning worker
                # keeps its five-second group grace before publishing a
                # receipt. Wait within the same overall cleanup deadline.
                status = process.wait(timeout=max(0.1, retired_by - time.monotonic()))
            except subprocess.TimeoutExpired:
                status = None
            if deadline:
                # GNU timeout uses 137 when its escalation kills the whole
                # group; preserve that failure rather than inventing success.
                expected = (6,) if workflow else (137,)
            else:
                expected = (130,) if workflow else (-signal.SIGTERM, 143)
            check(case + ': caller exits with the intended failure', status in expected)
            check(case + ': unrelated process remains alive', sentinel.poll() is None)
        finally:
            # Only groups with a still-live owned member are eligible. Do not
            # signal a reaped invocation's potentially reusable numeric PGID.
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if target is not None and running(target['pid']):
                try:
                    if os.getpgid(target['pid']) == target['group']:
                        os.killpg(target['group'], signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait(timeout=5)
            output.close()
finally:
    sentinel.terminate()
    sentinel.wait(timeout=5)

(root / 'summary.json').write_text(json.dumps({'checks': checks, 'failures': failures}) + '\n')
print('Workflow lifetime: %d checks, %d failures' % (checks, len(failures)), flush=True)
sys.exit(bool(failures))
PY
    then
        log_pass "Workflow cancellation reaches nested timeout groups and escalates resistant commands"
    else
        log_fail "Workflow or timeout process lifetime regression"
    fi
}

test_unix_native_build_guard() {
    log_test "Real host-side Unix build supervision"
    if python3 - "$SRC_DIR/act_runner.sh" <<'PY'
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

module = sys.argv[1]
bash = shutil.which('bash')
root = Path(tempfile.mkdtemp(prefix='dsr-unix-build-guard-'))
print('Retained native supervisor fixture:', root, flush=True)
checks = 0

def check(label, valid):
    global checks
    checks += 1
    print(('PASS: ' if valid else 'FAIL: ') + label, flush=True)
    if not valid:
        raise AssertionError(label)

def generate(name, body, deadline=20, selected_shell=None):
    source = root / (name + '.build.sh')
    source.write_text(body)
    result = subprocess.run([bash, '-c',
        'source "$1"; _act_unix_build_guard_script "$2" "$(cat "$3")" "$4"',
        '_', module, str(deadline), str(source), selected_shell or bash],
        capture_output=True, check=True)
    guard = root / (name + '.guard.sh')
    guard.write_bytes(result.stdout)
    return result.stdout

def launch(script, environment=None):
    process = subprocess.Popen([bash, '-s'], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        env=environment)
    process.stdin.write(script)
    process.stdin.close()
    process.stdin = None
    return process

def retain(name, process, stdout, stderr):
    (root / (name + '.stdout')).write_bytes(stdout)
    (root / (name + '.stderr')).write_bytes(stderr)
    (root / (name + '.exit')).write_text(str(process.returncode) + '\n')

def wait_marker(path):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if path.exists() and path.stat().st_size:
            return
        time.sleep(0.02)
    raise AssertionError('build process did not start: ' + str(path))

body = "printf 'out \\000 日本語 $()\\n'; printf 'err exact\\n' >&2; " \
       "if IFS= read -r unexpected; then exit 99; fi; exit 37"
process = launch(generate('exit-and-stdio', body))
stdout, stderr = process.communicate(timeout=8)
retain('exit-and-stdio', process, stdout, stderr)
check('ordinary nonzero exit and stdin EOF survive supervision', process.returncode == 37)
check('binary Unicode stdout and stderr are exact, without heartbeat bytes',
      stdout == 'out \0 日本語 $()\n'.encode() and stderr == b'err exact\n')

body = '#' + ('large-command ' * 14000) + '\nprintf "large-ok\\n"\n'
process = launch(generate('large-program', body))
stdout, stderr = process.communicate(timeout=8)
retain('large-program', process, stdout, stderr)
check('programs beyond the Unix single-argument limit execute unchanged',
      process.returncode == 0 and stdout == b'large-ok\n' and not stderr)

missing_environment = dict(os.environ, PATH=str(root / 'absent-runtime'))
process = launch(generate('missing-python', 'exit 99'), missing_environment)
stdout, stderr = process.communicate(timeout=5)
retain('missing-python', process, stdout, stderr)
check('missing host Python refuses before executing build work',
      process.returncode == 3 and b'requires Python 3.9+' in stderr and not stdout)

for value in ('0', '-1', '2147484', 'invalid', '1;exit 99'):
    result = subprocess.run([bash, '-c',
        'source "$1"; _act_unix_build_guard_script "$2" "exit 99"',
        '_', module, value], capture_output=True)
    check('invalid host deadline refuses: ' + value, result.returncode == 4 and not result.stdout)

heartbeat_program = '''import os,signal,sys,time
from pathlib import Path
if sys.argv[3] == 'stubborn': signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(sys.argv[1]).write_text('%d %d %d\\n' % (os.getpid(),os.getpgrp(),os.getppid()))
with open(sys.argv[2], 'ab', buffering=0) as output:
    while True:
        output.write(b'.')
        time.sleep(0.02)
'''
sentinel_marker, sentinel_beat = root / 'unrelated.pid', root / 'unrelated.beat'
sentinel = subprocess.Popen([sys.executable, '-c', heartbeat_program,
    str(sentinel_marker), str(sentinel_beat), 'ordinary'], start_new_session=True,
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    wait_marker(sentinel_marker)
    for case in ('completion', 'deadline', 'term', 'interrupt', 'hangup', 'supervisor-kill',
                 'supervisor-stop', 'stdout-loss', 'stderr-loss'):
        marker, beat = root / (case + '.pid'), root / (case + '.beat')
        command = ' '.join(shlex.quote(value) for value in (
            sys.executable, '-c', heartbeat_program, str(marker), str(beat), 'stubborn'))
        body = command + ' &\nwhile ! test -s ' + shlex.quote(str(marker)) + '; do sleep 0.02; done\n'
        body += 'exit 0\n' if case == 'completion' else 'wait\n'
        process = launch(generate(case, body, 1 if case in ('deadline', 'supervisor-stop') else 20))
        try:
            wait_marker(marker)
            pid, group, _parent = map(int, marker.read_text().split())
            check(case + ': build has a separate, owned process group',
                  group != process.pid and group != os.getpgrp() and group != sentinel.pid)
            if case in ('term', 'interrupt', 'hangup', 'supervisor-kill'):
                process.send_signal({'term': signal.SIGTERM, 'interrupt': signal.SIGINT,
                                     'hangup': signal.SIGHUP, 'supervisor-kill': signal.SIGKILL}[case])
            elif case == 'supervisor-stop':
                process.send_signal(signal.SIGSTOP)
                time.sleep(3.5)
                retired_size = beat.stat().st_size
                time.sleep(0.15)
                check('anchor enforces deadline while the supervisor is stopped',
                      beat.stat().st_size == retired_size)
                process.send_signal(signal.SIGCONT)
            elif case == 'stdout-loss':
                process.stdout.close()
                process.stdout = None
            elif case == 'stderr-loss':
                process.stderr.close()
                process.stderr = None
            stdout, stderr = process.communicate(timeout=7)
            stdout, stderr = stdout or b'', stderr or b''
            retain(case, process, stdout, stderr)
            expected = {'completion': 0, 'deadline': 124, 'term': 143, 'interrupt': 130,
                        'hangup': 129, 'supervisor-kill': -signal.SIGKILL, 'supervisor-stop': 124,
                        'stdout-loss': 129, 'stderr-loss': 129}[case]
            check(case + ': supervisor preserves the intended result', process.returncode == expected)
            retired_size = beat.stat().st_size
            sentinel_size = sentinel_beat.stat().st_size
            time.sleep(0.15)
            check(case + ': cleanup retires the TERM-resistant descendant',
                  beat.stat().st_size == retired_size)
            check(case + ': unrelated job keeps running',
                  sentinel.poll() is None and sentinel_beat.stat().st_size > sentinel_size)
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGCONT)
                process.send_signal(signal.SIGTERM)
                process.wait(timeout=5)
finally:
    sentinel.terminate()
    sentinel.wait(timeout=5)

(root / 'summary.json').write_text(json.dumps({'checks': checks, 'failures': 0}) + '\n')
print('Unix native supervisor: %d/%d checks passed' % (checks, checks), flush=True)
PY
    then
        log_pass "Host deadline, cancellation and transport loss retire only the owned build group"
    else
        log_fail "host-side Unix native build supervisor regression"
    fi
}

# Cancellation before compilation must retain a real interrupted attempt and
# release only its own capacity. The final case drives real output-conflict
# scheduling and exact-run resume; only the compiler itself is a fixture.
test_worker_admission_cancellation() {
    log_test "Worker cancellation during capacity and output-conflict waits"
    local dependency
    for dependency in python3 jq yq; do
        if ! command -v "$dependency" >/dev/null; then
            log_skip "worker admission cancellation requires $dependency"
            return
        fi
    done
    if python3 - "$PROJECT_ROOT" "${DSR_TEST_ACT_RUNNER:-$SRC_DIR/act_runner.sh}" <<'PY'
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

project, module = map(Path, sys.argv[1:])
root = Path(tempfile.mkdtemp(prefix='dsr-admission-cancel-'))
print('Retained admission cancellation fixture: ' + str(root), flush=True)
checks = 0


def check(label, valid):
    global checks
    if not valid:
        raise AssertionError(label)
    checks += 1
    print('PASS: ' + label, flush=True)


def read(path):
    return json.loads(path.read_text())


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def wait_for(process, predicate, label):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        if process.poll() is not None:
            break
        time.sleep(0.02)
    raise AssertionError(label)


def launch(case, script, phase, extra=None):
    env = dict(os.environ, DSR_ADMISSION_PROJECT=str(project), DSR_ADMISSION_MODULE=str(module),
               DSR_ADMISSION_CASE=str(case), DSR_ADMISSION_PHASE=phase,
               DSR_CONFIG_DIR=str(case / 'config'), DSR_HOSTS_FILE=str(case / 'config/hosts.yaml'),
               DSR_STATE_DIR=str(case / 'state'), ACT_REPOS_DIR=str(case / 'config/repos.d'),
               ACT_LOGS_DIR=str(case / 'logs'), ACT_ARTIFACTS_DIR=str(case / 'artifacts'),
               DSR_DISABLE_HOST_SELECTOR='1', DSR_SELECTOR_LOCK_TIMEOUT='2',
               DSR_SELECTOR_WAIT_TIMEOUT='30', DSR_SELECTOR_POLL_MAX='1', NO_COLOR='1')
    env.pop('DSR_BUILD_LOCK_HELD_BY_CALLER', None)
    env.update(extra or {})
    with open(case / (phase + '.stdout'), 'wb') as out, open(case / (phase + '.stderr'), 'wb') as err:
        return subprocess.Popen(['bash', '-c', script], env=env, stdin=subprocess.DEVNULL,
                                stdout=out, stderr=err, start_new_session=True)


def fixture(name, capacity=1):
    case = root / name
    for directory in ('config/repos.d', 'state', 'source', 'output'):
        (case / directory).mkdir(parents=True, exist_ok=True)
    (case / 'config/hosts.yaml').write_text(json.dumps({'hosts': {
        'shared': {'platform': 'linux/amd64', 'connection': 'local', 'concurrency': capacity}}}))
    return case


check('stdin isolation tests require the actual null device', stat.S_ISCHR(os.stat(os.devnull).st_mode))
holder_script = r'''
source "$DSR_ADMISSION_PROJECT/src/host_selector.sh"
selector_acquire_slot shared unrelated || exit 1
trap 'selector_release_slot shared unrelated' EXIT
trap 'exit 0' INT TERM
: > "$DSR_ADMISSION_CASE/holder.ready"
while :; do sleep 0.05; done
'''
worker_script = r'''
source "$DSR_ADMISSION_PROJECT/src/host_selector.sh"
source "$DSR_ADMISSION_MODULE"
act_platform_uses_act() { return 0; }
_act_build_orchestration_target() {
    : > "$DSR_ADMISSION_CASE/unexpected-build"
    cat > "$DSR_ADMISSION_CASE/unexpected.stdin"
    return 99
}
if [[ "$DSR_ADMISSION_PHASE" == waiting ]]; then
    # Observe the real selector's first capacity backoff, after its locked
    # attempt found the holder. Do not substitute the lease or its result.
    sleep() { : > "$DSR_ADMISSION_CASE/worker.ready"; command sleep "$@"; }
else
    # The real lease has been atomically granted, but acquire has not returned.
    _sel_log_ok() {
        : > "$DSR_ADMISSION_CASE/worker.ready"
        while :; do command sleep 0.05; done
    }
fi
_act_run_target_worker fixture 1.0.0 55555555-5555-4555-8555-555555555555 \
    linux/amd64 1 "$DSR_ADMISSION_CASE/worker.log" "$DSR_ADMISSION_CASE/result.json" \
    false null '{}' '' '' shared release
'''
for mode in ('waiting', 'granted'):
    case = fixture('capacity-' + mode)
    (case / 'worker.log').touch()
    holder = worker = None
    locks = case / 'state/selector/locks/shared'
    try:
        if mode == 'waiting':
            holder = launch(case, holder_script, 'holder')
            wait_for(holder, lambda: (case / 'holder.ready').exists(), 'capacity holder did not start')
            retained_holder = (locks / 'unrelated.lock').read_bytes()
        worker = launch(case, worker_script, mode)
        wait_for(worker, lambda: (case / 'worker.ready').exists(), 'worker did not reach ' + mode)
        own_slot = locks / '55555555-5555-4555-8555-555555555555-linux-amd64-attempt-1.lock'
        check(mode + ': the barrier observes the intended real lease state', own_slot.exists() == (mode == 'granted'))
        worker.send_signal(signal.SIGTERM)
        check(mode + ': interrupted admission preserves exit 130', worker.wait(timeout=8) == 130)
        check(mode + ': cancellation retains an immutable attempt receipt',
              (case / 'result.json').is_file() and read(case / 'result.json')['exit_code'] == 130 and
              read(case / 'result.json')['status'] == 'failed' and
              read(case / 'result.json')['task_key'] == 'linux/amd64')
        check(mode + ': capacity admission never starts compilation', not (case / 'unexpected-build').exists())
        check(mode + ': cancellation leaves no owned capacity lease', not own_slot.exists())
        if holder is not None:
            check('waiting: cancellation preserves the live unrelated holder and its exact lease',
                  holder.poll() is None and (locks / 'unrelated.lock').read_bytes() == retained_holder)
    finally:
        stop(worker)
        stop(holder)

# A failed immutable-result write must release the real worker lease before
# returning from the function: an EXIT trap runs after its locals unwind.
# Keep a peer alive so garbage collection cannot disguise ownership mistakes.
case = fixture('receipt-write-failure', capacity=2)
(case / 'result.json').mkdir()
receipt_failure_script = r'''
source "$DSR_ADMISSION_PROJECT/src/host_selector.sh"
source "$DSR_ADMISSION_MODULE"
act_platform_uses_act() { return 0; }
_act_build_orchestration_target() {
    cat "$DSR_ADMISSION_CASE/state/selector/locks/shared/55555555-5555-4555-8555-555555555555-linux-amd64-attempt-1.lock" \
        > "$DSR_ADMISSION_CASE/acquired-lease.json" || return 99
    printf '%s\n' '{"platform":"linux/amd64","status":"failed","exit_code":9,"error":"deliberate build failure before receipt write"}'
    return 9
}
_act_run_target_worker fixture 1.0.0 55555555-5555-4555-8555-555555555555 \
    linux/amd64 1 "$DSR_ADMISSION_CASE/worker.log" "$DSR_ADMISSION_CASE/result.json" \
    false null '{}' '' '' shared release
'''
holder = worker = None
locks = case / 'state/selector/locks/shared'
try:
    holder = launch(case, holder_script, 'holder')
    wait_for(holder, lambda: (case / 'holder.ready').exists(), 'receipt-failure peer did not start')
    retained_holder = (locks / 'unrelated.lock').read_bytes()
    worker = launch(case, receipt_failure_script, 'receipt-failure')
    check('receipt failure: immutable-result write failure remains nonzero', worker.wait(timeout=10) == 4)
    check('receipt failure: target ran under a genuine owned capacity lease',
          read(case / 'acquired-lease.json')['pid'] == worker.pid and
          b'deliberate build failure before receipt write' in (case / 'worker.log').read_bytes())
    own_slot = locks / '55555555-5555-4555-8555-555555555555-linux-amd64-attempt-1.lock'
    check('receipt failure: failed publication releases the worker lease', not own_slot.exists())
    check('receipt failure: failure preserves the live peer and its exact lease',
          holder.poll() is None and (locks / 'unrelated.lock').read_bytes() == retained_holder)
    check('receipt failure: no success receipt or artifact is fabricated',
          (case / 'result.json').is_dir() and not list((case / 'output').iterdir()) and
          b'unbound variable' not in (case / 'receipt-failure.stderr').read_bytes())
finally:
    stop(worker)
    stop(holder)

case = fixture('output-conflict', capacity=2)
targets = ['linux/amd64', 'linux/arm64', 'darwin/arm64']
identity = str(uuid.uuid4())
(case / 'config/repos.d/conflictfixture.yaml').write_text(json.dumps({
    'tool_name': 'conflictfixture', 'repo': 'fixture/conflictfixture', 'language': 'go',
    'local_path': str(case / 'source'), 'binary_name': 'fixture', 'targets': targets,
    'env': {'GOBIN': str(case / 'shared-output')},
    'cross_compile': {target: {'host': 'shared'} for target in targets}}))
coordinator_script = r'''
source "$DSR_ADMISSION_PROJECT/src/logging.sh"
source "$DSR_ADMISSION_PROJECT/src/config.sh"
source "$DSR_ADMISSION_PROJECT/src/build_state.sh"
source "$DSR_ADMISSION_PROJECT/src/host_selector.sh"
source "$DSR_ADMISSION_MODULE"
act_run_native_build() {
    local slug="${2//\//-}.attempt-$attempt" artifact
    printf '%s %s\n' "$2" "$attempt" >> "$DSR_ADMISSION_CASE/invocations"
    cat > "$DSR_ADMISSION_CASE/$slug.stdin"
    if [[ "$DSR_ADMISSION_PHASE" == first ]]; then while :; do sleep 0.05; done; fi
    artifact="$DSR_ADMISSION_CASE/output/$slug.bin"
    printf 'artifact %s\n' "$2" > "$artifact"
    jq -nc --arg platform "$2" --arg path "$artifact" \
        '{platform:$platform,method:"native",status:"success",exit_code:0,artifact_path:$path,artifact_paths:[$path]}'
}
args=(--run-id "$DSR_ADMISSION_RUN")
[[ "$DSR_ADMISSION_PHASE" != resume ]] || args=(--resume-run-id "$DSR_ADMISSION_RUN")
act_orchestrate_build conflictfixture 1.0.0 --parallel-jobs 2 --no-source-sync-gate \
    --output-dir "$DSR_ADMISSION_CASE/output" "${args[@]}"
'''
process = None
try:
    process = launch(case, coordinator_script, 'first', {'DSR_ADMISSION_RUN': identity})
    wait_for(process, lambda: (case / 'invocations').exists() and
             b'waiting for that build to finish' in (case / 'first.stderr').read_bytes(),
             'second target did not reach the real shared-output wait')
    process.send_signal(signal.SIGTERM)
    check('output conflict: cancellation drains the active worker and returns 130', process.wait(timeout=10) == 130)
    first = read(case / 'first.stdout')
    workspace = case / 'state/builds/conflictfixture/1.0.0' / identity
    state = read(workspace / 'state.json')
    check('output conflict: only the admitted target ran', (case / 'invocations').read_text().splitlines() == [targets[0] + ' 1'])
    for target, row in zip(targets[1:], first['targets'][1:]):
        saved = state['target_statuses'][target]
        check('output conflict: ' + target + ' stays pending with zero attempts',
              saved['status'] == 'pending' and saved['attempts'] == 0 and row['status'] == 'skipped')
    check('output conflict: no queued target reserves an immutable log or result',
          not any(p.name.startswith(('002-', '003-'))
                  for directory in ('logs', 'results') for p in (workspace / directory).iterdir()))
    receipts = {p: hashlib.sha256(p.read_bytes()).hexdigest()
                for directory in ('logs', 'results') for p in (workspace / directory).iterdir() if p.is_file()}
    process = launch(case, coordinator_script, 'resume', {'DSR_ADMISSION_RUN': identity})
    check('output conflict: exact-run resume completes successfully', process.wait(timeout=30) == 0)
    resumed = read(case / 'resume.stdout')
    state = read(workspace / 'state.json')
    check('output conflict: every queued target runs once and the interrupted target retries once',
          Counter((case / 'invocations').read_text().splitlines()) ==
          Counter([targets[0] + ' 1', targets[0] + ' 2', targets[1] + ' 1', targets[2] + ' 1']))
    check('output conflict: resume preserves ordered results and truthful attempt counters',
          resumed['run_id'] == identity and resumed['summary'] == {'total': 3, 'success': 3, 'failed': 0} and
          [r['platform'] for r in resumed['targets']] == targets and
          [state['target_statuses'][target]['attempts'] for target in targets] == [2, 1, 1] and
          state['status'] == 'targets-complete')
    check('output conflict: resume preserves prior immutable receipt bytes',
          all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in receipts.items()))
    check('output conflict: stdin-reading descendants receive EOF on every attempt',
          len(list(case.glob('*.stdin'))) == 4 and all(p.stat().st_size == 0 for p in case.glob('*.stdin')))
finally:
    stop(process)
print('Worker admission cancellation: %d passed, 0 failed' % checks, flush=True)
PY
    then
        log_pass "capacity and output-conflict cancellation preserve leases, receipts and resume"
    else
        log_fail "worker admission cancellation regression"
    fi
}

# Main
main() {
    if [[ "${1:-}" == "--typed-companions-only" ]]; then
        test_typed_workflow_companions
        [[ "$FAIL_COUNT" -eq 0 ]]
        return
    fi
    if [[ "${1:-}" == "--worker-admission-cancel-only" ]]; then
        test_worker_admission_cancellation
        [[ "$FAIL_COUNT" -eq 0 ]]
        return
    fi
    if [[ "${1:-}" == "--workflow-isolation-only" ]]; then
        test_concurrent_workflow_isolation
        [[ "$FAIL_COUNT" -eq 0 ]]
        return
    fi
    if [[ "${1:-}" == "--native-guard-only" ]]; then
        test_unix_native_build_guard
        [[ "$FAIL_COUNT" -eq 0 ]]
        return
    fi
    if [[ "${1:-}" == "--timeout-only" ]]; then
        test_timeout_descendant_cancellation
        test_timeout_owned_groups
        test_workflow_process_cancellation
        [[ "$FAIL_COUNT" -eq 0 ]]
        return
    fi
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
    test_workspace_archive_include_mode_large_listing
    test_workspace_archive_collection_receipts
    test_workspace_archive_contract_format_and_members
    test_strict_git_commit_replacement_binding
    test_act_cleanup
    test_workflow_validation
    test_act_run_workflow_injects_tag_env
    test_act_run_workflow_requires_runner_image_mapping
    test_act_run_workflow_isolates_parent_write_workflows
    test_concurrent_workflow_isolation
    test_typed_workflow_companions
    test_act_analyze_workflow
    test_timeout_descendant_cancellation
    test_timeout_owned_groups
    test_workflow_process_cancellation
    test_worker_admission_cancellation
    test_unix_native_build_guard

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
