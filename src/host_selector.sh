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
    [[ ! -L "$state_dir" ]] || return 4
    mkdir -p -- "$state_dir" || return 4
    state_dir=$(cd "$state_dir" && pwd -P) || return 4
    _SELECTOR_STATE_DIR="$state_dir/selector"
    _SELECTOR_LOCKS_DIR="$_SELECTOR_STATE_DIR/locks"
    local directory
    for directory in "$_SELECTOR_STATE_DIR" "$_SELECTOR_LOCKS_DIR" "$_SELECTOR_STATE_DIR/mutexes"; do
        [[ ! -L "$directory" ]] || return 4
        (umask 077; mkdir -p -- "$directory") || return 4
        [[ -d "$directory" && ! -L "$directory" ]] || return 4
    done
}

_sel_prepare_host() {
    _sel_safe_component "$1" || return 4
    selector_init || return $?
    local directory="$_SELECTOR_LOCKS_DIR/$1"
    [[ ! -L "$directory" ]] || return 4
    (umask 077; mkdir -p -- "$directory") || return 4
    [[ -d "$directory" && ! -L "$directory" ]] || return 4
}

# Pin one mutex implementation per state directory. Otherwise two invocations
# with different PATHs could use independent flock/mkdir locks concurrently.
_sel_lock_backend() (
    local marker="$_SELECTOR_STATE_DIR/lock-backend" temporary backend
    if [[ ! -e "$marker" && ! -L "$marker" ]]; then
        backend=mkdir
        if command -v flock &>/dev/null; then backend=flock; fi
        temporary=$(mktemp "$_SELECTOR_STATE_DIR/.backend.XXXXXXXX") || return 4
        local cleanup
        printf -v cleanup 'rm -f -- %q' "$temporary"
        # shellcheck disable=SC2064
        trap "$cleanup" EXIT
        printf '%s\n' "$backend" > "$temporary" || return 4
        # A competing initializer can publish first; read the winning marker.
        ln -- "$temporary" "$marker" 2>/dev/null || { [[ -f "$marker" ]] || return 4; }
    fi
    [[ -f "$marker" && ! -L "$marker" ]] || return 4
    backend=$(cat -- "$marker") || return 4
    case "$backend" in
        flock) command -v flock &>/dev/null || return 3 ;;
        mkdir) ;;
        *) return 4 ;;
    esac
    printf '%s\n' "$backend"
)

# All ledger readers/writers use the same per-host mutex. The fallback is
# deliberately NOT stolen by age: a paused process can still own an old lock.
# A SIGKILL during a mkdir critical section requires operator inspection of
# that guard; ordinary errors/INT/TERM release it via a subshell-scoped trap.
_sel_with_lock() (
    local hostname="$1" budget="$2" backend guard status started cleanup
    shift 2
    [[ "$budget" =~ ^[0-9]{1,5}$ ]] || return 4
    budget=$((10#$budget))
    backend=$(_sel_lock_backend) || return $?
    guard="$_SELECTOR_STATE_DIR/mutexes/$hostname"
    if [[ "$backend" == flock ]]; then
        [[ ! -L "$guard" && ( ! -e "$guard" || -f "$guard" ) ]] || return 4
        # Append-open acquires a descriptor without truncating an existing file.
        umask 077
        exec 9>> "$guard" || return 4
        if flock -x -w "$budget" 9; then :; else
            status=$?
            [[ $status -eq 1 ]] && return 2
            return 4
        fi
    else
        guard+=".d"
        started=$SECONDS
        while ! (umask 077; mkdir -- "$guard") 2>/dev/null; do
            [[ -d "$guard" && ! -L "$guard" ]] || return 4
            if ((SECONDS - started >= budget)); then
                _sel_log_warn "Host mutex busy; inspect abandoned guards rather than stealing them: $guard"
                return 2
            fi
            sleep 0.1 || return 5
        done
        printf -v cleanup 'rmdir -- %q 2>/dev/null || true' "$guard"
        # shellcheck disable=SC2064
        trap "$cleanup" EXIT
    fi
    trap 'exit 5' HUP INT TERM
    "$@"
)

_sel_boot_id() {
    local boot
    if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        IFS= read -r boot < /proc/sys/kernel/random/boot_id || return 3
    else
        boot=$(LC_ALL=C sysctl -n kern.boottime 2>/dev/null) || return 3
    fi
    [[ -n "$boot" && "$boot" != *[[:cntrl:]]* ]] || return 3
    printf '%s\n' "$boot"
}

# Return 1 only for a known dead/zombie process, 3/4 for an unavailable probe.
# Pair the PID with its start identity to avoid reclaiming a live long build
# or treating a recycled PID as the worker that originally acquired the slot.
_sel_process_start() {
    local pid="$1" info state
    [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]] || return 4
    if [[ -d /proc/self ]]; then
        if ! IFS= read -r info 2>/dev/null < "/proc/$pid/stat"; then
            [[ -d "/proc/$pid" ]] && return 4
            return 1
        fi
        local -a fields=()
        read -r -a fields <<< "${info##*) }"
        [[ ${#fields[@]} -ge 20 && "${fields[19]}" =~ ^[0-9]+$ ]] || return 4
        case "${fields[0]}" in Z|X) return 1 ;; esac
        printf 'proc:%s\n' "${fields[19]}"
    else
        command -v ps &>/dev/null || return 3
        info=$(LC_ALL=C ps -p "$pid" -o lstart= -o stat= 2>/dev/null) || return 1
        info="${info%"${info##*[![:space:]]}"}"
        [[ -n "$info" ]] || return 1
        state="${info##* }"
        case "$state" in Z*|X*) return 1 ;; esac
        info="${info%"$state"}"
        info="${info#"${info%%[![:space:]]*}"}"
        info="${info%"${info##*[![:space:]]}"}"
        [[ -n "$info" ]] || return 4
        printf 'ps:%s\n' "$info"
    fi
}

_sel_slot_record() {
    local path="$1" hostname="$2" run_id="$3"
    [[ -f "$path" && ! -L "$path" ]] || return 4
    jq -ces --arg host "$hostname" --arg run "$run_id" '
        if length == 1 and (.[0] | type == "object" and .schema == 1 and
            .host == $host and .run_id == $run and
            (.pid | type == "number" and floor == . and . > 0 and . <= 2147483647) and
            all(.node, .boot, .start; type == "string" and length > 0 and
                (test("[\u0000-\u001f\u007f]") | not)))
        then .[0] else error("unrecognized slot owner") end' "$path" 2>/dev/null
}

_sel_owner_live() {
    local record="$1" node="$2" boot="$3" pid start observed owner_node owner_boot status=0
    # State is controller-local. Never reclaim another controller's evidence.
    owner_node=$(jq -r '.node' <<< "$record") || return 0
    owner_boot=$(jq -r '.boot' <<< "$record") || return 0
    [[ "$owner_node" == "$node" ]] || return 0
    [[ "$owner_boot" == "$boot" ]] || return 1
    pid=$(jq -r '.pid' <<< "$record") || return 0
    start=$(jq -r '.start' <<< "$record") || return 0
    observed=$(_sel_process_start "$pid") || status=$?
    [[ $status -eq 1 ]] && return 1
    [[ $status -eq 0 ]] || return 0  # probe unavailable: keep capacity reserved
    [[ "$observed" == "$start" ]]
}

# Caller holds the host mutex. Reads are non-destructive; only an acquisition
# reaps provably dead records. Unknown/old-format files reserve capacity until
# inspected, rather than being expired merely because an hour has elapsed.
_sel_usage_locked() {
    local hostname="$1" reap="${2:-false}" path record node boot count=0
    node=$(uname -n) || return 3
    boot=$(_sel_boot_id) || return $?
    for path in "$_SELECTOR_LOCKS_DIR/$hostname/"*.lock; do
        [[ -e "$path" || -L "$path" ]] || continue
        [[ -f "$path" && ! -L "$path" ]] || return 4
        local run_id="${path##*/}"
        run_id="${run_id%.lock}"
        if record=$(_sel_slot_record "$path" "$hostname" "$run_id") &&
           ! _sel_owner_live "$record" "$node" "$boot"; then
            if [[ "$reap" == true ]]; then
                rm -f -- "$path" || return 4
                _sel_log_info "Reclaimed dead worker slot on $hostname: $run_id"
            fi
        else
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
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
    _sel_prepare_host "$hostname" || return $?
    _sel_with_lock "$hostname" "${DSR_SELECTOR_LOCK_TIMEOUT:-30}" _sel_usage_locked "$hostname"
}

# Check if host has available capacity
# Usage: selector_has_capacity <hostname>
# Returns: 0 if has capacity, 1 if at limit
selector_has_capacity() {
    local hostname="${1:-}"

    local limit usage
    limit=$(selector_get_limit "$hostname") || return $?
    usage=$(selector_get_usage "$hostname") || return $?

    [[ "$usage" -lt "$limit" ]]
}

# Acquire a build slot on a host
# Usage: selector_acquire_slot <hostname> <run_id> [--wait]
# DSR_SELECTOR_WAIT_TIMEOUT bounds --wait (default 300s); mutex waits are
# separately bounded by DSR_SELECTOR_LOCK_TIMEOUT (default 30s).
# Returns: 0 acquired/idempotent, 2 busy/deadline, 3 dependency, 4 invalid, 5 interrupted.
selector_acquire_slot() {
    local hostname="${1:-}"
    local owner_pid="$BASHPID"
    local run_id="${2:-$(date +%s)-$owner_pid}"
    local wait_mode=false
    _sel_safe_component "$hostname" && _sel_safe_component "$run_id" || return 4
    [[ $# -le 3 && ( $# -lt 3 || "$3" == --wait ) ]] || return 4
    [[ "${3:-}" == "--wait" ]] && wait_mode=true
    local wait_budget="${DSR_SELECTOR_WAIT_TIMEOUT:-300}" lock_budget="${DSR_SELECTOR_LOCK_TIMEOUT:-30}"
    [[ "$wait_budget" =~ ^[0-9]{1,5}$ && "$lock_budget" =~ ^[0-9]{1,5}$ ]] || return 4
    wait_budget=$((10#$wait_budget)) lock_budget=$((10#$lock_budget))
    local node boot start record status started=$SECONDS remaining budget limit
    _sel_prepare_host "$hostname" || return $?
    node=$(uname -n) || return 3
    boot=$(_sel_boot_id) || return $?
    start=$(_sel_process_start "$owner_pid") || return 3
    record=$(jq -nc --arg host "$hostname" --arg run "$run_id" --arg node "$node" \
        --arg boot "$boot" --arg start "$start" --argjson pid "$owner_pid" \
        '{schema:1,host:$host,run_id:$run,pid:$pid,node:$node,boot:$boot,start:$start}') || return 4
    while true; do
        budget=$lock_budget
        if $wait_mode; then
            remaining=$((wait_budget - (SECONDS - started)))
            ((remaining >= 0)) || remaining=0
            ((budget <= remaining)) || budget=$remaining
        fi
        if _sel_with_lock "$hostname" "$budget" _sel_try_acquire "$hostname" "$run_id" "$record"; then
            _sel_log_ok "Acquired slot on $hostname: $run_id"
            return 0
        else
            status=$?
            [[ $status -eq 2 ]] || return "$status"
        fi
        limit=$(selector_get_limit "$hostname") || return $?
        if ! $wait_mode || ((limit == 0 || SECONDS - started >= wait_budget)); then
            _sel_log_warn "No build slot available on $hostname (capacity/ownership/deadline)"
            return 2
        fi
        sleep 0.1 || return 5
    done
}

_sel_try_acquire() {
    local hostname="$1" run_id="$2" record="$3" existing usage limit
    local slot="$_SELECTOR_LOCKS_DIR/$hostname/$run_id.lock"
    limit=$(selector_get_limit "$hostname") || return $?
    usage=$(_sel_usage_locked "$hostname" true) || return $?
    if [[ -e "$slot" || -L "$slot" ]]; then
        existing=$(_sel_slot_record "$slot" "$hostname" "$run_id") || return 2
        jq -e --argjson owner "$record" '. == $owner' <<< "$existing" >/dev/null && return 0
        return 2  # another process cannot share a run ID or release its slot
    fi
    ((usage < limit)) || return 2
    _sel_publish_slot "$slot" "$record"
}

_sel_publish_slot() (
    local slot="$1" record="$2" temporary cleanup
    temporary=$(mktemp "${slot%/*}/.slot.XXXXXXXX") || return 4
    printf -v cleanup 'rm -f -- %q' "$temporary"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    printf '%s\n' "$record" > "$temporary" || return 4
    # Publish complete bytes with no-clobber semantics, never truncate a peer.
    ln -- "$temporary" "$slot" || return 4
)

# Release a build slot on a host
# Usage: selector_release_slot <hostname> <run_id>
selector_release_slot() {
    local hostname="${1:-}"
    local run_id="${2:-}"
    _sel_safe_component "$hostname" && _sel_safe_component "$run_id" || return 4
    local owner_pid="$BASHPID" node boot start
    _sel_prepare_host "$hostname" || return $?
    node=$(uname -n) || return 3
    boot=$(_sel_boot_id) || return $?
    start=$(_sel_process_start "$owner_pid") || return 3
    _sel_with_lock "$hostname" "${DSR_SELECTOR_LOCK_TIMEOUT:-30}" \
        _sel_release_owned "$hostname" "$run_id" "$owner_pid" "$node" "$boot" "$start"
}

_sel_release_owned() {
    local hostname="$1" run_id="$2" pid="$3" node="$4" boot="$5" start="$6" record
    local slot="$_SELECTOR_LOCKS_DIR/$hostname/$run_id.lock"
    [[ -e "$slot" || -L "$slot" ]] || return 0
    record=$(_sel_slot_record "$slot" "$hostname" "$run_id") || return 4
    jq -e --argjson pid "$pid" --arg node "$node" --arg boot "$boot" --arg start "$start" \
        '.pid == $pid and .node == $node and .boot == $boot and .start == $start' \
        <<< "$record" >/dev/null || return 2
    rm -f -- "$slot" || return 4
    _sel_log_info "Released slot on $hostname: $run_id"
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
