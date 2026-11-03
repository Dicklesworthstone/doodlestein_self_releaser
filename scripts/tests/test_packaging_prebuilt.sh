#!/usr/bin/env bash
# Real archive regression tests for authoritative prebuilt include handling.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/src/packaging.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
passed=0 failed=0 skipped=0
pass() { printf 'PASS %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf 'FAIL %s\n' "$*" >&2; failed=$((failed + 1)); }
inode() { stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"; }
expect_success() {
    local label="$1"; shift
    if "$@" > "$work/stdout" 2> "$work/stderr"; then
        [[ ! -s "$work/stdout" ]] && pass "$label" || fail "$label: polluted stdout"
    else
        fail "$label (exit $?)"
        cat "$work/stderr" >&2
    fi
}
expect_invalid() {
    local label="$1" rc; shift
    "$@" > "$work/stdout" 2> "$work/stderr"; rc=$?
    [[ $rc -eq 4 && ! -s "$work/stdout" ]] && pass "$label" || fail "$label: expected 4, got $rc"
}
expect_equal() { cmp -s "$2" "$3" && pass "$1" || fail "$1"; }
repack_with_changed_copy_metadata() (
    local replacement="$1" original="$2"
    shift
    cp() {
        if [[ $# -eq 3 && "$1" == -- && "$2" == "$original" ]]; then
            command cp -- "$replacement" "$3"
        else
            command cp "$@"
        fi
    }
    packaging_repack_archive "$@"
)

for tool in tar gzip xz cmp stat; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
mkdir -p "$work/input/docs" "$work/extras/docs"
printf '#!/bin/sh\nprintf "tool ready\\n"\n' > "$work/input/tool"
printf 'reviewed license\n' > "$work/input/LICENSE"
printf 'reviewed guide\n' > "$work/input/docs/guide.txt"
chmod 0755 "$work/input/tool"
chmod 0644 "$work/input/LICENSE" "$work/input/docs/guide.txt"
cp "$work/input/LICENSE" "$work/extras/LICENSE"
cp "$work/input/docs/guide.txt" "$work/extras/docs/guide.txt"
printf 'additional notice\n' > "$work/extras/NOTICE"
printf 'mode-sensitive companion\n' > "$work/extras/helper"
chmod 0654 "$work/extras/helper"
mkdir -p "$work/private" "$work/plain" "$work/executable" "$work/changed" "$work/legacy"
printf '#!/bin/sh\nprintf "private helper\\n"\n' > "$work/private/helper"
printf 'ordinary companion\n' > "$work/private/NOTICE"
chmod 0700 "$work/private/helper"
chmod 0600 "$work/private/NOTICE"
cp "$work/private/helper" "$work/plain/helper"
chmod 0600 "$work/plain/helper"
cp "$work/private/NOTICE" "$work/executable/NOTICE"
chmod 0700 "$work/executable/NOTICE"
printf 'different helper bytes\n' > "$work/changed/helper"
chmod 0700 "$work/changed/helper"
cp "$work/private/helper" "$work/legacy/helper"
chmod 0775 "$work/legacy/helper"

for format in tar.gz tar.xz zip; do
    if [[ "$format" == zip ]] && { ! command -v zip >/dev/null || ! command -v unzip >/dev/null; }; then
        printf 'SKIP zip: install zip and unzip\n'; skipped=$((skipped + 1)); continue
    fi
    dir="$work/$format"
    mkdir -p "$dir"
    source_archive="$dir/producer.$format"
    case "$format" in
        tar.gz) tar -czf "$source_archive" -C "$work/input" tool LICENSE docs/guide.txt ;;
        tar.xz) tar -cJf "$source_archive" -C "$work/input" tool LICENSE docs/guide.txt ;;
        zip) (cd "$work/input" && zip -q -0 "$source_archive" tool LICENSE docs/guide.txt) ;;
    esac
    [[ -s "$source_archive" ]] || { fail "$format fixture creation"; continue; }
    cp "$source_archive" "$dir/original"
    dest="$dir/versioned.$format"
    expect_success "$format accepts already-packaged includes" \
        packaging_repack_archive "$source_archive" "$format" "$dest" "$format" "$work/extras" LICENSE docs/guide.txt
    expect_equal "$format preserves authoritative compressed bytes" "$source_archive" "$dest"
    before=$(inode "$dest" 2>/dev/null || true)
    expect_success "$format repeated includes are idempotentent" \
        packaging_repack_archive "$source_archive" "$format" "$dest" "$format" "$work/extras" LICENSE LICENSE docs/guide.txt
    [[ -n "$before" && "$(inode "$dest" 2>/dev/null)" == "$before" ]] && \
        pass "$format retry preserves destination inode" || fail "$format retry preserves destination inode"

    extended="$dir/extended.$format"
    expect_success "$format composes matching and new includes" \
        packaging_repack_archive "$source_archive" "$format" "$extended" "$format" "$work/extras" LICENSE NOTICE NOTICE helper
    mkdir -p "$dir/extracted"
    if packaging_extract_payload "$extended" "$format" "$dir/extracted"; then
        expect_equal "$format retains binary payload" "$work/input/tool" "$dir/extracted/tool"
        expect_equal "$format includes new notice once" "$work/extras/NOTICE" "$dir/extracted/NOTICE"
        mode=$(stat -c '%a' "$dir/extracted/helper" 2>/dev/null || stat -f '%Lp' "$dir/extracted/helper")
        [[ "$mode" == 755 ]] && pass "$format normalizes new include executable mode" || fail "$format include mode: $mode"
        source_mode=$(stat -c '%a' "$work/extras/helper" 2>/dev/null || stat -f '%Lp' "$work/extras/helper")
        [[ "$source_mode" == 654 ]] && pass "$format preserves source include mode" || fail "$format source include mode: $source_mode"
        actual=$(packaging_payload_members "$extended" "$format")
        [[ "$actual" == $'LICENSE\nNOTICE\ndocs/guide.txt\nhelper\ntool' ]] && \
            pass "$format exact complete member set" || fail "$format complete member set"
    else
        fail "$format extended archive extraction"
    fi
    expect_equal "$format never changes producer archive" "$source_archive" "$dir/original"

    # An ordinary native archive already carries its private include as 0755.
    # The subsequent packaging pass must recognize that exact representation,
    # not reject or recompress it merely because the source remains 0700.
    canonical="$dir/canonical.$format"
    canonical_copy="$dir/canonical-copy.$format"
    expect_success "$format creates canonical archive from private includes" \
        packaging_build_archive "$format" "$canonical" "$work/private" helper NOTICE
    expect_success "$format private-include fixture has canonical metadata" \
        _pkg_archive_inspect normalized "$canonical" "$format"
    expect_success "$format reuses canonical member with original private include" \
        packaging_repack_archive "$canonical" "$format" "$canonical_copy" "$format" "$work/private" helper NOTICE
    expect_equal "$format canonical include round trip preserves compressed bytes" "$canonical" "$canonical_copy"
    canonical_inode=$(inode "$canonical_copy" 2>/dev/null || true)
    expect_success "$format repeated canonical private include is idempotent" \
        packaging_repack_archive "$canonical" "$format" "$canonical_copy" "$format" "$work/private" helper helper NOTICE
    [[ -n "$canonical_inode" && "$(inode "$canonical_copy" 2>/dev/null)" == "$canonical_inode" ]] && \
        pass "$format canonical include retry preserves destination inode" || fail "$format canonical include retry preserves destination inode"

    printf 'previous canonical destination\n' > "$dir/canonical-guarded.$format"
    cp "$dir/canonical-guarded.$format" "$dir/canonical-sentinel"
    expect_invalid "$format ordinary include cannot satisfy canonical executable" \
        packaging_repack_archive "$canonical" "$format" "$dir/canonical-guarded.$format" "$format" "$work/plain" helper
    expect_invalid "$format executable include cannot satisfy canonical ordinary file" \
        packaging_repack_archive "$canonical" "$format" "$dir/canonical-guarded.$format" "$format" "$work/executable" NOTICE
    expect_invalid "$format canonical metadata cannot hide differing include bytes" \
        packaging_repack_archive "$canonical" "$format" "$dir/canonical-guarded.$format" "$format" "$work/changed" helper

    # Copy corruption must not reuse an earlier normalization decision. Keep
    # the payload and all executable bits identical, changing only the public
    # mode so the final archive admission must inspect the copied headers.
    changed_metadata="$dir/changed-metadata.$format"
    if python3 - "$canonical" "$changed_metadata" "$format" <<'PY'
import io
import stat
import sys
import tarfile
import zipfile

source, destination, fmt = sys.argv[1:]
if fmt == 'zip':
    with zipfile.ZipFile(source) as incoming, zipfile.ZipFile(destination, 'w') as outgoing:
        for member in incoming.infolist():
            data = incoming.read(member)
            if member.filename == 'helper':
                member.external_attr = (stat.S_IFREG | 0o775) << 16
            outgoing.writestr(member, data)
else:
    with tarfile.open(source) as incoming, tarfile.open(destination, 'w:' + ('gz' if fmt == 'tar.gz' else 'xz')) as outgoing:
        for member in incoming.getmembers():
            data = incoming.extractfile(member).read()
            if member.name == 'helper':
                member.mode = 0o775
            outgoing.addfile(member, io.BytesIO(data))
PY
    then
        expect_invalid "$format revalidates canonical metadata after copying" \
            repack_with_changed_copy_metadata "$changed_metadata" "$canonical" "$format" \
                "$dir/canonical-guarded.$format" "$format" "$work/private" helper NOTICE
        expect_equal "$format metadata-only copy failure preserves destination" \
            "$dir/canonical-sentinel" "$dir/canonical-guarded.$format"
    else
        fail "$format changed-metadata fixture creation"
    fi

    # A 0775 legacy member has the same execution mask as canonical 0755 but
    # does not qualify for normalization-aware reuse. Exact legacy masks remain
    # accepted separately; neither fixture is rewritten during a same-format copy.
    legacy="$dir/legacy.$format"
    legacy_private="$dir/legacy-private.$format"
    case "$format" in
        tar.gz)
            tar -czf "$legacy" -C "$work/legacy" helper
            tar -czf "$legacy_private" -C "$work/private" helper
            ;;
        tar.xz)
            tar -cJf "$legacy" -C "$work/legacy" helper
            tar -cJf "$legacy_private" -C "$work/private" helper
            ;;
        zip)
            (cd "$work/legacy" && zip -q -0 "$legacy" helper)
            (cd "$work/private" && zip -q -0 "$legacy_private" helper)
            ;;
    esac
    expect_invalid "$format legacy fixture is not canonical despite full execution mask" \
        _pkg_archive_inspect normalized "$legacy" "$format"
    expect_invalid "$format unnormalized prebuilt retains exact include-mask policy" \
        packaging_repack_archive "$legacy" "$format" "$dir/canonical-guarded.$format" "$format" "$work/private" helper
    expect_equal "$format include refusals preserve previous destination" "$dir/canonical-sentinel" "$dir/canonical-guarded.$format"
    expect_success "$format matching legacy private include remains accepted" \
        packaging_repack_archive "$legacy_private" "$format" "$dir/legacy-copy.$format" "$format" "$work/private" helper
    expect_equal "$format matching legacy private include retains original archive bytes" "$legacy_private" "$dir/legacy-copy.$format"
    private_mode=$(stat -c '%a' "$work/private/helper" 2>/dev/null || stat -f '%Lp' "$work/private/helper")
    [[ "$private_mode" == 700 ]] && pass "$format original private include stays 0700" || fail "$format original private include mode: $private_mode"
    expect_equal "$format original private include bytes stay unchanged" "$work/private/helper" "$work/plain/helper"

    printf 'previous destination\n' > "$dir/guarded.$format"
    cp "$dir/guarded.$format" "$dir/sentinel"
    printf 'different license\n' > "$work/extras/LICENSE"
    expect_invalid "$format rejects differing include bytes" \
        packaging_repack_archive "$source_archive" "$format" "$dir/guarded.$format" "$format" "$work/extras" LICENSE
    expect_equal "$format conflict preserves previous destination" "$dir/sentinel" "$dir/guarded.$format"
    cp "$work/input/LICENSE" "$work/extras/LICENSE"
    chmod 0755 "$work/extras/LICENSE"
    expect_invalid "$format rejects differing executable bits" \
        packaging_repack_archive "$source_archive" "$format" "$dir/guarded.$format" "$format" "$work/extras" LICENSE
    chmod 0644 "$work/extras/LICENSE"
    expect_invalid "$format refuses source overwrite" \
        packaging_repack_archive "$source_archive" "$format" "$source_archive" "$format" "$work/extras" NOTICE
    expect_equal "$format rejection preserves source" "$source_archive" "$dir/original"
done

# Cross-format reuse must not rebuild a destination merely because matching
# extras were named; the extracted file set, bytes and modes remain the gate.
expect_success 'cross-format with matching include' \
    packaging_repack_archive "$work/tar.gz/producer.tar.gz" tar.gz "$work/cross.tar.xz" tar.xz "$work/extras" LICENSE
before=$(inode "$work/cross.tar.xz" 2>/dev/null || true)
expect_success 'cross-format retry with matching include' \
    packaging_repack_archive "$work/tar.gz/producer.tar.gz" tar.gz "$work/cross.tar.xz" tar.xz "$work/extras" LICENSE
[[ -n "$before" && "$(inode "$work/cross.tar.xz" 2>/dev/null)" == "$before" ]] && \
    pass 'cross-format retry preserves destination inode' || fail 'cross-format retry preserves destination inode'
ln -s "$work/input/LICENSE" "$work/extras/linked"
expect_invalid 'symlink include is never reused' \
    packaging_repack_archive "$work/tar.gz/producer.tar.gz" tar.gz "$work/unsafe.tar.gz" tar.gz "$work/extras" linked
expect_invalid 'traversal include is never reused' \
    packaging_repack_archive "$work/tar.gz/producer.tar.gz" tar.gz "$work/unsafe.tar.gz" tar.gz "$work/extras" ../input/LICENSE
mkdir -p "$work/extras/tool"
printf 'collision\n' > "$work/extras/tool/child"
expect_invalid 'include cannot descend through an existing binary' \
    packaging_repack_archive "$work/tar.gz/producer.tar.gz" tar.gz "$work/unsafe.tar.gz" tar.gz "$work/extras" tool/child
[[ ! -e "$work/unsafe.tar.gz" ]] && pass 'unsafe includes create no output' || fail 'unsafe includes create no output'
[[ -z "$(find "$work" -name '.dsr-repack.*' -o -name '.dsr-package.*')" ]] && \
    pass 'all temporary packaging state cleaned' || fail 'temporary state leaked'
printf '\nPrebuilt packaging: %s passed, %s failed, %s skipped\n' "$passed" "$failed" "$skipped"
[[ $failed -eq 0 ]]
