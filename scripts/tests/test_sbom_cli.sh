#!/usr/bin/env bash
# bd-1tv.17: Exercise the actual dsr CLI and production GitHub adapters with
# real files/hashes. Only outbound gh/curl and the scanner are executable
# protocol fixtures; these tests do not qualify Syft package detection or a
# live GitHub publication. Every existing library custody gate remains active.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
for dependency in python3 jq; do
    command -v "$dependency" >/dev/null || { printf 'SKIP SBOM CLI: missing %s\n' "$dependency"; exit 0; }
done
python3 -I -S - "$ROOT" "${DSR_TEST_COMMAND_FILE:-$ROOT/dsr}" "$@" <<'PY'
import hashlib, json, os, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(sys.argv.pop(1))
CLI = str(Path(sys.argv.pop(1)).resolve())
MODULE = str(ROOT / 'src/sbom.sh')
SCANNER = r'''#!/bin/sh
exec python3 -I -S - "$@" <<'SCAN_PY'
import hashlib, json, os, sys
from pathlib import Path
source = Path(next(a[5:] for a in sys.argv[1:] if a.startswith('file:')))
assert '/.dsr-sbom.' in str(source) and '/input/' in str(source)
data = source.read_bytes()
with open(os.environ['SCAN_LOG'], 'a') as out:
    out.write(json.dumps({'name':source.name,'sha256':hashlib.sha256(data).hexdigest()})+'\n')
if source.name == os.environ.get('SCAN_FAIL'): sys.exit(19)
fmt = sys.argv[sys.argv.index('-o')+1]
if fmt == 'spdx-json':
    doc = {'spdxVersion':'SPDX-2.3','SPDXID':'SPDXRef-DOCUMENT','dataLicense':'CC0-1.0',
           'name':source.name,'documentNamespace':'urn:fixture:'+hashlib.sha256(data).hexdigest(),
           'creationInfo':{'creators':['Tool: explicit-boundary-fixture'],'created':'2026-10-14T00:00:00Z'},
           'packages':[]}
else: doc = {'bomFormat':'CycloneDX','specVersion':'1.6','version':1,'components':[]}
print(json.dumps(doc, sort_keys=True))
SCAN_PY
'''

HTTP_BOUNDARY = r'''#!/usr/bin/env python3
import hashlib, json, os, sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

root = Path(os.environ['SBOM_HTTP_ROOT'])
args = sys.argv[1:]
tool = Path(sys.argv[0]).name

def load(name): return json.loads((root / name).read_text())
def emit(value): print(json.dumps(value, separators=(',', ':')))
def record(method, target):
    with (root / 'requests.jsonl').open('a') as output:
        output.write(json.dumps({'method':method,'target':target})+'\n')

if tool == 'gh':
    if args[:2] == ['auth','status']: sys.exit(0)
    if args[:2] == ['auth','token']:
        print('dsr-sbom-http-fixture'); sys.exit(0)
    assert args[0] == 'api', args
    endpoint = args[1]
    assert '--hostname' in args and args[args.index('--hostname')+1] == 'github.com'
    assert os.environ.get('GH_TOKEN') == 'dsr-sbom-http-fixture'
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
        sys.stdout.buffer.write((root / 'bytes' / str(ident)).read_bytes())
    else: raise AssertionError('Unexpected fixture request: '+endpoint)
elif tool == 'curl':
    assert args[args.index('-X')+1] == 'POST', args
    url = urlsplit(args[-1])
    assert url.scheme == 'https' and url.netloc == 'uploads.github.com'
    assert url.path == '/repos/acme/tool/releases/42/assets'
    assert 'Authorization: Bearer dsr-sbom-http-fixture' in args
    name = parse_qs(url.query)['name'][0]
    rows = load('inventory.json'); assert not any(r['name']==name for r in rows)
    source = args[args.index('--data-binary')+1]; assert source.startswith('@')
    body = Path(source[1:]).read_bytes()
    ident = max((r['id'] for r in rows), default=100)+1
    row = {'id':ident,'name':name,'state':'uploaded','size':len(body),
           'digest':'sha256:'+hashlib.sha256(body).hexdigest()}
    (root / 'bytes' / str(ident)).write_bytes(body)
    (root / 'inventory.json').write_text(json.dumps(rows+[row]))
    Path(args[args.index('-o')+1]).write_text(json.dumps(row))
    Path(args[args.index('-D')+1]).write_text('HTTP/2 201 Created\r\n\r\n')
    record('POST',name)
    print('201',end='')
else: raise AssertionError(tool)
'''


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


class PublicSbomCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace=Path(tempfile.mkdtemp(prefix='dsr-sbom-cli-')).resolve()
        print('Retained fixtures: '+str(cls.workspace),file=sys.stderr)
        print('Scanner and HTTP: explicit executable fixtures, no live network',file=sys.stderr)

    def setUp(self):
        self.work=self.workspace/self._testMethodName; self.work.mkdir()
        self.root=self.work/'artifacts'; self.root.mkdir()
        self.output=self.work/'sboms'
        self.bin=self.work/'bin'; self.bin.mkdir()
        self.log=self.work/'scans.jsonl'
        for name,program in [('syft',SCANNER),('gh',HTTP_BOUNDARY),('curl',HTTP_BOUNDARY)]:
            path=self.bin/name; path.write_text(program); path.chmod(0o700)
        for name,data in [('tool-linux',b'owned non-executed binary'),('LICENSE',b'full license and rider'),
                          ('runtime.json',b'{"release_data":true}\n'),('NOTICE',b'owned release notice\n')]:
            (self.root/name).write_bytes(data)
        self.rows=[{'name':path.name,'sha256':digest(path)} for path in sorted(self.root.iterdir())]
        self.selection=self.work/'selection.json'
        self.selection.write_text(json.dumps({'schema_version':1,'artifacts':self.rows}))
        self.remote=self.work/'remote'; self.remote.mkdir()
        self.bodies=self.remote/'bytes'; self.bodies.mkdir()
        self.inventory=self.remote/'inventory.json'
        assets=[]
        for ident,row in enumerate(self.rows,101):
            body=(self.root/row['name']).read_bytes()
            (self.bodies/str(ident)).write_bytes(body)
            assets.append(dict(id=ident,name=row['name'],state='uploaded',size=len(body),digest='sha256:'+row['sha256']))
        self.inventory.write_text(json.dumps(assets))
        (self.remote/'repository.json').write_text(json.dumps(dict(id=17,node_id='REPO17',full_name='acme/tool')))
        (self.remote/'releases.json').write_text('[{"id":42,"tag_name":"v1.2.3"}]')
        (self.remote/'release.json').write_text(json.dumps(dict(id=42,node_id='REL42',tag_name='v1.2.3',
            draft=True,prerelease=False,target_commitish='main',url='https://api.github.com/repos/acme/tool/releases/42',
            upload_url='https://uploads.github.com/repos/acme/tool/releases/42/assets{?name,label}')))
        (self.remote/'tag.sha').write_text('1'*40+'\n')

    def environment(self):
        env={key:value for key,value in os.environ.items()
             if not key.startswith(('DSR_','BASH_FUNC_','SBOM_','GH_','GITHUB_')) and
             key not in ('BASH_ENV','ENV','SCAN_FAIL','SCAN_DRIFT')}
        env.update(PATH=str(self.bin)+os.pathsep+os.environ['PATH'],SCAN_LOG=str(self.log),NO_COLOR='1',
                   DSR_CONFIG_DIR=str(self.work/'config'),DSR_STATE_DIR=str(self.work/'state'),
                   DSR_CACHE_DIR=str(self.work/'cache'),DSR_GH_TOKEN='dsr-sbom-http-fixture',
                   SBOM_HTTP_ROOT=str(self.remote),GH_MAX_RETRIES='1',GH_RETRY_DELAY='0',
                   GH_API_TIMEOUT='10',GH_DOWNLOAD_TIMEOUT='10',GH_UPLOAD_TIMEOUT='10',
                   SBOM_REMOTE_TIMEOUT='30')
        return env

    def invoke(self, operation, *arguments, json_mode=True, dry=False, fault=None):
        env=self.environment(); env.update(fault or {})
        command=['bash',CLI]
        if json_mode: command.append('--json')
        if dry: command.append('--dry-run')
        command += ['sbom',operation,*map(str,arguments)]
        return subprocess.run(command,env=env,capture_output=True,text=True,timeout=45)

    def result(self, code, operation, *arguments, **options):
        result=self.invoke(operation,*arguments,**options)
        self.assertEqual(result.returncode,code,result.stderr+'\n'+result.stdout)
        value=json.loads(result.stdout)
        self.assertEqual(value['command'],'sbom-'+operation)
        self.assertEqual(value['exit_code'],code)
        self.assertEqual(value['status'],'error' if code else ('ok' if operation.startswith('verify') else 'success'))
        details=value['details']; self.assertIs(details['authenticated'],False)
        if code: self.assertTrue(details['error'])
        return details

    def local_args(self):
        return [self.root,'--selection',self.selection,'--output-dir',self.output]

    def remote_args(self):
        return ['--repo','acme/tool','--tag','v1.2.3']

    def scan(self, *options):
        result=subprocess.run(['bash',MODULE,'artifacts',*map(str,self.local_args()),*options],
                              env=self.environment(),capture_output=True,text=True,timeout=40)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(Path(result.stdout.strip()).is_file(),result.stdout)

    def scans(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def requests(self, method=None):
        path=self.remote/'requests.jsonl'
        rows=[json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [row for row in rows if method is None or row['method']==method]

    def document(self):
        document=self.work/'valid.cdx.json'
        document.write_text(json.dumps({'bomFormat':'CycloneDX','specVersion':'1.6','version':1,'components':[]}))
        return document

    def test_document_verification_enforces_format_and_reports_scope(self):
        document=self.document()
        details=self.result(0,'verify',document,'-f','cdx')
        self.assertTrue(details['valid']); self.assertEqual(details['format'],'cyclonedx')
        self.assertEqual(details['verification_scope'],'document')
        self.assertFalse(self.result(1,'verify',document,'--format','spdx')['valid'])
        self.assertTrue(self.result(0,'verify',document)['valid'])

    def test_verification_rejects_unsupported_or_conflicting_policy(self):
        document=self.document()
        cases=[['--public-key',self.work/'not-a-trusted-key'],['--unknown'],['--format'],
               ['--format','spdx','-f','cyclonedx'],[document],['--format','unsupported']]
        for options in cases:
            with self.subTest(options=options):
                self.assertFalse(self.result(4,'verify',document,*options)['valid'])
        self.assertEqual(self.requests(),[])

    def test_generation_rejects_missing_values_duplicates_and_extra_targets_before_scanning(self):
        target=self.root/'tool-linux'
        cases=[['--output'],['--format'],['--scan-timeout'],[self.root/'LICENSE'],
               ['--format','spdx','-f','cdx'],['--output',self.work/'first','-o',self.work/'second']]
        for options in cases:
            with self.subTest(options=options):
                self.result(4,'generate',target,*options)
                self.assertEqual(self.scans(),[])
        self.assertFalse(self.output.exists())

    def test_generation_dry_run_refuses_before_document_or_directory_writes(self):
        target=self.root/'tool-linux'
        self.result(4,'generate',target,'--output',self.output/'single.json',dry=True)
        self.result(4,'generate-artifacts',*self.local_args(),'--dry-run')
        self.assertFalse(self.output.exists()); self.assertEqual(self.scans(),[])

    def test_single_generation_preserves_plain_output_and_format_aliases(self):
        target=self.root/'tool-linux'
        details=self.result(0,'generate',target,'-f','cdx','--output',self.work/'single.cdx.json','--scan-timeout','3')
        self.assertEqual(details['format'],'cyclonedx')
        self.assertEqual(details['evidence_kind'],'scanner-observation')
        document=Path(details['output']); self.assertEqual(json.loads(document.read_bytes())['bomFormat'],'CycloneDX')
        plain=self.invoke('verify',document,'--format','cyclonedx',json_mode=False)
        self.assertEqual(plain.returncode,0,plain.stderr); self.assertEqual(plain.stdout,'')
        plain=self.invoke('generate',target,'--output',self.work/'plain.spdx.json',json_mode=False)
        self.assertEqual(plain.returncode,0,plain.stderr)
        self.assertEqual(plain.stdout,str(self.work/'plain.spdx.json')+'\n')

    def test_complete_local_artifact_lifecycle_both_formats_and_no_rescan(self):
        for fmt,extension in (('spdx','spdx.json'),('cyclonedx','cdx.json')):
            with self.subTest(format=fmt):
                details=self.result(0,'generate-artifacts',*self.local_args(),'--format',fmt)
                manifest=self.output/('sbom-manifest.'+extension)
                self.assertEqual(details['manifest'],str(manifest))
                self.assertEqual(details['selection'],str(self.selection))
                self.assertEqual([row['artifact'] for row in json.loads(manifest.read_bytes())['artifacts']],self.rows)
                for row in json.loads(manifest.read_bytes())['artifacts']:
                    self.assertEqual(digest(self.output/row['sbom']['name']),row['sbom']['sha256'])
                scans=self.scans(); before=manifest.read_bytes()
                verified=self.result(0,'verify-artifacts',*self.local_args(),'--format',fmt)
                self.assertTrue(verified['valid']); self.assertEqual(verified['verification_scope'],'local-artifacts')
                self.result(0,'generate-artifacts',*self.local_args(),'--format',fmt,fault={'SCAN_FAIL':'LICENSE'})
                self.assertEqual(self.scans(),scans); self.assertEqual(manifest.read_bytes(),before)
                plain=self.invoke('verify-artifacts',*self.local_args(),'--format',fmt,json_mode=False)
                self.assertEqual(plain.returncode,0,plain.stderr); self.assertEqual(plain.stdout,str(manifest)+'\n')

    def test_local_verification_detects_selected_payload_drift(self):
        self.scan()
        before=self.scans(); manifest=self.output/'sbom-manifest.spdx.json'; original=manifest.read_bytes()
        (self.root/'runtime.json').write_bytes(b'changed selected release data')
        result=self.invoke('verify-artifacts',*self.local_args())
        self.assertNotEqual(result.returncode,0,result.stdout)
        details=json.loads(result.stdout)['details']; self.assertFalse(details['valid'])
        self.assertIsNone(details['manifest']); self.assertEqual(self.scans(),before)
        self.assertEqual(manifest.read_bytes(),original)

    def test_local_verification_rejects_changed_documents_and_incomplete_inventory(self):
        self.scan(); scans=self.scans()
        document=self.output/'runtime.json.sbom.spdx.json'; original=document.read_bytes()
        changed=json.loads(original); changed['name']='different-observation'
        document.write_text(json.dumps(changed))
        self.assertFalse(self.result(2,'verify-artifacts',*self.local_args())['valid'])
        self.assertEqual(self.scans(),scans)
        document.write_bytes(original)
        manifest=self.output/'sbom-manifest.spdx.json'; value=json.loads(manifest.read_bytes())
        value['artifacts']=value['artifacts'][:-1]; manifest.write_text(json.dumps(value))
        self.assertFalse(self.result(2,'verify-artifacts',*self.local_args())['valid'])
        self.assertEqual(self.scans(),scans)

    def test_remote_publication_preview_commit_verification_and_retry(self):
        self.scan()
        before=self.scans(); inventory=self.inventory.read_bytes()
        planned=self.result(0,'publish-artifacts',*self.local_args(),*self.remote_args(),dry=True)
        self.assertTrue(planned['dry_run']); self.assertFalse(planned['publication_verified'])
        self.assertEqual(planned['receipt']['status'],'planned'); self.assertEqual(len(planned['receipt']['actions']),5)
        self.assertEqual(self.requests('POST'),[]); self.assertEqual(self.inventory.read_bytes(),inventory)
        published=self.result(0,'publish-artifacts',*self.local_args(),*self.remote_args())
        self.assertTrue(published['publication_verified']); self.assertFalse(published['dry_run'])
        self.assertEqual(published['receipt']['verification']['artifact_count'],4)
        expected=[row['name']+'.sbom.spdx.json' for row in self.rows]+['sbom-manifest.spdx.json']
        self.assertEqual([row['target'] for row in self.requests('POST')],expected)
        for name in expected:
            asset=next(row for row in json.loads(self.inventory.read_bytes()) if row['name']==name)
            self.assertEqual(digest(self.bodies/str(asset['id'])),digest(self.output/name))
        pin=digest(self.output/'sbom-manifest.spdx.json')
        verified=self.result(0,'verify-release',*self.remote_args(),'--manifest-sha256',pin)
        self.assertTrue(verified['valid']); self.assertEqual(verified['verification_scope'],'remote-release')
        self.assertEqual(verified['receipt']['verification_policy'],'expected-manifest-sha256')
        self.assertEqual(verified['receipt']['manifest']['sha256'],pin)
        frozen=self.inventory.read_bytes()
        reused=self.result(0,'publish-artifacts',*self.local_args(),*self.remote_args())
        self.assertEqual(reused['receipt']['sbom_upload_attempts'],0)
        self.assertFalse(reused['receipt']['manifest_upload_attempted'])
        self.assertEqual(self.inventory.read_bytes(),frozen); self.assertEqual(self.scans(),before)
        self.assertEqual([row['target'] for row in self.requests('POST')],expected)
        plain=self.invoke('verify-release',*self.remote_args(),'--manifest-sha256',pin,json_mode=False)
        self.assertEqual(plain.returncode,0,plain.stderr)
        self.assertEqual(json.loads(plain.stdout)['kind'],'dsr-sbom-remote-verification')

    def test_remote_policy_is_required_before_any_network_operation(self):
        cases=[('verify-release',self.remote_args()),
               ('verify-release',[*self.remote_args(),'--manifest-sha256','0'*64,'--manifest-sha256','1'*64]),
               ('verify-release',[*self.remote_args(),'--manifest-sha256','0'*64,'--format','spdx','-f','cdx']),
               ('publish-artifacts',self.local_args()),
               ('publish-artifacts',[*self.local_args(),*self.remote_args(),'--allow-published','--allow-published']),
               ('publish-artifacts',[*self.local_args(),*self.remote_args(),'--selection',self.selection])]
        for operation,arguments in cases:
            with self.subTest(operation=operation,arguments=arguments): self.result(4,operation,*arguments)
        self.assertEqual(self.requests(),[]); self.assertEqual(self.scans(),[])

    def test_remote_digest_and_document_tampering_cannot_verify(self):
        self.scan(); self.result(0,'publish-artifacts',*self.local_args(),*self.remote_args())
        self.assertFalse(self.result(7,'verify-release',*self.remote_args(),'--manifest-sha256','0'*64)['valid'])
        pin=digest(self.output/'sbom-manifest.spdx.json')
        row=next(row for row in json.loads(self.inventory.read_bytes()) if row['name']=='runtime.json.sbom.spdx.json')
        body=self.bodies/str(row['id']); body.write_bytes(b'x'*body.stat().st_size)
        details=self.result(7,'verify-release',*self.remote_args(),'--manifest-sha256',pin)
        self.assertFalse(details['valid']); self.assertIsNone(details['receipt'])

    def test_published_release_requires_explicit_addition_consent(self):
        self.scan('--format','cyclonedx')
        path=self.remote/'release.json'; value=json.loads(path.read_bytes()); value['draft']=False
        path.write_text(json.dumps(value))
        args=[*self.local_args(),*self.remote_args(),'--format','cdx']
        details=self.result(4,'publish-artifacts',*args)
        self.assertFalse(details['publication_verified']); self.assertEqual(self.requests('POST'),[])
        planned=self.result(0,'publish-artifacts',*args,'--allow-published',dry=True)
        self.assertEqual(planned['receipt']['status'],'planned'); self.assertEqual(self.requests('POST'),[])
        published=self.result(0,'publish-artifacts',*args,'--allow-published')
        self.assertTrue(published['publication_verified'])
        self.assertEqual(published['receipt']['verification']['format'],'cyclonedx')
        self.assertEqual(self.requests('POST')[-1]['target'],'sbom-manifest.cdx.json')


if __name__ == '__main__': unittest.main(verbosity=2)
PY
