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
# The native entry point is replaced below by native.py; this policy applies
# only to that installation's process fixtures, never to an actual compiler.
fixture_env = dict(os.environ, RCH_REQUIRE_REMOTE='0')
fixture_env.pop('DSR_IMPORT_MUTATION_PATH', None)
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

def overwrite(p, text):
    # dsr freezes inputs read-only (0400); unlock before simulating drift so
    # the case also tests something when not run as root.
    p.chmod(0o600)
    p.write_text(text)

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

try:
    repo = work / 'repo'
    (repo / 'src').mkdir(parents=True)
    for name in ('release_builds.sh', 'release_bundle.sh', 'slsa.sh', 'platforms.sh', 'guardrails.sh'):
        shutil.copyfile(root / 'src' / name, repo / 'src' / name)
    (repo / 'dsr').write_text('#!/usr/bin/env bash\nexec python3 "$(dirname "$0")/native.py" "$@"\n')
    (repo / 'native.py').write_text(r'''
import hashlib, json, os, signal, subprocess, sys, time, uuid
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
if mode == 'stubborn':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
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
    if number == 1 and mode in ('slow', 'stubborn'):
        child = (subprocess.Popen([sys.executable, '-c',
                 'import pathlib,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                 'pathlib.Path(sys.argv[1]).write_text("ready"); time.sleep(60)', spec['control'] + '.stubborn-ready'],
                 start_new_session=True) if mode == 'stubborn' else subprocess.Popen(['sleep', '60']))
        if mode == 'stubborn':
            until = time.monotonic() + 5
            while not Path(spec['control'] + '.stubborn-ready').exists():
                if time.monotonic() >= until:
                    sys.exit(124)
                time.sleep(.01)
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
if mode == 'import-corrupt':
    # The command is successful, but the actual collector must refuse the
    # damaged payload. Recovery must retain its manifest pin, not compile anew.
    Path(state['target_statuses'][targets[0]]['path']).write_bytes(b'damaged transfer')
if mode != 'complete-hold-silent':
    print(json.dumps({'command':'build', 'status':'success', 'exit_code':0, 'details':{'manifest':str(manifest)}}), flush=True)
if mode == 'complete-hold-escaped':
    lock_path = str(Path(spec['control']).parent / 'run/lock')
    locks = []
    for descriptor in Path('/proc/self/fd').iterdir():
        try:
            if os.readlink(descriptor) == lock_path:
                locks.append(int(descriptor.name))
        except FileNotFoundError:
            pass
    assert locks, 'fixture driver did not inherit the coordinator lock'
    escaped = subprocess.Popen([sys.executable, '-c',
        'import ctypes,pathlib,sys,time; ctypes.CDLL(None).prctl(15,bytes([255])+b"dsr-writer",0,0,0); '
        'p=pathlib.Path(sys.argv[1]); pathlib.Path(str(p)+".ready").write_text("ready"); end=time.monotonic()+20; '
        '\nwhile not p.exists() and time.monotonic()<end: time.sleep(.02)'
        '\nif p.exists(): print("late stdout mutation",flush=True)',
        spec['control'] + '.late'], start_new_session=True, pass_fds=tuple(locks))
    until = time.monotonic() + 5
    while not Path(spec['control'] + '.late.ready').exists():
        if time.monotonic() >= until:
            sys.exit(124)
        time.sleep(.01)
    Path(spec['control'] + '.escaped').write_text(str(escaped.pid))
if mode.startswith('complete-hold'):
    Path(spec['control'] + '.completed').write_text('ready\n')
    until = time.monotonic() + 30
    while not Path(spec['control'] + '.release').exists():
        if time.monotonic() >= until:
            sys.exit(124)
        time.sleep(.03)
    if mode == 'complete-hold-nonzero':
        sys.exit(42)
    if mode == 'complete-hold-killed':
        os.kill(os.getpid(), 9)
''')
    # Keep actual shard import/admission intact; this explicit boundary fault
    # changes observed command evidence only after a real import completes.
    with (repo / 'src/release_bundle.sh').open('a') as stream:
        stream.write(r'''
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    original_import=$(declare -f _rb_import)
    eval "${original_import/_rb_import ()/_rb_test_original_import ()}"
    _rb_import() {
        _rb_test_original_import "$@" || return $?
        if [[ -n "${DSR_IMPORT_MUTATION_PATH:-}" ]]; then
            printf 'changed after real import\n' >> "$DSR_IMPORT_MUTATION_PATH"
        fi
    }
fi
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
    def invoke(case, expected=0, extra_env=None):
        proc = subprocess.run(['bash', str(script), '--plan', str(case / 'plan.json'), '--output-dir', str(case / 'run')],
                              env=dict(fixture_env, **(extra_env or {})), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
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

    # Kill the real coordinator before it can observe the native command's
    # terminal status. Its child still owns the coordinator lock and finishes
    # normally; a terminal checkpoint alone must never supply exit evidence.
    def crash_before_completion(case):
        with open(case / 'crash.stdout', 'wb') as out, open(case / 'crash.stderr', 'wb') as err:
            process = subprocess.Popen(['bash', str(script), '--plan', str(case / 'plan.json'),
                                        '--output-dir', str(case / 'run')], env=fixture_env,
                                       stdout=out, stderr=err, start_new_session=True)
            try:
                until = time.monotonic() + 15
                while time.monotonic() < until and not (case / 'control.completed').exists():
                    if process.poll() is not None:
                        break
                    time.sleep(.03)
                check(case.name + ': native targets complete before coordinator crash',
                      (case / 'control.completed').exists() and read(checkpoint(case))['status'] == 'completed')
                process.kill()
                check(case.name + ': coordinator really dies before acknowledging completion',
                      process.wait(timeout=5) == -signal.SIGKILL)
                record = read(case / 'run/state.json')['jobs']['native']
                check(case.name + ': crashed coordinator has no candidate or completed import',
                      record['candidate'] is None and record['complete'] is None and
                      record['attempts'][0]['status'] == 'running')
            finally:
                (case / 'control.release').write_text('finish\n')
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            until = time.monotonic() + 15
            lock_released = False
            with (case / 'run/lock').open('rb') as lock:
                while time.monotonic() < until:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        time.sleep(.03)
                    else:
                        lock_released = True
                        fcntl.flock(lock, fcntl.LOCK_UN)
                        break
            check(case.name + ': native command exits and releases its inherited lock', lock_released)

    case = fixture('coordinator-completion-crash', mode='complete-hold')
    crash_before_completion(case)
    previous_events = events(case)
    immutable = {p: p.read_bytes() for p in session(case).rglob('*') if p.is_file()}
    result = invoke(case)
    check('crashed completion recovers the same native attempt without compilation',
          result['bundle']['status'] == 'verified' and events(case) == previous_events and
          len(read(case / 'run/state.json')['jobs']['native']['attempts']) == 1)
    check('completion recovery preserves prior command, logs, checkpoint and artifacts',
          all(p.read_bytes() == contents for p, contents in immutable.items()))
    invoke(case)
    check('repeated completion recovery reuses the same admitted job',
          events(case) == previous_events and len(read(case / 'run/state.json')['jobs']['native']['attempts']) == 1)

    for mode in ('complete-hold-nonzero', 'complete-hold-killed', 'complete-hold-silent'):
        case = fixture(mode, mode=mode)
        crash_before_completion(case)
        previous_events = events(case)
        invoke(case, 1)
        record = read(case / 'run/state.json')['jobs']['native']
        check(mode + ': terminal native state cannot replace successful command evidence',
              record['candidate'] is None and record['complete'] is None and events(case) == previous_events and
              not (case / 'run/completed/native').exists())

    for label, mutate in (
        ('command', lambda c: write(session(c) / 'command.json', ['bash', '/different-driver'])),
        ('inputs', lambda c: write(session(c) / 'inputs.json', {})),
        ('stdout', lambda c: (session(c) / 'stdout.json').write_bytes((session(c) / 'stdout.json').read_bytes() + b'\n')),
        ('stderr', lambda c: (session(c) / 'stderr.log').write_bytes(b'changed diagnostics\n')),
        ('config', lambda c: overwrite(session(c) / 'config/config.yaml', '{}')),
        ('manifest', lambda c: write(session(c) / 'output/demo-v1.2.3-manifest.json', {})),
        ('checkpoint', lambda c: write(checkpoint(c), dict(read(checkpoint(c)), status='failed'))),
        ('receipt', lambda c: write(session(c) / 'driver-exit.json', dict(read(session(c) / 'driver-exit.json'), unknown=True))),
    ):
        case = fixture('completion-drift-' + label, mode='complete-hold')
        crash_before_completion(case)
        previous_events = events(case)
        mutate(case)
        invoke(case, 1)
        invoke(case, 1)
        record = read(case / 'run/state.json')['jobs']['native']
        check(label + ' drift keeps observed completion pinned and cannot trigger fresh compilation',
              record['complete'] is None and record['candidate'] is None and events(case) == previous_events and
              len(record['attempts']) == 1 and record['attempts'][0].get('completion_pending') is True)

    for linked in (False, True):
        case = fixture('completion-' + ('linked' if linked else 'missing') + '-receipt', mode='complete-hold')
        crash_before_completion(case)
        previous_events = events(case)
        original = session(case) / 'driver-exit.json'
        held = case / 'held-driver-exit.json'
        original.rename(held)
        if linked:
            original.symlink_to(held)
        invoke(case, 1)
        record = read(case / 'run/state.json')['jobs']['native']
        check(case.name + ': bare completed state cannot replace held original exit evidence',
              record['complete'] is None and record['candidate'] is None and events(case) == previous_events)

    case = fixture('completion-existing-observation', mode='complete-hold')
    crash_before_completion(case)
    write(session(case) / 'native-after.json', read(checkpoint(case)))
    observed = (session(case) / 'native-after.json').read_bytes()
    invoke(case)
    check('recovery accepts an identical already-retained native observation without replacing it',
          (session(case) / 'native-after.json').read_bytes() == observed and
          len([e for e in events(case) if e['event'] == 'invoke']) == 1)

    case = fixture('completion-import-mutation', mode='complete-hold')
    crash_before_completion(case)
    stderr = session(case) / 'stderr.log'
    original_stderr, previous_events = stderr.read_bytes(), events(case)
    invoke(case, 1, {'DSR_IMPORT_MUTATION_PATH': str(stderr)})
    record = read(case / 'run/state.json')['jobs']['native']
    check('evidence changed after real import cannot publish completed state',
          (case / 'run/completed/native').is_dir() and record['complete'] is None and
          record['candidate'] is not None and record['attempts'][0].get('completion_pending') is True)
    invoke(case, 1)
    check('existing import cannot bypass its rejected completion evidence on retry',
          read(case / 'run/state.json')['jobs']['native']['complete'] is None and events(case) == previous_events)
    original_output = session(case) / 'output'
    held_output = case / 'offline-output'
    original_output.rename(held_output)
    invoke(case, 1)
    check('offline original manifest cannot mask changed command logs',
          read(case / 'run/state.json')['jobs']['native']['complete'] is None and events(case) == previous_events)
    held_output.rename(original_output)
    stderr.write_bytes(original_stderr)
    manifest = original_output / 'demo-v1.2.3-manifest.json'
    original_manifest = manifest.read_bytes()
    manifest.write_text('{}')
    invoke(case, 1)
    check('retained import cannot mask a present but changed original manifest',
          read(case / 'run/state.json')['jobs']['native']['complete'] is None and events(case) == previous_events)
    manifest.write_bytes(original_manifest)
    original_output.rename(held_output)
    invoke(case)
    check('restored command evidence recovers the verified offline import without recompilation',
          events(case) == previous_events and len(read(case / 'run/state.json')['jobs']['native']['attempts']) == 1)

    case = fixture('escaped-writer', mode='complete-hold-escaped')
    try:
        crash_before_completion(case)
        pid = int((case / 'control.escaped').read_text())
        probe = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True)
        check('supervisor settles escaped stdout and lock holder before publishing receipt',
              probe.returncode != 0 or probe.stdout.strip().startswith(b'Z'))
        before = (session(case) / 'stdout.json').read_bytes()
        (case / 'control.late').write_text('write\n')
        invoke(case)
        check('escaped writer cannot mutate admitted completion output',
              (session(case) / 'stdout.json').read_bytes() == before and
              len([e for e in events(case) if e['event'] == 'invoke']) == 1)
    finally:
        (case / 'control.late').write_text('finish\n')

    case = fixture('stubborn-cancellation', mode='stubborn')
    with open(case / 'cancel.stdout', 'wb') as out, open(case / 'cancel.stderr', 'wb') as err:
        process = subprocess.Popen(['bash', str(script), '--plan', str(case / 'plan.json'),
                                    '--output-dir', str(case / 'run')], env=fixture_env, stdout=out, stderr=err)
        try:
            until = time.monotonic() + 15
            while time.monotonic() < until and not (case / 'control.pid').exists():
                time.sleep(.03)
            check('cancellation fixture starts an escaped signal-ignoring child', (case / 'control.pid').exists())
            started = time.monotonic()
            process.send_signal(signal.SIGTERM)
            check('supervisor cancellation settles inside the coordinator grace',
                  process.wait(timeout=7) == 5 and time.monotonic() - started < 6)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
    pid = int((case / 'control.pid').read_text())
    probe = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True)
    check('cancellation leaves no signal-ignoring escaped child', probe.returncode != 0 or probe.stdout.strip().startswith(b'Z'))
    (case / 'control').write_text('good')
    invoke(case)
    check('cancelled supervisor retains the existing native partial-target resume',
          len([e for e in events(case) if e['event'] == 'compile' and e['target'] == 'darwin/arm64']) == 1)
    if os.environ.get('DSR_BUILD_COMPLETION_ONLY') == '1':
        print(f'Native command completion recovery: {passes} passed, 0 failed', flush=True)
        print('Retained fixtures: ' + str(work), flush=True)
        sys.exit(0)

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
    no_launch(case, lambda:overwrite(session(case)/'config/config.yaml', '{}'), 'changed frozen config blocks resume')
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

    # A retained candidate is a distinct recovery phase: the native command
    # finished, but import failed or the coordinator lost its acknowledgement.
    def import_failure(label):
        case = fixture(label, mode='import-corrupt')
        invoke(case, 1)
        record = read(case/'run/state.json')['jobs']['native']
        check(label+': finished command has a selected candidate but no checkpoint',
              record['candidate'] is not None and record['complete'] is None and
              read(checkpoint(case))['status']=='completed' and not (case/'run/completed/native').exists())
        return case
    def repair_payload(case):
        (session(case)/'output/demo-darwin-arm64.bin').write_bytes(b'built native fixture darwin/arm64\n')
    case = import_failure('admission-retry')
    pin = read(case/'run/state.json')['jobs']['native']['candidate']['manifest_sha256']
    repair_payload(case)
    before = events(case)
    (case/'config').rename(case/'config-offline')
    invoke(case)
    record = read(case/'run/state.json')['jobs']['native']
    check('failed import recovers without any compiler invocation', events(case)==before and len(record['attempts'])==1)
    check('recovery preserves the selected manifest bytes and native UUID',
          sha(case/'run/completed/native/build-manifest.json')==pin and
          read(case/'run/completed/native/build-manifest.json')['run_id']==read(checkpoint(case))['run_id'])
    check('import recovery retains its own admission diagnostics',
          len(list(session(case).glob('admission-recovery-*/admission.log')))==1)
    invoke(case)
    check('recovered release retries remain compile-free', events(case)==before)

    case = import_failure('interrupted-import')
    repair_payload(case)
    # Simulate death after selecting the manifest, before import/acknowledgement.
    value = read(case/'run/state.json')
    value['jobs']['native']['attempts'][-1].update(status='running', exit_code=None)
    write(case/'run/state.json', value)
    before=events(case); invoke(case)
    check('interrupted candidate admission resumes instead of restarting the completed native run', events(case)==before)
    case = import_failure('still-corrupt')
    before=events(case); invoke(case,1)
    record=read(case/'run/state.json')['jobs']['native']
    check('continued corruption retains the pin and never falls back to compilation',
          events(case)==before and record['candidate'] is not None and len(record['attempts'])==1 and
          not (case/'run/completed/native').exists())
    for label, change in (
        ('candidate-manifest-drift', lambda c:(session(c)/'output/demo-v1.2.3-manifest.json').write_text('{}')),
        ('candidate-config-drift', lambda c:overwrite(session(c)/'config/config.yaml', '{}')),
        ('candidate-command-drift', lambda c:write(session(c)/'command.json', ['bash','/outside'])),
        ('candidate-input-drift', lambda c:write(session(c)/'inputs.json', {})),
        ('candidate-envelope-drift', lambda c:write(session(c)/'stdout.json', {'exit_code':0})),
        ('candidate-snapshot-drift', lambda c:write(session(c)/'native-after.json', {})),
        ('candidate-state-drift', lambda c:write(checkpoint(c), dict(read(checkpoint(c)), status='failed'))),
    ):
        case=import_failure(label); repair_payload(case)
        no_launch(case, lambda:change(case), label+' blocks adoption without a replacement build')
        check(label+': original candidate remains selected', read(case/'run/state.json')['jobs']['native']['candidate'] is not None)
    case=import_failure('candidate-path-drift'); repair_payload(case)
    value=read(case/'run/state.json'); value['jobs']['native']['candidate']['manifest']='/outside/manifest.json'
    no_launch(case, lambda:write(case/'run/state.json',value), 'candidate paths cannot redirect recovered import')

    # Interrupt a real native-driver process after it has checkpointed one
    # target. Resume must preserve that target and terminate its sleeper first.
    case=fixture('signal-resume', mode='slow')
    out=open(case/'cancel.stdout','wb'); err=open(case/'cancel.stderr','wb')
    process=subprocess.Popen(['bash',str(script),'--plan',str(case/'plan.json'),'--output-dir',str(case/'run')],
                             env=fixture_env,stdout=out,stderr=err)
    try:
        until=time.monotonic()+15
        while time.monotonic()<until and not (case/'control.pid').exists(): time.sleep(.03)
        check('signal test reaches native target checkpoint', (case/'control.pid').exists())
        identity=read(checkpoint(case))['run_id']
        saved=session(case)/'output/demo-darwin-arm64.bin'
        inode=saved.stat().st_ino
        process.send_signal(signal.SIGTERM)
        code=process.wait(timeout=10)
        check('native resume coordinator cancellation remains exit 5', code==5)
    finally:
        if process.poll() is None:
            process.terminate(); process.wait(timeout=10)
        out.close(); err.close()
    pid=(case/'control.pid').read_text().strip()
    status=Path('/proc')/pid/'stat'
    check('interrupted native descendants stop before recovery', not status.exists() or status.read_text().split(') ',1)[1].split()[0]=='Z')
    (case/'control').write_text('good'); invoke(case)
    check('interruption resumes the checkpointed UUID and retained successful target',
          read(checkpoint(case))['run_id']==identity and saved.stat().st_ino==inode and
          len([e for e in events(case) if e['event']=='compile' and e['target']=='darwin/arm64'])==1)

    case=fixture('disabled',resume=False); invoke(case,1); (case/'control').write_text('good'); invoke(case)
    check('disabled resume preserves fresh-attempt behavior', not any(a.startswith('--resume') for e in events(case) for a in e['args']))
    case=fixture('bad-option'); value=read(case/'plan.json'); value['builds'][0]['resume']='true'; write(case/'plan.json',value); invoke(case,4)
    check('resume policy must be a real boolean', not (case/'run').exists())
    print(f'\nNative build-plan resume: {passes} passed, 0 failed', flush=True)
except Exception:
    print('Retained failing fixtures: '+str(work), file=sys.stderr)
    raise
else:
    if os.environ.get('DSR_TEST_KEEP_TMP') == '1':
        print('Retained fixtures: ' + str(work), flush=True)
    else:
        shutil.rmtree(work)
PY
