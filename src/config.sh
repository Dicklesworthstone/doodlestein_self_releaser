#!/usr/bin/env bash
# config.sh - Configuration management for dsr
#
# Usage:
#   source config.sh
#   config_init
#   config_load
#   config_get <key>
#   config_set <key> <value>
#
# XDG Layout:
#   ~/.config/dsr/config.yaml    - Main configuration
#   ~/.config/dsr/repos.yaml     - Repository/tool registry
#   ~/.config/dsr/hosts.yaml     - Build host definitions
#   ~/.cache/dsr/                - API cache, downloads
#   ~/.local/state/dsr/          - Logs, state, run history

set -uo pipefail

# Preserve the source module's location for exported validators too. Their
# BASH_SOURCE becomes "environment" in a child shell and must never make its
# current working directory an authority for loading the native parser.
_DSR_CONFIG_MODULE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || { return 3 2>/dev/null || exit 3; }
export _DSR_CONFIG_MODULE_DIR
# shellcheck source=src/platforms.sh
source "$_DSR_CONFIG_MODULE_DIR/platforms.sh" || { return 3 2>/dev/null || exit 3; }

# XDG directories with defaults (respect existing env vars for testing)
DSR_CONFIG_DIR="${DSR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsr}"
DSR_CACHE_DIR="${DSR_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/dsr}"
DSR_STATE_DIR="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}"

# Config file paths
DSR_CONFIG_FILE="${DSR_CONFIG_FILE:-$DSR_CONFIG_DIR/config.yaml}"
DSR_REPOS_FILE="${DSR_REPOS_FILE:-$DSR_CONFIG_DIR/repos.yaml}"
DSR_HOSTS_FILE="${DSR_HOSTS_FILE:-$DSR_CONFIG_DIR/hosts.yaml}"

# Current schema version
DSR_SCHEMA_VERSION="1.0.0"

# Loaded config values (associative array)
declare -gA DSR_CONFIG

# Optional Unix split-storage contract (#38). The host's own `build_root` is
# where every snapshot, isolated target and output stage lands (act_runner
# defaults them to /var/tmp without it), so it is the volume the contract
# admits; the contract never carries a second path. An explicitly authorized
# build_min_free_bytes opts only that build root into a percentage exception,
# with a floor of at least 20 GiB. Omission preserves the default policy.
# The root filesystem (system, Cargo home) stays visible and, above the error
# percentage, is admitted only as a warning while its free space meets
# root_min_free_bytes. Emits {build_root, root_min_free_bytes}. Return 1 when
# absent, 4 for any malformed contract, including a missing host build_root.
config_unix_storage_json() {
    local host="$1" value hosts_file="${DSR_HOSTS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml}"
    # Unlike the Windows contract, this runs for every Unix host, so an unusual
    # host key must keep the legacy root-only check (absent), never become
    # unhealthy. strenv() below keeps the key out of the yq program anyway.
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    [[ -f "$hosts_file" ]] || return 1
    if ! command -v yq >/dev/null 2>&1; then
        # Any opt-in spells the key literally, so its absence proves absence;
        # a present key needs a real parser.
        local scan_status=0
        LC_ALL=C grep -q "unix_storage" "$hosts_file" || scan_status=$?
        case "$scan_status" in
            1) return 1 ;;
            *) return 4 ;;
        esac
    fi
    value=$(DSR_STORAGE_HOST="$host" yq -o=json -I=0 \
        '.hosts[strenv(DSR_STORAGE_HOST)] | {"unix_storage": .unix_storage, "build_root": .build_root}' \
        "$hosts_file") || return 4
    [[ "$(jq -c '.unix_storage' <<< "$value" 2>/dev/null)" != null ]] || return 1
    jq -e '
        (.unix_storage | type == "object" and
            (keys == ["root_min_free_bytes"] or keys == ["build_min_free_bytes","root_min_free_bytes"]) and
            (.root_min_free_bytes | type == "number" and . == floor and . >= 1073741824) and
            (if has("build_min_free_bytes") then
                (.build_min_free_bytes | type == "number" and . == floor and . >= 21474836480 and . <= 9007199254740991)
             else true end)) and
        (.build_root | type == "string" and test("^/[A-Za-z0-9._/-]+$") and
            (test("(^|/)\\.\\.?(/|$)") | not) and (test("//") | not) and (rtrimstr("/") != ""))
    ' <<< "$value" >/dev/null || return 4
    jq -c '.unix_storage + {build_root: (.build_root | rtrimstr("/"))}' <<< "$value"
}

# Optional Windows split-storage contract. The source and private Cargo home
# stay on NTFS; only target output and scratch use the explicitly named NFS
# export. Return 1 when absent, 4 for any malformed contract.
config_windows_storage_json() {
    local host="$1" value hosts_file="${DSR_HOSTS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml}"
    [[ "$host" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || return 4
    [[ -f "$hosts_file" ]] || return 1
    if ! command -v yq >/dev/null 2>&1; then
        # Preserve the existing yq-less fallback for simple files with no
        # possible opt-in. Complex YAML or any storage declaration requires
        # a real parser; indentation guessing cannot prove absence.
        local scan_status=0
        LC_ALL=C grep -Eq "windows_storage|[{}&*!]|^[[:space:]]*[\"'?%]" "$hosts_file" || scan_status=$?
        case "$scan_status" in
            1) return 1 ;;
            *) return 4 ;;
        esac
    fi
    value=$(DSR_STORAGE_HOST="$host" yq -o=json -I=0 \
        '.hosts[strenv(DSR_STORAGE_HOST)].windows_storage' "$hosts_file") || return 4
    [[ "$value" != null ]] || return 1
    jq -e '
        type == "object" and
        (keys | sort) == (["drive", "export", "server", "source_budget_bytes", "source_drive", "source_reserve_bytes", "target_min_free_bytes"] | sort) and
        (.drive | type == "string" and test("^[D-Z]$")) and
        (.source_drive | type == "string" and test("^[A-Z]$")) and
        .drive != .source_drive and
        (.server | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]*$")) and
        (.export | type == "string" and test("^/[A-Za-z0-9_/-]+[A-Za-z0-9_.-]*$") and (contains("..") | not)) and
        (.source_budget_bytes | type == "number" and floor == . and . >= 2147483648 and . <= 1099511627776) and
        (.source_reserve_bytes | type == "number" and floor == . and . >= 8589934592 and . <= 1099511627776) and
        (.target_min_free_bytes | type == "number" and floor == . and . >= 21474836480 and . <= 1099511627776)
    ' <<< "$value" >/dev/null || return 4
    printf '%s\n' "$value"
}

# This script must run in the SAME Windows logon session as its consumer.
# Native NFS mappings disappear between SSH sessions. In particular, a UNC
# path can read successfully while refusing byte-range locks.
config_windows_storage_session_script() {
    local host="$1" value drive source_drive server export_path reserve budget target_min provider
    value=$(config_windows_storage_json "$host") || return $?
    drive=$(jq -r '.drive' <<< "$value")
    source_drive=$(jq -r '.source_drive' <<< "$value")
    server=$(jq -r '.server' <<< "$value")
    export_path=$(jq -r '.export' <<< "$value")
    reserve=$(jq -r '.source_reserve_bytes' <<< "$value")
    budget=$(jq -r '.source_budget_bytes' <<< "$value")
    target_min=$(jq -r '.target_min_free_bytes' <<< "$value")
    provider="\\\\$server${export_path//\//\\}"
    cat <<EOF
\$ErrorActionPreference='Stop';
\$dsrSourceDisk=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${source_drive}:'";
if (\$null -eq \$dsrSourceDisk -or \$dsrSourceDisk.DriveType -ne 3 -or \$dsrSourceDisk.FileSystem -ne 'NTFS' -or \$dsrSourceDisk.FreeSpace -lt ([long]$reserve + [long]$budget)) { throw 'DSR source/cache capacity admission failed' };
\$dsrAmbientCargo=if (\$env:CARGO_HOME) { \$env:CARGO_HOME } else { Join-Path \$env:USERPROFILE '.cargo' };
if (-not \$dsrAmbientCargo.Replace([char]92,[char]47).StartsWith('${source_drive}:/',[StringComparison]::OrdinalIgnoreCase)) { throw 'DSR cache volume is outside source capacity admission' };
\$dsrCacheNode=Get-Item -LiteralPath \$dsrAmbientCargo -Force;
while (\$null -ne \$dsrCacheNode) { if ((\$dsrCacheNode.Attributes -band [IO.FileAttributes]::Directory) -eq 0 -or ((\$dsrCacheNode.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'DSR ambient cache ancestor is not a plain directory' }; \$dsrCacheNode=\$dsrCacheNode.Parent };
foreach (\$name in @('registry','git')) { \$cachePath=Join-Path \$dsrAmbientCargo \$name; if (Test-Path -LiteralPath \$cachePath) { \$cacheItem=Get-Item -LiteralPath \$cachePath -Force; if (-not \$cacheItem.PSIsContainer -or ((\$cacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'DSR cache storage is outside admitted plain directory' } } };
\$dsrTargetDisk=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${drive}:'";
if (\$null -eq \$dsrTargetDisk) {
    if (Get-PSDrive -Name '$drive' -ErrorAction SilentlyContinue) { throw 'DSR target drive is already occupied' };
    & (Join-Path \$env:SystemRoot 'System32/mount.exe') -o anon -o mtype=hard -o fileaccess=777 '${server}:${export_path}' '${drive}:' | Out-Null;
    if (\$LASTEXITCODE -ne 0) { throw 'DSR NFS mount failed' };
    \$dsrTargetDisk=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${drive}:'";
};
if (\$null -eq \$dsrTargetDisk -or \$dsrTargetDisk.DriveType -ne 4 -or \$dsrTargetDisk.FileSystem -ne 'NFS' -or \$dsrTargetDisk.ProviderName -cne '$provider') { throw 'DSR NFS mapping identity mismatch' };
if (\$dsrTargetDisk.FreeSpace -lt [long]$target_min) { throw 'DSR target capacity admission failed' };
EOF
}

# Retained tiny file, but Cargo locks the full unsigned 64-bit byte range.
# FileStream.Lock takes a signed length and cannot express that contract.
# Both exclusion while held and acquisition after release matter.
config_windows_storage_lock_script() {
    local value drive
    value=$(config_windows_storage_json "$1") || return $?
    drive=$(jq -r '.drive' <<< "$value")
    cat <<EOF
\$dsrLockNative=@'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class DsrCargoFileLock {
    [StructLayout(LayoutKind.Sequential)]
    private struct Overlapped {
        public UIntPtr Internal, InternalHigh;
        public uint Offset, OffsetHigh;
        public IntPtr Event;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LockFileEx(SafeFileHandle file, uint flags, uint reserved, uint low, uint high, ref Overlapped overlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnlockFileEx(SafeFileHandle file, uint reserved, uint low, uint high, ref Overlapped overlapped);
    public static int TryLock(SafeFileHandle file, uint low, uint high) {
        var overlapped = new Overlapped();
        return LockFileEx(file, 3, 0, low, high, ref overlapped) ? 0 : Marshal.GetLastWin32Error();
    }
    public static int Unlock(SafeFileHandle file, uint low, uint high) {
        var overlapped = new Overlapped();
        return UnlockFileEx(file, 0, low, high, ref overlapped) ? 0 : Marshal.GetLastWin32Error();
    }
}
'@;
Add-Type -TypeDefinition \$dsrLockNative;
\$dsrProbePath='${drive}:/.dsr-lock-'+[Guid]::NewGuid().ToString('N')+'.probe';
\$dsrProbe=[IO.File]::Open(\$dsrProbePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite);
try {
    \$dsrProbe.SetLength(1); \$dsrProbe.Flush(\$true);
    \$dsrLockError=[DsrCargoFileLock]::TryLock(\$dsrProbe.SafeFileHandle,[uint32]::MaxValue,[uint32]::MaxValue);
    if (\$dsrLockError -ne 0) { throw "DSR Cargo whole-u64 initial lock failed: \$dsrLockError" };
    \$dsrNativeEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(\$dsrLockNative));
    \$dsrChild='\$ErrorActionPreference="Stop"; Add-Type -TypeDefinition ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String("'+\$dsrNativeEncoded+'"))); \$f=[IO.File]::Open("'+\$dsrProbePath+'",[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite); try { \$result=[DsrCargoFileLock]::TryLock(\$f.SafeFileHandle,[uint32]::MaxValue,[uint32]::MaxValue); if (\$result -eq 0) { \$unlockError=[DsrCargoFileLock]::Unlock(\$f.SafeFileHandle,[uint32]::MaxValue,[uint32]::MaxValue); if (\$unlockError -ne 0) { throw "DSR Cargo child unlock failed: \$unlockError" } }; exit \$result } finally { \$f.Dispose() }';
    \$dsrEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(\$dsrChild));
    & (Join-Path \$env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoProfile -NonInteractive -EncodedCommand \$dsrEncoded;
    if (\$LASTEXITCODE -ne 33) { throw "DSR Cargo whole-u64 lock exclusion failed: \$LASTEXITCODE" };
    \$dsrLockError=[DsrCargoFileLock]::Unlock(\$dsrProbe.SafeFileHandle,[uint32]::MaxValue,[uint32]::MaxValue);
    if (\$dsrLockError -ne 0) { throw "DSR Cargo whole-u64 unlock failed: \$dsrLockError" };
    & (Join-Path \$env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoProfile -NonInteractive -EncodedCommand \$dsrEncoded;
    if (\$LASTEXITCODE -ne 0) { throw "DSR Cargo whole-u64 lock reacquisition failed: \$LASTEXITCODE" };
} finally { \$dsrProbe.Dispose() };
EOF
}

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _CFG_RED=$'\033[0;31m'
    _CFG_GREEN=$'\033[0;32m'
    _CFG_YELLOW=$'\033[0;33m'
    _CFG_BLUE=$'\033[0;34m'
    _CFG_NC=$'\033[0m'
else
    _CFG_RED='' _CFG_GREEN='' _CFG_YELLOW='' _CFG_BLUE='' _CFG_NC=''
fi

_cfg_log_info()  { echo "${_CFG_BLUE}[config]${_CFG_NC} $*" >&2; }
_cfg_log_ok()    { echo "${_CFG_GREEN}[config]${_CFG_NC} $*" >&2; }
_cfg_log_warn()  { echo "${_CFG_YELLOW}[config]${_CFG_NC} $*" >&2; }
_cfg_log_error() { echo "${_CFG_RED}[config]${_CFG_NC} $*" >&2; }

# Keep errors available to the JSON caller without redirecting diagnostics to
# a temporary file (in particular, during a preview).
_config_init_error() {
    _DSR_CONFIG_INIT_ERROR="${_DSR_CONFIG_INIT_ERROR:+$_DSR_CONFIG_INIT_ERROR; }$*"
    _cfg_log_error "$*"
}

# Resolve existing parent symlinks, including for a not-yet-created tree,
# without mkdir or realpath -m (which is unavailable on macOS). Unresolvable
# '..' components are refused rather than giving a preview a different path.
_config_init_path() {
    local path="$1" parent leaf suffix="" part resolved
    [[ -n "$path" && "$path" != */ && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 4
    leaf=$(basename -- "$path") || return 4
    [[ "$leaf" != . && "$leaf" != .. ]] || return 4
    parent=$(dirname -- "$path") || return 4
    while [[ ! -d "$parent" ]]; do
        [[ ! -e "$parent" && ! -L "$parent" ]] || return 4
        part=$(basename -- "$parent") || return 4
        [[ "$part" != .. && "$part" != / ]] || return 4
        [[ "$part" == . ]] || suffix="/$part$suffix"
        parent=$(dirname -- "$parent") || return 4
    done
    resolved=$(CDPATH='' cd -P -- "$parent" && pwd -P) || return 4
    printf '%s%s/%s\n' "${resolved%/}" "$suffix" "$leaf"
}

_config_init_stat() {
    stat -c '%d:%i:%u:%g:%a' -- "$1" 2>/dev/null || stat -f '%d:%i:%u:%g:%Lp' "$1"
}

# The helpers below use the caller's dynamically scoped transaction arrays
# and trusted renderer. Initialization and persistent edits share the same
# locks, verified backups, staged writes and guarded rollback.
_config_init_apply() {
    local index prior path lock stage backup stamp metadata mode render_status generation=""
    stamp=$(date -u +%Y%m%dT%H%M%SZ) || { _config_init_error "Could not timestamp configuration backups"; return 1; }
    for ((index = 0; index < ${#canonical_paths[@]}; index++)); do
        path="${canonical_paths[index]}"
        lock="$path.init.lock"
        # Even an otherwise no-op init must not declare a killed reset's
        # mixed configuration initialized while its recovery evidence remains.
        if ! ${init_selected[index]}; then
            if [[ -e "$lock" || -L "$lock" ]]; then
                _config_init_error "Cannot acquire $lock; another initialization or an interrupted operation must be inspected first"
                return 2
            fi
            continue
        fi
        if ! (umask 077; mkdir -- "$lock"); then
            if [[ -e "$lock" || -L "$lock" ]]; then
                _config_init_error "Cannot acquire $lock; another initialization or an interrupted operation must be inspected first"
                return 2
            fi
            _config_init_error "Could not create initialization lock $lock; check directory permissions and free space"
            return 1
        fi
        init_locks[index]="$lock"
        if ! printf '%s\n' "${BASHPID:-$$}" > "$lock/owner" ||
           ! init_stages[index]=$(mktemp -d "$lock/stage.XXXXXXXX"); then
            _config_init_error "Could not prepare private staging for $path"
            return 1
        fi
        [[ -n "$generation" ]] || generation="${init_stages[index]##*/}"
    done

    for ((index = 0; index < ${#canonical_paths[@]}; index++)); do
        ${init_selected[index]} || continue
        path="${canonical_paths[index]}"
        stage="${init_stages[index]}"
        if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
            _config_init_error "Configuration destination changed before backup: $path"
            return 4
        fi
        for ((prior = 0; prior < index; prior++)); do
            if [[ "$path" -ef "${canonical_paths[prior]}" ]]; then
                _config_init_error "Configuration destinations now alias one another: $path"
                return 4
            fi
        done
        [[ -f "$path" ]] || continue
        if ! $force; then
            _config_init_error "Configuration appeared during initialization: $path"
            return 2
        fi
        if ! init_before[index]=$(_config_init_stat "$path") ||
           ! cp -p -- "$path" "$stage/original" || ! cmp -s "$path" "$stage/original" ||
           [[ "${init_before[index]}" != "$(_config_init_stat "$path")" ]]; then
            _config_init_error "Could not preserve a stable original for $path; configuration not replaced"
            return 1
        fi
        metadata=$(_config_init_stat "$stage/original") || {
            _config_init_error "Could not inspect preserved metadata for $path"
            return 1
        }
        if [[ "${metadata#*:*:}" != "${init_before[index]#*:*:}" ]]; then
            _config_init_error "Could not preserve ownership and permissions for $path"
            return 1
        fi
        # Publish only a complete, verified backup. An exclusive hardlink
        # cannot truncate an older generation or expose an empty reservation.
        # One suffix identifies the complete original set, even if a process
        # dies during cleanup after some per-file leases have been removed.
        backup="$path.bak.$stamp.$generation"
        if [[ -e "$backup" || -L "$backup" ]] || ! ln -- "$stage/original" "$backup" ||
           [[ -L "$backup" || ! -f "$backup" || ! "$backup" -ef "$stage/original" ]]; then
            _config_init_error "Could not publish original backup $backup; configuration not replaced"
            return 1
        fi
        backups[index]="$backup"
        _DSR_CONFIG_INIT_BACKUP_PATHS+=("$backup")
        _cfg_log_info "Preserved $path in $backup"
        # JSON is printed only on return. Retain the exact generation in the
        # lease too, so a killed JSON invocation remains recoverable.
        if ! printf '%s\n' "$backup" > "$stage/backup-path"; then
            _config_init_error "Could not record recovery path for $path; original retained in $backup"
            return 1
        fi
    done

    for ((index = 0; index < ${#canonical_paths[@]}; index++)); do
        ${init_selected[index]} || continue
        path="${canonical_paths[index]}"
        stage="${init_stages[index]}"
        mode=600
        if [[ -n "${backups[index]}" ]]; then
            mode="${init_before[index]##*:}"
            # Copy metadata, but make the private candidate writable while
            # rendering even when the original is read-only (e.g. mode 0400).
            if ! cp -p -- "${backups[index]}" "$stage/new" || ! chmod 600 "$stage/new"; then
                _config_init_error "Could not prepare replacement for $path"
                return 1
            fi
        elif ! (umask 077; : > "$stage/new"); then
            _config_init_error "Could not stage new configuration $path"
            return 1
        fi
        render_status=0
        "$init_renderer" "$index" > "$stage/new" || render_status=$?
        if [[ $render_status -ne 0 ]]; then
            _config_init_error "Could not finish staging $path; live configuration unchanged"
            case "$render_status" in
                3|4) return "$render_status" ;;
                *) return 1 ;;
            esac
        fi
        if ! chmod "$mode" "$stage/new" ||
           ! cp -p -- "$stage/new" "$stage/expected" ||
           ! init_candidates[index]=$(_config_init_stat "$stage/new"); then
            _config_init_error "Could not finish staging $path; live configuration unchanged"
            return 1
        fi
        if [[ -n "${backups[index]}" && "${init_candidates[index]#*:*:}" != "${init_before[index]#*:*:}" ]]; then
            _config_init_error "Replacement ownership or permissions differ from the original: $path"
            return 1
        fi
    done

    # Recheck the entire set after preparation, then each leaf immediately
    # before publication. Cooperating initializers hold the same leaf locks.
    for ((index = 0; index < ${#canonical_paths[@]}; index++)); do
        ${init_selected[index]} || continue
        _config_init_original_unchanged "$index" || return $?
    done
    for ((index = 0; index < ${#canonical_paths[@]}; index++)); do
        ${init_selected[index]} || continue
        _config_init_original_unchanged "$index" || return $?
        path="${canonical_paths[index]}"
        stage="${init_stages[index]}"
        # Record intent before mv/ln: an I/O error may be reported after the
        # filesystem operation succeeded, and that case needs rollback too.
        init_attempted+=("$index")
        init_attempted_count=$((init_attempted_count + 1))
        if [[ -n "${backups[index]}" ]]; then
            if ! mv -f -- "$stage/new" "$path"; then
                _config_init_error "Could not replace $path"
                return 1
            fi
        elif ! ln -- "$stage/new" "$path"; then
            _config_init_error "Could not create $path without overwriting another file"
            return 1
        fi
        if ! _config_init_candidate_unchanged "$index"; then
            _config_init_error "Published configuration did not match its staged file: $path"
            return 1
        fi
    done
}

_config_init_original_unchanged() {
    local index="$1" path="${canonical_paths[$1]}"
    if [[ -n "${backups[index]}" ]]; then
        if [[ ! -L "$path" && -f "$path" && "${init_before[index]}" == "$(_config_init_stat "$path")" ]] &&
           cmp -s "$path" "${backups[index]}"; then
            return 0
        fi
    elif [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi
    _config_init_error "Configuration changed during initialization: $path"
    return 2
}

_config_init_candidate_unchanged() {
    local index="$1" path="${canonical_paths[$1]}"
    [[ ! -L "$path" && -f "$path" && "${init_candidates[index]}" == "$(_config_init_stat "$path")" ]] &&
        cmp -s "$path" "${init_stages[index]}/expected"
}

_config_init_rollback() {
    local offset index path stage restored=false failed=false
    # Keep a separate count for Bash 4.0-4.3 under nounset, where expanding
    # even the length of an empty array can abort the sourcing shell.
    for ((offset = init_attempted_count - 1; offset >= 0; offset--)); do
        index="${init_attempted[offset]}"
        path="${canonical_paths[index]}"
        stage="${init_stages[index]}"
        if ! _config_init_candidate_unchanged "$index"; then
            # A failed operation that left its original untouched needs no
            # restore. Any other change belongs to somebody else: retain it.
            if [[ -n "${backups[index]}" ]]; then
                if [[ ! -L "$path" && -f "$path" && "${init_before[index]}" == "$(_config_init_stat "$path")" ]] &&
                   cmp -s "$path" "${backups[index]}"; then
                    continue
                fi
            elif [[ ! -e "$path" && ! -L "$path" ]]; then
                continue
            fi
            _config_init_error "Refusing to roll back a changed destination: $path; inspect its retained backup and $stage"
            failed=true
            continue
        fi
        if [[ -n "${backups[index]}" ]]; then
            if ! cp -p -- "${backups[index]}" "$stage/restore" ||
               ! cmp -s "${backups[index]}" "$stage/restore" ||
               ! _config_init_candidate_unchanged "$index" ||
               ! mv -f -- "$stage/restore" "$path" || ! cmp -s "${backups[index]}" "$path"; then
                _config_init_error "Could not restore $path; original retained in ${backups[index]}"
                failed=true
                continue
            fi
        elif ! rm -f -- "$path"; then
            _config_init_error "Could not remove the newly created $path during rollback"
            failed=true
            continue
        fi
        restored=true
    done
    _DSR_CONFIG_INIT_ROLLED_BACK="$restored"
    _DSR_CONFIG_INIT_RECOVERY_REQUIRED="$failed"
    ! $failed
}

_config_init_cleanup() {
    local index stage lock failed=false
    for ((index = 0; index < ${#canonical_paths[@]}; index++)); do
        lock="${init_locks[index]}"
        [[ -n "$lock" ]] || continue
        stage="${init_stages[index]}"
        if [[ -n "$stage" ]]; then
            if ! rm -f -- "$stage/new" "$stage/expected" "$stage/original" "$stage/restore" "$stage/backup-path" || ! rmdir -- "$stage"; then
                _config_init_error "Could not clean private staging $stage; lock retained"
                failed=true
                continue
            fi
        fi
        if ! rm -f -- "$lock/owner" || ! rmdir -- "$lock"; then
            _config_init_error "Could not release initialization lock $lock"
            failed=true
        fi
    done
    ! $failed
}

# Initialize config directories and default files. No traps are installed in
# the sourcing shell. Termination can leave a mixed set of complete files,
# preserved originals and locks; a later run refuses to steal those locks.
# Usage: config_init [--force] [--dry-run]
config_init() {
    local force=false dry_run="${DRY_RUN:-false}" status=0 path previous parent index prior init_attempted_count=0
    local init_renderer=_config_init_render_default
    local -a init_paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")
    local -a canonical_paths=("" "" "") backups=("" "" "")
    local -a init_locks=("" "" "") init_stages=("" "" "") init_before=("" "" "")
    local -a init_candidates=("" "" "") init_selected=(false false false) init_attempted=()
    local -a init_dirs=("$DSR_CONFIG_DIR" "$DSR_CACHE_DIR" "$DSR_STATE_DIR"
        "$DSR_STATE_DIR/logs" "$DSR_STATE_DIR/artifacts" "$DSR_STATE_DIR/manifests"
        "$DSR_CACHE_DIR/act" "$DSR_CACHE_DIR/builds")
    _DSR_CONFIG_INIT_BACKUP_PATHS=()
    _DSR_CONFIG_INIT_ERROR=""
    _DSR_CONFIG_INIT_ROLLED_BACK=false
    _DSR_CONFIG_INIT_RECOVERY_REQUIRED=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true ;;
            --dry-run|-n) dry_run=true ;;
            *) _config_init_error "Unknown config init option: $1"; return 4 ;;
        esac
        shift
    done

    # Preflight the complete destination set, including missing parent aliases,
    # before any directory creation. A normal init keeps existing regular files.
    for ((index = 0; index < 3; index++)); do
        path="${init_paths[index]}"
        if ! canonical_paths[index]=$(_config_init_path "$path"); then
            _config_init_error "Invalid or unresolvable configuration destination: $path"
            return 4
        fi
        parent="${canonical_paths[index]%/*}"
        init_dirs+=("${parent:-/}")
        if $force || [[ ! -f "$path" ]]; then
            init_selected[index]=true
            if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
                _config_init_error "Configuration destination is not a regular file: $path"
                return 4
            fi
        fi
        for ((prior = 0; prior < index; prior++)); do
            previous="${init_paths[prior]}"
            if [[ "${canonical_paths[index]}" == "${canonical_paths[prior]}" || "$path" -ef "$previous" ]]; then
                _config_init_error "Configuration destinations alias one another: $path and $previous"
                return 4
            fi
        done
    done
    for path in "${init_dirs[@]}"; do
        if [[ ( -e "$path" || -L "$path" ) && ! -d "$path" ]]; then
            _config_init_error "Configuration, cache or state directory is not a directory: $path"
            return 1
        fi
    done

    if [[ "$dry_run" == true ]]; then
        for path in "${init_dirs[@]}"; do
            [[ -d "$path" ]] || _cfg_log_info "[dry-run] Would create directory: $path"
        done
        for path in "${init_paths[@]}"; do
            if [[ -f "$path" ]]; then
                if $force; then
                    _cfg_log_info "[dry-run] Would back up and replace: $path"
                else
                    _cfg_log_info "[dry-run] Would keep: $path"
                fi
            else
                _cfg_log_info "[dry-run] Would create: $path"
            fi
        done
        _cfg_log_info "[dry-run] No configuration files or directories changed"
        return 0
    fi

    _cfg_log_info "Initializing dsr configuration..."
    if ! (umask 077; mkdir -p -- "${init_dirs[@]}"); then
        _config_init_error "Could not create configuration, cache or state directories"
        return 1
    fi
    _config_init_apply || status=$?
    if [[ $status -ne 0 ]]; then
        _config_init_rollback || true
    fi
    if ! $_DSR_CONFIG_INIT_RECOVERY_REQUIRED; then
        if ! _config_init_cleanup; then
            _DSR_CONFIG_INIT_RECOVERY_REQUIRED=true
            [[ $status -ne 0 ]] || status=1
        fi
    fi
    [[ $status -eq 0 ]] || return "$status"
    for ((index = 0; index < 3; index++)); do
        ${init_selected[index]} && _cfg_log_ok "Created ${init_paths[index]}"
    done
    _cfg_log_ok "Configuration initialized in $DSR_CONFIG_DIR"
    return 0
}

# Templates write only to the caller's private candidate, never a live path.
_config_init_render_default() {
    case "$1" in
        0) cat << 'EOF'
# dsr configuration
# See docs/CLI_CONTRACT.md for full specification

schema_version: "1.0.0"

# Default queue time threshold for throttle detection (seconds)
threshold_seconds: 600

# Default build targets
default_targets:
  - linux/amd64
  - darwin/arm64
  - windows/amd64

# Artifact signing
signing:
  enabled: true
  tool: minisign
  # key_path: ~/.config/dsr/minisign.key

# Logging
log_level: info

# Notifications (optional)
# notifications:
#   slack_webhook: ""
#   discord_webhook: ""
EOF
            ;;
        1) cat << 'EOF'
# dsr build hosts configuration
# Define your build machines here

schema_version: "1.0.0"

hosts:
  trj:
    platform: linux/amd64
    connection: local
    capabilities:
      - rust
      - go
      - node
      - bun
      - docker
      - act
    concurrency: 4
    description: "Threadripper workstation (local)"
    # Optional: disk-backed root for release snapshots and isolated Rust
    # builds (default /var/tmp on Linux, /private/tmp on macOS; never /tmp).
    # build_root: /var/tmp/dsr-builds

  mmini:
    platform: darwin/arm64
    connection: ssh
    ssh_host: mmini
    ssh_timeout: 15
    capabilities:
      - rust
      - go
      - node
      - bun
    concurrency: 2
    description: "Mac Mini M1 via Tailscale"

  wlap:
    platform: windows/amd64
    connection: ssh
    ssh_host: wlap
    ssh_timeout: 15
    capabilities:
      - rust
      - go
      - node
      - bun
    concurrency: 2
    description: "Windows Surface Book via Tailscale"

# Platform to host mapping for builds
platform_mapping:
  linux/amd64: trj
  linux/arm64: trj  # via act/QEMU
  darwin/arm64: mmini
  darwin/amd64: mmini  # Rosetta
  windows/amd64: wlap
  windows/arm64: wlap
EOF
            ;;
        2) cat << 'EOF'
# dsr repository/tool registry
# Define tools to build and release

schema_version: "1.0.0"

# Example tool entry (uncomment and customize)
# tools:
#   ntm:
#     repo: dicklesworthstone/ntm
#     local_path: /data/projects/ntm
#     language: go
#     build_cmd: go build -ldflags="-s -w" -o ntm ./cmd/ntm
#     binary_name: ntm
#     targets:
#       - linux/amd64
#       - darwin/arm64
#       - windows/amd64
#     workflow: .github/workflows/release.yml
#     act_job_map:
#       linux/amd64: build-linux
#       darwin/arm64: null  # native on mmini
#       windows/amd64: null  # native on wlap
#     checks:
#       - go test ./...
#       - go vet ./...
#     artifact_naming: "${name}-${version}-${os}-${arch}"
#     archive_format: tar.gz  # or zip for windows

tools: {}
EOF
            ;;
        *) return 4 ;;
    esac
}

# Load configuration with precedence: CLI > ENV > config > defaults
# Usage: config_load
config_load() {
    local key
    local -A _config_pending=()
    _DSR_CONFIG_LOAD_ERROR=""

    # Resolve into a private map. Failed parsing must not replace the caller's
    # last valid settings with defaults or a partially decoded document.
    _config_pending[threshold_seconds]=600
    _config_pending[log_level]="info"
    _config_pending[signing_enabled]="true"
    _config_pending[signing_tool]="minisign"
    _config_pending[schema_version]="$DSR_SCHEMA_VERSION"

    if [[ -e "$DSR_CONFIG_FILE" || -L "$DSR_CONFIG_FILE" ]]; then
        if [[ ! -f "$DSR_CONFIG_FILE" || ! -r "$DSR_CONFIG_FILE" ]]; then
            _config_load_error "Configuration is not a readable regular file: $DSR_CONFIG_FILE"
            return 4
        fi
        # Retain default-only loading for an absent or zero-byte file. Explicit
        # validation still requires a physical document with its own schema.
        if [[ -s "$DSR_CONFIG_FILE" ]]; then
            _config_load_yaml "$DSR_CONFIG_FILE" || return $?
        fi
    fi

    [[ -n "${DSR_THRESHOLD:-}" ]] && _config_pending[threshold_seconds]="$DSR_THRESHOLD"
    [[ -n "${DSR_LOG_LEVEL:-}" ]] && _config_pending[log_level]="$DSR_LOG_LEVEL"
    if [[ "${DSR_NO_SIGN:-}" == 1 || "${DSR_NO_SIGN:-}" == true ]]; then
        _config_pending[signing_enabled]="false"
    fi
    [[ -n "${DSR_MINISIGN_KEY:-}" ]] && _config_pending[signing_key_path]="$DSR_MINISIGN_KEY"

    DSR_CONFIG=()
    for key in "${!_config_pending[@]}"; do
        DSR_CONFIG["$key"]="${_config_pending[$key]}"
    done

    return 0
}

_config_load_error() {
    _DSR_CONFIG_LOAD_ERROR="${_DSR_CONFIG_LOAD_ERROR:+$_DSR_CONFIG_LOAD_ERROR; }$*"
    _cfg_log_error "$*"
}

# Decode one complete document into config_load's private map. A properties
# file is not a lossless intermediary: it escapes controls and permits the
# same delimiter inside values. Keep literal strings in JSON until framing.
_config_load_yaml() {
    local file="$1" document entries key value complete=false
    if ! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        _config_load_error "Reading nonempty configuration requires yq (mikefarah/yq v4) and jq"
        return 3
    fi
    if ! document=$(_config_read_single_mapping_json "$file"); then
        _config_load_error "Cannot load configuration without one valid YAML mapping: $file"
        return 4
    fi
    if ! entries=$(_config_document_entries "$document"); then
        _config_load_error "Unsupported schema or ambiguous/unrepresentable configuration values: $file"
        return 4
    fi

    while IFS= read -r -d '' key; do
        # Empty keys cannot occur in the checked entries. This marker is
        # emitted only after successful serialization, never after failure.
        if [[ -z "$key" ]]; then
            complete=true
            break
        fi
        if ! IFS= read -r -d '' value; then
            _config_load_error "Incomplete configuration value stream: $file"
            return 3
        fi
        _config_pending["$key"]="$value"
    done < <(
        if printf '%s\n' "$entries" | jq -j '.[] | .key, "\u0000", .value, "\u0000"'; then
            printf '\0'
        fi
    )
    if ! $complete; then
        _config_load_error "Configuration decoding did not finish: $file"
        return 3
    fi
}

# Share scalar admission with validation without reparsing YAML. Null/empty
# legacy versions remain readable for migration; validation requires a version.
_config_document_entries() {
    jq -ce --arg schema "$DSR_SCHEMA_VERSION" '
        if has("schema_version") and
           (.schema_version != null and .schema_version != "" and .schema_version != $schema)
        then error("unsupported schema_version") else . end |
        [paths(type != "object" and type != "array") as $path |
            {key: ($path | map(tostring) | join(".")),
             value: (getpath($path) | if type == "string" then . else tostring end)}] |
        if any(.[]; .key == "" or (.key | contains("\u0000")) or (.value | contains("\u0000")))
        then error("configuration keys and values must be representable in Bash")
        elif (map(.key) | unique | length) != length
        then error("ambiguous dotted configuration paths")
        else sort_by(.key) end
    ' <<< "$1"
}

# Get a config value
# Usage: config_get <key> [default]
config_get() {
    local key="$1"
    local default="${2:-}"

    # Use ${var+x} pattern for Bash 4.0+ compatibility (avoids -v operator from 4.3+)
    if [[ -n "${DSR_CONFIG[$key]+x}" ]]; then
        printf '%s\n' "${DSR_CONFIG[$key]}"
    else
        printf '%s\n' "$default"
    fi
}

# Render an edit from the preserved original; never let yq edit a live path.
# The optional source is used for read-only preflight before acquiring a lock.
# Migration's version admission is repeated against the locked original.
_config_value_render() {
    local index="$1" source parsed
    source="${2:-${init_stages[index]}/original}"
    if ! parsed=$(_config_read_single_mapping_json "$source"); then
        _config_init_error "Cannot edit configuration without one valid YAML mapping: $source"
        return 4
    fi
    if [[ "$init_missing_schema" == true ]] && ! jq -e '
        (has("schema_version") | not) or .schema_version == null or .schema_version == ""
    ' <<< "$parsed" >/dev/null; then
        _config_init_error "Configuration schema changed before migration: $source"
        return 4
    fi
    # Only identifier paths reach this renderer. strenv preserves the value
    # literally, including quotes and newlines, without interpreting YAML/code.
    if ! DSR_SET_VALUE="$init_value" yq ".$init_key = strenv(DSR_SET_VALUE)" "$source"; then
        _config_init_error "Could not render configuration value for $init_key"
        return 1
    fi
}

# Persist one value using the initializer's transaction engine and leaf lock.
# The missing-schema guard is internal to migration, not a user yq program.
# Usage: _config_persist_value <key> <value> [missing_schema] [dry_run]
_config_persist_value() {
    local init_key="$1" init_value="$2" init_missing_schema="${3:-false}"
    local dry_run="${4:-${DRY_RUN:-false}}" force=true status=0 init_attempted_count=0
    local init_renderer=_config_value_render path
    local -a canonical_paths=("") backups=("") init_locks=("") init_stages=("")
    local -a init_before=("") init_candidates=("") init_selected=(true) init_attempted=()
    _DSR_CONFIG_INIT_BACKUP_PATHS=()
    _DSR_CONFIG_INIT_ERROR=""
    _DSR_CONFIG_INIT_ROLLED_BACK=false
    _DSR_CONFIG_INIT_RECOVERY_REQUIRED=false

    if [[ ! "$init_key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*$ ]]; then
        _config_init_error "Refusing to persist key with unsafe characters: $init_key"
        return 4
    fi
    if ! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        _config_init_error "Saving configuration requires yq (mikefarah/yq v4) and jq"
        return 3
    fi
    if ! path=$(_config_init_path "$DSR_CONFIG_FILE") || [[ -L "$path" || ! -f "$path" ]]; then
        _config_init_error "Configuration destination must be an existing regular file: $DSR_CONFIG_FILE"
        return 4
    fi
    canonical_paths[0]="$path"
    # Check the transformation without writes even on a real run. Re-render
    # from the verified original after the shared lock has been acquired.
    _config_value_render 0 "$path" >/dev/null || return $?
    if [[ "$dry_run" == true ]]; then
        _cfg_log_info "[dry-run] Would back up and set $init_key in $DSR_CONFIG_FILE"
        return 0
    fi

    _config_init_apply || status=$?
    if [[ $status -ne 0 ]]; then
        _config_init_rollback || true
    fi
    if ! $_DSR_CONFIG_INIT_RECOVERY_REQUIRED; then
        if ! _config_init_cleanup; then
            _DSR_CONFIG_INIT_RECOVERY_REQUIRED=true
            [[ $status -ne 0 ]] || status=1
        fi
    fi
    return "$status"
}

# Set a config value in memory, optionally committing it to disk first.
# A preview or failed persistence leaves the caller's configuration unchanged.
# Usage: config_set <key> <value> [--persist] [--dry-run]
config_set() {
    local key="${1:-}" value="${2:-}" persist=false dry_run="${DRY_RUN:-false}"
    _DSR_CONFIG_INIT_BACKUP_PATHS=()
    _DSR_CONFIG_INIT_ERROR=""
    _DSR_CONFIG_INIT_ROLLED_BACK=false
    _DSR_CONFIG_INIT_RECOVERY_REQUIRED=false
    if [[ $# -lt 2 || -z "$key" ]]; then
        _config_init_error "Usage: config_set <key> <value> [--persist] [--dry-run]"
        return 4
    fi
    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --persist) persist=true ;;
            --dry-run|-n) dry_run=true ;;
            *) _config_init_error "Unknown config set option: $1"; return 4 ;;
        esac
        shift
    done
    if $persist; then
        _config_persist_value "$key" "$value" false "$dry_run" || return $?
    fi
    if [[ "$dry_run" == true ]]; then
        $persist || _cfg_log_info "[dry-run] Would set $key in memory"
        return 0
    fi
    DSR_CONFIG["$key"]="$value"
    if $persist; then
        _cfg_log_ok "Set $key = $value (persisted; original backup retained)"
    else
        _cfg_log_info "Set $key = $value (in memory)"
    fi
}

# Validate configuration
# Usage: config_validate
# Returns: 0 if valid, 4 if invalid
config_validate() {
    local errors=0
    _DSR_CONFIG_LOAD_ERROR=""

    # Defaults and an earlier successful load are not evidence about the
    # document currently on disk. Validate its own schema independently.
    local primary_json=""
    if [[ ! -f "$DSR_CONFIG_FILE" || ! -r "$DSR_CONFIG_FILE" ]]; then
        _config_load_error "Configuration file is missing or unreadable: $DSR_CONFIG_FILE"
        ((errors++))
    elif ! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        _config_load_error "yq and jq are required to validate config.yaml"
        return 3
    elif ! primary_json=$(_config_read_single_mapping_json "$DSR_CONFIG_FILE"); then
        _config_load_error "Invalid YAML in config.yaml"
        ((errors++))
    elif ! jq -e --arg schema "$DSR_SCHEMA_VERSION" '
        has("schema_version") and (.schema_version | type == "string") and .schema_version == $schema
    ' <<< "$primary_json" >/dev/null; then
        _config_load_error "config.yaml must declare schema_version: $DSR_SCHEMA_VERSION"
        ((errors++))
    elif ! _config_document_entries "$primary_json" >/dev/null; then
        _config_load_error "Ambiguous or unrepresentable configuration values in config.yaml"
        ((errors++))
    fi

    # Check required directories exist
    if [[ ! -d "$DSR_CONFIG_DIR" ]]; then
        _cfg_log_error "Config directory missing: $DSR_CONFIG_DIR"
        _cfg_log_info "Run: dsr config init"
        ((errors++))
    fi

    # Check hosts.yaml if exists
    if [[ -f "$DSR_HOSTS_FILE" ]]; then
        if command -v yq &>/dev/null; then
            if ! yq '.' "$DSR_HOSTS_FILE" &>/dev/null; then
                _cfg_log_error "Invalid YAML in hosts.yaml"
                ((errors++))
            fi
        fi
    fi

    # Parse repos.yaml with the same single-document and duplicate-key rules
    # used for release decisions, then retain it for registry contract checks.
    local registry_json=""
    if [[ -f "$DSR_REPOS_FILE" ]]; then
        if ! command -v yq &>/dev/null || ! command -v jq &>/dev/null; then
            _cfg_log_error "yq and jq are required to validate repos.yaml"
            ((errors++))
        elif ! registry_json=$(_config_read_single_mapping_json "$DSR_REPOS_FILE"); then
            _cfg_log_error "Invalid YAML in repos.yaml"
            ((errors++))
        elif ! printf '%s\n' "$registry_json" | jq -e '
            ((.tools | type) == "object") and all(.tools[]; type == "object")
        ' >/dev/null; then
            _cfg_log_error "repos.yaml must contain a tools mapping of tool mappings"
            registry_json=""
            ((errors++))
        fi
    fi

    # Validate every opt-in per-repository release contract through the same
    # fail-closed parser used by build and release. A green `config validate`
    # must not disagree with the command that will publish assets.
    local repos_dir="$DSR_CONFIG_DIR/repos.d"
    if [[ -d "$repos_dir" ]]; then
        local had_nullglob=false
        shopt -q nullglob && had_nullglob=true
        shopt -s nullglob
        local repo_configs=("$repos_dir"/*.yaml)
        $had_nullglob || shopt -u nullglob

        local repo_config toolname
        for repo_config in "${repo_configs[@]}"; do
            toolname=$(basename "$repo_config" .yaml)
            if ! config_validate_release_contract "$toolname"; then
                _cfg_log_error "Invalid repository configuration: $repo_config"
                ((errors++))
            fi
        done
    fi

    # Registry-only tools have no repos.d file to drive the loop above.
    if [[ -n "$registry_json" ]]; then
        while IFS= read -r toolname; do
            [[ -n "$toolname" ]] || continue
            if ! config_validate_release_contract "$toolname"; then
                _cfg_log_error "Invalid registry configuration for tool: $toolname"
                ((errors++))
            fi
        done < <(printf '%s\n' "$registry_json" | jq -r \
            'if (.tools | type) == "object" then .tools | keys[] else empty end')
    fi

    if [[ $errors -eq 0 ]]; then
        _cfg_log_ok "Configuration valid"
        return 0
    else
        _cfg_log_error "Configuration has $errors error(s)"
        return 4
    fi
}

# Show configuration (human-readable or JSON)
# Usage: config_show [--json] [key] OR config_show [key] [--json]
config_show() {
    local key=""
    local json_mode=false

    # Parse arguments - handle --json in any position
    for arg in "$@"; do
        if [[ "$arg" == "--json" ]]; then
            json_mode=true
        elif [[ -z "$key" ]]; then
            key="$arg"
        fi
    done

    config_load || return $?
    _config_show_loaded "$key" "$json_mode"
}

# Format a map whose load already succeeded. The CLI uses this after its own
# checked load so human output does not parse the same file a second time.
_config_show_loaded() {
    local key="${1:-}" json_mode="${2:-false}" k
    if [[ "$json_mode" == true ]]; then
        if ! command -v jq >/dev/null 2>&1; then
            _config_load_error "jq is required for configuration JSON output"
            return 3
        fi
        # Stream values instead of manually escaping JSON or placing a whole
        # configuration into one exec argument. Both keys and values can
        # contain quotes, backslashes and trailing newlines.
        {
            for k in "${!DSR_CONFIG[@]}"; do
                if [[ -z "$key" || "$k" == "$key" || "$k" == "$key".* ]]; then
                    printf '%s\0%s\0' "$k" "${DSR_CONFIG[$k]}"
                fi
            done
        } | jq -Rs --arg config_dir "$DSR_CONFIG_DIR" --arg cache_dir "$DSR_CACHE_DIR" \
            --arg state_dir "$DSR_STATE_DIR" --arg config_file "$DSR_CONFIG_FILE" \
            --arg hosts_file "$DSR_HOSTS_FILE" --arg repos_file "$DSR_REPOS_FILE" '
            split("\u0000") | .[:-1] as $fields |
            {config_dir:$config_dir, cache_dir:$cache_dir, state_dir:$state_dir,
             config_file:$config_file, hosts_file:$hosts_file, repos_file:$repos_file,
             values: ([range(0; ($fields | length); 2) as $i |
                 {key:$fields[$i], value:$fields[$i+1]}] | sort_by(.key) | from_entries)}'
    else
        # Human-readable output
        echo "dsr Configuration"
        echo "================="
        echo ""
        echo "Directories:"
        echo "  config: $DSR_CONFIG_DIR"
        echo "  cache:  $DSR_CACHE_DIR"
        echo "  state:  $DSR_STATE_DIR"
        echo ""
        echo "Files:"
        echo "  config.yaml: $DSR_CONFIG_FILE"
        echo "  hosts.yaml:  $DSR_HOSTS_FILE"
        echo "  repos.yaml:  $DSR_REPOS_FILE"
        echo ""
        echo "Values:"
        # A key, or a section of dotted keys (signing -> signing.enabled).
        for k in "${!DSR_CONFIG[@]}"; do
            if [[ -z "$key" || "$k" == "$key" || "$k" == "$key".* ]]; then
                printf "  %-20s = %s\n" "$k" "${DSR_CONFIG[$k]}"
            fi
        done | LC_ALL=C sort
    fi
}

# Get host configuration
# Usage: config_get_host <hostname>
# Returns: JSON object with host config
config_get_host() {
    local hostname="$1"

    if [[ ! -f "$DSR_HOSTS_FILE" ]]; then
        _cfg_log_error "Hosts file not found: $DSR_HOSTS_FILE"
        return 4
    fi

    if command -v yq &>/dev/null; then
        yq ".hosts.$hostname" "$DSR_HOSTS_FILE"
    else
        _cfg_log_error "yq required for host configuration"
        return 3
    fi
}

# Get tool configuration
# Usage: config_get_tool <toolname>
# Returns: JSON object with tool config
config_get_tool() {
    local toolname="$1"

    if [[ ! -f "$DSR_REPOS_FILE" ]]; then
        _cfg_log_error "Repos file not found: $DSR_REPOS_FILE"
        return 4
    fi

    if command -v yq &>/dev/null; then
        yq ".tools.$toolname" "$DSR_REPOS_FILE"
    else
        _cfg_log_error "yq required for tool configuration"
        return 3
    fi
}

# Get a specific field from tool configuration
# Usage: config_get_tool_field <toolname> <field> [default]
# Returns: Field value or default (or empty if not found)
config_get_tool_field() {
    local toolname="$1"
    local field="$2"
    local default="${3:-}"

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"

    if [[ -f "$tool_config" ]] && command -v yq &>/dev/null; then
        local value
        value=$(yq -r ".$field" "$tool_config" 2>/dev/null)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    # Fallback to repos.yaml
    if [[ -f "$DSR_REPOS_FILE" ]] && command -v yq &>/dev/null; then
        local value
        value=$(yq -r ".tools.$toolname.$field" "$DSR_REPOS_FILE" 2>/dev/null)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    echo "$default"
}

# Parse exactly one YAML mapping document and reject duplicate mapping keys at
# every depth before jq can collapse them with last-key-wins semantics.
_config_read_single_mapping_json() {
    local config_file="$1"
    local docs_json canonical

    if [[ ! -f "$config_file" ]]; then
        _cfg_log_error "Configuration file not found: $config_file"
        return 4
    fi

    if ! yq -e \
        '[.. | select(tag == "!!map") | ((keys | length) == (keys | unique | length))] | all' \
        "$config_file" >/dev/null 2>&1; then
        _cfg_log_error "Duplicate YAML mapping key in: $config_file"
        return 4
    fi

    if ! docs_json=$(yq ea -o=json -I=0 '[.]' "$config_file" 2>/dev/null); then
        _cfg_log_error "Invalid YAML in: $config_file"
        return 4
    fi
    if ! canonical=$(printf '%s\n' "$docs_json" | jq -ce \
        'if length == 1 and (.[0] | type == "object") then .[0]
         else error("configuration must contain exactly one mapping document") end' \
        2>/dev/null); then
        _cfg_log_error "Configuration must contain exactly one YAML mapping document: $config_file"
        return 4
    fi

    printf '%s\n' "$canonical"
}

# Canonicalize a parsed release contract. A present contract must be an object;
# null is the opt-out used by legacy tool configurations.
_config_canonicalize_release_contract_json() {
    local raw_json="$1"

    if [[ "$raw_json" == "null" ]]; then
        printf 'null\n'
        return 0
    fi

    local canonical
    if ! canonical=$(printf '%s\n' "$raw_json" | jq -ceS \
        'if type == "object" then . else error("release_contract must be an object or null") end' 2>/dev/null); then
        _cfg_log_error "release_contract must be a YAML mapping or null"
        return 4
    fi

    printf '%s\n' "$canonical"
}

# Compare a tool's registry entry (repos.yaml) with its per-tool build config
# (repos.d/<tool>.yaml). The two files historically drifted apart silently:
# repos.yaml drives `dsr repos list/info/check` and the quality gates while
# the build runner reads only repos.d — so on divergence the tool you inspect
# is not the tool you build, which has produced wrong-target releases
# (issues #12/#13).
#
# Precedence contract (documented in README "Config precedence"):
#   - repos.d/<tool>.yaml is the build authority: build/release read it
#     exclusively for build-affecting keys.
#   - repos.yaml is the registry: list/info/check/quality read it.
#   - Any key present in both files must be identical.
#
# Usage: config_registry_divergence_json <toolname>
# stdout: compact JSON:
#   {registry: bool,                 # tool present in repos.yaml
#    repo_config: bool,              # repos.d/<tool>.yaml exists
#    tool_name: string|null,         # tool_name declared inside repos.d file
#    mismatched_keys: [key, ...],    # present in both files, values differ
#    registry_only_build_keys: [..]} # build-affecting keys only in repos.yaml
# rc: 0 with JSON on stdout; 3 when yq/jq missing; 4 on parse failure.
config_registry_divergence_json() {
    local toolname="${1:-}"
    if [[ -z "$toolname" ]]; then
        _cfg_log_error "Tool name required for registry divergence check"
        return 4
    fi
    if ! command -v yq &>/dev/null || ! command -v jq &>/dev/null; then
        _cfg_log_error "yq and jq are required for registry divergence checks"
        return 3
    fi

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"
    local registry_json="null" repo_json="null"

    if [[ -f "$DSR_REPOS_FILE" ]]; then
        registry_json=$(_config_read_single_mapping_json "$DSR_REPOS_FILE" | \
            jq -c --arg tool "$toolname" '.tools[$tool] // null' 2>/dev/null) || return 4
        [[ -n "$registry_json" ]] || return 4
    fi
    if [[ -f "$tool_config" ]]; then
        repo_json=$(_config_read_single_mapping_json "$tool_config") || return 4
    fi

    jq -nc --argjson registry "$registry_json" --argjson repo "$repo_json" '
        def build_keys: ["repo", "local_path", "language", "binary_name",
            "main_package", "workspace_binaries", "workspace_binaries_by_target", "build_cmd", "build_profile",
            "targets", "target_triples", "linux_libc_fallback", "cross_compile", "host_paths", "env",
            "artifact_naming", "install_script_compat", "install_script_path",
            "archive_format", "include_files", "include_extra_files",
            "workspace_archive_files", "workspace_additional_artifacts",
            "flat_archive", "sibling_crates",
            "release_contract", "act_job_map", "workflow", "linux_glibc_floor",
            "derive_cargo_build_target", "strict_cargo_cache_root"];
        {
            registry: ($registry != null),
            repo_config: ($repo != null),
            tool_name: (if $repo == null then null else ($repo.tool_name // null) end),
            mismatched_keys: (
                if $registry == null or $repo == null then []
                else [ ($registry | keys[]) as $k
                       | select(($repo | has($k)) and ($registry[$k] != $repo[$k]))
                       | $k ]
                     | sort
                end),
            registry_only_build_keys: (
                if $registry == null or $repo == null then []
                else [ build_keys[] as $k
                       | select(($registry | has($k)) and (($repo | has($k)) | not))
                       | $k ]
                end)
        }'
}

# Report Windows-host source-root problems for a tool (issue #8): every
# native windows/* target must resolve to a Windows host with a
# drive-qualified host_paths entry (C:/... or /c/...). A POSIX root can never
# work there — rsync targets the wrong location and the build-step validator
# rejects the path mid-build. One problem per line on stdout; empty when OK.
config_windows_host_path_problems() {
    local toolname="${1:-}"
    [[ -n "$toolname" ]] || return 0
    command -v yq &>/dev/null || return 0

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"
    [[ -f "$tool_config" ]] || return 0

    local target host host_platform host_path act_job
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        act_job=$(TARGET="$target" yq -r '.act_job_map[env(TARGET)] // ""' "$tool_config" 2>/dev/null)
        [[ "$act_job" == "null" ]] && act_job=""
        [[ -z "$act_job" ]] || continue

        host=$(TARGET="$target" yq -r '.cross_compile[env(TARGET)].host // ""' "$tool_config" 2>/dev/null)
        [[ "$host" == "null" ]] && host=""
        if [[ -z "$host" && -f "${DSR_HOSTS_FILE:-}" ]]; then
            host=$(TARGET="$target" yq -r '.platform_mapping[env(TARGET)] // ""' "$DSR_HOSTS_FILE" 2>/dev/null)
            [[ "$host" == "null" ]] && host=""
        fi
        [[ -n "$host" ]] || continue

        host_platform=""
        if [[ -f "${DSR_HOSTS_FILE:-}" ]]; then
            host_platform=$(HOST="$host" yq -r '.hosts[env(HOST)].platform // ""' "$DSR_HOSTS_FILE" 2>/dev/null)
            [[ "$host_platform" == "null" ]] && host_platform=""
        fi
        case "$host_platform" in
            windows/*) ;;
            "") [[ "$target" == windows/* ]] || continue ;;
            *) continue ;;
        esac

        host_path=$(HOST="$host" yq -r '.host_paths[env(HOST)] // ""' "$tool_config" 2>/dev/null)
        [[ "$host_path" == "null" ]] && host_path=""
        case "$host_path" in
            [A-Za-z]:[\\/]*|/[A-Za-z]/*) ;;
            "")
                printf 'target %s builds on Windows host %s but repos.d/%s.yaml has no host_paths.%s (needs a drive-qualified path, e.g. C:/Users/<user>/%s)\n' \
                    "$target" "$host" "$toolname" "$host" "$toolname"
                ;;
            *)
                printf 'target %s: host_paths.%s is not drive-qualified for Windows host %s (got %s; use C:/... or /c/...)\n' \
                    "$target" "$host" "$host" "$host_path"
                ;;
        esac
    done < <(yq -r '.targets[]?' "$tool_config" 2>/dev/null)
}

# Get the opt-in release contract for a tool as compact, canonical JSON.
# Per-tool repos.d configuration takes precedence over the registry file.
# Usage: config_get_release_contract_json <toolname>
# Returns: Canonical JSON object, or literal null when no contract is configured.
config_get_release_contract_json() {
    local toolname="${1:-}"

    if [[ -z "$toolname" ]]; then
        _cfg_log_error "Tool name required for release contract lookup"
        return 4
    fi
    if ! command -v yq &>/dev/null || ! command -v jq &>/dev/null; then
        _cfg_log_error "yq and jq are required for release contract parsing"
        return 3
    fi

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"
    local tool_json has_contract raw_json

    if [[ -f "$tool_config" ]]; then
        tool_json=$(_config_read_single_mapping_json "$tool_config") || return $?
        has_contract=$(printf '%s\n' "$tool_json" | jq -r 'has("release_contract")') || return 4
        if [[ "$has_contract" == "true" ]]; then
            if ! raw_json=$(printf '%s\n' "$tool_json" | jq -c '.release_contract'); then
                _cfg_log_error "Could not parse release_contract for $toolname"
                return 4
            fi
            _config_canonicalize_release_contract_json "$raw_json"
            return $?
        fi
    fi

    if [[ -f "$DSR_REPOS_FILE" ]]; then
        local registry_json
        registry_json=$(_config_read_single_mapping_json "$DSR_REPOS_FILE") || return $?
        if ! raw_json=$(printf '%s\n' "$registry_json" | jq -c --arg tool "$toolname" '
            if (.tools | type) != "object" then
                error("tools must be an object")
            elif (.tools | has($tool)) and ((.tools[$tool] | type) != "object") then
                error("tool entry must be an object")
            elif (.tools | has($tool)) and (.tools[$tool] | has("release_contract")) then
                .tools[$tool].release_contract
            else
                null
            end' 2>/dev/null); then
            _cfg_log_error "Could not parse release_contract for $toolname"
            return 4
        fi
    else
        raw_json="null"
    fi

    _config_canonicalize_release_contract_json "$raw_json"
}

# Canonicalize pinned sibling-crate checkouts for build-host validation. The
# public manifest projection below deliberately omits machine-local paths.
_config_canonicalize_release_source_dependency_checkouts_json() {
    local raw_json="$1"

    [[ "$raw_json" == "null" ]] && raw_json="[]"

    local canonical
    if ! canonical=$(printf '%s\n' "$raw_json" | jq -ceS '
        def safe_relative_path:
            type == "string" and
            length > 0 and
            test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and
            (contains("..") | not) and
            (endswith(".") | not) and
            ((ascii_downcase | test("^(con|prn|aux|nul|com[1-9]|lpt[1-9])($|\\.)")) | not);
        def exact_git_sha:
            type == "string" and
            test("^[0-9a-f]{40}$") and
            . != "0000000000000000000000000000000000000000";

        if type != "array" then
            error("sibling_crates must be an array or null")
        elif ([.[] |
            type == "object" and
            has("local_path") and (.local_path | type == "string" and startswith("/") and length > 1) and
            has("relative_path") and (.relative_path | safe_relative_path) and
            has("revision") and (.revision | exact_git_sha)
        ] | all | not) then
            error("each sibling_crates entry requires local_path, safe relative_path, and exact revision")
        elif ([.[].relative_path | ascii_downcase] | unique | length) != length then
            error("sibling_crates relative_path values must be portable and case-insensitively unique")
        else
            map({relative_path, local_path, git_sha: .revision}) | sort_by(.relative_path)
        end
    ' 2>/dev/null); then
        _cfg_log_error "Invalid pinned sibling_crates configuration"
        return 4
    fi

    printf '%s\n' "$canonical"
}

# Internal: get machine-local pinned checkout descriptions. Per-tool repos.d
# configuration takes precedence over repos.yaml.
_config_get_release_source_dependency_checkouts_json() {
    local toolname="${1:-}"

    if [[ -z "$toolname" ]]; then
        _cfg_log_error "Tool name required for release source dependency lookup"
        return 4
    fi
    if ! command -v yq &>/dev/null || ! command -v jq &>/dev/null; then
        _cfg_log_error "yq and jq are required for release source dependency parsing"
        return 3
    fi

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"
    local tool_json has_siblings raw_json

    if [[ -f "$tool_config" ]]; then
        tool_json=$(_config_read_single_mapping_json "$tool_config") || return $?
        has_siblings=$(printf '%s\n' "$tool_json" | jq -r 'has("sibling_crates")') || return 4
        if [[ "$has_siblings" == "true" ]]; then
            raw_json=$(printf '%s\n' "$tool_json" | jq -c '.sibling_crates') || return 4
            _config_canonicalize_release_source_dependency_checkouts_json "$raw_json"
            return $?
        fi
    fi

    if [[ -f "$DSR_REPOS_FILE" ]]; then
        local registry_json
        registry_json=$(_config_read_single_mapping_json "$DSR_REPOS_FILE") || return $?
        if ! raw_json=$(printf '%s\n' "$registry_json" | jq -c --arg tool "$toolname" '
            if (.tools | type) != "object" then
                error("tools must be an object")
            elif (.tools | has($tool)) and ((.tools[$tool] | type) != "object") then
                error("tool entry must be an object")
            elif (.tools | has($tool)) and (.tools[$tool] | has("sibling_crates")) then
                .tools[$tool].sibling_crates
            else
                null
            end' 2>/dev/null); then
            _cfg_log_error "Could not parse sibling_crates for $toolname"
            return 4
        fi
    else
        raw_json="null"
    fi

    _config_canonicalize_release_source_dependency_checkouts_json "$raw_json"
}

# Get the exact source-dependency identities that a strict release manifest
# must record, excluding host-local checkout paths.
# Usage: config_get_release_source_dependencies_json <toolname>
# Returns: Compact canonical JSON array sorted by relative_path.
config_get_release_source_dependencies_json() {
    local toolname="${1:-}"
    local checkouts_json

    checkouts_json=$(_config_get_release_source_dependency_checkouts_json "$toolname") || return $?
    printf '%s\n' "$checkouts_json" | jq -ceS \
        'map({relative_path, git_sha}) | sort_by(.relative_path)' 2>/dev/null
}

# Internal: get configured targets using the same per-tool precedence as the
# release contract lookup. The raw array shape is validated by the caller.
_config_get_tool_targets_json() {
    local toolname="$1"
    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"
    local tool_json has_targets raw_json

    if [[ -f "$tool_config" ]]; then
        tool_json=$(_config_read_single_mapping_json "$tool_config") || return $?
        has_targets=$(printf '%s\n' "$tool_json" | jq -r 'has("targets")') || return 4
        if [[ "$has_targets" == "true" ]]; then
            raw_json=$(printf '%s\n' "$tool_json" | jq -c '.targets') || return 4
            printf '%s\n' "$raw_json" | jq -c . 2>/dev/null
            return $?
        fi
    fi

    if [[ -f "$DSR_REPOS_FILE" ]]; then
        local registry_json
        registry_json=$(_config_read_single_mapping_json "$DSR_REPOS_FILE") || return $?
        raw_json=$(printf '%s\n' "$registry_json" | jq -c --arg tool "$toolname" '
            if (.tools | type) != "object" then
                error("tools must be an object")
            elif (.tools | has($tool)) and ((.tools[$tool] | type) != "object") then
                error("tool entry must be an object")
            elif (.tools | has($tool)) and (.tools[$tool] | has("targets")) then
                .tools[$tool].targets
            else
                null
            end' 2>/dev/null) || return 4
    else
        raw_json="null"
    fi
    printf '%s\n' "$raw_json" | jq -c . 2>/dev/null
}

# An absent matrix is permitted for source-only tools; an explicitly supplied
# matrix must be supported even when no strict release contract is enabled.
config_validate_targets() {
    local toolname="${1:-}" targets_json
    targets_json=$(_config_get_tool_targets_json "$toolname") || {
        _cfg_log_error "Could not parse configured targets for $toolname"
        return 4
    }
    [[ "$targets_json" == null ]] && return 0
    dsr_platform_validate_targets_json "$targets_json" "targets for $toolname"
}

# Additional release files have literal, globally unique names. Their declared
# format is build policy, not a value an untrusted producer receipt may choose.
# This pure normalizer is shared by preflight, native readers and workflow
# payload planning. Producer-specific ownership and byte admission happen in
# those consumers; a workflow job is a supported producer, not a native alias.
config_normalize_additional_artifacts_json() {
    local raw="${1:-null}" context="${2:-workspace_additional_artifacts}" normalized
    local act_jobs="${3:-null}"
    if ! normalized=$(jq -csSe --arg context "$context" \
        --argjson act_jobs "$act_jobs" \
        --arg platform_pattern "$(dsr_platform_pattern)" '
        def refuse($message): error($context + ": " + $message);
        def safe_name:
            type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and
            (test("[\u0000-\u001f\u007f]") | not) and
            (contains("..") | not);
        def release_metadata_name:
            ascii_downcase | test("(\\.minisig|\\.sig|\\.sha256|\\.sha512|\\.intoto\\.jsonl)$|^sha256sums|^checksums\\.txt$|\\.sbom\\.");
        if length != 1 then refuse("expected one platform mapping") else .[0] end |
        if . == null then {} else . end |
        if type != "object" then refuse("expected a platform mapping") else . end |
        to_entries | map(
            .key as $platform |
            if ($platform | test("[\u0000-\u001f\u007f]") or (test($platform_pattern) | not))
            then refuse("unsupported platform " + ($platform | tojson))
            elif (.value | type) != "array" then refuse($platform + " requires an array")
            else .value |= map(
                if type == "string" then {name:., format:"file"}
                elif type == "object" and
                     (keys == ["format", "name"] or keys == ["format", "name", "target_triple"]) then .
                else refuse($platform + " requires names or {name,format,target_triple?} declarations") end |
                .format as $format |
                if (.name | safe_name | not)
                then refuse($platform + " has an unsafe artifact name: " + (.name | tojson))
                elif (.name | release_metadata_name)
                then refuse($platform + " uses a reserved release metadata name: " + .name)
                elif ($format | type) != "string" or
                     (["file","binary","json","zip","tar.gz","tar.xz","msi"] | index($format)) == null
                then refuse($platform + " has an unsupported format for " + .name + ": " + (.format | tojson))
                elif has("target_triple") and
                     (.target_triple | type != "string" or
                      (test("^[A-Za-z0-9][A-Za-z0-9._-]*$") | not) or contains(".."))
                then refuse($platform + " has an invalid target_triple for " + .name)
                else . end
            ) end |
            if (.value | length) == 0 then .
            elif $act_jobs != null and ($act_jobs | type) != "object"
            then refuse("act_job_map must be a platform mapping")
            else $act_jobs[$platform] as $job |
                if $job != null and ($job | type) != "string"
                then refuse($platform + " has an invalid act job selector: " + ($job | tojson))
                elif ($job | type) == "string" and ($job | test("[\u0000-\u001f\u007f]"))
                then refuse($platform + " has a control character in its act job selector")
                else . end
            end
        ) | from_entries |
        [.[][] | .name | ascii_downcase] as $names |
        ($names | group_by(.) | map(select(length > 1) | .[0])) as $duplicates |
        if ($duplicates | length) > 0
        then refuse("artifact names must have one producer and be distinct ignoring case: " + ($duplicates | join(", ")))
        else . end
    ' <<< "$raw" 2>&1); then
        _cfg_log_error "Invalid $context: $normalized"
        return 4
    fi
    printf '%s\n' "$normalized"
}

# Bind each literal companion to a configured producer, independently of its
# filename. Preserve an explicit target_triple as content policy; an omitted
# selector retains the existing first-variant producer without inventing an
# explicit compiler claim on shared strict-contract metadata.
config_resolve_additional_artifact_owners_json() {
    local normalized="$1" mapping="${2:-null}" resolved
    if ! resolved=$(jq -ce --argjson mapping "$mapping" '
        def triple: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and
            (contains("..") | not);
        def variants:
            if . == null then []
            elif triple then [.]
            elif type == "array" and length > 0 and all(.[]; triple) and
                 length == (unique | length) then .
            else error("invalid configured companion target variants") end;
        (if $mapping == null then {} else $mapping end) as $m |
        if ($m | type) != "object" then error("target_triples must be a platform mapping") else . end |
        to_entries | map(.key as $platform |
            ($m[$platform] | variants) as $variants |
            .value |= map(
                if has("target_triple") and
                   (.target_triple as $triple | ($variants | index($triple)) == null)
                then error("additional artifact " + .name + " has an unconfigured target_triple for " + $platform)
                else . + {owner_target_triple:(.target_triple // $variants[0] // "")} end
            )) | from_entries
    ' <<< "$normalized" 2>&1); then
        _cfg_log_error "Invalid additional artifact ownership: $resolved"
        return 4
    fi
    printf '%s\n' "$resolved"
}

# repos.d is the native build authority, including an absent declaration. Only
# registry-only tools are read from repos.yaml, matching native selector policy.
# False and malformed mappings must never disappear through a defaulting
# operator before the shared normalizer sees them.
config_get_additional_artifacts_json() {
    local toolname="${1:-}" document raw="null" act_jobs="null" normalized mapping
    local tool_config="${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d/${toolname}.yaml"
    [[ -n "$toolname" ]] || return 4
    if [[ -f "$tool_config" ]]; then
        document=$(_config_read_single_mapping_json "$tool_config") || return 4
        act_jobs=$(jq -c '.act_job_map' <<< "$document") || return 4
        raw=$(jq -c '.workspace_additional_artifacts' <<< "$document") || return 4
    elif [[ -f "$DSR_REPOS_FILE" ]]; then
        document=$(_config_read_single_mapping_json "$DSR_REPOS_FILE") || return 4
        raw=$(jq -c --arg tool "$toolname" '
            if (.tools | type) != "object" then error("tools must be an object")
            elif (.tools | has($tool)) and (.tools[$tool] | type) != "object"
            then error("tool entry must be an object")
            else .tools[$tool].workspace_additional_artifacts end
        ' <<< "$document") || return 4
        act_jobs=$(jq -c --arg tool "$toolname" '.tools[$tool].act_job_map' <<< "$document") || return 4
    fi
    normalized=$(config_normalize_additional_artifacts_json "$raw" \
        "workspace_additional_artifacts for $toolname" "$act_jobs") || return 4
    if jq -e 'any(.[][]; has("target_triple"))' <<< "$normalized" >/dev/null; then
        mapping=$(_config_target_triples_json "$toolname") || return 4
        config_resolve_additional_artifact_owners_json "$normalized" "$mapping" >/dev/null || return 4
    fi
    printf '%s\n' "$normalized"
}

config_get_additional_artifact_owners_json() {
    local normalized mapping
    normalized=$(config_get_additional_artifacts_json "$1") || return 4
    mapping=$(_config_target_triples_json "$1") || return 4
    config_resolve_additional_artifact_owners_json "$normalized" "$mapping"
}

# Exact release identities follow native task identities. A singleton retains
# its physical platform key; multiple configured triples each own a qualified
# key. Keep the original platform/triple order for scheduling and ownership.
# An empty singleton triple means the existing backend default is selected.
# Usage: config_get_release_contract_targets_json <toolname>
config_get_release_contract_targets_json() {
    local toolname="${1:-}" targets mapping rows
    targets=$(_config_get_tool_targets_json "$toolname") || return 4
    mapping=$(_config_target_triples_json "$toolname") || return 4
    dsr_platform_validate_targets_json "$targets" "release targets for $toolname" || return 4
    if ! rows=$(jq -cen --argjson targets "$targets" --argjson mapping "$mapping" \
        --arg platform_pattern "$(dsr_platform_pattern)" '
        def platform: type == "string" and (test("[\u0000-\u001f\u007f]") | not) and test($platform_pattern);
        def triple: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and
            (contains("..") | not);
        def variants:
            if . == null then [""]
            elif triple then [.]
            elif type == "array" and length > 0 and all(.[]; triple) and
                length == (unique | length) then .
            else error("invalid configured target variants") end;
        if ($targets | type != "array" or length == 0 or
            (all(.[]; platform) | not) or length != (unique | length))
        then error("invalid configured release platforms") else . end |
        (if $mapping == null then {} else $mapping end) as $m |
        if ($m | type != "object") then error("invalid target triple mapping") else . end |
        [$targets[] as $platform | ($m[$platform] | variants) as $triples |
         $triples | to_entries[] |
         {key:(if ($triples | length) == 1 then $platform else $platform + "@" + .value end),
          platform:$platform, target_triple:.value, primary:(.key == 0)}]
    ' 2>/dev/null); then
        _cfg_log_error "Invalid release target identities for $toolname"
        return 4
    fi
    printf '%s\n' "$rows"
}

# Never infer which variant a strict naming or staging request intended.
# Usage: config_get_release_contract_target_key <toolname> <platform> [target_triple]
config_get_release_contract_target_key() {
    local toolname="${1:-}" platform="${2:-}" selected="${3:-}" rows key
    rows=$(config_get_release_contract_targets_json "$toolname") || return 4
    if ! key=$(jq -er --arg platform "$platform" --arg selected "$selected" '
        [.[] | select(.platform == $platform)] |
        if length == 1 then
            .[0] | if $selected == "" or .target_triple == "" or .target_triple == $selected
                then .key else error("selected triple differs from configuration") end
        elif length > 1 and $selected != "" then
            [.[] | select(.target_triple == $selected)] |
            if length == 1 then .[0].key else error("unconfigured selected triple") end
        else error("missing platform or ambiguous selected triple") end
    ' <<< "$rows" 2>/dev/null); then
        _cfg_log_error "Missing or conflicting release target selection for $toolname $platform"
        return 4
    fi
    printf '%s\n' "$key"
}

# Validate an opt-in exact release asset contract.
# Usage: config_validate_release_contract <toolname>
# Returns: 0 for a valid contract or no contract, 4 for an invalid contract.
config_validate_release_contract() {
    local toolname="${1:-}"
    local contract_json targets_json identities_json

    config_validate_targets "$toolname" || return 4
    config_get_additional_artifacts_json "$toolname" >/dev/null || return 4
    contract_json=$(config_get_release_contract_json "$toolname") || return $?
    # Target triples decide release asset names with or without a contract;
    # every build, release and `config validate` passes through here.
    config_validate_target_triples "$toolname" || return 4
    [[ "$contract_json" == "null" ]] && return 0

    if ! targets_json=$(_config_get_tool_targets_json "$toolname"); then
        _cfg_log_error "Could not parse configured targets for $toolname"
        return 4
    fi
    identities_json=$(config_get_release_contract_targets_json "$toolname") || return 4

    if jq -en \
        --argjson contract "$contract_json" \
        --argjson targets "$targets_json" --argjson identities "$identities_json" '
        def safe_name:
            if type != "string" then false
            else
                length > 0 and
                test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and
                (contains("/") | not) and
                (contains("..") | not)
            end;
        def safe_path_component:
            type == "string" and
            length > 0 and
            test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and
            . != "." and
            . != "..";
        def safe_project_path:
            type == "string" and
            length > 0 and
            (startswith("/") | not) and
            (contains("\\") | not) and
            (split("/") | all(.[]; safe_path_component));
        def safe_primary:
            safe_name and
            (ascii_downcase | endswith(".sha256") | not) and
            (ascii_downcase | endswith(".minisig") | not);

        if ($contract | type) != "object" then false
        elif ($targets | type) != "array" then false
        elif (($contract | has("checksum_sidecar")) | not) then false
        elif (($contract | has("exact_primary_assets")) | not) then false
        elif (($contract | keys) - [
            "build_manifest_assets",
            "checksum_sidecar",
            "exact_additional_assets",
            "exact_primary_assets",
            "github_tag_ruleset",
            "minisign_public_key_file"
        ] | length) != 0 then false
        elif $contract.checksum_sidecar != "sha256" then false
        elif ($contract.exact_primary_assets | type) != "object" then false
        elif (($contract.exact_additional_assets // []) | type) != "array" then false
        # Public names for the generated build manifest (GH #18): one or two
        # literal .json basenames; the second is a byte-identical alias.
        elif ($contract | has("build_manifest_assets")) and
             (($contract.build_manifest_assets | type) != "array" or
              ($contract.build_manifest_assets | length) < 1 or
              ($contract.build_manifest_assets | length) > 2 or
              ([$contract.build_manifest_assets[] |
                 safe_primary and (ascii_downcase | endswith(".json")) and
                 (. as $name | ["SHA256SUMS", "SHA256SUMS.txt", "checksums.txt"] |
                     index($name) | not)] | all | not)) then false
        elif ($contract | has("minisign_public_key_file")) and
             (($contract.minisign_public_key_file | safe_project_path) | not) then false
        elif ($contract | has("github_tag_ruleset")) and
             (($contract.github_tag_ruleset | type) != "object" or
              (($contract.github_tag_ruleset | keys) -
               ["repository_id", "ruleset_id"] | length) != 0 or
              (($contract.github_tag_ruleset | keys | length) != 2) or
              ($contract.github_tag_ruleset.repository_id | type) != "number" or
              ($contract.github_tag_ruleset.repository_id | floor) !=
                $contract.github_tag_ruleset.repository_id or
              $contract.github_tag_ruleset.repository_id <= 0 or
              ($contract.github_tag_ruleset.ruleset_id | type) != "number" or
              ($contract.github_tag_ruleset.ruleset_id | floor) !=
                $contract.github_tag_ruleset.ruleset_id or
              $contract.github_tag_ruleset.ruleset_id <= 0) then false
        elif ($targets | length) == 0 then false
        elif ([$targets[] | if type == "string" then length > 0 else false end] | all | not) then false
        elif (($targets | unique | length) != ($targets | length)) then false
        else
            ($contract.exact_primary_assets | [.[]]) as $primaries |
            ($contract |
                if has("exact_additional_assets")
                then .exact_additional_assets
                else []
                end) as $additional |
            ($contract |
                if has("minisign_public_key_file")
                then ($primaries | map(. + ".minisig"))
                else []
                end) as $signatures |
            ($primaries + ($primaries | map(. + ".sha256")) + $signatures + $additional +
                ($contract.build_manifest_assets // [])) as $all_assets |
            (($contract.exact_primary_assets | keys | sort) == ($identities | map(.key) | sort)) and
            ([$contract.exact_primary_assets[] | safe_primary] | all) and
            ([$additional[] | safe_name] | all) and
            (($contract.exact_primary_assets | [.[]] | unique | length) ==
             ($contract.exact_primary_assets | length)) and
            (($all_assets | map(ascii_downcase) | unique | length) == ($all_assets | length))
        end
    ' >/dev/null 2>&1; then
        if ! config_get_release_source_dependencies_json "$toolname" >/dev/null; then
            _cfg_log_error "Invalid release source dependencies for $toolname"
            return 4
        fi
        return 0
    fi

    _cfg_log_error "Invalid release_contract for $toolname"
    return 4
}

# Get install_script_compat pattern for a tool
# This is the naming pattern expected by install.sh scripts
# Usage: config_get_install_script_compat <toolname>
# Returns: Compat pattern (e.g., "${name}-${os}-${arch}") or empty
config_get_install_script_compat() {
    local toolname="$1"
    config_get_tool_field "$toolname" "install_script_compat" ""
}

# Get install_script_path for a tool
# When set, dsr parses this script to auto-detect the expected naming pattern
# Usage: config_get_install_script_path <toolname>
# Returns: Path to install.sh (relative to repo root) or empty
config_get_install_script_path() {
    local toolname="$1"
    config_get_tool_field "$toolname" "install_script_path" ""
}

# Get artifact naming pattern for a tool
# Usage: config_get_artifact_naming <toolname>
# Returns: Naming pattern (e.g., "${name}-${version}-${os}-${arch}") or empty
config_get_artifact_naming() {
    local toolname="$1"
    config_get_tool_field "$toolname" "artifact_naming" ""
}

# Raw target_triples mapping for a tool as JSON (repos.d file first, then the
# registry), or null when neither configures one.
_config_target_triples_json() {
    local toolname="$1"
    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"
    local value_json="null"

    command -v yq &>/dev/null || { echo null; return 0; }
    if [[ -f "$tool_config" ]]; then
        value_json=$(yq -o=json '.target_triples' "$tool_config" 2>/dev/null) || return 4
    fi
    if [[ -z "$value_json" || "$value_json" == "null" ]] && [[ -f "${DSR_REPOS_FILE:-}" ]]; then
        value_json=$(DSR_TOOL="$toolname" yq -o=json '.tools[strenv(DSR_TOOL)].target_triples' \
            "$DSR_REPOS_FILE" 2>/dev/null) || return 4
    fi
    [[ -n "$value_json" ]] || value_json="null"
    jq -c . <<< "$value_json" 2>/dev/null || return 4
}

# Target triples configured for one platform, primary first.
# A platform maps to one triple or to a list of variants (bd-cdcz):
#   target_triples:
#     linux/amd64: [x86_64-unknown-linux-gnu, x86_64-unknown-linux-musl]
# The first entry owns shared platform assets; native builds compile every
# entry. An ordinary artifact whose name identifies no variant is named as
# the primary. Prints one triple
# per line, or nothing when the platform is not configured.
# Usage: config_get_target_triples <toolname> <platform>
# Exit: 0 on success, 4 on an invalid mapping
config_get_target_triples() {
    local toolname="$1"
    local platform="$2"
    local mapping_json
    mapping_json=$(_config_target_triples_json "$toolname") || {
        _cfg_log_error "Could not read target_triples for $toolname"
        return 4
    }
    jq -r --arg platform "$platform" '
        def triple: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (contains("..") | not);
        if . == null then empty
        elif type != "object" then error("target_triples must map platforms to triples")
        else .[$platform] |
            if . == null then empty
            elif triple then .
            elif type == "array" and length > 0 and all(.[]; triple) and length == (unique | length) then .[]
            else error("expected a triple or a non-empty list of distinct triples") end
        end' <<< "$mapping_json" 2>/dev/null || {
        _cfg_log_error "Invalid target_triples for $toolname $platform: expected a triple or a non-empty list of distinct triples"
        return 4
    }
}

# Ordered JSON view for manifest/build consumers that must retain every variant.
config_get_target_triples_json() {
    local triples
    triples=$(config_get_target_triples "$1" "$2") || return $?
    printf '%s' "$triples" | jq -Rsc 'if length == 0 then [] else split("\n") end'
}

# Automatic installer fallback is opt-in, one-way GNU -> musl. Preserve field
# presence: null/false are invalid policy values, not an absent configuration.
config_get_linux_libc_fallback() {
    local toolname="$1" config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml" value_json='"none"' document
    if [[ -f "$tool_config" ]]; then
        document=$(_config_read_single_mapping_json "$tool_config") || return 4
        if jq -e 'has("linux_libc_fallback")' <<< "$document" >/dev/null; then
            value_json=$(jq -c '.linux_libc_fallback' <<< "$document") || return 4
        elif [[ -f "${DSR_REPOS_FILE:-}" ]]; then
            document=$(_config_read_single_mapping_json "$DSR_REPOS_FILE") || return 4
            value_json=$(jq -c --arg tool "$toolname" '
                .tools[$tool] // {} |
                if has("linux_libc_fallback") then .linux_libc_fallback else "none" end
            ' <<< "$document") || return 4
        fi
    elif [[ -f "${DSR_REPOS_FILE:-}" ]]; then
        document=$(_config_read_single_mapping_json "$DSR_REPOS_FILE") || return 4
        value_json=$(jq -c --arg tool "$toolname" '
            .tools[$tool] // {} |
            if has("linux_libc_fallback") then .linux_libc_fallback else "none" end
        ' <<< "$document") || return 4
    fi
    jq -er 'if . == "none" or . == "musl" then . else error("invalid libc fallback") end' \
        <<< "$value_json" 2>/dev/null || {
        _cfg_log_error "Invalid linux_libc_fallback for $toolname: expected none or musl"
        return 4
    }
}

# Primary target triple for a tool/platform
# Usage: config_get_target_triple <toolname> <platform>
# Returns: Target triple (e.g., "x86_64-unknown-linux-gnu") or empty
config_get_target_triple() {
    local triples
    triples=$(config_get_target_triples "$1" "$2") || return $?
    printf '%s\n' "${triples%%$'\n'*}"
}

# Validate every target_triples entry of a tool. Strict release validation
# separately requires an exact primary for every canonical platform/triple key.
# Usage: config_validate_target_triples <toolname>
config_validate_target_triples() {
    local toolname="$1"
    local mapping_json platform triples triple
    config_validate_gnu_target_suffixes "$toolname" || return $?
    config_get_linux_libc_fallback "$toolname" >/dev/null || return 4
    mapping_json=$(_config_target_triples_json "$toolname") || {
        _cfg_log_error "Could not read target_triples for $toolname"
        return 4
    }
    [[ "$mapping_json" == "null" ]] && return 0
    if ! jq -e 'type == "object"' <<< "$mapping_json" >/dev/null 2>&1; then
        _cfg_log_error "Invalid target_triples for $toolname: expected a mapping of platform to triple(s)"
        return 4
    fi
    while IFS= read -r platform; do
        if ! dsr_platform_is_supported "$platform"; then
            _cfg_log_error "Unsupported target_triples platform for $toolname: $platform (select a supported os/arch target)"
            return 4
        fi
        triples=$(config_get_target_triples "$toolname" "$platform") || return 4
        # The effective mapping may fall back to the registry even when the
        # per-tool file owns build_cmd. Validate that selected mapping too.
        while IFS= read -r triple; do
            _config_reject_gnu_target_suffix "$toolname" "target_triples[$platform]" "$triple" || return 4
        done <<< "$triples"
    done < <(jq -r 'keys[]' <<< "$mapping_json")
}

# A Zig glibc floor is not a Rust target identity (GH #37). Keep target maps
# and environment identities plain. The native observer can separately bind
# an explicit cargo-zigbuild ABI request to that Rust target; reuse its command
# parser before admitting such a request through the public configuration gate.
# Never strip a suffix from configured identities or retained worker receipts.
# This is a literal-selector check, not shell evaluation. Dynamically assembled
# selectors remain subject to the existing native command/receipt validators.
_config_gnu_target_selector_rows_json() {
    jq -ceS '
        def identities($path):
            if type == "string" then {path:$path,value:.,kind:"identity"}
            elif type == "array" then to_entries[] | . as $entry |
                $entry.value | identities($path+"["+($entry.key|tostring)+"]")
            else empty end;
        def scope($path; $command_active):
            . as $scope |
            (if $command_active and (.build_cmd | type == "string") then
                {path:($path+"build_cmd"),value:.build_cmd,kind:"command"}
             else empty end),
            (if $scope.env | type == "object" then
                $scope.env | to_entries[] |
                select(.key=="CARGO_BUILD_TARGET" or .key=="DSR_TARGET_TRIPLE") |
                . as $entry | .value | identities($path+"env."+$entry.key)
             else empty end),
            (if $path != "" then .target | identities($path+"target") else empty end);
        def all_commands_overridden:
            . as $config |
            if (.targets | type == "array" and length > 0) and
               (.cross_compile | type == "object") then
                all(.targets[]; . as $platform |
                    $config.cross_compile[$platform].build_cmd |
                    if type == "string" then length > 0 else false end)
            else false end;
        if type != "object" then error("expected tool configuration object") else
            # Per-platform commands replace the global recipe. Do not make an
            # unused global recipe a new restriction on a fully explicit matrix.
            [scope(""; (all_commands_overridden | not)),
             (if .cross_compile | type == "object" then
                 .cross_compile | to_entries[] | select(.value|type=="object") |
                 . as $entry | .value | scope("cross_compile["+($entry.key|tojson)+"]."; true)
              else empty end),
             (if .target_triples | type == "object" then
                 .target_triples | to_entries[] | . as $entry |
                 .value | identities("target_triples["+($entry.key|tojson)+"]")
              else empty end)] | unique
        end
    '
}

# Read literal shell words without executing expansions or sourcing a command.
# Quotes concatenate word fragments; a quoted diagnostic is one word, not an
# embedded --target invocation. Control operators keep adjacent commands apart.
# This intentionally does not interpret variables, substitutions or shell scripts
# passed as a single argument to another interpreter.
_config_literal_target_words() {
    local LC_ALL=C
    local text="$1" word='' quote='' ch next i started=false
    for ((i=0; i<${#text}; i++)); do
        ch=${text:i:1}
        if [[ "$quote" == "'" ]]; then
            if [[ "$ch" == "'" ]]; then quote=''; else word+="$ch"; fi
        elif [[ "$ch" == '\' ]]; then
            next=${text:i+1:1}
            if [[ "$quote" == '"' && "$next" != [\$\`\"\\] && "$next" != $'\n' ]]; then
                word+="$ch"
            else
                [[ -n "$next" ]] || return 4
                [[ "$next" == $'\n' ]] || { word+="$next"; started=true; }
                i=$((i+1))
            fi
        elif [[ -n "$quote" ]]; then
            if [[ "$ch" == "$quote" ]]; then quote=''; else word+="$ch"; fi
        else
            case "$ch" in
                "'"|'"') quote="$ch"; started=true ;;
                ' '|$'\t'|$'\r')
                    if [[ "$started" == true ]]; then printf '%s\0' "$word"; fi
                    word=''; started=false ;;
                $'\n'|';'|'&'|'|'|'('|')'|'<'|'>')
                    if [[ "$started" == true ]]; then printf '%s\0' "$word"; fi
                    printf '%s\0' ';'
                    word=''; started=false ;;
                '#')
                    if [[ "$started" == false ]]; then
                        while ((i+1<${#text})) && [[ "${text:i+1:1}" != $'\n' ]]; do i=$((i+1)); done
                    else word+="$ch"; fi ;;
                *) word+="$ch"; started=true ;;
            esac
        fi
    done
    [[ -z "$quote" ]] || return 4
    if [[ "$started" == true ]]; then printf '%s\0' "$word"; fi
}

_config_reject_gnu_target_suffix() {
    local tool="$1" path="$2" value="$3" triple floor
    if [[ "$value" =~ ^([A-Za-z0-9_+-]+(-[A-Za-z0-9_+-]+)*-linux-gnu[a-z0-9_]*)\.([0-9]+\.[0-9]+)$ ]]; then
        triple=${BASH_REMATCH[1]}; floor=${BASH_REMATCH[3]}
        _cfg_log_error "$tool $path: glibc-qualified target $triple.$floor cannot be a Rust identity; use plain $triple with linux_glibc_floor: \"$floor\", or a direct cargo zigbuild --target $triple.$floor build command"
        return 4
    fi
}

# Selection mode reads literal command intent without running Cargo, reading
# project/ambient Cargo configuration or trusting a worker receipt. Source the
# authoritative parser in a private privileged shell so inherited functions and
# BASH_ENV cannot replace it; command bytes enter this child over stdin, not as
# shell source or another exec argument. Keep its detailed
# diagnostics private because command arguments can contain secrets.
_config_validate_explicit_zigbuild_command() {
    local command="$1" selection
    [[ "${_DSR_CONFIG_MODULE_DIR:-}" == /* ]] || return 4
    selection=$(printf '%s\0' "$command" | "$BASH" -p -c '
        IFS= read -r -d "" command || exit 4
        source "$1/act_runner.sh" || exit 4
        _act_explicit_zigbuild_selection "$command" ""
    ' _ "$_DSR_CONFIG_MODULE_DIR" 2>/dev/null) || return 4
    jq -e 'type == "object" and
        (.rust_target | type == "string" and test("^[A-Za-z0-9_]+(-[A-Za-z0-9_]+)*-linux-gnu$")) and
        (.glibc_floor | type == "string" and test("^[0-9]+\\.[0-9]+$")) and
        .zig_target == (.rust_target + "." + .glibc_floor)' <<< "$selection" >/dev/null
}

# repos.d is the native build authority. Only registry-only tools are read from
# repos.yaml here; unrelated tools and non-build strings are not selectors.
config_validate_gnu_target_suffixes() {
    local toolname="${1:-}" config_file document rows row path value kind tokens word target_next explicit_zig
    [[ -n "$toolname" ]] || return 4
    config_file="${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d/$toolname.yaml"
    if [[ -f "$config_file" ]]; then
        document=$(_config_read_single_mapping_json "$config_file") || return $?
    elif [[ -f "${DSR_REPOS_FILE:-}" ]]; then
        document=$(_config_read_single_mapping_json "$DSR_REPOS_FILE") || return $?
        document=$(jq -ce --arg tool "$toolname" '
            if (.tools|type) != "object" then error("invalid registry")
            else .tools | if has($tool) then .[$tool] else {} end |
                if type=="object" then . else error("invalid tool") end end
        ' <<< "$document") || return 4
    else
        return 0
    fi
    rows=$(_config_gnu_target_selector_rows_json <<< "$document") || return 4
    rows=$(jq -c '.[]' <<< "$rows") || return 4
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        path=$(jq -r '.path' <<< "$row") || return 4
        value=$(jq -r '.value' <<< "$row") || return 4
        kind=$(jq -r '.kind' <<< "$row") || return 4
        if [[ "$kind" == identity ]]; then
            _config_reject_gnu_target_suffix "$toolname" "$path" "$value" || return 4
        elif [[ "$value" == *-linux-gnu* ]]; then
            # Capture the lexer status before checking tokens: a process
            # substitution alone would hide an unterminated quote failure.
            tokens=$(_config_literal_target_words "$value" | jq -Rs 'split("\u0000")[:-1]') || {
                _cfg_log_error "$toolname $path: malformed literal target command"; return 4;
            }
            target_next=false explicit_zig=false
            while IFS= read -r -d '' word; do
                if [[ "$target_next" == true ]]; then
                    if [[ "$word" =~ -linux-gnu[a-z0-9_]*\. ]]; then
                        explicit_zig=true
                    fi
                fi
                target_next=false
                case "$word" in
                    --target) target_next=true ;;
                    --target=*)
                        if [[ "${word#*=}" =~ -linux-gnu[a-z0-9_]*\. ]]; then
                            explicit_zig=true
                        fi ;;
                    CARGO_BUILD_TARGET=*|DSR_TARGET_TRIPLE=*)
                        _config_reject_gnu_target_suffix "$toolname" "$path" "${word#*=}" || return 4 ;;
                esac
            done < <(jq -j '.[] + "\u0000"' <<< "$tokens")
            if $explicit_zig && ! _config_validate_explicit_zigbuild_command "$value"; then
                _cfg_log_error "$toolname $path: glibc-qualified selectors require one consistent direct cargo zigbuild --target <GNU Rust triple>.<MAJOR.MINOR> selection; keep target identities plain and use linux_glibc_floor for the collected ELF ceiling"
                return 4
            fi
        fi
    done <<< "$rows"
}

# Get arch alias override for a tool/arch
# Usage: config_get_arch_alias <toolname> <arch>
# Returns: Alias (e.g., "x86_64") or empty
config_get_arch_alias() {
    local toolname="$1"
    local arch="$2"

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"

    if [[ -f "$tool_config" ]] && command -v yq &>/dev/null; then
        local value
        value=$(yq -r ".arch_aliases.\"$arch\" // \"\"" "$tool_config" 2>/dev/null)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    if [[ -f "$DSR_REPOS_FILE" ]] && command -v yq &>/dev/null; then
        local value
        value=$(yq -r ".tools.$toolname.arch_aliases.\"$arch\" // \"\"" "$DSR_REPOS_FILE" 2>/dev/null)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    echo ""
}

# List configured hosts
# Usage: config_list_hosts [--json]
config_list_hosts() {
    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    if [[ ! -f "$DSR_HOSTS_FILE" ]]; then
        _cfg_log_error "Hosts file not found: $DSR_HOSTS_FILE"
        return 4
    fi

    if command -v yq &>/dev/null; then
        local -a hosts=()
        while IFS= read -r host; do
            [[ -z "$host" || "$host" == "null" ]] && continue
            local enabled
            enabled=$(HOST="$host" yq -r '.hosts[env(HOST)].enabled' "$DSR_HOSTS_FILE" 2>/dev/null || echo null)
            [[ "$enabled" == "null" ]] && enabled=true
            [[ "$enabled" == "true" ]] && hosts+=("$host")
        done < <(yq -r '.hosts | keys | .[]' "$DSR_HOSTS_FILE")

        if $json_mode; then
            for host in "${hosts[@]}"; do
                echo "$host"
            done | jq -R -s 'split("
") | map(select(length > 0))'
        else
            for host in "${hosts[@]}"; do
                echo "$host"
            done
        fi
    else
        _cfg_log_error "yq required for host listing"
        return 3
    fi
}

# List configured tools
# Usage: config_list_tools [--json]
config_list_tools() {
    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    if [[ ! -f "$DSR_REPOS_FILE" ]]; then
        _cfg_log_error "Repos file not found: $DSR_REPOS_FILE"
        return 4
    fi

    if command -v yq &>/dev/null; then
        if $json_mode; then
            yq '.tools | keys' "$DSR_REPOS_FILE"
        else
            yq '.tools | keys | .[]' "$DSR_REPOS_FILE"
        fi
    else
        _cfg_log_error "yq required for tool listing"
        return 3
    fi
}

# Get host for a given platform
# Usage: config_get_host_for_platform <platform>
# Returns: hostname
config_get_host_for_platform() {
    local platform="$1"

    if [[ ! -f "$DSR_HOSTS_FILE" ]]; then
        _cfg_log_error "Hosts file not found"
        return 4
    fi

    if command -v yq &>/dev/null; then
        local host
        host=$(PLATFORM="$platform" yq -r '.platform_mapping[env(PLATFORM)] // ""' "$DSR_HOSTS_FILE" 2>/dev/null || echo "")
        if [[ -z "$host" || "$host" == "null" ]]; then
            echo ""
            return 0
        fi

        local enabled
        enabled=$(HOST="$host" yq -r '.hosts[env(HOST)].enabled' "$DSR_HOSTS_FILE" 2>/dev/null || echo null)
        [[ "$enabled" == "null" ]] && enabled=true
        if [[ "$enabled" == "true" ]]; then
            echo "$host"
        else
            echo ""
        fi
    else
        # Fallback to hardcoded defaults
        case "$platform" in
            linux/*) echo "trj" ;;
            darwin/*) echo "mmini" ;;
            windows/*) echo "wlap" ;;
            *) echo "" ;;
        esac
    fi
}

# Export functions for use by other scripts
export -f config_init config_load config_get config_set config_validate config_show
export -f _config_init_error _config_init_path _config_init_stat _config_init_apply
export -f _config_init_original_unchanged _config_init_candidate_unchanged
export -f _config_init_rollback _config_init_cleanup _config_init_render_default
export -f _config_persist_value _config_value_render _config_read_single_mapping_json
export -f _config_load_error _config_load_yaml _config_show_loaded
export -f _config_document_entries
export -f _cfg_log_info _cfg_log_ok _cfg_log_warn _cfg_log_error
export _CFG_RED _CFG_GREEN _CFG_YELLOW _CFG_BLUE _CFG_NC
export -f config_get_host config_get_tool config_list_hosts config_list_tools
export -f config_get_host_for_platform
export -f config_get_tool_field config_get_install_script_compat config_get_install_script_path
export -f config_get_artifact_naming config_get_target_triple config_get_arch_alias
export -f _config_target_triples_json config_get_target_triples config_get_target_triples_json config_validate_target_triples
export -f _config_gnu_target_selector_rows_json config_validate_gnu_target_suffixes
export -f _config_validate_explicit_zigbuild_command
export -f _config_literal_target_words _config_reject_gnu_target_suffix
export -f config_get_linux_libc_fallback
export -f config_get_release_contract_json config_validate_release_contract config_validate_targets
export -f config_get_release_contract_targets_json config_get_release_contract_target_key
export -f config_get_release_source_dependencies_json
