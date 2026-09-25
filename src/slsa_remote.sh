#!/usr/bin/env bash
# Signed build-manifest provenance at the GitHub release boundary. Reuse the
# existing uncached/immutable-ID transport, never URLs embedded in a statement.
_SLSA_REMOTE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_slr_require() {
    # Public SLSA functions may be exported by a parent shell without their
    # private dependencies. A new CLI must still load a complete implementation.
    if ! declare -F slsa_verify_release >/dev/null || ! declare -F _slsa_sha256 >/dev/null ||
       ! declare -F _slsa_authenticate >/dev/null; then
        # shellcheck source=src/slsa.sh
        source "$_SLSA_REMOTE_DIR/slsa.sh" || return 3
    fi
    if [[ "${1:-remote}" != local ]] && ! declare -F _sbr_context >/dev/null; then
        # shellcheck source=src/sbom_release.sh
        source "$_SLSA_REMOTE_DIR/sbom_release.sh" || return 3
    fi
    command -v jq >/dev/null && command -v minisign >/dev/null || return 3
}

# Authentication precedes consumption of any statement-selected payload name.
# Require the caller's target matrix as well as signer/builder/source identity:
# a correctly signed subset must not redefine a complete multi-platform release.
_slr_policy() {
    local proof="$1" signature="$2" key="$3" policy="$4"
    _slsa_authenticate "$proof" "$key" "$signature" || return $?
    _slsa_validate "$proof" || return 7
    jq -es --slurpfile policy "$policy" '
        def text: type=="string" and length>0 and (test("[\u0000-\u001f\u007f]")|not);
        def hash: type=="string" and length==64 and test("^[0-9a-f]{64}$");
        def name: text and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and (contains("..")|not);
        $policy[0] as $p | length==1 and (.[0] | . as $s |
        .predicateType=="https://slsa.dev/provenance/v1" and
        .predicate.buildDefinition.buildType=="https://github.com/Dicklesworthstone/doodlestein_self_releaser/buildtype/manifest-v1" and
        .predicate.runDetails.builder.id==$p.builder and
        (.predicate.runDetails.metadata.invocationId|text) and
        ($p.invocation_id=="" or .predicate.runDetails.metadata.invocationId==$p.invocation_id) and
        .predicate.buildDefinition.externalParameters.repository==("https://github.com/"+$p.repo) and
        .predicate.buildDefinition.externalParameters.version==$p.tag and
        (.predicate.buildDefinition.externalParameters.targets|sort)==$p.targets and
        ([.predicate.buildDefinition.resolvedDependencies[]? |
          select(.uri==("https://github.com/"+$p.repo))] |
            length==1 and .[0].digest.gitCommit==$p.source_sha) and
        .dsr_evidence.kind=="build-manifest" and (.dsr_evidence.manifest_sha256|hash) and
        ($p.manifest_sha256=="" or .dsr_evidence.manifest_sha256==$p.manifest_sha256) and
        ([.predicate.runDetails.byproducts[]? | select(.name=="dsr-build-manifest")] |
            length==1 and .[0].digest.sha256==$s.dsr_evidence.manifest_sha256) and
        (.dsr_evidence.artifacts|type=="array" and length>0 and all(.[];
            (.name|name) and (.target|type=="string") and
            (.size_bytes|type=="number" and .>0 and .<=9007199254740991 and .==floor)) and
            (map(.name)|sort)==($s.subject|map(.name)|sort) and
            (map(.target)|unique|sort)==$p.targets))
    ' "$proof" >/dev/null 2>&1 || { _slsa_log 'Signed statement differs from the selected release policy'; return 7; }
}

# The signature is still untrusted at this stage. Restrict body size and digest
# syntax, download by numeric ID, then authenticate the exact downloaded bytes.
_slr_document() {
    local repo="$1" asset="$2" work="$3" limit="$4" dir body size hash expected rc=0
    jq -e --argjson limit "$limit" '
        .state=="uploaded" and (.id|type=="number" and .>0 and .==floor) and
        (.size|type=="number" and .>0 and .<=$limit and .==floor) and
        (.digest==null or .digest=="" or (.digest|type=="string" and length==71 and test("^sha256:[0-9a-f]{64}$")))
    ' <<< "$asset" >/dev/null || return 7
    dir=$(mktemp -d "$work/proof.XXXXXXXX") || return 1
    body="$dir/body"
    _sbr_run gh_download_release_asset "$repo" "$(jq -r .id <<< "$asset")" "$body" >/dev/null || rc=$?
    case "$rc" in 0) ;; 3|5) return "$rc" ;; *) return 8 ;; esac
    hash=$(_slsa_sha256 "$body") || return $?
    size=$(wc -c < "$body") || return 1
    expected=$(jq -r '.digest // ""' <<< "$asset") || return 1
    [[ "${size//[[:space:]]/}" == "$(jq -r .size <<< "$asset")" &&
       ( -z "$expected" || "$expected" == "sha256:$hash" ) ]] || return 7
    printf '%s\n' "$body"
}

# Always hash downloaded payload bytes, even when GitHub advertises a digest.
# The API digest remains a consistency check; a mismatch never downgrades to
# trusting a different read. No candidate executable is run.
_slr_payloads() {
    local repo="$1" inventory="$2" proof="$3" work="$4" names actual rows row name asset hash body
    names=$(jq -c '[.subject[].name]|sort' "$proof") || return 7
    actual=$(_sbr_payload_names "$inventory") || return $?
    [[ "$names" == "$actual" ]] || { _slsa_log 'Remote payload namespace differs from signed subjects'; return 7; }
    local limit="${SLSA_REMOTE_MAX_PAYLOAD_BYTES:-8589934592}"
    [[ "$limit" =~ ^[1-9][0-9]{0,15}$ ]] || return 4
    jq -e --argjson limit "$limit" '([.dsr_evidence.artifacts[].size_bytes]|add)<=$limit' "$proof" >/dev/null || {
        _slsa_log 'Signed payload set exceeds SLSA_REMOTE_MAX_PAYLOAD_BYTES'; return 7;
    }
    mkdir "$work/payloads" || return 1
    rows=$(jq -c '. as $s | .dsr_evidence.artifacts[] | . as $a |
        .+{sha256:($s.subject[]|select(.name==$a.name)|.digest.sha256)}' "$proof") || return 1
    # Preflight every name/size/digest before any potentially large body read.
    while IFS= read -r row; do
        name=$(jq -r .name <<< "$row") || return 1
        asset=$(_sbr_named_asset "$inventory" "$name") || return $?
        [[ "$(jq -r .size <<< "$asset")" == "$(jq -r .size_bytes <<< "$row")" ]] || return 7
        _sbr_asset_digest "$asset" "$(jq -r .sha256 <<< "$row")" || return $?
    done <<< "$rows"
    while IFS= read -r row; do
        name=$(jq -r .name <<< "$row") || return 1
        hash=$(jq -r .sha256 <<< "$row") || return 1
        asset=$(_sbr_named_asset "$inventory" "$name") || return $?
        body=$(_sbr_download "$repo" "$asset" "$hash" "$work" false) || return $?
        # Private hardlinks avoid doubling temporary storage. Neither pathname
        # aliases the publisher's source files or any caller-owned artifact.
        ln -- "$body" "$work/payloads/$name" || return 1
    done <<< "$rows"
}

_slr_verify_remote() {
    local policy="$1" key="$2" work="$3" repo tag sha builder name context inventory asset signature_asset proof signature
    local proof_hash signature_hash expected final_context final_inventory inventory_hash
    repo=$(jq -r .repo "$policy"); tag=$(jq -r .tag "$policy"); sha=$(jq -r .source_sha "$policy")
    builder=$(jq -r .builder "$policy"); name=$(jq -r .statement_name "$policy")
    context=$(_sbr_context "$repo" "$tag" "$work") || return $?
    [[ "$(jq -r .tag_commit <<< "$context")" == "$sha" ]] || { _slsa_log 'Remote tag moved from the selected commit'; return 7; }
    inventory=$(_sbr_inventory "$repo" "$(jq -r .release.id <<< "$context")" "$work") || return $?
    asset=$(_sbr_named_asset "$inventory" "$name") || return $?
    signature_asset=$(_sbr_named_asset "$inventory" "$name.minisig") || return $?
    proof=$(_slr_document "$repo" "$asset" "$work" "${SBOM_REMOTE_MAX_DOCUMENT_BYTES:-67108864}") || return $?
    signature=$(_slr_document "$repo" "$signature_asset" "$work" 65536) || return $?
    proof_hash=$(_slsa_sha256 "$proof") || return $?
    signature_hash=$(_slsa_sha256 "$signature") || return $?
    expected=$(jq -r .statement_sha256 "$policy") || return 1
    [[ -z "$expected" || "$expected" == "$proof_hash" ]] || return 7
    _slr_policy "$proof" "$signature" "$key" "$policy" || return $?
    _slr_payloads "$repo" "$inventory" "$proof" "$work" || return $?
    slsa_verify_release "$proof" "$work/payloads" --builder "$builder" --public-key "$key" --signature "$signature" \
        --source-repository "https://github.com/$repo" --source-commit "$sha" || return $?
    final_inventory=$(_sbr_inventory "$repo" "$(jq -r .release.id <<< "$context")" "$work") || return $?
    final_context=$(_sbr_context "$repo" "$tag" "$work") || return $?
    [[ "$inventory" == "$final_inventory" && "$context" == "$final_context" &&
       "$(_slsa_sha256 "$proof")" == "$proof_hash" && "$(_slsa_sha256 "$signature")" == "$signature_hash" ]] || {
        _slsa_log 'Release, tag, or provenance assets changed during verification'; return 7;
    }
    inventory_hash=$(_sbr_inventory_sha256 "$inventory" "$work") || return $?
    # A fetch retains exactly the bytes verified above, never another download
    # selected from the receipt. Ordinary verification/publication is unchanged.
    if [[ "${4:-false}" == true ]]; then
        mkdir "$work/snapshot" || return 1
        ln -- "$proof" "$work/snapshot/release.intoto.jsonl" || return 1
        ln -- "$signature" "$work/snapshot/release.intoto.jsonl.minisig" || return 1
        mv -- "$work/payloads" "$work/snapshot/artifacts" || return 1
    fi
    jq -cn --argjson context "$context" --argjson asset "$asset" --argjson signature "$signature_asset" \
        --arg proof_hash "$proof_hash" --arg signature_hash "$signature_hash" --arg inventory_hash "$inventory_hash" \
        --slurpfile policy "$policy" --slurpfile proof "$proof" '
        {schema_version:1,kind:"dsr-slsa-remote-verification",status:"verified",authenticated:true,
         repository:$context.repository,release:$context.release,tag_commit:$context.tag_commit,
         builder:$policy[0].builder,targets:$policy[0].targets,
         statement:{name:$asset.name,asset_id:$asset.id,sha256:$proof_hash},
         signature:{name:$signature.name,asset_id:$signature.id,sha256:$signature_hash},
         build_manifest_sha256:$proof[0].dsr_evidence.manifest_sha256,
         invocation_id:$proof[0].predicate.runDetails.metadata.invocationId,
         artifact_count:($proof[0].subject|length),asset_inventory_sha256:$inventory_hash,
         verification_policy:"trusted-minisign-slsa-v1-all-payload-bytes"}'
}

# Canonical local selections cannot redirect snapshot reads or publication.
_slr_path() {
    local path="$1" rest component current=''
    [[ "$path" == /* && "$path" != / && "$path" != */ &&
       "$path" != *[[:cntrl:]]* && "$path" != *\\* ]] || return 4
    rest=${path#/}
    while [[ -n "$rest" ]]; do
        component=${rest%%/*}
        [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 4
        current+="/$component"
        [[ ! -L "$current" ]] || return 4
        [[ "$rest" == */* ]] || break
        [[ ! -e "$current" || -d "$current" ]] || return 4
        rest=${rest#*/}
    done
}

_slr_snapshot_names() {
    local root="$1" proof="$2" listing="$3" file name names='[]'
    _slr_path "$root/artifacts" && [[ -d "$root/artifacts" ]] || return 7
    # Include dotfiles in exact-namespace admission; never glob to choose which
    # payloads are trusted. The signed statement chooses the complete set.
    find "$root/artifacts" -mindepth 1 -maxdepth 1 -print0 > "$listing" || return 7
    while IFS= read -r -d '' file; do
        name=${file##*/}
        [[ -f "$file" && ! -L "$file" ]] && _slsa_name "$name" || return 7
        names=$(jq -cn --argjson names "$names" --arg name "$name" '$names+[$name]') || return 1
    done < "$listing"
    jq -en --argjson names "$names" --slurpfile proof "$proof" \
        '($names|sort)==($proof[0].subject|map(.name)|sort)' >/dev/null || return 7
}

# Offline authentication does not inherit trust from download.json or from an
# embedded key/policy. Every invocation supplies its own complete trust policy.
_slr_verify_snapshot() {
    local policy="$1" key="$2" root="$3" work="$4" proof signature proof_hash signature_hash expected file count=0
    _slr_path "$root" && [[ -d "$root" ]] || return 4
    for file in "$root"/* "$root"/.[!.]* "$root"/..?*; do
        [[ -e "$file" || -L "$file" ]] || continue
        case "${file##*/}" in
            artifacts) [[ -d "$file" && ! -L "$file" ]] || return 7 ;;
            release.intoto.jsonl|release.intoto.jsonl.minisig|download.json)
                [[ -f "$file" && ! -L "$file" ]] || return 7 ;;
            *) return 7 ;;
        esac
        count=$((count+1))
    done
    [[ "$count" == 4 ]] || return 7
    proof="$root/release.intoto.jsonl"; signature="$proof.minisig"
    [[ $(wc -c < "$proof") -le 67108864 && $(wc -c < "$signature") -le 65536 ]] || return 7
    proof_hash=$(_slsa_sha256 "$proof") || return $?
    signature_hash=$(_slsa_sha256 "$signature") || return $?
    expected=$(jq -r .statement_sha256 "$policy") || return 1
    [[ -z "$expected" || "$expected" == "$proof_hash" ]] || return 7
    _slr_policy "$proof" "$signature" "$key" "$policy" || return $?
    local limit="${SLSA_REMOTE_MAX_PAYLOAD_BYTES:-8589934592}"
    [[ "$limit" =~ ^[1-9][0-9]{0,15}$ ]] || return 4
    jq -e --argjson limit "$limit" '.dsr_evidence.artifacts |
        length<=256 and (map(.name|ascii_downcase)|unique|length)==length and
        all(.[]; (.name|length<=128) and
            (.archive_format|.=="binary" or .=="none" or .=="tar.gz" or .=="tar.xz" or .=="zip")) and
        (map(.size_bytes)|add)<=$limit' "$proof" >/dev/null || return 7
    _slr_snapshot_names "$root" "$proof" "$work/snapshot-names" || return $?
    slsa_verify_release "$proof" "$root/artifacts" --builder "$(jq -r .builder "$policy")" \
        --public-key "$key" --signature "$signature" \
        --source-repository "https://github.com/$(jq -r .repo "$policy")" \
        --source-commit "$(jq -r .source_sha "$policy")" || return $?
    _slr_snapshot_names "$root" "$proof" "$work/snapshot-names" || return $?
    [[ "$(_slsa_sha256 "$proof")" == "$proof_hash" && "$(_slsa_sha256 "$signature")" == "$signature_hash" ]] || return 7
    jq -cnS --arg proof_hash "$proof_hash" --arg signature_hash "$signature_hash" --slurpfile proof "$proof" '
        $proof[0] as $s | {statement_sha256:$proof_hash,signature_sha256:$signature_hash,
        artifacts:($s.dsr_evidence.artifacts|sort_by(.name)|map(. as $a |
            .+{sha256:($s.subject[]|select(.name==$a.name)|.digest.sha256)}))}' > "$work/snapshot-identity.json" || return 1
    jq -cn --arg root "$root" --arg hash "$(_slsa_sha256 "$work/snapshot-identity.json")" \
        --slurpfile identity "$work/snapshot-identity.json" --slurpfile policy "$policy" --slurpfile proof "$proof" '
        {kind:"dsr-slsa-snapshot-verification",status:"verified",authenticated:true,remote_current:false,
         snapshot:$root,snapshot_sha256:$hash,policy:$policy[0],
         build_manifest_sha256:$proof[0].dsr_evidence.manifest_sha256,
         invocation_id:$proof[0].predicate.runDetails.metadata.invocationId} + $identity[0]'
}

# Present proof names must match the frozen pair before ANY upload. A signature
# without its statement is a conflict, not permission to attach different bytes.
_slr_existing() {
    local repo="$1" inventory="$2" records="$3" work="$4" row asset body
    while IFS= read -r row; do
        asset=$(jq -c --arg name "$(jq -r .name <<< "$row")" '[.[]|select(.name==$name)]' <<< "$inventory") || return 1
        [[ $(jq length <<< "$asset") -le 1 ]] || return 7
        [[ "$asset" != '[]' ]] || continue
        asset=$(jq -c '.[0]' <<< "$asset") || return 1
        [[ $(jq -r .size <<< "$asset") == "$(jq -r .size <<< "$row")" ]] || return 7
        body=$(_sbr_download "$repo" "$asset" "$(jq -r .sha256 <<< "$row")" "$work") || return $?
        [[ "$(_slsa_sha256 "$body")" == "$(jq -r .sha256 <<< "$row")" ]] || return 7
    done < "$records"
}

_slr_publish() {
    local policy="$1" key="$2" work="$3" original_proof="$4" original_signature="$5" root="$6"
    local repo tag sha name context inventory current names row asset receipt file proof_hash signature_hash verify_work
    local uploaded=0
    # One POST per missing name. Reconcile ambiguous outcomes by reading the
    # release on retry, not through the lower-level uploader's automatic POSTs.
    # shellcheck disable=SC2034 # Consumed by gh_upload_asset_named.
    local GH_MAX_RETRIES=1
    repo=$(jq -r .repo "$policy") || return 1
    tag=$(jq -r .tag "$policy") || return 1
    sha=$(jq -r .source_sha "$policy") || return 1
    name=$(jq -r .statement_name "$policy") || return 1
    proof_hash=$(_slsa_sha256 "$work/statement") || return $?
    signature_hash=$(_slsa_sha256 "$work/signature") || return $?
    names=$(jq -cn --arg name "$name" '[$name,($name+".minisig")]') || return 1
    # Freeze document records once; hashes may never be reselected during retry.
    : > "$work/documents.jsonl" || return 1
    for file in statement signature; do
        local remote_name="$name"
        [[ "$file" != signature ]] || remote_name+=.minisig
        jq -cn --arg name "$remote_name" --arg sha "$(_slsa_sha256 "$work/$file")" \
            --arg file "$file" --argjson size "$(wc -c < "$work/$file")" \
            '{name:$name,sha256:$sha,size:$size,file:$file}' >> "$work/documents.jsonl" || return 1
    done
    context=$(_sbr_context "$repo" "$tag" "$work") || return $?
    [[ $(jq -r .tag_commit <<< "$context") == "$sha" ]] || return 7
    inventory=$(_sbr_inventory "$repo" "$(jq -r .release.id <<< "$context")" "$work") || return $?
    if jq -e --arg name "$name" 'any(.[];.name==($name+".minisig")) and all(.[];.name!=$name)' <<< "$inventory" >/dev/null; then
        _slsa_log 'Orphan remote provenance signature'; return 7
    fi
    _slr_existing "$repo" "$inventory" "$work/documents.jsonl" "$work" || return $?
    # All payloads must already exist and match before provenance is attached.
    # This command uploads no binaries, private manifests, keys or local state.
    _slr_payloads "$repo" "$inventory" "$work/statement" "$work" || return $?
    current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$inventory" "$names" "$work") || return $?
    if [[ $(jq -r .release.draft <<< "$context") != true ]] &&
       ! jq -en --argjson names "$names" --argjson inventory "$current" \
            'all($names[];. as $n|any($inventory[];.name==$n))' >/dev/null; then
        _slsa_log 'Missing provenance may only be attached to a draft'; return 4
    fi
    if ! declare -F gh_upload_asset_named >/dev/null; then
        # shellcheck source=src/github.sh
        source "$_SLSA_REMOTE_DIR/github.sh" || return 3
    fi
    while IFS= read -r row; do
        [[ "$(_slsa_sha256 "$original_proof")" == "$proof_hash" &&
           "$(_slsa_sha256 "$original_signature")" == "$signature_hash" ]] || return 7
        _slsa_release_assets "$work/statement" "$root" || return $?
        current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$current" "$names" "$work") || return $?
        _slr_existing "$repo" "$current" "$work/documents.jsonl" "$work" || return $?
        file=$(jq -r .file <<< "$row") || return 1
        asset=$(jq -c --arg name "$(jq -r .name <<< "$row")" '[.[]|select(.name==$name)]' <<< "$current") || return 1
        [[ "$asset" == '[]' ]] || continue
        [[ "$(_slsa_sha256 "$work/$file")" == "$(jq -r .sha256 <<< "$row")" ]] || return 7
        # Upload statement first, detached signature last. A lost transport
        # acknowledgement returns failure; repeating the command reads and
        # verifies occupied names rather than deleting or clobbering them.
        receipt=$(_sbr_run gh_upload_asset_named "$(jq -r .release.upload_url <<< "$context")" \
            "$work/$file" "$(jq -r .name <<< "$row")" application/octet-stream) || return $?
        uploaded=$((uploaded+1))
        jq -es --argjson row "$row" 'length==1 and (.[0]|.name==$row.name and .size==$row.size and
            .state=="uploaded" and (.id|type=="number" and .>0 and .==floor) and
            (.digest==null or .digest=="" or .digest==("sha256:"+$row.sha256)))' <<< "$receipt" >/dev/null || return 7
        current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$current" "$names" "$work") || return $?
        asset=$(_sbr_named_asset "$current" "$(jq -r .name <<< "$row")") || return $?
        [[ $(jq -r .id <<< "$asset") == "$(jq -r .id <<< "$receipt")" ]] || return 7
        _slr_existing "$repo" "$current" "$work/documents.jsonl" "$work" || return $?
    done < "$work/documents.jsonl"
    # Independent final download/signature/payload verification, constrained to
    # the original statement hash and the same complete release observation.
    verify_work=$(mktemp -d "$work/verify.XXXXXXXX") || return 1
    _slr_verify_remote "$policy" "$key" "$verify_work" > "$work/verification.json" || return $?
    jq -e --argjson context "$context" --arg inventory "$(_sbr_inventory_sha256 "$current" "$work")" '
        .repository==$context.repository and .release==$context.release and .tag_commit==$context.tag_commit and
        .asset_inventory_sha256==$inventory' "$work/verification.json" >/dev/null || return 7
    _sbr_publication_gate "$repo" "$tag" "$context" "$current" '[]' "$work" >/dev/null || return $?
    [[ "$(_slsa_sha256 "$original_proof")" == "$proof_hash" &&
       "$(_slsa_sha256 "$original_signature")" == "$signature_hash" &&
       $(jq -r .signature.sha256 "$work/verification.json") == "$signature_hash" ]] || return 7
    _slsa_release_assets "$work/statement" "$root" || return $?
    jq -cn --argjson uploaded "$uploaded" --slurpfile verification "$work/verification.json" \
        '{kind:"dsr-slsa-publication",status:"verified",dry_run:false,upload_attempts:$uploaded,
          verification:$verification[0]}'
}

# Public-GitHub only. Publishing consumes already-signed proof, not a private
# signing key. Both paths withhold stdout until local and remote gates finish.
_slr_execute() (
    set -uo pipefail
    umask 077
    local action="$1" local_proof='' local_signature='' root='' dry=false output=''
    shift
    if [[ "$action" == publish ]]; then
        [[ $# -ge 2 ]] || return 4
        local_proof=$1; root=$2; shift 2
        dry="${DRY_RUN:-false}"
        [[ -f "$local_proof" && ! -L "$local_proof" && -d "$root" && ! -L "$root" ]] || return 4
    fi
    if [[ "$action" == snapshot ]]; then
        [[ $# -ge 1 ]] || return 4
        root=$1; shift
        _slr_path "$root" && [[ -d "$root" ]] || return 4
    fi
    local repo='' tag='' sha='' builder='' public='' targets='' name=release.intoto.jsonl
    local expected='' manifest_hash='' invocation='' option work cleanup key_hash matrix
    local -A seen=()
    while (($#)); do
        option=$1
        [[ -n "$option" && -z "${seen[$option]:-}" ]] || return 4
        seen[$option]=1
        if [[ "$option" == --dry-run && "$action" == publish ]]; then dry=true; shift; continue; fi
        [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
        case "$option" in
            --repo) repo=$2 ;; --tag) tag=$2 ;; --sha) sha=$2 ;; --builder) builder=$2 ;;
            --public-key) public=$2 ;; --targets) targets=$2 ;; --statement-name) name=$2 ;;
            --statement-sha256) expected=$2 ;; --manifest-sha256) manifest_hash=$2 ;; --invocation-id) invocation=$2 ;;
            --signature) [[ "$action" == publish ]] || return 4; local_signature=$2 ;;
            --output-dir) [[ "$action" == fetch ]] || return 4; output=$2 ;;
            *) return 4 ;;
        esac
        shift 2
    done
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$repo" != *..* &&
       "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.+-]+)?$ &&
       "$sha" =~ ^[0-9a-f]{40}$ && "$sha" != 0000000000000000000000000000000000000000 &&
       -n "$builder" && "$builder" != *[[:cntrl:]]* && "$invocation" != *[[:cntrl:]]* &&
       "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.intoto\.jsonl$ && "$name" != *..* &&
       ( -z "$expected" || "$expected" =~ ^[0-9a-f]{64}$ ) &&
       ( -z "$manifest_hash" || "$manifest_hash" =~ ^[0-9a-f]{64}$ ) &&
       -f "$public" && ! -L "$public" && "$dry" =~ ^(true|false)$ ]] || return 4
    command -v jq >/dev/null || return 3
    matrix=$(jq -cne --arg targets "$targets" '$targets|split(",")|
        if length>0 and all(.[];test("^(linux|darwin|windows)/(amd64|arm64|386)$")) and (unique|length)==length
        then sort else error("invalid expected targets") end') || return 4
    if [[ "$action" == snapshot ]]; then _slr_require local || return $?; else _slr_require || return $?; fi
    if [[ "$action" == fetch ]]; then
        command -v flock >/dev/null && command -v python3 >/dev/null || return 3
        _slr_path "$output" && _slr_path "$output.lock" && [[ -d "${output%/*}/" ]] || return 4
        [[ ! -e "$output.lock" || -f "$output.lock" ]] || return 4
        exec 9>> "$output.lock" || return 1
        flock -n 9 || return 2
        [[ ! -e "$output" && ! -L "$output" ]] || { _slsa_log 'Snapshot already exists; use verify-snapshot'; return 2; }
        work=$(mktemp -d "${output%/*}/.dsr-fetch.XXXXXXXX") || return 1
    else
        work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-slsa-remote.XXXXXXXX") || return 1
    fi
    printf -v cleanup 'rm -rf -- %q' "$work"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    [[ $(wc -c < "$public") -le 8192 ]] || return 4
    key_hash=$(_slsa_sha256 "$public") || return $?
    cp -- "$public" "$work/trusted.pub" || return 1
    [[ "$(_slsa_sha256 "$work/trusted.pub")" == "$key_hash" ]] || return 7
    local token
    token=$(sed -n '2{s/\r$//;p;}' "$work/trusted.pub") || return 4
    [[ "$token" =~ ^[A-Za-z0-9+/]{56}$ ]] || return 4
    if [[ "$action" == publish ]]; then
        [[ -n "$local_signature" ]] || local_signature="$local_proof.minisig"
        [[ -f "$local_signature" && ! -L "$local_signature" && $(wc -c < "$local_signature") -le 65536 &&
           $(wc -c < "$local_proof") -le 67108864 ]] || return 4
        local selected_proof selected_signature
        selected_proof=$(_slsa_sha256 "$local_proof") || return $?
        selected_signature=$(_slsa_sha256 "$local_signature") || return $?
        [[ -z "$expected" || "$expected" == "$selected_proof" ]] || return 7
        expected=$selected_proof
        cp -- "$local_proof" "$work/statement" || return 1
        cp -- "$local_signature" "$work/signature" || return 1
        [[ "$(_slsa_sha256 "$work/statement")" == "$selected_proof" &&
           "$(_slsa_sha256 "$work/signature")" == "$selected_signature" ]] || return 7
        chmod 400 "$work/statement" "$work/signature" || return 1
    fi
    jq -cnS --arg repo "$repo" --arg tag "$tag" --arg sha "$sha" --arg builder "$builder" \
        --argjson targets "$matrix" --arg name "$name" --arg expected "$expected" \
        --arg manifest "$manifest_hash" --arg invocation "$invocation" \
        '{repo:$repo,tag:$tag,source_sha:$sha,builder:$builder,targets:$targets,statement_name:$name,
          statement_sha256:$expected,manifest_sha256:$manifest,invocation_id:$invocation}' > "$work/policy.json" || return 1
    if [[ "$action" == publish ]]; then
        _slr_policy "$work/statement" "$work/signature" "$work/trusted.pub" "$work/policy.json" || return $?
        _slsa_release_assets "$work/statement" "$root" || return $?
        [[ "$(_slsa_sha256 "$local_proof")" == "$selected_proof" &&
           "$(_slsa_sha256 "$local_signature")" == "$selected_signature" ]] || return 7
        if [[ "$dry" == true ]]; then
            jq -cn --slurpfile policy "$work/policy.json" \
                '{kind:"dsr-slsa-publication",status:"planned",dry_run:true,local_statement_authenticated:true,
                  remote_verified:false,plan:$policy[0]}' > "$work/result.json" || return 1
        else
            _sbr_require || return $?
            _slr_publish "$work/policy.json" "$work/trusted.pub" "$work" "$local_proof" "$local_signature" "$root" \
                > "$work/result.json" || return $?
        fi
    elif [[ "$action" == snapshot ]]; then
        _slr_verify_snapshot "$work/policy.json" "$work/trusted.pub" "$root" "$work" > "$work/result.json" || return $?
    elif [[ "$action" == fetch ]]; then
        _sbr_require || return $?
        _slr_verify_remote "$work/policy.json" "$work/trusted.pub" "$work" true > "$work/remote.json" || return $?
        cp -- "$work/remote.json" "$work/snapshot/download.json" || return 1
        _slr_verify_snapshot "$work/policy.json" "$work/trusted.pub" "$work/snapshot" "$work" > "$work/local.json" || return $?
        jq -cn --arg output "$output" --slurpfile remote "$work/remote.json" --slurpfile local "$work/local.json" \
            '{kind:"dsr-slsa-fetch",status:"verified",authenticated:true,snapshot:$output,
              snapshot_sha256:$local[0].snapshot_sha256,verification:$remote[0]}' > "$work/result.json" || return 1
    else
        _sbr_require || return $?
        _slr_verify_remote "$work/policy.json" "$work/trusted.pub" "$work" > "$work/result.json" || return $?
    fi
    [[ "$(_slsa_sha256 "$public")" == "$key_hash" && "$(_slsa_sha256 "$work/trusted.pub")" == "$key_hash" ]] || return 7
    if [[ "$action" == fetch ]]; then
        _slr_path "$output" && _slr_path "$output.lock" || return 2
        # The cooperating-writer lock and same-filesystem staging protect the
        # single directory rename. Never adopt or overwrite an occupied path.
        python3 - "$work/snapshot" "$output" <<'PY'
import os, stat, sys
source, dest = sys.argv[1:]
held, named = os.fstat(9), os.lstat(dest + ".lock")
if not stat.S_ISREG(named.st_mode) or (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino) or os.path.lexists(dest):
    sys.exit(2)
os.rename(source, dest)
PY
        [[ $? == 0 ]] || return 2
    fi
    cat "$work/result.json"
)

slsa_verify_remote() { _slr_execute verify "$@"; }
slsa_publish_release() { _slr_execute publish "$@"; }
slsa_fetch_release() { _slr_execute fetch "$@"; }
slsa_verify_snapshot() { _slr_execute snapshot "$@"; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-help}" in
        verify-release) shift; slsa_verify_remote "$@"; exit $? ;;
        publish-release) shift; slsa_publish_release "$@"; exit $? ;;
        fetch-release) shift; slsa_fetch_release "$@"; exit $? ;;
        verify-snapshot) shift; slsa_verify_snapshot "$@"; exit $? ;;
        help|--help|-h)
            printf '%s\n' 'Usage: bash src/slsa_remote.sh verify-release --repo OWNER/REPO --tag vVERSION --sha COMMIT' \
                '       --builder ID --public-key FILE --targets linux/amd64,windows/arm64' \
                '       [--statement-name release.intoto.jsonl] [--statement-sha256 SHA256]' \
                '       [--manifest-sha256 SHA256] [--invocation-id ID]' \
                'Publish: publish-release STATEMENT ARTIFACTS (same required policy options)' \
                '         [--signature FILE] [--dry-run]' \
                'Fetch: fetch-release --output-dir NEW_DIR (same required policy options)' \
                'Offline: verify-snapshot DIR (same required policy options; no network)' \
                'Verify performs no writes. Publish adds only a signed statement pair to an existing draft.' ;;
        *) exit 4 ;;
    esac
fi
