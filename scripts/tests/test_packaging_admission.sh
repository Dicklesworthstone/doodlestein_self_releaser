#!/usr/bin/env bash
# Real archive admission and extraction. No compiler, network, or substituted
# production functions. Retain owned fixture files for failure diagnosis.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dependency in python3 tar gzip xz zip unzip; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'SKIP: missing %s\n' "$dependency"
        exit 0
    fi
done
python3 -I - "${DSR_TEST_PACKAGING_MODULE:-$ROOT/src/packaging.sh}" "$@" <<'PY'
import gzip
import hashlib
import io
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import warnings
import zipfile

MODULE = Path(sys.argv.pop(1)).resolve()
FORMATS = ('tar.gz', 'tar.xz', 'zip')
LIMITS = ('DSR_ARCHIVE_MAX_BYTES', 'DSR_ARCHIVE_MAX_FILE_BYTES', 'DSR_ARCHIVE_MAX_MEMBERS',
          'DSR_ARCHIVE_MAX_PATH_DEPTH', 'DSR_ARCHIVE_MAX_METADATA_BYTES')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Admission(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix='dsr-archive-admission-')).resolve()
        print('Owned archive fixtures retained: ' + str(cls.root), file=sys.stderr)

    def setUp(self):
        self.work = self.root / self._testMethodName
        self.work.mkdir()
        self.serial = 0

    def call(self, function, *arguments, env=None):
        environment = {k: v for k, v in os.environ.items() if k not in LIMITS and
                       k not in ('TAR_OPTIONS', 'UNZIP', 'UNZIPOPT', 'ZIPOPT', 'GZIP',
                                 'XZ_OPT', 'XZ_DEFAULTS', 'BASH_ENV', 'ENV', 'SOURCE_DATE_EPOCH') and
                       not k.startswith('BASH_FUNC_')}
        environment.update(env or {})
        return subprocess.run(['bash', '-c', 'set -uo pipefail; source "$1"; shift; "$@"',
                               '_', str(MODULE), function, *map(str, arguments)],
                              env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=30)

    def archive(self, fmt, rows):
        # rows: name, bytes, Unix mode, kind. ZIP host metadata is explicitly
        # selected, rather than presenting a renamed tar as a Windows archive.
        self.serial += 1
        path = self.work / ('fixture-%d.%s' % (self.serial, fmt))
        if fmt == 'zip':
            with warnings.catch_warnings(), zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
                warnings.simplefilter('ignore', UserWarning)
                for name, data, mode, kind in rows:
                    item = zipfile.ZipInfo(name)
                    item.create_system = 3
                    item.external_attr = ((stat.S_IFDIR if kind == 'dir' else
                                           stat.S_IFLNK if kind == 'link' else stat.S_IFREG) | mode) << 16
                    if kind == 'dir':
                        item.external_attr |= 0x10
                    archive.writestr(item, data)
        else:
            with tarfile.open(path, 'w:gz' if fmt in ('tar.gz', 'tgz') else 'w:xz') as archive:
                for name, data, mode, kind in rows:
                    item = tarfile.TarInfo(name)
                    item.mode = mode
                    item.type = {'file': tarfile.REGTYPE, 'dir': tarfile.DIRTYPE,
                                 'link': tarfile.SYMTYPE, 'hardlink': tarfile.LNKTYPE,
                                 'fifo': tarfile.FIFOTYPE}[kind]
                    if kind in ('link', 'hardlink'):
                        item.linkname = 'other'
                    item.size = len(data) if kind == 'file' else 0
                    archive.addfile(item, io.BytesIO(data) if kind == 'file' else None)
        return path

    def accepted(self, archive, fmt, **env):
        result = self.call('packaging_validate_archive', archive, fmt, env=env)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        self.assertEqual(result.stdout, b'')

    def refused(self, archive, fmt, **env):
        before = sha(archive)
        result = self.call('packaging_validate_archive', archive, fmt, env=env)
        self.assertEqual(result.returncode, 4, (result.stdout + result.stderr).decode(errors='replace'))
        self.assertEqual(result.stdout, b'')
        self.assertEqual(sha(archive), before)

    def test_valid_formats_names_modes_and_payloads(self):
        for fmt in (*FORMATS, 'tgz'):
            with self.subTest(fmt=fmt):
                rows = [('bin/', b'', 0o755, 'dir'), ('bin/tool', b'owned executable', 0o751, 'file'),
                        ('LICENSE notes λ.txt', b'license', 0o644, 'file'), ('empty', b'', 0o600, 'file')]
                archive = self.archive(fmt, rows)
                self.accepted(archive, fmt)
                result = self.call('packaging_list_members', archive, fmt)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.decode(), ''.join(r[0] + '\n' for r in rows))
                dest = self.work / ('out-' + fmt)
                dest.mkdir()
                result = self.call('packaging_extract_payload', archive, fmt, dest)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((dest / 'bin/tool').read_bytes(), b'owned executable')
                self.assertEqual(stat.S_IMODE((dest / 'bin/tool').stat().st_mode) & 0o111, 0o111)
                self.assertEqual((dest / 'LICENSE notes λ.txt').read_bytes(), b'license')

    def test_byte_limits_and_exact_boundaries(self):
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                archive = self.archive(fmt, [('a', b'x' * 8, 0o644, 'file'), ('b', b'y' * 9, 0o644, 'file')])
                self.accepted(archive, fmt, DSR_ARCHIVE_MAX_BYTES='17', DSR_ARCHIVE_MAX_FILE_BYTES='9')
                self.refused(archive, fmt, DSR_ARCHIVE_MAX_BYTES='16')
                self.refused(archive, fmt, DSR_ARCHIVE_MAX_FILE_BYTES='8')
                dest = self.work / ('out-' + fmt)
                dest.mkdir()
                (dest / 'keep').write_bytes(b'untouched')
                result = self.call('packaging_extract_payload', archive, fmt, dest, env={'DSR_ARCHIVE_MAX_BYTES': '16'})
                self.assertEqual(result.returncode, 4)
                self.assertEqual([p.name for p in dest.iterdir()], ['keep'])
                self.assertEqual((dest / 'keep').read_bytes(), b'untouched')

    def test_member_and_implicit_directory_limits(self):
        for fmt in FORMATS:
            archive = self.archive(fmt, [('a/b/c', b'x', 0o644, 'file'), ('d', b'y', 0o644, 'file')])
            with self.subTest(fmt=fmt):
                self.accepted(archive, fmt, DSR_ARCHIVE_MAX_MEMBERS='4', DSR_ARCHIVE_MAX_PATH_DEPTH='3')
                self.refused(archive, fmt, DSR_ARCHIVE_MAX_MEMBERS='3')
                self.refused(archive, fmt, DSR_ARCHIVE_MAX_PATH_DEPTH='2')

    def test_invalid_budget_configuration(self):
        archive = self.archive('zip', [('a', b'x', 0o644, 'file')])
        for setting in LIMITS:
            for value in ('', '0', '-1', '01', '1.5', '1\n', 'auto', '9999999999999999'):
                with self.subTest(setting=setting, value=value):
                    self.refused(archive, 'zip', **{setting: value})

    def test_zip_directory_allocation_budget(self):
        archive = self.archive('zip', [('a', b'x', 0o644, 'file')])
        self.refused(archive, 'zip', DSR_ARCHIVE_MAX_METADATA_BYTES='32')
        self.accepted(archive, 'zip', DSR_ARCHIVE_MAX_METADATA_BYTES='128')

    def test_duplicate_and_path_prefix_collisions(self):
        for fmt in FORMATS:
            for rows in ([('a', b'x', 0o644, 'file'), ('a', b'y', 0o644, 'file')],
                         [('a', b'x', 0o644, 'file'), ('a/b', b'y', 0o644, 'file')],
                         [('a/b', b'y', 0o644, 'file'), ('a', b'x', 0o644, 'file')],
                         [('a/', b'', 0o755, 'dir'), ('a', b'x', 0o644, 'file')]):
                with self.subTest(fmt=fmt, names=[r[0] for r in rows]):
                    archive = self.archive(fmt, rows)
                    self.refused(archive, fmt)
                    result = self.call('packaging_list_members', archive, fmt)
                    self.assertEqual(result.returncode, 4)
                    self.assertEqual(result.stdout, b'')

    def test_unsafe_names_and_no_partial_listing(self):
        for fmt in FORMATS:
            for name in ('../escape', '/absolute', '-option', 'a/../b', 'a//b', 'a/./b', 'a\\b',
                         'C:stream', 'line\nbreak', 'a/' + 'x' * 256):
                with self.subTest(fmt=fmt, name=name):
                    archive = self.archive(fmt, [('first', b'x', 0o644, 'file'), (name, b'y', 0o644, 'file')])
                    self.refused(archive, fmt)
                    result = self.call('packaging_list_members', archive, fmt)
                    self.assertEqual(result.returncode, 4)
                    self.assertEqual(result.stdout, b'')

    def test_links_devices_and_privileged_modes(self):
        for fmt in FORMATS:
            for kind in (('link',) if fmt == 'zip' else ('link', 'hardlink', 'fifo')):
                with self.subTest(fmt=fmt, kind=kind):
                    self.refused(self.archive(fmt, [('a', b'other', 0o644, kind)]), fmt)
            for mode in (0o4755, 0o2755, 0o1644):
                with self.subTest(fmt=fmt, mode=mode):
                    self.refused(self.archive(fmt, [('a', b'x', mode, 'file')]), fmt)

    def test_sparse_tar_is_not_an_unbounded_regular_file(self):
        source = self.work / 'sparse'
        with source.open('wb') as out:
            out.truncate(4 * 1024**2)
        archive = self.work / 'sparse.tar.gz'
        result = subprocess.run(['tar', '--sparse', '-czf', str(archive), '-C', str(self.work), 'sparse'],
                                capture_output=True)
        if result.returncode != 0:
            self.skipTest('GNU sparse fixture creation unavailable on this tar')
        self.refused(archive, 'tar.gz')

    def test_zip_crc_failure_refused_before_destination_writes(self):
        archive = self.archive('zip', [('first', b'FIRST-PAYLOAD', 0o644, 'file'),
                                       ('second', b'SECOND-PAYLOAD', 0o644, 'file')])
        data = archive.read_bytes().replace(b'SECOND-PAYLOAD', b'BROKEN-PAYLOD!')
        archive.write_bytes(data)
        self.refused(archive, 'zip')
        dest = self.work / 'out'
        dest.mkdir()
        result = self.call('packaging_extract_payload', archive, 'zip', dest)
        self.assertEqual(result.returncode, 4)
        self.assertEqual(list(dest.iterdir()), [])

    def test_zip_local_name_must_match_directory(self):
        archive = self.archive('zip', [('first', b'x', 0o644, 'file')])
        data = bytearray(archive.read_bytes())
        data[30:35] = b'other'
        archive.write_bytes(data)
        self.refused(archive, 'zip')

    def test_zip_windows_metadata_and_zip64_payload(self):
        archive = self.work / 'windows.zip'
        with zipfile.ZipFile(archive, 'w') as out:
            entry = zipfile.ZipInfo('tool.exe')
            entry.create_system = 0
            entry.external_attr = 0x20
            with out.open(entry, 'w', force_zip64=True) as stream:
                stream.write(b'owned Windows fixture')
        self.accepted(archive, 'zip')

    def test_zip64_directory_and_conflicting_legacy_counts(self):
        original = self.archive('zip', [('a', b'zip64 payload', 0o644, 'file')])
        raw = original.read_bytes()
        trailer = list(struct.unpack('<4s4H2LH', raw[-22:]))
        count, size, offset = trailer[4:7]
        end = len(raw) - 22
        record = struct.pack('<4sQ2H2L4Q', b'PK\x06\x06', 44, 45, 45, 0, 0, count, count, size, offset)
        locator = struct.pack('<4sLQL', b'PK\x06\x07', 0, end, 1)
        for sentinels in (False, True):
            fields = trailer.copy()
            if sentinels:
                fields[3:7] = [65535, 65535, 0xffffffff, 0xffffffff]
            archive = self.work / ('directory-%s.zip' % sentinels)
            archive.write_bytes(raw[:-22] + record + locator + struct.pack('<4s4H2LH', *fields))
            with zipfile.ZipFile(archive) as verified:
                self.assertIsNone(verified.testzip())
            self.accepted(archive, 'zip')
        trailer[3] = trailer[4] = 2
        bad = self.work / 'conflict.zip'
        bad.write_bytes(raw[:-22] + record + locator + struct.pack('<4s4H2LH', *trailer))
        self.refused(bad, 'zip')

    def test_corrupt_compression_trailers_and_declared_formats(self):
        for fmt in ('tar.gz', 'tar.xz'):
            archive = self.archive(fmt, [('a', b'x', 0o644, 'file')])
            bad = self.work / ('bad.' + fmt)
            data = bytearray(archive.read_bytes())
            data[-8] ^= 1
            bad.write_bytes(data)
            result = self.call('packaging_validate_archive', bad, fmt)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'')
            self.refused(archive, 'zip')

    def test_existing_links_and_files_preserved(self):
        for fmt in FORMATS:
            archive = self.archive(fmt, [('nested/tool', b'new', 0o755, 'file')])
            dest = self.work / ('out-' + fmt)
            dest.mkdir()
            outside = self.work / ('outside-' + fmt)
            outside.mkdir()
            (outside / 'tool').write_bytes(b'old')
            (dest / 'nested').symlink_to(outside, target_is_directory=True)
            result = self.call('packaging_extract_payload', archive, fmt, dest)
            self.assertEqual(result.returncode, 4)
            self.assertEqual((outside / 'tool').read_bytes(), b'old')

    def test_production_build_repack_reuse_and_include_parity(self):
        payload = self.work / 'payload'
        payload.mkdir()
        (payload / 'tool').write_bytes(b'owned executable payload')
        (payload / 'tool').chmod(0o750)
        (payload / 'LICENSE').write_bytes(b'owned license')
        source_pin = sha(payload / 'tool')
        for epoch in (False, True):
            for fmt in FORMATS:
                with self.subTest(epoch=epoch, fmt=fmt):
                    env = {'SOURCE_DATE_EPOCH': '1700000000'} if epoch else {}
                    output = self.work / ('built-%s.%s' % (epoch, fmt))
                    result = self.call('packaging_build_archive', fmt, output, payload, 'tool', 'LICENSE', env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    pin = sha(output)
                    result = self.call('packaging_build_archive', fmt, output, payload, 'tool', 'LICENSE', env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(sha(output), pin)
                    target = self.work / ('repacked-%s-%s.tar.xz' % (epoch, fmt))
                    result = self.call('packaging_repack_archive', output, fmt, target, 'tar.xz', payload, 'LICENSE', env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.accepted(target, 'tar.xz')
        self.assertEqual(sha(payload / 'tool'), source_pin)
        self.assertEqual(stat.S_IMODE((payload / 'tool').stat().st_mode), 0o750)


unittest.main(verbosity=2)
PY
