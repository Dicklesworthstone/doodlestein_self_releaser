#!/usr/bin/env bash
# host_health.sh - Pre-build host health checking for dsr
#
# Usage:
#   source host_health.sh
#   host_health_check <hostname>        # Check specific host
#   host_health_check_all               # Check all configured hosts
#   host_health_get_healthy_hosts       # Get list of healthy hosts
#
# Checks performed:
#   - SSH connectivity (short timeout + BatchMode for remote hosts)
#   - Disk space threshold
#   - Toolchain availability (rust/go/bun per host capabilities)
#   - Docker/Colima availability (for act runners)
#   - Clock drift detection (optional warning)
#
# Output:
#   - JSON summary to stdout (when --json)
#   - Human-readable to stderr
#   - Cache results for 5 minutes

set -uo pipefail

# Dependencies check
[[ -n "${SCRIPT_DIR:-}" ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source config if not already loaded
if ! declare -p DSR_CONFIG &>/dev/null 2>&1; then
    source "$SCRIPT_DIR/src/config.sh"
fi

# Fallback host parsing when yq is unavailable
# Usage: _hh_parse_host_fallback <hostname>
# Returns: simplified JSON with host config
_hh_parse_host_fallback() {
    local hostname="$1"
    local hosts_file="${DSR_HOSTS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml}"

    if [[ ! -f "$hosts_file" ]]; then
        return 1
    fi

    # Simple state-machine parser for YAML host entries
    local in_hosts=false
    local in_target=false
    local in_capabilities=false
    local platform="" connection="" ssh_host="" description="" concurrency="1"
    local capabilities=""
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Track section entry
        if [[ "$line" =~ ^hosts: ]]; then
            in_hosts=true
            continue
        fi

        # Skip if not in hosts section
        $in_hosts || continue

        # Check for our target host (2-space indent)
        if [[ "$line" =~ ^[[:space:]][[:space:]]${hostname}: ]]; then
            in_target=true
            continue
        fi

        # If in target, check for next host (exit target)
        if $in_target && [[ "$line" =~ ^[[:space:]][[:space:]][a-zA-Z_][a-zA-Z0-9_]*: ]] && [[ ! "$line" =~ ^[[:space:]][[:space:]]${hostname}: ]]; then
            # Another host definition at same level - we're done
            break
        fi

        # Exit hosts section on non-indented line (except comments/blank)
        if [[ "$line" =~ ^[a-zA-Z] ]]; then
            in_hosts=false
            continue
        fi

        # Parse attributes if in target host
        if $in_target; then
            # Check for capabilities list
            if [[ "$line" =~ ^[[:space:]]+capabilities: ]]; then
                in_capabilities=true
                continue
            fi

            # Parse capability items
            if $in_capabilities; then
                if [[ "$line" =~ ^[[:space:]]+-[[:space:]]*([a-zA-Z0-9_]+) ]]; then
                    capabilities+="${BASH_REMATCH[1]} "
                    continue
                elif [[ "$line" =~ ^[[:space:]]+[a-zA-Z] ]]; then
                    in_capabilities=false
                fi
            fi

            # Parse simple key: value pairs (4-space indent)
            if [[ "$line" =~ ^[[:space:]]+platform:[[:space:]]*(.+)$ ]]; then
                platform="${BASH_REMATCH[1]}"
                platform="${platform%\"}"
                platform="${platform#\"}"
            elif [[ "$line" =~ ^[[:space:]]+connection:[[:space:]]*(.+)$ ]]; then
                connection="${BASH_REMATCH[1]}"
                connection="${connection%\"}"
                connection="${connection#\"}"
            elif [[ "$line" =~ ^[[:space:]]+ssh_host:[[:space:]]*(.+)$ ]]; then
                ssh_host="${BASH_REMATCH[1]}"
                ssh_host="${ssh_host%\"}"
                ssh_host="${ssh_host#\"}"
            elif [[ "$line" =~ ^[[:space:]]+description:[[:space:]]*(.+)$ ]]; then
                description="${BASH_REMATCH[1]}"
                description="${description%\"}"
                description="${description#\"}"
            elif [[ "$line" =~ ^[[:space:]]+concurrency:[[:space:]]*([0-9]+) ]]; then
                concurrency="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$hosts_file"

    # If we found the host, return JSON
    if [[ -n "$platform" || -n "$connection" ]]; then
        capabilities="${capabilities% }"  # trim trailing space
        jq -nc \
            --arg platform "$platform" \
            --arg connection "${connection:-ssh}" \
            --arg ssh_host "${ssh_host:-$hostname}" \
            --arg description "$description" \
            --argjson concurrency "$concurrency" \
            --arg capabilities "$capabilities" \
            '{
                platform: $platform,
                connection: $connection,
                ssh_host: $ssh_host,
                description: $description,
                concurrency: $concurrency,
                capabilities: $capabilities
            }'
        return 0
    fi

    return 1
}

# List hosts using fallback parsing
_hh_list_hosts_fallback() {
    local hosts_file="${DSR_HOSTS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml}"

    if [[ ! -f "$hosts_file" ]]; then
        return 1
    fi

    local in_hosts=false
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^hosts: ]]; then
            in_hosts=true
            continue
        fi

        $in_hosts || continue

        # Exit hosts section
        if [[ "$line" =~ ^[a-zA-Z] ]]; then
            break
        fi

        # Host name at 2-space indent
        if [[ "$line" =~ ^[[:space:]][[:space:]]([a-zA-Z_][a-zA-Z0-9_]*): ]]; then
            echo "${BASH_REMATCH[1]}"
        fi
    done < "$hosts_file"
}

# Get host config with yq fallback
_hh_get_host_config() {
    local hostname="$1"

    # Try yq first
    if command -v yq &>/dev/null; then
        local result
        result=$(config_get_host "$hostname" 2>/dev/null)
        if [[ -n "$result" && "$result" != "null" ]]; then
            echo "$result"
            return 0
        fi
    fi

    # Fallback to simple parser
    _hh_parse_host_fallback "$hostname"
}

# List hosts with yq fallback
_hh_list_hosts() {
    # Try yq first
    if command -v yq &>/dev/null; then
        local result
        result=$(config_list_hosts 2>/dev/null)
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    fi

    # Fallback to simple parser
    _hh_list_hosts_fallback
}

# Health check cache directory and TTL
_HH_CACHE_DIR="${DSR_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/dsr}/health"
_HH_CACHE_TTL=300  # 5 minutes

# Thresholds
_HH_DISK_WARN_THRESHOLD=90   # Warn if disk usage > 90%
_HH_DISK_ERROR_THRESHOLD=95  # Error if disk usage > 95%
_HH_CLOCK_DRIFT_WARN=30      # Warn if clock drift > 30 seconds
_HH_SSH_TIMEOUT=10           # SSH connect timeout (seconds)
_HH_CMD_TIMEOUT=30           # Command execution timeout (seconds)

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _HH_RED=$'\033[0;31m'
    _HH_GREEN=$'\033[0;32m'
    _HH_YELLOW=$'\033[0;33m'
    _HH_BLUE=$'\033[0;34m'
    _HH_NC=$'\033[0m'
else
    _HH_RED='' _HH_GREEN='' _HH_YELLOW='' _HH_BLUE='' _HH_NC=''
fi

_hh_log_info()  { echo "${_HH_BLUE}[health]${_HH_NC} $*" >&2; }
_hh_log_ok()    { echo "${_HH_GREEN}[health]${_HH_NC} $*" >&2; }
_hh_log_warn()  { echo "${_HH_YELLOW}[health]${_HH_NC} $*" >&2; }
_hh_log_error() { echo "${_HH_RED}[health]${_HH_NC} $*" >&2; }

# Initialize cache directory
_hh_init_cache() {
    mkdir -p "$_HH_CACHE_DIR"
}

# Get cache file path for a host
_hh_cache_file() {
    local hostname="$1"
    echo "$_HH_CACHE_DIR/${hostname}.json"
}

# Check if cache is valid (exists and not expired)
_hh_cache_valid() {
    local hostname="$1"
    local cache_file
    cache_file=$(_hh_cache_file "$hostname")

    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi

    local cache_age file_mtime now
    now=$(date +%s)
    if [[ "$(uname)" == "Darwin" ]]; then
        file_mtime=$(stat -f %m "$cache_file")
    else
        file_mtime=$(stat -c %Y "$cache_file")
    fi
    cache_age=$((now - file_mtime))

    [[ $cache_age -lt $_HH_CACHE_TTL ]]
}

# Read cached result
_hh_cache_read() {
    local hostname="$1"
    local cache_file
    cache_file=$(_hh_cache_file "$hostname")
    cat "$cache_file" 2>/dev/null
}

# Write cache result
_hh_cache_write() {
    local hostname="$1"
    local result="$2"
    local cache_file
    cache_file=$(_hh_cache_file "$hostname")
    echo "$result" > "$cache_file"
}

# Clear cache for a host or all hosts
host_health_clear_cache() {
    local hostname="${1:-}"
    if [[ -n "$hostname" ]]; then
        rm -f "$(_hh_cache_file "$hostname")"
    else
        rm -f "$_HH_CACHE_DIR"/*.json 2>/dev/null
    fi
}

# Execute command on host (local or SSH)
# Usage: _hh_exec_on_host <hostname> <connection_type> <ssh_host> <command>
# Returns: command output
_hh_exec_on_host() {
    local hostname="$1"
    local connection="$2"
    local ssh_host="$3"
    local cmd="$4"

    if [[ "$connection" == "local" ]]; then
        timeout "$_HH_CMD_TIMEOUT" bash -c "$cmd" 2>/dev/null
    else
        timeout "$_HH_CMD_TIMEOUT" ssh \
            -o ConnectTimeout="$_HH_SSH_TIMEOUT" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            "$ssh_host" "$cmd" 2>/dev/null
    fi
}

# Check SSH connectivity
# Returns: JSON object { "reachable": bool, "latency_ms": int, "error": string }
_hh_check_connectivity() {
    local hostname="$1"
    local connection="$2"
    local ssh_host="$3"

    if [[ "$connection" == "local" ]]; then
        echo '{"reachable": true, "latency_ms": 0, "method": "local"}'
        return 0
    fi

    # SSH connectivity test with timing
    local start_ms end_ms latency_ms
    start_ms=$(date +%s%3N 2>/dev/null || echo "0")

    if timeout "$_HH_SSH_TIMEOUT" ssh \
        -o ConnectTimeout="$_HH_SSH_TIMEOUT" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$ssh_host" "echo ok" &>/dev/null; then

        end_ms=$(date +%s%3N 2>/dev/null || echo "0")
        latency_ms=$((end_ms - start_ms))
        [[ $latency_ms -lt 0 ]] && latency_ms=0

        echo "{\"reachable\": true, \"latency_ms\": $latency_ms, \"method\": \"ssh\"}"
        return 0
    else
        echo '{"reachable": false, "latency_ms": null, "method": "ssh", "error": "SSH connection failed"}'
        return 1
    fi
}

# Check disk space
# Returns: JSON object { "path": str, "usage_percent": int, "available_gb": float, "status": str }
_hh_check_disk_space() {
    local hostname="$1"
    local connection="$2"
    local ssh_host="$3"

    local df_output
    df_output=$(_hh_exec_on_host "$hostname" "$connection" "$ssh_host" \
        "df -P / | tail -1 | awk '{print \$5, \$4}'")

    if [[ -z "$df_output" ]]; then
        echo '{"path": "/", "usage_percent": null, "available_gb": null, "status": "error", "error": "Failed to get disk info"}'
        return 1
    fi

    local usage_percent available_kb available_gb status
    usage_percent=$(echo "$df_output" | awk '{print $1}' | tr -d '%')
    available_kb=$(echo "$df_output" | awk '{print $2}')
    available_gb=$(echo "scale=2; $available_kb / 1048576" | bc 2>/dev/null || echo "0")

    if [[ $usage_percent -gt $_HH_DISK_ERROR_THRESHOLD ]]; then
        status="error"
    elif [[ $usage_percent -gt $_HH_DISK_WARN_THRESHOLD ]]; then
        status="warning"
    else
        status="ok"
    fi

    echo "{\"path\": \"/\", \"usage_percent\": $usage_percent, \"available_gb\": $available_gb, \"status\": \"$status\"}"
}

# Check toolchain availability
# Returns: JSON object { "rust": {...}, "go": {...}, "bun": {...}, ... }
_hh_check_toolchains() {
    local hostname="$1"
    local connection="$2"
    local ssh_host="$3"
    local capabilities="$4"

    local result="{"
    local first=true

    # Check each toolchain based on host capabilities
    for capability in $capabilities; do
        local check_cmd version status

        case "$capability" in
            rust)
                check_cmd="rustc --version 2>/dev/null | head -1"
                ;;
            go)
                check_cmd="go version 2>/dev/null | head -1"
                ;;
            bun)
                check_cmd="bun --version 2>/dev/null | head -1"
                ;;
            node)
                check_cmd="node --version 2>/dev/null | head -1"
                ;;
            docker)
                check_cmd="docker --version 2>/dev/null | head -1"
                ;;
            act)
                check_cmd="act --version 2>/dev/null | head -1"
                ;;
            *)
                continue
                ;;
        esac

        version=$(_hh_exec_on_host "$hostname" "$connection" "$ssh_host" "$check_cmd")

        if [[ -n "$version" ]]; then
            status="ok"
            # Clean version output (remove newlines, escape quotes)
            version=$(echo "$version" | tr -d '\n' | sed 's/"/\\"/g')
        else
            status="missing"
            version=""
        fi

        $first || result+=","
        first=false
        result+="\"$capability\": {\"status\": \"$status\", \"version\": \"$version\"}"
    done

    result+="}"
    echo "$result"
}

# Check Docker daemon status (for act hosts)
_hh_check_docker_status() {
    local hostname="$1"
    local connection="$2"
    local ssh_host="$3"

    local docker_info
    docker_info=$(_hh_exec_on_host "$hostname" "$connection" "$ssh_host" \
        "docker info --format '{{.ServerVersion}}' 2>/dev/null")

    if [[ -n "$docker_info" ]]; then
        echo "{\"running\": true, \"version\": \"$docker_info\"}"
        return 0
    else
        # Check if docker exists but daemon is not running
        local docker_exists
        docker_exists=$(_hh_exec_on_host "$hostname" "$connection" "$ssh_host" \
            "command -v docker &>/dev/null && echo yes || echo no")

        if [[ "$docker_exists" == "yes" ]]; then
            echo '{"running": false, "version": null, "error": "Docker daemon not running"}'
        else
            echo '{"running": false, "version": null, "error": "Docker not installed"}'
        fi
        return 1
    fi
}

# Check clock drift
_hh_check_clock_drift() {
    local hostname="$1"
    local connection="$2"
    local ssh_host="$3"

    local local_time remote_time drift_seconds

    if [[ "$connection" == "local" ]]; then
        echo '{"drift_seconds": 0, "status": "ok"}'
        return 0
    fi

    local_time=$(date +%s)
    remote_time=$(_hh_exec_on_host "$hostname" "$connection" "$ssh_host" "date +%s")

    if [[ -z "$remote_time" ]]; then
        echo '{"drift_seconds": null, "status": "error", "error": "Failed to get remote time"}'
        return 1
    fi

    drift_seconds=$((remote_time - local_time))
    [[ $drift_seconds -lt 0 ]] && drift_seconds=$((-drift_seconds))

    local status
    if [[ $drift_seconds -gt $_HH_CLOCK_DRIFT_WARN ]]; then
        status="warning"
    else
        status="ok"
    fi

    echo "{\"drift_seconds\": $drift_seconds, \"status\": \"$status\"}"
}

# Main health check function for a single host
# Usage: host_health_check <hostname> [--no-cache] [--json]
# Returns: JSON object with all health checks
host_health_check() {
    local hostname="$1"
    shift
    local use_cache=true
    local json_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-cache) use_cache=false; shift ;;
            --json) json_mode=true; shift ;;
            *) shift ;;
        esac
    done

    _hh_init_cache

    # Check cache first
    if $use_cache && _hh_cache_valid "$hostname"; then
        local cached
        cached=$(_hh_cache_read "$hostname")
        if $json_mode; then
            echo "$cached"
        else
            _hh_print_result "$hostname" "$cached"
        fi
        return 0
    fi

    # Get host configuration (uses yq with fallback parser)
    config_load 2>/dev/null || true
    local host_config
    host_config=$(_hh_get_host_config "$hostname" 2>/dev/null)

    if [[ -z "$host_config" || "$host_config" == "null" ]]; then
        local error_result
        error_result="{\"hostname\": \"$hostname\", \"status\": \"error\", \"error\": \"Host not configured\", \"healthy\": false}"
        if $json_mode; then
            echo "$error_result"
        else
            _hh_log_error "$hostname: Host not configured in hosts.yaml"
        fi
        return 4
    fi

    # Extract host properties (works with both yq YAML output and fallback JSON)
    local connection ssh_host capabilities platform description
    # Try jq first (for fallback JSON), then yq (for YAML output)
    if echo "$host_config" | jq -e '.' &>/dev/null 2>&1; then
        # JSON format from fallback parser
        connection=$(echo "$host_config" | jq -r '.connection // "ssh"')
        ssh_host=$(echo "$host_config" | jq -r '.ssh_host // ""')
        capabilities=$(echo "$host_config" | jq -r '.capabilities // ""')
        platform=$(echo "$host_config" | jq -r '.platform // "unknown"')
        description=$(echo "$host_config" | jq -r '.description // ""')
    elif command -v yq &>/dev/null; then
        # YAML format from yq
        connection=$(echo "$host_config" | yq -r '.connection // "ssh"' 2>/dev/null || echo "ssh")
        ssh_host=$(echo "$host_config" | yq -r '.ssh_host // ""' 2>/dev/null || echo "$hostname")
        capabilities=$(echo "$host_config" | yq -r '.capabilities // [] | .[]' 2>/dev/null | tr '\n' ' ')
        platform=$(echo "$host_config" | yq -r '.platform // "unknown"' 2>/dev/null || echo "unknown")
        description=$(echo "$host_config" | yq -r '.description // ""' 2>/dev/null || echo "")
    else
        # Last resort: default values
        connection="ssh"
        ssh_host="$hostname"
        capabilities=""
        platform="unknown"
        description=""
    fi

    # Use hostname as ssh_host if not specified
    [[ -z "$ssh_host" || "$ssh_host" == "null" ]] && ssh_host="$hostname"

    # Perform health checks
    _hh_log_info "Checking $hostname ($platform)..."

    local connectivity disk_space toolchains docker_status clock_drift
    local overall_status="ok"
    local errors=0
    local warnings=0

    # 1. Check connectivity
    connectivity=$(_hh_check_connectivity "$hostname" "$connection" "$ssh_host")
    if ! echo "$connectivity" | jq -e '.reachable' &>/dev/null; then
        overall_status="error"
        ((errors++))
    fi

    # Only continue with other checks if host is reachable
    if echo "$connectivity" | jq -e '.reachable' &>/dev/null; then
        # 2. Check disk space
        disk_space=$(_hh_check_disk_space "$hostname" "$connection" "$ssh_host")
        local disk_status
        disk_status=$(echo "$disk_space" | jq -r '.status')
        [[ "$disk_status" == "error" ]] && overall_status="error" && ((errors++))
        [[ "$disk_status" == "warning" ]] && [[ "$overall_status" != "error" ]] && overall_status="warning" && ((warnings++))

        # 3. Check toolchains
        toolchains=$(_hh_check_toolchains "$hostname" "$connection" "$ssh_host" "$capabilities")

        # 4. Check Docker (if host has docker/act capability)
        if [[ "$capabilities" == *"docker"* ]] || [[ "$capabilities" == *"act"* ]]; then
            docker_status=$(_hh_check_docker_status "$hostname" "$connection" "$ssh_host")
            if ! echo "$docker_status" | jq -e '.running' &>/dev/null; then
                [[ "$overall_status" != "error" ]] && overall_status="warning"
                ((warnings++))
            fi
        else
            docker_status='{"running": null, "required": false}'
        fi

        # 5. Check clock drift
        clock_drift=$(_hh_check_clock_drift "$hostname" "$connection" "$ssh_host")
        local drift_status
        drift_status=$(echo "$clock_drift" | jq -r '.status')
        [[ "$drift_status" == "warning" ]] && [[ "$overall_status" != "error" ]] && overall_status="warning" && ((warnings++))
    else
        disk_space='{"status": "unknown", "error": "Host unreachable"}'
        toolchains='{}'
        docker_status='{"running": null, "error": "Host unreachable"}'
        clock_drift='{"status": "unknown", "error": "Host unreachable"}'
    fi

    # Build result
    local healthy=true
    [[ "$overall_status" == "error" ]] && healthy=false

    local checked_at
    checked_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local result
    result=$(jq -nc \
        --arg hostname "$hostname" \
        --arg platform "$platform" \
        --arg description "$description" \
        --arg connection "$connection" \
        --arg status "$overall_status" \
        --argjson healthy "$healthy" \
        --argjson errors "$errors" \
        --argjson warnings "$warnings" \
        --argjson connectivity "$connectivity" \
        --argjson disk_space "$disk_space" \
        --argjson toolchains "$toolchains" \
        --argjson docker "$docker_status" \
        --argjson clock_drift "$clock_drift" \
        --arg checked_at "$checked_at" \
        '{
            hostname: $hostname,
            platform: $platform,
            description: $description,
            connection: $connection,
            status: $status,
            healthy: $healthy,
            errors: $errors,
            warnings: $warnings,
            checks: {
                connectivity: $connectivity,
                disk_space: $disk_space,
                toolchains: $toolchains,
                docker: $docker,
                clock_drift: $clock_drift
            },
            checked_at: $checked_at
        }')

    # Cache the result
    _hh_cache_write "$hostname" "$result"

    if $json_mode; then
        echo "$result"
    else
        _hh_print_result "$hostname" "$result"
    fi

    [[ "$overall_status" == "error" ]] && return 1 || return 0
}

# Print human-readable result
_hh_print_result() {
    local hostname="$1"
    local result="$2"

    local status healthy platform
    status=$(echo "$result" | jq -r '.status')
    healthy=$(echo "$result" | jq -r '.healthy')
    platform=$(echo "$result" | jq -r '.platform')

    case "$status" in
        ok)
            _hh_log_ok "$hostname ($platform): healthy"
            ;;
        warning)
            _hh_log_warn "$hostname ($platform): warnings present"
            # Print specific warnings
            local disk_status docker_running clock_status
            disk_status=$(echo "$result" | jq -r '.checks.disk_space.status')
            docker_running=$(echo "$result" | jq -r '.checks.docker.running')
            clock_status=$(echo "$result" | jq -r '.checks.clock_drift.status')

            [[ "$disk_status" == "warning" ]] && \
                _hh_log_warn "  - Disk usage > ${_HH_DISK_WARN_THRESHOLD}%"
            [[ "$docker_running" == "false" ]] && \
                _hh_log_warn "  - Docker daemon not running"
            [[ "$clock_status" == "warning" ]] && \
                _hh_log_warn "  - Clock drift > ${_HH_CLOCK_DRIFT_WARN}s"
            ;;
        error)
            _hh_log_error "$hostname ($platform): unhealthy"
            local reachable disk_status
            reachable=$(echo "$result" | jq -r '.checks.connectivity.reachable')
            disk_status=$(echo "$result" | jq -r '.checks.disk_space.status')

            [[ "$reachable" == "false" ]] && \
                _hh_log_error "  - Host unreachable"
            [[ "$disk_status" == "error" ]] && \
                _hh_log_error "  - Disk usage > ${_HH_DISK_ERROR_THRESHOLD}%"
            ;;
    esac

    # Show toolchain status
    local toolchains
    toolchains=$(echo "$result" | jq -r '.checks.toolchains // {}')
    if [[ "$toolchains" != "{}" ]]; then
        local missing
        missing=$(echo "$toolchains" | jq -r 'to_entries | map(select(.value.status == "missing")) | map(.key) | join(", ")')
        if [[ -n "$missing" ]]; then
            _hh_log_warn "  - Missing toolchains: $missing"
        fi
    fi
}

# Check all configured hosts
# Usage: host_health_check_all [--no-cache] [--json]
host_health_check_all() {
    local use_cache=true
    local json_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-cache) use_cache=false; shift ;;
            --json) json_mode=true; shift ;;
            *) shift ;;
        esac
    done

    config_load 2>/dev/null || true

    local hosts
    hosts=$(_hh_list_hosts 2>/dev/null | tr '\n' ' ')

    if [[ -z "$hosts" ]]; then
        if $json_mode; then
            echo '{"hosts": [], "error": "No hosts configured"}'
        else
            _hh_log_error "No hosts configured in hosts.yaml"
        fi
        return 4
    fi

    local results=()
    local total_healthy=0
    local total_unhealthy=0
    local total_warnings=0

    for hostname in $hosts; do
        local result
        local cache_flag=""
        $use_cache || cache_flag="--no-cache"

        result=$(host_health_check "$hostname" $cache_flag --json 2>/dev/null)
        results+=("$result")

        local healthy status
        healthy=$(echo "$result" | jq -r '.healthy')
        status=$(echo "$result" | jq -r '.status')

        if [[ "$healthy" == "true" ]]; then
            ((total_healthy++))
        else
            ((total_unhealthy++))
        fi
        [[ "$status" == "warning" ]] && ((total_warnings++))
    done

    local checked_at
    checked_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if $json_mode; then
        local hosts_json
        hosts_json=$(printf '%s\n' "${results[@]}" | jq -sc '.')
        jq -nc \
            --argjson hosts "$hosts_json" \
            --argjson healthy "$total_healthy" \
            --argjson unhealthy "$total_unhealthy" \
            --argjson warnings "$total_warnings" \
            --arg checked_at "$checked_at" \
            '{
                hosts: $hosts,
                summary: {
                    total: ($healthy + $unhealthy),
                    healthy: $healthy,
                    unhealthy: $unhealthy,
                    warnings: $warnings
                },
                checked_at: $checked_at
            }'
    else
        echo ""
        _hh_log_info "Summary: $total_healthy healthy, $total_unhealthy unhealthy, $total_warnings with warnings"
    fi
}

# Get list of healthy hosts
# Usage: host_health_get_healthy_hosts [--for-capability <cap>] [--json]
host_health_get_healthy_hosts() {
    local capability=""
    local json_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --for-capability) capability="$2"; shift 2 ;;
            --json) json_mode=true; shift ;;
            *) shift ;;
        esac
    done

    local all_results
    all_results=$(host_health_check_all --json 2>/dev/null)

    local healthy_hosts
    if [[ -n "$capability" ]]; then
        # Filter by capability
        healthy_hosts=$(echo "$all_results" | jq -r --arg cap "$capability" \
            '.hosts[] | select(.healthy == true) | select(.checks.toolchains[$cap].status == "ok") | .hostname')
    else
        healthy_hosts=$(echo "$all_results" | jq -r '.hosts[] | select(.healthy == true) | .hostname')
    fi

    if $json_mode; then
        echo "$healthy_hosts" | jq -R -s 'split("\n") | map(select(length > 0))'
    else
        echo "$healthy_hosts"
    fi
}

# Check if a specific host is healthy for a build
# Usage: host_health_is_ready <hostname> [--require <capability1,capability2>]
# Returns: 0 if ready, 1 if not
host_health_is_ready() {
    local hostname="$1"
    shift
    local required_capabilities=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --require) required_capabilities="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local result
    result=$(host_health_check "$hostname" --json 2>/dev/null)

    if ! echo "$result" | jq -e '.healthy' &>/dev/null; then
        return 1
    fi

    if [[ -n "$required_capabilities" ]]; then
        local caps
        IFS=',' read -ra caps <<< "$required_capabilities"
        for cap in "${caps[@]}"; do
            local cap_status
            cap_status=$(echo "$result" | jq -r --arg cap "$cap" '.checks.toolchains[$cap].status // "missing"')
            if [[ "$cap_status" != "ok" ]]; then
                return 1
            fi
        done
    fi

    return 0
}

# Export functions for use by other scripts
export -f host_health_check host_health_check_all host_health_get_healthy_hosts
export -f host_health_is_ready host_health_clear_cache
