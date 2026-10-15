#!/usr/bin/env bash
# Production release-command registration, checksum adapter, auditor and parser.
# The existing metadata/repair CLI and HTTP service are explicit boundary
# fixtures. No GitHub release is changed, no compiler or payload is executed.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for dependency in bash python3 jq; do
    command -v "$dependency" >/dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; exit 3; }
done
python3 - "$ROOT" <<'PY'
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
work = Path(tempfile.mkdtemp(prefix='dsr-verify-cli-tests-'))
print('Retained evidence: ' + str(work), flush=True)
passed = 0
sequence = 0

def check(label, value):
    global passed
    if not value:
        raise AssertionError(label)
    passed += 1
    print('PASS: ' + label, flush=True)

def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True) + '\n')

def sha(data):
    return hashlib.sha256(data).hexdigest()

runtime = work/'runtime'
(runtime/'src').mkdir(parents=True)
for name in ('release_formulas.sh','release_verify.sh','release_checksums.sh','checksum_sync.sh'):
    shutil.copy2(root/'src'/name, runtime/'src'/name)
# This is explicitly the METADATA CLI boundary, not an imitation of strict
# checks. Its outputs let the production adapter prove those checks cannot be
# overridden by a checksum success. Registration follows the actual root order:
# define original handler, load release module, then dispatch the command.
(runtime/'dsr').write_text(r'''#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)
DSR_VERSION=0.2.3
JSON_MODE=false DRY_RUN=false
while (($#)); do
    case "$1" in --json) JSON_MODE=true; shift ;; --dry-run) DRY_RUN=true; shift ;; *) break ;; esac
done
[[ "${1:-}/${2:-}" == release/verify ]] || exit 99
shift 2
log_error() { printf '[metadata-fixture] %s\n' "$*" >&2; }
json_envelope() {
    jq -cn --arg command "$1" --arg status "$2" --argjson code "$3" --argjson details "$4" \
       '{command:$command,status:$status,exit_code:$code,details:$details}'
}
cmd_release_verify() { python3 "$SCRIPT_DIR/metadata.py" "$JSON_MODE" "$DRY_RUN" "$@"; }
source "$SCRIPT_DIR/src/release_formulas.sh" || exit 3
source "$SCRIPT_DIR/src/release_formulas.sh" || exit 3
trap 'printf original-trap >&2' TERM
before=$(trap -p TERM)
rc=0; cmd_release_verify "$@" || rc=$?
[[ "$(trap -p TERM)" == "$before" ]] || exit 98
exit "$rc"
''')
(runtime/'metadata.py').write_text(r'''
import json, os, subprocess, sys, time
from pathlib import Path
base = Path(os.environ['DSR_VERIFY_FIXTURE'])
spec = json.loads((base/'fixture.json').read_text())
json_mode, dry = sys.argv[1]=='true', sys.argv[2]=='true'
args = sys.argv[3:]
assert not any(a in ('-c','--checksums','--verify-checksums') or a.startswith('--checksum-') for a in args), 'old checksum sampler called'
assert args[:2] == ['app','1.2.3'], args
repair = '--fix' in args
log=base/'metadata.jsonl'
previous = [json.loads(r) for r in log.read_text().splitlines()] if log.exists() else []
phase = 'repair' if repair else 'after' if previous else 'before'
with log.open('a') as f: f.write(json.dumps(dict(phase=phase,dry_run=dry,argv=args))+'\n')
if spec.get('metadata_mode')=='malformed':
    print('not JSON'); sys.exit(0)
if repair and spec.get('metadata_mode')=='cancel-repair':
    descendant = subprocess.Popen([sys.executable,'-c',
        'import time,pathlib; time.sleep(4); pathlib.Path('+repr(str(base/'late-repair-write'))+').write_text("bad")'])
    (base/'repair-descendant').write_text(str(descendant.pid))
    (base/'blocked-pid').write_text(str(os.getpid()))
    time.sleep(30)
if repair and not dry and 'missing_row' in spec:
    spec['assets'].append(spec.pop('missing_row'))
    (base/'fixture.json').write_text(json.dumps(spec)+'\n')
    (base/'repair-write').write_text('exact selected missing asset restored\n')
if phase=='after' and spec.get('metadata_mode') in ('proof-drift','payload-drift'):
    audit = next(base.glob('dsr-release-verify-*/audit'))
    file = audit/('evidence/SHA256SUMS' if spec['metadata_mode']=='proof-drift' else 'artifacts/app-000.tar.gz')
    with file.open('ab') as f: f.write(b'changed during final metadata check')
code = 1 if 'missing_row' in spec else 0
mode = spec.get('metadata_mode')
if mode=='strict-failure' or (phase=='after' and mode=='final-strict-failure'): code=1
if repair and mode=='repair-failure': code=7
names=sorted(a['name'] for a in spec['assets'])
if phase=='after' and mode=='inventory-drift': names.append('unobserved-extra')
wrong = [names[0]] if code and mode in ('strict-failure','final-strict-failure') else []
missing = [spec['missing_row']['name']] if 'missing_row' in spec else []
record = dict(repo='owner/app',version='1.2.3',tag='v1.2.3',release_id=322 if phase=='after' and mode=='identity-drift' else 321,
    release_url='https://github.com/owner/app/releases/tag/v1.2.3',manifest_found=True,
    verification=dict(expected=len(names)+len(missing),present=len(names)-len(wrong),missing=len(missing),extra=0,
        size_mismatches=0,digest_mismatches=len(wrong),remote_records_valid=not bool(wrong),tag_ruleset_receipt={'sentinel':'must-be-preserved'}),
    assets=dict(present=[n for n in names if n not in wrong],missing=missing,extra=[],size_mismatches=[],digest_mismatches=wrong),
    checksums=dict(verified=[],errors=[]),repair={'dry_run':dry,'uploads':['app-004.tar.gz']} if repair else None)
if json_mode:
    print(json.dumps(dict(command='release-verify',status='incomplete' if code else 'success',exit_code=code,details=record)))
else:
    print('metadata fixture result',file=sys.stderr)
sys.exit(code)
''')
bin_dir = work/'bin'
bin_dir.mkdir()
(bin_dir/'curl').write_text('#!'+sys.executable+' -S\n'+r'''
import json, os, sys, time
from pathlib import Path
from urllib.parse import urlparse, parse_qs
base = Path(os.environ['DSR_VERIFY_FIXTURE'])
spec=json.loads((base/'fixture.json').read_text())
args=sys.argv[1:]
if args==['--disable','--version']:
    print('curl '+spec.get('curl_version','8.4.0')+' test boundary'); sys.exit(0)
config=sys.stdin.read()
def value(k):return args[args.index(k)+1]
assert args[0]=='--disable' and '--fail' in args and '--location' in args
assert value('--proto')=='=https' and value('--proto-redir')=='=https'
assert '--location-trusted' not in args and '--insecure' not in args
assert 'Authorization: Bearer owned_test_token' in config
assert not any('owned_test_token' in a for a in args)
u=urlparse(args[-1]); assert u.netloc=='api.github.com' and u.path.startswith('/repos/owner/app/releases/')
with (base/'http.jsonl').open('a') as f:f.write(json.dumps({'url':args[-1],'binary':'application/octet-stream' in config})+'\n')
if '/assets/' in u.path:
    identity=int(u.path.rsplit('/',1)[1])
    if spec.get('mode')=='cancel' and identity==5:
        (base/'blocked-pid').write_text(str(os.getpid()));time.sleep(30)
    if spec.get('mode')=='download-failure' and identity==5:sys.exit(22)
    data=(base/'bodies'/str(identity)).read_bytes()
elif '/tags/' in u.path:
    data=json.dumps(spec['context']).encode()
else:
    assert 'application/vnd.github+json' in config
    page=int(parse_qs(u.query)['page'][0]); data=json.dumps(spec['assets'][(page-1)*100:page*100]).encode()
Path(value('--output')).write_bytes(data)
''')
(bin_dir/'curl').chmod(0o755)
(bin_dir/'gh').write_text('#!/bin/sh\n[ "$*" = "auth token --hostname github.com" ] || exit 99\nprintf owned_test_token\n')
(bin_dir/'gh').chmod(0o755)

trap_probe=r'''
set -uo pipefail
SCRIPT_DIR="$1"; DSR_VERSION=fixture; JSON_MODE=false; DRY_RUN=false
log_error() { printf '%s\n' "$*" >&2; }
source "$SCRIPT_DIR/src/release_verify.sh"
trap 'printf "%s" "$(printf deferred-command)" >> "$DSR_TRAP_MARKER"' INT
trap $'printf "%s" "apostrophe\047 and quotes" >> "$DSR_TRAP_MARKER"\n\n' TERM
trap '' HUP
before=$(trap -p INT TERM HUP)
release_verify_cli --help > "$2/help-custom" || exit $?
[[ "$(trap -p INT TERM HUP)" == "$before" && ! -e "$DSR_TRAP_MARKER" ]] || exit 97
trap - INT TERM HUP
before=$(trap -p INT TERM HUP)
release_verify_cli --help > "$2/help-default" || exit $?
[[ "$(trap -p INT TERM HUP)" == "$before" && ! -e "$DSR_TRAP_MARKER" ]] || exit 98
'''
probe=work/'signal-handlers';probe.mkdir()
p=subprocess.run(['bash','-c',trap_probe,'fixture',str(runtime),str(probe)],
                 env=dict(os.environ,DSR_TRAP_MARKER=str(probe/'unexpected-handler')),
                 capture_output=True,timeout=20)
(probe/'stdout').write_bytes(p.stdout);(probe/'stderr').write_bytes(p.stderr)
check('real verifier wrapper preserves custom, ignored and default traps without evaluating bodies',p.returncode==0)
check('real verifier help retains the public USAGE contract',
      (probe/'help-custom').read_text().startswith('USAGE: dsr release verify'))

def fixture(label, mode=None, count=5):
    global sequence
    sequence+=1
    base=work/('%03d-%s'%(sequence,label)); (base/'bodies').mkdir(parents=True)
    rows=[]
    def add(name, data):
        id=len(rows)+1; (base/'bodies'/str(id)).write_bytes(data)
        rows.append(dict(id=id,name=name,state='uploaded',size=len(data),digest='sha256:'+sha(data)))
    for i in range(count):add('app-%03d.tar.gz'%i,('Owned executable fixture %03d\n'%i).encode())
    data=''.join(a['digest'][7:]+'  '+a['name']+'\n' for a in rows).encode()
    add('SHA256SUMS',data)
    add('release.intoto.jsonl',b'Explicit excluded provenance fixture\n')
    spec=dict(context=dict(id=321,tag_name='v1.2.3',draft=True,prerelease=False,target_commitish='main'),assets=rows,mode=mode)
    save(base/'fixture.json',spec)
    env=dict(os.environ,DSR_VERIFY_FIXTURE=str(base),DSR_GH_TOKEN='owned_test_token',GH_TOKEN='',GITHUB_TOKEN='',
             PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],TMPDIR=str(base))
    return base,spec,env

def calls(base, file):
    return [json.loads(s) for s in (base/file).read_text().splitlines()] if (base/file).exists() else []

def command(extra=(), dry=False, checksum=True, json_mode=True):
    return ['bash',str(runtime/'dsr'),*(['--json'] if json_mode else []),*(['--dry-run'] if dry else []),
            'release','verify','app','1.2.3',*(['--verify-checksums'] if checksum else []),*extra]

def execute(label, expected=0, extra=(), mutate=None, dry=False, mode=None, checksum=True, count=5):
    base,spec,env=fixture(label,mode,count)
    if mutate:mutate(base,spec)
    save(base/'fixture.json',spec)
    p=subprocess.run(command(extra,dry,checksum),capture_output=True,env=env,timeout=120)
    (base/'stdout').write_bytes(p.stdout);(base/'stderr').write_bytes(p.stderr)
    if p.returncode!=expected:
        print(p.stdout.decode(errors='replace'),p.stderr.decode(errors='replace'),flush=True)
    check(label+': process status',p.returncode==expected)
    value=json.loads(p.stdout)
    check(label+': one truthful envelope',value['command']=='release-verify' and value['exit_code']==expected and
          (expected!=0 or value['status']=='success'))
    if checksum:
        c=value['details']['checksums']
        check(label+': checksum evidence is not signer or source authentication',c['authenticated'] is False and c['source_verified'] is False)
        if expected==0:
            check(label+': complete positive coverage',c['status']=='verified' and c['eligible_count']>0 and c['verified_count']==c['eligible_count']==len(c['verified']))
        if 'verification_evidence_dir' in value['details']:
            check(label+': persisted outer result matches stdout',json.loads((Path(value['details']['verification_evidence_dir'])/'result.json').read_text())==value)
    return base,spec,env,value

base,spec,env,value=execute('full-five')
check('all five payloads reach root checksum report',value['details']['checksums']['verified_count']==5)
check('checksum report identifies all deliberate exclusions',
      {r['reason'] for r in value['details']['checksums']['excluded_assets']}=={'checksum-aggregate','provenance-or-sbom'})
check('strict metadata fields survive successful audit',value['details']['verification']['tag_ruleset_receipt']=={'sentinel':'must-be-preserved'})
check('metadata is checked before and after the audit without sampling flags',
      [r['phase'] for r in calls(base,'metadata.jsonl')]==['before','after'] and
      all(r['argv']==['app','1.2.3'] for r in calls(base,'metadata.jsonl')))
check('all five bodies are downloaded by numeric API ID',len([r for r in calls(base,'http.jsonl') if r['binary']])==6)
# Aliases and named options route to the same new verifier.
base,_,env=fixture('alias-options')
p=subprocess.run(['bash',str(runtime/'dsr'),'--json','release','verify','--tool','app','--version','1.2.3','--checksums'],env=env,capture_output=True,timeout=60)
check('root --checksums alias and named arguments work',p.returncode==0 and json.loads(p.stdout)['details']['checksums']['verified_count']==5)
base,_,env=fixture('intermixed-options')
p=subprocess.run(['bash',str(runtime/'dsr'),'--json','release','verify','app','--checksums','1.2.3'],env=env,capture_output=True,timeout=60)
check('checksum options can occur between positional selections',p.returncode==0 and json.loads(p.stdout)['details']['checksums']['verified_count']==5)
base,_,_,value=execute('short-checksum-flag',extra=('-c',),checksum=False)
check('short checksum flag invokes complete audit',value['details']['checksums']['verified_count']==5)
execute('more-than-one-inventory-page',count=101)

# Same release inventory and claimed API digests cannot conceal wrong bytes
# against the independently downloaded aggregate.
def corruption(base,spec):
    file=base/'bodies/5'; data=b'changed fifth payload\n'; file.write_bytes(data)
    spec['assets'][4].update(size=len(data),digest='sha256:'+sha(data))
base,_,_,value=execute('fifth-payload-corruption',1,mutate=corruption)
check('four successes cannot conceal corrupt fifth payload',value['details']['checksums']['verified_count']==4 and
      value['details']['checksums']['errors']==['app-004.tar.gz'])
execute('failed-payload-download',8,mode='download-failure')
execute('no-checksum-evidence',1,mutate=lambda b,s:s.update(assets=[a for a in s['assets'] if a['name']!='SHA256SUMS']))
def change_aggregate(base,spec,data):
    row=next(a for a in spec['assets'] if a['name']=='SHA256SUMS');(base/'bodies'/str(row['id'])).write_bytes(data)
    row.update(size=len(data),digest='sha256:'+sha(data))
execute('malformed-checksum-evidence',4,mutate=lambda b,s:change_aggregate(b,s,b'<html>error</html>'))
execute('unmatched-checksum-names',1,mutate=lambda b,s:change_aggregate(b,s,('a'*64+'  foreign\n').encode()))
execute('empty-payload-coverage',1,count=0)
execute('explicit-metadata-coverage',1,extra=('--checksum-include-metadata',))

def sidecars(base,spec):
    payloads=[a for a in spec['assets'] if a['name'].endswith('.tar.gz')]
    spec['assets']=[a for a in spec['assets'] if a['name']!='SHA256SUMS']
    for i,a in enumerate(payloads):
        id=1000+i;data=(a['digest'][7:]+'\n').encode();(base/'bodies'/str(id)).write_bytes(data)
        spec['assets'].append(dict(id=id,name=a['name']+'.sha256',state='uploaded',size=len(data),digest='sha256:'+sha(data)))
execute('complete-sidecar-release',extra=('--checksum-mode','sidecars'),mutate=sidecars)
execute('default-cannot-silently-fall-back-to-sidecars',1,mutate=sidecars)

def missing(base,spec):
    spec['missing_row']=spec['assets'].pop(4)
base,_,_,value=execute('repair-before-audit',extra=('--fix',),mutate=missing)
check('repair is performed once and never replayed by final metadata check',
      [r['phase'] for r in calls(base,'metadata.jsonl')]==['before','repair','after'] and (base/'repair-write').is_file())
check('repair evidence remains in final envelope',value['details']['repair']=={'dry_run':False,'uploads':['app-004.tar.gz']})
base,_,_,value=execute('dry-run-does-not-repair',1,extra=('--fix',),mutate=missing,dry=True)
check('dry-run keeps missing asset and repair evidence without writes',not (base/'repair-write').exists() and
      value['details']['repair']['dry_run'] is True and value['details']['checksums']['status']=='error')
base,_,_,value=execute('dry-run-still-audits',dry=True)
check('read-only dry-run still hashes every selected payload',value['details']['checksums']['verified_count']==5)

for label,code,options in (
    ('bad-timeout',4,('--checksum-timeout','0')),
    ('bad-mode',4,('--checksum-mode','sample')),
    ('bad-output',4,('--checksum-output-dir','relative/audit')),
    ('sidecar-aggregate-conflict',4,('--checksum-mode','sidecars','--checksum-asset','SHA256SUMS')),
):
    base,_,_,value=execute(label,code,extra=(*options,'--fix'),mutate=missing)
    check(label+': no repair before invalid audit policy is refused',not (base/'repair-write').exists() and
          all(r['phase']!='repair' for r in calls(base,'metadata.jsonl')))
base,_,_,value=execute('old-curl-refused-before-repair',3,extra=('--fix',),mutate=lambda b,s:(missing(b,s),s.update(curl_version='8.3.0')))
check('unbounded transport cannot start a repair',all(r['phase']!='repair' for r in calls(base,'metadata.jsonl')))

base,_,_,value=execute('replaced-release-id',1,mutate=lambda b,s:s['context'].update(id=999))
check('selected release ID blocks replacement before any inventory/download',len(calls(base,'http.jsonl'))==1)
for mode in ('identity-drift','inventory-drift','proof-drift','payload-drift'):
    base,_,_,value=execute(mode,7,mutate=lambda b,s,m=mode:s.update(metadata_mode=m))
    if mode in ('proof-drift','payload-drift'):
        check(mode+': a formerly verified audit is not admitted after drift',value['details']['checksums']['status']=='not-admitted')
for mode in ('strict-failure','final-strict-failure'):
    base,_,_,value=execute(mode,1,mutate=lambda b,s,m=mode:s.update(metadata_mode=m))
    check(mode+': successful checksums cannot override strict failure',value['status']=='incomplete' and
          value['details']['checksums']['status']=='verified' and value['details']['verification']['remote_records_valid'] is False)
execute('malformed-metadata-result',7,mutate=lambda b,s:s.update(metadata_mode='malformed'))

# Audit outputs selected outside the adapter workspace never allow the adapter
# to write normalizer temporaries in an operator-selected parent directory.
base,spec,env=fixture('external-output')
parent=base/'external';parent.mkdir();sentinel=parent/'handoff.normalized';sentinel.write_text('keep original\n')
p=subprocess.run(command(('--checksum-output-dir',str(parent/'audit'))),env=env,capture_output=True,timeout=60)
check('explicit audit destination completes without touching parent files',p.returncode==0 and sentinel.read_text()=='keep original\n')
held=(parent/'audit/result.json').read_bytes()
p=subprocess.run(command(('--checksum-output-dir',str(parent/'audit'),'--fix')),env=env,capture_output=True,timeout=60)
check('occupied audit destination is preserved and does not trigger repair',p.returncode==4 and (parent/'audit/result.json').read_bytes()==held and
      all(r['phase']!='repair' for r in calls(base,'metadata.jsonl')))

# The ordinary metadata route is still a direct call: no extra dependencies,
# audit directory, child repair or semantic change. Repeated module sourcing
# is already exercised by every runtime invocation above.
base,_,_,value=execute('ordinary-metadata-only',checksum=False)
check('ordinary verification never invokes auditor',not (base/'http.jsonl').exists() and
      not list(base.glob('dsr-release-verify-*')) and value['details']['checksums']=={'verified':[],'errors':[]})
base,_,env=fixture('human-output')
p=subprocess.run(command(json_mode=False),env=env,capture_output=True,timeout=60)
check('human mode does not leak internal JSON to stdout',p.returncode==0 and not p.stdout and b'5/5 eligible payloads' in p.stderr)
base,_,env=fixture('help')
p=subprocess.run(['bash',str(runtime/'dsr'),'release','verify','--help'],env=env,capture_output=True,timeout=20)
check('root help exposes complete checksum options without remote work',p.returncode==0 and b'--checksum-mode' in p.stdout and not (base/'http.jsonl').exists())

# A missing new verifier fails closed rather than returning to the old sampler.
module=runtime/'src/release_verify.sh';module.rename(runtime/'src/release_verify-held.sh')
try:
    base,_,env=fixture('missing-module')
    p=subprocess.run(command(),env=env,capture_output=True,timeout=20)
    check('missing adapter never falls back to legacy checksum handling',p.returncode==3 and
          json.loads(p.stdout)['details']['checksums']['verified_count']==0 and not (base/'metadata.jsonl').exists())
finally:
    (runtime/'src/release_verify-held.sh').rename(module)

parser_module=runtime/'src/checksum_sync.sh';parser_module.rename(runtime/'src/checksum_sync-held.sh')
try:
    base,spec,env=fixture('missing-parser');missing(base,spec);save(base/'fixture.json',spec)
    p=subprocess.run(command(('--fix',)),env=env,capture_output=True,timeout=20)
    check('missing shared parser is a dependency failure before any repair',p.returncode==3 and
          not (base/'metadata.jsonl').exists() and not (base/'repair-write').exists())
finally:
    (runtime/'src/checksum_sync-held.sh').rename(parser_module)

for suffix in ('/./audit','/audit/'):
    base,spec,env=fixture('noncanonical-output');missing(base,spec);save(base/'fixture.json',spec)
    p=subprocess.run(command(('--checksum-output-dir',str(base)+suffix,'--fix')),env=env,capture_output=True,timeout=30)
    check('noncanonical audit destination cannot be normalized into a repair',p.returncode==4 and
          not (base/'audit').exists() and all(r['phase']!='repair' for r in calls(base,'metadata.jsonl')))

# Real cancellation of the public Bash supervisor. Active acquisition and
# descendants must stop before a terminal response; repair is never retried.
def alive(pid):
    try:
        text=Path('/proc/%d/stat'%pid).read_text()
        return text.split(') ',1)[1][0]!='Z'
    except FileNotFoundError:
        return False
for label,mode,options in (('cancel-download','cancel',()),('cancel-repair',None,('--fix',))):
    base,spec,env=fixture(label,mode)
    if label=='cancel-repair':spec['metadata_mode']='cancel-repair'
    save(base/'fixture.json',spec)
    p=subprocess.Popen(command(options),env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        until=time.monotonic()+25
        while not (base/'blocked-pid').exists() and time.monotonic()<until and p.poll() is None:time.sleep(.05)
        check(label+': actual owned operation started',(base/'blocked-pid').is_file())
        pid=int((base/'blocked-pid').read_text())
        p.send_signal(signal.SIGTERM)
        out,err=p.communicate(timeout=15)
        (base/'stdout').write_bytes(out);(base/'stderr').write_bytes(err)
        value=json.loads(out)
        check(label+': public supervisor returns one interrupted envelope',p.returncode==5 and value['exit_code']==5 and value['status']=='error')
        check(label+': active operation no longer runs',not alive(pid))
        if label=='cancel-download':
            check('cancelled audit never reaches final metadata or repair',[r['phase'] for r in calls(base,'metadata.jsonl')]==['before'])
            check('cancellation retains earlier verified payload count without a success claim',value['details']['checksums']['verified_count']==4 and
                  value['details']['checksums']['status']=='error')
        else:
            child=int((base/'repair-descendant').read_text())
            check('cancelled repair stops its delayed descendant',not alive(child))
            check('interrupted repair never claims no mutation occurred',value['details']['repair']['outcome']=='unknown' and value['details']['repair']['attempted'] is True)
            time.sleep(4.2)
            check('cancelled repair cannot perform a delayed write',not (base/'late-repair-write').exists() and
                  [r['phase'] for r in calls(base,'metadata.jsonl')]==['before','repair'])
    finally:
        if p.poll() is None:p.terminate();p.communicate(timeout=15)

# Exercise the standalone audit prerequisites independently of the adapter.
# The version probe is local; preflight must not even resolve credentials.
for identity, expected in (('321',0),('322',1),('0',4),('-1',4),('9007199254740992',4),('not-an-id',4)):
    base,spec,env=fixture('direct-ID-'+identity)
    p=subprocess.run(['bash',str(runtime/'src/release_checksums.sh'),'--repo','owner/app','--tag','v1.2.3',
                      '--release-id',identity,'--output-dir',str(base/'audit')],env=env,capture_output=True,timeout=60)
    value=json.loads(p.stdout)
    check('standalone selected ID '+identity+' has truthful status',p.returncode==expected and value['exit_code']==expected)
    if identity=='321':
        check('standalone ID pin survives complete audit',value['expected_release_id']==value['release']['id']==321 and value['verified_count']==5)
    elif identity=='322':
        check('wrong selected ID stops after the single release lookup',len(calls(base,'http.jsonl'))==1 and value['eligible_count']==0)
    else:
        check('invalid selected ID performs no HTTP',not (base/'http.jsonl').exists())
base,spec,env=fixture('direct-preflight');env['DSR_GH_TOKEN']='invalid\ncredential'
audit_output=base/'audit'
preview_command=['bash',str(runtime/'src/release_checksums.sh'),'--repo','owner/app','--tag','v1.2.3',
                 '--release-id','321','--output-dir',str(audit_output),'--preflight']
p=subprocess.run(preview_command,env=env,capture_output=True,timeout=20);value=json.loads(p.stdout)
check('standalone preflight validates without reading bad credentials',p.returncode==0 and value['status']=='planned' and
      value['authenticated'] is False and value['expected_release_id']==321)
check('standalone preflight cannot imply checksum success',value['eligible_count']==value['verified_count']==0 and
      value['inventory_stable'] is False and not audit_output.exists() and not (base/'http.jsonl').exists())
audit_output.mkdir();(audit_output/'retained').write_text('Original evidence\n')
p=subprocess.run(preview_command,env=env,capture_output=True,timeout=20)
check('standalone preflight preserves occupied output',p.returncode==4 and (audit_output/'retained').read_text()=='Original evidence\n')
spec['curl_version']='8.3.0';save(base/'fixture.json',spec)
p=subprocess.run(preview_command,env=env,capture_output=True,timeout=20)
check('standalone preflight refuses unbounded transport without HTTP',p.returncode==3 and not (base/'http.jsonl').exists())
base,_,env=fixture('token-precedence');env.update(GH_TOKEN='wrong',GITHUB_TOKEN='wrong')
p=subprocess.run(['bash',str(runtime/'src/release_checksums.sh'),'--repo','owner/app','--tag','v1.2.3',
                  '--output-dir',str(base/'audit')],env=env,capture_output=True,timeout=60)
check('explicit DSR token takes precedence through actual acquisition boundary',p.returncode==0 and len(calls(base,'http.jsonl'))==10)

save(work/'summary.json',dict(passed=passed,failed=0,metadata_boundary='explicit CLI fixture',http_boundary='explicit curl fixture'))
print('Results: %d passed, 0 failed\nEvidence: %s'%(passed,work),flush=True)
PY
