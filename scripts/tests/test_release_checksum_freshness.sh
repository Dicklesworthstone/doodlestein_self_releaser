#!/usr/bin/env bash
# Production checksum auditor; real files, hashes, pagination and subprocesses.
# Default: only curl's HTTP/auth boundary is a file-backed fixture. --cli adds
# the production CLI supervisor and evidence gates with an explicit legacy
# manifest/repair command fixture. No full dsr/native/live GitHub claim.
# Retain all evidence. DSR_TEST_VERIFY_MODULE selects an incumbent supervisor.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
exec python3 - "$ROOT" "$@" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
module = Path(os.environ.get('DSR_TEST_CHECKSUM_MODULE', str(root / 'src/release_checksums.sh')))
work = Path(tempfile.mkdtemp(prefix='dsr-checksum-freshness-')).resolve()
print('Checksum freshness fixtures retained: ' + str(work), flush=True)
(work / 'bin').mkdir()
passed = failed = 0
counter = 0

def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print('ok - ' + label, flush=True)
    else:
        failed += 1
        print('not ok - ' + label, flush=True)

def hash_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True) + '\n')

curl = work / 'bin/curl'
curl.write_text(r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
from urllib.parse import urlsplit, parse_qs
args = sys.argv[1:]
if args == ['--disable', '--version']:
    print('curl 8.10.1 (explicit test transport fixture)')
    raise SystemExit(0)
case = pathlib.Path(os.environ['FRESH_CASE'])
url = urlsplit(args[-1])
assert url.scheme == 'https' and url.netloc == 'api.github.com'
assert args[args.index('--request')+1] == 'GET'
assert '--fail' in args and '--location-trusted' not in args
assert args[args.index('--proto')+1] == '=https'
assert args[args.index('--proto-redir')+1] == '=https'
assert '--max-time' in args and '--max-filesize' in args and args[0] == '--disable'
configuration = sys.stdin.read()
assert 'Cache-Control: no-cache' in configuration
assert 'Authorization: Bearer fixture-token' in configuration
assert 'fixture-token' not in ' '.join(args)
with (case / 'calls.jsonl').open('a') as stream:
    stream.write(json.dumps({'path':url.path,'query':url.query})+'\n')
mode = os.environ.get('FRESH_MODE', '')
if (case/'final-metadata').exists() and os.environ.get('CLI_MODE') in ('network-failure','hang'):
    mode = os.environ['CLI_MODE']
if mode == 'network-failure':
    raise SystemExit(22)
if mode == 'hang':
    (case / 'worker.pid').write_text(str(os.getpid()))
    time.sleep(60)
release = json.loads((case / 'release.json').read_text())
assets = json.loads((case / 'assets.json').read_text())
if '/releases/tags/' in url.path:
    calls = [json.loads(r) for r in (case/'calls.jsonl').read_text().splitlines()]
    last = sum('/releases/tags/' in r['path'] for r in calls) > 1
    if last and mode == 'late-release':
        release['draft'] = not release['draft']
    if last and mode in ('local-selection', 'local-result'):
        path = pathlib.Path(os.environ['FRESH_SOURCE']) / ('selection.json' if mode=='local-selection' else 'result.json')
        with path.open('a') as stream:
            stream.write(' ')
    if last and mode == 'result-write-failure':
        (pathlib.Path(os.environ['FRESH_OUTPUT'])/'result.json').mkdir()
    body = json.dumps(release).encode()
elif url.path.endswith('/assets'):
    page = int(parse_qs(url.query)['page'][0])
    calls = [json.loads(r) for r in (case/'calls.jsonl').read_text().splitlines()]
    rounds = sum(r['path'].endswith('/assets') and 'page=1' == r['query'].split('&')[-1] for r in calls)
    if mode == 'late-inventory' and rounds >= 2:
        assets[0]['id'] += 100000
    if mode == 'duplicate-page' and page > 1:
        body = json.dumps(assets[:1]).encode()
    elif mode == 'malformed-page':
        body = b'<html>gateway error</html>'
    else:
        body = json.dumps(assets[(page-1)*100:page*100]).encode()
else:
    assert '/releases/assets/' in url.path
    if mode == 'payload-failure':
        raise SystemExit(22)
    body = (case/'bytes'/url.path.rsplit('/',1)[1]).read_bytes()
maximum = int(args[args.index('--max-filesize')+1])
if len(body) > maximum:
    raise SystemExit(63)
pathlib.Path(args[args.index('--output')+1]).write_bytes(body)
''')
curl.chmod(0o755)

base = work / 'remote-base'
(base / 'bytes').mkdir(parents=True)
release = dict(id=42, tag_name='v1.2.3', draft=False, prerelease=False, target_commitish='main')
assets = []
for i in range(4):
    name = 'tool-%d.tar.gz' % i
    data = ('actual checksum payload %d\n' % i).encode() * 100
    proof = hashlib.sha256(data).hexdigest().encode() + b'\n'
    for asset_name, content in ((name, data), (name + '.sha256', proof)):
        identifier = len(assets) + 1
        assets.append(dict(id=identifier, name=asset_name, state='uploaded', size=len(content),
                           digest='sha256:' + hashlib.sha256(content).hexdigest()))
        (base / 'bytes' / str(identifier)).write_bytes(content)
# A second API page and excluded metadata must be bound too.
for i in range(103):
    assets.append(dict(id=1000+i, name='signature-%03d.minisig' % i, state='uploaded', size=1, digest=None))
write_json(base / 'release.json', release)
write_json(base / 'assets.json', assets)

def case(label, change=None):
    global counter
    counter += 1
    directory = work / ('%03d-' % counter + label)
    shutil.copytree(base, directory)
    (directory / 'calls.jsonl').write_text('')
    if change is not None:
        rows = copy.deepcopy(assets)
        context = copy.deepcopy(release)
        change(rows, context)
        write_json(directory / 'assets.json', rows)
        write_json(directory / 'release.json', context)
    return directory

def environment(directory, mode='', source=None, output=None):
    env = dict(os.environ, PATH=str(work/'bin')+os.pathsep+os.environ['PATH'],
               FRESH_CASE=str(directory), FRESH_MODE=mode, DSR_GH_TOKEN='fixture-token')
    if source is not None:
        env['FRESH_SOURCE'] = str(source)
    if output is not None:
        env['FRESH_OUTPUT'] = str(output)
    return env

common = ['--repo','owner/tool','--tag','v1.2.3','--release-id','42','--checksum-mode','sidecars']

def run(directory, extra=(), mode='', source=None, output=None):
    command = ['bash', str(module), *common, '--output-dir', str(output or directory/'output'), *map(str,extra)]
    proc = subprocess.run(command, capture_output=True, env=environment(directory,mode,source,output), timeout=30)
    (directory/'stdout').write_bytes(proc.stdout); (directory/'stderr').write_bytes(proc.stderr)
    try:
        result = json.loads(proc.stdout)
    except ValueError:
        result = {}
    return proc, result

def requests(directory):
    return [json.loads(row) for row in (directory/'calls.jsonl').read_text().splitlines()]

def snapshot(directory):
    return {str(p.relative_to(directory)):(p.stat().st_ino,p.stat().st_mtime_ns,hash_file(p))
            for p in directory.rglob('*') if p.is_file()}

if sys.argv[2:] == ['--cli']:
    program = work/'program'
    (program/'src').mkdir(parents=True)
    for name in ('release_checksums.sh','checksum_sync.sh'):
        shutil.copy2(root/'src'/name,program/'src'/name)
    verifier = Path(os.environ.get('DSR_TEST_VERIFY_MODULE',str(root/'src/release_verify.sh')))
    shutil.copy2(verifier,program/'src/release_verify.sh')
    # The legacy manifest checks are a separate subsystem. This boundary
    # fixture reports their existing names-only result, but deliberately
    # replaces simulated remote assets after the real checksum audit. The
    # actual supervisor/auditor/admission functions must reject that drift.
    (program/'dsr').write_text(r'''#!/usr/bin/env bash
exec python3 - "$@" <<'LEGACY'
import hashlib,json,os,pathlib,sys
case=pathlib.Path(os.environ['FRESH_CASE'])
args=sys.argv[1:]
assert '--json' in args and 'release' in args and 'verify' in args
assert not any(a.startswith('--checksum') for a in args)
fix='--fix' in args
log=case/'metadata.jsonl'
history=[json.loads(r) for r in log.read_text().splitlines()] if log.exists() else []
final=not fix and any(not r['fix'] for r in history)
with log.open('a') as stream:
    stream.write(json.dumps({'fix':fix,'final':final,'dry_run':'--dry-run' in args})+'\n')
rows=json.loads((case/'assets.json').read_text())
context=json.loads((case/'release.json').read_text())
mode=os.environ.get('CLI_MODE','')
audit_root=case/'output'
if final:
    (case/'final-metadata').write_text('observed\n')
    if mode=='payload-id': rows[0]['id']+=10000
    elif mode=='payload-digest': rows[0]['digest']='sha256:'+'0'*64
    elif mode=='payload-size': rows[0]['size']+=1
    elif mode=='sidecar-id': rows[1]['id']+=10000
    elif mode=='signature-id': rows[-1]['id']+=10000
    elif mode=='release-mode': context['draft']=not context['draft']
    elif mode=='release-target': context['target_commitish']='another-target'
    elif mode=='local-payload':
        with (audit_root/'artifacts/tool-0.tar.gz').open('ab') as stream: stream.write(b'changed')
    elif mode=='local-audit':
        with (audit_root/'result.json').open('a') as stream: stream.write(' ')
    elif mode=='local-selection':
        with (audit_root/'selection.json').open('a') as stream: stream.write(' ')
    (case/'assets.json').write_text(json.dumps(rows))
    (case/'release.json').write_text(json.dumps(context))
    (case/'held-audit.json').write_bytes((audit_root/'result.json').read_bytes())
    (case/'calls-at-final.txt').write_text(str(len((case/'calls.jsonl').read_text().splitlines())))
code=7 if (mode=='manifest-final-failure' and final or mode=='manifest-initial-failure' and not final) else 0
details={'repo':'owner/tool','tag':'v1.2.3','release_id':42,
         'assets':{'present':sorted(r['name'] for r in rows),'extra':[],
                   'size_mismatches':[],'digest_mismatches':[]},
         'repair':{'requested':fix,'dry_run':'--dry-run' in args,'attempted':fix}}
print(json.dumps({'command':'release-verify','status':'success' if code==0 else 'error',
                  'exit_code':code,'details':details}))
sys.exit(code)
LEGACY
''')
    invocation = r'''source "$1/src/release_verify.sh" || exit 3
SCRIPT_DIR=$1; JSON_MODE=true; DRY_RUN=${CLI_DRY:-false}; DSR_VERSION=fixture
log_error() { printf '%s\n' "$*" >&2; }
shift; release_verify_cli "$@"'''

    def cli_case(label, mode='', extra=(), dry=False, selected_program=program):
        directory=case('cli-'+label)
        # Keep one excluded asset here; the standalone tests already exercise
        # both full pages. Four payloads still exceed the legacy sample size.
        write_json(directory/'assets.json',assets[:9])
        env=environment(directory)
        env.update(CLI_MODE=mode,CLI_DRY=str(dry).lower())
        command=['bash','-c',invocation,'_',str(selected_program),'tool','v1.2.3',
                 '--checksums','--checksum-mode','sidecars','--checksum-output-dir',str(directory/'output'),
                 *map(str,extra)]
        proc=subprocess.run(command,capture_output=True,env=env,timeout=45)
        (directory/'stdout').write_bytes(proc.stdout); (directory/'stderr').write_bytes(proc.stderr)
        try: result=json.loads(proc.stdout)
        except ValueError: result={}
        return directory,proc,result

    directory,proc,data=cli_case('unchanged')
    checksums=data.get('details',{}).get('checksums',{})
    check('CLI accepts complete unchanged coverage with a bound fresh inventory receipt',
          proc.returncode==0 and data.get('status')=='success' and checksums.get('verified_count')==4 and
          checksums.get('status')=='verified' and checksums.get('inventory_stable') is True and
          checksums.get('inventory_check',{}).get('status')=='unchanged')
    if not (directory/'final-metadata').exists():
        print(proc.stderr.decode(),flush=True)
        raise SystemExit(1)
    prior_root=directory/'output'; prior_snapshot=snapshot(prior_root)
    audited_bytes=hash_file(prior_root/'result.json')
    freshness=checksums.get('inventory_check') or {}
    check('CLI pins the original audit and retains a separate inventory-only observation',
          freshness.get('audit_sha256')==audited_bytes and freshness.get('payloads_reverified') is False and
          freshness.get('selection_sha256')==json.loads((prior_root/'result.json').read_text())['selection_sha256'])
    boundary=int((directory/'calls-at-final.txt').read_text())
    check('CLI freshness makes four bounded metadata reads and zero additional payload acquisitions',
          len(requests(directory)[boundary:])==4 and
          all('/releases/assets/' not in row['path'] for row in requests(directory)[boundary:]))
    check('CLI preserves completed audit bytes while checking freshness',
          (directory/'held-audit.json').read_bytes()==(prior_root/'result.json').read_bytes())

    for mode in ('payload-id','payload-digest','payload-size','sidecar-id','signature-id','release-mode','release-target','network-failure'):
        directory,proc,data=cli_case(mode,mode)
        c=data.get('details',{}).get('checksums',{})
        expected=8 if mode=='network-failure' else 1
        check('CLI refuses late '+mode+' despite unchanged names in manifest response',
              proc.returncode==expected and data.get('exit_code')==expected and data.get('status')!='success' and
              c.get('verified_count')==4 and c.get('status')=='stale-or-unconfirmed' and
              c.get('inventory_stable') is False and c.get('audit_inventory_stable') is True)
        check('late '+mode+' preserves the original audit and never reacquires binaries',
              (directory/'held-audit.json').read_bytes()==(directory/'output/result.json').read_bytes() and
              not any('/releases/assets/' in row['path'] for row in requests(directory)[
                  int((directory/'calls-at-final.txt').read_text()):]))

    for mode in ('local-payload','local-audit','local-selection'):
        directory,proc,data=cli_case(mode,mode)
        c=data.get('details',{}).get('checksums',{})
        check('CLI refuses '+mode+' corruption instead of replacing the selected evidence',
              proc.returncode!=0 and data.get('exit_code')==proc.returncode and
              data.get('status')!='success' and c.get('status')!='verified' and c.get('inventory_stable') is False)

    for mode in ('manifest-final-failure','manifest-initial-failure'):
        directory,proc,data=cli_case(mode,mode)
        check('successful checksum freshness cannot override '+mode,
              proc.returncode==7 and data.get('exit_code')==7 and data.get('status')!='success')

    for dry in (False,True):
        directory,proc,data=cli_case('repair-'+str(dry),extra=['--fix'],dry=dry)
        history=[json.loads(r) for r in (directory/'metadata.jsonl').read_text().splitlines()]
        check('CLI repair stays exactly once; original dry-run policy '+str(dry)+' is preserved',
              proc.returncode==0 and [r['fix'] for r in history]==[False,True,False] and
              all(r['dry_run']==dry for r in history) and
              data.get('details',{}).get('repair',{}).get('requested') is True)

    directory,proc,data=cli_case('resume',extra=['--checksum-resume-from',prior_root])
    c=data.get('details',{}).get('checksums',{})
    check('resumed CLI audit rechecks its new receipt without replaying the previous resume source',
          proc.returncode==0 and c.get('resume',{}).get('reused_count')==4 and
          (c.get('inventory_check') or {}).get('audited_output_dir')==str(directory/'output'))
    check('resumed CLI reacquires only sidecars and leaves the original audit unchanged',
          len([r for r in requests(directory) if '/releases/assets/' in r['path']])==4 and snapshot(prior_root)==prior_snapshot)

    cancelled=case('cli-cancelled')
    write_json(cancelled/'assets.json',assets[:9])
    command=['bash','-c',invocation,'_',str(program),'tool','v1.2.3','--checksums',
             '--checksum-mode','sidecars','--checksum-output-dir',str(cancelled/'output')]
    env=environment(cancelled);env['CLI_MODE']='hang'
    with (cancelled/'stdout').open('wb') as out,(cancelled/'stderr').open('wb') as err:
        proc=subprocess.Popen(command,stdout=out,stderr=err,env=env)
        deadline=time.monotonic()+30
        while not (cancelled/'worker.pid').exists() and proc.poll() is None and time.monotonic()<deadline:
            time.sleep(.02)
        if proc.poll() is None: proc.send_signal(signal.SIGTERM)
        code=proc.wait(timeout=15)
    try: data=json.loads((cancelled/'stdout').read_text())
    except ValueError: data={}
    worker_alive=False
    if (cancelled/'worker.pid').exists():
        try: os.kill(int((cancelled/'worker.pid').read_text()),0);worker_alive=True
        except ProcessLookupError: pass
    check('cancelling CLI freshness returns one nonzero result and stops the actual owned transport',
          code==5 and data.get('exit_code')==5 and not worker_alive and
          data.get('details',{}).get('checksums',{}).get('status')!='verified')
    print('%d passed, %d failed; CLI fixtures retained at %s' % (passed,failed,work),flush=True)
    raise SystemExit(1 if failed else 0)
elif sys.argv[2:]:
    raise SystemExit('Usage: test_release_checksum_freshness.sh [--cli]')

initial = case('initial')
proc, audit = run(initial)
audit_root = initial/'output'
check('production auditor verifies all four actual payloads using actual sidecar hashes',
      proc.returncode == 0 and audit.get('verified_count') == 4 and audit.get('inventory_stable') is True)
if proc.returncode:
    print(proc.stderr.decode(), flush=True)
    raise SystemExit(1)
pin = hash_file(audit_root/'result.json')
prior = snapshot(audit_root)

def recheck(label, change=None, mode='', source=audit_root, extra=(), expected=0, selected_pin=pin):
    directory = case(label, change)
    output = directory/'output'
    proc, result = run(directory, ['--recheck-from',source,'--audit-sha256',selected_pin,*extra],mode,source,output)
    check(label, proc.returncode == expected and result.get('exit_code') == expected and
          result.get('status') == ('unchanged' if expected == 0 else 'error'))
    check(label + ': no payload or checksum download',
          not any('/releases/assets/' in r['path'] for r in requests(directory)))
    return directory, result

stable, result = recheck('unchanged-inventory')
check('freshness result cannot masquerade as a new full checksum audit',
      result.get('kind') == 'dsr-release-checksum-inventory-check' and
      result.get('audit_sha256') == pin and result.get('selection_sha256') == audit['selection_sha256'] and
      result.get('payloads_reverified') is False and 'verified_count' not in result and
      not (stable/'output/checksums.normalized').exists() and not (stable/'output/verified.jsonl').exists())
check('both complete inventories and release contexts are read',len(requests(stable))==6)

for field, value in (('id',500),('size',9999),('digest','sha256:'+'0'*64),('digest',None)):
    recheck('payload-'+field+'-'+str(value)[:8],lambda rows, ctx, f=field,v=value: rows[0].update({f:v}),expected=1)
recheck('checksum-proof-replacement',lambda rows,ctx:rows[1].update(id=600),expected=1)
recheck('excluded-signature-replacement',lambda rows,ctx:rows[-1].update(id=7777),expected=1)
recheck('new-asset',lambda rows,ctx:rows.append(dict(id=99999,name='extra.minisig',state='uploaded',size=1,digest=None)),expected=1)
recheck('missing-asset',lambda rows,ctx:rows.pop(),expected=1)
for field, value in (('draft',True),('prerelease',True),('target_commitish','different'),('id',43)):
    recheck('release-'+field,lambda rows,ctx,f=field,v=value:ctx.update({f:v}),expected=1)
for label, mode, expected in (('late-inventory','late-inventory',1),('late-release','late-release',1),
                              ('network-failure','network-failure',8),('malformed-page','malformed-page',4),
                              ('duplicate-page','duplicate-page',4),('receipt-publication-failure','result-write-failure',1)):
    recheck(label,mode=mode,expected=expected)
for filename in ('selection','result'):
    retained = work/('changed-local-'+filename)
    shutil.copytree(audit_root,retained)
    recheck('local-'+filename,mode='local-'+filename,source=retained,expected=1)
recheck('wrong-audit-pin',selected_pin='0'*64,expected=4)
recheck('incompatible-mode',extra=['--resume-from',audit_root],expected=4)
overlap = case('overlapping-output')
proc, data = run(overlap,['--recheck-from',audit_root,'--audit-sha256',pin],output=audit_root/'nested')
check('overlapping output is refused before network or source changes',
      proc.returncode==4 and not requests(overlap) and not (audit_root/'nested').exists())

for label, extra in (('missing-pin',['--recheck-from',audit_root]),('orphan-pin',['--audit-sha256',pin])):
    directory = case(label)
    proc, data = run(directory,extra)
    check(label + ' fails before HTTP or output creation',proc.returncode==4 and not requests(directory) and not (directory/'output').exists())

preflight = case('preflight')
proc, data = run(preflight,['--recheck-from',audit_root,'--audit-sha256',pin,'--preflight'])
check('inventory preflight is not live verification and creates no output',
      proc.returncode==0 and data.get('status')=='planned' and data.get('preflight') is True and
      not requests(preflight) and not (preflight/'output').exists())

# A valid pin of a deliberately inconsistent copy is still not full coverage.
for label, change in (('partial',lambda r:r.update(status='error',exit_code=8,inventory_stable=False)),
                      ('zero-coverage',lambda r:r.update(eligible_count=0,verified_count=0,eligible_assets=[],verified_checksums=[])),
                      ('incomplete-coverage',lambda r:r.update(eligible_count=3,verified_count=3,eligible_assets=r['eligible_assets'][:3],verified_checksums=r['verified_checksums'][:3]))):
    retained = work/label
    shutil.copytree(audit_root,retained)
    modified = json.loads((retained/'result.json').read_text()); change(modified)
    write_json(retained/'result.json',modified)
    recheck(label,source=retained,selected_pin=hash_file(retained/'result.json'),expected=4)
linked = work/'linked-prior'; linked.symlink_to(audit_root,target_is_directory=True)
recheck('linked-prior',source=linked,expected=4)

resumed = case('existing-resume')
proc, data = run(resumed,['--resume-from',audit_root])
check('existing full resume still rehashes all four retained payloads',
      proc.returncode==0 and data.get('kind')=='dsr-release-checksum-verification' and
      data.get('verified_count')==4 and data.get('resume',{}).get('reused_count')==4)
check('full resume still reacquires every sidecar, not payloads',
      len([r for r in requests(resumed) if '/releases/assets/' in r['path']])==4)
check('original completed audit files, hashes and inodes remain unchanged',snapshot(audit_root)==prior)

cancelled = case('cancellation')
command = ['bash',str(module),*common,'--output-dir',str(cancelled/'output'),
           '--recheck-from',str(audit_root),'--audit-sha256',pin]
with (cancelled/'stdout').open('wb') as out, (cancelled/'stderr').open('wb') as err:
    proc = subprocess.Popen(command,stdout=out,stderr=err,env=environment(cancelled,'hang'))
    deadline = time.monotonic()+10
    while not (cancelled/'worker.pid').exists() and proc.poll() is None and time.monotonic()<deadline:
        time.sleep(.02)
    proc.send_signal(signal.SIGTERM)
    code = proc.wait(timeout=10)
data = json.loads((cancelled/'stdout').read_text())
worker_alive = False
if (cancelled/'worker.pid').exists():
    try:
        os.kill(int((cancelled/'worker.pid').read_text()),0); worker_alive=True
    except ProcessLookupError:
        pass
check('interruption retains a nonzero receipt and kills the owned transport process',
      code==5 and data.get('exit_code')==5 and not worker_alive)
print('%d passed, %d failed; fixtures retained at %s' % (passed,failed,work),flush=True)
raise SystemExit(1 if failed else 0)
PY
