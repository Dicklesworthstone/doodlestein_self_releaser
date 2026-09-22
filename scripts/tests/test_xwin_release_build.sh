#!/usr/bin/env bash
# Source-pinned release execution through the real runner and manifest validator.
# Git, LLVM NEON compilation and ARM64 linking are real. Cargo/rustc/cargo-xwin
# are command-boundary fixtures; no Rust dependency build or Windows execution.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT/src/xwin_build.sh"
source "$ROOT/src/xwin_source.sh"
source "$ROOT/src/slsa.sh"
for TOOL in jq git clang lld-link llvm-ar python3 timeout setsid; do
    command -v "$TOOL" >/dev/null || { printf 'SKIP xwin release: requires %s\n' "$TOOL"; exit 0; }
done
[[ "$(uname -s)" == Linux ]] || { printf 'SKIP xwin release: requires Linux\n'; exit 0; }
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
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
mkdir -p "$WORK/input/sdk/include" "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc" "$WORK/input/llvm/include" "$WORK/tools" "$WORK/template/src"
RESOURCE=$(clang -print-resource-dir) || exit 1
for HEADER in arm_neon.h arm_bf16.h arm_vector_types.h stdint.h; do
    [[ ! -f "$RESOURCE/include/$HEADER" ]] || cp "$RESOURCE/include/$HEADER" "$WORK/input/llvm/include/" || exit 1
done
printf 'int DsrKernelStub(void) { return 42; }\n' > "$WORK/kernel.c"
clang --target=aarch64-pc-windows-msvc -ffreestanding -c "$WORK/kernel.c" -o "$WORK/kernel.obj" || exit 1
lld-link /dll /noentry /machine:arm64 /export:DsrKernelStub "/out:$WORK/kernel32.dll" "/implib:$WORK/input/sdk/lib/aarch64-unknown-windows-msvc/kernel32.lib" "$WORK/kernel.obj" || exit 1
printf 'SDK fixture\n' > "$WORK/input/sdk/include/windows.h"
tar -cJf "$WORK/sdk.tar.xz" -C "$WORK/input" sdk || exit 1
tar -czf "$WORK/headers.tar.gz" -C "$WORK/input" llvm || exit 1
printf '[package]\nname="probe"\nversion="0.1.0"\nedition="2021"\n' > "$WORK/template/Cargo.toml"
printf 'version = 3\n' > "$WORK/template/Cargo.lock"
printf 'fn main() {}\n' > "$WORK/template/src/main.rs"
printf 'ignored.txt\n' > "$WORK/template/.gitignore"
cat > "$WORK/template/probe.c" <<'C'
#include <arm_neon.h>
__declspec(dllimport) int DsrKernelStub(void);
#ifdef DSR_SIBLING
int DsrSiblingValue(void);
#endif
int mainCRTStartup(void) {
    uint8x8_t vector = vdup_n_u8(7);
#ifdef DSR_SIBLING
    return DsrKernelStub() + vget_lane_u8(vector, 0) + DsrSiblingValue();
#else
    return DsrKernelStub() + vget_lane_u8(vector, 0);
#endif
}
C
cat > "$WORK/tools/cargo" <<'CARGO'
#!/usr/bin/env bash
set -uo pipefail
if [[ "$*" == -vV ]]; then printf 'cargo release fixture 1\nhost: linux\n'; exit 0; fi
[[ "$1" == metadata && "$*" == *'--locked'* && "$*" == *'--filter-platform aarch64-pc-windows-msvc'* ]] || exit 90
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
[[ "$1" == xwin && "$2" == build && "$*" == *'--package probe'* && "$*" == *'--message-format=json'* && "$*" == *'--target aarch64-pc-windows-msvc'* && "$*" == *'--locked'* ]] || exit 90
[[ "$XWIN_CROSS_COMPILER" == clang && -n "${SOURCE_DATE_EPOCH:-}" && -z "${UNRELATED_SECRET:-}" && ! -e .git ]] || exit 91
mode=$(cat mode)
case "$mode" in fail) printf 'intentional compiler failure\n' >&2; exit 42 ;; esac
mkdir -p "$CARGO_TARGET_DIR/aarch64-pc-windows-msvc/release"
out="$CARGO_TARGET_DIR/aarch64-pc-windows-msvc/release/probe.exe"
compile_flags=() objects=()
if [[ "$mode" == sibling-* ]]; then
    [[ ! -e ../helper/.git && ! -e ../types/.git && ! -e ../helper/ignored.txt ]] || exit 92
    compile_flags=(-DDSR_SIBLING=1)
    clang --target=aarch64-pc-windows-msvc -ffreestanding -c ../helper/native.c -o "$TMPDIR/helper.obj" || exit $?
    objects+=("$TMPDIR/helper.obj")
    printf 'compiled committed sibling C source with transitive header\n' >&2
fi
# Splitting only the controlled whitespace-free compiler flags from the runner.
# shellcheck disable=SC2086
clang --target=aarch64-pc-windows-msvc -ffreestanding $CFLAGS "${compile_flags[@]}" -c probe.c -o "$TMPDIR/probe.obj" || exit $?
lld-link /entry:mainCRTStartup /subsystem:console /nodefaultlib /machine:arm64 /timestamp:0 "/out:$out" "$TMPDIR/probe.obj" "${objects[@]}" Kernel32.lib || exit $?
case "$mode" in
    source-drift) printf '// source changed\n' >> src/main.rs ;;
    receipt-drift) printf '\n' >> "$HOME/../release-source.json" ;;
    environment-drift) printf '\n' >> "$HOME/../environment.json" ;;
    graph-receipt-drift) printf '\n' >> "$HOME/../metadata-before.json" ;;
    truncate) truncate -s 128 "$out" ;;
    sibling-drift) printf '// changed transitive header\n' >> ../types/value.h ;;
    sibling-plan-drift) printf '\n' >> "$HOME/../sibling-crates.json" ;;
    sibling-receipt-drift) printf '\n' >> "$HOME/../release-source.json" ;;
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
jq -cn --arg root "$WORK" --arg sdk "$(_xwt_hash "$WORK/sdk.tar.xz")" --arg headers "$(_xwt_hash "$WORK/headers.tar.gz")" --argjson tools "$TOOLS" \
    '{schema_version:1,target:"aarch64-pc-windows-msvc",sysroot:{path:($root+"/sdk.tar.xz"),sha256:$sdk,url:"https://example.invalid/pinned/sdk.tar.xz",prefix:"sdk"},
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
assert 'manifest uses existing DSR successful target and artifact profile' jq -e \
    '.schema_version=="1.0.0" and .tool=="probe-cli" and .status=="success" and .publishable==true and
     .summary=={total:1,success:1,failed:0} and .artifacts[0].name=="release-probe.exe" and .artifacts[0].target=="windows/arm64"' "$RELEASE_MANIFEST"
assert 'full evidence is retained in manifest rather than discarded' jq -e \
    '.build_environments[0] | .method=="pinned-cargo-xwin" and (.source_snapshot.files|length)>3 and
     (.toolchain.files|length)>3 and (.toolchain.inputs.tools|has("cargo-xwin")) and
     .cargo_metadata.package=="probe" and (.cargo_metadata.metadata_sha256|length)==64 and
     .build_influence_env.XWIN_CROSS_COMPILER=="clang" and (.build_influence_env|has("UNRELATED_SECRET")|not)' "$RELEASE_MANIFEST"
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
reject 'occupied run directory never overwrites a successful manifest' 2 "${BUILD[@]}" --project "$WORK/project-normal" --source-sha "$SHA" --run-dir "$WORK/good"
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
assert 'admitted sibling output passes ARM64 PE validation' xwin_validate_arm64_pe "$WORK/sibling-good/artifacts/probe-aarch64-pc-windows-msvc.exe"
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
printf '\nWindows ARM64 release path: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
