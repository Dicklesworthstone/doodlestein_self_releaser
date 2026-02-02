#!/usr/bin/env bash
# github.sh - GitHub API adapter with caching and rate-limit handling for dsr
#
# Usage:
#   source github.sh
#   gh_api <endpoint>                    # GET request
#   gh_api <endpoint> --post <data>      # POST request
#   gh_workflow_runs <owner/repo>        # List workflow runs
#   gh_releases <owner/repo>             # List releases
#   gh_create_release <owner/repo> <tag> # Create a release
#
# Caching:
#   Responses cached in ~/.cache/dsr/github/ with ETag validation
#   Default TTL: 60 seconds (configurable via GH_CACHE_TTL)

set -uo pipefail

# Cache configuration
GH_CACHE_DIR="${DSR_CACHE_DIR:-$HOME/.cache/dsr}/github"
GH_CACHE_TTL="${GH_CACHE_TTL:-60}"  # seconds
GH_MAX_RETRIES="${GH_MAX_RETRIES:-3}"
GH_RETRY_DELAY="${GH_RETRY_DELAY:-5}"  # seconds

# Last HTTP response metadata (curl path)
_GH_LAST_HTTP_CODE=""
_GH_LAST_ETAG=""

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _GH_RED=$'\033[0;31m'
    _GH_GREEN=$'\033[0;32m'
    _GH_YELLOW=$'\033[0;33m'
    _GH_BLUE=$'\033[0;34m'
    _GH_NC=$'\033[0m'
else
    _GH_RED='' _GH_GREEN='' _GH_YELLOW='' _GH_BLUE='' _GH_NC=''
fi

_gh_log_info()  { echo "${_GH_BLUE}[github]${_GH_NC} $*" >&2; }
_gh_log_ok()    { echo "${_GH_GREEN}[github]${_GH_NC} $*" >&2; }
_gh_log_warn()  { echo "${_GH_YELLOW}[github]${_GH_NC} $*" >&2; }
_gh_log_error() { echo "${_GH_RED}[github]${_GH_NC} $*" >&2; }
_gh_log_debug() { [[ "${GH_DEBUG:-}" == "1" ]] && echo "${_GH_BLUE}[github:debug]${_GH_NC} $*" >&2; }

# Initialize cache directory
gh_init_cache() {
    mkdir -p "$GH_CACHE_DIR"
}

# Check if gh CLI is available and authenticated
# Returns: 0 if ready, 3 if not
gh_check() {
    if ! command -v gh &>/dev/null; then
        _gh_log_warn "gh CLI not found, falling back to curl"
        return 1
    fi

    if ! gh auth status &>/dev/null 2>&1; then
        _gh_log_warn "gh CLI not authenticated, falling back to curl"
        return 1
    fi

    return 0
}

# Check if GITHUB_TOKEN is available for curl fallback
gh_check_token() {
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        _gh_log_error "GITHUB_TOKEN not set and gh CLI not authenticated"
        _gh_log_info "Either run: gh auth login"
        _gh_log_info "Or set: export GITHUB_TOKEN=<your-token>"
        return 3
    fi
    return 0
}

# Generate cache key from endpoint
_gh_cache_key() {
    local endpoint="$1"
    # Create safe filename from endpoint
    local key="${endpoint//\//_}"
    # Replace any remaining non-alphanumeric characters with underscore
    key="${key//[^a-zA-Z0-9_-]/_}"
    echo "$key"
}

# Get cached response if valid
# Usage: _gh_get_cache <endpoint>
# Returns: cached response on stdout if valid, empty if expired/missing
_gh_get_cache() {
    local endpoint="$1"
    local cache_key
    cache_key=$(_gh_cache_key "$endpoint")
    local cache_file="$GH_CACHE_DIR/${cache_key}.json"
    local meta_file="$GH_CACHE_DIR/${cache_key}.meta"

    if [[ ! -f "$cache_file" ]] || [[ ! -f "$meta_file" ]]; then
        return 1
    fi

    # Check TTL
    local cached_at
    cached_at=$(head -1 "$meta_file" 2>/dev/null || echo "0")
    local now
    now=$(date +%s)
    local age=$((now - cached_at))

    if [[ $age -gt $GH_CACHE_TTL ]]; then
        _gh_log_debug "Cache expired for $endpoint (age: ${age}s)"
        return 1
    fi

    _gh_log_debug "Cache hit for $endpoint (age: ${age}s)"
    cat "$cache_file"
    return 0
}

# Get cached response without TTL check (raw)
# Usage: _gh_get_cache_raw <endpoint>
_gh_get_cache_raw() {
    local endpoint="$1"
    local cache_key
    cache_key=$(_gh_cache_key "$endpoint")
    local cache_file="$GH_CACHE_DIR/${cache_key}.json"

    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    fi

    return 1
}
# Save response to cache
# Usage: _gh_set_cache <endpoint> <etag>
# Reads response from stdin
_gh_set_cache() {
    local endpoint="$1"
    local etag="${2:-}"
    local cache_key
    cache_key=$(_gh_cache_key "$endpoint")
    local cache_file="$GH_CACHE_DIR/${cache_key}.json"
    local meta_file="$GH_CACHE_DIR/${cache_key}.meta"

    gh_init_cache

    # Save response
    cat > "$cache_file"

    # Save metadata
    {
        date +%s
        echo "$etag"
    } > "$meta_file"
}

# Get ETag for cached response
_gh_get_etag() {
    local endpoint="$1"
    local cache_key
    cache_key=$(_gh_cache_key "$endpoint")
    local meta_file="$GH_CACHE_DIR/${cache_key}.meta"

    if [[ -f "$meta_file" ]]; then
        sed -n '2p' "$meta_file"
    fi
}

# Make GitHub API request
# Usage: gh_api <endpoint> [--method GET|POST|PATCH|DELETE] [--data <json>] [--no-cache]
# Returns: JSON response on stdout, sets exit code
gh_api() {
    local endpoint=""
    local method="GET"
    local data=""
    local no_cache=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --method|-X)
                method="$2"
                shift 2
                ;;
            --data|-d)
                data="$2"
                shift 2
                ;;
            --post)
                method="POST"
                data="$2"
                shift 2
                ;;
            --no-cache)
                no_cache=true
                shift
                ;;
            -*)
                _gh_log_error "Unknown option: $1"
                return 4
                ;;
            *)
                endpoint="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$endpoint" ]]; then
        _gh_log_error "Usage: gh_api <endpoint>"
        return 4
    fi

    # Reset last response metadata (set by curl path)
    _GH_LAST_HTTP_CODE=""
    _GH_LAST_ETAG=""

    # Check cache for GET requests
    if [[ "$method" == "GET" ]] && ! $no_cache; then
        local cached
        if cached=$(_gh_get_cache "$endpoint"); then
            echo "$cached"
            return 0
        fi
    fi

    # Try gh CLI first, then curl
    local response
    local exit_code
    local retries=0

    while [[ $retries -lt $GH_MAX_RETRIES ]]; do
        if gh_check 2>/dev/null; then
            response=$(_gh_api_with_gh "$endpoint" "$method" "$data")
            exit_code=$?
        else
            gh_check_token || return 3
            response=$(_gh_api_with_curl "$endpoint" "$method" "$data")
            exit_code=$?
        fi

        # Check for rate limit
        if [[ $exit_code -eq 0 ]]; then
            # Handle 304 Not Modified from curl path
            if [[ "$method" == "GET" ]] && ! $no_cache && [[ "${_GH_LAST_HTTP_CODE:-}" == "304" ]]; then
                local cached_raw
                if cached_raw=$(_gh_get_cache_raw "$endpoint"); then
                    echo "$cached_raw"
                    return 0
                fi
            fi

            # Cache GET responses
            if [[ "$method" == "GET" ]] && ! $no_cache; then
                echo "$response" | _gh_set_cache "$endpoint" "${_GH_LAST_ETAG:-}"
            fi
            echo "$response"
            return 0
        elif _gh_is_rate_limited "$response"; then
            ((retries++))
            if [[ $retries -lt $GH_MAX_RETRIES ]]; then
                local wait_time=$((GH_RETRY_DELAY * retries))
                _gh_log_warn "Rate limited. Waiting ${wait_time}s (retry $retries/$GH_MAX_RETRIES)"
                sleep "$wait_time"
            fi
        else
            # Non-rate-limit error
            echo "$response"
            return $exit_code
        fi
    done

    _gh_log_error "Rate limit exceeded after $GH_MAX_RETRIES retries"
    echo "$response"
    return 8
}

# Make API request using gh CLI
_gh_api_with_gh() {
    local endpoint="$1"
    local method="$2"
    local data="$3"

    local gh_args=(api "$endpoint" -X "$method")

    if [[ -n "$data" ]]; then
        gh_args+=(--input -)
        echo "$data" | gh "${gh_args[@]}" 2>/dev/null
    else
        gh "${gh_args[@]}" 2>/dev/null
    fi
}

# Make API request using curl
_gh_api_with_curl() {
    local endpoint="$1"
    local method="$2"
    local data="$3"

    local url="https://api.github.com/$endpoint"
    local curl_args=(
        -s
        -S
        -X "$method"
        -H "Accept: application/vnd.github+json"
        -H "Authorization: Bearer $GITHUB_TOKEN"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )

    # Add ETag if available
    local etag
    etag=$(_gh_get_etag "$endpoint")
    if [[ -n "$etag" ]]; then
        curl_args+=(-H "If-None-Match: $etag")
    fi

    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi

    local raw headers body status_line http_code etag
    local curl_status=0
    raw=$(curl -D - "${curl_args[@]}" "$url") || curl_status=$?
    if [[ $curl_status -ne 0 ]]; then
        _GH_LAST_HTTP_CODE=""
        _GH_LAST_ETAG=""
        return $curl_status
    fi

    if [[ "$raw" == *$'\r\n\r\n'* ]]; then
        headers="${raw%%$'\r\n\r\n'*}"
        body="${raw#*$'\r\n\r\n'}"
    elif [[ "$raw" == *$'\n\n'* ]]; then
        headers="${raw%%$'\n\n'*}"
        body="${raw#*$'\n\n'}"
    else
        headers=""
        body="$raw"
    fi

    status_line=$(printf '%s\n' "$headers" | head -n 1)
    http_code=$(printf '%s\n' "$status_line" | awk '{print $2}')
    etag=$(printf '%s\n' "$headers" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')

    _GH_LAST_HTTP_CODE="${http_code:-}"
    _GH_LAST_ETAG="${etag:-}"

    echo "$body"
    if [[ -n "$http_code" && "$http_code" -ge 400 ]]; then
        return 22
    fi
    return 0
}

# Check if response indicates rate limiting
_gh_is_rate_limited() {
    local response="$1"
    if echo "$response" | grep -qi "rate limit"; then
        return 0
    fi
    if echo "$response" | jq -e '.message | test("rate limit"; "i")' &>/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# ============================================================================
# HIGH-LEVEL API HELPERS
# ============================================================================

# List workflow runs for a repository
# Usage: gh_workflow_runs <owner/repo> [--workflow <name>] [--status <status>] [--limit <n>]
gh_workflow_runs() {
    local repo=""
    local workflow=""
    local status=""
    local limit=20

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workflow|-w)
                workflow="$2"
                shift 2
                ;;
            --status|-s)
                status="$2"
                shift 2
                ;;
            --limit|-l)
                limit="$2"
                shift 2
                ;;
            *)
                repo="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$repo" ]]; then
        _gh_log_error "Usage: gh_workflow_runs <owner/repo>"
        return 4
    fi

    # Validate status parameter (GitHub API enum)
    if [[ -n "$status" ]]; then
        case "$status" in
            queued|in_progress|completed|waiting|requested|pending|action_required|cancelled|failure|neutral|skipped|stale|success|timed_out)
                ;;
            *)
                _gh_log_error "Invalid status: $status"
                return 4
                ;;
        esac
    fi

    # Validate limit is numeric
    if [[ ! "$limit" =~ ^[0-9]+$ ]]; then
        _gh_log_error "Invalid limit: $limit (must be numeric)"
        return 4
    fi

    local endpoint="repos/$repo/actions/runs?per_page=$limit"
    # URL-encode workflow to prevent injection (only allow safe chars)
    if [[ -n "$workflow" ]]; then
        # Validate workflow contains only safe filename characters
        if [[ ! "$workflow" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
            _gh_log_error "Invalid workflow name: $workflow"
            return 4
        fi
        endpoint+="&workflow_file=$workflow"
    fi
    [[ -n "$status" ]] && endpoint+="&status=$status"

    gh_api "$endpoint"
}

# Get a specific workflow run
# Usage: gh_workflow_run <owner/repo> <run_id>
gh_workflow_run() {
    local repo="$1"
    local run_id="$2"

    if [[ -z "$repo" ]] || [[ -z "$run_id" ]]; then
        _gh_log_error "Usage: gh_workflow_run <owner/repo> <run_id>"
        return 4
    fi

    gh_api "repos/$repo/actions/runs/$run_id"
}

# List releases for a repository
# Usage: gh_releases <owner/repo> [--limit <n>]
gh_releases() {
    local repo="$1"
    local limit="${2:-10}"

    if [[ -z "$repo" ]]; then
        _gh_log_error "Usage: gh_releases <owner/repo>"
        return 4
    fi

    gh_api "repos/$repo/releases?per_page=$limit"
}

# Get latest release
# Usage: gh_latest_release <owner/repo>
gh_latest_release() {
    local repo="$1"

    if [[ -z "$repo" ]]; then
        _gh_log_error "Usage: gh_latest_release <owner/repo>"
        return 4
    fi

    gh_api "repos/$repo/releases/latest"
}

# Create a release
# Usage: gh_create_release <owner/repo> <tag> [--name <name>] [--body <body>] [--draft] [--prerelease]
gh_create_release() {
    local repo=""
    local tag=""
    local name=""
    local body=""
    local draft=false
    local prerelease=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)
                name="$2"
                shift 2
                ;;
            --body|-b)
                body="$2"
                shift 2
                ;;
            --draft)
                draft=true
                shift
                ;;
            --prerelease)
                prerelease=true
                shift
                ;;
            *)
                if [[ -z "$repo" ]]; then
                    repo="$1"
                else
                    tag="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$repo" ]] || [[ -z "$tag" ]]; then
        _gh_log_error "Usage: gh_create_release <owner/repo> <tag>"
        return 4
    fi

    [[ -z "$name" ]] && name="$tag"

    local data
    data=$(jq -n \
        --arg tag "$tag" \
        --arg name "$name" \
        --arg body "$body" \
        --argjson draft "$draft" \
        --argjson prerelease "$prerelease" \
        '{tag_name: $tag, name: $name, body: $body, draft: $draft, prerelease: $prerelease}')

    gh_api "repos/$repo/releases" --post "$data"
}

# Upload release asset
# Usage: gh_upload_asset <upload_url> <file_path> [--content-type <type>]
gh_upload_asset() {
    local upload_url="$1"
    local file_path="$2"
    local content_type="${3:-application/octet-stream}"

    if [[ -z "$upload_url" ]] || [[ -z "$file_path" ]]; then
        _gh_log_error "Usage: gh_upload_asset <upload_url> <file_path>"
        return 4
    fi

    if [[ ! -f "$file_path" ]]; then
        _gh_log_error "File not found: $file_path"
        return 4
    fi

    local filename
    filename=$(basename "$file_path")

    # Validate filename contains only safe characters for URL
    # Release assets should only have alphanumeric, dash, underscore, dot
    if [[ ! "$filename" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        _gh_log_error "Invalid filename for upload: $filename (contains unsafe characters)"
        return 4
    fi

    # Remove template part from upload_url
    upload_url="${upload_url%\{*}"
    upload_url+="?name=$filename"

    local token=""
    if command -v secrets_get_gh_token &>/dev/null; then
        token=$(secrets_get_gh_token 2>/dev/null || true)
    fi
    if [[ -z "$token" ]] && gh_check 2>/dev/null; then
        token=$(gh auth token 2>/dev/null || true)
    fi
    [[ -z "$token" ]] && token="${GITHUB_TOKEN:-}"

    if [[ -z "$token" ]]; then
        _gh_log_error "No GitHub token available for asset upload"
        _gh_log_error "Run: gh auth login  OR  export GITHUB_TOKEN=..."
        return 3
    fi

    # Use -w to capture HTTP status, don't use -f so we can capture error response body
    local http_code response
    response=$(curl -sS \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: $content_type" \
        --data-binary "@$file_path" \
        -w "\n__HTTP_CODE__%{http_code}" \
        "$upload_url" 2>&1)

    http_code="${response##*__HTTP_CODE__}"
    response="${response%__HTTP_CODE__*}"

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "$response"
        return 0
    else
        _gh_log_error "Upload failed with HTTP $http_code"
        # Output response for debugging (may contain GitHub error message)
        echo "$response" >&2
        return 7
    fi
}

# Compare two commits/tags
# Usage: gh_compare <owner/repo> <base> <head>
gh_compare() {
    local repo="$1"
    local base="$2"
    local head="$3"

    if [[ -z "$repo" ]] || [[ -z "$base" ]] || [[ -z "$head" ]]; then
        _gh_log_error "Usage: gh_compare <owner/repo> <base> <head>"
        return 4
    fi

    gh_api "repos/$repo/compare/$base...$head"
}

# List tags
# Usage: gh_tags <owner/repo> [--limit <n>]
gh_tags() {
    local repo="$1"
    local limit="${2:-30}"

    if [[ -z "$repo" ]]; then
        _gh_log_error "Usage: gh_tags <owner/repo>"
        return 4
    fi

    gh_api "repos/$repo/tags?per_page=$limit"
}

# Get repository info
# Usage: gh_repo <owner/repo>
gh_repo() {
    local repo="$1"

    if [[ -z "$repo" ]]; then
        _gh_log_error "Usage: gh_repo <owner/repo>"
        return 4
    fi

    gh_api "repos/$repo"
}

# Resolve a tag to a commit SHA via GitHub API
# Usage: gh_resolve_tag_sha <owner/repo> <tag>
# Returns: commit SHA on stdout
gh_resolve_tag_sha() {
    local repo="$1"
    local tag="$2"

    if [[ -z "$repo" || -z "$tag" ]]; then
        _gh_log_error "Usage: gh_resolve_tag_sha <owner/repo> <tag>"
        return 4
    fi

    if ! command -v jq &>/dev/null; then
        _gh_log_error "jq required for tag resolution"
        return 3
    fi

    local ref_json
    ref_json=$(gh_api "repos/$repo/git/ref/tags/$tag" --no-cache 2>/dev/null) || {
        _gh_log_error "Failed to fetch tag ref: $tag"
        return 4
    }

    local obj_sha obj_type
    obj_sha=$(echo "$ref_json" | jq -r '.object.sha // empty' 2>/dev/null)
    obj_type=$(echo "$ref_json" | jq -r '.object.type // empty' 2>/dev/null)

    if [[ -z "$obj_sha" ]]; then
        _gh_log_error "Tag not found: $tag"
        return 4
    fi

    if [[ "$obj_type" == "commit" ]]; then
        echo "$obj_sha"
        return 0
    fi

    if [[ "$obj_type" == "tag" ]]; then
        local tag_json
        tag_json=$(gh_api "repos/$repo/git/tags/$obj_sha" --no-cache 2>/dev/null) || {
            _gh_log_error "Failed to dereference annotated tag: $tag"
            return 4
        }

        local commit_sha
        commit_sha=$(echo "$tag_json" | jq -r '.object.sha // empty' 2>/dev/null)
        if [[ -n "$commit_sha" ]]; then
            echo "$commit_sha"
            return 0
        fi
    fi

    _gh_log_warn "Unknown tag type for $tag (type=$obj_type)"
    echo "$obj_sha"
    return 0
}

# Trigger repository dispatch event
# Usage: gh_repository_dispatch <owner/repo> <event_type> [payload_json]
# Returns: 0 on success, 4 on invalid args, 3 on missing deps
gh_repository_dispatch() {
    local repo="$1"
    local event_type="$2"
    local payload_json="${3:-"{}"}"

    if [[ -z "$repo" || -z "$event_type" ]]; then
        _gh_log_error "Usage: gh_repository_dispatch <owner/repo> <event_type> [payload_json]"
        return 4
    fi

    if ! command -v jq &>/dev/null; then
        _gh_log_error "jq required for dispatch payload"
        return 3
    fi

    if ! echo "$payload_json" | jq -e '.' >/dev/null 2>&1; then
        _gh_log_error "Invalid payload JSON for dispatch"
        return 4
    fi

    local data
    data=$(jq -nc \
        --arg event "$event_type" \
        --argjson payload "$payload_json" \
        '{event_type: $event, client_payload: $payload}')

    local response=""
    local status=0
    response=$(gh_api "repos/$repo/dispatches" --post "$data" --no-cache 2>/dev/null) || status=$?

    if [[ $status -ne 0 ]]; then
        return $status
    fi

    # GitHub returns 204 No Content on success; any body likely indicates error.
    if [[ -n "$response" ]]; then
        local msg=""
        msg=$(echo "$response" | jq -r '.message // empty' 2>/dev/null)
        if [[ -n "$msg" ]]; then
            _gh_log_error "Dispatch failed: $msg"
        else
            _gh_log_error "Dispatch failed: unexpected response"
        fi
        return 7
    fi

    return 0
}

# Clear cache
# Usage: gh_clear_cache [<endpoint>]
gh_clear_cache() {
    local endpoint="${1:-}"

    if [[ -n "$endpoint" ]]; then
        local cache_key
        cache_key=$(_gh_cache_key "$endpoint")
        rm -f "$GH_CACHE_DIR/${cache_key}.json" "$GH_CACHE_DIR/${cache_key}.meta"
        _gh_log_ok "Cleared cache for: $endpoint"
    else
        rm -rf "${GH_CACHE_DIR:?}/"*
        _gh_log_ok "Cleared all GitHub API cache"
    fi
}

# Export functions
export -f gh_init_cache gh_check gh_check_token gh_api
export -f gh_workflow_runs gh_workflow_run gh_releases gh_latest_release
export -f gh_create_release gh_upload_asset gh_compare gh_tags gh_repo
export -f gh_resolve_tag_sha gh_repository_dispatch
export -f gh_clear_cache
