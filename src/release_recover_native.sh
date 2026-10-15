#!/usr/bin/env bash
# Recover ordinary, completed native binaries after coordinator packaging fails.
# This is an explicit local import, not a strict-build attestation or a release
# upload. Original state, worker receipts and artifacts are never modified.

_native_recovery_execute() {
    command -v python3 >/dev/null || return 3
    exec env DRY_RUN="${DRY_RUN:-false}" python3 -I - "$@" <<'PY'
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import uuid


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
    need(state.get("status") in ("failed", "partial", "completed"), "active, pending or cancelled builds cannot be recovered", 2)
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
    selected, names, originals = [], set(), set()
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
        need(isinstance(receipts, list) and len(receipts) == 1 and isinstance(receipts[0], dict),
             "each task must retain exactly one raw executable receipt", 4)
        receipt = receipts[0]
        need(set(receipt) == {"path", "sha256", "size_bytes", "identity"} and
             match(receipt["sha256"], r"[0-9a-f]{64}") and type(receipt["size_bytes"]) is int and
             0 < receipt["size_bytes"] <= args.max_artifact_bytes and
             match(receipt["identity"], r"(?:gnu:[0-9]+:[1-9][0-9]*|bsd:[1-9][0-9]*)"), "invalid raw worker receipt", 4)
        original = path(receipt["path"])
        need(original.is_relative_to(artifacts_root) and original != artifacts_root and original not in originals,
             "worker artifact escapes the selected root or is shared by tasks", 4)
        need(result.get("artifact_path") == str(original) and result.get("artifact_paths") == [str(original)] and
             result.get("additional_artifacts", []) == [] and not result.get("artifact_dir"),
             "worker artifact inventory differs from its single raw receipt", 4)
        originals.add(original)
        stem = original.name[:-4] if original.name.lower().endswith(".exe") else original.name
        suffix = triple if triple else task["platform"].replace("/", "_")
        published = stem + "-" + suffix + (".exe" if task["platform"].startswith("windows/") else "")
        need(name(published) and published.casefold() not in names, "unsafe or colliding recovered asset name", 4)
        names.add(published.casefold())
        selected.append(dict(task=task, result=result, receipt=receipt, path=original, name=published,
                             completed_at=completed_at))
    return selected


def check_artifact(worker, destination=None):
    data, _, info = read_file(worker["path"], worker["receipt"], destination, args.max_artifact_bytes)
    need(binary_platform(data) == worker["task"]["platform"], "executable architecture differs from its worker target: " + worker["name"])
    executable = bool(info.st_mode & 0o111)
    need(executable or worker["task"]["platform"].startswith("windows/"), "Unix payload is not executable")
    if destination is not None:
        destination.chmod(0o755 if executable else 0o644)


def save(destination, data):
    with destination.open("xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def interrupted(signum, frame):
    raise Failure("native recovery interrupted", 5)


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, interrupted)

try:
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            raise Failure(message, 4)
    parser = Parser(description="Recover complete ordinary native raw builds into a new manifest-bound release input.",
        epilog="No build, upload, signing or original-state mutation occurs. This preserves ordinary worker custody, "
               "not strict source/toolchain authentication. Feed the returned manifest to release package/finalize.", allow_abbrev=False)
    for option in ("state", "state-sha256", "source-repo", "repo", "tag", "sha", "artifacts-root", "output-dir"):
        parser.add_argument("--" + option, required=True)
    parser.add_argument("--max-artifact-bytes", type=int, default=4 * 1024 ** 3)
    parser.add_argument("--dry-run", action="store_true", help="validate all inputs and print planned raw names without writing")
    flags = [a.split("=", 1)[0] for a in sys.argv[1:] if a.startswith("--")]
    need(len(flags) == len(set(flags)), "duplicate recovery option", 4)
    args = parser.parse_args(sys.argv[1:])
    need(match(args.repo, r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*") and ".." not in args.repo and
         match(args.tag, r"v[0-9]+\.[0-9]+\.[0-9]+(?:[+-][A-Za-z0-9.+-]+)?") and
         match(args.sha, r"[0-9a-f]{40}") and args.sha != "0" * 40 and
         match(args.state_sha256, r"[0-9a-f]{64}") and 1 <= args.max_artifact_bytes <= 64 * 1024 ** 3,
         "invalid release identity or byte limit", 4)
    state_path, source_repo, artifacts_root, root = map(path,
        (args.state, args.source_repo, args.artifacts_root, args.output_dir))
    need(source_repo.is_dir() and artifacts_root.is_dir(), "source-repo and artifacts-root must be directories", 4)
    need(not root.exists(), "recovery output already exists; select a new output directory", 2)
    need(not any(root.is_relative_to(p) for p in (source_repo, artifacts_root, state_path.parent)),
         "recovery output must be outside the original source, artifact and state directories", 4)
    state_bytes, state_hash, state_info = read_file(state_path)
    need(state_hash == args.state_sha256, "state does not match the independently selected SHA-256")
    state = document(state_bytes)
    workers = select_workers(state)
    source_identity()
    for worker in workers:
        check_artifact(worker)
    if args.dry_run or os.environ.get("DRY_RUN") == "true":
        print(canonical(dict(kind="dsr-native-recovery", status="planned", exit_code=0, dry_run=True,
            state_sha256=state_hash, artifacts=[dict(task_key=w["task"]["key"], name=w["name"],
                target=w["task"]["platform"], sha256=w["receipt"]["sha256"]) for w in workers])).decode(), end="")
        sys.exit(0)
    # Admission above performs no writes. Failure below leaves private evidence
    # but never a release/ directory or a successful receipt.
    os.umask(0o077)
    root.mkdir(mode=0o700)
    root_identity = (root.stat().st_dev, root.stat().st_ino)
    stage = Path(tempfile.mkdtemp(prefix=".recovery-", dir=root))
    (stage / "artifacts").mkdir()
    (stage / "inputs").mkdir()
    save(stage / "inputs/state.json", state_bytes)
    artifacts, environments, mapping = [], [], []
    for worker in workers:
        check_artifact(worker, stage / "artifacts" / worker["name"])
        task, result, receipt = worker["task"], worker["result"], worker["receipt"]
        artifact = dict(name=worker["name"], target=task["platform"], sha256=receipt["sha256"],
            size_bytes=receipt["size_bytes"], archive_format="binary", signed=False, signature_file="")
        environment = dict(target=task["platform"], host=result["host"], method="native",
            build_influence_env=result.get("build_influence_env", {}), cargo_isolation=result.get("cargo_isolation"))
        if task["target_triple"]:
            artifact["target_triple"] = environment["target_triple"] = task["target_triple"]
        artifacts.append(artifact)
        environments.append(environment)
        mapping.append(dict(task_key=task["key"], source_path=str(worker["path"]), name=worker["name"],
            sha256=receipt["sha256"], size_bytes=receipt["size_bytes"], worker_identity=receipt["identity"]))
    manifest = dict(schema_version="1.0.0", tool=state["tool"], version=args.tag, run_id=state["run_id"],
        source=dict(git_sha=args.sha, git_ref="refs/tags/" + args.tag, repository="https://github.com/" + args.repo,
                    dependencies=[]),
        built_at=max(w["completed_at"] for w in workers),
        status="success", build_purpose="release", publishable=True,
        summary=dict(total=len(workers), success=len(workers), failed=0), requested_targets=sorted(state["targets"]),
        artifacts=sorted(artifacts, key=lambda a: a["name"]), build_environments=environments,
        recovery_evidence=dict(kind="ordinary-native-worker-recovery", schema_version=1,
            state_sha256=state_hash, source_verification="tag-identity-only", dependency_pins_verified=False,
            built_at_basis="latest-completed-target-checkpoint",
            recovered_at=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            original_status=state["status"], artifacts=mapping))
    manifest_bytes = canonical(manifest)
    save(stage / "build-manifest.json", manifest_bytes)
    result = dict(kind="dsr-native-recovery", status="verified", exit_code=0,
        manifest=str(root / "release/build-manifest.json"), manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
        artifacts_dir=str(root / "release/artifacts"), state_sha256=state_hash, recovered_targets=len(workers),
        strict_source_verified=False, dependency_pins_verified=False)
    save(stage / "result.json", canonical(result))
    # Recheck original custody and repository identity after copying. Never
    # repair a failed checkpoint by rehashing changed files into a new claim.
    for worker in workers:
        check_artifact(worker)
    final_bytes, final_hash, final_info = read_file(state_path)
    need(final_bytes == state_bytes and final_hash == state_hash and identity(final_info) == identity(state_info),
         "build state changed during recovery", 2)
    source_identity()
    need(not root.is_symlink() and (root.stat().st_dev, root.stat().st_ino) == root_identity and
         not (root / "release").exists() and not (root / "release").is_symlink(), "recovery destination changed", 2)
    os.rename(stage, root / "release")
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    print(canonical(result).decode(), end="")
except (Failure, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
    code = error.code if isinstance(error, Failure) else 4
    print("[native-recovery] " + str(error), file=sys.stderr)
    print(canonical(dict(kind="dsr-native-recovery", status="error", exit_code=code, error=str(error))).decode(), end="")
    sys.exit(code)
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _native_recovery_execute "$@"
fi
