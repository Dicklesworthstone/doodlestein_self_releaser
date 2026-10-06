#!/usr/bin/env bash
# Native Unix metadata, compilation and artifact admission with private Cargo
# caches. Git/Cargo/filesystem operations are real; SSH is executed locally.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 bash git cargo rustc jq yq; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
python3 -I - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

root = Path(sys.argv[1])
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
(source / 'Cargo.toml').write_text('[package]\nname="cache-probe"\nversion="1.0.0"\nedition="2021"\n'
    '[dependencies]\ncache_dependency={git="' + dependency.as_uri() + '",rev="' + revision + '"}\n')
(source / 'src/main.rs').write_text('fn main() { println!("{}", cache_dependency::value()); }\n')
# Only the local file:// Git dependency is fetched; this fixture has no registry
# dependencies or external network service. Subsequent phases are offline.
require(['cargo', 'metadata', '--format-version', '1', '--manifest-path', source / 'Cargo.toml'], env=environment)
registry_file = ambient / 'registry/cache/fixture/payload.crate'
registry_file.parent.mkdir(parents=True)
registry_file.write_bytes(b'ambient registry marker\n')
(ambient / 'config.toml').write_text('[build]\nrustc-wrapper="/untrusted/operator-wrapper"\n')
(ambient / 'credentials.toml').write_text('private credentials must not be copied\n')
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
    check(label, result.returncode == 0)
    return json.loads(result.stdout)


ambient.rename(work / 'warmed-ambient')
ambient.mkdir()
cold = shell('_act_strict_cargo_metadata_json', 'cache-fixture', str(source))
check('missing offline dependencies do not publish an incomplete retained seed',
      cold.returncode != 0 and not cold.stdout and not seed.exists() and
      b'offline' in cold.stderr)
ambient.rename(work / 'retained-empty-ambient')
(work / 'warmed-ambient').rename(ambient)
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
check('ambient mutation cannot change the retained seed bytes', private_registry.read_bytes() == b'ambient registry marker\n')
second_metadata = metadata('resume metadata survives missing ambient registry and Git roots')
check('resume does not replace the seed receipt', digest(seed / '.dsr-cache-seed.json') == seed_receipt_hash)
second_git_manifest = next(package['manifest_path'] for package in second_metadata['metadata']['packages']
                           if package['name'] == 'cache_dependency')
check('metadata retries receive distinct private Cargo homes', second_git_manifest != git_manifest)


def build(label, mutation='', successful=True, preparation=''):
    probe = work / ('home-' + str(checks))
    command = ('printf "%s\\n" "$CARGO_HOME" > "$DSR_CACHE_PROBE"; ' + preparation +
               'cargo build --quiet --locked --offline --target "$CARGO_BUILD_TARGET"; ' + mutation)
    configuration = {
        'tool_name': 'cache-probe', 'repo': 'fixture/cache-probe', 'local_path': str(source),
        'language': 'rust', 'binary_name': 'cache-probe', 'build_profile': 'debug',
        'linux_glibc_floor': 'native', 'build_cmd': command,
        'env': {'CARGO_BUILD_TARGET': triple, 'DSR_CACHE_PROBE': str(probe),
                'DSR_AMBIENT_CACHE_FILE': str(work / 'retained-ambient' / registry_file.relative_to(ambient))},
    }
    (configs / 'cache-probe.yaml').write_text(json.dumps(configuration))
    result = shell('act_run_native_build', 'cache-probe', target, 'v1.0.0', 'cache-run', str(source))
    rows = [line for line in result.stdout.splitlines() if line.startswith(b'{')]
    report = json.loads(rows[-1]) if rows else {}
    if not (result.returncode == 0 if successful else result.returncode != 0):
        print(result.stderr.decode(), flush=True)
    if successful:
        check(label, result.returncode == 0 and report.get('status') == 'success')
    else:
        check(label, result.returncode != 0 and report.get('status') != 'success' and
              not report.get('artifact_paths') and not report.get('collected_sha256'))
        (work / 'refused-result.json').write_text(json.dumps(report))
    return report, Path(probe.read_text().strip()) if probe.exists() else None


report, first_home = build('native offline compilation and collection survive an ambient cache wipe',
    'mkdir -p "$CARGO_HOME/registry/unpacked"; printf unpacked > "$CARGO_HOME/registry/unpacked/new-file"',
    preparation='mv "$CARGO_HOME/git/checkouts" "$CARGO_HOME/retained-checkouts"; ')
isolation = report['cargo_isolation']
cache = isolation['dependency_cache']
(work / 'native-result.json').write_text(json.dumps(report))
old_checkout = next((first_home / 'retained-checkouts').rglob('src/lib.rs'))
new_checkout = next((first_home / 'git/checkouts').rglob('src/lib.rs'))
check('real Cargo reconstructs its private Git checkout from cached objects offline',
      old_checkout.read_bytes() == new_checkout.read_bytes() and
      old_checkout.stat().st_ino != new_checkout.stat().st_ino)
check('native result records private ownership and both inventories',
      isolation['cache_reuse'] == [] and cache['mode'] == 'private-copy' and
      cache['seed']['mode'] == 'private-copy' and cache['final']['mode'] == 'inventory' and
      cache['final']['file_count'] > cache['seed']['file_count'])
check('native environment and receipt bind the actual attempt home',
      str(first_home) == report['build_influence_env']['CARGO_HOME'] == isolation['cargo_home'] == cache['seed']['cargo_home'])
check('collected executable runs with the committed dependency bytes',
      require([report['artifact_path']]).strip() == '42')
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
):
    build(label + ' refuses artifact admission after successful compilation', mutation, False)

retained_marker = seed / 'config.toml'
retained_marker.write_text('[net]\noffline=true\n')
blocked = shell('_act_strict_cargo_metadata_json', 'cache-fixture', str(source))
check('configuration added to the retained seed blocks resume', blocked.returncode != 0 and not blocked.stdout)
retained_marker.rename(work / 'retained-forbidden-config')
private_registry.write_bytes(b'changed private seed\n')
blocked = shell('_act_strict_cargo_metadata_json', 'cache-fixture', str(source))
check('changed retained seed bytes block resume', blocked.returncode != 0 and not blocked.stdout)
private_registry.write_bytes(b'ambient registry marker\n')
metadata('restored seed resumes after a refused mutation')

prepared = shell('_act_prepare_unix_private_cargo_home', 'cache-fixture', str(source), 'collision-check')
check('explicit target copy is created successfully', prepared.returncode == 0)
prepared_home = Path(json.loads(prepared.stdout)['cargo_home'])
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
check('concurrent targets own independent cache inodes and mutations',
      parallel_homes[0] != parallel_homes[1] and
      parallel_files[0].stat().st_ino != parallel_files[1].stat().st_ino and
      parallel_files[1].read_bytes() == private_registry.read_bytes() and
      invoke(['bash', root / 'src/cargo_cache.sh', 'verify', parallel_homes[1],
              parallel_summaries[1]['receipt_path']]).returncode == 0)

# Ordinary (non-strict) native builds stage their source under a fresh root and
# previously linked the ambient registry into it (issue #15). They now receive
# the same private copies. Build a fresh ambient with the cached Git
# dependency, then make the dependency's origin disappear.
ordinary_ambient = work / 'ordinary-ambient'
ordinary_ambient.mkdir()
(work / 'retained-dependency').rename(dependency)
ordinary_env = dict(environment, CARGO_HOME=str(ordinary_ambient))
require(['cargo', 'metadata', '--format-version', '1', '--manifest-path', source / 'Cargo.toml'], env=ordinary_env)
dependency.rename(work / 'retained-ordinary-dependency')
ordinary_registry = ordinary_ambient / 'registry/cache/fixture/payload.crate'
ordinary_registry.parent.mkdir(parents=True)
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
      require([report['artifact_path']]).strip() == '42')
ordinary_build('a config-bearing ordinary private home refuses artifact admission',
               'printf config > "$CARGO_HOME/config.toml"', False)
_, second_ordinary_home = ordinary_build('a second ordinary build compiles with a fresh private home')
check('ordinary builds never share a Cargo home',
      second_ordinary_home is not None and second_ordinary_home != ordinary_home)

print(f'Native Unix Cargo cache: {checks} assertions passed; real offline compilation and local transport.', flush=True)
PY
