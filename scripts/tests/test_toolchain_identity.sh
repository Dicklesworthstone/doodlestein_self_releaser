#!/usr/bin/env bash
# Exercise the strict Unix identity probe with real Cargo/rustc executables.
# Rustup state and the compiled project are private; no toolchain is installed
# or modified. The second toolchain has its own real executable copies.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 bash cargo rustc rustup cc jq; do
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
fixture_base = os.environ.get('RCH_TARGET_BASE') or os.environ.get('TMPDIR')
work = Path(tempfile.mkdtemp(prefix='dsr-toolchain-identity-', dir=fixture_base)).resolve()
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
    timeout = kwargs.pop('timeout', 120)
    return subprocess.run(list(map(str, argv)), capture_output=True, text=True, timeout=timeout, **kwargs)


def require(argv, **kwargs):
    result = run(argv, **kwargs)
    if result.returncode:
        raise AssertionError(str(argv) + '\n' + result.stderr)
    return result.stdout.strip()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def real_toolchain_executable(name, candidate):
    candidate = Path(candidate).resolve()
    with candidate.open('rb') as stream:
        scripted = stream.read(2) == b'#!'
    if scripted:
        # Rustup's selected Cargo may itself be the exact managed toolchain
        # wrapper. Copy its actual executable, never a wrapper missing its
        # sibling or a made-up tool/version response.
        if name != 'cargo' or digest(candidate) != 'd5966567e177ce968f272848ab8e249da3d9bfca40f90237480e1fbe6bd9d2d0':
            raise AssertionError('Unreviewed selected toolchain launcher: ' + str(candidate))
        candidate = (candidate.parent / 'cargo-rch-real').resolve()
    if not candidate.is_file() or not os.access(candidate, os.X_OK):
        raise AssertionError('Actual toolchain executable unavailable: ' + str(candidate))
    with candidate.open('rb') as stream:
        if stream.read(2) == b'#!':
            raise AssertionError('Actual toolchain executable unavailable: ' + str(candidate))
    return candidate


real_cargo = real_toolchain_executable('cargo', require(['rustup', 'which', 'cargo']))
real_rustc = real_toolchain_executable('rustc', require(['rustup', 'which', 'rustc']))
real_sysroot = Path(require([real_rustc, '--print', 'sysroot'])).resolve()
host = next(line.split(': ', 1)[1] for line in require([real_rustc, '-vV']).splitlines()
            if line.startswith('host: '))
selected = work / 'selected-toolchain'
(selected / 'bin').mkdir(parents=True)
alternate_sysroot = Path(os.environ.get('DSR_TEST_ALTERNATE_SYSROOT', str(real_sysroot))).resolve()
for name in ('cargo', 'rustc'):
    shutil.copy2(real_toolchain_executable(name, alternate_sysroot / 'bin' / name), selected / 'bin' / name)
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

program = '''source "$1" || exit $?; _act_toolchain_identity_script "$2" "$3" "$4" "" "$5" "$6" | bash'''
counter = 0
receipt_pins = {}

binding_program = '''source "$1" || exit $?;
IFS= read -r isolation || exit 1; IFS= read -r original || exit 1; IFS= read -r current || exit 1;
_act_bind_toolchain_identity "$isolation" "$original" "$current"'''


def bind_observation(isolation, original, current):
    # Large JSON travels on stdin, including across this test's subprocess
    # boundary. The production helper must not turn it into one exec argument.
    documents = '\n'.join(json.dumps(item) for item in (isolation, original, current)) + '\n'
    return run(['bash', '-o', 'pipefail', '-c', binding_program, '_', module], input=documents)


large_identity = {'schema_version': 1, 'cwd': str(project), 'target_triple': host,
                  'tools': {'cargo': {'version': 'cargo ' + 'x' * 262144}}}
large_bound = bind_observation({'cargo_home': str(work / 'cargo')}, large_identity, large_identity)
check('accepted large observation binds through stdin without an exec argument overflow',
      large_bound.returncode == 0 and json.loads(large_bound.stdout) == {
          'cargo_home': str(work / 'cargo'), 'toolchain': large_identity})
contradiction = dict(large_identity, target_triple='different-target')
contradicted = bind_observation({}, large_identity, contradiction)
check('large observation disagreement refuses without returning an isolation receipt',
      contradicted.returncode != 0 and not contradicted.stdout)
for label, original, current in (('non-object original', [], []),
                                ('non-object returned', large_identity, [])):
    refused = bind_observation({}, original, current)
    check(label + ' cannot be inserted as compiler evidence', refused.returncode != 0 and not refused.stdout)

aggregation_program = '''source "$1" || exit $?;
IFS= read -r summary || exit 1; IFS= read -r targets || exit 1;
_act_bind_orchestration_targets "$summary" "$targets"'''
large_target = {'platform': 'linux/amd64', 'status': 'success',
                'cargo_isolation': {'toolchain': large_identity}}
summary = {'status': 'success', 'exit_code': 0, 'summary': {'total': 1, 'success': 1, 'failed': 0}}
aggregated = run(['bash', '-o', 'pipefail', '-c', aggregation_program, '_', module],
                 input=json.dumps(summary) + '\n' + json.dumps([large_target]) + '\n')
check('production target aggregator preserves a complete large compiler receipt',
      aggregated.returncode == 0 and json.loads(aggregated.stdout) == dict(summary, targets=[large_target]))

field_program = '''source "$1" || exit $?;
IFS= read -r isolation || exit 1; IFS= read -r observation || exit 1;
_act_bind_cargo_isolation_field "$2" "$isolation" "$observation"'''
for field in ('cargo_context', 'toolchain', 'dependency_sources'):
    bound_field = run(['bash', '-o', 'pipefail', '-c', field_program, '_', module, field],
                      input='{}\n' + json.dumps(large_identity) + '\n')
    check('large already-observed ' + field + ' is transported without becoming an exec argument',
          bound_field.returncode == 0 and json.loads(bound_field.stdout) == {field: large_identity})

# Exercise the production checkpoint writer too, rather than reproducing its
# jq filter. This is JSON transport evidence, not a worker/native build.
# Its existing production transaction cleanup also requires retained-mode or
# exact fixture lifecycle authorization before this test is admitted to run.
state_root = work / 'large-receipt-state'
state_file = state_root / 'identity-probe' / '1.0.0' / 'retained-run' / 'state.json'
state_file.parent.mkdir(parents=True)
state_file.write_text(json.dumps({'tool': 'identity-probe', 'version': '1.0.0',
                                 'run_id': 'retained-run', 'created_at': 'fixture'}))
state_program = '''log_error() { printf '%s\\n' "$*" >&2; }; log_debug() { :; };
source "$1" || exit $?; _BUILD_STATE_DIR="$2";
IFS= read -r extra || exit 1;
build_state_update_target identity-probe 1.0.0 linux/amd64 completed "$extra" retained-run'''
persisted = run(['bash', '-o', 'pipefail', '-c', state_program, '_', root / 'src/build_state.sh', state_root],
                input=json.dumps({'result': large_target, 'attempts': 1}) + '\n')
check('production target checkpoint retains the large receipt without exec argv transport',
      persisted.returncode == 0 and json.loads(state_file.read_text()).get(
          'target_statuses', {}).get('linux/amd64', {}).get('result') == large_target)


def probe(command, env=None, mode='record', receipt=None, pin=None, cwd=None, expected_cwd=None, timeout=120):
    global counter
    counter += 1
    if receipt is None:
        receipt = work / ('receipt-' + str(counter) + '.json')
    # Only record mode may establish a pin. Verification/collection must use
    # that held value, never rebase it from a compiler-writable pathname.
    held_pin = receipt_pins.get(str(receipt), {}) if pin is None else pin
    result = run(['bash', '-o', 'pipefail', '-c', program, '_', module, mode, receipt, command,
                  json.dumps(held_pin), expected_cwd or project], cwd=cwd or project,
                 env=env or environment, timeout=timeout)
    data = {}
    if result.returncode == 0 and mode == 'record':
        observation = json.loads(result.stdout)
        data = observation['identity']
        receipt_pins[str(receipt)] = observation['pin']
    elif result.returncode == 0 and mode == 'read':
        data = json.loads(result.stdout)
    if result.returncode:
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
if before.returncode == 0:
    held = receipt.stat(follow_symlinks=False)
    held_bytes = receipt.read_bytes()
    held_identity = ':'.join(str(value) for value in (
        held.st_dev, held.st_ino, held.st_mode, held.st_nlink, held.st_uid,
        held.st_gid, held.st_size, held.st_mtime_ns, held.st_ctime_ns))
    check('published pre-build pin binds exact retained receipt bytes and inode',
          receipt_pins[str(receipt)] == {
              'sha256': hashlib.sha256(held_bytes).hexdigest(), 'identity': held_identity})
    duplicate, _, _ = probe(command, receipt=receipt)
    current = receipt.stat(follow_symlinks=False)
    current_identity = ':'.join(str(value) for value in (
        current.st_dev, current.st_ino, current.st_mode, current.st_nlink,
        current.st_uid, current.st_gid, current.st_size, current.st_mtime_ns,
        current.st_ctime_ns))
    check('repeated recording refuses without replacing the original receipt or pin',
          duplicate.returncode != 0 and not duplicate.stdout and
          receipt.read_bytes() == held_bytes and
          current_identity == held_identity and
          receipt_pins[str(receipt)]['identity'] == held_identity)
else:
    check('published pre-build pin binds exact retained receipt bytes and inode', False)
    check('repeated recording refuses without replacing the original receipt or pin', False)
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
config_path.write_text('[env]\nRUST_MIN_STACK = "8388608"\nLIBSQLITE3_FLAGS = "-DSQLITE_ENABLE_MATH_FUNCTIONS"\n')
env_stack = dict(environment, CARGO_TARGET_DIR=str(work / 'stack-output'))
command = 'cargo build --quiet --offline'
result, data, receipt = probe(command, env_stack)
compiled = build(command, env_stack)
check('RUST_MIN_STACK in tracked [env] is admitted and the real build still runs',
      result.returncode == 0 and compiled.returncode == 0 and
      require([work / 'stack-output' / host / 'debug/identity-probe']) == '42')
check('admitted RUST_MIN_STACK is recorded by name and value in the receipt',
      data.get('selection', {}).get('cargo_config') == [{
          'path': str(config_path), 'sha256': digest(config_path),
          'env_exemptions': [{'name': 'RUST_MIN_STACK', 'value': '8388608'}]}])
after, _, _ = probe(command, env_stack, mode='verify', receipt=receipt)
check('unchanged RUST_MIN_STACK configuration passes the post-build probe', after.returncode == 0)
config_path.rename(work / 'retained-stack-config.toml')
for label, contents in (
    ('cfg linker', '[target.\'cfg(unix)\']\nlinker="cc"\n'),
    ('environment compiler', '[env]\nRUSTC="/bin/true"\n'),
    ('environment RUSTFLAGS', '[env]\nRUSTFLAGS="-C debuginfo=0"\n'),
    ('environment RUST_MIN_STACK_X near miss', '[env]\nRUST_MIN_STACK_X="8388608"\n'),
    ('environment non-numeric RUST_MIN_STACK', '[env]\nRUST_MIN_STACK="abc"\n'),
    ('environment zero RUST_MIN_STACK', '[env]\nRUST_MIN_STACK="0"\n'),
    ('environment table RUST_MIN_STACK', '[env]\nRUST_MIN_STACK={value="8388608", force=true}\n'),
    ('environment RUST_MIN_STACK beside RUSTFLAGS', '[env]\nRUST_MIN_STACK="8388608"\nRUSTFLAGS="-C debuginfo=0"\n'),
    ('included config', 'include=["other.toml"]\n'),
    ('command alias', '[alias]\ncompile="build"\n'),
):
    config_path.write_text(contents)
    result, _, receipt = probe('cargo compile' if label == 'command alias' else 'cargo build')
    check(label + ' refuses unresolved tracked configuration', result.returncode != 0 and not receipt.exists())
    config_path.rename(work / ('retained-' + label.replace(' ', '-') + '.toml'))

command = 'cargo +fixture-selected build --offline'
result, original, receipt = probe(command)
original_bytes = receipt.read_bytes()
held_pin = dict(receipt_pins[str(receipt)])
collected, collected_data, _ = probe(command, mode='read', receipt=receipt)
check('secure collection returns the unchanged genuine pre-build observation',
      result.returncode == 0 and collected.returncode == 0 and collected_data == original and
      digest(receipt) == held_pin['sha256'] and receipt.read_bytes() == original_bytes)
missing_pin, _, _ = probe(command, mode='verify', receipt=receipt, pin={})
check('verification cannot establish a new baseline without the original pin', missing_pin.returncode != 0)
wrong_target = dict(environment, CARGO_BUILD_TARGET='aarch64-unknown-linux-gnu' if host !=
                    'aarch64-unknown-linux-gnu' else 'x86_64-unknown-linux-gnu')
different_target, _, _ = probe(command, wrong_target, mode='verify', receipt=receipt)
check('actual selection of a different target refuses the held observation', different_target.returncode != 0)
other_project = work / 'other-project'
(other_project / 'src').mkdir(parents=True)
shutil.copy2(project / 'Cargo.toml', other_project / 'Cargo.toml')
shutil.copy2(project / 'src/main.rs', other_project / 'src/main.rs')
different_cwd, _, _ = probe(command, mode='verify', receipt=receipt, cwd=other_project)
check('actual different execution cwd refuses the held observation', different_cwd.returncode != 0)
aliased_root = work / 'requested-parent-alias'
aliased_root.symlink_to(project, target_is_directory=True)
alias_record, alias_identity, alias_receipt = probe(command, cwd=aliased_root, expected_cwd=aliased_root)
alias_verify, _, _ = probe(command, mode='verify', receipt=alias_receipt,
                         cwd=aliased_root, expected_cwd=aliased_root)
alias_read, alias_collected, _ = probe(command, mode='read', receipt=alias_receipt,
                                     expected_cwd=aliased_root)
check('requested root aliases bind the actual physical cwd without rejecting the unchanged build',
      alias_record.returncode == 0 and alias_verify.returncode == 0 and alias_read.returncode == 0 and
      alias_identity.get('cwd') == str(project) and alias_collected == alias_identity)

for mutation in ('truncate', 'replacement', 'symlink', 'fifo', 'hardlink', 'permissions', 'oversize'):
    result, original, receipt = probe(command)
    original_bytes = receipt.read_bytes()
    original_pin = dict(receipt_pins[str(receipt)])
    retained = work / ('retained-' + mutation + '-baseline.json')
    if mutation in ('replacement', 'symlink', 'fifo'):
        receipt.rename(retained)
        if mutation == 'replacement':
            receipt.write_bytes(original_bytes)
            receipt.chmod(0o600)
        elif mutation == 'symlink':
            receipt.symlink_to(retained)
        else:
            os.mkfifo(receipt, 0o600)
    elif mutation == 'hardlink':
        os.link(receipt, retained)
    elif mutation == 'permissions':
        retained.write_bytes(original_bytes)
        receipt.chmod(0o644)
    else:
        retained.write_bytes(original_bytes)
        receipt.write_bytes(b'' if mutation == 'truncate' else b'x' * 1048577)
    # The FIFO bound catches a blocking read; no reader follows a symlink or
    # substitutes fixture JSON for an actual compiler/service observation.
    verified, _, _ = probe(command, mode='verify', receipt=receipt, timeout=5)
    collected, _, _ = probe(command, mode='read', receipt=receipt, timeout=5)
    check(mutation + ' refuses verification and artifact consumption without losing baseline bytes',
          result.returncode == 0 and verified.returncode != 0 and collected.returncode != 0 and
          retained.read_bytes() == original_bytes and receipt_pins[str(receipt)] == original_pin)

command = 'cargo +fixture-selected build --offline'
result, _, receipt = probe(command)
original_bytes = receipt.read_bytes()
original_pin = dict(receipt_pins[str(receipt)])
with (selected / 'bin/rustc').open('ab') as stream:
    stream.write(b'changed fixture executable bytes\n')
after, _, _ = probe(command, mode='verify', receipt=receipt)
check('selected executable byte drift refuses the post-build probe', result.returncode == 0 and after.returncode != 0)
rebased, new_observation, new_receipt = probe(command)
retained = work / 'retained-before-rebased-receipt.json'
retained.write_bytes(original_bytes)
receipt.write_bytes(new_receipt.read_bytes())
after_rebase, _, _ = probe(command, mode='verify', receipt=receipt)
collected_rebase, _, _ = probe(command, mode='read', receipt=receipt)
check('changed real executable plus a rewritten matching receipt cannot rebase the original observation',
      rebased.returncode == 0 and new_observation != json.loads(original_bytes) and
      after_rebase.returncode != 0 and collected_rebase.returncode != 0 and
      receipt_pins[str(receipt)] == original_pin and retained.read_bytes() == original_bytes)

# Execute an exact source-reviewed managed shim with genuine private
# Cargo/rustc. This proves delegation in the fixture, not remote admission,
# live RCH worker execution, native SDK selection or release qualification.
managed_input = Path(os.environ.get('DSR_TEST_RCH_CARGO_SHIM', str(Path.home() / '.rch/shims/cargo')))
managed_hash = '171e35f834fb8f900f85bd9ee22a659b3e710973dc3922d9579d055d560982e5'
if not managed_input.is_file() or digest(managed_input) != managed_hash:
    check('a byte-exact reviewed RCH v6 shim input is required (DSR_TEST_RCH_CARGO_SHIM)', False)
else:
    # Prior refusal cases deliberately changed the first toolchain's bytes.
    # Preserve it and start this positive suite with a fresh real copy: a
    # modified signed Mach-O executable cannot be reused as a working fixture.
    selected = work / 'managed-selected-toolchain'
    (selected / 'bin').mkdir(parents=True)
    for name in ('cargo', 'rustc'):
        shutil.copy2(real_toolchain_executable(name, alternate_sysroot / 'bin' / name), selected / 'bin' / name)
    (selected / 'lib').symlink_to(alternate_sysroot / 'lib', target_is_directory=True)
    require(['rustup', 'toolchain', 'link', 'fixture-managed', selected], env=environment)
    managed_bin = work / 'managed-rch-bin'
    managed_bin.mkdir()
    managed_shim = managed_bin / 'cargo'
    shutil.copy2(managed_input, managed_shim)
    managed_shim.chmod(0o755)
    (selected / 'bin/cargo-rch-real').symlink_to('cargo')
    managed_env = dict(environment, PATH=str(managed_bin) + os.pathsep + environment['PATH'],
                       RUSTUP_TOOLCHAIN='fixture-managed',
                       CARGO_TARGET_DIR=str(work / 'managed-rch-output'))
    for variable in ('RCH_REAL_CARGO', 'RCH_SHIM_REAL_CARGO'):
        managed_env.pop(variable, None)
    command = 'cargo +fixture-managed build --quiet --offline --jobs 2'
    recorded, observed, managed_receipt = probe(command, managed_env)
    compiled = build(command, managed_env)
    verified, _, _ = probe(command, managed_env, mode='verify', receipt=managed_receipt)
    cargo_record = observed.get('tools', {}).get('cargo', {})
    check('reviewed managed shim builds with explicit selection and binds delegated Cargo bytes',
          recorded.returncode == 0 and compiled.returncode == 0 and verified.returncode == 0 and
          require([work / 'managed-rch-output' / host / 'debug/identity-probe']) == '42' and
          cargo_record.get('selected_kind') == 'script' and
          cargo_record.get('selected_sha256') == managed_hash and
          cargo_record.get('resolved_kind') == 'executable' and
          expected_tool(observed, 'cargo', selected / 'bin/cargo'))
    command = 'cargo build --quiet --offline --jobs 2'
    plain_recorded, plain_observed, plain_receipt = probe(command, managed_env)
    check('unselected managed shim binds its actual rustc sysroot dispatch',
          plain_recorded.returncode == 0 and expected_tool(plain_observed, 'cargo', selected / 'bin/cargo') and
          expected_tool({'tools': {'rustc': plain_observed.get('tools', {}).get('cargo', {}).get(
              'sysroot_resolver', {})}}, 'rustc', selected / 'bin/rustc'))

    # The shim permits absent bare-PATH rustc. Use an actual HOME Cargo and
    # explicit actual RUSTC, with a private PATH containing no rustc entry.
    # No fake compiler or hand-authored backend response supplies this case.
    fallback_home = work / 'managed-fallback-home'
    (fallback_home / '.cargo/bin').mkdir(parents=True)
    (fallback_home / '.cargo/bin/cargo').symlink_to(selected / 'bin/cargo')
    fallback_bin = work / 'managed-fallback-bin'
    fallback_bin.mkdir()
    (fallback_bin / 'cargo').symlink_to(managed_shim)
    for name in ('bash', 'python3', 'dirname', 'date', 'jq', 'cc', 'c++', 'xcrun', 'xcodebuild', 'ld', 'ar'):
        executable = shutil.which(name)
        if executable:
            (fallback_bin / name).symlink_to(executable)
    fallback_env = dict(managed_env, HOME=str(fallback_home), PATH=str(fallback_bin),
                        RUSTC=str(selected / 'bin/rustc'),
                        CARGO_TARGET_DIR=str(work / 'managed-fallback-output'))
    fallback_recorded, fallback_observed, fallback_receipt = probe(command, fallback_env)
    fallback_compiled = build(command, fallback_env)
    fallback_verified, _, _ = probe(command, fallback_env, mode='verify', receipt=fallback_receipt)
    check('absent bare rustc still binds and builds through the actual HOME Cargo fallback',
          fallback_recorded.returncode == 0 and fallback_compiled.returncode == 0 and
          fallback_verified.returncode == 0 and
          expected_tool(fallback_observed, 'cargo', selected / 'bin/cargo') and
          fallback_observed.get('tools', {}).get('cargo', {}).get('sysroot_resolver') is None and
          require([work / 'managed-fallback-output' / host / 'debug/identity-probe']) == '42')

    failing_bin = work / 'managed-failing-sysroot-bin'
    failing_bin.mkdir()
    for entry in fallback_bin.iterdir():
        (failing_bin / entry.name).symlink_to(entry)
    # A real Rustup proxy cannot resolve this deliberately absent private
    # toolchain. The explicit actual RUSTC and HOME Cargo still work.
    (failing_bin / 'rustc').symlink_to(Path(shutil.which('rustup')).resolve())
    failing_env = dict(fallback_env, PATH=str(failing_bin), RUSTUP_TOOLCHAIN='fixture-absent',
                       CARGO_TARGET_DIR=str(work / 'managed-failed-sysroot-output'))
    failed_sysroot_recorded, failed_sysroot_observed, failed_sysroot_receipt = probe(command, failing_env)
    failed_sysroot_compiled = build(command, failing_env)
    failed_sysroot_verified, _, _ = probe(command, failing_env, mode='verify', receipt=failed_sysroot_receipt)
    resolver_failure = failed_sysroot_observed.get('tools', {}).get('cargo', {}).get('sysroot_resolver') or {}
    check('failed real bare-rustc resolver falls back while binding explicit actual RUSTC',
          failed_sysroot_recorded.returncode == 0 and failed_sysroot_compiled.returncode == 0 and
          failed_sysroot_verified.returncode == 0 and resolver_failure.get('sysroot_probe_exit_code', 0) != 0 and
          expected_tool(failed_sysroot_observed, 'cargo', selected / 'bin/cargo') and
          expected_tool(failed_sysroot_observed, 'rustc', selected / 'bin/rustc') and
          require([work / 'managed-failed-sysroot-output' / host / 'debug/identity-probe']) == '42')

    # Stock Rustup proxies are real executable copies/hardlinks, not scripts.
    # PATH still has neither rustc nor rustup; HOME contains their dispatcher.
    proxy_home = work / 'managed-proxy-home'
    (proxy_home / '.cargo/bin').mkdir(parents=True)
    for name in ('cargo', 'rustup'):
        shutil.copy2(Path(shutil.which('rustup')).resolve(), proxy_home / '.cargo/bin' / name)
    proxy_env = dict(fallback_env, HOME=str(proxy_home),
                     CARGO_TARGET_DIR=str(work / 'managed-proxy-output'))
    proxy_recorded, proxy_observed, proxy_receipt = probe(command, proxy_env)
    proxy_compiled = build(command, proxy_env)
    proxy_verified, _, _ = probe(command, proxy_env, mode='verify', receipt=proxy_receipt)
    check('stock HOME Cargo proxy without PATH rustup binds the actual delegated compiler',
          proxy_recorded.returncode == 0 and proxy_compiled.returncode == 0 and
          proxy_verified.returncode == 0 and expected_tool(proxy_observed, 'cargo', selected / 'bin/cargo') and
          proxy_observed.get('tools', {}).get('cargo', {}).get('rustup_resolver', {}).get('sha256') ==
          digest(proxy_home / '.cargo/bin/rustup') and
          require([work / 'managed-proxy-output' / host / 'debug/identity-probe']) == '42')

    # Exercise the actual strict-cache emitter with the same genuine selected
    # tools. This closes dispatcher disagreement in the compiler consumer;
    # these local fixture builds still do not prove RCH admission/native SDK.
    cache_root = work / 'managed-cargo-cache'
    cache_root.mkdir(mode=0o700)
    cache_program = '''source "$1" || exit $?;
_act_strict_cargo_cache_script "$2" '{}' "$3" | bash'''

    def cached_build(label, cache_command, cache_environment):
        output = work / ('managed-cache-output-' + label)
        cache_environment = dict(cache_environment, CARGO_TARGET_DIR=str(output))
        before_cache, before_identity, cache_receipt = probe(cache_command, cache_environment)
        result = run(['bash', '-o', 'pipefail', '-c', cache_program, '_', module, cache_root, cache_command],
                     cwd=project, env=cache_environment, timeout=300)
        after_cache, _, _ = probe(cache_command, cache_environment, mode='verify', receipt=cache_receipt)
        executable = output / host / 'debug/identity-probe'
        check(label + ' strict cache uses the original actual delegated Cargo/Rustc observation',
              before_cache.returncode == 0 and result.returncode == 0 and after_cache.returncode == 0 and
              expected_tool(before_identity, 'cargo', selected / 'bin/cargo') and
              expected_tool(before_identity, 'rustc', selected / 'bin/rustc') and
              executable.is_file() and require([executable]) == '42')

    cached_build('explicit-v6', 'cargo +fixture-managed build --quiet --offline --jobs 2', managed_env)
    cached_build('explicit-v6-exported', 'cargo +fixture-managed build --quiet --offline --jobs 2',
                 dict(managed_env, dsr_cache_context='', DSR_CARGO_TOOLCHAIN_CONTEXT=''))
    cached_build('sysroot-v6', command, managed_env)
    cached_build('HOME-direct', command, fallback_env)
    cached_build('HOME-proxy', command, proxy_env)
    unknown_bin = work / 'unreviewed-cache-shim'
    unknown_bin.mkdir()
    unknown_shim = unknown_bin / 'cargo'
    # Keep the byte-exact original. Changed launcher bytes are a new owned
    # file with the same real dispatch, header and version, never a fake tool.
    unknown_shim.write_bytes(managed_shim.read_bytes() + b'\n# changed unreviewed launcher bytes\n')
    unknown_shim.chmod(0o755)
    refused_output = work / 'unreviewed-cache-output'
    unknown_env = dict(managed_env, PATH=str(unknown_bin) + os.pathsep + managed_env['PATH'],
                       CARGO_TARGET_DIR=str(refused_output))
    refused_cache = run(['bash', '-o', 'pipefail', '-c', cache_program, '_', module, cache_root, command],
                        cwd=project, env=unknown_env)
    check('unchanged real version/header cannot admit an unreviewed cache compiler launcher',
          refused_cache.returncode != 0 and not refused_output.exists())

    overridden = dict(managed_env, RCH_REAL_CARGO=str(real_cargo))
    refused, _, refused_receipt = probe(command, overridden)
    check('managed executable override cannot borrow the reviewed shim delegation authority',
          refused.returncode != 0 and not refused_receipt.exists())
    shim_before = digest(managed_shim)
    with (selected / 'bin/cargo').open('ab') as stream:
        stream.write(b'retained delegated Cargo byte drift\n')
    drifted, _, _ = probe(command, managed_env, mode='verify', receipt=plain_receipt)
    check('unchanged wrapper plus changed delegated executable refuses the original pin',
          plain_recorded.returncode == 0 and drifted.returncode != 0 and digest(managed_shim) == shim_before)
    proxy_drifted, _, _ = probe(command, proxy_env, mode='verify', receipt=proxy_receipt)
    check('stock HOME proxy cannot hide changed delegated Cargo bytes behind an unchanged Rustup binary',
          proxy_recorded.returncode == 0 and proxy_drifted.returncode != 0)

print(f'Toolchain identity: {passed} passed, {failed} failed; fixtures retained at {work}', flush=True)
raise SystemExit(1 if failed else 0)
PY
