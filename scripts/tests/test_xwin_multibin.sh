#!/usr/bin/env bash
# Exercise multi-binary admission through the real source/toolchain/build path.
# Git, LLVM NEON compilation, import libraries and ARM64 linking are real;
# Cargo/rustc/cargo-xwin are explicit protocol fixtures, not a Rust build.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 git jq clang lld-link llvm-ar timeout setsid zip unzip; do
    command -v "$tool" >/dev/null || { printf 'SKIP multi-binary xwin: requires %s\n' "$tool"; exit 0; }
done
[[ $(uname -s) == Linux ]] || { printf 'SKIP multi-binary xwin: requires Linux\n'; exit 0; }
python3 - "${XWIN_TEST_ROOT:-$ROOT}" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix='dsr-xwin-multibin-'))
passes = 0

def check(label, condition):
    global passes
    if not condition:
        raise AssertionError(label)
    passes += 1
    print('PASS ' + label, flush=True)

def run(*args, **kwargs):
    return subprocess.run(list(args), check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)

def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def read(path):
    return json.loads(path.read_text())

try:
    inputs, tools = work/'inputs', work/'tools'
    library = inputs/'sdk/lib/aarch64-unknown-windows-msvc/kernel32.lib'
    library.parent.mkdir(parents=True)
    write(inputs/'sdk/include/windows.h', '/* SDK fixture */\n')
    write(work/'kernel.c', 'int DsrKernelStub(void) { return 42; }\n')
    run('clang', '--target=aarch64-pc-windows-msvc', '-ffreestanding', '-c', str(work/'kernel.c'), '-o', str(work/'kernel.obj'))
    run('lld-link', '/dll', '/noentry', '/machine:arm64', '/export:DsrKernelStub',
        '/out:'+str(work/'kernel32.dll'), '/implib:'+str(library), str(work/'kernel.obj'))
    resource = Path(run('clang', '-print-resource-dir').stdout.decode().strip())/'include'
    headers = inputs/'llvm/include'; headers.mkdir(parents=True)
    for header in ('arm_neon.h', 'arm_bf16.h', 'arm_vector_types.h', 'stdint.h'):
        if (resource/header).is_file():
            shutil.copyfile(resource/header, headers/header)
    run('tar', '-cJf', str(work/'sdk.tar.xz'), '-C', str(inputs), 'sdk')
    run('tar', '-czf', str(work/'headers.tar.gz'), '-C', str(inputs), 'llvm')
    # The command fixture is selected under both Cargo roles. The real LLVM
    # executables below are independently hash-pinned and execute normally.
    driver = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
role = Path(sys.argv[0]).name
if args == ['-vV'] or args == ['--version']:
    print(role + ' multi-binary protocol fixture 1'); sys.exit(0)
root = Path.cwd()
mode = (root/'mode').read_text().strip()
spec = [('server', 'server-package'), ('client', 'client-package')]
if mode == 'same-package': spec = [(b, 'workspace-package') for b, _ in spec]
def identity(package): return 'path+file://' + str(root) + '#' + package + '@1.2.3'
with (Path(os.environ['HOME']).parent/'protocol-calls').open('a') as log:
    log.write(role + '\n')
if role == 'cargo':
    assert args[0] == 'metadata' and '--locked' in args and '--offline' in args
    packages = []
    for package in sorted({p for _, p in spec}):
        selected = [b for b, p in spec if p == package]
        version = '9.9.9' if mode == 'bad-version' and 'client' in selected else '1.2.3'
        binaries = [{'name':b, 'kind':['bin'], 'src_path':str(root/b/'main.rs')} for b in selected]
        if mode == 'metadata-missing': binaries = [b for b in binaries if b['name'] != 'client']
        if mode == 'inactive-feature':
            for b in binaries:
                if b['name'] == 'client': b['required-features'] = ['not-selected']
        packages.append({'id':identity(package), 'name':package, 'version':version, 'source':None,
                         'manifest_path':str(root/selected[0]/'Cargo.toml'), 'targets':binaries})
    members = [p['id'] for p in packages]
    nodes = [{'id':i, 'dependencies':[], 'features':[], 'deps':[]} for i in members]
    print(json.dumps({'version':1, 'workspace_root':str(root), 'workspace_members':members,
        'workspace_default_members':members, 'packages':packages,
        'resolve':{'root':None, 'nodes':nodes}, 'target_directory':os.environ['CARGO_TARGET_DIR']}))
    sys.exit(0)
assert role == 'cargo-xwin' and args[:2] == ['xwin', 'build']
assert '--release' in args and '--locked' in args and '--offline' in args
binaries = [args[i+1] for i, v in enumerate(args) if v == '--bin']
packages = [args[i+1] for i, v in enumerate(args) if v == '--package']
release = '--message-format=json' in args
if release: assert sorted(packages) == sorted({p for b, p in spec if b in binaries})
assert os.environ['XWIN_CROSS_COMPILER'] == 'clang' and not os.environ.get('UNRELATED_SECRET')
output = Path(os.environ['CARGO_TARGET_DIR'])/'aarch64-pc-windows-msvc/release'
output.mkdir(parents=True)
messages = []
for binary in binaries:
    exe = output/(binary+'.exe')
    if binary == 'client' and mode == 'fail-secondary': sys.exit(42)
    obj = Path(os.environ['TMPDIR'])/(binary+'.obj')
    if binary == 'client' and mode == 'wrong-arch-secondary':
        source = Path(os.environ['TMPDIR'])/'x64.c'; source.write_text('int mainCRTStartup(void) {return 3;}\n')
        subprocess.run(['clang', '--target=x86_64-pc-windows-msvc', '-ffreestanding', '-c', str(source), '-o', str(obj)], check=True)
        subprocess.run(['lld-link', '/entry:mainCRTStartup', '/subsystem:console', '/nodefaultlib', '/machine:x64', '/out:'+str(exe), str(obj)], check=True)
    else:
        subprocess.run(['clang', '--target=aarch64-pc-windows-msvc', '-ffreestanding'] + os.environ['CFLAGS'].split() +
                       ['-c', str(root/binary/'main.c'), '-o', str(obj)], check=True)
        subprocess.run(['lld-link', '/entry:mainCRTStartup', '/subsystem:console', '/nodefaultlib', '/machine:arm64',
                        '/out:'+str(exe), str(obj), 'Kernel32.lib'], check=True)
    package = dict(spec)[binary]
    message = {'reason':'compiler-artifact', 'package_id':identity(package),
        'target':{'name':binary, 'kind':['bin'], 'src_path':str(root/binary/'main.rs')},
        'features':[], 'profile':{'test':False}, 'executable':str(exe)}
    if binary == 'client':
        if mode == 'missing-secondary': exe.rename(exe.with_suffix('.hidden'))
        if mode == 'truncated-secondary': exe.write_bytes(exe.read_bytes()[:64])
        if mode == 'linked-secondary': exe.rename(exe.with_suffix('.hidden')); exe.symlink_to(exe.with_suffix('.hidden'))
        if mode == 'source-drift': (root/binary/'main.rs').write_text('// changed\n')
        if mode == 'wrong-package': message['package_id'] = identity('server-package')
        if mode == 'wrong-source': message['target']['src_path'] = str(root/'server/main.rs')
        if mode == 'wrong-features': message['features'] = ['unwanted']
        if mode == 'test-profile': message['profile']['test'] = True
        if mode == 'missing-message': continue
        if mode == 'duplicate-message': messages.append(message)
    messages.append(message)
if mode == 'unexpected-binary':
    extra = json.loads(json.dumps(messages[0])); extra['target']['name'] = 'unplanned'; messages.append(extra)
finished = {'reason':'build-finished', 'success':True}
if mode == 'early-finish': messages.insert(0, finished)
else: messages.append(finished)
if release:
    for message in messages: print(json.dumps(message))
'''
    for role in ('cargo', 'cargo-xwin', 'rustc'):
        write(tools/role, driver); (tools/role).chmod(0o755)
    pins = {}
    for role in ('cargo', 'cargo-xwin', 'rustc', 'clang', 'lld-link', 'llvm-ar'):
        path = tools/role if role in ('cargo', 'cargo-xwin', 'rustc') else Path(shutil.which(role)).resolve()
        pins[role] = {'path':str(path), 'sha256':sha(path)}
    manifest = work/'toolchain.json'
    manifest.write_text(json.dumps({'schema_version':1, 'target':'aarch64-pc-windows-msvc', 'tools':pins,
        'sysroot':{'path':str(work/'sdk.tar.xz'), 'sha256':sha(work/'sdk.tar.xz'), 'prefix':'sdk', 'url':'https://example.invalid/pinned/sdk.tar.xz'},
        'headers':{'path':str(work/'headers.tar.gz'), 'sha256':sha(work/'headers.tar.gz'), 'prefix':'llvm/include', 'url':'https://example.invalid/pinned/headers.tar.gz'},
        'aliases':{'Kernel32.lib':'kernel32.lib'}}))
    def project(mode):
        p = work/('project-'+mode); p.mkdir()
        write(p/'Cargo.toml', '[workspace]\nmembers=["server","client"]\n')
        write(p/'Cargo.lock', 'version = 3\n')
        write(p/'mode', mode+'\n')
        for number, binary in enumerate(('server', 'client'), 1):
            write(p/binary/'Cargo.toml', f'[package]\nname="{binary}-package"\nversion="1.2.3"\n')
            write(p/binary/'main.rs', 'fn main() {}\n')
            write(p/binary/'main.c', '#include <arm_neon.h>\n__declspec(dllimport) int DsrKernelStub(void);\n'
                  f'int mainCRTStartup(void) {{ uint8x8_t v=vdup_n_u8({number}); return DsrKernelStub()+vget_lane_u8(v,0); }}\n')
        write(p/'LICENSE', 'License bytes from the selected commit.\n')
        run('git', '-C', str(p), 'init', '-qb', 'main')
        run('git', '-C', str(p), 'config', 'user.name', 'DSR Test')
        run('git', '-C', str(p), 'config', 'user.email', 'test@example.invalid')
        run('git', '-C', str(p), 'remote', 'add', 'origin', 'https://github.com/owner/workspace.git')
        run('git', '-C', str(p), 'add', '.')
        run('git', '-C', str(p), '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
        run('git', '-C', str(p), 'tag', 'v1.2.3')
        return p, run('git', '-C', str(p), 'rev-parse', 'HEAD').stdout.decode().strip()
    def build(mode, expected=0, binaries=('server','client'), extra=(), release=True):
        p, commit = project(mode)
        output = work/('run-'+mode)
        command = ['bash', str(root/'scripts/xwin-build.sh'), '--manifest', str(manifest), '--project', str(p),
                   '--run-dir', str(output), '--cache-dir', str(work/'cache'), '--offline']
        for binary in binaries: command += ['--bin', binary]
        if release:
            command += ['--tool', 'workspace', '--release-repo', 'owner/workspace', '--release-tag', 'v1.2.3', '--source-sha', commit]
        result = subprocess.run(command+list(extra), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
        if result.returncode != expected:
            print(result.stderr.decode(), file=sys.stderr)
            for log in output.glob('*.log'): print(log.read_text(), file=sys.stderr)
            raise AssertionError(f'{mode}: expected {expected}, got {result.returncode}')
        check(mode+' returns expected status', result.returncode == expected)
        if expected:
            check(mode+' emits no successful result', not result.stdout and not (output/'release').exists())
            if (output/'failure.json').exists(): check(mode+' retains failure code', read(output/'failure.json')['exit_code']==expected)
            return output
        receipt = json.loads(result.stdout)
        check(mode+' stdout equals retained receipt', result.stdout == (output/('release/result.json' if release else 'result.json')).read_bytes())
        check(mode+' leaves original source unchanged', not run('git', '-C', str(p), 'status', '--porcelain').stdout)
        return output, receipt
    good, receipt = build('cross-package')
    check('two binaries are retained, without a misleading single artifact', len(receipt['artifacts'])==2 and 'artifact' not in receipt)
    check('each independently linked binary has different bytes', len({a['sha256'] for a in receipt['artifacts']})==2)
    check('both executables pass ARM64 PE admission', all(a['machine_code']==0xAA64 and a['format']=='PE32+' for a in receipt['artifacts']))
    check('one Cargo invocation builds both selected packages', (good/'protocol-calls').read_text().splitlines()==['cargo','cargo-xwin','cargo'])
    m = read(good/'release/build-manifest.json')
    check('manifest counts one target and two payloads', m['summary']=={'total':1,'success':1,'failed':0} and len(m['artifacts'])==2)
    check('metadata retains both exact package/binary identities', len(m['build_environments'][0]['cargo_metadata']['binaries'])==2)
    check('command contains each binary and package exactly once', read(good/'command.json').count('--bin')==2 and read(good/'command.json').count('--package')==2)
    proof = run('bash', '-c', 'source "$1/src/slsa.sh"; _slsa_manifest_statement "$2" owner/workspace test:multi', '_', str(root), str(good/'release/build-manifest.json')).stdout
    write(work/'proof.json', proof.decode())
    run('bash', '-c', 'source "$1/src/slsa.sh"; _slsa_release_assets "$2" "$3"', '_', str(root), str(work/'proof.json'), str(good/'artifacts'))
    check('existing release/SLSA admission verifies every named output', len(json.loads(proof)['subject'])==2)
    same, _ = build('same-package')
    check('same-package binaries share a single package selection', read(same/'command.json').count('--package')==1)
    _, single = build('single', binaries=('server',), extra=('--asset-name','server-custom.exe'))
    check('single binary retains the scalar receipt and custom release name', single['artifact']==single['artifacts'][0] and single['artifact']['name']=='server-custom.exe')
    ordinary, raw = build('ordinary', release=False)
    check('ordinary multi-binary mode also validates every output', [a['name'] for a in raw['artifacts']]==['server.exe','client.exe'])
    for mode in ('metadata-missing','bad-version','inactive-feature','missing-message','duplicate-message','wrong-package',
                 'wrong-source','wrong-features','test-profile','unexpected-binary','early-finish','missing-secondary',
                 'truncated-secondary','linked-secondary','wrong-arch-secondary','source-drift'):
        output = build(mode, 7)
        if mode in ('metadata-missing','bad-version','inactive-feature'):
            check(mode+' stops before compilation', 'cargo-xwin' not in (output/'protocol-calls').read_text())
    build('fail-secondary', 42)
    for mode, bins, extra in (
        ('duplicate-bin', ('server','server'), ()), ('case-collision', ('server','SERVER'), ()),
        ('unsafe-bin', ('server','../client'), ()), ('single-name-for-multiple', ('server','client'), ('--asset-name','one.exe')),
    ):
        output = build(mode, 4, binaries=bins, extra=extra)
        check(mode+' rejected before creating a run', not output.exists())
    print(f'\nWindows ARM64 multi-binary release: {passes} passed, 0 failed', flush=True)
except Exception:
    print('Retained failing fixture: '+str(work), file=sys.stderr)
    raise
else:
    shutil.rmtree(work)
PY
