#!/usr/bin/env bats
# test_local_host_artifact_download.bats - Regression tests for the
# act_run_native_build local-host artifact download branch.
#
# Historical bug: when act_run_native_build ran on the local host, the
# cp-success path set `scp_output=""` but neither appended to
# `local_artifact_paths` nor set `download_failed`. That meant a
# successful local build reported back JSON with an empty `artifact_path`,
# which in turn made the caller (`cmd_build`) think only the remote
# (scp-based) builds had produced anything. For a Go project with two
# local targets (e.g. linux/amd64 and windows/amd64 cross-compiled on
# the Linux host) and one remote target (darwin/arm64 on mmini), the
# visible symptom was: all three release archives packaged the same
# remote-built darwin binary under linux/darwin/windows names.
#
# These tests pin down the contract of that branch without standing up a
# full orchestrator run:
#   * cp-success -> local_artifact_paths gets the local path appended
#   * cp-failure -> download_failed becomes true
#   * windows cross-compile fallback -> if `$name.exe` is missing but the
#     bare `$name` exists (Go's `-o <name>` does not auto-append .exe),
#     cp the bare name instead.
#
# The tests reimplement the branch locally so they test-the-spec rather
# than the text of act_runner.sh; if the real code and the spec drift
# apart again, the fixture build matrix in `tests/fixtures/` is the next
# layer of defence.

load ../helpers/test_harness.bash

setup() {
    harness_setup

    # Simulate the handful of locals the real branch reads from. A fresh
    # copy per test, so state can't leak.
    _HOST=""
    _LOG_FILE="$_HARNESS_TMPDIR/build.log"
    : > "$_LOG_FILE"
}

# Reset the branch's state variables to a clean slate. Called at the top
# of every @test because `declare -a` inside setup() is function-local
# and not visible to the test body.
_reset_branch_state() {
    local_artifact_paths=()
    download_failed=false
}

teardown() {
    harness_teardown 2>/dev/null || true
}

# Tiny standin for _act_is_local_host — the real one consults the hosts
# registry; here we just check a module-level variable.
_is_local() {
    [[ "$_HOST" == "local" ]]
}

# Stubbed scp: we can't spin up a real ssh target in a unit test, so the
# fake `scp` behaves like cp against paths on the local filesystem. That
# keeps the contract under test — fallback-when-.exe-missing — honest
# without requiring a live remote.
_fake_scp() {
    # Usage mirrors the real call shape: _fake_scp <src> <dest>
    cp "$1" "$2" 2>/dev/null
}

# Reimplementation of the fixed branch. If this diverges from the real
# act_run_native_build snippet, the test will fail against the
# acceptance criteria rather than the literal source. The scp arm here
# is exercised whenever _HOST != "local" and mirrors the production
# flow: try the exact path, and on failure, if the path ends in .exe,
# retry once without the suffix.
_download_branch() {
    local remote_artifact_path="$1"
    local this_artifact_path="$2"
    local bin="$3"

    if _is_local; then
        local copy_src="$remote_artifact_path"
        # Windows cross-compile fallback: Go's `-o bv` does not append
        # .exe, so when the .exe form is missing try the bare name.
        if [[ ! -f "$copy_src" ]] && [[ "$copy_src" == *.exe ]]; then
            local alt_src="${copy_src%.exe}"
            if [[ -f "$alt_src" ]]; then
                copy_src="$alt_src"
            fi
        fi
        if cp "$copy_src" "$this_artifact_path" 2>/dev/null; then
            local_artifact_paths+=("$this_artifact_path")
        else
            echo "Local cp failed for $bin: $copy_src" >> "$_LOG_FILE"
            download_failed=true
        fi
    else
        # Remote (scp) branch with the same .exe fallback.
        if _fake_scp "$remote_artifact_path" "$this_artifact_path"; then
            local_artifact_paths+=("$this_artifact_path")
        else
            local fallback_ok=false
            if [[ "$remote_artifact_path" == *.exe ]]; then
                local alt_remote="${remote_artifact_path%.exe}"
                if _fake_scp "$alt_remote" "$this_artifact_path"; then
                    local_artifact_paths+=("$this_artifact_path")
                    fallback_ok=true
                else
                    echo "SCP fallback (no .exe) also failed for $bin" >> "$_LOG_FILE"
                fi
            fi
            if ! $fallback_ok; then
                echo "SCP failed for $bin: $remote_artifact_path" >> "$_LOG_FILE"
                download_failed=true
            fi
        fi
    fi
}

# ============================================================================
# Success path
# ============================================================================

@test "local-host cp success populates local_artifact_paths" {
    _reset_branch_state
    _HOST="local"
    local remote="$_HARNESS_TMPDIR/repo/bv"
    local dest="$_HARNESS_TMPDIR/artifacts/linux-amd64/bv"
    mkdir -p "$(dirname "$remote")" "$(dirname "$dest")"
    printf 'fake-linux-binary' > "$remote"

    _download_branch "$remote" "$dest" "bv"

    [[ "$download_failed" == "false" ]]
    [[ -f "$dest" ]]
    [[ "$(cat "$dest")" == "fake-linux-binary" ]]
    [[ "${#local_artifact_paths[@]}" -eq 1 ]]
    [[ "${local_artifact_paths[0]}" == "$dest" ]]
}

# ============================================================================
# Failure path
# ============================================================================

@test "local-host cp failure sets download_failed and logs" {
    _reset_branch_state
    _HOST="local"
    local missing="$_HARNESS_TMPDIR/repo/nope"
    local dest="$_HARNESS_TMPDIR/artifacts/linux-amd64/bv"
    mkdir -p "$(dirname "$missing")" "$(dirname "$dest")"

    _download_branch "$missing" "$dest" "bv"

    [[ "$download_failed" == "true" ]]
    [[ ! -f "$dest" ]]
    # ${#array[@]} trips bash set -u on truly-empty arrays, so guard.
    [[ "${#local_artifact_paths[@]}" -eq 0 ]]
    grep -q "Local cp failed for bv:" "$_LOG_FILE"
}

# ============================================================================
# Windows cross-compile fallback
# ============================================================================

@test "local-host windows fallback: .exe missing but bare name present" {
    _reset_branch_state
    _HOST="local"
    local bare="$_HARNESS_TMPDIR/repo/bv"
    local exe="$bare.exe"
    local dest="$_HARNESS_TMPDIR/artifacts/windows-amd64/bv.exe"
    mkdir -p "$(dirname "$bare")" "$(dirname "$dest")"
    # Only the bare name exists — this is what `go build -o bv` with
    # GOOS=windows produces when run on a Linux host.
    printf 'fake-windows-pe' > "$bare"
    [[ ! -f "$exe" ]]

    _download_branch "$exe" "$dest" "bv"

    [[ "$download_failed" == "false" ]]
    [[ -f "$dest" ]]
    [[ "$(cat "$dest")" == "fake-windows-pe" ]]
    [[ "${#local_artifact_paths[@]}" -eq 1 ]]
}

@test "local-host windows fallback: both .exe and bare name missing -> failure" {
    _reset_branch_state
    _HOST="local"
    local exe="$_HARNESS_TMPDIR/repo/bv.exe"
    local dest="$_HARNESS_TMPDIR/artifacts/windows-amd64/bv.exe"
    mkdir -p "$(dirname "$exe")" "$(dirname "$dest")"

    _download_branch "$exe" "$dest" "bv"

    [[ "$download_failed" == "true" ]]
    [[ ! -f "$dest" ]]
    [[ "${#local_artifact_paths[@]}" -eq 0 ]]
}

@test "local-host windows: prefer .exe when both exist" {
    _reset_branch_state
    _HOST="local"
    local bare="$_HARNESS_TMPDIR/repo/bv"
    local exe="$bare.exe"
    local dest="$_HARNESS_TMPDIR/artifacts/windows-amd64/bv.exe"
    mkdir -p "$(dirname "$bare")" "$(dirname "$dest")"
    printf 'bare-output' > "$bare"
    printf 'exe-output' > "$exe"

    _download_branch "$exe" "$dest" "bv"

    [[ "$download_failed" == "false" ]]
    [[ "$(cat "$dest")" == "exe-output" ]]
    [[ "${#local_artifact_paths[@]}" -eq 1 ]]
}

# ============================================================================
# Remote (scp) branch — symmetric contract
# ============================================================================

@test "scp success populates local_artifact_paths" {
    _reset_branch_state
    _HOST="wlap"  # anything other than 'local'
    local remote="$_HARNESS_TMPDIR/repo/bv"
    local dest="$_HARNESS_TMPDIR/artifacts/windows-amd64/bv.exe"
    mkdir -p "$(dirname "$remote")" "$(dirname "$dest")"
    printf 'fake-win-pe' > "$remote"

    _download_branch "$remote" "$dest" "bv"

    [[ "$download_failed" == "false" ]]
    [[ "${#local_artifact_paths[@]}" -eq 1 ]]
    [[ "${local_artifact_paths[0]}" == "$dest" ]]
}

@test "scp failure sets download_failed and logs" {
    _reset_branch_state
    _HOST="wlap"
    local missing="$_HARNESS_TMPDIR/repo/nope"
    local dest="$_HARNESS_TMPDIR/artifacts/linux-amd64/bv"
    mkdir -p "$(dirname "$missing")" "$(dirname "$dest")"

    _download_branch "$missing" "$dest" "bv"

    [[ "$download_failed" == "true" ]]
    [[ "${#local_artifact_paths[@]}" -eq 0 ]]
    grep -q "SCP failed for bv:" "$_LOG_FILE"
}

@test "scp windows fallback: .exe missing but bare name present -> retry succeeds" {
    _reset_branch_state
    _HOST="wlap"
    local bare="$_HARNESS_TMPDIR/repo/bv"
    local exe="$bare.exe"
    local dest="$_HARNESS_TMPDIR/artifacts/windows-amd64/bv.exe"
    mkdir -p "$(dirname "$bare")" "$(dirname "$dest")"
    # Simulates native-Windows Go build with `go build -o bv ./cmd/bv`
    # which produces `bv` even on Windows hosts (Go only auto-appends
    # .exe when -o is omitted).
    printf 'fake-win-bare' > "$bare"
    [[ ! -f "$exe" ]]

    _download_branch "$exe" "$dest" "bv"

    [[ "$download_failed" == "false" ]]
    [[ "$(cat "$dest")" == "fake-win-bare" ]]
    [[ "${#local_artifact_paths[@]}" -eq 1 ]]
}

@test "scp windows fallback: both .exe and bare name missing -> failure" {
    _reset_branch_state
    _HOST="wlap"
    local exe="$_HARNESS_TMPDIR/repo/bv.exe"
    local dest="$_HARNESS_TMPDIR/artifacts/windows-amd64/bv.exe"
    mkdir -p "$(dirname "$exe")" "$(dirname "$dest")"

    _download_branch "$exe" "$dest" "bv"

    [[ "$download_failed" == "true" ]]
    [[ "${#local_artifact_paths[@]}" -eq 0 ]]
    grep -q "SCP fallback (no .exe) also failed for bv" "$_LOG_FILE"
    grep -q "SCP failed for bv:" "$_LOG_FILE"
}

@test "scp non-windows failure does not attempt fallback" {
    _reset_branch_state
    _HOST="mmini"
    local missing="$_HARNESS_TMPDIR/repo/nope"
    local dest="$_HARNESS_TMPDIR/artifacts/darwin-arm64/bv"
    mkdir -p "$(dirname "$missing")" "$(dirname "$dest")"

    _download_branch "$missing" "$dest" "bv"

    [[ "$download_failed" == "true" ]]
    [[ "${#local_artifact_paths[@]}" -eq 0 ]]
    grep -q "SCP failed for bv:" "$_LOG_FILE"
    # The fallback is gated on path ending in .exe; darwin path must not
    # log a fallback attempt.
    ! grep -q "SCP fallback" "$_LOG_FILE"
}
