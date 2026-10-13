#!/usr/bin/env bash
# Full audited sync + recovery; actual local Git operations, branches and hooks.
# Only GitHub HTTP/authentication and selected process failures use adapters.
# No live push, repository deletion, source compilation or installer execution.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
exec python3 -I -S - "$ROOT" <<'PY'
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
work = Path(tempfile.mkdtemp(prefix='dsr-delivery-recovery-')).resolve()
print('Recovery test evidence retained: ' + str(work), flush=True)
bins = work / 'bin'; bins.mkdir()
checks = failures = cases = 0
actual_git = shutil.which('git')

def check(label, condition):
    global checks, failures
    checks += 1; failures += not condition
    print(('ok ' if condition else 'not ok ') + str(checks) + ' - ' + label, flush=True)

def hashed(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True) + '\n')

def git(env, *args):
    value = subprocess.run([actual_git, *map(str, args)], env=env, capture_output=True, timeout=15)
    if value.returncode:
        raise AssertionError(value.stderr.decode())
    return value.stdout.decode().strip()

(bins / 'curl').write_text(r'''#!/usr/bin/env -S python3 -I -S
import json,os,pathlib,sys,time
from urllib.parse import urlsplit
args=sys.argv[1:]
if args==['--disable','--version']:
    print('curl 8.10.1 (explicit HTTP fixture)'); raise SystemExit(0)
case=pathlib.Path(os.environ['CASE']); url=urlsplit(args[-1]); policy=sys.stdin.read()
assert url.scheme=='https' and url.netloc=='api.github.com' and '--fail' in args
assert 'Authorization: Bearer fixture-token' in policy and 'fixture-token' not in ' '.join(args)
with (case/'http.jsonl').open('a') as out: out.write(json.dumps({'path':url.path,'query':url.query})+'\n')
if os.environ.get('RECOVERY_ACTIVE')=='1':
    mode=os.environ.get('RECOVERY_MODE','')
    if mode=='network': raise SystemExit(22)
    if mode=='hang':
        (case/'blocked.pid').write_text(str(os.getpid()))
        time.sleep(60)
    if mode=='pause':
        (case/'paused').touch()
        for i in range(300):
            if (case/'continue').exists(): break
            time.sleep(.05)
    if mode=='head-move' and not (case/'moved').exists():
        import subprocess
        result=json.loads((case/'original.json').read_text()); checkout=result['results'][0]['checkout']
        subprocess.run([os.environ['ACTUAL_GIT'],'-C',checkout,'commit','--allow-empty','-m','independent writer'],check=True,stdout=subprocess.DEVNULL)
        (case/'moved').touch()
if '/releases/tags/' in url.path:
    body=(case/'release.json').read_bytes()
elif url.path.endswith('/assets'):
    body=(case/'assets.json').read_bytes()
else:
    body=(case/'bytes'/url.path.rsplit('/',1)[1]).read_bytes()
assert len(body)<=int(args[args.index('--max-filesize')+1])
pathlib.Path(args[args.index('--output')+1]).write_bytes(body)
''')
(bins / 'git').write_text('#!' + sys.executable + '\n' + r'''
import json,os,pathlib,subprocess,sys
args=sys.argv[1:]; case=pathlib.Path(os.environ['CASE'])
with (case/'git.jsonl').open('a') as out: out.write(json.dumps(args)+'\n')
code=subprocess.run([os.environ['ACTUAL_GIT'],*args]).returncode
# Genuine successful local push followed by a substituted lost acknowledgement.
if 'push' in args and code==0 and os.environ.get('RECOVERY_MODE')=='lost-ack':
    raise SystemExit(128)
raise SystemExit(code)
''')
for p in bins.iterdir(): p.chmod(0o755)

def setup(label):
    global cases
    cases += 1
    case = work / ('%02d-' % cases + label); case.mkdir()
    for name in ('tmp', 'home', 'bytes', 'remotes'):
        (case / name).mkdir()
    (case / 'git.jsonl').touch(); (case / 'http.jsonl').touch()
    env = {k:v for k,v in os.environ.items() if not k.startswith(('GIT_', 'BASH_FUNC_')) and k not in
           ('ENV', 'BASH_ENV', 'GH_TOKEN', 'GITHUB_TOKEN', 'DSR_GH_TOKEN')}
    env.update(HOME=str(case / 'home'), TMPDIR=str(case / 'tmp'), DSR_STATE_DIR=str(case / 'state'),
               CASE=str(case), ACTUAL_GIT=actual_git, PATH=str(bins) + os.pathsep + '/usr/bin:/bin:' + os.environ['PATH'],
               GIT_CONFIG_GLOBAL=str(case / 'gitconfig'), GIT_CONFIG_NOSYSTEM='1', DSR_GH_TOKEN='fixture-token')
    (case / 'gitconfig').write_text('[user]\n name = Recovery Test\n email = recovery@example.invalid\n'
        '[commit]\n gpgsign = false\n[push]\n followTags = true\n')
    seed = case / 'seed'
    git(env, 'init', '-b', 'main', seed)
    (seed / 'README').write_text('unchanged source\n')
    (seed / 'SHA256SUMS.txt').write_text('prior checksum file\n')
    git(env, '-C', seed, 'add', '.'); git(env, '-C', seed, 'commit', '-m', 'seed')
    remote = case / 'remotes/a.git'
    git(env, 'clone', '--bare', seed, remote)
    with (case / 'gitconfig').open('a') as out:
        out.write('[url "' + (case / 'remotes').as_uri() + '/"]\n insteadOf = https://github.com/owner/\n')
    hook = remote / 'hooks/pre-receive'
    hook.write_text('#!/bin/sh\n[ "${RECOVERY_MODE:-}" != reject ]\n'); hook.chmod(0o755)
    assets = []
    payload = b'real fixture payload bytes\n' * 10
    for index, name, content in ((1, 'tool.tar.gz', payload), (2, 'tool.tar.gz.sha256', hashlib.sha256(payload).hexdigest().encode() + b'\n')):
        (case / 'bytes' / str(index)).write_bytes(content)
        assets.append(dict(id=index, name=name, size=len(content), state='uploaded', digest='sha256:' + hashlib.sha256(content).hexdigest()))
    write_json(case / 'assets.json', assets)
    write_json(case / 'release.json', dict(id=42, tag_name='v1.2.3', draft=False, prerelease=False, target_commitish='main'))
    proc = subprocess.run(['bash', root / 'src/checksum_sync.sh', 'sync', 'tool', '1.2.3', '--repo', 'owner/tool',
        '--target-repo', 'owner/a', '--verify-release', '--checksum-mode', 'sidecars', '--json'],
        env=env, capture_output=True, timeout=60)
    (case / 'original.json').write_bytes(proc.stdout); (case / 'sync.stderr').write_bytes(proc.stderr)
    need = json.loads(proc.stdout)
    if proc.returncode != 0 or not need['results'][0].get('committed'):
        raise AssertionError('real audited local-commit setup failed: ' + proc.stderr.decode())
    env['RECOVERY_ACTIVE'] = '1'
    return case, env, need

def command(case, *, push=False, result=None, pin=None, output=None, target='owner/a', timeout=15):
    source = result or case / 'original.json'
    target_dir = output or case / ('recovery-%02d' % len(list(case.glob('recovery-*'))))
    cmd = ['bash', root / 'src/checksum_sync_recover.sh', '--result', source, '--result-sha256', pin or hashed(source),
           '--target-repo', target, '--output-dir', target_dir, '--timeout', str(timeout)]
    if push: cmd.append('--push')
    return cmd

def recover(case, env, **kwargs):
    proc = subprocess.run(command(case, **kwargs), env=env, capture_output=True, timeout=90)
    index = len(list(case.glob('call-*.json')))
    (case / ('call-%02d.json' % index)).write_bytes(proc.stdout)
    (case / ('call-%02d.stderr' % index)).write_bytes(proc.stderr)
    try: result = json.loads(proc.stdout)
    except ValueError: result = {}
    if result.get('exit_code') != proc.returncode:
        print(proc.stderr.decode(), flush=True)
    return proc, result

def tip(case, env):
    return git(env, '--git-dir', case / 'remotes/a.git', 'rev-parse', 'refs/heads/main')

def pushes(case):
    return [json.loads(line) for line in (case / 'git.jsonl').read_text().splitlines() if 'push' in json.loads(line)]

def binaries(case):
    return sum('/releases/assets/' in json.loads(line)['path'] for line in (case / 'http.jsonl').read_text().splitlines())

case, env, original = setup('pending-and-idempotent')
row = original['results'][0]; checkout = Path(row['checkout']); ws = Path(original['workspace'])
held = {p: hashed(p) for p in (case / 'original.json', ws / 'audit-result.json', ws / 'manifest', ws / 'audit/result.json')}
proc, result = recover(case, env)
check('default recovery checks without pushing', proc.returncode == 0 and result.get('status') == 'ready' and
      result.get('delivery_confirmed') is False and not pushes(case) and tip(case, env) == row['previous_commit'])
check('read-only reconciliation repeats no payload acquisitions', binaries(case) == 2)
git(env, '-C', checkout, 'tag', '-a', 'unselected-v1', '-m', 'do not publish')
proc, result = recover(case, env, push=True)
check('explicit recovery publishes the exact retained commit', proc.returncode == 0 and result.get('status') == 'pushed' and
      result.get('push_outcome') == 'acknowledged' and result.get('delivery_confirmed') is True and tip(case, env) == row['commit'])
check('recovery never creates another local commit', git(env, '-C', checkout, 'rev-parse', 'HEAD') == row['commit'])
check('operator followTags cannot add annotated release tags', git(env, '--git-dir', case / 'remotes/a.git', 'tag') == '')
check('push uses an exact SHA, one branch, no mirror, and no force', len(pushes(case)) == 1 and
      row['commit'] + ':' + row['branch'] in pushes(case)[0] and '--no-follow-tags' in pushes(case)[0] and
      '--no-mirror' in pushes(case)[0] and not any(x.startswith('--force') for x in pushes(case)[0]))
proc, result = recover(case, env, push=True)
check('repeated explicit recovery reconciles without another push', proc.returncode == 0 and
      result.get('status') == 'already-applied' and result.get('push_attempted') is False and len(pushes(case)) == 1)
check('original audit/export/result bytes remain unchanged', all(hashed(p) == v for p, v in held.items()))
check('recovery evidence and final JSON agree', Path(result['output_dir'], 'result.json').read_bytes() == proc.stdout)
check('all recovery attempts use metadata only on the network', binaries(case) == 2)

case, env, original = setup('lost-acknowledgement')
env['RECOVERY_MODE'] = 'lost-ack'
proc, result = recover(case, env, push=True)
check('lost push acknowledgement is reconciled from the real remote tip', proc.returncode == 0 and
      result.get('status') == 'reconciled' and result.get('push_exit_code') == 128 and
      result.get('push_outcome') == 'uncertain' and result.get('delivery_confirmed') is True and len(pushes(case)) == 1)
check('attempt retains intent before the acknowledged-or-uncertain push',
      json.loads(Path(result['output_dir'], 'push-intent.json').read_text())['commit'] == original['results'][0]['commit'])
proc, result = recover(case, env, push=True)
check('a second lost-ack recovery never resubmits the satisfied commit', proc.returncode == 0 and
      result.get('status') == 'already-applied' and len(pushes(case)) == 1)

case, env, original = setup('server-rejection')
env['RECOVERY_MODE'] = 'reject'
proc, result = recover(case, env, push=True)
check('real server rejection keeps the acknowledged local commit and returns nonzero', proc.returncode == 8 and
      result.get('push_outcome') == 'uncertain' and result.get('delivery_confirmed') is False and
      tip(case, env) == original['results'][0]['previous_commit'])
old_evidence = Path(result['output_dir'], 'result.json').read_bytes()
env['RECOVERY_MODE'] = ''
proc, result = recover(case, env, push=True)
check('explicit retry after server repair pushes the same commit once', proc.returncode == 0 and
      result.get('status') == 'pushed' and tip(case, env) == original['results'][0]['commit'] and len(pushes(case)) == 2)
check('retry preserves failed recovery receipt', (case / 'recovery-00/result.json').read_bytes() == old_evidence)

for label in ('wrong-pin', 'unknown-target', 'uncertain-commit', 'unaudited', 'duplicate-json', 'linked-result',
              'overlap', 'corrupt-payload', 'corrupt-proof', 'corrupt-export', 'tracked-edit', 'changed-head',
              'extra-commit-path', 'foreign-origin', 'extra-pushurl', 'remote-drift', 'release-drift', 'network', 'head-move', 'busy-lock'):
    case, env, original = setup(label)
    row = original['results'][0]; checkout = Path(row['checkout']); workspace = Path(original['workspace'])
    kwargs = dict(push=True); handle = None
    before = tip(case, env)
    if label == 'wrong-pin': kwargs['pin'] = '0' * 64
    elif label == 'unknown-target': kwargs['target'] = 'owner/absent'
    elif label in ('uncertain-commit', 'unaudited'):
        if label == 'uncertain-commit': original['results'][0]['commit_outcome'] = 'uncertain'
        else: original['source']['kind'] = 'provided_manifest'
        altered = case / 'altered.json'; write_json(altered, original); kwargs['result'] = altered
    elif label == 'duplicate-json':
        altered = case / 'duplicate.json'; altered.write_bytes((case / 'original.json').read_bytes().rstrip()[:-1] + b',"status":"success"}\n'); kwargs['result'] = altered
    elif label == 'linked-result':
        altered = case / 'linked.json'; altered.symlink_to(case / 'original.json'); kwargs['result'] = altered
    elif label == 'overlap': kwargs['output'] = workspace / 'new-recovery'
    elif label.startswith('corrupt-'):
        name = {'corrupt-payload':'audit/artifacts/tool.tar.gz','corrupt-proof':'audit/evidence/tool.tar.gz.sha256',
                'corrupt-export':'manifest'}[label]
        with (workspace / name).open('ab') as out: out.write(b'corruption')
    elif label == 'tracked-edit': (checkout / 'README').write_text('unrelated tracked edit\n')
    elif label in ('changed-head', 'extra-commit-path'):
        (checkout / 'README').write_text('independent commit\n')
        git(env, '-C', checkout, 'add', 'README'); git(env, '-C', checkout, 'commit', '-m', 'independent')
        if label == 'extra-commit-path':
            row['previous_commit'] = row['commit']; row['commit'] = git(env, '-C', checkout, 'rev-parse', 'HEAD')
            altered = case / 'altered.json'; write_json(altered, original); kwargs['result'] = altered
    elif label == 'foreign-origin': git(env, '-C', checkout, 'config', 'remote.origin.url', 'https://github.com/owner/foreign.git')
    elif label == 'extra-pushurl': git(env, '-C', checkout, 'config', 'remote.origin.pushurl', str(case / 'remotes/a.git'))
    elif label == 'remote-drift':
        (case / 'seed/README').write_text('independent remote change\n')
        git(env, '-C', case / 'seed', 'add', 'README'); git(env, '-C', case / 'seed', 'commit', '-m', 'remote change')
        git(env, '-C', case / 'seed', 'push', str(case / 'remotes/a.git'), 'HEAD:refs/heads/main')
        before = tip(case, env)
    elif label == 'release-drift':
        assets = json.loads((case / 'assets.json').read_text()); assets[0]['id'] = 999; write_json(case / 'assets.json', assets)
    elif label in ('network', 'head-move'): env['RECOVERY_MODE'] = label
    elif label == 'busy-lock':
        handle = os.open(workspace / '.recovery-target-1.lock', os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    proc, result = recover(case, env, **kwargs)
    if handle is not None: os.close(handle)
    check(label + ' refuses before any push and preserves the remote branch', proc.returncode != 0 and
          result.get('exit_code') == proc.returncode and result.get('delivery_confirmed') is False and
          not pushes(case) and tip(case, env) == before)

case, env, original = setup('cancel-owned-transport')
env['RECOVERY_MODE'] = 'hang'
proc = subprocess.Popen(command(case, push=True, timeout=20), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        start_new_session=True)
for _ in range(200):
    if (case / 'blocked.pid').exists() or proc.poll() is not None: break
    time.sleep(.05)
blocked = int((case / 'blocked.pid').read_text()) if (case / 'blocked.pid').exists() else None
proc.send_signal(signal.SIGTERM)
stdout, stderr = proc.communicate(timeout=15)
(case / 'cancel.stdout').write_bytes(stdout); (case / 'cancel.stderr').write_bytes(stderr)
result = json.loads(stdout) if stdout else {}
def alive(pid):
    if pid is None: return False
    try:
        os.kill(pid, 0)
        if Path('/proc', str(pid), 'stat').exists():
            return Path('/proc', str(pid), 'stat').read_text().split(') ', 1)[1][0] != 'Z'
        return True
    except ProcessLookupError: return False
check('parent-only cancellation returns one nonzero receipt', blocked is not None and proc.returncode == 5 and
      result.get('exit_code') == 5 and not pushes(case))
check('cancellation reaps the auditor-owned separately grouped transport', not alive(blocked))
# The persistent lock must be usable after cancellation; do not remove it.
env['RECOVERY_MODE'] = ''
proc, result = recover(case, env)
check('new recovery works after cancellation without deleting a lock', proc.returncode == 0 and result.get('status') == 'ready')

print('Recovery checks: %d passed, %d failed' % (checks - failures, failures), flush=True)
raise SystemExit(1 if failures else 0)
PY
