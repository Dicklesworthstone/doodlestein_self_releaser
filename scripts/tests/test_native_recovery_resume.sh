#!/usr/bin/env bash
# Real copy interruption, file-size exhaustion, locking and retained-checkpoint
# recovery. Git and Go are genuine; only saved native-worker metadata is a fixture.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
command -v python3 >/dev/null && command -v go >/dev/null && command -v git >/dev/null || exit 77
[[ $(uname -s) == Linux ]] || { echo 'SKIP: interruption integration requires Linux' >&2; exit 77; }
python3 -I - "$ROOT" <<'PY'
import ast
import copy
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import resource
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
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


# Exercise the exact allocation functions as well as the complete command.
# OS observations below are genuine fstatvfs calls; no free-space response,
# storage device or production function is substituted.
program = module.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
helpers = {'Failure', 'need', 'match', 'path', 'checkpoint', 'allocation_budget', 'check_capacity'}
definitions = [node for node in ast.parse(program).body
               if isinstance(node, (ast.ClassDef, ast.FunctionDef)) and node.name in helpers]
capacity = dict(os=os, Path=Path, re=re, cancel_requested=False)
exec(compile(ast.Module(body=definitions, type_ignores=[]), str(module), 'exec'), capacity)
budget, inspect_capacity = capacity['allocation_budget'], capacity['check_capacity']
check('allocation rounds each missing file independently and includes new namespace blocks',
      budget([1, 4096, 4097], 5, 4096) == (10 * 4096, 8))
check('same-filesystem scratch renaming does not require a second complete copy',
      budget([1024 * 1024], 0, 4096) == (1024 * 1024 + 4096, 1))
check('zero-length documents still require inode capacity', budget([0], 0, 4096) == (4096, 1))
check('the filesystem root can be observed as an output parent without creating a directory',
      inspect_capacity(Path('/'), [], 0, 0) == Path('/').stat().st_dev)
for invalid in (([-1], 0, 4096), ([True], 0, 4096), ([1], -1, 4096), ([1], 0, 0)):
    try:
        budget(*invalid)
        rejected = False
    except capacity['Failure'] as error:
        rejected = error.code == 4
    check('invalid allocation inputs cannot silently change the estimate: ' + repr(invalid), rejected)

observed = os.statvfs(work)
available = observed.f_bavail * observed.f_frsize
capacity_workspace = work / 'capacity-observation'
capacity_workspace.mkdir()
capacity_before = snapshot(capacity_workspace)
try:
    inspect_capacity(capacity_workspace, [available + observed.f_frsize], 0, 0)
    rejected = False
except capacity['Failure'] as error:
    rejected = error.code == 4 and 'insufficient recovery storage' in str(error)
check('a genuine destination observation refuses a payload larger than its available capacity without writes',
      rejected and snapshot(capacity_workspace) == capacity_before)

for flags in (('--dry-run',), (), ('--jobs', '4')):
    output = work / ('capacity-refusal-' + str(sequence))
    code, value = invoke(output, *flags, '--reserve-free-bytes', '9007199254740991')
    check('insufficient capacity refuses before any workspace is created: ' + repr(flags),
          code == 4 and 'insufficient recovery storage' in value.get('error', '') and not output.exists())
for invalid in ('-1', '9007199254740992', 'bad', '1.5', ''):
    output = work / ('bad-reserve-' + str(sequence))
    code, value = invoke(output, '--reserve-free-bytes', invalid)
    check('invalid reserve is a configuration error before output creation: ' + repr(invalid),
          code == 4 and value['status'] == 'error' and not output.exists())
output = work / 'duplicate-reserve'
code, _ = invoke(output, '--reserve-free-bytes', '0', '--reserve-free-bytes', '1')
check('duplicate reserve options cannot redefine the storage policy', code == 4 and not output.exists())
output = work / 'admitted-capacity-dry-run'
code, value = invoke(output, '--dry-run', '--reserve-free-bytes', '1048576')
check('sufficient actual capacity retains the complete dry-run plan without creating output',
      code == 0 and value['status'] == 'planned' and len(value['artifacts']) == 4 and not output.exists())

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
partial_additional_bytes = None
for flags in (('--resume',), ('--resume', '--dry-run')):
    code, value = invoke(interrupted, *flags, '--reserve-free-bytes', '9007199254740991')
    check('partial capacity refusal preserves completed copies and all private evidence: ' + repr(flags),
          code == 4 and 'insufficient recovery storage' in value.get('error', '') and snapshot(interrupted) == before)
    partial_additional_bytes = int(re.search(r'additional_bytes=([0-9]+)', value['error'])[1])
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
remaining_sizes = [second.stat().st_size, archive.stat().st_size,
                   (release / 'build-manifest.json').stat().st_size, (release / 'result.json').stat().st_size]
check('resume budget charges only the missing payloads and documents, not retained copies or scratch bytes',
      partial_additional_bytes == budget(remaining_sizes, 0, os.statvfs(release).f_frsize)[0])
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
code, retained_result = invoke(interrupted, '--resume', '--reserve-free-bytes', '9007199254740991')
check('completed read-only retry needs no new allocation even under an unsatisfiable reserve',
      code == 0 and retained_result == repeated and snapshot(interrupted) == held)

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
# Observe genuine writable descriptors, not timing, to prove that --jobs
# controls copying as well as the existing parallel verification phases.
# Use separate worker inputs so the original fixture's custody is unchanged.
parallel_assets = work / 'parallel-artifacts'
shutil.copytree(assets, parallel_assets)
parallel_state = copy.deepcopy(state)
parallel_result = parallel_state['target_statuses'][target]['result']
parallel_result['artifact_paths'] = [str(parallel_assets / Path(p).name) for p in primary]
parallel_result['artifact_path'] = ','.join(parallel_result['artifact_paths'])
parallel_companions = [parallel_assets / 'NOTICE']
for index in range(4):
    data = parallel_assets / ('data%d.bin' % index)
    with data.open('xb') as stream:
        for _ in range(32):
            stream.write(bytes([65 + index]) * (1024 * 1024))
    parallel_companions.append(data)
parallel_result['additional_artifacts'] = [receipt(p) for p in parallel_companions]
parallel_result['resume_artifacts'] = [receipt(Path(p)) for p in parallel_result['artifact_paths']] + parallel_result['additional_artifacts']
parallel_state_file = states / 'parallel-state.json'
parallel_state_file.write_bytes(encoded(parallel_state))
parallel_inputs = snapshot(parallel_assets)


def observe_copy(output, jobs=4, resume=False, cancel=False, selected_module=None, limit=None):
    global sequence
    sequence += 1
    command = ['bash', str(selected_module or module), '--state', str(parallel_state_file),
               '--state-sha256', digest(parallel_state_file.read_bytes()), '--source-repo', str(source),
               '--repo', 'owner/demo', '--tag', 'v1.2.3', '--sha', commit,
               '--artifacts-root', str(parallel_assets), '--output-dir', str(output), '--jobs', str(jobs)]
    if resume:
        command.append('--resume')
    def bounded_write():
        resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True, preexec_fn=bounded_write if limit is not None else None)
    peak = 0
    sent = False
    start = time.monotonic()
    try:
        while process.poll() is None:
            if time.monotonic() - start > 90:
                raise TimeoutError('copy observation deadline')
            writable = set()
            descriptors = Path('/proc') / str(process.pid) / 'fd'
            try:
                for descriptor in descriptors.iterdir():
                    try:
                        selected = Path(os.readlink(descriptor))
                        if selected.parent != output / '.partial':
                            continue
                        metadata = (descriptors.parent / 'fdinfo' / descriptor.name).read_text()
                        flags = next(int(line.split()[1], 8) for line in metadata.splitlines()
                                     if line.startswith('flags:'))
                        if flags & os.O_ACCMODE in (os.O_WRONLY, os.O_RDWR):
                            writable.add(str(selected))
                    except (OSError, ValueError, StopIteration):
                        pass
            except FileNotFoundError:
                pass
            peak = max(peak, len(writable))
            if cancel and len(writable) >= 2 and not sent:
                process.send_signal(signal.SIGTERM)
                sent = True
                time.sleep(0.001)
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
            time.sleep(0.0005)
        stdout, stderr = process.communicate(timeout=10)
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise
    (work / ('run-%d.stdout' % sequence)).write_bytes(stdout)
    (work / ('run-%d.stderr' % sequence)).write_bytes(stderr)
    return process.returncode, json.loads(stdout), dict(peak_writers=peak, interrupted=sent,
                                                       seconds=time.monotonic() - start)


copy_baseline = os.environ.get('DSR_RECOVERY_COPY_BASELINE')
serial_output, parallel_output = work / 'serial-copy', work / 'parallel-copy'
code, serial_receipt, serial_observation = observe_copy(serial_output,
    jobs=4 if copy_baseline else 1, selected_module=copy_baseline)
check('serial copy control has exactly one real writable payload descriptor',
      code == 0 and serial_observation['peak_writers'] == 1)
code, parallel_receipt, parallel_observation = observe_copy(parallel_output)
check('parallel copying opens multiple actual output files within --jobs',
      code == 0 and 2 <= parallel_observation['peak_writers'] <= 4)
serial_manifest = json.loads((serial_output / 'release/build-manifest.json').read_bytes())
parallel_manifest = json.loads((parallel_output / 'release/build-manifest.json').read_bytes())
# Only the observation timestamp differs between independently created plans;
# source custody, target coverage, archive evidence and payload rows must agree.
serial_manifest['recovery_evidence'].pop('recovered_at')
parallel_manifest['recovery_evidence'].pop('recovered_at')
check('parallel copies preserve every manifest identity and source attribution',
      serial_manifest == parallel_manifest and parallel_receipt['recovered_artifacts'] == 8)
check('all parallel raw archive and companion copies retain expected bytes and modes',
      all(digest((parallel_output / 'release/artifacts' / row['name']).read_bytes()) == row['sha256']
          for row in parallel_manifest['artifacts']) and
      snapshot(serial_output / 'release/artifacts', files_only=True).keys() ==
      snapshot(parallel_output / 'release/artifacts', files_only=True).keys() and
      all((serial_output / 'release/artifacts' / row['name']).stat().st_mode ==
          (parallel_output / 'release/artifacts' / row['name']).stat().st_mode
          for row in parallel_manifest['artifacts']))
held_parallel = snapshot(parallel_output)
for jobs in (1, 2, 32):
    code, retry, observed = observe_copy(parallel_output, jobs=jobs, resume=True)
    check('completed retry never starts a copier or changes receipt with jobs=' + str(jobs),
          code == 0 and retry == parallel_receipt and observed['peak_writers'] == 0 and
          snapshot(parallel_output) == held_parallel)

copy_cancelled = work / 'copy-cancelled'
code, failure, cancellation = observe_copy(copy_cancelled, cancel=True)
check('repeated signals during real parallel writes refuse publication and report interruption',
      cancellation['interrupted'] and code == 5 and failure['exit_code'] == 5 and
      not (copy_cancelled / 'release').exists())
cancel_stage = copy_cancelled / json.loads((copy_cancelled / 'plan.json').read_bytes())['stage']
retained_copies = snapshot(cancel_stage / 'artifacts', files_only=True)
retained_private = snapshot(copy_cancelled / '.partial', files_only=True)
check('cancelled threads retain their scratch evidence outside the committed namespace',
      bool(retained_private) and all(len(n) == 32 for n in retained_private))
lock = os.open(copy_cancelled, os.O_RDONLY | os.O_DIRECTORY)
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    check('all copy threads drain before releasing the recovery lock', True)
finally:
    os.close(lock)
code, retry, _ = observe_copy(copy_cancelled, resume=True)
check('resume completes the full payload set after parallel write cancellation',
      code == 0 and retry['recovered_artifacts'] == 8)
check('resume preserves already committed files and private cancellation evidence',
      all(snapshot(copy_cancelled / 'release/artifacts', files_only=True)[k] == v
          for k, v in retained_copies.items()) and
      all(snapshot(copy_cancelled / '.partial', files_only=True)[k] == v
          for k, v in retained_private.items()))

copy_exhausted = work / 'parallel-write-exhausted'
code, failure, _ = observe_copy(copy_exhausted, limit=len(binary) + 65536)
check('one parallel file-size failure prevents a successful subset release',
      code == 4 and 'File too large' in failure.get('error', '') and
      not (copy_exhausted / 'release').exists())
exhausted_stage = copy_exhausted / json.loads((copy_exhausted / 'plan.json').read_bytes())['stage']
retained = snapshot(exhausted_stage / 'artifacts', files_only=True)
code, retry, _ = observe_copy(copy_exhausted, jobs=2, resume=True)
check('failed parallel copy resumes with another budget without replacing completed files',
      code == 0 and retry['recovered_artifacts'] == 8 and
      all(snapshot(copy_exhausted / 'release/artifacts', files_only=True)[k] == v for k, v in retained.items()))
check('parallel copying leaves original input identities and selected state unchanged',
      snapshot(parallel_assets) == parallel_inputs and parallel_state_file.read_bytes() == encoded(parallel_state))
(work / 'copy-observations.json').write_bytes(encoded(dict(incumbent=copy_baseline,
    serial=serial_observation, parallel=parallel_observation, cancellation=cancellation)))

check('all original worker inputs and source state remain unchanged',
      snapshot(assets) == source_before and state_file.read_bytes() == state_before and not git('status', '--porcelain'))
print('Interrupted recovery: %d passed, 0 failed; evidence: %s' % (passed, work), flush=True)
PY
