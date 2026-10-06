#!/usr/bin/env bash
# Actual generated POSIX verifier, real Git archives and filesystem mutations.
# Git/grep observers delegate to the real tools and count process launches.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 bash sh git tar awk grep; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
module = Path(os.environ.get('DSR_TEST_ACT_RUNNER', str(root / 'src/act_runner.sh')))
os.umask(0o077)
work = Path(tempfile.mkdtemp(prefix='dsr-unix-snapshot-batch-'))
print('Retained fixtures: ' + str(work), flush=True)
repo, source = work / 'repo', work / 'source'
repo.mkdir(); source.mkdir()
checks = 0

def check(label, value):
    global checks
    if not value:
        raise AssertionError(label)
    checks += 1
    print('PASS ' + label, flush=True)

def git(*args):
    return subprocess.run(['git','-C',str(repo),*args],capture_output=True,check=True,timeout=60).stdout

def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()

for args in [('init','-q'),('config','user.name','DSR test'),('config','user.email','dsr@example.invalid')]:
    git(*args)
# The total path projection exceeds common per-argument limits. Git must read
# paths from stdin, not one shell argument per tracked file or a giant argv.
paths = []
for i in range(1200):
    relative = Path('data-%02d' % (i % 20)) / ('file-%04d-' % i + 'long-name-' * 18 + '.txt')
    paths.append(str(relative))
    file = repo / relative
    file.parent.mkdir(exist_ok=True)
    file.write_bytes(('source payload %d\n' % i).encode() * 10)
    file.chmod(0o755 if i % 11 == 0 else 0o644)
for name, data in [('empty',b''),('name [two] (x),+#=@~- file',b'literal path\n'),('-leading',b'not an option\n')]:
    (repo / name).write_bytes(data)
(repo / 'safe-link').symlink_to('empty')
git('add','.'); git('commit','-qm','source closure')
revision = git('rev-parse','HEAD').decode().strip()
git('update-index','--add','--cacheinfo','160000,'+revision+',module')
git('commit','-qm','empty gitlink')
archive = work / 'source.tar'
archive.write_bytes(git('archive','--format=tar','HEAD'))
subprocess.run(['tar','-xf',str(archive),'-C',str(source)],check=True,timeout=60)
manifest = work / 'source.manifest'
records = []
for line in git('ls-tree','-rz','--full-tree','HEAD').split(b'\0'):
    if not line: continue
    meta,name = line.split(b'\t')
    mode,kind,oid = meta.split()
    records.append(oid+b'\t'+mode+b'\t'+name+b'\n')
manifest.write_bytes(b''.join(records))
original_manifest = manifest.read_bytes()
expected_count = len(list(source.rglob('*')))
expected = digest(archive) + ' ' + digest(manifest) + '\n'

# Generate the real remote shell program; no copy of verifier implementation.
def generate(pin=None, count=None):
    return subprocess.run(['bash','-c','source "$1"; _act_unix_strict_snapshot_verify_script "$2" "$3" "$4" "$5" "$6"',
        '_',str(module),str(source),str(archive),str(manifest),pin or digest(manifest),str(expected_count if count is None else count)],
        check=True,capture_output=True,timeout=30).stdout

script = work / 'verify.sh'
script.write_bytes(generate())
observer = work / 'observer'; observer.mkdir()
log = work / 'calls.log'
for tool in ('git','grep'):
    actual = shutil.which(tool)
    file = observer / tool
    file.write_text('#!/bin/sh\nprintf "%s\\n" '+tool+' >> "$DSR_PROCESS_LOG"\n'+
        ('exec '+actual+' "$@"\n' if tool == 'grep' else
         actual+' "$@"\nrc=$?\n'
         'case "${DSR_GIT_MUTATION:-}" in\n'
         '  failure) exit 23;;\n'
         '  mode) chmod +x "$DSR_MUTATE_PATH";;\n'
         '  link) mv "$DSR_MUTATE_PATH" "$DSR_MUTATE_HELD"; ln -s "$DSR_MUTATE_HELD" "$DSR_MUTATE_PATH";;\n'
         'esac\nexit "$rc"\n'))
    file.chmod(0o755)
env = dict(os.environ,PATH=str(observer)+os.pathsep+os.environ['PATH'],DSR_PROCESS_LOG=str(log))

def invoke(label, success=True, shell='sh', overrides=None):
    log.write_text('')
    started = time.monotonic()
    result = subprocess.run([shell,str(script)],capture_output=True,timeout=60,env=dict(env,**(overrides or {})))
    elapsed = time.monotonic()-started
    check(label, (result.returncode==0 and result.stdout.decode()==expected) if success else (result.returncode!=0 and not result.stdout))
    return log.read_text().splitlines(),elapsed

for shell in ('sh','bash'):
    subprocess.run([shell,'-n',str(script)],check=True)
    calls,elapsed = invoke(shell+' verifies exact snapshot',shell=shell)
    check(shell+' hashes regular files in one Git process plus the symlink probe',calls.count('git')==2)
    check(shell+' avoids per-regular-file grep',calls.count('grep')==1)
    print('Measured '+shell+' seconds: '+str(round(elapsed,4)),flush=True)
# Other available POSIX shells exercise the generated program, not Bash syntax.
for shell in ('dash','zsh'):
    if shutil.which(shell): invoke(shell+' verifies generated POSIX program',shell=shell)
check('stdin inventory exceeds 128 KiB',sum(len(p)+1 for p in paths)>131072)

file = source / paths[1]; original = file.read_bytes(); mode = file.stat().st_mode & 0o777
file.write_bytes(original+b'corrupt'); invoke('modified tracked bytes refuse',False); file.write_bytes(original)
file.chmod(0o755); invoke('unexpected executable mode refuses',False); file.chmod(mode)
executable = source / paths[0]
executable.chmod(0o644); invoke('missing executable mode refuses',False); executable.chmod(0o755)
held = work / 'held-file'
file.rename(held); file.symlink_to(held); invoke('linked regular file refuses',False)
file.rename(work / 'held-link'); held.rename(file)
parent = file.parent; parent_held = work / 'held-directory'
parent.rename(parent_held); parent.symlink_to(parent_held,target_is_directory=True)
invoke('linked parent refuses',False); parent.rename(work / 'held-directory-link'); parent_held.rename(parent)
file.rename(held); invoke('missing tracked file refuses',False); held.rename(file)
extra = source / 'unexpected'
extra.write_bytes(b'extra'); invoke('extra regular file refuses',False); extra.rename(work / 'held-extra')
(source / 'module/extra').write_bytes(b'extra'); invoke('populated gitlink refuses',False)
(source / 'module/extra').rename(work / 'held-module-extra')
link = source / 'safe-link'; link.rename(work / 'held-safe-link')
link.symlink_to('../outside'); invoke('escaping symlink refuses',False)
link.rename(work / 'held-escaping-link'); (work / 'held-safe-link').rename(link)
# Preserve the symlink's committed bytes but substitute a second link at its
# target: containment and non-chaining must reject it before reading outside.
empty = source / 'empty'; empty.rename(work / 'held-empty'); empty.symlink_to('../held-empty')
invoke('chained symlink refuses',False); empty.rename(work / 'held-chained-link'); (work / 'held-empty').rename(empty)
file.rename(held); os.mkfifo(file); invoke('special tracked object refuses without opening it',False)
file.rename(work / 'held-fifo'); held.rename(file)

# Disable mutation on the earlier symlink Git probe so the change happens
# after the actual regular-file batch has produced every expected hash.
git_observer = observer / 'git'
observed = git_observer.read_text()
git_observer.write_text(observed.replace('case "${DSR_GIT_MUTATION:-}" in',
    'case " $* " in *" --stdin-paths "*) mutation=${DSR_GIT_MUTATION:-};; *) mutation=;; esac\ncase "$mutation" in'))
invoke('Git failure after output is not accepted as a valid batch',False,overrides={'DSR_GIT_MUTATION':'failure'})
file.chmod(0o644)
invoke('post-hash executable-mode change refuses',False,overrides={'DSR_GIT_MUTATION':'mode','DSR_MUTATE_PATH':str(file)})
file.chmod(mode)
invoke('post-hash symlink substitution refuses',False,overrides={'DSR_GIT_MUTATION':'link','DSR_MUTATE_PATH':str(file),'DSR_MUTATE_HELD':str(held)})
file.rename(work / 'held-post-hash-link'); held.rename(file)

manifest.write_bytes(original_manifest+b'corrupt\n'); invoke('manifest digest mismatch refuses',False)
manifest.write_bytes(original_manifest)
archive_bytes = archive.read_bytes(); archive.write_bytes(archive_bytes+b'corrupt')
# A remote verifier returns the archive hash; coordinator comparison to its
# independently computed expected hash must reject a changed retained tar.
result = subprocess.run(['sh',str(script)],capture_output=True,env=env,timeout=60)
check('changed archive cannot return the expected source identity',result.returncode!=0 or result.stdout.decode()!=expected)
archive.write_bytes(archive_bytes)
# Authenticate malformed test manifests themselves to exercise field admission,
# not merely an early digest mismatch. No producer could emit these records.
for label,body in [
    ('empty',b''),('duplicate-path',original_manifest+records[0]),
    ('bad-object-id',records[0].replace(records[0][:40],b'g'*40)),
    ('bad-mode',b'0'*40+b'\t000644\tempty\n'),
    ('parent-traversal',b'0'*40+b'\t100644\t../outside\n'),
    ('absolute-path',b'0'*40+b'\t100644\t/etc/passwd\n'),
    ('extra-field',records[0].rstrip(b'\n')+b'\tfield\n')]:
    manifest.write_bytes(body); script.write_bytes(generate())
    invoke('malformed '+label+' manifest refuses',False)
manifest.write_bytes(original_manifest)
# A final unterminated regular record must still undergo type/mode admission.
parts=original_manifest.splitlines(True)
last=next(row for row in parts if row.endswith(b'\tempty\n'))
manifest.write_bytes(b''.join(row for row in parts if row!=last)+last.rstrip(b'\n'))
script.write_bytes(generate()); expected = digest(archive)+' '+digest(manifest)+'\n'
invoke('unterminated final regular record is fully verified')
empty.chmod(0o755); invoke('unterminated final record cannot bypass mode checks',False); empty.chmod(0o644)
manifest.write_bytes(original_manifest); script.write_bytes(generate()); expected=digest(archive)+' '+digest(manifest)+'\n'
invoke('restored snapshot is still accepted')
print(f'Unix snapshot batch: {checks} assertions passed; real Git/filesystem, no SSH transport.',flush=True)
PY
