#!/usr/bin/env bash
# mock_time.bash - Deterministic time for tests
#
# Usage:
#   source mock_time.bash
#   mock_time_freeze "2026-01-30T12:00:00Z"
#   run_some_code_that_uses_date
#   mock_time_advance 60  # Advance 60 seconds
#   mock_time_restore

set -uo pipefail

# Internal state
_MOCK_TIME_ORIGINAL_DATE=""
_MOCK_TIME_FROZEN=""
_MOCK_TIME_ACTIVE=false

# Freeze time to a specific ISO8601 timestamp
# Args: timestamp (ISO8601 format, e.g., "2026-01-30T12:00:00Z")
mock_time_freeze() {
  local timestamp="${1:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
  _MOCK_TIME_FROZEN="$timestamp"
  _MOCK_TIME_ACTIVE=true

  # Store original date path if not already stored
  if [[ -z "$_MOCK_TIME_ORIGINAL_DATE" ]]; then
    _MOCK_TIME_ORIGINAL_DATE="$(command -v date)"
  fi
}

# Get the currently frozen time (or real time if not frozen)
mock_time_get() {
  if [[ "$_MOCK_TIME_ACTIVE" == true ]]; then
    echo "$_MOCK_TIME_FROZEN"
  else
    date -u +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

# Get frozen time as epoch seconds
mock_time_epoch() {
  if [[ "$_MOCK_TIME_ACTIVE" == true ]]; then
    # Parse ISO8601 to epoch - works on both Linux and macOS
    if command -v python3 &>/dev/null; then
      python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('${_MOCK_TIME_FROZEN}'.replace('Z', '+00:00')).timestamp()))"
    elif [[ "$(uname)" == "Darwin" ]]; then
      # macOS date
      "$_MOCK_TIME_ORIGINAL_DATE" -j -f "%Y-%m-%dT%H:%M:%SZ" "$_MOCK_TIME_FROZEN" +%s 2>/dev/null || \
      "$_MOCK_TIME_ORIGINAL_DATE" -j -f "%Y-%m-%dT%H:%M:%S%z" "${_MOCK_TIME_FROZEN/Z/+0000}" +%s
    else
      # GNU date
      "$_MOCK_TIME_ORIGINAL_DATE" -d "$_MOCK_TIME_FROZEN" +%s
    fi
  else
    date +%s
  fi
}

# Advance frozen time by N seconds
# Args: seconds (integer)
mock_time_advance() {
  local seconds="${1:-0}"

  if [[ "$_MOCK_TIME_ACTIVE" != true ]]; then
    echo "mock_time_advance: time is not frozen" >&2
    return 1
  fi

  local current_epoch
  current_epoch=$(mock_time_epoch)
  local new_epoch=$((current_epoch + seconds))

  # Convert back to ISO8601
  if command -v python3 &>/dev/null; then
    _MOCK_TIME_FROZEN=$(python3 -c "from datetime import datetime, timezone; print(datetime.fromtimestamp($new_epoch, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  elif [[ "$(uname)" == "Darwin" ]]; then
    _MOCK_TIME_FROZEN=$("$_MOCK_TIME_ORIGINAL_DATE" -u -r "$new_epoch" +"%Y-%m-%dT%H:%M:%SZ")
  else
    _MOCK_TIME_FROZEN=$("$_MOCK_TIME_ORIGINAL_DATE" -u -d "@$new_epoch" +"%Y-%m-%dT%H:%M:%SZ")
  fi
}

# Restore real time
mock_time_restore() {
  _MOCK_TIME_FROZEN=""
  _MOCK_TIME_ACTIVE=false
}

# Check if time is currently frozen
mock_time_is_frozen() {
  [[ "$_MOCK_TIME_ACTIVE" == true ]]
}

# Override date command (use with caution - affects subprocesses)
# This creates a wrapper function that intercepts date calls
mock_time_override_date() {
  if [[ "$_MOCK_TIME_ACTIVE" != true ]]; then
    echo "mock_time_override_date: freeze time first" >&2
    return 1
  fi

  # Create date function that uses frozen time
  date() {
    if [[ "$_MOCK_TIME_ACTIVE" == true ]]; then
      local format="${1:-}"
      case "$format" in
        +%s)
          mock_time_epoch
          ;;
        -Iseconds|+%Y-%m-%dT%H:%M:%S*)
          mock_time_get
          ;;
        -u*)
          # Pass through but replace time
          shift
          if [[ "${1:-}" == "+%Y-%m-%dT%H:%M:%SZ" || "${1:-}" == "-Iseconds" ]]; then
            mock_time_get
          else
            "$_MOCK_TIME_ORIGINAL_DATE" "$@"
          fi
          ;;
        *)
          # Pass through to real date
          "$_MOCK_TIME_ORIGINAL_DATE" "$@"
          ;;
      esac
    else
      "$_MOCK_TIME_ORIGINAL_DATE" "$@"
    fi
  }
  export -f date
}

# Restore original date command
mock_time_restore_date() {
  unset -f date 2>/dev/null || true
}

# Export functions
export -f mock_time_freeze mock_time_get mock_time_epoch mock_time_advance
export -f mock_time_restore mock_time_is_frozen
export -f mock_time_override_date mock_time_restore_date
