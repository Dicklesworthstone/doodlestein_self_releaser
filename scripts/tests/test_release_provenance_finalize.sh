#!/usr/bin/env bash
# Exercise the actual finalizer and complete SLSA/payload-manifest modules.
# SBOM scanning, integrity transport, remote SLSA and dispatch boundaries are
# file-backed fixtures. Minisign routing is a hash fixture, NOT a crypto test.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT/src/slsa.sh"
source "$ROOT/src/release_payloads.sh"
source "${PROVENANCE_FINALIZE_TEST_MODULE:-$ROOT/src/release_finalize_core.sh}"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir "$WORK/bin"
export PATH="$WORK/bin:$PATH"
cat > "$WORK/bin/minisign" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
file='' sig='' token=''
while (($#)); do
    case "$1" in
        -m) file=$2; shift 2 ;; -x) sig=$2; shift 2 ;; -P) token=$2; shift 2 ;;
        -V|-H|-q) shift ;; *) exit 99 ;;
    esac
done
hash=$(sha256sum < "$file") || exit 1
[[ $(cat "$sig") == "$token:${hash%% *}" ]]
SH
chmod 755 "$WORK/bin/minisign"
TOKEN=$(printf 'A%.0s' {1..56})
SOURCE_SHA=$(printf '1%.0s' {1..40})
BUILDER='dsr:test-production'
PASS=0 FAIL=0 CASE='' BUILD='' MODE='' STATUS=0
trace() { printf '%s\n' "$*" >> "$CASE/calls"; }
assert() { local label=$1; shift; if "$@" > "$WORK/assert.out" 2>&1; then
    PASS=$((PASS+1)); printf 'PASS %s\n' "$label"
    else FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$label"; cat "$WORK/assert.out"; fi; }
run_code() {
    local label=$1 expected=$2; shift 2; STATUS=0
    "$@" > "$CASE/result.json" 2> "$CASE/error.log" || STATUS=$?
    assert "$label" test "$STATUS" = "$expected"
    if [[ "$STATUS" != "$expected" ]]; then cat "$CASE/result.json" "$CASE/error.log"; fi
    assert 'exactly one result preserves process exit' jq -es --argjson rc "$STATUS" \
        'length==1 and .[0].kind=="dsr-release-finalization-result" and .[0].exit_code==$rc' "$CASE/result.json"
}
arg() { local option=$1; shift; while (($#)); do
    if [[ "$1" == "$option" ]]; then printf '%s\n' "$2"; return; fi; shift; done; }
count() { grep -c -x "$1" "$CASE/calls" || true; }
state_file() { find "$CASE/state" -name state.json -print -quit; }
signing_public_key_token() { sed -n '2p' "$1"; }
signing_sign_exact() {
    trace sign-provenance
    [[ "$MODE" != sign-fail ]] || return 42
    [[ -f "$3" && "$(_slsa_sha256 "$1")" == "$6" ]] || return 7
    (set -o noclobber; printf '%s:%s\n' "$4" "$6" > "$2") || return 2
}
_ri_require() { :; }
_ri_file_record() {
    local hash size
    hash=$(_slsa_sha256 "$1") || return $?
    size=$(wc -c < "$1") || return 1
    jq -cn --arg name "$2" --arg hash "$hash" --argjson size "$size" '{name:$name,sha256:$hash,size:$size}'
}
_ri_check_record() {
    [[ "$(_ri_file_record "$1" "$(jq -r .name <<< "$2")" | jq -cS .)" == \
       "$(jq -cS '{name,sha256,size}' <<< "$2")" ]] || return 7
}
_sbom_select_artifacts() { find "$1" -maxdepth 1 -type f \( -name 'tool-linux*' -o -name 'tool-windows.exe' \) -printf '%f\n' | sort; }
_rup_require() { :; }
fixture_payloads() {
    local root=$1 selection=$2 row
    while IFS= read -r row; do _ri_check_record "$root/$(jq -r .name <<< "$row")" "$row" || return $?
    done < <(jq -c '.artifacts[]' <<< "$selection")
}
release_prepare_integrity() {
    local root=$1; shift
    local file output token selection
    file=$(arg --build-manifest "$@"); output=$(arg --output-dir "$@"); token=$(signing_public_key_token "$(arg --public-key "$@")")
    selection=$(_rup_manifest "$file" owner/tool v1.0.0 "$SOURCE_SHA") || return $?
    fixture_payloads "$root" "$selection" || return $?
    if [[ " $* " == *' --dry-run '* ]]; then
        jq -cn --arg token "$token" --argjson selection "$selection" \
            '{kind:"dsr-release-integrity-plan",status:"planned",dry_run:true,public_key:$token,selection:$selection}'
    else
        trace integrity-prepare
        mkdir -p "$output"
        if [[ ! -e "$output/release-integrity.json" ]]; then
            jq -cS '.+{build_manifest_sha256:.manifest_sha256}' <<< "$selection" > "$output/release-integrity.json"
        fi
    fi
}
_ri_documents() { _ri_file_record "$1/release-integrity.json" release-integrity.json | jq -cs .; }
_ri_verify_set() { fixture_payloads "$1" "$(cat "$2/release-integrity.json")"; }
_ri_matches_selection() { [[ $(jq -cS 'del(.build_manifest_sha256)' "$1") == "$(jq -cS . <<< "$2")" ]]; }
_ri_local_unchanged() {
    local row
    fixture_payloads "$1" "$3" || return $?
    while IFS= read -r row; do _ri_check_record "$2/$(jq -r .name <<< "$row")" "$row" || return $?
    done < <(jq -c '.[]' <<< "$4")
}
_sbr_require() { trace auth; }
_sbr_context() { trace context; cat "$CASE/context.json"; }
_sbr_inventory() { cat "$CASE/inventory.json"; }
_sbr_inventory_sha256() { jq -cS 'sort_by(.name)' <<< "$1" | _rf_digest; }
_sbr_run() { "$@"; }
add_asset() {
    local name=$1 file=$2 record id
    record=$(_ri_file_record "$file" "$name") || return $?
    if jq -e --arg n "$name" 'any(.[];.name==$n)' "$CASE/inventory.json" >/dev/null; then
        _ri_check_record "$CASE/remote/$name" "$record" || return 7
    else
        id=$(jq '([.[].id]|max//0)+1' "$CASE/inventory.json")
        cp "$file" "$CASE/remote/$name" || return 1
        jq -cS --argjson r "$record" --argjson id "$id" \
            '.+[{id:$id,name:$r.name,size:$r.size,digest:("sha256:"+$r.sha256),state:"uploaded"}]|sort_by(.name)' \
            "$CASE/inventory.json" > "$CASE/next.json"
        mv "$CASE/next.json" "$CASE/inventory.json"
        trace "upload $name"
    fi
}
fixture_integrity_receipt() {
    local selected inventory hash
    selected=$(jq -c '{artifacts}' "$CASE/remote/release-integrity.json") || return 1
    fixture_payloads "$CASE/remote" "$selected" || return $?
    inventory=$(jq -c '[.[]|select(.name=="release-integrity.json" or (.name|startswith("tool-")))]' "$CASE/inventory.json")
    hash=$(_rf_hash "$CASE/remote/release-integrity.json")
    jq -cn --argjson ctx "$(cat "$CASE/context.json")" --argjson assets "$inventory" --arg token "$TOKEN" --arg hash "$hash" \
        '$ctx+{schema_version:1,kind:"dsr-release-integrity-verification",status:"verified",authenticated:true,
          public_key:$token,verification_policy:"minisign-all-payloads-and-checksums",assets:$assets,
          manifest:{name:"release-integrity.json",sha256:$hash,asset_id:($assets[]|select(.name=="release-integrity.json")|.id)}}'
}
release_publish_integrity() {
    trace integrity-publish
    add_asset release-integrity.json "$(arg --output-dir "$@")/release-integrity.json" || return $?
    fixture_integrity_receipt
}
release_verify_remote_integrity() { trace integrity-verify; fixture_integrity_receipt; }
_ri_remote_publish() { add_asset release-integrity.json "$2/release-integrity.json" && fixture_integrity_receipt; }
release_upload_payloads() {
    local root=$1; shift
    local selection row
    selection=$(_rup_manifest "$(arg --build-manifest "$@")" owner/tool v1.0.0 "$SOURCE_SHA") || return $?
    fixture_payloads "$root" "$selection" || return $?
    if [[ " $* " != *' --dry-run '* ]]; then
        trace payload-publish
        while IFS= read -r row; do add_asset "$row" "$root/$row" || return $?
        done < <(jq -r '.artifacts[].name' <<< "$selection")
        jq -cn --argjson ctx "$(cat "$CASE/context.json")" --argjson s "$selection" \
            --argjson a "$(jq -c '[.[]|select(.name|startswith("tool-"))]' "$CASE/inventory.json")" \
            '$ctx+{kind:"dsr-release-payload-publication",status:"verified",dry_run:false,manifest_sha256:$s.manifest_sha256,tool:$s.tool,assets:$a}'
    else
        jq -cn --argjson p "$selection" '{kind:"dsr-release-payload-publication",status:"planned",dry_run:true,plan:$p}'
    fi
}
_rup_preflight() { fixture_payloads "$CASE/remote" "$3"; }
sbom_generate_artifacts() {
    trace sbom-generate
    local output; output=$(arg --output-dir "$@")
    if [[ ! -e "$output/sbom-manifest.spdx.json" ]]; then
        jq -cS '{artifacts:[.artifacts[]|{artifact:{name,sha256}}]}' "$BUILD" > "$output/sbom-manifest.spdx.json"
    fi
}
sbom_verify_artifacts() {
    trace local-sbom-verify
    if [[ "$MODE" == local-late-drift && $(count local-sbom-verify) == 1 ]]; then
        printf drift >> "$CASE/proofs/release.intoto.jsonl"
    fi
    local manifest; manifest="$(arg --output-dir "$@")/sbom-manifest.spdx.json"
    [[ -f "$manifest" ]] || return 7
}
sbom_publish_artifacts() {
    trace sbom-publish
    add_asset sbom-manifest.spdx.json "$(arg --output-dir "$@")/sbom-manifest.spdx.json" || return $?
    if [[ "$MODE" == remote-late-drift ]]; then printf drift >> "$CASE/remote/release.intoto.jsonl"; fi
    printf '{"kind":"dsr-sbom-publication","status":"verified","dry_run":false}\n'
}
sbom_verify_release() {
    trace sbom-verify
    local hash asset inventory
    hash=$(arg --manifest-sha256 "$@"); asset=$(jq -c '.[]|select(.name=="sbom-manifest.spdx.json")' "$CASE/inventory.json")
    [[ "$hash" == "$(_rf_hash "$CASE/remote/sbom-manifest.spdx.json")" ]] || return 7
    inventory=$(_sbr_inventory_sha256 "$(cat "$CASE/inventory.json")" "$CASE")
    jq -cn --argjson ctx "$(cat "$CASE/context.json")" --argjson a "$asset" --arg hash "$hash" --arg inv "$inventory" \
        '$ctx+{schema_version:1,kind:"dsr-sbom-remote-verification",status:"verified",format:"spdx",
          manifest:{name:$a.name,asset_id:$a.id,sha256:$hash},artifact_count:3,
          asset_inventory_sha256:$inv,verification_policy:"expected-manifest-sha256"}'
}
fixture_provenance_receipt() {
    local proof="$CASE/remote/release.intoto.jsonl" key builder hash manifest invocation targets inventory stmt sig
    key=$(arg --public-key "$@"); builder=$(arg --builder "$@"); hash=$(arg --statement-sha256 "$@")
    manifest=$(arg --manifest-sha256 "$@"); invocation=$(arg --invocation-id "$@"); targets=$(arg --targets "$@")
    [[ "$hash" == "$(_rf_hash "$proof")" && "$manifest" == "$(_rf_hash "$BUILD")" &&
       "$invocation" == "$(jq -r .run_id "$BUILD")" && "$targets" == 'linux/amd64,windows/arm64' ]] || return 7
    slsa_verify_release "$proof" "$CASE/remote" --manifest "$BUILD" --repository owner/tool \
        --builder "$builder" --public-key "$key" || return $?
    inventory=$(_sbr_inventory_sha256 "$(cat "$CASE/inventory.json")" "$CASE")
    stmt=$(jq -c '.[]|select(.name=="release.intoto.jsonl")' "$CASE/inventory.json")
    sig=$(jq -c '.[]|select(.name=="release.intoto.jsonl.minisig")' "$CASE/inventory.json")
    jq -cn --argjson ctx "$(cat "$CASE/context.json")" --arg builder "$builder" --arg hash "$hash" \
        --arg manifest "$manifest" --arg invocation "$invocation" --arg inventory "$inventory" \
        --argjson a "$stmt" --argjson s "$sig" --arg sig "$(_rf_hash "$proof.minisig")" \
        '$ctx+{schema_version:1,kind:"dsr-slsa-remote-verification",status:"verified",authenticated:true,
          builder:$builder,targets:["linux/amd64","windows/arm64"],build_manifest_sha256:$manifest,invocation_id:$invocation,
          artifact_count:3,asset_inventory_sha256:$inventory,verification_policy:"trusted-minisign-slsa-v1-all-payload-bytes",
          statement:{name:$a.name,asset_id:$a.id,sha256:$hash},signature:{name:$s.name,asset_id:$s.id,sha256:$sig}}'
}
slsa_publish_release() {
    trace provenance-publish
    local proof=$1 root=$2; shift 2
    slsa_verify_release "$proof" "$root" --manifest "$BUILD" --repository owner/tool \
        --builder "$(arg --builder "$@")" --public-key "$(arg --public-key "$@")" || return $?
    [[ "$MODE" != provenance-publish-fail ]] || return 8
    add_asset release.intoto.jsonl "$proof" || return $?
    if [[ "$MODE" == lost-statement && ! -e "$CASE/lost" ]]; then touch "$CASE/lost"; return 8; fi
    add_asset release.intoto.jsonl.minisig "$proof.minisig" || return $?
    if [[ "$MODE" == lost-signature && ! -e "$CASE/lost" ]]; then touch "$CASE/lost"; return 8; fi
    local receipt; receipt=$(fixture_provenance_receipt "$@") || return $?
    [[ "$MODE" != malformed-publication ]] || { echo '{}'; return 0; }
    if [[ -n "${MUTATION:-}" ]]; then receipt=$(jq -c "$MUTATION" <<< "$receipt"); fi
    jq -cn --argjson r "$receipt" '{kind:"dsr-slsa-publication",status:"verified",dry_run:false,verification:$r}'
}
slsa_verify_remote() {
    trace "provenance-verify $(jq -r .release.draft "$CASE/context.json")"
    [[ "$MODE" != pre-verify-fail ]] || return 7
    if [[ "$MODE" == post-verify-fail && $(jq -r .release.draft "$CASE/context.json") == false ]]; then return 7; fi
    local receipt; receipt=$(fixture_provenance_receipt "$@") || return $?
    if [[ "$MODE" == wrong-inventory ]]; then jq '.asset_inventory_sha256=("0"*64)' <<< "$receipt"
    else printf '%s\n' "$receipt"; fi
}
gh() {
    trace promote
    [[ $(jq -cS . "${*: -1}") == '{"draft":false,"make_latest":"false"}' ]] || return 99
    jq '.release.draft=false' "$CASE/context.json" > "$CASE/next.json"
    mv "$CASE/next.json" "$CASE/context.json"
    [[ "$MODE" != lost-promotion ]] || return 8
}
_dp_config() { :; }
_dp_repos() { tr ',' '\n' <<< "$1"; }
dispatch_check_auth() { :; }
_dp_digest_text() { printf '%s' "$1" | _rf_digest; }
_dp_state_hash() { echo absent; }
_dp_release_plan() { jq -cn --arg repo "$1" --argjson p "$3" '{source_repo:$repo,payload:$p}'; }
_dp_release_outbox() {
    local guard=$5
    if [[ "$MODE" == dispatch-key-drift ]]; then printf 'comment\n%s\n' "$(printf 'B%.0s' {1..56})" > "$CASE/key.pub"; fi
    "$guard" || return $?
    trace dispatch
    printf '%s\n' "$1" > "$CASE/dispatch.json"
    printf '{"status":"accepted","exit_code":0,"results":[]}\n'
}
new_case() {
    CASE="$WORK/$1"; mkdir -p "$CASE/artifacts" "$CASE/remote" "$CASE/meta" "$CASE/proofs"
    BUILD="$CASE/build.json"; MODE=''; MUTATION=''
    : > "$CASE/calls"
    printf 'comment\n%s\n' "$TOKEN" > "$CASE/key.pub"
    printf 'not a real private key\n' > "$CASE/key.key"
    printf 'linux payload\n' > "$CASE/artifacts/tool-linux"
    cp "$CASE/artifacts/tool-linux" "$CASE/artifacts/tool-linux-alias"
    printf 'windows payload\n' > "$CASE/artifacts/tool-windows.exe"
    printf '[]\n' > "$CASE/inventory.json"
    local file target records=''
    for file in tool-linux tool-linux-alias tool-windows.exe; do
        target=linux/amd64; [[ "$file" != tool-windows.exe ]] || target=windows/arm64
        records+="$(jq -cn --arg name "$file" --arg target "$target" --arg sha "$(_rf_hash "$CASE/artifacts/$file")" \
            --argjson size "$(wc -c < "$CASE/artifacts/$file")" \
            '{name:$name,target:$target,sha256:$sha,size_bytes:$size,archive_format:"binary"}')"$'\n'
    done
    jq -cs --arg sha "$SOURCE_SHA" '{schema_version:"1.0.0",tool:"tool",version:"v1.0.0",run_id:"test-build-1",
        status:"success",summary:{total:2,success:2,failed:0},built_at:"2026-09-23T00:00:00Z",
        source:{git_sha:$sha,git_ref:"refs/tags/v1.0.0",dependencies:[]},artifacts:.}' <<< "$records" > "$BUILD"
    jq -cn --arg sha "$SOURCE_SHA" '{repository:{id:7,node_id:"repo-7",full_name:"owner/tool"},
        release:{id:42,node_id:"release-42",tag_name:"v1.0.0",draft:true,prerelease:false,target_commitish:"main",
        upload_url:"https://uploads.github.com/repos/owner/tool/releases/42/assets{?name,label}"},tag_commit:$sha}' > "$CASE/context.json"
}
base() { release_finalize "$CASE/artifacts" --repo owner/tool --tag v1.0.0 --sha "$SOURCE_SHA" \
    --build-manifest "$BUILD" --upload-payloads --output-dir "$CASE/meta" --state-dir "$CASE/state" \
    --require-signatures --public-key "$CASE/key.pub" --secret-key "$CASE/key.key" --integrity-dir "$CASE/proofs" "$@"; }
finalize() { base --require-provenance --provenance-builder "$BUILDER" "$@"; }
[[ "${DSR_PROVENANCE_FIXTURES_ONLY:-false}" != true ]] || return 0
new_case plan
run_code 'dry run pins provenance without signing or remote access' 0 finalize --dry-run
assert 'dry policy binds exact build and full target matrix' jq -e --arg hash "$(_rf_hash "$BUILD")" \
    '.provenance_policy.required and .provenance_policy.build_manifest_sha256==$hash and
     .provenance_policy.targets==["linux/amd64","windows/arm64"] and .provenance_policy.artifact_count==3' "$CASE/result.json"
assert 'planning performs no effects' test ! -s "$CASE/calls"
assert 'planning creates no durable state' test ! -e "$CASE/state"
for args in '--require-provenance' '--provenance-builder builder'; do
    # Only these fixed test literals are split; no input is evaluated.
    # shellcheck disable=SC2086
    run_code 'partial provenance policy is rejected' 4 base $args
 done
new_case success
run_code 'signed complete provenance gates an explicit promotion' 0 finalize --promote --tool tool --dispatch-repos owner/checksums
assert 'public result retains post-promotion authenticated provenance' jq -e \
    '.status=="complete" and .provenance.authenticated and .provenance.release.draft==false and
     .provenance.asset_inventory_sha256==.verification.asset_inventory_sha256 and .provenance.artifact_count==3' "$CASE/result.json"
assert 'state retains exact builder and proof identity' jq -e --arg b "$BUILDER" \
    '.plan.provenance.builder==$b and .provenance_verification.statement.sha256==.plan.provenance.statement.sha256 and
     .phase=="published" and .promotion_attempts==1' "$(state_file)"
assert 'dispatch includes selected proof and signing policy' jq -e --arg token "$TOKEN" \
    '.payload.release_evidence.provenance | .public_key==$token and .statement.asset_id>0 and .signature.asset_id>0 and
     .targets==["linux/amd64","windows/arm64"] and .artifact_count==3' "$CASE/dispatch.json"
assert 'verification happens on both sides of promotion' python3 - "$CASE/calls" <<'PY'
import sys
calls = open(sys.argv[1]).read().splitlines()
assert calls.index('provenance-verify true') < calls.index('promote') < calls.index('provenance-verify false') < calls.index('dispatch')
assert calls.index('sign-provenance') < calls.index('payload-publish') < calls.index('provenance-publish') < calls.index('sbom-publish')
PY
HASH=$(_rf_hash "$CASE/proofs/release.intoto.jsonl.minisig")
run_code 'public retry reuses exact proof bytes and does not repromote' 0 finalize --promote --tool tool --dispatch-repos owner/checksums
assert 'retries do not sign another pair' test "$(count sign-provenance)" = 1
assert 'retries do not issue another promotion' test "$(count promote)" = 1
assert 'retry signature bytes remain identical' test "$HASH" = "$(_rf_hash "$CASE/proofs/release.intoto.jsonl.minisig")"
BEFORE=$(count context)
run_code 'provenance policy cannot be omitted on retry' 2 base --promote --tool tool --dispatch-repos owner/checksums
run_code 'builder policy cannot change on retry' 2 base --require-provenance --provenance-builder other --promote --tool tool --dispatch-repos owner/checksums
assert 'policy conflicts fail before release access' test "$BEFORE" = "$(count context)"
new_case legacy
run_code 'existing signed finalization remains available without provenance' 0 base --promote
assert 'legacy path never calls provenance publication' test "$(count provenance-publish)" = 0
assert 'legacy success does not imply provenance authentication' jq -e 'has("provenance")|not' "$CASE/result.json"
for mode in sign-fail provenance-publish-fail malformed-publication pre-verify-fail wrong-inventory remote-late-drift local-late-drift; do
    new_case "$mode"; MODE=$mode; expected=7
    case "$mode" in sign-fail) expected=42 ;; provenance-publish-fail) expected=8 ;; esac
    run_code "$mode cannot promote or dispatch" "$expected" finalize --promote --tool tool --dispatch-repos owner/checksums
    assert 'failure before promotion retains draft' jq -e '.release.draft' "$CASE/context.json"
    assert 'failure sends no downstream event' test "$(count dispatch)" = 0
 done
for mode in lost-statement lost-signature; do
    new_case "$mode"; MODE=$mode
    run_code 'lost upload acknowledgement blocks promotion' 8 finalize --promote
    run_code 'same invocation reconciles the retained pair' 0 finalize --promote
    assert 'statement is uploaded only once' test "$(count 'upload release.intoto.jsonl')" = 1
    assert 'signature is uploaded only once' test "$(count 'upload release.intoto.jsonl.minisig')" = 1
    assert 'upload retry does not re-sign' test "$(count sign-provenance)" = 1
 done
INDEX=0
for mutation in '.authenticated=false' '.builder="other"' '.targets=["linux/amd64"]' \
    '.build_manifest_sha256=("0"*64)' '.invocation_id="other"' '.artifact_count=1' \
    '.statement.sha256=("0"*64)' '.signature.sha256=("0"*64)' '.statement.asset_id=.signature.asset_id' \
    '.release.id=99' '.release.draft=false' '.verification_policy="different"'; do
    INDEX=$((INDEX+1)); new_case "receipt-$INDEX"; MUTATION=$mutation
    run_code 'mismatched publication evidence cannot satisfy provenance policy' 7 finalize --promote
    assert 'bad receipt did not reach SBOM publication or promotion' test "$(count sbom-publish):$(count promote)" = 0:0
 done
new_case post-failure; MODE=post-verify-fail
run_code 'post-promotion authentication failure blocks dispatch' 7 finalize --promote --tool tool --dispatch-repos owner/checksums
assert 'post-promotion failure does not pretend draft was restored' jq -e '.release.draft==false' "$CASE/context.json"
assert 'post-promotion failure sends no downstream event' test "$(count dispatch)" = 0
MODE=''
run_code 'post-promotion retry verifies without another PATCH' 0 finalize --promote --tool tool --dispatch-repos owner/checksums
assert 'post-promotion recovery preserves one promotion attempt' test "$(count promote)" = 1
new_case vanished-local
run_code 'prepare verified draft before local signature loss' 0 finalize
mv "$CASE/proofs/release.intoto.jsonl.minisig" "$CASE/held-signature"
BEFORE=$(count provenance-publish)
run_code 'missing retained proof is not silently regenerated' 7 finalize --promote
assert 'missing-proof retry does not sign again' test "$(count sign-provenance)" = 1
assert 'missing-proof retry never calls publisher' test "$BEFORE" = "$(count provenance-publish)"
new_case forged-state
run_code 'prepare verified draft before checkpoint mutation' 0 finalize
STATE=$(state_file)
jq '.provenance_verification.signature.sha256=("0"*64)' "$STATE" > "$CASE/next-state"
cp "$CASE/next-state" "$STATE"
BEFORE=$(count context)
run_code 'mismatched retained receipt is rejected before remote effects' 2 finalize --promote
assert 'corrupt state never reaches release access' test "$BEFORE" = "$(count context)"
new_case dispatch-drift; MODE=dispatch-key-drift
run_code 'key drift at downstream boundary blocks delivery' 7 finalize --promote --tool tool --dispatch-repos owner/checksums
assert 'dispatch guard executes before event' test "$(count dispatch)" = 0
new_case large
jq '.build_environments=[{target:"linux/amd64",private_environment:("x"*150000)}]' "$BUILD" > "$CASE/large.json"
cp "$CASE/large.json" "$BUILD"
run_code 'large private build evidence reaches the provenance gate' 0 finalize --promote
assert 'private environment is not published inside the statement' test "$(wc -c < "$CASE/proofs/release.intoto.jsonl")" -lt 10000
new_case prepared
release_prepare_integrity "$CASE/artifacts" --build-manifest "$BUILD" --repo owner/tool --tag v1.0.0 --sha "$SOURCE_SHA" \
    --public-key "$CASE/key.pub" --output-dir "$CASE/proofs" || exit 1
POLICY=$(_rf_provenance_plan "$BUILD" owner/tool v1.0.0 "$SOURCE_SHA" "$BUILDER" "$TOKEN" "$(_rf_hash "$BUILD")") || exit 1
_rf_provenance_prepare "$CASE/artifacts" "$BUILD" owner/tool "$CASE/key.pub" "$CASE/key.key" \
    "$CASE/proofs" "$POLICY" false > "$CASE/prepared-documents.json" || exit 1
: > "$CASE/calls"
prepared() {
    release_finalize "$CASE/artifacts" --repo owner/tool --tag v1.0.0 --sha "$SOURCE_SHA" --build-manifest "$BUILD" \
        --upload-payloads --output-dir "$CASE/meta" --state-dir "$CASE/state" --prepared-signatures \
        --public-key "$CASE/key.pub" --integrity-dir "$CASE/proofs" --require-provenance --provenance-builder "$BUILDER" "$@"
}
mv "$CASE/proofs/release.intoto.jsonl.minisig" "$CASE/held-signature"
run_code 'prepared mode rejects missing provenance before remote access' 7 prepared --promote
assert 'invalid prepared provenance creates no state' test ! -e "$CASE/state"
assert 'invalid prepared provenance performs no remote access or signing' test ! -s "$CASE/calls"
mv "$CASE/held-signature" "$CASE/proofs/release.intoto.jsonl.minisig"
run_code 'prepared provenance supports local authentication-only planning' 0 prepared --dry-run
assert 'prepared planning creates no state' test ! -e "$CASE/state"
run_code 'prepared signing policy publishes without a private key' 0 prepared --promote
assert 'prepared flow never calls a signer' test "$(count sign-provenance)" = 0
assert 'prepared proof identity is retained exactly' jq -e --slurpfile docs "$CASE/prepared-documents.json" \
    '.integrity_policy.mode=="prepared" and .provenance_documents==$docs[0] and .phase=="published"' "$(state_file)"
printf '\nProvenance-gated finalization: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
