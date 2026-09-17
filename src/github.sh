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
_GH_LAST_RETRY_AFTER=""
_GH_LAST_RATE_REMAINING=""
_GH_LAST_RATE_RESET=""

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

# Resolve a GitHub token using the canonical cascade:
#   1. DSR_GH_TOKEN / GITHUB_TOKEN / GH_TOKEN (via secrets_get_gh_token
#      if that helper is sourced — it centralises the precedence so the
#      gh_upload_asset and gh_upload_asset_named callers below use the
#      same order)
#   2. `gh auth token` if gh CLI is authenticated
#   3. Bare $GITHUB_TOKEN env var
# Emits the resolved token on stdout. Returns 0 with a non-empty token on
# success, 3 on failure.
_gh_resolve_token() {
    local token=""
    if command -v secrets_get_gh_token &>/dev/null; then
        token=$(secrets_get_gh_token 2>/dev/null || true)
    fi
    if [[ -z "$token" ]] && gh_check 2>/dev/null; then
        token=$(gh auth token 2>/dev/null || true)
    fi
    [[ -z "$token" ]] && token="${GITHUB_TOKEN:-}"
    if [[ -z "$token" ]]; then
        return 3
    fi
    printf '%s' "$token"
    return 0
}

# Check if a GitHub token can be resolved from any supported source.
# Previously this only inspected $GITHUB_TOKEN directly, so setups that
# provided the token via DSR_GH_TOKEN or `gh auth login` (as documented
# in secrets.sh) were rejected even though the upload path could have
# used them.
gh_check_token() {
    if ! _gh_resolve_token >/dev/null; then
        _gh_log_error "No GitHub token available (DSR_GH_TOKEN / GITHUB_TOKEN / GH_TOKEN unset and gh CLI not authenticated)"
        _gh_log_info "Either run: gh auth login"
        _gh_log_info "Or set: export DSR_GH_TOKEN=<your-token>"
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
gh_api() (
    local endpoint=""
    local method="GET"
    local data=""
    local no_cache=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --method|-X)
                [[ $# -ge 2 && -n "$2" ]] || return 4
                method="$2"
                shift 2
                ;;
            --data|-d)
                [[ $# -ge 2 ]] || return 4
                data="$2"
                shift 2
                ;;
            --post)
                [[ $# -ge 2 ]] || return 4
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
    local max_attempts="${GH_MAX_RETRIES:-3}" retry_delay="${GH_RETRY_DELAY:-5}"
    if [[ ! "$max_attempts" =~ ^([1-9]|10)$ || ! "$retry_delay" =~ ^[0-9]{1,4}$ ]]; then
        _gh_log_error "Invalid API retry configuration"
        return 4
    fi
    retry_delay=$((10#$retry_delay))
    if ! command -v jq &>/dev/null; then
        _gh_log_error "jq is required for GitHub JSON responses"
        return 3
    fi

    # Reset last response metadata (set by curl path)
    _GH_LAST_HTTP_CODE=""
    _GH_LAST_ETAG=""

    # Check cache for GET requests
    if [[ "$method" == "GET" ]] && ! $no_cache; then
        local cached
        if cached=$(_gh_get_cache "$endpoint") &&
           jq -es 'length == 1' <<< "$cached" >/dev/null 2>&1; then
            echo "$cached"
            return 0
        fi
    fi

    # Try gh CLI first, then curl
    local response="" response_file cleanup_command
    local exit_code using_curl
    local retries=0
    response_file=$(mktemp "${TMPDIR:-/tmp}/dsr-api-response.XXXXXXXX") || return 8
    printf -v cleanup_command 'rm -f -- %q' "$response_file"
    # Freeze the safely quoted local path before the subshell EXIT trap runs.
    # shellcheck disable=SC2064
    trap "$cleanup_command" EXIT
    trap 'exit 5' INT TERM

    while [[ $retries -lt $max_attempts ]]; do
        _GH_LAST_HTTP_CODE=""
        _GH_LAST_ETAG=""
        _GH_LAST_RETRY_AFTER=""
        _GH_LAST_RATE_REMAINING=""
        _GH_LAST_RATE_RESET=""
        # Do not use response=$(transport): that subshell discards HTTP/ETag
        # metadata, turns 304 into empty success, and loses retry classification.
        exit_code=0
        using_curl=false
        if gh_check 2>/dev/null; then
            _gh_api_with_gh "$endpoint" "$method" "$data" "$no_cache" > "$response_file" || exit_code=$?
        else
            gh_check_token || return 3
            using_curl=true
            _gh_api_with_curl "$endpoint" "$method" "$data" "$no_cache" > "$response_file" || exit_code=$?
        fi
        response=$(cat "$response_file") || return 8

        # Check for rate limit
        if [[ $exit_code -eq 0 ]]; then
            # Handle 304 Not Modified from curl path
            if [[ "${_GH_LAST_HTTP_CODE:-}" == "304" ]]; then
                local cached_raw
                if [[ "$method" == "GET" ]] && ! $no_cache &&
                   cached_raw=$(_gh_get_cache_raw "$endpoint") &&
                   jq -es 'length == 1' <<< "$cached_raw" >/dev/null 2>&1; then
                    local etag="${_GH_LAST_ETAG:-}"
                    [[ -n "$etag" ]] || etag=$(_gh_get_etag "$endpoint")
                    printf '%s\n' "$cached_raw" | _gh_set_cache "$endpoint" "$etag"
                    echo "$cached_raw"
                    return 0
                fi
                _gh_log_error "Unexpected 304 without a usable cached response for $endpoint"
                return 8
            fi
            if [[ "$method" == "GET" ]] &&
               ! jq -es 'length == 1' <<< "$response" >/dev/null 2>&1; then
                _gh_log_error "GitHub returned an invalid JSON response for $endpoint"
                return 8
            fi

            # Cache GET responses
            if [[ "$method" == "GET" ]] && ! $no_cache; then
                echo "$response" | _gh_set_cache "$endpoint" "${_GH_LAST_ETAG:-}"
            fi
            echo "$response"
            return 0
        elif _gh_is_rate_limited "$response" ||
             { [[ "$method" == "GET" ]] &&
               { [[ "${_GH_LAST_HTTP_CODE:-}" =~ ^(408|429|5[0-9][0-9])$ ]] ||
                 { $using_curl && [[ -z "${_GH_LAST_HTTP_CODE:-}" && $exit_code -ne 3 ]]; }; }; }; then
            ((retries++))
            if [[ $retries -lt $max_attempts ]]; then
                local rate_limited=false
                if [[ "${_GH_LAST_HTTP_CODE:-}" == "429" ]] || _gh_is_rate_limited "$response"; then
                    rate_limited=true
                fi
                _gh_retry_pause "$retry_delay" "$retries" "$rate_limited" || return $?
            fi
        else
            # Non-rate-limit error
            echo "$response"
            return $exit_code
        fi
    done

    _gh_log_error "API request failed after $max_attempts attempts"
    echo "$response"
    return 8
)

# Download one release asset by immutable GitHub asset ID into an explicit,
# previously absent destination. The response is binary, so it deliberately
# bypasses JSON caching while retaining the adapter's authenticated gh/curl
# transport cascade. A same-directory staging file plus hard link prevents a
# failed transfer from leaving partial destination bytes or clobbering a caller.
gh_download_release_asset() {
    local repo="$1"
    local asset_id="$2"
    local destination="$3"
    local destination_parent staging_dir staged_file token=""
    local status=0 attempt=0
    local max_attempts="$GH_MAX_RETRIES"
    local retry_delay="$GH_RETRY_DELAY"

    if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || \
          ! "$asset_id" =~ ^[1-9][0-9]*$ || -z "$destination" ]]; then
        _gh_log_error "Invalid release asset download arguments"
        return 4
    fi
    destination_parent="${destination%/*}"
    [[ "$destination_parent" == "$destination" ]] && destination_parent="."
    if [[ ! -d "$destination_parent" || -L "$destination_parent" || \
          -e "$destination" || -L "$destination" ]]; then
        _gh_log_error "Release asset destination must be absent in a regular directory: $destination"
        return 4
    fi

    [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || max_attempts=1
    [[ "$retry_delay" =~ ^[0-9]+$ ]] || retry_delay=0

    while ((attempt < max_attempts)); do
        attempt=$((attempt + 1))
        status=0
        staging_dir=$(mktemp -d \
            "$destination_parent/.dsr-asset-download.XXXXXX") || return 4
        staged_file="$staging_dir/asset"

        if gh_check 2>/dev/null; then
            gh api "repos/$repo/releases/assets/$asset_id" \
                -H "Accept: application/octet-stream" \
                -H "Cache-Control: no-cache, no-store, max-age=0" \
                -H "Pragma: no-cache" > "$staged_file" 2>/dev/null || status=$?
        else
            token=$(_gh_resolve_token) || status=$?
            if [[ $status -eq 0 ]]; then
                curl -fLsS \
                    -H "Accept: application/octet-stream" \
                    -H "Authorization: Bearer $token" \
                    -H "X-GitHub-Api-Version: 2022-11-28" \
                    -H "Cache-Control: no-cache, no-store, max-age=0" \
                    -H "Pragma: no-cache" \
                    -o "$staged_file" \
                    "https://api.github.com/repos/$repo/releases/assets/$asset_id" || status=$?
            fi
        fi

        if [[ $status -eq 0 && ( ! -f "$staged_file" || -L "$staged_file" ) ]]; then
            status=1
        fi
        if [[ $status -eq 0 ]]; then
            break
        fi

        rm -f -- "$staged_file"
        rmdir -- "$staging_dir" 2>/dev/null || true
        if ((attempt < max_attempts && retry_delay > 0)); then
            sleep "$retry_delay"
        fi
    done

    if [[ $status -eq 0 ]] && ! ln "$staged_file" "$destination"; then
        status=1
    fi

    rm -f -- "$staged_file"
    rmdir -- "$staging_dir" 2>/dev/null || true
    if [[ $status -eq 0 ]]; then
        return 0
    fi

    _gh_log_error "Failed to download GitHub release asset ID $asset_id after $attempt attempt(s)"
    return "$status"
}

# Fetch and normalize one repository-owned immutable-tag ruleset. Repository
# and ruleset numeric IDs prevent redirects or transfers from being accepted.
# The current history version prevents an edit-and-revert from satisfying an
# older frozen receipt. Missing bypass fields are redaction, not evidence that
# bypass is impossible.
# Usage: gh_get_immutable_tag_ruleset_receipt <owner/repo> <repository-id> <ruleset-id> <tag>
gh_get_immutable_tag_ruleset_receipt() {
    local repo="${1:-}"
    local repository_id="${2:-}"
    local ruleset_id="${3:-}"
    local tag="${4:-}"
    local ruleset_endpoint history_endpoint expected_self
    local repository_json ruleset_before history_list history_version_id
    local history_version ruleset_after receipt

    if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || \
          ! "$repository_id" =~ ^[1-9][0-9]*$ || \
          ! "$ruleset_id" =~ ^[1-9][0-9]*$ || \
          ! "$tag" =~ ^v[A-Za-z0-9._+-]+$ ]]; then
        _gh_log_error "Invalid immutable tag-ruleset arguments"
        return 4
    fi
    if ! command -v jq &>/dev/null; then
        _gh_log_error "jq is required for immutable tag-ruleset verification"
        return 3
    fi

    ruleset_endpoint="repos/$repo/rulesets/$ruleset_id?includes_parents=false"
    history_endpoint="repos/$repo/rulesets/$ruleset_id/history"
    expected_self="https://api.github.com/repos/$repo/rulesets/$ruleset_id"
    repository_json=$(gh_api "repos/$repo" --no-cache 2>/dev/null) || {
        _gh_log_error "Could not bind GitHub repository identity for $repo"
        return 1
    }
    ruleset_before=$(gh_api "$ruleset_endpoint" --no-cache 2>/dev/null) || {
        _gh_log_error "Could not fetch immutable tag ruleset $ruleset_id for $repo"
        return 1
    }
    history_list=$(gh_api "$history_endpoint?per_page=100&page=1" \
        --no-cache 2>/dev/null) || {
        _gh_log_error "Could not fetch immutable tag-ruleset history"
        return 1
    }
    history_version_id=$(jq -er '
        if type == "array" and length > 0 and
           (.[0].version_id | type == "number" and floor == . and . > 0)
        then .[0].version_id
        else error("missing current ruleset history version")
        end
    ' <<< "$history_list" 2>/dev/null) || {
        _gh_log_error "GitHub returned no unambiguous current tag-ruleset history version"
        return 1
    }
    history_version=$(gh_api "$history_endpoint/$history_version_id" \
        --no-cache 2>/dev/null) || {
        _gh_log_error "Could not fetch current immutable tag-ruleset history state"
        return 1
    }
    ruleset_after=$(gh_api "$ruleset_endpoint" --no-cache 2>/dev/null) || {
        _gh_log_error "Could not re-fetch immutable tag ruleset $ruleset_id for $repo"
        return 1
    }

    if ! receipt=$(jq -nceS \
        --arg repo "$repo" \
        --arg tag "$tag" \
        --argjson repository_id "$repository_id" \
        --argjson ruleset_id "$ruleset_id" \
        --argjson history_version_id "$history_version_id" \
        --arg expected_self "$expected_self" \
        --argjson repository "$repository_json" \
        --argjson before "$ruleset_before" \
        --argjson history_list "$history_list" \
        --argjson history "$history_version" \
        --argjson after "$ruleset_after" '
        def timestamp:
            type == "string" and
            test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$");
        def nonempty_string:
            type == "string" and length > 0;
        def policy:
            {
                id,
                name,
                source,
                source_type,
                target,
                enforcement,
                bypass_actors,
                conditions: {
                    ref_name: {
                        include: (.conditions.ref_name.include | sort),
                        exclude: (.conditions.ref_name.exclude | sort)
                    }
                },
                rules: (.rules | sort_by(.type))
            };
        def live_policy:
            policy + {current_user_can_bypass};
        def valid_policy:
            type == "object" and
            .id == $ruleset_id and
            .source == $repo and
            .source_type == "Repository" and
            .target == "tag" and
            .enforcement == "active" and
            .bypass_actors == [] and
            (.conditions | type) == "object" and
            (.conditions.ref_name | type) == "object" and
            (.conditions.ref_name.include | type) == "array" and
            ((.conditions.ref_name.include | sort) == ["refs/tags/v*"]) and
            .conditions.ref_name.exclude == [] and
            (.rules | type) == "array" and
            all(.rules[]; type == "object" and (.type | type == "string")) and
            (([.rules[].type] | unique | length) == (.rules | length)) and
            (([.rules[] | select(.type == "update")] | length) == 1) and
            (([.rules[] | select(.type == "deletion")] | length) == 1);
        def valid_live_policy:
            valid_policy and .current_user_can_bypass == "never";
        def direct_identity:
            {
                node_id,
                created_at,
                updated_at,
                self: ._links.self.href,
                policy: live_policy
            };

        if ($repository | type) != "object" or
           $repository.id != $repository_id or
           $repository.full_name != $repo or
           (($repository.node_id | nonempty_string) | not) or
           (($before | valid_live_policy) | not) or
           (($after | valid_live_policy) | not) or
           (($before.node_id | nonempty_string) | not) or
           (($before.created_at | timestamp) | not) or
           (($before.updated_at | timestamp) | not) or
           $before._links.self.href != $expected_self or
           (($before | direct_identity) != ($after | direct_identity)) or
           ($history_list | type) != "array" or
           ($history_list | length) == 0 or
           (($history_list | map(.version_id) | unique | length) != ($history_list | length)) or
           $history_list[0].version_id != $history_version_id or
           (($history_list[0].updated_at | timestamp) | not) or
           ($history | type) != "object" or
           $history.version_id != $history_version_id or
           $history.updated_at != $history_list[0].updated_at or
           (($history.state | valid_policy) | not) or
           (($history.state | policy) != ($before | policy))
        then error("ruleset does not prove immutable release tags")
        else {
            schema: "dsr.github_tag_ruleset_receipt.v1",
            tag: $tag,
            repository: {
                id: $repository.id,
                node_id: $repository.node_id,
                full_name: $repository.full_name
            },
            ruleset: {
                node_id: $before.node_id,
                created_at: $before.created_at,
                updated_at: $before.updated_at,
                self: $before._links.self.href,
                history: {
                    version_id: $history.version_id,
                    updated_at: $history.updated_at
                },
                policy: ($before | live_policy)
            }
        }
        end
    ' 2>/dev/null); then
        _gh_log_error "GitHub ruleset $ruleset_id does not prove immutable refs/tags/v* for $repo"
        return 1
    fi

    printf '%s\n' "$receipt"
}

# Make API request using gh CLI
_gh_api_with_gh() {
    local endpoint="$1"
    local method="$2"
    local data="$3"
    local no_cache="${4:-false}"

    local gh_args=(api "$endpoint" -X "$method")
    if $no_cache; then
        gh_args+=(
            -H "Cache-Control: no-cache, no-store, max-age=0"
            -H "Pragma: no-cache"
        )
    fi

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
    local no_cache="${4:-false}"

    local url="https://api.github.com/$endpoint"
    # Resolve via the shared cascade so DSR_GH_TOKEN and `gh auth token`
    # work on this path too, not just bare $GITHUB_TOKEN. The callers
    # have already been gated through gh_check_token, so an empty result
    # here means the token was revoked mid-run — bail out instead of
    # sending "Authorization: Bearer " (which 401s with a confusing body).
    local gh_token
    if ! gh_token=$(_gh_resolve_token); then
        _GH_LAST_HTTP_CODE=""
        _GH_LAST_ETAG=""
        return 3
    fi
    local curl_args=(
        -s
        -S
        --connect-timeout 15
        --max-time 60
        -X "$method"
        -H "Accept: application/vnd.github+json"
        -H "Authorization: Bearer $gh_token"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )
    if $no_cache; then
        curl_args+=(
            -H "Cache-Control: no-cache, no-store, max-age=0"
            -H "Pragma: no-cache"
        )
    fi

    # Add ETag if available
    local etag=""
    if [[ "$method" == "GET" ]] && ! $no_cache; then
        etag=$(_gh_get_etag "$endpoint")
        if [[ -n "$etag" ]]; then
            curl_args+=(-H "If-None-Match: $etag")
        fi
    fi

    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi

    local raw headers body status_line http_code etag
    local curl_status=0
    # Preserve trailing header separators on body-less 204/304 responses.
    # Command substitution otherwise strips the final newline in CRLFCRLF.
    raw=$(curl -D - "${curl_args[@]}" "$url"; curl_status=$?; printf '\034'; exit "$curl_status") || curl_status=$?
    raw="${raw%$'\034'}"
    if [[ $curl_status -ne 0 ]]; then
        _GH_LAST_HTTP_CODE=""
        _GH_LAST_ETAG=""
        return $curl_status
    fi

    # curl -D - may include a proxy CONNECT response and interim 1xx
    # responses. Only the final header block describes the JSON body.
    body="$raw"
    http_code=""
    while [[ "$body" == HTTP/* ]]; do
        if [[ "$body" == *$'\r\n\r\n'* ]]; then
            headers="${body%%$'\r\n\r\n'*}"
            body="${body#*$'\r\n\r\n'}"
        elif [[ "$body" == *$'\n\n'* ]]; then
            headers="${body%%$'\n\n'*}"
            body="${body#*$'\n\n'}"
        else
            _gh_log_error "Incomplete GitHub HTTP response"
            return 8
        fi
        status_line="${headers%%$'\n'*}"
        if [[ ! "$status_line" =~ ^HTTP/[0-9.]+[[:space:]]([1-5][0-9][0-9])([[:space:]]|$) ]]; then
            _gh_log_error "Invalid GitHub HTTP status line"
            return 8
        fi
        http_code="${BASH_REMATCH[1]}"
        etag=$(_gh_response_header etag "$headers")
    done
    if [[ -z "$http_code" || "$http_code" == 1* ||
          "$status_line" == *"Connection established"* ]]; then
        _gh_log_error "Missing final GitHub HTTP response"
        return 8
    fi

    _GH_LAST_HTTP_CODE="${http_code:-}"
    _GH_LAST_ETAG="${etag:-}"
    _GH_LAST_RETRY_AFTER=$(_gh_response_header retry-after "$headers")
    _GH_LAST_RATE_REMAINING=$(_gh_response_header x-ratelimit-remaining "$headers")
    _GH_LAST_RATE_RESET=$(_gh_response_header x-ratelimit-reset "$headers")

    echo "$body"
    [[ "$http_code" == 2* || "$http_code" == "304" ]] && return 0
    return 22
}

# Read the last occurrence of a response header, accepting case and optional
# whitespace variations. Called only on headers, never the JSON body.
_gh_response_header() {
    printf '%s\n' "$2" | awk -v wanted="$1" '
        index($0, ":") > 0 && tolower(substr($0, 1, index($0, ":") - 1)) == wanted {
            sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t\r]+$/, ""); value=$0
        }
        END {if (value != "") print value}
    '
}

# Honor GitHub backoff before another request, including reconciliation GETs.
# Long server cooldowns return NETWORK_ERROR rather than sleeping indefinitely
# or retrying early. GH_MAX_RETRY_WAIT (seconds, default 300) bounds the pause.
_gh_retry_pause() {
    local base="$1" attempt="$2" rate_limited="${3:-false}"
    local ceiling="${GH_MAX_RETRY_WAIT:-300}" floor=0 now
    [[ "$ceiling" =~ ^[0-9]{1,5}$ ]] || return 4
    ceiling=$((10#$ceiling))
    local wait_time=$((base * (1 << (attempt - 1))))
    if [[ -n "${_GH_LAST_RETRY_AFTER:-}" ]]; then
        [[ "$_GH_LAST_RETRY_AFTER" =~ ^[0-9]{1,9}$ ]] || {
            _gh_log_error "Unusable Retry-After header; refusing an early retry"
            return 8
        }
        floor=$((10#$_GH_LAST_RETRY_AFTER))
    elif [[ "${_GH_LAST_RATE_REMAINING:-}" == "0" ]]; then
        [[ "${_GH_LAST_RATE_RESET:-}" =~ ^[0-9]{1,12}$ ]] || return 8
        now=$(date +%s) || return 8
        floor=$((10#$_GH_LAST_RATE_RESET - now))
        ((floor > 0)) || floor=0
    elif $rate_limited; then
        floor=$((60 * (1 << (attempt - 1))))
    fi
    ((wait_time >= floor)) || wait_time="$floor"
    if ((wait_time > ceiling)); then
        _gh_log_warn "GitHub retry requires ${wait_time}s; exceeds GH_MAX_RETRY_WAIT=${ceiling}s"
        return 8
    fi
    _gh_log_warn "Retrying after ${wait_time}s (attempt $attempt)"
    sleep "$wait_time" || return 5
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
            queued|in_progress|completed)
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

    local endpoint=""
    if [[ -n "$workflow" ]]; then
        # Validate workflow contains only safe filename characters
        if [[ ! "$workflow" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
            _gh_log_error "Invalid workflow name: $workflow"
            return 4
        fi
        endpoint="repos/$repo/actions/workflows/$workflow/runs?per_page=$limit"
    else
        endpoint="repos/$repo/actions/runs?per_page=$limit"
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
    local target_commitish=""

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
            --target-commitish)
                target_commitish="$2"
                shift 2
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
        --arg target_commitish "$target_commitish" \
        '{tag_name: $tag, name: $name, body: $body, draft: $draft, prerelease: $prerelease}
         + if $target_commitish == "" then {} else {target_commitish: $target_commitish} end')

    gh_api "repos/$repo/releases" --post "$data"
}

# Upload under the local filename. Named and unnamed uploads share the same
# content-verified retry path; stdout contains exactly one GitHub asset object.
# Usage: gh_upload_asset <upload_url> <file_path> [content_type]
gh_upload_asset() {
    local upload_url="${1:-}"
    local file_path="${2:-}"
    local content_type="${3:-application/octet-stream}"
    gh_upload_asset_named "$upload_url" "$file_path" "${file_path##*/}" "$content_type"
}

# Hash file contents rather than hash-tool filename output (paths may contain
# spaces or backslashes). Both Linux and macOS have a supported implementation.
_gh_asset_sha256() {
    local hash
    if command -v sha256sum &>/dev/null; then
        hash=$(sha256sum < "$1") || return 4
    elif command -v shasum &>/dev/null; then
        hash=$(shasum -a 256 < "$1") || return 4
    else
        _gh_log_error "sha256sum or shasum is required for verified asset uploads"
        return 3
    fi
    hash="${hash%% *}"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 4
    printf '%s\n' "$hash"
}

# Search the complete, uncached release inventory, not the truncated embedded
# .assets array. Return 0 + one asset, 1 for absence, 7 for ambiguity, 8 for an
# unavailable/incomplete inventory. Never interpret a failed GET as absence.
_gh_find_release_asset() {
    local repo="$1" release_id="$2" name="$3"
    local page=1 response matches count found=""
    while ((page <= 100)); do
        if ! response=$(gh_api "repos/$repo/releases/$release_id/assets?per_page=100&page=$page" --no-cache); then
            _gh_log_error "Cannot read release asset inventory for $repo/$release_id"
            return 8
        fi
        if ! jq -es 'length == 1 and (.[0] | type == "array" and length <= 100 and
            all(.[]; type == "object" and (.name | type == "string") and
                (.id | type == "number" and floor == . and . > 0 and . <= 9007199254740991)))' \
            <<< "$response" >/dev/null 2>&1; then
            _gh_log_error "Invalid release asset inventory for $repo/$release_id"
            return 8
        fi
        matches=$(jq -c --arg name "$name" '[.[] | select(.name == $name)]' <<< "$response") || return 8
        count=$(jq -r 'length' <<< "$matches") || return 8
        if ((count > 1)) || { ((count == 1)) && [[ -n "$found" ]]; }; then
            _gh_log_error "Ambiguous release asset name: $name"
            return 7
        fi
        if ((count == 1)); then
            found=$(jq -c '.[0]' <<< "$matches") || return 8
        fi
        count=$(jq -r 'length' <<< "$response") || return 8
        if ((count < 100)); then
            [[ -n "$found" ]] || return 1
            printf '%s\n' "$found"
            return 0
        fi
        page=$((page + 1))
    done
    _gh_log_error "Release inventory exceeded the 100-page safety limit"
    return 8
}

# An HTTP success, matching name, or matching size alone is NOT upload proof.
# Older GitHub assets can lack a digest: read their bytes by immutable asset ID
# and hash those, rather than accepting name/size or following an untrusted URL.
_gh_verify_uploaded_asset() {
    local repo="$1" name="$2" size="$3" sha="$4" asset="$5" workdir="$6"
    local asset_id digest downloaded_sha downloaded_size
    if ! jq -es --arg name "$name" --argjson size "$size" '
        length == 1 and (.[0] | type == "object" and
        .name == $name and .state == "uploaded" and .size == $size and
        (.id | type == "number" and floor == . and . > 0 and . <= 9007199254740991))
    ' <<< "$asset" >/dev/null 2>&1; then
        _gh_log_error "Asset receipt does not match the complete upload: $name"
        return 7
    fi
    digest=$(jq -r 'if .digest == null then "" else .digest end' <<< "$asset") || return 7
    if [[ -n "$digest" ]]; then
        if [[ "$digest" != "sha256:$sha" ]]; then
            _gh_log_error "Release asset SHA256 mismatch: $name (existing bytes left untouched)"
            return 7
        fi
    else
        asset_id=$(jq -r '.id' <<< "$asset") || return 7
        if ! gh_download_release_asset "$repo" "$asset_id" "$workdir/verified"; then
            _gh_log_error "Cannot verify digest-less release asset: $name"
            return 8
        fi
        downloaded_sha=$(_gh_asset_sha256 "$workdir/verified") || return $?
        downloaded_size=$(wc -c < "$workdir/verified") || return 4
        downloaded_size="${downloaded_size//[[:space:]]/}"
        if [[ "$downloaded_sha" != "$sha" || "$downloaded_size" != "$size" ]]; then
            _gh_log_error "Downloaded release asset differs from upload source: $name"
            return 7
        fi
    fi
    jq -c '.' <<< "$asset"
}

# Upload a frozen file snapshot, or reuse an identical complete remote asset.
# On an ambiguous POST failure, reconcile by name AND content before retrying.
# No remote assets are deleted or replaced, including incomplete starter assets.
# GH_MAX_RETRIES bounds POST attempts (1..10); GH_UPLOAD_TIMEOUT bounds each
# POST in seconds (default 900). A subshell scopes cleanup/signal traps locally.
gh_upload_asset_named() (
    local upload_url="${1:-}" file_path="${2:-}" upload_name="${3:-}"
    local content_type="${4:-application/octet-stream}"
    local max_attempts="${GH_MAX_RETRIES:-3}" retry_delay="${GH_RETRY_DELAY:-5}"
    local timeout="${GH_UPLOAD_TIMEOUT:-900}"
    local repo release_id token workdir sha snapshot_sha size asset response
    local attempt=0 status http_code curl_status retryable headers paused rate_limited

    # Accept only GitHub's documented upload endpoint and optional URI template.
    # In particular, do not forward a token to arbitrary hosts or follow redirects.
    upload_url="${upload_url%\{\?name,label\}}"
    if [[ ! "$upload_url" =~ ^https://uploads\.github\.com/repos/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/releases/([1-9][0-9]*)/assets$ ]]; then
        _gh_log_error "Invalid GitHub release upload URL"
        return 4
    fi
    repo="${BASH_REMATCH[1]}" release_id="${BASH_REMATCH[2]}"
    if [[ ! "$upload_name" =~ ^[A-Za-z0-9._+-]+$ || "$upload_name" == "." || "$upload_name" == ".." ||
          ! -f "$file_path" || -L "$file_path" || ! -s "$file_path" ||
          "$content_type" == *$'\r'* || "$content_type" == *$'\n'* ]]; then
        _gh_log_error "Upload requires a safe name and a nonempty regular file: $upload_name"
        return 4
    fi
    if [[ ! "$max_attempts" =~ ^([1-9]|10)$ || ! "$retry_delay" =~ ^[0-9]{1,4}$ ||
          ! "$timeout" =~ ^[1-9][0-9]{0,5}$ ]]; then
        _gh_log_error "Invalid upload retry/timeout configuration"
        return 4
    fi
    retry_delay=$((10#$retry_delay))
    if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
        _gh_log_error "curl and jq are required for verified asset uploads"
        return 3
    fi
    token=$(_gh_resolve_token) || {
        _gh_log_error "No GitHub token available for asset upload"
        return 3
    }
    sha=$(_gh_asset_sha256 "$file_path") || return $?
    umask 077
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/dsr-asset-upload.XXXXXXXX") || return 4
    # A direct function return can pop locals before the subshell EXIT trap.
    # Freeze safely quoted paths now; do not look up workdir during cleanup.
    local cleanup_command
    printf -v cleanup_command 'rm -f -- %q %q %q %q; rmdir -- %q 2>/dev/null || true' \
        "$workdir/payload" "$workdir/response" "$workdir/verified" "$workdir/headers" "$workdir"
    # shellcheck disable=SC2064
    trap "$cleanup_command" EXIT
    trap 'exit 5' INT TERM
    cp -- "$file_path" "$workdir/payload" || return 4
    snapshot_sha=$(_gh_asset_sha256 "$workdir/payload") || return $?
    if [[ "$snapshot_sha" != "$sha" || -L "$file_path" ]] ||
       [[ "$(_gh_asset_sha256 "$file_path")" != "$sha" ]]; then
        _gh_log_error "Upload source changed while being staged: $upload_name"
        return 4
    fi
    chmod 400 "$workdir/payload" || return 4
    size=$(wc -c < "$workdir/payload") || return 4
    size="${size//[[:space:]]/}"
    upload_url+="?name=${upload_name//+/%2B}"

    while ((attempt < max_attempts)); do
        status=0
        asset=$(_gh_find_release_asset "$repo" "$release_id" "$upload_name") || status=$?
        if ((status == 0)); then
            _gh_log_info "Verifying existing release asset: $upload_name"
            _gh_verify_uploaded_asset "$repo" "$upload_name" "$size" "$sha" "$asset" "$workdir"
            return $?
        elif ((status != 1)); then
            return "$status"
        fi

        attempt=$((attempt + 1))
        curl_status=0
        : > "$workdir/response" || return 4
        : > "$workdir/headers" || return 4
        http_code=$(curl -sS --connect-timeout 15 --max-time "$timeout" \
            -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $token" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "Content-Type: $content_type" \
            --data-binary "@$workdir/payload" \
            -D "$workdir/headers" -o "$workdir/response" -w '%{http_code}' \
            "$upload_url") || curl_status=$?
        response=$(cat "$workdir/response" 2>/dev/null) || response=""
        headers=$(cat "$workdir/headers") || return 8
        _GH_LAST_RETRY_AFTER=$(_gh_response_header retry-after "$headers")
        _GH_LAST_RATE_REMAINING=$(_gh_response_header x-ratelimit-remaining "$headers")
        _GH_LAST_RATE_RESET=$(_gh_response_header x-ratelimit-reset "$headers")
        if ((curl_status == 0)) && [[ "$http_code" == "201" ]]; then
            _gh_verify_uploaded_asset "$repo" "$upload_name" "$size" "$sha" "$response" "$workdir"
            return $?
        fi

        retryable=false paused=false rate_limited=false
        if [[ "$http_code" == "429" ]] ||
           { [[ "$http_code" == "403" ]] && _gh_is_rate_limited "$response"; }; then
            rate_limited=true
        fi
        if ((curl_status != 0)) || [[ "$http_code" =~ ^(408|429|5[0-9][0-9])$ ]]; then
            retryable=true
        elif [[ "$http_code" == "403" ]] && _gh_is_rate_limited "$response"; then
            retryable=true
        elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
            _gh_log_error "GitHub rejected upload authorization for $upload_name"
            return 3
        elif [[ "$http_code" != "422" ]]; then
            _gh_log_error "Upload failed for $upload_name (HTTP ${http_code:-unknown}, curl $curl_status)"
            return 7
        fi

        # A rate-limit response applies to reads too: do not immediately send
        # a reconciliation GET while GitHub explicitly asks us to back off.
        if $rate_limited || [[ -n "$_GH_LAST_RETRY_AFTER" || "$_GH_LAST_RATE_REMAINING" == "0" ]]; then
            _gh_retry_pause "$retry_delay" "$attempt" "$rate_limited" || return $?
            paused=true
        fi

        # The server may have stored all bytes before the connection failed.
        # A 422 can likewise mean another publisher won the name race. Only
        # identical uploaded bytes count as recovery; a starter/conflict fails.
        status=0
        asset=$(_gh_find_release_asset "$repo" "$release_id" "$upload_name") || status=$?
        if ((status == 0)); then
            _gh_log_info "Reconciling upload response failure: $upload_name"
            _gh_verify_uploaded_asset "$repo" "$upload_name" "$size" "$sha" "$asset" "$workdir"
            return $?
        elif ((status != 1)); then
            return "$status"
        fi
        if ! $retryable; then
            _gh_log_error "GitHub rejected asset $upload_name without a matching remote upload"
            return 7
        fi
        if ((attempt < max_attempts)) && ! $paused; then
            _gh_retry_pause "$retry_delay" "$attempt" false || return $?
        fi
    done
    _gh_log_error "Asset upload exhausted $max_attempts attempt(s): $upload_name"
    return 8
)

# Upload release asset with dual naming for install.sh compatibility (bd-1tv.3)
# Usage: gh_upload_asset_dual <upload_url> <file_path> <tool> <version> <os> <arch> <ext> [repo_path]
# Returns: JSON with upload results for both names
gh_upload_asset_dual() {
    local upload_url="$1"
    local file_path="$2"
    local tool="$3"
    local version="$4"
    local os="$5"
    local arch="$6"
    local ext="${7:-tar.gz}"
    local repo_path="${8:-}"

    if [[ -z "$upload_url" ]] || [[ -z "$file_path" ]]; then
        _gh_log_error "Usage: gh_upload_asset_dual <upload_url> <file_path> <tool> <version> <os> <arch>"
        return 4
    fi

    if [[ ! -f "$file_path" ]]; then
        _gh_log_error "File not found: $file_path"
        return 4
    fi

    if ! command -v jq &>/dev/null; then
        _gh_log_error "jq required for dual-name upload"
        return 3
    fi

    # Generate dual names using artifact_naming module
    local names_json
    if command -v artifact_naming_generate_dual_for_tool &>/dev/null; then
        names_json=$(artifact_naming_generate_dual_for_tool "$tool" "$version" "$os" "$arch" "$ext" "$repo_path")
    else
        # Fallback: generate default names
        local version_stripped="${version#v}"
        names_json=$(jq -nc \
            --arg versioned "${tool}-${version_stripped}-${os}-${arch}.${ext}" \
            --arg compat "${tool}-${os}-${arch}.${ext}" \
            '{versioned: $versioned, compat: $compat, same: ($versioned == $compat)}')
    fi

    local versioned_name compat_name same_names
    versioned_name=$(echo "$names_json" | jq -r '.versioned')
    compat_name=$(echo "$names_json" | jq -r '.compat')
    same_names=$(echo "$names_json" | jq -r '.same // false')

    # Ensure same_names is a valid JSON boolean for --argjson
    [[ "$same_names" != "true" && "$same_names" != "false" ]] && same_names="false"

    local content_type="application/octet-stream"
    case "$ext" in
        tar.gz|tgz) content_type="application/gzip" ;;
        tar.xz) content_type="application/x-xz" ;;
        zip) content_type="application/zip" ;;
    esac

    local versioned_result="failed" compat_result="skipped"
    local versioned_error="" compat_error=""

    # Upload with versioned name
    _gh_log_info "Uploading: $versioned_name"
    if gh_upload_asset_named "$upload_url" "$file_path" "$versioned_name" "$content_type" >/dev/null; then
        versioned_result="uploaded"
        _gh_log_ok "  Uploaded: $versioned_name"
    else
        versioned_error="Upload failed for $versioned_name"
        _gh_log_error "  $versioned_error"
    fi

    # Upload with compat name (if different)
    if [[ "$same_names" != "true" && "$versioned_result" == "uploaded" ]]; then
        _gh_log_info "Uploading compat name: $compat_name"
        if gh_upload_asset_named "$upload_url" "$file_path" "$compat_name" "$content_type" >/dev/null; then
            compat_result="uploaded"
            _gh_log_ok "  Uploaded: $compat_name"
        else
            compat_result="failed"
            compat_error="Upload failed for $compat_name"
            _gh_log_error "  $compat_error"
        fi
    elif [[ "$same_names" == "true" ]]; then
        compat_result="same_as_versioned"
    fi

    # Build result JSON
    jq -nc \
        --arg versioned_name "$versioned_name" \
        --arg versioned_result "$versioned_result" \
        --arg versioned_error "$versioned_error" \
        --arg compat_name "$compat_name" \
        --arg compat_result "$compat_result" \
        --arg compat_error "$compat_error" \
        --argjson same "$same_names" \
        '{
            versioned: {name: $versioned_name, status: $versioned_result, error: $versioned_error},
            compat: {name: $compat_name, status: $compat_result, error: $compat_error},
            same_names: $same
        }'

    if [[ "$versioned_result" != "uploaded" ]]; then
        return 7
    fi
    if [[ "$compat_result" == "failed" ]]; then
        return 1
    fi
    return 0
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

    if [[ ! "$obj_sha" =~ ^[0-9a-f]{40}$ ]]; then
        _gh_log_error "Tag not found: $tag"
        return 4
    fi

    local depth=0
    while [[ $depth -lt 8 ]]; do
        case "$obj_type" in
            commit)
                printf '%s\n' "$obj_sha"
                return 0
                ;;
            tag)
                local tag_json
                tag_json=$(gh_api "repos/$repo/git/tags/$obj_sha" --no-cache 2>/dev/null) || {
                    _gh_log_error "Failed to dereference annotated tag: $tag"
                    return 4
                }
                obj_sha=$(echo "$tag_json" | jq -r '.object.sha // empty' 2>/dev/null)
                obj_type=$(echo "$tag_json" | jq -r '.object.type // empty' 2>/dev/null)
                if [[ ! "$obj_sha" =~ ^[0-9a-f]{40}$ ]]; then
                    _gh_log_error "Annotated tag $tag does not reference a 40-hex object"
                    return 4
                fi
                ;;
            *)
                _gh_log_error "Tag $tag resolved to unsupported object type: $obj_type"
                return 4
                ;;
        esac
        depth=$((depth + 1))
    done

    _gh_log_error "Annotated tag chain is too deep for $tag"
    return 4
}

# Trigger repository dispatch event
# Usage: gh_repository_dispatch <owner/repo> <event_type> [payload_json]
# Returns: 0 on success, 4 on invalid args, 3 on missing deps
gh_repository_dispatch() {
    local repo="$1"
    local event_type="$2"
    local payload_json="${3:-"{}"}"

    if [[ -z "$repo" || -z "$event_type" ]]; then
        _gh_log_error "Usage: gh_repository_dispatch <owner/repo> <event_type>"
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
export -f gh_init_cache gh_check gh_check_token _gh_resolve_token gh_api
export -f gh_download_release_asset
export -f gh_get_immutable_tag_ruleset_receipt
export -f gh_workflow_runs gh_workflow_run gh_releases gh_latest_release
export -f gh_create_release gh_upload_asset gh_upload_asset_named gh_upload_asset_dual
export -f gh_compare gh_tags gh_repo
export -f gh_resolve_tag_sha gh_repository_dispatch
export -f gh_clear_cache
