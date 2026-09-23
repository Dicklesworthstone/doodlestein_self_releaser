#!/usr/bin/env bash
# Signed build-manifest provenance at the GitHub release boundary. Reuse the
# existing uncached/immutable-ID transport, never URLs embedded in a statement.
_SLSA_REMOTE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_slr_require() {
    if ! declare -F slsa_verify_release >/dev/null; then
        # shellcheck source=src/slsa.sh
        source "$_SLSA_REMOTE_DIR/slsa.sh" || return 3
    fi
    if ! declare -F _sbr_context >/dev/null; then
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

# Public-GitHub only; no source checkout, local artifact set, build manifest or
# private signing key is needed. stdout contains a receipt only after all gates.
slsa_verify_remote() (
    set -uo pipefail
    umask 077
    local repo='' tag='' sha='' builder='' public='' targets='' name=release.intoto.jsonl
    local expected='' manifest_hash='' invocation='' option work cleanup key_hash matrix
    local -A seen=()
    while (($#)); do
        option=$1
        [[ -n "$option" && -z "${seen[$option]:-}" && $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
        seen[$option]=1
        case "$option" in
            --repo) repo=$2 ;; --tag) tag=$2 ;; --sha) sha=$2 ;; --builder) builder=$2 ;;
            --public-key) public=$2 ;; --targets) targets=$2 ;; --statement-name) name=$2 ;;
            --statement-sha256) expected=$2 ;; --manifest-sha256) manifest_hash=$2 ;; --invocation-id) invocation=$2 ;;
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
       -f "$public" && ! -L "$public" ]] || return 4
    command -v jq >/dev/null || return 3
    matrix=$(jq -cne --arg targets "$targets" '$targets|split(",")|
        if length>0 and all(.[];test("^(linux|darwin|windows)/(amd64|arm64|386)$")) and (unique|length)==length
        then sort else error("invalid expected targets") end') || return 4
    _slr_require || return $?
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-slsa-remote.XXXXXXXX") || return 1
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
    jq -cnS --arg repo "$repo" --arg tag "$tag" --arg sha "$sha" --arg builder "$builder" \
        --argjson targets "$matrix" --arg name "$name" --arg expected "$expected" \
        --arg manifest "$manifest_hash" --arg invocation "$invocation" \
        '{repo:$repo,tag:$tag,source_sha:$sha,builder:$builder,targets:$targets,statement_name:$name,
          statement_sha256:$expected,manifest_sha256:$manifest,invocation_id:$invocation}' > "$work/policy.json" || return 1
    _sbr_require || return $?
    _slr_verify_remote "$work/policy.json" "$work/trusted.pub" "$work" > "$work/result.json" || return $?
    [[ "$(_slsa_sha256 "$public")" == "$key_hash" && "$(_slsa_sha256 "$work/trusted.pub")" == "$key_hash" ]] || return 7
    cat "$work/result.json"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-help}" in
        verify-release) shift; slsa_verify_remote "$@"; exit $? ;;
        help|--help|-h)
            printf '%s\n' 'Usage: bash src/slsa_remote.sh verify-release --repo OWNER/REPO --tag vVERSION --sha COMMIT' \
                '       --builder ID --public-key FILE --targets linux/amd64,windows/arm64' \
                '       [--statement-name release.intoto.jsonl] [--statement-sha256 SHA256]' \
                '       [--manifest-sha256 SHA256] [--invocation-id ID]' \
                'Authenticate signed manifest-backed provenance and every remote payload; no remote writes.' ;;
        *) exit 4 ;;
    esac
fi
