#!/usr/bin/env bash
# SLSA v1 statements for DSR artifacts. A local statement is a claim, not
# authenticated provenance or a SLSA build-level certification. Verification
# without a trust key checks structure, named bytes and requested policy only.
# Sourceable API: slsa_generate, slsa_generate_batch, slsa_verify,
# slsa_generate_json. Build timestamps are omitted unless backed by evidence.

SLSA_SPEC_VERSION="1.0"
SLSA_BUILDER_ID="${SLSA_BUILDER_ID:-https://github.com/Dicklesworthstone/doodlestein_self_releaser}"

_slsa_log() { printf '[slsa] %s\n' "$*" >&2; }
_slsa_text() { [[ -n "$1" && "$1" != *[[:cntrl:]]* ]]; }
_slsa_name() {
    _slsa_text "$1" && [[ "$1" != . && "$1" != .. && "$1" != */* &&
        "$1" != *\\* && "$1" != *:* && "$1" != -* ]]
}
_slsa_sha256() {
    local file="$1" digest
    [[ -f "$file" && ! -L "$file" ]] || return 4
    if command -v sha256sum >/dev/null 2>&1; then
        digest=$(sha256sum < "$file") || return 1
    elif command -v shasum >/dev/null 2>&1; then
        digest=$(shasum -a 256 < "$file") || return 1
    else
        return 3
    fi
    digest="${digest%% *}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ && -f "$file" && ! -L "$file" ]] || return 1
    printf '%s\n' "$digest"
}
_slsa_git() (
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
    export GIT_NO_REPLACE_OBJECTS=1 GIT_OPTIONAL_LOCKS=0
    git -c core.fsmonitor=false "$@"
)

# An explicit checkout is authoritative: never fall through to DSR's PWD or
# another repository when it is missing. This is an observation of a checkout,
# not evidence that an arbitrary pre-existing artifact was built from it.
_slsa_source() {
    local repo_path="$1" uri commit ref dirty=false rc=0
    if [[ -z "$repo_path" ]]; then printf '{}\n'; return 0; fi
    command -v git >/dev/null 2>&1 || return 3
    [[ -d "$repo_path" ]] || return 4
    [[ "$(_slsa_git -C "$repo_path" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]] || return 4
    uri=$(_slsa_git -C "$repo_path" config --get remote.origin.url) || return 4
    # Never put credentials, query parameters or fragments from a clone URL
    # into a public attestation. HTTPS and conventional SSH clone URLs work.
    _slsa_text "$uri" || return 4
    case "$uri" in
        https://*) [[ "${uri#https://}" != *@* && "$uri" != *\?* && "$uri" != *\#* ]] || return 4 ;;
        git@*:*|ssh://git@*) ;;
        *) _slsa_log 'Source origin must be a credential-free HTTPS or git SSH URL'; return 4 ;;
    esac
    [[ "$uri" != *[[:space:]]* ]] || return 4
    commit=$(_slsa_git -C "$repo_path" rev-parse --verify 'HEAD^{commit}') || return 4
    [[ "$commit" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 4
    if ! ref=$(_slsa_git -C "$repo_path" symbolic-ref -q HEAD); then ref="$commit"; fi
    _slsa_text "$ref" || return 4
    _slsa_git -C "$repo_path" diff --no-ext-diff --quiet HEAD -- || rc=$?
    case "$rc" in 0) ;; 1) dirty=true ;; *) return 4 ;; esac
    jq -nc --arg repository "$uri" --arg commit "$commit" --arg ref "$ref" --argjson dirty "$dirty" \
        '{repository:$repository,commit:$commit,ref:$ref,tracked_dirty:$dirty}'
}

# DSR's release profile requires unique safe basenames and SHA256 subjects.
# Other producers may use broader in-toto descriptors; this is not a generic
# verifier for every in-toto predicate/profile. Unknown extension fields remain
# allowed. Validate values BEFORE reading them through shell substitution.
_slsa_validate() {
    jq -e -s '
        def text: type == "string" and length > 0 and (test("[\u0000-\u001f\u007f]") | not);
        def name: text and . != "." and . != ".." and
            (test("[/\\\\:]") | not) and (startswith("-") | not);
        def sha: type == "string" and test("^[0-9a-f]{64}$") and length == 64;
        def object_or_empty: . == null or type == "object";
        length == 1 and (.[0] |
            type == "object" and ._type == "https://in-toto.io/Statement/v1" and
            .predicateType == "https://slsa.dev/provenance/v1" and
            (.subject | type == "array" and length > 0 and
                all(.[]; type == "object" and (.name | name) and (.digest.sha256 | sha))) and
            ((.subject | map(.name) | unique | length) == (.subject | length)) and
            (.predicate | type == "object") and
            (.predicate.buildDefinition | type == "object" and (.buildType | text) and
                (.externalParameters | object_or_empty) and (.internalParameters | object_or_empty) and
                ((.resolvedDependencies // []) | type == "array" and all(.[]; type == "object"))) and
            (.predicate.runDetails | type == "object" and (.builder | type == "object" and (.id | text)) and
                (.metadata | object_or_empty)))
    ' "$1" >/dev/null 2>&1
}

# slsa_verify artifact [statement] [--builder ID] [--build-type URI]
#   [--source-repository URI --source-commit SHA] [--invocation-id ID]
# A multi-subject statement is supported, but this call checks ONLY the named
# artifact. Neither matching bytes nor self-declared builder IDs authenticate it.
slsa_verify() {
    local artifact="${1:-}" provenance='' builder='' build_type='' repository='' commit='' invocation=''
    [[ $# -ge 1 ]] || return 4
    shift
    if [[ $# -gt 0 && "$1" != --* ]]; then provenance="$1"; shift; fi
    while (($#)); do
        [[ $# -ge 2 && -n "$2" ]] || return 4
        case "$1" in
            --builder) builder="$2" ;;
            --build-type) build_type="$2" ;;
            --source-repository) repository="$2" ;;
            --source-commit) commit="$2" ;;
            --invocation-id) invocation="$2" ;;
            *) return 4 ;;
        esac
        _slsa_text "$2" || return 4
        shift 2
    done
    if [[ -n "$repository" || -n "$commit" ]]; then
        [[ -n "$repository" && "$commit" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 4
    fi
    provenance="${provenance:-$artifact.intoto.jsonl}"
    command -v jq >/dev/null 2>&1 || return 3
    [[ -f "$provenance" && ! -L "$provenance" && -s "$provenance" ]] || return 1
    _slsa_name "${artifact##*/}" || return 4
    local digest proof_digest
    digest=$(_slsa_sha256 "$artifact") || return $?
    proof_digest=$(_slsa_sha256 "$provenance") || return $?
    _slsa_validate "$provenance" || { _slsa_log 'Invalid or ambiguous SLSA statement'; return 1; }
    jq -e --arg name "${artifact##*/}" --arg sha "$digest" --arg builder "$builder" \
        --arg type "$build_type" --arg repo "$repository" --arg commit "$commit" --arg invocation "$invocation" '
        ([.subject[] | select(.name == $name and .digest.sha256 == $sha)] | length) == 1 and
        ($builder == "" or .predicate.runDetails.builder.id == $builder) and
        ($type == "" or .predicate.buildDefinition.buildType == $type) and
        ($invocation == "" or .predicate.runDetails.metadata.invocationId == $invocation) and
        ($repo == "" or (.predicate.buildDefinition.externalParameters.repository == $repo and
            ([.predicate.buildDefinition.resolvedDependencies[]? |
              select(.uri == $repo)] | length) == 1 and
            ([.predicate.buildDefinition.resolvedDependencies[]? |
              select(.uri == $repo and .digest.gitCommit == $commit)] | length) == 1))
    ' "$provenance" >/dev/null 2>&1 || { _slsa_log 'Artifact identity or provenance policy mismatch'; return 1; }
    [[ "$(_slsa_sha256 "$artifact")" == "$digest" &&
       "$(_slsa_sha256 "$provenance")" == "$proof_digest" ]] || return 1
    _slsa_log 'Named artifact and statement policy match (signer not authenticated)'
}

# --repo-path is optional and records only a post-build checkout observation.
# Use manifest-backed generation for actual recorded build inputs and times.
# Never replace an existing statement: it may already have a detached signature.
slsa_generate() (
    local artifact="${1:-}" output='' builder="$SLSA_BUILDER_ID" build_type=dsr-local
    local invocation='' repo_path='' option source_info digest statement work now previous
    [[ $# -ge 1 ]] || return 4
    shift
    while (($#)); do
        [[ $# -ge 2 && -n "$2" ]] || return 4
        case "$1" in
            --builder|-b) builder="$2" ;;
            --output|-o) output="$2" ;;
            --build-type) build_type="$2" ;;
            --invocation-id) invocation="$2" ;;
            --repo-path) repo_path="$2" ;;
            *) return 4 ;;
        esac
        shift 2
    done
    command -v jq >/dev/null 2>&1 || return 3
    _slsa_text "$builder" && _slsa_name "$build_type" && _slsa_name "${artifact##*/}" || return 4
    [[ -z "$invocation" ]] || _slsa_text "$invocation" || return 4
    output="${output:-$artifact.intoto.jsonl}"
    _slsa_name "${output##*/}" || return 4
    [[ ! -L "$output" && ( ! -e "$output" || -f "$output" ) && ! "$output" -ef "$artifact" ]] || return 4
    local parent
    parent=$(dirname "$output")
    [[ -d "$parent" && ! -L "$parent" ]] || return 4
    digest=$(_slsa_sha256 "$artifact") || return $?
    source_info=$(_slsa_source "$repo_path") || return $?
    now=$(date -u +'%Y-%m-%dT%H:%M:%SZ') || return 1
    # These are observation timestamps, not invented build start/finish times.
    statement=$(jq -nc --arg name "${artifact##*/}" --arg sha "$digest" --arg builder "$builder" \
        --arg type "$build_type" --arg invocation "$invocation" --arg now "$now" --argjson source "$source_info" '
        {_type:"https://in-toto.io/Statement/v1", predicateType:"https://slsa.dev/provenance/v1",
         subject:[{name:$name,digest:{sha256:$sha}}],
         predicate:{buildDefinition:{
             buildType:("https://github.com/Dicklesworthstone/doodlestein_self_releaser/buildtype/"+$type),
             externalParameters:(if $source == {} then {} else {repository:$source.repository,ref:$source.ref} end),
             internalParameters:{},
             resolvedDependencies:(if $source == {} then [] else [{uri:$source.repository,digest:{gitCommit:$source.commit}}] end)},
             runDetails:{builder:{id:$builder},metadata:(if $invocation == "" then {} else {invocationId:$invocation} end)}},
         dsr_evidence:{kind:"post-build-observation",observedOn:$now,source:$source}}
    ') || return 1
    if [[ -f "$output" ]]; then
        previous=$(_slsa_sha256 "$output") || return $?
        slsa_verify "$artifact" "$output" --builder "$builder" || return $?
        jq -e --argjson candidate "$statement" '
            .subject == $candidate.subject and .predicate == $candidate.predicate and
            .dsr_evidence.kind == $candidate.dsr_evidence.kind and
            .dsr_evidence.source == $candidate.dsr_evidence.source
        ' "$output" >/dev/null 2>&1 || { _slsa_log 'Existing provenance conflicts; leaving it unchanged'; return 2; }
        [[ "$(_slsa_sha256 "$output")" == "$previous" ]] || return 1
    else
        umask 077
        work=$(mktemp -d "$parent/.dsr-provenance.XXXXXXXX") || return 1
        trap 'rm -f -- "$work/statement"; rmdir -- "$work" 2>/dev/null || true' EXIT
        trap 'exit 5' HUP INT TERM
        printf '%s\n' "$statement" > "$work/statement" || return 1
        _slsa_validate "$work/statement" || return 1
        [[ "$(_slsa_sha256 "$artifact")" == "$digest" &&
           "$(_slsa_source "$repo_path")" == "$source_info" ]] || return 1
        chmod 644 "$work/statement" || return 1
        ln -- "$work/statement" "$output" || return 2
        [[ ! -L "$output" && "$output" -ef "$work/statement" ]] || return 1
        slsa_verify "$artifact" "$output" --builder "$builder" || return $?
        cmp -s "$work/statement" "$output" || return 1
    fi
    [[ "$(_slsa_sha256 "$artifact")" == "$digest" &&
       "$(_slsa_source "$repo_path")" == "$source_info" ]] || return 1
    _slsa_log "Statement ready: $output (post-build observation, not authenticated)"
    printf '%s\n' "$output"
)

# Preserve per-file statement API while checking existing proofs, enumeration
# failures and the full selected set. Already completed proofs are not deleted
# after a later failure; publication across multiple files is NOT atomic.
slsa_generate_batch() (
    local dir="${1:-}" file name listing before after failed=0
    [[ $# -ge 1 && -d "$dir" && ! -L "$dir" ]] || return 4
    shift
    local -a args=("$@") files=() digests=()
    # Validate flags before touching any artifact, including empty selections.
    while (($#)); do
        [[ $# -ge 2 && -n "$2" ]] || return 4
        case "$1" in --builder|-b|--repo-path|--build-type|--invocation-id) ;; *) return 4 ;; esac
        shift 2
    done
    listing=$(mktemp "${TMPDIR:-/tmp}/dsr-provenance-list.XXXXXXXX") || return 1
    trap 'rm -f -- "$listing"' EXIT
    trap 'exit 5' HUP INT TERM
    find "$dir" -mindepth 1 -maxdepth 1 -print0 > "$listing" || return 1
    while IFS= read -r -d '' file; do
        [[ ! -d "$file" || -L "$file" ]] || continue
        name="${file##*/}"
        case "$name" in
            *.txt|*.json|*.yaml|*.yml|*.md|*.sha256|*.sha512|*.md5|*.minisig|*.sig|*.asc|*.intoto.jsonl|*.sbom.*) continue ;;
        esac
        _slsa_name "$name" || return 4
        before=$(_slsa_sha256 "$file") || return $?
        files+=("$file"); digests+=("$before")
    done < "$listing"
    [[ ${#files[@]} -gt 0 ]] || return 7
    local i
    for ((i=0; i<${#files[@]}; i++)); do
        if ! slsa_generate "${files[i]}" "${args[@]}" >/dev/null; then failed=1; fi
    done
    for ((i=0; i<${#files[@]}; i++)); do
        after=$(_slsa_sha256 "${files[i]}") || return $?
        [[ "$after" == "${digests[i]}" ]] || return 1
        slsa_verify "${files[i]}" || failed=1
    done
    return "$failed"
)

# Keep logs on stderr and propagate generation status, not jq's successful exit.
slsa_generate_json() {
    command -v jq >/dev/null 2>&1 || return 3
    local start status=0 output='' duration
    start=$(date +%s) || return 1
    output=$(slsa_generate "$@") || status=$?
    duration=$(($(date +%s) - start))
    jq -nc --arg artifact "${1:-}" --arg output "$output" --argjson code "$status" --argjson duration "$duration" '
        {artifact:$artifact,status:(if $code == 0 then "success" else "error" end),exit_code:$code,
         output_file:(if $code == 0 then $output else null end),
         error:(if $code == 0 then null else "provenance generation failed" end),
         authenticated:false,duration_seconds:$duration}' || return 1
    return "$status"
}

export -f slsa_generate slsa_generate_batch slsa_verify slsa_generate_json
