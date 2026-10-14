#!/usr/bin/env bash
# Complete release provenance for shared additional assets. Payload bytes and
# production producer/verifier are real; input build metadata is synthetic.
# No compiler or remote release is invoked. Owned test evidence is retained.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
for tool in python3 jq; do
    command -v "$tool" >/dev/null || { printf 'SKIP: missing %s\n' "$tool"; exit 0; }
done
python3 -I - "${DSR_TEST_SLSA_MODULE:-$ROOT/src/slsa.sh}" "$@" <<'PY'
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

MODULE = str(Path(sys.argv.pop(1)).resolve())
REMOTE = str(Path(os.environ.get('DSR_TEST_SLSA_REMOTE_MODULE',
                                str(Path(MODULE).with_name('slsa_remote.sh')))).resolve())
REPO = 'example/shared-assets'
BUILDER = 'https://example.invalid/fixture-builder'
SHA = '1' * 40


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SharedAssetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix='dsr-slsa-shared-')).resolve()
        print('Retained shared-asset fixtures: ' + str(cls.root), file=sys.stderr)

    def setUp(self):
        self.work = self.root / self._testMethodName
        self.work.mkdir()
        self.assets = self.work / 'assets'
        self.assets.mkdir()
        self.manifest = self.work / 'manifest.json'
        self.proof = self.work / 'release.intoto.jsonl'
        self.data = dict(schema_version='1.0.0', status='success', tool='fixture',
                         version='v1.0.0', run_id='owned-shared-fixture',
                         built_at='2026-10-14T11:30:00Z', build_purpose='release', publishable=True,
                         source=dict(git_sha=SHA, git_ref='refs/tags/v1.0.0', dependencies=[]),
                         summary=dict(total=1, success=1, failed=0),
                         requested_targets=['linux/amd64'],
                         build_environments=[dict(target='linux/amd64', method='native', host='fixture')],
                         hosts=[dict(platform='linux/amd64', status='success')], artifacts=[])
        self.add_payload('app-linux-amd64.tar.gz', 'linux/amd64', b'owned executable bytes\n', archive=True)
        self.add_payload('LICENSE', 'additional', b'owned complete license including rider\n')

    def add_payload(self, name, target, body, archive=False, triple=None):
        path = self.assets / name
        if archive:
            with tarfile.open(path, 'w:gz') as output:
                item = tarfile.TarInfo('bin/app')
                item.mode = 0o755
                item.size = len(body)
                output.addfile(item, io.BytesIO(body))
        else:
            path.write_bytes(body)
        row = dict(name=name, target=target, sha256=digest(path), size_bytes=path.stat().st_size,
                   archive_format='tar.gz' if archive else 'binary')
        if triple is not None:
            row['target_triple'] = triple
        self.data['artifacts'].append(row)
        return row

    @staticmethod
    def invoke(*args):
        environment = {k: v for k, v in os.environ.items()
                       if k not in ('BASH_ENV', 'ENV') and not k.startswith('BASH_FUNC_')}
        return subprocess.run(['bash', MODULE, *map(str, args)], env=environment,
                              capture_output=True, text=True, timeout=30)

    def generate(self, expected=0):
        self.manifest.write_text(json.dumps(self.data))
        result = self.invoke('generate-manifest', self.manifest, self.assets,
                             '--repository', REPO, '--builder', BUILDER, '--output', self.proof)
        self.assertEqual(result.returncode, expected, result.stderr)
        if expected:
            self.assertEqual(result.stdout, '')
            self.assertFalse(self.proof.exists())
            return None
        self.assertEqual(result.stdout.strip(), str(self.proof))
        return json.loads(self.proof.read_bytes())

    def verify(self, *, expected=0, manifest=True, proof=None):
        args = ['verify-release', proof or self.proof, self.assets, '--builder', BUILDER]
        if manifest:
            args += ['--manifest', self.manifest, '--repository', REPO]
        result = self.invoke(*args)
        if expected:
            self.assertNotEqual(result.returncode, 0, result.stderr)
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_shared_payload_is_hashed_without_a_phantom_build(self):
        proof = self.generate()
        self.assertEqual({s['name']: s['digest']['sha256'] for s in proof['subject']},
                         {a['name']: a['sha256'] for a in self.data['artifacts']})
        self.assertEqual(proof['predicate']['buildDefinition']['externalParameters']['targets'], ['linux/amd64'])
        self.assertEqual(proof['dsr_evidence']['build_environment_count'], 1)
        shared = next(a for a in proof['dsr_evidence']['artifacts'] if a['name'] == 'LICENSE')
        self.assertEqual(shared['target'], 'additional')
        self.assertNotIn('target_triple', shared)
        self.assertEqual(proof['dsr_evidence']['manifest_sha256'], digest(self.manifest))
        self.verify()

    def test_every_shared_payload_is_checked_before_and_after_generation(self):
        self.add_payload('readme.txt', 'additional', b'owned readme\n')
        self.generate()
        original_proof = self.proof.read_bytes()
        path = self.assets / 'readme.txt'
        original = path.read_bytes()
        path.write_bytes(b'x' * len(original))
        result = self.verify(expected=1)
        self.assertIn('Release digest mismatch: readme.txt', result.stderr)
        self.assertEqual(self.proof.read_bytes(), original_proof)
        # Generation to a fresh destination must not publish a proof either.
        self.proof = self.work / 'new-proof.intoto.jsonl'
        self.generate(expected=1)

    def test_missing_shared_payload_and_symlink_are_terminal(self):
        self.generate()
        path = self.assets / 'LICENSE'
        saved = self.work / 'retained-license'
        path.rename(saved)
        self.verify(expected=1)
        path.symlink_to(saved)
        self.verify(expected=1)
        self.assertTrue(path.is_symlink())
        self.assertEqual(saved.read_bytes(), b'owned complete license including rider\n')

    def test_shared_asset_cannot_supply_missing_platform_coverage(self):
        self.data['requested_targets'].append('darwin/arm64')
        self.generate(expected=4)

    def test_shared_only_release_is_not_a_completed_build(self):
        self.data['artifacts'] = self.data['artifacts'][1:]
        self.data.update(requested_targets=[], hosts=[], build_environments=[],
                         summary=dict(total=0, success=0, failed=0))
        self.generate(expected=4)

    def test_shared_asset_cannot_carry_compiler_or_task_identity(self):
        for i, value in enumerate((None, '', 'x86_64-unknown-linux-gnu')):
            with self.subTest(triple=value):
                self.proof = self.work / ('invalid-%d.intoto.jsonl' % i)
                self.data['artifacts'][1]['target_triple'] = value
                self.generate(expected=4)

    def test_shared_label_cannot_inflate_success_or_host_receipts(self):
        for i, change in enumerate(('count', 'environment', 'host', 'requested')):
            original = copy.deepcopy(self.data)
            with self.subTest(change=change):
                if change == 'count':
                    self.data['summary'].update(total=2, success=2)
                elif change == 'environment':
                    self.data['build_environments'].append(dict(target='additional', method='native'))
                elif change == 'host':
                    self.data['hosts'].append(dict(platform='additional', status='success'))
                else:
                    self.data['requested_targets'].append('additional')
                self.proof = self.work / ('invalid-%d.intoto.jsonl' % i)
                self.generate(expected=4)
            self.data = original

    def test_shared_payloads_coexist_with_exact_native_abi_matrix(self):
        gnu, musl = 'x86_64-unknown-linux-gnu', 'x86_64-unknown-linux-musl'
        self.data['artifacts'][0]['target_triple'] = gnu
        self.add_payload('app-musl.tar.gz', 'linux/amd64', b'other owned executable\n', archive=True, triple=musl)
        self.data['build_environments'] = [dict(target='linux/amd64', target_triple=t, method='native',
                                              cargo_isolation=dict(toolchain=dict(target_triple=t))) for t in (gnu, musl)]
        self.data['hosts'] = [dict(platform='linux/amd64', target_triple=t, status='success') for t in (gnu, musl)]
        self.data['summary'].update(total=2, success=2)
        self.data['required_variants'] = [dict(target='linux/amd64', target_triple=t) for t in (gnu, musl)]
        self.data['required_assets'] = [{k: v for k, v in a.items() if k in
                                        ('name', 'target', 'archive_format', 'target_triple')} for a in self.data['artifacts']]
        proof = self.generate()
        self.assertEqual(proof['dsr_evidence']['build_tasks'], self.data['required_variants'])
        self.assertEqual(len(proof['subject']), 3)
        self.verify()
        self.data['build_environments'].pop()
        self.proof = self.work / 'missing-native.intoto.jsonl'
        self.generate(expected=4)

    def test_closed_asset_contract_cannot_drop_or_relabel_shared_payload(self):
        self.data['required_assets'] = [{k: a[k] for k in ('name', 'target', 'archive_format')}
                                        for a in self.data['artifacts']]
        self.generate()
        for i, change in enumerate(('missing', 'platform', 'triple', 'extra')):
            original = copy.deepcopy(self.data)
            with self.subTest(change=change):
                rows = self.data['required_assets']
                if change == 'missing':
                    rows.pop()
                elif change == 'platform':
                    rows[1]['target'] = 'linux/amd64'
                elif change == 'triple':
                    rows[1]['target_triple'] = None
                else:
                    rows.append(dict(rows[1], name='extra'))
                self.proof = self.work / ('invalid-%d.intoto.jsonl' % i)
                self.generate(expected=4)
            self.data = original

    def test_unknown_target_and_nonrelease_shared_payload_remain_refused(self):
        for i, change in enumerate(('typo', 'case', 'diagnostic', 'unpublishable', 'duplicate')):
            original = copy.deepcopy(self.data)
            with self.subTest(change=change):
                if change in ('typo', 'case'):
                    self.data['artifacts'][1]['target'] = 'shared' if change == 'typo' else 'Additional'
                elif change == 'diagnostic':
                    self.data['artifacts'][1]['build_purpose'] = 'diagnostic'
                elif change == 'unpublishable':
                    self.data['artifacts'][1]['publishable'] = False
                else:
                    self.data['artifacts'].append(copy.deepcopy(self.data['artifacts'][1]))
                self.proof = self.work / ('invalid-%d.intoto.jsonl' % i)
                self.generate(expected=4)
            self.data = original

    def test_removed_subject_cannot_pass_manifest_binding(self):
        document = self.generate()
        document['subject'] = [s for s in document['subject'] if s['name'] != 'LICENSE']
        document['dsr_evidence']['artifacts'] = [a for a in document['dsr_evidence']['artifacts'] if a['name'] != 'LICENSE']
        altered = self.work / 'missing-license.intoto.jsonl'
        altered.write_text(json.dumps(document))
        self.verify(proof=altered, expected=1)

    def test_unchanged_retry_preserves_existing_proof(self):
        self.generate()
        original = self.proof.read_bytes()
        self.generate()
        self.assertEqual(self.proof.read_bytes(), original)
        self.verify()


class SharedContractTests(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix='dsr-shared-contract-')).resolve()
        self.path = self.work / 'contract.json'
        self.data = dict(schema_version=1, required_assets=[
            dict(name='app.tar.gz', target='linux/amd64', archive_format='tar.gz',
                 target_triple='x86_64-unknown-linux-gnu'),
            dict(name='LICENSE', target='additional', archive_format='binary')],
            required_variants=[dict(target='linux/amd64', target_triple='x86_64-unknown-linux-gnu')])

    def describe(self, expected=0, targets='linux/amd64'):
        self.path.write_text(json.dumps(self.data))
        result = subprocess.run(['bash', REMOTE, 'describe-contract', '--release-contract', str(self.path),
                                 '--targets', targets], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stderr)
        if expected:
            self.assertEqual(result.stdout, '')
            return None
        value = json.loads(result.stdout)
        self.assertFalse(value['authenticated'])
        self.assertEqual(value['input_sha256'], digest(self.path))
        return value

    def test_contract_retains_shared_assets_but_not_shared_variants(self):
        value = self.describe()
        self.assertEqual(len(value['contract']['required_assets']), 2)
        self.assertEqual(value['contract']['required_variants'], self.data['required_variants'])

    def test_equivalent_order_has_one_semantic_identity(self):
        first = self.describe()
        self.data['required_assets'].reverse()
        second = self.describe()
        self.assertEqual(first['contract_sha256'], second['contract_sha256'])
        self.assertNotEqual(first['input_sha256'], second['input_sha256'])

    def test_shared_contract_cannot_replace_a_platform_or_compiler(self):
        for change in ('null-triple', 'triple', 'only-shared', 'missing-platform', 'variant', 'case-collision'):
            original = copy.deepcopy(self.data)
            with self.subTest(change=change):
                rows = self.data['required_assets']
                if change in ('null-triple', 'triple'):
                    rows[1]['target_triple'] = None if change == 'null-triple' else 'x86_64-unknown-linux-gnu'
                elif change == 'only-shared':
                    rows.pop(0)
                elif change == 'missing-platform':
                    rows[0]['target'] = 'darwin/arm64'
                elif change == 'variant':
                    self.data['required_variants'].append(dict(target='additional', target_triple='anything'))
                else:
                    rows.append(dict(rows[1], name='license'))
                self.describe(expected=4)
            self.data = original
        self.describe(expected=4, targets='linux/amd64,additional')


class SharedSnapshotTests(unittest.TestCase):
    # Reuse fixture construction only, not the producer test methods.
    add_payload = SharedAssetTests.add_payload
    generate = SharedAssetTests.generate
    invoke = staticmethod(SharedAssetTests.invoke)

    @classmethod
    def setUpClass(cls):
        cls.fixture = os.environ.get('DSR_TEST_MINISIGN_FIXTURE') == '1'
        cls.signer = shutil.which('minisign')
        if not cls.signer and not cls.fixture:
            raise unittest.SkipTest('Minisign unavailable; DSR_TEST_MINISIGN_FIXTURE=1 explicitly tests only the signer boundary')
        cls.root = Path(tempfile.mkdtemp(prefix='dsr-shared-snapshot-')).resolve()
        cls.public = cls.root / 'trusted.pub'
        cls.private = cls.root / 'private.key'
        cls.environment = {k: v for k, v in os.environ.items()
                           if k not in ('BASH_ENV', 'ENV') and not k.startswith('BASH_FUNC_')}
        if cls.fixture:
            print('EXPLICIT MINISIGN FIXTURE: policy/bytes only, no cryptographic qualification', file=sys.stderr)
            cls.public.write_text('untrusted comment: explicit test fixture\n' + 'A' * 56 + '\n')
            directory = cls.root / 'bin'
            directory.mkdir()
            program = directory / 'minisign'
            # An external boundary fixture, not a replacement for any SLSA
            # function. The real authentication wrapper still checks all
            # proof, key, and signature inputs and handles signer refusal.
            program.write_text('''#!/usr/bin/env python3
import hashlib
from pathlib import Path
import sys
args = sys.argv[1:]
def value(flag):
    return args[args.index(flag) + 1]
try:
    expected = 'DSR_SIGNER_FIXTURE\\n' + value('-P') + '\\n' + hashlib.sha256(Path(value('-m')).read_bytes()).hexdigest() + '\\n'
    valid = '-V' in args and Path(value('-x')).read_text() == expected
except (OSError, ValueError, IndexError):
    valid = False
sys.exit(0 if valid else 1)
''')
            program.chmod(0o700)
            cls.environment['PATH'] = str(directory) + os.pathsep + cls.environment.get('PATH', '')
        else:
            subprocess.run([cls.signer, '-G', '-W', '-p', str(cls.public), '-s', str(cls.private)],
                           check=True, capture_output=True, timeout=30)
        print('Retained snapshot fixtures: ' + str(cls.root), file=sys.stderr)

    def setUp(self):
        SharedAssetTests.setUp(self)
        self.snapshot = self.work / 'snapshot'
        self.contract = self.work / 'contract.json'

    def sign(self):
        proof = self.snapshot / 'release.intoto.jsonl'
        signature = self.snapshot / 'release.intoto.jsonl.minisig'
        if self.fixture:
            signature.write_text('DSR_SIGNER_FIXTURE\n' + 'A' * 56 + '\n' + digest(proof) + '\n')
        else:
            subprocess.run([self.signer, '-S', '-s', str(self.private), '-m', str(proof),
                            '-x', str(signature), '-t', 'DSR owned shared-assets test'],
                           check=True, capture_output=True, timeout=30)

    def prepare(self):
        self.generate()
        self.snapshot.mkdir()
        shutil.copytree(self.assets, self.snapshot / 'artifacts')
        shutil.copy2(self.proof, self.snapshot / 'release.intoto.jsonl')
        # Neither a claimed download status nor an embedded policy is trusted.
        (self.snapshot / 'download.json').write_text('{"authenticated":false,"policy":"not authority"}')
        self.sign()
        policy = dict(schema_version=1, required_assets=[{k: v for k, v in a.items() if k in
                      ('name', 'target', 'archive_format', 'target_triple')} for a in self.data['artifacts']])
        if 'required_variants' in self.data:
            policy['required_variants'] = self.data['required_variants']
        self.contract.write_text(json.dumps(policy))

    def verify_snapshot(self, *, expected=0, contract=True, extra=None, env=None):
        command = ['bash', REMOTE, 'verify-snapshot', str(self.snapshot), '--repo', REPO,
                   '--tag', 'v1.0.0', '--sha', SHA, '--builder', BUILDER, '--targets', 'linux/amd64',
                   '--public-key', str(self.public)]
        if contract:
            command += ['--release-contract', str(self.contract)]
        command += extra or []
        environment = dict(self.environment, **(env or {}))
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=30)
        if expected:
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_actual_snapshot_cli_retains_and_verifies_shared_payload(self):
        self.prepare()
        value = json.loads(self.verify_snapshot().stdout)
        self.assertEqual(value['kind'], 'dsr-slsa-snapshot-verification')
        self.assertFalse(value['remote_current'])
        self.assertEqual({a['name'] for a in value['artifacts']}, {'LICENSE', 'app-linux-amd64.tar.gz'})
        self.assertEqual(next(a for a in value['artifacts'] if a['name'] == 'LICENSE')['sha256'],
                         digest(self.snapshot / 'artifacts/LICENSE'))
        self.assertEqual(value['build_manifest_sha256'], digest(self.manifest))
        again = json.loads(self.verify_snapshot().stdout)
        self.assertEqual(again, value)
        self.verify_snapshot(contract=False)

    def test_validly_resigned_missing_shared_subject_fails_independent_contract(self):
        self.prepare()
        proof = self.snapshot / 'release.intoto.jsonl'
        document = json.loads(proof.read_bytes())
        document['subject'] = [s for s in document['subject'] if s['name'] != 'LICENSE']
        document['dsr_evidence']['artifacts'] = [a for a in document['dsr_evidence']['artifacts'] if a['name'] != 'LICENSE']
        proof.write_text(json.dumps(document))
        self.sign()
        result = self.verify_snapshot(expected=1)
        self.assertIn('Signed statement differs from the selected release policy', result.stderr)

    def test_shared_compiler_identity_is_rejected_even_without_content_contract(self):
        self.prepare()
        proof = self.snapshot / 'release.intoto.jsonl'
        for value in (None, 'x86_64-unknown-linux-gnu'):
            with self.subTest(triple=value):
                document = json.loads(proof.read_bytes())
                next(a for a in document['dsr_evidence']['artifacts'] if a['name'] == 'LICENSE')['target_triple'] = value
                proof.write_text(json.dumps(document))
                self.sign()
                result = self.verify_snapshot(expected=1, contract=False)
                self.assertIn('Signed statement differs from the selected release policy', result.stderr)

    def test_tampered_shared_bytes_cannot_pass_snapshot_cli(self):
        self.prepare()
        license_file = self.snapshot / 'artifacts/LICENSE'
        original = license_file.read_bytes()
        proof = (self.snapshot / 'release.intoto.jsonl').read_bytes()
        license_file.write_bytes(b'x' * len(original))
        result = self.verify_snapshot(expected=1)
        self.assertIn('Release digest mismatch: LICENSE', result.stderr)
        self.assertEqual((self.snapshot / 'release.intoto.jsonl').read_bytes(), proof)
        self.assertEqual(license_file.read_bytes(), b'x' * len(original))

    def test_signature_failure_precedes_policy_and_payload_admission(self):
        self.prepare()
        signature = self.snapshot / 'release.intoto.jsonl.minisig'
        signature.write_bytes(b'not a valid signature\n')
        result = self.verify_snapshot(expected=1)
        self.assertIn('Provenance signature verification failed', result.stderr)
        self.assertNotIn('Signed statement differs', result.stderr)

    def test_shared_bytes_count_toward_download_budget(self):
        self.prepare()
        primary = self.snapshot / 'artifacts/app-linux-amd64.tar.gz'
        # Enough for the platform binary, but not the full shared payload set.
        self.verify_snapshot(expected=1, env={'SLSA_REMOTE_MAX_PAYLOAD_BYTES': str(primary.stat().st_size)})

    def test_shared_payload_does_not_hide_missing_required_abi(self):
        gnu, musl = 'x86_64-unknown-linux-gnu', 'x86_64-unknown-linux-musl'
        self.data['artifacts'][0]['target_triple'] = gnu
        self.add_payload('app-musl.tar.gz', 'linux/amd64', b'owned second ABI', archive=True, triple=musl)
        self.data['required_variants'] = [dict(target='linux/amd64', target_triple=t) for t in (gnu, musl)]
        self.data['build_environments'] = [dict(target='linux/amd64', target_triple=t, method='native') for t in (gnu, musl)]
        self.data['hosts'] = [dict(platform='linux/amd64', target_triple=t, status='success') for t in (gnu, musl)]
        self.data['summary'].update(total=2, success=2)
        self.prepare()
        self.verify_snapshot()
        proof = self.snapshot / 'release.intoto.jsonl'
        doc = json.loads(proof.read_bytes())
        doc['subject'] = [r for r in doc['subject'] if r['name'] != 'app-musl.tar.gz']
        doc['dsr_evidence']['artifacts'] = [r for r in doc['dsr_evidence']['artifacts'] if r['name'] != 'app-musl.tar.gz']
        proof.write_text(json.dumps(doc))
        self.sign()
        self.assertIn('Signed statement differs', self.verify_snapshot(expected=1).stderr)

    def test_snapshot_namespace_must_include_exact_shared_names(self):
        self.prepare()
        path = self.snapshot / 'artifacts/LICENSE'
        path.rename(self.work / 'retained-license')
        self.verify_snapshot(expected=1)
        path.symlink_to(self.work / 'retained-license')
        self.verify_snapshot(expected=1)
        self.assertTrue(path.is_symlink())


class SharedRemotePayloadTests(unittest.TestCase):
    """Post-authentication acquisition; only the HTTP transport is substituted.

    Read the real SBOM taxonomy/download functions from this checkout. Do not
    mirror their suffix rules in a fixture: doing so concealed this integration
    defect. An explicit support directory permits exact retained definitions in
    a partial checkout, without claiming full module startup or live transport.
    """
    add_payload = SharedAssetTests.add_payload
    generate = SharedAssetTests.generate
    invoke = staticmethod(SharedAssetTests.invoke)

    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix='dsr-shared-remote-')).resolve()
        support = Path(os.environ.get('DSR_TEST_SLSA_SUPPORT_DIR', str(Path(MODULE).parent)))
        if not all((support / name).is_file() for name in ('sbom.sh', 'sbom_release.sh')):
            raise unittest.SkipTest('remote payload checks need the actual sbom.sh/sbom_release.sh definitions')
        bodies = []
        for file, names in (('sbom.sh', ('_sbom_log', '_sbom_hash', '_sbom_is_metadata')),
                            ('sbom_release.sh', ('_sbr_named_asset', '_sbr_payload_names',
                                                 '_sbr_asset_digest', '_sbr_download'))):
            text = (support / file).read_text()
            for name in names:
                start = text.index(name + '() {\n')
                end = text.index('\n}\n', start) + 3
                bodies.append(text[start:end])
        cls.helpers = cls.root / 'production-definitions.sh'
        cls.helpers.write_text('\n\n'.join(bodies) + '\n')
        print('Retained remote payload fixtures: ' + str(cls.root), file=sys.stderr)

    def setUp(self):
        SharedAssetTests.setUp(self)
        self.remote_bytes = self.work / 'remote-by-id'
        self.remote_bytes.mkdir()
        self.calls = self.work / 'acquisitions.jsonl'
        self.serial = 0

    def inventory(self):
        self.generate()
        rows = []
        for asset_id, row in enumerate(self.data['artifacts'], 1):
            shutil.copy2(self.assets / row['name'], self.remote_bytes / str(asset_id))
            rows.append(dict(id=asset_id, name=row['name'], state='uploaded',
                             size=row['size_bytes'], digest='sha256:' + row['sha256']))
        # Unselected metadata retains its previous treatment. Its mere presence
        # must neither become an authenticated subject nor hide an extra binary.
        rows.append(dict(id=99, name='release.intoto.jsonl', state='uploaded', size=1, digest=None))
        return rows

    def acquire(self, rows, expected=0, env=None):
        self.serial += 1
        work = self.work / ('attempt-%d' % self.serial)
        work.mkdir()
        inventory = work / 'inventory.json'
        inventory.write_text(json.dumps(rows))
        environment = {k: v for k, v in os.environ.items()
                       if k not in ('BASH_ENV', 'ENV') and not k.startswith('BASH_FUNC_')}
        environment.update(DSR_FIXTURE_BYTES=str(self.remote_bytes), DSR_FIXTURE_CALLS=str(self.calls))
        environment.update(env or {})
        program = '''set -uo pipefail
source "$1" || exit $?
source "$2" || exit $?
source "$3" || exit $?
# Explicit network acquisition boundary. Production taxonomy, exact namespace,
# per-asset preflight, hashes and collection are not substituted.
_sbr_run() {
    [[ "$1" == gh_download_release_asset && "$2" == example/shared-assets ]] || return 91
    jq -nc --arg id "$3" '{asset_id:$id}' >> "$DSR_FIXTURE_CALLS" || return 1
    [[ "${DSR_FIXTURE_REFUSE_ID:-}" != "$3" ]] || return 8
    cp -- "$DSR_FIXTURE_BYTES/$3" "$4"
}
_slr_payloads example/shared-assets "$(cat "$4")" "$5" "$6"
'''
        result = subprocess.run(['bash', '-c', program, '_', MODULE, REMOTE, str(self.helpers),
                                 str(inventory), str(self.proof), str(work)], env=environment,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stderr)
        self.assertEqual(result.stdout, '')
        return work, result

    def test_signed_shared_metadata_names_are_downloaded_and_hashed(self):
        for name in ('NOTICE.txt', 'runtime.json', 'README.md'):
            self.add_payload(name, 'additional', ('owned ' + name).encode())
        rows = self.inventory()
        work, _ = self.acquire(rows)
        self.assertEqual({p.name for p in (work / 'payloads').iterdir()},
                         {a['name'] for a in self.data['artifacts']})
        for row in self.data['artifacts']:
            self.assertEqual(digest(work / 'payloads' / row['name']), row['sha256'])
        calls = [json.loads(line)['asset_id'] for line in self.calls.read_text().splitlines()]
        self.assertEqual(sorted(calls), [str(i) for i in range(1, 6)])

    def test_missing_shared_name_fails_before_any_download(self):
        rows = [r for r in self.inventory() if r['name'] != 'LICENSE']
        _, result = self.acquire(rows, expected=7)
        self.assertIn('Remote payload namespace differs', result.stderr)
        self.assertFalse(self.calls.exists())

    def test_unlisted_binary_is_not_hidden_by_shared_assets(self):
        rows = self.inventory()
        rows.append(dict(id=100, name='unexpected-executable', state='uploaded', size=1, digest=None))
        _, result = self.acquire(rows, expected=7)
        self.assertIn('Remote payload namespace differs', result.stderr)
        self.assertFalse(self.calls.exists())

    def test_shared_size_digest_and_duplicate_identities_fail_before_download(self):
        base = self.inventory()
        for change in ('size', 'digest', 'duplicate'):
            rows = copy.deepcopy(base)
            shared = next(r for r in rows if r['name'] == 'LICENSE')
            with self.subTest(change=change):
                if change == 'size':
                    shared['size'] += 1
                elif change == 'digest':
                    shared['digest'] = 'sha256:' + '0' * 64
                else:
                    rows.append(dict(shared, id=101))
                self.acquire(rows, expected=7)
                self.assertFalse(self.calls.exists())

    def test_corrupt_shared_download_is_refused_despite_api_digest(self):
        rows = self.inventory()
        path = self.remote_bytes / '2'
        path.write_bytes(b'x' * path.stat().st_size)
        work, result = self.acquire(rows, expected=7)
        self.assertIn('Downloaded release asset bytes do not match inventory', result.stderr)
        self.assertFalse((work / 'payloads/LICENSE').exists())

    def test_unreadable_shared_download_fails_without_partial_success(self):
        rows = self.inventory()
        work, _ = self.acquire(rows, expected=8, env={'DSR_FIXTURE_REFUSE_ID': '2'})
        self.assertFalse((work / 'payloads/LICENSE').exists())

    def test_shared_bytes_remain_part_of_the_acquisition_budget(self):
        rows = self.inventory()
        self.acquire(rows, expected=7,
                     env={'SLSA_REMOTE_MAX_PAYLOAD_BYTES': str(self.data['artifacts'][0]['size_bytes'])})
        self.assertFalse(self.calls.exists())

    def test_plain_platform_release_keeps_existing_metadata_policy(self):
        self.data['artifacts'] = self.data['artifacts'][:1]
        rows = self.inventory()
        rows.append(dict(id=102, name='LICENSE', state='uploaded', size=12, digest=None))
        work, _ = self.acquire(rows)
        self.assertEqual([p.name for p in (work / 'payloads').iterdir()], ['app-linux-amd64.tar.gz'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
PY
