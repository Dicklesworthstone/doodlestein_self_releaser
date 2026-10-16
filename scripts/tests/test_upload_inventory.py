#!/usr/bin/env python3
"""Production GitHub upload + signing inventory integration, without live uploads.

The only substituted boundaries are GitHub transport and token resolution.
Files, compiler, archive bytes, hashing, snapshot admission, retry/reconciliation
and receipt validation are real. Go cross-compilation is not native execution
on macOS or ARM. This suite does not substitute or claim cryptographic signing.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(os.environ.get('DSR_TEST_SOURCE_ROOT', Path(__file__).resolve().parents[2]))
MODULE = Path(os.environ.get('DSR_TEST_GITHUB_MODULE', ROOT / 'src/github.sh'))
BASH = os.environ.get('DSR_TEST_BASH', 'bash')
TARGETS = ('linux/amd64', 'linux/arm64', 'darwin/amd64', 'darwin/arm64')
URL = 'https://uploads.github.com/repos/fixture/project/releases/123/assets{?name,label}'


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


PROTOCOL = r'''import hashlib, json, os, pathlib, shutil, sys, urllib.parse
root = pathlib.Path(os.environ['DSR_TEST_REMOTE'])
config = json.loads((root/'config.json').read_text())
mode, args = sys.argv[1], sys.argv[2:]
with (root/'events.jsonl').open('a') as out:
    out.write(json.dumps({'mode':mode,'args':args})+'\n')
state = json.loads((root/'remote.json').read_text())
def mutate(where):
    if config.get('mutate_at') != where: return
    manifest = pathlib.Path(config['manifest'])
    kind = config['mutation']
    if kind == 'remove_manifest':
        if manifest.exists(): manifest.rename(root/'retained-manifest')
    elif kind == 'add_manifest':
        shutil.copy2(manifest, manifest.parent/'additional-manifest.json')
    elif kind == 'add_payload':
        (manifest.parent/'unlisted_arm64').write_bytes(b'late payload')
    elif kind == 'checksum':
        (manifest.parent/'SHA256SUMS').write_bytes(b'changed checksums')
    elif kind == 'payload':
        pathlib.Path(config['victim']).write_bytes(b'changed payload')
    else:
        body = json.loads(manifest.read_text())
        if kind == 'source': body['source']['git_sha'] = 'b'*40
        elif kind == 'target': body['artifacts'][0]['target'] = 'darwin/arm64'
        elif kind == 'subset':
            victim = pathlib.Path(config['victim'])
            if victim.exists(): victim.rename(root/'retained-payload')
            body['artifacts'] = [r for r in body['artifacts'] if r['name'] != victim.name]
            sums = manifest.parent/'SHA256SUMS'
            sums.write_text(''.join(r['sha256']+'  '+r['name']+'\n' for r in body['artifacts']))
        manifest.write_text(json.dumps(body)+'\n')
if mode == 'TOKEN':
    print('fixture-token-not-a-secret')
elif mode == 'GET':
    mutate('get')
    if config.get('get_error'): raise SystemExit(8)
    if config.get('malformed_get'):
        print('{}'); raise SystemExit(0)
    query = urllib.parse.parse_qs(urllib.parse.urlsplit('https://fixture/'+args[0]).query)
    page = int(query.get('page',['1'])[0])
    print(json.dumps(state['assets'][(page-1)*100:page*100]))
elif mode == 'DOWNLOAD':
    shutil.copyfile(root/'bytes'/args[1], args[2])
elif mode == 'POST':
    assert '-X' in args and args[args.index('-X')+1] == 'POST'
    body = pathlib.Path(args[args.index('--data-binary')+1][1:]).read_bytes()
    url = urllib.parse.urlsplit(args[-1])
    assert url.hostname == 'uploads.github.com'
    assert url.path == '/repos/fixture/project/releases/123/assets'
    name = urllib.parse.parse_qs(url.query)['name'][0]
    number = state.get('posts',0)
    statuses = config.get('post_statuses',[201])
    status = statuses[min(number,len(statuses)-1)]
    state['posts'] = number+1
    record = {'id':1000+len(state['assets']), 'name':name, 'state':'uploaded',
              'size':len(body),'digest':'sha256:'+hashlib.sha256(body).hexdigest()}
    record.update(config.get('receipt_override',{}))
    if status == 201 or config.get('store_on_error'):
        state['assets'].append(record)
        (root/'bytes'/str(record['id'])).write_bytes(body)
    (root/'remote.json').write_text(json.dumps(state))
    response = record if status == 201 else {'message':'fixture transport interruption'}
    pathlib.Path(args[args.index('-o')+1]).write_text(json.dumps(response))
    pathlib.Path(args[args.index('-D')+1]).write_text('HTTP/1.1 '+str(status)+' fixture\r\n\r\n')
    mutate('post')
    print(status,end='')
else:
    raise AssertionError(mode)
'''

SCRIPT = r'''source "$1"
_gh_resolve_token() { "$DSR_TEST_PYTHON" "$DSR_TEST_PROTOCOL" TOKEN; }
gh_api() { "$DSR_TEST_PYTHON" "$DSR_TEST_PROTOCOL" GET "$@"; }
gh_download_release_asset() { "$DSR_TEST_PYTHON" "$DSR_TEST_PROTOCOL" DOWNLOAD "$@"; }
curl() { "$DSR_TEST_PYTHON" "$DSR_TEST_PROTOCOL" POST "$@"; }
if [[ "${DSR_TEST_BAD_GLOBS:-}" == 1 ]]; then
    GLOBIGNORE='*'; set -f; shopt -s failglob
fi
case "$2" in
    named) gh_upload_asset_named "$3" "$4" "$5" ;;
    ordinary) gh_upload_asset "$3" "$4" ;;
    *) exit 99 ;;
esac
'''


class UploadInventory(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for tool in (BASH, 'go', 'jq', 'find', 'cmp', 'wc'):
            if not shutil.which(tool):
                raise unittest.SkipTest(f'{tool} required; no fake compiler or hashes')
        cls.compilation = tempfile.TemporaryDirectory(prefix='dsr-upload-compiled-')
        cls.addClassCleanup(cls.compilation.cleanup)
        cls.compiled = Path(cls.compilation.name)
        for name in ('sbh','inspector'):
            source = cls.compiled / (name+'.go')
            source.write_text('package main\nfunc main() { println("'+name+' fixture") }\n')
            for target in TARGETS:
                goos, goarch = target.split('/')
                path = cls.compiled/(name+'_'+goos+'_'+goarch)
                env = dict(os.environ, GOOS=goos, GOARCH=goarch, CGO_ENABLED='0',
                           GOTOOLCHAIN='local', GO111MODULE='off')
                subprocess.run(['go','build','-trimpath','-ldflags=-s -w','-o',str(path),str(source)],
                               env=env, check=True, capture_output=True, timeout=180)
                head=path.read_bytes()[:32]
                if goos=='linux':
                    assert head[:4]==b'\x7fELF'
                    assert struct.unpack_from('<H',head,18)[0] == (62 if goarch=='amd64' else 183)
                else:
                    assert head[:4]==b'\xcf\xfa\xed\xfe'
                    assert struct.unpack_from('<I',head,4)[0] == (0x01000007 if goarch=='amd64' else 0x0100000c)

    def setUp(self):
        self.work=tempfile.TemporaryDirectory(prefix='dsr-upload-inventory-')
        self.addCleanup(self.work.cleanup)
        self.root=Path(self.work.name)
        self.out=self.root/'release with spaces'; self.out.mkdir()
        self.remote=self.root/'remote'; self.remote.mkdir(); (self.remote/'bytes').mkdir()
        self.protocol=self.root/'protocol.py'; self.protocol.write_text(PROTOCOL)
        self.manifest=self.out/'sbh-v0.7.5-manifest.json'
        self.rows=[]
        for target in TARGETS:
            suffix=target.replace('/','_')
            triple={'linux/amd64':'x86_64-unknown-linux-gnu','linux/arm64':'aarch64-unknown-linux-gnu',
                    'darwin/amd64':'x86_64-apple-darwin','darwin/arm64':'aarch64-apple-darwin'}[target]
            for name in ('sbh','inspector'):
                path=self.out/(name+'_'+suffix)
                shutil.copy2(self.compiled/path.name,path)
                self.add(path,target,triple,'none')
            fmt='zip' if target.startswith('darwin') else 'tar.xz'
            path=self.out/('bundle_'+suffix+'.'+fmt)
            if fmt=='zip':
                with zipfile.ZipFile(path,'w') as archive:
                    for name in ('sbh','inspector'): archive.write(self.out/(name+'_'+suffix),name)
            else:
                with tarfile.open(path,'w:xz') as archive:
                    for name in ('sbh','inspector'): archive.add(self.out/(name+'_'+suffix),arcname=name)
            self.add(path,target,triple,fmt)
        self.body={'tool':'sbh','version':'v0.7.5','status':'success','build_purpose':'release',
                   'publishable':True,'source':{'git_sha':'a'*40},'artifacts':self.rows}
        self.save()
        self.sums=self.out/'SHA256SUMS'; self.checksums()
        (self.remote/'remote.json').write_text(json.dumps({'assets':[]}))
        (self.remote/'events.jsonl').write_text('')
        self.config={'manifest':str(self.manifest),'victim':str(self.out/'sbh_darwin_arm64')}
        self.env=dict(os.environ, DSR_TEST_PYTHON=sys.executable, DSR_TEST_PROTOCOL=str(self.protocol),
                      DSR_TEST_REMOTE=str(self.remote), GH_MAX_RETRIES='2', GH_RETRY_DELAY='0',
                      DSR_CONFIG_DIR=str(self.root/'config'), DSR_NO_SIGN='1',
                      DSR_SIGNING_ENABLED='false')

    def add(self,path,target,triple,fmt):
        self.rows.append({'name':path.name,'target':target,'target_triple':triple,
                          'sha256':sha(path),'size_bytes':path.stat().st_size,'archive_format':fmt})

    def save(self): self.manifest.write_text(json.dumps(self.body)+'\n')

    def checksums(self):
        self.sums.write_text(''.join(r['sha256']+'  '+r['name']+'\n' for r in self.rows))
        for r in self.rows:
            (self.out/(r['name']+'.sha256')).write_text(r['sha256']+'  '+r['name']+'\n')

    def events(self): return [json.loads(s) for s in (self.remote/'events.jsonl').read_text().splitlines()]

    def state(self): return json.loads((self.remote/'remote.json').read_text())

    def upload(self,name='sbh_linux_amd64',published=None,expect=0,ordinary=False):
        (self.remote/'config.json').write_text(json.dumps(self.config))
        path=self.out/name
        result=subprocess.run([BASH,'-c',SCRIPT,'_',str(MODULE),
                               'ordinary' if ordinary else 'named',URL,str(path),published or name],
                              env=self.env, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode,expect,result.stderr)
        if expect:
            self.assertEqual(result.stdout,'',result.stdout)
        else:
            record=json.loads(result.stdout)
            self.assertEqual(record['name'],published or name)
            self.assertEqual(record['digest'],'sha256:'+sha(path))
        return result

    def refusal(self,name='sbh_linux_amd64',published=None):
        result=self.upload(name,published,expect=4)
        self.assertEqual(self.events(),[], 'invalid local inventory reached token/HTTP boundary')
        return result

    def test_complete_four_target_two_binary_inventory_reaches_remote_under_exact_names(self):
        for r in self.rows: self.upload(r['name'],ordinary=True)
        self.upload(self.manifest.name); self.upload('SHA256SUMS')
        for r in self.rows: self.upload(r['name']+'.sha256')
        assets={r['name']:r for r in self.state()['assets']}
        expected={r['name']:r['sha256'] for r in self.rows}
        actual={name:sha(self.remote/'bytes'/str(assets[name]['id'])) for name in expected}
        unsigned={line[66:]:line[:64] for line in self.sums.read_text().splitlines()}
        self.assertEqual(actual,expected); self.assertEqual(unsigned,expected)
        self.assertEqual(set(assets),set(expected)|{name+'.sha256' for name in expected}|{self.manifest.name,'SHA256SUMS'})
        for r in self.rows:
            self.assertEqual(assets[r['name']]['size'],r['size_bytes'])

    def test_existing_remote_asset_reuse_has_no_second_post(self):
        self.upload(); events=len([x for x in self.events() if x['mode']=='POST'])
        self.upload(); self.assertEqual(len([x for x in self.events() if x['mode']=='POST']),events)

    def test_manifest_incomplete_even_when_signing_disabled(self):
        self.body['artifacts']=[r for r in self.rows if r['name']!='sbh_darwin_arm64']; self.save()
        self.sums.unlink()
        self.refusal()

    def test_retained_remote_asset_does_not_bypass_incomplete_local_manifest(self):
        self.upload(); (self.remote/'events.jsonl').write_text('')
        self.body['artifacts']=self.rows[:-1]; self.save(); self.sums.unlink()
        self.refusal()

    def test_unlisted_raw_published_name_is_not_an_alias(self):
        self.refusal(published='sbh')

    def test_unlisted_architecture_alias_is_not_invented(self):
        self.refusal('sbh_linux_arm64','sbh_linux_aarch64')

    def test_unlisted_archive_alias_is_not_invented(self):
        self.refusal('bundle_darwin_arm64.zip','sbh_darwin_arm64.zip')

    def test_manifest_enumerated_identical_archive_alias_is_supported(self):
        old=self.rows[2]; path=self.out/'compatible.tar.xz'; shutil.copy2(self.out/old['name'],path)
        self.add(path,old['target'],old['target_triple'],old['archive_format']); self.save(); self.checksums()
        self.upload(old['name'],path.name)

    def test_alias_with_different_manifest_bytes_refuses(self):
        self.refusal('sbh_linux_amd64','sbh_darwin_arm64')

    def test_raw_payload_cannot_be_published_as_checksum_document(self):
        self.refusal(published='SHA256SUMS')

    def test_raw_payload_cannot_be_published_as_a_signature(self):
        self.refusal(published='sbh_linux_amd64.minisig')

    def test_missing_companion_refuses_before_any_http(self):
        (self.out/'inspector_linux_arm64').unlink(); self.refusal()

    def test_changed_companion_refuses_before_any_http(self):
        (self.out/'inspector_darwin_arm64').write_bytes(b'wrong'); self.refusal()

    def test_wrong_size_refuses(self):
        self.rows[1]['size_bytes']+=1; self.save(); self.refusal()

    def test_checksum_mismatch_refuses(self):
        self.sums.write_text('0'*64+self.sums.read_text()[64:]); self.refusal()

    def test_checksum_omission_refuses(self):
        self.sums.write_text('\n'.join(self.sums.read_text().splitlines()[1:])+'\n'); self.refusal()

    def test_duplicate_names_refuse(self):
        self.rows.append(dict(self.rows[0])); self.save(); self.refusal()

    def test_duplicate_casefolded_names_refuse(self):
        self.rows.append(dict(self.rows[0],name=self.rows[0]['name'].upper())); self.save(); self.refusal()

    def test_source_symlink_refuses(self):
        path=self.out/'sbh_linux_amd64'; path.unlink(); path.symlink_to(self.compiled/path.name); self.refusal()

    def test_companion_symlink_refuses(self):
        path=self.out/'sbh_darwin_arm64'; path.unlink(); path.symlink_to(self.compiled/path.name); self.refusal()

    def test_manifest_removed_during_get_blocks_post(self):
        self.config.update(mutate_at='get',mutation='remove_manifest'); self.upload(expect=4)
        self.assertFalse(any(x['mode']=='POST' for x in self.events()))

    def test_source_identity_mutated_during_get_blocks_post(self):
        self.config.update(mutate_at='get',mutation='source'); self.upload(expect=4)
        self.assertFalse(any(x['mode']=='POST' for x in self.events()))

    def test_target_identity_mutated_during_get_blocks_post(self):
        self.config.update(mutate_at='get',mutation='target'); self.upload(expect=4)
        self.assertFalse(any(x['mode']=='POST' for x in self.events()))

    def test_new_unlisted_payload_during_get_blocks_post(self):
        self.config.update(mutate_at='get',mutation='add_payload'); self.upload(expect=4)
        self.assertFalse(any(x['mode']=='POST' for x in self.events()))

    def test_consistent_subset_during_get_still_blocks_post(self):
        self.config.update(mutate_at='get',mutation='subset'); self.upload(expect=4)
        self.assertFalse(any(x['mode']=='POST' for x in self.events()))

    def test_changed_manifest_after_post_cannot_emit_success_receipt(self):
        self.config.update(mutate_at='post',mutation='source'); self.upload(expect=4)
        self.assertEqual(len(self.state()['assets']),1, 'do not pretend a late failure rolls back remote writes')

    def test_changed_context_during_existing_asset_lookup_cannot_emit_success_receipt(self):
        self.upload(); self.config.update(mutate_at='get',mutation='source'); self.upload(expect=4)
        self.assertEqual(self.state()['posts'],1)

    def test_ambiguous_post_reconciles_only_with_unchanged_manifest(self):
        self.config.update(post_statuses=[503],store_on_error=True); self.upload()
        self.assertEqual(self.state()['posts'],1)

    def test_ambiguous_post_with_context_mutation_refuses_receipt(self):
        self.config.update(post_statuses=[503],store_on_error=True,mutate_at='post',mutation='source')
        self.upload(expect=4); self.assertEqual(self.state()['posts'],1)

    def test_retry_revalidates_before_second_post(self):
        self.config.update(post_statuses=[503,201],mutate_at='post',mutation='source')
        self.upload(expect=4); self.assertEqual(self.state()['posts'],1)

    def test_transient_post_failure_can_retry_without_mutation(self):
        self.config.update(post_statuses=[503,201]); self.upload(); self.assertEqual(self.state()['posts'],2)

    def test_bad_remote_digest_never_downgrades_to_name_only(self):
        self.config.update(receipt_override={'digest':'sha256:'+'0'*64}); self.upload(expect=7)

    def test_incomplete_remote_asset_is_not_a_success(self):
        self.config.update(receipt_override={'state':'starter'}); self.upload(expect=7)

    def test_get_failure_is_not_permission_to_post(self):
        self.config['get_error']=True; self.upload(expect=8)
        self.assertFalse(any(x['mode']=='POST' for x in self.events()))

    def test_glob_settings_cannot_hide_a_manifest(self):
        self.env['DSR_TEST_BAD_GLOBS']='1'
        self.body['artifacts']=self.rows[:-1]; self.save(); self.sums.unlink(); self.refusal()

    def test_generic_no_manifest_upload_remains_supported(self):
        path=self.root/'generic'; path.mkdir(); self.out=path
        (self.out/'standalone').write_bytes(b'standalone arbitrary asset')
        self.upload('standalone')

    def test_existing_checksum_bytes_are_not_modified_by_upload(self):
        self.sums.write_text('\n'.join(reversed(self.sums.read_text().replace('  ',' *').splitlines())))
        before=self.sums.read_bytes(); self.upload('SHA256SUMS'); self.assertEqual(self.sums.read_bytes(),before)


if __name__=='__main__': unittest.main(verbosity=2)
