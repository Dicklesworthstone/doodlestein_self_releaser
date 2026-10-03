#!/usr/bin/env bash
# Real Git, private descriptors, signed local plans and signed remote-byte
# verification. Only GitHub's HTTP/download boundary uses isolated fixtures.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
os.umask(0o077)
work = Path(tempfile.mkdtemp(prefix='dsr-strict-finalize-'))
source = Path(os.environ.get('DSR_TEST_COMMAND_FILE', str(root / 'dsr'))).read_text()
names = re.findall(r'^(_release_[A-Za-z0-9_]+)\(\) \{', source, re.M)
names += ['_source_release_read_private_receipt', '_source_release_metadata_matches',
          '_source_release_restore_draft', '_source_release_identity',
          '_source_release_inputs_match', 'cmd_release_finalize']
functions = work / 'functions.sh'
functions.write_text('\n'.join(re.search(r'^' + re.escape(n) + r'\(\) \{\n.*?^\}', source, re.M | re.S).group(0) for n in names))
print('Fixtures: ' + str(work), flush=True)
checks = 0

def check(label, value):
    global checks
    if not value:
        raise AssertionError(label)
    checks += 1
    print('PASS ' + label, flush=True)

base = work / 'base'
repo = base / 'repo'
repo.mkdir(parents=True)
subprocess.run(['minisign', '-G', '-W', '-p', str(repo/'minisign.pub'), '-s', str(base/'fixture.key')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
(repo/'README.md').write_text('Isolated signing fixture. No release compilation.\n')
for args in [['init','-q'],['config','user.name','DSR fixture'],['config','user.email','dsr@example.invalid'],['add','README.md','minisign.pub'],['commit','-qm','signed source fixture'],['tag','-a','v1.2.3','-m','fixture'],['remote','add','origin','https://github.com/owner/app.git']]:
    subprocess.run(['git','-C',str(repo)]+args,check=True)
sha = subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
contract = {'checksum_sidecar':'sha256','minisign_public_key_file':'minisign.pub',
            'exact_primary_assets':{'linux/amd64':'payload.tar.gz'},
            'exact_additional_assets':['SHA256SUMS','SHA256SUMS.minisig']}

api = r'''
import json, os
from pathlib import Path
import sys
c=Path(os.environ['CASE']); args=sys.argv[1:]; endpoint=args[0]
control=json.loads((c/'control.json').read_text())
with (c/'requests.jsonl').open('a') as f:f.write(json.dumps(args)+'\n')
r=json.loads((c/'remote.json').read_text())
if endpoint.startswith('repos/owner/app/releases?'):
    print(json.dumps([] if 'page=2' in endpoint else [dict(r,id=99) if control.get('wrong_scan_id') else r]))
elif endpoint=='repos/owner/app/git/ref/tags/v1.2.3':
    moved=control.get('tag_drift_after_publish') and not r['draft']
    print(json.dumps({'object':{'type':'commit','sha':'f'*40 if moved else os.environ['SOURCE_SHA']}}))
elif endpoint=='repos/owner/app/releases/9':
    if '--method' in args:
        r.update(json.loads(args[args.index('--data')+1]))
        if r['draft'] is False and control.get('metadata_drift_after_publish'):r['body']='changed after publish'
        (c/'remote.json').write_text(json.dumps(r));print(json.dumps(r))
        sys.exit(1 if control.get('lost_patch') else 0)
    count=control.get('reads',0)+1;control['reads']=count
    if count==2 and control.get('receipt_replace'):
        p=c/'tmp/dsr-api-response.ABCDEF12'; retained=p.with_name(p.name+'.retained');p.rename(retained)
        if control['receipt_replace']=='symlink':p.symlink_to(retained)
        else:p.write_bytes(retained.read_bytes());p.chmod(0o600)
    if count==2 and control.get('config_drift'):
        p=c/'config/repos.d/app.yaml';p.write_text(p.read_text()+'\n')
    if count==2 and control.get('registry_appears'):
        (c/'config/repos.yaml').write_text(json.dumps({'tools':{'app':{'release_contract':{}}}}))
    (c/'control.json').write_text(json.dumps(control));print(json.dumps(r))
elif endpoint.startswith('repos/owner/app/releases/9/assets?'):
    assets=list(r['assets'])
    if control.get('hidden_asset') or (control.get('post_hidden_asset') and not r['draft']):assets.append(dict(assets[0],id=999,name='hidden.bin'))
    print(json.dumps([] if 'page=2' in endpoint else assets))
else:print('Unexpected API '+endpoint,file=sys.stderr);sys.exit(89)
'''

script = r'''
set -uo pipefail
source "$ROOT/src/github.sh"
source "$ROOT/src/config.sh"
source "$ROOT/src/git_ops.sh"
source "$ROOT/src/act_runner.sh"
source "${DSR_TEST_SIGNING_MODULE:-$ROOT/src/signing.sh}"
source "$FUNCTIONS"
log_error() { printf 'ERROR %s\n' "$*" >&2; }
log_info() { printf 'INFO %s\n' "$*" >&2; }
log_ok() { log_info "$@"; }
log_warn() { log_info "$@"; }
gh_check() { return 0; }
gh_check_token() { return 0; }
gh_api() { python3 "$CASE/api.py" "$@"; }
gh_download_release_asset() { test ! -e "$3" && cp "$CASE/bytes/$2" "$3"; }
mktemp() {
    if [[ "${FAIL_PENDING:-false}" == true && "$*" == *finalization-pending* ]]; then return 1; fi
    if [[ "${FAIL_FINAL:-false}" == true && "$*" == *-finalized.* ]]; then return 1; fi
    command mktemp "$@"
}
DRY_RUN=false
JSON_MODE=false
if [[ "$1" == prepare ]]; then
    act_load_repo_config app || exit
    contract=$(config_get_release_contract_json app) || exit
    _release_contract_preflight app v1.2.3 owner/app "$CASE/repo" "$CASE/state/artifacts/app-v1.2.3" "$CASE/state/artifacts/app-v1.2.3/app-v1.2.3-manifest.json" "$contract" create > "$CASE/plan.json"
else
    shift
    DRY_RUN="$1"; shift
    cmd_release_finalize "$@"
fi
'''

def setup(label, controls=None):
    c=work/label;shutil.copytree(base,c)
    for name in ['tmp','config/repos.d','state/artifacts/app-v1.2.3','bytes']:(c/name).mkdir(parents=True)
    (c/'api.py').write_text(api);(c/'requests.jsonl').write_text('');(c/'control.json').write_text(json.dumps(controls or {}))
    (c/'config/repos.d/app.yaml').write_text(json.dumps({'tool_name':'app','repo':'owner/app','local_path':str(c/'repo'),'targets':['linux/amd64'],'release_contract':contract}))
    artifacts=c/'state/artifacts/app-v1.2.3'
    # A real tar archive; this test does not claim a native binary build.
    subprocess.run(['tar','-czf',str(artifacts/'payload.tar.gz'),'-C',str(c/'repo'),'README.md'],check=True)
    payload=(artifacts/'payload.tar.gz').read_bytes()
    manifest={'tool':'app','version':'v1.2.3','source':{'git_sha':sha,'git_ref':'v1.2.3','dependencies':[]},
              'build_purpose':'release','publishable':True,'requested_targets':['linux/amd64'],
              'status':'success','summary':{'total':1,'success':1,'failed':0},
              'artifacts':[{'name':'payload.tar.gz','target':'linux/amd64','sha256':hashlib.sha256(payload).hexdigest(),'size_bytes':len(payload),'build_purpose':'release','publishable':True}]}
    (artifacts/'app-v1.2.3-manifest.json').write_text(json.dumps(manifest))
    original={'id':9,'tag_name':'v1.2.3','name':'v1.2.3','target_commitish':sha,'draft':True,'prerelease':False,'assets':[],
              'body':'Release 1.2.3\n\n<!-- dsr-create-nonce:'+'1'*64+' -->',
              'upload_url':'https://uploads.github.com/repos/owner/app/releases/9/assets{?name,label}',
              'html_url':'https://github.com/owner/app/releases/tag/untagged-fixture'}
    (c/'remote.json').write_text(json.dumps(original))
    response=c/'tmp/dsr-api-response.ABCDEF12';response.write_text(json.dumps(original));response.chmod(0o600)
    env=dict(os.environ,ROOT=str(root),FUNCTIONS=str(functions),CASE=str(c),SOURCE_SHA=sha,
             DSR_CONFIG_DIR=str(c/'config'),DSR_STATE_DIR=str(c/'state'),TMPDIR=str(c/'tmp'),DSR_MINISIGN_KEY=str(c/'fixture.key'),NO_COLOR='1')
    r=subprocess.run(['bash','-c',script,'fixture','prepare'],env=env,capture_output=True,text=True)
    (c/'prepare.log').write_text(r.stdout+r.stderr)
    if r.returncode:raise AssertionError(label+' real preflight: '+r.stderr[-2500:])
    plan=json.loads((c/'plan.json').read_text());remote=dict(original,assets=[])
    for i,a in enumerate(plan['assets'],100):
        shutil.copyfile(a['path'],c/'bytes'/str(i))
        remote['assets'].append({'id':i,'name':a['name'],'state':'uploaded','size':a['size_bytes'],'digest':'sha256:'+a['sha256']})
    (c/'remote.json').write_text(json.dumps(remote))
    (c/'requests.jsonl').write_text('')
    return c,env,response,original

def invoke(c,env,response,dry=False,flags=None):
    args=flags if flags is not None else ['app','1.2.3','--create-response',str(response),'--no-dispatch']
    r=subprocess.run(['bash','-c',script,'fixture','run',str(dry).lower()]+args,env=env,capture_output=True,text=True)
    (c/'finalize.log').write_text(r.stdout+r.stderr)
    requests=[json.loads(l) for l in (c/'requests.jsonl').read_text().splitlines()]
    patches=[q for q in requests if '--method' in q]
    return r,patches

for label,controls in [('success',{}),('lost-patch',{'lost_patch':True}),('already-public',{}),('dry-run',{})]:
    c,env,response,_=setup(label,controls)
    raw=response.read_bytes();before=response.stat()
    if label=='already-public':
        remote=json.loads((c/'remote.json').read_text());remote['draft']=False;(c/'remote.json').write_text(json.dumps(remote))
    r,patches=invoke(c,env,response,dry=label=='dry-run')
    check(label+' terminal0',r.returncode==0)
    check(label+' expected mutation count',len(patches)==(1 if label in ['success','lost-patch'] else 0))
    check(label+' original receipt preserved',response.read_bytes()==raw and response.stat().st_ino==before.st_ino)
    check(label+' no creation POST',not any('--post' in q for q in map(json.loads,(c/'requests.jsonl').read_text().splitlines())))
    if label!='dry-run':check(label+' public exact source',json.loads((c/'remote.json').read_text())['draft'] is False)

for label in ['wrong-id','wrong-tag','wrong-target','wrong-nonce','wrong-url','initial-assets','permissions','hardlink','symlink','outside','duplicate-key','no-contract','source-only-mode','conflicting-registry','local-bytes','local-signature','remote-bytes','metadata','extra-asset','missing-asset','no-dispatch','extra-argument','optimized-python','pending-write-failure']:
    c,env,response,original=setup(label)
    flags=None
    if label.startswith('wrong-') or label=='initial-assets':
        field,value={'wrong-id':('id',99),'wrong-tag':('tag_name','v9.9.9'),'wrong-target':('target_commitish','f'*40),'wrong-nonce':('body','no nonce'),'wrong-url':('upload_url','https://example.invalid/'),'initial-assets':('assets',[{'id':1}])}[label]
        original[field]=value;response.write_text(json.dumps(original))
    elif label=='permissions':response.chmod(0o644)
    elif label=='hardlink':os.link(response,response.with_name('second-link'))
    elif label=='symlink':
        retained=response.with_name('retained');response.rename(retained);response.symlink_to(retained)
    elif label=='outside':
        out=c/'dsr-api-response.ABCDEF12';out.write_bytes(response.read_bytes());out.chmod(0o600);response=out
    elif label=='duplicate-key':response.write_text(response.read_text()[:-1]+',"id":9}')
    elif label=='no-contract':
        p=c/'config/repos.d/app.yaml';data=json.loads(p.read_text());data.pop('release_contract');p.write_text(json.dumps(data))
    elif label=='source-only-mode':
        p=c/'config/repos.d/app.yaml';data=json.loads(p.read_text());data['publication_mode']='source-only';p.write_text(json.dumps(data))
    elif label=='conflicting-registry':(c/'config/repos.yaml').write_text(json.dumps({'tools':{'app':{}}}))
    elif label in ['local-bytes','local-signature']:
        p=c/'state/artifacts/app-v1.2.3'/('payload.tar.gz' if label=='local-bytes' else 'payload.tar.gz.minisig');p.write_bytes(b'bad bytes\n')
    elif label=='remote-bytes':(c/'bytes/100').write_bytes(b'bad served bytes\n')
    elif label in ['metadata','extra-asset','missing-asset']:
        p=c/'remote.json';data=json.loads(p.read_text())
        if label=='metadata':data['target_commitish']='f'*40
        elif label=='extra-asset':data['assets'].append(dict(data['assets'][0],id=999,name='extra.bin'))
        else:data['assets'].pop()
        p.write_text(json.dumps(data))
    elif label=='no-dispatch':flags=['app','1.2.3','--create-response',str(response)]
    elif label=='extra-argument':flags=['app','1.2.3','--create-response',str(response),'--no-dispatch','extra']
    elif label=='optimized-python':response.chmod(0o644);env['PYTHONOPTIMIZE']='1'
    elif label=='pending-write-failure':env['FAIL_PENDING']='true'
    r,patches=invoke(c,env,response,flags=flags)
    check(label+' refused',r.returncode!=0)
    check(label+' no publication',not patches)

for label,controls in [('same-bytes-replacement',{'receipt_replace':'regular'}),('symlink-replacement',{'receipt_replace':'symlink'}),('config-drift',{'config_drift':True}),('registry-appears',{'registry_appears':True}),('wrong-scan-id',{'wrong_scan_id':True}),('hidden-asset',{'hidden_asset':True})]:
    c,env,response,_=setup(label,controls);r,patches=invoke(c,env,response)
    check(label+' refused',r.returncode!=0);check(label+' no publication',not patches)

for label,controls in [('post-metadata-drift',{'metadata_drift_after_publish':True}),('post-tag-drift',{'tag_drift_after_publish':True}),('post-hidden-asset',{'post_hidden_asset':True}),('final-write-failure',{})]:
    c,env,response,_=setup(label,controls)
    if label=='final-write-failure':env['FAIL_FINAL']='true'
    r,patches=invoke(c,env,response)
    check(label+' terminal failure',r.returncode!=0)
    check(label+' restored owned draft',json.loads((c/'remote.json').read_text())['draft'] is True)
    check(label+' only frozen ID mutated',all(q[0]=='repos/owner/app/releases/9' for q in patches))
    check(label+' pending record retained',len(list((c/'state/releases').glob('*finalization-pending.*')))==1)

print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
PY
