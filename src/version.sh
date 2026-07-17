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
# Args: repo_path [language] [main_package]
# Returns: version string (without 'v' prefix) or empty
version_detect() {
    local repo_path="$1"
    local language="${2:-}"
    local main_package="${3:-}"
    local version=""

    if [[ ! -d "$repo_path" ]]; then
        log_error "Repository not found: $repo_path"
        return 1
    fi

    # If language specified, only check that language's files
    if [[ -n "$language" ]]; then
        version=$(_version_detect_by_language "$repo_path" "$language" "$main_package")
        echo "$version"
        [[ -n "$version" ]]
        return $?
    fi

    # A root Cargo.toml is authoritative evidence that this is a Rust project.
    # If its workspace version is missing or ambiguous, fail closed instead of
    # falling through to an unrelated package.json/VERSION file and inventing a
    # release tag from a secondary ecosystem manifest.
    if [[ -f "$repo_path/Cargo.toml" ]]; then
        _version_from_cargo_toml "$repo_path" "$main_package"
        return $?
    fi

    # Auto-detect: try each language in order of prevalence
    for lang in go node python; do
        version=$(_version_detect_by_language "$repo_path" "$lang" "$main_package")
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    done

    log_debug "No version file found in $repo_path"
    return 1
}

# Internal: Detect version for a specific language
# Args: repo_path language [main_package]
_version_detect_by_language() {
    local repo_path="$1"
    local language="$2"
    local main_package="${3:-}"

    case "$language" in
        rust)
            _version_from_cargo_toml "$repo_path" "$main_package"
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

# Extract one scalar TOML key from an exact table. This fallback is deliberately
# section-aware: a dependency/profile version must never be mistaken for the
# package version.
_version_from_toml_table() {
    local toml_file="$1"
    local table="$2"
    local key="$3"
    local line=""

    line=$(awk -v wanted="[$table]" -v wanted_key="$key" '
        /^[[:space:]]*\[[^]]+\][[:space:]]*(#.*)?$/ {
            current = $0
            sub(/[[:space:]]*#.*/, "", current)
            gsub(/[[:space:]]/, "", current)
            next
        }
        current == wanted && $0 ~ "^[[:space:]]*" wanted_key "[[:space:]]*=" {
            print
            exit
        }
    ' "$toml_file")

    [[ -n "$line" ]] || return 1
    printf '%s\n' "$line" | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*/\1/'
}

# Extract a Rust package/workspace version without guessing.
#
# A normal root package is read directly from its exact [package] table. A
# virtual workspace is resolved through read-only Cargo metadata so inherited
# versions, publish=false members, and configured package names are handled by
# Cargo's own TOML semantics. Ambiguous workspaces fail closed.
_version_from_cargo_toml() {
    local repo_path="$1"
    local main_package="${2:-}"
    local cargo_file="$repo_path/Cargo.toml"

    if [[ ! -f "$cargo_file" ]]; then
        return 1
    fi

    local root_version=""
    root_version=$(_version_from_toml_table "$cargo_file" package version 2>/dev/null || true)
    if [[ -z "$main_package" && -n "$root_version" ]]; then
        if [[ "$root_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            echo "$root_version"
            return 0
        fi
        log_error "Invalid Rust package version in $cargo_file: $root_version"
        return 1
    fi

    if ! command -v cargo &>/dev/null || ! command -v jq &>/dev/null; then
        log_error "Cannot resolve virtual Rust workspace version in $repo_path: cargo and jq are required"
        return 1
    fi

    local metadata=""
    if ! metadata=$(cargo metadata \
        --format-version 1 \
        --no-deps \
        --locked \
        --offline \
        --manifest-path "$cargo_file" 2>/dev/null); then
        log_error "Cannot resolve Rust workspace version in $repo_path: 'cargo metadata --locked --offline' failed; ensure Cargo.lock is current"
        return 1
    fi

    local members_json=""
    if ! members_json=$(printf '%s\n' "$metadata" | jq -ce '
        [.workspace_members[] as $member_id
         | .packages[]
         | select(.id == $member_id)]
        | unique_by(.id)
    ' 2>/dev/null); then
        log_error "Cannot resolve Rust workspace version in $repo_path: Cargo metadata was malformed"
        return 1
    fi

    if [[ -n "$main_package" ]]; then
        local main_manifest=""
        local main_candidate="$repo_path/$main_package"
        if [[ "$main_package" == "." ]]; then
            main_candidate="$repo_path"
        fi
        if [[ -d "$main_candidate" ]]; then
            main_candidate="$main_candidate/Cargo.toml"
        fi
        if [[ -f "$main_candidate" ]]; then
            if declare -f resolve_path &>/dev/null; then
                main_manifest=$(resolve_path "$main_candidate" --must-exist 2>/dev/null || true)
            elif command -v realpath &>/dev/null; then
                main_manifest=$(realpath "$main_candidate" 2>/dev/null || true)
            else
                # macOS does not provide GNU `readlink -f`. Resolve the parent
                # in a subshell so the caller's working directory never moves.
                main_manifest=$(
                    builtin cd "$(dirname "$main_candidate")" 2>/dev/null \
                        && printf '%s/%s\n' "$(pwd -P)" "$(basename "$main_candidate")"
                ) || main_manifest=""
            fi
        fi

        local matches_json="" match_count=0
        matches_json=$(printf '%s\n' "$members_json" | jq -ce \
            --arg package "$main_package" \
            --arg manifest "$main_manifest" '
                [.[]
                 | select(
                     .name == $package
                     or ($manifest != "" and .manifest_path == $manifest)
                     or any(.targets[]?; .name == $package)
                 )]
            ') || return 1
        match_count=$(printf '%s\n' "$matches_json" | jq -r 'length')
        if [[ "$match_count" -ne 1 ]]; then
            log_error "Configured Rust main_package '$main_package' matched $match_count workspace packages in $repo_path; refusing ambiguous version detection"
            return 1
        fi
        printf '%s\n' "$matches_json" | jq -r '.[0].version'
        return 0
    fi

    local versions_json="" version_count=0
    local used_all_members=false
    versions_json=$(printf '%s\n' "$members_json" | jq -ce \
        '[.[] | select(.publish != []) | .version] | unique') || return 1
    if [[ "$(printf '%s\n' "$versions_json" | jq -r 'length')" -eq 0 ]]; then
        used_all_members=true
        versions_json=$(printf '%s\n' "$members_json" | jq -ce \
            '[.[].version] | unique') || return 1
    fi
    version_count=$(printf '%s\n' "$versions_json" | jq -r 'length')
    if [[ "$version_count" -eq 0 ]]; then
        log_error "No Rust workspace package version source found in $repo_path"
        return 1
    fi
    if [[ "$version_count" -eq 1 ]]; then
        printf '%s\n' "$versions_json" | jq -r '.[0]'
        return 0
    fi

    local version_inventory=""
    if $used_all_members; then
        version_inventory=$(printf '%s\n' "$members_json" | jq -r \
            '[.[] | "\(.name)=\(.version)"] | join(", ")')
    else
        version_inventory=$(printf '%s\n' "$members_json" | jq -r \
            '[.[] | select(.publish != []) | "\(.name)=\(.version)"] | join(", ")')
    fi
    log_error "Ambiguous Rust workspace versions in $repo_path: $version_inventory; configure main_package explicitly"
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
            version=$(grep -E '^[[:space:]]*(const[[:space:]]+)?Version[[:space:]]*=[[:space:]]*"' "$go_version_file" 2>/dev/null | \
                     sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
            if [[ -n "$version" && "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                echo "${version#v}"
                return 0
            fi
        fi
    done

    # 3. Check main.go for version const/var
    if [[ -f "$repo_path/main.go" ]]; then
        version=$(grep -E '^[[:space:]]*(const|var)[[:space:]]+[Vv]ersion[[:space:]]*=[[:space:]]*"' "$repo_path/main.go" 2>/dev/null | \
                 head -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
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
                 sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
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
    version=$(grep -E -m1 '^[[:space:]]*version[[:space:]]*=[[:space:]]*"' "$pyproject_file" 2>/dev/null | \
             sed -E 's/.*version[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')

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
# Args: repo_path [language] [main_package]
# Returns: 0 if tag needed, 1 if already tagged or no version
version_needs_tag() {
    local repo_path="$1"
    local language="${2:-}"
    local main_package="${3:-}"

    local version
    if ! version=$(version_detect "$repo_path" "$language" "$main_package"); then
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
#                 [--language language] [--main-package package]
# Returns: 0 on success
version_create_tag() {
    local repo_path="$1"
    shift

    local push=false
    local dry_run=false
    local message=""
    local language=""
    local main_package=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --push) push=true; shift ;;
            --dry-run|-n) dry_run=true; shift ;;
            --message|-m) message="$2"; shift 2 ;;
            --language) language="${2:-}"; shift 2 ;;
            --main-package) main_package="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Detect version
    local version
    if ! version=$(version_detect "$repo_path" "$language" "$main_package"); then
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
# Args: repo_path [language] [main_package]
version_info_json() {
    local repo_path="$1"
    local configured_language="${2:-}"
    local main_package="${3:-}"
    local version="" tag="" tag_exists=false needs_tag=false language=""

    # An empty/ambiguous version is an error, not a successful JSON record with
    # blank fields. Callers must not be able to turn that record into a tag.
    if ! version=$(version_detect "$repo_path" "$configured_language" "$main_package"); then
        return 1
    fi
    tag="v$version"

    # Check tag status
    if git -C "$repo_path" show-ref --tags --verify "refs/tags/$tag" &>/dev/null; then
        tag_exists=true
    else
        needs_tag=true
    fi

    # Detect language
    if [[ -n "$configured_language" ]]; then
        language="$configured_language"
    elif [[ -f "$repo_path/Cargo.toml" ]]; then
        language="rust"
    elif [[ -f "$repo_path/go.mod" ]] || [[ -f "$repo_path/go.sum" ]]; then
        language="go"
    elif [[ -f "$repo_path/package.json" ]]; then
        language="node"
    elif [[ -f "$repo_path/pyproject.toml" ]]; then
        language="python"
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

        local language="" main_package=""
        if command -v yq &>/dev/null; then
            language=$(yq -r '.language // ""' "$config_file" 2>/dev/null)
            main_package=$(yq -r '.main_package // ""' "$config_file" 2>/dev/null)
        else
            language=$(grep '^language:' "$config_file" 2>/dev/null | head -1 | \
                sed 's/language:[[:space:]]*//' | tr -d '"' | tr -d "'")
            main_package=$(grep '^main_package:' "$config_file" 2>/dev/null | head -1 | \
                sed 's/main_package:[[:space:]]*//' | tr -d '"' | tr -d "'")
        fi

        # Check if tag needed
        if ! version_needs_tag "$local_path" "$language" "$main_package"; then
            log_debug "Skipping $tool_name: already tagged or no version"
            ((skipped++))
            continue
        fi

        # Create tag
        local -a tag_args=()
        $push && tag_args+=("--push")
        $dry_run && tag_args+=("--dry-run")
        [[ -n "$language" ]] && tag_args+=("--language" "$language")
        [[ -n "$main_package" ]] && tag_args+=("--main-package" "$main_package")

        if version_create_tag "$local_path" "${tag_args[@]}"; then
            ((tagged++))
            results+=("$(jq -nc --arg tool "$tool_name" '{tool: $tool, status: "tagged"}')")
        else
            ((failed++))
            results+=("$(jq -nc --arg tool "$tool_name" '{tool: $tool, status: "failed"}')")
        fi
    done

    if $json_mode; then
        # Combine results array into JSON array
        local results_json="[]"
        if [[ ${#results[@]} -gt 0 ]]; then
            results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
        fi
        jq -nc \
            --argjson tagged "$tagged" \
            --argjson skipped "$skipped" \
            --argjson failed "$failed" \
            --argjson results "$results_json" \
            '{tagged: $tagged, skipped: $skipped, failed: $failed, results: $results}'
    else
        log_info "Version tagging complete: $tagged tagged, $skipped skipped, $failed failed"
    fi

    [[ $failed -eq 0 ]]
}

# Export functions
export -f version_detect version_needs_tag version_create_tag version_info_json version_tag_all
export -f _version_detect_by_language _version_from_cargo_toml _version_from_go
export -f _version_from_package_json _version_from_pyproject _version_from_toml_table
