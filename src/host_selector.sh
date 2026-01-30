#!/usr/bin/env bash
# host_selector.sh - Host selection and concurrency management for dsr
#
# Provides:
#   - Deterministic host selection based on health + capability
#   - Per-host concurrency limits
#   - Build queue management
#   - JSON output for scheduling decisions
#
# Usage:
#   source host_selector.sh
#   selector_init
#   host=$(selector_choose_host --target linux/amd64 --capability rust)
#   selector_acquire_slot <hostname>
#   selector_release_slot <hostname>

set -uo pipefail

# State directory for concurrency tracking
_SELECTOR_STATE_DIR=""
_SELECTOR_LOCKS_DIR=""

# Default concurrency limits
_SELECTOR_DEFAULT_MAX_PARALLEL=2

# Colors for output
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _SEL_GREEN=$'\033[0;32m'
    _SEL_RED=$'\033[0;31m'
    _SEL_YELLOW=$'\033[0;33m'
    _SEL_BLUE=$'\033[0;34m'
    _SEL_NC=$'\033[0m'
else
    _SEL_GREEN='' _SEL_RED='' _SEL_YELLOW='' _SEL_BLUE='' _SEL_NC=''
fi

_sel_log_info()  { echo "${_SEL_BLUE}[selector]${_SEL_NC} $*" >&2; }
_sel_log_ok()    { echo "${_SEL_GREEN}[selector]${_SEL_NC} $*" >&2; }
_sel_log_warn()  { echo "${_SEL_YELLOW}[selector]${_SEL_NC} $*" >&2; }
_sel_log_error() { echo "${_SEL_RED}[selector]${_SEL_NC} $*" >&2; }

# Initialize selector state
# Usage: selector_init
selector_init() {
    local state_dir="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}"
    _SELECTOR_STATE_DIR="$state_dir/selector"
    _SELECTOR_LOCKS_DIR="$_SELECTOR_STATE_DIR/locks"

    mkdir -p "$_SELECTOR_LOCKS_DIR"
}

# Get concurrency limit for a host
# Usage: selector_get_limit <hostname>
# Returns: max parallel builds for host
selector_get_limit() {
    local hostname="$1"
    local hosts_file="${DSR_HOSTS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml}"

    if [[ ! -f "$hosts_file" ]] || ! command -v yq &>/dev/null; then
        echo "$_SELECTOR_DEFAULT_MAX_PARALLEL"
        return 0
    fi

    local limit
    limit=$(yq -r ".hosts.${hostname}.concurrency // $_SELECTOR_DEFAULT_MAX_PARALLEL" "$hosts_file" 2>/dev/null)
    echo "${limit:-$_SELECTOR_DEFAULT_MAX_PARALLEL}"
}

# Get current slot usage for a host
# Usage: selector_get_usage <hostname>
# Returns: number of active builds
selector_get_usage() {
    local hostname="$1"

    [[ -z "$_SELECTOR_LOCKS_DIR" ]] && selector_init

    local lock_dir="$_SELECTOR_LOCKS_DIR/$hostname"
    if [[ ! -d "$lock_dir" ]]; then
        echo "0"
        return 0
    fi

    # Count active locks (not stale)
    local count=0
    local now
    now=$(date +%s)
    local stale_threshold=3600  # 1 hour

    # Use nullglob to handle no matches gracefully
    local lock_files
    lock_files=$(find "$lock_dir" -maxdepth 1 -name '*.lock' -type f 2>/dev/null || true)

    while IFS= read -r lock_file; do
        [[ -z "$lock_file" || ! -f "$lock_file" ]] && continue

        local lock_time
        lock_time=$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %m "$lock_file" 2>/dev/null || echo 0)
        local age=$((now - lock_time))

        if [[ $age -lt $stale_threshold ]]; then
            ((count++))
        else
            # Remove stale lock
            rm -f "$lock_file" 2>/dev/null
        fi
    done <<< "$lock_files"

    echo "$count"
}

# Check if host has available capacity
# Usage: selector_has_capacity <hostname>
# Returns: 0 if has capacity, 1 if at limit
selector_has_capacity() {
    local hostname="$1"

    local limit usage
    limit=$(selector_get_limit "$hostname")
    usage=$(selector_get_usage "$hostname")

    [[ "$usage" -lt "$limit" ]]
}

# Acquire a build slot on a host
# Usage: selector_acquire_slot <hostname> <run_id> [--wait]
# Returns: 0 on success, 2 if at capacity
selector_acquire_slot() {
    local hostname="$1"
    local run_id="${2:-$(date +%s)-$$}"
    local wait_mode=false
    [[ "${3:-}" == "--wait" ]] && wait_mode=true

    [[ -z "$_SELECTOR_LOCKS_DIR" ]] && selector_init

    local lock_dir="$_SELECTOR_LOCKS_DIR/$hostname"
    mkdir -p "$lock_dir"

    local slot_file="$lock_dir/${run_id}.lock"
    local global_lock_file="$_SELECTOR_STATE_DIR/selector.lock"
    
    # Helper to run in critical section
    _with_lock() {
        if command -v flock &>/dev/null; then
            (
                flock -x 200
                "$@"
            ) 200>"$global_lock_file"
        else
            "$@"
        fi
    }

    # Helper to attempt acquisition
    _try_acquire() {
        if selector_has_capacity "$hostname"; then
            echo "$run_id" > "$slot_file"
            touch "$slot_file"
            return 0
        else
            return 1
        fi
    }

    if $wait_mode; then
        _sel_log_info "Host $hostname at capacity, waiting..."
        while true; do
            if _with_lock _try_acquire; then
                break
            fi
            sleep 5
        done
    else
        if ! _with_lock _try_acquire; then
            local limit usage
            limit=$(selector_get_limit "$hostname")
            usage=$(selector_get_usage "$hostname")
            _sel_log_warn "Host $hostname at capacity ($usage/$limit)"
            return 2
        fi
    fi

    local usage
    usage=$(selector_get_usage "$hostname")
    local limit
    limit=$(selector_get_limit "$hostname")
    _sel_log_ok "Acquired slot on $hostname ($usage/$limit)"

    return 0
}

# Release a build slot on a host
# Usage: selector_release_slot <hostname> <run_id>
selector_release_slot() {
    local hostname="$1"
    local run_id="$2"

    [[ -z "$_SELECTOR_LOCKS_DIR" ]] && selector_init

    local lock_file="$_SELECTOR_LOCKS_DIR/$hostname/${run_id}.lock"

    if [[ -f "$lock_file" ]]; then
        rm -f "$lock_file"
        _sel_log_info "Released slot on $hostname"
    fi
}

# Get hosts that can build a target
# Usage: selector_get_candidates --target <os/arch> [--capability <cap>]
# Returns: JSON array of candidate hosts with scores
selector_get_candidates() {
    local target=""
    local capability=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) target="$2"; shift 2 ;;
            --capability) capability="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local os=""
    if [[ -n "$target" ]]; then
        os="${target%/*}"
    fi

    # Get healthy hosts
    local healthy_hosts
    if [[ -n "$capability" ]]; then
        healthy_hosts=$(host_health_get_healthy_hosts --for-capability "$capability" --json 2>/dev/null)
    else
        healthy_hosts=$(host_health_get_healthy_hosts --json 2>/dev/null)
    fi

    if [[ -z "$healthy_hosts" || "$healthy_hosts" == "[]" || "$healthy_hosts" == "null" ]]; then
        echo "[]"
        return 0
    fi

    # Get hosts config for platform filtering
    local hosts_file="${DSR_HOSTS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml}"

    # Build candidates with scores
    local candidates=()
    while IFS= read -r hostname; do
        [[ -z "$hostname" ]] && continue

        # Get host info
        local platform="" connection=""
        if [[ -f "$hosts_file" ]] && command -v yq &>/dev/null; then
            platform=$(yq -r ".hosts.${hostname}.platform // \"\"" "$hosts_file" 2>/dev/null)
            connection=$(yq -r ".hosts.${hostname}.connection // \"ssh\"" "$hosts_file" 2>/dev/null)
        fi

        # Filter by target platform if specified
        if [[ -n "$os" && -n "$platform" ]]; then
            local host_os="${platform%/*}"
            if [[ "$host_os" != "$os" ]]; then
                continue
            fi
        fi

        # Calculate score (higher is better)
        local score=100
        local usage limit

        usage=$(selector_get_usage "$hostname")
        limit=$(selector_get_limit "$hostname")

        # Prefer hosts with more available capacity
        local available=$((limit - usage))
        score=$((score + available * 10))

        # Prefer local hosts (lower latency)
        if [[ "$connection" == "local" ]]; then
            score=$((score + 20))
        fi

        # Add to candidates
        local candidate
        candidate=$(jq -nc \
            --arg hostname "$hostname" \
            --arg platform "$platform" \
            --arg connection "$connection" \
            --argjson usage "$usage" \
            --argjson limit "$limit" \
            --argjson available "$available" \
            --argjson score "$score" \
            '{
                hostname: $hostname,
                platform: $platform,
                connection: $connection,
                usage: $usage,
                limit: $limit,
                available: $available,
                score: $score
            }')
        candidates+=("$candidate")
    done < <(echo "$healthy_hosts" | jq -r '.[]')

    # Return sorted by score (descending)
    if [[ ${#candidates[@]} -gt 0 ]]; then
        printf '%s\n' "${candidates[@]}" | jq -s 'sort_by(-.score)'
    else
        echo "[]"
    fi
}

# Choose the best host for a build
# Usage: selector_choose_host --target <os/arch> [--capability <cap>] [--prefer <hostname>]
# Returns: hostname on stdout, JSON rationale to stderr in verbose mode
selector_choose_host() {
    local target=""
    local capability=""
    local prefer=""
    local json_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) target="$2"; shift 2 ;;
            --capability) capability="$2"; shift 2 ;;
            --prefer) prefer="$2"; shift 2 ;;
            --json) json_mode=true; shift ;;
            *) shift ;;
        esac
    done

    # Get candidates
    local candidates_args=()
    [[ -n "$target" ]] && candidates_args+=(--target "$target")
    [[ -n "$capability" ]] && candidates_args+=(--capability "$capability")

    local candidates
    candidates=$(selector_get_candidates "${candidates_args[@]}")

    if [[ -z "$candidates" || "$candidates" == "[]" || "$candidates" == "null" ]]; then
        _sel_log_error "No suitable hosts found for target=$target capability=$capability"
        return 1
    fi

    local chosen=""
    local reason=""

    # Check for preferred host first
    if [[ -n "$prefer" ]]; then
        local preferred_available
        preferred_available=$(echo "$candidates" | jq -r --arg h "$prefer" \
            '.[] | select(.hostname == $h) | select(.available > 0) | .hostname')
        if [[ -n "$preferred_available" ]]; then
            chosen="$prefer"
            reason="preferred host available"
        fi
    fi

    # Otherwise pick highest score with capacity
    if [[ -z "$chosen" ]]; then
        chosen=$(echo "$candidates" | jq -r '.[0] | select(.available > 0) | .hostname')
        reason="highest score with capacity"
    fi

    # Fallback: any host even if at capacity (caller must wait)
    if [[ -z "$chosen" ]]; then
        chosen=$(echo "$candidates" | jq -r '.[0].hostname')
        reason="best available (at capacity)"
    fi

    if [[ -z "$chosen" || "$chosen" == "null" ]]; then
        _sel_log_error "No hosts available"
        return 1
    fi

    if $json_mode; then
        local selection
        selection=$(jq -nc \
            --arg hostname "$chosen" \
            --arg target "$target" \
            --arg capability "$capability" \
            --arg reason "$reason" \
            --argjson candidates "$candidates" \
            '{
                selected: $hostname,
                target: $target,
                capability: $capability,
                reason: $reason,
                candidates: $candidates
            }')
        echo "$selection"
    else
        echo "$chosen"
    fi
}

# Get queue status for all hosts
# Usage: selector_queue_status [--json]
# Returns: JSON object with per-host usage
selector_queue_status() {
    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    [[ -z "$_SELECTOR_LOCKS_DIR" ]] && selector_init

    local hosts_file="${DSR_HOSTS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml}"
    local status=()

    # Get all configured hosts
    local hostnames
    if [[ -f "$hosts_file" ]] && command -v yq &>/dev/null; then
        hostnames=$(yq -r '.hosts | keys | .[]' "$hosts_file" 2>/dev/null)
    else
        # Fall back to lock directories
        hostnames=$(ls "$_SELECTOR_LOCKS_DIR" 2>/dev/null || echo "")
    fi

    while IFS= read -r hostname; do
        [[ -z "$hostname" ]] && continue

        local usage limit available
        usage=$(selector_get_usage "$hostname")
        limit=$(selector_get_limit "$hostname")
        available=$((limit - usage))

        local entry
        entry=$(jq -nc \
            --arg hostname "$hostname" \
            --argjson usage "$usage" \
            --argjson limit "$limit" \
            --argjson available "$available" \
            '{
                hostname: $hostname,
                usage: $usage,
                limit: $limit,
                available: $available,
                at_capacity: ($available <= 0)
            }')
        status+=("$entry")
    done <<< "$hostnames"

    if [[ ${#status[@]} -gt 0 ]]; then
        printf '%s\n' "${status[@]}" | jq -s '.'
    else
        echo "[]"
    fi
}

# Export functions
export -f selector_init selector_get_limit selector_get_usage selector_has_capacity
export -f selector_acquire_slot selector_release_slot
export -f selector_get_candidates selector_choose_host selector_queue_status
