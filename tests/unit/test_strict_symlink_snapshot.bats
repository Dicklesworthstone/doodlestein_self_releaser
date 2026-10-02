#!/usr/bin/env bats
# test_strict_symlink_snapshot.bats - strict release snapshots and tracked
# symlinks (mode 120000).
#
# A tracked relative symlink whose target stays inside the repository is
# archived as a symlink (git archive keeps it, tar -xf restores it) and is
# verified by its target string, which is the committed blob. Absolute targets
# and targets that climb above the repository root stay refused, as do links
# retargeted after extraction. eidetic_engine_cli tracks such a link
# (tests/audit_artifacts/latest_install_pipeline.json, ADR 0046), which the
# strict contract used to refuse outright.

load ../helpers/test_harness.bash

setup() {
    harness_setup
    command -v git >/dev/null 2>&1 || skip "git required for strict snapshot tests"
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/src/act_runner.sh"
    REPO="$TEST_TMPDIR/repo"
    mkdir -p "$REPO/tests/audit_artifacts" "$REPO/src"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email "dsr-tests@example.invalid"
    git -C "$REPO" config user.name "dsr tests"
    printf 'fn main() {}\n' > "$REPO/src/main.rs"
    printf '{"run":1}\n' > "$REPO/tests/audit_artifacts/install_pipeline_1.json"
    printf '{"run":2}\n' > "$REPO/tests/audit_artifacts/install_pipeline_2.json"
    ln -s install_pipeline_2.json "$REPO/tests/audit_artifacts/latest_install_pipeline.json"
    ln -s ../src/main.rs "$REPO/tests/main_link.rs"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m fixture
}

teardown() {
    harness_teardown 2>/dev/null || true
}

_extract_snapshot() {
    local dest="$1"
    mkdir -p "$dest"
    git -C "$REPO" archive --format=tar HEAD | tar -xf - -C "$dest"
}

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

@test "contained relative symlinks enter the strict manifest as mode 120000" {
    run _act_write_tracked_manifest "$REPO" HEAD "$TEST_TMPDIR/manifest"
    [ "$status" -eq 0 ]
    run grep -c $'\t120000\t' "$TEST_TMPDIR/manifest"
    [ "$output" = "2" ]
    run grep $'\t120000\ttests/audit_artifacts/latest_install_pipeline.json$' "$TEST_TMPDIR/manifest"
    [ "$status" -eq 0 ]
}

@test "an extracted snapshot with intact symlinks verifies locally and remotely" {
    _act_write_tracked_manifest "$REPO" HEAD "$TEST_TMPDIR/manifest"
    _extract_snapshot "$TEST_TMPDIR/snap"
    [ -L "$TEST_TMPDIR/snap/tests/audit_artifacts/latest_install_pipeline.json" ]

    run _act_verify_tracked_manifest_local "$TEST_TMPDIR/snap" "$TEST_TMPDIR/manifest"
    [ "$status" -eq 0 ]

    git -C "$REPO" archive --format=tar HEAD > "$TEST_TMPDIR/archive.tar"
    count=$(_act_tracked_manifest_object_count "$TEST_TMPDIR/manifest")
    _act_unix_strict_snapshot_verify_script "$TEST_TMPDIR/snap" "$TEST_TMPDIR/archive.tar" \
        "$TEST_TMPDIR/manifest" "$(_sha256 "$TEST_TMPDIR/manifest")" "$count" > "$TEST_TMPDIR/verify.sh"
    run sh "$TEST_TMPDIR/verify.sh"
    [ "$status" -eq 0 ]
}

@test "a symlink retargeted after extraction fails both verifiers" {
    _act_write_tracked_manifest "$REPO" HEAD "$TEST_TMPDIR/manifest"
    _extract_snapshot "$TEST_TMPDIR/snap"
    ln -sfn install_pipeline_1.json "$TEST_TMPDIR/snap/tests/audit_artifacts/latest_install_pipeline.json"

    run _act_verify_tracked_manifest_local "$TEST_TMPDIR/snap" "$TEST_TMPDIR/manifest"
    [ "$status" -ne 0 ]

    git -C "$REPO" archive --format=tar HEAD > "$TEST_TMPDIR/archive.tar"
    count=$(_act_tracked_manifest_object_count "$TEST_TMPDIR/manifest")
    _act_unix_strict_snapshot_verify_script "$TEST_TMPDIR/snap" "$TEST_TMPDIR/archive.tar" \
        "$TEST_TMPDIR/manifest" "$(_sha256 "$TEST_TMPDIR/manifest")" "$count" > "$TEST_TMPDIR/verify.sh"
    run sh "$TEST_TMPDIR/verify.sh"
    [ "$status" -ne 0 ]
}

@test "a regular file replaced by a symlink is still refused" {
    _act_write_tracked_manifest "$REPO" HEAD "$TEST_TMPDIR/manifest"
    _extract_snapshot "$TEST_TMPDIR/snap"
    mv "$TEST_TMPDIR/snap/src/main.rs" "$TEST_TMPDIR/main.rs.moved"
    ln -s ../tests/audit_artifacts/install_pipeline_1.json "$TEST_TMPDIR/snap/src/main.rs"
    run _act_verify_tracked_manifest_local "$TEST_TMPDIR/snap" "$TEST_TMPDIR/manifest"
    [ "$status" -ne 0 ]
}

@test "symlinks that escape the repository are refused when the manifest is written" {
    ln -s ../../../etc/hosts "$REPO/tests/audit_artifacts/escape.json"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m escape
    run _act_write_tracked_manifest "$REPO" HEAD "$TEST_TMPDIR/manifest-escape"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be represented safely: tests/audit_artifacts/escape.json"* ]]
}

@test "absolute symlink targets are refused when the manifest is written" {
    ln -s /etc/hosts "$REPO/abs_link"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m absolute
    run _act_write_tracked_manifest "$REPO" HEAD "$TEST_TMPDIR/manifest-abs"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be represented safely: abs_link"* ]]
}

@test "containment is resolved lexically from the link's directory" {
    run _act_strict_symlink_target_is_contained "a/b/link" "../c"
    [ "$status" -eq 0 ]
    run _act_strict_symlink_target_is_contained "a/b/link" "../../c"
    [ "$status" -eq 0 ]
    run _act_strict_symlink_target_is_contained "a/b/link" "../../../c"
    [ "$status" -ne 0 ]
    run _act_strict_symlink_target_is_contained "link" "../c"
    [ "$status" -ne 0 ]
    run _act_strict_symlink_target_is_contained "a/link" "x/../../../c"
    [ "$status" -ne 0 ]
    run _act_strict_symlink_target_is_contained "a/link" "/etc/hosts"
    [ "$status" -ne 0 ]
    run _act_strict_symlink_target_is_contained "a/link" ""
    [ "$status" -ne 0 ]
}
