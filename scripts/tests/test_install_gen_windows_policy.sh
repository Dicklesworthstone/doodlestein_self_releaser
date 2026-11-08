#!/usr/bin/env bash
# Windows installer selection and public dry-run using the real configuration,
# naming and publication observer. No PowerShell, network or compilation is
# needed; runtime/NTFS/signature acceptance lives in the separate runtime suite.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
for dependency in bash python3 jq yq; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'SKIP: Windows installer policy tests require %s\n' "$dependency"
        exit 0
    fi
done
exec python3 -I - "$ROOT" <<'PY'
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

project = Path(sys.argv[1]).resolve()
module = project / 'src/install_gen.sh'
work = Path(tempfile.mkdtemp(prefix='dsr-windows-policy-')).resolve()
os.chmod(work, 0o700)
print('Windows installer policy evidence retained: ' + str(work), flush=True)
checks, failures, sequence = 0, 0, 0
old_installer = b'#requires -Version 7.4\nWrite-Output "retained installer"\n'
public_key = base64.b64encode(b'Ed' + bytes(range(40))).decode()


def check(label, condition, result=None):
    global checks, failures
    checks += 1
    failures += not condition
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    if not condition and result is not None:
        print('exit=' + str(result.returncode) + '\n' + result.stderr.decode(errors='replace'), flush=True)


def configuration():
    return {
        'tool_name': 'example', 'repo': 'fixture/example', 'binary_name': 'example',
        'language': 'go', 'targets': ['linux/amd64', 'windows/amd64', 'windows/arm64'],
        'workspace_binaries': ['example', 'daemon'],
        'workspace_binaries_by_target': {'windows/arm64': ['example', 'worker']},
        'archive_format': {'windows': 'zip'},
        'arch_aliases': {'amd64': 'x64', 'arm64': 'a64'},
        'target_triples': {'windows/amd64': 'x86_64-pc-windows-msvc',
                           'windows/arm64': 'aarch64-pc-windows-msvc'},
        'artifact_naming': '${name}-v${version}-${arch}-${target_triple}.${ext}',
    }


def fresh(label, document=None, existing=True):
    case = work / label
    for name in ('config/repos.d', 'ambient/repos.d', 'cwd', 'home'):
        (case / name).mkdir(parents=True)
    (case / 'config/repos.d/example.yaml').write_text(json.dumps(document or configuration()))
    if existing:
        active = case / 'output/example/install.ps1'
        active.parent.mkdir(parents=True)
        active.write_bytes(old_installer)
        active.chmod(0o751)
    return case


def snapshot(path):
    if not path.exists():
        return None
    rows = []
    for entry in [path, *sorted(path.rglob('*'))]:
        info = entry.lstat()
        rows.append((str(entry.relative_to(path)), info.st_dev, info.st_ino,
                     info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
                     hashlib.sha256(entry.read_bytes()).hexdigest() if stat.S_ISREG(info.st_mode) else None))
    return rows


def invoke(case, operation='policy', *, ambient=False, dry=False):
    global sequence
    sequence += 1
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('BASH_FUNC_') and key not in ('BASH_ENV', 'ENV', 'DSR_REPOS_FILE')}
    environment.update(HOME=str(case / 'home'), DSR_CONFIG_DIR=str(case / ('ambient' if ambient else 'config')),
                       DSR_INSTALLER_DIR=str(case / 'output'), DSR_STATE_DIR=str(case / 'state'),
                       DSR_CACHE_DIR=str(case / 'cache'), NO_COLOR='1')
    if operation == 'public':
        arguments = ['bash', project / 'dsr', '--json', 'installer', 'generate', 'example',
                     '--shell', 'powershell', '--dry-run', '--output-dir', case / 'output']
    else:
        body = 'source "$1" || exit $?; shift; '
        if operation == 'policy':
            body += '_install_gen_windows_policy "$1/repos.d/example.yaml" example'
        else:
            body += 'install_gen_create_powershell example --config-dir "$1"'
            if dry:
                body += ' --dry-run'
        arguments = ['bash', '-c', body, '_', module, case / 'config']
    result = subprocess.run(list(map(str, arguments)), cwd=case / 'cwd', env=environment,
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
    (case / ('run-%03d.json' % sequence)).write_text(json.dumps({
        'returncode': result.returncode, 'stdout': result.stdout.decode(errors='replace'),
        'stderr': result.stderr.decode(errors='replace')}, indent=2) + '\n')
    return result


def document(result):
    try:
        value = json.loads(result.stdout)
    except (ValueError, UnicodeError):
        return {}
    return value if isinstance(value, dict) else {}


case = fresh('matrix')
result = invoke(case)
policy = document(result)
platforms = policy.get('platforms', {})
check('policy selects only declared Windows targets and their complete distinct families',
      result.returncode == 0 and set(platforms) == {'windows/amd64', 'windows/arm64'} and
      platforms.get('windows/amd64', {}).get('binaries') == ['example.exe', 'daemon.exe'] and
      platforms.get('windows/arm64', {}).get('binaries') == ['example.exe', 'worker.exe'], result)
check('real publication naming preserves version tokens, architecture aliases and exact triples',
      platforms.get('windows/amd64', {}).get('name') == 'example-v${version}-x64-x86_64-pc-windows-msvc.zip' and
      platforms.get('windows/arm64', {}).get('name') == 'example-v${version}-a64-aarch64-pc-windows-msvc.zip' and
      platforms.get('windows/amd64', {}).get('target_triple') == 'x86_64-pc-windows-msvc' and
      platforms.get('windows/arm64', {}).get('target_triple') == 'aarch64-pc-windows-msvc', result)

selected = configuration()
selected.pop('artifact_naming')
selected.pop('arch_aliases')
selected.pop('target_triples')
case = fresh('selected-recipe-defaults', selected)
(case / 'config/repos.yaml').write_text(json.dumps({'tools': {'example': {
    'artifact_naming': 'borrowed-${version}', 'arch_aliases': {'amd64': 'borrowed'},
    'target_triples': {'windows/amd64': 'borrowed-windows-target'}}}}))
result = invoke(case)
row = document(result).get('platforms', {}).get('windows/amd64', {})
check('selected recipe defaults do not borrow naming or target identity from the registry',
      result.returncode == 0 and row.get('name') == 'example-${version}-windows-amd64.zip' and
      row.get('target_triple') == 'x86_64-pc-windows-msvc', result)

selected = configuration()
selected['targets'] = ['windows/amd64', 'windows/arm64']
selected['workspace_binaries_by_target']['windows/arm64'] = ['example']
selected['release_contract'] = {'checksum_sidecar': 'sha256', 'exact_primary_assets': {
    'windows/amd64': 'published-x64-family.zip', 'windows/arm64': 'published-arm64-raw'}}
case = fresh('literal-contract', selected)
result = invoke(case)
platforms = document(result).get('platforms', {})
check('strict contracts preserve literal ZIP and extensionless raw PE asset names',
      result.returncode == 0 and platforms.get('windows/amd64', {}).get('name') == 'published-x64-family.zip' and
      platforms.get('windows/amd64', {}).get('format') == 'zip' and
      platforms.get('windows/arm64', {}).get('name') == 'published-arm64-raw' and
      platforms.get('windows/arm64', {}).get('format') == 'none' and
      platforms.get('windows/arm64', {}).get('binaries') == ['example.exe'], result)

selected = configuration()
selected['workspace_binaries'] = ['example'] + ['worker-%d' % index for index in range(63)]
case = fresh('family-64', selected)
result = invoke(case)
check('the supported 64-member workspace family is retained without truncation',
      result.returncode == 0 and len(document(result).get('platforms', {}).get('windows/amd64', {}).get('binaries', [])) == 64,
      result)

case = fresh('explicit-selected-signing-key')
(case / 'config/config.yaml').write_text(json.dumps({'signing': {'minisign_pubkey': public_key}}))
(case / 'ambient/config.yaml').write_text(json.dumps({'signing': {'minisign_pubkey': 'invalid-ambient-key'}}))
before = snapshot(case / 'output'), snapshot(case / 'config')
result = invoke(case, 'create', ambient=True, dry=True)
check('explicit-root dry-run uses its selected signing key and preserves all output/config metadata',
      result.returncode == 0 and result.stdout.strip() == str(case / 'output/example/install.ps1').encode() and
      (snapshot(case / 'output'), snapshot(case / 'config')) == before, result)

case = fresh('invalid-selected-signing-key')
(case / 'config/config.yaml').write_text(json.dumps({'signing': {'minisign_pubkey': 'invalid-selected-key'}}))
(case / 'ambient/config.yaml').write_text(json.dumps({'signing': {'minisign_pubkey': public_key}}))
before = snapshot(case / 'output')
result = invoke(case, 'create', ambient=True)
check('an invalid selected key cannot fall back to the valid ambient key or replace the old installer',
      result.returncode == 4 and not result.stdout and snapshot(case / 'output') == before, result)

case = fresh('public-dry-run', existing=False)
before = snapshot(case / 'config')
result = invoke(case, 'public')
envelope = document(result)
details = envelope.get('details', {})
check('public PowerShell dry-run emits one result without creating output directories or locks',
      result.returncode == 0 and envelope.get('status') == 'success' and details.get('shell') == 'powershell' and
      details.get('dry_run') is True and details.get('installers') == [{
          'tool': 'example', 'path': str(case / 'output/example/install.ps1'), 'ok': True, 'exit_code': 0}] and
      not (case / 'output').exists() and snapshot(case / 'config') == before, result)

invalid = []
value = configuration(); value['workspace_binaries'] = ['example'] + ['worker-%d' % i for i in range(64)]
invalid.append(('family-65', value))
value = configuration(); value['workspace_binaries'] = ['example', 'x' * 197]
invalid.append(('overlong-executable', value))
value = configuration(); value['workspace_binaries'] = ['example', 'CON']
invalid.append(('device-executable', value))
value = configuration(); value['workspace_binaries'] = ['example', 'EXAMPLE.exe']
invalid.append(('case-colliding-family', value))
for name in ('cache.json', 'SHA256SUMS.txt'):
    value = configuration(); value['artifact_naming'] = name + '${ext}'
    value['archive_format'] = 'none'; value['workspace_binaries'] = ['example']; value.pop('workspace_binaries_by_target')
    invalid.append(('reserved-asset-' + name, value))
value = configuration(); value['target_triples']['windows/amd64'] = ['x86_64-pc-windows-msvc', 'x86_64-pc-windows-gnu']
invalid.append(('ambiguous-windows-variants', value))
value = configuration(); value['archive_format'] = 'none'
invalid.append(('raw-multiple-executables', value))
value = configuration(); value['targets'] = ['linux/amd64']
invalid.append(('missing-windows-target', value))
for label, selected in invalid:
    case = fresh(label, selected)
    before = snapshot(case / 'output')
    result = invoke(case, 'create')
    check(label + ' refuses before changing the retained installer or publication history',
          result.returncode == 4 and not result.stdout and snapshot(case / 'output') == before, result)

print('Windows installer policy: %d passed, %d failed (%d checks)' % (checks - failures, failures, checks), flush=True)
raise SystemExit(bool(failures))
PY
