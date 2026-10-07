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
for tool in ('bash','git','jq','cc','tar','zip','unzip','xz'):
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
if os.environ.get('DSR_TEST_NATIVE_PACKAGE_BLOCK'):
    block = Path(os.environ['DSR_TEST_NATIVE_PACKAGE_BLOCK']).read_text()
else:
    source = module.read_text()
    begin = '        # Package workspace binaries into a single tarball\n'
    end = '\n    elif [[ $exit_code -eq 124 ]]; then'
    if source.count(begin) != 1:
        raise AssertionError('native packaging block is ambiguous or unavailable')
    start = source.index(begin)
    block = source[start:source.index(end, start)]

driver = work / 'package-driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$1" || exit $?
# Naming is an explicit configuration boundary, not simulated archive evidence.
# Its exact-primary behavior has a separate production naming regression suite.
artifact_naming_generate_dual_for_tool() {
    jq -cn --arg name "$(jq -r --arg target "$platform" '.release_contract.exact_primary_assets[$target]' "$config_file")" \
        '{versioned:$name,compat:$name,same:true}'
}
_test_native_packaging() {
    local config_file="$2" local_path="$3" release_git_sha="$4"
    local platform="$5" artifact_dir="$6" compiled="$7"
    local tool_name=app version=v1.2.3 strict_native_build=true selected_triple=''
    local status=success exit_code=0 log_file="$artifact_dir/build.log"
    local collected_sha256='' collected_size_bytes=0 collected_identity=''
    local workspace_binaries binary_name bin receipt
    local local_artifact_path=''
    local -a local_artifact_paths=() strict_collection_receipts=()
    workspace_binaries=$(_act_workspace_binaries_for_target "$config_file" "$platform") || return $?
    binary_name=$(jq -r '.binary_name' "$config_file") || return 4
    bin="$binary_name"
    [[ "$platform" != windows/* ]] || bin="${binary_name%.exe}.exe"
    local mode=700
    [[ "$platform" != windows/* ]] || mode=600
    receipt=$(_act_collect_stream_exclusive "$artifact_dir/$bin" "$mode" _act_stream_local_file "$compiled") || return $?
    local_artifact_paths=("$artifact_dir/$bin")
    strict_collection_receipts=("$receipt")
    printf '%s\n' "$receipt" > "$artifact_dir/binary-collection.json"
    if [[ ${DSR_TEST_TAMPER_COLLECTED:-0} == 1 ]]; then
        printf changed >> "$artifact_dir/$bin"
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

base = {'binary_name':'app', 'include_files':list(committed), 'release_contract':{'exact_primary_assets':{}}}
for target in fixtures:
    base['release_contract']['exact_primary_assets'][target] = 'app-'+target.replace('/','-')+'.tar.xz'

def read_archive(path, fmt):
    if fmt=='zip':
        with zipfile.ZipFile(path) as z:
            return {m.filename:(z.read(m),stat.S_IMODE(m.external_attr >> 16)) for m in z.infolist()}
    with tarfile.open(path,'r:*') as t:
        return {m.name:(t.extractfile(m).read(),m.mode) for m in t.getmembers() if m.isfile()}

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

counter=0

def package(config,target,expected=0,preexisting=False,tamper=False):
    global counter
    counter+=1
    folder=work/('case-'+str(counter)); folder.mkdir()
    cf=work/('case-'+str(counter)+'.json'); write(cf,config)
    path=folder/config['release_contract']['exact_primary_assets'][target]
    prior=None
    if preexisting:
        path.write_bytes(b'previous immutable archive')
        prior=(sha(path),path.stat().st_ino)
    p=subprocess.run(['bash',str(driver),str(module),str(cf),str(repo),revision,target,str(folder),str(fixtures[target])],
                     env=dict(os.environ,DSR_TEST_TAMPER_COLLECTED=str(int(tamper))),capture_output=True,timeout=90)
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
        expected[bin_name]=(binary.read_bytes(),0o600 if target.startswith('windows/') else 0o700)
        check(target+' '+fmt+' exact executable and companion bytes/modes',read_archive(archive,fmt)==expected)
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
print(f'Native singleton archives: {passed} assertions passed; {skipped} cross-toolchain skips')
print('Retained integration fixtures: '+str(work))

PY
