#!/usr/bin/env bash
# Real copy interruption, file-size exhaustion, locking and retained-checkpoint
# recovery. Git and Go are genuine; only saved native-worker metadata is a fixture.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
command -v python3 >/dev/null && command -v go >/dev/null && command -v git >/dev/null || exit 77
[[ $(uname -s) == Linux ]] || { echo 'SKIP: interruption integration requires Linux' >&2; exit 77; }
python3 -I - "$ROOT" <<'PY'
import copy
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import resource
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import uuid

module = Path(sys.argv[1]) / 'src/release_recover_native.sh'
work = Path(tempfile.mkdtemp(prefix='dsr-recovery-resume-'))
print('Evidence: ' + str(work), flush=True)
source, assets = work / 'source', work / 'artifacts'
source.mkdir()
assets.mkdir()
passed = 0


def check(label, ok):
    global passed
    if not ok:
        raise AssertionError(label)
    passed += 1
    print('PASS ' + label, flush=True)


def run(*command, **kwargs):
    return subprocess.run(list(map(str, command)), check=True, capture_output=True, timeout=180, **kwargs).stdout


def git(*args):
    return run('git', '-C', source, *args).decode().strip()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def snapshot(directory, files_only=False):
    values = {}
    for item in [directory, *sorted(directory.rglob('*'))]:
        info = item.lstat()
        if files_only and item.is_dir():
            continue
        values[str(item.relative_to(directory))] = (
            info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns,
            digest(item.read_bytes()) if item.is_file() and not item.is_symlink() else None)
    return values


arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(platform.machine())
if arch is None:
    raise SystemExit(77)
target = 'linux/' + arch
git('init', '-q', '-b', 'main')
git('config', 'user.name', 'DSR resume test')
git('config', 'user.email', 'resume@example.invalid')
git('config', 'commit.gpgsign', 'false')
git('remote', 'add', 'origin', 'https://github.com/owner/demo.git')
(source / 'main.go').write_text('package main\nimport "fmt"\nfunc main(){fmt.Println("recovered without recompilation")}\n')
git('add', 'main.go')
git('commit', '-qm', 'real compiler resume fixture')
commit = git('rev-parse', 'HEAD')
git('tag', 'v1.2.3')
env = dict(os.environ, CGO_ENABLED='0', GOOS='linux', GOARCH=arch, GOENV='off', GOTOOLCHAIN='local',
           GOPROXY='off', GOSUMDB='off', GO111MODULE='off',
           GOCACHE=os.environ.get('DSR_RECOVERY_TEST_GOCACHE', str(work / 'go-cache')))
first, second, archive, notice = (assets / name for name in ('a-demo', 'b-demo', 'c-bundle.tar.gz', 'NOTICE'))
run('go', 'build', '-trimpath', '-o', first, source / 'main.go', env=env)
first.chmod(0o755)
binary = first.read_bytes()
# Trailing padding makes the second genuine ELF larger than the kernel's
# per-file write limit. It does not replace the executable header or compiler.
second.write_bytes(binary + b'\0' * (4 * 1024 * 1024))
second.chmod(0o751)
with tarfile.open(archive, 'w:gz') as tf:
    item = tarfile.TarInfo('demo')
    item.mode, item.size = 0o755, len(binary)
    tf.addfile(item, io.BytesIO(binary))
notice.write_text('retained shared notice\n')


def receipt(selected):
    info = selected.stat()
    return dict(path=str(selected), sha256=digest(selected.read_bytes()), size_bytes=info.st_size,
                identity='gnu:%d:%d' % (info.st_dev, info.st_ino))


primary = [str(p) for p in (first, second, archive)]
result = dict(tool='demo', platform=target, host='fixture', task_key=target, target_triple=None,
              status='success', exit_code=0, method='native', build_purpose='release', publishable=True,
              artifact_path=','.join(primary), artifact_paths=primary, additional_artifacts=[receipt(notice)],
              resume_artifacts=[receipt(p) for p in (first, second, archive, notice)],
              build_influence_env={'GOOS': 'linux', 'GOARCH': arch}, cargo_isolation=None)
state = dict(tool='demo', version='1.2.3', run_id=str(uuid.uuid4()), status='targets-complete',
             git_sha=commit, git_ref='refs/tags/v1.2.3', targets=[target],
             target_statuses={target: dict(status='completed', host='fixture', result=result,
                                          updated_at='2026-10-01T12:00:00Z')},
             context=dict(build_purpose='release', publishable=True, target_hosts={target: 'fixture'},
                          build_tasks=[dict(key=target, platform=target, target_triple='', method='native')]))
states = work / 'states'
states.mkdir()
state_file = states / 'state.json'
state_file.write_bytes(encoded(state))
source_before = snapshot(assets)
state_before = state_file.read_bytes()
sequence = 0


def invoke(output, *flags, limit=None, environment=None, selected_module=None, selected_state=None):
    global sequence
    sequence += 1
    selected_state = selected_state or state_file
    command = ['bash', str(selected_module or module), '--state', str(selected_state),
               '--state-sha256', digest(selected_state.read_bytes()), '--source-repo', str(source),
               '--repo', 'owner/demo', '--tag', 'v1.2.3', '--sha', commit,
               '--artifacts-root', str(assets), '--output-dir', str(output), *flags]
    def bounded_write():
        resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))
    p = subprocess.run(command, capture_output=True, timeout=90, env=environment,
                       preexec_fn=bounded_write if limit is not None else None)
    (work / ('run-%d.stdout' % sequence)).write_bytes(p.stdout)
    (work / ('run-%d.stderr' % sequence)).write_bytes(p.stderr)
    value = json.loads(p.stdout)
    return p.returncode, value


interrupted = work / 'interrupted'
code, value = invoke(interrupted, limit=len(binary) + 65536)
check('real file-size exhaustion cannot publish a partial release', code == 4 and
      'File too large' in value.get('error', '') and not (interrupted / 'release').exists())
check('interrupted recovery retains an explicit pinned plan', (interrupted / 'plan.json').is_file())
plan = json.loads((interrupted / 'plan.json').read_bytes())
stage = interrupted / plan['stage']
first_name = 'a-demo-' + target.replace('/', '_')
check('completed first payload survives the failed second copy',
      (stage / 'artifacts' / first_name).read_bytes() == binary and
      {p.name for p in (stage / 'artifacts').iterdir()} == {first_name, 'NOTICE'})
check('truncated bytes remain private instead of taking a completed asset name',
      any(0 < p.stat().st_size < second.stat().st_size for p in (interrupted / '.partial').iterdir()))
before = snapshot(interrupted)
code, value = invoke(interrupted, '--resume', '--dry-run')
check('partial dry-run validates existing bytes without filling missing files',
      code == 0 and value['status'] == 'planned' and len(value['artifacts']) == 4 and snapshot(interrupted) == before)
code, _ = invoke(interrupted)
check('an interrupted workspace still requires explicit resume', code == 2 and snapshot(interrupted) == before)
lock = os.open(interrupted, os.O_RDONLY | os.O_DIRECTORY)
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    code, value = invoke(interrupted, '--resume')
    check('a second process cannot use the active recovery directory',
          code == 2 and 'already in use' in value['error'] and snapshot(interrupted) == before)
finally:
    os.close(lock)
partial_baseline = os.environ.get('DSR_RECOVERY_PARTIAL_BASELINE')
if partial_baseline:
    code, value = invoke(interrupted, '--resume', selected_module=partial_baseline)
    check('unchanged completed-only implementation cannot resume this interrupted copy',
          code == 2 and 'not a complete recovery' in value['error'] and snapshot(interrupted) == before)


def cloned(label):
    destination = work / label
    shutil.copytree(interrupted, destination)
    return destination, destination / plan['stage']


def refused(label, mutate, flags=('--resume',), changed_state=None):
    destination, selected = cloned('refused-' + str(sequence))
    mutate(destination, selected)
    held = snapshot(destination)
    code, value = invoke(destination, *flags, selected_state=changed_state)
    check(label, code != 0 and value['status'] == 'error' and not (destination / 'release').exists() and
          snapshot(destination) == held)


refused('changed completed partial payload is refused without replacement',
        lambda _, s: (s / 'artifacts' / first_name).write_bytes(b'changed'))
refused('wrong executable mode is refused before copying missing payloads',
        lambda _, s: (s / 'artifacts' / first_name).chmod(0o600))
refused('unselected partial payload cannot enter the recovered release',
        lambda _, s: (s / 'artifacts/unselected').write_bytes(b'extra'))
refused('unexpected stage files are not ignored', lambda _, s: (s / 'unknown.json').write_text('{}'))
refused('unexpected original-input names refuse the entire retry',
        lambda _, s: (s / 'inputs/other.json').write_text('{}'))
refused('retained state cannot differ from the selected checkpoint',
        lambda _, s: (s / 'inputs/state.json').write_bytes(b'{}\n'))
refused('a premature incomplete manifest is not repaired or trusted',
        lambda _, s: (s / 'build-manifest.json').write_text('{"status":"success"}\n'))
refused('a premature incomplete result is not silently replaced',
        lambda _, s: (s / 'result.json').write_text('{"status":"verified"}\n'))
refused('unmanaged root entries refuse recovery', lambda d, _: (d / 'unknown').write_text('extra'))
refused('unrecognized scratch names refuse without cleanup', lambda d, _: (d / '.partial/unknown').write_text('x'))
refused('scratch symlinks cannot redirect a later write',
        lambda d, _: (d / '.partial' / ('a' * 32)).symlink_to(first))
refused('corrupt plan bytes cannot be repinned', lambda d, _: (d / 'plan.json').write_text('{}\n'))
refused('boolean checkpoint schema versions cannot masquerade as integers',
        lambda d, _: (d / 'plan.json').write_bytes(encoded(dict(plan, schema_version=True))))
changed = copy.deepcopy(state)
changed['status'] = 'partial'
changed_file = states / 'changed-state.json'
changed_file.write_bytes(encoded(changed))
refused('another valid state cannot reuse this pinned partial recovery', lambda *_: None, changed_state=changed_file)
refused('dry-run also rejects partial payload corruption',
        lambda _, s: (s / 'artifacts' / first_name).write_bytes(b'changed'), flags=('--resume', '--dry-run'))

# Resume a partially initialized managed workspace whose plan is durable but
# whose stage creation did not complete. Preserve its private prior evidence.
initialized, old_stage = cloned('initialized')
old_stage.rename(work / 'retained-initialized-stage')
code, value = invoke(initialized, '--resume')
check('a durable plan can resume interrupted stage initialization', code == 0 and value['recovered_artifacts'] == 4)

first_identity = snapshot(stage / 'artifacts', files_only=True)[first_name]
private_before = snapshot(interrupted / '.partial')
code, value = invoke(interrupted, '--resume')
check('retry finishes all primary and companion payloads without compilation',
      code == 0 and value['recovered_artifacts'] == 4 and value['companion_artifacts'] == 1)
release = interrupted / 'release'
check('retry preserves the completed payload inode, bytes, mode and timestamps',
      snapshot(release / 'artifacts', files_only=True)[first_name] == first_identity)
check('retry retains partial bytes as private evidence, never release payloads',
      {p.name for p in (release / 'artifacts').iterdir()} ==
      {first_name, 'b-demo-' + target.replace('/', '_'), 'c-bundle-' + target.replace('/', '_') + '.tar.gz', 'NOTICE'} and
      {k: v for k, v in snapshot(interrupted / '.partial').items() if k != '.'} ==
      {k: v for k, v in private_before.items() if k != '.'})
manifest = json.loads((release / 'build-manifest.json').read_bytes())
check('final metadata retains the original checkpoint observation time and archive evidence',
      manifest['recovery_evidence']['recovered_at'] == plan['recovered_at'] and
      any('archive_inventory' in row for row in manifest['recovery_evidence']['artifacts']))
check('resumed executable runs and every manifest row matches final bytes',
      run(release / 'artifacts' / first_name).decode().strip() == 'recovered without recompilation' and
      all(digest((release / 'artifacts' / a['name']).read_bytes()) == a['sha256'] for a in manifest['artifacts']))
held = snapshot(interrupted)
code, repeated = invoke(interrupted, '--resume')
check('completed managed recovery returns its exact receipt without writes',
      code == 0 and repeated == value and snapshot(interrupted) == held)

# Real Git responses are forwarded unchanged. Signal the actual supervisor
# after its final source query, when all staged documents and bytes exist.
faults = work / 'faults'
faults.mkdir()
fault_git = faults / 'git'
fault_git.write_text('#!' + sys.executable + '\n' + r'''
import os, signal, subprocess, sys
from pathlib import Path
p = subprocess.run([os.environ['RECOVERY_REAL_GIT'], *sys.argv[1:]])
d = Path(os.environ['RECOVERY_INTERRUPT_OUTPUT'])
m = Path(os.environ['RECOVERY_INTERRUPT_MARKER'])
if p.returncode == 0 and not m.exists() and 'refs/tags/v1.2.3^{commit}' in sys.argv:
    stages = list(d.glob('.recovery-*'))
    if len(stages) == 1 and (stages[0] / 'result.json').is_file():
        m.write_text('SIGTERM after final genuine Git query')
        os.kill(os.getppid(), signal.SIGTERM)
raise SystemExit(p.returncode)
''')
fault_git.chmod(0o755)
cancelled, marker = work / 'cancelled', work / 'cancelled.marker'
code, value = invoke(cancelled, environment=dict(os.environ, PATH=str(faults) + os.pathsep + os.environ['PATH'],
    RECOVERY_REAL_GIT=shutil.which('git'), RECOVERY_INTERRUPT_OUTPUT=str(cancelled), RECOVERY_INTERRUPT_MARKER=str(marker)))
check('actual SIGTERM retains an unpublished completed staging generation',
      code == 5 and marker.is_file() and not (cancelled / 'release').exists())
retained_stage = cancelled / json.loads((cancelled / 'plan.json').read_bytes())['stage']
staged_files = snapshot(retained_stage, files_only=True)
staged_result = json.loads((retained_stage / 'result.json').read_bytes())
code, value = invoke(cancelled, '--resume')
check('post-copy cancellation resumes by publishing the exact retained generation',
      code == 0 and value == staged_result and snapshot(cancelled / 'release', files_only=True) == staged_files)

if partial_baseline:
    legacy = work / 'legacy'
    code, original_receipt = invoke(legacy, selected_module=partial_baseline)
    check('unchanged completed-only implementation creates the legacy layout',
          code == 0 and {p.name for p in legacy.iterdir()} == {'release'})
    held = snapshot(legacy)
    code, value = invoke(legacy, '--resume')
    check('new resumable implementation revalidates legacy completed output unchanged',
          code == 0 and value == original_receipt and snapshot(legacy) == held)
check('all original worker inputs and source state remain unchanged',
      snapshot(assets) == source_before and state_file.read_bytes() == state_before and not git('status', '--porcelain'))
print('Interrupted recovery: %d passed, 0 failed; evidence: %s' % (passed, work), flush=True)
PY
