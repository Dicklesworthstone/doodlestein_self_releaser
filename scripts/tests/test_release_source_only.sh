#!/usr/bin/env bash
# Real Git/config/CLI admission and draft custody with fixture GitHub HTTP.
# Atomic-writer probes additionally inject drift at the filesystem replacement
# boundary. Actual publication must additionally have a public readback.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
python3 - "$ROOT" <<'PY'
import json
import hashlib
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
os.umask(0o077)
work = Path(tempfile.mkdtemp(prefix='dsr-source-release-'))
source = (root / 'dsr').read_text()
names = ['_source_release_identity', '_source_release_metadata_matches',
         '_source_release_observe', '_source_release_restore_draft',
         '_source_release_inputs_match',
         '_source_release_read_private_receipt', '_source_release_resume_receipt_matches',
         '_source_release_scan_created', '_source_release_save_receipt',
         'cmd_release_source_only', 'cmd_release', '_release_sbom_policy',
         '_release_contract_verify_remote_tag_identity',
         '_release_contract_scan_release_by_tag', '_release_contract_create_nonce',
         '_release_contract_observe_bound_draft',
         '_release_contract_confirm_or_restore_bound_draft', '_release_file_size']
functions = work / 'functions.sh'
functions.write_text('\n'.join(re.search(r'^' + re.escape(n) + r'\(\) \{\n.*?^\}', source, re.M | re.S).group(0) for n in names))
print('Fixtures: ' + str(work), flush=True)
checks = 0

def assert_ok(label, value):
    global checks
    if not value:
        raise AssertionError(label)
    checks += 1
    print('PASS ' + label, flush=True)

api_source = r'''
import json, os
from pathlib import Path
import sys
case=Path(os.environ['CASE']); args=sys.argv[1:]; endpoint=args[0]
control=json.loads((case/'control.json').read_text())
with (case/'requests.jsonl').open('a') as f: f.write(json.dumps(args)+'\n')
release_file=case/'remote.json'
release=json.loads(release_file.read_text()) if release_file.exists() else None
if endpoint=='repos/owner/app/releases' and '--post' in args:
    data=json.loads(args[args.index('--post')+1]); data.update(id=9,assets=[],html_url='https://github.com/owner/app/releases/tag/v1.2.3')
    if control.get('wrong_create_body'): data['body']='peer-owned body'
    if control.get('embedded_asset'): data['assets']=[{'id':1,'name':'unexpected.bin'}]
    release_file.write_text(json.dumps(data)); print(json.dumps(data))
    sys.exit(1 if control.get('lost_post') else 0)
if endpoint.startswith('repos/owner/app/releases?'):
    if control.get('scan_failure'): sys.exit(88)
    if release is not None and control.get('omit_created'):
        print('[]');sys.exit(0)
    if release is not None and control.get('delay_created',0)>0:
        control['delay_created']-=1;(case/'control.json').write_text(json.dumps(control))
        print('[]');sys.exit(0)
    if release is not None and control.get('switch_scan_id'):
        calls=control.get('resume_scan_calls',0)+1
        control['resume_scan_calls']=calls;(case/'control.json').write_text(json.dumps(control))
        if calls>1:release=dict(release,id=10)
    if control.get('scan_malformed'): print('{}')
    else: print(json.dumps([release] if release is not None else []))
elif endpoint.startswith('repos/owner/app/git/ref/tags/'):
    if control.get('kill_after_retry_checkpoint'):
        receipts=(case/'state'/'source-only').glob('*.json.*')
        if any(record.get('status')=='pending' and record.get('resumed_from')
               for record in (json.loads(path.read_text()) for path in receipts)):
            import signal
            os.kill(int(os.environ['DSR_SOURCE_TEST_CONTROLLER_PID']),signal.SIGKILL)
            sys.exit(0)
    if control.get('config_moves'):
        path=case/'repos.d'/'app.yaml'; data=json.loads(path.read_text()); data['build_cmd']='cargo build --release'; path.write_text(json.dumps(data))
    if control.get('registry_appears'):
        (case/'repos.yaml').write_text(json.dumps({'tools':{'app':{'build_cmd':'cargo build --release'}}}))
    sha=(case/'sha').read_text().strip()
    if control.get('remote_tag_wrong') or (control.get('move_tag_after_publish') and release is not None and not release['draft']): sha='f'*40
    if control.get('move_tag_after_observations') and control.get('release_observations',0)>=control['move_tag_after_observations']: sha='f'*40
    print(json.dumps({'object':{'type':'tag' if control.get('annotated_remote') else 'commit','sha':'a'*40 if control.get('annotated_remote') else sha}}))
elif endpoint=='repos/owner/app/git/tags/'+'a'*40:
    print(json.dumps({'object':{'type':'commit','sha':(case/'sha').read_text().strip()}}))
elif endpoint=='repos/owner/app/releases/9' and '--method' in args:
    data=json.loads(args[args.index('--data')+1])
    if control.get('reject_publish') and data.get('draft') is False: sys.exit(87)
    release.update(data)
    if control.get('body_changes_after_publish') and data.get('draft') is False: release['body']='another worker changed body'
    release_file.write_text(json.dumps(release))
    if control.get('kill_after_publish') and data.get('draft') is False:
        import signal
        os.kill(os.getppid(),signal.SIGKILL)
        sys.exit(0)
    print(json.dumps(release))
    sys.exit(1 if control.get('lost_patch') else 0)
elif endpoint=='repos/owner/app/releases/9':
    if control.get('move_tag_after_observations'):
        control['release_observations']=control.get('release_observations',0)+1
        (case/'control.json').write_text(json.dumps(control))
    if control.get('receipt_replace'):
        path=Path(control['receipt_path']);retained=path.with_name(path.name+'.retained')
        path.rename(retained)
        if control['receipt_replace']=='symlink':path.symlink_to(retained)
        else:path.write_bytes(retained.read_bytes());path.chmod(0o600)
        control['receipt_replace']=False;(case/'control.json').write_text(json.dumps(control))
    if control.get('wrong_observed_id'): release=dict(release,id=99)
    print(json.dumps(release))
elif endpoint.startswith('repos/owner/app/releases/9/assets?'):
    print(json.dumps([{'id':1,'name':'hidden.bin'}] if control.get('hidden_asset') else []))
else:
    print('unexpected API endpoint: '+endpoint,file=sys.stderr); sys.exit(89)
'''

def setup(label, controls=None):
    case = work / label
    case.mkdir()
    repo = case / 'repo'; repo.mkdir()
    subprocess.run(['git','init','-q',str(repo)],check=True)
    subprocess.run(['git','-C',str(repo),'config','user.name','DSR fixture'],check=True)
    subprocess.run(['git','-C',str(repo),'config','user.email','dsr@example.invalid'],check=True)
    (repo/'install.sh').write_text('#!/bin/sh\nprintf source-fixture\\n\n')
    subprocess.run(['git','-C',str(repo),'add','install.sh'],check=True)
    subprocess.run(['git','-C',str(repo),'commit','-qm','source fixture'],check=True)
    subprocess.run(['git','-C',str(repo),'tag','-a','v1.2.3','-m','annotated fixture'],check=True)
    subprocess.run(['git','-C',str(repo),'remote','add','origin','https://github.com/owner/app.git'],check=True)
    sha=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
    (case/'sha').write_text(sha)
    (case/'notes.md').write_text('Reviewed source-only notes.\n\nSecond paragraph.\n\n')
    config={'tool_name':'app','repo':'owner/app','local_path':str(repo),'publication_mode':'source-only'}
    (case/'repos.d').mkdir()
    (case/'repos.d'/'app.yaml').write_text(json.dumps(config))
    (case/'control.json').write_text(json.dumps(controls or {}))
    (case/'api.py').write_text(api_source)
    (case/'requests.jsonl').write_text('')
    return case, repo, config

def invoke(case, flags=None, dry=False, binary=False):
    env=dict(os.environ,CASE=str(case),DSR_CONFIG_DIR=str(case),DSR_STATE_DIR=str(case/'state'),
             ROOT=str(root),FUNCTIONS=str(functions),NO_COLOR='1')
    script=r'''
set -uo pipefail
source "$ROOT/src/github.sh"
source "$ROOT/src/config.sh"
source "$ROOT/src/git_ops.sh"
source "$ROOT/src/act_runner.sh"
source "$FUNCTIONS"
log_error() { printf 'ERROR %s\n' "$*" >&2; }
log_info() { printf 'INFO %s\n' "$*" >&2; }
log_warn() { printf 'WARN %s\n' "$*" >&2; }
log_set_tool() { :; }
_dsr_require() { :; }
gh_check() { return 0; }
gh_check_token() { return 0; }
gh_api() { python3 "$CASE/api.py" "$@"; }
JSON_MODE=false
DRY_RUN="$1"
command_name="$2"
shift 2
export DSR_SOURCE_TEST_CONTROLLER_PID="$BASHPID"
"$command_name" "$@"
'''
    args=['bash','-c',script,'source-release-test','true' if dry else 'false',
          'cmd_release' if binary else 'cmd_release_source_only','app','1.2.3']
    if flags is None: flags=['--notes-file',str(case/'notes.md'),'--no-dispatch']
    proc=subprocess.run(args+flags,env=env,capture_output=True,text=True,timeout=60)
    (case/'stdout.log').write_text(proc.stdout); (case/'stderr.log').write_text(proc.stderr)
    requests=[json.loads(l) for l in (case/'requests.jsonl').read_text().splitlines()]
    if proc.returncode not in (0,4,7):
        print(proc.stderr,flush=True)
    return proc, requests

for label,control in [('publish',{}),('lost-post',{'lost_post':True}),('lost-patch',{'lost_patch':True}),('annotated-remote',{'annotated_remote':True})]:
    case,repo,config=setup(label,control); proc,requests=invoke(case)
    assert_ok(label+' terminal success',proc.returncode==0)
    remote=json.loads((case/'remote.json').read_text())
    assert_ok(label+' exact multiline notes',remote['body'].startswith((case/'notes.md').read_text()+'\n\n<!-- dsr-source-only-create:'))
    assert_ok(label+' verified publication',remote['draft'] is False and remote['assets']==[])
    receipts=list((case/'state'/'source-only').glob('*.json.*'))
    assert_ok(label+' separate source receipt',len(receipts)==1 and json.loads(receipts[0].read_text())['publication_mode']=='source-only')
    assert_ok(label+' authoritative inventory observed',sum('/assets?' in r[0] for r in requests)>=2)

case,repo,config=setup('draft'); proc,requests=invoke(case,['--notes-file',str(case/'notes.md'),'--no-dispatch','--draft','--prerelease'])
assert_ok('requested draft stays draft',proc.returncode==0 and json.loads((case/'remote.json').read_text())['draft'] is True)
assert_ok('requested prerelease retained',json.loads((case/'remote.json').read_text())['prerelease'] is True)
assert_ok('requested draft has no PATCH',not any('--method' in r for r in requests))
case,repo,config=setup('dry-run'); proc,requests=invoke(case,dry=True)
assert_ok('dry-run admitted',proc.returncode==0)
assert_ok('dry-run no mutation/receipt',not any('--post' in r or '--method' in r for r in requests) and not (case/'state').exists())

case,repo,config=setup('delayed-visibility',{'delay_created':2}); proc,requests=invoke(case)
assert_ok('delayed visibility reconciles',proc.returncode==0)
assert_ok('delayed visibility creates once',sum('--post' in r for r in requests)==1)

resume_labels=('resume','resume-legacy','resume-draft','resume-dry-run','resume-notes',
               'resume-config','resume-registry','resume-tag','resume-mode','resume-symlink',
               'resume-hardlink','resume-outside','resume-schema','resume-nonce',
               'resume-metadata','resume-wrong-id','resume-hidden-asset','resume-lost-patch',
               'resume-scan-id','resume-parent-mode','resume-inode','resume-path-race',
               'resume-optimized-mode')

def prepare_resume(label):
    case,repo,config=setup(label,{'omit_created':True})
    initial_flags=['--notes-file',str(case/'notes.md'),'--no-dispatch']
    if label=='resume-draft':initial_flags+=['--draft']
    first,requests=invoke(case,initial_flags)
    return case,repo,config,initial_flags,first,requests

# Only independent initial HTTP-visibility waits run concurrently. Every case
# still has its own real Git/config/state tree, complete original command and
# timeout. All assertions and subsequent recovery mutations remain sequential.
with ThreadPoolExecutor(max_workers=2) as pool:
    prepared_resumes=dict(zip(resume_labels,pool.map(prepare_resume,resume_labels)))

for label in resume_labels:
    case,repo,config,initial_flags,first,requests=prepared_resumes[label]
    assert_ok(label+' omission keeps pending draft',first.returncode==7 and json.loads((case/'remote.json').read_text())['draft'] is True and not any('--method' in r for r in requests))
    pending=next((case/'state'/'source-only').glob('*.json.*'))
    if label=='resume-legacy':
        data=json.loads(pending.read_text());data.pop('registry_sha256');data.pop('requested_draft');pending.write_text(json.dumps(data))
    before=pending.read_bytes()
    control={}
    if label=='resume-notes':(case/'notes.md').write_text('changed reviewed notes')
    if label=='resume-config':
        config['local_path']=str(repo)+'/'
        (case/'repos.d'/'app.yaml').write_text(json.dumps(config))
    if label=='resume-registry':(case/'repos.yaml').write_text(json.dumps({'tools':{}}))
    if label=='resume-tag':control['remote_tag_wrong']=True
    if label=='resume-mode':pending.chmod(0o644)
    if label=='resume-optimized-mode':
        pending.chmod(0o644);os.environ['PYTHONOPTIMIZE']='1'
    if label=='resume-parent-mode':pending.parent.chmod(0o770)
    resume_path=pending
    if label=='resume-symlink':
        resume_path=pending.with_name(pending.name+'.link');resume_path.symlink_to(pending)
    if label=='resume-hardlink':
        resume_path=pending.with_name(pending.name+'.hard');os.link(pending,resume_path)
    if label=='resume-outside':
        resume_path=case/pending.name;shutil.copyfile(pending,resume_path);resume_path.chmod(0o600)
    if label in ('resume-schema','resume-nonce','resume-metadata'):
        data=json.loads(pending.read_text())
        if label=='resume-schema':data['publication_mode']='binary'
        if label=='resume-nonce':data['metadata']['body']=data['metadata']['body'].replace('dsr-source-only-create:','invalid-nonce:')
        if label=='resume-metadata':data['metadata']['name']='peer title'
        pending.write_text(json.dumps(data));before=pending.read_bytes()
    if label=='resume-wrong-id':control['wrong_observed_id']=True
    if label=='resume-hidden-asset':control['hidden_asset']=True
    if label=='resume-lost-patch':control['lost_patch']=True
    if label=='resume-scan-id':control['switch_scan_id']=True
    if label in ('resume-inode','resume-path-race'):
        control['receipt_replace']='symlink' if label=='resume-path-race' else 'regular'
        control['receipt_path']=str(pending)
    (case/'control.json').write_text(json.dumps(control))
    flags=initial_flags+['--resume-receipt',str(resume_path)]
    proc,requests=invoke(case,flags,dry=label=='resume-dry-run')
    if label=='resume-optimized-mode':os.environ.pop('PYTHONOPTIMIZE',None)
    assert_ok(label+' never recreates',sum('--post' in r for r in requests)==1)
    assert_ok(label+' original pending bytes retained',pending.read_bytes()==before)
    if label in ('resume','resume-legacy','resume-draft','resume-dry-run','resume-lost-patch'):
        assert_ok(label+' admitted',proc.returncode==0)
        if label in ('resume-draft','resume-dry-run'):
            assert_ok(label+' no publication PATCH',not any('--method' in r for r in requests))
        else:assert_ok(label+' published same owned ID',json.loads((case/'remote.json').read_text())['id']==9 and json.loads((case/'remote.json').read_text())['draft'] is False)
        receipts=list((case/'state'/'source-only').glob('*.json.*'))
        assert_ok(label+' recovery receipt count',len(receipts)==(1 if label=='resume-dry-run' else 2))
    else:
        assert_ok(label+' refused without mutation',proc.returncode in (4,7) and not any('--method' in r for r in requests))

case,repo,config=setup('isolated-receipt-import',{'omit_created':True})
first,requests=invoke(case)
pending=next((case/'state'/'source-only').glob('*.json.*'))
(case/'json.py').write_text('raise RuntimeError("untrusted local import")\n')
reader=subprocess.run(['bash','-c','source "$1"; _source_release_read_private_receipt "$2" "$3" app v1.2.3',
                      'receipt-import-test',str(functions),str(pending),str(pending.parent)],
                      cwd=case,env=dict(os.environ,PYTHONOPTIMIZE='1'),capture_output=True,text=True,timeout=60)
assert_ok('private reader isolates local imports and optimization',reader.returncode==0 and json.loads(reader.stdout)['record']['status']=='pending')

for label,control in [('failed-scan',{'scan_failure':True}),('malformed-scan',{'scan_malformed':True}),
                      ('config-moves',{'config_moves':True}),('registry-appears',{'registry_appears':True}),
                      ('peer-post',{'wrong_create_body':True,'lost_post':True}),
                      ('hidden-asset',{'hidden_asset':True}),('embedded-asset',{'embedded_asset':True}),
                      ('wrong-id',{'wrong_observed_id':True}),('remote-tag',{'remote_tag_wrong':True}),
                      ('tag-moves',{'move_tag_after_publish':True}),
                      ('peer-body',{'body_changes_after_publish':True})]:
    case,repo,config=setup(label,control); proc,requests=invoke(case)
    assert_ok(label+' fail closed',proc.returncode in (4,7))
    if label in ('peer-post','hidden-asset','embedded-asset','wrong-id'):
        assert_ok(label+' never published',not any('--data' in r and json.loads(r[r.index('--data')+1]).get('draft') is False for r in requests))
    if label in ('peer-post','wrong-id'):
        assert_ok(label+' unproven custody not rolled back',not any('--data' in r and json.loads(r[r.index('--data')+1]).get('draft') is True for r in requests))
    if label in ('tag-moves','peer-body'):
        assert_ok(label+' owned release restored draft',json.loads((case/'remote.json').read_text())['draft'] is True)

for label in ('dirty','staged','wrong-root','wrong-origin','wrong-local-tag','replace-object','mode-absent','binary-contract','inherited-config','legacy-binary','existing-peer','binary-command'):
    case,repo,config=setup(label)
    if label=='dirty': (repo/'extra.txt').write_text('untracked')
    if label=='staged':
        (repo/'install.sh').write_text('staged change')
        subprocess.run(['git','-C',str(repo),'add','install.sh'],check=True)
    if label=='wrong-root':
        (repo/'subdir').mkdir(); config['local_path']=str(repo/'subdir')
    if label=='wrong-origin': subprocess.run(['git','-C',str(repo),'remote','set-url','origin','https://github.com/owner/peer.git'],check=True)
    if label=='wrong-local-tag':
        (repo/'install.sh').write_text('next committed source')
        subprocess.run(['git','-C',str(repo),'add','install.sh'],check=True)
        subprocess.run(['git','-C',str(repo),'commit','-qm','later change'],check=True)
    if label=='replace-object':
        old=(case/'sha').read_text().strip()
        (repo/'install.sh').write_text('replacement tree')
        subprocess.run(['git','-C',str(repo),'add','install.sh'],check=True)
        tree=subprocess.check_output(['git','-C',str(repo),'write-tree'],text=True).strip()
        replacement=subprocess.check_output(['git','-C',str(repo),'commit-tree',tree,'-m','replacement'],text=True).strip()
        subprocess.run(['git','-C',str(repo),'replace',old,replacement],check=True)
        assert_ok('replacement really disguises ordinary Git status',subprocess.check_output(['git','-C',str(repo),'status','--porcelain'],text=True)=='')
    if label=='mode-absent': config.pop('publication_mode')
    if label=='binary-contract': config['release_contract']={'exact_primary_assets':{'linux/amd64':'app.tar.gz'}}
    if label=='inherited-config': config['extends']='binary.yaml'
    if label=='legacy-binary': (case/'repos.yaml').write_text(json.dumps({'tools':{'app':{'build_cmd':'cargo build --release','release_contract':{'exact_primary_assets':{'linux/amd64':'app.tar.gz'}}}}}))
    if label=='existing-peer': (case/'remote.json').write_text(json.dumps({'id':8,'tag_name':'v1.2.3','body':'peer draft','draft':True}))
    (case/'repos.d'/'app.yaml').write_text(json.dumps(config))
    proc,requests=invoke(case,flags=[] if label=='binary-command' else None,binary=label=='binary-command')
    assert_ok(label+' refused before mutation',proc.returncode==4 and not any('--post' in r or '--method' in r for r in requests))

for index,flag in enumerate(['--artifacts','--resume','--verify-upgrade','--generate-notes','--dispatch','--dispatch-event','--dispatch-repos']):
    case,repo,config=setup('unsupported-'+str(index)); proc,requests=invoke(case,['--notes-file',str(case/'notes.md'),'--no-dispatch',flag])
    assert_ok(flag+' rejected without mutation',proc.returncode==4 and requests==[])
case,repo,config=setup('no-dispatch-missing'); proc,requests=invoke(case,['--notes-file',str(case/'notes.md')])
assert_ok('no-dispatch required',proc.returncode==4 and requests==[])

# Retained drafts are complete publications of private state. Omitting --draft
# on resume does not authorize making them public; promotion is explicit.
case,repo,config=setup('completed-draft-promotion')
flags=['--notes-file',str(case/'notes.md'),'--no-dispatch','--prerelease']
first,requests=invoke(case,flags+['--draft'])
assert_ok('completed draft creation succeeds',first.returncode==0)
original=next((case/'state'/'source-only').glob('*.json.*'))
original_bytes=original.read_bytes(); original_inode=original.stat().st_ino
saved=json.loads(original_bytes)
assert_ok('completed draft retains exact identity and private intent',saved['release_id']==9
          and saved['requested_draft'] is True and saved['publication_requested'] is False)
proc,requests=invoke(case,flags+['--resume-receipt',str(original)])
assert_ok('plain completed-draft resume stays private',proc.returncode==0
          and json.loads((case/'remote.json').read_text())['draft'] is True
          and not any('--method' in r for r in requests))
before_records=set((case/'state'/'source-only').glob('*.json.*'))
proc,requests=invoke(case,flags+['--resume-receipt',str(original),'--publish-draft'],dry=True)
assert_ok('draft promotion dry-run performs no mutation or receipt write',proc.returncode==0
          and set((case/'state'/'source-only').glob('*.json.*'))==before_records
          and not any('--method' in r for r in requests))
proc,requests=invoke(case,flags+['--resume-receipt',str(original),'--publish-draft'])
promoted=set((case/'state'/'source-only').glob('*.json.*'))-before_records
assert_ok('explicit promotion publishes the same prerelease once',proc.returncode==0
          and json.loads((case/'remote.json').read_text())['draft'] is False
          and json.loads((case/'remote.json').read_text())['prerelease'] is True
          and sum('--post' in r for r in requests)==1 and sum('--method' in r for r in requests)==1)
assert_ok('promotion preserves original draft receipt bytes and inode',original.read_bytes()==original_bytes
          and original.stat().st_ino==original_inode)
assert_ok('promotion creates a distinct success receipt',len(promoted)==1)
promoted=promoted.pop(); promoted_record=json.loads(promoted.read_text())
assert_ok('promotion receipt records explicit public authorization',promoted_record['status']=='success'
          and promoted_record['requested_draft'] is True and promoted_record['publication_requested'] is True
          and promoted_record['resumed_from']==str(original)
          and promoted_record['resumed_receipt_sha256']==hashlib.sha256(original_bytes).hexdigest())
prior_requests=len(requests); promoted_bytes=promoted.read_bytes()
proc,requests=invoke(case,flags+['--resume-receipt',str(promoted)])
assert_ok('completed public receipt resumes read-only',proc.returncode==0
          and not any('--post' in r or '--method' in r for r in requests[prior_requests:])
          and promoted.read_bytes()==promoted_bytes)

# Kill the real command process after the HTTP fixture has accepted draft=false.
# No graceful exit or fabricated successful command result can satisfy recovery.
case,repo,config=setup('publication-controller-killed',{'kill_after_publish':True})
first,requests=invoke(case)
assert_ok('controller is genuinely killed after accepted publication',first.returncode==-signal.SIGKILL
          and json.loads((case/'remote.json').read_text())['draft'] is False)
pending=next((case/'state'/'source-only').glob('*.json.*'))
pending_bytes=pending.read_bytes(); pending_inode=pending.stat().st_ino
pending_record=json.loads(pending_bytes)
assert_ok('publication crash retains an ID-bound authorized checkpoint',pending_record['status']=='pending'
          and pending_record['release_id']==9 and pending_record['git_sha']==(case/'sha').read_text().strip()
          and pending_record['tag']=='v1.2.3' and pending_record['asset_count']==0
          and pending_record['publication_requested'] is True)
assert_ok('recovery receipt path is exposed before publication',str(pending) in first.stderr)
(case/'control.json').write_text('{}')
prior_requests=len(requests)
proc,requests=invoke(case,['--notes-file',str(case/'notes.md'),'--no-dispatch','--resume-receipt',str(pending)])
assert_ok('public crash recovery succeeds without another mutation',proc.returncode==0
          and not any('--post' in r or '--method' in r for r in requests[prior_requests:]))
assert_ok('public crash recovery preserves pending custody',pending.read_bytes()==pending_bytes
          and pending.stat().st_ino==pending_inode)
recovered=[p for p in (case/'state'/'source-only').glob('*.json.*') if p!=pending]
assert_ok('public crash recovery produces linked terminal evidence',len(recovered)==1
          and json.loads(recovered[0].read_text())['status']=='success'
          and json.loads(recovered[0].read_text())['release_id']==9
          and json.loads(recovered[0].read_text())['resumed_receipt_sha256']==hashlib.sha256(pending_bytes).hexdigest())
prior_requests=len(requests); before_records=set((case/'state'/'source-only').glob('*.json.*'))
proc,requests=invoke(case,['--notes-file',str(case/'notes.md'),'--no-dispatch','--resume-receipt',str(pending)],dry=True)
assert_ok('public recovery dry-run performs no mutation or receipt write',proc.returncode==0
          and set((case/'state'/'source-only').glob('*.json.*'))==before_records
          and not any('--post' in r or '--method' in r for r in requests[prior_requests:]))
prior_requests=len(requests)
proc,requests=invoke(case,['--notes-file',str(case/'notes.md'),'--no-dispatch','--resume-receipt',str(pending),'--draft'])
assert_ok('public recovery refuses a contradictory draft request',proc.returncode in (4,7)
          and not any('--post' in r or '--method' in r for r in requests[prior_requests:]))

case,repo,config=setup('public-recovery-checkpoint-killed')
flags=['--notes-file',str(case/'notes.md'),'--no-dispatch']
first,requests=invoke(case,flags)
assert_ok('retry checkpoint starts from verified public custody',first.returncode==0)
original=next((case/'state'/'source-only').glob('*.json.*'));original_bytes=original.read_bytes()
(case/'control.json').write_text(json.dumps({'kill_after_retry_checkpoint':True}))
first,requests=invoke(case,flags+['--resume-receipt',str(original)])
pending=next(p for p in (case/'state'/'source-only').glob('*.json.*') if p!=original)
assert_ok('retry controller is killed after its first advertised checkpoint',first.returncode==-signal.SIGKILL
          and str(pending) in first.stderr and json.loads(pending.read_text())['status']=='pending')
assert_ok('first retry checkpoint already retains the held release ID',json.loads(pending.read_text())['release_id']==9
          and json.loads(pending.read_text())['git_sha']==(case/'sha').read_text().strip()
          and original.read_bytes()==original_bytes)
(case/'control.json').write_text('{}');prior_requests=len(requests)
proc,requests=invoke(case,flags+['--resume-receipt',str(pending)])
assert_ok('first retry checkpoint independently recovers without mutation',proc.returncode==0
          and not any('--post' in r or '--method' in r for r in requests[prior_requests:]))

case,repo,config=setup('rejected-draft-promotion')
flags=['--notes-file',str(case/'notes.md'),'--no-dispatch']
first,requests=invoke(case,flags+['--draft'])
assert_ok('rejected promotion starts with an owned completed draft',first.returncode==0)
original=next((case/'state'/'source-only').glob('*.json.*')); original_bytes=original.read_bytes()
(case/'control.json').write_text(json.dumps({'reject_publish':True}))
proc,requests=invoke(case,flags+['--resume-receipt',str(original),'--publish-draft'])
pending=next(p for p in (case/'state'/'source-only').glob('*.json.*') if p!=original)
assert_ok('failed promotion retains its explicit authorization',proc.returncode==7
          and json.loads((case/'remote.json').read_text())['draft'] is True
          and json.loads(pending.read_text())['status']=='pending'
          and json.loads(pending.read_text())['publication_requested'] is True)
(case/'control.json').write_text('{}')
proc,requests=invoke(case,flags+['--resume-receipt',str(pending)])
assert_ok('plain retry completes the already authorized promotion',proc.returncode==0
          and json.loads((case/'remote.json').read_text())['draft'] is False
          and sum('--post' in r for r in requests)==1 and original.read_bytes()==original_bytes)

case,repo,config=setup('legacy-public-without-id',{'omit_created':True})
first,requests=invoke(case)
pending=next((case/'state'/'source-only').glob('*.json.*')); pending_bytes=pending.read_bytes()
assert_ok('unobserved legacy checkpoint has no release ID',first.returncode==7
          and 'release_id' not in json.loads(pending_bytes))
remote=json.loads((case/'remote.json').read_text());remote['draft']=False
(case/'remote.json').write_text(json.dumps(remote));(case/'control.json').write_text('{}')
prior_requests=len(requests)
proc,requests=invoke(case,['--notes-file',str(case/'notes.md'),'--no-dispatch','--resume-receipt',str(pending)])
assert_ok('unbound pending receipt cannot adopt a public same-tag release',proc.returncode==7
          and pending.read_bytes()==pending_bytes
          and not any('--post' in r or '--method' in r for r in requests[prior_requests:]))

for label in ('changed-id','changed-body','changed-nonce','changed-notes','hidden-assets',
              'changed-saved-id','changed-saved-source','late-tag-drift'):
    case,repo,config=setup('public-resume-'+label)
    first,requests=invoke(case)
    assert_ok(label+' starts with verified public custody',first.returncode==0)
    receipt=next((case/'state'/'source-only').glob('*.json.*'))
    remote=json.loads((case/'remote.json').read_text());saved=json.loads(receipt.read_text());control={}
    if label=='changed-id':remote['id']=10
    if label=='changed-body':remote['body']='unrelated publisher metadata'
    if label=='changed-nonce':
        nonce=remote['body'].split('dsr-source-only-create:',1)[1].split(' -->',1)[0]
        remote['body']=remote['body'].replace(nonce,('0' if nonce[0]!='0' else '1')+nonce[1:])
    if label=='changed-notes':(case/'notes.md').write_text('different reviewed notes')
    if label=='hidden-assets':control['hidden_asset']=True
    if label=='changed-saved-id':saved['release_id']=10
    if label=='changed-saved-source':saved['git_sha']='f'*40
    if label=='late-tag-drift':control['move_tag_after_observations']=3
    (case/'remote.json').write_text(json.dumps(remote));receipt.write_text(json.dumps(saved))
    (case/'control.json').write_text(json.dumps(control));before=receipt.read_bytes();prior_requests=len(requests)
    proc,requests=invoke(case,['--notes-file',str(case/'notes.md'),'--no-dispatch','--resume-receipt',str(receipt)])
    assert_ok(label+' refuses without recreating or unpublishing',proc.returncode in (4,7)
              and not any('--post' in r or '--method' in r for r in requests[prior_requests:])
              and json.loads((case/'remote.json').read_text())['draft'] is False
              and receipt.read_bytes()==before)

for label,extra in [('without-receipt',['--publish-draft']),
                    ('with-draft',['--publish-draft','--draft','--resume-receipt','/missing/receipt'])]:
    case,repo,config=setup('invalid-promotion-'+label)
    proc,requests=invoke(case,['--notes-file',str(case/'notes.md'),'--no-dispatch']+extra)
    assert_ok('promotion '+label+' is rejected before GitHub reads',proc.returncode==4 and requests==[])

# Execute the unchanged embedded writer with a controlled os.replace boundary.
# Both the bytes and inode attacks occur after its pre-replace observations.
# A private file with different content must never become accepted custody.
writer_function=re.search(r'^_source_release_save_receipt\(\) \{\n.*?^\}',source,re.M|re.S).group(0)
writer_code=writer_function.split("python3 -I -c '\n",1)[1].split("\n' \"$file\"",1)[0]
writer_runner=r'''
import os,sys
code,path,fault=sys.argv[1:]
replace=os.replace
def drift(source,destination,**options):
    directory=options['src_dir_fd']
    if fault=='inode':
        replace(source,source+'.retained',src_dir_fd=directory,dst_dir_fd=directory)
        flags=os.O_WRONLY|os.O_CREAT|os.O_EXCL
    else:
        flags=os.O_WRONLY|os.O_TRUNC
    descriptor=os.open(source,flags|os.O_NOFOLLOW,0o600,dir_fd=directory)
    with os.fdopen(descriptor,'wb') as stream:
        stream.write(b'{"status":"foreign"}\n');stream.flush();os.fsync(stream.fileno())
    return replace(source,destination,**options)
if fault!='none':os.replace=drift
sys.argv=['source-only-writer',path,os.path.dirname(path),'null']
exec(compile(code,'dsr:_source_release_save_receipt','exec'))
'''
for fault in ('none','bytes','inode'):
    directory=work/('atomic-writer-'+fault);directory.mkdir()
    receipt=directory/'app-v1.2.3.json.ABCDEF12';receipt.touch(mode=0o600)
    data=b'{"publication_mode":"source-only","status":"pending"}\n'
    proc=subprocess.run([sys.executable,'-I','-c',writer_runner,writer_code,str(receipt),fault],
                        input=data,capture_output=True,timeout=30)
    if fault=='none':
        assert_ok('atomic writer returns proof for its exact durable bytes',proc.returncode==0
                  and receipt.read_bytes()==data
                  and json.loads(proc.stdout)['sha256']==hashlib.sha256(data).hexdigest())
    else:
        assert_ok('atomic writer refuses '+fault+' replacement drift',proc.returncode!=0
                  and not proc.stdout and json.loads(receipt.read_text())['status']=='foreign')

help_run=subprocess.run(['bash',str(root/'dsr'),'release','source-only','--help'],capture_output=True,text=True,timeout=60)
assert_ok('real CLI dispatch reaches source-only help',help_run.returncode==0 and 'exactly zero assets' in help_run.stdout)
reject_run=subprocess.run(['bash',str(root/'dsr'),'--json','--dry-run','release','source-only','app','1.2.3','--dispatch'],capture_output=True,text=True,timeout=60)
assert_ok('real CLI global flags preserve dispatch refusal',reject_run.returncode==4)
# Exercise real main/global option parsing and every production module. Only
# the copied GitHub HTTP boundary is replaced; source-only logic is unchanged.
cli=work/'cli'; (cli/'src').mkdir(parents=True)
shutil.copyfile(root/'dsr',cli/'dsr')
for module in (root/'src').glob('*.sh'): shutil.copyfile(module,cli/'src'/module.name)
with (cli/'src'/'github.sh').open('a') as f:
    f.write('\ngh_check() { return 0; }\ngh_check_token() { return 0; }\ngh_api() { python3 "$CASE/api.py" "$@"; }\n')
case,repo,config=setup('real-cli-dry-run')
env=dict(os.environ,CASE=str(case),DSR_CONFIG_DIR=str(case),DSR_STATE_DIR=str(case/'state'),NO_COLOR='1')
real_cli=subprocess.run(['bash',str(cli/'dsr'),'--json','--dry-run','release','source-only','app','1.2.3','--notes-file',str(case/'notes.md'),'--no-dispatch'],env=env,capture_output=True,text=True,timeout=60)
(case/'cli.stdout').write_text(real_cli.stdout); (case/'cli.stderr').write_text(real_cli.stderr)
assert_ok('real CLI global dry-run admission',real_cli.returncode==0)
envelope=json.loads(real_cli.stdout)
assert_ok('real CLI JSON source-only result',envelope['status']=='success' and envelope['command']=='release source-only')
requests=[json.loads(l) for l in (case/'requests.jsonl').read_text().splitlines()]
assert_ok('real CLI dry-run no API mutation/source receipt',not any('--post' in r or '--method' in r for r in requests) and not (case/'state'/'source-only').exists())
real_args=['bash',str(cli/'dsr'),'--json','release','source-only','app','1.2.3',
           '--notes-file',str(case/'notes.md'),'--no-dispatch']
real_cli=subprocess.run(real_args+['--draft'],env=env,capture_output=True,text=True,timeout=60)
assert_ok('real CLI retains a recoverable draft',real_cli.returncode==0)
envelope=json.loads(real_cli.stdout);receipt=Path(envelope['details']['receipt']);before=receipt.read_bytes()
assert_ok('real CLI JSON exposes its exact private receipt',receipt.is_file()
          and envelope['details']['draft'] is True and receipt.stat().st_mode&0o777==0o600)
real_cli=subprocess.run(real_args+['--resume-receipt',str(receipt),'--publish-draft'],
                        env=env,capture_output=True,text=True,timeout=60)
assert_ok('real CLI routes explicit source-only promotion',real_cli.returncode==0)
envelope=json.loads(real_cli.stdout)
assert_ok('real CLI promotion returns its new terminal receipt',envelope['details']['draft'] is False
          and envelope['details']['release_id']==9 and Path(envelope['details']['receipt']).is_file()
          and envelope['details']['receipt']!=str(receipt) and receipt.read_bytes()==before)
print(json.dumps({'passed':True,'checks':checks,'fixtures':str(work)}),flush=True)
PY
