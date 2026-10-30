#!/usr/bin/env bash
# Real checksum auditor and complete sync module; real local Git clone/commit/push.
# Only GitHub HTTP/auth and issue creation are file-backed transport fixtures.
# Git URL mappings keep all writes in new, retained, test-owned repositories.
# DSR_TEST_SYNC_MODULE selects the unchanged incumbent for before/after runs.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
exec python3 -I -S - "$ROOT" <<'PY'
import hashlib, json, os, pathlib, shutil, signal, subprocess, sys, tempfile, time
P = pathlib.Path
root = P(sys.argv[1])
work = P(tempfile.mkdtemp(prefix='dsr-sync-freshness-')).resolve()
print('Sync regression evidence retained: ' + str(work), flush=True)
program = work/'program/src'
program.mkdir(parents=True)
for name in ('checksum_sync.sh', 'release_checksums.sh', 'secrets.sh'):
    source = P(os.environ.get('DSR_TEST_SYNC_MODULE', str(root/'src'/name))) if name=='checksum_sync.sh' else root/'src'/name
    shutil.copy2(source, program/name)
passed = failed = 0

def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print('ok - '+label, flush=True)
    else:
        failed += 1
        print('not ok - '+label, flush=True)

def write(path, data):
    path.write_text(json.dumps(data, sort_keys=True)+'\n')

def run_git(args, env):
    result = subprocess.run(['git', *map(str,args)], env=env, capture_output=True, timeout=20)
    if result.returncode:
        raise AssertionError(result.stderr.decode())
    return result.stdout.decode().strip()

bin_dir=work/'bin'; bin_dir.mkdir()
(bin_dir/'curl').write_text(r'''#!/usr/bin/env -S python3 -I -S
import json, os, pathlib, sys, time
from urllib.parse import urlsplit, parse_qs
args=sys.argv[1:]
if args==['--disable','--version']:
    print('curl 8.10.1 (explicit HTTP/auth fixture)'); sys.exit(0)
case=pathlib.Path(os.environ['SYNC_CASE']); mode=os.environ.get('SYNC_MODE','')
url=urlsplit(args[-1]); assert url.scheme=='https' and url.netloc=='api.github.com'
assert '--fail' in args and '--location-trusted' not in args and args[0]=='--disable'
assert args[args.index('--proto')+1]=='=https' and args[args.index('--proto-redir')+1]=='=https'
assert '--max-time' in args and '--max-filesize' in args
assert args[args.index('--request')+1]=='GET'
assert 'Authorization: Bearer fixture-token' in sys.stdin.read()
assert 'fixture-token' not in ' '.join(args)
with (case/'requests.jsonl').open('a') as out: out.write(json.dumps({'path':url.path,'query':url.query})+'\n')
if (case/'audit-ended').exists() and mode in ('network','cancel'):
    if mode=='network': sys.exit(22)
    (case/'worker.pid').write_text(str(os.getpid())); time.sleep(60)
release=json.loads((case/'release.json').read_text()); assets=json.loads((case/'assets.json').read_text())
if '/releases/tags/' in url.path:
    body=json.dumps(release).encode()
elif url.path.endswith('/assets'):
    page=int(parse_qs(url.query)['page'][0]); body=json.dumps(assets[(page-1)*100:page*100]).encode()
else:
    assert '/releases/assets/' in url.path
    body=(case/'bytes'/url.path.rsplit('/',1)[1]).read_bytes()
assert len(body)<=int(args[args.index('--max-filesize')+1])
pathlib.Path(args[args.index('--output')+1]).write_bytes(body)
if '/releases/tags/' in url.path:
    requests=[json.loads(x) for x in (case/'requests.jsonl').read_text().splitlines()]
    if sum('/releases/tags/' in x['path'] for x in requests)==2:
        (case/'audit-ended').touch()
        if os.environ.get('SYNC_PHASE')=='after-audit':
            import subprocess
            subprocess.run([sys.executable, str(case/'mutate.py')], check=True)
''')
(bin_dir/'gh').write_text(r'''#!/usr/bin/env -S python3 -I -S
import json,os,pathlib,subprocess,sys
case=pathlib.Path(os.environ['SYNC_CASE'])
assert sys.argv[1:3]==['issue','create']
with (case/'issues.jsonl').open('a') as out: out.write(json.dumps(sys.argv[1:])+'\n')
if os.environ.get('SYNC_PHASE')=='after-issue': subprocess.run([sys.executable,str(case/'mutate.py')],check=True)
print('https://github.com/owner/a/issues/1')
''')
for p in bin_dir.iterdir(): p.chmod(0o755)

counter=0

def new_case(label, mode='', phase=''):
    global counter
    counter+=1
    case=work/('%02d-'%counter+label); case.mkdir()
    for path in ('bytes','tmp','home','hooks','remotes'): (case/path).mkdir()
    env={k:v for k,v in os.environ.items() if not k.startswith(('GIT_','BASH_FUNC_')) and k not in ('BASH_ENV','ENV','DSR_GH_TOKEN','GITHUB_TOKEN','GH_TOKEN')}
    env.update(HOME=str(case/'home'),TMPDIR=str(case/'tmp'),GIT_CONFIG_GLOBAL=str(case/'gitconfig'),GIT_CONFIG_NOSYSTEM='1',
               PATH=str(bin_dir)+os.pathsep+'/usr/bin:/bin:'+os.environ['PATH'],SYNC_CASE=str(case),SYNC_MODE=mode,SYNC_PHASE=phase,
               DSR_GH_TOKEN='fixture-token',DSR_STATE_DIR=str(case/'state'))
    (case/'gitconfig').write_text('[user]\n name = Checksum Test\n email = test@example.invalid\n[commit]\n gpgsign = false\n')
    heads={}
    for name in ('a','b'):
        seed=case/('seed-'+name)
        run_git(['init','-b','main',seed],env)
        (seed/'README').write_text('preserve this input\n')
        (seed/'SHA256SUMS.txt').write_text('original retained destination\n')
        run_git(['-C',seed,'add','.'],env); run_git(['-C',seed,'commit','-m','fixture initial'],env)
        run_git(['clone','--bare',seed,case/'remotes'/(name+'.git')],env)
        heads[name]=run_git(['--git-dir',case/'remotes'/(name+'.git'),'rev-parse','main'],env)
    with (case/'gitconfig').open('a') as out:
        out.write('[url "'+(case/'remotes').as_uri()+'/"]\n insteadOf = https://github.com/owner/\n')
        out.write('[core]\n hooksPath = '+str(case/'hooks')+'\n')
    assets=[]
    for i in range(4):
        name='tool-%d.tar.gz'%i; data=('genuine local payload %d\n'%i).encode()*500
        for n,b in ((name,data),(name+'.sha256',hashlib.sha256(data).hexdigest().encode()+b'\n')):
            identity=len(assets)+1; (case/'bytes'/str(identity)).write_bytes(b)
            assets.append(dict(id=identity,name=n,size=len(b),state='uploaded',digest='sha256:'+hashlib.sha256(b).hexdigest()))
    assets.append(dict(id=100,name='release.minisig',size=1,state='uploaded',digest=None))
    write(case/'assets.json',assets)
    write(case/'release.json',dict(id=42,tag_name='v1.2.3',draft=False,prerelease=False,target_commitish='main'))
    (case/'requests.jsonl').touch(); (case/'issues.jsonl').touch(); (case/'hooks.jsonl').touch()
    (case/'mutate.py').write_text(r'''
import json,os,pathlib
case=pathlib.Path(os.environ['SYNC_CASE']); mode=os.environ.get('SYNC_MODE','')
if (case/'mutated').exists(): raise SystemExit(0)
(case/'mutated').touch()
if mode.startswith('local-'):
    folder=next((case/'tmp').glob('dsr-checksum-sync.*'))
    chosen={'local-receipt':'audit-result.json','local-export':'manifest','local-proof':'audit/evidence/tool-0.tar.gz.sha256',
            'local-staged':str(next((folder/'target-1').glob('.dsr-checksum-update.*/manifest')).relative_to(folder)) if mode=='local-staged' else ''}[mode]
    with (folder/chosen).open('a') as out: out.write(' ')
else:
    p=case/('release.json' if mode=='release-mode' else 'assets.json'); data=json.loads(p.read_text())
    if mode=='release-mode': data['draft']=True
    elif mode=='signature-id': data[-1]['id']+=1000
    elif mode=='sidecar-id': data[1]['id']+=1000
    elif mode=='digest': data[0]['digest']='sha256:'+'0'*64
    elif mode=='size': data[0]['size']+=1
    else: data[0]['id']+=1000
    p.write_text(json.dumps(data)+'\n')
''')
    for event in ('post-checkout','pre-commit','post-commit','post-receive'):
        p=case/'hooks'/event
        p.write_text('#!/usr/bin/env -S python3 -I -S\n'+r'''
import json,os,pathlib,subprocess,sys
case=pathlib.Path(os.environ['SYNC_CASE']); event=pathlib.Path(__file__).name
with (case/'hooks.jsonl').open('a') as out: out.write(json.dumps({'event':event,'cwd':os.getcwd()})+'\n')
if os.environ.get('SYNC_PHASE')==event:
    subprocess.run([sys.executable,str(case/'mutate.py')],check=True)
'''); p.chmod(0o755)
    return case,env,heads

def invoke(case,env,flags=('--push',), audit=True):
    command=['bash',str(program/'checksum_sync.sh'),'sync','tool','1.2.3','--repo','owner/tool',
             '--target-repo','owner/a','--target-repo','owner/b','--json',*flags]
    if audit: command+=['--verify-release','--checksum-mode','sidecars']
    else: command+=['--manifest',str(case/'input-manifest')]
    proc=subprocess.run(command,env=env,capture_output=True,timeout=80)
    (case/'stdout').write_bytes(proc.stdout); (case/'stderr').write_bytes(proc.stderr)
    try: result=json.loads(proc.stdout)
    except ValueError: result={}
    return proc,result

def remote_heads(case,env):
    return {name:run_git(['--git-dir',case/'remotes'/(name+'.git'),'rev-parse','main'],env) for name in ('a','b')}

def request_rows(case): return [json.loads(x) for x in (case/'requests.jsonl').read_text().splitlines()]
def payload_requests(case): return sum('/releases/assets/' in x['path'] for x in request_rows(case))
def sync_folder(case): return next((case/'tmp').glob('dsr-checksum-sync.*'),None)

case,env,heads=new_case('unchanged')
proc,result=invoke(case,env)
check('real two-repository audited clone/commit/push succeeds',proc.returncode==0 and result.get('synced')==2 and all(remote_heads(case,env)[k]!=heads[k] for k in heads))
check('result retains complete audit and fresh inventory evidence',result.get('release_freshness',{}).get('status')=='unchanged' and result.get('release_freshness',{}).get('inventory_stable') is True)
check('both actual remote checksum files equal the audited export',all(run_git(['--git-dir',case/'remotes'/(n+'.git'),'show','main:SHA256SUMS.txt'],env)==(sync_folder(case)/'manifest').read_text().strip() for n in ('a','b')))
checks=result.get('release_freshness',{}).get('checks',[])
check('write, commit and push boundaries are each guarded for both targets',all(sum(x.get('phase')==p for x in checks)==2 for p in ('before-target','before-write','before-commit','before-push','after-target')))
check('freshness never reacquires payloads or proof assets',payload_requests(case)==8)
check('every boundary receipt names its selected destination',all(x.get('destination') in ('owner/a','owner/b') for x in checks) and len(checks)==10)

for mode in ('payload-id','sidecar-id','signature-id','digest','size','release-mode','network'):
    case,env,heads=new_case('late-'+mode,mode,'after-audit' if mode!='network' else '')
    proc,result=invoke(case,env)
    check(mode+' after the audit blocks every downstream write',proc.returncode!=0 and remote_heads(case,env)==heads and not (sync_folder(case)/'target-1').exists())
    check(mode+' cannot report fresh release success',result.get('exit_code')==proc.returncode and result.get('release_freshness',{}).get('inventory_stable') is False)
    if mode=='network': check('freshness transport failure retains the network exit code',proc.returncode==8)

for phase in ('post-checkout','pre-commit','post-commit','post-receive'):
    case,env,heads=new_case('git-'+phase,'payload-id',phase)
    proc,result=invoke(case,env)
    current=remote_heads(case,env); folder=sync_folder(case)
    check('release drift at real Git '+phase+' stops later destinations',proc.returncode!=0 and current['b']==heads['b'] and not (folder/'target-2').exists())
    check('release drift at '+phase+' gives truthful freshness JSON',result.get('exit_code')==proc.returncode and result.get('release_freshness',{}).get('inventory_stable') is False)
    if phase=='post-checkout':
        check('clone-time drift leaves the actual target file and local HEAD unchanged',(folder/'target-1/SHA256SUMS.txt').read_text()=='original retained destination\n' and run_git(['-C',folder/'target-1','rev-parse','HEAD'],env)==heads['a'])
    elif phase in ('pre-commit','post-commit'):
        row=(result.get('results') or [{}])[0]
        check('completed local commit survives '+phase+' without being pushed',current==heads and row.get('committed') is True and row.get('pushed') is False and row.get('commit')==run_git(['-C',folder/'target-1','rev-parse','HEAD'],env) and row.get('blocked_phase')=='before-push')
        check('unpublished local commit is reported as partial work',result.get('status')=='partial')
    else:
        row=(result.get('results') or [{}])[0]
        check('post-push drift preserves and reports the already completed remote write',current['a']!=heads['a'] and row.get('pushed') is True and result.get('status')=='partial' and result.get('synced')==1)
        check('post-push freshness failure cannot inherit the helper success exit code',
              row.get('status')=='error' and row.get('exit_code')==proc.returncode and proc.returncode!=0)

for mode in ('local-receipt','local-export','local-proof'):
    case,env,heads=new_case(mode,mode,'post-checkout')
    proc,result=invoke(case,env)
    check(mode+' mutation cannot reach commit or push',proc.returncode!=0 and remote_heads(case,env)==heads and not (sync_folder(case)/'target-2').exists())
    check(mode+' failure still produces exactly one nonzero JSON result',result.get('exit_code')==proc.returncode and result.get('release_freshness',{}).get('inventory_stable') is False)

case,env,heads=new_case('local-staged','local-staged','post-commit')
proc,result=invoke(case,env)
check('the exact staged checksum export is pinned, not just its original source path',proc.returncode!=0 and remote_heads(case,env)==heads and (result.get('results') or [{}])[0].get('blocked_phase')=='before-push')

case,env,heads=new_case('dry-run')
proc,result=invoke(case,env,('--dry-run',))
check('audited dry-run stays read-only while verifying freshness',proc.returncode==0 and result.get('planned')==2 and remote_heads(case,env)==heads and not (sync_folder(case)/'target-1').exists() and result.get('release_freshness',{}).get('inventory_stable') is True)
case,env,heads=new_case('local-commit-only')
proc,result=invoke(case,env,())
check('without --push guarded commits remain local',proc.returncode==0 and result.get('synced')==2 and remote_heads(case,env)==heads and all(x.get('committed') is True and x.get('pushed') is False for x in result.get('results',[])))
case,env,heads=new_case('issue-drift','payload-id','after-issue')
proc,result=invoke(case,env,('--open-issue',))
check('post-issue drift stops the next issue and retains the accepted receipt',proc.returncode!=0 and result.get('issues_opened')==1 and len((case/'issues.jsonl').read_text().splitlines())==1 and result.get('status')=='partial' and (result.get('results') or [{}])[0].get('issue_url')=='https://github.com/owner/a/issues/1')
case,env,heads=new_case('unaudited')
(case/'input-manifest').write_text(hashlib.sha256(b'fixture').hexdigest()+'  tool.tar.gz\n')
proc,result=invoke(case,env,audit=False)
check('explicit unaudited local-manifest sync preserves its existing behavior',proc.returncode==0 and result.get('synced')==2 and not request_rows(case) and result.get('release_freshness',{}).get('requested') is False)

case,env,heads=new_case('resume')
seed=case/'prior-audit'
seed_proc=subprocess.run(['bash',str(program/'release_checksums.sh'),'--repo','owner/tool','--tag','v1.2.3','--checksum-mode','sidecars','--output-dir',str(seed)],env=env,capture_output=True,timeout=30)
prior_pin=hashlib.sha256((seed/'result.json').read_bytes()).hexdigest()
before=payload_requests(case)
proc,result=invoke(case,env,('--push','--audit-resume-from',str(seed)))
check('resumed sync checks the new audit rather than passing the old resume source to freshness',seed_proc.returncode==0 and proc.returncode==0 and result.get('release_verification',{}).get('resume',{}).get('reused_count')==4 and payload_requests(case)-before==4 and hashlib.sha256((seed/'result.json').read_bytes()).hexdigest()==prior_pin)

# Actual Git rejection must not throw away the acknowledged local commit.
# Nonzero push status is conservatively unknown, not proof of remote rollback.
case,env,heads=new_case('rejected-push')
(case/'hooks/pre-receive').write_text('#!/bin/sh\n[ "${SYNC_REJECT_PUSH:-0}" != 1 ]\n')
(case/'hooks/pre-receive').chmod(0o755)
env['SYNC_REJECT_PUSH']='1'
proc,result=invoke(case,env)
row=(result.get('results') or [{}])[0]
folder=sync_folder(case)
held=run_git(['-C',folder/'target-1','rev-parse','HEAD'],env)
check('server-side rejection retains the exact completed local checksum commit',
      proc.returncode==8 and result.get('status')=='partial' and row.get('committed') is True and
      row.get('commit')==held and held!=heads['a'] and row.get('previous_commit')==heads['a'])
check('failed push distinguishes attempted but unacknowledged transport',
      row.get('push_attempted') is True and 'pushed' in row and row['pushed'] is None and
      row.get('push_outcome')=='uncertain' and row.get('push_exit_code',0)!=0 and row.get('failed_phase')=='push')
check('rejected first push leaves both remotes intact and later audited destinations untouched',
      remote_heads(case,env)==heads and not (folder/'target-2').exists())
env['SYNC_REJECT_PUSH']='0'
retry=subprocess.run(['bash','-c','source "$1"; _cs_update_repo_checksums "$2" "$(cat "$3")" --commit --push',
    '_',str(program/'checksum_sync.sh'),str(folder/'target-1'),str(folder/'manifest')],
    env=env,capture_output=True,timeout=30)
try: retry_row=json.loads(retry.stdout)
except ValueError: retry_row={}
check('explicit helper retry pushes the retained commit without creating another commit',
      retry.returncode==0 and retry_row.get('commit')==held and retry_row.get('committed') is False and
      retry_row.get('push_outcome')=='acknowledged' and retry_row.get('push_exit_code')==0 and
      remote_heads(case,env)['a']==held and run_git(['-C',folder/'target-1','rev-parse','HEAD'],env)==held)

case,env,heads=new_case('commit-rejected')
with (case/'hooks/pre-commit').open('a') as hook: hook.write('\nraise SystemExit(17)\n')
proc,result=invoke(case,env)
row=(result.get('results') or [{}])[0]
folder=sync_folder(case)
check('failed commit retains changed working file and reports partial work',
      proc.returncode==1 and row.get('changed') is True and result.get('status')=='partial' and
      (folder/'target-1/SHA256SUMS.txt').read_bytes()==(folder/'manifest').read_bytes() and
      remote_heads(case,env)==heads and run_git(['-C',folder/'target-1','rev-parse','HEAD'],env)==heads['a'])
check('unacknowledged commit is not misreported as a completed new or rolled-back commit',
      row.get('commit_attempted') is True and row.get('commit_outcome')=='uncertain' and
      row.get('commit_exit_code',0)!=0 and row.get('commit') is None and
      row.get('previous_commit')==heads['a'] and row.get('failed_phase')=='commit' and
      row.get('push_attempted') is False and row.get('pushed') is False)

# Execute an actual successful local Git push, then fault only its reported
# process status. This models lost acknowledgement, not a live Git protocol test.
case,env,heads=new_case('lost-push-ack')
fault_bin=case/'fault-bin';fault_bin.mkdir()
actual_git=shutil.which('git')
(fault_bin/'git').write_text('#!/usr/bin/env -S python3 -I -S\n'+
    'import subprocess,sys\nargs=sys.argv[1:]\n'+
    'code=subprocess.call(['+repr(actual_git)+',*args])\n'+
    'sys.exit(128 if "push" in args and code==0 else code)\n')
(fault_bin/'git').chmod(0o755)
env['PATH']=str(fault_bin)+os.pathsep+env['PATH']
proc,result=invoke(case,env)
row=(result.get('results') or [{}])[0]
current=remote_heads(case,env)
check('lost push acknowledgement is nonzero even after an actual successful remote update',
      proc.returncode==8 and current['a']!=heads['a'] and current['b']==heads['b'] and
      row.get('commit')==current['a'] and row.get('committed') is True and result.get('status')=='partial')
check('lost acknowledgement reports unknown rather than claiming push rejection or success',
      row.get('push_attempted') is True and 'pushed' in row and row['pushed'] is None and
      row.get('push_outcome')=='uncertain' and row.get('push_exit_code')==128 and
      not (sync_folder(case)/'target-2').exists())

case,env,heads=new_case('no-unselected-tags')
with (case/'gitconfig').open('a') as config: config.write('[push]\n followTags = true\n')
with (case/'hooks/post-commit').open('a') as hook:
    hook.write('\nsubprocess.run(["git","tag","-am","unselected tag","not-selected"],check=True)\n')
proc,result=invoke(case,env)
check('branch-only checksum pushes never inherit automatic annotated-tag publication',
      proc.returncode==0 and all(remote_heads(case,env)[name]!=heads[name] for name in heads) and
      all(not run_git(['--git-dir',case/'remotes'/(name+'.git'),'for-each-ref','--format=%(refname)','refs/tags'],env)
          for name in heads))

# A guard can race with another local writer. Use actual commits to prove the
# updater does not replace its checked commit by whatever HEAD becomes later.
case,env,heads=new_case('head-moved-during-guard')
checkout=case/'direct-checkout'
run_git(['clone','https://github.com/owner/a.git',checkout],env)
manifest=case/'input-manifest'
manifest.write_text(hashlib.sha256(b'payload').hexdigest()+'  tool.tar.gz\n')
script=r'''
source "$1" || exit $?
change_head() {
    [[ "$1" == before-push ]] || return 0
    printf 'unrelated writer\n' > "$repo_path/OTHER" || return 1
    git -C "$repo_path" add -- OTHER || return 1
    git -C "$repo_path" commit --only -m 'concurrent writer' -- OTHER >&2
}
_cs_update_repo_checksums "$2" "$(cat "$3")" --commit --push --release-guard change_head
'''
proc=subprocess.run(['bash','-c',script,'_',str(program/'checksum_sync.sh'),str(checkout),str(manifest)],
                    env=env,capture_output=True,timeout=30)
try: row=json.loads(proc.stdout)
except ValueError: row={}
check('changed HEAD at pre-push admission is refused without discarding either local commit',
      proc.returncode==2 and row.get('failed_phase')=='push-preflight' and row.get('push_attempted') is False and
      row.get('commit')==run_git(['-C',checkout,'rev-parse','HEAD^'],env) and remote_heads(case,env)==heads and
      (checkout/'OTHER').is_file())

case,env,heads=new_case('cancel','cancel')
command=['bash',str(program/'checksum_sync.sh'),'sync','tool','1.2.3','--repo','owner/tool','--target-repo','owner/a','--verify-release','--checksum-mode','sidecars','--push','--json']
proc=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
limit=time.monotonic()+15
while not (case/'worker.pid').exists() and proc.poll() is None and time.monotonic()<limit: time.sleep(.05)
had_worker=(case/'worker.pid').exists()
if proc.poll() is None: proc.send_signal(signal.SIGTERM)
try: out,err=proc.communicate(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill(); out,err=proc.communicate(); check('cancellation is bounded',False)
(case/'stdout').write_bytes(out); (case/'stderr').write_bytes(err)
try: result=json.loads(out)
except ValueError: result={}
worker_alive=False
if had_worker:
    pid=int((case/'worker.pid').read_text()); deadline=time.monotonic()+3
    while time.monotonic()<deadline:
        try:
            os.kill(pid,0)
            if P('/proc/%d/stat'%pid).exists() and P('/proc/%d/stat'%pid).read_text().split()[2]=='Z': break
        except ProcessLookupError: break
        time.sleep(.05)
    else: worker_alive=True
check('TERM to the public sync PID cancels the owned freshness transport',had_worker and proc.returncode==5 and not worker_alive and remote_heads(case,env)==heads)
check('cancelled sync retains non-success JSON instead of a stale green audit',result.get('exit_code')==5 and result.get('release_freshness',{}).get('inventory_stable') is False)
print('%d passed, %d failed; fixtures retained at %s'%(passed,failed,work),flush=True)
sys.exit(1 if failed else 0)
PY
