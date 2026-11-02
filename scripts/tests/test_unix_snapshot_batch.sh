#!/usr/bin/env bash
# Actual generated POSIX verifier, real Git archives and filesystem mutations.
# Git/grep observers delegate to the real tools and count process launches.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
case "${1:-}" in
    ''|--project-submodules-only|--export-attributes-only) ;;
    *) printf 'Unknown snapshot test selection: %s\n' "$1" >&2; exit 4 ;;
esac
for tool in python3 bash sh git tar awk grep; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
if [[ -z "${1:-}" ]]; then
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
batch_status=$?
[[ "$batch_status" -eq 0 ]] || exit "$batch_status"
fi

# Tiny real repositories exercise the native writer, independent receivers,
# retained-source recovery and relocation inventory. Export attributes are
# archive filters, so they must not remove or rewrite committed build inputs.
if [[ "${1:-}" != --project-submodules-only ]]; then
for tool in jq yq rg; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
python3 - "$ROOT" <<'PY'
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

root = Path(sys.argv[1])
module = Path(os.environ.get('DSR_TEST_ACT_RUNNER', str(root / 'src/act_runner.sh')))
exporter = root / 'src/xwin_source.sh'
os.umask(0o077)
work = Path(tempfile.mkdtemp(prefix='dsr-unix-export-attributes-'))
print('Export-attribute fixtures: ' + str(work), flush=True)
environment = {key: value for key, value in os.environ.items() if not key.upper().startswith('GIT_')}
environment.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
    GIT_AUTHOR_NAME='DSR fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
    GIT_COMMITTER_NAME='DSR fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid',
    GIT_AUTHOR_DATE='2026-01-01T00:00:00Z', GIT_COMMITTER_DATE='2026-01-01T00:00:00Z',
    ACT_ARTIFACTS_DIR=str(work / 'artifacts'), DSR_STATE_DIR=str(work / 'state'),
    DSR_CONFIG_DIR=str(work / 'config'), DSR_REPOS_FILE=str(work / 'config/repos.yaml'),
    NO_COLOR='1', LC_ALL='C')
(work / 'state').mkdir()
(work / 'config/repos.d').mkdir(parents=True)
(work / 'config/repos.d/source-fixture.yaml').write_text(json.dumps({'sibling_crates': []}))
checks, cases = 0, {}

def check(label, condition):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print('PASS ' + label, flush=True)

def run(arguments, overrides=None, **kwargs):
    return subprocess.run(arguments, capture_output=True, timeout=30,
                          env=dict(environment, **(overrides or {})), **kwargs)

def git(repository, *arguments):
    return run(['git', '-C', str(repository), *arguments], check=True).stdout

def call(function, *arguments, overrides=None):
    return run(['bash', '-c', 'source "$1" || exit; shift; "$@"',
                'fixture', str(module), function, *map(str, arguments)], overrides=overrides)

def success(function, *arguments):
    result = call(function, *arguments)
    if result.returncode:
        raise AssertionError(function + ': ' + result.stderr.decode(errors='replace'))
    return result.stdout

def probe(repository, revision, overrides=None):
    return run(['bash', '-c', 'source "$1" || exit; source_archive_matches_git "$2" "$3"',
                'fixture', str(exporter), str(repository), revision], overrides=overrides)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def unpack(archive, destination):
    destination.mkdir()
    run(['tar', '-xf', str(archive), '-C', str(destination)], check=True)

ram_backed = call('_act_dir_is_ram_backed', work).returncode == 0
print('Primary staging filesystem: ' + ('RAM-backed; refusal required' if ram_backed else
                                       'ordinary filesystem; successful admission required'), flush=True)
for name, attributes, changed in (
    ('ordinary', None, False),
    ('noop-subst', b'version-no-token.txt export-subst\n', False),
    ('export-ignore', b'src/input.txt export-ignore\n', True),
    ('export-subst', b'version.txt export-subst\n', True),
    ('all-export-ignore', b'* export-ignore\n', True),
):
    directory = work / name
    repository = directory / 'repo'
    repository.mkdir(parents=True)
    git(repository, 'init', '-q', '--initial-branch=main', '--object-format=sha1')
    files = {'Cargo.toml': b'[package]\nname="source-fixture"\nversion="0.1.0"\n',
             'src/input.txt': b'tracked compiler input\n',
             'version.txt': b'commit=$Format:%H$\n',
             'version-no-token.txt': b'no substitution placeholder\n',
             'run.sh': b'#!/bin/sh\nprintf "tracked executable\\n"\n'}
    if not changed:
        files['-leading'] = b'legacy path remains admitted\n'
    long_path = 'nested/' + 'long-name-' * 12 + '.txt' if name == 'ordinary' else None
    if long_path:
        files[long_path] = b'long tracked path retains PAX metadata\n'
    if attributes is not None:
        files['.gitattributes'] = attributes
    for relative, data in files.items():
        path = repository / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755 if relative == 'run.sh' else 0o644)
    (repository / 'input-link').symlink_to('src/input.txt')
    if long_path:
        (repository / 'long-link').symlink_to(long_path)
    git(repository, 'add', '.')
    git(repository, 'commit', '-qm', 'tracked archive attributes')
    revision = git(repository, 'rev-parse', 'HEAD').decode().strip()
    if name == 'noop-subst':
        git(repository, 'config', 'tar.umask', '0077')
    check(name + ': genuine pinned source checkout is clean', not git(repository, 'status', '--porcelain'))

    legacy = directory / 'legacy.tar'
    legacy.write_bytes(git(repository, 'archive', '--format=tar', revision))
    original_legacy = legacy.read_bytes()
    if name == 'all-export-ignore':
        # Python tarfile rejects Git's valid global-PAX-only empty archive.
        # The real tar reader independently establishes its empty inventory.
        empty_listing = run(['tar', '-tf', str(legacy)])
        check(name + ': real Git export has no source members but retains a valid tar stream',
              empty_listing.returncode == 0 and not empty_listing.stdout and len(original_legacy) >= 1024)
    else:
        with tarfile.open(legacy) as archive_reader:
            legacy_members = archive_reader.getmembers()
            if name == 'export-ignore':
                check(name + ': real Git export omits the committed input',
                      'src/input.txt' not in {entry.name for entry in legacy_members})
            elif name == 'export-subst':
                check(name + ': real Git export rewrites the committed token',
                      archive_reader.extractfile('version.txt').read() == ('commit=' + revision + '\n').encode())
            elif name == 'noop-subst':
                check(name + ': non-default tar umask is a valid legacy archive identity',
                      archive_reader.getmember('run.sh').mode == 0o700 and
                      archive_reader.getmember('version-no-token.txt').mode == 0o600)
            elif long_path:
                check(name + ': genuine Git tar includes long path and linkpath PAX headers',
                      archive_reader.getmember(long_path).pax_headers.get('path') == long_path and
                      archive_reader.getmember('long-link').pax_headers.get('linkpath') == long_path)
    match = probe(repository, revision)
    check(name + ': comparison distinguishes actual transformation from unchanged bytes',
          match.returncode == (10 if changed else 0) and not match.stdout)

    manifest, archive = directory / 'tracked.manifest', directory / 'selected.tar'
    success('_act_write_tracked_manifest', repository, revision, manifest)
    success('_act_write_git_archive_evidence', repository, revision, archive)
    original_manifest, original_archive = manifest.read_bytes(), archive.read_bytes()
    check(name + ': archive selection preserves accepted legacy bytes and replaces only changed trees',
          (original_archive != original_legacy) if changed else (original_archive == original_legacy))
    check(name + ': recovery digest agrees with the selected writer bytes',
          success('_act_git_archive_sha256', repository, revision).decode().strip() == digest(archive))
    extracted = directory / 'selected-source'
    unpack(archive, extracted)
    check(name + ': selected archive contains every original tracked byte and symlink',
          all((extracted / relative).read_bytes() == data for relative, data in files.items()) and
          (extracted / 'input-link').is_symlink() and os.readlink(extracted / 'input-link') == 'src/input.txt' and
          (not long_path or ((extracted / 'long-link').is_symlink() and os.readlink(extracted / 'long-link') == long_path)) and
          os.access(extracted / 'run.sh', os.X_OK))
    check(name + ': independent local tracked-tree verifier accepts the selected archive',
          call('_act_verify_tracked_manifest_local', extracted, manifest).returncode == 0)
    count = int(success('_act_tracked_manifest_object_count', manifest))
    program = success('_act_unix_strict_snapshot_verify_script', extracted, archive, manifest, digest(manifest), count)
    script = directory / 'verify-selected.sh'
    script.write_bytes(program)
    wanted = (digest(archive) + ' ' + digest(manifest) + '\n').encode()
    verified = run(['sh', str(script)])
    check(name + ': generated POSIX receiver verifies the same selected identity',
          verified.returncode == 0 and verified.stdout == wanted)

    if not changed:
        retained_parent = directory / 'retained-run'
        retained_parent.mkdir()
        retained_archive = retained_parent / '.source.tar'
        retained_manifest = retained_parent / '.source.manifest'
        retained_archive.write_bytes(original_legacy)
        retained_manifest.write_bytes(original_manifest)
        retained = retained_parent / 'source'
        unpack(retained_archive, retained)
        for attempt in range(2):
            check(name + ': retained legacy source resumes without restaging, pass ' + str(attempt + 1),
                  call('_act_verify_strict_checkout_snapshot', 'act', repository, revision,
                       retained, 'source.tar', name).returncode == 0)
        check(name + ': resumed legacy receipts remain byte-identical',
              retained_archive.read_bytes() == original_legacy and retained_manifest.read_bytes() == original_manifest)

    # This is the actual sibling staging path. Its parent is already owned by
    # the run; it uses the same writer and receiver as a fresh primary source.
    sibling_parent = directory / 'sibling-run'
    sibling_parent.mkdir()
    (sibling_parent / '.sbh-protect').write_text('DSR source regression fixture\n')
    stage = sibling_parent / 'dependency'
    success('_act_sync_strict_checkout', 'act', repository, revision, stage, 'dependency.tar', name)
    check(name + ': actual sibling source staging retains committed inputs',
          (stage / 'src/input.txt').read_bytes() == files['src/input.txt'] and
          (stage / 'version.txt').read_bytes() == files['version.txt'])
    staged_archive, staged_manifest = sibling_parent / '.dependency.tar', sibling_parent / '.dependency.manifest'
    check(name + ': staged receipts match the independently retained selected archive',
          staged_archive.read_bytes() == original_archive and staged_manifest.read_bytes() == original_manifest)
    primary = directory / 'primary-run/source'
    primary_result = call('_act_sync_strict_checkout', 'act', repository, revision, primary, 'source.tar', name)
    check(name + ': primary source staging respects the real filesystem storage gate',
          (primary_result.returncode == 4 and b'RAM-backed' in primary_result.stderr and not primary.exists())
          if ram_backed else (primary_result.returncode == 0 and (primary / 'src/input.txt').read_bytes() == files['src/input.txt']))

    def finalization():
        return call('_act_verify_strict_checkout_snapshot', 'act', repository, revision,
                    stage, 'dependency.tar', name)

    check(name + ': actual retained-source finalization accepts the selected archive', finalization().returncode == 0)
    if changed:
        stage_program = success('_act_unix_strict_snapshot_verify_script', stage, staged_archive,
                                staged_manifest, digest(manifest), count)
        stage_script = directory / 'verify-staged.sh'
        stage_script.write_bytes(stage_program)
        for kind in ('source', 'executable-mode', 'manifest', 'archive'):
            selected = {'source': stage / 'src/input.txt', 'executable-mode': stage / 'run.sh',
                        'manifest': staged_manifest, 'archive': staged_archive}[kind]
            held, held_mode = selected.read_bytes(), selected.stat().st_mode & 0o777
            if kind == 'executable-mode':
                selected.chmod(0o644)
            else:
                selected.write_bytes((bytes([held[0] ^ 1]) + held[1:]) if held else b'changed')
            result = finalization()
            received = run(['sh', str(stage_script)])
            check(name + ': ' + kind + ' tampering is refused by actual source finalization', result.returncode == 4)
            check(name + ': ' + kind + ' tampering cannot reproduce the pinned receiver identity',
                  received.returncode != 0 or received.stdout != wanted)
            if kind == 'executable-mode':
                selected.chmod(held_mode)
            else:
                selected.write_bytes(held)
        check(name + ': restored original source and receipt bytes are accepted', finalization().returncode == 0)

    repeated = directory / 'regenerated.tar'
    success('_act_write_git_archive_evidence', repository, revision, repeated)
    check(name + ': repeated export preserves the selected immutable identity', repeated.read_bytes() == original_archive)
    relocated = directory / 'relocated-repo'
    repository.rename(relocated)
    repository = relocated
    check(name + ': moving the controller checkout does not change the archive digest',
          success('_act_git_archive_sha256', repository, revision).decode().strip() == digest(archive))
    inventory = run(['bash', '-c',
        'source "$1" || exit; source "$2" || exit; ACT_REPO_LOCAL_PATH="$3"; _act_relocation_source_inventory source-fixture "$4"',
        'fixture', str(root / 'src/config.sh'), str(module), str(repository), revision])
    check(name + ': real relocation inventory retains both selected source identities',
          inventory.returncode == 0 and json.loads(inventory.stdout) == [dict(path='source', git_sha=revision,
              archive_sha256=digest(archive), manifest_sha256=digest(manifest))])
    check(name + ': repeated verification after relocation does not rewrite original evidence',
          finalization().returncode == 0 and archive.read_bytes() == original_archive and
          manifest.read_bytes() == original_manifest and legacy.read_bytes() == original_legacy and
          staged_archive.read_bytes() == original_archive and staged_manifest.read_bytes() == original_manifest)
    cases[name] = (repository, revision)

# Faults occur at real Git process boundaries. The archive itself is genuine
# Git output until the named corruption; all selection/writer/hash functions
# remain production code, so a fallback that hides a failure is observable.
observer = work / 'observer'
observer.mkdir()
git_wrapper = observer / 'git'
git_wrapper.write_text('''#!/usr/bin/env python3
import io, os, subprocess, sys, tarfile
arguments = sys.argv[1:]
fault = os.environ.get('DSR_ARCHIVE_FAULT', '')
if fault == 'inventory-failure' and 'ls-tree' in arguments:
    sys.exit(27)
if 'archive' not in arguments:
    os.execv(os.environ['DSR_REAL_GIT'], [os.environ['DSR_REAL_GIT'], *arguments])
result = subprocess.run([os.environ['DSR_REAL_GIT'], *arguments], capture_output=True)
sys.stderr.buffer.write(result.stderr)
if result.returncode:
    sys.exit(result.returncode)
data = result.stdout
if fault == 'malformed-header':
    data = bytes([data[0] ^ 1]) + data[1:]
elif fault == 'missing-terminators':
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        entries = archive.getmembers()
    end = max(entry.offset_data + ((entry.size + 511) // 512) * 512 for entry in entries)
    data = data[:end]
sys.stdout.buffer.write(data)
sys.exit(23 if fault == 'producer-failure' else 0)
''')
git_wrapper.chmod(0o755)
for name, fault in (('ordinary', 'producer-failure'), ('export-ignore', 'producer-failure'),
                    ('all-export-ignore', 'producer-failure'),
                    ('ordinary', 'malformed-header'), ('ordinary', 'missing-terminators'),
                    ('ordinary', 'inventory-failure')):
    repository, revision = cases[name]
    overrides = dict(PATH=str(observer) + os.pathsep + environment['PATH'],
                     DSR_REAL_GIT=shutil.which('git'), DSR_ARCHIVE_FAULT=fault)
    result = probe(repository, revision, overrides)
    check(name + ': ' + fault + ' is a comparison error rather than semantic divergence',
          result.returncode == 4 and not result.stdout)
    refused_archive = work / (name + '-' + fault + '.tar')
    result = call('_act_write_git_archive_evidence', repository, revision, refused_archive, overrides=overrides)
    check(name + ': ' + fault + ' cannot fall back to an apparently successful writer', result.returncode != 0)
    check(name + ': ' + fault + ' refuses before emitting any archive evidence',
          refused_archive.is_file() and refused_archive.stat().st_size == 0)
    result = call('_act_git_archive_sha256', repository, revision, overrides=overrides)
    check(name + ': ' + fault + ' cannot produce a successful recovery digest', result.returncode != 0)

print(f'Unix export attributes: {checks} assertions passed; real Git, writer, receivers, sibling staging and retained-source recovery.', flush=True)
print('Primary staging: ' + ('RAM-backed refusal verified; native host readiness not qualified.' if ram_backed else
                             'fresh primary source admitted on ordinary storage; no compiler or SSH transport.'), flush=True)
PY
attributes_status=$?
[[ "$attributes_status" -eq 0 ]] || exit "$attributes_status"
[[ "${1:-}" != --export-attributes-only ]] || exit 0
fi

# Authenticate the actual native export and receiver path with recursive Git
# repositories. This is separate from the large-file batch above so an
# incumbent negative control can select it without rerunning that matrix.
python3 - "$ROOT" <<'PY'
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import zlib

root = Path(sys.argv[1])
module = Path(os.environ.get('DSR_TEST_ACT_RUNNER', str(root / 'src/act_runner.sh')))
os.umask(0o077)
work = Path(tempfile.mkdtemp(prefix='dsr-unix-project-submodules-'))
print('Project-submodule fixtures: ' + str(work), flush=True)
environment = {key: value for key, value in os.environ.items() if not key.upper().startswith('GIT_')}
environment.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
    GIT_AUTHOR_NAME='DSR fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
    GIT_COMMITTER_NAME='DSR fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid',
    GIT_AUTHOR_DATE='2026-01-01T00:00:00Z', GIT_COMMITTER_DATE='2026-01-01T00:00:00Z',
    ACT_ARTIFACTS_DIR=str(work / 'artifacts'), DSR_STATE_DIR=str(work / 'state'), NO_COLOR='1')
checks = 0

def check(label, condition):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print('PASS ' + label, flush=True)

def run(arguments, **kwargs):
    return subprocess.run(arguments, capture_output=True, env=environment, timeout=30, **kwargs)

def git(repository, *arguments, data=None):
    return run(['git', '-c', 'protocol.file.allow=always', '-C', str(repository), *arguments],
               input=data, check=True).stdout

def call(function, *arguments):
    return run(['bash', '-c', 'source "$1" || exit; shift; "$@"', 'fixture', str(module),
                function, *map(str, arguments)])

def success(function, *arguments):
    result = call(function, *arguments)
    if result.returncode:
        raise AssertionError(function + ': ' + result.stderr.decode(errors='replace'))
    return result.stdout

def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def make_repository(name, files=None, links=None):
    repository = work / name
    repository.mkdir()
    git(repository, 'init', '-q', '--initial-branch=main', '--object-format=sha1')
    for name, value in (files or {}).items():
        mode, data = value if isinstance(value, tuple) else (0o644, value)
        path = repository / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data); path.chmod(mode)
    for name, target in (links or {}).items():
        path = repository / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)
    git(repository, 'add', '.')
    git(repository, 'commit', '-qm', 'pinned source fixture', '--allow-empty')
    return repository

leaf = make_repository('leaf-seed', {'leaf.txt': b'pinned nested source\n'}, {'leaf-copy': 'leaf.txt'})
empty = make_repository('empty-seed')
child_seed = make_repository('child-seed', {'data.txt': b'pinned child source\n',
    'run.sh': (0o755, b'#!/bin/sh\nprintf "child\\n"\n')},
    {'copy.txt': 'data.txt', 'deep/local-link': '../data.txt', 'nested-directory-link': 'nested'})
for name, repository in [('nested/leaf', leaf), ('empty', empty)]:
    git(child_seed, 'submodule', 'add', '-q', str(repository), name)
git(child_seed, 'commit', '-qm', 'pin nested and empty children')
standalone_seed = make_repository('standalone-seed', {'standalone.txt': b'self-contained child\n'})
project = make_repository('project', {'root.txt': b'root source\n', 'docs/guide.txt': b'tracked guide\n'},
                          {'root-copy': 'root.txt', 'directory-link': 'docs', 'vendor-directory-link': 'vendor'})
git(project, 'submodule', 'add', '-q', str(child_seed), 'vendor/dep')
git(project, 'submodule', 'update', '--init', '--recursive', '-q')
standalone = project / 'vendor/standalone'
git(project, 'clone', '-q', '--no-hardlinks', str(standalone_seed), str(standalone))
standalone_sha = git(standalone, 'rev-parse', 'HEAD').decode().strip()
git(project, 'update-index', '--add', '--cacheinfo', '160000,' + standalone_sha + ',vendor/standalone')
git(project, 'commit', '-qm', 'pin absorbed and self-contained project children')
revision = git(project, 'rev-parse', 'HEAD').decode().strip()
child = project / 'vendor/dep'
child_revision = git(child, 'rev-parse', 'HEAD').decode().strip()
check('fixture uses an absorbed child and self-contained sibling',
      (child / '.git').is_file() and (standalone / '.git').is_dir())
check('fixture uses a recursively absorbed nested child', (child / 'nested/leaf/.git').is_file())
check('full project checkout is clean before strict source staging', not git(project, 'status', '--porcelain'))

def export(label, selected=revision):
    archive, manifest = work / (label + '.tar'), work / (label + '.manifest')
    success('_act_write_git_archive_evidence', project, selected, archive)
    success('_act_write_tracked_manifest', project, selected, manifest)
    return archive, manifest

archive, manifest = export('selected')
rows = {}

def selected_rows(repository, commit, prefix=''):
    for row in git(repository, 'ls-tree', '-rz', '--full-tree', commit).split(b'\0'):
        if not row:
            continue
        metadata, name = row.decode().split('\t', 1)
        mode, kind, oid = metadata.split()
        rows[prefix + name] = (oid, mode)
        if mode == '160000':
            selected_rows(repository / name, oid, prefix + name + '/')

selected_rows(project, revision)
actual_rows = {parts[2]: tuple(parts[:2]) for parts in
               (line.split('\t') for line in manifest.read_text().splitlines())}
check('production manifest contains every exact recursive Git blob and gitlink', actual_rows == rows)
check('production manifest retains nested and empty repository boundaries',
      all(rows[path][1] == '160000' for path in ('vendor/dep', 'vendor/dep/nested/leaf', 'vendor/dep/empty', 'vendor/standalone')))
source = work / 'selected-source'; source.mkdir()
run(['tar', '-xf', str(archive), '-C', str(source)], check=True)
check('production archive contains pinned child and nested contents',
      (source / 'vendor/dep/data.txt').read_bytes() == b'pinned child source\n' and
      (source / 'vendor/dep/nested/leaf/leaf.txt').read_bytes() == b'pinned nested source\n')
check('production archive preserves child links and executable modes',
      (source / 'vendor/dep/copy.txt').is_symlink() and (source / 'directory-link').is_symlink() and
      (source / 'vendor/dep/run.sh').stat().st_mode & 0o111 == 0o111)
check('own-repository directory links survive when their directory contains only gitlinks',
      (source / 'vendor-directory-link').is_symlink() and (source / 'vendor-directory-link').is_dir() and
      (source / 'vendor/dep/nested-directory-link').is_symlink() and (source / 'vendor/dep/nested-directory-link').is_dir())
check('production archive preserves the empty child directory',
      (source / 'vendor/dep/empty').is_dir() and not list((source / 'vendor/dep/empty').iterdir()))
count = int(success('_act_tracked_manifest_object_count', manifest))
expected = (sha256(archive) + ' ' + sha256(manifest) + '\n').encode()

def verify(label, tree=source, selected_manifest=manifest, accepted=True):
    local = call('_act_verify_tracked_manifest_local', tree, selected_manifest)
    selected_count = int(success('_act_tracked_manifest_object_count', selected_manifest))
    program = success('_act_unix_strict_snapshot_verify_script', tree, archive, selected_manifest,
                      sha256(selected_manifest), selected_count)
    script = work / ('verify-' + label + '.sh'); script.write_bytes(program)
    remote = run(['sh', str(script)])
    wanted = (sha256(archive) + ' ' + sha256(selected_manifest) + '\n').encode()
    check(label + ' local verifier', local.returncode == 0 if accepted else local.returncode != 0)
    check(label + ' actual emitted POSIX verifier',
          remote.returncode == 0 and remote.stdout == wanted if accepted else remote.returncode != 0 and not remote.stdout)

verify('recursive-project-source')
again_archive, again_manifest = export('regenerated')
check('recovery reproduces the exact source archive and manifest bytes',
      archive.read_bytes() == again_archive.read_bytes() and manifest.read_bytes() == again_manifest.read_bytes())
check('production recovery archive hash matches admitted export',
      success('_act_git_archive_sha256', project, revision).decode().strip() == sha256(archive))

# Use actual local staging and final source verification; no transport, source
# admission, path selection, or manifest function is substituted here.
stage = work / 'native-run/source'
stage_archive = 'source.tar'
if call('_act_dir_is_ram_backed', work).returncode == 0:
    refused = call('_act_sync_strict_checkout', 'act', project, revision, stage, stage_archive, 'submodule-fixture')
    check('actual primary project staging retains the RAM-backed storage refusal',
          refused.returncode == 4 and b'RAM-backed' in refused.stderr and not stage.exists())
    stage.parent.mkdir()
    (stage.parent / '.sbh-protect').write_text('DSR project-submodule regression fixture\n')
    stage_archive = 'dependency.tar'
    print('Project-submodule integration uses genuine sibling staging on RAM-backed fixtures.', flush=True)
success('_act_sync_strict_checkout', 'act', project, revision, stage, stage_archive, 'submodule-fixture')
check('actual strict local stage contains the nested pinned source',
      (stage / 'vendor/dep/nested/leaf/leaf.txt').read_bytes() == b'pinned nested source\n')
check('actual strict source finalization accepts the unchanged staged graph',
      call('_act_verify_strict_checkout_snapshot', 'act', project, revision, stage, stage_archive, 'submodule-fixture').returncode == 0)
(stage / 'vendor/dep/data.txt').write_bytes(b'changed staged child\n')
check('actual strict source finalization refuses changed staged child bytes',
      call('_act_verify_strict_checkout_snapshot', 'act', project, revision, stage, stage_archive, 'submodule-fixture').returncode != 0)

payload = source / 'vendor/dep/data.txt'; original = payload.read_bytes()
payload.write_bytes(b'changed child\n'); verify('changed-child-bytes', accepted=False); payload.write_bytes(original)
executable = source / 'vendor/dep/run.sh'
executable.chmod(0o644); verify('changed-child-mode', accepted=False); executable.chmod(0o755)
extra = source / 'vendor/dep/empty/extra'; extra.write_bytes(b'untracked\n')
verify('extra-file-in-empty-submodule', accepted=False); extra.rename(work / 'held-extra-child')
nested = source / 'vendor/dep/nested/leaf/leaf.txt'; held_nested = work / 'held-nested-file'
nested.rename(held_nested); verify('missing-nested-file', accepted=False); held_nested.rename(nested)

# A correctly hashed link blob is insufficient if traversal crosses a Git
# namespace. These receiver inputs intentionally bypass the producer's own
# refusal; the independent local and remote gates must enforce it too.
for label, owner, target in (
    ('parent-direct-child-directory', '', 'vendor/dep'),
    ('parent-to-child', '', 'vendor/dep/data.txt'),
    ('parent-enters-and-leaves', '', 'vendor/dep/../../root.txt'),
    ('child-to-parent', 'vendor/dep', '../../root.txt'),
    ('child-leaves-and-reenters', 'vendor/dep', '../dep/data.txt'),
    ('child-to-sibling', 'vendor/dep', '../standalone/standalone.txt'),
    ('child-direct-nested-directory', 'vendor/dep', 'nested/leaf'),
    ('child-to-nested', 'vendor/dep', 'nested/leaf/leaf.txt'),
    ('child-enters-and-leaves-nested', 'vendor/dep', 'nested/leaf/../../data.txt'),
    ('nested-to-parent', 'vendor/dep/nested/leaf', '../../data.txt'),
    ('missing-directory-before-parent', 'vendor/dep', 'missing/../data.txt'),
    ('regular-file-before-parent', 'vendor/dep', 'data.txt/../data.txt'),
):
    tree = work / ('receiver-' + label)
    shutil.copytree(source, tree, symlinks=True)
    path = str(PurePosixPath(owner) / 'boundary-link')
    (tree / path).symlink_to(target)
    oid = git(project, 'hash-object', '--stdin', data=target.encode()).decode().strip()
    forged = work / ('receiver-' + label + '.manifest')
    forged.write_bytes(manifest.read_bytes() + (oid + '\t120000\t' + path + '\n').encode())
    verify(label, tree, forged, False)

# Construct a new child commit and parent gitlink using real Git objects. The
# selected parent pin, not the mutable child HEAD or checkout, chooses bytes.
old_oid = rows['vendor/dep/data.txt'][0]
new_oid = git(child, 'hash-object', '-w', '--stdin', data=b'new pinned child source\n').decode().strip()
git(child, 'update-index', '--cacheinfo', '100644,' + new_oid + ',data.txt')
new_tree = git(child, 'write-tree').decode().strip()
new_child = git(child, 'commit-tree', new_tree, '-p', child_revision, '-m', 'new child pin').decode().strip()
git(child, 'update-index', '--cacheinfo', '100644,' + old_oid + ',data.txt')
git(project, 'update-index', '--cacheinfo', '160000,' + new_child + ',vendor/dep')
new_root_tree = git(project, 'write-tree').decode().strip()
new_root = git(project, 'commit-tree', new_root_tree, '-p', revision, '-m', 'select changed child').decode().strip()
git(project, 'update-index', '--cacheinfo', '160000,' + child_revision + ',vendor/dep')
changed_archive, changed_manifest = export('changed-pin', new_root)
changed_source = work / 'changed-pin-source'; changed_source.mkdir()
run(['tar', '-xf', str(changed_archive), '-C', str(changed_source)], check=True)
check('changing the parent gitlink changes the actual selected child bytes',
      sha256(changed_archive) != sha256(archive) and
      (changed_source / 'vendor/dep/data.txt').read_bytes() == b'new pinned child source\n')
git(child, 'update-ref', 'HEAD', new_child)
(child / 'data.txt').write_bytes(b'mutable checkout bytes are never release inputs\n')
git(child, 'config', 'remote.origin.url', 'https://unreachable.invalid/never-fetch.git')
unchanged_archive, unchanged_manifest = export('ignore-mutable-child')
check('child HEAD, working bytes, and remote URL cannot override the parent pin',
      archive.read_bytes() == unchanged_archive.read_bytes() and manifest.read_bytes() == unchanged_manifest.read_bytes())
check('strict staging still refuses a dirty checkout even though object export is pinned',
      call('_act_sync_strict_checkout', 'act', project, revision, work / 'dirty-run/source', 'source.tar', 'dirty-fixture').returncode != 0)
git(child, 'update-ref', 'HEAD', child_revision)
(child / 'data.txt').write_bytes(b'pinned child source\n')

admin = Path(git(child, 'rev-parse', '--absolute-git-dir').decode().strip())
object_file = admin / 'objects' / old_oid[:2] / old_oid[2:]
check('negative controls use the genuine selected loose Git object', object_file.is_file())
held_object = work / 'held-child-object'; object_file.rename(held_object)
check('missing selected child object refuses native archive export',
      call('_act_write_git_archive_evidence', project, revision, work / 'missing-object.tar').returncode != 0)
check('missing child object cannot produce a successful recovery hash',
      call('_act_git_archive_sha256', project, revision).returncode != 0)
held_object.rename(object_file)
original_object = object_file.read_bytes()
object_file.write_bytes(zlib.compress(b'blob 6\x00forged'))
check('validly encoded object with wrong content hash refuses native export',
      call('_act_write_git_archive_evidence', project, revision, work / 'wrong-object.tar').returncode != 0)
object_file.write_bytes(original_object)

marker = child / '.git'; original_marker = marker.read_bytes()
external = work / 'external-git-administration'
shutil.copytree(admin, external)
marker.write_text('gitdir: ' + str(external) + '\n')
check('external Git administration with the same objects is refused',
      call('_act_write_git_archive_evidence', project, revision, work / 'external-admin.tar').returncode != 0)
marker.write_bytes(original_marker)
alternates = admin / 'objects/info/alternates'; alternates.write_text(str(external / 'objects') + '\n')
check('external alternate object stores are refused',
      call('_act_write_git_archive_evidence', project, revision, work / 'alternates.tar').returncode != 0)
alternates.rename(work / 'held-alternates')
check('restored genuine source objects reproduce the admitted recovery hash',
      success('_act_git_archive_sha256', project, revision).decode().strip() == sha256(archive))
verify('restored-recursive-project-source')
print(f'Unix project submodules: {checks} assertions passed; genuine Git and local source staging, no SSH transport.', flush=True)
PY
