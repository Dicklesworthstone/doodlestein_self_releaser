#!/usr/bin/env bash
# Manifest-bound payload publication (bd-1jt.3.1 / bd-1jt.3.10).
# Existing release/tag only. No clobber, deletion, promotion, or signing.
_RELEASE_PAYLOADS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_rup_log() { printf '[release-payloads] %s\n' "$*" >&2; }
_rup_require() {
    if ! declare -F _sbr_publication_gate >/dev/null; then
        # shellcheck source=src/sbom_release.sh
        source "$_RELEASE_PAYLOADS_DIR/sbom_release.sh" || return 3
    fi
    if ! declare -F _sbom_select_artifacts >/dev/null; then
        # shellcheck source=src/sbom.sh
        source "$_RELEASE_PAYLOADS_DIR/sbom.sh" || return 3
    fi
    if ! declare -F _slsa_manifest_statement >/dev/null; then
        # shellcheck source=src/slsa.sh
        source "$_RELEASE_PAYLOADS_DIR/slsa.sh" || return 3
    fi
}

# Reuse the complete successful-build profile, without emitting or authenticating
# a provenance claim. Embedded filesystem paths are never used for selection.
_rup_manifest() {
    local manifest="$1" repo="$2" tag="$3" sha="$4" statement before
    before=$(_slsa_sha256 "$manifest") || return $?
    statement=$(_slsa_manifest_statement "$manifest" "$repo" 'dsr:payload-validation') || return $?
    jq -ceS --arg tag "$tag" --arg sha "$sha" --arg hash "$before" '
        if .source.git_sha==$sha and ("v"+(.version|ltrimstr("v")))==$tag
        then {manifest_sha256:$hash,tool,tag:$tag,source_sha:$sha,
              artifacts:(.artifacts|sort_by(.name)|map({name,sha256,size:.size_bytes}))}
        else error("manifest source/version differs from requested release") end' "$manifest" || return 4
    [[ "$(_slsa_sha256 "$manifest")" == "$before" ]] || return 2
    # Consume the validated result even though only its success is needed here.
    [[ -n "$statement" ]] || return 4
}

_rup_check_files() {
    local root="$1" manifest="$2" plan="$3" work="$4" selected expected entries entry name hash size
    [[ "$(_slsa_sha256 "$manifest")" == "$(jq -r '.manifest_sha256' <<< "$plan")" ]] || return 2
    selected=$(_sbom_select_artifacts "$root" "$work/list") || return $?
    selected=$(jq -nc --arg names "$selected" '$names|split("\n")|sort') || return 1
    expected=$(jq -c '[.artifacts[].name]|sort' <<< "$plan") || return 1
    [[ "$selected" == "$expected" ]] || { _rup_log 'Local payload set differs from build manifest'; return 4; }
    entries=$(jq -c '.artifacts[]' <<< "$plan") || return 1
    while IFS= read -r entry; do
        name=$(jq -r '.name' <<< "$entry") || return 1
        hash=$(jq -r '.sha256' <<< "$entry") || return 1
        size=$(wc -c < "$root/$name") || return 1
        [[ "${size//[[:space:]]/}" == "$(jq -r '.size' <<< "$entry")" &&
           "$(_slsa_sha256 "$root/$name")" == "$hash" ]] || {
            _rup_log "Payload differs from build manifest: $name"; return 7;
        }
    done <<< "$entries"
}

_rup_context_key() {
    jq -ceSs --arg repo "$2" --arg tag "$3" --arg sha "$4" '
        def id: type=="number" and .>0 and .<=9007199254740991 and .==floor;
        def text: type=="string" and length>0 and (test("[\\x00-\\x1f\\x7f]")|not);
        if length==1 and (.[0] |
            (.repository|type=="object" and (.id|id) and (.node_id|text) and .full_name==$repo) and
            (.release|type=="object" and (.id|id) and (.node_id|text) and .tag_name==$tag and
                (.draft|type=="boolean") and (.prerelease|type=="boolean") and (.target_commitish|text) and
                .upload_url==("https://uploads.github.com/repos/"+$repo+"/releases/"+(.id|tostring)+"/assets{?name,label}")) and
            .tag_commit==$sha)
        then .[0]|{repository,release:(.release|del(.draft)),tag_commit}
        else error("release does not match selected source") end' <<< "$1" 2>/dev/null
}

_rup_state_valid() {
    jq -es --argjson plan "$2" '
        length==1 and (.[0]|type=="object" and .schema_version==1 and
            .kind=="dsr-release-payload-state" and .plan==$plan and (.complete|type=="boolean") and
            (.assets|type=="array" and all(.[];
                . as $a | type=="object" and .state=="uploaded" and
                (.id|type=="number" and .>0 and .<=9007199254740991 and .==floor) and
                ([ $plan.artifacts[]|select(.name==$a.name and .size==$a.size and
                    ($a.digest==null or $a.digest=="" or $a.digest==("sha256:"+.sha256))) ]|length)==1)) and
            ((.assets|map(.name)|unique|length)==(.assets|length)) and
            ((.assets|map(.id)|unique|length)==(.assets|length)) and
            (if .complete then (.assets|map(.name)|sort)==($plan.artifacts|map(.name)|sort) else true end))
    ' "$1" >/dev/null 2>&1
}

_rup_save() {
    local file="$1" next="$2" expected="$3" plan="$4" work="$5" current=absent staged
    [[ ! -L "$file" ]] || return 2
    [[ ! -e "$file" ]] || current=$(_slsa_sha256 "$file") || return $?
    [[ "$current" == "$expected" ]] || { _rup_log 'Payload state changed'; return 2; }
    staged=$(mktemp "$work/state.XXXXXXXX") || return 1
    printf '%s\n' "$next" > "$staged" || return 1
    _rup_state_valid "$staged" "$plan" || return 2
    if [[ "$current" == absent ]]; then
        [[ ! -e "$file" && ! -L "$file" ]] || return 2
    else
        [[ "$(_slsa_sha256 "$file")" == "$current" ]] || return 2
    fi
    if [[ "$current" == absent ]]; then
        ln -- "$staged" "$file" 2>/dev/null || return 2
    elif ! cmp -s "$staged" "$file"; then
        mv -f -- "$staged" "$file" || return 1
    fi
    _slsa_sha256 "$file"
}

# Verify ALL occupied payload names before any upload. No digest mismatch may
# fall through to a weaker check; null API digest alone permits ID download.
_rup_preflight() {
    local repo="$1" inventory="$2" plan="$3" pinned="$4" work="$5"
    local entries entry name asset digest size actual expected suffix
    expected=$(jq -c '[.artifacts[].name]|sort' <<< "$plan") || return 1
    actual=$(_sbr_payload_names "$inventory") || return $?
    jq -en --argjson actual "$actual" --argjson expected "$expected" --argjson inventory "$inventory" --argjson pinned "$pinned" '
        ($actual-$expected|length)==0 and
        all($pinned[];. as $a | [$inventory[]|select(.name==$a.name)]==[$a])' >/dev/null || {
        _rup_log 'Unexpected payload or changed retained asset identity'; return 7;
    }
    entries=$(jq -c '.artifacts[]' <<< "$plan") || return 1
    while IFS= read -r entry; do
        name=$(jq -r '.name' <<< "$entry") || return 1
        asset=$(jq -c --arg name "$name" '[.[]|select(.name==$name)][0] // null' <<< "$inventory") || return 1
        if [[ "$asset" == null ]]; then
            for suffix in minisig sig asc; do
                jq -e --arg name "$name.$suffix" 'all(.[];.name!=$name)' <<< "$inventory" >/dev/null || {
                    _rup_log "Refusing payload with orphan signature: $name.$suffix"; return 7;
                }
            done
            continue
        fi
        digest=$(jq -r '.sha256' <<< "$entry") || return 1
        size=$(jq -r '.size' <<< "$entry") || return 1
        [[ "$(jq -r '.size' <<< "$asset")" == "$size" ]] || return 7
        _sbr_asset_digest "$asset" "$digest" || return $?
        if [[ -z "$(jq -r '.digest // ""' <<< "$asset")" ]]; then
            _sbr_download "$repo" "$asset" "$digest" "$work" false >/dev/null || return $?
        fi
    done <<< "$entries"
}

_rup_selected_assets() {
    jq -cS --argjson plan "$2" '[.[]|select(.name as $n|any($plan.artifacts[];.name==$n))]|sort_by(.name)' <<< "$1"
}

_rup_upload() {
    local url="$1" source="$2" entry="$3" receipt rc=0 name sha size
    name=$(jq -r '.name' <<< "$entry") || return 1
    sha=$(jq -r '.sha256' <<< "$entry") || return 1
    size=$(jq -r '.size' <<< "$entry") || return 1
    [[ "$(_slsa_sha256 "$source")" == "$sha" ]] || return 7
    receipt=$(_sbr_run gh_upload_asset_named "$url" "$source" "$name" application/octet-stream) || rc=$?
    if ((rc != 0)); then
        _rup_log "Payload upload failed; retry reconciles retained remote bytes: $name"
        return "$rc"
    fi
    jq -ceSs --arg name "$name" --arg sha "$sha" --argjson size "$size" '
        if length==1 and (.[0]|type=="object" and .name==$name and .state=="uploaded" and .size==$size and
            (.id|type=="number" and .>0 and .<=9007199254740991 and .==floor) and
            (.digest==null or .digest=="" or .digest==("sha256:"+$sha)))
        then .[0]|{id,name,state,size,digest} else error("invalid upload receipt") end' <<< "$receipt" || return 7
    [[ "$(_slsa_sha256 "$source")" == "$sha" ]] || return 7
}

# stdout is a receipt only after the complete payload set is independently read.
# The build manifest and private upload state are NEVER uploaded as assets.
release_upload_payloads() (
    set -uo pipefail
    umask 077
    local root="${1:-}" manifest='' repo='' tag='' sha='' state_dir='' dry="${DRY_RUN:-false}"
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build-manifest|--repo|--tag|--sha|--state-dir)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
                case "$1" in
                    --build-manifest) [[ -z "$manifest" ]] || return 4; manifest="$2" ;;
                    --repo) [[ -z "$repo" ]] || return 4; repo="$2" ;;
                    --tag) [[ -z "$tag" ]] || return 4; tag="$2" ;;
                    --sha) [[ -z "$sha" ]] || return 4; sha="$2" ;;
                    --state-dir) [[ -z "$state_dir" ]] || return 4; state_dir="$2" ;;
                esac
                shift 2 ;;
            --dry-run|-n) dry=true; shift ;;
            *) _rup_log "Unknown payload option: $1"; return 4 ;;
        esac
    done
    [[ -d "$root" && ! -L "$root" && "$root" != *[[:cntrl:]]* && "$root" != *\\* &&
       -f "$manifest" && ! -L "$manifest" && "$sha" =~ ^[0-9a-f]{40}$ &&
       "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.+-]+)?$ &&
       ( "$dry" == true || "$dry" == false ) ]] || return 4
    command -v jq >/dev/null || return 3
    _rup_require || return $?
    root=$(cd "$root" && pwd -P) || return 4
    local selection plan work cleanup entries entry name hash size context context_key key session file state oldhash
    local inventory current pinned names receipt uploaded=0 final fingerprint retained_complete=false
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-payload-stage.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q' "$work"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    selection=$(_rup_manifest "$manifest" "$repo" "$tag" "$sha") || return $?
    _rup_check_files "$root" "$manifest" "$selection" "$work" || return $?
    if [[ "$dry" == true ]]; then
        jq -nc --argjson plan "$selection" --arg repo "$repo" \
            '{kind:"dsr-release-payload-publication",status:"planned",dry_run:true,repo:$repo,plan:$plan}'
        return $?
    fi
    command -v flock >/dev/null || return 3
    _sbr_require || return $?
    if ! declare -F gh_upload_asset_named >/dev/null; then
        # shellcheck source=src/github.sh
        source "$_RELEASE_PAYLOADS_DIR/github.sh" || return 3
    fi
    # Snapshot EVERY payload before the first upload. Do not hardlink mutable inputs.
    mkdir "$work/payloads" || return 1
    entries=$(jq -c '.artifacts[]' <<< "$selection") || return 1
    while IFS= read -r entry; do
        name=$(jq -r '.name' <<< "$entry") || return 1
        cp -- "$root/$name" "$work/payloads/$name" || return 1
        chmod 400 "$work/payloads/$name" || return 1
    done <<< "$entries"
    _rup_check_files "$work/payloads" "$manifest" "$selection" "$work" || return $?
    _rup_check_files "$root" "$manifest" "$selection" "$work" || return $?
    context=$(_sbr_context "$repo" "$tag" "$work") || return $?
    context_key=$(_rup_context_key "$context" "$repo" "$tag" "$sha") || return 7
    plan=$(jq -cSn --argjson context "$context_key" --argjson selection "$selection" '$selection+{context:$context}') || return 1
    [[ -n "$state_dir" ]] || state_dir="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/release-payloads"
    [[ ! -L "$state_dir" && "$state_dir" != *[[:cntrl:]]* && "$state_dir" != *\\* ]] || return 4
    mkdir -p -- "$state_dir" || return 1
    state_dir=$(cd "$state_dir" && pwd -P) || return 4
    key=$(jq -cSn --arg repo "${repo,,}" --arg tag "$tag" '{repo:$repo,tag:$tag}') || return 1
    printf '%s' "$key" > "$work/key" || return 1
    key=$(_slsa_sha256 "$work/key") || return $?
    session="$state_dir/$key"
    [[ ! -L "$session" ]] || return 2
    mkdir -p -- "$session" || return 1
    [[ ! -L "$session/lock" && ( ! -e "$session/lock" || -f "$session/lock" ) ]] || return 2
    exec 7>> "$session/lock" || return 1
    flock -n 7 || { _rup_log 'Payload publication is already active'; return 2; }
    # State staging must be beside the destination, which may not share /tmp's FS.
    local state_work
    state_work=$(mktemp -d "$session/.work.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q %q' "$work" "$state_work"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    file="$session/state.json"; oldhash=absent; pinned='[]'
    [[ ! -L "$file" ]] || return 2
    if [[ -e "$file" ]]; then
        oldhash=$(_slsa_sha256 "$file") || return $?
        _rup_state_valid "$file" "$plan" || { _rup_log 'Invalid or conflicting payload plan'; return 2; }
        state=$(cat "$file") || return 1
        pinned=$(jq -cS '.assets' <<< "$state") || return 1
        retained_complete=$(jq -r '.complete' <<< "$state") || return 1
        [[ "$(_slsa_sha256 "$file")" == "$oldhash" ]] || return 2
    fi
    inventory=$(_sbr_inventory "$repo" "$(jq -r '.release.id' <<< "$context")" "$work") || return $?
    _rup_preflight "$repo" "$inventory" "$plan" "$pinned" "$work" || return $?
    names=$(jq -c '[.artifacts[].name]' <<< "$plan") || return 1
    current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$inventory" "$names" "$work") || return $?
    _rup_preflight "$repo" "$current" "$plan" "$pinned" "$work" || return $?
    pinned=$(_rup_selected_assets "$current" "$plan") || return 1
    if [[ "$(jq -r '.release.draft' <<< "$context")" != true &&
          "$(jq 'length' <<< "$pinned")" != "$(jq '.artifacts|length' <<< "$plan")" ]]; then
        _rup_log 'Missing payloads may only be uploaded to a draft release'; return 4
    fi
    state=$(jq -cSn --argjson plan "$plan" --argjson assets "$pinned" --argjson complete "$retained_complete" \
        '{schema_version:1,kind:"dsr-release-payload-state",plan:$plan,assets:$assets,complete:$complete}') || return 1
    oldhash=$(_rup_save "$file" "$state" "$oldhash" "$plan" "$state_work") || return $?
    while IFS= read -r entry; do
        name=$(jq -r '.name' <<< "$entry") || return 1
        _rup_check_files "$root" "$manifest" "$plan" "$work" || return $?
        _rup_check_files "$work/payloads" "$manifest" "$plan" "$work" || return $?
        [[ "$(_slsa_sha256 "$file")" == "$oldhash" ]] || return 2
        current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$current" "$names" "$work") || return $?
        _rup_preflight "$repo" "$current" "$plan" "$pinned" "$work" || return $?
        if ! jq -e --arg name "$name" 'any(.[];.name==$name)' <<< "$current" >/dev/null; then
            receipt=$(_rup_upload "$(jq -r '.release.upload_url' <<< "$context")" "$work/payloads/$name" "$entry") || return $?
            uploaded=$((uploaded + 1))
            current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$current" "$names" "$work") || return $?
            jq -en --argjson receipt "$receipt" --argjson current "$current" \
                'any($current[];.id==$receipt.id and .name==$receipt.name and .state=="uploaded" and .size==$receipt.size)' >/dev/null || return 7
            _rup_preflight "$repo" "$current" "$plan" "$pinned" "$work" || return $?
        fi
        pinned=$(_rup_selected_assets "$current" "$plan") || return 1
        state=$(jq -cS --argjson assets "$pinned" '.assets=$assets' <<< "$state") || return 1
        oldhash=$(_rup_save "$file" "$state" "$oldhash" "$plan" "$state_work") || return $?
    done <<< "$entries"
    _rup_check_files "$root" "$manifest" "$plan" "$work" || return $?
    _rup_check_files "$work/payloads" "$manifest" "$plan" "$work" || return $?
    final=$(_sbr_publication_gate "$repo" "$tag" "$context" "$current" "$names" "$work") || return $?
    [[ "$current" == "$final" && "$(jq 'length' <<< "$pinned")" == "$(jq '.artifacts|length' <<< "$plan")" ]] || return 7
    _rup_preflight "$repo" "$final" "$plan" "$pinned" "$work" || return $?
    state=$(jq -cS '.complete=true' <<< "$state") || return 1
    oldhash=$(_rup_save "$file" "$state" "$oldhash" "$plan" "$state_work") || return $?
    # Saving completion is not itself evidence of an unchanged remote release.
    final=$(_sbr_publication_gate "$repo" "$tag" "$context" "$current" "$names" "$work") || return $?
    [[ "$final" == "$current" && "$(_slsa_sha256 "$file")" == "$oldhash" ]] || return 7
    fingerprint=$(_sbr_inventory_sha256 "$final" "$work") || return $?
    jq -nc --argjson context "$context" --argjson plan "$selection" --argjson assets "$pinned" \
        --arg state "$file" --argjson uploaded "$uploaded" --arg fingerprint "$fingerprint" '
        {kind:"dsr-release-payload-publication",status:"verified",dry_run:false,
         repository:$context.repository,release:$context.release,tag_commit:$context.tag_commit,
         manifest_sha256:$plan.manifest_sha256,tool:$plan.tool,assets:$assets,
         asset_inventory_sha256:$fingerprint,state_file:$state,upload_attempts:$uploaded}'
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --help|-h|'') printf '%s\n' 'Usage: bash src/release_payloads.sh ARTIFACTS --build-manifest FILE --repo OWNER/REPO --tag vVERSION --sha COMMIT [--state-dir DIR] [--dry-run]' ;;
        *) release_upload_payloads "$@"; exit $? ;;
    esac
fi
