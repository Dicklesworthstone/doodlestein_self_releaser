#!/usr/bin/env bash
# Private Cargo download caches. Copy bytes, never ambient configuration,
# credentials, symlinks, or source hardlinks. Sourceable and directly runnable.

_cargo_cache_run() {
    command -v python3 >/dev/null || { printf '%s\n' '[cargo-cache] Python 3.9+ is required' >&2; return 3; }
    python3 -I - "$@" <<'PY'
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


def inventory(root, destination=None, require_private_links=False, selected_paths=None):
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

    fd = os.open(root, flags)
    try:
        selected = {}
        for name in (selected_paths if selected_paths is not None else ('registry', 'git')):
            try:
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
            walk(fd, name, name, None if selected_paths is None else selected_paths[name])
        # Ignore unrelated ambient Cargo-home activity, but not replacement of
        # a selected cache root or creation of a previously missing one.
        for name, before in selected.items():
            try:
                after = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                after = None
            same = identity if selected_paths is None else lambda s: (s.st_dev, s.st_ino, s.st_mode)
            if (before is None) != (after is None) or (before is not None and same(before) != same(after)):
                raise Failure('cache root changed while reading: ' + name)
        if require_private_links:
            for name, before in selected.items():
                if before is not None:
                    recheck_private_links(fd, name, name)
    finally:
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


def locked_selection(source, lockfile):
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
        # checkout is never even opened. Relevant root links still fail.
        parent = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for part in relative.split('/'):
                try:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                except FileNotFoundError:
                    return []
                os.close(parent)
                parent = child
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
        parent = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            parts = relative.split('/')
            for part in parts[:-1]:
                try:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                except FileNotFoundError:
                    return False
                os.close(parent)
                parent = child
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
                    parent = os.open(os.path.join(source, 'registry/cache', registry), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
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
                origin = git_probe(gitdir, ['config', '--local', '--get', 'remote.origin.url']).decode('utf-8', 'replace').strip().rstrip('/')
                if origin in registries:
                    add(prefix + '.git')
    if source is not None and revisions:
        request = ''.join(revision + '\n' for revision in sorted(revisions)).encode('ascii')
        for database in children('git/db'):
            relative = 'git/db/' + database
            rows = git_probe(os.path.join(source, relative), ['cat-file', '--batch-check'], request).splitlines()
            if any(len(row.split()) == 3 and row.split()[0].decode('ascii', 'replace') in revisions and
                   row.split()[1] == b'commit' for row in rows):
                add(relative)
    scope = {'kind': 'cargo-lock-downloads', 'lockfile_sha256': hashlib.sha256(raw).hexdigest(),
             'registry_packages': len(archives), 'git_revisions': sorted(revisions)}
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
        paths, checksums, scope = None, {}, None
        if len(args) == 4:
            paths, checksums, scope = locked_selection(source, args[3])
        destination = absolute(second)
        parent = os.path.realpath(os.path.dirname(destination))
        destination = os.path.join(parent, os.path.basename(destination))
        if source is not None and (inside(destination, source) or inside(source, destination)):
            raise Failure('source and private Cargo home must not overlap', 4)
        os.mkdir(destination, 0o700)
        created = os.lstat(destination)
        complete = False
        try:
            selected = inventory(source, destination, selected_paths=paths) if source else {'caches': [], 'directories': [], 'files': []}
            if any(entry['path'] in checksums and entry['sha256'] != checksums[entry['path']]
                   for entry in selected['files']):
                raise Failure('selected archive changed after lockfile admission')
            if inventory(destination, require_private_links=True) != selected:
                raise Failure('private cache copy does not match its seed')
            receipt = {'schema_version': 1, 'kind': 'private-copy', 'cargo_home': destination,
                       'seed_source': source, 'inventory': selected}
            if scope is not None:
                if hashlib.sha256(read_path(args[3])).hexdigest() != scope['lockfile_sha256']:
                    raise Failure('Cargo.lock changed during cache preparation')
                receipt['selection'] = scope
            path = os.path.join(destination, '.dsr-cache-seed.json')
            digest = new_receipt(path, receipt)
            complete = True
            return summary(path, receipt, digest)
        finally:
            if not complete and os.path.lexists(destination):
                current = os.lstat(destination)
                if (current.st_dev, current.st_ino) == (created.st_dev, created.st_ino):
                    shutil.rmtree(destination)
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
