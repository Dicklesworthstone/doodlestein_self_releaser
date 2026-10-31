#!/usr/bin/env bash
# Content admission for explicitly typed additional release artifacts. This is
# independent of filename selection, producer receipts and release signatures.
# MSI admission checks a Windows Installer database compound document, not its
# installation semantics or publisher authentication. MSM/PCP share its CLSID.
#
# Format references (Microsoft):
# https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/
# https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-oleps/
# https://devblogs.microsoft.com/setup/identifying-windows-installer-file-types/

_artifact_format_validate() {
    command -v python3 >/dev/null 2>&1 || {
        printf '[artifact formats] Python 3.8 or newer is required\n' >&2
        return 3
    }
    python3 -I - "$@" <<'PY'
import array
import hashlib
import json
import math
import os
import re
import stat
import struct
import sys

if sys.version_info < (3, 8):
    print('[artifact formats] Python 3.8 or newer is required', file=sys.stderr)
    sys.exit(3)

MAX_JSON = 16 * 1024**2
MAX_MSI = 8 * 1024**3
MAX_METADATA = 16 * 1024**2
MAX_DIRECTORY_ENTRIES = 65536
FREE, END, FAT, DIF = 0xffffffff, 0xfffffffe, 0xfffffffd, 0xfffffffc
MSI_CLASS = bytes.fromhex('84100c0000000000c000000000000046')
SUMMARY_CLASS = bytes.fromhex('e0859ff2f94f6810ab9108002b27b3d9')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def digest(source, size):
    source.seek(0)
    result = hashlib.sha256()
    remaining = size
    while remaining:
        data = source.read(min(remaining, 1024**2))
        require(data, 'artifact was truncated during admission')
        result.update(data)
        remaining -= len(data)
    require(not source.read(1), 'artifact grew during admission')
    return result.hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON object key: ' + repr(key[:120]) + ('...' if len(key) > 120 else ''))
        result[key] = value
    return result


def number(text, integer=False):
    require(len(text) <= 4096, 'JSON number exceeds the 4096-character limit')
    result = int(text) if integer else float(text)
    require(integer or math.isfinite(result), 'nonfinite JSON number')
    return result


def json_document(source, size):
    source.seek(0)
    data = source.read(size)
    require(len(data) == size, 'JSON document was truncated')
    text = data.decode('utf-8')
    # Bound nesting before the recursive decoder, independently of the host
    # interpreter's recursion limit. Brackets inside strings are ordinary data.
    depth, quoted, escaped = 0, False, False
    for character in text:
        if quoted:
            if escaped:
                escaped = False
            elif character == '\\':
                escaped = True
            elif character == '"':
                quoted = False
        elif character == '"':
            quoted = True
        elif character in '[{':
            depth += 1
            require(depth <= 256, 'JSON nesting exceeds the 256-level limit')
        elif character in ']}':
            depth -= 1
    json.loads(text, object_pairs_hook=unique_object,
               parse_int=lambda text: number(text, True), parse_float=number,
               parse_constant=lambda text: require(False, 'nonfinite JSON number: ' + text))


def directory_key(encoded):
    # MS-CFB compares length, then simple uppercase UTF-16 units. Surrogate
    # pairs remain unchanged. Python's full uppercase expands some characters;
    # titlecase supplies the single-unit Greek simple-uppercase mapping.
    units = struct.unpack('<' + 'H' * (len(encoded) // 2), encoded)
    result = []
    for unit in units:
        character = chr(unit)
        upper = character.upper()
        if len(upper) != 1:
            upper = character.title()
        result.append(ord(upper) if len(upper) == 1 else unit)
    return (len(encoded), tuple(result))


class CompoundDocument:
    def __init__(self, source, size):
        self.source, self.size, self.metadata = source, size, 0
        header = self.read(0, 512)
        require(header[:8] == bytes.fromhex('d0cf11e0a1b11ae1'), 'missing CFB signature')
        require(header[8:24] == bytes(16), 'CFB header CLSID must be zero')
        self.version, order, shift, mini_shift = struct.unpack_from('<4H', header, 26)
        require((self.version, shift) in ((3, 9), (4, 12)), 'invalid CFB version or sector size')
        require(order == 0xfffe and mini_shift == 6, 'invalid CFB byte order or mini-sector size')
        require(header[34:40] == bytes(6), 'invalid CFB reserved header bytes')
        self.sector_size = 1 << shift
        require(size >= self.sector_size * 3 and size % self.sector_size == 0,
                'truncated or unaligned CFB document')
        if self.version == 4:
            require(self.read(512, self.sector_size - 512) == bytes(self.sector_size - 512),
                    'invalid CFB version 4 header padding')
        self.sectors = size // self.sector_size - 1
        self.claimed = bytearray(self.sectors)
        directory_count, fat_count, directory_start = struct.unpack_from('<3I', header, 40)
        cutoff, mini_start, mini_count, dif_start, dif_count = struct.unpack_from('<5I', header, 56)
        require(cutoff == 4096, 'invalid CFB mini-stream cutoff')
        require(self.version != 3 or directory_count == 0, 'invalid version 3 directory count')
        require(0 < fat_count <= self.sectors and fat_count * self.sector_size <= MAX_METADATA,
                'CFB FAT exceeds the metadata budget or file size')
        require(dif_count <= self.sectors and dif_count * self.sector_size <= MAX_METADATA,
                'CFB DIFAT exceeds the metadata budget or file size')
        fat_sectors = []

        def admit_fat_ids(ids):
            for sector in ids:
                if sector != FREE:
                    require(len(fat_sectors) < fat_count, 'CFB DIFAT contains excess FAT sectors')
                    self.claim(sector, 'FAT')
                    fat_sectors.append(sector)

        admit_fat_ids(struct.unpack_from('<109I', header, 76))
        dif_sectors = []
        for _ in range(dif_count):
            self.claim(dif_start, 'DIFAT')
            dif_sectors.append(dif_start)
            entries = struct.unpack('<' + 'I' * (self.sector_size // 4), self.sector(dif_start))
            admit_fat_ids(entries[:-1])
            dif_start = entries[-1]
        require(dif_start == END and len(fat_sectors) == fat_count, 'incomplete CFB DIFAT chain')
        self.fat = self.table(fat_sectors)
        require(len(self.fat) >= self.sectors, 'CFB FAT does not cover the file')
        for sector in fat_sectors:
            require(self.fat[sector] == FAT, 'CFB FAT sector lacks its allocation marker')
        for sector in dif_sectors:
            require(self.fat[sector] == DIF, 'CFB DIFAT sector lacks its allocation marker')
        for sector, value in enumerate(self.fat):
            require((sector < self.sectors and (value in (FREE, END, FAT, DIF) or value < self.sectors)) or
                    (sector >= self.sectors and value == FREE), 'CFB FAT contains an out-of-file reference')

        directories = self.chain(directory_start, 'directory', maximum=MAX_DIRECTORY_ENTRIES * 128 // self.sector_size)
        require(directories and (self.version == 3 or len(directories) == directory_count),
                'inconsistent CFB directory sector count')
        self.budget(len(directories) * self.sector_size)
        self.entries = []
        for sector in directories:
            data = self.sector(sector)
            for offset in range(0, len(data), 128):
                entry = data[offset:offset + 128]
                length, kind, color = struct.unpack_from('<HBB', entry, 64)
                if kind == 0:
                    self.entries.append(None)
                    continue
                require(kind in (1, 2, 5) and color in (0, 1), 'invalid CFB directory object type or color')
                require(2 <= length <= 64 and length % 2 == 0 and entry[length - 2:length] == b'\0\0',
                        'invalid CFB directory name length or terminator')
                name = entry[:length - 2].decode('utf-16le')
                require(name and not any(c in name for c in '\0/\\:!'), 'invalid CFB directory name')
                left, right, child = struct.unpack_from('<3I', entry, 68)
                start, count = struct.unpack_from('<IQ', entry, 116)
                if self.version == 3:
                    # MS-CFB 2.6.3 requires readers to accept old writers that
                    # left the stream-size high DWORD uninitialized.
                    count &= 0xffffffff
                require(kind != 2 or (child == FREE and entry[80:96] == bytes(16)),
                        'CFB stream has a child or storage class')
                require(kind != 1 or (start == 0 and count == 0), 'CFB storage has stream allocation')
                require(self.version != 3 or count <= 0x80000000, 'version 3 CFB stream exceeds 2 GiB')
                self.entries.append((name, kind, left, right, child, start, count,
                                     entry[80:96], directory_key(entry[:length - 2]), color))
        root = self.entries[0]
        require(root is not None and root[0] == 'Root Entry' and root[1] == 5 and root[2:4] == (FREE, FREE),
                'missing or invalid CFB root directory entry')
        require(root[7] == MSI_CLASS, 'CFB root class is not a Windows Installer database')
        self.parents = {0: None}
        stack = [(root[4], 0, None, None, False, True)]
        while stack:
            index, parent, lower, upper, red_parent, tree_root = stack.pop()
            if index == FREE:
                continue
            require(0 < index < len(self.entries) and index not in self.parents,
                    'cyclic, shared or out-of-range CFB directory reference')
            entry = self.entries[index]
            require(entry is not None and entry[1] != 5, 'CFB tree references an unused or second root entry')
            self.parents[index] = parent
            key, red = entry[8], entry[9] == 0
            require((lower is None or lower < key) and (upper is None or key < upper),
                    'duplicate or incorrectly ordered CFB child name')
            require(not red or not (red_parent or tree_root), 'invalid CFB red-black tree color relationship')
            stack.extend(((entry[2], parent, lower, key, red, False),
                          (entry[3], parent, key, upper, red, False)))
            if entry[1] == 1:
                stack.append((entry[4], index, None, None, False, True))
        require(len(self.parents) == sum(e is not None for e in self.entries), 'unreachable CFB directory entry')
        require(mini_count <= self.sectors and mini_count * self.sector_size <= MAX_METADATA,
                'CFB mini FAT exceeds the metadata budget or file size')
        mini_sectors = self.chain(mini_start, 'mini FAT', expected=mini_count)
        self.mini_fat = self.table(mini_sectors)
        require(root[6] % 64 == 0, 'CFB mini-stream size is not aligned')
        self.mini_stream = self.chain(root[5], 'mini-stream', expected=self.count(root[6], self.sector_size))
        self.mini_sectors = root[6] // 64
        require(self.mini_sectors <= len(self.mini_fat), 'CFB mini FAT does not cover the mini-stream')
        self.mini_claimed = bytearray(self.mini_sectors)
        for index, value in enumerate(self.mini_fat):
            require((index < self.mini_sectors and (value in (FREE, END) or value < self.mini_sectors)) or
                    (index >= self.mini_sectors and value == FREE), 'CFB mini FAT contains an out-of-stream reference')
        self.streams = {}
        for index, entry in enumerate(self.entries):
            if entry is not None and entry[1] == 2:
                mini = entry[6] < 4096
                sectors = self.chain(entry[5], 'data stream', expected=self.count(entry[6], 64 if mini else self.sector_size), mini=mini)
                self.streams[index] = (sectors, entry[6], mini)
        require(all(value == FREE or self.claimed[index] for index, value in enumerate(self.fat[:self.sectors])),
                'CFB contains an unowned allocated sector')
        require(all(value == FREE or self.mini_claimed[index] for index, value in enumerate(self.mini_fat[:self.mini_sectors])),
                'CFB contains an unowned allocated mini-sector')

    def read(self, offset, size):
        require(0 <= offset <= self.size and 0 <= size <= self.size - offset,
                'CFB read exceeds the actual file size')
        self.source.seek(offset)
        data = self.source.read(size)
        require(len(data) == size, 'truncated CFB content')
        return data

    def sector(self, index):
        require(0 <= index < self.sectors, 'CFB sector is outside the file')
        return self.read((index + 1) * self.sector_size, self.sector_size)

    def claim(self, index, label):
        require(0 <= index < self.sectors, label + ' sector is outside the CFB file')
        require(not self.claimed[index], 'overlapping or cyclic CFB ' + label + ' allocation')
        self.claimed[index] = 1

    def budget(self, size):
        self.metadata += size
        require(self.metadata <= MAX_METADATA, 'CFB metadata exceeds the 16 MiB budget')

    def table(self, sectors):
        self.budget(len(sectors) * self.sector_size)
        result = array.array('I')
        for sector in sectors:
            result.frombytes(self.sector(sector))
        if sys.byteorder != 'little':
            result.byteswap()
        return result

    @staticmethod
    def count(size, unit):
        return (size + unit - 1) // unit

    def chain(self, start, label, expected=None, maximum=None, mini=False):
        table = self.mini_fat if mini else self.fat
        claimed = self.mini_claimed if mini else self.claimed
        capacity = len(claimed)
        maximum = min(capacity, maximum if maximum is not None else capacity)
        require(expected is None or expected <= maximum, 'CFB ' + label + ' size exceeds available sectors')
        result = array.array('I')
        while start != END:
            require(len(result) < maximum and (expected is None or len(result) < expected),
                    'CFB ' + label + ' chain exceeds its declared size or budget')
            require(0 <= start < capacity and not claimed[start], 'overlapping, cyclic or out-of-range CFB ' + label + ' chain')
            claimed[start] = 1
            result.append(start)
            start = table[start]
        require(expected is None or len(result) == expected, 'truncated CFB ' + label + ' chain')
        return result

    def stream_bytes(self, index):
        sectors, size, mini = self.streams[index]
        require(size <= MAX_METADATA, 'MSI summary information exceeds the 16 MiB budget')
        result = bytearray()
        for sector in sectors:
            if mini:
                offset = sector * 64
                physical = self.mini_stream[offset // self.sector_size]
                result.extend(self.read((physical + 1) * self.sector_size + offset % self.sector_size, 64))
            else:
                result.extend(self.sector(sector))
        return result[:size]

    def validate_msi(self):
        summaries = [i for i in self.streams if self.parents[i] == 0 and self.entries[i][0] == '\x05SummaryInformation']
        require(len(summaries) == 1, 'MSI database lacks its root SummaryInformation stream')
        require(any(self.parents[i] == 0 and i != summaries[0] and self.entries[i][6] > 0 for i in self.streams),
                'MSI database has no database payload streams')
        data = self.stream_bytes(summaries[0])
        require(len(data) >= 56, 'truncated MSI SummaryInformation stream')
        order, version = struct.unpack_from('<HH', data)
        require(order == 0xfffe and version in (0, 1) and struct.unpack_from('<I', data, 24)[0] == 1 and
                data[28:44] == SUMMARY_CLASS, 'invalid MSI SummaryInformation property-set header')
        offset = struct.unpack_from('<I', data, 44)[0]
        require(48 <= offset <= len(data) - 8 and offset % 4 == 0, 'invalid MSI summary property-set offset')
        size, count = struct.unpack_from('<II', data, offset)
        require(0 < count <= (size - 8) // 8 and size <= len(data) - offset,
                'invalid MSI summary property-set length or count')
        ids, properties = set(), []
        for i in range(count):
            prop, position = struct.unpack_from('<II', data, offset + 8 + i * 8)
            require(prop not in ids and (not properties or properties[-1][1] < position) and
                    8 + count * 8 <= position <= size - 4 and position % 4 == 0,
                    'invalid or duplicated MSI summary property reference')
            ids.add(prop)
            properties.append((prop, position))
        values = {}
        for index, (prop, position) in enumerate(properties):
            end = properties[index + 1][1] if index + 1 < count else size
            values[prop] = data[offset + position:offset + end]
        # Unlike generic OLEPS, MSI's documented SummaryInformation contract
        # treats Codepage as optional. Real msibuild databases omit it. An
        # omitted value retains single-byte string representation; no locale
        # decoding is needed for this structural check.
        # https://learn.microsoft.com/en-us/windows/win32/msi/adding-summary-information
        codepage = values.get(1)
        wide = False
        if codepage is not None:
            require(len(codepage) >= 8 and struct.unpack_from('<I', codepage)[0] == 2 and codepage[6:8] == b'\0\0',
                    'invalid MSI summary CodePage property')
            wide = struct.unpack_from('<H', codepage, 4)[0] == 1200
        for value in values.values():
            # The Windows Installer SummaryInfo API uses these four primitive
            # types. Check their complete serialized extent, not only the tag.
            kind = struct.unpack_from('<I', value)[0]
            require(kind in (2, 3, 30, 64), 'unsupported MSI summary property type or nonzero type padding')
            if kind in (2, 3, 64):
                require(len(value) >= (12 if kind == 64 else 8), 'truncated MSI summary numeric property')
                require(kind != 2 or value[6:8] == b'\0\0', 'invalid MSI summary integer padding')
            else:
                require(len(value) >= 8, 'truncated MSI summary string header')
                length = struct.unpack_from('<I', value, 4)[0]
                padded = (length + 3) // 4 * 4
                require(padded <= len(value) - 8 and (not wide or length % 2 == 0),
                        'MSI summary string exceeds its property or has an invalid Unicode length')
                require(length == 0 or (length >= (2 if wide else 1) and
                        value[8 + length - (2 if wide else 1):8 + length] == (b'\0\0' if wide else b'\0')),
                        'MSI summary string lacks its null terminator')
                require(value[8 + length:8 + padded] == bytes(padded - length), 'invalid MSI summary string padding')


try:
    require(3 <= len(sys.argv) <= 5, 'expected format, file and optional SHA256/size')
    kind, path = sys.argv[1:3]
    expected_hash = sys.argv[3] if len(sys.argv) > 3 else None
    expected_size = sys.argv[4] if len(sys.argv) > 4 else None
    require(kind in ('json', 'msi'), 'unsupported content admission format')
    require(expected_hash is None or re.fullmatch('[0-9a-f]{64}', expected_hash), 'expected SHA256 must be lowercase hexadecimal')
    require(expected_size is None or re.fullmatch('[1-9][0-9]{0,15}', expected_size), 'expected size must be a positive decimal integer')
    before = os.stat(path, follow_symlinks=False)
    require(stat.S_ISREG(before.st_mode), 'artifact is not a regular file')
    require(0 < before.st_size <= (MAX_JSON if kind == 'json' else MAX_MSI),
            'artifact is empty or exceeds the ' + ('16 MiB JSON' if kind == 'json' else '8 GiB MSI') + ' size limit')
    require(expected_size is None or int(expected_size) == before.st_size, 'artifact size differs from its receipt')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        require(identity(before) == identity(os.fstat(source.fileno())), 'artifact changed before content admission')
        before_hash = digest(source, before.st_size)
        require(expected_hash is None or before_hash == expected_hash, 'artifact SHA256 differs from its receipt')
        if kind == 'json':
            json_document(source, before.st_size)
        else:
            CompoundDocument(source, before.st_size).validate_msi()
        require(before_hash == digest(source, before.st_size), 'artifact bytes changed during content admission')
        require(identity(before) == identity(os.fstat(source.fileno())) ==
                identity(os.stat(path, follow_symlinks=False)), 'artifact changed during content admission')
except (OSError, ValueError, UnicodeError, OverflowError, RecursionError, MemoryError, struct.error) as error:
    print('[artifact formats] Content admission failed: ' + str(error), file=sys.stderr)
    sys.exit(4)
PY
}

# A successful return binds the content check to the supplied receipt, when
# present. Callers retain their regular-file/path and post-copy hash checks.
artifact_format_validate_json() { _artifact_format_validate json "$@"; }
artifact_format_validate_msi() { _artifact_format_validate msi "$@"; }

export -f _artifact_format_validate artifact_format_validate_json artifact_format_validate_msi
