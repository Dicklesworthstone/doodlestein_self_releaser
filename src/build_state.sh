#!/usr/bin/env bash
# build_state.sh - Build workspace isolation and state management
#
# Provides:
#   - Lock acquisition/release per tool+version
#   - Build state persistence (JSON with authoritative per-target status)
#   - Workspace isolation (unique run_id directories)
#   - Resume from partial builds
#   - Stale lock detection and cleanup
#
# Usage:
#   source build_state.sh
#   build_state_init
#   build_lock_acquire "ntm" "v1.2.3"
#   build_state_create "ntm" "v1.2.3"
#   build_state_update_host "ntm" "v1.2.3" "trj" "running"
#   build_state_update_host "ntm" "v1.2.3" "trj" "completed" '{"artifact": "ntm-linux-amd64"}'
#   build_lock_release "ntm" "v1.2.3"

set -uo pipefail

# Lock settings
# shellcheck disable=SC2034 # Used by external callers
BUILD_LOCK_TTL_SECONDS="${DSR_LOCK_TTL:-3600}"  # 1 hour default
BUILD_LOCK_STALE_THRESHOLD="${DSR_LOCK_STALE:-1800}"  # 30 min stale detection

# State directory
_BUILD_STATE_DIR=""

# Compute SHA256 for a file (portable: sha256sum or shasum -a 256)
# Usage: _build_state_sha256 <file>
_build_state_sha256() {
  local file="$1"

  if command -v sha256sum &>/dev/null; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
    return $?
  fi

  if command -v shasum &>/dev/null; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
    return $?
  fi

  return 3
}

# Lock an inherited descriptor, not a pathname that will be replaced. The
# owning shell keeps the descriptor open for the entire transaction. Python's
# standard-library flock is the macOS fallback when util-linux flock is absent.
# These are local-filesystem locks; build state must not live on a filesystem
# that does not implement flock. Never unlink a lock sidecar: that would create
# a second lock domain while another process still holds the old inode.
_build_state_wait_lock() {
  local fd="$1" timeout="$2"
  if command -v flock &>/dev/null; then
    if [[ "$timeout" == 0 ]]; then
      flock -x -n "$fd"
    else
      flock -x -w "$timeout" "$fd"
    fi
  elif command -v python3 &>/dev/null; then
    python3 - "$fd" "$timeout" <<'PY'
import errno
import fcntl
import sys
import time

fd, timeout = int(sys.argv[1]), int(sys.argv[2])
deadline = time.monotonic() + timeout
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except OSError as exc:
        if exc.errno not in (errno.EACCES, errno.EAGAIN):
            raise
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            sys.exit(1)
        time.sleep(min(0.05, remaining))
PY
  else
    log_error "State updates require flock or Python 3 with fcntl"
    return 1
  fi
}

_build_state_file_identity() {
  stat -Lc '%d:%i' "$1" 2>/dev/null || stat -Lf '%d:%i' "$1" 2>/dev/null
}

# Darwin's /dev/fd entries have a synthetic device number even with stat -L.
# Inspect the inherited descriptor itself so the lock and pathname identities
# are comparable, while still detecting replacement of the locked sidecar.
_build_state_fd_identity() {
  local fd="$1"
  [[ "$fd" =~ ^[0-9]+$ ]] || return 1
  if command -v python3 &>/dev/null; then
    python3 - "$fd" <<'PY'
import os
import sys

identity = os.fstat(int(sys.argv[1]))
print(f"{identity.st_dev}:{identity.st_ino}")
PY
  elif [[ -d /proc/self/fd ]]; then
    _build_state_file_identity "/proc/self/fd/$fd"
  else
    log_error "Descriptor identity verification requires Python 3 or procfs"
    return 1
  fi
}

# Serialized read/modify/write transaction. A rename alone prevents partial
# JSON but does not prevent parallel writers from losing one another's updates.
# Lock acquisition is bounded by DSR_STATE_LOCK_TIMEOUT (seconds, default 30).
# Unique staging also prevents a failed writer from deleting another writer's
# temporary file; Bash subshells share $$, so a PID-only name is not unique.
# Returns 1 on any failure, preserving the previous checkpoint and caller traps.
_build_state_jq_update() (
  local state_file="$1"
  shift
  local lock_file="${state_file}.update.lock"
  local timeout="${DSR_STATE_LOCK_TIMEOUT:-30}"
  local workdir tmp_file before_file cleanup_command lock_identity

  if [[ ! "$timeout" =~ ^[0-9]{1,4}$ ]] || ((10#$timeout > 3600)); then
    log_error "Invalid DSR_STATE_LOCK_TIMEOUT (expected 0..3600 seconds)"
    return 1
  fi
  timeout=$((10#$timeout))
  [[ $# -gt 0 && -f "$state_file" && ! -L "$state_file" ]] || return 1
  umask 077

  # Exclusive creation is safe under concurrent first use. Opening an existing
  # sidecar must neither truncate it nor follow a symlink.
  if [[ ! -e "$lock_file" && ! -L "$lock_file" ]]; then
    (set -o noclobber; : > "$lock_file") 2>/dev/null || true
  fi
  [[ -f "$lock_file" && ! -L "$lock_file" ]] || return 1
  exec 9<> "$lock_file" || return 1
  if ! _build_state_wait_lock 9 "$timeout"; then
    log_error "Could not acquire state update lock within ${timeout}s: $state_file"
    return 1
  fi
  lock_identity=$(_build_state_fd_identity 9) || return 1
  if [[ -L "$lock_file" || ! -f "$lock_file" ||
        "$(_build_state_file_identity "$lock_file")" != "$lock_identity" ||
        -L "$state_file" || ! -f "$state_file" ]]; then
    log_error "State or lock identity changed while acquiring update lock"
    return 1
  fi

  workdir=$(mktemp -d "${state_file}.update.XXXXXXXX") || return 1
  tmp_file="$workdir/next.json"
  before_file="$workdir/before.json"
  printf -v cleanup_command 'rm -f -- %q %q; rmdir -- %q 2>/dev/null || true' \
    "$tmp_file" "$before_file" "$workdir"
  # Paths are deliberately shell-quoted and frozen before the caller changes scope.
  # shellcheck disable=SC2064
  trap "$cleanup_command" EXIT
  trap 'exit 5' INT TERM

  if ! cp -- "$state_file" "$before_file" ||
     ! jq -es 'length == 1 and (.[0] | type == "object")' \
       "$before_file" >/dev/null 2>&1; then
    log_error "State checkpoint must contain exactly one JSON object"
    return 1
  fi
  if ! jq "$@" "$before_file" > "$tmp_file" 2>/dev/null ||
     ! jq -es 'length == 1 and (.[0] | type == "object")' \
       "$tmp_file" >/dev/null 2>&1; then
    log_error "State update must produce exactly one JSON object"
    return 1
  fi
  if ! jq -ne --slurpfile before "$before_file" --slurpfile after "$tmp_file" '
      all(["tool", "version", "run_id", "created_at"][];
        . as $key | $before[0][$key] == $after[0][$key])
    ' >/dev/null 2>&1; then
    log_error "State update attempted to change immutable run identity"
    return 1
  fi

  # Detect non-cooperating writers too. Cooperating writers cannot enter until
  # this subshell closes descriptor 9; readers always see a complete document.
  if [[ -L "$state_file" || ! -f "$state_file" || -L "$lock_file" ||
        "$(_build_state_file_identity "$lock_file")" != "$lock_identity" ]] ||
     ! cmp -s "$state_file" "$before_file"; then
    log_error "State changed outside the checkpoint transaction"
    return 1
  fi
  chmod 600 "$tmp_file" || return 1
  mv -f -- "$tmp_file" "$state_file" || return 1
  return 0
)

# Initialize build state system
build_state_init() {
  local state_dir="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}"
  _BUILD_STATE_DIR="$state_dir/builds"

  # Create directories
  if ! mkdir -p "$_BUILD_STATE_DIR" "$state_dir/artifacts" "$state_dir/manifests"; then
    command -v log_error &>/dev/null && log_error "Build state directory initialization failed: $state_dir"
    return 1
  fi

  # Log initialization
  if command -v log_debug &>/dev/null; then
    log_debug "Build state initialized: $_BUILD_STATE_DIR"
  fi
}

# Get date-based build logs directory under XDG state
_build_state_log_root() {
  local state_dir="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}"
  local log_date
  log_date="$(date +%Y-%m-%d)"
  echo "$state_dir/logs/$log_date/builds"
}

# Ensure build logs directory exists and return it
_build_state_ensure_log_root() {
  local log_root
  log_root="$(_build_state_log_root)"
  mkdir -p "$log_root" 2>/dev/null || true
  echo "$log_root"
}

# Get the base directory for a tool/version combination
_build_get_tool_dir() {
  local tool="$1"
  local version="$2"
  echo "$_BUILD_STATE_DIR/${tool}/${version}"
}

# Get lock file path
_build_get_lock_file() {
  local tool="$1"
  local version="$2"
  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")
  echo "$tool_dir/.lock"
}

# Get state file path
_build_get_state_file() {
  local tool="$1"
  local version="$2"
  local run_id="${3:-}"
  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")

  if [[ -n "$run_id" ]]; then
    echo "$tool_dir/$run_id/state.json"
  else
    echo "$tool_dir/state.json"
  fi
}

# ============================================================================
# Lock Management
# ============================================================================

# Acquire lock for a tool/version
# Returns: 0 on success, 2 if already locked (conflict)
build_lock_acquire() {
  local tool="$1"
  local version="$2"
  # shellcheck disable=SC2034 # Reserved for future wait-for-lock feature
  local wait="${3:-false}"  # Whether to wait for lock

  [[ -z "$_BUILD_STATE_DIR" ]] && build_state_init

  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")
  if ! mkdir -p "$tool_dir"; then
    log_error "Failed to create tool directory: $tool_dir"
    return 1
  fi

  local lock_file
  lock_file=$(_build_get_lock_file "$tool" "$version")

  # Check for existing lock
  if [[ -f "$lock_file" ]]; then
    # Read existing lock info
    local lock_pid lock_ts lock_run_id
    if read -r lock_pid lock_ts lock_run_id < "$lock_file" 2>/dev/null; then
      # Validate numeric fields to handle corrupted lock files
      if [[ ! "$lock_pid" =~ ^[0-9]+$ ]] || [[ ! "$lock_ts" =~ ^[0-9]+$ ]]; then
        log_warn "Corrupted lock file (invalid pid/ts), removing: $lock_file"
        rm -f "$lock_file"
      else
        local now
        now=$(date +%s)
        local age=$((now - lock_ts))

        # Check if process is still alive (clear immediately if not)
        if ! kill -0 "$lock_pid" 2>/dev/null; then
          log_warn "Removing stale lock (pid=$lock_pid not running, age=${age}s)"
          rm -f "$lock_file"
        elif [[ $age -gt $BUILD_LOCK_STALE_THRESHOLD ]]; then
          # Process still alive but lock is old - respect it but warn
          log_warn "Lock held by active process $lock_pid for ${age}s"
          return 2
        else
          # Lock is recent and valid
          log_warn "Build already locked by pid=$lock_pid (run_id=$lock_run_id)"
          return 2
        fi
      fi
    fi
  fi

  # Create lock file atomically
  local my_pid=$$
  local my_ts
  my_ts=$(date +%s)
  local my_run_id="${DSR_RUN_ID:-run-$my_ts-$my_pid}"

  # Use temp file + mv for atomic creation
  local temp_lock="$lock_file.$$"
  echo "$my_pid $my_ts $my_run_id" > "$temp_lock"

  if ! mv -n "$temp_lock" "$lock_file" 2>/dev/null; then
    # Another process beat us to it
    rm -f "$temp_lock"
    log_warn "Failed to acquire lock (race condition)"
    return 2
  fi

  # Verify we own the lock
  local check_pid
  read -r check_pid _ _ < "$lock_file" 2>/dev/null || true
  if [[ "$check_pid" != "$my_pid" ]]; then
    log_warn "Lock acquired by another process"
    return 2
  fi

  log_info "Acquired build lock for $tool $version"
  return 0
}

# Release lock for a tool/version
build_lock_release() {
  local tool="$1"
  local version="$2"

  local lock_file
  lock_file=$(_build_get_lock_file "$tool" "$version")

  if [[ ! -f "$lock_file" ]]; then
    log_debug "No lock to release for $tool $version"
    return 0
  fi

  # Verify we own the lock before releasing
  local lock_pid
  read -r lock_pid _ _ < "$lock_file" 2>/dev/null || true

  if [[ "$lock_pid" == "$$" ]]; then
    rm -f "$lock_file"
    log_info "Released build lock for $tool $version"
  else
    log_warn "Cannot release lock owned by pid=$lock_pid (we are $$)"
    return 1
  fi
}

# Check if a lock exists and is valid
# Returns: 0 if locked, 1 if not locked
build_lock_check() {
  local tool="$1"
  local version="$2"

  local lock_file
  lock_file=$(_build_get_lock_file "$tool" "$version")

  if [[ ! -f "$lock_file" ]]; then
    return 1
  fi

  local lock_pid lock_ts
  if read -r lock_pid lock_ts _ < "$lock_file" 2>/dev/null; then
    local now
    now=$(date +%s)
    local age=$((now - lock_ts))

    # Check if lock is stale
    if [[ $age -gt $BUILD_LOCK_STALE_THRESHOLD ]]; then
      if ! kill -0 "$lock_pid" 2>/dev/null; then
        return 1  # Stale lock, process dead
      fi
    fi
    return 0  # Lock is valid
  fi

  return 1
}

# Get lock info as JSON
build_lock_info() {
  local tool="$1"
  local version="$2"

  local lock_file
  lock_file=$(_build_get_lock_file "$tool" "$version")

  if [[ ! -f "$lock_file" ]]; then
    echo '{"locked": false}'
    return
  fi

  local lock_pid lock_ts lock_run_id
  if read -r lock_pid lock_ts lock_run_id < "$lock_file" 2>/dev/null; then
    local now
    now=$(date +%s)
    local age=$((now - lock_ts))
    local alive=false
    kill -0 "$lock_pid" 2>/dev/null && alive=true
    local stale=false
    [[ "$age" -gt "$BUILD_LOCK_STALE_THRESHOLD" ]] && stale=true

    jq -nc \
        --argjson pid "$lock_pid" \
        --argjson timestamp "$lock_ts" \
        --argjson age_seconds "$age" \
        --arg run_id "$lock_run_id" \
        --argjson process_alive "$alive" \
        --argjson stale "$stale" \
        '{
            locked: true,
            pid: $pid,
            timestamp: $timestamp,
            age_seconds: $age_seconds,
            run_id: $run_id,
            process_alive: $process_alive,
            stale: $stale
        }'
  else
    echo '{"locked": false, "error": "invalid lock file"}'
  fi
}

# ============================================================================
# Build State Management
# ============================================================================

# Create new build state
# Returns: run_id on success
build_state_create() {
  local tool="$1"
  local version="$2"
  local targets="${3:-}"  # Comma-separated list of targets

  [[ -z "$_BUILD_STATE_DIR" ]] && build_state_init

  local run_id="${DSR_RUN_ID:-run-$(date +%s)-$$}"
  if [[ ! "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ||
        "$run_id" == "." || "$run_id" == ".." ]]; then
    log_error "Invalid build run identifier: $run_id"
    return 1
  fi
  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")
  local run_dir="$tool_dir/$run_id"

  # A run ID is an immutable namespace. Refusing a pre-existing path prevents
  # an accidental retry from replacing state or attempt receipts belonging to
  # an earlier invocation. The run itself is private even when the caller's
  # ambient umask is permissive.
  if ! mkdir -p "$tool_dir" || [[ -e "$run_dir" || -L "$run_dir" ]] ||
     ! (umask 077; mkdir "$run_dir") ||
     ! (umask 077; mkdir "$run_dir/artifacts" "$run_dir/logs" "$run_dir/results"); then
    log_error "Build run workspace already exists or could not be created: $run_dir"
    return 1
  fi
  _build_state_ensure_log_root >/dev/null

  # Initialize state
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local targets_json="[]"
  if [[ -n "$targets" ]]; then
    # Convert comma-separated to JSON array
    targets_json=$(echo "$targets" | jq -R 'split(",") | map(select(length > 0))' 2>/dev/null || echo '[]')
  fi

  if ! (
      umask 077
      set -o noclobber
      jq -nc \
          --arg tool "$tool" \
          --arg version "$version" \
          --arg run_id "$run_id" \
          --arg created_at "$now" \
          --arg updated_at "$now" \
          --argjson targets "$targets_json" \
          '{
              tool: $tool,
              version: $version,
              run_id: $run_id,
              status: "created",
              created_at: $created_at,
              updated_at: $updated_at,
              targets: $targets,
              target_statuses: (reduce $targets[] as $target ({};
                  .[$target] = {status: "pending", attempts: 0})),
              hosts: {}
          }' > "$run_dir/state.json"
  ); then
    log_error "Failed to create build state: $run_dir/state.json"
    return 1
  fi

  # Create symlink to latest
  ln -sfn "$run_id" "$tool_dir/latest"

  log_info "Created build state: $run_dir"
  echo "$run_id"
}

# Get current build state as JSON
build_state_get() {
  local tool="$1"
  local version="$2"
  local run_id="${3:-latest}"

  if [[ ! "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ||
        ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]]; then
    log_error "Invalid build state tool/version namespace"
    return 1
  fi

  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")

  # Resolve 'latest' to actual run_id
  if [[ "$run_id" == "latest" ]]; then
    if [[ -L "$tool_dir/latest" ]]; then
      run_id=$(readlink "$tool_dir/latest")
    else
      log_error "No latest build for $tool $version"
      return 1
    fi
  fi

  if [[ ! "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    log_error "Invalid build state run identifier"
    return 1
  fi
  local state_file="$tool_dir/$run_id/state.json" state
  if [[ ! -f "$state_file" || -L "$state_file" || -L "$tool_dir/$run_id" ]]; then
    log_error "Build state not found: $state_file"
    return 1
  fi
  # Read once, validate that exact snapshot, then return it. A second cat after
  # validation could return a different generation than the one just checked.
  state=$(cat -- "$state_file") || return 1
  if ! jq -es --arg tool "$tool" --arg version "$version" --arg run_id "$run_id" '
      length == 1 and (.[0] | type == "object" and
        .tool == $tool and .version == $version and .run_id == $run_id)
    ' <<< "$state" >/dev/null 2>&1; then
    log_error "Build checkpoint is malformed or belongs to a different run: $state_file"
    return 1
  fi
  printf '%s\n' "$state"
}

# Update build status
build_state_update_status() {
  local tool="$1"
  local version="$2"
  local status="$3"  # created, running, completed, failed, cancelled
  local run_id="${4:-latest}"

  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")

  if [[ "$run_id" == "latest" ]]; then
    run_id=$(readlink "$tool_dir/latest" 2>/dev/null || true)
    [[ -z "$run_id" ]] && return 1
  fi

  local state_file="$tool_dir/$run_id/state.json"
  [[ ! -f "$state_file" ]] && return 1

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Use safe jq update helper (validates non-empty and valid JSON)
  _build_state_jq_update "$state_file" \
    --arg status "$status" --arg now "$now" \
    '.status = $status | .updated_at = $now' || return 1

  log_debug "Build status updated: $tool $version -> $status"
}

# Update host status within build state
build_state_update_host() {
  local tool="$1"
  local version="$2"
  local host="$3"
  local host_status="$4"  # pending, running, completed, failed, skipped
  local extra_json="${5:-}"  # Additional JSON to merge (default empty)
  local run_id="${6:-latest}"

  # An omitted payload is empty; malformed evidence must never become success.
  : "${extra_json:="{}"}"

  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")

  if [[ "$run_id" == "latest" ]]; then
    run_id=$(readlink "$tool_dir/latest" 2>/dev/null || true)
    [[ -z "$run_id" ]] && return 1
  fi

  local state_file="$tool_dir/$run_id/state.json"
  [[ ! -f "$state_file" ]] && return 1

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if ! jq -es 'length == 1 and (.[0] | type == "object")' <<< "$extra_json" &>/dev/null; then
    log_error "Invalid host state evidence for $host"
    return 1
  fi

  # Update host status using safe helper. Propagate failure so callers
  # don't see "log_debug" succeeding while the underlying jq update
  # silently dropped the change — the previous code returned 0 even
  # when _build_state_jq_update returned 1, which left the state file
  # stale while the orchestrator believed it had recorded the host
  # transition.
  if ! _build_state_jq_update "$state_file" \
      --arg host "$host" --arg status "$host_status" --arg now "$now" \
      --argjson extra "$extra_json" \
      '.hosts[$host] = ((.hosts[$host] // {}) + $extra + {status: $status, updated_at: $now}) | .updated_at = $now'; then
    return 1
  fi

  log_debug "Host status updated: $host -> $host_status"
}

# Update authoritative target status within build state.
# Args: tool version target status [extra_json] [run_id]
#
# Host status is retained for compatibility and fleet telemetry, but it cannot
# represent two targets assigned to the same host. Scheduling and resume logic
# therefore use this target-keyed map exclusively.
build_state_update_target() {
  local tool="$1"
  local version="$2"
  local target="$3"
  local target_status="$4"  # pending, running, completed, failed, cancelled
  local extra_json="${5:-}"
  [[ -n "$extra_json" ]] || extra_json='{}'
  local run_id="${6:-latest}"

  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")

  if [[ "$run_id" == "latest" ]]; then
    run_id=$(readlink "$tool_dir/latest" 2>/dev/null || true)
    [[ -z "$run_id" ]] && return 1
  fi

  local state_file="$tool_dir/$run_id/state.json"
  [[ ! -f "$state_file" ]] && return 1

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if ! jq -es 'length == 1 and (.[0] | type == "object")' <<< "$extra_json" &>/dev/null; then
    log_error "Invalid target state evidence for $target"
    return 1
  fi

  if ! _build_state_jq_update "$state_file" \
      --arg target "$target" --arg status "$target_status" --arg now "$now" \
      --argjson extra "$extra_json" '
        .target_statuses = (.target_statuses // {}) |
        .target_statuses[$target] =
          ((.target_statuses[$target] // {attempts: 0}) + $extra +
           {status: $status, updated_at: $now}) |
        .updated_at = $now'; then
    return 1
  fi

  log_debug "Target status updated: $target -> $target_status"
}

# Bind a run to the inputs required for an honest resume.
# Args: tool version run_id git_sha git_ref source_roots_json output_dir parallel_jobs target_hosts_json
build_state_set_context() {
  local tool="$1"
  local version="$2"
  local run_id="$3"
  local git_sha="$4"
  local git_ref="$5"
  local source_roots_json="${6:-}"
  [[ -n "$source_roots_json" ]] || source_roots_json='{}'
  local output_dir="${7:-}"
  local parallel_jobs="${8:-1}"
  local target_hosts_json="${9:-}"
  [[ -n "$target_hosts_json" ]] || target_hosts_json='{}'
  local build_purpose="${10:-release}"
  [[ "$build_purpose" == "release" || "$build_purpose" == "diagnostic-native" ]] || return 1

  local tool_dir state_file now
  tool_dir=$(_build_get_tool_dir "$tool" "$version")
  state_file="$tool_dir/$run_id/state.json"
  [[ -f "$state_file" ]] || return 1
  jq -e 'type == "object"' <<< "$source_roots_json" &>/dev/null || return 1
  jq -e 'type == "object"' <<< "$target_hosts_json" &>/dev/null || return 1
  [[ "$parallel_jobs" =~ ^[1-9][0-9]*$ ]] || return 1
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _build_state_jq_update "$state_file" \
    --arg sha "$git_sha" --arg ref "$git_ref" \
    --argjson source_roots "$source_roots_json" \
    --argjson target_hosts "$target_hosts_json" \
    --arg build_purpose "$build_purpose" \
    --arg output_dir "$output_dir" --argjson parallel_jobs "$parallel_jobs" \
    --arg now "$now" '
      .git_sha = $sha |
      .git_ref = $ref |
      .context = {
        build_purpose: $build_purpose,
        publishable: ($build_purpose == "release"),
        source_roots: $source_roots,
        target_hosts: $target_hosts,
        output_dir: $output_dir,
        parallel_jobs: $parallel_jobs
      } |
      .updated_at = $now'
}

# Atomically replace only a failed target's host binding, preserving its attempt
# history and every completed target. Caller holds the orchestration lock.
build_state_relocate_failed_target() {
  local tool="$1" version="$2" run_id="$3" before="$4" target="$5"
  local host="$6" roots="$7" receipt="$8" tool_dir state_file
  tool_dir=$(_build_get_tool_dir "$tool" "$version")
  state_file="$tool_dir/$run_id/state.json"
  _build_state_jq_update "$state_file" \
    --argjson before "$before" --arg target "$target" --arg host "$host" \
    --argjson roots "$roots" --argjson receipt "$receipt" '
      if . != $before or .target_statuses[$target].status != "failed" or
         (.status == "completed" or .status == "cancelled")
      then error("relocation state changed or target is not failed")
      else
        .relocations = ((.relocations // []) + [$receipt]) |
        .context.target_hosts[$target] = $host |
        .context.source_roots = $roots
      end'
}

# Add artifact to build state
build_state_add_artifact() {
  local tool="$1"
  local version="$2"
  local artifact_name="$3"
  local artifact_path="$4"
  local sha256="${5:-}"
  local run_id="${6:-latest}"

  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")

  if [[ "$run_id" == "latest" ]]; then
    run_id=$(readlink "$tool_dir/latest" 2>/dev/null || true)
    [[ -z "$run_id" ]] && return 1
  fi

  local state_file="$tool_dir/$run_id/state.json"
  [[ ! -f "$state_file" ]] && return 1

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Calculate sha256 if not provided
  if [[ -z "$sha256" && -f "$artifact_path" ]]; then
    sha256=$(_build_state_sha256 "$artifact_path" 2>/dev/null || echo "")
  fi

  local size=0
  if [[ -f "$artifact_path" ]]; then
    size=$(stat -c%s "$artifact_path" 2>/dev/null || stat -f%z "$artifact_path" 2>/dev/null || echo 0)
  fi

  # Add artifact to state using safe helper. Propagate failure (see the
  # comment in build_state_update_host) — silently swallowing a jq
  # failure here means the manifest the orchestrator hands to the
  # release step would be missing entries.
  if ! _build_state_jq_update "$state_file" \
      --arg name "$artifact_name" --arg path "$artifact_path" \
      --arg sha256 "$sha256" --argjson size "$size" --arg now "$now" \
      '.artifacts = (.artifacts // []) + [{name: $name, path: $path, sha256: $sha256, size_bytes: $size, added_at: $now}] | .updated_at = $now'; then
    return 1
  fi

  log_debug "Artifact added: $artifact_name"
}

# Set git info for a build (for reproducibility tracking)
# Args: tool version git_sha git_ref [run_id]
build_state_set_git_info() {
  local tool="$1"
  local version="$2"
  local git_sha="$3"
  local git_ref="$4"
  local run_id="${5:-latest}"

  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")

  if [[ "$run_id" == "latest" ]]; then
    run_id=$(readlink "$tool_dir/latest" 2>/dev/null || true)
    [[ -z "$run_id" ]] && return 1
  fi

  local state_file="$tool_dir/$run_id/state.json"
  [[ ! -f "$state_file" ]] && return 1

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Update git info using safe helper. Propagate failure so a corrupt
  # state file doesn't silently get re-read with the wrong SHA later
  # (build_state_get_git_sha would return the prior value as if this
  # update had succeeded).
  if ! _build_state_jq_update "$state_file" \
      --arg sha "$git_sha" --arg ref "$git_ref" --arg now "$now" \
      '.git_sha = $sha | .git_ref = $ref | .updated_at = $now'; then
    return 1
  fi

  log_debug "Git info set: $git_ref ($git_sha)"
}

# Get git SHA from build state
# Args: tool version [run_id]
# Returns: SHA on stdout, or empty
build_state_get_git_sha() {
  local tool="$1"
  local version="$2"
  local run_id="${3:-latest}"

  local state
  state=$(build_state_get "$tool" "$version" "$run_id" 2>/dev/null) || return 1
  echo "$state" | jq -r '.git_sha // empty'
}

# Get git ref from build state
# Args: tool version [run_id]
# Returns: ref on stdout, or empty
build_state_get_git_ref() {
  local tool="$1"
  local version="$2"
  local run_id="${3:-latest}"

  local state
  state=$(build_state_get "$tool" "$version" "$run_id" 2>/dev/null) || return 1
  echo "$state" | jq -r '.git_ref // empty'
}

# ============================================================================
# Resume Support
# ============================================================================

# Check if a build can be resumed
# Returns: 0 if resumable, 1 if not
build_state_can_resume() {
  local tool="$1"
  local version="$2"
  local run_id="${3:-latest}"

  local state
  state=$(build_state_get "$tool" "$version" "$run_id" 2>/dev/null) || return 1

  local status
  status=$(echo "$state" | jq -r '.status')

  case "$status" in
    created|running|failed)
      return 0  # Can resume
      ;;
    completed|cancelled)
      return 1  # Cannot resume
      ;;
    *)
      return 1  # Unknown/missing status is not a resumable checkpoint
      ;;
  esac
}

# Get list of completed hosts for a build
build_state_completed_hosts() {
  local tool="$1"
  local version="$2"
  local run_id="${3:-latest}"

  local state
  state=$(build_state_get "$tool" "$version" "$run_id" 2>/dev/null) || return 1

  echo "$state" | jq -r '.hosts | to_entries | map(select(.value.status == "completed")) | .[].key'
}

# Get list of failed hosts for a build
build_state_failed_hosts() {
  local tool="$1"
  local version="$2"
  local run_id="${3:-latest}"

  local state
  state=$(build_state_get "$tool" "$version" "$run_id" 2>/dev/null) || return 1

  echo "$state" | jq -r '.hosts | to_entries | map(select(.value.status == "failed")) | .[].key'
}

# Get list of pending hosts for a build
build_state_pending_hosts() {
  local tool="$1"
  local version="$2"
  local run_id="${3:-latest}"

  local state
  state=$(build_state_get "$tool" "$version" "$run_id" 2>/dev/null) || return 1

  # Target platforms are not host names. Use explicit host routing where
  # available, while still reading older host-named target inventories.
  jq -r '
    . as $s |
    (((.hosts // {}) | keys) + [(.context.target_hosts // {})[]] +
      [.targets[]? | select(contains("/") | not)] | unique)[] as $host |
    ($s.hosts[$host].status // "pending") as $status |
    select($status == "pending" or $status == "running") | $host
  ' <<< "$state"
}

# Target-keyed status queries used by the orchestrator and resume planner.
build_state_completed_targets() {
  local state
  state=$(build_state_get "$1" "$2" "${3:-latest}" 2>/dev/null) || return 1
  jq -r '
    .target_statuses // {} | to_entries[] |
    select(.value.status == "completed" and (.value.result | type) == "object" and
      (.value.result | length) > 0) |
    .key
  ' <<< "$state"
}

build_state_failed_targets() {
  local state
  state=$(build_state_get "$1" "$2" "${3:-latest}" 2>/dev/null) || return 1
  jq -r '.target_statuses // {} | to_entries[] | select(.value.status == "failed") | .key' <<< "$state"
}

build_state_pending_targets() {
  local state
  state=$(build_state_get "$1" "$2" "${3:-latest}" 2>/dev/null) || return 1
  jq -r '
    . as $state |
    $state.targets[]? as $target |
    ($state.target_statuses[$target] // {status: "pending"}) as $entry |
    select($entry.status != "completed" or ($entry.result | type) != "object" or
      ($entry.result | length) == 0) |
    $target
  ' <<< "$state"
}

# ============================================================================
# Workspace Helpers
# ============================================================================

# Get workspace directory for a build
build_state_workspace() {
  local tool="$1"
  local version="$2"
  local run_id="${3:-latest}"

  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")

  if [[ "$run_id" == "latest" ]]; then
    run_id=$(readlink "$tool_dir/latest" 2>/dev/null || true)
    [[ -z "$run_id" ]] && return 1
  fi

  echo "$tool_dir/$run_id"
}

# Get artifacts directory for a build
build_state_artifacts_dir() {
  local workspace
  workspace=$(build_state_workspace "$@") || return 1
  echo "$workspace/artifacts"
}

# Get logs directory for a build
build_state_logs_dir() {
  _build_state_ensure_log_root
}

# Get per-run workspace logs directory (legacy)
build_state_workspace_logs_dir() {
  local workspace
  workspace=$(build_state_workspace "$@") || return 1
  echo "$workspace/logs"
}

# List all builds for a tool
build_state_list() {
  local tool="$1"
  local version="${2:-}"

  [[ -z "$_BUILD_STATE_DIR" ]] && build_state_init

  if [[ -n "$version" ]]; then
    local tool_dir
    tool_dir=$(_build_get_tool_dir "$tool" "$version")
    if [[ -d "$tool_dir" ]]; then
      # Use portable find + basename (avoid GNU-only -printf)
      find "$tool_dir" -maxdepth 1 -name 'run-*' -type d 2>/dev/null | while read -r dir; do
        basename "$dir"
      done | sort -r
    fi
  else
    # List all versions
    local tool_base="$_BUILD_STATE_DIR/$tool"
    if [[ -d "$tool_base" ]]; then
      find "$tool_base" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while read -r dir; do
        basename "$dir"
      done | sort -rV
    fi
  fi
}

# Clean up old builds (retention policy)
build_state_cleanup() {
  local tool="$1"
  local version="$2"
  local keep="${3:-5}"  # Number of recent builds to keep

  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")

  if [[ ! -d "$tool_dir" ]]; then
    return 0
  fi

  # Get all builds sorted by time (newest first)
  # Use portable stat instead of GNU find -printf
  local builds
  builds=$(find "$tool_dir" -maxdepth 1 -name 'run-*' -type d 2>/dev/null | while read -r dir; do
    # Get modification time as epoch and basename
    local mtime name
    mtime=$(stat -c%Y "$dir" 2>/dev/null || stat -f%m "$dir" 2>/dev/null || echo 0)
    name=$(basename "$dir")
    echo "$mtime $name"
  done | sort -rn | cut -d' ' -f2)

  local count=0
  for build in $builds; do
    ((count++))
    if [[ $count -gt $keep ]]; then
      log_info "Cleaning up old build: $build"
      rm -rf "${tool_dir:?}/${build:?}"
    fi
  done
}

# ============================================================================
# Retry and Recovery Logic
# ============================================================================

# Retry configuration
BUILD_RETRY_MAX="${DSR_RETRY_MAX:-3}"
BUILD_RETRY_BASE_DELAY="${DSR_RETRY_DELAY:-5}"  # Base delay in seconds
BUILD_RETRY_MAX_DELAY="${DSR_RETRY_MAX_DELAY:-300}"  # Max delay (5 min)

_build_retry_config_valid() {
  if [[ ! "$BUILD_RETRY_MAX" =~ ^[0-9]{1,4}$ ||
        ! "$BUILD_RETRY_BASE_DELAY" =~ ^[0-9]{1,5}$ ||
        ! "$BUILD_RETRY_MAX_DELAY" =~ ^[0-9]{1,5}$ ]] ||
     ((10#$BUILD_RETRY_MAX < 1 || 10#$BUILD_RETRY_MAX > 1000 ||
       10#$BUILD_RETRY_BASE_DELAY > 86400 || 10#$BUILD_RETRY_MAX_DELAY > 86400)); then
    log_error "Invalid retry configuration (1..1000 attempts, delays 0..86400 seconds)"
    return 4
  fi
}

# Calculate exponential backoff with jitter
# Args: attempt_number
# Returns: delay in seconds
_build_calc_backoff() {
  local attempt="$1"
  _build_retry_config_valid || return 4
  [[ "$attempt" =~ ^[0-9]{1,4}$ ]] && ((10#$attempt <= 1000)) || return 4
  attempt=$((10#$attempt))
  local delay=$((10#$BUILD_RETRY_BASE_DELAY)) cap=$((10#$BUILD_RETRY_MAX_DELAY)) i=0
  ((delay > cap)) && delay=$cap
  # Saturate before multiplication; a large attempt must not wrap a bit shift
  # into a negative delay or a fresh, unexpectedly short retry interval.
  while ((i < attempt && delay > 0 && delay < cap)); do
    if ((delay > cap / 2)); then delay=$cap; else delay=$((delay * 2)); fi
    i=$((i + 1))
  done
  local jitter=$((RANDOM % (delay / 4 + 1)))
  delay=$((delay + jitter))
  ((delay > cap)) && delay=$cap
  echo "$delay"
}

# Execute a command with exponential backoff retry
# Args: max_retries command [args...]
# Returns: Exit code of last attempt
build_retry_with_backoff() {
  [[ $# -ge 2 ]] || return 4
  local max_retries="${1:-$BUILD_RETRY_MAX}"
  shift
  _build_retry_config_valid || return 4
  [[ "$max_retries" =~ ^[0-9]{1,4}$ && -n "$1" ]] &&
    ((10#$max_retries >= 1 && 10#$max_retries <= 1000)) || return 4
  max_retries=$((10#$max_retries))

  local attempt=0
  local exit_code=0

  while [[ $attempt -lt $max_retries ]]; do
    # Run command and capture exit code using || (if uses $? incorrectly)
    exit_code=0
    "$@" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      return 0
    fi

    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_retries ]]; then
      log_error "Command failed after $max_retries attempts: $*"
      return $exit_code
    fi

    local delay
    delay=$(_build_calc_backoff "$attempt") || return 4
    log_warn "Attempt $attempt failed (exit $exit_code), retrying in ${delay}s..."
    sleep "$delay" || return 5
  done

  return $exit_code
}

# Record a retry attempt for a host in build state
# Args: tool version host attempt error_message [run_id]
build_state_record_retry() {
  local tool="$1"
  local version="$2"
  local host="$3"
  local attempt="$4"
  local error_msg="$5"
  local run_id="${6:-latest}"
  [[ "$attempt" =~ ^[1-9][0-9]{0,3}$ ]] && ((attempt <= 1000)) || return 4

  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")

  if [[ "$run_id" == "latest" ]]; then
    run_id=$(readlink "$tool_dir/latest" 2>/dev/null || true)
    [[ -z "$run_id" ]] && return 1
  fi

  local state_file="$tool_dir/$run_id/state.json"
  [[ ! -f "$state_file" ]] && return 1

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Update host with retry info using safe helper
  _build_state_jq_update "$state_file" \
    --arg host "$host" --argjson attempt "$attempt" \
    --arg error "$error_msg" --arg now "$now" \
    '.hosts[$host].retry_count = $attempt |
     .hosts[$host].last_error = $error |
     .hosts[$host].last_retry_at = $now |
     .hosts[$host].retries = ((.hosts[$host].retries // []) + [{attempt: $attempt, error: $error, at: $now}]) |
     .updated_at = $now' || return 1

  log_debug "Recorded retry $attempt for $host: $error_msg"
}

# Get retry count for a host
# Args: tool version host [run_id]
# Returns: retry count (0 if none)
build_state_get_retry_count() {
  local tool="$1"
  local version="$2"
  local host="$3"
  local run_id="${4:-latest}"

  local state
  state=$(build_state_get "$tool" "$version" "$run_id" 2>/dev/null) || return 1

  jq -er --arg host "$host" '
    if (.hosts | type) != "object" then error("invalid host inventory") else
      if .hosts | has($host) then .hosts[$host] else {} end
    end |
    if type != "object" then error("invalid host retry evidence") else . end |
    (if has("retry_count") then .retry_count else 0 end) |
    if type == "number" and floor == . and . >= 0 and . <= 9007199254740991
    then . else error("invalid saved retry count") end
  ' <<< "$state"
}

# Reset retry count for a host (on success)
# Args: tool version host [run_id]
build_state_reset_retries() {
  local tool="$1"
  local version="$2"
  local host="$3"
  local run_id="${4:-latest}"

  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")

  if [[ "$run_id" == "latest" ]]; then
    run_id=$(readlink "$tool_dir/latest" 2>/dev/null || true)
    [[ -z "$run_id" ]] && return 1
  fi

  local state_file="$tool_dir/$run_id/state.json"
  [[ ! -f "$state_file" ]] && return 1

  # Reset retry state using safe helper
  _build_state_jq_update "$state_file" \
    --arg host "$host" \
    '.hosts[$host].retry_count = 0 | .hosts[$host].last_error = null'
}

# Check if host has exceeded retry limit
# Args: tool version host [run_id]
# Returns: 0 if can retry, 1 if exceeded
build_state_can_retry() {
  local tool="$1"
  local version="$2"
  local host="$3"
  local run_id="${4:-latest}"
  _build_retry_config_valid || return 1

  local count
  count=$(build_state_get_retry_count "$tool" "$version" "$host" "$run_id") || return 1

  if ((count >= 10#$BUILD_RETRY_MAX)); then
    return 1  # Exceeded
  fi
  return 0  # Can retry
}

# Resume a failed or interrupted build
# Args: tool version [run_id]
# Returns: JSON with resume plan from ONE validated checkpoint generation.
# Completed-target entries remain candidates for the orchestrator's separate
# source/artifact verification; an empty result is never completion evidence.
build_state_resume() {
  local tool="$1"
  local version="$2"
  local run_id="${3:-latest}"

  local state
  state=$(build_state_get "$tool" "$version" "$run_id" 2>/dev/null) || {
    echo '{"error": "Build state missing or invalid", "can_resume": false}'
    return 1
  }

  if ! _build_retry_config_valid; then
    echo '{"error": "Invalid retry configuration", "can_resume": false}'
    return 1
  fi

  local plan
  if ! plan=$(jq -ce --argjson retry_max "$((10#$BUILD_RETRY_MAX))" '
    def counter($key): if has($key) then .[$key] else 0 end;
    def valid_counter($key):
      counter($key) | type == "number" and floor == . and . >= 0 and . <= 9007199254740991;
    def entry_status: if has("status") then .status else "pending" end;
    def valid_status:
      entry_status as $status |
      ["pending", "running", "completed", "failed", "cancelled", "skipped"] | index($status) != null;
    . as $s |
    if (.status != "created" and .status != "running" and .status != "failed") or
       (.targets | type) != "array" or
       (all(.targets[]; type == "string" and length > 0) | not) or
       (.targets | unique | length) != (.targets | length) or
       (.hosts | type) != "object" or
       (all(.hosts[]; type == "object" and valid_status and valid_counter("retry_count")) | not) or
       (.target_statuses != null and (.target_statuses | type) != "object") or
       (all((.target_statuses // {})[];
         type == "object" and valid_status and valid_counter("attempts")) | not) or
       (all((.target_statuses // {}) | keys[]; . as $t | $s.targets | index($t) != null) | not) or
       (.context != null and (.context | type) != "object") or
       (.context.target_hosts != null and (.context.target_hosts | type) != "object") or
       (all((.context.target_hosts // {})[]; type == "string" and length > 0) | not)
    then error("invalid or non-resumable checkpoint") else . end |
    # No further build_state_get/readlink calls: latest may now name a new run.
    (((.hosts | keys) + [(.context.target_hosts // {})[]] +
      [.targets[] | select(contains("/") | not)]) | unique |
      map(. as $host | {name: $host, entry: ($s.hosts[$host] // {})})) as $hosts |
    [$hosts[] | select(.entry.status == "completed") | .name] as $completed |
    [$hosts[] | select(.entry.status == "failed") | .name] as $failed |
    [$hosts[] | select((.entry | entry_status) == "pending" or .entry.status == "running") |
      select((.entry | counter("retry_count")) < $retry_max) | .name] as $pending |
    [$hosts[] | select(.entry.status == "failed" and
      (.entry | counter("retry_count")) < $retry_max) | .name] as $retryable |
    [$hosts[] | select((.entry | entry_status) == "pending" or
      .entry.status == "running" or .entry.status == "failed") |
      select((.entry | counter("retry_count")) >= $retry_max) | .name] as $exceeded |
    (reduce .targets[] as $target (
      {completed: [], retryable: [], exceeded: []};
      ($s.target_statuses[$target] // {}) as $entry |
      if ($entry.status == "completed" and ($entry.result | type) == "object" and
          ($entry.result | length) > 0) then .completed += [$target]
      elif (($entry | counter("attempts")) >= $retry_max) then .exceeded += [$target]
      else .retryable += [$target] end
    )) as $target_plan |
    {
      can_resume: true,
      tool: $s.tool,
      version: $s.version,
      run_id: $s.run_id,
      current_status: $s.status,
      completed_hosts: $completed,
      failed_hosts: $failed,
      pending_hosts: $pending,
      retryable_hosts: $retryable,
      exceeded_retry_limit: $exceeded,
      hosts_to_process: (($pending + $retryable) | unique),
      completed_targets: $target_plan.completed,
      targets_to_process: $target_plan.retryable,
      exceeded_target_retry_limit: $target_plan.exceeded,
      context: ($s.context // {})
    }
  ' <<< "$state" 2>/dev/null); then
    log_error "Cannot resume an invalid, completed, or cancelled checkpoint"
    echo '{"error": "Checkpoint is invalid or not resumable", "can_resume": false}'
    return 1
  fi
  printf '%s\n' "$plan"
}

# Execute a build step for a host with automatic retry
# Args: tool version host command [args...]
# Returns: 0 on recorded success, 1 on failure, 2 on concurrent execution,
# 4 on invalid retry configuration, 5 on interruption. Pin the run once and
# reserve each attempt before invoking the command, so a crash consumes budget.
# A per-host kernel lock allows different hosts to run concurrently.
build_state_exec_with_retry() (
  [[ $# -ge 4 ]] || return 4
  local tool="$1"
  local version="$2"
  local host="$3"
  shift 3
  [[ -n "$host" && -n "$1" ]] || return 4
  _build_retry_config_valid || return 4

  local state run_id workspace state_file key lock_file lock_identity
  state=$(build_state_get "$tool" "$version") || return 1
  run_id=$(jq -er '.run_id' <<< "$state") || return 1
  workspace=$(build_state_workspace "$tool" "$version" "$run_id") || return 1
  state_file="$workspace/state.json"
  key=$(_build_state_sha256 /dev/stdin <<< "$host") || return 3
  [[ "$key" =~ ^[0-9a-f]{64}$ ]] || return 1
  lock_file="$workspace/host-$key.retry.lock"
  if [[ ! -e "$lock_file" && ! -L "$lock_file" ]]; then
    (umask 077; set -o noclobber; : > "$lock_file") 2>/dev/null || true
  fi
  [[ -f "$lock_file" && ! -L "$lock_file" ]] || return 1
  exec 8<> "$lock_file" || return 1
  _build_state_wait_lock 8 0 || return 2
  lock_identity=$(_build_state_fd_identity 8) || return 1
  [[ ! -L "$lock_file" && "$(_build_state_file_identity "$lock_file")" == "$lock_identity" ]] || return 1
  trap 'exit 5' INT TERM

  local attempt next_attempt now delay exit_code outcome
  local max_attempts=$((10#$BUILD_RETRY_MAX))
  attempt=$(build_state_get_retry_count "$tool" "$version" "$host" "$run_id") || return 1

  while ((attempt < max_attempts)); do
    next_attempt=$((attempt + 1))
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    if ! _build_state_jq_update "$state_file" \
        --arg host "$host" --arg now "$now" --argjson before "$attempt" \
        --argjson attempt "$next_attempt" '
        (.hosts[$host] // {}) as $h |
        if (.status != "created" and .status != "running" and .status != "failed") or
           (if $h | has("retry_count") then $h.retry_count else 0 end) != $before
        then error("run or retry budget changed") else
          .hosts[$host] = ($h + {status: "running", retry_count: $attempt,
            active_attempt: $attempt, attempts_started: (($h.attempts_started // 0) + 1),
            updated_at: $now}) | .updated_at = $now
        end'; then
      return 1
    fi
    attempt=$next_attempt

    if "$@"; then
      exit_code=0
      outcome=completed
    else
      exit_code=$?
      outcome=failed
      case "$exit_code" in 5|130|143) outcome=cancelled ;; esac
    fi
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # Status, count, and the actual exit code are one transaction. Never claim
    # success or launch another attempt if the completion receipt was not saved.
    if ! _build_state_jq_update "$state_file" \
        --arg host "$host" --arg now "$now" --arg status "$outcome" \
        --argjson attempt "$attempt" --argjson code "$exit_code" '
        if (.status != "created" and .status != "running" and .status != "failed") or
           .hosts[$host].retry_count != $attempt or .hosts[$host].status != "running"
        then error("attempt ownership changed") else
          .hosts[$host] |= (. + {status: $status, exit_code: $code,
            active_attempt: null, updated_at: $now} |
            if $code == 0 then .retry_count = 0 | .last_error = null else
              .last_error = "exit code \($code)" | .last_retry_at = $now |
              .retries = ((.retries // []) +
                [{attempt: $attempt, error: .last_error, exit_code: $code, at: $now}])
            end) | .updated_at = $now
        end'; then
      return 1
    fi
    [[ "$outcome" == completed ]] && return 0
    [[ "$outcome" == cancelled ]] && return 5
    ((attempt >= max_attempts)) && break
    delay=$(_build_calc_backoff "$attempt") || return 4
    log_warn "Host $host attempt $attempt failed, retrying in ${delay}s..."
    sleep "$delay" || return 5
  done

  log_error "Host $host exhausted its $max_attempts attempt budget for run $run_id"
  return 1
)

# Export functions
export -f build_state_init build_lock_acquire build_lock_release build_lock_check build_lock_info
export -f build_state_create build_state_get build_state_update_status build_state_update_host
export -f build_state_update_target build_state_set_context
export -f build_state_add_artifact build_state_can_resume
export -f build_state_set_git_info build_state_get_git_sha build_state_get_git_ref
export -f build_state_completed_hosts build_state_failed_hosts build_state_pending_hosts
export -f build_state_workspace build_state_artifacts_dir build_state_logs_dir
export -f build_state_workspace_logs_dir
export -f build_state_list build_state_cleanup
export -f build_retry_with_backoff build_state_record_retry build_state_get_retry_count
export -f build_state_reset_retries build_state_can_retry build_state_resume
export -f build_state_completed_targets build_state_failed_targets build_state_pending_targets
export -f build_state_exec_with_retry
