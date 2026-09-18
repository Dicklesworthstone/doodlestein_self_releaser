#!/usr/bin/env bash
# Verified release finalization: local inventory -> remote evidence -> promotion.
# This composes the existing SBOM APIs; it does not build or upload payloads.
# A verified SBOM inventory is byte-integrity evidence, not a signed build claim.

_RELEASE_FINALIZE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_rf_log() { printf '[release-finalize] %s\n' "$*" >&2; }

_rf_require() {
    if ! declare -F sbom_publish_artifacts >/dev/null || ! declare -F sbom_verify_release >/dev/null; then
        # shellcheck source=src/sbom_release.sh
        source "$_RELEASE_FINALIZE_DIR/sbom_release.sh" || return 3
    fi
    _sbr_require
}

_rf_digest() (
    set -o pipefail
    local hash
    if command -v sha256sum >/dev/null; then
        hash=$(sha256sum) || return 1
    elif command -v shasum >/dev/null; then
        hash=$(shasum -a 256) || return 1
    else
        _rf_log 'sha256sum or shasum is required'; return 3
    fi
    hash="${hash%% *}"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$hash"
)

_rf_hash() {
    [[ -f "$1" && ! -L "$1" ]] || return 4
    _rf_digest < "$1"
}

_rf_file_state() {
    [[ ! -L "$1" ]] || return 2
    if [[ -e "$1" ]]; then _rf_hash "$1"; else printf '%s\n' absent; fi
}

# Retain every release identity field except draft, the ONLY permitted mutation.
_rf_context_key() {
    jq -ecsS --arg repo "$2" --arg tag "$3" --arg sha "$4" '
        def id: type=="number" and .>0 and .<=9007199254740991 and .==floor;
        def text: type=="string" and length>0 and (test("[\\x00-\\x1f\\x7f]")|not);
        if length==1 and (.[0] |
            (.repository|type=="object" and (.id|id) and (.node_id|text) and .full_name==$repo) and
            (.release|type=="object" and (.id|id) and (.node_id|text) and .tag_name==$tag and
                (.draft|type=="boolean") and (.prerelease|type=="boolean") and (.target_commitish|text) and
                .upload_url==("https://uploads.github.com/repos/"+$repo+"/releases/"+(.id|tostring)+"/assets{?name,label}")) and
            .tag_commit==$sha)
        then .[0] | {repository,release:(.release|del(.draft)),tag_commit}
        else error("release identity or source pin mismatch") end
    ' <<< "$1" 2>/dev/null
}

_rf_evidence_key() {
    local key
    key=$(_rf_context_key "$1" "$2" "$3" "$4") || return 7
    jq -ecsS --argjson context "$key" --arg format "$5" --arg sha "$6" --arg name "$7" '
        def digest: type=="string" and test("^[0-9a-f]{64}$");
        if length==1 and (.[0] |
            .schema_version==1 and .kind=="dsr-sbom-remote-verification" and .status=="verified" and
            .format==$format and .verification_policy=="expected-manifest-sha256" and
            (.manifest|type=="object" and .name==$name and .sha256==$sha and
                (.asset_id|type=="number" and .>0 and .<=9007199254740991 and .==floor)) and
            (.artifact_count|type=="number" and .>0 and .==floor) and (.asset_inventory_sha256|digest))
        then .[0] | $context+{format,manifest,artifact_count,asset_inventory_sha256,verification_policy}
        else error("missing or mismatched verification evidence") end
    ' <<< "$1" 2>/dev/null
}

_rf_state_valid() {
    jq -es --argjson plan "$2" '
        def digest: type=="string" and test("^[0-9a-f]{64}$");
        length==1 and (.[0] | type=="object" and .schema_version==1 and
            .kind=="dsr-release-finalization" and .plan==$plan and
            (.manifest_sha256==null or (.manifest_sha256|digest)) and
            (.verification==null or (.verification|type=="object" and .status=="verified")) and
            (.promotion_attempts|type=="number" and .>=0 and .==floor) and
            (.phase=="preparing" or .phase=="evidence_ready" or .phase=="promoting" or .phase=="published") and
            (if .phase=="preparing" then .verification==null
             else .manifest_sha256!=null and .verification!=null and
                  .verification.manifest.sha256==.manifest_sha256 end))
    ' "$1" >/dev/null 2>&1
}

# Same-filesystem publication under the finalizer lock. Hash checks catch observed
# outside edits. State is trusted local storage, not a power-loss transaction.
_rf_save() {
    local file="$1" state="$2" expected="$3" work="$4" plan="$5" staged actual
    staged=$(mktemp "$work/state.XXXXXXXX") || return 1
    printf '%s\n' "$state" > "$staged" || return 1
    _rf_state_valid "$staged" "$plan" || return 2
    actual=$(_rf_file_state "$file") || return $?
    [[ "$actual" == "$expected" ]] || { _rf_log 'Finalization state changed'; return 2; }
    if [[ "$expected" == absent ]]; then
        ln -- "$staged" "$file" 2>/dev/null || return 2
    elif ! cmp -s "$staged" "$file"; then
        mv -f -- "$staged" "$file" || return 1
    fi
    _rf_hash "$file"
}

# Recheck the exact observed asset IDs, tag and mode immediately before an effect.
_rf_gate() {
    local repo="$1" tag="$2" sha="$3" evidence="$4" draft="$5" manifest="$6" work="$7"
    local context key inventory fingerprint
    [[ "$(_rf_hash "$manifest")" == "$(jq -r '.manifest.sha256' <<< "$evidence")" ]] || return 7
    context=$(_sbr_context "$repo" "$tag" "$work") || return $?
    key=$(_rf_context_key "$context" "$repo" "$tag" "$sha") || return 7
    [[ "$key" == "$(jq -cS '{repository,release,tag_commit}' <<< "$evidence")" &&
       "$(jq -r '.release.draft' <<< "$context")" == "$draft" ]] || {
        _rf_log 'Release identity, commit or mode changed before finalization'; return 7;
    }
    inventory=$(_sbr_inventory "$repo" "$(jq -r '.release.id' <<< "$context")" "$work") || return $?
    fingerprint=$(_sbr_inventory_sha256 "$inventory" "$work") || return $?
    [[ "$fingerprint" == "$(jq -r '.asset_inventory_sha256' <<< "$evidence")" ]] || {
        _rf_log 'Release assets changed after verification'; return 7;
    }
}

_rf_promote() {
    local repo="$1" id="$2" work="$3"
    # Do not change tags, title, notes, prerelease mode or latest-release policy.
    printf '%s\n' '{"draft":false,"make_latest":"false"}' > "$work/promote.json" || return 1
    _sbr_run gh api --hostname github.com --method PATCH "repos/$repo/releases/$id" \
        --input "$work/promote.json" > "$work/promote.response" 2> "$work/promote.error"
}

_rf_dispatch_require() {
    if ! declare -F _dp_release_plan >/dev/null || ! declare -F _dp_release_outbox >/dev/null; then
        # shellcheck source=src/dispatch.sh
        source "$_RELEASE_FINALIZE_DIR/dispatch.sh" || return 3
    fi
    _dp_config
}

# Validate retained handoff state before promotion, without starting any sends.
# The outbox repeats this validation under its own lock when delivery begins.
_rf_dispatch_preflight() {
    local plan="$1" root="$2" identity key file hash
    identity=$(jq -Sc '{source_repo,tool:.payload.tool,version:.payload.version,run_id:.payload.run_id}' <<< "$plan") || return 1
    key=$(_dp_digest_text "$identity") || return $?
    file="$root/$key/state.json"
    [[ ! -L "$root" && ! -L "$root/$key" ]] || return 2
    hash=$(_dp_state_hash "$file") || return $?
    if [[ "$hash" != absent ]]; then
        _dp_state_valid "$file" "$plan" || { _rf_log 'Conflicting or corrupt dispatch outbox'; return 2; }
        [[ "$(_dp_state_hash "$file")" == "$hash" ]] || return 2
    fi
}

# These prefixed locals are scoped by _rf_execute and inherited by the outbox's
# subshell. Its repo/body/work locals must not shadow the frozen source context.
_rf_dispatch_guard() {
    [[ "$(_rf_hash "$_RF_GUARD_STATE")" == "$_RF_GUARD_STATE_HASH" ]] || return 2
    _rf_gate "$_RF_GUARD_REPO" "$_RF_GUARD_TAG" "$_RF_GUARD_SHA" "$_RF_GUARD_EVIDENCE" \
        false "$_RF_GUARD_MANIFEST" "$_RF_GUARD_WORK"
}

_rf_execute() (
    set -uo pipefail
    umask 077
    local root='' repo='' tag='' sha='' format=spdx output_dir='' state_dir=''
    local promote=false dry="${DRY_RUN:-false}"
    local tool='' dispatch_repos='' dispatch_run='' dispatch_root='' retry_uncertain=false
    local selected='' handoff=null dispatch_plan='' dispatch_result=null dispatch_rc=0 payload
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo|--tag|--sha|--format|--output-dir|--state-dir|--tool|--dispatch-repos|--dispatch-run-id|--dispatch-state-dir)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
                case "$1" in
                    --repo) [[ -z "$repo" ]] || return 4; repo="$2" ;;
                    --tag) [[ -z "$tag" ]] || return 4; tag="$2" ;;
                    --sha) [[ -z "$sha" ]] || return 4; sha="$2" ;;
                    --format) format="$2" ;;
                    --output-dir) [[ -z "$output_dir" ]] || return 4; output_dir="$2" ;;
                    --state-dir) [[ -z "$state_dir" ]] || return 4; state_dir="$2" ;;
                    --tool) [[ -z "$tool" ]] || return 4; tool="$2" ;;
                    --dispatch-repos) [[ -z "$dispatch_repos" ]] || return 4; dispatch_repos="$2" ;;
                    --dispatch-run-id) [[ -z "$dispatch_run" ]] || return 4; dispatch_run="$2" ;;
                    --dispatch-state-dir) [[ -z "$dispatch_root" ]] || return 4; dispatch_root="$2" ;;
                esac
                shift 2 ;;
            --promote) promote=true; shift ;;
            --dry-run|-n) dry=true; shift ;;
            --retry-uncertain) retry_uncertain=true; shift ;;
            -*) _rf_log "Unknown option: $1"; return 4 ;;
            *) [[ -z "$root" ]] || return 4; root="$1"; shift ;;
        esac
    done
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ && "${repo#*/}" != . && "${repo#*/}" != .. &&
       "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.+-]+)?$ && "$sha" =~ ^[0-9a-f]{40}$ &&
       -d "$root" && ! -L "$root" && "$root" != *[[:cntrl:]]* && "$root" != *\\* &&
       ( "$dry" == true || "$dry" == false ) ]] || {
        _rf_log 'Expected ARTIFACTS --repo OWNER/REPO --tag vVERSION --sha FULL_COMMIT'; return 4;
    }
    root=$(cd "$root" && pwd -P) || return 4
    [[ -n "$output_dir" ]] || output_dir="$root"
    [[ ! -L "$output_dir" && "$output_dir" != *[[:cntrl:]]* && "$output_dir" != *\\* ]] || return 4
    case "$format" in spdx|spdx-json) format=spdx ;; cyclonedx|cdx|cyclonedx-json) format=cyclonedx ;; *) return 4 ;; esac
    if [[ -n "$dispatch_repos" ]]; then
        [[ "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { _rf_log '--tool is required for downstream delivery'; return 4; }
        [[ -n "$dispatch_run" ]] || dispatch_run="$tool-$tag"
        [[ "$dispatch_run" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}$ ]] || return 4
        _rf_dispatch_require || return $?
        selected=$(_dp_repos "$dispatch_repos") || return $?
        [[ -n "$dispatch_root" ]] || dispatch_root="${DISPATCH_STATE_DIR:-${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/dispatch}"
        [[ ! -L "$dispatch_root" && "$dispatch_root" != *[[:cntrl:]]* && "$dispatch_root" != *\\* ]] || return 4
    elif [[ -n "$tool$dispatch_run$dispatch_root" || "$retry_uncertain" == true ]]; then
        _rf_log 'Dispatch options require --dispatch-repos'; return 4
    fi
    if [[ "$dry" == true ]]; then
        jq -nc --arg repo "$repo" --arg tag "$tag" --arg sha "$sha" --arg format "$format" --argjson promote "$promote" --arg selected "$selected" '
            {kind:"dsr-release-finalization-result",status:"planned",dry_run:true,exit_code:0,
             repo:$repo,tag:$tag,expected_sha:$sha,format:$format,promote:$promote,
             dispatch_repos:(if $selected=="" then [] else ($selected|split("\n")) end),
             stages:["pin release","generate or reuse SBOMs","publish and verify evidence",
                     (if $promote then "promote without changing latest" else "retain release mode" end)]}'
        return $?
    fi
    command -v flock >/dev/null || { _rf_log 'flock is required'; return 3; }
    _rf_require || return $?
    local context context_key initial_draft
    context=$(_sbr_context "$repo" "$tag" "${TMPDIR:-/tmp}") || return $?
    context_key=$(_rf_context_key "$context" "$repo" "$tag" "$sha") || {
        _rf_log 'Remote release does not match the selected source commit'; return 7;
    }
    initial_draft=$(jq -r '.release.draft' <<< "$context") || return 7
    if [[ -n "$selected" ]]; then
        [[ "$initial_draft" == false || "$promote" == true ]] || {
            _rf_log 'Dispatch requires a public release; use --promote for a draft'; return 4;
        }
        command -v curl >/dev/null || return 3
        dispatch_check_auth || return $?
        mkdir -p -- "$dispatch_root" || return 1
        dispatch_root=$(cd "$dispatch_root" && pwd -P) || return 1
        handoff=$(jq -cSn --arg tool "$tool" --arg run "$dispatch_run" --arg root "$dispatch_root" --arg selected "$selected" \
            '{tool:$tool,run_id:$run,outbox_root:$root,repos:($selected|split("\n"))}') || return 1
    fi
    if [[ "$initial_draft" == true && "$promote" == true ]]; then
        command -v gh >/dev/null || { _rf_log 'gh is required for draft promotion'; return 3; }
    fi
    mkdir -p -- "$output_dir" || return 1
    output_dir=$(cd "$output_dir" && pwd -P) || return 4
    [[ -n "$state_dir" ]] || state_dir="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/release-finalize"
    [[ "$state_dir" != *[[:cntrl:]]* && "$state_dir" != *\\* && ! -L "$state_dir" ]] || return 4
    mkdir -p -- "$state_dir" || return 1
    state_dir=$(cd "$state_dir" && pwd -P) || return 1
    local session key plan file state oldhash work cleanup manifest_name manifest pin saved result verification evidence bound=''
    key=$(jq -cSn --arg repo "${repo,,}" --arg tag "$tag" '{repo:$repo,tag:$tag}' | _rf_digest) || return $?
    session="$state_dir/$key"
    [[ ! -L "$session" ]] || return 2
    mkdir -p -- "$session" || return 1
    [[ ! -L "$session/lock" && ( ! -e "$session/lock" || -f "$session/lock" ) ]] || return 2
    exec 8>> "$session/lock" || return 1
    flock -n 8 || { _rf_log 'Release finalization is already active'; return 2; }
    work=$(mktemp -d "$session/.work.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q' "$work"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    file="$session/state.json"
    plan=$(jq -cSn --argjson context "$context_key" --arg root "$root" --arg output "$output_dir" --arg format "$format" \
        '{context:$context,artifacts_dir:$root,output_dir:$output,format:$format}') || return 1
    oldhash=$(_rf_file_state "$file") || return $?
    if [[ "$oldhash" == absent ]]; then
        state=$(jq -cSn --argjson plan "$plan" \
            '{schema_version:1,kind:"dsr-release-finalization",plan:$plan,manifest_sha256:null,
              verification:null,promotion_attempts:0,phase:"preparing"}') || return 1
        oldhash=$(_rf_save "$file" "$state" absent "$work" "$plan") || return $?
    else
        _rf_state_valid "$file" "$plan" || { _rf_log 'Invalid or conflicting finalization plan'; return 2; }
        state=$(cat "$file") || return 1
        [[ "$(_rf_hash "$file")" == "$oldhash" ]] || return 2
    fi
    saved=$(jq -cS '.handoff // null' <<< "$state") || return 1
    [[ "$saved" == null || "$saved" == "$handoff" ]] || {
        _rf_log 'Cannot change or omit the frozen downstream handoff'; return 2;
    }
    if [[ "$handoff" != null && "$saved" == null ]]; then
        state=$(jq -cS --argjson handoff "$handoff" '.handoff=$handoff' <<< "$state") || return 1
        oldhash=$(_rf_save "$file" "$state" "$oldhash" "$work" "$plan") || return $?
    fi
    case "$format" in spdx) manifest_name=sbom-manifest.spdx.json ;; *) manifest_name=sbom-manifest.cdx.json ;; esac
    manifest="$output_dir/$manifest_name"
    # This API reuses verified completed inventories without requiring Syft.
    sbom_generate_artifacts "$root" --format "$format" --output-dir "$output_dir" > "$work/scan.out" || return $?
    pin=$(_rf_hash "$manifest") || return $?
    saved=$(jq -r '.manifest_sha256 // ""' <<< "$state") || return 1
    [[ -z "$saved" || "$saved" == "$pin" ]] || { _rf_log 'Local SBOM inventory changed for this release'; return 2; }
    if [[ "$(jq -r '.verification != null' <<< "$state")" == true ]]; then
        bound=$(_rf_evidence_key "$(jq -c '.verification' <<< "$state")" "$repo" "$tag" "$sha" "$format" "$pin" "$manifest_name") || return 2
        [[ "$(jq -cS '{repository,release,tag_commit}' <<< "$bound")" == "$context_key" ]] || return 2
    fi
    state=$(jq -cS --arg sha "$pin" '.manifest_sha256=$sha' <<< "$state") || return 1
    oldhash=$(_rf_save "$file" "$state" "$oldhash" "$work" "$plan") || return $?
    [[ "$(_sbr_context "$repo" "$tag" "$work")" == "$context" ]] || { _rf_log 'Release changed before SBOM publication'; return 7; }
    result=$(sbom_publish_artifacts "$root" --repo "$repo" --tag "$tag" --format "$format" --output-dir "$output_dir") || return $?
    jq -es 'length==1 and (.[0]|.kind=="dsr-sbom-publication" and .status=="verified" and .dry_run==false)' <<< "$result" >/dev/null || return 7
    verification=$(sbom_verify_release --repo "$repo" --tag "$tag" --format "$format" --manifest-sha256 "$pin") || return $?
    evidence=$(_rf_evidence_key "$verification" "$repo" "$tag" "$sha" "$format" "$pin" "$manifest_name") || return 7
    [[ "$(jq -cS '{repository,release,tag_commit}' <<< "$evidence")" == "$context_key" &&
       ( -z "$bound" || "$bound" == "$evidence" ) &&
       "$(jq -r '.release.draft' <<< "$verification")" == "$initial_draft" ]] || {
        _rf_log 'Verified release differs from the frozen finalization plan'; return 7;
    }
    state=$(jq -cS --argjson verification "$verification" \
        '.verification=$verification | if .phase=="published" then . else .phase="evidence_ready" end' <<< "$state") || return 1
    oldhash=$(_rf_save "$file" "$state" "$oldhash" "$work" "$plan") || return $?
    if [[ -n "$selected" ]]; then
        payload=$(jq -nc --arg tool "$tool" --arg tag "$tag" --arg sha "$sha" --arg run "$dispatch_run" --argjson evidence "$evidence" '
            {tool:$tool,version:$tag,sha:$sha,run_id:$run,
             release_evidence:($evidence|{repository_id:.repository.id,release_id:.release.id,
                 format,manifest,artifact_count,asset_inventory_sha256,verification_policy})}') || return 1
        dispatch_plan=$(_dp_release_plan "${repo,,}" "$selected" "$payload") || return $?
        _rf_dispatch_preflight "$dispatch_plan" "$dispatch_root" || return $?
    fi
    _rf_gate "$repo" "$tag" "$sha" "$evidence" "$initial_draft" "$manifest" "$work" || return $?
    local promotion_attempted=false promotion_rc=0 status=ready
    if [[ "$initial_draft" == true && "$promote" == true ]]; then
        state=$(jq -cS '.promotion_attempts+=1 | .phase="promoting"' <<< "$state") || return 1
        oldhash=$(_rf_save "$file" "$state" "$oldhash" "$work" "$plan") || return $?
        # Saving intent can fail; no public mutation precedes that durable record.
        sbom_verify_artifacts "$root" --format "$format" --output-dir "$output_dir" >/dev/null || return $?
        _rf_gate "$repo" "$tag" "$sha" "$evidence" true "$manifest" "$work" || return $?
        promotion_attempted=true
        _rf_promote "$repo" "$(jq -r '.release.id' <<< "$verification")" "$work" || promotion_rc=$?
        # Reconcile a lost PATCH acknowledgement by reading actual state, not by
        # replaying the PATCH. The same verification runs after a process restart.
        verification=$(sbom_verify_release --repo "$repo" --tag "$tag" --format "$format" --manifest-sha256 "$pin") || return $?
        [[ "$(_rf_evidence_key "$verification" "$repo" "$tag" "$sha" "$format" "$pin" "$manifest_name")" == "$evidence" &&
           "$(jq -r '.release.draft' <<< "$verification")" == false ]] || {
            _rf_log 'Promotion did not yield the expected published release; retry rechecks remote state'; return 7;
        }
        initial_draft=false
    fi
    sbom_verify_artifacts "$root" --format "$format" --output-dir "$output_dir" >/dev/null || return $?
    _rf_gate "$repo" "$tag" "$sha" "$evidence" "$initial_draft" "$manifest" "$work" || return $?
    if [[ "$initial_draft" == false ]]; then
        status=published
        state=$(jq -cS --argjson verification "$verification" '.verification=$verification | .phase="published"' <<< "$state") || return 1
        oldhash=$(_rf_save "$file" "$state" "$oldhash" "$work" "$plan") || return $?
    fi
    [[ "$(_rf_hash "$file")" == "$oldhash" ]] || return 2
    if [[ -n "$selected" ]]; then
        # Published evidence and local state remain pinned for the entire fan-out.
        local _RF_GUARD_REPO="$repo" _RF_GUARD_TAG="$tag" _RF_GUARD_SHA="$sha" _RF_GUARD_EVIDENCE="$evidence"
        local _RF_GUARD_MANIFEST="$manifest" _RF_GUARD_WORK="$work" _RF_GUARD_STATE="$file" _RF_GUARD_STATE_HASH="$oldhash"
        [[ "$initial_draft" == false ]] || return 7
        dispatch_result=$(_dp_release_outbox "$dispatch_plan" "$dispatch_root" "$retry_uncertain" false _rf_dispatch_guard) || dispatch_rc=$?
        if ! jq -e -s --argjson rc "$dispatch_rc" 'length==1 and (.[0]|.exit_code==$rc and
            (.status=="accepted" or .status=="incomplete") and (.results|type=="array"))' <<< "$dispatch_result" >/dev/null 2>&1; then
            dispatch_result=null
            ((dispatch_rc != 0)) || dispatch_rc=1
        fi
        if ((dispatch_rc == 0)); then _rf_dispatch_guard || dispatch_rc=$?; fi
        if ((dispatch_rc == 0)); then status=complete; else status=incomplete; fi
    fi
    jq -nc --arg status "$status" --arg file "$file" --argjson verification "$verification" \
        --argjson attempted "$promotion_attempted" --argjson rc "$promotion_rc" --argjson dispatch "$dispatch_result" --argjson exit_code "$dispatch_rc" '
        {kind:"dsr-release-finalization-result",status:$status,exit_code:$exit_code,dry_run:false,
         state_file:$file,promotion_attempted:$attempted,promotion_transport_exit_code:$rc,
         verification:$verification,dispatch:$dispatch}' || return 1
    return "$dispatch_rc"
)

# Exactly one result even on failure, preserving the process exit. No live API
# response body or token is included in diagnostics.
release_finalize() (
    local work result='' rc=0 error='' start=$SECONDS cleanup
    command -v jq >/dev/null || return 3
    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-finalize-result.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q' "$work"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    result=$(_rf_execute "$@" 2> "$work/diagnostics") || rc=$?
    if ((rc == 0)); then
        jq -e -s 'length==1 and (.[0]|.kind=="dsr-release-finalization-result" and .exit_code==0)' <<< "$result" >/dev/null || rc=1
    fi
    if ((rc != 0)); then
        error=$(head -c 8192 "$work/diagnostics") || return 1
        [[ -n "$error" ]] || error="Release finalization failed (exit $rc)"
        if jq -e -s --argjson rc "$rc" 'length==1 and (.[0]|.kind=="dsr-release-finalization-result" and .exit_code==$rc)' <<< "$result" >/dev/null 2>&1; then
            jq -c --arg error "$error" --argjson duration "$((SECONDS-start))" '.+{error:$error,duration_seconds:$duration}' <<< "$result" || return 1
        else
            jq -nc --arg error "$error" --argjson rc "$rc" --argjson duration "$((SECONDS-start))" \
                '{kind:"dsr-release-finalization-result",status:"error",exit_code:$rc,error:$error,duration_seconds:$duration}' || return 1
        fi
    else
        jq -c --argjson duration "$((SECONDS-start))" '.+{duration_seconds:$duration}' <<< "$result" || return 1
    fi
    return "$rc"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --help|-h|'')
            printf '%s\n' 'Usage: bash src/release_finalize.sh ARTIFACTS --repo OWNER/REPO --tag vVERSION --sha COMMIT' \
                'Options: --promote --format spdx|cyclonedx --output-dir DIR --state-dir DIR --dry-run' \
                'Handoff: --tool NAME --dispatch-repos OWNER/A,OWNER/B [--dispatch-run-id ID] [--dispatch-state-dir DIR] [--retry-uncertain]' \
                'Default: attach and verify SBOMs, retaining draft mode. --promote explicitly publishes the draft.' \
                'Existing payloads must already be uploaded. This does not verify signatures or build provenance.' ;;
        *) release_finalize "$@"; exit $? ;;
    esac
fi
