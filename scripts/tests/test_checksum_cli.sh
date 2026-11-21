#!/usr/bin/env bash
# Public checksum lifecycle with real Git commits, retained evidence and hashes.
# Only GitHub HTTP/authentication is a protocol fixture; no live remote writes.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
for dependency in python3 jq git; do
    command -v "$dependency" >/dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; exit 3; }
done
exec python3 -I - "$ROOT" "${DSR_TEST_COMMAND_FILE:-$ROOT/dsr}" "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(sys.argv.pop(1))
CLI = Path(sys.argv.pop(1))
GIT = shutil.which('git')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

class ChecksumCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        envelope_schema = json.loads((ROOT / 'schemas/envelope.json').read_text())
        Draft202012Validator.check_schema(envelope_schema)
        cls.validator = Draft202012Validator(envelope_schema, format_checker=FormatChecker())
        cls.work = Path(tempfile.mkdtemp(prefix='dsr-checksum-cli-')).resolve()
        cls.bins = cls.work / 'bin'; cls.bins.mkdir()
        (cls.bins / 'curl').write_text(r'''#!/usr/bin/env -S python3 -I -S
import json,os,pathlib,sys,time
from urllib.parse import urlsplit
args=sys.argv[1:]
if args==['--disable','--version']:
    print('curl 8.10.1 (explicit GitHub HTTP fixture)'); raise SystemExit(0)
case=pathlib.Path(os.environ['CHECKSUM_CASE']); url=urlsplit(args[-1]); headers=sys.stdin.read()
assert url.scheme=='https' and url.netloc=='api.github.com' and '--fail' in args
assert 'Authorization: Bearer checksum-fixture' in headers
assert 'checksum-fixture' not in ' '.join(args)
with (case/'http.jsonl').open('a') as out: out.write(json.dumps({'path':url.path,'query':url.query})+'\n')
if (case/'hold-curl').exists():
    (case/'curl.pid').write_text(str(os.getpid()))
    time.sleep(120)
if '/releases/tags/' in url.path: body=(case/'release.json').read_bytes()
elif url.path.endswith('/assets'): body=(case/'assets.json').read_bytes()
else: body=(case/'bytes'/url.path.rsplit('/',1)[1]).read_bytes()
assert len(body)<=int(args[args.index('--max-filesize')+1])
pathlib.Path(args[args.index('--output')+1]).write_bytes(body)
''')
        (cls.bins / 'curl').chmod(0o755)
        (cls.bins / 'gh').write_text('#!/bin/sh\nexit 99\n')
        (cls.bins / 'gh').chmod(0o755)
        print('Checksum CLI evidence retained: ' + str(cls.work), file=sys.stderr)

    def setUp(self):
        self.case = self.work / self._testMethodName; self.case.mkdir()
        for folder in ('tmp', 'config', 'bytes', 'remotes'):
            (self.case / folder).mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(('GIT_', 'DSR_', 'BASH_FUNC_')) and
                    key not in ('BASH_ENV', 'ENV', 'GH_TOKEN', 'GITHUB_TOKEN')}
        self.env.update(NO_COLOR='1', CHECKSUM_CASE=str(self.case),
                        TMPDIR=str(self.case / 'tmp'), DSR_CONFIG_DIR=str(self.case / 'config'),
                        DSR_STATE_DIR=str(self.case / 'state'), DSR_GH_TOKEN='checksum-fixture',
                        GIT_CONFIG_GLOBAL=str(self.case / 'gitconfig'), GIT_CONFIG_NOSYSTEM='1',
                        PATH=str(self.bins) + os.pathsep + os.environ['PATH'])
        (self.case / 'gitconfig').write_text('[user]\n name = Checksum CLI\n email = checksum@example.invalid\n'
            '[commit]\n gpgsign = false\n[url "' + (self.case / 'remotes').as_uri() + '/"]\n'
            ' insteadOf = https://github.com/owner/\n')
        seed = self.case / 'seed'
        self.git('init', '-q', '-b', 'main', seed)
        (seed / 'README').write_text('unrelated repository bytes\n')
        (seed / 'SHA256SUMS.txt').write_text('old checksum records\n')
        self.git('-C', seed, 'add', '.'); self.git('-C', seed, 'commit', '-qm', 'initial')
        self.initial = self.git('-C', seed, 'rev-parse', 'HEAD')
        for name in ('a', 'b'):
            remote = self.case / 'remotes' / (name + '.git')
            self.git('clone', '-q', '--bare', seed, remote)
            hook = remote / 'hooks' / 'post-receive'
            hook.write_text('#!/bin/sh\nprintf "accepted\\n" >> "$CHECKSUM_CASE/push-' + name + '.log"\n')
            hook.chmod(0o755)
        payload = b'actual complete release payload\n'
        rows = []
        for index, name, content in ((1, 'app.tar.gz', payload),
                                    (2, 'app.tar.gz.sha256', hashlib.sha256(payload).hexdigest().encode() + b'\n')):
            (self.case / 'bytes' / str(index)).write_bytes(content)
            rows.append(dict(id=index, name=name, size=len(content), state='uploaded',
                             digest='sha256:' + hashlib.sha256(content).hexdigest()))
        (self.case / 'assets.json').write_text(json.dumps(rows))
        (self.case / 'release.json').write_text(json.dumps(dict(
            id=42, tag_name='v1.2.3', draft=False, prerelease=False, target_commitish='main')))
        self.manifest = self.case / 'local.sha256'
        self.manifest.write_text(hashlib.sha256(payload).hexdigest() + '  app.tar.gz\n')
        self.serial = 0

    def git(self, *arguments):
        proc = subprocess.run([GIT, *map(str, arguments)], env=self.env,
                              capture_output=True, text=True, timeout=15)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def tip(self, name='a'):
        return self.git('--git-dir', self.case / 'remotes' / (name + '.git'), 'rev-parse', 'HEAD')

    def requests(self):
        path = self.case / 'http.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def invoke(self, action, *arguments, plain=False, dry=False):
        self.serial += 1
        command = ['bash', str(CLI)]
        if not plain: command.append('--json')
        if dry: command.append('--dry-run')
        command += ['release', 'checksums', action, *map(str, arguments)]
        proc = subprocess.run(command, env=self.env, capture_output=True, timeout=35)
        (self.case / ('%02d.stdout' % self.serial)).write_bytes(proc.stdout)
        (self.case / ('%02d.stderr' % self.serial)).write_bytes(proc.stderr)
        try:
            value = json.loads(proc.stdout)
        except ValueError as error:
            self.fail('Missing CLI receipt: ' + proc.stderr.decode() + ': ' + str(error))
        if plain:
            return proc, value
        self.validator.validate(value)
        self.assertEqual(value['command'], 'release-checksums')
        self.assertEqual(value['exit_code'], proc.returncode)
        self.assertIn(value['status'], ('success', 'partial', 'error'))
        self.assertEqual(value['details']['action'], action)
        self.assertFalse(value['details'].get('authenticated', False))
        self.assertFalse(value['details'].get('source_verified', False))
        return proc, value['details']

    def sync(self, *arguments, **kwargs):
        return self.invoke('sync', 'app', 'v1.2.3', '--repo', 'owner/app', '--target-repo', 'owner/a',
                           '--verify-release', '--checksum-mode', 'sidecars', *arguments, **kwargs)

    def recovery(self, original, *arguments, **kwargs):
        source = Path(original['result_file'])
        return self.invoke('recover', '--result', source, '--result-sha256', digest(source),
                           '--target-repo', 'owner/a', '--output-dir', self.case / ('recover-%02d' % self.serial),
                           *arguments, **kwargs)

    def test_local_dry_run_and_plain_receipt(self):
        proc, details = self.invoke('sync', 'app', '1.2.3', '--repo', 'owner/app', '--manifest', self.manifest,
                                   '--target-repo', 'owner/a', dry=True)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        receipt = details['receipt']
        self.assertTrue(details['dry_run']); self.assertEqual(receipt['planned'], 1)
        self.assertEqual(receipt['synced'], 0); self.assertEqual(self.tip(), self.initial)
        self.assertEqual(json.loads(Path(receipt['result_file']).read_bytes()), receipt)
        self.assertEqual(self.requests(), [])
        self.assertFalse((Path(receipt['workspace']) / 'target-1').exists())
        proc, plain = self.invoke('sync', 'app', '1.2.3', '--repo', 'owner/app', '--manifest', self.manifest,
                                 '--target-repo', 'owner/a', '--dry-run', plain=True)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(proc.stdout, Path(plain['result_file']).read_bytes())

    def test_audit_preflight_and_complete_payload(self):
        output = self.case / 'audit'
        args = ('--repo', 'owner/app', '--tag', 'v1.2.3', '--checksum-mode', 'sidecars', '--output-dir', output)
        proc, details = self.invoke('audit', *args, dry=True)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertTrue(details['dry_run']); self.assertFalse(output.exists())
        self.assertEqual(self.requests(), [])
        proc, details = self.invoke('audit', *args)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        receipt = details['receipt']
        self.assertEqual(receipt['status'], 'verified')
        self.assertEqual(receipt['eligible_count'], receipt['verified_count'])
        self.assertEqual(receipt['verified_checksums'], ['app.tar.gz'])
        self.assertEqual((output / 'artifacts/app.tar.gz').read_bytes(), (self.case / 'bytes/1').read_bytes())
        self.assertEqual(json.loads((output / 'result.json').read_bytes()), receipt)

    def test_audit_recheck_retains_distinct_inventory_receipt(self):
        proc, details = self.invoke('audit', '--repo', 'owner/app', '--tag', 'v1.2.3',
                                   '--checksum-mode', 'sidecars')
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        prior = Path(details['receipt']['output_dir'])
        before = sum('/releases/assets/' in row['path'] for row in self.requests())
        proc, details = self.invoke('audit', '--repo', 'owner/app', '--tag', 'v1.2.3',
            '--checksum-mode', 'sidecars', '--recheck-from', prior, '--audit-sha256', digest(prior / 'result.json'))
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(details['receipt']['kind'], 'dsr-release-checksum-inventory-check')
        self.assertFalse(details['receipt']['payloads_reverified'])
        self.assertEqual(sum('/releases/assets/' in row['path'] for row in self.requests()), before)

    def test_audited_commit_and_result_delivery_recovery(self):
        proc, details = self.sync()
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        original = details['receipt']; row = original['results'][0]
        self.assertTrue(row['committed']); self.assertFalse(row['pushed'])
        self.assertEqual(self.tip(), self.initial)
        self.assertEqual(self.git('-C', row['checkout'], 'show', 'HEAD:SHA256SUMS.txt'), self.manifest.read_text().strip())
        self.assertEqual(self.git('-C', row['checkout'], 'diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD'), 'SHA256SUMS.txt')
        proc, details = self.recovery(original)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(details['receipt']['status'], 'ready')
        self.assertFalse(details['receipt']['delivery_confirmed'])
        proc, details = self.recovery(original, '--push')
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(details['receipt']['status'], 'pushed')
        self.assertTrue(details['receipt']['delivery_confirmed'])
        self.assertEqual(self.tip(), row['commit'])
        proc, details = self.recovery(original, '--push')
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(details['receipt']['status'], 'already-applied')
        self.assertEqual((self.case / 'push-a.log').read_text(), 'accepted\n')

    def test_partial_fanout_recovers_from_exact_plan(self):
        hook = self.case / 'remotes/b.git/hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n'); hook.chmod(0o755)
        proc, details = self.sync('--target-repo', 'owner/b', '--push')
        self.assertNotEqual(proc.returncode, 0)
        original = details['receipt']
        self.assertEqual(original['status'], 'partial')
        self.assertNotEqual(self.tip(), self.initial); self.assertEqual(self.tip('b'), self.initial)
        hook.write_text('#!/bin/sh\nexit 0\n')
        plan = original['sync_plan']
        proc, details = self.invoke('recover', '--plan', plan['path'], '--plan-sha256', plan['sha256'],
                                   '--output-dir', self.case / 'plan-recovery', '--execute', '--push')
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(details['receipt']['kind'], 'dsr-checksum-sync-continuation')
        self.assertTrue(details['receipt']['delivery_confirmed'])
        self.assertEqual((self.case / 'push-a.log').read_text(), 'accepted\n')
        self.assertEqual((self.case / 'push-b.log').read_text(), 'accepted\n')

    def test_corrupt_download_blocks_every_downstream_commit(self):
        (self.case / 'bytes/1').write_bytes(b'wrong release bytes')
        proc, details = self.sync('--push')
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(details['receipt']['results'], [])
        self.assertEqual(self.tip(), self.initial)
        self.assertFalse((self.case / 'push-a.log').exists())

    def test_wrong_recovery_pin_and_retained_bytes_refuse_delivery(self):
        proc, details = self.sync()
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        original = details['receipt']; before = len(self.requests())
        proc, _ = self.invoke('recover', '--result', original['result_file'], '--result-sha256', '0' * 64,
                             '--target-repo', 'owner/a', '--output-dir', self.case / 'wrong-pin', '--push')
        self.assertEqual(proc.returncode, 4); self.assertEqual(len(self.requests()), before)
        retained = Path(original['release_verification']['output_dir']) / 'artifacts/app.tar.gz'
        retained.write_bytes(b'changed retained payload')
        proc, _ = self.recovery(original, '--push')
        self.assertNotEqual(proc.returncode, 0); self.assertEqual(self.tip(), self.initial)
        self.assertFalse((self.case / 'push-a.log').exists())

    def test_invalid_options_are_refused_before_any_engine(self):
        cases = (
            ('sync', 'app', '1.2.3', '--repo', 'owner/app', '--repo', 'owner/other'),
            ('sync', 'app', '1.2.3', '--repo', 'owner/app', '--manifest'),
            ('sync', 'app', '1.2.3', '--repo', 'owner/app', '--unknown'),
            ('sync', 'app', '1.2.3', '--repo', 'owner/app', '--push=true'),
            ('sync', 'app', '1.2.3', '--repo', 'owner/app', '--tool', 'other'),
            ('sync', 'app', '1.2.3', '--manifest', self.manifest),
            ('audit', '--repo', 'owner/app', '--tag', 'v1.2.3', '--push'),
            ('audit', '--repo', 'owner/app', '--tag', 'v1.2.3', 'unexpected'),
            ('recover', '--sync-lease-fd', '9'),
            ('recover', '--result', 'a', '--result', 'b'),
        )
        for args in cases:
            with self.subTest(args=args):
                proc, details = self.invoke(*args)
                self.assertEqual(proc.returncode, 4, proc.stderr.decode())
                self.assertNotIn('receipt', details)
        proc, _ = self.invoke('recover', '--push', dry=True)
        self.assertEqual(proc.returncode, 4)
        self.assertEqual(self.requests(), []); self.assertEqual(self.tip(), self.initial)
        self.assertEqual(list((self.case / 'tmp').iterdir()), [])

    def test_outer_cli_cancellation_stops_audit_before_mutation(self):
        (self.case / 'hold-curl').touch()
        command = ['bash', str(CLI), '--json', 'release', 'checksums', 'sync', 'app', 'v1.2.3',
                   '--repo', 'owner/app', '--target-repo', 'owner/a', '--verify-release',
                   '--checksum-mode', 'sidecars', '--push']
        worker = subprocess.Popen(command, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                if (self.case / 'curl.pid').exists() or worker.poll() is not None: break
                time.sleep(.05)
            self.assertTrue((self.case / 'curl.pid').exists(), 'Audit never reached controlled HTTP boundary')
            pid = int((self.case / 'curl.pid').read_text())
            worker.send_signal(signal.SIGTERM)
            stdout, stderr = worker.communicate(timeout=15)
            self.assertEqual(worker.returncode, 5, stderr.decode())
            result = json.loads(stdout)
            self.validator.validate(result)
            self.assertEqual(result['exit_code'], 5)
            self.assertEqual(result['details']['receipt']['results'], [])
            with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
            self.assertEqual(self.tip(), self.initial)
        finally:
            if worker.poll() is None:
                worker.terminate(); worker.communicate(timeout=15)

if __name__ == '__main__':
    unittest.main(verbosity=2)
PY
