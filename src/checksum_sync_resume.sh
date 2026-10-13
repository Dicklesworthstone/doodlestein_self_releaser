#!/usr/bin/env bash
# Continue an explicitly pinned audited fan-out, retaining every prior attempt.
# Completed commits use checksum_sync_recover; untouched destinations use a new
# audited sync. An uncertain target is never treated as permission to replay it.
set -uo pipefail
MODULE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 3
command -v python3 >/dev/null || { printf '%s\n' 'Python 3 is required for checksum fan-out recovery' >&2; exit 3; }
exec python3 -I -S - "$MODULE" "$@" <<'PY'
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time

module = Path(sys.argv[1])
started = time.monotonic()
output = None
lease = None
child = None
step = 0
pins = {}
absent = set()
report = dict(kind='dsr-checksum-sync-continuation', schema_version=1, status='error', exit_code=7,
              execute_requested=False, push_requested=False, delivery_confirmed=False,
              local_work_complete=False, original_terminal_outcome='unknown',
              results=[], remaining_targets=[], release_freshness='unconfirmed',
              authenticated=False, source_verified=False)

class Failure(Exception):
    def __init__(self, message, code=7):
        super().__init__(message)
        self.code = code

def need(condition, message, code=7):
    if not condition:
        raise Failure(message, code)

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()

def sha(data):
    return hashlib.sha256(data).hexdigest()

def digest(value, sizes=(64,)):
    return isinstance(value, str) and len(value) in sizes and re.fullmatch('[0-9a-f]+', value) is not None

def name(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,127}', value) and '..' not in value

def repository(value):
    return isinstance(value, str) and len(value) <= 256 and '..' not in value and re.fullmatch(
        r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*', value)

def member(value):
    return (isinstance(value, str) and 0 < len(value) <= 1024 and not value.startswith(('/', '-')) and
            not any(ord(c) < 32 or ord(c) == 127 or c in '\\:' for c in value) and
            all(p not in ('', '.', '..') and p.lower() != '.git' for p in value.split('/')))

def path_checked(value, directory=False, missing=False):
    need(isinstance(value, str) and value.startswith('/') and len(value) <= 4096 and
         not any(ord(c) < 32 or ord(c) == 127 for c in value), 'Canonical absolute path required', 4)
    path = Path(value)
    need(str(path) == value and '..' not in path.parts, 'Ambiguous continuation path', 4)
    for component in [*reversed(path.parents), path]:
        if component == path and missing:
            need(not os.path.lexists(component), 'Output already exists', 4)
        else:
            info = component.lstat()
            need(stat.S_ISDIR(info.st_mode) if component != path or directory else stat.S_ISREG(info.st_mode),
                 'Linked or nonregular continuation path', 4)
    return path

def read(path):
    path_checked(str(path))
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as source:
        before = os.fstat(source.fileno())
        need(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= 64 * 1024 * 1024,
             'Empty, nonregular or excessive evidence', 4)
        data = source.read(64 * 1024 * 1024 + 1)
        after = os.fstat(source.fileno())
    identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    need(len(data) == before.st_size and identity(before) == identity(after) == identity(path.lstat()),
         'Evidence changed while reading', 2)
    return data

def pairs(items):
    value = {}
    for key, item in items:
        need(key not in value, 'Duplicate JSON member', 4)
        value[key] = item
    return value

def document(data):
    try:
        return json.loads(data, object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(Failure('Nonfinite JSON', 4)))
    except (ValueError, UnicodeError) as error:
        raise Failure('Unreadable retained JSON evidence', 4) from error

def bind(path):
    data = read(path)
    pins[path] = sha(data)
    return document(data)

def unchanged():
    path_checked(str(workspace), directory=True)
    held, named = os.fstat(lease), (workspace / '.sync.lock').lstat()
    need(held.st_nlink == 1 and stat.S_ISREG(named.st_mode) and
         (held.st_dev, held.st_ino) == (named.st_dev, named.st_ino), 'Synchronization lease changed', 2)
    need(all(sha(read(path)) == pin for path, pin in pins.items()), 'Original plan or evidence changed', 2)
    need(all(not os.path.lexists(path) for path in absent), 'Unrecorded outcome appeared during recovery', 2)

def stop(signum, frame):
    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, signal.SIG_IGN)
    raise Failure('Checksum continuation interrupted; inspect retained intent and child plans', 5)

for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(sig, stop)

def run(command, phase, *, incoming=None, environment=None, timeout=None):
    global step, child
    step += 1
    prefix = output / ('%03d-%s' % (step, phase))
    env = {k:v for k,v in os.environ.items() if not k.startswith('BASH_FUNC_') and k not in ('BASH_ENV', 'ENV')}
    if environment:
        env.update(environment)
    with prefix.with_suffix('.stdout').open('xb') as out, prefix.with_suffix('.stderr').open('xb') as err:
        child = subprocess.Popen([str(x) for x in command], stdin=subprocess.PIPE if incoming is not None else subprocess.DEVNULL,
            stdout=out, stderr=err, env=env, start_new_session=True, pass_fds=(lease,))
        try:
            child.communicate(input=incoming, timeout=args.timeout if timeout is None else timeout)
            code = child.returncode
        except subprocess.TimeoutExpired as error:
            raise Failure('Continuation operation exceeded its timeout: ' + phase, 8) from error
        finally:
            # The public sync/auditor supervisors forward TERM to their own
            # children. Give them time to retain failures and reap transports.
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=6)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            child = None
    raw = prefix.with_suffix('.stdout').read_bytes()
    need(len(raw) <= 64 * 1024 * 1024, 'Excessive child response', 7)
    return code, raw

def persist(root, filename, value):
    code, _ = run(['bash', '-c', 'source "$1/checksum_sync.sh" || exit 3; _cs_retain_sync_json "$2" "$3"',
                   '_', module, root, filename], 'persist-' + filename, incoming=canonical(value))
    need(code == 0, 'Could not retain ' + filename + '; no automatic replay is permitted', 7)
    return sha(read(root / filename))

def local_audit():
    unchanged()
    program = r'''
source "$1/checksum_sync.sh" || exit 3
shift
_cs_admit_release_audit "$@" || exit 7
cmp -s "$2/checksums.normalized" "$8" || exit 7
jq -Rse --slurpfile audit "$1" '(split("\n")|map(select(length>0)|.[66:]))==$audit[0].verified_checksums' "$8" >/dev/null || exit 7
checksum_verify "$8" "$2/artifacts" || exit 7
'''
    code, _ = run(['bash', '-c', program, '_', module, workspace/'audit-result.json', workspace/'audit',
                   plan['repository'], plan['tag'], str(metadata).lower(), mode, aggregate or '', workspace/'manifest'], 'audit-bytes')
    need(code == 0, 'Retained audit or payload bytes no longer match', 7)
    unchanged()

def fresh(phase):
    unchanged()
    dest = output / phase
    command = ['bash', module/'release_checksums.sh', '--repo', plan['repository'], '--tag', plan['tag'],
               '--release-id', str(audit['release']['id']), '--recheck-from', workspace/'audit',
               '--audit-sha256', plan['audit_sha256'], '--output-dir', dest, *plan['audit_options']]
    code, raw = run(command, phase)
    need(code == 0, 'Release freshness could not be confirmed', code if 0 < code <= 8 else 7)
    value = document(raw)
    need(read(dest/'result.json') == raw and isinstance(value, dict) and
         value.get('kind') == 'dsr-release-checksum-inventory-check' and value.get('status') == 'unchanged' and
         type(value.get('exit_code')) is int and value['exit_code'] == 0 and value.get('inventory_stable') is True and
         value.get('payloads_reverified') is False and value.get('authenticated') is False and value.get('source_verified') is False and
         value.get('audit_sha256') == plan['audit_sha256'] and value.get('selection_sha256') == audit['selection_sha256'] and
         value.get('repository') == plan['repository'] and value.get('tag') == plan['tag'] and
         value.get('release') == audit['release'] and value.get('expected_release_id') == audit['release']['id'] and
         value.get('audited_output_dir') == str(workspace/'audit') and value.get('output_dir') == str(dest) and
         value.get('checksum_mode') == mode and value.get('include_metadata') is metadata,
         'Freshness receipt differs from the selected audit', 7)
    unchanged()
    report['release_freshness'] = 'unchanged'

def recover(row, execute=False, final=False):
    unchanged()
    dest = output / (('final-' if final else 'apply-' if execute else 'check-') + str(row['index']))
    command = ['bash', module/'checksum_sync_recover.sh', '--result', output/'selection.json',
               '--result-sha256', selection_pin, '--target-repo', row['repo'], '--output-dir', dest,
               '--timeout', str(args.timeout), '--sync-lease-fd', str(lease)]
    if execute and args.push:
        command.append('--push')
    code, raw = run(command, 'recover-' + dest.name, timeout=args.timeout)
    value = document(raw)
    report['results'].append(dict(repo=row['repo'], phase='final' if final else 'execute' if execute else 'check',
                                  recovery=value, evidence_dir=str(dest)))
    need(code == 0 and isinstance(value, dict) and read(dest/'result.json') == raw and
         type(value.get('exit_code')) is int and value['exit_code'] == 0 and
         value.get('kind') == 'dsr-checksum-delivery-recovery' and value.get('selected_commit_verified') is True and
         value.get('repository') == row['repo'] and value.get('commit') == row['commit'] and
         value.get('result_sha256') == selection_pin and value.get('checkpoint_selection') is True and
         value.get('release_freshness', {}).get('inventory_stable') is True and
         value.get('status') in ('ready', 'already-applied', 'pushed', 'reconciled'),
         'Recorded destination could not be reconciled: ' + row['repo'], code if 0 < code <= 8 else 7)
    unchanged()
    return value

try:
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            raise Failure(message, 4)
    parser = Parser(description='Reconcile a pinned audited fan-out. --execute continues safe unfinished work; --push also authorizes delivery.',
                    allow_abbrev=False)
    parser.add_argument('--plan', required=True)
    parser.add_argument('--plan-sha256', required=True)
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--push', action='store_true')
    parser.add_argument('--timeout', type=int, default=120, help='Seconds per child operation, including a delegated sync')
    flags = [a.split('=', 1)[0] for a in sys.argv[2:] if a.startswith('--')]
    need(len(flags) == len(set(flags)), 'Duplicate continuation option', 4)
    args = parser.parse_args(sys.argv[2:])
    need(digest(args.plan_sha256) and 1 <= args.timeout <= 3600 and (not args.push or args.execute),
         'Invalid plan pin, timeout, or push without --execute', 4)
    report.update(execute_requested=args.execute, push_requested=args.push)
    plan_path = path_checked(args.plan)
    plan = bind(plan_path)
    need(pins[plan_path] == args.plan_sha256, 'Plan does not match its independently selected SHA256', 4)
    keys = {'kind','schema_version','workspace','tool','repository','tag','checksums_file','push','review','dry_run',
            'audit_sha256','manifest_sha256','audit_options','targets'}
    need(isinstance(plan, dict) and set(plan) == keys and plan['kind'] == 'dsr-checksum-sync-plan' and
         type(plan['schema_version']) is int and plan['schema_version'] == 1 and name(plan['tool']) and
         repository(plan['repository']) and isinstance(plan['tag'], str) and
         re.fullmatch(r'v?[0-9]+\.[0-9]+\.[0-9]+(?:[+-][A-Za-z0-9.+-]+)?', plan['tag']) and
         member(plan['checksums_file']) and type(plan['push']) is bool and plan['review'] is False and
         plan['dry_run'] is False and digest(plan['audit_sha256']) and digest(plan['manifest_sha256']) and
         isinstance(plan['targets'], list) and 1 <= len(plan['targets']) <= 256 and
         all(repository(t) for t in plan['targets']) and len({t.lower() for t in plan['targets']}) == len(plan['targets']),
         'Unsupported or ambiguous sync plan; reviews and dry runs cannot authorize delivery', 4)
    need(not args.execute or args.push == plan['push'], 'Execution must preserve the original explicit push policy', 4)
    options = plan['audit_options']
    need(isinstance(options, list) and len(options) <= 11 and all(isinstance(o, str) for o in options),
         'Invalid retained audit options', 4)
    allowed = {'--checksum-mode','--checksum-asset','--timeout','--max-asset-bytes','--max-total-bytes','--include-metadata'}
    selected = {}
    cursor = 0
    while cursor < len(options):
        flag = options[cursor]
        need(flag in allowed and flag not in selected, 'Unrecognized or duplicate retained audit option', 4)
        cursor += 1
        if flag == '--include-metadata':
            selected[flag] = True
        else:
            need(cursor < len(options), 'Missing retained audit option value', 4)
            selected[flag] = options[cursor]; cursor += 1
            if flag in ('--timeout','--max-asset-bytes','--max-total-bytes'):
                need(re.fullmatch('[1-9][0-9]{0,15}', selected[flag]) and
                     int(selected[flag]) <= (3600 if flag == '--timeout' else 9007199254740991), 'Invalid audit limit', 4)
    mode, aggregate, metadata = selected.get('--checksum-mode', 'aggregate'), selected.get('--checksum-asset'), selected.get('--include-metadata', False)
    need(mode in ('aggregate','sidecars') and (aggregate is None or isinstance(aggregate,str) and 0 < len(aggregate) <= 255 and
         not aggregate.startswith('-') and not any(ord(c)<32 or ord(c)==127 or c in '/\\:' for c in aggregate)) and
         (mode != 'sidecars' or aggregate is None), 'Unsupported checksum policy', 4)
    workspace = path_checked(plan['workspace'], directory=True)
    need(plan_path == workspace/'sync-plan.json', 'Plan is not at its original workspace path', 4)
    destination = path_checked(args.output_dir, missing=True)
    need(destination != workspace and workspace not in destination.parents and destination not in workspace.parents,
         'Continuation output overlaps original evidence', 4)
    for protected in (Path('/data/projects'), Path.home()/'projects'):
        for prefix in (protected, protected.resolve()):
            need(all(p != prefix and prefix not in p.parents for p in (workspace,destination)), 'Protected project path', 4)
    lock_path = path_checked(str(workspace/'.sync.lock'))
    lease = os.open(lock_path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
    info = os.fstat(lease)
    need(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.geteuid() and not info.st_mode & 0o077,
         'Unsafe synchronization lease', 4)
    try:
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        raise Failure('An active sync or continuation owns this plan', 2) from error
    unchanged()
    audit = bind(workspace/'audit/result.json')
    need(pins[workspace/'audit/result.json'] == plan['audit_sha256'] and
         bind(workspace/'audit-result.json') == audit and pins[workspace/'audit-result.json'] == plan['audit_sha256'],
         'Plan audit pin differs from retained receipts', 4)
    audit_selection = bind(workspace/'audit/selection.json')
    need(isinstance(audit,dict) and audit.get('status')=='verified' and audit.get('exit_code')==0 and
         audit.get('repository')==plan['repository'] and audit.get('tag')==plan['tag'] and
         audit.get('selection_sha256')==pins[workspace/'audit/selection.json'] and
         isinstance(audit_selection,dict) and audit_selection.get('checksum_mode')==mode and
         audit_selection.get('checksum_asset')==aggregate and audit_selection.get('include_metadata') is metadata and
         audit.get('normalized_manifest_sha256')==plan['manifest_sha256'], 'Plan differs from admitted checksum evidence', 4)
    for path in (workspace/'manifest',workspace/'audit/checksums.normalized'):
        pins[path] = sha(read(path))
        need(pins[path]==plan['manifest_sha256'], 'Checksum export changed', 4)
    rows, known, pending, uncertain = [], [], [], []
    found_gap = found_failure = False
    for index, target in enumerate(plan['targets'],1):
        intent_path, row_path = workspace/f'target-{index}.intent.json', workspace/f'target-{index}.result.json'
        if not os.path.lexists(intent_path):
            need(not os.path.lexists(row_path) and not any(p.name==f'target-{index}' or p.name.startswith(f'target-{index}.')
                 for p in workspace.iterdir()), 'Destination has evidence but no acknowledged intent', 4)
            absent.update((intent_path,row_path)); pending.append(target)
            found_gap = True
            continue
        need(not found_gap and not found_failure, 'Target records violate the original ordered stop-on-failure plan', 4)
        intent = bind(intent_path)
        need(intent==dict(kind='dsr-checksum-sync-target-intent',schema_version=1,plan_sha256=args.plan_sha256,index=index,repo=target),
             'Target intent differs from pinned plan', 4)
        if not os.path.lexists(row_path):
            absent.add(row_path); uncertain.append(target); continue
        row = bind(row_path)
        need(isinstance(row,dict) and row.get('repo')==target and row.get('plan_sha256')==args.plan_sha256 and
             type(row.get('index')) is int and row['index']==index and type(row.get('exit_code')) is int and
             0 <= row['exit_code'] <= 255 and row.get('status')==('success' if row['exit_code']==0 else 'error'),
             'Target result differs from pinned intent', 4)
        rows.append(row)
        found_failure = row['exit_code'] != 0
        acknowledged = row.get('committed') is True and row.get('commit_attempted') is True and row.get('commit_outcome')=='acknowledged' and type(row.get('commit_exit_code')) is int and row['commit_exit_code']==0
        unmodified = row.get('changed') is False and row.get('committed') is False and row.get('commit_attempted') is False and row.get('commit_outcome')=='not-attempted' and row.get('commit_exit_code') is None and row.get('commit')==row.get('previous_commit')
        if row.get('action')=='update' and (acknowledged or unmodified):
            need(row.get('checksums_file')==plan['checksums_file'] and row.get('checkout')==str(workspace/f'target-{index}') and
                 digest(row.get('commit'),(40,64)) and digest(row.get('previous_commit'),(40,64)), 'Invalid retained checkout identity', 4)
            known.append(row)
        elif (set(row)=={'repo','action','status','exit_code','checkout','blocked_phase','plan_sha256','index'} and
              row.get('action')=='blocked' and row['exit_code']!=0 and row.get('blocked_phase')=='before-target' and row.get('checkout') is None):
            pending.append(target)
        else:
            # A failed clone/commit can leave valuable or ambiguous state. Do
            # not create another checkout merely because its status is red.
            uncertain.append(target)
    terminal_pin = None
    terminal = workspace/'result.json'
    if os.path.lexists(terminal):
        value = bind(terminal); terminal_pin = pins[terminal]
        need(isinstance(value,dict) and value.get('kind')=='dsr-checksum-sync-result' and value.get('schema_version')==1 and
             value.get('workspace')==str(workspace) and value.get('sync_plan')==dict(path=str(plan_path),sha256=args.plan_sha256) and
             value.get('repository')==plan['repository'] and value.get('version')==plan['tag'] and value.get('dry_run') is False and
             value.get('release_verification_sha256')==plan['audit_sha256'] and value.get('release_verification')==audit and
             value.get('source',{}).get('manifest_sha256')==plan['manifest_sha256'] and value.get('results')==rows and
             type(value.get('exit_code')) is int and value.get('status') in ('success','partial','error') and
             (value['status']=='success')==(value['exit_code']==0), 'Terminal result contradicts retained checkpoints', 4)
        report['original_terminal_outcome'] = value['status']
    else:
        absent.add(terminal)
    report.update(plan_file=str(plan_path),plan_sha256=args.plan_sha256,workspace=str(workspace),
                  remaining_targets=pending,uncertain_targets=uncertain)
    need(not uncertain, 'Unacknowledged destination outcomes require manual reconciliation: '+', '.join(uncertain), 2)
    delegated = workspace/'continuation.json'
    if os.path.lexists(delegated):
        continuation = bind(delegated)
        need(isinstance(continuation,dict) and continuation.get('kind')=='dsr-checksum-sync-delegation' and
             continuation.get('schema_version')==1 and continuation.get('plan_sha256')==args.plan_sha256 and
             continuation.get('targets')==pending and continuation.get('push') is plan['push'] and
             isinstance(continuation.get('output_dir'),str), 'Invalid existing continuation intent', 4)
        report['continuation'] = continuation
        raise Failure('Remaining destinations were already delegated; inspect that attempt and use its child sync plan', 2)
    absent.add(delegated)
    os.umask(0o077); destination.mkdir(mode=0o700); output=destination
    report['output_dir']=str(output)
    selection = dict(kind='dsr-checksum-sync-checkpoint-selection',schema_version=1,status='checkpointed',exit_code=None,
        dry_run=False,workspace=str(workspace),repository=plan['repository'],version=plan['tag'],
        source=dict(kind='verified_release_assets',manifest_sha256=plan['manifest_sha256']),
        release_verification=audit,release_verification_sha256=plan['audit_sha256'],
        checkpoint_plan_sha256=args.plan_sha256,checkpoint_terminal_sha256=terminal_pin,results=known)
    # This handoff is explicitly labelled nonterminal. The recovery engine
    # independently binds every included row back to its original intent/bytes.
    with (output/'selection.json').open('xb') as out:
        out.write(canonical(selection))
    selection_pin=sha(read(output/'selection.json'))
    local_audit()
    fresh('freshness-before')
    observations=[recover(row) for row in known]
    if args.execute:
        for row, observed in zip(known,observations):
            if args.push and not observed['delivery_confirmed']:
                observed.update(recover(row,execute=True))
        if pending:
            fresh('freshness-pre-delegation'); unchanged()
            temporary=output/'pending'; temporary.mkdir(mode=0o700)
            continuation=dict(kind='dsr-checksum-sync-delegation',schema_version=1,plan_sha256=args.plan_sha256,
                              targets=pending,output_dir=str(output),temporary_root=str(temporary),push=plan['push'])
            # Claim the remaining work exactly once BEFORE launching anything.
            # A killed parent leaves this claim, not permission to replay it.
            persist(workspace,'continuation.json',continuation)
            absent.remove(delegated); pins[delegated]=sha(read(delegated))
            report['continuation']=continuation
            command=['bash',module/'checksum_sync.sh','sync',plan['tool'],plan['tag'],'--repo',plan['repository'],
                     '--verify-release','--audit-resume-from',workspace/'audit','--checksums-file',plan['checksums_file'],'--json']
            for token in options:
                command.append({'--timeout':'--audit-timeout','--max-asset-bytes':'--audit-max-asset-bytes',
                                '--max-total-bytes':'--audit-max-total-bytes'}.get(token,token))
            for target in pending:
                command += ['--target-repo',target]
            if args.push:
                command.append('--push')
            code,raw=run(command,'remaining-sync',environment={'TMPDIR':str(temporary)})
            value=document(raw)
            need(isinstance(value,dict) and value.get('kind')=='dsr-checksum-sync-result' and
                 type(value.get('exit_code')) is int and value['exit_code']==code and
                 isinstance(value.get('workspace'),str), 'Delegated sync did not return a consistent outcome', 7)
            child_root=path_checked(value['workspace'],directory=True)
            need(child_root.parent==temporary and child_root.name.startswith('dsr-checksum-sync.') and
                 read(child_root/'result.json')==raw, 'Delegated result is not retained in the new workspace', 7)
            report['delegated_result']=value
            report['delegated_result_sha256']=sha(raw)
            need(value.get('repository')==plan['repository'] and value.get('version')==plan['tag'] and
                 value.get('source',{}).get('manifest_sha256')==plan['manifest_sha256'] and
                 value.get('release_verification',{}).get('release')==audit['release'],
                 'Delegated sync differs from the original release selection', 7)
            need(code==0 and value.get('status')=='success' and value.get('release_freshness',{}).get('inventory_stable') is True and
                 [r.get('repo') for r in value.get('results',[])]==pending and
                 all(r.get('exit_code')==0 and (not args.push or r.get('pushed') is True) for r in value['results']),
                 'Delegated sync is incomplete; recover its retained child plan, not the original plan', code if 0 < code <= 8 else 7)
            # Confirm each new destination through the same existing engine,
            # not just a child's successful push response. Its separate sync
            # lease is now free; an orphaned writer makes recovery refuse it.
            for index, row in enumerate(value['results'],1):
                dest=output/('child-final-'+str(index))
                recovery_code,recovery_raw=run(['bash',module/'checksum_sync_recover.sh',
                    '--result',child_root/'result.json','--result-sha256',sha(raw),
                    '--target-repo',row['repo'],'--output-dir',dest,'--timeout',str(args.timeout)],
                    'child-confirm-'+str(index))
                recovered=document(recovery_raw)
                report['results'].append(dict(repo=row['repo'],phase='child-final',recovery=recovered,evidence_dir=str(dest)))
                need(recovery_code==0 and read(dest/'result.json')==recovery_raw and
                     isinstance(recovered,dict) and recovered.get('kind')=='dsr-checksum-delivery-recovery' and
                     recovered.get('repository')==row['repo'] and recovered.get('commit')==row['commit'] and
                     recovered.get('selected_commit_verified') is True and recovered.get('push_attempted') is False and
                     recovered.get('release_freshness',{}).get('inventory_stable') is True and
                     (not args.push or recovered.get('delivery_confirmed') is True),
                     'Delegated destination is no longer confirmed; inspect its retained commit', 7)
                unchanged()
            report['remaining_targets']=[]
        # A later destination may take time. Re-observe the original completed
        # branches as well; the first preflight is not a perpetual freshness
        # claim while the child sync is changing other repositories.
        observations=[recover(row,final=True) for row in known]
    fresh('freshness-after')
    complete=not report['remaining_targets'] and (not plan['push'] or all(o['delivery_confirmed'] for o in observations))
    report.update(status=('completed' if plan['push'] else 'completed-local') if complete else 'ready',exit_code=0,
                  local_work_complete=complete,delivery_confirmed=complete and plan['push'])
except (Failure,OSError,ValueError,TypeError,KeyError,IndexError) as error:
    report.update(status='error',exit_code=getattr(error,'code',7),error=str(error),delivery_confirmed=False,local_work_complete=False)
    report['release_freshness']='unconfirmed'
    print('[checksum-continuation] '+str(error),file=sys.stderr)
finally:
    report['duration_ms']=int((time.monotonic()-started)*1000)
    if output is not None:
        try:
            persist(output,'result.json',report)
        except (Failure,OSError,ValueError) as error:
            report.update(status='error',exit_code=7,delivery_confirmed=False,local_work_complete=False,
                          error='Could not retain continuation outcome; inspect delegation and child evidence: '+str(error))
        print('[checksum-continuation] Evidence retained: '+str(output),file=sys.stderr)
    if 'args' in globals() or sys.exc_info()[0] is not SystemExit:
        print(canonical(report).decode(),end='')
    if lease is not None:
        os.close(lease)
sys.exit(report['exit_code'])
PY
