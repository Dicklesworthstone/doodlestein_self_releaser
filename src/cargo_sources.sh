#!/usr/bin/env bash
# Inventory the dependency source trees Cargo actually resolved for selected
# release packages. Cache indexes and unrelated cached crates are not inputs.
# Optional fourth argument: the workspace Cargo.lock. This authenticates
# cached sources against locked archive/object hashes (Python 3.11+). Vendors
# must be inside the workspace, whose committed source the CALLER must verify;
# their editable checksum descriptors are never upstream authenticity proof.
# This is an admission gate, not a sandbox or a signature of provenance.

cargo_sources_capture() {
    [[ $# == 3 || $# == 4 ]] || return 4
    _cargo_sources capture "$@"
}

cargo_sources_verify() {
    [[ $# == 3 || $# == 4 ]] || return 4
    _cargo_sources verify "$@"
}

# Native metadata already contains the conservative all-features workspace
# graph. Derive its local roots here instead of sending an unbounded ID array
# through a shell command. Workspace admission always authenticates Cargo.lock.
cargo_sources_capture_workspace() {
    [[ $# == 3 ]] || return 4
    _cargo_sources capture-workspace "$@"
}

cargo_sources_verify_workspace() {
    [[ $# == 3 ]] || return 4
    _cargo_sources verify-workspace "$@"
}

_cargo_sources() {
    command -v python3 >/dev/null || return 3
    python3 -I - "$@" <<'PY'
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import select
import stat
import subprocess
import sys
import tempfile
import tarfile


class Rejected(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Rejected(message)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def absolute(value):
    require(isinstance(value, str) and value.startswith("/") and value != "/" and
            not any(ord(c) < 32 or ord(c) == 127 or c in "\\:" for c in value) and
            all(part not in ("", ".", "..") for part in value[1:].split("/")),
            "noncanonical absolute dependency path")
    return Path(value)


def open_directory(path):
    # Pin every ancestor instead of resolving a symlink and admitting its target.
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns, info.st_nlink)


def read_json(path):
    path = absolute(str(path))
    parent = open_directory(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            require(stat.S_ISREG(before.st_mode), "metadata/receipt is not a regular file")
            value = json.load(stream, object_pairs_hook=pairs)
            require(identity(before) == identity(os.fstat(stream.fileno())), "metadata/receipt changed while reading")
            return value
    finally:
        os.close(parent)


@contextlib.contextmanager
def regular(path):
    path = absolute(str(path))
    parent = open_directory(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            require(stat.S_ISREG(before.st_mode), "authentication input is not a regular file")
            yield stream
            require(identity(before) == identity(os.fstat(stream.fileno())) and
                    identity(before) == identity(os.stat(path.name, dir_fd=parent, follow_symlinks=False)),
                    "authentication input changed while reading")
    finally:
        os.close(parent)


def sha256(stream):
    result = hashlib.sha256()
    for block in iter(lambda: stream.read(1048576), b""):
        result.update(block)
    return result.hexdigest()


def member_name(name):
    require(isinstance(name, str) and name and not name.startswith("/") and
            not any(ord(c) < 32 or ord(c) == 127 or c in "\\:" for c in name) and
            all(p not in ("", ".", "..", ".git") for p in name.split("/")),
            "unsafe authenticated source member")
    return name


def ancestors(name):
    return {str(p) for p in Path(name).parents if str(p) != "."}


def match_tree(tree, files, directories):
    actual = {row["path"]: row for row in tree["files"]}
    # Cargo creates this marker after checkout/extraction. It is not an
    # upstream source file; constrain it instead of allowing arbitrary extras.
    require(".cargo-ok" not in files, "upstream source occupies Cargo's reserved marker")
    marker = actual.pop(".cargo-ok", None)
    if marker is not None:
        require(marker["size_bytes"] <= 64 and marker["executable_bits"] == 0,
                "invalid Cargo completion marker")
        with regular(Path(tree["path"]) / ".cargo-ok") as stream:
            value = stream.read(65)
        valid = value in (b"", b"ok") if tree["kind"] == "git" else value == b"ok"
        if not valid:
            try:
                parsed = json.loads(value, object_pairs_hook=pairs)
                valid = isinstance(parsed, dict) and set(parsed) == {"v"} and type(parsed["v"]) is int and parsed["v"] == 1
            except (ValueError, Rejected):
                valid = False
        require(valid, "unrecognized Cargo completion marker")
    # Cargo/Git extraction respects the owner's umask. A private home may
    # legitimately have 0700 executables from 0755 inputs. Never admit added
    # execute bits or a lost owner-executable bit; before/after inventories
    # still compare every observed execute bit exactly.
    expected = {}
    for name, row in files.items():
        bits = actual.get(name, {}).get("executable_bits", -1)
        require(bits >= 0 and bits & ~row["executable_bits"] == 0 and
                bool(bits & 0o100) == bool(row["executable_bits"] & 0o100),
                "dependency executable mode differs from locked content: " + name)
        expected[name] = {**row, "executable_bits": bits}
    require(actual == expected, "dependency source files differ from locked content: " + tree["path"])
    actual_dirs = set(tree["directories"])
    if tree["kind"] == "git":
        actual_dirs.discard(".git")
    require(actual_dirs == directories, "dependency source directories differ from locked content")


def registry_authentication(package, tree, checksum):
    require(isinstance(checksum, str) and re.fullmatch(r"[0-9a-f]{64}", checksum),
            "registry dependency has no SHA-256 in Cargo.lock")
    root = Path(tree["path"])
    archive = root.parent.parent.parent / "cache" / root.parent.name / (root.name + ".crate")
    files, directories, seen = {}, set(), set()
    with regular(archive) as stream:
        require(sha256(stream) == checksum, "cached crate archive differs from Cargo.lock: " + package["name"])
        stream.seek(0)
        # No extraction: compare authenticated archive bytes directly with
        # the inventory of the files rustc is about to consume.
        with tarfile.open(fileobj=stream, mode="r|gz") as archive_reader:
            for entry in archive_reader:
                name = entry.name.rstrip("/") if entry.isdir() else entry.name
                member_name(name)
                require(name not in seen and len(seen) < 500000, "duplicate or oversized crate archive")
                seen.add(name)
                if name == root.name:
                    require(entry.isdir(), "crate root is not a directory")
                    continue
                require(name.startswith(root.name + "/"), "crate archive has another package root")
                name = member_name(name[len(root.name) + 1:])
                directories.update(ancestors(name))
                if entry.isdir():
                    directories.add(name)
                else:
                    require(entry.isfile() and 0 <= entry.size <= 1024**3, "linked, special or oversized crate member")
                    incoming = archive_reader.extractfile(entry)
                    require(incoming is not None, "missing crate member data")
                    with incoming:
                        digest = sha256(incoming)
                    files[name] = {"path": name, "sha256": digest, "size_bytes": entry.size,
                                   "executable_bits": entry.mode & 0o111}
        require(files, "empty crate archive")
    match_tree(tree, files, directories)
    return {"basis": "lockfile-crate-sha256", "archive_sha256": checksum}


def git_authentication(tree, source):
    revision = source.rsplit("#", 1)[-1]
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "Git source requires a full locked SHA-1 commit")
    root = Path(tree["path"])
    admin = root / ".git"
    fd = open_directory(admin)
    os.close(fd)
    for name in ("commondir", "objects/info/alternates", "objects/info/http-alternates"):
        require(not os.path.lexists(admin / name), "external Git object storage is not an admitted source")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_NO_REPLACE_OBJECTS="1",
                       GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
    process = subprocess.Popen(["git", "-c", "protocol.allow=never", "--git-dir=" + str(admin),
                                "cat-file", "--batch"], env=environment, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)

    def read(count):
        result = bytearray()
        while len(result) < count:
            require(select.select([process.stdout], [], [], 30)[0], "Git object read timed out")
            block = os.read(process.stdout.fileno(), count - len(result))
            require(block, "truncated Git object")
            result.extend(block)
        return bytes(result)

    def object_bytes(oid, kind):
        require(re.fullmatch(r"[0-9a-f]{40}", oid), "invalid Git object ID")
        process.stdin.write((oid + "\n").encode())
        header = bytearray()
        while len(header) <= 128:
            byte = read(1)
            if byte == b"\n":
                break
            header.extend(byte)
        fields = header.decode("ascii").split()
        require(len(fields) == 3 and fields[:2] == [oid, kind] and fields[2].isdigit(), "missing or wrong-type locked Git object")
        size = int(fields[2])
        require(size <= (1024**3 if kind == "blob" else 64*1024**2), "oversized locked Git object")
        git_hash = hashlib.sha1((kind + " " + str(size) + "\0").encode())
        file_hash, remaining, data = hashlib.sha256(), size, bytearray()
        while remaining:
            block = read(min(1048576, remaining))
            git_hash.update(block)
            file_hash.update(block)
            if kind != "blob":
                data.extend(block)
            remaining -= len(block)
        require(read(1) == b"\n" and git_hash.hexdigest() == oid, "locked Git object's bytes do not match its ID")
        return bytes(data), file_hash.hexdigest(), size

    files, directories = {}, set()
    try:
        commit, _, _ = object_bytes(revision, "commit")
        first = commit.split(b"\n", 1)[0]
        require(re.fullmatch(rb"tree [0-9a-f]{40}", first), "invalid locked Git commit tree")
        tree_oid = first[5:].decode()
        pending = [("", tree_oid)]
        count = 0
        while pending:
            prefix, oid = pending.pop()
            data, _, _ = object_bytes(oid, "tree")
            offset, names = 0, set()
            while offset < len(data):
                end = data.find(b"\0", offset)
                require(end > offset and end + 21 <= len(data), "malformed locked Git tree")
                mode, raw_name = data[offset:end].split(b" ", 1)
                leaf = raw_name.decode("utf-8")
                member_name(leaf)
                require("/" not in leaf and leaf not in names, "ambiguous locked Git tree entry")
                names.add(leaf)
                name = prefix + leaf
                member_name(name)
                count += 1
                require(count <= 500000, "oversized locked Git tree")
                child_oid = data[end + 1:end + 21].hex()
                offset = end + 21
                if mode == b"40000":
                    directories.add(name)
                    pending.append((name + "/", child_oid))
                else:
                    require(mode in (b"100644", b"100755"), "locked Git sources contain a link or submodule")
                    _, digest, size = object_bytes(child_oid, "blob")
                    files[name] = {"path": name, "sha256": digest, "size_bytes": size,
                                   "executable_bits": 0o111 if mode == b"100755" else 0}
        process.stdin.close()
        require(process.wait(timeout=10) == 0, "locked Git object reader failed")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()
        if not process.stdin.closed:
            process.stdin.close()
    match_tree(tree, files, directories)
    return {"basis": "lockfile-git-objects", "commit": revision, "tree": tree_oid}


def authenticate(evidence, metadata, lockfile):
    # A TOML parser is essential here: treating a comment, duplicate key or
    # multiline string as a package checksum would manufacture authority.
    try:
        import tomllib
    except ImportError:
        print("[cargo-sources] Locked source authentication requires Python 3.11+", file=sys.stderr)
        sys.exit(3)
    workspace = absolute(metadata["workspace_root"])
    require(absolute(lockfile) == workspace / "Cargo.lock", "lockfile is outside the selected workspace")
    with regular(lockfile) as stream:
        raw = stream.read()
    lock = tomllib.loads(raw.decode("utf-8"))
    require(type(lock.get("version")) is int and lock["version"] in (3, 4), "Cargo.lock v3 or v4 required")
    locked = {}
    def source_key(source):
        # Cargo uses the git-index source ID for crates.io even with sparse
        # transport. Do not equate arbitrary custom registry URLs.
        return "registry+https://github.com/rust-lang/crates.io-index" if source == "sparse+https://index.crates.io/" else source
    for package in lock.get("package", []):
        require(isinstance(package, dict), "invalid lockfile package")
        if "source" not in package:
            continue
        key = (package["name"], package["version"], source_key(package["source"]))
        require(all(isinstance(part, str) and part for part in key) and key not in locked,
                "ambiguous lockfile package identity")
        locked[key] = package
    trees = {tree["path"]: tree for tree in evidence["roots"]}
    proofs, git_roots = [], {}
    for package in evidence["packages"]:
        key = (package["name"], package["version"], source_key(package["source"]))
        require(key in locked, "resolved dependency is not pinned by Cargo.lock: " + package["name"])
        tree = trees[package["root"]]
        if tree["kind"] == "registry":
            proof = registry_authentication(package, tree, locked[key].get("checksum"))
        elif tree["kind"] == "git":
            identity_key = (package["root"], package["source"])
            if identity_key not in git_roots:
                git_roots[identity_key] = git_authentication(tree, package["source"])
            proof = git_roots[identity_key]
        else:
            # A vendor checksum map is editable alongside the files. It must
            # not be promoted into upstream authentication. For release
            # callers the primary workspace is independently commit-pinned;
            # require containment and record that distinct trust basis.
            root = Path(package["root"])
            require(root.is_relative_to(workspace), "external directory source needs committed workspace coverage")
            proof = {"basis": "caller-verified-workspace-snapshot", "path": root.relative_to(workspace).as_posix()}
        proofs.append({"package_id": package["package_id"], **proof})
    with regular(lockfile) as stream:
        require(hashlib.sha256(raw).hexdigest() == sha256(stream), "Cargo.lock changed during authentication")
    # Refuse persistent source mutation while the archive/object proofs ran.
    for tree in evidence["roots"]:
        require(tree == {"kind": tree["kind"], **inventory(Path(tree["path"]), tree["kind"])},
                "dependency source changed during authentication")
    evidence["authentication"] = {"lockfile_sha256": hashlib.sha256(raw).hexdigest(), "packages": proofs}


def remote_root(package):
    manifest = absolute(package["manifest_path"])
    require(manifest.name == "Cargo.toml", "unexpected dependency manifest name")
    source = package["source"]
    require(isinstance(source, str), "invalid dependency source identity")
    require(source.startswith(("registry+", "sparse+", "git+")), "unsupported remote dependency source")
    # Infer the source boundary from Cargo's cache layout, not from the
    # manifest's immediate parent: a Git package may read workspace siblings.
    if source.startswith(("registry+", "sparse+")):
        root = manifest.parent
        if root.parent.parent.name == "src" and root.parent.parent.parent.name == "registry":
            require(root.name == package["name"] + "-" + package["version"], "registry package directory differs from its identity")
            return root, "registry"
    else:
        candidates = [base for base in manifest.parents
                      if base.parent.parent.name == "checkouts" and base.parent.parent.parent.name == "git"]
        require(len(candidates) <= 1, "ambiguous Cargo Git checkout")
        if candidates:
            return candidates[0], "git"
    # Cargo source replacement keeps registry/Git IDs but puts each package
    # into a directory source. cargo vendor may omit version suffixes. Its
    # checksum descriptor establishes this layout, not authenticity: its
    # bytes are included in our observation just like every other source.
    descriptor = read_json(manifest.parent / ".cargo-checksum.json")
    require(isinstance(descriptor, dict) and isinstance(descriptor.get("files"), dict),
            "remote dependency is not a Cargo cache or directory source")
    return manifest.parent, "directory"


def inventory(root, kind):
    directories, files = [], []
    count = 0

    def visit(directory, prefix):
        nonlocal count
        before = os.fstat(directory)
        names = sorted(os.listdir(directory), key=os.fsencode)
        for name in names:
            count += 1
            require(count <= 500000, "dependency tree exceeds 500000 entries")
            require(name not in ("", ".", "..") and
                    not any(ord(c) < 32 or ord(c) == 127 or c in "\\:" for c in name), "unsafe dependency member")
            relative = prefix + name
            info = os.stat(name, dir_fd=directory, follow_symlinks=False)
            # Cargo's Git checkout has a mutable administrative database.
            # Build scripts may run git status/version commands, refreshing
            # its index without changing source. Bind the directory's
            # presence/type, but not its contents; this is source evidence,
            # not an attestation of Git command output or object storage.
            if kind == "git" and relative == ".git":
                require(stat.S_ISDIR(info.st_mode), "linked or external Git administrative directory")
                directories.append(relative)
                continue
            if stat.S_ISDIR(info.st_mode):
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                try:
                    require(identity(info) == identity(os.fstat(child)), "dependency directory was replaced")
                    directories.append(relative)
                    visit(child, relative + "/")
                finally:
                    os.close(child)
            else:
                require(stat.S_ISREG(info.st_mode), "linked or special dependency member: " + relative)
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
                with os.fdopen(fd, "rb") as stream:
                    opened = os.fstat(stream.fileno())
                    require(identity(info) == identity(opened), "dependency file was replaced")
                    digest = hashlib.sha256()
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(block)
                    require(identity(opened) == identity(os.fstat(stream.fileno())), "dependency changed while hashing")
                    files.append({"path": relative, "sha256": digest.hexdigest(),
                                  "size_bytes": opened.st_size, "executable_bits": opened.st_mode & 0o111})
            require(identity(info) == identity(os.stat(name, dir_fd=directory, follow_symlinks=False)),
                    "dependency member changed during inventory")
        require(names == sorted(os.listdir(directory), key=os.fsencode) and
                identity(before) == identity(os.fstat(directory)), "dependency directory changed during inventory")

    fd = open_directory(root)
    try:
        visit(fd, "")
        # Reopen the path to catch a lasting rename of a pinned directory.
        current = open_directory(root)
        try:
            require(identity(os.fstat(fd)) == identity(os.fstat(current)), "dependency root was replaced")
        finally:
            os.close(current)
    finally:
        os.close(fd)
    return {"path": str(root), "directories": sorted(directories),
            "files": sorted(files, key=lambda item: item["path"])}


def observe(metadata, selected, workspace=False):
    require(isinstance(metadata, dict) and metadata.get("version") == 1 and
            isinstance(metadata.get("resolve"), dict), "complete Cargo metadata v1 required")
    packages, nodes = metadata.get("packages"), metadata["resolve"].get("nodes")
    require(isinstance(packages, list) and isinstance(nodes, list), "missing Cargo dependency graph")
    by_package, by_node = {}, {}
    for package in packages:
        require(isinstance(package, dict) and isinstance(package.get("id"), str) and
                package["id"] and package["id"] not in by_package, "invalid or repeated package ID")
        by_package[package["id"]] = package
    for node in nodes:
        require(isinstance(node, dict) and isinstance(node.get("id"), str) and
                node["id"] in by_package and node["id"] not in by_node and
                isinstance(node.get("dependencies"), list) and
                all(isinstance(item, str) for item in node["dependencies"]), "invalid resolved node")
        by_node[node["id"]] = node
    if workspace:
        selected = metadata.get("workspace_members")
    require(isinstance(selected, list) and len(selected) >= 1 and (workspace or len(selected) <= 32) and
            all(isinstance(item, str) and item in by_node for item in selected) and
            len(set(selected)) == len(selected), "invalid selected release package set")
    if workspace:
        for key in selected:
            package = by_package[key]
            require("source" in package and package["source"] is None,
                    "workspace member is not a local package")
            absolute(package["manifest_path"])
    reachable, pending = set(), list(selected)
    while pending:
        key = pending.pop()
        require(key in by_node, "resolved dependency is missing")
        if key not in reachable:
            reachable.add(key)
            pending.extend(by_node[key]["dependencies"])
    roots, admitted = {}, []
    for key in sorted(reachable):
        package = by_package[key]
        require("source" in package, "missing Cargo source identity")
        if package["source"] is None:
            continue  # Committed primary/sibling trees have their own gate.
        root, kind = remote_root(package)
        require(root not in roots or roots[root] == kind, "conflicting dependency source root")
        roots[root] = kind
        manifest = absolute(package["manifest_path"])
        admitted.append({"package_id": key, "source": package["source"],
                         "name": package["name"], "version": package["version"],
                         "root": str(root), "manifest": manifest.relative_to(root).as_posix()})
        for target in package.get("targets", []):
            target_path = absolute(target["src_path"])
            require(target_path.is_relative_to(root), "dependency target escapes its source tree")
    trees = [{"kind": roots[root], **inventory(root, roots[root])} for root in sorted(roots)]
    indexed = {tree["path"]: {file["path"] for file in tree["files"]} for tree in trees}
    for package in admitted:
        require(package["manifest"] in indexed[package["root"]], "missing dependency manifest")
        for target in by_package[package["package_id"]].get("targets", []):
            relative = absolute(target["src_path"]).relative_to(Path(package["root"])).as_posix()
            require(relative in indexed[package["root"]], "missing dependency target source")
    return {"schema_version": 1, "kind": "dsr-cargo-dependency-sources",
            "selected_packages": sorted(selected), "packages": admitted, "roots": trees}


def publish(destination, evidence):
    for root in evidence["roots"]:
        require(not destination.is_relative_to(Path(root["path"])), "receipt cannot be inside dependency sources")
    parent = open_directory(destination.parent)
    temporary = None
    try:
        require(not os.path.lexists(destination), "dependency receipt already exists")
        fd, temporary = tempfile.mkstemp(prefix=".cargo-sources-", dir=destination.parent)
        with os.fdopen(fd, "wb") as stream:
            stream.write(canonical(evidence))
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, destination.name, dst_dir_fd=parent, follow_symlinks=False)
        os.fsync(parent)
    finally:
        if temporary is not None:
            os.unlink(temporary)
        os.close(parent)


try:
    require(sys.version_info >= (3, 9), "Python 3.9 or newer is required")
    require(len(sys.argv) >= 2, "invalid dependency-source operation")
    workspace = sys.argv[1] in ("capture-workspace", "verify-workspace")
    if workspace:
        require(len(sys.argv) == 5, "workspace source authentication requires metadata, receipt, and Cargo.lock")
        mode, metadata_path, receipt_path, lockfile = sys.argv[1:5]
        mode = mode.split("-", 1)[0]
        selected = None
    else:
        require(len(sys.argv) in (5, 6) and sys.argv[1] in ("capture", "verify"), "invalid dependency-source operation")
        mode, metadata_path, selected_json, receipt_path = sys.argv[1:5]
        selected = json.loads(selected_json, object_pairs_hook=pairs)
        lockfile = sys.argv[5] if len(sys.argv) == 6 else None
    metadata = read_json(metadata_path)
    evidence = observe(metadata, selected, workspace=workspace)
    if lockfile is not None:
        authenticate(evidence, metadata, lockfile)
    receipt = absolute(receipt_path)
    if mode == "verify":
        require(read_json(receipt) == evidence, "resolved dependency source bytes, modes, or namespace changed")
    else:
        publish(receipt, evidence)
    files = [file for tree in evidence["roots"] for file in tree["files"]]
    summary = {"schema_version": 1, "kind": evidence["kind"],
                     "sha256": hashlib.sha256(canonical(evidence)).hexdigest(),
                     "package_count": len(evidence["packages"]), "root_count": len(evidence["roots"]),
                     "file_count": len(files), "size_bytes": sum(file["size_bytes"] for file in files)}
    if "authentication" in evidence:
        proofs = evidence["authentication"]["packages"]
        # The summary is passed through shell argv by metadata admission.
        # Keep large per-package proof lists only in the full evidence file.
        summary["authentication"] = {
            "lockfile_sha256": evidence["authentication"]["lockfile_sha256"],
            "locked_archive_packages": sum(p["basis"] == "lockfile-crate-sha256" for p in proofs),
            "locked_git_packages": sum(p["basis"] == "lockfile-git-objects" for p in proofs),
            "workspace_snapshot_packages": sum(p["basis"] == "caller-verified-workspace-snapshot" for p in proofs)}
    print(canonical(summary).decode(), end="")
except (Rejected, OSError, ValueError, KeyError, TypeError, AttributeError, RecursionError,
        tarfile.TarError, EOFError, subprocess.SubprocessError) as error:
    print("[cargo-sources] " + str(error), file=sys.stderr)
    sys.exit(7)
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ ( ( $# == 4 || $# == 5 ) && ( "$1" == capture || "$1" == verify ) ) ||
       ( $# == 4 && ( "$1" == capture-workspace || "$1" == verify-workspace ) ) ]] || exit 4
    _cargo_sources "$@"
fi
