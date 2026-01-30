#!/usr/bin/env bash
# bats.config.bash - Auto-loaded by bats-core
#
# This file is sourced by bats before running tests.
# It loads the test harness and sets up common hooks.

# Find the helpers directory relative to this file
BATS_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the test harness
source "$BATS_CONFIG_DIR/helpers/test_harness.bash"

# Bats setup hook - called before each test
setup() {
  harness_setup
}

# Bats teardown hook - called after each test
teardown() {
  harness_teardown
}

# Bats setup_file hook - called once before all tests in a file
setup_file() {
  # Ensure we're in the project root
  cd "$DSR_PROJECT_ROOT" || exit 1
}

# Bats teardown_file hook - called once after all tests in a file
teardown_file() {
  true  # Nothing to clean up at file level
}
