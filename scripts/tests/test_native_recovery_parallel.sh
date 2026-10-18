#!/usr/bin/env bash
# Real parallel recovery I/O, unchanged receipts, and process cancellation.
# Native worker-state envelopes are fixtures; no production helper is replaced.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
for tool in python3 go git; do
    command -v "$tool" >/dev/null || { echo "SKIP: $tool is required" >&2; exit 77; }
done
[[ $(uname -s) == Linux && -d /proc/self/fd ]] || {
    echo 'SKIP: parallel I/O observation requires Linux procfs' >&2; exit 77;
}
python3 -I - "$ROOT" <<'PY'
import copy
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
import zipfile

module = Path(sys.argv[1]) / 'src/release_recover_native.sh'
work = Path(tempfile.mkdtemp(prefix='dsr-recovery-parallel-'))
print('Evidence: ' + str(work), flush=True)
source, assets, states = (work / n for n in ('source', 'artifacts', 'states'))
for directory in (source, assets, states):
    directory.mkdir()
passed = sequence = 0


def check(label, ok):
    global passed
    if not ok:
        raise AssertionError(label)
    passed += 1
    print('PASS ' + label, flush=True)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def run(*command, **kwargs):
    return subprocess.run(list(map(str, command)), capture_output=True, check=True,
                          timeout=180, **kwargs).stdout


def git(*arguments):
    return run('git', '-C', source, *arguments).decode().strip()


def snapshot(directory):
    return {str(p.relative_to(directory)): (
        p.lstat().st_dev, p.lstat().st_ino, p.lstat().st_mode, p.lstat().st_size,
        p.lstat().st_mtime_ns, p.lstat().st_ctime_ns,
        digest(p) if p.is_file() and not p.is_symlink() else None)
        for p in [directory, *sorted(directory.rglob('*'))]}


arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(platform.machine())
if arch is None:
    raise SystemExit(77)
target = 'linux/' + arch
git('init', '-q', '-b', 'main')
git('config', 'user.name', 'DSR parallel fixture')
git('config', 'user.email', 'parallel@example.invalid')
git('config', 'commit.gpgsign', 'false')
git('remote', 'add', 'origin', 'https://github.com/owner/demo.git')
(source / 'main.go').write_text('package main\nfunc main(){println("parallel recovery executable")}\n')
git('add', 'main.go')
git('commit', '-qm', 'real parallel recovery fixture')
commit = git('rev-parse', 'HEAD')
git('tag', 'v1.2.3')
env = dict(os.environ, CGO_ENABLED='0', GOOS='linux', GOARCH=arch, GOENV='off',
           GOTOOLCHAIN='local', GOPROXY='off', GOSUMDB='off', GO111MODULE='off',
           GOCACHE=os.environ.get('DSR_RECOVERY_TEST_GOCACHE', str(work / 'go-cache')))
binary = assets / 'a-demo'
run('go', 'build', '-trimpath', '-o', binary, source / 'main.go', env=env)
binary.chmod(0o751)
compressed, zipped = assets / 'b-bundle.tar.gz', assets / 'c-bundle.zip'
with tarfile.open(compressed, 'w:gz') as tf:
    tf.add(binary, arcname='bin/demo')
with zipfile.ZipFile(zipped, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
    zf.write(binary, 'bin/demo')
# Large opaque companions make simultaneous actual read descriptors observable.
# The test never injects a timing delay or substitutes a hash/copy function.
companions = [assets / ('data%d.bin' % i) for i in range(4)]
for number, selected in enumerate(companions):
    with selected.open('xb') as f:
        for _ in range(64):
            f.write(bytes([number + 65]) * (1024 * 1024))
primaries = [binary, compressed, zipped]


def receipt(p):
    info = p.stat()
    return dict(path=str(p), sha256=digest(p), size_bytes=info.st_size,
                identity='gnu:%d:%d' % (info.st_dev, info.st_ino))


rows = [receipt(p) for p in primaries + companions]
worker = dict(tool='demo', platform=target, host='fixture', task_key=target, target_triple=None,
              status='success', exit_code=0, method='native', build_purpose='release', publishable=True,
              artifact_path=','.join(map(str, primaries)), artifact_paths=list(map(str, primaries)),
              additional_artifacts=rows[3:], resume_artifacts=rows,
              build_influence_env={'GOOS': 'linux', 'GOARCH': arch}, cargo_isolation=None)
state = dict(tool='demo', version='1.2.3', run_id=str(uuid.uuid4()), status='targets-complete',
             git_sha=commit, git_ref='refs/tags/v1.2.3', targets=[target],
             target_statuses={target: dict(status='completed', host='fixture', result=worker,
                                          updated_at='2026-10-01T12:00:00Z')},
             context=dict(build_purpose='release', publishable=True, target_hosts={target: 'fixture'},
                          build_tasks=[dict(key=target, platform=target, target_triple='', method='native')]))
# Real cross-compiled primaries share the exact same physical companion paths.
# Keep every logical worker receipt while avoiding repeated full companion reads.
for other in ('linux/amd64', 'linux/arm64', 'darwin/amd64', 'darwin/arm64'):
    if other == target:
        continue
    operating_system, architecture = other.split('/')
    directory = assets / other.replace('/', '_')
    directory.mkdir()
    selected = directory / 'a-demo'
    run('go', 'build', '-trimpath', '-o', selected, source / 'main.go',
        env=dict(env, GOOS=operating_system, GOARCH=architecture))
    selected.chmod(0o751)
    primaries.append(selected)
    result = copy.deepcopy(dict(worker, platform=other, task_key=other,
                  artifact_path=str(selected), artifact_paths=[str(selected)],
                  resume_artifacts=[receipt(selected), *rows[3:]],
                  build_influence_env={'GOOS': operating_system, 'GOARCH': architecture}))
    state['targets'].append(other)
    state['target_statuses'][other] = dict(status='completed', host='fixture', result=result,
                                         updated_at='2026-10-01T12:00:00Z')
    state['context']['target_hosts'][other] = 'fixture'
    state['context']['build_tasks'].append(dict(key=other, platform=other, target_triple='', method='native'))
state_file = states / 'state.json'
state_file.write_bytes(encoded(state))
input_before = snapshot(assets)


def invocation(output, *options, selected_module=None, selected_state=None):
    chosen = selected_state or state_file
    return ['bash', str(selected_module or module), '--state', str(chosen), '--state-sha256', digest(chosen),
            '--source-repo', str(source), '--repo', 'owner/demo', '--tag', 'v1.2.3', '--sha', commit,
            '--artifacts-root', str(assets), '--output-dir', str(output), *options]


def open_inputs(pid):
    opened = set()
    try:
        for descriptor in (Path('/proc') / str(pid) / 'fd').iterdir():
            try:
                selected = Path(os.readlink(descriptor))
                if selected in primaries + companions:
                    opened.add(str(selected))
            except (OSError, ValueError):
                pass
    except FileNotFoundError:
        pass
    return opened


def invoke(output, *options, observe=False, cancel=False, **kwargs):
    global sequence
    sequence += 1
    started, peak, read_bytes, sent = time.monotonic(), 0, 0, False
    process = subprocess.Popen(invocation(output, *options, **kwargs),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        if observe or cancel:
            deadline = started + 90
            while process.poll() is None and time.monotonic() < deadline:
                peak = max(peak, len(open_inputs(process.pid)))
                try:
                    counters = dict(line.split(': ', 1) for line in
                                    (Path('/proc') / str(process.pid) / 'io').read_text().splitlines())
                    read_bytes = max(read_bytes, int(counters['rchar']))
                except FileNotFoundError:
                    pass
                if cancel and peak >= 2 and not sent:
                    process.send_signal(signal.SIGTERM)
                    sent = True
                    # A second signal must not interrupt worker draining.
                    time.sleep(0.001)
                    if process.poll() is None:
                        process.send_signal(signal.SIGINT)
                time.sleep(0.0005)
        stdout, stderr = process.communicate(timeout=90)
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise
    elapsed = time.monotonic() - started
    (work / ('run-%d.stdout' % sequence)).write_bytes(stdout)
    (work / ('run-%d.stderr' % sequence)).write_bytes(stderr)
    value = json.loads(stdout)
    return process.returncode, value, dict(peak_open_inputs=peak, bytes_read=read_bytes,
                                         seconds=elapsed, signal_sent=sent)


baseline = os.environ.get('DSR_RECOVERY_PARALLEL_BASELINE')
code, serial, serial_observation = invoke(work / 'serial-dry', '--dry-run', observe=True,
                                         selected_module=baseline)
check('serial incumbent reads one original at a time', code == 0 and serial_observation['peak_open_inputs'] == 1)
code, parallel, observation = invoke(work / 'parallel-dry', '--jobs', '4', '--dry-run', observe=True)
check('parallel admission observes concurrent real input reads within its selected bound',
      code == 0 and 2 <= observation['peak_open_inputs'] <= 4)
check('parallel and serial planning retain exactly the same complete inventory', parallel == serial)
check('parallel dry-run creates no recovery workspace', not (work / 'parallel-dry').exists())
if baseline:
    check('shared physical companions eliminate repeated full reads without losing tasks',
          serial_observation['bytes_read'] > 2 * observation['bytes_read'] > 0)
(work / 'observations.json').write_bytes(encoded(dict(serial=serial_observation, parallel=observation,
                                                     baseline=baseline or 'current default serial path')))

output = work / 'complete'
code, result, _ = invoke(output, '--jobs', '4')
check('parallel verification recovers every raw archive and companion', code == 0 and
      result['recovered_artifacts'] == 10 and result['recovered_targets'] == 4)
release = output / 'release'
manifest = json.loads((release / 'build-manifest.json').read_bytes())
check('each recovered payload binds its actual final digest and size', all(
    digest(release / 'artifacts' / r['name']) == r['sha256'] and
    (release / 'artifacts' / r['name']).stat().st_size == r['size_bytes'] for r in manifest['artifacts']))
check('archive member evidence survives parallel admission',
      sum('archive_inventory' in r for r in manifest['recovery_evidence']['artifacts']) == 2)
check('coalesced companions retain all sixteen logical source attributions',
      sum(r['role'] == 'additional' for r in manifest['recovery_evidence']['artifacts']) == 16)
check('the recovered host executable really executes',
      subprocess.run([str(release / 'artifacts' / ('a-demo-' + target.replace('/', '_')))],
                     capture_output=True, check=True, timeout=10).stderr == b'parallel recovery executable\n')
before = snapshot(output)
for jobs in ('1', '2', '32'):
    code, retry, _ = invoke(output, '--resume', '--jobs', jobs)
    check('changing concurrency on completed retry preserves the original receipt: ' + jobs,
          code == 0 and retry == result and snapshot(output) == before)
code, planned, _ = invoke(output, '--resume', '--jobs', '3', '--dry-run')
check('parallel retained dry-run never rewrites evidence', code == 0 and planned == parallel and snapshot(output) == before)

for value in ('0', '-1', '33', 'bad', '', '1.5'):
    refused = work / ('invalid-' + str(sequence))
    code, response, _ = invoke(refused, '--jobs', value)
    check('invalid worker budget refuses before output creation: ' + repr(value),
          code == 4 and not refused.exists())
code, _, _ = invoke(work / 'duplicate-option', '--jobs', '2', '--jobs', '3')
check('duplicate concurrency options cannot silently change policy', code == 4 and not (work / 'duplicate-option').exists())

bad = copy.deepcopy(state)
bad['target_statuses'][target]['result']['resume_artifacts'][0]['sha256'] = '0' * 64
invalid_state = states / 'wrong-receipt.json'
invalid_state.write_bytes(encoded(bad))
code, failure, _ = invoke(work / 'bad-original', '--jobs', '4', selected_state=invalid_state)
check('a parallel worker failure cannot publish a valid subset', code == 7 and
      'digest differs from worker receipt' in failure['error'] and not (work / 'bad-original').exists())

conflict = copy.deepcopy(state)
other = next(t for t in conflict['targets'] if t != target)
for inventory in ('additional_artifacts', 'resume_artifacts'):
    for row in conflict['target_statuses'][other]['result'][inventory]:
        if row['path'] == str(companions[0]):
            row['sha256'] = 'f' * 64
conflicting_state = states / 'conflicting-shared.json'
conflicting_state.write_bytes(encoded(conflict))
code, failure, _ = invoke(work / 'conflicting-shared', '--jobs', '4', selected_state=conflicting_state)
check('coalescing refuses a conflicting logical receipt before output exists', code == 4 and
      not (work / 'conflicting-shared').exists() and 'shared' in failure['error'])

# Interrupt actual simultaneous reads in a held completed workspace. Every
# thread belongs to the same process and must drain before it releases its lock.
code, failure, interrupted_observation = invoke(output, '--resume', '--jobs', '4', observe=True, cancel=True)
check('SIGTERM during parallel reads is reported as interrupted',
      code == 5 and interrupted_observation['signal_sent'] and failure['exit_code'] == 5)
check('cancellation preserves all retained output identities and bytes', snapshot(output) == before)
fd = os.open(output, os.O_RDONLY | os.O_DIRECTORY)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    check('cancellation leaves no surviving lock owner', True)
finally:
    os.close(fd)
code, retry, _ = invoke(output, '--resume', '--jobs', '4')
check('retry after parallel cancellation revalidates the original release', code == 0 and retry == result)
check('parallel operations never alter original worker artifacts or selected state',
      snapshot(assets) == input_before and state_file.read_bytes() == encoded(state))

# A valid original is not permission to repair a corrupted committed copy.
payload = release / 'artifacts' / 'data0.bin'
with payload.open('r+b') as f:
    f.write(b'corrupt')
corrupt_before = snapshot(output)
code, failure, _ = invoke(output, '--resume', '--jobs', '4')
check('parallel retry refuses a corrupt retained copy without repair', code == 7 and
      'digest differs from worker receipt' in failure['error'] and snapshot(output) == corrupt_before)
print('Parallel recovery: %d passed, 0 failed' % passed, flush=True)
PY
