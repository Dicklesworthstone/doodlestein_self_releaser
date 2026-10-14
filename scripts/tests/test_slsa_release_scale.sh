#!/usr/bin/env bash
# Exercise the real standalone SLSA producer/verifier with owned payloads.
# The input manifest is synthetic producer evidence, not compiler attestation.
# No network, compiler, signer, or production function is substituted.
set -uo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dependency in python3 jq; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'SKIP: missing %s\n' "$dependency"
        exit 0
    fi
done
python3 -I - "$@" "${DSR_TEST_SLSA_MODULE:-$PROJECT_ROOT/src/slsa.sh}" <<'PY'
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

MODULE = str(Path(sys.argv.pop()).resolve())
REPOSITORY = 'example/scale-fixture'
BUILDER = 'https://example.invalid/dsr-test-builder'


class ReleaseScaleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Retain only newly created, owned fixtures for failure investigation.
        # The suite never edits a checkout, existing statement or real release.
        cls.root = Path(tempfile.mkdtemp(prefix='dsr-slsa-scale-'))
        cls.assets = cls.root / 'assets'
        cls.assets.mkdir()
        rows = []
        for number in range(8):
            name = 'package-%04d-' % number + 'x' * 167 + '.tar.gz'
            payload = ('owned regression payload %d\n' % number).encode() + b'x' * number
            (cls.assets / name).write_bytes(payload)
            rows.append(dict(name=name, sha256=hashlib.sha256(payload).hexdigest(),
                             target='linux/amd64', size_bytes=len(payload),
                             archive_format='tar.gz'))
        cls.manifest_data = dict(
            schema_version='1.0.0', status='success', tool='scale-fixture',
            version='v1.0.0', run_id='owned-fixture-run',
            built_at='2026-10-14T00:00:00Z',
            source=dict(git_sha='1' * 40, git_ref='refs/tags/v1.0.0', dependencies=[
                dict(relative_path='sibling-%04d-' % number + 's' * 100,
                     git_sha='2' * 40) for number in range(1024)]),
            artifacts=rows, summary=dict(total=1, success=1, failed=0))
        cls.manifest = cls.root / 'manifest.json'
        cls.manifest.write_text(json.dumps(cls.manifest_data), encoding='utf-8')
        cls.proof = cls.root / 'release.intoto.jsonl'
        result = cls.invoke('generate-manifest', cls.manifest, cls.assets,
                            '--repository', REPOSITORY, '--builder', BUILDER,
                            '--output', cls.proof)
        if result.returncode:
            raise RuntimeError('Production generation failed: ' + result.stderr)
        cls.original = cls.proof.read_bytes()
        cls.document = json.loads(cls.original)
        if len(cls.original) <= 131072:
            raise RuntimeError('Fixture no longer exercises large statement transport')
        print('Owned fixture: %s (%d statement bytes)' % (cls.root, len(cls.original)),
              file=sys.stderr)

    @staticmethod
    def invoke(*arguments):
        return subprocess.run(['bash', MODULE, *map(str, arguments)],
                              text=True, capture_output=True, timeout=60)

    def verify(self, proof=None, manifest=None):
        return self.invoke('verify-release', proof or self.proof, self.assets,
                           '--manifest', manifest or self.manifest,
                           '--repository', REPOSITORY, '--builder', BUILDER)

    def write_json(self, name, document):
        path = self.root / name
        path.write_text(json.dumps(document, indent=2), encoding='utf-8')
        return path

    def test_full_generation_binds_all_payloads(self):
        expected = {row['name']: row['sha256'] for row in self.manifest_data['artifacts']}
        actual = {row['name']: row['digest']['sha256'] for row in self.document['subject']}
        self.assertEqual(actual, expected)
        self.assertEqual(self.document['dsr_evidence']['manifest_sha256'],
                         hashlib.sha256(self.manifest.read_bytes()).hexdigest())

    def test_large_manifest_verifies(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.proof.read_bytes(), self.original)

    def test_pretty_printed_statement_remains_equivalent(self):
        pretty = self.write_json('pretty.intoto.jsonl', self.document)
        result = self.verify(proof=pretty)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_changed_last_payload_is_detected_after_manifest_comparison(self):
        path = self.assets / self.manifest_data['artifacts'][-1]['name']
        original = path.read_bytes()
        try:
            path.write_bytes(b'!' * len(original))
            result = self.verify()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Release digest mismatch', result.stderr)
            self.assertEqual(self.proof.read_bytes(), self.original)
        finally:
            path.write_bytes(original)

    def test_stale_run_is_refused_without_replacing_proof(self):
        altered = copy.deepcopy(self.document)
        altered['predicate']['runDetails']['metadata']['invocationId'] = 'other-run'
        stale = self.write_json('stale.intoto.jsonl', altered)
        before = stale.read_bytes()
        result = self.verify(proof=stale)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Statement differs', result.stderr)
        self.assertEqual(stale.read_bytes(), before)

    def test_removed_subject_is_refused(self):
        altered = copy.deepcopy(self.document)
        altered['subject'].pop()
        stale = self.write_json('incomplete.intoto.jsonl', altered)
        result = self.verify(proof=stale)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.proof.read_bytes(), self.original)

    def test_failed_manifest_cannot_qualify_an_existing_statement(self):
        altered = copy.deepcopy(self.manifest_data)
        altered['status'] = 'failed'
        failed = self.write_json('failed-manifest.json', altered)
        result = self.verify(manifest=failed)
        self.assertNotEqual(result.returncode, 0)

    def test_multiple_json_documents_are_refused(self):
        path = self.root / 'ambiguous.intoto.jsonl'
        path.write_bytes(self.original + self.original)
        result = self.verify(proof=path)
        self.assertNotEqual(result.returncode, 0)

    def test_idempotent_generation_preserves_statement_bytes(self):
        result = self.invoke('generate-manifest', self.manifest, self.assets,
                             '--repository', REPOSITORY, '--builder', BUILDER,
                             '--output', self.proof)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.proof.read_bytes(), self.original)

    def test_manifest_size_inventory_is_complete_and_typed(self):
        def altered_inventory():
            return copy.deepcopy(self.document)

        cases = []
        missing = altered_inventory()
        missing['dsr_evidence']['artifacts'].pop()
        cases.append(('missing-record', missing))
        duplicate = altered_inventory()
        duplicate['dsr_evidence']['artifacts'][-1] = copy.deepcopy(
            duplicate['dsr_evidence']['artifacts'][0])
        cases.append(('duplicate-record', duplicate))
        foreign = altered_inventory()
        foreign['dsr_evidence']['artifacts'][-1]['name'] = 'foreign-asset'
        cases.append(('foreign-record', foreign))
        absent = altered_inventory()
        del absent['dsr_evidence']['artifacts']
        cases.append(('absent-inventory', absent))
        for index, value in enumerate((None, 0, -1, 1.5, '27', True, 2**53)):
            altered = altered_inventory()
            altered['dsr_evidence']['artifacts'][-1]['size_bytes'] = value
            cases.append(('invalid-size-%d' % index, altered))
        wrong = altered_inventory()
        wrong['dsr_evidence']['artifacts'][-1]['size_bytes'] += 1
        cases.append(('wrong-size', wrong))
        for name, document in cases:
            with self.subTest(name=name):
                proof = self.write_json(name + '.intoto.jsonl', document)
                before = proof.read_bytes()
                # Exercise the inventory verifier itself, rather than having
                # --manifest reject the edited statement before size checks.
                result = self.invoke('verify-release', proof, self.assets,
                                     '--builder', BUILDER)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(proof.read_bytes(), before)

    def test_size_records_join_by_name_not_position(self):
        document = copy.deepcopy(self.document)
        document['dsr_evidence']['artifacts'].reverse()
        proof = self.write_json('reordered-sizes.intoto.jsonl', document)
        result = self.invoke('verify-release', proof, self.assets, '--builder', BUILDER)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_observations_without_sizes_preserve_literal_names_and_empty_files(self):
        for index, (name, payload) in enumerate((('space name.bin', b'spaces'),
                                               ('unicode-\u03a9.bin', b'unicode'),
                                               ('empty.bin', b''))):
            with self.subTest(name=name):
                artifact = self.assets / name
                artifact.write_bytes(payload)
                proof = self.root / ('observation-%d.intoto.jsonl' % index)
                generated = self.invoke('generate', artifact, '--output', proof)
                self.assertEqual(generated.returncode, 0, generated.stderr)
                result = self.invoke('verify-release', proof, self.assets)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_inventory_parsing_does_not_launch_jq_for_each_asset(self):
        result = subprocess.run(
            ['bash', '-x', MODULE, 'verify-release', str(self.proof), str(self.assets)],
            text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        # Trace actual jq processes: do not replace jq or mirror its predicates.
        calls = re.findall(r'^\++ jq(?: |$)', result.stderr, flags=re.MULTILINE)
        self.assertLessEqual(len(calls), 10, 'per-asset jq execution returned')

    def test_many_asset_release_round_trip(self):
        root = self.root / 'asset-heavy'
        root.mkdir()
        rows = []
        for number in range(64):
            name = 'asset-%04d-' % number + 'a' * 167 + '.tar.gz'
            payload = b'owned asset-heavy fixture\n' + b'x' * number
            (root / name).write_bytes(payload)
            rows.append(dict(name=name, sha256=hashlib.sha256(payload).hexdigest(),
                             target='linux/amd64', size_bytes=len(payload),
                             archive_format='tar.gz'))
        manifest_data = copy.deepcopy(self.manifest_data)
        manifest_data['artifacts'] = rows
        manifest = self.write_json('asset-heavy-manifest.json', manifest_data)
        proof = self.root / 'asset-heavy.intoto.jsonl'
        generated = self.invoke('generate-manifest', manifest, root,
                                '--repository', REPOSITORY, '--builder', BUILDER,
                                '--output', proof)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        before = proof.read_bytes()
        self.assertGreater(len(before), 131072)
        verified = self.invoke('verify-release', proof, root, '--manifest', manifest,
                               '--repository', REPOSITORY, '--builder', BUILDER)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        document = json.loads(before)
        self.assertEqual(len(document['subject']), 64)
        self.assertEqual(proof.read_bytes(), before)


class SharedAssetTests(unittest.TestCase):
    """Real payload/proof IO with synthetic native-producer metadata."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='dsr-slsa-shared-')).resolve()
        self.assets = self.root / 'assets'
        self.assets.mkdir()
        self.serial = 0
        self.data = dict(schema_version='1.0.0', status='success', tool='demo',
                         version='v1.0.0', run_id='shared-fixture-run',
                         built_at='2026-10-14T00:00:00Z', build_purpose='release', publishable=True,
                         source=dict(git_sha='1' * 40, git_ref='refs/tags/v1.0.0', dependencies=[]),
                         requested_targets=['linux/amd64'], summary=dict(total=1, success=1, failed=0),
                         artifacts=[], build_environments=[dict(target='linux/amd64', method='native', host='fixture')],
                         hosts=[dict(platform='linux/amd64', status='success')])
        self.add_asset('demo-linux', b'owned primary payload', 'linux/amd64')
        self.add_asset('release-notes.txt', b'owned shared notes', 'additional')
        self.add_asset('companion.json', b'{"fixture":true}\n', 'additional')

    def add_asset(self, name, payload, target, triple=None):
        (self.assets / name).write_bytes(payload)
        row = dict(name=name, target=target, archive_format='binary',
                   sha256=hashlib.sha256(payload).hexdigest(), size_bytes=len(payload))
        if triple is not None:
            row['target_triple'] = triple
        self.data['artifacts'].append(row)
        return row

    def required_assets(self):
        self.data['required_assets'] = [{k: row[k] for k in ('name', 'target', 'archive_format', 'target_triple') if k in row}
                                        for row in self.data['artifacts']]

    def generate(self, data=None):
        self.serial += 1
        manifest = self.root / ('manifest-%d.json' % self.serial)
        proof = self.root / ('proof-%d.intoto.jsonl' % self.serial)
        manifest.write_text(json.dumps(self.data if data is None else data), encoding='utf-8')
        result = ReleaseScaleTests.invoke('generate-manifest', manifest, self.assets,
                                         '--repository', REPOSITORY, '--builder', BUILDER, '--output', proof)
        return result, manifest, proof

    def accepted(self):
        result, manifest, proof = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(proof.read_bytes())
        self.assertEqual({row['name']: row['digest']['sha256'] for row in document['subject']},
                         {row['name']: row['sha256'] for row in self.data['artifacts']})
        self.assertEqual(document['dsr_evidence']['manifest_sha256'],
                         hashlib.sha256(manifest.read_bytes()).hexdigest())
        self.assertEqual(document['predicate']['buildDefinition']['externalParameters']['targets'],
                         sorted(self.data['requested_targets']))
        result = ReleaseScaleTests.invoke('verify-release', proof, self.assets, '--manifest', manifest,
                                         '--repository', REPOSITORY, '--builder', BUILDER)
        self.assertEqual(result.returncode, 0, result.stderr)
        return manifest, proof, document

    def refused(self, data):
        before = {p.name: p.read_bytes() for p in self.assets.iterdir()}
        result, _, proof = self.generate(data)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertFalse(proof.exists())
        self.assertEqual({p.name: p.read_bytes() for p in self.assets.iterdir()}, before)

    def test_shared_payloads_do_not_create_a_build_task(self):
        self.required_assets()
        _, _, doc = self.accepted()
        self.assertEqual(doc['dsr_evidence']['build_environment_count'], 1)
        self.assertNotIn('build_tasks', doc['dsr_evidence'])
        shared = [a for a in doc['dsr_evidence']['artifacts'] if a['target'] == 'additional']
        self.assertEqual(len(shared), 2)
        self.assertTrue(all('target_triple' not in a for a in shared))

    def test_multiple_platforms_keep_exact_coverage(self):
        self.add_asset('demo-darwin', b'owned darwin fixture', 'darwin/arm64')
        self.data['requested_targets'].append('darwin/arm64')
        self.data['build_environments'].append(dict(target='darwin/arm64', method='native', host='other-fixture'))
        self.data['hosts'].append(dict(platform='darwin/arm64', status='success'))
        self.data['summary'].update(total=2, success=2)
        self.required_assets()
        self.accepted()

    def test_shared_payloads_with_native_gnu_musl_variants(self):
        gnu, musl = 'x86_64-unknown-linux-gnu', 'x86_64-unknown-linux-musl'
        self.data['artifacts'][0]['target_triple'] = gnu
        self.add_asset('demo-musl', b'owned musl fixture', 'linux/amd64', musl)
        variants = [dict(target='linux/amd64', target_triple=t) for t in (gnu, musl)]
        self.data['required_variants'] = variants
        self.data['build_environments'] = [dict(v, method='native', host='fixture',
                                               build_influence_env=dict(CARGO_BUILD_TARGET=v['target_triple'])) for v in variants]
        self.data['hosts'] = [dict(platform=v['target'], target_triple=v['target_triple'], status='success') for v in variants]
        self.data['summary'].update(total=2, success=2)
        self.required_assets()
        _, _, doc = self.accepted()
        self.assertEqual(doc['dsr_evidence']['build_tasks'], variants)
        self.assertEqual([a['target_triple'] for a in doc['dsr_evidence']['artifacts'] if a['target'] != 'additional'],
                         [gnu, musl])
        for label, mutation in [('missing-environment', lambda d: d['build_environments'].pop()),
                                ('missing-variant', lambda d: d['required_variants'].pop()),
                                ('shared-variant', lambda d: d['required_variants'].append(dict(target='additional', target_triple=gnu)))]:
            with self.subTest(label=label):
                bad = copy.deepcopy(self.data)
                mutation(bad)
                self.refused(bad)

    def test_shared_only_is_not_a_platform_release(self):
        bad = copy.deepcopy(self.data)
        bad['artifacts'] = bad['artifacts'][1:]
        bad.pop('requested_targets')
        bad.pop('build_environments')
        bad.pop('hosts')
        bad['summary'].update(total=0, success=0)
        self.refused(bad)

    def test_shared_identity_cannot_claim_a_compiler(self):
        for value in (None, '', 'x86_64-unknown-linux-gnu'):
            with self.subTest(value=value):
                bad = copy.deepcopy(self.data)
                bad['artifacts'][1]['target_triple'] = value
                self.refused(bad)
        self.required_assets()
        bad = copy.deepcopy(self.data)
        bad['required_assets'][1]['target_triple'] = None
        self.refused(bad)

    def test_shared_assets_cannot_satisfy_or_inflate_platform_coverage(self):
        mutations = [lambda d: d['requested_targets'].append('additional'),
                     lambda d: d['requested_targets'].append('darwin/arm64'),
                     lambda d: d['summary'].update(total=3, success=3),
                     lambda d: d['hosts'].append(dict(platform='additional', status='success')),
                     lambda d: d['build_environments'].append(dict(target='additional', method='native'))]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                bad = copy.deepcopy(self.data)
                mutation(bad)
                self.refused(bad)

    def test_shared_payload_contract_remains_exact(self):
        self.required_assets()
        mutations = [lambda d: d['required_assets'].pop(),
                     lambda d: d['artifacts'].pop(),
                     lambda d: d['required_assets'][1].update(archive_format='zip'),
                     lambda d: d['required_assets'][1].update(target='linux/amd64'),
                     lambda d: d['artifacts'][1].update(name=d['artifacts'][0]['name']),
                     lambda d: d['artifacts'][1].update(target='shared'),
                     lambda d: d['artifacts'][1].update(publishable=False),
                     lambda d: d['artifacts'][1].update(build_purpose='diagnostic')]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                bad = copy.deepcopy(self.data)
                mutation(bad)
                self.refused(bad)

    def test_every_shared_payload_is_reverified_and_old_proof_preserved(self):
        manifest, proof, _ = self.accepted()
        original = proof.read_bytes()
        path = self.assets / 'release-notes.txt'
        path.rename(self.root / 'preserved-notes')
        for kind in ('missing', 'link', 'changed'):
            with self.subTest(kind=kind):
                if kind == 'link':
                    path.symlink_to(self.root / 'preserved-notes')
                elif kind == 'changed':
                    path.write_bytes(b'wrong shared notes')
                result = ReleaseScaleTests.invoke('verify-release', proof, self.assets, '--manifest', manifest,
                                                 '--repository', REPOSITORY, '--builder', BUILDER)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(proof.read_bytes(), original)
                if path.exists() or path.is_symlink():
                    path.rename(self.root / ('preserved-' + kind))

    def test_removed_shared_subject_cannot_match_the_manifest(self):
        manifest, proof, document = self.accepted()
        document['subject'] = [row for row in document['subject'] if row['name'] != 'companion.json']
        reduced = self.root / 'reduced.intoto.jsonl'
        reduced.write_text(json.dumps(document), encoding='utf-8')
        result = ReleaseScaleTests.invoke('verify-release', reduced, self.assets, '--manifest', manifest,
                                         '--repository', REPOSITORY, '--builder', BUILDER)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
PY
