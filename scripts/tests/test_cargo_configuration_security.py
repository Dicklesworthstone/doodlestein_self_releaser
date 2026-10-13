#!/usr/bin/env python3
"""Adversarial tests of the production Cargo attestation definitions.

No mocked compiler result is release-build evidence. These definition-level
checks complement test_cargo_configuration.py --integration, which uses real
Cargo/rustc and byte-pinned upstream configuration fixtures.
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE = Path(os.environ.get('DSR_TEST_ACT_RUNNER', str(ROOT / 'src/act_runner.sh')))


class Refused(Exception):
    pass


def refuse(message):
    raise Refused(message)


source = MODULE.read_text()
start = source.index('def cargo_env_exemption(')
end = source.find('\ndef cargo_configuration(', start)
namespace = dict(re=re, os=os, pathlib=__import__('pathlib'), hashlib=hashlib,
                 subprocess=subprocess, fail=refuse)
exec(compile(source[start:end if end >= 0 else None], str(MODULE), 'exec'), namespace)

TRIPLE = 'x86_64-unknown-linux-gnu'
FACTS = {('unix', None), ('target_arch', 'x86_64'), ('target_os', 'linux'),
         ('target_env', 'gnu'), ('target_vendor', 'unknown'), ('target_family', 'unix'),
         ('target_endian', 'little'), ('target_pointer_width', '64')}
SELECTORS = [('-C', 'linker=unattested'), ('--codegen', 'linker=unattested'),
             ('-Z', 'codegen-backend=unattested'), ('-Z', 'codegen_backend=unattested')]


def selected(config, environment=None):
    return namespace['cargo_target_settings'](config, TRIPLE, environment or {}, FACTS)[1]


class CargoConfigurationSecurityTests(unittest.TestCase):
    def test_not_and_outer_delimiters_match_cargo_grammar(self):
        for text in ('cfg(not(unix,))', 'cfg(not(windows,))', 'cfg(unix) ',
                     'cfg(unix)\n', 'cfg(all(not(windows,), unix))'):
            with self.subTest(text=text), self.assertRaises(Refused):
                namespace['cargo_parse_cfg'](text)
        for text in ('cfg(not(windows))', 'cfg(all(unix,))', 'cfg(any(windows, unix,))'):
            self.assertTrue(namespace['cargo_match_cfg'](namespace['cargo_parse_cfg'](text), FACTS))

    def test_only_cargo_supported_inter_token_whitespace(self):
        for separator in ('\t', '\n', '\r', '\v', '\f', '\u00a0'):
            for text in ('cfg(' + separator + 'unix)',
                         'cfg(target_os' + separator + '= "linux")',
                         'cfg(all(unix,' + separator + 'windows))'):
                with self.subTest(text=text), self.assertRaises(Refused):
                    namespace['cargo_parse_cfg'](text)
        self.assertTrue(namespace['cargo_match_cfg'](
            namespace['cargo_parse_cfg']('cfg( all( unix , not(windows) ) )'), FACTS))

    def test_selectors_cannot_straddle_exact_and_cfg_arrays(self):
        for prefix, argument in SELECTORS:
            config = {'build': {}, 'target': {
                TRIPLE: {'rustflags': [prefix]}, 'cfg(unix)': {'rustflags': [argument]}}}
            with self.subTest(prefix=prefix, argument=argument), self.assertRaises(Refused):
                selected(config)

    def test_selectors_cannot_straddle_two_matching_cfg_arrays(self):
        for prefix, argument in SELECTORS:
            config = {'build': {}, 'target': {
                'cfg(all(unix))': {'rustflags': [prefix]},
                'cfg(unix)': {'rustflags': [argument]}}}
            with self.subTest(prefix=prefix, argument=argument), self.assertRaises(Refused):
                selected(config)

    def test_selectors_cannot_straddle_target_environment_and_cfg(self):
        for prefix, argument in SELECTORS:
            config = {'build': {}, 'target': {'cfg(unix)': {'rustflags': [argument]}}}
            with self.subTest(prefix=prefix, argument=argument), self.assertRaises(Refused):
                selected(config, {'CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS': prefix})

    def test_underscore_backend_and_clustered_selectors_are_refused(self):
        for words in (['-Zcodegen_backend=unattested'], ['-Z', 'codegen_backend=unattested'],
                      ['--unstable-options=codegen_backend=unattested'],
                      ['-vClinker=unattested'], ['-gC', 'linker=unattested'],
                      ['-OZcodegen-backend=unattested']):
            with self.subTest(words=words), self.assertRaises(Refused):
                namespace['cargo_validate_flags'](words, True)

    def test_final_argument_boundaries_are_not_retokenized(self):
        config = {'build': {}, 'target': {}}
        for raw, expected in (('-C\topt-level=1', ['-C\topt-level=1']),
                              ('  -C\nopt-level=1  ', ['-C\nopt-level=1']),
                              (' -C opt-level=1 ', ['-C', 'opt-level=1']),
                              ('', [])):
            with self.subTest(raw=raw):
                self.assertEqual(selected(config, {'RUSTFLAGS': raw})['rustflags'], expected)
        for control in ('\x1c', '\x1d', '\x1e', '\x1f'):
            with self.subTest(control=control), self.assertRaises(Refused):
                selected(config, {'RUSTFLAGS': '-C' + control + 'opt-level=1'})

    def test_encoded_flags_preserve_empty_argument_positions(self):
        config = {'build': {}, 'target': {}}
        for raw, expected in (('', []), ('\x1f', ['', '']), ('-C\x1f\x1fopt-level=1', ['-C', '', 'opt-level=1']),
                              ('-C\x1fopt-level=1\x1f', ['-C', 'opt-level=1', ''])):
            with self.subTest(raw=raw):
                row = selected(config, {'CARGO_ENCODED_RUSTFLAGS': raw, 'RUSTFLAGS': '-Clinker=unattested'})
                self.assertEqual(row['rustflags'], expected)
                self.assertEqual(row['rustflags_source'], 'CARGO_ENCODED_RUSTFLAGS')

    def test_response_files_are_refused_even_in_false_cfg_branch(self):
        for words in (['@hidden.args'], ['-Zshell-argfiles', '@shell:hidden.args'],
                      ['-Z', 'codegen_backend=unattested'], ['-vClinker=unattested']):
            config = {'build': {}, 'target': {'cfg(windows)': {'rustflags': words}}}
            with self.subTest(words=words), self.assertRaises(Refused):
                namespace['cargo_observe_target'](config, TRIPLE, {}, {})

    def test_supported_release_flags_survive_ordered_composition(self):
        pi_flags = ['-Z', 'threads=4', '-Cllvm-args=-enable-machine-outliner=always']
        whisper_flags = ['-Z', 'threads=4', '-C', 'target-cpu=x86-64-v3']
        for flags in (pi_flags, whisper_flags, ['-L', '/usr/local/lib']):
            config = {'build': {}, 'target': {'cfg(unix)': {'rustflags': flags}}}
            self.assertEqual(selected(config)['rustflags'], flags)
            namespace['cargo_validate_flags'](flags, True)

    def test_numeric_table_receipt_retains_configured_and_effective_values(self):
        for name in ('RUST_MIN_STACK', 'RUST_TEST_THREADS'):
            for force in (False, True):
                entry = {'value': '16777216', 'force': force, 'relative': False}
                row = namespace['cargo_env_exemption'](name, entry)
                receipts = [{'env_exemptions': [row]}]
                environment = {name: '33554432'}
                namespace['cargo_effective_environment']({'env': {name: entry}}, receipts, environment)
                self.assertEqual(row['value'], '16777216')
                self.assertEqual(row['effective_value'], '16777216' if force else '33554432')
                self.assertEqual(row['effective_force'], force)
                self.assertEqual(row['effective_source'], 'configuration' if force else 'environment')
                self.assertEqual(environment[name], row['effective_value'])

    def test_unsupported_branch_is_validated_without_boolean_short_circuit(self):
        for expression in ('cfg(any(unix, feature="hidden"))',
                           'cfg(all(windows, target_feature="avx2"))',
                           'cfg(any(unix, not(windows,)))'):
            with self.subTest(expression=expression), self.assertRaises(Refused):
                namespace['cargo_parse_cfg'](expression)


if __name__ == '__main__':
    unittest.main(verbosity=2)
