#!/usr/bin/env bash
# Real DSR packaging, generated PowerShell, Go PE files and Minisign. Only host
# detection and HTTP delivery are fixtures; native NTFS/Windows is not claimed.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for dependency in pwsh minisign go python3 jq yq tar gzip; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'SKIP: Windows archive tests require %s\n' "$dependency"
        exit 0
    }
done
python3 -I - "$ROOT" "$@" <<'PY'
import argparse
import base64
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('project', type=Path)
parser.add_argument('--baseline-project', type=Path)
args = parser.parse_args()
project = args.project.resolve()
root = Path(tempfile.mkdtemp(prefix='dsr-windows-archives-')).resolve()
os.chmod(root, 0o700)
print('Retained Windows archive evidence: ' + str(root), flush=True)
env = {k: v for k, v in os.environ.items() if k not in ('BASH_ENV', 'ENV', 'DSR_GH_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN', 'DSR_REPOS_FILE') and not k.startswith('BASH_FUNC_')}
env.update(DSR_CONFIG_DIR=str(root / 'config'), DSR_STATE_DIR=str(root / 'state'),
           DSR_CACHE_DIR=str(root / 'cache'), DSR_INSTALLER_DIR=str(root / 'generated'),
           XDG_CONFIG_HOME=str(root / 'xdg'), CI='1', GOTOOLCHAIN='local', GOFLAGS='-p=2', GOMAXPROCS='2')
for name in ('config/repos.d', 'source', 'results', 'packages'):
    (root / name).mkdir(parents=True)
(root / 'source/main.go').write_text('package main\nimport "fmt"\nvar role string\nfunc main(){fmt.Println(role)}\n')
passed = failed = 0

def check(label, condition, detail=''):
    global passed, failed
    if condition:
        passed += 1
        print('PASS: ' + label, flush=True)
    else:
        failed += 1
        print('FAIL: ' + label + ': ' + str(detail), flush=True)

def command(argv, label, extra=None, timeout=90):
    result = subprocess.run([str(x) for x in argv], env=env | (extra or {}), cwd=project,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    (root / 'results' / (label + '.stdout')).write_bytes(result.stdout)
    (root / 'results' / (label + '.stderr')).write_bytes(result.stderr)
    return result

def need(result):
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace'))
    return result

for arch in ('amd64', 'arm64'):
    (root / arch).mkdir()
    for binary in ('app', 'worker'):
        need(command(['go', 'build', '-trimpath', '-ldflags', '-X main.role=' + binary,
                      '-o', root / arch / (binary + '.exe'), root / 'source/main.go'],
                     'compile-' + arch + '-' + binary,
                     {'GOOS': 'windows', 'GOARCH': arch, 'CGO_ENABLED': '0'}))
need(command(['minisign', '-G', '-W', '-p', root / 'key.pub', '-s', root / 'key.sec'], 'keygen'))
key = (root / 'key.pub').read_text().splitlines()[-1]
configuration = dict(tool_name='tar-demo', repo='fixture/tar-demo', binary_name='app', language='go',
                     targets=['windows/amd64', 'windows/arm64'], workspace_binaries=['app', 'worker'],
                     archive_format={'windows': 'tar.gz'}, minisign_pubkey=key,
                     artifact_naming='${name}-${version}-${os}-${arch}')
config_path = root / 'config/repos.d/tar-demo.yaml'
config_path.write_text(json.dumps(configuration))
if args.baseline_project:
    incumbent = command([args.baseline_project.resolve() / 'dsr', '--json', '--non-interactive', 'installer',
                         'generate', 'tar-demo', '--shell', 'powershell', '--output-dir', root / 'baseline'], 'baseline-generation')
    check('frozen incumbent rejects a configured Windows tar.gz installer', incumbent.returncode == 4 and
          b'PowerShell installers support ZIP and raw Windows executables' in incumbent.stderr)

generated = command([project / 'dsr', '--json', '--non-interactive', 'installer', 'generate', 'tar-demo',
                     '--shell', 'powershell'], 'generate')
runtime = root / 'generated/tar-demo/install.ps1'
check('public CLI generates a tar.gz Windows installer', generated.returncode == 0 and runtime.is_file(), generated.stderr)
need(generated)
embedded = json.loads(base64.b64decode(re.findall(r"\$script:DsrWindowsInstallPolicyBase64 = '([A-Za-z0-9+/=]+)'", runtime.read_text())[0]))
check('both Windows architectures retain tar.gz and the complete family',
      all(embedded['platforms']['windows/' + a]['format'] == 'tar.gz' and
          embedded['platforms']['windows/' + a]['binaries'] == ['app.exe', 'worker.exe'] for a in ('amd64', 'arm64')))

driver = root / 'driver.ps1'
driver.write_text(r'''param([string]$RuntimePath, [string]$CasePath)
$ErrorActionPreference = 'Stop'
$fixture = ConvertFrom-Json ([IO.File]::ReadAllText($CasePath)) -AsHashtable
$text = [IO.File]::ReadAllText($RuntimePath)
$offset = $text.IndexOf('# DSR_WINDOWS_INSTALL_DISPATCH:', [StringComparison]::Ordinal)
if ($offset -le 0) { throw 'Missing production dispatch marker' }
. ([scriptblock]::Create($text.Substring(0, $offset)))
$script:Fixture = $fixture
function Get-DsrHostPlatform { return $script:Fixture.platform }
function Invoke-DsrDownload {
    param([string]$Url, [string]$Destination, [switch]$Optional, [long]$MaximumBytes = 2147483648, [switch]$ApiAsset)
    [IO.File]::AppendAllText($script:Fixture.requests, $Url + "`n")
    if ($script:Fixture.parameters.Contains('Offline') -and $script:Fixture.parameters.Offline) { throw 'Offline network request' }
    if (-not $script:Fixture.downloads.Contains($Url)) {
        if ($Optional) { return $false }
        Stop-DsrInstall 'Fixture asset unavailable' 8
    }
    $source = $script:Fixture.downloads[$Url]
    if ([IO.FileInfo]::new($source).Length -gt $MaximumBytes) { Stop-DsrInstall 'Fixture exceeds transfer cap' 7 }
    Copy-DsrNewFile $source $Destination
    return $true
}
if ($fixture.Contains('expanded_limit')) { $script:DsrMaximumExpandedBytes = [long]$fixture.expanded_limit }
if ($fixture.Contains('move_fault') -and $fixture.move_fault) {
    $script:Moves = 0
    function Move-DsrInstalledFile {
        param([string]$Source, [string]$Destination)
        $script:Moves++
        if ($script:Moves -eq 2) { throw 'Injected second replacement failure' }
        [IO.File]::Move($Source, $Destination, $true)
    }
}
$parameters = $fixture.parameters
exit (Invoke-DsrWindowsInstaller @parameters)
''')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def package(name, arch='amd64', entries=None, raw=None, fmt=tarfile.USTAR_FORMAT):
    path = root / 'packages' / (name + '.tar.gz')
    if raw is not None:
        path.write_bytes(gzip.compress(raw, mtime=0))
    elif entries is None:
        need(command(['bash', '-c', 'source "$1/src/packaging.sh"; packaging_build_archive tar.gz "$2" "$3" app.exe worker.exe',
                      '_', project, path, root / arch], 'package-' + name))
    else:
        with tarfile.open(path, 'w:gz', format=fmt) as archive:
            for entry, data in entries:
                if data is not None:
                    entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data) if data is not None else None)
    return path

def member(name, data=None, kind=tarfile.REGTYPE, link=''):
    entry = tarfile.TarInfo(name)
    entry.type, entry.mode, entry.linkname = kind, 0o755, link
    return entry, data

def proof(path, asset, label):
    checksum = root / 'packages' / (label + '.sha256')
    checksum.write_text(digest(path) + '  ' + asset + '\n')
    signature = root / 'packages' / (label + '.minisig')
    need(command(['minisign', '-Sm', path, '-s', root / 'key.sec', '-x', signature], 'sign-' + label))
    base = 'https://github.com/fixture/tar-demo/releases/download/v1.2.3/'
    return {base + asset: str(path), base + asset + '.sha256': str(checksum), base + asset + '.minisig': str(signature)}

def install(label, path, arch='amd64', *, extra=None, cache=None, offline=False, selected_runtime=runtime, mutate_proof=None):
    asset = embedded['platforms']['windows/' + arch]['name'].replace('${version}', '1.2.3')
    prefix = root / (label + '-installed')
    prefix.mkdir()
    for binary in ('app.exe', 'worker.exe'):
        (prefix / binary).write_bytes(('previous ' + binary).encode())
    (prefix / 'unrelated').write_bytes(b'leave this alone')
    before = {p.name: (p.read_bytes(), p.stat().st_ino) for p in prefix.iterdir()}
    requests = root / (label + '-requests')
    fixture = dict(platform='windows/' + arch, requests=str(requests), downloads=proof(path, asset, label),
                   parameters=dict(Version='1.2.3', Prefix=str(prefix), CacheDir=str(cache or root / (label + '-cache')),
                                   Yes=True, Json=True, Offline=offline))
    fixture.update(extra or {})
    if mutate_proof:
        mutate_proof(fixture['downloads'])
    case_path = root / (label + '.json')
    case_path.write_text(json.dumps(fixture))
    result = command(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', driver, selected_runtime, case_path], label)
    try:
        value = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError):
        value = {}
    return result, value, prefix, before, requests

archives = {a: package('production-' + a, a) for a in ('amd64', 'arm64')}
for arch, path in archives.items():
    result, value, prefix, before, requests = install('install-' + arch, path, arch)
    check(arch + ' signed production tar.gz installs both genuine PE executables', result.returncode == 0 and
          all((prefix / b).read_bytes() == (root / arch / b).read_bytes() for b in ('app.exe', 'worker.exe')), result.stderr)
    check(arch + ' result retains real signature, platform and binary receipts', value.get('signature_verified') is True and
          value.get('platform') == 'windows/' + arch and len(value.get('binaries', [])) == 2 and
          all(row['sha256'] == digest(root / arch / row['name']) for row in value.get('binaries', [])))
    check(arch + ' leaves unselected files untouched', (prefix / 'unrelated').read_bytes() == before['unrelated'][0] and
          (prefix / 'unrelated').stat().st_ino == before['unrelated'][1])
    result, value, prefix, before, requests = install('offline-' + arch, path, arch, offline=True, cache=root / ('install-' + arch + '-cache'))
    check(arch + ' exact verified cache installs offline with no network', result.returncode == 0 and not requests.exists() and
          value.get('cache', {}).get('offline') is True, result.stderr)

app = (root / 'amd64/app.exe').read_bytes()
worker = (root / 'amd64/worker.exe').read_bytes()
base = [member('app.exe', app), member('worker.exe', worker)]
negatives = {
    'traversal': base + [member('../escape', b'x')],
    'absolute': base + [member('/escape', b'x')],
    'backslash': base + [member('dir\\escape', b'x')],
    'device': base + [member('NUL.txt', b'x')],
    'symlink': base + [member('link', kind=tarfile.SYMTYPE, link='app.exe')],
    'hardlink': base + [member('link', kind=tarfile.LNKTYPE, link='app.exe')],
    'fifo': base + [member('pipe', kind=tarfile.FIFOTYPE)],
    'duplicate': base + [member('app.exe', app)],
    'case-alias': base + [member('APP.exe', app)],
    'ambiguous-family': base + [member('second/app.exe', app)],
    'directory-conflict': base + [member('data', b'x'), member('data/file', b'x')],
    'case-directory': base + [member('Data/a', b'x'), member('data/b', b'x')],
    'missing-companion': base[:1],
    'wrong-machine': [member('app.exe', (root / 'arm64/app.exe').read_bytes()), base[1]],
    'empty-executable': [member('app.exe', b''), base[1]],
}
for label, entries in negatives.items():
    path = package(label, entries=entries)
    result, value, prefix, before, requests = install(label, path)
    check(label + ' refuses before any installed byte or inode changes', result.returncode == 7 and value.get('status') == 'error' and
          all((prefix / n).read_bytes() == b and (prefix / n).stat().st_ino == ino for n, (b, ino) in before.items()), result.stderr)

# USTAR, PAX long names and GNU long-name records are genuine archive encodings.
for label, fmt in [('pax', tarfile.PAX_FORMAT), ('gnu-long', tarfile.GNU_FORMAT)]:
    directory = 'a' * 110
    path = package(label, entries=[member(directory, kind=tarfile.DIRTYPE),
                   member(directory + '/app.exe', app), member(directory + '/worker.exe', worker), member('README', b'data')], fmt=fmt)
    result, value, prefix, before, requests = install(label, path)
    check(label + ' streams complete long-name families without extracting unselected data', result.returncode == 0 and
          (prefix / 'app.exe').read_bytes() == app and (prefix / 'worker.exe').read_bytes() == worker and
          not (prefix / 'README').exists(), result.stderr)

raw = gzip.decompress(archives['amd64'].read_bytes())
bad_checksum = bytearray(raw); bad_checksum[148] = ord('7') if bad_checksum[148] != ord('7') else ord('6')
malformed = {'header-checksum': bytes(bad_checksum), 'truncated-member': raw[:2048],
             'trailing-garbage': raw + b'x' * 512,
             'concatenated-tar': raw + raw}
# A giant metadata length must be rejected from its header, before TarReader
# allocates or reads that declared data. Keep the fixture itself only 512 bytes.
large = tarfile.TarInfo('PaxHeaders/long'); large.type = tarfile.XHDTYPE; large.size = 2**30
malformed['oversized-metadata'] = large.tobuf(format=tarfile.USTAR_FORMAT)
for label, content in malformed.items():
    result, value, prefix, before, requests = install(label, package(label, raw=content))
    check(label + ' refuses before installation', result.returncode == 7 and value.get('status') == 'error' and
          all((prefix / n).read_bytes() == b and (prefix / n).stat().st_ino == ino for n, (b, ino) in before.items()), result.stderr)

for label, attributes in [('pax-gnu-sparse', {'GNU.sparse.map': '0,' + str(len(app)), 'GNU.sparse.size': str(len(app))}),
                          ('pax-schily-sparse', {'SCHILY.filetype': 'sparse', 'SCHILY.realsize': str(len(app))})]:
    sparse = member('app.exe', app)
    sparse[0].pax_headers = attributes
    path = package(label, entries=[sparse, member('worker.exe', worker)], fmt=tarfile.PAX_FORMAT)
    result, value, prefix, before, requests = install(label, path)
    check(label + ' cannot disguise sparse data as a regular executable', result.returncode == 7 and
          b'Sparse TAR metadata' in result.stderr and
          all((prefix / n).read_bytes() == b and (prefix / n).stat().st_ino == ino for n, (b, ino) in before.items()), result.stderr)

for label, compressed in [('gzip-missing-footer', archives['amd64'].read_bytes()[:-8]),
                          ('gzip-bad-crc', archives['amd64'].read_bytes()[:-8] + b'\0\0\0\0' + archives['amd64'].read_bytes()[-4:])]:
    path = root / 'packages' / (label + '.tar.gz')
    path.write_bytes(compressed)
    result, value, prefix, before, requests = install(label, path)
    check(label + ' refuses an authenticated but malformed gzip stream', result.returncode == 7 and
          all((prefix / n).read_bytes() == b for n, (b, _) in before.items()), result.stderr)

result, value, prefix, before, requests = install('stream-limit', archives['amd64'],
    extra={'expanded_limit': len(app) + len(worker) + 512})
check('decompressed stream cap is enforced while reading', result.returncode == 7 and b'expanded stream exceeds' in result.stderr and
      all((prefix / n).read_bytes() == b for n, (b, _) in before.items()), result.stderr)
result, value, prefix, before, requests = install('rollback', archives['amd64'], extra={'move_fault': True})
check('tar.gz uses the existing complete-family rollback transaction', result.returncode != 0 and
      all((prefix / n).read_bytes() == b for n, (b, _) in before.items()) and
      not (prefix / '.dsr-windows-install.pending.json').exists(), result.stderr)

def poison_checksum(downloads):
    url = next(url for url in downloads if url.endswith('.sha256'))
    path = Path(downloads[url])
    path.write_text('0' * 64 + path.read_text()[64:])

def poison_signature(downloads):
    url = next(url for url in downloads if url.endswith('.minisig'))
    Path(downloads[url]).write_bytes((root / 'packages/install-arm64.minisig').read_bytes())

for label, mutation in [('bad-checksum', poison_checksum), ('wrong-signature', poison_signature)]:
    result, value, prefix, before, requests = install(label, archives['amd64'], mutate_proof=mutation)
    check('tar.gz ' + label + ' remains terminal before installation', result.returncode == 7 and
          ('checksum' if label == 'bad-checksum' else 'signature') in value.get('error', '').lower() and
          all((prefix / n).read_bytes() == b and (prefix / n).stat().st_ino == ino for n, (b, ino) in before.items()), result.stderr)

strict = dict(configuration, target_triples={'windows/amd64': 'x86_64-pc-windows-msvc',
                                             'windows/arm64': 'aarch64-pc-windows-msvc'},
              release_contract={'checksum_sidecar': 'sha256', 'exact_primary_assets': {
                  'windows/amd64': 'literal-x64-release.tar.gz', 'windows/arm64': 'literal-arm64-release.tar.gz'}})
config_path.write_text(json.dumps(strict))
need(command([project / 'dsr', '--json', '--non-interactive', 'installer', 'generate', 'tar-demo', '--shell', 'powershell'], 'generate-strict'))
embedded = json.loads(base64.b64decode(re.findall(r"\$script:DsrWindowsInstallPolicyBase64 = '([A-Za-z0-9+/=]+)'", runtime.read_text())[0]))
result, value, prefix, before, requests = install('strict-arm64', archives['arm64'], 'arm64')
check('strict ARM64 contract preserves its literal tar.gz name through authenticated installation',
      result.returncode == 0 and embedded['platforms']['windows/arm64']['name'] == 'literal-arm64-release.tar.gz' and
      value.get('target_triple') == 'aarch64-pc-windows-msvc' and (prefix / 'worker.exe').read_bytes() == (root / 'arm64/worker.exe').read_bytes(), result.stderr)

# The shared member-path validator must preserve ZIP admission as well.
zip_configuration = dict(configuration, archive_format='zip')
config_path.write_text(json.dumps(zip_configuration))
need(command([project / 'dsr', '--json', '--non-interactive', 'installer', 'generate', 'tar-demo', '--shell', 'powershell'], 'generate-zip'))
embedded = json.loads(base64.b64decode(re.findall(r"\$script:DsrWindowsInstallPolicyBase64 = '([A-Za-z0-9+/=]+)'", runtime.read_text())[0]))
for label, extra_name in [('zip-valid', None), ('zip-case-directory', 'data/b')]:
    path = root / 'packages' / (label + '.zip')
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('app.exe', app); archive.writestr('worker.exe', worker)
        archive.writestr('Data/a', b'one')
        if extra_name:
            archive.writestr(extra_name, b'two')
    result, value, prefix, before, requests = install(label, path)
    check(label + ' preserves existing ZIP path admission',
          (result.returncode == 7 and all((prefix / n).read_bytes() == b for n, (b, _) in before.items())) if extra_name else
          (result.returncode == 0 and (prefix / 'app.exe').read_bytes() == app), result.stderr)

print(f'Windows archive tests: {passed} passed; {failed} failed', flush=True)
raise SystemExit(1 if failed else 0)
PY
