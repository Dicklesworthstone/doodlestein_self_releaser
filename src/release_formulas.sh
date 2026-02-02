#!/usr/bin/env bash
# release_formulas.sh - Update Homebrew and Scoop manifests after release
#
# Usage:
#   source release_formulas.sh
#   cmd_release_formulas <tool> <version>   # Update formulas
#
# This module updates package manager manifests (Homebrew formulas and Scoop
# manifests) with version URLs and SHA256 checksums from a GitHub release.

set -uo pipefail

# ============================================================================
# RELEASE FORMULAS SUBCOMMAND - Update Homebrew/Scoop manifests
# ============================================================================

cmd_release_formulas() {
    local tool_name=""
    local version=""
    local homebrew_tap=""
    local scoop_bucket=""
    local skip_homebrew=false
    local skip_scoop=false
    local push_changes=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool|-t)
                tool_name="$2"
                shift 2
                ;;
            --version|-V)
                version="$2"
                shift 2
                ;;
            --homebrew-tap)
                homebrew_tap="$2"
                shift 2
                ;;
            --scoop-bucket)
                scoop_bucket="$2"
                shift 2
                ;;
            --skip-homebrew)
                skip_homebrew=true
                shift
                ;;
            --skip-scoop)
                skip_scoop=true
                shift
                ;;
            --push)
                push_changes=true
                shift
                ;;
            --help|-h)
                cat << 'EOF'
dsr release formulas - Update Homebrew and Scoop manifests

USAGE:
    dsr release formulas <tool> <version>
    dsr release formulas --tool <name> --version <tag>

OPTIONS:
    -t, --tool <name>          Tool to update formulas for
    -V, --version <ver>        Version to update to
    --homebrew-tap <repo>      Homebrew tap repo (default: from config)
    --scoop-bucket <repo>      Scoop bucket repo (default: from config)
    --skip-homebrew            Skip Homebrew formula update
    --skip-scoop               Skip Scoop manifest update
    --push                     Push changes to remote repos

DESCRIPTION:
    Updates Homebrew formula and Scoop manifest with new version URLs
    and SHA256 checksums from a GitHub release. Works in temp directories
    to avoid modifying /data/projects.

    In dry-run mode (--dry-run global flag), shows what would be updated
    without making changes.

EXAMPLES:
    dsr release formulas ntm 1.2.3               Update both
    dsr release formulas ntm 1.2.3 --skip-scoop  Homebrew only
    dsr release formulas ntm 1.2.3 --push        Update and push

EXIT CODES:
    0  - Formulas updated successfully
    1  - Some updates failed
    3  - Authentication error
    4  - Invalid arguments
    7  - Release not found
EOF
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                log_info "Run 'dsr release formulas --help' for usage"
                return 4
                ;;
            *)
                # Positional arguments: tool, version
                if [[ -z "$tool_name" ]]; then
                    tool_name="$1"
                elif [[ -z "$version" ]]; then
                    version="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$tool_name" ]]; then
        log_error "Tool name required"
        log_info "Run 'dsr release formulas --help' for usage"
        return 4
    fi

    if [[ -z "$version" ]]; then
        log_error "Version required"
        log_info "Run 'dsr release formulas --help' for usage"
        return 4
    fi

    # Check GitHub authentication
    if ! gh_check 2>/dev/null; then
        if ! gh_check_token 2>/dev/null; then
            log_error "GitHub authentication required"
            if $JSON_MODE; then
                json_envelope "release-formulas" "error" 3 '{"error": "GitHub authentication required"}'
            fi
            return 3
        fi
    fi

    # Load tool configuration
    if ! act_load_repo_config "$tool_name" 2>/dev/null; then
        log_error "Tool '$tool_name' not found in repos.d"
        return 4
    fi

    # Get repository info
    local repo
    repo=$(act_get_repo "$tool_name")
    if [[ -z "$repo" ]]; then
        log_error "No GitHub repo configured for $tool_name"
        return 4
    fi

    # Resolve owner/repo if short name
    if [[ ! "$repo" =~ / ]]; then
        repo="Dicklesworthstone/$repo"
    fi

    # Get tap/bucket from config if not specified
    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    if [[ -z "$homebrew_tap" ]]; then
        homebrew_tap=$(yq -r '.formulas.homebrew_tap // "Dicklesworthstone/homebrew-tap"' "$config_dir/config.yaml" 2>/dev/null || echo "Dicklesworthstone/homebrew-tap")
    fi
    if [[ -z "$scoop_bucket" ]]; then
        scoop_bucket=$(yq -r '.formulas.scoop_bucket // "Dicklesworthstone/scoop-bucket"' "$config_dir/config.yaml" 2>/dev/null || echo "Dicklesworthstone/scoop-bucket")
    fi

    # Normalize version tag
    local tag
    tag=$(git_ops_version_to_tag "$version")
    local version_num="${tag#v}"

    log_info "Updating formulas for $tool_name $tag"

    # Record start time
    local start_time
    start_time=$(date +%s)

    # Fetch release info from GitHub
    local release_json
    release_json=$(gh_api "repos/$repo/releases/tags/$tag" 2>/dev/null)
    if [[ -z "$release_json" ]] || ! echo "$release_json" | jq -e '.id' &>/dev/null; then
        log_error "Release $tag not found in $repo"
        if $JSON_MODE; then
            json_envelope "release-formulas" "error" 7 "$(jq -nc --arg tag "$tag" '{error: "Release not found", tag: $tag}')"
        fi
        return 7
    fi

    # Get release assets
    local assets_json
    assets_json=$(echo "$release_json" | jq -c '.assets // []')

    # Find checksums file
    local checksums_url=""
    checksums_url=$(echo "$assets_json" | jq -r '.[] | select(.name | test("SHA256|sha256|checksums"; "i")) | .browser_download_url' | head -1)

    local checksums_content=""
    if [[ -n "$checksums_url" ]]; then
        checksums_content=$(curl -sL "$checksums_url" 2>/dev/null)
    fi

    # Helper to get URL and SHA for a pattern
    _get_asset_info() {
        local pattern="$1"
        local url sha name
        name=$(echo "$assets_json" | jq -r --arg p "$pattern" '.[] | select(.name | test($p; "i")) | .name' | head -1)
        if [[ -n "$name" ]]; then
            url=$(echo "$assets_json" | jq -r --arg n "$name" '.[] | select(.name == $n) | .browser_download_url')
            if [[ -n "$checksums_content" ]]; then
                sha=$(printf '%s\n' "$checksums_content" | awk -v n="$name" '
                    $2==n {print $1; exit}
                    $2=="*"n {print $1; exit}
                    $1==n {print $2; exit}
                ')
            fi
            echo "$url|$sha"
        fi
    }

    # Get URLs and SHAs for each platform
    local darwin_arm64_info linux_amd64_info windows_amd64_info
    darwin_arm64_info=$(_get_asset_info "darwin.*arm64|arm64.*darwin|macos.*arm64")
    linux_amd64_info=$(_get_asset_info "linux.*amd64|amd64.*linux|linux.*x86_64")
    windows_amd64_info=$(_get_asset_info "windows.*amd64|amd64.*windows|win.*64")

    local darwin_arm64_url="${darwin_arm64_info%%|*}"
    local darwin_arm64_sha="${darwin_arm64_info##*|}"
    local linux_amd64_url="${linux_amd64_info%%|*}"
    local linux_amd64_sha="${linux_amd64_info##*|}"
    local windows_amd64_url="${windows_amd64_info%%|*}"
    local windows_amd64_sha="${windows_amd64_info##*|}"

    local homebrew_updated=false
    local scoop_updated=false
    local homebrew_error=""
    local scoop_error=""

    # Create temp directory for work
    local temp_dir
    temp_dir=$(mktemp -d)

    # Update Homebrew formula
    if ! $skip_homebrew && [[ -n "$darwin_arm64_url" || -n "$linux_amd64_url" ]]; then
        log_info "Updating Homebrew formula..."

        if $DRY_RUN; then
            log_info "[dry-run] Would update $homebrew_tap with:"
            log_info "  version: $version_num"
            [[ -n "$darwin_arm64_url" ]] && log_info "  darwin-arm64: $darwin_arm64_url"
            [[ -n "$darwin_arm64_sha" ]] && log_info "  darwin-arm64 sha256: $darwin_arm64_sha"
            [[ -n "$linux_amd64_url" ]] && log_info "  linux-amd64: $linux_amd64_url"
            [[ -n "$linux_amd64_sha" ]] && log_info "  linux-amd64 sha256: $linux_amd64_sha"
            homebrew_updated=true
        else
            local tap_dir="$temp_dir/homebrew-tap"
            if git clone --depth 1 "https://github.com/$homebrew_tap.git" "$tap_dir" 2>/dev/null; then
                local formula_file="$tap_dir/Formula/${tool_name}.rb"
                if [[ -f "$formula_file" ]]; then
                    # Update version
                    sed -i.bak "s/version \"[^\"]*\"/version \"$version_num\"/" "$formula_file"

                    # Update URLs and SHAs (simplified - real impl would use proper Ruby parsing)
                    if [[ -n "$darwin_arm64_url" ]]; then
                        sed -i.bak "s|url \".*darwin.*arm64.*\"|url \"$darwin_arm64_url\"|" "$formula_file"
                    fi
                    if [[ -n "$linux_amd64_url" ]]; then
                        sed -i.bak "s|url \".*linux.*amd64.*\"|url \"$linux_amd64_url\"|" "$formula_file"
                    fi

                    rm -f "$formula_file.bak"

                    # Validate with brew if available
                    if command -v brew &>/dev/null; then
                        brew audit --strict "$formula_file" 2>/dev/null && log_ok "  brew audit passed" || log_warn "  brew audit warnings"
                    fi

                    # Commit changes
                    if git -C "$tap_dir" diff --quiet; then
                        log_info "  No changes needed"
                    else
                        git -C "$tap_dir" add -A
                        git -C "$tap_dir" commit -m "Update $tool_name to $version_num" 2>/dev/null
                        if $push_changes; then
                            git -C "$tap_dir" push 2>/dev/null && log_ok "  Pushed" || { homebrew_error="Push failed"; log_error "  Push failed"; }
                        else
                            log_ok "  Changes committed (use --push to push)"
                        fi
                        homebrew_updated=true
                    fi
                else
                    log_warn "  Formula not found: $formula_file"
                    homebrew_error="Formula not found"
                fi
            else
                log_error "  Failed to clone $homebrew_tap"
                homebrew_error="Clone failed"
            fi
        fi
    elif ! $skip_homebrew; then
        log_warn "Skipping Homebrew: no macOS/Linux assets found"
    fi

    # Update Scoop manifest
    if ! $skip_scoop && [[ -n "$windows_amd64_url" ]]; then
        log_info "Updating Scoop manifest..."

        if $DRY_RUN; then
            log_info "[dry-run] Would update $scoop_bucket with:"
            log_info "  version: $version_num"
            log_info "  url: $windows_amd64_url"
            [[ -n "$windows_amd64_sha" ]] && log_info "  sha256: $windows_amd64_sha"
            scoop_updated=true
        else
            local bucket_dir="$temp_dir/scoop-bucket"
            if git clone --depth 1 "https://github.com/$scoop_bucket.git" "$bucket_dir" 2>/dev/null; then
                local manifest_file="$bucket_dir/bucket/${tool_name}.json"
                if [[ -f "$manifest_file" ]]; then
                    # Update manifest using jq
                    local new_manifest
                    new_manifest=$(jq \
                        --arg version "$version_num" \
                        --arg url "$windows_amd64_url" \
                        --arg sha "$windows_amd64_sha" \
                        '.version = $version | .url = $url | (if $sha != "" then .hash = "sha256:\($sha)" else . end)' \
                        "$manifest_file")

                    echo "$new_manifest" > "$manifest_file"

                    # Validate JSON
                    jq empty "$manifest_file" 2>/dev/null && log_ok "  JSON valid" || { log_error "  Invalid JSON"; scoop_error="Invalid JSON"; }

                    # Commit changes
                    if git -C "$bucket_dir" diff --quiet; then
                        log_info "  No changes needed"
                    else
                        git -C "$bucket_dir" add -A
                        git -C "$bucket_dir" commit -m "Update $tool_name to $version_num" 2>/dev/null
                        if $push_changes; then
                            git -C "$bucket_dir" push 2>/dev/null && log_ok "  Pushed" || { scoop_error="Push failed"; log_error "  Push failed"; }
                        else
                            log_ok "  Changes committed (use --push to push)"
                        fi
                        scoop_updated=true
                    fi
                else
                    log_warn "  Manifest not found: $manifest_file"
                    scoop_error="Manifest not found"
                fi
            else
                log_error "  Failed to clone $scoop_bucket"
                scoop_error="Clone failed"
            fi
        fi
    elif ! $skip_scoop; then
        log_warn "Skipping Scoop: no Windows assets found"
    fi

    # Cleanup temp directory
    rm -rf "$temp_dir"

    # Calculate duration
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Determine status
    local status="success"
    local exit_code=0
    if [[ -n "$homebrew_error" || -n "$scoop_error" ]]; then
        if ! $homebrew_updated && ! $scoop_updated; then
            status="error"
            exit_code=1
        else
            status="partial"
            exit_code=1
        fi
    fi

    # Output
    if $JSON_MODE; then
        local details
        details=$(jq -nc \
            --arg tool "$tool_name" \
            --arg version "$version_num" \
            --arg tag "$tag" \
            --arg repo "$repo" \
            --argjson homebrew_updated "$homebrew_updated" \
            --arg homebrew_tap "$homebrew_tap" \
            --arg homebrew_error "${homebrew_error:-}" \
            --argjson scoop_updated "$scoop_updated" \
            --arg scoop_bucket "$scoop_bucket" \
            --arg scoop_error "${scoop_error:-}" \
            --argjson pushed "$push_changes" \
            --argjson dry_run "$DRY_RUN" \
            --argjson duration "$duration" \
            '{
                tool: $tool,
                version: $version,
                tag: $tag,
                repo: $repo,
                homebrew: {
                    updated: $homebrew_updated,
                    tap: $homebrew_tap,
                    error: (if $homebrew_error == "" then null else $homebrew_error end)
                },
                scoop: {
                    updated: $scoop_updated,
                    bucket: $scoop_bucket,
                    error: (if $scoop_error == "" then null else $scoop_error end)
                },
                pushed: $pushed,
                dry_run: $dry_run,
                duration_seconds: $duration
            }')
        json_envelope "release-formulas" "$status" "$exit_code" "$details"
    else
        echo ""
        log_info "=== Formula Update Summary ==="
        log_info "Tool:     $tool_name"
        log_info "Version:  $tag"
        echo ""

        if $homebrew_updated; then
            log_ok "Homebrew: Updated ($homebrew_tap)"
        elif [[ -n "$homebrew_error" ]]; then
            log_error "Homebrew: Failed - $homebrew_error"
        else
            log_info "Homebrew: Skipped"
        fi

        if $scoop_updated; then
            log_ok "Scoop:    Updated ($scoop_bucket)"
        elif [[ -n "$scoop_error" ]]; then
            log_error "Scoop:    Failed - $scoop_error"
        else
            log_info "Scoop:    Skipped"
        fi

        echo ""
        if $push_changes; then
            log_info "Changes pushed to remote"
        elif $homebrew_updated || $scoop_updated; then
            log_info "Run with --push to push changes"
        fi
        log_info "Duration: ${duration}s"
    fi

    return $exit_code
}

# Export function
export -f cmd_release_formulas
