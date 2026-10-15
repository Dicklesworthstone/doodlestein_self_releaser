#!/usr/bin/env python3
"""Ordinary publication admission/checksum/caller-block integration.

The checksum writer and inventory validator are production functions. The two
handoff blocks are extracted from dsr; compiler scheduling and GitHub transport
are outside this test. A failing signer boundary records the attempted inputs;
it never fakes successful cryptography. Minisign checks run only when installed.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(os.environ.get('DSR_TEST_SOURCE_ROOT', Path(__file__).resolve().parents[2]))
BASH = os.environ.get('DSR_TEST_BASH', 'bash')
PLATFORMS = ('linux/amd64', 'linux/arm64', 'darwin/amd64', 'darwin/arm64')


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PublicationInventory(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for tool in (BASH, 'jq', 'go'):
            if not shutil.which(tool):
                raise unittest.SkipTest(f'requires {tool}')
        cls.fixture = tempfile.TemporaryDirectory(prefix='dsr-publication-compiler-')
        cls.addClassCleanup(cls.fixture.cleanup)
        cls.build = Path(cls.fixture.name)
        for program in ('sbh', 'helper'):
            source = cls.build / f'{program}.go'
            source.write_text(f'package main\nfunc main() {{ println("{program}") }}\n')
            for target in PLATFORMS:
                goos, goarch = target.split('/')
                subprocess.run(['go', 'build', '-trimpath', '-ldflags=-s -w', '-o',
                                str(cls.build / f'{program}_{goos}_{goarch}'), str(source)],
                               env=dict(os.environ, GOOS=goos, GOARCH=goarch,
                                        CGO_ENABLED='0', GO111MODULE='off', GOTOOLCHAIN='local'),
                               check=True, capture_output=True, timeout=180)
        cls.command_source = (ROOT / 'dsr').read_text()
        start = cls.command_source.index('_release_prepare_ordinary_checksums() (')
        end = cls.command_source.index('\n)\n', start) + 3
        cls.checksum_helper = cls.command_source[start:end]
        start = cls.command_source.index('        ordinary_expected_sha["${manifest_file##*/}"]=')
        end = cls.command_source.index('    elif ! $release_contract_enabled; then', start)
        cls.admission = cls.command_source[start:end]
        start = cls.command_source.index('    # Ordinary inventory admission is independent of signing and resume.')
        end = cls.command_source.index('    # Quality/signing commands may mutate', start)
        cls.fallback = cls.command_source[start:end]
        end = cls.command_source.index('    log_info "Creating GitHub release for $tag..."')
        start = cls.command_source.rfind('    if ! $release_contract_enabled && $manifest_exists;', 0, end)
        if start < 0:
            raise AssertionError('missing ordinary pre-create checksum admission')
        cls.create = cls.command_source[start:end]

    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='dsr-publication-inventory-')
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.out = self.root / 'assets'
        self.out.mkdir()
        self.manifest = self.out / 'sbh-v1.2.3-manifest.json'
        self.rows = []
        for target in PLATFORMS:
            suffix = target.replace('/', '_')
            for program in ('sbh', 'helper'):
                path = self.out / f'{program}_{suffix}'
                shutil.copy2(self.build / path.name, path)
                self.row(path, target, 'none')
            path = self.out / f'bundle_{suffix}.tar.gz'
            with tarfile.open(path, 'w:gz') as archive:
                for program in ('sbh', 'helper'):
                    archive.add(self.out / f'{program}_{suffix}', arcname=program)
            self.row(path, target, 'tar.gz')
        self.save()
        self.expected = sha(self.manifest)
        self.sums = self.out / 'SHA256SUMS'

    def row(self, path, target, fmt):
        self.rows.append(dict(name=path.name, target=target, archive_format=fmt,
                              sha256=sha(path), size_bytes=path.stat().st_size))

    def save(self):
        self.manifest.write_text(json.dumps(dict(tool='sbh', version='v1.2.3',
            status='success', build_purpose='release', publishable=True,
            summary=dict(total=4, success=4, failed=0), artifacts=self.rows)) + '\n')

    def call(self, body, expected=0, extra='', env=None):
        script = '''set -uo pipefail
log_error() { printf '%s\\n' "$*" >&2; }
log_warn() { log_error "$@"; }
log_info() { :; }
log_ok() { :; }
_sign_log_error() { log_error "$@"; }
source "$1/src/signing.sh" || exit
''' + self.checksum_helper + '''
manifest_file="$2"; artifacts_dir="$3"; output_dir="$3"; manifest_sha="$4"
''' + extra + '\n_test() {\n' + body + '\n}\n_test\n'
        result = subprocess.run([BASH, '-c', script, '_', str(ROOT), str(self.manifest),
                                 str(self.out), self.expected], text=True, capture_output=True,
                                timeout=45, env=env)
        self.assertEqual(result.returncode, expected, result.stderr)
        return result

    def prepare(self, expected=0, extra=''):
        return self.call('_release_prepare_ordinary_checksums "$manifest_file" "$artifacts_dir" "$manifest_sha"',
                         expected=expected, extra=extra)

    def validate(self, expected=0):
        return self.call('signing_validate_release_inventory "$manifest_file" "$artifacts_dir" "$manifest_sha"', expected)

    def inventory(self):
        return {r['name']: r['sha256'] for r in self.rows}

    def assert_checksums(self):
        observed = {line[66:]: line[:64] for line in self.sums.read_text().splitlines()}
        self.assertEqual(observed, self.inventory())
        for name, digest in observed.items():
            self.assertEqual(sha(self.out / name), digest)
            self.assertEqual((self.out / (name + '.sha256')).read_text(), f'{digest}  {name}\n')

    def test_new_complete_checksums_cover_eight_raws_and_four_archives(self):
        self.prepare()
        self.assert_checksums()
        self.assertEqual(len(self.inventory()), 12)

    def test_retry_preserves_bytes_inodes_and_does_not_add_staging(self):
        self.prepare()
        paths = [self.sums, *(self.out / (r['name']+'.sha256') for r in self.rows)]
        before = [(p.read_bytes(), p.stat().st_ino) for p in paths]
        staging = set(self.out.iterdir())
        self.prepare()
        self.assertEqual(before, [(p.read_bytes(), p.stat().st_ino) for p in paths])
        self.assertEqual(staging, set(self.out.iterdir()))

    def test_signed_gnu_binary_order_and_missing_newline_preserved(self):
        content = '\n'.join(f'{r["sha256"]} *{r["name"]}' for r in reversed(self.rows))
        self.sums.write_text(content)
        evidence = self.out / 'SHA256SUMS.minisig'
        evidence.write_bytes(b'opaque retained sidecar; not asserted cryptographically valid')
        before = self.sums.stat().st_ino
        self.prepare()
        self.assertEqual(self.sums.read_text(), content)
        self.assertEqual(self.sums.stat().st_ino, before)
        self.assertEqual(evidence.read_bytes(), b'opaque retained sidecar; not asserted cryptographically valid')

    def test_missing_artifact_refuses_without_any_checksum_publication(self):
        (self.out / 'sbh_darwin_arm64').rename(self.root / 'held')
        self.prepare(4)
        self.assertFalse(self.sums.exists())

    def test_omitted_arm64_row_refuses_direct_admission_with_or_without_signing(self):
        self.rows = [r for r in self.rows if r['name'] != 'sbh_darwin_arm64']
        self.save(); self.expected = sha(self.manifest)
        extra = '_gh_asset_sha256() { _signing_sha256 "$1"; }; declare -A ordinary_expected_sha=()'
        for signing in ('true', 'false'):
            self.call(self.admission, 4, extra=extra,
                      env=dict(os.environ, DSR_SIGNING_ENABLED=signing))
        self.assertFalse(self.sums.exists())

    def test_direct_admission_accepts_complete_inventory(self):
        extra = '_gh_asset_sha256() { _signing_sha256 "$1"; }; declare -A ordinary_expected_sha=()'
        self.call(self.admission, extra=extra)

    def test_precreate_freezes_every_generated_checksum_hash(self):
        extra = '''release_contract_enabled=false; manifest_exists=true
_gh_asset_sha256() { _signing_sha256 "$1"; }
declare -A ordinary_expected_sha=() ordinary_generated_names=([SHA256SUMS]=1)
ordinary_expected_sha["${manifest_file##*/}"]="$manifest_sha"
while IFS= read -r name; do ordinary_generated_names["$name.sha256"]=1; done < <(jq -r '.artifacts[].name' "$manifest_file")'''
        result = self.call(self.create + '''
for name in "${!ordinary_expected_sha[@]}"; do
    printf '%s\\t%s\\n' "$name" "${ordinary_expected_sha[$name]}"
done''', extra=extra)
        frozen = dict(line.split('\t') for line in result.stdout.splitlines())
        expected = {self.manifest.name, 'SHA256SUMS', *(r['name']+'.sha256' for r in self.rows)}
        self.assertEqual(set(frozen), expected)
        self.assertEqual(frozen, {name: sha(self.out / name) for name in expected})

    def test_precreate_refuses_checksum_orphan_without_exposing_outputs(self):
        (self.out / 'SHA256SUMS.minisig').write_text('orphan evidence')
        extra = '''release_contract_enabled=false; manifest_exists=true
_gh_asset_sha256() { _signing_sha256 "$1"; }
declare -A ordinary_expected_sha=() ordinary_generated_names=([SHA256SUMS]=1)
ordinary_expected_sha["${manifest_file##*/}"]="$manifest_sha"'''
        self.call(self.create, 4, extra=extra)
        self.assertFalse(self.sums.exists())

    def test_changed_bytes_refuse(self):
        (self.out / 'sbh_linux_arm64').write_bytes(b'changed')
        self.prepare(4)
        self.assertFalse(self.sums.exists())

    def test_changed_manifest_cannot_be_reselected(self):
        self.rows[0]['target'] = 'darwin/arm64'
        self.save()
        self.prepare(4)
        self.assertFalse(self.sums.exists())

    def test_unlisted_raw_alias_refuses(self):
        shutil.copy2(self.out / 'sbh_linux_arm64', self.out / 'sbh_linux_aarch64')
        self.prepare(4)

    def test_unlisted_archive_refuses(self):
        shutil.copy2(self.out / 'bundle_linux_arm64.tar.gz', self.out / 'extra.tar.gz')
        self.prepare(4)

    def test_corrupt_aggregate_is_not_overwritten(self):
        self.sums.write_bytes(b'stale or tampered evidence\n')
        self.prepare(4)
        self.assertEqual(self.sums.read_bytes(), b'stale or tampered evidence\n')

    def test_wrong_per_asset_checksum_is_not_overwritten(self):
        path = self.out / (self.rows[0]['name'] + '.sha256')
        path.write_bytes(b'wrong checksum\n')
        self.prepare(4)
        self.assertEqual(path.read_bytes(), b'wrong checksum\n')
        self.assertFalse(self.sums.exists())

    def test_orphan_aggregate_signature_refuses_before_outputs(self):
        for suffix in ('minisig', 'sig', 'asc'):
            with self.subTest(suffix=suffix):
                path = self.out / ('SHA256SUMS.' + suffix)
                path.write_text('retained signature')
                self.prepare(4)
                self.assertFalse(self.sums.exists())
                path.rename(self.root / suffix)

    def test_orphan_per_asset_signature_refuses_before_outputs(self):
        path = self.out / (self.rows[-1]['name'] + '.sha256.minisig')
        path.write_text('retained signature')
        self.prepare(4)
        self.assertFalse(self.sums.exists())
        self.assertFalse(list(self.out.glob('*.sha256')))

    def test_checksum_symlink_does_not_overwrite_outside_file(self):
        outside = self.root / 'outside'
        outside.write_text('keep me')
        self.sums.symlink_to(outside)
        self.prepare(4)
        self.assertEqual(outside.read_text(), 'keep me')

    def test_duplicate_payload_names_refuse(self):
        self.rows.append(dict(self.rows[0]))
        self.save(); self.expected = sha(self.manifest)
        self.prepare(4)

    def test_case_collision_refuses(self):
        path = self.out / self.rows[0]['name'].upper()
        shutil.copy2(self.out / self.rows[0]['name'], path)
        self.rows.append(dict(self.rows[0], name=path.name))
        self.save(); self.expected = sha(self.manifest)
        self.prepare(4)

    def test_explicit_manifest_in_separate_directory(self):
        relocated = self.root / 'inventory.json'
        self.manifest.rename(relocated)
        self.manifest = relocated
        self.prepare()
        self.assert_checksums()

    def test_explicit_nonstandard_manifest_in_asset_directory(self):
        renamed = self.out / 'inventory.json'
        self.manifest.rename(renamed)
        self.manifest = renamed
        self.prepare()
        self.assert_checksums()

    def test_nonstandard_manifest_cannot_bypass_validation(self):
        renamed = self.root / 'inventory.json'
        self.manifest.rename(renamed); self.manifest = renamed
        (self.out / 'helper_darwin_arm64').rename(self.root / 'held')
        self.prepare(4)

    def test_missing_explicit_directory_refuses(self):
        self.call('signing_validate_release_inventory "$manifest_file" "$artifacts_dir/missing"', 4)

    def test_partial_prior_generation_is_resumable(self):
        self.prepare()
        victim = self.out / (self.rows[0]['name']+'.sha256')
        old = victim.read_bytes()
        victim.rename(self.root / 'retained-one-checksum')
        self.prepare()
        self.assertEqual(victim.read_bytes(), old)
        self.assert_checksums()

    def test_link_failure_cannot_truncate_existing_evidence(self):
        content = ''.join(f'{r["sha256"]}  {r["name"]}\n' for r in reversed(self.rows))
        self.sums.write_text(content)
        self.prepare(4, extra='ln() { printf "INJECTED_LINK_FAILURE\\n" >&2; return 1; }')
        self.assertEqual(self.sums.read_text(), content)
        self.assertFalse(list(self.out.glob('*.sha256')))

    def test_competing_creation_is_not_clobbered(self):
        extra = '''ln() {
    local destination="${!#}"
    printf competitor > "$destination"
    command ln "$@"
}'''
        result = self.prepare(4, extra=extra)
        self.assertIn('publication conflict', result.stderr)
        self.assertEqual(self.sums.read_bytes(), b'competitor')

    def test_successful_link_then_mutation_is_not_success(self):
        extra = '''ln() { command ln "$@" || return; printf changed > "$artifacts_dir/sbh_linux_arm64"; }'''
        self.prepare(4, extra=extra)

    def test_unsigned_fallback_cannot_skip_missing_inventory_rows(self):
        self.rows = [r for r in self.rows if r['name'] != 'sbh_linux_arm64']
        self.save(); self.expected = sha(self.manifest)
        extra = '''contract=null; rc=0; signing_wanted() { return 1; }
signing_is_enabled() { return 1; }
_fallback_result() { printf '%s\\n' "$*" >&2; }
payload_paths=("$artifacts_dir/sbh_linux_amd64")'''
        result = self.call(self.fallback, 6, extra=extra)
        self.assertIn('incomplete or inconsistent', result.stderr)

    def test_fallback_reused_signatures_still_invoke_batch_and_include_manifest(self):
        extra = '''contract=null; rc=0
signing_wanted() { return 0; }; signing_is_enabled() { return 0; }
_fallback_result() { printf '%s\\n' "$*" >&2; }
signing_sign_batch() { printf '%s\\n' "$@" > "$output_dir/.dsr-observed-inputs.json"; return 42; }
payload_paths=("$artifacts_dir/sbh_linux_amd64" "$artifacts_dir/helper_linux_amd64")
for payload in "${payload_paths[@]}" "$manifest_file"; do printf retained > "$payload.minisig"; done'''
        self.call(self.fallback, 7, extra=extra)
        attempted = (self.out / '.dsr-observed-inputs.json').read_text().splitlines()
        self.assertEqual(attempted, [str(self.out / 'sbh_linux_amd64'),
                                    str(self.out / 'helper_linux_amd64'), str(self.manifest)])

    def test_unsigned_complete_fallback_passes_without_key_use(self):
        extra = '''contract=null; rc=0; signing_wanted() { return 1; }
signing_is_enabled() { return 1; }; _fallback_result() { return 1; }
payload_paths=()'''
        self.call(self.fallback, extra=extra)

    @unittest.skipUnless(shutil.which('minisign'), 'real Minisign is unavailable')
    def test_real_retained_signature_survives_checksum_preparation(self):
        self.sums.write_text('\n'.join(f'{r["sha256"]} *{r["name"]}' for r in reversed(self.rows)))
        key, public = self.root / 'key', self.root / 'key.pub'
        subprocess.run(['minisign', '-G', '-W', '-s', str(key), '-p', str(public)],
                       check=True, capture_output=True)
        subprocess.run(['minisign', '-S', '-s', str(key), '-m', str(self.sums)],
                       check=True, capture_output=True)
        signature = Path(str(self.sums)+'.minisig')
        before = signature.read_bytes()
        self.prepare()
        subprocess.run(['minisign', '-V', '-H', '-q', '-p', str(public), '-m', str(self.sums)],
                       check=True, capture_output=True)
        self.assertEqual(signature.read_bytes(), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
