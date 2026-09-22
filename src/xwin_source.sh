#!/usr/bin/env bash
# Committed-source admission for manifest-backed Windows ARM64 builds.
# No checkout mutation, archive export filters, network access, or tag writes.

xwin_source_snapshot() {
    [[ $# == 6 ]] || return 4
    command -v python3 >/dev/null && command -v git >/dev/null || return 3
    _xws_source snapshot "$@"
}

xwin_source_verify() {
    [[ $# == 2 ]] || return 4
    command -v python3 >/dev/null || return 3
    _xws_source verify "$@"
}

_xws_source() {
    python3 - "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

class Rejected(Exception):
    pass

def require(condition, message):
    if not condition:
        raise Rejected(message)

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()

def safe_name(name):
    require(isinstance(name, str) and name and not any(ord(c) < 32 or ord(c) == 127 for c in name), "unsafe source path")
    require(not any(c in name for c in "\\:") and all(p not in ("", ".", "..") and p.lower() != ".git" and not p.startswith("-") for p in name.split("/")), "unsafe source path: " + name)

def inventory(root):
    require(root.is_dir() and not root.is_symlink(), "missing or linked source snapshot")
    files = []
    for directory, dirs, names in os.walk(root, followlinks=False):
        for name in dirs:
            path = Path(directory) / name
            safe_name(path.relative_to(root).as_posix())
            require(stat.S_ISDIR(path.lstat().st_mode), "linked or special source directory")
        for name in names:
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            safe_name(relative)
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as stream:
                before = os.fstat(stream.fileno())
                require(stat.S_ISREG(before.st_mode), "special source file: " + relative)
                digest = hashlib.sha256()
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
                after = os.fstat(stream.fileno())
                require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (after.st_size, after.st_mtime_ns, after.st_ctime_ns), "source changed while reading")
                bits = before.st_mode & 0o111
                require(bits in (0, 0o111), "noncanonical source executable mode")
                files.append({"path": relative, "sha256": digest.hexdigest(), "size_bytes": before.st_size, "executable": bool(bits)})
    return sorted(files, key=lambda item: item["path"])

def read_json(path):
    require(path.is_file() and not path.is_symlink(), "missing or linked source receipt")
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate JSON key")
            result[key] = value
        return result
    with path.open() as stream:
        return json.load(stream, object_pairs_hook=pairs)

def publish(path, value):
    require(path.parent.is_dir() and not path.exists() and not path.is_symlink(), "source receipt destination already exists")
    fd, temporary = tempfile.mkstemp(prefix=".source-receipt.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(canonical(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path)
    finally:
        os.unlink(temporary)

try:
    mode = sys.argv[1]
    if mode == "verify":
        root, receipt = map(Path, sys.argv[2:])
        evidence = read_json(receipt)
        require(evidence.get("schema_version") == 1 and evidence.get("kind") == "dsr-xwin-source", "invalid source receipt")
        files = inventory(root)
        require(files == evidence.get("files"), "source snapshot changed during the build")
        require(hashlib.sha256(canonical(files)).hexdigest() == evidence.get("snapshot_sha256"), "source inventory digest mismatch")
        sys.exit(0)
    require(mode == "snapshot", "unknown source operation")
    project, commit, tag, repo, destination, receipt = sys.argv[2:]
    require(re.fullmatch(r"[0-9a-f]{40}", commit) and commit != "0" * 40, "expected an explicit SHA-1 source commit")
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.+-]+)?", tag), "expected a version tag")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", repo) and ".." not in repo, "invalid release repository")
    project = Path(project)
    require(project.is_dir() and not project.is_symlink(), "invalid project directory")
    project = project.resolve()
    root, receipt = Path(destination), Path(receipt)
    require(root.is_absolute() and root.parent.is_dir() and not root.exists() and not root.is_symlink(), "snapshot destination must be a new absolute directory")
    require(not receipt.is_relative_to(root), "receipt must live outside the source snapshot")
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_NO_REPLACE_OBJECTS="1", GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", LC_ALL="C")
    command = ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=" + os.devnull, "-C", str(project)]
    def git(*args):
        return subprocess.run(command + list(args), env=environment, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    require(Path(os.fsdecode(git("rev-parse", "--show-toplevel")).strip()).resolve() == project, "project must be the Git worktree root")
    require(git("rev-parse", "--verify", "HEAD^{commit}").decode().strip() == commit, "HEAD differs from the selected source commit")
    require(git("rev-parse", "--verify", "refs/tags/" + tag + "^{commit}").decode().strip() == commit, "local release tag differs from the selected commit")
    require(not git("status", "--porcelain=v1", "-z", "--untracked-files=normal"), "source checkout must be clean")
    origin = git("config", "--get", "remote.origin.url").decode().strip()
    require(origin in ("https://github.com/" + repo, "https://github.com/" + repo + ".git",
                       "git@github.com:" + repo, "git@github.com:" + repo + ".git",
                       "ssh://git@github.com/" + repo, "ssh://git@github.com/" + repo + ".git"), "source origin differs from the selected release repository")
    tree = git("rev-parse", "--verify", commit + "^{tree}").decode().strip()
    epoch = git("show", "-s", "--format=%ct", commit).decode().strip()
    require(epoch.isdigit(), "invalid source timestamp")
    records = git("ls-tree", "-r", "-z", "--full-tree", commit).split(b"\0")
    entries = []
    for record in records:
        if not record:
            continue
        header, raw_name = record.split(b"\t", 1)
        file_mode, kind, oid = header.decode("ascii").split(" ")
        name = raw_name.decode("utf-8")
        safe_name(name)
        require(kind == "blob" and file_mode in ("100644", "100755"), "release snapshot refuses links and submodules: " + name)
        require(re.fullmatch(r"[0-9a-f]{40}", oid), "invalid Git object identity")
        entries.append((name, file_mode, oid))
    require(entries and len(entries) <= 100000, "empty or oversized source tree")
    require({"Cargo.toml", "Cargo.lock"}.issubset({item[0] for item in entries}), "Cargo.toml and Cargo.lock must both be committed")
    root.mkdir(mode=0o700)
    # Read raw Git objects, not a working tree or git archive: attributes such
    # as export-ignore/export-subst must not silently change release inputs.
    process = subprocess.Popen(command + ["cat-file", "--batch"], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        for name, file_mode, oid in entries:
            process.stdin.write((oid + "\n").encode("ascii"))
            process.stdin.flush()
            object_header = process.stdout.readline().decode("ascii").split()
            require(len(object_header) == 3 and object_header[:2] == [oid, "blob"] and object_header[2].isdigit(), "invalid Git blob response")
            remaining = int(object_header[2])
            require(remaining <= 1024 ** 3, "source blob exceeds 1 GiB")
            digest = hashlib.sha1(("blob " + str(remaining) + "\0").encode())
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("xb") as stream:
                while remaining:
                    block = process.stdout.read(min(remaining, 1024 * 1024))
                    require(block, "truncated Git blob")
                    stream.write(block)
                    digest.update(block)
                    remaining -= len(block)
            require(process.stdout.read(1) == b"\n" and digest.hexdigest() == oid, "Git source object hash mismatch")
            path.chmod(0o755 if file_mode == "100755" else 0o644)
        process.stdin.close()
        require(process.wait() == 0, "Git source reader failed")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait()
        process.stdout.close()
    files = inventory(root)
    evidence = {"schema_version": 1, "kind": "dsr-xwin-source", "repository": "https://github.com/" + repo,
                "git_sha": commit, "git_ref": "refs/tags/" + tag, "git_tree": tree,
                "source_date_epoch": int(epoch), "files": files,
                "snapshot_sha256": hashlib.sha256(canonical(files)).hexdigest()}
    publish(receipt, evidence)
except (Rejected, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
    print("[xwin-source] " + str(error), file=sys.stderr)
    sys.exit(7 if sys.argv[1] == "verify" else 4)
PY
}

# Validate the selected binary and complete Cargo graph. Every local/path
# package must come from the committed snapshot; sibling/absolute path escapes
# are refused rather than being advertised as pinned source dependencies.
# stdout is a small selection receipt; the full canonical graph stays in a file.
xwin_source_metadata() {
    [[ $# == 6 ]] || return 4
    command -v python3 >/dev/null || return 3
    python3 - "$@" <<'PY'
import hashlib
import json
from pathlib import Path
import stat
import sys

try:
    input_file, root, binary, package, output_file, version = sys.argv[1:]
    root = Path(root).resolve()
    def require(condition, message):
        if not condition:
            raise ValueError(message)
    def pairs(items):
        obj = {}
        for key, value in items:
            require(key not in obj, "duplicate Cargo metadata key")
            obj[key] = value
        return obj
    def local_file(name):
        path = Path(name)
        require(path.is_absolute() and path.is_relative_to(root), "unbound local Cargo source: " + str(name))
        current = root
        for part in path.relative_to(root).parts:
            require(part not in (".", ".."), "noncanonical Cargo source path")
            current /= part
            require(not current.is_symlink(), "linked Cargo source path")
        require(path.is_file() and stat.S_ISREG(path.stat().st_mode), "missing local Cargo source")
        return path.relative_to(root).as_posix()
    with open(input_file) as stream:
        graph = json.load(stream, object_pairs_hook=pairs)
    require(graph.get("version") == 1 and isinstance(graph.get("resolve"), dict), "complete Cargo metadata v1 graph required")
    require(Path(graph["workspace_root"]).resolve() == root, "workspace escapes the committed snapshot")
    packages = graph["packages"]
    require(isinstance(packages, list) and packages, "empty Cargo package graph")
    ids = [p["id"] for p in packages]
    require(all(isinstance(i, str) and i for i in ids) and len(set(ids)) == len(ids), "ambiguous Cargo package IDs")
    members = graph["workspace_members"]
    require(isinstance(members, list) and members and len(set(members)) == len(members) and set(members) <= set(ids), "invalid Cargo workspace members")
    nodes = graph["resolve"]["nodes"]
    node_ids = [n["id"] for n in nodes]
    require(nodes and len(set(node_ids)) == len(node_ids) and set(node_ids) <= set(ids), "invalid resolved Cargo nodes")
    for node in nodes:
        require(set(node["dependencies"]) <= set(node_ids), "dependency missing from Cargo graph")
        require(set(d["pkg"] for d in node.get("deps", [])) <= set(node_ids), "dependency edge missing from Cargo graph")
    for p in packages:
        if p["source"] is None:
            local_file(p["manifest_path"])
            for target in p["targets"]:
                local_file(target["src_path"])
    defaults = graph.get("workspace_default_members", [graph["resolve"].get("root")])
    require(isinstance(defaults, list) and set(defaults) <= set(members), "invalid default workspace selection")
    candidates = []
    for p in packages:
        if p["id"] not in members or p["source"] is not None:
            continue
        if package and p["name"] != package or not package and p["id"] not in defaults:
            continue
        for target in p["targets"]:
            if target["name"] == binary and "bin" in target["kind"]:
                candidates.append((p, target))
    require(len(candidates) == 1, "binary/package selection is missing or ambiguous")
    selected, target = candidates[0]
    require(selected["version"] == version, "Cargo package version differs from the release tag")
    selected_nodes = [n for n in nodes if n["id"] == selected["id"]]
    require(len(selected_nodes) == 1, "selected package missing from dependency resolution")
    require(set(target.get("required-features", [])) <= set(selected_nodes[0]["features"]), "selected binary requires inactive features")
    # Cargo documents package-array dependencies for ALL targets; only resolve
    # is platform-filtered. Retain both and compare the same canonical graph.
    graph["packages"] = sorted(packages, key=lambda p: p["id"])
    graph["workspace_members"] = sorted(members)
    if "workspace_default_members" in graph:
        graph["workspace_default_members"] = sorted(defaults)
    graph["resolve"]["nodes"] = sorted(nodes, key=lambda n: n["id"])
    for node in nodes:
        node["dependencies"] = sorted(node["dependencies"])
        node["features"] = sorted(node["features"])
        node["deps"] = sorted(node.get("deps", []), key=lambda d: (d["name"], d["pkg"]))
    encoded = (json.dumps(graph, sort_keys=True, separators=(",", ":")) + "\n").encode()
    with open(output_file, "xb") as stream:
        stream.write(encoded)
    print(json.dumps({"metadata_sha256": hashlib.sha256(encoded).hexdigest(),
                      "package_id": selected["id"], "package": selected["name"], "version": selected["version"],
                      "binary": binary, "manifest": local_file(selected["manifest_path"]),
                      "binary_source": local_file(target["src_path"]),
                      "resolved_packages": len(nodes), "features": sorted(selected_nodes[0]["features"])}))
except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
    print("[xwin-source] " + str(error), file=sys.stderr)
    sys.exit(7)
PY
}
