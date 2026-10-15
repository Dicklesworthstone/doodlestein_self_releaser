#!/usr/bin/env bash
# Real Git source-link admission. No compiler, SDK, network or Windows claims.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for dependency in python3 git; do
    command -v "$dependency" >/dev/null || { printf 'Missing %s\n' "$dependency" >&2; exit 3; }
done
python3 - "${XWIN_TEST_ROOT:-$ROOT}" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop()).resolve()
MODULE = ROOT / 'src/xwin_source.sh'
ENV = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
ENV.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
           GIT_TERMINAL_PROMPT='0', LC_ALL='C')


def digest(value):
    raw = (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()
    return hashlib.sha256(raw).hexdigest()


class SourceLinks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dsr-source-links-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.project = self.make_project('primary', 'demo')
        self.snapshot = self.work / 'snapshot'
        self.receipt = self.work / 'source.json'

    def git(self, project, *args, data=None):
        return subprocess.run(['git', '-C', str(project), *args], input=data, env=ENV,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout

    def make_project(self, name, repo):
        project = self.work / name
        (project / 'src').mkdir(parents=True)
        self.git(project, 'init', '-q', '-b', 'main')
        self.git(project, 'config', 'user.name', 'DSR source link test')
        self.git(project, 'config', 'user.email', 'test@example.invalid')
        self.git(project, 'remote', 'add', 'origin', f'https://github.com/owner/{repo}.git')
        (project / 'Cargo.toml').write_text(f'[package]\nname="{repo}"\nversion="1.2.3"\n')
        (project / 'Cargo.lock').write_text('version = 3\n')
        (project / 'src/main.rs').write_text('fn main() {}\n')
        (project / 'AGENTS.md').write_text('committed release instructions\n')
        (project / '.gitignore').write_text('ignored.txt\n')
        (project / 'ignored.txt').write_text('not a committed release input\n')
        (project / 'build-helper').write_text('#!/bin/sh\nexit 0\n')
        (project / 'build-helper').chmod(0o755)
        return project

    def link(self, name, target, project=None):
        project = project or self.project
        path = project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)

    def seal(self, project=None):
        project = project or self.project
        self.git(project, 'add', '.')
        self.git(project, 'commit', '-qm', 'committed fixture')
        self.git(project, 'tag', 'v1.2.3')
        return self.git(project, 'rev-parse', 'HEAD').decode().strip()

    def call(self, function, *args):
        return subprocess.run(['bash', '-c', 'source "$1"; shift; "$@"',
                               'xwin-source-test', str(MODULE), function, *map(str, args)],
                              env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    def capture(self, sha, expected=0):
        result = self.call('xwin_source_snapshot', self.project, sha, 'v1.2.3',
                           'owner/demo', self.snapshot, self.receipt)
        self.assertEqual(result.returncode, expected, result.stderr.decode())
        self.assertEqual(result.stdout, b'')
        if expected:
            self.assertFalse(self.snapshot.exists(), result.stderr.decode())
            self.assertFalse(self.receipt.exists())
            return None
        evidence = json.loads(self.receipt.read_text())
        self.assertEqual(evidence['snapshot_sha256'], digest(evidence['files']))
        self.assertEqual(self.call('xwin_source_verify', self.snapshot, self.receipt).returncode, 0)
        return evidence

    def rows(self, evidence):
        return {entry['path']: entry for entry in evidence['files']}

    def reject_evidence(self, evidence):
        path = self.work / 'modified-receipt.json'
        path.write_text(json.dumps(evidence))
        result = self.call('xwin_source_verify', self.snapshot, path)
        self.assertEqual(result.returncode, 7, result.stderr.decode())
        self.assertEqual(result.stdout, b'')
        self.assertNotIn(b'Traceback', result.stderr)

    def test_ordinary_source_keeps_existing_inventory_shape(self):
        evidence = self.capture(self.seal())
        self.assertTrue(all(set(row) == {'path', 'sha256', 'size_bytes', 'executable'}
                            for row in evidence['files']))
        self.assertFalse((self.snapshot / 'ignored.txt').exists())

    def test_relative_file_links_are_regular_authenticated_copies(self):
        self.link('CLAUDE.md', 'AGENTS.md')
        self.link('docs/policy', '../AGENTS.md')
        evidence = self.capture(self.seal())
        rows = self.rows(evidence)
        for name in ('CLAUDE.md', 'docs/policy'):
            with self.subTest(path=name):
                self.assertFalse((self.snapshot / name).is_symlink())
                self.assertEqual((self.snapshot / name).read_bytes(), (self.snapshot / 'AGENTS.md').read_bytes())
                link = rows[name]['symlink']
                self.assertEqual(link['resolved_path'], 'AGENTS.md')
                self.assertEqual(link['git_blob'], self.git(self.project, 'rev-parse', 'HEAD:' + name).decode().strip())
                self.assertEqual(link['resolved_git_blob'], self.git(self.project, 'rev-parse', 'HEAD:AGENTS.md').decode().strip())

    def test_link_chain_and_executable_mode(self):
        self.link('docs/policy', '../AGENTS.md')
        self.link('CLAUDE.md', './docs/../docs/policy')
        self.link('tools/run', '../build-helper')
        rows = self.rows(self.capture(self.seal()))
        self.assertEqual(rows['CLAUDE.md']['symlink']['resolved_path'], 'AGENTS.md')
        self.assertTrue(rows['tools/run']['executable'])
        self.assertEqual((self.snapshot / 'tools/run').stat().st_mode & 0o777, 0o755)

    def test_working_tree_cannot_replace_link_or_target_authority(self):
        self.link('CLAUDE.md', 'AGENTS.md')
        sha = self.seal()
        self.git(self.project, 'update-index', '--assume-unchanged', 'AGENTS.md', 'CLAUDE.md')
        (self.project / 'AGENTS.md').write_text('uncommitted hidden bytes\n')
        (self.project / 'CLAUDE.md').unlink()
        self.link('CLAUDE.md', 'ignored.txt')
        self.assertEqual(self.git(self.project, 'status', '--porcelain=v1'), b'')
        rows = self.rows(self.capture(sha))
        self.assertEqual(rows['CLAUDE.md']['symlink']['target'], 'AGENTS.md')
        self.assertEqual((self.snapshot / 'CLAUDE.md').read_text(), 'committed release instructions\n')

    def test_export_attributes_cannot_omit_or_substitute_link_targets(self):
        self.link('CLAUDE.md', 'AGENTS.md')
        (self.project / '.gitattributes').write_text('AGENTS.md export-ignore\nCLAUDE.md export-subst\n')
        evidence = self.capture(self.seal())
        self.assertIn('AGENTS.md', self.rows(evidence))
        self.assertEqual((self.snapshot / 'CLAUDE.md').read_text(), 'committed release instructions\n')

    def test_git_symlink_stubs_do_not_require_worktree_link_support(self):
        self.git(self.project, 'config', 'core.symlinks', 'false')
        (self.project / 'CLAUDE.md').write_text('AGENTS.md')
        self.git(self.project, 'add', '.')
        oid = self.git(self.project, 'hash-object', '-w', '--stdin', data=b'AGENTS.md').decode().strip()
        self.git(self.project, 'update-index', '--cacheinfo', f'120000,{oid},CLAUDE.md')
        self.git(self.project, 'commit', '-qm', 'committed Git symlink with plain worktree stub')
        self.git(self.project, 'tag', 'v1.2.3')
        sha = self.git(self.project, 'rev-parse', 'HEAD').decode().strip()
        evidence = self.capture(sha)
        self.assertEqual(self.rows(evidence)['CLAUDE.md']['symlink']['git_blob'], oid)
        self.assertEqual((self.snapshot / 'CLAUDE.md').read_text(), 'committed release instructions\n')

    def test_unsafe_uncommitted_or_directory_targets_fail_before_writes(self):
        targets = ['/etc/passwd', '../outside', 'src/../../primary/AGENTS.md',
                   'C:/Windows/file', r'C:\Windows\file', r'\\server\share',
                   'ignored.txt', 'missing', 'src', '.', 'AGENTS.md/../src/main.rs',
                   'AGENTS.md/', 'src//main.rs', '.git/config', 'AGENTS.md\n']
        for index, target in enumerate(targets):
            with self.subTest(target=target):
                project = self.make_project('bad-' + str(index), 'demo')
                self.link('CLAUDE.md', target, project)
                self.project = project
                self.capture(self.seal(project), expected=4)

    def test_empty_and_nul_git_link_objects_fail_before_writes(self):
        for index, target in enumerate((b'', b'AGENTS.md\0ignored.txt')):
            with self.subTest(target=target):
                project = self.make_project('invalid-link-' + str(index), 'demo')
                self.git(project, 'config', 'core.symlinks', 'false')
                (project / 'CLAUDE.md').write_bytes(target)
                self.git(project, 'add', '.')
                oid = self.git(project, 'hash-object', '-w', '--stdin', data=target).decode().strip()
                self.git(project, 'update-index', '--cacheinfo', f'120000,{oid},CLAUDE.md')
                self.git(project, 'commit', '-qm', 'invalid link object')
                self.git(project, 'tag', 'v1.2.3')
                self.project = project
                self.capture(self.git(project, 'rev-parse', 'HEAD').decode().strip(), expected=4)

    def test_cycles_are_rejected_with_the_link_path(self):
        self.link('CLAUDE.md', 'docs/loop')
        self.link('docs/loop', '../CLAUDE.md')
        self.capture(self.seal(), expected=4)
        self.assertFalse(self.snapshot.exists())

    def test_chain_bound_accepts_40_and_refuses_41_links(self):
        for index in range(40):
            self.link('link-' + str(index), 'link-' + str(index + 1) if index < 39 else 'AGENTS.md')
        rows = self.rows(self.capture(self.seal()))
        self.assertEqual(rows['link-0']['symlink']['resolved_path'], 'AGENTS.md')
        self.link('too-long', 'link-0')
        self.git(self.project, 'add', 'too-long')
        self.git(self.project, 'commit', '-qm', 'excessive chain')
        self.git(self.project, 'tag', 'v1.2.4')
        sha = self.git(self.project, 'rev-parse', 'HEAD').decode().strip()
        result = self.call('xwin_source_snapshot', self.project, sha, 'v1.2.4', 'owner/demo',
                           self.work / 'excessive', self.work / 'excessive.json')
        self.assertEqual(result.returncode, 4, result.stderr.decode())
        self.assertIn(b'too-long', result.stderr)
        self.assertFalse((self.work / 'excessive').exists())

    def test_copy_or_original_target_drift_fails_verification(self):
        self.link('CLAUDE.md', 'AGENTS.md')
        self.capture(self.seal())
        for name in ('CLAUDE.md', 'AGENTS.md'):
            with self.subTest(path=name):
                path = self.snapshot / name
                original = path.read_bytes()
                path.write_text('drift\n')
                self.assertEqual(self.call('xwin_source_verify', self.snapshot, self.receipt).returncode, 7)
                path.write_bytes(original)
        self.assertEqual(self.call('xwin_source_verify', self.snapshot, self.receipt).returncode, 0)

    def test_restoring_a_physical_symlink_is_not_admitted(self):
        self.link('CLAUDE.md', 'AGENTS.md')
        self.capture(self.seal())
        (self.snapshot / 'CLAUDE.md').unlink()
        (self.snapshot / 'CLAUDE.md').symlink_to('AGENTS.md')
        self.assertEqual(self.call('xwin_source_verify', self.snapshot, self.receipt).returncode, 7)

    def test_transformation_evidence_is_validated_not_merely_carried(self):
        self.link('CLAUDE.md', 'AGENTS.md')
        (self.project / 'OTHER.md').write_bytes((self.project / 'AGENTS.md').read_bytes())
        original = self.capture(self.seal())
        mutations = [('target', 'OTHER.md'), ('git_blob', '0' * 40),
                     ('resolved_path', 'OTHER.md'), ('resolved_path', '../primary/AGENTS.md'),
                     ('resolved_git_blob', '0' * 40), ('target', None), ('extra', True)]
        for key, value in mutations:
            with self.subTest(field=key, value=value):
                evidence = json.loads(json.dumps(original))
                self.rows(evidence)['CLAUDE.md']['symlink'][key] = value
                # Even a rehashed inventory cannot bless inconsistent link facts.
                evidence['snapshot_sha256'] = digest(evidence['files'])
                self.reject_evidence(evidence)
        malformed = json.loads(json.dumps(original))
        self.rows(malformed)['CLAUDE.md']['symlink'] = None
        self.reject_evidence(malformed)
        malformed = json.loads(json.dumps(original))
        malformed['files'][0]['path'] = None
        self.reject_evidence(malformed)
        self.reject_evidence([])

    def test_source_set_retains_each_repository_link_and_digest(self):
        self.link('CLAUDE.md', 'AGENTS.md')
        sha = self.seal()
        sibling = self.make_project('sibling-checkout', 'lib')
        (sibling / 'AGENTS.md').write_text('independent sibling instructions\n')
        self.link('docs/policy', '../AGENTS.md', sibling)
        revision = self.seal(sibling)
        plan = self.work / 'siblings.json'
        plan.write_text(json.dumps([{'relative_path': 'lib', 'local_path': str(sibling),
                                     'revision': revision, 'repo': 'owner/lib'}]))
        result = self.call('xwin_source_snapshot_set', self.project, sha, 'v1.2.3', 'owner/demo',
                           self.snapshot, self.receipt, plan)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(self.call('xwin_source_verify', self.snapshot, self.receipt).returncode, 0)
        evidence = json.loads(self.receipt.read_text())
        rows = self.rows(evidence)
        self.assertEqual(rows['project/CLAUDE.md']['symlink']['resolved_path'], 'AGENTS.md')
        self.assertEqual(rows['lib/docs/policy']['symlink']['resolved_path'], 'AGENTS.md')
        self.assertNotEqual(rows['project/CLAUDE.md']['sha256'], rows['lib/docs/policy']['sha256'])
        self.assertEqual(evidence['snapshot_sha256'], digest(evidence['files']))
        for prefix, expected in [('project', evidence['primary_snapshot_sha256']),
                                 ('lib', evidence['dependencies'][0]['snapshot_sha256'])]:
            subset = [{**entry, 'path': entry['path'][len(prefix) + 1:]} for entry in evidence['files']
                      if entry['path'].startswith(prefix + '/')]
            self.assertEqual(digest(subset), expected)
        self.assertEqual((self.snapshot / 'lib/docs/policy').read_text(), 'independent sibling instructions\n')
        rows['lib/docs/policy']['symlink']['resolved_path'] = '../project/AGENTS.md'
        evidence['snapshot_sha256'] = digest(evidence['files'])
        self.reject_evidence(evidence)

    def test_link_cannot_cross_even_an_explicitly_pinned_sibling_boundary(self):
        self.link('CLAUDE.md', '../lib/AGENTS.md')
        sha = self.seal()
        sibling = self.make_project('lib', 'lib')
        revision = self.seal(sibling)
        plan = self.work / 'siblings.json'
        plan.write_text(json.dumps([{'relative_path': 'lib', 'local_path': str(sibling),
                                     'revision': revision, 'repo': 'owner/lib'}]))
        result = self.call('xwin_source_snapshot_set', self.project, sha, 'v1.2.3', 'owner/demo',
                           self.snapshot, self.receipt, plan)
        self.assertEqual(result.returncode, 4, result.stderr.decode())
        self.assertIn(b'CLAUDE.md', result.stderr)
        self.assertFalse(self.snapshot.exists())
        self.assertFalse(self.receipt.exists())

    def test_manifest_schema_retains_and_constrains_link_evidence(self):
        try:
            from jsonschema import Draft202012Validator
        except ImportError:
            self.skipTest('jsonschema is not installed')
        schema = json.loads((ROOT / 'schemas/manifest.json').read_text())
        Draft202012Validator.check_schema(schema)
        validator = Draft202012Validator({'$ref': '#/$defs/xwin_source_snapshot',
                                          '$defs': schema['$defs']})
        self.link('docs/policy', '../AGENTS.md')
        evidence = self.capture(self.seal())
        validator.validate(evidence)
        for key, value in [('target', '/etc/passwd'), ('target', 'AGENTS.md\n'),
                           ('git_blob', '0' * 40), ('resolved_path', '../AGENTS.md'),
                           ('resolved_git_blob', False), ('unbound', 'ignored')]:
            with self.subTest(field=key, value=value):
                changed = json.loads(json.dumps(evidence))
                self.rows(changed)['docs/policy']['symlink'][key] = value
                self.assertFalse(validator.is_valid(changed))
        for key in ('target', 'git_blob', 'resolved_path', 'resolved_git_blob'):
            with self.subTest(missing=key):
                changed = json.loads(json.dumps(evidence))
                del self.rows(changed)['docs/policy']['symlink'][key]
                self.assertFalse(validator.is_valid(changed))


unittest.main(verbosity=2)
PY
