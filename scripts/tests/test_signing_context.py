#!/usr/bin/env python3
"""Exercise full production signing module; no fake cryptographic success.

Small byte fixtures test inventory admission, not compiler/ABI provenance.
Cryptographic lifecycle tests invoke genuine Minisign or explicitly skip.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE = Path(os.environ.get('DSR_TEST_SIGNING_MODULE', ROOT / 'src/signing.sh'))
BASH = os.environ.get('DSR_TEST_BASH', 'bash')


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SigningContext(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='dsr-sign-context-test-')
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.out = self.root / 'release with spaces'
        self.out.mkdir()
        self.payload = self.out / 'sbh_linux_amd64'
        self.companion = self.out / 'sbh_darwin_arm64'
        self.payload.write_bytes(b'linux payload bytes')
        self.companion.write_bytes(b'apple silicon payload bytes')
        self.manifest = self.out / 'sbh-v1.2.3-manifest.json'
        self.body = dict(tool='sbh', version='v1.2.3', status='success',
                         build_purpose='release', publishable=True,
                         source=dict(git_sha='a'*40), artifacts=[
                             dict(name=p.name, target=t, sha256=sha(p), size_bytes=p.stat().st_size)
                             for p, t in [(self.payload, 'linux/amd64'), (self.companion, 'darwin/arm64')]])
        self.save()

    def save(self):
        self.manifest.write_text(json.dumps(self.body) + '\n')

    def call(self, code, *args, expected=0, env=None):
        result = subprocess.run([BASH, '-c', 'set -uo pipefail; source "$1"; shift; ' + code,
                                 '_', str(MODULE), *map(str,args)], text=True,
                                capture_output=True, timeout=30, env=env)
        self.assertEqual(result.returncode, expected, result.stderr)
        return result

    def snapshot(self, *paths):
        return self.call('_signing_release_manifest_snapshot "$@"', *(paths or [self.payload])).stdout.strip()

    def check(self, frozen, expected=0, *paths):
        return self.call('_signing_release_snapshot_matches "$@"', frozen, *(paths or [self.payload]), expected=expected)

    def test_unchanged_snapshot_retains_exact_manifest_name_and_bytes(self):
        frozen = self.snapshot()
        self.assertEqual(json.loads(frozen), [dict(manifest=str(self.manifest), sha256=sha(self.manifest))])
        self.check(frozen)

    def test_current_predicate_alone_accepts_changed_source_but_snapshot_refuses(self):
        frozen = self.snapshot()
        self.body['source']['git_sha'] = 'b'*40
        self.save()
        self.call('_signing_release_preflight "$@"', self.payload)
        self.check(frozen, 4)

    def test_same_payload_bytes_do_not_permit_target_identity_change(self):
        frozen = self.snapshot()
        self.body['artifacts'][0]['target'] = 'darwin/amd64'
        self.save()
        self.call('_signing_release_preflight "$@"', self.payload)
        self.check(frozen, 4)

    def test_disappearing_manifest_does_not_turn_release_into_generic_signing(self):
        frozen = self.snapshot()
        self.manifest.rename(self.root / 'retained-manifest.json')
        self.call('_signing_release_preflight "$@"', self.payload)
        self.check(frozen, 4)

    def test_manifest_rename_is_not_an_equivalent_selection(self):
        frozen = self.snapshot()
        self.manifest.rename(self.out / 'other-manifest.json')
        self.call('_signing_release_preflight "$@"', self.payload)
        self.check(frozen, 4)

    def test_additional_consistent_manifest_changes_the_selected_set(self):
        frozen = self.snapshot()
        shutil.copy2(self.manifest, self.out / 'other-manifest.json')
        self.call('_signing_release_preflight "$@"', self.payload)
        self.check(frozen, 4)

    def test_consistent_subset_after_removing_unselected_payload_still_refuses(self):
        frozen = self.snapshot()
        self.companion.rename(self.root / 'retained-arm64')
        self.body['artifacts'] = self.body['artifacts'][:1]
        self.save()
        self.call('_signing_release_preflight "$@"', self.payload)
        self.check(frozen, 4)

    def test_payload_mutation_refuses_without_reselecting_manifest(self):
        frozen = self.snapshot()
        self.companion.write_bytes(b'mutation')
        self.check(frozen,4)

    def test_duplicate_paths_and_reversed_inputs_have_one_context(self):
        self.assertEqual(self.snapshot(self.payload,self.companion,self.payload),
                         self.snapshot(self.companion,self.payload))

    def test_manifest_snapshot_order_is_stable(self):
        other = self.out / 'first-manifest.json'
        shutil.copy2(self.manifest,other)
        frozen = self.snapshot()
        rows = json.loads(frozen)
        self.assertEqual(rows, sorted(rows,key=lambda r:r['manifest']))
        self.check(frozen)

    def test_multiple_directories_are_independently_bound(self):
        second = self.root / 'second'
        shutil.copytree(self.out,second)
        selected = second / self.payload.name
        frozen = self.snapshot(self.payload,selected)
        self.assertEqual(len(json.loads(frozen)),2)
        self.assertEqual(frozen,self.snapshot(selected,self.payload))
        (second / self.manifest.name).rename(self.root / 'removed.json')
        self.check(frozen,4,self.payload,selected)

    def test_generic_signing_without_manifest_retains_empty_context(self):
        self.manifest.rename(self.root / 'retained.json')
        frozen = self.snapshot()
        self.assertEqual(frozen,'[]')
        self.check(frozen)

    def test_new_manifest_cannot_appear_during_generic_signing(self):
        stored=self.root/'retained.json'
        self.manifest.rename(stored)
        frozen=self.snapshot()
        stored.rename(self.manifest)
        self.check(frozen,4)

    def test_symlink_manifest_is_rejected(self):
        stored=self.root/'retained.json'
        self.manifest.rename(stored)
        self.manifest.symlink_to(stored)
        self.call('_signing_release_manifest_snapshot "$@"',self.payload,expected=4)

    def test_broken_manifest_symlink_is_rejected(self):
        self.manifest.rename(self.root/'retained.json')
        self.manifest.symlink_to(self.root/'missing')
        self.call('_signing_release_manifest_snapshot "$@"',self.payload,expected=4)

    def test_manifest_directory_is_rejected(self):
        self.manifest.rename(self.root/'retained.json')
        self.manifest.mkdir()
        self.call('_signing_release_manifest_snapshot "$@"',self.payload,expected=4)

    def test_inherited_glob_options_cannot_hide_context(self):
        frozen=self.snapshot()
        actual=self.call('GLOBIGNORE="*"; set -f; shopt -s failglob; _signing_release_manifest_snapshot "$@"',self.payload)
        self.assertEqual(actual.stdout.strip(),frozen)

    def test_failed_enumeration_is_not_empty_context(self):
        result=self.call('find() { printf "INJECTED_FIND_FAILURE\\n" >&2; return 13; }; '
                         '_signing_release_manifest_snapshot "$@"',self.payload,expected=4)
        self.assertIn('INJECTED_FIND_FAILURE',result.stderr)
        self.assertEqual(result.stdout,'')

    def test_helper_does_not_change_caller_traps_or_shell_flags(self):
        self.call('before=$(set +o; trap -p); _signing_release_manifest_snapshot "$@" >/dev/null || exit; '
                  'after=$(set +o; trap -p); [[ "$before" == "$after" ]]',self.payload)

    def test_snapshot_validation_removes_only_own_private_staging(self):
        temp=self.root/'scratch'; temp.mkdir()
        keep=temp/'keep'; keep.write_text('unrelated')
        self.call('_signing_release_manifest_snapshot "$@"',self.payload,env=dict(os.environ,TMPDIR=str(temp)))
        self.assertEqual(list(temp.iterdir()),[keep])

    def test_explicit_admission_accepts_separate_nonstandard_manifest(self):
        stored=self.root/'inventory.json'
        self.manifest.rename(stored)
        self.call('signing_validate_release_inventory "$@"',stored,self.out,sha(stored))
        self.companion.rename(self.root/'retained-arm64')
        self.call('signing_validate_release_inventory "$@"',stored,self.out,sha(stored),expected=4)

    def test_explicit_admission_requires_frozen_digest(self):
        self.call('signing_validate_release_inventory "$@"',self.manifest,self.out,'0'*64,expected=4)

    def test_public_entrypoints_validate_before_private_key_use(self):
        self.companion.rename(self.root/'retained-arm64')
        for function in ('signing_sign','signing_sign_batch'):
            with self.subTest(function=function):
                result=self.call('signing_require_minisign() { printf "UNEXPECTED_KEY_USE\\n" >&2; return 3; }; '
                                 + function + ' "$@"',self.payload,expected=4)
                self.assertNotIn('UNEXPECTED_KEY_USE',result.stderr)

    def make_key(self):
        key=self.root/'key'; public=self.root/'minisign.pub'
        subprocess.run(['minisign','-G','-W','-s',str(key),'-p',str(public)],check=True,capture_output=True,timeout=20)
        return dict(os.environ,DSR_CONFIG_DIR=str(self.root),DSR_MINISIGN_KEY=str(key),
                    CONTEXT_MANIFEST=str(self.manifest),CONTEXT_ROOT=str(self.root))

    @unittest.skipUnless(shutil.which('minisign'),'real Minisign unavailable')
    def test_real_batch_refuses_consistent_manifest_mutation_before_publication(self):
        env=self.make_key()
        result=self.call(r'''minisign() {
    command minisign "$@" || return $?
    if [[ "${1:-}" == -S ]]; then
        jq '.source.git_sha=("b"*40)' "$CONTEXT_MANIFEST" > "$CONTEXT_ROOT/changed.json" || return
        mv "$CONTEXT_ROOT/changed.json" "$CONTEXT_MANIFEST"
    fi
}; signing_sign_batch "$@"''',self.payload,env=env,expected=4)
        self.assertIn('manifest set or bytes changed',result.stderr)
        self.assertFalse(list(self.out.glob('*.minisig')))

    @unittest.skipUnless(shutil.which('minisign'),'real Minisign unavailable')
    def test_real_batch_refuses_manifest_disappearance_before_publication(self):
        env=self.make_key()
        self.call(r'''minisign() {
    command minisign "$@" || return $?
    if [[ "${1:-}" == -S && -f "$CONTEXT_MANIFEST" ]]; then
        mv "$CONTEXT_MANIFEST" "$CONTEXT_ROOT/retained.json"
    fi
}; signing_sign_batch "$@"''',self.payload,env=env,expected=4)
        self.assertFalse(list(self.out.glob('*.minisig')))

    @unittest.skipUnless(shutil.which('minisign'),'real Minisign unavailable')
    def test_real_retained_batch_refuses_manifest_switch_during_verification(self):
        env=self.make_key()
        self.call('signing_sign_batch "$@"',self.payload,env=env)
        signature=Path(str(self.payload)+'.minisig'); before=signature.read_bytes()
        self.call(r'''minisign() {
    command minisign "$@" || return $?
    if [[ "${1:-}" == -V ]]; then
        jq '.source.git_sha=("b"*40)' "$CONTEXT_MANIFEST" > "$CONTEXT_ROOT/changed.json" || return
        mv "$CONTEXT_ROOT/changed.json" "$CONTEXT_MANIFEST"
    fi
}; signing_sign_batch "$@"''',self.payload,env=env,expected=4)
        self.assertEqual(before,signature.read_bytes())

    @unittest.skipUnless(shutil.which('minisign'),'real Minisign unavailable')
    def test_real_unchanged_batch_signs_and_reuses_byte_identical_proofs(self):
        env=self.make_key()
        self.call('signing_sign_batch "$@"',self.payload,self.companion,self.manifest,env=env)
        signatures={p.name:p.read_bytes() for p in self.out.glob('*.minisig')}
        self.assertEqual(len(signatures),3)
        self.call('signing_sign_batch "$@"',self.companion,self.manifest,self.payload,env=env)
        self.assertEqual(signatures,{p.name:p.read_bytes() for p in self.out.glob('*.minisig')})
        for p in (self.payload,self.companion,self.manifest):
            self.call('signing_verify "$@"',p,env=env)


if __name__ == '__main__':
    unittest.main(verbosity=2)
