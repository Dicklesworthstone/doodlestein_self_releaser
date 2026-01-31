#!/usr/bin/env bash
# src/docker.sh - Multi-arch Docker image building for containerized tools
#
# bd-1jt.3.8: Build multi-arch Docker images for containerized tools
#
# Builds and publishes multi-architecture Docker images (amd64/arm64) for tools
# that support containerization. Uses docker buildx for cross-platform builds
# and cosign for keyless signing.
#
# Usage:
#   source "$SCRIPT_DIR/src/docker.sh"
#   docker_build <tool> <version>
#   docker_sign <image>
#   docker_push <image>
#
# Required modules:
#   - logging.sh (for log_info, log_error, etc.)

set -uo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Default registry
DOCKER_REGISTRY="${DOCKER_REGISTRY:-ghcr.io/dicklesworthstone}"

# Default platforms for multi-arch builds
DOCKER_PLATFORMS="${DOCKER_PLATFORMS:-linux/amd64,linux/arm64}"

# Buildx builder name
DOCKER_BUILDER_NAME="${DOCKER_BUILDER_NAME:-dsr-builder}"

# Tools that have Dockerfiles and should be containerized
DOCKER_CONTAINERIZED_TOOLS="${DOCKER_CONTAINERIZED_TOOLS:-ubs,mcp_agent_mail,process_triage}"

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _DK_RED=$'\033[0;31m'
    _DK_GREEN=$'\033[0;32m'
    _DK_YELLOW=$'\033[0;33m'
    _DK_BLUE=$'\033[0;34m'
    _DK_NC=$'\033[0m'
else
    _DK_RED='' _DK_GREEN='' _DK_YELLOW='' _DK_BLUE='' _DK_NC=''
fi

_dk_log_info()  { echo "${_DK_BLUE}[docker]${_DK_NC} $*" >&2; }
_dk_log_ok()    { echo "${_DK_GREEN}[docker]${_DK_NC} $*" >&2; }
_dk_log_warn()  { echo "${_DK_YELLOW}[docker]${_DK_NC} $*" >&2; }
_dk_log_error() { echo "${_DK_RED}[docker]${_DK_NC} $*" >&2; }
_dk_log_debug() { [[ "${DOCKER_DEBUG:-}" == "1" ]] && echo "${_DK_BLUE}[docker:debug]${_DK_NC} $*" >&2 || true; }

# ============================================================================
# Dependency Checking
# ============================================================================

# Check if docker is available and running
# Returns: 0 if available, 3 if not
docker_check() {
    if ! command -v docker &>/dev/null; then
        _dk_log_error "docker not installed"
        _dk_log_info "Install from: https://docs.docker.com/engine/install/"
        return 3
    fi

    if ! docker info &>/dev/null; then
        _dk_log_error "Docker daemon not running"
        _dk_log_info "Start Docker daemon or check permissions"
        return 3
    fi

    return 0
}

# Check if buildx is available and configured
# Returns: 0 if available, 3 if not
docker_check_buildx() {
    if ! docker_check; then
        return 3
    fi

    if ! docker buildx version &>/dev/null; then
        _dk_log_error "docker buildx not available"
        _dk_log_info "Update Docker or install buildx plugin"
        return 3
    fi

    return 0
}

# Check if cosign is available
# Returns: 0 if available, 3 if not
docker_check_cosign() {
    if ! command -v cosign &>/dev/null; then
        _dk_log_warn "cosign not installed - container signing unavailable"
        _dk_log_info "Install: go install github.com/sigstore/cosign/v2/cmd/cosign@latest"
        return 3
    fi

    return 0
}

# Get docker version
docker_version() {
    if ! docker_check; then
        return 1
    fi
    docker version --format '{{.Server.Version}}' 2>/dev/null
}

# ============================================================================
# Buildx Setup
# ============================================================================

# Ensure buildx builder exists and is ready
# Returns: 0 on success
docker_setup_buildx() {
    if ! docker_check_buildx; then
        return 3
    fi

    # Check if builder already exists
    if docker buildx inspect "$DOCKER_BUILDER_NAME" &>/dev/null; then
        _dk_log_debug "Using existing builder: $DOCKER_BUILDER_NAME"
        docker buildx use "$DOCKER_BUILDER_NAME"
        return 0
    fi

    # Create new builder
    _dk_log_info "Creating buildx builder: $DOCKER_BUILDER_NAME"
    docker buildx create \
        --name "$DOCKER_BUILDER_NAME" \
        --driver docker-container \
        --platform "$DOCKER_PLATFORMS" \
        --use &>/dev/null || {
        _dk_log_error "Failed to create buildx builder"
        return 1
    }

    # Bootstrap builder
    docker buildx inspect --bootstrap &>/dev/null || {
        _dk_log_error "Failed to bootstrap buildx builder"
        return 1
    }

    _dk_log_ok "Buildx builder ready: $DOCKER_BUILDER_NAME"
    return 0
}

# ============================================================================
# GHCR Authentication
# ============================================================================

# Check if authenticated to GHCR
# Returns: 0 if authenticated, 3 if not
docker_check_ghcr_auth() {
    # Try a simple auth check
    if docker manifest inspect ghcr.io/dicklesworthstone/test-auth-check &>/dev/null 2>&1; then
        return 0
    fi

    # Check if GITHUB_TOKEN is available
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        return 0
    fi

    # Check if gh can provide token
    if command -v gh &>/dev/null && gh auth status &>/dev/null; then
        return 0
    fi

    _dk_log_error "GHCR authentication required"
    _dk_log_info "Run: echo \$GITHUB_TOKEN | docker login ghcr.io -u \$USER --password-stdin"
    _dk_log_info "Or: gh auth token | docker login ghcr.io -u \$USER --password-stdin"
    return 3
}

# Login to GHCR
docker_login_ghcr() {
    local token=""

    # Try GITHUB_TOKEN first
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        token="$GITHUB_TOKEN"
    elif command -v gh &>/dev/null && gh auth status &>/dev/null; then
        token=$(gh auth token 2>/dev/null)
    else
        _dk_log_error "No GitHub token available"
        return 3
    fi

    echo "$token" | docker login ghcr.io -u "${GITHUB_USER:-$USER}" --password-stdin &>/dev/null || {
        _dk_log_error "GHCR login failed"
        return 3
    }

    _dk_log_ok "Logged in to GHCR"
    return 0
}

# ============================================================================
# Docker Build
# ============================================================================

# Check if a tool should be containerized
# Args: tool_name
# Returns: 0 if containerized, 1 if not
docker_is_containerized() {
    local tool="$1"
    [[ ",$DOCKER_CONTAINERIZED_TOOLS," == *",$tool,"* ]]
}

# Find Dockerfile for a tool
# Args: tool_name [repo_path]
# Returns: path to Dockerfile on stdout, 1 if not found
docker_find_dockerfile() {
    local tool="$1"
    local repo_path="${2:-/data/projects/$tool}"

    local dockerfile_paths=(
        "$repo_path/Dockerfile"
        "$repo_path/docker/Dockerfile"
        "$repo_path/build/Dockerfile"
    )

    for df in "${dockerfile_paths[@]}"; do
        if [[ -f "$df" ]]; then
            echo "$df"
            return 0
        fi
    done

    return 1
}

# Build multi-arch Docker image
# Args: tool version [--push] [--local] [--platform <platforms>] [--dry-run]
docker_build() {
    local tool=""
    local version=""
    local push=false
    local local_only=false
    local platforms="$DOCKER_PLATFORMS"
    local dry_run=false
    local extra_tags=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool|-t) tool="$2"; shift 2 ;;
            --version|-V) version="$2"; shift 2 ;;
            --push) push=true; shift ;;
            --local) local_only=true; shift ;;
            --platform|-p) platforms="$2"; shift 2 ;;
            --tag) extra_tags+=("$2"); shift 2 ;;
            --dry-run|-n) dry_run=true; shift ;;
            --help|-h)
                cat << 'EOF'
docker_build - Build multi-arch Docker image

USAGE:
    docker_build <tool> <version>
    docker_build --tool <name> --version <tag> [options]

OPTIONS:
    -t, --tool <name>       Tool to build
    -V, --version <ver>     Version/tag
    --push                  Push to registry after build
    --local                 Build for local platform only
    -p, --platform <list>   Platforms (default: linux/amd64,linux/arm64)
    --tag <tag>             Additional tags (can repeat)
    -n, --dry-run           Show what would be done

EXAMPLES:
    docker_build ubs v1.2.3
    docker_build ubs v1.2.3 --push
    docker_build ubs v1.2.3 --local
    docker_build ubs v1.2.3 --tag latest --push

EXIT CODES:
    0  - Build successful
    1  - Build failed
    3  - Dependency error
    4  - Invalid arguments
    7  - No Dockerfile found
EOF
                return 0
                ;;
            -*)
                _dk_log_error "Unknown option: $1"
                return 4
                ;;
            *)
                if [[ -z "$tool" ]]; then
                    tool="$1"
                elif [[ -z "$version" ]]; then
                    version="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$tool" ]]; then
        _dk_log_error "Tool name required"
        return 4
    fi

    if [[ -z "$version" ]]; then
        _dk_log_error "Version required"
        return 4
    fi

    # Normalize version
    local tag="${version#v}"
    tag="v$tag"

    # Check if tool should be containerized
    if ! docker_is_containerized "$tool"; then
        _dk_log_warn "$tool is not in the containerized tools list"
        _dk_log_info "Containerized tools: $DOCKER_CONTAINERIZED_TOOLS"
    fi

    # Check dependencies
    if ! docker_setup_buildx; then
        return 3
    fi

    # Find Dockerfile
    local repo_path="/data/projects/$tool"
    local dockerfile
    if ! dockerfile=$(docker_find_dockerfile "$tool" "$repo_path"); then
        _dk_log_error "No Dockerfile found for $tool"
        _dk_log_info "Looked in: $repo_path/Dockerfile, $repo_path/docker/Dockerfile"
        return 7
    fi

    _dk_log_info "Found Dockerfile: $dockerfile"

    # Build image name
    local image_name="$DOCKER_REGISTRY/$tool"
    local full_tag="$image_name:$tag"

    # Build tags array
    local tags=("$full_tag")
    tags+=("$image_name:latest")
    for extra_tag in "${extra_tags[@]}"; do
        tags+=("$image_name:$extra_tag")
    done

    # Build tag arguments
    local tag_args=()
    for t in "${tags[@]}"; do
        tag_args+=(--tag "$t")
    done

    _dk_log_info "Building $tool $tag"
    _dk_log_info "Platforms: $platforms"
    _dk_log_info "Tags: ${tags[*]}"

    if $dry_run; then
        _dk_log_info "[dry-run] Would build: $full_tag"
        _dk_log_info "[dry-run] Dockerfile: $dockerfile"
        _dk_log_info "[dry-run] Context: $(dirname "$dockerfile")"
        _dk_log_info "[dry-run] Platforms: $platforms"
        $push && _dk_log_info "[dry-run] Would push to registry"
        return 0
    fi

    # Build arguments
    local build_args=(
        --file "$dockerfile"
        --platform "$platforms"
        "${tag_args[@]}"
        --provenance=true
        --sbom=true
    )

    # Add push or load based on options
    if $push; then
        if ! docker_check_ghcr_auth; then
            docker_login_ghcr || return 3
        fi
        build_args+=(--push)
    elif $local_only; then
        # For local builds, we can only load single-platform
        build_args=(
            --file "$dockerfile"
            "${tag_args[@]}"
            --load
        )
    else
        # Multi-arch without push - need to use --output
        build_args+=(--output "type=image,push=false")
    fi

    # Build context is the directory containing the Dockerfile
    local build_context
    build_context=$(dirname "$dockerfile")

    # Execute build
    local start_time
    start_time=$(date +%s)

    if docker buildx build "${build_args[@]}" "$build_context"; then
        local end_time duration
        end_time=$(date +%s)
        duration=$((end_time - start_time))

        _dk_log_ok "Built $full_tag in ${duration}s"

        if $push; then
            _dk_log_ok "Pushed to $DOCKER_REGISTRY"
        fi

        return 0
    else
        _dk_log_error "Build failed for $tool"
        return 1
    fi
}

# ============================================================================
# Container Signing
# ============================================================================

# Sign a container image with cosign (keyless)
# Args: image [--dry-run]
docker_sign() {
    local image=""
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n) dry_run=true; shift ;;
            --help|-h)
                cat << 'EOF'
docker_sign - Sign container image with cosign

USAGE:
    docker_sign <image>

OPTIONS:
    -n, --dry-run    Show what would be done

DESCRIPTION:
    Signs the container image using cosign keyless signing
    (Sigstore/Fulcio). Requires OIDC authentication.

EXAMPLES:
    docker_sign ghcr.io/dicklesworthstone/ubs:v1.2.3

EXIT CODES:
    0  - Signing successful
    1  - Signing failed
    3  - Cosign not available
EOF
                return 0
                ;;
            -*)
                _dk_log_error "Unknown option: $1"
                return 4
                ;;
            *)
                image="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$image" ]]; then
        _dk_log_error "Image reference required"
        return 4
    fi

    if ! docker_check_cosign; then
        return 3
    fi

    _dk_log_info "Signing image: $image"

    if $dry_run; then
        _dk_log_info "[dry-run] Would sign: $image"
        return 0
    fi

    # Keyless signing with cosign
    if cosign sign --yes "$image" 2>&1; then
        _dk_log_ok "Signed: $image"
        return 0
    else
        _dk_log_error "Signing failed for: $image"
        return 1
    fi
}

# Attach SBOM attestation to container image
# Args: image [--dry-run]
docker_attest_sbom() {
    local image=""
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n) dry_run=true; shift ;;
            -*)
                _dk_log_error "Unknown option: $1"
                return 4
                ;;
            *)
                image="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$image" ]]; then
        _dk_log_error "Image reference required"
        return 4
    fi

    if ! docker_check_cosign; then
        return 3
    fi

    if ! command -v syft &>/dev/null; then
        _dk_log_warn "syft not installed - SBOM attestation unavailable"
        return 3
    fi

    _dk_log_info "Attaching SBOM attestation to: $image"

    if $dry_run; then
        _dk_log_info "[dry-run] Would attach SBOM to: $image"
        return 0
    fi

    # Generate SBOM and attest in one pipeline
    if syft "$image" -o spdx-json 2>/dev/null | cosign attest --yes --predicate - --type spdx "$image" 2>&1; then
        _dk_log_ok "SBOM attestation attached: $image"
        return 0
    else
        _dk_log_error "SBOM attestation failed for: $image"
        return 1
    fi
}

# ============================================================================
# Full Workflow
# ============================================================================

# Build, push, sign, and attest a container image
# Args: tool version [--dry-run]
docker_release() {
    local tool=""
    local version=""
    local dry_run=false
    local skip_sign=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool|-t) tool="$2"; shift 2 ;;
            --version|-V) version="$2"; shift 2 ;;
            --dry-run|-n) dry_run=true; shift ;;
            --skip-sign) skip_sign=true; shift ;;
            --help|-h)
                cat << 'EOF'
docker_release - Build, push, sign, and attest container image

USAGE:
    docker_release <tool> <version>
    docker_release --tool <name> --version <tag> [options]

OPTIONS:
    -t, --tool <name>    Tool to release
    -V, --version <ver>  Version/tag
    --skip-sign          Skip cosign signing
    -n, --dry-run        Show what would be done

DESCRIPTION:
    Full container release workflow:
    1. Build multi-arch image with buildx
    2. Push to GHCR
    3. Sign with cosign (keyless)
    4. Attach SBOM attestation

EXAMPLES:
    docker_release ubs v1.2.3
    docker_release mcp_agent_mail v2.0.0 --dry-run

EXIT CODES:
    0  - Release successful
    1  - Release failed
    3  - Dependency error
    7  - No Dockerfile found
EOF
                return 0
                ;;
            -*)
                _dk_log_error "Unknown option: $1"
                return 4
                ;;
            *)
                if [[ -z "$tool" ]]; then
                    tool="$1"
                elif [[ -z "$version" ]]; then
                    version="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$tool" || -z "$version" ]]; then
        _dk_log_error "Tool and version required"
        return 4
    fi

    # Normalize version
    local tag="${version#v}"
    tag="v$tag"

    local image="$DOCKER_REGISTRY/$tool:$tag"

    _dk_log_info "=== Docker Release: $tool $tag ==="

    local start_time
    start_time=$(date +%s)

    # Step 1: Build and push
    _dk_log_info "Step 1/3: Building and pushing..."
    local build_args=(--tool "$tool" --version "$version" --push)
    $dry_run && build_args+=(--dry-run)

    if ! docker_build "${build_args[@]}"; then
        _dk_log_error "Build/push failed"
        return 1
    fi

    # Step 2: Sign (optional)
    if ! $skip_sign; then
        _dk_log_info "Step 2/3: Signing..."
        local sign_args=("$image")
        $dry_run && sign_args+=(--dry-run)

        if ! docker_sign "${sign_args[@]}"; then
            _dk_log_warn "Signing failed (continuing anyway)"
        fi
    else
        _dk_log_info "Step 2/3: Signing skipped"
    fi

    # Step 3: Attest SBOM
    _dk_log_info "Step 3/3: Attaching SBOM attestation..."
    local attest_args=("$image")
    $dry_run && attest_args+=(--dry-run)

    if ! docker_attest_sbom "${attest_args[@]}"; then
        _dk_log_warn "SBOM attestation failed (continuing anyway)"
    fi

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    _dk_log_ok "=== Docker Release Complete ==="
    _dk_log_info "Image: $image"
    _dk_log_info "Duration: ${duration}s"

    return 0
}

# ============================================================================
# JSON Output
# ============================================================================

# Build with JSON output
docker_build_json() {
    local args=("$@")
    local start_time
    start_time=$(date +%s)

    local output status="success" exit_code=0
    output=$(docker_build "${args[@]}" 2>&1) || {
        exit_code=$?
        status="error"
    }

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    jq -nc \
        --arg status "$status" \
        --argjson exit_code "$exit_code" \
        --arg output "$output" \
        --argjson duration "$duration" \
        '{
            status: $status,
            exit_code: $exit_code,
            output: $output,
            duration_seconds: $duration
        }'
}

# Release with JSON output
docker_release_json() {
    local args=("$@")
    local start_time
    start_time=$(date +%s)

    local output status="success" exit_code=0
    output=$(docker_release "${args[@]}" 2>&1) || {
        exit_code=$?
        status="error"
    }

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    jq -nc \
        --arg status "$status" \
        --argjson exit_code "$exit_code" \
        --arg output "$output" \
        --argjson duration "$duration" \
        '{
            status: $status,
            exit_code: $exit_code,
            output: $output,
            duration_seconds: $duration
        }'
}

# ============================================================================
# Exports
# ============================================================================

export -f docker_check docker_check_buildx docker_check_cosign docker_version
export -f docker_setup_buildx docker_check_ghcr_auth docker_login_ghcr
export -f docker_is_containerized docker_find_dockerfile docker_build
export -f docker_sign docker_attest_sbom docker_release
export -f docker_build_json docker_release_json
