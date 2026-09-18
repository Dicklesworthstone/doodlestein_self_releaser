#!/usr/bin/env bash
# End-to-end local inventory -> staged upload -> independent remote verification.
# Files/hashes/process races are real; GitHub and Syft are explicit fixtures.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/test_sbom_remote.sh"
UPLOAD_MODE='' PUBLISH_OUTPUT=''
gh_upload_asset_named() (
    local url="$1" file="$2" name="$3" type="$4" attempts=0 existing id
    [[ "$url" == 'https://uploads.github.com/repos/acme/tool/releases/42/assets{?name,label}' &&
       "$file" == */proofs/* && "$type" == application/json && -f "$file" && ! -L "$file" ]] || return 99
    while ! mkdir "$REMOTE/upload-lock" 2>/dev/null; do
        attempts=$((attempts+1)); ((attempts < 250)) || return 8
        sleep 0.02
    done
    trap 'rmdir "$REMOTE/upload-lock" 2>/dev/null || true' EXIT
    printf '%s\n' "$name" >> "$CASE/uploads.log"
    if [[ "$UPLOAD_MODE" == fail-second && "$name" == b.tar.xz.sbom.* ]] ||
       [[ "$UPLOAD_MODE" == manifest-fail && "$name" == sbom-manifest.* ]]; then return 8; fi
    if [[ "$UPLOAD_MODE" == timeout ]]; then (trap '' TERM; sleep 30) & wait; return; fi
    if [[ "$UPLOAD_MODE" == false-success ]]; then
        jq -nc --arg name "$name" --arg sha "$(_sbom_hash "$file")" --argjson size "$(wc -c < "$file")" \
            '{id:999,name:$name,size:$size,state:"uploaded",digest:("sha256:"+$sha)}'
        return
    fi
    existing=$(jq -c --arg name "$name" '[.[] | select(.name == $name)][0] // null' "$REMOTE/inventory.json")
    if [[ "$existing" != null ]]; then
        [[ "$(jq -r '.digest' <<< "$existing")" == "sha256:$(_sbom_hash "$file")" ]] || return 7
        printf '%s\n' "$existing"
        return
    fi
    remote_add "$name" "$file" || return 8
    if [[ "$UPLOAD_MODE" == lost-ack && "$name" == a.tar.gz.sbom.* ]]; then return 8; fi
    if [[ "$UPLOAD_MODE" == bad-receipt ]]; then printf '{}\n'; return; fi
    if [[ "$name" == a.tar.gz.sbom.* ]]; then
        case "$UPLOAD_MODE" in
            local-payload) printf changed >> "$ART/a.tar.gz" ;;
            local-proof) printf changed >> "$ART/b.tar.xz.sbom.spdx.json" ;;
            remote-payload) edit_inventory 'map(if .name == "a.tar.gz" then .digest = ("sha256:" + ("0"*64)) else . end)' ;;
            remote-extra) printf extra > "$CASE/extra.zip"; remote_add extra.zip "$CASE/extra.zip" ;;
            tag) printf '%040d\n' 2 > "$REMOTE/tag.sha" ;;
        esac
    fi
    if [[ "$UPLOAD_MODE" == final-mutation && "$name" == sbom-manifest.* ]]; then
        edit_inventory 'map(if .name == "b.tar.xz.sbom.spdx.json" then .digest = ("sha256:" + ("0"*64)) else . end)'
    fi
    jq -c --arg name "$name" '.[] | select(.name == $name)' "$REMOTE/inventory.json"
)
new_publication() {
    new_case "$1" "${2:-spdx}"
    edit_inventory 'map(select(.name == "a.tar.gz" or .name == "b.tar.xz"))'
    : > "$CASE/uploads.log"
    UPLOAD_MODE=''; PUBLISH_OUTPUT=''; SYFT_DISABLED=true
}
publish() {
    local -a args=("$ART" --repo acme/tool --tag v1.2.3 --format "$FORMAT")
    [[ -z "$PUBLISH_OUTPUT" ]] || args+=(--output-dir "$PUBLISH_OUTPUT")
    sbom_publish_artifacts "${args[@]}" "$@"
}
no_aggregate() {
    jq -e '[.[] | select(.name | startswith("sbom-manifest."))] | length == 0' "$REMOTE/inventory.json" >/dev/null
}
no_uploads() { [[ ! -s "$CASE/uploads.log" ]]; }
complete_documents() {
    jq -e '[.[] | select(.name | contains(".sbom."))] | length == 2' "$REMOTE/inventory.json" >/dev/null
}

for format in spdx cyclonedx; do
    new_publication "publish-$format" "$format"
    capture publish
    check "$format publication completes verified remote inventory" test "$status" -eq 0
    check "$format returns a typed independently verified receipt" jq -e '.status == "verified" and .verification.artifact_count == 2 and .manifest_upload_attempted == true' "$CASE/stdout"
    check "$format publishes documents plus aggregate only" test "$(wc -l < "$CASE/uploads.log")" -eq 3
    check "$format publishes aggregate last" test "$(tail -1 "$CASE/uploads.log")" = "sbom-manifest.$(_sbom_extension "$format")"
    check "$format never uploads raw payloads or private scan receipts" bash -c '! grep -Ev "^(a.tar.gz.sbom.|b.tar.xz.sbom.|sbom-manifest.)" "$1"' bash "$CASE/uploads.log"
    check "$format leaves release in its existing draft state" jq -e '.draft == true' "$REMOTE/release.json"
    cp "$REMOTE/inventory.json" "$CASE/inventory.before-retry"
    capture publish
    check "$format verified retry succeeds without Syft" test "$status" -eq 0
    check "$format verified retry invokes no new uploads" test "$(wc -l < "$CASE/uploads.log")" -eq 3
    check "$format retry preserves every remote asset ID/digest" cmp -s "$CASE/inventory.before-retry" "$REMOTE/inventory.json"
    check "$format retry reports no attempted additions" jq -e '.sbom_upload_attempts == 0 and .manifest_upload_attempted == false' "$CASE/stdout"
done

new_publication dry-run
cp "$REMOTE/inventory.json" "$CASE/before"
capture publish --dry-run
check 'dry-run performs complete preflight and reports a plan' test "$status" -eq 0
check 'dry-run is not a verified publication' jq -e '.status == "planned" and .dry_run == true and (.actions | length) == 3' "$CASE/stdout"
check 'dry-run performs zero uploads' no_uploads
check 'dry-run preserves remote inventory' cmp -s "$CASE/before" "$REMOTE/inventory.json"
new_publication global-dry-run
DRY_RUN=true
capture publish
check 'global dry-run is honored by the publication API' jq -e '.status == "planned"' "$CASE/stdout"
check 'global dry-run performs zero uploads' no_uploads
unset DRY_RUN

new_publication partial
UPLOAD_MODE=fail-second
capture publish
check 'later SBOM upload failure remains failure' test "$status" -eq 8
check 'failed batch never publishes aggregate' no_aggregate
check 'completed first SBOM remains available for retry' jq -e '[.[] | select(.name == "a.tar.gz.sbom.spdx.json")] | length == 1' "$REMOTE/inventory.json"
check 'failed batch emits no success JSON' no_success
UPLOAD_MODE=''
capture publish
check 'partial publication resumes successfully' test "$status" -eq 0
check 'resume only retries missing SBOM and aggregate' test "$(wc -l < "$CASE/uploads.log")" -eq 4
check 'resume reports one SBOM upload attempt' jq -e '.sbom_upload_attempts == 1 and .manifest_upload_attempted == true' "$CASE/stdout"

new_publication ambiguous-ack
UPLOAD_MODE=lost-ack
capture publish
check 'lost upload acknowledgement does not imply completion' test "$status" -eq 8
check 'lost acknowledgement leaves no aggregate' no_aggregate
UPLOAD_MODE=''
capture publish
check 'retry reconciles persisted bytes after lost acknowledgement' test "$status" -eq 0
check 'lost-ack retry never clobbers or reuploads matching first SBOM' test "$(grep -c '^a.tar.gz.sbom.' "$CASE/uploads.log")" -eq 1

new_publication aggregate-failure
UPLOAD_MODE=manifest-fail
capture publish
check 'aggregate failure propagates' test "$status" -eq 8
check 'aggregate failure preserves complete individual documents' complete_documents
check 'aggregate failure leaves no complete marker' no_aggregate
UPLOAD_MODE=''
capture publish
check 'aggregate-only retry completes' test "$status" -eq 0
check 'aggregate-only retry invokes no SBOM uploads' jq -e '.sbom_upload_attempts == 0 and .manifest_upload_attempted == true' "$CASE/stdout"

new_publication false-success
UPLOAD_MODE=false-success
capture publish
check 'HTTP/adapter success without stored bytes cannot pass' test "$status" -eq 7
check 'false-success receipts cannot cause aggregate upload' no_aggregate
new_publication bad-receipt
UPLOAD_MODE=bad-receipt
capture publish
check 'malformed successful upload receipt fails closed' test "$status" -eq 7
check 'invalid receipt cannot publish aggregate' no_aggregate

for mutation in local-payload local-proof remote-payload remote-extra tag; do
    new_publication "mutation-$mutation"
    UPLOAD_MODE="$mutation"
    capture publish
    check "$mutation during publication fails closed" nonzero "$status"
    check "$mutation blocks aggregate upload" no_aggregate
    check "$mutation emits no success JSON" no_success
done
new_publication replaced-proof
LATE_MODE=proof-id
capture publish
check 'document replacement after byte verification is rejected before aggregate' test "$status" -eq 7
check 'recreated identical document ID cannot acquire a completion marker' no_aggregate
new_publication late-tag
LATE_MODE=tag
capture publish
check 'tag movement during pre-aggregate downloads is rejected' test "$status" -eq 7
check 'tag movement before aggregate leaves no marker' no_aggregate
new_publication post-aggregate
UPLOAD_MODE=final-mutation
capture publish
check 'post-upload verification can reject a published aggregate' test "$status" -eq 7
check 'late failure does not delete already-published assets' jq -e '[.[] | select(.name == "sbom-manifest.spdx.json")] | length == 1' "$REMOTE/inventory.json"
check 'late failure does not emit success JSON' no_success

new_publication final-observation
MODE=final-proof-id
capture publish
check 'final gate observes a recreated metadata asset after independent verification' jq -e \
    '.[] | select(.name == "a.tar.gz.sbom.spdx.json") | .id == 9100' "$REMOTE/inventory.json"
check 'final success remains bound to the verified asset IDs' test "$status" -eq 7
check 'changed final inventory emits no success JSON' no_success

new_publication known-conflict
remote_add b.tar.xz.sbom.spdx.json "$ART/b.tar.xz.sbom.spdx.json"
edit_inventory 'map(if .name == "b.tar.xz.sbom.spdx.json" then .digest = ("sha256:" + ("0"*64)) else . end)'
capture publish
check 'conflicting later target is rejected during all-target preflight' test "$status" -eq 7
check 'known later conflict causes zero uploads of earlier missing targets' no_uploads
new_case incomplete-complete
: > "$CASE/uploads.log"; UPLOAD_MODE=''; PUBLISH_OUTPUT=''
edit_inventory 'map(select(.name != "b.tar.xz.sbom.spdx.json"))'
capture publish
check 'existing completeness marker with missing document is a hard conflict' test "$status" -eq 7
check 'incomplete published promise is not silently repaired' no_uploads
new_publication orphan-signature
printf signature > "$CASE/signature"
remote_add a.tar.gz.sbom.spdx.json.minisig "$CASE/signature"
capture publish
check 'orphan remote signature blocks attaching new unsigned bytes' test "$status" -eq 7
check 'orphan signature is rejected before uploads' no_uploads
new_publication raw-size
edit_inventory 'map(if .name == "a.tar.gz" then .size += 1 else . end)'
capture publish
check 'remote payload size is checked against the verified local source' test "$status" -eq 7
check 'payload size mismatch prevents all uploads' no_uploads

new_publication bad-local
printf changed >> "$ART/a.tar.gz"
capture publish --dry-run
check 'dry-run cannot bypass stale local inventory' nonzero "$status"
check 'stale local inventory fails before any remote read' test ! -s "$CASE/api.log"
check 'stale local inventory fails before any upload' no_uploads
new_publication missing-local-manifest
mv "$ART/sbom-manifest.spdx.json" "$CASE/retained-manifest.json"
capture publish
check 'publication requires an existing verified local aggregate' nonzero "$status"
check 'missing aggregate never triggers a scan or remote upload' no_uploads

new_publication published
jq '.draft = false' "$REMOTE/release.json" > "$REMOTE/release.next"; mv "$REMOTE/release.next" "$REMOTE/release.json"
capture publish
check 'adding metadata to public releases requires explicit consent' test "$status" -eq 4
check 'public-release default performs no uploads' no_uploads
capture publish --allow-published
check 'explicit public-release additions are supported' test "$status" -eq 0
check 'publisher does not change public release mode' jq -e '.draft == false' "$REMOTE/release.json"
capture publish
check 'completed public release has a read-only retry without override' test "$status" -eq 0
check 'public retry performs no additional uploads' test "$(wc -l < "$CASE/uploads.log")" -eq 3

new_publication separate-output
PUBLISH_OUTPUT="$CASE/evidence"
mkdir "$PUBLISH_OUTPUT"
for file in "$ART/"*.json; do mv "$file" "$PUBLISH_OUTPUT/"; done
capture publish
check 'separate generated-metadata directory is supported' test "$status" -eq 0
check 'separate output publishes aggregate with its public basename' test "$(tail -1 "$CASE/uploads.log")" = sbom-manifest.spdx.json
new_publication aliases
SYFT_DISABLED=false
ln "$ART/a.tar.gz" "$ART/compat-linux.tar.gz"
PUBLISH_OUTPUT="$CASE/alias-evidence"
sbom_generate_artifacts "$ART" --output-dir "$PUBLISH_OUTPUT" > "$CASE/generated-alias" 2> "$CASE/generate-alias.log" || exit 1
SYFT_DISABLED=true
remote_add compat-linux.tar.gz "$ART/compat-linux.tar.gz"
capture publish
check 'byte-identical compatibility aliases remain separately covered' test "$status" -eq 0
check 'alias publication verifies three named payloads' jq -e '.verification.artifact_count == 3 and .sbom_upload_attempts == 3' "$CASE/stdout"

new_publication timeout
UPLOAD_MODE=timeout; SBOM_REMOTE_TIMEOUT=1; start=$SECONDS
capture publish
check 'stalled upload is terminated rather than blocking release forever' test "$status" -eq 5
check 'upload timeout leaves no complete marker' no_aggregate
check 'upload timeout is bounded' test "$((SECONDS-start))" -le 8
SBOM_REMOTE_TIMEOUT=10

new_publication cli
export CASE ART REMOTE MODE DOWNLOAD_MODE LATE_MODE UPLOAD_MODE SYFT_DISABLED
export -f gh_api gh_resolve_tag_sha gh_download_release_asset gh_upload_asset_named remote_add edit_inventory
capture bash "$ROOT/src/sbom.sh" publish-artifacts "$ART" --repo acme/tool --tag v1.2.3
check 'existing SBOM module CLI dispatches the publication path' test "$status" -eq 0
capture bash "$ROOT/src/sbom.sh" verify-release --repo acme/tool --tag v1.2.3 --manifest-sha256 "$PIN"
check 'existing SBOM module CLI dispatches independent remote verification' test "$status" -eq 0
capture bash "$ROOT/src/sbom_release.sh" publish "$ART" --repo acme/tool --tag v1.2.3
check 'dedicated remote module CLI also supports verified retry' test "$status" -eq 0
capture bash "$ROOT/src/sbom.sh" publish-artifacts "$ART" --repo
check 'CLI propagates invalid publication options' test "$status" -eq 4

new_publication concurrent
pids=()
for i in 1 2 3; do
    publish > "$CASE/worker-$i.out" 2> "$CASE/worker-$i.err" &
    pids+=("$!")
done
succeeded=0
for pid in "${pids[@]}"; do if wait "$pid"; then succeeded=$((succeeded+1)); fi; done
check 'at least one concurrent publisher completes the release' test "$succeeded" -ge 1
capture verify
check 'concurrent publication leaves one independently verifiable complete set' test "$status" -eq 0
check 'concurrent publishers leave unique named metadata assets' jq -e 'length == 5 and (map(.name)|unique|length) == 5' "$REMOTE/inventory.json"
capture publish
check 'verified retry converges after concurrent publishers' test "$status" -eq 0

printf '\nSBOM publication checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
