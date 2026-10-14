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

if __name__ == '__main__': unittest.main(verbosity=2)
PY
