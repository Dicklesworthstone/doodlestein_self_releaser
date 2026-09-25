#!/usr/bin/env bash
# Install an explicitly selected executable set from local or fetched signed bytes.
# One managed current symlink activates a complete generation; no payload runs.
_RELEASE_INSTALL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_release_install_execute() {
    command -v python3 >/dev/null || return 3
    exec python3 - "$_RELEASE_INSTALL_DIR" "$@" <<'PY'
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


class Failure(Exception):
    def __init__(self, message, code=7):
        super().__init__(message)
        self.code = code


def need(condition, message, code=7):
    if not condition:
        raise Failure(message, code)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def pairs(items):
    result = {}
    for key, value in items:
        need(key not in result, "duplicate JSON key: " + key, 4)
        result[key] = value
    return result


def plain(value, kind=None):
    value = str(value)
    need(value.startswith("/") and value != "/" and
         all(p not in ("", ".", "..") for p in value[1:].split("/")) and
         not any(ord(c) < 32 or ord(c) == 127 or c == "\\" for c in value), "noncanonical absolute path", 4)
    path = Path(value)
    for ancestor in [*reversed(path.parents), path]:
        need(not ancestor.is_symlink(), "symlink in selected path: " + str(ancestor))
        if ancestor != path and ancestor.exists():
            need(ancestor.is_dir(), "non-directory path component")
    if kind:
        need(path.is_file() if kind == "file" else path.is_dir(), "missing " + kind + ": " + value)
    return path


def digest(path):
    plain(path, "file")
    h = hashlib.sha256()
    with path.open("rb") as f:
        before = os.fstat(f.fileno())
        for block in iter(lambda: f.read(1048576), b""):
            h.update(block)
        after = os.fstat(f.fileno())
    need((before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
         (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), "file changed during hashing")
    return h.hexdigest()


def load(path, limit=67108864):
    plain(path, "file")
    need(path.stat().st_size <= limit, "JSON input exceeds size limit", 4)
    with path.open(encoding="utf-8") as f:
        return json.load(f, object_pairs_hook=pairs,
                         parse_constant=lambda s: (_ for _ in ()).throw(Failure("non-finite JSON number", 4)))


def write(path, value):
    with path.open("xb") as f:
        f.write(canonical(value))
        f.flush()
        os.fsync(f.fileno())


def copy_pinned(source, dest, expected, mode=0o400):
    plain(source, "file")
    h = hashlib.sha256()
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as incoming, dest.open("xb") as outgoing:
        before = os.fstat(incoming.fileno())
        need(stat.S_ISREG(before.st_mode), "source is not a regular file")
        for block in iter(lambda: incoming.read(1048576), b""):
            outgoing.write(block)
            h.update(block)
        after = os.fstat(incoming.fileno())
        need((before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
             (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), "source changed during copy")
        outgoing.flush()
        os.fsync(outgoing.fileno())
    need(h.hexdigest() == expected, "copied bytes differ from authenticated selection")
    dest.chmod(mode)


def name(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", value) is not None and ".." not in value


def member(value):
    return isinstance(value, str) and len(value) <= 1024 and all(name(p) for p in value.split("/"))


def recipe(value):
    need(isinstance(value, dict) and set(value) == {"schema_version", "target", "executables"} and
         type(value["schema_version"]) is int and value["schema_version"] == 1 and
         isinstance(value["target"], str) and re.fullmatch(r"(linux|darwin)/(amd64|arm64|386)", value["target"]) and
         isinstance(value["executables"], list) and 1 <= len(value["executables"]) <= 64, "invalid installation recipe", 4)
    for item in value["executables"]:
        need(isinstance(item, dict) and {"name", "artifact"} <= set(item) <= {"name", "artifact", "member"} and
             name(item["name"]) and name(item["artifact"]) and
             ("member" not in item or member(item["member"])), "invalid executable selection", 4)
    need(len({e["name"].lower() for e in value["executables"]}) == len(value["executables"]), "colliding executable names", 4)
    value["executables"].sort(key=lambda e: e["name"])
    return value


def interrupt(signum, frame):
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)
    raise Failure("installation interrupted", 5)


for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, interrupt)

module = Path(sys.argv[1])
lockfd = None
activated = False


def helper(command, work, network=False):
    environment = os.environ.copy()
    for key in list(environment):
        if key.startswith("BASH_FUNC_") or key in ("BASH_ENV", "ENV", "TAR_OPTIONS", "GZIP", "XZ_OPT", "XZ_DEFAULTS",
            "ZIPOPT", "UNZIP", "UNZIPOPT", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN") or (
            not network and key in ("DSR_GH_TOKEN", "GH_TOKEN", "GITHUB_TOKEN")):
            environment.pop(key)
    environment.update(LC_ALL="C", TZ="UTC", COPYFILE_DISABLE="1")
    with (work / "helper.stderr").open("wb") as error:
        proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=error,
                                env=environment, start_new_session=True, pass_fds=(() if lockfd is None else (lockfd,)))
        try:
            output, _ = proc.communicate(timeout=args.timeout)
            need(proc.returncode == 0, "verification/archive helper failed (exit %s)" % proc.returncode,
                 proc.returncode if 0 < proc.returncode < 256 else 5)
            return output
        except subprocess.TimeoutExpired:
            raise Failure("verification/archive helper timed out", 5)
        finally:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()


def verify_generation(directory, expected):
    plain(directory, "dir")
    need({p.name for p in directory.iterdir()} == {"bin", "receipt.json", "release.intoto.jsonl", "release.intoto.jsonl.minisig"},
         "generation namespace changed")
    need(load(directory / "receipt.json") == expected, "generation receipt differs from authenticated selection")
    for file, pin in (("release.intoto.jsonl", expected["statement_sha256"]),
                      ("release.intoto.jsonl.minisig", expected["signature_sha256"])):
        need(digest(directory / file) == pin, "retained generation proof changed")
    binaries = plain(directory / "bin", "dir")
    need({p.name for p in binaries.iterdir()} == {e["name"] for e in expected["executables"]}, "installed executable set changed")
    for item in expected["executables"]:
        file = plain(binaries / item["name"], "file")
        need(digest(file) == item["sha256"] and file.stat().st_size == item["size_bytes"] and
             stat.S_IMODE(file.stat().st_mode) == 0o755, "installed executable changed: " + item["name"])


def current_selection(prefix):
    current = prefix / "current"
    if not current.exists() and not current.is_symlink():
        return None
    need(current.is_symlink(), "refusing unmanaged current entry", 2)
    target = os.readlink(current)
    need(re.fullmatch(r"generations/[0-9a-f]{64}", target), "current link escapes managed generations", 2)
    directory = plain(prefix / target, "dir")
    old = load(directory / "receipt.json")
    need(isinstance(old, dict) and old.get("kind") == "dsr-authenticated-install-generation" and
         old.get("repository") == args.repo and old.get("target") == selected["target"], "current is not this installation", 2)
    observed = current.lstat()
    return target, observed.st_dev, observed.st_ino


try:
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            raise Failure(message, 4)
    parser = Parser(description="Authenticate and install a complete executable set; never execute payloads.", allow_abbrev=False)
    origin = parser.add_mutually_exclusive_group(required=True)
    origin.add_argument("--snapshot", help="Use a complete local snapshot without network access")
    origin.add_argument("--fetch", action="store_true", help="Fetch an exact signed release into private staging before installation")
    parser.add_argument("--allow-draft", action="store_true", help="With --fetch: permit an authenticated draft release")
    for flag in ("recipe", "prefix", "repo", "tag", "sha", "builder", "targets", "public-key"):
        parser.add_argument("--" + flag, required=True)
    for flag in ("statement-sha256", "manifest-sha256", "invocation-id"):
        parser.add_argument("--" + flag)
    parser.add_argument("--replace", action="store_true", help="Permit switching an existing managed installation")
    parser.add_argument("--dry-run", action="store_true", help="Authenticate and extract without changing installation state")
    parser.add_argument("--timeout", type=int, default=900, help="Per verification/extraction helper timeout, 1..86400 seconds")
    flags = [a.split("=", 1)[0] for a in sys.argv[2:] if a.startswith("--")]
    need(len(flags) == len(set(flags)), "duplicate installation option", 4)
    args = parser.parse_args(sys.argv[2:])
    need(1 <= args.timeout <= 86400, "timeout must be 1..86400", 4)
    need(not args.allow_draft or args.fetch, "--allow-draft requires --fetch", 4)
    snapshot = None if args.fetch else plain(args.snapshot, "dir")
    recipe_file = plain(args.recipe, "file")
    public = plain(args.public_key, "file")
    prefix = plain(args.prefix)
    plain(prefix.parent, "dir")
    for input_path in (recipe_file, public, *(() if snapshot is None else (snapshot,))):
        need(prefix != input_path and prefix not in input_path.parents and input_path not in prefix.parents,
             "installation prefix overlaps selected inputs", 4)
    selected = recipe(load(recipe_file, 1048576))
    recipe_pin = digest(recipe_file)
    key_pin = digest(public)
    need(public.stat().st_size <= 8192, "public key exceeds size limit", 4)
    operating_system = {"Linux": "linux", "Darwin": "darwin"}.get(platform.system())
    architecture = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64", "i386": "386", "i686": "386"}.get(platform.machine().lower())
    need(operating_system is not None and architecture is not None, "unsupported installation host", 3)
    need(selected["target"] == operating_system + "/" + architecture, "recipe target is not the installation host", 4)
    for executable in ("bash", "jq", "minisign"):
        need(shutil.which(executable), "missing dependency: " + executable, 3)
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix=".dsr-install-", dir=prefix.parent) as temporary:
        work = Path(temporary)
        copy_pinned(public, work / "trusted.pub", key_pin)
        policy = []
        for flag in ("repo", "tag", "sha", "builder", "targets", "statement-sha256", "manifest-sha256", "invocation-id"):
            value = getattr(args, flag.replace("-", "_"))
            if value is not None:
                policy += ["--" + flag, value]
        fetched = None
        if args.fetch:
            snapshot = work / "snapshot"
            output = helper(["bash", str(module / "slsa_remote.sh"), "fetch-release", "--output-dir", str(snapshot),
                             "--public-key", str(work / "trusted.pub"), *policy], work, network=True)
            fetched = json.loads(output, object_pairs_hook=pairs)
            need(isinstance(fetched, dict) and fetched.get("kind") == "dsr-slsa-fetch" and
                 fetched.get("status") == "verified" and fetched.get("authenticated") is True and
                 fetched.get("snapshot") == str(snapshot) and isinstance(fetched.get("verification"), dict),
                 "invalid authenticated download handoff")
            observation = fetched["verification"]
            need(observation.get("kind") == "dsr-slsa-remote-verification" and observation.get("authenticated") is True and
                 observation.get("status") == "verified" and observation.get("tag_commit") == args.sha and
                 isinstance(observation.get("repository"), dict) and observation["repository"].get("full_name") == args.repo and
                 isinstance(observation.get("release"), dict) and observation["release"].get("tag_name") == args.tag and
                 type(observation["release"].get("draft")) is bool, "download observation differs from selected release")
            need(not observation["release"]["draft"] or args.allow_draft, "draft installation requires --allow-draft", 4)
        # Reauthenticate the exact downloaded bytes, not a remote success field.
        # From here onward no helper receives GitHub credentials or uses HTTP.
        output = helper(["bash", str(module / "slsa_remote.sh"), "verify-snapshot", str(snapshot),
                         "--public-key", str(work / "trusted.pub"), *policy], work)
        verified = json.loads(output, object_pairs_hook=pairs)
        need(isinstance(verified, dict) and verified.get("kind") == "dsr-slsa-snapshot-verification" and
             verified.get("authenticated") is True and verified.get("remote_current") is False and
             verified.get("snapshot") == str(snapshot), "invalid snapshot verification handoff")
        if fetched is not None:
            need(fetched.get("snapshot_sha256") == verified["snapshot_sha256"] and
                 observation.get("statement", {}).get("sha256") == verified["statement_sha256"] and
                 observation.get("signature", {}).get("sha256") == verified["signature_sha256"] and
                 observation.get("build_manifest_sha256") == verified["build_manifest_sha256"] and
                 observation.get("invocation_id") == verified["invocation_id"], "download and local authentication disagree")
        records = {a["name"]: a for a in verified["artifacts"]}
        for item in selected["executables"]:
            need(item["artifact"] in records and records[item["artifact"]]["target"] == selected["target"], "executable artifact is not a signed payload for this target", 4)
            need((records[item["artifact"]]["archive_format"] in ("binary", "none")) == ("member" not in item),
                 "raw artifacts forbid member; archives require member", 4)
        staged = work / "generation"
        (staged / "bin").mkdir(parents=True)
        copy_pinned(snapshot / "release.intoto.jsonl", staged / "release.intoto.jsonl", verified["statement_sha256"])
        copy_pinned(snapshot / "release.intoto.jsonl.minisig", staged / "release.intoto.jsonl.minisig", verified["signature_sha256"])
        extracted = {}
        for number, artifact in enumerate(sorted({e["artifact"] for e in selected["executables"]})):
            record = records[artifact]
            local = work / ("artifact-%d" % number)
            copy_pinned(snapshot / "artifacts" / artifact, local, record["sha256"])
            need(local.stat().st_size == record["size_bytes"], "authenticated artifact size changed")
            if record["archive_format"] in ("binary", "none"):
                extracted[artifact] = local
            else:
                dest = work / ("extracted-%d" % number)
                dest.mkdir()
                helper(["bash", "-c", 'source "$1/packaging.sh" || exit 3; packaging_extract_payload "$2" "$3" "$4"',
                        "_", str(module), str(local), record["archive_format"], str(dest)], work)
                extracted[artifact] = dest
        installed = []
        for item in selected["executables"]:
            source = extracted[item["artifact"]]
            if "member" in item:
                source /= item["member"]
            plain(source, "file")
            need(source.stat().st_size > 0, "empty executable member")
            pin = digest(source)
            dest = staged / "bin" / item["name"]
            copy_pinned(source, dest, pin, 0o755)
            installed.append(dict(item, sha256=pin, size_bytes=dest.stat().st_size, mode=0o755))
        receipt = dict(schema_version=1, kind="dsr-authenticated-install-generation", repository=args.repo, tag=args.tag,
                       source_sha=args.sha, builder=args.builder, target=selected["target"], recipe=selected,
                       public_key=(work / "trusted.pub").read_text().splitlines()[1], remote_current=False,
                       snapshot_sha256=verified["snapshot_sha256"], statement_sha256=verified["statement_sha256"],
                       signature_sha256=verified["signature_sha256"], build_manifest_sha256=verified["build_manifest_sha256"],
                       invocation_id=verified["invocation_id"], executables=installed)
        identity = hashlib.sha256(canonical(receipt)).hexdigest()
        write(staged / "receipt.json", receipt)
        verify_generation(staged, receipt)
        need(digest(public) == key_pin and digest(recipe_file) == recipe_pin, "selected key or recipe changed")
        result = dict(kind="dsr-release-install", status="planned" if args.dry_run else "installed", exit_code=0,
                      authenticated=True, remote_current=False, prefix=str(prefix), generation=identity,
                      bin_dir=str(prefix / "current/bin"), generation_bin_dir=str(prefix / "generations" / identity / "bin"),
                      executables=installed, snapshot_sha256=verified["snapshot_sha256"],
                      dry_run=args.dry_run)
        if fetched is not None:
            # The observation describes the just-completed fetch, not ongoing
            # freshness. Exclude it from generation identity so offline reuse
            # and a subsequent re-download select the same installed bytes.
            result["download"] = dict(kind=fetched["kind"], snapshot_sha256=verified["snapshot_sha256"],
                                      verification=observation)
        if not args.dry_run:
            lock_path = plain(str(prefix) + ".lock")
            lockfd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
            held = os.fstat(lockfd)
            need(stat.S_ISREG(held.st_mode), "invalid installation lock", 2)
            try:
                fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Failure("installation already active", 2)
            plain(prefix)
            prefix.mkdir(mode=0o700, exist_ok=True)
            root_identity = dict(schema_version=1, kind="dsr-release-install-root", repository=args.repo, target=selected["target"])
            marker = plain(prefix / "installation.json")
            if marker.exists():
                need(load(marker) == root_identity, "prefix belongs to a different installation", 2)
                need({p.name for p in prefix.iterdir()} <= {"installation.json", "generations", "current"}, "unmanaged installation entries", 2)
            else:
                need(not list(prefix.iterdir()), "refusing an unmanaged nonempty prefix", 2)
                write(work / "installation.json", root_identity)
                os.link(work / "installation.json", marker)
            generations = plain(prefix / "generations")
            generations.mkdir(mode=0o700, exist_ok=True)
            before = current_selection(prefix)
            desired = "generations/" + identity
            need(before is None or before[0] == desired or args.replace, "existing installation requires --replace", 2)
            final = plain(generations / identity)
            if final.exists():
                verify_generation(final, receipt)
            else:
                staged.rename(final)
                verify_generation(final, receipt)
            need(digest(public) == key_pin and digest(recipe_file) == recipe_pin, "selected key or recipe changed before activation")
            named = plain(lock_path, "file").stat()
            need((held.st_dev, held.st_ino) == (named.st_dev, named.st_ino) and load(marker) == root_identity and
                 current_selection(prefix) == before, "installation state changed before activation", 2)
            if before is None or before[0] != desired:
                os.symlink(desired, work / "current")
                # A handled signal must not report activated:false after the
                # pointer switch succeeded. Defer it across this tiny commit
                # boundary; a delivered signal then reports the actual state.
                previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT, signal.SIGHUP})
                try:
                    os.replace(work / "current", prefix / "current")
                    activated = True
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            need(os.readlink(prefix / "current") == desired, "installation pointer changed after activation")
            result.update(activated=activated, previous_generation=None if before is None else before[0].split("/")[1])
        print(canonical(result).decode(), end="")
except (Failure, OSError, ValueError, TypeError, KeyError, IndexError) as error:
    code = getattr(error, "code", 7)
    print("[release-install] " + str(error), file=sys.stderr)
    print(canonical(dict(kind="dsr-release-install", status="error", exit_code=code, activated=activated,
                         error=str(error))).decode(), end="")
    sys.exit(code)
finally:
    if lockfd is not None:
        os.close(lockfd)
PY
}

release_install() ( _release_install_execute "$@"; )
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _release_install_execute "$@"
fi
