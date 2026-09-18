#!/usr/bin/env bash
# Release checksum contracts: real hashing, filenames, aliases and publication.
# Fault cases replace a single local boundary; no network or signing keys used.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${DSR_CHECKSUM_MODULE:-$ROOT/src/checksum_sync.sh}" || exit 1
for dependency in sha256sum jq; do
    command -v "$dependency" >/dev/null || { echo "SKIP: $dependency required"; exit 0; }
done
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/dsr-checksum-test.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEMP"' EXIT
export NO_COLOR=1
passed=0 failed=0 status=0 result=''
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); printf 'PASS: %s\n' "$label"
    else failed=$((failed + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
equal() { [[ "$1" == "$2" ]]; }
run() { status=0; result=$("$@" 2> "$TEMP/last.err") || status=$?; }
rejected() { [[ "$status" != 0 && -z "$result" ]]; }
mkdir "$TEMP/assets" "$TEMP/empty" "$TEMP/nested" "$TEMP/nested/bin"
ASSETS="$TEMP/assets"
printf 'release executable\n' > "$ASSETS/tool-1.2.3-linux-amd64.tar.gz"
ln "$ASSETS/tool-1.2.3-linux-amd64.tar.gz" "$ASSETS/tool-linux-amd64.tar.gz"
printf 'other target\n' > "$ASSETS/tool-1.2.3-darwin-arm64.tar.xz"
printf 'space in name\n' > "$ASSETS/tool release.zip"
printf 'equals & brackets\n' > "$ASSETS/tool=[x]&y"
printf 'empty is hashable' > "$ASSETS/empty"; : > "$ASSETS/empty"
MANIFEST="$TEMP/checksums.sha256"
run checksum_generate "$ASSETS" --output "$MANIFEST"
check 'complete release manifest generation succeeds' equal "$status" 0
check 'file output does not leak checksum text to stdout' equal "$result" ''
check 'one record per release name, including hardlink aliases' equal "$(wc -l < "$MANIFEST" | tr -d ' ')" 6
check 'versioned and compatible names have equal digests' equal \
    "$(awk '$2=="tool-1.2.3-linux-amd64.tar.gz" {print $1}' "$MANIFEST")" \
    "$(awk '$2=="tool-linux-amd64.tar.gz" {print $1}' "$MANIFEST")"
check 'manifest is accepted by the real GNU verifier' bash -c 'cd "$1" && sha256sum --check "$2" >/dev/null' _ "$ASSETS" "$MANIFEST"
run checksum_verify "$MANIFEST" "$ASSETS" --strict
check 'strict verification confirms the complete alias set' equal "$status" 0
check 'verification keeps stdout empty' equal "$result" ''
run checksum_generate "$ASSETS"
check 'stdout generation matches exact saved manifest' equal "$result" "$(cat "$MANIFEST")"
check 'output sorting uses the complete filename, not digest' bash -c 'cut -c67- "$1" | LC_ALL=C sort -c' _ "$MANIFEST"
# Locale cannot alter release manifest ordering; same bytes are retained on retry.
touch -t 200101010000 "$MANIFEST"
mtime=$(stat -c %Y "$MANIFEST" 2>/dev/null || stat -f %m "$MANIFEST")
LC_ALL=C run checksum_generate "$ASSETS" -o "$MANIFEST"
check 'identical retry succeeds' equal "$status" 0
check 'identical retry does not rewrite publication mtime' equal "$mtime" "$(stat -c %Y "$MANIFEST" 2>/dev/null || stat -f %m "$MANIFEST")"
run checksum_generate "$ASSETS" -i '*linux*'
check 'include glob selects both Linux alias names' equal "$(printf '%s\n' "$result" | wc -l | tr -d ' ')" 2
run checksum_generate "$ASSETS" -e 'linux|darwin'
check 'exclude regex keeps remaining exact names' equal "$(printf '%s\n' "$result" | wc -l | tr -d ' ')" 3
run checksum_generate "$ASSETS" -e '['
check 'invalid exclusion regex fails before output' rejected
run checksum_generate "$ASSETS" -i 'no-match-*'
check 'empty matched release cannot claim successful checksums' equal "$status:$result" '7:'
run checksum_generate "$TEMP/empty"
check 'empty directory is an explicit missing-artifact error' equal "$status:$result" '7:'
# Default historical selection remains payload-only; metadata coverage is explicit.
printf 'readme' > "$ASSETS/README.txt"
printf '{}' > "$ASSETS/tool.sbom.json"
printf '{}' > "$ASSETS/tool.intoto.jsonl"
printf 'signature' > "$ASSETS/tool-linux-amd64.tar.gz.minisig"
printf 'prior checksum' > "$ASSETS/SHA256SUMS.txt"
run checksum_generate "$ASSETS"
check 'default metadata exclusions preserve the payload contract' equal "$result" "$(cat "$MANIFEST")"
run checksum_generate "$ASSETS" --include-metadata -o "$TEMP/full.sha256"
check 'optional complete release evidence manifest succeeds' equal "$status" 0
check 'metadata option covers text, SBOM and provenance' equal "$(wc -l < "$TEMP/full.sha256" | tr -d ' ')" 9
check 'integrity manifests and detached signatures never include themselves' bash -c '! grep -E "  (SHA256SUMS.txt|.*minisig)$" "$1"' _ "$TEMP/full.sha256"
run checksum_verify "$TEMP/full.sha256" "$ASSETS" --strict --include-metadata
check 'complete evidence manifest satisfies exact coverage' equal "$status" 0
# Custom output names must be excluded, rather than hashed into themselves.
run checksum_generate "$ASSETS" --output "$ASSETS/release-index"
check 'custom output filename inside artifact directory works' equal "$status" 0
saved=$(cat "$ASSETS/release-index")
run checksum_generate "$ASSETS" --output "$ASSETS/release-index"
check 'custom output retry does not acquire a self record' equal "$(cat "$ASSETS/release-index")" "$saved"
run checksum_verify "$ASSETS/release-index" "$ASSETS" --strict
check 'strict verification excludes its custom manifest path' equal "$status" 0
# Dedicated tiny trees keep coverage failures distinct from parsing failures.
printf 'nested payload\n' > "$TEMP/nested/bin/tool"
hash=$(_cs_sha256 "$TEMP/nested/bin/tool")
printf '# comment\r\n%s *./bin/tool\r\n' "${hash^^}" > "$TEMP/portable"
run checksum_verify "$TEMP/portable" "$TEMP/nested"
check 'binary mode uppercase CRLF and conventional ./ prefix work' equal "$status" 0
printf '%s  bin/tool' "$hash" > "$TEMP/unterminated"
run checksum_verify "$TEMP/unterminated" "$TEMP/nested"
check 'last checksum record without newline is verified' equal "$status" 0
run checksum_manifest_normalize "$TEMP/portable"
check 'normalization emits canonical lowercase text-mode record' equal "$result" "$hash  bin/tool"
printf 'root payload' > "$TEMP/nested/other"
run checksum_verify "$TEMP/unterminated" "$TEMP/nested" --strict
check 'strict coverage rejects omitted release files' rejected
printf 'tampered' > "$TEMP/nested/bin/tool"
run checksum_verify "$TEMP/unterminated" "$TEMP/nested"
check 'unterminated record cannot bypass changed payload detection' rejected
# Parse every row before opening payloads or emitting a normalized manifest.
for kind in empty comments html short-hash bad-hash missing-separator one-space duplicate alias-duplicate absolute traversal double-slash dot-component drive backslash option control extra-row; do
    file="$TEMP/invalid-$kind"
    case "$kind" in
        empty) : > "$file" ;;
        comments) printf '# only a comment\n \n' > "$file" ;;
        html) printf '<html>404 Not Found</html>\n' > "$file" ;;
        short-hash) printf 'abc123  bin/tool\n' > "$file" ;;
        bad-hash) printf '%064d  bin/tool\n' 0 | sed 's/0/z/' > "$file" ;;
        missing-separator) printf '%sbin/tool\n' "$hash" > "$file" ;;
        one-space) printf '%s bin/tool\n' "$hash" > "$file" ;;
        duplicate) printf '%s  bin/tool\n%s  bin/tool\n' "$hash" "$hash" > "$file" ;;
        alias-duplicate) printf '%s  bin/tool\n%s  ./bin/tool\n' "$hash" "$hash" > "$file" ;;
        absolute) printf '%s  /etc/passwd\n' "$hash" > "$file" ;;
        traversal) printf '%s  bin/../../outside\n' "$hash" > "$file" ;;
        double-slash) printf '%s  bin//tool\n' "$hash" > "$file" ;;
        dot-component) printf '%s  bin/./tool\n' "$hash" > "$file" ;;
        drive) printf '%s  C:payload\n' "$hash" > "$file" ;;
        backslash) printf '%s  bin\\tool\n' "$hash" > "$file" ;;
        option) printf '%s  --status\n' "$hash" > "$file" ;;
        control) printf '%s  bin\ttool\n' "$hash" > "$file" ;;
        extra-row) printf '%s  bin/tool\nnot a checksum\n' "$hash" > "$file" ;;
    esac
    run checksum_manifest_normalize "$file"
    check "invalid manifest has no partial normalized stdout: $kind" equal "$status:$result" '4:'
done
printf '%s  bin/too\000l\n' "$hash" > "$TEMP/nul"
run checksum_manifest_normalize "$TEMP/nul"
check 'NUL bytes are rejected rather than silently removed by Bash' equal "$status:$result" '4:'
mkdir "$TEMP/linked-tree"
ln -s "$TEMP/nested/bin" "$TEMP/linked-tree/bin"
run checksum_verify "$TEMP/unterminated" "$TEMP/linked-tree"
check 'intermediate directory symlink cannot redirect verification' rejected
ln -s "$TEMP/nested/bin/tool" "$TEMP/linked-tree/tool"
printf '%s  tool\n' "$(_cs_sha256 "$TEMP/nested/bin/tool")" > "$TEMP/linked-manifest"
run checksum_verify "$TEMP/linked-manifest" "$TEMP/linked-tree"
check 'final artifact symlink cannot satisfy a checksum entry' rejected
ln -s "$MANIFEST" "$TEMP/manifest-link"
run checksum_verify "$TEMP/manifest-link" "$ASSETS"
check 'linked manifest rejected' equal "$status:$result" '4:'
mkdir "$TEMP/unsafe"
for kind in symlink fifo newline backslash; do
    dir="$TEMP/unsafe/$kind"; mkdir "$dir"; printf first > "$dir/a"
    case "$kind" in
        symlink) ln -s "$ASSETS/empty" "$dir/z" ;;
        fifo) mkfifo "$dir/z" ;;
        newline) printf bad > "$dir/"$'z\nname' ;;
        backslash) printf bad > "$dir/z\\name" ;;
    esac
    run checksum_generate "$dir"
    check "unsafe directory candidate does not disappear from release set: $kind" equal "$status:$result" '4:'
done
mkdir "$TEMP/atomic"
printf first > "$TEMP/atomic/a"; printf second > "$TEMP/atomic/z"
run checksum_generate "$TEMP/atomic" -o "$TEMP/original.sha256"
ORIGINAL=$(cat "$TEMP/original.sha256")
# Fault injection affects only hashing chosen paths; all other hashes are real.
_cs_sha256() {
    [[ "$1" != "$TEMP/atomic/z" ]] || return 1
    local digest
    digest=$(sha256sum < "$1") || return 1
    printf '%s\n' "${digest%% *}"
}
run checksum_generate "$TEMP/atomic"
check 'late hash failure returns failure instead of incomplete release manifest' rejected
run checksum_generate "$TEMP/atomic" -o "$TEMP/original.sha256"
check 'late hash failure preserves old published manifest' equal "$ORIGINAL" "$(cat "$TEMP/original.sha256")"
# Restore production function by sourcing the real module, not a copied body.
source "${DSR_CHECKSUM_MODULE:-$ROOT/src/checksum_sync.sh}"
find() { command find "$@"; return 1; }
run checksum_generate "$TEMP/atomic"
check 'directory enumeration failure cannot silently omit all files' rejected
unset -f find
sha256sum() { printf '%064d  -\n' 0; return 9; }
run checksum_generate "$TEMP/atomic"
check 'hash tool output does not override a failed exit status' rejected
unset -f sha256sum
sha256sum() { printf 'not-a-hash  -\n'; }
run checksum_generate "$TEMP/atomic"
check 'malformed successful hash-tool output is rejected' rejected
unset -f sha256sum
_cs_sha256() {
    local digest
    digest=$(sha256sum < "$1") || return 1
    if [[ "$1" == "$TEMP/atomic/z" ]]; then printf drift > "$TEMP/atomic/a"; fi
    printf '%s\n' "${digest%% *}"
}
run checksum_generate "$TEMP/atomic"
check 'earlier artifact changed by later producer fails full-set recheck' rejected
source "${DSR_CHECKSUM_MODULE:-$ROOT/src/checksum_sync.sh}"
_cs_sha256() {
    local digest
    digest=$(sha256sum < "$1") || return 1
    if [[ "$1" == "$TEMP/atomic/z" ]]; then printf added > "$TEMP/atomic/new"; fi
    printf '%s\n' "${digest%% *}"
}
run checksum_generate "$TEMP/atomic"
check 'new release filename appearing during generation is detected' rejected
source "${DSR_CHECKSUM_MODULE:-$ROOT/src/checksum_sync.sh}"
mv() { return 1; }
run checksum_generate "$TEMP/atomic" -o "$TEMP/original.sha256"
check 'failed final publication is reported' rejected
check 'failed final publication does not truncate old manifest' equal "$ORIGINAL" "$(cat "$TEMP/original.sha256")"
unset -f mv
ln -s "$TEMP/original.sha256" "$TEMP/output-link"
run checksum_generate "$TEMP/atomic" -o "$TEMP/output-link"
check 'linked output is refused before write' equal "$status:$result" '4:'
check 'linked output target is unchanged' equal "$ORIGINAL" "$(cat "$TEMP/original.sha256")"
ln "$TEMP/atomic/a" "$TEMP/hardlink-output"
run checksum_generate "$TEMP/atomic" -o "$TEMP/hardlink-output"
check 'output alias of a release payload is refused' equal "$status:$result" '4:'
for flag in --output --include --exclude; do
    run checksum_generate "$TEMP/atomic" "$flag"
    check "missing option value fails cleanly: $flag" equal "$status:$result" '4:'
done
run checksum_generate "$TEMP/atomic" --bogus
check 'unknown option is not treated as a directory' equal "$status:$result" '4:'
run checksum_verify "$MANIFEST"
check 'missing verification argument does not abort via nounset' equal "$status:$result" '4:'
check 'all manifest staging directories cleaned' test -z "$(find "$TEMP" -name '.dsr-checksums.*' -print)"
printf 'Release checksum contract: %s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" == 0 ]]
