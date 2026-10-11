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
import json, os, sys
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

print('Results: %d passed, 0 failed\nEvidence: %s' % (passed, work), flush=True)
PY
