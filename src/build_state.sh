#!/usr/bin/env bash
# build_state.sh - Build workspace isolation and state management
#
# Provides:
#   - Lock acquisition/release per tool+version
#   - Build state persistence (JSON with authoritative per-target status)
#   - Workspace isolation (unique run_id directories)
#   - Resume from partial builds
#   - Inherited build custody across coordinator loss
#   - Verified borrowing of a caller's inherited build custody
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

if ! declare -F dsr_lock_fd >/dev/null; then
  # shellcheck source=src/guardrails.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/guardrails.sh" || { return 3 2>/dev/null || exit 3; }
fi

# State directory
_BUILD_STATE_DIR="${_BUILD_STATE_DIR:-}"

# Indexed arrays keep this Bash 4.0 compatible, including when the module is
# sourced from a loader function (where declare would create local variables).
# A re-source must not forget an open lease. Children inherit these descriptors,
# but only the process that acquired one may explicitly release its copy.
if [[ "${_BUILD_LOCK_REGISTRY_READY:-0}" != 1 ]]; then
  _BUILD_LOCK_PATHS=("") _BUILD_LOCK_FDS=("") _BUILD_LOCK_IDENTITIES=("")
  _BUILD_LOCK_OWNERS=("") _BUILD_LOCK_RECORDS=("")
  _BUILD_LOCK_REGISTRY_READY=1
fi

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
  dsr_lock_fd "$1" "$2"
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

# Use a stable inode for the kernel lease and a separate, atomic metadata file.
# Neither lease age nor coordinator death proves that inherited workers stopped.
# Never unlink this sidecar, or unlock its shared open description with LOCK_UN.
_build_lock_open_lease() {
  local lease="$1" create="${2:-true}" descriptor
  _BUILD_LOCK_OPEN_FD=""
  if [[ ! -e "$lease" && ! -L "$lease" ]]; then
    [[ "$create" == true ]] || return 1
    (umask 077; set -C; : > "$lease") 2>/dev/null || true
  fi
  [[ -f "$lease" && ! -L "$lease" ]] || return 1
  # Preserve caller descriptors and other build leases. Bash 4.0 predates
  # exec {variable}; eval receives only our bounded numeric descriptor.
  for ((descriptor = 10; descriptor < 200; descriptor++)); do
    if ! { : <&"$descriptor"; } 2>/dev/null; then
      if eval 'exec '"$descriptor"'<> "$lease"'; then
        _BUILD_LOCK_OPEN_FD="$descriptor"
        return 0
      fi
      return 1
    fi
  done
  log_error "No free descriptor for build custody"
  return 1
}

_build_lock_close_fd() {
  local descriptor="$1"
  [[ "$descriptor" =~ ^[0-9]{1,3}$ ]] || return 1
  eval "exec ${descriptor}>&-"
}

_build_lock_record() {
  local path="$1" expected_identity="${2:-}" record pid timestamp run format token identity extra
  [[ -f "$path" && ! -L "$path" ]] || return 1
  record=$(cat -- "$path") || return 1
  [[ "$record" != *$'\n'* ]] || return 1
  read -r pid timestamp run format token identity extra <<< "$record"
  [[ "$pid" =~ ^[1-9][0-9]{0,9}$ && "$timestamp" =~ ^(0|[1-9][0-9]{0,9})$ &&
     "$run" =~ ^[A-Za-z0-9._-]+$ && "$format" == lease-v1 &&
     "$token" =~ ^[A-Za-z0-9:.-]+$ && "$identity" =~ ^[0-9]+:[0-9]+$ &&
     -z "$extra" && ( -z "$expected_identity" || "$identity" == "$expected_identity" ) ]] || return 1
  printf '%s\n' "$record"
}

# A probe uses a separate open description even when this shell owns the lease.
# Return 0 when free, 2 when held, and 4 for unverifiable custody. Only a verified
# free lease permits admission; legacy PID-only metadata is retained and refused.
_build_lock_probe() (
  local lock_file="$1" lease="$1.lease" descriptor identity
  if [[ ! -e "$lease" && ! -L "$lease" ]]; then
    [[ ! -e "$lock_file" && ! -L "$lock_file" ]] && return 0
    return 4
  fi
  _build_lock_open_lease "$lease" false || return 4
  descriptor="$_BUILD_LOCK_OPEN_FD"
  identity=$(_build_state_fd_identity "$descriptor") || return 4
  [[ ! -L "$lease" && "$(_build_state_file_identity "$lease")" == "$identity" ]] || return 4
  command -v flock >/dev/null || command -v python3 >/dev/null || return 4
  _build_state_wait_lock "$descriptor" 0 || return 2
  [[ ! -L "$lease" && "$(_build_state_file_identity "$lease")" == "$identity" ]] || return 4
  if [[ -e "$lock_file" || -L "$lock_file" ]]; then
    _build_lock_record "$lock_file" "$identity" >/dev/null || return 4
  fi
  return 0
)

# Acquire custody for a tool/version. Workers inherit the descriptor, keeping
# exclusion after coordinator loss until the last owned descendant closes it.
# Returns 2 for contention and 1 for unavailable/unsafe custody.
build_lock_acquire() {
  local tool="$1" version="$2" tool_dir lock_file lease descriptor identity
  local index timestamp run record metadata
  [[ -n "$_BUILD_STATE_DIR" ]] || build_state_init || return 1
  tool_dir=$(_build_get_tool_dir "$tool" "$version")
  if ! mkdir -p "$tool_dir" || [[ ! -d "$tool_dir" || -L "$tool_dir" ]]; then
    log_error "Failed to create safe build custody directory: $tool_dir"
    return 1
  fi
  lock_file=$(_build_get_lock_file "$tool" "$version")
  lease="$lock_file.lease"
  if [[ ( -e "$lock_file" || -L "$lock_file" ) && ! -e "$lease" ]]; then
    log_error "Build custody has metadata without its original lease; explicit recovery is required"
    return 1
  fi
  for index in "${!_BUILD_LOCK_PATHS[@]}"; do
    if [[ "${_BUILD_LOCK_PATHS[$index]}" == "$lock_file" ]]; then
      log_warn "Build custody is already held by this shell or an ancestor"
      return 2
    fi
  done
  _build_lock_open_lease "$lease" || return 1
  descriptor="$_BUILD_LOCK_OPEN_FD"
  if ! identity=$(_build_state_fd_identity "$descriptor") || [[ -L "$lease" ||
       "$(_build_state_file_identity "$lease")" != "$identity" ]]; then
    _build_lock_close_fd "$descriptor"
    return 1
  fi
  if ! command -v flock >/dev/null && ! command -v python3 >/dev/null; then
    _build_lock_close_fd "$descriptor"
    log_error "Build custody requires flock or Python 3 with fcntl"
    return 1
  fi
  if ! _build_state_wait_lock "$descriptor" 0; then
    _build_lock_close_fd "$descriptor"
    log_warn "Build custody is held by a coordinator or its workers"
    return 2
  fi
  if [[ -L "$lease" || "$(_build_state_file_identity "$lease")" != "$identity" ]] ||
     { [[ -e "$lock_file" || -L "$lock_file" ]] && ! _build_lock_record "$lock_file" "$identity" >/dev/null; }; then
    _build_lock_close_fd "$descriptor"
    log_error "Build custody metadata is unsafe or predates inherited leases; retained for explicit recovery"
    return 1
  fi
  timestamp=$(date +%s) || { _build_lock_close_fd "$descriptor"; return 1; }
  run="${DSR_RUN_ID:-run-$timestamp-$BASHPID}"
  if [[ ! "$run" =~ ^[A-Za-z0-9._-]+$ ]] ||
     ! metadata=$(umask 077; mktemp "$lock_file.owner.XXXXXXXX"); then
    _build_lock_close_fd "$descriptor"
    return 1
  fi
  record="$BASHPID $timestamp $run lease-v1 $BASHPID:$RANDOM:$RANDOM $identity"
  if ! printf '%s\n' "$record" > "$metadata" ||
     [[ -L "$lease" || "$(_build_state_file_identity "$lease")" != "$identity" || -L "$lock_file" ]] ||
     ! mv -f -- "$metadata" "$lock_file"; then
    _build_lock_close_fd "$descriptor"
    return 1
  fi
  index=${#_BUILD_LOCK_PATHS[@]}
  # Released entries retain their index so concurrent locks never overwrite
  # another registry slot after an earlier lock has been released.
  while [[ -n "${_BUILD_LOCK_PATHS[$index]:-}" ]]; do index=$((index + 1)); done
  _BUILD_LOCK_PATHS[$index]="$lock_file"
  _BUILD_LOCK_FDS[$index]="$descriptor"
  _BUILD_LOCK_IDENTITIES[$index]="$identity"
  _BUILD_LOCK_OWNERS[$index]="$BASHPID"
  _BUILD_LOCK_RECORDS[$index]="$record"
  log_info "Acquired build custody for $tool $version"
  return 0
}

# Borrow custody already held by this shell or an ancestor. The registry is
# inherited by Bash children, not exported as an environment assertion. Verify
# the original open description as well as its path and exact owner record;
# a busy pathname alone could belong to a different process after replacement.
# Return 1 for no registered lease, 4 for unverifiable custody, and 0 only for
# verified custody. Never close the descriptor or change its acquiring owner.
build_lock_borrow() {
  local tool="$1" version="$2" lock_file index descriptor identity record owner probe_status
  [[ "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ &&
     "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] || return 4
  [[ -n "$_BUILD_STATE_DIR" ]] || return 1
  lock_file=$(_build_get_lock_file "$tool" "$version")
  for index in "${!_BUILD_LOCK_PATHS[@]}"; do
    [[ "${_BUILD_LOCK_PATHS[$index]}" == "$lock_file" ]] || continue
    descriptor="${_BUILD_LOCK_FDS[$index]:-}"
    identity="${_BUILD_LOCK_IDENTITIES[$index]:-}"
    record="${_BUILD_LOCK_RECORDS[$index]:-}"
    owner="${_BUILD_LOCK_OWNERS[$index]:-}"
    if [[ ! "$descriptor" =~ ^[0-9]{1,3}$ || ! "$identity" =~ ^[0-9]+:[0-9]+$ ||
          ! "$owner" =~ ^[1-9][0-9]*$ ||
          "$record" != "$owner "* || -L "$lock_file.lease" ||
          "$(_build_state_file_identity "$lock_file.lease")" != "$identity" ||
          "$(_build_state_fd_identity "$descriptor")" != "$identity" ||
          "$(_build_lock_record "$lock_file" "$identity")" != "$record" ]]; then
      log_error "Cannot borrow changed build custody for $tool $version"
      return 4
    fi
    probe_status=0
    _build_lock_probe "$lock_file" || probe_status=$?
    # The independent open must be excluded, while the registered original
    # description must still hold the lease. Neither operation unlocks it.
    if [[ "$probe_status" != 2 ]] || ! _build_state_wait_lock "$descriptor" 0 ||
       [[ -L "$lock_file.lease" ||
          "$(_build_state_file_identity "$lock_file.lease")" != "$identity" ||
          "$(_build_state_fd_identity "$descriptor")" != "$identity" ||
          "$(_build_lock_record "$lock_file" "$identity")" != "$record" ]]; then
      log_error "Cannot verify inherited build custody for $tool $version"
      return 4
    fi
    return 0
  done
  return 1
}

build_lock_release() {
  local tool="$1" version="$2" lock_file index descriptor
  [[ -n "$_BUILD_STATE_DIR" ]] || build_state_init || return 1
  lock_file=$(_build_get_lock_file "$tool" "$version")
  for index in "${!_BUILD_LOCK_PATHS[@]}"; do
    [[ "${_BUILD_LOCK_PATHS[$index]}" == "$lock_file" ]] || continue
    if [[ "${_BUILD_LOCK_OWNERS[$index]}" != "$BASHPID" ]]; then
      log_warn "Only the acquiring process may release its build custody descriptor"
      return 1
    fi
    descriptor="${_BUILD_LOCK_FDS[$index]}"
    if [[ -L "$lock_file.lease" ||
          "$(_build_state_file_identity "$lock_file.lease")" != "${_BUILD_LOCK_IDENTITIES[$index]}" ||
          "$(_build_state_fd_identity "$descriptor")" != "${_BUILD_LOCK_IDENTITIES[$index]}" ||
          "$(_build_lock_record "$lock_file" "${_BUILD_LOCK_IDENTITIES[$index]}")" != "${_BUILD_LOCK_RECORDS[$index]}" ]]; then
      log_error "Build custody identity changed; refusing to release an unrelated descriptor"
      return 1
    fi
    _build_lock_close_fd "$descriptor" || return 1
    _BUILD_LOCK_PATHS[$index]=""
    _BUILD_LOCK_FDS[$index]="" _BUILD_LOCK_IDENTITIES[$index]=""
    _BUILD_LOCK_OWNERS[$index]="" _BUILD_LOCK_RECORDS[$index]=""
    log_info "Released coordinator custody for $tool $version; inherited workers retain their leases"
    return 0
  done
  # Idempotent release is safe only when no other process holds custody.
  _build_lock_probe "$lock_file" || return 1
}

# Unknown custody is treated as locked, never as permission to start or prune.
build_lock_check() {
  local lock_file
  [[ -n "$_BUILD_STATE_DIR" ]] || build_state_init || return 0
  lock_file=$(_build_get_lock_file "$1" "$2")
  if _build_lock_probe "$lock_file"; then return 1; fi
  return 0
}

build_lock_info() {
  local lock_file record status=0 pid timestamp run format token identity now age alive=false
  local locked=false custody=free
  [[ -n "$_BUILD_STATE_DIR" ]] || build_state_init || return 1
  lock_file=$(_build_get_lock_file "$1" "$2")
  _build_lock_probe "$lock_file" || status=$?
  if [[ "$status" == 2 ]]; then locked=true; custody=held
  elif [[ "$status" != 0 ]]; then locked=true; custody=unverifiable; fi
  if ! record=$(_build_lock_record "$lock_file"); then
    jq -nc --argjson locked "$locked" --arg custody "$custody" \
      '{locked:$locked,custody:$custody} +
       (if $locked then {error:"Build custody metadata is unavailable or unverifiable"} else {} end)'
    return
  fi
  read -r pid timestamp run format token identity <<< "$record"
  now=$(date +%s) || return 1
  age=$((now - 10#$timestamp))
  kill -0 "$pid" 2>/dev/null && alive=true
  jq -nc --argjson locked "$locked" --arg custody "$custody" \
    --argjson pid "$pid" --argjson timestamp "$timestamp" --argjson age "$age" \
    --arg run "$run" --argjson alive "$alive" \
    '{locked:$locked,custody:$custody,pid:$pid,timestamp:$timestamp,
      age_seconds:$age,run_id:$run,process_alive:$alive,stale:false}'
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
      --slurpfile extra /dev/stdin \
      '($extra | select(length == 1 and (.[0] | type == "object")) | .[0]) as $extra |
       .hosts[$host] = ((.hosts[$host] // {}) + $extra + {status: $status, updated_at: $now}) |
       .updated_at = $now' <<< "$extra_json"; then
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
      --slurpfile extra /dev/stdin '
        ($extra | select(length == 1) | .[0]) as $extra |
        .target_statuses = (.target_statuses // {}) |
        (.target_statuses[$target] // {attempts: 0}) as $prior |
        .target_statuses[$target] =
          ($prior + $extra +
           {status: $status, updated_at: $now}) |
        # A source-sync failure reserves an immutable attempt receipt, but no
        # compiler was admitted. Count each such attempt once so repairing a
        # disconnected host does not exhaust its compiler retry allowance.
        if $status == "failed" and $extra.result.stage == "source_sync" and
           ($prior.status != "failed" or $prior.result.stage != "source_sync" or
            $prior.attempts != $extra.attempts)
        then .target_statuses[$target].source_sync_failures =
          (($prior.source_sync_failures // 0) + 1)
        else . end |
        # Native readiness refusals likewise stop before compilation. Keep
        # their attempt receipts, but do not spend the compiler retry budget
        # while an operator repairs an unavailable or full build host.
        if $status == "failed" and $extra.result.stage == "host_readiness" and
           $extra.result.exit_code == 4 and
           ($extra.result.status == "failed" or $extra.result.status == "error") and
           ($prior.status != "failed" or $prior.result.stage != "host_readiness" or
            $prior.result.exit_code != 4 or $prior.attempts != $extra.attempts)
        then .target_statuses[$target].host_readiness_failures =
          (($prior.host_readiness_failures // 0) + 1)
        else . end |
        # Waiting for a busy host is a real, retained scheduling attempt, but
        # it cannot spend compiler retries when no backend was launched. The
        # worker owns backend_started; an executed command cannot opt out by
        # printing a capacity label. Replaying the same refusal is idempotent.
        if $status == "failed" and $extra.result.stage == "host_capacity" and
           $extra.result.exit_code == 2 and $extra.result.backend_started == false and
           ($extra.result.status == "failed" or $extra.result.status == "error") and
           ($prior.status != "failed" or $prior.result.stage != "host_capacity" or
            $prior.result.exit_code != 2 or $prior.result.backend_started != false or
            $prior.attempts != $extra.attempts)
        then .target_statuses[$target].host_capacity_failures =
          (($prior.host_capacity_failures // 0) + 1)
        else . end |
        .updated_at = $now' <<< "$extra_json"; then
    return 1
  fi

  log_debug "Target status updated: $target -> $target_status"
}

# Bind a run to the inputs required for an honest resume.
# Args: tool version run_id git_sha git_ref source_roots_json output_dir
#       parallel_jobs target_hosts_json build_purpose build_tasks_json matrix_config_sha256
#       source_sync_json repo_config_sha256
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
  local build_tasks_json="${11:-}" native_matrix_config_sha256="${12:-}"
  local source_sync_json="${13:-null}"
  local repo_config_sha256="${14:-}"
  if [[ ! "$repo_config_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    log_error "Build context requires the captured repository configuration digest"
    return 1
  fi
  if [[ -n "$native_matrix_config_sha256" && "$native_matrix_config_sha256" != "$repo_config_sha256" ]]; then
    log_error "Native matrix and repository configuration must bind the same captured recipe"
    return 1
  fi

  local tool_dir state_file now
  tool_dir=$(_build_get_tool_dir "$tool" "$version")
  state_file="$tool_dir/$run_id/state.json"
  [[ -f "$state_file" ]] || return 1
  if [[ -z "$build_tasks_json" ]]; then
    build_tasks_json=$(jq -c '[.targets[] | {key:., platform:., target_triple:"", method:"native"}]' \
      "$state_file") || return 1
  fi
  if ! jq -e --argjson tasks "$build_tasks_json" --arg digest "$native_matrix_config_sha256" '
      .targets as $platforms |
      ($tasks | type == "array") and
      ([$tasks[].key] | unique | length) == ($tasks | length) and
      all($tasks[];
        (.key | type == "string" and length > 0) and
        (.platform as $platform | $platforms | index($platform) != null) and
        (.target_triple | type == "string") and
        (.method == "act" or .method == "native") and
        (.key == .platform or (.method == "native" and
          (.target_triple | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (contains("..") | not)) and
          .key == (.platform + "@" + .target_triple)))) and
      ([$tasks[].platform] | unique | sort) == ($platforms | unique | sort) and
      (if any($tasks[]; .key != .platform) then $digest | test("^[0-9a-f]{64}$")
       else $digest == "" end)
    ' "$state_file" >/dev/null 2>&1; then
    log_error "Invalid build task plan for run $run_id"
    return 1
  fi
  jq -e 'type == "object"' <<< "$source_roots_json" &>/dev/null || return 1
  jq -e 'type == "object"' <<< "$target_hosts_json" &>/dev/null || return 1
  jq -es 'length == 1 and (.[0] == null or (.[0] | type == "object"))' \
    <<< "$source_sync_json" &>/dev/null || return 1
  [[ "$parallel_jobs" =~ ^[1-9][0-9]*$ ]] || return 1
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _build_state_jq_update "$state_file" \
    --arg sha "$git_sha" --arg ref "$git_ref" \
    --argjson source_roots "$source_roots_json" \
    --argjson target_hosts "$target_hosts_json" \
    --slurpfile source_sync /dev/stdin \
    --arg build_purpose "$build_purpose" \
    --argjson build_tasks "$build_tasks_json" \
    --arg native_matrix_config_sha256 "$native_matrix_config_sha256" \
    --arg repo_config_sha256 "$repo_config_sha256" \
    --arg output_dir "$output_dir" --argjson parallel_jobs "$parallel_jobs" \
    --arg now "$now" '
      ($source_sync | select(length == 1) | .[0]) as $source_sync |
      .git_sha = $sha |
      .git_ref = $ref |
      .context = {
        build_purpose: $build_purpose,
        publishable: ($build_purpose == "release"),
        source_roots: $source_roots,
        target_hosts: $target_hosts,
        source_sync: $source_sync,
        build_tasks: $build_tasks,
        native_matrix_config_sha256: $native_matrix_config_sha256,
        repo_config_sha256: $repo_config_sha256,
        output_dir: $output_dir,
        parallel_jobs: $parallel_jobs
      } |
      .target_statuses = (reduce $build_tasks[] as $task ({};
        .[$task.key] = {status: "pending", attempts: 0})) |
      .source_sync_history = (if $source_sync == null then []
        else [{recorded_at: $now, receipt: $source_sync}] end) |
      .updated_at = $now' <<< "$source_sync_json"
}

# Refresh an ordinary run's sync admission evidence without changing completed
# targets or their attempt receipts. The coordinator validates the receipt and
# holds the orchestration lock. A null receipt records an explicit sync opt-out.
# Args: tool version run_id source_sync_json source_roots_json target_hosts_json
build_state_set_source_sync() {
  local tool="$1" version="$2" run_id="$3" source_sync_json="$4"
  local source_roots_json="$5" target_hosts_json="$6" tool_dir state_file now
  if ! jq -es --argjson roots "$source_roots_json" --argjson hosts "$target_hosts_json" '
        length == 1 and (.[0] as $receipt |
        ($receipt == null or ($receipt | type == "object")) and
        ($roots | type == "object") and all($roots[]; type == "string" and length > 0) and
        ($hosts | type == "object") and all($hosts[]; type == "string" and length > 0) and
        ($receipt == null or ($receipt.source_roots == $roots and $receipt.target_hosts == $hosts)))
      ' <<< "$source_sync_json" >/dev/null 2>&1; then
    log_error "Invalid source-sync context for run $run_id"
    return 1
  fi
  tool_dir=$(_build_get_tool_dir "$tool" "$version")
  state_file="$tool_dir/$run_id/state.json"
  [[ -f "$state_file" ]] || return 1
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  _build_state_jq_update "$state_file" \
    --slurpfile source_sync /dev/stdin --argjson roots "$source_roots_json" \
    --argjson hosts "$target_hosts_json" --arg now "$now" '
      ($source_sync | select(length == 1) | .[0]) as $source_sync |
      if .status == "completed" or .status == "cancelled"
      then error("cannot refresh source sync for a terminal run")
      else
        .context.source_sync = $source_sync |
        .context.source_roots = $roots |
        .context.target_hosts = $hosts |
        .source_sync_history = ((.source_sync_history // []) +
          [{recorded_at: $now, receipt: $source_sync}]) |
        .updated_at = $now
      end' <<< "$source_sync_json"
}

# Shared jq definitions keep initial host projection and retained-state
# admission on the same task identity rules. No state or receipt bytes enter
# the jq program or its argv; callers stream those documents separately.
_build_state_task_host_filters() {
  cat <<'JQ'
    def repo_config_digest:
      type == "string" and test("^[0-9a-f]{64}$");
    def admit_repo_config_history:
      . as $state |
      (if has("relocations") then .relocations else [] end) as $history |
      if (.context.repo_config_sha256 | repo_config_digest | not) then
        error("build run lacks a saved repository configuration digest; start a fresh run")
      elif ($history | type) != "array" then error("invalid relocation recipe history")
      elif any(.context.build_tasks[]?; .key != .platform) and
           .context.native_matrix_config_sha256 != .context.repo_config_sha256 then
        error("saved native matrix and repository configuration digests differ")
      elif ($history | length) == 0 then .
      else
        (reduce $history[] as $receipt ($history[0].prior_context.repo_config_sha256;
          if (repo_config_digest | not) or
             $receipt.prior_context.repo_config_sha256 != . or
             $receipt.approval.prior_repo_config_sha256 != . or
             ($receipt.repo_config_sha256 | repo_config_digest | not) or
             $receipt.approval.repo_config_sha256 != $receipt.repo_config_sha256 or
             $receipt.approval.run_id != $state.run_id or
             $receipt.approval.target != $receipt.target or
             $receipt.approval.new_host != $receipt.new_host or
             (any($receipt.prior_context.build_tasks[]?; .key != .platform) and
               $receipt.prior_context.native_matrix_config_sha256 != .)
          then error("relocation history does not bind the retained repository recipe")
          else $receipt.repo_config_sha256 end)) as $digest |
        if $digest == $state.context.repo_config_sha256 then $state
        else error("saved repository recipe differs from approved relocation history") end
      end;
    def task_host_overrides:
      if type != "object" then error("invalid build context")
      elif has("task_host_overrides") then
        .task_host_overrides |
        if type == "object" then . else error("invalid task host overrides") end
      else {} end;
    def effective_task_hosts:
      .context as $context |
      ($context | task_host_overrides) as $overrides |
      $context.build_tasks as $tasks |
      $context.target_hosts as $hosts |
      if ($tasks | type != "array" or length == 0) or
         ([$tasks[].key] | unique | length) != ($tasks | length) or
         (all($tasks[];
           (.platform | type == "string" and test("^[a-z]+/[a-z0-9]+$")) and
           (.target_triple | type == "string") and
           (.method == "native" or .method == "act") and
           (.key == .platform or (.method == "native" and
             (.target_triple | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (contains("..") | not)) and
             .key == (.platform + "@" + .target_triple)))) | not) or
         ($hosts | type != "object") or
         ($hosts | keys | sort) != ([$tasks[].platform] | unique | sort) or
         (all($hosts[]; type == "string" and test("^[A-Za-z0-9_-]+$")) | not) or
         (all($overrides | to_entries[];
           . as $override |
           (.value | type == "string" and test("^[A-Za-z0-9_-]+$")) and
           any($tasks[]; .key == $override.key and .key != .platform and .method == "native")) | not)
      then error("invalid task host bindings")
      else reduce $tasks[] as $task ({};
        .[$task.key] = ($overrides[$task.key] // $hosts[$task.platform]))
      end;
    def normalized_task_context:
      . + {task_host_overrides: task_host_overrides};
    def valid_relocation_counter($key):
      (if has($key) then .[$key] else 0 end) |
      type == "number" and floor == . and . >= 0 and . <= 9007199254740991;
    def relocated_task_context($state; $receipt):
      . as $prior |
      ({context: $prior} | effective_task_hosts) as $old_hosts |
      [$prior.build_tasks[] | select(.key == $receipt.target)] as $matches |
      $matches[0] as $task |
      if ($matches | length) != 1 or $task.method != "native" or
         $prior.build_tasks != $state.context.build_tasks or
         ($receipt.new_host | type != "string" or (test("^[A-Za-z0-9_-]+$") | not)) or
         $receipt.old_host != $old_hosts[$task.key] or $receipt.new_host == $receipt.old_host or
         $receipt.git_sha != $state.git_sha or $receipt.git_ref != $state.git_ref or
         ($state.git_sha | type != "string" or (test("^[0-9a-f]{40}$") | not)) or
         ($state.git_ref | type != "string" or length == 0) or
         $receipt.prior_target.status != "failed" or
         (all(["attempts", "source_sync_failures", "host_readiness_failures", "host_capacity_failures"][];
           . as $key | $receipt.prior_target | valid_relocation_counter($key)) | not) or
         (($receipt.prior_target.source_sync_failures // 0) +
          ($receipt.prior_target.host_readiness_failures // 0) +
          ($receipt.prior_target.host_capacity_failures // 0)) > ($receipt.prior_target.attempts // 0) or
         $receipt.approval.run_id != $state.run_id or
         $receipt.approval.target != $task.key or $receipt.approval.new_host != $receipt.new_host or
         (all([$prior.repo_config_sha256, $prior.native_matrix_config_sha256, $receipt.repo_config_sha256,
               $receipt.hosts_config_sha256, $receipt.prior_result_sha256, $receipt.prior_log_sha256][];
           type == "string" and test("^[0-9a-f]{64}$")) | not) or
         $receipt.approval.prior_repo_config_sha256 != $prior.repo_config_sha256 or
         $prior.repo_config_sha256 != $prior.native_matrix_config_sha256 or
         $receipt.approval.repo_config_sha256 != $receipt.repo_config_sha256 or
         $receipt.approval.hosts_config_sha256 != $receipt.hosts_config_sha256 or
         ($task.key != $task.platform and
           ($receipt.task_key != $task.key or $receipt.platform != $task.platform or
            $receipt.target_triple != $task.target_triple or
            $receipt.prior_target.result.host != $receipt.old_host or
            $receipt.prior_target.result.platform != $task.platform or
            $receipt.prior_target.result.task_key != $task.key or
            $receipt.prior_target.result.target_triple != $task.target_triple or
            $receipt.new_host_platform != $task.platform or
            $receipt.repo_config_sha256 != $prior.native_matrix_config_sha256)) or
         $receipt.verified_source_sync.status != "success" or $receipt.verified_source_sync.failed != 0 or
         $receipt.verified_source_sync.target_hosts != {($task.platform): $receipt.new_host} or
         ($receipt.verified_source_sync.source_roots | type != "object" or keys != [$receipt.new_host]) or
         ($receipt.verified_source_sync.source_roots[$receipt.new_host] | type != "string" or length == 0) or
         ($prior.source_roots | type != "object") or
         (all($prior.source_roots[]; type == "string" and length > 0) | not) or
         ($prior.source_roots | keys | sort) != ([$old_hosts[]] | unique | sort) or
         (($prior.source_roots | has($receipt.new_host)) and
           $prior.source_roots[$receipt.new_host] != $receipt.verified_source_sync.source_roots[$receipt.new_host]) or
         ($receipt.verified_source_inventory | type != "array" or length == 0) or
         ([$receipt.verified_source_inventory[].path] | length) !=
           ([$receipt.verified_source_inventory[].path] | unique | length) or
         (all($receipt.verified_source_inventory[];
           (.path | type == "string" and length > 0) and
           (.git_sha | type == "string" and test("^[0-9a-f]{40}$")) and
           all([.archive_sha256, .manifest_sha256][];
             type == "string" and test("^[0-9a-f]{64}$"))) | not) or
         (any($receipt.verified_source_inventory[]; .path == "source" and .git_sha == $state.git_sha) | not)
      then error("relocation history does not bind task, recipe and source custody")
      else
        (if $task.key == $task.platform then .target_hosts[$task.key] = $receipt.new_host
         else .task_host_overrides = (task_host_overrides + {($task.key): $receipt.new_host}) end) |
        .native_matrix_config_sha256 = $receipt.repo_config_sha256 |
        .repo_config_sha256 = $receipt.repo_config_sha256 |
        ({context: .} | effective_task_hosts) as $new_hosts |
        .source_roots = (($prior.source_roots + $receipt.verified_source_sync.source_roots) |
          with_entries(select(.key as $host | $new_hosts | any(. == $host))))
      end;
    def admit_task_host_history:
      . as $state |
      (if has("relocations") then .relocations else [] end) as $history |
      if ($history | type) != "array" then error("invalid relocation history")
      elif ((.context // {}) | has("task_host_overrides")) or
           any($history[]; ((.target // "") | contains("@")) or
             ((.task_key // "") | contains("@")))
      then
        effective_task_hosts as $hosts |
        (.context | task_host_overrides) as $overrides |
        if ($overrides | length) == 0 and
           (any($history[]; ((.target // "") | contains("@")) or
             ((.task_key // "") | contains("@"))) | not) then $state
        elif ($history | length) == 0 then
          error("task host overrides lack relocation history")
        elif ($history[0].prior_context | task_host_overrides | length) != 0 then
          error("relocation history starts with an unproved task override")
        else
          (reduce $history[] as $receipt ($history[0].prior_context;
            if (normalized_task_context) != ($receipt.prior_context | normalized_task_context)
            then error("relocation context history is inconsistent")
            else relocated_task_context($state; $receipt) end)) as $expected |
          if ($expected | normalized_task_context) == ($state.context | normalized_task_context)
          then $state else error("task host overrides differ from approved relocation history") end
        end
      else . end;
JQ
}

# Project only the supplied context. Initial strict admission uses this before
# a checkpoint exists; stored overrides additionally require history admission.
# Args: state_json (with context.build_tasks, target_hosts, optional overrides)
build_state_effective_task_hosts() {
  local state="$1" filters
  filters=$(_build_state_task_host_filters) || return 1
  jq -ce -s "$filters"'
    if length == 1 then .[0] | effective_task_hosts
    else error("exactly one build context required") end
  ' <<< "$state"
}

# A run may reuse old outputs only with its captured recipe. Relocation is the
# sole reviewed transition: every prior digest must lead to the current one.
# Omit expected_digest only while admitting that explicit reviewed transition.
# Missing legacy evidence is never synthesized from the current configuration.
build_state_validate_repo_config() {
  local state="$1" expected_digest="${2:-}" filters
  filters=$(_build_state_task_host_filters) || return 1
  if ! jq -ce -s --arg expected "$expected_digest" "$filters"'
    if length == 1 then .[0] | admit_repo_config_history |
      if $expected == "" or .context.repo_config_sha256 == $expected then true
      else error("repository configuration changed; restore the saved recipe or start a fresh run") end
    else error("exactly one build checkpoint required") end
  ' <<< "$state" >/dev/null; then
    log_error "Cannot resume with an unbound or changed repository recipe; restore the saved configuration or start a fresh run"
    return 1
  fi
}

# Shape alone cannot authorize a persisted route. Replay reviewed relocations
# before using overrides on resume, including when an override was removed or
# changed to another already-staged host. This does not read remote systems.
build_state_validate_task_host_overrides() {
  local state="$1" filters
  filters=$(_build_state_task_host_filters) || return 1
  jq -ce -s "$filters"'
    if length == 1 then .[0] | admit_task_host_history | true
    else error("exactly one build checkpoint required") end
  ' <<< "$state" >/dev/null
}

# Atomically replace only a failed target's host binding, preserving its attempt
# history and every completed target. Caller holds the orchestration lock.
build_state_relocate_failed_target() {
  local tool="$1" version="$2" run_id="$3" before="$4" target="$5"
  local host="$6" roots="$7" receipt="$8" tool_dir state_file filters
  tool_dir=$(_build_get_tool_dir "$tool" "$version")
  state_file="$tool_dir/$run_id/state.json"
  filters=$(_build_state_task_host_filters) || return 1
  # Before/receipt include retained result and relocation histories. Separate
  # input descriptors avoid the OS single-argument limit while preserving each
  # argument's document boundary; one input cannot supply another's receipt.
  _build_state_jq_update "$state_file" \
    --slurpfile before /dev/fd/3 --slurpfile roots /dev/fd/4 --slurpfile receipt /dev/fd/5 \
    --arg target "$target" --arg host "$host" "$filters"'
      def one: if length == 1 then .[0] else error("exactly one relocation input required") end;
      ($before | one) as $before | ($roots | one) as $roots | ($receipt | one) as $receipt |
      . as $state |
      if . != $before or .target_statuses[$target].status != "failed" or
         (.status == "completed" or .status == "cancelled")
      then error("relocation state changed or target is not failed")
      elif ((.context.repo_config_sha256 | repo_config_digest) | not) or
           (($receipt.repo_config_sha256 | repo_config_digest) | not) or
           $receipt.approval.prior_repo_config_sha256 != .context.repo_config_sha256 or
           $receipt.approval.repo_config_sha256 != $receipt.repo_config_sha256 or
           $receipt.prior_context != .context or
           $receipt.prior_target != .target_statuses[$target] or
           $receipt.target != $target or $receipt.new_host != $host
      then error("relocation approval does not bind the retained repository configuration")
      elif any(.context.build_tasks[]?; .key != .platform) and
         (((.context.native_matrix_config_sha256 | type == "string" and
               test("^[0-9a-f]{64}$")) | not) or
          (($receipt.repo_config_sha256 | type == "string" and
               test("^[0-9a-f]{64}$")) | not) or
          $receipt.approval.prior_repo_config_sha256 != .context.native_matrix_config_sha256)
      then error("relocation approval does not bind the retained native matrix configuration")
      elif $target | contains("@") then
        if .context.build_purpose != "release" or .context.publishable != true or
           any(.target_statuses[]; .status == "running") or
           $receipt.target != $target or $receipt.new_host != $host or
           $receipt.prior_context != .context or $receipt.prior_target != .target_statuses[$target]
        then error("qualified relocation does not bind the retained failed task")
        else
          (.context | relocated_task_context($state; $receipt)) as $next |
          if $roots != $next.source_roots then error("relocation changed retained source custody")
          else .context = $next | .relocations = ((.relocations // []) + [$receipt]) end
        end
      else
        .relocations = ((.relocations // []) + [$receipt]) |
        .context.target_hosts[$target] = $host |
        .context.source_roots = $roots |
        .context.repo_config_sha256 = $receipt.repo_config_sha256 |
        if any(.context.build_tasks[]?; .key != .platform) then
          .context.native_matrix_config_sha256 = $receipt.repo_config_sha256
        else . end
      end | admit_repo_config_history | admit_task_host_history' 3<<< "$before" 4<<< "$roots" 5<<< "$receipt"
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
    created|running|failed|partial|targets-complete)
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

  local state filters
  state=$(build_state_get "$tool" "$version" "$run_id" 2>/dev/null) || return 1
  build_state_validate_task_host_overrides "$state" || return 1
  filters=$(_build_state_task_host_filters) || return 1

  # Target platforms are not host names. Use explicit host routing where
  # available, while still reading older host-named target inventories.
  jq -r "$filters"'
    . as $s |
    # This is an unfinished-work projection, like pending_targets. It includes
    # failed/exhausted tasks; build_state_resume applies the compiler budget.
    if (.context.task_host_overrides // {} | length) > 0 then
      effective_task_hosts as $routes |
      [.context.build_tasks[].key as $key |
       ($s.target_statuses[$key] // {}) as $entry |
       select(($entry.status == "completed" and ($entry.result | type) == "object" and
         ($entry.result | length) > 0) | not) | $routes[$key]] | unique[]
    else
      (((.hosts // {}) | keys) + [(.context.target_hosts // {})[]] +
        [.targets[]? | select(contains("/") | not)] | unique)[] as $host |
      ($s.hosts[$host].status // "pending") as $status |
      select($status == "pending" or $status == "running") | $host
    end
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
    (($state.context.build_tasks // [$state.targets[]? | {key:.}])[] | .key) as $target |
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
  if ! build_state_validate_repo_config "$state"; then
    echo '{"error": "Saved repository recipe is missing or invalid; start a fresh run", "can_resume": false}'
    return 1
  fi
  if ! build_state_validate_task_host_overrides "$state"; then
    log_error "Cannot resume task host bindings without matching relocation history"
    echo '{"error": "Invalid task host relocation history", "can_resume": false}'
    return 1
  fi

  local plan filters
  filters=$(_build_state_task_host_filters) || return 1
  if ! plan=$(jq -ce --argjson retry_max "$((10#$BUILD_RETRY_MAX))" "$filters"'
    def counter($key): if has($key) then .[$key] else 0 end;
    def valid_counter($key):
      counter($key) | type == "number" and floor == . and . >= 0 and . <= 9007199254740991;
    def entry_status: if has("status") then .status else "pending" end;
    def valid_status:
      entry_status as $status |
      ["pending", "running", "completed", "failed", "cancelled", "skipped"] | index($status) != null;
    def tasks: .context.build_tasks // [.targets[] | {key:., platform:.}];
    . as $s |
    if (.status != "created" and .status != "running" and .status != "failed" and
        .status != "partial" and .status != "targets-complete") or
       (.targets | type) != "array" or
       (all(.targets[]; type == "string" and length > 0) | not) or
       (.targets | unique | length) != (.targets | length) or
       (.hosts | type) != "object" or
       (all(.hosts[]; type == "object" and valid_status and valid_counter("retry_count")) | not) or
       (.target_statuses != null and (.target_statuses | type) != "object") or
       (all((.target_statuses // {})[];
         type == "object" and valid_status and valid_counter("attempts") and
         valid_counter("source_sync_failures") and
         valid_counter("host_readiness_failures") and
         valid_counter("host_capacity_failures") and
         ((counter("source_sync_failures") + counter("host_readiness_failures") +
           counter("host_capacity_failures")) <= counter("attempts"))) | not) or
       (tasks | type) != "array" or
       ([tasks[].key] | unique | length) != (tasks | length) or
       (all(tasks[]; (.key | type == "string" and length > 0) and
         (.platform as $p | $s.targets | index($p) != null)) | not) or
       ([tasks[].platform] | unique | sort) != (.targets | unique | sort) or
       (.context.build_tasks != null and
         (all(tasks[]; (.target_triple | type == "string") and
           (.method == "act" or .method == "native") and
           (.key == .platform or (.method == "native" and
             (.target_triple | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (contains("..") | not)) and
             .key == (.platform + "@" + .target_triple)))) | not)) or
       (.context.build_tasks != null and
         (if any(tasks[]; .key != .platform)
          then (.context.native_matrix_config_sha256 // "" | test("^[0-9a-f]{64}$") | not)
          else (.context.native_matrix_config_sha256 // "") != "" end)) or
       (all((.target_statuses // {}) | keys[]; . as $t | [$s | tasks[].key] | index($t) != null) | not) or
       (.context != null and (.context | type) != "object") or
       (.context.target_hosts != null and (.context.target_hosts | type) != "object") or
       (all((.context.target_hosts // {})[]; type == "string" and length > 0) | not)
    then error("invalid or non-resumable checkpoint") else . end |
    # No further build_state_get/readlink calls: latest may now name a new run.
    (if (.context.task_host_overrides // {} | length) > 0 then [effective_task_hosts[]]
     else ((.hosts | keys) + [(.context.target_hosts // {})[]] +
       [.targets[] | select(contains("/") | not)]) end | unique |
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
    (reduce (tasks[].key) as $target (
      {completed: [], retryable: [], exceeded: []};
      ($s.target_statuses[$target] // {}) as $entry |
      if ($entry.status == "completed" and ($entry.result | type) == "object" and
          ($entry.result | length) > 0) then .completed += [$target]
      elif (($entry | counter("attempts") - counter("source_sync_failures") -
                    counter("host_readiness_failures") - counter("host_capacity_failures")) >= $retry_max)
      then .exceeded += [$target]
      else .retryable += [$target] end
    )) as $target_plan |
    # Host summaries are historical aggregate telemetry. After a task moves to
    # an already used host, historical completion and retry counts cannot
    # suppress the remaining compiler allowance of its assigned tasks.
    (if (.context.task_host_overrides // {} | length) > 0 then
      effective_task_hosts as $routes |
      def routed($keys): [$keys[] | $routes[.]] | unique;
      {
        completed: (routed($target_plan.completed) -
          routed($target_plan.retryable + $target_plan.exceeded)),
        failed: routed([tasks[].key | select($s.target_statuses[.].status == "failed")]),
        pending: routed([$target_plan.retryable[] | select($s.target_statuses[.].status != "failed")]),
        retryable: routed([$target_plan.retryable[] | select($s.target_statuses[.].status == "failed")]),
        exceeded: (routed($target_plan.exceeded) - routed($target_plan.retryable)),
        process: routed($target_plan.retryable)
      }
     else {completed: $completed, failed: $failed, pending: $pending,
           retryable: $retryable, exceeded: $exceeded, process: (($pending + $retryable) | unique)}
     end) as $host_plan |
    {
      can_resume: true,
      tool: $s.tool,
      version: $s.version,
      run_id: $s.run_id,
      current_status: $s.status,
      completed_hosts: $host_plan.completed,
      failed_hosts: $host_plan.failed,
      pending_hosts: $host_plan.pending,
      retryable_hosts: $host_plan.retryable,
      exceeded_retry_limit: $host_plan.exceeded,
      hosts_to_process: $host_plan.process,
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
export -f build_state_update_target build_state_set_context build_state_validate_repo_config
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
