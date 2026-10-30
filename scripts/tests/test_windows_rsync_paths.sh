#!/usr/bin/env bash
# Windows receiver path policy, using real Bash/jq and owned configuration
# files. Native Windows rsync/SSH behavior is not simulated or claimed.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
for tool in python3 jq; do
    command -v "$tool" >/dev/null || {
        printf 'SKIP: Windows rsync path tests require %s\n' "$tool" >&2
        exit 77
    }
done
export DSR_TEST_RSYNC_BASH="$BASH"
python3 - "$ROOT" "$@" <<'PY'
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

root = Path(sys.argv.pop(1))
module = Path(os.environ.get('DSR_TEST_ACT_RUNNER', root / 'src/act_runner.sh'))
source = module.read_text()
# Isolate the exact production definitions so unrelated native compiler and
# CLI startup dependencies are not needed for path-policy tests. No binary,
# config parser, transport or path function is replaced with a test double.
functions = []
for name in ('_act_windows_rsync_prefix_from_json', '_act_windows_rsync_path',
             '_act_windows_rsync_host_path'):
    match = re.search(r'^' + re.escape(name) + r'\(\) \{\n.*?^\}', source, re.M | re.S)
    if match:
        functions.append(match.group(0))
# The retained source defines this logger before the tested functions. Keep
# stderr behavior without importing unrelated CLI/module initialization.
logging = '_RED=""; _NC=""\n_log_error() { echo "${_RED}[act]${_NC} $*" >&2; }\n'
program = 'set -uo pipefail\n' + logging + '\n'.join(functions) + '\n"$@"\n'
work = Path(tempfile.mkdtemp(prefix='dsr-windows-rsync-tests-'))
print('Fixtures retained:', work, flush=True)
(work / 'production-functions.sh').write_text(program)


class WindowsRsyncPaths(unittest.TestCase):
    def call(self, function, *args, env=None, configuration_module=False):
        environment = dict(os.environ)
        environment.pop('DSR_HOSTS_FILE', None)
        if env:
            environment.update(env)
        script = program
        if configuration_module:
            script = 'source ' + shlex.quote(str(root / 'src/config.sh')) + ' || exit $?\n' + script
        return subprocess.run([os.environ['DSR_TEST_RSYNC_BASH'], '-c', script,
                               '_', function, *map(str, args)], env=environment,
                              capture_output=True, text=True, timeout=10)

    def converted(self, path, expected, prefix=None):
        args = (path,) if prefix is None else (path, prefix)
        result = self.call('_act_windows_rsync_path', *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected + '\n')
        self.assertEqual(result.stderr, '')

    def prefix(self, config, host='wlap'):
        return self.call('_act_windows_rsync_prefix_from_json', host, json.dumps(config))

    def test_default_cygwin_preserves_existing_drive_conversion(self):
        for path, expected in [('C:/d/app', '/cygdrive/c/d/app'),
                               ('D:\\Work\\App.exe', '/cygdrive/d/Work/App.exe'),
                               ('z:/', '/cygdrive/z/'), ('C:', '/cygdrive/c')]:
            with self.subTest(path=path):
                self.converted(path, expected)

    def test_empty_prefix_is_msys2_not_default(self):
        for path, expected in [('C:/d/app', '/c/d/app'),
                               ('D:\\Work\\App.exe', '/d/Work/App.exe'),
                               ('z:/', '/z/'), ('C:', '/c')]:
            with self.subTest(path=path):
                self.converted(path, expected, '')

    @unittest.skipUnless(os.environ.get('DSR_TEST_RSYNC_BASELINE'), 'no exact incumbent module selected')
    def test_incumbent_msys2_counterexample_in_same_invocation(self):
        baseline_source = Path(os.environ['DSR_TEST_RSYNC_BASELINE']).read_text()
        baseline = re.search(r'^_act_windows_rsync_path\(\) \{\n.*?^\}', baseline_source, re.M | re.S)
        self.assertIsNotNone(baseline, 'selected incumbent lacks the production path function')
        previous = subprocess.run([os.environ['DSR_TEST_RSYNC_BASH'], '-c',
            baseline.group(0) + '\n_act_windows_rsync_path "$1" "$2"', '_', 'C:/d/app', ''],
            text=True, capture_output=True, timeout=10)
        self.assertEqual(previous.returncode, 0, previous.stderr)
        self.assertEqual(previous.stdout, '/cygdrive/c/d/app\n')
        self.converted('C:/d/app', '/c/d/app', '')

    def test_all_drive_letters(self):
        for drive in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ':
            with self.subTest(drive=drive):
                self.converted(drive + ':/build/source', '/' + drive.lower() + '/build/source', '')

    def test_custom_absolute_prefix(self):
        for prefix in ('/mnt', '/drives/windows', '/volume-1/drive_root', '/proc/cygdrive'):
            with self.subTest(prefix=prefix):
                self.converted('E:/src/App', prefix + '/e/src/App', prefix)

    def test_posix_paths_are_not_prefixed_twice(self):
        for path in ('/c/work/app', '/cygdrive/c/work/app', '/drives/c/work/app'):
            for prefix in ('', '/cygdrive', '/drives'):
                with self.subTest(path=path, prefix=prefix):
                    self.converted(path, path, prefix)

    def test_spaces_unicode_and_case_remain_literal(self):
        self.converted('C:/Users/Alice Smith/\u00e9tude/App.EXE', '/c/Users/Alice Smith/\u00e9tude/App.EXE', '')

    def test_unsafe_prefixes_refused_with_no_path_output(self):
        for prefix in ('relative', '/', '/mnt/', '//mnt', '/mnt//x', '/.', '/..',
                       '/mnt/../escape', '/mnt/./drive', 'C:/mnt', '/with space',
                       '/foo:bar', '/foo\\bar', '/foo\nbar', '/foo;id', '/$(id)', '/`id`'):
            with self.subTest(prefix=prefix):
                result = self.call('_act_windows_rsync_path', 'C:/d/app', prefix)
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertEqual(result.stdout, '')

    def test_empty_control_and_ambiguous_paths_refused(self):
        for path in ('', 'C:relative', 'C:/line\nnext', 'C:/tab\tnext', 'C:/carriage\rnext'):
            with self.subTest(path=path):
                result = self.call('_act_windows_rsync_path', path, '')
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertEqual(result.stdout, '')

    def test_absent_setting_retains_cygwin(self):
        for config in ({'hosts': {}}, {'hosts': {'wlap': {}}},
                       {'hosts': {'wlap': {'platform': 'windows/amd64'}}}):
            with self.subTest(config=config):
                result = self.prefix(config)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, '/cygdrive\n')

    def test_explicit_empty_setting_survives_json_parsing(self):
        result = self.prefix({'hosts': {'wlap': {'windows_rsync_drive_prefix': ''}}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '\n')

    def test_host_selection_is_literal_and_isolated(self):
        config = {'hosts': {
            'windows.msys-1': {'windows_rsync_drive_prefix': ''},
            'windows.cygwin-2': {'windows_rsync_drive_prefix': '/cygdrive'},
            'windows.custom-3': {'windows_rsync_drive_prefix': '/drives'},
        }}
        for host, expected in [('windows.msys-1', ''), ('windows.cygwin-2', '/cygdrive'),
                               ('windows.custom-3', '/drives')]:
            with self.subTest(host=host):
                result = self.prefix(config, host)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected + '\n')

    def test_nonstring_settings_never_default(self):
        for value in (None, False, True, 0, 1, [], {}, ['/cygdrive']):
            with self.subTest(value=value):
                result = self.prefix({'hosts': {'wlap': {'windows_rsync_drive_prefix': value}}})
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertEqual(result.stdout, '')

    def test_unsafe_json_settings_never_default(self):
        for prefix in ('relative', '/', '/mnt/', '/mnt/../x', '/$(id)', '/a\nb'):
            with self.subTest(prefix=prefix):
                result = self.prefix({'hosts': {'wlap': {'windows_rsync_drive_prefix': prefix}}})
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertEqual(result.stdout, '')

    def test_malformed_host_documents_are_refused(self):
        for document in ('{} {}', '{broken', 'null', '[]', '{}', '{"hosts":[]}',
                         '{"hosts":{"wlap":false}}', '{"hosts":{"wlap":[]}}'):
            with self.subTest(document=document):
                result = self.call('_act_windows_rsync_prefix_from_json', 'wlap', document)
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertEqual(result.stdout, '')

    def test_unconfigured_host_needs_no_yaml_parser(self):
        result = self.call('_act_windows_rsync_host_path', 'wlap', 'C:/d/app')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '/cygdrive/c/d/app\n')

    def test_absent_optional_hosts_file_preserves_unconfigured_host(self):
        result = self.call('_act_windows_rsync_host_path', 'wlap', 'C:/d/app',
                           env={'DSR_HOSTS_FILE': str(work / 'not-created.yaml')})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '/cygdrive/c/d/app\n')

    def test_linked_or_directory_hosts_configuration_is_refused(self):
        regular = work / 'hosts-reference.json'
        regular.write_text('{"hosts":{}}')
        link = work / 'hosts-linked.json'
        link.symlink_to(regular)
        for path in (link, work):
            with self.subTest(path=path):
                result = self.call('_act_windows_rsync_host_path', 'wlap', 'C:/d/app',
                                   env={'DSR_HOSTS_FILE': str(path)})
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertEqual(result.stdout, '')

    @unittest.skipIf(shutil.which('yq'), 'missing-yq condition is not present')
    def test_missing_yaml_dependency_is_not_a_silent_prefix_fallback(self):
        config = work / 'needs-yq.yaml'
        config.write_text('hosts:\n  wlap:\n    windows_rsync_drive_prefix: ""\n')
        result = self.call('_act_windows_rsync_host_path', 'wlap', 'C:/d/app',
                           env={'DSR_HOSTS_FILE': str(config)})
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn('yq and jq', result.stderr)
        self.assertEqual(result.stdout, '')

    @unittest.skipUnless(shutil.which('yq'), 'real Mike Farah yq is unavailable; no replacement parser')
    def test_real_yaml_host_mapping_and_configuration_changes(self):
        config = work / 'real-hosts.yaml'
        for value, expected in [('""', '/c/d/app'), ('/cygdrive', '/cygdrive/c/d/app'),
                                ('/drives', '/drives/c/d/app')]:
            config.write_text('hosts:\n  windows.msys-1:\n    platform: windows/amd64\n'
                              '    windows_rsync_drive_prefix: ' + value + '\n')
            result = self.call('_act_windows_rsync_host_path', 'windows.msys-1', 'C:/d/app',
                               env={'DSR_HOSTS_FILE': str(config)}, configuration_module=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected + '\n')

    @unittest.skipUnless(shutil.which('yq'), 'real Mike Farah yq is unavailable; no replacement parser')
    def test_real_yaml_invalid_setting_does_not_emit_receiver_path(self):
        config = work / 'invalid-hosts.yaml'
        config.write_text('hosts:\n  wlap:\n    windows_rsync_drive_prefix: false\n')
        result = self.call('_act_windows_rsync_host_path', 'wlap', 'C:/d/app',
                           env={'DSR_HOSTS_FILE': str(config)}, configuration_module=True)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(result.stdout, '')


unittest.main(verbosity=2)
PY
