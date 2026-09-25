#!/usr/bin/env bash
# Real independent archive builds, not repeated reads of a cached destination.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/src/packaging.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
passed=0 failed=0 skipped=0
pass() { printf 'PASS %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf 'FAIL %s\n' "$*" >&2; failed=$((failed + 1)); }
inode() { stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"; }
run_ok() {
    local label="$1" rc; shift
    "$@" > "$work/stdout" 2> "$work/stderr"; rc=$?
    if [[ $rc -eq 0 && ! -s "$work/stdout" ]]; then
        pass "$label"
    else
        fail "$label: exit $rc"
        cat "$work/stderr" >&2
    fi
}
run_invalid() {
    local label="$1" rc; shift
    "$@" > "$work/stdout" 2> "$work/stderr"; rc=$?
    [[ $rc -eq 4 && ! -s "$work/stdout" ]] && pass "$label" || fail "$label: expected 4, got $rc"
}
equal() { cmp -s "$2" "$3" && pass "$1" || fail "$1"; }
different() { [[ -s "$2" && -s "$3" ]] && ! cmp -s "$2" "$3" && pass "$1" || fail "$1"; }
for tool in python3 tar gzip xz cmp stat; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done

# Same payload in different creation order, with different ownership when
# privileged, mtimes and irrelevant mode bits. Do not normalize sources first.
python3 - "$work" <<'PY'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
files = {'tool': b'#!/bin/sh\necho reproducible\n', 'LICENSE': b'license\n',
         'docs/' + 'long-' * 24 + 'guide with spaces': b'guide\n' * 4096}
before = {}
for lane, order, mtime in [('one', files, 1000000000), ('two', reversed(files), 1900000000)]:
    for name in order:
        p = root / lane / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(files[name])
        p.chmod((0o4755 if lane == 'one' else 0o755) if name == 'tool' else (0o640 if lane == 'one' else 0o600))
        if lane == 'two' and os.geteuid() == 0:
            os.chown(p, 12345, 12346)
        os.utime(p, (mtime, mtime))
        s = p.stat()
        before[str(p)] = [s.st_mode, s.st_uid, s.st_gid, s.st_mtime_ns]
(root / 'before.json').write_text(json.dumps(before))
PY

build_one() (export SOURCE_DATE_EPOCH=1700000001 TZ=UTC; umask 022; packaging_build_archive "$1" "$2" "$work/one" tool docs LICENSE)
build_two() (export SOURCE_DATE_EPOCH=1700000001 TZ=Pacific/Kiritimati; umask 077; packaging_build_archive "$1" "$2" "$work/two" LICENSE docs tool tool)

for format in tar.gz tar.xz zip; do
    if [[ "$format" == zip ]] && { ! command -v zip >/dev/null || ! command -v unzip >/dev/null; }; then
        printf 'SKIP zip: install zip and unzip\n'; skipped=$((skipped + 1)); continue
    fi
    dir="$work/$format"
    mkdir "$dir"
    first="$dir/first.$format" second="$dir/second.$format"
    run_ok "$format first fresh build" build_one "$format" "$first"
    run_ok "$format independent reordered build" build_two "$format" "$second"
    equal "$format identical bytes across independent build trees" "$first" "$second"
    run_ok "$format accepted by existing archive validator" packaging_validate_archive "$first" "$format"
    mkdir "$dir/extracted"
    run_ok "$format real extraction" packaging_extract_payload "$first" "$format" "$dir/extracted"
    equal "$format executable payload round trip" "$work/one/tool" "$dir/extracted/tool"
    if python3 - "$first" "$format" <<'PY'
import datetime, pathlib, stat, struct, sys, tarfile, zipfile
p, fmt = pathlib.Path(sys.argv[1]), sys.argv[2]
epoch = 1700000001
expected = ['LICENSE', 'docs/' + 'long-' * 24 + 'guide with spaces', 'tool']
if fmt == 'zip':
    with zipfile.ZipFile(p) as z:
        assert z.namelist() == expected, z.namelist()
        for m in z.infolist():
            assert m.date_time == (2023, 11, 14, 22, 13, 20), m.date_time
            assert m.create_system == 3 and not m.extra and not m.comment
            assert m.compress_type == zipfile.ZIP_DEFLATED
            assert (m.external_attr >> 16) == stat.S_IFREG | (0o755 if m.filename == 'tool' else 0o644)
else:
    with tarfile.open(p) as t:
        assert t.getnames() == expected, t.getnames()
        for m in t.getmembers():
            assert m.isfile() and m.mtime == epoch
            assert m.uid == m.gid == 0 and m.uname == m.gname == ''
            assert m.mode == (0o755 if m.name == 'tool' else 0o644)
            assert set(m.pax_headers) <= {'path'}
    if fmt == 'tar.gz':
        header = p.read_bytes()[:10]
        assert header[3] == 0, 'gzip filename/extra/comment unexpectedly embedded'
        assert struct.unpack('<I', header[4:8])[0] == epoch
PY
    then pass "$format independent metadata inspection"; else fail "$format metadata inspection"; fi

    # Existing verified bytes are authoritative even when another epoch is
    # selected. This is intentionally not an in-place recompression command.
    before=$(inode "$first" 2>/dev/null || true)
    run_ok "$format changed epoch does not rewrite verified archive" \
        env SOURCE_DATE_EPOCH=1 bash -c 'source "$1"; packaging_build_archive "$2" "$3" "$4" tool docs LICENSE' _ \
        "$ROOT/src/packaging.sh" "$format" "$first" "$work/one"
    [[ -n "$before" && "$(inode "$first" 2>/dev/null)" == "$before" ]] && \
        pass "$format verified reuse retains inode" || fail "$format verified reuse retains inode"
    run_ok "$format producer archive remains authoritative" \
        env SOURCE_DATE_EPOCH=2 bash -c 'source "$1"; packaging_repack_archive "$2" "$3" "$4" "$3"' _ \
        "$ROOT/src/packaging.sh" "$first" "$format" "$dir/alias.$format"
    equal "$format exact compressed producer alias" "$first" "$dir/alias.$format"

    cp -R "$work/one" "$dir/changed"
    printf 'different executable\n' > "$dir/changed/tool"
    run_ok "$format changed binary can be packaged" \
        env SOURCE_DATE_EPOCH=1700000001 bash -c 'source "$1"; packaging_build_archive "$2" "$3" "$4" tool docs LICENSE' _ \
        "$ROOT/src/packaging.sh" "$format" "$dir/changed.$format" "$dir/changed"
    different "$format changed bytes change the archive" "$first" "$dir/changed.$format"
    cp "$work/one/tool" "$dir/changed/tool"
    chmod 0644 "$dir/changed/tool"
    run_ok "$format changed executable bits can be packaged" \
        env SOURCE_DATE_EPOCH=1700000001 bash -c 'source "$1"; packaging_build_archive "$2" "$3" "$4" tool docs LICENSE' _ \
        "$ROOT/src/packaging.sh" "$format" "$dir/mode.$format" "$dir/changed"
    different "$format executable bits change the archive" "$first" "$dir/mode.$format"

    for epoch in 0 4294967295; do
        run_ok "$format accepts epoch boundary $epoch" \
            env SOURCE_DATE_EPOCH="$epoch" bash -c 'source "$1"; packaging_build_archive "$2" "$3" "$4" tool' _ \
            "$ROOT/src/packaging.sh" "$format" "$dir/epoch-$epoch.$format" "$work/one"
    done
    if [[ "$format" == zip ]]; then
        if python3 - "$dir/epoch-0.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    assert z.getinfo('tool').date_time == (1980, 1, 1, 0, 0, 0)
PY
        then pass 'ZIP clamps pre-1980 timestamp'; else fail 'ZIP timestamp clamp'; fi
    fi
    for epoch in '' -1 1.5 abc 4294967296 999999999999999999999999999 1+2 ' 1' $'1\n'; do
        run_invalid "$format rejects invalid epoch [$epoch] even on reuse" \
            env SOURCE_DATE_EPOCH="$epoch" bash -c 'source "$1"; packaging_build_archive "$2" "$3" "$4" tool docs LICENSE' _ \
            "$ROOT/src/packaging.sh" "$format" "$first" "$work/one"
    done
    equal "$format invalid policy never changes existing archive" "$first" "$second"
done

# Cross-format conversion reaches the same deterministic archive builder.
run_ok 'repack uses deterministic construction for another format' \
    env SOURCE_DATE_EPOCH=1700000001 bash -c 'source "$1"; packaging_repack_archive "$2" tar.gz "$3" tar.xz' _ \
    "$ROOT/src/packaging.sh" "$work/tar.gz/first.tar.gz" "$work/from-source.tar.xz"
equal 'repack matches independently built tar.xz' "$work/from-source.tar.xz" "$work/tar.xz/first.tar.xz"

# Narrow dependency boundary fixture; archive creation and failure cleanup are
# real. A missing optional interpreter cannot truncate a prior destination.
printf 'previous artifact\n' > "$work/protected.tar.gz"
cp "$work/protected.tar.gz" "$work/prior"
if (
    export SOURCE_DATE_EPOCH=0
    command() {
        [[ "${1:-}" != -v || "${2:-}" != python3 ]] || return 1
        builtin command "$@"
    }
    packaging_build_archive tar.gz "$work/protected.tar.gz" "$work/one" tool
) > "$work/stdout" 2> "$work/stderr"; then
    fail 'missing Python is a dependency error'
else
    [[ $? -eq 3 ]] && pass 'missing Python is a dependency error' || fail 'missing Python exit code'
fi
equal 'dependency failure preserves previous bytes' "$work/prior" "$work/protected.tar.gz"

if python3 - "$work/before.json" <<'PY'
import json, os, sys
for path, before in json.load(open(sys.argv[1])).items():
    s = os.stat(path)
    assert [s.st_mode, s.st_uid, s.st_gid, s.st_mtime_ns] == before, path
PY
then pass 'source metadata never modified'; else fail 'source metadata modified'; fi
[[ -z "$(find "$work" -name '.dsr-package.*' -o -name '.dsr-repack.*')" ]] && \
    pass 'staging cleaned on success and failure' || fail 'staging cleanup'
printf '\nReproducible packaging: %s passed, %s failed, %s skipped\n' "$passed" "$failed" "$skipped"
[[ $failed -eq 0 ]]
