#!/usr/bin/env bash
# Real native archive-branch, Git-source and collection-receipt regressions.
# No remote build execution, signing or GitHub publication is claimed.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 3; }
python3 - "$ROOT" <<'PY'
#!/usr/bin/env python3
"""Exercise the real native packaging block and its collection validators.

Git, compilers, archive tools, source staging, hashes and receipts are real.
Naming is an explicit fixture at the existing naming-API boundary. JSON/YAML
parsing is production yq unless DSR_TEST_ACT_RUNNER selects an isolated runtime.
This is archive integration, not remote-host/Rust compilation or publication.
"""
import copy
import errno
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile

root = Path(sys.argv[1])
module = Path(os.environ.get('DSR_TEST_ACT_RUNNER', str(root / 'src/act_runner.sh')))
for tool in ('bash','git','jq','cc','tar','gzip','zip','unzip','xz'):
    if not shutil.which(tool):
        print('Missing required test dependency: '+tool,file=sys.stderr)
        raise SystemExit(3)
parser = subprocess.run(['bash','-c','source "$1" && command -v yq >/dev/null','_',str(module)],capture_output=True)
if parser.returncode:
    print('Sourceable act_runner.sh and Mike Farah yq v4 are required',file=sys.stderr)
    raise SystemExit(3)
work = Path(tempfile.mkdtemp(prefix='dsr-native-single-'))
passed = 0
skipped = 0

# Run the exact production writer with a real selected implementation. A
# symlink changes PATH lookup only; no archive contents or options are mocked.
# CI requires each lane explicitly so missing bsdtar never becomes a skip.
tar_implementation = os.environ.get('DSR_TEST_TAR', '')
if tar_implementation:
    if tar_implementation not in ('gnu', 'bsd'):
        raise SystemExit('DSR_TEST_TAR must be gnu or bsd')
    if tar_implementation == 'gnu':
        candidates = ('gtar', 'tar')
    elif platform.system() == 'Darwin':
        candidates = ('/usr/bin/tar', 'bsdtar', 'tar')
    else:
        candidates = ('bsdtar', 'tar')
    tar_binary = None
    for candidate in candidates:
        executable = shutil.which(candidate)
        if not executable:
            continue
        version = subprocess.run([executable, '--version'], capture_output=True, text=True, timeout=10)
        marker = 'GNU tar' if tar_implementation == 'gnu' else 'bsdtar'
        if version.returncode == 0 and marker in version.stdout:
            tar_binary = Path(executable).resolve()
            break
    if tar_binary is None:
        raise SystemExit('Required real archive implementation unavailable: ' + tar_implementation)
    tool_dir = work / 'archive-tools'
    tool_dir.mkdir()
    (tool_dir / 'tar').symlink_to(tar_binary)
    os.environ['PATH'] = str(tool_dir) + os.pathsep + os.environ['PATH']
tar_version = subprocess.run(['tar', '--version'], capture_output=True, text=True, check=True).stdout.splitlines()[0]
print('Real archive implementation: ' + tar_version, flush=True)

def check(label, condition):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print('PASS ' + label, flush=True)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def write(path, value):
    path.write_text(json.dumps(value))

def command(arguments, **kw):
    return subprocess.run(list(map(str, arguments)), capture_output=True, check=True, timeout=60, **kw)

def shell(function, *args, rc=0):
    p = subprocess.run(['bash', '-c', 'source "$1"; shift; "$@"', '_', str(module), function, *map(str,args)], capture_output=True, timeout=60)
    check(function + ' exit ' + str(rc), p.returncode == rc)
    return p.stdout.decode().rstrip('\n')

def selection(label, value, target='linux/amd64', expected='app', rc=0, function='_act_workspace_binaries_for_target', purpose=None, inherited=False):
    file = work / ('selection-' + str(passed) + '.json')
    file.write_text(value if isinstance(value, str) else json.dumps(value))
    program = 'source "$1"; shift; "$@"'
    extra = []
    if purpose is not None:
        if inherited:
            program = 'source "$1"; build_purpose="$2"; shift 2; "$@"'
            extra = [purpose]
        else:
            extra = []
    args = ['bash','-c',program,'_',str(module),*extra,function,str(file),target]
    if purpose is not None and not inherited:
        args += [purpose]
    p = subprocess.run(args,capture_output=True,timeout=20)
    check(label, p.returncode == rc and p.stdout.decode().rstrip('\n') == expected)

base_selection = {'binary_name':'app','release_contract':{'exact_primary_assets':{'linux/amd64':'app.tar.xz'}}}
for target in ('linux/amd64','linux/arm64','darwin/amd64','darwin/arm64','windows/amd64','windows/arm64'):
    for ext in ('tar.gz','tgz','tar.xz','zip'):
        value = {'binary_name':'app','release_contract':{'exact_primary_assets':{target:'selected.'+ext}}}
        selection(target+' '+ext+' selects the primary inventory',value,target)
        selection(target+' '+ext+' selects the exact compression',value,target,
                  expected='tar.gz' if ext=='tgz' else ext,function='_act_workspace_archive_format')
selection('legacy unconfigured single binary stays raw',{'binary_name':'app'},expected='')
selection('null contract retains legacy behavior',{'binary_name':'app','release_contract':None},expected='')
selection('raw closed primary stays raw',{'binary_name':'app','release_contract':{'exact_primary_assets':{'linux/amd64':'app'}}},expected='')
selection('workspace preserves every member',dict(base_selection,workspace_binaries=['app','helper']),expected='app\nhelper')
selection('empty global list uses single primary',dict(base_selection,workspace_binaries=[]))
selection('target override wins',dict(base_selection,workspace_binaries_by_target={'linux/amd64':['lite']}),expected='lite')
selection('empty archive override discards global workspace',dict(base_selection,workspace_binaries=['helper'],workspace_binaries_by_target={'linux/amd64':[]}))
selection('empty legacy override remains empty',{'binary_name':'app','workspace_binaries':['helper'],'workspace_binaries_by_target':{'linux/amd64':[]}},expected='')
selection('other target overrides do not drop primary',dict(base_selection,workspace_binaries_by_target={'darwin/arm64':['other']}))
selection('Windows primary suffix is normalized',{'binary_name':'App.EXE','release_contract':{'exact_primary_assets':{'windows/amd64':'app.zip'}}},'windows/amd64',expected='App.exe')
for name in (None,3,'','../app','app name','app.sha256'):
    selection('invalid primary binary '+repr(name),dict(base_selection,binary_name=name),expected='',rc=4)
for value in ('{}\n{}','null','[]','false',dict(base_selection,release_contract=False),dict(base_selection,workspace_binaries='app'),
              dict(base_selection,workspace_binaries_by_target=[]),{'release_contract':{}},dict(base_selection,release_contract={'exact_primary_assets':{}})):
    selection('invalid or incomplete native inventory '+str(value),value,expected='',rc=4)
for value in ('tar.xz',{'linux':'tar.xz'}):
    selection('explicit matching compression '+str(value),dict(base_selection,archive_format=value),expected='tar.xz',function='_act_workspace_archive_format')
for value in ('zip',{'linux':'tar.gz'},False,7,[],{'linux':False},{'linux':'rar'}):
    selection('invalid or conflicting compression '+str(value),dict(base_selection,archive_format=value),expected='',rc=4,function='_act_workspace_archive_format')
for target,expected in (('linux/amd64','tar.gz'),('windows/amd64','zip')):
    selection('legacy format default '+target,{},target,expected=expected,function='_act_workspace_archive_format')
selection('multiple format documents refuse','{}\n{}',expected='',rc=4,function='_act_workspace_archive_format')
for inherited in (False,True):
    selection('diagnostic singleton keeps existing raw collection',base_selection,expected='',purpose='diagnostic-native',inherited=inherited)
    selection('diagnostic workspace selection remains complete',dict(base_selection,workspace_binaries=['app','helper']),
              expected='app\nhelper',purpose='diagnostic-native',inherited=inherited)
    selection('diagnostic format does not infer release-only compression',base_selection,expected='tar.gz',
              function='_act_workspace_archive_format',purpose='diagnostic-native',inherited=inherited)
    selection('release context still selects complete singleton archive',base_selection,purpose='release',inherited=inherited)
selection('unknown archive-selection purpose refuses',base_selection,expected='',rc=4,purpose='other')
for name in ('app','app.exe','app.EXE','app.ExE'):
    result = shell('act_get_remote_artifact_path','go',r'C:\build dir\release','',name,'windows/arm64')
    check('Windows collection does not double executable suffix: '+name,result=='C:/build dir/release/app.exe')
for name in ('app','app.exe','app.EXE'):
    result = shell('act_get_remote_artifact_path','go','/build dir/release','',name,'linux/amd64')
    check('Unix artifact spelling stays exact: '+name,result=='/build dir/release/'+name)

# Extract the actual native branch: no hand-maintained alternate implementation.
# The isolated-run override must contain this exact production block and is
# reported separately; it is not evidence of executing the complete coordinator.
source = module.read_text()
if os.environ.get('DSR_TEST_NATIVE_PACKAGE_BLOCK'):
    block = Path(os.environ['DSR_TEST_NATIVE_PACKAGE_BLOCK']).read_text()
else:
    begin = '        # Package workspace binaries into a single tarball\n'
    # Stop at the next outer result branch. Readiness and timeout handling
    # are outside this archive-only fixture; retain the whole success block.
    end = '\n    elif [['
    if source.count(begin) != 1:
        raise AssertionError('native packaging block is ambiguous or unavailable')
    start = source.index(begin)
    block = source[start:source.index(end, start)]

# Exercise the production strict companion collection and failure handoff as
# well as packaging, so a test cannot manufacture the receipt the runner lost.
collect_begin = '        # Collect configured non-binary package members separately from the\n'
collect_end = '        # Package workspace binaries into a single tarball\n'
if source.count(collect_begin) != 1 or source.count(collect_end) != 1:
    raise AssertionError('native companion collection block is ambiguous or unavailable')
collection_block = source[source.index(collect_begin):source.index(collect_end)]

driver = work / 'package-driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$1" || exit $?
source "$(dirname "$1")/config.sh" || exit $?
# Naming is an explicit configuration boundary, not simulated archive evidence.
# Its exact-primary behavior has a separate production naming regression suite.
artifact_naming_generate_dual_for_tool() {
    jq -cn --arg name "$(jq -r --arg target "$platform" '.release_contract.exact_primary_assets[$target]' "$config_file")" \
        '{versioned:$name,compat:$name,same:true}'
}
_test_mutate_companion() {
    python3 - "$1" "$DSR_TEST_COMPANION_MUTATION" "$DSR_TEST_COMPANION_PROOF" <<'MUTATE'
import hashlib
import json
from pathlib import Path
import stat
import sys
path=Path(sys.argv[1])
def snapshot():
    info=path.stat()
    return {'inode':info.st_ino,'mode':stat.S_IMODE(info.st_mode),'size':info.st_size,
            'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
before=snapshot()
if sys.argv[2]=='content':
    original=path.read_bytes()
    replacement=original.replace(b'original',b'REPLACED',1)
    assert replacement!=original and len(replacement)==len(original)
    path.write_bytes(replacement)
elif sys.argv[2]=='mode':
    path.chmod(0o750 if before['mode'] & 0o111 else 0o640)
elif sys.argv[2]=='inode':
    payload=path.read_bytes()
    path.rename(path.with_name(path.name+'.retained-original'))
    with path.open('xb') as output:
        output.write(payload)
    path.chmod(before['mode'])
else:
    raise AssertionError('unknown companion mutation')
Path(sys.argv[3]).write_text(json.dumps({'before':before,'after':snapshot()}))
MUTATE
}
definition=$(declare -f _act_collect_stream_exclusive) || exit 98
eval "${definition/#_act_collect_stream_exclusive /_test_real_collect }"
_act_collect_stream_exclusive() {
    local receipt
    receipt=$(_test_real_collect "$@") || return $?
    printf '%s\n' "$receipt" >> "$DSR_TEST_COLLECTION_LOG"
    if [[ "$DSR_TEST_COMPANION_PHASE" == handoff &&
          "$1" == "$artifact_dir/$DSR_TEST_COMPANION_MEMBER" ]]; then
        _test_mutate_companion "$1" || return $?
    fi
    # This remains the original collector's receipt even after the fault.
    printf '%s\n' "$receipt"
}
_test_native_packaging() {
    local config_file="$2" local_path="$3" release_git_sha="$4"
    local platform="$5" artifact_dir="$6" compiled="$7"
    local tool_name=app version=v1.2.3 strict_native_build=true selected_triple=''
    # The extracted branch inherits this context from act_run_native_build.
    # Exercise release packaging; do not let nounset abort before validation.
    local build_purpose=release
    local status=success exit_code=0 log_file="$artifact_dir/build.log"
    local collected_sha256='' collected_size_bytes=0 collected_identity=''
    local workspace_binaries binary_name bin receipt
    local local_artifact_path=''
    local -a local_artifact_paths=() strict_collection_receipts=() workspace_member_receipts=()
    local -a additional_artifact_receipts=()
    local host=act language=go build_env='' build_profile=release ssh_destination=''
    local artifact_source_root="$DSR_TEST_ARCHIVE_INPUTS" output_stage_root='' additional_json='[]'
    local download_failed=false
    workspace_binaries=$(_act_workspace_binaries_for_target "$config_file" "$platform") || return $?
    binary_name=$(jq -r '.binary_name' "$config_file") || return 4
    bin="$binary_name"
    [[ "$platform" != windows/* ]] || bin="${binary_name%.exe}.exe"
    local mode=700
    [[ "$platform" != windows/* ]] || mode=600
    receipt=$(_act_collect_stream_exclusive "$artifact_dir/$bin" "$mode" _act_stream_local_file "$compiled") || return $?
    local_artifact_paths=("$artifact_dir/$bin")
    strict_collection_receipts=("$receipt")
    workspace_member_receipts+=("$(_act_workspace_member_receipt "$artifact_dir" "$bin" "$receipt" "$mode")") || return $?
    printf '%s\n' "$receipt" > "$artifact_dir/binary-collection.json"
    if [[ ${DSR_TEST_TAMPER_COLLECTED:-0} == 1 ]]; then
        printf changed >> "$artifact_dir/$bin"
    fi
''' + collection_block + r'''
    if [[ "$DSR_TEST_COMPANION_PHASE" == prearchive && "$status" == success ]]; then
        _test_mutate_companion "$artifact_dir/$DSR_TEST_COMPANION_MEMBER" || return $?
    fi
''' + block + r'''
    jq -nc --arg status "$status" --argjson exit_code "$exit_code" \
        --arg path "$local_artifact_path" --arg sha "$collected_sha256" \
        --argjson size "$collected_size_bytes" --arg identity "$collected_identity" \
        '{status:$status,exit_code:$exit_code,artifact_path:$path,collected_sha256:$sha,
          collected_size_bytes:$size,collected_identity:$identity}'
    return "$exit_code"
}
_test_native_packaging "$@"
''')
command(['bash','-n',driver])

repo = work / 'source'
repo.mkdir()
def git(*args):
    return command(['git','-C',repo,*args]).stdout.decode().strip()
git('init','-q')
git('config','user.name','DSR Archive Test')
git('config','user.email','archive-test@example.invalid')
git('config','core.autocrlf','false')
(repo / 'docs').mkdir()
committed = {'LICENSE': (b'Complete license\nAdditional rider\n', 0o644),
             'docs/README.md': (b'Release README\n$Format:%H$\n', 0o644),
             'install.sh': (b'#!/bin/sh\nexit 0\n', 0o755),
             'EMPTY': (b'', 0o644)}
for name,(data,mode) in committed.items():
    p = repo / name
    p.write_bytes(data)
    p.chmod(mode)
(repo / 'app').write_text('not the compiled program')
(repo / 'linked').symlink_to('LICENSE')
(repo / '.gitattributes').write_text('LICENSE export-ignore\ndocs/README.md export-subst\n')
git('add','.')
git('commit','-qm','Pinned source companions')
revision = git('rev-parse','HEAD')
# Deliberately dirty for the companion-stage unit: full strict command admission
# still requires clean HEAD/tag and is NOT exercised or bypassed by this test.
(repo / 'LICENSE').write_text('uncommitted replacement')
(repo / 'install.sh').chmod(0o644)
source_status = git('status','--porcelain=v1')

source_c = work / 'fixture.c'
source_c.write_text('int main(void) { return 17; }\n')
fixtures = {}
host = {'Linux':'linux','Darwin':'darwin'}.get(platform.system(),'') + '/' + {'x86_64':'amd64','arm64':'arm64','aarch64':'arm64'}.get(platform.machine(),'')
cc = shutil.which('cc')
if not cc or host not in ('linux/amd64','linux/arm64','darwin/amd64','darwin/arm64'):
    raise SystemExit('native archive test requires a supported host and C compiler')
local_binary = work / 'native-app'
command([cc,source_c,'-o',local_binary])
check('actual host-compiled binary executes',subprocess.run([str(local_binary)],timeout=10).returncode == 17)
fixtures[host] = local_binary
clang = shutil.which('clang')
if clang:
    for arch,triple in [('amd64','x86_64'),('arm64','aarch64')]:
        target = 'windows/'+arch
        linker = shutil.which('lld-link')
        if linker:
            obj = work / ('windows-'+arch+'.obj')
            binary = work / ('windows-'+arch+'.exe')
            command([clang,'--target='+triple+'-pc-windows-msvc','-c',source_c,'-o',obj])
            command([linker,'/entry:main','/subsystem:console','/nodefaultlib','/out:'+str(binary),obj])
            fixtures[target] = binary
        target = 'darwin/'+arch
        linker = shutil.which('ld64.lld')
        if target not in fixtures and linker:
            obj = work / ('darwin-'+arch+'.o')
            binary = work / ('darwin-'+arch)
            cpu = 'arm64' if arch=='arm64' else 'x86_64'
            command([clang,'--target='+cpu+'-apple-macos11','-c',source_c,'-o',obj])
            try:
                command([linker,'-arch',cpu,'-platform_version','macos','11.0','11.0','-e','_main','-o',binary,obj])
            except subprocess.CalledProcessError as error:
                # Some LLVM distributions ship ld64.lld without macOS linking.
                # Do not substitute a fake Mach-O executable or claim coverage.
                print('Cross compiler unavailable for '+target+': '+error.stderr.decode().splitlines()[0],flush=True)
            else:
                fixtures[target] = binary
    if 'linux/arm64' not in fixtures and shutil.which('ld.lld'):
        binary = work / 'linux-arm64'
        command([clang,'--target=aarch64-linux-gnu','-fuse-ld=lld','-nostdlib','-Wl,-e,main',source_c,'-o',binary])
        fixtures['linux/arm64'] = binary
for target in ('linux/amd64','linux/arm64','darwin/amd64','darwin/arm64','windows/amd64','windows/arm64'):
    if target not in fixtures:
        skipped += 1
        print('SKIP actual cross-compiled fixture unavailable: '+target)

base = {'binary_name':'app', 'include_files':list(committed),
        'targets':list(fixtures), 'release_contract':{'exact_primary_assets':{}}}
for target in fixtures:
    base['release_contract']['exact_primary_assets'][target] = 'app-'+target.replace('/','-')+'.tar.xz'

def read_archive(path, fmt):
    if fmt=='zip':
        with zipfile.ZipFile(path) as z:
            return {m.filename:(z.read(m),stat.S_IMODE(m.external_attr >> 16)) for m in z.infolist()}
    with tarfile.open(path,'r:*') as t:
        return {m.name:(t.extractfile(m).read(),m.mode) for m in t.getmembers() if m.isfile()}

def inspect_tar_metadata(path, expected, label):
    with tarfile.open(path, 'r:*') as package:
        members = package.getmembers()
        check(label + ' exact regular member inventory',
              len(members) == len(expected) and {m.name for m in members} == set(expected)
              and all(m.isfile() and not m.islnk() for m in members))
        check(label + ' published modes are exactly 0755/0644',
              all(m.mode == expected[m.name][1] for m in members))
        check(label + ' numeric owners and groups are 0/0',
              all(m.uid == 0 and m.gid == 0 for m in members))
        check(label + ' archive contains no account names',
              all(m.uname == '' and m.gname == '' and
                  not any(key.startswith(('SCHILY.acl.', 'SCHILY.xattr.', 'LIBARCHIVE.xattr.'))
                          for key in m.pax_headers) for m in members))
        check(label + ' complete member bytes survive normalization',
              all(package.extractfile(m).read() == expected[m.name][0] for m in members))

def inspect_archive_metadata(path, fmt, expected, label):
    if fmt != 'zip':
        inspect_tar_metadata(path, expected, label)
        return
    with zipfile.ZipFile(path) as package:
        members = package.infolist()
        check(label + ' exact regular member inventory',
              len(members) == len(expected) and {m.filename for m in members} == set(expected)
              and all(stat.S_ISREG(m.external_attr >> 16) for m in members))
        check(label + ' published modes are exactly 0755/0644',
              all(stat.S_IMODE(m.external_attr >> 16) == expected[m.filename][1] for m in members))
        check(label + ' ZIP omits host ownership extra records',all(m.extra == b'' for m in members))
        check(label + ' complete member bytes survive normalization',
              all(package.read(m) == expected[m.filename][0] for m in members))

def metadata_snapshot(path):
    value = path.stat()
    return (sha(path), value.st_dev, value.st_ino, value.st_mode,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns, value.st_ctime_ns)

def make_archive(path, fmt, members):
    if fmt=='zip':
        with zipfile.ZipFile(path,'w',compression=zipfile.ZIP_DEFLATED) as z:
            for n,(data,mode) in members.items():
                info=zipfile.ZipInfo(n)
                info.create_system=3
                info.external_attr=(stat.S_IFREG | mode) << 16
                z.writestr(info,data)
    else:
        with tarfile.open(path,'w:gz' if fmt=='tar.gz' else 'w:xz') as t:
            for n,(data,mode) in members.items():
                info=tarfile.TarInfo(n)
                info.size=len(data); info.mode=mode
                t.addfile(info,io.BytesIO(data))

def metadata_gate_regressions():
    # Change only metadata: valid payload bytes cannot excuse a private mode,
    # nonzero owner/group, account name, or ZIP ownership extra field.
    payload = b'unchanged metadata-gate payload\n'
    for fmt in ('tar.gz', 'tar.xz', 'zip'):
        good = work / ('metadata-gate-good.'+fmt)
        make_archive(good, fmt, {'app': (payload, 0o755)})
        shell('_act_validate_release_archive_metadata', good, fmt)
        mutations = [('mode', 0o700), ('mode', 0o4755)]
        if fmt == 'zip':
            mutations += [('extra', b'\x75\x78\x05\x00\x01\x01\x7b\x01\x2a')]
        else:
            mutations += [('uid', 123), ('gid', 456), ('uname', 'build-user'), ('gname', 'build-group')]
        for index, (field, value) in enumerate(mutations):
            bad = work / ('metadata-gate-'+str(index)+'.'+fmt)
            if fmt == 'zip':
                with zipfile.ZipFile(bad, 'w', compression=zipfile.ZIP_DEFLATED) as output:
                    item = zipfile.ZipInfo('app')
                    item.create_system = 3
                    item.external_attr = (stat.S_IFREG | (value if field == 'mode' else 0o755)) << 16
                    if field == 'extra':
                        item.extra = value
                    output.writestr(item, payload)
            else:
                with tarfile.open(bad, 'w:gz' if fmt == 'tar.gz' else 'w:xz') as output:
                    item = tarfile.TarInfo('app')
                    item.mode = 0o755
                    item.size = len(payload)
                    setattr(item, field, value)
                    output.addfile(item, io.BytesIO(payload))
            before = metadata_snapshot(bad)
            shell('_act_validate_release_archive_metadata', bad, fmt, rc=4)
            check(fmt+' rejects '+field+' metadata without rewriting evidence',before == metadata_snapshot(bad))

counter=0
generated_companions={'metadata.json':(b'{"release":"original"}\n',0o600),
                      'verify.sh':(b'#!/bin/sh\nprintf "original verifier\\n"\n',0o700)}

def package(config,target,expected=0,preexisting=False,tamper=False,companion_fault=None):
    global counter
    counter+=1
    folder=work/('case-'+str(counter)); folder.mkdir()
    cf=work/('case-'+str(counter)+'.json'); write(cf,config)
    config_dir=folder/'config'
    (config_dir/'repos.d').mkdir(parents=True)
    # Bind the production config reader to this exact case, never the user's
    # release registry. JSON is valid YAML and retains identical contract bytes.
    (config_dir/'repos.d/app.yaml').write_bytes(cf.read_bytes())
    inputs=folder/'generated-inputs'; inputs.mkdir()
    for name,(data,mode) in generated_companions.items():
        (inputs/name).write_bytes(data)
        (inputs/name).chmod(mode)
    path=folder/config['release_contract']['exact_primary_assets'][target]
    prior=None
    if preexisting:
        path.write_bytes(b'previous immutable archive')
        prior=(sha(path),path.stat().st_ino)
    p=subprocess.run(['bash',str(driver),str(module),str(cf),str(repo),revision,target,str(folder),str(fixtures[target])],
                     env=dict(os.environ,DSR_CONFIG_DIR=str(config_dir),
                              DSR_TEST_TAMPER_COLLECTED=str(int(tamper)),DSR_TEST_ARCHIVE_INPUTS=str(inputs),
                              DSR_TEST_COLLECTION_LOG=str(folder/'collection-handoffs.jsonl'),
                              DSR_TEST_COMPANION_PROOF=str(folder/'companion-mutation.json'),
                              DSR_TEST_COMPANION_PHASE=companion_fault[0] if companion_fault else '',
                              DSR_TEST_COMPANION_MEMBER=companion_fault[1] if companion_fault else '',
                              DSR_TEST_COMPANION_MUTATION=companion_fault[2] if companion_fault else ''),capture_output=True,timeout=90)
    (folder/'package.stdout').write_bytes(p.stdout)
    (folder/'package.stderr').write_bytes(p.stderr)
    if p.returncode!=expected:
        raise AssertionError(f'package expected {expected}, got {p.returncode}: {p.stdout.decode()}\n{p.stderr.decode()}')
    result=json.loads(p.stdout)
    check('one native packaging result matches process status',result['exit_code']==expected)
    if expected:
        check('packaging failure is not reported as success',result['status']=='failed')
    if prior:
        check('existing archive is not replaced or rewritten',prior==(sha(path),path.stat().st_ino))
    return result,cf,folder

for target,binary in fixtures.items():
    for fmt in ('tar.gz','tar.xz','zip'):
        cfg=copy.deepcopy(base)
        cfg['release_contract']['exact_primary_assets'][target]='app-'+target.replace('/','-')+'.'+fmt
        before=(sha(binary),binary.stat().st_ino,stat.S_IMODE(binary.stat().st_mode))
        result,cf,folder=package(cfg,target)
        archive=Path(result['artifact_path'])
        check(target+' '+fmt+' reaches automatic native archive branch',archive.name==cfg['release_contract']['exact_primary_assets'][target])
        bin_name='app.exe' if target.startswith('windows/') else 'app'
        expected=dict(committed)
        private_mode = 0o600 if target.startswith('windows/') else 0o700
        published_mode = 0o644 if target.startswith('windows/') else 0o755
        expected[bin_name]=(binary.read_bytes(),published_mode)
        check(target+' '+fmt+' exact executable and companion bytes/modes',read_archive(archive,fmt)==expected)
        inspect_archive_metadata(archive, fmt, expected, target+' '+fmt)
        check('collected binary retains its private mode',stat.S_IMODE((folder/bin_name).stat().st_mode)==private_mode)
        check('receipt binds completed archive hash/size',result['collected_sha256']==sha(archive) and result['collected_size_bytes']==archive.stat().st_size)
        snapshot=(sha(archive),archive.stat().st_ino,archive.stat().st_mtime_ns)
        shell('_act_validate_workspace_archive',archive,fmt,target,cf)
        shell('_act_validate_workspace_archive_release_tree_includes',archive,fmt,cf,repo,revision)
        binary_receipt=(folder/'binary-collection.json').read_text()
        shell('_act_validate_workspace_archive_collection_receipts',archive,fmt,target,cf,binary_receipt)
        check('same-format validation never recompresses or rewrites',snapshot==(sha(archive),archive.stat().st_ino,archive.stat().st_mtime_ns))
        check('compiler-produced bytes and mode remain untouched',before==(sha(binary),binary.stat().st_ino,stat.S_IMODE(binary.stat().st_mode)))
        thin=folder/('old-thin.'+fmt)
        make_archive(thin,fmt,{bin_name:expected[bin_name]})
        old=(sha(thin),thin.stat().st_ino)
        shell('_act_validate_workspace_archive',thin,fmt,target,cf,rc=4)
        check('old executable-only archive is refused without repair',old==(sha(thin),thin.stat().st_ino))

# Generated data and scripts need custody separate from native executable and
# Git include receipts. Mutations at the collector return cannot be adopted as
# a new baseline; mutations after member freezing must also block packaging.
for fmt in ('tar.gz','tar.xz','zip'):
    cfg=copy.deepcopy(base)
    asset='companion-custody.'+fmt
    cfg['release_contract']['exact_primary_assets'][host]=asset
    cfg['workspace_archive_files']={host:[{'name':name,'executable':bool(mode & 0o111)}
                                        for name,(_,mode) in generated_companions.items()]}
    result,cf,folder=package(cfg,host)
    expected=dict(committed,app=(local_binary.read_bytes(),0o755))
    expected.update({name:(data,0o755 if mode & 0o111 else 0o644)
                     for name,(data,mode) in generated_companions.items()})
    check(fmt+' strict collection packages original generated scripts and data',
          read_archive(Path(result['artifact_path']),fmt)==expected)
    handoffs=[json.loads(row) for row in (folder/'collection-handoffs.jsonl').read_text().splitlines()]
    for name,(data,mode) in generated_companions.items():
        receipt=next(row for row in handoffs if row['path']==str(folder/name))
        info=(folder/name).stat()
        check(fmt+' generated '+name+' retains its original exclusive collection identity',
              receipt['sha256']==hashlib.sha256(data).hexdigest()==sha(folder/name) and
              receipt['size_bytes']==info.st_size and stat.S_IMODE(info.st_mode)==mode and
              receipt['identity'] in (f'gnu:{info.st_dev}:{info.st_ino}',f'bsd:{info.st_ino}'))
    faults=[('prearchive',name,'content') for name in generated_companions]
    if fmt=='tar.gz':
        faults += [('handoff',name,'content') for name in generated_companions]
        faults += [(phase,name,mutation) for phase in ('handoff','prearchive')
                   for name,mutation in (('metadata.json','inode'),('verify.sh','mode'))]
    for phase,name,mutation in faults:
        result,cf,folder=package(cfg,host,expected=7,companion_fault=(phase,name,mutation))
        proof=json.loads((folder/'companion-mutation.json').read_text())
        handoffs=[json.loads(row) for row in (folder/'collection-handoffs.jsonl').read_text().splitlines()]
        receipt=next(row for row in handoffs if row['path']==str(folder/name))
        changed_field={'content':'sha256','mode':'mode','inode':'inode'}[mutation]
        unchanged_fields=set(proof['before'])-{changed_field}
        label=fmt+' '+phase+' '+name+' '+mutation
        check(label+' changes only the intended custody field after real collection',
              proof['before']['sha256']==receipt['sha256'] and
              proof['before'][changed_field]!=proof['after'][changed_field] and
              all(proof['before'][key]==proof['after'][key] for key in unchanged_fields))
        check(label+' cannot advertise a completed primary and leaves the compiler output intact',
              result['artifact_path']=='' and not result['collected_sha256'] and
              (folder/'app').read_bytes()==local_binary.read_bytes())
        if phase=='handoff':
            check(label+' is refused before archive production instead of rebasing the receipt',
                  not (folder/asset).exists())
        else:
            archive=folder/asset
            archived=read_archive(archive,fmt)
            archive_receipt=next(row for row in handoffs if row['path']==str(archive))
            check(label+' reaches a genuine successful writer with unchanged binary and Git includes',
                  archive_receipt['sha256']==sha(archive) and archived['app']==expected['app'] and
                  all(archived[include]==expected[include] for include in committed) and
                  archived[name][0]==(folder/name).read_bytes())

# Direct writer coverage uses deliberately private and noncanonical inputs.
# Checking the original inode, ctime and mode also rejects implementations
# which temporarily chmod the collected file and then restore its permissions.
metadata_dir = work / 'private-metadata-inputs'
metadata_dir.mkdir(mode=0o700)
metadata_files = {
    'private-app': (local_binary.read_bytes(), 0o700),
    'setid-app': (b'#!/bin/sh\nexit 17\n', 0o4700),
    'private-readme': (b'Private collected companion\n', 0o600),
    'special-data': (b'Setgid is never published\n', 0o2600),
    'EMPTY': (b'', 0o600),
}
vary_source_owner = os.geteuid() == 0
for name, (data, mode) in metadata_files.items():
    path = metadata_dir / name
    path.write_bytes(data)
    # Root runners otherwise cannot demonstrate nonzero stored source IDs.
    if vary_source_owner:
        try:
            os.chown(path, 12345, 12346)
        except OSError as error:
            if error.errno not in (errno.EPERM, errno.EINVAL, errno.ENOSYS):
                raise
            # Namespace-root may lack chown authority. Keep all metadata
            # assertions, and report only this extra source-ID variation.
            vary_source_owner = False
            skipped += 1
            print('SKIP nonzero source ownership fixture: '+str(error), flush=True)
    path.chmod(mode)
before_metadata = {name: metadata_snapshot(metadata_dir/name) for name in metadata_files}
normalized = {name: (data, 0o755 if mode & 0o111 else 0o644)
              for name, (data, mode) in metadata_files.items()}
for fmt, function in (('tar.gz', '_act_stream_workspace_tar_gz'),
                      ('tar.xz', '_act_stream_workspace_tar_xz'),
                      ('zip', '_act_stream_workspace_zip')):
    archive = work / ('normalized.' + fmt)
    with archive.open('wb') as output:
        result = subprocess.run(['bash', '-c', 'umask 077; source "$1"; shift; "$@"',
                                 '_', str(module), function, str(metadata_dir), *metadata_files],
                                stdout=output, stderr=subprocess.PIPE, timeout=30)
    check(fmt+' private input writer succeeds', result.returncode == 0)
    inspect_archive_metadata(archive, fmt, normalized, fmt+' private inputs')
    check(fmt+' normalization never changes original metadata or inodes',
          before_metadata == {name: metadata_snapshot(metadata_dir/name) for name in metadata_files})
    check(fmt+' original collection directory remains private',
          stat.S_IMODE(metadata_dir.stat().st_mode) == 0o700)
    extracted = work / ('extracted-' + fmt)
    extracted.mkdir()
    extract_command = ['unzip', '-q', archive, '-d', extracted] if fmt == 'zip' else ['tar', '-xf', archive, '-C', extracted]
    command(extract_command, preexec_fn=lambda: os.umask(0o022))
    check(fmt+' ordinary extraction yields shared executable and readable data',
          all(stat.S_IMODE((extracted/name).stat().st_mode) == mode
              for name, (_, mode) in normalized.items()))
    check(fmt+' extracted native executable still runs',
          subprocess.run([str(extracted/'private-app')], timeout=10).returncode == 17)

# Return failure after a real tar has written its stream. The compressor may
# still succeed, but the held collector must not issue an artifact receipt.
failing_tar_dir = work / 'failing-tar'
failing_tar_dir.mkdir()
failing_tar = failing_tar_dir / 'tar'
failing_tar.write_text('''#!/bin/sh
if [ "$1" = --version ]; then exec "$DSR_TEST_REAL_TAR" "$@"; fi
"$DSR_TEST_REAL_TAR" "$@" || exit "$?"
exit 73
''')
failing_tar.chmod(0o755)
failure_environment = dict(os.environ,
                           PATH=str(failing_tar_dir)+os.pathsep+os.environ['PATH'],
                           DSR_TEST_REAL_TAR=str(Path(shutil.which('tar')).resolve()))
for fmt, function in (('tar.gz', '_act_stream_workspace_tar_gz'),
                      ('tar.xz', '_act_stream_workspace_tar_xz')):
    partial = work / ('failed-producer.'+fmt)
    process = subprocess.run(['bash', '-c', 'source "$1"; shift; _act_collect_stream_exclusive "$@"',
                              '_', str(module), str(partial), '600', function, str(metadata_dir), 'private-app'],
                             env=failure_environment, capture_output=True, timeout=30)
    check(fmt+' archiver failure emits no collection receipt',
          process.returncode != 0 and process.stdout == b'')
    with tarfile.open(partial, 'r:*') as failed_archive:
        check(fmt+' failure occurred after genuine archive bytes were written',
              failed_archive.extractfile('private-app').read() == local_binary.read_bytes())
    check(fmt+' failed writer leaves private source unchanged',
          before_metadata == {name: metadata_snapshot(metadata_dir/name) for name in metadata_files})

# The contract-stage singleton writer is independent of the native workspace
# branch. Exercise it with a genuine compiled binary and frozen collection
# receipt, including the existing unchanged-prebuilt-archive path.
for fmt in ('tar.gz', 'tar.xz', 'zip'):
    folder = work / ('singleton-stage-' + fmt)
    collected = folder / 'collected'
    collected.mkdir(parents=True, mode=0o700)
    config_dir = folder / 'config'
    (config_dir/'repos.d').mkdir(parents=True)
    contract = {'exact_primary_assets': {host: 'app.'+fmt}}
    config = {'binary_name': 'app', 'targets': [host], 'release_contract': contract}
    write(config_dir/'repos.d/app.yaml', config)
    receipt = json.loads(shell('_act_collect_stream_exclusive', collected/'app', '700',
                               '_act_stream_local_file', local_binary))
    source_snapshot = metadata_snapshot(collected/'app')
    source_result = {'artifact_path': receipt['path'], 'artifact_paths': [receipt['path']],
                     'collected_sha256': receipt['sha256'], 'collected_size_bytes': receipt['size_bytes'],
                     'collected_identity': receipt['identity']}
    environment = dict(os.environ, DSR_CONFIG_DIR=str(config_dir),
                       ACT_REPOS_DIR=str(config_dir/'repos.d'), ACT_ARTIFACTS_DIR=str(folder/'artifacts'))
    stage_program = r'''
umask 077
source "$1" || exit $?
source "$(dirname "$1")/config.sh" || exit $?
source "$(dirname "$1")/packaging.sh" || exit $?
if [[ "$DSR_TEST_REPLACE_STAGED" == 1 ]]; then
    definition=$(declare -f _act_validate_release_archive_metadata) || exit 98
    eval "${definition/#_act_validate_release_archive_metadata /_test_real_metadata }"
    _act_validate_release_archive_metadata() {
        _test_real_metadata "$@" || return $?
        # The genuine metadata gate succeeds first. Replace only the gzip
        # header and output inode; executable bytes and metadata remain valid.
        python3 - "$1" "$DSR_TEST_REPLACEMENT_PROOF" <<'REPLACE'
import hashlib
import json
from pathlib import Path
import sys
path,report=map(Path,sys.argv[1:])
original=path.read_bytes()
before={'inode':path.stat().st_ino,'sha256':hashlib.sha256(original).hexdigest()}
assert original[:2]==b'\x1f\x8b'
replacement=bytearray(original)
replacement[4]^=1
path.rename(path.with_name(path.name+'.retained-original'))
with path.open('xb') as stream:
    stream.write(replacement)
path.chmod(0o600)
after={'inode':path.stat().st_ino,'sha256':hashlib.sha256(replacement).hexdigest()}
report.write_text(json.dumps({'path':str(path),'before':before,'after':after}))
REPLACE
    }
fi
shift
_act_stage_contract_primary "$@"
'''
    def stage(result, run_id, replace=False):
        proof=folder/'staged-replacement.json'
        process = subprocess.run(['bash', '-c', stage_program, '_', str(module), 'app', 'v1.2.3',
                                  run_id, host, json.dumps(result), json.dumps(contract)],
                                 env=dict(environment,DSR_TEST_REPLACE_STAGED=str(int(replace)),
                                          DSR_TEST_REPLACEMENT_PROOF=str(proof)),capture_output=True,timeout=60)
        (folder/(run_id+'.stdout')).write_bytes(process.stdout)
        (folder/(run_id+'.stderr')).write_bytes(process.stderr)
        if replace:
            evidence=json.loads(proof.read_text())
            replaced=Path(evidence['path'])
            check('singleton substitution followed genuine production and metadata validation',
                  evidence['before']['inode']!=evidence['after']['inode'] and
                  evidence['before']['sha256']!=evidence['after']['sha256'] and
                  read_archive(replaced,fmt)=={'app':(local_binary.read_bytes(),0o755)})
            shell('_act_validate_release_archive_metadata',replaced,fmt)
            check('singleton refuses changed output against its original held receipt',
                  process.returncode==4 and process.stdout==b'' and
                  b'changed after its exclusive collection' in process.stderr)
            check('singleton output substitution leaves private source unchanged',
                  metadata_snapshot(collected/'app')==source_snapshot)
            return None
        if process.returncode:
            raise AssertionError('singleton staging failed: '+process.stderr.decode())
        return json.loads(process.stdout)
    staged = stage(source_result, 'normalization-raw')
    archive = Path(staged['artifact_path'])
    inspect_archive_metadata(archive, fmt, {'app': (local_binary.read_bytes(), 0o755)}, fmt+' singleton stage')
    check(fmt+' singleton stage retains private collection unchanged',
          metadata_snapshot(collected/'app') == source_snapshot)
    check(fmt+' singleton output remains private on disk',
          stat.S_IMODE(archive.stat().st_mode) == 0o600 and
          stat.S_IMODE(archive.parent.stat().st_mode) == 0o700)
    check(fmt+' singleton receipt binds the normalized archive',
          staged['staged_sha256'] == sha(archive) and staged['staged_size_bytes'] == archive.stat().st_size)
    shell('_act_validate_target_archive', archive, fmt, 'app', host)
    if fmt=='tar.gz':
        stage(source_result,'custody-replaced-output',replace=True)
    receipt = json.loads(shell('_act_collect_stream_exclusive', collected/('app.'+fmt), '600',
                               '_act_stream_local_file', archive))
    source_result = {'artifact_path': receipt['path'], 'artifact_paths': [receipt['path']],
                     'collected_sha256': receipt['sha256'], 'collected_size_bytes': receipt['size_bytes'],
                     'collected_identity': receipt['identity']}
    prebuilt_snapshot = metadata_snapshot(Path(receipt['path']))
    restaged = stage(source_result, 'normalization-prebuilt')
    check(fmt+' existing contract archive retains identical compressed bytes',
          Path(restaged['artifact_path']).read_bytes() == archive.read_bytes() and
          prebuilt_snapshot == metadata_snapshot(Path(receipt['path'])))

for fmt in ('tar.xz','zip'):
    cfg=copy.deepcopy(base)
    cfg['release_contract']['exact_primary_assets'][host]='fault-test.'+fmt
    result,cf,folder=package(cfg,host)
    good=Path(result['artifact_path'])
    original=read_archive(good,fmt)
    for label,mutate,validator in (
        ('wrong-license',lambda m:m.__setitem__('LICENSE',(b'wrong license',0o644)),'_act_validate_workspace_archive_release_tree_includes'),
        ('wrong-script-mode',lambda m:m.__setitem__('install.sh',(m['install.sh'][0],0o644)),'_act_validate_workspace_archive_release_tree_includes'),
        ('wrong-binary-mode',lambda m:m.__setitem__('app',(m['app'][0],0o644)),'_act_validate_workspace_archive'),
    ):
        content=copy.deepcopy(original); mutate(content)
        bad=folder/(label+'.'+fmt); make_archive(bad,fmt,content)
        args=(bad,fmt,cf,repo,revision) if validator.endswith('includes') else (bad,fmt,host,cf)
        shell(validator,*args,rc=4)
    # Receipt checking rejects a valid executable from a different collection.
    forged=json.loads((folder/'binary-collection.json').read_text()); forged['sha256']='a'*64
    shell('_act_validate_workspace_archive_collection_receipts',good,fmt,host,cf,json.dumps(forged),rc=4)
    package(cfg,host,expected=7,preexisting=True)
    package(cfg,host,expected=7,tamper=True)
    for source in ('absent','linked','app'):
        bad=copy.deepcopy(cfg); bad['include_files']=[source]
        result,_,f=package(bad,host,expected=7)
        check('missing/linked/colliding companion leaves binary intact',sha(f/'app')==sha(local_binary))
    for opt in ({'include_extra_files':False},{'flat_archive':True}):
        flat=dict(cfg,**opt)
        rr,c,f=package(flat,host)
        check('explicit extras opt-out retains binary-only archive',set(read_archive(Path(rr['artifact_path']),fmt))=={'app'})
        shell('_act_validate_workspace_archive',rr['artifact_path'],fmt,host,c)

# A correct same-member archive for the host is not admitted for another CPU.
if len(fixtures)>1:
    target=next(t for t in fixtures if t!=host)
    cfg=copy.deepcopy(base); cfg['release_contract']['exact_primary_assets'][host]='host.tar.xz'
    rr,cf,_=package(cfg,host)
    shell('_act_validate_workspace_archive',rr['artifact_path'],'tar.xz',target,cf,rc=4)
cfg=copy.deepcopy(base)
cfg['workspace_binaries']=['unused-helper']
cfg['workspace_binaries_by_target']={host:[]}
rr,cf,_=package(cfg,host)
check('empty target override packages only primary, not the global workspace',set(read_archive(Path(rr['artifact_path']),'tar.xz'))==set(committed)|{'app'})
shell('_act_validate_workspace_archive',rr['artifact_path'],'tar.xz',host,cf)
cfg=copy.deepcopy(base)
cfg['release_contract']['exact_primary_assets'][host]='app'
rr,cf,folder=package(cfg,host)
check('raw strict primary is not silently converted to an archive',Path(rr['artifact_path']).name=='app' and sha(Path(rr['artifact_path']))==sha(local_binary))
check('raw primary does not acquire inapplicable archive companions',not (folder/'LICENSE').exists())
check('source working-copy dirt and modes are not altered',git('status','--porcelain=v1')==source_status)
metadata_gate_regressions()
print(f'Native singleton archives: {passed} assertions passed; {skipped} unavailable-fixture skips')
print('Retained integration fixtures: '+str(work))

PY
