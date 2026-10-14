#!/usr/bin/env bash
# Complete manifest-bound publication with owned files and durable state.
# GitHub authentication/HTTP is a file-backed transport. Signature tests use
# genuine Minisign unless the explicit non-cryptographic fixture is selected.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
for tool in python3 jq flock; do
    command -v "$tool" >/dev/null || { printf 'SKIP: missing %s\n' "$tool"; exit 0; }
done
python3 -I - "$ROOT" "$@" <<'PY'
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
MODULE = Path(os.environ.get('DSR_TEST_PAYLOAD_MODULE', ROOT / 'src/release_payloads.sh'))
PIN = '1' * 40

# The real validators, source/manifest checks, custody, retry ledger and
# publication guard all run. These callbacks represent GitHub observations
# and transport effects only. No real release, compiler or signing is claimed.
TRANSPORT = r'''
set -uo pipefail
source "$1/src/slsa.sh" || exit $?
source "$1/src/sbom.sh" || exit $?
source "$1/src/sbom_release.sh" || exit $?
source "$2" || exit $?
shift 2
_sbr_require() { printf 'auth\n' >> "$CASE/auth"; }
_sbr_run() { "$@"; }
_sbr_context() { cat "$CASE/context.json"; }
_sbr_inventory() { jq -cS 'sort_by(.name)' "$CASE/inventory.json"; }
gh_download_release_asset() {
    printf '%s\n' "$2" >> "$CASE/downloads"
    cp -- "$CASE/remote/$2" "$3"
}
gh_upload_asset_named() {
    local path="$2" name="$3" id hash size receipt
    [[ "$1" == 'https://uploads.github.com/repos/owner/tool/releases/17/assets{?name,label}' &&
       "$4" == application/octet-stream && "$path" != "$CASE/artifacts/"* &&
       ! "$path" -ef "$CASE/artifacts/$name" ]] || return 4
    printf '%s\n' "$name" >> "$CASE/uploads"
    [[ "${FAULT:-}" != fail || "$name" != "${FAIL_NAME:-runtime.json}" ]] || return 8
    id=$(jq '([.[].id]+[100]|max)+1' "$CASE/inventory.json") || return 1
    hash=$(_slsa_sha256 "$path") || return $?
    size=$(wc -c < "$path") || return 1
    receipt=$(jq -nc --arg name "$name" --arg hash "$hash" --argjson size "$size" --argjson id "$id" \
        '{id:$id,name:$name,state:"uploaded",size:$size,digest:("sha256:"+$hash)}') || return 1
    cp -- "$path" "$CASE/remote/$id" || return 1
    [[ "${FAULT:-}" != no_digest ]] || receipt=$(jq '.digest=null' <<< "$receipt") || return 1
    jq -cS --argjson row "$receipt" '.+[$row]|sort_by(.name)' "$CASE/inventory.json" > "$CASE/next" || return 1
    mv -- "$CASE/next" "$CASE/inventory.json" || return 1
    case "${FAULT:-}" in
        lost) [[ "$name" != "${FAIL_NAME:-runtime.json}" ]] || return 8 ;;
        drift) printf changed >> "$CASE/artifacts/runtime.json" ;;
        tag) jq '.tag_commit=("2"*40)' "$CASE/context.json" > "$CASE/next"; mv "$CASE/next" "$CASE/context.json" ;;
    esac
    printf '%s\n' "$receipt"
}
release_upload_payloads "$@"
'''


class SharedPublicationTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='dsr-shared-publication-')).resolve()
        self.assets = self.root / 'artifacts'
        self.assets.mkdir()
        (self.root / 'remote').mkdir()
        for name in ('auth', 'uploads', 'downloads'):
            (self.root / name).touch()
        self.rows = []
        for name, data, target in (('tool-linux', b'owned platform payload', 'linux/amd64'),
                                   ('LICENSE', b'owned license text', 'additional'),
                                   ('runtime.json', b'{"data":"owned"}\n', 'additional')):
            (self.assets / name).write_bytes(data)
            self.rows.append(dict(name=name, sha256=hashlib.sha256(data).hexdigest(),
                                 target=target, size_bytes=len(data), archive_format='binary'))
        (self.assets / 'private.json').write_text('never publish unselected metadata')
        self.manifest = self.root / 'build-manifest.json'
        self.write_manifest()
        self.inventory = self.root / 'inventory.json'
        self.inventory.write_text('[]')
        self.context = self.root / 'context.json'
        self.context.write_text(json.dumps(dict(repository=dict(id=9, node_id='repo-9', full_name='owner/tool'),
            release=dict(id=17, node_id='release-17', tag_name='v1.0.0', draft=True, prerelease=False,
                         target_commitish='main', upload_url='https://uploads.github.com/repos/owner/tool/releases/17/assets{?name,label}'),
            tag_commit=PIN)))

    def write_manifest(self):
        self.manifest.write_text(json.dumps(dict(schema_version='1.0.0', tool='tool', version='v1.0.0',
            run_id='producer-fixture', built_at='2026-10-14T00:00:00Z', status='success',
            build_purpose='release', publishable=True,
            source=dict(git_sha=PIN, git_ref='refs/tags/v1.0.0', dependencies=[]),
            requested_targets=['linux/amd64'], artifacts=self.rows,
            summary=dict(total=1, success=1, failed=0))))

    def call(self, *options, fault=''):
        env = {k:v for k,v in os.environ.items() if not k.startswith('BASH_FUNC_') and k not in ('BASH_ENV','ENV','DRY_RUN')}
        env.update(CASE=str(self.root), FAULT=fault)
        return subprocess.run(['bash', '-c', TRANSPORT, '_', str(ROOT), str(MODULE), str(self.assets),
            '--build-manifest', str(self.manifest), '--repo', 'owner/tool', '--tag', 'v1.0.0', '--sha', PIN,
            '--state-dir', str(self.root / 'state'), *options], env=env, text=True,
            capture_output=True, timeout=60)

    def accepted(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def refused(self, result, no_upload=False):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse(result.stdout, 'failure must not publish a success receipt')
        if no_upload:
            self.assertEqual((self.root / 'uploads').read_text(), '')

    def test_upload_retry_and_public_readback_cover_shared_names(self):
        first = self.accepted(self.call())
        self.assertEqual([a['name'] for a in first['assets']], ['LICENSE', 'runtime.json', 'tool-linux'])
        self.assertEqual(first['upload_attempts'], 3)
        state = Path(first['state_file'])
        saved = state.read_bytes()
        uploads = (self.root / 'uploads').read_bytes()
        again = self.accepted(self.call())
        self.assertEqual(again['upload_attempts'], 0)
        self.assertEqual(state.read_bytes(), saved)
        context = json.loads(self.context.read_text()); context['release']['draft'] = False
        self.context.write_text(json.dumps(context))
        self.accepted(self.call())
        self.assertEqual((self.root / 'uploads').read_bytes(), uploads)
        actual = json.loads(self.inventory.read_text())
        self.assertNotIn('private.json', [a['name'] for a in actual])
        for record in actual:
            self.assertEqual((self.root / 'remote' / str(record['id'])).read_bytes(), (self.assets / record['name']).read_bytes())

    def test_dry_run_selects_shared_assets_without_auth_or_state(self):
        planned = self.accepted(self.call('--dry-run'))
        self.assertEqual(planned['status'], 'planned')
        self.assertEqual(len(planned['plan']['artifacts']), 3)
        self.assertFalse((self.root / 'auth').stat().st_size)
        self.assertFalse((self.root / 'state').exists())

    def test_lost_acknowledgement_reconciles_shared_file_without_reupload(self):
        self.refused(self.call(fault='lost'))
        self.assertEqual([a['name'] for a in json.loads(self.inventory.read_text())], ['LICENSE','runtime.json'])
        completed = self.accepted(self.call())
        self.assertEqual(completed['upload_attempts'], 1)
        self.assertEqual((self.root / 'uploads').read_text().splitlines().count('runtime.json'), 1)

    def test_partial_failure_retains_earlier_shared_file(self):
        self.refused(self.call(fault='fail'))
        state = next((self.root / 'state').rglob('state.json'))
        self.assertEqual([a['name'] for a in json.loads(state.read_text())['assets']], ['LICENSE'])
        self.assertFalse(json.loads(state.read_text())['complete'])
        self.assertEqual(self.accepted(self.call())['upload_attempts'], 2)

    def test_null_api_digest_uses_real_download_hash_and_refuses_changed_remote_bytes(self):
        self.accepted(self.call(fault='no_digest'))
        self.assertTrue((self.root / 'downloads').stat().st_size)
        row = next(r for r in json.loads(self.inventory.read_text()) if r['name']=='LICENSE')
        path = self.root / 'remote' / str(row['id']); path.chmod(0o600); path.write_bytes(b'bad remote license')
        uploads = (self.root / 'uploads').read_bytes()
        self.refused(self.call())
        self.assertEqual((self.root / 'uploads').read_bytes(), uploads)

    def test_all_declared_metadata_types_are_checked_before_authentication(self):
        path = self.assets / 'LICENSE'; path.rename(self.root / 'saved-license')
        for kind in ('missing', 'symlink', 'fifo', 'directory', 'wrong-bytes'):
            with self.subTest(kind=kind):
                if kind=='symlink': path.symlink_to(self.root / 'saved-license')
                elif kind=='fifo': os.mkfifo(path)
                elif kind=='directory': path.mkdir()
                elif kind=='wrong-bytes': path.write_bytes(b'x')
                self.refused(self.call(), no_upload=True)
                self.assertFalse((self.root / 'auth').stat().st_size)
                if path.exists() or path.is_symlink(): path.rename(self.root / ('retained-'+kind))

    def test_unplanned_binary_and_orphan_shared_signature_are_refused(self):
        extra = self.assets / 'unplanned-bin'; extra.write_bytes(b'not selected')
        self.refused(self.call(), no_upload=True)
        extra.rename(self.root / 'retained-unplanned')
        self.inventory.write_text(json.dumps([dict(id=90,name='LICENSE.minisig',state='uploaded',size=10,digest=None)]))
        self.refused(self.call(), no_upload=True)

    def test_late_local_change_or_tag_change_stops_later_uploads(self):
        for fault in ('drift','tag'):
            with self.subTest(fault=fault):
                self.setUp()
                self.refused(self.call(fault=fault))
                self.assertEqual(len((self.root / 'uploads').read_text().splitlines()),1)

    def test_completed_retry_refuses_same_name_shared_id_replacement(self):
        self.accepted(self.call())
        rows=json.loads(self.inventory.read_text()); rows[0]['id']=999
        self.inventory.write_text(json.dumps(rows))
        uploads=(self.root/'uploads').read_bytes()
        self.refused(self.call())
        self.assertEqual((self.root/'uploads').read_bytes(), uploads)

    def test_platform_payload_may_have_an_explicit_metadata_name(self):
        row = self.rows[0]; old=self.assets/row['name']; row['name']='tool.json'; old.rename(self.assets/row['name'])
        self.write_manifest()
        self.assertEqual(len(self.accepted(self.call())['assets']),3)

    def test_ordinary_binary_only_publication_is_unchanged(self):
        self.rows=self.rows[:1]; self.write_manifest()
        result=self.accepted(self.call())
        self.assertEqual([a['name'] for a in result['assets']],['tool-linux'])
        self.assertEqual(result['upload_attempts'],1)


# Only the signer executable is substituted under this explicit opt-in.
# Its digest/token checks are a control-flow fixture, NOT Minisign crypto.
# Without the opt-in, genuine Minisign must be installed for these tests.
MINISIGN_FIXTURE = r'''#!/bin/sh
exec python3 -I -S - "$@" <<'FIXTURE_PY'
import hashlib, json, os, sys
from pathlib import Path
args = sys.argv[1:]
def value(flag):
    return args[args.index(flag) + 1]
try:
    source = Path(value('-m'))
    signature = Path(value('-x'))
    checksum = hashlib.sha256(source.read_bytes()).hexdigest()
    with (Path(os.environ['CASE']) / 'signer-calls').open('a') as stream:
        stream.write(('sign' if '-S' in args else 'verify') + '\n')
    if '-S' in args:
        token = Path(value('-s')).read_text().strip()
        with signature.open('x') as stream:
            json.dump(dict(fixture='not-minisign', token=token, sha256=checksum,
                           trusted=value('-t')), stream, sort_keys=True)
    elif '-V' in args and '-H' in args:
        proof = json.loads(signature.read_text())
        if proof.get('fixture') != 'not-minisign' or proof.get('token') != value('-P') or proof.get('sha256') != checksum:
            sys.exit(1)
    else:
        sys.exit(2)
except (OSError, ValueError, IndexError, TypeError):
    sys.exit(1)
FIXTURE_PY
'''

INTEGRITY_PROGRAM = TRANSPORT.rsplit('release_upload_payloads "$@"', 1)[0] + r'''
source "$SIGNING_MODULE" || exit $?
source "$INTEGRITY_MODULE" || exit $?
action=$1; shift
case "$action" in
    prepare) release_prepare_integrity "$@" ;;
    verify) release_verify_integrity "$@" ;;
    publish) release_publish_integrity "$@" ;;
    verify-release) release_verify_remote_integrity "$@" ;;
    *) exit 4 ;;
esac
'''


@unittest.skipUnless(shutil.which('minisign') or os.environ.get('DSR_TEST_MINISIGN_FIXTURE') == '1',
                     'requires Minisign; DSR_TEST_MINISIGN_FIXTURE=1 explicitly selects a non-cryptographic boundary fixture')
class SharedIntegrityTests(unittest.TestCase):
    write_manifest = SharedPublicationTests.write_manifest
    call = SharedPublicationTests.call
    accepted = SharedPublicationTests.accepted
    refused = SharedPublicationTests.refused

    @classmethod
    def setUpClass(cls):
        cls.fixture = os.environ.get('DSR_TEST_MINISIGN_FIXTURE') == '1'
        print('Integrity signer: ' + ('EXPLICIT non-cryptographic fixture' if cls.fixture else 'genuine Minisign'), file=sys.stderr)

    def setUp(self):
        SharedPublicationTests.setUp(self)
        self.proofs = self.root / 'proofs'
        self.public = self.root / 'trusted.pub'
        self.private = self.root / 'signing.key'
        self.signer_env = {}
        if self.fixture:
            binaries = self.root / 'bin'; binaries.mkdir()
            executable = binaries / 'minisign'
            executable.write_text(MINISIGN_FIXTURE); executable.chmod(0o700)
            token = 'A' * 56
            self.public.write_text('untrusted comment: TEST FIXTURE, NOT A KEY\n' + token + '\n')
            self.private.write_text(token)
            self.signer_env['PATH'] = str(binaries) + os.pathsep + os.environ.get('PATH', '')
        else:
            subprocess.run(['minisign', '-G', '-W', '-p', str(self.public), '-s', str(self.private)],
                           check=True, capture_output=True, timeout=30)
        self.private.chmod(0o600)

    def integrity(self, action, *options, fault='', key=None, secret=None, module=None):
        env = {k:v for k,v in os.environ.items() if not k.startswith('BASH_FUNC_') and k not in ('BASH_ENV','ENV','DRY_RUN')}
        env.update(self.signer_env)
        env.update(CASE=str(self.root), FAULT=fault, FAIL_NAME='runtime.json.minisig',
                   SIGNING_MODULE=str(ROOT / 'src/signing.sh'),
                   INTEGRITY_MODULE=str(module or os.environ.get('DSR_TEST_INTEGRITY_MODULE', ROOT / 'src/release_integrity.sh')))
        arguments = ['--repo', 'owner/tool', '--tag', 'v1.0.0', '--sha', PIN, '--public-key', str(key or self.public)]
        if action != 'verify-release':
            arguments = [str(self.assets), '--build-manifest', str(self.manifest), '--output-dir', str(self.proofs), *arguments]
        if action == 'prepare':
            arguments += ['--secret-key', str(secret or self.private)]
        return subprocess.run(['bash', '-c', INTEGRITY_PROGRAM, '_', str(ROOT), str(MODULE), action,
                               *arguments, *options], env=env, text=True, capture_output=True, timeout=90)

    def proof_bytes(self):
        return {p.name:p.read_bytes() for p in self.proofs.iterdir() if p.is_file()}

    def prepare(self):
        return self.accepted(self.integrity('prepare'))

    def test_prepare_verify_and_retry_preserve_all_shared_signatures(self):
        self.prepare()
        saved = self.proof_bytes()
        self.assertEqual(set(saved), {'LICENSE.minisig','runtime.json.minisig','tool-linux.minisig',
            'checksums.sha256','checksums.sha256.minisig','release-integrity.json','release-integrity.json.minisig'})
        expected = ''.join(r['sha256'] + '  ' + r['name'] + '\n' for r in sorted(self.rows,key=lambda r:r['name']))
        self.assertEqual(saved['checksums.sha256'].decode(), expected)
        self.accepted(self.integrity('verify'))
        self.prepare()
        self.assertEqual(self.proof_bytes(), saved)
        self.assertFalse((self.root / 'auth').stat().st_size)

    def test_publish_and_independent_remote_readback_cover_the_whole_signed_set(self):
        self.prepare()
        self.accepted(self.call())
        result = self.accepted(self.integrity('publish'))
        expected = sorted([r['name'] for r in self.rows] + list(self.proof_bytes()))
        self.assertEqual([r['name'] for r in result['assets']], expected)
        first = (self.root/'uploads').read_bytes()
        saved = self.proof_bytes()
        verified = self.accepted(self.integrity('verify-release'))
        self.assertEqual(verified['assets'], result['assets'])
        rows = json.loads(self.inventory.read_text())
        for row in rows:
            self.assertIn(str(row['id']), (self.root/'downloads').read_text().splitlines())
        context = json.loads(self.context.read_text()); context['release']['draft'] = False
        self.context.write_text(json.dumps(context))
        self.accepted(self.integrity('publish'))
        self.assertEqual((self.root/'uploads').read_bytes(), first)
        self.assertEqual(self.proof_bytes(), saved)

    def test_reserved_proof_names_and_case_collisions_fail_before_signing(self):
        for name in ('checksums.sha256', 'checksums.sha256.minisig', 'release-integrity.json',
                     'release-integrity.json.minisig', 'LICENSE.minisig', 'license', 'RELEASE-INTEGRITY.JSON'):
            with self.subTest(name=name):
                original = self.rows[2]['name']; self.rows[2]['name'] = name
                (self.assets/original).rename(self.assets/name); self.write_manifest()
                for arguments in ((), ('--dry-run',)):
                    result = self.integrity('prepare', *arguments)
                    self.assertEqual(result.returncode,4,result.stderr)
                    self.assertIn('collide',result.stderr)
                    self.assertFalse(result.stdout)
                self.assertFalse(self.proofs.exists())
                self.assertFalse((self.root/'signer-calls').exists())
                (self.assets/name).rename(self.assets/original); self.rows[2]['name']=original; self.write_manifest()

    def test_secret_key_may_not_overlap_a_shared_payload(self):
        result = self.integrity('prepare', secret=self.assets/'LICENSE')
        self.assertEqual(result.returncode,4,result.stderr)
        self.assertIn('Signing key overlaps',result.stderr)
        self.assertFalse(self.proofs.exists())
        self.assertFalse((self.root/'signer-calls').exists())

    def test_local_shared_corruption_does_not_resign_or_replace_proofs(self):
        self.prepare(); saved=self.proof_bytes()
        (self.assets/'LICENSE').write_bytes(b'x'*len((self.assets/'LICENSE').read_bytes()))
        self.refused(self.integrity('verify'))
        self.refused(self.integrity('prepare'))
        self.assertEqual(self.proof_bytes(),saved)

    def test_shared_signature_or_trust_key_change_is_refused(self):
        self.prepare()
        other = self.root/'other.pub'; other.write_text('untrusted comment: wrong key\n'+'B'*56+'\n')
        self.refused(self.integrity('verify',key=other))
        signature=self.proofs/'LICENSE.minisig'; signature.write_bytes(b'invalid detached signature')
        before=self.proof_bytes()
        self.refused(self.integrity('verify'))
        self.refused(self.integrity('prepare'))
        self.assertEqual(self.proof_bytes(),before)

    def test_missing_shared_remote_payload_cannot_be_fabricated_from_expected_names(self):
        self.prepare(); self.accepted(self.call())
        rows=json.loads(self.inventory.read_text())
        self.inventory.write_text(json.dumps([r for r in rows if r['name']!='LICENSE']))
        uploads=(self.root/'uploads').read_bytes()
        self.refused(self.integrity('publish'))
        self.assertEqual((self.root/'uploads').read_bytes(),uploads)

    def test_corrupt_remote_shared_bytes_fail_even_without_an_api_digest(self):
        self.prepare(); self.accepted(self.call()); self.accepted(self.integrity('publish'))
        rows=json.loads(self.inventory.read_text())
        row=next(r for r in rows if r['name']=='LICENSE'); row['digest']=None
        self.inventory.write_text(json.dumps(rows))
        payload=self.root/'remote'/str(row['id']); payload.chmod(0o600); payload.write_bytes(b'x'*row['size'])
        self.refused(self.integrity('verify-release'))

    def test_unselected_remote_metadata_is_ignored_but_unplanned_binary_is_not(self):
        self.prepare(); self.accepted(self.call()); self.accepted(self.integrity('publish'))
        rows=json.loads(self.inventory.read_text()); rows.append(dict(id=999,name='private.json',state='uploaded',size=5,digest=None))
        self.inventory.write_text(json.dumps(rows))
        self.accepted(self.integrity('verify-release'))
        self.assertNotIn('999',(self.root/'downloads').read_text().splitlines())
        rows[-1]['name']='unplanned-bin'; self.inventory.write_text(json.dumps(rows))
        self.refused(self.integrity('verify-release'))

    def test_signature_upload_loss_is_reconciled_without_resigning_or_reupload(self):
        self.prepare(); saved=self.proof_bytes(); self.accepted(self.call())
        self.refused(self.integrity('publish',fault='lost'))
        self.assertIn('runtime.json.minisig',[r['name'] for r in json.loads(self.inventory.read_text())])
        self.accepted(self.integrity('publish'))
        self.assertEqual((self.root/'uploads').read_text().splitlines().count('runtime.json.minisig'),1)
        self.assertEqual(self.proof_bytes(),saved)

    def test_late_shared_source_drift_stops_following_proof_uploads(self):
        self.prepare(); self.accepted(self.call()); count=len((self.root/'uploads').read_text().splitlines())
        self.refused(self.integrity('publish',fault='drift'))
        self.assertEqual(len((self.root/'uploads').read_text().splitlines()),count+1)

    def test_original_binary_only_signed_release_still_works(self):
        self.rows=self.rows[:1]; self.write_manifest()
        self.prepare(); self.accepted(self.call()); self.accepted(self.integrity('publish'))
        result=self.accepted(self.integrity('verify-release'))
        self.assertEqual(len(result['assets']),6)


if __name__=='__main__':
    unittest.main(verbosity=2)
PY
