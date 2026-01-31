#!/usr/bin/env bash
# guardrails.sh - Runtime safety guardrails for dsr
#
# Provides:
#   - Bash version gate (4.0+ required)
#   - Absolute path enforcement with tilde expansion
#   - Safe deletion helpers (allowlisted directories)
#   - Safe temp directory creation
#   - NO_COLOR support
#
# Usage:
#   source guardrails.sh
#   require_bash_4
#   path=$(resolve_path "$user_input")
#   safe_rm "$path"
#   tmpdir=$(safe_tmpdir "dsr-build")

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
_SAFE_DELETE_ROOTS=()

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
# Path Resolution
# ============================================================================

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
    # ~username expansion (let shell handle it)
    resolved=$(eval echo "$input" 2>/dev/null) || {
      echo "Error: Cannot expand path: $input" >&2
      return $EXIT_INVALID_ARGS
    }
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
      resolved=$(realpath -m "$resolved" 2>/dev/null) || resolved="$resolved"
    fi
  else
    # Manual normalization for systems without realpath
    # Remove trailing slashes and double slashes
    resolved="${resolved%/}"
    resolved=$(echo "$resolved" | sed 's#//*#/#g')

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
    echo -n ""
    return
  fi

  case "$name" in
    red)    echo -n $'\033[0;31m' ;;
    green)  echo -n $'\033[0;32m' ;;
    yellow) echo -n $'\033[0;33m' ;;
    blue)   echo -n $'\033[0;34m' ;;
    gray)   echo -n $'\033[0;90m' ;;
    reset)  echo -n $'\033[0m' ;;
    *)      echo -n "" ;;
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

export -f require_bash_4
export -f resolve_path resolve_path_or_default
export -f safe_rm safe_rm_allow _is_safe_path
export -f safe_tmpdir
export -f is_color_disabled color
export -f is_non_interactive confirm

export EXIT_SUCCESS EXIT_DEPENDENCY_ERROR EXIT_INVALID_ARGS
