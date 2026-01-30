#!/usr/bin/env bash
# mock_random.bash - Seeded random for deterministic tests
#
# Usage:
#   source mock_random.bash
#   mock_random_seed 42
#   value=$(mock_random 100)  # Returns 0-99 deterministically
#   uuid=$(mock_uuid)         # Returns deterministic UUID

set -uo pipefail

# Internal state - Linear Congruential Generator parameters
# Using MINSTD parameters: a=48271, c=0, m=2^31-1
_MOCK_RANDOM_SEED=1
_MOCK_RANDOM_STATE=1
_MOCK_RANDOM_A=48271
_MOCK_RANDOM_M=2147483647  # 2^31 - 1

# Seed the random number generator
# Args: seed (integer)
mock_random_seed() {
  local seed="${1:-1}"
  _MOCK_RANDOM_SEED=$seed
  _MOCK_RANDOM_STATE=$seed

  # Ensure non-zero state
  if [[ $_MOCK_RANDOM_STATE -eq 0 ]]; then
    _MOCK_RANDOM_STATE=1
  fi
}

# Generate next random number in range [0, max)
# Args: max (optional, default 32768)
mock_random() {
  local max="${1:-32768}"

  # Linear Congruential Generator step
  _MOCK_RANDOM_STATE=$(( (_MOCK_RANDOM_STATE * _MOCK_RANDOM_A) % _MOCK_RANDOM_M ))

  # Scale to requested range
  echo $(( _MOCK_RANDOM_STATE % max ))
}

# Generate random bytes as hex string
# Args: count (number of bytes, default 16)
mock_random_hex() {
  local count="${1:-16}"
  local result=""
  local i

  for ((i=0; i<count; i++)); do
    local byte
    byte=$(mock_random 256)
    result+=$(printf '%02x' "$byte")
  done

  echo "$result"
}

# Generate deterministic UUID (v4-like format)
mock_uuid() {
  # UUID format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  # where x is random hex, y is 8, 9, a, or b

  local hex
  hex=$(mock_random_hex 16)

  # Set version (4) and variant bits
  # Position 12 = '4' (version)
  # Position 16 = '8', '9', 'a', or 'b' (variant)
  local variant_chars=("8" "9" "a" "b")
  local variant_idx
  variant_idx=$(mock_random 4)

  local uuid=""
  uuid+="${hex:0:8}-"
  uuid+="${hex:8:4}-"
  uuid+="4${hex:13:3}-"
  uuid+="${variant_chars[$variant_idx]}${hex:17:3}-"
  uuid+="${hex:20:12}"

  echo "$uuid"
}

# Generate deterministic run ID (format: run-<epoch>-<pid>)
mock_run_id() {
  local epoch
  epoch=$(mock_random 2000000000)
  local pid
  pid=$(mock_random 65536)
  echo "run-${epoch}-${pid}"
}

# Get current state (for debugging/verification)
mock_random_state() {
  echo "$_MOCK_RANDOM_STATE"
}

# Reset to initial seed
mock_random_restore() {
  _MOCK_RANDOM_STATE=$_MOCK_RANDOM_SEED
}

# Reset everything to defaults
mock_random_reset() {
  _MOCK_RANDOM_SEED=1
  _MOCK_RANDOM_STATE=1
}

# Export functions
export -f mock_random_seed mock_random mock_random_hex mock_uuid mock_run_id
export -f mock_random_state mock_random_restore mock_random_reset
