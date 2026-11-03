#!/usr/bin/env python3
"""Selection regressions against the shell-generated production observer.

No fake Rust version is substituted for compiler evidence. Parser/selection
unit tests use explicit synthetic target facts. The executable tests below run
only target planning and pre-compiler refusal paths; they do not claim a build.
Temporary configurations are retained, never automatically deleted.
"""
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
MODULE = Path(os.environ.get('DSR_TEST_ACT_RUNNER', str(ROOT / 'src/act_runner.sh')))
TRIPLE = 'x86_64-unknown-linux-gnu'
EMIT = 'source "$1" || exit $?; _act_toolchain_identity_script "$2" "$3" "$4" "" "" "" "$5"'


def emit(mode, command, shim_dir='', receipt='/tmp/dsr-unused-receipt.json'):
    return subprocess.run(['bash', '-o', 'pipefail', '-c', EMIT, '_', str(MODULE),
                           mode, str(receipt), command, str(shim_dir)],
                          capture_output=True, text=True, check=True, timeout=30).stdout


program = emit('record', 'cargo build')
python_text = program.split("<<'DSR_TOOLCHAIN_IDENTITY_PY'\n", 1)[1].rsplit('\nDSR_TOOLCHAIN_IDENTITY_PY', 1)[0]
# Compile the complete emitted Python, not a hand-copied implementation.
tree = ast.parse(python_text)
compile(tree, str(MODULE), 'exec')
namespace = dict(hashlib=hashlib, json=json, os=os, pathlib=__import__('pathlib'),
                 re=re, shlex=shlex, shutil=shutil, stat=stat,
                 subprocess=subprocess, sys=sys)
exec(compile(ast.Module(body=[node for node in tree.body if isinstance(node, ast.FunctionDef)],
                        type_ignores=[]), str(MODULE), 'exec'), namespace)


class Refused(Exception):
    pass


def refuse(message):
    raise Refused(message)


namespace['fail'] = refuse


def invoke(command, cfg=True, mode='record', environment=None):
    namespace.update(command=command, mode=mode,
                     cargo_config={'build': {}, 'alias': {}, 'target':
                                   {'cfg(unix)': {'rustflags': []}} if cfg else {}})
    with patch.dict(os.environ, {'CARGO_BUILD_TARGET': TRIPLE} if environment is None else environment, clear=True):
        return namespace['invocation_selection']()


def read_config(text):
    work = Path(tempfile.mkdtemp(prefix='dsr-cargo-invocation-')).resolve()
    (work / '.cargo').mkdir()
    (work / '.cargo/config.toml').write_text(text)
    old = Path.cwd()
    try:
        os.chdir(work)
        with patch.dict(os.environ, {'CARGO_HOME': str(work / 'private-cargo')}, clear=True):
            return namespace['cargo_configuration']()
    finally:
        os.chdir(old)


def facts(arch='x86_64', system='linux'):
    family = 'windows' if system == 'windows' else 'unix'
    return {(family, None), ('target_arch', arch), ('target_os', system),
            ('target_env', 'gnu'), ('target_vendor', 'unknown'), ('target_family', family),
            ('target_endian', 'little'), ('target_pointer_width', '64')}


class InvocationBoundaryTests(unittest.TestCase):
    def test_cfg_refuses_unstable_options_before_and_after_subcommand(self):
        for mode in ('record', 'verify', 'metadata', 'context'):
            for command in ('cargo -Zhost-config build', 'cargo build -Zhost-config',
                            'cargo build -Z host-config', 'cargo build --release -Zprofile-rustflags',
                            'cargo build -vvZhost-config', 'cargo build -qZprofile-rustflags'):
                with self.subTest(mode=mode, command=command), self.assertRaisesRegex(Refused, 'unstable Cargo'):
                    invoke(command, mode=mode)

    def test_rustc_flags_are_not_cargo_unstable_options(self):
        self.assertEqual(invoke('cargo rustc --release -- -Z threads=4')[0]['target'], TRIPLE)
        for command in ('cargo rustc -- --cfg target_os="windows"',
                        'cargo rustc -- -Zcodegen-backend=evil',
                        'cargo rustc -- --codegen=linker=evil', 'cargo rustc -- @hidden.args'):
            with self.subTest(command=command), self.assertRaises(Refused):
                invoke(command)

    def test_application_arguments_do_not_select_compiler_target(self):
        for subcommand in ('run', 'test', 'bench'):
            for tail in ('--target aarch64-apple-darwin', '--target=wasm32-unknown-unknown',
                         '--manifest-path elsewhere/Cargo.toml', '-Zhost-config'):
                with self.subTest(subcommand=subcommand, tail=tail):
                    result = invoke('cargo ' + subcommand + ' -- ' + tail, mode='metadata')
                    self.assertEqual(result[0]['target'], TRIPLE)

    def test_real_cargo_target_before_separator_remains_authoritative(self):
        selected = 'aarch64-apple-darwin'
        result = invoke('cargo run --target ' + selected + ' -- --target ' + TRIPLE)
        self.assertEqual(result[0]['target'], selected)
        with self.assertRaisesRegex(Refused, 'multiple Cargo targets'):
            invoke('cargo build --target ' + selected + ' --target ' + TRIPLE)

    def test_run_tail_cannot_forge_target_in_actual_planning_process(self):
        command = 'cargo run -- --target aarch64-apple-darwin'
        environment = dict(os.environ, CARGO_BUILD_TARGET=TRIPLE, DSR_TARGET_TRIPLE=TRIPLE)
        result = subprocess.run(['bash'], input=emit('target', command), text=True,
                                capture_output=True, env=environment, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), TRIPLE)

    def test_actual_observer_refuses_unstable_cfg_before_compiler_lookup(self):
        work = Path(tempfile.mkdtemp(prefix='dsr-cargo-preflight-')).resolve()
        (work / '.cargo').mkdir()
        (work / '.cargo/config.toml').write_text('[target.\'cfg(unix)\']\nrustflags=[]\n')
        environment = {name: value for name, value in os.environ.items()
                       if not name.startswith(('CARGO_', 'RUST'))}
        environment.update(CARGO_HOME=str(work / 'private-cargo'), CARGO_BUILD_TARGET=TRIPLE)
        for mode in ('record', 'metadata', 'context'):
            result = subprocess.run(['bash'], input=emit(mode, 'cargo build -Zhost-config'),
                                    text=True, capture_output=True, cwd=work,
                                    env=environment, timeout=30)
            self.assertEqual(result.returncode, 86, result.stderr)
            self.assertIn('unstable Cargo', result.stderr)
            self.assertNotIn('required executable not found', result.stderr)
            self.assertEqual(result.stdout, '')

    def test_existing_environment_config_and_shell_refusals_survive(self):
        for command in ('cargo build --config build.rustc="evil"',
                        'cargo -C other build', 'CARGO_HOME=/other cargo build',
                        'cargo build --target one-target --target another-target',
                        'cd elsewhere; cargo build', 'cargo build &',
                        'RUSTC=one cargo build; RUSTC=two cargo build'):
            with self.subTest(command=command), self.assertRaises(Refused):
                invoke(command)

    def test_normal_release_invocations_survive(self):
        for command in ('cargo build --release --locked --offline',
                        'cargo +nightly build --release --target ' + TRIPLE,
                        'command cargo build --locked', 'cargo --color never build --release'):
            with self.subTest(command=command):
                self.assertEqual(invoke(command)[0]['target'], TRIPLE)

    def test_explicit_zig_targets_preserve_the_request_and_select_the_rust_target(self):
        for target in (TRIPLE, 'aarch64-unknown-linux-gnu'):
            for spelling in ('--target ', '--target='):
                command = 'cargo +nightly --quiet zigbuild ' + spelling + target + '.2.17'
                environment = {'CARGO_BUILD_TARGET': target, 'DSR_TARGET_TRIPLE': target,
                               'DSR_LINUX_GLIBC_FLOOR': '2.28'}
                with self.subTest(command=command):
                    selected = invoke(command, environment=environment)[0]
                    self.assertEqual(selected['target'], target)
                    self.assertEqual(selected['cargo_zigbuild'], {
                        'rust_target': target, 'zig_target': target + '.2.17', 'glibc_floor': '2.17'})
                    # The declared output ceiling does not rewrite a request
                    # for an older, more portable GNU ABI.
                    self.assertEqual(selected['environment']['DSR_LINUX_GLIBC_FLOOR'], '2.28')

    def test_version_suffix_is_not_a_generic_target_rewrite(self):
        for command in ('cargo build --target ' + TRIPLE + '.2.28',
                        'cargo zigbuild --target ' + TRIPLE + '.2..28',
                        'cargo zigbuild --target ' + TRIPLE + '.2.28.0',
                        'cargo zigbuild --target ' + TRIPLE + '.2',
                        'cargo zigbuild --target x86_64-unknown-linux-musl.2.28',
                        'cargo zigbuild --target aarch64-apple-darwin.2.28'):
            with self.subTest(command=command), self.assertRaises(Refused):
                invoke(command)
        with self.assertRaisesRegex(Refused, 'versioned targets'):
            invoke('cargo zigbuild', environment={'CARGO_BUILD_TARGET': TRIPLE + '.2.28'})

    def test_explicit_zig_conflicting_tasks_and_floors_are_refused(self):
        first = 'cargo zigbuild --target ' + TRIPLE + '.2.28'
        for command in (first + ' && cargo zigbuild --target ' + TRIPLE + '.2.17',
                        first + ' && cargo build --target ' + TRIPLE,
                        first + ' --target ' + TRIPLE + '.2.17',
                        'cargo zigbuild --target aarch64-unknown-linux-gnu.2.28',
                        'DSR_TARGET_TRIPLE=elsewhere cargo zigbuild --target ' + TRIPLE + '.2.28',
                        'CARGO_BUILD_TARGET=elsewhere cargo zigbuild --target ' + TRIPLE + '.2.28'):
            with self.subTest(command=command), self.assertRaises(Refused):
                invoke(command)
        self.assertEqual(invoke(first + ' && ' + first)[0]['target'], TRIPLE)

    def test_actual_coordinator_selection_and_matrix_guard_agree(self):
        program = '''source "$1" || exit $?;
_act_validate_native_target_command "$2" "$3" "$4" || exit $?;
_act_explicit_zigbuild_selection "$2" "$3"'''
        for target in (TRIPLE, 'aarch64-unknown-linux-gnu'):
            command = 'cargo +selected --offline zigbuild --target=' + target + '.2.28'
            environment = 'CARGO_BUILD_TARGET=' + target + '\nDSR_TARGET_TRIPLE=' + target
            result = subprocess.run(['bash', '-c', program, '_', str(MODULE), command,
                                     environment, target], text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {
                'rust_target': target, 'zig_target': target + '.2.28', 'glibc_floor': '2.28'})

    def test_worker_shell_startup_cannot_execute_during_coordinator_planning(self):
        work = Path(tempfile.mkdtemp(prefix='dsr-zig-coordinator-')).resolve()
        marker = work / 'worker-startup-ran-on-coordinator'
        startup = work / 'worker-startup.sh'
        startup.write_text('printf ran > ' + shlex.quote(str(marker)) + '\n')
        command = 'cargo zigbuild --target=' + TRIPLE + '.2.28'
        environment = ('CARGO_BUILD_TARGET=' + TRIPLE + '\nDSR_TARGET_TRIPLE=' + TRIPLE +
                       '\nBASH_ENV=' + str(startup))
        program = '''source "$1" || exit $?;
_act_validate_native_target_command "$2" "$3" "$4" || exit $?;
_act_explicit_zigbuild_selection "$2" "$3"'''
        result = subprocess.run(['bash', '-c', program, '_', str(MODULE), command, environment,
                                 TRIPLE], text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['rust_target'], TRIPLE)
        self.assertFalse(marker.exists())


class ZigShimAdmissionTests(unittest.TestCase):
    """Exercise actual generated admission before any compiler is available.

    These are filesystem, command-selection and PATH tests. They deliberately
    stop before executable identity and cannot qualify a Cargo/Zig build; that
    remains the job of test_toolchain_identity.sh --zig-shim-only on a host
    with genuine Rustup, Cargo, Zig and the two Linux standard libraries.
    """

    zig_selectors = ('CARGO_ZIGBUILD_ZIG_COMMAND', 'CARGO_ZIGBUILD_ZIG_COMMAND_ARGS',
                     'CARGO_ZIGBUILD_PYTHON_PATH', 'CARGO_ZIGBUILD_ZIG_PATH',
                     'CARGO_ZIGBUILD_ZIG_VERSION')

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix='dsr-zig-admission-')).resolve()
        self.project = self.work / 'source'
        self.project.mkdir()
        self.shim_dir = self.work / 'shim'
        self.receipt = self.work / 'receipt.json'
        staging = subprocess.run(
            ['bash', '-o', 'pipefail', '-c',
             'source "$1" || exit $?; _act_zig_shim_prefix_sh "$2" | bash',
             '_', str(MODULE), str(self.shim_dir)],
            capture_output=True, text=True, check=True, timeout=30)
        self.assertEqual(staging.stdout, '')
        self.shim = self.shim_dir / 'cargo'
        self.generator = subprocess.run(
            ['bash', '-c', 'source "$1" || exit $?; _act_zig_cargo_shim_sh', '_', str(MODULE)],
            capture_output=True, check=True, timeout=30).stdout
        self.environment = {name: value for name, value in os.environ.items()
                            if not name.startswith(('CARGO_', 'RUST', 'DSR_'))}
        self.environment.update(CARGO_HOME=str(self.work / 'cargo-home'),
                                CARGO_BUILD_TARGET=TRIPLE, DSR_RUST_TARGET=TRIPLE,
                                DSR_ZIG_TARGET=TRIPLE + '.2.28', DSR_LINUX_GLIBC_FLOOR='2.28',
                                PATH=str(self.shim_dir) + os.pathsep + os.environ['PATH'])

    def admission(self, target=TRIPLE, path=None, shim=True):
        """Run the emitted Python through shim admission, before tool probes.

        Keep the generated argv (including the controller-derived hash) and
        every preceding production statement. Expose only the already-observed
        pre-compiler state; never replace a tool or fabricate its version.
        """
        command = 'cargo +fixture-selected build --release --locked --target ' + target
        script = emit('record', command, self.shim_dir if shim else '', self.receipt)
        header, body = script.split("<<'DSR_TOOLCHAIN_IDENTITY_PY'\n", 1)
        argv = shlex.split(header.splitlines()[-1].strip())[2:]
        module = ast.parse(body.rsplit('\nDSR_TOOLCHAIN_IDENTITY_PY', 1)[0])
        prefix = []
        for node in module.body:
            if isinstance(node, ast.FunctionDef) and node.name == 'run':
                break
            prefix.append(node)
        else:
            self.fail('generated observer has no pre-compiler admission boundary')
        environment = dict(self.environment, CARGO_BUILD_TARGET=target,
                           DSR_RUST_TARGET=target, DSR_ZIG_TARGET=target + '.2.28')
        if path is not None:
            environment['PATH'] = path
        namespace = {'__name__': '__main__'}
        previous = Path.cwd()
        try:
            os.chdir(self.project)
            with patch.dict(os.environ, environment, clear=True), patch.object(sys, 'argv', argv):
                exec(compile(ast.Module(body=prefix, type_ignores=[]), str(MODULE), 'exec'), namespace)
            return {key: namespace[key] for key in ('zig_shim_record', 'selection', 'probe_env')}
        finally:
            os.chdir(previous)
            if namespace.get('zig_shim_file') is not None:
                namespace['zig_shim_file'].close()
            if namespace.get('zig_shim_parent') is not None:
                os.close(namespace['zig_shim_parent'])
            self.assertFalse(self.receipt.exists(), 'admission alone must not publish compiler evidence')

    def observe(self, mode='record', environment=None, script=None, prefix=''):
        # An intentional dispatch override is the final pre-compiler sentinel.
        # Exact shims reach it; malformed shims must fail earlier. No installed
        # Rust or Zig command can run even when one exists on the test host.
        environment = dict(environment or self.environment, RUSTUP_FORCE_ARG0='rustup')
        script = script or emit(mode, 'cargo build --release --locked --target ' + TRIPLE,
                                self.shim_dir, self.receipt)
        return subprocess.run(['bash', '-c', prefix + script], cwd=self.project,
                              env=environment, text=True, capture_output=True, timeout=30)

    def assert_refused(self, result, message):
        self.assertEqual(result.returncode, 86, result.stderr)
        self.assertIn(message, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertFalse(self.receipt.exists())

    def test_exact_generator_bytes_and_underlying_dispatch_for_both_linux_architectures(self):
        self.assertEqual(self.shim.read_bytes(), self.generator)
        for target in (TRIPLE, 'aarch64-unknown-linux-gnu'):
            with self.subTest(target=target):
                observed = self.admission(target)
                self.assertEqual(observed['zig_shim_record'], {
                    'program': 'cargo', 'selected_path': str(self.shim),
                    'selected_sha256': hashlib.sha256(self.generator).hexdigest(),
                    'selected_kind': 'script', 'version': ''})
                self.assertEqual(observed['selection']['toolchain'], 'fixture-selected')
                self.assertEqual(observed['selection']['target'], target)
                self.assertEqual(observed['probe_env']['PATH'], os.environ['PATH'])

    def test_delegated_path_preserves_posix_empty_fields_and_removes_only_exact_shim_entries(self):
        first, second = str(self.work / 'first'), str(self.work / 'second')
        shim = str(self.shim_dir)
        for path, expected in ((shim + '::' + first, first),
                               (shim + ':' + first + '::' + second, first + '::' + second),
                               (shim + ':' + first + ':', first),
                               (shim + ':' + first + '::', first + ':'),
                               (shim + ':' + first + ':' + shim + ':' + second, first + ':' + second)):
            with self.subTest(path=path):
                self.assertEqual(self.admission(path=path)['probe_env']['PATH'], expected)

    def test_mixed_platform_selection_does_not_carry_linux_shim_authority_to_native_targets(self):
        # Deterministic selection matrix only, not a mixed release execution.
        for target, shim in ((TRIPLE, True), ('aarch64-apple-darwin', False),
                             ('aarch64-unknown-linux-gnu', True), ('x86_64-pc-windows-msvc', False),
                             ('x86_64-apple-darwin', False)):
            with self.subTest(target=target):
                path = self.environment['PATH'] if shim else os.environ['PATH']
                observed = self.admission(target, path=path, shim=shim)
                self.assertEqual(observed['selection']['target'], target)
                self.assertEqual(observed['zig_shim_record'] is not None, shim)
                self.assertEqual(observed['probe_env']['PATH'], os.environ['PATH'])

    def test_substituted_shim_cannot_rebase_controller_hash_or_execute_a_version_probe(self):
        frozen = {mode: emit(mode, 'cargo build --target ' + TRIPLE, self.shim_dir, self.receipt)
                  for mode in ('record', 'metadata', 'context')}
        marker = self.work / 'substituted-shim-executed'
        self.shim.write_text('#!/bin/sh\nprintf ran > ' + shlex.quote(str(marker)) + '\nexit 0\n')
        environment = dict(self.environment, DSR_ZIG_SHIM_SHA256=hashlib.sha256(self.shim.read_bytes()).hexdigest())
        for mode, script in frozen.items():
            with self.subTest(mode=mode):
                self.assert_refused(self.observe(mode, environment, script), 'trusted generator bytes')
                self.assertFalse(marker.exists())

    def test_byte_identical_symlink_and_writable_shim_are_refused(self):
        original = self.work / 'original-cargo'
        self.shim.rename(original)
        self.shim.symlink_to(original)
        self.assert_refused(self.observe(), 'cannot admit generated DSR Cargo shim')
        self.shim.rename(self.work / 'retained-symlink')
        original.rename(self.shim)
        self.shim.chmod(0o777)
        self.assert_refused(self.observe(), 'trusted generator bytes or ownership')

    def test_unexpected_directory_entries_refuse_before_interpreter_selection_even_with_glob_options(self):
        frozen = emit('record', 'cargo build --target ' + TRIPLE, self.shim_dir, self.receipt)
        for index, name in enumerate(('python3', '.hidden', '..hidden')):
            with self.subTest(entry=name):
                marker = self.work / ('interpreter-executed-' + str(index))
                extra = self.shim_dir / name
                extra.write_text('#!/bin/sh\nprintf ran > ' + shlex.quote(str(marker)) + '\nexit 0\n')
                extra.chmod(0o755)
                result = self.observe(script=frozen,
                                      prefix="set -f; shopt -s failglob nullglob; GLOBIGNORE='*';\n")
                self.assert_refused(result, 'unexpected entry in generated DSR Cargo shim directory')
                self.assertFalse(marker.exists())
                extra.rename(self.work / ('retained-extra-' + str(index)))

    def test_python_alias_of_modified_shim_cannot_impersonate_observer_or_strict_cache(self):
        scripts = {mode: emit(mode, 'cargo build --target ' + TRIPLE, self.shim_dir, self.receipt)
                   for mode in ('record', 'verify', 'metadata', 'context')}
        cache_root = self.work / 'cache'
        cache_root.mkdir(mode=0o700)
        scripts['cache'] = subprocess.run(
            ['bash', '-c', 'source "$1" || exit $?; _act_strict_cargo_cache_script "$2" \'{}\' "$3" "$4"',
             '_', str(MODULE), str(cache_root), 'cargo build --target ' + TRIPLE, str(self.shim_dir)],
            capture_output=True, text=True, check=True, timeout=30).stdout
        for index, link in enumerate(('symlink', 'hardlink')):
            directory = self.work / ('interpreter-alias-' + link)
            directory.mkdir()
            alias = directory / 'python3'
            if link == 'symlink':
                alias.symlink_to(self.shim)
            else:
                os.link(self.shim, alias)
            marker = self.work / ('aliased-shim-executed-' + str(index))
            # Freeze the trusted program first, then mutate the only allowed
            # directory entry. The delegated Python name aliases that same
            # inode, bypassing a check based only on its lexical parent.
            self.shim.write_text('#!/bin/sh\nprintf ran > ' + shlex.quote(str(marker)) + '\nexit 0\n')
            environment = dict(self.environment,
                               PATH=str(self.shim_dir) + ':' + str(directory) + ':' + os.environ['PATH'])
            for mode, script in scripts.items():
                with self.subTest(link=link, mode=mode):
                    self.assert_refused(self.observe(environment=environment, script=script), 'Python cannot')
                    self.assertFalse(marker.exists())
                    self.assertEqual(list(cache_root.iterdir()), [])

    def test_external_python_symlink_still_reaches_the_real_precompiler_guard(self):
        directory = self.work / 'trusted-python'
        directory.mkdir()
        (directory / 'python3').symlink_to(Path(sys.executable).resolve())
        environment = dict(self.environment,
                           PATH=str(self.shim_dir) + ':' + str(directory) + ':' + os.environ['PATH'])
        self.assert_refused(self.observe(environment=environment), 'configured Rustup dispatch overrides')

    def test_path_substitution_globs_and_recursive_aliases_are_refused(self):
        alias = self.work / 'alias'
        alias.symlink_to(self.shim_dir, target_is_directory=True)
        for path, message in ((os.environ['PATH'] + ':' + str(self.shim_dir), 'selected first PATH entry'),
                              (self.environment['PATH'] + ':glob-*', 'globbed PATH entries'),
                              (self.environment['PATH'] + ':' + str(alias), 'recursive alias')):
            with self.subTest(path=path):
                self.assert_refused(self.observe(environment=dict(self.environment, PATH=path)), message)

    def test_target_floor_changes_refuse_before_compiler_execution(self):
        for field, value in (('DSR_RUST_TARGET', 'aarch64-unknown-linux-gnu'),
                             ('DSR_ZIG_TARGET', TRIPLE + '.2.29'),
                             ('DSR_LINUX_GLIBC_FLOOR', ''), ('DSR_LINUX_GLIBC_FLOOR', '2.28.0')):
            with self.subTest(field=field, value=value):
                self.assert_refused(self.observe(environment=dict(self.environment, **{field: value})),
                                    'target/floor does not match')

    def test_exact_shim_reaches_same_precompiler_dispatch_guard_in_identity_metadata_and_cache_context(self):
        for mode in ('record', 'metadata', 'context'):
            with self.subTest(mode=mode):
                self.assert_refused(self.observe(mode), 'configured Rustup dispatch overrides')

    def test_explicit_zig_requires_authenticated_dispatch_for_record_and_cache(self):
        command = 'cargo zigbuild --target=' + TRIPLE + '.2.28'
        for mode in ('record', 'context'):
            with self.subTest(mode=mode):
                bare = emit(mode, command, receipt=self.receipt)
                self.assert_refused(self.observe(script=bare), 'requires the generated DSR Cargo shim')
                managed = emit(mode, command, self.shim_dir, self.receipt)
                self.assert_refused(self.observe(script=managed), 'configured Rustup dispatch overrides')
        # Metadata is ordinary Cargo metadata and never launches a Zig build.
        metadata = emit('metadata', command, receipt=self.receipt)
        self.assert_refused(self.observe(script=metadata), 'configured Rustup dispatch overrides')
        wrong = emit('record', 'cargo zigbuild --target=' + TRIPLE + '.2.17', self.shim_dir, self.receipt)
        self.assert_refused(self.observe(script=wrong), 'explicit Zig target/floor does not match')

    def transport_environment(self):
        """Capture launcher argv/environment only; never emulate a Rust build."""
        directory = self.project / 'delegated tools'
        directory.mkdir()
        cargo = directory / 'cargo'
        cargo.write_text('#!' + sys.executable + '\n' +
                         'import json, os, pathlib, sys\n' +
                         'pathlib.Path(os.environ["DSR_FIXTURE_CAPTURE"]).write_text(json.dumps({' +
                         '"argv":sys.argv[1:], "PATH":os.environ["PATH"], ' +
                         '"zig":{k:os.environ.get(k) for k in ' + repr(self.zig_selectors) + '}}))\n')
        # The plugin fixture exercises only the launcher's version gate. It is
        # never supplied to the identity observer as compiler/plugin evidence.
        plugin = directory / 'cargo-zigbuild'
        plugin.write_text('#!/bin/sh\nprintf probed > "$DSR_FIXTURE_PLUGIN_MARKER"\n'
                          'printf "cargo-zigbuild %s\\n" "$DSR_FIXTURE_PLUGIN_VERSION"\n')
        zig = directory / 'zig'
        zig.write_text('#!/bin/sh\nprintf executed > "$DSR_FIXTURE_ZIG_MARKER"\nexit 97\n')
        for path in (cargo, plugin, zig):
            path.chmod(0o755)
        return directory, dict(self.environment,
                               PATH=str(self.shim_dir) + ':' + str(directory) + ':' + os.environ['PATH'],
                               DSR_FIXTURE_PLUGIN_VERSION='0.24.0',
                               DSR_FIXTURE_PLUGIN_MARKER=str(self.work / 'plugin-probed'),
                               DSR_FIXTURE_ZIG_MARKER=str(self.work / 'zig-executed'))

    def test_generated_build_dispatch_pins_path_zig_and_preserves_target_arguments(self):
        directory, environment = self.transport_environment()
        sequence = 0
        for target in (TRIPLE, 'aarch64-unknown-linux-gnu'):
            for version in ('0.23.4', '0.24.0'):
                cases = ((['build', '--target', target, '--release'],
                          ['zigbuild', '--target', target + '.2.28', '--release']),
                         (['+fixture-selected', 'build', '--target=' + target, '--locked'],
                          ['+fixture-selected', 'zigbuild', '--target=' + target + '.2.28', '--locked']),
                         (['build', '--release'], ['zigbuild', '--target', target + '.2.28', '--release']),
                         (['+fixture-selected', '--quiet', '--color', 'never', 'build', '--offline'],
                          ['+fixture-selected', '--quiet', '--color', 'never', 'zigbuild',
                           '--target', target + '.2.28', '--offline']),
                         (['build', '--release', '--', '--target', 'application-argument'],
                          ['zigbuild', '--target', target + '.2.28', '--release', '--',
                           '--target', 'application-argument']),
                         (['--offline', 'zigbuild', '--target', target + '.2.28', '--release'],
                          ['--offline', 'zigbuild', '--target', target + '.2.28', '--release']),
                         (['+fixture-selected', '--color=never', 'zigbuild', '--target=' + target + '.2.28'],
                          ['+fixture-selected', '--color=never', 'zigbuild', '--target=' + target + '.2.28']))
                for argv, expected in cases:
                    sequence += 1
                    with self.subTest(target=target, version=version, argv=argv):
                        capture = self.work / ('dispatch-' + str(sequence) + '.json')
                        # Relative delegated entries and spaces must resolve to
                        # the same absolute Zig identity as the observer sees.
                        path = str(self.shim_dir) + ':' + directory.name + ':' + os.environ['PATH']
                        env = dict(environment, PATH=path, CARGO_BUILD_TARGET=target,
                                   DSR_RUST_TARGET=target, DSR_ZIG_TARGET=target + '.2.28',
                                   DSR_FIXTURE_PLUGIN_VERSION=version, DSR_FIXTURE_CAPTURE=str(capture))
                        result = subprocess.run([str(self.shim), *argv], cwd=self.project, env=env,
                                                text=True, capture_output=True, timeout=30)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        captured = json.loads(capture.read_text())
                        self.assertEqual(captured['argv'], expected)
                        self.assertEqual(captured['PATH'], directory.name + ':' + os.environ['PATH'])
                        self.assertEqual(captured['zig'], {
                            'CARGO_ZIGBUILD_ZIG_COMMAND': str(directory / 'zig'),
                            'CARGO_ZIGBUILD_ZIG_COMMAND_ARGS': None,
                            'CARGO_ZIGBUILD_PYTHON_PATH': '/dev/null',
                            'CARGO_ZIGBUILD_ZIG_PATH': str(directory / 'zig'),
                            'CARGO_ZIGBUILD_ZIG_VERSION': None})
                        self.assertFalse(Path(environment['DSR_FIXTURE_ZIG_MARKER']).exists())

    def test_generated_nonbuild_dispatch_preserves_cargo_arguments_without_zig_controls(self):
        directory, environment = self.transport_environment()
        for index, argv in enumerate((['metadata', '--no-deps'], ['--version'],
                                     ['+fixture-selected', 'metadata', '--format-version=1'])):
            with self.subTest(argv=argv):
                capture = self.work / ('passthrough-' + str(index) + '.json')
                result = subprocess.run([str(self.shim), *argv], cwd=self.project,
                                        env=dict(environment, DSR_FIXTURE_CAPTURE=str(capture)),
                                        text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                captured = json.loads(capture.read_text())
                self.assertEqual(captured['argv'], argv)
                self.assertEqual(captured['PATH'], str(directory) + ':' + os.environ['PATH'])
                self.assertEqual(captured['zig'], dict.fromkeys(self.zig_selectors))
                self.assertFalse(Path(environment['DSR_FIXTURE_PLUGIN_MARKER']).exists())
                self.assertFalse(Path(environment['DSR_FIXTURE_ZIG_MARKER']).exists())

    def test_external_zig_selectors_including_empty_values_refuse_before_plugin_or_cargo(self):
        _, environment = self.transport_environment()
        for index, name in enumerate(self.zig_selectors):
            for value_index, value in enumerate(('', '/untrusted/zig')):
                with self.subTest(name=name, value=value):
                    capture = self.work / ('refused-dispatch-' + str(index) + '-' + str(value_index) + '.json')
                    env = dict(environment, **{name: value}, DSR_FIXTURE_CAPTURE=str(capture))
                    result = subprocess.run([str(self.shim), 'build', '--target', TRIPLE],
                                            cwd=self.project, env=env, text=True,
                                            capture_output=True, timeout=30)
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertIn('Zig', result.stderr)
                    self.assertFalse(capture.exists())
                    self.assertFalse(Path(environment['DSR_FIXTURE_PLUGIN_MARKER']).exists())
                    self.assertFalse(Path(environment['DSR_FIXTURE_ZIG_MARKER']).exists())
                    for mode in ('record', 'metadata', 'context'):
                        self.assert_refused(self.observe(mode, dict(self.environment, **{name: value})), 'Zig')

    def test_command_scoped_zig_selectors_cannot_override_observed_dispatch(self):
        for name in self.zig_selectors:
            for value in ('', '/untrusted/zig'):
                with self.subTest(name=name, value=value):
                    script = emit('record', name + '=' + shlex.quote(value) + ' cargo build --target ' + TRIPLE,
                                  self.shim_dir, self.receipt)
                    self.assert_refused(self.observe(script=script), 'Zig')

    def test_new_zig_selector_policy_does_not_apply_without_the_generated_shim(self):
        target = 'aarch64-apple-darwin'
        script = emit('record', 'cargo build --target ' + target, receipt=self.receipt)
        for name in self.zig_selectors:
            with self.subTest(name=name):
                environment = dict(self.environment, PATH=os.environ['PATH'], CARGO_BUILD_TARGET=target,
                                   **{name: '/caller-owned/zig'})
                self.assert_refused(self.observe(environment=environment, script=script),
                                    'configured Rustup dispatch overrides')


class CargoCompatibilityTests(unittest.TestCase):
    def test_byte_exact_release_fixtures_and_full_target_matrix(self):
        configs = [('pi_agent_rust-v0.8.0.toml', 'dbd046e2b5abdf74d88e12c3deff5cdcea679092'),
                   ('franken_whisper-4261f62.toml', '4261f62b941756aa4a422ae83013c51cf2ec983a')]
        for name, expected_hash in configs:
            raw = (ROOT / 'tests/fixtures/cargo' / name).read_bytes()
            self.assertEqual(hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest(), expected_hash)
            config, receipts = read_config(raw.decode())
            environment = {}
            namespace['cargo_effective_environment'](config, receipts, environment)
            self.assertEqual(environment['RUST_MIN_STACK'], '16777216' if name.startswith('pi_') else '67108864')
            for arch in ('x86_64', 'aarch64'):
                for system in ('linux', 'macos', 'windows', 'freebsd'):
                    with self.subTest(name=name, arch=arch, system=system):
                        triple = 'x86_64-pc-windows-msvc' if (arch, system) == ('x86_64', 'windows') else 'fixture-target'
                        linker, row = namespace['cargo_target_settings'](config, triple, {}, facts(arch, system))
                        if name.startswith('pi_'):
                            expected = (['-L', '/usr/local/lib'] if system == 'freebsd' else [] if system == 'windows'
                                        else ['-Z', 'threads=4', '-Cllvm-args=-enable-machine-outliner=always'])
                            self.assertEqual(linker, 'rust-lld' if triple == 'x86_64-pc-windows-msvc' else '')
                        else:
                            expected = ['-Z', 'threads=4'] + (['-C', 'target-cpu=x86-64-v3'] if arch == 'x86_64' else [])
                        self.assertEqual(row['rustflags'], expected)

    def test_numeric_tables_force_and_effective_receipts(self):
        for name in ('RUST_MIN_STACK', 'RUST_TEST_THREADS'):
            for force in (False, True):
                for ambient in (None, '33554432'):
                    config, receipts = read_config('[env]\n' + name + '={value="16777216",force=' + str(force).lower() + ',relative=false}\n')
                    env = {} if ambient is None else {name: ambient}
                    namespace['cargo_effective_environment'](config, receipts, env)
                    row = receipts[0]['env_exemptions'][0]
                    self.assertEqual(row['value'], '16777216')
                    self.assertEqual(row['force'], force)
                    self.assertEqual(row['effective_value'], ambient if ambient and not force else '16777216')
                    self.assertEqual(row['effective_source'], 'environment' if ambient and not force else 'configuration')

    def test_invalid_env_attributes_and_compiler_manipulation(self):
        for name in ('RUST_MIN_STACK', 'RUST_TEST_THREADS'):
            for entry in ('{value="0"}', '{value=1}', '{value="-1"}', '{value="1",force=0}',
                          '{value="1",force="false"}', '{value="1",relative=true}',
                          '{value="1",relative=0}', '{value="1",extra=false}'):
                with self.subTest(name=name, entry=entry), self.assertRaises(Refused):
                    read_config('[env]\n' + name + '=' + entry)
        for name in ('RUSTC', 'RUSTFLAGS', 'RUSTC_WRAPPER', 'CARGO_ENCODED_RUSTFLAGS',
                     'RUSTUP_TOOLCHAIN', 'PATH', 'CC', 'RUST_MIN_STACK_X', 'RUST_TEST_THREADS_X'):
            with self.subTest(name=name), self.assertRaises(Refused):
                read_config('[env]\nRUST_MIN_STACK={value="1"}\n' + name + '={value="1",force=false}\n')

    def test_cfg_grammar_fail_closed_in_inactive_branches(self):
        for text in ('cfg(not(unix,))', 'cfg(all(windows, feature="x"))',
                     'cfg(any(unix, evil()))', 'cfg(target_feature="avx2")', 'cfg(debug_assertions)',
                     'cfg(target_os="linux") trailing', 'cfg(\tunix)', 'cfg(not())'):
            with self.subTest(text=text), self.assertRaises(Refused):
                namespace['cargo_parse_cfg'](text)
        for text in ('cfg(all(unix,not(windows)))', 'cfg(any(windows,unix,))', 'cfg(all())'):
            self.assertTrue(namespace['cargo_match_cfg'](namespace['cargo_parse_cfg'](text), facts()))

    def test_final_merged_flags_cannot_hide_compiler_selectors(self):
        for prefix, suffix in (('-C', 'linker=evil'), ('-Z', 'codegen-backend=evil'),
                               ('-Z', 'codegen_backend=evil'), ('--codegen', 'linker=evil')):
            config = {'build': {}, 'target': {TRIPLE: {'rustflags': [prefix]},
                       'cfg(unix)': {'rustflags': [suffix]}}}
            with self.subTest(prefix=prefix, suffix=suffix), self.assertRaises(Refused):
                namespace['cargo_target_settings'](config, TRIPLE, {}, facts())
        config = {'build': {}, 'target': {'cfg(windows)': {'rustflags': ['@hidden.args']}}}
        with self.assertRaises(Refused):
            namespace['cargo_observe_target'](config, TRIPLE, {}, {})

    def test_cfg_linker_ambiguity_and_authoritative_override(self):
        config = {'build': {}, 'target': {'cfg(unix)': {'linker': 'one'},
                                         'cfg(target_os="linux")': {'linker': 'two'}}}
        with self.assertRaises(Refused):
            namespace['cargo_target_settings'](config, TRIPLE, {}, facts())
        config['target'][TRIPLE] = {'linker': 'exact'}
        self.assertEqual(namespace['cargo_target_settings'](config, TRIPLE, {}, facts())[0], 'exact')
        env = {'CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER': 'environment'}
        self.assertEqual(namespace['cargo_target_settings'](config, TRIPLE, env, facts())[0], 'environment')

    def test_encoded_empty_argument_positions_remain_distinct(self):
        config = {'build': {}, 'target': {}}
        _, row = namespace['cargo_target_settings'](config, TRIPLE, {'CARGO_ENCODED_RUSTFLAGS': '-C\x1f\x1flinker=evil'}, facts())
        self.assertEqual(row['rustflags'], ['-C', '', 'linker=evil'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
