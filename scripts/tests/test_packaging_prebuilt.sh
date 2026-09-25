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
        [[ "$mode" == 654 ]] && pass "$format retains exact include executable bits" || fail "$format include mode: $mode"
        actual=$(packaging_payload_members "$extended" "$format")
        [[ "$actual" == $'LICENSE\nNOTICE\ndocs/guide.txt\nhelper\ntool' ]] && \
            pass "$format exact complete member set" || fail "$format complete member set"
    else
        fail "$format extended archive extraction"
    fi
    expect_equal "$format never changes producer archive" "$source_archive" "$dir/original"

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
