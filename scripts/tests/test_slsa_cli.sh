#!/usr/bin/env bash
# bd-1tv.15: Exercise the actual public CLI with real Git, payload bytes and
# Minisign keys/signatures. Build manifests are explicit synthetic producer
# records; these tests do not claim compilation or a live GitHub publication.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for dependency in python3 jq git minisign; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'SKIP: %s required\n' "$dependency"
        exit 0
    fi
done
python3 -I - "$ROOT" "${DSR_TEST_COMMAND_FILE:-$ROOT/dsr}" "$@" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1))
CLI = Path(sys.argv.pop(1))
BUILDER = 'dsr/test-cli'
REPOSITORY = 'example/slsa-cli'
SOURCE = 'https://github.com/' + REPOSITORY
BUILD_TYPE = 'https://github.com/Dicklesworthstone/doodlestein_self_releaser/buildtype/release-test'


class SlsaCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix='dsr-slsa-cli-'))
        cls.env = {key: value for key, value in os.environ.items()
                   if not key.startswith(('DSR_', 'GIT_', 'BASH_FUNC_'))}
        cls.env.update(NO_COLOR='1', XDG_CONFIG_HOME=str(cls.work / 'config'),
                       XDG_STATE_HOME=str(cls.work / 'state'),
                       XDG_CACHE_HOME=str(cls.work / 'cache'),
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(cls.work / 'gitconfig'))
        cls.repo = cls.work / 'source'; cls.repo.mkdir()
        cls.assets = cls.work / 'assets'; cls.assets.mkdir()
        cls.first = cls.assets / 'app.bin'; cls.first.write_bytes(b'primary release bytes\n')
        cls.second = cls.assets / 'helper.bin'; cls.second.write_bytes(b'helper release bytes\n')
        cls.run_setup('git', 'init', '-q', '-b', 'main', cls.repo)
        cls.run_setup('git', '-C', cls.repo, 'config', 'user.name', 'DSR test')
        cls.run_setup('git', '-C', cls.repo, 'config', 'user.email', 'test@example.invalid')
        cls.run_setup('git', '-C', cls.repo, 'remote', 'add', 'origin', SOURCE)
        (cls.repo / 'source.txt').write_text('source fixture\n')
        cls.run_setup('git', '-C', cls.repo, 'add', 'source.txt')
        cls.run_setup('git', '-C', cls.repo, 'commit', '-qm', 'source fixture')
        cls.pin = cls.run_setup('git', '-C', cls.repo, 'rev-parse', 'HEAD').stdout.strip()
        cls.key = cls.work / 'trusted.pub'; cls.secret = cls.work / 'trusted.key'
        cls.wrong_key = cls.work / 'other.pub'
        cls.run_setup('minisign', '-G', '-W', '-p', cls.key, '-s', cls.secret)
        cls.run_setup('minisign', '-G', '-W', '-p', cls.wrong_key, '-s', cls.work / 'other.key')
        cls.observation = Path(str(cls.first) + '.intoto.jsonl')
        cls.run_setup('bash', ROOT / 'src/slsa.sh', 'generate', cls.first,
                      '--builder', BUILDER, '--repo-path', cls.repo,
                      '--build-type', 'release-test', '--invocation-id', 'fixture-run')
        cls.sign(cls.observation)
        cls.manifest_data = dict(
            schema_version='1.0.0', tool='slsa-cli', version='v1.0.0', run_id='fixture-run',
            built_at='2026-11-20T00:00:00Z', status='success',
            source=dict(git_sha=cls.pin, git_ref='refs/tags/v1.0.0', dependencies=[]),
            summary=dict(total=1, success=1, failed=0),
            artifacts=[dict(name=file.name, target='linux/amd64', archive_format='binary',
                            size_bytes=file.stat().st_size,
                            sha256=hashlib.sha256(file.read_bytes()).hexdigest())
                       for file in (cls.first, cls.second)])
        cls.manifest = cls.work / 'manifest.json'
        cls.manifest.write_text(json.dumps(cls.manifest_data))
        cls.release = cls.work / 'release.intoto.jsonl'
        cls.run_setup('bash', ROOT / 'src/slsa.sh', 'generate-manifest', cls.manifest, cls.assets,
                      '--repository', REPOSITORY, '--builder', BUILDER, '--output', cls.release)
        cls.sign(cls.release)
        print('SLSA CLI fixtures retained: ' + str(cls.work), file=sys.stderr)

    @classmethod
    def run_setup(cls, *arguments):
        result = subprocess.run(list(map(str, arguments)), env=cls.env, text=True,
                                capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError('Fixture setup failed: ' + result.stderr)
        return result

    @classmethod
    def sign(cls, proof):
        cls.run_setup('minisign', '-S', '-W', '-s', cls.secret, '-m', proof)

    def invoke(self, operation, *arguments, json_mode=True, dry=False):
        command = ['bash', str(CLI)]
        if json_mode:
            command.append('--json')
        if dry:
            command.append('--dry-run')
        command += ['slsa', operation, *map(str, arguments)]
        return subprocess.run(command, env=self.env, text=True, capture_output=True, timeout=30)

    def result(self, code, operation, *arguments, **options):
        result = self.invoke(operation, *arguments, **options)
        self.assertEqual(result.returncode, code, result.stderr + '\n' + result.stdout)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt['command'], 'slsa-' + operation)
        self.assertEqual(receipt['exit_code'], code)
        self.assertEqual(receipt['status'], 'error' if code else
                         ('ok' if operation.startswith('verify') else 'success'))
        if code:
            self.assertFalse(receipt['details']['authenticated'])
            self.assertTrue(receipt['details']['error'])
        return receipt['details']

    def test_authenticated_named_artifact(self):
        details = self.result(0, 'verify', self.first, self.observation,
                              '--public-key', self.key, '--builder', BUILDER,
                              '--build-type', BUILD_TYPE, '--source-repository', SOURCE,
                              '--source-commit', self.pin, '--invocation-id', 'fixture-run')
        self.assertTrue(details['valid'] and details['authenticated'] and details['authentication_requested'])
        self.assertEqual(details['verification_scope'], 'artifact')
        self.assertEqual(details['policy']['source_commit'], self.pin)

    def test_unsigned_named_artifact_reports_no_authentication(self):
        details = self.result(0, 'verify', self.first, self.observation)
        self.assertTrue(details['valid'])
        self.assertFalse(details['authenticated'] or details['authentication_requested'])
        self.assertEqual(details['policy'], {})

    def test_default_proof_keeps_every_option(self):
        details = self.result(0, 'verify', self.first, '--builder', BUILDER, '--public-key', self.key)
        self.assertTrue(details['authenticated'])
        self.assertEqual(details['provenance'], str(self.observation))

    def test_wrong_or_missing_signer_is_terminal(self):
        for key in (self.wrong_key, self.work / 'absent.pub'):
            with self.subTest(key=key.name):
                details = self.result(1, 'verify', self.first, self.observation,
                                      '--builder', BUILDER, '--public-key', key)
                self.assertFalse(details['valid'])
                self.assertTrue(details['authentication_requested'])

    def test_missing_selected_signature_is_terminal(self):
        self.result(1, 'verify', self.first, self.observation, '--builder', BUILDER,
                    '--public-key', self.key, '--signature', self.work / 'absent.minisig')

    def test_each_expected_identity_is_enforced(self):
        for arguments in (('--builder', 'wrong'), ('--build-type', 'wrong'),
                          ('--invocation-id', 'wrong'),
                          ('--source-repository', SOURCE, '--source-commit', 'f' * 40),
                          ('--source-repository', SOURCE + '-other', '--source-commit', self.pin)):
            with self.subTest(policy=arguments[0]):
                details = self.result(1, 'verify', self.first, self.observation, *arguments)
                self.assertFalse(details['valid'])

    def test_invalid_and_ambiguous_options_never_verify(self):
        for arguments in (('--public-key',), ('--builder',), ('--unsupported', 'value'),
                          ('--builder', BUILDER, '--builder', 'wrong'),
                          ('--builder', BUILDER, '-b', 'wrong'),
                          ('--public-key', self.key), ('--source-commit', self.pin),
                          ('--signature', str(self.observation) + '.minisig'),
                          ('--builder', '--public-key', self.key), ('extra-positional',)):
            with self.subTest(arguments=arguments):
                details = self.result(4, 'verify', self.first, self.observation, *arguments)
                self.assertFalse(details['valid'])

    def test_generation_exposes_recorded_invocation_and_type(self):
        output = self.work / 'generated-observation.jsonl'
        details = self.result(0, 'generate', self.first, '--builder', BUILDER,
                              '--repo-path', self.repo, '--build-type', 'release-test',
                              '--invocation-id', 'public-run', '--output', output)
        self.assertFalse(details['authenticated'])
        self.assertEqual(details['evidence_kind'], 'post-build-observation')
        self.assertEqual(details['output'], str(output))
        data = json.loads(output.read_text())
        self.assertEqual(data['predicate']['runDetails']['metadata']['invocationId'], 'public-run')
        self.assertEqual(data['predicate']['buildDefinition']['buildType'], BUILD_TYPE)

    def test_generation_rejects_missing_options_and_extra_inputs(self):
        for arguments in (('--builder',), ('--output',), ('--repo-path',),
                          ('--invocation-id',), ('--build-type',), ('extra-positional',)):
            with self.subTest(arguments=arguments):
                details = self.result(4, 'generate', self.first, *arguments)
                self.assertIsNone(details['output'])

    def test_manifest_generation_selects_every_real_payload(self):
        output = self.work / 'generated-release.jsonl'
        details = self.result(0, 'generate-manifest', self.manifest, self.assets,
                              '--repository', REPOSITORY, '--builder', BUILDER, '--output', output)
        self.assertFalse(details['authenticated'])
        self.assertEqual(details['evidence_kind'], 'build-manifest')
        self.assertEqual(details['output'], str(output))
        data = json.loads(output.read_text())
        self.assertEqual({row['name']: row['digest']['sha256'] for row in data['subject']},
                         {row['name']: row['sha256'] for row in self.manifest_data['artifacts']})
        self.assertEqual(data['dsr_evidence']['manifest_sha256'], hashlib.sha256(self.manifest.read_bytes()).hexdigest())
        before = output.read_bytes()
        self.result(0, 'generate-manifest', self.manifest, self.assets, '--repository', REPOSITORY,
                    '--builder', BUILDER, '--output', output)
        self.assertEqual(output.read_bytes(), before)
        self.result(2, 'generate-manifest', self.manifest, self.assets, '--repository', REPOSITORY,
                    '--builder', 'another-builder', '--output', output)
        self.assertEqual(output.read_bytes(), before)

    def test_signed_complete_release_and_expected_manifest(self):
        details = self.result(0, 'verify-release', self.release, self.assets,
                              '--manifest', self.manifest, '--repository', REPOSITORY,
                              '--builder', BUILDER, '--public-key', self.key)
        self.assertTrue(details['valid'] and details['authenticated'])
        self.assertEqual(details['verification_scope'], 'release')
        self.assertEqual(details['policy']['manifest'], str(self.manifest))

    def test_complete_release_never_falls_back_to_first_subject(self):
        assets = self.work / 'changed-assets'; assets.mkdir()
        shutil.copy2(self.first, assets / self.first.name)
        (assets / self.second.name).write_bytes(b'changed helper bytes\n')
        details = self.result(1, 'verify-release', self.release, assets,
                              '--builder', BUILDER, '--public-key', self.key)
        self.assertFalse(details['valid'])
        (assets / self.second.name).rename(self.work / 'changed-helper.saved')
        self.result(4, 'verify-release', self.release, assets, '--builder', BUILDER, '--public-key', self.key)

    def test_complete_release_rejects_wrong_key_and_stale_manifest(self):
        self.result(1, 'verify-release', self.release, self.assets,
                    '--builder', BUILDER, '--public-key', self.wrong_key)
        data = copy.deepcopy(self.manifest_data); data['run_id'] = 'other-build'
        manifest = self.work / 'stale-manifest.json'; manifest.write_text(json.dumps(data))
        self.result(1, 'verify-release', self.release, self.assets, '--manifest', manifest,
                    '--repository', REPOSITORY, '--builder', BUILDER, '--public-key', self.key)

    def test_complete_release_requires_explicit_manifest_policy(self):
        for arguments in (('--manifest', self.manifest), ('--repository', REPOSITORY),
                          ('--public-key', self.key), ('--repo-path', self.repo)):
            with self.subTest(arguments=arguments):
                self.result(4, 'verify-release', self.release, self.assets, *arguments)

    def test_generation_dry_run_never_writes_a_statement(self):
        for operation, inputs, arguments in (
                ('generate', [self.first], []),
                ('generate-manifest', [self.manifest, self.assets], ['--repository', REPOSITORY])):
            with self.subTest(operation=operation):
                output = self.work / ('dry-' + operation + '.jsonl')
                self.result(4, operation, *inputs, *arguments, '--output', output, dry=True)
                self.assertFalse(output.exists())

    def test_plain_stdout_is_only_a_generated_path_or_empty_verification(self):
        output = self.work / 'plain-generation.jsonl'
        generated = self.invoke('generate-manifest', self.manifest, self.assets,
                                '--repository', REPOSITORY, '--builder', BUILDER,
                                '--output', output, json_mode=False)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        self.assertEqual(generated.stdout, str(output) + '\n')
        verified = self.invoke('verify', self.first, self.observation,
                               '--builder', BUILDER, '--public-key', self.key, json_mode=False)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(verified.stdout, '')


unittest.main()
PY
