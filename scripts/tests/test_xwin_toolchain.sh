#!/usr/bin/env bash
# Real archive/filesystem regression tests for dsr-h4y0. No network or SDK
# installation is required; executable fixtures are identity inputs only.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT/src/xwin_toolchain.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
PASS=0 FAIL=0
ok() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert() { local label=$1; shift; if "$@" > "$WORK/assert.out"; then ok "$label"; else bad "$label"; fi; }
reject() {
    local label=$1 expected=$2 rc=0; shift 2
    "$@" > "$WORK/rejected.out" 2> "$WORK/rejected.err" || rc=$?
    if [[ "$rc" == "$expected" && ! -s "$WORK/rejected.out" ]]; then ok "$label"; else
        bad "$label (expected $expected, got $rc)"; cat "$WORK/rejected.err" >&2
    fi
}
mkdir -p "$WORK/input/sdk/include" "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc" "$WORK/input/llvm/include" "$WORK/tools"
printf 'sdk header\n' > "$WORK/input/sdk/include/windows.h"
printf 'pinned kernel32 import library\n' > "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc/kernel32.lib"
printf 'pinned user32 import library\n' > "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc/user32.lib"
printf 'pinned arm_neon header\n' > "$WORK/input/llvm/include/arm_neon.h"
printf 'pinned dependent LLVM header\n' > "$WORK/input/llvm/include/stdint.h"
tar -cJf "$WORK/sdk.tar.xz" -C "$WORK/input" sdk || exit 1
tar -czf "$WORK/headers.tar.gz" -C "$WORK/input" llvm || exit 1
TOOLS='{}'
for tool in cargo cargo-xwin rustc clang lld-link; do
    printf '#!/usr/bin/env bash\nprintf "%s version 1\\n"\n' "$tool" > "$WORK/tools/$tool"
    chmod 755 "$WORK/tools/$tool"
    TOOLS=$(jq -cn --argjson before "$TOOLS" --arg tool "$tool" --arg path "$WORK/tools/$tool" --arg sha "$(_xwt_hash "$WORK/tools/$tool")" \
        '$before+{($tool):{path:$path,sha256:$sha}}') || exit 1
done
jq -cn --arg root "$WORK" --arg sdk "$(_xwt_hash "$WORK/sdk.tar.xz")" --arg headers "$(_xwt_hash "$WORK/headers.tar.gz")" --argjson tools "$TOOLS" \
    '{schema_version:1,target:"aarch64-pc-windows-msvc",
      sysroot:{path:($root+"/sdk.tar.xz"),sha256:$sdk,url:"https://example.invalid/sdk/pinned.tar.xz",prefix:"sdk"},
      headers:{path:($root+"/headers.tar.gz"),sha256:$headers,url:"https://example.invalid/llvm/pinned.tar.gz",prefix:"llvm/include"},
      aliases:{"Kernel32.lib":"kernel32.lib","User32.lib":"user32.lib"},tools:$tools}' > "$WORK/manifest.json" || exit 1
MANIFEST="$WORK/manifest.json"
CACHE="$WORK/cache"
if ! xwin_toolchain_prepare "$MANIFEST" "$CACHE" > "$WORK/first.json"; then
    printf 'Initial preparation failed\n' >&2; exit 1
fi
VIEW=$(jq -r .view "$WORK/first.json")
assert 'prepared result is one structured receipt' jq -es 'length==1 and .[0].status=="prepared"' "$WORK/first.json"
assert 'MSVC-cased alias has the pinned lower-case bytes' cmp -s "$VIEW/lib/Kernel32.lib" "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc/kernel32.lib"
assert 'canonical lower-case library remains available' cmp -s "$VIEW/lib/kernel32.lib" "$VIEW/lib/Kernel32.lib"
assert 'LLVM header dependency tree is retained' cmp -s "$VIEW/include/stdint.h" "$WORK/input/llvm/include/stdint.h"
assert 'source input directory was not case-renamed' test ! -e "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc/Kernel32.lib"
assert 'aliases are copies, not hardlinks to pinned source files' test ! "$VIEW/lib/Kernel32.lib" -ef "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc/kernel32.lib"
assert 'cargo-xwin DONE marker is pinned URL, not latest discovery' grep -Fxq 'https://example.invalid/sdk/pinned.tar.xz' "$VIEW/sysroot/DONE"
assert 'evidence binds archive, tool and relevant file hashes' jq -e --argjson tools "$TOOLS" \
    '.inputs.tools==$tools and (.inputs.sysroot.sha256|length)==64 and any(.files[];.path=="lib/Kernel32.lib") and any(.files[];.path=="include/arm_neon.h")' "$VIEW/evidence.json"
assert 'compiler flags use the prepared headers and library view' jq -e --arg view "$VIEW" \
    '.environment.CFLAGS==("-nobuiltininc -isystem "+$view+"/include") and .environment.LIB==($view+"/lib") and .environment.XWIN_CROSS_COMPILER=="clang"' "$WORK/first.json"
BEFORE=$(stat -c '%d:%i' "$VIEW/lib/Kernel32.lib")
assert 'second preparation revalidates and reuses the view' xwin_toolchain_prepare "$MANIFEST" "$CACHE" verify
assert 'verified reuse preserves the original inode' test "$(stat -c '%d:%i' "$VIEW/lib/Kernel32.lib")" = "$BEFORE"
reject 'verify refuses an absent cache' 7 xwin_toolchain_prepare "$MANIFEST" "$WORK/absent" verify
assert 'verify did not create the absent cache' test ! -e "$WORK/absent"
reject 'flag-bearing cache paths cannot contain spaces' 4 xwin_toolchain_prepare "$MANIFEST" "$WORK/bad cache"
jq '.target="x86_64-pc-windows-msvc"' "$MANIFEST" > "$WORK/bad.json"
reject 'wrong target rejected before preparation' 4 xwin_toolchain_prepare "$WORK/bad.json" "$CACHE"
jq '.aliases["Kernel32.lib"]="user32.lib"' "$MANIFEST" > "$WORK/bad.json"
reject 'aliases cannot substitute a different library' 4 xwin_toolchain_prepare "$WORK/bad.json" "$CACHE"
jq '.aliases["../Kernel32.lib"]="kernel32.lib"' "$MANIFEST" > "$WORK/bad.json"
reject 'alias path traversal rejected' 4 xwin_toolchain_prepare "$WORK/bad.json" "$CACHE"
jq '.headers.prefix="../llvm/include"' "$MANIFEST" > "$WORK/bad.json"
reject 'archive prefix traversal rejected' 4 xwin_toolchain_prepare "$WORK/bad.json" "$CACHE"
jq '.sysroot.sha256=("0"*64)' "$MANIFEST" > "$WORK/bad.json"
reject 'changed source hash refused' 7 xwin_toolchain_prepare "$WORK/bad.json" "$CACHE"
# Real, correctly hash-pinned archives can still violate the closure contract.
printf 'conflicting bytes\n' > "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc/Kernel32.lib"
tar -cJf "$WORK/conflict.tar.xz" -C "$WORK/input" sdk || exit 1
jq --arg path "$WORK/conflict.tar.xz" --arg sha "$(_xwt_hash "$WORK/conflict.tar.xz")" \
    '.sysroot.path=$path|.sysroot.sha256=$sha' "$MANIFEST" > "$WORK/bad.json"
reject 'differently cased libraries with conflicting bytes are refused' 4 xwin_toolchain_prepare "$WORK/bad.json" "$CACHE"
mkdir -p "$WORK/missing/llvm/include"
printf 'unrelated header\n' > "$WORK/missing/llvm/include/stdint.h"
tar -czf "$WORK/missing.tar.gz" -C "$WORK/missing" llvm || exit 1
jq --arg path "$WORK/missing.tar.gz" --arg sha "$(_xwt_hash "$WORK/missing.tar.gz")" \
    '.headers.path=$path|.headers.sha256=$sha' "$MANIFEST" > "$WORK/bad.json"
reject 'missing ARM NEON headers cannot produce a prepared view' 4 xwin_toolchain_prepare "$WORK/bad.json" "$CACHE"
ln -s /etc/passwd "$WORK/missing/llvm/include/arm_neon.h"
tar -czf "$WORK/linked.tar.gz" -C "$WORK/missing" llvm || exit 1
jq --arg path "$WORK/linked.tar.gz" --arg sha "$(_xwt_hash "$WORK/linked.tar.gz")" \
    '.headers.path=$path|.headers.sha256=$sha' "$MANIFEST" > "$WORK/bad.json"
reject 'linked archive members are refused before extraction' 4 xwin_toolchain_prepare "$WORK/bad.json" "$CACHE"
cat "$MANIFEST" "$MANIFEST" > "$WORK/bad.json"
reject 'concatenated manifest documents are refused' 4 xwin_toolchain_prepare "$WORK/bad.json" "$CACHE"
contended_prepare() (
    exec 8>> "$CACHE/$(jq -r .manifest_sha256 "$WORK/first.json").lock"
    flock -n 8 || exit 1
    xwin_toolchain_prepare "$MANIFEST" "$CACHE"
)
reject 'concurrent admission is bounded and refuses the occupied lock' 2 contended_prepare
printf 'changed\n' >> "$WORK/tools/clang"
reject 'compiler identity drift refused before cache reuse' 7 xwin_toolchain_prepare "$MANIFEST" "$CACHE" verify
printf '#!/usr/bin/env bash\nprintf "clang version 1\\n"\n' > "$WORK/tools/clang"
printf 'corrupt library\n' > "$VIEW/lib/Kernel32.lib"
reject 'cache library corruption rejected' 7 xwin_toolchain_prepare "$MANIFEST" "$CACHE" verify
# A forged receipt cannot bless a modified view: admission is re-derived from
# the pinned source archives, not merely from self-consistent cached metadata.
jq --arg sha "$(_xwt_hash "$VIEW/lib/Kernel32.lib")" '.files|=map(if .path=="lib/Kernel32.lib" then .sha256=$sha else . end)' \
    "$VIEW/evidence.json" > "$WORK/forged.json"
cp "$WORK/forged.json" "$VIEW/evidence.json"
reject 'forged local evidence does not admit corrupted libraries' 7 xwin_toolchain_prepare "$MANIFEST" "$CACHE" verify
assert 'CLI accepts the same manifest and rejects damaged cache' bash -c \
    'bash "$1/scripts/xwin-toolchain.sh" verify --manifest "$2" --cache-dir "$3" >/dev/null 2>&1; [[ $? == 7 ]]' _ "$ROOT" "$MANIFEST" "$CACHE"
reject 'CLI repeated options rejected' 4 bash "$ROOT/scripts/xwin-toolchain.sh" prepare --manifest "$MANIFEST" --manifest "$MANIFEST"
assert 'temporary preparation directories are cleaned after failures' bash -c '[[ -z $(find "$1" -maxdepth 1 -name ".prepare.*" -print -quit) ]]' _ "$CACHE"
printf '\nWindows ARM64 toolchain preparation: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
