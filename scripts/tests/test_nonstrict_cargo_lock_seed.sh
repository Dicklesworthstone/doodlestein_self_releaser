#!/usr/bin/env bash
# Ordinary Unix Cargo-home preparation must scope ambient downloads to Cargo.lock.
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
source "$ROOT/src/act_runner.sh" || exit 1
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
if jq -e 'has("selection")' <<< "$receipt2" >/dev/null; then
    printf 'not ok %d - lockless fallback must not invent a lock selection\n' "$((checks+1))"; exit 1
fi
checks=$((checks + 1)); printf 'ok %d - lockless fallback does not invent a lock selection\n' "$checks"

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

printf 'Nonstrict Cargo.lock cache: %d checks passed\n' "$checks"
