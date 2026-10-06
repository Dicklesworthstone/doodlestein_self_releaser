#!/usr/bin/env bash
# GH #28: real native manifest/staging, retained receipts and Minisign checks.
# Only GitHub's tag/asset transport uses file-backed fixtures; no publication.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 bash git jq yq cc tar minisign; do
    command -v "$tool" >/dev/null || { printf 'Missing required dependency: %s\n' "$tool" >&2; exit 3; }
done
python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
os.umask(0o077)
work = Path(tempfile.mkdtemp(prefix='dsr-legacy-aggregate-'))
print('Retained test workspace: ' + str(work), flush=True)
checks = 0

def check(label, value):
    global checks
    if not value:
        raise AssertionError(label)
    checks += 1
    print('PASS ' + label, flush=True)

def run(argv, **kwargs):
    return subprocess.run(list(map(str, argv)), capture_output=True, check=True, timeout=90, **kwargs)

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def dump(p, value):
    p.write_text(json.dumps(value))

# Match the existing strict-finalization test's production-function boundary.
# No implementation is copied into this test, and the CLI is never executed.
source = (root / 'dsr').read_text()
functions = work / 'release-functions.sh'
names = re.findall(r'^(_release_[A-Za-z0-9_]+)\(\) \{', source, re.M)
functions.write_text('\n'.join(re.search(r'^' + re.escape(n) + r'\(\) \{\n.*?^\}', source, re.M | re.S).group(0) for n in names))
repo = work / 'repo'
repo.mkdir()
(repo / 'README.md').write_text('Exact tagged aggregate fixture.\n')
(repo / 'probe.c').write_text('int main(void) { return 0; }\n')
run(['minisign','-G','-W','-p',repo / 'minisign.pub','-s',work / 'signing.key'])
for args in (['init','-q'], ['config','user.name','DSR fixture'], ['config','user.email','dsr@example.invalid'],
             ['add','.'], ['commit','-qm','exact source'], ['tag','-a','v1.2.3','-m','fixture'],
             ['remote','add','origin','https://github.com/owner/app.git']):
    run(['git','-C',repo,*args])
revision = run(['git','-C',repo,'rev-parse','HEAD']).stdout.decode().strip()
arch = {'x86_64':'amd64','amd64':'amd64','aarch64':'arm64','arm64':'arm64'}.get(platform.machine().lower())
os_name = {'Linux':'linux','Darwin':'darwin'}.get(platform.system())
check('supported native compiler host', arch is not None and os_name is not None)
target = os_name + '/' + arch
built = work / 'compiler/app'
built.parent.mkdir()
run(['cc',repo / 'probe.c','-o',built])
run([built])
for directory in ('config/repos.d','cache','state','collected','publication','remote'):
    (work / directory).mkdir(parents=True)
contract = dict(checksum_sidecar='sha256', minisign_public_key_file='minisign.pub',
                exact_primary_assets={target:'app.tar.gz'},
                exact_additional_assets=['SHA256SUMS','SHA256SUMS.minisig','SHA256SUMS.txt','SHA256SUMS.txt.minisig',
                                         'checksums.txt','checksums.txt.minisig','NOTICE'])
dump(work / 'config/repos.d/app.yaml', dict(tool_name='app', repo='owner/app', local_path=str(repo), binary_name='app',
     language='c', targets=[target], workspace_additional_artifacts={target:['NOTICE']}, release_contract=contract))
env = dict(os.environ, ROOT=str(root), CASE=str(work), FUNCTIONS=str(functions), SOURCE_SHA=revision,
           TARGET=target, DSR_CONFIG_DIR=str(work / 'config'), DSR_CACHE_DIR=str(work / 'cache'),
           DSR_STATE_DIR=str(work / 'state'), SIGNING_PRIVATE_KEY=str(work / 'signing.key'),
           DSR_MINISIGN_KEY=str(work / 'signing.key'), NO_COLOR='1')
script = r'''
set -uo pipefail
source "$ROOT/src/github.sh" || exit $?
source "$ROOT/src/config.sh" || exit $?
source "$ROOT/src/git_ops.sh" || exit $?
source "$ROOT/src/act_runner.sh" || exit $?
source "$ROOT/src/signing.sh" || exit $?
source "$FUNCTIONS" || exit $?
log_error() { printf 'ERROR %s\n' "$*" >&2; }
log_info() { printf 'INFO %s\n' "$*" >&2; }
log_ok() { log_info "$@"; }
log_warn() { log_info "$@"; }
# Explicit transport fixtures: all local source, byte and signature gates run.
gh_resolve_tag_sha() { [[ "$1" == owner/app && "$2" == v1.2.3 ]] && printf '%s\n' "$SOURCE_SHA"; }
gh_api() { [[ "$1" == repos/owner/app/releases/9 && "$2" == --no-cache ]] && cat "$CASE/remote.json"; }
gh_download_release_asset() { [[ "$1" == owner/app && ! -e "$3" ]] && cp "$CASE/remote/$2" "$3"; }
act_load_repo_config app >&2 || exit $?
contract=$(config_get_release_contract_json app) || exit $?
case "$1" in
  manifest)
    receipt=$(_act_collect_stream_exclusive "$CASE/collected/app" 700 _act_stream_local_file "$CASE/compiler/app") || exit $?
    result=$(jq -nc --arg target "$TARGET" --argjson receipt "$receipt" '
      {status:"success",exit_code:0,platform:$target,method:"native",host:"fixture",build_purpose:"release",publishable:true,
       artifact_path:$receipt.path,artifact_paths:[$receipt.path],collected_sha256:$receipt.sha256,
       collected_size_bytes:$receipt.size_bytes,collected_identity:$receipt.identity}') || exit $?
    result=$(_act_stage_contract_primary app v1.2.3 12345678-1234-4123-8123-123456789abc "$TARGET" "$result" "$contract") || exit $?
    additional=$(_act_collect_stream_exclusive "$CASE/collected/NOTICE" 600 _act_stream_local_file "$CASE/repo/README.md") || exit $?
    result=$(jq -c --argjson additional "$additional" '. + {additional_artifacts:[$additional]}' <<< "$result") || exit $?
    receipts=$(_act_result_artifact_receipts "$result") || exit $?
    result=$(jq -c --argjson receipts "$receipts" '. + {resume_artifacts:$receipts}' <<< "$result") || exit $?
    printf '%s\n' "$result" > "$CASE/target-result.json"
    orchestration=$(jq -nc --arg sha "$SOURCE_SHA" --arg target "$TARGET" --argjson result "$result" '
      {tool:"app",version:"v1.2.3",run_id:"12345678-1234-4123-8123-123456789abc",git_sha:$sha,git_ref:"v1.2.3",
       source_dependencies:[],status:"success",summary:{total:1,success:1,failed:0},targets:[$result],
       build_purpose:"release",publishable:true,requested_targets:[$target]}') || exit $?
    act_generate_manifest "$orchestration" "$CASE/publication/app-v1.2.3-manifest.json" || exit $?
    cp "$(jq -r .artifact_path <<< "$result")" "$CASE/publication/app.tar.gz" || exit $?
    cp "$CASE/collected/NOTICE" "$CASE/publication/NOTICE" || exit $?
    ;;
  resume)
    result=$(cat "$CASE/target-result.json") || exit $?
    _act_target_result_available "$result" release true || exit $?
    ;;
  remote)
    _release_contract_verify_remote_assets owner/app 9 "$(jq -c .assets "$CASE/plan.json")" true v1.2.3
    ;;
  diagnostic)
    _act_contract_for_build_purpose app "$contract" "$(jq -nc --arg target "$TARGET" '[$target]')" diagnostic-native
    ;;
  *)
    _release_contract_preflight app v1.2.3 owner/app "$CASE/repo" "$CASE/publication" \
      "$CASE/publication/app-v1.2.3-manifest.json" "$contract" "$1"
    ;;
esac
'''

def invoke(mode, expected=0):
    result = subprocess.run(['bash','-c',script,'fixture',mode], env=env, capture_output=True, timeout=90)
    (work / ('last-' + mode + '.log')).write_bytes(result.stdout + result.stderr)
    if result.returncode != expected:
        print(result.stdout.decode(errors='replace') + result.stderr.decode(errors='replace'),file=sys.stderr)
    check(mode + ' returns ' + str(expected), result.returncode == expected)
    return result

invoke('manifest')
manifest_path = work / 'publication/app-v1.2.3-manifest.json'
manifest = json.loads(manifest_path.read_text())
check('native successful manifest contains only producer-owned payloads', [a['name'] for a in manifest['artifacts']] == ['app.tar.gz','NOTICE'])
check('native manifest keeps exact successful source and target evidence', manifest['source']['git_sha'] == revision and manifest['requested_targets'] == [target])
projection = json.loads(invoke('diagnostic').stdout)
check('derived aggregates never become native diagnostic target ownership', projection['exact_additional_assets'] == ['NOTICE'])
invoke('resume')
receipt = work / 'target-result.json'
original_receipt = receipt.read_bytes()
manifest_before = manifest_path.read_bytes()
plan = json.loads(invoke('create').stdout)
dump(work / 'plan.json',plan)
aggregates = [a for a in plan['assets'] if a['kind'] == 'aggregate-checksum']
check('all three exact conventional basenames are derived', {a['name'] for a in aggregates} == {'SHA256SUMS','SHA256SUMS.txt','checksums.txt'})
expected = (''.join(sorted(sha(work / 'publication' / name) + '  ' + name + '\n' for name in ('app.tar.gz','NOTICE')))).encode()
check('legacy and modern aggregates have identical canonical bytes', all(Path(a['path']).read_bytes() == expected for a in aggregates))
check('every aggregate signature covers those exact bytes', all(any(s['kind'] == 'minisign' and s['name'] == a['name']+'.minisig' and s['source_sha256'] == a['sha256'] for s in plan['assets']) for a in aggregates))
originals = {p.name:(p.read_bytes(),p.stat().st_ino,p.stat().st_mtime_ns) for p in (work / 'publication').iterdir()}
invoke('verify')
invoke('create')
invoke('resume')
check('verification and retry never rewrite completed artifacts or receipts',
      receipt.read_bytes() == original_receipt and manifest_path.read_bytes() == manifest_before and
      all((p.read_bytes(),p.stat().st_ino,p.stat().st_mtime_ns) == originals[p.name] for p in (work / 'publication').iterdir()))
# Signed remote byte verification uses actual Minisign with fixture downloads.
remote = dict(id=9,tag_name='v1.2.3',draft=True,prerelease=False,name='v1.2.3',body='fixture',assets=[])
for identifier,a in enumerate(plan['assets'],100):
    shutil.copyfile(a['path'],work / 'remote' / str(identifier))
    remote['assets'].append(dict(id=identifier,name=a['name'],state='uploaded',size=a['size_bytes'],digest='sha256:'+a['sha256']))
dump(work / 'remote.json',remote)
invoke('remote')
legacy = work / 'publication/checksums.txt'
signature = work / 'publication/checksums.txt.minisig'
for file in (legacy,signature):
    original = file.read_bytes()
    file.write_bytes(b'wrong pre-existing bytes\n')
    invoke('verify',4)
    invoke('create',4)
    check('invalid ' + file.name + ' is not silently repaired', file.read_bytes() == b'wrong pre-existing bytes\n')
    file.write_bytes(original)
held = work / 'held-legacy-aggregate'
legacy.rename(held)
legacy.symlink_to(held)
invoke('verify',4)
invoke('create',4)
check('linked legacy aggregate stays untouched', legacy.is_symlink() and held.read_bytes() == expected)
legacy.rename(work / 'held-legacy-link')
held.rename(legacy)
legacy_remote = next(a for a in remote['assets'] if a['name'] == 'checksums.txt')
remote_bytes = work / 'remote' / str(legacy_remote['id'])
remote_original = remote_bytes.read_bytes()
remote_bytes.write_bytes(b'wrong remote aggregate\n')
invoke('remote',1)
remote_bytes.write_bytes(remote_original)
invoke('remote')
check('no aggregate is manufactured as a native producer receipt', [Path(a['path']).name for a in json.loads(receipt.read_text())['additional_artifacts']] == ['NOTICE'])
# Conventional aggregate matching is exact: an unrelated payload with a similar
# prefix still needs target ownership and a manifest-bound producer receipt.
config_path = work / 'config/repos.d/app.yaml'
config = json.loads(config_path.read_text())
config['release_contract']['exact_additional_assets'].append('SHA256SUMS.NOTICE')
dump(config_path, config)
invoke('diagnostic', 4)
invoke('verify', 4)
check('unrecognized checksum-prefix payload is never manufactured', not (work / 'publication/SHA256SUMS.NOTICE').exists())
print(f'Legacy aggregate integration: {checks} assertions passed; real local signatures, fixture GitHub transport.',flush=True)
PY
