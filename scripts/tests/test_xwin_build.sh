#!/usr/bin/env bash
# Command-boundary Cargo fixtures plus real LLVM NEON/SSE compilation and
# ARM64/x64 import-library linking. No Rust Windows build, network, SDK
# download or Windows execution is claimed.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT/src/xwin_build.sh"
for TOOL in jq clang lld-link llvm-ar python3 timeout setsid; do
    command -v "$TOOL" >/dev/null || { printf 'SKIP xwin build: requires %s\n' "$TOOL"; exit 0; }
done
[[ "$(uname -s)" == Linux ]] || { printf 'SKIP xwin build: requires Linux\n'; exit 0; }
WORK=$(mktemp -d)
if [[ "${DSR_KEEP_TEST_FIXTURES:-0}" == 1 ]]; then
    printf 'Retained fixtures: %s\n' "$WORK"
else
    trap 'rm -rf -- "$WORK"' EXIT
fi
PASS=0 FAIL=0
ok() { printf 'PASS %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
assert() { local label=$1; shift; if "$@" > "$WORK/assert.out" 2> "$WORK/assert.err"; then ok "$label"; else bad "$label"; cat "$WORK/assert.err" >&2; fi; }
reject() {
    local label=$1 expected=$2 rc=0; shift 2
    "$@" > "$WORK/rejected.out" 2> "$WORK/rejected.err" || rc=$?
    if [[ "$rc" == "$expected" && ! -s "$WORK/rejected.out" ]]; then ok "$label"; else
        bad "$label (expected $expected, got $rc)"; cat "$WORK/rejected.err" >&2
    fi
}
mkdir -p "$WORK/input/sdk/include" "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc" \
    "$WORK/input/sdk/lib/x86_64-unknown-windows-msvc" "$WORK/input/llvm/include" "$WORK/tools" "$WORK/project"
RESOURCE=$(clang -print-resource-dir) || exit 1
# Preserve a real LLVM header subset, including transitive NEON dependencies.
for HEADER in arm_neon.h arm_bf16.h arm_vector_types.h stdint.h xmmintrin.h emmintrin.h mmintrin.h mm_malloc.h; do
    [[ ! -f "$RESOURCE/include/$HEADER" ]] || cp "$RESOURCE/include/$HEADER" "$WORK/input/llvm/include/" || exit 1
done
printf 'int DsrKernelStub(void) { return 42; }\n' > "$WORK/kernel.c"
clang --target=aarch64-pc-windows-msvc -ffreestanding -c "$WORK/kernel.c" -o "$WORK/kernel.obj" || exit 1
lld-link /dll /noentry /machine:arm64 /export:DsrKernelStub "/out:$WORK/kernel32.dll" "/implib:$WORK/input/sdk/lib/aarch64-unknown-windows-msvc/kernel32.lib" "$WORK/kernel.obj" || exit 1
clang --target=x86_64-pc-windows-msvc -ffreestanding -c "$WORK/kernel.c" -o "$WORK/kernel-x64.obj" || exit 1
lld-link /dll /noentry /machine:x64 /export:DsrKernelStub "/out:$WORK/kernel32-x64.dll" "/implib:$WORK/input/sdk/lib/x86_64-unknown-windows-msvc/kernel32.lib" "$WORK/kernel-x64.obj" || exit 1
printf 'SDK fixture\n' > "$WORK/input/sdk/include/windows.h"
tar -cJf "$WORK/sdk.tar.xz" -C "$WORK/input" sdk || exit 1
tar -czf "$WORK/headers.tar.gz" -C "$WORK/input" llvm || exit 1
printf '[package]\nname="probe"\nversion="0.1.0"\nedition="2021"\n' > "$WORK/project/Cargo.toml"
printf 'version = 3\n' > "$WORK/project/Cargo.lock"
cat > "$WORK/project/probe.c" <<'C'
#if defined(__aarch64__)
#include <arm_neon.h>
#elif defined(__x86_64__)
#include <xmmintrin.h>
int _fltused = 0;
#else
#error Unexpected architecture
#endif
__declspec(dllimport) int DsrKernelStub(void);
int mainCRTStartup(void) {
#if defined(__aarch64__)
    uint8x8_t vector = vdup_n_u8(7);
    return DsrKernelStub() + vget_lane_u8(vector, 0);
#else
    __m128 vector = _mm_set_ss(7.0f);
    return DsrKernelStub() + _mm_cvtss_si32(vector);
#endif
}
C
cat > "$WORK/tools/cargo" <<'SH'
#!/usr/bin/env bash
[[ "$*" == -vV ]] || exit 90
printf 'cargo boundary fixture 1\nhost: linux\n'
SH
cat > "$WORK/tools/rustc" <<'SH'
#!/usr/bin/env bash
[[ "$*" == -vV ]] || exit 90
printf 'rustc boundary fixture 1\nhost: linux\n'
SH
cat > "$WORK/tools/cargo-xwin" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
if [[ "$*" == --version ]]; then printf 'cargo-xwin boundary fixture 1\n'; exit 0; fi
[[ "$1" == xwin && "$2" == build ]] || exit 90
shift 2
[[ "$*" == *'--locked'* && "$*" == *'--release'* ]] || exit 90
target=''
while (($#)); do
    if [[ "$1" == --target && $# -ge 2 && -z "$target" ]]; then target=$2; shift; fi
    shift
done
case "$target" in
    aarch64-pc-windows-msvc) machine=arm64; other_target=x86_64-pc-windows-msvc; other_machine=x64 ;;
    x86_64-pc-windows-msvc) machine=x64; other_target=aarch64-pc-windows-msvc; other_machine=arm64 ;;
    *) exit 90 ;;
esac
[[ -z "${RUSTFLAGS:-}" && -z "${RUSTC_WRAPPER:-}" && -z "${CC:-}" && -z "${UNRELATED_SECRET:-}" ]] || exit 91
[[ "$XWIN_CROSS_COMPILER" == clang && -f "$XWIN_CACHE_DIR/windows-msvc-sysroot/DONE" ]] || exit 92
[[ -f "$LIB/Kernel32.lib" && -f "$LIB/kernel32.lib" ]] || exit 93
[[ ! -e "$CARGO_HOME/config.toml" && ! -e "$HOME/.cargo/config.toml" ]] || exit 94
cmp -s "$LIB/kernel32.lib" "$LIB/Kernel32.lib" || exit 95
mode=$(cat mode 2>/dev/null || printf normal)
source_file=probe.c
case "$mode" in
    fail) printf 'intentional compiler failure\n'; exit 42 ;;
    slow) sleep 60 & sleeper=$!; printf '%s\n' "$sleeper" > "$CARGO_TARGET_DIR.sleep-pid"; wait "$sleeper"; exit $? ;;
    cache-wipe)
        [[ -d "$CARGO_HOME/registry" && ! -L "$CARGO_HOME/registry" && ! -L "$CARGO_HOME/git" &&
           ! -e "$CARGO_HOME/credentials.toml" ]] || exit 96
        source_file="$CARGO_HOME/registry/src/probe.c"
        cmp -s "$source_file" probe.c || exit 96
        # Retire this suite's generated seed paths after the runner prepared
        # the private home and before the real compiler reads it. Checked
        # renames retain evidence and guarantee the original paths disappear.
        ambient="${PWD%/project}/ambient-cache"
        [[ -f "$ambient/test-owned" ]] || exit 96
        mv -- "$ambient/registry" "$ambient/registry.retired" || exit 96
        mv -- "$ambient/git" "$ambient/git.retired" || exit 96
        [[ ! -e "$ambient/registry" && ! -e "$ambient/git" ]] || exit 96
        printf 'new dependency bytes\n' > "$CARGO_HOME/registry/new-dependency"
        ;;
esac
mkdir -p "$CARGO_TARGET_DIR/$target/release"
out="$CARGO_TARGET_DIR/$target/release/probe.exe"
if [[ "$mode" == wrong-arch ]]; then
    printf 'int mainCRTStartup(void) {return 0;}\n' > "$TMPDIR/opposite.c"
    clang --target="$other_target" -ffreestanding -c "$TMPDIR/opposite.c" -o "$TMPDIR/probe.obj" || exit $?
    lld-link /entry:mainCRTStartup /subsystem:console /nodefaultlib "/machine:$other_machine" "/out:$out" "$TMPDIR/probe.obj" || exit $?
else
    # Intentional splitting: these are the exact whitespace-free flags emitted
    # by DSR, not arbitrary user-supplied shell input.
    # shellcheck disable=SC2086
    clang --target="$target" -ffreestanding $CFLAGS -c "$source_file" -o "$TMPDIR/probe.obj" || exit $?
    # lld-link must discover Kernel32.lib from the emitted LIB environment,
    # not a release-local /libpath override or renamed source library.
    lld-link /entry:mainCRTStartup /subsystem:console /nodefaultlib "/machine:$machine" "/out:$out" "$TMPDIR/probe.obj" Kernel32.lib || exit $?
fi
case "$mode" in
    corrupt-header) printf 'drift\n' >> "${LIB%/lib}/include/arm_neon.h" ;;
    corrupt-tool) printf '# changed\n' >> "$RUSTC" ;;
    corrupt-lock) printf '# changed\n' >> Cargo.lock ;;
    corrupt-config) mkdir -p .cargo; printf '[build]\njobs=1\n' > .cargo/config.toml ;;
    corrupt-shim) rm -- "$HOME/../bin/cargo"; ln -s /bin/false "$HOME/../bin/cargo" ;;
    corrupt-cache-seed) printf '\n' >> "$CARGO_HOME/.dsr-cache-seed.json" ;;
    corrupt-cache-summary) printf '\n' >> "$HOME/../cargo-cache-seed.json" ;;
    linked-cache) mkdir -p "$CARGO_HOME/registry"; ln -s "$TMPDIR" "$CARGO_HOME/registry/external" ;;
    truncate) truncate -s 128 "$out" ;;
esac
printf 'compiled and linked probe\n'
SH
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
BUILD=(bash "$ROOT/scripts/xwin-build.sh" --manifest "$MANIFEST" --project "$WORK/project" --bin probe --cache-dir "$CACHE" --offline)
RUSTFLAGS='bad ambient flags' RUSTC_WRAPPER=/not/a/wrapper CC=/not/a/compiler UNRELATED_SECRET=not-retained \
    "${BUILD[@]}" --run-dir "$WORK/good" > "$WORK/success.json" 2> "$WORK/good.stderr" || {
        cat "$WORK/good.stderr" >&2; cat "$WORK/good/build.log" >&2; exit 1;
    }
assert 'real LLVM output verifies as ARM64 PE32+' jq -e '.artifact.format=="PE32+" and .artifact.machine=="IMAGE_FILE_MACHINE_ARM64" and .artifact.size_bytes>512' "$WORK/success.json"
assert 'successful stdout equals durable receipt' cmp -s "$WORK/success.json" "$WORK/good/result.json"
assert 'exact build command and normalized influence environment retained' jq -e \
    '.command[1:3]==["xwin","build"] and (.command|index("--locked"))!=null and (.command|index("--offline"))!=null and
    .build_influence_env.XWIN_CROSS_COMPILER=="clang" and (.build_influence_env|has("UNRELATED_SECRET")|not) and
    (.build_influence_env|has("RUSTFLAGS")|not) and .build_influence_env.RUSTC_WRAPPER==""' "$WORK/success.json"
assert 'tool identities and before/after version hashes retained' jq -e '.toolchain.inputs.tools|has("rustc") and has("cargo-xwin") and has("llvm-ar")' "$WORK/success.json"
assert 'before/after version maps agree' cmp -s "$WORK/good/versions-before.json" "$WORK/good/versions-after.json"
assert 'LLVM NEON source remains unchanged' cmp -s "$RESOURCE/include/arm_neon.h" "$WORK/input/llvm/include/arm_neon.h"
assert 'lowercase pinned sysroot was never renamed' test ! -e "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc/Kernel32.lib"
assert 'original source archive still matches pinned hash' bash -c '[[ "$(sha256sum "$1"|cut -d" " -f1)" == "$(jq -r .sysroot.sha256 "$2")" ]]' _ "$WORK/sdk.tar.xz" "$MANIFEST"
assert 'unseeded build records an empty private cache' jq -e \
    '.cargo_cache.mode=="private-copy" and .cargo_cache.seed.file_count==0 and .cargo_cache.final.file_count==0 and
     (.cargo_cache.seed|has("selection")|not)' "$WORK/success.json"
jq '.target="x86_64-pc-windows-msvc"' "$MANIFEST" > "$WORK/manifest-x64.json" || exit 1
X64_BUILD=(bash "$ROOT/scripts/xwin-build.sh" --manifest "$WORK/manifest-x64.json" \
    --project "$WORK/project" --bin probe --cache-dir "$CACHE" --offline)
if "${X64_BUILD[@]}" --run-dir "$WORK/good-x64" > "$WORK/x64-success.json" 2> "$WORK/good-x64.stderr"; then
    ok 'real LLVM SSE and pinned x64 import library build an AMD64 executable'
else
    bad 'real LLVM SSE and pinned x64 import library build an AMD64 executable'
    cat "$WORK/good-x64.stderr" >&2
    [[ ! -f "$WORK/good-x64/build.log" ]] || cat "$WORK/good-x64/build.log" >&2
    exit 1
fi
assert 'x64 result, command and toolchain evidence retain one selected target' jq -e '
    (.command|index("--target")) as $i |
    .target=="x86_64-pc-windows-msvc" and .artifact.machine=="IMAGE_FILE_MACHINE_AMD64" and
    .artifact.machine_code==34404 and .artifact.format=="PE32+" and .artifact.size_bytes>512 and
    .toolchain.target==.target and .toolchain.inputs.target==.target and
    .command[$i+1]==.target' "$WORK/good-x64/result.json"
X64_VIEW=$(jq -r .view "$WORK/good-x64/toolchain.json")
assert 'selected x64 view has the actual pinned x64 import library' cmp -s \
    "$X64_VIEW/lib/Kernel32.lib" "$WORK/input/sdk/lib/x86_64-unknown-windows-msvc/kernel32.lib"
assert 'selected x64 view does not alias the ARM64 import library' bash -c \
    '! cmp -s "$1" "$2"' _ "$X64_VIEW/lib/Kernel32.lib" \
    "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc/kernel32.lib"
assert 'x64 executable independently passes expected-machine admission' xwin_validate_pe \
    "$WORK/good-x64/artifacts/probe.exe" x86_64-pc-windows-msvc
reject 'ARM64 executable cannot satisfy x64 admission' 7 xwin_validate_pe \
    "$WORK/good/artifacts/probe.exe" x86_64-pc-windows-msvc
reject 'x64 executable cannot satisfy ARM64 admission' 7 xwin_validate_pe \
    "$WORK/good-x64/artifacts/probe.exe" aarch64-pc-windows-msvc
printf 'wrong-arch\n' > "$WORK/project/mode"
reject 'x64 lane refuses a successful compiler that emitted ARM64' 7 \
    "${X64_BUILD[@]}" --run-dir "$WORK/wrong-x64"
assert 'opposite-architecture x64 attempt records failure without result' bash -c '
    [[ ! -e "$1/result.json" ]] && jq -e ".status==\"failed\" and .exit_code==7" "$1/failure.json"' _ "$WORK/wrong-x64"
printf 'normal\n' > "$WORK/project/mode"
mkdir -p "$WORK/ambient-cache/registry/src" "$WORK/ambient-cache/git/db"
touch "$WORK/ambient-cache/test-owned"
cp "$WORK/project/probe.c" "$WORK/ambient-cache/registry/src/probe.c"
printf 'git cache bytes\n' > "$WORK/ambient-cache/git/db/input"
printf 'not inherited\n' > "$WORK/ambient-cache/credentials.toml"
printf 'not inherited\n' > "$WORK/ambient-cache/config.toml"
printf 'cache-wipe\n' > "$WORK/project/mode"
assert 'real ARM64 compilation survives original Cargo cache paths disappearing' \
    "${BUILD[@]}" --run-dir "$WORK/cache-wipe" --cargo-cache "$WORK/ambient-cache"
assert 'fixture actually retired the original registry path' test ! -e "$WORK/ambient-cache/registry"
assert 'fixture actually retired the original git cache path' test ! -e "$WORK/ambient-cache/git"
assert 'seed and newly resolved dependency inventories retained' jq -e \
    '.cargo_cache.mode=="private-copy" and .cargo_cache.seed.file_count==2 and .cargo_cache.final.file_count==3 and
     (.cargo_cache.seed.inventory_sha256 != .cargo_cache.final.inventory_sha256) and .artifact.machine=="IMAGE_FILE_MACHINE_ARM64"' \
    "$WORK/cache-wipe/result.json"
assert 'completed private cache verifies independently' cargo_cache_verify \
    "$WORK/cache-wipe/cargo-home" "$WORK/cache-wipe/cargo-cache-final.json"
mkdir -p "$WORK/ambient-cache/registry"
ln -s "$WORK/project" "$WORK/ambient-cache/registry/escape"
reject 'unsafe seed fails before any compiler runs' 7 "${BUILD[@]}" --run-dir "$WORK/unsafe-cache" --cargo-cache "$WORK/ambient-cache"
assert 'unsafe seed never starts compilation' test ! -e "$WORK/unsafe-cache/build.log"
reject 'occupied run directory is never overwritten' 2 "${BUILD[@]}" --run-dir "$WORK/good"
# Stall the actual preparation subprocess boundary, not the compiler, to
# prove large cache copies have their own deadline and cancellation handling.
mkdir "$WORK/slow-controller"
REAL_PYTHON=$(command -v python3)
{
    printf '#!/usr/bin/env bash\n'
    printf 'if [[ "${3:-}" == snapshot ]]; then\n'
    printf '  sleep 60 & sleeper=$!; printf "%%s\n" "$sleeper" > "$DSR_CACHE_TEST_PID_FILE"; wait "$sleeper"; exit $?\n'
    printf 'fi\nexec %q "$@"\n' "$REAL_PYTHON"
} > "$WORK/slow-controller/python3"
chmod 755 "$WORK/slow-controller/python3"
reject 'cache preparation deadline emits no successful receipt' 124 env \
    PATH="$WORK/slow-controller:$PATH" DSR_CACHE_TEST_PID_FILE="$WORK/cache-deadline/target.sleep-pid" \
    "${BUILD[@]}" --run-dir "$WORK/cache-deadline" --timeout 1
assert 'cache timeout retains its failure code' jq -e '.exit_code==124' "$WORK/cache-deadline/failure.json"
env PATH="$WORK/slow-controller:$PATH" DSR_CACHE_TEST_PID_FILE="$WORK/cache-cancel/target.sleep-pid" \
    "${BUILD[@]}" --run-dir "$WORK/cache-cancel" > "$WORK/cache-cancel.stdout" 2> "$WORK/cache-cancel.stderr" &
CACHE_PID=$!
for ((n=0;n<500;n++)); do [[ ! -f "$WORK/cache-cancel/target.sleep-pid" ]] || break; sleep 0.05; done
if [[ -f "$WORK/cache-cancel/target.sleep-pid" ]]; then
    kill -TERM "$CACHE_PID"
    RC=0; wait "$CACHE_PID" || RC=$?
    assert 'CLI cancellation reaches cache preparation' test "$RC" = 5
    assert 'cancelled cache preparation has no success output' test ! -s "$WORK/cache-cancel.stdout"
    assert 'cancelled cache preparation retains its failure code' jq -e '.exit_code==5' "$WORK/cache-cancel/failure.json"
else
    bad 'cache preparation reached cancellation boundary'
    kill -TERM "$CACHE_PID" 2>/dev/null || true; wait "$CACHE_PID" 2>/dev/null || true
fi
for MODE in fail wrong-arch truncate corrupt-lock corrupt-tool corrupt-header corrupt-config corrupt-shim corrupt-cache-seed corrupt-cache-summary linked-cache; do
    printf '%s\n' "$MODE" > "$WORK/project/mode"
    EXPECTED=7; [[ "$MODE" != fail ]] || EXPECTED=42
    reject "$MODE produces no successful receipt" "$EXPECTED" "${BUILD[@]}" --run-dir "$WORK/$MODE"
    assert "$MODE preserves failure evidence" jq -e --argjson code "$EXPECTED" '.status=="failed" and .exit_code==$code' "$WORK/$MODE/failure.json"
    assert "$MODE never publishes result.json" test ! -e "$WORK/$MODE/result.json"
    case "$MODE" in
        corrupt-lock) printf 'version = 3\n' > "$WORK/project/Cargo.lock" ;;
        corrupt-tool) sed -i '$d' "$WORK/tools/rustc" ;;
        corrupt-header) VIEW=$(jq -r .view "$WORK/good/toolchain.json"); cp "$RESOURCE/include/arm_neon.h" "$VIEW/include/arm_neon.h" ;;
        corrupt-config) rm -- "$WORK/project/.cargo/config.toml" ;;
    esac
done
assert 'sourced build failure preserves caller traps and status' bash -c '
    source "$1/src/xwin_build.sh"
    printf fail > "$2/project/mode"
    trap ": caller trap" TERM
    before=$(trap -p TERM)
    rc=0
    xwin_toolchain_build --manifest "$2/manifest.json" --project "$2/project" --bin probe \
        --cache-dir "$2/cache" --run-dir "$2/sourced" > "$2/sourced.stdout" 2> "$2/sourced.stderr" || rc=$?
    [[ "$rc" == 42 && ! -s "$2/sourced.stdout" && $(trap -p TERM) == "$before" ]] &&
        jq -e ".exit_code==42" "$2/sourced/failure.json" >/dev/null
' _ "$ROOT" "$WORK"
printf 'slow\n' > "$WORK/project/mode"
# Cache preparation now shares the per-phase deadline. Allow its Python
# startup to finish before exercising the deliberately slow compiler above;
# the separate cache-deadline case still tests a one-second preparation limit.
reject 'deadline returns timeout without a success receipt' 124 "${BUILD[@]}" --run-dir "$WORK/deadline" --timeout 10
# SIGTERM to the CLI, not its group, must reach the owned compiler session.
"${BUILD[@]}" --run-dir "$WORK/cancel" > "$WORK/cancel.stdout" 2> "$WORK/cancel.stderr" &
BUILD_PID=$!
for ((n=0;n<500;n++)); do [[ ! -f "$WORK/cancel/target.sleep-pid" ]] || break; sleep 0.05; done
if [[ -f "$WORK/cancel/target.sleep-pid" ]]; then
    kill -TERM "$BUILD_PID"
    RC=0; wait "$BUILD_PID" || RC=$?
    assert 'CLI cancellation returns the interruption code' test "$RC" = 5
    assert 'cancelled build has no success output' test ! -s "$WORK/cancel.stdout"
    assert 'cancelled build retains failure code' jq -e '.exit_code==5' "$WORK/cancel/failure.json"
else
    bad 'build reached cancellation boundary'; kill -TERM "$BUILD_PID" 2>/dev/null || true; wait "$BUILD_PID" 2>/dev/null || true
fi
for RUN in deadline cancel cache-deadline cache-cancel; do
    SLEEP_PID=$(cat "$WORK/$RUN/target.sleep-pid")
    assert "$RUN stops compiler descendants" python3 - "$SLEEP_PID" <<'PY'
from pathlib import Path
import sys
status = Path('/proc') / sys.argv[1] / 'stat'
if status.exists():
    # Zombies are terminated; their lifetime depends on the outer init reaper.
    assert status.read_text().split(') ', 1)[1].split()[0] == 'Z'
PY
done
printf 'normal\n' > "$WORK/project/mode"
printf '{}\n' > "$WORK/project/aarch64-pc-windows-msvc.json"
reject 'local JSON cannot shadow the selected built-in target' 4 "${BUILD[@]}" --run-dir "$WORK/shadow"
printf '{}\n' > "$WORK/project/x86_64-pc-windows-msvc.json"
reject 'local JSON cannot shadow the selected x64 target' 4 "${X64_BUILD[@]}" --run-dir "$WORK/shadow-x64"
# Parser rejection checks mutate independently produced real PE fixtures.
python3 - "$WORK/good/artifacts/probe.exe" "$WORK" <<'PY'
from pathlib import Path
import struct
import sys
image = bytearray(Path(sys.argv[1]).read_bytes())
pe = struct.unpack_from('<I', image, 60)[0]
root = Path(sys.argv[2])
for name, offset, fmt, value in [
    ('machine', pe+4, '<H', 0x8664), ('magic', pe+24, '<H', 0x10b),
    ('offset', 60, '<I', 0xffffffff), ('dll', pe+22, '<H', 0x2002),
    ('sections', pe+6, '<H', 97), ('entry', pe+40, '<I', 0),
]:
    changed = bytearray(image)
    struct.pack_into(fmt, changed, offset, value)
    (root / (name + '.exe')).write_bytes(changed)
(root/'empty.exe').write_bytes(b'')
(root/'symbolic.exe').symlink_to(root/'good/artifacts/probe.exe')
PY
for MODE in machine magic offset dll sections entry empty symbolic; do
    reject "PE validator rejects $MODE" 7 xwin_validate_pe "$WORK/$MODE.exe" aarch64-pc-windows-msvc
done
reject 'PE validator refuses an unsupported target selector' 4 xwin_validate_pe "$WORK/good/artifacts/probe.exe" i686-pc-windows-msvc
printf '\nPinned Windows build path: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
