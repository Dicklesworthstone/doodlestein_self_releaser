#!/usr/bin/env bash
# Authenticated release sets: payloads, checksums and detached Minisign proofs.
# A caller-selected public key is always required; a downloaded key is never
# a trust anchor. Build manifests remain private. No release/tag creation.
_RELEASE_INTEGRITY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_ri_log() { printf '[release-integrity] %s\n' "$*" >&2; }

_ri_require() {
    if ! declare -F _rup_manifest >/dev/null; then
        # shellcheck source=src/release_payloads.sh
        source "$_RELEASE_INTEGRITY_DIR/release_payloads.sh" || return 3
    fi
    _rup_require || return $?
    if ! declare -F signing_sign_exact >/dev/null; then
        # shellcheck source=src/signing.sh
        source "$_RELEASE_INTEGRITY_DIR/signing.sh" || return 3
    fi
    command -v jq >/dev/null || return 3
}

_ri_file_record() {
    local file="$1" name="$2" hash size
    hash=$(_slsa_sha256 "$file") || return $?
    size=$(wc -c < "$file") || return 1
    size="${size//[[:space:]]/}"
    jq -nc --arg name "$name" --arg hash "$hash" --argjson size "$size" \
        '{name:$name,sha256:$hash,size:$size}'
}

# Validate every path before following any manifest-selected filesystem name.
_ri_shape() {
    jq -es --arg repo "$2" --arg tag "$3" --arg sha "$4" --arg token "$5" '
        def text: type=="string" and length>0 and (test("[\\x00-\\x1f\\x7f]")|not);
        def name: text and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and (contains("..")|not);
        def hash: type=="string" and test("^[0-9a-f]{64}$") and length==64;
        def record: type=="object" and (.name|name) and (.sha256|hash) and
            (.size|type=="number" and .>0 and .<=9007199254740991 and .==floor);
        def signed_record: record and (.signature|record) and .signature.name==(.name+".minisig");
        length==1 and (.[0]|type=="object" and .schema_version==1 and
            .kind=="dsr-release-integrity" and .repository==$repo and .tag==$tag and
            .source_sha==$sha and (.tool|name) and (.build_manifest_sha256|hash) and
            .signer=={type:"minisign",public_key:$token} and
            (.artifacts|type=="array" and length>0 and all(.[];signed_record)) and
            ((.artifacts|map(.name)|unique|length)==(.artifacts|length)) and
            (.checksums|signed_record and .name=="checksums.sha256") and
            ([.artifacts[].name,.artifacts[].signature.name,.checksums.name,.checksums.signature.name,
              "release-integrity.json","release-integrity.json.minisig"] as $names |
             ($names|unique|length)==($names|length)))
    ' "$1" >/dev/null 2>&1
}

_ri_checksums() {
    jq -er '.artifacts|sort_by(.name)[]|.sha256+"  "+.name' "$1"
}

_ri_matches_selection() {
    jq -en --argjson selection "$2" --slurpfile m "$1" '
        ($m|length)==1 and $m[0].build_manifest_sha256==$selection.manifest_sha256 and
        $m[0].tool==$selection.tool and
        ($m[0].artifacts|map({name,sha256,size})|sort_by(.name))==$selection.artifacts
    ' >/dev/null 2>&1
}

_ri_check_record() {
    local file="$1" record="$2" actual
    actual=$(_ri_file_record "$file" "$(jq -r '.name' <<< "$record")") || return $?
    [[ "$(jq -cS . <<< "$actual")" == "$(jq -cS '{name,sha256,size}' <<< "$record")" ]] || return 7
}

# The complete signed set is checked twice at the public API boundaries. The
# master signature authenticates repository/tag/commit and all named sidecars;
# every individual payload/checksum signature is also cryptographically checked.
_ri_verify_set() {
    local root="$1" proofs="$2" repo="$3" tag="$4" sha="$5" token="$6" work="$7"
    local manifest="$proofs/release-integrity.json" before rows row name path signature
    before=$(_slsa_sha256 "$manifest") || return $?
    signing_verify_exact "$manifest" "$manifest.minisig" "$token" || return 7
    _ri_shape "$manifest" "$repo" "$tag" "$sha" "$token" || return 7
    rows=$(jq -c '.artifacts[],.checksums' "$manifest") || return 1
    while IFS= read -r row; do
        name=$(jq -r '.name' <<< "$row") || return 1
        if [[ "$name" == checksums.sha256 ]]; then path="$proofs/$name"
        else
            # Same payload selection policy as build uploads and SBOM inventory.
            _sbom_is_metadata "$name" && return 7
            path="$root/$name"
        fi
        _ri_check_record "$path" "$row" || return $?
        signature=$(jq -c '.signature' <<< "$row") || return 1
        _ri_check_record "$proofs/$name.minisig" "$signature" || return $?
        signing_verify_exact "$path" "$proofs/$name.minisig" "$token" || return 7
    done <<< "$rows"
    _ri_checksums "$manifest" > "$work/expected-checksums" || return 1
    cmp -s "$proofs/checksums.sha256" "$work/expected-checksums" || return 7
    [[ "$(_slsa_sha256 "$manifest")" == "$before" ]] || return 7
}

_ri_publish_file() {
    local staged="$1" output="$2"
    [[ ! -L "$output" && ( ! -e "$output" || -f "$output" ) ]] || return 2
    if [[ -f "$output" ]]; then
        cmp -s "$staged" "$output" || { _ri_log "Conflicting retained proof: $output"; return 2; }
    elif ! ln -- "$staged" "$output" 2>/dev/null; then
        [[ -f "$output" && ! -L "$output" ]] && cmp -s "$staged" "$output" || return 2
    fi
}

_ri_prepare() (
    local root="$1" manifest="$2" selection="$3" repo="$4" tag="$5" sha="$6"
    local token="$7" private="$8" output="$9" work cleanup name names path sig hash record rows checksum
    # A misconfigured secret-key path must not also be treated as a release
    # payload. Compare file identity (including hardlinks) before copying inputs,
    # publishing proofs or handing the selected set to the binary uploader.
    names=$(jq -r '.artifacts[].name' <<< "$selection") || return 1
    while IFS= read -r name; do
        if [[ -n "$private" && "$private" -ef "$root/$name" ]]; then
            _ri_log 'Signing key overlaps a selected release payload'; return 4
        fi
    done <<< "$names"
    # Staging belongs to the output filesystem; final publication never truncates.
    mkdir -p -- "$output" || return 1
    output=$(cd "$output" && pwd -P) || return 4
    work=$(mktemp -d "$output/.dsr-integrity.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q' "$work"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    if [[ -e "$output/release-integrity.json.minisig" || -L "$output/release-integrity.json.minisig" ]]; then
        _ri_verify_set "$root" "$output" "$repo" "$tag" "$sha" "$token" "$work" || return $?
        _ri_matches_selection "$output/release-integrity.json" "$selection" || return 2
        _rup_check_files "$root" "$manifest" "$selection" "$work" || return $?
        return 0
    fi
    mkdir "$work/payloads" "$work/proofs" || return 1
    printf '%s\n' "$selection" > "$work/selection.json" || return 1
    _ri_checksums "$work/selection.json" > "$work/proofs/checksums.sha256" || return 1
    # Snapshot every input and preflight ALL retained signatures before signing.
    while IFS= read -r name; do
        cp -- "$root/$name" "$work/payloads/$name" || return 1
    done <<< "$names"
    _rup_check_files "$work/payloads" "$manifest" "$selection" "$work" || return $?
    if [[ -e "$output/checksums.sha256" || -L "$output/checksums.sha256" ]]; then
        [[ -f "$output/checksums.sha256" && ! -L "$output/checksums.sha256" ]] &&
            cmp -s "$output/checksums.sha256" "$work/proofs/checksums.sha256" || return 2
    fi
    names+=$'\nchecksums.sha256'
    while IFS= read -r name; do
        path="$work/payloads/$name"
        [[ "$name" != checksums.sha256 ]] || path="$work/proofs/$name"
        sig="$output/$name.minisig"
        if [[ -e "$sig" || -L "$sig" ]]; then
            signing_verify_exact "$path" "$sig" "$token" || return 7
            cp -- "$sig" "$work/proofs/$name.minisig" || return 1
        fi
    done <<< "$names"
    while IFS= read -r name; do
        path="$work/payloads/$name"
        [[ "$name" != checksums.sha256 ]] || path="$work/proofs/$name"
        sig="$work/proofs/$name.minisig"
        if [[ ! -e "$sig" ]]; then
            hash=$(_slsa_sha256 "$path") || return $?
            signing_sign_exact "$path" "$sig" "$private" "$token" \
                "dsr release $repo $tag commit:$sha asset:$name" "$hash" || return $?
        fi
    done <<< "$names"
    rows="$work/records.jsonl"
    : > "$rows" || return 1
    while IFS= read -r name; do
        path="$work/payloads/$name"
        [[ "$name" != checksums.sha256 ]] || path="$work/proofs/$name"
        record=$(_ri_file_record "$path" "$name") || return $?
        sig=$(_ri_file_record "$work/proofs/$name.minisig" "$name.minisig") || return $?
        jq -nc --argjson record "$record" --argjson signature "$sig" \
            '$record+{signature:$signature}' >> "$rows" || return 1
    done <<< "$names"
    jq -cSs --arg repo "$repo" --arg tag "$tag" --arg sha "$sha" --arg token "$token" --argjson s "$selection" '
        {schema_version:1,kind:"dsr-release-integrity",repository:$repo,tag:$tag,source_sha:$sha,
         tool:$s.tool,build_manifest_sha256:$s.manifest_sha256,signer:{type:"minisign",public_key:$token},
         artifacts:(map(select(.name!="checksums.sha256"))|sort_by(.name)),
         checksums:(map(select(.name=="checksums.sha256"))[0])}' "$rows" > "$work/proofs/release-integrity.json" || return 1
    if [[ -e "$output/release-integrity.json" || -L "$output/release-integrity.json" ]]; then
        [[ -f "$output/release-integrity.json" && ! -L "$output/release-integrity.json" ]] &&
            cmp -s "$output/release-integrity.json" "$work/proofs/release-integrity.json" || return 2
    fi
    hash=$(_slsa_sha256 "$work/proofs/release-integrity.json") || return $?
    signing_sign_exact "$work/proofs/release-integrity.json" "$work/proofs/release-integrity.json.minisig" \
        "$private" "$token" "dsr release inventory $repo $tag commit:$sha" "$hash" || return $?
    _ri_verify_set "$work/payloads" "$work/proofs" "$repo" "$tag" "$sha" "$token" "$work" || return $?
    _ri_matches_selection "$work/proofs/release-integrity.json" "$selection" || return 2
    _rup_check_files "$root" "$manifest" "$selection" "$work" || return $?
    # The authenticated inventory is published last. Completed sidecars survive
    # any late failure; an identical retry verifies them instead of re-signing.
    while IFS= read -r name; do
        _ri_publish_file "$work/proofs/$name.minisig" "$output/$name.minisig" || return $?
    done <<< "$names"
    for name in checksums.sha256 release-integrity.json release-integrity.json.minisig; do
        _ri_publish_file "$work/proofs/$name" "$output/$name" || return $?
    done
    _ri_verify_set "$root" "$output" "$repo" "$tag" "$sha" "$token" "$work" || return $?
    _rup_check_files "$root" "$manifest" "$selection" "$work" || return $?
)

_ri_documents() {
    local proofs="$1" manifest="$1/release-integrity.json" main sig
    main=$(_ri_file_record "$manifest" release-integrity.json) || return $?
    sig=$(_ri_file_record "$manifest.minisig" release-integrity.json.minisig) || return $?
    jq -c --argjson main "$main" --argjson sig "$sig" \
        '[.artifacts[].signature,.checksums.signature,(.checksums|del(.signature)),$main,$sig]' "$manifest"
}

# The signature is untrusted until Minisign checks it; an API digest for it is
# merely a transport consistency check. No bytes are parsed as shell source.
_ri_download_unpinned() {
    local repo="$1" asset="$2" work="$3" path size digest actual
    [[ "$(jq -r '.state' <<< "$asset")" == uploaded ]] || return 7
    size=$(jq -r '.size' <<< "$asset") || return 7
    [[ "$size" =~ ^[1-9][0-9]{0,8}$ ]] && ((size <= ${SBOM_REMOTE_MAX_DOCUMENT_BYTES:-67108864})) || return 7
    digest=$(jq -r '.digest // ""' <<< "$asset") || return 7
    [[ -z "$digest" || "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 7
    path=$(mktemp -d "$work/unsigned.XXXXXXXX") || return 1
    path="$path/body"
    _sbr_run gh_download_release_asset "$repo" "$(jq -r '.id' <<< "$asset")" "$path" >/dev/null || return $?
    actual=$(_ri_file_record "$path" body) || return $?
    [[ "$(jq -r '.size' <<< "$actual")" == "$size" &&
       ( -z "$digest" || "$digest" == "sha256:$(jq -r '.sha256' <<< "$actual")" ) ]] || return 7
    printf '%s\n' "$path"
}

_ri_selected_assets() {
    jq -cS --argjson names "$2" '[.[]|select(.name as $n|$names|index($n)!=null)]|sort_by(.name)' <<< "$1"
}

# Signatures were checked against frozen bytes. Rehashing those exact inputs is
# sufficient at intermediate publication gates; do not repeat public-key crypto
# and full remote downloads for every unchanged sidecar in an N-file release.
_ri_local_unchanged() {
    local root="$1" proofs="$2" selection="$3" documents="$4" work="$5" names rows row name
    names=$(_sbom_select_artifacts "$root" "$work/local-list") || return $?
    [[ "$(jq -nc --arg names "$names" '$names|split("\n")|sort')" == \
       "$(jq -c '[.artifacts[].name]|sort' <<< "$selection")" ]] || return 7
    rows=$(jq -c '.artifacts[]' <<< "$selection") || return 1
    while IFS= read -r row; do
        name=$(jq -r '.name' <<< "$row") || return 1
        _ri_check_record "$root/$name" "$row" || return $?
    done <<< "$rows"
    rows=$(jq -c '.[]' <<< "$documents") || return 1
    while IFS= read -r row; do
        name=$(jq -r '.name' <<< "$row") || return 1
        _ri_check_record "$proofs/$name" "$row" || return $?
    done <<< "$rows"
}

_ri_remote_verify() (
    local repo="$1" tag="$2" sha="$3" token="$4" expected="$5" work="$6"
    local context inventory id asset file manifest before documents names entries row name hash current key
    context=$(_sbr_context "$repo" "$tag" "$work") || return $?
    key=$(_rup_context_key "$context" "$repo" "$tag" "$sha") || return 7
    id=$(jq -r '.release.id' <<< "$context") || return 7
    inventory=$(_sbr_inventory "$repo" "$id" "$work") || return $?
    mkdir "$work/proofs" "$work/payloads" || return 1
    for name in release-integrity.json release-integrity.json.minisig; do
        asset=$(_sbr_named_asset "$inventory" "$name") || return $?
        file=$(_ri_download_unpinned "$repo" "$asset" "$work") || return $?
        cp -- "$file" "$work/proofs/$name" || return 1
    done
    manifest="$work/proofs/release-integrity.json"
    before=$(_slsa_sha256 "$manifest") || return $?
    [[ -z "$expected" || "$before" == "$expected" ]] || return 7
    signing_verify_exact "$manifest" "$manifest.minisig" "$token" || return 7
    _ri_shape "$manifest" "$repo" "$tag" "$sha" "$token" || return 7
    names=$(jq -c '[.artifacts[].name]|sort' "$manifest") || return 1
    [[ "$(_sbr_payload_names "$inventory")" == "$names" ]] || return 7
    documents=$(_ri_documents "$work/proofs") || return $?
    entries=$(jq -c --argjson docs "$documents" '[.artifacts[]|del(.signature)]+$docs|.[]' "$manifest") || return 1
    while IFS= read -r row; do
        name=$(jq -r '.name' <<< "$row") || return 1
        case "$name" in release-integrity.json|release-integrity.json.minisig) continue ;; esac
        asset=$(_sbr_named_asset "$inventory" "$name") || return $?
        [[ "$(jq -r '.size' <<< "$asset")" == "$(jq -r '.size' <<< "$row")" ]] || return 7
        hash=$(jq -r '.sha256' <<< "$row") || return 1
        if jq -e --arg name "$name" 'index($name)!=null' <<< "$names" >/dev/null; then
            file=$(_sbr_download "$repo" "$asset" "$hash" "$work" false) || return $?
            cp -- "$file" "$work/payloads/$name" || return 1
        else
            file=$(_sbr_download "$repo" "$asset" "$hash" "$work" true) || return $?
            cp -- "$file" "$work/proofs/$name" || return 1
        fi
    done <<< "$entries"
    _ri_verify_set "$work/payloads" "$work/proofs" "$repo" "$tag" "$sha" "$token" "$work" || return $?
    current=$(_sbr_inventory "$repo" "$id" "$work") || return $?
    [[ "$inventory" == "$current" && "$(_sbr_context "$repo" "$tag" "$work")" == "$context" &&
       "$(_slsa_sha256 "$manifest")" == "$before" ]] || return 7
    names=$(jq -c --argjson docs "$documents" '[.artifacts[].name]+[$docs[].name]|sort' "$manifest") || return 1
    asset=$(_sbr_named_asset "$inventory" release-integrity.json) || return $?
    jq -nc --argjson context "$context" --arg token "$token" --arg hash "$before" --argjson asset "$asset" \
        --argjson assets "$(_ri_selected_assets "$inventory" "$names")" '
        {schema_version:1,kind:"dsr-release-integrity-verification",status:"verified",authenticated:true,
         verification_policy:"minisign-all-payloads-and-checksums",repository:$context.repository,
         release:$context.release,tag_commit:$context.tag_commit,public_key:$token,
         manifest:{name:"release-integrity.json",sha256:$hash,asset_id:$asset.id},assets:$assets}'
)

# Preflight every already occupied proof before any metadata POST. Wrong bytes
# are conflicts, not permission to replace a signature or weaken verification.
_ri_remote_preflight() {
    local repo="$1" inventory="$2" documents="$3" work="$4" known="${5:-[]}" row name asset body entries
    entries=$(jq -c '.[]' <<< "$documents") || return 1
    while IFS= read -r row; do
        name=$(jq -r '.name' <<< "$row") || return 1
        asset=$(jq -c --arg name "$name" '[.[]|select(.name==$name)][0] // null' <<< "$inventory") || return 1
        [[ "$asset" != null ]] || continue
        if jq -e --argjson asset "$asset" 'any(.[];.==$asset)' <<< "$known" >/dev/null; then continue; fi
        [[ "$(jq -r '.size' <<< "$asset")" == "$(jq -r '.size' <<< "$row")" ]] || return 7
        body=$(_sbr_download "$repo" "$asset" "$(jq -r '.sha256' <<< "$row")" "$work") || return $?
        _ri_check_record "$body" "$row" || return $?
    done <<< "$entries"
}

_ri_remote_publish() (
    local root="$1" proofs="$2" selection="$3" repo="$4" tag="$5" sha="$6" token="$7" work="$8"
    local manifest="$proofs/release-integrity.json" hash context inventory current names documents row name asset missing id
    local receipt observed verify_work upload_receipt before entries staged verified
    hash=$(_slsa_sha256 "$manifest") || return $?
    documents=$(_ri_documents "$proofs") || return $?
    entries=$(jq -c '.[]' <<< "$documents") || return 1
    staged="$work/public"
    mkdir "$staged" || return 1
    while IFS= read -r row; do
        name=$(jq -r '.name' <<< "$row") || return 1
        cp -- "$proofs/$name" "$staged/$name" || return 1
        _ri_check_record "$staged/$name" "$row" || return $?
        chmod 400 "$staged/$name" || return 1
    done <<< "$entries"
    _ri_verify_set "$root" "$staged" "$repo" "$tag" "$sha" "$token" "$work" || return $?
    names=$(jq -c '[.[].name]' <<< "$documents") || return 1
    context=$(_sbr_context "$repo" "$tag" "$work") || return $?
    _rup_context_key "$context" "$repo" "$tag" "$sha" >/dev/null || return 7
    id=$(jq -r '.release.id' <<< "$context") || return 7
    inventory=$(_sbr_inventory "$repo" "$id" "$work") || return $?
    _rup_preflight "$repo" "$inventory" "$selection" '[]' "$work" || return $?
    [[ "$(_sbr_payload_names "$inventory")" == "$(jq -c '[.artifacts[].name]|sort' <<< "$selection")" ]] || return 7
    _ri_remote_preflight "$repo" "$inventory" "$documents" "$work" || return $?
    verified="$inventory"
    missing=$(jq -nc --argjson names "$names" --argjson inventory "$inventory" '$names-[$inventory[].name]') || return 1
    if [[ "$missing" != '[]' && "$(jq -r '.release.draft' <<< "$context")" != true ]]; then
        _ri_log 'Missing integrity assets may be added only to a draft'; return 4
    fi
    # Never attach an unrelated document to an orphaned master signature.
    if jq -e 'any(.[];.name=="release-integrity.json.minisig") and all(.[];.name!="release-integrity.json")' \
        <<< "$inventory" >/dev/null; then return 7; fi
    current="$inventory"
    while IFS= read -r row; do
        name=$(jq -r '.name' <<< "$row") || return 1
        current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$current" "$names" "$work") || return $?
        _ri_remote_preflight "$repo" "$current" "$documents" "$work" "$verified" || return $?
        verified="$current"
        _ri_local_unchanged "$root" "$proofs" "$selection" "$documents" "$work" || return $?
        [[ "$(_slsa_sha256 "$manifest")" == "$hash" ]] || return 7
        asset=$(jq -c --arg name "$name" '[.[]|select(.name==$name)][0] // null' <<< "$current") || return 1
        [[ "$asset" == null ]] || continue
        before="$current"
        _ri_check_record "$staged/$name" "$row" || return $?
        upload_receipt=$(_sbr_run gh_upload_asset_named "$(jq -r '.release.upload_url' <<< "$context")" \
            "$staged/$name" "$name" application/octet-stream) || return $?
        _ri_check_record "$staged/$name" "$row" || return $?
        current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$before" "$names" "$work") || return $?
        observed=$(_sbr_named_asset "$current" "$name") || return $?
        jq -en --argjson observed "$observed" --argjson receipt "$upload_receipt" --argjson planned "$row" '
            ($receipt|type=="object") and $receipt.id==$observed.id and $receipt.name==$planned.name and
            $receipt.state=="uploaded" and $receipt.size==$planned.size' >/dev/null || return 7
        _ri_remote_preflight "$repo" "$current" "$documents" "$work" "$verified" || return $?
        verified="$current"
    done <<< "$entries"
    verify_work=$(mktemp -d "$work/verify.XXXXXXXX") || return 1
    receipt=$(_ri_remote_verify "$repo" "$tag" "$sha" "$token" "$hash" "$verify_work") || return $?
    observed=$(_sbr_publication_gate "$repo" "$tag" "$context" "$current" '[]' "$work") || return $?
    _ri_verify_set "$root" "$proofs" "$repo" "$tag" "$sha" "$token" "$work" || return $?
    [[ "$(_slsa_sha256 "$manifest")" == "$hash" ]] || return 7
    printf '%s\n' "$receipt"
)

_ri_execute() (
    set -uo pipefail
    umask 077
    local action="$1" root='' manifest='' repo='' tag='' sha='' public='' private='' output='' dry="${DRY_RUN:-false}" expected=''
    shift
    while (($#)); do
        case "$1" in
            --build-manifest|--repo|--tag|--sha|--public-key|--secret-key|--output-dir|--manifest-sha256)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
                case "$1" in
                    --build-manifest) [[ -z "$manifest" ]] || return 4; manifest="$2" ;;
                    --repo) [[ -z "$repo" ]] || return 4; repo="$2" ;;
                    --tag) [[ -z "$tag" ]] || return 4; tag="$2" ;;
                    --sha) [[ -z "$sha" ]] || return 4; sha="$2" ;;
                    --public-key) [[ -z "$public" ]] || return 4; public="$2" ;;
                    --secret-key) [[ -z "$private" ]] || return 4; private="$2" ;;
                    --output-dir) [[ -z "$output" ]] || return 4; output="$2" ;;
                    --manifest-sha256) [[ -z "$expected" ]] || return 4; expected="$2" ;;
                esac
                shift 2 ;;
            --dry-run|-n) dry=true; shift ;;
            -*) _ri_log "Unknown option: $1"; return 4 ;;
            *) [[ -z "$root" ]] || return 4; root="$1"; shift ;;
        esac
    done
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ &&
       "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.+-]+)?$ && "$sha" =~ ^[0-9a-f]{40}$ &&
       ( "$dry" == true || "$dry" == false ) && ( -z "$expected" || "$expected" =~ ^[0-9a-f]{64}$ ) ]] || return 4
    _ri_require || return $?
    local token work cleanup selection receipt hash
    token=$(signing_public_key_token "$public") || return $?
    if [[ "$action" != prepare && -n "$private" ]]; then
        _ri_log '--secret-key is only valid for prepare'; return 4
    fi
    if [[ "$action" == verify-release ]]; then
        [[ -z "$root$manifest$output" && "$dry" == false ]] || return 4
    elif [[ "$action" != prepare && "$action" != verify && "$action" != publish ]]; then
        return 4
    fi
    [[ -n "$private" ]] || private="${SIGNING_PRIVATE_KEY:-}"
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-integrity-check.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q' "$work"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    if [[ "$action" != verify-release ]]; then
        [[ -d "$root" && ! -L "$root" && "$root" != *[[:cntrl:]]* && "$root" != *\\* ]] || return 4
        root=$(cd "$root" && pwd -P) || return 4
        [[ -n "$output" ]] || output="$root"
        [[ ! -L "$output" && "$output" != *[[:cntrl:]]* && "$output" != *\\* ]] || return 4
        selection=$(_rup_manifest "$manifest" "$repo" "$tag" "$sha") || return $?
        _rup_check_files "$root" "$manifest" "$selection" "$work" || return $?
        if [[ "$dry" == true ]]; then
            jq -nc --arg action "$action" --arg repo "$repo" --arg token "$token" --argjson selection "$selection" \
                '{kind:"dsr-release-integrity-plan",status:"planned",dry_run:true,action:$action,repo:$repo,public_key:$token,selection:$selection}'
            return $?
        fi
        signing_require_minisign || return $?
        if [[ "$action" == prepare ]]; then
            _ri_prepare "$root" "$manifest" "$selection" "$repo" "$tag" "$sha" "$token" "$private" "$output" || return $?
        fi
        [[ -d "$output" ]] || return 4
        output=$(cd "$output" && pwd -P) || return 4
        _ri_verify_set "$root" "$output" "$repo" "$tag" "$sha" "$token" "$work" || return $?
        _ri_matches_selection "$output/release-integrity.json" "$selection" || return 2
        hash=$(_slsa_sha256 "$output/release-integrity.json") || return $?
        [[ -z "$expected" || "$expected" == "$hash" ]] || return 7
        if [[ "$action" == publish ]]; then
            _sbr_require || return $?
            receipt=$(_ri_remote_publish "$root" "$output" "$selection" "$repo" "$tag" "$sha" "$token" "$work") || return $?
        else
            receipt=$(jq -nc --arg repo "$repo" --arg tag "$tag" --arg sha "$sha" --arg token "$token" --arg hash "$hash" \
                --argjson selection "$selection" '{schema_version:1,kind:"dsr-release-integrity-local",status:"verified",authenticated:true,
                  repo:$repo,tag:$tag,source_sha:$sha,public_key:$token,manifest_sha256:$hash,selection:$selection}') || return 1
        fi
        _rup_check_files "$root" "$manifest" "$selection" "$work" || return $?
        [[ "$(_slsa_sha256 "$output/release-integrity.json")" == "$hash" ]] || return 7
    else
        signing_require_minisign || return $?
        _sbr_require || return $?
        receipt=$(_ri_remote_verify "$repo" "$tag" "$sha" "$token" "$expected" "$work") || return $?
    fi
    printf '%s\n' "$receipt"
)

release_prepare_integrity() { _ri_execute prepare "$@"; }
release_verify_integrity() { _ri_execute verify "$@"; }
release_publish_integrity() { _ri_execute publish "$@"; }
release_verify_remote_integrity() { _ri_execute verify-release "$@"; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-help}" in
        prepare|verify|publish|verify-release) _ri_execute "$@"; exit $? ;;
        help|--help|-h)
            printf '%s\n' 'Usage: bash src/release_integrity.sh prepare|verify|publish ARTIFACTS [options]' \
                'Required: --build-manifest FILE --repo OWNER/REPO --tag vVERSION --sha COMMIT --public-key FILE' \
                'Options: --output-dir DIR --secret-key FILE --manifest-sha256 SHA256 --dry-run' \
                'Remote: verify-release --repo OWNER/REPO --tag vVERSION --sha COMMIT --public-key FILE' \
                'Publishing requires existing payloads and a draft (or complete identical public retry).' ;;
        *) exit 4 ;;
    esac
fi
