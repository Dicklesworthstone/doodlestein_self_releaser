#!/usr/bin/env bash
# test_host_health.sh - Tests for src/host_health.sh
#
# Run: ./scripts/tests/test_host_health.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED+=1)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED+=1)); echo "${RED}FAIL${NC}: $1"; }

# Setup test environment
TEMP_DIR=$(mktemp -d)
export DSR_STATE_DIR="$TEMP_DIR/state"
export DSR_CACHE_DIR="$TEMP_DIR/cache"
export DSR_CONFIG_DIR="$TEMP_DIR/config"
mkdir -p "$DSR_STATE_DIR" "$DSR_CACHE_DIR" "$DSR_CONFIG_DIR"

# Create mock hosts.yaml for testing
cat > "$DSR_CONFIG_DIR/hosts.yaml" << 'EOF'
schema_version: "1.0.0"

hosts:
  testlocal:
    platform: linux/amd64
    connection: local
    capabilities:
      - rust
      - go
      - docker
    concurrency: 2
    description: "Test local host"

  testremote:
    platform: darwin/arm64
    connection: ssh
    ssh_host: nonexistent.example.com
    ssh_timeout: 5
    capabilities:
      - rust
      - go
    concurrency: 1
    description: "Test remote host (will fail)"

platform_mapping:
  linux/amd64: testlocal
  darwin/arm64: testremote
EOF

# Create minimal config.yaml
cat > "$DSR_CONFIG_DIR/config.yaml" << 'EOF'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
EOF

export DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"
export DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"

# Source logging for the numeric-safe timestamp helper, then stub log output.
source "$PROJECT_ROOT/src/logging.sh"

# Stub logging functions
log_info() { :; }
log_warn() { :; }
log_error() { echo "ERROR: $*" >&2; }
log_debug() { :; }
export -f log_info log_warn log_error log_debug

# Source the modules
source "$PROJECT_ROOT/src/config.sh"
source "$PROJECT_ROOT/src/host_health.sh"

# ============================================================================
# Cache Tests
# ============================================================================

_test_health_result_json() {
    local hostname="$1"
    local status="$2"
    local healthy="$3"

    jq -nc \
        --arg hostname "$hostname" \
        --arg status "$status" \
        --argjson healthy "$healthy" \
        '{
            hostname: $hostname,
            platform: "linux/amd64",
            description: "test fixture",
            connection: "local",
            status: $status,
            healthy: $healthy,
            errors: (if $healthy then 0 else 1 end),
            warnings: 0,
            checks: {
                connectivity: {reachable: $healthy},
                disk_space: {status: $status, usage_percent: null},
                toolchains: {},
                docker: {},
                clock_drift: {}
            },
            checked_at: "2026-07-12T00:00:00Z"
        }'
}

test_cache_init() {
    ((TESTS_RUN+=1))

    _hh_init_cache

    if [[ -d "$DSR_CACHE_DIR/health" ]]; then
        pass "Cache directory created"
    else
        fail "Cache directory not created at $DSR_CACHE_DIR/health"
    fi
}

test_cache_write_and_read() {
    ((TESTS_RUN+=1))

    _hh_init_cache
    local test_data='{"hostname": "test", "healthy": true}'
    _hh_cache_write "testhost" "$test_data"

    local read_data
    read_data=$(_hh_cache_read "testhost")

    if [[ "$read_data" == "$test_data" ]]; then
        pass "Cache write and read works"
    else
        fail "Cache mismatch: expected '$test_data', got '$read_data'"
    fi
}

test_cache_validity() {
    ((TESTS_RUN+=1))

    _hh_init_cache
    _hh_cache_write "freshhost" "$(_test_health_result_json "freshhost" "ok" "true")"

    if _hh_cache_valid "freshhost"; then
        pass "Fresh cache is valid"
    else
        fail "Fresh cache should be valid"
    fi
}

test_cache_rejects_wrong_shape_or_hostname() {
    ((TESTS_RUN+=1))

    _hh_init_cache
    _hh_cache_write "wrongshape" '{"hostname": "wrongshape", "healthy": true}'
    _hh_cache_write "expectedhost" "$(_test_health_result_json "otherhost" "ok" "true")"

    if ! _hh_cache_valid "wrongshape" && ! _hh_cache_valid "expectedhost"; then
        pass "Cache requires the expected health-result shape and hostname"
    else
        fail "Cache should reject incomplete or mismatched health results"
    fi
}

test_cached_unhealthy_result_returns_nonzero() {
    ((TESTS_RUN+=1))

    _hh_init_cache
    _hh_cache_write "cachedunhealthy" "$(_test_health_result_json "cachedunhealthy" "error" "false")"

    local result status=0
    result=$(host_health_check "cachedunhealthy" --json 2>/dev/null) || status=$?

    if [[ $status -ne 0 ]] && echo "$result" | jq -e '.healthy == false and .status == "error"' &>/dev/null; then
        pass "Cached unhealthy result preserves nonzero status"
    else
        fail "Cached unhealthy result should return nonzero, got status=$status result=$result"
    fi
}

test_cache_rejects_invalid_json() {
    ((TESTS_RUN+=1))

    _hh_init_cache
    printf 'x' > "$(_hh_cache_file "invalidhost")"

    if ! _hh_cache_valid "invalidhost"; then
        pass "Fresh cache rejects one-byte invalid JSON"
    else
        fail "Fresh cache should reject one-byte invalid JSON"
    fi
}

test_cache_clear() {
    ((TESTS_RUN+=1))

    _hh_init_cache
    _hh_cache_write "clearme" '{"test": true}'

    host_health_clear_cache "clearme"

    if ! _hh_cache_valid "clearme"; then
        pass "Cache cleared successfully"
    else
        fail "Cache should be invalid after clear"
    fi
}

test_cache_clear_all() {
    ((TESTS_RUN+=1))

    _hh_init_cache
    _hh_cache_write "host1" '{"test": 1}'
    _hh_cache_write "host2" '{"test": 2}'

    host_health_clear_cache

    if ! _hh_cache_valid "host1" && ! _hh_cache_valid "host2"; then
        pass "All cache cleared"
    else
        fail "Not all cache cleared"
    fi
}

# ============================================================================
# Local Host Check Tests
# ============================================================================

test_standalone_source_ignores_caller_script_dir() {
    ((TESTS_RUN+=1))

    local result status=0
    result=$(
        SCRIPT_DIR="$TEMP_DIR/unrelated-caller" \
        DSR_CONFIG_DIR="$DSR_CONFIG_DIR" \
        DSR_CACHE_DIR="$DSR_CACHE_DIR" \
        DSR_STATE_DIR="$DSR_STATE_DIR" \
        bash -c 'source "$1/src/host_health.sh"; _get_ms_timestamp' _ "$PROJECT_ROOT" 2>&1
    ) || status=$?

    if [[ $status -eq 0 && "$result" =~ ^[0-9]+$ ]]; then
        pass "Standalone source resolves dependencies independently of caller SCRIPT_DIR"
    else
        fail "Standalone source should ignore caller SCRIPT_DIR, got status=$status result=$result"
    fi
}

test_local_connectivity() {
    ((TESTS_RUN+=1))

    local result
    result=$(_hh_check_connectivity "testlocal" "local" "")

    if echo "$result" | jq -e '.reachable == true' &>/dev/null; then
        pass "Local connectivity check returns reachable"
    else
        fail "Local connectivity should always be reachable, got: $result"
    fi
}

test_remote_connectivity_handles_bsd_date_literal_nanoseconds() {
    ((TESTS_RUN+=1))

    local result
    result=$(
        (
            date() {
                case "${1:-}" in
                    +%s%3N) printf '1700000000%%3N\n' ;;
                    +%s) printf '1700000000\n' ;;
                    *) command date "$@" ;;
                esac
            }
            python3() { printf '1700000000123\n'; }
            _hh_run_with_timeout() { return 0; }
            _DSR_MS_TIMESTAMP_METHOD=""
            _hh_check_connectivity "testremote" "ssh" "example.invalid"
        )
    )

    if echo "$result" | jq -e '.reachable == true and (.latency_ms | type == "number")' &>/dev/null; then
        pass "Connectivity timing handles BSD date literal nanoseconds"
    else
        fail "Connectivity timing should remain numeric with BSD date, got: $result"
    fi
}

test_remote_health_preserves_caller_stdin() {
    local mode
    for mode in command connectivity; do
        ((TESTS_RUN+=1))
        if printf 'caller-input-must-survive\n' | (
            # Model SSH consuming its input unless explicitly detached. Neither
            # health command requires input from its caller's command stream.
            ssh() {
                local detached=false argument
                for argument in "$@"; do
                    [[ "$argument" != -n ]] || detached=true
                done
                if ! "$detached"; then cat >/dev/null; fi
                printf 'ok\n'
            }
            _hh_run_with_timeout() { shift; "$@"; }
            if [[ "$mode" == command ]]; then
                _hh_exec_on_host test ssh fixture 'echo ok' >/dev/null || exit 1
            else
                _hh_check_connectivity test ssh fixture >/dev/null || exit 1
            fi
            value=''
            IFS= read -r value || exit 1
            [[ "$value" == caller-input-must-survive ]]
        ); then
            pass "Remote health $mode preserves caller stdin"
        else
            fail "Remote health $mode consumed caller stdin"
        fi
    done
}

# Explicit data at the external writable-probe boundary. Classification and
# role/contract admission remain the complete production implementation.
_test_writable_inventory() {
    local root_usage="$1" root_kb="$2" build_usage="$3" build_kb="$4" build_path="${5:-/var/tmp}"
    jq -nc --argjson root_usage "$root_usage" --argjson root_kb "$root_kb" \
        --argjson build_usage "$build_usage" --argjson build_kb "$build_kb" --arg build_path "$build_path" '
        {requested_paths:[],roles:(["root","home","cargo_home","temp","build_root"] | map(
            . as $role | ($role == "build_root") as $build |
            (if $role == "root" then "/" elif $build then $build_path else "/fixture/" + $role end) as $path |
            {role:$role,path:$path,probe_path:$path,filesystem_id:(if $build then "20" else "10" end),
             capacity_group:(if $build then "filesystem:20" else "filesystem:10" end),
             usage_percent:(if $build then $build_usage else $root_usage end),
             available_bytes:((if $build then $build_kb else $root_kb end)*1024),
             total_bytes:4398046511104}))}'
}

test_local_disk_space() {
    ((TESTS_RUN+=1))

    local result
    result=$(_hh_check_disk_space "testlocal" "local" "")

    if echo "$result" | jq -e '.usage_percent' &>/dev/null; then
        pass "Disk space check returns usage_percent"
    else
        fail "Disk space check failed, got: $result"
    fi
}

test_local_disk_space_has_status() {
    ((TESTS_RUN+=1))

    local result
    result=$(_hh_check_disk_space "testlocal" "local" "")
    local status
    status=$(echo "$result" | jq -r '.status')

    if [[ "$status" == "ok" || "$status" == "warning" || "$status" == "error" ]]; then
        pass "Disk space has valid status: $status"
    else
        fail "Disk space invalid status: $status"
    fi
}

test_disk_space_forces_kilobytes_with_512_byte_default() {
    ((TESTS_RUN+=1))

    local result
    # Only the explicit split route still uses df. Its fixture rejects commands
    # without -k, and also supplies the now-required complete writable inventory.
    result=$(_test_unix_split_disk "50 2097152" "50 67108864")

    if echo "$result" | jq -e '.admission == "unix-split-storage-v2" and
        .root.usage_percent == 50 and .root.available_gb == 2 and
        .root.available_bytes == 2147483648 and .root.admitted_as == "error" and
        .status == "error" and (.roles|length) == 5' &>/dev/null; then
        pass "Retained df probes force 1K blocks and preserve the absolute capacity refusal"
    else
        fail "Disk space should report 2 GiB from df -Pk output, got: $result"
    fi
}

test_windows_disk_probe_survives_bash_default_shell() {
    ((TESTS_RUN+=1))

    local result status=0
    result=$(
        (
            powershell() {
                [[ "$1 $2 $3" == '-NoProfile -NonInteractive -EncodedCommand' ]] || return 91
                local script
                script=$(printf '%s' "$4" | base64 -d | iconv -f UTF-16LE -t UTF-8) || return 92
                [[ "$script" == *'$d=Get-CimInstance Win32_LogicalDisk'* &&
                   "$script" == *"DeviceID='C:'"* &&
                   "$script" == *'$d.FreeSpace/$d.Size'* ]] || return 93
                printf '50\r\n2097152\r\n'
            }
            export -f powershell
            _hh_exec_on_host() {
                # A real Bash parse catches the original accidental $d
                # expansion before the PowerShell process receives its argv.
                bash -uc "$4"
            }
            _hh_check_disk_space "testwindows" "ssh" "example.invalid" "windows/amd64" '{"concurrency":1}'
        )
    ) || status=$?

    if [[ $status -eq 0 ]] && echo "$result" | jq -e '.usage_percent == 50 and .available_gb == 2 and
        .available_bytes == 2147483648 and .min_free_bytes == 21474836480 and .status == "error"' &>/dev/null; then
        pass "Windows disk probe preserves PowerShell variables and refuses capacity below its floor"
    else
        fail "Windows disk probe failed through Bash: status=$status result=$result"
    fi
}

test_disk_space_rejects_non_numeric_fields() {
    ((TESTS_RUN+=1))

    local result status=0
    result=$(
        (
            _hh_exec_on_host() {
                [[ "$4" == *DSR_UNIX_WRITABLE_PY* ]] || return 91
                _test_writable_inventory 50 67108864 50 67108864 |
                    jq '.roles[0].available_bytes="invalid"'
            }
            _hh_check_disk_space "testlocal" "local" ""
        )
    ) || status=$?

    if [[ $status -ne 0 ]] && echo "$result" | jq -e '.status == "error" and .available_gb == null and
        .error == "Invalid writable storage inventory or free-space policy"' &>/dev/null; then
        pass "Disk space rejects non-numeric fields"
    else
        fail "Disk space should reject non-numeric fields, got status=$status result=$result"
    fi
}

test_windows_disk_capacity_boundaries() {
    # Controlled transport output exercises the real scalar admission path;
    # this is not native PowerShell or Windows filesystem qualification.
    local usage available expected result status
    while read -r usage available expected; do
        ((TESTS_RUN+=1))
        status=0
        result=$(
            (
                _hh_exec_on_host() {
                    [[ "$4" == 'powershell -NoProfile -NonInteractive -EncodedCommand '* ]] || return 91
                    printf '%s\r\n%s\r\n' "$usage" "$available"
                }
                _hh_check_disk_space "testwindows" "ssh" "example.invalid" "windows/amd64" '{"concurrency":1}'
            )
        ) || status=$?
        if [[ $status -eq 0 ]] && jq -e --arg expected "$expected" --argjson usage "$usage" --argjson kb "$available" '
            .status == $expected and .usage_percent == $usage and
            .available_bytes == ($kb*1024) and .min_free_bytes == 21474836480 and
            (if $expected == "error" then .available_gb == 20 and
                (.error|contains("20 GiB floor")) else .error == null end)
        ' <<< "$result" >/dev/null; then
            pass "Windows scalar capacity: $usage percent and $available KiB produces $expected"
        else
            fail "Windows scalar capacity: $usage percent and $available KiB: $result"
        fi
    done <<'CASES'
96 187695104 warning
100 20971520 warning
90 20971520 ok
96 20971519 error
CASES
}

test_concurrent_disk_capacity() {
    # Exercise all three decisions with the same external observations. The
    # 179 GiB/96% case must pass for eight 20 GiB slots but refuse nine, and
    # five writable role aliases must not turn two slots into ten budgets.
    local usage available slots minimum expected platform result status scalar
    while read -r usage available slots minimum expected; do
        ((TESTS_RUN+=1))
        scalar=$(_hh_disk_status "$usage" "$available" 21474836480 "$slots")
        if [[ "$scalar" == "$expected" ]]; then
            pass "Raw disk status admits $slots slots at $available KiB as $expected"
        else
            fail "Raw disk status for $slots slots: $scalar, expected $expected"
        fi
        for platform in linux/amd64 windows/amd64; do
            ((TESTS_RUN+=1))
            status=0
            result=$(
                config_unix_storage_json() { return 1; }
                config_windows_storage_json() { return 1; }
                _hh_exec_on_host() {
                    if [[ "$4" == *DSR_UNIX_WRITABLE_PY* ]]; then
                        _test_writable_inventory "$usage" "$available" "$usage" "$available"
                    elif [[ "$4" == 'powershell -NoProfile -NonInteractive -EncodedCommand '* ]]; then
                        printf '%s\r\n%s\r\n' "$usage" "$available"
                    else
                        return 91
                    fi
                }
                _hh_check_disk_space concurrent local '' "$platform" "{\"concurrency\":$slots}"
            ) || status=$?
            if [[ $status -eq 0 ]] && jq -e --arg expected "$expected" --argjson minimum "$minimum" \
                --argjson slots "$slots" --argjson usage "$usage" '
                .status == $expected and .min_free_bytes == $minimum and .concurrent_builds == $slots and
                .usage_percent == $usage and
                (if .roles != null then all(.roles[]; .status == $expected and .min_free_bytes == $minimum)
                 else true end)
            ' <<< "$result" >/dev/null; then
                pass "$platform admits $slots concurrent builds at $available KiB as $expected"
            else
                fail "$platform concurrent disk admission: status=$status result=$result"
            fi
        done
    done <<'CASES'
96 187695104 2 42949672960 warning
96 187695104 8 171798691840 warning
96 187695104 9 193273528320 error
50 41943039 2 42949672960 error
50 41943040 2 42949672960 ok
100 41943040 2 42949672960 warning
90 20971520 1 21474836480 ok
91 20971520 1 21474836480 warning
CASES
}

test_default_disk_concurrency_matches_scheduler() {
    local fixture="$TEMP_DIR/default-disk-concurrency.yaml" result platform available expected status=0
    printf 'hosts:\n  defaultlimit:\n    platform: linux/amd64\n    connection: local\n' > "$fixture"
    ((TESTS_RUN+=1))
    result=$(
        source "$PROJECT_ROOT/src/host_selector.sh"
        selector=$(_sel_limit_from_config defaultlimit '{"hosts":{"defaultlimit":{"platform":"linux/amd64","connection":"local"}}}') || exit 1
        normalized=$(_hh_normalize_host_config defaultlimit '{"platform":"linux/amd64","connection":"local"}') || exit 1
        fallback=$(DSR_HOSTS_FILE="$fixture" _hh_parse_host_fallback defaultlimit) || exit 1
        [[ "$selector" == 2 && "$(_hh_disk_concurrency '{}')" == "$selector" ]] || exit 1
        jq -e --argjson selected "$selector" '.concurrency == $selected' <<< "$normalized" >/dev/null &&
            jq -e --argjson selected "$selector" '.concurrency == $selected' <<< "$fallback" >/dev/null
    ) || status=$?
    if [[ $status -eq 0 ]]; then
        pass "Host normalization, fallback parsing and disk admission share the scheduler default of two builds"
    else
        fail "Disk concurrency defaults diverged from the production scheduler: $result"
    fi

    for platform in linux/amd64 windows/amd64; do
        while read -r available expected; do
            ((TESTS_RUN+=1))
            result=$(
                config_unix_storage_json() { return 1; }
                config_windows_storage_json() { return 1; }
                _hh_exec_on_host() {
                    if [[ "$4" == *DSR_UNIX_WRITABLE_PY* ]]; then
                        _test_writable_inventory 50 "$available" 50 "$available"
                    else
                        printf '50\r\n%s\r\n' "$available"
                    fi
                }
                _hh_check_disk_space defaultlimit local '' "$platform" '{}'
            )
            if jq -e --arg expected "$expected" '.status == $expected and
                .concurrent_builds == 2 and .min_free_bytes == 42949672960' <<< "$result" >/dev/null; then
                pass "$platform without an explicit slot limit requires 40 GiB: $available KiB is $expected"
            else
                fail "$platform default disk requirement: $result"
            fi
        done <<'CASES'
20971520 error
41943040 ok
CASES
    done
}

test_shared_apfs_concurrent_capacity() {
    local inventory result mode slots expected available quota
    # The two APFS volumes share one pool. Capacity cannot be summed across
    # their filesystem IDs, and a volume quota remains an independent limit.
    while read -r mode available slots expected quota; do
        ((TESTS_RUN+=1))
        inventory=$(_test_writable_inventory 96 "$available" 96 "$available" | jq \
            --argjson quota "$quota" '
            .roles |= map(.usage_percent=(((.total_bytes-.available_bytes)*100/.total_bytes)|ceil) | . + {
                filesystem_available_bytes:.available_bytes,
                filesystem_total_bytes:.total_bytes,
                capacity_group:"apfs:12345678-1234-1234-1234-123456789abc",
                apfs:{container_id:"disk3",container_uuid:"12345678-1234-1234-1234-123456789abc",
                      volume_id:(if .role == "build_root" then "disk3s5" else "disk3s1" end),
                      available_bytes:.available_bytes,total_bytes:.total_bytes,
                      used_bytes:0,quota_bytes:0,reserve_bytes:0}}
                | if .role == "cargo_home" and $quota > 0 then
                    .filesystem_id="30" | .apfs.volume_id="disk3s7" |
                    .apfs.quota_bytes=$quota | .available_bytes=([.available_bytes,$quota]|min) |
                    .total_bytes=$quota
                  else . end)')
        result=$(_hh_writable_storage_verdict null '[]' "$slots" <<< "$inventory")
        if jq -e --arg expected "$expected" --argjson slots "$slots" --argjson kb "$available" \
            --argjson quota "$quota" '
            .status == $expected and .concurrent_builds == $slots and
            (.roles|length) == 5 and (.capacity_groups|length) == 1 and
            .capacity_groups[0].apfs_container.available_bytes == ($kb*1024) and
            (if $quota > 0 then
                [.roles[]|select(.role == "cargo_home")][0].available_bytes == $quota
             else .capacity_groups[0].available_bytes == ($kb*1024) end)
        ' <<< "$result" >/dev/null; then
            pass "Shared APFS $mode: $slots builds receive one pool and retain volume quota limits"
        else
            fail "Shared APFS $mode admission: $result"
        fi
    done <<'CASES'
large-warning 187695104 8 warning 0
insufficient-for-nine 187695104 9 error 0
shared-space-not-summed 52428800 3 error 0
role-aliases-not-multiplied 52428800 2 warning 0
separate-volume-quota 187695104 2 error 32212254720
exact-quota-boundary 187695104 2 warning 42949672960
CASES

    ((TESTS_RUN+=1))
    inventory=$(jq '.roles[0].apfs.available_bytes += 1024' <<< "$inventory")
    if _hh_writable_storage_verdict null '[]' 2 <<< "$inventory" >/dev/null 2>&1; then
        fail "Conflicting observations of shared APFS capacity were admitted"
    else
        pass "Concurrent admission refuses conflicting observations of one APFS container"
    fi
}

_test_windows_capacity_contract() {
    jq -nc --argjson target_minimum "${1:-21474836480}" '
        {drive:"R",source_drive:"C",server:"192.0.2.1",export:"/owned/builds",
         source_budget_bytes:2147483648,source_reserve_bytes:8589934592,
         target_min_free_bytes:$target_minimum}'
}

test_windows_split_concurrent_capacity() {
    # Real production script generation and controller validation, with
    # controlled transport observations. Native Win32/PowerShell execution is
    # covered separately; no native-runtime qualification is claimed here.
    local slots contract_minimum available required expected result status script counter=0
    while read -r slots contract_minimum available required expected; do
        ((TESTS_RUN+=1))
        counter=$((counter+1))
        script="$TEMP_DIR/windows-concurrent-storage-$counter.ps1"
        status=0
        result=$(
            config_windows_storage_json() { _test_windows_capacity_contract "$contract_minimum"; }
            _hh_exec_on_host() {
                local payload
                payload="${4#*FromBase64String(\'}"
                payload="${payload%%\'*}"
                printf '%s' "$payload" | base64 -d | gzip -d > "$script" || return 91
                jq -nc --argjson available "$available" '
                    {admission:"split-storage-role-budgets-v1",status:"warning",
                     lock_range:"cargo-win32-whole-u64-v1",target:{free_bytes:$available}}'
            }
            _hh_check_disk_space concurrent ssh fixture windows/amd64 "{\"concurrency\":$slots}"
        ) || status=$?
        if [[ -f "$script" ]] &&
           grep -Fq "FreeSpace -lt [long]$required) { throw 'DSR concurrent target capacity admission failed'" "$script" &&
           grep -Fq 'DSR NFS mapping identity mismatch' "$script" &&
           grep -Fq 'DSR Cargo whole-u64 lock exclusion failed' "$script" &&
           jq -e --arg expected "$expected" --argjson minimum "$required" --argjson slots "$slots" '
               .status == $expected and
               (if $expected == "error" then .error != null
                else .concurrent_builds == $slots and .target.min_free_bytes == $minimum and
                     .storage_contract.source_budget_bytes == 2147483648 and
                     .storage_contract.source_reserve_bytes == 8589934592 end)
           ' <<< "$result" >/dev/null &&
           { [[ "$expected" == error && $status -ne 0 ]] || [[ "$expected" == warning && $status -eq 0 ]]; }; then
            pass "Windows split target for $slots builds enforces max(contract, concurrent floor)=$required"
        else
            fail "Windows split concurrent capacity: status=$status result=$result"
        fi
    done <<'CASES'
2 21474836480 42949672960 42949672960 warning
2 21474836480 42949672959 42949672960 error
2 64424509440 64424509440 64424509440 warning
2 64424509440 64424509439 64424509440 error
8 21474836480 192199786496 171798691840 warning
9 21474836480 192199786496 193273528320 error
2 21474836480 null 42949672960 error
2 21474836480 "42949672960" 42949672960 error
CASES
}

test_invalid_disk_concurrency() {
    local slots platform result status marker counter=0
    for slots in 0 -1 1.5 false '"2"' '[]' '{}' 419431 9007199254740991; do
        for platform in linux/amd64 windows/amd64 windows/split; do
            ((TESTS_RUN+=1))
            counter=$((counter+1))
            marker="$TEMP_DIR/invalid-concurrency-transport-$counter"
            status=0
            result=$(
                config_unix_storage_json() { return 1; }
                config_windows_storage_json() {
                    [[ "$platform" == windows/split ]] || return 1
                    _test_windows_capacity_contract
                }
                _hh_exec_on_host() { printf 'transport was invoked\n' >> "$marker"; return 91; }
                _hh_check_disk_space concurrent local '' "$platform" "{\"concurrency\":$slots}"
            ) || status=$?
            if [[ $status -ne 0 && ! -e "$marker" ]] && jq -e '.status == "error" and
                .error == "Invalid disk concurrency or overflowing free-space requirement"' <<< "$result" >/dev/null; then
                pass "$platform refuses unsafe concurrency $slots before probing storage"
            else
                fail "$platform unsafe concurrency $slots: status=$status result=$result"
            fi
        done
    done

    local fixture="$TEMP_DIR/invalid-fallback-concurrency.yaml"
    for slots in 0 -1 2suffix 1.5 false; do
        ((TESTS_RUN+=1))
        printf 'hosts:\n  concurrent:\n    platform: linux/amd64\n    connection: local\n    concurrency: %s\n' "$slots" > "$fixture"
        if (export DSR_HOSTS_FILE="$fixture"; raw=$(_hh_parse_host_fallback concurrent) &&
            _hh_normalize_host_config concurrent "$raw") >/dev/null 2>&1; then
            fail "Fallback parser admitted unsafe concurrency $slots"
        else
            pass "Fallback parser refuses unsafe concurrency $slots"
        fi
    done
}

test_disk_space_rejects_numeric_output_from_failed_command() {
    ((TESTS_RUN+=1))

    local result status=0
    result=$(
        (
            _hh_exec_on_host() {
                [[ "$4" == *DSR_UNIX_WRITABLE_PY* ]] || return 91
                _test_writable_inventory 50 67108864 50 67108864
                return 23
            }
            _hh_check_disk_space "testlocal" "local" ""
        )
    ) || status=$?

    if [[ $status -ne 0 ]] && echo "$result" | jq -e '.status == "error" and
        (.error|startswith("Required writable storage probe failed"))' &>/dev/null; then
        pass "Disk space preserves command failure despite numeric stdout"
    else
        fail "Disk space should fail when command returns nonzero, got status=$status result=$result"
    fi
}

test_human_disk_error_reports_probe_failure() {
    ((TESTS_RUN+=1))

    local result output
    result='{"hostname":"testlocal","platform":"linux/amd64","status":"error","healthy":false,"checks":{"connectivity":{"reachable":true},"disk_space":{"status":"error","usage_percent":null,"error":"Disk probe timed out"},"toolchains":{}}}'
    output=$(_hh_print_result "testlocal" "$result" 2>&1)

    if [[ "$output" == *"Disk probe timed out"* && "$output" != *"Disk usage >"* ]]; then
        pass "Human disk error reports the recorded probe failure"
    else
        fail "Human disk error should report recorded failure, got: $output"
    fi
}

test_local_toolchains_check() {
    ((TESTS_RUN+=1))

    local result
    result=$(_hh_check_toolchains "testlocal" "local" "" "rust go docker")

    # Should at least return valid JSON with the capability keys
    if echo "$result" | jq -e 'keys | length > 0' &>/dev/null; then
        pass "Toolchain check returns valid JSON"
    else
        fail "Toolchain check failed, got: $result"
    fi
}

test_local_clock_drift() {
    ((TESTS_RUN+=1))

    local result
    result=$(_hh_check_clock_drift "testlocal" "local" "")

    if echo "$result" | jq -e '.drift_seconds == 0' &>/dev/null; then
        pass "Local clock drift is 0"
    else
        fail "Local clock drift should be 0, got: $result"
    fi
}

# ============================================================================
# Full Host Health Check Tests
# ============================================================================

test_health_check_local_host() {
    ((TESTS_RUN+=1))

    # Clear any cached result first
    host_health_clear_cache "testlocal"

    local result
    result=$(host_health_check "testlocal" --no-cache --json 2>/dev/null)

    if echo "$result" | jq -e '.hostname == "testlocal"' &>/dev/null; then
        pass "Health check returns correct hostname"
    else
        fail "Health check hostname mismatch, got: $result"
    fi
}

test_health_check_returns_healthy_for_local() {
    ((TESTS_RUN+=1))

    host_health_clear_cache "testlocal"

    local result
    result=$(host_health_check "testlocal" --no-cache --json 2>/dev/null)

    if echo "$result" | jq -e '.healthy == true' &>/dev/null; then
        pass "Local host is healthy"
    else
        fail "Local host should be healthy, got: $(echo "$result" | jq '.healthy, .status')"
    fi
}

test_health_check_has_all_checks() {
    ((TESTS_RUN+=1))

    host_health_clear_cache "testlocal"

    local result
    result=$(host_health_check "testlocal" --no-cache --json 2>/dev/null)

    local has_connectivity has_disk has_toolchains has_clock
    has_connectivity=$(echo "$result" | jq -e '.checks.connectivity' &>/dev/null && echo "yes" || echo "no")
    has_disk=$(echo "$result" | jq -e '.checks.disk_space' &>/dev/null && echo "yes" || echo "no")
    has_toolchains=$(echo "$result" | jq -e '.checks.toolchains' &>/dev/null && echo "yes" || echo "no")
    has_clock=$(echo "$result" | jq -e '.checks.clock_drift' &>/dev/null && echo "yes" || echo "no")

    if [[ "$has_connectivity" == "yes" && "$has_disk" == "yes" && "$has_toolchains" == "yes" && "$has_clock" == "yes" ]]; then
        pass "Health check has all check categories"
    else
        fail "Missing checks: connectivity=$has_connectivity disk=$has_disk toolchains=$has_toolchains clock=$has_clock"
    fi
}

test_health_check_unknown_host() {
    ((TESTS_RUN+=1))

    local result
    result=$(host_health_check "nonexistent_host_xyz" --json 2>/dev/null)

    if echo "$result" | jq -e '.healthy == false' &>/dev/null; then
        pass "Unknown host returns unhealthy"
    else
        fail "Unknown host should be unhealthy, got: $result"
    fi
}

test_health_check_unreachable_host() {
    ((TESTS_RUN+=1))

    # testremote is configured with a nonexistent SSH host
    host_health_clear_cache "testremote"

    local result
    # This should timeout/fail since the host doesn't exist
    result=$(host_health_check "testremote" --no-cache --json 2>/dev/null)

    if echo "$result" | jq -e '.healthy == false' &>/dev/null; then
        pass "Unreachable host returns unhealthy"
    else
        fail "Unreachable host should be unhealthy, got: $result"
    fi
}

# ============================================================================
# Check All Hosts Tests
# ============================================================================

test_health_check_all_returns_summary() {
    ((TESTS_RUN+=1))

    local result
    result=$(host_health_check_all --json 2>/dev/null)

    if echo "$result" | jq -e '.summary.total > 0' &>/dev/null; then
        pass "Check all returns summary with total"
    else
        fail "Check all should have summary, got: $result"
    fi
}

test_health_check_all_has_hosts_array() {
    ((TESTS_RUN+=1))

    local result
    result=$(host_health_check_all --json 2>/dev/null)

    if echo "$result" | jq -e '.hosts | type == "array"' &>/dev/null; then
        pass "Check all has hosts array"
    else
        fail "Check all should have hosts array, got: $result"
    fi
}

# ============================================================================
# Healthy Hosts Tests
# ============================================================================

test_get_healthy_hosts() {
    ((TESTS_RUN+=1))

    local result
    result=$(host_health_get_healthy_hosts --json 2>/dev/null)

    # Should be a valid JSON array
    if echo "$result" | jq -e 'type == "array"' &>/dev/null; then
        pass "get_healthy_hosts returns array"
    else
        fail "get_healthy_hosts should return array, got: $result"
    fi
}

test_get_healthy_hosts_includes_local() {
    ((TESTS_RUN+=1))

    host_health_clear_cache "testlocal"

    local result
    result=$(host_health_get_healthy_hosts --json 2>/dev/null)

    if echo "$result" | jq -e 'map(select(. == "testlocal")) | length > 0' &>/dev/null; then
        pass "Healthy hosts includes testlocal"
    else
        fail "Healthy hosts should include testlocal, got: $result"
    fi
}

# ============================================================================
# Host Readiness Tests
# ============================================================================

test_host_is_ready_local() {
    ((TESTS_RUN+=1))

    host_health_clear_cache "testlocal"

    if host_health_is_ready "testlocal"; then
        pass "testlocal is ready"
    else
        fail "testlocal should be ready"
    fi
}

test_host_is_ready_unreachable() {
    ((TESTS_RUN+=1))

    host_health_clear_cache "testremote"

    if ! host_health_is_ready "testremote"; then
        pass "Unreachable host is not ready"
    else
        fail "Unreachable host should not be ready"
    fi
}

test_host_is_ready_unknown() {
    ((TESTS_RUN+=1))

    if ! host_health_is_ready "completely_unknown_host"; then
        pass "Unknown host is not ready"
    else
        fail "Unknown host should not be ready"
    fi
}

# ============================================================================
# Fallback Parser Tests
# ============================================================================

test_fallback_parser_basic() {
    ((TESTS_RUN+=1))

    local result
    result=$(_hh_parse_host_fallback "testlocal")

    if echo "$result" | jq -e '.platform == "linux/amd64"' &>/dev/null; then
        pass "Fallback parser extracts platform"
    else
        fail "Fallback parser should extract platform, got: $result"
    fi
}

test_fallback_parser_connection() {
    ((TESTS_RUN+=1))

    local result
    result=$(_hh_parse_host_fallback "testlocal")

    if echo "$result" | jq -e '.connection == "local"' &>/dev/null; then
        pass "Fallback parser extracts connection type"
    else
        fail "Fallback parser should extract connection, got: $result"
    fi
}

test_fallback_parser_capabilities() {
    ((TESTS_RUN+=1))

    local result
    result=$(_hh_parse_host_fallback "testlocal")
    local caps
    caps=$(echo "$result" | jq -r '.capabilities')

    if [[ "$caps" == *"rust"* ]] && [[ "$caps" == *"go"* ]]; then
        pass "Fallback parser extracts capabilities"
    else
        fail "Fallback parser should extract capabilities, got: $caps"
    fi
}

test_fallback_parser_unknown_host() {
    ((TESTS_RUN+=1))

    if ! _hh_parse_host_fallback "this_host_does_not_exist" &>/dev/null; then
        pass "Fallback parser returns error for unknown host"
    else
        fail "Fallback parser should fail for unknown host"
    fi
}

test_fallback_list_hosts() {
    ((TESTS_RUN+=1))

    local hosts
    hosts=$(_hh_list_hosts_fallback | tr '\n' ' ')

    if [[ "$hosts" == *"testlocal"* ]] && [[ "$hosts" == *"testremote"* ]]; then
        pass "Fallback list returns all hosts"
    else
        fail "Fallback list should find both hosts, got: $hosts"
    fi
}

# ============================================================================
# Threshold Tests
# ============================================================================

test_disk_threshold_values() {
    ((TESTS_RUN+=1))

    # Verify thresholds are set
    if [[ $_HH_DISK_WARN_THRESHOLD -eq 90 ]] && [[ $_HH_DISK_MIN_FREE_BYTES -eq 21474836480 ]]; then
        pass "Disk thresholds have expected defaults"
    else
        fail "Disk thresholds: warn=$_HH_DISK_WARN_THRESHOLD min_free_bytes=$_HH_DISK_MIN_FREE_BYTES"
    fi
}

test_ssh_timeout_value() {
    ((TESTS_RUN+=1))

    if [[ $_HH_SSH_TIMEOUT -eq 10 ]]; then
        pass "SSH timeout has expected default (10s)"
    else
        fail "SSH timeout should be 10, got: $_HH_SSH_TIMEOUT"
    fi
}

test_cache_ttl_value() {
    ((TESTS_RUN+=1))

    if [[ $_HH_CACHE_TTL -eq 300 ]]; then
        pass "Cache TTL has expected default (300s)"
    else
        fail "Cache TTL should be 300, got: $_HH_CACHE_TTL"
    fi
}

# ============================================================================
# Retry Logic Integration Tests
# ============================================================================

# Source build_state for retry tests
source "$PROJECT_ROOT/src/build_state.sh"

test_retry_backoff_calculation() {
    ((TESTS_RUN+=1))

    # shellcheck disable=SC2034  # Variable used by sourced module
    BUILD_RETRY_BASE_DELAY=1
    local delay0 delay1 delay2
    delay0=$(_build_calc_backoff 0)
    delay1=$(_build_calc_backoff 1)
    delay2=$(_build_calc_backoff 2)

    # Exponential: 1*2^0=1, 1*2^1=2, 1*2^2=4 (plus some jitter)
    if [[ "$delay0" -ge 1 ]] && [[ "$delay1" -ge "$delay0" ]] && [[ "$delay2" -ge "$delay1" ]]; then
        pass "Backoff calculation increases correctly"
    else
        fail "Backoff should increase: got $delay0, $delay1, $delay2"
    fi

    # shellcheck disable=SC2034  # Variable used by sourced module
    BUILD_RETRY_BASE_DELAY=5
}

test_retry_max_delay_cap() {
    ((TESTS_RUN+=1))

    BUILD_RETRY_BASE_DELAY=100
    BUILD_RETRY_MAX_DELAY=200
    local delay
    delay=$(_build_calc_backoff 5)  # 100 * 2^5 = 3200, should cap at 200

    if [[ "$delay" -le 250 ]]; then  # Allow some jitter margin
        pass "Backoff respects max delay cap"
    else
        fail "Backoff exceeded max: got $delay, max was $BUILD_RETRY_MAX_DELAY"
    fi

    BUILD_RETRY_BASE_DELAY=5
    BUILD_RETRY_MAX_DELAY=300
}

test_retry_with_success() {
    ((TESTS_RUN+=1))

    BUILD_RETRY_BASE_DELAY=0
    local attempt=0
    succeed_after_two() { ((attempt+=1)); [[ $attempt -ge 2 ]]; }

    if build_retry_with_backoff 3 succeed_after_two 2>/dev/null; then
        pass "Retry succeeds after transient failure"
    else
        fail "Retry should succeed when command eventually passes"
    fi

    # shellcheck disable=SC2034  # Variable used by sourced module
    BUILD_RETRY_BASE_DELAY=5
}

test_retry_state_recording() {
    ((TESTS_RUN+=1))

    build_state_init
    # shellcheck disable=SC2034  # run_id captured for debugging
    DSR_RUN_ID="test-retry-$$" build_state_create "retry-test" "v1.0.0" "trj" >/dev/null 2>&1

    build_state_update_host "retry-test" "v1.0.0" "trj" "running"
    build_state_record_retry "retry-test" "v1.0.0" "trj" 1 "SSH timeout"

    local count
    count=$(build_state_get_retry_count "retry-test" "v1.0.0" "trj")

    if [[ "$count" -eq 1 ]]; then
        pass "Retry attempt is recorded in state"
    else
        fail "Retry count should be 1, got: $count"
    fi
}

test_retry_limit_enforcement() {
    ((TESTS_RUN+=1))

    build_state_init
    DSR_RUN_ID="test-limit-$$" build_state_create "limit-test" "v1.0.0" "trj" >/dev/null 2>&1
    build_state_update_host "limit-test" "v1.0.0" "trj" "running"

    BUILD_RETRY_MAX=2
    build_state_record_retry "limit-test" "v1.0.0" "trj" 1 "error"
    build_state_record_retry "limit-test" "v1.0.0" "trj" 2 "error"

    if ! build_state_can_retry "limit-test" "v1.0.0" "trj"; then
        pass "Retry limit is enforced"
    else
        fail "Should not be able to retry after exceeding limit"
    fi

    # shellcheck disable=SC2034  # Variable used by sourced module
    BUILD_RETRY_MAX=3
}

test_resume_plan_generation() {
    ((TESTS_RUN+=1))

    build_state_init
    DSR_RUN_ID="test-resume-$$" build_state_create "resume-test" "v1.0.0" "trj,mmini" >/dev/null 2>&1
    build_state_update_status "resume-test" "v1.0.0" "running"
    build_state_update_host "resume-test" "v1.0.0" "trj" "completed"
    build_state_update_host "resume-test" "v1.0.0" "mmini" "failed"

    local plan
    plan=$(build_state_resume "resume-test" "v1.0.0")

    if echo "$plan" | jq -e '.can_resume == true' &>/dev/null; then
        local hosts_to_process
        hosts_to_process=$(echo "$plan" | jq -r '.hosts_to_process | length')
        if [[ "$hosts_to_process" -ge 1 ]]; then
            pass "Resume plan identifies hosts to process"
        else
            fail "Resume plan should have hosts to process"
        fi
    else
        fail "Resume should be possible for failed build, got: $plan"
    fi
}

test_health_check_with_retry_context() {
    ((TESTS_RUN+=1))

    # Test that health check results can be used in retry context
    build_state_init
    DSR_RUN_ID="test-health-retry-$$" build_state_create "health-retry" "v1.0.0" "testlocal" >/dev/null 2>&1

    host_health_clear_cache "testlocal"
    local health_result
    health_result=$(host_health_check "testlocal" --no-cache --json 2>/dev/null)

    local healthy
    healthy=$(echo "$health_result" | jq -r '.healthy')

    if [[ "$healthy" == "true" ]]; then
        build_state_update_host "health-retry" "v1.0.0" "testlocal" "completed"
        local state
        state=$(build_state_get "health-retry" "v1.0.0")
        local host_status
        host_status=$(echo "$state" | jq -r '.hosts.testlocal.status')

        if [[ "$host_status" == "completed" ]]; then
            pass "Health check integrates with build state"
        else
            fail "Build state should show completed, got: $host_status"
        fi
    else
        fail "testlocal should be healthy"
    fi
}

# ============================================================================
# Run All Tests
# ============================================================================

run_powershell_program() {
    local program
    program=$(cat) || return 1
    # -Command - reads through the stdin host, which emits terminal controls
    # and can resume after a terminating error. Pass one complete program.
    pwsh -NoLogo -NoProfile -NonInteractive -Command "$program"
}

test_powershell_program_failure() {
    local result status=0
    ((TESTS_RUN+=1))
    if ! command -v pwsh >/dev/null; then
        fail "PowerShell is required to verify terminating-error propagation"
        return
    fi
    result=$(run_powershell_program 2> "$TEMP_DIR/powershell-program-error" <<'POWERSHELL'
Write-Output 'BEFORE_ERROR'
throw 'DSR_TEST_TERMINATING_ERROR'
Write-Output 'UNREACHABLE'
POWERSHELL
    ) || status=$?
    result=$(printf '%s' "$result" | tr -d '\r')
    if [[ $status -ne 0 && "$result" == BEFORE_ERROR ]] &&
        grep -q 'DSR_TEST_TERMINATING_ERROR' "$TEMP_DIR/powershell-program-error"; then
        pass "Complete PowerShell program preserves terminating errors and exact output"
    else
        fail "PowerShell terminating error: status=$status result=$result"
    fi
}

test_windows_split_storage_admission() {
    local mode script result expected status
    if ! command -v pwsh >/dev/null; then
        ((TESTS_RUN+=1))
        fail "PowerShell is required to execute Windows storage admission tests"
        return
    fi
    script=$(
        config_windows_storage_json() {
            printf '%s' '{"drive":"R","source_drive":"C","server":"192.0.2.1","export":"/owned/builds","source_budget_bytes":2147483648,"source_reserve_bytes":8589934592,"target_min_free_bytes":21474836480}'
        }
        config_windows_storage_session_script fixture
    )
    for mode in valid wrong_mapping low_source low_target unavailable; do
        ((TESTS_RUN+=1))
        case "$mode" in
            valid) expected='ADMITTED:0' ;;
            wrong_mapping) expected='DSR NFS mapping identity mismatch:0' ;;
            low_source) expected='DSR source/cache capacity admission failed:0' ;;
            low_target) expected='DSR target capacity admission failed:0' ;;
            unavailable) expected='DSR NFS mount failed:1' ;;
        esac
        status=0
        result=$(
            {
                printf "\$mode='%s';\n" "$mode"
                cat <<'POWERSHELL'
$global:mountCalls=0
$env:SystemRoot='/fixture'
$env:CARGO_HOME='C:/cargo'
function Get-Item { return [pscustomobject]@{PSIsContainer=$true;Attributes=16;Parent=$null} }
function Get-CimInstance {
    param($ClassName,$Filter)
    if ($Filter -eq "DeviceID='C:'") {
        $free=if($mode -eq 'low_source'){9GB}else{12GB}
        return [pscustomobject]@{DeviceID='C:';DriveType=3;FileSystem='NTFS';FreeSpace=$free;Size=500GB}
    }
    if($mode -eq 'unavailable'){return $null}
    $provider=if($mode -eq 'wrong_mapping'){'\wrongoreign'}else{'\\192.0.2.1\owned\builds'}
    $free=if($mode -eq 'low_target'){19GB}else{100GB}
    return [pscustomobject]@{DeviceID='R:';DriveType=4;FileSystem='NFS';ProviderName=$provider;FreeSpace=$free;Size=500GB}
}
function Get-PSDrive { param($Name); return $null }
function Join-Path { param($Path,$ChildPath); return 'Invoke-TestMount' }
function Invoke-TestMount { $global:mountCalls++; $global:LASTEXITCODE=53 }
try {
POWERSHELL
                printf '%s\n' "$script"
                printf '%s\n' 'Write-Output ("ADMITTED:"+$global:mountCalls)' '} catch { Write-Output ($_.Exception.Message+":"+$global:mountCalls) }'
                printf '\n'
            } | run_powershell_program
        ) || status=$?
        result=$(printf '%s' "$result" | tr -d '\r')
        if [[ $status -eq 0 && "$result" == "$expected" ]]; then
            pass "Windows split-storage $mode admission executes expected branch"
        else
            fail "Windows split-storage $mode: status=$status result=$result expected=$expected"
        fi
    done
}

test_windows_storage_transport() {
    local command result status=0 expected
    command=$(cat <<'POWERSHELL' | _hh_windows_storage_command
$marker='DSR-界-é'
Write-Output $marker
Write-Output 'literal $HOME ` " ; & Write-Output EXTRA_COMMAND'
POWERSHELL
    ) || status=$?
    expected=$'DSR-界-é\nliteral $HOME ` " ; & Write-Output EXTRA_COMMAND'
    ((TESTS_RUN+=1))
    result=$(
        powershell() {
            [[ $# -eq 4 && "$1 $2 $3" == '-NoProfile -NonInteractive -Command' ]] || return 91
            pwsh -NoLogo "$@"
        }
        export -f powershell
        # A real shell parse must preserve exactly one PowerShell command,
        # which itself decompresses and executes the original Unicode script.
        bash -uc "$command"
    ) || status=$?
    result=$(printf '%s' "$result" | tr -d '\r')
    if [[ $status -eq 0 && "$result" == "$expected" ]]; then
        pass "Storage transport preserves Unicode and multiline shell literals through Bash and PowerShell"
    else
        fail "Storage transport status=$status result=$result"
    fi
    ((TESTS_RUN+=1))
    status=0
    result=$(printf 'Write-Output "row-%s"\n' {1..6000} | _hh_windows_storage_command) || status=$?
    if [[ $status -eq 4 && -z "$result" ]]; then pass "Overlong storage command refuses before transport";
    else fail "Overlong storage command status=$status output_bytes=${#result}"; fi
    ((TESTS_RUN+=1))
    status=0
    result=$(
        config_windows_storage_json() {
            printf '%s' '{"drive":"R","source_drive":"C","server":"192.0.2.1","export":"/owned/builds","source_budget_bytes":2147483648,"source_reserve_bytes":8589934592,"target_min_free_bytes":21474836480}'
        }
        _hh_exec_on_host() {
            [[ ${#4} -lt 7000 && "$4" == 'powershell -NoProfile -NonInteractive -Command "& '* ]] || return 91
            # Transport-size control only; native admission is exercised by
            # the separate parent/child primitive controls and Windows probe.
            printf '%s' '{"admission":"split-storage-role-budgets-v1","status":"ok","lock_range":"cargo-win32-whole-u64-v1","target":{"free_bytes":42949672960}}'
        }
        _hh_check_disk_space fixture ssh example.invalid windows/amd64 '{"concurrency":2}'
    ) || status=$?
    if [[ $status -eq 0 ]] && jq -e '.lock_range=="cargo-win32-whole-u64-v1"' <<< "$result" >/dev/null; then
        pass "Complete Win32 storage probe fits the unchanged transport limit"
    else fail "Complete Win32 storage transport refused: status=$status result=$result"; fi
}

test_windows_cargo_lock_range() {
    local script mode result status expected model="$TEMP_DIR/lock-model.ps1"
    local storage_fixture="$TEMP_DIR/lock-storage.yaml"
    cat > "$storage_fixture" <<'YAML'
hosts:
  lockcontract:
    windows_storage:
      drive: R
      source_drive: C
      server: storage.example
      export: /exports/builds
      source_budget_bytes: 2147483648
      source_reserve_bytes: 8589934592
      target_min_free_bytes: 21474836480
YAML
    local DSR_HOSTS_FILE="$storage_fixture" contract
    contract=$(config_windows_storage_json lockcontract)
    _hh_init_cache
    result=$(_test_health_result_json "lockcontract" "ok" "true" | jq \
        --argjson contract "$contract" '.platform="windows/amd64" |
        .checks.disk_space.storage_contract=$contract |
        .checks.disk_space.admission="split-storage-role-budgets-v1"')
    _hh_cache_write lockcontract "$result"
    ((TESTS_RUN+=1))
    if _hh_cache_valid lockcontract; then fail "Legacy one-byte cached admission must be reprobed";
    else pass "Legacy one-byte cached admission is refused"; fi
    _hh_cache_write lockcontract "$(jq '.checks.disk_space.lock_range="cargo-win32-whole-u64-v1"' <<< "$result")"
    ((TESTS_RUN+=1))
    if _hh_cache_valid lockcontract; then pass "Whole-u64 cached admission retains normal TTL";
    else fail "Whole-u64 cached admission unexpectedly refused"; fi
    local current_result ordinary_result changed_contract
    current_result=$(_hh_cache_read lockcontract)
    ordinary_result=$(_test_health_result_json "lockcontract" "ok" "true" | jq '.platform="windows/amd64"')
    _hh_cache_write lockcontract "$ordinary_result"
    ((TESTS_RUN+=1))
    if _hh_cache_valid lockcontract; then fail "Local cached health must not admit new split storage";
    else pass "Local-to-split storage change invalidates cached health"; fi
    for changed_contract in \
        "$(jq '.server="other.example"' <<< "$contract")" \
        "$(jq '.target_min_free_bytes=42949672960' <<< "$contract")"; do
        _hh_cache_write lockcontract "$(jq --argjson contract "$changed_contract" \
            '.checks.disk_space.storage_contract=$contract' <<< "$current_result")"
        ((TESTS_RUN+=1))
        if _hh_cache_valid lockcontract; then fail "Changed storage identity/budget must be reprobed";
        else pass "Changed storage identity/budget invalidates cached health"; fi
    done
    _hh_cache_write lockcontract "$current_result"
    ((TESTS_RUN+=1))
    if (DSR_HOSTS_FILE="$TEMP_DIR/absent-storage.yaml"; _hh_cache_valid lockcontract); then
        fail "Split cached health must not survive storage removal"
    else pass "Split-to-local storage change invalidates cached health"; fi
    _hh_cache_write lockcontract "$(jq '.healthy=false | .status="error" |
        .checks.disk_space={path:"split-storage",status:"error"}' <<< "$current_result")"
    ((TESTS_RUN+=1))
    if (DSR_HOSTS_FILE="$TEMP_DIR/absent-storage.yaml"; _hh_cache_valid lockcontract); then
        fail "Historical split failure must not survive storage removal"
    else pass "Split-to-local storage change invalidates cached failure"; fi
    _hh_cache_write lockcontract "$ordinary_result"
    ((TESTS_RUN+=1))
    if (DSR_HOSTS_FILE="$TEMP_DIR/absent-storage.yaml"; _hh_cache_valid lockcontract); then
        pass "Unchanged local storage retains normal cache TTL"
    else fail "Unchanged local storage cache unexpectedly refused"; fi
    printf 'hosts:\n  lockcontract:\n    windows_storage: false\n' > "$TEMP_DIR/invalid-lock-storage.yaml"
    ((TESTS_RUN+=1))
    if (DSR_HOSTS_FILE="$TEMP_DIR/invalid-lock-storage.yaml"; _hh_cache_valid lockcontract); then
        fail "Invalid current storage contract must not reuse cached health"
    else pass "Invalid current storage contract invalidates cached health"; fi
    if ! command -v pwsh >/dev/null; then
        ((TESTS_RUN+=1)); fail "PowerShell is required for Cargo lock admission controls"; return
    fi
    script=$(
        config_windows_storage_json() { printf '%s' '{"drive":"R"}'; }
        config_windows_storage_lock_script fixture
    )
    # Execute the generated parent AND independently launched child logic.
    # Only the unavailable Win32 primitive is modeled; this is not native NFS
    # proof. In particular this model admits a one-byte lock while refusing
    # Cargo's whole-u64 range, matching the retained Windows counterexample.
    cat > "$model" <<'POWERSHELL'
class DsrCargoFileLock {
    static [int] TryLock([object] $file, [uint32] $low, [uint32] $high) {
        if ($env:DSR_LOCK_MODE -eq 'one_byte_only' -and ($low -ne 1 -or $high -ne 0)) { return 33 }
        if ($env:DSR_LOCK_MODE -eq 'reacquire_failure' -and $env:DSR_LOCK_RELEASED -eq '1') { return 33 }
        if ($env:DSR_LOCK_HELD -eq '1') {
            if ($env:DSR_LOCK_MODE -eq 'wrong_exclusion') { return 5 }
            if ($env:DSR_LOCK_MODE -eq 'no_exclusion' -or $env:DSR_LOCK_MODE -eq 'no_exclusion_unlock_failure') { return 0 }
            return 33
        }
        $env:DSR_LOCK_HELD='1'; return 0
    }
    static [int] Unlock([object] $file, [uint32] $low, [uint32] $high) {
        if ($env:DSR_LOCK_MODE -eq 'unlock_failure') { return 5 }
        if ($env:DSR_LOCK_MODE -eq 'no_exclusion_unlock_failure' -and
            $env:DSR_LOCK_CHILD -eq '1' -and $env:DSR_LOCK_RELEASED -ne '1') { return 33 }
        $env:DSR_LOCK_HELD='0'; $env:DSR_LOCK_RELEASED='1'; return 0
    }
}
function Add-Type {
    param([string] $TypeDefinition)
    if (-not $TypeDefinition.Contains('LockFileEx(file, 3, 0, low, high, ref overlapped)') -or
        -not $TypeDefinition.Contains('UnlockFileEx(file, 0, low, high, ref overlapped)')) {
        throw 'Probe no longer uses the reviewed nonblocking exclusive Win32 contract'
    }
}
function Join-Path { param($Path,$ChildPath); return 'Invoke-LockChild' }
function Invoke-LockChild {
    param([switch] $NoProfile, [switch] $NonInteractive, [string] $EncodedCommand)
    $child=[IO.File]::ReadAllText($env:DSR_LOCK_MODEL)+[Environment]::NewLine+
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($EncodedCommand))
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
    $env:DSR_LOCK_CHILD='1'
    & $env:DSR_LOCK_PWSH -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded
    $childStatus=$LASTEXITCODE
    $env:DSR_LOCK_CHILD='0'
    $global:LASTEXITCODE=$childStatus
}
POWERSHELL
    for mode in valid one_byte_only wrong_exclusion no_exclusion no_exclusion_unlock_failure unlock_failure reacquire_failure; do
        ((TESTS_RUN+=1))
        case "$mode" in
            valid) expected='ADMITTED' ;;
            one_byte_only) expected='ONE_BYTE_ADMITTED;DSR Cargo whole-u64 initial lock failed: 33' ;;
            wrong_exclusion) expected='DSR Cargo whole-u64 lock exclusion failed: 5' ;;
            no_exclusion) expected='DSR Cargo whole-u64 lock exclusion failed: 0' ;;
            no_exclusion_unlock_failure) expected='DSR Cargo whole-u64 lock exclusion failed: 1' ;;
            unlock_failure) expected='DSR Cargo whole-u64 unlock failed: 5' ;;
            reacquire_failure) expected='DSR Cargo whole-u64 lock reacquisition failed: 33' ;;
        esac
        status=0
        result=$(
            {
                cat "$model"
                cat <<'POWERSHELL'
$ErrorActionPreference='Stop'
$env:SystemRoot='/fixture'
$env:DSR_LOCK_HELD='0'; $env:DSR_LOCK_RELEASED='0'
Set-Location $env:DSR_LOCK_ROOT
[Environment]::CurrentDirectory=$env:DSR_LOCK_ROOT
[void][IO.Directory]::CreateDirectory('R:')
$prefix=''
if ($env:DSR_LOCK_MODE -eq 'one_byte_only') {
    if ([DsrCargoFileLock]::TryLock($null,1,0) -ne 0 -or
        [DsrCargoFileLock]::TryLock($null,1,0) -ne 33 -or
        [DsrCargoFileLock]::Unlock($null,1,0) -ne 0 -or
        [DsrCargoFileLock]::TryLock($null,1,0) -ne 0) { throw 'one-byte control did not pass' }
    [void][DsrCargoFileLock]::Unlock($null,1,0)
    $prefix='ONE_BYTE_ADMITTED;'
}
try {
POWERSHELL
                printf '%s\n' "$script"
                printf '%s\n' 'Write-Output ($prefix+"ADMITTED")' '} catch { Write-Output ($prefix+$_.Exception.Message) }'
                printf '\n'
            } | DSR_LOCK_MODEL="$model" DSR_LOCK_MODE="$mode" DSR_LOCK_ROOT="$TEMP_DIR" \
                DSR_LOCK_PWSH="$(command -v pwsh)" run_powershell_program
        ) || status=$?
        result=$(printf '%s' "$result" | tr -d '\r')
        if [[ $status -eq 0 && "$result" == "$expected" ]]; then
            pass "Cargo whole-u64 lock $mode admission control"
        else
            fail "Cargo lock $mode: status=$status result=$result expected=$expected"
        fi
    done
}

test_windows_storage_optional_config() {
    local result status=0 fixture="$TEMP_DIR/windows-storage-optional.yaml" ordinary_fixture="$TEMP_DIR/windows-storage-ordinary.yaml"
    printf 'hosts:\n  ordinary:\n    platform: windows/amd64\n  opted:\n    windows_storage: false\n' > "$fixture"
    printf 'hosts:\n  ordinary:\n    platform: windows/amd64\n' > "$ordinary_fixture"
    ((TESTS_RUN+=1))
    result=$(
        export DSR_HOSTS_FILE="$ordinary_fixture"
        command() {
            if [[ "${1:-}" == -v && "${2:-}" == yq ]]; then return 1; fi
            builtin command "$@"
        }
        local ordinary=0 opted=0
        config_windows_storage_json ordinary >/dev/null || ordinary=$?
        export DSR_HOSTS_FILE="$fixture"
        config_windows_storage_json opted >/dev/null || opted=$?
        printf '%s:%s' "$ordinary" "$opted"
    ) || status=$?
    if [[ $status -eq 0 && "$result" == 1:4 ]]; then
        pass "Missing yq preserves ordinary hosts and refuses configured split storage"
    else
        fail "Missing-yq config behavior: status=$status result=$result"
    fi
    ((TESTS_RUN+=1))
    status=0
    (
        export DSR_HOSTS_FILE="$ordinary_fixture"
        command() {
            if [[ "${1:-}" == -v && "${2:-}" == yq ]]; then return 1; fi
            builtin command "$@"
        }
        grep() { return 2; }
        config_windows_storage_json ordinary >/dev/null
    ) || status=$?
    if [[ $status -eq 4 ]]; then pass "Unreadable yq-less configuration fails closed";
    else fail "Unreadable yq-less configuration returned $status"; fi
    ((TESTS_RUN+=1))
    status=0
    (export DSR_HOSTS_FILE="$fixture"; config_windows_storage_json opted >/dev/null) || status=$?
    if [[ $status -eq 4 ]]; then pass "False split-storage contract is malformed, not absent";
    else fail "False split-storage contract returned $status"; fi
    local syntax complex_fixture
    for syntax in flow quoted; do
        ((TESTS_RUN+=1))
        complex_fixture="$TEMP_DIR/windows-storage-$syntax.yaml"
        if [[ "$syntax" == flow ]]; then
            printf 'hosts: {ordinary: {windows_storage: false}}\n' > "$complex_fixture"
        else
            printf 'hosts:\n  "ordinary":\n    "windows_storage": false\n' > "$complex_fixture"
        fi
        status=0
        (
            export DSR_HOSTS_FILE="$complex_fixture"
            command() {
                if [[ "${1:-}" == -v && "${2:-}" == yq ]]; then return 1; fi
                builtin command "$@"
            }
            config_windows_storage_json ordinary >/dev/null
        ) || status=$?
        if [[ $status -eq 4 ]]; then pass "Yq-less $syntax contract cannot bypass admission";
        else fail "Yq-less $syntax contract returned $status"; fi
    done
}

# ============================================================================
# Unix split storage (#38)
# ============================================================================

test_unix_storage_config_contract() {
    local fixture="$TEMP_DIR/unix-storage.yaml" status
    cat > "$fixture" << 'EOF'
hosts:
  plain:
    platform: linux/amd64
  rootonly:
    platform: linux/amd64
    build_root: /data/tmp
  good:
    platform: linux/amd64
    build_root: /data/tmp
    unix_storage:
      root_min_free_bytes: 21474836480
  trailing:
    build_root: /data/tmp/
    unix_storage: {root_min_free_bytes: 21474836480}
  nobuildroot:
    unix_storage: {root_min_free_bytes: 21474836480}
  relative:
    build_root: data
    unix_storage: {root_min_free_bytes: 21474836480}
  dotdot:
    build_root: /data/../etc
    unix_storage: {root_min_free_bytes: 21474836480}
  slash:
    build_root: /
    unix_storage: {root_min_free_bytes: 21474836480}
  quote:
    build_root: "/data'x"
    unix_storage: {root_min_free_bytes: 21474836480}
  tiny:
    build_root: /data/tmp
    unix_storage: {root_min_free_bytes: 1024}
  secondpath:
    build_root: /data/tmp
    unix_storage: {build_root: /data, root_min_free_bytes: 21474836480}
  falsy:
    build_root: /data/tmp
    unix_storage: false
  dotted.host:
    build_root: /data/tmp
    unix_storage: {root_min_free_bytes: 21474836480}
  doubleslash:
    build_root: //
    unix_storage: {root_min_free_bytes: 21474836480}
  innerslash:
    build_root: /data//tmp
    unix_storage: {root_min_free_bytes: 21474836480}
EOF
    local host expected
    # A key outside the name pattern (here "-odd") keeps the legacy root-only check
    # (absent, 1); it must never turn an ordinary Unix host unhealthy.
    for host in plain:1 rootonly:1 good:0 trailing:0 nobuildroot:4 relative:4 dotdot:4 slash:4 quote:4 tiny:4 secondpath:4 falsy:4 dotted.host:0 doubleslash:4 innerslash:4 -odd:1; do
        expected="${host#*:}"; host="${host%%:*}"
        ((TESTS_RUN+=1))
        status=0
        (export DSR_HOSTS_FILE="$fixture"; config_unix_storage_json "$host" >/dev/null) || status=$?
        if [[ $status -eq $expected ]]; then pass "Unix storage contract '$host' returns $expected";
        else fail "Unix storage contract '$host' returned $status, expected $expected"; fi
    done
    ((TESTS_RUN+=1))
    status=0
    (
        export DSR_HOSTS_FILE="$fixture"
        command() {
            if [[ "${1:-}" == -v && "${2:-}" == yq ]]; then return 1; fi
            builtin command "$@"
        }
        config_unix_storage_json good >/dev/null
    ) || status=$?
    if [[ $status -eq 4 ]]; then pass "Yq-less Unix storage opt-in fails closed";
    else fail "Yq-less Unix storage opt-in returned $status"; fi
    ((TESTS_RUN+=1))
    local emitted
    emitted=$(export DSR_HOSTS_FILE="$fixture"; config_unix_storage_json trailing)
    if jq -e '. == {build_root: "/data/tmp", root_min_free_bytes: 21474836480}' <<< "$emitted" >/dev/null; then
        pass "Unix storage contract emits the host build_root (trailing slash trimmed) and the floor"
    else
        fail "Unix storage contract emitted: $emitted"
    fi
}

# Root/build df observations plus the required v2 complete-role observation.
# $1 root "usage avail_kb", $2 build "usage avail_kb" or "FAIL", $3 probe mode.
_test_unix_split_disk() {
    local root="$1" build="$2" probe_mode="${3:-valid}" fixture="$TEMP_DIR/unix-storage-admission.yaml"
    local slots="${4:-1}"
    printf 'hosts:\n  splithost:\n    platform: linux/amd64\n    connection: local\n    concurrency: %s\n    build_root: /data\n    unix_storage:\n      root_min_free_bytes: 21474836480\n' "$slots" > "$fixture"
    (
        export DSR_HOSTS_FILE="$fixture"
        _hh_exec_on_host() {
            local fields
            if [[ "$4" == *DSR_UNIX_WRITABLE_PY* ]]; then
                [[ "$4" == *"python3 -I - '/data'"* ]] || return 91
                local inventory
                inventory=$(_test_writable_inventory "${root%% *}" "${root#* }" \
                    "${build%% *}" "${build#* }" /data) || return 92
                case "$probe_mode" in
                    valid) printf '%s\n' "$inventory" ;;
                    low_temp) jq '.roles |= map(if .role == "temp" then
                        . + {available_bytes:1073741824,usage_percent:99,
                             filesystem_id:"30",capacity_group:"filesystem:30"} else . end)' <<< "$inventory" ;;
                    incomplete) jq '.roles |= map(select(.role != "temp"))' <<< "$inventory" ;;
                    *) return 93 ;;
                esac
                return $?
            elif [[ "$4" == "LC_ALL=C df -Pk '/data'" ]]; then
                [[ "$build" == FAIL ]] && return 7
                fields="$build"
            elif [[ "$4" == "LC_ALL=C df -Pk /" ]]; then
                fields="$root"
            else
                return 9
            fi
            printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
            printf '/dev/test 1000000000 1 %s %s%% /x\n' "${fields#* }" "${fields%% *}"
        }
        _hh_check_disk_space "splithost" "local" "" "linux/amd64"
    )
}

test_unix_split_storage_admission() {
    local result status
    # trj on 2026-10-13: / 97% with ~33 GiB free, /data 69%.
    ((TESTS_RUN+=1))
    result=$(_test_unix_split_disk "97 34664140" "69 1700000000")
    if jq -e '.status == "warning" and .admission == "unix-split-storage-v2" and
              .root.status == "warning" and .root.admitted_as == "warning" and
              .build_root.status == "ok" and .build_root.path == "/data" and .usage_percent == 97 and
              (.roles|length) == 5 and (.capacity_groups|length) == 2 and
              all(.roles[]; if .role == "build_root" then .status == "ok" else .status == "warning" end)' <<< "$result" >/dev/null; then
        pass "Full root above its free floor is admitted as a warning beside a healthy build root"
    else
        fail "Split admission (root over floor) got: $result"
    fi

    ((TESTS_RUN+=1))
    result=$(_test_unix_split_disk "97 5000000" "69 1700000000")
    if jq -e '.status == "error" and .root.admitted_as == "error"' <<< "$result" >/dev/null; then
        pass "Full root below its free floor stays an error"
    else
        fail "Split admission (root under floor) got: $result"
    fi

    ((TESTS_RUN+=1))
    result=$(_test_unix_split_disk "50 400000000" "96 1000000")
    if jq -e '.status == "error" and .root.status == "ok" and .build_root.status == "error"' <<< "$result" >/dev/null; then
        pass "Full build root is an error even with a healthy root"
    else
        fail "Split admission (full build root) got: $result"
    fi

    ((TESTS_RUN+=1))
    result=$(_test_unix_split_disk "50 400000000" "92 80000000")
    if jq -e '.status == "warning" and .build_root.status == "warning" and .root.admitted_as == "ok"' <<< "$result" >/dev/null; then
        pass "Build-root warning surfaces as the overall warning"
    else
        fail "Split admission (build-root warning) got: $result"
    fi

    ((TESTS_RUN+=1))
    result=$(_test_unix_split_disk "96 187695104" "96 187695104")
    if jq -e '.status == "warning" and .root.admitted_as == "warning" and
              .build_root.status == "warning" and (.roles|length) == 5 and
              all(.roles[]; .status == "warning" and .available_bytes == 192199786496)' <<< "$result" >/dev/null; then
        pass "Large split volumes at 96 percent preserve all roles and admit their sufficient byte capacity"
    else
        fail "Split admission (large spacious volumes) got: $result"
    fi

    ((TESTS_RUN+=1))
    result=$(_test_unix_split_disk "96 187695104" "96 187695104" low_temp)
    if jq -e '.status == "error" and .root.admitted_as == "warning" and
              .build_root.status == "warning" and
              [.roles[]|select(.status == "error")|.role] == ["temp"] and
              (.error|contains("temp /fixture/temp"))' <<< "$result" >/dev/null; then
        pass "Spacious split root and build storage cannot hide a separate exhausted temp role"
    else
        fail "Split admission (independent low temp) got: $result"
    fi

    ((TESTS_RUN+=1))
    status=0
    result=$(_test_unix_split_disk "96 187695104" "96 187695104" incomplete) || status=$?
    if [[ $status -ne 0 ]] && jq -e '.admission == "unix-split-storage-v2" and .status == "error" and
              .error == "Required complete writable-storage inspection failed"' <<< "$result" >/dev/null; then
        pass "Split admission refuses an incomplete role inventory despite two spacious df observations"
    else
        fail "Split admission (incomplete roles) status=$status got: $result"
    fi

    ((TESTS_RUN+=1))
    status=0
    result=$(_test_unix_split_disk "50 400000000" FAIL) || status=$?
    if [[ $status -ne 0 ]] && jq -e '.status == "error" and (.error | test("build root /data"))' <<< "$result" >/dev/null; then
        pass "Build-root probe failure fails closed"
    else
        fail "Split admission (probe failure) status=$status got: $result"
    fi

    ((TESTS_RUN+=1))
    local fixture="$TEMP_DIR/unix-storage-bad.yaml"
    printf 'hosts:\n  badhost:\n    platform: linux/amd64\n    connection: local\n    unix_storage: {root_min_free_bytes: 21474836480}\n' > "$fixture"
    status=0
    result=$(
        export DSR_HOSTS_FILE="$fixture"
        _hh_exec_on_host() { printf 'F 1 2 3 4 5\n/dev/test 1000 1 400000000 50%% /\n'; }
        _hh_check_disk_space "badhost" "local" "" "linux/amd64"
    ) || status=$?
    if [[ $status -ne 0 ]] && jq -e '.status == "error" and .error == "Invalid Unix split-storage contract"' <<< "$result" >/dev/null; then
        pass "Malformed Unix storage contract makes the host unhealthy"
    else
        fail "Malformed contract status=$status got: $result"
    fi
}

test_unix_split_storage_human_report() {
    local warn_result err_result output
    warn_result=$(jq -nc --argjson disk "$(_test_unix_split_disk "97 34664140" "69 1700000000")" '
        {hostname:"trj",platform:"linux/amd64",status:"warning",healthy:true,
         checks:{connectivity:{reachable:true},disk_space:$disk,toolchains:{},docker:{},clock_drift:{}}}')
    err_result=$(jq -nc --argjson disk "$(_test_unix_split_disk "50 400000000" "96 1000000")" '
        {hostname:"trj",platform:"linux/amd64",status:"error",healthy:false,
         checks:{connectivity:{reachable:true},disk_space:$disk,toolchains:{},docker:{},clock_drift:{}}}')
    ((TESTS_RUN+=1))
    output=$(_hh_print_result "trj" "$warn_result" 2>&1)
    if [[ "$output" == *"initial root / 97% used,"*"GiB free: warning"* &&
          "$output" == *"initial build root /data 69% used"*": ok"* &&
          "$output" == *"cargo_home /fixture/cargo_home 97% used"* &&
          "$output" == *"temp /fixture/temp 97% used"* && "$output" != *"Disk usage >"* ]]; then
        pass "Current split-storage warning report names both initial volumes and every writable role"
    else
        fail "Split-storage warning report: $output"
    fi
    ((TESTS_RUN+=1))
    output=$(_hh_print_result "trj" "$err_result" 2>&1)
    if [[ "$output" == *"initial build root /data 96% used"*"GiB free: error"* &&
          "$output" == *"20 GiB required"* && "$output" != *"Disk usage >"* ]]; then
        pass "Split-storage error report names the full build root, not the healthy root"
    else
        fail "Split-storage error report: $output"
    fi
}

# Only configuration/transport inputs are fixtures here. The scalar df check,
# split policy, complete writable-role verdict and concurrent budget all run
# through their production entrypoint without depending on an installed yq.
_test_unix_concurrent_disk() {
    local build_kb="$1"
    (
        config_unix_storage_json() {
            printf '%s\n' '{"build_root":"/data","root_min_free_bytes":21474836480}'
        }
        _hh_exec_on_host() {
            case "$4" in
                *DSR_UNIX_WRITABLE_PY*) _test_writable_inventory 96 20971520 96 "$build_kb" /data ;;
                'LC_ALL=C df -Pk /') printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 524288000 1 20971520 96%% /\n' ;;
                "LC_ALL=C df -Pk '/data'") printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/build 1048576000 1 %s 96%% /data\n' "$build_kb" ;;
                *) return 91 ;;
            esac
        }
        _hh_check_disk_space concurrent local '' linux/amd64 '{"build_root":"/data","concurrency":2}'
    )
}

test_unix_split_concurrent_capacity() {
    local result inventory
    ((TESTS_RUN+=1))
    result=$(_test_unix_concurrent_disk 41943040)
    if jq -e '.status == "warning" and .concurrent_builds == 2 and
        .root.min_free_bytes == 21474836480 and .root.admitted_as == "warning" and
        .build_root.min_free_bytes == 42949672960 and .build_root.status == "warning" and
        all(.roles[]; if .role == "build_root" then .min_free_bytes == 42949672960
            else .min_free_bytes == 21474836480 end)' <<< "$result" >/dev/null; then
        pass "Concurrent split storage preserves the host root reserve and budgets both build slots"
    else
        fail "Concurrent split storage multiplied a reserve or omitted a build budget: $result"
    fi

    ((TESTS_RUN+=1))
    result=$(_test_unix_concurrent_disk 41943039)
    if jq -e '.status == "error" and .root.admitted_as == "warning" and
        .build_root.min_free_bytes == 42949672960 and .build_root.status == "error" and
        any(.roles[]; .role == "build_root" and .status == "error")' <<< "$result" >/dev/null; then
        pass "Split df and writable-role checks both refuse a build volume below its concurrent requirement"
    else
        fail "Concurrent split storage admitted insufficient build capacity: $result"
    fi

    ((TESTS_RUN+=1))
    inventory=$(_test_writable_inventory 96 20971520 96 20971520 /data |
        jq '.roles |= map(.filesystem_id="10" | .capacity_group="filesystem:10")')
    result=$(_hh_writable_storage_verdict '{"build_root":"/data","root_min_free_bytes":21474836480}' '[]' 2 <<< "$inventory")
    if jq -e '.status == "error" and (.capacity_groups|length) == 1 and
        [.roles[]|select(.status == "error")|.role] == ["build_root"] and
        [.roles[]|select(.role == "build_root")][0].min_free_bytes == 42949672960' <<< "$result" >/dev/null; then
        pass "A shared root/build filesystem cannot borrow the lower root reserve to admit two builds"
    else
        fail "Shared split storage bypassed the concurrent build requirement: $result"
    fi
}

if [[ "${1:-}" == --disk-capacity-only ]]; then
    test_windows_disk_capacity_boundaries
    test_concurrent_disk_capacity
    test_default_disk_concurrency_matches_scheduler
    test_shared_apfs_concurrent_capacity
    test_windows_split_concurrent_capacity
    test_invalid_disk_concurrency
    test_unix_split_concurrent_capacity
    echo "Tests run: $TESTS_RUN  Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
    [[ $TESTS_FAILED -eq 0 ]]
    exit $?
fi

if [[ "${1:-}" == --unix-storage-only ]]; then
    test_unix_storage_config_contract
    test_unix_split_storage_admission
    test_unix_split_storage_human_report
    test_unix_split_concurrent_capacity
    echo "Tests run: $TESTS_RUN  Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
    [[ $TESTS_FAILED -eq 0 ]]
    exit $?
fi

if [[ "${1:-}" == --windows-storage-only ]]; then
    test_windows_storage_optional_config
    test_windows_split_storage_admission
    test_windows_storage_transport
    test_windows_cargo_lock_range
    [[ $TESTS_FAILED -eq 0 ]]
    exit $?
fi

echo "=== Host Health Module Tests ==="
echo ""

# Cache tests
test_cache_init
test_cache_write_and_read
test_cache_validity
test_cache_rejects_invalid_json
test_cache_rejects_wrong_shape_or_hostname
test_cached_unhealthy_result_returns_nonzero
test_cache_clear
test_cache_clear_all

# Local check tests
test_standalone_source_ignores_caller_script_dir
test_local_connectivity
test_remote_connectivity_handles_bsd_date_literal_nanoseconds
test_local_disk_space
test_local_disk_space_has_status
test_disk_space_forces_kilobytes_with_512_byte_default
test_disk_space_rejects_non_numeric_fields
test_disk_space_rejects_numeric_output_from_failed_command
test_windows_disk_probe_survives_bash_default_shell
test_windows_disk_capacity_boundaries
test_concurrent_disk_capacity
test_default_disk_concurrency_matches_scheduler
test_shared_apfs_concurrent_capacity
test_windows_split_concurrent_capacity
test_invalid_disk_concurrency
test_windows_storage_optional_config
test_powershell_program_failure
test_windows_split_storage_admission
test_windows_storage_transport
test_windows_cargo_lock_range
test_unix_storage_config_contract
test_unix_split_storage_admission
test_unix_split_storage_human_report
test_unix_split_concurrent_capacity
test_human_disk_error_reports_probe_failure
test_local_toolchains_check
test_local_clock_drift

# Full health check tests
test_remote_health_preserves_caller_stdin
test_health_check_local_host
test_health_check_returns_healthy_for_local
test_health_check_has_all_checks
test_health_check_unknown_host
test_health_check_unreachable_host

# Check all tests
test_health_check_all_returns_summary
test_health_check_all_has_hosts_array

# Healthy hosts tests
test_get_healthy_hosts
test_get_healthy_hosts_includes_local

# Readiness tests
test_host_is_ready_local
test_host_is_ready_unreachable
test_host_is_ready_unknown

# Fallback parser tests
test_fallback_parser_basic
test_fallback_parser_connection
test_fallback_parser_capabilities
test_fallback_parser_unknown_host
test_fallback_list_hosts

# Threshold tests
test_disk_threshold_values
test_ssh_timeout_value
test_cache_ttl_value

# Retry logic tests
test_retry_backoff_calculation
test_retry_max_delay_cap
test_retry_with_success
test_retry_state_recording
test_retry_limit_enforcement
test_resume_plan_generation
test_health_check_with_retry_context

# Cleanup
if [[ "${DSR_TEST_KEEP_TEMP:-0}" != 1 ]]; then
    rm -rf "$TEMP_DIR"
else
    printf 'Retained fixtures: %s\n' "$TEMP_DIR"
fi

# Summary
echo ""
echo "=== Results ==="
echo "Tests run: $TESTS_RUN"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
