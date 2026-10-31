#!/usr/bin/env bash
# Actual standalone generated installers and filesystem transactions. Tiny
# executable shell payloads keep this suite independent of compiler caches.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for dependency in python3 bash jq yq tar gzip; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'SKIP: installer transaction tests require %s\n' "$dependency"
        exit 0
    }
done
python3 -I - "$ROOT" "$@" <<'PY'
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

root = Path(sys.argv[1])
baseline = sys.argv[2:] == ['--baseline-reproduction']
if sys.argv[2:] not in ([], ['--baseline-reproduction']):
    raise SystemExit('Usage: test_generated_installer_transactions.sh [--baseline-reproduction]')
work = Path(tempfile.mkdtemp(prefix='dsr-installer-transactions-')).resolve()
print('Retained installer transaction evidence: ' + str(work), flush=True)
operating_system = {'Linux': 'linux', 'Darwin': 'darwin', 'FreeBSD': 'freebsd'}[platform.system()]
architecture = {'x86_64': 'amd64', 'amd64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64',
                'i386': '386', 'i686': '386', 'armv7l': 'armv7'}[platform.machine()]
names = ['demo', 'worker']
environment = {key: value for key, value in os.environ.items()
               if key not in ('BASH_ENV', 'ENV') and not key.startswith('BASH_FUNC_')}
environment.update(DSR_CONFIG_DIR=str(work / 'config'), DSR_STATE_DIR=str(work / 'state'),
                   DSR_CACHE_DIR=str(work / 'dsr-cache'), DSR_INSTALLER_DIR=str(work / 'generated'),
                   DSR_GH_TOKEN='', GITHUB_TOKEN='', GH_TOKEN='', NO_COLOR='1')
for directory in ('config/repos.d', 'archives', 'tools', 'control', 'results'):
    (work / directory).mkdir(parents=True)
passed = failed = sequence = 0


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print('PASS: ' + label, flush=True)
    else:
        failed += 1
        print('FAIL: ' + label, flush=True)


def payload(name, version):
    return ('#!/bin/sh\nprintf "%s\\n" "' + name + ' ' + version + '"\n').encode()


def archive(version, primary='demo'):
    target = work / 'archives' / (primary + '-' + version + '.tar.gz')
    with tarfile.open(target, 'w:gz') as output:
        for name in (primary, 'worker'):
            value = payload(name, version)
            item = tarfile.TarInfo(name)
            item.mode, item.size = 0o755, len(value)
            output.addfile(item, io.BytesIO(value))
    asset = f'{primary}-{version}-{operating_system}-{architecture}.tar.gz'
    Path(str(target) + '.sha256').write_text(hashlib.sha256(target.read_bytes()).hexdigest() + '  ' + asset + '\n')
    return target


def generate(primary='demo'):
    config = {'tool_name': primary, 'repo': 'example/' + primary, 'binary_name': primary,
              'language': 'rust', 'targets': [operating_system + '/' + architecture],
              'workspace_binaries': [primary, 'worker'], 'archive_format': 'tar.gz',
              'artifact_naming': '${name}-${version}-${os}-${arch}'}
    (work / 'config/repos.d' / (primary + '.yaml')).write_text(json.dumps(config) + '\n')
    result = subprocess.run(['bash', '-c', 'source "$1/src/install_gen.sh"; install_gen_create "$2" --config-dir "$3"',
                             '_', str(root), primary, str(work / 'config')],
                            env=environment, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    (work / 'results' / (primary + '-generation.log')).write_bytes(result.stderr)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace'))
    script = Path(result.stdout.decode().strip())
    check(primary + ' generated standalone installer exists', script.is_file())
    return script


def arguments(script, directory, version, package, yes=True):
    result = ['bash', str(script), '--version', 'v' + version, '--dir', str(directory),
              '--offline', str(package), '--cache-dir', str(work / 'cache'),
              '--non-interactive', '--json', '--no-skills']
    if yes:
        result.append('--yes')
    return result


def record(label, result):
    (work / 'results' / (label + '.out')).write_bytes(result.stdout)
    (work / 'results' / (label + '.err')).write_bytes(result.stderr)
    try:
        value = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError):
        value = {}
    check(label + ' emits one matching JSON result', value.get('status') == ('success' if result.returncode == 0 else 'error'))
    return value


def install(label, script, directory, version, package, env=None, yes=True):
    result = subprocess.run(arguments(script, directory, version, package, yes), env=env or environment,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    record(label, result)
    return result


def snapshot(directory):
    return {name: (path.read_bytes(), stat.S_IMODE(path.stat().st_mode), path.stat().st_ino)
            for name in names + ['unrelated'] if (path := directory / name).exists()}


def family(directory, version):
    return all((directory / name).read_bytes() == payload(name, version) for name in names)


def wait_for(path, process):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if path.exists():
            return
        if process.poll() is not None:
            out, err = process.communicate()
            raise RuntimeError('writer ended before ' + path.name + ': ' + (out + err).decode(errors='replace'))
        time.sleep(0.02)
    raise RuntimeError('writer did not reach ' + path.name)


real_mv = shutil.which('mv')
wrapper = work / 'tools/mv'
wrapper.write_text('''#!''' + sys.executable + '''
import os, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
source, destination = args[-2:]
root = Path(os.environ['TRANSACTION_CONTROL'])
def wait(name):
    deadline = time.monotonic() + 45
    while not (root / name).exists():
        if time.monotonic() > deadline:
            sys.exit(74)
        time.sleep(0.02)
mode = os.environ.get('TRANSACTION_MODE', 'pause')
if mode == 'fail-worker' and source.endswith('/new/worker') and destination == os.environ['TRANSACTION_PREFIX'] + '/worker':
    (root / 'worker-rename-failed').write_text('yes')
    sys.exit(73)
if mode == 'pause' and source.endswith('/new/demo') and destination == os.environ['TRANSACTION_PREFIX'] + '/demo':
    (root / 'backups-ready').write_text(str(os.getppid()))
    wait('allow-primary')
    status = subprocess.run([os.environ['TRANSACTION_REAL_MV'], *args]).returncode
    if status:
        sys.exit(status)
    (root / 'primary-committed').write_text('yes')
    wait('finish-primary')
    sys.exit(0)
os.execv(os.environ['TRANSACTION_REAL_MV'], [os.environ['TRANSACTION_REAL_MV'], *args])
''')
wrapper.chmod(0o755)
script = generate()
other_script = None if baseline else generate('other')
other_package = None if baseline else archive('2.0.0', 'other')
packages = {version: archive(version) for version in ('1.0.0', '2.0.0', '3.0.0')}
destination = work / 'installed'
seeded = install('initial', script, destination, '1.0.0', packages['1.0.0'])
check('initial complete family installs', seeded.returncode == 0 and family(destination, '1.0.0'))
(destination / 'unrelated').write_bytes(b'preserve unrelated user data\n')
(destination / 'unrelated').chmod(0o640)
before = snapshot(destination)
control = work / 'control'
writer_environment = environment | {'PATH': str(work / 'tools') + os.pathsep + environment['PATH'],
                                    'TRANSACTION_REAL_MV': real_mv, 'TRANSACTION_CONTROL': str(control),
                                    'TRANSACTION_PREFIX': str(destination)}
writer = subprocess.Popen(arguments(script, destination, '3.0.0', packages['3.0.0']), env=writer_environment,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
try:
    wait_for(control / 'backups-ready', writer)
    check('writer has completed backups without replacing any installed file', snapshot(destination) == before)
    contender = install('contender', script, destination, '2.0.0', packages['2.0.0'])
    if baseline:
        check('baseline second writer reports successful complete installation', contender.returncode == 0 and family(destination, '2.0.0'))
    else:
        check('competing installer refuses a busy prefix', contender.returncode != 0)
        check('busy refusal explains retry', b'install' in contender.stderr.lower() and b'retry' in contender.stderr.lower())
        check('busy contender preserves every installed byte, mode and inode', snapshot(destination) == before)
        alias = work / 'directory-alias'
        alias.symlink_to(destination, target_is_directory=True)
        alias_result = install('alias-contender', script, alias, '2.0.0', packages['2.0.0'])
        check('a directory alias cannot bypass the same prefix lock', alias_result.returncode != 0 and snapshot(destination) == before)
        other = install('overlapping-tool', other_script, destination, '2.0.0', other_package)
        check('another primary sharing a companion uses the same prefix lock',
              other.returncode != 0 and not (destination / 'other').exists() and snapshot(destination) == before)
        independent = work / 'independent-prefix'
        independent_result = install('independent-prefix', script, independent, '2.0.0', packages['2.0.0'])
        check('a different installation directory proceeds concurrently', independent_result.returncode == 0 and family(independent, '2.0.0'))
        check('private lock directory and owner record have restrictive modes',
              stat.S_IMODE((destination / '.dsr-install.lock').stat().st_mode) == 0o700 and
              stat.S_IMODE((destination / '.dsr-install.lock/owner').stat().st_mode) == 0o600)
    (control / 'allow-primary').touch()
    wait_for(control / 'primary-committed', writer)
    check('writer really replaced the first family member', (destination / 'demo').read_bytes() == payload('demo', '3.0.0'))
    writer.send_signal(signal.SIGTERM)
    # The public installer forwards TERM to its child, which waits for the
    # real rename wrapper to finish before running its production rollback.
    time.sleep(0.1)
    (control / 'finish-primary').touch()
    output, error = writer.communicate(timeout=20)
    result = subprocess.CompletedProcess(writer.args, writer.returncode, output, error)
    record('interrupted-writer', result)
    check('TERM to the public installer fails its transaction', result.returncode != 0)
    if baseline:
        check('baseline rollback corrupts the completed contender family',
              (destination / 'demo').read_bytes() == payload('demo', '1.0.0') and
              (destination / 'worker').read_bytes() == payload('worker', '2.0.0'))
    else:
        check('interrupted sole writer restores the complete previous family', family(destination, '1.0.0'))
        check('unrelated file retains its bytes, permissions and inode', snapshot(destination)['unrelated'] == before['unrelated'])
        check('handled interruption releases its installation lock', not (destination / '.dsr-install.lock').exists())
        retried = install('retry', script, destination, '2.0.0', packages['2.0.0'])
        check('retry installs one complete family', retried.returncode == 0 and family(destination, '2.0.0'))
finally:
    for gate in ('allow-primary', 'finish-primary'):
        (control / gate).touch()
    if writer.poll() is None:
        writer.terminate()
        try:
            writer.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(writer.pid, signal.SIGKILL)
            writer.communicate(timeout=5)

if not baseline:
    before = snapshot(destination)
    refused = install('overwrite-consent', script, destination, '3.0.0', packages['3.0.0'], yes=False)
    check('overwrite refusal preserves every old inode and releases its lock',
          refused.returncode != 0 and snapshot(destination) == before and not (destination / '.dsr-install.lock').exists())
    (destination / 'demo').chmod(0o751)
    (destination / 'worker').chmod(0o711)
    before = snapshot(destination)
    failure_environment = writer_environment | {'TRANSACTION_MODE': 'fail-worker'}
    failed_rename = install('single-writer-rename-failure', script, destination, '3.0.0', packages['3.0.0'], failure_environment)
    check('actual companion rename failure exercises transaction rollback',
          failed_rename.returncode != 0 and (control / 'worker-rename-failed').exists())
    after = snapshot(destination)
    check('rollback restores all prior bytes and file modes', all(after[name][:2] == before[name][:2] for name in names))
    check('rollback preserves unrelated files and releases its lock',
          after['unrelated'] == before['unrelated'] and not (destination / '.dsr-install.lock').exists())
    unavailable_tools = work / 'unavailable-identity-tools'
    unavailable_tools.mkdir()
    unavailable_stat = unavailable_tools / 'stat'
    unavailable_stat.write_text('#!/bin/sh\nexit 1\n')
    unavailable_stat.chmod(0o755)
    initial = snapshot(destination)
    result = install('unavailable-directory-identity', script, destination, '3.0.0', packages['3.0.0'],
                     environment | {'PATH': str(unavailable_tools) + os.pathsep + environment['PATH']})
    check('unavailable identity inspection fails before acquiring a lock or changing files',
          result.returncode != 0 and b'stat cannot identify' in result.stderr and
          snapshot(destination) == initial and not (destination / '.dsr-install.lock').exists())
    for kind in ('abandoned-directory', 'regular-file', 'symlink'):
        prefix = work / ('guard-' + kind)
        prefix.mkdir()
        for name in names:
            shutil.copy2(destination / name, prefix / name)
        guard = prefix / '.dsr-install.lock'
        if kind == 'abandoned-directory':
            guard.mkdir()
            (guard / 'owner').write_text('pid=999999999 tool=someone-else token=retain-this\n')
            (guard / 'foreign').write_text('preserve foreign data\n')
            protected = guard / 'foreign'
        elif kind == 'regular-file':
            guard.write_text('not an owned lock directory\n')
            protected = guard
        else:
            outside = work / 'external-lock-target'
            outside.mkdir()
            protected = outside / 'foreign'
            protected.write_text('never follow or change the lock target\n')
            guard.symlink_to(outside, target_is_directory=True)
        initial = snapshot(prefix)
        protected_bytes, protected_inode = protected.read_bytes(), protected.stat().st_ino
        result = install('guard-' + kind, script, prefix, '3.0.0', packages['3.0.0'])
        check(kind + ' is never stolen even with --yes', result.returncode != 0 and snapshot(prefix) == initial)
        check(kind + ' retains foreign bytes and inode', protected.read_bytes() == protected_bytes and protected.stat().st_ino == protected_inode)

    # Replace the guard after successful file verification but before cleanup.
    # The new directory deliberately has identical owner bytes: inode binding,
    # rather than a token-only comparison, must protect the replacement.
    cleanup_tools = work / 'cleanup-tools'
    cleanup_tools.mkdir()
    cleanup_wrapper = cleanup_tools / 'rm'
    cleanup_wrapper.write_text('''#!''' + sys.executable + '''
import os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
target = Path(args[-1])
prefix = Path(os.environ['TRANSACTION_PREFIX'])
if target.parent == prefix and target.name.startswith('.demo.install.'):
    result = subprocess.run([os.environ['TRANSACTION_REAL_RM'], *args]).returncode
    if result:
        sys.exit(result)
    guard = prefix / '.dsr-install.lock'
    owner = (guard / 'owner').read_bytes()
    guard.rename(Path(os.environ['TRANSACTION_DISPLACED_LOCK']))
    guard.mkdir()
    (guard / 'owner').write_bytes(owner)
    (guard / 'foreign').write_bytes(b'preserve replacement lock resources')
    sys.exit(0)
os.execv(os.environ['TRANSACTION_REAL_RM'], [os.environ['TRANSACTION_REAL_RM'], *args])
''')
    cleanup_wrapper.chmod(0o755)
    cleanup_environment = environment | {'PATH': str(cleanup_tools) + os.pathsep + environment['PATH'],
                                        'TRANSACTION_REAL_RM': shutil.which('rm'),
                                        'TRANSACTION_PREFIX': str(destination),
                                        'TRANSACTION_DISPLACED_LOCK': str(work / 'displaced-lock')}
    changed = install('changed-lock-cleanup', script, destination, '3.0.0', packages['3.0.0'], cleanup_environment)
    check('changed lock ownership cannot report successful installation', changed.returncode != 0)
    check('changed lock cleanup retains the replacement owner and foreign files',
          (destination / '.dsr-install.lock/owner').is_file() and
          (destination / '.dsr-install.lock/foreign').read_bytes() == b'preserve replacement lock resources' and
          (work / 'displaced-lock/owner').is_file())
    check('cleanup ownership failure preserves the complete verified family', family(destination, '3.0.0'))

print(f'Installer transaction checks: {passed} passed, {failed} failed', flush=True)
sys.exit(1 if failed else 0)
PY
