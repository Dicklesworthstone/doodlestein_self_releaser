#!/usr/bin/env bash
# Verified release finalization: local inventory -> remote evidence -> promotion.
# Optional manifest-bound payload upload precedes the existing SBOM APIs.
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

_rf_payload_require() {
    if ! declare -F release_upload_payloads >/dev/null; then
        # shellcheck source=src/release_payloads.sh
        source "$_RELEASE_FINALIZE_DIR/release_payloads.sh" || return 3
    fi
    _rup_require
}

_rf_prepare_require() {
    if ! declare -F release_prepare >/dev/null; then
        # shellcheck source=src/release_prepare.sh
        source "$_RELEASE_FINALIZE_DIR/release_prepare.sh" || return 3
    fi
}

_rf_integrity_require() {
    if ! declare -F release_publish_integrity >/dev/null; then
        # shellcheck source=src/release_integrity.sh
        source "$_RELEASE_FINALIZE_DIR/release_integrity.sh" || return 3
    fi
    _ri_require
}

# Authenticate an already-prepared bundle before any remote read or persistent
# state. This mode never invokes preparation or needs a private build manifest.
_rf_prepared_integrity_plan() (
    local root="$1" proofs="$2" public="$3" repo="$4" tag="$5" sha="$6"
    local work cleanup token selection documents
    umask 077
    [[ -d "$proofs" && ! -L "$proofs" ]] || return 4
    token=$(signing_public_key_token "$public") || return $?
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-finalize-integrity.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q' "$work"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    _ri_verify_set "$root" "$proofs" "$repo" "$tag" "$sha" "$token" "$work" || return $?
    documents=$(_ri_documents "$proofs") || return $?
    selection=$(jq -cS '{tool,manifest_sha256:.build_manifest_sha256,tag,source_sha,
        artifacts:(.artifacts|map({name,sha256,size})|sort_by(.name))}' \
        "$proofs/release-integrity.json") || return 1
    _ri_local_unchanged "$root" "$proofs" "$selection" "$documents" "$work" || return $?
    _ri_verify_set "$root" "$proofs" "$repo" "$tag" "$sha" "$token" "$work" || return $?
    _ri_local_unchanged "$root" "$proofs" "$selection" "$documents" "$work" || return $?
    [[ "$(signing_public_key_token "$public")" == "$token" ]] || return 7
    jq -cSn --arg token "$token" --argjson selection "$selection" --argjson documents "$documents" \
        '{public_key:$token,selection:$selection,documents:$documents}'
)

# Freeze the exact authenticated proof set at the finalizer/publisher boundary.
# A valid replacement bundle must not become the newly selected publication.
_rf_integrity_snapshot() {
    local proofs="$1" documents="$2" work="$3" snapshot rows row name
    snapshot=$(mktemp -d "$work/integrity-input.XXXXXXXX") || return 1
    rows=$(jq -c '.[]' <<< "$documents") || return 1
    while IFS= read -r row; do
        name=$(jq -r '.name' <<< "$row") || return 1
        _ri_check_record "$proofs/$name" "$row" || return $?
        cp -- "$proofs/$name" "$snapshot/$name" || return 1
        _ri_check_record "$snapshot/$name" "$row" || return $?
        chmod 400 "$snapshot/$name" || return 1
    done <<< "$rows"
    printf '%s\n' "$snapshot"
}

# Bind the verified signature receipt to the selected key, signed manifest and
# exact expected asset records. A bare authenticated:true is not a receipt.
_rf_integrity_key() {
    local receipt="$1" repo="$2" tag="$3" sha="$4" token="$5" hash="$6" selection="$7" documents="$8" context
    context=$(_rf_context_key "$receipt" "$repo" "$tag" "$sha") || return 7
    jq -ecsS --argjson context "$context" --arg token "$token" --arg hash "$hash" \
        --argjson selection "$selection" --argjson documents "$documents" '
        def id: type=="number" and .>0 and .<=9007199254740991 and .==floor;
        ($selection.artifacts+$documents|sort_by(.name)) as $records |
        if length==1 and (.[0]|. as $r|
            .schema_version==1 and .kind=="dsr-release-integrity-verification" and
            .status=="verified" and .authenticated==true and .public_key==$token and
            .verification_policy=="minisign-all-payloads-and-checksums" and
            (.manifest|type=="object" and .name=="release-integrity.json" and .sha256==$hash and (.asset_id|id)) and
            (.assets|type=="array" and all(.[];type=="object" and (.id|id) and .state=="uploaded")) and
            ((.assets|map(.name)|sort)==($records|map(.name))) and
            ((.assets|map(.id)|unique|length)==(.assets|length)) and
            all($records[];. as $p|[$r.assets[]|select(.name==$p.name)] as $a|
                ($a|length)==1 and $a[0].size==$p.size and
                ($a[0].digest==null or $a[0].digest=="" or $a[0].digest==("sha256:"+$p.sha256))) and
            ([.assets[]|select(.name=="release-integrity.json")|.id]==[.manifest.asset_id]))
        then .[0]|{context:$context,authenticated,verification_policy,public_key,manifest,assets:(.assets|sort_by(.name))}
        else error("missing or mismatched signature verification evidence") end' <<< "$receipt" 2>/dev/null
}

# Signature verification authenticates frozen bytes. Rehash those bytes and keep
# the SBOM payload set identical at later gates; do not repeatedly sign or fetch
# the whole release before every downstream HTTP retry.
_rf_integrity_inputs_gate() {
    [[ -n "${_RF_INTEGRITY_SELECTION:-}" ]] || return 0
    local work="$1"
    if [[ -n "${_RF_INTEGRITY_BUILD:-}" ]]; then
        [[ "$(_rf_hash "$_RF_INTEGRITY_BUILD")" == "$(jq -r '.manifest_sha256' <<< "$_RF_INTEGRITY_SELECTION")" ]] || return 2
    fi
    if [[ -n "${_RF_PREPARED_PUBLIC_KEY:-}" ]]; then
        [[ "$(signing_public_key_token "$_RF_PREPARED_PUBLIC_KEY")" == "$_RF_PREPARED_TOKEN" ]] || return 7
    fi
    _ri_local_unchanged "$_RF_INTEGRITY_ROOT" "$_RF_INTEGRITY_OUTPUT" \
        "$_RF_INTEGRITY_SELECTION" "$_RF_INTEGRITY_DOCUMENTS" "$work"
}

_rf_integrity_local_gate() {
    [[ -n "${_RF_INTEGRITY_SELECTION:-}" ]] || return 0
    local manifest="$1" work="$2" actual expected
    _rf_integrity_inputs_gate "$work" || return $?
    actual=$(jq -cS '[.artifacts[].artifact|{name,sha256}]|sort_by(.name)' "$manifest") || return 7
    expected=$(jq -cS '[.artifacts[]|{name,sha256}]|sort_by(.name)' <<< "$_RF_INTEGRITY_SELECTION") || return 1
    [[ "$actual" == "$expected" ]] || { _rf_log 'SBOM inventory differs from the signed release'; return 7; }
}

_rf_integrity_assets_gate() {
    [[ -n "${_RF_INTEGRITY_ASSETS:-}" ]] || return 0
    jq -en --argjson current "$1" --argjson pinned "$_RF_INTEGRITY_ASSETS" \
        'all($pinned[];. as $a|[$current[]|select(.name==$a.name)]==[$a])' >/dev/null || {
            _rf_log 'Signed release asset identity changed'; return 7;
        }
}

# These inputs are scoped by _rf_execute, not taken from caller environment.
# Keep the generated SBOM set tied to the original successful build throughout
# promotion and every guarded downstream POST, not just at upload time.
_rf_payload_gate() {
    [[ -n "${_RF_BUILD_PLAN:-}" ]] || return 0
    local manifest="$1" work="$2" actual expected
    _rup_check_files "$_RF_PAYLOAD_ROOT" "$_RF_BUILD_MANIFEST" "$_RF_BUILD_PLAN" "$work" || return $?
    actual=$(jq -cS '[.artifacts[].artifact|{name,sha256}]|sort_by(.name)' "$manifest") || return 7
    expected=$(jq -cS '[.artifacts[]|{name,sha256}]|sort_by(.name)' <<< "$_RF_BUILD_PLAN") || return 1
    [[ "$actual" == "$expected" ]] || { _rf_log 'SBOM inventory differs from the selected build'; return 7; }
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
        def record: type=="object" and (.name|type=="string" and length>0) and (.sha256|digest) and
            (.size|type=="number" and .>0 and .==floor);
        length==1 and (.[0] | . as $s | type=="object" and .schema_version==1 and
            .kind=="dsr-release-finalization" and .plan==$plan and
            (.manifest_sha256==null or (.manifest_sha256|digest)) and
            (.verification==null or (.verification|type=="object" and .status=="verified")) and
            (.promotion_attempts|type=="number" and .>=0 and .==floor) and
            (.phase=="preparing" or .phase=="evidence_ready" or .phase=="promoting" or .phase=="published") and
            (if .phase=="preparing" then .verification==null
             else .manifest_sha256!=null and .verification!=null and
                  .verification.manifest.sha256==.manifest_sha256 end) and
            (if has("preparation_plan") then
                (.preparation_plan|type=="object" and .repo==$s.plan.context.repository.full_name and
                    (.request|type=="object" and .tag_name==$s.plan.context.release.tag_name and
                        .target_commitish==$s.plan.context.tag_commit and .draft==true and .make_latest=="false" and
                        .prerelease==$s.plan.context.release.prerelease and
                        (.name|type=="string" and length>0) and (.body|type=="string"))) and
                (.preparation|type=="object" and .kind=="dsr-release-preparation-result" and
                    .status=="prepared" and .exit_code==0 and .dry_run==false and .plan==$s.preparation_plan and
                    (.context|del(.release.draft))==$s.plan.context and
                    (.context.release.draft|type=="boolean"))
             else .preparation==null end) and
            (if has("integrity_policy") then
                (.integrity_policy|type=="object" and .required==true and
                    ((has("mode")|not) or .mode=="prepared") and
                    (.public_key|type=="string" and test("^[A-Za-z0-9+/]{40,}={0,2}$")) and
                    (.output_dir|type=="string" and length>0) and
                    (.selection|type=="object" and (.manifest_sha256|digest))) and
                (if .integrity_manifest_sha256==null then
                    .integrity_documents==null and .integrity_verification==null
                 else (.integrity_manifest_sha256|digest) and
                    (.integrity_documents|type=="array" and length>0 and all(.[];record)) and
                    (if .integrity_verification==null then true else
                        (.integrity_verification|type=="object" and
                            .kind=="dsr-release-integrity-verification" and .status=="verified" and .authenticated==true and
                            .public_key==$s.integrity_policy.public_key and
                            .manifest.sha256==$s.integrity_manifest_sha256) end) end) and
                (.phase=="preparing" or .integrity_verification!=null)
             else .integrity_manifest_sha256==null and .integrity_documents==null and .integrity_verification==null end))
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
    _rf_payload_gate "$manifest" "$work" || return $?
    if [[ -n "${_RF_BUILD_PLAN:-}" ]]; then
        _rup_preflight "$repo" "$inventory" "$_RF_BUILD_PLAN" "$_RF_PAYLOAD_ASSETS" "$work" || return $?
    fi
    _rf_integrity_local_gate "$manifest" "$work" || return $?
    _rf_integrity_assets_gate "$inventory"
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
    local upload_payloads=false build_manifest='' upload_plan=null payload_result=null
    local _RF_PAYLOAD_ROOT='' _RF_BUILD_MANIFEST='' _RF_BUILD_PLAN='' _RF_PAYLOAD_ASSETS=''
    local require_signatures=false public_key='' secret_key='' integrity_dir='' integrity_token=''
    local integrity_selection=null integrity_policy=null integrity_result=null integrity_hash='' integrity_key=null
    local build_snapshot='' build_pin='' public_snapshot='' integrity_documents=''
    local _RF_INTEGRITY_ROOT='' _RF_INTEGRITY_OUTPUT='' _RF_INTEGRITY_SELECTION='' _RF_INTEGRITY_DOCUMENTS=''
    local _RF_INTEGRITY_BUILD='' _RF_INTEGRITY_ASSETS=''
    local prepared_signatures=false prepared_plan=null integrity_snapshot='' integrity_work=''
    local _RF_PREPARED_PUBLIC_KEY='' _RF_PREPARED_TOKEN=''
    local create_draft=false release_name='' release_notes='' prerelease=false retry_creation=false
    local preparation_plan=null preparation_result=null preparation_notes=''
    local -a preparation_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo|--tag|--sha|--format|--output-dir|--state-dir|--tool|--dispatch-repos|--dispatch-run-id|--dispatch-state-dir|--build-manifest|--public-key|--secret-key|--integrity-dir|--release-name|--release-notes-file)
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
                    --build-manifest) [[ -z "$build_manifest" ]] || return 4; build_manifest="$2" ;;
                    --public-key) [[ -z "$public_key" ]] || return 4; public_key="$2" ;;
                    --secret-key) [[ -z "$secret_key" ]] || return 4; secret_key="$2" ;;
                    --integrity-dir) [[ -z "$integrity_dir" ]] || return 4; integrity_dir="$2" ;;
                    --release-name) [[ -z "$release_name" ]] || return 4; release_name="$2" ;;
                    --release-notes-file) [[ -z "$release_notes" ]] || return 4; release_notes="$2" ;;
                esac
                shift 2 ;;
            --promote) promote=true; shift ;;
            --create-draft) create_draft=true; shift ;;
            --prerelease) prerelease=true; shift ;;
            --retry-creation) retry_creation=true; shift ;;
            --upload-payloads) upload_payloads=true; shift ;;
            --require-signatures) require_signatures=true; shift ;;
            --prepared-signatures) prepared_signatures=true; shift ;;
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
    if [[ "$prepared_signatures" == true ]]; then
        [[ "$require_signatures" == false && -z "$secret_key" && -n "$public_key" && -n "$integrity_dir" ]] || {
            _rf_log '--prepared-signatures requires --integrity-dir and --public-key; signing options are not allowed'; return 4;
        }
        [[ "$integrity_dir" != *[[:cntrl:]]* && "$integrity_dir" != *\\* ]] || return 4
        _rf_integrity_require || return $?
        prepared_plan=$(_rf_prepared_integrity_plan "$root" "$integrity_dir" "$public_key" "$repo" "$tag" "$sha") || return $?
        integrity_token=$(jq -r '.public_key' <<< "$prepared_plan") || return 1
        integrity_selection=$(jq -cS '.selection' <<< "$prepared_plan") || return 1
        integrity_documents=$(jq -c '.documents' <<< "$prepared_plan") || return 1
        integrity_hash=$(jq -r '.documents[]|select(.name=="release-integrity.json")|.sha256' <<< "$prepared_plan") || return 1
        if [[ -n "$build_manifest" ]]; then
            [[ "$(_rf_hash "$build_manifest")" == "$(jq -r '.manifest_sha256' <<< "$integrity_selection")" ]] || return 2
        fi
        [[ -z "$tool" || "$tool" == "$(jq -r '.tool' <<< "$integrity_selection")" ]] || return 4
        require_signatures=true
    fi
    if [[ "$upload_payloads" == true ]]; then
        [[ -n "$build_manifest" ]] || { _rf_log '--upload-payloads requires --build-manifest'; return 4; }
        _rf_payload_require || return $?
        payload_result=$(release_upload_payloads "$root" --build-manifest "$build_manifest" \
            --repo "$repo" --tag "$tag" --sha "$sha" --dry-run) || return $?
        upload_plan=$(jq -ceS 'select(.kind=="dsr-release-payload-publication" and .status=="planned" and .dry_run==true)|.plan' <<< "$payload_result") || return 7
        [[ -z "$tool" || "$tool" == "$(jq -r '.tool' <<< "$upload_plan")" ]] || {
            _rf_log 'Dispatch tool differs from the build manifest'; return 4;
        }
    elif [[ -n "$build_manifest" && "$require_signatures" == false ]]; then
        _rf_log '--build-manifest requires --upload-payloads or --require-signatures'; return 4
    fi
    if [[ "$prepared_signatures" == true ]]; then
        [[ "$upload_plan" == null || "$upload_plan" == "$integrity_selection" ]] || return 7
    elif [[ "$require_signatures" == true ]]; then
        [[ -n "$build_manifest" && -n "$public_key" ]] || {
            _rf_log '--require-signatures needs --build-manifest and --public-key'; return 4;
        }
        _rf_integrity_require || return $?
        integrity_token=$(signing_public_key_token "$public_key") || return $?
        integrity_result=$(release_prepare_integrity "$root" --build-manifest "$build_manifest" \
            --repo "$repo" --tag "$tag" --sha "$sha" --public-key "$public_key" --dry-run) || return $?
        integrity_selection=$(jq -ceS --arg token "$integrity_token" \
            'select(.kind=="dsr-release-integrity-plan" and .status=="planned" and .dry_run==true and .public_key==$token)|.selection' \
            <<< "$integrity_result") || return 7
        [[ "$upload_plan" == null || "$upload_plan" == "$integrity_selection" ]] || return 7
        [[ -z "$tool" || "$tool" == "$(jq -r '.tool' <<< "$integrity_selection")" ]] || return 4
        [[ -n "$integrity_dir" ]] || integrity_dir="$output_dir"
        [[ ! -L "$integrity_dir" && "$integrity_dir" != *[[:cntrl:]]* && "$integrity_dir" != *\\* ]] || return 4
        integrity_result=null
    elif [[ -n "$public_key$secret_key$integrity_dir" ]]; then
        _rf_log 'Signing options require --require-signatures'; return 4
    fi
    if [[ "$create_draft" == true ]]; then
        [[ "$upload_payloads" == true ]] || { _rf_log '--create-draft requires --upload-payloads and --build-manifest'; return 4; }
        [[ -z "$selected" || "$promote" == true ]] || { _rf_log 'Creating a draft for dispatch requires --promote'; return 4; }
        _rf_prepare_require || return $?
        preparation_args=(--repo "$repo" --tag "$tag" --sha "$sha")
        [[ -z "$release_name" ]] || preparation_args+=(--name "$release_name")
        [[ -z "$release_notes" ]] || preparation_args+=(--notes-file "$release_notes")
        [[ "$prerelease" == false ]] || preparation_args+=(--prerelease)
        preparation_result=$(release_prepare "${preparation_args[@]}" \
            --state-dir "${state_dir:-${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/release-finalize}" --dry-run) || return $?
        preparation_plan=$(jq -ecsS 'if length==1 and (.[0]|.kind=="dsr-release-preparation-result" and
            .status=="planned" and .dry_run==true and .exit_code==0) then .[0].plan else error("invalid draft plan") end' \
            <<< "$preparation_result") || return 7
        preparation_result=null
    elif [[ -n "$release_name$release_notes" || "$prerelease" == true || "$retry_creation" == true ]]; then
        _rf_log 'Draft metadata and --retry-creation require --create-draft'; return 4
    fi
    if [[ "$dry" == true ]]; then
        jq -nc --arg repo "$repo" --arg tag "$tag" --arg sha "$sha" --arg format "$format" --argjson promote "$promote" --arg selected "$selected" --argjson upload_plan "$upload_plan" \
            --argjson signed "$require_signatures" --argjson prepared "$prepared_signatures" --arg key "$integrity_token" --argjson preparation "$preparation_plan" '
            {kind:"dsr-release-finalization-result",status:"planned",dry_run:true,exit_code:0,
             repo:$repo,tag:$tag,expected_sha:$sha,format:$format,promote:$promote,
             dispatch_repos:(if $selected=="" then [] else ($selected|split("\n")) end),
             payload_plan:$upload_plan,
             require_signatures:$signed,public_key:(if $signed then $key else null end),
             prepared_signatures:$prepared,
             preparation_plan:$preparation,
             stages:((if $prepared then ["authenticate prepared bundle"] else [] end)+
                     (if $preparation==null then [] else ["create or reconcile source-pinned draft"] end)+["pin release"]+
                     (if $signed and ($prepared|not) then ["prepare and verify signed release bundle"] else [] end)+
                     (if $upload_plan==null then [] else ["upload and verify build payloads"] end)+
                     (if $signed then ["publish and authenticate payload/checksum signatures"] else [] end)+
                     ["generate or reuse SBOMs","publish and verify evidence",
                     (if $promote then "promote without changing latest" else "retain release mode" end)])}'
        return $?
    fi
    command -v flock >/dev/null || { _rf_log 'flock is required'; return 3; }
    [[ -n "$state_dir" ]] || state_dir="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/release-finalize"
    [[ "$state_dir" != *[[:cntrl:]]* && "$state_dir" != *\\* && ! -L "$state_dir" ]] || return 4
    _rf_require || return $?
    # Serialize creation as well as upload/finalization, and inspect retained
    # state before any create attempt. Never replace an already-bound release.
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
    oldhash=$(_rf_file_state "$file") || return $?
    if [[ "$oldhash" != absent ]]; then
        saved=$(jq -cS .plan "$file") || return 2
        _rf_state_valid "$file" "$saved" || { _rf_log 'Invalid finalization state'; return 2; }
        [[ "$(jq -cS '.preparation_plan // null' "$file")" == "$preparation_plan" ]] || {
            _rf_log 'Cannot change or omit the frozen draft-creation plan'; return 2;
        }
        [[ "$(_rf_hash "$file")" == "$oldhash" ]] || return 2
    fi
    local context context_key initial_draft
    if [[ "$create_draft" == true ]]; then
        # Use the planned note bytes, not a mutable file reread after preflight.
        preparation_notes="$work/release-notes"
        jq -jr .request.body <<< "$preparation_plan" > "$preparation_notes" || return 1
        chmod 400 "$preparation_notes" || return 1
        preparation_args=(--repo "$repo" --tag "$tag" --sha "$sha" --state-dir "$session/preparation"
            --name "$(jq -r .request.name <<< "$preparation_plan")" --notes-file "$preparation_notes")
        [[ "$prerelease" == false ]] || preparation_args+=(--prerelease)
        [[ "$retry_creation" == false ]] || preparation_args+=(--retry-uncertain)
        [[ "$oldhash" == absent ]] || preparation_args+=(--existing-only)
        preparation_result=$(release_prepare "${preparation_args[@]}") || return $?
        context=$(jq -ecsS --argjson plan "$preparation_plan" 'if length==1 and (.[0]|
            .kind=="dsr-release-preparation-result" and .status=="prepared" and .exit_code==0 and
            .dry_run==false and .plan==$plan) then .[0].context else error("invalid draft receipt") end' \
            <<< "$preparation_result") || return 7
    else
        context=$(_sbr_context "$repo" "$tag" "$work") || return $?
    fi
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
    if [[ "$require_signatures" == true ]]; then
        mkdir -p -- "$integrity_dir" || return 1
        integrity_dir=$(cd "$integrity_dir" && pwd -P) || return 4
        integrity_policy=$(jq -cSn --arg token "$integrity_token" --arg dir "$integrity_dir" --argjson selection "$integrity_selection" \
            '{required:true,public_key:$token,output_dir:$dir,selection:$selection}') || return 1
        if [[ "$prepared_signatures" == true ]]; then
            integrity_policy=$(jq -cS '.mode="prepared"' <<< "$integrity_policy") || return 1
        fi
    fi
    plan=$(jq -cSn --argjson context "$context_key" --arg root "$root" --arg output "$output_dir" --arg format "$format" \
        '{context:$context,artifacts_dir:$root,output_dir:$output,format:$format}') || return 1
    if [[ "$oldhash" == absent ]]; then
        state=$(jq -cSn --argjson plan "$plan" --argjson preparation "$preparation_plan" --argjson receipt "$preparation_result" \
            '{schema_version:1,kind:"dsr-release-finalization",plan:$plan,manifest_sha256:null,
              verification:null,promotion_attempts:0,phase:"preparing"} |
             if $preparation==null then . else .+{preparation_plan:$preparation,preparation:$receipt} end') || return 1
        oldhash=$(_rf_save "$file" "$state" absent "$work" "$plan") || return $?
    else
        _rf_state_valid "$file" "$plan" || { _rf_log 'Invalid or conflicting finalization plan'; return 2; }
        state=$(cat "$file") || return 1
        [[ "$(_rf_hash "$file")" == "$oldhash" ]] || return 2
    fi
    saved=$(jq -cS '.integrity_policy // null' <<< "$state") || return 1
    [[ "$saved" == null || "$saved" == "$integrity_policy" ]] || {
        _rf_log 'Cannot change or omit the frozen signature policy'; return 2;
    }
    if [[ "$integrity_policy" != null && "$saved" == null ]]; then
        # Adding proof assets changes the immutable inventory in a completed
        # finalization. Require selecting this policy before that inventory binds.
        [[ "$(jq -r '.phase' <<< "$state")" == preparing ]] || {
            _rf_log 'Signature policy must be selected before evidence finalization'; return 2;
        }
        state=$(jq -cS --argjson policy "$integrity_policy" '.integrity_policy=$policy' <<< "$state") || return 1
        oldhash=$(_rf_save "$file" "$state" "$oldhash" "$work" "$plan") || return $?
    fi
    saved=$(jq -cS '.handoff // null' <<< "$state") || return 1
    [[ "$saved" == null || "$saved" == "$handoff" ]] || {
        _rf_log 'Cannot change or omit the frozen downstream handoff'; return 2;
    }
    if [[ "$handoff" != null && "$saved" == null ]]; then
        state=$(jq -cS --argjson handoff "$handoff" '.handoff=$handoff' <<< "$state") || return 1
        oldhash=$(_rf_save "$file" "$state" "$oldhash" "$work" "$plan") || return $?
    fi
    saved=$(jq -cS '.payload_plan // null' <<< "$state") || return 1
    [[ "$saved" == null || "$saved" == "$upload_plan" ]] || {
        _rf_log 'Cannot change or omit the frozen build payload plan'; return 2;
    }
    if [[ -n "$build_manifest" && ( "$upload_payloads" == true || "$require_signatures" == true ) ]]; then
        if [[ "$require_signatures" == true ]]; then
            build_pin=$(jq -r '.manifest_sha256' <<< "$integrity_selection") || return 1
        else
            build_pin=$(jq -r '.manifest_sha256' <<< "$upload_plan") || return 1
        fi
        [[ "$(_rf_hash "$build_manifest")" == "$build_pin" ]] || return 2
        build_snapshot=$(mktemp "$work/build-manifest.XXXXXXXX") || return 1
        cp -- "$build_manifest" "$build_snapshot" || return 1
        chmod 400 "$build_snapshot" || return 1
        [[ "$(_rf_hash "$build_snapshot")" == "$build_pin" &&
           "$(_rf_hash "$build_manifest")" == "$build_pin" ]] || return 2
    fi
    if [[ "$require_signatures" == true ]]; then
        # Freeze the selected public token; subsequent mutation of the key file
        # cannot silently change which key this invocation trusts. Never copy the
        # secret key into finalization state or public output.
        public_snapshot="$work/trusted-minisign.pub"
        printf 'untrusted comment: pinned finalization key\n%s\n' "$integrity_token" > "$public_snapshot" || return 1
        if [[ "$prepared_signatures" == true ]]; then
            _ri_local_unchanged "$root" "$integrity_dir" "$integrity_selection" "$integrity_documents" "$work" || return $?
        else
            local -a sign_args=("$root" --build-manifest "$build_snapshot" --repo "$repo" --tag "$tag" --sha "$sha"
                --public-key "$public_snapshot" --output-dir "$integrity_dir")
            [[ -z "$secret_key" ]] || sign_args+=(--secret-key "$secret_key")
            release_prepare_integrity "${sign_args[@]}" > "$work/integrity-prepare.json" || return $?
        fi
        _ri_verify_set "$root" "$integrity_dir" "$repo" "$tag" "$sha" "$integrity_token" "$work" || return $?
        _ri_matches_selection "$integrity_dir/release-integrity.json" "$integrity_selection" || return 2
        integrity_hash=$(_rf_hash "$integrity_dir/release-integrity.json") || return $?
        integrity_documents=$(_ri_documents "$integrity_dir") || return $?
        if [[ "$prepared_signatures" == true ]]; then
            [[ "$(jq -cS . <<< "$integrity_documents")" == "$(jq -cS '.documents' <<< "$prepared_plan")" ]] || return 2
        fi
        saved=$(jq -r '.integrity_manifest_sha256 // ""' <<< "$state") || return 1
        [[ -z "$saved" || "$saved" == "$integrity_hash" ]] || return 2
        saved=$(jq -cS '.integrity_documents // null' <<< "$state") || return 1
        [[ "$saved" == null || "$saved" == "$(jq -cS . <<< "$integrity_documents")" ]] || return 2
        state=$(jq -cS --arg hash "$integrity_hash" --argjson docs "$integrity_documents" \
            '.integrity_manifest_sha256=$hash|.integrity_documents=$docs' <<< "$state") || return 1
        oldhash=$(_rf_save "$file" "$state" "$oldhash" "$work" "$plan") || return $?
        if [[ -n "$build_manifest" ]]; then
            [[ "$(_rf_hash "$build_manifest")" == "$build_pin" ]] || return 2
        fi
        _RF_INTEGRITY_ROOT="$root"; _RF_INTEGRITY_OUTPUT="$integrity_dir"; _RF_INTEGRITY_BUILD="$build_manifest"
        _RF_INTEGRITY_SELECTION="$integrity_selection"; _RF_INTEGRITY_DOCUMENTS="$integrity_documents"
        if [[ "$prepared_signatures" == true ]]; then
            _RF_PREPARED_PUBLIC_KEY="$public_key"; _RF_PREPARED_TOKEN="$integrity_token"
        fi
    fi
    if [[ "$upload_payloads" == true ]]; then
        state=$(jq -cS --argjson selection "$upload_plan" '.payload_plan=$selection' <<< "$state") || return 1
        oldhash=$(_rf_save "$file" "$state" "$oldhash" "$work" "$plan") || return $?
        # The uploader must consume the already selected manifest, not a new
        # build that appeared between the planning read and this invocation.
        # Keep the original path for later guards, but freeze the input bytes.
        [[ "$(_rf_hash "$build_manifest")" == "$build_pin" ]] || return 2
        [[ "$(_rf_hash "$build_snapshot")" == "$build_pin" ]] || return 2
        _rf_integrity_inputs_gate "$work" || return $?
        [[ "$(_sbr_context "$repo" "$tag" "$work")" == "$context" ]] || {
            _rf_log 'Release changed before payload publication'; return 7;
        }
        payload_result=$(release_upload_payloads "$root" --build-manifest "$build_snapshot" \
            --repo "$repo" --tag "$tag" --sha "$sha" --state-dir "$session/payloads") || return $?
        jq -es --argjson selection "$upload_plan" 'length==1 and (.[0]|
            .kind=="dsr-release-payload-publication" and .status=="verified" and .dry_run==false and
            .manifest_sha256==$selection.manifest_sha256 and .tool==$selection.tool and
            (.assets|type=="array") and (.assets|map(.name)|sort)==($selection.artifacts|map(.name)|sort))' \
            <<< "$payload_result" >/dev/null || return 7
        [[ "$(_rf_context_key "$payload_result" "$repo" "$tag" "$sha")" == "$context_key" &&
           "$(jq -r '.release.draft' <<< "$payload_result")" == "$initial_draft" ]] || return 7
        _RF_PAYLOAD_ROOT="$root"; _RF_BUILD_MANIFEST="$build_manifest"; _RF_BUILD_PLAN="$upload_plan"
        _RF_PAYLOAD_ASSETS=$(jq -cS '.assets' <<< "$payload_result") || return 1
        saved=$(jq -cS '.payload_verification.assets // null' <<< "$state") || return 1
        [[ "$saved" == null || "$saved" == "$_RF_PAYLOAD_ASSETS" ]] || return 7
        state=$(jq -cS --argjson receipt "$payload_result" '.payload_verification=$receipt' <<< "$state") || return 1
        oldhash=$(_rf_save "$file" "$state" "$oldhash" "$work" "$plan") || return $?
    fi
    if [[ "$require_signatures" == true ]]; then
        _rf_integrity_inputs_gate "$work" || return $?
        saved=$(jq -cS '.integrity_verification // null' <<< "$state") || return 1
        if [[ "$saved" != null ]]; then
            integrity_key=$(_rf_integrity_key "$saved" "$repo" "$tag" "$sha" "$integrity_token" \
                "$integrity_hash" "$integrity_selection" "$integrity_documents") || return 7
            _RF_INTEGRITY_ASSETS=$(jq -cS '.assets' <<< "$integrity_key") || return 1
            _rf_integrity_assets_gate "$(_sbr_inventory "$repo" "$(jq -r '.release.id' <<< "$context")" "$work")" || return $?
        fi
        integrity_snapshot=$(_rf_integrity_snapshot "$integrity_dir" "$integrity_documents" "$work") || return $?
        _rf_integrity_inputs_gate "$work" || return $?
        if [[ "$prepared_signatures" == true ]]; then
            integrity_work=$(mktemp -d "$work/integrity-publish.XXXXXXXX") || return 1
            integrity_result=$(_ri_remote_publish "$root" "$integrity_snapshot" "$integrity_selection" \
                "$repo" "$tag" "$sha" "$integrity_token" "$integrity_work") || return $?
        else
            integrity_result=$(release_publish_integrity "$root" --build-manifest "$build_snapshot" \
                --repo "$repo" --tag "$tag" --sha "$sha" --public-key "$public_snapshot" \
                --output-dir "$integrity_snapshot" --manifest-sha256 "$integrity_hash") || return $?
        fi
        _rf_integrity_inputs_gate "$work" || return $?
        integrity_key=$(_rf_integrity_key "$integrity_result" "$repo" "$tag" "$sha" "$integrity_token" \
            "$integrity_hash" "$integrity_selection" "$integrity_documents") || return 7
        [[ "$(jq -cS '.context' <<< "$integrity_key")" == "$context_key" &&
           "$(jq -r '.release.draft' <<< "$integrity_result")" == "$initial_draft" ]] || return 7
        saved=$(jq -cS '.integrity_verification // null' <<< "$state") || return 1
        if [[ "$saved" != null ]]; then
            [[ "$(_rf_integrity_key "$saved" "$repo" "$tag" "$sha" "$integrity_token" \
                "$integrity_hash" "$integrity_selection" "$integrity_documents")" == "$integrity_key" ]] || return 7
        fi
        _RF_INTEGRITY_ASSETS=$(jq -cS '.assets' <<< "$integrity_key") || return 1
        state=$(jq -cS --argjson receipt "$integrity_result" '.integrity_verification=$receipt' <<< "$state") || return 1
        oldhash=$(_rf_save "$file" "$state" "$oldhash" "$work" "$plan") || return $?
    fi
    case "$format" in spdx) manifest_name=sbom-manifest.spdx.json ;; *) manifest_name=sbom-manifest.cdx.json ;; esac
    manifest="$output_dir/$manifest_name"
    # This API reuses verified completed inventories without requiring Syft.
    sbom_generate_artifacts "$root" --format "$format" --output-dir "$output_dir" > "$work/scan.out" || return $?
    _rf_payload_gate "$manifest" "$work" || return $?
    _rf_integrity_local_gate "$manifest" "$work" || return $?
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
    if [[ "$require_signatures" == true ]]; then
        local integrity_inventory
        integrity_inventory=$(_sbr_inventory "$repo" "$(jq -r '.release.id' <<< "$context")" "$work") || return $?
        _rf_integrity_assets_gate "$integrity_inventory" || return $?
    fi
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
        payload=$(jq -nc --arg tool "$tool" --arg tag "$tag" --arg sha "$sha" --arg run "$dispatch_run" --argjson evidence "$evidence" --argjson integrity "$integrity_key" '
            {tool:$tool,version:$tag,sha:$sha,run_id:$run,
             release_evidence:($evidence|{repository_id:.repository.id,release_id:.release.id,
                 format,manifest,artifact_count,asset_inventory_sha256,verification_policy})} |
            if $integrity==null then . else
                .release_evidence.integrity=($integrity|{verification_policy,public_key,manifest}) end') || return 1
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
    if [[ "$require_signatures" == true ]]; then
        # Independently authenticate the final remote bytes again after SBOM
        # publication and any draft promotion, then pin the same verified IDs
        # throughout downstream handoff. No fallback to unsigned completion.
        integrity_result=$(release_verify_remote_integrity --repo "$repo" --tag "$tag" --sha "$sha" \
            --public-key "$public_snapshot" --manifest-sha256 "$integrity_hash") || return $?
        [[ "$(_rf_integrity_key "$integrity_result" "$repo" "$tag" "$sha" "$integrity_token" \
            "$integrity_hash" "$integrity_selection" "$integrity_documents")" == "$integrity_key" &&
           "$(jq -r '.release.draft' <<< "$integrity_result")" == "$initial_draft" ]] || return 7
        state=$(jq -cS --argjson receipt "$integrity_result" '.integrity_verification=$receipt' <<< "$state") || return 1
        oldhash=$(_rf_save "$file" "$state" "$oldhash" "$work" "$plan") || return $?
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
        --argjson attempted "$promotion_attempted" --argjson rc "$promotion_rc" --argjson dispatch "$dispatch_result" --argjson exit_code "$dispatch_rc" --argjson payloads "$payload_result" --argjson integrity "$integrity_result" --argjson preparation "$preparation_result" '
        {kind:"dsr-release-finalization-result",status:$status,exit_code:$exit_code,dry_run:false,
         state_file:$file,promotion_attempted:$attempted,promotion_transport_exit_code:$rc,
         verification:$verification,dispatch:$dispatch,payloads:$payloads,integrity:$integrity,preparation:$preparation}' || return 1
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
                'Draft creation: --create-draft --upload-payloads --build-manifest FILE [--release-name TITLE] [--release-notes-file FILE] [--prerelease] [--retry-creation]' \
                'Payloads: --upload-payloads --build-manifest FILE (resumable uploads to an existing draft)' \
                'Signatures: --require-signatures --build-manifest FILE --public-key FILE [--secret-key FILE] [--integrity-dir DIR]' \
                'Prepared only: --prepared-signatures --integrity-dir DIR --public-key FILE (never signs; build manifest optional unless uploading)' \
                'Handoff: --tool NAME --dispatch-repos OWNER/A,OWNER/B [--dispatch-run-id ID] [--dispatch-state-dir DIR] [--retry-uncertain]' \
                'Default: attach and verify SBOMs, retaining draft mode. --promote explicitly publishes the draft.' \
                'Without --upload-payloads, payloads must already exist. Signatures require explicit policy; no build-provenance claim.' ;;
        *) release_finalize "$@"; exit $? ;;
    esac
fi
