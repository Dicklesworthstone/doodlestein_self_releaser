#!/usr/bin/env bash
# version.sh - Version detection and auto-tagging for dsr
#
# Detects version from language-specific files and creates git tags.
# All git operations use `git -C <repo>` (no global cd).
#
# Usage:
#   source version.sh
#   version_detect "/path/to/repo"          # Returns version from version files
#   version_needs_tag "/path/to/repo"       # Returns 0 if tag needed
#   version_create_tag "/path/to/repo"      # Create and push tag
#
# Supported version sources:
#   | Language | File             | Pattern                |
#   |----------|------------------|------------------------|
#   | Rust     | Cargo.toml       | version = "X.Y.Z"      |
#   | Go       | VERSION, *.go    | Version = "X.Y.Z"      |
#   | Node/Bun | package.json     | "version": "X.Y.Z"     |
#   | Python   | pyproject.toml   | version = "X.Y.Z"      |
#
# Safety:
#   - Uses git plumbing commands (no status parsing)
#   - Dirty tree check before tagging
#   - Tag existence check before creation

set -uo pipefail

# ============================================================================
# Version File Detection
# ============================================================================

# Detect version from repo based on language-specific files
# Args: repo_path [language]
# Returns: version string (without 'v' prefix) or empty
version_detect() {
    local repo_path="$1"
    local language="${2:-}"
    local version=""

    if [[ ! -d "$repo_path" ]]; then
        log_error "Repository not found: $repo_path"
        return 1
    fi

    # If language specified, only check that language's files
    if [[ -n "$language" ]]; then
        version=$(_version_detect_by_language "$repo_path" "$language")
        echo "$version"
        [[ -n "$version" ]]
        return $?
    fi

    # Auto-detect: try each language in order of prevalence
    for lang in rust go node python; do
        version=$(_version_detect_by_language "$repo_path" "$lang")
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    done

    log_debug "No version file found in $repo_path"
    return 1
}

# Internal: Detect version for a specific language
# Args: repo_path language
_version_detect_by_language() {
    local repo_path="$1"
    local language="$2"

    case "$language" in
        rust)
            _version_from_cargo_toml "$repo_path"
            ;;
        go)
            _version_from_go "$repo_path"
            ;;
        node|bun|javascript|typescript)
            _version_from_package_json "$repo_path"
            ;;
        python)
            _version_from_pyproject "$repo_path"
            ;;
        *)
            return 1
            ;;
    esac
}

# Extract version from Cargo.toml
# Pattern: version = "X.Y.Z" (at package level)
_version_from_cargo_toml() {
    local repo_path="$1"
    local cargo_file="$repo_path/Cargo.toml"

    if [[ ! -f "$cargo_file" ]]; then
        return 1
    fi

    # Use grep + sed for simple extraction (no toml parser needed)
    # Look for version = "X.Y.Z" in [package] section
    # This handles most common Cargo.toml formats
    local version
    version=$(grep -m1 '^version\s*=\s*"' "$cargo_file" 2>/dev/null | \
              sed 's/.*version\s*=\s*"\([^"]*\)".*/\1/')

    if [[ -n "$version" && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        echo "$version"
        return 0
    fi
    return 1
}

# Extract version from Go project
# Checks: VERSION file, version.go, main.go (const Version)
_version_from_go() {
    local repo_path="$1"
    local version=""

    # 1. Check VERSION file (common pattern)
    if [[ -f "$repo_path/VERSION" ]]; then
        version=$(head -1 "$repo_path/VERSION" | tr -d '[:space:]')
        if [[ -n "$version" && "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            # Strip leading 'v' if present
            echo "${version#v}"
            return 0
        fi
    fi

    # 2. Check version.go or similar
    local go_version_file
    for go_version_file in "$repo_path/version.go" "$repo_path/internal/version/version.go" \
                           "$repo_path/pkg/version/version.go" "$repo_path/cmd/version.go"; do
        if [[ -f "$go_version_file" ]]; then
            version=$(grep -E '^\s*(const\s+)?Version\s*=\s*"' "$go_version_file" 2>/dev/null | \
                     sed 's/.*=\s*"\([^"]*\)".*/\1/')
            if [[ -n "$version" && "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                echo "${version#v}"
                return 0
            fi
        fi
    done

    # 3. Check main.go for version const/var
    if [[ -f "$repo_path/main.go" ]]; then
        version=$(grep -E '^\s*(const|var)\s+[Vv]ersion\s*=\s*"' "$repo_path/main.go" 2>/dev/null | \
                 head -1 | sed 's/.*=\s*"\([^"]*\)".*/\1/')
        if [[ -n "$version" && "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            echo "${version#v}"
            return 0
        fi
    fi

    return 1
}

# Extract version from package.json (Node.js/Bun)
# Pattern: "version": "X.Y.Z"
_version_from_package_json() {
    local repo_path="$1"
    local pkg_file="$repo_path/package.json"

    if [[ ! -f "$pkg_file" ]]; then
        return 1
    fi

    local version
    # Use jq if available for reliable JSON parsing
    if command -v jq &>/dev/null; then
        version=$(jq -r '.version // empty' "$pkg_file" 2>/dev/null)
    else
        # Fallback: grep + sed (less reliable for edge cases)
        version=$(grep -m1 '"version"' "$pkg_file" 2>/dev/null | \
                 sed 's/.*"version"\s*:\s*"\([^"]*\)".*/\1/')
    fi

    if [[ -n "$version" && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        echo "$version"
        return 0
    fi
    return 1
}

# Extract version from pyproject.toml (Python)
# Pattern: version = "X.Y.Z" in [project] or [tool.poetry] section
_version_from_pyproject() {
    local repo_path="$1"
    local pyproject_file="$repo_path/pyproject.toml"

    if [[ ! -f "$pyproject_file" ]]; then
        return 1
    fi

    local version
    # Simple grep for version line (handles most cases)
    version=$(grep -m1 '^version\s*=\s*"' "$pyproject_file" 2>/dev/null | \
             sed 's/.*version\s*=\s*"\([^"]*\)".*/\1/')

    if [[ -n "$version" && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        echo "$version"
        return 0
    fi
    return 1
}

# ============================================================================
# Tag Operations
# ============================================================================

# Check if a tag is needed for the detected version
# Args: repo_path
# Returns: 0 if tag needed, 1 if already tagged or no version
version_needs_tag() {
    local repo_path="$1"

    local version
    if ! version=$(version_detect "$repo_path"); then
        log_debug "No version detected in $repo_path"
        return 1
    fi

    local tag="v$version"

    # Check if tag exists using git_ops if available
    if declare -f git_ops_tag_exists &>/dev/null; then
        if git_ops_tag_exists "$repo_path" "$tag"; then
            log_debug "Tag $tag already exists"
            return 1
        fi
    else
        # Fallback: direct git command
        if git -C "$repo_path" show-ref --tags --verify "refs/tags/$tag" &>/dev/null; then
            log_debug "Tag $tag already exists"
            return 1
        fi
    fi

    log_info "Tag $tag needed for $repo_path"
    return 0
}

# Create and optionally push a tag for the detected version
# Args: repo_path [--push] [--dry-run] [--message "msg"]
# Returns: 0 on success
version_create_tag() {
    local repo_path="$1"
    shift

    local push=false
    local dry_run=false
    local message=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --push) push=true; shift ;;
            --dry-run|-n) dry_run=true; shift ;;
            --message|-m) message="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Detect version
    local version
    if ! version=$(version_detect "$repo_path"); then
        log_error "Cannot detect version in $repo_path"
        return 1
    fi

    local tag="v$version"

    # Check if tag already exists
    if git -C "$repo_path" show-ref --tags --verify "refs/tags/$tag" &>/dev/null; then
        log_warn "Tag $tag already exists"
        return 0
    fi

    # Check for dirty tree (unless --dry-run)
    if ! $dry_run; then
        if declare -f git_ops_is_dirty &>/dev/null; then
            if git_ops_is_dirty "$repo_path"; then
                log_error "Working tree has uncommitted changes. Commit first."
                return 1
            fi
        else
            # Fallback
            if ! git -C "$repo_path" diff-index --quiet HEAD -- 2>/dev/null; then
                log_error "Working tree has uncommitted changes. Commit first."
                return 1
            fi
        fi
    fi

    # Default message
    [[ -z "$message" ]] && message="Release $version"

    if $dry_run; then
        log_info "[DRY-RUN] Would create tag: $tag"
        log_info "[DRY-RUN] Message: $message"
        $push && log_info "[DRY-RUN] Would push tag to origin"
        return 0
    fi

    # Create annotated tag
    log_info "Creating tag $tag..."
    if ! git -C "$repo_path" tag -a "$tag" -m "$message"; then
        log_error "Failed to create tag $tag"
        return 1
    fi
    log_ok "Created tag $tag"

    # Push if requested
    if $push; then
        log_info "Pushing tag $tag to origin..."
        if ! git -C "$repo_path" push origin "$tag"; then
            log_error "Failed to push tag $tag"
            return 1
        fi
        log_ok "Pushed tag $tag to origin"
    else
        log_info "Tag created locally. Push with: git -C '$repo_path' push origin $tag"
    fi

    return 0
}

# ============================================================================
# JSON Output
# ============================================================================

# Get version info as JSON
# Args: repo_path
version_info_json() {
    local repo_path="$1"
    local version="" tag="" tag_exists=false needs_tag=false language=""

    # Detect version
    if version=$(version_detect "$repo_path"); then
        tag="v$version"

        # Check tag status
        if git -C "$repo_path" show-ref --tags --verify "refs/tags/$tag" &>/dev/null; then
            tag_exists=true
        else
            needs_tag=true
        fi

        # Detect language
        if [[ -f "$repo_path/Cargo.toml" ]]; then
            language="rust"
        elif [[ -f "$repo_path/go.mod" ]] || [[ -f "$repo_path/go.sum" ]]; then
            language="go"
        elif [[ -f "$repo_path/package.json" ]]; then
            language="node"
        elif [[ -f "$repo_path/pyproject.toml" ]]; then
            language="python"
        fi
    fi

    # Use jq for safe JSON construction
    jq -nc \
        --arg repo_path "$repo_path" \
        --arg version "$version" \
        --arg tag "$tag" \
        --argjson tag_exists "$tag_exists" \
        --argjson needs_tag "$needs_tag" \
        --arg language "$language" \
        '{
            repo_path: $repo_path,
            version: $version,
            tag: $tag,
            tag_exists: $tag_exists,
            needs_tag: $needs_tag,
            language: $language
        }'
}

# ============================================================================
# Batch Operations
# ============================================================================

# Detect and optionally tag all configured tools
# Args: [--push] [--dry-run] [--json]
# Uses: ACT_REPOS_DIR from act_runner.sh
version_tag_all() {
    local push=false
    local dry_run=false
    local json_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --push) push=true; shift ;;
            --dry-run|-n) dry_run=true; shift ;;
            --json) json_mode=true; shift ;;
            *) shift ;;
        esac
    done

    local repos_dir="${ACT_REPOS_DIR:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d}"

    if [[ ! -d "$repos_dir" ]]; then
        log_error "repos.d directory not found: $repos_dir"
        return 4
    fi

    local config_file tool_name local_path
    local results=()
    local tagged=0 skipped=0 failed=0

    for config_file in "$repos_dir"/*.yaml; do
        [[ -f "$config_file" ]] || continue
        [[ "$(basename "$config_file")" == _* ]] && continue  # Skip templates

        tool_name=$(basename "$config_file" .yaml)

        # Get local_path from config
        if command -v yq &>/dev/null; then
            local_path=$(yq -r '.local_path // ""' "$config_file" 2>/dev/null)
        else
            local_path=$(grep '^local_path:' "$config_file" 2>/dev/null | \
                        sed 's/local_path:\s*//' | tr -d '"' | tr -d "'")
        fi

        if [[ -z "$local_path" || ! -d "$local_path" ]]; then
            log_debug "Skipping $tool_name: local_path not found"
            ((skipped++))
            continue
        fi

        # Check if tag needed
        if ! version_needs_tag "$local_path"; then
            log_debug "Skipping $tool_name: already tagged or no version"
            ((skipped++))
            continue
        fi

        # Create tag
        local tag_args=""
        $push && tag_args+=" --push"
        $dry_run && tag_args+=" --dry-run"

        # shellcheck disable=SC2086
        if version_create_tag "$local_path" $tag_args; then
            ((tagged++))
            results+=("$(jq -nc --arg tool "$tool_name" '{tool: $tool, status: "tagged"}')")
        else
            ((failed++))
            results+=("$(jq -nc --arg tool "$tool_name" '{tool: $tool, status: "failed"}')")
        fi
    done

    if $json_mode; then
        echo "{"
        echo "  \"tagged\": $tagged,"
        echo "  \"skipped\": $skipped,"
        echo "  \"failed\": $failed,"
        echo "  \"results\": ["
        local first=true
        for r in "${results[@]}"; do
            $first || echo ","
            first=false
            echo -n "    $r"
        done
        echo ""
        echo "  ]"
        echo "}"
    else
        log_info "Version tagging complete: $tagged tagged, $skipped skipped, $failed failed"
    fi

    [[ $failed -eq 0 ]]
}

# Export functions
export -f version_detect version_needs_tag version_create_tag version_info_json version_tag_all
export -f _version_detect_by_language _version_from_cargo_toml _version_from_go
export -f _version_from_package_json _version_from_pyproject
