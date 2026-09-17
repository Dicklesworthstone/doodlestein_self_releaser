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
export CURL_FAIL=0 GH_FAIL=0 LATEST_MODE=none GH_VIEW_TAG=''
export LATEST_JSON='{"tag_name":"v1.2.3"}' LATEST_URL='https://github.com/example/demo/releases/tag/v1.2.3'
cat > "$work/transports/curl" <<'TRANSPORT'
#!/usr/bin/env bash
set -uo pipefail
url='' dest='' effective=false
while (($#)); do
    case "$1" in
        -o|--output) dest="$2"; shift 2 ;;
        --proto|--proto-redir|--connect-timeout|--max-time|--retry|--max-redirs) shift 2 ;;
        -w) effective=true; shift 2 ;;
        https:*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf 'curl %s\n' "$url" >> "$CALLS"
[[ "$CURL_FAIL" == 0 ]] || exit 22
if [[ "$url" == https://api.github.com/* ]]; then
    [[ "$LATEST_MODE" == api ]] || exit 22
    printf '%s\n' "$LATEST_JSON"; exit 0
fi
if $effective; then
    [[ "$LATEST_MODE" == redirect || "$LATEST_MODE" == api ]] || exit 22
    printf '%s' "$LATEST_URL"; exit 0
fi
name="${url##*/}"
[[ -f "$REMOTE/$name" ]] || exit 22
cp "$REMOTE/$name" "$dest"
TRANSPORT
cat > "$work/transports/gh" <<'TRANSPORT'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-} ${2:-}" == 'release view' ]]; then
    printf 'gh view\n' >> "$CALLS"
    [[ "$GH_FAIL" == 0 && -n "$GH_VIEW_TAG" ]] || exit 1
    printf '%s\n' "$GH_VIEW_TAG"; exit 0
fi
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
VERSION_ARGS=(--version v1.2.3)
run_install() {
    case_id=$((case_id + 1)); case_dir="$work/case-$case_id"
    mkdir -p "$case_dir"
    status=0
    bash "$installer" "${VERSION_ARGS[@]}" --dir "$case_dir/bin" --cache-dir "$case_dir/cache" \
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

# Continue with an unsigned fixture; checksums remain mandatory.
cat > "$DSR_CONFIG_DIR/repos.d/demo.yaml" <<'CONFIG'
tool_name: demo
repo: example/demo
binary_name: demo
artifact_naming: ${name}-${version}-${os}-${arch}
CONFIG
installer=$(install_gen_create demo 2>> "$work/generate.log") || exit 1
VERSION_ARGS=()
LATEST_MODE=api
run_install
check 'latest release can be resolved from valid API metadata' success
LATEST_MODE=redirect
run_install
check 'API throttling recovers through the public release redirect' success
for redirect in https://github.com/other/demo/releases/tag/v1.2.3 \
    https://example.org/example/demo/releases/tag/v1.2.3 \
    https://github.com/example/demo/releases/latest \
    https://github.com/example/demo/releases/tag/../bad; do
    LATEST_URL="$redirect"
    run_install
    check "untrusted latest redirect rejected: $redirect" blocked
done
LATEST_MODE=api
LATEST_JSON='{"tag_name":null}'
run_install
check 'invalid API result is not accepted as a version' blocked
GH_VIEW_TAG=v1.2.3 CURL_FAIL=1
run_install --prefer-gh
check 'private latest release discovery works through gh' success
GH_VIEW_TAG='' CURL_FAIL=0
before=$(wc -l < "$CALLS")
run_install --offline
check 'offline latest requires an explicit version' test "$status" -eq 4
check 'offline latest makes no network request' test "$(wc -l < "$CALLS")" -eq "$before"
check 'preflight failure produces one error JSON object' jq -es 'length == 1 and .[0].status == "error"' "$case_dir/out"
VERSION_ARGS=(--version v1.2.3)

# Real upgrades, hardlinks, and write failures. Fail only the final install
# operations, not fixture construction, transport copies, or cache staging.
export REAL_CP REAL_CHMOD REAL_MV INSTALL_FAULT=''
REAL_CP=$(command -v cp); REAL_CHMOD=$(command -v chmod); REAL_MV=$(command -v mv)
cat > "$work/transports/cp" <<'FAULT'
#!/usr/bin/env bash
last="${!#}"
if [[ "$last" == *'/.demo.install.'*'/payload' && "$INSTALL_FAULT" == copy ]]; then
    printf partial > "$last"; exit 1
fi
exec "$REAL_CP" "$@"
FAULT
cat > "$work/transports/chmod" <<'FAULT'
#!/usr/bin/env bash
last="${!#}"
[[ "$last" != *'/.demo.install.'*'/payload' || "$INSTALL_FAULT" != chmod ]] || exit 1
exec "$REAL_CHMOD" "$@"
FAULT
cat > "$work/transports/mv" <<'FAULT'
#!/usr/bin/env bash
if [[ "$INSTALL_FAULT" == rename ]]; then
    for arg in "$@"; do [[ "$arg" != *'/.demo.install.'*'/payload' ]] || exit 1; done
fi
exec "$REAL_MV" "$@"
FAULT
chmod +x "$work/transports/cp" "$work/transports/chmod" "$work/transports/mv"
mkdir -p "$work/upgrade"
printf 'original binary\n' > "$work/old"
for fault in copy chmod rename; do
    cp "$work/old" "$work/upgrade/demo"
    INSTALL_FAULT="$fault"
    run_install --dir "$work/upgrade" --yes
    check "failed $fault returns failure" test "$status" -ne 0
    check "failed $fault preserves existing binary" cmp -s "$work/old" "$work/upgrade/demo"
    check "failed $fault emits error JSON" jq -es 'length == 1 and .[0].status == "error"' "$case_dir/out"
done
INSTALL_FAULT=''
run_install --dir "$work/upgrade" --yes
check 'successful atomic replacement returns success' test "$status" -eq 0
check 'successful replacement installs exact verified payload' cmp -s "$work/case-1/bin/demo" "$work/upgrade/demo"
mkdir -p "$work/hardlinked"
cp "$work/old" "$work/outside"
ln "$work/outside" "$work/hardlinked/demo"
run_install --dir "$work/hardlinked" --yes
check 'upgrade can replace a hardlinked destination' test "$status" -eq 0
check 'hardlink peer is not truncated or modified' cmp -s "$work/old" "$work/outside"
mkdir -p "$work/linked"
ln -s "$work/outside" "$work/linked/demo"
run_install --dir "$work/linked" --yes
check 'symlink install destination is refused' test "$status" -ne 0
check 'symlink target remains unchanged' cmp -s "$work/old" "$work/outside"

# Generate archived payloads with unsafe paths/types and duplicate binaries.
# Every archive has a correct checksum: integrity alone is not shape validation.
if command -v python3 >/dev/null; then
    python3 - "$work" <<'ARCHIVES'
import io, pathlib, sys, tarfile, zipfile
w = pathlib.Path(sys.argv[1]); payload = b'#!/bin/sh\necho demo\n'
cases = {
    'traversal': [('../escape', 'file')],
    'absolute': [(str(w / 'escaped'), 'file')],
    'symlink': [('demo', 'symlink')],
    'hardlink': [('demo', 'hardlink')],
    'fifo': [('demo', 'fifo')],
    'duplicate': [('demo', 'file'), ('demo', 'file')],
    'ambiguous': [('a/demo', 'file'), ('b/demo', 'file')],
    'normal-nested': [('./bin/demo', 'file')],
}
for name, entries in cases.items():
    with tarfile.open(w / (name + '.tar.gz'), 'w:gz') as tf:
        for path, kind in entries:
            info = tarfile.TarInfo(path); info.mode = 0o755
            if kind == 'file':
                info.size = len(payload); tf.addfile(info, io.BytesIO(payload))
            else:
                info.type = {'symlink': tarfile.SYMTYPE, 'hardlink': tarfile.LNKTYPE, 'fifo': tarfile.FIFOTYPE}[kind]
                info.linkname = str(w / 'outside'); tf.addfile(info)
with zipfile.ZipFile(w / 'normal.zip', 'w') as zf:
    zf.writestr('bin/demo', payload)
for fmt, mode in [('tar', 'w'), ('tar.xz', 'w:xz')]:
    with tarfile.open(w / ('normal.' + fmt), mode) as tf:
        info = tarfile.TarInfo('bin/demo'); info.size = len(payload); info.mode = 0o755
        tf.addfile(info, io.BytesIO(payload))
ARCHIVES
    cp "$REMOTE/$asset" "$work/release.saved"
    for shape in traversal absolute symlink hardlink fifo duplicate ambiguous; do
        cp "$work/$shape.tar.gz" "$REMOTE/$asset"
        bad_hash=$(sha256sum < "$REMOTE/$asset" | awk '{print $1}')
        set_manifest "$bad_hash  $asset"
        run_install
        check "checksum-valid $shape archive is rejected" blocked
    done
    check 'unsafe archive extraction did not escape its root' test ! -e "$work/escaped"
    cp "$work/normal-nested.tar.gz" "$REMOTE/$asset"
    set_manifest "$(sha256sum < "$REMOTE/$asset" | awk '{print $1}')  $asset"
    run_install
    check 'ordinary dot-prefixed nested archive remains supported' success
    # Exercise raw payload and zip configuration through the generated main.
    # No copied installer logic; source its harmless --help entry point first.
    for format in none exe zip tar tar.xz; do
        source_file="$work/case-1/bin/demo"
        case "$format" in zip|tar|tar.xz) source_file="$work/normal.$format" ;; esac
        remote_name="demo-1.2.3-$os-$arch"
        [[ "$format" == none ]] || remote_name+=".$format"
        digest=$(sha256sum < "$source_file" | awk '{print $1}')
        printf '%s  %s\n' "$digest" "$remote_name" > "$source_file.sha256"
        status=0
        bash -c 'source "$1" --help >/dev/null 2>&1; ARCHIVE_FORMAT_LINUX="$2"; ARCHIVE_FORMAT_DARWIN="$2";
            main --version v1.2.3 --offline "$3" --dir "$4" --no-skills --non-interactive' \
            bash "$installer" "$format" "$source_file" "$work/format-$format" > "$work/$format.out" 2> "$work/$format.err" || status=$?
        check "generated installer supports $format payload" test "$status" -eq 0
        check "$format payload is installed executable" test -x "$work/format-$format/demo"
    done
else
    echo 'SKIP: python3 unavailable for adversarial archive construction'
fi
printf 'Generated installer integrity: %s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
