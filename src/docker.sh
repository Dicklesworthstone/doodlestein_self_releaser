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
docker_attest_sbom() (
    local image="${1:-}" dry="${DRY_RUN:-false}" work
    [[ $# -eq 0 ]] || shift
    while [[ $# -gt 0 ]]; do
        case "$1" in --dry-run|-n) dry=true; shift ;; *) return 4 ;; esac
    done
    [[ -n "$image" ]] || { _dk_log_error 'Image reference required'; return 4; }
    _dk_pinned_valid "$image" || return 4
    [[ "$dry" != true ]] || { _dk_log_info "[dry-run] Would attest $image"; return 0; }
    _dk_dependency jq && _dk_dependency syft && docker_check_cosign || return 3
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-container-sbom.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    syft "registry:$image" -o spdx-json > "$work/sbom.json" || return 1
    _dk_spdx_valid "$work/sbom.json" || { _dk_log_error 'Invalid scanner output; refusing attestation'; return 1; }
    cosign attest --yes --predicate "$work/sbom.json" --type spdxjson "$image" >&2 || return 1
)

# Release failures are never downgraded to warnings. Dependencies are checked
# before push; completed external effects are not deleted to hide a late error.
docker_release() {
    local skip=false arg plan build image status
    local -a args=()
    for arg in "$@"; do
        case "$arg" in
            --skip-sign) skip=true ;;
            --help|-h)
                printf '%s\n' 'docker_release - Build, push, sign, and attest container image' \
                    'Usage: docker_release TOOL VERSION [build options] [--skip-sign] [--dry-run]' >&2
                return 0 ;;
            --push|--local|--output) _dk_log_error 'Release requires registry export'; return 4 ;;
            *) args+=("$arg") ;;
        esac
    done
    [[ ${#args[@]} -gt 0 ]] || { _dk_log_error 'Tool and version required'; return 4; }
    plan=$(_dk_build_plan "${args[@]}" --push) || return $?
    if [[ $(jq -r '.dry_run' <<< "$plan") == true ]]; then
        jq -c --argjson skip "$skip" '. + {kind:"dsr-container-release",signature:(if $skip then "skipped" else "planned" end),sbom:"planned"}' <<< "$plan"
        return $?
    fi
    docker_check_cosign && _dk_dependency syft || return 3
    build=$(_dk_build_execute "$plan") || return $?
    image=$(jq -er '.reference' <<< "$build") || return 1
    _dk_pinned_valid "$image" || return 1
    if ! $skip; then
        if docker_sign "$image"; then :; else status=$?; return "$status"; fi
    fi
    if docker_attest_sbom "$image"; then :; else status=$?; return "$status"; fi
    jq -nc --argjson build "$build" --argjson skip "$skip" '
        {schema_version:1,kind:"dsr-container-release",status:"complete",build:$build,
         reference:$build.reference,signature:(if $skip then "skipped" else "submitted" end),sbom:"submitted"}'
}

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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    _dk_cmd="${1:-help}"
    [[ $# -eq 0 ]] || shift
    case "$_dk_cmd" in
        build) docker_build "$@" ;;
        release) docker_release "$@" ;;
        sign) docker_sign "$@" ;;
        attest) docker_attest_sbom "$@" ;;
        build-json) docker_build_json "$@" ;;
        release-json) docker_release_json "$@" ;;
        help|--help|-h) printf '%s\n' 'Usage: bash src/docker.sh build|release|sign|attest|build-json|release-json [options]' ;;
        *) _dk_log_error "Unknown container command: $_dk_cmd"; exit 4 ;;
    esac
    exit $?
fi
