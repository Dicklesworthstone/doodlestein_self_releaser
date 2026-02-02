#!/usr/bin/env bash
# logging.sh - Structured logging for dsr
#
# Provides:
#   - JSONL structured logs to file
#   - Human-readable colored output to stderr
#   - Log levels (error, warn, info, debug)
#   - Run ID correlation across all logs
#   - Duration tracking via log_timed
#   - Auto-rotation and retention
#
# Usage:
#   source logging.sh
#   log_init
#   log_info "Starting build"
#   log_timed my_command arg1 arg2
#   log_error "Build failed" '"exit_code":1'

set -uo pipefail

# Log levels (numeric for comparison)
declare -gA LOG_LEVELS=(
  [error]=0
  [warn]=1
  [info]=2
  [debug]=3
)

# Current log level (default: info)
# Can be set via DSR_LOG_LEVEL env var or -v/-q flags
LOG_LEVEL="${DSR_LOG_LEVEL:-info}"

# Log file path (set by log_init)
LOG_FILE="${DSR_LOG_FILE:-}"

# Colors (disabled if not TTY or NO_COLOR set)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
  _LOG_RED=$'\033[0;31m'
  _LOG_YELLOW=$'\033[0;33m'
  _LOG_GREEN=$'\033[0;32m'
  _LOG_BLUE=$'\033[0;34m'
  _LOG_GRAY=$'\033[0;90m'
  _LOG_NC=$'\033[0m'
else
  _LOG_RED='' _LOG_YELLOW='' _LOG_GREEN='' _LOG_BLUE='' _LOG_GRAY='' _LOG_NC=''
fi

# Generate run ID if not set
# Format: run-<epoch_seconds>-<pid>
# Optimization: Use EPOCHSECONDS builtin (Bash 5+) to avoid date subshell
: "${DSR_RUN_ID:="run-${EPOCHSECONDS:-$(date +%s)}-$$"}"

# Current command context (set by main script)
DSR_CURRENT_CMD="${DSR_CURRENT_CMD:-}"

# Optional context fields (set during execution)
DSR_CURRENT_TOOL="${DSR_CURRENT_TOOL:-}"
DSR_CURRENT_HOST="${DSR_CURRENT_HOST:-}"

# Initialize logging
# Creates log directory, sets up log file, handles rotation
log_init() {
  local state_dir="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}"
  local log_root="$state_dir/logs"
  local log_date
  log_date="$(date +%Y-%m-%d)"
  local day_dir="$log_root/$log_date"
  local builds_dir="$day_dir/builds"

  # Create date-based log directories if needed
  if ! mkdir -p "$builds_dir" 2>/dev/null; then
    echo "[logging] Warning: Cannot create log directory $builds_dir" >&2
    return 0  # Non-fatal, continue without file logging
  fi

  # Set log file if not specified
  if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="$day_dir/run.log"
  fi

  # Update logs/latest symlink atomically
  local tmp_link="$log_root/.latest.$$"
  if ln -sfn "$log_date" "$tmp_link" 2>/dev/null; then
    mv -f "$tmp_link" "$log_root/latest" 2>/dev/null || true
  fi

  # Log rotation: only run once per day (marker file prevents repeated find calls)
  # This optimization avoids expensive find operations on every command
  local rotation_marker="$log_root/.rotated-$log_date"
  if [[ ! -f "$rotation_marker" ]]; then
    # Rotate logs: compress logs older than 7 days
    find "$log_root" -type f -name '*.log' -mtime +7 ! -name '*.gz' \
      -exec gzip -q {} \; 2>/dev/null || true

    # Delete logs older than 30 days
    find "$log_root" -type f -name '*.log*' -mtime +30 -delete 2>/dev/null || true

    # Create marker to skip rotation for rest of day
    touch "$rotation_marker" 2>/dev/null || true

    # Clean up old rotation markers (keep only today's)
    find "$log_root" -maxdepth 1 -name '.rotated-*' ! -name ".rotated-$log_date" \
      -delete 2>/dev/null || true
  fi

  # Log session start
  _log info "Session started" "\"pid\":$$"
}

# Check if level should be logged
_should_log() {
  local level="$1"
  local level_num="${LOG_LEVELS[$level]:-2}"
  local current_num="${LOG_LEVELS[$LOG_LEVEL]:-2}"
  [[ "$level_num" -le "$current_num" ]]
}

# Escape string for JSON (two variants for different call patterns)
# _json_escape_var: stores result in variable named by $2 (no subshell, faster)
# _json_escape: returns on stdout (for legacy/simple cases)
_json_escape_var() {
  local _s="$1"
  local _var="$2"
  # Escape backslashes, quotes, and control characters
  _s="${_s//\\/\\\\}"
  _s="${_s//\"/\\\"}"
  _s="${_s//$'\n'/\\n}"
  _s="${_s//$'\r'/\\r}"
  _s="${_s//$'\t'/\\t}"
  printf -v "$_var" '%s' "$_s"
}

_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Core log function
# Args: level message [extra_json_fields]
_log() {
  local level="$1"
  local msg="$2"
  shift 2
  local extras="${*:-}"

  _should_log "$level" || return 0

  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Build JSON log entry with proper escaping for all fields
  # Use _json_escape_var to avoid subshell overhead (5 fewer forks per log call)
  local escaped_msg escaped_run_id escaped_cmd escaped_tool escaped_host
  _json_escape_var "$msg" escaped_msg
  _json_escape_var "$DSR_RUN_ID" escaped_run_id
  _json_escape_var "${DSR_CURRENT_CMD:-}" escaped_cmd

  local json="{"
  json+="\"ts\":\"$ts\","
  json+="\"run_id\":\"$escaped_run_id\","
  json+="\"level\":\"$level\","
  json+="\"cmd\":\"$escaped_cmd\","
  json+="\"msg\":\"$escaped_msg\""

  # Add optional context fields with escaping
  if [[ -n "${DSR_CURRENT_TOOL:-}" ]]; then
    _json_escape_var "$DSR_CURRENT_TOOL" escaped_tool
    json+=",\"tool\":\"$escaped_tool\""
  fi
  if [[ -n "${DSR_CURRENT_HOST:-}" ]]; then
    _json_escape_var "$DSR_CURRENT_HOST" escaped_host
    json+=",\"host\":\"$escaped_host\""
  fi

  # Add extra fields (must be valid JSON key-value pairs)
  [[ -n "$extras" ]] && json+=",$extras"
  json+="}"

  # Write to log file (if set)
  if [[ -n "$LOG_FILE" ]]; then
    echo "$json" >> "$LOG_FILE" 2>/dev/null || true
  fi

  # Human-readable stderr output
  local color prefix
  case "$level" in
    error) color="$_LOG_RED";    prefix="ERROR" ;;
    warn)  color="$_LOG_YELLOW"; prefix="WARN" ;;
    info)  color="$_LOG_GREEN";  prefix="INFO" ;;
    debug) color="$_LOG_GRAY";   prefix="DEBUG" ;;
    *)     color="$_LOG_NC";     prefix="$level" ;;
  esac

  echo "${color}[${prefix}]${_LOG_NC} $msg" >&2
}

# Convenience functions
log_error() { _log error "$1" "${2:-}"; }
log_warn()  { _log warn "$1" "${2:-}"; }
log_info()  { _log info "$1" "${2:-}"; }
log_debug() { _log debug "$1" "${2:-}"; }

# Log success (alias for info with success indicator)
log_ok() { _log info "$1" "${2:-}"; }

# Millisecond timestamp method (cached on first call)
# Values: "date_ms" | "python" | "date_sec"
_DSR_MS_TIMESTAMP_METHOD=""

# Get milliseconds timestamp (optimized: date +%s%3N >> python3)
# Usage: _get_ms_timestamp
# Returns: Milliseconds since epoch on stdout
_get_ms_timestamp() {
  # Cache the detection result to avoid repeated checks
  if [[ -z "$_DSR_MS_TIMESTAMP_METHOD" ]]; then
    # Check if GNU date supports %N (nanoseconds) - BSD date outputs literal "%3N"
    # We verify by checking that the output is purely numeric (no literal % chars)
    local test_output
    test_output=$(date +%s%3N 2>/dev/null)
    if [[ "$test_output" =~ ^[0-9]+$ ]]; then
      _DSR_MS_TIMESTAMP_METHOD="date_ms"
    elif command -v python3 &>/dev/null; then
      _DSR_MS_TIMESTAMP_METHOD="python"
    else
      _DSR_MS_TIMESTAMP_METHOD="date_sec"
    fi
  fi

  case "$_DSR_MS_TIMESTAMP_METHOD" in
    date_ms)  date +%s%3N ;;
    python)   python3 -c 'import time; print(int(time.time() * 1000))' ;;
    date_sec) echo "$(($(date +%s) * 1000))" ;;
  esac
}

# Log with duration tracking
# Executes command and logs completion with duration and exit code
# Usage: log_timed command arg1 arg2 ...
log_timed() {
  local start_ms
  start_ms=$(_get_ms_timestamp)

  # Run the command
  local exit_code=0
  "$@" || exit_code=$?

  local end_ms
  end_ms=$(_get_ms_timestamp)

  local duration_ms=$((end_ms - start_ms))

  if [[ $exit_code -eq 0 ]]; then
    log_info "Completed: $1" "\"duration_ms\":$duration_ms,\"exit_code\":$exit_code"
  else
    log_error "Failed: $1" "\"duration_ms\":$duration_ms,\"exit_code\":$exit_code"
  fi

  return $exit_code
}

# Set log level from verbose/quiet flags
# Usage: log_set_level_from_flags $VERBOSE $QUIET
log_set_level_from_flags() {
  local verbose="${1:-false}"
  local quiet="${2:-false}"

  if [[ "$verbose" == "true" ]]; then
    LOG_LEVEL="debug"
  elif [[ "$quiet" == "true" ]]; then
    LOG_LEVEL="error"
  fi
}

# Set current command context
log_set_command() {
  DSR_CURRENT_CMD="$1"
}

# Set current tool context
log_set_tool() {
  DSR_CURRENT_TOOL="$1"
}

# Set current host context
log_set_host() {
  DSR_CURRENT_HOST="$1"
}

# Clear context (useful when switching between tools/hosts)
log_clear_context() {
  DSR_CURRENT_TOOL=""
  DSR_CURRENT_HOST=""
}

# Get current log file path
log_get_file() {
  echo "$LOG_FILE"
}

# Get current run ID
log_get_run_id() {
  echo "$DSR_RUN_ID"
}

# Export functions and variables
export -f log_init log_error log_warn log_info log_debug log_ok log_timed
export -f log_set_level_from_flags log_set_command log_set_tool log_set_host
export -f log_clear_context log_get_file log_get_run_id
export -f _log _should_log _json_escape _json_escape_var _get_ms_timestamp
export DSR_RUN_ID LOG_LEVEL LOG_FILE _DSR_MS_TIMESTAMP_METHOD
export DSR_CURRENT_CMD DSR_CURRENT_TOOL DSR_CURRENT_HOST
