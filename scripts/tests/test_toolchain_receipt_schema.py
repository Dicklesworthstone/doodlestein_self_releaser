#!/usr/bin/env python3
"""Contract tests for production Cargo observations crossing manifest validation.

The Cargo selection/environment rows come from the checked-out observer's actual
Python definitions. Executable and cfg-probe envelopes are explicitly synthetic
schema fixtures, not evidence of compiler execution or release qualification.
Run with Python 3.11+ and jsonschema; no Cargo installation is required.
"""
import ast
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import pathlib
import re
import unittest

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = json.loads(Path(os.environ.get(
    'DSR_TEST_MANIFEST_SCHEMA', str(ROOT / 'schemas/manifest.json'))).read_text())
Draft202012Validator.check_schema(SCHEMA)
VALIDATOR = Draft202012Validator(SCHEMA)
TRIPLE = 'x86_64-unknown-linux-gnu'
DIGEST = 'a' * 64
FACTS = {('unix', None), ('target_arch', 'x86_64'), ('target_os', 'linux'),
         ('target_env', 'gnu'), ('target_vendor', 'unknown'), ('target_family', 'unix'),
         ('target_endian', 'little'), ('target_pointer_width', '64')}


def load_observer_definitions():
    path = ROOT / 'src/act_runner.sh'
    source = path.read_text()
    start = source.index('_act_toolchain_identity_script() {')
    start = source.index("    cat <<'PY'\n", start) + len("    cat <<'PY'\n")
    end = source.index('\nPY\n', start)
    module = ast.parse(source[start:end], filename=str(path))
    definitions = ast.Module(body=[node for node in module.body
                                  if isinstance(node, ast.FunctionDef)], type_ignores=[])
    namespace = dict(re=re, os=os, pathlib=pathlib, hashlib=hashlib, json=json)
    exec(compile(definitions, str(path), 'exec'), namespace)

    def refuse(message):
        raise ValueError(message)

    namespace['fail'] = refuse
    return namespace


OBSERVER = load_observer_definitions()


def executable(program, root='/opt/tools'):
    return {'program': program, 'selected_path': root + '/' + program,
            'selected_sha256': DIGEST, 'selected_kind': 'executable',
            'version': 'schema-test-fixture'}


def identity():
    return {'schema_version': 1, 'cwd': '/var/tmp/source', 'target_triple': TRIPLE,
            'tools': {name: executable(name) for name in ('cargo', 'rustc')},
            'selection': {'rustup_toolchain': None, 'cargo_commands': ['build'],
                          'cargo_config': []}}


def manifest(observation):
    return {'schema_version': '1.0.0', 'tool': 'schema-test', 'version': 'v1.0.0',
            'run_id': '01234567-89ab-4cde-8012-3456789abcde',
            'source': {'git_sha': '1' * 40, 'git_ref': 'v1.0.0', 'dependencies': []},
            'built_at': '2026-10-13T00:00:00Z', 'status': 'success',
            'summary': {'total': 1, 'success': 1, 'failed': 0},
            'artifacts': [{'name': 'schema-test', 'target': 'linux/amd64',
                           'sha256': DIGEST, 'size_bytes': 1, 'archive_format': 'binary'}],
            'build_environments': [{'target': 'linux/amd64', 'host': 'schema-fixture',
                                    'method': 'native', 'build_influence_env': {},
                                    'cargo_isolation': {'mode': 'strict-release-snapshot',
                                        'source_boundary': 'canonical-fresh-source-root',
                                        'cargo_home': '/var/tmp/cargo-home',
                                        'target_dir': '/var/tmp/target',
                                        'ancestor_config_policy': 'reject', 'cache_reuse': [],
                                        'toolchain': observation}}]}


def target_observation(config=None, environment=None):
    config = config or {'build': {}, 'target': {}}
    environment = environment or {}
    result = identity()
    _, row = OBSERVER['cargo_target_settings'](config, TRIPLE, environment, FACTS)
    if row['cfg_tables']:
        # Probe shape only: these are synthetic facts, never a mocked compiler
        # response supplied to the observer or a release-build receipt.
        values = sorted(name if value is None else name + '=' + json.dumps(value)
                        for name, value in FACTS)
        row['cfg_probe'] = {'compiler_path': '/opt/tools/rustc', 'compiler_sha256': DIGEST,
                            'target_triple': TRIPLE, 'values': values,
                            'sha256': hashlib.sha256(('\n'.join(values) + '\n').encode()).hexdigest()}
    result['selection']['cargo_target'] = row
    return result


def numeric_observation(name='RUST_MIN_STACK', entry='16777216', environment=None):
    result = target_observation()
    row = OBSERVER['cargo_env_exemption'](name, entry)
    receipts = [{'path': '/var/tmp/source/.cargo/config.toml', 'sha256': DIGEST,
                 'env_exemptions': [row]}]
    OBSERVER['cargo_effective_environment']({'env': {name: entry}}, receipts,
                                           dict(environment or {}))
    result['selection']['cargo_config'] = receipts
    return result


def cfg_observation():
    return target_observation({'build': {}, 'target': {
        'cfg(unix)': {'rustflags': ['-C', 'opt-level=2'], 'linker': '/opt/tools/cc'},
        'cfg(windows)': {'rustflags': ['-C', 'debuginfo=1']}}})


def resolver_observation():
    result = target_observation()
    result['tools']['cargo'].update({
        'rustup_resolver': {'path': '/opt/tools/rustup', 'sha256': DIGEST},
        'toolchain_launcher': {'path': '/opt/tools/cargo-wrapper', 'sha256': DIGEST},
        'sysroot_resolver': {'program': 'rustc', 'selected_path': '/opt/tools/rustc',
            'selected_sha256': DIGEST, 'selected_kind': 'executable',
            'sysroot_probe_exit_code': 1, 'sysroot': ''}})
    return result


class ToolchainReceiptSchemaTests(unittest.TestCase):
    def accepted(self, observation):
        errors = list(VALIDATOR.iter_errors(manifest(observation)))
        self.assertFalse(errors, '\n'.join(error.message for error in errors))

    def rejected(self, observation):
        self.assertFalse(VALIDATOR.is_valid(manifest(observation)))

    def test_legacy_receipt_remains_valid(self):
        result = identity()
        result['selection']['cargo_config'] = [{'path': '/source/.cargo/config',
            'sha256': DIGEST, 'env_exemptions': [{'name': 'RUST_MIN_STACK', 'value': '1'}]}]
        self.accepted(result)

    def test_default_production_target_receipt(self):
        result = target_observation()
        self.assertEqual(result['selection']['cargo_target']['rustflags_source'], 'build')
        self.accepted(result)

    def test_numeric_production_receipts_and_precedence(self):
        for name in ('RUST_MIN_STACK', 'RUST_TEST_THREADS'):
            for entry in ('16777216', {'value': '16777216'},
                          {'value': '16777216', 'force': False},
                          {'value': '16777216', 'force': True, 'relative': False}):
                for inherited in ({}, {name: '33554432'}):
                    with self.subTest(name=name, entry=entry, inherited=inherited):
                        result = numeric_observation(name, entry, inherited)
                        row = result['selection']['cargo_config'][0]['env_exemptions'][0]
                        forced = isinstance(entry, dict) and entry.get('force', False)
                        expected = 'environment' if inherited and not forced else 'configuration'
                        self.assertEqual(row['effective_source'], expected)
                        self.assertEqual(row['effective_value'], '33554432' if expected == 'environment' else '16777216')
                        self.accepted(result)

    def test_partial_numeric_provenance_is_rejected(self):
        for field in ('force', 'effective_value', 'effective_force', 'effective_source'):
            with self.subTest(field=field):
                result = numeric_observation()
                del result['selection']['cargo_config'][0]['env_exemptions'][0][field]
                self.rejected(result)

    def test_bad_numeric_evidence_is_rejected(self):
        for field, value in [('name', 'RUSTC'), ('value', '0'), ('value', '1\n'),
                             ('value', 1), ('force', 'false'), ('effective_force', 0),
                             ('effective_value', ''), ('effective_value', '-1'),
                             ('effective_value', '1\n'), ('effective_source', 'assumed'),
                             ('unknown', True)]:
            with self.subTest(field=field, value=value):
                result = numeric_observation()
                result['selection']['cargo_config'][0]['env_exemptions'][0][field] = value
                self.rejected(result)

    def test_matching_and_nonmatching_cfg_contributions(self):
        result = cfg_observation()
        row = result['selection']['cargo_target']
        self.assertEqual(row['matched_cfg'], ['cfg(unix)'])
        self.assertEqual([entry['matched'] for entry in row['cfg_tables']], [True, False])
        self.assertEqual(row['rustflags'], ['-C', 'opt-level=2'])
        self.accepted(result)
        self.accepted(target_observation({'build': {}, 'target': {'cfg(windows)': {}}}))

    def test_environment_overrides_and_encoded_empty_arguments(self):
        for environment, source in [({'RUSTFLAGS': ''}, 'RUSTFLAGS'),
                ({'CARGO_ENCODED_RUSTFLAGS': '\x1f'}, 'CARGO_ENCODED_RUSTFLAGS'),
                ({'CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS': '-C opt-level=1'}, 'target'),
                ({'CARGO_BUILD_RUSTFLAGS': '-C opt-level=2'}, 'build')]:
            with self.subTest(environment=environment):
                result = target_observation(environment=environment)
                self.assertEqual(result['selection']['cargo_target']['rustflags_source'], source)
                self.accepted(result)

    def test_cfg_probe_required_exactly_when_cfg_tables_exist(self):
        result = cfg_observation()
        probe = result['selection']['cargo_target'].pop('cfg_probe')
        self.rejected(result)
        result = target_observation()
        result['selection']['cargo_target']['cfg_probe'] = probe
        self.rejected(result)

    def test_bad_target_and_probe_evidence_is_rejected(self):
        for field, value in [('cfg_tables', {}), ('matched_cfg', [1]), ('linker', 1),
                             ('linker_source', False), ('rustflags', ['-C', 1]),
                             ('rustflags_source', 'invented'), ('unknown', 1)]:
            with self.subTest(field=field):
                result = cfg_observation()
                result['selection']['cargo_target'][field] = value
                self.rejected(result)
        for field in ('compiler_path', 'compiler_sha256', 'target_triple', 'sha256', 'values'):
            with self.subTest(missing=field):
                result = cfg_observation()
                del result['selection']['cargo_target']['cfg_probe'][field]
                self.rejected(result)
        for field, value in [('compiler_path', 'relative/rustc'), ('compiler_sha256', 'bad'),
                             ('sha256', 'bad'), ('values', []), ('unknown', 1)]:
            with self.subTest(probe_field=field):
                result = cfg_observation()
                result['selection']['cargo_target']['cfg_probe'][field] = value
                self.rejected(result)
        for field, value in [('matched', 'false'), ('expression', 'unix'), ('rustflags', [1]),
                             ('linker', None), ('unknown', 1)]:
            with self.subTest(decision_field=field):
                result = cfg_observation()
                result['selection']['cargo_target']['cfg_tables'][0][field] = value
                self.rejected(result)

    def test_rustup_and_rch_dispatch_shapes(self):
        result = resolver_observation()
        self.accepted(result)
        resolver = result['tools']['cargo']['sysroot_resolver']
        resolver.update(version='', sysroot='/opt/toolchain', sysroot_probe_exit_code=0,
                        resolved_path='/opt/toolchain/bin/rustc', resolved_sha256=DIGEST,
                        resolved_kind='executable',
                        rustup_resolver={'path': '/opt/tools/rustup', 'sha256': DIGEST})
        self.accepted(result)
        result['tools']['cargo']['sysroot_resolver'] = None
        self.accepted(result)

    def test_dispatch_pins_are_closed_and_complete(self):
        for name in ('rustup_resolver', 'toolchain_launcher'):
            for field, value in [('path', 'relative/tool'), ('sha256', 'bad'), ('unknown', 1)]:
                with self.subTest(name=name, field=field):
                    result = resolver_observation()
                    result['tools']['cargo'][name][field] = value
                    self.rejected(result)
            for missing in ('path', 'sha256'):
                with self.subTest(name=name, missing=missing):
                    result = resolver_observation()
                    del result['tools']['cargo'][name][missing]
                    self.rejected(result)

    def test_sysroot_resolution_is_closed_and_complete(self):
        original = resolver_observation()
        for missing in original['tools']['cargo']['sysroot_resolver']:
            with self.subTest(missing=missing):
                result = deepcopy(original)
                del result['tools']['cargo']['sysroot_resolver'][missing]
                self.rejected(result)
        for field, value in [('program', 'cargo'), ('selected_sha256', 'bad'),
                             ('selected_path', 'relative/rustc'), ('selected_kind', 'unknown'),
                             ('sysroot_probe_exit_code', '0'), ('sysroot', None), ('unknown', 1),
                             ('resolved_path', '/opt/toolchain/rustc')]:
            with self.subTest(field=field):
                result = deepcopy(original)
                result['tools']['cargo']['sysroot_resolver'][field] = value
                self.rejected(result)

    def test_resolved_executable_fields_are_atomic(self):
        original = target_observation()
        original['tools']['cargo'].update(resolved_path='/opt/toolchain/cargo',
                                         resolved_sha256=DIGEST, resolved_kind='executable')
        self.accepted(original)
        for missing in ('resolved_path', 'resolved_sha256', 'resolved_kind'):
            with self.subTest(missing=missing):
                result = deepcopy(original)
                del result['tools']['cargo'][missing]
                self.rejected(result)

    def test_unrecognized_observation_fields_still_fail(self):
        for location in ((), ('selection',), ('tools', 'cargo'),
                         ('selection', 'cargo_target')):
            with self.subTest(location=location):
                result = target_observation()
                value = result
                for key in location:
                    value = value[key]
                value['unexpected'] = True
                self.rejected(result)

    def test_native_windows_requirements_are_preserved(self):
        result = identity()
        result.update(cwd='C:/source', target_triple='x86_64-pc-windows-msvc')
        result['tools'] = {name: executable(name, 'C:/tools') for name in ('cargo', 'rustc', 'linker')}
        self.accepted(result)
        for change in ('no-linker', 'script', 'relative', 'no-version'):
            with self.subTest(change=change):
                changed = deepcopy(result)
                if change == 'no-linker':
                    del changed['tools']['linker']
                elif change == 'script':
                    changed['tools']['rustc']['selected_kind'] = 'script'
                elif change == 'relative':
                    changed['tools']['cargo']['selected_path'] = '/unix/cargo'
                else:
                    changed['tools']['cargo']['version'] = ''
                self.rejected(changed)


if __name__ == '__main__':
    unittest.main(verbosity=2)
