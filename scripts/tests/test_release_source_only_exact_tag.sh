#!/usr/bin/env bash
# Exact-tag admission/custody with real Git and the production CLI. Only the
# GitHub HTTP boundary is a fixture; this is not actual publication evidence.
# All fixture files are retained. Run the existing suites independently too.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
python3 -I - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

if not __debug__:
    raise SystemExit("Exact-tag proof predicates must remain enabled")

root = Path(sys.argv[1])
stock = root / "scripts/tests/test_release_source_only.sh"
stock_bytes = stock.read_bytes()
production_sha = hashlib.sha256((root / "dsr").read_bytes()).hexdigest()
# Reuse only the unchanged stock helper definitions, before its first test.
# No existing assertions are executed, rewritten, or suppressed by this file.
python_marker = 'python3 - "$ROOT" <<\'PY\'\n'
test_marker = "\nfor label,control in [('publish',{})"
assert stock_bytes.decode().count(python_marker) == 1
helper_text = stock_bytes.decode().split(python_marker, 1)[1]
assert helper_text.count(test_marker) == 1
helper_text = helper_text.split(test_marker, 1)[0]
exec(compile(helper_text, str(stock) + ":helper-definitions", "exec"))

EXACT_TAGS = ("fp-types-v0.4.0", "frankenpandas-v0.4.0")
EXPECTED_CHECKS = 132
seen_checks = set()
stock_assert_ok = assert_ok


def exact_check(label, value):
    if label in seen_checks:
        raise AssertionError("duplicate exact-tag predicate: " + label)
    seen_checks.add(label)
    stock_assert_ok(label, value)


api_source = r'''
import json
from pathlib import Path
import os
import subprocess
import sys

case = Path(os.environ['CASE'])
args = sys.argv[1:]
endpoint = args[0]
control = json.loads((case/'control.json').read_text())
with (case/'requests.jsonl').open('a') as stream:
    stream.write(json.dumps(args)+'\n')
release_file = case/'remote.json'
release = json.loads(release_file.read_text()) if release_file.exists() else None
if endpoint == 'repos/owner/app/releases' and '--post' in args:
    data = json.loads(args[args.index('--post')+1])
    data.update(id=9, assets=[], html_url='https://github.com/owner/app/releases/tag/'+data['tag_name'])
    release_file.write_text(json.dumps(data))
    print(json.dumps(data))
    raise SystemExit(1 if control.get('lost_post') else 0)
if endpoint.startswith('repos/owner/app/releases?'):
    if release is not None and control.get('omit_created'):
        print('[]')
    elif release is not None and control.get('delay_created', 0) > 0:
        control['delay_created'] -= 1
        (case/'control.json').write_text(json.dumps(control))
        print('[]')
    else:
        print(json.dumps([release] if release is not None else []))
elif endpoint.startswith('repos/owner/app/git/ref/tags/'):
    if control.get('remote_tag_wrong'):
        print(json.dumps({'object': {'type': 'commit', 'sha': 'f'*40}}))
    else:
        print(json.dumps({'object': {'type': 'tag', 'sha': 'a'*40}}))
elif endpoint == 'repos/owner/app/git/tags/'+'a'*40:
    print(json.dumps({'object': {'type': 'commit', 'sha': (case/'sha').read_text().strip()}}))
elif endpoint == 'repos/owner/app/releases/9' and '--method' in args:
    assert args[args.index('--method')+1] == 'PATCH'
    data = json.loads(args[args.index('--data')+1])
    release.update(data)
    if data.get('draft') is False:
        if control.get('move_tag_after_publish'):
            control['remote_tag_wrong'] = True
            (case/'control.json').write_text(json.dumps(control))
        if control.get('move_local_after_publish'):
            repo = case/'repo'
            (repo/'install.sh').write_text('committed source drift\n')
            subprocess.run(['git', '-C', str(repo), 'add', 'install.sh'], check=True)
            subprocess.run(['git', '-C', str(repo), 'commit', '-qm', 'source drift'], check=True)
        if control.get('body_changes_after_publish'):
            release['body'] = 'another worker changed the body'
    release_file.write_text(json.dumps(release))
    print(json.dumps(release))
    raise SystemExit(1 if control.get('lost_patch') else 0)
elif endpoint == 'repos/owner/app/releases/9':
    print(json.dumps(release))
elif endpoint.startswith('repos/owner/app/releases/9/assets?'):
    print('[]')
else:
    print('unexpected exact-tag API endpoint: '+endpoint, file=sys.stderr)
    raise SystemExit(89)
'''

stock_setup = setup


def setup_exact(label, controls=None):
    case, repo, config = stock_setup(label, controls)
    for tag in EXACT_TAGS:
        subprocess.run(['git', '-C', str(repo), 'tag', '-a', tag, '-m', 'exact-tag fixture'], check=True)
    return case, repo, config


def invoke_exact(case, tag=EXACT_TAGS[0], *, flags=None, dry=False, arguments=None):
    env = dict(os.environ, CASE=str(case), DSR_CONFIG_DIR=str(case),
               DSR_STATE_DIR=str(case/'state'), ROOT=str(root),
               FUNCTIONS=str(functions), NO_COLOR='1')
    script = r'''
set -uo pipefail
source "$ROOT/src/github.sh"
source "$ROOT/src/config.sh"
source "$ROOT/src/git_ops.sh"
source "$ROOT/src/act_runner.sh"
source "$FUNCTIONS"
log_error() { printf 'ERROR %s\n' "$*" >&2; }
log_info() { printf 'INFO %s\n' "$*" >&2; }
log_warn() { printf 'WARN %s\n' "$*" >&2; }
_dsr_require() { :; }
gh_check() { return 0; }
gh_check_token() { return 0; }
gh_api() { python3 -I "$CASE/api.py" "$@"; }
JSON_MODE=false
DRY_RUN="$1"
shift
cmd_release_source_only "$@"
'''
    tail = ['app', '--tag', tag] if arguments is None else arguments
    tail += ['--notes-file', str(case/'notes.md'), '--no-dispatch']
    proc = subprocess.run(['bash', '-c', script, 'exact-tag-fixture',
                           'true' if dry else 'false', *tail, *(flags or [])],
                          env=env, capture_output=True, text=True, timeout=60)
    with (case/'stdout.log').open('a') as stream:
        stream.write(proc.stdout)
    with (case/'stderr.log').open('a') as stream:
        stream.write(proc.stderr)
    requests = [json.loads(line) for line in (case/'requests.jsonl').read_text().splitlines()]
    return proc, requests


def records(case):
    return sorted((case/'state'/'source-only').glob('*.json.*'))


def remote_record(case):
    return json.loads((case/'remote.json').read_text())


def has_patch(requests, draft):
    return any('--method' in request and '--data' in request
               and json.loads(request[request.index('--data')+1]).get('draft') is draft
               for request in requests)


def post_count(requests):
    return sum('--post' in request for request in requests)


def exact_metadata(case, data, tag, prerelease=False):
    prefix = (case/'notes.md').read_text()+'\n\n<!-- dsr-source-only-create:'
    return (data['tag_name'] == tag and data['name'] == tag+' (source only)'
            and data['target_commitish'] == (case/'sha').read_text().strip()
            and data['prerelease'] is prerelease
            and data['body'].startswith(prefix)
            and re.fullmatch(r'[0-9a-f]{64} -->', data['body'][len(prefix):]) is not None)


def private_record(case, path, tag, status='success', prerelease=False):
    data = json.loads(path.read_text())
    remote = remote_record(case)
    return (path.name.startswith('app-'+tag+'.json.')
            and stat.S_IMODE(path.stat().st_mode) == 0o600
            and data['status'] == status and data['publication_mode'] == 'source-only'
            and data['repo'] == 'owner/app'
            and data['notes_sha256'] == hashlib.sha256((case/'notes.md').read_bytes()).hexdigest()
            and data['config_sha256'] == hashlib.sha256((case/'repos.d'/'app.yaml').read_bytes()).hexdigest()
            and exact_metadata(case, data['metadata'], tag, prerelease)
            and data['metadata'] == {key: remote[key] for key in data['metadata']}
            and (status != 'success' or (data['tag'] == tag
                 and data['git_sha'] == remote['target_commitish'] and data['asset_count'] == 0
                 and data['release_id'] == remote['id'] and data['draft'] is remote['draft'])))


for tag in EXACT_TAGS:
    label = 'publish-'+tag
    case, repo, _ = setup_exact(label)
    proc, requests = invoke_exact(case, tag)
    release = remote_record(case)
    receipt = records(case)
    exact_check(label+' terminal success', proc.returncode == 0)
    exact_check(label+' real annotated local and remote tag', subprocess.check_output(
        ['git', '-C', str(repo), 'cat-file', '-t', 'refs/tags/'+tag], text=True).strip() == 'tag'
                and any(request[0] == 'repos/owner/app/git/ref/tags/'+tag for request in requests)
                and any(request[0] == 'repos/owner/app/git/tags/'+'a'*40 for request in requests))
    exact_check(label+' exact tag title source notes', exact_metadata(case, release, tag) and release['draft'] is False)
    exact_check(label+' zero embedded and authoritative assets', release['assets'] == []
                and sum('/assets?' in request[0] for request in requests) >= 2)
    exact_check(label+' private exact-tag success receipt', len(receipt) == 1 and private_record(case, receipt[0], tag))
    exact_check(label+' no dispatch or upload endpoint', all(request[0].startswith('repos/owner/app/')
                and '/actions/' not in request[0] and '/dispatches' not in request[0]
                and 'uploads.' not in request[0] for request in requests))
    exact_check(label+' one create POST', post_count(requests) == 1)

# Actual main/global-option dispatch, with production module bytes preserved.
cli = work/'exact-cli'
(cli/'src').mkdir(parents=True)
shutil.copyfile(root/'dsr', cli/'dsr')
for module in (root/'src').glob('*.sh'):
    shutil.copyfile(module, cli/'src'/module.name)
with (cli/'src'/'github.sh').open('a') as stream:
    stream.write('\ngh_check() { return 0; }\ngh_check_token() { return 0; }\n'
                 'gh_api() { python3 -I "$CASE/api.py" "$@"; }\n')
for tag in EXACT_TAGS:
    label = 'real-cli-dry-'+tag
    case, _, _ = setup_exact(label)
    env = dict(os.environ, CASE=str(case), DSR_CONFIG_DIR=str(case),
               DSR_STATE_DIR=str(case/'state'), NO_COLOR='1')
    proc = subprocess.run(['bash', str(cli/'dsr'), '--json', '--dry-run', 'release',
                           'source-only', 'app', '--tag', tag, '--notes-file',
                           str(case/'notes.md'), '--no-dispatch'],
                          env=env, capture_output=True, text=True, timeout=60)
    (case/'cli.stdout').write_text(proc.stdout)
    (case/'cli.stderr').write_text(proc.stderr)
    exact_check(label+' terminal success', proc.returncode == 0)
    envelope = json.loads(proc.stdout)
    exact_check(label+' exact JSON metadata', envelope['status'] == 'success'
                and envelope['command'] == 'release source-only'
                and exact_metadata(case, envelope['details'], tag))
    requests = [json.loads(line) for line in (case/'requests.jsonl').read_text().splitlines()]
    exact_check(label+' no API mutation or receipt', not any('--post' in request or '--method' in request
                for request in requests) and not (case/'state'/'source-only').exists())
    exact_check(label+' real CLI bytes preserved', (cli/'dsr').read_bytes() == (root/'dsr').read_bytes())

for tag in EXACT_TAGS:
    label = 'draft-prerelease-'+tag
    case, _, _ = setup_exact(label)
    proc, requests = invoke_exact(case, tag, flags=['--draft', '--prerelease'])
    release = remote_record(case)
    exact_check(label+' exact requested draft/prerelease', proc.returncode == 0
                and release['draft'] is True and exact_metadata(case, release, tag, True))
    exact_check(label+' no publication PATCH', not any('--method' in request for request in requests))
    receipt = records(case)
    exact_check(label+' private zero-asset draft receipt', len(receipt) == 1
                and private_record(case, receipt[0], tag, prerelease=True)
                and json.loads(receipt[0].read_text())['asset_count'] == 0)

for tag in EXACT_TAGS:
    for fault, control in [('delayed', {'delay_created': 2}), ('lost-post', {'lost_post': True})]:
        label = fault+'-'+tag
        case, _, _ = setup_exact(label, control)
        proc, requests = invoke_exact(case, tag)
        exact_check(label+' terminal success', proc.returncode == 0)
        exact_check(label+' exactly one POST', post_count(requests) == 1)
        release = remote_record(case)
        exact_check(label+' same owned public empty release', release['id'] == 9
                    and release['draft'] is False and release['assets'] == []
                    and exact_metadata(case, release, tag))
        receipt = records(case)
        exact_check(label+' private tag binding', len(receipt) == 1 and private_record(case, receipt[0], tag))

for tag in EXACT_TAGS:
    label = 'resume-'+tag
    case, _, _ = setup_exact(label, {'omit_created': True})
    first, requests = invoke_exact(case, tag)
    pending = records(case)[0]
    before, inode = pending.read_bytes(), pending.stat().st_ino
    exact_check(label+' pending draft before resume', first.returncode == 7
                and remote_record(case)['draft'] is True and not has_patch(requests, False))
    exact_check(label+' private prefixed pending record', private_record(case, pending, tag, 'pending'))
    (case/'control.json').write_text('{}')
    proc, requests = invoke_exact(case, tag, flags=['--resume-receipt', str(pending)])
    exact_check(label+' terminal resume success', proc.returncode == 0)
    exact_check(label+' no second POST', post_count(requests) == 1)
    exact_check(label+' original file bytes and inode retained', pending.read_bytes() == before
                and pending.stat().st_ino == inode)
    release = remote_record(case)
    exact_check(label+' same exact owned release published', release['id'] == 9
                and release['draft'] is False and exact_metadata(case, release, tag))
    recovery = [path for path in records(case) if path != pending]
    exact_check(label+' separate receipt links original', len(recovery) == 1
                and private_record(case, recovery[0], tag)
                and json.loads(recovery[0].read_text())['resumed_from'] == str(pending)
                and json.loads(recovery[0].read_text())['resumed_receipt_sha256'] == hashlib.sha256(before).hexdigest())

for tag in EXACT_TAGS:
    other = next(value for value in EXACT_TAGS if value != tag)
    label = 'wrong-receipt-tag-'+tag
    case, _, _ = setup_exact(label, {'omit_created': True})
    first, _ = invoke_exact(case, tag)
    pending = records(case)[0]
    exact_check(label+' real pending setup', first.returncode == 7)
    saved = json.loads(pending.read_text())
    saved['metadata']['tag_name'] = other
    pending.write_text(json.dumps(saved))
    before = pending.read_bytes()
    (case/'control.json').write_text('{}')
    proc, requests = invoke_exact(case, tag, flags=['--resume-receipt', str(pending)])
    exact_check(label+' metadata mismatch refused', proc.returncode in (4, 7))
    exact_check(label+' no new POST or PATCH', post_count(requests) == 1
                and not any('--method' in request for request in requests))
    exact_check(label+' original invalid receipt retained', pending.read_bytes() == before)

    label = 'wrong-receipt-filename-'+tag
    case, _, _ = setup_exact(label, {'omit_created': True})
    first, _ = invoke_exact(case, tag)
    pending = records(case)[0]
    before = pending.read_bytes()
    exact_check(label+' real pending setup', first.returncode == 7)
    (case/'control.json').write_text('{}')
    proc, requests = invoke_exact(case, other, flags=['--resume-receipt', str(pending)])
    exact_check(label+' exact filename mismatch refused', proc.returncode == 4
                and post_count(requests) == 1 and not any('--method' in request for request in requests))
    exact_check(label+' original prefixed receipt retained', pending.read_bytes() == before)

for tag in EXACT_TAGS:
    for kind in ('remote', 'local'):
        label = 'initial-'+kind+'-drift-'+tag
        case, repo, _ = setup_exact(label, {'remote_tag_wrong': True} if kind == 'remote' else {})
        if kind == 'local':
            (repo/'install.sh').write_text('later committed source\n')
            subprocess.run(['git', '-C', str(repo), 'add', 'install.sh'], check=True)
            subprocess.run(['git', '-C', str(repo), 'commit', '-qm', 'later source'], check=True)
        proc, requests = invoke_exact(case, tag)
        exact_check(label+' identity refusal', proc.returncode == 4)
        exact_check(label+' no create or publication', not any('--post' in request or '--method' in request for request in requests))

    for kind, control in [('remote', {'move_tag_after_publish': True}),
                          ('local', {'move_local_after_publish': True}),
                          ('body', {'body_changes_after_publish': True})]:
        label = 'owned-'+kind+'-rollback-'+tag
        case, _, _ = setup_exact(label, control)
        proc, requests = invoke_exact(case, tag)
        exact_check(label+' post-publication drift refusal', proc.returncode == 7)
        exact_check(label+' original create/publication attempt proven', post_count(requests) == 1 and has_patch(requests, False))
        release = remote_record(case)
        exact_check(label+' only owned ID restored draft', release['id'] == 9
                    and release['tag_name'] == tag and release['draft'] is True
                    and has_patch(requests, True)
                    and len(records(case)) == 1 and json.loads(records(case)[0].read_text())['status'] == 'pending')

invalid_arguments = [
    ('both-version-first', ['app', '0.4.0', '--tag', EXACT_TAGS[0]]),
    ('both-tag-first', ['app', '--tag', EXACT_TAGS[0], '0.4.0']),
    ('duplicate-tag', ['app', '--tag', EXACT_TAGS[0], '--tag', EXACT_TAGS[1]]),
    ('missing-tag-value', ['app', '--tag']),
    ('option-as-tag-value', ['app', '--tag', '--draft']),
    ('empty-tag', ['app', '--tag', '']),
    ('slash-tag', ['app', '--tag', 'fp-types/v0.4.0']),
    ('space-tag', ['app', '--tag', 'fp-types v0.4.0']),
    ('newline-tag', ['app', '--tag', 'fp-types-v0.4.0\npeer']),
    ('leading-option-tag', ['app', '--tag', '-fp-types-v0.4.0']),
    ('traversal-tag', ['app', '--tag', '../fp-types-v0.4.0']),
    ('double-dot-ref', ['app', '--tag', 'fp-types..v0.4.0']),
    ('lock-ref', ['app', '--tag', 'fp-types-v0.4.0.lock']),
    ('missing-version-and-tag', ['app']),
    ('prefixed-positional-version', ['app', EXACT_TAGS[0]]),
    ('dispatch-with-exact-tag', ['app', '--tag', EXACT_TAGS[0], '--dispatch']),
]
for label, arguments in invalid_arguments:
    case, _, _ = setup_exact('invalid-'+label)
    proc, requests = invoke_exact(case, arguments=arguments.copy())
    exact_check('invalid-'+label+' argument refusal', proc.returncode == 4)
    exact_check('invalid-'+label+' no HTTP mutation', not any('--post' in request or '--method' in request for request in requests))

exact_check('original source-only fixture untouched', stock.read_bytes() == stock_bytes)
exact_check('production CLI source untouched', hashlib.sha256((root/'dsr').read_bytes()).hexdigest() == production_sha)
assert checks == len(seen_checks) == EXPECTED_CHECKS, (checks, len(seen_checks), EXPECTED_CHECKS)
print(json.dumps({'passed': True, 'checks': checks, 'expected_checks': EXPECTED_CHECKS,
                  'fixtures': str(work), 'production_sha256': production_sha,
                  'stock_fixture_sha256': hashlib.sha256(stock_bytes).hexdigest(),
                  'proof_boundary': 'Real Git/CLI with fixture GitHub HTTP; not actual public publication'}), flush=True)
PY
