#!/usr/bin/env bash
# Exercise the strict Unix identity probe with real Cargo/rustc executables.
# Rustup state and the compiled project are private; no toolchain is installed
# or modified. The second toolchain has its own real executable copies.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
MODE=all
if [[ "${1:-}" == --rustup-dispatch-only && $# == 1 ]]; then
    MODE=rustup-dispatch
elif [[ "${1:-}" == --zig-shim-only && $# == 1 ]]; then
    MODE=zig-shim
elif (( $# != 0 )); then
    printf 'Usage: %s [--rustup-dispatch-only|--zig-shim-only]\n' "$0" >&2
    exit 4
fi
for tool in python3 bash cargo rustc rustup cc jq; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
python3 -I - "$ROOT" "$MODE" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
mode = sys.argv[2]
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
                   RUSTUP_AUTO_INSTALL='0', RCH_DISABLED='1', RCH_CARGO_WRAPPER_BYPASS='1',
                   CARGO_INCREMENTAL='0', CARGO_PROFILE_DEV_DEBUG='0', CARGO_PROFILE_TEST_DEBUG='0')
require(['rustup', 'toolchain', 'link', 'fixture-default', real_sysroot], env=environment)
require(['rustup', 'toolchain', 'link', 'fixture-selected', selected], env=environment)
require(['rustup', 'default', 'fixture-default'], env=environment)
environment['RUSTUP_TOOLCHAIN'] = 'fixture-default'
environment['CARGO_BUILD_TARGET'] = host

# Match the production transport: parse the whole generated program before
# executing it, and give descendants closed stdin. A fault-injected Python
# version probe must not consume later program text from the interpreter pipe.
program = '''source "$1" || exit $?;
dsr_identity_program=$(_act_toolchain_identity_script "$2" "$3" "$4" "" "$5" "$6" "$7") || exit $?
printf '{\\n%s\\n} </dev/null\\n' "$dsr_identity_program" | bash'''
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


def probe(command, env=None, mode='record', receipt=None, pin=None, cwd=None, expected_cwd=None,
          timeout=120, zig_shim_dir=''):
    global counter
    counter += 1
    if receipt is None:
        receipt = work / ('receipt-' + str(counter) + '.json')
    # Only record mode may establish a pin. Verification/collection must use
    # that held value, never rebase it from a compiler-writable pathname.
    held_pin = receipt_pins.get(str(receipt), {}) if pin is None else pin
    result = run(['bash', '-o', 'pipefail', '-c', program, '_', module, mode, receipt, command,
                  json.dumps(held_pin), expected_cwd or project, zig_shim_dir], cwd=cwd or project,
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


# Reuse the owned compiler copies and read-only library link above. Proxy
# entries are hardlinks to one owned copy, as in a normal Rustup installation;
# no installed executable, standard library or account configuration is changed.
dispatch_bin = work / 'dispatch-bin'
dispatch_bin.mkdir()
proxy_cargo = dispatch_bin / 'cargo'
shutil.copy2(Path(shutil.which('rustup')).resolve(), proxy_cargo)
os.link(proxy_cargo, dispatch_bin / 'rustc')
for name in ('bash', 'python3', 'cat', 'dirname', 'date', 'jq', 'cc', 'c++', 'as', 'ld', 'ar',
             'xcrun', 'xcodebuild', 'sha256sum', 'shasum', 'awk', 'cargo-zigbuild', 'zig'):
    executable = shutil.which(name)
    if executable:
        (dispatch_bin / name).symlink_to(executable)
dispatch_home = work / 'dispatch-home'
dispatch_home.mkdir()
dispatch_env = dict(environment, HOME=str(dispatch_home), PATH=str(dispatch_bin),
                    RUSTUP_TOOLCHAIN='fixture-selected',
                    CARGO_TARGET_DIR=str(work / 'dispatch-output'))
dispatch_command = 'cargo build --quiet --locked --offline'
require(['cargo', 'generate-lockfile', '--offline'], env=dispatch_env, cwd=project)
compiled = build(dispatch_command, dispatch_env)
check('unresolved copied proxies are genuine and can compile the owned project offline',
      compiled.returncode == 0 and
      require([work / 'dispatch-output' / host / 'debug/identity-probe']) == '42')
for probe_mode in ('record', 'metadata', 'context'):
    unresolved, _, unresolved_receipt = probe(dispatch_command, dispatch_env, mode=probe_mode)
    check('hidden manager refuses ' + probe_mode + ' instead of attesting only proxy bytes',
          unresolved.returncode != 0 and not unresolved.stdout and not unresolved_receipt.exists() and
          'unresolved Rustup dispatch' in unresolved.stderr)

# A nonmatching native manager on PATH cannot make the proxy a direct compiler
# or mask the recognized installation reference at the existing HOME location.
mismatched_manager = dispatch_bin / 'rustup'
shutil.copy2(Path(shutil.which('cc')).resolve(), mismatched_manager)
unresolved, _, unresolved_receipt = probe(dispatch_command, dispatch_env)
check('mismatched PATH manager cannot authorize a selected-only proxy receipt',
      unresolved.returncode != 0 and not unresolved_receipt.exists() and
      'unresolved Rustup dispatch' in unresolved.stderr)
home_manager = dispatch_home / '.cargo/bin/rustup'
home_manager.parent.mkdir(parents=True)
os.link(proxy_cargo, home_manager)
known, known_identity, known_receipt = probe(dispatch_command, dispatch_env)
known_verify, _, _ = probe(dispatch_command, dispatch_env, mode='verify', receipt=known_receipt)
known_metadata, _, _ = probe(dispatch_command, dispatch_env, mode='metadata')
check('matching HOME manager retains genuine metadata and exact Cargo/rustc identities despite PATH mismatch',
      known.returncode == 0 and known_verify.returncode == 0 and known_metadata.returncode == 0 and
      expected_tool(known_identity, 'cargo', selected / 'bin/cargo') and
      expected_tool(known_identity, 'rustc', selected / 'bin/rustc') and
      all(known_identity.get('tools', {}).get(name, {}).get('rustup_resolver') == {
          'path': str(home_manager), 'sha256': digest(home_manager)} for name in ('cargo', 'rustc')))
explicit_env = dict(dispatch_env, RUSTUP_TOOLCHAIN='fixture-default',
                    CARGO_TARGET_DIR=str(work / 'dispatch-explicit-output'))
explicit_command = 'cargo +fixture-selected build --quiet --locked --offline'
explicit, explicit_identity, explicit_receipt = probe(explicit_command, explicit_env)
explicit_build = build(explicit_command, explicit_env)
explicit_verify, _, _ = probe(explicit_command, explicit_env, mode='verify', receipt=explicit_receipt)
check('recognized explicit toolchain still overrides the ambient choice and genuinely compiles',
      explicit.returncode == 0 and explicit_build.returncode == 0 and explicit_verify.returncode == 0 and
      expected_tool(explicit_identity, 'rustc', selected / 'bin/rustc') and
      require([work / 'dispatch-explicit-output' / host / 'debug/identity-probe']) == '42')

# The manager itself remains a bound dependency even when unchanged proxy
# versions continue to select the same real compiler.
home_manager.rename(work / 'retained-dispatch-manager')
missing_manager, _, _ = probe(dispatch_command, dispatch_env, mode='verify', receipt=known_receipt)
check('losing the recognized manager refuses the original pinned observation',
      missing_manager.returncode != 0 and 'unresolved Rustup dispatch' in missing_manager.stderr)
(work / 'retained-dispatch-manager').rename(home_manager)

# Native direct Cargo/rustc remain supported with no Rustup manager. Selecting
# these physical executables is an explicit positive control for the detector.
direct_env = dict(dispatch_env, PATH=str(selected / 'bin') + os.pathsep + str(dispatch_bin),
                  HOME=str(work / 'direct-home'), CARGO_TARGET_DIR=str(work / 'direct-output'))
Path(direct_env['HOME']).mkdir()
direct, direct_identity, direct_receipt = probe(dispatch_command, direct_env)
direct_build = build(dispatch_command, direct_env)
direct_verify, _, _ = probe(dispatch_command, direct_env, mode='verify', receipt=direct_receipt)
check('direct native executables still compile and verify without a recognized manager',
      direct.returncode == 0 and direct_build.returncode == 0 and direct_verify.returncode == 0 and
      expected_tool(direct_identity, 'cargo', selected / 'bin/cargo') and
      expected_tool(direct_identity, 'rustc', selected / 'bin/rustc') and
      all('rustup_resolver' not in direct_identity.get('tools', {}).get(name, {}) for name in ('cargo', 'rustc')) and
      require([work / 'direct-output' / host / 'debug/identity-probe']) == '42')
for override in ('rustup', 'cargo', ''):
    refused, _, refused_receipt = probe(dispatch_command, dict(direct_env, RUSTUP_FORCE_ARG0=override))
    check('configured Rustup dispatch override is refused even for direct executables: ' + repr(override),
          refused.returncode != 0 and not refused_receipt.exists() and
          'dispatch overrides' in refused.stderr)

# A genuine compiled forwarder demonstrates why a version/FORCE_ARG0 reply is
# only a refusal signal. No fabricated compiler/version output grants trust.
forward_bin = work / 'dispatch-forwarder'
forward_bin.mkdir()
forward_source = forward_bin / 'forwarder.c'
forward_source.write_text('''#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
    (void)argc;
    const char *target = getenv("DSR_FORWARD_TOOL");
    if (!target) return 90;
    if (getenv("RUSTUP_FORCE_ARG0") && getenv("DSR_FAIL_DISPATCH_PROBE")) return 23;
    argv[0] = (char *)target;
    execv(target, argv);
    return 91;
}
''')
require(['cc', forward_source, '-o', forward_bin / 'cargo'])
forward_env = dict(dispatch_env, PATH=str(forward_bin) + os.pathsep + str(dispatch_bin),
                   DSR_FORWARD_TOOL=str(proxy_cargo))
forwarded = build(dispatch_command, forward_env)
check('compiled native forwarder executes genuine selected Cargo successfully', forwarded.returncode == 0)
opaque, _, opaque_receipt = probe(dispatch_command, forward_env)
check('native forwarding of Rustup versions cannot authorize an unrecognized entrypoint',
      opaque.returncode != 0 and not opaque_receipt.exists() and 'unresolved Rustup dispatch' in opaque.stderr)
failed_probe, _, failed_receipt = probe(dispatch_command, dict(forward_env, DSR_FAIL_DISPATCH_PROBE='1'))
check('failed unknown-dispatch probe cannot authorize a selected-only receipt',
      failed_probe.returncode != 0 and not failed_receipt.exists() and
      'cannot rule out unresolved Rustup dispatch' in failed_probe.stderr)

# Reproduce the original custody failure against a pinned successful build:
# only the delegated compiler changes; proxy, manager and verbose version stay
# fixed. Restore a fresh owned copy afterward for the remaining genuine builds.
compiler = selected / 'bin/rustc'
original_compiler = digest(compiler)
with compiler.open('ab') as stream:
    stream.write(b'changed owned delegated compiler bytes\n')
drifted, _, _ = probe(dispatch_command, dispatch_env, mode='verify', receipt=known_receipt)
check('delegated compiler byte drift refuses the original proxy/manager observation',
      known.returncode == 0 and digest(compiler) != original_compiler and drifted.returncode != 0)
compiler.rename(work / 'retained-dispatch-drift-rustc')
shutil.copy2(real_toolchain_executable('rustc', alternate_sysroot / 'bin/rustc'), compiler)

if mode == 'rustup-dispatch':
    print(str(passed) + ' passed; ' + str(failed) + ' failed')
    sys.exit(1 if failed else 0)


# These are real generated-launcher/Rustup/Cargo/Zig runs, including GNU
# cross-linking on a macOS host when this same suite is run there. No test
# command impersonates a compiler or returns a fabricated version string.
# The dedicated qualification flag requires both Linux standard libraries;
# existing full-suite users without Zig retain an explicit dependency skip.
zig_dependencies = all(shutil.which(name) for name in ('cargo-zigbuild', 'zig'))
zig_targets = ('x86_64-unknown-linux-gnu', 'aarch64-unknown-linux-gnu')
zig_stdlibs = all((selected / 'lib/rustlib' / target / 'lib').is_dir() for target in zig_targets)
if mode == 'zig-shim' and not (zig_dependencies and zig_stdlibs):
    print('Missing qualification dependencies: cargo-zigbuild >=0.23, Zig, and installed '
          'x86_64/aarch64-unknown-linux-gnu Rust standard libraries', file=sys.stderr)
    sys.exit(3)
if zig_dependencies and zig_stdlibs:
    shim_dir = work / 'glibc-floor-shim'
    staging = '''source "$1" || exit $?;
_act_zig_shim_prefix_sh "$2" | bash'''
    require(['bash', '-o', 'pipefail', '-c', staging, '_', module, shim_dir], env=environment)
    shim = shim_dir / 'cargo'
    generated = run(['bash', '-c', 'source "$1"; _act_zig_cargo_shim_sh', '_', module], env=environment)
    check('staged glibc-floor Cargo shim is byte-identical to the generator including newline',
          generated.returncode == 0 and shim.read_bytes() == generated.stdout.encode())
    shim_digest = digest(shim)

    def shim_environment(target, label, direct=False):
        base = direct_env if direct else dispatch_env
        # Exercise the launcher's exact empty-field and repeated-directory
        # removal; the delegated compiler must see the same PATH as the probe.
        return dict(base, PATH=str(shim_dir) + '::' + base['PATH'] + ':' + str(shim_dir) + ':',
                    CARGO_BUILD_TARGET=target, DSR_RUST_TARGET=target,
                    DSR_ZIG_TARGET=target + '.2.28', DSR_LINUX_GLIBC_FLOOR='2.28',
                    CARGO_TARGET_DIR=str(work / label))

    def linux_output(output, target):
        path = output / target / 'debug/identity-probe'
        if not path.is_file():
            return False
        data = path.read_bytes()
        machine = 62 if target.startswith('x86_64-') else 183
        versions = [tuple(map(int, token[6:].decode().split('.'))) for token in data.split(b'\x00')
                    if re.fullmatch(rb'GLIBC_[0-9]+\.[0-9]+(?:\.[0-9]+)?', token)]
        return (data[:5] == b'\x7fELF\x02' and data[5] == 1 and
                int.from_bytes(data[18:20], 'little') == machine and
                bool(versions) and
                all(version + (0,) * (3 - len(version)) <= (2, 28, 0) for version in versions))

    for target in zig_targets:
        env = shim_environment(target, 'zig-proxy-' + target)
        env['RUSTUP_TOOLCHAIN'] = 'fixture-default'
        command = 'cargo +fixture-selected build --quiet --locked --offline --target ' + target
        before, observed, receipt = probe(command, env, zig_shim_dir=shim_dir)
        prebuild, _, _ = probe(command, env, mode='verify', receipt=receipt, zig_shim_dir=shim_dir)
        compiled = build(command, env) if before.returncode == prebuild.returncode == 0 else before
        after, _, _ = probe(command, env, mode='verify', receipt=receipt, zig_shim_dir=shim_dir)
        if compiled.returncode:
            (work / ('zig-build-' + target + '.log')).write_text(compiled.stdout + compiled.stderr)
        check('genuine Zig floor build with Rustup +toolchain records, compiles and verifies ' + target,
              before.returncode == prebuild.returncode == compiled.returncode == after.returncode == 0 and
              linux_output(Path(env['CARGO_TARGET_DIR']), target))
        check('shim and actual Rustup/Cargo/compiler/plugin bytes are independently retained for ' + target,
              observed.get('tools', {}).get('dsr_cargo_shim') == {
                  'program': 'cargo', 'selected_path': str(shim), 'selected_sha256': shim_digest,
                  'selected_kind': 'script', 'version': ''} and
              expected_tool(observed, 'cargo', selected / 'bin/cargo') and
              expected_tool(observed, 'rustc', selected / 'bin/rustc') and
              observed.get('selection', {}).get('dsr_cargo_shim') == {
                  'rust_target': target, 'zig_target': target + '.2.28', 'glibc_floor': '2.28'} and
              observed.get('tools', {}).get('cargo', {}).get('rustup_resolver', {}).get('sha256') == digest(home_manager) and
              all(name in observed.get('tools', {}) for name in ('cargo-zigbuild', 'zig')))

    target = zig_targets[0]
    command = 'cargo build --quiet --locked --offline --target=' + target
    direct_shim_env = shim_environment(target, 'zig-direct', direct=True)
    direct_before, direct_observed, direct_receipt = probe(command, direct_shim_env, zig_shim_dir=shim_dir)
    direct_compiled = build(command, direct_shim_env) if direct_before.returncode == 0 else direct_before
    direct_after, _, _ = probe(command, direct_shim_env, mode='verify', receipt=direct_receipt, zig_shim_dir=shim_dir)
    check('genuine direct Cargo underneath the DSR shim builds the GNU floor without a Rustup manager',
          direct_before.returncode == direct_compiled.returncode == direct_after.returncode == 0 and
          expected_tool(direct_observed, 'cargo', selected / 'bin/cargo') and
          'rustup_resolver' not in direct_observed.get('tools', {}).get('cargo', {}) and
          linux_output(Path(direct_shim_env['CARGO_TARGET_DIR']), target))

    env = shim_environment(target, 'zig-refusals')
    baseline, _, receipt = probe(command, env, zig_shim_dir=shim_dir)
    metadata, _, _ = probe(command, env, mode='metadata', zig_shim_dir=shim_dir)
    context, _, _ = probe(command, env, mode='context', zig_shim_dir=shim_dir)
    context_row = json.loads(context.stdout) if context.returncode == 0 else {}
    check('shim metadata and strict cache context use the real Cargo dispatch PATH',
          baseline.returncode == metadata.returncode == context.returncode == 0 and
          Path(context_row.get('identity', {}).get('tools', {}).get('cargo', {}).get('selected_path', '')) == proxy_cargo and
          str(shim_dir) not in context_row.get('environment', {}).get('PATH', '').split(os.pathsep))

    # Freeze the real programs before an attacker adds an interpreter in the
    # writable PATH directory. Regenerating under that PATH would not exercise
    # the coordinator's original, already-issued verification program.
    emit_verify = '''source "$1" || exit $?;
_act_toolchain_identity_script verify "$2" "$3" '' "$4" "$5" "$6"'''
    frozen_verify = require(['bash', '-c', emit_verify, '_', module, receipt, command,
                             json.dumps(receipt_pins[str(receipt)]), project, shim_dir], env=environment)
    shadow_cache = work / 'bootstrap-cache'
    shadow_cache.mkdir(mode=0o700)
    emit_cache = '''source "$1" || exit $?;
_act_strict_cargo_cache_script "$2" '{}' "$3" "$4"'''
    frozen_cache = require(['bash', '-c', emit_cache, '_', module, shadow_cache, command, shim_dir], env=environment)
    shadow_python = shim_dir / 'python3'
    interpreter_marker = work / 'untrusted-shim-python-executed'
    shadow_python.write_text('#!/bin/sh\nprintf ran > ' + shlex.quote(str(interpreter_marker)) + '\nexit 0\n')
    shadow_python.chmod(0o755)
    for label, frozen in (('pinned post-build verifier', frozen_verify), ('strict-cache interpreter', frozen_cache)):
        refused = run([shutil.which('bash'), '-c', frozen], cwd=project, env=dict(env, GLOBIGNORE='*'))
        check('injected shim-directory Python cannot impersonate the ' + label,
              refused.returncode != 0 and not interpreter_marker.exists() and
              'unexpected entry in generated DSR Cargo shim directory' in refused.stderr)
    shadow_python.rename(work / 'retained-untrusted-shim-python')
    floor_changed_env = dict(env, DSR_ZIG_TARGET=target + '.2.27', DSR_LINUX_GLIBC_FLOOR='2.27')
    floor_changed, _, _ = probe(command, floor_changed_env, mode='verify', receipt=receipt, zig_shim_dir=shim_dir)
    check('changing the floor with unchanged shim and compiler bytes invalidates the pinned observation',
          floor_changed.returncode != 0 and 'changed during the build' in floor_changed.stderr)

    # An interior empty field means current-directory lookup in the actual
    # POSIX shim. A probe that drops it would attest dispatch-bin/cargo while
    # the launcher executes this different, genuine Rustup proxy path.
    empty_bin = work / 'empty-path-bin'
    empty_bin.mkdir()
    cwd_cargo = project / 'cargo'
    os.link(proxy_cargo, cwd_cargo)
    empty_env = shim_environment(target, 'zig-empty-path')
    empty_env['PATH'] = str(shim_dir) + ':' + str(empty_bin) + '::' + str(dispatch_bin)
    empty_before, empty_observed, empty_receipt = probe(command, empty_env, zig_shim_dir=shim_dir)
    empty_build = build(command, empty_env) if empty_before.returncode == 0 else empty_before
    empty_after, _, _ = probe(command, empty_env, mode='verify', receipt=empty_receipt, zig_shim_dir=shim_dir)
    check('interior empty PATH field attests the same genuine current-directory Cargo used by the shim',
          empty_before.returncode == empty_build.returncode == empty_after.returncode == 0 and
          empty_observed.get('tools', {}).get('cargo', {}).get('selected_path') == str(cwd_cargo) and
          expected_tool(empty_observed, 'cargo', selected / 'bin/cargo') and
          linux_output(Path(empty_env['CARGO_TARGET_DIR']), target))
    cwd_cargo.rename(work / 'retained-current-directory-cargo')

    swap_env = shim_environment(target, 'zig-postbuild-swap')
    swap_command = command + " && printf '%s\\n' '#!/bin/sh' 'exit 0' > " + shlex.quote(str(shim))
    swap_before, _, swap_receipt = probe(swap_command, swap_env, zig_shim_dir=shim_dir)
    swap_build = build(swap_command, swap_env) if swap_before.returncode == 0 else swap_before
    swap_after, _, _ = probe(swap_command, swap_env, mode='verify', receipt=swap_receipt, zig_shim_dir=shim_dir)
    check('successful genuine Zig compile cannot publish after replacing its shim during the build',
          swap_before.returncode == swap_build.returncode == 0 and swap_after.returncode != 0 and
          linux_output(Path(swap_env['CARGO_TARGET_DIR']), target) and
          'trusted generator bytes' in swap_after.stderr)
    shim.rename(work / 'retained-postbuild-zig-shim')
    require(['bash', '-o', 'pipefail', '-c', staging, '_', module, shim_dir], env=environment)

    # Never execute a substituted shim, even its version branch, and never
    # admit new bytes because the compiler-writable file says it is DSR's.
    shim.rename(work / 'retained-original-zig-shim')
    marker = work / 'untrusted-zig-shim-executed'
    shim.write_text('#!/bin/sh\nprintf ran > ' + shlex.quote(str(marker)) + '\nexit 0\n')
    shim.chmod(0o755)
    for probe_mode in ('record', 'verify', 'metadata', 'context'):
        refused, _, refused_receipt = probe(command, env, mode=probe_mode,
                                           receipt=receipt if probe_mode == 'verify' else None,
                                           zig_shim_dir=shim_dir)
        check('unexpected DSR shim replacement refuses before execution in ' + probe_mode,
              refused.returncode != 0 and not marker.exists() and
              'trusted generator bytes' in refused.stderr and
              (probe_mode == 'verify' or not refused_receipt.exists()))
    shim.rename(work / 'retained-untrusted-zig-shim')
    (work / 'retained-original-zig-shim').rename(shim)
    restored, _, _ = probe(command, env, mode='verify', receipt=receipt, zig_shim_dir=shim_dir)
    check('restored exact generated shim retains the original pinned observation', restored.returncode == 0)

    for variable in ('DSR_RUST_TARGET', 'DSR_ZIG_TARGET', 'DSR_LINUX_GLIBC_FLOOR'):
        refused, _, _ = probe(variable + '= ' + command, env, zig_shim_dir=shim_dir)
        check('command cannot disable glibc-floor dispatch by overriding ' + variable,
              refused.returncode != 0 and 'cannot override generated DSR Cargo shim' in refused.stderr)
        missing = dict(env)
        missing.pop(variable)
        refused, _, _ = probe(command, missing, zig_shim_dir=shim_dir)
        check('missing glibc-floor dispatch selector fails closed: ' + variable,
              refused.returncode != 0 and 'target/floor' in refused.stderr)
    wrong_path = dict(env, PATH=dispatch_env['PATH'] + ':' + str(shim_dir))
    refused, _, _ = probe(command, wrong_path, zig_shim_dir=shim_dir)
    check('removing the DSR shim from the selected PATH position refuses admission',
          refused.returncode != 0 and 'selected first PATH entry' in refused.stderr)
    shim.rename(work / 'retained-zig-shim-symlink-target')
    shim.symlink_to(work / 'retained-zig-shim-symlink-target')
    refused, _, _ = probe(command, env, zig_shim_dir=shim_dir)
    check('a byte-identical symlink replacement is not the generated regular shim',
          refused.returncode != 0 and 'cannot admit generated DSR Cargo shim' in refused.stderr)
    shim.rename(work / 'retained-zig-shim-symlink')
    (work / 'retained-zig-shim-symlink-target').rename(shim)

    # The recognized wrapper cannot conceal replacement of the real compiler.
    compiler_before_swap = digest(compiler)
    with compiler.open('ab') as stream:
        stream.write(b'changed underlying compiler after Zig admission\n')
    refused, _, _ = probe(command, env, mode='verify', receipt=receipt, zig_shim_dir=shim_dir)
    # A changed signed Mach-O may be refused by the OS at its version probe;
    # Linux can reach the final byte comparison. Both must refuse the same
    # original valid observation, with independently confirmed byte drift.
    check('underlying compiler replacement invalidates the original shim receipt',
          baseline.returncode == 0 and digest(compiler) != compiler_before_swap and refused.returncode != 0)
    compiler.rename(work / 'retained-zig-drift-rustc')
    shutil.copy2(real_toolchain_executable('rustc', alternate_sysroot / 'bin/rustc'), compiler)

    if '-nightly' in require([selected / 'bin/cargo', '-V']):
        cache_root = work / 'zig-cache'
        cache_root.mkdir(mode=0o700)
        cache_env = shim_environment(target, 'zig-cached-output')
        cache_command = 'cargo +fixture-selected build --quiet --locked --offline --target ' + target
        cache_program = '''source "$1" || exit $?;
_act_strict_cargo_cache_script "$2" '{}' "$3" "$4" | bash'''
        before_cache, _, cache_receipt = probe(cache_command, cache_env, zig_shim_dir=shim_dir)
        cached_build = run(['bash', '-o', 'pipefail', '-c', cache_program, '_', module,
                            cache_root, cache_command, shim_dir], cwd=project, env=cache_env, timeout=240)
        after_cache, _, _ = probe(cache_command, cache_env, mode='verify', receipt=cache_receipt,
                                  zig_shim_dir=shim_dir)
        (work / 'zig-cache.log').write_text(cached_build.stdout + cached_build.stderr)
        check('strict intermediate cache probes underlying Cargo while the real build still uses Zig floor shim',
              before_cache.returncode == cached_build.returncode == after_cache.returncode == 0 and
              linux_output(Path(cache_env['CARGO_TARGET_DIR']), target) and
              'DSR_CARGO_CACHE namespace=' in cached_build.stdout)
        first_cache_file = Path(cache_env['CARGO_TARGET_DIR'] + '.cache-receipt.json')
        first_cache = json.loads(first_cache_file.read_text()) if first_cache_file.is_file() else {}
        relocated = work / 'cache-relocated-source'
        shutil.copytree(project, relocated)
        for label, floor in (('same-floor', '2.28'), ('different-floor', '2.27')):
            next_shim = work / ('cache-' + label + '-shim')
            require(['bash', '-o', 'pipefail', '-c', staging, '_', module, next_shim], env=environment)
            next_env = dict(cache_env, PATH=str(next_shim) + ':' + dispatch_env['PATH'],
                            DSR_ZIG_TARGET=target + '.' + floor, DSR_LINUX_GLIBC_FLOOR=floor,
                            CARGO_TARGET_DIR=str(work / ('zig-cached-' + label)))
            next_before, _, next_receipt = probe(cache_command, next_env, cwd=relocated,
                                                 expected_cwd=relocated, zig_shim_dir=next_shim)
            next_build = run(['bash', '-o', 'pipefail', '-c', cache_program, '_', module,
                              cache_root, cache_command, next_shim], cwd=relocated, env=next_env, timeout=240)
            next_after, _, _ = probe(cache_command, next_env, mode='verify', receipt=next_receipt,
                                     cwd=relocated, expected_cwd=relocated, zig_shim_dir=next_shim)
            next_cache_file = Path(next_env['CARGO_TARGET_DIR'] + '.cache-receipt.json')
            next_cache = json.loads(next_cache_file.read_text()) if next_cache_file.is_file() else {}
            (work / ('zig-cache-' + label + '.log')).write_text(next_build.stdout + next_build.stderr)
            same_namespace = first_cache.get('namespace') == next_cache.get('namespace')
            check('fresh source and generated shim retain cache policy: ' + label,
                  next_before.returncode == next_build.returncode == next_after.returncode == 0 and
                  bool(first_cache.get('namespace')) and bool(next_cache.get('namespace')) and
                  same_namespace == (label == 'same-floor') and
                  next_cache.get('contract', {}).get('environment', {}).get('DSR_LINUX_GLIBC_FLOOR') == floor and
                  linux_output(Path(next_env['CARGO_TARGET_DIR']), target))
    elif mode == 'zig-shim':
        check('dedicated Zig shim qualification requires nightly for the strict-cache regression', False)
    else:
        print('SKIP glibc-floor intermediate cache requires nightly Cargo/rustc', flush=True)
else:
    print('SKIP generated Zig shim regression requires real Zig/Cargo plugin and both GNU target stdlibs', flush=True)

if mode == 'zig-shim':
    print(f'Zig shim qualification: {passed} passed, {failed} failed; fixtures retained at {work}', flush=True)
    sys.exit(1 if failed else 0)


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
config_path.write_text('[env]\nRUST_MIN_STACK = "8388608"\nRUST_TEST_THREADS = "1"\nLIBSQLITE3_FLAGS = "-DSQLITE_ENABLE_MATH_FUNCTIONS"\n')
env_stack = dict(environment, CARGO_TARGET_DIR=str(work / 'stack-output'))
command = 'cargo build --quiet --offline'
result, data, receipt = probe(command, env_stack)
compiled = build(command, env_stack)
check('RUST_MIN_STACK and RUST_TEST_THREADS in tracked [env] are admitted and the real build still runs',
      result.returncode == 0 and compiled.returncode == 0 and
      require([work / 'stack-output' / host / 'debug/identity-probe']) == '42')
check('admitted RUST_MIN_STACK and RUST_TEST_THREADS are recorded by name and value in the receipt',
      data.get('selection', {}).get('cargo_config') == [{
          'path': str(config_path), 'sha256': digest(config_path),
          'env_exemptions': [{'name': 'RUST_MIN_STACK', 'value': '8388608', 'force': False,
                              'effective_value': '8388608', 'effective_force': False,
                              'effective_source': 'configuration'},
                             {'name': 'RUST_TEST_THREADS', 'value': '1', 'force': False,
                              'effective_value': '1', 'effective_force': False,
                              'effective_source': 'configuration'}]}])
after, _, _ = probe(command, env_stack, mode='verify', receipt=receipt)
check('unchanged RUST_MIN_STACK configuration passes the post-build probe', after.returncode == 0)
config_path.rename(work / 'retained-stack-config.toml')
# Legitimate cfg linkers and numeric tables are now positive cases, not
# silently dropped refusal checks. Each runs genuine Cargo and final verify.
for label, contents in (
    ('cfg-linker', '[target.\'cfg(unix)\']\nlinker="cc"\n'),
    ('stack-table-default', '[env]\nRUST_MIN_STACK={value="16777216", force=false}\n'),
    ('stack-table-force', '[env]\nRUST_MIN_STACK={value="16777216", force=true}\n'),
    ('threads-table', '[env]\nRUST_TEST_THREADS={value="2", relative=false}\n'),
):
    config_path.write_text(contents)
    case_env = dict(environment, CARGO_TARGET_DIR=str(work / (label + '-output')))
    recorded, data, receipt = probe('cargo build --quiet --offline', case_env)
    compiled = build('cargo build --quiet --offline', case_env)
    verified, _, _ = probe('cargo build --quiet --offline', case_env, mode='verify', receipt=receipt)
    check(label + ' admits, genuinely builds, and verifies the unchanged observation',
          recorded.returncode == 0 and compiled.returncode == 0 and verified.returncode == 0 and
          require([work / (label + '-output') / host / 'debug/identity-probe']) == '42')
    config_path.rename(work / ('retained-' + label + '.toml'))
for label, contents in (
    ('unsupported cfg linker', '[target.\'cfg(feature="hidden")\']\nlinker="cc"\n'),
    ('environment compiler', '[env]\nRUSTC="/bin/true"\n'),
    ('environment RUSTFLAGS', '[env]\nRUSTFLAGS="-C debuginfo=0"\n'),
    ('environment RUST_MIN_STACK_X near miss', '[env]\nRUST_MIN_STACK_X="8388608"\n'),
    ('environment non-numeric RUST_MIN_STACK', '[env]\nRUST_MIN_STACK="abc"\n'),
    ('environment zero RUST_MIN_STACK', '[env]\nRUST_MIN_STACK="0"\n'),
    ('environment relative RUST_MIN_STACK', '[env]\nRUST_MIN_STACK={value="8388608", relative=true}\n'),
    ('environment RUST_MIN_STACK beside RUSTFLAGS', '[env]\nRUST_MIN_STACK="8388608"\nRUSTFLAGS="-C debuginfo=0"\n'),
    ('environment RUST_TEST_THREADS_X near miss', '[env]\nRUST_TEST_THREADS_X="1"\n'),
    ('environment non-numeric RUST_TEST_THREADS', '[env]\nRUST_TEST_THREADS="auto"\n'),
    ('environment zero RUST_TEST_THREADS', '[env]\nRUST_TEST_THREADS="0"\n'),
    ('environment negative RUST_TEST_THREADS', '[env]\nRUST_TEST_THREADS="-1"\n'),
    ('environment integer-typed RUST_TEST_THREADS', '[env]\nRUST_TEST_THREADS=1\n'),
    ('environment unknown RUST_TEST_THREADS attribute', '[env]\nRUST_TEST_THREADS={value="1", unknown=true}\n'),
    ('environment RUST_TEST_THREADS beside RUSTFLAGS', '[env]\nRUST_TEST_THREADS="1"\nRUSTFLAGS="-C debuginfo=0"\n'),
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
    for name in ('bash', 'python3', 'cat', 'dirname', 'date', 'jq', 'cc', 'c++', 'xcrun', 'xcodebuild', 'ld', 'ar'):
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
