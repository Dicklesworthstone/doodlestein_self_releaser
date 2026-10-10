#!/usr/bin/env bash
# Real SLSA mapping, policy checks, payload hashing and snapshot publication.
# Remote acquisition is an explicit local-file boundary fixture. No release is
# written and no payload is executed. Minisign is real unless explicitly opted
# into DSR_TEST_MINISIGN_FIXTURE=1 (not cryptographic qualification).
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 jq bash sha256sum flock; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
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
module = Path(os.environ.get('SLSA_REMOTE_TEST_MODULE', root / 'src/slsa_remote.sh'))
work = Path(tempfile.mkdtemp(prefix='dsr-release-contract-'))
print('Evidence: ' + str(work), flush=True)
passed = failed = calls = 0
pin = '1' * 40
builder = 'dsr:contract-test'
targets = ['linux/amd64', 'linux/arm64']
repo, tag = 'example/app', 'v1.2.3'
public, secret = work / 'trusted.pub', work / 'test-only.key'
bin_dir = work / 'bin'
bin_dir.mkdir()
env = {k: v for k, v in os.environ.items() if not k.startswith('BASH_FUNC_') and k not in ('BASH_ENV', 'ENV')}
env.update(PATH=str(bin_dir) + ':' + env['PATH'], DSR_CONTRACT_TEST=str(work))
fixture = os.environ.get('DSR_TEST_MINISIGN_FIXTURE') == '1'
if fixture:
    print('Signer: explicit key/hash test fixture, NOT Minisign cryptography', flush=True)
    token = 'A' * 56
    public.write_text('untrusted comment: test-only\n' + token + '\n')
    signer = bin_dir / 'minisign'
    signer.write_text('''#!/usr/bin/env python3
# TEST-ONLY signature boundary, not a cryptographic implementation.
import hashlib, os, pathlib, sys
try:
    a=sys.argv[1:]
    assert '-V' in a
    proof=pathlib.Path(a[a.index('-m')+1]); signature=pathlib.Path(a[a.index('-x')+1])
    token=a[a.index('-P')+1]
    assert signature.read_text() == 'TEST:'+token+':'+hashlib.sha256(proof.read_bytes()).hexdigest()+'\\n'
    if os.environ.get('DSR_CONTRACT_MUTATE'):
        pathlib.Path(os.environ['DSR_CONTRACT_MUTATE']).write_text('{"changed":true}\\n')
except (AssertionError, ValueError, IndexError, OSError):
    sys.exit(1)
''')
    signer.chmod(0o755)
else:
    if not shutil.which('minisign'):
        print('Missing Minisign; explicitly use DSR_TEST_MINISIGN_FIXTURE=1 for boundary-only tests', file=sys.stderr)
        sys.exit(3)
    subprocess.run(['minisign', '-G', '-W', '-p', str(public), '-s', str(secret)], check=True, capture_output=True)
# Poison every real network command; the separate remote-driver fixture owns
# only acquisition and API observation, never signature or content admission.
for name in ('curl', 'wget', 'gh'):
    p=bin_dir/name
    p.write_text('#!/bin/sh\nprintf "unexpected network\\n" >&2\nexit 99\n')
    p.chmod(0o755)

def check(label, ok):
    global passed, failed
    if ok: passed += 1
    else: failed += 1
    print(('PASS ' if ok else 'FAIL ') + label, flush=True)

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p, v): p.write_text(json.dumps(v, sort_keys=True)+'\n'); return p
def read(p): return json.loads(p.read_text())
def invoke(command, expected=0, label='command', extra_env=None):
    global calls
    calls += 1
    result=subprocess.run(list(map(str,command)), env=dict(env, **(extra_env or {})), capture_output=True, timeout=60)
    (work/('%03d.stdout'%calls)).write_bytes(result.stdout)
    (work/('%03d.stderr'%calls)).write_bytes(result.stderr)
    check(label+' exit '+str(expected), result.returncode==expected)
    if result.returncode!=expected: print(result.stderr.decode(errors='replace'), flush=True)
    return result

def sign(proof):
    if fixture: Path(str(proof)+'.minisig').write_text('TEST:'+token+':'+sha(proof)+'\n')
    else:
        subprocess.run(['minisign','-S','-s',str(secret),'-m',str(proof),'-x',str(proof)+'.minisig','-t','owned contract test'],
                       check=True,capture_output=True)

snapshot=work/'snapshot'; assets=snapshot/'artifacts'; assets.mkdir(parents=True)
artifacts=[]; environments=[]
for index, (target,cpu,abi) in enumerate(((targets[0],'x86_64','gnu'),(targets[0],'x86_64','musl'),
                                       (targets[1],'aarch64','gnu'),(targets[1],'aarch64','musl'))):
    triple=cpu+'-unknown-linux-'+abi
    p=assets/('payload-%d'%index); p.write_bytes(('owned artifact '+triple+'\n').encode())
    artifacts.append(dict(name=p.name,target=target,target_triple=triple,archive_format='binary',sha256=sha(p),size_bytes=p.stat().st_size))
    environments.append(dict(target=target,target_triple=triple,method='native',host='fixture'))
shutil.copy2(assets/'payload-0',assets/'compat-alias')
artifacts.append(dict(artifacts[0],name='compat-alias'))
manifest=dict(schema_version='1.0.0',tool='app',version=tag,run_id='12345678-1234-4123-8123-123456789abc',
              source=dict(git_sha=pin,git_ref='refs/tags/'+tag,dependencies=[]),built_at='2026-10-10T01:02:03Z',
              status='success',summary=dict(total=4,success=4,failed=0),requested_targets=targets,
              artifacts=artifacts,build_environments=environments)
save(work/'manifest.json',manifest)
proof=snapshot/'release.intoto.jsonl'
p=invoke(['bash',root/'src/slsa.sh','generate-manifest',work/'manifest.json',assets,'--repository',repo,'--builder',builder,'--output',proof],label='real manifest mapping')
if p.returncode: sys.exit(1)
sign(proof); save(snapshot/'download.json',dict(untrusted=True))
contract=dict(schema_version=1,required_assets=[{k:a[k] for k in ('name','target','target_triple','archive_format')} for a in artifacts],
              required_variants=[{k:e[k] for k in ('target','target_triple')} for e in environments])
contract_file=save(work/'contract.json',contract)
policy=['--repo',repo,'--tag',tag,'--sha',pin,'--builder',builder,'--targets',','.join(targets),'--public-key',public]

def verify(directory=snapshot, contract_path=contract_file, expected=0, label='snapshot', extra=()):
    return invoke(['bash',module,'verify-snapshot',directory,*policy,
                   *([] if contract_path is None else ['--release-contract',contract_path]),*extra],expected,label)

def describe(path=contract_file, expected=0, selected_targets=targets):
    return invoke(['bash',module,'describe-contract','--release-contract',path,'--targets',','.join(selected_targets)],expected,'describe contract')

preview=describe()
if preview.returncode==0:
    described=json.loads(preview.stdout)
    check('description never claims authentication',described['authenticated'] is False)
    expected_hash=described['contract_sha256']
else: expected_hash='0'*64
verified=verify()
if verified.returncode==0:
    observed=json.loads(verified.stdout)
    check('snapshot retains independent exact contract policy', observed['policy']['release_contract_sha256']==expected_hash and
          observed['policy']['release_contract']==described['contract'])
    check('actual named artifacts remain fully hashed',len(observed['artifacts'])==5 and observed['authenticated'] is True and observed['remote_current'] is False)
    basic=verify(contract_path=None,label='legacy platform-only policy')
    if basic.returncode==0:
        check('contract changes policy, not immutable snapshot byte identity',json.loads(basic.stdout)['snapshot_sha256']==observed['snapshot_sha256'])
reordered=copy.deepcopy(contract);reordered['required_assets'].reverse();reordered['required_variants'].reverse()
reordered_file=save(work/'reordered.json',reordered)
p=describe(reordered_file)
if p.returncode==0: check('contract order is not semantic identity',json.loads(p.stdout)['contract_sha256']==expected_hash)

# Valid signatures and complete platform coverage alone accepted all these
# selections. The independently supplied exact contract must refuse them.
for change in ('missing-variant','missing-alias','swapped-compiler','changed-format','foreign-asset'):
    dest=work/change;shutil.copytree(snapshot,dest);statement=read(dest/'release.intoto.jsonl')
    if change.startswith('missing'):
        omitted='payload-1' if change=='missing-variant' else 'compat-alias'
        statement['subject']=[s for s in statement['subject'] if s['name']!=omitted]
        statement['dsr_evidence']['artifacts']=[a for a in statement['dsr_evidence']['artifacts'] if a['name']!=omitted]
        (dest/'artifacts'/omitted).rename(work/(change+'-retained-payload'))
    elif change=='swapped-compiler':
        selected=[a for a in statement['dsr_evidence']['artifacts'] if a['name'] in ('payload-0','payload-1')]
        selected[0]['target_triple'],selected[1]['target_triple']=selected[1]['target_triple'],selected[0]['target_triple']
    elif change=='changed-format': statement['dsr_evidence']['artifacts'][0]['archive_format']='zip'
    else:
        shutil.copy2(dest/'artifacts/payload-0',dest/'artifacts/extra')
        statement['subject'].append(dict(name='extra',digest=dict(sha256=sha(dest/'artifacts/extra'))))
        statement['dsr_evidence']['artifacts'].append(dict(statement['dsr_evidence']['artifacts'][0],name='extra'))
    save(dest/'release.intoto.jsonl',statement);sign(dest/'release.intoto.jsonl')
    verify(dest,None,0,'platform-only accepts '+change)
    p=verify(dest,expected=7,label='exact contract refuses '+change)
    check(change+' cannot emit successful verification',not p.stdout)

for change in ('null','boolean-version','empty','case-collision','unsafe-name','unsafe-triple','untyped-variant',
               'duplicate-variant','missing-platform','format','unknown-field'):
    bad=copy.deepcopy(contract)
    if change=='null': bad=None
    elif change=='boolean-version': bad['schema_version']=True
    elif change=='empty': bad['required_assets']=[]
    elif change=='case-collision': bad['required_assets'].append(dict(bad['required_assets'][0],name=bad['required_assets'][0]['name'].upper()))
    elif change=='unsafe-name': bad['required_assets'][0]['name']='../escape'
    elif change=='unsafe-triple': bad['required_assets'][0]['target_triple']=None
    elif change=='untyped-variant': bad['required_assets'][0].pop('target_triple')
    elif change=='duplicate-variant': bad['required_variants'].append(bad['required_variants'][0])
    elif change=='missing-platform': bad['required_assets']=[a for a in bad['required_assets'] if a['target']==targets[0]]
    elif change=='format': bad['required_assets'][0]['archive_format']='exe'
    else: bad['fallback']=True
    path=save(work/('bad-'+change+'.json'),bad)
    describe(path,4)
    p=verify(contract_path=path,expected=4,label='invalid contract '+change)
    check('invalid '+change+' emits no success',not p.stdout)
duplicates=work/'duplicate-keys.json';duplicates.write_text('{"schema_version":1,"schema_version":1,"required_assets":[]}\n')
describe(duplicates,4)
symlink=work/'linked.json';symlink.symlink_to(contract_file);describe(symlink,4)
fifo=work/'fifo';os.mkfifo(fifo);describe(fifo,4)
# Maximum contracts exceed one argument on common POSIX systems. Normalizing
# and attaching them must use files, not a large --argjson exec argument.
large=copy.deepcopy(contract);large['required_assets']=[];large['required_variants']=[]
for n in range(256):
    platform=['windows/amd64','windows/arm64'][n%2];triple=('t%03d-'%n)+'x'*123
    large['required_assets'].append(dict(name=('a%03d-'%n)+'y'*123,target=platform,target_triple=triple,archive_format='binary'))
    large['required_variants'].append(dict(target=platform,target_triple=triple))
p=describe(save(work/'large.json',large),selected_targets=['windows/amd64','windows/arm64'])
if p.returncode==0: check('maximum bounded contract survives large canonical representation',len(p.stdout)>131072 and len(json.loads(p.stdout)['contract']['required_assets'])==256)

# Exercise remote verify/fetch and publish preflight through production code.
# These callbacks replace HTTP/GitHub only, recording every acquisition by ID.
driver=work/'remote-driver.sh'
driver.write_text('''#!/usr/bin/env bash
set -uo pipefail
source "$1/src/slsa.sh"; source "$2"; shift 2
_sbr_require() { :; }
_sbr_run() { "$@"; }
_sbr_context() { printf 'context\\n' >> "$DSR_CONTRACT_TEST/events"; cat "$DSR_CONTRACT_TEST/context.json"; }
_sbr_inventory() { printf 'inventory\\n' >> "$DSR_CONTRACT_TEST/events"; cat "$DSR_CONTRACT_TEST/inventory.json"; }
_sbr_named_asset() { jq -ce --arg n "$2" '[.[]|select(.name==$n)]|if length==1 then .[0] else error("ambiguous asset") end' <<< "$1"; }
_sbr_payload_names() { jq -c '[.[]|select(.name!="release.intoto.jsonl" and .name!="release.intoto.jsonl.minisig")|.name]|sort' <<< "$1"; }
_sbr_asset_digest() { [[ "$(jq -r .digest <<< "$1")" == "sha256:$2" ]]; }
gh_download_release_asset() { printf 'download:%s\\n' "$2" >> "$DSR_CONTRACT_TEST/events"; cp -- "$DSR_CONTRACT_TEST/remote/$2" "$3"; }
_sbr_download() { local file="$4/payload-$(jq -r .id <<< "$2")"; gh_download_release_asset "$1" "$(jq -r .id <<< "$2")" "$file" || return 8; [[ "$(_slsa_sha256 "$file")" == "$3" ]] || return 7; printf '%s\\n' "$file"; }
_sbr_inventory_sha256() { printf '%s' "$1" | sha256sum | cut -d ' ' -f 1; }
case "$1" in
verify) shift; slsa_verify_remote "$@";;
fetch) shift; slsa_fetch_release "$@";;
publish) shift; slsa_publish_release "$@";;
esac
''')
remote=work/'remote';remote.mkdir()
save(work/'context.json',dict(repository=dict(full_name=repo,id=12),release=dict(id=34,tag_name=tag,draft=False),tag_commit=pin))
def remote_snapshot(directory):
    inventory=[]
    for n,p in enumerate([directory/'release.intoto.jsonl',directory/'release.intoto.jsonl.minisig',*sorted((directory/'artifacts').iterdir())],1):
        # Preserve the prior acquisition fixtures instead of replacing them.
        asset_id=calls*1000+n
        shutil.copy2(p,remote/str(asset_id))
        inventory.append(dict(id=asset_id,name=p.name,size=p.stat().st_size,state='uploaded',digest='sha256:'+sha(p)))
    save(work/'inventory.json',inventory)
    (work/'events').write_text('')
    return {a['id'] for a in inventory if not a['name'].startswith('release.intoto')}
def remote_run(action='verify', expected=0, directory=snapshot, selected_contract=contract_file,extra_env=None):
    payload_ids=remote_snapshot(directory)
    output=work/('fetched-%d'%calls)
    args=([proof,assets,'--dry-run'] if action=='publish' else ['--output-dir',output] if action=='fetch' else [])
    p=invoke(['bash',driver,root,module,action,*args,*policy,'--release-contract',selected_contract],expected,'remote '+action,extra_env)
    return p,output,payload_ids
p,fetched,payload_ids=remote_run('fetch')
if p.returncode==0:
    value=json.loads(p.stdout)
    check('fetch observation binds the independent contract',value['verification'].get('release_contract_sha256')==expected_hash)
    check('complete authenticated snapshot is atomically published',fetched.is_dir() and len(list((fetched/'artifacts').iterdir()))==5)
    verify(fetched,label='offline reauthentication of contracted fetch')
    check('fetch downloads every named payload by immutable fixture ID',all('download:'+str(i) in (work/'events').read_text() for i in payload_ids))
p,_,_=remote_run('publish')
check('publication dry-run contract checks never contact remote boundary',not (work/'events').read_text())
p,output,payload_ids=remote_run('fetch',7,work/'missing-variant')
check('signed missing variant refuses before payload acquisition',not any('download:'+str(i) in (work/'events').read_text() for i in payload_ids))
check('failed exact-contract fetch exposes no snapshot or success',not output.exists() and not p.stdout)
if fixture:
    mutable=save(work/'mutable.json',contract)
    p,output,_=remote_run('fetch',7,selected_contract=mutable,extra_env={'DSR_CONTRACT_MUTATE':str(mutable)})
    check('changed caller contract cannot publish an authenticated snapshot',not output.exists() and not p.stdout)
# A mismatching contract cannot compensate for a bad signer.
wrong=work/'bad-signature';shutil.copytree(snapshot,wrong)
(wrong/'release.intoto.jsonl.minisig').write_text('not a signature\n')
verify(wrong,expected=1,label='signature failure remains terminal')
summary=dict(passed=passed,failed=failed,signer='fixture' if fixture else 'minisign',remote_transport='local callback fixtures',work=str(work))
save(work/'summary.json',summary)
# Do not distribute ephemeral private signing keys as validation evidence.
if secret.exists(): secret.rename(work.parent/(work.name+'-private-test-key'))
print('Results: %d passed, %d failed\nEvidence: %s'%(passed,failed,work),flush=True)
sys.exit(1 if failed else 0)
PY
