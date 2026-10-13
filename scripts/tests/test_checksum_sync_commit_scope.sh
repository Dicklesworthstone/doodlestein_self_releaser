#!/usr/bin/env bash
# Real Git commits, hooks and local remotes. No HTTP, auth or Git substitutions.
# Every fixture and the complete stdout/stderr remain available for inspection.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
exec python3 -I -S - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
module = Path(os.environ.get('DSR_TEST_SYNC_MODULE', root / 'src/checksum_sync.sh')).resolve()
work = Path(tempfile.mkdtemp(prefix='dsr-commit-scope-')).resolve()
print('Commit-scope evidence retained:', work, flush=True)
actual_git = shutil.which('git')
checks = failures = serial = 0
manifest = hashlib.sha256(b'owned release payload').hexdigest() + '  app.tar.gz\n'


def check(label, condition):
    global checks, failures
    checks += 1
    failures += not condition
    print(('ok ' if condition else 'not ok ') + str(checks) + ' - ' + label, flush=True)


def git(env, *args):
    result = subprocess.run([actual_git, *map(str, args)], env=env, capture_output=True, timeout=15)
    if result.returncode:
        raise AssertionError(result.stderr.decode(errors='replace'))
    return result.stdout.decode().strip()


def setup(label, hook=None, member='SHA256SUMS.txt', initial=False):
    global serial
    serial += 1
    case = work / ('%02d-' % serial + label)
    case.mkdir()
    (case / 'home').mkdir()
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('GIT_', 'BASH_FUNC_')) and k not in ('BASH_ENV', 'ENV')}
    env.update(HOME=str(case / 'home'), GIT_CONFIG_NOSYSTEM='1',
               GIT_CONFIG_GLOBAL=str(case / 'gitconfig'), SCOPE_MEMBER=member,
               NO_COLOR='1')
    (case / 'gitconfig').write_text('[user]\n name = Scope Test\n email = scope@example.invalid\n'
                                  '[commit]\n gpgsign = false\n')
    checkout = case / 'checkout'
    git(env, 'init', '-b', 'main', checkout)
    (checkout / 'README').write_text('Unrelated tracked content\n')
    if initial:
        target = checkout / member
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(manifest)
    git(env, '-C', checkout, 'add', '.')
    git(env, '-C', checkout, 'commit', '-m', 'initial')
    before = git(env, '-C', checkout, 'rev-parse', 'HEAD')
    remote = case / 'remote.git'
    git(env, 'clone', '--bare', checkout, remote)
    git(env, '-C', checkout, 'remote', 'add', 'origin', str(remote))
    if hook is not None:
        where, body = hook
        path = checkout / '.git/hooks' / where
        path.write_text('#!/usr/bin/env bash\nset -uo pipefail\n' + body + '\n')
        path.chmod(0o755)
    return case, env, checkout, remote, before


def invoke(case, env, checkout, member='SHA256SUMS.txt', guard=''):
    args = ['bash', '-c', r'''
source "$1" || exit $?
content=$2
checkout=$3
member=$4
shift 4
''' + guard + r'''
_cs_update_repo_checksums "$checkout" "$content" --commit --push --checksums-file "$member" "$@"
''', '_', str(module), manifest, str(checkout), member]
    if guard:
        args += ['--release-guard', 'change_before_commit']
    result = subprocess.run(args, env=env, capture_output=True, timeout=25)
    (case / 'stdout').write_bytes(result.stdout)
    (case / 'stderr').write_bytes(result.stderr)
    try:
        row = json.loads(result.stdout)
    except ValueError:
        row = {}
    (case / 'exit-status').write_text(str(result.returncode) + '\n')
    return result, row


case, env, checkout, remote, before = setup('ordinary')
p, row = invoke(case, env, checkout)
head = git(env, '-C', checkout, 'rev-parse', 'HEAD')
check('ordinary single-file checksum update is still committed and pushed',
      p.returncode == 0 and row.get('commit') == head and row.get('commit_outcome') == 'acknowledged' and
      git(env, '--git-dir', remote, 'rev-parse', 'main') == head and head != before)

# Git runs this hook against the actual temporary index used by --only. A
# formatter or another writer can add a second path even though DSR named one.
case, env, checkout, remote, before = setup('pre-commit-extra-path', ('pre-commit', '''
printf 'unselected local content\\n' > OTHER
git add -- OTHER
'''))
p, row = invoke(case, env, checkout)
head = git(env, '-C', checkout, 'rev-parse', 'HEAD')
paths = git(env, '-C', checkout, 'diff-tree', '--no-commit-id', '--name-only', '-r', before, head)
check('genuine pre-commit hook demonstrates --only can include another path',
      head != before and set(paths.splitlines()) == {'OTHER', 'SHA256SUMS.txt'})
check('commit containing an extra path is refused before any push',
      p.returncode == 2 and row.get('push_attempted') is False and
      git(env, '--git-dir', remote, 'rev-parse', 'main') == before)
check('scope refusal preserves the actual local commit and all working bytes',
      (checkout / 'OTHER').read_text() == 'unselected local content\n' and
      (checkout / 'SHA256SUMS.txt').read_text() == manifest and
      git(env, '-C', checkout, 'rev-parse', 'HEAD') == head)
check('successful Git exit alone does not authenticate a selected checksum commit',
      row.get('commit_exit_code') == 0 and row.get('commit_outcome') == 'uncertain' and
      row.get('commit') is None and row.get('failed_phase') == 'commit-scope')

# Nested commit changes HEAD before the original successful git commit returns.
# The recursion marker belongs only to this fixture's actual Git hook.
for label, body in (
    ('post-commit-extra-commit', "printf 'concurrent content\\n' > OTHER\ngit add -- OTHER\nSCOPE_NESTED=1 git commit --only -m concurrent -- OTHER"),
    ('post-commit-empty-commit', 'SCOPE_NESTED=1 git commit --allow-empty -m concurrent-empty')):
    case, env, checkout, remote, before = setup(label, ('post-commit', '''
[[ "${SCOPE_NESTED:-}" != 1 ]] || exit 0
''' + body))
    p, row = invoke(case, env, checkout)
    head = git(env, '-C', checkout, 'rev-parse', 'HEAD')
    check(label + ' really creates a second local commit before returning',
          git(env, '-C', checkout, 'rev-list', '--count', before + '..' + head) == '2')
    check(label + ' cannot replace the selected checksum commit with a moving HEAD',
          p.returncode == 2 and row.get('commit') is None and row.get('failed_phase') == 'commit-scope' and
          row.get('push_attempted') is False and git(env, '--git-dir', remote, 'rev-parse', 'main') == before)
    check(label + ' leaves both commits and the checksum payload available',
          git(env, '-C', checkout, 'rev-parse', 'HEAD') == head and
          (checkout / 'SHA256SUMS.txt').read_text() == manifest)

case, env, checkout, remote, before = setup('moved-before-commit')
guard = r'''
change_before_commit() {
    [[ "$1" == before-commit ]] || return 0
    printf 'concurrent content\n' > "$checkout/OTHER" || return 1
    git -C "$checkout" add -- OTHER || return 1
    git -C "$checkout" commit --only -m concurrent -- OTHER >&2
}
'''
p, row = invoke(case, env, checkout, guard=guard)
check('changed parent before commit is refused without creating another commit',
      p.returncode == 2 and row.get('failed_phase') == 'commit-preflight' and
      row.get('commit_attempted') is False and git(env, '-C', checkout, 'rev-list', '--count', before + '..HEAD') == '1' and
      git(env, '--git-dir', remote, 'rev-parse', 'main') == before)
check('pre-commit conflict retains the unrelated commit and staged checksum bytes',
      (checkout / 'OTHER').read_text() == 'concurrent content\n' and
      (checkout / 'SHA256SUMS.txt').read_text() == manifest)

case, env, checkout, remote, before = setup('unrelated-staged')
(checkout / 'OTHER').write_text('local staged content\n')
git(env, '-C', checkout, 'add', 'OTHER')
p, row = invoke(case, env, checkout)
check('pre-existing unrelated staged work stays local, not part of the checksum commit',
      p.returncode == 0 and git(env, '-C', checkout, 'diff', '--cached', '--name-only') == 'OTHER' and
      git(env, '--git-dir', remote, 'ls-tree', '--name-only', 'main') == 'README\nSHA256SUMS.txt')

for member in ('nested dir/check "sums".txt', 'checksums-é.txt'):
    case, env, checkout, remote, before = setup('literal-name', member=member)
    p, row = invoke(case, env, checkout, member=member)
    check('NUL-delimited scope checking preserves the exact literal path ' + repr(member),
          p.returncode == 0 and row.get('checksums_file') == member and
          git(env, '--git-dir', remote, 'show', 'main:' + member) == manifest.rstrip('\n'))

case, env, checkout, remote, before = setup('unchanged', initial=True)
p, row = invoke(case, env, checkout)
check('unchanged explicit retry remains a no-new-commit operation',
      p.returncode == 0 and row.get('committed') is False and row.get('commit') == before and
      git(env, '--git-dir', remote, 'rev-parse', 'main') == before)

print('Commit scope: %d passed, %d failed' % (checks-failures, failures), flush=True)
raise SystemExit(1 if failures else 0)
PY
