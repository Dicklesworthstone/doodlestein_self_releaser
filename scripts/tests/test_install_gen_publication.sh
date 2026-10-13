#!/usr/bin/env bash
# Actual generator and POSIX publication: real directories, locks, processes,
# faulting file writes and readers. No downloads, installer execution or builds.
# Only complete generated --help is executed. All evidence is retained.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
exec python3 - "$ROOT" <<'PY'
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
module = Path(os.environ.get('GENERATOR_TEST_MODULE', str(root / 'src/install_gen.sh'))).resolve()
work = Path(tempfile.mkdtemp(prefix='dsr-installer-publication-')).resolve()
print('Publication evidence retained:', work, flush=True)
bins = work / 'bin'
bins.mkdir()
for name in ('bash', 'python3', 'grep', 'sed', 'cat', 'awk', 'dirname', 'basename',
             'mkdir', 'chmod', 'tr', 'cmp', 'sha256sum', 'shasum', 'wc', 'sort',
             'head', 'tar', 'base64', 'sleep', 'mktemp', 'cp'):
    selected = shutil.which(name)
    if selected:
        (bins / name).symlink_to(selected)
checks = failures = cases = 0
OLD = b'#!/usr/bin/env bash\nprintf "old installer\\n"\n'
SCRIPT = b'#!/usr/bin/env bash\nprintf "new installer\\n"\n'

# Apply a genuine kernel write limit only after Bash has delivered the Python
# here-document. Applying it to the whole generator would fail while Bash
# materializes its template, never reaching the staging write under test.
# This interpreter-boundary fault adapter changes no production predicate.
limited = work / 'limited-bin'
limited.mkdir()
(limited / 'python3').write_text('#!' + sys.executable + '\n' + r'''
import resource,sys
program = sys.stdin.buffer.read()
if len(sys.argv) > 4 and sys.argv[4] == 'publish':
    resource.setrlimit(resource.RLIMIT_FSIZE, (4096,4096))
sys.argv = sys.argv[2:]
exec(compile(program, '<production installer publisher>', 'exec'))
''')
(limited / 'python3').chmod(0o755)

def check(label, condition):
    global checks, failures
    checks += 1
    failures += not condition
    print(('ok ' if condition else 'not ok ') + str(checks) + ' - ' + label, flush=True)

def fresh(existing=True):
    global cases
    cases += 1
    case = work / ('case-%03d' % cases)
    for name in ('cwd', 'config/repos.d', 'out/example', 'outside/example'):
        (case / name).mkdir(parents=True)
    (case / 'config/repos.d/example.yaml').write_text(
        'tool_name: example\nrepo: owner/example\nbinary_name: example\nlanguage: go\n')
    if existing:
        (case / 'out/example/install.sh').write_bytes(OLD)
        (case / 'out/example/install.sh').chmod(0o751)
    (case / 'outside/example/install.sh').write_bytes(b'outside protected bytes\n')
    return case

def environment(case):
    env = {k:v for k,v in os.environ.items() if not k.startswith('BASH_FUNC_') and k not in ('BASH_ENV','ENV')}
    env.update(PATH=str(bins), HOME=str(case), DSR_CONFIG_DIR=str(case / 'config'),
               DSR_INSTALLER_DIR=str(case / 'out'), CASE_DIR=str(case), NO_COLOR='1')
    return env

def command(prefix='', action='install_gen_create example'):
    return [str(bins / 'bash'), '-c', 'source "$1" || exit $?; _IG_SCRIPT_DIR=$2; ' + prefix + '\n' + action,
            '_', str(module), str(root / 'src')]

def run(case, prefix='', action='install_gen_create example', incoming=None, limit=False, timeout=20):
    env = environment(case)
    if limit: env['PATH'] = str(limited) + os.pathsep + env['PATH']
    proc = subprocess.Popen(command(prefix, action), cwd=case / 'cwd', env=env,
                            stdin=subprocess.PIPE if incoming is not None else subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, err = proc.communicate(incoming, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        out, err = proc.communicate()
    result = subprocess.CompletedProcess(proc.args, proc.returncode, out, err)
    record = len(list(case.glob('run-*.json')))
    (case / ('run-%03d.json' % record)).write_text(json.dumps(dict(
        returncode=result.returncode, stdout=out.decode(errors='replace'), stderr=err.decode(errors='replace'))))
    return result

def state(path):
    info = path.stat()
    return (info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns, path.read_bytes())

def histories(case):
    return sorted((case / 'out/example').glob('.install-gen.*'))

case = fresh(False)
result = run(case)
active = case / 'out/example/install.sh'
check('complete actual renderer creates an executable installer and returns only its path',
      result.returncode == 0 and result.stdout.strip() == str(active).encode() and
      active.is_file() and stat.S_IMODE(active.stat().st_mode) == 0o755)
if active.is_file():
    parsed = subprocess.run([str(bins / 'bash'), '-n', active], capture_output=True)
    help_run = subprocess.run([str(bins / 'bash'), active, '--help'], capture_output=True, timeout=10)
    check('complete emitted template and source engine parse and run --help',
          parsed.returncode == help_run.returncode == 0 and b'Install example' in help_run.stdout)
    previous = state(active)
    count = len(histories(case))
    result = run(case)
    check('identical regeneration preserves inode, times, mode and generation-history count',
          result.returncode == 0 and state(active) == previous and len(histories(case)) == count)

case = fresh()
active = case / 'out/example/install.sh'
original = state(active)
with active.open('rb') as reader:
    result = run(case)
    old_reader = reader.read()
check('readers holding the previous inode never see partial or replacement bytes',
      result.returncode == 0 and old_reader == OLD and active.stat().st_ino != original[0])
previous = [p / 'previous.sh' for p in histories(case) if (p / 'previous.sh').is_file()]
check('successful replacement retains the exact previous installer in private history',
      len(previous) == 1 and previous[0].read_bytes() == OLD and
      stat.S_IMODE(previous[0].stat().st_mode) == 0o600 and
      json.loads((previous[0].parent / 'selection.json').read_text())['expected']['target']['sha256'] == hashlib.sha256(OLD).hexdigest())
check('publication completion binds the active bytes', len(previous) == 1 and
      json.loads((previous[0].parent / 'completed.json').read_text())['sha256'] == hashlib.sha256(active.read_bytes()).hexdigest())

for label, prefix, code in (
    ('renderer command failure', '_install_gen_template() { printf partial; return 23; };', 23),
    ('invalid generated syntax', '_install_gen_template() { printf "#!/usr/bin/env bash\\nif then\\n"; };', 6),
    ('empty generated output', '_install_gen_template() { :; };', 6),
    ('help renderer failure', 'awk() { return 19; };', 1)):
    case = fresh(); active = case / 'out/example/install.sh'; before = state(active)
    result = run(case, prefix)
    check(label + ' cannot truncate or report an existing installer as generated',
          result.returncode == code and not result.stdout and state(active) == before)
case = fresh(False)
result = run(case, '_install_gen_template() { printf "#!/usr/bin/env bash\\nif then\\n"; };')
check('invalid syntax never becomes a new live installer', result.returncode == 6 and
      not (case / 'out/example/install.sh').exists() and not histories(case))

for kind in ('file-link', 'dangling-file-link', 'hardlink', 'directory', 'fifo', 'tool-link', 'root-link', 'ancestor-link'):
    case = fresh(False)
    active = case / 'out/example/install.sh'
    outside = case / 'outside/example/install.sh'; before = state(outside)
    if kind == 'file-link': active.symlink_to(outside)
    elif kind == 'dangling-file-link': active.symlink_to(case / 'missing-target')
    elif kind == 'hardlink': os.link(outside, active)
    elif kind == 'directory': active.mkdir()
    elif kind == 'fifo': os.mkfifo(active)
    elif kind == 'tool-link':
        active.parent.rename(case / 'original-tool-dir')
        active.parent.symlink_to(case / 'outside/example')
    elif kind == 'root-link':
        (case / 'out').rename(case / 'original-output-root')
        (case / 'out').symlink_to(case / 'outside')
    else:
        (case / 'linked-ancestor').symlink_to(case / 'outside')
    before = state(outside)  # Creating a hardlink itself changes its ctime.
    prefix = '_IG_OUTPUT_DIR="$CASE_DIR/linked-ancestor/new-output";' if kind == 'ancestor-link' else ''
    result = run(case, prefix, timeout=2 if kind == 'fifo' else 20)
    check(kind + ' is refused without writing the symlink/hardlink target or reporting success',
          result.returncode > 0 and not result.stdout and state(outside) == before and
          not (case / 'missing-target').exists() and not (case / 'outside/new-output').exists())

for kind in ('symlink', 'hardlink', 'directory', 'fifo', 'public-mode', 'busy'):
    case = fresh(); active = case / 'out/example/install.sh'; before = state(active)
    lock = active.parent / '.install-gen.lock'
    target = case / 'lock-target'; target.write_bytes(b'retained lock bytes')
    held = None
    if kind == 'symlink': lock.symlink_to(target)
    elif kind == 'hardlink': os.link(target, lock)
    elif kind == 'directory': lock.mkdir()
    elif kind == 'fifo': os.mkfifo(lock)
    else:
        lock.write_bytes(b''); lock.chmod(0o644 if kind == 'public-mode' else 0o600)
        if kind == 'busy':
            held = lock.open('r+b'); fcntl.flock(held, fcntl.LOCK_EX)
    result = run(case)
    if held: held.close()
    check('publication lock ' + kind + ' cannot permit a destructive write',
          result.returncode != 0 and not result.stdout and state(active) == before and target.read_bytes() == b'retained lock bytes')

case = fresh(); active = case / 'out/example/install.sh'; before = state(active)
result = run(case, limit=True)
check('real file-size-limit failure preserves the previous installer without a success path',
      result.returncode != 0 and not result.stdout and state(active) == before)
check('failed staging retains the original backup and candidate rather than deleting evidence',
      any((p / 'previous.sh').is_file() and (p / 'previous.sh').read_bytes() == OLD and
          (p / 'candidate.sh').is_file() for p in histories(case)))
result = run(case)
check('ordinary retry after a killed or failed writer succeeds without stale lock removal',
      result.returncode == 0 and active.read_bytes() != OLD)

# Pause only rendering, after the production output observation. The original
# renderer still emits the full script. This is controlled fault timing, not a
# replacement for any production path/lock/hash/publication gate.
BARRIER = r'''
saved=$(declare -f _install_gen_template)
eval "${saved/_install_gen_template/_publication_original_template}"
_install_gen_template() {
    _publication_original_template "$@" || return $?
    printf '%s\n' "# publisher ${SLOT:-one}"
    printf ready > "$CASE_DIR/ready-${SLOT:-one}"
    while [[ ! -f "$CASE_DIR/go" ]]; do sleep 0.02; done
}
'''
def start(case, slot='one'):
    env = environment(case); env['SLOT'] = slot
    return subprocess.Popen(command(BARRIER), cwd=case / 'cwd', env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
def await_ready(case, proc, slot='one'):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        if (case / ('ready-' + slot)).exists(): return True
        if proc.poll() is not None: return False
        time.sleep(0.02)
    return False
def finish(case, proc):
    try: out, err = proc.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL); out, err = proc.communicate()
    (case / ('process-%d.json' % proc.pid)).write_text(json.dumps(dict(code=proc.returncode,
        stdout=out.decode(errors='replace'), stderr=err.decode(errors='replace'))))
    return proc.returncode, out, err

for kind in ('changed-bytes', 'same-bytes-new-inode', 'new-destination', 'moved-tool-directory', 'new-root-symlink'):
    case = fresh(kind != 'new-destination')
    active = case / 'out/example/install.sh'
    outside = case / 'outside/example/install.sh'; outside_before = state(outside)
    proc = start(case); ready = await_ready(case, proc)
    if ready:
        if kind == 'changed-bytes': active.write_bytes(b'external edit retained\n')
        elif kind == 'same-bytes-new-inode':
            active.rename(active.parent / 'retained-original.sh'); active.write_bytes(OLD); active.chmod(0o751)
        elif kind == 'new-destination': active.write_bytes(b'other publisher output\n')
        elif kind == 'moved-tool-directory':
            active.parent.rename(case / 'retained-tool'); active.parent.mkdir(); active.write_bytes(OLD)
        else:
            (case / 'out').rename(case / 'retained-root'); (case / 'out').symlink_to(case / 'outside')
    before = state(active) if active.is_file() else None
    (case / 'go').write_text('go')
    code, out, err = finish(case, proc)
    check(kind + ' during rendering refuses the stale publication',
          ready and code != 0 and not out and state(active) == before and state(outside) == outside_before)

case = fresh()
first, second = start(case, 'a'), start(case, 'b')
ready = await_ready(case, first, 'a') and await_ready(case, second, 'b')
(case / 'go').write_text('go')
a, b = finish(case, first), finish(case, second)
check('competing full generators permit exactly one publication from the same starting observation',
      ready and sorted((a[0], b[0])) == [0,2] and len([p for p in histories(case) if (p / 'completed.json').is_file()]) == 1)
winner = b'a' if a[0] == 0 else b'b'
check('the winner is complete and the losing writer does not replace its output',
      ready and (case / 'out/example/install.sh').read_bytes().endswith(b'# publisher ' + winner + b'\n'))

case = fresh()
(case / 'cwd/.claude/skills/example').mkdir(parents=True)
(case / 'cwd/.claude/skills/example/SKILL.md').write_text('owned skill input\n')
before = state(case / 'out/example/install.sh')
result = run(case, 'tar() { return 17; };')
check('skill archiving failure does not silently publish an incomplete installer',
      result.returncode == 1 and not result.stdout and state(case / 'out/example/install.sh') == before)

case = fresh()
result = run(case, '_IG_OUTPUT_DIR="./new root/nested";')
check('safe relative output roots with spaces and absent parents remain usable',
      result.returncode == 0 and result.stdout.strip() == b'./new root/nested/example/install.sh' and
      (case / 'cwd/new root/nested/example/install.sh').is_file())
case = fresh()
result = run(case, '_IG_OUTPUT_DIR="$CASE_DIR/out/../outside";')
check('explicit output-root parent traversal is refused', result.returncode == 4 and not result.stdout and
      (case / 'outside/example/install.sh').read_bytes() == b'outside protected bytes\n')

# Direct helper checks cover the byte stream, not a second hand-written gate.
for label, data, expected_code in (('NUL', SCRIPT + b'\0', 6), ('missing shebang', b'echo no\n', 6),
                                   ('large input off exec argv', SCRIPT + b'#' + b'x'*400000 + b'\n', 0)):
    case = fresh(False)
    plan = run(case, action='_install_gen_output inspect "$_IG_OUTPUT_DIR" example')
    token_file = case / 'observation.json'; token_file.write_bytes(plan.stdout)
    result = run(case, action='_install_gen_output publish "$_IG_OUTPUT_DIR" example "$(cat "$CASE_DIR/observation.json")"', incoming=data)
    check('publisher ' + label, plan.returncode == 0 and result.returncode == expected_code and
          ((case / 'out/example/install.sh').read_bytes() == data if expected_code == 0 else
           not (case / 'out/example/install.sh').exists()))

case = fresh(False)
plan = run(case, action='_install_gen_output inspect "$_IG_OUTPUT_DIR" example')
(case / 'observation.json').write_bytes(plan.stdout)
script = b'#!/usr/bin/env bash\nprintf touched > "' + str(case / 'must-not-execute').encode() + b'"\n'
(case / 'startup').write_text('printf touched > "' + str(case / 'startup-must-not-execute') + '"\n')
result = run(case, prefix='export BASH_ENV="$CASE_DIR/startup";',
             action='_install_gen_output publish "$_IG_OUTPUT_DIR" example "$(cat "$CASE_DIR/observation.json")"', incoming=script)
check('syntax validation never executes the candidate or an inherited Bash startup file',
      plan.returncode == result.returncode == 0 and not (case / 'must-not-execute').exists() and
      not (case / 'startup-must-not-execute').exists())
print(json.dumps(dict(checks=checks, failures=failures, evidence=str(work))), flush=True)
sys.exit(1 if failures else 0)
PY
