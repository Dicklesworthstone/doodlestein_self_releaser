#!/usr/bin/env python3
"""Cargo config unit tests; --integration also builds with a real nightly toolchain.

Fixtures are byte-exact upstream .cargo/config.toml files, pinned by Git blob:
pi_agent_rust v0.8.0: dbd046e2b5abdf74d88e12c3deff5cdcea679092
franken_whisper (issue #41 config): 4261f62b941756aa4a422ae83013c51cf2ec983a
The latter blob is pinned rather than claiming an unavailable v0.11.0 tag.
No test downloads source, changes an installed toolchain, or deletes fixtures.
"""
import ast
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
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
MODULE = Path(os.environ.get('DSR_TEST_ACT_RUNNER', str(ROOT / 'src/act_runner.sh')))
INTEGRATION = '--integration' in sys.argv
if INTEGRATION:
    sys.argv.remove('--integration')


class Refused(Exception):
    pass


def refuse(message):
    raise Refused(message)


# Load only production definitions, never its side-effecting top-level probe.
# Integration below executes the complete shell-generated observer unchanged.
source = MODULE.read_text()
start = source.index('def cargo_env_exemption(')
end = source.index('\ncargo_config, cargo_config_receipts', start)
namespace = dict(re=re, os=os, pathlib=__import__('pathlib'), hashlib=hashlib,
                 subprocess=subprocess, fail=refuse)
exec(compile(source[start:end], str(MODULE), 'exec'), namespace)
for name in ('cargo_env_exemption', 'cargo_effective_environment', 'cargo_parse_cfg',
             'cargo_match_cfg', 'cargo_parse_target_cfg', 'cargo_target_settings',
             'cargo_merge_flags', 'cargo_validate_flags', 'cargo_observe_target'):
    globals()[name] = namespace[name]
# influences() is outside the extracted block; read its actual definition too.
influence_start = source.index('def influences(name):')
influence_end = source.index('\n\n', influence_start)
exec(compile(source[influence_start:influence_end], str(MODULE), 'exec'), namespace)

FIXTURES = [('pi_agent_rust-v0.8.0.toml', 'dbd046e2b5abdf74d88e12c3deff5cdcea679092'),
            ('franken_whisper-4261f62.toml', '4261f62b941756aa4a422ae83013c51cf2ec983a')]


def fixture(name):
    return (ROOT / 'tests/fixtures/cargo' / name).read_bytes()


def config_read(text):
    directory = Path(tempfile.mkdtemp(prefix='dsr-cargo-config-unit-')).resolve()
    (directory / '.cargo').mkdir()
    (directory / '.cargo/config.toml').write_text(text)
    previous = Path.cwd()
    try:
        os.chdir(directory)
        with patch.dict(os.environ, {'CARGO_HOME': str(directory / 'private-home')}):
            return namespace['cargo_configuration']()
    finally:
        os.chdir(previous)


def facts(arch='x86_64', system='linux'):
    # Synthetic facts are parser/selection unit evidence, not compiler evidence.
    family = 'windows' if system == 'windows' else 'unix'
    return {(family, None), ('target_arch', arch), ('target_os', system),
            ('target_env', 'gnu'), ('target_vendor', 'unknown'), ('target_family', family),
            ('target_endian', 'little'), ('target_pointer_width', '64')}


class ConfigurationTests(unittest.TestCase):
    def test_byte_exact_upstream_fixtures(self):
        for name, expected in FIXTURES:
            raw = fixture(name)
            self.assertEqual(hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest(), expected)

    def test_numeric_forms(self):
        for name in ('RUST_MIN_STACK', 'RUST_TEST_THREADS'):
            for entry, force in [('16777216', False), ({'value': '16777216'}, False),
                                 ({'value': '16777216', 'force': False}, False),
                                 ({'value': '16777216', 'force': True, 'relative': False}, True)]:
                with self.subTest(name=name, entry=entry):
                    self.assertEqual(cargo_env_exemption(name, entry),
                                     {'name': name, 'value': '16777216', 'force': force})

    def test_invalid_numeric_forms(self):
        invalid = ['', '0', '-1', '+1', '01', ' 1', '1\n', 'auto', 1, True, [], {},
                   {'value': 1}, {'value': '0'}, {'value': 'x'}, {'value': '1', 'force': 0},
                   {'value': '1', 'force': 'false'}, {'value': '1', 'relative': 0},
                   {'value': '1', 'relative': True}, {'value': '1', 'extra': False}]
        for name in ('RUST_MIN_STACK', 'RUST_TEST_THREADS'):
            for entry in invalid:
                with self.subTest(name=name, entry=entry), self.assertRaises(Refused):
                    cargo_env_exemption(name, entry)

    def test_force_and_effective_receipts(self):
        for force in (False, True):
            for ambient in (None, '33554432'):
                text = '[env]\nRUST_MIN_STACK={value="16777216", force=' + str(force).lower() + '}\n'
                config, receipts = config_read(text)
                env = {} if ambient is None else {'RUST_MIN_STACK': ambient}
                cargo_effective_environment(config, receipts, env)
                expected = '16777216' if force or ambient is None else ambient
                row = receipts[0]['env_exemptions'][0]
                self.assertEqual(env['RUST_MIN_STACK'], expected)
                self.assertEqual(row['effective_value'], expected)
                self.assertEqual(row['force'], force)
                self.assertEqual(row['effective_source'], 'environment' if ambient and not force else 'configuration')
        config, receipts = config_read('[env]\nRUST_MIN_STACK="1"\n')
        with self.assertRaises(Refused):
            cargo_effective_environment(config, receipts, {'RUST_MIN_STACK': 'invalid'})

    def test_compiler_environment_still_refused(self):
        names = ('RUSTC', 'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'RUSTC_WRAPPER',
                 'RUSTUP_TOOLCHAIN', 'CARGO_BUILD_RUSTC', 'PATH', 'CC', 'RUST_MIN_STACK_X',
                 'RUST_TEST_THREADS_X', 'CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER')
        for name in names:
            for value in ('"1"', '{value="1", force=false}'):
                with self.subTest(name=name, value=value), self.assertRaises(Refused):
                    config_read('[env]\nRUST_MIN_STACK="1"\n' + name + '=' + value + '\n')

    def test_cfg_grammar_and_boolean_semantics(self):
        for text, expected in [('cfg(unix)', True), ('cfg(windows)', False),
                               ('cfg(all())', True), ('cfg(any())', False),
                               ('cfg(not(windows))', True),
                               ('cfg(all(unix, any(windows, target_arch = "x86_64"),))', True),
                               ('cfg(not(target_os="linux"))', False)]:
            self.assertEqual(cargo_match_cfg(cargo_parse_cfg(text), facts()), expected)

    def test_cfg_refuses_unsupported_and_malformed_branches(self):
        invalid = ['cfg()', 'cfg(not())', 'cfg(not(unix,windows))', 'cfg(unix) trailing',
                   'cfg(all(unix, evil()))', 'cfg(any(unix, feature="x"))', 'cfg(test)',
                   'cfg(debug_assertions)', 'cfg(target_feature="avx2")', 'cfg(panic="abort")',
                   'cfg(target_os=linux)', 'cfg(target_os="lin\\ux")', 'cfg(unix || windows)',
                   'cfg(all(unix,,))', 'cfg(target_arch)', 'cfg (unix)',
                   'cfg(' + 'not(' * 40 + 'unix' + ')' * 40 + ')',
                   'cfg(all(' + 'unix,' * 600 + '))']
        for text in invalid:
            with self.subTest(text=text[:100]), self.assertRaises(Refused):
                cargo_parse_cfg(text)

    def test_real_config_target_matrix(self):
        pi, _ = config_read(fixture(FIXTURES[0][0]).decode())
        whisper, _ = config_read(fixture(FIXTURES[1][0]).decode())
        for arch, system, expected in [('x86_64', 'linux', 1), ('aarch64', 'macos', 1),
                                       ('x86_64', 'freebsd', 1), ('x86_64', 'windows', 0)]:
            _, row = cargo_target_settings(pi, 'fixture-target', {}, facts(arch, system))
            self.assertEqual(len(row['matched_cfg']), expected)
            if system == 'freebsd':
                self.assertEqual(row['rustflags'], ['-L', '/usr/local/lib'])
            _, row = cargo_target_settings(whisper, 'fixture-target', {}, facts(arch, system))
            self.assertEqual(len(row['matched_cfg']), int(arch == 'x86_64'))
            self.assertEqual('target-cpu=x86-64-v3' in row['rustflags'], arch == 'x86_64')

    def test_linker_ambiguity_and_exact_precedence(self):
        config = {'build': {}, 'target': {'cfg(unix)': {'linker': 'one'},
                                         'cfg(target_os="linux")': {'linker': 'two'}}}
        with self.assertRaises(Refused):
            cargo_target_settings(config, 'x86_64-unknown-linux-gnu', {}, facts())
        config['target']['x86_64-unknown-linux-gnu'] = {'linker': 'exact'}
        linker, _ = cargo_target_settings(config, 'x86_64-unknown-linux-gnu', {}, facts())
        self.assertEqual(linker, 'exact')
        linker, _ = cargo_target_settings(config, 'x86_64-unknown-linux-gnu',
                    {'CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER': 'environment'}, facts())
        self.assertEqual(linker, 'environment')

    def test_flags_precedence_and_array_merge(self):
        self.assertEqual(cargo_merge_flags(['-A', 'warnings'], ['-Cdebuginfo=0']), ['-A', 'warnings', '-Cdebuginfo=0'])
        self.assertEqual(cargo_merge_flags('-A warnings', '-Cdebuginfo=0'), '-Cdebuginfo=0')
        with self.assertRaises(Refused):
            cargo_merge_flags([], '-A warnings')
        config = {'build': {'rustflags': ['build']}, 'target': {
            'cfg(unix)': {'rustflags': ['cfg']}, 'fixture-target': {'rustflags': ['exact']}}}
        _, row = cargo_target_settings(config, 'fixture-target', {}, facts())
        self.assertEqual(row['rustflags'], ['exact', 'cfg'])
        for env, expected in [({'RUSTFLAGS': ''}, []), ({'RUSTFLAGS': 'env'}, ['env']),
                              ({'RUSTFLAGS': 'env', 'CARGO_ENCODED_RUSTFLAGS': 'encoded\x1fflags'}, ['encoded', 'flags'])]:
            _, row = cargo_target_settings(config, 'fixture-target', env, facts())
            self.assertEqual(row['rustflags'], expected)

    def test_hidden_compiler_selectors(self):
        for words in [['-Clinker=evil'], ['-C', 'linker=evil'], ['--codegen=linker=evil'],
                      ['--codegen', 'linker=evil'], ['-C=linker=evil'], ['@hidden.args'],
                      ['-Zcodegen-backend=evil'], ['-Z', 'codegen-backend=evil'],
                      ['--cfg', 'target_os="windows"'], ['--cfg=unix'],
                      ['--target=other'], ['--target', 'other']]:
            with self.subTest(words=words), self.assertRaises(Refused):
                cargo_validate_flags(words, True)
        cargo_validate_flags(['-Z', 'threads=4', '-C', 'target-cpu=x86-64-v3'], True)

    def test_unstable_and_wrapped_cfg_fail_closed(self):
        for text, env in [('[unstable]\nhost-config=true\n', {}),
                           ('', {'CARGO_UNSTABLE_HOST_CONFIG': 'true'}),
                           ('[build]\nrustc-wrapper="wrapper"\n', {}),
                           ('', {'RUSTC_WRAPPER': 'wrapper'})]:
            config, _ = config_read(text + '[target.\'cfg(unix)\']\nrustflags=[]\n')
            with self.assertRaises(Refused):
                cargo_observe_target(config, 'x86_64-unknown-linux-gnu', env, {})

    def test_target_probe_output_validation(self):
        valid = '\n'.join(name if value is None else name + '="' + value + '"'
                          for name, value in sorted(facts())) + '\n'
        self.assertEqual(cargo_parse_target_cfg(valid), facts())
        for text in ['', valid + 'not a cfg\n', valid + 'target_os="linux"\n',
                     valid + 'target_os="windows"\n', valid.replace('target_arch="x86_64"\n', '')]:
            with self.assertRaises(Refused):
                cargo_parse_target_cfg(text)


@unittest.skipUnless(INTEGRATION, 'use --integration with real nightly Cargo/rustc')
class CompilerIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for tool in ('cargo', 'rustc', 'rustup', 'bash', 'jq', 'cc'):
            if not shutil.which(tool):
                raise RuntimeError('Missing integration dependency: ' + tool)
        cls.work = Path(tempfile.mkdtemp(prefix='dsr-cargo-config-live-')).resolve()
        print('Retained live fixtures:', cls.work, flush=True)
        cls.env = {key: value for key, value in os.environ.items()
                   if not key.startswith(('RUST', 'CARGO_', 'RCH_'))}
        real_sysroot = cls.run_command(['rustc', '--print', 'sysroot']).stdout.strip()
        cls.env.update(CARGO_HOME=str(cls.work / 'cargo'), RUSTUP_HOME=str(cls.work / 'rustup'),
                       RUSTUP_AUTO_INSTALL='0', RCH_DISABLED='1', RCH_CARGO_WRAPPER_BYPASS='1')
        cls.run_command(['rustup', 'toolchain', 'link', 'dsr-config-fixture', real_sysroot], env=cls.env)
        cls.env['RUSTUP_TOOLCHAIN'] = 'dsr-config-fixture'
        version = cls.run_command(['rustc', '-vV'], env=cls.env).stdout
        if 'nightly' not in version:
            raise RuntimeError('Real release configuration integration requires nightly rustc (-Z threads)')
        cls.host = next(line.split(': ', 1)[1] for line in version.splitlines() if line.startswith('host: '))
        cls.env['CARGO_BUILD_TARGET'] = cls.host
        cls.count = 0

    @staticmethod
    def run_command(argv, **kwargs):
        result = subprocess.run(list(map(str, argv)), capture_output=True, text=True, timeout=120, **kwargs)
        if result.returncode:
            raise AssertionError(str(argv) + '\n' + result.stdout + '\n' + result.stderr)
        return result

    def project(self, contents):
        type(self).count += 1
        directory = self.work / str(self.count)
        (directory / 'src').mkdir(parents=True)
        (directory / '.cargo').mkdir()
        (directory / '.cargo/config.toml').write_bytes(contents.encode() if isinstance(contents, str) else contents)
        (directory / 'Cargo.toml').write_text('[package]\nname="config-probe"\nversion="0.1.0"\nedition="2021"\n')
        (directory / 'src/main.rs').write_text('fn main() { print!("{}", include_str!(concat!(env!("OUT_DIR"), "/observed.txt"))); }\n')
        (directory / 'build.rs').write_text(r'''fn main() {
    let flags = std::env::var("CARGO_ENCODED_RUSTFLAGS").unwrap_or_default().replace('\u{1f}', "\t");
    let stack = std::env::var("RUST_MIN_STACK").unwrap_or_default();
    let threads = std::env::var("RUST_TEST_THREADS").unwrap_or_default();
    std::fs::write(std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("observed.txt"),
                   format!("{}\n{}\n{}\n", flags, stack, threads)).unwrap();
}''')
        return directory

    def probe(self, directory, env=None, command='cargo build --offline', mode='record', pin=None, receipt=None):
        environment = self.env if env is None else env
        receipt = directory / 'identity.json' if receipt is None else receipt
        script = 'source "$1" || exit $?; _act_toolchain_identity_script "$2" "$3" "$4" "" "$5" "$6" | bash'
        result = subprocess.run(['bash', '-o', 'pipefail', '-c', script, '_', str(MODULE), mode,
                                 str(receipt), command, json.dumps(pin or {}), str(directory)],
                                cwd=directory, env=environment, capture_output=True, text=True, timeout=120)
        return result, (json.loads(result.stdout) if result.returncode == 0 and result.stdout else {})

    def build_and_compare(self, directory, env=None, command='cargo build --offline'):
        environment = self.env if env is None else env
        result, recorded = self.probe(directory, environment, command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.run_command(['bash', '-c', command], cwd=directory, env=environment)
        observed = self.run_command([directory / 'target' / self.host / 'debug/config-probe']).stdout.splitlines()
        self.assertEqual(observed[0].split('\t') if observed[0] else [],
                         recorded['identity']['selection']['cargo_target']['rustflags'])
        rows = recorded['identity']['selection']['cargo_config'][0].get('env_exemptions', [])
        for row in rows:
            self.assertEqual(observed[1 if row['name'] == 'RUST_MIN_STACK' else 2], row['effective_value'])
        verified, _ = self.probe(directory, environment, command, mode='verify', pin=recorded['pin'])
        self.assertEqual(verified.returncode, 0, verified.stderr)
        return recorded

    def test_actual_releases_build_and_verify(self):
        for name, _ in FIXTURES:
            with self.subTest(name=name):
                directory = self.project(fixture(name))
                recorded = self.build_and_compare(directory)
                target = recorded['identity']['selection']['cargo_target']
                rustc = recorded['identity']['tools']['rustc']
                self.assertEqual(target['cfg_probe']['compiler_sha256'], rustc.get('resolved_sha256', rustc['selected_sha256']))
                self.assertEqual(target['cfg_probe']['target_triple'], self.host)
                with (directory / '.cargo/config.toml').open('a') as stream:
                    stream.write('\n# receipt drift\n')
                refused, _ = self.probe(directory, mode='verify', pin=recorded['pin'])
                self.assertNotEqual(refused.returncode, 0)

    def test_force_false_true_and_inline_environment(self):
        for force in ('false', 'true'):
            directory = self.project('[env]\nRUST_MIN_STACK={value="16777216", force=' + force + '}\nRUST_TEST_THREADS={value="2"}\n')
            self.build_and_compare(directory, command='RUST_MIN_STACK=33554432 cargo build --offline')

    def test_actual_flag_precedence(self):
        for env_flags in ({}, {'CARGO_TARGET_' + self.host.replace('-', '_').upper() + '_RUSTFLAGS': '-Copt-level=1'},
                          {'RUSTFLAGS': ''}, {'RUSTFLAGS': '-Copt-level=1'},
                          {'CARGO_ENCODED_RUSTFLAGS': '-C\x1fopt-level=1'}):
            text = '[build]\nrustflags=["-Copt-level=0"]\n[target.\'' + self.host + '\']\nrustflags=["-Cdebuginfo=1"]\n[target.\'cfg(unix)\']\nrustflags=["-Cdebug-assertions=yes"]\n'
            directory = self.project(text)
            self.build_and_compare(directory, dict(self.env, **env_flags))

    def test_cfg_linker_is_the_linker_actually_invoked(self):
        directory = self.project('[target.\'cfg(unix)\']\nlinker="./observed-linker"\n')
        linker = directory / 'observed-linker'
        log = directory / 'linker.log'
        linker.write_text('#!/bin/sh\nif [ "$1" != "--version" ]; then printf "%s\\n" "$*" >> ' +
                          shlex.quote(str(log)) + '; fi\nexec ' + shlex.quote(shutil.which('cc')) + ' "$@"\n')
        linker.chmod(0o755)
        recorded = self.build_and_compare(directory)
        self.assertIn('-o ', log.read_text())
        self.assertEqual(recorded['identity']['tools']['linker']['selected_path'], str(linker))
        linker.write_text(linker.read_text() + '# drift\n')
        refused, _ = self.probe(directory, mode='verify', pin=recorded['pin'])
        self.assertNotEqual(refused.returncode, 0)

    def test_real_cross_target_cfg_queries(self):
        for name, _ in FIXTURES:
            for triple, arch, system in [('x86_64-unknown-linux-gnu', 'x86_64', 'linux'),
                                         ('aarch64-unknown-linux-gnu', 'aarch64', 'linux'),
                                         ('x86_64-apple-darwin', 'x86_64', 'macos'),
                                         ('aarch64-apple-darwin', 'aarch64', 'macos'),
                                         ('x86_64-unknown-freebsd', 'x86_64', 'freebsd')]:
                with self.subTest(name=name, target=triple):
                    directory = self.project(fixture(name))
                    result, record = self.probe(directory, command='cargo build --offline --target ' + triple)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    target = record['identity']['selection']['cargo_target']
                    self.assertIn('target_arch="' + arch + '"', target['cfg_probe']['values'])
                    self.assertIn('target_os="' + system + '"', target['cfg_probe']['values'])
                    self.assertEqual(record['identity']['target_triple'], triple)
                    if name.startswith('franken'):
                        self.assertEqual('target-cpu=x86-64-v3' in target['rustflags'], arch == 'x86_64')

    def test_security_refusals_create_no_receipt(self):
        invalid = ['[env]\nRUST_MIN_STACK={value="1", relative=true}\n',
                   '[env]\nRUSTC={value="/bin/true", force=true}\n',
                   '[env]\nRUST_MIN_STACK={value="1"}\nRUSTFLAGS="-Copt-level=1"\n',
                   '[target.\'cfg(any(unix, feature="hidden"))\']\nrustflags=[]\n',
                   '[target.\'cfg(unix)\']\nlinker="cc"\n[target.\'cfg(all(unix))\']\nlinker="cc"\n',
                   '[target.\'cfg(windows)\']\nrustflags=["--codegen", "linker=/bin/true"]\n',
                   '[target.\'cfg(unix)\']\nrustflags=["@hidden.args"]\n']
        for text in invalid:
            directory = self.project(text)
            result, _ = self.probe(directory)
            self.assertNotEqual(result.returncode, 0, text)
            self.assertFalse((directory / 'identity.json').exists())
        directory = self.project('[target.\'cfg(unix)\']\nrustflags=[]\n')
        result, _ = self.probe(directory, command='cargo build --target definitely-not-a-target')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((directory / 'identity.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
