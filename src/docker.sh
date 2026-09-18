#!/usr/bin/env bash
# Multi-architecture container builds and releases (bd-1jt.3.8).
# stdout is JSON for builds/releases, stderr is diagnostics. External tool
# acknowledgements are not independent signature or registry verification.

DOCKER_REGISTRY="${DOCKER_REGISTRY:-ghcr.io/dicklesworthstone}"
DOCKER_PLATFORMS="${DOCKER_PLATFORMS:-linux/amd64,linux/arm64}"
DOCKER_BUILDER_NAME="${DOCKER_BUILDER_NAME:-dsr-builder}"
DOCKER_CONTAINERIZED_TOOLS="${DOCKER_CONTAINERIZED_TOOLS:-ubs,mcp_agent_mail,process_triage}"

_dk_log_info() { printf '[docker] %s\n' "$*" >&2; }
_dk_log_ok() { _dk_log_info "$@"; }
_dk_log_warn() { printf '[docker:warn] %s\n' "$*" >&2; }
_dk_log_error() { printf '[docker:error] %s\n' "$*" >&2; }
_dk_log_debug() { [[ "${DOCKER_DEBUG:-}" != 1 ]] || _dk_log_info "$@"; }

_dk_dependency() {
    command -v "$1" >/dev/null 2>&1 || {
        _dk_log_error "$1 is required"; return 3;
    }
}
docker_check() {
    _dk_dependency docker || return $?
    docker info >/dev/null 2>&1 || { _dk_log_error 'Docker daemon unavailable'; return 3; }
}
docker_check_buildx() {
    docker_check || return $?
    docker buildx version >/dev/null 2>&1 || { _dk_log_error 'Docker buildx unavailable'; return 3; }
}
docker_check_cosign() { _dk_dependency cosign; }
docker_version() {
    docker_check || return $?
    docker version --format '{{.Server.Version}}'
}

# Never change the operator's globally selected builder. Every build passes
# --builder explicitly. Inspect/bootstrap the named builder, including on reuse.
docker_setup_buildx() {
    local builder="${1:-${DOCKER_BUILDER_NAME:-dsr-builder}}"
    [[ "$builder" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 4
    docker_check_buildx || return $?
    if ! docker buildx inspect "$builder" >/dev/null 2>&1; then
        if ! docker buildx create --name "$builder" --driver docker-container >&2; then
            # Another process may have created this same builder.
            docker buildx inspect "$builder" >/dev/null 2>&1 || return 1
        fi
    fi
    docker buildx inspect "$builder" --bootstrap >&2 || return 1
}

# Explicit environment choices win; do not accidentally prefer another account
# selected in gh's local config. Never expose the token in an argument or log.
_dk_resolve_gh_token() {
    local token="${DSR_GH_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
    if [[ -z "$token" ]] && declare -F secrets_get_gh_token >/dev/null; then
        token=$(secrets_get_gh_token 2>/dev/null) || return 1
    fi
    if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
        token=$(gh auth token --hostname github.com 2>/dev/null) || return 1
    fi
    [[ -n "$token" && "$token" != *[[:cntrl:]]* ]] || return 1
    printf '%s' "$token"
}
# A token's presence is NOT proof of registry authorization. Login performs the
# check; builds can instead use the operator's existing Docker credential store.
docker_check_ghcr_auth() { docker_login_ghcr; }
docker_login_ghcr() (
    set +x
    set -o pipefail
    local token username="${GITHUB_USER:-${USER:-}}"
    [[ -n "$username" && "$username" != -* && "$username" != *[[:cntrl:]]* ]] || {
        _dk_log_error 'GITHUB_USER is required for GHCR login'; return 3;
    }
    token=$(_dk_resolve_gh_token) || { _dk_log_error 'No GitHub token available'; return 3; }
    printf '%s' "$token" | docker login ghcr.io -u "$username" --password-stdin >/dev/null 2>&1 || {
        _dk_log_error 'GHCR login failed'; return 3;
    }
)

docker_is_containerized() {
    [[ ",${DOCKER_CONTAINERIZED_TOOLS:-ubs,mcp_agent_mail,process_triage}," == *",$1,"* ]]
}
docker_find_dockerfile() {
    local tool="$1" root="${2:-/data/projects/$1}" path
    [[ -n "$tool" ]] || return 4
    for path in "$root/Dockerfile" "$root/docker/Dockerfile" "$root/build/Dockerfile"; do
        if [[ -f "$path" && ! -L "$path" ]]; then printf '%s\n' "$path"; return 0; fi
    done
    return 1
}
_dk_tag_valid() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; }
# Deliberately conservative qualified registry/repository grammar; no implicit
# Docker Hub namespace, URL, embedded credentials, option, or shell syntax.
_dk_repository_valid() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+$ ]]
}
_dk_pinned_valid() {
    [[ "$1" == *@sha256:* ]] || return 4
    _dk_repository_valid "${1%@*}" && [[ "${1##*@}" =~ ^sha256:[0-9a-f]{64}$ ]]
}
_dk_platforms() {
    local value="$1" platform seen=','
    local -a entries=()
    [[ -n "$value" && "$value" != ,* && "$value" != *, && "$value" != *,,* ]] || return 4
    IFS=',' read -r -a entries <<< "$value"
    for platform in "${entries[@]}"; do
        [[ "$platform" =~ ^linux/[a-z0-9_]+(/[a-z0-9_.-]+)?$ && "$seen" != *",$platform,"* ]] || return 4
        seen+="$platform,"
    done
    printf '%s\n' "${entries[@]}" | jq -Rsc 'split("\n")[:-1]'
}
_dk_hash() {
    local value
    [[ -f "$1" && ! -L "$1" ]] || return 4
    if command -v sha256sum >/dev/null 2>&1; then value=$(sha256sum < "$1") || return 1
    elif command -v shasum >/dev/null 2>&1; then value=$(shasum -a 256 < "$1") || return 1
    else return 3; fi
    value="${value%% *}"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$value"
}

# Parse/resolve a build plan without invoking Docker, login, Syft, or Cosign,
# creating directories, or writing an output. Also used for release preflight.
_dk_build_plan() {
    local tool='' version='' root='' dockerfile='' output='' mode=oci
    local push=false local_only=false explicit_platform=false dry="${DRY_RUN:-false}"
    local platforms="${DOCKER_PLATFORMS:-linux/amd64,linux/arm64}" tags='[]' tag image builder
    local -a extra_tags=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool|-t|--version|-V|--repo-path|--dockerfile|--platform|-p|--tag|--output)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { _dk_log_error "Missing value for $1"; return 4; }
                case "$1" in
                    --tool|-t) [[ -z "$tool" ]] || return 4; tool="$2" ;;
                    --version|-V) [[ -z "$version" ]] || return 4; version="$2" ;;
                    --repo-path) root="$2" ;;
                    --dockerfile) dockerfile="$2" ;;
                    --platform|-p) platforms="$2"; explicit_platform=true ;;
                    --tag) extra_tags+=("$2") ;;
                    --output) output="$2" ;;
                esac
                shift 2 ;;
            --push) push=true; shift ;;
            --local) local_only=true; shift ;;
            --dry-run|-n) dry=true; shift ;;
            -*) _dk_log_error "Unknown option: $1"; return 4 ;;
            *)
                if [[ -z "$tool" ]]; then tool="$1"
                elif [[ -z "$version" ]]; then version="$1"
                else _dk_log_error 'Unexpected positional argument'; return 4; fi
                shift ;;
        esac
    done
    [[ -n "$tool" ]] || { _dk_log_error 'Tool name required'; return 4; }
    [[ -n "$version" ]] || { _dk_log_error 'Version required'; return 4; }
    [[ "$tool" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || return 4
    tag="v${version#v}"
    _dk_tag_valid "$tag" || { _dk_log_error 'Version is not a valid container tag'; return 4; }
    image="${DOCKER_REGISTRY:-ghcr.io/dicklesworthstone}/$tool"
    _dk_repository_valid "$image" || { _dk_log_error 'Invalid container repository'; return 4; }
    builder="${DOCKER_BUILDER_NAME:-dsr-builder}"
    [[ "$builder" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$dry" =~ ^(true|false)$ ]] || return 4
    $push && $local_only && { _dk_log_error '--push and --local conflict'; return 4; }
    if $push; then mode=registry; elif $local_only; then mode=docker; fi
    [[ "$mode" == oci || -z "$output" ]] || { _dk_log_error '--output is only for OCI export'; return 4; }
    _dk_dependency jq || return $?
    local platforms_json
    if $local_only && ! $explicit_platform; then
        platforms_json='[]'; platforms=''
    else
        platforms_json=$(_dk_platforms "$platforms") || { _dk_log_error 'Invalid or duplicate Linux platforms'; return 4; }
        [[ "$mode" != docker || "$platforms" != *,* ]] || { _dk_log_error '--local loads only one platform'; return 4; }
    fi
    for tag in "v${version#v}" "${extra_tags[@]}"; do
        _dk_tag_valid "$tag" || return 4
        tags=$(jq -c --arg tag "$image:$tag" 'if index($tag) then . else . + [$tag] end' <<< "$tags") || return 1
    done
    if [[ -z "$root" ]] && declare -F config_get_tool_field >/dev/null; then
        root=$(config_get_tool_field "$tool" local_path '' 2>/dev/null) || return 4
    fi
    [[ -n "$root" ]] || root="/data/projects/$tool"
    [[ -d "$root" && ! -L "$root" && "$root" != *[[:cntrl:]]* ]] || { _dk_log_error "Invalid repository path: $root"; return 4; }
    root=$(cd "$root" && pwd -P) || return 4
    if [[ -z "$dockerfile" ]]; then
        dockerfile=$(docker_find_dockerfile "$tool" "$root") || { _dk_log_error 'No Dockerfile found'; return 7; }
    elif [[ "$dockerfile" != /* ]]; then dockerfile="$root/$dockerfile"; fi
    [[ -f "$dockerfile" && ! -L "$dockerfile" && "$dockerfile" != *[[:cntrl:]]* ]] || return 4
    dockerfile="$(cd "$(dirname "$dockerfile")" && pwd -P)/$(basename "$dockerfile")"
    [[ "$dockerfile" == "$root/"* ]] || { _dk_log_error 'Dockerfile must be inside the repository context'; return 4; }
    if [[ "$mode" == oci ]]; then
        [[ -n "$output" ]] || output="${DOCKER_OUTPUT_DIR:-${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/containers}/$tool-v${version#v}.oci.tar"
        [[ "$output" == /* ]] || output="$PWD/$output"
        [[ "$output" != *[[:cntrl:]]* && "$output" != *','* && "$output" != */ &&
           ! -e "$output" && ! -L "$output" ]] || { _dk_log_error 'OCI output already exists or is unsafe'; return 4; }
    fi
    jq -nc --arg tool "$tool" --arg version "v${version#v}" --arg repository "$image" \
        --arg root "$root" --arg dockerfile "$dockerfile" --arg builder "$builder" --arg exporter "$mode" \
        --arg output "$output" --argjson tags "$tags" --argjson platforms "$platforms_json" --argjson dry "$dry" '
        {schema_version:1,kind:"dsr-container-build",status:"planned",tool:$tool,version:$version,
         repository:$repository,tags:$tags,context:$root,dockerfile:$dockerfile,builder:$builder,
         exporter:$exporter,platforms:$platforms,dry_run:$dry,
         output_file:(if $output == "" then null else $output end)}'
}

_dk_build_execute() (
    set -o pipefail
    local plan="$1" work='' output_work='' root dockerfile builder mode output platforms digest start=$SECONDS
    root=$(jq -r '.context' <<< "$plan") || return 1
    dockerfile=$(jq -r '.dockerfile' <<< "$plan") || return 1
    builder=$(jq -r '.builder' <<< "$plan") || return 1
    mode=$(jq -r '.exporter' <<< "$plan") || return 1
    output=$(jq -r '.output_file // ""' <<< "$plan") || return 1
    platforms=$(jq -r '.platforms | join(",")' <<< "$plan") || return 1
    if [[ $(jq -r '.dry_run' <<< "$plan") == true ]]; then printf '%s\n' "$plan"; return 0; fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-container.XXXXXXXX") || return 1
    trap '[[ -z "$output_work" ]] || rm -rf -- "$output_work"; rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    if [[ "$mode" == oci ]]; then
        mkdir -p -- "$(dirname "$output")" || return 1
        output="$(cd "$(dirname "$output")" && pwd -P)/$(basename "$output")"
        [[ "$output" != "$root/"* && ! -e "$output" && ! -L "$output" ]] || {
            _dk_log_error 'OCI output overlaps build context or exists'; return 4;
        }
        output_work=$(mktemp -d "$(dirname "$output")/.dsr-oci.XXXXXXXX") || return 1
    fi
    docker_setup_buildx "$builder" || return $?
    local tag tag_lines repository
    local -a args=(--builder "$builder" --file "$dockerfile" --metadata-file "$work/metadata.json" --progress plain)
    [[ -z "$platforms" ]] || args+=(--platform "$platforms")
    tag_lines=$(jq -r '.tags[]' <<< "$plan") || return 1
    while IFS= read -r tag; do args+=(--tag "$tag"); done <<< "$tag_lines"
    case "$mode" in
        registry)
            repository=$(jq -r '.repository' <<< "$plan") || return 1
            if [[ "$repository" == ghcr.io/* && -n "${DSR_GH_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}" ]]; then
                docker_login_ghcr || return $?
            fi
            args+=(--push --provenance=true --sbom=true) ;;
        docker) args+=(--load --provenance=false --sbom=false) ;;
        oci) args+=(--output "type=oci,dest=$output_work/image.tar" --provenance=true --sbom=true) ;;
        *) return 4 ;;
    esac
    # The repository, NOT dirname(Dockerfile), is the build context.
    docker buildx build "${args[@]}" "$root" >&2 || { _dk_log_error 'Container build/export failed'; return 1; }
    [[ -f "$work/metadata.json" && ! -L "$work/metadata.json" ]] || return 1
    digest=$(jq -er -s '
        if length == 1 and (.[0] | type == "object") then .[0] else error("metadata") end |
        .["containerimage.digest"] as $digest |
        if ($digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
           (if has("containerimage.descriptor") then .["containerimage.descriptor"].digest == $digest else true end)
        then $digest else error("missing or conflicting image digest") end' "$work/metadata.json") || {
        _dk_log_error 'Build succeeded without a valid image digest receipt'; return 1;
    }
    local archive_hash='' archive_size=0
    if [[ "$mode" == oci ]]; then
        [[ -s "$output_work/image.tar" && ! -L "$output_work/image.tar" ]] || return 1
        archive_hash=$(_dk_hash "$output_work/image.tar") || return $?
        archive_size=$(wc -c < "$output_work/image.tar") || return 1
        [[ ! -d "$output" && ! -e "$output" && ! -L "$output" ]] || return 2
        ln -- "$output_work/image.tar" "$output" || return 2
        [[ -f "$output" && ! -L "$output" && "$(_dk_hash "$output")" == "$archive_hash" ]] || return 2
    fi
    jq -c --arg digest "$digest" --arg output "$output" --arg archive_sha256 "$archive_hash" \
        --argjson archive_size "$archive_size" --argjson duration "$((SECONDS-start))" '
        . + {status:"built",digest:$digest,reference:(.repository + "@" + $digest),duration_seconds:$duration,
             output_file:(if $output == "" then null else $output end),
             archive:(if $archive_sha256 == "" then null else {sha256:$archive_sha256,size:$archive_size} end)}' <<< "$plan"
)

docker_build() {
    case "${1:-}" in --help|-h)
        printf '%s\n' 'docker_build - Build multi-arch Docker image' \
            'Usage: docker_build TOOL VERSION [--repo-path DIR] [--dockerfile FILE]' \
            '  --push | --local | --output OCI_TAR (default: XDG state OCI archive)' \
            '  --platform linux/amd64,linux/arm64 --tag TAG --dry-run' \
            'No implicit latest tag. --local without --platform uses the builder default.' >&2
        return 0 ;;
    esac
    local plan
    plan=$(_dk_build_plan "$@") || return $?
    _dk_build_execute "$plan"
}

# These operations accept immutable qualified references only. A mutable tag
# must not be resolved independently by the scanner and signer.
docker_sign() {
    local image="${1:-}" dry="${DRY_RUN:-false}"
    case "$image" in --help|-h)
        printf '%s\n' 'docker_sign - Sign container image by immutable repository@sha256:digest' >&2; return 0 ;;
    esac
    [[ $# -eq 0 ]] || shift
    while [[ $# -gt 0 ]]; do
        case "$1" in --dry-run|-n) dry=true; shift ;; *) return 4 ;; esac
    done
    [[ -n "$image" ]] || { _dk_log_error 'Image reference required'; return 4; }
    _dk_pinned_valid "$image" || { _dk_log_error 'Use an immutable repository@sha256:digest'; return 4; }
    [[ "$dry" != true ]] || { _dk_log_info "[dry-run] Would sign $image"; return 0; }
    docker_check_cosign || return $?
    cosign sign --yes "$image" >&2 || { _dk_log_error "Signing failed: $image"; return 1; }
}
_dk_spdx_valid() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    jq -e -s 'length == 1 and (.[0] | type == "object" and
        (.spdxVersion == "SPDX-2.2" or .spdxVersion == "SPDX-2.3") and
        .SPDXID == "SPDXRef-DOCUMENT" and .dataLicense == "CC0-1.0" and
        (.name | type == "string" and length > 0) and
        (.documentNamespace | type == "string" and length > 0) and
        (.creationInfo | type == "object") and
        (if has("packages") then .packages | type == "array" else true end))' "$1" >/dev/null 2>&1
}

# Buildx --raw preserves exact registry manifest bytes (no added newline).
# Hash BEFORE parsing, so a dishonest/mistaken digest field cannot satisfy a pin.
_dk_fetch_manifest() {
    local image="$1" file="$2"
    _dk_pinned_valid "$image" || return 4
    docker buildx imagetools inspect "$image" --raw > "$file" || return 8
    [[ "$(_dk_hash "$file")" == "${image##*@sha256:}" ]] || {
        _dk_log_error "Registry manifest digest mismatch: $image"; return 7;
    }
    jq -e -s 'length == 1 and (.[0] | type == "object" and .schemaVersion == 2)' "$file" >/dev/null || return 7
}

# Normalize the default arm64 variant without conflating arm/v6 and arm/v7.
# Only image manifests are executable platforms. BuildKit attestation entries
# must identify themselves AND reference a real executable manifest in the set.
_dk_registry_inventory() (
    local image="$1" expected="$2" work="$3" media rows row digest platform config actual size raw
    _dk_fetch_manifest "$image" "$work/root.json" || return $?
    media=$(jq -r '.mediaType' "$work/root.json") || return 7
    case "$media" in
        application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
            rows=$(jq -ec '
                def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
                def size: type == "number" and . > 0 and . == floor;
                def image: .mediaType == "application/vnd.oci.image.manifest.v1+json" or
                    .mediaType == "application/vnd.docker.distribution.manifest.v2+json";
                def evidence: .annotations["vnd.docker.reference.type"] == "attestation-manifest";
                def platform: .os + "/" + .architecture +
                    (if (.variant // "") == "" or (.architecture == "arm64" and .variant == "v8")
                     then "" else "/" + .variant end);
                .manifests as $all |
                if ($all | type != "array" or length == 0) then error("empty index") else . end |
                if all($all[]; image and (.digest | digest) and (.size | size) and
                    (if evidence then .platform.os == "unknown" and .platform.architecture == "unknown" and
                        (.annotations["vnd.docker.reference.digest"] | digest)
                     else .platform.os == "linux" and
                        (.platform.architecture | type == "string" and test("^[a-z0-9_]+$")) and
                        (.platform.variant // "" | type == "string" and test("^[a-z0-9_.-]*$")) end))
                then . else error("unsupported descriptor") end |
                [$all[] | select(evidence | not)] as $images |
                if ($images | length) == 0 or
                    any($all[] | select(evidence); .annotations["vnd.docker.reference.digest"] as $d |
                        [$images[].digest] | index($d) == null)
                then error("unbound index evidence") else . end |
                [$images[] | {digest,size,platform:(.platform | platform)}] |
                if (map(.platform) | unique | length) != length or
                   (map(.digest) | unique | length) != length
                then error("duplicate platform or image") else sort_by(.platform) end
            ' "$work/root.json") || return 7 ;;
        application/vnd.oci.image.manifest.v1+json|application/vnd.docker.distribution.manifest.v2+json)
            rows=$(jq -nc --arg digest "${image##*@}" --argjson size "$(wc -c < "$work/root.json")" \
                '[{digest:$digest,size:$size,platform:null}]') || return 7 ;;
        *) _dk_log_error 'Unsupported registry manifest type'; return 7 ;;
    esac
    : > "$work/inventory.jsonl" || return 1
    local lines reference
    lines=$(jq -c '.[]' <<< "$rows") || return 7
    while IFS= read -r row; do
        digest=$(jq -r '.digest' <<< "$row") || return 7
        platform=$(jq -r '.platform // ""' <<< "$row") || return 7
        size=$(jq -r '.size' <<< "$row") || return 7
        reference="${image%@*}@$digest"
        raw="$work/${digest#sha256:}.json"
        _dk_fetch_manifest "$reference" "$raw" || return $?
        [[ "$(wc -c < "$raw")" -eq "$size" ]] || return 7
        jq -e '
            def d: type == "string" and test("^sha256:[0-9a-f]{64}$");
            (.mediaType == "application/vnd.oci.image.manifest.v1+json" or
             .mediaType == "application/vnd.docker.distribution.manifest.v2+json") and
            (.config.digest | d) and (.config.size | type == "number" and . > 0 and . == floor) and
            (.layers | type == "array" and all(.[]; (.digest | d) and
                (.size | type == "number" and . >= 0 and . == floor)))
        ' "$raw" >/dev/null || return 7
        # .Image is loaded by Docker's content-addressed resolver. It is parsed
        # configuration, not original config bytes; Docker is a trusted adapter.
        docker buildx imagetools inspect "$reference" --format '{{json .Image}}' > "$work/config.json" || return 8
        config=$(jq -ec -s 'if length == 1 then .[0] else error("config stream") end |
            if type == "object" and .os == "linux" and
               (.architecture | type == "string" and test("^[a-z0-9_]+$")) and
               (.variant // "" | type == "string" and test("^[a-z0-9_.-]*$"))
            then .os + "/" + .architecture +
                (if (.variant // "") == "" or (.architecture == "arm64" and .variant == "v8")
                 then "" else "/" + .variant end)
            else error("invalid platform config") end' "$work/config.json") || return 7
        actual=$(jq -r . <<< "$config") || return 7
        [[ -z "$platform" || "$platform" == "$actual" ]] || {
            _dk_log_error "Index/config platform mismatch: $reference"; return 7;
        }
        jq -nc --arg reference "$reference" --arg digest "$digest" --arg platform "$actual" \
            '{reference:$reference,digest:$digest,platform:$platform}' >> "$work/inventory.jsonl" || return 1
    done <<< "$lines"
    rows=$(jq -sc 'sort_by(.platform)' "$work/inventory.jsonl") || return 7
    jq -e --argjson expected "$expected" '
        def normalize: if . == "linux/arm64/v8" then "linux/arm64" else . end;
        ($expected | length) == 0 or (map(.platform) | sort) == ($expected | map(normalize) | sort)
    ' <<< "$rows" >/dev/null || { _dk_log_error 'Registry platform set differs from requested build'; return 7; }
    printf '%s\n' "$rows"
)

_dk_verify_policy() {
    [[ -n "$1" && "$1" != *[[:cntrl:]]* && "$2" == https://* && "$2" != *[[:space:]]* ]] || {
        _dk_log_error 'Set an exact --certificate-identity and --certificate-oidc-issuer (or DOCKER_CERTIFICATE_IDENTITY / DOCKER_CERTIFICATE_OIDC_ISSUER)'; return 4;
    }
}
_dk_verify_signature() {
    local image="$1" identity="$2" issuer="$3" file="$4"
    cosign verify --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" \
        --output json "$image" > "$file" || return 7
    jq -e -s --arg digest "${image##*@}" 'length == 1 and (.[0] | type == "array" and length > 0 and
        all(.[]; .critical.image["docker-manifest-digest"] == $digest))' "$file" >/dev/null || return 7
}

# Inspect only Cosign-VERIFIED DSSE payloads, never a download of unauthenticated
# attestations. Require a named subject and SPDX predicate; on publication also
# require that the authenticated predicate equals the document we just scanned.
_dk_verify_attestation() {
    local image="$1" identity="$2" issuer="$3" work="$4" expected="${5:-}" payload hash
    cosign verify-attestation --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" \
        --type spdxjson --output json "$image" > "$work/attestations.jsonl" || return 7
    jq -ec -s --arg digest "${image##*@sha256:}" --arg repository "${image%@*}" '
        [.[] | if type == "array" then .[] else . end] |
        if length > 0 and all(.[]; type == "object" and .payloadType == "application/vnd.in-toto+json" and
            (.payload | type == "string" and length > 0)) then . else error("missing DSSE") end |
        map(.payload | @base64d | fromjson) |
        .[] | select((._type == "https://in-toto.io/Statement/v0.1" or ._type == "https://in-toto.io/Statement/v1") and
            .predicateType == "https://spdx.dev/Document" and
            (.subject | type == "array" and length > 0 and
                any(.[]; .name == $repository and .digest.sha256 == $digest))) | .predicate
    ' "$work/attestations.jsonl" > "$work/predicates.jsonl" || return 7
    [[ -s "$work/predicates.jsonl" ]] || return 7
    while IFS= read -r payload; do
        printf '%s\n' "$payload" > "$work/predicate.json" || return 1
        _dk_spdx_valid "$work/predicate.json" || continue
        if [[ -n "$expected" ]]; then
            jq -e --slurpfile expected "$expected" '. == $expected[0]' "$work/predicate.json" >/dev/null || continue
        fi
        jq -cS . "$work/predicate.json" > "$work/canonical.json" || return 1
        hash=$(_dk_hash "$work/canonical.json") || return $?
        printf '%s\n' "$hash"
        return 0
    done < "$work/predicates.jsonl"
    _dk_log_error "No matching verified SPDX attestation: $image"
    return 7
}

_dk_prepare_sboms() {
    local inventory="$1" work="$2" row reference platform file count=0 lines hash
    lines=$(jq -c '.[]' <<< "$inventory") || return 1
    : > "$work/scans.jsonl" || return 1
    while IFS= read -r row; do
        reference=$(jq -r '.reference' <<< "$row") || return 1
        platform=$(jq -r '.platform' <<< "$row") || return 1
        file="$work/sbom-$count.json"
        syft "registry:$reference" --platform "$platform" -o spdx-json > "$file" || return 1
        _dk_spdx_valid "$file" || { _dk_log_error "Invalid SPDX for $platform"; return 1; }
        hash=$(_dk_hash "$file") || return $?
        jq -c --arg file "$file" --arg hash "$hash" '. + {file:$file,sbom_sha256:$hash}' <<< "$row" \
            >> "$work/scans.jsonl" || return 1
        count=$((count+1))
    done <<< "$lines"
    jq -sc . "$work/scans.jsonl"
}
_dk_publish_sboms() {
    local scans="$1" identity="$2" issuer="$3" work="$4" lines row reference file hash predicate
    lines=$(jq -c '.[]' <<< "$scans") || return 1
    : > "$work/verified.jsonl" || return 1
    while IFS= read -r row; do
        reference=$(jq -r '.reference' <<< "$row") || return 1
        file=$(jq -r '.file' <<< "$row") || return 1
        hash=$(jq -r '.sbom_sha256' <<< "$row") || return 1
        [[ "$(_dk_hash "$file")" == "$hash" ]] || return 7
        cosign attest --yes --predicate "$file" --type spdxjson "$reference" >&2 || return 1
        [[ "$(_dk_hash "$file")" == "$hash" ]] || return 7
        predicate=$(_dk_verify_attestation "$reference" "$identity" "$issuer" "$work" "$file") || return $?
        [[ "$(_dk_hash "$file")" == "$hash" ]] || return 7
        jq -c --arg predicate "$predicate" 'del(.file) + {status:"verified",predicate_sha256:$predicate}' <<< "$row" \
            >> "$work/verified.jsonl" || return 1
    done <<< "$lines"
    jq -sc . "$work/verified.jsonl"
}

# Verify or attest an EXISTING immutable image without a source checkout/build.
# Verification needs no scanner, login, builder setup, upload, or tag mutation.
_dk_evidence_command() (
    local action="$1" image="${2:-}" expected='[]' skip=false dry="${DRY_RUN:-false}" work inventory after rows='[]'
    local identity="${DOCKER_CERTIFICATE_IDENTITY:-}" issuer="${DOCKER_CERTIFICATE_OIDC_ISSUER:-}" lines row ref hash scans
    local expected_scans='' expected_file='' expected_hash=''
    shift
    [[ $# -eq 0 ]] || shift
    # Internal release verification additionally binds the exact freshly scanned
    # predicates. The public read-only verifier accepts any valid matching SPDX
    # from the configured signer, so older attestations may coexist on an image.
    if [[ "$action" == verify-scans ]]; then
        [[ $# -gt 0 ]] || return 4
        expected_scans="$1"; shift
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --certificate-identity|--certificate-oidc-issuer|--platform|-p)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || return 4
                case "$1" in
                    --certificate-identity) identity="$2" ;;
                    --certificate-oidc-issuer) issuer="$2" ;;
                    *) expected=$(_dk_platforms "$2") || return 4 ;;
                esac
                shift 2 ;;
            --skip-sign) skip=true; shift ;;
            --dry-run|-n) dry=true; shift ;;
            *) return 4 ;;
        esac
    done
    _dk_pinned_valid "$image" || return 4
    _dk_dependency jq || return $?
    if [[ "$dry" == true ]]; then
        jq -nc --arg image "$image" --arg action "$action" '{status:"planned",reference:$image,operation:$action}'
        return $?
    fi
    _dk_verify_policy "$identity" "$issuer" || return $?
    _dk_dependency docker && docker_check_cosign || return 3
    [[ "$action" != attest ]] || _dk_dependency syft || return 3
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-container-evidence.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    inventory=$(_dk_registry_inventory "$image" "$expected" "$work") || return $?
    if [[ "$action" == attest ]]; then
        scans=$(_dk_prepare_sboms "$inventory" "$work") || return $?
        rows=$(_dk_publish_sboms "$scans" "$identity" "$issuer" "$work") || return $?
    else
        $skip || _dk_verify_signature "$image" "$identity" "$issuer" "$work/signature.json" || return $?
        lines=$(jq -c '.[]' <<< "$inventory") || return 1
        while IFS= read -r row; do
            ref=$(jq -r '.reference' <<< "$row") || return 1
            if [[ -n "$expected_scans" ]]; then
                scans=$(jq -ec --arg ref "$ref" '[.[] | select(.reference == $ref)] |
                    if length == 1 then .[0] else error("missing or duplicate expected scan") end' <<< "$expected_scans") || return 7
                expected_file=$(jq -r '.file' <<< "$scans") || return 7
                expected_hash=$(jq -r '.sbom_sha256' <<< "$scans") || return 7
                [[ "$(_dk_hash "$expected_file")" == "$expected_hash" ]] || return 7
            fi
            hash=$(_dk_verify_attestation "$ref" "$identity" "$issuer" "$work" "$expected_file") || return $?
            [[ -z "$expected_file" || "$(_dk_hash "$expected_file")" == "$expected_hash" ]] || return 7
            rows=$(jq -c --argjson row "$row" --arg hash "$hash" '. + [$row + {predicate_sha256:$hash,status:"verified"}]' <<< "$rows") || return 1
        done <<< "$lines"
    fi
    after=$(_dk_registry_inventory "$image" "$expected" "$work") || return $?
    [[ "$inventory" == "$after" ]] || return 7
    jq -nc --arg image "$image" --arg identity "$identity" --arg issuer "$issuer" --arg action "$action" \
        --argjson skip "$skip" --argjson rows "$rows" '
        {schema_version:1,kind:"dsr-container-evidence",status:"verified",reference:$image,platforms:$rows,
         certificate_identity:$identity,certificate_oidc_issuer:$issuer,
         signature:(if $action == "attest" then "not_checked" elif $skip then "skipped" else "verified" end)}'
)
docker_attest_sbom() { _dk_evidence_command attest "$@"; }
docker_verify_release() { _dk_evidence_command verify "$@"; }

_dk_check_tags() {
    local build="$1" work="$2" tags tag digest
    tags=$(jq -r '.tags[]' <<< "$build") || return 1
    digest=$(jq -r '.digest' <<< "$build") || return 1
    while IFS= read -r tag; do
        docker buildx imagetools inspect "$tag" --raw > "$work/tag.json" || return 8
        [[ "sha256:$(_dk_hash "$work/tag.json")" == "$digest" ]] || {
            _dk_log_error "Published tag no longer refers to this build: $tag"; return 7;
        }
    done <<< "$tags"
}

# Release failures are never downgraded to warnings. Dependencies are checked
# before push; completed external effects are not deleted to hide a late error.
docker_release() (
    local skip=false plan build image work inventory after scans evidence expected result
    local identity="${DOCKER_CERTIFICATE_IDENTITY:-}" issuer="${DOCKER_CERTIFICATE_OIDC_ISSUER:-}"
    local -a args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --certificate-identity|--certificate-oidc-issuer)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || return 4
                case "$1" in --certificate-identity) identity="$2" ;; *) issuer="$2" ;; esac
                shift 2 ;;
            --skip-sign) skip=true; shift ;;
            --help|-h)
                printf '%s\n' 'docker_release - Build, push, sign, and attest container image' \
                    'Usage: docker_release TOOL VERSION [build options] [--skip-sign] [--dry-run]' \
                    '  --certificate-identity ID --certificate-oidc-issuer HTTPS_ISSUER' >&2
                return 0 ;;
            --push|--local|--output) _dk_log_error 'Release requires registry export'; return 4 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    [[ ${#args[@]} -gt 0 ]] || { _dk_log_error 'Tool and version required'; return 4; }
    plan=$(_dk_build_plan "${args[@]}" --push) || return $?
    if [[ $(jq -r '.dry_run' <<< "$plan") == true ]]; then
        jq -c --argjson skip "$skip" '. + {kind:"dsr-container-release",signature:(if $skip then "skipped" else "planned" end),sbom:"planned"}' <<< "$plan"
        return $?
    fi
    _dk_verify_policy "$identity" "$issuer" || return $?
    docker_check_cosign && _dk_dependency syft || return 3
    build=$(_dk_build_execute "$plan") || return $?
    image=$(jq -er '.reference' <<< "$build") || return 1
    _dk_pinned_valid "$image" || return 1
    expected=$(jq -c '.platforms' <<< "$plan") || return 1
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-container-release.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    inventory=$(_dk_registry_inventory "$image" "$expected" "$work") || return $?
    _dk_check_tags "$build" "$work" || return $?
    # Complete ALL scans before publishing any new Cosign evidence.
    scans=$(_dk_prepare_sboms "$inventory" "$work") || return $?
    _dk_check_tags "$build" "$work" || return $?
    if ! $skip; then
        docker_sign "$image" || return $?
        _dk_verify_signature "$image" "$identity" "$issuer" "$work/signature.json" || return $?
    fi
    evidence=$(_dk_publish_sboms "$scans" "$identity" "$issuer" "$work") || return $?
    # Independently reread the entire remote evidence set after all writes.
    local -a verify_args=("$image" --certificate-identity "$identity" --certificate-oidc-issuer "$issuer")
    $skip && verify_args+=(--skip-sign)
    result=$(_dk_evidence_command verify-scans "$image" "$scans" "${verify_args[@]:1}") || return $?
    # An older but valid attestation is not a substitute for the just-scanned one.
    jq -e --argjson published "$evidence" '
        (.platforms | map({reference,predicate_sha256}) | sort_by(.reference)) ==
        ($published | map({reference,predicate_sha256}) | sort_by(.reference))
    ' <<< "$result" >/dev/null || return 7
    after=$(_dk_registry_inventory "$image" "$expected" "$work") || return $?
    [[ "$inventory" == "$after" ]] || return 7
    _dk_check_tags "$build" "$work" || return $?
    jq -nc --argjson build "$build" --argjson skip "$skip" --argjson evidence "$evidence" --argjson result "$result" '
        {schema_version:1,kind:"dsr-container-release",status:"verified",build:$build,
         reference:$build.reference,signature:(if $skip then "skipped" else "verified" end),
         sbom:"verified",platforms:$evidence,verification:$result}'
)

_dk_json() (
    local operation="$1" status=0 output='' error='' work start=$SECONDS
    shift
    _dk_dependency jq || return $?
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-container-json.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    output=$("$operation" "$@" 2> "$work/error") || status=$?
    error=$(head -c 8192 "$work/error")
    jq -nc --arg output "$output" --arg error "$error" --argjson code "$status" --argjson duration "$((SECONDS-start))" '
        ($output | fromjson? // null) as $result |
        {status:(if $code != 0 then "error" elif $result.status == "planned" then "planned" else "success" end),
         exit_code:$code,output:$output,result:$result,diagnostics:$error,duration_seconds:$duration}' || return 1
    return "$status"
)
docker_build_json() { _dk_json docker_build "$@"; }
docker_release_json() { _dk_json docker_release "$@"; }

export -f docker_check docker_check_buildx docker_check_cosign docker_version
export -f docker_setup_buildx docker_check_ghcr_auth docker_login_ghcr
export -f docker_is_containerized docker_find_dockerfile docker_build docker_sign
export -f docker_attest_sbom docker_release docker_build_json docker_release_json
export -f _dk_log_info _dk_log_ok _dk_log_warn _dk_log_error _dk_log_debug
export -f _dk_dependency _dk_resolve_gh_token _dk_tag_valid _dk_repository_valid _dk_pinned_valid
export -f _dk_platforms _dk_hash _dk_build_plan _dk_build_execute _dk_spdx_valid _dk_json
export -f _dk_fetch_manifest _dk_registry_inventory _dk_verify_policy _dk_verify_signature
export -f _dk_verify_attestation _dk_prepare_sboms _dk_publish_sboms _dk_evidence_command
export -f docker_verify_release _dk_check_tags

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    _dk_cmd="${1:-help}"
    [[ $# -eq 0 ]] || shift
    case "$_dk_cmd" in
        build) docker_build "$@" ;;
        release) docker_release "$@" ;;
        sign) docker_sign "$@" ;;
        attest) docker_attest_sbom "$@" ;;
        verify) docker_verify_release "$@" ;;
        build-json) docker_build_json "$@" ;;
        release-json) docker_release_json "$@" ;;
        help|--help|-h) printf '%s\n' 'Usage: bash src/docker.sh build|release|sign|attest|verify|build-json|release-json [options]' ;;
        *) _dk_log_error "Unknown container command: $_dk_cmd"; exit 4 ;;
    esac
    exit $?
fi
