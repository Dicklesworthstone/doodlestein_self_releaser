#!/usr/bin/env bash
# checksum_sync.sh - Sync checksums to downstream flywheel repos
#
# bd-1jt.3.5: Implement checksum auto-sync across flywheel repos
#
# Usage:
#   source checksum_sync.sh
#   checksum_sync <tool> <version>   # Sync checksums after release
#
# This module updates checksum manifests in downstream repos when installers
# change. It always works in /tmp to avoid modifying /data/projects.

set -uo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Never modify these directories
CHECKSUM_SYNC_PROTECTED_PATHS=("/data/projects" "$HOME/projects")

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _CS_RED=$'\033[0;31m'
    _CS_GREEN=$'\033[0;32m'
    _CS_YELLOW=$'\033[0;33m'
    _CS_BLUE=$'\033[0;34m'
    _CS_NC=$'\033[0m'
else
    _CS_RED='' _CS_GREEN='' _CS_YELLOW='' _CS_BLUE='' _CS_NC=''
fi

_cs_log_info()  { echo "${_CS_BLUE}[checksum-sync]${_CS_NC} $*" >&2; }
_cs_log_ok()    { echo "${_CS_GREEN}[checksum-sync]${_CS_NC} $*" >&2; }
_cs_log_warn()  { echo "${_CS_YELLOW}[checksum-sync]${_CS_NC} $*" >&2; }
_cs_log_error() { echo "${_CS_RED}[checksum-sync]${_CS_NC} $*" >&2; }
_cs_log_debug() { [[ "${CS_DEBUG:-}" == "1" ]] && echo "${_CS_BLUE}[checksum-sync:debug]${_CS_NC} $*" >&2 || true; }

# ============================================================================
# Safety Checks
# ============================================================================

# Verify path is safe to modify (not in protected directories)
# Args: path
# Returns: 0 if safe, 1 if protected
_cs_is_safe_path() {
    local path="$1"
    local abs_path
    abs_path=$(realpath -m "$path" 2>/dev/null || echo "$path")

    for protected in "${CHECKSUM_SYNC_PROTECTED_PATHS[@]}"; do
        # Check for exact match OR path is inside protected directory
        if [[ "$abs_path" == "$protected" || "$abs_path" == "$protected/"* ]]; then
            _cs_log_error "Refusing to modify protected path: $abs_path"
            _cs_log_error "Protected prefix: $protected"
            return 1
        fi
    done
    return 0
}

# ============================================================================
# Checksum Operations
# ============================================================================

# Generate SHA256 checksums for files in a directory
# Args: dir [--output file]
# Returns: 0 on success, writes checksums to stdout or file
checksum_generate() {
    local dir=""
    local output=""
    local include_pattern="*"
    local exclude_pattern=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output|-o)
                output="$2"
                shift 2
                ;;
            --include|-i)
                include_pattern="$2"
                shift 2
                ;;
            --exclude|-e)
                exclude_pattern="$2"
                shift 2
                ;;
            *)
                dir="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$dir" || ! -d "$dir" ]]; then
        _cs_log_error "Directory required"
        return 4
    fi

    local checksums=""

    # Find files matching include pattern, excluding unwanted files
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        local filename
        filename=$(basename "$file")

        # Skip checksums, signatures, and provenance files
        case "$filename" in
            *.txt|*.sha256|*.sha512|*.md5|*.minisig|*.sig|*.asc|*.intoto.jsonl|*.sbom.*)
                continue
                ;;
        esac

        # Skip if matches exclude pattern
        if [[ -n "$exclude_pattern" && "$filename" =~ $exclude_pattern ]]; then
            continue
        fi

        local sha256
        sha256=$(sha256sum "$file" | cut -d' ' -f1)
        checksums+="$sha256  $filename"$'\n'
    done < <(find "$dir" -maxdepth 1 -type f -name "$include_pattern" 2>/dev/null | sort)

    if [[ -n "$output" ]]; then
        echo -n "$checksums" > "$output"
    else
        echo -n "$checksums"
    fi
}

# Verify checksums from a manifest file
# Args: checksums_file dir
# Returns: 0 if all match, 1 if mismatch
checksum_verify() {
    local checksums_file="$1"
    local dir="$2"

    if [[ ! -f "$checksums_file" ]]; then
        _cs_log_error "Checksums file not found: $checksums_file"
        return 4
    fi

    if [[ ! -d "$dir" ]]; then
        _cs_log_error "Directory not found: $dir"
        return 4
    fi

    local failed=0
    local verified=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        local expected_sha filename
        expected_sha=$(echo "$line" | awk '{print $1}')
        filename=$(echo "$line" | awk '{print $2}')

        local file_path="$dir/$filename"
        if [[ ! -f "$file_path" ]]; then
            _cs_log_warn "File not found: $filename"
            ((failed++))
            continue
        fi

        local actual_sha
        actual_sha=$(sha256sum "$file_path" | cut -d' ' -f1)

        if [[ "$expected_sha" == "$actual_sha" ]]; then
            _cs_log_debug "✓ $filename"
            ((verified++))
        else
            _cs_log_error "✗ $filename: checksum mismatch"
            _cs_log_error "  Expected: $expected_sha"
            _cs_log_error "  Actual:   $actual_sha"
            ((failed++))
        fi
    done < "$checksums_file"

    if [[ $failed -gt 0 ]]; then
        _cs_log_error "Verification failed: $failed file(s)"
        return 1
    fi

    _cs_log_ok "Verified $verified file(s)"
    return 0
}

# ============================================================================
# Repository Sync
# ============================================================================

# Clone a repository to a temp directory
# Args: repo [--branch branch]
# Returns: path to cloned repo on stdout
_cs_clone_repo() {
    local repo="$1"
    local branch="${2:-}"

    # Ensure we're working in /tmp
    local temp_dir
    temp_dir=$(mktemp -d "/tmp/dsr-checksum-sync-XXXXXX")

    if ! _cs_is_safe_path "$temp_dir"; then
        rm -rf "$temp_dir"
        return 1
    fi

    local clone_args=(--depth 1)
    [[ -n "$branch" ]] && clone_args+=(--branch "$branch")

    local repo_url="https://github.com/$repo.git"
    if git clone "${clone_args[@]}" "$repo_url" "$temp_dir/repo" 2>/dev/null; then
        echo "$temp_dir/repo"
        return 0
    else
        _cs_log_error "Failed to clone: $repo"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Update checksums in a target repository
# Args: repo_path checksums_content [--commit] [--push]
_cs_update_repo_checksums() {
    local repo_path="$1"
    local checksums_content="$2"
    local commit=false
    local push=false
    local checksums_file=""

    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --commit) commit=true; shift ;;
            --push) push=true; shift ;;
            --checksums-file) checksums_file="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if ! _cs_is_safe_path "$repo_path"; then
        return 1
    fi

    # Find or create checksums file
    if [[ -z "$checksums_file" ]]; then
        checksums_file="SHA256SUMS.txt"
    fi

    local full_path="$repo_path/$checksums_file"

    # Update checksums
    echo -n "$checksums_content" > "$full_path"
    _cs_log_ok "Updated: $checksums_file"

    if $commit; then
        git -C "$repo_path" add "$checksums_file"
        if ! git -C "$repo_path" diff --cached --quiet; then
            git -C "$repo_path" commit -m "Update checksums" >/dev/null 2>&1
            _cs_log_ok "Committed changes"

            if $push; then
                if git -C "$repo_path" push >/dev/null 2>&1; then
                    _cs_log_ok "Pushed to remote"
                else
                    _cs_log_error "Push failed"
                    return 1
                fi
            fi
        else
            _cs_log_info "No changes to commit"
        fi
    fi

    return 0
}

# ============================================================================
# Main Sync Command
# ============================================================================

# Sync checksums to downstream repos after release
# Usage: checksum_sync <tool> <version> [options]
# Options:
#   --artifacts-dir <dir>  Directory with release artifacts
#   --target-repo <repo>   Target repository to update (can repeat)
#   --checksums-file <file> Checksums file in target repo (default: SHA256SUMS.txt)
#   --push                  Push changes to remote
#   --open-issue            Open security review issue instead of auto-merge
#   --dry-run               Show what would be done
checksum_sync() {
    local tool_name=""
    local version=""
    local artifacts_dir=""
    local target_repos=()
    local checksums_file="SHA256SUMS.txt"
    local push_changes=false
    local open_issue=false
    local dry_run=false
    local is_external=false

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
            --artifacts-dir|-a)
                artifacts_dir="$2"
                shift 2
                ;;
            --target-repo|-r)
                target_repos+=("$2")
                shift 2
                ;;
            --checksums-file)
                checksums_file="$2"
                shift 2
                ;;
            --push)
                push_changes=true
                shift
                ;;
            --open-issue)
                open_issue=true
                shift
                ;;
            --external)
                is_external=true
                shift
                ;;
            --dry-run|-n)
                dry_run=true
                shift
                ;;
            --help|-h)
                cat << 'EOF'
checksum_sync - Sync checksums to downstream repos

USAGE:
    checksum_sync <tool> <version>
    checksum_sync --tool <name> --version <tag> [options]

OPTIONS:
    -t, --tool <name>           Tool to sync checksums for
    -V, --version <ver>         Version/tag to sync
    -a, --artifacts-dir <dir>   Directory with release artifacts
    -r, --target-repo <repo>    Target repository (can repeat)
    --checksums-file <file>     Checksums file name (default: SHA256SUMS.txt)
    --push                      Push changes to remote repos
    --open-issue                Open security review issue (for external tools)
    --external                  Treat as external tool (triggers review)
    -n, --dry-run               Show what would be done

DESCRIPTION:
    After a dsr release, updates checksum manifests in downstream repositories.

    For internal tools: auto-commits and optionally pushes changes.
    For external tools: opens a security review issue instead of auto-merge.

    All operations happen in /tmp to avoid modifying /data/projects.

EXAMPLES:
    checksum_sync ntm v1.2.3                      # Auto-detect artifacts
    checksum_sync ntm v1.2.3 --push               # Commit and push
    checksum_sync ntm v1.2.3 --external           # Open review issue
    checksum_sync ntm v1.2.3 --dry-run            # Preview changes

EXIT CODES:
    0  - Checksums synced successfully
    1  - Sync failed
    3  - Authentication error
    4  - Invalid arguments
    7  - Artifacts not found
EOF
                return 0
                ;;
            -*)
                _cs_log_error "Unknown option: $1"
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
        _cs_log_error "Tool name required"
        return 4
    fi

    if [[ -z "$version" ]]; then
        _cs_log_error "Version required"
        return 4
    fi

    # Record start time
    local start_time
    start_time=$(date +%s)

    # Normalize version
    local tag="${version#v}"
    tag="v$tag"

    _cs_log_info "Syncing checksums for $tool_name $tag"

    # If artifacts directory not specified, try to find release artifacts
    if [[ -z "$artifacts_dir" ]]; then
        # Try common locations
        local state_dir="${DSR_STATE_DIR:-$HOME/.local/state/dsr}"
        local possible_dirs=(
            "$state_dir/releases/$tool_name/$tag"
            "$state_dir/artifacts/$tool_name/$tag"
            "/tmp/dsr-release-$tool_name-$tag"
        )
        for dir in "${possible_dirs[@]}"; do
            if [[ -d "$dir" ]]; then
                artifacts_dir="$dir"
                break
            fi
        done
    fi

    # Generate checksums
    local checksums_content=""
    if [[ -n "$artifacts_dir" && -d "$artifacts_dir" ]]; then
        _cs_log_info "Generating checksums from: $artifacts_dir"
        checksums_content=$(checksum_generate "$artifacts_dir")
    else
        # Try to fetch from GitHub release
        _cs_log_info "Fetching checksums from GitHub release..."
        local repo
        if command -v act_get_repo &>/dev/null; then
            repo=$(act_get_repo "$tool_name" 2>/dev/null)
        fi
        [[ -z "$repo" ]] && repo="Dicklesworthstone/$tool_name"

        local checksums_url="https://github.com/$repo/releases/download/$tag/${tool_name}-${tag#v}-SHA256SUMS.txt"
        checksums_content=$(curl -sL "$checksums_url" 2>/dev/null)

        if [[ -z "$checksums_content" ]]; then
            _cs_log_error "Could not find checksums for $tool_name $tag"
            _cs_log_error "Tried: $checksums_url"
            return 7
        fi
    fi

    if [[ -z "$checksums_content" ]]; then
        _cs_log_error "No checksums to sync"
        return 7
    fi

    _cs_log_debug "Checksums content:"
    _cs_log_debug "$checksums_content"

    # If no target repos specified, use default (the tool's own repo)
    if [[ ${#target_repos[@]} -eq 0 ]]; then
        local default_repo=""
        if command -v act_get_repo &>/dev/null; then
            default_repo=$(act_get_repo "$tool_name" 2>/dev/null) || default_repo=""
        fi
        [[ -z "$default_repo" ]] && default_repo="Dicklesworthstone/$tool_name"
        target_repos=("$default_repo")
    fi

    local synced=0
    local failed=0
    local issues_opened=0
    local results=()

    for target_repo in "${target_repos[@]}"; do
        _cs_log_info "Updating: $target_repo"

        if $dry_run; then
            _cs_log_info "[dry-run] Would update $checksums_file in $target_repo"
            _cs_log_info "[dry-run] Checksums:"
            echo "$checksums_content" | head -5 >&2
            [[ $(echo "$checksums_content" | wc -l) -gt 5 ]] && _cs_log_info "[dry-run] ..."
            ((synced++))
            continue
        fi

        # For external tools, open an issue instead of auto-merge
        if $is_external || $open_issue; then
            _cs_log_info "Opening security review issue for external tool..."

            local issue_title="Security Review: Update checksums for $tool_name $tag"
            local issue_body="## Checksum Update Request

Tool: \`$tool_name\`
Version: \`$tag\`

### Proposed Checksums
\`\`\`
$checksums_content
\`\`\`

### Action Required
Please review and verify these checksums before merging.

- [ ] Checksums match official release
- [ ] No unexpected changes
- [ ] Source verified

/cc @maintainer"

            if command -v gh &>/dev/null && gh auth status &>/dev/null; then
                if gh issue create --repo "$target_repo" --title "$issue_title" --body "$issue_body" >/dev/null 2>&1; then
                    _cs_log_ok "Security review issue opened in $target_repo"
                    ((issues_opened++))
                    results+=("{\"repo\": \"$target_repo\", \"action\": \"issue_opened\", \"status\": \"success\"}")
                else
                    _cs_log_error "Failed to open issue in $target_repo"
                    ((failed++))
                    results+=("{\"repo\": \"$target_repo\", \"action\": \"issue_opened\", \"status\": \"error\"}")
                fi
            else
                _cs_log_warn "gh CLI not available, cannot open issue"
                _cs_log_info "Manual review required for: $target_repo"
                ((failed++))
                results+=("{\"repo\": \"$target_repo\", \"action\": \"issue_opened\", \"status\": \"error\", \"reason\": \"gh_unavailable\"}")
            fi
            continue
        fi

        # Clone repo to temp directory
        local repo_path
        repo_path=$(_cs_clone_repo "$target_repo")
        if [[ -z "$repo_path" ]]; then
            _cs_log_error "Failed to clone $target_repo"
            ((failed++))
            results+=("{\"repo\": \"$target_repo\", \"action\": \"clone\", \"status\": \"error\"}")
            continue
        fi

        # Update checksums
        local update_args=(--commit)
        $push_changes && update_args+=(--push)
        update_args+=(--checksums-file "$checksums_file")

        if _cs_update_repo_checksums "$repo_path" "$checksums_content" "${update_args[@]}"; then
            ((synced++))
            results+=("{\"repo\": \"$target_repo\", \"action\": \"updated\", \"status\": \"success\", \"pushed\": $push_changes}")
        else
            ((failed++))
            results+=("{\"repo\": \"$target_repo\", \"action\": \"update\", \"status\": \"error\"}")
        fi

        # Cleanup
        rm -rf "$(dirname "$repo_path")"
    done

    # Calculate duration
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Determine overall status
    local status="success"
    local exit_code=0
    if [[ $failed -gt 0 ]]; then
        if [[ $synced -eq 0 && $issues_opened -eq 0 ]]; then
            status="error"
            exit_code=1
        else
            status="partial"
            exit_code=1
        fi
    fi

    # Output summary
    _cs_log_info ""
    _cs_log_info "=== Checksum Sync Summary ==="
    _cs_log_info "Tool:     $tool_name"
    _cs_log_info "Version:  $tag"
    _cs_log_info "Synced:   $synced repo(s)"
    [[ $issues_opened -gt 0 ]] && _cs_log_info "Issues:   $issues_opened opened"
    [[ $failed -gt 0 ]] && _cs_log_error "Failed:   $failed repo(s)"
    _cs_log_info "Duration: ${duration}s"

    return $exit_code
}

# JSON output wrapper
checksum_sync_json() {
    local args=("$@")
    local start_time
    start_time=$(date +%s)

    local output status="success" exit_code=0
    output=$(checksum_sync "${args[@]}" 2>&1) || {
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

export -f checksum_generate checksum_verify checksum_sync checksum_sync_json
