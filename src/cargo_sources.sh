#!/usr/bin/env bash
# Inventory the dependency source trees Cargo actually resolved for selected
# release packages. Cache indexes and unrelated cached crates are not inputs.
# This is an observation gate, not a sandbox or a signature of provenance.

cargo_sources_capture() {
    [[ $# == 3 ]] || return 4
    _cargo_sources capture "$@"
}

cargo_sources_verify() {
    [[ $# == 3 ]] || return 4
    _cargo_sources verify "$@"
}

_cargo_sources() {
    command -v python3 >/dev/null || return 3
    python3 -I - "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


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


def observe(metadata, selected):
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
    require(isinstance(selected, list) and 1 <= len(selected) <= 32 and
            all(isinstance(item, str) and item in by_node for item in selected) and
            len(set(selected)) == len(selected), "invalid selected release package set")
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
    require(len(sys.argv) == 5 and sys.argv[1] in ("capture", "verify"), "invalid dependency-source operation")
    mode, metadata_path, selected_json, receipt_path = sys.argv[1:]
    selected = json.loads(selected_json, object_pairs_hook=pairs)
    evidence = observe(read_json(metadata_path), selected)
    receipt = absolute(receipt_path)
    if mode == "verify":
        require(read_json(receipt) == evidence, "resolved dependency source bytes, modes, or namespace changed")
    else:
        publish(receipt, evidence)
    files = [file for tree in evidence["roots"] for file in tree["files"]]
    print(canonical({"schema_version": 1, "kind": evidence["kind"],
                     "sha256": hashlib.sha256(canonical(evidence)).hexdigest(),
                     "package_count": len(evidence["packages"]), "root_count": len(evidence["roots"]),
                     "file_count": len(files), "size_bytes": sum(file["size_bytes"] for file in files)}).decode(), end="")
except (Rejected, OSError, ValueError, KeyError, TypeError, AttributeError, RecursionError) as error:
    print("[cargo-sources] " + str(error), file=sys.stderr)
    sys.exit(7)
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ $# == 4 && ( "$1" == capture || "$1" == verify ) ]] || exit 4
    _cargo_sources "$@"
fi
