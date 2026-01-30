#!/usr/bin/env bash
# log_capture.bash - Capture and assert on logs
#
# Usage:
#   source log_capture.bash
#   log_capture_init "/tmp/test.log"
#   run_some_code
#   log_capture_contains "expected message" || fail "Missing message"
#   log_capture_dump  # On failure, dump all logs

set -uo pipefail

# Internal state
_LOG_CAPTURE_FILE=""
_LOG_CAPTURE_STARTED=false
_LOG_CAPTURE_STDOUT_FD=""
_LOG_CAPTURE_STDERR_FD=""

# Initialize log capture
# Args: log_file (path to capture file)
log_capture_init() {
  local log_file="${1:-}"

  if [[ -z "$log_file" ]]; then
    log_file="$(mktemp)"
  fi

  _LOG_CAPTURE_FILE="$log_file"
  _LOG_CAPTURE_STARTED=true

  # Create/clear the log file
  : > "$_LOG_CAPTURE_FILE"
}

# Start redirecting stdout/stderr to log file
# Note: This captures ALL output, use with caution
log_capture_start_redirect() {
  if [[ "$_LOG_CAPTURE_STARTED" != true ]]; then
    echo "log_capture_start_redirect: init first" >&2
    return 1
  fi

  # Save original file descriptors
  exec {_LOG_CAPTURE_STDOUT_FD}>&1
  exec {_LOG_CAPTURE_STDERR_FD}>&2

  # Redirect to log file via tee (preserves output)
  exec > >(tee -a "$_LOG_CAPTURE_FILE") 2>&1
}

# Stop redirecting output
log_capture_stop_redirect() {
  if [[ -n "$_LOG_CAPTURE_STDOUT_FD" ]]; then
    exec 1>&"$_LOG_CAPTURE_STDOUT_FD" 2>&"$_LOG_CAPTURE_STDERR_FD"
    exec {_LOG_CAPTURE_STDOUT_FD}>&-
    exec {_LOG_CAPTURE_STDERR_FD}>&-
    _LOG_CAPTURE_STDOUT_FD=""
    _LOG_CAPTURE_STDERR_FD=""
  fi
}

# Write to the capture log directly
# Args: message
log_capture_write() {
  if [[ "$_LOG_CAPTURE_STARTED" == true && -n "$_LOG_CAPTURE_FILE" ]]; then
    echo "$*" >> "$_LOG_CAPTURE_FILE"
  fi
}

# Check if log contains a pattern
# Args: pattern (grep regex)
log_capture_contains() {
  local pattern="$1"

  if [[ ! -f "$_LOG_CAPTURE_FILE" ]]; then
    return 1
  fi

  grep -q "$pattern" "$_LOG_CAPTURE_FILE"
}

# Check if log contains exact string
# Args: string
log_capture_contains_exact() {
  local string="$1"

  if [[ ! -f "$_LOG_CAPTURE_FILE" ]]; then
    return 1
  fi

  grep -qF "$string" "$_LOG_CAPTURE_FILE"
}

# Count matches of a pattern
# Args: pattern (grep regex)
log_capture_count() {
  local pattern="$1"

  if [[ ! -f "$_LOG_CAPTURE_FILE" ]]; then
    echo "0"
    return
  fi

  grep -c "$pattern" "$_LOG_CAPTURE_FILE" 2>/dev/null || echo "0"
}

# Get line count of log
log_capture_line_count() {
  if [[ ! -f "$_LOG_CAPTURE_FILE" ]]; then
    echo "0"
    return
  fi

  wc -l < "$_LOG_CAPTURE_FILE" | tr -d ' '
}

# Get specific line from log
# Args: line_number (1-indexed)
log_capture_line() {
  local line_num="$1"

  if [[ ! -f "$_LOG_CAPTURE_FILE" ]]; then
    return 1
  fi

  sed -n "${line_num}p" "$_LOG_CAPTURE_FILE"
}

# Get last N lines
# Args: count (default 10)
log_capture_tail() {
  local count="${1:-10}"

  if [[ ! -f "$_LOG_CAPTURE_FILE" ]]; then
    return 1
  fi

  tail -n "$count" "$_LOG_CAPTURE_FILE"
}

# Get first N lines
# Args: count (default 10)
log_capture_head() {
  local count="${1:-10}"

  if [[ ! -f "$_LOG_CAPTURE_FILE" ]]; then
    return 1
  fi

  head -n "$count" "$_LOG_CAPTURE_FILE"
}

# Dump full log contents to stderr
log_capture_dump() {
  if [[ ! -f "$_LOG_CAPTURE_FILE" ]]; then
    echo "[log_capture] No log file" >&2
    return
  fi

  local line_count
  line_count=$(log_capture_line_count)

  echo "=== Log Dump ($_LOG_CAPTURE_FILE, $line_count lines) ===" >&2
  cat "$_LOG_CAPTURE_FILE" >&2
  echo "=== End Log Dump ===" >&2
}

# Get log file path
log_capture_file() {
  echo "$_LOG_CAPTURE_FILE"
}

# Clear log contents
log_capture_clear() {
  if [[ -f "$_LOG_CAPTURE_FILE" ]]; then
    : > "$_LOG_CAPTURE_FILE"
  fi
}

# Cleanup and restore
log_capture_cleanup() {
  log_capture_stop_redirect

  if [[ -f "$_LOG_CAPTURE_FILE" && -z "${DEBUG:-}" ]]; then
    rm -f "$_LOG_CAPTURE_FILE"
  fi

  _LOG_CAPTURE_FILE=""
  _LOG_CAPTURE_STARTED=false
}

# Assert helpers (for use with test frameworks)

# Assert log contains pattern, fail with message if not
# Args: pattern message
assert_log_contains() {
  local pattern="$1"
  local message="${2:-Log should contain: $pattern}"

  if ! log_capture_contains "$pattern"; then
    echo "FAIL: $message" >&2
    log_capture_dump
    return 1
  fi
}

# Assert log does NOT contain pattern
# Args: pattern message
assert_log_not_contains() {
  local pattern="$1"
  local message="${2:-Log should not contain: $pattern}"

  if log_capture_contains "$pattern"; then
    echo "FAIL: $message" >&2
    log_capture_dump
    return 1
  fi
}

# Export functions
export -f log_capture_init log_capture_start_redirect log_capture_stop_redirect
export -f log_capture_write log_capture_contains log_capture_contains_exact
export -f log_capture_count log_capture_line_count log_capture_line
export -f log_capture_tail log_capture_head log_capture_dump
export -f log_capture_file log_capture_clear log_capture_cleanup
export -f assert_log_contains assert_log_not_contains
