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
source "${DSR_SIGNING_MODULE:-$ROOT/src/signing.sh}" || exit 1
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
            batch-second-fail)
                [[ "$trusted" != *' batch-b '* ]] || { printf partial > "$signature"; return 23; } ;;
            batch-late-change)
                [[ "$trusted" != *' late-b '* ]] || printf 'late drift\n' >> "$TARGET" ;;
            private-change) printf '%s\n' "$OTHER" > "$key" ;;
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
no_staging() { [[ -z "$(find "$TEMP/artifacts" \( -name '*.dsr-signing.*' -o -name '*.dsr-batch.*' \) -print)" ]]; }
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
run signing_verify_exact "$artifact" "$artifact.minisig" "$OTHER"
check 'signature does not verify with substituted public token' test "$status" -ne 0
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

# A release signing batch is complete or failed, never a best-effort success.
new_file batch-a; a="$artifact"
before=$(grep -c '^-S ' "$CALLS")
run signing_sign_batch "$a" "$TEMP/absent"
check 'missing later input fails whole-batch preflight' equal "$status" 4
check 'preflight failure invokes no signer' equal "$before" "$(grep -c '^-S ' "$CALLS")"
check 'preflight failure publishes no early signature' test ! -e "$a.minisig"
new_file batch-b; b="$artifact"
MODE=batch-second-fail
run signing_sign_batch "$a" "$b"
check 'later signing failure fails the batch' test "$status" -ne 0
check 'later signing failure does not publish the first staged signature' test ! -e "$a.minisig"
check 'later signing failure publishes no partial final signature' test ! -e "$b.minisig"
check 'failed whole-batch staging is removed' no_staging
MODE=normal
run signing_sign_batch "$a" "$b"
check 'complete staged batch succeeds' equal "$status" 0
check 'batch has no blank lines or signer noise on stdout' equal "$output" ''
check 'first batch artifact verifies' signing_verify "$a"
check 'second batch artifact verifies' signing_verify "$b"
asig=$(_signing_sha256 "$a.minisig"); bsig=$(_signing_sha256 "$b.minisig")
before=$(grep -c '^-S ' "$CALLS")
run signing_sign_batch "$a" "$b" "$TEMP/artifacts/./batch-a"
check 'duplicate path spellings are deduplicated and resume succeeds' equal "$status" 0
check 'batch retry does not sign completed assets again' equal "$before" "$(grep -c '^-S ' "$CALLS")"
check 'batch retry preserves first signature bytes' equal "$asig" "$(_signing_sha256 "$a.minisig")"
check 'batch retry preserves second signature bytes' equal "$bsig" "$(_signing_sha256 "$b.minisig")"
SIGNING_PRIVATE_KEY="$TEMP/private-key-offline"
run signing_sign_batch "$a" "$b"
check 'fully signed batch can resume without private key' equal "$status" 0
SIGNING_PRIVATE_KEY="$private"
new_file new-duplicate; a="$artifact"
before=$(grep -c '^-S ' "$CALLS")
run signing_sign_batch "$a" "$a" "$TEMP/artifacts/./new-duplicate"
check 'duplicate new path has one signing operation' equal "$(grep -c '^-S ' "$CALLS")" "$((before + 1))"
check 'duplicate new path does not cause publication conflict' equal "$status" 0
new_file tool-1.2.3-linux-amd64.tar.gz; a="$artifact"
b="$TEMP/artifacts/tool-linux-amd64.tar.gz"
ln "$a" "$b"
before=$(grep -c '^-S ' "$CALLS")
run signing_sign_batch "$a" "$b"
check 'versioned and compat hardlink aliases both sign' equal "$status" 0
check 'distinct asset names are not deduplicated by inode' equal "$(grep -c '^-S ' "$CALLS")" "$((before + 2))"
check 'versioned artifact signature binds its release name' grep -q 'tool-1.2.3-linux-amd64.tar.gz sha256:' "$a.minisig"
check 'compat artifact signature binds its release name' grep -q 'tool-linux-amd64.tar.gz sha256:' "$b.minisig"
check 'compat artifact sidecar verifies' signing_verify "$b"
new_file overlap; a="$artifact"
printf 'existing sidecar\n' > "$a.minisig"
before=$(grep -c '^-S ' "$CALLS")
run signing_sign_batch "$a" "$a.minisig"
check 'batch input/output overlap rejected before signing' equal "$status" 4
check 'overlap rejection has no signer calls' equal "$before" "$(grep -c '^-S ' "$CALLS")"
new_file preflight-first; a="$artifact"
new_file preflight-corrupt; b="$artifact"
printf invalid > "$b.minisig"
before=$(grep -c '^-S ' "$CALLS")
run signing_sign_batch "$a" "$b"
check 'bad retained signature blocks the whole batch' test "$status" -ne 0
check 'bad retained signature checked before signing earlier unsigned file' equal "$before" "$(grep -c '^-S ' "$CALLS")"
check 'retained conflict does not publish unrelated signature' test ! -e "$a.minisig"
check 'corrupt existing signature is not overwritten' equal "$(cat "$b.minisig")" invalid
new_file planned-a; a="$artifact"
new_file planned-b; b="$artifact"
MODE=input-change TARGET="$b"
run signing_sign_batch "$a" "$b"
check 'later artifact mutation fails its frozen digest check' test "$status" -ne 0
check 'changed later input does not publish earlier staged sidecar' test ! -e "$a.minisig"
check 'changed later input does not publish a signature for new bytes' test ! -e "$b.minisig"
new_file late-a; a="$artifact"
new_file late-b; b="$artifact"
MODE=batch-late-change TARGET="$a"
run signing_sign_batch "$a" "$b"
check 'earlier input mutation during last signer is caught by set validation' test "$status" -ne 0
check 'set validation failure publishes no early sidecar' test ! -e "$a.minisig"
check 'set validation failure publishes no later sidecar' test ! -e "$b.minisig"
new_file retained; a="$artifact"
signing_sign "$a" >/dev/null 2>&1 || exit 1
new_file unsigned; b="$artifact"
MODE=input-change TARGET="$a.minisig"
run signing_sign_batch "$a" "$b"
check 'retained signature drift during new signing is detected' test "$status" -ne 0
check 'retained signature drift prevents new public sidecar' test ! -e "$b.minisig"
new_file key-a; a="$artifact"
new_file key-b; b="$artifact"
MODE=private-change
run signing_sign_batch "$a" "$b"
check 'changing private key cannot produce a mixed-key release set' test "$status" -ne 0
check 'mixed-key attempt leaves first final sidecar absent' test ! -e "$a.minisig"
check 'mixed-key attempt leaves second final sidecar absent' test ! -e "$b.minisig"
printf '%s\n' "$TOKEN" > "$SIGNING_PRIVATE_KEY"
new_file public-a; a="$artifact"
new_file public-b; b="$artifact"
MODE=public-change
run signing_sign_batch "$a" "$b"
check 'batch pins one public key for the entire operation' equal "$status" 0
MODE=normal
check 'first member verifies against pinned batch key' signing_verify_exact "$a" "$a.minisig" "$TOKEN"
check 'second member verifies against pinned batch key' signing_verify_exact "$b" "$b.minisig" "$TOKEN"

# Real hardlink publication, with a fault only at a selected FINAL sidecar.
# Earlier successful publications must remain valid and reusable after failure.
new_file publish-a; a="$artifact"
new_file publish-b; b="$artifact"
FAIL_LINK="$b.minisig"
ln() {
    [[ "${!#}" != "$FAIL_LINK" ]] || return 1
    command ln "$@"
}
run signing_sign_batch "$a" "$b"
check 'late publication failure fails the whole batch' equal "$status" 4
check 'completed early sidecar survives late failure' signing_verify "$a"
check 'failed late publication leaves destination absent' test ! -e "$b.minisig"
asig=$(_signing_sha256 "$a.minisig")
unset -f ln
run signing_sign_batch "$a" "$b"
check 'partial publication can be safely resumed' equal "$status" 0
check 'resume never rewrites the completed early signature' equal "$asig" "$(_signing_sha256 "$a.minisig")"
check 'resume completes missing late signature' signing_verify "$b"
check 'all batch failure/success stages cleaned' no_staging

# Competing publishers use real OS processes and the real atomic ln primitive.
new_file concurrent-a; a="$artifact"
new_file concurrent-b; b="$artifact"
pids=()
for n in 1 2 3 4 5 6; do
    (code=0; signing_sign_batch "$a" "$b" > "$TEMP/race-$n.out" 2> "$TEMP/race-$n.err" || code=$?;
     printf '%s\n' "$code" > "$TEMP/race-$n.status") &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || exit 1; done
check 'at least one competing batch completes' grep -q '^0$' "$TEMP"/race-*.status
check 'competing publishers fail only on publication conflict or succeed' bash -c '! grep -Ev "^(0|4)$" "$@"' _ "$TEMP"/race-*.status
check 'concurrent first artifact signature verifies' signing_verify "$a"
check 'concurrent second artifact signature verifies' signing_verify "$b"
check 'competing signing invocations leave no staging directories' no_staging

# Directory selection signs release evidence as well as binaries; filenames
# containing 'sha256' must not be silently filtered out of the release set.
MODE=normal
dir="$TEMP/directory with spaces"
mkdir "$dir"
for name in tool-v1.tar.gz tool.tar.gz checksums.sha256 tool.sbom.json tool.intoto.jsonl sha256-tool.zip; do
    printf 'payload %s\n' "$name" > "$dir/$name"
done
run signing_sign_files "$dir" '*'
check 'directory signing produces full release-evidence coverage' equal "$status" 0
check 'directory signing keeps stdout empty' equal "$output" ''
for name in tool-v1.tar.gz tool.tar.gz checksums.sha256 tool.sbom.json tool.intoto.jsonl sha256-tool.zip; do
    check "directory signature verifies: $name" signing_verify "$dir/$name"
done
before=$(grep -c '^-S ' "$CALLS")
run signing_sign_files "$dir" '*'
check 'directory retry retains verified signatures and skips detached sidecars' equal "$status" 0
check 'directory retry does not create signatures of signatures' test ! -e "$dir/tool.tar.gz.minisig.minisig"
check 'directory retry has no new signer calls' equal "$before" "$(grep -c '^-S ' "$CALLS")"
option_result=$(
    shopt -s nullglob failglob; set -f; GLOBIGNORE='*'; IFS=:
    old=$(shopt -p nullglob failglob); flags="$-"
    signing_sign_files "$dir" '*.tar.gz' >/dev/null 2>&1 || exit 1
    [[ "$(shopt -p nullglob failglob)" == "$old" && "$-" == "$flags" && "$GLOBIGNORE" == '*' && "$IFS" == : ]]
    printf '%s' "$?"
)
check 'directory selection does not inherit or leak caller glob/IFS policy' equal "$option_result" 0
run signing_sign_files "$dir" '*.does-not-exist'
check 'empty signing selection is a failure instead of false completion' equal "$status" 4
run signing_sign_files "$dir" '../*'
check 'directory glob cannot escape requested directory' equal "$status" 4
unsafe="$TEMP/unsafe-selection"
mkdir "$unsafe"
printf artifact > "$unsafe/a.tar.gz"
ln -s "$dir/tool.tar.gz" "$unsafe/z.tar.gz"
run signing_sign_files "$unsafe" '*.tar.gz'
check 'linked candidate fails directory preflight' equal "$status" 4
check 'invalid directory selection produces no earlier signature' test ! -e "$unsafe/a.tar.gz.minisig"
mkfifo "$unsafe/z.pipe"
run signing_sign_files "$unsafe" '*.pipe'
check 'special file candidate rejected without reading or hanging' equal "$status" 4
check 'final staging tree is empty' no_staging
printf 'Signing publication: %s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" == 0 ]]
