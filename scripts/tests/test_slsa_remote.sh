#!/usr/bin/env bash
# Real statement generation, payload hashing and file mutation. GitHub transport
# and Minisign are explicit process/function fixtures, not network/crypto tests.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in jq sha256sum; do command -v "$tool" >/dev/null || { echo "SKIP: $tool required"; exit 0; }; done
source "$ROOT/src/slsa.sh" || exit 1
source "$ROOT/src/slsa_remote.sh" || exit 1
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/assets" "$WORK/remote" "$WORK/bin" "$WORK/proofs"
mkdir "$WORK/tmp"
export TMPDIR="$WORK/tmp"
PASS=0 FAIL=0
check() { local label=$1; shift; if "$@" > "$WORK/assert.out" 2> "$WORK/assert.err"; then PASS=$((PASS+1)); printf 'PASS %s\n' "$label"; else FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$label" >&2; cat "$WORK/assert.err" >&2; fi; }
run() { CODE=0; "$@" > "$WORK/result" 2> "$WORK/error" || CODE=$?; }
expect() { local label=$1 code=$2; shift 2; run "$@"; check "$label" test "$CODE" = "$code"; if ((code != 0)); then check "$label emits no success" test ! -s "$WORK/result"; fi; }
PIN=$(printf 'a%.0s' {1..40})
TOKEN=$(printf 'A%.0s' {1..56})
printf 'untrusted comment: fixture key\n%s\n' "$TOKEN" > "$WORK/trusted.pub"
printf 'linux release payload\n' > "$WORK/assets/demo-linux"
printf 'windows release payload\n' > "$WORK/assets/demo-windows.exe"
# A distinct installer alias remains a separate signed subject.
cp "$WORK/assets/demo-linux" "$WORK/assets/demo-v1-linux"
jq -cn --arg pin "$PIN" --arg linux "$(_slsa_sha256 "$WORK/assets/demo-linux")" \
    --arg windows "$(_slsa_sha256 "$WORK/assets/demo-windows.exe")" \
    --argjson linuxsize "$(wc -c < "$WORK/assets/demo-linux")" --argjson winsize "$(wc -c < "$WORK/assets/demo-windows.exe")" '
    {schema_version:"1.0.0",tool:"demo",version:"v1.2.3",run_id:"550e8400-e29b-41d4-a716-446655440000",
     source:{git_sha:$pin,git_ref:"refs/tags/v1.2.3",dependencies:[]},built_at:"2026-09-22T00:00:00Z",
     status:"success",summary:{total:2,success:2,failed:0},artifacts:[
       {name:"demo-linux",target:"linux/amd64",sha256:$linux,size_bytes:$linuxsize,archive_format:"binary"},
       {name:"demo-v1-linux",target:"linux/amd64",sha256:$linux,size_bytes:$linuxsize,archive_format:"binary"},
       {name:"demo-windows.exe",target:"windows/arm64",sha256:$windows,size_bytes:$winsize,archive_format:"binary"}]}' > "$WORK/manifest.json"
slsa_generate_manifest "$WORK/manifest.json" "$WORK/assets" --repository owner/demo --builder dsr:test \
    --output "$WORK/proofs/release.intoto.jsonl" > /dev/null || exit 1
# Fixture signature binds exact token and bytes; it is not an Ed25519 signature.
sign_fixture() { printf '%s:%s\n' "$TOKEN" "$(_slsa_sha256 "$1")" > "$2"; }
sign_fixture "$WORK/proofs/release.intoto.jsonl" "$WORK/proofs/release.intoto.jsonl.minisig"
cat > "$WORK/bin/minisign" <<'SIGNER'
#!/usr/bin/env bash
file='' signature='' token='' prehash=false
while (($#)); do
    case "$1" in
        -V|-q) shift ;; -H) prehash=true; shift ;;
        -m) file=$2; shift 2 ;; -x) signature=$2; shift 2 ;; -P) token=$2; shift 2 ;; *) exit 99 ;;
    esac
done
$prehash || exit 98
printf 'verify\n' >> "$SLSA_TEST_CRYPTO_CALLS"
hash=$(sha256sum < "$file"); hash=${hash%% *}
[[ $(cat "$signature") == "$token:$hash" ]] || exit 1
printf 'fixture verifier stdout must be suppressed\n'
SIGNER
chmod 755 "$WORK/bin/minisign"
export PATH="$WORK/bin:$PATH" SLSA_TEST_CRYPTO_CALLS="$WORK/crypto.calls"
# Transport contracts are tested here with local immutable-ID files. Actual
# pagination/auth/HTTP deadlines are owned and tested by sbom_release.sh.
_sbr_require() { printf 'require\n' >> "$WORK/network.calls"; }
_sbr_run() { "$@"; }
_sbr_context() {
    printf 'context\n' >> "$WORK/network.calls"
    if [[ "$MODE" == readback-swap && -s "$WORK/swap-ready" ]]; then
        local count
        count=$(cat "$WORK/swap-count"); count=$((count+1)); printf '%s\n' "$count" > "$WORK/swap-count"
        if ((count <= 2)); then
            jq -c '.release.id=999|.release.node_id="other-release"|
                .release.upload_url="https://uploads.github.com/repos/owner/demo/releases/999/assets{?name,label}"' "$WORK/context.json"
            return
        fi
    fi
    cat "$WORK/context.json"
}
_sbr_inventory() { jq -cS 'sort_by(.name)' "$WORK/inventory.json"; }
_sbr_named_asset() { jq -ce --arg name "$2" '[.[]|select(.name==$name)]|if length==1 then .[0] else error("missing/ambiguous") end' <<< "$1" || return 7; }
_sbr_payload_names() { jq -c '[.[]|select(.name|endswith(".jsonl") or endswith(".minisig") or endswith(".json") or endswith(".txt")|not)|.name]|sort' <<< "$1"; }
_sbr_asset_digest() {
    local hash
    hash=$(jq -r '.digest // ""' <<< "$1") || return 7
    [[ $(jq -r .state <<< "$1") == uploaded && ( -z "$hash" || "$hash" == "sha256:$2" ) ]] || return 7
}
_sbr_inventory_sha256() { jq -cS 'sort_by(.name)' <<< "$1" > "$2/inventory-hash.json"; _slsa_sha256 "$2/inventory-hash.json"; }
# Download/hash contract matches the real adapter, while the data transport is
# deliberately local and instrumentable. No URLs from statements are followed.
_sbr_download() {
    local dir hash size
    _sbr_asset_digest "$2" "$3" || return 7
    dir=$(mktemp -d "$4/payload.XXXXXXXX") || return 1
    _sbr_run gh_download_release_asset "$1" "$(jq -r .id <<< "$2")" "$dir/body" > /dev/null || return $?
    hash=$(_slsa_sha256 "$dir/body") || return 7
    size=$(wc -c < "$dir/body")
    [[ "$hash" == "$3" && "${size//[[:space:]]/}" == "$(jq -r .size <<< "$2")" ]] || return 7
    printf '%s\n' "$dir/body"
}
MODE=normal
# Mutable observations support concurrent-writer probes after exact ID reads.
gh_download_release_asset() {
    local id=$2 dest=$3
    printf '%s\n' "$id" >> "$WORK/download.calls"
    [[ "$MODE" != download-error ]] || return 8
    [[ "$MODE" != download-timeout ]] || return 5
    cp "$WORK/remote/$id" "$dest" || return 8
    if [[ "$MODE" == readback-swap && "$id" == 5 && ! -s "$WORK/swap-ready" ]]; then
        printf ready > "$WORK/swap-ready"; printf '0\n' > "$WORK/swap-count"
    fi
    if [[ "$MODE" == lying-api && "$id" == 3 ]]; then printf corrupt >> "$dest"; fi
    if [[ "$id" == 3 ]]; then
        case "$MODE" in
            moved-tag) jq '.tag_commit=("b"*40)' "$WORK/context.json" > "$WORK/changed"; cp "$WORK/changed" "$WORK/context.json" ;;
            recreated-release) jq '.release.id=999' "$WORK/context.json" > "$WORK/changed"; cp "$WORK/changed" "$WORK/context.json" ;;
            mode-change) jq '.release.draft=false' "$WORK/context.json" > "$WORK/changed"; cp "$WORK/changed" "$WORK/context.json" ;;
            replaced-asset) jq 'map(if .id==1 then .id=900 else . end)' "$WORK/inventory.json" > "$WORK/changed"; cp "$WORK/changed" "$WORK/inventory.json" ;;
            key-drift) printf changed >> "$WORK/trusted.pub" ;;
        esac
    fi
    printf 'transport noise must be suppressed\n'
}
reset_remote() {
    MODE=normal
    printf 'untrusted comment: fixture key\n%s\n' "$TOKEN" > "$WORK/trusted.pub"
    jq -cn --arg pin "$PIN" '{repository:{id:1,node_id:"repo-id",full_name:"owner/demo"},
        release:{id:10,node_id:"release-id",tag_name:"v1.2.3",draft:true,prerelease:false,
                 target_commitish:$pin,upload_url:"https://uploads.github.com/repos/owner/demo/releases/10/assets{?name,label}"},
        tag_commit:$pin}' > "$WORK/context.json"
    cp "$WORK/assets/demo-linux" "$WORK/remote/1"
    cp "$WORK/assets/demo-v1-linux" "$WORK/remote/2"
    cp "$WORK/assets/demo-windows.exe" "$WORK/remote/3"
    cp "$WORK/proofs/release.intoto.jsonl" "$WORK/remote/4"
    cp "$WORK/proofs/release.intoto.jsonl.minisig" "$WORK/remote/5"
    : > "$WORK/records"
    local id name
    for id in 1 2 3 4 5; do
        case "$id" in 1) name=demo-linux ;; 2) name=demo-v1-linux ;; 3) name=demo-windows.exe ;; 4) name=release.intoto.jsonl ;; 5) name=release.intoto.jsonl.minisig ;; esac
        jq -cn --argjson id "$id" --arg name "$name" --arg hash "$(_slsa_sha256 "$WORK/remote/$id")" \
            --argjson size "$(wc -c < "$WORK/remote/$id")" \
            '{id:$id,name:$name,state:"uploaded",size:$size,digest:("sha256:"+$hash)}' >> "$WORK/records"
    done
    jq -cs 'sort_by(.name)' "$WORK/records" > "$WORK/inventory.json"
    : > "$WORK/download.calls"
    : > "$WORK/network.calls"
    : > "$WORK/swap-ready"
}
refresh_proof() {
    sign_fixture "$WORK/remote/4" "$WORK/remote/5"
    jq --arg proof "$(_slsa_sha256 "$WORK/remote/4")" --arg signature "$(_slsa_sha256 "$WORK/remote/5")" \
        --argjson size "$(wc -c < "$WORK/remote/4")" --argjson sigsize "$(wc -c < "$WORK/remote/5")" \
        'map(if .id==4 then .digest="sha256:"+$proof|.size=$size elif .id==5 then .digest="sha256:"+$signature|.size=$sigsize else . end)' \
        "$WORK/inventory.json" > "$WORK/changed"
    cp "$WORK/changed" "$WORK/inventory.json"
}
BASE=(--repo owner/demo --tag v1.2.3 --sha "$PIN" --builder dsr:test --public-key "$WORK/trusted.pub" --targets windows/arm64,linux/amd64)
reset_remote
expect 'signed complete remote release verifies' 0 slsa_verify_remote "${BASE[@]}"
check 'single authenticated receipt binds immutable source/asset identities' jq -es --arg pin "$PIN" \
    'length==1 and (.[0]|.authenticated and .status=="verified" and .tag_commit==$pin and
     .artifact_count==3 and .statement.asset_id==4 and .signature.asset_id==5 and
     .targets==["linux/amd64","windows/arm64"] and .verification_policy=="trusted-minisign-slsa-v1-all-payload-bytes")' "$WORK/result"
check 'every payload downloaded despite advertised digests' bash -c '[[ $(sort -nu "$1"|paste -sd, -) == 1,2,3,4,5 ]]' _ "$WORK/download.calls"
check 'receipt omits private local paths and transport/verifier noise' bash -c '! grep -Eq "transport noise|fixture verifier|trusted.pub|/tmp/" "$1"' _ "$WORK/result"
reset_remote
jq 'map(.digest=null)' "$WORK/inventory.json" > "$WORK/changed"; cp "$WORK/changed" "$WORK/inventory.json"
expect 'missing API digests still verify by exact downloaded bytes' 0 slsa_verify_remote "${BASE[@]}"
expect 'independent statement manifest and run pins are supported' 0 slsa_verify_remote "${BASE[@]}" \
    --statement-sha256 "$(_slsa_sha256 "$WORK/proofs/release.intoto.jsonl")" \
    --manifest-sha256 "$(_slsa_sha256 "$WORK/manifest.json")" --invocation-id 550e8400-e29b-41d4-a716-446655440000
for option in --statement-sha256 --manifest-sha256; do
    expect 'incorrect independent hash cannot replay another build' 7 slsa_verify_remote "${BASE[@]}" "$option" "$(printf 'b%.0s' {1..64})"
done
expect 'incorrect invocation ID cannot replay another build' 7 slsa_verify_remote "${BASE[@]}" --invocation-id other-run
# Correctly re-signed invalid statements must fail semantic policy, not crypto.
for filter in '.predicate.runDetails.builder.id="other"' \
    '.predicate.buildDefinition.externalParameters.repository="https://github.com/owner/other"' \
    '.predicate.buildDefinition.externalParameters.version="v9.9.9"' \
    '.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit=("b"*40)' \
    '.dsr_evidence.kind="post-build-observation"' '.dsr_evidence.manifest_sha256=("c"*64)' \
    '.subject|=.[0:2]|.dsr_evidence.artifacts|=.[0:2]|.predicate.buildDefinition.externalParameters.targets=["linux/amd64"]' \
    '.dsr_evidence.artifacts[2].size_bytes+=1' '.dsr_evidence.artifacts[0].target="darwin/arm64"' \
    '.predicate.buildDefinition.externalParameters.targets+=["linux/amd64"]'; do
    reset_remote
    jq "$filter" "$WORK/remote/4" > "$WORK/changed"; cp "$WORK/changed" "$WORK/remote/4"
    refresh_proof
    expect "signed mismatch rejected: $filter" 7 slsa_verify_remote "${BASE[@]}"
done
reset_remote
printf 'invalid signature\n' > "$WORK/remote/5"
jq --arg hash "$(_slsa_sha256 "$WORK/remote/5")" --argjson size "$(wc -c < "$WORK/remote/5")" \
    'map(if .id==5 then .digest="sha256:"+$hash|.size=$size else . end)' "$WORK/inventory.json" > "$WORK/changed"
cp "$WORK/changed" "$WORK/inventory.json"
expect 'correct API digest cannot authenticate an invalid signature' 1 slsa_verify_remote "${BASE[@]}"
check 'unauthenticated subjects never trigger payload downloads' bash -c '! grep -Eq "^[123]$" "$1"' _ "$WORK/download.calls"
for mode in lying-api moved-tag recreated-release mode-change replaced-asset key-drift; do
    reset_remote; MODE=$mode
    expect "$mode invalidates remote success" 7 slsa_verify_remote "${BASE[@]}"
done
reset_remote; MODE=download-error
expect 'network failure retains network status' 8 slsa_verify_remote "${BASE[@]}"
reset_remote; MODE=download-timeout
expect 'transport timeout retains interruption status' 5 slsa_verify_remote "${BASE[@]}"
for filter in 'map(select(.id!=5))' 'map(if .id==4 then .size=999999999 else . end)' \
    'map(if .id==5 then .size=65537 else . end)' 'map(if .id==3 then .state="starter" else . end)' \
    'map(if .id==3 then .digest="sha512:unsupported" else . end)' \
    'map(if .id==3 then .digest="sha256:"+("b"*64) else . end)' \
    '.+[{id:6,name:"unplanned.exe",state:"uploaded",size:1,digest:null}]'; do
    reset_remote
    jq "$filter" "$WORK/inventory.json" > "$WORK/changed"; cp "$WORK/changed" "$WORK/inventory.json"
    expect "invalid inventory rejected: $filter" 7 slsa_verify_remote "${BASE[@]}"
    check 'invalid inventory triggers no payload downloads' bash -c '! grep -Eq "^[123]$" "$1"' _ "$WORK/download.calls"
done
reset_remote
# Function invocation in this shell retains the transport fixtures.
SLSA_REMOTE_MAX_PAYLOAD_BYTES=1 run slsa_verify_remote "${BASE[@]}"
check 'actual payload budget gate rejects the signed set' test "$CODE" = 7
check 'budget rejection starts no payload body read' bash -c '! grep -Eq "^[123]$" "$1"' _ "$WORK/download.calls"
reset_remote
expect 'repeated policy flags rejected' 4 slsa_verify_remote "${BASE[@]}" --repo owner/other
expect 'unsafe statement name rejected' 4 slsa_verify_remote "${BASE[@]}" --statement-name ../release.intoto.jsonl
expect 'expected target matrix is mandatory' 4 slsa_verify_remote --repo owner/demo --tag v1.2.3 --sha "$PIN" --builder dsr:test --public-key "$WORK/trusted.pub"
expect 'duplicate expected platforms rejected' 4 slsa_verify_remote --repo owner/demo --tag v1.2.3 --sha "$PIN" --builder dsr:test --public-key "$WORK/trusted.pub" --targets linux/amd64,linux/amd64
check 'argument rejection performs no downloads' test ! -s "$WORK/download.calls"
check 'argument rejection performs no remote preflight' test ! -s "$WORK/network.calls"

# Publication transport fixture: complete immutable asset records and a guarded
# addition-only inventory. POST responses can be lost after their bytes land.
_sbr_publication_gate() {
    local observed current
    observed=$(_sbr_context "$1" "$2" "$6") || return $?
    current=$(_sbr_inventory "$1" 10 "$6") || return $?
    [[ "$observed" == "$3" ]] || return 7
    jq -en --argjson before "$4" --argjson after "$current" --argjson names "$5" '
        all($before[];. as $a|[$after[]|select(.name==$a.name)]==[$a]) and
        ([$before[]|select(.name as $n|$names|index($n)==null)]==
         [$after[]|select(.name as $n|$names|index($n)==null)])' >/dev/null || return 7
    printf '%s\n' "$current"
}
gh_upload_asset_named() {
    local url=$1 file=$2 name=$3 id record
    [[ "$url" == 'https://uploads.github.com/repos/owner/demo/releases/10/assets{?name,label}' ]] || return 99
    [[ "${GH_MAX_RETRIES:-}" == 1 ]] || return 99
    printf '%s\n' "$name" >> "$WORK/upload.calls"
    jq -e --arg name "$name" 'all(.[];.name!=$name)' "$WORK/inventory.json" >/dev/null || return 8
    id=$(jq '[.[].id]|max+1' "$WORK/inventory.json") || return 8
    cp "$file" "$WORK/remote/$id" || return 8
    record=$(jq -cn --arg name "$name" --argjson id "$id" --arg sha "$(_slsa_sha256 "$file")" \
        --argjson size "$(wc -c < "$file")" '{id:$id,name:$name,size:$size,state:"uploaded",digest:("sha256:"+$sha)}') || return 8
    jq --argjson record "$record" '.+[$record]|sort_by(.name)' "$WORK/inventory.json" > "$WORK/changed" || return 8
    cp "$WORK/changed" "$WORK/inventory.json"
    case "$MODE:$name" in
        lost-statement:release.intoto.jsonl|lost-signature:release.intoto.jsonl.minisig) return 8 ;;
        corrupt-upload:*) printf corrupt >> "$WORK/remote/$id" ;;
        mutate-local:*) printf changed >> "$WORK/proofs/release.intoto.jsonl" ;;
        wrong-receipt:*) record=$(jq -c '.id+=100' <<< "$record") ;;
        tag-on-upload:*) jq '.tag_commit=("b"*40)' "$WORK/context.json" > "$WORK/changed"; cp "$WORK/changed" "$WORK/context.json" ;;
    esac
    printf '%s\n' "$record"
}
reset_publication() {
    reset_remote
    jq 'map(select(.id<4))' "$WORK/inventory.json" > "$WORK/changed"; cp "$WORK/changed" "$WORK/inventory.json"
    : > "$WORK/upload.calls"
}
publish() { slsa_publish_release "$WORK/proofs/release.intoto.jsonl" "$WORK/assets" "${BASE[@]}" "$@"; }
reset_publication
expect 'publication dry run authenticates local proof without remote calls' 0 publish --dry-run
check 'dry run is not remote verification' jq -e '.status=="planned" and .dry_run and .local_statement_authenticated and (.remote_verified|not)' "$WORK/result"
check 'dry run performs no remote preflight or upload' bash -c '[[ ! -s "$1/network.calls" && ! -s "$1/upload.calls" ]]' _ "$WORK"
expect 'signed provenance pair publishes to a matching complete draft' 0 publish
check 'publisher returns independent authenticated verification' jq -e '.status=="verified" and .upload_attempts==2 and .verification.authenticated and .verification.artifact_count==3' "$WORK/result"
check 'only statement then detached signature are uploaded' bash -c '[[ $(paste -sd, "$1") == release.intoto.jsonl,release.intoto.jsonl.minisig ]]' _ "$WORK/upload.calls"
check 'published statement and signature bytes equal selected local inputs' bash -c 'cmp -s "$1/remote/4" "$1/proofs/release.intoto.jsonl" && cmp -s "$1/remote/5" "$1/proofs/release.intoto.jsonl.minisig"' _ "$WORK"
BEFORE=$(wc -l < "$WORK/upload.calls")
expect 'identical publication retry is read-only' 0 publish
check 'retry never uploads the same names again' test "$BEFORE" = "$(wc -l < "$WORK/upload.calls")"
check 'retry reports zero uploads' jq -e '.upload_attempts==0' "$WORK/result"
jq '.release.draft=false' "$WORK/context.json" > "$WORK/changed"; cp "$WORK/changed" "$WORK/context.json"
expect 'already-complete published release may be reverified read-only' 0 publish
check 'published release retry does not mutate assets' test "$BEFORE" = "$(wc -l < "$WORK/upload.calls")"
for phase in statement signature; do
    reset_publication; MODE="lost-$phase"
    expect "lost $phase acknowledgement returns failure" 8 publish
    COUNT=$(wc -l < "$WORK/upload.calls")
    MODE=normal
    expect "retry recovers lost $phase acknowledgement" 0 publish
    check 'recovery never repeats an accepted upload' test "$(wc -l < "$WORK/upload.calls")" = 2
    if [[ "$phase" == signature ]]; then
        check 'completed pair needs no new uploads after lost acknowledgement' test "$COUNT" = "$(wc -l < "$WORK/upload.calls")"
    fi
done
reset_publication
jq '.release.draft=false' "$WORK/context.json" > "$WORK/changed"; cp "$WORK/changed" "$WORK/context.json"
expect 'missing proof cannot be attached to an already-public release' 4 publish
check 'public release refusal makes no POST' test ! -s "$WORK/upload.calls"
reset_remote
jq 'map(select(.id!=4))' "$WORK/inventory.json" > "$WORK/changed"; cp "$WORK/changed" "$WORK/inventory.json"
: > "$WORK/upload.calls"
expect 'orphan signature cannot acquire a new statement' 7 publish
check 'orphan refusal makes no POST' test ! -s "$WORK/upload.calls"
reset_remote
# A different valid signature/proof pair still cannot occupy the selected names.
jq '.predicate.runDetails.metadata.invocationId="other-build"' "$WORK/remote/4" > "$WORK/changed"; cp "$WORK/changed" "$WORK/remote/4"
refresh_proof
: > "$WORK/upload.calls"
expect 'conflicting occupied proof is never replaced' 7 publish
check 'all occupied proof conflicts are found before upload' test ! -s "$WORK/upload.calls"
for mode in wrong-receipt corrupt-upload tag-on-upload readback-swap; do
    reset_publication; MODE=$mode
    expect "$mode prevents publication success" 7 publish
done
reset_publication
cp "$WORK/proofs/release.intoto.jsonl" "$WORK/saved-proof"
MODE=mutate-local
expect 'changing selected local proof during upload is not success' 7 publish
cp "$WORK/saved-proof" "$WORK/proofs/release.intoto.jsonl"
reset_publication
printf corrupt >> "$WORK/assets/demo-windows.exe"
expect 'local payload corruption is rejected before remote preflight' 1 publish
check 'local corruption starts no remote operation' test ! -s "$WORK/network.calls"
printf 'windows release payload\n' > "$WORK/assets/demo-windows.exe"
reset_publication
MODE=lying-api
expect 'remote payload corruption blocks provenance upload' 7 publish
check 'payload preflight happens before any proof upload' test ! -s "$WORK/upload.calls"
reset_publication
expect 'private key option is not accepted by the publisher' 4 publish --secret-key /private/key
expect 'verification cannot be downgraded to a dry run' 4 slsa_verify_remote "${BASE[@]}" --dry-run
check 'private temporary work is cleaned' bash -c '[[ -z $(find "$1" -name "dsr-slsa-remote.*" -print -quit) ]]' _ "$WORK"
printf '\nRemote SLSA verification/publication: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
