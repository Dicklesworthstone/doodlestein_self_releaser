#!/usr/bin/env bash
# Genuine Go cross-compiled payloads and Git tags, with explicit native-state
# envelopes. No network, release writes, SSH or source/receipt validator mocks.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
command -v python3 >/dev/null && command -v go >/dev/null && command -v git >/dev/null || {
    printf 'SKIP: native recovery integration requires Python 3, Go and Git\n' >&2
    exit 77
}
python3 -I - "$ROOT" <<'PY'
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

root = Path(sys.argv[1])
module = root / 'src/release_recover_native.sh'
work = Path(tempfile.mkdtemp(prefix='dsr-native-recovery-'))
print('Evidence directory: ' + str(work), flush=True)
source, assets, states = work / 'source', work / 'artifacts', work / 'states'
for directory in (source, assets, states):
    directory.mkdir()
passed = failed = 0


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print('PASS ' + label, flush=True)
    else:
        failed += 1
        print('FAIL ' + label, file=sys.stderr, flush=True)


def run(command, **kwargs):
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, **kwargs).stdout


def git(*arguments):
    return run(['git', '-C', str(source), *arguments]).decode().strip()


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


git('init', '-q', '-b', 'main')
git('config', 'user.name', 'DSR recovery test')
git('config', 'user.email', 'recovery@example.invalid')
git('config', 'commit.gpgsign', 'false')
git('remote', 'add', 'origin', 'https://github.com/owner/demo.git')
(source / 'main.go').write_text('package main\nimport("fmt";"runtime")\nfunc main(){fmt.Println(runtime.GOOS+"/"+runtime.GOARCH)}\n')
git('add', 'main.go')
git('commit', '-qm', 'genuine cross-compiled recovery fixture')
commit = git('rev-parse', 'HEAD')
git('tag', 'v1.2.3')
platforms = ['linux/amd64', 'linux/arm64', 'darwin/amd64', 'darwin/arm64',
             'windows/amd64', 'windows/arm64', 'windows/386']
state = dict(tool='demo', version='1.2.3', run_id=str(uuid.uuid4()), status='failed',
             git_sha=commit, git_ref='refs/tags/v1.2.3', targets=platforms, target_statuses={},
             context=dict(build_purpose='release', publishable=True, build_tasks=[],
                          target_hosts={p: 'cross-host' for p in platforms}))
environment = os.environ.copy()
environment.update(CGO_ENABLED='0', GOENV='off', GOTOOLCHAIN='local', GOPROXY='off',
                   GOSUMDB='off', GO111MODULE='off', GOCACHE=str(work / 'go-cache'))
for platform in platforms:
    operating_system, architecture = platform.split('/')
    directory = assets / platform.replace('/', '-')
    directory.mkdir()
    binary = directory / ('demo.exe' if operating_system == 'windows' else 'demo')
    env = dict(environment, GOOS=operating_system, GOARCH=architecture)
    print('Compiling genuine Go payload: ' + platform, flush=True)
    run(['go', 'build', '-trimpath', '-o', str(binary), str(source / 'main.go')], env=env, timeout=180)
    binary.chmod(0o600 if operating_system == 'windows' else 0o700)
    info = binary.stat()
    receipt = dict(path=str(binary), sha256=sha(binary.read_bytes()), size_bytes=info.st_size,
                   identity='gnu:%d:%d' % (info.st_dev, info.st_ino))
    task = dict(key=platform, platform=platform, target_triple='', method='native')
    result = dict(tool='demo', platform=platform, host='cross-host', task_key=platform, target_triple=None,
        status='success', exit_code=0, method='native', build_purpose='release', publishable=True,
        artifact_path=str(binary), artifact_paths=[str(binary)], additional_artifacts=[], resume_artifacts=[receipt],
        build_influence_env={'GOOS': operating_system, 'GOARCH': architecture}, cargo_isolation=None)
    state['context']['build_tasks'].append(task)
    state['target_statuses'][platform] = dict(status='completed', host='cross-host', result=result,
        updated_at=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))

counter = 0


def invoke(value=None, arguments=None, raw=None, output=None, expected_hash=None):
    global counter
    counter += 1
    selected_state = states / ('state-%d.json' % counter)
    data = encoded(state if value is None else value) if raw is None else raw
    selected_state.write_bytes(data)
    output = work / ('recovered-%d' % counter) if output is None else output
    command = ['bash', str(module), '--state', str(selected_state), '--state-sha256', expected_hash or sha(data),
               '--source-repo', str(source), '--repo', 'owner/demo', '--tag', 'v1.2.3', '--sha', commit,
               '--artifacts-root', str(assets), '--output-dir', str(output)]
    command += arguments or []
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    (work / ('run-%d.stdout' % counter)).write_bytes(result.stdout)
    (work / ('run-%d.stderr' % counter)).write_bytes(result.stderr)
    try:
        response = json.loads(result.stdout)
    except (ValueError, UnicodeError):
        response = {}
    return result.returncode, response, output, selected_state

status, response, output, selected_state = invoke()
check('seven completed native targets recover after failed coordinator packaging', status == 0 and response.get('recovered_targets') == 7)
if status:
    print((work / ('run-%d.stderr' % counter)).read_text(), file=sys.stderr)
    raise SystemExit(1)
release = output / 'release'
manifest = json.loads((release / 'build-manifest.json').read_bytes())
check('all same-basename binaries have distinct published manifest names', len({a['name'].casefold() for a in manifest['artifacts']}) == 7)
check('every scheduling target survives manifest generation', {a['target'] for a in manifest['artifacts']} == set(platforms))
check('manifest digest matches retained bytes', response['manifest_sha256'] == sha((release / 'build-manifest.json').read_bytes()))
check('original failed build state is retained byte-for-byte', (release / 'inputs/state.json').read_bytes() == selected_state.read_bytes())
check('recovery does not rewrite original state or claim strict source verification',
      json.loads(selected_state.read_bytes())['status'] == 'failed' and response['strict_source_verified'] is False and
      manifest['recovery_evidence']['source_verification'] == 'tag-identity-only')
check('native build environments are preserved for every target',
      {e['target']: e['build_influence_env'] for e in manifest['build_environments']} ==
      {p: state['target_statuses'][p]['result']['build_influence_env'] for p in platforms})
exact = True
for artifact in manifest['artifacts']:
    original = Path(state['target_statuses'][artifact['target']]['result']['artifact_path'])
    recovered = release / 'artifacts' / artifact['name']
    exact &= recovered.read_bytes() == original.read_bytes() and recovered.stat().st_ino != original.stat().st_ino
    exact &= sha(recovered.read_bytes()) == artifact['sha256'] and recovered.stat().st_size == artifact['size_bytes']
check('all raw bytes match their own worker receipts without hardlinks', exact)
check('recovered Linux executable runs with the expected target', run([str(release / 'artifacts/demo-linux_amd64')]).decode().strip() == 'linux/amd64')
check('source tag and checkout stay untouched', git('rev-parse', 'refs/tags/v1.2.3') == commit and not git('status', '--porcelain'))
check('build time comes from completed checkpoints, not the recovery clock',
      manifest['built_at'] == max(s['updated_at'] for s in state['target_statuses'].values()))
status, response, planned, _ = invoke(arguments=['--dry-run'])
check('dry-run validates every target without creating output', status == 0 and response.get('status') == 'planned' and
      len(response.get('artifacts', [])) == 7 and not planned.exists())


def refuse(label, value=None, code=None, **kwargs):
    status, response, destination, _ = invoke(value, **kwargs)
    check(label, status != 0 and (code is None or status == code) and
          response.get('exit_code') == status and response.get('status') == 'error' and not (destination / 'release').exists())


refuse('wrong state digest refuses before output', expected_hash='0' * 64, code=7)
for build_status in ('running', 'pending', 'cancelled'):
    candidate = copy.deepcopy(state)
    candidate['status'] = build_status
    refuse(build_status + ' runs cannot be recovered', candidate, code=2)
for field, value in [('build_purpose', 'diagnostic-native'), ('publishable', False)]:
    candidate = copy.deepcopy(state)
    candidate['context'][field] = value
    refuse('nonrelease context cannot be promoted: ' + field, candidate, code=4)
for field, value in [('status', 'failed'), ('exit_code', 6), ('publishable', False), ('method', 'act'),
                     ('task_key', 'other'), ('host', 'other'), ('target_triple', 'aarch64-unknown-linux-gnu')]:
    candidate = copy.deepcopy(state)
    candidate['target_statuses']['linux/amd64']['result'][field] = value
    refuse('invalid completed worker refuses: ' + field, candidate, code=4)
candidate = copy.deepcopy(state)
candidate['target_statuses'].pop('darwin/arm64')
refuse('omitted Apple Silicon worker cannot yield a smaller release', candidate, code=4)
candidate = copy.deepcopy(state)
candidate['context']['build_tasks'].append(copy.deepcopy(candidate['context']['build_tasks'][0]))
refuse('duplicate planned target refuses', candidate, code=4)
candidate = copy.deepcopy(state)
candidate['target_statuses']['linux/amd64']['result']['cargo_isolation'] = {'mode': 'strict-release-snapshot'}
refuse('strict builds cannot be downgraded through ordinary recovery', candidate, code=4)
for field, value in [('sha256', '0' * 64), ('size_bytes', 1), ('identity', 'gnu:0:1')]:
    candidate = copy.deepcopy(state)
    candidate['target_statuses']['linux/amd64']['result']['resume_artifacts'][0][field] = value
    refuse('changed artifact receipt refuses: ' + field, candidate, code=7)
candidate = copy.deepcopy(state)
record = candidate['target_statuses']['linux/amd64']['result']
other = state['target_statuses']['linux/arm64']['result']
record['resume_artifacts'] = copy.deepcopy(other['resume_artifacts'])
record['artifact_path'], record['artifact_paths'] = other['artifact_path'], other['artifact_paths']
refuse('one physical payload cannot be reused by two targets', candidate, code=4)
candidate = copy.deepcopy(state)
candidate['target_statuses']['linux/amd64']['result']['artifact_path'] += '-unbound'
refuse('worker inventory cannot differ from resume receipt', candidate, code=4)
refuse('duplicate JSON members refuse', raw=encoded(state)[:-2] + b',"status":"completed"}\n', code=4)
refuse('duplicate CLI options refuse', arguments=['--repo', 'elsewhere/demo'], code=4)
refuse('byte limits cannot silently omit a target', arguments=['--max-artifact-bytes', '1'], code=4)
old = (release / 'build-manifest.json').read_bytes()
status, _, _, _ = invoke(output=output)
check('existing output is never overwritten', status == 2 and old == (release / 'build-manifest.json').read_bytes())

git('remote', 'set-url', 'origin', 'https://github.com/someone/else.git')
refuse('repository substitution refuses', code=4)
git('remote', 'set-url', 'origin', 'https://github.com/owner/demo.git')
candidate = copy.deepcopy(state)
candidate['git_sha'] = '1' * 40
refuse('source commit substitution refuses', candidate, code=4)
original = Path(state['target_statuses']['linux/amd64']['result']['artifact_path'])
backup = original.read_bytes()
with original.open('r+b') as stream:
    stream.seek(-1, os.SEEK_END)
    stream.write(bytes([backup[-1] ^ 1]))
refuse('changed payload bytes cannot be reblessed', code=7)
with original.open('wb') as stream:
    stream.write(backup)
os.link(original, work / 'hardlinked-payload')
refuse('hardlinked source custody refuses', code=7)
# Keep evidence instead of deleting fixture files.
original.rename(work / 'retained-original-hardlink')
original.write_bytes(backup)
original.chmod(0o700)
refuse('byte-identical replacement cannot satisfy the frozen inode', code=7)

print('Native raw recovery: %d passed, %d failed; evidence: %s' % (passed, failed, work), flush=True)
raise SystemExit(1 if failed else 0)
PY
