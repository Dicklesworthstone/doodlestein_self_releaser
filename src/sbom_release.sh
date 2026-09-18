#!/usr/bin/env bash
# Remote release SBOM transport and verification (bd-1jt.3.4).
#
# This module connects the local SBOM inventory to actual GitHub release assets.
# It never treats a remote manifest as its own trust anchor. The caller chooses
# its SHA256 independently. GitHub API digests or downloaded immutable-ID bytes
# establish payload equality; SBOM documents are always downloaded and checked.
# This is not signature verification, scanner attestation or build provenance.

_SBOM_RELEASE_MODULE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
export _SBOM_RELEASE_MODULE_DIR

_sbr_require() {
    local module_dir="${_SBOM_RELEASE_MODULE_DIR:-}" token="" status
    [[ -n "$module_dir" && -d "$module_dir" ]] || return 3
    if ! declare -F _sbom_receipt_shape >/dev/null; then
        # shellcheck source=src/sbom.sh
        source "$module_dir/sbom.sh" || return 3
    fi
    command -v jq >/dev/null || { _sbom_log error 'jq is required'; return 3; }
    [[ "${SBOM_REMOTE_TIMEOUT:-900}" =~ ^[1-9][0-9]{0,4}$ &&
       "${SBOM_REMOTE_MAX_DOCUMENT_BYTES:-67108864}" =~ ^[1-9][0-9]{0,8}$ ]] || {
        _sbom_log error 'Invalid SBOM remote timeout/document-size limit'; return 4;
    }
    if ! declare -F gh_api >/dev/null || ! declare -F gh_download_release_asset >/dev/null ||
       ! declare -F gh_resolve_tag_sha >/dev/null; then
        # shellcheck source=src/github.sh
        source "$module_dir/github.sh" || return 3
    fi
    # DSR's public-GitHub URLs must not be mixed with an ambient Enterprise host
    # or a different gh CLI token precedence. Freeze one credential for this call.
    export GH_HOST=github.com
    token="${DSR_GH_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
    if [[ -z "$token" ]] && declare -F _gh_resolve_token >/dev/null; then
        if token=$(_sbr_run _gh_resolve_token); then :; else
            status=$?
            [[ "$status" -ne 5 ]] || return 5
            return 3
        fi
    fi
    [[ -n "$token" && "$token" != *[[:cntrl:]]* ]] || {
        _sbom_log error 'No usable public-GitHub credential'; return 3;
    }
    export DSR_GH_TOKEN="$token" GITHUB_TOKEN="$token" GH_TOKEN="$token"
}

# A scoped Bash process group bounds the adapter call, including its retries and
# descendants. No GNU-only timeout dependency and no changes to caller traps or
# job-control policy. Functions remain in the forked shell, not an exported shim.
_sbr_run() (
    local seconds="${SBOM_REMOTE_TIMEOUT:-900}" worker watcher status=0 cleanup
    [[ "$seconds" =~ ^[1-9][0-9]{0,4}$ ]] || return 4
    set -m
    "$@" &
    worker=$!
    (
        sleep "$seconds" || exit
        kill -TERM -- "-$worker" 2>/dev/null || exit
        sleep 1
        kill -KILL -- "-$worker" 2>/dev/null || true
    ) &
    watcher=$!
    printf -v cleanup 'kill -TERM -- -%s -%s 2>/dev/null || true; kill -KILL -- -%s -%s 2>/dev/null || true; wait %s %s 2>/dev/null || true' \
        "$worker" "$watcher" "$worker" "$watcher" "$worker" "$watcher"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    wait "$worker" 2>/dev/null || status=$?
    if ((status >= 128)); then
        _sbom_log error 'GitHub operation interrupted or exceeded SBOM_REMOTE_TIMEOUT'
        status=5
    fi
    exit "$status"
)

_sbr_api() {
    local response status
    if response=$(_sbr_run gh_api "$1" --no-cache); then
        :
    else
        status=$?
        _sbom_log error "GitHub read failed: $1"
        [[ "$status" -ne 5 ]] || return 5
        [[ "$status" -ne 3 ]] || return 3
        return 8
    fi
    jq -es 'length == 1' <<< "$response" >/dev/null 2>&1 || return 8
    printf '%s\n' "$response"
}

# Resolve drafts too, without relying on the truncated embedded .assets array
# or on a tag endpoint whose visibility differs for unpublished releases.
_sbr_release_for_tag() {
    local repo="$1" tag="$2" workdir="$3" page=1 response count ids id found="" match
    local -A seen=()
    while ((page <= 100)); do
        response=$(_sbr_api "repos/$repo/releases?per_page=100&page=$page") || return $?
        jq -e 'type == "array" and length <= 100 and all(.[];
            type == "object" and (.tag_name | type == "string") and
            (.id | type == "number" and . > 0 and . <= 9007199254740991 and . == floor))' \
            <<< "$response" >/dev/null 2>&1 || return 8
        ids=$(jq -r '.[].id' <<< "$response") || return 8
        if [[ -n "$ids" ]]; then
            while IFS= read -r id; do
                [[ -z "${seen[$id]:-}" ]] || {
                    _sbom_log error 'Repeated release ID across GitHub pages'; return 8;
                }
                seen["$id"]=1
            done <<< "$ids"
        fi
        match=$(jq -c --arg tag "$tag" '[.[] | select(.tag_name == $tag)]' <<< "$response") || return 8
        count=$(jq -r 'length' <<< "$match") || return 8
        if ((count > 1)) || { ((count == 1)) && [[ -n "$found" ]]; }; then
            _sbom_log error "Ambiguous release tag: $tag"; return 7
        fi
        if ((count == 1)); then found=$(jq -r '.[0].id' <<< "$match") || return 8; fi
        count=$(jq -r 'length' <<< "$response") || return 8
        if ((count < 100)); then
            [[ -n "$found" ]] || { _sbom_log error "Release not found: $repo $tag"; return 7; }
            printf '%s\n' "$found"
            return 0
        fi
        page=$((page + 1))
    done
    _sbom_log error 'Release listing exceeded the 100-page safety limit'
    return 8
}

# Freeze numeric repository/release identities, release mode, and the resolved
# tag commit. Existing tags are required; this command never creates a tag.
_sbr_context() {
    local repo="$1" tag="$2" workdir="$3" repository release release_id commit status
    repository=$(_sbr_api "repos/$repo") || return $?
    release_id=$(_sbr_release_for_tag "$repo" "$tag" "$workdir") || return $?
    release=$(_sbr_api "repos/$repo/releases/$release_id") || return $?
    if commit=$(_sbr_run gh_resolve_tag_sha "$repo" "$tag"); then :; else
        status=$?
        [[ "$status" -ne 5 ]] || return 5
        _sbom_log error "Cannot bind existing tag to a commit: $tag"; return 7
    fi
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 7
    jq -nceS --arg repo "$repo" --arg tag "$tag" --arg commit "$commit" \
        --argjson id "$release_id" --argjson repository "$repository" --argjson release "$release" '
        def id: type == "number" and . > 0 and . <= 9007199254740991 and . == floor;
        def text: type == "string" and length > 0 and (test("[\\x00-\\x1f\\x7f]") | not);
        if ($repository | type == "object" and (.id | id) and (.node_id | text) and .full_name == $repo) and
           ($release | type == "object" and .id == $id and (.node_id | text) and .tag_name == $tag and
             (.draft | type == "boolean") and (.prerelease | type == "boolean") and
             (.target_commitish | text) and
             .url == ("https://api.github.com/repos/" + $repo + "/releases/" + ($id|tostring)) and
             .upload_url == ("https://uploads.github.com/repos/" + $repo + "/releases/" + ($id|tostring) + "/assets{?name,label}"))
        then {repository:($repository | {id,node_id,full_name}),
              release:($release | {id,node_id,tag_name,draft,prerelease,target_commitish,upload_url}),
              tag_commit:$commit}
        else error("repository/release identity is not bound to the request") end
    ' 2>/dev/null || { _sbom_log error 'Invalid repository/release identity'; return 7; }
}

# Complete uncached asset inventory. Reject duplicate names/IDs and malformed
# rows across pages before any asset is trusted or any local path is selected.
_sbr_inventory() {
    local repo="$1" release_id="$2" workdir="$3" records response page=1 count
    records=$(mktemp "$workdir/inventory.XXXXXXXX") || return 1
    while ((page <= 100)); do
        response=$(_sbr_api "repos/$repo/releases/$release_id/assets?per_page=100&page=$page") || return $?
        jq -e 'def id: type == "number" and . > 0 and . <= 9007199254740991 and . == floor;
            def name: type == "string" and length > 0 and . != "." and . != ".." and
                (test("[/\\\\\\x00-\\x1f\\x7f]") | not);
            type == "array" and length <= 100 and all(.[];
                type == "object" and (.id | id) and (.name | name) and
                (.state == "uploaded" or .state == "starter") and
                (.size | type == "number" and . >= 0 and . <= 9007199254740991 and . == floor) and
                (.digest == null or (.digest | type == "string")))' \
            <<< "$response" >/dev/null 2>&1 || { _sbom_log error 'Invalid release asset inventory'; return 8; }
        jq -c '.[] | {id,name,state,size,digest}' <<< "$response" >> "$records" || return 1
        count=$(jq -r 'length' <<< "$response") || return 8
        if ((count < 100)); then
            jq -cse 'if (map(.name) | unique | length) == length and
                          (map(.id) | unique | length) == length
                     then sort_by(.name) else error("duplicate release asset") end' \
                "$records" 2>/dev/null || { _sbom_log error 'Duplicate release asset name or ID'; return 7; }
            return 0
        fi
        page=$((page + 1))
    done
    _sbom_log error 'Asset inventory exceeded the 100-page safety limit'
    return 8
}

_sbr_named_asset() {
    jq -ce --arg name "$2" '[.[] | select(.name == $name)] |
        if length == 1 then .[0] else error("missing or ambiguous asset") end' \
        <<< "$1" 2>/dev/null || { _sbom_log error "Missing release asset: $2"; return 7; }
}

_sbr_payload_names() {
    local inventory="$1" names name records=""
    names=$(jq -r '.[].name' <<< "$inventory") || return 8
    if [[ -n "$names" ]]; then
        while IFS= read -r name; do
            _sbom_is_metadata "$name" && continue
            records+="$(jq -nc --arg name "$name" '$name')"$'\n'
        done <<< "$names"
    fi
    jq -sc 'sort' <<< "$records"
}

# Validate any advertised digest without weakening to a download on mismatch or
# unknown algorithms. Missing/null digest alone permits the immutable-ID fallback.
_sbr_asset_digest() {
    local asset="$1" expected="$2" digest
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 4
    [[ "$(jq -r '.state' <<< "$asset")" == uploaded ]] || {
        _sbom_log error 'Release asset is not completely uploaded'; return 7;
    }
    digest=$(jq -r '.digest // ""' <<< "$asset") || return 8
    if [[ -n "$digest" && "$digest" != "sha256:$expected" ]]; then
        _sbom_log error "Release asset digest differs from the expected inventory: $(jq -r '.name' <<< "$asset")"
        return 7
    fi
}

# Always download documents, even when the API advertises their digest: the
# content must satisfy the document contract too. Body bytes never enter Bash.
_sbr_download() {
    local repo="$1" asset="$2" expected="$3" workdir="$4" is_document="${5:-true}"
    local size id directory file actual_size status
    _sbr_asset_digest "$asset" "$expected" || return $?
    size=$(jq -r '.size' <<< "$asset") || return 8
    id=$(jq -r '.id' <<< "$asset") || return 8
    if [[ "$is_document" == true ]] && ((size > ${SBOM_REMOTE_MAX_DOCUMENT_BYTES:-67108864})); then
        _sbom_log error 'SBOM document exceeds SBOM_REMOTE_MAX_DOCUMENT_BYTES'; return 7
    fi
    directory=$(mktemp -d "$workdir/download.XXXXXXXX") || return 1
    file="$directory/body"
    if _sbr_run gh_download_release_asset "$repo" "$id" "$file" >/dev/null; then :; else
        status=$?
        [[ "$status" -ne 5 ]] || return 5
        [[ "$status" -ne 3 ]] || return 3
        _sbom_log error "Could not download release asset ID $id"; return 8
    fi
    [[ -f "$file" && ! -L "$file" ]] || return 7
    actual_size=$(wc -c < "$file") || return 1
    actual_size="${actual_size//[[:space:]]/}"
    [[ "$actual_size" == "$size" && "$(_sbom_hash "$file")" == "$expected" ]] || {
        _sbom_log error "Downloaded release asset bytes do not match inventory: $id"; return 7;
    }
    chmod 400 "$file" || return 1
    printf '%s\n' "$file"
}

# Prove the EXACT selected payload namespace, not a few checksum spot checks.
# Files excluded by the local selection policy remain metadata remotely too.
_sbr_verify_payloads() {
    local repo="$1" inventory="$2" manifest="$3" workdir="$4"
    local expected actual entries entry name sha asset digest
    expected=$(jq -c '[.artifacts[].artifact.name] | sort' "$manifest") || return 7
    actual=$(_sbr_payload_names "$inventory") || return $?
    [[ "$actual" == "$expected" ]] || {
        _sbom_log error 'Remote payload set differs from the complete SBOM inventory'; return 7;
    }
    entries=$(jq -c '.artifacts[].artifact' "$manifest") || return 7
    while IFS= read -r entry; do
        name=$(jq -r '.name' <<< "$entry") || return 7
        sha=$(jq -r '.sha256' <<< "$entry") || return 7
        asset=$(_sbr_named_asset "$inventory" "$name") || return $?
        _sbr_asset_digest "$asset" "$sha" || return $?
        digest=$(jq -r '.digest // ""' <<< "$asset") || return 7
        if [[ -z "$digest" ]]; then
            _sbr_download "$repo" "$asset" "$sha" "$workdir" false >/dev/null || return $?
        fi
    done <<< "$entries"
}

_sbr_verify_documents() {
    local repo="$1" inventory="$2" manifest="$3" format="$4" workdir="$5"
    local entries entry name sha asset file
    entries=$(jq -c '.artifacts[].sbom' "$manifest") || return 7
    while IFS= read -r entry; do
        name=$(jq -r '.name' <<< "$entry") || return 7
        sha=$(jq -r '.sha256' <<< "$entry") || return 7
        asset=$(_sbr_named_asset "$inventory" "$name") || return $?
        file=$(_sbr_download "$repo" "$asset" "$sha" "$workdir") || return $?
        _sbom_validate "$file" "$format" || {
            _sbom_log error "Remote SBOM document does not satisfy $format contract: $name"; return 7;
        }
        [[ "$(_sbom_hash "$file")" == "$sha" ]] || return 7
    done <<< "$entries"
}

# Bind a verification receipt to all observed immutable IDs, including metadata
# newly added by this publication. Canonical JSON keeps the fingerprint stable
# across pagination order and callers without exposing the full inventory.
_sbr_inventory_sha256() {
    local inventory="$1" workdir="$2" file
    file=$(mktemp "$workdir/inventory-digest.XXXXXXXX") || return 1
    jq -cS 'sort_by(.name)' <<< "$inventory" > "$file" || return 1
    _sbom_hash "$file"
}

# Verify against one frozen context/inventory. The final uncached observations
# reject deleted/recreated IDs, moved tags, changed release modes and late assets.
_sbr_verify_remote() {
    local repo="$1" tag="$2" format="$3" expected="$4" workdir="$5"
    local context inventory release_id manifest_name asset manifest final_context final_inventory inventory_sha
    context=$(_sbr_context "$repo" "$tag" "$workdir") || return $?
    release_id=$(jq -r '.release.id' <<< "$context") || return 7
    inventory=$(_sbr_inventory "$repo" "$release_id" "$workdir") || return $?
    manifest_name="sbom-manifest.$(_sbom_extension "$format")"
    asset=$(_sbr_named_asset "$inventory" "$manifest_name") || return $?
    manifest=$(_sbr_download "$repo" "$asset" "$expected" "$workdir") || return $?
    _sbom_receipt_shape "$manifest" "$format" "$(_sbom_extension "$format")" release || {
        _sbom_log error 'Remote aggregate is not a complete SBOM inventory'; return 7;
    }
    _sbr_verify_payloads "$repo" "$inventory" "$manifest" "$workdir" || return $?
    _sbr_verify_documents "$repo" "$inventory" "$manifest" "$format" "$workdir" || return $?
    final_inventory=$(_sbr_inventory "$repo" "$release_id" "$workdir") || return $?
    final_context=$(_sbr_context "$repo" "$tag" "$workdir") || return $?
    [[ "$context" == "$final_context" && "$inventory" == "$final_inventory" &&
       "$(_sbom_hash "$manifest")" == "$expected" ]] || {
        _sbom_log error 'GitHub release, tag or asset inventory changed during verification'; return 7;
    }
    inventory_sha=$(_sbr_inventory_sha256 "$inventory" "$workdir") || return $?
    jq -nc --argjson context "$context" --arg format "$format" --arg sha "$expected" --arg inventory_sha "$inventory_sha" \
        --argjson asset "$asset" --argjson count "$(jq '.artifacts | length' "$manifest")" '
        {schema_version:1,kind:"dsr-sbom-remote-verification",status:"verified",
         repository:$context.repository,release:$context.release,tag_commit:$context.tag_commit,
         format:$format,manifest:{name:$asset.name,asset_id:$asset.id,sha256:$sha},
         artifact_count:$count,asset_inventory_sha256:$inventory_sha,
         verification_policy:"expected-manifest-sha256"}'
}

# Public remote verification deliberately requires an independently selected
# manifest SHA256, rather than accepting whatever proof the release happens to
# serve. It does not need local artifacts or Syft, and makes no remote writes.
# stdout: one JSON verification receipt on success; failures have no success JSON.
sbom_verify_release() (
    set -uo pipefail
    local repo="" tag="" format="${SBOM_DEFAULT_FORMAT:-spdx}" expected="" workdir
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo|--tag|--format|-f|--manifest-sha256)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
                case "$1" in
                    --repo) [[ -z "$repo" ]] || return 4; repo="$2" ;;
                    --tag) [[ -z "$tag" ]] || return 4; tag="$2" ;;
                    --format|-f) format="$2" ;;
                    --manifest-sha256) [[ -z "$expected" ]] || return 4; expected="$2" ;;
                esac
                shift 2 ;;
            *) printf 'Unknown remote SBOM option: %s\n' "$1" >&2; return 4 ;;
        esac
    done
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ &&
       "$tag" =~ ^v[A-Za-z0-9._+-]+$ && "$expected" =~ ^[0-9a-f]{64}$ ]] || {
        printf '%s\n' 'Expected --repo owner/repo --tag vVERSION --manifest-sha256 SHA256' >&2
        return 4
    }
    _sbr_require || return $?
    format=$(_sbom_format "$format") || return $?
    umask 077
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/dsr-sbom-remote.XXXXXXXX") || return 1
    # Freeze the path because function return can unwind local scope before EXIT.
    local cleanup
    printf -v cleanup 'rm -rf -- %q' "$workdir"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    _sbr_verify_remote "$repo" "$tag" "$format" "$expected" "$workdir"
)

# Snapshot only the public documents, not private scan plans/cache receipts or
# multi-gigabyte payloads. The local verifier binds all originals to this manifest.
_sbr_stage_publication() {
    local root="$1" output_dir="$2" format="$3" workdir="$4"
    local extension manifest sha after entries entry name digest size records
    extension=$(_sbom_extension "$format") || return $?
    manifest="$output_dir/sbom-manifest.$extension"
    sha=$(_sbom_hash "$manifest") || return $?
    sbom_verify_artifacts "$root" --format "$format" --output-dir "$output_dir" >/dev/null || return $?
    [[ "$(_sbom_hash "$manifest")" == "$sha" ]] || return 7
    mkdir "$workdir/proofs" || return 1
    cp -- "$manifest" "$workdir/proofs/sbom-manifest.$extension" || return 1
    [[ "$(_sbom_hash "$workdir/proofs/sbom-manifest.$extension")" == "$sha" ]] || return 7
    records="$workdir/documents.jsonl"
    : > "$records" || return 1
    entries=$(jq -c '.artifacts[].sbom' "$manifest") || return 1
    while IFS= read -r entry; do
        name=$(jq -r '.name' <<< "$entry") || return 1
        digest=$(jq -r '.sha256' <<< "$entry") || return 1
        # Match gh_upload_asset_named's actual filename contract before writes.
        [[ "$name" =~ ^[A-Za-z0-9._+-]+$ && "$name" != . && "$name" != .. ]] || {
            _sbom_log error "SBOM filename is not supported by the release uploader: $name"; return 4;
        }
        [[ -f "$output_dir/$name" && ! -L "$output_dir/$name" ]] || return 4
        cp -- "$output_dir/$name" "$workdir/proofs/$name" || return 1
        [[ "$(_sbom_hash "$workdir/proofs/$name")" == "$digest" ]] || return 7
        _sbom_validate "$workdir/proofs/$name" "$format" || return 7
        size=$(wc -c < "$workdir/proofs/$name") || return 1
        size="${size//[[:space:]]/}"
        ((size <= ${SBOM_REMOTE_MAX_DOCUMENT_BYTES:-67108864})) || return 4
        chmod 400 "$workdir/proofs/$name" || return 1
        jq -nc --arg name "$name" --arg sha "$digest" --argjson size "$size" \
            '{name:$name,sha256:$sha,size:$size}' >> "$records" || return 1
    done <<< "$entries"
    after=$(_sbom_hash "$manifest") || return $?
    [[ "$after" == "$sha" ]] || return 7
    size=$(wc -c < "$workdir/proofs/sbom-manifest.$extension") || return 1
    size="${size//[[:space:]]/}"
    ((size <= ${SBOM_REMOTE_MAX_DOCUMENT_BYTES:-67108864})) || return 4
    chmod 400 "$workdir/proofs/sbom-manifest.$extension" || return 1
    jq -cs --arg name "sbom-manifest.$extension" --arg sha "$sha" --argjson size "$size" \
        '{manifest:{name:$name,sha256:$sha,size:$size},documents:sort_by(.name)}' "$records"
}

_sbr_check_local_publication() {
    local root="$1" output_dir="$2" format="$3" plan="$4"
    local name expected
    name=$(jq -r '.manifest.name' <<< "$plan") || return 1
    expected=$(jq -r '.manifest.sha256' <<< "$plan") || return 1
    [[ "$(_sbom_hash "$output_dir/$name")" == "$expected" ]] || return 7
    sbom_verify_artifacts "$root" --format "$format" --output-dir "$output_dir" >/dev/null || return $?
    [[ "$(_sbom_hash "$output_dir/$name")" == "$expected" ]] || return 7
}

# All initially present assets must retain their complete identity/metadata.
# Only the explicitly planned SBOM names may appear during this publication.
_sbr_inventory_compatible() {
    jq -ne --argjson before "$1" --argjson after "$2" --argjson names "$3" '
        all($before[]; . as $item | [$after[] | select(.name == $item.name)] == [$item]) and
        ([$before[] | select(.name as $n | ($names | index($n)) == null)] ==
         [$after[] | select(.name as $n | ($names | index($n)) == null)])
    ' >/dev/null 2>&1 || {
        _sbom_log error 'Release inventory changed outside the planned SBOM additions'; return 7;
    }
}

_sbr_publication_gate() {
    local repo="$1" tag="$2" context="$3" inventory="$4" names="$5" workdir="$6"
    local observed current id
    id=$(jq -r '.release.id' <<< "$context") || return 7
    current=$(_sbr_inventory "$repo" "$id" "$workdir") || return $?
    observed=$(_sbr_context "$repo" "$tag" "$workdir") || return $?
    [[ "$observed" == "$context" ]] || {
        _sbom_log error 'Release or tag changed during SBOM publication'; return 7;
    }
    _sbr_inventory_compatible "$inventory" "$current" "$names" || return $?
    printf '%s\n' "$current"
}

# Preflight every existing target before the first upload. Present mismatches,
# starter assets and orphan signatures are conflicts, never clobber permission.
_sbr_preflight_publication() {
    local repo="$1" inventory="$2" plan="$3" format="$4" workdir="$5"
    local records entries entry name sha size asset body suffix count present=0 missing=0
    records=$(mktemp "$workdir/actions.XXXXXXXX") || return 1
    entries=$(jq -c '.documents[], .manifest' <<< "$plan") || return 1
    while IFS= read -r entry; do
        name=$(jq -r '.name' <<< "$entry") || return 1
        sha=$(jq -r '.sha256' <<< "$entry") || return 1
        size=$(jq -r '.size' <<< "$entry") || return 1
        asset=$(jq -c --arg name "$name" '[.[] | select(.name == $name)][0] // null' <<< "$inventory") || return 8
        if [[ "$asset" != null ]]; then
            [[ "$(jq -r '.size' <<< "$asset")" == "$size" ]] || return 7
            body=$(_sbr_download "$repo" "$asset" "$sha" "$workdir") || return $?
            [[ "$(_sbom_hash "$body")" == "$sha" ]] || return 7
            if [[ "$name" == "$(jq -r '.manifest.name' <<< "$plan")" ]]; then
                present=1
            else
                _sbom_validate "$body" "$format" || return 7
            fi
            jq -nc --argjson file "$entry" --argjson asset "$asset" \
                '$file + {action:"reuse",asset_id:$asset.id}' >> "$records" || return 1
        else
            for suffix in minisig sig asc; do
                count=$(jq --arg name "$name.$suffix" '[.[] | select(.name == $name)] | length' <<< "$inventory") || return 8
                [[ "$count" -eq 0 ]] || {
                    _sbom_log error "Refusing to attach new bytes to an orphan signature: $name.$suffix"; return 7;
                }
            done
            if [[ "$name" != "$(jq -r '.manifest.name' <<< "$plan")" ]]; then missing=$((missing + 1)); fi
            jq -nc --argjson file "$entry" '$file + {action:"upload",asset_id:null}' >> "$records" || return 1
        fi
    done <<< "$entries"
    if ((present == 1 && missing > 0)); then
        _sbom_log error 'A complete remote manifest already exists but its SBOM set is incomplete'
        return 7
    fi
    jq -sc '.' "$records"
}

_sbr_upload_document() {
    local upload_url="$1" file="$2" entry="$3" receipt name sha size status
    name=$(jq -r '.name' <<< "$entry") || return 1
    sha=$(jq -r '.sha256' <<< "$entry") || return 1
    size=$(jq -r '.size' <<< "$entry") || return 1
    [[ "$(_sbom_hash "$file")" == "$sha" ]] || return 7
    if receipt=$(_sbr_run gh_upload_asset_named "$upload_url" "$file" "$name" application/json); then :; else
        status=$?
        _sbom_log error "SBOM upload failed; completed assets remain available for retry: $name"
        return "$status"
    fi
    jq -es --arg name "$name" --arg sha "$sha" --argjson size "$size" '
        length == 1 and (.[0] | type == "object" and .name == $name and .state == "uploaded" and .size == $size and
        (.id | type == "number" and . > 0 and . <= 9007199254740991 and . == floor) and
        (.digest == null or .digest == "" or .digest == ("sha256:" + $sha)))' <<< "$receipt" >/dev/null 2>&1 || {
        _sbom_log error "Invalid SBOM upload receipt: $name"; return 7;
    }
    [[ "$(_sbom_hash "$file")" == "$sha" ]] || return 7
}

# Attach a verified local inventory to an EXISTING release, uploading documents
# before its aggregate. Payloads are compared, not uploaded, deleted or replaced.
# No tag/release creation, release-mode change, signing or Syft scan occurs.
# Defaults to drafts; public-release additions require explicit consent. A fully
# complete identical public release can always be verified on a read-only retry.
sbom_publish_artifacts() (
    set -uo pipefail
    local root="${1:-}" repo="" tag="" format="${SBOM_DEFAULT_FORMAT:-spdx}" output_dir="${SBOM_OUTPUT_DIR:-}"
    local dry_run="${DRY_RUN:-false}" allow_published=false
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo|--tag|--format|-f|--output-dir)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
                case "$1" in
                    --repo) [[ -z "$repo" ]] || return 4; repo="$2" ;;
                    --tag) [[ -z "$tag" ]] || return 4; tag="$2" ;;
                    --format|-f) format="$2" ;;
                    --output-dir) output_dir="$2" ;;
                esac
                shift 2 ;;
            --dry-run|-n) dry_run=true; shift ;;
            --allow-published) allow_published=true; shift ;;
            *) printf 'Unknown SBOM publication option: %s\n' "$1" >&2; return 4 ;;
        esac
    done
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$tag" =~ ^v[A-Za-z0-9._+-]+$ &&
       -d "$root" && ! -L "$root" && "$root" != *[[:cntrl:]]* && "$root" != *\\* &&
       ( "$dry_run" == true || "$dry_run" == false ) ]] || return 4
    _sbr_require || return $?
    if ! declare -F gh_upload_asset_named >/dev/null; then
        # shellcheck source=src/github.sh
        source "$_SBOM_RELEASE_MODULE_DIR/github.sh" || return 3
    fi
    format=$(_sbom_format "$format") || return $?
    root=$(cd "$root" && pwd -P) || return 4
    [[ -n "$output_dir" ]] || output_dir="$root"
    [[ -d "$output_dir" && ! -L "$output_dir" && "$output_dir" != *[[:cntrl:]]* && "$output_dir" != *\\* ]] || return 4
    output_dir=$(cd "$output_dir" && pwd -P) || return 4
    umask 077
    local workdir cleanup plan manifest sha context inventory release_id names actions current entries entry name
    local upload_url result observed verified_inventory upload_attempts=0 manifest_attempted=false manifest_action size asset
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/dsr-sbom-publish.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q' "$workdir"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    plan=$(_sbr_stage_publication "$root" "$output_dir" "$format" "$workdir") || return $?
    name=$(jq -r '.manifest.name' <<< "$plan") || return 1
    manifest="$workdir/proofs/$name"
    sha=$(jq -r '.manifest.sha256' <<< "$plan") || return 1
    names=$(jq -c '[.documents[].name, .manifest.name]' <<< "$plan") || return 1
    context=$(_sbr_context "$repo" "$tag" "$workdir") || return $?
    release_id=$(jq -r '.release.id' <<< "$context") || return 7
    upload_url=$(jq -r '.release.upload_url' <<< "$context") || return 7
    inventory=$(_sbr_inventory "$repo" "$release_id" "$workdir") || return $?
    _sbr_verify_payloads "$repo" "$inventory" "$manifest" "$workdir" || return $?
    entries=$(jq -r '.artifacts[].artifact.name' "$manifest") || return 1
    while IFS= read -r name; do
        size=$(wc -c < "$root/$name") || return 1
        size="${size//[[:space:]]/}"
        asset=$(_sbr_named_asset "$inventory" "$name") || return $?
        [[ "$(jq -r '.size' <<< "$asset")" == "$size" ]] || return 7
    done <<< "$entries"
    actions=$(_sbr_preflight_publication "$repo" "$inventory" "$plan" "$format" "$workdir") || return $?
    manifest_action=$(jq -r --arg name "$(jq -r '.manifest.name' <<< "$plan")" \
        '.[] | select(.name == $name) | .action' <<< "$actions") || return 1
    if [[ "$(jq -r '.release.draft' <<< "$context")" == false &&
          "$manifest_action" == upload && "$allow_published" != true ]]; then
        _sbom_log error 'Adding SBOMs to a published release requires --allow-published (drafts are the default)'
        return 4
    fi
    current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$inventory" "$names" "$workdir") || return $?
    _sbr_check_local_publication "$root" "$output_dir" "$format" "$plan" || return $?
    # A planned name may have been occupied while the first preflight ran.
    # Check the new observation before allowing any upload, not only at the end.
    actions=$(_sbr_preflight_publication "$repo" "$current" "$plan" "$format" "$workdir") || return $?
    manifest_action=$(jq -r --arg name "$(jq -r '.manifest.name' <<< "$plan")" \
        '.[] | select(.name == $name) | .action' <<< "$actions") || return 1
    if [[ "$dry_run" == true ]]; then
        jq -nc --argjson context "$context" --arg format "$format" --argjson actions "$actions" \
            --argjson manifest "$(jq -c '.manifest' <<< "$plan")" '
            {schema_version:1,kind:"dsr-sbom-publication",status:"planned",dry_run:true,
             repository:$context.repository,release:$context.release,tag_commit:$context.tag_commit,
             format:$format,manifest:$manifest,actions:$actions}'
        return $?
    fi
    if [[ "$manifest_action" == upload ]]; then
        entries=$(jq -c --arg manifest "$(jq -r '.manifest.name' <<< "$plan")" \
            '.[] | select(.name != $manifest and .action == "upload")' <<< "$actions") || return 1
        if [[ -n "$entries" ]]; then
            while IFS= read -r entry; do
                name=$(jq -r '.name' <<< "$entry") || return 1
                _sbr_upload_document "$upload_url" "$workdir/proofs/$name" "$entry" || return $?
                upload_attempts=$((upload_attempts + 1))
            done <<< "$entries"
        fi
        current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$inventory" "$names" "$workdir") || return $?
        verified_inventory="$current"
        _sbr_verify_documents "$repo" "$current" "$manifest" "$format" "$workdir" || return $?
        _sbr_check_local_publication "$root" "$output_dir" "$format" "$plan" || return $?
        # Re-observe after document downloads, immediately before the aggregate.
        current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$inventory" "$names" "$workdir") || return $?
        # Once the documents have been read, their IDs and metadata are frozen
        # too. Only an identical concurrent aggregate is allowed to appear now.
        _sbr_inventory_compatible "$verified_inventory" "$current" \
            "$(jq -c '[.manifest.name]' <<< "$plan")" || return $?
        entry=$(jq -c '.manifest' <<< "$plan") || return 1
        _sbr_upload_document "$upload_url" "$manifest" "$entry" || return $?
        manifest_attempted=true
    fi
    # Use the independent verifier, not POST success, as completion evidence.
    result=$(_sbr_verify_remote "$repo" "$tag" "$format" "$sha" "$workdir") || return $?
    observed=$(jq -cS '{repository,release,tag_commit}' <<< "$result") || return 7
    [[ "$observed" == "$context" ]] || return 7
    current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$inventory" "$names" "$workdir") || return $?
    [[ "$(_sbr_inventory_sha256 "$current" "$workdir")" == "$(jq -r '.asset_inventory_sha256' <<< "$result")" ]] || {
        _sbom_log error 'Final release inventory differs from the independently verified asset identities'; return 7;
    }
    _sbr_check_local_publication "$root" "$output_dir" "$format" "$plan" || return $?
    jq -nc --argjson verification "$result" --argjson attempts "$upload_attempts" --argjson manifest "$manifest_attempted" '
        {schema_version:1,kind:"dsr-sbom-publication",status:"verified",dry_run:false,
         sbom_upload_attempts:$attempts,manifest_upload_attempted:$manifest,verification:$verification}'
)

export -f sbom_publish_artifacts _sbr_stage_publication _sbr_check_local_publication
export -f _sbr_inventory_compatible _sbr_publication_gate _sbr_preflight_publication _sbr_upload_document
export -f sbom_verify_release _sbr_require _sbr_run _sbr_api _sbr_release_for_tag
export -f _sbr_context _sbr_inventory _sbr_named_asset _sbr_payload_names
export -f _sbr_asset_digest _sbr_download _sbr_verify_payloads _sbr_verify_documents _sbr_verify_remote
export -f _sbr_inventory_sha256

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    command_name="${1:-help}"
    [[ $# -gt 0 ]] && shift
    case "$command_name" in
        publish) sbom_publish_artifacts "$@" ;;
        verify) sbom_verify_release "$@" ;;
        help|--help|-h)
            printf '%s\n' \
                'Usage: bash src/sbom_release.sh publish ARTIFACTS --repo OWNER/REPO --tag vVERSION' \
                '       [--format spdx|cyclonedx] [--output-dir DIR] [--dry-run] [--allow-published]' \
                'Usage: bash src/sbom_release.sh verify --repo OWNER/REPO --tag vVERSION' \
                '       --manifest-sha256 SHA256 [--format spdx|cyclonedx]' \
                'The manifest digest must come from an independently trusted source.' \
                'Checks complete release payloads and SBOM documents; does not verify signatures.' ;;
        *) printf 'Unknown SBOM release command: %s\n' "$command_name" >&2; exit 4 ;;
    esac
    exit $?
fi
