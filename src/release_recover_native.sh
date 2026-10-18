#!/usr/bin/env bash
# Recover ordinary, completed native payloads after coordinator packaging fails.
# This is an explicit local import, not a strict-build attestation or a release
# upload. Original state, worker receipts and artifacts are never modified.

_native_recovery_execute() {
    command -v python3 >/dev/null || return 3
    exec env DRY_RUN="${DRY_RUN:-false}" python3 -I - "$@" <<'PY'
import argparse
import datetime
import gzip
import hashlib
import json
import lzma
import os
from pathlib import Path
import re
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import uuid
import zipfile
import zlib


class Failure(Exception):
    def __init__(self, message, code=7):
        super().__init__(message)
        self.code = code


def need(ok, message, code=7):
    if not ok:
        raise Failure(message, code)


def match(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def name(value):
    return match(value, r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}") and ".." not in value


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def pairs(items):
    value = {}
    for key, item in items:
        need(key not in value, "duplicate JSON member: " + key, 4)
        value[key] = item
    return value


def document(data):
    return json.loads(data, object_pairs_hook=pairs,
        parse_constant=lambda _: (_ for _ in ()).throw(Failure("non-finite JSON number", 4)))


def path(value):
    need(isinstance(value, str) and value.startswith("/") and value != "/" and
         not any(ord(c) < 32 or ord(c) == 127 or c == "\\" for c in value) and
         all(p not in ("", ".", "..") for p in value[1:].split("/")), "noncanonical absolute path", 4)
    result = Path(value)
    for part in [*reversed(result.parents), result]:
        need(not part.is_symlink(), "symlink in selected path: " + str(part), 4)
        if part != result:
            need(part.is_dir(), "missing parent directory: " + str(part), 4)
    return result


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def read_file(selected, expected=None, destination=None, limit=64 * 1024 * 1024):
    selected = path(str(selected))
    before = selected.lstat()
    need(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 < before.st_size <= limit,
         "missing, linked, empty or excessive input: " + str(selected))
    if expected is not None:
        need(before.st_size == expected["size_bytes"], "artifact size differs from worker receipt")
        claimed = expected["identity"]
        actual = ("gnu:%d:%d" % (before.st_dev, before.st_ino) if claimed.startswith("gnu:")
                  else "bsd:%d" % before.st_ino)
        need(claimed == actual, "artifact inode differs from worker receipt: " + str(selected))
    fd = os.open(selected, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    digest, data, size = hashlib.sha256(), bytearray(), 0
    with os.fdopen(fd, "rb") as incoming:
        need(identity(os.fstat(incoming.fileno())) == identity(before), "input replaced before reading")
        outgoing = destination.open("xb") if destination is not None else None
        try:
            for block in iter(lambda: incoming.read(1024 * 1024), b""):
                size += len(block)
                need(size <= limit, "input grew beyond its size limit")
                digest.update(block)
                if expected is None:
                    data.extend(block)
                elif len(data) < 4096:
                    data.extend(block[:4096 - len(data)])
                if outgoing is not None:
                    outgoing.write(block)
            if outgoing is not None:
                outgoing.flush()
                os.fsync(outgoing.fileno())
        finally:
            if outgoing is not None:
                outgoing.close()
        need(size == before.st_size and
             identity(os.fstat(incoming.fileno())) == identity(before) == identity(selected.lstat()),
             "input changed during recovery: " + str(selected))
    if expected is not None:
        need(digest.hexdigest() == expected["sha256"], "artifact digest differs from worker receipt: " + str(selected))
    return bytes(data), digest.hexdigest(), before


def binary_platform(data):
    # Architecture checks do not claim libc, minimum-OS or dependency parity.
    if data[:4] == b"\x7fELF" and len(data) >= 64 and data[5] in (1, 2):
        order = "<" if data[5] == 1 else ">"
        kind, machine = struct.unpack_from(order + "HH", data, 16)
        need(kind in (2, 3), "ELF payload is not an executable")
        return {(1, 3): "linux/386", (2, 62): "linux/amd64", (2, 183): "linux/arm64"}.get((data[4], machine))
    if data[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe") and len(data) >= 32:
        cpu, _, kind = struct.unpack_from("<III", data, 4)
        need(kind == 2, "Mach-O payload is not an executable")
        return {0x1000007: "darwin/amd64", 0x100000c: "darwin/arm64"}.get(cpu)
    if data[:2] == b"MZ" and len(data) >= 64:
        offset = struct.unpack_from("<I", data, 60)[0]
        need(64 <= offset <= len(data) - 26 and data[offset:offset + 4] == b"PE\0\0", "invalid PE header")
        machine = struct.unpack_from("<H", data, offset + 4)[0]
        flags, magic = struct.unpack_from("<HH", data, offset + 22)
        need(flags & 2 and not flags & 0x2000 and magic in (0x10b, 0x20b), "PE payload is not an executable")
        return {(0x14c, 0x10b): "windows/386", (0x8664, 0x20b): "windows/amd64",
                (0xaa64, 0x20b): "windows/arm64"}.get((machine, magic))
    raise Failure("raw native recovery requires ELF, Mach-O or PE executables; archives and scripts are not imported", 4)


def archive_format(filename):
    for extension, format_name in ((".tar.gz", "tar.gz"), (".tgz", "tar.gz"),
                                   (".tar.xz", "tar.xz"), (".zip", "zip")):
        if filename.endswith(extension):
            return extension, format_name
    return "", "binary"


def valid_receipt(receipt):
    return (isinstance(receipt, dict) and set(receipt) == {"path", "sha256", "size_bytes", "identity"} and
            isinstance(receipt["path"], str) and match(receipt["sha256"], r"[0-9a-f]{64}") and
            type(receipt["size_bytes"]) is int and 0 < receipt["size_bytes"] <= args.max_artifact_bytes and
            match(receipt["identity"], r"(?:gnu:[0-9]+:[1-9][0-9]*|bsd:[1-9][0-9]*)"))


def companion_name(filename):
    # Renaming a payload invalidates filename-bearing checksum/provenance
    # metadata. Do not copy it unchanged or manufacture a fresh attestation.
    lower = filename.lower()
    return (name(filename) and not lower.startswith("sha256sums") and lower != "checksums.txt" and
            not lower.endswith((".sha256", ".sha512", ".minisig", ".sig", ".asc", ".intoto.jsonl")) and
            ".sbom." not in lower and not lower.endswith("manifest.json"))


def inspect_archive(selected, admitted_info, format_name, platform):
    """Inspect authenticated archive bytes without extracting any member."""
    nodes, files, executables = {}, [], []
    expanded = records = 0

    def member_path(value, directory):
        need(isinstance(value, str) and 0 < len(value) <= 4096 and
             not any(ord(c) < 32 or ord(c) == 127 or c in "\\:" for c in value),
             "unsafe archive member path", 4)
        if directory and value in (".", "./"):
            return None
        need(not value.startswith("/"), "absolute archive member: " + value, 4)
        if value.startswith("./"):
            value = value[2:]
        if directory and value.endswith("/"):
            value = value[:-1]
        parts = value.split("/")
        need(all(p not in ("", ".", "..") and not p.startswith("-") and
                 p.lower() != ".git" and not p.endswith((".", " ")) for p in parts),
             "unsafe archive member: " + value, 4)
        for index in range(1, len(parts)):
            parent = "/".join(parts[:index])
            key = parent.casefold()
            previous = nodes.get(key)
            need(previous is None or previous[:2] == (parent, "directory"),
                 "archive member collides with a parent: " + value, 4)
            if previous is None:
                nodes[key] = (parent, "directory", False)
        kind = "directory" if directory else "file"
        previous = nodes.get(value.casefold())
        need(previous is None or (directory and previous == (value, kind, False)),
             "duplicate or case-colliding archive member: " + value, 4)
        nodes[value.casefold()] = (value, kind, True)
        return value

    def consume(filename, size, mode, directory, opener):
        nonlocal expanded, records
        records += 1
        need(records <= args.max_archive_members, "archive member limit exceeded", 4)
        relative = member_path(filename, directory)
        need(not mode & 0o7000, "privileged archive member mode: " + filename, 4)
        if directory:
            need(size == 0, "archive directory has a payload", 4)
            return
        need(relative is not None and 0 <= size <= args.max_unpacked_bytes - expanded,
             "archive expanded-byte limit exceeded", 4)
        digest, prefix, actual = hashlib.sha256(), bytearray(), 0
        with opener() as stream:
            while True:
                block = stream.read(min(1024 * 1024, size - actual + 1))
                if not block:
                    break
                actual += len(block)
                need(actual <= size, "archive member grew beyond its declared size", 4)
                digest.update(block)
                if len(prefix) < 4096:
                    prefix.extend(block[:4096 - len(prefix)])
        need(actual == size, "truncated archive member: " + relative, 4)
        expanded += actual
        data = bytes(prefix)
        if (data.startswith((b"\x7fELF", b"MZ", b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe")) or
                relative.lower().endswith(".exe")):
            need(binary_platform(data) == platform,
                 "archive executable architecture differs from its worker target: " + relative, 4)
            need(platform.startswith("windows/") or mode & 0o111,
                 "Unix archive executable has no executable bits: " + relative, 4)
            executables.append(relative)
        files.append(dict(path=relative, sha256=digest.hexdigest(), size_bytes=size,
                          executable_bits=mode & 0o111))

    class BoundedReader:
        # Bound tar padding and extended metadata too, not just regular files.
        def __init__(self, stream):
            self.stream = stream
            self.remaining = args.max_unpacked_bytes + args.max_archive_members * 2048 + 1024 * 1024

        def read(self, size):
            data = self.stream.read(min(size, self.remaining + 1, 1024 * 1024))
            self.remaining -= len(data)
            need(self.remaining >= 0, "expanded tar stream exceeds its byte budget", 4)
            return data

    class BoundedTarInfo(tarfile.TarInfo):
        @classmethod
        def frombuf(cls, buf, encoding, errors):
            item = super().frombuf(buf, encoding, errors)
            # frombuf runs before tarfile reads PAX/GNU extension payloads.
            need(item.type != tarfile.GNUTYPE_SPARSE, "sparse archive members are unsupported", 4)
            if item.type in (tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK):
                need(0 <= item.size <= 65536, "excessive archive extended header", 4)
            return item

    selected = path(str(selected))
    fd = os.open(selected, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        need(identity(os.fstat(stream.fileno())) == identity(admitted_info) == identity(selected.lstat()),
             "archive changed before inspection")
        if format_name == "zip":
            # Bound the central directory BEFORE ZipFile allocates its list.
            # ZIP64 and split archives are deliberately not admitted here.
            size = admitted_info.st_size
            stream.seek(max(0, size - 65557))
            tail = stream.read(65557)
            end = tail.rfind(b"PK\x05\x06")
            need(end >= 0 and len(tail) - end >= 22, "missing ZIP end record", 4)
            _, disk, start_disk, count, total, directory_size, offset, comment = struct.unpack_from("<4s4H2IH", tail, end)
            need(disk == start_disk == 0 and count == total and 0 < total <= args.max_archive_members and
                 total != 65535 and directory_size <= 16 * 1024 * 1024 and offset != 0xffffffff and
                 len(tail) - end == 22 + comment and offset + directory_size == size - len(tail) + end,
                 "unsupported or excessive ZIP directory", 4)
            stream.seek(0)
            with zipfile.ZipFile(stream) as archive:
                need(len(archive.infolist()) == total, "ZIP member count differs from directory", 4)
                for item in archive.infolist():
                    mode = item.external_attr >> 16
                    directory = item.is_dir()
                    need(not item.flag_bits & 1 and item.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED) and
                         stat.S_IFMT(mode) in (0, stat.S_IFDIR if directory else stat.S_IFREG),
                         "linked, encrypted or unsupported ZIP member: " + item.filename, 4)
                    need(item.orig_filename == item.filename, "NUL in ZIP member name", 4)
                    consume(item.filename, item.file_size, mode, directory, lambda: archive.open(item))
        else:
            decompressor = gzip.GzipFile(fileobj=stream) if format_name == "tar.gz" else lzma.LZMAFile(stream)
            with decompressor:
                with tarfile.open(fileobj=BoundedReader(decompressor), mode="r|", tarinfo=BoundedTarInfo) as archive:
                    for item in archive:
                        need((item.isfile() or item.isdir()) and not item.issparse() and
                             not any(k.startswith("GNU.sparse") for k in item.pax_headers),
                             "linked, sparse or special tar member: " + item.name, 4)
                        consume(item.name, item.size, item.mode, item.isdir(), lambda: archive.extractfile(item))
                    # Drain through tarfile's buffered reader, including the
                    # compressor trailer/CRC, and refuse hidden appended data.
                    while True:
                        tail = archive.fileobj.read(1024 * 1024)
                        if not tail:
                            break
                        need(not any(tail), "nonzero data after tar end marker", 4)
        need(identity(os.fstat(stream.fileno())) == identity(admitted_info) == identity(selected.lstat()),
             "archive changed during inspection")
    need(files and executables, "archive contains no native executable for its target", 4)
    files.sort(key=lambda row: row["path"])
    return dict(kind="dsr-native-archive-inventory", archive_format=format_name, files=files,
                executable_members=sorted(executables), unpacked_bytes=expanded,
                inventory_sha256=hashlib.sha256(canonical(files)).hexdigest())


def git_read(repository, *arguments):
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    environment.update(GIT_NO_REPLACE_OBJECTS="1", GIT_NO_LAZY_FETCH="1", GIT_ALLOW_PROTOCOL="",
        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_OPTIONAL_LOCKS="0",
        GIT_TERMINAL_PROMPT="0", LC_ALL="C")
    command = ["git", "-c", "core.hooksPath=" + os.devnull, "-c", "core.fsmonitor=false",
               "-c", "protocol.allow=never", "-C", str(repository), *arguments]
    try:
        output = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=environment, timeout=30, check=True)
    except FileNotFoundError:
        raise Failure("Git is required to check the selected release tag", 3)
    except subprocess.TimeoutExpired:
        raise Failure("source identity check timed out", 5)
    except subprocess.CalledProcessError:
        raise Failure("cannot verify the selected repository/tag", 4)
    return output.stdout.decode("utf-8").rstrip("\n")


def triple_platform(triple):
    arch = {"x86_64": "amd64", "aarch64": "arm64", "i686": "386", "i586": "386"}.get(triple.split("-", 1)[0])
    operating_system = ("linux" if "-linux-" in triple else "darwin" if triple.endswith("-apple-darwin")
                        else "windows" if "-windows-" in triple else None)
    return operating_system + "/" + arch if operating_system and arch else None


def source_identity():
    need(git_read(source_repo, "rev-parse", "--show-toplevel") == str(source_repo),
         "source-repo must be the Git worktree root", 4)
    origin = git_read(source_repo, "config", "--get", "remote.origin.url")
    need(origin in {prefix + args.repo + suffix for prefix in
         ("https://github.com/", "git@github.com:", "ssh://git@github.com/") for suffix in ("", ".git")},
         "source origin differs from selected repository", 4)
    need(git_read(source_repo, "rev-parse", "--verify", "refs/tags/" + args.tag + "^{commit}") == args.sha,
         "release tag differs from the selected source commit", 4)


def timestamp(value):
    need(match(value, r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"),
         "completed target has no valid recorded timestamp", 4)
    datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    return value


def select_workers(state):
    need(isinstance(state, dict) and match(state.get("tool"), r"[a-z][a-z0-9_-]*") and
         state.get("version") in (args.tag, args.tag[1:]) and state.get("git_sha") == args.sha and
         state.get("git_ref") in (args.tag, "refs/tags/" + args.tag), "state does not match selected release", 4)
    # The scheduler seals successful workers as targets-complete and releases
    # its orchestration lock BEFORE cmd_build collects/packages their output.
    # A failure in that handoff leaves this exact checkpoint, not "failed".
    # Admit it only through the same complete-worker and frozen-byte checks
    # below; never rewrite the original checkpoint to claim a completed build.
    need(state.get("status") in ("failed", "partial", "targets-complete", "completed"),
         "active, pending or cancelled builds cannot be recovered", 2)
    need(str(uuid.UUID(state["run_id"])) == state["run_id"], "invalid build run UUID", 4)
    context, statuses, targets = state["context"], state["target_statuses"], state["targets"]
    need(context.get("build_purpose") == "release" and context.get("publishable") is True,
         "diagnostic or unclassified builds cannot become releases", 4)
    tasks = context["build_tasks"]
    need(isinstance(tasks, list) and 1 <= len(tasks) <= 256 and isinstance(statuses, dict) and
         isinstance(targets, list) and targets and all(match(t, r"(linux|darwin|windows)/(amd64|arm64|386)") for t in targets) and
         len(set(targets)) == len(targets), "invalid native task matrix", 4)
    need(all(isinstance(t, dict) and set(t) == {"key", "platform", "target_triple", "method"} and
         t["method"] == "native" and isinstance(t["platform"], str) and t["platform"] in targets and
         isinstance(t["target_triple"], str) and (not t["target_triple"] or name(t["target_triple"])) and
         (t["key"] == t["platform"] or
          (t["target_triple"] and t["key"] == t["platform"] + "@" + t["target_triple"])) for t in tasks),
         "recovery supports only complete native task plans", 4)
    need(len({t["key"] for t in tasks}) == len(tasks) and set(statuses) == {t["key"] for t in tasks} and
         {t["platform"] for t in tasks} == set(targets) and
         len({(t["platform"], t["target_triple"]) for t in tasks}) == len(tasks), "incomplete or duplicated task matrix", 4)
    for platform in targets:
        variants = [t for t in tasks if t["platform"] == platform]
        need(len(variants) == 1 or all(t["target_triple"] and
             t["key"] == platform + "@" + t["target_triple"] for t in variants),
             "same-platform variants require explicit compiler task identities", 4)
    selected, names, originals = [], {}, {}
    for task in sorted(tasks, key=lambda t: t["key"]):
        saved = statuses[task["key"]]
        result = saved["result"]
        completed_at = timestamp(saved.get("updated_at"))
        need(saved.get("status") == "completed" and result.get("status") == "success" and
             type(result.get("exit_code")) is int and result["exit_code"] == 0 and
             result.get("method") == "native" and result.get("platform") == task["platform"] and
             result.get("task_key") == task["key"] and result.get("build_purpose") == "release" and
             result.get("publishable") is True and result.get("tool") == state["tool"],
             "every requested native worker must have completed successfully", 4)
        need(isinstance(result.get("host"), str) and result["host"] and saved.get("host") == result["host"],
             "worker host is not bound to completed state", 4)
        bound = context.get("target_hosts", {}).get(task["platform"])
        need(bound is None or bound == result["host"], "worker host differs from the planned host", 4)
        # Native Go receipts encode an absent triple as null, while the frozen
        # task plan uses an empty string. Do not coerce arbitrary falsey data.
        triple = result.get("target_triple")
        need(triple is None or isinstance(triple, str), "invalid worker compiler target", 4)
        triple = "" if triple is None else triple
        need(triple == task["target_triple"], "worker compiler target differs from the task plan", 4)
        need(not triple or triple_platform(triple) == task["platform"], "compiler target contradicts its routing platform", 4)
        isolation = result.get("cargo_isolation")
        influence = result.get("build_influence_env", {})
        need((isolation is None or isinstance(isolation, dict)) and isinstance(influence, dict) and
             all(isinstance(k, str) and isinstance(v, str) for k, v in influence.items()), "invalid native build evidence", 4)
        need(not (isolation and str(isolation.get("mode", "")).startswith("strict")) and
             not influence.get("DSR_RELEASE_GIT_SHA") and not result.get("release_contract"),
             "strict-contract builds must use their original strict finalization path", 4)
        if triple:
            need(all(influence.get(k, triple) == triple for k in ("CARGO_BUILD_TARGET", "DSR_TARGET_TRIPLE")) and
                 (not isolation or isolation.get("toolchain", {}).get("target_triple", triple) == triple),
                 "compiler target contradicts retained build evidence", 4)
        receipts = result.get("resume_artifacts")
        primaries, additional = result.get("artifact_paths"), result.get("additional_artifacts", [])
        need(isinstance(primaries, list) and 1 <= len(primaries) <= 256 and
             all(isinstance(p, str) and p for p in primaries) and len(set(primaries)) == len(primaries) and
             result.get("artifact_path") == ",".join(primaries) and not result.get("artifact_dir"),
             "worker primary array is missing, duplicated or inconsistent", 4)
        need(isinstance(additional, list) and len(additional) <= 256 and all(valid_receipt(r) for r in additional),
             "invalid additional-artifact receipt inventory", 4)
        extra_paths = [r["path"] for r in additional]
        need(len(set(extra_paths)) == len(extra_paths) and not set(extra_paths) & set(primaries),
             "additional assets duplicate primaries or each other", 4)
        need(isinstance(receipts, list) and len(receipts) == len(primaries) + len(additional) and
             all(valid_receipt(r) for r in receipts) and len({r["path"] for r in receipts}) == len(receipts),
             "invalid or incomplete worker receipt inventory", 4)
        by_path = {r["path"]: r for r in receipts}
        need(set(by_path) == set(primaries) | set(extra_paths) and
             all(by_path[r["path"]] == r for r in additional),
             "worker artifact inventory differs from its frozen receipts", 4)
        for selected_path in sorted(by_path):
            receipt = by_path[selected_path]
            original = path(selected_path)
            role = "primary" if selected_path in primaries else "additional"
            need(original.is_relative_to(artifacts_root) and original != artifacts_root,
                 "worker artifact escapes the selected root", 4)
            previous = originals.get(original)
            need(previous is None or (role == "additional" and previous == (role, receipt)),
                 "worker artifact is shared by distinct primary tasks or roles", 4)
            originals[original] = (role, receipt)
            if role == "primary":
                extension, format_name = archive_format(original.name)
                stem = original.name[:-len(extension)] if extension else (
                    original.name[:-4] if original.name.lower().endswith(".exe") else original.name)
                suffix = triple if triple else task["platform"].replace("/", "_")
                published = stem + "-" + suffix + (extension or (".exe" if task["platform"].startswith("windows/") else ""))
            else:
                published, format_name = original.name, "none"
                need(companion_name(published), "additional attestation or unsafe name cannot be recovered unchanged", 4)
            need(name(published), "unsafe recovered asset name", 4)
            descriptor = (published, role, receipt["sha256"], receipt["size_bytes"])
            previous = names.get(published.casefold())
            need(previous is None or (role == "additional" and previous == descriptor),
                 "colliding recovered asset name or conflicting companion content", 4)
            names[published.casefold()] = descriptor
            selected.append(dict(task=task, result=result, receipt=receipt, path=original, name=published,
                                 completed_at=completed_at, format=format_name, role=role))
    return selected


def check_artifact(worker, destination=None):
    data, _, info = read_file(worker["path"], worker["receipt"], destination, args.max_artifact_bytes)
    observed = identity(info)
    need(worker.get("admitted_identity", observed) == observed, "artifact metadata changed during recovery")
    worker["admitted_identity"] = observed
    if worker["format"] == "binary":
        need(binary_platform(data) == worker["task"]["platform"], "executable architecture differs from its worker target: " + worker["name"])
        executable = bool(info.st_mode & 0o111)
        need(executable or worker["task"]["platform"].startswith("windows/"), "Unix payload is not executable")
    elif worker["format"] == "none":
        # Companions are copied as opaque assets, never executed or asserted
        # to be a native build for every platform sharing their name.
        need(not data.startswith((b"\x7fELF", b"MZ", b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe")) and
             not worker["name"].lower().endswith(".exe"),
             "native executables must be declared as primary outputs", 4)
        executable = bool(info.st_mode & 0o111)
    else:
        evidence = inspect_archive(worker["path"], info, worker["format"], worker["task"]["platform"])
        need(worker.get("archive_inventory", evidence) == evidence, "archive inventory changed during recovery")
        worker["archive_inventory"] = evidence
        executable = False
    mode = (0o644 | (info.st_mode & 0o111)) if executable else 0o644
    if destination is not None:
        destination.chmod(mode)
    return mode


def save(destination, data):
    with destination.open("xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
        saved_identity = identity(os.fstat(stream.fileno()))
    need(identity(destination.lstat()) == saved_identity, "recovery document replaced while writing")
    return saved_identity


def retain_document(destination, data, reuse):
    if not reuse:
        return save(destination, data)
    retained, _, info = read_file(destination)
    need(retained == data, "completed recovery document differs from selected inputs: " + destination.name, 2)
    return identity(info)


def verify_stage(stage, directories, outputs, documents):
    # Re-admit the COPIES, not just their original worker paths. This also
    # catches an altered manifest or an extra uploadable file before rename.
    for directory, expected in directories.items():
        observed = path(str(directory)).lstat()
        need(stat.S_ISDIR(observed.st_mode) and (observed.st_dev, observed.st_ino) == expected,
             "recovery staging directory changed", 2)
    need({p.name for p in stage.iterdir()} == {"artifacts", "inputs", "build-manifest.json", "result.json"} and
         {p.name for p in (stage / "inputs").iterdir()} == {"state.json"} and
         {p.name for p in (stage / "artifacts").iterdir()} == set(outputs),
         "recovery staging inventory changed", 2)
    for filename, (receipt, expected_info) in outputs.items():
        _, _, info = read_file(stage / "artifacts" / filename, receipt, limit=args.max_artifact_bytes)
        need(identity(info) == expected_info, "recovered artifact metadata changed")
    for selected, (data, expected_info) in documents.items():
        current, _, info = read_file(selected)
        need(current == data and identity(info) == expected_info, "recovery document changed before publication")


def interrupted(signum, frame):
    raise Failure("native recovery interrupted", 5)


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, interrupted)

try:
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            raise Failure(message, 4)
    parser = Parser(description="Recover complete ordinary native builds into a new manifest-bound release input.",
        epilog="No build, upload, signing or original-state mutation occurs. This preserves ordinary worker custody, "
               "not strict source/toolchain authentication. Feed the returned manifest to release package/finalize.", allow_abbrev=False)
    for option in ("state", "state-sha256", "source-repo", "repo", "tag", "sha", "artifacts-root", "output-dir"):
        parser.add_argument("--" + option, required=True)
    parser.add_argument("--max-artifact-bytes", type=int, default=4 * 1024 ** 3)
    parser.add_argument("--max-unpacked-bytes", type=int, default=4 * 1024 ** 3)
    parser.add_argument("--max-archive-members", type=int, default=10000)
    parser.add_argument("--dry-run", action="store_true", help="validate all inputs and print planned names without writing")
    parser.add_argument("--resume", action="store_true",
        help="revalidate and reuse a complete recovery without changing any retained file")
    flags = [a.split("=", 1)[0] for a in sys.argv[1:] if a.startswith("--")]
    need(len(flags) == len(set(flags)), "duplicate recovery option", 4)
    args = parser.parse_args(sys.argv[1:])
    need(match(args.repo, r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*") and ".." not in args.repo and
         match(args.tag, r"v[0-9]+\.[0-9]+\.[0-9]+(?:[+-][A-Za-z0-9.+-]+)?") and
         match(args.sha, r"[0-9a-f]{40}") and args.sha != "0" * 40 and
         match(args.state_sha256, r"[0-9a-f]{64}") and 1 <= args.max_artifact_bytes <= 64 * 1024 ** 3 and
         1 <= args.max_unpacked_bytes <= 64 * 1024 ** 3 and 1 <= args.max_archive_members <= 100000,
         "invalid release identity or byte limit", 4)
    state_path, source_repo, artifacts_root, root = map(path,
        (args.state, args.source_repo, args.artifacts_root, args.output_dir))
    need(source_repo.is_dir() and artifacts_root.is_dir(), "source-repo and artifacts-root must be directories", 4)
    reuse = root.exists()
    need(not reuse or args.resume, "recovery output already exists; use --resume to revalidate it", 2)
    if reuse:
        need(root.is_dir() and {p.name for p in root.iterdir()} == {"release"} and
             path(str(root / "release")).is_dir(), "output is not a complete recovery", 2)
    need(not any(root.is_relative_to(p) or p.is_relative_to(root)
                 for p in (source_repo, artifacts_root, state_path.parent)),
         "recovery output must be outside the original source, artifact and state directories", 4)
    state_bytes, state_hash, state_info = read_file(state_path)
    need(state_hash == args.state_sha256, "state does not match the independently selected SHA-256")
    state = document(state_bytes)
    workers = select_workers(state)
    source_identity()
    output_workers = {}
    for worker in workers:
        worker["output_mode"] = check_artifact(worker)
        previous = output_workers.get(worker["name"])
        need(previous is None or previous["output_mode"] == worker["output_mode"],
             "shared companion executable modes differ", 4)
        output_workers[worker["name"]] = worker
    task_count = len(state["context"]["build_tasks"])
    dry = args.dry_run or os.environ.get("DRY_RUN") == "true"
    planned = dict(kind="dsr-native-recovery", status="planned", exit_code=0, dry_run=True,
            state_sha256=state_hash, recovered_targets=task_count,
            artifacts=[dict(name=w["name"], role=w["role"],
                target=w["task"]["platform"] if w["role"] == "primary" else "additional",
                task_keys=sorted({v["task"]["key"] for v in workers if v["name"] == w["name"]}),
                sha256=w["receipt"]["sha256"], archive_format=w["format"])
                for w in sorted(output_workers.values(), key=lambda row: row["name"])])
    if dry and not reuse:
        print(canonical(planned).decode(), end="")
        sys.exit(0)
    # Admission above performs no writes. Failure below leaves private evidence
    # but never a release/ directory or a successful receipt.
    os.umask(0o077)
    if not reuse:
        root.mkdir(mode=0o700)
    root_identity = (root.stat().st_dev, root.stat().st_ino)
    stage = root / "release" if reuse else Path(tempfile.mkdtemp(prefix=".recovery-", dir=root))
    if not reuse:
        (stage / "artifacts").mkdir()
        (stage / "inputs").mkdir()
    for directory in (stage, stage / "artifacts", stage / "inputs"):
        need(path(str(directory)).is_dir(), "missing recovery directory", 2)
    directories = {p: (p.stat().st_dev, p.stat().st_ino) for p in (stage, stage / "artifacts", stage / "inputs")}
    documents = {stage / "inputs/state.json":
        (state_bytes, retain_document(stage / "inputs/state.json", state_bytes, reuse))}
    artifacts, environments, mapping, copies = [], {}, [], {}
    for worker in workers:
        task, result, receipt = worker["task"], worker["result"], worker["receipt"]
        if worker["name"] not in copies:
            destination = stage / "artifacts" / worker["name"]
            if not reuse:
                check_artifact(worker, destination)
            info = destination.lstat()
            need(stat.S_IMODE(info.st_mode) == worker["output_mode"], "recovered artifact mode changed", 2)
            copied_receipt = dict(receipt, path=str(destination), identity="gnu:%d:%d" % (info.st_dev, info.st_ino))
            _, _, copied_info = read_file(destination, copied_receipt, limit=args.max_artifact_bytes)
            copies[worker["name"]] = (copied_receipt, identity(copied_info))
            artifact = dict(name=worker["name"], target=task["platform"] if worker["role"] == "primary" else "additional",
                sha256=receipt["sha256"], size_bytes=receipt["size_bytes"], archive_format=worker["format"],
                signed=False, signature_file="")
            if task["target_triple"] and worker["role"] == "primary":
                artifact["target_triple"] = task["target_triple"]
            artifacts.append(artifact)
        environment = dict(target=task["platform"], host=result["host"], method="native",
            build_influence_env=result.get("build_influence_env", {}), cargo_isolation=result.get("cargo_isolation"))
        if task["target_triple"]:
            environment["target_triple"] = task["target_triple"]
        environments[task["key"]] = environment
        mapping.append(dict(task_key=task["key"], source_path=str(worker["path"]), name=worker["name"],
            sha256=receipt["sha256"], size_bytes=receipt["size_bytes"], worker_identity=receipt["identity"],
            role=worker["role"], executable_bits=worker["output_mode"] & 0o111))
        if "archive_inventory" in worker:
            mapping[-1]["archive_inventory"] = worker["archive_inventory"]
    recovered_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if reuse:
        # Only the historical observation time comes from retained output.
        # Reconstruct every identity, artifact and evidence field from the
        # independently selected state and newly revalidated original inputs.
        retained_manifest, _, _ = read_file(stage / "build-manifest.json")
        recovered_at = timestamp(document(retained_manifest)["recovery_evidence"]["recovered_at"])
    manifest = dict(schema_version="1.0.0", tool=state["tool"], version=args.tag, run_id=state["run_id"],
        source=dict(git_sha=args.sha, git_ref="refs/tags/" + args.tag, repository="https://github.com/" + args.repo,
                    dependencies=[]),
        built_at=max(w["completed_at"] for w in workers),
        status="success", build_purpose="release", publishable=True,
        summary=dict(total=task_count, success=task_count, failed=0), requested_targets=sorted(state["targets"]),
        artifacts=sorted(artifacts, key=lambda a: a["name"]),
        build_environments=[environments[key] for key in sorted(environments)],
        recovery_evidence=dict(kind="ordinary-native-worker-recovery", schema_version=1,
            state_sha256=state_hash, source_verification="tag-identity-only", dependency_pins_verified=False,
            built_at_basis="latest-completed-target-checkpoint",
            recovered_at=recovered_at,
            original_status=state["status"], artifacts=mapping))
    manifest_bytes = canonical(manifest)
    documents[stage / "build-manifest.json"] = (
        manifest_bytes, retain_document(stage / "build-manifest.json", manifest_bytes, reuse))
    result = dict(kind="dsr-native-recovery", status="verified", exit_code=0,
        manifest=str(root / "release/build-manifest.json"), manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
        artifacts_dir=str(root / "release/artifacts"), state_sha256=state_hash, recovered_targets=task_count,
        recovered_artifacts=len(artifacts), companion_artifacts=sum(a["target"] == "additional" for a in artifacts),
        strict_source_verified=False, dependency_pins_verified=False)
    result_bytes = canonical(result)
    documents[stage / "result.json"] = (result_bytes, retain_document(stage / "result.json", result_bytes, reuse))
    # Recheck original custody and repository identity after copying. Never
    # repair a failed checkpoint by rehashing changed files into a new claim.
    for worker in workers:
        check_artifact(worker)
    final_bytes, final_hash, final_info = read_file(state_path)
    need(final_bytes == state_bytes and final_hash == state_hash and identity(final_info) == identity(state_info),
         "build state changed during recovery", 2)
    source_identity()
    verify_stage(stage, directories, copies, documents)
    if reuse:
        need(not root.is_symlink() and (root.stat().st_dev, root.stat().st_ino) == root_identity and
             {p.name for p in root.iterdir()} == {"release"}, "completed recovery directory changed", 2)
        print("[native-recovery] Revalidated completed recovery without rewriting retained files", file=sys.stderr)
        print(canonical(planned if dry else result).decode(), end="")
        sys.exit(0)
    need(not root.is_symlink() and (root.stat().st_dev, root.stat().st_ino) == root_identity and
         not (root / "release").exists() and not (root / "release").is_symlink(), "recovery destination changed", 2)
    os.rename(stage, root / "release")
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    print(canonical(result).decode(), end="")
except (Failure, OSError, ValueError, KeyError, TypeError, AttributeError, EOFError,
        tarfile.TarError, zipfile.BadZipFile, lzma.LZMAError, zlib.error, struct.error, RecursionError) as error:
    code = error.code if isinstance(error, Failure) else 4
    print("[native-recovery] " + str(error), file=sys.stderr)
    print(canonical(dict(kind="dsr-native-recovery", status="error", exit_code=code, error=str(error))).decode(), end="")
    sys.exit(code)
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _native_recovery_execute "$@"
fi
