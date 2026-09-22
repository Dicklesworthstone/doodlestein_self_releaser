#!/usr/bin/env bash
# Command-boundary fixtures plus real LLVM NEON compilation and ARM64 import
# library linking. No Rust build, network, SDK download or Windows execution.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT/src/xwin_build.sh"
for TOOL in jq clang lld-link llvm-ar python3 timeout setsid; do
    command -v "$TOOL" >/dev/null || { printf 'SKIP xwin build: requires %s\n' "$TOOL"; exit 0; }
done
[[ "$(uname -s)" == Linux ]] || { printf 'SKIP xwin build: requires Linux\n'; exit 0; }
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
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
mkdir -p "$WORK/input/sdk/include" "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc" "$WORK/input/llvm/include" "$WORK/tools" "$WORK/project"
RESOURCE=$(clang -print-resource-dir) || exit 1
# Preserve a real LLVM header subset, including transitive NEON dependencies.
for HEADER in arm_neon.h arm_bf16.h arm_vector_types.h stdint.h; do
    [[ ! -f "$RESOURCE/include/$HEADER" ]] || cp "$RESOURCE/include/$HEADER" "$WORK/input/llvm/include/" || exit 1
done
printf 'int DsrKernelStub(void) { return 42; }\n' > "$WORK/kernel.c"
clang --target=aarch64-pc-windows-msvc -ffreestanding -c "$WORK/kernel.c" -o "$WORK/kernel.obj" || exit 1
lld-link /dll /noentry /machine:arm64 /export:DsrKernelStub "/out:$WORK/kernel32.dll" "/implib:$WORK/input/sdk/lib/aarch64-unknown-windows-msvc/kernel32.lib" "$WORK/kernel.obj" || exit 1
printf 'SDK fixture\n' > "$WORK/input/sdk/include/windows.h"
tar -cJf "$WORK/sdk.tar.xz" -C "$WORK/input" sdk || exit 1
tar -czf "$WORK/headers.tar.gz" -C "$WORK/input" llvm || exit 1
printf '[package]\nname="probe"\nversion="0.1.0"\nedition="2021"\n' > "$WORK/project/Cargo.toml"
printf 'version = 3\n' > "$WORK/project/Cargo.lock"
cat > "$WORK/project/probe.c" <<'C'
#include <arm_neon.h>
__declspec(dllimport) int DsrKernelStub(void);
int mainCRTStartup(void) {
    uint8x8_t vector = vdup_n_u8(7);
    return DsrKernelStub() + vget_lane_u8(vector, 0);
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
[[ "$*" == *'--locked'* && "$*" == *'--release'* && "$*" == *'--target aarch64-pc-windows-msvc'* ]] || exit 90
[[ -z "${RUSTFLAGS:-}" && -z "${RUSTC_WRAPPER:-}" && -z "${CC:-}" && -z "${UNRELATED_SECRET:-}" ]] || exit 91
[[ "$XWIN_CROSS_COMPILER" == clang && -f "$XWIN_CACHE_DIR/windows-msvc-sysroot/DONE" ]] || exit 92
[[ -f "$LIB/Kernel32.lib" && -f "$LIB/kernel32.lib" ]] || exit 93
[[ ! -e "$CARGO_HOME/config.toml" && ! -e "$HOME/.cargo/config.toml" ]] || exit 94
cmp -s "$LIB/kernel32.lib" "$LIB/Kernel32.lib" || exit 95
mode=$(cat mode 2>/dev/null || printf normal)
case "$mode" in
    fail) printf 'intentional compiler failure\n'; exit 42 ;;
    slow) sleep 60 & sleeper=$!; printf '%s\n' "$sleeper" > "$CARGO_TARGET_DIR.sleep-pid"; wait "$sleeper"; exit $? ;;
esac
mkdir -p "$CARGO_TARGET_DIR/aarch64-pc-windows-msvc/release"
out="$CARGO_TARGET_DIR/aarch64-pc-windows-msvc/release/probe.exe"
if [[ "$mode" == wrong-arch ]]; then
    printf 'int mainCRTStartup(void) {return 0;}\n' > "$TMPDIR/x64.c"
    clang --target=x86_64-pc-windows-msvc -ffreestanding -c "$TMPDIR/x64.c" -o "$TMPDIR/probe.obj" || exit $?
    lld-link /entry:mainCRTStartup /subsystem:console /nodefaultlib /machine:x64 "/out:$out" "$TMPDIR/probe.obj" || exit $?
else
    # Intentional splitting: these are the exact whitespace-free flags emitted
    # by DSR, not arbitrary user-supplied shell input.
    # shellcheck disable=SC2086
    clang --target=aarch64-pc-windows-msvc -ffreestanding $CFLAGS -c probe.c -o "$TMPDIR/probe.obj" || exit $?
    # lld-link must discover Kernel32.lib from the emitted LIB environment,
    # not a release-local /libpath override or renamed source library.
    lld-link /entry:mainCRTStartup /subsystem:console /nodefaultlib /machine:arm64 "/out:$out" "$TMPDIR/probe.obj" Kernel32.lib || exit $?
fi
case "$mode" in
    corrupt-header) printf 'drift\n' >> "${LIB%/lib}/include/arm_neon.h" ;;
    corrupt-tool) printf '# changed\n' >> "$RUSTC" ;;
    corrupt-lock) printf '# changed\n' >> Cargo.lock ;;
    corrupt-config) mkdir -p .cargo; printf '[build]\njobs=1\n' > .cargo/config.toml ;;
    corrupt-shim) rm -- "$HOME/../bin/cargo"; ln -s /bin/false "$HOME/../bin/cargo" ;;
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
reject 'occupied run directory is never overwritten' 2 "${BUILD[@]}" --run-dir "$WORK/good"
for MODE in fail wrong-arch truncate corrupt-lock corrupt-tool corrupt-header corrupt-config corrupt-shim; do
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
reject 'deadline returns timeout without a success receipt' 124 "${BUILD[@]}" --run-dir "$WORK/deadline" --timeout 1
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
for RUN in deadline cancel; do
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
    reject "PE validator rejects $MODE" 7 xwin_validate_arm64_pe "$WORK/$MODE.exe"
done
printf '\nWindows ARM64 build path: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
