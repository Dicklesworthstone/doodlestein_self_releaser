#!/usr/bin/env bash
# Exercise the real audit CLI and shared aggregate parser. Only curl/gh network
# boundaries are fixtures; payloads, files, hashes and JSON admission are real.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 jq bash; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
python3 - "$ROOT" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix='dsr-checksum-audit-tests-'))
print('Retained evidence: ' + str(work), flush=True)
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
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True) + '\n')

def fixture(directory, count=5, metadata=True):
    (directory / 'bodies').mkdir(parents=True)
    context = dict(id=321, tag_name='v1.2.3', draft=False, prerelease=False, target_commitish='main')
    rows = []
    def asset(name, data):
        identity = len(rows) + 1
        (directory / 'bodies' / str(identity)).write_bytes(data)
        rows.append(dict(id=identity, name=name, size=len(data), state='uploaded', digest='sha256:' + sha(data),
                         browser_download_url='https://untrusted.example/never-follow-this'))
    for i in range(count):
        asset('app-%03d.tar.gz' % i, ('Owned payload %03d\n' % i).encode())
    checksums = ''.join(sha((directory / 'bodies' / str(a['id'])).read_bytes()) + '  ' + a['name'] + '\n' for a in rows)
    asset('SHA256SUMS', checksums.encode())
    if metadata:
        for name in ('app-000.tar.gz.sha256', 'app-000.tar.gz.minisig', 'release.intoto.jsonl', 'app.spdx.json', 'app-v1.2.3-manifest.json'):
            asset(name, b'Excluded evidence fixture\n')
    value = dict(context=context, assets=rows, mode='ok')
    save(directory / 'fixture.json', value)
    return value

bin_dir = work / 'bin'
bin_dir.mkdir()
(bin_dir / 'curl').write_text('#!' + sys.executable + ' -S\n' + r'''
import json, os, sys, time
from pathlib import Path
from urllib.parse import urlparse, parse_qs
args = sys.argv[1:]
config = sys.stdin.read()
base = Path(os.environ['DSR_AUDIT_FIXTURE'])
spec = json.loads((base / 'fixture.json').read_text())
if args == ['--disable', '--version']:
    print('curl ' + spec.get('curl_version', '8.4.0') + ' fixture')
    sys.exit(0)
def value(flag): return args[args.index(flag) + 1]
assert args[0] == '--disable'
for flag in ('--fail', '--location', '--silent', '--show-error'): assert flag in args
assert value('--proto') == '=https' and value('--proto-redir') == '=https'
assert value('--connect-timeout') == '10' and 1 <= int(value('--max-time')) <= 3600
assert value('--max-redirs') == '5' and int(value('--max-filesize')) > 0
assert value('--request') == 'GET' and value('--config') == '-'
assert '--location-trusted' not in args and '--insecure' not in args
assert all('owned_test_token' not in arg for arg in args)
assert not any(arg.startswith('https://untrusted.') for arg in args)
url = urlparse(args[-1])
assert url.scheme == 'https' and url.netloc == 'api.github.com'
assert url.path.startswith('/repos/owner/app/releases/')
assert 'X-GitHub-Api-Version: 2022-11-28' in config
assert 'Cache-Control: no-cache' in config
if spec.get('private'): assert 'Authorization: Bearer owned_test_token' in config
trace = base / 'trace.jsonl'
with trace.open('a') as out: out.write(json.dumps({'url':args[-1], 'argv':args, 'binary':'application/octet-stream' in config})+'\n')
mode = spec['mode']
if mode in ('timeout', 'cancel'):
    (base / 'blocked-pid').write_text(str(os.getpid()))
    time.sleep(30)
if '/assets/' in url.path:
    assert 'application/octet-stream' in config
    identity = int(url.path.rsplit('/', 1)[1])
    if mode == 'asset-failure' and identity == 5: sys.exit(22)
    if mode == 'aggregate-failure' and identity == spec['aggregate_id']: sys.exit(22)
    data = (base / 'bodies' / str(identity)).read_bytes()
    if mode == 'payload-mismatch' and identity == 5: data = b'!' * len(data)
    if mode == 'short-download' and identity == 1: data = data[:-1]
    if mode == 'long-download' and identity == 1: data += b'X'
    if mode == 'symlink-download' and identity == 1:
        Path(value('--output')).symlink_to(base / 'bodies' / str(identity)); sys.exit(0)
    if mode == 'local-drift' and identity == 5:
        (Path(value('--output')).parent / 'app-000.tar.gz').write_bytes(b'late mutation')
else:
    assert 'application/vnd.github+json' in config
    if '/tags/' in url.path:
        context = dict(spec['context'])
        if mode == 'release-drift' and len([row for row in trace.read_text().splitlines() if '/tags/' in row]) > 1:
            context['id'] += 1
        data = json.dumps(context).encode()
    else:
        page = int(parse_qs(url.query)['page'][0])
        assert parse_qs(url.query)['per_page'] == ['100']
        if mode == 'page-two-failure' and page == 2: sys.exit(22)
        assets = spec['assets']
        already = len([row for row in trace.read_text().splitlines() if '/assets?' in row])
        if mode == 'inventory-drift' and already > 1:
            assets = json.loads(json.dumps(assets)); assets[0]['id'] += 9000
        if mode == 'malformed-page': data = b'{"message":"error"}'
        elif mode == 'duplicate-json': data = b'[{"id":1,"id":2}]'
        elif mode == 'html-page': data = b'<html>rate limited</html>'
        else: data = json.dumps(assets[(page - 1)*100:page*100]).encode()
Path(value('--output')).write_bytes(data)
''')
(bin_dir / 'curl').chmod(0o755)
(bin_dir / 'gh').write_text('#!/bin/sh\n[ "$*" = "auth token --hostname github.com" ] || exit 99\nprintf "owned_test_token\\n"\n')
(bin_dir / 'gh').chmod(0o755)

sequence = 0
def run(label, data, expected, extra=(), env_changes=None, output=None):
    global sequence
    sequence += 1
    directory = work / ('case-%03d' % sequence)
    spec = fixture(directory, data.pop('_count', 5), data.pop('_metadata', True))
    spec.update(data)
    spec['aggregate_id'] = next((a['id'] for a in spec['assets'] if a['name'] == 'SHA256SUMS'), None)
    save(directory / 'fixture.json', spec)
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], DSR_AUDIT_FIXTURE=str(directory),
               GH_TOKEN='owned_test_token', GITHUB_TOKEN='', GH_HOST='untrusted.example')
    env.update(env_changes or {})
    result_dir = output or directory / 'audit'
    previous_receipt = (result_dir / 'result.json').read_bytes() if (result_dir / 'result.json').is_file() else None
    command = ['bash', str(root / 'src/release_checksums.sh'), '--repo', 'owner/app', '--tag', 'v1.2.3', '--output-dir', str(result_dir)]
    proc = subprocess.run(command + list(extra), capture_output=True, env=env, timeout=180)
    (directory / 'stdout').write_bytes(proc.stdout); (directory / 'stderr').write_bytes(proc.stderr)
    check(label + ': exit', proc.returncode == expected)
    result = json.loads(proc.stdout)
    check(label + ': truthful envelope', result['exit_code'] == expected and result['authenticated'] is False and result['source_verified'] is False)
    if expected == 0:
        check(label + ': complete positive coverage', result['status'] == 'verified' and result['eligible_count'] > 0 and
              result['verified_count'] == result['eligible_count'] == len(result['verified_checksums']) and not result['coverage_errors'] and
              not result['checksum_errors'] and result['inventory_stable'] is True)
        check(label + ': exported manifest is byte-pinned', sha(Path(result['normalized_manifest']).read_bytes()) == result['normalized_manifest_sha256'])
    else:
        check(label + ': failure cannot expose a verified manifest', result['status'] == 'error' and 'normalized_manifest' not in result)
    if previous_receipt is not None:
        check(label + ': existing receipt is preserved', (result_dir / 'result.json').read_bytes() == previous_receipt)
    elif result_dir.is_dir() and (result_dir / 'result.json').exists():
        check(label + ': retained receipt matches stdout', json.loads((result_dir / 'result.json').read_bytes()) == result)
    return directory, spec, result, env

# Five payloads deliberately exceed the legacy verifier's three-file sample.
directory, spec, result, env = run('all five payloads', {}, 0)
check('five payloads checked, aggregate and five metadata exclusions explained', result['eligible_count'] == 5 and len(result['excluded_assets']) == 6)
check('every network request passed protocol/redirect/time/auth assertions', len((directory / 'trace.jsonl').read_text().splitlines()) == 10)
check('secrets are absent from stdout and retained evidence', all(b'owned_test_token' not in p.read_bytes() for p in (directory / 'audit').rglob('*') if p.is_file()))
run('private asset API uses configured credentials', {'private':True}, 0)
run('GitHub CLI authentication fallback', {'private':True}, 0, env_changes={'GH_TOKEN':'','GITHUB_TOKEN':''})
run('GITHUB_TOKEN fallback', {'private':True}, 0, env_changes={'GH_TOKEN':'','GITHUB_TOKEN':'owned_test_token'})
run('page beyond first hundred', {'_count':101, '_metadata':False}, 0)
run('refuse pre-stream-limit curl', {'curl_version':'8.3.0'}, 3)
run('later-page failure', {'_count':101, 'mode':'page-two-failure'}, 8)
for mode, code in (('asset-failure',8), ('aggregate-failure',8), ('payload-mismatch',1), ('short-download',1),
                   ('long-download',8), ('symlink-download',4), ('inventory-drift',1), ('local-drift',1),
                   ('release-drift',1), ('malformed-page',4), ('duplicate-json',4), ('html-page',4)):
    run(mode, {'mode':mode}, code)
run('bounded timeout', {'mode':'timeout'}, 8, extra=('--timeout','1'))
run('per-asset byte cap', {}, 4, extra=('--max-asset-bytes','2'))
run('total byte cap', {}, 4, extra=('--max-total-bytes','2'))
run('no eligible payloads', {'_count':0}, 1)
run('explicit sidecar cannot masquerade as aggregate', {}, 4, extra=('--checksum-asset','app-000.tar.gz.sha256'))
run('metadata mode requires metadata coverage', {}, 1, extra=('--include-metadata',))
run('reject unknown tag policy', {}, 4, extra=('--tag','latest'))
run('refuse an existing evidence directory', {}, 4, output=directory / 'audit')
run('invalid authentication header encoding', {}, 3, env_changes={'GH_TOKEN':'bad\nheader'})

# Mutate only owned fake server inputs, rebind API size/digest, and then run
# the unchanged real CLI. Thus parser negatives cannot hide behind API hashes.
def special(label, mutate, expected=4, extra=()):
    global sequence
    sequence += 1
    directory = work / ('special-%03d' % sequence)
    spec = fixture(directory)
    mutate(directory, spec)
    save(directory / 'fixture.json', spec)
    env = dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ['PATH'], DSR_AUDIT_FIXTURE=str(directory), GH_TOKEN='owned_test_token')
    proc = subprocess.run(['bash', str(root / 'src/release_checksums.sh'), '--repo','owner/app','--tag','v1.2.3',
                           '--output-dir',str(directory / 'audit'), *extra], env=env, capture_output=True, timeout=180)
    (directory / 'stdout').write_bytes(proc.stdout); (directory / 'stderr').write_bytes(proc.stderr)
    check(label + ': exit', proc.returncode == expected)
    result = json.loads(proc.stdout)
    check(label + ': truthful status', result['exit_code'] == expected and result['status'] == ('verified' if expected == 0 else 'error'))
    return directory, result

def body(directory, spec, data):
    row = next(a for a in spec['assets'] if a['name']=='SHA256SUMS')
    (directory / 'bodies' / str(row['id'])).write_bytes(data)
    row.update(size=len(data), digest='sha256:'+sha(data))

for label, data in [('empty aggregate',b''), ('HTML aggregate',b'<html>error</html>'), ('bad digest',b'not-a-hash  app-000.tar.gz\n'),
                    ('NUL aggregate',b'1'*64+b'  app-000.tar.gz\x00\n'), ('traversal aggregate',b'1'*64+b'  ../escape\n'),
                    ('duplicate filename', (b'1'*64+b'  app-000.tar.gz\n')*2)]:
    special(label, lambda d,s,data=data:body(d,s,data))
special('missing eligible checksum', lambda d,s:body(d,s,(d/'bodies'/'6').read_bytes().split(b'\n',1)[1]),1)
special('unknown checksum member', lambda d,s:body(d,s,(d/'bodies'/'6').read_bytes()+b'1'*64+b'  foreign\n'),1)
special('duplicate asset identity', lambda d,s:s['assets'].append(s['assets'][0]))
special('case-colliding names', lambda d,s:s['assets'][1].update(name='APP-000.TAR.GZ'))
special('invalid asset state', lambda d,s:s['assets'][0].update(state='new'))
special('invalid asset path', lambda d,s:s['assets'][0].update(name='../escape'))
special('mistyped size', lambda d,s:s['assets'][0].update(size=True))
special('release tag mismatch', lambda d,s:s['context'].update(tag_name='v9.9.9'))
special('no conventional aggregate', lambda d,s:s['assets'].__setitem__(slice(None),[a for a in s['assets'] if a['name']!='SHA256SUMS']),1)
special('API digest disagreement', lambda d,s:s['assets'][0].update(digest='sha256:'+'0'*64),1)
special('API digest absent still hashes every payload', lambda d,s:[a.pop('digest') for a in s['assets']],0)

def corrupt_last_payload(d,s):
    row = s['assets'][4]
    data = b'!' * row['size']
    (d/'bodies'/str(row['id'])).write_bytes(data)
    row['digest'] = 'sha256:' + sha(data)
d,result=special('fifth payload fails aggregate comparison despite matching API digest',corrupt_last_payload,1)
check('three-file spot checking cannot satisfy the actual full audit', result['verified_count']==4 and
      result['checksum_errors'][0]['name']=='app-004.tar.gz' and 'normalized_manifest' not in result)

def conventional_rows(d,s):
    data=(d/'bodies'/'6').read_text().splitlines()
    body(d,s,('# portable checksum example\r\n\r\n' + '\r\n'.join(
        line[:64].upper()+' *./'+line[66:] for line in reversed(data))).encode())
special('CRLF comments uppercase binary-mode and ./ aliases normalize together',conventional_rows,0)

def spaced_member(d,s):
    s['assets'][0]['name']='payload with spaces + plus.tar.gz'
    body(d,s,(d/'bodies'/'6').read_bytes().replace(b'app-000.tar.gz',s['assets'][0]['name'].encode()))
d,result=special('literal spaced asset name preserves filename boundaries',spaced_member,0)
check('spaced filename is retained as one checksum member', 'payload with spaces + plus.tar.gz' in result['verified_checksums'])

def add_aggregate(d,s,conflict=False):
    data=(d/'bodies'/'6').read_bytes()
    if conflict:data=b'0'*64+data[64:]
    identity=len(s['assets'])+1
    (d/'bodies'/str(identity)).write_bytes(data)
    s['assets'].append(dict(id=identity,name='checksums.txt',size=len(data),state='uploaded',digest='sha256:'+sha(data)))
special('identical conventional aggregate aliases', lambda d,s:add_aggregate(d,s),0)
special('conflicting conventional aggregates', lambda d,s:add_aggregate(d,s,True),1)
special('explicit aggregate chooses a declared authority', lambda d,s:add_aggregate(d,s,True),0,extra=('--checksum-asset','SHA256SUMS'))

def extra_metadata(d,s):
    rows=[a for a in s['assets'] if a['name'].endswith(('.intoto.jsonl','.spdx.json','-manifest.json'))]
    data=(d/'bodies'/'6').read_bytes()+b''.join((sha((d/'bodies'/str(a['id'])).read_bytes())+'  '+a['name']+'\n').encode() for a in rows)
    body(d,s,data)
d,result=special('metadata explicitly included and verified',extra_metadata,0,extra=('--include-metadata',))
check('metadata mode increases actual verified coverage', result['verified_count']==8)
d,result=special('excluded metadata never propagated as audited checksums',extra_metadata,0)
check('export contains only actual verified files',len(Path(result['normalized_manifest']).read_text().splitlines())==5)
check('parser and downloads did not remove original server inputs', all((d/'bodies'/str(i)).exists() for i in range(1,12)))

# Cancel the real CLI PID, not an assumed child or a PID recovered from state.
# It must own and stop the active transport before emitting an error receipt.
directory=work/'cancel'
spec=fixture(directory); spec['mode']='cancel'; save(directory/'fixture.json',spec)
env=dict(os.environ,PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],DSR_AUDIT_FIXTURE=str(directory),GH_TOKEN='owned_test_token')
command=['bash',str(root/'src/release_checksums.sh'),'--repo','owner/app','--tag','v1.2.3','--output-dir',str(directory/'audit')]
proc=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
try:
    deadline=time.monotonic()+15
    while not (directory/'blocked-pid').exists() and time.monotonic()<deadline and proc.poll() is None:
        time.sleep(.05)
    check('cancellation reaches a genuinely active transport', (directory/'blocked-pid').exists())
    proc.send_signal(signal.SIGTERM)
    stdout,stderr=proc.communicate(timeout=15)
    (directory/'stdout').write_bytes(stdout); (directory/'stderr').write_bytes(stderr)
    result=json.loads(stdout)
    check('CLI cancellation returns a persisted error envelope', proc.returncode==5 and result['exit_code']==5 and result['status']=='error' and
          json.loads((directory/'audit/result.json').read_bytes())==result)
    transport=int((directory/'blocked-pid').read_text())
    try:
        os.kill(transport,0)
        stopped=False
    except ProcessLookupError:
        stopped=True
    check('cancellation reaps the owned download process',stopped)
    check('interrupted acquisition cannot export verified checksums',not (directory/'audit/checksums.normalized').exists())
finally:
    if proc.poll() is None:
        proc.terminate(); proc.communicate(timeout=15)
print('Results: %d passed, 0 failed\nEvidence: %s' % (passed,work),flush=True)
PY
