#!/usr/bin/env bash
# artifact_naming.sh - Artifact naming pattern detection and generation for dsr
#
# Usage:
#   source artifact_naming.sh
#   artifact_naming_parse_install_script /path/to/install.sh
#   artifact_naming_generate_dual "tool" "v1.0.0" "linux" "amd64" "tar.gz"
#
# This module centralizes all artifact naming logic:
# - Parsing install.sh to extract expected naming patterns
# - Parsing workflow files to extract artifact names
# - Validating consistency across all naming sources
# - Generating both versioned and install.sh-compatible names

set -uo pipefail

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _AN_RED=$'\033[0;31m'
    _AN_GREEN=$'\033[0;32m'
    _AN_YELLOW=$'\033[0;33m'
    _AN_BLUE=$'\033[0;34m'
    _AN_NC=$'\033[0m'
else
    _AN_RED='' _AN_GREEN='' _AN_YELLOW='' _AN_BLUE='' _AN_NC=''
fi

# Logging with timestamps for debugging
_an_log_debug() {
    [[ "${ARTIFACT_NAMING_DEBUG:-0}" == "1" ]] && \
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${_AN_BLUE}[artifact_naming]${_AN_NC} DEBUG: $*" >&2
}
_an_log_info()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${_AN_BLUE}[artifact_naming]${_AN_NC} $*" >&2; }
_an_log_ok()    { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${_AN_GREEN}[artifact_naming]${_AN_NC} $*" >&2; }
_an_log_warn()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${_AN_YELLOW}[artifact_naming]${_AN_NC} $*" >&2; }
_an_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${_AN_RED}[artifact_naming]${_AN_NC} $*" >&2; }

# Normalize variable names to canonical form
# Input: Pattern with various variable syntaxes
# Output: Pattern with normalized ${name}, ${version}, ${os}, ${arch} variables
#
# NOTE: We use sed for all replacements because bash parameter expansion
# interprets ${var} in the replacement string, causing corruption like
# ${os-${arch}}-${arch}}}} instead of ${os}-${arch}
#
# shellcheck disable=SC2016 # We intentionally use single quotes to prevent expansion
_an_normalize_pattern() {
    local pattern="$1"
    local result="$pattern"

    _an_log_debug "Normalizing pattern: $pattern"

    # Use sed for all substitutions to avoid bash interpreting ${var} in replacements
    # Normalize TARGET -> os-arch combined (must come before OS/ARCH to avoid double replacement)
    result=$(printf '%s' "$result" | sed 's/\${TARGET}/${os}-${arch}/g; s/\$TARGET/${os}-${arch}/g')

    # Normalize OS/GOOS variants
    result=$(printf '%s' "$result" | sed 's/\${OS}/${os}/g; s/\${GOOS}/${os}/g; s/\$OS/${os}/g; s/\$GOOS/${os}/g')

    # Normalize ARCH/GOARCH variants
    result=$(printf '%s' "$result" | sed 's/\${ARCH}/${arch}/g; s/\${GOARCH}/${arch}/g; s/\$ARCH/${arch}/g; s/\$GOARCH/${arch}/g')

    # Normalize NAME/TOOL/APP variants
    result=$(printf '%s' "$result" | sed 's/\${NAME}/${name}/g; s/\${TOOL}/${name}/g; s/\${APP}/${name}/g')
    result=$(printf '%s' "$result" | sed 's/\$NAME/${name}/g; s/\$TOOL/${name}/g; s/\$APP/${name}/g')

    # Normalize VERSION
    result=$(printf '%s' "$result" | sed 's/\${VERSION}/${version}/g; s/\$VERSION/${version}/g')

    # Normalize EXT (common extensions)
    # Handle .${EXT} pattern (with leading dot) to avoid double dots
    result=$(printf '%s' "$result" | sed 's/\.\${EXT}/.tar.gz/g; s/\.\$EXT/.tar.gz/g')
    # Handle ${EXT} without leading dot
    result=$(printf '%s' "$result" | sed 's/\${EXT}/.tar.gz/g; s/\$EXT/.tar.gz/g')

    # Handle GitHub Actions matrix syntax
    # ${{ matrix.goos }} -> ${os}
    result=$(printf '%s' "$result" | sed -E 's/\$\{\{\s*matrix\.(goos|os)\s*\}\}/${os}/g')
    # ${{ matrix.goarch }} -> ${arch}
    result=$(printf '%s' "$result" | sed -E 's/\$\{\{\s*matrix\.(goarch|arch)\s*\}\}/${arch}/g')
    # ${{ matrix.target }} -> ${os}-${arch}
    result=$(printf '%s' "$result" | sed -E 's/\$\{\{\s*matrix\.target\s*\}\}/${os}-${arch}/g')
    # Strip version from pattern for compat comparison
    result=$(printf '%s' "$result" | sed -E 's/\$\{\{\s*(github\.ref_name|env\.VERSION)\s*\}\}/${version}/g')

    _an_log_debug "Normalized to: $result"
    printf '%s' "$result"
}

# Parse install.sh and extract expected artifact naming pattern
# Args: install_path
# Output: Normalized pattern string (stdout) or empty on failure
# Exit: 0 on success, 1 on not found/error
artifact_naming_parse_install_script() {
    local install_path="$1"

    if [[ ! -f "$install_path" ]]; then
        _an_log_debug "Install script not found: $install_path"
        echo ""
        return 1
    fi

    _an_log_debug "Parsing install script: $install_path"

    local content
    content=$(cat "$install_path")
    local pattern=""

    # Pattern 1: TAR variable assignment
    # TAR="cass-${TARGET}.${EXT}"
    # TAR="${name}-${TARGET}.tar.gz"
    if [[ -z "$pattern" ]]; then
        pattern=$(echo "$content" | grep -oP 'TAR="[^"]*\$[^"]*"' | head -1 || true)
        if [[ -n "$pattern" ]]; then
            pattern="${pattern#TAR=\"}"
            pattern="${pattern%\"}"
            _an_log_debug "Found TAR pattern: $pattern"
        fi
    fi

    # Pattern 2: asset_name variable
    # asset_name="rch-${TARGET}.tar.gz"
    if [[ -z "$pattern" ]]; then
        pattern=$(echo "$content" | grep -oiP 'asset_name="[^"]*\$[^"]*"' | head -1 || true)
        if [[ -n "$pattern" ]]; then
            pattern=$(echo "$pattern" | sed -E 's/^[^"]*"([^"]*)".*/\1/')
            _an_log_debug "Found asset_name pattern: $pattern"
        fi
    fi

    # Pattern 3: Download URL with filename
    # URL="https://...releases/download/${VERSION}/${name}-${TARGET}.tar.gz"
    if [[ -z "$pattern" ]]; then
        local url_match
        url_match=$(echo "$content" | grep -oP 'https://[^"]*releases/download/[^"]*' | head -1 || true)
        if [[ -n "$url_match" ]]; then
            # Extract filename portion after last /
            pattern="${url_match##*/}"
            _an_log_debug "Extracted from URL: $pattern"
        fi
    fi

    # Pattern 4: Direct curl/wget with asset pattern
    # curl ... "https://.../${name}-${os}-${arch}.tar.gz"
    if [[ -z "$pattern" ]]; then
        local curl_match
        curl_match=$(echo "$content" | grep -oP 'curl[^|]*\$\{?[A-Za-z_]+[^"]*\.tar\.gz' | head -1 || true)
        if [[ -n "$curl_match" ]]; then
            pattern="${curl_match##*/}"
            _an_log_debug "Extracted from curl: $pattern"
        fi
    fi

    if [[ -z "$pattern" ]]; then
        _an_log_debug "No pattern found in install script"
        echo ""
        return 1
    fi

    # Normalize and output
    local normalized
    normalized=$(_an_normalize_pattern "$pattern")

    # Remove extension for pattern comparison
    normalized="${normalized%.tar.gz}"
    normalized="${normalized%.zip}"
    normalized="${normalized%.tgz}"

    _an_log_info "Extracted pattern from install.sh: $normalized"
    echo "$normalized"
    return 0
}

# Parse workflow file and extract artifact names
# Args: workflow_path
# Output: JSON array of normalized patterns (stdout)
# Exit: 0 on success, 1 on error
artifact_naming_parse_workflow() {
    local workflow_path="$1"
    local patterns=()

    if [[ ! -f "$workflow_path" ]]; then
        _an_log_debug "Workflow not found: $workflow_path"
        echo "[]"
        return 1
    fi

    _an_log_debug "Parsing workflow: $workflow_path"

    # Check for yq
    if ! command -v yq &>/dev/null; then
        _an_log_warn "yq not installed, skipping workflow parsing"
        echo "[]"
        return 1
    fi

    local content
    content=$(cat "$workflow_path")

    # Pattern 1: actions/upload-artifact with name field
    local upload_names
    upload_names=$(yq -r '
        .jobs[].steps[] | select(has("uses")) | select(.uses | test("upload-artifact")) | .with.name
    ' "$workflow_path" 2>/dev/null | grep -v '^$' | grep -v '^null$' || true)

    while IFS= read -r name; do
        if [[ -n "$name" ]]; then
            local normalized
            normalized=$(_an_normalize_pattern "$name")
            patterns+=("$normalized")
            _an_log_debug "Found upload-artifact name: $normalized"
        fi
    done <<< "$upload_names"

    # Pattern 2: softprops/action-gh-release files field
    local release_files
    release_files=$(yq -r '
        .jobs[].steps[] | select(has("uses")) | select(.uses | test("action-gh-release")) | .with.files
    ' "$workflow_path" 2>/dev/null | grep -v '^$' | grep -v '^null$' || true)

    while IFS= read -r file; do
        if [[ -n "$file" && "$file" != "null" ]]; then
            # Handle multiline files field
            while IFS= read -r line; do
                line=$(echo "$line" | xargs)  # trim whitespace
                if [[ -n "$line" && "$line" != "|" ]]; then
                    local normalized
                    normalized=$(_an_normalize_pattern "$line")
                    # Extract just the filename pattern
                    normalized="${normalized##*/}"
                    normalized="${normalized%.tar.gz}"
                    normalized="${normalized%.zip}"
                    patterns+=("$normalized")
                    _an_log_debug "Found gh-release file: $normalized"
                fi
            done <<< "$file"
        fi
    done <<< "$release_files"

    # Pattern 3: gh release upload in run steps
    local run_steps
    run_steps=$(yq -r '.jobs[].steps[] | select(has("run")) | .run' "$workflow_path" 2>/dev/null || true)

    while IFS= read -r line; do
        if [[ "$line" =~ gh\ release\ upload.*([a-zA-Z0-9_-]+(\$\{\{[^}]+\}\}|[.-])+\.(tar\.gz|zip)) ]]; then
            local match="${BASH_REMATCH[1]}"
            local normalized
            normalized=$(_an_normalize_pattern "$match")
            normalized="${normalized%.tar.gz}"
            normalized="${normalized%.zip}"
            patterns+=("$normalized")
            _an_log_debug "Found gh release upload: $normalized"
        fi
    done <<< "$run_steps"

    # Deduplicate and output as JSON array
    local unique_patterns
    unique_patterns=$(printf '%s\n' "${patterns[@]}" 2>/dev/null | sort -u | grep -v '^$' || true)

    if [[ -z "$unique_patterns" ]]; then
        echo "[]"
        return 0
    fi

    # Build JSON array
    local json_array="["
    local first=true
    while IFS= read -r p; do
        if [[ -n "$p" ]]; then
            if [[ "$first" == "true" ]]; then
                first=false
            else
                json_array+=","
            fi
            json_array+="\"$p\""
        fi
    done <<< "$unique_patterns"
    json_array+="]"

    _an_log_info "Extracted $(echo "$unique_patterns" | wc -l | xargs) patterns from workflow"
    echo "$json_array"
    return 0
}

# Generate both versioned and install.sh-compatible names
# Args: tool_name version os arch ext [compat_pattern]
# Output: JSON object with both names (stdout)
# Exit: 0 on success
artifact_naming_generate_dual() {
    local tool="$1"
    local version="$2"
    local os="$3"
    local arch="$4"
    local ext="${5:-tar.gz}"
    local compat_pattern="${6:-}"  # Optional explicit compat pattern

    _an_log_debug "Generating dual names: tool=$tool version=$version os=$os arch=$arch ext=$ext"

    # Strip leading 'v' from version for filename
    local version_stripped="${version#v}"

    # Generate versioned name (default pattern)
    local versioned="${tool}-${version_stripped}-${os}-${arch}.${ext}"

    # Generate compat name
    local compat
    if [[ -n "$compat_pattern" ]]; then
        # Use explicit pattern if provided
        compat="$compat_pattern"
        # Substitute variables
        compat="${compat//\$\{name\}/$tool}"
        compat="${compat//\$\{os\}/$os}"
        compat="${compat//\$\{arch\}/$arch}"
        compat="${compat}.${ext}"
    else
        # Default compat: no version
        compat="${tool}-${os}-${arch}.${ext}"
    fi

    _an_log_debug "Versioned: $versioned"
    _an_log_debug "Compat: $compat"

    # Output JSON
    printf '{"versioned":"%s","compat":"%s","same":%s}\n' \
        "$versioned" "$compat" \
        "$(if [[ "$versioned" == "$compat" ]]; then echo "true"; else echo "false"; fi)"
}

# Validate that all naming sources are consistent
# Args: tool_name config_pattern install_pattern workflow_patterns_json
# Output: JSON validation result (stdout)
# Exit: 0 if consistent, 1 if mismatches found
artifact_naming_validate() {
    local tool="$1"
    local config_pattern="${2:-}"
    local install_pattern="${3:-}"
    local workflow_json="${4:-[]}"

    _an_log_info "Validating naming consistency for: $tool"

    local status="ok"
    local mismatches=()
    local recommendations=()

    # Normalize all patterns for comparison
    local config_norm=""
    local install_norm=""

    if [[ -n "$config_pattern" ]]; then
        config_norm=$(_an_normalize_pattern "$config_pattern")
        config_norm="${config_norm%.tar.gz}"
        config_norm="${config_norm%.zip}"
        _an_log_debug "Config pattern normalized: $config_norm"
    fi

    if [[ -n "$install_pattern" ]]; then
        install_norm="$install_pattern"  # Already normalized
        _an_log_debug "Install pattern: $install_norm"
    fi

    # Check for version in patterns
    local config_has_version=false
    local install_has_version=false

    # shellcheck disable=SC2016 # Matching literal ${version} text, not bash variable
    [[ "$config_norm" == *'${version}'* ]] && config_has_version=true
    # shellcheck disable=SC2016 # Matching literal ${version} text, not bash variable
    [[ "$install_norm" == *'${version}'* ]] && install_has_version=true

    # Detect mismatches
    if [[ -n "$config_norm" && -n "$install_norm" ]]; then
        # Check if config has version but install doesn't
        if [[ "$config_has_version" == "true" && "$install_has_version" == "false" ]]; then
            status="warning"
            mismatches+=("{\"field\":\"version\",\"config_has\":true,\"install_expects\":false}")
            recommendations+=("Add install_script_compat field to repos.d config")
            _an_log_warn "Config includes version but install.sh doesn't expect it"
        fi

        # Check separator differences (underscore vs hyphen)
        local config_sep=""
        local install_sep=""
        [[ "$config_norm" == *'_'* ]] && config_sep="underscore"
        [[ "$config_norm" == *'-'* ]] && config_sep="hyphen"
        [[ "$install_norm" == *'_'* ]] && install_sep="underscore"
        [[ "$install_norm" == *'-'* ]] && install_sep="hyphen"

        if [[ -n "$config_sep" && -n "$install_sep" && "$config_sep" != "$install_sep" ]]; then
            status="warning"
            mismatches+=("{\"field\":\"separator\",\"config_uses\":\"$config_sep\",\"install_uses\":\"$install_sep\"}")
            recommendations+=("Ensure separator consistency in artifact_naming")
            _an_log_warn "Separator mismatch: config uses $config_sep, install uses $install_sep"
        fi
    fi

    # Build result JSON
    local mismatches_json="["
    local first=true
    for m in "${mismatches[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            mismatches_json+=","
        fi
        mismatches_json+="$m"
    done
    mismatches_json+="]"

    local recs_json="["
    first=true
    for r in "${recommendations[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            recs_json+=","
        fi
        recs_json+="\"$r\""
    done
    recs_json+="]"

    printf '{"tool":"%s","status":"%s","sources":{"config":"%s","install":"%s","workflow":%s},"mismatches":%s,"recommendations":%s}\n' \
        "$tool" "$status" "${config_norm:-}" "${install_norm:-}" "$workflow_json" "$mismatches_json" "$recs_json"

    if [[ "$status" != "ok" ]]; then
        return 1
    fi
    return 0
}

# Derive compat pattern from versioned pattern by stripping version
# Args: versioned_pattern
# Output: Compat pattern (stdout)
_an_derive_compat_from_versioned() {
    local versioned="$1"
    local compat="$versioned"

    # Remove version component variations
    compat="${compat//\$\{version\}-/}"
    compat="${compat//-\$\{version\}/}"
    compat="${compat//v\$\{version\}-/}"
    compat="${compat//-v\$\{version\}/}"
    compat="${compat//\$\{version\}/}"

    # Clean up any double-hyphens or underscores
    compat=$(echo "$compat" | sed 's/--/-/g' | sed 's/__/_/g')

    echo "$compat"
}

# Substitute variables in a naming pattern
# Args: pattern tool version os arch ext
# Output: Substituted string (stdout)
artifact_naming_substitute() {
    local pattern="$1"
    local tool="$2"
    local version="$3"
    local os="$4"
    local arch="$5"
    local ext="${6:-tar.gz}"

    local result="$pattern"
    local version_stripped="${version#v}"

    result="${result//\$\{name\}/$tool}"
    result="${result//\$\{version\}/$version_stripped}"
    result="${result//\$\{os\}/$os}"
    result="${result//\$\{arch\}/$arch}"
    result="${result//\$\{ext\}/.$ext}"
    result="${result//\$\{target\}/${os}-${arch}}"

    echo "$result"
}

# Get the compat pattern for a tool using precedence:
# 1. Explicit install_script_compat from config (highest priority)
# 2. Auto-detect from install_script_path if set
# 3. Derive from artifact_naming by stripping version (fallback)
#
# Args: tool_name local_repo_path
# Output: Compat pattern (stdout) or empty
# Exit: 0 on success
artifact_naming_get_compat_pattern() {
    local tool="$1"
    local repo_path="${2:-}"

    _an_log_debug "Getting compat pattern for: $tool"

    # Source config.sh if not already loaded
    if ! declare -F config_get_install_script_compat &>/dev/null; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        # shellcheck source=./config.sh
        source "$script_dir/config.sh" 2>/dev/null || true
    fi

    # Priority 1: Explicit install_script_compat
    local explicit_compat
    explicit_compat=$(config_get_install_script_compat "$tool" 2>/dev/null || echo "")
    if [[ -n "$explicit_compat" ]]; then
        _an_log_info "Using explicit install_script_compat: $explicit_compat"
        echo "$explicit_compat"
        return 0
    fi

    # Priority 2: Auto-detect from install_script_path
    local install_path
    install_path=$(config_get_install_script_path "$tool" 2>/dev/null || echo "")
    if [[ -n "$install_path" && -n "$repo_path" ]]; then
        local full_path="$repo_path/$install_path"
        if [[ -f "$full_path" ]]; then
            local detected_pattern
            detected_pattern=$(artifact_naming_parse_install_script "$full_path")
            if [[ -n "$detected_pattern" ]]; then
                _an_log_info "Auto-detected pattern from install.sh: $detected_pattern"
                echo "$detected_pattern"
                return 0
            fi
        else
            _an_log_debug "Install script not found at: $full_path"
        fi
    fi

    # Priority 3: Derive from artifact_naming by stripping version
    local artifact_naming
    artifact_naming=$(config_get_artifact_naming "$tool" 2>/dev/null || echo "")
    if [[ -n "$artifact_naming" ]]; then
        local derived
        derived=$(_an_derive_compat_from_versioned "$artifact_naming")
        _an_log_info "Derived compat pattern from artifact_naming: $derived"
        echo "$derived"
        return 0
    fi

    # No pattern found - caller should use default
    _an_log_debug "No compat pattern found for $tool, using default"
    echo ""
    return 0
}

# Generate dual names for a tool using config-aware precedence
# This is the main entry point for the release workflow
#
# Args: tool_name version os arch ext repo_path
# Output: JSON object with versioned and compat names
# Exit: 0 on success
artifact_naming_generate_dual_for_tool() {
    local tool="$1"
    local version="$2"
    local os="$3"
    local arch="$4"
    local ext="${5:-tar.gz}"
    local repo_path="${6:-}"

    # Get compat pattern using precedence logic
    local compat_pattern
    compat_pattern=$(artifact_naming_get_compat_pattern "$tool" "$repo_path")

    # Generate dual names
    artifact_naming_generate_dual "$tool" "$version" "$os" "$arch" "$ext" "$compat_pattern"
}

# Export functions
export -f artifact_naming_parse_install_script artifact_naming_parse_workflow
export -f artifact_naming_generate_dual artifact_naming_validate
export -f artifact_naming_substitute
export -f artifact_naming_get_compat_pattern artifact_naming_generate_dual_for_tool
