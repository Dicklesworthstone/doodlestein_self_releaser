#!/usr/bin/env bash
# Test the production signing entry points with real files, hashes and hardlinks.
# Only the Minisign process boundary is a fixture; this is not a crypto test.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for tool in jq sha256sum; do command -v "$tool" >/dev/null || { echo "SKIP: $tool required"; exit 0; }; done
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/dsr-signing-test.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEMP"' EXIT
export DSR_CONFIG_DIR="$TEMP/config" NO_COLOR=1
mkdir -p "$DSR_CONFIG_DIR/secrets" "$TEMP/artifacts"
source "${DSR_SIGNING_MODULE:-$ROOT/src/signing.sh}"
TOKEN=$(printf 'A%.0s' {1..56})
OTHER=$(printf 'B%.0s' {1..56})
printf 'untrusted comment: fixture public key\n%s\n' "$TOKEN" > "$SIGNING_PUBLIC_KEY"
printf '%s\n' "$TOKEN" > "$SIGNING_PRIVATE_KEY"
chmod 600 "$SIGNING_PRIVATE_KEY"
CALLS="$TEMP/calls" MODE=normal TARGET='' PUBFILE="$SIGNING_PUBLIC_KEY"
: > "$CALLS"
# These records are deliberately NOT Minisign wire-format signatures. They
# model successful verification against the actual input hash and pinned key,
# and fault modes simulate failures/dishonest exit codes at the tool boundary.
minisign() {
    local operation='' message='' signature='' key='' trusted='' untrusted=fixture prehash=false
    while (($#)); do
        case "$1" in
            -S|-V) operation="$1"; shift ;;
            -s|-p|-P) key="$2"; [[ "$1" != -p ]] || key=$(sed -n '2p' "$2"); shift 2 ;;
            -m) message="$2"; shift 2 ;;
            -x) signature="$2"; shift 2 ;;
            -t) trusted="$2"; shift 2 ;;
            -c) untrusted="$2"; shift 2 ;;
            -H) prehash=true; shift ;;
            -q) shift ;;
            *) return 91 ;;
        esac
    done
    [[ -n "$signature" ]] || signature="$message.minisig"
    printf '%s %s\n' "$operation" "$message" >> "$CALLS"
    local hash record token
    hash=$(sha256sum < "$message") || return 1
    hash="${hash%% *}"
    if [[ "$operation" == -S ]]; then
        token=$(cat "$key") || return 1
        case "$MODE" in
            fail) printf partial > "$signature"; return 1 ;;
            no-output) return 0 ;;
            empty) : > "$signature"; return 0 ;;
            invalid) printf invalid > "$signature"; return 0 ;;
            sig-link) ln -s "$TARGET" "$signature"; return 0 ;;
            input-change) printf 'drifted artifact\n' >> "$TARGET" ;;
            public-change) printf 'untrusted comment: changed\n%s\n' "$OTHER" > "$PUBFILE" ;;
        esac
        # An incrementing untrusted field makes accidental re-signing visible.
        [[ "$untrusted" != fixture ]] || untrusted="fixture-$(wc -l < "$CALLS")"
        record=$(printf '%s\n' "$token:$hash:$trusted" | sha256sum)
        printf 'untrusted comment: %s\n%s:%s\ntrusted comment: %s\n%s\n' \
            "$untrusted" "$token" "$hash" "$trusted" "${record%% *}" > "$signature"
        printf 'signer stdout must not escape\n'
        return 0
    fi
    [[ "$operation" == -V && -f "$signature" ]] || return 1
    $prehash || return 1
    [[ "$(sed -n '2p' "$signature")" == "$key:$hash" ]] || return 1
    trusted=$(sed -n '3s/^trusted comment: //p' "$signature")
    record=$(printf '%s\n' "$key:$hash:$trusted" | sha256sum)
    [[ "$(sed -n '4p' "$signature")" == "${record%% *}" ]] || return 1
    case "$MODE" in
        verify-input-change) printf 'mutation after verifier read\n' >> "$message" ;;
        verify-signature-change) printf 'mutation after verifier read\n' >> "$signature" ;;
    esac
    printf 'verifier stdout must not escape\n'
}
passed=0 failed=0 status=0 output='' artifact=''
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); printf 'PASS: %s\n' "$label"
    else failed=$((failed + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
equal() { [[ "$1" == "$2" ]]; }
run() {
    status=0
    output=$("$@" 2> "$TEMP/last.err") || status=$?
}
new_file() {
    artifact="$TEMP/artifacts/$1"
    printf 'release artifact %s\n' "$1" > "$artifact"
    MODE=normal TARGET="$artifact"
    printf 'untrusted comment: fixture public key\n%s\n' "$TOKEN" > "$SIGNING_PUBLIC_KEY"
}
no_staging() { [[ -z "$(find "$TEMP/artifacts" -name '*.dsr-signing.*' -print)" ]]; }
new_file release.tar.gz
run signing_sign "$artifact"
check 'ordinary signing publishes a sidecar only after verification' equal "$status" 0
check 'signer output stays off stdout' equal "$output" ''
check 'sidecar verifies against the configured key' signing_verify "$artifact"
check 'staging files are removed on success' no_staging
saved=$(_signing_sha256 "$artifact.minisig")
before=$(grep -c '^-S ' "$CALLS")
run signing_sign "$artifact"
check 'retry of already signed artifact succeeds' equal "$status" 0
check 'retry preserves exact signature bytes' equal "$saved" "$(_signing_sha256 "$artifact.minisig")"
check 'retry does not call signer or ask for a password' equal "$before" "$(grep -c '^-S ' "$CALLS")"
# Verification-only retry works with the private key offline.
private="$SIGNING_PRIVATE_KEY"; SIGNING_PRIVATE_KEY="$TEMP/not-present"
run signing_sign "$artifact"
check 'verified resume does not require private key access' equal "$status" 0
SIGNING_PRIVATE_KEY="$private"
run signing_sign "$artifact" --trusted-comment different
check 'explicit conflicting trusted comment does not overwrite signature' equal "$status" 4
check 'comment conflict preserves exact sidecar bytes' equal "$saved" "$(_signing_sha256 "$artifact.minisig")"
new_file 'comments & spaces.tar.gz'
run signing_sign "$artifact" -t 'release v1.0.0 linux/amd64' -c 'reviewed artifact'
check 'trusted and untrusted comments reach staged signer' equal "$status" 0
check 'trusted comment is preserved' equal "$(sed -n '3p' "$artifact.minisig")" 'trusted comment: release v1.0.0 linux/amd64'
check 'untrusted comment is preserved' equal "$(sed -n '1p' "$artifact.minisig")" 'untrusted comment: reviewed artifact'
run signing_sign "$artifact" -t 'release v1.0.0 linux/amd64' -c 'reviewed artifact'
check 'same explicit comments allow byte-stable retry' equal "$status" 0
run signing_sign "$artifact" -c 'changed comment'
check 'conflicting explicit untrusted comment is reported' equal "$status" 4
new_file 'back\slash.tar.xz'
run signing_sign "$artifact"
check 'backslash in filename cannot corrupt hash-tool output' equal "$status" 0
run signing_verify "$artifact"
check 'verification uses content hash independent of filename escaping' equal "$status" 0
for mode in fail no-output empty invalid sig-link input-change; do
    new_file "$mode.tar.gz"
    MODE="$mode"
    run signing_sign "$artifact"
    check "$mode cannot report successful signing" test "$status" -ne 0
    check "$mode does not publish partial or unusable signature" test ! -e "$artifact.minisig"
    check "$mode leaves stdout empty" equal "$output" ''
    check "$mode cleans private staging" no_staging
done
new_file wrong-key
printf '%s\n' "$OTHER" > "$SIGNING_PRIVATE_KEY"
run signing_sign "$artifact"
check 'private/public mismatch blocks publication' test "$status" -ne 0
check 'wrong-key result is not published' test ! -e "$artifact.minisig"
printf '%s\n' "$TOKEN" > "$SIGNING_PRIVATE_KEY"
new_file public-key-race
MODE=public-change
run signing_sign "$artifact"
check 'in-flight public key change does not change pinned trust identity' equal "$status" 0
MODE=normal
check 'signature verifies with the original pinned token' signing_verify_exact "$artifact" "$artifact.minisig" "$TOKEN"
check 'signature does not verify with substituted public token' bash -c 'test "$1" != "$2"' _ "$TOKEN" "$(sed -n '2p' "$SIGNING_PUBLIC_KEY")"
for mode in verify-input-change verify-signature-change; do
    new_file "$mode"
    signing_sign "$artifact" >/dev/null 2>&1 || exit 1
    MODE="$mode"
    run signing_verify "$artifact"
    check "$mode detected after successful verifier exit" test "$status" -ne 0
    check "$mode verification emits no successful stdout" equal "$output" ''
done
new_file existing-bad
printf 'existing bad signature\n' > "$artifact.minisig"
saved=$(cat "$artifact.minisig")
run signing_sign "$artifact"
check 'invalid existing sidecar is not silently replaced' test "$status" -ne 0
check 'invalid existing bytes are retained for inspection' equal "$saved" "$(cat "$artifact.minisig")"
new_file symlink-input
ln -s "$artifact" "$TEMP/artifacts/linked"
run signing_sign "$TEMP/artifacts/linked"
check 'linked artifact refused before signing' equal "$status" 4
check 'linked artifact receives no sidecar' test ! -e "$TEMP/artifacts/linked.minisig"
ln -s "$artifact" "$artifact.minisig"
run signing_sign "$artifact"
check 'linked signature destination is refused' equal "$status" 4
check 'linked signature target is not modified' grep -q 'release artifact symlink-input' "$artifact"
new_file strict
sha=$(_signing_sha256 "$artifact")
run signing_sign_exact "$artifact" "$artifact.proof" "$SIGNING_PRIVATE_KEY" "$TOKEN" 'strict contract' "$sha"
check 'existing strict six-argument API still works' equal "$status" 0
run signing_sign_exact "$artifact" "$artifact.proof" "$SIGNING_PRIVATE_KEY" "$TOKEN" 'strict contract' "$sha"
check 'strict publication never overwrites an existing proof' equal "$status" 4
run signing_sign_exact "$artifact" "$artifact.wrong" "$SIGNING_PRIVATE_KEY" "$TOKEN" 'strict contract' "$(printf '%064d' 0)"
check 'frozen strict artifact mismatch rejected before sign' equal "$status" 4
check 'strict mismatch leaves no output' test ! -e "$artifact.wrong"
for flag in --trusted-comment --untrusted-comment; do
    run signing_sign "$artifact" "$flag"
    check "missing $flag argument rejected" equal "$status" 4
done
run signing_verify "$artifact" --public-key
check 'missing public key argument rejected' equal "$status" 4
run signing_sign "$artifact" -t $'two\nlines'
check 'multiline comment rejected before publication' equal "$status" 4
run signing_sign_exact "$artifact"
check 'missing exact-signing arguments rejected without nounset termination' equal "$status" 4
run signing_verify_exact "$artifact"
check 'missing exact-verification arguments rejected without nounset termination' equal "$status" 4
# A function-scoped signing failure must not overwrite its caller's traps/options.
new_file trap-scope
trap_before=$(trap -p EXIT)
umask_before=$(umask)
MODE=fail
run signing_sign "$artifact"
check 'staging cleanup leaves caller EXIT trap unchanged' equal "$(trap -p EXIT)" "$trap_before"
check 'staging umask does not leak to caller' equal "$(umask)" "$umask_before"
check 'all failure stages are cleaned' no_staging
printf 'Signing publication: %s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" == 0 ]]
