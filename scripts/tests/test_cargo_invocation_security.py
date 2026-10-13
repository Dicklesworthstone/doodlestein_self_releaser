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
EMIT = 'source "$1" || exit $?; _act_toolchain_identity_script "$2" "$3" "$4" "" "" ""'


def emit(mode, command):
    return subprocess.run(['bash', '-o', 'pipefail', '-c', EMIT, '_', str(MODULE),
                           mode, '/tmp/dsr-unused-receipt.json', command],
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


def invoke(command, cfg=True, mode='record'):
    namespace.update(command=command, mode=mode,
                     cargo_config={'build': {}, 'alias': {}, 'target':
                                   {'cfg(unix)': {'rustflags': []}} if cfg else {}})
    with patch.dict(os.environ, {'CARGO_BUILD_TARGET': TRIPLE}, clear=True):
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
