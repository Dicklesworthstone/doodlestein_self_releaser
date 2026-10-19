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
import copy
import os
from pathlib import Path
import plistlib
import shutil
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
                        DSR_CONFIG_DIR=str(self.work / 'config'),
                        DSR_CONFIG_FILE=str(self.work / 'config.yaml'),
                        DSR_REPOS_FILE=str(self.work / 'repos.yaml'),
                        DSR_STATE_DIR=str(self.work / 'state'),
                        DSR_HOSTS_FILE=str(self.work / 'hosts.yaml'), NO_COLOR='1')
        self.env.pop('CARGO_HOME', None)
        self.env.pop('CARGO_TARGET_DIR', None)
        self.env.pop('TMPDIR', None)
        Path(self.env['DSR_HOSTS_FILE']).write_text(
            'hosts:\n  localtest:\n    platform: linux/amd64\n    connection: local\n'
            '    enabled: true\n    capabilities:\n')
        self.sequence = 0

    def call(self, function, *arguments, module=MODULE, setup=''):
        # A complete checkout loads its actual config module, including the
        # YAML parser helpers. The retained partial-workspace mode only supports
        # the existing no-yq reader; no function or executable is replaced.
        if shutil.which('yq') and not (ROOT / 'src/config.sh').is_file():
            self.skipTest('real yq requires the complete production config module')
        program = ('if [[ -f "$1/src/config.sh" ]]; then source "$1/src/config.sh" || exit $?; '
                   'else declare -A DSR_CONFIG=(); fi; source "$1/src/logging.sh" || exit $?; '
                   'source "$2" || exit $?; shift 2; ' + setup + '; "$@"')
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

    def default_probe(self, **changes):
        self.env.update(changes)
        result = self.call('_hh_check_disk_space', 'localtest', 'local', '', 'linux/amd64', setup=':')
        return result, json.loads(result.stdout)

    def small_filesystem(self):
        selected = Path('/dev/shm')
        if not selected.is_dir() or os.statvfs(selected).f_bavail * os.statvfs(selected).f_frsize >= MINIMUM:
            self.skipTest('requires an existing filesystem below 20 GiB; no disk is filled')
        return selected

    def test_default_writable_roles_are_complete_and_grouped_without_summing(self):
        result, value = self.default_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(value['admission'], 'unix-writable-roles-v2')
        self.assertEqual({r['role'] for r in value['roles']},
                         {'root', 'home', 'cargo_home', 'temp', 'build_root'})
        for role in value['roles']:
            stats = os.statvfs(role['probe_path'])
            self.assertEqual(role['filesystem_id'], str(os.stat(role['probe_path']).st_dev))
            self.assertEqual(role['min_free_bytes'], MINIMUM)
            self.assertEqual(role['total_bytes'], stats.f_blocks * (stats.f_frsize or stats.f_bsize))
        self.assertEqual(len(value['filesystems']), len({r['filesystem_id'] for r in value['roles']}))
        for filesystem in value['filesystems']:
            rows = [r for r in value['roles'] if r['filesystem_id'] == filesystem['filesystem_id']]
            self.assertEqual(filesystem['available_bytes'], min(r['available_bytes'] for r in rows))
            self.assertEqual(set(filesystem['roles']), {r['role'] for r in rows})

    def test_configured_build_root_is_checked_without_split_opt_in(self):
        small = self.small_filesystem()
        with Path(self.env['DSR_HOSTS_FILE']).open('a') as output:
            output.write(f'    build_root: "{small}"\n')
        result, value = self.default_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        build = next(r for r in value['roles'] if r['role'] == 'build_root')
        self.assertEqual(build['path'], str(small))
        self.assertEqual(build['status'], 'error')
        self.assertEqual(value['status'], 'error')
        public = self.call('host_health_check', 'localtest', '--no-cache', '--json', setup=':')
        self.assertEqual(public.returncode, 1, public.stderr)
        self.assertFalse(json.loads(public.stdout)['healthy'])

    def test_tight_temp_cannot_hide_behind_healthy_build_root(self):
        result, value = self.default_probe(TMPDIR=str(self.small_filesystem()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(value['status'], 'error')
        self.assertEqual(next(r['status'] for r in value['roles'] if r['role'] == 'temp'), 'error')
        self.assertIn('temp /dev/shm', value['error'])

    def test_tight_cargo_home_and_target_are_each_required(self):
        small = str(self.small_filesystem())
        for field, role in [('CARGO_HOME', 'cargo_home'), ('CARGO_TARGET_DIR', 'cargo_target')]:
            with self.subTest(field=field):
                result, value = self.default_probe(**{field: small})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(value['status'], 'error')
                self.assertEqual(next(r['status'] for r in value['roles'] if r['role'] == role), 'error')
                self.env.pop(field)

    def test_missing_configured_build_root_refuses(self):
        with Path(self.env['DSR_HOSTS_FILE']).open('a') as output:
            output.write(f'    build_root: {self.work}/missing\n')
        result, value = self.default_probe()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(value['status'], 'error')

    def test_missing_or_relative_environment_roles_refuse(self):
        for field in ('HOME', 'CARGO_HOME', 'TMPDIR', 'CARGO_TARGET_DIR'):
            before = dict(self.env)
            for chosen in (str(self.work / 'absent'), 'relative-path'):
                with self.subTest(field=field, path=chosen):
                    result, value = self.default_probe(**{field: chosen})
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(value['status'], 'error')
                    self.env = dict(before)

    def test_absent_implicit_cargo_home_probes_its_actual_parent(self):
        result, value = self.default_probe(HOME=str(self.work))
        self.assertEqual(result.returncode, 0, result.stderr)
        cargo = next(r for r in value['roles'] if r['role'] == 'cargo_home')
        self.assertEqual(cargo['path'], str(self.work / '.cargo'))
        self.assertEqual(cargo['probe_path'], str(self.work.resolve()))
        self.assertFalse((self.work / '.cargo').exists())

    def test_environment_path_metacharacters_are_literal_data(self):
        cargo = self.work / 'cargo $(touch not-executed); quote\'s'
        cargo.mkdir()
        result, value = self.default_probe(CARGO_HOME=str(cargo))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(next(r['path'] for r in value['roles'] if r['role'] == 'cargo_home'), str(cargo))
        self.assertFalse((self.work / 'not-executed').exists())

    def test_configured_path_cannot_inject_a_remote_command(self):
        marker = self.work / 'injected'
        body = dict(build_root=f'/tmp/$(touch {marker})', platform='linux/amd64')
        result = self.call('_hh_default_unix_storage_admission', 'localtest', 'local', '',
                           json.dumps(body), setup=':')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['status'], 'error')
        self.assertFalse(marker.exists())

    def test_human_role_report_retains_every_writable_location(self):
        result, value = self.default_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = self.call('_hh_split_storage_lines', json.dumps(dict(checks=dict(disk_space=value))), setup=':')
        self.assertEqual(len(lines.stdout.splitlines()), len(value['roles']))
        for row in value['roles']:
            self.assertIn(row['role'] + ' ' + row['path'], lines.stdout)

    @unittest.skipUnless(BASELINE, 'set DSR_TEST_DISK_BASELINE for the unchanged default root-only probe')
    def test_incumbent_ignores_the_same_real_low_capacity_temp(self):
        self.require_room()
        self.env['TMPDIR'] = str(self.small_filesystem())
        old = self.call('host_health_check', 'localtest', '--no-cache', '--json', module=BASELINE, setup=':')
        new = self.call('host_health_check', 'localtest', '--no-cache', '--json', setup=':')
        self.assertEqual(old.returncode, 0, old.stderr)
        self.assertTrue(json.loads(old.stdout)['healthy'])
        self.assertEqual(new.returncode, 1, new.stderr)
        self.assertFalse(json.loads(new.stdout)['healthy'])
        self.assertIn('temp /dev/shm', json.loads(new.stdout)['checks']['disk_space']['error'])

    @unittest.skipUnless(BASELINE, 'set DSR_TEST_DISK_BASELINE to run the unchanged incumbent')
    def test_incumbent_accepts_the_same_false_green_split_input(self):
        self.require_room()
        old = self.split(84, 2427860, 'ok', module=BASELINE)
        new = self.split(84, 2427860, 'ok')
        self.assertEqual(old['status'], 'ok')
        self.assertEqual(new['status'], 'error')
        print('CONTROL: same 84% / 2427860 KiB root counts and genuine build-root df: incumbent ok, candidate error')


class ApfsCapacity(unittest.TestCase):
    """Real production parser/policy; diskutil observations are explicit data.

    No fake macOS host, diskutil executable, subprocess response, or production
    function is installed. The existing class covers actual Unix host probes.
    """
    @classmethod
    def setUpClass(cls):
        emit = subprocess.run([BASH, '-c',
            'declare -A DSR_CONFIG=(); source "$1/src/logging.sh"; source "$2"; '
            '_hh_unix_writable_probe_script', '_', str(ROOT), str(MODULE)],
            capture_output=True, text=True, check=True, timeout=10)
        cls.probe = {'__name__': 'dsr_probe_parser_test'}
        exec(compile(emit.stdout, str(MODULE) + ':writable-probe', 'exec'), cls.probe)
        (WORK / 'tested-probe.py').write_text(emit.stdout)

    def setUp(self):
        self.work = WORK / self.id().rsplit('.', 1)[-1]
        self.work.mkdir()
        self.document = {'Containers': [{
            'ContainerReference': 'disk3',
            'APFSContainerUUID': '11111111-2222-4333-8444-555555555555',
            'CapacityCeiling': 500 * GIB, 'CapacityFree': 100 * GIB,
            'Volumes': [dict(DeviceIdentifier='disk3s1', CapacityInUse=10 * GIB,
                             CapacityQuota=0, CapacityReserve=0),
                        dict(DeviceIdentifier='disk3s5', CapacityInUse=30 * GIB,
                             CapacityQuota=0, CapacityReserve=0)]}]}
        self.infos = {'10': dict(FilesystemType='apfs', DeviceIdentifier='disk3s1',
                                APFSContainerReference='disk3'),
                      '20': dict(FilesystemType='apfs', DeviceIdentifier='disk3s5',
                                APFSContainerReference='disk3')}
        self.rows = [dict(role=role, path='/fixture/' + role, probe_path='/fixture/' + role,
                         filesystem_id=fs, usage_percent=80,
                         available_bytes=100 * GIB, total_bytes=500 * GIB)
                     for role, fs in [('root', '10'), ('home', '10'), ('cargo_home', '10'),
                                      ('temp', '20'), ('build_root', '20')]]
        self.sequence = 0

    def bind(self, fmt=plistlib.FMT_XML):
        data = plistlib.dumps(self.document, fmt=fmt)
        inventory = self.probe['apfs_inventory'](data)
        return self.probe['bind_apfs'](self.rows, self.infos, inventory)

    def verdict(self, rows):
        result = subprocess.run([BASH, '-c',
            'declare -A DSR_CONFIG=(); source "$1/src/logging.sh"; source "$2"; '
            '_hh_writable_storage_verdict', '_', str(ROOT), str(MODULE)],
            input=json.dumps(dict(roles=rows)), text=True, capture_output=True, timeout=10)
        self.sequence += 1
        (self.work / f'{self.sequence}.stdout').write_text(result.stdout)
        (self.work / f'{self.sequence}.stderr').write_text(result.stderr)
        return result

    def accepted(self, rows):
        result = self.verdict(rows)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_apfs_distinct_volumes_share_one_pool_without_losing_roles(self):
        value = self.accepted(self.bind())
        self.assertEqual(value['status'], 'ok')
        self.assertEqual(len(value['filesystems']), 2)
        self.assertEqual(len(value['capacity_groups']), 1)
        pool = value['capacity_groups'][0]
        self.assertEqual(pool['filesystem_ids'], ['10', '20'])
        self.assertEqual(sorted(pool['roles']), sorted(r['role'] for r in self.rows))
        self.assertEqual(pool['available_bytes'], 100 * GIB)
        self.assertEqual(pool['apfs_container']['available_bytes'], 100 * GIB)

    def test_binary_and_xml_plists_produce_identical_evidence(self):
        self.assertEqual(self.bind(plistlib.FMT_BINARY), self.bind())

    def test_distinct_containers_never_share_capacity(self):
        second = copy.deepcopy(self.document['Containers'][0])
        second.update(ContainerReference='disk8', APFSContainerUUID='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee')
        second['Volumes'] = [dict(second['Volumes'][1], DeviceIdentifier='disk8s1')]
        self.document['Containers'].append(second)
        self.infos['20'].update(DeviceIdentifier='disk8s1', APFSContainerReference='disk8')
        value = self.accepted(self.bind())
        self.assertEqual(len(value['capacity_groups']), 2)

    def test_reported_232_gib_container_cannot_be_offset_by_volume_counts(self):
        self.document['Containers'][0]['CapacityFree'] = 2427860 * 1024
        value = self.accepted(self.bind())
        self.assertEqual(value['status'], 'error')
        self.assertTrue(all(r['available_bytes'] == 2427860 * 1024 for r in value['roles']))
        self.assertTrue(all(r['status'] == 'error' for r in value['roles']))

    def test_volume_quota_is_independent_of_spacious_container(self):
        self.document['Containers'][0]['Volumes'][1]['CapacityQuota'] = 31 * GIB
        value = self.accepted(self.bind())
        self.assertEqual(value['status'], 'error')
        roles = {r['role']: r for r in value['roles']}
        self.assertEqual(roles['home']['status'], 'ok')
        self.assertEqual(roles['build_root']['available_bytes'], GIB)
        self.assertEqual(roles['build_root']['apfs']['available_bytes'], 100 * GIB)

    def test_exhausted_quota_reports_zero_not_negative_or_unlimited(self):
        self.document['Containers'][0]['Volumes'][1]['CapacityQuota'] = 29 * GIB
        value = self.accepted(self.bind())
        self.assertEqual(next(r['available_bytes'] for r in value['roles'] if r['role'] == 'temp'), 0)

    def test_smaller_statvfs_availability_is_preserved(self):
        self.rows[1]['available_bytes'] = 2 * GIB
        value = self.accepted(self.bind())
        home = next(r for r in value['roles'] if r['role'] == 'home')
        self.assertEqual(home['available_bytes'], 2 * GIB)
        self.assertEqual(home['status'], 'error')

    def test_container_percentage_cannot_be_hidden_by_volume_percentage(self):
        self.document['Containers'][0].update(CapacityCeiling=1000 * GIB, CapacityFree=30 * GIB)
        value = self.accepted(self.bind())
        self.assertEqual(value['status'], 'error')
        self.assertTrue(all(r['usage_percent'] == 97 for r in value['roles']))

    def test_reserve_is_evidence_not_additional_free_space(self):
        self.document['Containers'][0]['Volumes'][1]['CapacityReserve'] = 60 * GIB
        rows = self.bind()
        self.assertTrue(all(r['available_bytes'] == 100 * GIB for r in rows))
        self.assertEqual(next(r['apfs']['reserve_bytes'] for r in rows if r['role'] == 'temp'), 60 * GIB)

    def test_missing_selected_volume_or_container_refuses(self):
        for key, value in [('DeviceIdentifier', 'disk3s99'), ('APFSContainerReference', 'disk9')]:
            with self.subTest(key=key):
                saved = copy.deepcopy(self.infos)
                self.infos['20'][key] = value
                with self.assertRaises(ValueError):
                    self.bind()
                self.infos = saved

    def test_volume_in_wrong_container_refuses(self):
        other = copy.deepcopy(self.document['Containers'][0])
        other.update(ContainerReference='disk9', APFSContainerUUID='99999999-2222-4333-8444-555555555555', Volumes=[])
        self.document['Containers'].append(other)
        self.infos['20']['APFSContainerReference'] = 'disk9'
        with self.assertRaises(ValueError):
            self.bind()

    def test_duplicate_container_reference_uuid_or_volume_refuses(self):
        original = copy.deepcopy(self.document)
        for duplicate in ('reference', 'uuid', 'volume'):
            with self.subTest(duplicate=duplicate):
                self.document = copy.deepcopy(original)
                other = copy.deepcopy(self.document['Containers'][0])
                if duplicate != 'reference':
                    other['ContainerReference'] = 'disk8'
                if duplicate != 'uuid':
                    other['APFSContainerUUID'] = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
                if duplicate != 'volume':
                    other['Volumes'] = []
                self.document['Containers'].append(other)
                with self.assertRaises(ValueError):
                    self.bind()

    def test_invalid_capacity_counts_fail_closed(self):
        for field in ('CapacityCeiling', 'CapacityFree'):
            for value in (True, -1, 2.5, '100', 9007199254740992):
                with self.subTest(field=field, value=value):
                    saved = self.document['Containers'][0][field]
                    self.document['Containers'][0][field] = value
                    with self.assertRaises(ValueError):
                        self.bind()
                    self.document['Containers'][0][field] = saved
        self.document['Containers'][0]['CapacityCeiling'] = 0
        with self.assertRaises(ValueError):
            self.bind()

    def test_missing_quota_metadata_is_not_an_unlimited_quota(self):
        self.document['Containers'][0]['Volumes'][1].pop('CapacityQuota')
        with self.assertRaises(KeyError):
            self.bind()

    def test_duplicate_plist_keys_refuse(self):
        data = b'<?xml version="1.0"?><plist version="1.0"><dict><key>Containers</key><array/>' \
               b'<key>Containers</key><array/></dict></plist>'
        with self.assertRaises(ValueError):
            self.probe['apfs_inventory'](data)

    def test_malformed_or_missing_inventory_refuses(self):
        for data in (b'', b'not a plist', plistlib.dumps({}), plistlib.dumps([])):
            with self.subTest(data=data[:30]), self.assertRaises((ValueError, plistlib.InvalidFileException)):
                self.probe['apfs_inventory'](data)

    def test_parent_verifier_rejects_conflicting_pool_or_inflated_capacity(self):
        for mutation in ('group', 'container', 'available', 'percent'):
            with self.subTest(mutation=mutation):
                rows = self.bind()
                if mutation == 'group':
                    rows[0]['capacity_group'] = 'filesystem:10'
                elif mutation == 'container':
                    rows[0]['apfs']['total_bytes'] += GIB
                elif mutation == 'available':
                    rows[0]['available_bytes'] += GIB
                else:
                    rows[0]['usage_percent'] = 0
                result = self.verdict(rows)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_parent_verifier_refuses_partial_role_inventory(self):
        result = self.verdict(self.bind()[:-1])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_non_apfs_filesystem_capacity_is_unchanged(self):
        rows = self.probe['bind_apfs'](self.rows, {'10': dict(FilesystemType='hfs')}, ({}, {}))
        for old, new in zip(self.rows, rows):
            self.assertEqual({k: new[k] for k in old}, old)
            self.assertNotIn('apfs', new)
        self.assertEqual(len(self.accepted(rows)['capacity_groups']), 2)

    @unittest.skipUnless(os.environ.get('DSR_TEST_APFS_BASELINE'), 'set DSR_TEST_APFS_BASELINE for actual prior policy')
    def test_incumbent_has_no_quota_or_container_admission(self):
        # Execute the unchanged prior pure jq verdict, extracted verbatim from
        # its containing transport function; no OS probe is mocked. Both arms
        # see the same explicit statvfs/volume/container observation fixture.
        old = Path(os.environ['DSR_TEST_APFS_BASELINE']).read_text()
        start = old.index('    if ! jq -ces --argjson minimum "$_HH_DISK_MIN_FREE_BYTES"')
        end = old.index("    ' <<< \"$result\"; then", start)
        expression = old[start + len('    if ! '):end] + "    '"
        run = subprocess.run([BASH, '-c',
            '_HH_DISK_MIN_FREE_BYTES=21474836480; _HH_DISK_WARN_THRESHOLD=90; '
            '_HH_DISK_ERROR_THRESHOLD=95; ' + expression], input=json.dumps(dict(roles=self.rows)),
            capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(run.stdout)['status'], 'ok')
        self.document['Containers'][0]['Volumes'][1]['CapacityQuota'] = 31 * GIB
        current = self.accepted(self.bind())
        self.assertEqual(current['status'], 'error')
        self.assertEqual(len(json.loads(run.stdout)['filesystems']), 2)
        self.assertEqual(len(current['capacity_groups']), 1)
        (self.work / 'incumbent.stdout').write_text(run.stdout)

    @unittest.skipUnless(sys.platform == 'darwin', 'native diskutil/APFS observation requires macOS')
    def test_native_macos_probe(self):
        row = self.probe['observe']('home', os.environ['HOME'])
        rows = self.probe['macos_capacities']([row])
        self.assertEqual(len(rows), 1)
        self.assertLessEqual(rows[0]['available_bytes'], row['available_bytes'])
        self.assertIn('capacity_group', rows[0])


unittest.main(verbosity=2)
PY
