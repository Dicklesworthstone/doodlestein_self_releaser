#!/usr/bin/env bash
# Complete production SBOM CLI with real files. Syft is an explicit executable
# protocol fixture: these tests do not qualify scanner package detection.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
for tool in python3 jq; do
    command -v "$tool" >/dev/null || { printf 'SKIP explicit SBOM selection: missing %s\n' "$tool"; exit 0; }
done
python3 -I -S - "${DSR_TEST_SBOM_MODULE:-$ROOT/src/sbom.sh}" "$@" <<'PY'
import hashlib, json, os, subprocess, sys, tempfile, unittest
from pathlib import Path
MODULE = str(Path(sys.argv.pop(1)).resolve())
REMOTE = str(Path(os.environ.get('DSR_TEST_SBOM_RELEASE_MODULE',
                                str(Path(MODULE).with_name('sbom_release.sh')))).resolve())
TRANSPORT_FIXTURE = str(Path(MODULE).parent.parent / 'scripts/tests/test_sbom_remote.sh')
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
if os.environ.get('SCAN_DRIFT'):
    Path(os.environ['SCAN_DRIFT']).write_bytes(b'changed during scanner subprocess')
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

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

class SelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = Path(tempfile.mkdtemp(prefix='dsr-sbom-selection-')).resolve()
        print('Retained fixtures: '+str(cls.workspace), file=sys.stderr)
        print('Scanner: explicit executable fixture, not Syft', file=sys.stderr)

    def setUp(self):
        self.work = self.workspace / self._testMethodName; self.work.mkdir()
        self.root = self.work / 'artifacts'; self.root.mkdir()
        self.output = self.work / 'sboms'
        self.bin = self.work / 'bin'; self.bin.mkdir()
        scanner = self.bin / 'syft'; scanner.write_text(SCANNER); scanner.chmod(0o700)
        self.log = self.work / 'scans.jsonl'
        for name, data in [('tool-linux',b'owned non-executed binary'),('LICENSE',b'full license and rider'),
                           ('runtime.json',b'{"release_data":true}\n')]:
            (self.root / name).write_bytes(data)
        self.selection = self.work / 'selection.json'
        self.rows = [{'name':p.name,'sha256':digest(p)} for p in sorted(self.root.iterdir())]
        self.save_selection(self.rows)

    def save_selection(self, rows):
        self.selection.write_text(json.dumps({'schema_version':1,'artifacts':rows}))

    def call(self, command='artifacts', *options, explicit=True, output=None, fault=None):
        env = {k:v for k,v in os.environ.items() if not k.startswith('BASH_FUNC_') and
               k not in ('BASH_ENV','ENV','SBOM_OUTPUT_DIR','SBOM_DEFAULT_FORMAT','SCAN_FAIL','SCAN_DRIFT')}
        env.update(PATH=str(self.bin)+os.pathsep+os.environ['PATH'], SCAN_LOG=str(self.log))
        env.update(fault or {})
        args = [command,str(self.root),'--output-dir',str(output or self.output)]
        if explicit: args += ['--selection',str(self.selection)]
        return subprocess.run(['bash',MODULE,*args,*options],capture_output=True,text=True,env=env,timeout=40)

    def accepted(self, result):
        self.assertEqual(result.returncode,0,result.stderr)
        path = Path(result.stdout.strip()); self.assertTrue(path.is_file(),result.stdout)
        return path

    def refused(self, result):
        self.assertNotEqual(result.returncode,0,result.stderr); self.assertEqual(result.stdout,'')

    def scans(self):
        return [json.loads(s) for s in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_complete_explicit_scan_and_verify_both_formats(self):
        for fmt in ('spdx','cyclonedx'):
            with self.subTest(format=fmt):
                output = self.work / fmt
                proof = self.accepted(self.call('artifacts','--format',fmt,output=output))
                value = json.loads(proof.read_bytes())
                self.assertEqual(value['selection_policy'],'explicit-artifacts-v1')
                self.assertEqual([r['artifact'] for r in value['artifacts']],self.rows)
                for entry in value['artifacts']:
                    self.assertEqual(digest(output / entry['sbom']['name']),entry['sbom']['sha256'])
                    self.assertTrue((output / (entry['sbom']['name']+'.dsr.json')).is_file())
                before = proof.read_bytes(); calls = len(self.scans())
                self.accepted(self.call('verify-artifacts','--format',fmt,output=output))
                self.assertEqual(proof.read_bytes(),before); self.assertEqual(len(self.scans()),calls)
        self.assertEqual(self.scans(),self.rows*2)

    def test_default_discovery_and_unsigned_byte_claim_are_unchanged(self):
        proof = self.accepted(self.call(explicit=False)); value = json.loads(proof.read_bytes())
        self.assertEqual(value['selection_policy'],'top-level-artifacts-v1')
        self.assertEqual([r['artifact']['name'] for r in value['artifacts']],['tool-linux'])
        self.accepted(self.call('verify-artifacts',explicit=False)); self.assertNotIn('authenticated',value)

    def test_reordered_selection_reuses_exact_records_without_rescanning(self):
        proof = self.accepted(self.call()); before = proof.read_bytes()
        self.save_selection([{'sha256':r['sha256'],'name':r['name']} for r in reversed(self.rows)])
        self.accepted(self.call()); self.assertEqual(proof.read_bytes(),before); self.assertEqual(len(self.scans()),3)

    def test_unselected_binary_refused_but_unselected_metadata_not_scanned(self):
        (self.root / 'operator.json').write_bytes(b'private metadata'); self.accepted(self.call())
        self.assertNotIn('operator.json',[r['name'] for r in self.scans()])
        (self.root / 'unexpected-bin').write_bytes(b'unselected')
        self.refused(self.call('verify-artifacts')); self.assertEqual(len(self.scans()),3)

    def test_wrong_selected_digest_fails_before_any_scan(self):
        self.rows[-1]['sha256'] = '0'*64; self.save_selection(self.rows)
        self.refused(self.call()); self.assertEqual(self.scans(),[])
        self.assertFalse((self.output / 'sbom-manifest.spdx.json').exists())

    def test_selected_missing_link_directory_and_fifo_are_refused(self):
        path = self.root / 'LICENSE'; path.rename(self.work / 'retained-license')
        for kind in ('missing','link','directory','fifo'):
            with self.subTest(kind=kind):
                if kind == 'link': path.symlink_to(self.work / 'retained-license')
                elif kind == 'directory': path.mkdir()
                elif kind == 'fifo': os.mkfifo(path)
                self.refused(self.call())
                if path.exists() or path.is_symlink(): path.rename(self.work / ('retained-'+kind))
                self.assertEqual(self.scans(),[])

    def test_bad_selections_fail_before_output_creation(self):
        valid = {'schema_version':1,'artifacts':self.rows}
        cases = ['{}','[]',json.dumps(valid)+json.dumps(valid),
                 '{"schema_version":1,"schema_version":1,"artifacts":[]}',
                 json.dumps(dict(valid,schema_version=True)),json.dumps(dict(valid,extra=True)),
                 json.dumps(dict(valid,artifacts=[])),json.dumps(dict(valid,artifacts=self.rows*2)),
                 '{"schema_version":1,"artifacts":NaN}',' '*(1048576+1)]
        for name in ('../escape','a/b','a\\b','line\nbreak','tool;exit','..','-flag','x'*129):
            cases.append(json.dumps(dict(valid,artifacts=[{'name':name,'sha256':'1'*64}])))
        cases.append(json.dumps(dict(valid,artifacts=[self.rows[0],dict(self.rows[0],name='license')])))
        for raw in cases:
            with self.subTest(raw=raw[:100]):
                self.selection.write_text(raw); self.refused(self.call())
                self.assertFalse(self.output.exists()); self.assertEqual(self.scans(),[])

    def test_selection_file_link_and_duplicate_option_are_refused(self):
        self.selection.rename(self.work / 'original-selection')
        self.selection.symlink_to(self.work / 'original-selection'); self.refused(self.call())
        self.assertFalse(self.output.exists()); self.selection.rename(self.work / 'retained-link')
        self.save_selection(self.rows)
        self.refused(self.call('artifacts','--selection',str(self.selection))); self.assertFalse(self.output.exists())

    def test_output_name_collisions_fail_without_scanning(self):
        for name in ('tool-linux.sbom.spdx.json','LICENSE.sbom.spdx.json.dsr.json',
                     'SBOM-MANIFEST.spdx.json','sbom-plan.spdx.json'):
            with self.subTest(name=name):
                path = self.root / name; path.write_bytes(b'not scanner output')
                self.save_selection(self.rows+[{'name':name,'sha256':digest(path)}]); self.refused(self.call())
                self.assertEqual(path.read_bytes(),b'not scanner output')
                path.rename(self.work / ('retained-'+name)); self.assertEqual(self.scans(),[])

    def test_selection_drift_blocks_success_and_preserves_partial_records(self):
        self.refused(self.call(fault={'SCAN_DRIFT':str(self.selection)}))
        self.assertFalse((self.output / 'sbom-manifest.spdx.json').exists())
        self.assertTrue((self.output / 'LICENSE.sbom.spdx.json.dsr.json').is_file())
        self.assertEqual(len(self.scans()),1); self.save_selection(self.rows)
        self.accepted(self.call()); self.assertEqual(len(self.scans()),3)

    def test_failed_scan_can_resume_but_cannot_drop_selected_shared_file(self):
        self.refused(self.call(fault={'SCAN_FAIL':'runtime.json'}))
        kept = (self.output / 'LICENSE.sbom.spdx.json').read_bytes()
        self.save_selection([r for r in self.rows if r['name'] != 'runtime.json']); self.refused(self.call())
        self.assertFalse((self.output / 'sbom-manifest.spdx.json').exists())
        self.save_selection(self.rows); self.accepted(self.call())
        self.assertEqual((self.output / 'LICENSE.sbom.spdx.json').read_bytes(),kept)
        self.assertEqual([r['name'] for r in self.scans()].count('LICENSE'),1)

    def test_completed_set_rejects_shared_byte_drift_and_policy_downgrade(self):
        proof = self.accepted(self.call()); before = proof.read_bytes()
        self.refused(self.call('verify-artifacts',explicit=False))
        (self.root / 'runtime.json').write_bytes(b'changed'); self.refused(self.call('verify-artifacts'))
        self.assertEqual(proof.read_bytes(),before); self.assertEqual(len(self.scans()),3)

    def test_empty_shared_file_and_hardlink_alias_scanned_independently(self):
        (self.root / 'empty.txt').write_bytes(b''); os.link(self.root / 'tool-linux',self.root / 'compat-linux')
        self.rows = [{'name':p.name,'sha256':digest(p)} for p in sorted(self.root.iterdir())]
        self.save_selection(self.rows); proof = self.accepted(self.call())
        self.assertEqual(len(json.loads(proof.read_bytes())['artifacts']),5); self.assertEqual(self.scans(),self.rows)


class PublicationSelectionTests(unittest.TestCase):
    """Real inventory generation/publication/verification; fixture HTTP/Syft.

    Reuse the existing GitHub transport fixture, keeping all payload selection,
    document validation, hashing, receipt, retry, and publication gates real.
    No network, scanner qualification, signature, or build claim is made.
    """
    setUpClass = classmethod(SelectionTests.setUpClass.__func__)
    scan = SelectionTests.call
    accepted = SelectionTests.accepted
    refused = SelectionTests.refused
    scans = SelectionTests.scans
    save_selection = SelectionTests.save_selection

    def setUp(self):
        SelectionTests.setUp(self)
        (self.root / 'NOTICE').write_bytes(b'owned release notice\n')
        self.rows = [{'name':p.name,'sha256':digest(p)} for p in sorted(self.root.iterdir())]
        self.save_selection(self.rows)
        self.remote = self.work / 'remote'; self.remote.mkdir()
        self.bodies = self.remote / 'bytes'; self.bodies.mkdir()
        self.inventory = self.remote / 'inventory.json'
        assets = []
        for ident, row in enumerate(self.rows, 101):
            body = (self.root / row['name']).read_bytes()
            (self.bodies / str(ident)).write_bytes(body)
            assets.append(dict(id=ident, name=row['name'], state='uploaded', size=len(body),
                               digest='sha256:'+row['sha256']))
        self.inventory.write_text(json.dumps(assets))
        (self.remote / 'repository.json').write_text(json.dumps(dict(id=17,node_id='REPO17',full_name='acme/tool')))
        (self.remote / 'releases.json').write_text('[{"id":42,"tag_name":"v1.2.3"}]')
        (self.remote / 'release.json').write_text(json.dumps(dict(id=42,node_id='REL42',tag_name='v1.2.3',
            draft=True,prerelease=False,target_commitish='main',url='https://api.github.com/repos/acme/tool/releases/42',
            upload_url='https://uploads.github.com/repos/acme/tool/releases/42/assets{?name,label}')))
        (self.remote / 'tag.sha').write_text('1'*40+'\n')
        self.uploads = self.work / 'uploads.log'

    def publish(self, command='publish', *, explicit=True, options=(), fault='', fmt='spdx'):
        env = {k:v for k,v in os.environ.items() if not k.startswith('BASH_FUNC_') and k not in ('BASH_ENV','ENV')}
        env.update(DSR_SELECTION_CASE=str(self.work), DSR_SELECTION_FAULT=fault)
        args = ['--repo','acme/tool','--tag','v1.2.3','--format',fmt]
        if command == 'publish':
            args = [str(self.root),*args,'--output-dir',str(self.output)]
            if explicit: args += ['--selection',str(self.selection)]
        else:
            extension = 'spdx.json' if fmt == 'spdx' else 'cdx.json'
            args += ['--manifest-sha256',digest(self.output / ('sbom-manifest.'+extension))]
        program = r'''set -uo pipefail
source "$1" || exit $?
source "$2" || exit $?
source "$3" || exit $?
action=$4; shift 4
CASE=$DSR_SELECTION_CASE; ART="$CASE/artifacts"; REMOTE="$CASE/remote"
MODE=''; DOWNLOAD_MODE=''; LATE_MODE=''; SYFT_DISABLED=true
# Only GitHub's upload boundary is substituted. The existing fixture supplies
# real inventory reads, immutable-ID downloads, and recorded transport calls.
gh_upload_asset_named() {
    local url=$1 file=$2 name=$3 type=$4
    [[ "$url" == 'https://uploads.github.com/repos/acme/tool/releases/42/assets{?name,label}' &&
       "$file" == */proofs/* && "$type" == application/json ]] || return 99
    printf '%s\n' "$name" >> "$CASE/uploads.log" || return 1
    remote_add "$name" "$file" || return $?
    if [[ "$DSR_SELECTION_FAULT" == selection-drift ]]; then
        printf ' ' >> "$CASE/selection.json" || return 1
    fi
    [[ "$DSR_SELECTION_FAULT" != lost-ack ]] || return 8
    jq -c --arg name "$name" '.[] | select(.name==$name)' "$REMOTE/inventory.json"
}
case "$action" in
    publish) sbom_publish_artifacts "$@" ;;
    verify) sbom_verify_release "$@" ;;
    *) exit 99 ;;
esac
'''
        return subprocess.run(['bash','-c',program,'_',TRANSPORT_FIXTURE,MODULE,REMOTE,command,*args,*options],
                              capture_output=True,text=True,env=env,timeout=45)

    def uploaded_names(self):
        return self.uploads.read_text().splitlines() if self.uploads.exists() else []

    def complete(self, result):
        self.assertEqual(result.returncode,0,result.stderr)
        value=json.loads(result.stdout); self.assertEqual(value['status'],'verified')
        self.assertNotIn('authenticated',value)
        return value

    def test_complete_explicit_publication_verification_and_retry_both_formats(self):
        for fmt, extension in (('spdx','spdx.json'),('cyclonedx','cdx.json')):
            with self.subTest(format=fmt):
                self.accepted(self.scan('artifacts','--format',fmt))
                scans=self.scans(); before=len(self.uploaded_names())
                value=self.complete(self.publish(fmt=fmt))
                self.assertEqual(value['verification']['artifact_count'],4)
                self.assertEqual(value['verification']['verification_policy'],'expected-manifest-sha256')
                self.assertNotIn('authenticated',value['verification'])
                expected=[r['name']+'.sbom.'+extension for r in self.rows]+['sbom-manifest.'+extension]
                self.assertEqual(self.uploaded_names()[before:],expected)
                for name in expected:
                    row=next(r for r in json.loads(self.inventory.read_bytes()) if r['name']==name)
                    self.assertEqual(digest(self.bodies / str(row['id'])),digest(self.output / name))
                frozen=self.inventory.read_bytes()
                self.complete(self.publish('verify',fmt=fmt))
                retry=self.complete(self.publish(fmt=fmt))
                self.assertEqual(retry['sbom_upload_attempts'],0)
                self.assertFalse(retry['manifest_upload_attempted'])
                self.assertEqual(self.inventory.read_bytes(),frozen)
                self.assertEqual(len(self.uploaded_names()),before+5)
                self.assertEqual(self.scans(),scans)

    def test_explicit_policy_cannot_be_dropped_or_duplicated(self):
        self.accepted(self.scan())
        self.refused(self.publish(explicit=False))
        self.refused(self.publish(options=('--selection',str(self.selection))))
        self.assertEqual(self.uploaded_names(),[])

    def test_missing_selected_metadata_fails_before_publication(self):
        self.accepted(self.scan())
        rows=[r for r in json.loads(self.inventory.read_bytes()) if r['name']!='runtime.json']
        self.inventory.write_text(json.dumps(rows))
        result=self.publish(); self.refused(result)
        self.assertIn('Remote payload set differs',result.stderr)
        self.assertEqual(self.uploaded_names(),[])

    def test_unselected_metadata_stays_private_and_unexpected_binary_fails(self):
        self.accepted(self.scan())
        rows=json.loads(self.inventory.read_bytes())
        rows.append(dict(id=999,name='operator.json',state='uploaded',size=1,digest=None))
        self.inventory.write_text(json.dumps(rows))
        (self.root / 'operator.json').write_text('private operator data')
        self.complete(self.publish())
        self.assertFalse(any(name.startswith('operator.json') for name in self.uploaded_names()))
        rows=json.loads(self.inventory.read_bytes())
        rows.append(dict(id=1000,name='unexpected-executable',state='uploaded',size=1,digest=None))
        self.inventory.write_text(json.dumps(rows)); before=self.uploaded_names()
        self.refused(self.publish('verify')); self.refused(self.publish())
        self.assertEqual(self.uploaded_names(),before)

    def test_selected_metadata_digest_and_download_tampering_fail(self):
        self.accepted(self.scan())
        rows=json.loads(self.inventory.read_bytes()); selected=next(r for r in rows if r['name']=='runtime.json')
        selected['digest']='sha256:'+'0'*64
        self.inventory.write_text(json.dumps(rows)); self.refused(self.publish())
        self.assertEqual(self.uploaded_names(),[])
        selected['digest']=None
        self.inventory.write_text(json.dumps(rows))
        (self.bodies / str(selected['id'])).write_bytes(b'x'*selected['size'])
        result=self.publish(); self.refused(result)
        self.assertIn('Downloaded release asset bytes do not match inventory',result.stderr)
        self.assertEqual(self.uploaded_names(),[])

    def test_changed_selection_stops_before_following_upload(self):
        self.accepted(self.scan()); before=self.selection.read_bytes()
        result=self.publish(fault='selection-drift'); self.refused(result)
        self.assertIn('Artifact selection changed',result.stderr)
        self.assertEqual(len(self.uploaded_names()),1)
        self.assertFalse(any(r['name'].startswith('sbom-manifest.') for r in json.loads(self.inventory.read_bytes())))
        self.selection.write_bytes(before)
        self.complete(self.publish())
        self.assertEqual(self.uploaded_names().count('LICENSE.sbom.spdx.json'),1)

    def test_lost_acknowledgement_retains_and_reuses_selected_metadata_proof(self):
        self.accepted(self.scan()); self.refused(self.publish(fault='lost-ack'))
        self.assertEqual(self.uploaded_names(),['LICENSE.sbom.spdx.json'])
        self.complete(self.publish())
        self.assertEqual(self.uploaded_names().count('LICENSE.sbom.spdx.json'),1)
        self.assertEqual(len(self.uploaded_names()),5)

    def test_default_discovery_publication_preserves_existing_policy(self):
        self.accepted(self.scan(explicit=False))
        value=self.complete(self.publish(explicit=False))
        self.assertEqual(value['verification']['artifact_count'],1)
        self.assertEqual(self.uploaded_names(),['tool-linux.sbom.spdx.json','sbom-manifest.spdx.json'])

if __name__ == '__main__': unittest.main(verbosity=2)
PY
