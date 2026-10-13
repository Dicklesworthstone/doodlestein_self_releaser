#!/usr/bin/env bash
# Complete sync with real local Git and retained files. HTTP/auth is an explicit
# file-backed boundary; controlled receipt pauses exercise actual SIGKILL/leases.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
exec python3 -I -S - "$ROOT" "$@" <<'PY'
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
if sys.argv[2:] not in ([], ['--resume']):
    raise SystemExit('Usage: test_checksum_sync_plan.sh [--resume]')
test_resume = sys.argv[2:] == ['--resume']
module = Path(os.environ.get('DSR_TEST_SYNC_MODULE', str(root / 'src/checksum_sync.sh'))).resolve()
work = Path(tempfile.mkdtemp(prefix='dsr-sync-plan-')).resolve()
print('Sync plan evidence retained: ' + str(work), flush=True)
bins = work / 'bin'; bins.mkdir()
actual_git = shutil.which('git')
checks = failures = serial = 0

def check(label, condition):
    global checks, failures
    checks += 1; failures += not condition
    print(('ok ' if condition else 'not ok ') + str(checks) + ' - ' + label, flush=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def git(env, *args):
    p = subprocess.run([actual_git, *map(str, args)], env=env, capture_output=True, timeout=15)
    if p.returncode: raise AssertionError(p.stderr.decode())
    return p.stdout.decode().strip()

(bins / 'curl').write_text(r'''#!/usr/bin/env -S python3 -I -S
import hashlib,json,os,pathlib,sys,time
from urllib.parse import urlsplit
args=sys.argv[1:]
if args==['--disable','--version']:
    print('curl 8.10.1 (explicit HTTP fixture)'); raise SystemExit(0)
case=pathlib.Path(os.environ['CASE']); url=urlsplit(args[-1]); headers=sys.stdin.read()
assert url.netloc=='api.github.com' and '--fail' in args and 'fixture-token' in headers
with (case/'http.jsonl').open('a') as out: out.write(json.dumps({'path':url.path,'query':url.query})+'\n')
if (case/'hold-curl').exists():
    (case/'curl-paused').write_text(str(os.getpid()))
    time.sleep(120)
if '/releases/tags/' in url.path: body=(case/'release.json').read_bytes()
elif url.path.endswith('/assets'): body=(case/'assets.json').read_bytes()
else: body=(case/'bytes'/url.path.rsplit('/',1)[1]).read_bytes()
assert len(body)<=int(args[args.index('--max-filesize')+1])
pathlib.Path(args[args.index('--output')+1]).write_bytes(body)
''')
(bins / 'curl').chmod(0o755)

def setup(label):
    global serial
    serial += 1
    case = work / ('%02d-' % serial + label); case.mkdir()
    for name in ('home','tmp','bytes','remotes'): (case / name).mkdir()
    env = {k:v for k,v in os.environ.items() if not k.startswith(('GIT_', 'BASH_FUNC_')) and
           k not in ('ENV','BASH_ENV','GH_TOKEN','GITHUB_TOKEN','DSR_GH_TOKEN')}
    env.update(CASE=str(case), HOME=str(case/'home'), TMPDIR=str(case/'tmp'),
        PATH=str(bins)+os.pathsep+os.environ['PATH'], GIT_CONFIG_GLOBAL=str(case/'gitconfig'),
        GIT_CONFIG_NOSYSTEM='1', DSR_GH_TOKEN='fixture-token', DSR_STATE_DIR=str(case/'state'))
    (case/'gitconfig').write_text('[user]\n name = Plan Test\n email = plan@example.invalid\n[commit]\n gpgsign = false\n')
    seed = case/'seed'
    git(env,'init','-b','main',seed)
    (seed/'README').write_text('unchanged repository\n')
    git(env,'-C',seed,'add','.'); git(env,'-C',seed,'commit','-m','seed')
    for name in ('a','b'):
        git(env,'clone','--bare',seed,case/'remotes'/f'{name}.git')
        hook=case/'remotes'/f'{name}.git/hooks/post-receive'
        hook.write_text('#!/usr/bin/env bash\nprintf "accepted\\n" >> "$CASE/pushes-'+name+'.log"\n')
        hook.chmod(0o755)
    with (case/'gitconfig').open('a') as out:
        out.write('[url "'+(case/'remotes').as_uri()+'/\"]\n insteadOf = https://github.com/owner/\n')
    payload=b'actual owned payload\n'
    assets=[]
    for i,name,data in ((1,'tool.tar.gz',payload),(2,'tool.tar.gz.sha256',hashlib.sha256(payload).hexdigest().encode()+b'\n')):
        (case/'bytes'/str(i)).write_bytes(data)
        assets.append(dict(id=i,name=name,size=len(data),state='uploaded',digest='sha256:'+hashlib.sha256(data).hexdigest()))
    (case/'assets.json').write_text(json.dumps(assets))
    (case/'release.json').write_text(json.dumps(dict(id=42,tag_name='v1.2.3',draft=False,prerelease=False,target_commitish='main')))
    return case,env,git(env,'-C',seed,'rev-parse','HEAD')

def command(occupy='', pause='', push=True, dry=False):
    # Only the receipt boundary is paused, AFTER the actual publisher returns.
    # All production sync/audit/Git behavior and refusal predicates stay intact.
    program=r'''source "$1" || exit $?; module=$1; occupy=$2; pause=$3
_cs_retain_sync_json() {
    if [[ "$2" == "$occupy" ]]; then printf 'occupied\n' > "$1/$2"; fi
    if [[ "before:$2" == "$pause" ]]; then
        printf '%s\n' "$1" > "$CASE/paused"
        while [[ ! -f "$CASE/continue" ]]; do sleep .05; done
    fi
    bash -c 'source "$1" || exit $?; shift; _cs_retain_sync_json "$@"' _ "$module" "$@" || return $?
    if [[ "$2" == "$pause" ]]; then
        printf '%s\n' "$1" > "$CASE/paused"
        while [[ ! -f "$CASE/continue" ]]; do sleep .05; done
    fi
}
shift 3
checksum_sync tool 1.2.3 --repo owner/tool --verify-release --checksum-mode sidecars \
    --target-repo owner/a --target-repo owner/A --target-repo owner/b --json "$@"'''
    return ['bash','-c',program,'_',str(module),occupy,pause]+(['--push'] if push else [])+(['--dry-run'] if dry else [])

def complete(case,env,**kw):
    previous=set((case/'tmp').glob('dsr-checksum-sync.*'))
    p=subprocess.run(command(**kw),env=env,capture_output=True,timeout=75)
    log='sync-%03d' % len(previous)
    (case/(log+'.stdout')).write_bytes(p.stdout); (case/(log+'.stderr')).write_bytes(p.stderr)
    created=set((case/'tmp').glob('dsr-checksum-sync.*'))-previous
    if len(created)!=1: raise AssertionError('sync did not create exactly one new workspace')
    return p,json.loads(p.stdout),created.pop()

def recover_plan(case,env,ws,options=(),pin=None):
    output=case/('recovery-%03d' % (len(list(case.glob('recovery-*'))) + 1))
    args=['bash',str(root/'src/checksum_sync.sh'),'recover','--plan',str(ws/'sync-plan.json'),
          '--plan-sha256',pin or digest(ws/'sync-plan.json'),'--output-dir',str(output),*options]
    p=subprocess.run(args,env=env,capture_output=True,timeout=90)
    log=case/('recovery-log-%03d.json' % len(list(case.glob('recovery-log-*'))))
    log.write_text(json.dumps(dict(code=p.returncode,stdout=p.stdout.decode(),stderr=p.stderr.decode())))
    value=json.loads(p.stdout)
    if value.get('output_dir'):
        check('continuation result is retained byte-for-byte before its stdout acknowledgement',
              (Path(value['output_dir'])/'result.json').read_bytes()==p.stdout)
    return p,value

def pushes(case,name):
    path=case/('pushes-'+name+'.log')
    return len(path.read_text().splitlines()) if path.is_file() else 0

def inventory(ws):
    # Preserve every pre-existing byte. New locks/delegation may be created;
    # their addition must not rewrite original audit, checkout or receipts.
    return {str(p.relative_to(ws)):digest(p) for p in ws.rglob('*') if p.is_file() and not p.is_symlink()}

def still_original(ws,held):
    return all((ws/name).is_file() and digest(ws/name)==pin for name,pin in held.items())

case,env,before=setup('complete')
p,result,ws=complete(case,env)
plan_path=ws/'sync-plan.json'
plan=json.loads(plan_path.read_bytes()) if plan_path.is_file() else {}
check('complete audited sync persists the original ordered, case-deduplicated fan-out',
    p.returncode==0 and plan.get('targets')==['owner/a','owner/b'])
check('plan pins exact workspace, tool, source, tag, checksum destination and policy',
    plan.get('kind')=='dsr-checksum-sync-plan' and plan.get('schema_version')==1 and
    plan.get('workspace')==str(ws) and plan.get('tool')=='tool' and plan.get('repository')=='owner/tool' and
    plan.get('tag')=='v1.2.3' and plan.get('checksums_file')=='SHA256SUMS.txt' and
    plan.get('push') is True and plan.get('review') is False and plan.get('dry_run') is False)
check('audit and checksum content pins match actual complete retained evidence',
    plan.get('audit_sha256')==digest(ws/'audit/result.json') and plan.get('manifest_sha256')==digest(ws/'manifest'))
check('final result exposes the exact independently usable plan digest',
    plan_path.is_file() and result.get('sync_plan')==dict(path=str(plan_path),sha256=digest(plan_path)) and
    digest(plan_path).encode() in p.stderr)
check('both destinations record plan-bound intents and matching outcomes',
    plan_path.is_file() and all((ws/f'target-{i}.intent.json').is_file() and
        json.loads((ws/f'target-{i}.intent.json').read_bytes())==dict(kind='dsr-checksum-sync-target-intent',
            schema_version=1,plan_sha256=digest(plan_path),index=i,repo=row['repo']) and
        row.get('plan_sha256')==digest(plan_path) and row.get('index')==i and
        json.loads((ws/f'target-{i}.result.json').read_bytes())==row
        for i,row in enumerate(result['results'],1)))
check('plan and intent persistence do not alter genuine delivery',
    all(git(env,'--git-dir',case/'remotes'/f'{name}.git','rev-parse','main')==row['commit']
        for name,row in zip(('a','b'),result['results'])))

for name in ('sync-plan.json','target-1.intent.json'):
    case,env,before=setup('occupied-'+name)
    p,result,ws=complete(case,env,occupy=name)
    check('occupied '+name+' stops before any clone, commit or push',p.returncode!=0 and
        (ws/name).read_text()=='occupied\n' and not (ws/'target-1').exists() and not (ws/'target-2').exists() and
        all(git(env,'--git-dir',case/'remotes'/f'{n}.git','rev-parse','main')==before for n in ('a','b')))

case,env,before=setup('killed-after-first-receipt')
proc=subprocess.Popen(command(pause='target-1.result.json'),env=env,stdout=(case/'stdout').open('wb'),
    stderr=(case/'stderr').open('wb'),start_new_session=True)
for _ in range(1000):
    if (case/'paused').is_file() or proc.poll() is not None: break
    time.sleep(.02)
paused=(case/'paused').is_file()
check('real sync reaches the deliberate pause after its first acknowledged destination',paused)
if paused:
    ws=Path((case/'paused').read_text().strip())
    busy=False
    if (ws/'.sync.lock').is_file():
        with (ws/'.sync.lock').open('r') as lease:
            try: fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError: busy=True
    check('the whole-sync lease excludes a resumer while the original shell is alive',busy)
    if test_resume:
        refused,value=recover_plan(case,env,ws)
        check('public plan recovery refuses the actual live sync before output or remote effects',
              refused.returncode==2 and not value.get('output_dir') and pushes(case,'b')==0)
    os.killpg(proc.pid,signal.SIGKILL); proc.wait(timeout=10)
    check('SIGKILL leaves no invented terminal sync result',not (ws/'result.json').exists())
    check('completed target and never-attempted target remain distinguishable after SIGKILL',
        (ws/'sync-plan.json').is_file() and (ws/'target-1.intent.json').is_file() and
        (ws/'target-1.result.json').is_file() and not (ws/'target-2.intent.json').exists() and
        not (ws/'target-2.result.json').exists() and not (ws/'target-2').exists())
    free=False
    if (ws/'.sync.lock').is_file():
        with (ws/'.sync.lock').open('r') as lease:
            try: fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB); free=True
            except BlockingIOError: pass
    check('kernel releases the lease after owned processes terminate without deleting the lock',free)
    if test_resume:
        held=inventory(ws); pin=digest(ws/'sync-plan.json')
        rejected,value=recover_plan(case,env,ws,pin='0'*64)
        check('wrong independent plan digest is refused without resuming',rejected.returncode==4 and pushes(case,'b')==0)
        rejected,value=recover_plan(case,env,ws,options=['--push'])
        check('push requires explicit execution consent',rejected.returncode==4 and pushes(case,'b')==0)
        rejected,value=recover_plan(case,env,ws,options=['--execute'])
        check('execution cannot silently change the original selected push policy',rejected.returncode==4 and pushes(case,'b')==0)
        p,value=recover_plan(case,env,ws)
        check('check-only reconciles the first push and identifies untouched second destination',
              p.returncode==0 and value['status']=='ready' and value['remaining_targets']==['owner/b'] and
              value['original_terminal_outcome']=='unknown' and not value['delivery_confirmed'] and
              value['results'][0]['recovery']['status']=='already-applied' and pushes(case,'a')==1 and pushes(case,'b')==0)
        check('checkpoint selection never fabricates an original terminal result',
              not (ws/'result.json').exists() and json.loads((Path(value['output_dir'])/'selection.json').read_bytes())['exit_code'] is None)
        prior_downloads=sum('/releases/assets/1'==r['path'] for r in map(json.loads,(case/'http.jsonl').read_text().splitlines()))
        p,value=recover_plan(case,env,ws,options=['--execute','--push'])
        check('execute resumes only the untouched destination with one new actual push',
              p.returncode==0 and value['status']=='completed' and value['delivery_confirmed'] and
              pushes(case,'a')==1 and pushes(case,'b')==1 and not value['remaining_targets'])
        child_result=value.get('delegated_result',{})
        check('remaining sync reuses verified payload bytes instead of downloading them again',
              child_result.get('release_verification',{}).get('resume',{}).get('reused_count')==1 and
              sum('/releases/assets/1'==r['path'] for r in map(json.loads,(case/'http.jsonl').read_text().splitlines()))==prior_downloads)
        check('delegated sync has its own exact plan and only its remaining destination',
              child_result.get('sync_plan',{}).get('sha256')==digest(Path(child_result['workspace'])/'sync-plan.json') and
              [r['repo'] for r in child_result['results']]==['owner/b'])
        check('the original audit, checkout, plan and every checkpoint byte remain unchanged',still_original(ws,held))
        rejected,repeated=recover_plan(case,env,ws,options=['--execute','--push'])
        check('repeating the original plan cannot replay delegated work',rejected.returncode==2 and
              repeated.get('continuation',{}).get('output_dir')==value['output_dir'] and pushes(case,'a')==pushes(case,'b')==1)
        p,reconciled=recover_plan(case,env,Path(child_result['workspace']),options=['--execute','--push'])
        check('child plan reconciles its already-applied commit with no additional push',
              p.returncode==0 and reconciled['delivery_confirmed'] and pushes(case,'a')==pushes(case,'b')==1)
else:
    if proc.poll() is None: os.killpg(proc.pid,signal.SIGKILL); proc.wait(timeout=10)
    print((case/'stderr').read_text(),flush=True)

if test_resume:
    # Both targets have real acknowledged commits; the server rejects only
    # the second push. Recovery must deliver that SAME commit, not resync it.
    case,env,before=setup('rejected-second-push')
    reject=case/'remotes/b.git/hooks/pre-receive'
    reject.write_text('#!/usr/bin/env bash\nexit 1\n'); reject.chmod(0o755)
    p,initial,ws=complete(case,env)
    check('actual second-remote rejection retains its acknowledged local commit',p.returncode==8 and
          initial['results'][1]['committed'] is True and initial['results'][1]['push_outcome']=='uncertain')
    selected_commit=initial['results'][1]['commit']; held=inventory(ws)
    p,view=recover_plan(case,env,ws)
    check('whole-plan read-only reconciliation separates delivered and ready commits',p.returncode==0 and
          [r['recovery']['status'] for r in view['results']]==['already-applied','ready'] and
          view['remaining_targets']==[] and not view['delivery_confirmed'] and pushes(case,'b')==0)
    (case/'rejected-hook-original').write_bytes(reject.read_bytes())
    reject.write_text('#!/usr/bin/env bash\nexit 0\n')
    p,recovered=recover_plan(case,env,ws,options=['--execute','--push'])
    check('repair-and-recover pushes the retained SHA without another clone or commit',p.returncode==0 and
          recovered['delivery_confirmed'] and git(env,'--git-dir',case/'remotes/b.git','rev-parse','main')==selected_commit and
          pushes(case,'a')==pushes(case,'b')==1 and not (ws/'continuation.json').exists())
    check('rejected-push recovery preserves all original state and evidence',still_original(ws,held))
    p,repeated=recover_plan(case,env,ws,options=['--execute','--push'])
    check('repeating a fully acknowledged plan makes no second push',p.returncode==0 and
          repeated['delivery_confirmed'] and pushes(case,'a')==pushes(case,'b')==1)

    # Kill AFTER a genuine push but BEFORE the target completion receipt is
    # published. Missing completion is unknown, never safe-to-replay state.
    case,env,before=setup('lost-completion-after-push')
    proc=subprocess.Popen(command(pause='before:target-1.result.json'),env=env,
        stdout=(case/'stdout').open('wb'),stderr=(case/'stderr').open('wb'),start_new_session=True)
    for _ in range(1500):
        if (case/'paused').is_file() or proc.poll() is not None: break
        time.sleep(.02)
    if not (case/'paused').is_file():
        if proc.poll() is None: os.killpg(proc.pid,signal.SIGKILL); proc.wait(timeout=10)
        raise AssertionError('sync did not reach actual push/receipt boundary')
    ws=Path((case/'paused').read_text().strip())
    os.killpg(proc.pid,signal.SIGKILL); proc.wait(timeout=10)
    p,refused=recover_plan(case,env,ws,options=['--execute','--push'])
    check('a real accepted push without target completion is refused as uncertain, not replayed',
          p.returncode==2 and refused['uncertain_targets']==['owner/a'] and not (ws/'target-1.result.json').exists() and
          not (ws/'result.json').exists() and not (ws/'continuation.json').exists() and pushes(case,'a')==1 and pushes(case,'b')==0)

    # A second ordinary sync has unchanged checksums and creates no new commit.
    case,env,before=setup('unchanged-checksum-commit')
    _,first,_=complete(case,env)
    p,second,ws=complete(case,env)
    check('ordinary unchanged sync records no newly created commits',p.returncode==0 and
          all(r['committed'] is False and r['commit']==r['previous_commit'] for r in second['results']))
    count=(pushes(case,'a'),pushes(case,'b'))
    p,reconciled=recover_plan(case,env,ws,options=['--execute','--push'])
    check('unchanged checksum receipts reconcile read-only even under --execute --push',p.returncode==0 and
          reconciled['delivery_confirmed'] and all(r['recovery']['unchanged_checksum_commit'] and
          not r['recovery']['push_attempted'] for r in reconciled['results']) and (pushes(case,'a'),pushes(case,'b'))==count)

    case,env,before=setup('local-only-plan')
    p,local,ws=complete(case,env,push=False)
    p,refused=recover_plan(case,env,ws,options=['--execute','--push'])
    check('local-only plan cannot be escalated into push authorization',p.returncode==4 and pushes(case,'a')==pushes(case,'b')==0)
    p,observed=recover_plan(case,env,ws,options=['--execute'])
    check('local-only completed work stays complete without claiming remote delivery',p.returncode==0 and
          observed['status']=='completed-local' and observed['local_work_complete'] and not observed['delivery_confirmed'] and
          pushes(case,'a')==pushes(case,'b')==0)

    # Each refusal owns a fresh complete sync; save pre-fault bytes outside the
    # workspace before corrupting that test input. Nothing repairs originals
    # or deletes evidence to turn a failure into a positive control.
    for fault,expected in [('plan-duplicate',4),('plan-unknown-option',4),('terminal-corrupt',4),
                           ('target-mismatched',4),('missing-lease',7),('linked-lease',4),('hardlinked-lease',4),
                           ('delegation-corrupt',4),('payload-corrupt',7),
                           ('proof-corrupt',7),('release-drift',1),('remote-drift',2)]:
        case,env,before=setup(fault)
        _,original,ws=complete(case,env)
        pin=digest(ws/'sync-plan.json')
        if fault.startswith('plan-'):
            path=ws/'sync-plan.json'; (case/'before-fault').write_bytes(path.read_bytes())
            value=json.loads(path.read_bytes())
            if fault=='plan-duplicate': value['targets'].append('owner/A')
            else: value['audit_options'] += ['--resume-from','/not-authorized']
            path.write_text(json.dumps(value)); pin=digest(path)
        elif fault=='terminal-corrupt':
            path=ws/'result.json'; (case/'before-fault').write_bytes(path.read_bytes()); path.write_text('{broken')
        elif fault=='target-mismatched':
            path=ws/'target-1.result.json'; (case/'before-fault').write_bytes(path.read_bytes())
            value=json.loads(path.read_bytes()); value['index']=2; path.write_text(json.dumps(value))
        elif fault=='missing-lease':
            (ws/'.sync.lock').rename(case/'preserved-lease')
        elif fault=='linked-lease':
            (ws/'.sync.lock').rename(case/'preserved-lease'); (ws/'.sync.lock').symlink_to(case/'preserved-lease')
        elif fault=='hardlinked-lease':
            os.link(ws/'.sync.lock',case/'another-lease-name')
        elif fault=='delegation-corrupt':
            (ws/'continuation.json').write_text('{broken')
        elif fault in ('payload-corrupt','proof-corrupt'):
            path=(ws/'audit/artifacts/tool.tar.gz' if fault=='payload-corrupt' else ws/'audit/evidence/tool.tar.gz.sha256')
            (case/'before-fault').write_bytes(path.read_bytes()); path.write_bytes(b'corrupted owned fixture\n')
        elif fault=='release-drift':
            path=case/'assets.json'; (case/'before-fault').write_bytes(path.read_bytes())
            value=json.loads(path.read_bytes()); value[0]['id']=101; path.write_text(json.dumps(value))
        else:
            changed=case/'changed-remote'; git(env,'clone',case/'remotes/a.git',changed)
            (changed/'unrelated').write_text('independent remote change\n'); git(env,'-C',changed,'add','unrelated')
            git(env,'-C',changed,'commit','-m','independent'); git(env,'-C',changed,'push','origin','main')
        counts=(pushes(case,'a'),pushes(case,'b'))
        p,refused=recover_plan(case,env,ws,options=['--execute','--push'],pin=pin)
        check(fault+' refuses at its intended boundary with no recovery push',p.returncode==expected and
              not refused['delivery_confirmed'] and (pushes(case,'a'),pushes(case,'b'))==counts and
              (fault=='delegation-corrupt' or not (ws/'continuation.json').exists()))

    case,env,before=setup('failed-delegated-push')
    proc=subprocess.Popen(command(pause='target-1.result.json'),env=env,
        stdout=(case/'stdout').open('wb'),stderr=(case/'stderr').open('wb'),start_new_session=True)
    for _ in range(1500):
        if (case/'paused').is_file() or proc.poll() is not None: break
        time.sleep(.02)
    if not (case/'paused').is_file():
        if proc.poll() is None: os.killpg(proc.pid,signal.SIGKILL); proc.wait(timeout=10)
        raise AssertionError('delegation fixture did not reach first completed target')
    ws=Path((case/'paused').read_text().strip()); os.killpg(proc.pid,signal.SIGKILL); proc.wait(timeout=10)
    reject=case/'remotes/b.git/hooks/pre-receive'; reject.write_text('#!/usr/bin/env bash\nexit 1\n'); reject.chmod(0o755)
    p,partial=recover_plan(case,env,ws,options=['--execute','--push'])
    child_result=partial.get('delegated_result',{})
    check('failed delegated push retains both the delegation and actual child recovery evidence',
          p.returncode==8 and not partial['delivery_confirmed'] and (ws/'continuation.json').is_file() and
          child_result.get('exit_code')==8 and child_result.get('results',[{}])[0].get('committed') is True and
          pushes(case,'a')==1 and pushes(case,'b')==0)
    p,refused=recover_plan(case,env,ws,options=['--execute','--push'])
    check('an incomplete child is not silently rerun from the parent plan',p.returncode==2 and pushes(case,'b')==0)
    (case/'original-rejected-hook').write_bytes(reject.read_bytes()); reject.write_text('#!/usr/bin/env bash\nexit 0\n')
    if not child_result.get('workspace'): raise AssertionError('failed child did not retain its workspace')
    p,repaired=recover_plan(case,env,Path(child_result['workspace']),options=['--execute','--push'])
    check('child-plan recovery delivers the SAME previously rejected commit without duplicate parent work',
          p.returncode==0 and repaired['delivery_confirmed'] and pushes(case,'a')==pushes(case,'b')==1 and
          git(env,'--git-dir',case/'remotes/b.git','rev-parse','main')==child_result['results'][0]['commit'])

    case,env,before=setup('cancel-continuation')
    _,original,ws=complete(case,env)
    (case/'hold-curl').write_text('pause the explicit HTTP fixture\n')
    output=case/'cancelled-recovery'
    proc=subprocess.Popen(['bash',str(root/'src/checksum_sync.sh'),'recover','--plan',str(ws/'sync-plan.json'),
        '--plan-sha256',digest(ws/'sync-plan.json'),'--output-dir',str(output)],env=env,
        stdout=(case/'recover.stdout').open('wb'),stderr=(case/'recover.stderr').open('wb'),start_new_session=True)
    for _ in range(1500):
        if (case/'curl-paused').is_file() or proc.poll() is not None: break
        time.sleep(.02)
    if not (case/'curl-paused').is_file():
        if proc.poll() is None: os.killpg(proc.pid,signal.SIGKILL); proc.wait(timeout=10)
        raise AssertionError('continuation did not reach HTTP cancellation boundary')
    transport=int((case/'curl-paused').read_text())
    p,conflict=recover_plan(case,env,ws)
    check('another actual fan-out recovery cannot overlap the active continuation',p.returncode==2 and not conflict.get('output_dir'))
    single=subprocess.run(['bash',str(root/'src/checksum_sync.sh'),'recover','--result',str(ws/'result.json'),
        '--result-sha256',digest(ws/'result.json'),'--target-repo','owner/a','--output-dir',str(case/'blocked-single')],
        env=env,capture_output=True,timeout=15)
    check('single-commit recovery also refuses a concurrently owned full plan',single.returncode==2 and
          not (case/'blocked-single').exists() and pushes(case,'a')==pushes(case,'b')==1)
    proc.send_signal(signal.SIGTERM); code=proc.wait(timeout=20)
    result=json.loads((case/'recover.stdout').read_bytes())
    check('TERM to the public recovery PID retains a non-successful interruption result',
          code==5 and result['exit_code']==5 and not result['delivery_confirmed'] and
          (output/'result.json').read_bytes()==(case/'recover.stdout').read_bytes())
    def alive(pid):
        try:
            os.kill(pid,0)
            procstat=Path('/proc')/str(pid)/'stat'
            return not (procstat.is_file() and procstat.read_text().rsplit(')',1)[1].split()[0]=='Z')
        except ProcessLookupError: return False
    for _ in range(100):
        if not alive(transport): break
        time.sleep(.02)
    check('cancellation reaps the owned audit transport and releases the plan lease',not alive(transport))
    with (ws/'.sync.lock').open('r') as held_lease:
        try: fcntl.flock(held_lease,fcntl.LOCK_EX|fcntl.LOCK_NB); free=True
        except BlockingIOError: free=False
    check('cancelled continuation does not leave a live synchronization owner',free and pushes(case,'a')==pushes(case,'b')==1)
print('Sync plan: %d passed, %d failed' % (checks-failures,failures),flush=True)
raise SystemExit(1 if failures else 0)
PY
