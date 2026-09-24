#!/usr/bin/env bash
# Turn a pinned producer manifest into installer-ready release payloads.
# Archive safety, extraction and payload parity use the existing packaging API;
# both input and output manifests pass the shared successful-release admission.
_RELEASE_PACKAGING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_rpackage_execute() {
    command -v python3 >/dev/null || return 3
    exec python3 - "$_RELEASE_PACKAGING_DIR" "$@" <<'PY'
import argparse
import copy
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

class Failure(Exception):
    def __init__(self, message, code=7):
        super().__init__(message)
        self.code = code

def need(value, message, code=7):
    if not value:
        raise Failure(message, code)

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()

def pairs(items):
    result = {}
    for key, value in items:
        need(key not in result, "duplicate JSON key: " + key, 4)
        result[key] = value
    return result

def match(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None

def name(value):
    return match(value, r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}") and ".." not in value

def path(value):
    need(isinstance(value, str) and value.startswith("/") and value != "/" and
         not any(ord(c) < 32 or ord(c) == 127 or c == "\\" for c in value) and
         all(p not in ("", ".", "..") for p in value[1:].split("/")), "invalid absolute path", 4)
    p = Path(value)
    for ancestor in [*reversed(p.parents), p]:
        need(not ancestor.is_symlink(), "symlink in selected path: " + str(ancestor))
        if ancestor != p and ancestor.exists():
            need(ancestor.is_dir(), "non-directory path component")
    return p

def regular(p):
    path(str(p))
    need(p.is_file(), "missing regular file: " + str(p))
    return p

def digest(p):
    regular(p)
    h = hashlib.sha256()
    with p.open("rb") as f:
        before = os.fstat(f.fileno())
        for block in iter(lambda: f.read(1048576), b""):
            h.update(block)
        after = os.fstat(f.fileno())
    need((before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
         (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), "file changed while hashing")
    return h.hexdigest()

def load(p):
    with regular(p).open(encoding="utf-8") as f:
        return json.load(f, object_pairs_hook=pairs,
                         parse_constant=lambda s: (_ for _ in ()).throw(Failure("non-finite JSON number", 4)))

def write(p, value):
    with p.open("xb") as f:
        f.write(canonical(value))

ARCHIVES = {"tar.gz", "tar.xz", "zip"}
RAW = {"binary", "none"}

def file_format(filename):
    for suffix, fmt in ((".tar.gz", "tar.gz"), (".tgz", "tar.gz"), (".tar.xz", "tar.xz"), (".zip", "zip")):
        if filename.endswith(suffix):
            return fmt
    return "none"

def recipe(value):
    need(isinstance(value, dict) and set(value) == {"schema_version", "artifacts"} and
         type(value["schema_version"]) is int and value["schema_version"] == 1 and
         isinstance(value["artifacts"], list) and 1 <= len(value["artifacts"]) <= 256, "invalid packaging recipe", 4)
    outputs, sources = [], set()
    for item in value["artifacts"]:
        need(isinstance(item, dict), "invalid packaging artifact", 4)
        base = {"name", "target", "archive_format"}
        need(base <= set(item) <= base | {"source", "members", "aliases"} and
             ("source" in item) != ("members" in item), "select source or members, not both", 4)
        need(name(item["name"]) and match(item["target"], r"(linux|darwin|windows)/(amd64|arm64|386)") and
             isinstance(item["archive_format"], str) and item["archive_format"] in ARCHIVES | RAW,
             "invalid packaging name, target or format", 4)
        item.setdefault("aliases", [])
        need(isinstance(item["aliases"], list) and all(name(n) for n in item["aliases"]), "invalid aliases", 4)
        for n in [item["name"], *item["aliases"]]:
            need(file_format(n) == (item["archive_format"] if item["archive_format"] in ARCHIVES else "none"),
                 "output suffix disagrees with format: " + n, 4)
            outputs.append({"name": n, "target": item["target"], "archive_format": item["archive_format"]})
        item["aliases"].sort()
        if "source" in item:
            need(name(item["source"]), "invalid source name", 4)
            sources.add((item["source"], item["target"]))
        else:
            need(item["archive_format"] in ARCHIVES and isinstance(item["members"], list) and
                 1 <= len(item["members"]) <= 256, "members require an archive format", 4)
            paths = []
            for member in item["members"]:
                need(isinstance(member, dict) and set(member) == {"source", "path"} and
                     name(member["source"]) and name(member["path"]), "archive members must be safe flat names", 4)
                paths.append(member["path"].lower())
                sources.add((member["source"], item["target"]))
            need(len(set(paths)) == len(paths), "colliding archive member names", 4)
            item["members"].sort(key=lambda m: m["path"])
    need(len(outputs) <= 256 and len({a["name"].lower() for a in outputs}) == len(outputs),
         "colliding or excessive output/alias names", 4)
    value["artifacts"].sort(key=lambda a: a["name"])
    return value, sorted(outputs, key=lambda a: a["name"]), [dict(name=n, target=t) for n, t in sorted(sources)]

module = Path(sys.argv[1])
child = None
lock = None

def interrupt(signum, frame):
    raise Failure("packaging interrupted", 5)

for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, interrupt)

def helper(module_name, function, *arguments):
    global child
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("BASH_FUNC_") or key in ("BASH_ENV", "ENV", "TAR_OPTIONS", "GZIP", "XZ_OPT", "XZ_DEFAULTS", "ZIPOPT", "UNZIP", "UNZIPOPT"):
            env.pop(key)
    env.update(LC_ALL="C", TZ="UTC", COPYFILE_DISABLE="1")
    # Inherit advisory locks through the bounded helper. Arguments are never
    # interpolated into the fixed shell program or interpreted as shell text.
    command = ['bash', '-c', 'source "$1/$2.sh" || exit 3; shift 2; "$@"', '_', str(module), module_name, function]
    child = subprocess.Popen(command + [str(a) for a in arguments], env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, start_new_session=True, close_fds=False)
    try:
        output, _ = child.communicate(timeout=900)
        need(child.returncode == 0, "packaging/admission helper failed: " + function,
             child.returncode if 0 < child.returncode < 256 else 5)
        return output.decode("utf-8").rstrip("\n")
    except subprocess.TimeoutExpired:
        raise Failure("packaging helper timed out", 5)
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        child = None

def admit(manifest, artifacts, work):
    proof = work / "proof.json"
    proof.write_text(helper("slsa", "_slsa_manifest_statement", manifest, args.repo, "dsr:release-packaging") + "\n")
    helper("slsa", "_slsa_release_assets", proof, artifacts)
    value = load(manifest)
    need(value["source"]["git_sha"] == args.sha and "v" + value["version"].lstrip("v") == args.tag,
         "producer identity differs from selected release", 4)
    return value

def source_contract(value):
    records = {a["name"]: a for a in value["artifacts"]}
    need(len(records) <= 256 and len({n.lower() for n in records}) == len(records), "invalid source asset namespace", 4)
    need({(a["name"], a["target"]) for a in inputs} == {(a["name"], a["target"]) for a in records.values()},
         "recipe must consume every producer asset and no unlisted asset", 4)
    for item in selected["artifacts"]:
        if "members" in item:
            need(all(records[m["source"]]["archive_format"] in RAW and file_format(m["source"]) == "none"
                     for m in item["members"]), "archives cannot be nested as raw members", 4)
        else:
            original = records[item["source"]]["archive_format"]
            need((original in RAW and item["archive_format"] in RAW) or
                 (original in ARCHIVES and item["archive_format"] in ARCHIVES), "use members to package raw files", 4)
    return records

def bits(p):
    return stat.S_IMODE(regular(p).stat().st_mode) & 0o111

def copy_payload(source, dest):
    regular(source)
    executable = bits(source)
    with source.open("rb") as incoming, dest.open("xb") as outgoing:
        shutil.copyfileobj(incoming, outgoing, 1048576)
    dest.chmod(0o644 | executable)
    need(digest(dest) == digest(source) and bits(source) == executable, "source changed during snapshot")

def materialize(base, records, work, build):
    for index, item in enumerate(selected["artifacts"]):
        dest = base / "artifacts" / item["name"]
        fmt = item["archive_format"]
        payload = work / ("payload-%d" % index)
        payload.mkdir()
        if "members" in item:
            members = []
            for member in item["members"]:
                source = base / "source/artifacts" / member["source"]
                with source.open("rb") as f:
                    magic = f.read(512)
                need(not (magic.startswith((b"\x1f\x8b", b"\xfd7zXZ\x00", b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08")) or
                          magic[257:262] == b"ustar"), "archive bytes cannot masquerade as a raw member", 4)
                copy_payload(source, payload / member["path"])
                members.append(member["path"])
            if build:
                helper("packaging", "packaging_build_archive", fmt, dest, payload, *members)
            helper("packaging", "_pkg_archive_matches_payload", dest, fmt, payload, "\n".join(members))
        else:
            source = base / "source/artifacts" / item["source"]
            original = records[item["source"]]["archive_format"]
            if original in ARCHIVES:
                helper("packaging", "packaging_extract_payload", source, original, payload)
                members = helper("packaging", "packaging_payload_members", source, original)
                if build:
                    helper("packaging", "packaging_repack_archive", source, original, dest, fmt)
                helper("packaging", "_pkg_archive_matches_payload", dest, fmt, payload, members)
            elif build:
                copy_payload(source, dest)
            if original == fmt or original in RAW:
                need(digest(dest) == digest(source), "authoritative source bytes changed")
            if original in RAW:
                need(bits(dest) == bits(source), "raw executable mode changed")
        for alias in item["aliases"]:
            out = base / "artifacts" / alias
            if build:
                copy_payload(dest, out)
            need(digest(out) == digest(dest) and bits(out) == bits(dest), "alias differs from its primary")

def derived_manifest(source, base):
    result = copy.deepcopy(source)
    # Checksums and signatures for pre-packaging bytes are not proofs for the
    # new namespace. Signing/SBOM/provenance still belong to the finalizer.
    for key in ("checksums_file", "signature_file", "sbom_file"):
        result.pop(key, None)
    result["artifacts"] = [dict(a, sha256=digest(base / "artifacts" / a["name"]),
                                size_bytes=(base / "artifacts" / a["name"]).stat().st_size,
                                signed=False, signature_file="", build_purpose="release", publishable=True)
                           for a in expected_assets]
    result["required_assets"] = expected_assets
    result["packaging_evidence"] = dict(kind="manifest-bound-packaging", schema_version=1,
        source_manifest_sha256=args.manifest_sha256, recipe_sha256=recipe_hash, recipe=selected,
        source_executable_bits={a["name"]: bits(base / "source/artifacts" / a["name"]) for a in source["artifacts"]})
    return result

def result_for(base):
    return dict(kind="dsr-release-packaging", status="verified", exit_code=0, publishable=True,
                source_manifest_sha256=args.manifest_sha256, recipe_sha256=recipe_hash,
                manifest=str(root / "release/build-manifest.json"), manifest_sha256=digest(base / "build-manifest.json"),
                artifacts_dir=str(root / "release/artifacts"))

def verify(base, work):
    path(str(base))
    need(load(base / "recipe.json") == selected and digest(base / "source/build-manifest.json") == args.manifest_sha256,
         "packaging inputs changed", 2)
    value = admit(base / "source/build-manifest.json", base / "source/artifacts", work)
    records = source_contract(value)
    for directory, names in ((base / "artifacts", {a["name"] for a in expected_assets}),
                             (base / "source/artifacts", set(records))):
        path(str(directory))
        need({p.name for p in directory.iterdir()} == names, "packaging file namespace changed")
        for p in directory.iterdir():
            regular(p)
    with tempfile.TemporaryDirectory(prefix="verify-", dir=work) as temporary:
        materialize(base, records, Path(temporary), False)
    need(load(base / "build-manifest.json") == derived_manifest(value, base), "packaged manifest changed")
    admit(base / "build-manifest.json", base / "artifacts", work)
    need(load(base / "result.json") == result_for(base), "packaging completion receipt changed")

try:
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            raise Failure(message, 4)
    parser = Parser(description="Package a pinned producer manifest; no signing or network writes.", allow_abbrev=False)
    parser.add_argument("--recipe", required=True)
    parser.add_argument("--describe", action="store_true")
    for option in ("manifest", "manifest-sha256", "artifacts-dir", "output-dir", "repo", "tag", "sha"):
        parser.add_argument("--" + option)
    flags = [a.split("=", 1)[0] for a in sys.argv[2:] if a.startswith("--")]
    need(len(flags) == len(set(flags)), "duplicate packaging option", 4)
    args = parser.parse_args(sys.argv[2:])
    selected, expected_assets, inputs = recipe(load(path(args.recipe)))
    recipe_hash = hashlib.sha256(canonical(selected)).hexdigest()
    if args.describe:
        need(all(getattr(args, o) is None for o in ("manifest", "manifest_sha256", "artifacts_dir", "output_dir", "repo", "tag", "sha")),
             "describe accepts only a recipe", 4)
        print(canonical(dict(kind="dsr-release-packaging-plan", recipe=selected, recipe_sha256=recipe_hash,
                             required_assets=expected_assets, inputs=inputs)).decode(), end="")
        sys.exit(0)
    need(match(args.repo, r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*") and ".." not in args.repo and
         match(args.tag, r"v[0-9]+\.[0-9]+\.[0-9]+(?:[+-][A-Za-z0-9.+-]+)?") and
         match(args.sha, r"[0-9a-f]{40}") and args.sha != "0" * 40 and
         match(args.manifest_sha256, r"[0-9a-f]{64}"), "invalid release or manifest pin", 4)
    root, incoming, original = path(args.output_dir), path(args.artifacts_dir), path(args.manifest)
    need(root != incoming and incoming not in root.parents and root not in incoming.parents and root not in original.parents,
         "packaging output overlaps producer inputs", 4)
    need(root.parent.is_dir(), "output parent does not exist", 4)
    for tool in ("bash", "jq"):
        need(shutil.which(tool), "missing dependency: " + tool, 3)
    os.umask(0o077)
    root.mkdir(mode=0o700, exist_ok=True)
    lock_path = path(str(root / "lock"))
    lock = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    need(stat.S_ISREG(os.fstat(lock).st_mode), "invalid packaging lock", 2)
    os.set_inheritable(lock, True)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise Failure("packaging is already active", 2)
    identity = dict(recipe_sha256=recipe_hash, source_manifest_sha256=args.manifest_sha256,
                    repo=args.repo, tag=args.tag, source_sha=args.sha)
    if (root / "identity.json").exists() or (root / "identity.json").is_symlink():
        need(load(root / "identity.json") == identity, "conflicting packaging selection", 2)
    else:
        need({p.name for p in root.iterdir()} == {"lock"}, "refusing unrelated packaging output", 2)
        write(root / "identity.json", identity)
    with tempfile.TemporaryDirectory(prefix=".package-", dir=root) as temporary:
        work = Path(temporary)
        final = root / "release"
        if final.exists() or final.is_symlink():
            verify(final, work)
        else:
            need(digest(original) == args.manifest_sha256, "producer manifest pin mismatch")
            source = admit(original, incoming, work)
            records = source_contract(source)
            staged = work / "release"
            (staged / "source/artifacts").mkdir(parents=True)
            (staged / "artifacts").mkdir()
            copy_payload(original, staged / "source/build-manifest.json")
            for n in records:
                copy_payload(incoming / n, staged / "source/artifacts" / n)
            need(digest(original) == args.manifest_sha256 and digest(staged / "source/build-manifest.json") == args.manifest_sha256,
                 "producer manifest changed during snapshot")
            admit(original, incoming, work)
            write(staged / "recipe.json", selected)
            with tempfile.TemporaryDirectory(prefix="build-", dir=work) as build_work:
                materialize(staged, records, Path(build_work), True)
            write(staged / "build-manifest.json", derived_manifest(source, staged))
            write(staged / "result.json", result_for(staged))
            verify(staged, work)
            need(load(root / "identity.json") == identity, "packaging selection changed", 2)
            need(not final.exists() and not final.is_symlink(), "packaging publication conflict", 2)
            staged.rename(final)
        need(load(root / "identity.json") == identity, "packaging selection changed", 2)
        print(canonical(load(final / "result.json")).decode(), end="")
except (Failure, OSError, ValueError, TypeError, KeyError) as exc:
    code = getattr(exc, "code", 7)
    print("[release-packaging] " + str(exc), file=sys.stderr)
    print(canonical(dict(kind="dsr-release-packaging", status="error", exit_code=code,
                         publishable=False, error=str(exc))).decode(), end="")
    sys.exit(code)
finally:
    if lock is not None:
        os.close(lock)
PY
}

release_package() ( _rpackage_execute "$@"; )

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _rpackage_execute "$@"
fi
