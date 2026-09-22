#!/usr/bin/env bash
# Real subprocess scheduling, timeout/cancellation, state, hashing and bundle
# admission. Native DSR and xwin compilation are explicit driver-boundary fixtures.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 bash jq flock timeout sha256sum; do
    command -v "$tool" >/dev/null || { printf 'SKIP requires %s\n' "$tool"; exit 0; }
done
[[ "$(uname -s)" == Linux ]] || { printf 'SKIP requires Linux\n'; exit 0; }
python3 - "$ROOT" <<'PY'
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
work = Path(tempfile.mkdtemp(prefix="dsr-release-builds-test-"))
passes = 0

def check(label, condition):
    global passes
    if not condition:
        raise AssertionError(label)
    passes += 1
    print("PASS " + label, flush=True)

def encode(p, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj))

def read(p):
    return json.loads(p.read_text())

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

try:
    repo = work / "repo"
    (repo / "src").mkdir(parents=True)
    (repo / "scripts").mkdir()
    for file in ("release_builds.sh", "release_bundle.sh", "slsa.sh"):
        shutil.copyfile(root / "src" / file, repo / "src" / file)
    # The production dispatcher has no test hooks. Execute unmodified code in
    # a temporary installation with test doubles only at its driver paths.
    (repo / "dsr").write_text('#!/usr/bin/env bash\nexec python3 "$(dirname "$0")/driver.py" dsr "$@"\n')
    (repo / "scripts/xwin-build.sh").write_text('#!/usr/bin/env bash\nexec python3 "$(dirname "$0")/../driver.py" xwin "$@"\n')
    (repo / "driver.py").write_text(r'''
import fcntl, hashlib, json, os, subprocess, sys, time
from pathlib import Path
kind, args = sys.argv[1], sys.argv[2:]
def arg(flag): return args[args.index(flag)+1]
if kind == 'dsr':
    assert args[:3] == ['--json', '--non-interactive', 'build']
    assert '--allow-dirty' not in args and '--no-sync' not in args and '--resume' not in args
    cfg = Path(os.environ['DSR_CONFIG_DIR'])
    assert os.environ['DSR_CONFIG_FILE'] == str(cfg/'config.yaml')
    assert os.environ['DSR_REPOS_FILE'] == str(cfg/'repos.yaml')
    assert os.environ['DSR_HOSTS_FILE'] == str(cfg/'hosts.yaml')
    spec = json.loads((cfg/'config.yaml').read_text())
    output = Path(arg('--output-dir'))
    targets = arg('--targets').split(',')
    tool, tag, source = arg('--tool'), arg('--version'), spec['source']
    manifest = output/(tool+'-'+tag+'-manifest.json')
else:
    spec = json.loads(Path(arg('--manifest')).read_text())
    output = Path(arg('--run-dir'))/'artifacts'
    manifest = output.parent/'release/build-manifest.json'
    targets = ['windows/arm64']
    tool, tag, source = arg('--tool'), arg('--release-tag'), arg('--source-sha')
    assert arg('--release-repo') == 'owner/demo' and arg('--bin') == 'demo'
    assert arg('--package') == 'demo-package' and '--offline' in args
    assert json.loads(Path(arg('--sibling-crates')).read_text()) == []
trace = Path(spec['trace'])
def event(phase):
    with trace.open('a') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(json.dumps({'job':spec['id'], 'phase':phase, 'at':time.monotonic(), 'pid':os.getpid()})+'\n')
mode = Path(spec['control']).read_text().strip()
event('start')
if mode in ('slow', 'leak'):
    sleeper = subprocess.Popen(['sleep', '60'])
    Path(spec['control']+'.pid').write_text(str(sleeper.pid))
    if mode == 'slow': sleeper.wait()
time.sleep(spec.get('delay', 0.3))
if mode == 'fail':
    event('end'); sys.exit(42)
output.mkdir(parents=True)
artifacts = []
for target in targets:
    name = 'demo-'+target.replace('/', '-')+'.bin'
    if kind == 'xwin': name = arg('--asset-name')
    data = ('built '+target+'\n').encode()
    (output/name).write_bytes(data)
    artifacts.append({'name':name, 'target':target, 'sha256':hashlib.sha256(data).hexdigest(), 'size_bytes':len(data), 'archive_format':'binary'})
value = {'schema_version':'1.0.0', 'tool':tool, 'version':tag, 'run_id':'12345678-1234-4123-8123-123456789abc',
         'source':{'git_sha':source, 'git_ref':'refs/tags/'+tag, 'dependencies':[]}, 'built_at':'2026-09-22T00:00:00Z',
         'status':'success', 'summary':{'total':len(targets), 'success':len(targets), 'failed':0}, 'artifacts':artifacts,
         'build_environments':[{'target':target, 'method':kind, 'retained_evidence':'x'*150000} for target in targets]}
if mode == 'wrong-source': value['source']['git_sha'] = 'b'*40
if mode == 'bad-hash': value['artifacts'][0]['sha256'] = '0'*64
if mode == 'diagnostic': value['publishable'] = False
if mode == 'config-drift': (cfg/'config.yaml').write_text('{}')
if mode == 'extra-config': (cfg/'repos.d').mkdir(); (cfg/'repos.d/injected.yaml').write_text('{}')
manifest.parent.mkdir(parents=True, exist_ok=True)
manifest.write_text(json.dumps(value))
event('end')
if mode == 'silent': sys.exit(0)
if kind == 'dsr':
    response = {'command':'build', 'status':'success', 'exit_code':0, 'details':{'manifest':str(manifest)}}
else:
    response = {'kind':'dsr-xwin-build', 'status':'verified', 'exit_code':0,
                'release_manifest':{'path':str(manifest), 'sha256':hashlib.sha256(manifest.read_bytes()).hexdigest()}}
if mode == 'wrong-receipt': response['exit_code'] = 7
if mode == 'null-details': response['details'] = None
if mode == 'array-details': response['details'] = []
print(json.dumps(response))
''')
    script = repo / "src/release_builds.sh"
    trace = work / "events.jsonl"
    controls = {}
    def native(identity, target):
        cfg = work / ("config-" + identity)
        control = work / ("control-" + identity)
        control.write_text('good')
        controls[identity] = control
        encode(cfg/'config.yaml', {'id':identity, 'source':'a'*40, 'trace':str(trace), 'control':str(control)})
        encode(cfg/'repos.yaml', {'tools':{}})
        encode(cfg/'hosts.yaml', {'hosts':{}})
        return {'id':identity, 'driver':'dsr', 'targets':[target], 'config_dir':str(cfg),
                'config_files':{p.name:sha(p) for p in cfg.iterdir()}}
    a, b = native('linux', 'linux/amd64'), native('darwin', 'darwin/arm64')
    control = work/'control-windows'; control.write_text('good'); controls['windows']=control
    toolchain, siblings = work/'toolchain.json', work/'siblings.json'
    encode(toolchain, {'id':'windows','trace':str(trace),'control':str(control)})
    encode(siblings, [])
    windows = {'id':'windows', 'driver':'xwin', 'targets':['windows/arm64'], 'project':str(work/'project'),
               'toolchain_manifest':str(toolchain), 'toolchain_sha256':sha(toolchain), 'binary':'demo',
               'package':'demo-package', 'offline':True, 'asset_name':'demo-windows-arm64.exe',
               'siblings':{'path':str(siblings),'sha256':sha(siblings)}}
    plan = {'schema_version':1,'repo':'owner/demo','tool':'demo','tag':'v1.2.3','source_sha':'a'*40,
            'required_targets':['linux/amd64','darwin/arm64','windows/arm64'],'builds':[a,b,windows]}
    planfile = work/'plan.json'; encode(planfile, plan)
    def run(output, expected=0, selected=planfile, extra=(), env=None):
        proc = subprocess.run(['bash',str(script),'--plan',str(selected),'--output-dir',str(output)] + list(extra),
                              env=env, stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=45)
        if proc.returncode != expected:
            print(proc.stderr.decode(), file=sys.stderr)
            raise AssertionError(f'expected {expected}, got {proc.returncode}: {proc.stdout.decode()}')
        value = json.loads(proc.stdout)
        check('one JSON envelope agrees with process exit', value['exit_code']==expected)
        return value
    output = work/'builds'
    result = run(output, extra=('--dry-run','--jobs','2'))
    check('planning starts no builders and creates no state', result['status']=='planned' and not output.exists() and not trace.exists())
    controls['windows'].write_text('fail')
    env = dict(os.environ, DSR_CONFIG_FILE='/wrong', DSR_REPOS_FILE='/wrong', DSR_HOSTS_FILE='/wrong')
    result = run(output,1,extra=('--jobs','2'),env=env)
    check('independent successes survive a failed builder', result['completed_builds']==2 and result['failed_builds']==['windows'])
    check('incomplete matrix has no publishable bundle', not (output/'bundle').exists() and not result['publishable'])
    state = read(output/'state.json')
    check('compiler status is retained per attempt', state['jobs']['windows']['attempts'][0]['exit_code']==42)
    events = [json.loads(line) for line in trace.read_text().splitlines()]
    live = maximum = 0
    for item in events:
        live += 1 if item['phase']=='start' else -1
        maximum = max(maximum, live)
    check('two workers actually overlap without exceeding bound', maximum==2)
    controls['windows'].write_text('good')
    before = len(events)
    result = run(output,extra=('--jobs','3'))
    new_events=[json.loads(line) for line in trace.read_text().splitlines()[before:]]
    check('retry executes only the failed driver', {e['job'] for e in new_events}=={'windows'})
    check('all targets reach the existing bundle collector', result['bundle']['targets']==sorted(plan['required_targets']))
    check('large producer evidence survives full execution/aggregation', Path(result['bundle']['manifest']).stat().st_size>450000)
    check('complete manifests are pinned only after successful execution', all(sha(Path(j['manifest']))==j['manifest_sha256'] for j in read(output/'build-set.json')['builds']))
    before_trace=trace.read_bytes()
    before_hash=result['bundle']['manifest_sha256']
    # Original compiler outputs are no longer the checkpoint authority.
    original=output/'attempts/linux/000001/output'
    original.rename(original.with_name('removed-output'))
    result = run(output)
    check('completed builds are independently verified without recompilation', trace.read_bytes()==before_trace and result['bundle']['manifest_sha256']==before_hash)
    reordered=json.loads(json.dumps(plan)); reordered['builds'].reverse(); reordered['required_targets'].reverse()
    encode(work/'reordered.json',reordered)
    result=run(output,selected=work/'reordered.json')
    check('plan ordering does not change recovery identity', result['bundle']['manifest_sha256']==before_hash)
    changed=json.loads(json.dumps(plan)); changed['builds'][0]['timeout']=12; encode(work/'changed.json',changed)
    run(output,2,work/'changed.json')
    check('changed plans cannot reuse completed work', trace.read_bytes()==before_trace)
    checkpoint=output/'completed/linux/artifacts/demo-linux-amd64.bin'
    original_bytes=checkpoint.read_bytes(); checkpoint.write_bytes(b'corrupted')
    run(output,7)
    check('checkpoint corruption fails before any new builder', trace.read_bytes()==before_trace)
    checkpoint.write_bytes(original_bytes)
    # Simulate lost acknowledgement after atomic import but before state update.
    state=read(output/'state.json'); state['jobs']['linux']['candidate']=state['jobs']['linux']['complete']; state['jobs']['linux']['complete']=None
    state['jobs']['linux']['attempts'][-1].update(status='running',exit_code=None); encode(output/'state.json',state)
    run(output)
    check('interrupted import completion is reconciled without rebuilding', trace.read_bytes()==before_trace and read(output/'state.json')['jobs']['linux']['complete'] is not None)
    # Drive individual native failure gates through the real collector.
    single=dict(plan,required_targets=a['targets'],builds=[a]); encode(work/'single.json',single)
    for mode in ('wrong-source','bad-hash','diagnostic','config-drift','extra-config','silent','wrong-receipt','null-details','array-details'):
        controls['linux'].write_text(mode)
        folder=work/('reject-'+mode)
        run(folder,1,work/'single.json')
        check(mode+' never admits a completed checkpoint', not (folder/'completed/linux').exists() and not (folder/'bundle').exists())
    controls['linux'].write_text('null-details')
    mixed = dict(plan, required_targets=['linux/amd64', 'darwin/arm64'], builds=[a, b])
    encode(work/'malformed-mixed.json', mixed)
    result = run(work/'malformed-mixed', 1, work/'malformed-mixed.json', extra=('--jobs', '2'))
    check('malformed completion does not cancel an independent successful job',
          result['failed_builds']==['linux'] and result['completed_builds']==1 and
          (work/'malformed-mixed/completed/darwin/build-manifest.json').is_file())
    controls['linux'].write_text('good')
    # Missing reviewed file/hash fails before any child starts.
    changed=json.loads(json.dumps(single)); changed['builds'][0]['config_files']['config.yaml']='0'*64; encode(work/'badpin.json',changed)
    before_trace=trace.read_bytes(); run(work/'badpin',1,work/'badpin.json')
    check('configuration hash mismatch does not execute the native builder', trace.read_bytes()==before_trace)
    # Invalid plans fail with no state. Duplicate object keys are also refused.
    for title, mutation in (
        ('missing-target',lambda p:p['required_targets'].append('linux/arm64')),
        ('duplicate-target',lambda p:p['builds'].append(dict(p['builds'][0],id='other'))),
        ('unknown-driver',lambda p:p['builds'][0].update(driver='shell')),
        ('relative-path',lambda p:p['builds'][0].update(config_dir='relative')),
        ('unknown-option',lambda p:p['builds'][0].update(command='echo unsafe')),
        ('boolean-timeout',lambda p:p['builds'][0].update(timeout=True)),
    ):
        changed=json.loads(json.dumps(single)); mutation(changed); encode(work/'invalid.json',changed)
        folder=work/('invalid-'+title); run(folder,4,work/'invalid.json')
        check(title+' rejected before filesystem mutation',not folder.exists())
    (work/'duplicate.json').write_text(planfile.read_text()[:-1]+',"schema_version":1}')
    run(work/'duplicate',4,work/'duplicate.json')
    run(work/'options',4,extra=('--jobs','1','--jobs','2'))
    # Process deadlines and explicit CLI cancellation cover real child groups.
    controls['linux'].write_text('slow')
    slow=json.loads(json.dumps(single)); slow['builds'][0]['timeout']=1; encode(work/'slow.json',slow)
    run(work/'deadline',1,work/'slow.json')
    check('timeout status retained and success withheld',read(work/'deadline/state.json')['jobs']['linux']['attempts'][0]['exit_code']==124)
    def stopped(pid):
        p=Path('/proc')/str(pid)/'stat'
        return not p.exists() or p.read_text().split(') ',1)[1].split()[0]=='Z'
    check('timeout kills compiler descendants',stopped(int(Path(str(controls['linux'])+'.pid').read_text())))
    # A longer deadline lets the test address the CLI PID rather than its group.
    slow['builds'][0]['timeout']=20; encode(work/'slow.json',slow)
    out=open(work/'cancel.stdout','wb'); err=open(work/'cancel.stderr','wb')
    proc=subprocess.Popen(['bash',str(script),'--plan',str(work/'slow.json'),'--output-dir',str(work/'cancel')],stdout=out,stderr=err)
    prior=trace.read_text().count('start')
    deadline=time.monotonic()+10
    while time.monotonic()<deadline and trace.read_text().count('start')==prior: time.sleep(.03)
    check('cancellable build reached running boundary',trace.read_text().count('start')>prior)
    run(work/'cancel',2,work/'slow.json')
    proc.send_signal(signal.SIGTERM); code=proc.wait(timeout=10); out.close();err.close()
    check('SIGTERM to CLI exits with interruption status',code==5 and read(work/'cancel.stdout')['exit_code']==5)
    check('cancellation kills compiler descendants',stopped(int(Path(str(controls['linux'])+'.pid').read_text())))
    controls['linux'].write_text('good'); run(work/'cancel',selected=work/'slow.json')
    check('interrupted attempt is retained while a fresh retry succeeds', [r['status'] for r in read(work/'cancel/state.json')['jobs']['linux']['attempts']]==['interrupted','completed'])
    # A killed coordinator cannot perform finally cleanup. Its live driver
    # must nevertheless retain the inherited lock and prevent a second build.
    controls['linux'].write_text('slow')
    prior=trace.read_text().count('start')
    out=open(work/'crash.stdout','wb'); err=open(work/'crash.stderr','wb')
    proc=subprocess.Popen(['bash',str(script),'--plan',str(work/'slow.json'),'--output-dir',str(work/'crash')],stdout=out,stderr=err)
    group=None
    try:
        deadline=time.monotonic()+10
        while time.monotonic()<deadline and trace.read_text().count('start')==prior: time.sleep(.03)
        check('crash probe reached its own native driver',trace.read_text().count('start')>prior)
        event=json.loads(trace.read_text().splitlines()[-1])
        group=os.getpgid(event['pid'])
        check('crash probe driver owns a separate process group',group!=os.getpgrp())
        proc.kill(); proc.wait(timeout=5)
        run(work/'crash',2,work/'slow.json')
        check('live driver keeps the coordinator lock after parent SIGKILL',not stopped(event['pid']))
    finally:
        if group is not None:
            try: os.killpg(group,signal.SIGTERM)
            except ProcessLookupError: pass
        if proc.poll() is None:
            proc.terminate(); proc.wait(timeout=10)
        out.close();err.close()
    deadline=time.monotonic()+10
    while time.monotonic()<deadline and not stopped(event['pid']): time.sleep(.03)
    check('crash probe driver has terminated before recovery',stopped(event['pid']))
    controls['linux'].write_text('good'); run(work/'crash',selected=work/'slow.json')
    check('crash recovery never adopts unacknowledged compiler output',
          [r['status'] for r in read(work/'crash/state.json')['jobs']['linux']['attempts']]==['interrupted','completed'])
    controls['linux'].write_text('leak'); run(work/'leak',selected=work/'single.json')
    check('successful builder cannot leave detached group children running',stopped(int(Path(str(controls['linux'])+'.pid').read_text())))
    controls['linux'].write_text('good')
    # Already built inputs can coexist with jobs that still need execution.
    imported=dict(plan,required_targets=['linux/amd64'],builds=[dict(read(output/'build-set.json')['builds'][1],driver='import')])
    # Select by ID rather than relying on the canonical plan's sorted position.
    imported['builds']=[dict(next(j for j in read(output/'build-set.json')['builds'] if j['id']=='linux'),driver='import')]
    encode(work/'import.json',imported); before_trace=trace.read_bytes(); run(work/'import',selected=work/'import.json')
    check('pre-pinned imported builds need no compiler execution',trace.read_bytes()==before_trace)
    print(f'\nRelease build-plan execution: {passes} passed, 0 failed',flush=True)
except Exception:
    print('Retained failing fixtures: '+str(work),file=sys.stderr)
    raise
else:
    shutil.rmtree(work)
PY
