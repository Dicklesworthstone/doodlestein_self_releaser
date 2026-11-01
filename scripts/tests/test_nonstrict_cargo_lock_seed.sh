#!/usr/bin/env bash
# Ordinary Unix Cargo-home preparation scopes downloads and protects its stage.
# Uses the real cache runtime and filesystem; no network, compiler, or SSH.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
for tool in bash python3 jq sha256sum; do
    command -v "$tool" >/dev/null || { printf 'SKIP nonstrict lock cache: missing %s\n' "$tool"; exit 0; }
done
python3 -I -c 'import sys; raise SystemExit(sys.version_info < (3,11))' 2>/dev/null || {
    printf 'SKIP nonstrict lock cache: Python 3.11+ required\n'; exit 0;
}
work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-nonstrict-lock.XXXXXXXX") || exit 1
printf 'Retained fixture: %s\n' "$work"
home="$work/home"
ambient="$home/.cargo"
source_root="$work/source"
mkdir -p "$ambient/registry/cache/example" "$ambient/git/checkouts/unrelated/deadbeef" "$source_root"
selected="$ambient/registry/cache/example/selected-1.0.0.crate"
unrelated="$ambient/registry/cache/example/unrelated-9.9.9.crate"
printf 'selected locked archive\n' > "$selected"
printf 'unrelated archive bytes\n' > "$unrelated"
ln -s /missing/unrelated "$ambient/git/checkouts/unrelated/deadbeef/LICENSE"
sha=$(sha256sum < "$selected"); sha=${sha%% *}
cat > "$source_root/Cargo.lock" <<EOF
version = 3

[[package]]
name = "selected"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "$sha"
EOF
export HOME="$home"
export CARGO_HOME="$ambient"
# shellcheck source=src/act_runner.sh
source "${DSR_TEST_ACT_RUNNER:-$ROOT/src/act_runner.sh}" || exit 1
_act_is_windows_host() { return 1; }
_act_ram_backed_guard_sh() { printf ':'; }
_act_ssh_exec() { bash -c "$2"; }

checks=0
check() {
    local label="$1"; shift
    checks=$((checks + 1))
    if "$@"; then printf 'ok %d - %s\n' "$checks" "$label"
    else printf 'not ok %d - %s\n' "$checks" "$label"; exit 1
    fi
}

isolation="$work/isolation"
stage="$isolation/dsr-build-probe-linux-amd64-locked"
private="$stage/cargo-home"
receipt=$(_act_prepare_unix_nonstrict_cargo_home local "$isolation" "$stage" "$private" "$source_root") || {
    printf 'preparation failed\n' >&2; exit 1;
}
check 'lockfile-scoped ordinary seed succeeds' test -d "$private"
check 'ordinary stage protection is a real file outside Cargo home and source' \
    test -f "$stage/.sbh-protect"
check 'ordinary stage protection is not a symlink' test ! -L "$stage/.sbh-protect"
check 'source tree is not changed by stage protection' test ! -e "$source_root/.sbh-protect"
check 'Cargo home does not import the stage marker' test ! -e "$private/.sbh-protect"
check 'stage and protection marker retain private ownership and modes' python3 -I - "$stage" <<'PY'
import os, stat, sys
root = sys.argv[1]
for path, mode in ((root, 0o700), (root + '/.sbh-protect', 0o600)):
    info = os.lstat(path)
    assert info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == mode, (path, info)
PY
check 'ordinary seed receipt records Cargo.lock selection' jq -e '.selection.kind=="cargo-lock-downloads" and .selection.registry_packages==1' <<< "$receipt"
check 'selected archive is copied' test -f "$private/registry/cache/example/selected-1.0.0.crate"
check 'unrelated registry archive is omitted' test ! -e "$private/registry/cache/example/unrelated-9.9.9.crate"
check 'unrelated Git checkout tree is never entered' test ! -e "$private/git"

# Projects without Cargo.lock retain the existing conservative unscoped behavior.
source_unlocked="$work/source-unlocked"
mkdir "$source_unlocked"
stage2="$isolation/dsr-build-probe-linux-amd64-unlocked"
private2="$stage2/cargo-home"
receipt2=$(_act_prepare_unix_nonstrict_cargo_home local "$isolation" "$stage2" "$private2" "$source_unlocked") || exit 1
check 'lockless ordinary project retains unrelated ambient archive' test -f "$private2/registry/cache/example/unrelated-9.9.9.crate"
check 'lockless ordinary preparation also protects its private stage' test -f "$stage2/.sbh-protect"
if jq -e 'has("selection")' <<< "$receipt2" >/dev/null; then
    printf 'not ok %d - lockless fallback must not invent a lock selection\n' "$((checks+1))"; exit 1
fi
checks=$((checks + 1)); printf 'ok %d - lockless fallback does not invent a lock selection\n' "$checks"

# A configured shared build root may inherit setgid onto new directories;
# those private stages still have no group/other access and remain supported.
setgid_root="$work/isolation-setgid"
mkdir "$setgid_root"
chmod 2775 "$setgid_root"
setgid_stage="$setgid_root/dsr-build-probe-setgid"
_act_prepare_unix_nonstrict_cargo_home local "$setgid_root" "$setgid_stage" \
    "$setgid_stage/cargo-home" "$source_root" > "$work/setgid-summary.json" || exit 1
check 'setgid build root retains its configured group inheritance' test -g "$setgid_root"
check 'setgid build root permits an ordinary private cache' test -d "$setgid_stage/cargo-home"
check 'inherited directory flags do not grant access to stage or marker' python3 -I - "$setgid_stage" <<'PY'
import os, stat, sys
root = sys.argv[1]
for path, mode in ((root, 0o700), (root + '/.sbh-protect', 0o600)):
    info = os.lstat(path)
    assert info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) & 0o777 == mode, (path, info)
PY

# A Cargo.lock symlink is evidence ambiguity, not permission to silently fall back.
source_link="$work/source-linked"
mkdir "$source_link"
ln -s "$source_root/Cargo.lock" "$source_link/Cargo.lock"
stage3="$isolation/dsr-build-probe-linux-amd64-linked"
private3="$stage3/cargo-home"
if _act_prepare_unix_nonstrict_cargo_home local "$isolation" "$stage3" "$private3" "$source_link" >/dev/null 2>&1; then
    printf 'not ok %d - linked Cargo.lock must be refused\n' "$((checks+1))"; exit 1
fi
checks=$((checks + 1)); printf 'ok %d - linked Cargo.lock is refused\n' "$checks"

# The marker must exist before cache preparation can fail, not be added after
# a successful seed. A failed attempt never publishes a private cache receipt.
check 'refused cache preparation still has stage protection' test -f "$stage3/.sbh-protect"
check 'refused preparation publishes no private cache' test ! -e "$private3"

# Inject an actual colliding leaf immediately after the real mkdir creates the
# private stage. The generated marker write must neither follow nor overwrite
# it, and the real cache snapshot must never start. No admission result is faked.
collision_target="$work/marker-collision-target"
printf 'retained unrelated bytes\n' > "$collision_target"
collision_fifo="$work/marker-collision-fifo"
mkfifo "$collision_fifo"
export DSR_MARKER_COLLISION_TARGET="$collision_target" DSR_MARKER_COLLISION_FIFO="$collision_fifo"
_act_ssh_exec() {
    local injected='
mkdir() {
    command mkdir "$@" || return $?
    if [[ $# == 1 && "$1" == "$DSR_MARKER_COLLISION_STAGE" ]]; then
        case "$DSR_MARKER_COLLISION_KIND" in
            link) ln -s "$DSR_MARKER_COLLISION_TARGET" "$1/.sbh-protect" ;;
            file) printf "preexisting marker bytes\\n" > "$1/.sbh-protect" ;;
            directory) command mkdir "$1/.sbh-protect" ;;
            fifo) mkfifo "$1/.sbh-protect" ;;
            fifo-link) ln -s "$DSR_MARKER_COLLISION_FIFO" "$1/.sbh-protect" ;;
        esac
    fi
}
'
    python3 -I - "$injected$2" <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(['bash', '-c', sys.argv[1]], timeout=10).returncode)
except subprocess.TimeoutExpired:
    print('marker collision blocked instead of being refused', file=sys.stderr)
    sys.exit(124)
PY
}
for collision_kind in link file directory fifo fifo-link; do
    collision_stage="$isolation/dsr-build-marker-collision-$collision_kind"
    export DSR_MARKER_COLLISION_STAGE="$collision_stage" DSR_MARKER_COLLISION_KIND="$collision_kind"
    collision_status=0
    _act_prepare_unix_nonstrict_cargo_home local "$isolation" "$collision_stage" \
            "$collision_stage/cargo-home" "$source_root" > "$work/collision-$collision_kind.stdout" \
            2> "$work/collision-$collision_kind.stderr" || collision_status=$?
    check "colliding $collision_kind marker is refused" test "$collision_status" -ne 0
    check "colliding $collision_kind marker does not block" test "$collision_status" -ne 124
    check "colliding $collision_kind marker prevents private cache creation" \
        test ! -e "$collision_stage/cargo-home"
    check "colliding $collision_kind marker publishes no seed summary" \
        test ! -s "$work/collision-$collision_kind.stdout"
done
check 'linked marker never writes outside the private stage' \
    test "$(cat "$collision_target")" = 'retained unrelated bytes'
check 'existing regular marker bytes are never overwritten' \
    test "$(cat "$isolation/dsr-build-marker-collision-file/.sbh-protect")" = 'preexisting marker bytes'
check 'a linked FIFO outside the stage is untouched' test -p "$collision_fifo"

printf 'Nonstrict Cargo.lock cache: %d checks passed\n' "$checks"
