#!/usr/bin/env bash
# Reconcile one acknowledged checksum commit against its actual remote branch.
# Consumes the original checksum_sync JSON with an independently selected digest.
# Never clones, commits, resets, creates a branch, retries a push, or opens issues.
set -uo pipefail
MODULE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 3
command -v python3 >/dev/null || { printf '%s\n' 'Python 3 is required for checksum delivery recovery' >&2; exit 3; }
exec python3 -I - "$MODULE" "$@" <<'PY'
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
worker = None
lock = None
step = 0
report = dict(kind='dsr-checksum-delivery-recovery', schema_version=1, status='error', exit_code=7,
              push_requested=False, push_attempted=False, push_outcome='not-attempted',
              push_exit_code=None, remote_state='unconfirmed', delivery_confirmed=False,
              release_freshness=dict(status='unconfirmed', inventory_stable=False),
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

def hex_digest(value, lengths=(64,)):
    return isinstance(value, str) and len(value) in lengths and re.fullmatch('[0-9a-f]+', value)

def repository(value):
    return isinstance(value, str) and len(value) <= 256 and '..' not in value and re.fullmatch(
        r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*', value)

def path_checked(value, directory=False, missing=False):
    need(isinstance(value, str) and value.startswith('/') and len(value) <= 4096 and
         not any(ord(c) < 32 or ord(c) == 127 for c in value), 'A canonical absolute path is required', 4)
    path = Path(value)
    need(str(path) == value and '..' not in path.parts, 'Ambiguous recovery path', 4)
    for component in [*reversed(path.parents), path]:
        if component == path and missing:
            need(not component.exists() and not component.is_symlink(), 'Recovery output already exists', 4)
            continue
        info = component.lstat()
        if component != path or directory:
            need(stat.S_ISDIR(info.st_mode), 'Recovery path has a linked or non-directory component', 4)
        else:
            need(stat.S_ISREG(info.st_mode), 'Recovery input is linked or nonregular', 4)
    return path

def stable_bytes(path, maximum=8 * 1024 * 1024):
    # A FIFO or symlink must not turn a read into a hang or a different input.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as incoming:
        before = os.fstat(incoming.fileno())
        need(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= maximum,
             'Nonregular or excessive recovery evidence', 4)
        data = incoming.read(maximum + 1)
        after = os.fstat(incoming.fileno())
    identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    need(len(data) == before.st_size and identity(before) == identity(after) == identity(path.lstat()),
         'Recovery evidence changed while reading', 2)
    return data

def pairs(items):
    result = {}
    for key, value in items:
        need(key not in result, 'Duplicate JSON member in recovery evidence', 4)
        result[key] = value
    return result

def document(data):
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(Failure('Nonfinite JSON value', 4)))

def stop(signum, frame):
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, signal.SIG_IGN)
    raise Failure('Checksum delivery recovery interrupted', 5)

for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, stop)

def run(argv, phase, maximum=8 * 1024 * 1024):
    global worker, step
    step += 1
    prefix = output / ('%03d-%s' % (step, phase))
    environment = {k:v for k,v in os.environ.items() if not k.startswith('BASH_FUNC_') and k not in ('BASH_ENV', 'ENV')}
    # Git configuration and credential helpers remain explicit operator policy.
    environment.update(GIT_TERMINAL_PROMPT='0', GIT_OPTIONAL_LOCKS='0', GIT_NO_LAZY_FETCH='1')
    with prefix.with_suffix('.stdout').open('xb') as out, prefix.with_suffix('.stderr').open('xb') as err:
        worker = subprocess.Popen([str(x) for x in argv], stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                  env=environment, start_new_session=True)
        try:
            code = worker.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired as error:
            raise Failure('Recovery operation timed out: ' + phase, 8) from error
        finally:
            try:
                # The auditor owns a separately grouped download. Allow its
                # TERM handler to reap that transport before escalation.
                os.killpg(worker.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                worker.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(worker.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            worker.wait()
            worker = None
    data = stable_bytes(prefix.with_suffix('.stdout'), maximum)
    return code, data

def bash(program, argv, phase):
    return run(['bash', '-c', 'source "$1/checksum_sync.sh" || exit 3; shift; ' + program,
                '_', module, *argv], phase)

def git(argv, phase, accepted=(0,)):
    code, data = bash('_cs_git "$@"', argv, phase)
    need(code in accepted, 'Git operation failed: ' + phase, 8)
    return code, data

def local_evidence(payloads=False):
    held = os.fstat(lock)
    named = lock_path.lstat()
    need(held.st_nlink == 1 and (held.st_dev, held.st_ino) == (named.st_dev, named.st_ino),
         'Recovery lock was replaced; stop instead of using an unlinked lease', 2)
    need(sha(stable_bytes(result_path, 64 * 1024 * 1024)) == args.result_sha256,
         'Original sync result changed', 2)
    path_checked(str(workspace), directory=True)
    for name in ('audit-result.json', 'audit/result.json'):
        path = path_checked(str(workspace / name))
        need(sha(stable_bytes(path, 64 * 1024 * 1024)) == audit_pin, 'Original audit receipt changed', 2)
    for name in ('manifest', 'audit/checksums.normalized'):
        path = path_checked(str(workspace / name))
        need(sha(stable_bytes(path)) == manifest_pin, 'Original checksum export changed', 2)
    program = '_cs_admit_release_audit "$@" || exit 7'
    if payloads:
        program += '; cmp -s "$2/checksums.normalized" "$8" || exit 7; checksum_verify "$8" "$2/artifacts"'
    code, _ = bash(program, [workspace / 'audit-result.json', workspace / 'audit', origin_repo,
                             tag, str(metadata).lower(), mode, aggregate or '', workspace / 'manifest'], 'local-evidence')
    need(code == 0, 'Retained audit no longer proves complete checksum coverage')

def local_commit():
    path_checked(str(checkout), directory=True)
    path_checked(str(checkout / '.git'), directory=True)
    _, top = git(['-C', checkout, 'rev-parse', '--show-toplevel'], 'checkout-root')
    need(top.decode().rstrip('\n') == str(checkout), 'Checkout is not the selected standalone repository', 2)
    _, head = git(['-C', checkout, 'rev-parse', '--verify', 'HEAD'], 'head')
    _, ref = git(['-C', checkout, 'symbolic-ref', '-q', 'HEAD'], 'branch')
    need(head.decode().strip() == commit and ref.decode().strip() == branch,
         'Retained checkout HEAD or branch changed; do not reset it', 2)
    for options in (['diff', '--quiet', '--no-ext-diff', '--no-textconv', 'HEAD', '--'],
                    ['diff', '--cached', '--quiet', '--no-ext-diff', '--no-textconv', '--']):
        code, _ = git(['-C', checkout, *options], 'tracked-state', accepted=(0, 1))
        need(code == 0, 'Retained checkout has tracked edits; no recovery write attempted', 2)
    _, parents = git(['-C', checkout, 'rev-list', '--parents', '-n', '1', commit], 'commit-parent')
    need(parents.decode().strip().split() == [commit, previous], 'Acknowledged commit has unexpected ancestry', 2)
    _, changed = git(['-C', checkout, 'diff-tree', '--no-commit-id', '--name-only', '--no-renames', '-z',
                      '-r', previous, commit, '--'], 'commit-paths')
    need(changed == member.encode() + b'\0', 'Recovery commit changes more than its checksum file', 2)
    _, tree = git(['-C', checkout, 'ls-tree', '-z', commit, '--', member], 'checksum-mode')
    need(re.fullmatch(rb'100644 blob [0-9a-f]{40}(?:[0-9a-f]{24})?\t' + re.escape(member.encode()) + b'\x00', tree),
         'Checksum commit does not contain a regular checksum blob', 2)
    _, blob = git(['-C', checkout, 'cat-file', 'blob', commit + ':' + member], 'checksum-blob')
    need(sha(blob) == manifest_pin and blob == stable_bytes(path_checked(str(checkout / member))),
         'Committed or working checksum content differs from the audited export', 2)
    _, raw_url = git(['-C', checkout, 'config', '--get-all', 'remote.origin.url'], 'origin-url')
    need(raw_url.decode().splitlines() == ['https://github.com/' + target_repo + '.git'],
         'Retained origin is not the selected downstream repository', 2)
    code, push_urls = git(['-C', checkout, 'config', '--get-all', 'remote.origin.pushurl'],
                         'origin-pushurl', accepted=(0, 1))
    need(code == 1 and not push_urls, 'An independent push URL is not admitted for recovery', 2)
    _, resolved = git(['-C', checkout, 'remote', 'get-url', '--push', '--all', 'origin'], 'effective-origin')
    urls = resolved.decode().splitlines()
    need(len(urls) == 1 and re.match(r'^(https://|ssh://|git@|file:///|/)', urls[0]) and
         not any(ord(c) < 32 or ord(c) == 127 for c in urls[0]), 'Ambiguous or unsupported effective origin', 2)
    # Existing operator URL rewrites (including local test remotes) are preserved.
    # Never expose a resolved URL, possibly containing credentials, in public JSON.
    return urls[0]

def remote_tip():
    _, raw = git(['-C', checkout, 'ls-remote', '--refs', '--exit-code', endpoint, branch], 'remote-branch')
    lines = raw.decode().splitlines()
    need(len(lines) == 1, 'Remote branch is missing or ambiguous', 2)
    fields = lines[0].split('\t')
    need(len(fields) == 2 and fields[1] == branch and hex_digest(fields[0], (40, 64)),
         'Invalid remote branch observation', 2)
    tip = fields[0]
    report['observed_remote_commit'] = tip
    report['remote_state'] = 'selected' if tip == commit else 'previous' if tip == previous else 'conflict'
    need(tip in (commit, previous), 'Remote branch changed independently; no overwrite or ancestry guess', 2)
    return tip

def fresh(phase):
    local_evidence()
    destination = output / phase
    command = ['bash', module / 'release_checksums.sh', '--repo', origin_repo, '--tag', tag,
               '--release-id', str(audit['release']['id']), '--recheck-from', str(workspace / 'audit'),
               '--audit-sha256', audit_pin, '--output-dir', str(destination), '--checksum-mode', mode,
               '--timeout', str(args.timeout)]
    if aggregate is not None:
        command += ['--checksum-asset', aggregate]
    if metadata:
        command += ['--include-metadata']
    code, raw = run(command, phase)
    need(code == 0, 'Release inventory freshness could not be confirmed', code if 0 < code <= 8 else 7)
    value = document(raw)
    need(isinstance(value, dict) and stable_bytes(destination / 'result.json') == raw and
         value.get('kind') == 'dsr-release-checksum-inventory-check' and value.get('status') == 'unchanged' and
         type(value.get('exit_code')) is int and value['exit_code'] == 0 and
         value.get('verification_policy') == 'unchanged-audited-release-inventory' and
         value.get('inventory_stable') is True and value.get('payloads_reverified') is False and
         value.get('authenticated') is False and value.get('source_verified') is False and
         value.get('audit_sha256') == audit_pin and value.get('audited_output_dir') == str(workspace / 'audit') and
         value.get('output_dir') == str(destination) and value.get('repository') == origin_repo and
         value.get('tag') == tag and value.get('release') == audit['release'] and
         value.get('expected_release_id') == audit['release']['id'] and
         value.get('selection_sha256') == audit['selection_sha256'] and
         value.get('checksum_mode') == mode and value.get('include_metadata') is metadata,
         'Freshness handoff does not match the pinned original audit')
    local_evidence()
    report['release_freshness'] = dict(status='unchanged', inventory_stable=True, evidence_dir=str(destination),
                                      payloads_reverified=False)

try:
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            raise Failure(message, 4)
    parser = Parser(description='Reconcile one acknowledged audited checksum commit. Read-only unless --push is supplied.',
                    allow_abbrev=False)
    parser.add_argument('--result', required=True, help='Original checksum_sync JSON file, not a previous recovery result')
    parser.add_argument('--result-sha256', required=True, help='Independently selected SHA256 of that exact result file')
    parser.add_argument('--target-repo', required=True)
    parser.add_argument('--output-dir', required=True, help='New, separate directory for recovery evidence')
    parser.add_argument('--push', action='store_true', help='Permit one push only when the remote still equals the original parent')
    parser.add_argument('--timeout', type=int, default=120)
    flags = [x.split('=', 1)[0] for x in sys.argv[2:] if x.startswith('--')]
    need(len(flags) == len(set(flags)), 'Duplicate recovery option', 4)
    args = parser.parse_args(sys.argv[2:])
    need(hex_digest(args.result_sha256) and repository(args.target_repo) and 1 <= args.timeout <= 3600,
         'Invalid recovery pin, repository, or timeout', 4)
    report['push_requested'] = args.push
    result_path = path_checked(args.result)
    raw_result = stable_bytes(result_path, 64 * 1024 * 1024)
    need(sha(raw_result) == args.result_sha256, 'Original sync result differs from the selected SHA256', 4)
    result = document(raw_result)
    need(isinstance(result, dict) and result.get('dry_run') is False and
         type(result.get('exit_code')) is int and result.get('status') in ('success', 'partial', 'error') and
         result.get('source', {}).get('kind') == 'verified_release_assets' and isinstance(result.get('results'), list),
         'Recovery needs an actual audited synchronization result', 4)
    workspace = path_checked(result.get('workspace'), directory=True)
    targets = result['results']
    need(all(isinstance(r, dict) and repository(r.get('repo')) for r in targets) and
         len({r['repo'].lower() for r in targets}) == len(targets), 'Ambiguous downstream target records', 4)
    selected = [r for r in targets if r['repo'].lower() == args.target_repo.lower()]
    need(len(selected) == 1, 'No unique recorded downstream target', 4)
    row = selected[0]
    target_repo = row['repo']
    need(row.get('action') == 'update' and row.get('committed') is True and
         row.get('commit_outcome') == 'acknowledged' and row.get('commit_attempted') is True and
         type(row.get('commit_exit_code')) is int and row['commit_exit_code'] == 0,
         'Recovery requires an acknowledged local checksum commit; uncertain commits and issues are not replayed', 4)
    commit, previous, branch, member = (row.get(k) for k in ('commit', 'previous_commit', 'branch', 'checksums_file'))
    need(hex_digest(commit, (40, 64)) and hex_digest(previous, (40, 64)) and commit != previous and
         isinstance(branch, str) and branch.startswith('refs/heads/') and
         isinstance(member, str) and 0 < len(member) <= 1024 and not member.startswith(('/', '-')) and
         not any(ord(c) < 32 or ord(c) == 127 or c in '\\:' for c in member) and
         all(p not in ('', '.', '..') and p.lower() != '.git' for p in member.split('/')),
         'Invalid recorded commit, branch, or checksum path', 4)
    checkout = path_checked(row.get('checkout'), directory=True)
    need(checkout.parent == workspace and re.fullmatch(r'target-[1-9][0-9]*', checkout.name),
         'Recorded checkout is outside the original synchronization workspace', 4)
    audit_pin, manifest_pin = result.get('release_verification_sha256'), result['source'].get('manifest_sha256')
    origin_repo, tag = result.get('repository'), result.get('version')
    audit = result.get('release_verification')
    need(hex_digest(audit_pin) and hex_digest(manifest_pin) and repository(origin_repo) and isinstance(tag, str) and
         isinstance(audit, dict), 'Original result lacks pinned release evidence', 4)
    audit_root = path_checked(str(workspace / 'audit'), directory=True)
    raw_audit = stable_bytes(path_checked(str(audit_root / 'result.json')), 64 * 1024 * 1024)
    need(sha(raw_audit) == audit_pin and document(raw_audit) == audit and
         audit.get('normalized_manifest_sha256') == manifest_pin, 'Original audit binding is inconsistent', 4)
    selection = document(stable_bytes(path_checked(str(audit_root / 'selection.json')), 64 * 1024 * 1024))
    need(isinstance(selection, dict) and sha(stable_bytes(audit_root / 'selection.json', 64 * 1024 * 1024)) ==
         audit.get('selection_sha256'), 'Original audit selection binding is inconsistent', 4)
    mode, aggregate, metadata = (selection.get(k) for k in ('checksum_mode', 'checksum_asset', 'include_metadata'))
    need(mode in ('aggregate', 'sidecars') and type(metadata) is bool and (aggregate is None or isinstance(aggregate, str)),
         'Invalid retained checksum policy', 4)
    destination = path_checked(args.output_dir, missing=True)
    need(destination != workspace and workspace not in destination.parents and destination not in workspace.parents and
         destination not in result_path.parents, 'Recovery output overlaps original evidence', 4)
    for protected in (Path('/data/projects'), Path.home() / 'projects'):
        for prefix in (protected, protected.resolve()):
            need(all(p != prefix and prefix not in p.parents for p in (workspace, destination)),
                 'Recovery cannot modify a protected project directory', 4)
    os.umask(0o077)
    destination.mkdir(mode=0o700)
    output = destination
    report.update(output_dir=str(output), result_file=str(result_path), result_sha256=args.result_sha256,
                  repository=target_repo, source_repository=origin_repo, tag=tag, commit=commit,
                  previous_commit=previous, branch=branch, checksums_file=member, checkout=str(checkout),
                  historical_push_outcome=row.get('push_outcome'), selected_commit_verified=False)
    (output / 'input-result.json').write_bytes(raw_result)
    lock_path = workspace / ('.recovery-' + checkout.name + '.lock')
    lock = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    info = os.fstat(lock)
    need(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.geteuid() and
         not info.st_mode & 0o077, 'Unsafe recovery lock', 4)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        raise Failure('Another recovery owns this retained checkout', 2) from error
    git(['check-ref-format', branch], 'branch-format')
    local_evidence(payloads=True)
    endpoint = local_commit()
    report['selected_commit_verified'] = True
    fresh('freshness-before')
    need(local_commit() == endpoint, 'Effective origin changed before recovery', 2)
    observed = remote_tip()
    if observed == previous and args.push:
        # A repeated explicit recovery gets another intent, never overwrites a
        # prior attempt, and first checks whether the previous push arrived.
        (output / 'push-intent.json').write_bytes(canonical(dict(result_sha256=args.result_sha256,
            repository=target_repo, branch=branch, commit=commit, expected_remote_commit=previous)))
        fresh('freshness-pre-push')
        need(local_commit() == endpoint, 'Effective origin changed before push', 2)
        need(remote_tip() == previous, 'Remote branch changed before push; reconcile in a new invocation', 2)
        report.update(push_attempted=True, push_outcome='uncertain')
        code, _ = bash('_cs_git "$@"', ['-C', checkout, 'push', '--porcelain', '--no-follow-tags', '--no-mirror',
                                        endpoint, commit + ':' + branch], 'push')
        report.update(push_exit_code=code, push_outcome='acknowledged' if code == 0 else 'uncertain')
        observed = remote_tip()
        need(observed == commit, 'Push did not yield a confirmed selected remote commit; inspect retained evidence', 8)
    fresh('freshness-after')
    need(local_commit() == endpoint, 'Retained checkout or origin changed during recovery', 2)
    final_tip = remote_tip()
    need(final_tip == observed, 'Remote branch changed during recovery', 2)
    confirmed = final_tip == commit
    status = ('reconciled' if report['push_outcome'] == 'uncertain' else
              'pushed' if report['push_attempted'] else 'already-applied') if confirmed else 'ready'
    report.update(status=status, exit_code=0, delivery_confirmed=confirmed)
except (Failure, OSError, ValueError, TypeError, KeyError, IndexError) as error:
    report.update(status='error', exit_code=getattr(error, 'code', 7), error=str(error), delivery_confirmed=False)
    report['release_freshness']['inventory_stable'] = False
    report['release_freshness']['status'] = 'unconfirmed'
    print('[checksum-recovery] ' + str(error), file=sys.stderr)
finally:
    if lock is not None:
        os.close(lock)
    report['duration_ms'] = int((time.monotonic() - started) * 1000)
    if output is not None:
        try:
            # No overwrite. A terminated writer may leave incomplete JSON,
            # never authority for another recovery: the original pin is required.
            with (output / 'result.json').open('xb') as stream:
                stream.write(canonical(report))
        except OSError:
            report.update(status='error', exit_code=7, delivery_confirmed=False,
                          error='Could not persist recovery result; inspect push intent and logs')
        print('[checksum-recovery] Evidence retained: ' + str(output), file=sys.stderr)
    if 'args' in globals() or sys.exc_info()[0] is not SystemExit:
        print(canonical(report).decode(), end='')
sys.exit(report['exit_code'])
PY
