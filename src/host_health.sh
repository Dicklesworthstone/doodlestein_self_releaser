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

# Resolve dependencies relative to this module, independent of caller globals.
_HH_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source config if not already loaded
if ! declare -p DSR_CONFIG &>/dev/null 2>&1; then
    source "$_HH_PROJECT_ROOT/src/config.sh"
fi

# Reuse the numeric-safe millisecond clock used by structured logging. The main
# dsr entrypoint loads logging first; source it here as well for standalone use.
if ! declare -F _get_ms_timestamp &>/dev/null; then
    source "$_HH_PROJECT_ROOT/src/logging.sh"
fi

# Fallback host parsing when yq is unavailable
# Usage: _hh_parse_host_fallback <hostname>
# Returns: simplified JSON with host config
_hh_parse_host_fallback() {
    local hostname="$1"
    local hosts_file="${DSR_HOSTS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml}"

    # Validate hostname contains only safe characters (prevents regex injection)
    # Hostnames must be alphanumeric with underscores/hyphens only
    if [[ ! "$hostname" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        echo "Invalid hostname format: $hostname" >&2
        return 4
    fi

    if [[ ! -f "$hosts_file" ]]; then
        return 1
    fi

    # This is deliberately a small YAML subset, not an alias resolver. Never
    # turn an unresolved alias, flow collection, merge, tag or second document
    # into an empty capability list or a different SSH destination.
    local scan_status=0
    LC_ALL=C grep -Eq '[][{}&*!]|<<:|^---|^\.\.\.|^[[:space:]]*[?%]' "$hosts_file" || scan_status=$?
    case "$scan_status" in
        1) ;;
        0)
            _hh_log_error "Host configuration needs yq v4: $hosts_file"
            return 3
            ;;
        *) return 4 ;;
    esac

    # Simple state-machine parser for YAML host entries
    local in_hosts=false
    local in_target=false
    local in_capabilities=false
    local platform="" connection="" ssh_host="" description="" concurrency="1"
    local enabled="true"
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
        if $in_target && [[ "$line" =~ ^[[:space:]][[:space:]][a-zA-Z_][a-zA-Z0-9_-]*: ]] && [[ ! "$line" =~ ^[[:space:]][[:space:]]${hostname}: ]]; then
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
                [[ "$line" =~ ^[[:space:]]+capabilities:[[:space:]]*$ ]] || return 4
                in_capabilities=true
                continue
            fi

            # Parse capability items
            if $in_capabilities; then
                if [[ "$line" =~ ^[[:space:]]+-[[:space:]]*([a-zA-Z0-9_][a-zA-Z0-9_.+-]*)[[:space:]]*$ ]]; then
                    capabilities+="${BASH_REMATCH[1]} "
                    continue
                elif [[ "$line" =~ ^[[:space:]]+- ]]; then
                    _hh_log_error "Capability syntax needs yq v4: $hostname"
                    return 3
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
            elif [[ "$line" =~ ^[[:space:]]+enabled: ]]; then
                [[ "$line" =~ ^[[:space:]]+enabled:[[:space:]]*(true|false)[[:space:]]*$ ]] || return 4
                enabled="${BASH_REMATCH[1]}"
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
            --argjson enabled "$enabled" \
            --arg capabilities "$capabilities" \
            '{
                platform: $platform,
                connection: $connection,
                ssh_host: $ssh_host,
                description: $description,
                concurrency: $concurrency,
                capabilities: ($capabilities | split(" ") | map(select(length > 0))),
                enabled: $enabled
            }' || return 4
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
        if [[ "$line" =~ ^[[:space:]][[:space:]]([a-zA-Z_][a-zA-Z0-9_-]*): ]]; then
            local host_name="${BASH_REMATCH[1]}"
            local host_json
            host_json=$(_hh_get_host_config "$host_name") || return $?
            if jq -e '.enabled == true' <<< "$host_json" >/dev/null; then
                echo "$host_name"
            fi
        fi
    done < "$hosts_file"
}

# Resolve the COMPLETE document before selecting a host. Serializing a YAML
# fragment first leaves aliases pointing at anchors that are no longer present
# (GH #21). Reuse the configuration layer's duplicate-key/single-document gate.
_hh_read_hosts_json() {
    local hosts_file="${DSR_HOSTS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml}"
    local document hosts
    document=$(_config_read_single_mapping_json "$hosts_file") || return 4
    if ! hosts=$(jq -ceS '
        .hosts | if type == "object" and
            all(keys[]; test("^[A-Za-z][A-Za-z0-9_-]*$")) and
            all(.[]; type == "object")
        then . else error("hosts must be a mapping of named host objects") end
    ' <<< "$document" 2>/dev/null); then
        _hh_log_error "Invalid hosts mapping in: $hosts_file"
        return 4
    fi
    printf '%s\n' "$hosts"
}

# Both parsers feed exactly one typed JSON object to health admission. Defaults
# apply only to absent/null optional fields, never to malformed values. In
# particular false is not the same as an absent enabled flag, and capabilities
# must remain a list until explicitly joined for the toolchain probe.
_hh_normalize_host_config() {
    local hostname="$1" raw="$2" normalized
    if ! normalized=$(jq -cSe --slurp --arg hostname "$hostname" '
        if length == 1 then .[0] else error("expected one host object") end |
        if type == "object" and
            (.platform | type == "string" and test("^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$")) and
            (.connection == null or .connection == "local" or .connection == "ssh") and
            (.ssh_host == null or .ssh_host == "" or
                (.ssh_host | type == "string" and test("^[^[:space:][:cntrl:]-][^[:space:][:cntrl:]]*$"))) and
            (.description == null or (.description | type == "string")) and
            (.enabled == null or (.enabled | type == "boolean")) and
            (.capabilities == null or (.capabilities | type == "array" and
                all(.[]; type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9_.+-]*$"))))
        then . + {
            connection: (.connection // "ssh"),
            ssh_host: (if .ssh_host == null or .ssh_host == "" then $hostname else .ssh_host end),
            description: (.description // ""),
            capabilities: (.capabilities // []),
            enabled: (if .enabled == null then true else .enabled end)
        } else error("invalid host configuration fields") end
    ' <<< "$raw" 2>/dev/null); then
        _hh_log_error "Invalid host configuration for: $hostname"
        return 4
    fi
    printf '%s\n' "$normalized"
}

# Return self-contained JSON, 1 for a missing host, 3 for a missing parser, or
# 4 for invalid configuration. A parser failure must never select a fallback.
_hh_get_host_config() {
    local hostname="$1"
    local hosts raw
    [[ "$hostname" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || return 4

    if command -v yq &>/dev/null; then
        hosts=$(_hh_read_hosts_json) || return $?
        jq -e --arg host "$hostname" 'has($host)' <<< "$hosts" >/dev/null || return 1
        raw=$(jq -c --arg host "$hostname" '.[$host]' <<< "$hosts") || return 4
    else
        raw=$(_hh_parse_host_fallback "$hostname") || return $?
    fi
    _hh_normalize_host_config "$hostname" "$raw"
}

# List hosts with yq fallback
_hh_list_hosts() {
    local hosts names name host_config result=""
    if command -v yq &>/dev/null; then
        hosts=$(_hh_read_hosts_json) || return $?
        names=$(jq -r 'keys[]' <<< "$hosts") || return 4
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            host_config=$(jq -c --arg name "$name" '.[$name]' <<< "$hosts") || return 4
            host_config=$(_hh_normalize_host_config "$name" "$host_config") || return $?
            if jq -e '.enabled == true' <<< "$host_config" >/dev/null; then
                result+="$name"$'\n'
            fi
        done <<< "$names"
    else
        # Capture the complete result so a later malformed entry cannot leave
        # an apparently successful partial list on stdout.
        result=$(_hh_list_hosts_fallback) || return $?
    fi
    [[ -z "$result" ]] || printf '%s\n' "${result%$'\n'}"
    return 0
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

# Timeout helper (supports GNU timeout and coreutils gtimeout)
_HH_TIMEOUT_CMD=""
_hh_timeout_cmd() {
    if [[ -n "$_HH_TIMEOUT_CMD" ]]; then
        echo "$_HH_TIMEOUT_CMD"
        return 0
    fi

    if command -v timeout &>/dev/null; then
        _HH_TIMEOUT_CMD="timeout"
    elif command -v gtimeout &>/dev/null; then
        _HH_TIMEOUT_CMD="gtimeout"
    else
        _HH_TIMEOUT_CMD=""
    fi

    echo "$_HH_TIMEOUT_CMD"
}

_hh_run_with_timeout() {
    local seconds="$1"
    shift
    local cmd
    cmd=$(_hh_timeout_cmd)
    if [[ -n "$cmd" ]]; then
        "$cmd" "$seconds" "$@"
    else
        "$@"
    fi
}

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
    [[ "$hostname" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || return 4
    echo "$_HH_CACHE_DIR/${hostname}.json"
}

# Bind cached admission to the normalized host and the policy that produced it.
# Retain only the digest, not arbitrary host fields (which may be private).
# Bump the schema whenever probe/admission semantics change incompatibly.
_hh_admission_fingerprint() {
    local host_config="$1" contract digest
    contract=$(jq -ncS --argjson host "$host_config" \
        --arg disk_warn "$_HH_DISK_WARN_THRESHOLD" \
        --arg disk_error "$_HH_DISK_ERROR_THRESHOLD" \
        --arg clock_warn "$_HH_CLOCK_DRIFT_WARN" \
        --arg ssh_timeout "$_HH_SSH_TIMEOUT" \
        --arg command_timeout "$_HH_CMD_TIMEOUT" \
        '{schema:"dsr-host-admission-v1",host:$host,policy:{
            disk_warn:$disk_warn,disk_error:$disk_error,clock_warn:$clock_warn,
            ssh_timeout:$ssh_timeout,command_timeout:$command_timeout}}') || return 4
    if command -v sha256sum >/dev/null 2>&1; then
        digest=$(printf '%s\n' "$contract" | sha256sum) || return 3
    elif command -v shasum >/dev/null 2>&1; then
        digest=$(printf '%s\n' "$contract" | shasum -a 256) || return 3
    else
        return 3
    fi
    digest="${digest%% *}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 4
    printf '%s\n' "$digest"
}

# Read one snapshot and validate THAT result, not a pathname which another
# health checker might replace between validation and consumption. The expected
# fingerprint is mandatory at build admission; the optional form supports
# existing low-level cache inspection without authorizing a build.
_hh_cache_get() {
    local hostname="$1"
    local expected_fingerprint="${2:-}"
    local cache_file result
    cache_file=$(_hh_cache_file "$hostname") || return 1

    if [[ ! -f "$cache_file" || -L "$cache_file" ]]; then
        return 1
    fi
    result=$(_hh_cache_read "$hostname") || return 1

    # A hostname can switch between local and split storage, or change its
    # mapping/budgets. A fresh timestamp does not authorize the new contract.
    local storage storage_status=0
    storage=$(config_windows_storage_json "$hostname") || storage_status=$?
    case "$storage_status" in
        0)
            jq -e --argjson storage "$storage" \
                '.checks.disk_space.storage_contract == $storage' \
                <<< "$result" >/dev/null 2>&1 || return 1
            ;;
        1)
            jq -e '.checks.disk_space | .storage_contract == null and
                .admission != "split-storage-role-budgets-v1" and .path != "split-storage"' \
                <<< "$result" >/dev/null 2>&1 || return 1
            ;;
        *) return 1 ;;
    esac

    if ! jq -se --arg hostname "$hostname" --arg fingerprint "$expected_fingerprint" '
        length == 1 and (.[0] |
        type == "object" and
        .hostname == $hostname and
        ($fingerprint == "" or .admission_fingerprint == $fingerprint) and
        (.platform | type == "string") and
        (.description | type == "string") and
        (.connection | type == "string") and
        ((.status == "ok" or .status == "warning") and .healthy == true or
         .status == "error" and .healthy == false) and
        (.errors | type == "number") and
        (.warnings | type == "number") and
        (.checks | type == "object") and
        (.checks.connectivity | type == "object") and
        (.checks.disk_space | type == "object") and
        (.checks.disk_space.admission != "split-storage-role-budgets-v1" or
         .checks.disk_space.lock_range == "cargo-win32-whole-u64-v1") and
        (.checks.toolchains | type == "object") and
        (.checks.docker | type == "object") and
        (.checks.clock_drift | type == "object") and
        (.checked_at | type == "string"))
    ' <<< "$result" >/dev/null 2>&1; then
        return 1
    fi

    local cache_age file_mtime now
    now=$(date +%s) || return 1
    if [[ "$(uname)" == "Darwin" ]]; then
        file_mtime=$(stat -f %m "$cache_file") || return 1
    else
        file_mtime=$(stat -c %Y "$cache_file") || return 1
    fi
    [[ "$now" =~ ^[0-9]+$ && "$file_mtime" =~ ^[0-9]+$ ]] || return 1
    cache_age=$((now - file_mtime))

    [[ $cache_age -ge 0 && $cache_age -lt $_HH_CACHE_TTL ]] || return 1
    printf '%s\n' "$result"
}

# Check cache validity without emitting its contents.
_hh_cache_valid() {
    _hh_cache_get "$@" >/dev/null
}

# Read cached result
_hh_cache_read() {
    local hostname="$1"
    local cache_file
    cache_file=$(_hh_cache_file "$hostname") || return 4
    cat "$cache_file" 2>/dev/null
}

# Write cache result
_hh_cache_write() (
    local hostname="$1"
    local result="$2"
    local cache_file staged
    cache_file=$(_hh_cache_file "$hostname") || return 4
    # Never truncate a visible receipt or follow a linked destination. Stage
    # privately in the same directory and publish through one atomic rename.
    [[ ! -L "$cache_file" && ( ! -e "$cache_file" || -f "$cache_file" ) ]] || return 1
    jq -se 'length == 1' <<< "$result" >/dev/null 2>&1 || return 1
    staged=$(mktemp "$_HH_CACHE_DIR/.${hostname}.XXXXXXXX") || return 1
    trap 'rm -f -- "$staged"' EXIT
    trap 'exit 1' HUP INT TERM
    printf '%s\n' "$result" > "$staged" || return 1
    [[ ! -L "$cache_file" && ( ! -e "$cache_file" || -f "$cache_file" ) ]] || return 1
    mv -f -- "$staged" "$cache_file"
)

# Clear cache for a host or all hosts
host_health_clear_cache() {
    local hostname="${1:-}"
    if [[ -n "$hostname" ]]; then
        local cache_file
        cache_file=$(_hh_cache_file "$hostname") || return 4
        rm -f -- "$cache_file"
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
        _hh_run_with_timeout "$_HH_CMD_TIMEOUT" bash -c "$cmd" 2>/dev/null
    else
        _hh_run_with_timeout "$_HH_CMD_TIMEOUT" ssh \
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
    start_ms=$(_get_ms_timestamp)

    if _hh_run_with_timeout "$_HH_SSH_TIMEOUT" ssh \
        -o ConnectTimeout="$_HH_SSH_TIMEOUT" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$ssh_host" "echo ok" &>/dev/null; then

        end_ms=$(_get_ms_timestamp)
        latency_ms=$((end_ms - start_ms))
        [[ $latency_ms -lt 0 ]] && latency_ms=0

        echo "{\"reachable\": true, \"latency_ms\": $latency_ms, \"method\": \"ssh\"}"
        return 0
    else
        echo '{"reachable": false, "latency_ms": null, "method": "ssh", "error": "SSH connection failed"}'
        return 1
    fi
}

# Encode only the split-storage probe. The outer command is trusted ASCII:
# payload text (including Unicode, quotes and shell metacharacters) exists only
# inside gzip/base64, never as shell syntax. Avoid wrapping that base64 again
# in UTF-16/base64, which exceeds Windows' command limit for the Win32 probe.
_hh_windows_storage_command() {
    local payload wrapper command
    payload=$(gzip -n -c | base64 | tr -d '\r\n') || return 4
    [[ "$payload" =~ ^[A-Za-z0-9+/=]+$ ]] || return 4
    wrapper="& ([ScriptBlock]::Create([IO.StreamReader]::new([IO.Compression.GZipStream]::new([IO.MemoryStream]::new([Convert]::FromBase64String('$payload')),[IO.Compression.CompressionMode]::Decompress),[Text.Encoding]::UTF8).ReadToEnd()))"
    case "$wrapper" in *'$'*|*'`'*|*'"'*|*'\\'*) return 4 ;; esac
    command="powershell -NoProfile -NonInteractive -Command \"$wrapper\""
    [[ ${#command} -lt 7000 ]] || return 4
    printf '%s\n' "$command"
}

# Check disk space
# Returns: JSON object { "path": str, "usage_percent": int, "available_gb": float, "status": str }
_hh_check_disk_space() {
    local hostname="$1"
    local connection="$2"
    local ssh_host="$3"
    local platform="${4:-}"

    if [[ "$platform" == windows/* ]]; then
        local storage storage_status=0 storage_script storage_probe storage_result
        storage=$(config_windows_storage_json "$hostname") || storage_status=$?
        if [[ $storage_status -eq 0 ]]; then
            storage_script=$(config_windows_storage_session_script "$hostname") || return 4
            storage_script+=$'\n'"$(config_windows_storage_lock_script "$hostname")" || return 4
            # Preserve the source volume's actual pressure. A split layout is
            # admitted by BOTH role budgets, never by substituting NFS free
            # space for the system disk or suppressing its warning.
            storage_script+=$'\n''$sourceUsage=[math]::Round(100-($dsrSourceDisk.FreeSpace/$dsrSourceDisk.Size*100)); $targetUsage=[math]::Round(100-($dsrTargetDisk.FreeSpace/$dsrTargetDisk.Size*100)); $status=if($sourceUsage -gt 90 -or $targetUsage -gt 90){"warning"}else{"ok"}; @{path=$dsrSourceDisk.DeviceID; usage_percent=$sourceUsage; available_gb=[math]::Round($dsrSourceDisk.FreeSpace/1GB,2); status=$status; admission="split-storage-role-budgets-v1"; source=@{path=$dsrSourceDisk.DeviceID; free_bytes=$dsrSourceDisk.FreeSpace; size_bytes=$dsrSourceDisk.Size}; target=@{path=$dsrTargetDisk.DeviceID; provider=$dsrTargetDisk.ProviderName; free_bytes=$dsrTargetDisk.FreeSpace; size_bytes=$dsrTargetDisk.Size}; lock_probe="independent-process-exclusion-and-reacquisition"; lock_range="cargo-win32-whole-u64-v1"} | ConvertTo-Json -Depth 4 -Compress'
            storage_probe=$(printf '%s' "$storage_script" | _hh_windows_storage_command) || return 4
            if storage_result=$(_hh_exec_on_host "$hostname" "$connection" "$ssh_host" \
                "$storage_probe") && \
               jq -e '.admission == "split-storage-role-budgets-v1" and .lock_range == "cargo-win32-whole-u64-v1" and (.status == "ok" or .status == "warning")' <<< "$storage_result" >/dev/null; then
                jq --argjson contract "$storage" '. + {storage_contract:$contract}' <<< "$storage_result"
                return 0
            fi
            echo '{"path":"split-storage","status":"error","available_gb":null,"error":"Windows source/target capacity, mapping identity, or lock admission failed"}'
            return 1
        elif [[ $storage_status -ne 1 ]]; then
            echo '{"path":"split-storage","status":"error","available_gb":null,"error":"Invalid Windows split-storage contract"}'
            return 1
        fi
    fi

    local df_output df_status=0
    if [[ "$platform" == windows/* ]]; then
        # Windows SSH may launch Bash, which expands $d inside a quoted
        # -Command before PowerShell sees it. Encode the script so either
        # shell passes the exact program through, including the drive filter.
        local disk_probe
        if disk_probe=$(printf '%s' '$ErrorActionPreference="Stop"; $d=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='"'"'C:'"'"'"; [math]::Round(100-($d.FreeSpace/$d.Size*100)); [math]::Round($d.FreeSpace/1KB)' \
            | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\r\n'); then
            df_output=$(_hh_exec_on_host "$hostname" "$connection" "$ssh_host" \
                "powershell -NoProfile -NonInteractive -EncodedCommand $disk_probe") || df_status=$?
        else
            df_status=$?
        fi
    else
        df_output=$(_hh_exec_on_host "$hostname" "$connection" "$ssh_host" \
            "LC_ALL=C df -Pk /") || df_status=$?
    fi

    if [[ $df_status -ne 0 || -z "$df_output" ]]; then
        echo '{"path": "/", "usage_percent": null, "available_gb": null, "status": "error", "error": "Failed to get disk info"}'
        return 1
    fi

    if [[ "$platform" == windows/* ]]; then
        # Strip Windows CRLF and flatten the two PowerShell output lines.
        df_output=$(printf '%s\n' "$df_output" | tr -d '\r' | tr '\n' ' ')
    else
        # Parse locally so the remote command status above belongs to df itself.
        df_output=$(printf '%s\n' "$df_output" | awk 'END {print $5, $4}')
    fi

    local usage_token usage_percent available_kb extra available_gb status
    read -r usage_token available_kb extra <<< "$df_output"
    usage_percent="${usage_token%\%}"

    if [[ -n "${extra:-}" || ! "$usage_percent" =~ ^[0-9]{1,3}$ || ! "$available_kb" =~ ^[0-9]+$ ]]; then
        echo '{"path": "/", "usage_percent": null, "available_gb": null, "status": "error", "error": "Invalid disk info"}'
        return 1
    fi

    usage_percent=$((10#$usage_percent))
    if [[ $usage_percent -gt 100 ]]; then
        echo '{"path": "/", "usage_percent": null, "available_gb": null, "status": "error", "error": "Invalid disk info"}'
        return 1
    fi

    # Use awk for division (more portable than bc which may not be installed)
    available_gb=$(awk -v kb="$available_kb" 'BEGIN {printf "%.2f", kb / 1048576}')

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
    local platform="${5:-}"

    local result="{"
    local first=true
    local is_windows=false
    [[ "$platform" == windows/* ]] && is_windows=true

    # Check each toolchain based on host capabilities
    for capability in $capabilities; do
        local check_cmd version status

        if $is_windows; then
            # Windows commands (no Unix shell redirection/pipes)
            case "$capability" in
                rust)   check_cmd="rustc --version" ;;
                go)     check_cmd="go version" ;;
                bun)    check_cmd="bun --version" ;;
                node)   check_cmd="node --version" ;;
                docker) check_cmd="docker --version" ;;
                act)    check_cmd="act --version" ;;
                *)      continue ;;
            esac
        else
            # Unix commands
            case "$capability" in
                rust)   check_cmd="rustc --version 2>/dev/null | head -1" ;;
                go)     check_cmd="go version 2>/dev/null | head -1" ;;
                bun)    check_cmd="bun --version 2>/dev/null | head -1" ;;
                node)   check_cmd="node --version 2>/dev/null | head -1" ;;
                docker) check_cmd="docker --version 2>/dev/null | head -1" ;;
                act)    check_cmd="act --version 2>/dev/null | head -1" ;;
                *)      continue ;;
            esac
        fi

        version=$(_hh_exec_on_host "$hostname" "$connection" "$ssh_host" "$check_cmd")

        if [[ -n "$version" ]]; then
            status="ok"
            # Clean version output (remove CRLF/newlines, escape quotes)
            version=$(echo "$version" | tr -d '\r\n' | sed 's/"/\\"/g')
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
        "docker version --format '{{.Server.Version}}' 2>/dev/null || docker info --format '{{.ServerVersion}}' 2>/dev/null")

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
    local platform="${4:-}"

    local local_time remote_time drift_seconds

    if [[ "$connection" == "local" ]]; then
        echo '{"drift_seconds": 0, "status": "ok"}'
        return 0
    fi

    local_time=$(date +%s)

    # Use PowerShell for Windows hosts, date +%s for Unix hosts
    if [[ "$platform" == windows/* ]]; then
        remote_time=$(_hh_exec_on_host "$hostname" "$connection" "$ssh_host" \
            "powershell -NoProfile -Command \"[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()\"")
        # Strip Windows CRLF line endings
        remote_time=$(echo "$remote_time" | tr -d '\r\n')
    else
        remote_time=$(_hh_exec_on_host "$hostname" "$connection" "$ssh_host" "date +%s")
    fi

    if [[ -z "$remote_time" ]]; then
        echo '{"drift_seconds": null, "status": "error", "error": "Failed to get remote time"}'
        return 1
    fi

    # Validate the remote time is a positive integer before doing
    # arithmetic on it. The earlier code went straight into
    # `$((remote_time - local_time))`, which under `set -uo pipefail`
    # aborts the function with a "syntax error" the moment the SSH/
    # PowerShell call returns something non-numeric (a PowerShell warn
    # banner, a partial line, an SSH MOTD that leaked through, etc.) —
    # the caller would then see the function exit with no JSON on
    # stdout and treat the host as silently broken. Use jq to safely
    # encode the (possibly multi-line / quote-containing) error value.
    if [[ ! "$remote_time" =~ ^[0-9]+$ ]]; then
        local _hh_truncated="${remote_time:0:200}"
        local _hh_err
        _hh_err=$(jq -nc --arg msg "Non-numeric remote time: $_hh_truncated" '{drift_seconds: null, status: "error", error: $msg}')
        echo "$_hh_err"
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

    # Validate configuration before considering cached health or invoking SSH.
    config_load 2>/dev/null || true
    local host_config config_status=0
    host_config=$(_hh_get_host_config "$hostname") || config_status=$?
    if [[ $config_status -ne 0 ]]; then
        local error_result message="Invalid host configuration"
        [[ $config_status -ne 1 ]] || message="Host not configured"
        [[ $config_status -ne 3 ]] || message="Host configuration requires yq v4"
        error_result=$(jq -nc --arg hostname "$hostname" --arg error "$message" \
            '{hostname:$hostname,status:"error",error:$error,healthy:false}')
        if $json_mode; then
            echo "$error_result"
        else
            _hh_log_error "$hostname: $message"
        fi
        [[ $config_status -ne 3 ]] || return 3
        return 4
    fi

    # The admission boundary produces typed, normalized JSON in both modes.
    local connection ssh_host capabilities platform description enabled
    connection=$(jq -r '.connection' <<< "$host_config")
    ssh_host=$(jq -r '.ssh_host' <<< "$host_config")
    capabilities=$(jq -r '.capabilities | join(" ")' <<< "$host_config")
    platform=$(jq -r '.platform' <<< "$host_config")
    description=$(jq -r '.description' <<< "$host_config")
    enabled=$(jq -r '.enabled' <<< "$host_config")

    if [[ "$enabled" != "true" ]]; then
        local checked_at
        checked_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local disabled_result
        disabled_result=$(jq -nc             --arg hostname "$hostname"             --arg platform "$platform"             --arg description "$description"             --arg connection "$connection"             --arg checked_at "$checked_at"             '{
                hostname: $hostname,
                platform: $platform,
                description: $description,
                connection: $connection,
                status: "disabled",
                healthy: false,
                errors: 0,
                warnings: 0,
                checks: {},
                checked_at: $checked_at
            }')
        if $json_mode; then
            echo "$disabled_result"
        else
            _hh_log_info "$hostname ($platform): disabled"
        fi
        return 0
    fi

    local fingerprint="" cache_available=true cached cached_healthy
    if ! fingerprint=$(_hh_admission_fingerprint "$host_config") || ! _hh_init_cache; then
        # Health probes still work without a writable cache or a hash utility;
        # an unbound or unwritable receipt is never used for admission.
        cache_available=false
        use_cache=false
        _hh_log_warn "Health cache unavailable for $hostname; running fresh checks"
    fi
    if $use_cache && cached=$(_hh_cache_get "$hostname" "$fingerprint"); then
        cached_healthy=$(jq -r '.healthy' <<< "$cached")
        if $json_mode; then
            echo "$cached"
        else
            _hh_print_result "$hostname" "$cached"
        fi
        [[ "$cached_healthy" == "true" ]] && return 0 || return 1
    fi

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
        # 2. Check disk space (pass platform for Windows compatibility)
        disk_space=$(_hh_check_disk_space "$hostname" "$connection" "$ssh_host" "$platform")
        local disk_status
        disk_status=$(echo "$disk_space" | jq -r '.status')
        [[ "$disk_status" == "error" ]] && overall_status="error" && ((errors++))
        [[ "$disk_status" == "warning" ]] && [[ "$overall_status" != "error" ]] && overall_status="warning" && ((warnings++))

        # 3. Check toolchains (pass platform for Windows compatibility)
        toolchains=$(_hh_check_toolchains "$hostname" "$connection" "$ssh_host" "$capabilities" "$platform")

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

        # 5. Check clock drift (pass platform for Windows compatibility)
        clock_drift=$(_hh_check_clock_drift "$hostname" "$connection" "$ssh_host" "$platform")
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
        --arg fingerprint "$fingerprint" \
        '{
            hostname: $hostname,
            platform: $platform,
            description: $description,
            connection: $connection,
            admission_fingerprint: $fingerprint,
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
    if $cache_available; then
        _hh_cache_write "$hostname" "$result" || _hh_log_warn "Could not cache health for $hostname"
    fi

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

    [[ "$platform" == "null" ]] && platform="unknown platform"
    case "$status" in
        ok)
            _hh_log_ok "$hostname ($platform): healthy"
            ;;
        disabled)
            _hh_log_info "$hostname ($platform): disabled"
            return 0
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
            local result_error
            result_error=$(jq -r '.error // empty' <<< "$result")
            [[ -n "$result_error" ]] && _hh_log_error "  - $result_error"
            local reachable disk_status disk_usage disk_error
            reachable=$(echo "$result" | jq -r '.checks.connectivity.reachable')
            disk_status=$(echo "$result" | jq -r '.checks.disk_space.status')
            disk_usage=$(echo "$result" | jq -r '.checks.disk_space.usage_percent')

            [[ "$reachable" == "false" ]] && \
                _hh_log_error "  - Host unreachable"
            if [[ "$disk_status" == "error" ]]; then
                if [[ "$disk_usage" == "null" ]]; then
                    disk_error=$(echo "$result" | jq -r '.checks.disk_space.error // "Disk check failed"')
                    _hh_log_error "  - $disk_error"
                else
                    _hh_log_error "  - Disk usage > ${_HH_DISK_ERROR_THRESHOLD}%"
                fi
            fi
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
# Usage: host_health_check_all [--no-cache] [--json] [--fail-unhealthy]
# Returns 4 for an invalid host configuration. With --fail-unhealthy, also 1
# when an enabled host is unhealthy (the report is still printed); without
# it, unhealthy hosts are data, not a failure of the check.
host_health_check_all() {
    local use_cache=true
    local json_mode=false
    local fail_unhealthy=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-cache) use_cache=false; shift ;;
            --json) json_mode=true; shift ;;
            --fail-unhealthy) fail_unhealthy=true; shift ;;
            *) shift ;;
        esac
    done

    config_load 2>/dev/null || true

    local hosts hosts_status=0
    hosts=$(_hh_list_hosts | tr '\n' ' ') || hosts_status=$?

    if [[ $hosts_status -ne 0 || -z "$hosts" ]]; then
        local message="No hosts configured"
        [[ $hosts_status -eq 0 ]] || message="Invalid host configuration or missing YAML parser"
        if $json_mode; then
            jq -nc --arg error "$message" '{hosts:[],error:$error}'
        else
            _hh_log_error "$message"
        fi
        return 4
    fi

    local results=()
    local total_healthy=0
    local total_unhealthy=0
    local total_warnings=0
    local total_disabled=0

    for hostname in $hosts; do
        local result
        local cache_flag=""
        $use_cache || cache_flag="--no-cache"

        result=$(host_health_check "$hostname" $cache_flag --json 2>/dev/null)
        if ! jq -e 'type == "object"' <<< "$result" >/dev/null 2>&1; then
            result=$(jq -nc --arg hostname "$hostname" \
                '{hostname: $hostname, status: "error", healthy: false, error: "health check produced no result"}')
        fi
        results+=("$result")

        local healthy status
        healthy=$(echo "$result" | jq -r '.healthy')
        status=$(echo "$result" | jq -r '.status')

        # A host disabled in config is deliberately out of rotation, not a
        # failure of the fleet.
        if [[ "$status" == "disabled" ]]; then
            ((total_disabled++))
        elif [[ "$healthy" == "true" ]]; then
            ((total_healthy++))
        else
            ((total_unhealthy++))
        fi
        [[ "$status" == "warning" ]] && ((total_warnings++))
        $json_mode || _hh_print_result "$hostname" "$result"
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
            --argjson disabled "$total_disabled" \
            --arg checked_at "$checked_at" \
            '{
                hosts: $hosts,
                summary: {
                    total: ($healthy + $unhealthy + $disabled),
                    healthy: $healthy,
                    unhealthy: $unhealthy,
                    disabled: $disabled,
                    warnings: $warnings
                },
                checked_at: $checked_at
            }'
    else
        echo "" >&2
        _hh_log_info "Summary: $total_healthy healthy, $total_unhealthy unhealthy, $total_disabled disabled, $total_warnings with warnings"
    fi

    if $fail_unhealthy && [[ $total_unhealthy -gt 0 ]]; then
        return 1
    fi
    return 0
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
    if ! all_results=$(host_health_check_all --json); then
        _hh_log_error "Cannot select healthy hosts from an invalid host configuration"
        return 4
    fi

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
