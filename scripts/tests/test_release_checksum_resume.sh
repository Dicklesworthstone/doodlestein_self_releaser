#!/usr/bin/env bash
# Production audit/parser with an explicit HTTP acquisition fixture; no network.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
python3 - "$ROOT" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import time
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix='dsr-resume-regression-'))
print('Evidence: ' + str(work), flush=True)
passed = 0

def check(label, condition):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print('PASS: ' + label, flush=True)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True) + '\n')

bin_dir = work / 'bin'
bin_dir.mkdir()
(bin_dir / 'curl').write_text('#!' + sys.executable + ' -S\n' + r'''
import json, os, sys, time
from pathlib import Path
from urllib.parse import urlparse, parse_qs
args = sys.argv[1:]
if args == ['--disable', '--version']:
    print('curl 8.4.0 explicit test transport'); sys.exit(0)
base = Path(os.environ['RESUME_FIXTURE'])
spec = json.loads((base / 'spec.json').read_text())
config = sys.stdin.read()
assert 'Authorization: Bearer test_only_token' in config
assert '--fail' in args and '--location-trusted' not in args
for key in ('--proto', '--proto-redir'):
    assert args[args.index(key)+1] == '=https'
assert all('test_only_token' not in a for a in args)
url = urlparse(args[-1])
assert url.scheme == 'https' and url.netloc == 'api.github.com'
assert url.path.startswith('/repos/owner/app/releases/')
with (base / 'calls.jsonl').open('a') as f:
    f.write(json.dumps(url.path + '?' + url.query) + '\n')
if '/assets/' in url.path:
    identity = int(url.path.rsplit('/', 1)[1])
    if identity == spec.get('pause_id'):
        (base / 'paused.pid').write_text(str(os.getpid()))
        time.sleep(30)
    if identity == spec.get('fail_id'): sys.exit(22)
    data = (base / 'bodies' / str(identity)).read_bytes()
elif '/tags/' in url.path:
    data = json.dumps(spec['release']).encode()
else:
    page = int(parse_qs(url.query)['page'][0])
    data = json.dumps(spec['assets'][(page-1)*100:page*100]).encode()
assert len(data) <= int(args[args.index('--max-filesize')+1])
Path(args[args.index('--output')+1]).write_bytes(data)
''')
(bin_dir / 'curl').chmod(0o755)
env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'], DSR_GH_TOKEN='test_only_token')

def fixture(label, count=6, sidecars=False):
    base = work / label
    (base / 'bodies').mkdir(parents=True)
    rows = []
    def asset(name, data):
        identity = len(rows) + 1
        (base / 'bodies' / str(identity)).write_bytes(data)
        rows.append(dict(id=identity, name=name, size=len(data), state='uploaded', digest='sha256:' + sha(data)))
    for i in range(count):
        asset('payload-%03d' % i, ('Owned payload %03d\n' % i).encode())
    if sidecars:
        for row in list(rows):
            asset(row['name'] + '.sha256', (row['digest'][7:] + '\n').encode())
    else:
        asset('SHA256SUMS', ''.join(r['digest'][7:] + '  ' + r['name'] + '\n' for r in rows).encode())
    spec = dict(release=dict(id=321, tag_name='v1.2.3', draft=False, prerelease=False, target_commitish='main'),
                assets=rows, fail_id=5)
    save(base / 'spec.json', spec)
    return base, spec

def audit(base, label, expected, extra=(), destination=None):
    env['RESUME_FIXTURE'] = str(base)
    output = destination or base / label
    call = ['bash', str(root / 'src/release_checksums.sh'), '--repo', 'owner/app', '--tag', 'v1.2.3',
            '--output-dir', str(output), *map(str, extra)]
    result = subprocess.run(call, env=env, capture_output=True, timeout=45)
    (base / (label + '.stdout')).write_bytes(result.stdout)
    (base / (label + '.stderr')).write_bytes(result.stderr)
    check(label + ' process status', result.returncode == expected)
    value = json.loads(result.stdout)
    check(label + ' truthful result', value['exit_code'] == expected and
          value['status'] == ('verified' if expected == 0 else 'error'))
    if expected:
        check(label + ' cannot export success', 'normalized_manifest' not in value)
    return output, value

def frozen(base):
    return {str(p.relative_to(base)): (p.stat().st_ino, sha(p.read_bytes()))
            for p in base.rglob('*') if p.is_file()}

def calls(base, start):
    return [json.loads(s) for s in (base / 'calls.jsonl').read_text().splitlines()[start:]]

for sidecars, count in ((False, 6), (True, 6), (False, 101)):
    base, spec = fixture(('sidecars' if sidecars else 'aggregate') + str(count), count, sidecars)
    policy = ['--checksum-mode', 'sidecars'] if sidecars else []
    old, partial = audit(base, 'failed', 8, policy)
    check('late failure retains four verified payloads', partial['verified_count'] == 4)
    original = frozen(old)
    spec['fail_id'] = None
    save(base / 'spec.json', spec)
    start = len((base / 'calls.jsonl').read_text().splitlines())
    output, verified = audit(base, 'resumed', 0, [*policy, '--resume-from', old])
    check('resume verifies complete selected release', verified['eligible_count'] == verified['verified_count'] == count)
    check('reuse is reported separately', verified['resume']['reused_count'] == 4)
    check('original failure evidence is untouched', frozen(old) == original)
    current_calls = calls(base, start)
    check('verified payloads are not downloaded again', not any('/assets/%d?' % n in s for n in range(1, 5) for s in current_calls))
    check('checksum evidence is acquired again', any('/assets/%d?' % (count + 1) in s for s in current_calls))
    check('new copies are not hardlinks', (old / 'artifacts/payload-000').stat().st_ino !=
          (output / 'artifacts/payload-000').stat().st_ino)
    audit(base, 'occupied', 4, [*policy, '--resume-from', old], destination=output)
    check('failed option validation preserves both attempts', frozen(old) == original)
    spec['assets'][0]['id'] = 900
    save(base / 'spec.json', spec)
    audit(base, 'replaced-asset', 1, [*policy, '--resume-from', old])
    spec['assets'][0]['id'] = 1
    save(base / 'spec.json', spec)
    copied = base / 'corrupt-retained'
    shutil.copytree(old, copied)
    (copied / 'artifacts/payload-000').write_bytes(b'corrupt retained payload')
    audit(base, 'corrupt-refused', 1, [*policy, '--resume-from', copied])
    check('corruption is not silently repaired', (copied / 'artifacts/payload-000').read_bytes() == b'corrupt retained payload')
    audit(base, 'policy-change', 4, [*policy, '--resume-from', old, '--include-metadata'])
    check('all refusals preserve original attempt', frozen(old) == original)


# Exercise production command registration and both recovery handoffs. Only
# the original root metadata/repair command is a fixture, not the adapter or
# auditor. The real audit must still rehash all reused bytes.
base, spec = fixture('handoff')
old, _ = audit(base, 'failed', 8)
original = frozen(old)
spec['fail_id'] = None
save(base / 'spec.json', spec)
runtime = base / 'runtime'
(runtime / 'src').mkdir(parents=True)
for name in ('release_formulas.sh', 'release_verify.sh', 'release_checksums.sh', 'checksum_sync.sh'):
    shutil.copy2(root / 'src' / name, runtime / 'src' / name)
(runtime / 'dsr').write_text(r"""#!/usr/bin/env bash
# Explicit metadata CLI boundary fixture; no publisher or compiler runs.
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
DSR_VERSION=fixture
JSON_MODE=false
DRY_RUN=false
while (($#)); do
    case "$1" in
        --json) JSON_MODE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) break ;;
    esac
done
log_error() { printf '%s\n' "$*" >&2; }
cmd_release_verify() {
    python3 -S - "$@" <<'METADATA'
import json, os, sys
from pathlib import Path
base=Path(os.environ['RESUME_FIXTURE'])
spec=json.loads((base/'spec.json').read_text())
with (base/'metadata.jsonl').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\n')
rc=7 if spec.get('strict_error') else 0
print(json.dumps(dict(command='release-verify',status='incomplete' if rc else 'success',exit_code=rc,
    details=dict(repo='owner/app',tag='v1.2.3',release_id=321,
                 assets=dict(present=[r['name'] for r in spec['assets']],extra=[]),
                 verification=dict(strict_sentinel='retained'),repair=None))))
sys.exit(rc)
METADATA
}
source "$SCRIPT_DIR/src/release_formulas.sh"
[[ "${1:-} ${2:-}" == 'release verify' ]] || exit 4
shift 2
cmd_release_verify "$@"
""")

def invoke(label, command, expected=0):
    result = subprocess.run(list(map(str, command)), env=env, capture_output=True, timeout=60)
    (base / (label + '.stdout')).write_bytes(result.stdout)
    (base / (label + '.stderr')).write_bytes(result.stderr)
    check(label + ' status', result.returncode == expected)
    value = json.loads(result.stdout)
    check(label + ' JSON status', value['exit_code'] == expected)
    return value

cli = ['bash', runtime / 'dsr', '--json', 'release', 'verify', 'app', '1.2.3', '--checksums',
       '--checksum-resume-from', old]
value = invoke('cli-resume', [*cli, '--checksum-output-dir', base / 'cli-audit'])
check('CLI retains verified and reused coverage', value['details']['checksums']['verified_count'] == 6 and
      value['details']['checksums']['resume']['reused_count'] == 4)
check('CLI preserves original metadata gates', value['details']['verification']['strict_sentinel'] == 'retained')
check('CLI rechecks metadata without forwarding checksum or repair flags',
      [json.loads(line) for line in (base / 'metadata.jsonl').read_text().splitlines()] == [['app','1.2.3']]*2)
metadata_before = (base / 'metadata.jsonl').read_bytes()
invoke('repair-resume-refused', [*cli, '--fix'], 4)
check('repair plus resume is refused before metadata or mutation', (base / 'metadata.jsonl').read_bytes() == metadata_before)
spec['strict_error'] = True
save(base / 'spec.json', spec)
value = invoke('strict-failure', [*cli, '--checksum-output-dir', base / 'strict-audit'], 7)
check('complete resumed checksums cannot override strict failure', value['details']['checksums']['verified_count'] == 6)
spec.pop('strict_error')
save(base / 'spec.json', spec)
sync = ['bash', root / 'src/checksum_sync.sh', 'sync', 'app', '1.2.3', '--repo', 'owner/app',
        '--target-repo', 'owner/installers', '--dry-run', '--json']
value = invoke('sync-resume', [*sync, '--verify-release', '--audit-resume-from', old])
check('downstream preview uses the complete resumed audit', value['planned'] == 1 and value['synced'] == 0 and
      value['release_verification']['verified_count'] == 6 and value['release_verification']['resume']['reused_count'] == 4)
check('downstream preview clones nothing', not list(Path(value['workspace']).glob('target-*')))
invoke('unaudited-sync-refused', [*sync, '--audit-resume-from', old], 4)
check('both handoffs leave earlier evidence unchanged', frozen(old) == original)


# Kill the real audit supervisor while its fifth owned download is pending.
# Unlike graceful TERM, SIGKILL cannot write result.json. The test reaps the
# supervisor and explicitly kills only the PID/group recorded by its own fake
# transport; it does not manufacture a terminal success or edit the attempt.
base, spec = fixture('crash-handoff')
env['RESUME_FIXTURE'] = str(base)
spec['fail_id'] = None
spec['pause_id'] = 5
save(base / 'spec.json', spec)
crashed = base / 'crashed'
command = ['bash', str(root / 'src/release_checksums.sh'), '--repo', 'owner/app', '--tag', 'v1.2.3',
           '--output-dir', str(crashed)]
with (base / 'killed.stdout').open('wb') as out, (base / 'killed.stderr').open('wb') as err:
    worker = subprocess.Popen(command, env=env, stdout=out, stderr=err, start_new_session=True)
    try:
        deadline = time.monotonic() + 20
        while not (base / 'paused.pid').exists() and worker.poll() is None and time.monotonic() < deadline:
            time.sleep(.025)
        check('fifth download begins under real audit supervisor', (base / 'paused.pid').exists() and worker.poll() is None)
        os.kill(worker.pid, signal.SIGKILL)
        check('forced termination has no handled completion status', worker.wait(timeout=5) == -signal.SIGKILL)
    finally:
        if worker.poll() is None:
            os.killpg(worker.pid, signal.SIGKILL)
            worker.wait()
        if (base / 'paused.pid').exists():
            download_pid = int((base / 'paused.pid').read_text())
            try:
                os.killpg(download_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
check('crash leaves no terminal audit or normalized success export',
      not (crashed / 'result.json').exists() and not (crashed / 'checksums.normalized').exists())
rows = [json.loads(line) for line in (crashed / 'verified.jsonl').read_bytes().splitlines()]
check('each completed payload has one append-only checkpoint', len(rows) == 5 and
      [r['name'] for r in rows[1:]] == ['payload-%03d' % i for i in range(4)])
check('checkpoint header is bound to the exact retained inventory',
      rows[0]['selection_sha256'] == sha((crashed / 'selection.json').read_bytes()))
original = frozen(crashed)
spec.pop('pause_id')
save(base / 'spec.json', spec)
start = len((base / 'calls.jsonl').read_text().splitlines())
_, value = audit(base, 'after-crash', 0, ['--resume-from', crashed])
check('crash recovery verifies all six and reuses four', value['verified_count'] == 6 and value['resume']['reused_count'] == 4)
check('journal recovery makes no invented terminal-outcome claim', value['resume']['source_kind'] == 'progress-journal' and
      value['resume']['source_terminal_outcome'] == 'unknown' and value['resume']['source_result_sha256'] is None)
check('journal and selection hashes identify original process evidence',
      value['resume']['source_progress_sha256'] == sha((crashed / 'verified.jsonl').read_bytes()) and
      value['resume']['source_selection_sha256'] == sha((crashed / 'selection.json').read_bytes()))
check('crash recovery reacquires checksum evidence, not completed payloads',
      any('/assets/7?' in c for c in calls(base, start)) and
      not any('/assets/%d?' % n in c for n in range(1,5) for c in calls(base,start)))
check('crash recovery preserves the original interrupted attempt', frozen(crashed) == original)

# The committed CLI/sync integration needs no special-case trust shortcut.
cli_crash = ['bash', runtime / 'dsr', '--json', 'release', 'verify', 'app', '1.2.3', '--checksums',
             '--checksum-resume-from', crashed, '--checksum-output-dir', base / 'crash-cli']
value = invoke('crash-cli', cli_crash)
check('CLI reports checkpoint recovery without masking unknown earlier outcome',
      value['details']['checksums']['verified_count'] == 6 and
      value['details']['checksums']['resume']['source_terminal_outcome'] == 'unknown')
value = invoke('crash-sync', [*sync, '--verify-release', '--audit-resume-from', crashed])
check('downstream dry-run admits a fully rechecked checkpoint recovery', value['planned'] == 1 and value['synced'] == 0 and
      value['release_verification']['resume']['reused_count'] == 4)
check('all wrapper recovery work stays outside the prior attempt', frozen(crashed) == original)

# A missing newline is an uncommitted tail, even if its JSON happens to parse.
# Earlier complete lines are still usable and no prior file is rewritten.
for label, tail in (('partial-json', b'{"name":'), ('complete-without-newline', json.dumps(rows[-1]).encode())):
    prior = base / label
    shutil.copytree(crashed, prior)
    with (prior / 'verified.jsonl').open('ab') as out:
        out.write(tail)
    prior_state = frozen(prior)
    _, value = audit(base, label + '-recovered', 0, ['--resume-from', prior])
    check(label + ' ignores only the uncommitted tail', value['resume']['reused_count'] == 4 and
          value['resume']['discarded_tail_bytes'] == len(tail))
    check(label + ' leaves journal and payloads untouched', frozen(prior) == prior_state)

# Complete malformed records are never silently dropped, and a present bad
# terminal receipt is never bypassed by a usable progress journal.
for label in ('nonobject-header', 'wrong-selection', 'boolean-schema', 'duplicate', 'out-of-order',
              'wrong-id', 'wrong-size', 'wrong-digest', 'unknown-name', 'excluded', 'complete-garbage',
              'duplicate-json-key', 'oversized-tail', 'invalid-terminal', 'linked-journal', 'corrupt-payload'):
    prior = base / ('bad-' + label)
    shutil.copytree(crashed, prior)
    records = copy.deepcopy(rows)
    journal = prior / 'verified.jsonl'
    if label == 'nonobject-header': records[0] = []
    elif label == 'wrong-selection': records[0]['selection_sha256'] = 'a' * 64
    elif label == 'boolean-schema': records[0]['schema_version'] = True
    elif label == 'duplicate': records.append(records[-1])
    elif label == 'out-of-order': records[1], records[2] = records[2], records[1]
    elif label == 'wrong-id': records[1]['id'] = 999
    elif label == 'wrong-size': records[1]['size'] += 1
    elif label == 'wrong-digest': records[1]['sha256'] = 'a' * 64
    elif label == 'unknown-name': records[1]['name'] = 'unselected'
    elif label == 'excluded':
        checksum = spec['assets'][-1]
        records[1] = dict(name='SHA256SUMS', id=checksum['id'], size=checksum['size'], sha256=checksum['digest'][7:])
    journal.write_bytes(b''.join(json.dumps(r).encode() + b'\n' for r in records))
    if label == 'complete-garbage':
        with journal.open('ab') as out: out.write(b'{\n')
    elif label == 'duplicate-json-key':
        with journal.open('ab') as out: out.write(b'{"name":"a","name":"b"}\n')
    elif label == 'oversized-tail':
        with journal.open('ab') as out: out.write(b'x' * 4097)
    elif label == 'invalid-terminal': save(prior / 'result.json', {})
    elif label == 'linked-journal':
        journal.rename(prior / 'original-journal')
        journal.symlink_to('original-journal')
    elif label == 'corrupt-payload': (prior / 'artifacts/payload-000').write_bytes(b'corrupted cache')
    state = frozen(prior)
    _, refusal = audit(base, label + '-refused', 1 if label == 'corrupt-payload' else 4, ['--resume-from', prior])
    check(label + ' preserves rejected evidence', frozen(prior) == state)
    check(label + ' cannot export a verified audit', not (base / (label + '-refused') / 'checksums.normalized').exists())

# Even with absent API digests, fresh checksum evidence and every reused file
# must agree. A mere journal success marker cannot authorize different bytes.
base, spec = fixture('no-api-digest')
env['RESUME_FIXTURE'] = str(base)
for asset in spec['assets']: asset['digest'] = None
spec['fail_id'] = None
save(base / 'spec.json', spec)
# Preserve the producer's release bytes; construct an interrupted checkpoint
# from the earlier owned attempt with an independently bound no-digest inventory.
prior = base / 'retained'
shutil.copytree(crashed, prior)
selection = json.loads((prior / 'selection.json').read_text())
selection['assets'] = sorted([{k: r[k] for k in ('id','name','size','digest')} for r in spec['assets']], key=lambda r:r['name'])
save(prior / 'selection.json', selection)
records = copy.deepcopy(rows)
records[0]['selection_sha256'] = sha((prior / 'selection.json').read_bytes())
(prior / 'verified.jsonl').write_bytes(b''.join(json.dumps(r).encode() + b'\n' for r in records))
_, value = audit(base, 'no-digest-recovery', 0, ['--resume-from', prior])
check('checksum evidence alone still verifies all reused bytes', value['verified_count'] == 6 and value['resume']['reused_count'] == 4)
bad = base / 'corrupt'
shutil.copytree(prior, bad)
(bad / 'artifacts/payload-000').write_bytes(b'not the checksum-bound payload')
audit(base, 'no-digest-corrupt', 1, ['--resume-from', bad])

print('Results: %d passed, 0 failed\nEvidence: %s' % (passed, work), flush=True)
PY
