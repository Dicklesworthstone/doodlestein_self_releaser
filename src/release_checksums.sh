#!/usr/bin/env bash
# Read-only, complete SHA256 coverage for GitHub release payloads. Checksums
# downloaded from a release are integrity evidence, NOT authenticated provenance.
# Reuses checksum_sync.sh's strict aggregate parser; never executes an asset.
_RELEASE_CHECKSUMS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_release_checksums_execute() {
    command -v python3 >/dev/null || { printf '%s\n' '[release-checksums] Python 3 is required' >&2; return 3; }
    exec python3 -I - "$_RELEASE_CHECKSUMS_DIR" "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
from urllib.parse import quote

AGGREGATES = ('SHA256SUMS', 'SHA256SUMS.txt', 'checksums.sha256', 'checksums.txt')
MAX_METADATA = 8 * 1024 * 1024
module = Path(sys.argv[1])
work = None
child = None
requests = 0
report = dict(kind='dsr-release-checksum-verification', status='error', exit_code=1,
              authenticated=False, source_verified=False,
              verification_policy='sha256-all-eligible-release-assets',
              eligible_count=0, verified_count=0, eligible_assets=[], verified_checksums=[],
              excluded_assets=[], checksum_errors=[], coverage_errors=[])

class Failure(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code

def require(condition, message, code=1):
    if not condition:
        raise Failure(message, code)

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()

def safe_name(value):
    return (isinstance(value, str) and 1 <= len(value.encode('utf-8')) <= 255 and value not in ('.', '..') and
            not value.startswith('-') and not any(ord(c) < 32 or ord(c) == 127 or c in '/\\:' for c in value))

def integer(value, low=0, high=9007199254740991):
    return type(value) is int and low <= value <= high

def pairs(items):
    value = {}
    for key, item in items:
        require(key not in value, 'Duplicate JSON member in release metadata', 4)
        value[key] = item
    return value

def read_json(path):
    try:
        return json.loads(path.read_bytes(), object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(Failure('Non-finite release metadata', 4)))
    except (ValueError, UnicodeError) as error:
        raise Failure('Unreadable JSON release metadata', 4) from error

def regular(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode), 'Downloaded response is not a regular file', 4)
    return info

def digest(path):
    info = regular(path)
    value = hashlib.sha256()
    with path.open('rb') as stream:
        before = os.fstat(stream.fileno())
        require((before.st_dev, before.st_ino) == (info.st_dev, info.st_ino), 'File replaced before hashing')
        for block in iter(lambda: stream.read(1048576), b''):
            value.update(block)
        after = os.fstat(stream.fileno())
    identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mode, s.st_mtime_ns, s.st_ctime_ns)
    require(identity(info) == identity(after) == identity(path.lstat()), 'File changed while hashing')
    return value.hexdigest()

def stop(signum, frame):
    raise Failure('Checksum verification interrupted', 5)

for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, stop)

def run(command, *, incoming=None, limit=60):
    global child
    # No shell, startup-file hooks or exported Bash functions. Proxy/CA settings
    # remain operator policy; curl's own rc file is explicitly disabled below.
    env = {k:v for k,v in os.environ.items() if not k.startswith('BASH_FUNC_') and k not in ('BASH_ENV', 'ENV')}
    child = subprocess.Popen(command, stdin=subprocess.PIPE if incoming is not None else subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, start_new_session=True)
    try:
        stdout, stderr = child.communicate(input=incoming, timeout=limit)
        return child.returncode, stdout, stderr
    except subprocess.TimeoutExpired as error:
        raise Failure('Release acquisition exceeded its time limit', 8) from error
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        child = None

def token_for_request():
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN') or ''
    if not token and shutil.which('gh'):
        code, stdout, _ = run(['gh', 'auth', 'token', '--hostname', 'github.com'], limit=15)
        if code == 0:
            try:
                token = stdout.decode('ascii').strip()
            except UnicodeError as error:
                raise Failure('Invalid GitHub authentication token encoding', 3) from error
    require(not token or re.fullmatch(r'[A-Za-z0-9_.-]+', token) is not None,
            'Invalid GitHub authentication token encoding', 3)
    return token

def require_curl():
    # Older curl only applied --max-filesize when the server advertised its
    # length. Refuse that unbounded chunked-download behavior before network IO.
    code, stdout, _ = run(['curl', '--disable', '--version'], limit=15)
    version = re.match(rb'curl ([0-9]+)\.([0-9]+)\.([0-9]+)\b', stdout)
    require(code == 0 and version is not None and
            tuple(map(int, version.groups())) >= (8, 4, 0),
            'curl 8.4.0 or newer is required for bounded downloads', 3)

def acquire(endpoint, destination, maximum, binary=False):
    global requests
    require(not destination.exists() and not destination.is_symlink(), 'Refusing to overwrite audit evidence', 4)
    requests += 1
    # Authorization goes through stdin, not argv or a retained configuration.
    # curl strips it on cross-host redirects; never use --location-trusted.
    config = 'header = "Accept: %s"\n' % ('application/octet-stream' if binary else 'application/vnd.github+json')
    config += 'header = "X-GitHub-Api-Version: 2022-11-28"\nheader = "Cache-Control: no-cache"\n'
    if token:
        config += 'header = "Authorization: Bearer %s"\n' % token
    command = ['curl', '--disable', '--silent', '--show-error', '--fail', '--location',
               '--max-redirs', '5', '--proto', '=https', '--proto-redir', '=https',
               '--connect-timeout', '10', '--max-time', str(args.timeout),
               '--max-filesize', str(max(1, maximum)), '--request', 'GET', '--config', '-',
               '--output', str(destination), 'https://api.github.com/' + endpoint]
    code, _, _ = run(command, incoming=config.encode('ascii'), limit=args.timeout + 10)
    require(code == 0, 'Release asset or metadata download failed (curl exit %d)' % code, 8)
    info = regular(destination)
    require(info.st_size <= maximum, 'Downloaded response exceeds its byte limit', 8)

def api(endpoint):
    destination = work / 'requests' / ('%04d.json' % (requests + 1))
    acquire(endpoint, destination, MAX_METADATA)
    return read_json(destination)

def release_context():
    value = api('repos/' + args.repo + '/releases/tags/' + quote(args.tag, safe=''))
    require(isinstance(value, dict) and integer(value.get('id'), 1) and value.get('tag_name') == args.tag and
            type(value.get('draft')) is bool and type(value.get('prerelease')) is bool and
            isinstance(value.get('target_commitish'), str), 'Invalid release identity', 4)
    return {key: value[key] for key in ('id', 'tag_name', 'draft', 'prerelease', 'target_commitish')}

def inventory(release_id):
    assets, ids, names = [], set(), set()
    for page in range(1, 102):
        rows = api('repos/%s/releases/%d/assets?per_page=100&page=%d' % (args.repo, release_id, page))
        require(isinstance(rows, list) and len(rows) <= 100, 'Invalid release asset page', 4)
        require(page <= 100 or not rows, 'Release asset inventory exceeds the 10000-asset audit limit', 4)
        for row in rows:
            require(isinstance(row, dict) and integer(row.get('id'), 1) and safe_name(row.get('name')) and
                    integer(row.get('size')) and row.get('state') == 'uploaded', 'Invalid release asset record', 4)
            checksum = row.get('digest')
            require(checksum is None or (isinstance(checksum, str) and re.fullmatch(r'sha256:[0-9a-fA-F]{64}', checksum)),
                    'Unsupported release API digest', 4)
            require(row['id'] not in ids and row['name'].casefold() not in names,
                    'Duplicate or case-colliding release asset identity', 4)
            ids.add(row['id']); names.add(row['name'].casefold())
            assets.append(dict(id=row['id'], name=row['name'], size=row['size'], digest=checksum))
        if len(rows) < 100:
            return sorted(assets, key=lambda row: row['name'])
    raise Failure('Truncated release asset inventory', 4)

def metadata_kind(name, checksum_name):
    if name == checksum_name or name in AGGREGATES:
        return 'checksum-aggregate'
    lower = name.lower()
    if lower.endswith(('.sha256', '.sha512', '.md5')):
        return 'checksum-sidecar'
    if lower.endswith(('.minisig', '.sig', '.asc')):
        return 'signature'
    if lower.endswith(('.intoto.jsonl', '.sigstore.json', '.sbom.json', '.sbom.spdx.json', '.spdx.json', '.cdx.json')):
        return 'provenance-or-sbom'
    if lower.endswith('-manifest.json') or lower in ('release-integrity.json', 'build-manifest.json'):
        return 'release-metadata'
    return None

def download_asset(row, directory, maximum):
    require(row['size'] <= maximum, 'Release asset exceeds the configured byte limit: ' + row['name'], 4)
    destination = directory / row['name']
    acquire('repos/%s/releases/assets/%d' % (args.repo, row['id']), destination, row['size'], True)
    require(regular(destination).st_size == row['size'], 'Downloaded size differs from release metadata: ' + row['name'])
    value = digest(destination)
    require(row['digest'] is None or value == row['digest'][7:].lower(),
            'Downloaded digest differs from release metadata: ' + row['name'])
    return destination, value

def normalized_checksums(path, index):
    code, stdout, _ = run(['bash', '-c', 'source "$1/checksum_sync.sh" || exit $?; checksum_manifest_normalize "$2"',
                           '_', str(module), str(path)], limit=args.timeout)
    require(code == 0, 'Checksum aggregate is empty, malformed, unsafe, or ambiguous', 4)
    normalized = work / 'evidence' / ('checksums-%03d.normalized' % index)
    with normalized.open('xb') as stream:
        stream.write(stdout)
    rows = {}
    for line in stdout.decode('utf-8').rstrip('\n').split('\n'):
        name, checksum = line[66:], line[:64]
        require(safe_name(name), 'Release checksum entries must use flat asset names', 4)
        rows[name] = checksum
    require(rows, 'Checksum aggregate has no records', 4)
    return rows

def owned_output(selected):
    if selected is None:
        return Path(tempfile.mkdtemp(prefix='dsr-release-checksums-')).resolve()
    path = Path(selected)
    require(path.is_absolute() and str(path) == selected and not any(p in ('.', '..') for p in path.parts),
            'Audit output must be a canonical absolute path', 4)
    require(not any(ord(c) < 32 or ord(c) == 127 or c == '\\' for c in selected),
            'Audit output contains unsupported path characters', 4)
    for part in [*reversed(path.parents), path]:
        require(not part.is_symlink(), 'Audit output may not contain symlinks', 4)
    require(path.parent.is_dir() and not path.exists(), 'Audit output must be a new directory with an existing parent', 4)
    path.mkdir(mode=0o700)
    return path

try:
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            raise Failure(message, 4)
    parser = Parser(description='Verify every eligible GitHub release asset against a complete SHA256 aggregate. No writes to GitHub.',
        epilog='Downloaded checksums do not authenticate the publisher or source. Signature/provenance verification is separate.',
        allow_abbrev=False)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--checksum-asset', help='Exact aggregate name; default: a conventional aggregate, never a payload sidecar')
    parser.add_argument('--output-dir', help='New directory for retained downloads and the audit receipt')
    parser.add_argument('--include-metadata', action='store_true', help='Also require checksums for SBOM/provenance/build metadata (not signatures or checksums)')
    parser.add_argument('--timeout', type=int, default=120, help='Seconds per bounded network/parser operation (default: 120)')
    parser.add_argument('--max-asset-bytes', type=int, default=2 * 1024**3)
    parser.add_argument('--max-total-bytes', type=int, default=8 * 1024**3)
    flags = [value.split('=', 1)[0] for value in sys.argv[2:] if value.startswith('--')]
    require(len(flags) == len(set(flags)), 'Duplicate audit option', 4)
    args = parser.parse_args(sys.argv[2:])
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*', args.repo) is not None and '..' not in args.repo,
            'Invalid repository name', 4)
    require(re.fullmatch(r'v?[0-9]+\.[0-9]+\.[0-9]+(?:[+-][A-Za-z0-9.+-]+)?', args.tag) is not None,
            'Select an explicit version tag, not latest or a branch', 4)
    require(args.checksum_asset is None or safe_name(args.checksum_asset), 'Unsafe checksum aggregate name', 4)
    require(integer(args.timeout, 1, 3600) and integer(args.max_asset_bytes, 1) and integer(args.max_total_bytes, 1),
            'Invalid acquisition limit', 4)
    require(shutil.which('curl') and shutil.which('bash'), 'curl and Bash are required', 3)
    require(shutil.which('jq'), 'jq is required for the shared checksum parser', 3)
    require_curl()
    token = token_for_request()
    os.umask(0o077)
    work = owned_output(args.output_dir)
    (work / 'requests').mkdir(); (work / 'artifacts').mkdir(); (work / 'evidence').mkdir()
    report.update(repository=args.repo, tag=args.tag, output_dir=str(work), include_metadata=args.include_metadata)
    context = release_context()
    report['release'] = context
    assets = inventory(context['id'])
    by_name = {row['name']: row for row in assets}
    checksum_names = ([args.checksum_asset] if args.checksum_asset else
                      [name for name in AGGREGATES if name in by_name])
    checksum_name = checksum_names[0] if checksum_names else None
    eligible = []
    for row in assets:
        kind = metadata_kind(row['name'], checksum_name)
        if kind is None or (args.include_metadata and kind in ('provenance-or-sbom', 'release-metadata')):
            eligible.append(row)
        else:
            report['excluded_assets'].append(dict(name=row['name'], reason=kind))
    report['eligible_assets'] = [row['name'] for row in eligible]
    report['eligible_count'] = len(eligible)
    require(eligible, 'Release has no eligible payloads; no checksum coverage can be claimed')
    require(checksum_name in by_name, 'No unambiguous checksum aggregate is available')
    require(sum(row['size'] for row in eligible) + sum(by_name[name]['size'] for name in checksum_names) <= args.max_total_bytes,
            'Release audit exceeds the configured total download limit', 4)
    expected, checksum_evidence = {}, []
    for index, name in enumerate(checksum_names, 1):
        checksum_path, checksum_digest = download_asset(by_name[name], work / 'evidence', MAX_METADATA)
        evidence = dict(name=name, id=by_name[name]['id'], sha256=checksum_digest, path=str(checksum_path))
        checksum_evidence.append(evidence)
        report['checksum_assets'] = checksum_evidence
        rows = normalized_checksums(checksum_path, index)
        missing = [row['name'] for row in eligible if row['name'] not in rows]
        foreign = sorted(set(rows) - set(by_name))
        if missing:
            report['coverage_errors'].append(dict(kind='missing-checksum', aggregate=name, assets=missing))
        if foreign:
            report['coverage_errors'].append(dict(kind='unknown-checksum-member', aggregate=name, assets=foreign))
        selected = {row['name']: rows[row['name']] for row in eligible if row['name'] in rows}
        if expected and selected != expected:
            report['coverage_errors'].append(dict(kind='conflicting-aggregate', aggregate=name))
        expected = selected
    require(not report['coverage_errors'], 'Checksum aggregate does not cover the selected release inventory')
    for row in eligible:
        try:
            _, actual = download_asset(row, work / 'artifacts', args.max_asset_bytes)
            require(actual == expected[row['name']], 'Payload checksum mismatch: ' + row['name'])
        except Failure as error:
            report['checksum_errors'].append(dict(name=row['name'], error=str(error), exit_code=error.code))
            raise
        report['verified_checksums'].append(row['name'])
        report['verified_count'] += 1
    require(inventory(context['id']) == assets and release_context() == context,
            'Release identity or asset inventory changed during verification')
    require(all(digest(Path(row['path'])) == row['sha256'] for row in checksum_evidence),
            'Checksum evidence changed during verification')
    # A later write to an earlier downloaded payload must not leave a green
    # full-coverage receipt. The private output directory is trusted storage.
    require(all(digest(work / 'artifacts' / row['name']) == expected[row['name']] for row in eligible),
            'Downloaded payload changed before audit completion')
    # Export ONLY actually verified records. Excluded metadata can occur in an
    # aggregate, but its unchecked digest must never propagate as audited data.
    with (work / 'checksums.normalized').open('xb') as stream:
        stream.write(''.join(expected[row['name']] + '  ' + row['name'] + '\n' for row in eligible).encode('utf-8'))
    report.update(status='verified', exit_code=0, inventory_stable=True,
                  normalized_manifest=str(work / 'checksums.normalized'),
                  normalized_manifest_sha256=digest(work / 'checksums.normalized'))
except (Failure, OSError, ValueError, UnicodeError, TypeError, KeyError) as error:
    report.update(status='error', exit_code=getattr(error, 'code', 1), error=str(error), inventory_stable=False)
    if not report['checksum_errors'] and not report['coverage_errors']:
        report['coverage_errors'].append(dict(kind='unverified', error=str(error)))
    print('[release-checksums] ' + str(error), file=sys.stderr)
finally:
    # Retain success AND failure evidence. Never replace an existing receipt.
    if work is not None:
        try:
            with (work / 'result.json').open('xb') as receipt:
                receipt.write(canonical(report))
            print('[release-checksums] Evidence retained: ' + str(work), file=sys.stderr)
        except OSError:
            report.update(status='error', exit_code=1, inventory_stable=False, error='Could not persist audit receipt')
            report.pop('normalized_manifest', None)
            report.pop('normalized_manifest_sha256', None)
    if 'args' in globals():
        print(canonical(report).decode(), end='')
    elif sys.exc_info()[0] is not SystemExit:
        print(canonical(report).decode(), end='')
sys.exit(report['exit_code'])
PY
}

release_verify_checksums() ( _release_checksums_execute "$@"; )

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Execute directly so signals to the CLI PID reach the owned supervisor,
    # rather than orphaning it below a Bash function subshell.
    _release_checksums_execute "$@"
fi
