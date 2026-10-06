#!/usr/bin/env bash
# Real stable/nightly regression for strict metadata and intermediate caching.
# Set DSR_TEST_STABLE_SYSROOT to an installed stable sysroot if `stable` is not
# installed. No toolchain is downloaded and all source/cache fixtures remain.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 bash cargo rustc rustup cc jq yq; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
python3 -I - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
module = Path(os.environ.get('DSR_TEST_ACT_RUNNER', str(root / 'src/act_runner.sh')))
work = Path(tempfile.mkdtemp(prefix='dsr-toolchain-parity-')).resolve()
print('Retained fixtures: ' + str(work), flush=True)
passed = failed = 0


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print('PASS ' + label, flush=True)
    else:
        failed += 1
        print('FAIL ' + label, flush=True)


def run(argv, **kwargs):
    return subprocess.run(list(map(str, argv)), capture_output=True, text=True, timeout=180, **kwargs)


def require(argv, **kwargs):
    result = run(argv, **kwargs)
    if result.returncode:
        raise AssertionError(str(argv) + '\n' + result.stderr)
    return result.stdout.strip()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


nightly_rustc = Path(require(['rustup', 'which', 'rustc'])).resolve()
nightly_root = Path(require([nightly_rustc, '--print', 'sysroot'])).resolve()
nightly_version = require([nightly_rustc, '-vV'])
if '-nightly' not in nightly_version:
    sys.exit('Run this cache regression with nightly Cargo/rustc >=1.91.1 selected')
stable_root = os.environ.get('DSR_TEST_STABLE_SYSROOT')
if not stable_root:
    found = run(['rustup', 'run', 'stable', 'rustc', '--print', 'sysroot'],
                env=dict(os.environ, RUSTUP_AUTO_INSTALL='0'))
    if found.returncode:
        sys.exit('Set DSR_TEST_STABLE_SYSROOT to an installed stable Rust sysroot')
    stable_root = found.stdout.strip()
stable_root = Path(stable_root).resolve()
stable_version = require([stable_root / 'bin/rustc', '-vV'])
if '-nightly' in stable_version:
    sys.exit('DSR_TEST_STABLE_SYSROOT must identify a genuine stable compiler')
host = next(line.split(': ', 1)[1] for line in nightly_version.splitlines() if line.startswith('host: '))

home = work / 'home'
home.mkdir()
(home / '.rustup').symlink_to(work / 'rustup', target_is_directory=True)
environment = dict(os.environ)
for name in list(environment):
    if name.startswith(('CARGO_', 'RUST')):
        environment.pop(name)
environment.update(HOME=str(home), RUSTUP_HOME=str(work / 'rustup'),
                   CARGO_HOME=str(work / 'ambient'), RUSTUP_AUTO_INSTALL='0',
                   RCH_DISABLED='1', RCH_CARGO_WRAPPER_BYPASS='1',
                   DSR_TEST_CONFIGS=str(work / 'repos.d'))
(work / 'ambient').mkdir()
(work / 'repos.d').mkdir()
for name, sysroot in (('fixture-stable', stable_root), ('fixture-nightly', nightly_root),
                     ('fixture-nightly-suffix', stable_root)):
    require(['rustup', 'toolchain', 'link', name, sysroot], env=environment)
require(['rustup', 'default', 'fixture-stable'], env=environment)
environment['RUSTUP_TOOLCHAIN'] = 'fixture-stable'

source = work / 'snapshot' / 'project'
(source / 'src').mkdir(parents=True)
(source / 'Cargo.toml').write_text(
    'cargo-features=["profile-rustflags"]\n[package]\nname="metadata-probe"\nversion="1.0.0"\n'
    'edition="2021"\n[profile.dev]\nrustflags=[]\n[dependencies]\n'
    'parity-dep={path="../dep",optional=true}\n')
(source / 'src/main.rs').write_text('fn main() { println!("42"); }\n')
dependency = source.parent / 'dep'
(dependency / 'src').mkdir(parents=True)
(dependency / 'Cargo.toml').write_text('[package]\nname="parity-dep"\nversion="1.0.0"\nedition="2021"\n')
(dependency / 'src/lib.rs').write_text('pub fn value() -> u32 { 42 }\n')
require(['cargo', '+fixture-nightly', 'generate-lockfile', '--offline'], cwd=source, env=environment)
inputs = {str(path): digest(path) for directory in (source, dependency)
          for path in directory.rglob('*') if path.is_file()}
dependencies = json.dumps([{'relative_path': 'dep', 'local_path': str(dependency), 'git_sha': '1' * 40}])
build_env = 'RUSTUP_HOME=' + environment['RUSTUP_HOME'] + '\nRUSTUP_TOOLCHAIN=fixture-stable'
nightly_command = 'cargo +fixture-nightly build --offline'

program = '''
source "$1" || exit $?
shift
ACT_REPOS_DIR=$DSR_TEST_CONFIGS
_act_is_windows_host() { return 1; }
_act_is_local_host() { return 0; }
_act_ssh_exec() { bash -e -c "$2"; }
"$@"
'''
counter = 0


def shell(function, *args, env=None):
    global counter
    counter += 1
    result = run(['bash', '-c', program, '_', module, function, *args], env=env or environment)
    (work / ('probe-' + str(counter) + '.stdout')).write_text(result.stdout)
    (work / ('probe-' + str(counter) + '.stderr')).write_text(result.stderr)
    return result


def metadata(command=nightly_command, configured=build_env):
    return shell('_act_strict_cargo_metadata_json', 'fixture', source, command, configured)


direct_stable = run(['cargo', '+fixture-stable', 'metadata', '--locked', '--offline', '--format-version=1'],
                    cwd=source, env=environment)
check('real stable Cargo refuses the nightly-only manifest',
      direct_stable.returncode != 0 and 'requires a nightly version of Cargo' in direct_stable.stderr)
result = metadata()
check('strict metadata honors +nightly despite the real stable default', result.returncode == 0)
snapshot = json.loads(result.stdout) if result.returncode == 0 else {}
check('selected offline metadata includes optional pinned path dependencies',
      {package['name'] for package in snapshot.get('metadata', {}).get('packages', [])} ==
      {'metadata-probe', 'parity-dep'})
seed = source.parent / '.cargo-home'
check('successful selected metadata admits the private download seed',
      (seed / '.dsr-cache-seed.json').is_file())
seed_digest = digest(seed / '.dsr-cache-seed.json') if seed.exists() else None
result = metadata('cargo +fixture-stable build --offline')
check('a shared admitted seed does not bypass an incompatible target toolchain',
      result.returncode != 0 and 'requires a nightly version of Cargo' in result.stderr)
result = shell('_act_prepare_unix_private_cargo_home', 'fixture', source, 'nightly-attempt',
               nightly_command, build_env)
check('direct native preparation resolves metadata with its selected toolchain', result.returncode == 0)
result = shell('_act_prepare_unix_private_cargo_home', 'fixture', source, 'stable-attempt',
               'cargo +fixture-stable build --offline', build_env)
check('direct native preparation revalidates toolchain compatibility on a warm seed',
      result.returncode != 0 and 'requires a nightly version of Cargo' in result.stderr)
result = metadata('cargo build --offline', build_env + '\nRUSTUP_TOOLCHAIN=fixture-nightly')
check('metadata restores configured RUSTUP_TOOLCHAIN after ambient cleanup', result.returncode == 0)
result = metadata('RUSTUP_TOOLCHAIN=fixture-nightly cargo build --offline')
check('metadata honors a literal command-scoped Rustup selection', result.returncode == 0)
result = metadata(nightly_command + ' --manifest-path ./Cargo.toml')
check('metadata accepts an explicit canonical root manifest', result.returncode == 0)
result = shell('_act_validate_strict_cargo_source_closure', 'fixture', source, dependencies,
               nightly_command, build_env)
check('selected metadata passes the exact pinned source closure', result.returncode == 0)
result = shell('_act_validate_strict_cargo_source_closure', 'fixture', source, '[]',
               nightly_command, build_env)
check('selected metadata still refuses an unpinned optional local dependency',
      result.returncode != 0 and 'unpinned local package root' in result.stderr)

config = {'language': 'rust', 'binary_name': 'nightly', 'build_cmd': 'cargo +fixture-stable build --offline',
          'env': {'RUSTUP_HOME': environment['RUSTUP_HOME'], 'RUSTUP_TOOLCHAIN': 'fixture-stable'},
          'cross_compile': {'linux/amd64': {'build_cmd': 'cargo +fixture-${name} build --offline'}}}
(work / 'repos.d/tool.yaml').write_text(json.dumps(config))
result = shell('_act_validate_strict_target_cargo_source_closure', 'tool', 'linux/amd64', '1.0.0',
               'fixture', source, dependencies)
check('target closure uses its command override and resolved build tokens', result.returncode == 0)
result = shell('_act_validate_strict_target_cargo_source_closure', 'tool', 'linux/arm64', '1.0.0',
               'fixture', source, dependencies)
check('another target on the same host keeps its own incompatible compiler selection',
      result.returncode != 0 and 'requires a nightly version of Cargo' in result.stderr)
for label, command in (
        ('dynamic', 'cargo +"$UNREVIEWED_TOOLCHAIN" build --offline'),
        ('conflicting', 'cargo +fixture-nightly build; cargo +fixture-stable build')):
    result = metadata(command)
    check(label + ' metadata selection refuses before guessing a compiler',
          result.returncode != 0 and 'toolchain identity:' in result.stderr)
check('all metadata attempts preserve the immutable source inputs',
      inputs == {str(path): digest(path) for directory in (source, dependency)
                 for path in directory.rglob('*') if path.is_file()})
check('later target failures preserve the admitted seed receipt',
      seed_digest is not None and digest(seed / '.dsr-cache-seed.json') == seed_digest)

cache = work / 'cache'
cache.mkdir(mode=0o700)
cache_source = work / 'cache-source'
(cache_source / 'src').mkdir(parents=True)
(cache_source / 'Cargo.toml').write_text('[package]\nname="cache-probe"\nversion="1.0.0"\nedition="2021"\n')
(cache_source / 'Cargo.lock').write_text('version = 4\n[[package]]\nname = "cache-probe"\nversion = "1.0.0"\n')
(cache_source / 'src/main.rs').write_text('fn main() { println!("42"); }\n')
second_source = work / 'second-source'
shutil.copytree(cache_source, second_source)
(second_source / 'src/main.rs').write_text('fn main() { println!("99"); }\n')
for directory in (cache_source, second_source):
    for path in directory.rglob('*'):
        if path.is_file():
            os.utime(path, ns=(1_000_000_000, 1_000_000_000))
cache_contract = json.dumps({'tool': 'cache-probe', 'platform': 'native', 'profile': 'dev'})
cache_program = 'source "$1" || exit $?; script=$(_act_strict_cargo_cache_script "$2" "$3" "$4") || exit $?; bash -e -c "$script"'


def cached(label, command, env=None, cwd=None):
    target = work / ('output-' + label)
    effective_env = dict(env or environment, CARGO_TARGET_DIR=str(target))
    result = run(['bash', '-c', cache_program, '_', module, cache, cache_contract, command],
                 cwd=cwd or cache_source, env=effective_env)
    (work / ('cache-' + label + '.stdout')).write_text(result.stdout)
    (work / ('cache-' + label + '.stderr')).write_text(result.stderr)
    receipt_path = target.with_name(target.name + '.cache-receipt.json')
    receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
    return result, target, receipt


def marker_value(path):
    result = run([path]) if path.exists() else None
    return result.stdout.strip() if result and result.returncode == 0 else None


command = 'cargo +fixture-nightly build --frozen --message-format=json'
result, target, receipt = cached('nightly', command)
check('intermediate cache builds with explicit nightly over a stable default',
      result.returncode == 0 and marker_value(target / 'debug/cache-probe') == '42')
compilers = receipt.get('contract', {}).get('compilers', {})
check('cache receipt binds the actual selected Cargo and rustc executable bytes',
      compilers.get('cargo', {}).get('executable_sha256') == digest(nightly_root / 'bin/cargo') and
      compilers.get('rustc', {}).get('executable_sha256') == digest(nightly_rustc))
check('cache records selected nightly versions and the effective Rustup environment',
      '-nightly' in receipt.get('contract', {}).get('cargo', '') and
      receipt.get('contract', {}).get('rustc') == nightly_version and
      receipt.get('contract', {}).get('environment', {}).get('RUSTUP_TOOLCHAIN') == 'fixture-nightly')
result, second_target, second_receipt = cached('second', command, cwd=second_source)
check('equal old timestamps still rebuild changed source under the selected toolchain',
      result.returncode == 0 and marker_value(second_target / 'debug/cache-probe') == '99')
check('compiler context retains cache reuse across distinct immutable source paths',
      bool(receipt) and receipt.get('namespace') == second_receipt.get('namespace'))

nightly_env = dict(environment, RUSTUP_TOOLCHAIN='fixture-nightly')
marker = work / 'stable-started'
result, target, refused_receipt = cached('stable',
    'printf started > ' + shlex.quote(str(marker)) + '; cargo +fixture-stable build --frozen', nightly_env)
check('incompatible explicit stable Cargo is refused before the build command starts',
      result.returncode != 0 and not marker.exists() and not target.exists() and not refused_receipt and
      ('Cargo >=1.91.1' in result.stderr or 'requires nightly Cargo/rustc' in result.stderr))

marker = work / 'override-started'
override_env = dict(nightly_env, CARGO_BUILD_RUSTC=str(stable_root / 'bin/rustc'))
result, target, refused_receipt = cached('compiler-override',
    'printf started > ' + shlex.quote(str(marker)) + '; ' + command, override_env)
check('CARGO_BUILD_RUSTC stable override is refused by the selected compiler capability gate',
      result.returncode != 0 and not marker.exists() and not target.exists() and not refused_receipt and
      'requires nightly Cargo/rustc' in result.stderr)

config_source = work / 'config-source'
shutil.copytree(cache_source, config_source)
(config_source / '.cargo').mkdir()
(config_source / '.cargo/config.toml').write_text('[build]\nrustc=' + json.dumps(str(stable_root / 'bin/rustc')) + '\n')
marker = work / 'config-started'
result, target, refused_receipt = cached('config-compiler',
    'printf started > ' + shlex.quote(str(marker)) + '; ' + command, nightly_env, config_source)
check('tracked Cargo compiler selection reaches the cache capability gate',
      result.returncode != 0 and not marker.exists() and not target.exists() and not refused_receipt and
      'requires nightly Cargo/rustc' in result.stderr)

wrapper = work / 'unknown-rustc'
wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(str(nightly_rustc)) + ' "$@"\n')
wrapper.chmod(0o700)
result, target, refused_receipt = cached('unknown-wrapper', command, dict(nightly_env, RUSTC=str(wrapper)))
check('matching-version compiler scripts remain outside the cache authority contract',
      result.returncode != 0 and not target.exists() and not refused_receipt and
      'unrecognized selected compiler script' in result.stderr)

linker = work / 'target-linker'
linker.write_text('#!/bin/sh\nexec ' + shlex.quote(shutil.which('cc')) + ' "$@"\n')
linker.chmod(0o700)
linker_key = 'CARGO_TARGET_' + host.replace('-', '_').upper() + '_LINKER'
target_env = dict(environment, CARGO_BUILD_TARGET='unselected-host-target')
target_env[linker_key] = str(linker)
result, target, target_receipt = cached('target-linker', command + ' --target ' + host, target_env)
check('cache builds through the explicit target despite a conflicting ambient target',
      result.returncode == 0 and marker_value(target / host / 'debug/cache-probe') == '42')
toolchain = target_receipt.get('contract', {}).get('toolchain', {})
check('cache namespace binds the effective target linker bytes',
      toolchain.get('target_triple') == host and
      toolchain.get('tools', {}).get('linker', {}).get('selected_sha256') == digest(linker) and
      bool(receipt) and target_receipt.get('namespace') != receipt.get('namespace'))

result, target, refused_receipt = cached('conflicting',
    'cargo +fixture-nightly build; cargo +fixture-stable build', nightly_env)
check('conflicting cache compiler selections refuse before producing outputs',
      result.returncode != 0 and not target.exists() and not refused_receipt and
      'conflicting Cargo toolchain' in result.stderr)
for variable, value in (('CARGO_UNSTABLE_CHECKSUM_FRESHNESS', 'false'),
                        ('CARGO_BUILD_FINGERPRINT', 'mtime'),
                        ('CARGO_BUILD_BUILD_DIR', str(work / 'unmanaged-intermediates'))):
    marker = work / (variable.lower() + '-started')
    # Keep the same value in the incoming environment: command-scoped
    # assignment must be recognized even when it is not an environment delta.
    result, target, refused_receipt = cached(variable.lower(),
        'printf started > ' + shlex.quote(str(marker)) + '; ' + variable + '=' +
        shlex.quote(value) + ' ' + command, dict(nightly_env, **{variable: value}))
    check(variable + ' command override refuses before bypassing cache enforcement',
          result.returncode != 0 and not marker.exists() and not target.exists() and not refused_receipt and
          'cannot override managed cache custody or freshness settings' in result.stderr)

nested = cache_source / 'nested'
(nested / 'src').mkdir(parents=True)
(nested / 'Cargo.toml').write_text('[workspace]\n[package]\nname="nested-probe"\nversion="1.0.0"\nedition="2021"\n')
(nested / 'src/main.rs').write_text('fn main() {}\n')
(nested / 'build.rs').write_text('fn main() {}\n')
require(['cargo', '+fixture-nightly', 'generate-lockfile', '--offline', '--manifest-path', nested / 'Cargo.toml'],
        cwd=cache_source, env=nightly_env)
nested_metadata = json.loads(require(['cargo', '+fixture-nightly', 'metadata', '--frozen', '--all-features',
                                     '--format-version=1', '--manifest-path', nested / 'Cargo.toml'],
                                    cwd=cache_source, env=nightly_env))
check('alternate manifest fixture contains a real independent build-script graph',
      any('custom-build' in target['kind'] for package in nested_metadata['packages'] for target in package['targets']))
result = shell('_act_strict_cargo_metadata_json', 'fixture', cache_source,
               command + ' --manifest-path nested/Cargo.toml', build_env)
check('strict metadata refuses to attest another workspace from the root manifest',
      result.returncode != 0 and not result.stdout and
      'manifest differs from the strict source root' in result.stderr)
for label, manifest_arg in (('separate', '--manifest-path nested/Cargo.toml'),
                            ('equals', '--manifest-path=nested/Cargo.toml'),
                            ('short', '-m nested/Cargo.toml')):
    marker = work / ('manifest-' + label + '-started')
    result, target, refused_receipt = cached('manifest-' + label,
        'printf started > ' + shlex.quote(str(marker)) + '; ' + command + ' ' + manifest_arg, nightly_env)
    check(label + ' alternate manifest refuses before bypassing the admitted dependency graph',
          result.returncode != 0 and not marker.exists() and not target.exists() and not refused_receipt and
          'manifest differs from the strict source root' in result.stderr)
result, target, explicit_receipt = cached('root-manifest', command + ' --manifest-path ./Cargo.toml')
check('cache accepts an explicit canonical root manifest',
      result.returncode == 0 and marker_value(target / 'debug/cache-probe') == '42' and bool(explicit_receipt))

# Representative shell-state changes must be rejected during preflight, even
# when a direct Cargo command appears elsewhere in the same command list.
require(['rustup', 'default', 'fixture-nightly'], env=environment)
declared = require(['bash', '-c', 'declare -x RUSTUP_TOOLCHAIN=fixture-stable; cargo --version'],
                   cwd=cache_source, env=nightly_env)
check('Bash declaration fixture actually selects the genuine stable Cargo',
      declared == require([stable_root / 'bin/cargo', '-V']))
class_results = []
for label, prefix, suffix, selected_env in (
        ('declare', 'declare -x RUSTUP_TOOLCHAIN=fixture-stable; ', '', nightly_env),
        ('printf-variable', 'printf -v RUSTUP_TOOLCHAIN %s fixture-stable; ', '', nightly_env),
        ('builtin', 'builtin export RUSTUP_TOOLCHAIN=fixture-stable; ', '', nightly_env),
        ('command-options', 'command -p export RUSTUP_TOOLCHAIN=fixture-stable; ', '', nightly_env),
        ('nested-command', 'command command export RUSTUP_TOOLCHAIN=fixture-stable; ', '', nightly_env),
        ('conditional', 'if true; then export RUSTUP_TOOLCHAIN=fixture-stable; fi; ', '', nightly_env),
        ('lookup', 'hash -p ' + shlex.quote(str(stable_root / 'bin/cargo')) + ' cargo; ', '', nightly_env),
        ('append', 'RUSTUP_TOOLCHAIN+=-suffix; ', '', nightly_env),
        ('parameter', 'printf "%s" "${RUSTUP_TOOLCHAIN:=fixture-stable}"; ', '',
         dict(nightly_env, RUSTUP_TOOLCHAIN='')),
        ('early-exit', '', '; exit 0', nightly_env)):
    marker = work / (label + '-context-started')
    result, target, refused_receipt = cached('context-' + label,
        prefix + 'printf started > ' + shlex.quote(str(marker)) + '; cargo build --frozen' + suffix,
        selected_env)
    class_results.append(result.returncode != 0 and not marker.exists() and not target.exists() and
                         not refused_receipt and 'toolchain identity:' in result.stderr)
check('shell mutation and control classes refuse before any build command starts', all(class_results))
marker = work / 'declared-freshness-started'
result, target, refused_receipt = cached('declared-freshness',
    'declare -x CARGO_UNSTABLE_CHECKSUM_FRESHNESS=false; printf started > ' + shlex.quote(str(marker)) +
    '; ' + command, nightly_env)
check('declaration cannot disable enforced cache freshness after preflight',
      result.returncode != 0 and not marker.exists() and not target.exists() and not refused_receipt and
      'Cargo context changes inside build_cmd' in result.stderr)
print('Toolchain metadata/cache: ' + str(passed) + ' passed, ' + str(failed) +
      ' failed; fixtures retained at ' + str(work), flush=True)
sys.exit(1 if failed else 0)
PY
