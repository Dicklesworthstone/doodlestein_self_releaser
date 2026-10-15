#!/usr/bin/env bash
# Exercise the complete cmd_build/native scheduler/collector/packager path with
# real offline Go compilation. No SSH, workflow, compiler, receipt, hash or
# archive substitute. Host-slot reservation is outside this local fixture.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
EXPECT_INVENTORY_GAP=false
case "${1:-}" in
    --expect-inventory-gap) EXPECT_INVENTORY_GAP=true ;;
    '') ;;
    *) printf 'Unknown test option: %s\n' "$1" >&2; exit 4 ;;
esac
for dependency in bash go git jq yq python3 tar gzip zip unzip; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'Missing native artifact integration dependency: %s\n' "$dependency" >&2; exit 3;
    }
done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-native-artifacts.XXXXXXXX") || exit 1
printf 'Native artifact evidence: %s\n' "$WORK"
mkdir -p "$WORK/config/repos.d" "$WORK/source" "$WORK/state" "$WORK/cache" || exit 1
export DSR_CONFIG_DIR="$WORK/config" DSR_CONFIG_FILE="$WORK/config/config.yaml"
export DSR_STATE_DIR="$WORK/state" DSR_CACHE_DIR="$WORK/cache"
export DSR_REPOS_FILE="$WORK/config/repos.yaml" DSR_HOSTS_FILE="$WORK/config/hosts.yaml"
export ACT_CONFIG_DIR="$WORK/config" ACT_REPOS_DIR="$WORK/config/repos.d" NO_COLOR=1
export DSR_DISABLE_HOST_SELECTOR=1 RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1
unset RCH_REQUIRE_REMOTE
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) HOST_PLATFORM=linux/amd64 ;;
    Linux/aarch64) HOST_PLATFORM=linux/arm64 ;;
    Darwin/x86_64) HOST_PLATFORM=darwin/amd64 ;;
    Darwin/arm64) HOST_PLATFORM=darwin/arm64 ;;
    *) printf 'Unsupported execution host\n' >&2; exit 3 ;;
esac
cat > "$WORK/source/go.mod" <<'GO'
module example.invalid/nativeartifacts

go 1.20
GO
cat > "$WORK/source/main.go" <<'GO'
package main
import("fmt"; "runtime")
func main() { fmt.Println("nativeartifacts " + runtime.GOOS + "/" + runtime.GOARCH) }
GO
cat > "$WORK/source/build.sh" <<'BUILD'
#!/usr/bin/env bash
set -uo pipefail
printf '%s/%s\n' "$GOOS" "$GOARCH" >> "$DSR_TEST_EVENTS" || exit 1
if [[ -f "$DSR_TEST_FAIL" ]] && [[ "$(cat "$DSR_TEST_FAIL")" == "$GOOS/$GOARCH" ]]; then
    printf 'Deliberate compiler-lane failure for resume\n' >&2
    exit 6
fi
binary=nativeartifacts
[[ "$GOOS" != windows ]] || binary+=.exe
go build -trimpath -o "$binary" .
BUILD
printf 'Fixture license: redistribution permitted.\n' > "$WORK/source/LICENSE"
printf '/nativeartifacts\n/nativeartifacts.exe\n' > "$WORK/source/.gitignore"
git -C "$WORK/source" init -q -b main || exit 1
git -C "$WORK/source" add . || exit 1
git -C "$WORK/source" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm 'native artifact fixture' || exit 1
git -C "$WORK/source" tag v1.2.3 || exit 1
SOURCE_SHA=$(git -C "$WORK/source" rev-parse HEAD) || exit 1
printf 'schema_version: "1.0.0"\n' > "$DSR_CONFIG_FILE"
printf 'tools: {}\n' > "$DSR_REPOS_FILE"
cat > "$DSR_HOSTS_FILE" <<YAML
schema_version: "1.0.0"
hosts:
  localnative:
    platform: $HOST_PLATFORM
    connection: local
    concurrency: 2
platform_mapping:
  linux/amd64: localnative
  linux/arm64: localnative
  darwin/amd64: localnative
  darwin/arm64: localnative
  windows/amd64: localnative
  windows/arm64: localnative
  windows/386: localnative
YAML
cat > "$ACT_REPOS_DIR/nativeartifacts.yaml" <<YAML
tool_name: nativeartifacts
repo: example/nativeartifacts
local_path: $WORK/source
language: go
binary_name: nativeartifacts
build_cmd: bash build.sh
targets: [linux/amd64, linux/arm64, darwin/amd64, darwin/arm64, windows/amd64, windows/arm64, windows/386]
act_job_map:
  linux/amd64: null
  linux/arm64: null
  darwin/amd64: null
  darwin/arm64: null
  windows/amd64: null
  windows/arm64: null
  windows/386: null
artifact_naming: '\${name}-\${version}-\${os}-\${arch}'
install_script_compat: '\${name}-\${os}-\${arch}'
archive_format:
  linux: tar.gz
  darwin: tar.gz
  windows: zip
include_files: [LICENSE]
env:
  PATH: "$PATH"
  CGO_ENABLED: "0"
  GOENV: "off"
  GOTOOLCHAIN: local
  GOPROXY: "off"
  GOSUMDB: "off"
  GOCACHE: "$WORK/go-cache"
  DSR_TEST_EVENTS: "$WORK/build-events"
  DSR_TEST_FAIL: "$WORK/fail-target"
YAML
: > "$WORK/build-events"
# Same definition-loading boundary as test_native_variants.sh. This preserves
# every line of the real build command and the real native scheduler; it avoids
# CLI-wide loading of unrelated network/signing/capacity modules.
for module in logging config build_state act_runner artifact_naming git_ops packaging; do
    # shellcheck disable=SC1090
    source "$ROOT/src/$module.sh" || exit 1
done
export SCRIPT_DIR="$ROOT"
declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
# shellcheck disable=SC1090
source <(awk '/^(_dsr_require|cmd_build)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/dsr") || exit 1
# shellcheck disable=SC1090
source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$ROOT/dsr") || exit 1
export JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture
OUTPUT="$WORK/output"
STATUS=0
cmd_build nativeartifacts --version 1.2.3 --no-sync --jobs 1 --output-dir "$OUTPUT" \
    > "$WORK/build.json" 2> "$WORK/build.log" || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
    cat "$WORK/build.log" >&2
    printf 'FAIL: native build command exited %s\n' "$STATUS" >&2
    exit 1
fi
build_state_get nativeartifacts 1.2.3 > "$WORK/checkpoint.json" || exit 1
python3 - "$WORK" "$HOST_PLATFORM" "$SOURCE_SHA" "$EXPECT_INVENTORY_GAP" <<'PY'
import hashlib, json, os, subprocess, sys, tarfile, zipfile
from pathlib import Path
work, host, source = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
expect_gap = sys.argv[4] == 'true'
output = work / 'output'
response = json.loads((work/'build.json').read_bytes())
state = json.loads((work/'checkpoint.json').read_bytes())
manifest = json.loads((output/'nativeartifacts-v1.2.3-manifest.json').read_bytes())
platforms = ['linux/amd64','linux/arm64','darwin/amd64','darwin/arm64','windows/amd64','windows/arm64','windows/386']
checks = 0

def check(label, ok):
    global checks
    if not ok:
        raise AssertionError(label)
    checks += 1
    print('PASS: '+label, flush=True)

def digest(data):
    return hashlib.sha256(data).hexdigest()

check('one successful build envelope', response['command']=='build' and response['status']=='success' and response['exit_code']==0)
check('seven independent successful native workers', response['details']['total']==7 and response['details']['success']==7 and response['details']['failed']==0)
check('all seven native compilations actually ran', sorted((work/'build-events').read_text().splitlines())==sorted(platforms))
check('source identity survives final manifest', manifest['source']['git_sha']==source)
check('final manifest and durable checkpoint completed together', manifest['publishable'] is True and state['status']=='completed')
rows = manifest['artifacts']
check('every published name unique', len({a['name'].casefold() for a in rows})==len(rows))
check('exact raw/archive/compatibility inventory', len(rows)==21)
check('all targets survive signed-manifest input', {a['target'] for a in rows}==set(platforms))
for platform in platforms:
    osname, arch = platform.split('/')
    extension = '.exe' if osname=='windows' else ''
    name = 'nativeartifacts_'+osname+'_'+arch+extension
    matches = [a for a in rows if a['name']==name]
    check(platform+' raw row uses its collected name', len(matches)==1 and matches[0]['target']==platform)
    raw = (output/name).read_bytes()
    original = Path(state['target_statuses'][platform]['result']['artifact_path'])
    check(platform+' raw bytes match its own worker', raw==original.read_bytes())
    receipt = next(r for r in state['target_statuses'][platform]['result']['resume_artifacts'] if r['path']==str(original))
    check(platform+' original frozen custody preserved', digest(raw)==receipt['sha256'] and len(raw)==receipt['size_bytes'])
    fmt = 'zip' if osname=='windows' else 'tar.gz'
    versioned = output/('nativeartifacts-1.2.3-'+osname+'-'+arch+'.'+fmt)
    alias = output/('nativeartifacts-'+osname+'-'+arch+'.'+fmt)
    check(platform+' installer alias retains exact archive bytes', versioned.read_bytes()==alias.read_bytes())
    if fmt=='zip':
        with zipfile.ZipFile(versioned) as archive:
            members = {n:archive.read(n) for n in archive.namelist() if not n.endswith('/')}
    else:
        with tarfile.open(versioned) as archive:
            members = {m.name:archive.extractfile(m).read() for m in archive.getmembers() if m.isfile()}
    check(platform+' archive has canonical executable and license', set(members)=={'nativeartifacts'+extension,'LICENSE'})
    check(platform+' archive contains its own raw payload', members['nativeartifacts'+extension]==raw)
    check(platform+' license retained', members['LICENSE']==(work/'source/LICENSE').read_bytes())
for artifact in rows:
    data = (output/artifact['name']).read_bytes()
    check('manifest binds final bytes: '+artifact['name'], digest(data)==artifact['sha256'] and len(data)==artifact['size_bytes'])
run = subprocess.run([str(output/('nativeartifacts_'+host.replace('/','_')))], capture_output=True, check=True, timeout=10)
check('host-compatible collected executable runs', run.stdout.decode().strip()=='nativeartifacts '+host)
# Exercise the exact final admission helper using the actual compiled files.
# These rejected documents are independent candidates, not regenerated goldens.
module = Path(os.environ['SCRIPT_DIR'])/'src/act_runner.sh'
raw_names = ['nativeartifacts_'+p.replace('/','_')+('.exe' if p.startswith('windows/') else '') for p in platforms]
framed = ('\0'.join(raw_names)+'\0').encode()
def gate(value):
    candidate=work/('gate-%d.json'%checks)
    candidate.write_text(json.dumps(value))
    p=subprocess.run(['bash','-c','source "$1"; _act_verify_collected_manifest "$2" "$3" --collected','_',str(module),str(candidate),str(output)],input=framed,capture_output=True,timeout=30)
    (work/('gate-%d.stderr'%checks)).write_bytes(p.stderr)
    return p.returncode
check('actual complete collected manifest passes final admission',gate(manifest)==0)
for label, change in [
    ('omitted Apple Silicon row',lambda m:m['artifacts'].__setitem__(slice(None),[a for a in m['artifacts'] if a['name']!='nativeartifacts_darwin_arm64'])),
    ('pre-rename raw name',lambda m:m['artifacts'][0].__setitem__('name','old-uncollected-name')),
    ('duplicate manifest name',lambda m:m['artifacts'].append(dict(m['artifacts'][0]))),
    ('changed recorded hash',lambda m:m['artifacts'][0].__setitem__('sha256','0'*64)),
    ('changed recorded size',lambda m:m['artifacts'][0].__setitem__('size_bytes',1)),
    ('path traversal',lambda m:m['artifacts'][0].__setitem__('name','../outside')),
]:
    candidate=json.loads(json.dumps(manifest))
    change(candidate)
    if expect_gap and label == 'omitted Apple Silicon row':
        check('unchanged incumbent accepts an omitted collected Apple Silicon payload',gate(candidate)==0)
    else:
        check('final admission refuses '+label,gate(candidate)==4)
selected=output/raw_names[0]
held=work/'retained-raw'
selected.rename(held)
check('final admission refuses a missing actual payload',gate(manifest)==4)
selected.symlink_to(held)
check('final admission refuses a symlink payload',gate(manifest)==4)
selected.rename(work/'retained-symlink')
selected.write_bytes(held.read_bytes()+b'corruption')
check('final admission refuses changed actual payload bytes',gate(manifest)==4)
selected.rename(work/'retained-corrupt-copy')
held.rename(selected)
check('restored original bytes pass final admission',gate(manifest)==0)
(work/'summary.json').write_text(json.dumps({'passed':checks,'failed':0,'targets':platforms,'evidence':str(work)},indent=2)+'\n')
print('Native artifact build: %d passed, 0 failed'%checks)
PY
