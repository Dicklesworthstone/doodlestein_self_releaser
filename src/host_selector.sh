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

# Host aliases and run IDs are path components, never paths or expressions.
_sel_safe_component() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$ ]]
}

# Read one configuration snapshot. JSON is valid YAML and can be read directly;
# ordinary YAML requires yq. Never silently replace an unreadable/invalid
# configured limit with the default (that can overcommit a build machine).
_sel_hosts_json() {
    local file="${DSR_HOSTS_FILE:-${DSR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsr}/hosts.yaml}"
    local config
    command -v jq &>/dev/null || return 3
    if [[ ! -e "$file" && ! -L "$file" ]]; then
        printf '%s\n' '{"hosts":{}}'
        return 0
    fi
    [[ -f "$file" && -r "$file" && ! -L "$file" ]] || return 4
    if ! config=$(jq -cs 'if length == 1 then .[0] else error("multiple configs") end' "$file" 2>/dev/null); then
        if ! command -v yq &>/dev/null; then
            _sel_log_error "yq is required to read host configuration: $file"
            return 3
        fi
        config=$(yq -o=json -I=0 '.' "$file" 2>/dev/null) || return 4
    fi
    if ! jq -es 'length == 1 and (.[0] | type == "object" and
        (if has("hosts") then (.hosts | type == "object") else true end) and
        ((.hosts // {}) | all(to_entries[];
            (.key | test("^[A-Za-z0-9][A-Za-z0-9._+\\-]{0,199}$") and
                (test("[\u0000-\u001f\u007f]") | not)) and
            (.value | type == "object" and
                (if has("concurrency") then (.concurrency | type == "number" and
                    floor == . and . >= 0 and . <= 1024) else true end) and
                (if has("enabled") then (.enabled | type == "boolean") else true end) and
                (if has("platform") then (.platform | type == "string" and
                    test("^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$") and
                    (test("[\u0000-\u001f\u007f]") | not)) else true end) and
                (if has("connection") then (.connection == "local" or .connection == "ssh") else true end)
            )
        )))' <<< "$config" >/dev/null 2>&1; then
        _sel_log_error "Invalid host configuration: $file"
        return 4
    fi
    jq -c '. + {hosts: (.hosts // {})}' <<< "$config"
}

_sel_limit_from_config() {
    local hostname="$1" config="$2"
    jq -r --arg h "$hostname" --argjson default "$_SELECTOR_DEFAULT_MAX_PARALLEL" '
        if .hosts[$h].enabled == false then 0
        else (.hosts[$h].concurrency // $default) end' <<< "$config"
}

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
    local hostname="${1:-}" config
    _sel_safe_component "$hostname" || return 4
    config=$(_sel_hosts_json) || return $?
    _sel_limit_from_config "$hostname" "$config"
}

# Get current slot usage for a host
# Usage: selector_get_usage <hostname>
# Returns: number of active builds
selector_get_usage() {
    local hostname="${1:-}"
    _sel_safe_component "$hostname" || return 4

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
    limit=$(selector_get_limit "$hostname") || return $?
    usage=$(selector_get_usage "$hostname") || return $?

    [[ "$usage" -lt "$limit" ]]
}

# Acquire a build slot on a host
# Usage: selector_acquire_slot <hostname> <run_id> [--wait]
# Returns: 0 on success, 2 if at capacity
selector_acquire_slot() {
    local hostname="${1:-}"
    local run_id="${2:-$(date +%s)-$$}"
    local wait_mode=false
    _sel_safe_component "$hostname" && _sel_safe_component "$run_id" || return 4
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
            # Fallback: mkdir-based locking (atomic on POSIX systems).
            # Using a DIFFERENT local name (_mkdir_lock) to avoid
            # shadowing the outer selector_acquire_slot's $lock_dir —
            # if a future edit to _try_acquire ever references $lock_dir
            # it will now see the correct per-host path rather than the
            # global lock.
            local _mkdir_lock="$global_lock_file.d"
            local max_wait=30
            local waited=0
            # Treat the lock as stale if it's been held longer than
            # max_wait * 2 — matches flock's implicit release on process
            # death and prevents permanent wedging if a previous holder
            # was SIGKILL'd before reaching the rmdir cleanup below.
            local stale_ceiling=$((max_wait * 2))
            while ! mkdir "$_mkdir_lock" 2>/dev/null; do
                local lock_age=0
                if [[ -d "$_mkdir_lock" ]]; then
                    local lock_mtime
                    lock_mtime=$(stat -c %Y "$_mkdir_lock" 2>/dev/null || stat -f %m "$_mkdir_lock" 2>/dev/null || echo 0)
                    local now
                    now=$(date +%s)
                    lock_age=$((now - lock_mtime))
                fi
                if [[ $lock_age -ge $stale_ceiling ]]; then
                    _sel_log_warn "Clearing stale mkdir lock (age=${lock_age}s): $_mkdir_lock"
                    rmdir "$_mkdir_lock" 2>/dev/null || true
                    continue
                fi
                if [[ $waited -ge $max_wait ]]; then
                    _sel_log_warn "Lock acquisition timeout (flock unavailable, using mkdir fallback)"
                    return 2
                fi
                sleep 1
                waited=$((waited + 1))
            done
            # Ensure the lock is released even if the command SIGTERMs,
            # returns non-zero, or triggers an ERR trap. The trap is
            # RETURN-scoped so it fires when _with_lock returns, which
            # includes the normal path below AND any early return from
            # within the wrapped command via `exit` in the caller.
            # shellcheck disable=SC2064  # expand _mkdir_lock now
            trap "rmdir '$_mkdir_lock' 2>/dev/null; trap - RETURN" RETURN
            "$@"
            local ret=$?
            rmdir "$_mkdir_lock" 2>/dev/null
            trap - RETURN
            return $ret
        fi
    }

    # Helper to attempt acquisition
    _try_acquire() {
        selector_has_capacity "$hostname" || return $?
        printf '%s\n' "$run_id" > "$slot_file" || return 4
        touch "$slot_file" || return 4
    }

    local acquire_status
    if $wait_mode; then
        _sel_log_info "Host $hostname at capacity, waiting..."
        while true; do
            if _with_lock _try_acquire; then
                break
            else
                acquire_status=$?
                [[ $acquire_status -eq 1 ]] || return "$acquire_status"
            fi
            sleep 5 || return 5
        done
    else
        if _with_lock _try_acquire; then
            :
        else
            acquire_status=$?
            [[ $acquire_status -eq 1 ]] || return "$acquire_status"
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
    local hostname="${1:-}"
    local run_id="${2:-}"
    _sel_safe_component "$hostname" && _sel_safe_component "$run_id" || return 4

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
            --target) [[ $# -ge 2 && -n "$2" ]] || return 4; target="$2"; shift 2 ;;
            --capability) [[ $# -ge 2 && -n "$2" ]] || return 4; capability="$2"; shift 2 ;;
            *) _sel_log_error "Unknown selector option: $1"; return 4 ;;
        esac
    done

    local os=""
    if [[ -n "$target" ]]; then
        [[ "$target" =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$ ]] || return 4
        os="${target%/*}"
    fi
    [[ -z "$capability" ]] || _sel_safe_component "$capability" || return 4

    local config
    config=$(_sel_hosts_json) || return $?

    # Get healthy hosts
    local healthy_hosts
    declare -F host_health_get_healthy_hosts &>/dev/null || return 3
    if [[ -n "$capability" ]]; then
        healthy_hosts=$(host_health_get_healthy_hosts --for-capability "$capability" --json) || return $?
    else
        healthy_hosts=$(host_health_get_healthy_hosts --json) || return $?
    fi

    if ! jq -es 'length == 1 and (.[0] | type == "array" and all(.[];
        type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+\\-]{0,199}$") and
        (test("[\u0000-\u001f\u007f]") | not)))' <<< "$healthy_hosts" >/dev/null 2>&1; then
        _sel_log_error "Host health returned an invalid host inventory"
        return 4
    fi

    # Build candidates with scores
    local candidates=()
    while IFS= read -r hostname; do
        [[ -z "$hostname" ]] && continue

        # A stale health cache is not authority to schedule a removed/disabled
        # host. All scheduling fields come from the same config snapshot.
        jq -e --arg h "$hostname" '.hosts | has($h)' <<< "$config" >/dev/null || continue
        local platform="" connection=""
        platform=$(jq -r --arg h "$hostname" '.hosts[$h].platform // ""' <<< "$config") || return 4
        connection=$(jq -r --arg h "$hostname" '.hosts[$h].connection // "ssh"' <<< "$config") || return 4

        # Filter by target platform if specified
        if [[ -n "$os" ]]; then
            local host_os="${platform%/*}"
            if [[ "$host_os" != "$os" ]]; then
                continue
            fi
        fi

        # Calculate score (higher is better)
        local score=100
        local usage limit

        limit=$(_sel_limit_from_config "$hostname" "$config") || return 4
        ((limit > 0)) || continue
        usage=$(selector_get_usage "$hostname") || return $?

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
            }') || return 4
        candidates+=("$candidate")
    done < <(jq -r 'unique[]' <<< "$healthy_hosts")

    # Return sorted by score (descending)
    if [[ ${#candidates[@]} -gt 0 ]]; then
        printf '%s\n' "${candidates[@]}" | jq -s 'sort_by([-.score, .hostname])'
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
            --target) [[ $# -ge 2 && -n "$2" ]] || return 4; target="$2"; shift 2 ;;
            --capability) [[ $# -ge 2 && -n "$2" ]] || return 4; capability="$2"; shift 2 ;;
            --prefer) [[ $# -ge 2 && -n "$2" ]] || return 4; prefer="$2"; shift 2 ;;
            --json) json_mode=true; shift ;;
            *) _sel_log_error "Unknown selector option: $1"; return 4 ;;
        esac
    done
    [[ -z "$prefer" ]] || _sel_safe_component "$prefer" || return 4

    # Get candidates
    local candidates_args=()
    [[ -n "$target" ]] && candidates_args+=(--target "$target")
    [[ -n "$capability" ]] && candidates_args+=(--capability "$capability")

    local candidates
    candidates=$(selector_get_candidates "${candidates_args[@]}") || return $?

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
        # Filter BEFORE taking the first element. The local-host score bonus
        # can otherwise keep an idle remote host behind a completely full one.
        chosen=$(jq -r '[.[] | select(.available > 0)][0].hostname // empty' <<< "$candidates")
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
    [[ $# -eq 0 || ( $# -eq 1 && "$1" == "--json" ) ]] || return 4

    if [[ -z "$_SELECTOR_LOCKS_DIR" ]]; then
        selector_init || return 4
    fi

    local config path
    config=$(_sel_hosts_json) || return $?
    local status=()

    # Include synthetic act-local and removed hosts that still own build slots,
    # not only hosts that currently occur in the configuration.
    local hostnames
    hostnames=$(jq -r '.hosts | keys[]' <<< "$config") || return 4
    for path in "$_SELECTOR_LOCKS_DIR"/*; do
        [[ -e "$path" || -L "$path" ]] || continue
        [[ -d "$path" && ! -L "$path" ]] || return 4
        _sel_safe_component "${path##*/}" || return 4
        hostnames+=$'\n'"${path##*/}"
    done
    hostnames=$(printf '%s\n' "$hostnames" | LC_ALL=C sort -u) || return 4

    while IFS= read -r hostname; do
        [[ -z "$hostname" ]] && continue

        local usage limit available
        usage=$(selector_get_usage "$hostname") || return $?
        limit=$(_sel_limit_from_config "$hostname" "$config") || return 4
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
            }') || return 4
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
