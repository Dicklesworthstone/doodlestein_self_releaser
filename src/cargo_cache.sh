#!/usr/bin/env bash
# Private Cargo download caches. Copy bytes, never ambient configuration,
# credentials, symlinks, or source hardlinks. Sourceable and directly runnable.

_cargo_cache_run() {
    command -v python3 >/dev/null || { printf '%s\n' '[cargo-cache] Python 3.9+ is required' >&2; return 3; }
    python3 -I - "$@" <<'PY'
import hashlib
import json
import os
import shutil
import signal
import stat
import sys
import tempfile


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
            info.st_mtime_ns, info.st_ctime_ns)


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
    if not parts or parts[0] != 'git':
        return False
    # A copied checkout must not retain a gitdir/commondir/alternate-object
    # pointer into the ambient home. Ordinary Cargo-owned clones need none.
    return (parts[-1] == '.git' or
            (size > 0 and parts[-3:] == ['objects', 'info', 'alternates']) or
            (size > 0 and parts[-1] == 'commondir' and
             ('.git' in parts[:-1] or (len(parts) == 4 and parts[1] == 'db'))))


def inventory(root, destination=None):
    files, directories, caches = [], [], []
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW

    def walk(parent, name, relative):
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if stat.S_ISDIR(before.st_mode):
            fd = os.open(name, flags, dir_fd=parent)
            try:
                if identity(before) != identity(os.fstat(fd)):
                    raise Failure('cache directory replaced: ' + relative)
                directories.append(relative)
                if destination is not None:
                    os.mkdir(os.path.join(destination, relative), 0o700)
                names = sorted(os.listdir(fd), key=os.fsencode)
                for child in names:
                    walk(fd, child, relative + '/' + child)
                if (names != sorted(os.listdir(fd), key=os.fsencode) or
                        identity(before) != identity(os.fstat(fd)) or
                        identity(before) != identity(os.stat(name, dir_fd=parent, follow_symlinks=False))):
                    raise Failure('cache directory changed while reading: ' + relative)
            finally:
                os.close(fd)
        elif stat.S_ISREG(before.st_mode):
            if external_git_reference(relative, before.st_size):
                raise Failure('external Git storage reference: ' + relative)
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

    fd = os.open(root, flags)
    try:
        selected = {}
        for name in ('registry', 'git'):
            try:
                selected[name] = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                selected[name] = None
        for name, before in selected.items():
            if before is None:
                continue
            if not stat.S_ISDIR(before.st_mode):
                raise Failure('cache root is not a real directory: ' + name)
            caches.append(name)
            walk(fd, name, name)
        # Ignore unrelated ambient Cargo-home activity, but not replacement of
        # a selected cache root or creation of a previously missing one.
        for name, before in selected.items():
            try:
                after = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                after = None
            if (before is None) != (after is None) or (before is not None and identity(before) != identity(after)):
                raise Failure('cache root changed while reading: ' + name)
    finally:
        os.close(fd)
    return {'caches': sorted(caches), 'directories': sorted(directories, key=os.fsencode),
            'files': sorted(files, key=lambda entry: os.fsencode(entry['path']))}


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()


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
    return {'schema_version': 1, 'mode': receipt['kind'], 'cargo_home': receipt['cargo_home'],
            'receipt_path': path, 'receipt_sha256': digest,
            'inventory_sha256': hashlib.sha256(canonical(receipt['inventory'])).hexdigest(),
            'caches': receipt['inventory']['caches'], 'file_count': len(entries),
            'size_bytes': sum(entry['size_bytes'] for entry in entries)}


def main(args):
    if len(args) != 3 or args[0] not in ('snapshot', 'inventory', 'verify'):
        raise Failure('usage: cargo_cache.sh snapshot SOURCE_HOME NEW_HOME | inventory HOME NEW_RECEIPT | verify HOME RECEIPT', 4)
    command, first, second = args
    if command == 'snapshot':
        source = root_path(first) if first else None
        destination = absolute(second)
        parent = os.path.realpath(os.path.dirname(destination))
        destination = os.path.join(parent, os.path.basename(destination))
        if source is not None and (inside(destination, source) or inside(source, destination)):
            raise Failure('source and private Cargo home must not overlap', 4)
        os.mkdir(destination, 0o700)
        created = os.lstat(destination)
        complete = False
        try:
            selected = inventory(source, destination) if source else {'caches': [], 'directories': [], 'files': []}
            if inventory(destination) != selected:
                raise Failure('private cache copy does not match its seed')
            receipt = {'schema_version': 1, 'kind': 'private-copy', 'cargo_home': destination,
                       'seed_source': source, 'inventory': selected}
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
                   'seed_source': None, 'inventory': inventory(home)}
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
            set(receipt) != {'schema_version', 'kind', 'cargo_home', 'seed_source', 'inventory'} or
            type(receipt['schema_version']) is not int or receipt['schema_version'] != 1 or
            receipt['kind'] not in ('private-copy', 'inventory') or receipt['cargo_home'] != home or
            receipt['inventory'] != inventory(home)):
        raise Failure('private Cargo cache does not match its inventory')
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
