#!/usr/bin/env bash
# guardrails.sh - Runtime safety guardrails for dsr
#
# Provides:
#   - Bash version gate (4.0+ required)
#   - Absolute path enforcement with tilde expansion
#   - Safe deletion helpers (allowlisted directories)
#   - Safe temp directory creation
#   - NO_COLOR support
#   - Owned command deadlines, including hosts without GNU timeout
#
# Usage:
#   source guardrails.sh
#   require_bash_4
#   path=$(resolve_path "$user_input")
#   safe_rm "$path"
#   tmpdir=$(safe_tmpdir "dsr-build")
#   run_with_timeout 30 command arg...

set -uo pipefail

# Exit codes (from AGENTS.md) - only declare if not already set
if [[ -z "${EXIT_SUCCESS:-}" ]]; then
    readonly EXIT_SUCCESS=0
    readonly EXIT_DEPENDENCY_ERROR=3
    readonly EXIT_INVALID_ARGS=4
fi

# Minimum required Bash version - only declare if not already set
if [[ -z "${MIN_BASH_MAJOR:-}" ]]; then
    readonly MIN_BASH_MAJOR=4
    readonly MIN_BASH_MINOR=0
fi

# Safe deletion allowlist (directories under which deletion is permitted)
if ! declare -p _SAFE_DELETE_ROOTS >/dev/null 2>&1; then
    _SAFE_DELETE_ROOTS=()
fi

# Initialize safe delete roots from XDG directories
_guardrails_init_safe_roots() {
  local state_dir="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}"
  local cache_dir="${DSR_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/dsr}"

  _SAFE_DELETE_ROOTS=(
    "$state_dir"
    "$cache_dir"
    "/tmp"
  )
}

# ============================================================================
# Bash Version Gate
# ============================================================================

# Check Bash version is 4.0+
# Usage: require_bash_4
# Exits with code 3 (DEPENDENCY_ERROR) if Bash is too old
require_bash_4() {
  local major="${BASH_VERSINFO[0]:-0}"
  local minor="${BASH_VERSINFO[1]:-0}"

  if [[ "$major" -lt $MIN_BASH_MAJOR ]] || \
     [[ "$major" -eq $MIN_BASH_MAJOR && "$minor" -lt $MIN_BASH_MINOR ]]; then
    cat >&2 << EOF
Error: dsr requires Bash ${MIN_BASH_MAJOR}.${MIN_BASH_MINOR} or later.
Current version: ${BASH_VERSION:-unknown}

To fix on macOS:
  1. Install newer Bash: brew install bash
  2. Add to shells: sudo bash -c 'echo /opt/homebrew/bin/bash >> /etc/shells'
  3. Change shell: chsh -s /opt/homebrew/bin/bash
  Or run dsr with: /opt/homebrew/bin/bash -c 'dsr ...'

To fix on Linux (Debian/Ubuntu):
  sudo apt update && sudo apt install bash

To fix on Linux (RHEL/Fedora):
  sudo dnf install bash
EOF
    return $EXIT_DEPENDENCY_ERROR
  fi
  return $EXIT_SUCCESS
}

# ============================================================================
# Owned Command Deadlines
# ============================================================================

_dsr_timeout_cmd() {
    if command -v timeout >/dev/null 2>&1; then
        printf '%s\n' timeout
    elif command -v gtimeout >/dev/null 2>&1; then
        printf '%s\n' gtimeout
    fi
    return 0
}

# The timer reports deadlines over its private pipe, never to a reusable PID.
# The live group anchor owns every termination signal, including cleanup of
# this timer and its sleeps. Its stdin is separate from the command's input.
_dsr_timeout_watchdog() {
    local seconds="$1" control=""
    trap '' INT TERM HUP PIPE
    printf 'ready\n' || return 4
    IFS= read -r control && [[ "$control" == start ]] || return 4
    if command sleep "$seconds"; then
        printf 'deadline\n' || return 4
        if command sleep 5; then
            printf 'force\n' || return 4
        else
            printf 'error\n' || return 4
        fi
    else
        printf 'error\n' || return 4
    fi
    # Keep the writer alive until the anchor retires the group: Bash closes
    # the result descriptor when a coprocess finishes.
    IFS= read -r control || true
}

# A GNU timeout leader can exit before a resistant descendant, abandoning its
# kill-after timer. Keep timeout --foreground and all ordinary descendants in
# the group of this live anchor. The portable engine uses that same ownership.
_dsr_timeout_group() {
    local input_fd="$1" output_fd="$2" timeout_command="$3" seconds="$4"
    shift 4
    [[ "$input_fd" =~ ^[0-9]+$ && "$output_fd" =~ ^[0-9]+$ ]] || return 4
    local group_pid="$BASHPID" child="" finished=false cancelled=false
    local control="" running="" status=0 read_status=0
    local watchdog_read="" watchdog_write="" watchdog_pid="" watchdog_message="" expired=false
    local -a _DSR_TIMEOUT_WATCHDOG=()
    local _DSR_TIMEOUT_WATCHDOG_PID=""
    set +m
    trap - EXIT
    trap 'cancelled=true' INT TERM HUP PIPE
    if ! IFS= read -r control || [[ "$control" != start ]] || $cancelled; then
        return 130
    fi
    if [[ -z "$timeout_command" ]]; then
        coproc _DSR_TIMEOUT_WATCHDOG {
            eval "exec ${input_fd}<&- ${output_fd}>&-"
            _dsr_timeout_watchdog "$seconds"
        }
        watchdog_read="${_DSR_TIMEOUT_WATCHDOG[0]:-}"
        watchdog_write="${_DSR_TIMEOUT_WATCHDOG[1]:-}"
        watchdog_pid="${_DSR_TIMEOUT_WATCHDOG_PID:-}"
        if [[ ! "$watchdog_read" =~ ^[0-9]+$ || ! "$watchdog_write" =~ ^[0-9]+$ ||
              ! "$watchdog_pid" =~ ^[1-9][0-9]*$ ]] ||
           ! IFS= read -r -u "$watchdog_read" watchdog_message ||
           [[ "$watchdog_message" != ready ]] || $cancelled; then
            trap '' INT TERM HUP PIPE
            kill -KILL -- "-$group_pid" 2>/dev/null || true
            return 4
        fi
    fi
    (
        eval "exec ${input_fd}<&- ${output_fd}>&-"
        if [[ -n "$timeout_command" ]]; then
            exec "$timeout_command" --foreground --kill-after=5 "$seconds" "$@"
        else
            # External commands replace this PID so an intermediate shell
            # cannot hide a still-running, TERM-resistant command leader.
            case "$(type -t -- "$1")" in
                function|builtin) "$@" ;;
                *) exec "$@" ;;
            esac
        fi
    ) <&"$input_fd" >&"$output_fd" &
    child=$!
    eval "exec ${input_fd}<&- ${output_fd}>&-"
    if [[ -n "$watchdog_write" ]] && ! printf 'start\n' >&"$watchdog_write"; then
        cancelled=true
    fi
    while ! $cancelled; do
        if ! $finished; then
            running=$(jobs -pr)
            case $'\n'"$running"$'\n' in
                *$'\n'"$child"$'\n'*) ;;
                *)
                    wait "$child" || status=$?
                    $expired && status=124
                    finished=true
                    printf 'exit:%s\n' "$status" || break
                    ;;
            esac
        fi
        if ! $finished && [[ -n "$watchdog_read" ]]; then
            watchdog_message=""
            case $'\n'"$running"$'\n' in
                *$'\n'"$watchdog_pid"$'\n'*)
                    if IFS= read -r -t 0 -u "$watchdog_read"; then
                        IFS= read -r -u "$watchdog_read" watchdog_message || watchdog_message=error
                    fi
                    ;;
                *) watchdog_message=error ;;
            esac
            case "$watchdog_message" in
                '') ;;
                deadline)
                    expired=true
                    trap '' INT TERM HUP PIPE
                    kill -TERM -- "-$group_pid" 2>/dev/null || true
                    ;;
                *)
                    if [[ "$watchdog_message" == force ]]; then
                        status=137
                    else
                        printf '%s\n' '[dsr] Portable timeout watchdog could not maintain its deadline' >&2
                        status=125
                    fi
                    finished=true
                    printf 'exit:%s\n' "$status" || true
                    break
                    ;;
            esac
        fi
        read_status=0
        IFS= read -r -t 0.1 control || read_status=$?
        # EOF also drains the group after the waiting shell is killed or lost.
        if (( read_status == 0 || read_status == 1 )); then
            break
        fi
        (( read_status > 128 )) || break
    done
    trap '' INT TERM HUP PIPE
    kill -TERM -- "-$group_pid" 2>/dev/null || true
    if ! $finished; then
        # Finish within the outer worker's cancellation grace.
        command sleep 2
    fi
    # The anchor is still the live leader; its process-group ID cannot be reused.
    kill -KILL -- "-$group_pid" 2>/dev/null || true
    return 4
}

# Private entry point lets existing callers retain their timer-selection hook.
# Resolve it INSIDE the waiting subshell so the parent-lifetime channel always
# belongs to the process that selected the engine and actually waits for it.
_dsr_run_with_timeout() (
    [[ $# -ge 3 ]] || return 4
    local selector="$1" seconds="$2" cmd
    shift 2
    if [[ ! "$seconds" =~ ^[0-9]+([.][0-9]+)?$ || -z "${seconds//[0.]/}" ]]; then
        printf '[dsr] Timeout requires a positive duration in seconds: %s\n' "$seconds" >&2
        return 4
    fi
    cmd=$("$selector") || return 3
    # GNU timeout cannot execute an unexported shell function or builtin.
    # The forked portable engine retains their real definitions and environment.
    case "$(type -t -- "$1")" in function|builtin) cmd="" ;; esac
    if [[ -z "$cmd" ]] &&
       { ! command -v sleep >/dev/null 2>&1 || ! type -P sleep >/dev/null 2>&1; }; then
        printf '%s\n' '[dsr] sleep is required to supervise commands without timeout or gtimeout' >&2
        return 3
    fi

    # Reserve unused descriptors for real streams. Coprocess fd0/fd1 carry
    # control/status only. Numeric eval redirections retain Bash 4.0 support.
    local input_fd="" output_fd="" candidate_fd
    for ((candidate_fd = 10; candidate_fd < 63; candidate_fd++)); do
        if { : <&"$candidate_fd"; } 2>/dev/null; then
            continue
        fi
        if [[ -z "$input_fd" ]]; then
            eval "exec ${candidate_fd}<&0" || return 4
            input_fd=$candidate_fd
        else
            eval "exec ${candidate_fd}>&1" || return 4
            output_fd=$candidate_fd
            break
        fi
    done
    [[ -n "$input_fd" && -n "$output_fd" ]] || return 4

    local timeout_pid="" result_fd="" control_fd="" guard_status=0
    local cancel_status=0 launch_pending=false monitor=false
    local message="" result=4 protocol_valid=false
    local -a _DSR_TIMEOUT_GROUP=()
    local _DSR_TIMEOUT_GROUP_PID=""
    _dsr_timeout_drain() {
        if [[ "$control_fd" =~ ^[0-9]+$ ]]; then
            eval "exec ${control_fd}>&-"
            control_fd=""
        fi
        if [[ "$timeout_pid" =~ ^[1-9][0-9]*$ ]]; then
            guard_status=0
            wait "$timeout_pid" 2>/dev/null || guard_status=$?
            timeout_pid=""
        fi
        if [[ "$result_fd" =~ ^[0-9]+$ ]]; then
            eval "exec ${result_fd}<&-"
            result_fd=""
        fi
    }
    _dsr_timeout_cancel() {
        (( cancel_status != 0 )) || cancel_status=$1
        $launch_pending && return 0
        trap '' INT TERM HUP PIPE
        _dsr_timeout_drain
        exit "$cancel_status"
    }
    trap '_dsr_timeout_cancel 130' INT
    trap '_dsr_timeout_cancel 143' TERM
    trap '_dsr_timeout_cancel 129' HUP
    trap '_dsr_timeout_cancel 141' PIPE
    [[ $- != *m* ]] || monitor=true
    set -m
    launch_pending=true
    coproc _DSR_TIMEOUT_GROUP {
        _dsr_timeout_group "$input_fd" "$output_fd" "$cmd" "$seconds" "$@"
    }
    timeout_pid="${_DSR_TIMEOUT_GROUP_PID:-}"
    result_fd="${_DSR_TIMEOUT_GROUP[0]:-}"
    control_fd="${_DSR_TIMEOUT_GROUP[1]:-}"
    launch_pending=false
    $monitor || set +m
    eval "exec ${input_fd}<&- ${output_fd}>&-"
    if (( cancel_status != 0 )); then
        _dsr_timeout_cancel "$cancel_status"
    fi
    if [[ "$control_fd" =~ ^[0-9]+$ && "$result_fd" =~ ^[0-9]+$ ]] &&
       printf 'start\n' >&"$control_fd" &&
       IFS= read -r -u "$result_fd" message &&
       [[ "$message" =~ ^exit:([0-9]{1,3})$ ]] &&
       (( 10#${BASH_REMATCH[1]} <= 255 )); then
        result=$((10#${BASH_REMATCH[1]}))
        protocol_valid=true
    fi
    _dsr_timeout_drain
    if ! $protocol_valid; then
        result=$guard_status
        [[ "$result" -ne 0 ]] || result=4
    fi
    return "$result"
)

# Usage: run_with_timeout <positive-seconds> <command> [args...]
# Completion retains command status; deadline exits are 124 or escalated 137.
# Missing dependencies/invalid bounds refuse before launching the command.
run_with_timeout() {
    _dsr_run_with_timeout _dsr_timeout_cmd "$@"
}

# ============================================================================
# Path Resolution
# ============================================================================

# Normalize a path without relying on realpath (resolves ., .., and //)
# Usage: _normalize_path <path>
_normalize_path() {
  local path="$1"
  local is_abs=false
  [[ "$path" == /* ]] && is_abs=true

  local IFS='/'
  local -a parts=()
  read -r -a parts <<< "$path"

  local -a stack=()
  local part
  for part in "${parts[@]}"; do
    case "$part" in
      ""|".")
        continue
        ;;
      "..")
        if [[ ${#stack[@]} -gt 0 ]]; then
          unset 'stack[${#stack[@]}-1]'
        elif ! $is_abs; then
          stack+=("..")
        fi
        ;;
      *)
        stack+=("$part")
        ;;
    esac
  done

  local normalized=""
  if $is_abs; then
    normalized="/"
  fi
  if [[ ${#stack[@]} -gt 0 ]]; then
    local joined
    joined=$(IFS=/; printf '%s' "${stack[*]}")
    normalized+="$joined"
  fi

  [[ -z "$normalized" ]] && normalized="/"
  printf '%s' "$normalized"
}

# Resolve a path to absolute, expanding ~ and validating
# Usage: resolve_path <path> [--must-exist]
# Returns: Absolute path on stdout
# Exits with code 4 (INVALID_ARGS) if path is invalid
resolve_path() {
  local input="${1:-}"
  local must_exist=false
  [[ "${2:-}" == "--must-exist" ]] && must_exist=true

  if [[ -z "$input" ]]; then
    echo "Error: Empty path provided" >&2
    return $EXIT_INVALID_ARGS
  fi

  local resolved=""

  # Expand ~ to HOME
  # shellcheck disable=SC2088  # Intentional pattern match, not expansion
  if [[ "$input" == "~" ]]; then
    resolved="$HOME"
  elif [[ "$input" == "~/"* ]]; then
    resolved="$HOME/${input:2}"
  elif [[ "$input" == "~"* ]]; then
    # ~username expansion (sanitized to avoid eval injection)
    if [[ "$input" =~ ^~([a-zA-Z0-9._-]+)(/.*)?$ ]]; then
      local user="${BASH_REMATCH[1]}"
      local rest="${BASH_REMATCH[2]}"
      local user_home=""

      if command -v getent &>/dev/null; then
        user_home=$(getent passwd "$user" | awk -F: '{print $6}' | head -1)
      fi

      if [[ -z "$user_home" ]]; then
        user_home=$(eval echo "~$user" 2>/dev/null || true)
      fi

      if [[ -z "$user_home" || "$user_home" == "~"* ]]; then
        echo "Error: Cannot expand path: $input" >&2
        return $EXIT_INVALID_ARGS
      fi

      resolved="$user_home${rest:-}"
    else
      echo "Error: Cannot expand path: $input" >&2
      return $EXIT_INVALID_ARGS
    fi
  elif [[ "$input" == /* ]]; then
    # Already absolute
    resolved="$input"
  else
    # Relative path - reject with helpful error
    echo "Error: Relative path not allowed: $input" >&2
    echo "Please use an absolute path (starting with / or ~)" >&2
    return $EXIT_INVALID_ARGS
  fi

  # Normalize path (remove . and ..)
  # Use realpath if available, otherwise manual normalization
  if command -v realpath &>/dev/null; then
    if $must_exist; then
      resolved=$(realpath "$resolved" 2>/dev/null) || {
        echo "Error: Path does not exist: $resolved" >&2
        return $EXIT_INVALID_ARGS
      }
    else
      local original_resolved="$resolved"
      local normalized_resolved=""
      if normalized_resolved=$(realpath -m "$original_resolved" 2>/dev/null) && \
         [[ -n "$normalized_resolved" ]]; then
        resolved="$normalized_resolved"
      else
        resolved=$(_normalize_path "$original_resolved")
      fi
    fi
  else
    # Manual normalization for systems without realpath
    resolved=$(_normalize_path "$resolved")

    if $must_exist && [[ ! -e "$resolved" ]]; then
      echo "Error: Path does not exist: $resolved" >&2
      return $EXIT_INVALID_ARGS
    fi
  fi

  echo "$resolved"
}

# Resolve path or return default if empty
# Usage: resolve_path_or_default <path> <default>
resolve_path_or_default() {
  local input="${1:-}"
  local default="$2"

  if [[ -z "$input" ]]; then
    resolve_path "$default"
  else
    resolve_path "$input"
  fi
}

# ============================================================================
# Safe Deletion
# ============================================================================

# Check if a path is under an allowed root
# Usage: _is_safe_path <path>
# Returns: 0 if safe, 1 if not
_is_safe_path() {
  local path="$1"

  # Initialize safe roots if not done
  [[ ${#_SAFE_DELETE_ROOTS[@]} -eq 0 ]] && _guardrails_init_safe_roots

  # Resolve to absolute path
  local abs_path
  abs_path=$(resolve_path "$path" 2>/dev/null) || return 1

  # Check against each safe root
  for root in "${_SAFE_DELETE_ROOTS[@]}"; do
    local abs_root
    abs_root=$(resolve_path "$root" 2>/dev/null) || continue

    # Check if path is under root (with trailing slash to prevent prefix attacks)
    if [[ "$abs_path" == "$abs_root" || "$abs_path" == "$abs_root/"* ]]; then
      return 0
    fi
  done

  return 1
}

# Safely remove a file or directory (only if under allowed roots)
# Usage: safe_rm <path> [--force]
# Returns: 0 on success, 4 on invalid path
safe_rm() {
  local path="$1"
  local force=false
  [[ "${2:-}" == "--force" ]] && force=true

  if [[ -z "$path" ]]; then
    echo "Error: safe_rm requires a path argument" >&2
    return $EXIT_INVALID_ARGS
  fi

  # Check if path is under a safe root
  if ! _is_safe_path "$path"; then
    echo "Error: Refusing to delete path outside allowed directories: $path" >&2
    echo "Allowed roots: ${_SAFE_DELETE_ROOTS[*]}" >&2
    return $EXIT_INVALID_ARGS
  fi

  # Additional safety: never delete root directories themselves
  local abs_path
  abs_path=$(resolve_path "$path" 2>/dev/null) || return $EXIT_INVALID_ARGS

  for root in "${_SAFE_DELETE_ROOTS[@]}"; do
    local abs_root
    abs_root=$(resolve_path "$root" 2>/dev/null) || continue
    if [[ "$abs_path" == "$abs_root" ]]; then
      echo "Error: Refusing to delete root directory: $abs_path" >&2
      return $EXIT_INVALID_ARGS
    fi
  done

  # Path is safe, delete it
  if [[ -d "$path" ]]; then
    if $force; then
      rm -rf "$path"
    else
      rm -r "$path"
    fi
  elif [[ -f "$path" || -L "$path" ]]; then
    rm -f "$path"
  elif [[ ! -e "$path" ]]; then
    # Already doesn't exist, success
    return $EXIT_SUCCESS
  fi
}

# Add a directory to the safe deletion allowlist
# Usage: safe_rm_allow <path>
safe_rm_allow() {
  local path="$1"

  [[ ${#_SAFE_DELETE_ROOTS[@]} -eq 0 ]] && _guardrails_init_safe_roots

  local abs_path
  abs_path=$(resolve_path "$path" 2>/dev/null) || return $EXIT_INVALID_ARGS

  _SAFE_DELETE_ROOTS+=("$abs_path")
}

# ============================================================================
# Safe Temp Directory
# ============================================================================

# Create a temporary directory under /tmp
# Usage: safe_tmpdir [prefix]
# Returns: Path to created directory on stdout
safe_tmpdir() {
  local prefix="${1:-dsr}"

  local tmpdir
  tmpdir=$(mktemp -d "/tmp/${prefix}.XXXXXX" 2>/dev/null) || {
    echo "Error: Failed to create temporary directory" >&2
    return $EXIT_DEPENDENCY_ERROR
  }

  echo "$tmpdir"
}

# ============================================================================
# NO_COLOR Support
# ============================================================================

# Check if colors should be disabled
# Returns: 0 if colors disabled, 1 if colors enabled
is_color_disabled() {
  # NO_COLOR takes precedence (https://no-color.org/)
  [[ -n "${NO_COLOR:-}" ]] && return 0

  # --no-color flag (checked via global)
  [[ "${DSR_NO_COLOR:-}" == "true" ]] && return 0

  # Not a TTY
  [[ ! -t 2 ]] && return 0

  return 1
}

# Get color code if colors are enabled, empty string otherwise
# Usage: color <color_name>
# Color names: red, green, yellow, blue, gray, reset
color() {
  local name="$1"

  if is_color_disabled; then
    printf ''
    return
  fi

  case "$name" in
    red)    printf '\033[0;31m' ;;
    green)  printf '\033[0;32m' ;;
    yellow) printf '\033[0;33m' ;;
    blue)   printf '\033[0;34m' ;;
    gray)   printf '\033[0;90m' ;;
    reset)  printf '\033[0m' ;;
    *)      printf '' ;;
  esac
}

# ============================================================================
# Non-Interactive Mode
# ============================================================================

# Check if running in non-interactive mode
# Returns: 0 if non-interactive, 1 if interactive
is_non_interactive() {
  # CI environments
  [[ -n "${CI:-}" ]] && return 0

  # Explicit flag
  [[ "${DSR_NON_INTERACTIVE:-}" == "true" ]] && return 0

  # No TTY on stdin
  [[ ! -t 0 ]] && return 0

  return 1
}

# Prompt for confirmation (non-interactive mode returns provided default)
# Usage: confirm <prompt> [default: y|n]
# Returns: 0 for yes, 1 for no
confirm() {
  local prompt="$1"
  local default="${2:-n}"

  if is_non_interactive; then
    [[ "$default" == "y" || "$default" == "Y" ]] && return 0
    return 1
  fi

  local yn_hint="[y/N]"
  [[ "$default" == "y" || "$default" == "Y" ]] && yn_hint="[Y/n]"

  local answer
  read -r -p "$prompt $yn_hint " answer

  case "${answer:-$default}" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# ============================================================================
# Exports
# ============================================================================

# Direct native and pinned-xwin backends do not establish RCH admission.
# Keep their policy parsing and refusal identical until the real backend exists.
dsr_native_rch_policy() {
    local platform="$1" remote_policy="${2:-}" response_kind="${3:-}"
    remote_policy="${remote_policy#"${remote_policy%%[![:space:]]*}"}"
    remote_policy="${remote_policy%"${remote_policy##*[![:space:]]}"}"
    case "${remote_policy,,}" in
        ""|0|false|no|off|disabled) return 0 ;;
        1|true|yes|on|enabled)
            printf '%s\n' '[dsr-policy] RCH-required native execution is unavailable; refusing direct native compilation' >&2
            jq -nc --arg platform "$platform" --arg kind "$response_kind" \
                '{status: "error", exit_code: 4, platform: $platform,
                  reason_code: "RCH_REQUIRED_NATIVE_UNAVAILABLE",
                  error: "RCH-required native execution is unavailable; no build dispatched"} |
                 if $kind == "" then . else . + {kind: $kind, publishable: false} end'
            return 4
            ;;
        *)
            printf '%s\n' '[dsr-policy] RCH_REQUIRE_REMOTE must select an explicit enabled or disabled policy' >&2
            jq -nc --arg platform "$platform" --arg kind "$response_kind" \
                '{status: "error", exit_code: 4, platform: $platform,
                  reason_code: "INVALID_RCH_REQUIRE_REMOTE",
                  error: "RCH_REQUIRE_REMOTE must select an explicit enabled or disabled policy"} |
                 if $kind == "" then . else . + {kind: $kind, publishable: false} end'
            return 4
            ;;
    esac
}

dsr_native_rch_environment_policy() {
    local platform="$1" build_env="$2" policy_assignment
    # A later disabled assignment cannot obscure an earlier RCH requirement.
    while IFS= read -r policy_assignment; do
        case "$policy_assignment" in
            RCH_REQUIRE_REMOTE=*)
                dsr_native_rch_policy "$platform" "${policy_assignment#*=}" || return 4
                ;;
        esac
    done <<< "$build_env"
    return 0
}

export -f require_bash_4
export -f resolve_path resolve_path_or_default
export -f safe_rm safe_rm_allow _is_safe_path
export -f safe_tmpdir
export -f is_color_disabled color
export -f is_non_interactive confirm
export -f dsr_native_rch_policy dsr_native_rch_environment_policy
export -f run_with_timeout _dsr_timeout_cmd _dsr_run_with_timeout
export -f _dsr_timeout_group _dsr_timeout_watchdog

export EXIT_SUCCESS EXIT_DEPENDENCY_ERROR EXIT_INVALID_ARGS
