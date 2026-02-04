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

# Known archive extensions
_an_has_known_ext() {
    local name="$1"
    case "$name" in
        *.tar.gz|*.tgz|*.tar.xz|*.zip|*.exe) return 0 ;;
        *) return 1 ;;
    esac
}

# Append extension if missing (and ext is not empty)
_an_append_ext_if_missing() {
    local name="$1"
    local ext="$2"

    if [[ -z "$ext" || "$ext" == "none" ]]; then
        # Avoid trailing dot if ext is empty
        echo "${name%.}"
        return 0
    fi

    if _an_has_known_ext "$name"; then
        echo "$name"
        return 0
    fi

    echo "${name}.${ext}"
}

# Default target triple mapping (override via config target_triples)
_an_default_target_triple() {
    local os="$1"
    local arch="$2"

    case "$os/$arch" in
        linux/amd64) echo "x86_64-unknown-linux-gnu" ;;
        linux/arm64) echo "aarch64-unknown-linux-gnu" ;;
        darwin/amd64) echo "x86_64-apple-darwin" ;;
        darwin/arm64) echo "aarch64-apple-darwin" ;;
        windows/amd64) echo "x86_64-pc-windows-msvc" ;;
        *) echo "${os}-${arch}" ;;
    esac
}

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
    # Normalize TARGET/PLATFORM -> combined forms (must come before OS/ARCH to avoid double replacement)
    result=$(printf '%s' "$result" | sed 's/\${TARGET}/${target}/g; s/\$TARGET/${target}/g')
    result=$(printf '%s' "$result" | sed 's/\${TARGET_TRIPLE}/${target_triple}/g; s/\$TARGET_TRIPLE/${target_triple}/g')
    result=$(printf '%s' "$result" | sed 's/\${platform}/${os}_${arch}/g; s/\${PLATFORM}/${os}_${arch}/g; s/\$platform/${os}_${arch}/g; s/\$PLATFORM/${os}_${arch}/g')

    # Normalize OS/GOOS variants
    result=$(printf '%s' "$result" | sed 's/\${OS}/${os}/g; s/\${GOOS}/${os}/g; s/\$OS/${os}/g; s/\$GOOS/${os}/g')

    # Normalize ARCH/GOARCH variants
    result=$(printf '%s' "$result" | sed 's/\${ARCH}/${arch}/g; s/\${GOARCH}/${arch}/g; s/\$ARCH/${arch}/g; s/\$GOARCH/${arch}/g')

    # Normalize NAME/TOOL/APP variants
    result=$(printf '%s' "$result" | sed 's/\${NAME}/${name}/g; s/\${TOOL}/${name}/g; s/\${APP}/${name}/g')
    result=$(printf '%s' "$result" | sed 's/\$NAME/${name}/g; s/\$TOOL/${name}/g; s/\$APP/${name}/g')

    # Normalize VERSION
    result=$(printf '%s' "$result" | sed 's/\${VERSION}/${version}/g; s/\$VERSION/${version}/g')

    # Normalize EXT variable to ${ext} (preserve extension semantics)
    # Handle .${EXT} pattern (with leading dot) to avoid double dots
    result=$(printf '%s' "$result" | sed 's/\.\${EXT}/.${ext}/g; s/\.\$EXT/.${ext}/g')
    # Handle ${EXT} without leading dot
    result=$(printf '%s' "$result" | sed 's/\${EXT}/${ext}/g; s/\$EXT/${ext}/g')

    # Handle GitHub Actions matrix syntax
    # ${{ matrix.goos }} -> ${os}
    result=$(printf '%s' "$result" | sed -E 's/\$\{\{\s*matrix\.(goos|os)\s*\}\}/${os}/g')
    # ${{ matrix.goarch }} -> ${arch}
    result=$(printf '%s' "$result" | sed -E 's/\$\{\{\s*matrix\.(goarch|arch)\s*\}\}/${arch}/g')
    # ${{ matrix.target }} -> ${target_triple}
    result=$(printf '%s' "$result" | sed -E 's/\$\{\{\s*matrix\.target\s*\}\}/${target_triple}/g')
    # Strip version from pattern for compat comparison
    result=$(printf '%s' "$result" | sed -E 's/\$\{\{\s*(github\.ref_name|env\.VERSION)\s*\}\}/${version}/g')

    _an_log_debug "Normalized to: $result"
    printf '%s' "$result"
}

# Parse install.sh and extract expected artifact naming pattern
# Args: install_path [tool_name]
# Output: Normalized pattern string (stdout) or empty on failure
# Exit: 0 on success, 1 on not found/error
artifact_naming_parse_install_script() {
    local install_path="$1"
    local tool_name="${2:-}"

    if [[ ! -f "$install_path" ]]; then
        _an_log_debug "Install script not found: $install_path"
        echo ""
        return 1
    fi

    _an_log_debug "Parsing install script: $install_path"

    local content
    content=$(cat "$install_path")
    local -a candidates=()

    # Pattern 1: TAR variable assignment
    # TAR="cass-${TARGET}.${EXT}"
    # TAR="${name}-${TARGET}.tar.gz"
    # Avoid non-portable grep -P (not available on macOS/BSD)
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        candidates+=("$pattern")
        _an_log_debug "Found TAR pattern: $pattern"
    done < <(echo "$content" | sed -n 's/.*TAR="\([^"]*\$[^"]*\)".*/\1/p' || true)

    # Pattern 2: asset_name variable
    # asset_name="rch-${TARGET}.tar.gz"
    # Avoid non-portable grep -P (not available on macOS/BSD)
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        candidates+=("$pattern")
        _an_log_debug "Found asset_name pattern: $pattern"
    done < <(echo "$content" | sed -n 's/.*[Aa][Ss][Ss][Ee][Tt]_[Nn][Aa][Mm][Ee]="\([^"]*\$[^"]*\)".*/\1/p' || true)

    # Pattern 2b: archive_name variable
    # archive_name="tool-${VERSION}-${platform}.tar.gz"
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        candidates+=("$pattern")
        _an_log_debug "Found archive_name pattern: $pattern"
    done < <(echo "$content" | sed -n 's/.*[Aa][Rr][Cc][Hh][Ii][Vv][Ee]_[Nn][Aa][Mm][Ee]="\([^"]*\$[^"]*\)".*/\1/p' || true)

    # Pattern 3: Download URL with filename
    # URL="https://...releases/download/${VERSION}/${name}-${TARGET}.tar.gz"
    # Avoid non-portable grep -P (not available on macOS/BSD)
    while IFS= read -r url_match; do
        [[ -z "$url_match" ]] && continue
        local pattern="${url_match##*/}"
        candidates+=("$pattern")
        _an_log_debug "Extracted from URL: $pattern"
    done < <(echo "$content" | sed -n 's/.*\(https:\/\/[^"]*releases\/download\/[^"]*\).*/\1/p' || true)

    # Pattern 4: Direct curl/wget with asset pattern
    # curl ... "https://.../${name}-${os}-${arch}.tar.gz"
    # Avoid non-portable grep -P (not available on macOS/BSD)
    while IFS= read -r curl_match; do
        [[ -z "$curl_match" ]] && continue
        local pattern="${curl_match##*/}"
        candidates+=("$pattern")
        _an_log_debug "Extracted from curl: $pattern"
    done < <(echo "$content" | sed -n 's/.*\(curl[^|]*\$[^"]*\.tar\.gz\).*/\1/p' || true)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        _an_log_debug "No pattern found in install script"
        echo ""
        return 1
    fi

    # Normalize candidates
    local -a normalized_candidates=()
    local cand
    for cand in "${candidates[@]}"; do
        local normalized
        normalized=$(_an_normalize_pattern "$cand")

        # Remove extension for pattern comparison
        normalized="${normalized%.tar.gz}"
        normalized="${normalized%.tar.xz}"
        normalized="${normalized%.zip}"
        normalized="${normalized%.tgz}"
        # Remove variable extension placeholder if present
        case "$normalized" in
            *'.${ext}') normalized="${normalized%'.${ext}'}" ;;
            *'.${EXT}') normalized="${normalized%'.${EXT}'}" ;;
        esac

        normalized_candidates+=("$normalized")
    done

    local best=""
    if [[ -n "$tool_name" ]]; then
        local best_score=-1
        for cand in "${normalized_candidates[@]}"; do
            local score=0
            [[ "$cand" == *'${name}'* ]] && score=$((score + 5))
            [[ "$cand" == *'${version}'* ]] && score=$((score + 2))
            [[ "$cand" == *'${os}'* ]] && score=$((score + 1))
            [[ "$cand" == *'${arch}'* ]] && score=$((score + 1))
            [[ "$cand" == *"${tool_name}"* ]] && score=$((score + 4))
            if [[ "$score" -gt "$best_score" ]]; then
                best="$cand"
                best_score="$score"
            fi
        done
    fi

    if [[ -z "$best" ]]; then
        best="${normalized_candidates[0]}"
    fi

    _an_log_info "Extracted pattern from install.sh: $best"
    echo "$best"
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
                    normalized="${normalized%.tar.xz}"
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
        if [[ "$line" =~ gh\ release\ upload.*([a-zA-Z0-9_-]+(\$\{\{[^}]+\}\}|[.-])+\.(tar\.gz|tar\.xz|zip)) ]]; then
            local match="${BASH_REMATCH[1]}"
            local normalized
            normalized=$(_an_normalize_pattern "$match")
            normalized="${normalized%.tar.gz}"
            normalized="${normalized%.tar.xz}"
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

    # Build JSON array using jq for proper escaping of special characters
    local json_array
    json_array=$(printf '%s\n' "$unique_patterns" | jq -R -s 'split("\n") | map(select(length > 0))')

    _an_log_info "Extracted $(echo "$unique_patterns" | wc -l | xargs) patterns from workflow"
    echo "$json_array"
    return 0
}

# Parse GoReleaser config and extract archive name_template
# Args: goreleaser_path
# Output: Normalized pattern (stdout) or empty on failure
artifact_naming_parse_goreleaser() {
    local goreleaser_path="$1"

    if [[ ! -f "$goreleaser_path" ]]; then
        _an_log_debug "GoReleaser config not found: $goreleaser_path"
        echo ""
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        _an_log_warn "yq not installed, skipping goreleaser parsing"
        echo ""
        return 1
    fi

    local template
    template=$(yq -r '
        .archives[]? |
        select((.formats // []) | index("binary") | not) |
        .name_template // empty
    ' "$goreleaser_path" 2>/dev/null | head -1)

    if [[ -z "$template" || "$template" == "null" ]]; then
        template=$(yq -r '.archives[]?.name_template // empty' "$goreleaser_path" 2>/dev/null | head -1)
    fi

    if [[ -z "$template" || "$template" == "null" ]]; then
        _an_log_debug "No name_template found in goreleaser config"
        echo ""
        return 1
    fi

    # Collapse whitespace/newlines
    local normalized
    normalized=$(printf '%s' "$template" | tr -d '\r' | tr '\n' ' ' | sed -E 's/[[:space:]]+//g')

    # Replace GoReleaser template variables with dsr placeholders
    normalized=$(printf '%s' "$normalized" | sed -E 's/\{\{[- ]*\.ProjectName[- ]*\}\}/\${name}/g')
    normalized=$(printf '%s' "$normalized" | sed -E 's/\{\{[- ]*\.Version[- ]*\}\}/\${version}/g')
    normalized=$(printf '%s' "$normalized" | sed -E 's/\{\{[- ]*\.Os[- ]*\}\}/\${os}/g')
    normalized=$(printf '%s' "$normalized" | sed -E 's/\{\{[- ]*\.Arch[- ]*\}\}/\${arch}/g')
    normalized=$(printf '%s' "$normalized" | sed -E 's/\{\{[- ]*\.Tag[- ]*\}\}/v\${version}/g')
    # Drop arm suffix blocks (dsr does not model arm variants yet)
    normalized=$(printf '%s' "$normalized" | sed -E 's/\{\{[- ]*if\.Arm[- ]*\}\}v\{\{[- ]*\.Arm[- ]*\}\}\{\{[- ]*end[- ]*\}\}//g')
    # Remove any remaining template fragments
    normalized=$(printf '%s' "$normalized" | sed -E 's/\{\{[^}]*\}\}//g')

    normalized=$(_an_normalize_pattern "$normalized")

    # Strip archive extensions (GoReleaser adds these based on format)
    normalized="${normalized%.tar.gz}"
    normalized="${normalized%.tar.xz}"
    normalized="${normalized%.zip}"
    normalized="${normalized%.tgz}"

    _an_log_info "Extracted pattern from goreleaser: $normalized"
    echo "$normalized"
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
    local versioned_pattern="${7:-}"  # Optional explicit versioned pattern
    local config_tool="${8:-$tool}"  # Config tool name for arch alias / target triple lookups

    _an_log_debug "Generating dual names: tool=$tool version=$version os=$os arch=$arch ext=$ext"

    local ext_value="$ext"
    [[ "$ext_value" == "none" ]] && ext_value=""

    # Generate versioned name (config/workflow pattern or default)
    local versioned=""
    if [[ -n "$versioned_pattern" ]]; then
        local rendered
        rendered=$(artifact_naming_substitute "$versioned_pattern" "$tool" "$version" "$os" "$arch" "$ext_value" "$config_tool")
        # If pattern did not include ${ext}, append extension if missing
        if [[ "$versioned_pattern" == *'${ext}'* || "$versioned_pattern" == *'${EXT}'* ]]; then
            versioned="$rendered"
        else
            versioned=$(_an_append_ext_if_missing "$rendered" "$ext_value")
        fi
    else
        local version_stripped="${version#v}"
        if [[ -n "$ext_value" ]]; then
            versioned="${tool}-${version_stripped}-${os}-${arch}.${ext_value}"
        else
            versioned="${tool}-${version_stripped}-${os}-${arch}"
        fi
    fi

    # Generate compat name
    local compat
    if [[ -n "$compat_pattern" ]]; then
        # Use explicit pattern if provided
        compat=$(artifact_naming_substitute "$compat_pattern" "$tool" "$version" "$os" "$arch" "$ext_value" "$config_tool")
        if [[ "$compat_pattern" == *'${ext}'* || "$compat_pattern" == *'${EXT}'* ]]; then
            : # Extension explicitly controlled by pattern
        else
            compat=$(_an_append_ext_if_missing "$compat" "$ext_value")
        fi
    else
        # Default compat: no version
        if [[ -n "$ext_value" ]]; then
            compat="${tool}-${os}-${arch}.${ext_value}"
        else
            compat="${tool}-${os}-${arch}"
        fi
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
        case "$config_norm" in
            *'.${ext}') config_norm="${config_norm%'.${ext}'}" ;;
            *'.${EXT}') config_norm="${config_norm%'.${EXT}'}" ;;
        esac
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

# Score a pattern for selection (higher is better)
_an_score_pattern() {
    local pattern="$1"
    local score=0

    # Prefer patterns that include version and target dimensions
    [[ "$pattern" == *'${version}'* ]] && score=$((score + 4))
    [[ "$pattern" == *'${os}'* ]] && score=$((score + 2))
    [[ "$pattern" == *'${arch}'* ]] && score=$((score + 2))
    [[ "$pattern" == *'${target}'* ]] && score=$((score + 1))
    [[ "$pattern" == *'${target_triple}'* ]] && score=$((score + 2))
    [[ "$pattern" == *'${name}'* ]] && score=$((score + 1))

    echo "$score"
}

# Choose best pattern from a JSON array of patterns
_an_choose_workflow_pattern() {
    local patterns_json="$1"
    local best=""
    local best_score=-1

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        local score
        score=$(_an_score_pattern "$pattern")
        if [[ "$score" -gt "$best_score" ]]; then
            best="$pattern"
            best_score="$score"
        fi
    done < <(echo "$patterns_json" | jq -r '.[]?' 2>/dev/null)

    [[ -n "$best" ]] && echo "$best"
}

# Get the versioned naming pattern for a tool using precedence:
# 1. Explicit artifact_naming from config
# 2. Workflow-derived patterns (choose best)
# 3. Default ${name}-${version}-${os}-${arch}
#
# Args: tool_name local_repo_path [workflow_path]
# Output: Pattern (stdout) or empty
# Exit: 0 on success
artifact_naming_get_versioned_pattern() {
    local tool="$1"
    local repo_path="${2:-}"
    local workflow_path="${3:-}"

    _an_log_debug "Getting versioned pattern for: $tool"

    local pattern
    pattern=$(config_get_artifact_naming "$tool" 2>/dev/null || echo "")
    if [[ -n "$pattern" ]]; then
        local config_norm default_norm
        config_norm=$(_an_normalize_pattern "$pattern")
        default_norm=$(_an_normalize_pattern '${name}-${version}-${os}-${arch}')
        if [[ "$config_norm" != "$default_norm" ]]; then
            _an_log_info "Using artifact_naming from config: $pattern"
            echo "$pattern"
            return 0
        fi
    fi

    if [[ -z "$workflow_path" ]]; then
        workflow_path=$(config_get_tool_field "$tool" "workflow" "" 2>/dev/null || echo "")
    fi

    if [[ -n "$workflow_path" && -n "$repo_path" ]]; then
        local full_path="$repo_path/$workflow_path"
        if [[ -f "$full_path" ]]; then
            local patterns_json
            patterns_json=$(artifact_naming_parse_workflow "$full_path" 2>/dev/null || echo "[]")
            local chosen
            chosen=$(_an_choose_workflow_pattern "$patterns_json")
            if [[ -n "$chosen" ]]; then
                _an_log_info "Using workflow-derived pattern: $chosen"
                echo "$chosen"
                return 0
            fi
        else
            _an_log_debug "Workflow file not found for pattern resolution: $full_path"
        fi
    fi

    # Fallback: GoReleaser config (common for Go projects)
    if [[ -n "$repo_path" ]]; then
        local goreleaser_path=""
        for candidate in ".goreleaser.yml" ".goreleaser.yaml" "goreleaser.yml" "goreleaser.yaml"; do
            if [[ -f "$repo_path/$candidate" ]]; then
                goreleaser_path="$repo_path/$candidate"
                break
            fi
        done
        if [[ -n "$goreleaser_path" ]]; then
            local goreleaser_pattern
            goreleaser_pattern=$(artifact_naming_parse_goreleaser "$goreleaser_path" 2>/dev/null || echo "")
            if [[ -n "$goreleaser_pattern" ]]; then
                _an_log_info "Using goreleaser-derived pattern: $goreleaser_pattern"
                echo "$goreleaser_pattern"
                return 0
            fi
        fi
    fi

    if [[ -n "$pattern" ]]; then
        _an_log_info "Using default artifact_naming from config: $pattern"
        echo "$pattern"
        return 0
    fi

    _an_log_debug "No versioned pattern found for $tool, using default"
    echo ""
    return 0
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
    local config_tool="${7:-$tool}"  # Config tool name for arch alias / target triple lookups

    local result="$pattern"
    local version_stripped="${version#v}"

    # Ensure config helpers are available (for arch alias + target triple)
    if ! declare -F config_get_arch_alias &>/dev/null; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        # shellcheck source=./config.sh
        source "$script_dir/config.sh" 2>/dev/null || true
    fi

    local arch_resolved="$arch"
    if declare -F config_get_arch_alias &>/dev/null; then
        local arch_alias
        arch_alias=$(config_get_arch_alias "$config_tool" "$arch" 2>/dev/null || echo "")
        [[ -n "$arch_alias" ]] && arch_resolved="$arch_alias"
    fi

    local target_triple=""
    if declare -F config_get_target_triple &>/dev/null; then
        target_triple=$(config_get_target_triple "$config_tool" "${os}/${arch}" 2>/dev/null || echo "")
    fi
    [[ -z "$target_triple" ]] && target_triple=$(_an_default_target_triple "$os" "$arch")

    local target="${os}-${arch_resolved}"

    result="${result//\$\{name\}/$tool}"
    result="${result//\$\{NAME\}/$tool}"
    result="${result//\$\{tool\}/$tool}"
    result="${result//\$\{TOOL\}/$tool}"
    result="${result//\$\{app\}/$tool}"
    result="${result//\$\{APP\}/$tool}"

    result="${result//\$\{version\}/$version_stripped}"
    result="${result//\$\{VERSION\}/$version_stripped}"

    result="${result//\$\{os\}/$os}"
    result="${result//\$\{OS\}/$os}"
    result="${result//\$\{goos\}/$os}"
    result="${result//\$\{GOOS\}/$os}"
    result="${result//\$\{arch\}/$arch_resolved}"
    result="${result//\$\{ARCH\}/$arch_resolved}"
    result="${result//\$\{goarch\}/$arch_resolved}"
    result="${result//\$\{GOARCH\}/$arch_resolved}"

    result="${result//\$\{target\}/$target}"
    result="${result//\$\{TARGET\}/$target}"
    result="${result//\$\{target_triple\}/$target_triple}"
    result="${result//\$\{TARGET_TRIPLE\}/$target_triple}"

    # Replace extension placeholders; handle ".${ext}" before bare "${ext}"
    result="${result//\.\$\{ext\}/.${ext}}"
    result="${result//\.\$\{EXT\}/.${ext}}"
    result="${result//\$\{ext\}/$ext}"
    result="${result//\$\{EXT\}/$ext}"

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

    # Explicit install_script_compat (highest priority)
    local explicit_compat
    explicit_compat=$(config_get_install_script_compat "$tool" 2>/dev/null || echo "")

    local detected_pattern=""
    local install_path
    install_path=$(config_get_install_script_path "$tool" 2>/dev/null || echo "")
    if [[ -n "$install_path" && -n "$repo_path" ]]; then
        local full_path="$repo_path/$install_path"
        if [[ -f "$full_path" ]]; then
            detected_pattern=$(artifact_naming_parse_install_script "$full_path" "$tool")
            if [[ -n "$detected_pattern" ]]; then
                if [[ -n "$explicit_compat" && "$explicit_compat" != "$detected_pattern" ]]; then
                    _an_log_warn "install_script_compat differs from install.sh; using explicit override: $explicit_compat"
                else
                    _an_log_info "Auto-detected pattern from install.sh: $detected_pattern"
                fi
            fi
        else
            _an_log_debug "Install script not found at: $full_path"
        fi
    fi

    if [[ -n "$explicit_compat" ]]; then
        _an_log_info "Using explicit install_script_compat: $explicit_compat"
        echo "$explicit_compat"
        return 0
    fi

    # Auto-detect from install_script_path (fallback)
    if [[ -n "$detected_pattern" ]]; then
        echo "$detected_pattern"
        return 0
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

    # Ensure config helpers are available
    if ! declare -F config_get_tool_field &>/dev/null; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        # shellcheck source=./config.sh
        source "$script_dir/config.sh" 2>/dev/null || true
    fi

    # Resolve naming base (prefer tool_name or binary_name from config)
    local naming_name
    naming_name=$(config_get_tool_field "$tool" "tool_name" "" 2>/dev/null || echo "")
    if [[ -z "$naming_name" ]]; then
        naming_name=$(config_get_tool_field "$tool" "binary_name" "" 2>/dev/null || echo "")
    fi
    [[ -z "$naming_name" ]] && naming_name="$tool"

    # Get compat pattern using precedence logic
    local compat_pattern
    compat_pattern=$(artifact_naming_get_compat_pattern "$tool" "$repo_path")

    # Get versioned pattern using precedence logic
    local versioned_pattern
    versioned_pattern=$(artifact_naming_get_versioned_pattern "$tool" "$repo_path")

    # Generate dual names; pass config tool name ($tool) for config lookups
    artifact_naming_generate_dual "$naming_name" "$version" "$os" "$arch" "$ext" "$compat_pattern" "$versioned_pattern" "$tool"
}

# Export functions
export -f artifact_naming_parse_install_script artifact_naming_parse_workflow artifact_naming_parse_goreleaser
export -f artifact_naming_generate_dual artifact_naming_validate
export -f artifact_naming_substitute
export -f artifact_naming_get_compat_pattern artifact_naming_get_versioned_pattern artifact_naming_generate_dual_for_tool
