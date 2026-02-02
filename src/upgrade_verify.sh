#!/usr/bin/env bash
# src/upgrade_verify.sh - Verify tool upgrade commands work correctly
#
# bd-1jt.5.6: Implement upgrade command verification after release
#
# After releasing binaries, verify that each tool's `upgrade --check`
# command correctly finds and downloads the new release assets.
#
# Usage:
#   source "$SCRIPT_DIR/src/upgrade_verify.sh"
#   upgrade_verify_tool ntm
#   upgrade_verify_all
#
# Required modules:
#   - logging.sh (for log_info, log_error, etc.)
#   - config.sh (for repos config)

# ============================================================================
# Configuration
# ============================================================================

# Default timeout for upgrade check (seconds)
UPGRADE_VERIFY_TIMEOUT=30

# ============================================================================
# Verification Functions
# ============================================================================

# Verify upgrade command works for a tool
# Args: tool_name [--version <ver>] [--build-from-source]
# Returns: 0 on success, 1 on failure
upgrade_verify_tool() {
    local tool_name="${1:-}"
    shift 1 2>/dev/null || true

    local version=""  # Reserved for future use (assigned but not yet read)
    local build_from_source=false
    local dry_run=false

    # shellcheck disable=SC2034  # version is reserved for future use
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version|-V) version="$2"; shift 2 ;;
            --build-from-source) build_from_source=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$tool_name" ]]; then
        log_error "Tool name required"
        return 4
    fi

    log_info "Verifying upgrade command for $tool_name..."

    # Find the tool binary
    local bin_path=""

    # Check if installed in PATH
    if command -v "$tool_name" &>/dev/null; then
        bin_path=$(command -v "$tool_name")
        log_debug "Found $tool_name at: $bin_path"
    fi

    # Track if we built from source (for cleanup)
    local built_tmpdir=""

    # Build from source if requested or not found
    if $build_from_source || [[ -z "$bin_path" ]]; then
        local repo_dir
        repo_dir=$(_upgrade_find_repo_dir "$tool_name")

        if [[ -z "$repo_dir" || ! -d "$repo_dir" ]]; then
            log_error "Repository not found for $tool_name"
            return 1
        fi

        log_info "Building $tool_name from source..."
        bin_path=$(_upgrade_build_tool "$tool_name" "$repo_dir")

        if [[ -z "$bin_path" || ! -x "$bin_path" ]]; then
            log_error "Failed to build $tool_name"
            return 1
        fi

        # Track the tmpdir for cleanup (bin_path is like /tmp/xxx/tool)
        built_tmpdir=$(dirname "$bin_path")
    fi

    if [[ -z "$bin_path" ]]; then
        log_error "$tool_name not found in PATH and --build-from-source not specified"
        return 1
    fi

    # Run upgrade check
    log_info "Running upgrade check..."
    local output exit_code=0

    if $dry_run; then
        log_info "[DRY RUN] Would run: $bin_path upgrade --check"
        [[ -n "$built_tmpdir" ]] && rm -rf "$built_tmpdir"
        return 0
    fi

    local timeout_cmd=""
    if command -v timeout &>/dev/null; then
        timeout_cmd="timeout"
    elif command -v gtimeout &>/dev/null; then
        timeout_cmd="gtimeout"
    else
        log_warn "timeout command not available; running upgrade check without timeout"
    fi

    if [[ -n "$timeout_cmd" ]]; then
        output=$("$timeout_cmd" "$UPGRADE_VERIFY_TIMEOUT" "$bin_path" upgrade --check 2>&1) || exit_code=$?
    else
        output=$("$bin_path" upgrade --check 2>&1) || exit_code=$?
    fi

    # Parse output
    local found_asset=false
    local current_version=""
    local latest_version=""

    # Check for common success patterns
    if echo "$output" | grep -qi "up.to.date\|no update\|already.*latest\|current version"; then
        found_asset=true
        log_ok "$tool_name upgrade --check: Up to date"
    elif echo "$output" | grep -qi "found.*asset\|download.*available\|update.*available"; then
        found_asset=true
        log_ok "$tool_name upgrade --check: Found update"
    elif echo "$output" | grep -qi "no suitable release asset\|asset not found\|failed to find"; then
        found_asset=false
        log_error "$tool_name upgrade --check: Asset naming mismatch"
        log_error "Output: $output"
        [[ -n "$built_tmpdir" ]] && rm -rf "$built_tmpdir"
        return 1
    elif [[ $exit_code -eq 0 ]]; then
        # Exit 0 usually means success
        found_asset=true
        log_ok "$tool_name upgrade --check: Completed successfully"
    fi

    # Extract versions if present (using portable grep -oE)
    current_version=$(echo "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    latest_version=$(echo "$output" | grep -i 'latest' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

    if [[ -n "$current_version" ]]; then
        log_debug "Current version: $current_version"
    fi
    if [[ -n "$latest_version" ]]; then
        log_debug "Latest version: $latest_version"
    fi

    # Build result
    local platform
    platform="$(uname -s | tr '[:upper:]' '[:lower:]')/$(uname -m)"
    case "$platform" in
        linux/x86_64) platform="linux/amd64" ;;
        linux/aarch64) platform="linux/arm64" ;;
        darwin/arm64) platform="darwin/arm64" ;;
        darwin/x86_64) platform="darwin/amd64" ;;
    esac

    # Cleanup built binary tmpdir
    [[ -n "$built_tmpdir" ]] && rm -rf "$built_tmpdir"

    if $found_asset; then
        log_ok "Upgrade verification PASSED for $tool_name on $platform"
        return 0
    else
        log_error "Upgrade verification FAILED for $tool_name on $platform"
        log_error "Exit code: $exit_code"
        log_error "Output: $output"
        return 1
    fi
}

# Verify upgrade command for all tools
# Args: [--build-from-source]
upgrade_verify_all() {
    local build_from_source=false
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build-from-source) build_from_source=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            *) shift ;;
        esac
    done

    local repos_dir="${ACT_REPOS_DIR:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d}"
    local results=()
    local passed=0 failed=0 skipped=0

    if [[ ! -d "$repos_dir" ]]; then
        log_error "repos.d directory not found: $repos_dir"
        return 4
    fi

    log_info "Verifying upgrade commands for all tools..."

    local config_file tool_name
    for config_file in "$repos_dir"/*.yaml; do
        [[ -f "$config_file" ]] || continue
        [[ "$(basename "$config_file")" == _* ]] && continue

        tool_name=$(basename "$config_file" .yaml)

        # Check if tool has upgrade capability
        local has_upgrade=false
        if command -v "$tool_name" &>/dev/null; then
            if "$tool_name" --help 2>&1 | grep -q "upgrade"; then
                has_upgrade=true
            fi
        fi

        if ! $has_upgrade; then
            log_debug "Skipping $tool_name: no upgrade command"
            ((skipped++))
            results+=("$(jq -nc --arg tool "$tool_name" '{tool: $tool, status: "skipped", reason: "no upgrade command"}')")
            continue
        fi

        local args=""
        $build_from_source && args+=" --build-from-source"
        $dry_run && args+=" --dry-run"

        # shellcheck disable=SC2086
        if upgrade_verify_tool "$tool_name" $args; then
            ((passed++))
            results+=("$(jq -nc --arg tool "$tool_name" '{tool: $tool, status: "passed"}')")
        else
            ((failed++))
            results+=("$(jq -nc --arg tool "$tool_name" '{tool: $tool, status: "failed"}')")
        fi
    done

    # Summary
    log_info "Upgrade verification complete: $passed passed, $failed failed, $skipped skipped"

    [[ $failed -eq 0 ]]
}

# Get upgrade verification results as JSON
upgrade_verify_json() {
    local tool_name="${1:-}"
    local build_from_source=false

    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build-from-source) build_from_source=true; shift ;;
            *) shift ;;
        esac
    done

    local status=0
    local output exit_code platform

    platform="$(uname -s | tr '[:upper:]' '[:lower:]')/$(uname -m)"

    if [[ -n "$tool_name" ]]; then
        # Single tool
        local bin_path
        bin_path=$(command -v "$tool_name" 2>/dev/null || echo "")

        if [[ -z "$bin_path" ]]; then
            jq -nc \
                --arg tool "$tool_name" \
                --arg platform "$platform" \
                '{tool: $tool, status: "error", error: "Tool not found in PATH", platform: $platform}'
            return 1
        fi

        output=$(timeout "$UPGRADE_VERIFY_TIMEOUT" "$bin_path" upgrade --check 2>&1) || exit_code=$?

        local found_asset=false
        if echo "$output" | grep -qi "up.to.date\|no update\|already.*latest\|current version\|found.*asset\|download.*available\|update.*available"; then
            found_asset=true
            status=0
        elif [[ ${exit_code:-0} -eq 0 ]]; then
            found_asset=true
            status=0
        else
            found_asset=false
            status=1
        fi

        local result_status
        result_status=$([ $status -eq 0 ] && echo "passed" || echo "failed")
        jq -nc \
            --arg tool "$tool_name" \
            --arg result_status "$result_status" \
            --arg platform "$platform" \
            --argjson found_asset "$found_asset" \
            --argjson exit_code "${exit_code:-0}" \
            --arg output "$output" \
            '{
                tool: $tool,
                status: $result_status,
                platform: $platform,
                found_asset: $found_asset,
                exit_code: $exit_code,
                output: $output
            }'
        return $status
    else
        # All tools
        echo '{"tools": ['
        local first=true
        local repos_dir="${ACT_REPOS_DIR:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d}"

        for config_file in "$repos_dir"/*.yaml; do
            [[ -f "$config_file" ]] || continue
            [[ "$(basename "$config_file")" == _* ]] && continue

            tool_name=$(basename "$config_file" .yaml)
            $first || echo ","
            first=false

            upgrade_verify_json "$tool_name" 2>/dev/null || true
        done

        echo '], "platform": "'"$platform"'"}'
    fi
}

# ============================================================================
# Internal Helpers
# ============================================================================

# Find repository directory for a tool
_upgrade_find_repo_dir() {
    local tool_name="$1"
    local repos_dir="${ACT_REPOS_DIR:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d}"
    local config_file="$repos_dir/$tool_name.yaml"

    if [[ ! -f "$config_file" ]]; then
        # Try standard location
        local default_path="/data/projects/$tool_name"
        if [[ -d "$default_path" ]]; then
            echo "$default_path"
            return 0
        fi
        return 1
    fi

    # Get local_path from config
    local local_path
    if command -v yq &>/dev/null; then
        local_path=$(yq -r '.local_path // ""' "$config_file" 2>/dev/null)
    else
        local_path=$(grep '^local_path:' "$config_file" 2>/dev/null | \
                    sed 's/local_path:\s*//' | tr -d '"' | tr -d "'")
    fi

    if [[ -n "$local_path" && -d "$local_path" ]]; then
        echo "$local_path"
        return 0
    fi

    return 1
}

# Build tool from source
_upgrade_build_tool() {
    local tool_name="$1"
    local repo_dir="$2"
    local tmpdir
    tmpdir=$(mktemp -d)

    local bin_path="$tmpdir/$tool_name"

    if [[ -f "$repo_dir/go.mod" ]]; then
        # Go project
        log_debug "Building Go project..."
        if [[ -d "$repo_dir/cmd/$tool_name" ]]; then
            go build -o "$bin_path" "$repo_dir/cmd/$tool_name" 2>/dev/null
        elif [[ -f "$repo_dir/main.go" ]]; then
            go build -o "$bin_path" "$repo_dir" 2>/dev/null
        fi
    elif [[ -f "$repo_dir/Cargo.toml" ]]; then
        # Rust project
        log_debug "Building Rust project..."
        cargo build --release --manifest-path "$repo_dir/Cargo.toml" 2>/dev/null
        local target_path="$repo_dir/target/release/$tool_name"
        if [[ -f "$target_path" ]]; then
            cp "$target_path" "$bin_path"
        fi
    fi

    if [[ -x "$bin_path" ]]; then
        echo "$bin_path"
        return 0
    fi

    rm -rf "$tmpdir"
    return 1
}

# Export functions
export -f upgrade_verify_tool upgrade_verify_all upgrade_verify_json
export -f _upgrade_find_repo_dir _upgrade_build_tool
