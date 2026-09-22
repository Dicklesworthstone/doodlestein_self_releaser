#!/usr/bin/env bash
# Execute reviewed native/xwin jobs before pinning their successful manifests.
# The existing release-bundle validator remains the only artifact admission path.
_RELEASE_BUILDS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_rbuild_execute() {
    set -uo pipefail
    command -v python3 >/dev/null || return 3
    exec python3 - "$_RELEASE_BUILDS_DIR" "$@" <<'PY'
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

# State is private, cooperating-writer recovery storage, not authenticated
# provenance. Never signal a PID loaded from disk or adopt an unbound success.
class Failure(Exception):
    def __init__(self, message, code=7):
        super().__init__(message)
        self.code = code

def require(ok, message, code=7):
    if not ok:
        raise Failure(message, code)

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()

def pairs(items):
    obj = {}
    for key, value in items:
        require(key not in obj, "duplicate JSON key: " + key, 4)
        obj[key] = value
    return obj

def path(value):
    require(isinstance(value, str) and value.startswith("/") and value != "/" and
            not any(ord(c) < 32 or ord(c) == 127 or c == "\\" for c in value) and
            all(p not in ("", ".", "..") for p in value[1:].split("/")), "noncanonical absolute path", 4)
    return Path(value)

def plain(p, kind=None):
    p = path(str(p))
    current = Path("/")
    for part in p.parts[1:]:
        current /= part
        require(not current.is_symlink(), "symlink in selected path: " + str(current))
        if current != p and current.exists():
            require(current.is_dir(), "non-directory path component")
    if kind:
        require(p.exists(), "missing input: " + str(p))
        mode = p.stat().st_mode
        require(stat.S_ISREG(mode) if kind == "file" else stat.S_ISDIR(mode), "unexpected file type: " + str(p))
    return p

def digest(p):
    plain(p, "file")
    h = hashlib.sha256()
    with open(p, "rb") as f:
        before = os.fstat(f.fileno())
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
        after = os.fstat(f.fileno())
    require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
            (after.st_size, after.st_mtime_ns, after.st_ctime_ns), "input changed while hashing")
    return h.hexdigest()

def load(p):
    plain(p, "file")
    with open(p, encoding="utf-8") as f:
        return json.load(f, object_pairs_hook=pairs)

def write(p, value, replace=False):
    plain(p.parent, "dir")
    plain(p)
    fd, temporary = tempfile.mkstemp(prefix=".write-", dir=p.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(canonical(value))
            f.flush()
            os.fsync(f.fileno())
        if replace:
            os.replace(temporary, p)
        else:
            os.link(temporary, p)
        fd = os.open(p.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def matches(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None

def name(value):
    return matches(value, r"[A-Za-z0-9][A-Za-z0-9._+-]*") and ".." not in value

def sha(value):
    return matches(value, r"[0-9a-f]{64}")

def integer(value, low, high):
    return type(value) is int and low <= value <= high

def targets(value):
    require(isinstance(value, list) and value and all(matches(t, r"(linux|darwin|windows)/(amd64|arm64|386)") for t in value)
            and len(set(value)) == len(value), "invalid or duplicate targets", 4)
    return sorted(value)

def validate(value):
    required = {"schema_version", "repo", "tool", "tag", "source_sha", "required_targets", "builds"}
    require(isinstance(value, dict) and set(value) == required and type(value["schema_version"]) is int and
            value["schema_version"] == 1, "invalid build-plan schema", 4)
    require(name(value["tool"]) and matches(value["repo"], r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*") and
            ".." not in value["repo"] and matches(value["tag"], r"v[0-9]+\.[0-9]+\.[0-9]+(?:[+-][A-Za-z0-9.+-]+)?") and
            matches(value["source_sha"], r"[0-9a-f]{40}") and value["source_sha"] != "0" * 40, "invalid release identity", 4)
    value["required_targets"] = targets(value["required_targets"])
    require(isinstance(value["builds"], list) and 1 <= len(value["builds"]) <= 32, "expected 1..32 build jobs", 4)
    ids, matrix = [], []
    for job in value["builds"]:
        require(isinstance(job, dict) and {"id", "driver", "targets"} <= set(job) and name(job["id"]), "invalid job identity", 4)
        base = {"id", "driver", "targets", "timeout"}
        kind = job["driver"]
        if kind == "dsr":
            require({"config_dir", "config_files"} <= set(job) and set(job) <= base | {"config_dir", "config_files", "jobs"}, "invalid native job", 4)
            path(job["config_dir"])
            files = job["config_files"]
            require(isinstance(files, dict) and 3 <= len(files) <= 64 and
                    {"config.yaml", "repos.yaml", "hosts.yaml"} <= set(files), "pin config.yaml, repos.yaml and hosts.yaml", 4)
            for filename, pin in files.items():
                require(matches(filename, r"(?:config\.yaml|repos\.yaml|hosts\.yaml|repos\.d/[A-Za-z0-9][A-Za-z0-9_-]*\.yaml)") and sha(pin), "invalid configuration pin", 4)
            job.setdefault("jobs", 1)
            require(integer(job["jobs"], 1, 32), "invalid native target concurrency", 4)
        elif kind == "xwin":
            require({"project", "toolchain_manifest", "toolchain_sha256", "binary"} <= set(job) and
                    set(job) <= base | {"project", "toolchain_manifest", "toolchain_sha256", "binary", "package", "asset_name", "siblings", "cargo_cache", "cache_dir", "offline"}, "invalid xwin job", 4)
            path(job["project"]); path(job["toolchain_manifest"])
            require(sha(job["toolchain_sha256"]) and matches(job["binary"], r"[A-Za-z0-9][A-Za-z0-9_-]*"), "invalid toolchain pin or binary", 4)
            require(job["targets"] == ["windows/arm64"], "xwin supports one Windows ARM64 target", 4)
            for key in ("cargo_cache", "cache_dir"):
                if key in job:
                    path(job[key])
            if "package" in job:
                require(matches(job["package"], r"[A-Za-z0-9][A-Za-z0-9_-]*"), "invalid package", 4)
            if "asset_name" in job:
                require(name(job["asset_name"]) and job["asset_name"].endswith(".exe"), "invalid executable asset name", 4)
            if "siblings" in job:
                sibling = job["siblings"]
                require(isinstance(sibling, dict) and set(sibling) == {"path", "sha256"} and sha(sibling["sha256"]), "invalid sibling-plan pin", 4)
                path(sibling["path"])
            job.setdefault("offline", False)
            require(type(job["offline"]) is bool, "offline must be boolean", 4)
        elif kind == "import":
            require(set(job) == {"id", "driver", "targets", "manifest", "manifest_sha256", "artifacts_dir"} and sha(job["manifest_sha256"]), "invalid imported job", 4)
            path(job["manifest"]); path(job["artifacts_dir"])
        else:
            raise Failure("unknown build driver", 4)
        if kind != "import":
            job.setdefault("timeout", 3600)
            require(integer(job["timeout"], 1, 86400), "timeout must be 1..86400 seconds", 4)
        job["targets"] = targets(job["targets"])
        ids.append(job["id"].casefold()); matrix += job["targets"]
    require(len(set(ids)) == len(ids) and sorted(matrix) == value["required_targets"], "jobs must partition the entire required target matrix", 4)
    value["builds"].sort(key=lambda j: j["id"])
    return value

module = Path(sys.argv[1])
active = {}
interrupted = False
lockfd = None
lock_identity = None
state_hash = None

def stop(signum, frame):
    global interrupted
    interrupted = True

for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, stop)

def kill_group(proc, sig):
    try:
        os.killpg(proc.pid, sig)
    except ProcessLookupError:
        pass

def save_state():
    global state_hash
    identity = plain(root / "lock", "file").stat()
    require((identity.st_dev, identity.st_ino) == lock_identity and load(root / "plan.json") == plan,
            "coordinator lock or frozen plan changed", 2)
    require(digest(root / "state.json") == state_hash, "build state changed outside coordinator", 2)
    write(root / "state.json", state, replace=True)
    state_hash = digest(root / "state.json")

def helper(operation, entry, destination, directory):
    # The source and program are fixed; untrusted JSON/paths are arguments, not
    # interpolated shell. A compact entry never contains the producer inventory.
    plain(directory, "dir")
    command = 'source "$1/release_bundle.sh" || exit 3; _rb_require || exit $?; "$2" "$3" "$4" "$5" "$6"'
    if operation == "_rb_import":
        args = [json.dumps(entry), str(root / "plan.json"), str(destination), str(directory)]
    else:
        args = [str(destination), json.dumps(entry), str(root / "plan.json"), str(directory)]
    with open(directory / "admission.log", "ab") as log:
        result = subprocess.run(["bash", "-c", command, "_", str(module), operation] + args,
                                stdout=log, stderr=log, pass_fds=(lockfd,))
    require(result.returncode == 0, "manifest/payload admission failed; see " + str(directory / "admission.log"), 7)

def selected(job, manifest, artifacts, pin=None):
    return {"id": job["id"], "targets": job["targets"], "manifest": str(manifest),
            "manifest_sha256": pin or digest(manifest), "artifacts_dir": str(artifacts)}

def copy_pin(source, target, pin):
    require(digest(source) == pin, "configured build input hash mismatch: " + str(source))
    target.parent.mkdir(parents=True, exist_ok=True)
    plain(target.parent, "dir")
    require(not target.exists() and not target.is_symlink(), "input snapshot already exists", 2)
    with open(source, "rb") as incoming, open(target, "xb") as outgoing:
        shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
    require(digest(target) == pin and digest(source) == pin, "build input changed while snapshotting")
    target.chmod(0o400)

def start_job(job):
    record = state["jobs"][job["id"]]
    attempt = root / "attempts" / job["id"] / ("%06d" % (len(record["attempts"]) + 1))
    attempt.parent.mkdir(parents=True, exist_ok=True)
    plain(attempt)
    item = {"number": len(record["attempts"]) + 1, "status": "starting", "exit_code": None}
    record["attempts"].append(item)
    save_state()
    environment = os.environ.copy()
    try:
        attempt.mkdir(mode=0o700)
        if job["driver"] == "import":
            entry = selected(job, job["manifest"], job["artifacts_dir"], job["manifest_sha256"])
            accept(job, attempt, entry)
            return
        if job["driver"] == "dsr":
            for filename, pin in job["config_files"].items():
                copy_pin(Path(job["config_dir"]) / filename, attempt / "config" / filename, pin)
            # Freeze all config file selectors. Preserve native host credentials
            # and toolchain environment, as the ordinary DSR builder does.
            for key in list(environment):
                if key.startswith("DSR_") or key in ("DRY_RUN", "JSON_MODE"):
                    environment.pop(key)
            cfg = str(attempt / "config")
            environment.update(DSR_CONFIG_DIR=cfg, DSR_CONFIG_FILE=cfg + "/config.yaml",
                               DSR_REPOS_FILE=cfg + "/repos.yaml", DSR_HOSTS_FILE=cfg + "/hosts.yaml",
                               DSR_STATE_DIR=str(attempt / "state"))
            command = ["bash", str(module.parent / "dsr"), "--json", "--non-interactive", "build", "--tool", plan["tool"],
                       "--version", plan["tag"], "--targets", ",".join(job["targets"]), "--jobs", str(job["jobs"]),
                       "--output-dir", str(attempt / "output")]
            manifest = attempt / "output" / (plan["tool"] + "-" + plan["tag"] + "-manifest.json")
            artifacts = attempt / "output"
        else:
            copy_pin(Path(job["toolchain_manifest"]), attempt / "toolchain.json", job["toolchain_sha256"])
            command = ["bash", str(module.parent / "scripts/xwin-build.sh"), "--manifest", str(attempt / "toolchain.json"),
                       "--project", job["project"], "--bin", job["binary"], "--run-dir", str(attempt / "run"),
                       "--release-repo", plan["repo"], "--release-tag", plan["tag"], "--source-sha", plan["source_sha"],
                       "--tool", plan["tool"], "--timeout", str(job["timeout"])]
            for key, option in (("package", "--package"), ("asset_name", "--asset-name"),
                                ("cargo_cache", "--cargo-cache"), ("cache_dir", "--cache-dir")):
                if key in job:
                    command += [option, job[key]]
            if job["offline"]:
                command.append("--offline")
            if "siblings" in job:
                copy_pin(Path(job["siblings"]["path"]), attempt / "siblings.json", job["siblings"]["sha256"])
                command += ["--sibling-crates", str(attempt / "siblings.json")]
            manifest, artifacts = attempt / "run/release/build-manifest.json", attempt / "run/artifacts"
        plain(Path(command[1]), "file")
        write(attempt / "command.json", command)
        write(attempt / "inputs.json", {"plan_sha256": plan_hash, "job": job})
        item["status"] = "running"
        save_state()
        # A inherited high descriptor keeps the coordinator lock occupied even
        # if the parent dies before a driver finishes. Never unlock it in a child.
        with open(attempt / "stdout.json", "xb") as out, open(attempt / "stderr.log", "xb") as err:
            proc = subprocess.Popen(["timeout", "--foreground", "--kill-after=5s", str(job["timeout"]) + "s"] + command,
                                    env=environment, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                    start_new_session=True, pass_fds=(lockfd,))
        active[job["id"]] = (proc, job, attempt, manifest, artifacts)
        print("[release-builds] Started " + job["id"] + "; log: " + str(attempt / "stderr.log"), file=sys.stderr)
    except (Failure, OSError) as exc:
        item.update(status="failed", exit_code=getattr(exc, "code", 7))
        save_state()
        print("[release-builds] " + job["id"] + ": " + str(exc), file=sys.stderr)

def accept(job, attempt, entry):
    record = state["jobs"][job["id"]]
    # Persist the selected manifest BEFORE importing. A crash between import
    # and the completion update can only reuse that exact pinned selection.
    record["candidate"] = entry
    save_state()
    destination = root / "completed" / job["id"]
    helper("_rb_import", entry, destination, attempt)
    record["complete"] = entry
    record["candidate"] = None
    record["attempts"][-1].update(status="completed", exit_code=0)
    save_state()

def finish_job(item):
    proc, job, attempt, manifest, artifacts = item
    code = proc.wait()
    kill_group(proc, signal.SIGKILL)
    record = state["jobs"][job["id"]]
    try:
        require(code == 0, "builder exited " + str(code), code if 0 < code < 256 else 5)
        response = load(attempt / "stdout.json")
        require(isinstance(response, dict) and type(response.get("exit_code")) is int,
                "builder did not return a typed completion object")
        if job["driver"] == "dsr":
            require(response.get("command") == "build" and response.get("status") == "success" and response.get("exit_code") == 0 and
                    response.get("details", {}).get("manifest") == str(manifest), "native completion envelope does not bind its manifest")
            for filename, pin in job["config_files"].items():
                require(digest(attempt / "config" / filename) == pin, "native configuration snapshot changed")
            actual = set()
            for directory, dirs, files in os.walk(attempt / "config", followlinks=False):
                for filename in dirs + files:
                    p = Path(directory) / filename
                    plain(p, "dir" if filename in dirs else "file")
                    if filename in files:
                        actual.add(p.relative_to(attempt / "config").as_posix())
            require(actual == set(job["config_files"]), "native configuration namespace changed")
        else:
            require(response.get("kind") == "dsr-xwin-build" and response.get("status") == "verified" and response.get("exit_code") == 0 and
                    response.get("release_manifest") == {"path": str(manifest), "sha256": digest(manifest)}, "xwin completion receipt does not bind its manifest")
            require(digest(attempt / "toolchain.json") == job["toolchain_sha256"], "toolchain plan changed")
            if "siblings" in job:
                require(digest(attempt / "siblings.json") == job["siblings"]["sha256"], "sibling plan changed")
        accept(job, attempt, selected(job, manifest, artifacts))
    except (Failure, OSError, ValueError) as exc:
        record["attempts"][-1].update(status="failed", exit_code=getattr(exc, "code", 7))
        save_state()
        print("[release-builds] " + job["id"] + ": " + str(exc), file=sys.stderr)

try:
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            raise Failure(message, 4)
    parser = Parser(description="Run pinned DSR/xwin jobs, resume completed builds, and assemble a release. No publication.")
    parser.add_argument("--plan", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--dry-run", action="store_true")
    # argparse otherwise accepts repeated flags and silently keeps the last one.
    flags = [a.split("=", 1)[0] for a in sys.argv[2:] if a.startswith("--")]
    require(len(flags) == len(set(flags)), "repeated build-plan option", 4)
    args = parser.parse_args(sys.argv[2:])
    require(integer(args.jobs, 1, 32), "jobs must be 1..32", 4)
    root = path(args.output_dir)
    plain(root)
    plan = validate(load(path(args.plan)))
    plan_hash = hashlib.sha256(canonical(plan)).hexdigest()
    require(os.environ.get("DRY_RUN", "false") in ("true", "false"), "invalid DRY_RUN", 4)
    if args.dry_run or os.environ.get("DRY_RUN") == "true":
        print(canonical({"kind": "dsr-release-builds", "status": "planned", "exit_code": 0, "dry_run": True,
                         "publishable": False, "plan": plan, "plan_sha256": plan_hash, "jobs": args.jobs}).decode(), end="")
        sys.exit(0)
    require(sys.platform.startswith("linux"), "build-plan execution requires Linux", 3)
    for tool in ("bash", "jq", "flock", "timeout", "sha256sum"):
        require(shutil.which(tool), "missing dependency: " + tool, 3)
    plain(root.parent, "dir")
    root.mkdir(mode=0o700, exist_ok=True)
    plain(root, "dir")
    lock_path = plain(root / "lock")
    rawfd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    require(stat.S_ISREG(os.fstat(rawfd).st_mode), "invalid coordinator lock", 2)
    lockfd = fcntl.fcntl(rawfd, fcntl.F_DUPFD, 64)
    os.close(rawfd)
    try:
        fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise Failure("build-plan execution is already active", 2)
    lock_identity = (os.fstat(lockfd).st_dev, os.fstat(lockfd).st_ino)
    require(lock_identity ==
            (lock_path.stat().st_dev, lock_path.stat().st_ino), "lock identity changed", 2)
    if (root / "state.json").exists() or (root / "state.json").is_symlink():
        state = load(root / "state.json")
        require(isinstance(state, dict) and state.get("kind") == "dsr-release-build-state" and state.get("schema_version") == 1 and
                state.get("plan") == plan and state.get("plan_sha256") == plan_hash and
                isinstance(state.get("jobs"), dict) and set(state["jobs"]) == {j["id"] for j in plan["builds"]}, "conflicting or damaged build state", 2)
        require(load(root / "plan.json") == plan, "retained plan changed", 2)
    else:
        require({p.name for p in root.iterdir()} <= {"lock", "plan.json"}, "refusing an unrelated output directory", 2)
        state = {"schema_version": 1, "kind": "dsr-release-build-state", "run_id": str(uuid.uuid4()),
                 "plan": plan, "plan_sha256": plan_hash,
                 "jobs": {j["id"]: {"attempts": [], "complete": None, "candidate": None} for j in plan["builds"]}}
        if (root / "plan.json").exists() or (root / "plan.json").is_symlink():
            require(load(root / "plan.json") == plan, "conflicting interrupted initialization", 2)
        else:
            write(root / "plan.json", plan)
        write(root / "state.json", state)
    state_hash = digest(root / "state.json")
    for dirname in ("attempts", "completed"):
        plain(root / dirname)
        (root / dirname).mkdir(mode=0o700, exist_ok=True)
    require({p.name for p in (root / "completed").iterdir()} <= set(state["jobs"]), "unexpected completed build")
    queued = []
    for job in plan["builds"]:
        record = state["jobs"][job["id"]]
        require(isinstance(record, dict) and set(record) == {"attempts", "complete", "candidate"} and
                isinstance(record["attempts"], list), "invalid job checkpoint", 2)
        for number, attempt in enumerate(record["attempts"], 1):
            require(isinstance(attempt, dict) and set(attempt) == {"number", "status", "exit_code"} and attempt["number"] == number and
                    attempt["status"] in ("starting", "running", "failed", "interrupted", "completed") and
                    (attempt["exit_code"] is None or integer(attempt["exit_code"], 0, 255)), "invalid attempt checkpoint", 2)
        destination = root / "completed" / job["id"]
        entry = record["complete"] or record["candidate"]
        if destination.exists() or destination.is_symlink():
            require(isinstance(entry, dict) and record["attempts"] and entry.get("id") == job["id"] and entry.get("targets") == job["targets"] and
                    sha(entry.get("manifest_sha256")), "unbound completed build", 2)
            with tempfile.TemporaryDirectory(prefix=".verify-", dir=root) as temporary:
                helper("_rb_verify_shard", entry, destination, Path(temporary))
            record["complete"], record["candidate"] = entry, None
            record["attempts"][-1].update(status="completed", exit_code=0)
        else:
            require(record["complete"] is None, "completed build disappeared")
            if record["attempts"] and record["attempts"][-1]["status"] in ("running", "starting"):
                record["attempts"][-1].update(status="interrupted", exit_code=5)
            record["candidate"] = None
            queued.append(job)
    save_state()
    # Work-conserving bounded scheduling; one failed job does not cancel useful
    # independent builds. Failed attempts are never silently overwritten.
    while queued or active:
        if interrupted:
            raise Failure("build-plan execution interrupted", 5)
        while queued and len(active) < args.jobs:
            start_job(queued.pop(0))
            if interrupted:
                break
        for identity, item in list(active.items()):
            if item[0].poll() is not None:
                active.pop(identity)
                finish_job(item)
        if active:
            time.sleep(0.05)
    save_state()
    require(not interrupted, "build-plan execution interrupted", 5)
    failed = [j["id"] for j in plan["builds"] if state["jobs"][j["id"]]["complete"] is None]
    result = {"kind": "dsr-release-builds", "status": "incomplete" if failed else "verified", "exit_code": 1 if failed else 0,
              "dry_run": False, "publishable": not failed, "output_dir": str(root), "plan_sha256": plan_hash,
              "failed_builds": failed, "completed_builds": len(plan["builds"]) - len(failed)}
    if not failed:
        collection = {key: plan[key] for key in ("schema_version", "repo", "tool", "tag", "source_sha", "required_targets")}
        collection["builds"] = [selected(j, root / "completed" / j["id"] / "build-manifest.json", root / "completed" / j["id"] / "artifacts",
                                          state["jobs"][j["id"]]["complete"]["manifest_sha256"]) for j in plan["builds"]]
        if (root / "build-set.json").exists():
            require(load(root / "build-set.json") == collection, "completed build-set identity changed")
        else:
            write(root / "build-set.json", collection)
        require(digest(root / "state.json") == state_hash and load(root / "plan.json") == plan, "state changed before collection", 2)
        with tempfile.TemporaryDirectory(prefix=".collect-result-", dir=root) as temporary:
            result_path = Path(temporary) / "bundle.json"
            with open(result_path, "wb") as output:
                code = subprocess.call(["bash", str(module / "release_bundle.sh"), "--plan", str(root / "build-set.json"),
                                        "--output-dir", str(root / "bundle")], stdout=output, pass_fds=(lockfd,))
            require(code == 0, "complete build-set failed bundle admission", code if 0 < code < 256 else 7)
            bundle = load(result_path)
        require(bundle.get("status") == "verified" and bundle.get("publishable") is True, "collector did not verify the build set")
        result.update(bundle=bundle, build_set=str(root / "build-set.json"), build_set_sha256=digest(root / "build-set.json"))
    require(not interrupted, "build-plan execution interrupted", 5)
    print(canonical(result).decode(), end="")
    sys.exit(result["exit_code"])
except (Failure, OSError, ValueError, TypeError, KeyError) as error:
    code = getattr(error, "code", 7)
    print("[release-builds] " + str(error), file=sys.stderr)
    print(canonical({"kind": "dsr-release-builds", "status": "error", "exit_code": code,
                     "publishable": False, "error": str(error)}).decode(), end="")
    sys.exit(code)
finally:
    # Only this invocation's owned process groups are signaled. Retain the
    # coordinator lock until all of them are dead, including timeout children.
    for item in active.values():
        kill_group(item[0], signal.SIGTERM)
    if active:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and any(i[0].poll() is None for i in active.values()):
            time.sleep(0.05)
    for item in active.values():
        kill_group(item[0], signal.SIGKILL)
        item[0].wait()
    if lockfd is not None:
        os.close(lockfd)
PY
}

release_build_plan() ( _rbuild_execute "$@"; )

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _rbuild_execute "$@"
fi
