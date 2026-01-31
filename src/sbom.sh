#!/usr/bin/env bash
# src/sbom.sh - Software Bill of Materials (SBOM) generation
#
# bd-1jt.3.4: Generate SBOM for releases
#
# Produces SBOMs using syft for improved supply-chain transparency.
# Supports SPDX and CycloneDX formats.
#
# Usage:
#   source "$SCRIPT_DIR/src/sbom.sh"
#   sbom_generate /path/to/project --format spdx
#   sbom_generate /path/to/artifact --format cyclonedx
#
# Required modules:
#   - logging.sh (for log_info, log_error, etc.)

# ============================================================================
# Configuration
# ============================================================================

# Default SBOM format (spdx or cyclonedx)
SBOM_DEFAULT_FORMAT="${SBOM_DEFAULT_FORMAT:-spdx}"

# Output directory (defaults to project/artifacts directory)
SBOM_OUTPUT_DIR="${SBOM_OUTPUT_DIR:-}"

# ============================================================================
# Dependency Checking
# ============================================================================

# Check if syft is available
# Returns: 0 if available, 1 if not
sbom_check() {
    if command -v syft &>/dev/null; then
        return 0
    fi

    log_warn "syft not installed - SBOM generation unavailable"
    log_info "Install: curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin"
    return 3
}

# Get syft version
sbom_version() {
    if ! sbom_check; then
        return 1
    fi
    syft version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# ============================================================================
# SBOM Generation
# ============================================================================

# Generate SBOM for a project or artifact
# Args: project_path [--format spdx|cyclonedx] [--output <file>]
# Returns: 0 on success, 1 on error, 3 if syft unavailable
sbom_generate() {
    local target="${1:-}"
    shift 2>/dev/null || true

    local format="$SBOM_DEFAULT_FORMAT"
    local output=""
    local quiet=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format|-f) format="$2"; shift 2 ;;
            --output|-o) output="$2"; shift 2 ;;
            --quiet|-q) quiet=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$target" ]]; then
        log_error "Target path required"
        return 4
    fi

    if [[ ! -e "$target" ]]; then
        log_error "Target not found: $target"
        return 4
    fi

    if ! sbom_check; then
        return 3
    fi

    # Determine output format for syft
    local syft_format
    local output_ext
    case "$format" in
        spdx|spdx-json)
            syft_format="spdx-json"
            output_ext="spdx.json"
            ;;
        cyclonedx|cdx|cyclonedx-json)
            syft_format="cyclonedx-json"
            output_ext="cdx.json"
            ;;
        *)
            log_error "Unsupported format: $format (use spdx or cyclonedx)"
            return 4
            ;;
    esac

    # Determine output file
    if [[ -z "$output" ]]; then
        if [[ -d "$target" ]]; then
            output="$target/sbom.$output_ext"
        else
            output="${target%.*}.sbom.$output_ext"
        fi
    fi

    # Create output directory if needed
    mkdir -p "$(dirname "$output")"

    $quiet || log_info "Generating SBOM ($format) for: $target"

    # Run syft
    local syft_args=()
    syft_args+=("-o" "$syft_format")

    # Determine scan type based on target
    if [[ -d "$target" ]]; then
        # Directory scan
        syft_args+=("dir:$target")
    elif [[ -f "$target" ]]; then
        # Binary or archive scan
        case "$target" in
            *.tar.gz|*.tgz|*.zip)
                syft_args+=("file:$target")
                ;;
            *)
                # Binary scan
                syft_args+=("file:$target")
                ;;
        esac
    fi

    local syft_output exit_code=0
    if syft_output=$(syft "${syft_args[@]}" 2>&1); then
        echo "$syft_output" > "$output"
        $quiet || log_ok "SBOM generated: $output"
    else
        exit_code=$?
        log_error "SBOM generation failed: $syft_output"
        return 1
    fi

    # Return path to generated file
    echo "$output"
    return 0
}

# Generate SBOM from a project based on detected language
# Args: project_path [--format spdx|cyclonedx]
sbom_generate_project() {
    local project_path="${1:-}"
    shift 2>/dev/null || true

    local format="$SBOM_DEFAULT_FORMAT"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format|-f) format="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$project_path" || ! -d "$project_path" ]]; then
        log_error "Project path required and must be a directory"
        return 4
    fi

    if ! sbom_check; then
        return 3
    fi

    # Detect language based on project files
    local language=""
    if [[ -f "$project_path/Cargo.toml" ]]; then
        language="rust"
    elif [[ -f "$project_path/go.mod" ]]; then
        language="go"
    elif [[ -f "$project_path/package.json" ]]; then
        language="node"
    elif [[ -f "$project_path/pyproject.toml" ]]; then
        language="python"
    else
        log_warn "Could not detect project language, scanning entire directory"
    fi

    log_info "Detected language: ${language:-unknown}"
    sbom_generate "$project_path" --format "$format"
}

# Generate SBOMs for all artifacts in a directory
# Args: artifacts_dir [--format spdx|cyclonedx]
sbom_generate_artifacts() {
    local artifacts_dir="${1:-}"
    shift 2>/dev/null || true

    local format="$SBOM_DEFAULT_FORMAT"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format|-f) format="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$artifacts_dir" || ! -d "$artifacts_dir" ]]; then
        log_error "Artifacts directory required"
        return 4
    fi

    if ! sbom_check; then
        return 3
    fi

    local generated=0
    local failed=0

    # Find all binaries (exclude checksums, signatures, etc.)
    while IFS= read -r artifact; do
        [[ -z "$artifact" ]] && continue

        # Skip non-binary files
        local filename
        filename=$(basename "$artifact")
        case "$filename" in
            *.txt|*.json|*.yaml|*.yml|*.md|*.minisig|*.sig|*.asc)
                continue
                ;;
        esac

        # Skip if SBOM already exists
        local sbom_file="${artifact}.sbom.${format%%json}.json"
        if [[ -f "$sbom_file" ]]; then
            log_debug "SBOM already exists: $sbom_file"
            continue
        fi

        if sbom_generate "$artifact" --format "$format" --quiet; then
            ((generated++))
        else
            ((failed++))
        fi
    done < <(find "$artifacts_dir" -maxdepth 1 -type f 2>/dev/null)

    log_info "SBOM generation complete: $generated generated, $failed failed"

    [[ $failed -eq 0 ]]
}

# ============================================================================
# SBOM Verification
# ============================================================================

# Verify SBOM format is valid
# Args: sbom_file
sbom_verify() {
    local sbom_file="${1:-}"

    if [[ -z "$sbom_file" || ! -f "$sbom_file" ]]; then
        log_error "SBOM file required"
        return 4
    fi

    # Check if it's valid JSON
    if ! jq empty "$sbom_file" 2>/dev/null; then
        log_error "Invalid JSON: $sbom_file"
        return 1
    fi

    # Check for SPDX or CycloneDX format
    local format=""
    if jq -e '.spdxVersion' "$sbom_file" &>/dev/null; then
        format="spdx"
        local version
        version=$(jq -r '.spdxVersion' "$sbom_file")
        log_info "SPDX format detected: $version"
    elif jq -e '.bomFormat' "$sbom_file" &>/dev/null; then
        format="cyclonedx"
        local version
        version=$(jq -r '.specVersion' "$sbom_file")
        log_info "CycloneDX format detected: $version"
    else
        log_error "Unknown SBOM format"
        return 1
    fi

    log_ok "SBOM verified: $sbom_file ($format)"
    return 0
}

# ============================================================================
# JSON Output
# ============================================================================

# Generate SBOM and return JSON result
# Args: target [--format spdx|cyclonedx]
sbom_generate_json() {
    local target="${1:-}"
    shift 2>/dev/null || true

    local format="$SBOM_DEFAULT_FORMAT"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format|-f) format="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local start_time
    start_time=$(date +%s)

    local output_file status="success" error=""

    if ! sbom_check 2>/dev/null; then
        status="error"
        error="syft not installed"
    elif output_file=$(sbom_generate "$target" --format "$format" --quiet 2>&1); then
        status="success"
    else
        status="error"
        error="$output_file"
        output_file=""
    fi

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    jq -nc \
        --arg target "$target" \
        --arg format "$format" \
        --arg status "$status" \
        --arg output "${output_file:-}" \
        --arg error "${error:-}" \
        --argjson duration "$duration" \
        '{
            target: $target,
            format: $format,
            status: $status,
            output_file: (if $output == "" then null else $output end),
            error: (if $error == "" then null else $error end),
            duration_seconds: $duration
        }'
}

# ============================================================================
# Exports
# ============================================================================

export -f sbom_check sbom_version
export -f sbom_generate sbom_generate_project sbom_generate_artifacts
export -f sbom_verify sbom_generate_json
