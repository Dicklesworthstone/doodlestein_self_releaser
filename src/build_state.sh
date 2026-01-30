#!/usr/bin/env bash
# build_state.sh - Build workspace isolation and state management
#
# Provides:
#   - Lock acquisition/release per tool+version
#   - Build state persistence (JSON with per-host status)
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

# Initialize build state system
build_state_init() {
  local state_dir="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}"
  _BUILD_STATE_DIR="$state_dir/builds"

  # Create directories
  mkdir -p "$_BUILD_STATE_DIR" "$state_dir/artifacts" "$state_dir/manifests"

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
  mkdir -p "$tool_dir"

  local lock_file
  lock_file=$(_build_get_lock_file "$tool" "$version")

  # Check for existing lock
  if [[ -f "$lock_file" ]]; then
    # Read existing lock info
    local lock_pid lock_ts lock_run_id
    if read -r lock_pid lock_ts lock_run_id < "$lock_file" 2>/dev/null; then
      local now
      now=$(date +%s)
      local age=$((now - lock_ts))

      # Check if lock is stale
      if [[ $age -gt $BUILD_LOCK_STALE_THRESHOLD ]]; then
        # Check if process is still alive
        if ! kill -0 "$lock_pid" 2>/dev/null; then
          log_warn "Removing stale lock (pid=$lock_pid, age=${age}s)"
          rm -f "$lock_file"
        else
          # Process still alive but lock is old - respect it but warn
          log_warn "Lock held by active process $lock_pid for ${age}s"
          return 2
        fi
      else
        # Lock is recent and valid
        log_warn "Build already locked by pid=$lock_pid (run_id=$lock_run_id)"
        return 2
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

    cat << EOF
{
  "locked": true,
  "pid": $lock_pid,
  "timestamp": $lock_ts,
  "age_seconds": $age,
  "run_id": "$lock_run_id",
  "process_alive": $alive,
  "stale": $(( age > BUILD_LOCK_STALE_THRESHOLD ? 1 : 0 ))
}
EOF
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
  local tool_dir
  tool_dir=$(_build_get_tool_dir "$tool" "$version")
  local run_dir="$tool_dir/$run_id"

  # Create workspace directory
  mkdir -p "$run_dir/artifacts" "$run_dir/logs"
  _build_state_ensure_log_root >/dev/null

  # Initialize state
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local targets_json="[]"
  if [[ -n "$targets" ]]; then
    # Convert comma-separated to JSON array
    targets_json=$(echo "$targets" | jq -R 'split(",")' 2>/dev/null || echo '[]')
  fi

  cat > "$run_dir/state.json" << EOF
{
  "tool": "$tool",
  "version": "$version",
  "run_id": "$run_id",
  "status": "created",
  "created_at": "$now",
  "updated_at": "$now",
  "targets": $targets_json,
  "hosts": {}
}
EOF

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

  local state_file="$tool_dir/$run_id/state.json"

  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    log_error "Build state not found: $state_file"
    return 1
  fi
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

  # Update status and timestamp
  local tmp_file="$state_file.tmp"
  jq --arg status "$status" --arg now "$now" \
    '.status = $status | .updated_at = $now' "$state_file" > "$tmp_file" \
    && mv "$tmp_file" "$state_file"

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

  # Default to empty JSON object if not provided or invalid
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

  # Ensure extra_json is valid JSON (default to empty object)
  # Use simple string check to avoid regex issues across shell versions
  if [[ -z "$extra_json" ]]; then
    extra_json='{}'
  elif [[ "${extra_json:0:1}" != "{" ]]; then
    extra_json='{}'
  fi

  # Update host status
  local tmp_file="$state_file.tmp"
  jq --arg host "$host" --arg status "$host_status" --arg now "$now" \
    --argjson extra "$extra_json" \
    '.hosts[$host] = ((.hosts[$host] // {}) + $extra + {status: $status, updated_at: $now}) | .updated_at = $now' \
    "$state_file" > "$tmp_file" \
    && mv "$tmp_file" "$state_file"

  log_debug "Host status updated: $host -> $host_status"
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
    sha256=$(sha256sum "$artifact_path" 2>/dev/null | cut -d' ' -f1 || echo "")
  fi

  local size=0
  if [[ -f "$artifact_path" ]]; then
    size=$(stat -c%s "$artifact_path" 2>/dev/null || stat -f%z "$artifact_path" 2>/dev/null || echo 0)
  fi

  # Add artifact to state
  local tmp_file="$state_file.tmp"
  jq --arg name "$artifact_name" --arg path "$artifact_path" \
    --arg sha256 "$sha256" --argjson size "$size" --arg now "$now" \
    '.artifacts = (.artifacts // []) + [{name: $name, path: $path, sha256: $sha256, size_bytes: $size, added_at: $now}] | .updated_at = $now' \
    "$state_file" > "$tmp_file" \
    && mv "$tmp_file" "$state_file"

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

  # Update git info
  local tmp_file="$state_file.tmp"
  jq --arg sha "$git_sha" --arg ref "$git_ref" --arg now "$now" \
    '.git_sha = $sha | .git_ref = $ref | .updated_at = $now' \
    "$state_file" > "$tmp_file" \
    && mv "$tmp_file" "$state_file"

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
    running|failed)
      return 0  # Can resume
      ;;
    completed|cancelled)
      return 1  # Cannot resume
      ;;
    *)
      return 0  # Unknown status, try to resume
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

  # Hosts not yet started or with pending status
  local all_targets completed failed
  all_targets=$(echo "$state" | jq -r '.targets[]?' 2>/dev/null)
  completed=$(build_state_completed_hosts "$tool" "$version" "$run_id")
  failed=$(build_state_failed_hosts "$tool" "$version" "$run_id")

  # Return targets that aren't completed or failed
  for target in $all_targets; do
    if ! echo "$completed $failed" | grep -qw "$target"; then
      echo "$target"
    fi
  done
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

# Export functions
export -f build_state_init build_lock_acquire build_lock_release build_lock_check build_lock_info
export -f build_state_create build_state_get build_state_update_status build_state_update_host
export -f build_state_add_artifact build_state_can_resume
export -f build_state_set_git_info build_state_get_git_sha build_state_get_git_ref
export -f build_state_completed_hosts build_state_failed_hosts build_state_pending_hosts
export -f build_state_workspace build_state_artifacts_dir build_state_logs_dir
export -f build_state_workspace_logs_dir
export -f build_state_list build_state_cleanup
