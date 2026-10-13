#!/usr/bin/env bash
# Full checksum verification for the release CLI. The existing manifest/strict
# repair command remains the metadata authority; it is invoked without any
# checksum option. Never substitute a checksum audit for its release gates.

# Called by the release command registration in release_formulas.sh. Keep a
# supervisor PID in the CLI shell so TERM to dsr also stops its owned workers.
release_verify_cli() {
    local module="${BASH_SOURCE[0]}" worker='' signals=0 seen=0 rc=0
    local old_int old_term old_hup
    if ! command -v python3 >/dev/null; then
        log_error 'Python 3 is required for complete release checksum verification'
        if ${JSON_MODE:-false}; then
            json_envelope release-verify error 3 '{"error":"Python 3 is required","checksums":{"requested":true,"verified":[],"verified_count":0}}'
        fi
        return 3
    fi
    old_int=$(trap -p INT); old_term=$(trap -p TERM); old_hup=$(trap -p HUP)
    trap 'signals=$((signals+1)); [[ -z "$worker" ]] || kill -TERM "$worker" 2>/dev/null || true' INT TERM HUP
    bash "$module" "$SCRIPT_DIR/dsr" "${JSON_MODE:-false}" "${DRY_RUN:-false}" "$DSR_VERSION" "$@" &
    worker=$!
    if ((signals > 0)); then kill -TERM "$worker" 2>/dev/null || true; fi
    # An interrupted wait is not the worker's exit status. Wait again for its
    # final JSON/result; no child PID or trap escapes this invocation.
    while :; do
        seen=$signals
        rc=0; wait "$worker" || rc=$?
        ((signals == seen)) && break
    done
    worker=''
    trap - INT TERM HUP
    [[ -z "$old_int" ]] || eval "$old_int"
    [[ -z "$old_term" ]] || eval "$old_term"
    [[ -z "$old_hup" ]] || eval "$old_hup"
    return "$rc"
}

_release_verify_execute() {
    local module_dir
    module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || return 3
    exec python3 -I - "$module_dir" "$@" <<'PY'
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

module, cli = Path(sys.argv[1]), Path(sys.argv[2])
json_mode, dry_run, version = sys.argv[3] == 'true', sys.argv[4] == 'true', sys.argv[5]
started = time.monotonic()
result = dict(command='release-verify', status='error', exit_code=7, run_id=str(uuid.uuid4()),
              started_at=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
              duration_ms=0, tool='dsr', version=version, details={})
work = None
child = None
audit = None
audit_admitted = False
inventory_check = None
inventory_admitted = False
repair_started = False
repair_completed = False

class Failure(Exception):
    def __init__(self, message, code=7):
        super().__init__(message)
        self.code = code

def need(condition, message, code=7):
    if not condition:
        raise Failure(message, code)

def pairs(items):
    value = {}
    for key, item in items:
        need(key not in value, 'Duplicate JSON member in verification response')
        value[key] = item
    return value

def read_document(path):
    info = path.lstat()
    need(stat.S_ISREG(info.st_mode) and info.st_size <= 67108864, 'Invalid or excessive verification response')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        need(identity(os.fstat(stream.fileno())) == identity(info), 'Verification response replaced before reading')
        data = stream.read(67108865)
        need(len(data) == info.st_size and identity(os.fstat(stream.fileno())) == identity(info) == identity(path.lstat()),
             'Verification response changed while reading')
    return data

def read_json(path):
    return json.loads(read_document(path), object_pairs_hook=pairs,
        parse_constant=lambda _: (_ for _ in ()).throw(Failure('Non-finite verification response')))

def document_digest(path):
    return hashlib.sha256(read_document(path)).hexdigest()

def stop(signum, frame):
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)
    raise Failure('Release verification interrupted', 5)

for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, stop)

def run(command, phase):
    global child
    environment = {k:v for k,v in os.environ.items() if not k.startswith('BASH_FUNC_') and k not in ('BASH_ENV','ENV')}
    output, errors = work / (phase + '.json'), work / (phase + '.stderr')
    with output.open('xb') as out, errors.open('xb') as err:
        child = subprocess.Popen([str(x) for x in command], stdin=subprocess.DEVNULL, stdout=out,
                                 stderr=err, env=environment, start_new_session=True)
        try:
            code = child.wait()
        finally:
            # Kill the entire owned session, including a still-running helper
            # below an exited shell. Never signal a PID recovered from disk.
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            child = None
    return code if code >= 0 else 5, output

def metadata(phase, fix=False):
    command = ['bash', cli, '--json']
    if dry_run:
        command.append('--dry-run')
    command += ['release', 'verify', args.tool, args.version]
    if fix:
        command.append('--fix')
    code, path = run(command, phase)
    try:
        value = read_json(path)
    except (Failure, OSError, ValueError):
        raise Failure('Manifest verification returned no consistent JSON; see ' + str(path), code or 7)
    need(isinstance(value, dict) and value.get('command') == 'release-verify' and
         type(value.get('exit_code')) is int and value['exit_code'] == code and
         isinstance(value.get('details'), dict) and
         (code != 0 or value.get('status') == 'success'), 'Invalid manifest verification result')
    details = value['details']
    if 'release_id' not in details:
        raise Failure(str(details.get('error', 'Manifest verification did not identify a release')), code or 7)
    need(type(details['release_id']) is int and 0 < details['release_id'] <= 9007199254740991 and
         isinstance(details.get('repo'), str) and isinstance(details.get('tag'), str),
         'Manifest verification did not bind the release identity')
    return code, details

def identity(details):
    return details['repo'], details['tag'], details['release_id']

def audit_command(details, output, resume=True):
    command = ['bash', module / 'release_checksums.sh', '--repo', details['repo'], '--tag', details['tag'],
               '--release-id', str(details['release_id']), '--output-dir', str(output),
               '--checksum-mode', args.checksum_mode, '--timeout', str(args.checksum_timeout),
               '--max-asset-bytes', str(args.checksum_max_asset_bytes), '--max-total-bytes', str(args.checksum_max_total_bytes)]
    if args.checksum_asset is not None:
        command += ['--checksum-asset', args.checksum_asset]
    if args.checksum_include_metadata:
        command.append('--include-metadata')
    if resume and args.checksum_resume_from is not None:
        command += ['--resume-from', args.checksum_resume_from]
    return command

def admit_audit(path, output, details, phase):
    global audit_admitted
    audit_admitted = False
    # Reuse the downstream sync gate, including exact sidecar ownership and
    # retained proof hashing. Also recheck the exported manifest and every
    # downloaded payload before integrating it with the CLI's release report.
    code, _ = run(['bash', '-c', r'''
source "$1/checksum_sync.sh" || exit 3
normalized=$2
shift 2
_cs_admit_release_audit "$@" || exit 7
receipt=$1; root=$2
cmp -s "$receipt" "$root/result.json" || exit 7
expected=$(jq -er .normalized_manifest_sha256 "$receipt") || exit 7
[[ "$(_cs_sha256 "$root/checksums.normalized")" == "$expected" ]] || exit 7
(set -o noclobber; checksum_manifest_normalize "$root/checksums.normalized" > "$normalized") || exit 7
cmp -s "$root/checksums.normalized" "$normalized" || exit 7
jq -Rse --slurpfile audit "$receipt" '
    (split("\n")|map(select(length>0)|.[66:]))==$audit[0].verified_checksums
' "$root/checksums.normalized" >/dev/null || exit 7
checksum_verify "$root/checksums.normalized" "$root/artifacts" >/dev/null || exit 7
''', '_', module, work / (phase + '.normalized'), path, output, details['repo'], details['tag'],
        str(args.checksum_include_metadata).lower(), args.checksum_mode, args.checksum_asset or ''], phase)
    need(code == 0, 'Checksum audit handoff failed complete retained-evidence verification', code)
    need(audit.get('release', {}).get('id') == details['release_id'] and
         audit.get('expected_release_id') == details['release_id'], 'Checksum audit belongs to a different release ID')
    audit_admitted = True

def recheck_audit(path, output, details, pin):
    global inventory_check
    need(document_digest(path) == pin, 'Selected checksum audit changed before inventory recheck')
    destination = work / 'inventory-after'
    # Resume sources belong to the original download operation. This check
    # pins the newly completed audit, not an earlier interrupted attempt.
    command = audit_command(details, destination, resume=False)
    command += ['--recheck-from', output, '--audit-sha256', pin]
    code, response = run(command, 'inventory-check')
    inventory_check = read_json(response)
    need(isinstance(inventory_check, dict) and
         inventory_check.get('kind') == 'dsr-release-checksum-inventory-check' and
         type(inventory_check.get('exit_code')) is int and inventory_check['exit_code'] == code,
         'Invalid checksum inventory recheck result', code or 7)
    need(code == 0, str(inventory_check.get('error', 'Checksum inventory freshness could not be confirmed')), code)
    need(inventory_check.get('status') == 'unchanged' and inventory_check.get('inventory_stable') is True and
         inventory_check.get('verification_policy') == 'unchanged-audited-release-inventory' and
         inventory_check.get('payloads_reverified') is False and
         inventory_check.get('audit_sha256') == pin and
         inventory_check.get('selection_sha256') == audit.get('selection_sha256') and
         inventory_check.get('audited_output_dir') == output and inventory_check.get('output_dir') == str(destination) and
         inventory_check.get('repository') == details['repo'] and inventory_check.get('tag') == details['tag'] and
         inventory_check.get('expected_release_id') == details['release_id'] and
         inventory_check.get('release') == audit.get('release') and
         inventory_check.get('checksum_mode') == args.checksum_mode and
         inventory_check.get('include_metadata') is args.checksum_include_metadata,
         'Inventory recheck does not bind the selected checksum audit')
    need(document_digest(response) == document_digest(destination / 'result.json'),
         'Inventory recheck receipt was not retained consistently')
    need(document_digest(path) == pin, 'Selected checksum audit changed during inventory recheck')

def checksum_details():
    if not isinstance(audit, dict):
        return dict(requested=True, status='not-verified', eligible_count=0, verified_count=0,
                    verified=[], errors=[], coverage_errors=[], authenticated=False, source_verified=False)
    status = audit.get('status', 'error')
    if status == 'verified' and not audit_admitted:
        status = 'not-admitted'
    elif status == 'verified' and not inventory_admitted:
        status = 'stale-or-unconfirmed'
    details = dict(requested=True, status=status,
                policy=audit.get('verification_policy'), mode=audit.get('checksum_mode'),
                include_metadata=audit.get('include_metadata'), eligible_count=audit.get('eligible_count', 0),
                verified_count=audit.get('verified_count', 0), verified=audit.get('verified_checksums', []),
                eligible_assets=audit.get('eligible_assets', []), excluded_assets=audit.get('excluded_assets', []),
                inventory_stable=audit.get('inventory_stable', False) and inventory_admitted,
                audit_inventory_stable=audit.get('inventory_stable', False), inventory_check=inventory_check,
                release_id=audit.get('release', {}).get('id'),
                errors=[r.get('name', r.get('error', 'unverified')) for r in audit.get('checksum_errors', [])],
                coverage_errors=audit.get('coverage_errors', []), audit_exit_code=audit.get('exit_code'),
                authenticated=False, source_verified=False, evidence_dir=audit.get('output_dir'))
    if 'resume' in audit:
        details['resume'] = audit['resume']
    return details

try:
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            raise Failure(message, 4)
    parser = Parser(prog='dsr release verify', description='Check the existing manifest/strict release gates and every eligible payload checksum.',
        epilog='--fix retains the existing repair rules. --dry-run prevents repair writes, not requested checksum downloads. '
               'Checksums are integrity evidence, not publisher signatures. Audit evidence is retained.', allow_abbrev=False)
    parser.add_argument('selection', nargs='*', metavar='TOOL VERSION')
    parser.add_argument('--tool', '-t')
    parser.add_argument('--version', '-V')
    parser.add_argument('--verify-checksums', '--checksums', '-c', action='store_true', dest='verify_checksums')
    parser.add_argument('--fix', action='store_true')
    parser.add_argument('--checksum-mode', choices=('aggregate','sidecars'), default='aggregate')
    parser.add_argument('--checksum-asset')
    parser.add_argument('--checksum-include-metadata', action='store_true')
    parser.add_argument('--checksum-output-dir')
    parser.add_argument('--checksum-resume-from', help='Recheck verified payloads from a previous audit in a new output directory; cannot be combined with --fix')
    parser.add_argument('--checksum-timeout', type=int, default=120)
    parser.add_argument('--checksum-max-asset-bytes', type=int, default=2*1024**3)
    parser.add_argument('--checksum-max-total-bytes', type=int, default=8*1024**3)
    aliases = {'-t':'--tool','-V':'--version','-c':'--verify-checksums','--checksums':'--verify-checksums'}
    flags = [aliases.get(a.split('=',1)[0], a.split('=',1)[0]) for a in sys.argv[6:] if a.startswith('-')]
    need(len(flags) == len(set(flags)), 'Duplicate verification option', 4)
    args = parser.parse_intermixed_args(sys.argv[6:])
    for item in args.selection:
        if args.tool is None:
            args.tool = item
        elif args.version is None:
            args.version = item
        else:
            raise Failure('Unexpected positional argument', 4)
    need(args.verify_checksums, 'Checksum options require --verify-checksums (or --checksums)', 4)
    need(args.checksum_resume_from is None or not args.fix,
         'Checksum resume requires an unchanged release; perform --fix separately and start a fresh audit', 4)
    need(isinstance(args.tool, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,127}', args.tool) and '..' not in args.tool,
         'A safe tool name is required', 4)
    need(isinstance(args.version, str) and re.fullmatch(r'v?[0-9]+\.[0-9]+\.[0-9]+(?:[+-][A-Za-z0-9.+-]+)?', args.version),
         'An explicit version tag is required', 4)
    need(cli.is_absolute() and cli.is_file(), 'The original dsr CLI is unavailable', 3)
    for dependency in ('release_checksums.sh', 'checksum_sync.sh'):
        need((module / dependency).is_file(), 'Required checksum module is unavailable: ' + dependency, 3)
    if args.checksum_resume_from is not None:
        retained = Path(args.checksum_resume_from).resolve()
        temporary = Path(tempfile.gettempdir()).resolve()
        need(retained != temporary and retained not in temporary.parents,
             'Verification workspace must be outside retained audit evidence', 4)
    os.umask(0o077)
    work = Path(tempfile.mkdtemp(prefix='dsr-release-verify-')).resolve()
    base_code, details = metadata('manifest-before')
    result['details'] = details
    selected = identity(details)
    # Preserve spelling for the auditor's canonical-path check; Path() would
    # silently erase a caller-supplied dot component or trailing slash.
    audit_output = args.checksum_output_dir if args.checksum_output_dir is not None else str(work / 'audit')
    command = audit_command(details, audit_output)
    preflight_code, preflight_path = run([*command, '--preflight'], 'audit-preflight')
    preflight = read_json(preflight_path)
    need(preflight_code == 0 and preflight.get('status') == 'planned' and preflight.get('preflight') is True and
         preflight.get('exit_code') == 0 and preflight.get('expected_release_id') == selected[2],
         str(preflight.get('error', 'Checksum audit preflight failed; no repair attempted')), preflight_code or 7)
    if args.fix:
        repair_started = True
        base_code, details = metadata('manifest-repair', fix=True)
        repair_completed = True
        result['details'] = details
        need(identity(details) == selected, 'Release identity changed during repair')
    audit_code, audit_path = run(command, 'checksum-audit')
    audit_pin = document_digest(audit_path)
    audit = read_json(audit_path)
    need(document_digest(audit_path) == audit_pin, 'Checksum audit response changed during selection')
    need(isinstance(audit, dict) and audit.get('kind') == 'dsr-release-checksum-verification' and
         type(audit.get('exit_code')) is int and audit['exit_code'] == audit_code and
         audit.get('status') == ('verified' if audit_code == 0 else 'error'), 'Inconsistent checksum audit result')
    need(audit_code == 0, str(audit.get('error', 'Checksum coverage failed')), audit_code)
    admit_audit(audit_path, audit_output, details, 'handoff-before')
    need(document_digest(audit_path) == audit_pin, 'Checksum audit changed during initial admission')
    # The audit is not permission to relax a strict source/tag/ruleset gate.
    # Re-run the original read-only checks after downloads, never repeat --fix.
    final_code, final_details = metadata('manifest-after')
    need(identity(final_details) == selected, 'Release identity changed after checksum verification')
    actual = sorted(set(final_details.get('assets', {}).get('present', []) + final_details.get('assets', {}).get('extra', []) +
                        final_details.get('assets', {}).get('size_mismatches', []) + final_details.get('assets', {}).get('digest_mismatches', [])))
    audited = sorted(audit['eligible_assets'] + [r['name'] for r in audit['excluded_assets']])
    need(actual == audited, 'Manifest verification and checksum audit observed different asset inventories')
    # Names alone cannot bind the checksum observation: replacement assets
    # can keep their names while changing IDs, sizes, digests or release mode.
    recheck_audit(audit_path, audit_output, final_details, audit_pin)
    admit_audit(audit_path, audit_output, final_details, 'handoff-after')
    need(document_digest(audit_path) == audit_pin, 'Checksum audit changed during final admission')
    inventory_admitted = True
    repair = details.get('repair')
    result['details'] = final_details
    result['details']['repair'] = repair
    result.update(status='success' if base_code == final_code == 0 else 'incomplete', exit_code=base_code or final_code)
except (Failure, OSError, ValueError, TypeError, KeyError, IndexError) as error:
    code = getattr(error, 'code', 7)
    if code == 5 and audit is None and work is not None:
        # The audit supervisor gets a chance to retain its partial counts when
        # cancellation is forwarded. Never turn an unfinished child into a
        # successful audit, or trust a missing/malformed completion document.
        try:
            partial = read_json(work / 'checksum-audit.json')
            if (isinstance(partial, dict) and partial.get('kind') == 'dsr-release-checksum-verification' and
                    partial.get('status') == 'error' and partial.get('exit_code') == 5):
                audit = partial
        except (Failure, OSError, ValueError, TypeError):
            pass
    result.update(status='incomplete' if code == 1 else 'error', exit_code=code)
    result['details']['error'] = str(error)
    print('[release-verify] ' + str(error), file=sys.stderr)
finally:
    if child is not None:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()

result['details']['checksums'] = checksum_details()
result['details']['duration_seconds'] = int(time.monotonic() - started)
result['duration_ms'] = int((time.monotonic() - started)*1000)
if repair_started and not repair_completed:
    result['details']['repair'] = dict(requested=True, dry_run=dry_run, attempted=True, outcome='unknown')
if work is not None:
    result['details']['verification_evidence_dir'] = str(work)
    try:
        with (work / 'result.json').open('x') as out:
            json.dump(result, out, sort_keys=True); out.write('\n')
    except OSError:
        result.update(status='error', exit_code=7)
        result['details']['error'] = 'Could not retain verification result'
    print('[release-verify] Evidence retained: ' + str(work), file=sys.stderr)
if json_mode:
    print(json.dumps(result, sort_keys=True))
else:
    c = result['details']['checksums']
    print('[release-verify] Checksums: %d/%d eligible payloads; %s' %
          (c['verified_count'], c['eligible_count'], c['status']), file=sys.stderr)
    print('[release-verify] Verification: ' + ('PASSED' if result['exit_code']==0 else 'FAILED'), file=sys.stderr)
sys.exit(result['exit_code'])
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _release_verify_execute "$@"
fi
