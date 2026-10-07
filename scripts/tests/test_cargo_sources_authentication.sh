#!/usr/bin/env bash
# Locked-cache authenticity: real crate archives and Git object databases;
# Cargo metadata is an explicit fixture. No network or Rust toolchain required.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 git cc; do
    command -v "$tool" >/dev/null || { printf 'SKIP: requires %s\n' "$tool"; exit 0; }
done
python3 -I - "$ROOT/src/cargo_sources.sh" <<'PY'
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
import zlib

MODULE = sys.argv[1]
PASS = FAIL = 0
REGISTRY = 'registry+https://example.invalid/index'


def git(root, *args, input=None):
    return subprocess.run(['git', '-C', str(root), *args], input=input,
                          capture_output=True, check=True).stdout.decode().strip()


class Fixture:
    def __init__(self, root):
        self.root = Path(root)
        self.app = self.root / 'project'
        self.reg = self.root / 'cargo home/registry/src/registry-123/dep-1.2.3'
        self.repo = self.root / 'cargo home/git/checkouts/repo-123/abcdef0'
        self.archive = self.root / 'cargo home/registry/cache/registry-123/dep-1.2.3.crate'
        for directory in (self.app, self.reg, self.repo):
            directory.mkdir(parents=True)
            (directory / 'Cargo.toml').write_text('[package]\nname="dep"\nversion="1.2.3"\n')
            (directory / 'lib.rs').write_text('pub fn value() -> u32 { 42 }\n')
            (directory / 'shared.h').write_text('#define VALUE 42\n')
        self.archive.parent.mkdir(parents=True)
        self.pack()
        git(self.repo, 'init', '-q', '-b', 'main')
        git(self.repo, 'config', 'user.name', 'DSR Test')
        git(self.repo, 'config', 'user.email', 'dsr@example.invalid')
        git(self.repo, 'add', '.')
        git(self.repo, 'commit', '-qm', 'reviewed dependency')
        self.commit = git(self.repo, 'rev-parse', 'HEAD')
        self.source = 'git+https://example.invalid/repo?rev=reviewed#' + self.commit
        self.lock = self.app / 'Cargo.lock'
        self.write_lock()
        self.metadata = self.root / 'metadata.json'
        self.receipt = self.root / 'receipt.json'
        def package(id, source, root):
            return dict(id=id, name=id if id == 'app' else 'dep', version='1.2.3', source=source,
                        manifest_path=str(root/'Cargo.toml'), targets=[dict(src_path=str(root/'lib.rs'))])
        self.graph = dict(version=1, workspace_root=str(self.app),
            packages=[package('app', None, self.app), package('registry', REGISTRY, self.reg),
                      package('git', self.source, self.repo)],
            resolve=dict(nodes=[dict(id='app', dependencies=['registry', 'git']),
                                dict(id='registry', dependencies=[]), dict(id='git', dependencies=[])]))
        self.save()

    def pack(self, extra=None):
        with tarfile.open(self.archive, 'w:gz') as archive:
            for file in sorted(self.reg.rglob('*')):
                archive.add(file, arcname=self.reg.name + '/' + str(file.relative_to(self.reg)), recursive=False)
            if extra is not None:
                entry, payload = extra
                archive.addfile(entry, io.BytesIO(payload) if entry.isfile() else None)
        self.checksum = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def write_lock(self):
        self.lock.write_text('version = 4\n\n[[package]]\nname="app"\nversion="1.2.3"\n' +
            '\n[[package]]\nname="dep"\nversion="1.2.3"\nsource=' + json.dumps(REGISTRY) +
            '\nchecksum=' + json.dumps(self.checksum) + '\n\n[[package]]\nname="dep"\nversion="1.2.3"\nsource=' +
            json.dumps(self.source) + '\n')

    def save(self):
        self.metadata.write_text(json.dumps(self.graph))

    def run(self, mode='capture', locked=True, env=None, receipt=None):
        args = ['bash', MODULE, mode, str(self.metadata), '["app"]', str(receipt or self.receipt)]
        if locked:
            args.append(str(self.lock))
        return subprocess.run(args, capture_output=True, text=True, timeout=20, env=env)

    def good(self, **kwargs):
        result = self.run(**kwargs)
        assert result.returncode == 0, (result.returncode, result.stderr)
        return json.loads(result.stdout)

    def refused(self, reason=None, **kwargs):
        result = self.run(**kwargs)
        assert result.returncode == 7 and not result.stdout, (result.returncode, result.stdout, result.stderr)
        if reason:
            assert reason in result.stderr, result.stderr
        return result


def check(name, fn):
    global PASS, FAIL
    try:
        with tempfile.TemporaryDirectory(prefix='dsr-locked-sources-') as directory:
            fn(Fixture(directory))
        PASS += 1
        print('PASS ' + name)
    except Exception as exc:
        FAIL += 1
        print('FAIL ' + name + ': ' + str(exc), file=sys.stderr)


def valid(f):
    summary = f.good()
    evidence = json.loads(f.receipt.read_bytes())
    assert summary['sha256'] == hashlib.sha256(f.receipt.read_bytes()).hexdigest()
    assert evidence['authentication']['lockfile_sha256'] == hashlib.sha256(f.lock.read_bytes()).hexdigest()
    proofs = {p['package_id']: p for p in evidence['authentication']['packages']}
    assert proofs['registry']['archive_sha256'] == f.checksum
    assert proofs['git']['commit'] == f.commit and proofs['git']['tree'] == git(f.repo, 'rev-parse', 'HEAD^{tree}')
    assert f.good(mode='verify') == summary
check('crate SHA256 and commit/tree/blob object chains are bound and reverify', valid)


def poison(f, root):
    (root/'shared.h').write_text('#define VALUE 43\n')
    f.good(locked=False, receipt=f.root/'observed.json')
    f.refused('differ from locked content')
    assert not f.receipt.exists()
check('pre-existing registry poison passes observation but fails locked admission', lambda f: poison(f, f.reg))
check('pre-existing Git poison passes observation but fails locked admission', lambda f: poison(f, f.repo))


def compiler(f):
    source = f.root/'probe.c'; source.write_text('#include "shared.h"\nint main(void){return VALUE;}\n')
    binary = f.root/'probe'
    subprocess.run(['cc', '-I', str(f.reg), str(source), '-o', str(binary)], check=True)
    assert subprocess.run([str(binary)]).returncode == 42
    (f.reg/'shared.h').write_text('#define VALUE 43\n')
    subprocess.run(['cc', '-I', str(f.reg), str(source), '-o', str(f.root/'poisoned')], check=True)
    assert subprocess.run([str(f.root/'poisoned')]).returncode == 43
    f.good(locked=False, receipt=f.root/'unprotected.json')
    f.refused('differ from locked content')
check('a poisoned dependency changes real compiled behavior and is refused before a build', compiler)


def replace_archive(f):
    (f.reg/'lib.rs').write_text('attacker bytes')
    f.pack()  # The extracted tree and the archive agree, but the lock does not.
    f.refused('archive differs from Cargo.lock')
check('matching altered source and archive cannot override the reviewed lock', replace_archive)


def wrong_lock(f):
    f.checksum = '0'*64; f.write_lock(); f.refused('archive differs from Cargo.lock')
check('wrong lockfile archive checksum is refused', wrong_lock)


def without_archive(f):
    f.archive.rename(f.root/'retained.crate'); f.refused()
check('a missing archive cannot be replaced by an extracted-tree receipt', without_archive)


def linked_archive(f):
    retained = f.root/'retained.crate'; f.archive.rename(retained); f.archive.symlink_to(retained); f.refused()
check('linked pinned archives are refused', linked_archive)


def linked_archive_parent(f):
    parent=f.archive.parent; retained=f.root/'retained-cache'; parent.rename(retained); parent.symlink_to(retained, target_is_directory=True); f.refused()
check('archive ancestor links cannot redirect authenticated inputs', linked_archive_parent)


def change_before(f, action):
    action(); f.refused()
check('registry executable bits must match the archive', lambda f: change_before(f, lambda: (f.reg/'lib.rs').chmod(0o755)))
check('Git executable bits must match the locked tree', lambda f: change_before(f, lambda: (f.repo/'lib.rs').chmod(0o755)))
check('untracked Git files cannot become release inputs', lambda f: change_before(f, lambda: (f.repo/'injected.rs').write_text('bad')))
check('unlisted registry files are refused', lambda f: change_before(f, lambda: (f.reg/'injected.rs').write_text('bad')))
check('unlisted empty source directories are refused', lambda f: change_before(f, lambda: (f.reg/'empty').mkdir()))
check('missing extracted sources are refused', lambda f: change_before(f, lambda: (f.reg/'lib.rs').rename(f.root/'retained.rs')))


def markers(f):
    (f.reg/'.cargo-ok').write_text('{"v":1}')
    (f.repo/'.cargo-ok').write_bytes(b'')
    f.good(); f.good(mode='verify')
check('bounded Cargo extraction and checkout markers are accepted', markers)
check('arbitrary completion-marker contents are refused', lambda f: change_before(f, lambda: (f.reg/'.cargo-ok').write_text('arbitrary input')))
check('oversized completion markers are refused', lambda f: change_before(f, lambda: (f.repo/'.cargo-ok').write_bytes(b'x'*65)))


def unsafe_archive(f, name, kind=tarfile.REGTYPE):
    entry=tarfile.TarInfo(name); entry.type=kind; entry.size=0
    if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
        entry.linkname='outside'
    f.pack((entry, b'')); f.write_lock(); f.refused()
check('even a pinned traversal archive is never extracted', lambda f: unsafe_archive(f, '../escape'))
check('another package root in a pinned archive is refused', lambda f: unsafe_archive(f, 'other-1.0.0/file'))
check('duplicate pinned archive members are refused', lambda f: unsafe_archive(f, 'dep-1.2.3/lib.rs'))
check('upstream symlinks are refused', lambda f: unsafe_archive(f, 'dep-1.2.3/link', tarfile.SYMTYPE))
check('upstream hardlinks are refused', lambda f: unsafe_archive(f, 'dep-1.2.3/link', tarfile.LNKTYPE))
check('upstream FIFO members are refused', lambda f: unsafe_archive(f, 'dep-1.2.3/pipe', tarfile.FIFOTYPE))
check('upstream Cargo completion markers cannot shadow managed ones', lambda f: unsafe_archive(f, 'dep-1.2.3/.cargo-ok'))


def changed_lock(f, text):
    f.lock.write_text(text); f.refused()
check('malformed TOML fails rather than using a guessed checksum', lambda f: changed_lock(f, 'version = "unterminated'))
check('unsupported lockfile schema fails', lambda f: changed_lock(f, f.lock.read_text().replace('version = 4', 'version = 5')))
check('duplicate TOML keys fail', lambda f: changed_lock(f, f.lock.read_text() + '\nsource="forged"\n'))
check('comment text cannot supply a checksum', lambda f: changed_lock(f, f.lock.read_text().replace('\nchecksum=', '\n# checksum=')))
check('a duplicate lockfile package identity fails', lambda f: changed_lock(f, f.lock.read_text() + f.lock.read_text().split('[[package]]')[-1].join(['\n[[package]]', ''])))


def identity_mismatch(f):
    f.graph['packages'][1]['source'] = 'registry+https://different.invalid/index'; f.save(); f.refused('not pinned')
check('same package and version from a different registry are distinct', identity_mismatch)


def git_revision(f):
    f.graph['packages'][2]['source'] = f.source[:-40] + 'a'*40; f.save(); f.refused('not pinned')
check('metadata cannot substitute another Git commit', git_revision)


def shortened(f):
    f.source = f.source[:-40] + f.commit[:7]; f.graph['packages'][2]['source'] = f.source
    f.write_lock(); f.save(); f.refused('full locked SHA-1')
check('abbreviated locked Git commits cannot authorize sources', shortened)


def git_corruption(f):
    oid=git(f.repo, 'rev-parse', 'HEAD^{tree}')
    path=f.repo/'.git/objects'/oid[:2]/oid[2:]
    raw=zlib.decompress(path.read_bytes())
    raw=raw.replace(b'lib.rs', b'bad.rs')
    path.chmod(0o600); path.write_bytes(zlib.compress(raw))
    f.refused("bytes do not match its ID")
check('stored Git tree bytes are hashed, not trusted by their object filename', git_corruption)


def git_replacements(f):
    (f.repo/'lib.rs').write_text('replacement objects must not be trusted')
    git(f.repo, 'add', '.'); git(f.repo, 'commit', '-qm', 'forged')
    forged=git(f.repo,'rev-parse','HEAD')
    git(f.repo, 'replace', f.commit, forged)
    # A replacement makes ordinary object reads show the forged tree, but
    # this verifier must read the exact raw objects the lockfile selected.
    f.refused('differ from locked content')
check('Git replacement refs cannot authorize altered cached sources', git_replacements)


def git_ambient(f):
    env=dict(os.environ, GIT_DIR='/nonexistent', GIT_WORK_TREE='/nonexistent',
             GIT_OBJECT_DIRECTORY='/nonexistent', GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='core.bare', GIT_CONFIG_VALUE_0='true')
    f.good(env=env)
check('ambient Git redirection does not affect locked object selection', git_ambient)


def external_storage(f):
    path=f.repo/'.git/objects/info/alternates'; path.parent.mkdir(exist_ok=True); path.write_text('/outside\n'); f.refused('external Git')
check('Git alternates do not create external storage dependencies', external_storage)


def version_three(f):
    f.lock.write_text(f.lock.read_text().replace('version = 4','version = 3')); f.good()
check('Cargo.lock version 3 is supported', version_three)


def timestamps(f):
    f.good(); os.utime(f.reg/'lib.rs',(1,1)); os.utime(f.repo/'lib.rs',(1,1)); f.good(mode='verify')
check('source timestamps are not mistaken for authenticity', timestamps)


def once(f):
    tools=f.root/'tools'; tools.mkdir(); log=f.root/'git.log'
    script=tools/'git'; script.write_text('#!/bin/sh\nprintf "call\\n" >> "'+str(log)+'"\nexec '+shutil.which('git')+' "$@"\n'); script.chmod(0o755)
    for i in range(1100):
        (f.repo/('source%04d.rs'%i)).write_text('pub const VALUE: u32 = 42;\n')
    git(f.repo,'add','.'); git(f.repo,'commit','-qm','large workspace')
    f.commit=git(f.repo,'rev-parse','HEAD'); f.source=f.source[:-40]+f.commit
    f.graph['packages'][2]['source']=f.source; f.write_lock(); f.save()
    f.good(env=dict(os.environ, PATH=str(tools)+':'+os.environ['PATH']))
    assert log.read_text().splitlines()==['call']
check('1100-file Git source authentication uses one batch reader, not one process per file', once)


def vendor(f, external=False):
    vendor=(f.root if external else f.app)/'vendor/dep'; vendor.parent.mkdir()
    shutil.copytree(f.reg,vendor)
    (vendor/'.cargo-checksum.json').write_text('{"files":{},"package":null}')
    f.graph['packages'][1].update(manifest_path=str(vendor/'Cargo.toml'), targets=[dict(src_path=str(vendor/'lib.rs'))]); f.save()
    if external:
        f.refused('external directory source')
    else:
        f.good()
        proofs=json.loads(f.receipt.read_bytes())['authentication']['packages']
        assert any(p['basis']=='caller-verified-workspace-snapshot' and p['path']=='vendor/dep' for p in proofs)
check('committed-workspace vendors retain a distinct, explicit trust basis', vendor)
check('editable external vendor descriptors cannot impersonate upstream pins', lambda f: vendor(f, True))


def after_capture(f):
    f.good(); (f.reg/'shared.h').write_text('#define VALUE 43\n'); f.refused(mode='verify')
check('post-admission changes are still refused by locked verification', after_capture)

print('\nLocked dependency sources: %d passed, %d failed' % (PASS, FAIL))
sys.exit(bool(FAIL))
PY
