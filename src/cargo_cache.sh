#!/usr/bin/env bash
# Private Cargo download caches. Copy bytes, never ambient configuration,
# credentials, symlinks, or source hardlinks. Sourceable and directly runnable.
# Ambient registry/git roots may be relocated links; private copies may not.

_cargo_cache_run() {
    # Lockfile-scoped seeding needs tomllib (Python 3.11+), but a login shell can put
    # an older python3 first: macOS path_helper puts /usr/bin/python3 (3.9) ahead of
    # Homebrew. Prefer the first interpreter that is new enough. The selection lives
    # inside this function because only this function is shipped to remote hosts.
    local dsr_python dsr_candidate
    dsr_python=
    for dsr_candidate in python3 python3.14 python3.13 python3.12 python3.11; do
        command -v "$dsr_candidate" >/dev/null 2>&1 || continue
        if "$dsr_candidate" -I -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
            dsr_python=$dsr_candidate
            break
        fi
    done
    if [ -z "$dsr_python" ]; then
        command -v python3 >/dev/null || { printf '%s\n' '[cargo-cache] Python 3.9+ is required' >&2; return 3; }
        dsr_python=python3
    fi
    "$dsr_python" -I - "$@" <<'PY'
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import sys
import tempfile
import subprocess


class Failure(Exception):
    def __init__(self, message, code=7):
        super().__init__(message)
        self.code = code


def interrupted(signum, frame):
    raise Failure('interrupted', 5)


for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(signum, interrupted)


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns, info.st_nlink)


def absolute(path):
    if not path or not os.path.isabs(path):
        raise Failure('paths must be nonempty and absolute', 4)
    return os.path.normpath(path)


def root_path(path):
    path = absolute(path)
    if os.path.islink(path) or not os.path.isdir(path):
        raise Failure('Cargo home must be a real directory: ' + path, 4)
    return os.path.realpath(path)


def inside(path, root):
    return os.path.commonpath((path, root)) == root


def directory_identity(info):
    # Unrelated cache maintenance changes directory times and link counts.
    return info.st_dev, info.st_ino, info.st_mode


class CacheSourceRoots:
    """Hold ambient layout aliases, never follow links inside selected trees.

    Only snapshot input gets this view. inventory/verify still require wholly
    private real directories. Opening is lazy: a registry-only lockfile must
    not even inspect an unrelated git alias. No alias is copied to the output.
    """
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW

    def __init__(self, home, destination):
        self.home, self.destination, self.roots = home, destination, {}
        self.fd = os.open(home, self.flags) if home is not None else None
        self.home_identity = directory_identity(os.fstat(self.fd)) if self.fd is not None else None
        self.marker = self.entry('.dsr-cache-seed.json')

    def entry(self, name):
        if self.fd is None:
            return None
        try:
            return os.stat(name, dir_fd=self.fd, follow_symlinks=False)
        except FileNotFoundError:
            return None

    def root(self, name):
        if name not in ('registry', 'git') or self.fd is None:
            raise FileNotFoundError('no selected ambient cache root: ' + name)
        if name not in self.roots:
            before = self.entry(name)
            if before is None:
                self.roots[name] = None
            else:
                if stat.S_ISLNK(before.st_mode):
                    if self.marker is not None:
                        raise Failure('prepared private cache root must not be a symlink: ' + name)
                elif not stat.S_ISDIR(before.st_mode):
                    raise Failure('cache root is not a directory or relocation link: ' + name)
                logical = os.path.join(self.home, name)
                physical = os.path.realpath(logical)
                if (inside(self.home, physical) or inside(self.destination, physical) or
                        inside(physical, self.destination)):
                    raise Failure('relocated cache root overlaps Cargo home or destination: ' + name, 4)
                for other in self.roots.values():
                    if other is not None and (inside(physical, other[1]) or inside(other[1], physical)):
                        raise Failure('ambient cache roots overlap')
                try:
                    descriptor = os.open(physical, self.flags)
                except OSError as error:
                    # An existing but broken alias is not an absent cold cache.
                    raise Failure('cannot open relocated cache root: ' + name) from error
                self.roots[name] = before, physical, descriptor, directory_identity(os.fstat(descriptor))
                self.verify()
        root = self.roots[name]
        if root is None:
            raise FileNotFoundError('missing ambient cache root: ' + name)
        return root

    def open(self, relative):
        parts = relative.split('/')
        if any(part in ('', '.', '..') for part in parts):
            raise Failure('invalid cache-relative directory', 4)
        parent = os.dup(self.root(parts[0])[2])
        try:
            for part in parts[1:]:
                child = os.open(part, self.flags, dir_fd=parent)
                os.close(parent)
                parent = child
            result, parent = parent, None
            return result
        finally:
            if parent is not None:
                os.close(parent)

    def location(self, relative):
        # Git's read-only subprocess needs a pathname. Validate every inner
        # component first, and recheck the root binding around its observation.
        self.verify()
        descriptor = self.open(relative)
        os.close(descriptor)
        root, *parts = relative.split('/')
        return os.path.join(self.root(root)[1], *parts)

    def verify(self):
        if self.fd is None:
            return
        if (directory_identity(os.fstat(self.fd)) != self.home_identity or
                directory_identity(os.stat(self.home, follow_symlinks=False)) != self.home_identity):
            raise Failure('ambient Cargo home changed during preparation')
        marker = self.entry('.dsr-cache-seed.json')
        if (identity(marker) if marker is not None else None) != \
                (identity(self.marker) if self.marker is not None else None):
            raise Failure('ambient cache preparation marker changed')
        for name, record in self.roots.items():
            named = self.entry(name)
            if record is None:
                if named is not None:
                    raise Failure('missing ambient cache root appeared: ' + name)
                continue
            before, physical, descriptor, held = record
            compare = identity if stat.S_ISLNK(before.st_mode) else directory_identity
            logical = os.path.join(self.home, name)
            if (named is None or compare(named) != compare(before) or
                    os.path.realpath(logical) != physical or
                    directory_identity(os.fstat(descriptor)) != held or
                    directory_identity(os.stat(physical, follow_symlinks=False)) != held or
                    directory_identity(os.stat(logical)) != held):
                raise Failure('ambient cache root changed during preparation: ' + name)

    def close(self):
        for record in self.roots.values():
            if record is not None:
                os.close(record[2])
        self.roots.clear()
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


def source_directory(source, relative, roots=None):
    if roots is not None:
        return roots.open(relative)
    parent = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in relative.split('/'):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        result, parent = parent, None
        return result
    finally:
        if parent is not None:
            os.close(parent)


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Failure('duplicate receipt field: ' + key)
        result[key] = value
    return result


def read_regular(parent, name, before, outgoing=None):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    with os.fdopen(fd, 'rb') as incoming:
        opened = os.fstat(incoming.fileno())
        if not stat.S_ISREG(opened.st_mode) or identity(before) != identity(opened):
            raise Failure('cache file changed before reading: ' + name)
        digest, size = hashlib.sha256(), 0
        while True:
            block = incoming.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
            size += len(block)
            if outgoing is not None:
                outgoing.write(block)
        if size != before.st_size or identity(before) != identity(os.fstat(incoming.fileno())):
            raise Failure('cache file changed while reading: ' + name)
    after = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if identity(before) != identity(after):
        raise Failure('cache file replaced while reading: ' + name)
    return digest.hexdigest(), size


def external_git_reference(path, size):
    parts = path.split('/')
    registry_git = len(parts) > 3 and parts[:2] == ['registry', 'index'] and '.git' in parts[3:]
    if not parts or (parts[0] != 'git' and not registry_git):
        return False
    # A copied checkout must not retain a gitdir/commondir/alternate-object
    # pointer into the ambient home. Ordinary Cargo-owned clones need none.
    return (parts[-1] == '.git' or
            (size > 0 and parts[-3:] == ['objects', 'info', 'alternates']) or
            (size > 0 and parts[-1] == 'commondir' and
             ('.git' in parts[:-1] or (len(parts) == 4 and parts[1] == 'db'))))


def inventory(root, destination=None, require_private_links=False, selected_paths=None, source_roots=None):
    files, directories, caches = [], [], []
    inodes = {}
    private_entries = {}
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW

    def walk(parent, name, relative, selection=None):
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if require_private_links:
            private_entries[relative] = identity(before)
        if stat.S_ISDIR(before.st_mode):
            fd = os.open(name, flags, dir_fd=parent)
            try:
                if identity(before) != identity(os.fstat(fd)):
                    raise Failure('cache directory replaced: ' + relative)
                directories.append(relative)
                if destination is not None:
                    os.mkdir(os.path.join(destination, relative), 0o700)
                # A selector node describes only the named children. Never
                # list/read the other subtree contents, or let their mtime
                # changes invalidate an otherwise stable selected seed.
                names = sorted(selection if selection is not None else os.listdir(fd), key=os.fsencode)
                for child in names:
                    walk(fd, child, relative + '/' + child, None if selection is None else selection[child])
                same = identity if selection is None else lambda s: (s.st_dev, s.st_ino, s.st_mode)
                if ((selection is None and names != sorted(os.listdir(fd), key=os.fsencode)) or
                        same(before) != same(os.fstat(fd)) or
                        same(before) != same(os.stat(name, dir_fd=parent, follow_symlinks=False))):
                    raise Failure('cache directory changed while reading: ' + relative)
            finally:
                os.close(fd)
        elif stat.S_ISREG(before.st_mode):
            if selection is not None:
                raise Failure('selected cache ancestor is not a directory: ' + relative)
            if external_git_reference(relative, before.st_size):
                raise Failure('external Git storage reference: ' + relative)
            if require_private_links:
                # Cargo can hardlink Git objects between its own database and
                # checkout. Every link must belong to these inventoried trees;
                # a regular file with an ambient owner is still shared state.
                key = (before.st_dev, before.st_ino)
                expected, count, first = inodes.get(key, (before.st_nlink, 0, relative))
                if expected != before.st_nlink:
                    raise Failure('cache hardlinks changed while reading: ' + relative)
                inodes[key] = (expected, count + 1, first)
            if destination is None:
                digest, size = read_regular(parent, name, before)
            else:
                output = os.path.join(destination, relative)
                # A fresh inode is mandatory: hardlink seeds survive unlink but
                # not writes through another link. Do not preserve setuid bits.
                fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, 'wb') as outgoing:
                    digest, size = read_regular(parent, name, before, outgoing)
                    outgoing.flush()
                    os.fchmod(outgoing.fileno(), stat.S_IMODE(before.st_mode) & 0o777)
            files.append({'path': relative, 'sha256': digest, 'size_bytes': size,
                          'executable_bits': before.st_mode & 0o111})
        else:
            raise Failure('linked or special cache entry: ' + relative)

    def recheck_private_links(parent, name, relative):
        # A link created outside these trees changes no inventoried directory.
        # Recheck file identity/nlink after the full count, including files that
        # were hashed early, without following a replaced ancestor directory.
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if private_entries.get(relative) != identity(before):
            raise Failure('private cache entry changed after reading: ' + relative)
        if stat.S_ISDIR(before.st_mode):
            fd = os.open(name, flags, dir_fd=parent)
            try:
                if identity(before) != identity(os.fstat(fd)):
                    raise Failure('private cache directory replaced: ' + relative)
                names = sorted(os.listdir(fd), key=os.fsencode)
                for child in names:
                    recheck_private_links(fd, child, relative + '/' + child)
                if (identity(before) != identity(os.fstat(fd)) or
                        identity(before) != identity(os.stat(name, dir_fd=parent, follow_symlinks=False))):
                    raise Failure('private cache directory changed after reading: ' + relative)
            finally:
                os.close(fd)

    if source_roots is not None and (require_private_links or destination is None):
        raise Failure('ambient aliases are only allowed while seeding a new private home', 4)
    fd = os.open(root, flags)
    handles = {}
    try:
        selected = {}
        for name in (selected_paths if selected_paths is not None else ('registry', 'git')):
            try:
                if source_roots is not None:
                    handles[name] = source_roots.open(name)
                    selected[name] = os.fstat(handles[name])
                else:
                    selected[name] = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                selected[name] = None
        for name, before in selected.items():
            if before is None:
                if selected_paths is not None:
                    raise Failure('selected cache root disappeared: ' + name)
                continue
            if not stat.S_ISDIR(before.st_mode):
                raise Failure('cache root is not a real directory: ' + name)
            caches.append(name)
            walk(handles.get(name, fd), '.' if name in handles else name, name,
                 None if selected_paths is None else selected_paths[name])
        # Ignore unrelated ambient Cargo-home activity, but not replacement of
        # a selected cache root or creation of a previously missing one.
        for name, before in selected.items():
            try:
                after = os.fstat(handles[name]) if name in handles else os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                after = None
            same = identity if selected_paths is None else lambda s: (s.st_dev, s.st_ino, s.st_mode)
            if (before is None) != (after is None) or (before is not None and same(before) != same(after)):
                raise Failure('cache root changed while reading: ' + name)
        if source_roots is not None:
            source_roots.verify()
        if require_private_links:
            for name, before in selected.items():
                if before is not None:
                    recheck_private_links(fd, name, name)
    finally:
        for descriptor in handles.values():
            os.close(descriptor)
        os.close(fd)
    for expected, count, first in inodes.values():
        if expected != count:
            raise Failure('cache file has hardlinks outside its private trees: ' + first)
    return {'caches': sorted(caches), 'directories': sorted(directories, key=os.fsencode),
            'files': sorted(files, key=lambda entry: os.fsencode(entry['path']))}


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()


def read_path(path, maximum=16 * 1024 * 1024):
    """Read small selection inputs without following any path component."""
    path = absolute(path)
    parent = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        parts = path.split('/')[1:]
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        before = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
            raise Failure('selection input is not a bounded regular file: ' + path)
        import io
        output = io.BytesIO()
        read_regular(parent, parts[-1], before, output)
        return output.getvalue()
    finally:
        os.close(parent)


def unscoped_registry_selection(parent, anchors):
    """Omit materialized registry sources backed by a same-registry archive.

    An ordinary seed has no lockfile authority. Keep source-only packages, but
    never walk the expanded copy when the download is already being retained.
    This is cache selection, not archive authentication or offline admission.
    The copied download and every retained source still pass full inventory.
    """
    from contextlib import contextmanager

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    stable = lambda info: (info.st_dev, info.st_ino, info.st_mode)

    @contextmanager
    def directory(owner, name, relative):
        before = os.stat(name, dir_fd=owner, follow_symlinks=False)
        if not stat.S_ISDIR(before.st_mode):
            raise Failure('registry routing entry is not a real directory: ' + relative)
        descriptor = os.open(name, flags, dir_fd=owner)
        try:
            anchors[relative] = stable(before)
            if stable(os.fstat(descriptor)) != anchors[relative]:
                raise Failure('registry directory replaced during selection: ' + relative)
            yield descriptor
            if (stable(os.fstat(descriptor)) != anchors[relative] or
                    stable(os.stat(name, dir_fd=owner, follow_symlinks=False)) != anchors[relative]):
                raise Failure('registry directory changed during selection: ' + relative)
        finally:
            os.close(descriptor)

    selected = {name: None for name in os.listdir(parent)}
    if 'src' not in selected or 'cache' not in selected:
        return selected  # No duplicate representation to omit.
    with directory(parent, 'src', 'registry/src') as sources, \
            directory(parent, 'cache', 'registry/cache') as downloads:
        source_paths = {}
        for registry in sorted(os.listdir(sources), key=os.fsencode):
            try:
                cached = os.stat(registry, dir_fd=downloads, follow_symlinks=False)
            except FileNotFoundError:
                source_paths[registry] = None  # Preserve this whole source-only registry.
                continue
            # Links/special entries in selected cache routing are still errors;
            # do not follow them to decide that a source package is redundant.
            if not stat.S_ISDIR(cached.st_mode):
                raise Failure('registry archive route is not a real directory: ' + registry)
            prefix = 'registry/src/' + registry
            cache_prefix = 'registry/cache/' + registry
            with directory(sources, registry, prefix) as packages, \
                    directory(downloads, registry, cache_prefix) as archives:
                retained = {}
                for package in sorted(os.listdir(packages), key=os.fsencode):
                    # Cargo archive basenames mirror the extracted directory.
                    # Unrecognized metadata/long names retain their old policy.
                    if (len(os.fsencode(package)) > 240 or not re.fullmatch(
                            r'[A-Za-z0-9_-]+-[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?', package)):
                        retained[package] = None
                        continue
                    archive = package + '.crate'
                    try:
                        info = os.stat(archive, dir_fd=archives, follow_symlinks=False)
                    except FileNotFoundError:
                        retained[package] = None
                        continue
                    if not stat.S_ISREG(info.st_mode):
                        raise Failure('registry download is linked or special: ' + cache_prefix + '/' + archive)
                    if info.st_size == 0:
                        retained[package] = None
                        continue
                    # Bind the exact download which permits this omission,
                    # including identity after the independent destination read.
                    anchors[cache_prefix + '/' + archive] = identity(info)
                source_paths[registry] = retained
        selected['src'] = source_paths
    return selected


def unscoped_selection(source, roots=None):
    """Keep registry downloads/source-only packages and Git databases.

    Ordinary callers may not supply a lockfile. Cargo recreates git/checkouts
    from git/db; the host's unrelated working copies can contain legitimate
    symlinks and need not be read or copied (#39). Registry archives similarly
    supersede their redundant extracted trees; source-only packages are retained.
    Lockfile-scoped callers keep their stricter download-only selection. This
    is not project-specific minimization or proof of complete offline closure.
    """
    selected, anchors = {}, {}
    if source is None:
        return selected, anchors
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    stable = lambda info: (info.st_dev, info.st_ino, info.st_mode)
    home = os.open(source, flags)
    try:
        anchors[''] = stable(os.fstat(home))
        # A prepared DSR home may carry source-authentication receipts whose
        # paths refer to its materialized registry trees. Do not change that
        # copy contract. Marker presence is only a conservative optimization
        # opt-out: it is never followed, copied, or accepted as a trust proof.
        try:
            marker = os.stat('.dsr-cache-seed.json', dir_fd=home, follow_symlinks=False)
        except FileNotFoundError:
            marker = None
        anchors['.dsr-cache-seed.json'] = None if marker is None else identity(marker)
        for root, categories in (('registry', None), ('git', ('db',))):
            try:
                parent = source_directory(source, root, roots)
            except FileNotFoundError:
                anchors[root] = None
                continue
            try:
                before = os.fstat(parent)
                anchors[root] = stable(before)
                if stable(os.fstat(parent)) != anchors[root]:
                    raise Failure('cache root replaced during seed selection: ' + root)
                if categories is None:
                    selected[root] = None if marker is not None else unscoped_registry_selection(parent, anchors)
                else:
                    selected[root] = {}
                for name in categories or ():
                    relative = root + '/' + name
                    try:
                        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
                    except FileNotFoundError:
                        anchors[relative] = None
                        continue
                    if not stat.S_ISDIR(info.st_mode):
                        raise Failure('Git database cache is not a real directory: ' + relative)
                    selected[root][name] = None
                    anchors[relative] = stable(info)
                if (stable(os.fstat(parent)) != anchors[root] or
                        (roots is None and stable(os.stat(root, dir_fd=home, follow_symlinks=False)) != anchors[root])):
                    raise Failure('cache root changed during seed selection: ' + root)
            finally:
                os.close(parent)
        if stable(os.stat(source, follow_symlinks=False)) != anchors['']:
            raise Failure('Cargo home changed during seed selection')
        if roots is not None:
            roots.verify()
    finally:
        os.close(home)
    return selected, anchors


def locked_selection(source, lockfile, roots=None):
    """Select download inputs, not the host's unrelated unpacked sources.

    Cargo has not resolved metadata in its private home yet. Cargo.lock is a
    conservative all-workspace/all-target selection, not a target-graph claim.
    Sparse indexes are narrowed to locked crate names. Git dependencies use
    only bare databases containing a locked commit; Cargo recreates checkouts.
    A selected Git database/index retains its history, not just one tree.
    """
    try:
        import tomllib
    except ImportError as error:
        raise Failure('lockfile-scoped seeding requires Python 3.11+', 3) from error
    raw = read_path(lockfile)
    lock = tomllib.loads(raw.decode('utf-8'))
    packages = lock.get('package', [])
    if (type(lock.get('version', 1)) is not int or lock.get('version', 1) not in (1, 2, 3, 4) or
            not isinstance(packages, list) or len(packages) > 10000):
        raise Failure('invalid or oversized Cargo.lock', 4)
    archives, registries, revisions, names = {}, set(), set(), set()
    seen = set()
    for package in packages:
        if not isinstance(package, dict):
            raise Failure('invalid locked package', 4)
        name, version, origin = (package.get(k) for k in ('name', 'version', 'source'))
        if (not isinstance(name, str) or not name or len(name) > 128 or
                not all(c.isalnum() or c in '_-' for c in name) or
                not isinstance(version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?', version) or
                (origin is not None and (not isinstance(origin, str) or any(ord(c) < 32 for c in origin)))):
            raise Failure('unsafe or invalid locked package identity', 4)
        key = (name, version, origin)
        if key in seen:
            raise Failure('duplicate Cargo.lock package', 4)
        seen.add(key)
        if origin is None:
            continue
        if origin.startswith(('registry+', 'sparse+')):
            checksum = package.get('checksum')
            if not isinstance(checksum, str) or not re.fullmatch('[0-9a-f]{64}', checksum):
                raise Failure('locked registry package lacks a SHA256 checksum', 4)
            archives.setdefault(name + '-' + version + '.crate', set()).add(checksum)
            registries.add(origin.split('+', 1)[1].rstrip('/'))
            names.add(name.lower())
        elif origin.startswith('git+') and re.search(r'#[0-9a-f]{40}$', origin):
            revisions.add(origin.rsplit('#', 1)[1])
        else:
            raise Failure('unsupported or unpinned Cargo.lock source', 4)
    selected, expected = {}, {}

    def add(relative):
        parts = relative.split('/')
        node = selected
        for part in parts[:-1]:
            if part in node and node[part] is None:
                return
            node = node.setdefault(part, {})
        node[parts[-1]] = None

    def children(relative):
        # List only routing directories. An unused registry/src or Git
        # checkout is never even opened. Only held ambient root aliases pass.
        try:
            parent = source_directory(source, relative, roots)
        except FileNotFoundError:
            return []
        try:
            result = []
            for name in os.listdir(parent):
                if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]*', name):
                    continue
                try:
                    info = os.stat(name, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    continue  # Unselected routing entries can disappear.
                if stat.S_ISDIR(info.st_mode):
                    result.append(name)
            return sorted(result)
        finally:
            os.close(parent)

    def available(relative):
        # Validate selected ancestors through descriptors. Absence is an
        # incomplete seed, not permission to substitute a different version.
        parts = relative.split('/')
        try:
            parent = source_directory(source, '/'.join(parts[:-1]), roots)
        except FileNotFoundError:
            return False
        try:
            try:
                value = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                return False
            if not stat.S_ISREG(value.st_mode):
                raise Failure('selected download is linked or special: ' + relative)
            return True
        finally:
            os.close(parent)

    def git_probe(directory, arguments, incoming=None):
        env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        # Object availability is a local read. A partial clone must not fetch
        # from its promisor remote while we inspect unrelated database routes.
        # The empty protocol allowlist also overrides repository-local policy.
        env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_NO_REPLACE_OBJECTS='1', GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0',
                   GIT_NO_LAZY_FETCH='1', GIT_ALLOW_PROTOCOL='')
        try:
            result = subprocess.run(['git', '--git-dir=' + directory, '-c', 'core.fsmonitor=false',
                                     '-c', 'core.hooksPath=' + os.devnull] + arguments,
                                    input=incoming, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    env=env, timeout=30, check=False)
        except FileNotFoundError as error:
            raise Failure('Git is required to select locked Git downloads', 3) from error
        except subprocess.TimeoutExpired:
            return b''  # Not an admitted seed; the offline metadata gate remains.
        return result.stdout if result.returncode == 0 else b''

    selected_registries = set()
    if source is not None and archives:
        for registry in children('registry/cache'):
            for archive, checksums in sorted(archives.items()):
                relative = 'registry/cache/' + registry + '/' + archive
                if available(relative):
                    # The same name/version can exist in multiple registries.
                    # Never admit a checksum from the wrong source. Skip it as
                    # unavailable; the private offline resolver decides whether
                    # all of its required downloads are actually present.
                    parent = source_directory(source, 'registry/cache/' + registry, roots)
                    try:
                        before = os.stat(archive, dir_fd=parent, follow_symlinks=False)
                        digest, _ = read_regular(parent, archive, before)
                    finally:
                        os.close(parent)
                    if digest in checksums:
                        add(relative)
                        expected[relative] = digest
                        selected_registries.add(registry)
        for registry in sorted(set(children('registry/index')) & selected_registries):
            prefix = 'registry/index/' + registry + '/'
            for name in sorted(names):
                route = ('1/' if len(name) == 1 else '2/' if len(name) == 2 else
                         '3/' + name[0] + '/' if len(name) == 3 else name[:2] + '/' + name[2:4] + '/') + name
                if available(prefix + '.cache/' + route):
                    add(prefix + '.cache/' + route)
            if available(prefix + 'config.json'):
                add(prefix + 'config.json')
            # Legacy Git-backed indexes also need their object store. Retain
            # only a registry named in the lockfile, not other registry history.
            gitdir = os.path.join(source, prefix, '.git')
            if os.path.isdir(gitdir) and not os.path.islink(gitdir):
                if roots is not None:
                    gitdir = roots.location(prefix + '.git')
                origin = git_probe(gitdir, ['config', '--local', '--get', 'remote.origin.url']).decode('utf-8', 'replace').strip().rstrip('/')
                if origin in registries:
                    add(prefix + '.git')
    if source is not None and revisions:
        request = ''.join(revision + '\n' for revision in sorted(revisions)).encode('ascii')
        for database in children('git/db'):
            relative = 'git/db/' + database
            directory = roots.location(relative) if roots is not None else os.path.join(source, relative)
            rows = git_probe(directory, ['cat-file', '--batch-check'], request).splitlines()
            if any(len(row.split()) == 3 and row.split()[0].decode('ascii', 'replace') in revisions and
                   row.split()[1] == b'commit' for row in rows):
                add(relative)
    scope = {'kind': 'cargo-lock-downloads', 'lockfile_sha256': hashlib.sha256(raw).hexdigest(),
             'registry_packages': len(archives), 'git_revisions': sorted(revisions)}
    if roots is not None:
        roots.verify()
    return selected, expected, scope


def new_receipt(path, value):
    path = absolute(path)
    data = canonical(value)
    fd, temporary = tempfile.mkstemp(prefix='.dsr-cargo-receipt.', dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, 'wb') as outgoing:
            outgoing.write(data)
            outgoing.flush()
            os.fsync(outgoing.fileno())
        # Atomic no-clobber publication, including a dangling symlink at path.
        os.link(temporary, path, follow_symlinks=False)
    finally:
        os.unlink(temporary)
    return hashlib.sha256(data).hexdigest()


def summary(path, receipt, digest):
    entries = receipt['inventory']['files']
    result = {'schema_version': 1, 'mode': receipt['kind'], 'cargo_home': receipt['cargo_home'],
              'receipt_path': path, 'receipt_sha256': digest,
              'inventory_sha256': hashlib.sha256(canonical(receipt['inventory'])).hexdigest(),
              'caches': receipt['inventory']['caches'], 'file_count': len(entries),
              'size_bytes': sum(entry['size_bytes'] for entry in entries)}
    if 'selection' in receipt:
        result['selection'] = receipt['selection']
    return result


def main(args):
    if (len(args) not in (3, 4) or args[0] not in ('snapshot', 'inventory', 'verify') or
            (len(args) == 4 and (args[0] != 'snapshot' or not args[3]))):
        raise Failure('usage: cargo_cache.sh snapshot SOURCE_HOME NEW_HOME [LOCKFILE] | inventory HOME NEW_RECEIPT | verify HOME RECEIPT', 4)
    command, first, second = args[:3]
    if command == 'snapshot':
        source = root_path(first) if first else None
        destination = absolute(second)
        parent = os.path.realpath(os.path.dirname(destination))
        destination = os.path.join(parent, os.path.basename(destination))
        if source is not None and (inside(destination, source) or inside(source, destination)):
            raise Failure('source and private Cargo home must not overlap', 4)
        roots = CacheSourceRoots(source, destination)
        try:
            paths, checksums, scope = None, {}, None
            if len(args) == 4:
                paths, checksums, scope = locked_selection(source, args[3], roots)
            else:
                paths, seed_anchors = unscoped_selection(source, roots)
            roots.verify()
            os.mkdir(destination, 0o700)
            created = os.lstat(destination)
            complete = False
            try:
                selected = inventory(source, destination, selected_paths=paths, source_roots=roots) if source else {'caches': [], 'directories': [], 'files': []}
                if any(entry['path'] in checksums and entry['sha256'] != checksums[entry['path']]
                       for entry in selected['files']):
                    raise Failure('selected archive changed after lockfile admission')
                if inventory(destination, require_private_links=True) != selected:
                    raise Failure('private cache copy does not match its seed')
                if scope is None and unscoped_selection(source, roots) != (paths, seed_anchors):
                    raise Failure('cache selection changed during preparation')
                receipt = {'schema_version': 1, 'kind': 'private-copy', 'cargo_home': destination,
                           'seed_source': source, 'inventory': selected}
                if scope is not None:
                    if hashlib.sha256(read_path(args[3])).hexdigest() != scope['lockfile_sha256']:
                        raise Failure('Cargo.lock changed during cache preparation')
                    receipt['selection'] = scope
                roots.verify()
                path = os.path.join(destination, '.dsr-cache-seed.json')
                digest = new_receipt(path, receipt)
                roots.verify()
                complete = True
                return summary(path, receipt, digest)
            finally:
                if not complete and os.path.lexists(destination):
                    current = os.lstat(destination)
                    if (current.st_dev, current.st_ino) == (created.st_dev, created.st_ino):
                        shutil.rmtree(destination)
        finally:
            roots.close()
    home = root_path(first)
    path = absolute(second)
    if command == 'inventory':
        output = os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))
        if any(inside(output, os.path.join(home, name)) for name in ('registry', 'git')):
            raise Failure('receipt must live outside the inventoried cache directories', 4)
        receipt = {'schema_version': 1, 'kind': 'inventory', 'cargo_home': home,
                   'seed_source': None, 'inventory': inventory(home, require_private_links=True)}
        return summary(path, receipt, new_receipt(path, receipt))
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as incoming:
        before = os.fstat(incoming.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise Failure('receipt is not a regular file')
        data = incoming.read()
        if identity(before) != identity(os.fstat(incoming.fileno())):
            raise Failure('receipt changed during verification')
    receipt = json.loads(data, object_pairs_hook=unique_pairs)
    if (not isinstance(receipt, dict) or
            set(receipt) - {'selection'} != {'schema_version', 'kind', 'cargo_home', 'seed_source', 'inventory'} or
            type(receipt['schema_version']) is not int or receipt['schema_version'] != 1 or
            receipt['kind'] not in ('private-copy', 'inventory') or receipt['cargo_home'] != home or
            receipt['inventory'] != inventory(home, require_private_links=True)):
        raise Failure('private Cargo cache does not match its inventory')
    if 'selection' in receipt:
        scope = receipt['selection']
        if (receipt['kind'] != 'private-copy' or not isinstance(scope, dict) or
                set(scope) != {'kind', 'lockfile_sha256', 'registry_packages', 'git_revisions'} or
                scope['kind'] != 'cargo-lock-downloads' or not isinstance(scope['lockfile_sha256'], str) or
                not re.fullmatch('[0-9a-f]{64}', scope['lockfile_sha256']) or
                type(scope['registry_packages']) is not int or not 0 <= scope['registry_packages'] <= 10000 or
                not isinstance(scope['git_revisions'], list) or len(scope['git_revisions']) > 10000 or
                not all(isinstance(item, str) and re.fullmatch('[0-9a-f]{40}', item) for item in scope['git_revisions']) or
                scope['git_revisions'] != sorted(set(scope['git_revisions']))):
            raise Failure('invalid lockfile cache selection receipt')
    return summary(path, receipt, hashlib.sha256(data).hexdigest())


try:
    if sys.version_info < (3, 9) or not hasattr(os, 'O_NOFOLLOW'):
        raise Failure('Python 3.9+ on a Unix host is required', 3)
    print(json.dumps(main(sys.argv[1:]), sort_keys=True))
except Failure as error:
    print('[cargo-cache] ' + str(error), file=sys.stderr)
    sys.exit(error.code)
except FileExistsError as error:
    print('[cargo-cache] destination already exists: ' + str(error.filename), file=sys.stderr)
    sys.exit(2)
except (OSError, ValueError, TypeError) as error:
    print('[cargo-cache] ' + str(error), file=sys.stderr)
    sys.exit(7)
PY
}

cargo_cache_snapshot() { _cargo_cache_run snapshot "$@"; }
cargo_cache_inventory() { _cargo_cache_run inventory "$@"; }
cargo_cache_verify() { _cargo_cache_run verify "$@"; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _cargo_cache_run "$@"
    exit $?
fi
