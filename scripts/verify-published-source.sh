#!/usr/bin/env bash
# Read-only consumer audit of DSR's signed source-release assets. This does not
# install, build, publish, extract archives, or use a bundled key as a trust anchor.
set -uo pipefail
python3 - "$@" <<'PY'
import argparse
import gzip
import hashlib
import hmac
import io
import json
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile
import zipfile
import zlib

LIMIT = 256 * 1024**2
TOTAL_LIMIT = 512 * 1024**2
MEMBER_LIMIT = 10000


def need(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    need(path.is_file() and not path.is_symlink(), "nonregular input: " + str(path))
    need(path.stat().st_size <= LIMIT, "oversized input: " + str(path))
    return path.read_bytes()


def sums(data):
    rows = {}
    for line in data.decode("utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]*)", line)
        need(match is not None and match[2] not in rows and ".." not in match[2],
             "malformed or duplicate checksum row")
        rows[match[2]] = match[1]
    return rows


def members(data, fmt, prefix=None):
    """Read a bounded regular-file archive without writing any member to disk."""
    need(len(data) <= LIMIT, "oversized compressed archive")
    result = {}
    seen = set()
    total = 0

    def admit(name, size):
        nonlocal total
        name = name.rstrip("/")
        path = PurePosixPath(name)
        need(name and not path.is_absolute() and str(path) == name and name != "."
             and ".." not in path.parts and "\\" not in name
             and not re.match(r"^[A-Za-z]:", name), "unsafe archive path")
        if prefix is not None:
            need(name == prefix.rstrip("/") or name.startswith(prefix), "archive member outside selected prefix")
        need(name not in seen, "duplicate archive member")
        seen.add(name)
        total += size
        need(len(seen) <= MEMBER_LIMIT and 0 <= size <= LIMIT
             and total <= TOTAL_LIMIT, "archive size/member budget exceeded")
        return name

    if fmt == "tar":
        # tarfile stops at tar EOF before necessarily checking the gzip CRC.
        # Bound the whole stream, including hidden PAX/longname metadata.
        with gzip.GzipFile(fileobj=io.BytesIO(data), mode="rb") as compressed:
            expanded = compressed.read(TOTAL_LIMIT + 1)
        need(len(expanded) <= TOTAL_LIMIT, "decompressed tar budget exceeded")
        with tarfile.open(fileobj=io.BytesIO(expanded), mode="r:") as archive:
            for item in archive:
                need(item.isdir() or item.isfile(), "tar link/special member")
                name = admit(item.name, item.size)
                if item.isfile():
                    with archive.extractfile(item) as stream:
                        blob = stream.read()
                    need(len(blob) == item.size, "truncated tar member")
                    result[name] = (stat.S_IMODE(item.mode), blob)
    else:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            need(len(archive.infolist()) <= MEMBER_LIMIT, "too many ZIP members")
            for item in archive.infolist():
                mode = item.external_attr >> 16
                kind = stat.S_IFMT(mode)
                need(kind in (0, stat.S_IFDIR if item.is_dir() else stat.S_IFREG)
                     and not item.flag_bits & 1, "ZIP link/special/encrypted member")
                need(item.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                     "unsupported ZIP compression method")
                name = admit(item.filename, item.file_size)
                need(not item.is_dir() or item.file_size == 0, "nonempty ZIP directory")
                blob = archive.read(item)
                if not item.is_dir():
                    result[name] = (stat.S_IMODE(mode), blob)
    return result


def git(checkout, *args):
    return subprocess.check_output(["git", "--no-replace-objects", "-C", str(checkout), *args], timeout=60)


def tree_records(checkout, source):
    listing = git(checkout, "ls-tree", "-r", "--full-tree", "-z", source)
    records = {}
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, kind, blob = metadata.decode("ascii").split()
        name = raw_name.decode("utf-8")
        need(mode in ("100644", "100755") and kind == "blob", "unsupported Git source mode: " + name)
        need(name not in records, "duplicate Git source path")
        records[name] = (mode, git(checkout, "cat-file", "blob", blob))
    need(records, "empty source tree")
    return listing, records


def verify(args):
    need(re.fullmatch(r"v\d+\.\d+\.\d+", args.tag), "invalid tag")
    need(re.fullmatch(r"[0-9a-f]{40}", args.source_sha), "invalid source commit")
    need(re.fullmatch(r"[0-9a-f]{64}", args.trusted_key_sha256), "invalid trusted key digest")
    trusted = read(args.public_key)
    need(hmac.compare_digest(digest(trusted), args.trusted_key_sha256), "trusted key digest mismatch")
    peeled = git(args.checkout, "rev-parse", args.tag + "^{commit}").decode().strip()
    need(peeled == args.source_sha, "local peeled tag differs from selected source commit")
    listing, records = tree_records(args.checkout, args.source_sha)
    stem = "doodlestein_self_releaser-" + args.tag
    primary = {stem + ".tar.gz", stem + ".zip", "install.sh", "skill.tar.gz",
               stem + ".spdx.json", "SHA256SUMS"}
    expected = primary | {name + ".minisig" for name in primary} | {"minisign.pub"}
    need(args.bundle.is_dir() and not args.bundle.is_symlink(), "bundle must be a real directory")
    need({p.name for p in args.bundle.iterdir()} == expected, "exact 13-asset contract mismatch")
    before = {name: digest(read(args.bundle / name)) for name in sorted(expected)}
    need(read(args.bundle / "minisign.pub") == trusted, "bundled key differs from independent trusted key")
    for name in sorted(primary):
        subprocess.run(["minisign", "-Vm", str(args.bundle / name), "-x", str(args.bundle / (name + ".minisig")),
                        "-p", str(args.public_key), "-q"], check=True, capture_output=True, timeout=60)
    checksums = sums(read(args.bundle / "SHA256SUMS"))
    need(set(checksums) == primary - {"SHA256SUMS"}, "signed checksum set mismatch")
    need(all(before[name] == value for name, value in checksums.items()), "signed payload checksum mismatch")
    prefix = stem + "/"
    for extension, fmt in ((".tar.gz", "tar"), (".zip", "zip")):
        rows = members(read(args.bundle / (stem + extension)), fmt, prefix)
        need(set(rows) == {prefix + name for name in records}, "source archive member set differs from tagged Git tree")
        for name, (git_mode, blob) in records.items():
            mode, actual = rows[prefix + name]
            # Stock git archive uses 0664/0775 for tar and 0000/0755 for ZIP.
            wanted = (0o775 if git_mode == "100755" else 0o664) if fmt == "tar" \
                else (0o755 if git_mode == "100755" else 0)
            need(actual == blob and mode == wanted, "source archive blob/mode mismatch: " + name)
    skill = members(read(args.bundle / "skill.tar.gz"), "tar")
    need(set(skill) == {"SKILL.md"} and skill["SKILL.md"][1] == records["SKILL.md"][1],
         "skill archive differs from tagged SKILL.md")
    need(read(args.bundle / "install.sh") == records["install.sh"][1], "installer differs from tagged Git blob")
    try:
        sbom = json.loads(read(args.bundle / (stem + ".spdx.json")))
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise ValueError("invalid SPDX JSON") from error
    need(isinstance(sbom, dict) and isinstance(sbom.get("packages"), list)
         and sbom["packages"] and isinstance(sbom["packages"][0], dict), "invalid SPDX package shape")
    package = sbom["packages"][0]
    need(isinstance(package.get("checksums"), list)
         and all(isinstance(row, dict) for row in package["checksums"]), "invalid SPDX checksums shape")
    need(package.get("versionInfo") == args.tag.removeprefix("v")
         and any(row.get("algorithm") == "SHA256" and row.get("checksumValue") == before[stem + ".tar.gz"]
                 for row in package["checksums"]), "SPDX source archive binding mismatch")
    need(before == {name: digest(read(args.bundle / name)) for name in sorted(expected)}
         and {p.name for p in args.bundle.iterdir()} == expected
         and hmac.compare_digest(digest(read(args.public_key)), args.trusted_key_sha256)
         and git(args.checkout, "rev-parse", args.tag + "^{commit}").decode().strip() == peeled
         and git(args.checkout, "ls-tree", "-r", "--full-tree", "-z", args.source_sha) == listing,
         "selected inputs changed during audit")
    return {"status": "PASS", "tag": args.tag, "source_commit": peeled,
            "source_files": len(records), "git_tree_listing_sha256": digest(listing),
            "assets": before, "public_key_sha256": args.trusted_key_sha256,
            "boundary": "signed source bytes, tagged Git blobs/modes and SPDX binding; no installer, upgrade, build or runtime proof"}


def self_test():
    checks = 0
    checksum = "a" * 64
    need(sums((checksum + "  archive.zip\n").encode()) == {"archive.zip": checksum}, "valid checksum rejected")
    checks += 1
    for text in (checksum + "  a\n" + checksum + "  a", checksum + "  ../a", "bad  a"):
        try:
            sums(text.encode())
        except ValueError:
            checks += 1
        else:
            raise ValueError("unsafe checksum accepted")
    for name, kind, size, expected_error in (("../escape", tarfile.REGTYPE, 0, "unsafe"),
                                             ("linked", tarfile.SYMTYPE, 0, "special"),
                                             ("huge", tarfile.REGTYPE, LIMIT + 1, "budget")):
        item = tarfile.TarInfo(name)
        item.type, item.size = kind, size
        malformed = gzip.compress(item.tobuf() + bytes(1024))
        try:
            members(malformed, "tar")
        except ValueError as error:
            need(expected_error in str(error), "wrong archive rejection")
            checks += 1
        else:
            raise ValueError("unsafe tar accepted")
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        item = zipfile.ZipInfo("linked")
        item.create_system = 3
        item.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(item, b"target")
    try:
        members(stream.getvalue(), "zip")
    except ValueError as error:
        need("special" in str(error), "wrong ZIP rejection")
        checks += 1
    else:
        raise ValueError("ZIP symlink accepted")
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        item = tarfile.TarInfo("ordinary")
        item.size = 7
        archive.addfile(item, io.BytesIO(b"fixture"))
    need(members(stream.getvalue(), "tar")["ordinary"][1] == b"fixture", "valid tar rejected")
    checks += 1
    corrupt = bytearray(stream.getvalue())
    corrupt[-8] ^= 1
    try:
        members(bytes(corrupt), "tar")
    except gzip.BadGzipFile:
        checks += 1
    else:
        raise ValueError("invalid gzip CRC accepted")
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        archive.writestr("ordinary", b"fixture")
    for method in (14, 99):
        unsupported = bytearray(stream.getvalue())
        central = unsupported.index(b"PK\x01\x02")
        unsupported[8:10] = method.to_bytes(2, "little")
        unsupported[central + 10:central + 12] = method.to_bytes(2, "little")
        try:
            members(bytes(unsupported), "zip")
        except ValueError as error:
            need("compression" in str(error), "wrong ZIP compression refusal")
            checks += 1
        else:
            raise ValueError("unsupported ZIP compression accepted")
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        archive.writestr("metadata/", b"hidden body")
    try:
        members(stream.getvalue(), "zip")
    except ValueError as error:
        need("directory" in str(error), "wrong ZIP directory refusal")
        checks += 1
    else:
        raise ValueError("ZIP directory payload accepted")
    return {"status": "PASS", "self_test_checks": checks, "boundary": "local checksum and unsafe archive rejection controls"}


parser = argparse.ArgumentParser(description="Audit downloaded signed DSR source assets without extracting or executing them")
parser.add_argument("--self-test", action="store_true")
parser.add_argument("--bundle", type=Path)
parser.add_argument("--checkout", type=Path)
parser.add_argument("--tag")
parser.add_argument("--source-sha")
parser.add_argument("--public-key", type=Path)
parser.add_argument("--trusted-key-sha256")
options = parser.parse_args()
if not options.self_test and not all((options.bundle, options.checkout, options.tag,
                                     options.source_sha, options.public_key, options.trusted_key_sha256)):
    parser.error("all six bundle/source/trust options are required unless --self-test is selected")
try:
    print(json.dumps(self_test() if options.self_test else verify(options), indent=2))
except (ValueError, OSError, KeyError, IndexError, RuntimeError, zlib.error,
        subprocess.SubprocessError, tarfile.TarError, zipfile.BadZipFile) as error:
    print(json.dumps({"status": "FAIL", "error": str(error)}))
    sys.exit(1)
PY
