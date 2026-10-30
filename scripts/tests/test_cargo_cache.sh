#!/usr/bin/env bash
# Real filesystem and Git-cache regressions; optional genuine offline Cargo.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
command -v python3 >/dev/null || { printf 'SKIP cargo cache: requires Python 3.9+\n' >&2; exit 0; }
python3 -I - "$ROOT/src/cargo_cache.sh" "$@" <<'PY'
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tarfile
import unittest
from unittest.mock import patch

MODULE = os.environ.get('DSR_TEST_CARGO_CACHE_MODULE', sys.argv.pop(1))


class PrivateCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dsr-cargo-cache-test.')
        self.addCleanup(self.temporary.cleanup)
        # Darwin's temporary directory may start with the /var symlink.
        # Selection inputs require physical ancestors; individual tests still
        # create their own rejected links below this canonical fixture root.
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'ambient cargo'
        self.home = self.root / 'private cargo'
        self.source.mkdir()
        # Keep these custody tests on a selected source-only package. The
        # distinct archive-backed cases below exercise deliberate omission.
        self.crate = self.source / 'registry/src/example/source-only-1.0.0/src/lib.rs'
        self.crate.parent.mkdir(parents=True)
        self.crate.write_bytes(b'pub fn answer() -> u32 { 42 }\n')
        self.archive = self.source / 'registry/cache/example/probe-1.0.0.crate'
        self.archive.parent.mkdir(parents=True)
        self.archive.write_bytes(b'cached archive\x00\xff\n')
        # Exercise copied bytes/modes inside the selected database store.
        # Materialized Git working copies are now deliberately omitted.
        self.script = self.source / 'git/db/probe/hooks/build.sh'
        self.script.parent.mkdir(parents=True)
        self.script.write_text('#!/bin/sh\nexit 0\n')
        self.script.chmod(0o751)
        (self.source / 'registry/index/empty').mkdir(parents=True)
        (self.source / 'config.toml').write_text('[build]\nrustc-wrapper="untrusted"\n')
        (self.source / 'credentials.toml').write_text('DO-NOT-COPY\n')
        (self.source / 'bin').mkdir()
        (self.source / 'bin/cargo').write_text('DO-NOT-COPY\n')

    def invoke(self, operation, first, second, expected=0):
        result = subprocess.run(['bash', MODULE, operation, str(first), str(second)],
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stderr)
        if expected:
            self.assertEqual(result.stdout, '', result.stdout)
            self.assertIn('[cargo-cache]', result.stderr)
            return None
        self.assertEqual(result.stderr, '')
        return json.loads(result.stdout)

    def snapshot(self):
        return self.invoke('snapshot', self.source, self.home)

    def copied(self, source):
        return self.home / source.relative_to(self.source)

    def checkout_link(self, target):
        self.snapshot()
        checkout = self.home / 'git/checkouts/license-fixture/abcdef0'
        (checkout / 'crate').mkdir(parents=True)
        (checkout / 'LICENSE').write_text('reviewed license\n')
        (checkout / 'crate/LICENSE').symlink_to(target)
        return checkout

    def test_final_inventory_binds_internal_checkout_file_link(self):
        self.checkout_link('../LICENSE')
        receipt = self.root / 'final-links.json'
        self.invoke('inventory', self.home, receipt)
        entry = next(row for row in json.loads(receipt.read_text())['inventory']['files']
                     if row['path'].endswith('/crate/LICENSE'))
        self.assertTrue(entry['symlink'])
        self.assertEqual(entry['sha256'], hashlib.sha256(b'../LICENSE').hexdigest())
        self.invoke('verify', self.home, receipt)

    def test_final_inventory_refuses_checkout_link_escape(self):
        self.checkout_link('../../../../../config.toml')
        self.invoke('inventory', self.home, self.root / 'final.json', expected=7)

    def test_final_inventory_refuses_checkout_directory_link(self):
        self.checkout_link('..')
        self.invoke('inventory', self.home, self.root / 'final.json', expected=7)

    def test_final_inventory_refuses_checkout_absolute_link(self):
        self.checkout_link(str(self.home / 'git/checkouts/license-fixture/abcdef0/LICENSE'))
        self.invoke('inventory', self.home, self.root / 'final.json', expected=7)

    def test_final_inventory_refuses_checkout_link_cycle(self):
        self.checkout_link('LICENSE')
        self.invoke('inventory', self.home, self.root / 'final.json', expected=7)

    def test_final_inventory_refuses_case_variant_git_admin_link(self):
        self.checkout_link('../.GiT/HEAD')
        self.invoke('inventory', self.home, self.root / 'final.json', expected=7)

    def test_private_bytes_modes_and_inventory(self):
        receipt = self.snapshot()
        self.assertEqual(receipt['mode'], 'private-copy')
        self.assertEqual(receipt['file_count'], 3)
        self.assertEqual(receipt['caches'], ['git', 'registry'])
        self.assertEqual(receipt['size_bytes'], sum(p.stat().st_size for p in (self.crate, self.archive, self.script)))
        for original in (self.crate, self.archive, self.script):
            copied = self.copied(original)
            self.assertEqual(copied.read_bytes(), original.read_bytes())
            self.assertNotEqual((copied.stat().st_dev, copied.stat().st_ino),
                                (original.stat().st_dev, original.stat().st_ino))
            self.assertEqual(copied.stat().st_mode & 0o111, original.stat().st_mode & 0o111)
        self.assertTrue((self.home / 'registry/index/empty').is_dir())
        self.assertEqual(self.home.stat().st_mode & 0o777, 0o700)
        self.assertEqual(hashlib.sha256(Path(receipt['receipt_path']).read_bytes()).hexdigest(), receipt['receipt_sha256'])
        verified = self.invoke('verify', self.home, receipt['receipt_path'])
        self.assertEqual(verified, receipt)

    def test_does_not_import_configuration_credentials_or_bins(self):
        self.snapshot()
        self.assertEqual(sorted(p.name for p in self.home.iterdir()), ['.dsr-cache-seed.json', 'git', 'registry'])

    def test_original_cache_wipe_cannot_reach_private_files(self):
        receipt = self.snapshot()
        payload = self.copied(self.crate).read_bytes()
        shutil.rmtree(self.source / 'registry')
        shutil.rmtree(self.source / 'git')
        self.assertEqual(self.copied(self.crate).read_bytes(), payload)
        self.invoke('verify', self.home, receipt['receipt_path'])

    def test_in_place_source_writes_cannot_reach_private_files(self):
        receipt = self.snapshot()
        payload = self.copied(self.crate).read_bytes()
        self.crate.write_bytes(b'mutated through original inode\n')
        self.script.chmod(0o600)
        self.assertEqual(self.copied(self.crate).read_bytes(), payload)
        self.invoke('verify', self.home, receipt['receipt_path'])

    def test_private_writes_cannot_modify_ambient_cache(self):
        self.snapshot()
        original = self.crate.read_bytes()
        self.copied(self.crate).write_bytes(b'private mutation\n')
        self.assertEqual(self.crate.read_bytes(), original)

    def test_ambient_hardlinks_are_copied_into_private_inodes(self):
        outside = self.root / 'operator-owned'
        os.link(self.crate, outside)
        receipt = self.snapshot()
        copied = self.copied(self.crate)
        self.assertEqual(copied.stat().st_nlink, 1)
        outside.write_bytes(b'operator mutation through another name')
        self.assertNotEqual(copied.read_bytes(), outside.read_bytes())
        self.invoke('verify', self.home, receipt['receipt_path'])

    def test_final_inventory_refuses_ambient_hardlink_grafts(self):
        self.snapshot()
        os.link(self.crate, self.home / 'registry/ambient-hardlink')
        final = self.root / 'resolved.json'
        self.invoke('inventory', self.home, final, 7)
        self.assertFalse(final.exists())

    def test_verification_refuses_external_ownership_without_byte_changes(self):
        receipt = self.snapshot()
        os.link(self.copied(self.crate), self.root / 'operator-owned')
        self.invoke('verify', self.home, receipt['receipt_path'], 7)

    def test_private_internal_hardlinks_can_be_inventoried_and_verified(self):
        self.snapshot()
        os.link(self.copied(self.crate), self.home / 'git/private-hardlink')
        final = self.invoke('inventory', self.home, self.root / 'resolved.json')
        self.assertEqual(final['file_count'], 4)
        self.invoke('verify', self.home, final['receipt_path'])

    def test_empty_unseeded_home(self):
        result = self.invoke('snapshot', '', self.home)
        self.assertEqual(result['file_count'], 0)
        self.assertEqual(result['caches'], [])
        self.invoke('verify', self.home, result['receipt_path'])

    def test_missing_seed_rejected(self):
        self.invoke('snapshot', self.root / 'missing', self.home, 4)
        self.assertFalse(self.home.exists())

    def test_existing_home_never_overwritten(self):
        self.home.mkdir()
        marker = self.home / 'operator-file'
        marker.write_bytes(b'keep me')
        self.invoke('snapshot', self.source, self.home, 2)
        self.assertEqual(marker.read_bytes(), b'keep me')

    def test_overlapping_homes_rejected(self):
        for dest in (self.source, self.source / 'nested', self.root):
            with self.subTest(destination=dest):
                self.invoke('snapshot', self.source, dest, 4)
        self.assertTrue(self.crate.exists())

    def test_relative_paths_rejected(self):
        self.invoke('snapshot', self.source, 'relative-home', 4)
        self.invoke('snapshot', 'relative-source', self.home, 4)

    def test_top_level_seed_symlink_rejected(self):
        link = self.root / 'source-link'
        link.symlink_to(self.source, target_is_directory=True)
        self.invoke('snapshot', link, self.home, 4)

    def test_destination_dangling_symlink_preserved(self):
        self.home.symlink_to(self.root / 'missing')
        self.invoke('snapshot', self.source, self.home, 2)
        self.assertTrue(self.home.is_symlink())

    def test_nested_symlink_rejected_and_partial_copy_cleaned(self):
        (self.crate.parent / 'escape').symlink_to(self.source / 'credentials.toml')
        self.invoke('snapshot', self.source, self.home, 7)
        self.assertFalse(self.home.exists())
        self.assertEqual((self.source / 'credentials.toml').read_text(), 'DO-NOT-COPY\n')

    def test_cache_root_symlink_rejected(self):
        shutil.rmtree(self.source / 'git')
        (self.source / 'git').symlink_to(self.source / 'registry', target_is_directory=True)
        self.invoke('snapshot', self.source, self.home, 7)
        self.assertFalse(self.home.exists())

    def test_fifo_rejected_without_blocking(self):
        os.mkfifo(self.crate.parent / 'fifo')
        self.invoke('snapshot', self.source, self.home, 7)
        self.assertFalse(self.home.exists())

    def test_external_git_storage_pointers_rejected(self):
        for relative in ('git/db/probe/objects/info/alternates', 'git/db/probe/commondir',
                         'git/db/probe/.git'):
            with self.subTest(path=relative):
                path = self.source / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('/outside/object/store\n')
                self.invoke('snapshot', self.source, self.home, 7)
                self.assertFalse(self.home.exists())
                path.unlink()

    def test_regular_git_clone_survives_seed_removal(self):
        if shutil.which('git') is None:
            self.skipTest('git not installed')
        repository = self.root / 'upstream-repository'
        subprocess.run(['git', 'init', '-q', str(repository)], check=True, capture_output=True)
        (repository / 'Cargo.toml').write_text('[package]\nname="cache-probe"\nversion="1.0.0"\n')
        subprocess.run(['git', '-C', str(repository), 'add', 'Cargo.toml'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(repository), '-c', 'user.name=Cache Test', '-c',
                        'user.email=cache-test@example.invalid', 'commit', '-qm', 'fixture'], check=True, capture_output=True)
        database = self.source / 'git/db/real'
        subprocess.run(['git', 'clone', '-q', '--bare', '--no-hardlinks', str(repository), str(database)],
                       check=True, capture_output=True)
        receipt = self.snapshot()
        repository.rename(self.root / 'retained-upstream')
        self.source.rename(self.root / 'retained-source')
        subprocess.run(['git', '--git-dir=' + str(self.copied(database)), 'fsck', '--full'],
                       check=True, capture_output=True)
        self.invoke('verify', self.home, receipt['receipt_path'])

    def test_new_downloads_can_be_sealed_after_resolution(self):
        seed = self.snapshot()
        downloaded = self.home / 'registry/cache/example/new.crate'
        downloaded.write_bytes(b'new locked dependency')
        self.invoke('verify', self.home, seed['receipt_path'], 7)
        result = self.invoke('inventory', self.home, self.root / 'resolved.json')
        self.assertEqual(result['file_count'], 4)
        self.assertEqual(result['mode'], 'inventory')
        self.invoke('verify', self.home, result['receipt_path'])

    def test_private_content_drift_rejected(self):
        receipt = self.snapshot()
        self.copied(self.crate).write_bytes(b'changed')
        self.invoke('verify', self.home, receipt['receipt_path'], 7)

    def test_private_executable_mode_drift_rejected(self):
        receipt = self.snapshot()
        self.copied(self.script).chmod(0o600)
        self.invoke('verify', self.home, receipt['receipt_path'], 7)

    def test_private_member_deletion_rejected(self):
        receipt = self.snapshot()
        self.copied(self.archive).unlink()
        self.invoke('verify', self.home, receipt['receipt_path'], 7)

    def test_private_member_addition_rejected(self):
        receipt = self.snapshot()
        (self.home / 'registry/unexpected').write_bytes(b'new')
        self.invoke('verify', self.home, receipt['receipt_path'], 7)

    def test_receipt_cannot_overwrite_cache_payload_or_existing_evidence(self):
        receipt = self.snapshot()
        original = self.copied(self.crate).read_bytes()
        self.invoke('inventory', self.home, self.copied(self.crate), 4)
        self.assertEqual(self.copied(self.crate).read_bytes(), original)
        self.invoke('inventory', self.home, receipt['receipt_path'], 2)
        self.invoke('verify', self.home, receipt['receipt_path'])

    def test_receipt_is_bound_to_home(self):
        receipt = self.snapshot()
        other = self.root / 'other'
        self.invoke('snapshot', self.source, other)
        self.invoke('verify', other, receipt['receipt_path'], 7)

    def test_malformed_and_symlink_receipts_rejected(self):
        self.snapshot()
        path = self.root / 'bad.json'
        for text in ('{', '{}', '[]', '{"schema_version":1,"schema_version":1}'):
            path.write_text(text)
            self.invoke('verify', self.home, path, 7)
        link = self.root / 'receipt-link'
        link.symlink_to(self.home / '.dsr-cache-seed.json')
        self.invoke('verify', self.home, link, 7)

    def test_sourceable_api(self):
        result = subprocess.run(['bash', '-uc', 'source "$1"; cargo_cache_snapshot "$2" "$3"',
                                 'cache-test', MODULE, str(self.source), str(self.home)],
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['file_count'], 3)


@unittest.skipIf(sys.version_info < (3, 11), 'lockfile selection requires Python 3.11+')
class LockedCacheTests(unittest.TestCase):
    invoke = PrivateCacheTests.invoke
    copied = PrivateCacheTests.copied

    def setUp(self):
        PrivateCacheTests.setUp(self)
        self.lock = self.root / 'Cargo.lock'
        self.files = {'Cargo.toml': b'[package]\nname="probe"\nversion="1.0.0"\nedition="2021"\n',
                      'src/lib.rs': self.crate.read_bytes()}
        with tarfile.open(self.archive, 'w:gz') as archive:
            for name, content in self.files.items():
                info = tarfile.TarInfo('probe-1.0.0/' + name)
                info.size = len(content); info.mode = 0o644
                archive.addfile(info, io.BytesIO(content))
        self.pin = {'name': 'probe', 'version': '1.0.0',
                    'source': 'registry+https://github.com/rust-lang/crates.io-index',
                    'checksum': hashlib.sha256(self.archive.read_bytes()).hexdigest()}
        self.write_lock([self.pin])
        self.index = self.source / 'registry/index/example'
        entry = self.index / '.cache/pr/ob/probe'
        entry.parent.mkdir(parents=True)
        entry.write_bytes(b'opaque sparse index entry\x00version\x00json\x00')
        (self.index / 'config.json').write_text('{"dl":"https://example.invalid/crates"}')

    def write_lock(self, packages):
        self.lock.write_text('version = 3\n' + ''.join('\n[[package]]\n' + ''.join(
            key + ' = ' + json.dumps(value) + '\n' for key, value in p.items()) for p in packages))

    def scoped(self, expected=0, source=None, home=None):
        result = subprocess.run(['bash', MODULE, 'snapshot', str(self.source if source is None else source),
                                 str(home or self.home), str(self.lock)], text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stderr)
        if expected:
            self.assertFalse(result.stdout)
            return None
        return json.loads(result.stdout)

    def test_download_subset_and_pinned_receipt(self):
        result = self.scoped()
        self.assertEqual(result['file_count'], 3)
        self.assertEqual(result['caches'], ['registry'])
        self.assertFalse((self.home / 'registry/src').exists())
        self.assertFalse((self.home / 'git').exists())
        self.assertFalse((self.home / 'config.toml').exists())
        self.assertFalse((self.home / 'credentials.toml').exists())
        evidence = json.loads(Path(result['receipt_path']).read_bytes())
        self.assertEqual(evidence['selection']['lockfile_sha256'], hashlib.sha256(self.lock.read_bytes()).hexdigest())
        self.assertEqual(evidence['selection']['kind'], 'cargo-lock-downloads')
        self.assertEqual(result['selection'], evidence['selection'])
        self.assertEqual(self.invoke('verify', self.home, result['receipt_path']), result)

    def test_unrelated_symlinks_fifos_and_extracted_poison_are_irrelevant(self):
        (self.script.parent / 'LICENSE').symlink_to('/missing/unrelated')
        os.mkfifo(self.crate.parent / 'unrelated-fifo')
        self.crate.write_bytes(b'poisoned extracted bytes are never seeded')
        result = self.scoped()
        self.assertEqual(result['file_count'], 3)
        self.assertEqual(self.copied(self.archive).read_bytes(), self.archive.read_bytes())

    def test_unused_git_root_on_an_external_volume_is_not_opened(self):
        (self.source / 'git').rename(self.root / 'external-git')
        (self.source / 'git').symlink_to(self.root / 'external-git', target_is_directory=True)
        self.assertEqual(self.scoped()['caches'], ['registry'])

    def test_unselected_oversized_cache_does_not_inflate_seed(self):
        large = self.source / 'registry/cache/example/unrelated-99.0.0.crate'
        with large.open('wb') as output:
            output.truncate(1024 * 1024 * 1024)
        result = self.scoped()
        self.assertLess(result['size_bytes'], 4096)
        self.assertFalse(self.copied(large).exists())

    def test_archives_reextract_after_original_cache_disappears(self):
        result = self.scoped()
        self.source.rename(self.root / 'retained-ambient')
        with tarfile.open(self.copied(self.archive), 'r:gz') as archive:
            for name, content in self.files.items():
                self.assertEqual(archive.extractfile('probe-1.0.0/' + name).read(), content)
        self.invoke('verify', self.home, result['receipt_path'])

    def test_archive_copy_has_no_shared_inode(self):
        result = self.scoped()
        old = self.copied(self.archive).read_bytes()
        self.archive.write_bytes(b'changed ambient archive')
        self.assertEqual(self.copied(self.archive).stat().st_nlink, 1)
        self.assertEqual(self.copied(self.archive).read_bytes(), old)
        self.invoke('verify', self.home, result['receipt_path'])

    def test_wrong_registry_archive_checksum_is_not_seeded(self):
        self.archive.write_bytes(b'not the locked download')
        result = self.scoped()
        self.assertEqual(result['file_count'], 0)
        self.assertFalse(self.copied(self.archive).exists())

    def test_multiple_registry_versions_are_scoped_by_lockfile(self):
        second = self.archive.with_name('probe-2.0.0.crate')
        second.write_bytes(b'second locked version')
        pin = dict(self.pin, version='2.0.0', checksum=hashlib.sha256(second.read_bytes()).hexdigest())
        self.write_lock([self.pin, pin])
        result = self.scoped()
        self.assertEqual(result['file_count'], 4)
        self.assertEqual(self.copied(second).read_bytes(), second.read_bytes())

    def test_selected_index_link_is_rejected(self):
        entry = self.index / '.cache/pr/ob/probe'
        entry.rename(self.root / 'retained-index-entry')
        entry.symlink_to(self.root / 'retained-index-entry')
        self.scoped(7)
        self.assertFalse(self.home.exists())

    def test_selected_archive_link_is_rejected(self):
        self.archive.rename(self.root / 'retained-archive')
        self.archive.symlink_to(self.root / 'retained-archive')
        self.scoped(7)
        self.assertFalse(self.home.exists())

    def test_unrelated_registry_with_linked_index_config_is_not_copied(self):
        other = self.source / 'registry/index/unrelated'
        other.mkdir()
        (other / 'config.json').symlink_to('/unrelated')
        self.assertEqual(self.scoped()['file_count'], 3)

    def test_no_remote_dependencies_produce_empty_seed(self):
        self.write_lock([{'name': 'workspace', 'version': '0.1.0'}])
        (self.source / 'registry').rename(self.root / 'retained-registry')
        (self.source / 'registry').symlink_to('/missing')
        self.assertEqual(self.scoped()['file_count'], 0)

    def test_missing_cache_can_be_retried_without_overwriting_an_admitted_seed(self):
        self.archive.rename(self.root / 'retained-download')
        incomplete = self.scoped()
        self.assertEqual(incomplete['file_count'], 0)
        (self.root / 'retained-download').rename(self.archive)
        complete = self.scoped(home=self.root / 'refilled-home')
        self.assertEqual(complete['file_count'], 3)
        self.assertEqual(self.invoke('verify', self.home, incomplete['receipt_path']), incomplete)

    def test_copying_an_admitted_seed_keeps_extracted_private_sources(self):
        self.scoped()
        extracted = self.home / 'registry/src/example/probe-1.0.0/src/lib.rs'
        extracted.parent.mkdir(parents=True)
        extracted.write_bytes(self.files['src/lib.rs'])
        result = self.invoke('snapshot', self.home, self.root / 'admitted')
        self.assertEqual(result['file_count'], 4)
        self.assertTrue((self.root / 'admitted' / extracted.relative_to(self.home)).is_file())

    def test_lockfile_links_and_invalid_pins_fail_before_copying(self):
        for data in ('[', 'version=99\n', 'version=3\n[[package]]\nname="../escape"\nversion="1.0.0"'):
            self.lock.write_text(data)
            self.scoped(7 if data == '[' else 4)
            self.assertFalse(self.home.exists())
        self.write_lock([dict(self.pin, checksum='invalid')])
        self.scoped(4)
        self.lock.rename(self.root / 'retained-lock')
        self.lock.symlink_to(self.root / 'retained-lock')
        self.scoped(7)

    def test_lockfile_ancestor_symlink_fails_before_copying(self):
        alias = self.root / 'lockfile-parent-alias'
        alias.symlink_to(self.root, target_is_directory=True)
        result = subprocess.run(['bash', MODULE, 'snapshot', str(self.source),
                                 str(self.home), str(alias / 'Cargo.lock')],
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertFalse(result.stdout)
        self.assertIn('[cargo-cache]', result.stderr)
        self.assertFalse(self.home.exists())

    def test_duplicate_pins_are_not_silently_merged(self):
        self.write_lock([self.pin, self.pin])
        self.scoped(4)
        self.assertFalse(self.home.exists())

    def git(self, *args):
        result = subprocess.run(['git'] + list(map(str, args)), text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def make_git_database(self, name):
        work = self.root / ('work-' + name)
        self.git('init', '-q', '-b', 'main', work)
        (work / 'Cargo.toml').write_text('[package]\nname="helper"\nversion="1.0.0"\n')
        (work / 'lib.rs').write_text('pub fn value() -> u32 { 42 }\n')
        self.git('-C', work, 'add', '.')
        self.git('-C', work, '-c', 'user.name=DSR Test', '-c', 'user.email=dsr@example.invalid', 'commit', '-qm', name)
        sha = self.git('-C', work, 'rev-parse', 'HEAD')
        database = self.source / ('git/db/' + name)
        self.git('clone', '-q', '--bare', '--no-hardlinks', work, database)
        return database, sha

    @unittest.skipUnless(shutil.which('git'), 'Git not installed')
    def test_only_locked_git_database_is_copied_and_can_recreate_checkout(self):
        database, sha = self.make_git_database('selected-123')
        unrelated, _ = self.make_git_database('unrelated-456')
        (unrelated / 'irrelevant-link').symlink_to('/missing')
        (self.script.parent / 'LICENSE').symlink_to('/missing')
        self.write_lock([{'name': 'helper', 'version': '1.0.0', 'source': 'git+https://example.invalid/helper#' + sha}])
        result = self.scoped()
        self.assertEqual(result['caches'], ['git'])
        self.assertFalse(self.copied(unrelated).exists())
        self.assertFalse((self.home / 'git/checkouts').exists())
        self.source.rename(self.root / 'retained-ambient')
        checkout = self.root / 'recreated'
        self.git('clone', '-q', '--no-hardlinks', self.copied(database), checkout)
        self.git('-C', checkout, 'checkout', '-q', sha)
        self.assertEqual((checkout / 'lib.rs').read_text(), 'pub fn value() -> u32 { 42 }\n')
        self.invoke('verify', self.home, result['receipt_path'])

    @unittest.skipUnless(shutil.which('git'), 'Git not installed')
    def test_selecting_git_downloads_never_fetches_from_unrelated_partial_clones(self):
        database, sha = self.make_git_database('selected-123')
        unrelated = self.source / 'git/db/unrelated-partial'
        self.git('init', '-q', '--bare', unrelated)
        for key, value in (('remote.origin.url', 'review::local-only'),
                           ('remote.origin.promisor', 'true'),
                           ('extensions.partialClone', 'origin'),
                           ('protocol.review.allow', 'always')):
            self.git('--git-dir=' + str(unrelated), 'config', key, value)
        helpers = self.root / 'helpers'
        helpers.mkdir()
        helper = helpers / 'git-remote-review'
        helper.write_text('#!/bin/sh\nprintf invoked > "$DSR_PROMISOR_MARKER"\nexit 1\n')
        helper.chmod(0o700)
        marker = self.root / 'remote-invoked'
        environment = dict(os.environ, PATH=str(helpers) + os.pathsep + os.environ.get('PATH', ''),
                           DSR_PROMISOR_MARKER=str(marker), GIT_NO_LAZY_FETCH='0', GIT_ALLOW_PROTOCOL='review')
        # Real Git demonstrates that a read-only-looking object probe fetches
        # without DSR's isolation, even if generic protocol policy says never.
        subprocess.run(['git', '--git-dir=' + str(unrelated), '-c', 'protocol.allow=never',
                        'cat-file', '--batch-check'], input=sha + '\n',
                       text=True, capture_output=True, timeout=15, env=environment)
        self.assertTrue(marker.is_file(), 'promisor control must exercise the real remote helper')
        marker.rename(self.root / 'retained-control-invocation')
        self.write_lock([{'name': 'helper', 'version': '1.0.0', 'source': 'git+https://example.invalid/helper#' + sha}])
        with patch.dict(os.environ, environment):
            result = self.scoped()
        self.assertFalse(marker.exists(), 'cache selection must not invoke any remote helper')
        self.assertEqual(result['caches'], ['git'])
        self.assertTrue(self.copied(database).is_dir())
        self.assertFalse(self.copied(unrelated).exists())
        self.invoke('verify', self.home, result['receipt_path'])

    @unittest.skipUnless(shutil.which('git'), 'Git not installed')
    def test_selected_git_storage_still_rejects_external_pointers(self):
        database, sha = self.make_git_database('selected-123')
        pointer = database / 'objects/info/alternates'
        pointer.write_text('/outside/objects\n')
        self.write_lock([{'name': 'helper', 'version': '1.0.0', 'source': 'git+https://example.invalid/helper#' + sha}])
        self.scoped(7)

    def test_selected_seed_drift_is_still_refused(self):
        result = self.scoped()
        self.copied(self.archive).write_bytes(b'changed private input')
        self.invoke('verify', self.home, result['receipt_path'], 7)


class UnscopedGitSeedTests(unittest.TestCase):
    setUp = PrivateCacheTests.setUp
    invoke = PrivateCacheTests.invoke
    snapshot = PrivateCacheTests.snapshot
    copied = PrivateCacheTests.copied
    git = LockedCacheTests.git
    make_git_database = LockedCacheTests.make_git_database

    def test_issue_39_unrelated_checkout_license_link_does_not_abort(self):
        checkout = self.source / 'git/checkouts/k9/revision'
        checkout.mkdir(parents=True)
        (checkout / 'LICENSE').symlink_to('/missing/unrelated-license')
        receipt = self.snapshot()
        self.assertFalse((self.home / 'git/checkouts').exists())
        self.assertTrue((checkout / 'LICENSE').is_symlink())
        self.assertEqual(receipt['file_count'], 3)
        self.invoke('verify', self.home, receipt['receipt_path'])

    def test_checkout_volume_is_not_copied(self):
        checkout = self.source / 'git/checkouts/unrelated/revision'
        checkout.mkdir(parents=True)
        with (checkout / 'large-source').open('wb') as output:
            output.truncate(32 * 1024 * 1024)
        receipt = self.snapshot()
        self.assertEqual(receipt['size_bytes'], sum(p.stat().st_size for p in
                                                   (self.crate, self.archive, self.script)))
        self.assertFalse((self.home / 'git/checkouts').exists())

    def test_checkout_root_links_and_fifos_are_not_opened(self):
        excluded = self.source / 'git/checkouts'
        for kind in ('link', 'fifo'):
            with self.subTest(kind=kind):
                if kind == 'link':
                    excluded.symlink_to(self.source / 'credentials.toml')
                else:
                    os.mkfifo(excluded)
                home = self.root / ('private-' + kind)
                receipt = self.invoke('snapshot', self.source, home)
                self.assertFalse((home / 'git/checkouts').exists())
                self.assertEqual(receipt['file_count'], 3)
            excluded.rename(self.root / ('preserved-' + kind))

    def test_selected_database_root_link_is_still_refused(self):
        database = self.source / 'git/db'
        database.rename(self.root / 'retained-db')
        database.symlink_to(self.root / 'retained-db', target_is_directory=True)
        self.invoke('snapshot', self.source, self.home, 7)
        self.assertFalse(self.home.exists())

    def test_selected_database_member_link_is_still_refused(self):
        (self.script.parent / 'escape').symlink_to(self.source / 'credentials.toml')
        self.invoke('snapshot', self.source, self.home, 7)
        self.assertFalse(self.home.exists())
        self.assertEqual((self.source / 'credentials.toml').read_text(), 'DO-NOT-COPY\n')

    def test_final_inventory_still_covers_recreated_checkouts(self):
        seed = self.snapshot()
        checkout = self.home / 'git/checkouts/recreated/revision'
        checkout.mkdir(parents=True)
        payload = checkout / 'lib.rs'
        payload.write_bytes(b'pub fn answer() -> u32 { 42 }\n')
        self.invoke('verify', self.home, seed['receipt_path'], 7)
        final = self.invoke('inventory', self.home, self.root / 'resolved.json')
        self.assertEqual(final['file_count'], 4)
        self.invoke('verify', self.home, final['receipt_path'])
        payload.write_bytes(b'changed after final inventory')
        self.invoke('verify', self.home, final['receipt_path'], 7)
        (checkout / 'escape').symlink_to(self.crate)
        self.invoke('inventory', self.home, self.root / 'unsafe.json', 7)
        self.assertFalse((self.root / 'unsafe.json').exists())

    def test_final_inventory_rejects_external_checkout_storage_pointers(self):
        self.snapshot()
        checkout = self.home / 'git/checkouts/recreated/revision'
        checkout.mkdir(parents=True)
        (checkout / '.git').write_text('gitdir: /outside/objects\n')
        self.invoke('inventory', self.home, self.root / 'external.json', 7)
        self.assertFalse((self.root / 'external.json').exists())

    def test_database_replacement_after_copy_is_refused(self):
        # Deterministic filesystem-change injection after the real copy, not
        # a mocked inventory or admission result. Use production definitions.
        import ast
        code = Path(MODULE).read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
        definitions = ast.parse(code)
        definitions.body = [node for node in definitions.body if isinstance(
            node, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.ClassDef))]
        namespace = {}
        exec(compile(definitions, MODULE, 'exec'), namespace)
        original = namespace['inventory']

        def replace_after_copy(root, destination=None, **kwargs):
            result = original(root, destination, **kwargs)
            if root == str(self.source) and destination is not None:
                db = self.source / 'git/db'
                db.rename(self.root / 'replaced-database')
                shutil.copytree(self.root / 'replaced-database', db)
            return result

        namespace['inventory'] = replace_after_copy
        with self.assertRaisesRegex(namespace['Failure'], 'cache selection changed'):
            namespace['main'](['snapshot', str(self.source), str(self.home)])
        self.assertFalse(self.home.exists())
        self.assertEqual(self.script.read_bytes(), b'#!/bin/sh\nexit 0\n')

    @unittest.skipUnless(shutil.which('git'), 'Git not installed')
    def test_real_git_reconstruction_uses_objects_not_ambient_working_bytes(self):
        database, sha = self.make_git_database('actual-database')
        checkout = self.source / 'git/checkouts/actual-database/revision'
        self.git('clone', '-q', '--no-hardlinks', database, checkout)
        (checkout / 'lib.rs').write_text('pub fn value() -> u32 { 666 }\n')
        (checkout / 'LICENSE').symlink_to('/missing/unrelated')
        receipt = self.snapshot()
        self.assertFalse((self.home / 'git/checkouts').exists())
        self.source.rename(self.root / 'retained-ambient')
        recreated = self.root / 'recreated'
        self.git('clone', '-q', '--no-hardlinks', self.copied(database), recreated)
        self.git('-C', recreated, 'checkout', '-q', sha)
        self.assertEqual((recreated / 'lib.rs').read_text(), 'pub fn value() -> u32 { 42 }\n')
        self.invoke('verify', self.home, receipt['receipt_path'])

    def test_missing_database_is_not_replaced_with_a_checkout(self):
        (self.source / 'git/db').rename(self.root / 'retained-db')
        checkout = self.source / 'git/checkouts/source-only'
        checkout.mkdir(parents=True)
        (checkout / 'lib.rs').write_text('unselected working bytes')
        receipt = self.snapshot()
        self.assertEqual(receipt['file_count'], 2)
        self.assertFalse((self.home / 'git/checkouts').exists())
        self.assertNotIn('selection', receipt)

    def test_remote_function_remains_self_contained(self):
        command = ['bash', '-c', 'source "$1"; declare -f _cargo_cache_run', '_', MODULE]
        definition = subprocess.run(command, text=True, capture_output=True, check=True).stdout
        definition += '\n_cargo_cache_run snapshot "$1" "$2"\n'
        result = subprocess.run(['bash', '-c', definition, '_', str(self.source), str(self.home)],
                                cwd=self.root, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['file_count'], 3)

    @unittest.skipUnless(shutil.which('cargo') and shutil.which('rustc'),
                         'real Cargo/rustc unavailable; no compiler fixture or toolchain installation')
    def test_real_cargo_build_recreates_git_sources_offline(self):
        # Only a local file:// dependency, no registry or network dependency.
        # This separately qualifies Cargo consumption, not merely Git objects.
        upstream = self.root / 'cargo-upstream'
        self.git('init', '-q', '-b', 'main', upstream)
        (upstream / 'Cargo.toml').write_text(
            '[package]\nname="seed-dependency"\nversion="1.0.0"\nedition="2021"\n[lib]\npath="lib.rs"\n')
        (upstream / 'lib.rs').write_text('pub fn answer() -> u32 { 42 }\n')
        self.git('-C', upstream, 'add', '.')
        self.git('-C', upstream, '-c', 'user.name=DSR Test', '-c', 'user.email=dsr@example.invalid',
                 'commit', '-qm', 'local dependency')
        revision = self.git('-C', upstream, 'rev-parse', 'HEAD')
        project = self.root / 'cargo-project'
        (project / 'src').mkdir(parents=True)
        (project / 'Cargo.toml').write_text(
            '[package]\nname="seed-consumer"\nversion="1.0.0"\nedition="2021"\n[dependencies]\n'
            'seed-dependency={git=' + json.dumps(upstream.as_uri()) + ',rev=' + json.dumps(revision) + '}\n')
        (project / 'src/main.rs').write_text('fn main() { println!("{}", seed_dependency::answer()); }\n')
        ambient = self.root / 'real-cargo-home'
        ambient.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(('CARGO_', 'RUST', 'GIT_'))}
        env.update(CARGO_HOME=str(ambient), CARGO_TARGET_DIR=str(self.root / 'target'),
                   RUSTUP_AUTO_INSTALL='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
        for name in ('RUSTUP_HOME', 'RUSTUP_TOOLCHAIN'):
            if name in os.environ:
                env[name] = os.environ[name]
        result = subprocess.run(['cargo', 'fetch'], cwd=project, env=env, capture_output=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        home = self.root / 'real-private'
        seed = self.invoke('snapshot', ambient, home)
        self.assertFalse((home / 'git/checkouts').exists())
        ambient.rename(self.root / 'retained-real-cargo-home')
        upstream.rename(self.root / 'retained-upstream')
        env['CARGO_HOME'] = str(home)
        result = subprocess.run(['cargo', 'run', '--locked', '--offline', '--quiet'],
                                cwd=project, env=env, capture_output=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout.strip(), b'42')
        final = self.invoke('inventory', home, self.root / 'cargo-final.json')
        self.invoke('verify', home, final['receipt_path'])
        self.assertEqual(json.loads(Path(seed['receipt_path']).read_bytes())['kind'], 'private-copy')


class UnscopedRegistrySeedTests(unittest.TestCase):
    setUp = PrivateCacheTests.setUp
    invoke = PrivateCacheTests.invoke
    snapshot = PrivateCacheTests.snapshot
    copied = PrivateCacheTests.copied

    def package(self, name='probe-1.0.0', registry='example'):
        tree = self.source / 'registry/src' / registry / name
        (tree / 'src').mkdir(parents=True)
        files = {'Cargo.toml': b'[package]\nname="probe"\nversion="1.0.0"\nedition="2021"\n',
                 'src/lib.rs': b'pub fn answer() -> u32 { 42 }\n'}
        for path, content in files.items():
            (tree / path).write_bytes(content)
        archive = self.source / 'registry/cache' / registry / (name + '.crate')
        archive.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive, 'w:gz') as packed:
            for path, content in files.items():
                info = tarfile.TarInfo(name + '/' + path)
                info.size = len(content)
                info.mode = 0o644
                packed.addfile(info, io.BytesIO(content))
        return tree, archive, files

    def test_archive_backed_expansion_is_not_copied(self):
        tree, archive, _ = self.package()
        result = self.snapshot()
        self.assertFalse(self.copied(tree).exists())
        self.assertEqual(self.copied(archive).read_bytes(), archive.read_bytes())
        self.assertEqual(self.copied(self.crate).read_bytes(), self.crate.read_bytes())
        self.assertEqual(result['file_count'], 3)
        self.invoke('verify', self.home, result['receipt_path'])

    def test_large_redundant_sources_do_not_inflate_seed(self):
        tree, archive, _ = self.package()
        with (tree / 'expanded-source').open('wb') as data:
            data.truncate(64 * 1024 * 1024)
        result = self.snapshot()
        self.assertEqual(result['size_bytes'], sum(p.stat().st_size for p in
                                                   (self.crate, archive, self.script)))
        self.assertFalse(self.copied(tree).exists())
        self.assertEqual((tree / 'expanded-source').stat().st_size, 64 * 1024 * 1024)

    def test_redundant_sources_are_not_traversed_for_links_or_special_files(self):
        tree, _, _ = self.package()
        (tree / 'LICENSE').symlink_to(self.source / 'credentials.toml')
        os.mkfifo(tree / 'blocked-pipe')
        result = self.snapshot()
        self.assertFalse(self.copied(tree).exists())
        self.assertTrue((tree / 'LICENSE').is_symlink())
        self.invoke('verify', self.home, result['receipt_path'])

    def test_redundant_source_root_link_and_fifo_are_not_opened(self):
        tree, _, _ = self.package()
        tree.rename(self.root / 'retained-expanded')
        for kind in ('link', 'fifo'):
            if kind == 'link': tree.symlink_to(self.root / 'retained-expanded')
            else: os.mkfifo(tree)
            try:
                with self.subTest(kind=kind):
                    home = self.root / ('private-' + kind)
                    result = self.invoke('snapshot', self.source, home)
                    self.assertFalse((home / tree.relative_to(self.source)).exists())
                    self.invoke('verify', home, result['receipt_path'])
            finally:
                tree.rename(self.root / ('retained-source-' + kind))

    def test_copied_archive_reconstructs_original_not_modified_working_sources(self):
        tree, archive, files = self.package()
        (tree / 'src/lib.rs').write_bytes(b'pub fn answer() -> u32 { 666 }\n')
        result = self.snapshot()
        self.source.rename(self.root / 'retained-ambient')
        with tarfile.open(self.copied(archive), 'r:gz') as packed:
            for path, content in files.items():
                self.assertEqual(packed.extractfile('probe-1.0.0/' + path).read(), content)
        self.invoke('verify', self.home, result['receipt_path'])

    def test_source_only_registry_and_package_are_preserved(self):
        tree, archive, files = self.package()
        archive.rename(self.root / 'retained-archive')
        second = self.source / 'registry/src/source-only-registry/helper-1.0.0/src/lib.rs'
        second.parent.mkdir(parents=True)
        second.write_bytes(b'source-only registry bytes\n')
        result = self.snapshot()
        for path, content in files.items(): self.assertEqual(self.copied(tree / path).read_bytes(), content)
        self.assertEqual(self.copied(second).read_bytes(), second.read_bytes())
        self.invoke('verify', self.home, result['receipt_path'])

    def test_other_registry_archive_never_discards_same_named_source(self):
        tree, archive, files = self.package()
        other = self.source / 'registry/cache/other'
        other.mkdir()
        archive.rename(other / archive.name)
        result = self.snapshot()
        self.assertEqual(self.copied(tree / 'src/lib.rs').read_bytes(), files['src/lib.rs'])
        self.invoke('verify', self.home, result['receipt_path'])

    def test_empty_archive_keeps_the_only_materialized_source(self):
        tree, archive, files = self.package()
        archive.write_bytes(b'')
        result = self.snapshot()
        self.assertEqual(self.copied(tree / 'src/lib.rs').read_bytes(), files['src/lib.rs'])
        self.invoke('verify', self.home, result['receipt_path'])

    def test_absent_archive_root_keeps_source_cache(self):
        tree, _, files = self.package()
        (self.source / 'registry/cache').rename(self.root / 'retained-downloads')
        result = self.snapshot()
        self.assertEqual(self.copied(tree / 'src/lib.rs').read_bytes(), files['src/lib.rs'])
        self.invoke('verify', self.home, result['receipt_path'])

    def test_package_versions_and_build_metadata_select_only_exact_archive(self):
        first, _, _ = self.package('probe-1.0.0-rc.1+build.5')
        other, archive, files = self.package('probe-2.0.0')
        archive.rename(self.root / 'retained-other-archive')
        result = self.snapshot()
        self.assertFalse(self.copied(first).exists())
        self.assertEqual(self.copied(other / 'src/lib.rs').read_bytes(), files['src/lib.rs'])
        self.invoke('verify', self.home, result['receipt_path'])

    def test_selected_source_only_links_are_still_refused(self):
        (self.crate.parent / 'unsafe').symlink_to(self.source / 'credentials.toml')
        self.invoke('snapshot', self.source, self.home, 7)
        self.assertFalse(self.home.exists())

    def test_selected_archive_links_and_special_files_are_still_refused(self):
        _, archive, _ = self.package()
        archive.rename(self.root / 'retained-archive')
        for kind in ('link', 'fifo'):
            with self.subTest(kind=kind):
                if kind == 'link': archive.symlink_to(self.root / 'retained-archive')
                else: os.mkfifo(archive)
                self.invoke('snapshot', self.source, self.root / ('private-' + kind), 7)
                self.assertFalse((self.root / ('private-' + kind)).exists())
                archive.rename(self.root / ('retained-archive-' + kind))

    def test_registry_route_links_are_still_refused(self):
        self.package()
        for relative in ('registry/cache', 'registry/cache/example', 'registry/src', 'registry/src/example'):
            with self.subTest(relative=relative):
                route = self.source / relative
                held = self.root / ('held-' + relative.replace('/', '-'))
                route.rename(held)
                route.symlink_to(held, target_is_directory=True)
                self.invoke('snapshot', self.source, self.home, 7)
                self.assertFalse(self.home.exists())
                route.rename(self.root / ('link-' + relative.replace('/', '-')))
                held.rename(route)

    def test_full_inventory_checks_recreated_registry_sources(self):
        tree, archive, files = self.package()
        seed = self.snapshot()
        self.assertFalse(self.copied(tree).exists())
        for path, content in files.items():
            output = self.copied(tree / path)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(content)
        self.invoke('verify', self.home, seed['receipt_path'], 7)
        final = self.invoke('inventory', self.home, self.root / 'final.json')
        self.invoke('verify', self.home, final['receipt_path'])
        self.copied(tree / 'src/lib.rs').write_bytes(b'modified after final inventory')
        self.invoke('verify', self.home, final['receipt_path'], 7)
        self.copied(tree / 'LICENSE').symlink_to(archive)
        self.invoke('inventory', self.home, self.root / 'unsafe.json', 7)
        self.assertFalse((self.root / 'unsafe.json').exists())

    def test_preexisting_full_receipt_is_not_rewritten_by_verification(self):
        self.package()
        retained = self.invoke('inventory', self.source, self.root / 'retained.json')
        original = Path(retained['receipt_path']).read_bytes()
        self.invoke('verify', self.source, retained['receipt_path'])
        self.assertEqual(Path(retained['receipt_path']).read_bytes(), original)

    def test_prepared_private_source_receipt_keeps_its_materialized_paths(self):
        tree, _, files = self.package()
        seed = self.snapshot()
        for path, content in files.items():
            output = self.copied(tree / path)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(content)
        before = Path(seed['receipt_path']).read_bytes()
        destination = self.root / 'prepared-copy'
        result = self.invoke('snapshot', self.home, destination)
        for path, content in files.items():
            self.assertEqual((destination / tree.relative_to(self.source) / path).read_bytes(), content)
        self.assertEqual(Path(seed['receipt_path']).read_bytes(), before)
        self.invoke('verify', destination, result['receipt_path'])

    def test_marker_presence_never_authenticates_or_follows_a_source_link(self):
        tree, _, _ = self.package()
        (self.source / '.dsr-cache-seed.json').symlink_to(self.source / 'credentials.toml')
        (tree / 'LICENSE').symlink_to(self.source / 'credentials.toml')
        self.invoke('snapshot', self.source, self.home, 7)
        self.assertFalse(self.home.exists())
        self.assertEqual((self.source / 'credentials.toml').read_bytes(), b'DO-NOT-COPY\n')

    def changed_after_copy(self, change, refused=True):
        # Deterministic mutation at a real inventory-return boundary. The full
        # production copy/read/verification runs; only timing is controlled.
        import ast
        code = Path(MODULE).read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
        definitions = ast.parse(code)
        definitions.body = [node for node in definitions.body if isinstance(
            node, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.ClassDef))]
        namespace = {}
        exec(compile(definitions, MODULE, 'exec'), namespace)
        original = namespace['inventory']

        def after_copy(root, destination=None, **kwargs):
            result = original(root, destination, **kwargs)
            if root == str(self.source) and destination is not None: change()
            return result

        namespace['inventory'] = after_copy
        if refused:
            with self.assertRaises(namespace['Failure']):
                namespace['main'](['snapshot', str(self.source), str(self.home)])
            self.assertFalse(self.home.exists())
        else:
            result = namespace['main'](['snapshot', str(self.source), str(self.home)])
            self.invoke('verify', self.home, result['receipt_path'])

    def test_archive_replacement_after_copy_is_refused(self):
        _, archive, _ = self.package()

        def change():
            original = archive.read_bytes()
            archive.rename(self.root / 'old-archive')
            archive.write_bytes(original)

        self.changed_after_copy(change)

    def test_archive_removal_after_copy_is_refused(self):
        _, archive, _ = self.package()
        self.changed_after_copy(lambda: archive.rename(self.root / 'removed-archive'))

    def test_archive_byte_change_after_copy_is_refused(self):
        _, archive, _ = self.package()
        self.changed_after_copy(lambda: archive.write_bytes(b'changed download'))

    def test_new_source_only_package_after_copy_is_refused(self):
        self.package()

        def change():
            extra = self.source / 'registry/src/example/new-source-1.0.0'
            extra.mkdir()
            (extra / 'lib.rs').write_bytes(b'new required private selection')

        self.changed_after_copy(change)

    def test_changes_inside_omitted_expansion_do_not_invalidate_private_bytes(self):
        tree, _, _ = self.package()
        self.changed_after_copy(lambda: (tree / 'new-working-file').write_bytes(b'ignored expansion'), refused=False)
        self.assertFalse(self.copied(tree).exists())

    @unittest.skipUnless(shutil.which('cargo') and shutil.which('rustc'),
                         'real Cargo/rustc unavailable; registry consumption requires genuine tools')
    def test_real_cargo_reextracts_registry_sources_offline(self):
        # Real Cargo fetches a tiny registry served on loopback, then the server
        # and ambient cache disappear. No public network, compiler adapter or
        # toolchain installation is involved. The package has no dependencies.
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        import threading

        _, archive, _ = self.package()
        raw = archive.read_bytes()
        index = dict(name='probe', vers='1.0.0', deps=[], cksum=hashlib.sha256(raw).hexdigest(),
                     features={}, yanked=False)
        objects = {'/pr/ob/probe': json.dumps(index).encode() + b'\n',
                   '/crate/probe/1.0.0/download': raw}

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                payload = objects.get(self.path)
                if payload is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        address = 'http://127.0.0.1:' + str(server.server_address[1])
        objects['/config.json'] = json.dumps({'dl': address + '/crate/{crate}/{version}/download'}).encode()
        serving = threading.Thread(target=server.serve_forever)
        project = self.root / 'registry-project'
        (project / 'src').mkdir(parents=True)
        (project / '.cargo').mkdir()
        (project / '.cargo/config.toml').write_text(
            '[source.crates-io]\nreplace-with="fixture"\n[source.fixture]\nregistry=' +
            json.dumps('sparse+' + address + '/') + '\n')
        (project / 'Cargo.toml').write_text(
            '[package]\nname="registry-consumer"\nversion="1.0.0"\nedition="2021"\n'
            '[dependencies]\nprobe="=1.0.0"\n')
        (project / 'src/main.rs').write_text('fn main() { println!("{}", probe::answer()); }\n')
        ambient = self.root / 'real-registry-home'
        ambient.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(('CARGO_', 'RUST', 'GIT_'))}
        env.update(CARGO_HOME=str(ambient), CARGO_TARGET_DIR=str(self.root / 'registry-target'),
                   RUSTUP_AUTO_INSTALL='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                   HTTP_PROXY='', HTTPS_PROXY='', ALL_PROXY='', NO_PROXY='127.0.0.1')
        for name in ('RUSTUP_HOME', 'RUSTUP_TOOLCHAIN'):
            if name in os.environ: env[name] = os.environ[name]
        serving.start()
        try:
            fetched = subprocess.run(['cargo', 'fetch'], cwd=project, env=env,
                                     capture_output=True, timeout=90)
        finally:
            server.shutdown()
            server.server_close()
            serving.join(timeout=10)
        self.assertEqual(fetched.returncode, 0, fetched.stderr.decode())
        expanded = list((ambient / 'registry/src').glob('*/probe-1.0.0/src/lib.rs'))
        self.assertEqual(len(expanded), 1)
        expanded[0].write_bytes(b'pub fn answer() -> u32 { 666 }\n')
        (expanded[0].parents[1] / 'LICENSE').symlink_to('/missing/redundant-source')
        home = self.root / 'real-registry-private'
        seed = self.invoke('snapshot', ambient, home)
        self.assertFalse(list((home / 'registry/src').glob('*/probe-1.0.0')))
        ambient.rename(self.root / 'retained-registry-home')
        env['CARGO_HOME'] = str(home)
        built = subprocess.run(['cargo', 'run', '--offline', '--locked', '--quiet'],
                               cwd=project, env=env, capture_output=True, timeout=90)
        self.assertEqual(built.returncode, 0, built.stderr.decode())
        self.assertEqual(built.stdout.strip(), b'42')
        final = self.invoke('inventory', home, self.root / 'registry-final.json')
        self.invoke('verify', home, final['receipt_path'])
        self.assertEqual(json.loads(Path(seed['receipt_path']).read_bytes())['kind'], 'private-copy')


unittest.main(verbosity=2)
PY
