#!/usr/bin/env bash
# Exercise the complete cmd_build/native scheduler/collector/packager path with
# real offline Go compilation. No SSH, workflow, compiler, receipt, hash or
# archive substitute. Host-slot reservation is outside this local fixture.
# --seven-target-release selects the exact issue #47 matrix.
# --validate-targets-only checks early rejection and structured errors only.
# --manifest-provenance-only compiles that matrix directly, then exercises the
# real collector/packager/manifest/provenance APIs without running the scheduler
# or changing its host-health admission. It is narrower evidence, not a full
# cmd_build result, and never manufactures a completed publication marker.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
EXPECT_INVENTORY_GAP=false
GO_ENVIRONMENT_ONLY=false
MANIFEST_PROVENANCE_ONLY=false
VALIDATE_TARGETS_ONLY=false
TARGETS_JSON='["linux/amd64","linux/arm64","linux/armv7","darwin/amd64","darwin/arm64","windows/amd64","windows/arm64","windows/386","freebsd/amd64"]'
case "${1:-}" in
    --expect-inventory-gap) EXPECT_INVENTORY_GAP=true ;;
    # The exact matrix from issue #47, alongside the broader default which
    # retains the existing Windows ARM64 and 386 compiler/archive coverage.
    --seven-target-release) TARGETS_JSON='["linux/amd64","linux/arm64","linux/armv7","darwin/amd64","darwin/arm64","windows/amd64","freebsd/amd64"]' ;;
    --manifest-provenance-only) MANIFEST_PROVENANCE_ONLY=true; TARGETS_JSON='["linux/amd64","linux/arm64","linux/armv7","darwin/amd64","darwin/arm64","windows/amd64","freebsd/amd64"]' ;;
    --validate-targets-only) VALIDATE_TARGETS_ONLY=true ;;
    --go-targets-only) TARGETS_JSON='["linux/amd64","linux/arm64"]' ;;
    --go-environment-only) GO_ENVIRONMENT_ONLY=true; TARGETS_JSON='["linux/amd64","linux/arm64"]' ;;
    '') ;;
    *) printf 'Unknown test option: %s\n' "$1" >&2; exit 4 ;;
esac
for dependency in bash go git jq yq python3 tar gzip zip unzip minisign; do
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
if ! $GO_ENVIRONMENT_ONLY && ! jq -e --arg host "$HOST_PLATFORM" 'index($host) != null' <<< "$TARGETS_JSON" >/dev/null; then
    printf 'The selected fixture targets must include the execution host\n' >&2; exit 3
fi
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
  linux/armv7: localnative
  darwin/amd64: localnative
  darwin/arm64: localnative
  windows/amd64: localnative
  windows/arm64: localnative
  windows/386: localnative
  freebsd/amd64: localnative
YAML
cat > "$ACT_REPOS_DIR/nativeartifacts.yaml" <<YAML
tool_name: nativeartifacts
repo: example/nativeartifacts
local_path: $WORK/source
language: go
binary_name: nativeartifacts
build_cmd: bash build.sh
targets: $TARGETS_JSON
act_job_map:
  linux/amd64: null
  linux/arm64: null
  linux/armv7: null
  darwin/amd64: null
  darwin/arm64: null
  windows/amd64: null
  windows/arm64: null
  windows/386: null
  freebsd/amd64: null
artifact_naming: '\${name}-\${version}-\${os}-\${arch}'
install_script_compat: '\${name}-\${os}-\${arch}'
archive_format:
  linux: tar.gz
  darwin: tar.gz
  windows: zip
  freebsd: tar.gz
include_files: [LICENSE]
env:
  PATH: "$PATH"
  CGO_ENABLED: "0"
  GOENV: "off"
  GOTOOLCHAIN: local
  GOPROXY: "off"
  GOSUMDB: "off"
  GOMAXPROCS: "2"
  GOCACHE: "$WORK/go-cache"
  DSR_TEST_EVENTS: "$WORK/build-events"
  DSR_TEST_FAIL: "$WORK/fail-target"
YAML
: > "$WORK/build-events"
# Same definition-loading boundary as test_native_variants.sh. This preserves
# every line of the real build command and the real native scheduler; it avoids
# CLI-wide loading of unrelated network/signing/capacity modules.
for module in logging config build_state act_runner artifact_naming git_ops packaging host_health slsa; do
    # shellcheck disable=SC1090
    source "$ROOT/src/$module.sh" || exit 1
done
# Initialize this shell too: the native orchestrator initializes its subshell.
build_state_init || exit 1
export SCRIPT_DIR="$ROOT"
declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
# shellcheck disable=SC1090
source <(awk '/^(_dsr_require|cmd_build)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/dsr") || exit 1
# shellcheck disable=SC1090
source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$ROOT/dsr") || exit 1
export JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture
# The requested target must override both the host default and selectors from
# the caller. The recipe intentionally has no GOOS/GOARCH or cross_compile map.
export GOOS=plan9 GOARCH=386 GOARM=5
if $GO_ENVIRONMENT_ONLY; then
    # Exercise the actual resolver and compiler without starting a native worker.
    # This focused mode is also usable when host disk admission prevents the full
    # scheduler fixture; it does not replace that admission or artifact coverage.
    mkdir -p "$WORK/go-tmp" "$WORK/go-binaries" || exit 1
    cat > "$WORK/go-target.go" <<'GO'
package main
import "runtime"
func main() { println(runtime.GOOS + "/" + runtime.GOARCH) }
GO
    for target in linux/amd64 linux/arm64; do
        target_key="${target//\//-}"
        build_env=$(act_get_build_env nativeartifacts "$target") || exit 1
        printf '%s\n' "$build_env" > "$WORK/go-binaries/$target_key.env" || exit 1
        (
            cd "$WORK/source" || exit 1
            while IFS= read -r env_pair; do
                [[ -z "$env_pair" ]] || export "${env_pair?}" || exit 1
            done <<< "$build_env"
            export GOTMPDIR="$WORK/go-tmp"
            go build -trimpath -o "$WORK/go-binaries/$target_key" "$WORK/go-target.go"
        ) || exit 1
    done
    python3 - "$WORK/go-binaries" <<'PY'
import struct, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
checks = 0

def check(label, ok):
    global checks
    if not ok:
        raise AssertionError(label)
    checks += 1
    print('PASS: ' + label, flush=True)

for arch, machine in [('amd64', 62), ('arm64', 183)]:
    binary = root / ('linux-' + arch)
    pairs = binary.with_suffix('.env').read_text().splitlines()
    selectors = [p for p in pairs if p.startswith(('GOOS=', 'GOARCH='))]
    check(arch + ' canonical target selectors from production config resolver',
          sorted(selectors) == sorted(['GOOS=linux', 'GOARCH=' + arch]))
    header = binary.read_bytes()[:20]
    check(arch + ' real compiled ELF architecture',
          header[:4] == b'\x7fELF' and header[4:6] == b'\x02\x01'
          and struct.unpack('<H', header[18:20])[0] == machine)
    metadata = subprocess.check_output(['go', 'version', '-m', str(binary)], text=True)
    check(arch + ' embedded Go operating system', '\tbuild\tGOOS=linux\n' in metadata)
    check(arch + ' embedded Go architecture', '\tbuild\tGOARCH=' + arch + '\n' in metadata)

print(f'Go environment/compiler checks: {checks} passed')
PY
    exit $?
fi

# A valid first entry must not reach the compiler before an unsupported later
# target is rejected. Exercise configuration, command and direct library entry
# points with the real parsers; the build script itself records any compilation.
config_load || exit 1
PREFLIGHT_CHECKS=0
expect_target_rejection() {
    local label="$1" rejected="$2" status=0
    shift 2
    "$@" > "$WORK/preflight-$PREFLIGHT_CHECKS.out" \
        2> "$WORK/preflight-$PREFLIGHT_CHECKS.err" || status=$?
    if [[ "$status" != 4 ]] ||
       ! grep -F -- "$rejected" "$WORK/preflight-$PREFLIGHT_CHECKS.err" >/dev/null ||
       ! grep -Ei 'support|supported' "$WORK/preflight-$PREFLIGHT_CHECKS.err" >/dev/null ||
       [[ -s "$WORK/build-events" || -e "$WORK/rejected-output" ]]; then
        cat "$WORK/preflight-$PREFLIGHT_CHECKS.err" >&2
        printf 'FAIL: %s must identify unsupported %s before any build (exit %s)\n' \
            "$label" "$rejected" "$status" >&2
        return 1
    fi
    PREFLIGHT_CHECKS=$((PREFLIGHT_CHECKS + 1))
    printf 'PASS: %s rejects %s before compilation or artifact publication\n' "$label" "$rejected"
}
for rejected in plan9/amd64 linux/mips64 windows/armv7 freebsd/arm64; do
    yq -o=json '.' "$ACT_REPOS_DIR/nativeartifacts.yaml" | \
        jq --arg rejected "$rejected" '.tool_name="nativeinvalid" |
            .targets=["linux/amd64",$rejected]' > "$ACT_REPOS_DIR/nativeinvalid.yaml" || exit 1
    expect_target_rejection 'configuration validation' "$rejected" \
        config_validate || exit 1
    expect_target_rejection 'configured build' "$rejected" \
        cmd_build nativeinvalid --version 1.2.3 --no-sync --jobs 1 \
            --output-dir "$WORK/rejected-output" || exit 1
    expect_target_rejection 'explicit CLI target override' "$rejected" \
        cmd_build nativeartifacts --version 1.2.3 --no-sync --jobs 1 \
            --targets "linux/amd64,$rejected" --output-dir "$WORK/rejected-output" || exit 1
    expect_target_rejection 'direct orchestrator target override' "$rejected" \
        act_orchestrate_build nativeartifacts 1.2.3 --no-source-sync-gate \
            --output-dir "$WORK/rejected-output" -- linux/amd64 "$rejected" || exit 1
done
mv "$ACT_REPOS_DIR/nativeinvalid.yaml" "$WORK/rejected-config.yaml" || exit 1
config_validate > "$WORK/config-valid.out" 2> "$WORK/config-valid.err" || {
    cat "$WORK/config-valid.err" >&2; exit 1;
}
printf 'PASS: complete supported target matrix passes configuration validation\n'
PREFLIGHT_CHECKS=$((PREFLIGHT_CHECKS + 1))

# The direct API's rejection result is consumed by build coordinators. Keep
# its JSON error contract, including the established duplicate-target error,
# and preserve argument boundaries rather than splitting embedded whitespace.
expect_orchestration_error_json() {
    local label="$1" expected="$2" status=0
    shift 2
    act_orchestrate_build nativeartifacts 1.2.3 --no-source-sync-gate \
        --output-dir "$WORK/rejected-output" -- linux/amd64 "$@" \
        > "$WORK/preflight-$PREFLIGHT_CHECKS.out" \
        2> "$WORK/preflight-$PREFLIGHT_CHECKS.err" || status=$?
    if [[ "$status" != 4 || -s "$WORK/build-events" || -e "$WORK/rejected-output" ]] ||
       ! jq -e --arg expected "$expected" '
           .tool == "nativeartifacts" and .status == "error" and
           .summary == {total:0,success:0,failed:0} and .targets == [] and
           (.error | type == "string" and contains($expected))
       ' "$WORK/preflight-$PREFLIGHT_CHECKS.out" >/dev/null; then
        cat "$WORK/preflight-$PREFLIGHT_CHECKS.err" >&2
        printf 'FAIL: %s must preserve structured early rejection (exit %s)\n' "$label" "$status" >&2
        return 1
    fi
    PREFLIGHT_CHECKS=$((PREFLIGHT_CHECKS + 1))
    printf 'PASS: %s retains structured early rejection without compilation\n' "$label"
}
expect_orchestration_error_json duplicate Duplicate linux/amd64 || exit 1
expect_orchestration_error_json unsupported plan9/amd64 plan9/amd64 || exit 1
expect_orchestration_error_json 'space inside target' unsupported 'linux/arm64 freebsd/amd64' || exit 1
expect_orchestration_error_json 'newline inside target' unsupported $'linux/arm64\nfreebsd/amd64' || exit 1
if $VALIDATE_TARGETS_ONLY; then
    printf 'Target validation: %s passed, 0 failed\n' "$PREFLIGHT_CHECKS"
    exit 0
fi
OUTPUT="$WORK/output"
MANIFEST="$OUTPUT/nativeartifacts-v1.2.3-manifest.json"
if $MANIFEST_PROVENANCE_ONLY; then
    printf 'Scope: real compiler/collection/packaging/manifest/provenance APIs; scheduler and host-health admission are not exercised.\n'
    mkdir -p "$OUTPUT" "$WORK/compiler-output" || exit 1
    act_load_repo_config nativeartifacts || exit 1
    target_results='[]'
    while IFS= read -r target; do
        os="${target%/*}" arch="${target#*/}" binary=nativeartifacts mode=700 format=tar.gz
        [[ "$os" != windows ]] || { binary+=.exe; mode=600; format=zip; }
        compile_dir="$WORK/compiler-output/${target//\//-}"
        # Retain a real local Git context for Go's VCS stamping. This is an
        # offline clone of the committed fixture, with independent object files.
        git clone -q --no-hardlinks "$WORK/source" "$compile_dir" || exit 1
        [[ "$(git -C "$compile_dir" rev-parse HEAD)" == "$SOURCE_SHA" ]] || exit 1
        build_env=$(act_get_build_env nativeartifacts "$target") || exit 1
        (
            cd "$compile_dir" || exit 1
            while IFS= read -r env_pair; do
                [[ -z "$env_pair" ]] || export "${env_pair?}" || exit 1
            done <<< "$build_env"
            bash build.sh
        ) > "$compile_dir.log" 2>&1 || { cat "$compile_dir.log" >&2; exit 1; }
        _act_validate_target_binary "$compile_dir/$binary" "$target" || exit 1
        raw="$OUTPUT/nativeartifacts_${os}_${arch}"
        [[ "$os" != windows ]] || raw+=.exe
        _act_collect_stream_exclusive "$raw" "$mode" _act_stream_local_file "$compile_dir/$binary" \
            > "$compile_dir/collection.json" || exit 1
        names=$(artifact_naming_generate_dual_for_tool nativeartifacts 1.2.3 \
            "$os" "$arch" "$format" "$WORK/source") || exit 1
        archive="$OUTPUT/$(jq -r .versioned <<< "$names")"
        alias="$OUTPUT/$(jq -r .compat <<< "$names")"
        packaging_build_archive "$format" "$archive" "$compile_dir" "$binary" LICENSE || exit 1
        # This ordinary archive intentionally includes its license. The strict
        # single-member release-contract validator is not its member policy.
        packaging_validate_archive "$archive" "$format" || exit 1
        cp "$archive" "$alias" || exit 1
        environment=$(jq -Rn '[inputs | select(length>0) | index("=") as $eq |
            {key:.[0:$eq],value:.[$eq+1:]}] | from_entries' <<< "$build_env") || exit 1
        row=$(jq -nc --arg platform "$target" --arg raw "$raw" --arg archive "$archive" \
            --arg alias "$alias" --arg compiled "$compile_dir/$binary" --argjson env "$environment" '
            {platform:$platform,method:"native",host:"local-compiler-fixture",status:"success",exit_code:0,
             artifact_path:$raw,artifact_paths:[$raw,$archive,$alias],compiled_path:$compiled,
             build_influence_env:$env}') || exit 1
        receipts=$(_act_result_artifact_receipts "$row") || exit 1
        target_results=$(jq -c --argjson row "$row" --argjson receipts "$receipts" \
            '. + [$row + {resume_artifacts:$receipts}]' <<< "$target_results") || exit 1
        printf 'PASS: actual Go compilation and archive admission for %s\n' "$target"
    done < <(jq -r '.[]' <<< "$TARGETS_JSON")
    result=$(jq -nc --argjson targets "$target_results" --argjson requested "$TARGETS_JSON" \
        --arg sha "$SOURCE_SHA" --arg run "$(python3 -c 'import uuid; print(uuid.uuid4())')" '
        {tool:"nativeartifacts",version:"1.2.3",run_id:$run,git_sha:$sha,git_ref:"refs/tags/v1.2.3",
         build_purpose:"release",publishable:true,status:"success",requested_targets:$requested,
         summary:{total:($targets|length),success:($targets|length),failed:0},targets:$targets}') || exit 1
    printf '%s\n' "$result" > "$WORK/compiler-results.json" || exit 1
    act_generate_manifest "$result" "$MANIFEST" || exit 1
else
    STATUS=0
    cmd_build nativeartifacts --version 1.2.3 --no-sync --jobs 1 --output-dir "$OUTPUT" \
        > "$WORK/build.json" 2> "$WORK/build.log" || STATUS=$?
    if [[ "$STATUS" -ne 0 ]]; then
        cat "$WORK/build.log" >&2
        printf 'FAIL: native build command exited %s\n' "$STATUS" >&2
        exit 1
    fi
    build_state_get nativeartifacts 1.2.3 > "$WORK/checkpoint.json" || exit 1
fi
mkdir -p "$WORK/provenance" || exit 1
PROVENANCE="$WORK/provenance/release.intoto.jsonl"
slsa_generate_manifest "$MANIFEST" "$OUTPUT" --repository example/nativeartifacts \
    --builder dsr/native-integration --output "$PROVENANCE" > "$WORK/provenance-path" || exit 1
# First exercise unsigned verification without pretending it authenticates a
# producer. Then sign with a real ephemeral fixture key and require that exact
# signer/builder pair; no user release key or remote service is accessed.
slsa_verify_release "$PROVENANCE" "$OUTPUT" --manifest "$MANIFEST" \
    --repository example/nativeartifacts --builder dsr/native-integration \
    --source-repository https://github.com/example/nativeartifacts \
    --source-commit "$SOURCE_SHA" > "$WORK/provenance-verify.out" \
    2> "$WORK/provenance-verify.err" || {
        cat "$WORK/provenance-verify.err" >&2; exit 1;
    }
minisign -G -W -s "$WORK/provenance/fixture.key" -p "$WORK/provenance/fixture.pub" \
    > "$WORK/provenance/keygen.log" 2>&1 || exit 1
minisign -G -W -s "$WORK/provenance/other.key" -p "$WORK/provenance/other.pub" \
    > "$WORK/provenance/other-keygen.log" 2>&1 || exit 1
minisign -S -s "$WORK/provenance/fixture.key" -m "$PROVENANCE" \
    -x "$PROVENANCE.minisig" -t 'DSR platform regression fixture' \
    > "$WORK/provenance/sign.log" 2>&1 || exit 1
slsa_verify_release "$PROVENANCE" "$OUTPUT" --manifest "$MANIFEST" \
    --repository example/nativeartifacts --builder dsr/native-integration \
    --public-key "$WORK/provenance/fixture.pub" \
    --source-repository https://github.com/example/nativeartifacts --source-commit "$SOURCE_SHA" \
    > "$WORK/provenance/signed-verify.out" 2> "$WORK/provenance/signed-verify.err" || {
        cat "$WORK/provenance/signed-verify.err" >&2; exit 1;
    }
python3 - "$WORK" "$HOST_PLATFORM" "$SOURCE_SHA" "$EXPECT_INVENTORY_GAP" "$TARGETS_JSON" "$PREFLIGHT_CHECKS" "$MANIFEST_PROVENANCE_ONLY" <<'PY'
import hashlib, json, os, struct, subprocess, sys, tarfile, zipfile
from pathlib import Path
work, host, source = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
expect_gap = sys.argv[4] == 'true'
focused = sys.argv[7] == 'true'
output = work / 'output'
if focused:
    compiler_results = json.loads((work/'compiler-results.json').read_bytes())
else:
    response = json.loads((work/'build.json').read_bytes())
    state = json.loads((work/'checkpoint.json').read_bytes())
    marker = json.loads((output/'.dsr-build-purpose.json').read_bytes())
manifest = json.loads((output/'nativeartifacts-v1.2.3-manifest.json').read_bytes())
proof_path = work/'provenance/release.intoto.jsonl'
proof = json.loads(proof_path.read_bytes())
platforms = json.loads(sys.argv[5])
checks = int(sys.argv[6])

def check(label, ok):
    global checks
    if not ok:
        raise AssertionError(label)
    checks += 1
    print('PASS: '+label, flush=True)

def digest(data):
    return hashlib.sha256(data).hexdigest()

if focused:
    check('real compiler fixture produced all requested targets',compiler_results['summary']=={'total':len(platforms),'success':len(platforms),'failed':0})
else:
    check('one successful build envelope', response['command']=='build' and response['status']=='success' and response['exit_code']==0)
    check('every requested native worker succeeds', response['details']['total']==len(platforms) and response['details']['success']==len(platforms) and response['details']['failed']==0)
check('real Go compilation overrides ambient target selectors for every requested platform', sorted((work/'build-events').read_text().splitlines())==sorted(p.replace('/armv7','/arm') for p in platforms))
check('source identity survives final manifest', manifest['source']['git_sha']==source)
if not focused:
    check('final manifest and durable checkpoint completed together', manifest['publishable'] is True and state['status']=='completed')
    check('publication marker completes only after the full manifest', marker['publishable'] is True and marker['publication_status']=='completed')
check('requested targets survive complete manifest generation', sorted(manifest['requested_targets'])==sorted(platforms))
try:
    import jsonschema
except ImportError:
    print('SKIP: jsonschema is unavailable for the optional manifest schema check',flush=True)
else:
    schema=json.loads((Path(os.environ['SCRIPT_DIR'])/'schemas/manifest.json').read_bytes())
    jsonschema.Draft202012Validator(schema,format_checker=jsonschema.FormatChecker()).validate(manifest)
    check('complete generated manifest satisfies the published JSON schema',True)
rows = manifest['artifacts']
check('every published name unique', len({a['name'].casefold() for a in rows})==len(rows))
check('exact raw/archive/compatibility inventory', len(rows)==3*len(platforms))
check('all targets survive signed-manifest input', {a['target'] for a in rows}==set(platforms))
for platform in platforms:
    osname, arch = platform.split('/')
    extension = '.exe' if osname=='windows' else ''
    name = 'nativeartifacts_'+osname+'_'+arch+extension
    matches = [a for a in rows if a['name']==name]
    check(platform+' raw row uses its collected name', len(matches)==1 and matches[0]['target']==platform)
    raw = (output/name).read_bytes()
    metadata = subprocess.check_output(['go','version','-m',str(output/name)],text=True)
    check(platform+' compiler metadata retains exact operating system', '\tbuild\tGOOS='+osname+'\n' in metadata)
    goarch = 'arm' if arch=='armv7' else arch
    check(platform+' compiler metadata retains exact architecture', '\tbuild\tGOARCH='+goarch+'\n' in metadata)
    if platform=='linux/armv7':
        check('ARMv7 selects GOARM=7 despite inherited GOARM=5', '\tbuild\tGOARM=7\n' in metadata or '\tbuild\tGOARM=7,hardfloat\n' in metadata)
        check('ARMv7 payload is 32-bit ARM ELF', raw[:6]==b'\x7fELF\x01\x01' and struct.unpack('<H',raw[18:20])[0]==40)
    if platform=='freebsd/amd64':
        check('FreeBSD payload is AMD64 ELF with the FreeBSD ABI', raw[:6]==b'\x7fELF\x02\x01' and raw[7]==9 and struct.unpack('<H',raw[18:20])[0]==62)
    producer = next(r for r in compiler_results['targets'] if r['platform']==platform) if focused else state['target_statuses'][platform]['result']
    original = Path(producer['compiled_path'] if focused else producer['artifact_path'])
    check(platform+' raw bytes match its own '+('compiler output' if focused else 'worker'), raw==original.read_bytes())
    receipt = next(r for r in producer['resume_artifacts'] if r['path']==str(output/name if focused else original))
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
check('provenance is an in-toto v1 SLSA v1 statement', proof['_type']=='https://in-toto.io/Statement/v1' and proof['predicateType']=='https://slsa.dev/provenance/v1')
check('provenance covers every raw executable, archive and installer alias', {s['name']:s['digest']['sha256'] for s in proof['subject']}=={a['name']:a['sha256'] for a in rows})
check('provenance retains the complete requested target matrix', sorted(proof['predicate']['buildDefinition']['externalParameters']['targets'])==sorted(platforms))
check('provenance binds the actual final manifest bytes', proof['dsr_evidence']['manifest_sha256']==digest((output/'nativeartifacts-v1.2.3-manifest.json').read_bytes()))
check('provenance retains source commit and expected builder', proof['predicate']['buildDefinition']['resolvedDependencies'][0]['digest']['gitCommit']==source and proof['predicate']['runDetails']['builder']['id']=='dsr/native-integration')
check('offline verification reports unauthenticated producer explicitly', 'not authenticated' in (work/'provenance-verify.err').read_text())
check('real Minisign verification authenticates the expected signer and builder', 'trusted signer/builder pair' in (work/'provenance/signed-verify.err').read_text())
run = subprocess.run([str(output/('nativeartifacts_'+host.replace('/','_')))], capture_output=True, check=True, timeout=10)
check('host-compatible collected executable runs', run.stdout.decode().strip()=='nativeartifacts '+host)
# Exercise the exact final admission helper using the actual compiled files.
# These rejected documents are independent candidates, not regenerated goldens.
module = Path(os.environ['SCRIPT_DIR'])/'src/act_runner.sh'
raw_names = ['nativeartifacts_'+p.replace('/','_')+('.exe' if p.startswith('windows/') else '') for p in platforms]
def binary_gate(source_platform, selected_platform):
    binary=output/('nativeartifacts_'+source_platform.replace('/','_')+('.exe' if source_platform.startswith('windows/') else ''))
    p=subprocess.run(['bash','-c','source "$1"; _act_validate_target_binary "$2" "$3"','_',
                      str(module),str(binary),selected_platform],capture_output=True,timeout=30)
    (work/('binary-gate-%d.stderr'%checks)).write_bytes(p.stderr)
    return p.returncode
for platform in platforms:
    check(platform+' real binary passes production format/architecture admission',binary_gate(platform,platform)==0)
for source_platform,selected_platform in [
    ('linux/amd64','freebsd/amd64'),
    ('freebsd/amd64','linux/amd64'),
    ('linux/arm64','linux/armv7'),
    ('linux/armv7','linux/arm64'),
]:
    if source_platform in platforms:
        check('binary admission refuses '+source_platform+' relabeled '+selected_platform,
              binary_gate(source_platform,selected_platform)==4)
framed = ('\0'.join(raw_names)+'\0').encode()
def gate(value):
    candidate=work/('gate-%d.json'%checks)
    candidate.write_text(json.dumps(value))
    p=subprocess.run(['bash','-c','source "$1"; _act_verify_collected_manifest "$2" "$3" --collected','_',str(module),str(candidate),str(output)],input=framed,capture_output=True,timeout=30)
    (work/('gate-%d.stderr'%checks)).write_bytes(p.stderr)
    return p.returncode
check('actual complete collected manifest passes final admission',gate(manifest)==0)
def provenance_gate(candidate=None):
    selected = output/'nativeartifacts-v1.2.3-manifest.json'
    if candidate is not None:
        selected=work/('proof-gate-%d.json'%checks)
        selected.write_text(json.dumps(candidate))
    p=subprocess.run(['bash','-c','source "$1"; shift; slsa_verify_release "$@"','_',
                      str(module.parent/'slsa.sh'),str(proof_path),str(output),'--manifest',str(selected),
                      '--repository','example/nativeartifacts','--builder','dsr/native-integration'],
                     capture_output=True,timeout=30)
    (work/('proof-gate-%d.stderr'%checks)).write_bytes(p.stderr)
    return p.returncode
def signed_provenance_gate(selected=proof_path, key=work/'provenance/fixture.pub', builder='dsr/native-integration'):
    p=subprocess.run(['bash','-c','source "$1"; shift; slsa_verify_release "$@"','_',
                      str(module.parent/'slsa.sh'),str(selected),str(output),
                      '--manifest',str(output/'nativeartifacts-v1.2.3-manifest.json'),
                      '--repository','example/nativeartifacts','--builder',builder,
                      '--public-key',str(key),'--signature',str(proof_path)+'.minisig'],
                     capture_output=True,timeout=30)
    (work/('signature-gate-%d.stderr'%checks)).write_bytes(p.stderr)
    return p.returncode
check('signed provenance refuses a different trusted key',signed_provenance_gate(key=work/'provenance/other.pub')!=0)
check('signed provenance refuses a different builder policy',signed_provenance_gate(builder='dsr/other-builder')!=0)
modified_proof=work/'provenance/reformatted.jsonl'
modified_proof.write_text(json.dumps(proof,indent=2)+'\n')
check('signature verification binds the exact provenance bytes',signed_provenance_gate(selected=modified_proof)!=0)
for label, change in [
    ('missing requested target',lambda m:m['requested_targets'].pop()),
    ('missing platform inventory',lambda m:m['artifacts'].__setitem__(slice(None),[a for a in m['artifacts'] if a['target']!=platforms[-1]])),
    ('failed worker',lambda m:m['summary'].__setitem__('failed',1)),
    ('unpublishable build',lambda m:m.__setitem__('publishable',False)),
    ('unpublishable artifact',lambda m:m['artifacts'][-1].__setitem__('publishable',False)),
]:
    candidate=json.loads(json.dumps(manifest))
    change(candidate)
    check('provenance refuses '+label,provenance_gate(candidate)!=0)
omitted_name = 'nativeartifacts_darwin_arm64' if 'darwin/arm64' in platforms else 'nativeartifacts_linux_arm64'
for label, change in [
    ('omitted target row',lambda m:m['artifacts'].__setitem__(slice(None),[a for a in m['artifacts'] if a['name']!=omitted_name])),
    ('pre-rename raw name',lambda m:m['artifacts'][0].__setitem__('name','old-uncollected-name')),
    ('duplicate manifest name',lambda m:m['artifacts'].append(dict(m['artifacts'][0]))),
    ('changed recorded hash',lambda m:m['artifacts'][0].__setitem__('sha256','0'*64)),
    ('changed recorded size',lambda m:m['artifacts'][0].__setitem__('size_bytes',1)),
    ('path traversal',lambda m:m['artifacts'][0].__setitem__('name','../outside')),
]:
    candidate=json.loads(json.dumps(manifest))
    change(candidate)
    if expect_gap and label == 'omitted target row':
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
check('provenance refuses changed actual payload bytes',provenance_gate()!=0)
check('valid signature cannot authorize changed payload bytes',signed_provenance_gate()!=0)
selected.rename(work/'retained-corrupt-copy')
held.rename(selected)
check('restored original bytes pass final admission',gate(manifest)==0)
check('restored original bytes pass provenance verification',provenance_gate()==0)
check('restored original bytes pass signed provenance verification',signed_provenance_gate()==0)
scope='compiler-manifest-provenance' if focused else 'full-native-build'
(work/'summary.json').write_text(json.dumps({'passed':checks,'failed':0,'targets':platforms,'scope':scope,'evidence':str(work)},indent=2)+'\n')
print(scope+': %d passed, 0 failed'%checks)
PY
