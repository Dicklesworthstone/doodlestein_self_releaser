#!/usr/bin/env bash
# A real inventory larger than Linux's per-argument limit must be admitted,
# retained and revalidated without passing the inventory through exec argv.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT/src/xwin_toolchain.sh"
[[ "$(uname -s)" == Linux ]] || { printf 'SKIP xwin scale: requires Linux\n'; exit 0; }
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/input/sdk/include" "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc" "$WORK/input/llvm/include"
printf 'header\n' > "$WORK/input/llvm/include/arm_neon.h"
printf 'import lib\n' > "$WORK/input/sdk/lib/aarch64-unknown-windows-msvc/kernel32.lib"
printf -v LONG '%0190d' 0
for ((n=0;n<550;n++)); do printf 'header %d\n' "$n" > "$WORK/input/sdk/include/$LONG-$n.h"; done
tar -czf "$WORK/sdk.tar.gz" -C "$WORK/input" sdk || exit 1
tar -czf "$WORK/llvm.tar.gz" -C "$WORK/input" llvm || exit 1
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/tool"
chmod 755 "$WORK/tool"
jq -cn --arg root "$WORK" --arg tool "$(_xwt_hash "$WORK/tool")" --arg sdk "$(_xwt_hash "$WORK/sdk.tar.gz")" --arg llvm "$(_xwt_hash "$WORK/llvm.tar.gz")" '
    {schema_version:1,target:"aarch64-pc-windows-msvc",
     sysroot:{path:($root+"/sdk.tar.gz"),prefix:"sdk",sha256:$sdk,url:"https://example.invalid/pinned/sdk.tar.gz"},
     headers:{path:($root+"/llvm.tar.gz"),prefix:"llvm/include",sha256:$llvm,url:"https://example.invalid/pinned/llvm.tar.gz"},
     aliases:{"Kernel32.lib":"kernel32.lib"},
     tools:(["cargo","cargo-xwin","rustc","clang","lld-link"]|map({key:.,value:{path:($root+"/tool"),sha256:$tool}})|from_entries)
    }' > "$WORK/manifest.json" || exit 1
PASS=0 FAIL=0
assert() { local label=$1; shift; if "$@"; then printf 'PASS %s\n' "$label"; PASS=$((PASS+1)); else printf 'FAIL %s\n' "$label" >&2; FAIL=$((FAIL+1)); fi; }
xwin_toolchain_prepare "$WORK/manifest.json" "$WORK/cache" > "$WORK/result.json" || exit 1
VIEW=$(jq -r .view "$WORK/result.json")
assert 'retained evidence exceeds the 128 KiB argument limit' test "$(wc -c < "$VIEW/evidence.json")" -gt 131072
assert 'large output remains exactly one complete JSON receipt' jq -es 'length==1 and .[0].status=="prepared" and (.[0].evidence.files|length)>550' "$WORK/result.json" > "$WORK/assert.json"
xwin_toolchain_prepare "$WORK/manifest.json" "$WORK/cache" verify > "$WORK/verified.json" || exit 1
assert 'large view can be revalidated without argv limits' jq -e '.status=="verified"' "$WORK/verified.json" > "$WORK/assert.json"
assert 'retained inventory is identical after revalidation' bash -c 'cmp -s <(jq -c .evidence "$1") <(jq -c .evidence "$2")' _ "$WORK/result.json" "$WORK/verified.json"
cat "$WORK/manifest.json" "$WORK/manifest.json" > "$WORK/multiple.json"
rc=0
xwin_toolchain_prepare "$WORK/multiple.json" "$WORK/cache" > "$WORK/rejected.json" 2>/dev/null || rc=$?
assert 'single-read manifest validation rejects concatenated documents' test "$rc" = 4
assert 'invalid manifest produces no partial JSON receipt' test ! -s "$WORK/rejected.json"
printf '\nWindows ARM64 large inventory: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
