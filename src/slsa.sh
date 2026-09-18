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
#   [--public-key trusted.pub [--signature statement.minisig]]
# A multi-subject statement is supported, but this call checks ONLY the named
# artifact. Neither matching bytes nor self-declared builder IDs authenticate it.
slsa_verify() {
    local artifact="${1:-}" provenance='' builder='' build_type='' repository='' commit='' invocation=''
    local public_key='' signature=''
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
            --public-key) public_key="$2" ;;
            --signature) signature="$2" ;;
            *) return 4 ;;
        esac
        _slsa_text "$2" || return 4
        shift 2
    done
    if [[ -n "$repository" || -n "$commit" ]]; then
        [[ -n "$repository" && "$commit" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 4
    fi
    # Trust belongs to an externally selected signer/builder pair, never to a
    # key or builder copied out of the statement being verified.
    [[ -z "$public_key" || -n "$builder" ]] || return 4
    [[ -z "$signature" || -n "$public_key" ]] || return 4
    provenance="${provenance:-$artifact.intoto.jsonl}"
    command -v jq >/dev/null 2>&1 || return 3
    [[ -f "$provenance" && ! -L "$provenance" && -s "$provenance" ]] || return 1
    _slsa_name "${artifact##*/}" || return 4
    local digest proof_digest
    digest=$(_slsa_sha256 "$artifact") || return $?
    proof_digest=$(_slsa_sha256 "$provenance") || return $?
    if [[ -n "$public_key" ]]; then
        _slsa_authenticate "$provenance" "$public_key" "${signature:-$provenance.minisig}" || return $?
    fi
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
    if [[ -n "$public_key" ]]; then
        _slsa_log 'Named artifact and policy match the trusted signer/builder pair'
    else
        _slsa_log 'Named artifact and statement policy match (signer not authenticated)'
    fi
}

# Authenticate the statement, not just the release artifact. Pin the public
# key token before invoking Minisign, and bind verification to stable proof
# and signature bytes. Standard two-line Minisign public-key files only.
_slsa_authenticate() {
    local proof="$1" public_key="$2" signature="$3" token before sig_before key_before
    command -v minisign >/dev/null 2>&1 || return 3
    [[ -s "$public_key" && -s "$signature" ]] || return 1
    before=$(_slsa_sha256 "$proof") || return $?
    sig_before=$(_slsa_sha256 "$signature") || return $?
    key_before=$(_slsa_sha256 "$public_key") || return $?
    token=$(sed -n '2{s/\r$//;p;}' "$public_key") || return 4
    [[ "$token" =~ ^[A-Za-z0-9+/]{56}$ ]] || return 4
    minisign -V -H -q -P "$token" -m "$proof" -x "$signature" >/dev/null 2>&1 || {
        _slsa_log 'Provenance signature verification failed'; return 1;
    }
    [[ "$(_slsa_sha256 "$proof")" == "$before" &&
       "$(_slsa_sha256 "$signature")" == "$sig_before" &&
       "$(_slsa_sha256 "$public_key")" == "$key_before" ]] || return 1
}

# --repo-path is optional and records only a post-build checkout observation.
# Use manifest-backed generation for actual recorded build inputs and times.
# Never replace an existing statement: it may already have a detached signature.
slsa_generate() (
    local artifact="${1:-}" output='' builder="$SLSA_BUILDER_ID" build_type=dsr-local
    local invocation='' repo_path='' source_info digest statement work now previous
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
        [[ ! -e "$output.minisig" && ! -L "$output.minisig" ]] || return 2
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

# Manifest schema 1.0.0 records commit/ref but not repository ownership. The
# producer must supply owner/repo explicitly; never infer it from PWD, a file
# path or a tool name. The signer is responsible for this binding's accuracy.
_slsa_repository() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ &&
       "$1" != *..* ]] || return 4
    printf 'https://github.com/%s\n' "$1"
}

# Map a complete successful DSR manifest to a deterministic multi-subject
# statement. This validates the fields used by this profile, not every future
# extension in schemas/manifest.json. No arbitrary embedded paths are read.
_slsa_manifest_statement() {
    local manifest="$1" repository="$2" builder="$3" digest statement
    repository=$(_slsa_repository "$repository") || return $?
    _slsa_text "$builder" || return 4
    digest=$(_slsa_sha256 "$manifest") || return $?
    statement=$(jq -ceS -s --arg repo "$repository" --arg builder "$builder" --arg digest "$digest" '
        def text: type == "string" and length > 0 and (test("[\u0000-\u001f\u007f]") | not);
        def name: text and test("^[A-Za-z0-9][A-Za-z0-9._+\\-]*$") and (contains("..") | not);
        def sha: type == "string" and length == 64 and test("^[0-9a-f]{64}$");
        def commit: type == "string" and length == 40 and test("^[0-9a-f]{40}$") and . != ("0" * 40);
        def count: type == "number" and floor == . and . >= 0 and . <= 9007199254740991;
        def target: text and test("^(linux|darwin|windows)/(amd64|arm64|386)$");
        def timestamp: text and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
            (. as $s | try (fromdateiso8601 | todateiso8601 == $s) catch false);
        if length == 1 then .[0] else error("expected one build manifest") end |
        if type != "object" or .schema_version != "1.0.0" or .status != "success" or
           (.tool | name | not) or (.version | text | not) or (.run_id | text | not) or
           (.built_at | timestamp | not) or (.source | type != "object") or
           (.source.git_sha | commit | not) or (.source.git_ref | text | not) or
           (.source.dependencies | type != "array" or
               (all(.[]; type == "object" and (.relative_path | name) and (.git_sha | commit)) | not))
        then error("incomplete or unsuccessful build manifest") else . end |
        if (.artifacts | type != "array" or length == 0 or
            (all(.[]; type == "object" and (.name | name) and (.sha256 | sha) and
                (.target | target) and (.size_bytes | count and . > 0) and
                (.archive_format | . == "tar.gz" or . == "tar.xz" or . == "zip" or . == "binary" or . == "none")) | not))
        then error("invalid artifact records") else . end |
        (.artifacts | map(.target) | unique) as $targets |
        if (.summary | type != "object" or (.total | count | not) or (.success | count | not) or
            .failed != 0 or .total != .success or .total != ($targets | length)) or
           ((.artifacts | map(.name) | unique | length) != (.artifacts | length)) or
           ((.source.dependencies | map(.relative_path) | unique | length) != (.source.dependencies | length))
        then error("incomplete or duplicate release coverage") else . end |
        if has("hosts") and (.hosts | type != "array" or
            (all(.[]; type == "object" and .status == "success" and (.platform | target)) | not) or
            (map(.platform) | sort) != $targets)
        then error("host results disagree with successful targets") else . end |
        if has("builder") and (.builder | type != "object" or .tool != "dsr" or (.version | text | not))
        then error("invalid recorded builder") else . end |
        if has("build_environments") and (.build_environments | type != "array" or
            (all(.[]; type == "object" and (.target | target) and
                (.target as $t | $targets | index($t) != null)) | not) or
            ((map(.target) | unique | length) != length))
        then error("invalid build environment coverage") else . end |
        . as $m |
        {_type:"https://in-toto.io/Statement/v1",predicateType:"https://slsa.dev/provenance/v1",
         subject:($m.artifacts | sort_by(.name) | map({name:.name,digest:{sha256:.sha256}})),
         predicate:{buildDefinition:{
             buildType:"https://github.com/Dicklesworthstone/doodlestein_self_releaser/buildtype/manifest-v1",
             externalParameters:{repository:$repo,ref:$m.source.git_ref,version:$m.version,targets:$targets},
             internalParameters:{tool:$m.tool},
             resolvedDependencies:([{uri:$repo,digest:{gitCommit:$m.source.git_sha}}] +
                 ($m.source.dependencies | sort_by(.relative_path) |
                  map({name:("sibling/"+.relative_path),digest:{gitCommit:.git_sha}})))},
             runDetails:{builder:({id:$builder} +
                 (if $m.builder == null then {} else {version:{dsr:$m.builder.version}} end)),
                 metadata:{invocationId:$m.run_id,finishedOn:$m.built_at},
                 byproducts:[{name:"dsr-build-manifest",digest:{sha256:$digest}}]}},
         dsr_evidence:{kind:"build-manifest",manifest_sha256:$digest,
             repository_binding:"caller-supplied",build_environment_count:(($m.build_environments // []) | length),
             artifacts:($m.artifacts | sort_by(.name) | map({name,target,size_bytes,archive_format}))}}
    ' "$manifest" 2>/dev/null) || { _slsa_log 'Invalid or incomplete DSR build manifest'; return 4; }
    [[ "$(_slsa_sha256 "$manifest")" == "$digest" ]] || return 1
    printf '%s\n' "$statement"
}

# Read only safe flat names from an already validated statement. Two passes
# bind the entire set to the same observation interval. This is not a snapshot
# against an adversarial privileged filesystem writer; release dirs are trusted.
_slsa_release_assets() {
    local proof="$1" root="$2" rows name digest actual size expected pass
    [[ -d "$root" && ! -L "$root" ]] || return 4
    _slsa_validate "$proof" || return 1
    if [[ "$(jq -r '.dsr_evidence.kind // ""' "$proof")" == build-manifest ]]; then
        jq -e '
            . as $s | .dsr_evidence.artifacts |
            type == "array" and (map(.name) | sort) == ($s.subject | map(.name) | sort) and
            all(.[]; (.size_bytes | type == "number" and floor == . and . > 0 and . <= 9007199254740991))
        ' "$proof" >/dev/null 2>&1 || return 1
    fi
    rows=$(jq -r '.subject[] | [.name,.digest.sha256] | @tsv' "$proof") || return 1
    for pass in 1 2; do
        while IFS=$'\t' read -r name digest; do
            _slsa_name "$name" || return 4
            actual=$(_slsa_sha256 "$root/$name") || return $?
            [[ "$actual" == "$digest" ]] || { _slsa_log "Release digest mismatch: $name"; return 1; }
            expected=$(jq -r --arg name "$name" '
                if .dsr_evidence.kind == "build-manifest" then
                    .dsr_evidence.artifacts[] | select(.name == $name) | .size_bytes
                else empty end' "$proof") || return 1
            if [[ -n "$expected" ]]; then
                size=$(wc -c < "$root/$name") || return 1
                [[ "${size//[[:space:]]/}" == "$expected" ]] || return 1
            fi
        done <<< "$rows"
    done
}

# slsa_generate_manifest manifest.json artifact_root --repository owner/repo
#   [--builder ID] [--output statement.intoto.jsonl]
# The manifest is trusted producer evidence, not independently authenticated
# build execution. No source checkout is needed and embedded paths are ignored.
slsa_generate_manifest() (
    local manifest="${1:-}" root="${2:-}" repository='' builder="$SLSA_BUILDER_ID" output=''
    [[ $# -ge 2 ]] || return 4
    shift 2
    while (($#)); do
        [[ $# -ge 2 && -n "$2" ]] || return 4
        case "$1" in
            --repository) repository="$2" ;;
            --builder) builder="$2" ;;
            --output|-o) output="$2" ;;
            *) return 4 ;;
        esac
        shift 2
    done
    command -v jq >/dev/null 2>&1 || return 3
    [[ -d "$root" && ! -L "$root" ]] || return 4
    root=$(cd "$root" && pwd -P) || return 4
    local statement digest parent work name old expected
    digest=$(_slsa_sha256 "$manifest") || return $?
    statement=$(_slsa_manifest_statement "$manifest" "$repository" "$builder") || return $?
    output="${output:-$manifest.intoto.jsonl}"
    name="${output##*/}"
    _slsa_name "$name" || return 4
    parent=$(dirname "$output")
    [[ -d "$parent" && ! -L "$parent" ]] || return 4
    parent=$(cd "$parent" && pwd -P) || return 4
    output="$parent/$name"
    [[ ! -L "$output" && ( ! -e "$output" || -f "$output" ) && ! "$manifest" -ef "$output" ]] || return 4
    if [[ "$parent" == "$root" ]] && jq -e --arg name "$name" \
        '.subject | any(.[]; .name == $name)' <<< "$statement" >/dev/null; then return 4; fi
    umask 077
    work=$(mktemp -d "$parent/.dsr-manifest-proof.XXXXXXXX") || return 1
    trap 'rm -f -- "$work/statement"; rmdir -- "$work" 2>/dev/null || true' EXIT
    trap 'exit 5' HUP INT TERM
    printf '%s\n' "$statement" > "$work/statement" || return 1
    _slsa_release_assets "$work/statement" "$root" || return $?
    [[ "$(_slsa_sha256 "$manifest")" == "$digest" ]] || return 1
    expected=$(_slsa_sha256 "$work/statement") || return 1
    if [[ -f "$output" ]]; then
        old=$(_slsa_sha256 "$output") || return $?
        [[ "$old" == "$expected" ]] || { _slsa_log 'Existing manifest provenance conflicts; preserving it'; return 2; }
    else
        # A detached signature without its original statement is a conflict,
        # not permission to publish a different statement under that identity.
        [[ ! -e "$output.minisig" && ! -L "$output.minisig" ]] || return 2
        chmod 644 "$work/statement" || return 1
        ln -- "$work/statement" "$output" || return 2
        [[ ! -L "$output" && "$output" -ef "$work/statement" ]] || return 1
    fi
    _slsa_release_assets "$output" "$root" || return $?
    [[ "$(_slsa_sha256 "$manifest")" == "$digest" && "$(_slsa_sha256 "$output")" == "$expected" ]] || return 1
    _slsa_log "Manifest-backed release statement ready: $output"
    printf '%s\n' "$output"
)

# Verify EVERY named subject. Optional --manifest with --repository and
# --builder also requires an exact statement for the expected build, detecting
# removed/added subjects and stale runs. Unrelated files in root are not subjects.
# --public-key requires the expected builder, never trusts a key inside JSON.
slsa_verify_release() {
    local proof="${1:-}" root="${2:-}" manifest='' repository='' builder='' key='' signature=''
    local -a policy=()
    [[ $# -ge 2 ]] || return 4
    shift 2
    while (($#)); do
        [[ $# -ge 2 && -n "$2" ]] || return 4
        case "$1" in
            --manifest) manifest="$2" ;;
            --repository) repository="$2" ;;
            --builder) builder="$2"; policy+=("$1" "$2") ;;
            --public-key) key="$2" ;;
            --signature) signature="$2" ;;
            --build-type|--source-repository|--source-commit|--invocation-id) policy+=("$1" "$2") ;;
            *) return 4 ;;
        esac
        shift 2
    done
    command -v jq >/dev/null 2>&1 || return 3
    [[ -z "$key" || -n "$builder" ]] || return 4
    [[ -z "$signature" || -n "$key" ]] || return 4
    [[ -z "$repository" || -n "$manifest" ]] || return 4
    [[ -z "$manifest" || ( -n "$repository" && -n "$builder" ) ]] || return 4
    local digest manifest_digest='' expected first
    digest=$(_slsa_sha256 "$proof") || return $?
    _slsa_validate "$proof" || return 1
    if [[ -n "$key" ]]; then
        _slsa_authenticate "$proof" "$key" "${signature:-$proof.minisig}" || return $?
    fi
    if [[ -n "$manifest" ]]; then
        manifest_digest=$(_slsa_sha256 "$manifest") || return $?
        expected=$(_slsa_manifest_statement "$manifest" "$repository" "$builder") || return $?
        jq -e --argjson expected "$expected" '. == $expected' "$proof" >/dev/null 2>&1 || {
            _slsa_log 'Statement differs from the expected build manifest'; return 1;
        }
    fi
    _slsa_release_assets "$proof" "$root" || return $?
    first=$(jq -r '.subject[0].name' "$proof") || return 1
    slsa_verify "$root/$first" "$proof" "${policy[@]}" 2>/dev/null || return $?
    [[ "$(_slsa_sha256 "$proof")" == "$digest" ]] || return 1
    [[ -z "$manifest" || "$(_slsa_sha256 "$manifest")" == "$manifest_digest" ]] || return 1
    if [[ -n "$key" ]]; then
        _slsa_log 'Complete named release set matches the trusted signer/builder pair'
    else
        _slsa_log 'Complete named release set matches (signer not authenticated)'
    fi
}

# Standalone access to release-set operations without loading DSR host config.
slsa_main() {
    local command="${1:-help}"
    [[ $# -eq 0 ]] || shift
    case "$command" in
        generate) slsa_generate "$@" ;;
        generate-json) slsa_generate_json "$@" ;;
        generate-manifest) slsa_generate_manifest "$@" ;;
        verify) slsa_verify "$@" ;;
        verify-release) slsa_verify_release "$@" ;;
        help|--help|-h)
            printf '%s\n' 'Usage: bash src/slsa.sh generate ARTIFACT [--repo-path DIR] [--output FILE]' \
                '       bash src/slsa.sh generate-manifest MANIFEST ROOT --repository OWNER/REPO [--builder ID] [--output FILE]' \
                '       bash src/slsa.sh verify ARTIFACT [STATEMENT] [--builder ID --public-key KEY]' \
                '       bash src/slsa.sh verify-release STATEMENT ROOT [--manifest FILE --repository OWNER/REPO --builder ID] [--public-key KEY]' \
                'Sign the statement separately with dsr signing sign. Unsigned verification does not authenticate the producer.'
            ;;
        *) return 4 ;;
    esac
}

export -f slsa_generate slsa_generate_batch slsa_verify slsa_generate_json
export -f slsa_generate_manifest slsa_verify_release
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    slsa_main "$@"
fi
