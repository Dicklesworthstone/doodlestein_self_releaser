#!/usr/bin/env bash
# Native exact-run resume through the real build coordinator and bundle/SLSA
# modules. Only the native compiler/SSH driver is a command-boundary fixture.
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
work = Path(tempfile.mkdtemp(prefix='dsr-native-resume-test-'))
passes = 0

def check(label, condition):
    global passes
    if not condition:
        raise AssertionError(label)
    passes += 1
    print('PASS ' + label, flush=True)

def read(p):
    return json.loads(p.read_text())

def write(p, value):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value))

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

try:
    repo = work / 'repo'
    (repo / 'src').mkdir(parents=True)
    for name in ('release_builds.sh', 'release_bundle.sh', 'slsa.sh'):
        shutil.copyfile(root / 'src' / name, repo / 'src' / name)
    (repo / 'dsr').write_text('#!/usr/bin/env bash\nexec python3 "$(dirname "$0")/native.py" "$@"\n')
    (repo / 'native.py').write_text(r'''
import hashlib, json, os, subprocess, sys, uuid
from pathlib import Path
args = sys.argv[1:]
assert args[:3] == ['--json', '--non-interactive', 'build']
assert '--allow-dirty' not in args and '--no-sync' not in args
arg = lambda flag: args[args.index(flag) + 1]
cfg = Path(os.environ['DSR_CONFIG_DIR'])
assert os.environ['DSR_CONFIG_FILE'] == str(cfg / 'config.yaml')
assert os.environ['DSR_REPOS_FILE'] == str(cfg / 'repos.yaml')
assert os.environ['DSR_HOSTS_FILE'] == str(cfg / 'hosts.yaml')
spec = json.loads((cfg / 'config.yaml').read_text())
mode = Path(spec['control']).read_text().strip()
tool, version = arg('--tool'), arg('--version')
targets = arg('--targets').split(',')
output = Path(arg('--output-dir'))
namespace = Path(os.environ['DSR_STATE_DIR']) / 'builds' / tool / version
resume = [a.split('=', 1)[1] for a in args if a.startswith('--resume=')]
assert len(resume) <= 1 and '--resume' not in args

def event(kind, **extra):
    with open(spec['trace'], 'a') as f:
        f.write(json.dumps({'event':kind, 'args':args, **extra}) + '\n')

def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def save():
    staging = checkpoint.with_suffix('.next')
    staging.write_text(json.dumps(state))
    staging.replace(checkpoint)

event('invoke', config=str(cfg), output=str(output), state=str(namespace))
if mode == 'preflight':
    sys.exit(42)
if resume:
    identity = resume[0]
    checkpoint = namespace / identity / 'state.json'
    state = json.loads(checkpoint.read_text())
    assert state['run_id'] == identity and state['targets'] == targets
    assert state['git_sha'] == spec['source'] and state['context']['output_dir'] == str(output)
    assert state['context']['config_root'] == str(cfg)
    assert state['status'] not in ('completed', 'cancelled')
    # Stand in for DSR's existing target-receipt checks, never silently repair.
    for item in state['target_statuses'].values():
        if item['status'] == 'success':
            if not Path(item['path']).is_file() or digest(Path(item['path'])) != item['sha256']:
                event('rejected-artifact'); sys.exit(7)
else:
    identity = str(uuid.uuid4())
    checkpoint = namespace / identity / 'state.json'
    checkpoint.parent.mkdir(parents=True)
    output.mkdir()
    state = {'tool':tool, 'version':version, 'run_id':identity, 'git_sha':spec['source'], 'git_ref':version,
             'targets':targets, 'status':'created', 'context':{'output_dir':str(output), 'build_purpose':'release',
             'publishable':True, 'config_root':str(cfg), 'opaque_host_receipts':{'native-host':'retained'}},
             'target_statuses':{t:{'status':'pending', 'attempts':0} for t in targets}}
    (namespace / 'latest').symlink_to(identity)
    save()
state['status'] = 'running'; save()
for number, target in enumerate(targets):
    item = state['target_statuses'][target]
    if item['status'] == 'success':
        event('reuse', target=target); continue
    if number == 1 and mode == 'slow':
        child = subprocess.Popen(['sleep', '60'])
        Path(spec['control'] + '.pid').write_text(str(child.pid))
        event('sleep', child=child.pid)
        child.wait()
    item['attempts'] += 1
    if number == 1 and mode == 'partial':
        item['status'] = 'failed'; state['status'] = 'failed'; save(); sys.exit(42)
    destination = output / ('demo-' + target.replace('/', '-') + '.bin')
    destination.write_bytes(('built native fixture ' + target + '\n').encode())
    event('compile', target=target)
    item.update(status='success', path=str(destination), sha256=digest(destination))
    save()
manifest = output / (tool + '-' + version + '-manifest.json')
artifacts = [{'name':Path(i['path']).name, 'target':t, 'sha256':i['sha256'], 'size_bytes':Path(i['path']).stat().st_size,
              'archive_format':'binary'} for t, i in state['target_statuses'].items()]
value = {'schema_version':'1.0.0', 'tool':tool, 'version':version, 'run_id':identity,
         'source':{'git_sha':spec['source'], 'git_ref':version, 'dependencies':[]},
         'built_at':'2026-09-22T00:00:00Z', 'status':'success',
         'summary':{'total':len(targets), 'success':len(targets), 'failed':0}, 'artifacts':artifacts}
if mode == 'wrong-manifest-run': value['run_id'] = str(uuid.uuid4())
if mode == 'wrong-state-run': state['run_id'] = str(uuid.uuid4())
manifest.write_text(json.dumps(value))
state['status'] = 'completed'; save()
print(json.dumps({'command':'build', 'status':'success', 'exit_code':0, 'details':{'manifest':str(manifest)}}))
''')
    script = repo / 'src/release_builds.sh'
    def fixture(label, mode='partial', resume=True):
        case = work / label
        case.mkdir()
        (case / 'control').write_text(mode)
        write(case / 'config/config.yaml', {'control':str(case / 'control'), 'trace':str(case / 'events'), 'source':'a'*40})
        write(case / 'config/repos.yaml', {'tools':{}})
        write(case / 'config/hosts.yaml', {'hosts':{}})
        job = {'id':'native', 'driver':'dsr', 'targets':['darwin/arm64', 'linux/amd64'], 'config_dir':str(case / 'config'),
               'config_files':{p.name:sha(p) for p in (case / 'config').iterdir()}, 'resume':resume}
        write(case / 'plan.json', {'schema_version':1, 'repo':'owner/demo', 'tool':'demo', 'tag':'v1.2.3', 'source_sha':'a'*40,
                                  'required_targets':job['targets'], 'builds':[job]})
        return case
    def invoke(case, expected=0):
        proc = subprocess.run(['bash', str(script), '--plan', str(case / 'plan.json'), '--output-dir', str(case / 'run')],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        if proc.returncode != expected:
            print(proc.stderr.decode(), file=sys.stderr)
            raise AssertionError(f'{case.name}: expected {expected}, got {proc.returncode}: {proc.stdout.decode()}')
        result = json.loads(proc.stdout)
        check(case.name + ': one envelope agrees with exit', result['exit_code'] == expected)
        return result
    def events(case):
        return [json.loads(s) for s in (case / 'events').read_text().splitlines()] if (case / 'events').exists() else []
    def session(case, number=1):
        return case / 'run/attempts/native' / f'{number:06d}'
    def checkpoint(case):
        return next((session(case) / 'state/builds/demo/v1.2.3').glob('*/state.json'))
    def no_launch(case, mutate, message):
        before = events(case)
        mutate()
        invoke(case, 1)
        check(message, events(case) == before and not (case / 'run/completed/native').exists())

    case = fixture('resume')
    invoke(case, 1)
    state_file = checkpoint(case)
    old_state = read(state_file)
    identity = old_state['run_id']
    payload = session(case) / 'output/demo-darwin-arm64.bin'
    before_bytes, before_inode = payload.read_bytes(), payload.stat().st_ino
    (case / 'control').write_text('good')
    # Resume uses frozen bytes, not the live config tree or a moving latest link.
    (case / 'config').rename(case / 'config-offline')
    latest = state_file.parent.parent / 'latest'
    latest.rename(latest.with_name('old-latest'))
    # Keep the foreign pointer under the sole ignored 'latest' name.
    (latest.with_name('old-latest')).rename(case / 'old-latest')
    latest.symlink_to('/must-not-follow')
    result = invoke(case)
    check('resumed native job reaches complete bundle', result['bundle']['status'] == 'verified')
    calls = [e for e in events(case) if e['event'] == 'invoke']
    check('retry supplies exact UUID, never latest', '--resume=' + identity in calls[1]['args'] and '--resume=latest' not in calls[1]['args'])
    check('state config and output paths remain bound to original session', all(calls[0][k] == calls[1][k] for k in ('config','state','output')))
    check('successful target is not compiled again', len([e for e in events(case) if e['event']=='compile' and e['target']=='darwin/arm64']) == 1)
    check('retained target bytes and inode are unchanged', payload.read_bytes() == before_bytes and payload.stat().st_ino == before_inode)
    history = read(case / 'run/state.json')['jobs']['native']['attempts']
    check('separate attempts retain one native run identity', [a['native']['session_attempt'] for a in history] == [1,1] and all(a['native']['run_id']==identity for a in history))
    check('resume evidence retains before and after native checkpoints', read(session(case,2)/'native-before.json')['status']=='failed' and read(session(case,2)/'native-after.json')['status']=='completed')
    check('retry does not create replacement state or outputs', not (session(case,2)/'output').exists() and not (session(case,2)/'state').exists())
    before = events(case); invoke(case)
    check('completed release retry launches no native driver', events(case) == before)

    case = fixture('repeat')
    invoke(case,1); invoke(case,1)
    (case/'control').write_text('good'); invoke(case)
    history = read(case/'run/state.json')['jobs']['native']['attempts']
    check('multiple retries retain the same original session', [a['native']['session_attempt'] for a in history]==[1,1,1])
    check('a successful target survives more than one retry', len([e for e in events(case) if e['event']=='compile' and e['target']=='darwin/arm64'])==1)

    for label, mutate in (
        ('wrong-source', lambda s:s.update(git_sha='b'*40)),
        ('wrong-version', lambda s:s.update(version='v9.9.9')),
        ('wrong-targets', lambda s:s.update(targets=['linux/amd64'])),
        ('wrong-run', lambda s:s.update(run_id='12345678-1234-4123-8123-123456789abc')),
        ('wrong-output', lambda s:s['context'].update(output_dir='/outside')),
        ('diagnostic', lambda s:s['context'].update(build_purpose='diagnostic-native')),
        ('nonpublishable', lambda s:s['context'].update(publishable=False)),
        ('cancelled', lambda s:s.update(status='cancelled')),
        ('completed-without-admission', lambda s:s.update(status='completed')),
    ):
        case=fixture(label); invoke(case,1); state_file=checkpoint(case); value=read(state_file); mutate(value)
        no_launch(case, lambda:write(state_file,value), label+' refused before native execution')
    case=fixture('malformed-state'); invoke(case,1)
    no_launch(case, lambda:checkpoint(case).write_text('[]'), 'malformed native state fails as a job error')
    case=fixture('missing-state'); invoke(case,1); saved=checkpoint(case)
    no_launch(case, lambda:saved.rename(case/'held-state.json'), 'a previously observed checkpoint cannot disappear')
    case=fixture('ambiguous'); invoke(case,1); saved=checkpoint(case)
    no_launch(case, lambda:shutil.copytree(saved.parent, saved.parent.with_name('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')),
              'two native runs cannot be resolved by recency')
    case=fixture('changed-config'); invoke(case,1)
    no_launch(case, lambda:(session(case)/'config/config.yaml').write_text('{}'), 'changed frozen config blocks resume')
    case=fixture('changed-command'); invoke(case,1)
    no_launch(case, lambda:write(session(case)/'command.json',['bash','/outside']), 'changed original invocation blocks resume')
    case=fixture('changed-inputs'); invoke(case,1)
    no_launch(case, lambda:write(session(case)/'inputs.json',{}), 'changed original input receipt blocks resume')
    case=fixture('linked-state'); invoke(case,1); saved=checkpoint(case); moved=case/'actual-state.json'; saved.rename(moved)
    no_launch(case, lambda:saved.symlink_to(moved), 'linked native checkpoint is refused')
    case=fixture('corrupt-artifact'); invoke(case,1)
    (session(case)/'output/demo-darwin-arm64.bin').write_bytes(b'corruption')
    (case/'control').write_text('good'); invoke(case,1)
    check('native receipt rejection is not retried as a fresh build', events(case)[-1]['event']=='rejected-artifact' and '--resume=' in ' '.join(events(case)[-1]['args']))
    check('native rejection preserves the corrupted evidence instead of replacing it', (session(case)/'output/demo-darwin-arm64.bin').read_bytes()==b'corruption')
    for mode in ('wrong-manifest-run','wrong-state-run'):
        case=fixture(mode); invoke(case,1); (case/'control').write_text(mode); invoke(case,1)
        check(mode+' cannot admit success', not (case/'run/completed/native').exists())
    case=fixture('preflight',mode='preflight'); invoke(case,1); (case/'control').write_text('good'); invoke(case)
    check('failure before native checkpoint creation gets a fresh isolated session', read(case/'run/state.json')['jobs']['native']['attempts'][1]['native']['session_attempt']==2)
    case=fixture('disabled',resume=False); invoke(case,1); (case/'control').write_text('good'); invoke(case)
    check('disabled resume preserves fresh-attempt behavior', not any(a.startswith('--resume') for e in events(case) for a in e['args']))
    case=fixture('bad-option'); value=read(case/'plan.json'); value['builds'][0]['resume']='true'; write(case/'plan.json',value); invoke(case,4)
    check('resume policy must be a real boolean', not (case/'run').exists())
    print(f'\nNative build-plan resume: {passes} passed, 0 failed', flush=True)
except Exception:
    print('Retained failing fixtures: '+str(work), file=sys.stderr)
    raise
else:
    shutil.rmtree(work)
PY
