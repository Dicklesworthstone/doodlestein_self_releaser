#!/usr/bin/env bash
# Generate a self-contained installer using the existing authenticated engines.
# Policy is data; source bytes come from this installation, never a release URL.
_INSTALL_GEN_RELEASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

install_gen_release() (
    command -v python3 >/dev/null || return 3
    exec python3 - "$_INSTALL_GEN_RELEASE_DIR" "$@" <<'PY'
import argparse
import ast
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile


class Failure(Exception):
    def __init__(self, message, code=4):
        super().__init__(message)
        self.code = code


def need(condition, message, code=4):
    if not condition:
        raise Failure(message, code)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def pairs(items):
    value = {}
    for key, item in items:
        need(key not in value, "duplicate JSON key: " + key)
        value[key] = item
    return value


def plain(value):
    p = Path(value)
    need(str(p) == value and value.startswith("/") and value != "/" and
         all(part not in ("", ".", "..") for part in value[1:].split("/")) and
         not any(ord(c) < 32 or ord(c) == 127 or c == "\\" for c in value), "noncanonical absolute path")
    for ancestor in [*reversed(p.parents), p]:
        need(not ancestor.is_symlink(), "symlink in selected path", 7)
        if ancestor != p and ancestor.exists():
            need(ancestor.is_dir(), "non-directory path component", 7)
    return p


def read(p, limit):
    plain(str(p))
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        before = os.fstat(f.fileno())
        need(stat.S_ISREG(before.st_mode) and before.st_size <= limit, "invalid or excessive input file")
        data = f.read(limit + 1)
        after = os.fstat(f.fileno())
    need(len(data) <= limit and (before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
         (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), "input changed while reading", 7)
    return data


def text(v, maximum=4096):
    return isinstance(v, str) and 0 < len(v) <= maximum and not any(ord(c) < 32 or ord(c) == 127 for c in v)


def matches(v, pattern):
    return isinstance(v, str) and re.fullmatch(pattern, v) is not None


MODULES = ("release_install.sh", "slsa_remote.sh", "slsa.sh", "packaging.sh", "sbom_release.sh", "sbom.sh", "github.sh")
# No module code or policy value is interpolated into executable Python/shell.
# The only substitution is an ASCII base64-encoded JSON literal.
BOOTSTRAP = r'''#!/usr/bin/env bash
# Pinned authenticated release installer. Trust this script's distribution.
# Embedded checksums detect corruption; they do not authenticate this script.
set -uo pipefail
command -v python3 >/dev/null || { printf '%s\n' 'python3 is required' >&2; exit 3; }
exec python3 - "$@" <<'DSR_RELEASE_INSTALLER_PY'
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import stat
import subprocess
import sys
import tempfile

BUNDLE = '__DSR_RELEASE_BUNDLE__'
BUNDLE_SHA256 = '__DSR_RELEASE_BUNDLE_SHA256__'
child = None
interrupted = False
result = None

class Failure(Exception):
    def __init__(self, message, code=4):
        super().__init__(message)
        self.code = code

def need(condition, message, code=4):
    if not condition:
        raise Failure(message, code)

def plain(value):
    p = Path(value)
    need(str(p) == value and value.startswith("/") and value != "/" and
         all(part not in ("", ".", "..") for part in value[1:].split("/")) and
         not any(ord(c) < 32 or ord(c) == 127 or c == "\\" for c in value), "noncanonical absolute path")
    for a in [*reversed(p.parents), p]:
        need(not a.is_symlink(), "symlink in selected path", 7)
        if a != p and a.exists():
            need(a.is_dir(), "non-directory path component", 7)
    return p

def stop(signum, frame):
    global interrupted
    interrupted = True
    if child is not None and child.poll() is None:
        # The engine owns its verification/extraction groups and activation
        # bookkeeping. Let it report whether the pointer switch occurred.
        child.send_signal(signum)

for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, stop)

try:
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            raise Failure(message)
    parser = Parser(description="Install the fixed signed release embedded in this installer.", allow_abbrev=False)
    parser.add_argument("--prefix", help="Managed installation prefix with an existing parent")
    parser.add_argument("--snapshot", help="Use a complete local snapshot, without any network access")
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--allow-draft", action="store_true", help="Explicitly permit a draft when fetching")
    parser.add_argument("--dry-run", action="store_true", help="Authenticate and stage only; online by default")
    parser.add_argument("--inspect", action="store_true", help="Print embedded policy and engine hashes, without authentication or writes")
    parser.add_argument("--timeout", type=int, default=900)
    flags = [a.split("=", 1)[0] for a in sys.argv[1:] if a.startswith("--")]
    need(len(flags) == len(set(flags)), "duplicate installer option")
    args = parser.parse_args()
    need(not interrupted, "installation interrupted", 5)
    need(1 <= args.timeout <= 86400, "timeout must be 1..86400")
    need(not args.allow_draft or args.snapshot is None, "--allow-draft is online-only")
    blob = base64.b64decode(BUNDLE, validate=True)
    need(hashlib.sha256(blob).hexdigest() == BUNDLE_SHA256, "embedded installer data is damaged", 7)
    bundle = json.loads(blob)
    policy = bundle["policy"]
    expected = {"release_install.sh", "slsa_remote.sh", "slsa.sh", "packaging.sh", "sbom_release.sh", "sbom.sh", "github.sh"}
    need(set(bundle["modules"]) == expected, "embedded engine inventory changed", 7)
    modules = {}
    for name, record in bundle["modules"].items():
        data = base64.b64decode(record["content"], validate=True)
        need(hashlib.sha256(data).hexdigest() == record["sha256"], "embedded engine is damaged", 7)
        modules[name] = data
    if args.inspect:
        need(not any(f != "--inspect" for f in flags), "--inspect is a standalone operation")
        print(json.dumps(dict(kind="dsr-release-installer-policy", authenticated=False, policy=policy,
                             public_key=bundle["public_key"], engines={n: r["sha256"] for n, r in bundle["modules"].items()}), sort_keys=True))
        sys.exit(0)
    need(args.prefix is not None, "--prefix is required")
    prefix = plain(args.prefix)
    need(prefix.parent.is_dir(), "prefix parent must exist")
    if args.snapshot is not None:
        snapshot = plain(args.snapshot)
        need(snapshot.is_dir(), "snapshot must be a directory")
        need(snapshot != prefix and prefix not in snapshot.parents and snapshot not in prefix.parents, "prefix overlaps snapshot")
    os_name = {"Linux": "linux", "Darwin": "darwin"}.get(platform.system())
    arch = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64", "i386": "386", "i686": "386"}.get(platform.machine().lower())
    need(os_name is not None and arch is not None, "unsupported installation host", 3)
    target = os_name + "/" + arch
    selected = [r for r in policy["recipes"] if r["target"] == target]
    need(len(selected) == 1, "this installer has no recipe for this host", 3)
    os.umask(0o077)
    need(not interrupted, "installation interrupted", 5)
    with tempfile.TemporaryDirectory(prefix=".dsr-installer-", dir=prefix.parent) as temporary:
        work = Path(temporary)
        for name, data in modules.items():
            (work / name).write_bytes(data)
            (work / name).chmod(0o400)
        (work / "recipe.json").write_text(json.dumps(selected[0]) + "\n")
        (work / "trusted.pub").write_text("untrusted comment: generated installer pinned key\n" + bundle["public_key"] + "\n")
        command = ["bash", str(work / "release_install.sh"), "--prefix", str(prefix), "--recipe", str(work / "recipe.json"),
                   "--public-key", str(work / "trusted.pub"), "--repo", policy["repo"], "--tag", policy["tag"],
                   "--sha", policy["source_sha"], "--builder", policy["builder"], "--targets", ",".join(policy["targets"]),
                   "--timeout", str(args.timeout)]
        command += ["--snapshot", args.snapshot] if args.snapshot is not None else ["--fetch"]
        for key in ("statement_sha256", "manifest_sha256", "invocation_id"):
            if key in policy:
                command += ["--" + key.replace("_", "-"), policy[key]]
        for flag in ("replace", "dry_run", "allow_draft"):
            if getattr(args, flag):
                command.append("--" + flag.replace("_", "-"))
        env = {k: v for k, v in os.environ.items() if not k.startswith("BASH_FUNC_") and k not in ("BASH_ENV", "ENV")}
        need(not interrupted, "installation interrupted", 5)
        with (work / "result.json").open("wb") as out:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, env=env, start_new_session=True)
            # A signal between spawn and assignment cannot expose a success:
            # forward any already-recorded interruption as soon as owned.
            if interrupted:
                child.send_signal(signal.SIGTERM)
            rc = child.wait()
        raw = (work / "result.json").read_bytes()
        need(raw, "installation engine returned no result", 5 if interrupted else 7)
        result = json.loads(raw)
        need(isinstance(result, dict) and result.get("kind") == "dsr-release-install" and
             type(result.get("exit_code")) is int and result["exit_code"] == rc, "invalid installation result", 7)
        print(json.dumps(result, sort_keys=True))
        sys.exit(rc)
except (Failure, OSError, ValueError, TypeError, KeyError) as error:
    code = getattr(error, "code", 7)
    print("[release-installer] " + str(error), file=sys.stderr)
    # Never turn an acknowledged activation into an asserted non-activation.
    activated = result.get("activated", False) if isinstance(result, dict) else None if child is not None else False
    print(json.dumps(dict(kind="dsr-release-install", status="error", exit_code=code, activated=activated, error=str(error))))
    sys.exit(code)
finally:
    if child is not None and child.poll() is None:
        child.send_signal(signal.SIGTERM)
        child.wait()
DSR_RELEASE_INSTALLER_PY
'''


lockfd = None
child = None

def stop(signum, frame):
    raise Failure("installer generation interrupted", 5)

for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, stop)

try:
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            raise Failure(message)
    parser = Parser(description="Generate a pinned, standalone authenticated release installer; no downloads or signing.", allow_abbrev=False)
    for flag in ("policy", "public-key", "output"):
        parser.add_argument("--" + flag, required=True)
    parser.add_argument("--replace", action="store_true", help="Permit replacing an existing regular installer file")
    flags = [a.split("=", 1)[0] for a in sys.argv[2:] if a.startswith("--")]
    need(len(flags) == len(set(flags)), "duplicate generator option")
    args = parser.parse_args(sys.argv[2:])
    module = plain(sys.argv[1])
    policy_file, key_file, output = (plain(v) for v in (args.policy, args.public_key, args.output))
    need(output.parent.is_dir(), "output parent must exist")
    source_paths = [module / name for name in MODULES]
    need(output not in source_paths + [policy_file, key_file] and
         Path(str(output) + ".lock") not in source_paths + [policy_file, key_file], "output overlaps generator inputs")
    policy_bytes = read(policy_file, 1048576)
    value = json.loads(policy_bytes, object_pairs_hook=pairs,
                      parse_constant=lambda s: (_ for _ in ()).throw(Failure("non-finite JSON number")))
    required = {"schema_version", "repo", "tag", "source_sha", "builder", "targets", "recipes"}
    optional = {"statement_sha256", "manifest_sha256", "invocation_id"}
    need(isinstance(value, dict) and required <= set(value) <= required | optional and
         type(value["schema_version"]) is int and value["schema_version"] == 1, "invalid installer policy")
    need(matches(value["repo"], r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*") and ".." not in value["repo"] and
         matches(value["tag"], r"v[0-9]+\.[0-9]+\.[0-9]+(?:[+-][A-Za-z0-9.+-]+)?") and
         matches(value["source_sha"], r"[0-9a-f]{40}") and value["source_sha"] != "0" * 40 and text(value["builder"]),
         "invalid pinned release identity")
    need(isinstance(value["targets"], list) and 1 <= len(value["targets"]) <= 9 and
         all(matches(t, r"(linux|darwin|windows)/(amd64|arm64|386)") for t in value["targets"]) and
         len(set(value["targets"])) == len(value["targets"]), "invalid complete target matrix")
    value["targets"].sort()
    for key in optional & set(value):
        need(text(value[key]) if key == "invocation_id" else matches(value[key], r"[0-9a-f]{64}"), "invalid independent build pin")
    need(isinstance(value["recipes"], list) and 1 <= len(value["recipes"]) <= 6, "expected 1..6 installation recipes")
    key_bytes = read(key_file, 8192)
    lines = key_bytes.decode("utf-8").splitlines()
    need(len(lines) == 2 and lines[0].startswith("untrusted comment:") and matches(lines[1], r"[A-Za-z0-9+/]{56}"), "invalid Minisign public key file")
    sources = {p.name: read(p, 2097152) for p in source_paths}
    need(sum(map(len, sources.values())) <= 8388608, "installer engine bundle exceeds size limit")
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix=".dsr-installer-gen-", dir=output.parent) as temporary:
        work = Path(temporary)
        for name, data in sources.items():
            (work / name).write_bytes(data)
            (work / name).chmod(0o400)
        normalized = []
        env = {k: v for k, v in os.environ.items() if not k.startswith("BASH_FUNC_") and k not in ("BASH_ENV", "ENV")}
        for i, item in enumerate(value["recipes"]):
            file = work / ("recipe-%d.json" % i)
            file.write_bytes(canonical(item))
            child = subprocess.Popen(["bash", str(work / "release_install.sh"), "describe-recipe", "--recipe", str(file)],
                                     env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            response, diagnostics = child.communicate(timeout=30)
            need(child.returncode == 0, "invalid installation recipe", child.returncode if 0 < child.returncode < 256 else 7)
            record = json.loads(response, object_pairs_hook=pairs)
            need(record.get("kind") == "dsr-install-recipe" and record.get("authenticated") is False, "invalid recipe validation result", 7)
            normalized.append(record["recipe"])
            child = None
        wanted = [t for t in value["targets"] if not t.startswith("windows/")]
        need(sorted(r["target"] for r in normalized) == wanted, "recipes must cover every declared POSIX target exactly once")
        value["recipes"] = sorted(normalized, key=lambda r: r["target"])
        inventory = {name: dict(content=base64.b64encode(data).decode(), sha256=hashlib.sha256(data).hexdigest()) for name, data in sources.items()}
        bundle = canonical(dict(policy=value, public_key=lines[1], modules=inventory))
        script = BOOTSTRAP.replace("__DSR_RELEASE_BUNDLE__", base64.b64encode(bundle).decode()).replace("__DSR_RELEASE_BUNDLE_SHA256__", hashlib.sha256(bundle).hexdigest())
        ast.parse(script.split("<<'DSR_RELEASE_INSTALLER_PY'\n", 1)[1].rsplit("\nDSR_RELEASE_INSTALLER_PY", 1)[0])
        staged = work / "install.sh"
        staged.write_text(script, encoding="utf-8")
        staged.chmod(0o755)
        child = subprocess.Popen(["bash", "-n", str(staged)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        child.communicate(timeout=30)
        need(child.returncode == 0, "generated shell syntax is invalid", 7)
        child = None
        need(read(policy_file, 1048576) == policy_bytes and read(key_file, 8192) == key_bytes and
             all(read(p, 2097152) == sources[p.name] for p in source_paths), "generator inputs changed", 7)
        lock = plain(str(output) + ".lock")
        lockfd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        held = os.fstat(lockfd)
        need(stat.S_ISREG(held.st_mode), "invalid generator lock", 2)
        try:
            fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Failure("installer generation already active", 2)
        plain(str(output))
        data = script.encode("utf-8")
        same = output.exists() and read(output, 33554432) == data and stat.S_IMODE(output.stat().st_mode) == 0o755
        need(not output.exists() or same or args.replace, "existing installer requires --replace", 2)
        named = plain(str(lock)).stat()
        need((held.st_dev, held.st_ino) == (named.st_dev, named.st_ino), "generator lock changed", 2)
        if not same:
            os.replace(staged, output)
        print(canonical(dict(kind="dsr-release-installer-generation", status="generated", exit_code=0, output=str(output),
                             sha256=hashlib.sha256(data).hexdigest(), policy_sha256=hashlib.sha256(canonical(value)).hexdigest(),
                             targets=wanted, reused=same, authenticated=False,
                             engines={n: r["sha256"] for n, r in inventory.items()})).decode(), end="")
except (Failure, OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired) as error:
    code = 5 if isinstance(error, subprocess.TimeoutExpired) else getattr(error, "code", 7)
    print("[install-gen-release] " + str(error), file=sys.stderr)
    print(canonical(dict(kind="dsr-release-installer-generation", status="error", exit_code=code, error=str(error))).decode(), end="")
    sys.exit(code)
finally:
    if child is not None:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
    if lockfd is not None:
        os.close(lockfd)
PY
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    install_gen_release "$@"
fi
