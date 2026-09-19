#!/usr/bin/env bash
# Real preparation + finalizer state machines with file-backed API, upload,
# SBOM and dispatch boundaries. No live GitHub, Syft or cryptography claim.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DSR_PREPARE_FIXTURES_ONLY=true source "$HERE/test_release_prepare.sh"
# shellcheck source=src/release_finalize.sh
source "${FINALIZER_TEST_MODULE:-$ROOT/src/release_finalize.sh}"

_rup_require() { :; }
_rup_check_files() {
    local selection="$3" name hash
    [[ "$(_rf_hash "$2")" == "$(jq -r .manifest_sha256 <<< "$selection")" ]] || return 2
    name=$(jq -r '.artifacts[0].name' <<< "$selection") || return 1
    hash=$(jq -r '.artifacts[0].sha256' <<< "$selection") || return 1
    [[ "$(_rf_hash "$1/$name")" == "$hash" ]] || return 7
}
_rup_preflight() {
    jq -ne --argjson current "$2" --argjson pinned "$4" \
        'all($pinned[]; . as $p|[$current[]|select(.name==$p.name)]==[$p])' >/dev/null
}
# Minimal producer manifests are fixture inputs; the production payload module's
# complete build-profile validator has separate upstream tests.
fixture_selection() {
    local manifest="$1" hash
    hash=$(_rf_hash "$manifest") || return 4
    jq -ceS --arg hash "$hash" --arg sha "$SHA" '
        select(.status=="success" and .source_sha==$sha and (.artifacts|length)==1)|
        {tool,source_sha,tag:.version,artifacts,manifest_sha256:$hash}' "$manifest" || return 4
}
release_upload_payloads() {
    local root="$1" manifest='' dry=false selection asset context arg
    shift
    while (($#)); do
        arg="$1"; shift
        case "$arg" in
            --build-manifest) manifest="$1"; shift ;;
            --repo|--tag|--sha|--state-dir) shift ;;
            --dry-run) dry=true ;;
            *) return 4 ;;
        esac
    done
    selection=$(fixture_selection "$manifest") || return $?
    _rup_check_files "$root" "$manifest" "$selection" || return $?
    if [[ "$dry" == true ]]; then
        jq -nc --argjson selection "$selection" '{kind:"dsr-release-payload-publication",status:"planned",dry_run:true,plan:$selection}'
        return
    fi
    printf 'PAYLOAD\n' >> "$CASE/calls"
    [[ ! -e "$CASE/payload-fail" ]] || return 6
    if [[ ! -e "$CASE/remote/tool.tar.gz" ]]; then
        cp "$root/tool.tar.gz" "$CASE/remote/tool.tar.gz" || return 1
        printf 'UPLOAD\n' >> "$CASE/calls"
    fi
    [[ "$(_rf_hash "$CASE/remote/tool.tar.gz")" == "$(jq -r '.artifacts[0].sha256' <<< "$selection")" ]] || return 7
    asset=$(jq -c '.artifacts[0]|{id:101,name,size,state:"uploaded",digest:("sha256:"+.sha256)}' <<< "$selection") || return 1
    fixture_inventory_add "$asset" || return $?
    context=$(_sbr_context acme/tool v1.2.3 "$CASE") || return $?
    jq -nc --argjson ctx "$context" --argjson selection "$selection" --argjson asset "$asset" \
        '$ctx+{kind:"dsr-release-payload-publication",status:"verified",dry_run:false,
            tool:$selection.tool,manifest_sha256:$selection.manifest_sha256,assets:[$asset]}'
}
fixture_inventory_add() {
    local tmp
    tmp=$(mktemp "$CASE/inventory.XXXXXXXX") || return 1
    jq -cS --argjson asset "$1" 'map(select(.name!=$asset.name))+[$asset]|sort_by(.name)' "$CASE/inventory" > "$tmp" || return 1
    mv "$tmp" "$CASE/inventory"
}
_sbr_context() {
    local plan source id
    [[ -e "$CASE/release" ]] || return 7
    plan=$(jq -c --arg sha "$SHA" '{repo:"acme/tool",request:{tag_name:"v1.2.3",target_commitish:$sha,
        name,body:(.body//""),prerelease}}' "$CASE/release") || return 1
    source=$(_rp_source "$plan") || return $?
    id=$(_rp_find acme/tool v1.2.3) || return $?
    [[ "$id" != null ]] || return 7
    _rp_context "$plan" "$source" "$id"
}
_sbr_inventory() { cat "$CASE/inventory"; }
_sbr_inventory_sha256() { jq -cS 'sort_by(.name)' <<< "$1" | _rf_digest; }
fixture_local_verify() {
    local root="$1" out="$2" ext="$3" entry rows name hash
    rows=$(jq -c '.artifacts[]' "$out/sbom-manifest.$ext.json") || return 7
    while IFS= read -r entry; do
        name=$(jq -r .artifact.name <<< "$entry"); hash=$(jq -r .artifact.sha256 <<< "$entry")
        [[ "$(_rf_hash "$root/$name")" == "$hash" ]] || return 7
        name=$(jq -r .sbom.name <<< "$entry"); hash=$(jq -r .sbom.sha256 <<< "$entry")
        [[ "$(_rf_hash "$out/$name")" == "$hash" ]] || return 7
    done <<< "$rows"
}
sbom_generate_artifacts() {
    local root="$1" format="$3" out="$5" ext=spdx sha doc
    [[ "$format" != cyclonedx ]] || ext=cdx
    [[ ! -e "$CASE/scan-fail" ]] || return 6
    if [[ ! -e "$out/sbom-manifest.$ext.json" ]]; then
        printf 'SCAN\n' >> "$CASE/calls"
        printf '{"fixture":"%s"}\n' "$format" > "$out/tool.tar.gz.sbom.$ext.json"
        sha=$(_rf_hash "$root/tool.tar.gz"); doc=$(_rf_hash "$out/tool.tar.gz.sbom.$ext.json")
        jq -nc --arg sha "$sha" --arg doc "$doc" --arg ext "$ext" --arg format "$format" \
            '{schema_version:1,kind:"dsr-sbom-release",status:"complete",format:$format,
                artifacts:[{artifact:{name:"tool.tar.gz",sha256:$sha},
                    sbom:{name:("tool.tar.gz.sbom."+$ext+".json"),sha256:$doc}}]}' > "$out/sbom-manifest.$ext.json"
    fi
    fixture_local_verify "$root" "$out" "$ext" || return $?
    [[ ! -e "$CASE/source-drift-scan" ]] || printf '%s\n' "$OTHER" > "$CASE/sha"
}
sbom_verify_artifacts() {
    local ext=spdx
    [[ "$3" != cyclonedx ]] || ext=cdx
    fixture_local_verify "$1" "$5" "$ext"
}
sbom_publish_artifacts() {
    local format="$7" out="$9" ext=spdx name i=102 asset
    [[ "$format" != cyclonedx ]] || ext=cdx
    [[ ! -e "$CASE/sbom-fail" ]] || return 7
    for name in "tool.tar.gz.sbom.$ext.json" "sbom-manifest.$ext.json"; do
        if [[ ! -e "$CASE/remote/$name" ]]; then
            cp "$out/$name" "$CASE/remote/$name" || return 1
            printf 'SBOM_UPLOAD\n' >> "$CASE/calls"
        fi
        [[ "$(_rf_hash "$out/$name")" == "$(_rf_hash "$CASE/remote/$name")" ]] || return 7
        asset=$(jq -nc --arg name "$name" --arg hash "$(_rf_hash "$out/$name")" \
            --argjson size "$(wc -c < "$out/$name")" --argjson id "$i" \
            '{id:$id,name:$name,state:"uploaded",size:$size,digest:("sha256:"+$hash)}') || return 1
        fixture_inventory_add "$asset" || return $?
        i=$((i+1))
    done
    printf '{"kind":"dsr-sbom-publication","status":"verified","dry_run":false}\n'
}
sbom_verify_release() {
    local format="$6" pin="$8" ext=spdx ctx inv
    [[ "$format" != cyclonedx ]] || ext=cdx
    [[ ! -e "$CASE/verify-fail" ]] || return 7
    [[ "$(_rf_hash "$CASE/remote/sbom-manifest.$ext.json")" == "$pin" ]] || return 7
    fixture_local_verify "$CASE/remote" "$CASE/remote" "$ext" || return $?
    ctx=$(_sbr_context acme/tool v1.2.3 "$CASE") || return $?
    inv=$(_sbr_inventory_sha256 "$(cat "$CASE/inventory")" "$CASE") || return $?
    jq -nc --argjson ctx "$ctx" --arg format "$format" --arg ext "$ext" --arg pin "$pin" --arg inv "$inv" \
        '$ctx+{schema_version:1,kind:"dsr-sbom-remote-verification",status:"verified",format:$format,
            manifest:{name:("sbom-manifest."+$ext+".json"),sha256:$pin,asset_id:103},artifact_count:1,
            asset_inventory_sha256:$inv,verification_policy:"expected-manifest-sha256"}'
}
# Deliberately failing signature fixtures test ordering, NOT cryptographic validity.
_ri_require() { :; }
release_publish_integrity() { return 99; }
signing_public_key_token() { [[ -f "$1" ]] || return 4; printf '%044d\n' 0; }
_ri_verify_set() { printf 'SIGNATURE_CHECK\n' >> "$CASE/calls"; return 7; }
release_prepare_integrity() {
    if [[ "${*: -1}" == --dry-run ]]; then
        jq -nc --arg key "$(signing_public_key_token "$CASE/public.key")" --argjson selection "$(fixture_selection "$CASE/build.json")" \
            '{kind:"dsr-release-integrity-plan",status:"planned",dry_run:true,public_key:$key,selection:$selection}'
    else printf 'SIGN\n' >> "$CASE/calls"; return 7; fi
}
# The actual finalizer guard runs at the handoff boundary; delivery is a fixture.
_dp_config() { :; }
_dp_repos() { printf '%s\n' "$1" | tr ',' '\n'; }
_dp_digest_text() { printf '%s\n' "$1" | _rf_digest; }
_dp_state_hash() { printf 'absent\n'; }
_dp_release_plan() { jq -nc --arg repo "$1" --argjson payload "$3" '{source_repo:$repo,payload:$payload}'; }
dispatch_check_auth() { :; }
_dp_release_outbox() {
    "$5" || return $?
    printf 'DISPATCH %s\n' "$3" >> "$CASE/calls"
    printf '%s\n' "$1" > "$CASE/dispatch.json"
    printf '{"status":"accepted","exit_code":0,"results":[]}\n'
}

new_pipeline() {
    new_case
    mkdir "$CASE/artifacts" "$CASE/meta" "$CASE/remote"
    printf 'real payload bytes\n' > "$CASE/artifacts/tool.tar.gz"
    printf '[]\n' > "$CASE/inventory"
    printf 'fixture public key\n' > "$CASE/public.key"
    jq -nc --arg sha "$SHA" --arg hash "$(_rf_hash "$CASE/artifacts/tool.tar.gz")" \
        --argjson size "$(wc -c < "$CASE/artifacts/tool.tar.gz")" \
        '{status:"success",tool:"tool",version:"v1.2.3",source_sha:$sha,
            artifacts:[{name:"tool.tar.gz",sha256:$hash,size:$size}]}' > "$CASE/build.json"
}
pipeline() {
    RC=0
    OUT=$(release_finalize "$CASE/artifacts" --repo acme/tool --tag v1.2.3 --sha "$SHA" \
        --state-dir "$CASE/finalize" --output-dir "$CASE/meta" "$@" 2> "$CASE/diagnostics") || RC=$?
}
create_pipeline() { pipeline --create-draft --upload-payloads --build-manifest "$CASE/build.json" "$@"; }
count() { [[ $(grep -c "^$1$" "$CASE/calls" || true) -eq "$2" ]]; }
no_reads() { [[ $(grep -c '^GET ' "$CASE/calls" || true) -eq 0 ]]; }
final_state() { find "$CASE/finalize" -maxdepth 2 -type f -name state.json; }

[[ "${DSR_PREPARE_FINALIZE_FIXTURES_ONLY:-false}" != true ]] || return 0

new_pipeline
create_pipeline --dry-run
check assert_rc 0
check json '.[0].dry_run and .[0].preparation_plan.request.draft and (.[0].stages|index("create or reconcile source-pinned draft"))!=null'
check posts 0
check test ! -e "$CASE/finalize"
check no_reads
create_pipeline
check assert_rc 0
check json '.[0].status=="ready" and .[0].preparation.context.release.id==.[0].verification.release.id and .[0].verification.release.draft'
check posts 1
check count UPLOAD 1
check count PATCH 0
create_pipeline --promote
check assert_rc 0
check json '.[0].status=="published" and (.[0].verification.release.draft|not)'
check posts 1
check count UPLOAD 1
check count PATCH 1
create_pipeline --promote
check assert_rc 0
check posts 1
check count PATCH 1
check count SBOM_UPLOAD 2
check count SCAN 1
pipeline --upload-payloads --build-manifest "$CASE/build.json" --promote
check assert_rc 2
check posts 1
check count PATCH 1

new_pipeline
pipeline --upload-payloads --build-manifest "$CASE/build.json"
check assert_rc 7
check posts 0
# Preserve the original existing-release path, including public read-only retry.
new_pipeline; run
pipeline --upload-payloads --build-manifest "$CASE/build.json" --promote
check assert_rc 0
check json '.[0].preparation==null and .[0].status=="published"'
pipeline --upload-payloads --build-manifest "$CASE/build.json" --promote
check assert_rc 0
check posts 1
check count PATCH 1
for option in '--release-name title' '--prerelease' '--retry-creation'; do
    new_pipeline
    read -r -a args <<< "$option"
    pipeline "${args[@]}"
    check assert_rc 4
    check posts 0
done
new_pipeline
pipeline --create-draft
check assert_rc 4
check posts 0
new_pipeline
printf '{}\n' > "$CASE/build.json"
create_pipeline
check assert_rc 4
check posts 0
new_pipeline
touch "$CASE/lost-ack"
create_pipeline --promote
check assert_rc 0
check posts 1
check count PATCH 1
new_pipeline
touch "$CASE/post-fail"
create_pipeline
check assert_rc 8
check posts 1
create_pipeline
check assert_rc 2
check posts 1
mv "$CASE/post-fail" "$CASE/post-fail.disabled"
create_pipeline --retry-creation
check assert_rc 0
check posts 2
check count UPLOAD 1

new_pipeline
touch "$CASE/scan-fail"
create_pipeline --promote
check assert_rc 6
check posts 1
check count UPLOAD 1
check count PATCH 0
mv "$CASE/scan-fail" "$CASE/scan-fail.disabled"
create_pipeline --promote
check assert_rc 0
check posts 1
check count UPLOAD 1
check count PATCH 1
new_pipeline
touch "$CASE/patch-lost"
create_pipeline --promote
check assert_rc 0
check count PATCH 1
create_pipeline --promote
check assert_rc 0
check count PATCH 1
new_pipeline
touch "$CASE/verify-fail"
create_pipeline --promote
check assert_rc 7
check count PATCH 0

new_pipeline
printf 'Quoted "notes"\n\n' > "$CASE/notes"
create_pipeline --release-name 'Release title' --release-notes-file "$CASE/notes" --prerelease
check assert_rc 0
check jq -e '.name=="Release title" and .body=="Quoted \"notes\"\n\n" and .prerelease and .draft' "$CASE/release"
create_pipeline --release-name 'Different title' --release-notes-file "$CASE/notes" --prerelease
check assert_rc 2
check posts 1
check count UPLOAD 1

# Planning captures the exact note bytes; later filesystem changes cannot alter
# the request between preflight and the preparation engine's own state binding.
new_pipeline
printf 'original notes\n' > "$CASE/notes"
auth_definition=$(declare -f _sbr_require)
_sbr_require() { printf 'changed notes\n' > "$CASE/notes"; }
create_pipeline --release-notes-file "$CASE/notes"
check assert_rc 0
check jq -e '.body=="original notes\n"' "$CASE/release"
check posts 1
eval "$auth_definition"
create_pipeline --release-notes-file "$CASE/notes"
check assert_rc 2
check posts 1

# No tag/repository drift can be accepted as a fresh creation request.
new_pipeline; create_pipeline
printf '%s\n' "$OTHER" > "$CASE/sha"
create_pipeline
check assert_rc 7
check posts 1
new_pipeline; create_pipeline
mv "$CASE/release" "$CASE/deleted-release"
# Even losing the nested preparation state cannot authorize a replacement.
mv "$CASE/finalize/$(basename "$(dirname "$(final_state)")")/preparation" "$CASE/old-preparation"
create_pipeline --retry-creation
check assert_rc 2
check posts 1
new_pipeline; create_pipeline
mutate "$(final_state)" '.preparation_plan=false'
create_pipeline
check assert_rc 2
check posts 1

# Invalid explicit state paths fail before a release can be created.
new_pipeline
mkdir "$CASE/real-finalize"; ln -s "$CASE/real-finalize" "$CASE/finalize"
create_pipeline
check assert_rc 4
check posts 0

# Prepared-only authentication must fail before draft creation, even in dry-run.
new_pipeline
create_pipeline --prepared-signatures --public-key "$CASE/public.key" --integrity-dir "$CASE/meta"
check assert_rc 7
check count SIGNATURE_CHECK 1
check posts 0
check test ! -e "$CASE/finalize"
create_pipeline --prepared-signatures --public-key "$CASE/public.key" --integrity-dir "$CASE/meta" --dry-run
check assert_rc 7
check posts 0
new_pipeline
create_pipeline --require-signatures --public-key "$CASE/public.key" --integrity-dir "$CASE/meta"
check assert_rc 7
check count SIGN 1
check posts 1
check count UPLOAD 0
check count PATCH 0
# An actual signing failure leaves only a draft, not a published unsigned release.
check jq -e .draft "$CASE/release"

# Release identity is rechecked before the payload boundary, not only afterward.
new_pipeline
save_definition=$(declare -f _rf_save)
_rf_save() {
    local file="$1" state="$2" result
    # Use the unchanged production implementation, then inject an outside tag move.
    result=$(_fixture_save "$@") || return $?
    if [[ -e "$CASE/drift-before-payload" ]] && jq -e '.payload_plan!=null' <<< "$state" >/dev/null; then
        printf '%s\n' "$OTHER" > "$CASE/sha"
    fi
    printf '%s\n' "$result"
}
# Function cloning is test setup, not a source-code transformation.
eval "${save_definition/_rf_save ()/_fixture_save ()}"
touch "$CASE/drift-before-payload"
create_pipeline
check assert_rc 7
check posts 1
check count PAYLOAD 0
eval "$save_definition"

new_pipeline
create_pipeline --tool tool --dispatch-repos acme/checksums
check assert_rc 4
check posts 0
new_pipeline
create_pipeline --promote --tool tool --dispatch-repos acme/checksums --retry-creation
check assert_rc 0
check json '.[0].status=="complete" and .[0].dispatch.status=="accepted"'
check count 'DISPATCH false' 1
check jq -e '.payload.release_evidence.release_id==42' "$CASE/dispatch.json"

# Four whole pipelines race on real flock locks: one draft and one promotion.
new_pipeline; touch "$CASE/post-slow"
pids=()
for n in 1 2 3 4; do
    (release_finalize "$CASE/artifacts" --repo acme/tool --tag v1.2.3 --sha "$SHA" \
        --state-dir "$CASE/finalize" --output-dir "$CASE/meta" --create-draft --upload-payloads \
        --build-manifest "$CASE/build.json" --promote > "$CASE/out.$n" 2> "$CASE/err.$n"; \
        printf '%s\n' "$?" > "$CASE/rc.$n") &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
check posts 1
check count UPLOAD 1
check count PATCH 1
for n in 1 2 3 4; do
    check jq -es 'length==1 and (.[0].exit_code==0 or .[0].exit_code==2)' "$CASE/out.$n"
done
create_pipeline --promote
check assert_rc 0
check posts 1
check count PATCH 1
printf '%s checks: %s passed, %s failed. Fixtures retained at %s\n' "$TOTAL" "$PASSED" "$FAILED" "$TMP"
((FAILED==0))
