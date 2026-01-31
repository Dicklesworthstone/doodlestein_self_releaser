#!/usr/bin/env bash
# src/slsa.sh - SLSA provenance attestation generation
#
# bd-1jt.3.6: Implement SLSA provenance attestation for supply chain security
#
# Generates SLSA v1 provenance (in-toto Statement + predicate) for release artifacts.
# This provides verifiable build provenance for supply chain security.
#
# Usage:
#   source "$SCRIPT_DIR/src/slsa.sh"
#   slsa_generate /path/to/artifact --builder "dsr/v1"
#   slsa_verify /path/to/artifact
#
# Required modules:
#   - logging.sh (for log_info, log_error, etc.)

# ============================================================================
# Configuration
# ============================================================================

# SLSA specification version
SLSA_SPEC_VERSION="1.0"

# Builder identity
SLSA_BUILDER_ID="${SLSA_BUILDER_ID:-https://github.com/Dicklesworthstone/doodlestein_self_releaser}"

# ============================================================================
# In-Toto Statement Generation
# ============================================================================

# Generate SLSA v1 provenance for an artifact
# Args: artifact_path [--builder <id>] [--output <file>]
# Returns: 0 on success, path to provenance file on stdout
slsa_generate() {
    local artifact="${1:-}"
    shift 2>/dev/null || true

    local builder_id="$SLSA_BUILDER_ID"
    local output=""
    local build_type="dsr-local"
    local invocation_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --builder|-b) builder_id="$2"; shift 2 ;;
            --output|-o) output="$2"; shift 2 ;;
            --build-type) build_type="$2"; shift 2 ;;
            --invocation-id) invocation_id="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$artifact" ]]; then
        log_error "Artifact path required"
        return 4
    fi

    if [[ ! -f "$artifact" ]]; then
        log_error "Artifact not found: $artifact"
        return 4
    fi

    # Determine output file
    if [[ -z "$output" ]]; then
        output="${artifact}.intoto.jsonl"
    fi

    log_info "Generating SLSA provenance for: $artifact"

    # Calculate artifact digest
    local artifact_sha256
    artifact_sha256=$(sha256sum "$artifact" | cut -d' ' -f1)

    local artifact_name
    artifact_name=$(basename "$artifact")

    # Get timestamps
    local started_at finished_at
    started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    finished_at="$started_at"

    # Generate invocation ID if not provided
    if [[ -z "$invocation_id" ]]; then
        invocation_id="$(hostname)-$(date +%Y%m%d%H%M%S)-$$"
    fi

    # Get git info if available
    local git_repo="" git_commit="" git_ref=""
    if command -v git &>/dev/null; then
        git_repo=$(git config --get remote.origin.url 2>/dev/null || echo "")
        git_commit=$(git rev-parse HEAD 2>/dev/null || echo "")
        git_ref=$(git symbolic-ref -q HEAD 2>/dev/null || echo "")
    fi

    # Build the in-toto statement with SLSA v1 provenance predicate
    local statement
    statement=$(jq -nc \
        --arg artifact_name "$artifact_name" \
        --arg artifact_sha256 "$artifact_sha256" \
        --arg builder_id "$builder_id" \
        --arg build_type "$build_type" \
        --arg invocation_id "$invocation_id" \
        --arg started_at "$started_at" \
        --arg finished_at "$finished_at" \
        --arg git_repo "$git_repo" \
        --arg git_commit "$git_commit" \
        --arg git_ref "$git_ref" \
        --arg hostname "$(hostname)" \
        --arg user "${USER:-unknown}" \
        '{
            "_type": "https://in-toto.io/Statement/v1",
            "subject": [
                {
                    "name": $artifact_name,
                    "digest": {
                        "sha256": $artifact_sha256
                    }
                }
            ],
            "predicateType": "https://slsa.dev/provenance/v1",
            "predicate": {
                "buildDefinition": {
                    "buildType": ("https://github.com/Dicklesworthstone/doodlestein_self_releaser/buildtype/" + $build_type),
                    "externalParameters": {
                        "repository": $git_repo,
                        "ref": $git_ref
                    },
                    "internalParameters": {
                        "buildHost": $hostname,
                        "buildUser": $user
                    },
                    "resolvedDependencies": []
                },
                "runDetails": {
                    "builder": {
                        "id": $builder_id,
                        "version": {}
                    },
                    "metadata": {
                        "invocationId": $invocation_id,
                        "startedOn": $started_at,
                        "finishedOn": $finished_at
                    },
                    "byproducts": []
                }
            }
        }')

    # Add source info if git is available
    if [[ -n "$git_repo" && -n "$git_commit" ]]; then
        statement=$(echo "$statement" | jq \
            --arg git_repo "$git_repo" \
            --arg git_commit "$git_commit" \
            '.predicate.buildDefinition.resolvedDependencies += [{
                "uri": $git_repo,
                "digest": {
                    "gitCommit": $git_commit
                }
            }]')
    fi

    # Write to output file
    echo "$statement" > "$output"

    log_ok "SLSA provenance generated: $output"
    echo "$output"
    return 0
}

# Generate provenance for multiple artifacts
# Args: artifacts_dir [--builder <id>]
slsa_generate_batch() {
    local artifacts_dir="${1:-}"
    shift 2>/dev/null || true

    local builder_id="$SLSA_BUILDER_ID"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --builder|-b) builder_id="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$artifacts_dir" || ! -d "$artifacts_dir" ]]; then
        log_error "Artifacts directory required"
        return 4
    fi

    local generated=0
    local failed=0

    # Find all artifacts (exclude checksums, signatures, existing provenance)
    while IFS= read -r artifact; do
        [[ -z "$artifact" ]] && continue

        local filename
        filename=$(basename "$artifact")

        # Skip non-artifacts
        case "$filename" in
            *.txt|*.json|*.yaml|*.yml|*.md|*.minisig|*.sig|*.asc|*.intoto.jsonl|*.sbom.*)
                continue
                ;;
        esac

        # Skip if provenance already exists
        if [[ -f "${artifact}.intoto.jsonl" ]]; then
            log_debug "Provenance already exists: ${artifact}.intoto.jsonl"
            continue
        fi

        if slsa_generate "$artifact" --builder "$builder_id" >/dev/null; then
            ((generated++))
        else
            ((failed++))
        fi
    done < <(find "$artifacts_dir" -maxdepth 1 -type f 2>/dev/null)

    log_info "SLSA provenance generation complete: $generated generated, $failed failed"

    [[ $failed -eq 0 ]]
}

# ============================================================================
# Verification
# ============================================================================

# Verify SLSA provenance for an artifact
# Args: artifact_path [provenance_path]
slsa_verify() {
    local artifact="${1:-}"
    local provenance="${2:-}"

    if [[ -z "$artifact" ]]; then
        log_error "Artifact path required"
        return 4
    fi

    if [[ ! -f "$artifact" ]]; then
        log_error "Artifact not found: $artifact"
        return 4
    fi

    # Find provenance file if not specified
    if [[ -z "$provenance" ]]; then
        provenance="${artifact}.intoto.jsonl"
    fi

    if [[ ! -f "$provenance" ]]; then
        log_error "Provenance not found: $provenance"
        return 1
    fi

    log_info "Verifying SLSA provenance for: $artifact"

    # Verify JSON structure
    if ! jq empty "$provenance" 2>/dev/null; then
        log_error "Invalid JSON: $provenance"
        return 1
    fi

    # Verify in-toto statement type
    local stmt_type
    stmt_type=$(jq -r '._type' "$provenance")
    if [[ "$stmt_type" != "https://in-toto.io/Statement/v1" ]]; then
        log_error "Invalid statement type: $stmt_type"
        return 1
    fi

    # Verify predicate type
    local pred_type
    pred_type=$(jq -r '.predicateType' "$provenance")
    if [[ "$pred_type" != "https://slsa.dev/provenance/v1" ]]; then
        log_error "Invalid predicate type: $pred_type"
        return 1
    fi

    # Verify artifact digest
    local expected_sha256
    expected_sha256=$(jq -r '.subject[0].digest.sha256' "$provenance")

    local actual_sha256
    actual_sha256=$(sha256sum "$artifact" | cut -d' ' -f1)

    if [[ "$expected_sha256" != "$actual_sha256" ]]; then
        log_error "Digest mismatch!"
        log_error "  Expected: $expected_sha256"
        log_error "  Actual:   $actual_sha256"
        return 1
    fi

    log_ok "SLSA provenance verified: $artifact"
    return 0
}

# ============================================================================
# JSON Output
# ============================================================================

# Generate provenance and return JSON result
slsa_generate_json() {
    local artifact="${1:-}"
    shift 2>/dev/null || true

    local builder_id="$SLSA_BUILDER_ID"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --builder|-b) builder_id="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local start_time
    start_time=$(date +%s)

    local output_file status="success" error=""

    if output_file=$(slsa_generate "$artifact" --builder "$builder_id" 2>&1); then
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
        --arg artifact "$artifact" \
        --arg builder "$builder_id" \
        --arg status "$status" \
        --arg output "${output_file:-}" \
        --arg error "${error:-}" \
        --argjson duration "$duration" \
        '{
            artifact: $artifact,
            builder: $builder,
            status: $status,
            output_file: (if $output == "" then null else $output end),
            error: (if $error == "" then null else $error end),
            duration_seconds: $duration
        }'
}

# ============================================================================
# Exports
# ============================================================================

export -f slsa_generate slsa_generate_batch slsa_verify slsa_generate_json
