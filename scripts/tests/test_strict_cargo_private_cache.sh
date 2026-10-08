#!/usr/bin/env bash
# Native Unix metadata, compilation and artifact admission with private Cargo
# caches. Git/Cargo/filesystem operations are real; SSH is executed locally.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
MODE=all
if [[ "${1:-}" == --locked-downloads-only && $# == 1 ]]; then
    MODE=locked-downloads
elif (( $# != 0 )); then
    printf 'Usage: %s [--locked-downloads-only]\n' "$0" >&2
    exit 4
fi
for tool in python3 bash git cargo rustc jq yq; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
python3 -I - "$ROOT" "$MODE" <<'PY'
import functools
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor

root = Path(sys.argv[1])
mode = sys.argv[2]
module = Path(os.environ.get('DSR_TEST_ACT_RUNNER', str(root / 'src/act_runner.sh')))
os.umask(0o077)
work = Path(tempfile.mkdtemp(prefix='dsr-strict-cargo-private-')).resolve()
print('Retained fixtures: ' + str(work), flush=True)
source = work / 'snapshot/source'
ambient = work / 'ambient'
dependency = work / 'dependency'
configs = work / 'config/repos.d'
for directory in (source / 'src', ambient, dependency / 'src', configs):
    directory.mkdir(parents=True)
checks = 0


def check(label, condition):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print('PASS ' + label, flush=True)


def invoke(argv, **kwargs):
    return subprocess.run(list(map(str, argv)), capture_output=True, timeout=90, **kwargs)


def require(argv, **kwargs):
    result = invoke(argv, **kwargs)
    if result.returncode:
        raise AssertionError(str(argv) + '\n' + result.stderr.decode())
    return result.stdout.decode()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


environment = dict(os.environ)
for name in list(environment):
    if name.startswith('CARGO_') or name in ('RUSTC', 'RUSTDOC', 'RUSTFLAGS', 'RUSTDOCFLAGS',
                                            'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER'):
        environment.pop(name)
environment.update(CARGO_HOME=str(ambient), RCH_DISABLED='1', RCH_CARGO_WRAPPER_BYPASS='1',
                   DSR_KEEP_BUILD_STAGES='1', DSR_TEST_CONFIGS=str(configs),
                   DSR_TEST_ARTIFACTS=str(work / 'artifacts'), DSR_TEST_LOGS=str(work / 'logs'))
triple = next(line.split(': ', 1)[1] for line in require(['rustc', '-vV']).splitlines()
              if line.startswith('host: '))
host = {'Linux': 'linux', 'Darwin': 'darwin'}.get(platform.system())
arch = {'x86_64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine())
if not host or not arch:
    raise SystemExit('strict Cargo cache test requires a native Unix Rust host')
target = host + '/' + arch
environment['DSR_TEST_PLATFORM'] = target

(dependency / 'Cargo.toml').write_text('[package]\nname="cache_dependency"\nversion="1.0.0"\nedition="2021"\n')
(dependency / 'src/lib.rs').write_text('pub fn value() -> u32 { 42 }\n')
require(['git', '-C', dependency, 'init', '-q'])
require(['git', '-C', dependency, 'add', '.'])
require(['git', '-C', dependency, '-c', 'user.name=DSR Test', '-c',
         'user.email=dsr@example.invalid', 'commit', '-qm', 'dependency'])
revision = require(['git', '-C', dependency, 'rev-parse', 'HEAD']).strip()
# A genuine alternate sparse registry serves one authenticated crate. Only
# this process's loopback server is used to warm Cargo; it is stopped before
# any locked/offline admission or compilation, including the poison baselines.
registry = work / 'registry-origin'
registry.mkdir()
crate_bytes = io.BytesIO()
with tarfile.open(fileobj=crate_bytes, mode='w:gz') as archive:
    for name, data in {
        'Cargo.toml': b'[package]\nname="registry_dependency"\nversion="1.0.0"\nedition="2021"\n',
        'src/lib.rs': b'pub fn value() -> u32 { 42 }\n',
    }.items():
        entry = tarfile.TarInfo('registry_dependency-1.0.0/' + name)
        entry.size, entry.mode = len(data), 0o644
        archive.addfile(entry, io.BytesIO(data))


class RegistryHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0),
    functools.partial(RegistryHandler, directory=str(registry)))
server_thread = threading.Thread(target=server.serve_forever, daemon=True)
server_thread.start()
registry_url = 'http://127.0.0.1:' + str(server.server_port)
(registry / 'index/re/gi').mkdir(parents=True)
(registry / 'index/config.json').write_text(json.dumps({
    'dl': registry_url + '/crates/{crate}/{version}/download'}))
(registry / 'index/re/gi/registry_dependency').write_text(json.dumps({
    'name': 'registry_dependency', 'vers': '1.0.0', 'deps': [],
    'cksum': hashlib.sha256(crate_bytes.getvalue()).hexdigest(),
    'features': {}, 'yanked': False}) + '\n')
download = registry / 'crates/registry_dependency/1.0.0/download'
download.parent.mkdir(parents=True)
download.write_bytes(crate_bytes.getvalue())
(source / '.cargo').mkdir()
(source / '.cargo/config.toml').write_text('[registries.fixture]\nindex="sparse+' + registry_url + '/index/"\n')
(source / 'Cargo.toml').write_text('[package]\nname="cache-probe"\nversion="1.0.0"\nedition="2021"\n'
    '[dependencies]\ncache_dependency={git="' + dependency.as_uri() + '",rev="' + revision + '"}\n'
    'registry_dependency={version="=1.0.0",registry="fixture"}\n')
(source / 'src/main.rs').write_text('fn main() { println!("{}:{}", cache_dependency::value(), registry_dependency::value()); }\n')
try:
    require(['cargo', 'metadata', '--format-version', '1'], env=environment, cwd=source)
finally:
    server.shutdown()
    server.server_close()
    server_thread.join()
registry_file = next(ambient.glob('registry/cache/*/registry_dependency-1.0.0.crate'))
registry_bytes = registry_file.read_bytes()
unrelated_marker = ambient / 'registry/cache/fixture/payload.crate'
unrelated_marker.parent.mkdir(parents=True)
unrelated_marker.write_bytes(b'ambient registry marker\n')
seed = source.parent / '.cargo-home'

program = r'''
source "$1" || exit $?
shift
ACT_REPOS_DIR=$DSR_TEST_CONFIGS
ACT_ARTIFACTS_DIR=$DSR_TEST_ARTIFACTS
ACT_LOGS_DIR=$DSR_TEST_LOGS
_act_is_windows_host() { return 1; }
_act_is_local_host() { return 0; }
_act_get_host_platform() { printf '%s\n' "$DSR_TEST_PLATFORM"; }
_act_get_host_build_root() { printf '%s\n' "${DSR_TEST_BUILD_ROOT:-}"; }
act_get_native_host() { printf 'cache-fixture\n'; }
_act_ssh_exec() { bash -c "$2"; }
"$@"
'''


def shell(function, *args, env=None):
    return invoke(['bash', '-c', program, '_', module, function, *args], env=env or environment)


def metadata(label):
    result = shell('_act_strict_cargo_metadata_json', 'cache-fixture', str(source))
    if result.returncode:
        print(result.stderr.decode(), flush=True)
    check(label, result.returncode == 0)
    return json.loads(result.stdout)


def isolated_source(label):
    destination = work / ('admission-' + label) / 'source'
    shutil.copytree(source, destination)
    return destination


def admission_build(label, fixture_source, successful=True, expected='42:42', env=None):
    sentinel = work / (label + '-compiler-started')
    probe = work / (label + '-private-home')
    (configs / 'cache-probe.yaml').write_text(json.dumps({
        'tool_name': 'cache-probe', 'repo': 'fixture/cache-probe', 'local_path': str(fixture_source),
        'language': 'rust', 'binary_name': 'cache-probe', 'build_profile': 'debug',
        'linux_glibc_floor': 'native',
        'build_cmd': ('printf started > "$DSR_SOURCE_SENTINEL"; '
                      'printf "%s\\n" "$CARGO_HOME" > "$DSR_CACHE_PROBE"; '
                      'cargo build --quiet --locked --offline --target "$CARGO_BUILD_TARGET"'),
        'env': {'CARGO_BUILD_TARGET': triple, 'DSR_SOURCE_SENTINEL': str(sentinel),
                'DSR_CACHE_PROBE': str(probe)},
    }))
    result = shell('act_run_native_build', 'cache-probe', target, 'v1.0.0', label,
                   str(fixture_source), env=env)
    rows = [line for line in result.stdout.splitlines() if line.startswith(b'{')]
    report = json.loads(rows[-1]) if rows else {}
    if (result.returncode == 0) != successful:
        print(result.stderr.decode(), flush=True)
    if successful:
        check(label + ' compiles and collects through the native coordinator',
              result.returncode == 0 and report.get('status') == 'success' and sentinel.exists())
        check(label + ' collected executable uses the authentic dependency bytes',
              require([report['artifact_path']]).strip() == expected)
        return report, Path(probe.read_text().strip())
    check(label + ' refuses the native compiler and artifact admission',
          result.returncode != 0 and not sentinel.exists() and not report.get('artifact_paths') and
          not report.get('collected_sha256') and not (fixture_source.parent / '.cargo-home').exists())
    return report, None


def refused_download(label, damage):
    fixture_source = isolated_source(label)
    fixture_ambient = work / ('ambient-' + label)
    fixture_archive = fixture_ambient / registry_file.relative_to(ambient)
    fixture_archive.parent.mkdir(parents=True)
    shutil.copytree(ambient / 'registry/index', fixture_ambient / 'registry/index')
    shutil.copytree(registry_source.parent.parent,
                    fixture_ambient / registry_source.parent.parent.relative_to(ambient))
    shutil.copytree(git_source.parent.parent,
                    fixture_ambient / git_source.parent.parent.relative_to(ambient))
    if damage == 'linked-archive':
        fixture_archive.symlink_to(registry_file)
    elif damage != 'missing-archive':
        fixture_archive.write_bytes(b'not the locked crate archive\n' if damage == 'corrupt-archive' else registry_bytes)
    if damage != 'missing-git':
        fixture_database = fixture_ambient / git_database.relative_to(ambient)
        shutil.copytree(git_database, fixture_database)
        if damage == 'corrupt-git':
            object_path = fixture_database / 'objects' / revision[:2] / revision[2:]
            if not object_path.is_file():
                object_path = next((fixture_database / 'objects/pack').glob('*.pack'))
            object_path.chmod(object_path.stat().st_mode | 0o200)
            object_path.write_bytes(b'not a valid locked Git object\n')
    fixture_env = dict(environment, CARGO_HOME=str(fixture_ambient))
    if damage == 'missing-archive':
        check('the required archive was never populated before metadata', not fixture_archive.exists())
    if damage == 'missing-git':
        check('the required Git database was never populated before metadata',
              not (fixture_ambient / 'git/db').exists())
    refused = shell('_act_strict_cargo_metadata_json', 'cache-fixture', str(fixture_source), env=fixture_env)
    check(label + ' cannot authorize metadata or admit a retained seed',
          refused.returncode != 0 and not refused.stdout and not (fixture_source.parent / '.cargo-home').exists())
    if damage == 'missing-archive':
        check('the required archive is still absent before native admission', not fixture_archive.exists())
    if damage == 'missing-git':
        check('the required Git database is still absent before native admission',
              not (fixture_ambient / 'git/db').exists())
    admission_build(label, fixture_source, successful=False, env=fixture_env)


ambient.rename(work / 'warmed-ambient')
ambient.mkdir()
cold = shell('_act_strict_cargo_metadata_json', 'cache-fixture', str(source))
check('missing offline dependencies do not publish an incomplete retained seed',
      cold.returncode != 0 and not cold.stdout and not seed.exists() and
      b'offline' in cold.stderr)
ambient.rename(work / 'retained-empty-ambient')
(work / 'warmed-ambient').rename(ambient)


def baseline(label):
    target_dir = work / ('baseline-' + label)
    require(['cargo', 'build', '--quiet', '--locked', '--offline', '--target', triple],
            env=dict(environment, CARGO_TARGET_DIR=str(target_dir)), cwd=source)
    return require([target_dir / triple / 'debug/cache-probe']).strip()


check('real locked offline Cargo consumes the original registry and Git dependencies', baseline('original') == '42:42')
registry_source = next(ambient.glob('registry/src/*/registry_dependency-1.0.0/src/lib.rs'))
git_source = next((ambient / 'git/checkouts').rglob('src/lib.rs'))
git_database = next((ambient / 'git/db').iterdir())
# Issue #32: these objects belong to unrelated historical dependencies. They
# must neither enter the seed nor prevent the locked workspace from compiling.
unrelated_checkout = ambient / 'git/checkouts/unrelated-history/deadbeef/k9'
unrelated_checkout.mkdir(parents=True)
(unrelated_checkout / 'LICENSE').symlink_to('/missing/unrelated-cache-license')
unrelated_extraction = ambient / 'registry/src/unrelated-history/unused-99.0.0'
unrelated_extraction.mkdir(parents=True)
os.mkfifo(unrelated_extraction / 'unrelated-fifo')
large_archive = registry_file.parent / 'unused-99.0.0.crate'
with large_archive.open('wb') as output:
    output.truncate(1024 * 1024 * 1024)
scoped_source = isolated_source('unrelated-cache')
scoped_report, scoped_home = admission_build('unrelated-cache', scoped_source)
scoped_seed = scoped_source.parent / '.cargo-home'
scoped_receipt = json.loads((scoped_seed / '.dsr-cache-seed.json').read_bytes())
check('the admitted retained seed records its committed lockfile selection',
      scoped_receipt['selection']['kind'] == 'cargo-lock-downloads' and
      scoped_receipt['selection']['lockfile_sha256'] == digest(scoped_source / 'Cargo.lock'))
check('retained seeds and initial attempt inventories contain only locked downloads',
      not (scoped_seed / 'registry/src').exists() and not (scoped_seed / 'git/checkouts').exists() and
      all(not entry['path'].startswith(('registry/src/', 'git/checkouts/'))
          for entry in json.loads((scoped_home / '.dsr-cache-seed.json').read_bytes())['inventory']['files']))
for label, excluded in (('unrelated archive', large_archive), ('unrelated marker', unrelated_marker),
                        ('unrelated checkout symlink', unrelated_checkout / 'LICENSE'),
                        ('unrelated extracted FIFO', unrelated_extraction / 'unrelated-fifo')):
    relative = excluded.relative_to(ambient)
    check(label + ' never enters the retained or compiling Cargo home',
          not os.path.lexists(scoped_seed / relative) and not os.path.lexists(scoped_home / relative))
check('a one-GiB unrelated download leaves the real fixture seed below one MiB',
      large_archive.stat().st_size == 1024 * 1024 * 1024 and
      scoped_report['cargo_isolation']['dependency_cache']['seed']['size_bytes'] < 1024 * 1024)

# Registry-only releases commonly run on hosts whose unused Git cache lives on
# another volume. Resolve the real registry dependency, then keep that Git root
# as a symlink for both native metadata and compilation.
registry_only_source = isolated_source('registry-only')
(registry_only_source / 'Cargo.toml').write_text(
    '[package]\nname="cache-probe"\nversion="1.0.0"\nedition="2021"\n'
    '[dependencies]\nregistry_dependency={version="=1.0.0",registry="fixture"}\n')
(registry_only_source / 'src/main.rs').write_text('fn main() { println!("{}", registry_dependency::value()); }\n')
registry_only_ambient = work / 'registry-only-ambient'
registry_only_archive = registry_only_ambient / registry_file.relative_to(ambient)
registry_only_archive.parent.mkdir(parents=True)
registry_only_archive.write_bytes(registry_bytes)
shutil.copytree(ambient / 'registry/index', registry_only_ambient / 'registry/index')
(registry_only_ambient / 'git').symlink_to(ambient / 'git', target_is_directory=True)
registry_only_env = dict(environment, CARGO_HOME=str(registry_only_ambient))
require(['cargo', 'generate-lockfile', '--offline'], env=registry_only_env, cwd=registry_only_source)
registry_report, registry_home = admission_build('unused-git-root-link', registry_only_source,
                                               expected='42', env=registry_only_env)
check('registry-only admission never opens or copies the linked unused Git root',
      (registry_only_ambient / 'git').is_symlink() and not (registry_home / 'git').exists() and
      not (registry_only_source.parent / '.cargo-home/git').exists() and
      registry_report['cargo_isolation']['dependency_sources']['authentication']['locked_git_packages'] == 0)

for kind, cached_source, expected in (
    ('registry', registry_source, '42:43'), ('git', git_source, '43:42'),
):
    original = cached_source.read_bytes()
    cached_source.write_text('pub fn value() -> u32 { 43 }\n')
    check(kind + ' cache poison changes a genuine locked offline Cargo executable', baseline(kind + '-poison') == expected)
    report, private_home = admission_build(kind + '-extracted-poison', isolated_source(kind + '-poison'))
    private_source = private_home / cached_source.relative_to(ambient)
    check(kind + ' sources are recreated from locked downloads instead of poisoned extraction',
          private_source.read_bytes() == original and
          private_source.stat().st_ino != cached_source.stat().st_ino)
    cached_source.write_bytes(original)

# Discarding untrusted extractions must not turn missing or corrupt required
# downloads into a fallback to those extractions. Every case starts without a
# retained seed so an earlier successful build cannot mask the unavailable pin.
for label, damage in (
    ('corrupt-required-archive', 'corrupt-archive'),
    ('missing-required-archive', 'missing-archive'),
    ('linked-required-archive', 'linked-archive'),
    ('corrupt-required-git-object', 'corrupt-git'),
    ('missing-required-git-database', 'missing-git'),
):
    refused_download(label, damage)

(ambient / 'config.toml').write_text('[build]\nrustc-wrapper="/untrusted/operator-wrapper"\n')
(ambient / 'credentials.toml').write_text('private credentials must not be copied\n')
first_metadata = metadata('refilled ambient cache rescues metadata after an incomplete first attempt')
check('canonical seed uses plain registry and Git directories',
      seed.is_dir() and not seed.is_symlink() and
      all((seed / name).is_dir() and not (seed / name).is_symlink() for name in ('registry', 'git')))
check('ambient configuration and credentials never enter the seed',
      not (seed / 'config.toml').exists() and not (seed / 'credentials.toml').exists())
seed_receipt_hash = digest(seed / '.dsr-cache-seed.json')
private_registry = seed / registry_file.relative_to(ambient)
check('seed has independently owned registry inodes',
      private_registry.stat().st_ino != registry_file.stat().st_ino)
git_manifest = next(package['manifest_path'] for package in first_metadata['metadata']['packages']
                    if package['name'] == 'cache_dependency')
check('metadata runs in a fresh copy and never writes the retained seed',
      '.cargo-home-metadata-' in git_manifest and str(seed / 'git') not in git_manifest)
# Rename the ambient paths so their original names disappear, then mutate the
# retained original inodes. This covers both host cache pruning and in-place
# operator writes without deleting evidence.
ambient.rename(work / 'retained-ambient')
dependency.rename(work / 'retained-dependency')
(work / 'retained-ambient' / registry_file.relative_to(ambient)).write_bytes(b'operator replacement\n')
for file in (work / 'retained-ambient/git/checkouts').rglob('src/lib.rs'):
    file.write_text('compile_error!("ambient cache was modified");\n')
for file in (work / 'retained-ambient/registry/src').rglob('src/lib.rs'):
    file.write_text('compile_error!("ambient registry was modified");\n')
check('ambient mutation cannot change the retained seed bytes', private_registry.read_bytes() == registry_bytes)
second_metadata = metadata('resume metadata survives missing ambient registry and Git roots')
check('resume does not replace the seed receipt', digest(seed / '.dsr-cache-seed.json') == seed_receipt_hash)
second_git_manifest = next(package['manifest_path'] for package in second_metadata['metadata']['packages']
                           if package['name'] == 'cache_dependency')
check('metadata retries receive distinct private Cargo homes', second_git_manifest != git_manifest)
check('retained seeds remain download-only after multiple metadata attempts',
      not (seed / 'registry/src').exists() and not (seed / 'git/checkouts').exists())
lock_bytes = (source / 'Cargo.lock').read_bytes()
(source / 'Cargo.lock').write_bytes(lock_bytes + b'\n')
changed_lock = shell('_act_strict_cargo_metadata_json', 'cache-fixture', str(source))
check('a different lockfile cannot reuse the admitted retained seed',
      changed_lock.returncode != 0 and not changed_lock.stdout and
      digest(seed / '.dsr-cache-seed.json') == seed_receipt_hash)
(source / 'Cargo.lock').write_bytes(lock_bytes)
metadata('the original lockfile resumes after a refused selection change')

if mode == 'locked-downloads':
    print(f'Native locked downloads: {checks} assertions passed; real offline compilation and local transport.', flush=True)
    raise SystemExit(0)


def build(label, mutation='', successful=True, preparation='', extra_env=None):
    probe = work / ('home-' + str(checks))
    compiled = work / ('compiled-' + str(checks))
    command = ('printf "%s\\n" "$CARGO_HOME" > "$DSR_CACHE_PROBE"; ' + preparation +
               'cargo build --quiet --locked --offline --target "$CARGO_BUILD_TARGET" && '
               'printf compiled > "$DSR_CACHE_COMPILED"; ' + mutation)
    configuration = {
        'tool_name': 'cache-probe', 'repo': 'fixture/cache-probe', 'local_path': str(source),
        'language': 'rust', 'binary_name': 'cache-probe', 'build_profile': 'debug',
        'linux_glibc_floor': 'native', 'build_cmd': command,
        'env': {'CARGO_BUILD_TARGET': triple, 'DSR_CACHE_PROBE': str(probe), 'DSR_CACHE_COMPILED': str(compiled),
                'DSR_AMBIENT_CACHE_FILE': str(work / 'retained-ambient' / registry_file.relative_to(ambient))},
    }
    configuration['env'].update(extra_env or {})
    (configs / 'cache-probe.yaml').write_text(json.dumps(configuration))
    result = shell('act_run_native_build', 'cache-probe', target, 'v1.0.0', 'cache-run', str(source))
    rows = [line for line in result.stdout.splitlines() if line.startswith(b'{')]
    report = json.loads(rows[-1]) if rows else {}
    if not compiled.exists() or not (result.returncode == 0 if successful else result.returncode != 0):
        print(result.stderr.decode(), flush=True)
    if successful:
        check(label, result.returncode == 0 and report.get('status') == 'success' and compiled.exists())
    else:
        check(label, result.returncode != 0 and report.get('status') != 'success' and
              not report.get('artifact_paths') and not report.get('collected_sha256') and compiled.exists())
        (work / 'refused-result.json').write_text(json.dumps(report))
    return report, Path(probe.read_text().strip()) if probe.exists() else None


report, first_home = build('native offline compilation and collection survive an ambient cache wipe',
    'mkdir -p "$CARGO_HOME/registry/unpacked"; printf unpacked > "$CARGO_HOME/registry/unpacked/new-file"',
    preparation='mv "$CARGO_HOME/git/checkouts" "$CARGO_HOME/git/retained-checkouts"; ')
isolation = report['cargo_isolation']
cache = isolation['dependency_cache']
(work / 'native-result.json').write_text(json.dumps(report))
old_checkout = next((first_home / 'git/retained-checkouts').rglob('src/lib.rs'))
new_checkout = next((first_home / 'git/checkouts').rglob('src/lib.rs'))
check('real Cargo reconstructs its private Git checkout from cached objects offline',
      old_checkout.read_bytes() == new_checkout.read_bytes() and
      old_checkout.stat().st_ino != new_checkout.stat().st_ino)
check('native result records private ownership and both inventories',
      isolation['cache_reuse'] == [] and cache['mode'] == 'private-copy' and
      cache['seed']['mode'] == 'private-copy' and cache['final']['mode'] == 'inventory' and
      cache['final']['file_count'] > cache['seed']['file_count'])
sources = isolation['dependency_sources']
check('native source authority authenticates genuine registry archives and pinned Git objects',
      sources['authentication']['locked_archive_packages'] == 1 and
      sources['authentication']['locked_git_packages'] == 1 and
      sources['authentication']['lockfile_sha256'] == digest(source / 'Cargo.lock') and
      sources['metadata_sha256'] == digest(first_home / '.dsr-cargo-metadata.json') and
      sources['sha256'] == digest(first_home / '.dsr-cargo-sources.json'))
check('native environment and receipt bind the actual attempt home',
      str(first_home) == report['build_influence_env']['CARGO_HOME'] == isolation['cargo_home'] == cache['seed']['cargo_home'])
# bd-10we: the build's own shell attested the executables it ran.
toolchain = isolation.get('toolchain', {})
tools = toolchain.get('tools', {})


def attested(record):
    path = Path(record.get('resolved_path') or record['selected_path'])
    return path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == (
        record.get('resolved_sha256') or record['selected_sha256'])


check('strict build records cargo, rustc and linker identities from the build shell',
      toolchain.get('schema_version') == 1 and toolchain.get('target_triple') == triple and
      {'cargo', 'rustc', 'linker'} <= set(tools) and all(attested(tools[name]) for name in ('cargo', 'rustc', 'linker')))
check('attested rustc is the compiler that reports the build host',
      'host: ' in tools['rustc']['version'] and tools['rustc']['version'].startswith('rustc '))
check('toolchain receipt lives beside the snapshot, never inside it',
      Path(toolchain['cwd']).resolve() == source.resolve() and
      not any(source.rglob('.dsr-toolchain-*')) and any(source.parent.glob('.dsr-toolchain-*.json')))
check('collected executable runs with the committed dependency bytes',
      require([report['artifact_path']]).strip() == '42:42')
check('native build preserves the retained source seed receipt', digest(seed / '.dsr-cache-seed.json') == seed_receipt_hash)
second_report, second_home = build('a native retry compiles successfully with a fresh Cargo home')
check('native target attempts never reuse a mutable Cargo home',
      first_home != second_home and first_home.is_dir() and second_home.is_dir())
check('the completed private cache can be verified independently',
      invoke(['bash', root / 'src/cargo_cache.sh', 'verify', first_home, cache['final']['receipt_path']]).returncode == 0)

for label, mutation in (
    ('config-bearing final home', 'printf config > "$CARGO_HOME/config.toml"'),
    ('dangling configuration link', 'ln -s /missing/fixture-config "$CARGO_HOME/credentials.toml"'),
    ('nested cache symlink', 'ln -s /missing/fixture-cache "$CARGO_HOME/registry/linked"'),
    ('ambient hardlink graft', 'ln "$DSR_AMBIENT_CACHE_FILE" "$CARGO_HOME/registry/ambient-hardlink"'),
    ('special cache object', 'mkfifo "$CARGO_HOME/registry/fifo"'),
    ('modified seed receipt', 'printf "\\n" >> "$CARGO_HOME/.dsr-cache-seed.json"'),
    ('registry source mutation',
     'printf "\\n// changed after compilation\\n" >> "$CARGO_HOME"/registry/src/*/registry_dependency-1.0.0/src/lib.rs'),
    ('Git source mutation',
     'printf "\\n// changed after compilation\\n" >> "$CARGO_HOME"/git/checkouts/*/*/src/lib.rs'),
    ('metadata receipt mutation', 'printf "\\n" >> "$CARGO_HOME/.dsr-cargo-metadata.json"'),
    ('dependency source receipt mutation', 'printf "\\n" >> "$CARGO_HOME/.dsr-cargo-sources.json"'),
):
    build(label + ' refuses artifact admission after successful compilation', mutation, False)

# Configure this owned compiler wrapper before admission, then change its
# bytes after real compilation. An in-command export would instead be refused
# before launch and would not test the post-build toolchain identity gate.
compiler_wrapper = work / 'owned-rustc'
compiler_wrapper.write_text('#!/bin/sh\nexec ' + json.dumps(shutil.which('rustc')) + ' "$@"\n')
compiler_wrapper.chmod(0o700)
build('toolchain byte changes refuse artifact admission after successful compilation',
      'printf "\\n# changed after compilation\\n" >> "$RUSTC"', False,
      extra_env={'RUSTC': str(compiler_wrapper)})

retained_marker = seed / 'config.toml'
retained_marker.write_text('[net]\noffline=true\n')
blocked = shell('_act_strict_cargo_metadata_json', 'cache-fixture', str(source))
check('configuration added to the retained seed blocks resume', blocked.returncode != 0 and not blocked.stdout)
retained_marker.rename(work / 'retained-forbidden-config')
private_registry.write_bytes(b'changed private seed\n')
blocked = shell('_act_strict_cargo_metadata_json', 'cache-fixture', str(source))
check('changed retained seed bytes block resume', blocked.returncode != 0 and not blocked.stdout)
private_registry.write_bytes(registry_bytes)
metadata('restored seed resumes after a refused mutation')

prepared = shell('_act_prepare_unix_private_cargo_home', 'cache-fixture', str(source), 'collision-check')
check('explicit target copy is created successfully', prepared.returncode == 0)
prepared_home = Path(json.loads(prepared.stdout)['cargo_home'])
prepared_sources = json.loads(prepared.stdout)['dependency_sources']
verification = shell('_act_unix_cargo_sources_verify_script', str(source), str(prepared_home), json.dumps(prepared_sources))
check('held source authority produces an independently executable verifier', verification.returncode == 0)


def verify_prepared():
    return invoke(['bash', '-c', verification.stdout.decode()], env=environment)


check('held source authority verifies the actual private attempt before compilation', verify_prepared().returncode == 0)
# macOS presents /private/var through /var. Held metadata names physical paths,
# while the coordinator can legitimately retain a logical ancestor alias.
logical_parent = work / 'logical-snapshot'
logical_parent.symlink_to(source.parent, target_is_directory=True)
logical_verification = shell('_act_unix_cargo_sources_verify_script', str(logical_parent / 'source'),
                             str(prepared_home), json.dumps(prepared_sources))
check('logical source ancestor aliases verify against the held physical workspace',
      logical_verification.returncode == 0 and
      invoke(['bash', '-c', logical_verification.stdout.decode()], env=environment).returncode == 0)
alternate_source = work / 'alternate-snapshot/source'
shutil.copytree(source, alternate_source)
logical_parent.rename(work / 'retained-original-alias')
logical_parent.symlink_to(alternate_source.parent, target_is_directory=True)
check('retargeting a source ancestor alias cannot reuse held workspace authority',
      invoke(['bash', '-c', logical_verification.stdout.decode()], env=environment).returncode != 0)
for label, path in (
    ('registry bytes', next(prepared_home.glob('registry/src/*/registry_dependency-1.0.0/src/lib.rs'))),
    ('Git bytes', next((prepared_home / 'git/checkouts').rglob('src/lib.rs'))),
    ('metadata bytes', prepared_home / '.dsr-cargo-metadata.json'),
    ('source receipt bytes', prepared_home / '.dsr-cargo-sources.json'),
):
    original = path.read_bytes()
    path.write_bytes(original + b'\n')
    check('controller-held authority refuses altered ' + label, verify_prepared().returncode != 0)
    finish = shell('_act_finish_unix_private_cargo_home', 'cache-fixture', str(prepared_home),
                   json.loads(prepared.stdout)['receipt_sha256'], str(source), json.dumps(prepared_sources))
    check('independent final admission refuses altered ' + label, finish.returncode != 0 and not finish.stdout)
    path.write_bytes(original)
check('restored source bytes satisfy the original held authority', verify_prepared().returncode == 0)
marker = prepared_home / 'operator-evidence'
marker.write_bytes(b'preserve existing attempt')
collision = shell('_act_prepare_unix_private_cargo_home', 'cache-fixture', str(source), 'collision-check')
check('an existing attempt home is refused without overwriting it',
      collision.returncode != 0 and marker.read_bytes() == b'preserve existing attempt')

with ThreadPoolExecutor(max_workers=2) as workers:
    parallel = list(workers.map(lambda suffix: shell('_act_prepare_unix_private_cargo_home',
                                                    'cache-fixture', str(source), suffix),
                                ('parallel-one', 'parallel-two')))
check('concurrent target preparation succeeds from one retained seed',
      all(result.returncode == 0 for result in parallel))
parallel_summaries = [json.loads(result.stdout) for result in parallel]
parallel_homes = [Path(summary['cargo_home']) for summary in parallel_summaries]
parallel_files = [home / registry_file.relative_to(ambient) for home in parallel_homes]
parallel_files[0].write_bytes(b'one target changes its own dependency cache\n')
parallel_finished = shell('_act_finish_unix_private_cargo_home', 'cache-fixture', str(parallel_homes[1]),
                          parallel_summaries[1]['receipt_sha256'], str(source),
                          json.dumps(parallel_summaries[1]['dependency_sources']))
check('concurrent targets own independent cache inodes and mutations',
      parallel_homes[0] != parallel_homes[1] and
      parallel_files[0].stat().st_ino != parallel_files[1].stat().st_ino and
      parallel_files[1].read_bytes() == private_registry.read_bytes() and
      parallel_finished.returncode == 0 and
      invoke(['bash', root / 'src/cargo_cache.sh', 'verify', parallel_homes[1],
              json.loads(parallel_finished.stdout)['receipt_path']]).returncode == 0)

# Ordinary (non-strict) native builds stage their source under a fresh root and
# previously linked the ambient registry into it (issue #15). They now receive
# the same private copies. Build a fresh ambient with the cached Git
# dependency, then make the dependency's origin disappear.
ordinary_ambient = work / 'ordinary-ambient'
ordinary_ambient.mkdir()
shutil.copytree(seed / 'registry', ordinary_ambient / 'registry')
check('offline compilation cannot reconstruct usable Git origin sources',
      not dependency.exists() or not any(path.is_file() or path.is_symlink() for path in dependency.rglob('*')))
if dependency.exists():
    # Preserve any empty recreated parents before restoring the local origin
    # solely for the ordinary-build fixture's fresh Git cache warming.
    dependency.rename(work / 'retained-recreated-origin-parent')
(work / 'retained-dependency').rename(dependency)
ordinary_env = dict(environment, CARGO_HOME=str(ordinary_ambient))
require(['cargo', 'metadata', '--format-version', '1'], env=ordinary_env, cwd=source)
dependency.rename(work / 'retained-ordinary-dependency')
ordinary_registry = ordinary_ambient / 'registry/cache/fixture/payload.crate'
ordinary_registry.parent.mkdir(parents=True, exist_ok=True)
ordinary_registry.write_bytes(b'ordinary registry marker\n')
(ordinary_ambient / 'config.toml').write_text('[build]\nrustc-wrapper="/untrusted/operator-wrapper"\n')
(ordinary_ambient / 'credentials.toml').write_text('private credentials must not be copied\n')
ordinary_build_root = work / 'ordinary-build-root'
ordinary_build_root.mkdir()
ordinary_env['DSR_TEST_BUILD_ROOT'] = str(ordinary_build_root)
wiped_ambient = work / 'ordinary-ambient-wiped'


def ordinary_build(label, mutation='', successful=True, preparation=''):
    probe = work / ('ordinary-home-' + str(checks))
    command = ('printf "%s\\n" "$CARGO_HOME" > "$DSR_CACHE_PROBE"; ' + preparation +
               'cargo build --quiet --locked --offline --target "$CARGO_BUILD_TARGET"; ' + mutation)
    configuration = {
        'tool_name': 'cache-probe', 'repo': 'fixture/cache-probe', 'local_path': str(source),
        'language': 'rust', 'binary_name': 'cache-probe', 'build_profile': 'debug',
        'linux_glibc_floor': 'native', 'build_cmd': command,
        'env': {'CARGO_BUILD_TARGET': triple, 'DSR_CACHE_PROBE': str(probe),
                'DSR_ORDINARY_AMBIENT': str(ordinary_ambient), 'DSR_WIPED_AMBIENT': str(wiped_ambient)},
    }
    (configs / 'cache-probe.yaml').write_text(json.dumps(configuration))
    result = shell('act_run_native_build', 'cache-probe', target, 'v1.0.0', 'ordinary-run', env=ordinary_env)
    rows = [line for line in result.stdout.splitlines() if line.startswith(b'{')]
    report = json.loads(rows[-1]) if rows else {}
    if not (result.returncode == 0 if successful else result.returncode != 0):
        print(result.stderr.decode(), flush=True)
    if successful:
        check(label, result.returncode == 0 and report.get('status') == 'success')
    else:
        check(label, result.returncode != 0 and report.get('status') != 'success' and
              not report.get('artifact_paths') and not report.get('collected_sha256'))
    return report, Path(probe.read_text().strip()) if probe.exists() else None


# The ambient cache disappears after the build has started (a disk-hygiene
# pass on the host): the offline build must still find every dependency.
report, ordinary_home = ordinary_build(
    'ordinary native build compiles offline after the ambient cache is wiped mid-build',
    preparation='mv "$DSR_ORDINARY_AMBIENT" "$DSR_WIPED_AMBIENT"; ')
wiped_ambient.rename(ordinary_ambient)
isolation = report['cargo_isolation']
cache = isolation.get('dependency_cache', {})
check('ordinary result records a private copy instead of ambient cache reuse',
      isolation['mode'] == 'ephemeral-staged-source' and isolation['cache_reuse'] == [] and
      cache.get('mode') == 'private-copy' and cache['seed']['mode'] == 'private-copy' and
      cache['final']['mode'] == 'inventory' and sorted(cache['seed']['caches']) == ['git', 'registry'])
check('ordinary build ran with the recorded private Cargo home inside its stage root',
      ordinary_home is not None and ordinary_home.resolve() == Path(cache['seed']['cargo_home']) and
      str(ordinary_home).startswith(str(ordinary_build_root) + '/dsr-build-cache-probe-'))
ordinary_private_registry = ordinary_home / 'registry/cache/fixture/payload.crate'
check('ordinary private registry bytes are copied onto independent inodes',
      ordinary_private_registry.read_bytes() == b'ordinary registry marker\n' and
      not ordinary_private_registry.is_symlink() and
      ordinary_private_registry.stat().st_ino != ordinary_registry.stat().st_ino and
      not (ordinary_home / 'registry').is_symlink())
check('ordinary private home excludes ambient configuration and credentials',
      not (ordinary_home / 'config.toml').exists() and not (ordinary_home / 'credentials.toml').exists())
check('ordinary collected executable runs with the committed dependency bytes',
      require([report['artifact_path']]).strip() == '42:42')
ordinary_build('a config-bearing ordinary private home refuses artifact admission',
               'printf config > "$CARGO_HOME/config.toml"', False)
_, second_ordinary_home = ordinary_build('a second ordinary build compiles with a fresh private home')
check('ordinary builds never share a Cargo home',
      second_ordinary_home is not None and second_ordinary_home != ordinary_home)

print(f'Native Unix Cargo cache: {checks} assertions passed; real offline compilation and local transport.', flush=True)
PY
