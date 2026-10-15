#!/usr/bin/env python3
"""Real ELF/Mach-O payloads and production signing admission for issue #45.

Go cross-compiles two programs for all four targets. This proves byte custody,
not execution on macOS/ARM hosts. Minisign tests use the real executable or skip
explicitly; namespace/checksum and public refusal tests need no signing key.
"""
from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import struct
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / 'src/signing.sh'
BASH = os.environ.get('DSR_TEST_BASH', 'bash')
PLATFORMS = ('linux/amd64', 'linux/arm64', 'darwin/amd64', 'darwin/arm64')
TRIPLES = ('x86_64-unknown-linux-gnu', 'aarch64-unknown-linux-gnu',
           'x86_64-apple-darwin', 'aarch64-apple-darwin')


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SigningInventory(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        for tool in ('go', 'bash', 'jq', 'find', 'cmp', 'wc'):
            if not shutil.which(tool):
                raise unittest.SkipTest(f'{tool} is required; no fake compiler/signer')
        version = subprocess.run([BASH, '-c', '(( BASH_VERSINFO[0] >= 4 ))'],
                                 capture_output=True, timeout=5)
        if version.returncode != 0:
            raise unittest.SkipTest('Bash 4+ is required (use the repository shell wrapper)')
        cls.compiled = tempfile.TemporaryDirectory(prefix='dsr-signing-compiled-')
        cls.addClassCleanup(cls.compiled.cleanup)
        cls.fixtures = Path(cls.compiled.name)
        for binary in ('sbh', 'helper'):
            source = cls.fixtures / f'{binary}.go'
            source.write_text(f'package main\nfunc main() {{ println("{binary} fixture") }}\n')
            for platform in PLATFORMS:
                goos, goarch = platform.split('/')
                output = cls.fixtures / f'{binary}_{goos}_{goarch}'
                env = dict(os.environ, GOOS=goos, GOARCH=goarch, CGO_ENABLED='0',
                           GO111MODULE='off', GOTOOLCHAIN='local')
                subprocess.run(['go', 'build', '-trimpath', '-ldflags=-s -w',
                                '-o', str(output), str(source)], env=env,
                               check=True, capture_output=True, timeout=180)
                expected_magic = b'\x7fELF' if goos == 'linux' else b'\xcf\xfa\xed\xfe'
                if output.read_bytes()[:4] != expected_magic:
                    raise AssertionError(f'compiler did not emit expected format: {output}')
                header = output.read_bytes()[:32]
                if goos == 'linux':
                    machine = struct.unpack_from('<H', header, 18)[0]
                    expected = 62 if goarch == 'amd64' else 183
                else:
                    machine = struct.unpack_from('<I', header, 4)[0]
                    expected = 0x01000007 if goarch == 'amd64' else 0x0100000C
                if machine != expected:
                    raise AssertionError(f'compiler emitted the wrong machine type: {output}')

    def setUp(self) -> None:
        self.work = tempfile.TemporaryDirectory(prefix='dsr-signing-inventory-')
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.output = self.root / 'release'
        self.output.mkdir()
        self.manifest = self.output / 'sbh-v0.7.5-manifest.json'
        self.rows = []
        for platform, triple in zip(PLATFORMS, TRIPLES):
            suffix = platform.replace('/', '_')
            for binary in ('sbh', 'helper'):
                path = self.output / f'{binary}_{suffix}'
                shutil.copy2(self.fixtures / path.name, path)
                self.add_row(path, platform, triple, 'none')
            # Preserve two identically named archive members per target.
            extension = 'zip' if platform.startswith('darwin') else 'tar.gz'
            archive = self.output / f'bundle_{suffix}.{extension}'
            if extension == 'zip':
                with zipfile.ZipFile(archive, 'w') as zf:
                    for binary in ('sbh', 'helper'):
                        zf.write(self.output / f'{binary}_{suffix}', binary)
            else:
                with tarfile.open(archive, 'w:gz') as tf:
                    for binary in ('sbh', 'helper'):
                        tf.add(self.output / f'{binary}_{suffix}', arcname=binary)
            self.add_row(archive, platform, triple, extension)
        self.write_manifest()
        self.write_checksums()

    def add_row(self, path: Path, target: str, triple: str, fmt: str) -> None:
        self.rows.append(dict(name=path.name, target=target, target_triple=triple,
                              archive_format=fmt, sha256=digest(path),
                              size_bytes=path.stat().st_size))

    def write_manifest(self) -> None:
        self.manifest.write_text(json.dumps(dict(
            schema_version='1.0.0', tool='sbh', version='v0.7.5',
            status='success', build_purpose='release', publishable=True,
            summary=dict(total=4, success=4, failed=0), artifacts=self.rows)) + '\n')

    def write_checksums(self) -> None:
        self.sums = self.output / 'SHA256SUMS'
        self.sums.write_text(''.join(f'{r["sha256"]}  {r["name"]}\n'
                                    for r in sorted(self.rows, key=lambda r: r['name'])))
        for row in self.rows:
            (self.output / (row['name'] + '.sha256')).write_text(
                f'{row["sha256"]}  {row["name"]}\n')

    def call(self, function: str, *args: object) -> subprocess.CompletedProcess:
        # Function and module are trusted test constants; paths are argv data.
        return subprocess.run([BASH, '-c', 'source "$1"; shift; "$@"',
                               '_', str(MODULE), function, *map(str, args)],
                              text=True, capture_output=True, timeout=30)

    def admitted(self) -> None:
        result = self.call('_signing_release_preflight', self.output / 'sbh_linux_amd64')
        self.assertEqual(result.returncode, 0, result.stderr)

    def refused(self, message: str = '') -> None:
        result = self.call('_signing_release_preflight', self.output / 'sbh_linux_amd64')
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn(message, result.stderr)

    def test_all_final_names_hashes_targets_archives_and_checksums(self) -> None:
        self.admitted()
        signed_rows = json.loads(self.manifest.read_bytes())['artifacts']
        manifest_inventory = {r['name']: r['sha256'] for r in signed_rows}
        checksum_inventory = dict((line[66:], line[:64])
                                  for line in self.sums.read_text().splitlines())
        actual = {r['name']: digest(self.output / r['name']) for r in self.rows}
        self.assertEqual(actual, manifest_inventory)
        self.assertEqual(actual, checksum_inventory)
        self.assertEqual(len(actual), 12)
        self.assertEqual({r['target'] for r in signed_rows}, set(PLATFORMS))
        self.assertEqual({r['target_triple'] for r in signed_rows}, set(TRIPLES))
        for row in self.rows:
            if row['archive_format'] == 'none':
                continue
            data = (self.output / row['name']).read_bytes()
            if row['archive_format'] == 'zip':
                with zipfile.ZipFile(io.BytesIO(data)) as zf:
                    members = {n: zf.read(n) for n in zf.namelist()}
            else:
                with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as tf:
                    members = {m.name: tf.extractfile(m).read() for m in tf.getmembers()}
            self.assertEqual(set(members), {'sbh', 'helper'})
            for name, payload in members.items():
                self.assertEqual(payload, (self.output / f'{name}_{row["target"].replace("/", "_")}').read_bytes())

    def test_missing_arm64_rows_even_when_checksums_drop_them(self) -> None:
        self.rows = [r for r in self.rows if not (r['name'].startswith('sbh_') and 'arm64' in r['name'])]
        self.write_manifest()
        self.write_checksums()
        self.refused('absent from manifest')

    def test_misnamed_linux_amd64(self) -> None:
        self.rows[0]['name'] = 'sbh'
        self.write_manifest()
        self.refused('missing or linked')

    def test_unlisted_raw_alias(self) -> None:
        shutil.copy2(self.output / 'sbh_linux_arm64', self.output / 'sbh_linux_aarch64')
        self.refused('absent from manifest')

    def test_unlisted_archive(self) -> None:
        shutil.copy2(self.output / 'bundle_darwin_arm64.zip', self.output / 'extra.zip')
        self.refused('absent from manifest')

    def test_duplicate_published_names_even_with_identical_bytes(self) -> None:
        self.rows.append(dict(self.rows[0]))
        self.write_manifest()
        self.refused('Invalid release manifest')

    def test_case_insensitive_duplicate_names(self) -> None:
        self.rows.append(dict(self.rows[0], name=self.rows[0]['name'].upper()))
        self.write_manifest()
        self.refused('Invalid release manifest')

    def test_missing_artifact(self) -> None:
        (self.output / 'helper_darwin_arm64').unlink()
        self.refused('missing or linked')

    def test_changed_raw_bytes(self) -> None:
        (self.output / 'sbh_linux_arm64').write_bytes(b'changed')
        self.refused('checksum mismatch')

    def test_wrong_size(self) -> None:
        self.rows[0]['size_bytes'] += 1
        self.write_manifest()
        self.refused('size mismatch')

    def test_payload_symlink(self) -> None:
        path = self.output / 'sbh_linux_arm64'
        path.unlink()
        path.symlink_to(self.fixtures / path.name)
        self.refused('missing or linked')

    def test_checksum_omission(self) -> None:
        self.sums.write_text('\n'.join(self.sums.read_text().splitlines()[1:]) + '\n')
        self.refused('omits manifest artifacts')

    def test_checksum_mismatch(self) -> None:
        content = self.sums.read_text()
        self.sums.write_text('0' * 64 + content[64:])
        self.refused('SHA256SUMS disagrees')

    def test_duplicate_checksum_entry(self) -> None:
        content = self.sums.read_text()
        self.sums.write_text(content + content.splitlines()[0] + '\n')
        self.refused('SHA256SUMS disagrees')

    def test_unmanifested_checksum_alias(self) -> None:
        self.sums.write_text(self.sums.read_text() + f'{self.rows[0]["sha256"]}  unsigned_alias\n')
        self.refused('SHA256SUMS disagrees')

    def test_bad_per_asset_checksum(self) -> None:
        (self.output / (self.rows[0]['name'] + '.sha256')).write_text('stale\n')
        self.refused('Per-asset checksum disagrees')

    def test_gnu_binary_checksum_format(self) -> None:
        self.sums.write_text(self.sums.read_text().replace('  ', ' *'))
        self.admitted()

    def test_unsafe_manifest_path(self) -> None:
        self.rows[0]['name'] = '../escape'
        self.write_manifest()
        self.refused('Invalid release manifest')

    def test_concatenated_json_is_not_one_manifest(self) -> None:
        self.manifest.write_text(self.manifest.read_text() + self.manifest.read_text())
        self.refused('Invalid release manifest')

    def test_failed_manifest_is_not_signed(self) -> None:
        body = json.loads(self.manifest.read_text())
        body['status'] = 'failed'
        self.manifest.write_text(json.dumps(body))
        self.refused('Invalid release manifest')

    def test_direct_and_batch_admission_before_key_use(self) -> None:
        (self.output / 'helper_darwin_arm64').unlink()
        unrelated = self.root / 'unrelated.bin'
        unrelated.write_bytes(b'not a release payload')
        for function, args in (
            ('signing_sign', [self.manifest]),
            ('signing_sign_batch', [unrelated, self.output / 'sbh_linux_amd64']),
            ('signing_sign_exact', [self.manifest, str(self.manifest) + '.minisig',
                                    self.root / 'no-private-key', 'A' * 44, 'fixture']),
        ):
            with self.subTest(function=function):
                result = self.call(function, *args)
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertIn('missing or linked', result.stderr)
                self.assertFalse(list(self.root.rglob('*.minisig')))

    def test_retained_signature_is_not_rewritten_on_inventory_failure(self) -> None:
        signature = Path(str(self.manifest) + '.minisig')
        signature.write_bytes(b'retained evidence must not be overwritten')
        before = signature.read_bytes()
        self.sums.write_text('')
        result = self.call('signing_sign', self.manifest)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(signature.read_bytes(), before)

    def test_generic_signing_without_release_manifest_is_unchanged(self) -> None:
        unrelated = self.root / 'document.txt'
        unrelated.write_text('ordinary arbitrary signing input')
        result = self.call('_signing_release_preflight', unrelated)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_checksum_generation_can_follow_payload_signing(self) -> None:
        self.sums.unlink()
        self.admitted()

    def test_integrity_metadata_and_private_staging_are_not_payloads(self) -> None:
        for name in ('.dsr-build-purpose.json', 'bundle.sbom.spdx.json',
                     'bundle.intoto.jsonl', 'SHA256SUMS.minisig'):
            (self.output / name).write_text('separate evidence fixture\n')
        staging = self.output / '.sbh.dsr-batch.fixture'
        staging.mkdir()
        (staging / 'signature').write_text('private staged bytes')
        self.admitted()

    def test_shell_glob_options_cannot_hide_release_manifest(self) -> None:
        (self.output / 'helper_darwin_arm64').unlink()
        result = subprocess.run([BASH, '-c',
            'source "$1"; GLOBIGNORE="*"; set -f; shopt -s failglob; '
            '_signing_release_preflight "$2"', '_', str(MODULE),
            str(self.output / 'sbh_linux_amd64')], text=True,
            capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn('missing or linked', result.stderr)

    def test_checksum_symlink_is_not_followed(self) -> None:
        retained = self.root / 'retained-checksums'
        self.sums.rename(retained)
        self.sums.symlink_to(retained)
        self.refused()

    def test_checksum_without_final_newline(self) -> None:
        self.sums.write_text(self.sums.read_text().rstrip('\n'))
        self.admitted()

    @unittest.skipUnless(shutil.which('minisign'), 'real Minisign executable is unavailable')
    def test_real_minisign_complete_manifest_and_payload_only_batch(self) -> None:
        key, public = self.root / 'key', self.root / 'key.pub'
        subprocess.run(['minisign', '-G', '-W', '-s', str(key), '-p', str(public)],
                       check=True, capture_output=True, timeout=30)
        env = dict(os.environ, DSR_CONFIG_DIR=str(self.root), DSR_MINISIGN_KEY=str(key))
        shutil.copy2(public, self.root / 'minisign.pub')
        inputs = [self.output / r['name'] for r in self.rows] + [self.manifest]
        command = [BASH, '-c', 'source "$1"; shift; signing_sign_batch "$@"',
                   '_', str(MODULE), *map(str, inputs)]
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        before = {p.name: digest(p) for p in self.output.glob('*.minisig')}
        self.assertEqual(len(before), len(inputs))
        for path in inputs:
            subprocess.run(['minisign', '-V', '-H', '-q', '-p', str(public), '-m', str(path)],
                           check=True, capture_output=True, timeout=30)
        # Byte-identical resume, not re-signing with different comments/times.
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, {p.name: digest(p) for p in self.output.glob('*.minisig')})
        self.admitted()


    @unittest.skipUnless(shutil.which('minisign'), 'real Minisign executable is unavailable')
    def test_real_signer_cannot_publish_manifest_after_payload_mutation(self) -> None:
        key, public = self.root / 'key', self.root / 'key.pub'
        subprocess.run(['minisign', '-G', '-W', '-s', str(key), '-p', str(public)],
                       check=True, capture_output=True, timeout=30)
        # This boundary fault still invokes the genuine Minisign executable.
        # Only an adjacent payload (not the signed JSON) changes after signing.
        script = r'''source "$1"
minisign() {
    command minisign "$@" || return $?
    if [[ "${1:-}" == -S ]]; then printf changed > "$VICTIM"; fi
}
signing_sign_exact "$2" "$2.minisig" "$3" "$(signing_public_key_token "$4")" fixture
'''
        result = subprocess.run([BASH, '-c', script, '_', str(MODULE),
                                 str(self.manifest), str(key), str(public)],
                                env=dict(os.environ, VICTIM=str(self.output / 'sbh_darwin_arm64')),
                                text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn('inventory changed', result.stderr)
        self.assertFalse(list(self.output.glob('*.minisig')))

    @unittest.skipUnless(shutil.which('minisign'), 'real Minisign executable is unavailable')
    def test_real_payload_only_batch_rechecks_unlisted_late_arrival(self) -> None:
        key, public = self.root / 'key', self.root / 'minisign.pub'
        subprocess.run(['minisign', '-G', '-W', '-s', str(key), '-p', str(public)],
                       check=True, capture_output=True, timeout=30)
        script = r'''source "$1"
minisign() {
    command minisign "$@" || return $?
    if [[ "${1:-}" == -S ]]; then printf unlisted > "$LATE_PAYLOAD"; fi
}
signing_sign_batch "$2"
'''
        result = subprocess.run([BASH, '-c', script, '_', str(MODULE),
                                 str(self.output / 'sbh_linux_amd64')],
                                env=dict(os.environ, DSR_CONFIG_DIR=str(self.root),
                                         DSR_MINISIGN_KEY=str(key),
                                         LATE_PAYLOAD=str(self.output / 'unlisted_arm64')),
                                text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn('absent from manifest', result.stderr)
        self.assertFalse(list(self.output.glob('*.minisig')))


if __name__ == '__main__':
    unittest.main(verbosity=2)
