#!/usr/bin/env bash
# Actual persistence helper and sync command, no network or downstream writes.
# Files, hardlinks, FIFO and RLIMIT_FSIZE are real. Full-command fault cases
# preoccupy names at the mktemp boundary; the production publisher is unchanged.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
exec python3 -I -S - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import resource
import stat
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]); module = root / 'src/checksum_sync.sh'
work = Path(tempfile.mkdtemp(prefix='dsr-sync-results-')).resolve()
print('Result persistence evidence retained: ' + str(work), flush=True)
checks = failures = 0

def check(label, condition):
    global checks, failures
    checks += 1; failures += not condition
    print(('ok ' if condition else 'not ok ') + str(checks) + ' - ' + label, flush=True)

def retain(folder, data, name='result.json', limit=False):
    def limited():
        resource.setrlimit(resource.RLIMIT_FSIZE, (4096, 4096))
    proc = subprocess.run(['bash', '-c', 'source "$1" || exit $?; _cs_retain_sync_json "$2" "$3"', '_', module, folder, name],
                          input=data, capture_output=True, timeout=15, preexec_fn=limited if limit else None)
    return proc

folder = work / 'large'; folder.mkdir()
data = json.dumps(dict(status='success', exit_code=0, evidence='real-data-' * 40000)).encode() + b'\n'
proc = retain(folder, data)
check('large JSON stays on stdin and is retained byte-for-byte', proc.returncode == 0 and not proc.stdout and
      (folder / 'result.json').read_bytes() == data)
check('published result is private', stat.S_IMODE((folder / 'result.json').stat().st_mode) == 0o600)
old = (folder / 'result.json').stat()
proc = retain(folder, b'{"other":true}\n')
check('existing result is not overwritten', proc.returncode != 0 and (folder / 'result.json').read_bytes() == data and
      (folder / 'result.json').stat().st_ino == old.st_ino)

for kind in ('symlink', 'directory', 'fifo', 'bad-json', 'duplicate-json', 'nonfinite-json', 'array-json', 'write-failure'):
    folder = work / kind; folder.mkdir()
    outside = folder / 'protected'; outside.write_bytes(b'preserve this file\n')
    dest = folder / 'result.json'
    content = b'{"status":"success","exit_code":0}\n'
    if kind == 'symlink': dest.symlink_to(outside)
    elif kind == 'directory': dest.mkdir()
    elif kind == 'fifo': os.mkfifo(dest)
    elif kind == 'bad-json': content = b'{'
    elif kind == 'duplicate-json': content = b'{"a":1,"a":2}'
    elif kind == 'nonfinite-json': content = b'{"a":NaN}'
    elif kind == 'array-json': content = b'[]'
    elif kind == 'write-failure': content = data
    proc = retain(folder, content, limit=(kind == 'write-failure'))
    check(kind + ' cannot publish or overwrite evidence', proc.returncode != 0 and not proc.stdout and
          outside.read_bytes() == b'preserve this file\n' and (kind in ('symlink','directory','fifo') or not dest.exists()))
    if kind == 'write-failure':
        check('kernel write refusal retains its incomplete candidate', any(folder.glob('.sync-result.*.json')))

folder = work / 'safe-name'; folder.mkdir()
proc = retain(folder, b'{}', '../outside.json')
check('receipt names cannot traverse out of the workspace', proc.returncode != 0 and not (work / 'outside.json').exists())

serial = 0

def sync(*, json_mode=True, bad_manifest=False, occupy=None):
    global serial
    serial += 1
    case = work / ('command-%02d' % serial); case.mkdir()
    (case / 'tmp').mkdir(); (case / 'home').mkdir()
    manifest = case / 'input.sha256'
    manifest.write_text('bad manifest\n' if bad_manifest else 'a' * 64 + '  tool.tar.gz\n')
    env = {k:v for k,v in os.environ.items() if not k.startswith('BASH_FUNC_') and k not in ('BASH_ENV','ENV')}
    env.update(TMPDIR=str(case / 'tmp'), HOME=str(case / 'home'), DSR_STATE_DIR=str(case / 'state'))
    args = ['sync', 'tool', '1.2.3', '--repo', 'owner/tool', '--target-repo', 'owner/a', '--target-repo', 'owner/b',
            '--manifest', str(manifest), '--dry-run']
    if json_mode: args.append('--json')
    if occupy is not None:
        code = '''source "$1" || exit $?; shift; occupied=$1; shift
mktemp() {
    local path
    path=$(command mktemp "$@") || return $?
    if [[ "$path" == */dsr-checksum-sync.* ]]; then
        printf 'preexisting evidence\\n' > "$path/$occupied"
    fi
    printf '%s\\n' "$path"
}
shift; checksum_sync "$@"'''
        command = ['bash', '-c', code, '_', module, occupy, *args]
    else: command = ['bash', module, *args]
    proc = subprocess.run(command, env=env, capture_output=True, timeout=20)
    (case / 'stdout').write_bytes(proc.stdout); (case / 'stderr').write_bytes(proc.stderr)
    workspace = next((case / 'tmp').glob('dsr-checksum-sync.*'), None)
    result = json.loads(proc.stdout) if json_mode and proc.stdout else None
    return proc, result, workspace

proc, result, workspace = sync()
check('public sync retains exactly its stdout result', proc.returncode == 0 and result.get('kind') == 'dsr-checksum-sync-result' and
      result.get('result_file') == str(workspace / 'result.json') and (workspace / 'result.json').read_bytes() == proc.stdout)
check('each finished target has an independent complete receipt', all(json.loads((workspace / ('target-%d.result.json' % (i+1))).read_text()) == r
      for i,r in enumerate(result['results'])))
check('stderr advertises the exact independently usable result digest', hashlib.sha256(proc.stdout).hexdigest().encode() in proc.stderr)
proc, result, workspace = sync(json_mode=False)
check('non-JSON sync still retains machine-readable recovery evidence', proc.returncode == 0 and not proc.stdout and
      json.loads((workspace / 'result.json').read_text())['status'] == 'success')
proc, result, workspace = sync(bad_manifest=True)
check('handled failures also retain their authoritative exit status', proc.returncode == 4 and result['exit_code'] == 4 and
      (workspace / 'result.json').read_bytes() == proc.stdout)
proc, result, workspace = sync(occupy='result.json')
check('failed final persistence cannot emit a green result', proc.returncode != 0 and result.get('exit_code') == proc.returncode and
      result.get('status') == 'error' and result.get('result_file') is None and
      (workspace / 'result.json').read_text() == 'preexisting evidence\n')
proc, result, workspace = sync(occupy='target-1.result.json')
check('failed target persistence stops later destinations and retains a failure result', proc.returncode != 0 and
      len(result.get('results', [])) == 1 and not (workspace / 'target-2.result.json').exists() and
      (workspace / 'target-1.result.json').read_text() == 'preexisting evidence\n' and
      (workspace / 'result.json').read_bytes() == proc.stdout)
proc = subprocess.run(['bash', module, 'recover', '--help'], capture_output=True, timeout=10)
check('public recover entry point reaches the real reconciliation engine', proc.returncode == 0 and
      b'--result-sha256' in proc.stdout and b'--push' in proc.stdout)
print('Result persistence: %d passed, %d failed' % (checks - failures, failures), flush=True)
raise SystemExit(1 if failures else 0)
PY
