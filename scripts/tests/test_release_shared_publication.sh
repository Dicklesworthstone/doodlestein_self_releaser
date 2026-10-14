#!/usr/bin/env bash
# Complete manifest-bound publication with owned files and durable state.
# Only GitHub authentication/HTTP is replaced by a file-backed transport.
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
    [[ "${FAULT:-}" != fail || "$name" != runtime.json ]] || return 8
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
        lost) [[ "$name" != runtime.json ]] || return 8 ;;
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


if __name__=='__main__':
    unittest.main(verbosity=2)
PY
