#!/usr/bin/env bash
# Raw-count policy tests plus real df/local host-health admission. No fake
# binaries or replaced production functions. APFS root counts are fixtures;
# this is not live macOS qualification. Evidence is retained, never cleaned.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
for tool in python3 jq df bash; do
    command -v "$tool" >/dev/null || { echo "SKIP: $tool is required" >&2; exit 77; }
done
export DSR_TEST_DISK_BASH="$BASH"
python3 - "$ROOT" "$@" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1))
MODULE = Path(os.environ.get('DSR_TEST_HOST_HEALTH', ROOT / 'src/host_health.sh'))
BASELINE = os.environ.get('DSR_TEST_DISK_BASELINE')
BASH = os.environ['DSR_TEST_DISK_BASH']
WORK = Path(tempfile.mkdtemp(prefix='dsr-disk-floor-'))
print('Retained evidence:', WORK, flush=True)
GIB = 1024**3
MINIMUM = 20 * GIB
FLOOR_KB = MINIMUM // 1024


class DiskFloor(unittest.TestCase):
    def setUp(self):
        self.work = WORK / self.id().rsplit('.', 1)[-1]
        self.work.mkdir()
        self.env = dict(os.environ, DSR_CACHE_DIR=str(self.work / 'cache'),
                        DSR_HOSTS_FILE=str(self.work / 'hosts.yaml'), NO_COLOR='1')
        Path(self.env['DSR_HOSTS_FILE']).write_text(
            'hosts:\n  localtest:\n    platform: linux/amd64\n    connection: local\n'
            '    enabled: true\n    capabilities:\n')
        self.sequence = 0

    def call(self, function, *arguments, module=MODULE, setup=''):
        # Initialize the config cache as a sourceable consumer. Host selection
        # uses the real fallback reader (or installed real yq); no configured
        # storage/helper behavior is replaced. Config initialization and the
        # monolithic CLI remain outside this standalone admission test.
        program = ('declare -A DSR_CONFIG=(); source "$1/src/logging.sh"; '
                   'source "$2"; shift 2; ' + setup + '; "$@"')
        result = subprocess.run([BASH, '-c', program, '_', str(ROOT), str(module),
                                 function, *map(str, arguments)], env=self.env,
                                text=True, capture_output=True, timeout=20)
        self.sequence += 1
        (self.work / f'{self.sequence}.stdout').write_text(result.stdout)
        (self.work / f'{self.sequence}.stderr').write_text(result.stderr)
        return result

    def verdict(self, usage, kb, expected, minimum=MINIMUM):
        result = self.call('_hh_disk_status', usage, kb, minimum, setup=':')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected + '\n')

    def test_reported_apfs_counts_refuse(self):
        self.verdict(84, 2427860, 'error')

    def test_zero_free_refuses_even_at_zero_percent(self):
        self.verdict(0, 0, 'error')

    def test_one_kib_below_floor_refuses(self):
        self.verdict(10, FLOOR_KB - 1, 'error')

    def test_exact_floor_accepts(self):
        self.verdict(10, FLOOR_KB, 'ok')

    def test_one_kib_above_floor_accepts(self):
        self.verdict(10, FLOOR_KB + 1, 'ok')

    def test_fractional_kib_floor_is_rounded_up(self):
        self.verdict(10, FLOOR_KB, 'error', MINIMUM + 1)
        self.verdict(10, FLOOR_KB + 1, 'ok', MINIMUM + 1)

    def test_percentage_warning_still_applies(self):
        self.verdict(91, FLOOR_KB * 2, 'warning')

    def test_percentage_error_still_applies(self):
        self.verdict(96, FLOOR_KB * 2, 'error')

    def test_percentage_boundaries_unchanged(self):
        self.verdict(90, FLOOR_KB, 'ok')
        self.verdict(95, FLOOR_KB, 'warning')

    def test_byte_floor_overrides_percentage_warning(self):
        self.verdict(91, FLOOR_KB - 1, 'error')

    def test_decimal_leading_zeroes(self):
        self.verdict('084', '0000002427860', 'error')
        self.verdict('010', '0000020971520', 'ok')

    def test_malformed_counts_never_reach_arithmetic(self):
        for usage, kb, minimum in [
            ('', 1, MINIMUM), ('101', 1, MINIMUM), ('-1', 1, MINIMUM),
            ('1.5', 1, MINIMUM), ('1+2', 1, MINIMUM),
            (0, '-1', MINIMUM), (0, '2e20', MINIMUM),
            (0, '99999999999999999999', MINIMUM), (0, '8796093022208', MINIMUM),
            (0, FLOOR_KB, 0), (0, FLOOR_KB, '-1'),
            (0, FLOOR_KB, '9007199254740992'), (0, FLOOR_KB, 'bad'),
        ]:
            with self.subTest(usage=usage, kb=kb, minimum=minimum):
                result = self.call('_hh_disk_status', usage, kb, minimum, setup=':')
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertEqual(result.stdout, '')

    def test_arithmetic_payload_is_data(self):
        marker = self.work / 'must-not-exist'
        attack = f'a[$(touch {marker})]'
        for arguments in [(attack, 1, MINIMUM), (0, attack, MINIMUM),
                          (0, FLOOR_KB, attack)]:
            result = self.call('_hh_disk_status', *arguments, setup=':')
            self.assertEqual(result.returncode, 4, result.stderr)
        self.assertFalse(marker.exists())

    def split(self, usage, kb, raw_status, minimum=MINIMUM, root=None, module=MODULE):
        selected = root or self.work
        storage = json.dumps(dict(build_root=str(selected), root_min_free_bytes=minimum))
        result = self.call('_hh_unix_split_storage_admission', 'localtest', 'local', '',
                           storage, usage, kb, raw_status, module=module, setup=':')
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def require_room(self):
        stats = os.statvfs(self.work)
        if stats.f_bavail * stats.f_frsize < MINIMUM:
            self.skipTest('split-storage positive needs 20 GiB already free; no disk is filled/cleaned')

    def test_split_root_floor_is_not_conditional_on_percentage(self):
        result = self.split(84, 2427860, 'ok')
        self.assertEqual(result['status'], 'error')
        self.assertEqual(result['root']['admitted_as'], 'error')
        self.assertEqual(result['root']['status'], 'ok')
        self.assertEqual(result['root']['available_bytes'], 2427860 * 1024)

    def test_healthy_split_root_exception_is_retained(self):
        self.require_room()
        result = self.split(96, 30 * GIB // 1024, 'error')
        self.assertEqual(result['status'], 'warning')
        self.assertEqual(result['root']['status'], 'error')
        self.assertEqual(result['root']['admitted_as'], 'warning')
        self.assertEqual(result['build_root']['status'], 'ok')

    def test_split_contract_keeps_its_explicit_root_floor(self):
        self.require_room()
        result = self.split(96, 15 * GIB // 1024, 'error', minimum=10 * GIB)
        self.assertEqual(result['root']['admitted_as'], 'warning')
        self.assertEqual(result['root']['min_free_bytes'], 10 * GIB)

    def test_split_build_root_has_an_independent_floor(self):
        small = Path('/dev/shm')
        if not small.is_dir():
            self.skipTest('requires an existing small Linux tmpfs for a genuine df negative')
        stats = os.statvfs(small)
        if stats.f_bavail * stats.f_frsize >= MINIMUM:
            self.skipTest('existing tmpfs is not below the floor; no filesystem is modified')
        result = self.split(10, 100 * GIB // 1024, 'ok', root=small)
        self.assertEqual(result['status'], 'error')
        self.assertEqual(result['build_root']['status'], 'error')
        self.assertLess(result['build_root']['available_bytes'], MINIMUM)
        self.assertEqual(result['build_root']['min_free_bytes'], MINIMUM)

    def test_split_missing_required_path_is_error(self):
        storage = json.dumps(dict(build_root=str(self.work / 'absent'), root_min_free_bytes=MINIMUM))
        result = self.call('_hh_unix_split_storage_admission', 'localtest', 'local', '',
                           storage, 10, FLOOR_KB * 2, 'ok', setup=':')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['status'], 'error')

    def test_live_default_probe_reports_unrounded_capacity(self):
        result = self.call('_hh_check_disk_space', 'localtest', 'local', '', 'linux/amd64', setup=':')
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value['min_free_bytes'], MINIMUM)
        self.assertIsInstance(value['available_bytes'], int)
        self.assertEqual(value['available_bytes'] % 1024, 0)
        classified = self.call('_hh_disk_status', value['usage_percent'],
                               value['available_bytes'] // 1024, MINIMUM, setup=':')
        self.assertEqual(value['status'], classified.stdout.strip())

    def test_bad_policy_cannot_become_healthy_in_public_check(self):
        result = self.call('host_health_check', 'localtest', '--no-cache', '--json',
                           setup='_HH_DISK_MIN_FREE_BYTES=invalid')
        self.assertEqual(result.returncode, 1, result.stderr)
        value = json.loads(result.stdout)
        self.assertFalse(value['healthy'])
        self.assertEqual(value['checks']['disk_space']['status'], 'error')
        self.assertEqual(value['errors'], 1)

    def test_human_report_names_capacity_not_false_percentage(self):
        value = dict(status='error', healthy=False, platform='darwin/arm64', checks=dict(
            connectivity=dict(reachable=True), toolchains={}, disk_space=dict(
                status='error', usage_percent=84, error='Available disk space is below the required 20 GiB floor')))
        result = self.call('_hh_print_result', 'localtest', json.dumps(value), setup=':')
        self.assertIn('20 GiB floor', result.stderr)
        self.assertNotIn('Disk usage > 95%', result.stderr)

    def test_floor_participates_in_cache_identity(self):
        config = '{"platform":"linux/amd64","connection":"local"}'
        first = self.call('_hh_admission_fingerprint', config, setup=':')
        second = self.call('_hh_admission_fingerprint', config,
                           setup='_HH_DISK_MIN_FREE_BYTES=21474836481')
        self.assertEqual(first.returncode, 0)
        self.assertEqual(second.returncode, 0)
        self.assertNotEqual(first.stdout, second.stdout)
        if BASELINE:
            old = self.call('_hh_admission_fingerprint', config, module=BASELINE, setup=':')
            self.assertEqual(old.returncode, 0)
            self.assertNotEqual(first.stdout, old.stdout)

    @unittest.skipUnless(BASELINE, 'set DSR_TEST_DISK_BASELINE to run the unchanged incumbent')
    def test_incumbent_accepts_the_same_false_green_split_input(self):
        self.require_room()
        old = self.split(84, 2427860, 'ok', module=BASELINE)
        new = self.split(84, 2427860, 'ok')
        self.assertEqual(old['status'], 'ok')
        self.assertEqual(new['status'], 'error')
        print('CONTROL: same 84% / 2427860 KiB root counts and genuine build-root df: incumbent ok, candidate error')


unittest.main(verbosity=2)
PY
