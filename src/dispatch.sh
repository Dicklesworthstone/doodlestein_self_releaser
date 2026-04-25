#!/usr/bin/env bash
# dispatch.sh - Repository dispatch for cross-repo coordination
#
# bd-1jt.3.7: Implement repository dispatch for cross-repo coordination
#
# Usage:
#   source dispatch.sh
#   dispatch_event <repo> <event_type> --payload '{"key": "value"}'
#   dispatch_release <repo> <tool> <version>
#
# This module triggers downstream workflows after dsr release operations
# using GitHub's repository_dispatch event.

set -uo pipefail

# ============================================================================
# Configuration
# ============================================================================

DISPATCH_MAX_RETRIES="${DISPATCH_MAX_RETRIES:-3}"
DISPATCH_RETRY_DELAY="${DISPATCH_RETRY_DELAY:-5}"  # seconds

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _DP_RED=$'\033[0;31m'
    _DP_GREEN=$'\033[0;32m'
    _DP_YELLOW=$'\033[0;33m'
    _DP_BLUE=$'\033[0;34m'
    _DP_NC=$'\033[0m'
else
    _DP_RED='' _DP_GREEN='' _DP_YELLOW='' _DP_BLUE='' _DP_NC=''
fi

_dp_log_info()  { echo "${_DP_BLUE}[dispatch]${_DP_NC} $*" >&2; }
_dp_log_ok()    { echo "${_DP_GREEN}[dispatch]${_DP_NC} $*" >&2; }
_dp_log_warn()  { echo "${_DP_YELLOW}[dispatch]${_DP_NC} $*" >&2; }
_dp_log_error() { echo "${_DP_RED}[dispatch]${_DP_NC} $*" >&2; }
_dp_log_debug() { [[ "${DISPATCH_DEBUG:-}" == "1" ]] && echo "${_DP_BLUE}[dispatch:debug]${_DP_NC} $*" >&2 || true; }

# ============================================================================
# Authentication
# ============================================================================

# Resolve a GitHub token using the canonical cascade:
#   DSR_GH_TOKEN > GITHUB_TOKEN > GH_TOKEN > `gh auth token`
# Mirrors github.sh / docker.sh / secrets.sh. Previously this module
# only inspected GITHUB_TOKEN + `gh auth`, so users who set
# DSR_GH_TOKEN (the documented primary) or GH_TOKEN were rejected.
# Emits the token on stdout, returns 0 with non-empty token, 1 otherwise.
_dp_get_token() {
    local token=""
    if command -v secrets_get_gh_token &>/dev/null; then
        token=$(secrets_get_gh_token 2>/dev/null || true)
    fi
    [[ -z "$token" ]] && token="${DSR_GH_TOKEN:-}"
    [[ -z "$token" ]] && token="${GITHUB_TOKEN:-}"
    [[ -z "$token" ]] && token="${GH_TOKEN:-}"
    if [[ -z "$token" ]] && command -v gh &>/dev/null; then
        token=$(gh auth token 2>/dev/null || true)
    fi
    if [[ -z "$token" ]]; then
        return 1
    fi
    printf '%s' "$token"
    return 0
}

# Check if GitHub authentication is available
# Returns: 0 if authenticated, 3 if not
dispatch_check_auth() {
    if _dp_get_token >/dev/null; then
        return 0
    fi

    _dp_log_error "GitHub authentication required"
    _dp_log_info "Either run: gh auth login"
    _dp_log_info "Or set: export DSR_GH_TOKEN=<your-token> (or GITHUB_TOKEN / GH_TOKEN)"
    return 3
}

# ============================================================================
# Dispatch Operations
# ============================================================================

# Send a repository dispatch event
# Args: repo event_type [--payload json]
# Returns: 0 on success, non-zero on failure
dispatch_event() {
    local repo=""
    local event_type=""
    local payload="{}"
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --payload|-p)
                payload="$2"
                shift 2
                ;;
            --dry-run|-n)
                dry_run=true
                shift
                ;;
            *)
                if [[ -z "$repo" ]]; then
                    repo="$1"
                elif [[ -z "$event_type" ]]; then
                    event_type="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$repo" ]]; then
        _dp_log_error "Repository required"
        return 4
    fi

    if [[ -z "$event_type" ]]; then
        _dp_log_error "Event type required"
        return 4
    fi

    # Validate payload is valid JSON
    if ! echo "$payload" | jq empty &>/dev/null; then
        _dp_log_error "Invalid JSON payload"
        return 4
    fi

    # Check authentication
    if ! dispatch_check_auth; then
        return 3
    fi

    _dp_log_info "Dispatching event '$event_type' to $repo"
    _dp_log_debug "Payload: $payload"

    if $dry_run; then
        _dp_log_info "[dry-run] Would dispatch event to $repo"
        _dp_log_info "[dry-run] Event type: $event_type"
        _dp_log_info "[dry-run] Payload: $payload"
        return 0
    fi

    # Build request body
    local request_body
    request_body=$(jq -nc \
        --arg event_type "$event_type" \
        --argjson client_payload "$payload" \
        '{event_type: $event_type, client_payload: $client_payload}')

    # Send dispatch with retry
    local retry=0
    local exit_code=0

    while [[ $retry -lt $DISPATCH_MAX_RETRIES ]]; do
        if _dp_send_dispatch "$repo" "$request_body"; then
            _dp_log_ok "Dispatched event to $repo"
            return 0
        else
            exit_code=$?
            retry=$((retry + 1))

            if [[ $retry -lt $DISPATCH_MAX_RETRIES ]]; then
                local wait_time=$((DISPATCH_RETRY_DELAY * retry))
                _dp_log_warn "Dispatch failed. Retrying in ${wait_time}s (attempt $((retry+1))/$DISPATCH_MAX_RETRIES)"
                sleep "$wait_time"
            fi
        fi
    done

    _dp_log_error "Dispatch failed after $DISPATCH_MAX_RETRIES attempts"
    return $exit_code
}

# Internal: Send dispatch request
# Args: repo request_body
_dp_send_dispatch() {
    local repo="$1"
    local request_body="$2"

    # Try gh CLI first
    if command -v gh &>/dev/null && gh auth status &>/dev/null; then
        if echo "$request_body" | gh api "repos/$repo/dispatches" --input - -X POST &>/dev/null; then
            return 0
        fi
    fi

    # Fall back to curl
    local token
    token=$(_dp_get_token) || return 3

    local http_code response
    response=$(curl -sS \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $token" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d "$request_body" \
        -w "\n__HTTP_CODE__%{http_code}" \
        "https://api.github.com/repos/$repo/dispatches" 2>&1)

    http_code="${response##*__HTTP_CODE__}"
    response="${response%__HTTP_CODE__*}"

    # 204 No Content is success for dispatch
    if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
        return 0
    else
        _dp_log_error "HTTP $http_code: $response"
        return 7
    fi
}

# ============================================================================
# Release Dispatch
# ============================================================================

# Dispatch release event to downstream repos
# Args: tool version [--repos repo1,repo2,...] [--sha commit_sha]
dispatch_release() {
    local tool=""
    local version=""
    local repos=""
    local commit_sha=""
    local run_id=""
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool|-t)
                tool="$2"
                shift 2
                ;;
            --version|-V)
                version="$2"
                shift 2
                ;;
            --repos|-r)
                repos="$2"
                shift 2
                ;;
            --sha)
                commit_sha="$2"
                shift 2
                ;;
            --run-id)
                run_id="$2"
                shift 2
                ;;
            --dry-run|-n)
                dry_run=true
                shift
                ;;
            --help|-h)
                cat << 'EOF'
dispatch_release - Dispatch release event to downstream repos

USAGE:
    dispatch_release <tool> <version>
    dispatch_release --tool <name> --version <tag> [options]

OPTIONS:
    -t, --tool <name>      Tool name
    -V, --version <ver>    Version/tag
    -r, --repos <list>     Comma-separated list of target repos
    --sha <commit>         Commit SHA for the release
    --run-id <id>          Workflow run ID (for idempotency)
    -n, --dry-run          Show what would be done

DESCRIPTION:
    Triggers repository_dispatch events in downstream repositories
    after a release. This is used to:

    - Update checksum manifests
    - Update Homebrew/Scoop formulas
    - Run canary tests
    - Update documentation

    The payload includes tool name, version, commit SHA, and run ID
    for idempotency.

EXAMPLES:
    dispatch_release ntm v1.2.3
    dispatch_release ntm v1.2.3 --repos owner/repo1,owner/repo2
    dispatch_release ntm v1.2.3 --dry-run

EXIT CODES:
    0  - Events dispatched successfully
    1  - Some dispatches failed
    3  - Authentication error
    4  - Invalid arguments
EOF
                return 0
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
        _dp_log_error "Tool name required"
        return 4
    fi

    if [[ -z "$version" ]]; then
        _dp_log_error "Version required"
        return 4
    fi

    # Normalize version
    local tag="${version#v}"
    tag="v$tag"

    # Get commit SHA if not provided
    if [[ -z "$commit_sha" ]]; then
        if command -v git &>/dev/null; then
            commit_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        fi
    fi

    # Generate run ID if not provided (for idempotency)
    if [[ -z "$run_id" ]]; then
        run_id="$(hostname)-$(date +%Y%m%d%H%M%S)-$$"
    fi

    _dp_log_info "Dispatching release event for $tool $tag"

    # Build idempotent payload
    local payload
    payload=$(jq -nc \
        --arg tool "$tool" \
        --arg version "$tag" \
        --arg sha "${commit_sha:-unknown}" \
        --arg run_id "$run_id" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            tool: $tool,
            version: $version,
            sha: $sha,
            run_id: $run_id,
            timestamp: $timestamp
        }')

    _dp_log_debug "Payload: $payload"

    # Get target repos
    local target_repos=()
    if [[ -n "$repos" ]]; then
        IFS=',' read -ra target_repos <<< "$repos"
    else
        # Default: use the tool's own repo for self-dispatch
        local default_repo=""
        if command -v act_get_repo &>/dev/null; then
            default_repo=$(act_get_repo "$tool" 2>/dev/null) || default_repo=""
        fi
        [[ -z "$default_repo" ]] && default_repo="Dicklesworthstone/$tool"
        target_repos=("$default_repo")
    fi

    local dispatched=0
    local failed=0
    local results=()

    for repo in "${target_repos[@]}"; do
        local dispatch_args=("$repo" "dsr-release" --payload "$payload")
        $dry_run && dispatch_args+=(--dry-run)

        if dispatch_event "${dispatch_args[@]}"; then
            dispatched=$((dispatched + 1))
            results+=("$(jq -nc --arg repo "$repo" '{repo: $repo, status: "success"}')")
        else
            failed=$((failed + 1))
            results+=("$(jq -nc --arg repo "$repo" '{repo: $repo, status: "error"}')")
        fi
    done

    # Summary
    _dp_log_info ""
    _dp_log_info "=== Dispatch Summary ==="
    _dp_log_info "Tool:       $tool"
    _dp_log_info "Version:    $tag"
    _dp_log_info "Run ID:     $run_id"
    _dp_log_info "Dispatched: $dispatched repo(s)"
    [[ $failed -gt 0 ]] && _dp_log_error "Failed:     $failed repo(s)"

    [[ $failed -eq 0 ]]
}

# ============================================================================
# Batch Dispatch
# ============================================================================

# Dispatch events to multiple repos in parallel
# Args: event_type --repos repo1,repo2,... --payload json
dispatch_batch() {
    local event_type=""
    local repos=""
    local payload="{}"
    local dry_run=false
    local parallel=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --event|-e)
                event_type="$2"
                shift 2
                ;;
            --repos|-r)
                repos="$2"
                shift 2
                ;;
            --payload|-p)
                payload="$2"
                shift 2
                ;;
            --parallel)
                parallel=true
                shift
                ;;
            --dry-run|-n)
                dry_run=true
                shift
                ;;
            *)
                [[ -z "$event_type" ]] && event_type="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$event_type" ]]; then
        _dp_log_error "Event type required"
        return 4
    fi

    if [[ -z "$repos" ]]; then
        _dp_log_error "Repos required (--repos repo1,repo2,...)"
        return 4
    fi

    local target_repos=()
    IFS=',' read -ra target_repos <<< "$repos"

    _dp_log_info "Batch dispatching '$event_type' to ${#target_repos[@]} repo(s)"

    local dispatched=0
    local failed=0

    if $parallel; then
        # Bash-native parallel dispatch.
        # The previous GNU-parallel path failed at runtime: parallel
        # spawned a subshell that didn't have dispatch_event, the
        # _dp_* helpers, or the colour vars defined, and returned
        # immediately without updating dispatched/failed counters.
        # `&` + `wait <pid>` keeps every helper in scope, captures
        # each job's exit code, and removes the GNU-parallel dep.
        # Each dispatch is a single HTTP POST so launching all repos
        # concurrently is fine in practice (typical: 1-10 repos).
        _dp_log_info "Using parallel dispatch (${#target_repos[@]} concurrent)..."
        local pids=() pid_to_repo=()
        for repo in "${target_repos[@]}"; do
            local dispatch_args=("$repo" "$event_type" --payload "$payload")
            $dry_run && dispatch_args+=(--dry-run)
            ( dispatch_event "${dispatch_args[@]}" ) &
            pids+=("$!")
            pid_to_repo+=("$repo")
        done
        # Wait for each job and tally results by PID
        local idx
        for idx in "${!pids[@]}"; do
            if wait "${pids[$idx]}" 2>/dev/null; then
                dispatched=$((dispatched + 1))
            else
                failed=$((failed + 1))
                _dp_log_warn "Failed: ${pid_to_repo[$idx]}"
            fi
        done
    else
        # Sequential dispatch
        for repo in "${target_repos[@]}"; do
            local dispatch_args=("$repo" "$event_type" --payload "$payload")
            $dry_run && dispatch_args+=(--dry-run)

            if dispatch_event "${dispatch_args[@]}"; then
                dispatched=$((dispatched + 1))
            else
                failed=$((failed + 1))
            fi
        done
    fi

    _dp_log_info "Batch complete: $dispatched dispatched, $failed failed"
    [[ $failed -eq 0 ]]
}

# ============================================================================
# JSON Output
# ============================================================================

# Dispatch release with JSON output
dispatch_release_json() {
    local args=("$@")
    local start_time
    start_time=$(date +%s)

    local output status="success" exit_code=0
    output=$(dispatch_release "${args[@]}" 2>&1) || {
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

export -f dispatch_check_auth dispatch_event dispatch_release dispatch_batch dispatch_release_json
