#!/usr/bin/env bash
# Production finalizer + integrity pipeline, real native/reference Ed25519 signatures,
# files, hashes and locks. SBOM scanning, payload uploader and dispatch are
# explicit orchestration fixtures; GitHub transport is file-backed.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RI_HARNESS_ONLY=true source "$HERE/test_release_integrity.sh"
# shellcheck source=scripts/test_groups.sh
source "${DSR_TEST_GROUPS_MODULE:-$ROOT/scripts/test_groups.sh}"
# shellcheck source=src/release_finalize.sh
source "${RF_TEST_MODULE:-$ROOT/src/release_finalize.sh}"
# Load real outbox identity helpers before the explicit transport fixtures.
# Lazy loading during finalization would otherwise replace those fixtures.
source "$ROOT/src/dispatch.sh" || exit 1
FI_MODE='' FI_PUBLIC="$WORK/public" FI_SECRET="$WORK/private"
SBOMS='' FI_REQUIRE=true
_sbr_context() {
    printf 'read\n' >> "$CASE/reads"
    if [[ "$FI_MODE" == manifest-before-snapshot ]]; then
        jq '.run_id="changed-after-plan"' "$MANIFEST" > "$CASE/changed-build.json"
        cp "$CASE/changed-build.json" "$MANIFEST"
    fi
    if [[ "$FI_MODE" == key-after-plan ]]; then cp "$WORK/wrong-public" "$FI_PUBLIC"; fi
    cat "$CASE/context.json"
}
_sbr_inventory_sha256() {
    local file
    file=$(mktemp "$2/inventory-digest.XXXXXXXX") || return 1
    jq -cS 'sort_by(.name)' <<< "$1" > "$file" || return 1
    _sbom_hash "$file"
}
# The uploader boundary returns its documented receipt, with real selected files
# and retained IDs. Its internal resume behavior has its own separate suite.
release_upload_payloads() {
    local root="$1" manifest='' repo='' tag='' sha='' dry=false selection context inventory name
    shift
    while (($#)); do
        case "$1" in
            --build-manifest) manifest="$2"; shift 2 ;;
            --repo) repo="$2"; shift 2 ;;
            --tag) tag="$2"; shift 2 ;;
            --sha) sha="$2"; shift 2 ;;
            --state-dir) shift 2 ;;
            --dry-run) dry=true; shift ;;
            *) return 99 ;;
        esac
    done
    selection=$(_rup_manifest "$manifest" "$repo" "$tag" "$sha") || return $?
    if [[ "$dry" == true ]]; then
        jq -nc --argjson selection "$selection" '{kind:"dsr-release-payload-publication",status:"planned",dry_run:true,plan:$selection}'
        return
    fi
    printf 'payload-upload\n' >> "$CASE/events"
    if [[ "$FI_REQUIRE" == true ]]; then
        [[ -f "$PROOFS/release-integrity.json.minisig" ]] || return 98
    fi
    while IFS= read -r name; do
        if ! jq -e --arg name "$name" 'any(.[];.name==$name)' "$CASE/remote/inventory.json" >/dev/null; then
            remote_add "$root/$name" "$name" >/dev/null || return $?
        fi
    done < <(jq -r '.artifacts[].name' <<< "$selection")
    context=$(_sbr_context "$repo" "$tag" "$CASE") || return $?
    inventory=$(_sbr_inventory "$repo" 42 "$CASE") || return $?
    if [[ "$FI_MODE" == manifest-after-payloads ]]; then
        jq '.run_id="changed-after-payload-upload"' "$MANIFEST" > "$CASE/changed-build.json"
        cp "$CASE/changed-build.json" "$MANIFEST"
    fi
    jq -nc --argjson s "$selection" --argjson context "$context" --argjson inventory "$inventory" '
        $context+{kind:"dsr-release-payload-publication",status:"verified",dry_run:false,
         tool:$s.tool,manifest_sha256:$s.manifest_sha256,
         assets:[$inventory[]|select(.name as $n|any($s.artifacts[];.name==$n))]}'
}
# Build deterministic unsigned SBOM observations; signature checking is NOT
# stubbed. This fixture only supplies the independent SBOM subsystem's boundary.
sbom_generate_artifacts() {
    local root="$1" format=spdx output='' name sha doc docsha rows
    shift
    while (($#)); do
        case "$1" in --format) format="$2"; shift 2 ;; --output-dir) output="$2"; shift 2 ;; *) return 99 ;; esac
    done
    printf 'sbom-scan\n' >> "$CASE/events"
    mkdir -p "$output" || return 1
    rows=$(mktemp "$CASE/sbom-rows.XXXXXXXX") || return 1
    while IFS= read -r name; do
        sha=$(_slsa_sha256 "$root/$name") || return $?
        [[ "$FI_MODE" != sbom-other ]] || sha=$(printf '%064d' 0)
        doc="$name.sbom.spdx.json"
        jq -nc --arg name "$name" '{spdxVersion:"SPDX-2.3",dataLicense:"CC0-1.0",SPDXID:"SPDXRef-DOCUMENT",
            name:$name,documentNamespace:"https://example.test/sbom",creationInfo:{creators:["Tool: fixture"],created:"2026-09-18T00:00:00Z"},packages:[]}' > "$output/$doc"
        docsha=$(_slsa_sha256 "$output/$doc") || return $?
        jq -nc --arg name "$name" --arg sha "$sha" --arg doc "$doc" --arg docsha "$docsha" '
            {artifact:{name:$name,sha256:$sha},sbom:{name:$doc,sha256:$docsha}}' >> "$rows"
    done < <(jq -r '.artifacts[].name' "$MANIFEST")
    jq -cs --arg format "$format" '{schema_version:1,kind:"dsr-sbom-release",status:"complete",format:$format,
        selection_policy:"top-level-artifacts-v1",artifacts:sort_by(.artifact.name)}' "$rows" > "$output/sbom-manifest.spdx.json"
    if [[ "$FI_MODE" == local-signature ]]; then printf changed >> "$PROOFS/a.tar.gz.minisig"; fi
    if [[ "$FI_MODE" == replaced-signature-id ]]; then replace_signature_id; fi
    printf '%s\n' "$output/sbom-manifest.spdx.json"
}
sbom_verify_artifacts() {
    local root="$1" output='' name expected
    shift
    while (($#)); do case "$1" in --format) shift 2 ;; --output-dir) output="$2"; shift 2 ;; *) return 99 ;; esac; done
    while IFS=$'\t' read -r name expected; do
        [[ "$(_slsa_sha256 "$root/$name")" == "$expected" ]] || return 7
    done < <(jq -r '.artifacts[].artifact|[.name,.sha256]|@tsv' "$output/sbom-manifest.spdx.json")
}
sbom_publish_artifacts() {
    local root="$1" output='' name
    shift
    while (($#)); do case "$1" in --repo|--tag|--format) shift 2 ;; --output-dir) output="$2"; shift 2 ;; *) return 99 ;; esac; done
    printf 'sbom-publish\n' >> "$CASE/events"
    while IFS= read -r name; do
        if ! jq -e --arg name "$name" 'any(.[];.name==$name)' "$CASE/remote/inventory.json" >/dev/null; then
            remote_add "$output/$name" "$name" >/dev/null || return $?
        fi
    done < <(jq -r '.artifacts[].sbom.name,"sbom-manifest.spdx.json"' "$output/sbom-manifest.spdx.json")
    printf '%s\n' '{"kind":"dsr-sbom-publication","status":"verified","dry_run":false}'
}
sbom_verify_release() {
    local repo='' tag='' format='' pin='' context inventory asset id fingerprint
    while (($#)); do
        case "$1" in --repo) repo="$2" ;; --tag) tag="$2" ;; --format) format="$2" ;; --manifest-sha256) pin="$2" ;; *) return 99 ;; esac
        shift 2
    done
    context=$(_sbr_context "$repo" "$tag" "$CASE") || return $?
    inventory=$(_sbr_inventory "$repo" 42 "$CASE") || return $?
    asset=$(_sbr_named_asset "$inventory" sbom-manifest.spdx.json) || return $?
    id=$(jq -r '.id' <<< "$asset")
    [[ "$(_slsa_sha256 "$CASE/remote/files/$id")" == "$pin" ]] || return 7
    fingerprint=$(_sbr_inventory_sha256 "$inventory" "$CASE") || return $?
    jq -nc --argjson context "$context" --argjson asset "$asset" --arg format "$format" --arg pin "$pin" --arg fingerprint "$fingerprint" \
        --argjson count "$(jq '.artifacts|length' "$CASE/remote/files/$id")" '
        $context+{schema_version:1,kind:"dsr-sbom-remote-verification",status:"verified",format:$format,
          manifest:{name:$asset.name,asset_id:$asset.id,sha256:$pin},artifact_count:$count,
          asset_inventory_sha256:$fingerprint,verification_policy:"expected-manifest-sha256"}'
}
# Promotion goes through the production _rf_promote request builder.
gh() {
    local input="${*: -1}" id
    [[ "$1" == api && " $* " == *' --method PATCH '* ]] || return 99
    jq -e '.=={draft:false,make_latest:"false"}' "$input" >/dev/null || return 99
    printf 'promote\n' >> "$CASE/events"; printf 'patch\n' >> "$CASE/promotions"
    jq '.release.draft=false' "$CASE/context.json" > "$CASE/ctx"; mv "$CASE/ctx" "$CASE/context.json"
    if [[ "$FI_MODE" == remote-after-promote ]]; then
        id=$(jq -r '.[]|select(.name=="a.tar.gz.minisig")|.id' "$CASE/remote/inventory.json")
        # The staged signature copy is 0400; without this a non-root run
        # never changes it and the drift case silently tests nothing.
        chmod u+w "$CASE/remote/files/$id" || return 99
        printf changed >> "$CASE/remote/files/$id"
    fi
    if [[ "$FI_MODE" == local-after-promote ]]; then printf changed >> "$ART/a.tar.gz"; fi
    cat "$CASE/context.json"
}
replace_signature_id() {
    local old next
    old=$(jq -r '.[]|select(.name=="a.tar.gz.minisig")|.id' "$CASE/remote/inventory.json")
    next=$((old+1000)); cp "$CASE/remote/files/$old" "$CASE/remote/files/$next"
    jq --argjson next "$next" 'map(if .name=="a.tar.gz.minisig" then .id=$next else . end)' "$CASE/remote/inventory.json" > "$CASE/new-inventory"
    mv "$CASE/new-inventory" "$CASE/remote/inventory.json"
}
# Dispatch is an explicit delivery boundary fixture. The production finalizer's
# guard is executed before each simulated POST and after the whole handoff.
_dp_config() { return 0; }
_dp_repos() {
    [[ "$1" != *,,* && "$1" != *, && "$1" != ,* ]] || return 4
    tr ',' '\n' <<< "$1" | LC_ALL=C sort -u
}
_dp_release_plan() { jq -nc --arg source "$1" --arg repos "$2" --argjson payload "$3" '{source_repo:$source,payload:$payload,repos:($repos|split("\n"))}'; }
_rf_dispatch_preflight() { return 0; }
dispatch_check_auth() { return 0; }
_dp_release_outbox() {
    local plan="$1" guard="$5" repo rc=0
    printf '%s\n' "$plan" > "$CASE/dispatch-plan.json"
    while IFS= read -r repo; do
        if ! "$guard"; then rc=7; break; fi
        printf '%s\n' "$repo" >> "$CASE/dispatches"
        if [[ "$FI_MODE" == between-dispatches ]]; then replace_signature_id; fi
    done < <(jq -r '.repos[]' <<< "$plan")
    jq -nc --argjson rc "$rc" '{status:(if $rc==0 then "accepted" else "incomplete" end),exit_code:$rc,results:[]}'
    return "$rc"
}
new_fi_case() {
    new_case "finalize-$1"
    SBOMS="$CASE/sboms"; FI_MODE=''; FI_PUBLIC="$WORK/public"; FI_SECRET="$WORK/private"; FI_REQUIRE=true
    : > "$CASE/events"; : > "$CASE/promotions"; : > "$CASE/dispatches"; : > "$CASE/reads"
}
signed() {
    local -a args=()
    [[ -z "$FI_SECRET" ]] || args+=(--secret-key "$FI_SECRET")
    release_finalize "$ART" --repo acme/tool --tag v1.0.0 --sha "$PIN" --build-manifest "$MANIFEST" \
        --output-dir "$SBOMS" --state-dir "$CASE/finalizer" --require-signatures --public-key "$FI_PUBLIC" \
        --integrity-dir "$PROOFS" "${args[@]}" "$@"
}
unsigned() {
    release_finalize "$ART" --repo acme/tool --tag v1.0.0 --sha "$PIN" \
        --output-dir "$SBOMS" --state-dir "$CASE/finalizer" "$@"
}
never_promoted() { [[ ! -s "$CASE/promotions" ]]; }

if [[ "${RF_HARNESS_ONLY:-false}" == true && "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

fi_worker_pass() { check 'worker assertion passes' true; }
fi_worker_failure() { check 'worker assertion fails' false; }
fi_worker_abort() { exit 17; }
fi_worker_nonzero() { check 'worker assertion before failing exit' true; return 17; }
fi_worker_empty() { :; }
fi_worker_bad_counts() { checks=1 failures=2; }
fi_worker_later() { sleep 1; check 'later worker completes' true; printf 'done' > "$FI_REAP_MARKER"; }
fi_expect_group_status() {
    local expected=$1 observed=0; shift
    (checks=0 failures=0; dsr_test_groups "$@") || observed=$?
    [[ "$observed" -eq "$expected" ]]
}
fi_expect_all_reaped() {
    local FI_REAP_MARKER="$WORK/later-worker-finished"
    fi_expect_group_status 1 fi_worker_bad_counts fi_worker_later && [[ -s "$FI_REAP_MARKER" ]]
}

fi_large_inventory_cases() {
    local inventory changed before _RF_INTEGRITY_ASSETS _RF_PROVENANCE_KEY _RF_PROVENANCE_DOCUMENTS status=0
    new_fi_case large-inventory
    add_payloads || return 1
    # Unrelated metadata stays in every publication observation; it must not be
    # dropped to make the selected three-payload release fit one argv element.
    jq -c '.+[range(1000;1500)|{id:.,name:("existing-"+tostring+"-"+("x"*195)+".json"),
        size:7,state:"uploaded",digest:("sha256:"+("a"*64))}]|sort_by(.name)' \
        "$CASE/remote/inventory.json" > "$CASE/large-inventory.json" || return 1
    cp "$CASE/large-inventory.json" "$CASE/remote/inventory.json" || return 1
    check 'signed finalization fixture exceeds the single-argument limit' \
        test "$(wc -c < "$CASE/remote/inventory.json")" -gt 131072
    capture signed --promote
    check 'large inventory completes actual integrity publication and signed finalization' test "$status" -eq 0
    if ((status)); then cat "$CASE/err" "$CASE/out"; return 1; fi
    check 'large inventory result authenticates the promoted release' jq -e \
        '.status=="published" and .integrity.authenticated and (.integrity.release.draft|not)' "$CASE/out"
    check 'large inventory uploads exactly seven integrity proofs' test "$(wc -l < "$CASE/uploads")" -eq 7
    check 'large inventory promotes exactly once' test "$(wc -l < "$CASE/promotions")" -eq 1
    check 'unrelated metadata keeps every original immutable record' jq -e \
        --slurpfile original "$CASE/large-inventory.json" \
        '[.[]|select(.id>=1000 and .id<1500)]==[$original[0][]|select(.id>=1000 and .id<1500)]' \
        "$CASE/remote/inventory.json"
    before=$(wc -l < "$CASE/signs")
    FI_SECRET=/missing
    capture signed --promote
    check 'large published release retries without a private key' test "$status" -eq 0
    check 'large published retry neither uploads nor promotes again' bash -c \
        '[[ $(wc -l < "$1/uploads") == 7 && $(wc -l < "$1/promotions") == 1 ]]' _ "$CASE"
    check 'large published retry preserves the original signature set' test "$(wc -l < "$CASE/signs")" -eq "$before"

    inventory=$(cat "$CASE/remote/inventory.json") || return 1
    _RF_INTEGRITY_ASSETS=$inventory
    capture _rf_integrity_assets_gate "$inventory"
    check 'integrity gate accepts large observed and retained inventories' test "$status" -eq 0
    changed=$(jq -c 'map(if .id==1000 then .size+=1 else . end)' <<< "$inventory") || return 1
    capture _rf_integrity_assets_gate "$changed"
    check 'large inventory still refuses retained metadata drift' test "$status" -eq 7
    capture _rf_integrity_assets_gate "$inventory"$'\n[]'
    check 'integrity observation refuses trailing JSON documents' test "$status" -eq 7
    _RF_INTEGRITY_ASSETS+=$'\n[]'
    capture _rf_integrity_assets_gate "$inventory"
    check 'integrity retention refuses trailing JSON documents' test "$status" -eq 7

    # Exercise the provenance identity gate with two actual uploaded proof
    # records; provenance signing/verification is qualified in its own suite.
    _RF_PROVENANCE_KEY=$(jq -c '
        def record($name): first(.[]|select(.name==$name))|{name,asset_id:.id,sha256:(.digest|ltrimstr("sha256:"))};
        {statement:record("release-integrity.json"),signature:record("release-integrity.json.minisig")}' \
        <<< "$inventory") || return 1
    _RF_PROVENANCE_DOCUMENTS=$(jq -c '
        def record($name): first(.[]|select(.name==$name))|{name,size};
        {statement:record("release-integrity.json"),signature:record("release-integrity.json.minisig")}' \
        <<< "$inventory") || return 1
    capture _rf_provenance_assets_gate "$inventory"
    check 'provenance gate finds both exact proof identities in a large inventory' test "$status" -eq 0
    local mutation
    for mutation in '.id+=1' '.size+=1' '.state="new"' '.digest=("sha256:"+("0"*64))'; do
        changed=$(jq -c "map(if .name==\"release-integrity.json\" then $mutation else . end)" <<< "$inventory") || return 1
        capture _rf_provenance_assets_gate "$changed"
        check "large provenance inventory refuses proof mutation $mutation" test "$status" -eq 7
    done
    capture _rf_provenance_assets_gate "$inventory"$'\n[]'
    check 'provenance observation refuses trailing JSON documents' test "$status" -eq 7
}

fi_completion_cases() {
new_fi_case complete
capture signed --upload-payloads
# status is assigned by capture() in the sourced integrity harness.
# shellcheck disable=SC2154
check 'one invocation signs before payload upload and finalizes a draft' test "$status" -eq 0
check 'ready draft result distinguishes authenticated bundle from unsigned SBOMs' jq -e '.status=="ready" and .integrity.authenticated and .integrity.release.draft and .verification.status=="verified"' "$CASE/out"
check 'signature preparation precedes first payload uploader call' test "$(head -1 "$CASE/events")" = payload-upload
check 'five signatures cover payload aliases checksum and master' test "$(wc -l < "$CASE/signs")" -eq 5
check 'no promotion occurs without explicit choice' never_promoted
STATE=$(find "$CASE/finalizer" -name state.json -type f | head -1)
check 'signature key and original build selection are frozen in state' jq -e '.integrity_policy.required and .integrity_policy.selection.manifest_sha256==.payload_plan.manifest_sha256 and (.integrity_documents|length)==7' "$STATE"
FI_SECRET=/missing
capture signed --upload-payloads --promote
check 'same draft can be promoted without accessing private key again' test "$status" -eq 0
check 'published receipt authenticates final public release mode' jq -e '.status=="published" and .integrity.authenticated and (.integrity.release.draft|not)' "$CASE/out"
check 'promotion is sent exactly once' test "$(wc -l < "$CASE/promotions")" -eq 1
check 'ready-to-public retry does not re-sign any file' test "$(wc -l < "$CASE/signs")" -eq 5
before=$(wc -l < "$CASE/uploads")
capture signed --upload-payloads --promote
check 'complete signed finalization is safely repeatable' test "$status" -eq 0
check 'complete signed retry sends no new proof uploads' test "$(wc -l < "$CASE/uploads")" -eq "$before"
check 'complete signed retry does not promote again' test "$(wc -l < "$CASE/promotions")" -eq 1
FI_SECRET='' SIGNING_PRIVATE_KEY=/missing capture signed --upload-payloads --promote
check 'omitted secret-key option supports a completed key-free retry' test "$status" -eq 0
check 'omitted private key never triggers re-signing' test "$(wc -l < "$CASE/signs")" -eq 5
FI_PUBLIC="$WORK/wrong-public"
capture signed --upload-payloads --promote
check 'retry cannot replace the chosen trust key' test "$status" -eq 2
check 'key-policy conflict creates no new uploads' test "$(wc -l < "$CASE/uploads")" -eq "$before"
FI_PUBLIC="$WORK/public"
capture unsigned --upload-payloads --build-manifest "$MANIFEST" --promote
check 'retry cannot drop a mandatory signature policy' test "$status" -eq 2

new_fi_case damaged-policy
add_payloads
capture signed
STATE=$(find "$CASE/finalizer" -name state.json -type f | head -1)
cp "$STATE" "$CASE/state.before"
before=$(wc -l < "$CASE/uploads")
for filter in '.integrity_policy=null' 'del(.integrity_policy)' '.integrity_manifest_sha256=null' '.integrity_verification=null'; do
    jq "$filter" "$CASE/state.before" > "$STATE"
    capture unsigned --promote
    check "inconsistent signed state cannot downgrade: $filter" test "$status" -eq 2
    check 'inconsistent signed state cannot publish release' never_promoted
done
check 'damaged signature policy causes no new uploads' test "$(wc -l < "$CASE/uploads")" -eq "$before"

new_fi_case preexisting
add_payloads
capture signed --promote
check 'signed finalization accepts existing payloads without upload flag' test "$status" -eq 0
check 'existing-payload flow never invokes binary uploader' bash -c '! grep -q payload-upload "$1"' bash "$CASE/events"
check 'signed checksums are present before publication' jq -e 'any(.[];.name=="checksums.sha256.minisig")' "$CASE/remote/inventory.json"
}

fi_local_failure_cases() {
new_fi_case bad-signer
export RI_SIGN_FAIL=b.tar.xz RI_SIGN_MODE=empty
capture signed --upload-payloads --promote
check 'signer false success blocks pipeline' nonzero "$status"
check 'signer failure precedes all payload/metadata uploads' test ! -s "$CASE/events"
check 'signer failure cannot publish the release' never_promoted

new_fi_case private-mismatch
FI_SECRET="$WORK/wrong-private"
capture signed --upload-payloads --promote
check 'wrong private key blocks integrated release' nonzero "$status"
check 'wrong key cannot trigger payload upload' test ! -s "$CASE/events"

new_fi_case private-payload
fixture_private_payload
FI_SECRET="$ART/a.tar.gz"
capture signed --upload-payloads --promote
check 'signing key cannot be selected for binary upload' test "$status" -eq 4
check 'private-key payload is rejected before any uploader call' test ! -s "$CASE/events"
check 'private-key payload cannot publish the release' never_promoted

new_fi_case partial-proofs
add_payloads
export RI_UPLOAD_FAIL=b.tar.xz.minisig
capture signed --promote
check 'partial proof upload remains a pipeline failure' nonzero "$status"
check 'partial proof upload never promotes a release' never_promoted
check 'partial proof upload retains already completed asset' jq -e 'any(.[];.name=="a.tar.gz.minisig")' "$CASE/remote/inventory.json"
unset RI_UPLOAD_FAIL
FI_SECRET=/missing
capture signed --promote
check 'partial pipeline resumes with retained local signatures' test "$status" -eq 0
check 'partial retry reuses first uploaded signature' test "$(grep -c '^a.tar.gz.minisig$' "$CASE/uploads")" -eq 1
check 'partial retry uses no private key' test "$(wc -l < "$CASE/signs")" -eq 5
}

fi_remote_drift_cases() {
for mode in local-signature replaced-signature-id sbom-other; do
    new_fi_case "$mode"; add_payloads; FI_MODE="$mode"
    capture signed --promote
    check "$mode before promotion blocks finalization" nonzero "$status"
    check "$mode cannot promote a release" never_promoted
    check "$mode cannot dispatch downstream work" test ! -s "$CASE/dispatches"
    check "$mode stops subsequent SBOM publication" bash -c '! grep -q sbom-publish "$1"' bash "$CASE/events"
done

for mode in remote-after-promote local-after-promote; do
    new_fi_case "$mode"; add_payloads; FI_MODE="$mode"
    capture signed --promote --tool tool --dispatch-repos owner/a,owner/b --dispatch-state-dir "$CASE/outbox"
    check "$mode prevents false completion" nonzero "$status"
    check "$mode leaves already published release intact rather than rolling back" jq -e '.release.draft==false' "$CASE/context.json"
    check "$mode blocks downstream events" test ! -s "$CASE/dispatches"
done
}

fi_dispatch_and_policy_cases() {
local -a pids=()
local i pid succeeded
new_fi_case dispatch
add_payloads
capture signed --promote --tool tool --dispatch-repos owner/a,owner/b --dispatch-state-dir "$CASE/outbox"
check 'authenticated finalization can complete guarded handoff' test "$status" -eq 0
check 'complete result contains separate signature verification evidence' jq -e '.status=="complete" and .integrity.authenticated' "$CASE/out"
check 'downstream payload carries signed manifest and chosen key' jq -e '.payload.release_evidence.integrity | .manifest.name=="release-integrity.json" and (.public_key|length)>40 and .verification_policy=="minisign-all-payloads-and-checksums"' "$CASE/dispatch-plan.json"
check 'both guarded downstream requests were reached' test "$(wc -l < "$CASE/dispatches")" -eq 2

new_fi_case between-dispatches
add_payloads; FI_MODE=between-dispatches
capture signed --promote --tool tool --dispatch-repos owner/a,owner/b --dispatch-state-dir "$CASE/outbox"
check 'signature identity change between recipients returns failure' nonzero "$status"
check 'signature identity change stops the second downstream request' test "$(wc -l < "$CASE/dispatches")" -eq 1
check 'partial handoff result retains authenticated release evidence' jq -e '.status=="incomplete" and .integrity.authenticated and .dispatch.exit_code!=0' "$CASE/out"

new_fi_case malformed-receipt
add_payloads
release_publish_integrity() { printf '%s\n' '{"authenticated":true,"status":"verified"}'; }
capture signed --promote
check 'an authenticated boolean alone is not accepted as a verification receipt' nonzero "$status"
check 'malformed signature receipt cannot promote release' never_promoted
release_publish_integrity() { _ri_execute publish "$@"; }

new_fi_case manifest-race
FI_MODE='manifest-before-snapshot'
capture signed --upload-payloads --promote
check 'changed valid build manifest after planning is rejected' test "$status" -eq 2
check 'changed plan causes no signatures' test ! -s "$CASE/signs"
check 'changed plan causes no uploads' test ! -s "$CASE/events"

new_fi_case post-upload-manifest
FI_MODE='manifest-after-payloads'
capture signed --upload-payloads --promote
check 'manifest mutation after payload upload blocks the next stage' test "$status" -eq 2
check 'post-upload manifest mutation prevents signature metadata uploads' test ! -s "$CASE/uploads"
check 'post-upload manifest mutation cannot promote release' never_promoted

new_fi_case frozen-key
add_payloads; FI_PUBLIC="$CASE/pinned.pub"; cp "$WORK/public" "$FI_PUBLIC"; FI_MODE=key-after-plan
capture signed --promote
check 'mid-run key-file mutation cannot change the frozen verifier token' test "$status" -eq 0
check 'receipt retains the initially selected key' jq -e --arg key "$(signing_public_key_token "$WORK/public")" '.integrity.public_key==$key' "$CASE/out"
FI_MODE=''
capture signed --promote
check 'next invocation sees changed key and rejects policy switch' test "$status" -eq 2

new_fi_case dry
FI_SECRET=/missing
capture signed --upload-payloads --promote --dry-run
check 'integrated dry-run is a plan rather than authentication' jq -e '.status=="planned" and .require_signatures and .dry_run and .integrity==null' "$CASE/out"
check 'dry-run causes no remote reads' test ! -s "$CASE/reads"
check 'dry-run does not create finalization state' test ! -e "$CASE/finalizer"
check 'dry-run does not access signing key' test ! -s "$CASE/signs"
check 'dry-run does not publish proof files' no_public_proofs

new_fi_case validation
capture unsigned --require-signatures
check 'signature policy requires a build manifest and trust key' test "$status" -eq 4
capture unsigned --public-key "$WORK/public"
check 'unselected signing options are rejected not ignored' test "$status" -eq 4
capture unsigned --require-signatures --build-manifest "$MANIFEST"
check 'required signature policy never silently chooses a public key' test "$status" -eq 4
capture unsigned --require-signatures --build-manifest "$MANIFEST" --public-key
check 'missing signing option value is structured invalid arguments' test "$status" -eq 4

new_fi_case unsigned
FI_REQUIRE=false; add_payloads
capture unsigned --promote
check 'existing explicitly unsigned finalization path remains functional' test "$status" -eq 0
check 'unsigned path never claims signature authentication' jq -e '.status=="published" and .integrity==null' "$CASE/out"
check 'unsigned path performs no signing' test ! -s "$CASE/signs"

new_fi_case concurrent
add_payloads
pids=()
for i in 1 2 3 4; do
    signed --promote > "$CASE/worker-$i.out" 2> "$CASE/worker-$i.err" & pids+=("$!")
done
succeeded=0
for pid in "${pids[@]}"; do if wait "$pid"; then succeeded=$((succeeded+1)); fi; done
check 'one competing signed finalizer completes' test "$succeeded" -ge 1
check 'competing finalizers publish one signature set' test "$(wc -l < "$CASE/signs")" -eq 5
check 'competing finalizers promote once' test "$(wc -l < "$CASE/promotions")" -eq 1
check 'competing finalizers do not duplicate proof uploads' test "$(wc -l < "$CASE/uploads")" -eq 7
}

if [[ "${1:-}" == --large-inventory-only ]]; then
    fi_large_inventory_cases || exit 1
    printf '\nLarge signed finalization checks: %d; failures: %d\n' "$checks" "$failures"
    [[ "$failures" -eq 0 ]]
    exit
fi

check 'group runner accepts a completed positive assertion' fi_expect_group_status 0 fi_worker_pass
check 'group runner retains failed assertions' fi_expect_group_status 1 fi_worker_failure
check 'group runner rejects an early worker exit with missing counts' fi_expect_group_status 1 fi_worker_abort
check 'group runner rejects a failing process despite positive assertions' fi_expect_group_status 1 fi_worker_nonzero
check 'group runner rejects a worker with no assertions' fi_expect_group_status 1 fi_worker_empty
check 'group runner rejects empty discovery' fi_expect_group_status 1
check 'group runner reaps later workers after invalid counts' fi_expect_all_reaped
dsr_test_groups fi_completion_cases fi_local_failure_cases fi_remote_drift_cases fi_dispatch_and_policy_cases fi_large_inventory_cases || exit 1

printf '\nSigned finalization checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
