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
import select
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

root = Path(sys.argv[1])
client_bash = os.environ.get('DSR_TEST_INSTALLER_BASH', 'bash')
baseline = sys.argv[2:] == ['--baseline-reproduction']
crash_reproduction = sys.argv[2:] == ['--crash-reproduction']
if sys.argv[2:] not in ([], ['--baseline-reproduction'], ['--crash-reproduction']):
    raise SystemExit('Usage: test_generated_installer_transactions.sh [--baseline-reproduction|--crash-reproduction]')
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
    result = [client_bash, str(script), '--version', 'v' + version, '--dir', str(directory),
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
import os, signal, subprocess, sys, time
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
if mode in ('pause', 'resist') and source.endswith('/new/demo') and destination == os.environ['TRANSACTION_PREFIX'] + '/demo':
    (root / 'backups-ready').write_text(str(os.getppid()))
    wait('allow-primary')
    status = subprocess.run([os.environ['TRANSACTION_REAL_MV'], *args]).returncode
    if status:
        sys.exit(status)
    if mode == 'resist':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    (root / 'primary-committed').write_text('yes')
    wait('finish-primary')
    sys.exit(0)
if mode == 'pause-worker' and source.endswith('/new/worker') and destination == os.environ['TRANSACTION_PREFIX'] + '/worker':
    status = subprocess.run([os.environ['TRANSACTION_REAL_MV'], *args]).returncode
    if status:
        sys.exit(status)
    (root / 'worker-committed').write_text(str(os.getppid()))
    wait('finish-worker')
    sys.exit(0)
if ((mode == 'pause-complete' and destination == os.environ['TRANSACTION_PREFIX'] + '/.dsr-install.lock/completion') or
    (mode == 'pause-retired' and source == os.environ['TRANSACTION_PREFIX'] + '/.dsr-install.lock')):
    status = subprocess.run([os.environ['TRANSACTION_REAL_MV'], *args]).returncode
    if status:
        sys.exit(status)
    (root / mode).write_text(str(os.getppid()))
    wait('finish-' + mode)
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
seed_directory = work / 'seed'
seed_directory.mkdir()
for name in names:
    shutil.copy2(destination / name, seed_directory / name)
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
    if crash_reproduction:
        (control / 'allow-primary').touch()
        wait_for(control / 'primary-committed', writer)
        os.killpg(os.getpgid(int((control / 'backups-ready').read_text())), signal.SIGKILL)
        writer.communicate(timeout=10)
        check('uncatchable interruption leaves a mixed executable family',
              (destination / 'demo').read_bytes() == payload('demo', '3.0.0') and
              (destination / 'worker').read_bytes() == payload('worker', '1.0.0'))
        retained = snapshot(destination)
        retried = install('crash-retry', script, destination, '3.0.0', packages['3.0.0'])
        check('ordinary retry refuses the abandoned transaction and preserves its evidence',
              retried.returncode != 0 and snapshot(destination) == retained and
              (destination / '.dsr-install.lock/owner').is_file())
        recovery = subprocess.run([client_bash, str(script), '--recover', '--yes', '--dir', str(destination), '--json'],
                                  env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        record('crash-recovery-unavailable', recovery)
        check('unchanged installer has no explicit crash recovery operation',
              recovery.returncode == 4 and b'Unknown option: --recover' in recovery.stderr and
              snapshot(destination) == retained)
        print(f'Installer crash reproduction checks: {passed} passed, {failed} failed', flush=True)
        raise SystemExit(1 if failed else 0)
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

    # Replace the guard after its completion marker is published but before
    # retirement. Successful cleanup now removes an already retired lock.
    # The new directory deliberately has identical owner bytes: inode binding,
    # rather than a token-only comparison, must protect the replacement.
    cleanup_tools = work / 'cleanup-tools'
    cleanup_tools.mkdir()
    cleanup_wrapper = cleanup_tools / 'mv'
    cleanup_wrapper.write_text('''#!''' + sys.executable + '''
import os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
source, target = map(Path, args[-2:])
prefix = Path(os.environ['TRANSACTION_PREFIX'])
if target == prefix / '.dsr-install.lock/completion' and source.name == 'completion.pending':
    result = subprocess.run([os.environ['TRANSACTION_REAL_MV'], *args]).returncode
    if result:
        sys.exit(result)
    guard = prefix / '.dsr-install.lock'
    owner = (guard / 'owner').read_bytes()
    guard.rename(Path(os.environ['TRANSACTION_DISPLACED_LOCK']))
    guard.mkdir()
    (guard / 'owner').write_bytes(owner)
    (guard / 'foreign').write_bytes(b'preserve replacement lock resources')
    sys.exit(0)
os.execv(os.environ['TRANSACTION_REAL_MV'], [os.environ['TRANSACTION_REAL_MV'], *args])
''')
    cleanup_wrapper.chmod(0o755)
    cleanup_environment = environment | {'PATH': str(cleanup_tools) + os.pathsep + environment['PATH'],
                                        'TRANSACTION_REAL_MV': real_mv,
                                        'TRANSACTION_PREFIX': str(destination),
                                        'TRANSACTION_DISPLACED_LOCK': str(work / 'displaced-lock')}
    changed = install('changed-lock-cleanup', script, destination, '3.0.0', packages['3.0.0'], cleanup_environment)
    check('changed lock ownership cannot report successful installation', changed.returncode != 0)
    check('changed lock cleanup retains the replacement owner and foreign files',
          (destination / '.dsr-install.lock/owner').is_file() and
          (destination / '.dsr-install.lock/foreign').read_bytes() == b'preserve replacement lock resources' and
          (work / 'displaced-lock/owner').is_file())
    check('cleanup ownership failure preserves the complete verified family', family(destination, '3.0.0'))

    def seed_prefix(label, fresh=False):
        prefix = work / label
        prefix.mkdir()
        if not fresh:
            for name, mode in zip(names, (0o751, 0o711)):
                shutil.copy2(seed_directory / name, prefix / name)
                (prefix / name).chmod(mode)
        (prefix / 'unrelated').write_bytes(b'preserve unrelated recovery data\n')
        return prefix

    def tree_snapshot(prefix):
        result = {}
        for path in sorted(prefix.rglob('*')):
            info = path.lstat()
            value = path.read_bytes() if stat.S_ISREG(info.st_mode) else os.readlink(path) if path.is_symlink() else None
            result[str(path.relative_to(prefix))] = (info.st_ino, info.st_mode, info.st_nlink, value)
        return result

    def recover(label, prefix, selected=script, env=environment, consent=True, umask=None):
        args = [client_bash, str(selected), '--recover', '--dir', str(prefix), '--json', '--non-interactive']
        if consent:
            args.append('--yes')
        result = subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
                                preexec_fn=(lambda: os.umask(umask)) if umask is not None else None)
        value = record(label, result)
        return result, value

    def paused_writer(label, full=False, fresh=False, completion=None, resistant=False, umask=None):
        prefix = seed_prefix(label, fresh)
        gate = work / 'control' / label
        gate.mkdir()
        env = writer_environment | {'TRANSACTION_CONTROL': str(gate), 'TRANSACTION_PREFIX': str(prefix),
                                    'TRANSACTION_MODE': completion or ('pause-worker' if full else 'resist' if resistant else 'pause')}
        process = subprocess.Popen(arguments(script, prefix, '3.0.0', packages['3.0.0']), env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                                   preexec_fn=(lambda: os.umask(umask)) if umask is not None else None)
        if not full and not completion:
            wait_for(gate / 'backups-ready', process)
            (gate / 'allow-primary').touch()
        wait_for(gate / (completion or ('worker-committed' if full else 'primary-committed')), process)
        if completion == 'pause-retired':
            group = int((gate / completion).read_text())
        else:
            journal = json.loads((prefix / '.dsr-install.lock/journal.json').read_bytes())
            group = journal['process_group']
        check(label + ' records the actual isolated transaction group', os.getpgid(group) == group and group != process.pid)
        return prefix, gate, process, group

    def kill_writer(label, process, group):
        os.killpg(group, signal.SIGKILL)
        out, err = process.communicate(timeout=10)
        (work / 'results' / (label + '-killed.out')).write_bytes(out)
        (work / 'results' / (label + '-killed.err')).write_bytes(err)
        check(label + ' actual transaction group was killed', process.returncode != 0)

    prefix, gate, process, group = paused_writer('crash-recovery')
    try:
        before_recovery = tree_snapshot(prefix)
        active, _ = recover('live-writer-recovery', prefix)
        check('recovery refuses the live writer without changing transaction evidence',
              active.returncode == 2 and tree_snapshot(prefix) == before_recovery)
        os.kill(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        orphan, _ = recover('orphan-writer-recovery', prefix)
        check('killing only the public installer does not authorize recovery over its live writer group',
              orphan.returncode == 2 and tree_snapshot(prefix) == before_recovery)
        os.kill(group, signal.SIGKILL)
        descendant, _ = recover('live-descendant-recovery', prefix)
        check('a live rename descendant still blocks recovery after its writer dies',
              descendant.returncode == 2 and tree_snapshot(prefix) == before_recovery)
        os.killpg(group, signal.SIGKILL)
        process.communicate(timeout=10)
        no_consent, _ = recover('recovery-consent', prefix, consent=False)
        check('recovery requires its own explicit yes consent', no_consent.returncode == 4 and tree_snapshot(prefix) == before_recovery)
        no_python_tools = work / 'no-recovery-python'
        no_python_tools.mkdir()
        for name in ('bash', 'uname', 'tr', 'dirname'):
            (no_python_tools / name).symlink_to(shutil.which(name))
        no_python, _ = recover('recovery-missing-python', prefix, env=environment | {'PATH': str(no_python_tools)})
        check('missing recovery Python returns a dependency refusal without modifying evidence',
              no_python.returncode == 3 and b'Python 3 is required' in no_python.stderr and tree_snapshot(prefix) == before_recovery)
        wrong_tool, _ = recover('recovery-wrong-tool', prefix, selected=other_script)
        check('another tool cannot adopt a retained transaction', wrong_tool.returncode == 4 and tree_snapshot(prefix) == before_recovery)
        restored, value = recover('recover-mixed-family', prefix)
        check('explicit recovery restores every previous byte and mode',
              restored.returncode == 0 and family(prefix, '1.0.0') and
              [stat.S_IMODE((prefix / name).stat().st_mode) for name in names] == [0o751, 0o711])
        archive_path = Path(value.get('recovery', {}).get('evidence_path', 'missing'))
        check('recovery retains original backup bytes and releases the exact common lock',
              archive_path.is_dir() and not (prefix / '.dsr-install.lock').exists() and
              all((archive_path / 'evidence/old' / name).read_bytes() == payload(name, '1.0.0') for name in names))
        check('recovery receipt distinguishes rollback from a new installation',
              value.get('action') == 'recover' and value.get('version') == '' and
              value.get('recovery', {}).get('outcome') == 'rolled-back' and value['recovery']['recovered'] is True)
        unchanged = tree_snapshot(prefix)
        repeated, value = recover('repeat-recovery', prefix)
        check('repeated completed recovery is a read-only no-op', repeated.returncode == 0 and
              value.get('recovery', {}).get('outcome') == 'nothing-to-recover' and tree_snapshot(prefix) == unchanged)
        resumed = install('install-after-recovery', script, prefix, '2.0.0', packages['2.0.0'])
        check('a normal installation proceeds after explicit recovery', resumed.returncode == 0 and family(prefix, '2.0.0'))
    finally:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=10)

    prefix, gate, process, group = paused_writer('first-install-recovery', fresh=True)
    kill_writer('first-install-recovery', process, group)
    result, value = recover('recover-first-install', prefix)
    check('recovery removes only owned new members from an interrupted first installation',
          result.returncode == 0 and all(not (prefix / name).exists() for name in names) and
          (prefix / 'unrelated').read_bytes() == b'preserve unrelated recovery data\n')

    prefix, gate, process, group = paused_writer('completed-recovery', completion='pause-complete')
    kill_writer('completed-recovery', process, group)
    result, value = recover('recover-completed-installation', prefix)
    check('a recorded completed installation retains its verified new family during recovery',
          result.returncode == 0 and family(prefix, '3.0.0') and
          value.get('recovery', {}).get('outcome') == 'committed' and not (prefix / '.dsr-install.lock').exists())

    prefix, gate, process, group = paused_writer('cleanup-interruption', completion='pause-retired')
    kill_writer('cleanup-interruption', process, group)
    result, value = recover('recover-after-lock-retirement', prefix)
    check('interrupted cleanup cannot strand the shared lock after backup disposal begins',
          result.returncode == 0 and value.get('recovery', {}).get('outcome') == 'nothing-to-recover' and
          family(prefix, '3.0.0') and not (prefix / '.dsr-install.lock').exists())
    result = install('retry-after-cleanup-interruption', script, prefix, '2.0.0', packages['2.0.0'])
    check('a new installation succeeds after an interrupted retired-stage cleanup', result.returncode == 0 and family(prefix, '2.0.0'))

    prefix, gate, process, group = paused_writer('handled-foreign-edit')
    (prefix / 'worker').write_bytes(b'concurrent later-member edit\n')
    initial = snapshot(prefix)
    process.send_signal(signal.SIGTERM)
    (gate / 'finish-primary').touch()
    out, err = process.communicate(timeout=15)
    record('handled-foreign-edit', subprocess.CompletedProcess(process.args, process.returncode, out, err))
    check('handled rollback inspects the later family member before restoring the earlier one',
          process.returncode != 0 and snapshot(prefix) == initial and
          (prefix / '.dsr-install.lock/journal.json').is_file())

    prefix, gate, process, group = paused_writer('resistant-cancellation', resistant=True)
    started = time.monotonic()
    process.send_signal(signal.SIGTERM)
    out, err = process.communicate(timeout=12)
    elapsed = time.monotonic() - started
    record('resistant-cancellation', subprocess.CompletedProcess(process.args, process.returncode, out, err))
    check('public cancellation bounds a real TERM-resistant rename child',
          process.returncode == 5 and elapsed < 10 and (prefix / '.dsr-install.lock/journal.json').is_file())
    result, value = recover('recover-resistant-cancellation', prefix)
    check('forced cancellation retains enough evidence to restore the complete prior family',
          result.returncode == 0 and family(prefix, '1.0.0'))

    prefix, gate, process, group = paused_writer('collaborative-umask', umask=0o002)
    journal = json.loads((prefix / '.dsr-install.lock/journal.json').read_bytes())
    check('caller umask cannot make staged recovery directories writable by other users',
          all(stat.S_IMODE((prefix / journal['stage'] / name).stat().st_mode) == 0o700 for name in ('new', 'old', 'restore')))
    kill_writer('collaborative-umask', process, group)
    result, value = recover('recover-collaborative-umask', prefix, umask=0o777)
    check('an interrupted installation under umask002 remains recoverable', result.returncode == 0 and family(prefix, '1.0.0'))
    archive_path = Path(value.get('recovery', {}).get('evidence_path', 'missing'))
    check('restrictive recovery umask still preserves accessible private evidence',
          stat.S_IMODE(archive_path.parent.stat().st_mode) == 0o700 and
          stat.S_IMODE((archive_path / 'recovery-result.json').stat().st_mode) == 0o600)

    for fault in ('changed-later-member', 'replaced-same-bytes', 'changed-backup', 'foreign-stage-file', 'replaced-lock', 'wrong-process-scope'):
        prefix, gate, process, group = paused_writer(fault)
        kill_writer(fault, process, group)
        journal = json.loads((prefix / '.dsr-install.lock/journal.json').read_bytes())
        if fault == 'changed-later-member':
            (prefix / 'worker').write_bytes(b'independent user edit\n')
        elif fault == 'replaced-same-bytes':
            replacement = work / (fault + '-replacement')
            replacement.write_bytes((prefix / 'worker').read_bytes())
            replacement.chmod(0o711)
            replacement.replace(prefix / 'worker')
        elif fault == 'changed-backup':
            (prefix / journal['stage'] / 'old/worker').write_bytes(b'changed backup\n')
        elif fault == 'foreign-stage-file':
            (prefix / journal['stage'] / 'foreign').write_bytes(b'preserve unrelated evidence\n')
        elif fault == 'replaced-lock':
            guard = prefix / '.dsr-install.lock'
            guard.rename(prefix / 'original-lock')
            shutil.copytree(prefix / 'original-lock', guard)
        else:
            journal['process_scope'] = 'unobserved-foreign-process-namespace'
            (prefix / '.dsr-install.lock/journal.json').write_text(json.dumps(journal) + '\n')
        initial = tree_snapshot(prefix)
        refused, _ = recover('refuse-' + fault, prefix)
        check(fault + ' refuses before any family or evidence mutation', refused.returncode == 4 and tree_snapshot(prefix) == initial)

    # Kill recovery after a real Python rename, then resume the exact journal.
    # The adapter runs the unmodified generated program in the genuine Python
    # interpreter and pauses only around one filesystem primitive; it supplies
    # no result, journal, lease, process census or artifact-verification output.
    recovery_tools = work / 'recovery-tools'
    recovery_tools.mkdir()
    recovery_python = recovery_tools / 'python3'
    recovery_python.write_text('#!' + sys.executable + ' -I\n' + r'''
import os, sys, time
from pathlib import Path
assert sys.argv[1:3] == ['-I', '-'], sys.argv
program = sys.stdin.read()
sys.argv = sys.argv[2:]
control = Path(os.environ['RECOVERY_CONTROL'])
mode = os.environ['RECOVERY_PAUSE']
real_replace, real_rename = os.replace, os.rename
def pause():
    (control / 'recovery-paused').write_text(str(os.getpid()))
    deadline = time.monotonic() + 30
    while not (control / 'continue-recovery').exists():
        if time.monotonic() > deadline:
            raise RuntimeError('recovery fixture timed out')
        time.sleep(0.02)
def replace(source, destination, *args, **kwargs):
    result = real_replace(source, destination, *args, **kwargs)
    if mode == 'member' and source == 'demo':
        pause()
    return result
def rename(source, destination, *args, **kwargs):
    if mode == 'receipt' and source == 'recovery-result.pending':
        pause()
    return real_rename(source, destination, *args, **kwargs)
os.replace, os.rename = replace, rename
exec(compile(program, '<generated-installer-recovery>', 'exec'), {'__name__': '__main__'})
''')
    recovery_python.chmod(0o755)
    for boundary in ('member', 'receipt'):
        prefix, gate, process, group = paused_writer('recover-retry-' + boundary, full=True)
        kill_writer('recover-retry-' + boundary, process, group)
        env = environment | {'PATH': str(recovery_tools) + os.pathsep + environment['PATH'],
                             'RECOVERY_CONTROL': str(gate), 'RECOVERY_PAUSE': boundary}
        recovery = subprocess.Popen([client_bash, str(script), '--recover', '--yes', '--dir', str(prefix), '--json'],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            wait_for(gate / 'recovery-paused', recovery)
            check(boundary + ' recovery reached an actual restoration boundary',
                  (prefix / 'demo').read_bytes() == payload('demo', '1.0.0'))
            initial = tree_snapshot(prefix)
            contender, _ = recover('competing-recovery-' + boundary, prefix)
            check(boundary + ' concurrent recovery cannot acquire the live recovery lease',
                  contender.returncode == 2 and tree_snapshot(prefix) == initial)
            os.killpg(recovery.pid, signal.SIGKILL)
            recovery.communicate(timeout=10)
            restarted, value = recover('restart-recovery-' + boundary, prefix)
            check(boundary + ' interrupted recovery can restart and restore the entire family',
                  restarted.returncode == 0 and family(prefix, '1.0.0') and not (prefix / '.dsr-install.lock').exists())
            archive_path = Path(value.get('recovery', {}).get('evidence_path', 'missing'))
            check(boundary + ' retry preserves the immutable original backups',
                  all((archive_path / 'evidence/old' / name).read_bytes() == payload(name, '1.0.0') for name in names))
        finally:
            if recovery.poll() is None:
                os.killpg(recovery.pid, signal.SIGKILL)
            recovery.communicate(timeout=10)

    prefix, gate, process, group = paused_writer('recovery-owner-replacement', full=True)
    kill_writer('recovery-owner-replacement', process, group)
    env = environment | {'PATH': str(recovery_tools) + os.pathsep + environment['PATH'],
                         'RECOVERY_CONTROL': str(gate), 'RECOVERY_PAUSE': 'member'}
    recovery = subprocess.Popen([client_bash, str(script), '--recover', '--yes', '--dir', str(prefix), '--json'],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        wait_for(gate / 'recovery-paused', recovery)
        owner = prefix / '.dsr-install.lock/owner'
        replacement = work / 'replacement-recovery-owner'
        replacement.write_bytes(owner.read_bytes())
        replacement.chmod(0o600)
        replacement.replace(owner)
        initial = tree_snapshot(prefix)
        contender, _ = recover('replaced-owner-contender', prefix)
        check('a replaced owner cannot split recoverers onto independent kernel leases',
              contender.returncode == 4 and tree_snapshot(prefix) == initial)
        (gate / 'continue-recovery').touch()
        out, err = recovery.communicate(timeout=10)
        record('replaced-owner-active-recovery', subprocess.CompletedProcess(recovery.args, recovery.returncode, out, err))
        check('the active recoverer rechecks its held owner inode before another mutation',
              recovery.returncode == 4 and tree_snapshot(prefix) == initial)
    finally:
        if recovery.poll() is None:
            os.killpg(recovery.pid, signal.SIGKILL)
        recovery.communicate(timeout=10)

    prefix = seed_prefix('hardlinked-family', fresh=True)
    shutil.copy2(seed_directory / 'demo', prefix / 'demo')
    os.link(prefix / 'demo', prefix / 'worker')
    initial = tree_snapshot(prefix)
    result = install('hardlinked-family', script, prefix, '3.0.0', packages['3.0.0'])
    check('shared original family inodes are refused before the first replacement without stranding a lock',
          result.returncode == 4 and tree_snapshot(prefix) == initial)
    prefix = seed_prefix('external-hardlink')
    os.link(prefix / 'demo', prefix / 'external')
    external = (prefix / 'external').read_bytes(), (prefix / 'external').stat().st_ino
    result = install('external-hardlink', script, prefix, '3.0.0', packages['3.0.0'])
    check('unrelated external hardlinks retain their original bytes and inode during a normal replacement',
          result.returncode == 0 and family(prefix, '3.0.0') and
          ((prefix / 'external').read_bytes(), (prefix / 'external').stat().st_ino) == external)

    # The isolated writer never owns the controlling terminal. Real foreground
    # prompts must still work, and their approvals must reject subsequent edits.
    import fcntl
    import pty
    import termios
    for change_after_consent in (False, True):
        label = 'interactive-consent-change' if change_after_consent else 'interactive-consent'
        prefix = seed_prefix(label)
        master, slave = pty.openpty()
        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            os.tcsetpgrp(slave, os.getpgrp())
        args = [arg for arg in arguments(script, prefix, '3.0.0', packages['3.0.0'], yes=False) if arg != '--non-interactive']
        process = subprocess.Popen(args, env=environment, stdin=slave, stdout=subprocess.PIPE, stderr=slave,
                                   preexec_fn=controlling_terminal)
        os.close(slave)
        transcript = b''
        try:
            for number in (1, 2):
                deadline = time.monotonic() + 15
                while transcript.count(b'Overwrite? [y/N]') < number:
                    if time.monotonic() >= deadline or process.poll() is not None:
                        raise RuntimeError(label + ' did not reach foreground prompt: ' + transcript.decode(errors='replace'))
                    ready, _, _ = select.select([master], [], [], 0.2)
                    if ready:
                        transcript += os.read(master, 4096)
                if number == 2 and change_after_consent:
                    (prefix / 'demo').write_bytes(b'changed after first approval\n')
                os.write(master, b'y\n')
            out, _ = process.communicate(timeout=20)
            (work / 'results' / (label + '.tty')).write_bytes(transcript)
            check(label + ' returns one JSON result', json.loads(out).get('status') == ('error' if change_after_consent else 'success'))
            if change_after_consent:
                check('changed foreground approval refuses replacement under the lock',
                      process.returncode != 0 and (prefix / 'demo').read_bytes() == b'changed after first approval\n' and
                      (prefix / 'worker').read_bytes() == payload('worker', '1.0.0') and not (prefix / '.dsr-install.lock').exists())
            else:
                check('foreground prompts install the full family without stopping the isolated writer',
                      process.returncode == 0 and family(prefix, '3.0.0'))
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
            os.close(master)

print(f'Installer transaction checks: {passed} passed, {failed} failed', flush=True)
sys.exit(1 if failed else 0)
PY
