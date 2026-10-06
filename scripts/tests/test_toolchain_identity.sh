#!/usr/bin/env bash
# Exercise the strict Unix identity probe with real Cargo/rustc executables.
# Rustup state and the compiled project are private; no toolchain is installed
# or modified. The second toolchain has its own real executable copies.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 bash cargo rustc rustup cc; do
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
work = Path(tempfile.mkdtemp(prefix='dsr-toolchain-identity-')).resolve()
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
    return subprocess.run(list(map(str, argv)), capture_output=True, text=True, timeout=120, **kwargs)


def require(argv, **kwargs):
    result = run(argv, **kwargs)
    if result.returncode:
        raise AssertionError(str(argv) + '\n' + result.stderr)
    return result.stdout.strip()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


real_cargo = Path(require(['rustup', 'which', 'cargo'])).resolve()
real_rustc = Path(require(['rustup', 'which', 'rustc'])).resolve()
real_sysroot = Path(require([real_rustc, '--print', 'sysroot'])).resolve()
host = next(line.split(': ', 1)[1] for line in require([real_rustc, '-vV']).splitlines()
            if line.startswith('host: '))
selected = work / 'selected-toolchain'
(selected / 'bin').mkdir(parents=True)
alternate_sysroot = Path(os.environ.get('DSR_TEST_ALTERNATE_SYSROOT', str(real_sysroot))).resolve()
for name, source in (('cargo', alternate_sysroot / 'bin/cargo'), ('rustc', alternate_sysroot / 'bin/rustc')):
    shutil.copy2(source, selected / 'bin' / name)
# Both compilers use real installed standard libraries, but their executable
# paths/inodes differ. This proves +toolchain routing without network access.
(selected / 'lib').symlink_to(alternate_sysroot / 'lib', target_is_directory=True)
project = work / 'project'
(project / 'src').mkdir(parents=True)
(project / 'Cargo.toml').write_text('[package]\nname="identity-probe"\nversion="1.0.0"\nedition="2021"\n')
(project / 'src/main.rs').write_text('fn main() { println!("42"); }\n')
environment = dict(os.environ)
for name in list(environment):
    if name.startswith(('CARGO_', 'RUST')):
        environment.pop(name)
environment.update(RUSTUP_HOME=str(work / 'rustup'), CARGO_HOME=str(work / 'cargo'),
                   RUSTUP_AUTO_INSTALL='0', RCH_DISABLED='1', RCH_CARGO_WRAPPER_BYPASS='1')
require(['rustup', 'toolchain', 'link', 'fixture-default', real_sysroot], env=environment)
require(['rustup', 'toolchain', 'link', 'fixture-selected', selected], env=environment)
require(['rustup', 'default', 'fixture-default'], env=environment)
environment['RUSTUP_TOOLCHAIN'] = 'fixture-default'
environment['CARGO_BUILD_TARGET'] = host

program = '''source "$1" || exit $?; _act_toolchain_identity_script "$2" "$3" "$4" | bash'''
counter = 0


def probe(command, env=None, mode='record', receipt=None):
    global counter
    counter += 1
    if receipt is None:
        receipt = work / ('receipt-' + str(counter) + '.json')
    result = run(['bash', '-o', 'pipefail', '-c', program, '_', module, mode, receipt, command],
                 cwd=project, env=env or environment)
    data = json.loads(receipt.read_text()) if receipt.exists() else {}
    if result.returncode and mode == 'record':
        (work / ('refusal-' + str(counter) + '.log')).write_text(result.stderr)
    return result, data, receipt


def build(command, env=None):
    return run(['bash', '-c', command], cwd=project, env=env or environment)


def expected_tool(data, name, expected):
    record = data.get('tools', {}).get(name, {})
    return record.get('resolved_path', record.get('selected_path')) == str(expected) and \
        record.get('resolved_sha256', record.get('selected_sha256')) == digest(expected)


command = 'cargo +fixture-selected build --quiet --offline --target ' + shlex.quote(host)
before, identity, receipt = probe(command)
compiled = build(command)
check('explicit +toolchain builds and runs with genuine Cargo/rustc',
      compiled.returncode == 0 and require([project / 'target' / host / 'debug/identity-probe']) == '42')
check('explicit +toolchain receipt names the Cargo and rustc actually selected',
      before.returncode == 0 and expected_tool(identity, 'cargo', selected / 'bin/cargo') and
      expected_tool(identity, 'rustc', selected / 'bin/rustc'))
check('explicit toolchain verbose versions match the real selected executables',
      identity.get('tools', {}).get('cargo', {}).get('version') == require([selected / 'bin/cargo', '-vV']) and
      identity.get('tools', {}).get('rustc', {}).get('version') == require([selected / 'bin/rustc', '-vV']))
after, _, _ = probe(command, mode='verify', receipt=receipt)
check('unchanged explicit toolchain passes the post-build probe', after.returncode == 0)

env_selected = dict(environment, RUSTUP_TOOLCHAIN='fixture-selected')
result, data, _ = probe('cargo build --offline', env_selected)
check('RUSTUP_TOOLCHAIN selects matching compiler bytes without a plus flag',
      result.returncode == 0 and expected_tool(data, 'rustc', selected / 'bin/rustc'))
(project / 'rust-toolchain.toml').write_text('[toolchain]\nchannel="fixture-selected"\n')
env_tracked = dict(environment)
env_tracked.pop('RUSTUP_TOOLCHAIN')
result, data, _ = probe('cargo build --offline', env_tracked)
check('tracked rust-toolchain.toml keeps selecting its own compiler',
      result.returncode == 0 and expected_tool(data, 'rustc', selected / 'bin/rustc'))
(project / 'rust-toolchain.toml').rename(work / 'retained-rust-toolchain.toml')

linker = work / 'actual-linker'
link_log = work / 'linker.log'
linker.write_text('#!/bin/sh\nprintf invoked\\n >> ' + shlex.quote(str(link_log)) +
                  '\nexec ' + shlex.quote(shutil.which('cc')) + ' "$@"\n')
linker.chmod(0o755)
linker_variable = 'CARGO_TARGET_' + host.replace('-', '_').upper() + '_LINKER'
env_target = dict(environment, CARGO_BUILD_TARGET='unselected-host-target',
                  CARGO_TARGET_DIR=str(work / 'explicit-target-output'))
env_target[linker_variable] = str(linker)
command = 'cargo build --quiet --offline --target=' + shlex.quote(host)
result, data, _ = probe(command, env_target)
compiled = build(command, env_target)
check('explicit target compiles through its target-specific linker',
      compiled.returncode == 0 and link_log.exists() and
      require([work / 'explicit-target-output' / host / 'debug/identity-probe']) == '42')
check('command target overrides ambient target in the linker receipt',
      result.returncode == 0 and data.get('target_triple') == host and
      data.get('linker_variable') == linker_variable and expected_tool(data, 'linker', linker))
env_redirect = dict(env_target, CARGO_TARGET_DIR=str(work / 'redirect-output'))
command = 'cargo build >"compile output.log" --quiet --offline --target=' + shlex.quote(host)
result, data, _ = probe(command, env_redirect)
compiled = build(command, env_redirect)
check('real Cargo retains target arguments after an intervening redirection',
      compiled.returncode == 0 and require([work / 'redirect-output' / host / 'debug/identity-probe']) == '42')
check('mid-command redirection preserves the actual target and linker in the receipt',
      result.returncode == 0 and data.get('target_triple') == host and
      expected_tool(data, 'linker', linker))

for variable in ('RUSTC', 'CARGO_BUILD_RUSTC'):
    compiler = work / ('explicit-' + variable.lower())
    compiler_log = work / (variable.lower() + '.log')
    compiler.write_text('#!/bin/sh\nprintf invoked\\n >> ' + shlex.quote(str(compiler_log)) +
                        '\nexec ' + shlex.quote(str(real_rustc)) + ' "$@"\n')
    compiler.chmod(0o755)
    env_compiler = dict(environment, CARGO_TARGET_DIR=str(work / ('output-' + variable)))
    env_compiler[variable] = str(compiler)
    command = 'cargo +fixture-selected build --quiet --offline'
    result, data, _ = probe(command, env_compiler)
    compiled = build(command, env_compiler)
    check(variable + ' override executes in a real Cargo build', compiled.returncode == 0 and compiler_log.exists())
    check(variable + ' script is identified without inventing a rustup dispatch',
          result.returncode == 0 and expected_tool(data, 'rustc', compiler) and
          'resolved_path' not in data.get('tools', {}).get('rustc', {}))

for label, command in (
    ('quoted literal toolchain', "'cargo' +'fixture-selected' build --offline"),
    ('known quoted target environment', 'cargo +fixture-selected build --target "$CARGO_BUILD_TARGET" --offline'),
    ('known braced target environment', 'cargo +fixture-selected build --target="${CARGO_BUILD_TARGET}" --offline'),
    ('compound command without selection changes', 'printf preparing; cargo +fixture-selected build --offline; printf finished'),
    ('matching multiple Cargo selections', 'cargo +fixture-selected check --offline && cargo +fixture-selected build --offline'),
    ('continued shell line', 'cargo +fixture-selected build ' + '\\\n' + ' --target "$CARGO_BUILD_TARGET" --offline'),
    ('leading shell redirection', '>"build output.log" cargo +fixture-selected build --offline'),
    ('descriptor redirection before target', 'cargo +fixture-selected build 2>&1 --target "$CARGO_BUILD_TARGET" --offline'),
):
    result, data, _ = probe(command)
    check(label + ' keeps the selected compiler identity',
          result.returncode == 0 and expected_tool(data, 'rustc', selected / 'bin/rustc'))

for label, command in (
    ('dynamic plus selector', 'cargo +$(printf fixture-selected) build'),
    ('dynamic target', 'cargo build --target "$(rustc -vV)"'),
    ('unreviewed variable selector', 'cargo +"$DSR_TEST_DYNAMIC_TOOLCHAIN" build'),
    ('conflicting Cargo toolchains', 'cargo +fixture-default check && cargo +fixture-selected build'),
    ('conflicting Cargo targets', 'cargo build --target ' + host + ' --target wasm32-unknown-unknown'),
    ('Cargo config override', 'cargo --config \'build.rustc="/bin/true"\' build'),
    ('Cargo config equals override', 'cargo build --config=fixture.toml'),
    ('Cargo cwd override', 'cargo -C other-project build'),
    ('shell context mutation', 'export RUSTUP_TOOLCHAIN=fixture-selected; cargo build'),
    ('shell cwd mutation', 'cd other-project; cargo build'),
    ('opaque compiler driver', './compile-everything.sh'),
    ('mixed wrapped toolchain', 'cargo build; rustup run fixture-selected cargo build'),
    ('mixed nested shell compiler', 'cargo build; bash -c "cargo +fixture-selected build"'),
    ('mixed env compiler', 'cargo build; env -u RUSTUP_TOOLCHAIN cargo build'),
    ('exec replacing final verifier', 'cargo build; exec cargo +fixture-selected build'),
    ('direct rustc linker override', 'cargo rustc -- -C linker=/bin/true'),
    ('direct rustc target override', 'cargo rustc -- --target wasm32-unknown-unknown'),
    ('process substitution redirection', 'cargo build > >(cat) --target ' + host),
    ('background compiler', 'cargo +fixture-selected build &'),
):
    result, _, receipt = probe(command)
    check(label + ' refuses to attest a guessed default', result.returncode != 0 and not receipt.exists())

config_dir = project / '.cargo'
config_dir.mkdir()
config_path = config_dir / 'config.toml'
config_compiler = work / 'configured-rustc'
config_compiler.write_text('#!/bin/sh\nexec ' + shlex.quote(str(real_rustc)) + ' "$@"\n')
config_compiler.chmod(0o755)
config_path.write_text('[build]\nrustc="../configured-rustc"\ntarget="' + host +
                      '"\n[target.' + host + ']\nlinker="../actual-linker"\n')
env_config = dict(environment, CARGO_TARGET_DIR=str(work / 'config-output'))
env_config.pop('CARGO_BUILD_TARGET')
command = 'cargo build --quiet --offline'
result, data, receipt = probe(command, env_config)
compiled = build(command, env_config)
check('tracked Cargo configuration selects a real compiler, target and linker',
      compiled.returncode == 0 and require([work / 'config-output' / host / 'debug/identity-probe']) == '42')
check('literal tracked Cargo selectors enter the executable receipt',
      result.returncode == 0 and data.get('target_triple') == host and
      expected_tool(data, 'rustc', config_compiler) and expected_tool(data, 'linker', linker) and
      data.get('selection', {}).get('cargo_config') == [{'path': str(config_path), 'sha256': digest(config_path)}])
missing_toml_bin = work / 'without-tomllib'
missing_toml_bin.mkdir()
missing_toml_runner = work / 'without_tomllib.py'
missing_toml_runner.write_text('''import builtins, sys
original_import = builtins.__import__
def guarded_import(name, *args, **kwargs):
    if name == "tomllib":
        raise ImportError("simulated Python 3.9 standard library")
    return original_import(name, *args, **kwargs)
builtins.__import__ = guarded_import
sys.argv = sys.argv[1:]
if sys.argv[0] == "-I":
    sys.argv.pop(0)
exec(compile(sys.stdin.read(), "<toolchain-probe>", "exec"))
''')
missing_toml_python = missing_toml_bin / 'python3'
missing_toml_python.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) +
                              ' -I ' + shlex.quote(str(missing_toml_runner)) + ' "$@"\n')
missing_toml_python.chmod(0o755)
env_missing_toml = dict(env_config, PATH=str(missing_toml_bin) + os.pathsep + environment['PATH'])
no_parser, _, no_parser_receipt = probe(command, env_missing_toml)
check('missing TOML parser refuses config selection with an actionable Python requirement',
      no_parser.returncode != 0 and not no_parser_receipt.exists() and 'Python 3.11+' in no_parser.stderr)
config_path.write_text(config_path.read_text() + '# changed configuration evidence\n')
after, _, _ = probe(command, env_config, mode='verify', receipt=receipt)
check('tracked Cargo configuration drift refuses the final identity check', result.returncode == 0 and after.returncode != 0)
config_path.rename(work / 'retained-literal-config.toml')
for label, contents in (
    ('cfg linker', '[target.\'cfg(unix)\']\nlinker="cc"\n'),
    ('environment compiler', '[env]\nRUSTC="/bin/true"\n'),
    ('included config', 'include=["other.toml"]\n'),
    ('command alias', '[alias]\ncompile="build"\n'),
):
    config_path.write_text(contents)
    result, _, receipt = probe('cargo compile' if label == 'command alias' else 'cargo build')
    check(label + ' refuses unresolved tracked configuration', result.returncode != 0 and not receipt.exists())
    config_path.rename(work / ('retained-' + label.replace(' ', '-') + '.toml'))

command = 'cargo +fixture-selected build --offline'
result, _, receipt = probe(command)
with (selected / 'bin/rustc').open('ab') as stream:
    stream.write(b'changed fixture executable bytes\n')
after, _, _ = probe(command, mode='verify', receipt=receipt)
check('selected executable byte drift refuses the post-build probe', result.returncode == 0 and after.returncode != 0)

print(f'Toolchain identity: {passed} passed, {failed} failed; fixtures retained at {work}', flush=True)
raise SystemExit(1 if failed else 0)
PY
