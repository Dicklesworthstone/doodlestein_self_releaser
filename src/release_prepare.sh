#!/usr/bin/env bash
# Recoverable, source-pinned draft creation for the verified release pipeline.
# Never create/move tags, publish, edit, delete, or upload release assets.

_RELEASE_PREPARE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_rp_log() { printf '[release-prepare] %s\n' "$*" >&2; }

_rp_require() {
    if ! declare -F _sbr_require >/dev/null; then
        # shellcheck source=src/sbom_release.sh
        source "$_RELEASE_PREPARE_DIR/sbom_release.sh" || return 3
    fi
    command -v flock >/dev/null && command -v gh >/dev/null || {
        _rp_log 'flock and gh are required'; return 3;
    }
    _sbr_require
}

_rp_hash() (
    set -o pipefail
    local digest
    if command -v sha256sum >/dev/null; then digest=$(sha256sum) || return 1
    elif command -v shasum >/dev/null; then digest=$(shasum -a 256) || return 1
    else return 3; fi
    digest=${digest%% *}
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
)

# Only a complete, valid listing establishes absence. Errors, duplicate IDs,
# repeated pages and ambiguous tags must never be interpreted as "create".
_rp_find() {
    local repo="$1" tag="$2" page response count ids id match found=null
    local -A seen=()
    for ((page=1; page<=100; page++)); do
        response=$(_sbr_api "repos/$repo/releases?per_page=100&page=$page") || return $?
        jq -es 'def id: type=="number" and .>0 and .<=9007199254740991 and .==floor;
            length==1 and (.[0]|type=="array" and length<=100 and
            all(.[];type=="object" and (.id|id) and (.tag_name|type=="string")))' \
            <<< "$response" >/dev/null 2>&1 || return 8
        ids=$(jq -r '.[].id' <<< "$response") || return 8
        if [[ -n "$ids" ]]; then
            while IFS= read -r id; do
                [[ -z "${seen[$id]:-}" ]] || { _rp_log 'Repeated release ID'; return 8; }
                seen[$id]=1
            done <<< "$ids"
        fi
        match=$(jq -c --arg tag "$tag" '[.[]|select(.tag_name==$tag)|.id]' <<< "$response") || return 8
        count=$(jq -r length <<< "$match") || return 8
        if ((count>1)) || { ((count==1)) && [[ "$found" != null ]]; }; then
            _rp_log 'More than one release has the selected tag'; return 2
        fi
        if ((count==1)); then found=$(jq -r '.[0]' <<< "$match") || return 8; fi
        count=$(jq -r length <<< "$response") || return 8
        if ((count<100)); then printf '%s\n' "$found"; return 0; fi
    done
    _rp_log 'Release listing exceeded the safety limit'; return 8
}

_rp_source() {
    local plan="$1" repo tag sha repository commit
    repo=$(jq -r .repo <<< "$plan") || return 1
    tag=$(jq -r .request.tag_name <<< "$plan") || return 1
    sha=$(jq -r .request.target_commitish <<< "$plan") || return 1
    repository=$(_sbr_api "repos/$repo") || return $?
    commit=$(_sbr_run gh_resolve_tag_sha "$repo" "$tag") || return $?
    [[ "$commit" == "$sha" ]] || { _rp_log 'Existing tag differs from the expected commit'; return 7; }
    jq -ecsS --arg repo "$repo" --arg sha "$sha" '
        def id: type=="number" and .>0 and .<=9007199254740991 and .==floor;
        if length==1 and (.[0]|type=="object" and (.id|id) and .full_name==$repo and
            (.node_id|type=="string" and length>0 and (test("[\\x00-\\x1f\\x7f]")|not)))
        then {repository:(.[0]|{id,node_id,full_name}),tag_commit:$sha}
        else error("invalid repository identity") end' <<< "$repository" 2>/dev/null || return 7
}

# Same context shape consumed by the existing payload/signature/SBOM finalizer.
# An existing release's target may be a branch; its *tag* is independently pinned.
_rp_context() {
    local plan="$1" source="$2" id="$3" release repo
    repo=$(jq -r .repo <<< "$plan") || return 1
    release=$(_sbr_api "repos/$repo/releases/$id") || return $?
    jq -ecsS --argjson plan "$plan" --argjson source "$source" --argjson id "$id" '
        def text: type=="string" and length>0 and (test("[\\x00-\\x1f\\x7f]")|not);
        if length==1 and (.[0]|type=="object" and .id==$id and (.node_id|text) and
            .tag_name==$plan.request.tag_name and (.draft|type=="boolean") and
            .prerelease==$plan.request.prerelease and (.target_commitish|text) and
            .name==$plan.request.name and (.body==null or (.body|type=="string")) and
            (.body//"")==$plan.request.body and
            .url==("https://api.github.com/repos/"+$plan.repo+"/releases/"+($id|tostring)) and
            .upload_url==("https://uploads.github.com/repos/"+$plan.repo+"/releases/"+($id|tostring)+"/assets{?name,label}"))
        then $source+{release:(.[0]|{id,node_id,tag_name,draft,prerelease,target_commitish,upload_url})}
        else error("release metadata differs from the selected draft") end' <<< "$release" 2>/dev/null || {
            _rp_log 'Release identity or metadata conflicts with the request'; return 2;
        }
}

_rp_state_valid() {
    jq -es --argjson plan "$2" '
        def id: type=="number" and .>0 and .<=9007199254740991 and .==floor;
        def text: type=="string" and length>0;
        length==1 and (.[0]|. as $s|type=="object" and .schema_version==1 and
            .kind=="dsr-release-preparation-state" and .plan==$plan and
            (.phase=="pending" or .phase=="sending" or .phase=="uncertain" or .phase=="prepared") and
            (.attempts|type=="number" and .>=0 and .<=9007199254740991 and .==floor) and
            (.source|type=="object" and .tag_commit==$plan.request.target_commitish and
                (.repository|type=="object" and (.id|id) and (.node_id|text) and .full_name==$plan.repo)) and
            (.candidate_id==null or (.candidate_id|id)) and
            (if .context==null then .phase!="prepared" else
                (.context|type=="object" and .repository==$s.source.repository and .tag_commit==$s.source.tag_commit and
                    (.release|type=="object" and (.id|id) and (.node_id|text) and (.draft|type=="boolean") and
                        .tag_name==$plan.request.tag_name and .prerelease==$plan.request.prerelease and
                        (.target_commitish|text) and
                        .upload_url==("https://uploads.github.com/repos/"+$plan.repo+"/releases/"+(.id|tostring)+"/assets{?name,label}")))
                and (.candidate_id==null or .context.release.id==.candidate_id) end) and
            (if .phase=="pending" then .attempts==0 and .candidate_id==null and .context==null else true end) and
            (if .phase=="sending" or .phase=="uncertain" then .attempts>0 else true end))' "$1" >/dev/null 2>&1
}

# Compare-before-replace also detects edits by non-cooperating local writers.
# The state directory is trusted local recovery storage, not a security boundary.
_rp_save() {
    local file="$1" state="$2" old="$3" plan="$4" tmp actual=absent
    [[ ! -L "$file" && ( ! -e "$file" || -f "$file" ) ]] || return 2
    if [[ -e "$file" ]]; then actual=$(_rp_hash < "$file") || return $?; fi
    [[ "$actual" == "$old" ]] || return 2
    tmp=$(mktemp "${file%/*}/.state.XXXXXXXX") || return 1
    printf '%s\n' "$state" > "$tmp" || return 1
    _rp_state_valid "$tmp" "$plan" || return 2
    chmod 600 "$tmp" || return 1
    [[ ! -L "$file" && ( ! -e "$file" || -f "$file" ) ]] || return 2
    actual=absent
    if [[ -e "$file" ]]; then actual=$(_rp_hash < "$file") || return $?; fi
    [[ "$actual" == "$old" ]] || return 2
    mv -f -- "$tmp" "$file" || return 1
    _rp_hash < "$file"
}

# Do not use gh_api's retry layer for a non-idempotent POST. The intent is already
# durable; even a lost success response is reconciled through independent reads.
_rp_post() {
    _sbr_run gh api --hostname github.com --method POST "repos/$1/releases" --input "$2"
}

_rp_execute() (
    set -uo pipefail
    local repo='' tag='' sha='' name='' notes='' root='' retry=false dry="${DRY_RUN:-false}" prerelease=false
    local -A seen=()
    while (($#)); do
        [[ -z "${seen[$1]:-}" ]] || { _rp_log "Repeated option: $1"; return 4; }
        seen[$1]=1
        case "$1" in
            --repo|--tag|--sha|--name|--notes-file|--state-dir)
                [[ $# -ge 2 && -n "$2" ]] || return 4
                case "$1" in
                    --repo) repo="$2" ;; --tag) tag="$2" ;; --sha) sha="${2,,}" ;;
                    --name) name="$2" ;; --notes-file) notes="$2" ;; --state-dir) root="$2" ;;
                esac
                shift 2 ;;
            --prerelease) prerelease=true; shift ;;
            --retry-uncertain) retry=true; shift ;;
            --dry-run) dry=true; shift ;;
            *) _rp_log "Unknown option: $1"; return 4 ;;
        esac
    done
    command -v jq >/dev/null && command -v git >/dev/null || return 3
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ &&
       "${repo#*/}" != . && "${repo#*/}" != .. && "$sha" =~ ^[0-9a-f]{40}$ &&
       -n "$tag" && "$tag" != -* && "$dry" =~ ^(true|false)$ ]] || return 4
    git check-ref-format "refs/tags/$tag" >/dev/null 2>&1 || return 4
    [[ -n "$name" ]] || name="$tag"
    [[ "$name" != *[[:cntrl:]]* && ${#name} -le 255 ]] || return 4
    [[ -n "$root" ]] || root="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/release-prepare"
    [[ "$root" != *[[:cntrl:]]* && "$root" != *\\* && ! -L "$root" ]] || return 4
    local body='""' plan
    if [[ -n "$notes" ]]; then
        [[ -f "$notes" && ! -L "$notes" ]] || return 4
        [[ $(wc -c < "$notes") -le 65536 ]] || return 4
        body=$(jq -Rse 'if contains("\u0000") then error("NUL in notes") else . end' "$notes") || return 4
    fi
    plan=$(jq -cnS --arg repo "$repo" --arg tag "$tag" --arg sha "$sha" --arg name "$name" \
        --argjson body "$body" --argjson prerelease "$prerelease" \
        '{repo:$repo,request:{tag_name:$tag,target_commitish:$sha,name:$name,body:$body,
            draft:true,prerelease:$prerelease,make_latest:"false"}}') || return 1
    if [[ "$dry" == true ]]; then
        jq -cn --argjson plan "$plan" '{kind:"dsr-release-preparation-result",status:"planned",exit_code:0,dry_run:true,plan:$plan}'
        return $?
    fi
    _rp_require || return $?
    umask 077
    mkdir -p -- "$root" || return 1
    root=$(cd "$root" && pwd -P) || return 1
    local key session file state old=absent source saved id context response='' post_rc=0 candidate=null request
    key=$(jq -cnS --arg repo "$repo" --arg tag "$tag" '{repo:$repo,tag:$tag}' | _rp_hash) || return $?
    session="$root/$key"
    [[ ! -L "$session" ]] || return 2
    mkdir -p -- "$session" || return 1
    [[ ! -L "$session/lock" && ( ! -e "$session/lock" || -f "$session/lock" ) ]] || return 2
    exec 9>> "$session/lock" || return 1
    flock -n 9 || { _rp_log 'Draft preparation is already active'; return 2; }
    file="$session/state.json"
    [[ ! -L "$file" && ( ! -e "$file" || -f "$file" ) ]] || return 2
    if [[ -e "$file" ]]; then
        old=$(_rp_hash < "$file") || return $?
        _rp_state_valid "$file" "$plan" || { _rp_log 'Conflicting or damaged preparation state'; return 2; }
        state=$(cat "$file") || return 1
        [[ "$(_rp_hash < "$file")" == "$old" ]] || return 2
    else
        state=null
    fi
    source=$(_rp_source "$plan") || return $?
    if [[ "$state" == null ]]; then
        state=$(jq -cnS --argjson plan "$plan" --argjson source "$source" \
            '{schema_version:1,kind:"dsr-release-preparation-state",plan:$plan,source:$source,
                phase:"pending",attempts:0,candidate_id:null,context:null}') || return 1
        old=$(_rp_save "$file" "$state" "$old" "$plan") || return $?
    else
        [[ "$(jq -cS .source <<< "$state")" == "$source" ]] || { _rp_log 'Repository identity changed'; return 2; }
    fi
    id=$(_rp_find "$repo" "$tag") || return $?
    if [[ "$id" == null ]]; then
        [[ "$(jq -r '.context==null and .candidate_id==null' <<< "$state")" == true ]] || {
            _rp_log 'A previously observed release disappeared; refusing replacement'; return 2;
        }
        if [[ "$(jq -r .phase <<< "$state")" != pending && "$retry" != true ]]; then
            _rp_log 'Creation outcome is uncertain; inspect GitHub before --retry-uncertain'; return 2
        fi
        [[ "$(_rp_source "$plan")" == "$source" ]] || return 7
        state=$(jq -cS '.phase="sending"|.attempts+=1' <<< "$state") || return 1
        old=$(_rp_save "$file" "$state" "$old" "$plan") || return $?
        request=$(mktemp "$session/.request.XXXXXXXX") || return 1
        jq -cS .request <<< "$plan" > "$request" || return 1
        chmod 400 "$request" || return 1
        # No mutation is allowed after an unpersisted or externally edited intent.
        [[ "$(_rp_hash < "$file")" == "$old" && "$(_rp_source "$plan")" == "$source" &&
           "$(_rp_hash < "$file")" == "$old" &&
           "$(_rp_hash < "$request")" == "$(jq -cS .request <<< "$plan" | _rp_hash)" ]] || return 2
        response=$(_rp_post "$repo" "$request" 2>/dev/null) || post_rc=$?
        if ((post_rc==0)); then
            candidate=$(jq -ers 'if length==1 and (.[0].id|type=="number" and .>0 and .<=9007199254740991 and .==floor)
                then .[0].id else null end' <<< "$response" 2>/dev/null) || candidate=null
        fi
        state=$(jq -cS --argjson candidate "$candidate" '.phase="uncertain"|.candidate_id=$candidate' <<< "$state") || return 1
        old=$(_rp_save "$file" "$state" "$old" "$plan") || return $?
        [[ "$(_rp_source "$plan")" == "$source" ]] || return 7
        id=$(_rp_find "$repo" "$tag") || return $?
        [[ "$id" != null ]] || {
            _rp_log 'Creation could not be confirmed; no automatic POST retry'; return 8;
        }
    fi
    candidate=$(jq -r '.candidate_id // "null"' <<< "$state") || return 1
    [[ "$candidate" == null || "$candidate" == "$id" ]] || return 2
    context=$(_rp_context "$plan" "$source" "$id") || return $?
    saved=$(jq -cS .context <<< "$state") || return 1
    if [[ "$saved" != null ]]; then
        [[ "$(jq -cS 'del(.release.draft)' <<< "$saved")" == "$(jq -cS 'del(.release.draft)' <<< "$context")" ]] || {
            _rp_log 'Previously bound release identity changed'; return 2;
        }
        [[ "$(jq -r .release.draft <<< "$saved")" == true || "$(jq -r .release.draft <<< "$context")" == false ]] || return 2
    else
        [[ "$(jq -r .release.draft <<< "$context")" == true ]] || {
            _rp_log 'An unbound published release cannot be adopted as a draft'; return 2;
        }
    fi
    # Check the full listing again, not just the selected ID: duplicate drafts
    # created by another machine must block handoff to finalization.
    [[ "$(_rp_source "$plan")" == "$source" && "$(_rp_find "$repo" "$tag")" == "$id" &&
       "$(_rp_context "$plan" "$source" "$id")" == "$context" ]] || return 7
    state=$(jq -cS --argjson context "$context" '.phase="prepared"|.context=$context' <<< "$state") || return 1
    old=$(_rp_save "$file" "$state" "$old" "$plan") || return $?
    jq -cn --argjson context "$context" --argjson attempts "$(jq -r .attempts <<< "$state")" --arg file "$file" \
        '{kind:"dsr-release-preparation-result",status:"prepared",exit_code:0,dry_run:false,
            context:$context,creation_attempts:$attempts,state_file:$file}'
)

release_prepare() (
    local result='' rc=0
    command -v jq >/dev/null || { _rp_log 'jq is required'; return 3; }
    result=$(_rp_execute "$@") || rc=$?
    if ((rc==0)) && ! jq -es 'length==1 and (.[0]|.kind=="dsr-release-preparation-result" and .exit_code==0)' \
        <<< "$result" >/dev/null 2>&1; then rc=1; fi
    if ((rc==0)); then printf '%s\n' "$result"
    else jq -cn --argjson rc "$rc" '{kind:"dsr-release-preparation-result",status:"error",exit_code:$rc}'; fi
    return "$rc"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --help|-h|'')
            printf '%s\n' 'Usage: bash src/release_prepare.sh --repo OWNER/REPO --tag TAG --sha FULL_COMMIT' \
                'Options: --name TITLE --notes-file FILE --prerelease --state-dir DIR --dry-run --retry-uncertain' \
                'Requires an existing source-pinned tag. Creates drafts only; never publishes or edits releases.' >&2 ;;
        *) release_prepare "$@"; exit $? ;;
    esac
fi
