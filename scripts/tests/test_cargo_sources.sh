#!/usr/bin/env bash
# Real filesystem and Git/C compilation checks. Cargo metadata is an explicit
# protocol fixture; no network, Rust compilation or production release claimed.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
command -v python3 >/dev/null || { printf 'SKIP: Python 3.9+ required\n'; exit 0; }
python3 - "$ROOT/src/cargo_sources.sh" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

MODULE = sys.argv[1]
passed = failed = 0


class Fixture:
    def __init__(self, root):
        self.root = Path(root)
        self.home = self.root / 'cargo home'
        self.registry = self.home / 'registry/src/example-123/dep-1.2.3'
        self.git = self.home / 'git/checkouts/helper-123/abcdef0'
        self.app = self.root / 'project'
        for base in (self.registry, self.git / 'nested', self.app):
            base.mkdir(parents=True)
            (base / 'Cargo.toml').write_text('[package]\nname="fixture"\nversion="1.2.3"\n')
            (base / 'lib.rs').write_text('pub fn value() -> u32 { 42 }\n')
        (self.git / 'shared.h').write_text('#define VALUE 42\n')
        self.graph = {'version': 1, 'workspace_root': str(self.app),
                      'packages': [self.package('app', None, self.app),
                                   self.package('reg', 'registry+https://example.invalid/index', self.registry),
                                   self.package('git', 'git+https://example.invalid/helper#' + 'a'*40, self.git / 'nested')],
                      'resolve': {'root': 'app', 'nodes': [
                          {'id': 'app', 'dependencies': ['reg', 'git']},
                          {'id': 'reg', 'dependencies': []}, {'id': 'git', 'dependencies': []}]}}
        self.metadata = self.root / 'metadata.json'
        self.receipt = self.root / 'sources.json'
        self.save()

    def package(self, key, source, base):
        return {'id': key, 'name': 'dep' if key == 'reg' else key, 'version': '1.2.3',
                'source': source, 'manifest_path': str(base / 'Cargo.toml'),
                'targets': [{'src_path': str(base / 'lib.rs')}]}

    def save(self):
        self.metadata.write_text(json.dumps(self.graph))

    def call(self, mode='capture', selected='["app"]', receipt=None):
        return subprocess.run(['bash', MODULE, mode, str(self.metadata), selected,
                               str(receipt or self.receipt)], capture_output=True, text=True, timeout=15)

    def good(self, mode='capture', **kwargs):
        p = self.call(mode, **kwargs)
        assert p.returncode == 0, (p.returncode, p.stderr)
        value = json.loads(p.stdout)
        assert value['kind'] == 'dsr-cargo-dependency-sources'
        return value

    def bad(self, mode='capture', **kwargs):
        p = self.call(mode, **kwargs)
        assert p.returncode == 7 and not p.stdout, (p.returncode, p.stdout, p.stderr)


def check(label, action):
    global passed, failed
    try:
        with tempfile.TemporaryDirectory(prefix='dsr-cargo-sources-') as root:
            action(Fixture(root))
        passed += 1
        print('PASS ' + label)
    except Exception as exc:
        failed += 1
        print('FAIL ' + label + ': ' + str(exc), file=sys.stderr)


def exact(f):
    summary = f.good()
    evidence = json.loads(f.receipt.read_bytes())
    assert summary['package_count'] == 2 and summary['root_count'] == 2 and summary['file_count'] == 5
    assert hashlib.sha256(f.receipt.read_bytes()).hexdigest() == summary['sha256']
    assert any('shared.h' in [p['path'] for p in t['files']] for t in evidence['roots'])
    assert f.good('verify') == summary
check('resolved registry and complete Git workspace inventories verify', exact)


def repeat(f):
    first = f.good()
    assert first == f.good(receipt=f.root / 'other.json')
    f.graph['packages'].reverse(); f.graph['resolve']['nodes'].reverse()
    f.graph['resolve']['nodes'][-1]['dependencies'].reverse(); f.save()
    assert first == f.good(receipt=f.root / 'reordered.json')
check('receipt identity ignores output filename and metadata ordering', repeat)


def changed(f, action):
    f.good(); action(f); f.bad('verify')
check('dependency content changes fail verification', lambda f: changed(f, lambda x: (x.registry/'lib.rs').write_text('changed')))


def same_size(f):
    file = f.registry/'lib.rs'; timestamp = file.stat().st_mtime_ns
    f.good(); file.write_text(file.read_text().replace('42', '43'))
    os.utime(file, ns=(timestamp, timestamp)); f.bad('verify')
check('same-size source changes with restored mtime are detected', same_size)
check('executable bit drift fails', lambda f: changed(f, lambda x: (x.registry/'lib.rs').chmod(0o755)))
check('an added source file fails', lambda f: changed(f, lambda x: (x.registry/'extra').write_text('new')))
check('a removed source file fails', lambda f: changed(f, lambda x: (x.registry/'lib.rs').rename(x.root/'retained.rs')))
check('an added empty directory fails', lambda f: changed(f, lambda x: (x.registry/'empty').mkdir()))
check('workspace files outside the Git package directory are bound', lambda f: changed(f, lambda x: (x.git/'shared.h').write_text('#define VALUE 43\n')))


def unchanged_cache(f):
    first = f.good()
    other = f.home/'registry/index/unrelated'; other.parent.mkdir(parents=True); other.write_text('index changed')
    f.graph['packages'].append(f.package('unused', 'registry+https://example.invalid', f.root/'missing'))
    f.graph['resolve']['nodes'].append({'id': 'unused', 'dependencies': []}); f.save()
    assert f.good('verify') == first
check('unresolved cached crates and mutable indexes do not invalidate sources', unchanged_cache)


def transitive(f):
    f.graph['resolve']['nodes'][0]['dependencies'] = ['reg']
    f.graph['resolve']['nodes'][1]['dependencies'] = ['git']; f.save()
    assert f.good()['package_count'] == 2
check('transitive resolved dependencies remain in the source boundary', transitive)


def local_only(f):
    f.graph['resolve']['nodes'][0]['dependencies'] = []; f.save()
    result = f.good(); assert result['package_count'] == result['file_count'] == 0
check('dependency-free releases retain a deterministic empty receipt', local_only)


def root_shared(f):
    second = f.git/'second'; second.mkdir(); (second/'Cargo.toml').write_text(''); (second/'lib.rs').write_text('')
    f.graph['packages'].append(f.package('git2', f.graph['packages'][2]['source'], second))
    f.graph['resolve']['nodes'].append({'id':'git2', 'dependencies':[]})
    f.graph['resolve']['nodes'][0]['dependencies'].append('git2'); f.save()
    value=f.good(); assert value['package_count']==3 and value['root_count']==2
check('multiple Git workspace packages share one complete root inventory', root_shared)


def unsafe(f, action):
    action(f); f.save(); f.bad(); assert not f.receipt.exists()
check('symlink dependency files fail before publication', lambda f: unsafe(f, lambda x: (x.registry/'alias').symlink_to(x.root)))
check('directory symlinks fail before traversal', lambda f: unsafe(f, lambda x: (x.registry/'subdir').symlink_to(x.git, target_is_directory=True)))
check('FIFO members are rejected without blocking', lambda f: unsafe(f, lambda x: os.mkfifo(x.registry/'fifo')))
check('unsafe control characters in source names fail', lambda f: unsafe(f, lambda x: (x.registry/'bad\nname').write_text('bad')))
check('unknown remote source types fail closed', lambda f: unsafe(f, lambda x: x.graph['packages'][1].update(source='unrecognized+location')))
check('registry identity cannot point at a differently named crate', lambda f: unsafe(f, lambda x: x.graph['packages'][1].update(name='other')))
check('target source cannot escape a dependency boundary', lambda f: unsafe(f, lambda x: x.graph['packages'][1].update(targets=[{'src_path':str(x.app/'lib.rs')}])) )
check('missing dependency target sources fail', lambda f: unsafe(f, lambda x: x.graph['packages'][1].update(targets=[{'src_path':str(x.registry/'missing.rs')}])) )
check('missing resolved nodes fail', lambda f: unsafe(f, lambda x: x.graph['resolve']['nodes'][0]['dependencies'].append('missing')))
check('duplicate package IDs fail', lambda f: unsafe(f, lambda x: x.graph['packages'].append(x.graph['packages'][0])))
check('duplicate resolve nodes fail', lambda f: unsafe(f, lambda x: x.graph['resolve']['nodes'].append(x.graph['resolve']['nodes'][0])))
check('invalid selected package IDs fail', lambda f: f.bad(selected='["missing"]'))
check('duplicate selected package IDs fail', lambda f: f.bad(selected='["app","app"]'))
check('receipt inside a dependency source tree fails', lambda f: f.bad(receipt=f.registry/'receipt.json'))


def occupied(f):
    f.good(); before=f.receipt.read_bytes(); f.bad(); assert before==f.receipt.read_bytes()
check('occupied receipt is never overwritten', occupied)


def bad_receipt(f):
    f.good(); f.receipt.write_text('{"schema_version":1,"schema_version":1}')
    f.bad('verify')
check('duplicate fields in retained evidence fail', bad_receipt)


def ancestor(f):
    moved=f.root/'retained home'; f.home.rename(moved); f.home.symlink_to(moved, target_is_directory=True)
    f.bad()
check('a symlink ancestor cannot authorize cached source paths', ancestor)


def git_administration(f):
    subprocess.run(['git','init','--quiet','-b','main',str(f.git)],check=True)
    subprocess.run(['git','-C',str(f.git),'add','.'],check=True)
    before=f.good()
    (f.git/'.git/index').write_bytes(b'changed administrative data')
    assert f.good('verify')==before
    evidence=json.loads(f.receipt.read_bytes())
    tree=next(t for t in evidence['roots'] if t['kind']=='git')
    assert '.git' in tree['directories'] and not any(p['path'].startswith('.git/') for p in tree['files'])
check('Git administrative changes are distinct from dependency source changes', git_administration)
check('external Git administrative pointers are refused', lambda f: unsafe(f, lambda x: (x.git/'.git').write_text('gitdir: /outside')))


def actual_git_compile(f):
    assert shutil.which('git') and shutil.which('cc'), 'requires Git and a C compiler'
    subprocess.run(['git','init','--quiet','-b','main',str(f.git)],check=True)
    subprocess.run(['git','-C',str(f.git),'add','.'],check=True)
    subprocess.run(['git','-C',str(f.git),'-c','user.name=DSR Test','-c','user.email=dsr@example.invalid',
                    'commit','--quiet','-m','dependency fixture'],check=True)
    source=f.root/'probe.c'; source.write_text('#include "shared.h"\nint main(void) { return VALUE; }\n')
    f.good()
    executable=f.root/'probe'
    subprocess.run(['cc','-I',str(f.git),str(source),'-o',str(executable)],check=True)
    assert subprocess.run([str(executable)]).returncode==42
    (f.git/'shared.h').write_text('#define VALUE 43\n')
    subprocess.run(['cc','-I',str(f.git),str(source),'-o',str(f.root/'changed')],check=True)
    assert subprocess.run([str(f.root/'changed')]).returncode==43
    f.bad('verify')
check('real Git dependency header changes compiled behavior and fails admission', actual_git_compile)

print('\nCargo dependency sources: %d passed, %d failed' % (passed, failed))
sys.exit(bool(failed))
PY
