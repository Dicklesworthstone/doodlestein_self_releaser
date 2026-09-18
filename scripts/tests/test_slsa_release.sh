#!/usr/bin/env bash
# Real manifest/asset operations; Minisign process fixture is NOT a crypto test.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for tool in jq sha256sum; do command -v "$tool" >/dev/null || { echo "SKIP: $tool required"; exit 0; }; done
source "$ROOT/src/slsa.sh" || exit 1
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/dsr-slsa-release.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEMP"' EXIT
mkdir -p "$TEMP/assets" "$TEMP/proofs" "$TEMP/modified" "$TEMP/bin"
printf 'linux executable\n' > "$TEMP/assets/app-v1-linux"
ln "$TEMP/assets/app-v1-linux" "$TEMP/assets/app-linux"
printf 'windows executable\n' > "$TEMP/assets/app-v1-windows.exe"
manifest="$TEMP/build.json"
linux_sha=$(_slsa_sha256 "$TEMP/assets/app-v1-linux")
windows_sha=$(_slsa_sha256 "$TEMP/assets/app-v1-windows.exe")
linux_size=$(wc -c < "$TEMP/assets/app-v1-linux")
windows_size=$(wc -c < "$TEMP/assets/app-v1-windows.exe")
PIN=$(printf '1%.0s' {1..40})
DEP=$(printf '2%.0s' {1..40})
jq -n --arg sha "$linux_sha" --arg win "$windows_sha" --arg commit "$PIN" --arg dep "$DEP" \
    --argjson size "$linux_size" --argjson winsize "$windows_size" '
    {schema_version:"1.0.0",tool:"app",version:"v1.2.3",run_id:"550e8400-e29b-41d4-a716-446655440000",
     source:{git_sha:$commit,git_ref:"v1.2.3",dependencies:[{relative_path:"shared",git_sha:$dep}]},
     built_at:"2026-09-18T01:02:03Z",status:"success",summary:{total:2,success:2,failed:0},
     builder:{tool:"dsr",version:"0.1.2"},
     artifacts:[{name:"app-v1-linux",target:"linux/amd64",sha256:$sha,size_bytes:$size,archive_format:"binary"},
                {name:"app-linux",target:"linux/amd64",sha256:$sha,size_bytes:$size,archive_format:"binary"},
                {name:"app-v1-windows.exe",target:"windows/amd64",sha256:$win,size_bytes:$winsize,archive_format:"binary"}],
     hosts:[{host:"linux-host",platform:"linux/amd64",status:"success"},
            {host:"windows-host",platform:"windows/amd64",status:"success"}],
     build_environments:[{target:"windows/amd64",host:"windows-host",method:"native",
         build_influence_env:{PRIVATE_BUILD_SETTING:"do-not-publish-this-value"},cargo_isolation:null}]}
' > "$manifest"
passed=0 failed=0 status=0 output=''
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); printf 'PASS: %s\n' "$label"
    else failed=$((failed + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
equal() { [[ "$1" == "$2" ]]; }
run() { status=0; output=$("$@" 2> "$TEMP/last.err") || status=$?; }
proof="$TEMP/proofs/release.intoto.jsonl"
run slsa_generate_manifest "$manifest" "$TEMP/assets" --repository example/app --builder dsr/test --output "$proof"
check 'complete successful build produces release-set provenance' equal "$status" 0
[[ "$status" == 0 ]] || { cat "$TEMP/last.err"; exit 1; }
check 'manifest generation emits exactly its path' equal "$output" "$proof"
check 'subjects sorted deterministically with every alias' jq -e '.subject | map(.name) == ["app-linux","app-v1-linux","app-v1-windows.exe"]' "$proof"
check 'recorded source pin is used without a checkout' jq -e --arg sha "$PIN" '.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit == $sha' "$proof"
check 'source sibling revision survives into provenance' jq -e --arg dep "$DEP" '.predicate.buildDefinition.resolvedDependencies[1] == {name:"sibling/shared",digest:{gitCommit:$dep}}' "$proof"
check 'recorded completion and invocation retained, not invented' jq -e '.predicate.runDetails.metadata == {invocationId:"550e8400-e29b-41d4-a716-446655440000",finishedOn:"2026-09-18T01:02:03Z"}' "$proof"
check 'recorded DSR builder version retained' jq -e '.predicate.runDetails.builder.version.dsr == "0.1.2"' "$proof"
check 'manifest content digest binds omitted private evidence' jq -e --arg hash "$(_slsa_sha256 "$manifest")" '.dsr_evidence.manifest_sha256 == $hash and .predicate.runDetails.byproducts[0].digest.sha256 == $hash' "$proof"
check 'raw environment values are not copied into public statements' bash -c '! grep -q do-not-publish-this-value "$1"' _ "$proof"
check 'repository binding is explicitly caller supplied' jq -e '.dsr_evidence.repository_binding == "caller-supplied"' "$proof"
run slsa_verify_release "$proof" "$TEMP/assets" --manifest "$manifest" --repository example/app --builder dsr/test
check 'complete release matches exact expected manifest' equal "$status" 0
check 'verification keeps stdout empty' equal "$output" ''
check 'unsigned release verification reports unauthenticated producer' grep -q 'not authenticated' "$TEMP/last.err"
prior=$(_slsa_sha256 "$proof")
run slsa_generate_manifest "$manifest" "$TEMP/assets" --repository example/app --builder dsr/test --output "$proof"
check 'retry reuses existing proof successfully' equal "$status" 0
check 'retry preserves byte-identical statement' equal "$prior" "$(_slsa_sha256 "$proof")"
run slsa_generate_manifest "$manifest" "$TEMP/assets" --repository example/other --builder dsr/test --output "$proof"
check 'changed repository claim cannot replace existing proof' equal "$status" 2
check 'conflicting proof is left untouched' equal "$prior" "$(_slsa_sha256 "$proof")"
run slsa_generate_manifest "$manifest" "$TEMP/assets" --builder dsr/test --output "$TEMP/proofs/no-repo"
check 'manifest lacking repository ownership cannot infer it' equal "$status" 4
run slsa_verify_release "$proof" "$TEMP/assets" --source-repository https://github.com/example/app --source-commit "$PIN" --builder dsr/test
check 'release verifier applies expected source policy' equal "$status" 0
run slsa_verify_release "$proof" "$TEMP/assets" --source-repository https://github.com/example/app --source-commit "$DEP" --builder dsr/test
check 'wrong source commit is rejected for whole release' test "$status" -ne 0
# Re-signed/stale proofs still must satisfy the caller supplied expected manifest.
jq '.subject |= .[0:1] | .dsr_evidence.artifacts |= .[0:1]' "$proof" > "$TEMP/proofs/subset"
run slsa_verify_release "$TEMP/proofs/subset" "$TEMP/assets" --manifest "$manifest" --repository example/app --builder dsr/test
check 'exact manifest policy rejects subject omission' equal "$status" 1
jq '.run_id="a-different-run"' "$manifest" > "$TEMP/modified/run.json"
run slsa_verify_release "$proof" "$TEMP/assets" --manifest "$TEMP/modified/run.json" --repository example/app --builder dsr/test
check 'matching artifact bytes cannot replay a different build run' equal "$status" 1
# Corrupt only the last listed target; checking subject[0] would miss this.
printf corrupt > "$TEMP/assets/app-v1-windows.exe"
run slsa_verify_release "$proof" "$TEMP/assets"
check 'tampered last target fails full release verification' test "$status" -ne 0
run slsa_generate_manifest "$manifest" "$TEMP/assets" --repository example/app --output "$TEMP/proofs/corrupt"
check 'manifest with a tampered target cannot be attested' test "$status" -ne 0
check 'tampered target produces no final proof' test ! -e "$TEMP/proofs/corrupt"
printf 'windows executable\n' > "$TEMP/assets/app-v1-windows.exe"
# Validation errors use the actual manifest parser, not a parallel test parser.
for mutation in partial failed empty duplicate escape null-sha control-sha wrong-size zero-size fractional-size \
    unknown-format missing-target bad-target source-zero source-short source-control duplicate-dependency \
    bad-dependency wrong-summary failed-summary failed-host duplicate-host extra-host bad-date missing-date \
    wrong-builder missing-source bad-environment duplicate-environment; do
    case "$mutation" in
        partial) filter='.status="partial"' ;;
        failed) filter='.status="failed"' ;;
        empty) filter='.artifacts=[]' ;;
        duplicate) filter='.artifacts += [.artifacts[0]]' ;;
        escape) filter='.artifacts[0].name="../escape"' ;;
        null-sha) filter='.artifacts[0].sha256=null' ;;
        control-sha) filter='.artifacts[0].sha256 += "\n"' ;;
        wrong-size) filter='.artifacts[0].size_bytes += 1' ;;
        zero-size) filter='.artifacts[0].size_bytes=0' ;;
        fractional-size) filter='.artifacts[0].size_bytes=2.5' ;;
        unknown-format) filter='.artifacts[0].archive_format="rar"' ;;
        missing-target) filter='del(.artifacts[2])' ;;
        bad-target) filter='.artifacts[0].target="wrong/target"' ;;
        source-zero) filter='.source.git_sha="0" * 40' ;;
        source-short) filter='.source.git_sha="123"' ;;
        source-control) filter='.source.git_sha += "\n"' ;;
        duplicate-dependency) filter='.source.dependencies += [.source.dependencies[0]]' ;;
        bad-dependency) filter='.source.dependencies[0].relative_path="../escape"' ;;
        wrong-summary) filter='.summary.total=3' ;;
        failed-summary) filter='.summary.failed=1' ;;
        failed-host) filter='.hosts[1].status="failed"' ;;
        duplicate-host) filter='.hosts += [.hosts[0]]' ;;
        extra-host) filter='.hosts += [{host:"other",platform:"darwin/arm64",status:"success"}]' ;;
        bad-date) filter='.built_at="2026-02-31T00:00:00Z"' ;;
        missing-date) filter='del(.built_at)' ;;
        wrong-builder) filter='.builder.tool="different"' ;;
        missing-source) filter='del(.source)' ;;
        bad-environment) filter='.build_environments[0].target="darwin/arm64"' ;;
        duplicate-environment) filter='.build_environments += [.build_environments[0]]' ;;
    esac
    jq "$filter" "$manifest" > "$TEMP/modified/$mutation.json"
    run slsa_generate_manifest "$TEMP/modified/$mutation.json" "$TEMP/assets" --repository example/app --output "$TEMP/proofs/reject-$mutation"
    check "invalid or incomplete manifest fails: $mutation" test "$status" -ne 0
    check "failed $mutation manifest publishes nothing" test ! -e "$TEMP/proofs/reject-$mutation"
done
cat "$manifest" "$manifest" > "$TEMP/modified/multiple.json"
run slsa_generate_manifest "$TEMP/modified/multiple.json" "$TEMP/assets" --repository example/app --output "$TEMP/proofs/multiple"
check 'multiple manifest documents rejected' equal "$status" 4
ln -s "$manifest" "$TEMP/modified/link.json"
run slsa_generate_manifest "$TEMP/modified/link.json" "$TEMP/assets" --repository example/app --output "$TEMP/proofs/linked-manifest"
check 'linked manifest rejected' equal "$status" 4
run slsa_generate_manifest "$manifest" "$TEMP/assets" --repository example/app --output "$TEMP/assets/app-linux"
check 'output cannot replace a listed alias' equal "$status" 4
run slsa_generate_manifest "$manifest" "$TEMP/assets" --repository example/app --output "$manifest"
check 'output cannot replace source manifest' equal "$status" 4
printf 'existing detached signature\n' > "$TEMP/proofs/orphan.minisig"
run slsa_generate_manifest "$manifest" "$TEMP/assets" --repository example/app --output "$TEMP/proofs/orphan"
check 'orphan signature is a publication conflict' equal "$status" 2
check 'orphan signature cannot acquire unrelated proof' test ! -e "$TEMP/proofs/orphan"
# Manifest fields may contain builder-local paths. Neither generation nor
# verification follows them or treats artifact.signed as proof of authentication.
jq '.artifacts[0].path="/outside/should-not-be-read" | .artifacts[0].signed=true | del(.hosts,.builder,.build_environments)' "$manifest" > "$TEMP/minimal.json"
run slsa_generate_manifest "$TEMP/minimal.json" "$TEMP/assets" --repository example/app --output "$TEMP/proofs/minimal"
check 'optional receipts absent and untrusted paths ignored' equal "$status" 0
run slsa_verify_release "$TEMP/proofs/minimal" "$TEMP/assets"
check 'optional-fields manifest still verifies actual bytes' equal "$status" 0
# Distinct names pointing to the same inode still require distinct subjects.
cp "$TEMP/assets/app-linux" "$TEMP/retained-linux"
mv "$TEMP/assets/app-linux" "$TEMP/alias-before-link"
ln -s "$TEMP/retained-linux" "$TEMP/assets/app-linux"
run slsa_generate_manifest "$manifest" "$TEMP/assets" --repository example/app --output "$TEMP/proofs/linked-asset"
check 'linked artifact cannot satisfy a manifest subject' test "$status" -ne 0
mv -f "$TEMP/alias-before-link" "$TEMP/assets/app-linux"
# Local error injection only at a publication primitive, after real hashing.
ln() { return 23; }
run slsa_generate_manifest "$manifest" "$TEMP/assets" --repository example/app --output "$TEMP/proofs/no-publish"
unset -f ln
check 'release statement publication failure is not success' equal "$status" 2
check 'publication failure leaves no partial final statement' test ! -e "$TEMP/proofs/no-publish"
# A changed input after the first pass must not become release proof.
wc() { command wc "$@"; printf changed >> "$TEMP/assets/app-v1-windows.exe"; }
run slsa_generate_manifest "$manifest" "$TEMP/assets" --repository example/app --output "$TEMP/proofs/drift"
unset -f wc
check 'artifact-set drift during preflight is detected' test "$status" -ne 0
check 'preflight drift publishes no proof' test ! -e "$TEMP/proofs/drift"
printf 'windows executable\n' > "$TEMP/assets/app-v1-windows.exe"
# Real competing writers publish the same deterministic proof without clobber.
pids=()
for n in 1 2 3 4 5 6; do
    (rc=0; slsa_generate_manifest "$manifest" "$TEMP/assets" --repository example/app --builder dsr/test \
        --output "$TEMP/proofs/concurrent" > "$TEMP/race-$n.out" 2> "$TEMP/race-$n.err" || rc=$?;
        printf '%s\n' "$rc" > "$TEMP/race-$n.status") &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || exit 1; done
check 'at least one concurrent generator succeeds' grep -q '^0$' "$TEMP"/race-*.status
check 'concurrent generators only succeed or report publication conflict' bash -c '! grep -hEv "^(0|2)$" "$@"' _ "$TEMP"/race-*.status
check 'concurrent publication preserves deterministic statement bytes' cmp -s "$proof" "$TEMP/proofs/concurrent"
# Native Minisign integration can run where installed, without production keys.
if command -v minisign >/dev/null; then
    minisign -G -W -p "$TEMP/native.pub" -s "$TEMP/native.key" >/dev/null 2>&1 || exit 1
    minisign -S -s "$TEMP/native.key" -m "$proof" -x "$TEMP/native.minisig" >/dev/null 2>&1 || exit 1
    run slsa_verify_release "$proof" "$TEMP/assets" --builder dsr/test --public-key "$TEMP/native.pub" --signature "$TEMP/native.minisig"
    check 'native Minisign authenticates a generated release proof' equal "$status" 0
else
    printf 'SKIP: native Minisign integration unavailable\n'
fi
# Process-boundary fixture tests authentication routing and mutation handling.
# This fixture never claims to produce or validate an Ed25519 signature.
TOKEN=$(printf 'A%.0s' {1..56})
WRONG=$(printf 'B%.0s' {1..56})
export TOKEN MODE=normal CALLS="$TEMP/minisign.calls" PROOF_TARGET="$proof" KEY_TARGET="$TEMP/test.pub"
printf 'untrusted comment: test only\n%s\n' "$TOKEN" > "$KEY_TARGET"
printf '%s:%s\n' "$TOKEN" "$(_slsa_sha256 "$proof")" > "$proof.minisig"
: > "$CALLS"
cat > "$TEMP/bin/minisign" <<'SIGNER'
#!/usr/bin/env bash
set -uo pipefail
file='' signature='' token='' prehash=false
while (($#)); do
    case "$1" in
        -m) file="$2"; shift 2 ;;
        -x) signature="$2"; shift 2 ;;
        -P) token="$2"; shift 2 ;;
        -H) prehash=true; shift ;;
        -V|-q) shift ;;
        *) exit 99 ;;
    esac
done
printf '%s\n' "$token" >> "$CALLS"
$prehash || exit 1
[[ "$MODE" != failure ]] || exit 1
hash=$(sha256sum < "$file"); hash="${hash%% *}"
[[ "$(cat "$signature")" == "$token:$hash" ]] || exit 1
case "$MODE" in
    proof-change) printf ' ' >> "$file" ;;
    signature-change) printf 'changed\n' >> "$signature" ;;
    key-change) printf 'changed\n' >> "$KEY_TARGET" ;;
esac
printf 'verifier noise stays off stdout\n'
SIGNER
chmod +x "$TEMP/bin/minisign"
export PATH="$TEMP/bin:$PATH"
run slsa_verify_release "$proof" "$TEMP/assets" --builder dsr/test --public-key "$KEY_TARGET"
check 'authenticated full-set path invokes verifier with pinned external key' equal "$status" 0
check 'verifier receives the externally chosen key token' equal "$(tail -1 "$CALLS")" "$TOKEN"
check 'authenticated full-set path emits no verifier noise' equal "$output" ''
check 'authenticated log distinguishes signer/builder check' grep -q 'trusted signer/builder' "$TEMP/last.err"
run slsa_verify "$TEMP/assets/app-linux" "$proof" --builder dsr/test --public-key "$KEY_TARGET"
check 'single-artifact verifier also supports authenticated statement' equal "$status" 0
printf changed > "$TEMP/assets/app-v1-windows.exe"
run slsa_verify_release "$proof" "$TEMP/assets" --builder dsr/test --public-key "$KEY_TARGET"
check 'valid proof signature cannot hide a corrupted last target' test "$status" -ne 0
printf 'windows executable\n' > "$TEMP/assets/app-v1-windows.exe"
run slsa_verify_release "$proof" "$TEMP/assets" --public-key "$KEY_TARGET"
check 'key alone cannot choose a self-declared builder policy' equal "$status" 4
run slsa_verify_release "$proof" "$TEMP/assets" --signature "$proof.minisig"
check 'signature alone cannot supply its own trust root' equal "$status" 4
run slsa_verify_release "$proof" "$TEMP/assets" --builder wrong --public-key "$KEY_TARGET"
check 'valid signature does not bypass expected builder' test "$status" -ne 0
printf 'untrusted comment: wrong test key\n%s\n' "$WRONG" > "$TEMP/wrong.pub"
run slsa_verify_release "$proof" "$TEMP/assets" --builder dsr/test --public-key "$TEMP/wrong.pub"
check 'wrong trusted key fails rather than downgrading to unsigned checks' equal "$status" 1
run slsa_verify_release "$proof" "$TEMP/assets" --builder dsr/test --public-key "$KEY_TARGET" --signature "$TEMP/absent"
check 'missing detached signature fails closed' test "$status" -ne 0
MODE=failure
run slsa_verify_release "$proof" "$TEMP/assets" --builder dsr/test --public-key "$KEY_TARGET"
check 'verifier rejection propagates' equal "$status" 1
MODE=normal
ln -s "$proof.minisig" "$TEMP/linked.minisig"
run slsa_verify_release "$proof" "$TEMP/assets" --builder dsr/test --public-key "$KEY_TARGET" --signature "$TEMP/linked.minisig"
check 'linked detached signature rejected' test "$status" -ne 0
for mutation in proof-change signature-change key-change; do
    cp "$proof" "$TEMP/$mutation.proof"
    printf '%s:%s\n' "$TOKEN" "$(_slsa_sha256 "$TEMP/$mutation.proof")" > "$TEMP/$mutation.minisig"
    printf 'untrusted comment: test only\n%s\n' "$TOKEN" > "$KEY_TARGET"
    MODE="$mutation"
    run slsa_verify_release "$TEMP/$mutation.proof" "$TEMP/assets" --builder dsr/test \
        --public-key "$KEY_TARGET" --signature "$TEMP/$mutation.minisig"
    check "changed authentication input detected: $mutation" equal "$status" 1
done
MODE=normal
# Standalone entry points expose the actual production functions.
run bash "$ROOT/src/slsa.sh" generate-manifest "$manifest" "$TEMP/assets" --repository example/app --builder dsr/test --output "$TEMP/proofs/cli"
check 'standalone manifest generation succeeds' equal "$status" 0
run bash "$ROOT/src/slsa.sh" verify-release "$TEMP/proofs/cli" "$TEMP/assets" --manifest "$manifest" --repository example/app --builder dsr/test
check 'standalone full release verification succeeds' equal "$status" 0
run bash "$ROOT/src/slsa.sh" verify-release "$TEMP/proofs/subset" "$TEMP/assets" --manifest "$manifest" --repository example/app --builder dsr/test
check 'standalone verification preserves mismatch status' equal "$status" 1
run slsa_verify_release "$proof" "$TEMP/assets" --manifest "$manifest" --builder dsr/test
check 'expected manifest needs explicit repository binding' equal "$status" 4
check 'final provenance staging is cleaned' test -z "$(find "$TEMP" -name '.dsr-manifest-proof.*' -print)"
printf 'SLSA release provenance: %s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" == 0 ]]
