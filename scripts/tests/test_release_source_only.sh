#!/usr/bin/env bash
# Real Git/config/CLI admission and draft custody; only GitHub HTTP responses
# are fixtures. Actual publication must additionally have a public readback.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix='dsr-source-release-'))
source = (root / 'dsr').read_text()
names = ['_source_release_identity', '_source_release_metadata_matches',
         '_source_release_observe', '_source_release_restore_draft',
         '_source_release_inputs_match',
         'cmd_release_source_only', 'cmd_release',
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
    if control.get('scan_malformed'): print('{}')
    else: print(json.dumps([release] if release is not None else []))
elif endpoint.startswith('repos/owner/app/git/ref/tags/'):
    if control.get('config_moves'):
        path=case/'repos.d'/'app.yaml'; data=json.loads(path.read_text()); data['build_cmd']='cargo build --release'; path.write_text(json.dumps(data))
    if control.get('registry_appears'):
        (case/'repos.yaml').write_text(json.dumps({'tools':{'app':{'build_cmd':'cargo build --release'}}}))
    sha=(case/'sha').read_text().strip()
    if control.get('remote_tag_wrong') or (control.get('move_tag_after_publish') and release is not None and not release['draft']): sha='f'*40
    print(json.dumps({'object':{'type':'tag' if control.get('annotated_remote') else 'commit','sha':'a'*40 if control.get('annotated_remote') else sha}}))
elif endpoint=='repos/owner/app/git/tags/'+'a'*40:
    print(json.dumps({'object':{'type':'commit','sha':(case/'sha').read_text().strip()}}))
elif endpoint=='repos/owner/app/releases/9' and '--method' in args:
    data=json.loads(args[args.index('--data')+1]); release.update(data)
    if control.get('body_changes_after_publish') and data.get('draft') is False: release['body']='another worker changed body'
    release_file.write_text(json.dumps(release)); print(json.dumps(release))
    sys.exit(1 if control.get('lost_patch') else 0)
elif endpoint=='repos/owner/app/releases/9':
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
print(json.dumps({'passed':True,'checks':checks,'fixtures':str(work)}),flush=True)
PY
