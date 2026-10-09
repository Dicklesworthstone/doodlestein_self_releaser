#!/usr/bin/env bash
# Source-pinned release execution through the real runner and manifest validator.
# Git, locked crate authentication, LLVM NEON/SSE compilation and Windows linking
# are real. Cargo/rustc/cargo-xwin and crate extraction are command-boundary
# fixtures; no Rust dependency build or Windows execution is claimed.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT/src/xwin_build.sh"
source "$ROOT/src/xwin_source.sh"
source "$ROOT/src/slsa.sh"
for TOOL in jq git clang lld-link llvm-ar python3 timeout setsid; do
    command -v "$TOOL" >/dev/null || { printf 'SKIP xwin release: requires %s\n' "$TOOL"; exit 0; }
done
[[ "$(uname -s)" == Linux ]] || { printf 'SKIP xwin release: requires Linux\n'; exit 0; }
TEST_TARGET="${XWIN_TEST_TARGET:-aarch64-pc-windows-msvc}"
case "$TEST_TARGET" in
    aarch64-pc-windows-msvc)
        TEST_PLATFORM=windows/arm64 TEST_SYSROOT=aarch64-unknown-windows-msvc
        TEST_MACHINE=arm64 TEST_MACHINE_CODE=43620 ;;
    x86_64-pc-windows-msvc)
        TEST_PLATFORM=windows/amd64 TEST_SYSROOT=x86_64-unknown-windows-msvc
        TEST_MACHINE=x64 TEST_MACHINE_CODE=34404 ;;
    *) printf 'Unsupported XWIN_TEST_TARGET: %s\n' "$TEST_TARGET" >&2; exit 4 ;;
esac
WORK=$(mktemp -d)
if [[ "${DSR_KEEP_TEST_FIXTURES:-0}" == 1 ]]; then
    printf 'Retained fixtures for %s: %s\n' "$TEST_TARGET" "$WORK"
else
    trap 'rm -rf -- "$WORK"' EXIT
fi
PASS=0 FAIL=0
ok() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert() { local label=$1; shift; if "$@" > "$WORK/assert.out" 2> "$WORK/assert.err"; then ok "$label"; else bad "$label"; cat "$WORK/assert.err" >&2; fi; }
reject() {
    local label=$1 expected=$2 rc=0; shift 2
    "$@" > "$WORK/rejected.out" 2> "$WORK/rejected.err" || rc=$?
    if [[ "$rc" == "$expected" && ! -s "$WORK/rejected.out" ]]; then ok "$label"; else
        bad "$label (expected $expected, got $rc)"; cat "$WORK/rejected.err" >&2
    fi
}
mkdir -p "$WORK/input/sdk/include" "$WORK/input/sdk/lib/$TEST_SYSROOT" "$WORK/input/llvm/include" "$WORK/tools" "$WORK/template/src"
RESOURCE=$(clang -print-resource-dir) || exit 1
for HEADER in arm_neon.h arm_bf16.h arm_vector_types.h stdint.h xmmintrin.h emmintrin.h mmintrin.h mm_malloc.h; do
    [[ ! -f "$RESOURCE/include/$HEADER" ]] || cp "$RESOURCE/include/$HEADER" "$WORK/input/llvm/include/" || exit 1
done
printf 'int DsrKernelStub(void) { return 42; }\n' > "$WORK/kernel.c"
clang --target="$TEST_TARGET" -ffreestanding -c "$WORK/kernel.c" -o "$WORK/kernel.obj" || exit 1
lld-link /dll /noentry "/machine:$TEST_MACHINE" /export:DsrKernelStub "/out:$WORK/kernel32.dll" "/implib:$WORK/input/sdk/lib/$TEST_SYSROOT/kernel32.lib" "$WORK/kernel.obj" || exit 1
printf 'SDK fixture\n' > "$WORK/input/sdk/include/windows.h"
# Exercise the real cargo-xwin include-order conflict: its MSVC intrinsic
# directory must not shadow the complete selected LLVM resource headers.
mkdir -p "$WORK/input/sdk/include/__msvc_vcruntime_intrinsics"
for HEADER in arm_neon.h xmmintrin.h; do
    printf '#error DSR_MSVC_INTRINSIC_SHADOW\n' > "$WORK/input/sdk/include/__msvc_vcruntime_intrinsics/$HEADER"
done
tar -cJf "$WORK/sdk.tar.xz" -C "$WORK/input" sdk || exit 1
tar -czf "$WORK/headers.tar.gz" -C "$WORK/input" llvm || exit 1
printf '[package]\nname="probe"\nversion="0.1.0"\nedition="2021"\n' > "$WORK/template/Cargo.toml"
printf 'version = 3\n' > "$WORK/template/Cargo.lock"
printf 'fn main() {}\n' > "$WORK/template/src/main.rs"
printf 'ignored.txt\n' > "$WORK/template/.gitignore"
cat > "$WORK/template/probe.c" <<'C'
#if defined(__aarch64__)
#include <arm_neon.h>
#elif defined(__x86_64__)
#include <xmmintrin.h>
int _fltused = 0;
#else
#error Unexpected architecture
#endif
__declspec(dllimport) int DsrKernelStub(void);
#ifdef DSR_SIBLING
int DsrSiblingValue(void);
#endif
int mainCRTStartup(void) {
#if defined(__aarch64__)
    uint8x8_t vector = vdup_n_u8(7);
    int lane = vget_lane_u8(vector, 0);
#else
    __m128 vector = _mm_set_ss(7.0f);
    int lane = _mm_cvtss_si32(vector);
#endif
#ifdef DSR_SIBLING
    return DsrKernelStub() + lane + DsrSiblingValue();
#else
    return DsrKernelStub() + lane;
#endif
}
C
cat > "$WORK/tools/cargo" <<'CARGO'
#!/usr/bin/env bash
set -uo pipefail
if [[ "$*" == -vV ]]; then printf 'cargo release fixture 1\nhost: linux\n'; exit 0; fi
[[ "$1" == metadata && "$*" == *'--locked'* ]] || exit 90
target=''
while (($#)); do
    if [[ "$1" == --filter-platform && $# -ge 2 && -z "$target" ]]; then target=$2; shift; fi
    shift
done
[[ "$target" == aarch64-pc-windows-msvc || "$target" == x86_64-pc-windows-msvc ]] || exit 90
[[ -n "${SOURCE_DATE_EPOCH:-}" && -z "${RUSTFLAGS:-}" && -z "${UNRELATED_SECRET:-}" ]] || exit 91
printf 'metadata diagnostic on stderr\n' >&2
python3 - <<'PY'
import json, os
from pathlib import Path
root = str(Path.cwd())
mode = Path('mode').read_text().strip()
identity = 'path+file://' + root + '#probe@0.1.0'
version = '9.9.9' if mode == 'wrong-version' else '0.1.0'
features = ['drift'] if mode == 'graph-drift' and Path(os.environ['CARGO_TARGET_DIR']).exists() else []
p = {'id':identity, 'name':'probe', 'version':version, 'source':None,
     'manifest_path':root+'/Cargo.toml', 'targets':[{'name':'probe', 'kind':['bin'], 'src_path':root+'/src/main.rs'}]}
if mode == 'external-source':
    p['targets'][0]['src_path'] = '/outside/src/main.rs'
graph = {'version':1, 'workspace_root':root, 'workspace_members':[identity], 'workspace_default_members':[identity],
         'packages':[p], 'resolve':{'root':identity, 'nodes':[{'id':identity, 'dependencies':[], 'features':features, 'deps':[]}]},
         'target_directory':os.environ['CARGO_TARGET_DIR']}
if mode.startswith('sibling-'):
    sibling_ids = {}
    for name, version in [('helper', '0.2.0'), ('types', '0.3.0')]:
        sibling = Path(root).parent / name
        if mode == 'sibling-external' and name == 'helper':
            sibling = Path(root).parent / 'unlisted'
        sibling_id = 'path+file://' + str(sibling) + '#' + name + '@' + version
        sibling_ids[name] = sibling_id
        graph['packages'].append({'id':sibling_id, 'name':name, 'version':version, 'source':None,
            'manifest_path':str(sibling/'Cargo.toml'),
            'targets':[{'name':name, 'kind':['lib'], 'src_path':str(sibling/'src/lib.rs')}]})
        graph['resolve']['nodes'].append({'id':sibling_id, 'dependencies':[], 'features':[], 'deps':[]})
    graph['resolve']['nodes'][0]['dependencies'] = [sibling_ids['helper']]
    graph['resolve']['nodes'][0]['deps'] = [{'name':'helper', 'pkg':sibling_ids['helper'], 'dep_kinds':[]}]
    graph['resolve']['nodes'][1]['dependencies'] = [sibling_ids['types']]
    graph['resolve']['nodes'][1]['deps'] = [{'name':'types', 'pkg':sibling_ids['types'], 'dep_kinds':[]}]
    if mode == 'sibling-graph-drift' and Path(os.environ['CARGO_TARGET_DIR']).exists():
        graph['resolve']['nodes'][2]['features'] = ['changed']
if mode.startswith('registry-'):
    import sys, tarfile
    home = Path(os.environ['CARGO_HOME'])
    archive = home / 'registry/cache/fixture-registry/native-dependency-1.0.0.crate'
    dependency = home / 'registry/src/fixture-registry/native-dependency-1.0.0'
    if not archive.is_file():
        print('fixture offline metadata requires the locked private crate download', file=sys.stderr)
        sys.exit(7)
    # Only this command boundary is simulated. The production source verifier
    # independently checks the archive checksum and every extracted file.
    # Preserve existing sources on the second metadata pass, as Cargo does.
    if not dependency.exists():
        dependency.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive, 'r:gz') as incoming:
            incoming.extractall(dependency.parent, filter='data')
        (dependency / '.cargo-ok').write_text('ok')
    dependency_id = 'registry+https://fixture.invalid/index#native-dependency@1.0.0'
    graph['packages'].append({'id':dependency_id, 'name':'native-dependency', 'version':'1.0.0',
        'source':'registry+https://fixture.invalid/index', 'manifest_path':str(dependency/'Cargo.toml'),
        'targets':[{'name':'native_dependency', 'kind':['lib'], 'src_path':str(dependency/'src/lib.rs')}]})
    graph['resolve']['nodes'][0]['dependencies'] = [dependency_id]
    graph['resolve']['nodes'][0]['deps'] = [{'name':'native_dependency', 'pkg':dependency_id, 'dep_kinds':[]}]
    graph['resolve']['nodes'].append({'id':dependency_id, 'dependencies':[], 'features':[], 'deps':[]})
print(json.dumps(graph))
PY
CARGO
cat > "$WORK/tools/rustc" <<'RUSTC'
#!/usr/bin/env bash
[[ "$*" == -vV ]] || exit 90
printf 'rustc release fixture 1\nhost: linux\n'
RUSTC
cat > "$WORK/tools/cargo-xwin" <<'PLUGIN'
#!/usr/bin/env bash
set -uo pipefail
if [[ "$*" == --version ]]; then printf 'cargo-xwin release fixture 1\n'; exit 0; fi
[[ "$1" == xwin && "$2" == build && "$*" == *'--package probe'* && "$*" == *'--message-format=json'* && "$*" == *'--locked'* ]] || exit 90
target=''
while (($#)); do
    if [[ "$1" == --target && $# -ge 2 && -z "$target" ]]; then target=$2; shift; fi
    shift
done
case "$target" in
    aarch64-pc-windows-msvc) machine=arm64 ;;
    x86_64-pc-windows-msvc) machine=x64 ;;
    *) exit 90 ;;
esac
[[ "$XWIN_CROSS_COMPILER" == clang && -n "${SOURCE_DATE_EPOCH:-}" && -z "${UNRELATED_SECRET:-}" && ! -e .git ]] || exit 91
mode=$(cat mode)
case "$mode" in fail) printf 'intentional compiler failure\n' >&2; exit 42 ;; esac
mkdir -p "$CARGO_TARGET_DIR/$target/release"
out="$CARGO_TARGET_DIR/$target/release/probe.exe"
compile_flags=() objects=()
if [[ "$mode" == sibling-* ]]; then
    [[ ! -e ../helper/.git && ! -e ../types/.git && ! -e ../helper/ignored.txt ]] || exit 92
    compile_flags=(-DDSR_SIBLING=1)
    clang --target="$target" -ffreestanding -c ../helper/native.c -o "$TMPDIR/helper.obj" || exit $?
    objects+=("$TMPDIR/helper.obj")
    printf 'compiled committed sibling C source with transitive header\n' >&2
fi
if [[ "$mode" == registry-* ]]; then
    compile_flags=(-DDSR_SIBLING=1)
    dependency="$CARGO_HOME/registry/src/fixture-registry/native-dependency-1.0.0/native.c"
    clang --target="$target" -ffreestanding -c "$dependency" -o "$TMPDIR/dependency.obj" || exit $?
    objects+=("$TMPDIR/dependency.obj")
    printf 'compiled lockfile-authenticated private crate C source\n' >&2
fi
# Match the observed cc-rs/cargo-xwin order, including the competing MSVC
# intrinsic -I path. Split only the runner's controlled whitespace-free flags.
sysroot="$XWIN_CACHE_DIR/windows-msvc-sysroot"
# shellcheck disable=SC2086
clang --target="$target" -ffreestanding $CFLAGS -I"$sysroot/include" \
    -I"$sysroot/include/c++/stl" -I"$sysroot/include/__msvc_vcruntime_intrinsics" \
    $CFLAGS "${compile_flags[@]}" -c probe.c -o "$TMPDIR/probe.obj" || exit $?
lld-link /entry:mainCRTStartup /subsystem:console /nodefaultlib "/machine:$machine" /timestamp:0 "/out:$out" "$TMPDIR/probe.obj" "${objects[@]}" Kernel32.lib || exit $?
case "$mode" in
    source-drift) printf '// source changed\n' >> src/main.rs ;;
    receipt-drift) printf '\n' >> "$HOME/../release-source.json" ;;
    environment-drift) printf '\n' >> "$HOME/../environment.json" ;;
    graph-receipt-drift) printf '\n' >> "$HOME/../metadata-before.json" ;;
    truncate) truncate -s 128 "$out" ;;
    sibling-drift) printf '// changed transitive header\n' >> ../types/value.h ;;
    sibling-plan-drift) printf '\n' >> "$HOME/../sibling-crates.json" ;;
    sibling-receipt-drift) printf '\n' >> "$HOME/../release-source.json" ;;
    registry-drift) printf '// changed after compilation\n' >> "$dependency" ;;
esac
python3 - "$mode" "$out" <<'PY'
import json, os, sys
mode, out = sys.argv[1:]
root = os.getcwd()
artifact = {'reason':'compiler-artifact', 'package_id':'path+file://'+root+'#probe@0.1.0',
            'target':{'name':'probe', 'kind':['bin'], 'src_path':root+'/src/main.rs'},
            'features':[], 'profile':{'test':False}, 'executable':out}
if mode == 'wrong-package': artifact['package_id'] = 'other-package'
if mode == 'wrong-message-source': artifact['target']['src_path'] = root+'/probe.c'
if mode == 'wrong-features': artifact['features'] = ['unexpected']
if mode == 'test-profile': artifact['profile']['test'] = True
if mode != 'missing-artifact': print(json.dumps(artifact))
if mode == 'duplicate-artifact': print(json.dumps(artifact))
print(json.dumps({'reason':'build-finished', 'success':mode != 'failed-message'}))
PY
PLUGIN
chmod 755 "$WORK/tools/"*
TOOLS='{}'
for TOOL in cargo cargo-xwin rustc clang lld-link llvm-ar; do
    case "$TOOL" in cargo|cargo-xwin|rustc) PATHNAME="$WORK/tools/$TOOL" ;; *) PATHNAME=$(readlink -f "$(command -v "$TOOL")") ;; esac
    TOOLS=$(jq -cn --argjson before "$TOOLS" --arg tool "$TOOL" --arg path "$PATHNAME" --arg sha "$(_xwt_hash "$PATHNAME")" \
        '$before+{($tool):{path:$path,sha256:$sha}}') || exit 1
done
jq -cn --arg root "$WORK" --arg target "$TEST_TARGET" --arg sdk "$(_xwt_hash "$WORK/sdk.tar.xz")" --arg headers "$(_xwt_hash "$WORK/headers.tar.gz")" --argjson tools "$TOOLS" \
    '{schema_version:1,target:$target,sysroot:{path:($root+"/sdk.tar.xz"),sha256:$sdk,url:"https://example.invalid/pinned/sdk.tar.xz",prefix:"sdk"},
    headers:{path:($root+"/headers.tar.gz"),sha256:$headers,url:"https://example.invalid/pinned/headers.tar.gz",prefix:"llvm/include"},
    aliases:{"Kernel32.lib":"kernel32.lib"},tools:$tools}' > "$WORK/manifest.json" || exit 1
MANIFEST="$WORK/manifest.json"
CACHE="$WORK/cache"
make_project() {
    local directory="$WORK/project-$1"
    cp -R "$WORK/template" "$directory" || return 1
    printf '%s\n' "$1" > "$directory/mode"
    if [[ "$1" == sibling-* ]]; then
        printf '\n[dependencies]\nhelper = { path = "../helper" }\n' >> "$directory/Cargo.toml"
        printf 'fn main() { let _ = helper::answer(); }\n' > "$directory/src/main.rs"
        cat > "$directory/Cargo.lock" <<'LOCK'
version = 3
[[package]]
name = "probe"
version = "0.1.0"
dependencies = ["helper"]
[[package]]
name = "helper"
version = "0.2.0"
dependencies = ["types"]
[[package]]
name = "types"
version = "0.3.0"
LOCK
    fi
    if [[ "$1" == registry-* ]]; then
        printf '\n[dependencies]\nnative-dependency = "=1.0.0"\n' >> "$directory/Cargo.toml"
        cat > "$directory/Cargo.lock" <<LOCK
version = 3
[[package]]
name = "probe"
version = "0.1.0"
dependencies = ["native-dependency"]
[[package]]
name = "native-dependency"
version = "1.0.0"
source = "registry+https://fixture.invalid/index"
checksum = "$REGISTRY_CHECKSUM"
LOCK
    fi
    if [[ "$1" == normal ]]; then
        # A real repository-sized inventory must cross the Linux per-argument
        # limit without passing the source evidence through --argjson/argv.
        python3 - "$directory" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]) / 'source-data'
root.mkdir()
for number in range(1000):
    (root / (f'{number:04d}-' + 'fixture-' * 12 + '.txt')).write_text('committed fixture\n')
PY
    fi
    git -C "$directory" init -qb main && git -C "$directory" config user.name 'DSR Fixture' &&
        git -C "$directory" config user.email test@example.invalid &&
        git -C "$directory" remote add origin https://github.com/owner/probe.git &&
        git -C "$directory" add . && git -C "$directory" -c commit.gpgsign=false commit -qm fixture &&
        git -C "$directory" tag v0.1.0 || return 1
    printf 'ignored, uncommitted bytes\n' > "$directory/ignored.txt"
}
BUILD=(bash "$ROOT/scripts/xwin-build.sh" --manifest "$MANIFEST" --bin probe --cache-dir "$CACHE" --offline \
    --release-repo owner/probe --release-tag v0.1.0)
make_project normal || exit 1
SHA=$(git -C "$WORK/project-normal" rev-parse HEAD)
RUSTFLAGS=ignored UNRELATED_SECRET=not-in-evidence "${BUILD[@]}" --project "$WORK/project-normal" --source-sha "$SHA" \
    --run-dir "$WORK/good" --asset-name release-probe.exe --tool probe-cli > "$WORK/success.json" 2> "$WORK/good.stderr" || {
        cat "$WORK/good.stderr" >&2; [[ ! -f "$WORK/good/build.log" ]] || cat "$WORK/good/build.log" >&2; exit 1;
    }
RELEASE_MANIFEST="$WORK/good/release/build-manifest.json"
assert 'release emits one durable JSON result' cmp -s "$WORK/success.json" "$WORK/good/release/result.json"
assert 'release source builds in a committed snapshot rather than checkout' jq -e --arg root "$WORK/good/source" '.project==$root' "$WORK/success.json"
assert 'source checkout stays clean and ignored bytes are absent from build' bash -c \
    '[[ -z $(git -C "$1" status --porcelain) && ! -e "$2/ignored.txt" ]]' _ "$WORK/project-normal" "$WORK/good/source"
assert 'release manifest binds explicit tag SHA repository and source inventory' jq -e --arg sha "$SHA" \
    '.source.git_sha==$sha and .source.git_ref=="refs/tags/v0.1.0" and .source.repository=="https://github.com/owner/probe" and
     (.source.snapshot_sha256|length)==64 and (.source.receipt_sha256|length)==64 and .source.dependencies==[]' "$RELEASE_MANIFEST"
assert 'manifest uses existing DSR successful target and artifact profile' jq -e --arg platform "$TEST_PLATFORM" --arg target "$TEST_TARGET" \
    '.schema_version=="1.0.0" and .tool=="probe-cli" and .status=="success" and .publishable==true and
     .summary=={total:1,success:1,failed:0} and .requested_targets==[$platform] and
     .artifacts[0].name=="release-probe.exe" and .artifacts[0].target==$platform and .artifacts[0].target_triple==$target and
     .hosts==[{host:"local",platform:$platform,status:"success",method:"local"}]' "$RELEASE_MANIFEST"
assert 'release result, executable machine and environment retain the selected architecture' jq -en \
    --arg target "$TEST_TARGET" --arg platform "$TEST_PLATFORM" --argjson machine "$TEST_MACHINE_CODE" \
    --slurpfile result "$WORK/success.json" --slurpfile manifest "$RELEASE_MANIFEST" '
    $result[0].target==$target and $result[0].artifact.machine_code==$machine and
    $result[0].toolchain.target==$target and $manifest[0].build_environments[0].target==$platform and
    $manifest[0].build_environments[0].target_triple==$target and
    $manifest[0].build_environments[0].toolchain.target==$target'
assert 'full evidence is retained in manifest rather than discarded' jq -e \
    '.build_environments[0] | .method=="pinned-cargo-xwin" and (.source_snapshot.files|length)>3 and
     (.toolchain.files|length)>3 and (.toolchain.inputs.tools|has("cargo-xwin")) and
     .cargo_metadata.package=="probe" and (.cargo_metadata.metadata_sha256|length)==64 and
     .build_influence_env.XWIN_CROSS_COMPILER=="clang" and (.build_influence_env|has("UNRELATED_SECRET")|not)' "$RELEASE_MANIFEST"
assert 'dependency-source summary binds the coordinator-held final metadata graph' jq -e \
    --arg sha "$(_xwt_hash "$WORK/good/metadata-after.json")" '
    .build_environments[0].cargo_metadata |
    .metadata_sha256==$sha and .dependency_sources.metadata_sha256==$sha' "$RELEASE_MANIFEST"
assert 'source inventory larger than 128 KiB survives manifest serialization' bash -c \
    '[[ $(wc -c < "$1") -gt 131072 ]] && jq -e ".build_environments[0].source_snapshot.files|length>1000" "$2" >/dev/null' \
    _ "$WORK/good/release-source.json" "$RELEASE_MANIFEST"
assert 'manifest hash is bound into final result' bash -c \
    '[[ $(sha256sum "$1"|cut -d" " -f1) == $(jq -r .release_manifest.sha256 "$2") ]]' _ "$RELEASE_MANIFEST" "$WORK/success.json"
assert 'artifact hash and size match the verified PE bytes' bash -c \
    '[[ $(sha256sum "$1"|cut -d" " -f1) == $(jq -r .artifacts[0].sha256 "$2") && $(wc -c < "$1") == $(jq -r .artifacts[0].size_bytes "$2") ]]' \
    _ "$WORK/good/artifacts/release-probe.exe" "$RELEASE_MANIFEST"
assert 'existing publication/SLSA profile accepts runner manifest' _slsa_manifest_statement "$RELEASE_MANIFEST" owner/probe dsr:pinned-cargo-xwin
cp "$WORK/assert.out" "$WORK/statement.json"
assert 'existing SLSA mapping binds source commit and release asset' jq -e --arg sha "$SHA" \
    '.subject[0].name=="release-probe.exe" and .predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit==$sha' "$WORK/statement.json"
assert 'metadata diagnostic is separated from parseable Cargo JSON' grep -Fxq 'metadata diagnostic on stderr' "$WORK/good/metadata-before.log"
assert 'before and after full dependency graphs agree' cmp -s "$WORK/good/metadata-before.json" "$WORK/good/metadata-after.json"
assert 'release forces the metadata-selected package and JSON artifact messages' jq -e \
    'index("--package")!=null and index("probe")!=null and index("--message-format=json")!=null' "$WORK/good/command.json"
assert 'even dependency-free releases seed from their admitted staged lockfile' jq -e \
    '.cargo_cache.seed.selection.kind=="cargo-lock-downloads" and
     .cargo_cache.seed.selection.lockfile_sha256==.cargo_lock_sha256 and
     .cargo_cache.seed.selection.registry_packages==0 and .cargo_cache.seed.selection.git_revisions==[]' "$WORK/success.json"
reject 'occupied run directory never overwrites a successful manifest' 2 "${BUILD[@]}" --project "$WORK/project-normal" --source-sha "$SHA" --run-dir "$WORK/good"

# A source-pinned release consumes authenticated downloads and freshly created
# private source trees. Ambient extracted sources, unrelated downloads and Git
# checkouts are deliberately unsafe; they cannot become inputs or veto a build.
mkdir -p "$WORK/crate/native-dependency-1.0.0/src" "$WORK/registry-ambient/registry/cache/fixture-registry" \
    "$WORK/registry-ambient/git" "$WORK/poisoned-sources/native-dependency-1.0.0"
printf '[package]\nname="native-dependency"\nversion="1.0.0"\nedition="2021"\n' > "$WORK/crate/native-dependency-1.0.0/Cargo.toml"
printf 'pub fn value() -> u32 { 7 }\n' > "$WORK/crate/native-dependency-1.0.0/src/lib.rs"
printf 'int DsrSiblingValue(void) { return 7; }\n' > "$WORK/crate/native-dependency-1.0.0/native.c"
tar -czf "$WORK/registry-ambient/registry/cache/fixture-registry/native-dependency-1.0.0.crate" \
    -C "$WORK/crate" native-dependency-1.0.0 || exit 1
REGISTRY_CHECKSUM=$(_xwt_hash "$WORK/registry-ambient/registry/cache/fixture-registry/native-dependency-1.0.0.crate") || exit 1
printf '#error ambient source must never compile\n' > "$WORK/poisoned-sources/native-dependency-1.0.0/native.c"
ln -s "$WORK/poisoned-sources" "$WORK/registry-ambient/registry/src"
ln -s "$WORK/poisoned-sources" "$WORK/registry-ambient/git/checkouts"
ln -s "$WORK/poisoned-sources" "$WORK/registry-ambient/git/db"
ln -s "$WORK/poisoned-sources" "$WORK/registry-ambient/registry/cache/fixture-registry/unrelated-9.9.9.crate"
printf 'not a valid archive, and not a locked input\n' > "$WORK/registry-ambient/registry/cache/fixture-registry/unrelated-0.0.1.crate"
make_project registry-ok || exit 1
REGISTRY_SHA=$(git -C "$WORK/project-registry-ok" rev-parse HEAD) || exit 1
assert 'release ignores unsafe unused ambient sources and compiles the locked private download' \
    "${BUILD[@]}" --project "$WORK/project-registry-ok" --source-sha "$REGISTRY_SHA" \
    --run-dir "$WORK/registry-good" --cargo-cache "$WORK/registry-ambient"
assert 'fresh private extraction contains authentic dependency bytes' cmp -s \
    "$WORK/crate/native-dependency-1.0.0/native.c" "$WORK/registry-good/cargo-home/registry/src/fixture-registry/native-dependency-1.0.0/native.c"
assert 'seed inventory contains the locked archive and no ambient extracted sources or Git trees' jq -e \
    '.selection.kind=="cargo-lock-downloads" and .selection.registry_packages==1 and .selection.git_revisions==[] and
     [.inventory.files[].path]==["registry/cache/fixture-registry/native-dependency-1.0.0.crate"]' \
    "$WORK/registry-good/cargo-home/.dsr-cache-seed.json"
assert 'source-pinned cache evidence distinguishes authenticated downloads from later private extraction' jq -e \
    '.cargo_cache.seed.file_count==1 and .cargo_cache.final.file_count==5 and
     .cargo_cache.seed.selection.lockfile_sha256==.cargo_lock_sha256 and
     .cargo_cache.seed.inventory_sha256!=.cargo_cache.final.inventory_sha256' "$WORK/registry-good/release/result.json"
assert "real $TEST_TARGET compilation consumed the authenticated crate C source" grep -Fxq \
    'compiled lockfile-authenticated private crate C source' "$WORK/registry-good/build.log"
assert 'locked dependency contributes to the emitted Windows binary' jq -es \
    'length==2 and all(.[];.artifact.sha256|test("^[0-9a-f]{64}$")) and
     .[0].artifact.sha256!=.[1].artifact.sha256' "$WORK/success.json" "$WORK/registry-good/release/result.json"
assert 'release manifest retains source authentication and the exact selected seed evidence' jq -e \
    --slurpfile result "$WORK/registry-good/release/result.json" \
    '.build_environments[0] | .cargo_cache==$result[0].cargo_cache and
     .cargo_metadata.dependency_sources.authentication.locked_archive_packages==1 and
     .cargo_metadata.dependency_sources.authentication.lockfile_sha256==.cargo_cache.seed.selection.lockfile_sha256' \
    "$WORK/registry-good/release/build-manifest.json"
assert 'finished locked-download private cache verifies independently' cargo_cache_verify \
    "$WORK/registry-good/cargo-home" "$WORK/registry-good/cargo-cache-final.json"
assert 'original poisoned source remains unmodified and unused' grep -Fxq \
    '#error ambient source must never compile' "$WORK/poisoned-sources/native-dependency-1.0.0/native.c"

for CACHE_FAILURE in absent checksum linked; do
    BROKEN_HOME="$WORK/registry-$CACHE_FAILURE-cache"
    mkdir -p "$BROKEN_HOME/registry/cache/fixture-registry"
    ln -s "$WORK/poisoned-sources" "$BROKEN_HOME/registry/src"
    case "$CACHE_FAILURE" in
        checksum) printf 'wrong locked download bytes\n' > "$BROKEN_HOME/registry/cache/fixture-registry/native-dependency-1.0.0.crate" ;;
        linked) ln -s "$WORK/registry-ambient/registry/cache/fixture-registry/native-dependency-1.0.0.crate" \
            "$BROKEN_HOME/registry/cache/fixture-registry/native-dependency-1.0.0.crate" ;;
    esac
    reject "$CACHE_FAILURE required download cannot be replaced by an ambient source tree" 7 \
        "${BUILD[@]}" --project "$WORK/project-registry-ok" --source-sha "$REGISTRY_SHA" \
        --run-dir "$WORK/registry-$CACHE_FAILURE" --cargo-cache "$BROKEN_HOME"
    assert "$CACHE_FAILURE required download fails before any target compiler command" test ! -e "$WORK/registry-$CACHE_FAILURE/build.log"
    assert "$CACHE_FAILURE required download emits no release manifest" test ! -e "$WORK/registry-$CACHE_FAILURE/release"
done
make_project registry-drift || exit 1
REGISTRY_DRIFT_SHA=$(git -C "$WORK/project-registry-drift" rev-parse HEAD) || exit 1
reject 'dependency changed after successful Windows compilation cannot be published' 7 \
    "${BUILD[@]}" --project "$WORK/project-registry-drift" --source-sha "$REGISTRY_DRIFT_SHA" \
    --run-dir "$WORK/registry-drift" --cargo-cache "$WORK/registry-ambient"
assert 'dependency drift fixture completed real selected-target linking before refusal' xwin_validate_pe \
    "$WORK/registry-drift/target/$TEST_TARGET/release/probe.exe" "$TEST_TARGET"
assert 'post-build authentication refusal leaves no release manifest' test ! -e "$WORK/registry-drift/release"

for MODE in source-drift receipt-drift environment-drift graph-receipt-drift graph-drift wrong-package wrong-message-source wrong-features test-profile missing-artifact duplicate-artifact failed-message truncate external-source wrong-version fail; do
    make_project "$MODE" || exit 1
    SOURCE_SHA=$(git -C "$WORK/project-$MODE" rev-parse HEAD)
    EXPECTED=7; [[ "$MODE" != fail ]] || EXPECTED=42
    reject "$MODE cannot publish release success" "$EXPECTED" "${BUILD[@]}" --project "$WORK/project-$MODE" --source-sha "$SOURCE_SHA" --run-dir "$WORK/run-$MODE"
    assert "$MODE leaves no public release manifest/receipt pair" test ! -e "$WORK/run-$MODE/release"
    assert "$MODE retains failure evidence" jq -e --argjson code "$EXPECTED" '.exit_code==$code and .status=="failed"' "$WORK/run-$MODE/failure.json"
done
reject 'partial release identity cannot be enabled accidentally' 4 bash "$ROOT/scripts/xwin-build.sh" --manifest "$MANIFEST" \
    --project "$WORK/project-normal" --bin probe --run-dir "$WORK/partial" --release-repo owner/probe
reject 'unsafe asset name is rejected before run creation' 4 "${BUILD[@]}" --project "$WORK/project-normal" --source-sha "$SHA" \
    --run-dir "$WORK/unsafe" --asset-name ../probe.exe
assert 'invalid asset did not create a run' test ! -e "$WORK/unsafe"

# The real runner now consumes two separately committed dependency roots.
# Metadata is still a Cargo-boundary fixture. C source in helper and a header
# in types genuinely affect the LLVM-linked PE output, not only its receipt.
for SIBLING in helper types; do
    mkdir -p "$WORK/$SIBLING/src"
    printf 'ignored.txt\n' > "$WORK/$SIBLING/.gitignore"
done
printf '[package]\nname="helper"\nversion="0.2.0"\nedition="2021"\n[dependencies]\ntypes={path="../types"}\n' > "$WORK/helper/Cargo.toml"
printf 'pub fn answer() -> i32 { types::answer() }\n' > "$WORK/helper/src/lib.rs"
printf '#include "../types/value.h"\nint DsrSiblingValue(void) { return DSR_PINNED_VALUE; }\n' > "$WORK/helper/native.c"
printf '[package]\nname="types"\nversion="0.3.0"\nedition="2021"\n' > "$WORK/types/Cargo.toml"
printf 'pub fn answer() -> i32 { 314 }\n' > "$WORK/types/src/lib.rs"
printf '#define DSR_PINNED_VALUE 314\n' > "$WORK/types/value.h"
for SIBLING in helper types; do
    git -C "$WORK/$SIBLING" init -qb main && git -C "$WORK/$SIBLING" config user.name 'DSR Fixture' &&
        git -C "$WORK/$SIBLING" config user.email test@example.invalid &&
        git -C "$WORK/$SIBLING" remote add origin "https://github.com/owner/$SIBLING.git" &&
        git -C "$WORK/$SIBLING" add . && git -C "$WORK/$SIBLING" -c commit.gpgsign=false commit -qm dependency || exit 1
    printf 'never used in the build\n' > "$WORK/$SIBLING/ignored.txt"
done
HELPER_SHA=$(git -C "$WORK/helper" rev-parse HEAD)
TYPES_SHA=$(git -C "$WORK/types" rev-parse HEAD)
jq -cn --arg work "$WORK" --arg helper "$HELPER_SHA" --arg types "$TYPES_SHA" \
    '[{relative_path:"types",local_path:($work+"/types"),revision:$types,repo:"owner/types"},
      {relative_path:"helper",local_path:($work+"/helper"),revision:$helper,repo:"owner/helper"}]' > "$WORK/siblings.json"
make_project sibling-ok || exit 1
SIBLING_SOURCE_SHA=$(git -C "$WORK/project-sibling-ok" rev-parse HEAD)
"${BUILD[@]}" --project "$WORK/project-sibling-ok" --source-sha "$SIBLING_SOURCE_SHA" --run-dir "$WORK/sibling-good" \
    --sibling-crates "$WORK/siblings.json" > "$WORK/sibling-result.json" 2> "$WORK/sibling.stderr" || {
        cat "$WORK/sibling.stderr" >&2; [[ ! -f "$WORK/sibling-good/build.log" ]] || cat "$WORK/sibling-good/build.log" >&2; exit 1;
    }
SIBLING_MANIFEST="$WORK/sibling-good/release/build-manifest.json"
assert 'sibling build publishes exactly its durable release receipt' cmp -s "$WORK/sibling-result.json" "$WORK/sibling-good/release/result.json"
assert 'sibling layout builds from the staged primary directory' jq -e --arg root "$WORK/sibling-good/source/project" '.project==$root' "$WORK/sibling-result.json"
assert 'manifest retains both independently pinned dependency revisions' jq -e --arg helper "$HELPER_SHA" --arg types "$TYPES_SHA" \
    '.source.dependencies==[{relative_path:"helper",git_sha:$helper},{relative_path:"types",git_sha:$types}]' "$SIBLING_MANIFEST"
assert 'public result and Cargo selection retain identical sibling pins' jq -en --slurpfile result "$WORK/sibling-result.json" \
    --slurpfile manifest "$SIBLING_MANIFEST" --slurpfile selection "$WORK/sibling-good/selection-after.json" \
    '$result[0].source_dependencies==$manifest[0].source.dependencies and
     $selection[0].source_dependencies==$manifest[0].source.dependencies and
     $result[0].resolved_siblings==["helper","types"] and $selection[0].resolved_siblings==["helper","types"]'
assert 'full repository and file evidence survives manifest export' jq -e \
    '.build_environments[0].source_snapshot | .primary_path=="project" and (.dependencies|length)==2 and
     all(.dependencies[];(.git_tree|length)==40 and (.snapshot_sha256|length)==64) and
     any(.files[];.path=="helper/native.c") and any(.files[];.path=="types/value.h")' "$SIBLING_MANIFEST"
assert 'real LLVM compiler consumed the committed transitive sibling input' grep -Fxq \
    'compiled committed sibling C source with transitive header' "$WORK/sibling-good/build.log"
assert 'admitted sibling output passes selected-target PE validation with its target-qualified name' xwin_validate_pe \
    "$WORK/sibling-good/artifacts/probe-$TEST_TARGET.exe" "$TEST_TARGET"
assert 'dependency Cargo manifests are staged without path rewriting' cmp -s "$WORK/helper/Cargo.toml" "$WORK/sibling-good/source/helper/Cargo.toml"
assert 'primary Cargo manifest is staged without path rewriting' cmp -s "$WORK/project-sibling-ok/Cargo.toml" "$WORK/sibling-good/source/project/Cargo.toml"
assert 'source-set verification uses the entire boundary after compilation' xwin_source_verify "$WORK/sibling-good/source" "$WORK/sibling-good/release-source.json"
assert 'original dependency checkouts remain clean' bash -c \
    '[[ -z $(git -C "$1/helper" status --porcelain) && -z $(git -C "$1/types" status --porcelain) ]]' _ "$WORK"
assert 'existing publication profile accepts pinned sibling dependencies' _slsa_manifest_statement "$SIBLING_MANIFEST" owner/probe dsr:pinned-cargo-xwin
cp "$WORK/assert.out" "$WORK/sibling-statement.json"
assert 'SLSA resolved dependencies bind both sibling revisions' jq -e --arg helper "$HELPER_SHA" --arg types "$TYPES_SHA" \
    '.predicate.buildDefinition.resolvedDependencies | any(.[];.name=="sibling/helper" and .digest.gitCommit==$helper) and
     any(.[];.name=="sibling/types" and .digest.gitCommit==$types)' "$WORK/sibling-statement.json"

for MODE in sibling-drift sibling-plan-drift sibling-receipt-drift sibling-graph-drift sibling-external; do
    make_project "$MODE" || exit 1
    SOURCE_SHA=$(git -C "$WORK/project-$MODE" rev-parse HEAD)
    reject "$MODE cannot publish a release" 7 "${BUILD[@]}" --project "$WORK/project-$MODE" --source-sha "$SOURCE_SHA" \
        --run-dir "$WORK/run-$MODE" --sibling-crates "$WORK/siblings.json"
    assert "$MODE leaves no release manifest" test ! -e "$WORK/run-$MODE/release"
    assert "$MODE retains failure status" jq -e '.exit_code==7 and .status=="failed"' "$WORK/run-$MODE/failure.json"
done
assert 'unlisted metadata source is rejected before compiler invocation' test ! -e "$WORK/run-sibling-external/build.messages.jsonl"
reject 'missing sibling pin file is refused before creating a run' 4 "${BUILD[@]}" --project "$WORK/project-sibling-ok" \
    --source-sha "$SIBLING_SOURCE_SHA" --run-dir "$WORK/missing-plan" --sibling-crates "$WORK/absent.json"
assert 'missing sibling pin file left no run' test ! -e "$WORK/missing-plan"
reject 'sibling option cannot bypass source-pinned release mode' 4 bash "$ROOT/scripts/xwin-build.sh" --manifest "$MANIFEST" \
    --bin probe --project "$WORK/project-sibling-ok" --run-dir "$WORK/no-release" --sibling-crates "$WORK/siblings.json"
reject 'dependent project without sibling admission still fails closed' 7 "${BUILD[@]}" --project "$WORK/project-sibling-ok" \
    --source-sha "$SIBLING_SOURCE_SHA" --run-dir "$WORK/unpinned-siblings"
assert 'unbound dependency was rejected before compiler invocation' test ! -e "$WORK/unpinned-siblings/build.messages.jsonl"
jq '.[0].revision=("1"*40)' "$WORK/siblings.json" > "$WORK/wrong-pin.json"
reject 'wrong sibling pin cannot reach toolchain setup' 4 "${BUILD[@]}" --project "$WORK/project-sibling-ok" \
    --source-sha "$SIBLING_SOURCE_SHA" --run-dir "$WORK/wrong-sibling" --sibling-crates "$WORK/wrong-pin.json"
assert 'failed source-set admission left no toolchain receipt' test ! -e "$WORK/wrong-sibling/toolchain.json"

# A different reviewed transitive commit changes the actual linked executable
# and its retained pin. Fixed PE timestamp removes wall-clock noise from this
# comparison; Cargo remains a declared boundary fixture, not the compiler.
printf '#define DSR_PINNED_VALUE 2718\n' > "$WORK/types/value.h"
git -C "$WORK/types" add value.h && git -C "$WORK/types" -c commit.gpgsign=false commit -qm next-pin || exit 1
NEXT_TYPES_SHA=$(git -C "$WORK/types" rev-parse HEAD)
jq --arg sha "$NEXT_TYPES_SHA" 'map(if .relative_path=="types" then .revision=$sha else . end)' "$WORK/siblings.json" > "$WORK/next-siblings.json"
"${BUILD[@]}" --project "$WORK/project-sibling-ok" --source-sha "$SIBLING_SOURCE_SHA" --run-dir "$WORK/sibling-next" \
    --sibling-crates "$WORK/next-siblings.json" > "$WORK/sibling-next.json" 2> "$WORK/sibling-next.stderr" || {
        cat "$WORK/sibling-next.stderr" >&2; exit 1;
    }
assert 'newly admitted transitive pin is retained in public result' jq -e --arg sha "$NEXT_TYPES_SHA" \
    'any(.source_dependencies[];.relative_path=="types" and .git_sha==$sha)' "$WORK/sibling-next.json"
assert 'transitive committed header changes actual compiled bytes' jq -en --slurpfile before "$WORK/sibling-result.json" \
    --slurpfile after "$WORK/sibling-next.json" '$before[0].artifact.sha256!=$after[0].artifact.sha256'
assert 'old completed snapshot remains independent of advanced original checkout' xwin_source_verify \
    "$WORK/sibling-good/source" "$WORK/sibling-good/release-source.json"
printf '\n%s release path: %s passed, %s failed\n' "$TEST_TARGET" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
