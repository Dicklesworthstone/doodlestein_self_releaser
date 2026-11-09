#!/usr/bin/env bash
# Production collector + manifest + final-byte gate. Compiler/host metadata is
# a fixture; these payloads test custody/naming, not native execution or ABI.
# shellcheck disable=SC1090,SC2034 # Extracted production functions consume fixture variables through Bash dynamic scope.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# Full build-command regressions use a controlled producer/scheduler boundary.
# Config parsing, receipts, collection, packaging, final byte admission and
# publication/checkpoint writes are real. Tiny host ELF executables are compiled
# with cc; the fixture does not claim native Go/Rust or GNU/musl qualification.
test_companion_packaging() {
    python3 - "$ROOT" "${DSR_TEST_COMMAND_FILE:-$ROOT/dsr}" <<'PY'
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile

root, command_file = map(Path, sys.argv[1:])
for dependency in ('bash', 'cc', 'git', 'jq', 'yq', 'tar', 'gzip', 'xz', 'zip', 'unzip'):
    if not shutil.which(dependency):
        raise SystemExit('Companion packaging tests require ' + dependency)
machine = platform.machine()
if platform.system() != 'Linux' or machine not in ('x86_64', 'aarch64'):
    print('SKIP: host ELF companion-packaging fixture requires Linux AMD64 or ARM64')
    raise SystemExit(0)
target = 'linux/' + ('amd64' if machine == 'x86_64' else 'arm64')
triple_arch = 'x86_64' if machine == 'x86_64' else 'aarch64'
triples = [triple_arch + '-unknown-linux-' + libc for libc in ('gnu', 'musl')]
work = Path(tempfile.mkdtemp(prefix='dsr-companion-packaging-'))
print('Companion packaging evidence: ' + str(work), flush=True)
print('Command SHA256: ' + hashlib.sha256(command_file.read_bytes()).hexdigest(), flush=True)
passed = 0
failures = []

def check(label, condition):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print('PASS: ' + label, flush=True)

def run(args, **options):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, timeout=30, **options)

def save(path, value):
    path.write_text(json.dumps(value) + '\n')

source = work / 'source'
source.mkdir()
(source / 'main.c').write_text('#include <stdio.h>\n#ifndef LABEL\n#define LABEL "primary"\n#endif\nint main(void) { puts("rolefixture " LABEL); return 0; }\n')
(source / 'LICENSE').write_text('Fixture license: redistribution permitted.\n')
run(['git', '-C', source, 'init', '-q', '-b', 'main'])
run(['git', '-C', source, 'add', 'main.c', 'LICENSE'])
run(['git', '-C', source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
     '-c', 'commit.gpgsign=false', 'commit', '-qm', 'tiny packaging fixture'])
run(['git', '-C', source, 'tag', 'v1.2.3'])
source_sha = run(['git', '-C', source, 'rev-parse', 'HEAD']).stdout.decode().strip()
binaries = []
for label in ('primary', 'secondary'):
    binary = work / label
    run(['cc', '-O2', '-DLABEL="' + label + '"', source / 'main.c', '-o', binary])
    check('real host ELF runs: ' + label, run([binary]).stdout == ('rolefixture ' + label + '\n').encode())
    binaries.append(binary.read_bytes())

driver = work / 'driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
ROOT="$1" COMMAND_FILE="$2" CASE_ROOT="$3"
export DSR_CONFIG_DIR="$CASE_ROOT/config" DSR_STATE_DIR="$CASE_ROOT/state" DSR_CACHE_DIR="$CASE_ROOT/cache"
export DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml" DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
export DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml" ACT_CONFIG_DIR="$DSR_CONFIG_DIR" ACT_REPOS_DIR="$DSR_CONFIG_DIR/repos.d"
export JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture NO_COLOR=1
export RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1
unset RCH_REQUIRE_REMOTE
for module in logging config build_state act_runner artifact_naming git_ops packaging; do
    source "$ROOT/src/$module.sh" || exit 1
done
source <(awk '/^cmd_build\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$COMMAND_FILE") || exit 1
source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$COMMAND_FILE") || exit 1
_dsr_require() { case "$1" in artifact_naming|packaging) return 0 ;; *) return 3 ;; esac; }
act_check() { return 0; }
act_check_prereqs() { return 0; }
act_orchestrate_build() {
    local tool="$1" version="$2" run='' rows row path receipt additional result task key
    local completed='[]' keys=()
    shift 2
    while (($#)); do
        case "$1" in --run-id) run="$2"; shift 2 ;; --) break ;; *) shift ;; esac
    done
    [[ -n "$run" ]] || return 4
    rows=$(cat "$CASE_ROOT/producer.json") || return 4
    while IFS= read -r key; do keys+=("$key"); done < <(jq -r '.[].task_key' <<< "$rows")
    run=$(DSR_RUN_ID="$run" build_state_create "$tool" "$version" "${keys[@]}") || return 4
    build_state_update_status "$tool" "$version" running "$run" || return 4
    while IFS= read -r row; do
        additional='[]'
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            receipt=$(jq -nc --arg path "$path" --arg sha "$(_act_sha256 "$path")" \
                --argjson size "$(_act_file_size "$path")" --arg identity "$(_act_file_identity "$path")" \
                '{path:$path,sha256:$sha,size_bytes:$size,identity:$identity}') || return 4
            additional=$(jq -c --argjson receipt "$receipt" '. + [$receipt]' <<< "$additional") || return 4
        done < <(jq -r '.additional_paths[]' <<< "$row")
        row=$(jq -c --argjson additional "$additional" 'del(.additional_paths) + {additional_artifacts:$additional}' <<< "$row") || return 4
        row=$(jq -c --argjson receipts "$(_act_result_artifact_receipts "$row")" '. + {resume_artifacts:$receipts}' <<< "$row") || return 4
        completed=$(jq -c --argjson row "$row" '. + [$row]' <<< "$completed") || return 4
        task=$(jq -r '.task_key' <<< "$row") || return 4
        build_state_update_target "$tool" "$version" "$task" completed \
            "$(jq -cn --argjson row "$row" '{result:$row}')" "$run" || return 4
    done < <(jq -c '.[]' <<< "$rows")
    result=$(jq -nc --arg tool "$tool" --arg version "$version" --arg run "$run" \
        --arg sha "$DSR_FIXTURE_SOURCE_SHA" --argjson rows "$completed" \
        '{tool:$tool,version:$version,run_id:$run,status:"success",git_sha:$sha,git_ref:"v1.2.3",
          build_purpose:"release",publishable:true,requested_targets:([$rows[].platform]|unique),
          summary:{total:($rows|length),success:($rows|length),failed:0},targets:$rows}') || return 4
    printf '%s\n' "$result" > "$CASE_ROOT/observed-producer.json" || return 4
    printf '%s\n' "$result"
}
config_load || exit 1
cmd_build rolefixture --version 1.2.3 --no-sync --output-dir "$CASE_ROOT/output"
''')

def archive(path, format, members):
    if format == 'zip':
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as stream:
            for name, data, mode in members:
                item = zipfile.ZipInfo(name)
                item.create_system = 3
                item.external_attr = (stat.S_IFREG | mode) << 16
                stream.writestr(item, data)
    else:
        with tarfile.open(path, 'w:gz' if format == 'tar.gz' else 'w:xz') as stream:
            for name, data, mode in members:
                item = tarfile.TarInfo(name)
                item.size, item.mode, item.mtime = len(data), mode, 1
                stream.addfile(item, io.BytesIO(data))

def contents(path, format):
    if format == 'zip':
        with zipfile.ZipFile(path) as stream:
            return {row.filename: stream.read(row) for row in stream.infolist() if not row.is_dir()}
    with tarfile.open(path) as stream:
        return {row.name: stream.extractfile(row).read() for row in stream.getmembers() if row.isfile()}

def exercise(label, desired='tar.gz', primary_format=None, matrix=False, missing=False, corrupt=False,
             includes=False, companion_role=None, alternate_primary=False, same_bytes=False):
    base = work / label
    (base / 'config/repos.d').mkdir(parents=True)
    producer = base / 'producer'
    producer.mkdir()
    save(base / 'config/config.yaml', {'schema_version': '1.0.0'})
    save(base / 'config/repos.yaml', {'tools': {}})
    save(base / 'config/hosts.yaml', {'schema_version': '1.0.0', 'hosts': {}})
    companion_format = 'tar.gz' if desired == 'binary' else desired
    companion_name = 'documentation.' + companion_format
    if companion_role:
        suffix = triples[1] if companion_role.startswith('secondary-') else target.replace('/','-')
        versioned = 'versioned' in companion_role
        companion_name = 'rolefixture-' + ('1.2.3-' if versioned else '') + suffix + ('' if desired=='binary' else '.'+desired)
        if companion_role.startswith('case-'):
            companion_name = companion_name.upper()
    companion = producer / companion_name
    archive(companion, companion_format, [('README.txt', b'Companion documentation without an executable.\n', 0o644)])
    companion_bytes = companion.read_bytes()
    config = dict(tool_name='rolefixture', repo='example/rolefixture', local_path=str(source), language='go',
                  binary_name='rolefixture', build_cmd='cc main.c -o rolefixture', targets=[target], act_job_map={target: None},
                  artifact_naming='${name}-${version}-' + ('${target_triple}' if matrix else '${os}-${arch}'),
                  install_script_compat='${name}-' + ('${target_triple}' if matrix else '${os}-${arch}'),
                  archive_format={'linux': desired}, workspace_additional_artifacts={target:[dict(name=companion.name,format=companion_format)]})
    if matrix:
        config['target_triples'] = {target: triples}
    if includes:
        config['include_files'] = ['LICENSE']
    save(base / 'config/repos.d/rolefixture.yaml', config)
    rows, original_primaries = [], []
    for index, triple in enumerate(triples if matrix else ['']):
        directory = producer / str(index)
        directory.mkdir()
        primary = directory / ('rolefixture-1.2.3-' + target.replace('/', '-') + '.' + primary_format if primary_format else 'rolefixture')
        if alternate_primary:
            primary = directory / ('producer.' + primary_format)
        data = binaries[index]
        if not missing:
            if corrupt:
                primary.write_bytes(b'not an archive\n')
            elif primary_format:
                archive(primary, primary_format, [('rolefixture', data, 0o755)])
            else:
                primary.write_bytes(data)
                primary.chmod(0o755)
            original_primaries.append((primary, primary.read_bytes()))
        row = dict(platform=target,method='native',host='fixture',status='success',
                   task_key=target + ('@'+triple if triple else ''),artifact_paths=[] if missing else [str(primary)],
                   additional_paths=[str(companion)] if index==0 else [])
        if triple:
            row['target_triple'] = triple
        rows.append(row)
    if same_bytes:
        companion.write_bytes(original_primaries[0][1])
        companion_bytes = companion.read_bytes()
    save(base / 'producer.json', rows)
    process = subprocess.run(['bash',str(driver),str(root),str(command_file),str(base)], capture_output=True, timeout=60,
                             env=dict(os.environ,DSR_FIXTURE_SOURCE_SHA=source_sha))
    (base / 'stdout.json').write_bytes(process.stdout)
    (base / 'stderr.log').write_bytes(process.stderr)
    (base / 'exit-status').write_text(str(process.returncode) + '\n')
    marker = json.loads((base/'output/.dsr-build-purpose.json').read_bytes())
    states = list((base/'state/builds/rolefixture').glob('**/state.json'))
    check(label + ': exactly one durable build checkpoint', len(states)==1)
    state = json.loads(states[0].read_bytes())
    check(label + ': companion source bytes stay unchanged', companion.read_bytes()==companion_bytes)
    for path, original in original_primaries:
        check(label + ': primary source stays unchanged ' + path.parent.name, path.read_bytes()==original)
    if missing or corrupt or companion_role:
        check(label + ': invalid primary ownership refuses the build', process.returncode!=0)
        check(label + ': failed packaging grants no publication authority', marker['publishable'] is False and state['status']!='completed' and
              not (base/'output/rolefixture-v1.2.3-manifest.json').exists())
        check(label + ': refusal preserves collected companion bytes', (base/'output'/companion.name).read_bytes()==companion_bytes)
        if companion_role:
            check(label + ': refusal identifies the reserved-name conflict', b'collides with a configured additional artifact' in process.stderr)
        return
    check(label + ': build command succeeds', process.returncode==0)
    result = json.loads(process.stdout)
    check(label + ': success envelope and completion marker agree', result['status']=='success' and result['details']['publishable'] is True and
          marker['publishable'] is True and marker['publication_status']=='completed' and state['status']=='completed')
    manifest = json.loads((base/'output/rolefixture-v1.2.3-manifest.json').read_bytes())
    inventory = {row['name']:row for row in manifest['artifacts']}
    check(label + ': literal companion is retained in the final manifest', companion.name in inventory and
          (base/'output'/companion.name).read_bytes()==companion_bytes)
    for index, triple in enumerate(triples if matrix else ['']):
        suffix = triple if matrix else target.replace('/','-')
        extension = '' if desired=='binary' else '.'+desired
        versioned = 'rolefixture-1.2.3-'+suffix+extension
        alias = 'rolefixture-'+suffix+extension
        check(label + ': complete primary naming for ' + suffix, all(name in inventory and (base/'output'/name).is_file() for name in (versioned,alias)))
        actual = (base/'output'/versioned).read_bytes()
        check(label + ': installer alias binds primary bytes for ' + suffix, (base/'output'/alias).read_bytes()==actual)
        if desired=='binary':
            check(label + ': raw primary remains the compiled executable', actual==binaries[index])
        else:
            expected = {'rolefixture':binaries[index]}
            if includes:
                expected['LICENSE']=(source/'LICENSE').read_bytes()
            check(label + ': archive contains the exact primary payload for ' + suffix, contents(base/'output'/versioned,desired)==expected)
            if primary_format==desired and not includes:
                check(label + ': matching prebuilt bytes are preserved', actual==original_primaries[index][1])
        if matrix:
            check(label + ': selected compiler variant stays bound', all(inventory[name]['target']==target and inventory[name]['target_triple']==triple for name in (versioned,alias)))
    check(label + ': every final digest and size matches actual output', all(
        hashlib.sha256((base/'output'/row['name']).read_bytes()).hexdigest()==row['sha256'] and
        (base/'output'/row['name']).stat().st_size==row['size_bytes'] for row in manifest['artifacts']))

cases = [
    ('raw-with-gzip-companion', {}),
    ('raw-with-zip-companion', dict(desired='zip')),
    ('convert-primary-with-gzip-companion', dict(primary_format='tar.xz',includes=True)),
    ('preserve-prebuilt-primary', dict(primary_format='tar.gz')),
    ('raw-binary-primary', dict(desired='binary')),
    ('variant-primary-ownership', dict(matrix=True)),
    ('missing-primary', dict(missing=True)),
    ('corrupt-primary', dict(primary_format='tar.xz',corrupt=True)),
    ('reserved-versioned-archive', dict(companion_role='versioned')),
    ('reserved-versioned-binary', dict(desired='binary',companion_role='versioned')),
    ('reserved-name-ignores-case', dict(companion_role='case-versioned')),
    ('reserved-prebuilt-destination', dict(primary_format='tar.gz',alternate_primary=True,companion_role='versioned')),
    ('reserved-secondary-variant', dict(matrix=True,companion_role='secondary-versioned')),
    ('reserved-identical-alias', dict(primary_format='tar.gz',alternate_primary=True,same_bytes=True,companion_role='compat')),
]
for label, options in cases:
    try:
        exercise(label, **options)
    except (AssertionError, OSError, ValueError, subprocess.SubprocessError, tarfile.TarError, zipfile.BadZipFile) as error:
        failures.append(label)
        print('FAIL: ' + label + ': ' + str(error), file=sys.stderr, flush=True)
print('Companion packaging: %d passed, %d failed cases' % (passed,len(failures)), flush=True)
raise SystemExit(1 if failures else 0)
PY
}

test_large_public_manifest() {
    python3 - "$ROOT" <<'PY'
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

root = Path(sys.argv[1])
for dependency in ('bash', 'jq', 'yq'):
    if not shutil.which(dependency):
        raise SystemExit('Large manifest tests require ' + dependency)
work = Path(tempfile.mkdtemp(prefix='dsr-large-public-manifest-')).resolve()
(work / 'config/repos.d').mkdir(parents=True)
(work / 'payloads').mkdir()
print('Large public manifest evidence: ' + str(work), flush=True)
checks = 0

def check(label, condition):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print('PASS: ' + label, flush=True)

def save(path, value):
    path.write_text(json.dumps(value) + '\n')

save(work / 'config/repos.d/largefiles.yaml', {
    'tool_name': 'largefiles', 'binary_name': 'app', 'targets': ['linux/amd64'],
    'local_path': str(work), 'target_triples': {'linux/amd64': 'x86_64-unknown-linux-gnu'}})
with tarfile.open(work / 'payload.tar.gz', 'w:gz') as archive:
    member = tarfile.TarInfo('app')
    body = b'#!/bin/sh\nexit 0\n'
    member.size, member.mode, member.uid, member.gid = len(body), 0o755, 0, 0
    archive.addfile(member, io.BytesIO(body))
payload = (work / 'payload.tar.gz').read_bytes()
digest = hashlib.sha256(payload).hexdigest()
# These are actual legal filesystem names and real archive bytes, not an
# oversized extension field. They cross argv's limit with a bounded file count.
paths = [work / 'payloads' / ('component-%04d-' % i + 'x' * 205 + '-linux-amd64.tar.gz')
         for i in range(256)]
for path in paths:
    path.write_bytes(payload)
original = {p.name: (p.stat().st_dev, p.stat().st_ino, hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths}
driver = r'''set -uo pipefail
export DSR_CONFIG_DIR="$2/config" DSR_REPOS_FILE="$2/config/repos.yaml" ACT_REPOS_DIR="$2/config/repos.d"
source "$1/src/config.sh" || exit 90
source "$1/src/act_runner.sh" || exit 90
root=$1; shift 2
operation=$1; shift
case "$operation" in
    receipts) _act_result_artifact_receipts "$(cat "$1")" > "$2" ;;
    manifest) act_generate_manifest "$(cat "$1")" "$2" ;;
    collected) _act_verify_collected_manifest "$@" ;;
    admission)
        source "$root/src/slsa.sh" || exit 90
        _slsa_manifest_statement "$1" fixture/largefiles dsr:manifest-fixture > "$2" ;;
    bad-environments)
        _act_build_environments_json() { printf '[]\n[]\n'; }
        act_generate_manifest "$(cat "$1")" "$2" ;;
    *) exit 90 ;;
esac
'''

def invoke(label, operation, *args, input=None):
    started = time.monotonic()
    result = subprocess.run(['bash', '-c', driver, '_', str(root), str(work), operation,
                             *map(str, args)], input=input, capture_output=True, timeout=105)
    (work / (label + '.stdout')).write_bytes(result.stdout)
    (work / (label + '.stderr')).write_bytes(result.stderr)
    print('%s: exit=%d, seconds=%.3f' % (label, result.returncode, time.monotonic() - started), flush=True)
    if result.returncode:
        print(result.stderr.decode(errors='replace')[-1500:], file=sys.stderr, flush=True)
    return result

results = {}
for count in (1, 256):
    row = {'platform': 'linux/amd64', 'host': 'fixture', 'method': 'native',
           'status': 'success', 'artifact_paths': list(map(str, paths[:count]))}
    row_path, receipts_path = work / ('row-%d.json' % count), work / ('receipts-%d.json' % count)
    save(row_path, row)
    captured = invoke('receipts-%d' % count, 'receipts', row_path, receipts_path)
    check('real producer receipt inventory covers %d files' % count,
          captured.returncode == 0 and len(json.loads(receipts_path.read_bytes())) == count)
    row['resume_artifacts'] = json.loads(receipts_path.read_bytes())
    result = {'tool': 'largefiles', 'version': '1.2.3', 'run_id': '12345678-1234-1234-1234-123456789abc',
              'git_sha': 'a' * 40, 'git_ref': 'v1.2.3', 'status': 'success',
              'summary': {'total': 1, 'success': 1, 'failed': 0}, 'targets': [row]}
    results[count] = result
    result_path, manifest = work / ('result-%d.json' % count), work / ('manifest-%d.json' % count)
    save(result_path, result)
    generated = invoke('manifest-%d' % count, 'manifest', result_path, manifest)
    check('public manifest generation succeeds for %d actual archives' % count,
          generated.returncode == 0 and manifest.is_file())
    observed = json.loads(manifest.read_bytes())
    expected = [{'name': p.name, 'target': 'linux/amd64', 'target_triple': 'x86_64-unknown-linux-gnu',
                 'sha256': digest, 'size_bytes': len(payload), 'archive_format': 'tar.gz',
                 'signed': False, 'signature_file': '', 'build_purpose': 'release', 'publishable': True}
                for p in paths[:count]]
    check('%d-file manifest preserves every exact name, owner, hash and size' % count,
          observed['artifacts'] == expected and observed['summary'] == result['summary'])
    if count == 256:
        assembled = [{k: v for k, v in row.items() if k not in ('build_purpose', 'publishable')}
                     for row in observed['artifacts']]
        save(work / 'assembled-artifacts.json', assembled)
        check('the complete real artifact array exceeds the single-argument limit',
              len(json.dumps(assembled, indent=2).encode()) > 131072)

manifest = work / 'manifest-256.json'
framed = b''.join(p.name.encode() + b'\0' for p in paths)
check('independent final byte and collected-name admission accepts all 256 archives',
      invoke('final-admission', 'collected', manifest, work / 'payloads', '--collected', input=framed).returncode == 0)
check('complete manifest passes the shared successful-release profile',
      invoke('release-profile', 'admission', manifest, work / 'release-proof.json').returncode == 0 and
      len(json.loads((work / 'release-proof.json').read_bytes())['subject']) == 256)
value = json.loads(manifest.read_bytes())
for label, mutation in (
    ('omitted-row', lambda rows: rows.pop()),
    ('duplicate-name', lambda rows: rows.append(copy.deepcopy(rows[0]))),
    ('wrong-hash', lambda rows: rows[0].update(sha256='0' * 64)),
):
    changed = copy.deepcopy(value)
    mutation(changed['artifacts'])
    candidate = work / (label + '.json')
    save(candidate, changed)
    check('complete final inventory refuses ' + label,
          invoke(label, 'collected', candidate, work / 'payloads', '--collected', input=framed).returncode == 4)

def refused_source(label, selected=results[256], operation='manifest'):
    source, output = work / (label + '-result.json'), work / (label + '-manifest.json')
    save(source, selected)
    failed = invoke(label, operation, source, output)
    check(label + ' cannot emit or persist a publishable manifest',
          failed.returncode == 4 and not output.exists() and not failed.stdout)

malformed = copy.deepcopy(results[256])
malformed['targets'][0]['resume_artifacts'][0]['size_bytes'] = str(len(payload))
refused_source('malformed-worker-receipt', malformed)
held = work / 'temporarily-held-archive'
paths[0].rename(held)
try:
    refused_source('missing-collected-archive')
finally:
    held.rename(paths[0])
paths[0].write_bytes(payload + b'changed')
try:
    refused_source('changed-collected-archive')
finally:
    paths[0].write_bytes(payload)
wrong_owner = copy.deepcopy(results[1])
wrong_owner['targets'][0]['platform'] = 'linux/arm64'
refused_source('wrong-platform-owner', wrong_owner)
refused_source('trailing-build-environment-document', results[1], 'bad-environments')
stdout_result = invoke('stdout-manifest', 'manifest', work / 'result-1.json', '')
check('stdout mode emits exactly one complete manifest document',
      stdout_result.returncode == 0 and
      json.loads(stdout_result.stdout)['artifacts'] == json.loads((work / 'manifest-1.json').read_bytes())['artifacts'])
sentinel = work / 'existing-manifest.json'
sentinel.write_bytes(b'preserve existing output bytes\n')
sentinel_inode = sentinel.stat().st_ino
refused = invoke('preserve-existing-output', 'bad-environments', work / 'result-1.json', sentinel)
check('serialization failure preserves existing output bytes and inode without stdout',
      refused.returncode == 4 and not refused.stdout and sentinel.stat().st_ino == sentinel_inode and
      sentinel.read_bytes() == b'preserve existing output bytes\n')
check('generation and refusals preserve every original producer inode and byte', original ==
      {p.name: (p.stat().st_dev, p.stat().st_ino, hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths})
print('Large public manifest: %d checks passed' % checks, flush=True)
print('Compiler and source execution are fixture metadata; config, archives, receipts, manifest and byte admission are real.', flush=True)
PY
}

case "${1:-}" in
    --companion-packaging-only) test_companion_packaging; exit $? ;;
    --large-manifest-only) test_large_public_manifest; exit $? ;;
    '') ;;
    *) printf 'Unknown test option: %s\n' "$1" >&2; exit 4 ;;
esac
WORK=$(mktemp -d) || exit 1
printf 'Fixtures retained: %s\n' "$WORK"
# Ownership validation now uses the real document parser even when the legacy
# matrix fixture below supplies its narrow target/naming API responses.
source "$ROOT/src/config.sh"
source "$ROOT/src/act_runner.sh"
source "$ROOT/src/signing.sh"
# The checksum writer is now an explicit pre-publication helper; the normal
# command and this caller-block regression both execute its production body.
source <(awk '
    /^_release_prepare_ordinary_checksums\(\) \(/ {copy=1}
    copy {print}
    copy && /^\)/ {exit}
' "$ROOT/dsr")
# Load the actual nested collector and publisher naming functions without
# invoking CLI startup, authentication, compilers or any network mutation.
source <(awk '
    /^    (_build_target_suffix_name|_build_collect_artifact_file|_release_artifact_candidate_names)\(\)/ {copy=1}
    copy {print}
    copy && /^    }/ {copy=0}
' "$ROOT/dsr")
log_info() { :; }; log_warn() { :; }; log_error() { printf '%s\n' "$*" >&2; }
config_get_release_contract_json() { echo null; }
config_validate_target_triples() { return 0; }
config_get_target_triples_json() { echo '[]'; }
artifact_naming_artifact_variant() {
    case "$2/$3" in
        linux/amd64) printf 'x86_64-unknown-linux-gnu\tprimary\n' ;;
        linux/arm64) printf 'aarch64-unknown-linux-gnu\tprimary\n' ;;
        darwin/amd64) printf 'x86_64-apple-darwin\tprimary\n' ;;
        darwin/arm64) printf 'aarch64-apple-darwin\tprimary\n' ;;
        *) return 4 ;;
    esac
}
tool_name=sbh
version=1.2.3
local_path="$WORK"
build_release_contract_enabled=false
resume=false
collect_failed=false
collected_count=0
collision_count=0
declare -A collected_names=()
declare -a artifact_rename_pairs=()
output_dir="$WORK/output"
DSR_CONFIG_DIR="$WORK/config"
DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
ACT_REPOS_DIR="$DSR_CONFIG_DIR/repos.d"
mkdir -p "$output_dir" "$ACT_REPOS_DIR"
cat > "$ACT_REPOS_DIR/sbh.yaml" <<'YAML'
tool_name: sbh
targets: [linux/amd64, linux/arm64, darwin/amd64, darwin/arm64]
workspace_additional_artifacts:
  linux/amd64: [{name: release-info.json, format: json}]
YAML
if [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]]; then
    (
        # Use an actual host ELF executable to check final-copy permissions,
        # independently of the synthetic multi-platform payloads below.
        output_dir="$WORK/typed-binary-output"
        mkdir -p "$output_dir" "$WORK/typed-binary-source"
        cp -L /bin/true "$WORK/typed-binary-source/helper" || exit 1
        chmod 700 "$WORK/typed-binary-source/helper" || exit 1
        verified_additional_receipts=$(jq -nc --arg path "$WORK/typed-binary-source/helper" \
            --arg sha "$(_act_sha256 "$WORK/typed-binary-source/helper")" \
            --argjson size "$(_act_file_size "$WORK/typed-binary-source/helper")" \
            --arg identity "$(_act_file_identity "$WORK/typed-binary-source/helper")" \
            '{($path):{path:$path,name:"helper",declared_format:"binary",target:"linux/amd64",
                       sha256:$sha,size_bytes:$size,identity:$identity}}') || exit 1
        _build_collect_artifact_file "$WORK/typed-binary-source/helper" linux/amd64 \
            x86_64-unknown-linux-gnu true true || exit 1
        [[ -x "$output_dir/helper" ]] || exit 1
        cmp "$WORK/typed-binary-source/helper" "$output_dir/helper" || exit 1
        chmod 600 "$output_dir/helper" || exit 1
        if _build_collect_artifact_file "$WORK/typed-binary-source/helper" linux/amd64 \
            x86_64-unknown-linux-gnu true true; then
            echo 'FAIL: repeated collection accepted a companion whose executable mode changed' >&2
            exit 1
        fi
    ) || exit 1
    echo 'PASS: a real Linux companion retains executable mode and refuses later mode changes'
else
    echo 'SKIP: real Linux AMD64 companion executable requires that host architecture'
fi
targets='[]'
for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do
    dir="$WORK/${target/\//_}"
    mkdir -p "$dir"
    # Two raw executables with identical basenames across all four workers,
    # plus one archive with a repeated basename. No source is overwritten.
    printf 'executable fixture sbh %s\n' "$target" > "$dir/sbh"
    printf 'executable fixture inspector %s\n' "$target" > "$dir/inspector"
    tar -cJf "$dir/bundle.tar.xz" -C "$dir" sbh inspector || exit 1
    for name in sbh inspector bundle.tar.xz; do
        _build_collect_artifact_file "$dir/$name" "$target" '' true || exit 1
    done
    targets=$(jq -c --arg target "$target" --arg dir "$dir" '. + [{
        platform:$target,method:"native",status:"success",host:"fixture",
        artifact_paths:[$dir+"/sbh",$dir+"/inspector",$dir+"/bundle.tar.xz"]}]' <<< "$targets") || exit 1
done
printf '{"version":"1.2.3","schema":1}\n' > "$WORK/linux_amd64/release-info.json"
additional_receipt=$(jq -nc --arg path "$WORK/linux_amd64/release-info.json" \
    --arg sha "$(_act_sha256 "$WORK/linux_amd64/release-info.json")" \
    --argjson size "$(_act_file_size "$WORK/linux_amd64/release-info.json")" \
    --arg identity "$(_act_file_identity "$WORK/linux_amd64/release-info.json")" \
    '{path:$path,sha256:$sha,size_bytes:$size,identity:$identity}') || exit 1
targets=$(jq -c --argjson receipt "$additional_receipt" \
    '.[0].additional_artifacts=[$receipt]' <<< "$targets") || exit 1
with_receipts='[]'
while IFS= read -r row; do
    receipts=$(_act_result_artifact_receipts "$row") || exit 1
    with_receipts=$(jq -c --argjson row "$row" --argjson receipts "$receipts" \
        '. + [$row + {resume_artifacts:$receipts}]' <<< "$with_receipts") || exit 1
done < <(jq -c '.[]' <<< "$targets")
targets="$with_receipts"
result=$(jq -nc --argjson targets "$targets" '{tool:"sbh",version:"1.2.3",
    run_id:"12345678-1234-1234-1234-123456789abc",git_sha:("a"*40),git_ref:"v1.2.3",
    status:"success",summary:{total:4,success:4,failed:0},targets:$targets}') || exit 1
verified_additional_receipts=$(_act_additional_artifact_receipts_json sbh "$result") || exit 1
_build_collect_artifact_file "$WORK/linux_amd64/release-info.json" linux/amd64 \
    x86_64-unknown-linux-gnu true true || exit 1
[[ -f "$output_dir/release-info.json" && ! -e "$output_dir/release-info_linux_amd64.json" ]] || exit 1
before_count="$collected_count"
# The real collector also discovers files by walking the worker directory.
# Its second observation must retain the declaration instead of renaming it.
_build_collect_artifact_file "$WORK/linux_amd64/release-info.json" linux/amd64 \
    x86_64-unknown-linux-gnu true || exit 1
[[ "$collected_count" == "$before_count" ]] || exit 1
echo 'PASS: a declared JSON companion keeps its literal name through both collection paths'
collected_names[release-info.json]="$WORK/another-producer"
if _build_collect_artifact_file "$WORK/linux_amd64/release-info.json" linux/amd64 '' true true; then
    echo 'FAIL: literal companion collision was silently renamed or coalesced' >&2
    exit 1
fi
collected_names[release-info.json]="$WORK/linux_amd64/release-info.json"
[[ ! -e "$output_dir/release-info_linux_amd64.json" ]] || exit 1
cmp "$WORK/linux_amd64/release-info.json" "$output_dir/release-info.json" || exit 1
collect_failed=false
if _build_collect_artifact_file "$WORK/linux_amd64/sbh" linux/amd64 '' true true; then
    echo 'FAIL: undeclared additional payload bypassed receipt validation' >&2
    exit 1
fi
collect_failed=false
echo 'PASS: companion collisions and undeclared additional payloads refuse collection'
renames=$(printf '%s\n' "${artifact_rename_pairs[@]}" | jq -Rn '
    reduce inputs as $line ({}; ($line|split("\t")) as $p | .[$p[0]]=$p[1])') || exit 1
manifest="$WORK/manifest.json"
act_generate_manifest "$result" "$manifest" "$renames" || exit 1
_act_verify_collected_manifest "$manifest" "$output_dir" || exit 1
printf '%s\0' "${!collected_names[@]}" |
    _act_verify_collected_manifest "$manifest" "$output_dir" --collected || exit 1
omitted_manifest="$WORK/omitted-collected.json"
jq 'del(.artifacts[] | select(.name == "sbh_linux_arm64"))' "$manifest" > "$omitted_manifest" || exit 1
# Row-only verification cannot notice an omitted collected payload; the
# independent collection-coverage gate must reject it before sealing.
_act_verify_collected_manifest "$omitted_manifest" "$output_dir" || exit 1
if printf '%s\0' "${!collected_names[@]}" |
    _act_verify_collected_manifest "$omitted_manifest" "$output_dir" --collected; then
    echo 'FAIL: collected payload omitted from manifest was accepted' >&2
    exit 1
fi
echo 'PASS: final sealing refuses a collected payload omitted from the manifest'
jq -e '.artifacts | length == 13 and
    ([.[]|select(.archive_format=="none")]|length==9) and
    ([.[].target]|unique|length==4) and
    any(.name=="release-info.json" and .target=="linux/amd64")' "$manifest" >/dev/null || exit 1
for target in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do
    for binary in sbh inspector; do
        test -s "$output_dir/${binary}_${target}" || exit 1
    done
done
echo 'PASS: all four targets and both raw executables retain final names and bytes'
# Reverse result arrival: retained collection decisions must give exactly the
# same inventory, with no basename deduplication before name resolution.
reversed=$(jq '.targets |= reverse' <<< "$result")
act_generate_manifest "$reversed" "$WORK/reversed.json" "$renames" || exit 1
jq -S '.artifacts|sort_by(.name)' "$manifest" > "$WORK/forward.rows"
jq -S '.artifacts|sort_by(.name)' "$WORK/reversed.json" > "$WORK/reverse.rows"
cmp "$WORK/forward.rows" "$WORK/reverse.rows" || exit 1
echo 'PASS: manifest row order cannot lose a target'
if act_generate_manifest "$result" "$WORK/unsafe.json"; then
    echo 'FAIL: unresolved duplicate basenames were silently accepted' >&2; exit 1
fi
echo 'PASS: unresolved duplicate basenames refuse instead of dropping rows'
missing=$(jq '.targets[0].artifact_paths += ["/nonexistent/dsr-artifact"]' <<< "$result")
if act_generate_manifest "$missing" "$WORK/missing.json" "$renames"; then exit 1; fi
if _build_collect_artifact_file "$WORK/missing" linux/arm64 '' true; then exit 1; fi
echo 'PASS: declared missing artifacts refuse both collection and manifest generation'
wrong_receipt=$(jq '.targets[0].resume_artifacts[0].sha256=("0"*64)' <<< "$result")
if act_generate_manifest "$wrong_receipt" "$WORK/receipt-mismatch.json" "$renames"; then exit 1; fi
echo 'PASS: worker checksum receipt mismatches refuse manifest generation'
cp "$manifest" "$WORK/bad.json"
jq '.artifacts[0].sha256=("0"*64)' "$manifest" > "$WORK/bad.json"
if _act_verify_collected_manifest "$WORK/bad.json" "$output_dir"; then exit 1; fi
jq '.artifacts += [.artifacts[0]]' "$manifest" > "$WORK/duplicate.json"
if _act_verify_collected_manifest "$WORK/duplicate.json" "$output_dir"; then exit 1; fi
echo 'PASS: final byte mismatches and duplicate published names refuse sealing'
for format in none binary; do
    test "$(_release_artifact_candidate_names sbh_darwin_arm64 darwin/arm64 "$format")" = sbh_darwin_arm64 || exit 1
done
echo 'PASS: publication cannot synthesize unmanifested raw names'
# Execute the production checksum-generation block with the resolved upload
# names, rather than reproducing its checksum logic in this test.
source <(printf '_test_generate_checksums() {\n'; awk '
    /^    # === Generate SHA256SUMS/ {section=1}
    section && /^    if \$manifest_exists/ {copy=1}
    copy && /^    # Build upload list/ {exit}
    copy {print}
' "$ROOT/dsr"; printf '}\n')
artifacts_dir="$output_dir"
manifest_file="$manifest"
manifest_exists=true
ordinary_manifest=$(cat "$manifest")
declare -A ordinary_expected_sha=()
ordinary_expected_sha["${manifest_file##*/}"]=$(_act_sha256 "$manifest_file") || exit 1
artifact_naming_generate_dual_for_variant() {
    printf '%s\n' '{"versioned":"bundle_linux_arm64.tar.xz","compat":"unlisted.tar.xz"}'
}
test "$(_release_artifact_candidate_names bundle_linux_arm64.tar.xz linux/arm64 tar.xz)" = \
    bundle_linux_arm64.tar.xz || exit 1
echo 'PASS: archive publication also refuses names absent from the signed inventory'
declare -A ordinary_upload_names=()
while IFS= read -r name; do ordinary_upload_names["$name"]="$name"; done < <(jq -r '.artifacts[].name' "$manifest")
log_ok() { :; }
_test_generate_checksums || exit 1
if command -v minisign >/dev/null; then
    source "$ROOT/src/signing.sh"
    minisign -G -W -s "$WORK/key" -p "$WORK/key.pub" > "$WORK/keygen.log" 2>&1 || exit 1
    token=$(sed -n '2p' "$WORK/key.pub")
    signing_sign_exact "$manifest" "$manifest.minisig" "$WORK/key" "$token" \
        'ordinary collection regression' || exit 1
    signing_verify_exact "$manifest" "$manifest.minisig" "$token" || exit 1
    echo 'PASS: production signing authenticates the complete final inventory with Minisign'
else
    echo 'SKIP: native Minisign check (Ed25519 inventory authentication still runs below)'
fi
# Real signed bytes and checksums; this exercises Ed25519 authentication, not
# the Minisign CLI/format (covered by the signing integration suites).
python3 - "$manifest" "$output_dir" "$WORK" <<'PY'
import hashlib, json, pathlib, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
manifest, output, work = map(pathlib.Path, sys.argv[1:])
rows = json.loads(manifest.read_bytes())["artifacts"]
key = Ed25519PrivateKey.generate()
signature = key.sign(manifest.read_bytes())
key.public_key().verify(signature, manifest.read_bytes())
checksums = output / "SHA256SUMS"
signed = {r["name"]:r["sha256"] for r in rows}
unsigned = dict((line.split("  ",1)[1],line.split("  ",1)[0]) for line in checksums.read_text().splitlines())
actual = {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in output.iterdir() if p.is_file() and p.name != "SHA256SUMS" and not p.name.endswith(".sha256")}
assert actual == unsigned == signed
for name, digest in signed.items():
    assert (output / (name+".sha256")).read_text() == f"{digest}  {name}\n"
print("PASS: final payload namespace, SHA256SUMS and authenticated manifest match exactly")
PY
status=$?
[[ "$status" == 0 ]] || exit "$status"
printf 'post-collection mutation\n' >> "$output_dir/sbh_linux_amd64"
if _act_verify_collected_manifest "$manifest" "$output_dir"; then exit 1; fi
echo 'PASS: actual collected-byte mutation refuses final sealing'
printf 'post-worker mutation\n' >> "$WORK/linux_amd64/sbh"
if act_generate_manifest "$result" "$WORK/source-mutation.json" "$renames"; then exit 1; fi
echo 'PASS: source mutation cannot silently replace frozen worker bytes'
test_companion_packaging
