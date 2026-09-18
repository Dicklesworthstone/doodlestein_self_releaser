#!/usr/bin/env bash
# Production uploader/finalizer with real manifests, hashing and state. GitHub,
# SBOM scanning/publication and dispatch boundaries are explicit fixtures.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DSR_PAYLOAD_FIXTURES_ONLY=true source "$HERE/test_release_payloads.sh"
source "${FINALIZER_TEST_MODULE:-$ROOT/src/release_finalize.sh}"

_sbr_context() {
    if [[ "${PIPE_MODE:-}" == manifest_before_upload && ! -f "$CASE/manifest-moved" ]]; then
        : > "$CASE/manifest-moved"
        change_json "$MANIFEST" '.run_id="different-build"'
    fi
    cat "$CASE/context.json"
}

sbom_generate_artifacts() {
    printf 'scan\n' >> "$CASE/stages"
    [[ "${PIPE_MODE:-}" != scan_fail ]] || return 6
    local root="$1" out="${*: -1}" entries='' name hash doc_hash
    mkdir -p "$out"
    for name in a.tar.gz b.zip z-compat.tar.gz; do
        hash=$(_slsa_sha256 "$root/$name") || return 1
        printf '{"spdxVersion":"SPDX-2.3","name":"%s"}\n' "$name" > "$out/$name.sbom.spdx.json"
        doc_hash=$(_slsa_sha256 "$out/$name.sbom.spdx.json") || return 1
        entries+="$(jq -nc --arg name "$name" --arg hash "$hash" --arg doc "$doc_hash" \
            '{artifact:{name:$name,sha256:$hash},sbom:{name:($name+".sbom.spdx.json"),sha256:$doc}}')"$'\n'
    done
    jq -sc '{schema_version:1,kind:"dsr-sbom-release",status:"complete",format:"spdx",selection_policy:"top-level-artifacts-v1",artifacts:.}' \
        <<< "$entries" > "$out/sbom-manifest.spdx.json"
    case "${PIPE_MODE:-}" in
        wrong_sbom) change_json "$out/sbom-manifest.spdx.json" '.artifacts[0].artifact.sha256=("0"*64)' ;;
        manifest_drift) printf ' ' >> "$MANIFEST" ;;
        source_drift_after_scan) printf changed >> "$ART/b.zip" ;;
    esac
    printf '%s\n' "$out/sbom-manifest.spdx.json"
}
sbom_verify_artifacts() { [[ -f "${*: -1}/sbom-manifest.spdx.json" ]]; }
sbom_publish_artifacts() {
    printf 'metadata\n' >> "$CASE/stages"
    [[ "${PIPE_MODE:-}" != metadata_fail ]] || return 7
    local file="${*: -1}/sbom-manifest.spdx.json" sha size
    sha=$(_slsa_sha256 "$file"); size=$(wc -c < "$file")
    jq -cS --arg sha "$sha" --argjson size "$size" '
        [.[]|select(.name!="sbom-manifest.spdx.json")]+
        [{id:800,name:"sbom-manifest.spdx.json",state:"uploaded",size:$size,digest:("sha256:"+$sha)}]|sort_by(.name)' \
        "$CASE/inventory.json" > "$CASE/inventory.next"
    mv "$CASE/inventory.next" "$CASE/inventory.json"
    cp "$file" "$CASE/remote/800"
    if [[ "${PIPE_MODE:-}" == replaced_after_upload ]]; then
        change_json "$CASE/inventory.json" 'map(if .name=="a.tar.gz" then .id=999 else . end)'
    fi
    printf '%s\n' '{"kind":"dsr-sbom-publication","status":"verified","dry_run":false}'
}
sbom_verify_release() {
    printf 'verify\n' >> "$CASE/stages"
    local context expected="${*: -1}" actual fingerprint
    context=$(cat "$CASE/context.json")
    actual=$(_slsa_sha256 "$CASE/remote/800") || return 7
    [[ "$actual" == "$expected" ]] || return 7
    fingerprint=$(_sbr_inventory_sha256 "$(cat "$CASE/inventory.json")" "$WORK") || return 1
    jq -nc --argjson context "$context" --arg hash "$actual" --arg fingerprint "$fingerprint" '
        $context+{schema_version:1,kind:"dsr-sbom-remote-verification",status:"verified",format:"spdx",
          verification_policy:"expected-manifest-sha256",artifact_count:3,asset_inventory_sha256:$fingerprint,
          manifest:{name:"sbom-manifest.spdx.json",sha256:$hash,asset_id:800}}'
}
gh() {
    printf 'promote\n' >> "$CASE/stages"
    [[ "$*" == *'--method PATCH repos/owner/tool/releases/17'* ]] || return 4
    jq -e '.=={draft:false,make_latest:"false"}' "${*: -1}" >/dev/null || return 4
    change_json "$CASE/context.json" '.release.draft=false'
    if [[ "${PIPE_MODE:-}" == after_promotion ]]; then printf changed >> "$ART/b.zip"; fi
    [[ "${PIPE_MODE:-}" != lost_promotion ]] || return 8
    printf '{}\n'
}
# The finalizer's actual guards are invoked at the dispatch boundary. The
# persistent outbox itself has its separate test_release_finalize.sh coverage.
_rf_dispatch_require() { :; }
dispatch_check_auth() { :; }
_dp_repos() { printf '%s\n' "${1//,/$'\n'}" | LC_ALL=C sort -u; }
_dp_release_plan() { jq -nc --arg repo "$1" --argjson payload "$3" '{source_repo:$repo,payload:$payload}'; }
_rf_dispatch_preflight() { :; }
_dp_release_outbox() {
    "$5" || return $?
    printf 'dispatch\n' >> "$CASE/stages"
    if [[ "${PIPE_MODE:-}" == dispatch_mutation ]]; then
        printf changed >> "$ART/b.zip"
        "$5" || return $?
    fi
    printf '%s\n' '{"status":"accepted","exit_code":0,"results":[{"repo":"owner/downstream","outcome":"accepted"}]}'
}
new_pipeline_case() {
    new_case "$1"
    : > "$CASE/stages"
    unset PIPE_MODE
    export DSR_STATE_DIR="$CASE/dsr-state"
}
pipeline() {
    release_finalize "$ART" --repo owner/tool --tag v1.0.0 --sha "$PIN" \
        --upload-payloads --build-manifest "$MANIFEST" --output-dir "$CASE/proofs" \
        --state-dir "$CASE/finalize-state" "$@"
}
if [[ "${DSR_PIPELINE_FIXTURES_ONLY:-false}" == true ]]; then return 0; fi

new_pipeline_case complete
capture pipeline --promote
check 'one command uploads payloads and publishes release' test "$status" -eq 0
check 'pipeline receipt includes verified upload binding' jq -e '.status=="published" and .payloads.status=="verified" and .payloads.manifest_sha256!=null and .verification.tag_commit==("1"*40)' "$CASE/out"
check 'all build assets uploaded once' test "$(count)" -eq 3
check 'public release is observed after promotion' jq -e '.release.draft==false' "$CASE/context.json"
check 'promotion occurs exactly once' test "$(grep -c '^promote$' "$CASE/stages")" -eq 1
capture pipeline --promote
check 'complete pipeline can be retried' test "$status" -eq 0
check 'retry does not reupload binaries' test "$(count)" -eq 3
check 'retry does not repeat promotion' test "$(grep -c '^promote$' "$CASE/stages")" -eq 1
capture release_finalize "$ART" --repo owner/tool --tag v1.0.0 --sha "$PIN" --output-dir "$CASE/proofs" --state-dir "$CASE/finalize-state"
check 'configured build plan cannot be omitted on retry' test "$status" -eq 2

new_pipeline_case raw_failure
MODE=fail; capture pipeline --promote
check 'payload failure aborts later stages' nonzero "$status"
check 'no scanner or metadata runs after failed upload' test ! -s "$CASE/stages"
check 'payload failure retains draft' jq -e '.release.draft==true' "$CASE/context.json"
unset MODE; capture pipeline --promote
check 'pipeline resumes partial payload upload' test "$status" -eq 0
check 'pipeline resume sends only missing binaries' test "$(count)" -eq 4

new_pipeline_case metadata_failure
PIPE_MODE=metadata_fail; capture pipeline --promote
check 'metadata failure propagates after retained payloads' nonzero "$status"
check 'metadata failure keeps payloads for retry' test "$(count)" -eq 3
check 'metadata failure does not promote' jq -e '.release.draft' "$CASE/context.json"
unset PIPE_MODE; capture pipeline --promote
check 'metadata failure can recover without rebuilding or reuploading' test "$status" -eq 0
check 'metadata recovery makes no duplicate upload' test "$(count)" -eq 3

for mode in wrong_sbom manifest_drift source_drift_after_scan replaced_after_upload; do
    new_pipeline_case "$mode"; PIPE_MODE="$mode"; capture pipeline --promote
    check "$mode blocks finalization" nonzero "$status"
    check "$mode cannot promote the release" jq -e '.release.draft==true' "$CASE/context.json"
    check "$mode emits structured failure" jq -e '.exit_code!=0 and .status=="error"' "$CASE/out"
done
new_pipeline_case lost_promotion
PIPE_MODE=lost_promotion; capture pipeline --promote
check 'lost promotion acknowledgement is reconciled by verification' test "$status" -eq 0
check 'reconciled promotion preserves transport failure evidence' jq -e '.promotion_transport_exit_code==8 and .status=="published"' "$CASE/out"
new_pipeline_case after_promotion
PIPE_MODE=after_promotion; capture pipeline --promote
check 'late source change is not reported as success' nonzero "$status"
check 'already published release is never rolled back' jq -e '.release.draft==false' "$CASE/context.json"
new_pipeline_case dry
capture pipeline --promote --dry-run
check 'integrated dry-run validates upload selection' test "$status" -eq 0
check 'dry-run describes the upload stage' jq -e '.status=="planned" and .payload_plan.manifest_sha256!=null and (.stages|index("upload and verify build payloads"))!=null' "$CASE/out"
check 'integrated dry-run performs no remote auth' test ! -s "$CASE/auth"
check 'integrated dry-run creates no durable finalization state' test ! -d "$CASE/finalize-state"
check 'integrated dry-run invokes no release stages' test ! -s "$CASE/stages"
new_pipeline_case missing_option
capture release_finalize "$ART" --repo owner/tool --tag v1.0.0 --sha "$PIN" --upload-payloads
check 'upload requires a build manifest' test "$status" -eq 4
capture release_finalize "$ART" --repo owner/tool --tag v1.0.0 --sha "$PIN" --build-manifest "$MANIFEST"
check 'build manifest cannot be silently ignored without upload option' test "$status" -eq 4
check 'bad paired options have no uploads' test "$(count)" -eq 0
new_pipeline_case dispatch
capture pipeline --promote --tool tool --dispatch-repos owner/downstream
check 'upload/promotion pipeline reaches guarded handoff' test "$status" -eq 0
check 'handoff result retains payload evidence' jq -e '.status=="complete" and .payloads.status=="verified" and .dispatch.status=="accepted"' "$CASE/out"
check 'handoff is after promotion' test "$(tail -1 "$CASE/stages")" = dispatch
new_pipeline_case wrong_tool
capture pipeline --promote --tool another --dispatch-repos owner/downstream
check 'dispatch tool must match build manifest' test "$status" -eq 4
check 'wrong tool fails before raw uploads' test "$(count)" -eq 0
new_pipeline_case manifest_before_upload
PIPE_MODE=manifest_before_upload
capture pipeline --promote
check 'changed manifest between planning and upload is a conflict' test "$status" -eq 2
check 'changed planned manifest causes zero raw uploads' test "$(count)" -eq 0
check 'changed planned manifest blocks all later release stages' test ! -s "$CASE/stages"
new_pipeline_case dispatch_mutation
PIPE_MODE=dispatch_mutation
capture pipeline --promote --tool tool --dispatch-repos owner/downstream
check 'build drift at handoff is rejected by production guard' nonzero "$status"
check 'handoff failure preserves published-release and upload evidence' jq -e '.status=="incomplete" and .payloads.status=="verified" and .verification.release.draft==false' "$CASE/out"

new_pipeline_case ready
capture pipeline
check 'upload without promotion retains a ready draft' test "$status" -eq 0
check 'ready result distinguishes verification from publication' jq -e '.status=="ready" and .payloads.status=="verified" and .promotion_attempted==false' "$CASE/out"
check 'upload option alone never publishes release' jq -e '.release.draft==true' "$CASE/context.json"

new_pipeline_case existing_payloads
seed a.tar.gz 201; seed b.zip 202; seed z-compat.tar.gz 203
# Ambient variables cannot opt a legacy invocation into the build-payload gate.
export _RF_BUILD_PLAN='not a plan' _RF_BUILD_MANIFEST=/nonexistent
capture release_finalize "$ART" --repo owner/tool --tag v1.0.0 --sha "$PIN" \
    --output-dir "$CASE/proofs" --state-dir "$CASE/finalize-state" --promote
check 'existing-upload invocation still finalizes without new flags' test "$status" -eq 0
check 'legacy result does not claim to have uploaded payloads' jq -e '.status=="published" and .payloads==null' "$CASE/out"
check 'legacy finalization never invokes raw uploader' test "$(count)" -eq 0
unset _RF_BUILD_PLAN _RF_BUILD_MANIFEST

new_pipeline_case concurrent_pipeline
pids=()
for i in 1 2 3 4; do pipeline --promote > "$CASE/pipeline-$i.out" 2> "$CASE/pipeline-$i.err" & pids+=("$!"); done
passed=0
for pid in "${pids[@]}"; do if wait "$pid"; then passed=$((passed+1)); fi; done
check 'nested payload and finalizer locks permit one complete pipeline' test "$passed" -ge 1
check 'competing pipelines do not duplicate raw uploads' test "$(count)" -eq 3
check 'competing pipelines promote once' test "$(grep -c '^promote$' "$CASE/stages")" -eq 1
capture pipeline --promote
check 'completed concurrent pipeline remains recoverable' test "$status" -eq 0

printf '\nPayload pipeline checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
