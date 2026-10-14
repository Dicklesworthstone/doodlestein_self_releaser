#!/usr/bin/env bash
# Real filesystem/Git checks for relocated ambient Cargo roots. No compiler,
# network, or production predicate is replaced. Owned fixtures are retained.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dependency in python3 git; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'SKIP: missing %s\n' "$dependency"
        exit 0
    fi
done
python3 -I - "${DSR_TEST_CARGO_CACHE_MODULE:-$ROOT/src/cargo_cache.sh}" "$@" <<'PY'
import ast
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

MODULE = Path(sys.argv.pop(1)).resolve()
SOURCE = MODULE.read_text()
ENV = {key: value for key, value in os.environ.items()
       if not key.startswith(('BASH_FUNC_', 'GIT_')) and key not in ('BASH_ENV', 'ENV')}
ENV.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0')
REGISTRY = 'index.crates.io-fixture'
ARCHIVE = 'demo_dep-1.0.0.crate'


def run(*args):
    return subprocess.run([str(a) for a in args], capture_output=True, env=ENV, timeout=30)


def git(*args):
    result = run('git', *args)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace'))
    return result.stdout.decode().strip()


class CacheRoots(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix='dsr-cache-roots-')).resolve()
        print('Owned cache fixtures retained: ' + str(cls.root), file=sys.stderr)

    def setUp(self):
        self.work = self.root / self._testMethodName
        self.work.mkdir()
        self.serial = 0

    def fixture(self, alias=True, relative=False, with_git=False):
        self.serial += 1
        work = self.work / str(self.serial)
        work.mkdir()
        home = work / 'cargo-home'
        home.mkdir()
        external = work / 'relocated registry'
        external.mkdir()
        if alias:
            (home / 'registry').symlink_to('../relocated registry' if relative else external, target_is_directory=True)
        else:
            external.rename(home / 'registry')
            external = home / 'registry'
        download = external / 'cache' / REGISTRY / ARCHIVE
        download.parent.mkdir(parents=True)
        with tarfile.open(download, 'w:gz') as archive:
            item = tarfile.TarInfo('demo_dep-1.0.0/src/lib.rs')
            data = b'pub fn answer() -> u32 { 42 }\n'
            item.size = len(data)
            item.mode = 0o644
            archive.addfile(item, io.BytesIO(data))
        index = external / 'index' / REGISTRY
        (index / '.cache/de/mo').mkdir(parents=True)
        (index / '.cache/de/mo/demo_dep').write_bytes(b'owned sparse index fixture')
        (index / 'config.json').write_text('{"dl":"https://example.invalid/crates"}\n')
        (home / 'config.toml').write_text('[alias]\nbuild="not-a-build"\n')
        (home / 'credentials.toml').write_text('owned fixture, not a real credential\n')
        lock = work / 'Cargo.lock'
        lock.write_text('version = 4\n\n[[package]]\nname="demo"\nversion="1.0.0"\n\n'
                        '[[package]]\nname="demo_dep"\nversion="1.0.0"\n'
                        'source="registry+https://github.com/rust-lang/crates.io-index"\n'
                        'checksum="' + hashlib.sha256(download.read_bytes()).hexdigest() + '"\n')
        revision = None
        if with_git:
            upstream = work / 'upstream'
            git('init', '-q', '-b', 'main', upstream)
            git('-C', upstream, 'config', 'user.name', 'DSR fixture')
            git('-C', upstream, 'config', 'user.email', 'fixture@example.invalid')
            (upstream / 'lib.rs').write_text('pub fn dependency() -> u32 { 7 }\n')
            git('-C', upstream, 'add', 'lib.rs')
            git('-C', upstream, 'commit', '-qm', 'owned dependency')
            revision = git('-C', upstream, 'rev-parse', 'HEAD')
            git_root = work / 'relocated git'
            (git_root / 'db').mkdir(parents=True)
            git('clone', '-q', '--bare', '--no-hardlinks', upstream, git_root / 'db/dependency')
            (git_root / 'checkouts').mkdir()
            (git_root / 'checkouts/unused').symlink_to(work / 'missing-working-copy')
            (home / 'git').symlink_to(git_root, target_is_directory=True)
            with lock.open('a') as output:
                output.write('\n[[package]]\nname="git_dep"\nversion="1.0.0"\n'
                             'source="git+' + upstream.as_uri() + '#' + revision + '"\n')
        return home, external, download, lock, revision

    def call(self, command, *args):
        return run('bash', MODULE, command, *args)

    def snapshot(self, home, destination, lock=None):
        result = self.call('snapshot', home, destination, *([] if lock is None else [lock]))
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        value = json.loads(result.stdout)
        receipt = json.loads(Path(value['receipt_path']).read_bytes())
        self.assertEqual(value['mode'], 'private-copy')
        self.assertEqual(self.call('verify', destination, value['receipt_path']).returncode, 0)
        self.assertTrue(all(not p.is_symlink() for p in destination.rglob('*')))
        self.assertFalse((destination / 'config.toml').exists())
        self.assertFalse((destination / 'credentials.toml').exists())
        return value, receipt

    def test_locked_registry_absolute_and_relative_aliases(self):
        for relative in (False, True):
            with self.subTest(relative=relative):
                home, external, download, lock, _ = self.fixture(relative=relative)
                (home / 'git').symlink_to(home / 'git', target_is_directory=True)
                (external / 'src').symlink_to(self.work / 'irrelevant-unpacked-tree')
                destination = home.parent / 'private'
                value, receipt = self.snapshot(home, destination, lock)
                self.assertEqual(value['selection']['registry_packages'], 1)
                self.assertEqual(value['file_count'], 3)
                self.assertEqual(value['caches'], ['registry'])
                copied = destination / 'registry/cache' / REGISTRY / ARCHIVE
                self.assertEqual(copied.read_bytes(), download.read_bytes())
                self.assertNotEqual(copied.stat().st_ino, download.stat().st_ino)
                self.assertEqual(copied.stat().st_nlink, 1)
                before = copied.read_bytes()
                download.write_bytes(b'changed ambient input after snapshot')
                self.assertEqual(copied.read_bytes(), before)
                self.assertEqual(self.call('verify', destination, value['receipt_path']).returncode, 0)
                self.assertEqual(receipt['seed_source'], str(home))

    def test_locked_git_alias_retains_pinned_database_not_checkouts(self):
        home, _, _, lock, revision = self.fixture(alias=False, with_git=True)
        destination = home.parent / 'private'
        value, _ = self.snapshot(home, destination, lock)
        self.assertEqual(value['selection']['git_revisions'], [revision])
        self.assertFalse((destination / 'git/checkouts').exists())
        actual = git('--git-dir=' + str(destination / 'git/db/dependency'), 'show', revision + ':lib.rs')
        self.assertEqual(actual, 'pub fn dependency() -> u32 { 7 }')

    def test_git_only_selection_does_not_open_an_unrelated_registry_alias(self):
        home, _, _, lock, revision = self.fixture(with_git=True)
        (home / 'registry').rename(home / 'preserved-registry-alias')
        (home / 'registry').symlink_to(home / 'registry')
        lock.write_text('version=4\n[[package]]\nname="git_dep"\nversion="1.0.0"\n'
                        'source="git+' + (home.parent / 'upstream').as_uri() + '#' + revision + '"\n')
        value, _ = self.snapshot(home, home.parent / 'private', lock)
        self.assertEqual(value['caches'], ['git'])
        self.assertFalse((home.parent / 'private/registry').exists())

    def test_unscoped_aliases_keep_source_only_and_omit_redundant_trees(self):
        home, external, _, _, _ = self.fixture(with_git=True)
        src = external / 'src' / REGISTRY
        src.mkdir(parents=True)
        (src / 'demo_dep-1.0.0').symlink_to(self.work / 'unused-expanded-copy')
        (src / 'source_only-1.0.0').mkdir()
        (src / 'source_only-1.0.0/lib.rs').write_text('owned source-only cache')
        destination = home.parent / 'private'
        _, receipt = self.snapshot(home, destination)
        names = [row['path'] for row in receipt['inventory']['files']]
        self.assertIn('registry/src/' + REGISTRY + '/source_only-1.0.0/lib.rs', names)
        self.assertFalse(any('demo_dep-1.0.0/' in name or name.startswith('git/checkouts/') for name in names))

    def test_plain_and_relocated_layouts_produce_identical_inventories(self):
        home, direct, _, lock, _ = self.fixture(alias=False)
        _, first = self.snapshot(home, home.parent / 'first', lock)
        external = home.parent / 'moved-registry'
        direct.rename(external)
        (home / 'registry').symlink_to(external, target_is_directory=True)
        _, second = self.snapshot(home, home.parent / 'second', lock)
        self.assertEqual(first['inventory'], second['inventory'])
        self.assertEqual(first['selection'], second['selection'])

    def test_existing_broken_aliases_are_not_empty_cold_caches(self):
        for kind in ('missing', 'file', 'loop'):
            home, _, _, lock, _ = self.fixture()
            (home / 'registry').rename(home / 'preserved-registry-link')
            target = home.parent / 'missing'
            if kind == 'file':
                target.write_text('not a directory')
            if kind == 'loop':
                target = home / 'registry'
            (home / 'registry').symlink_to(target)
            destination = home.parent / 'private'
            for scoped in (False, True):
                result = self.call('snapshot', home, destination, *([lock] if scoped else []))
                self.assertNotEqual(result.returncode, 0, kind)
                self.assertEqual(result.stdout, b'')
                self.assertFalse(destination.exists())

    def test_nested_links_and_linked_downloads_stay_refused(self):
        for kind in ('category', 'download'):
            home, external, download, lock, _ = self.fixture()
            source = external / 'cache' if kind == 'category' else download
            preserved = home.parent / ('saved-' + kind)
            source.rename(preserved)
            source.symlink_to(preserved, target_is_directory=kind == 'category')
            result = self.call('snapshot', home, home.parent / 'private', lock)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'')
            self.assertFalse((home.parent / 'private').exists())

    def test_prepared_private_seed_and_private_verifier_reject_root_links(self):
        home, _, _, lock, _ = self.fixture()
        first = home.parent / 'first'
        value, _ = self.snapshot(home, first, lock)
        original_receipt = Path(value['receipt_path']).read_bytes()
        moved = home.parent / 'moved-private-registry'
        (first / 'registry').rename(moved)
        (first / 'registry').symlink_to(moved, target_is_directory=True)
        self.assertNotEqual(self.call('verify', first, value['receipt_path']).returncode, 0)
        self.assertNotEqual(self.call('inventory', first, home.parent / 'new-receipt').returncode, 0)
        for scoped in (False, True):
            result = self.call('snapshot', first, home.parent / 'second', *([lock] if scoped else []))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'private cache root', result.stderr)
        self.assertEqual(Path(value['receipt_path']).read_bytes(), original_receipt)

    def test_destination_must_not_overlap_a_physical_cache_root(self):
        home, external, download, lock, _ = self.fixture()
        before = download.read_bytes()
        result = self.call('snapshot', home, external / 'new-private', lock)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertFalse((external / 'new-private').exists())
        self.assertEqual(download.read_bytes(), before)

    def test_wrong_archive_hash_is_not_selected(self):
        home, _, download, lock, _ = self.fixture()
        download.write_bytes(b'not the locked archive')
        value, _ = self.snapshot(home, home.parent / 'private', lock)
        self.assertEqual(value['file_count'], 0)
        self.assertFalse((home.parent / 'private/registry').exists())
        # An empty seed is not offline dependency admission; that remains the
        # responsibility of the subsequent genuine Cargo metadata/source gate.

    def test_empty_source_and_unrelated_alias_stay_unused(self):
        value, _ = self.snapshot('', self.work / 'empty')
        self.assertEqual(value['file_count'], 0)
        home, _, _, lock, _ = self.fixture()
        (home / 'git').symlink_to(self.work / 'missing-git')
        value, _ = self.snapshot(home, home.parent / 'private', lock)
        self.assertEqual(value['caches'], ['registry'])

    def definitions(self):
        text = SOURCE.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        parsed = ast.parse(text)
        values = dict(os=os, stat=stat)
        selected = [node for node in parsed.body if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and
                    node.name in ('Failure', 'identity', 'directory_identity', 'inside', 'CacheSourceRoots')]
        exec(compile(ast.Module(body=selected, type_ignores=[]), str(MODULE), 'exec'), values)
        if 'CacheSourceRoots' not in values:
            self.skipTest('baseline has no held ambient-root API; CLI counterexamples remain active')
        return values

    def test_retargeted_alias_is_refused_even_with_identical_bytes(self):
        values = self.definitions()
        home, external, _, _, _ = self.fixture()
        other = home.parent / 'other'
        shutil.copytree(external, other)
        roots = values['CacheSourceRoots'](str(home), str(home.parent / 'private'))
        try:
            fd = roots.open('registry')
            self.assertEqual(os.fstat(fd).st_ino, external.stat().st_ino)
            os.close(fd)
            (home / 'registry').rename(home / 'preserved-link')
            (home / 'registry').symlink_to(other, target_is_directory=True)
            with self.assertRaises(values['Failure']):
                roots.verify()
        finally:
            roots.close()

    def test_replaced_physical_root_and_home_are_refused(self):
        values = self.definitions()
        for changed in ('root', 'home'):
            home, external, _, _, _ = self.fixture()
            roots = values['CacheSourceRoots'](str(home), str(home.parent / 'private'))
            try:
                os.close(roots.open('registry'))
                path = external if changed == 'root' else home
                path.rename(home.parent / ('preserved-' + changed))
                path.mkdir()
                with self.assertRaises(values['Failure']):
                    roots.verify()
            finally:
                roots.close()

    def test_missing_root_appearance_and_preparation_marker_are_refused(self):
        values = self.definitions()
        for changed in ('git', '.dsr-cache-seed.json'):
            home, _, _, _, _ = self.fixture()
            roots = values['CacheSourceRoots'](str(home), str(home.parent / 'private'))
            try:
                if changed == 'git':
                    with self.assertRaises(FileNotFoundError):
                        roots.open('git')
                    (home / changed).mkdir()
                else:
                    os.close(roots.open('registry'))
                    (home / changed).write_text('{}')
                with self.assertRaises(values['Failure']):
                    roots.verify()
            finally:
                roots.close()

    def test_source_alias_roots_cannot_overlap_each_other(self):
        home, external, _, _, _ = self.fixture()
        (home / 'git').symlink_to(external, target_is_directory=True)
        result = self.call('snapshot', home, home.parent / 'private')
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertFalse((home.parent / 'private').exists())

    def test_generated_remote_function_carries_the_same_root_policy(self):
        home, _, _, lock, _ = self.fixture(relative=True)
        emitted = run('bash', '-c', 'source "$1"; declare -f _cargo_cache_run', '_', MODULE)
        self.assertEqual(emitted.returncode, 0)
        destination = home.parent / 'remote-private'
        program = emitted.stdout.decode() + '\n_cargo_cache_run "$@"\n'
        result = run('bash', '-c', program, '_', 'snapshot', home, destination, lock)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['file_count'], 3)
        self.assertFalse((destination / 'registry').is_symlink())


if __name__ == '__main__':
    unittest.main(verbosity=2)
PY
