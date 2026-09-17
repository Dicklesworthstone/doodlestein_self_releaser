#!/usr/bin/env bash
# Exercise the generated installer, not copies of its verification functions.
# Real tar archives and SHA256; only remote transports/minisign failure are fixtures.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-install-integrity.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
passed=0 failed=0
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); echo "ok - $label"
    else failed=$((failed + 1)); echo "not ok - $label"; fi
}
mkdir -p "$work/config/repos.d" "$work/payload" "$work/remote" "$work/transports" "$work/home"
export DSR_CONFIG_DIR="$work/config" DSR_INSTALLER_DIR="$work/generated"
export HOME="$work/home" NO_COLOR=1
cat > "$DSR_CONFIG_DIR/repos.d/demo.yaml" <<'CONFIG'
tool_name: demo
repo: example/demo
binary_name: demo
artifact_naming: ${name}-${version}-${os}-${arch}
CONFIG
# shellcheck source=../../src/install_gen.sh
source "${DSR_INSTALL_GEN_MODULE:-$ROOT/src/install_gen.sh}"
installer=$(install_gen_create demo 2> "$work/generate.log") || exit 1
check 'generated Bash parses' bash -n "$installer"
cat > "$work/payload/demo" <<'PAYLOAD'
#!/usr/bin/env bash
printf 'demo 1.2.3\n'
PAYLOAD
chmod +x "$work/payload/demo"
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) exit 3 ;; esac
asset="demo-1.2.3-$os-$arch.tar.gz"
tar -czf "$work/remote/$asset" -C "$work/payload" demo || exit 1
hash=$(sha256sum < "$work/remote/$asset" | awk '{print $1}')
export REMOTE="$work/remote" CALLS="$work/calls" ASSET="$asset"
export CURL_FAIL=0 GH_FAIL=0 CHECKSUM_MODE=good
cat > "$work/transports/curl" <<'TRANSPORT'
#!/usr/bin/env bash
set -uo pipefail
url='' dest=''
while (($#)); do
    case "$1" in
        -o|--output) dest="$2"; shift 2 ;;
        --proto|--proto-redir|--connect-timeout|--max-time|--retry) shift 2 ;;
        https:*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf 'curl %s\n' "$url" >> "$CALLS"
[[ "$CURL_FAIL" == 0 ]] || exit 22
name="${url##*/}"
[[ -f "$REMOTE/$name" ]] || exit 22
cp "$REMOTE/$name" "$dest"
TRANSPORT
cat > "$work/transports/gh" <<'TRANSPORT'
#!/usr/bin/env bash
set -uo pipefail
asset='' dest=''
while (($#)); do
    case "$1" in
        --pattern) asset="$2"; shift 2 ;;
        --output) dest="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf 'gh %s\n' "$asset" >> "$CALLS"
[[ "$GH_FAIL" == 0 && -n "$asset" && -n "$dest" && -f "$REMOTE/$asset" ]] || exit 1
cp "$REMOTE/$asset" "$dest"
TRANSPORT
chmod +x "$work/transports/curl" "$work/transports/gh"
export PATH="$work/transports:$PATH"
case_id=0 status=0 case_dir=''
run_install() {
    case_id=$((case_id + 1)); case_dir="$work/case-$case_id"
    mkdir -p "$case_dir"
    status=0
    bash "$installer" --version v1.2.3 --dir "$case_dir/bin" --cache-dir "$case_dir/cache" \
        --non-interactive --json --no-skills "$@" > "$case_dir/out" 2> "$case_dir/err" || status=$?
}
success() { [[ $status -eq 0 && -x "$case_dir/bin/demo" ]] && jq -es 'length == 1 and .[0].status == "success"' "$case_dir/out" >/dev/null; }
blocked() { [[ $status -ne 0 && ! -e "$case_dir/bin/demo" && ! -e "$case_dir/cache/demo/v1.2.3/$os-$arch.tar.gz" ]]; }
set_manifest() { printf '%s\n' "$1" > "$REMOTE/checksums.sha256"; }
set_manifest "$hash  $asset"
run_install
check 'default install verifies release name, not temporary archive name' success
cache="$case_dir/cache"
check 'verified cache retains checksum evidence' test -s "$cache/demo/v1.2.3/$os-$arch.tar.gz.sha256"
run_install --cache-dir "$cache" --offline
check 'verified cached archive works offline' success
before=$(wc -l < "$CALLS")
run_install --cache-dir "$cache" --offline --require-signatures
check 'required signatures cannot be bypassed through cache' test "$status" -ne 0
check 'offline signature failure never uses transports' test "$(wc -l < "$CALLS")" -eq "$before"
run_install --offline "$REMOTE/$asset"
check 'explicit archive without evidence is rejected' blocked
printf '%s  %s\n' "$hash" "$asset" > "$REMOTE/$asset.sha256"
run_install --offline "$REMOTE/$asset"
check 'explicit archive and exact checksum evidence install offline' success
check 'explicit offline path never uses transports' test "$(wc -l < "$CALLS")" -eq "$before"
mv "$REMOTE/$asset.sha256" "$work/original-sidecar"
for mode in missing empty wrong-name wrong-hash duplicate malformed; do
    case "$mode" in
        missing) mv "$REMOTE/checksums.sha256" "$work/manifest.saved" ;;
        empty) : > "$REMOTE/checksums.sha256" ;;
        wrong-name) set_manifest "$hash  not-$asset" ;;
        wrong-hash) set_manifest "$(printf '%064d' 0)  $asset" ;;
        duplicate) set_manifest "$(printf '%s  %s\n%s  %s' "$hash" "$asset" "$hash" "$asset")" ;;
        malformed) set_manifest "not-a-hash  $asset" ;;
    esac
    run_install
    check "unverified $mode response cannot install or populate cache" blocked
done
set_manifest "${hash^^} *$asset"
run_install
check 'binary-mode uppercase checksum record is accepted' success
set_manifest "$hash  $asset"
CURL_FAIL=1
run_install
check 'gh fallback passes the same checksum gate' success
run_install --prefer-gh
check 'private-repo preference also fetches checksum evidence through gh' success
set_manifest "$(printf '%064d' 0)  $asset"
run_install --prefer-gh
check 'gh success never bypasses checksum mismatch' blocked
CURL_FAIL=0
set_manifest "$hash  $asset"
printf '%s\n' "$hash" > "$REMOTE/$asset.sha256"
run_install
check 'single raw digest is supported in asset-specific sidecar' success
printf 'invalid\n' > "$REMOTE/$asset.sha256"
run_install
check 'malformed asset sidecar cannot fall through to weaker manifest' blocked
mv "$REMOTE/$asset.sha256" "$work/malformed-sidecar"
# Replace the cached archive with another valid tarball; extraction alone would succeed.
printf '#!/usr/bin/env bash\necho wrong-version\n' > "$work/payload/demo"
tar -czf "$work/changed.tar.gz" -C "$work/payload" demo
cp "$work/changed.tar.gz" "$cache/demo/v1.2.3/$os-$arch.tar.gz"
before=$(wc -l < "$CALLS")
run_install --cache-dir "$cache" --offline
check 'tampered cache is rehashed before extraction' test "$status" -ne 0
check 'tampered cached binary is not installed' test ! -e "$case_dir/bin/demo"
check 'tampered cache failure is offline' test "$(wc -l < "$CALLS")" -eq "$before"
for version in ../escape null v1/../../escape '-bad'; do
    run_install --version "$version"
    check "unsafe version rejected: $version" test "$status" -eq 4
done
run_install --version
check 'missing version argument returns invalid-arguments status' test "$status" -eq 4
# An embedded trust key must not be optional even without --require-signatures.
printf 'minisign_pubkey: configured-test-key\n' >> "$DSR_CONFIG_DIR/repos.d/demo.yaml"
installer=$(install_gen_create demo 2>> "$work/generate.log") || exit 1
cat > "$work/transports/minisign" <<'SIGNER'
#!/usr/bin/env bash
printf 'minisign\n' >> "$CALLS"
exit 1
SIGNER
chmod +x "$work/transports/minisign"
printf 'invalid signature\n' > "$REMOTE/$asset.minisig"
run_install
check 'configured signing key fails closed on verification failure' blocked
check 'signature verifier was reached after checksum success' grep -q '^minisign$' "$CALLS"
printf 'Generated installer integrity: %s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
