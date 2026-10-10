#!/usr/bin/env bash
# Actual coordinator, immutable imports and collector over owned local files.
# As in test_release_builds.sh, DSR/xwin compilation is replaced ONLY at the
# driver executable paths of an isolated installation. No native proof claimed.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 jq flock timeout sha256sum; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
python3 - "${RELEASE_BUILDS_TEST_ROOT:-$ROOT}" <<'PY'
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
work = Path(tempfile.mkdtemp(prefix='dsr-build-variants-'))
print('Retained evidence: ' + str(work), flush=True)
passed, calls = 0, 0
pin = '1' * 40

def check(label, ok):
    global passed
    if not ok:
        raise AssertionError(label)
    passed += 1
    print('PASS ' + label, flush=True)

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def write(p, value):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value, sort_keys=True) + '\n')
    return p

def read(p):
    return json.loads(p.read_text())

runtime = work / 'runtime'
(runtime / 'src').mkdir(parents=True)
(runtime / 'scripts').mkdir()
for filename in ('release_builds.sh', 'release_bundle.sh', 'slsa.sh'):
    shutil.copy2(root / 'src' / filename, runtime / 'src' / filename)
(runtime / 'dsr').write_text('#!/usr/bin/env bash\nexec python3 "${0%/*}/driver.py" dsr "$@"\n')
(runtime / 'scripts/xwin-build.sh').write_text('#!/usr/bin/env bash\nexec python3 "${0%/*}/../driver.py" xwin "$@"\n')
(runtime / 'driver.py').write_text(r'''
import hashlib, json, os, sys
from pathlib import Path
kind, args = sys.argv[1], sys.argv[2:]
def arg(k): return args[args.index(k)+1]
if kind == 'dsr':
    assert args[:3] == ['--json', '--non-interactive', 'build']
    assert not any(a in args for a in ['--allow-dirty', '--no-sync', '--no-manifest'])
    cfg = Path(os.environ['DSR_CONFIG_DIR'])
    assert os.environ['DSR_CONFIG_FILE'] == str(cfg/'config.yaml')
    assert os.environ['DSR_REPOS_FILE'] == str(cfg/'repos.yaml')
    assert os.environ['DSR_HOSTS_FILE'] == str(cfg/'hosts.yaml')
    spec = json.loads((cfg/'config.yaml').read_text())
    assert arg('--targets') == spec['platform']
    assert arg('--tool') == 'app' and arg('--version') == 'v1.2.3'
    output = Path(arg('--output-dir'))
    manifest = output/'app-v1.2.3-manifest.json'
else:
    spec = json.loads(Path(arg('--manifest')).read_text())
    assert arg('--bin') == 'app' and arg('--asset-name') == 'app-win.exe'
    assert arg('--release-repo') == 'example/app' and arg('--release-tag') == 'v1.2.3'
    assert arg('--source-sha') == '1'*40 and '--offline' in args
    output = Path(arg('--run-dir'))/'artifacts'
    manifest = output.parent/'release/build-manifest.json'
trace = Path(spec['trace'])
with trace.open('a') as f:
    f.write(json.dumps({'job': spec['job'], 'args': args, 'output': str(output)})+'\n')
mode = Path(spec['control']).read_text().strip()
if mode == 'fail':
    sys.exit(6)
output.mkdir(parents=True)
value = json.loads(Path(spec['template']).read_text())
for a in value['artifacts']:
    source = Path(spec['payloads'])/a['name']
    if mode != 'missing-payload':
        (output/a['name']).write_bytes(source.read_bytes())
if mode == 'wrong-variant':
    value['artifacts'][0]['target_triple'] = 'x86_64-unknown-linux-wrong'
if mode == 'wrong-source':
    value['source']['git_sha'] = '2'*40
if mode == 'wrong-method':
    value['build_environments'][0]['method'] = 'act'
manifest.parent.mkdir(parents=True, exist_ok=True)
manifest.write_text(json.dumps(value, sort_keys=True)+'\n')
if kind == 'dsr':
    response = {'command':'build','status':'success','exit_code':0,'details':{'manifest':str(manifest)}}
else:
    response = {'kind':'dsr-xwin-build','status':'verified','exit_code':0,'target':spec['target'],
                'release_manifest':{'path':str(manifest),'sha256':hashlib.sha256(manifest.read_bytes()).hexdigest()}}
print(json.dumps(response))
''')

def run(plan, output, expected=0, dry=False):
    global calls
    calls += 1
    cmd = ['bash', str(runtime/'src/release_builds.sh'), '--plan', str(plan),
           '--output-dir', str(output), '--jobs', '3'] + (['--dry-run'] if dry else [])
    p = subprocess.run(cmd, capture_output=True, timeout=60)
    (work / ('call-%03d.stdout' % calls)).write_bytes(p.stdout)
    (work / ('call-%03d.stderr' % calls)).write_bytes(p.stderr)
    if p.returncode != expected:
        raise AssertionError(f'expected {expected}, got {p.returncode}: {p.stdout!r}\n{p.stderr.decode()}')
    result = json.loads(p.stdout)
    check('one coordinator envelope agrees with its process exit', result['exit_code'] == expected)
    if expected:
        check('unsuccessful matrix is not publishable', result['publishable'] is False)
    return result

def fixture(base, arch, drivers=False):
    platform = 'linux/' + arch
    cpu = 'x86_64' if arch == 'amd64' else 'aarch64'
    win_platform = 'windows/arm64' if arch == 'amd64' else 'windows/amd64'
    win_triple = 'aarch64-pc-windows-msvc' if arch == 'amd64' else 'x86_64-pc-windows-msvc'
    jobs, required, assets = [], [], []
    for identity, target, triple in [('gnu',platform,cpu+'-unknown-linux-gnu'),
                                     ('musl',platform,cpu+'-unknown-linux-musl'),
                                     ('win',win_platform,win_triple)]:
        directory = base / identity
        directory.mkdir(parents=True)
        names = ['app-'+identity] if identity != 'win' else ['app-win.exe']
        if identity == 'gnu':
            names.append('app-primary-alias')
        rows = []
        for n in names:
            payload = directory / n
            payload.write_bytes(('Owned fixture bytes for '+triple+'\n').encode())
            rows.append(dict(name=n,target=target,target_triple=triple,archive_format='binary',
                             sha256=sha(payload),size_bytes=payload.stat().st_size))
        env = dict(target=target,target_triple=triple,method='native',host='fixture',
                   build_influence_env={'CARGO_BUILD_TARGET':triple,'DSR_TARGET_TRIPLE':triple,
                                        'DSR_RELEASE_GIT_SHA':pin,'DSR_RELEASE_GIT_REF':'v1.2.3'})
        if identity == 'win':
            env = dict(target=target,target_triple=triple,method='pinned-cargo-xwin',
                       toolchain=dict(target=triple,inputs=dict(target=triple)))
        value = dict(schema_version='1.0.0',tool='app',version='v1.2.3',run_id='12345678-1234-4123-8123-123456789abc',
                     source=dict(git_sha=pin,git_ref='v1.2.3',dependencies=[]),status='success',
                     built_at='2026-10-09T01:02:03Z',summary=dict(total=1,success=1,failed=0),
                     build_purpose='release',publishable=True,requested_targets=[target],
                     artifacts=rows,build_environments=[env])
        manifest = write(directory/'manifest.json',value)
        variant = dict(target=target,target_triple=triple)
        job = dict(id=identity,driver='import',targets=[target],variants=[variant],
                   manifest=str(manifest),manifest_sha256=sha(manifest),artifacts_dir=str(directory))
        if drivers:
            control = base/(identity+'-control')
            control.write_text('ready\n')
            spec = dict(job=identity,platform=target,target=triple,trace=str(base/'trace.jsonl'),
                        control=str(control),template=str(manifest),payloads=str(directory))
            job = dict(id=identity,targets=[target],variants=[variant],timeout=10)
            if identity != 'win':
                cfg = base/('config-'+identity)
                write(cfg/'config.yaml',spec)
                write(cfg/'repos.yaml',{})
                write(cfg/'hosts.yaml',{})
                job.update(driver='dsr',config_dir=str(cfg),
                           config_files={n:sha(cfg/n) for n in ('config.yaml','repos.yaml','hosts.yaml')})
            else:
                toolchain = write(base/'toolchain.json',spec)
                job.update(driver='xwin',project=str(base),toolchain_manifest=str(toolchain),
                           toolchain_sha256=sha(toolchain),binary='app',asset_name='app-win.exe',offline=True)
        jobs.append(job)
        required.append(variant)
        assets += [{k:r[k] for k in ('name','target','target_triple','archive_format')} for r in rows]
    plan = dict(schema_version=1,repo='example/app',tool='app',tag='v1.2.3',source_sha=pin,
                required_targets=[platform,win_platform],required_variants=required,required_assets=assets,builds=jobs)
    return write(base/'plan.json',plan)

for arch in ('amd64','arm64'):
    base = work/('imports-'+arch)
    plan = fixture(base,arch)
    output = base/'builds'
    preview = run(plan,output,dry=True)
    check(arch+' explicit ABI plan is canonical and does not start work', not output.exists() and
          preview['plan']['required_variants'] == sorted(read(plan)['required_variants'],key=lambda v:(v['target'],v['target_triple'])))
    (base/'musl').rename(base/'musl-held')
    pending = run(plan,output,1)
    check(arch+' missing musl retains independent GNU and xwin checkpoints',
          pending['failed_builds']==['musl'] and pending['completed_builds']==2 and
          not (output/'build-set.json').exists() and not (output/'bundle/release').exists())
    native_pin = sha(output/'completed/gnu/build-manifest.json')
    (base/'gnu').rename(base/'gnu-offline')
    (base/'win').rename(base/'win-offline')
    (base/'musl-held').rename(base/'musl')
    result = run(plan,output)
    build_set = read(output/'build-set.json')
    aggregate = read(Path(result['bundle']['manifest']))
    check(arch+' build-set preserves every job variant and public-name binding',
          build_set['required_variants']==preview['plan']['required_variants'] and
          build_set['required_assets']==preview['plan']['required_assets'] and all('variants' in j for j in build_set['builds']))
    check(arch+' final summary counts compiler tasks rather than platforms or aliases',
          aggregate['summary']==dict(total=3,success=3,failed=0) and len(aggregate['artifacts'])==4)
    check(arch+' retained producer receipt stays byte-identical through recovery',sha(output/'completed/gnu/build-manifest.json')==native_pin)
    first = sha(Path(result['bundle']['manifest']))
    state = read(output/'state.json')
    check(arch+' only unavailable input receives another attempt',
          {k:len(v['attempts']) for k,v in state['jobs'].items()}==dict(gnu=1,musl=2,win=1))
    reordered = copy.deepcopy(read(plan))
    for key in ('required_targets','required_variants','required_assets','builds'):
        reordered[key].reverse()
    again = run(write(base/'reordered.json',reordered),output)
    check(arch+' reordered retry preserves frozen plan and aggregate hashes',
          again['plan_sha256']==result['plan_sha256'] and sha(Path(again['bundle']['manifest']))==first)
    tampered = base/'tampered'
    shutil.copytree(output,tampered)
    changed = read(tampered/'state.json')
    changed['jobs']['gnu']['complete']['variants'] = changed['jobs']['musl']['complete']['variants']
    write(tampered/'state.json',changed)
    run(plan,tampered,2)
    check(arch+' altered completed variant cannot be re-adopted',sha(Path(result['bundle']['manifest']))==first)

base = work/'drivers'
plan = fixture(base,'amd64',drivers=True)
(base/'musl-control').write_text('fail\n')
output = base/'builds'
run(plan,output,1)
check('actual scheduler retains successful DSR/xwin driver outputs after one job fails',
      (output/'completed/gnu/build-manifest.json').is_file() and (output/'completed/win/build-manifest.json').is_file())
first_attempt = (output/'attempts/musl/000001/stderr.log').read_bytes()
(base/'musl-control').write_text('ready\n')
completed = run(plan,output)
trace = [json.loads(line) for line in (base/'trace.jsonl').read_text().splitlines()]
check('retry executes only failed driver, not completed GNU or Windows jobs',
      {n:sum(t['job']==n for t in trace) for n in ('gnu','musl','win')}==dict(gnu=1,musl=2,win=1))
check('failed attempt evidence is not overwritten by retry',
      (output/'attempts/musl/000001/stderr.log').read_bytes()==first_attempt and (output/'attempts/musl/000002/command.json').is_file())
check('native jobs retain separate pinned configurations and state directories',
      read(output/'attempts/gnu/000001/config/config.yaml')['job']=='gnu' and
      read(output/'attempts/musl/000002/config/config.yaml')['job']=='musl')
check('pinned xwin evidence is not relabeled as native execution',
      read(output/'completed/win/build-manifest.json')['build_environments'][0]['method']=='pinned-cargo-xwin')

for mutation in ('no-global','null-global','empty-global','duplicate-global','missing-global','missing-job','null-job',
                 'duplicate-job','foreign-asset','unsafe-triple','wrong-xwin','wrong-platform','extra-field'):
    candidate = copy.deepcopy(read(plan))
    if mutation=='no-global': candidate.pop('required_variants')
    elif mutation=='null-global': candidate['required_variants']=None
    elif mutation=='empty-global': candidate['required_variants']=[]
    elif mutation=='duplicate-global': candidate['required_variants'].append(candidate['required_variants'][0])
    elif mutation=='missing-global': candidate['required_variants'].pop(0)
    elif mutation=='missing-job': candidate['builds'][0].pop('variants')
    elif mutation=='null-job': candidate['builds'][0]['variants']=None
    elif mutation=='duplicate-job': candidate['builds'][1]['variants']=candidate['builds'][0]['variants']
    elif mutation=='foreign-asset': candidate['required_assets'][0]['target_triple']='aarch64-unknown-linux-gnu'
    elif mutation=='unsafe-triple': candidate['required_variants'][0]['target_triple']='../gnu'
    elif mutation=='wrong-xwin': candidate['builds'][2]['variants'][0]['target_triple']='x86_64-pc-windows-msvc'
    elif mutation=='wrong-platform': candidate['builds'][0]['variants'][0]['target']='darwin/arm64'
    else: candidate['builds'][0]['variants'][0]['unbound']=True
    p=write(base/(mutation+'.json'),candidate)
    run(p,base/mutation,4,dry=True)
    check(mutation+' is refused before starting any driver or creating state',not (base/mutation).exists())

legacy_base=work/'legacy'
legacy=fixture(legacy_base,'amd64')
value=read(legacy)
value.pop('required_variants')
value['builds']=[value['builds'][0],value['builds'][2]]
for j in value['builds']: j.pop('variants')
value['required_assets']=[{k:v for k,v in a.items() if k!='target_triple'}
                          for a in value['required_assets'] if a['name']!='app-musl']
legacy=write(legacy_base/'legacy.json',value)
result=run(legacy,legacy_base/'builds')
check('legacy platform-partitioned build sets keep the old shape',
      'required_variants' not in read(Path(result['build_set'])) and
      all('variants' not in b for b in read(Path(result['build_set']))['builds']))
print(f'Results: {passed} passed, 0 failed\nEvidence: {work}',flush=True)
PY
