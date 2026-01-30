#!/usr/bin/env bash
# mock_common.bash - Shared mock infrastructure
#
# Provides common utilities for creating and managing mocks
# in test environments.

set -uo pipefail

# Internal state
_MOCK_BIN_DIR=""
_MOCK_ORIGINAL_PATH=""
_MOCK_COMMANDS=()

# Initialize mock environment
# Creates a directory for mock scripts and prepends to PATH
mock_init() {
  if [[ -n "$_MOCK_BIN_DIR" ]]; then
    return 0  # Already initialized
  fi

  _MOCK_BIN_DIR="$(mktemp -d)"
  _MOCK_ORIGINAL_PATH="$PATH"
  export PATH="$_MOCK_BIN_DIR:$PATH"
}

# Create a mock command that returns fixed output
# Args: command_name output [exit_code]
mock_command() {
  local cmd="$1"
  local output="$2"
  local exit_code="${3:-0}"

  mock_init

  # Create mock script
  cat > "$_MOCK_BIN_DIR/$cmd" << EOF
#!/usr/bin/env bash
echo '$output'
exit $exit_code
EOF
  chmod +x "$_MOCK_BIN_DIR/$cmd"

  _MOCK_COMMANDS+=("$cmd")
}

# Create a mock command that runs a custom script
# Args: command_name script_content
mock_command_script() {
  local cmd="$1"
  local script="$2"

  mock_init

  cat > "$_MOCK_BIN_DIR/$cmd" << EOF
#!/usr/bin/env bash
$script
EOF
  chmod +x "$_MOCK_BIN_DIR/$cmd"

  _MOCK_COMMANDS+=("$cmd")
}

# Create a mock command that logs calls and returns output
# Args: command_name output [exit_code]
mock_command_logged() {
  local cmd="$1"
  local output="$2"
  local exit_code="${3:-0}"

  # Must init first so _MOCK_BIN_DIR is set
  mock_init

  local log_file="${_MOCK_BIN_DIR}/${cmd}.calls"

  cat > "$_MOCK_BIN_DIR/$cmd" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$log_file"
echo '$output'
exit $exit_code
EOF
  chmod +x "$_MOCK_BIN_DIR/$cmd"

  _MOCK_COMMANDS+=("$cmd")
}

# Get call log for a mock command
# Args: command_name
mock_get_calls() {
  local cmd="$1"
  local log_file="${_MOCK_BIN_DIR}/${cmd}.calls"

  if [[ -f "$log_file" ]]; then
    cat "$log_file"
  fi
}

# Get call count for a mock command
# Args: command_name
mock_call_count() {
  local cmd="$1"
  local log_file="${_MOCK_BIN_DIR}/${cmd}.calls"

  if [[ -f "$log_file" ]]; then
    wc -l < "$log_file" | tr -d ' '
  else
    echo "0"
  fi
}

# Check if mock command was called with specific args
# Args: command_name expected_args
mock_called_with() {
  local cmd="$1"
  local expected="$2"
  local log_file="${_MOCK_BIN_DIR}/${cmd}.calls"

  if [[ -f "$log_file" ]]; then
    # Use -- to prevent grep from interpreting $expected as options
    grep -qF -- "$expected" "$log_file"
  else
    return 1
  fi
}

# Remove a mock command
# Args: command_name
mock_remove() {
  local cmd="$1"

  if [[ -f "$_MOCK_BIN_DIR/$cmd" ]]; then
    rm -f "$_MOCK_BIN_DIR/$cmd"
    rm -f "$_MOCK_BIN_DIR/${cmd}.calls"
  fi

  # Remove from tracked list
  local new_commands=()
  for c in "${_MOCK_COMMANDS[@]}"; do
    if [[ "$c" != "$cmd" ]]; then
      new_commands+=("$c")
    fi
  done
  _MOCK_COMMANDS=("${new_commands[@]}")
}

# List all active mocks
mock_list() {
  printf '%s\n' "${_MOCK_COMMANDS[@]}"
}

# Clean up all mocks and restore PATH
mock_cleanup() {
  if [[ -n "$_MOCK_ORIGINAL_PATH" ]]; then
    export PATH="$_MOCK_ORIGINAL_PATH"
  fi

  if [[ -d "$_MOCK_BIN_DIR" ]]; then
    rm -rf "$_MOCK_BIN_DIR"
  fi

  _MOCK_BIN_DIR=""
  _MOCK_ORIGINAL_PATH=""
  _MOCK_COMMANDS=()
}

# Create mock for SSH command (common use case)
# Args: [output] [exit_code]
mock_ssh() {
  local output="${1:-}"
  local exit_code="${2:-0}"

  mock_command_script "ssh" "
# Log the call
echo \"\$@\" >> \"$_MOCK_BIN_DIR/ssh.calls\"

# Return configured output
echo '$output'
exit $exit_code
"
}

# Create mock for gh command (GitHub CLI)
# Args: [output] [exit_code]
mock_gh() {
  local output="${1:-{}}"
  local exit_code="${2:-0}"

  mock_command_script "gh" "
# Log the call
echo \"\$@\" >> \"$_MOCK_BIN_DIR/gh.calls\"

# Return configured output
echo '$output'
exit $exit_code
"
}

# Create mock for docker command
# Args: [output] [exit_code]
mock_docker() {
  local output="${1:-}"
  local exit_code="${2:-0}"

  mock_command_script "docker" "
# Log the call
echo \"\$@\" >> \"$_MOCK_BIN_DIR/docker.calls\"

# Return configured output
echo '$output'
exit $exit_code
"
}

# Create mock for act command
# Args: [output] [exit_code]
mock_act() {
  local output="${1:-}"
  local exit_code="${2:-0}"

  mock_command_script "act" "
# Log the call
echo \"\$@\" >> \"$_MOCK_BIN_DIR/act.calls\"

# Return configured output
echo '$output'
exit $exit_code
"
}

# Export functions
export -f mock_init mock_command mock_command_script mock_command_logged
export -f mock_get_calls mock_call_count mock_called_with
export -f mock_remove mock_list mock_cleanup
export -f mock_ssh mock_gh mock_docker mock_act
