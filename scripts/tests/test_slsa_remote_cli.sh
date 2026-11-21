#!/usr/bin/env bash
# bd-1tv.18: Public generation/signing, remote provenance and offline consumers
# with genuine Git/Minisign and exact payload bytes. Only outbound gh/curl are
# executable protocol fixtures; no compiler or live GitHub acceptance is claimed.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
for dependency in python3 jq git minisign; do
    command -v "$dependency" >/dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; exit 3; }
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

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(sys.argv.pop(1))
CLI = str(Path(sys.argv.pop(1)).resolve())
REPOSITORY = 'acme/tool'
TAG = 'v1.2.3'
BUILDER = 'dsr/test-remote-cli'
TARGETS = 'linux/amd64,windows/arm64'
INVOCATION = 'remote-cli-build'

HTTP_BOUNDARY = r'''#!/usr/bin/env python3
import hashlib, json, os, sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
root = Path(os.environ['SLSA_HTTP_ROOT'])
args = sys.argv[1:]
tool = Path(sys.argv[0]).name
def load(name): return json.loads((root / name).read_text())
def emit(value): print(json.dumps(value, separators=(',', ':')))
def record(method, target):
    with (root / 'requests.jsonl').open('a') as output:
        output.write(json.dumps({'method':method,'target':target})+'\n')
if os.environ.get('SLSA_HTTP_DENY') == '1':
    record('DENIED', tool+' '+repr(args)); sys.exit(97)
if tool == 'gh':
    if args[:2] == ['auth','status']:
        record('AUTH','status'); sys.exit(0)
    if args[:2] == ['auth','token']:
        record('AUTH','token'); print('dsr-slsa-http-fixture'); sys.exit(0)
    assert args[0] == 'api', args
    endpoint = args[1]
    assert '--hostname' in args and args[args.index('--hostname')+1] == 'github.com'
    assert os.environ.get('GH_TOKEN') == 'dsr-slsa-http-fixture'
    assert '-X' not in args or args[args.index('-X')+1] == 'GET'
    record('GET', endpoint)
    path, _, query = endpoint.partition('?')
    if path == 'repos/acme/tool': emit(load('repository.json'))
    elif path == 'repos/acme/tool/git/ref/tags/v1.2.3':
        emit({'ref':'refs/tags/v1.2.3','object':{'type':'commit','sha':(root/'tag.sha').read_text().strip()}})
    elif path == 'repos/acme/tool/releases':
        page = int(parse_qs(query).get('page',['1'])[0]); rows = load('releases.json')
        emit(rows[(page-1)*100:page*100])
    elif path == 'repos/acme/tool/releases/42': emit(load('release.json'))
    elif path == 'repos/acme/tool/releases/42/assets':
        page = int(parse_qs(query).get('page',['1'])[0]); rows = load('inventory.json')
        emit(rows[(page-1)*100:page*100])
    elif path.startswith('repos/acme/tool/releases/assets/'):
        ident = int(path.rsplit('/',1)[1])
        assert 'Accept: application/octet-stream' in args, args
        if (root/'fail-id').is_file() and int((root/'fail-id').read_text()) == ident:
            print('explicit fixture transport failure',file=sys.stderr); sys.exit(1)
        sys.stdout.buffer.write((root / 'bytes' / str(ident)).read_bytes())
    else: raise AssertionError('Unexpected fixture request: '+endpoint)
elif tool == 'curl':
    assert args[args.index('-X')+1] == 'POST', args
    url = urlsplit(args[-1])
    assert url.scheme == 'https' and url.netloc == 'uploads.github.com'
    assert url.path == '/repos/acme/tool/releases/42/assets'
    assert 'Authorization: Bearer dsr-slsa-http-fixture' in args
    name = parse_qs(url.query)['name'][0]
    rows = load('inventory.json'); assert not any(row['name']==name for row in rows)
    source = args[args.index('--data-binary')+1]; assert source.startswith('@')
    body = Path(source[1:]).read_bytes()
    ident = max((row['id'] for row in rows), default=100)+1
    row = dict(id=ident,name=name,state='uploaded',size=len(body),digest='sha256:'+hashlib.sha256(body).hexdigest())
    (root / 'bytes' / str(ident)).write_bytes(body)
    (root / 'inventory.json').write_text(json.dumps(rows+[row]))
    Path(args[args.index('-o')+1]).write_text(json.dumps(row))
    Path(args[args.index('-D')+1]).write_text('HTTP/2 201 Created\r\n\r\n')
    record('POST',name)
    print('201',end='')
else: raise AssertionError(tool)
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PublicSlsaRemoteCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = Path(tempfile.mkdtemp(prefix='dsr-slsa-remote-cli-')).resolve()
        print('Retained fixtures: '+str(cls.workspace),file=sys.stderr)
        cls.base_env = {key:value for key,value in os.environ.items()
                        if not key.startswith(('DSR_','GIT_','GH_','GITHUB_','BASH_FUNC_','SLSA_','SBOM_'))
                        and key not in ('BASH_ENV','ENV')}
        config = cls.workspace/'producer-config'; config.mkdir()
        cls.key = config/'minisign.pub'; cls.secret = cls.workspace/'producer.key'
        cls.wrong_key = cls.workspace/'other.pub'
        cls.base_env.update(NO_COLOR='1',DSR_CONFIG_DIR=str(config),
                            DSR_MINISIGN_KEY=str(cls.secret),DSR_STATE_DIR=str(cls.workspace/'state'),
                            DSR_CACHE_DIR=str(cls.workspace/'cache'),GIT_CONFIG_NOSYSTEM='1',
                            GIT_CONFIG_GLOBAL=str(cls.workspace/'gitconfig'))
        cls.setup_run('minisign','-G','-W','-p',cls.key,'-s',cls.secret)
        cls.setup_run('minisign','-G','-W','-p',cls.wrong_key,'-s',cls.workspace/'other.key')
        source = cls.workspace/'source'; source.mkdir()
        cls.setup_run('git','init','-q','-b','main',source)
        cls.setup_run('git','-C',source,'config','user.name','DSR test')
        cls.setup_run('git','-C',source,'config','user.email','test@example.invalid')
        (source/'source.txt').write_text('source fixture\n')
        cls.setup_run('git','-C',source,'add','source.txt')
        cls.setup_run('git','-C',source,'commit','-qm','source fixture')
        cls.pin = cls.setup_run('git','-C',source,'rev-parse','HEAD').stdout.strip()
        cls.payloads = {'demo-linux':b'linux primary bytes\n','demo-v1-linux':b'linux primary bytes\n',
                        'demo-windows.exe':b'windows release bytes\n','runtime.json':b'{"runtime":"release"}\n'}
        artifacts = cls.workspace/'producer-assets'; artifacts.mkdir()
        for name,data in cls.payloads.items(): (artifacts/name).write_bytes(data)
        cls.rows = []
        for name in sorted(cls.payloads):
            target,triple = ('additional',None) if name=='runtime.json' else (
                ('windows/arm64','aarch64-pc-windows-msvc') if name.endswith('.exe') else
                ('linux/amd64','x86_64-unknown-linux-gnu'))
            row = dict(name=name,target=target,archive_format='none' if triple is None else 'binary',
                       size_bytes=len(cls.payloads[name]),sha256=digest(artifacts/name))
            if triple: row['target_triple'] = triple
            cls.rows.append(row)
        cls.manifest = cls.workspace/'manifest.json'
        cls.manifest.write_text(json.dumps(dict(schema_version='1.0.0',tool='tool',version=TAG,
            run_id=INVOCATION,source=dict(git_sha=cls.pin,git_ref='refs/tags/'+TAG,dependencies=[]),
            built_at='2026-11-21T00:00:00Z',status='success',summary=dict(total=2,success=2,failed=0),
            artifacts=cls.rows)))
        cls.producer_proof = cls.workspace/'release.intoto.jsonl'
        cls.setup_run('bash',CLI,'slsa','generate-manifest',cls.manifest,artifacts,
                      '--repository',REPOSITORY,'--builder',BUILDER,'--output',cls.producer_proof)
        cls.setup_run('bash',CLI,'signing','sign',cls.producer_proof)
        cls.contract_data = dict(schema_version=1,required_assets=[
            {key:value for key,value in row.items() if key in ('name','target','archive_format','target_triple')}
            for row in cls.rows],required_variants=[
                dict(target='linux/amd64',target_triple='x86_64-unknown-linux-gnu'),
                dict(target='windows/arm64',target_triple='aarch64-pc-windows-msvc')])
        cls.validator = Draft202012Validator(json.loads((ROOT/'schemas/envelope.json').read_text()),
                                             format_checker=FormatChecker())

    @classmethod
    def setup_run(cls,*args):
        result = subprocess.run(list(map(str,args)),env=cls.base_env,capture_output=True,text=True,timeout=30)
        if result.returncode: raise RuntimeError(result.stderr+'\n'+result.stdout)
        return result

    def setUp(self):
        self.work = self.workspace/self._testMethodName; self.work.mkdir()
        self.assets = self.work/'artifacts'; self.assets.mkdir()
        for name,data in self.payloads.items(): (self.assets/name).write_bytes(data)
        self.proof = self.work/'release.intoto.jsonl'
        self.proof.write_bytes(self.producer_proof.read_bytes())
        self.signature = Path(str(self.proof)+'.minisig')
        self.signature.write_bytes(Path(str(self.producer_proof)+'.minisig').read_bytes())
        self.contract = self.work/'contract.json'; self.contract.write_text(json.dumps(self.contract_data))
        self.bin = self.work/'bin'; self.bin.mkdir()
        for name in ('gh','curl'):
            path=self.bin/name; path.write_text(HTTP_BOUNDARY); path.chmod(0o700)
        self.remote = self.work/'remote'; self.remote.mkdir()
        self.bodies = self.remote/'bytes'; self.bodies.mkdir()
        self.inventory = self.remote/'inventory.json'
        self.inventory.write_text('[]')
        for row in self.rows: self.add_remote(row['name'],self.payloads[row['name']])
        (self.remote/'repository.json').write_text(json.dumps(dict(id=17,node_id='REPO17',full_name=REPOSITORY)))
        (self.remote/'releases.json').write_text('[{"id":42,"tag_name":"v1.2.3"}]')
        (self.remote/'release.json').write_text(json.dumps(dict(id=42,node_id='REL42',tag_name=TAG,
            draft=True,prerelease=False,target_commitish='main',url='https://api.github.com/repos/acme/tool/releases/42',
            upload_url='https://uploads.github.com/repos/acme/tool/releases/42/assets{?name,label}')))
        (self.remote/'tag.sha').write_text(self.pin+'\n')

    def add_remote(self,name,body):
        rows=json.loads(self.inventory.read_bytes()); ident=max((row['id'] for row in rows),default=100)+1
        (self.bodies/str(ident)).write_bytes(body)
        rows.append(dict(id=ident,name=name,state='uploaded',size=len(body),digest='sha256:'+hashlib.sha256(body).hexdigest()))
        self.inventory.write_text(json.dumps(rows))

    def seed_proofs(self):
        self.add_remote(self.proof.name,self.proof.read_bytes())
        self.add_remote(self.signature.name,self.signature.read_bytes())

    def policy(self,**changes):
        values=dict(repo=REPOSITORY,tag=TAG,sha=self.pin,builder=BUILDER,public_key=self.key,targets=TARGETS)
        values.update(changes)
        return [part for key,value in values.items() if value is not None for part in ('--'+key.replace('_','-'),str(value))]

    def invoke(self,operation,*args,json_mode=True,dry=False,offline=False):
        env=self.base_env.copy()
        env.update(PATH=str(self.bin)+os.pathsep+env['PATH'],DSR_CONFIG_DIR=str(self.work/'config'),
                   DSR_STATE_DIR=str(self.work/'state'),DSR_CACHE_DIR=str(self.work/'cache'),
                   DSR_GH_TOKEN='dsr-slsa-http-fixture',SLSA_HTTP_ROOT=str(self.remote),
                   GH_MAX_RETRIES='1',GH_RETRY_DELAY='0',GH_API_TIMEOUT='10',
                   GH_DOWNLOAD_TIMEOUT='10',GH_UPLOAD_TIMEOUT='10',SBOM_REMOTE_TIMEOUT='30')
        if offline: env.update(DSR_GH_TOKEN='',SLSA_HTTP_DENY='1')
        command=['bash',CLI]
        if json_mode: command.append('--json')
        if dry: command.append('--dry-run')
        command+=['slsa',operation,*map(str,args)]
        return subprocess.run(command,env=env,capture_output=True,text=True,timeout=45)

    def result(self,code,operation,*args,**options):
        result=self.invoke(operation,*args,**options)
        self.assertEqual(result.returncode,code,result.stderr+'\n'+result.stdout)
        value=json.loads(result.stdout); self.validator.validate(value)
        self.assertEqual(value['command'],'slsa-'+operation)
        self.assertEqual(value['exit_code'],code)
        self.assertEqual(value['status'],'error' if code else 'success')
        details=value['details']
        if code:
            self.assertFalse(details['authenticated']); self.assertIsNone(details['receipt'])
            self.assertTrue(details['error'])
        return details

    def requests(self):
        path=self.remote/'requests.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def posts(self):
        return [row['target'] for row in self.requests() if row['method']=='POST']

    def test_publication_preview_authenticates_every_pin_without_remote_calls(self):
        selected=self.work/'prepared.minisig'; self.signature.rename(selected)
        args=[self.proof,self.assets,*self.policy(), '--signature',selected,
              '--statement-name','custom.intoto.jsonl','--statement-sha256',digest(self.proof),
              '--manifest-sha256',digest(self.manifest),'--invocation-id',INVOCATION,
              '--release-contract',self.contract]
        details=self.result(0,'publish-release',*args,dry=True,offline=True)
        self.assertTrue(details['authenticated'] and details['local_statement_authenticated'])
        self.assertFalse(details['publication_verified']); self.assertEqual(details['verification_scope'],'local-release')
        receipt=details['receipt']; self.assertFalse(receipt['remote_verified'])
        self.assertEqual(receipt['plan']['statement_name'],'custom.intoto.jsonl')
        self.assertEqual(receipt['plan']['manifest_sha256'],digest(self.manifest))
        self.assertEqual(receipt['plan']['invocation_id'],INVOCATION)
        self.assertEqual(receipt['plan']['release_contract'],self.contract_data)
        plain=self.invoke('publish-release',*args,'-n',json_mode=False,offline=True)
        self.assertEqual(plain.returncode,0,plain.stderr)
        self.assertEqual(json.loads(plain.stdout)['status'],'planned'); self.assertEqual(self.requests(),[])

    def test_parser_rejects_missing_duplicate_and_unrelated_policy_before_remote_calls(self):
        for key in ('repo','tag','sha','builder','public_key','targets'):
            with self.subTest(missing=key): self.result(4,'verify-remote',*self.policy(**{key:None}))
        for options in (['--builder'],['-b',BUILDER],['--sha',self.pin],['--secret-key',self.secret],
                        ['--signature',self.signature],['unexpected'],['--jobs','0'],['--jobs','33']):
            with self.subTest(options=options): self.result(4,'verify-remote',*self.policy(),*options)
        self.result(4,'publish-release',self.proof,self.assets,*self.policy(),'--dry-run','-n')
        self.result(4,'verify-snapshot',self.work,*self.policy(),'--jobs','2')
        self.result(4,'describe-contract','--release-contract',self.contract,'--targets',TARGETS,'--public-key',self.key)
        self.assertEqual(self.requests(),[])

    def test_complete_publication_remote_verification_and_public_retry(self):
        details=self.result(0,'publish-release',self.proof,self.assets,*self.policy(),
                            '--release-contract',self.contract)
        self.assertTrue(details['authenticated'] and details['publication_verified'])
        self.assertEqual(details['receipt']['verification']['artifact_count'],4)
        self.assertEqual(self.posts(),['release.intoto.jsonl','release.intoto.jsonl.minisig'])
        rows=json.loads(self.inventory.read_bytes())
        for file in (self.proof,self.signature):
            row=next(row for row in rows if row['name']==file.name)
            self.assertEqual((self.bodies/str(row['id'])).read_bytes(),file.read_bytes())
        verified=self.result(0,'verify-remote',*self.policy(),'--jobs','2',
                             '--manifest-sha256',digest(self.manifest),'--release-contract',self.contract)
        self.assertTrue(verified['valid'] and verified['authenticated'])
        self.assertEqual(verified['receipt']['targets'],TARGETS.split(','))
        mode=self.remote/'release.json'; release=json.loads(mode.read_bytes()); release['draft']=False
        mode.write_text(json.dumps(release)); frozen=self.inventory.read_bytes()
        retry=self.result(0,'publish-release',self.proof,self.assets,*self.policy())
        self.assertEqual(retry['receipt']['upload_attempts'],0); self.assertEqual(self.inventory.read_bytes(),frozen)
        self.assertEqual(self.posts(),['release.intoto.jsonl','release.intoto.jsonl.minisig'])
        plain=self.invoke('verify-remote',*self.policy(),json_mode=False)
        self.assertEqual(plain.returncode,0,plain.stderr)
        self.assertEqual(json.loads(plain.stdout)['kind'],'dsr-slsa-remote-verification')

    def test_remote_verification_enforces_independently_selected_identity_and_build_pins(self):
        self.seed_proofs()
        for policy,options,code in (
            (self.policy(builder='wrong-builder'),[],7),
            (self.policy(sha='b'*40),[],7),
            (self.policy(targets='linux/amd64'),[],7),
            (self.policy(public_key=self.wrong_key),[],1),
            (self.policy(),['--statement-sha256','0'*64],7),
            (self.policy(),['--manifest-sha256','0'*64],7),
            (self.policy(),['--invocation-id','wrong-invocation'],7)):
            with self.subTest(policy=policy,options=options):
                self.assertFalse(self.result(code,'verify-remote',*policy,*options)['valid'])
        contract=copy.deepcopy(self.contract_data)
        contract['required_assets'][0]['archive_format']='zip'
        self.contract.write_text(json.dumps(contract))
        self.result(7,'verify-remote',*self.policy(),'--release-contract',self.contract)
        self.assertEqual(self.posts(),[])

    def test_remote_payload_and_signature_bytes_cannot_be_authenticated_from_api_metadata(self):
        self.seed_proofs(); rows=json.loads(self.inventory.read_bytes())
        payload=next(row for row in rows if row['name']=='runtime.json')
        (self.bodies/str(payload['id'])).write_bytes(b'x'*payload['size'])
        self.result(7,'verify-remote',*self.policy())
        (self.bodies/str(payload['id'])).write_bytes(self.payloads['runtime.json'])
        signature=next(row for row in rows if row['name']==self.signature.name)
        bad=b'x'*signature['size']; (self.bodies/str(signature['id'])).write_bytes(bad)
        signature['digest']='sha256:'+hashlib.sha256(bad).hexdigest()
        self.inventory.write_text(json.dumps(rows))
        self.result(1,'verify-remote',*self.policy()); self.assertEqual(self.posts(),[])

    def test_published_release_does_not_acquire_missing_provenance(self):
        path=self.remote/'release.json'; release=json.loads(path.read_bytes()); release['draft']=False
        path.write_text(json.dumps(release))
        self.result(4,'publish-release',self.proof,self.assets,*self.policy())
        self.assertEqual(self.posts(),[])

    def test_fetch_resumable_snapshot_offline_verification_and_completed_retry(self):
        self.seed_proofs(); destination=self.work/'snapshot'
        args=[*self.policy(),'--output-dir',destination,'--resume','--jobs','2','--release-contract',self.contract]
        fetched=self.result(0,'fetch-release',*args)
        self.assertTrue(fetched['authenticated'] and fetched['resumable'])
        self.assertEqual(fetched['receipt']['acquisition'],dict(reused_payloads=0,downloaded_payloads=4))
        for name,data in self.payloads.items(): self.assertEqual((destination/'artifacts'/name).read_bytes(),data)
        retained={str(path.relative_to(destination)):(path.read_bytes(),path.stat().st_ino,path.stat().st_mtime_ns)
                  for path in destination.rglob('*') if path.is_file()}
        before=len(self.requests())
        retry=self.result(0,'fetch-release',*self.policy(),'--output-dir',destination,'--resume',
                          '--jobs','1','--release-contract',self.contract)
        self.assertEqual(retry['receipt']['acquisition'],dict(reused_payloads=4,downloaded_payloads=0))
        self.assertEqual(retry['receipt']['snapshot_sha256'],fetched['receipt']['snapshot_sha256'])
        payload_paths={'repos/acme/tool/releases/assets/'+str(i) for i in range(101,105)}
        self.assertFalse(any(row['target'] in payload_paths for row in self.requests()[before:]))
        for relative,expected in retained.items():
            path=destination/relative
            self.assertEqual((path.read_bytes(),path.stat().st_ino,path.stat().st_mtime_ns),expected)
        (destination/'download.json').write_text('{"historical_receipt":"not a trust anchor"}')
        before=len(self.requests())
        offline=self.result(0,'verify-snapshot',destination,*self.policy(),
                            '--release-contract',self.contract,offline=True)
        self.assertTrue(offline['valid'] and offline['authenticated']); self.assertFalse(offline['remote_current'])
        self.assertEqual(offline['receipt']['snapshot_sha256'],fetched['receipt']['snapshot_sha256'])
        self.assertEqual(len(self.requests()),before)

    def test_failed_fetch_resumes_only_missing_authenticated_payload(self):
        self.seed_proofs(); destination=self.work/'snapshot'
        failure=self.remote/'fail-id'; failure.write_text('104')
        args=[*self.policy(),'--output-dir',destination,'--resume']
        self.result(8,'fetch-release',*args)
        self.assertFalse(destination.exists())
        retained=Path(str(destination)+'.partial')/'artifacts'
        original={path.name:(path.read_bytes(),path.stat().st_ino) for path in retained.iterdir()}
        self.assertEqual(set(original),set(self.payloads)-{'runtime.json'})
        failure.rename(self.remote/'fail-id.saved'); before=len(self.requests())
        complete=self.result(0,'fetch-release',*args,'--jobs','2')
        self.assertEqual(complete['receipt']['acquisition'],dict(reused_payloads=3,downloaded_payloads=1))
        for name,state in original.items():
            path=destination/'artifacts'/name; self.assertEqual((path.read_bytes(),path.stat().st_ino),state)
        bodies=[row['target'] for row in self.requests()[before:] if '/releases/assets/' in row['target']]
        self.assertEqual(bodies.count('repos/acme/tool/releases/assets/104'),1)
        self.assertFalse(any('repos/acme/tool/releases/assets/'+str(i) in bodies for i in (101,102,103)))

    def test_fetch_dry_run_and_invalid_selection_create_no_snapshot_or_checkpoint(self):
        destination=self.work/'snapshot'
        self.result(4,'fetch-release',*self.policy(),'--output-dir',destination,'--resume',dry=True)
        self.result(4,'fetch-release',*self.policy())
        self.result(4,'fetch-release',*self.policy(),'--output-dir',destination,'--jobs','2','--jobs','3')
        self.assertFalse(destination.exists()); self.assertFalse(Path(str(destination)+'.lock').exists())
        self.assertFalse(Path(str(destination)+'.partial').exists()); self.assertEqual(self.requests(),[])

    def test_offline_snapshot_rejects_wrong_signer_extra_and_changed_payloads(self):
        destination=self.work/'snapshot'; destination.mkdir()
        shutil.copytree(self.assets,destination/'artifacts')
        shutil.copyfile(self.proof,destination/'release.intoto.jsonl')
        shutil.copyfile(self.signature,destination/'release.intoto.jsonl.minisig')
        (destination/'download.json').write_text('{}')
        self.result(0,'verify-snapshot',destination,*self.policy(),offline=True)
        self.result(1,'verify-snapshot',destination,*self.policy(public_key=self.wrong_key),offline=True)
        self.result(7,'verify-snapshot',destination,*self.policy(),'--statement-sha256','0'*64,offline=True)
        payload=destination/'artifacts'/'demo-windows.exe'; payload.write_bytes(b'changed payload')
        self.result(1,'verify-snapshot',destination,*self.policy(),offline=True)
        payload.write_bytes(self.payloads[payload.name]); (destination/'artifacts'/'extra.bin').write_bytes(b'extra')
        self.result(7,'verify-snapshot',destination,*self.policy(),offline=True)
        self.assertEqual(self.requests(),[])

    def test_contract_description_preserves_exact_assets_without_authentication(self):
        args=['--release-contract',self.contract,'--targets',TARGETS]
        details=self.result(0,'describe-contract',*args,offline=True)
        self.assertFalse(details['authenticated'] or details['authentication_requested'])
        receipt=details['receipt']; self.assertEqual(receipt['contract'],self.contract_data)
        canonical=(json.dumps(self.contract_data,sort_keys=True,separators=(',',':'),ensure_ascii=True)+'\n').encode()
        self.assertEqual(receipt['contract_sha256'],hashlib.sha256(canonical).hexdigest())
        plain=self.invoke('describe-contract',*args,json_mode=False,offline=True)
        self.assertEqual(plain.returncode,0,plain.stderr)
        self.assertEqual(json.loads(plain.stdout),receipt); self.assertEqual(self.requests(),[])


if __name__ == '__main__': unittest.main(verbosity=2)
PY
