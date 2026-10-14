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


if __name__ == '__main__':
    unittest.main(verbosity=2)
PY
