#!/usr/bin/env bash
# Exercise real content admission with specification-shaped CFB fixtures and
# malformed bytes. The CFB fixtures are not executable/semantically valid MSI
# installers; these tests prove structural admission, not installer safety.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
    printf 'SKIP: Python 3 is required\n'
    exit 0
fi
python3 -I - "$ROOT/src/artifact_formats.sh" "$@" <<'PY'
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid

MODULE = Path(sys.argv.pop(1)).resolve()
FREE, END, FAT, DIF = 0xffffffff, 0xfffffffe, 0xfffffffd, 0xfffffffc
MSI_CLASS = uuid.UUID('000C1084-0000-0000-C000-000000000046').bytes_le


def entry(name, kind, start=END, size=0, child=FREE, left=FREE, right=FREE, color=1, clsid=bytes(16)):
    data = bytearray(128)
    encoded = (name + '\0').encode('utf-16le')
    data[:len(encoded)] = encoded
    struct.pack_into('<HBBIII', data, 64, len(encoded), kind, color, left, right, child)
    data[80:96] = clsid
    struct.pack_into('<IQ', data, 116, start, size)
    return data


def compound(version=3, normal=False, difat=False):
    # MS-CFB structures, plus an MS-OLEPS SummaryInformation property set with
    # a Codepage property. Store payloads through both mini and normal chains.
    width = 512 if version == 3 else 4096
    fat_count = 110 if difat else 1
    directory, minifat, mini = fat_count, fat_count + 1, fat_count + 2
    dif = fat_count + 3 if difat else None
    normal_start = fat_count + 3 + int(difat)
    total = normal_start + (4096 // width if normal else 0)
    sectors = [bytearray(width) for _ in range(total)]
    allocation = [FREE] * (width // 4 * fat_count)
    for index in range(fat_count):
        allocation[index] = FAT
    for index in (directory, minifat, mini):
        allocation[index] = END
    if difat:
        allocation[dif] = DIF
        struct.pack_into('<' + 'I' * (width // 4), sectors[dif], 0,
                         109, *([FREE] * (width // 4 - 2)), END)
    if normal:
        for index in range(normal_start, total):
            allocation[index] = index + 1 if index + 1 < total else END
            sectors[index][:] = b'x' * width
    for index in range(fat_count):
        struct.pack_into('<' + 'I' * (width // 4), sectors[index], 0,
                         *allocation[index * (width // 4):(index + 1) * (width // 4)])
    summary = bytearray(72)
    struct.pack_into('<HHI', summary, 0, 0xfffe, 0, 0x00020006)
    struct.pack_into('<I', summary, 24, 1)
    summary[28:44] = uuid.UUID('F29F85E0-4FF9-1068-AB91-08002B27B3D9').bytes_le
    struct.pack_into('<IIIIII', summary, 44, 48, 24, 1, 1, 16, 2)
    struct.pack_into('<H', summary, 68, 1252)
    sectors[mini][:72] = summary
    if not normal:
        sectors[mini][128:132] = b'DB\0\0'
    mini_allocation = [1, END, *([FREE] * (width // 4 - 2))]
    if not normal:
        mini_allocation[2] = END
    struct.pack_into('<' + 'I' * (width // 4), sectors[minifat], 0, *mini_allocation)
    sectors[directory][:128] = entry('Root Entry', 5, mini, 128 if normal else 192, child=1, clsid=MSI_CLASS)
    sectors[directory][128:256] = entry('\x05SummaryInformation', 2, 0, 72, left=2)
    sectors[directory][256:384] = entry('payload', 2, normal_start if normal else 2,
                                      4096 if normal else 4, color=0)
    header = bytearray(width)
    header[:8] = bytes.fromhex('d0cf11e0a1b11ae1')
    struct.pack_into('<5H', header, 24, 0x3e, version, 0xfffe, 9 if version == 3 else 12, 6)
    struct.pack_into('<9I', header, 40, 0 if version == 3 else 1, fat_count, directory, 0,
                     4096, minifat, 1, dif if difat else END, int(difat))
    struct.pack_into('<109I', header, 76, *range(min(fat_count, 109)), *([FREE] * (109 - min(fat_count, 109))))
    return header + b''.join(sectors)


def summary_document(properties):
    data = compound()
    header = data[2048:2048 + 48]
    position = 8 + 8 * len(properties)
    offsets, values = bytearray(), bytearray()
    for prop, value in properties:
        offsets.extend(struct.pack('<II', prop, position))
        values.extend(value)
        position += len(value)
    summary = header + struct.pack('<II', position, len(properties)) + offsets + values
    assert 64 < len(summary) <= 128
    data[2048:2048 + 128] = summary + bytes(128 - len(summary))
    struct.pack_into('<Q', data, 1024 + 128 + 120, len(summary))
    return data


class Admission(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix='dsr-artifact-formats-'))
        print('Owned content-admission fixtures retained: ' + str(cls.root), file=sys.stderr)

    def setUp(self):
        self.work = self.root / self._testMethodName
        self.work.mkdir()
        self.serial = 0

    def fixture(self, data):
        self.serial += 1
        path = self.work / str(self.serial)
        path.write_bytes(data)
        return path

    def call(self, kind, path, *receipt, environment=None):
        env = {key: value for key, value in os.environ.items()
               if key not in ('BASH_ENV', 'ENV') and not key.startswith('BASH_FUNC_')}
        env.update(environment or {})
        return subprocess.run(['/bin/bash', '-c', 'set -uo pipefail; source "$1"; shift; "$@"',
                               '_', str(MODULE), 'artifact_format_validate_' + kind, str(path), *map(str, receipt)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=10)

    def admitted(self, kind, path, *receipt):
        before = path.read_bytes()
        result = self.call(kind, path, *receipt)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        self.assertEqual(result.stdout, b'')
        self.assertEqual(path.read_bytes(), before)

    def refused(self, kind, path, *receipt):
        before = path.read_bytes()
        result = self.call(kind, path, *receipt)
        self.assertEqual(result.returncode, 4, (result.stdout + result.stderr).decode(errors='replace'))
        self.assertEqual(result.stdout, b'')
        self.assertIn(b'Content admission failed:', result.stderr)
        self.assertNotIn(b'Traceback', result.stderr)
        self.assertEqual(path.read_bytes(), before)

    def test_json_complete_documents_and_receipts(self):
        for data in (b'{"release":{"platforms":["linux/armv7","freebsd/amd64"],"ok":true},"size":42}\n',
                     ' {"description":"\u03bb"} '.encode(), b'null', b'[1.25,-2,3e2]'):
            path = self.fixture(data)
            self.admitted('json', path)
            self.admitted('json', path, hashlib.sha256(data).hexdigest(), len(data))

    def test_json_syntax_ambiguity_and_nonfinite_values(self):
        for data in (b'', b'{', b'{}{}', b'{}\x00', b'\xff', b'\xef\xbb\xbf{}',
                     b'{"key":1,"key":2}', b'{"parent":{"x":1,"x":2}}', b'{"a":1,"\\u0061":2}',
                     b'[NaN]', b'Infinity', b'-Infinity', b'1e9999', b'01', b'1' * 4097,
                     b'[' * 2000 + b'0' + b']' * 2000):
            with self.subTest(data=data[:50]):
                self.refused('json', self.fixture(data))

    def test_json_nesting_limit_ignores_brackets_inside_strings(self):
        self.admitted('json', self.fixture(b'[' * 256 + b'0' + b']' * 256))
        self.refused('json', self.fixture(b'[' * 257 + b'0' + b']' * 257))
        self.admitted('json', self.fixture(b'["' + b'[' * 1000 + b'\\\"\\\\]' + b']' * 1000 + b'"]'))

    def test_content_receipt_binding(self):
        for kind, data in (('json', b'{}'), ('msi', compound())):
            path = self.fixture(data)
            digest = hashlib.sha256(data).hexdigest()
            self.admitted(kind, path, digest, len(data))
            self.refused(kind, path, '0' * 64, len(data))
            self.refused(kind, path, digest, len(data) + 1)
            self.refused(kind, path, digest.upper(), len(data))
            self.refused(kind, path, digest, str(len(data)) + '\n')
            self.refused(kind, path, digest, '0' + str(len(data)))

    def test_regular_file_and_missing_dependency_guards(self):
        real = self.fixture(b'{}')
        link = self.work / 'link'
        link.symlink_to(real)
        fifo = self.work / 'fifo'
        os.mkfifo(fifo)
        for kind in ('json', 'msi'):
            for path in (link, fifo, self.work, self.work / 'absent'):
                result = self.call(kind, path)
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertEqual(result.stdout, b'')
            result = self.call(kind, real, environment={'PATH': '/nonexistent'})
            self.assertEqual(result.returncode, 3)
            self.assertIn(b'Python 3.8', result.stderr)

    def test_sparse_oversized_inputs_are_rejected_before_reading(self):
        for kind, limit in (('json', 16 * 1024**2), ('msi', 8 * 1024**3)):
            path = self.fixture(b'x')
            with path.open('r+b') as output:
                output.truncate(limit + 1)
            result = self.call(kind, path)
            self.assertEqual(result.returncode, 4, result.stderr)
            self.assertIn(b'size limit', result.stderr)

    def test_cfb_versions_and_stream_allocations(self):
        for version in (3, 4):
            for normal in (False, True):
                data = compound(version, normal)
                self.admitted('msi', self.fixture(data), hashlib.sha256(data).hexdigest(), len(data))

    @unittest.skipUnless(shutil.which('msibuild') and shutil.which('msiinfo'), 'msitools is unavailable; synthetic CFB coverage still runs')
    def test_independent_msibuild_producer_and_corruption(self):
        payload = self.fixture(b'An independent compound-document writer owns these bytes.\n')
        package = self.work / 'producer.msi'
        built = subprocess.run(['msibuild', str(package), '-s', 'DSR admission fixture', 'DSR',
                                'Intel;1033', '{CE8C37CE-B5B5-4899-8117-E82F94350ACB}'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(built.returncode, 0, (built.stdout + built.stderr).decode(errors='replace'))
        added = subprocess.run(['msibuild', str(package), '-a', 'fixture-payload', str(payload)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(added.returncode, 0, (added.stdout + added.stderr).decode(errors='replace'))
        inspected = subprocess.run(['msiinfo', 'suminfo', str(package)], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(inspected.returncode, 0, inspected.stderr)
        self.assertIn(b'DSR admission fixture', inspected.stdout)
        data = package.read_bytes()
        self.admitted('msi', package, hashlib.sha256(data).hexdigest(), len(data))
        self.refused('msi', self.fixture(data[:-1]))
        wrong_class = bytearray(data)
        width = 1 << struct.unpack_from('<H', data, 30)[0]
        root = (struct.unpack_from('<I', data, 48)[0] + 1) * width
        wrong_class[root + 80:root + 96] = uuid.UUID('000C1086-0000-0000-C000-000000000046').bytes_le
        self.refused('msi', self.fixture(wrong_class))
        # MSI treats Codepage as optional. Exercise the same real writer with
        # an explicit value too, via Microsoft's documented import table.
        table = self.work / '_SummaryInformation.idt'
        table.write_text('PropertyId\tValue\ni2\tl255\n_SummaryInformation\tPropertyId\n1\t1252\n', encoding='utf-8')
        updated = subprocess.run(['msibuild', str(package), '-i', str(table)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(updated.returncode, 0, (updated.stdout + updated.stderr).decode(errors='replace'))
        inspected = subprocess.run(['msiinfo', 'export', str(package), '_SummaryInformation'], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(inspected.returncode, 0, inspected.stderr)
        self.assertIn(b'1\t1252', inspected.stdout)
        data = package.read_bytes()
        self.admitted('msi', package, hashlib.sha256(data).hexdigest(), len(data))

    @unittest.skipUnless(shutil.which('wixl') and shutil.which('msiextract'), 'wixl/msiextract is unavailable; synthetic CFB coverage still runs')
    def test_independent_wixl_package_and_payload_extraction(self):
        payload = self.work / 'payload.txt'
        payload.write_bytes(b'DSR independent MSI package payload\n')
        definition = self.work / 'fixture.wxs'
        definition.write_text('''<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="CE8C37CE-B5B5-4899-8117-E82F94350ACB" Name="DSRFormatFixture" Language="1033" Version="1.0.0" Manufacturer="DSR" UpgradeCode="583283DF-ED20-47E3-9C54-41F60E8CF03D">
    <Package InstallerVersion="200" Compressed="yes" InstallScope="perUser"/>
    <Media Id="1" Cabinet="fixture.cab" EmbedCab="yes"/>
    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="LocalAppDataFolder">
        <Directory Id="INSTALLDIR" Name="DSRFormatFixture">
          <Component Id="Payload" Guid="6243D1BA-24E6-4442-9341-931CB2915642">
            <File Id="FixtureFile" Name="payload.txt" Source="payload.txt" KeyPath="yes"/>
          </Component>
        </Directory>
      </Directory>
    </Directory>
    <Feature Id="Main" Title="Fixture" Level="1"><ComponentRef Id="Payload"/></Feature>
  </Product>
</Wix>
''', encoding='utf-8')
        package = self.work / 'package.msi'
        built = subprocess.run(['wixl', '-o', str(package), str(definition)], cwd=self.work,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(built.returncode, 0, (built.stdout + built.stderr).decode(errors='replace'))
        data = package.read_bytes()
        self.admitted('msi', package, hashlib.sha256(data).hexdigest(), len(data))
        extracted = self.work / 'extracted'
        extracted.mkdir()
        result = subprocess.run(['msiextract', '-C', str(extracted), str(package)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode(errors='replace'))
        files = [path for path in extracted.rglob('*') if path.is_file()]
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].read_bytes(), payload.read_bytes())
        self.refused('msi', self.fixture(data[:-1]))

    def test_v3_legacy_high_size_dword_and_v4_full_size(self):
        data = compound()
        for index in range(3):
            struct.pack_into('<I', data, 1024 + index * 128 + 124, 0x12345678)
        self.admitted('msi', self.fixture(data))
        for index in range(3):
            data = compound(4)
            struct.pack_into('<I', data, 8192 + index * 128 + 124, 1)
            self.refused('msi', self.fixture(data))

    def test_difat_chain_and_extra_fat_sectors(self):
        data = compound(difat=True)
        self.admitted('msi', self.fixture(data))
        for offset, value in ((68, 0xffffffff), (72, 2), ((113 + 1) * 512 + 508, 113),
                              ((113 + 1) * 512, 0), (76, 1)):
            invalid = bytearray(data)
            struct.pack_into('<I', invalid, offset, value)
            self.refused('msi', self.fixture(invalid))

    def test_header_class_and_container_type(self):
        for data in (b'arbitrary executable', b'D0CF11E0A1B11AE1', compound()[:512], compound()[:-1]):
            self.refused('msi', self.fixture(data))
        for clsid in ('00000000-0000-0000-0000-000000000000',
                      '000C1082-0000-0000-C000-000000000046',
                      '000C1086-0000-0000-C000-000000000046',
                      '00020906-0000-0000-C000-000000000046'):
            data = compound()
            data[1024 + 80:1024 + 96] = uuid.UUID(clsid).bytes_le
            self.refused('msi', self.fixture(data))
        for offset, value in ((8, 1), (26, 5), (28, 0), (30, 12), (32, 5), (34, 1), (56, 1024)):
            data = compound()
            struct.pack_into('<H', data, offset, value)
            self.refused('msi', self.fixture(data))
        data = compound(4)
        data[512] = 1
        self.refused('msi', self.fixture(data))

    def test_fat_directory_and_minifat_corruption(self):
        for offset, value in ((44, 0xffffffff), (48, 0xffffffff), (64, 0xffffffff),
                              (512, END), (512 + 4, 1), (512 + 8, 1), (512 + 12, FREE),
                              (512 + 16, END), (1536, 0), (1536, 999), (1544, 0),
                              (1024 + 116, 1), (1024 + 120, 0xffffffff),
                              (1024 + 128 + 116, 999), (1024 + 128 + 120, 4096),
                              (1024 + 256 + 116, 0)):
            with self.subTest(offset=offset, value=value):
                data = compound()
                struct.pack_into('<I', data, offset, value)
                self.refused('msi', self.fixture(data))

    def test_directory_cycles_shared_or_dangling_entries(self):
        for offset, value in ((1024 + 76, FREE), (1024 + 76, 99),
                              (1024 + 128 + 68, 1), (1024 + 128 + 72, 2),
                              (1024 + 256 + 68, 1), (1024 + 256 + 76, 1)):
            data = compound()
            struct.pack_into('<I', data, offset, value)
            self.refused('msi', self.fixture(data))
        for offset, value in ((1024 + 66, 2), (1024 + 128 + 66, 5), (1024 + 256 + 66, 0),
                              (1024 + 128 + 64, 63), (1024 + 128 + 67, 3)):
            data = compound()
            data[offset] = value
            self.refused('msi', self.fixture(data))

    def test_directory_order_colors_and_utf16_comparison(self):
        data = compound()
        struct.pack_into('<II', data, 1024 + 128 + 68, FREE, 2)
        self.refused('msi', self.fixture(data))
        data = compound()
        data[1024 + 256:1024 + 384] = entry('payload', 2, 2, 4, left=3, color=0)
        data[1024 + 384:1024 + 512] = entry('a', 2, color=1)
        self.admitted('msi', self.fixture(data))
        data[1024 + 384 + 67] = 0
        self.refused('msi', self.fixture(data))
        data = compound()
        data[1024 + 128 + 67] = 0
        self.refused('msi', self.fixture(data))
        data = compound()
        data[1024 + 256:1024 + 384] = entry('payload', 2, 2, 4, right=3, color=0)
        data[1024 + 384:1024 + 512] = entry('PAYLOAD', 2)
        self.refused('msi', self.fixture(data))
        # CFB preserves the surrogate units; these two Deseret names must not
        # collapse to one name through Python's scalar Unicode uppercasing.
        data = compound()
        data[1024 + 256:1024 + 384] = entry('\U00010428', 2, 2, 4, left=3, color=0)
        data[1024 + 384:1024 + 512] = entry('\U00010400', 2)
        self.admitted('msi', self.fixture(data))
        struct.pack_into('<II', data, 1024 + 256 + 68, FREE, 3)
        self.refused('msi', self.fixture(data))

    def test_nested_storage_names_have_independent_trees(self):
        data = compound(4)
        directory = 8192
        data[directory + 256:directory + 384] = entry('payload', 2, 2, 4, right=3, color=0)
        data[directory + 384:directory + 512] = entry('storage', 1, 0, 0, child=4)
        data[directory + 512:directory + 640] = entry('payload', 2)
        self.admitted('msi', self.fixture(data))
        # Root Entry itself has no siblings, so either color is permitted.
        data[directory + 67] = 0
        self.admitted('msi', self.fixture(data))
        data[directory + 512 + 67] = 0
        self.refused('msi', self.fixture(data))

    def test_msi_summary_and_database_payload_are_required(self):
        for offset, value in ((2048, 0), (2048 + 24, 2), (2048 + 28, 0),
                              (2048 + 44, 0xfffffff0), (2048 + 48, 0xffffffff),
                              (2048 + 52, 0), (2048 + 52, 0xffffffff), (2048 + 60, 0)):
            data = compound()
            struct.pack_into('<I', data, offset, value)
            self.refused('msi', self.fixture(data))
        data = compound()
        data[1024 + 128:1024 + 256] = entry('UnrelatedInformation', 2, 0, 72, left=2)
        self.refused('msi', self.fixture(data))
        data = compound()
        data[1024 + 256:1024 + 384] = entry('payload', 2, END, 0, color=0)
        struct.pack_into('<I', data, 1544, FREE)
        self.refused('msi', self.fixture(data))

    def test_summary_property_types_lengths_and_codepages(self):
        for codepage in (1252, 1200):
            code = (1, struct.pack('<IHH', 2, codepage, 0))
            for kind, value in ((3, struct.pack('<I', 42)), (64, bytes(8))):
                self.admitted('msi', self.fixture(summary_document([code, (12, struct.pack('<I', kind) + value)])))
            for text in (b'', b'a\0b\0\0\0', b'\0\0'):
                payload = struct.pack('<II', 30, len(text)) + text + bytes(-len(text) % 4)
                self.admitted('msi', self.fixture(summary_document([code, (2, payload)])))
            for payload in (struct.pack('<II', 64, 0), struct.pack('<I', 0xffffffff),
                            struct.pack('<II', 30, 0xfffffff0), struct.pack('<II4s', 30, 4, b'nope'),
                            struct.pack('<II4s', 30, 1, b'\0xxx'), struct.pack('<HHI', 3, 1, 0)):
                self.refused('msi', self.fixture(summary_document([code, (2, payload)])))
        data = summary_document([(1, struct.pack('<IHH', 2, 1252, 0)), (12, struct.pack('<IQ', 64, 0))])
        # Every property reference is in bounds, but reversing the table is
        # forbidden even when each property can be read individually.
        first = bytes(data[2048 + 56:2048 + 64])
        data[2048 + 56:2048 + 64] = data[2048 + 64:2048 + 72]
        data[2048 + 64:2048 + 72] = first
        self.refused('msi', self.fixture(data))


if len(sys.argv) == 3 and sys.argv[1] == '--write-fixtures':
    # Other integration suites exercise the real collectors with these same
    # small format fixtures; do not duplicate their CFB construction code.
    directory = Path(sys.argv[2])
    directory.mkdir(parents=True, exist_ok=True)
    suitable = compound()
    ordinary = bytearray(suitable)
    ordinary[1024 + 80:1024 + 96] = uuid.UUID('00020906-0000-0000-C000-000000000046').bytes_le
    for name, data in (('suitable.msi', suitable), ('ordinary-ole.msi', ordinary),
                       ('corrupt.msi', suitable[:-1])):
        with (directory / name).open('xb') as output:
            output.write(data)
else:
    unittest.main()
PY
