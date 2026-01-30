#!/usr/bin/env bash
# test_host_selector.sh - Tests for src/host_selector.sh
#
# Run: ./scripts/tests/test_host_selector.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }

# Setup test environment
TEMP_DIR=$(mktemp -d)
export DSR_STATE_DIR="$TEMP_DIR/state"
export DSR_CONFIG_DIR="$TEMP_DIR/config"
mkdir -p "$DSR_STATE_DIR" "$DSR_CONFIG_DIR"

# Create mock hosts.yaml for testing
cat > "$DSR_CONFIG_DIR/hosts.yaml" << 'YAML'
schema_version: "1.0.0"

hosts:
  alpha:
    platform: linux/amd64
    connection: local
    max_parallel: 3
    description: "Local host"
  beta:
    platform: darwin/arm64
    connection: ssh
    max_parallel: 1
    description: "Remote host"
YAML

export DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"

# Stub yq to avoid external dependency and keep tests deterministic
mkdir -p "$TEMP_DIR/bin"
cat > "$TEMP_DIR/bin/yq" << 'YQ'
#!/usr/bin/env bash
# Minimal stub for host_selector tests
if [[ "$1" == "-r" ]]; then
  query="$2"
  file="$3"
else
  query="$1"
  file="$2"
fi

case "$query" in
  ".hosts.alpha.max_parallel // 2") echo "3" ;;
  ".hosts.beta.max_parallel // 2") echo "1" ;;
  ".hosts.alpha.platform // \"\"") echo "linux/amd64" ;;
  ".hosts.beta.platform // \"\"") echo "darwin/arm64" ;;
  ".hosts.alpha.connection // \"ssh\"") echo "local" ;;
  ".hosts.beta.connection // \"ssh\"") echo "ssh" ;;
  ".hosts | keys | .[]") echo "alpha"; echo "beta" ;;
  *) echo "" ;;
esac
YQ
chmod +x "$TEMP_DIR/bin/yq"
export PATH="$TEMP_DIR/bin:$PATH"

# Stub host_health_get_healthy_hosts for deterministic candidates
# shellcheck disable=SC2317
host_health_get_healthy_hosts() {
  local capability=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --for-capability) capability="$2"; shift 2 ;;
      --json) shift ;;
      *) shift ;;
    esac
  done

  if [[ -n "$capability" ]]; then
    echo '["alpha"]'
  else
    echo '["alpha","beta"]'
  fi
}
export -f host_health_get_healthy_hosts

# Source the module under test
# shellcheck disable=SC1091
source "$PROJECT_ROOT/src/host_selector.sh"

# ==========================================================================
# Tests
# ==========================================================================

test_selector_init_creates_dirs() {
  ((TESTS_RUN++))

  selector_init

  if [[ -d "$DSR_STATE_DIR/selector" && -d "$DSR_STATE_DIR/selector/locks" ]]; then
    pass "selector_init creates state directories"
  else
    fail "selector_init did not create expected directories"
  fi
}

test_get_limit_reads_config() {
  ((TESTS_RUN++))

  local limit
  limit=$(selector_get_limit "alpha")

  if [[ "$limit" == "3" ]]; then
    pass "selector_get_limit reads max_parallel from config"
  else
    fail "selector_get_limit expected 3, got $limit"
  fi
}

test_get_usage_counts_locks() {
  ((TESTS_RUN++))

  selector_init
  mkdir -p "$DSR_STATE_DIR/selector/locks/alpha"
  echo "run-1" > "$DSR_STATE_DIR/selector/locks/alpha/run-1.lock"

  local usage
  usage=$(selector_get_usage "alpha")

  if [[ "$usage" == "1" ]]; then
    pass "selector_get_usage counts active locks"
  else
    fail "selector_get_usage expected 1, got $usage"
  fi
}

test_has_capacity_respects_limit() {
  ((TESTS_RUN++))

  selector_init
  mkdir -p "$DSR_STATE_DIR/selector/locks/alpha"
  rm -f "$DSR_STATE_DIR/selector/locks/alpha"/*.lock 2>/dev/null || true

  # Add 2 locks (limit is 3)
  echo "run-a" > "$DSR_STATE_DIR/selector/locks/alpha/run-a.lock"
  echo "run-b" > "$DSR_STATE_DIR/selector/locks/alpha/run-b.lock"

  if selector_has_capacity "alpha"; then
    pass "selector_has_capacity true when under limit"
  else
    fail "selector_has_capacity should be true when under limit"
  fi

  # Add third lock (at limit)
  echo "run-c" > "$DSR_STATE_DIR/selector/locks/alpha/run-c.lock"

  if ! selector_has_capacity "alpha"; then
    pass "selector_has_capacity false when at limit"
  else
    fail "selector_has_capacity should be false at limit"
  fi
}

test_acquire_and_release_slot() {
  ((TESTS_RUN++))

  selector_init
  local run_id="test-run-1"

  if selector_acquire_slot "alpha" "$run_id"; then
    if [[ -f "$DSR_STATE_DIR/selector/locks/alpha/${run_id}.lock" ]]; then
      pass "selector_acquire_slot creates lock file"
    else
      fail "selector_acquire_slot did not create lock file"
    fi
  else
    fail "selector_acquire_slot failed unexpectedly"
  fi

  selector_release_slot "alpha" "$run_id"
  if [[ ! -f "$DSR_STATE_DIR/selector/locks/alpha/${run_id}.lock" ]]; then
    pass "selector_release_slot removes lock file"
  else
    fail "selector_release_slot did not remove lock file"
  fi
}

test_get_candidates_filters_target() {
  ((TESTS_RUN++))

  local candidates
  candidates=$(selector_get_candidates --target linux/amd64)

  if echo "$candidates" | jq -e 'length == 1 and .[0].hostname == "alpha"' >/dev/null; then
    pass "selector_get_candidates filters by target OS"
  else
    fail "selector_get_candidates target filter mismatch: $candidates"
  fi
}

test_choose_host_prefers_local() {
  ((TESTS_RUN++))

  local chosen
  chosen=$(selector_choose_host)

  if [[ "$chosen" == "alpha" ]]; then
    pass "selector_choose_host picks highest score (local)"
  else
    fail "selector_choose_host expected alpha, got $chosen"
  fi
}

test_choose_host_respects_prefer() {
  ((TESTS_RUN++))

  local chosen
  chosen=$(selector_choose_host --prefer beta)

  if [[ "$chosen" == "beta" ]]; then
    pass "selector_choose_host respects preferred host when available"
  else
    fail "selector_choose_host expected beta, got $chosen"
  fi
}

test_queue_status_returns_hosts() {
  ((TESTS_RUN++))

  local status
  status=$(selector_queue_status --json)

  if echo "$status" | jq -e 'length == 2 and map(.hostname) | sort == ["alpha","beta"]' >/dev/null; then
    pass "selector_queue_status returns all configured hosts"
  else
    fail "selector_queue_status missing hosts: $status"
  fi
}

# ==========================================================================
# Run All Tests
# ==========================================================================

echo "=== Host Selector Module Tests ==="
echo ""

test_selector_init_creates_dirs
test_get_limit_reads_config
test_get_usage_counts_locks
test_has_capacity_respects_limit
test_acquire_and_release_slot
test_get_candidates_filters_target
test_choose_host_prefers_local
test_choose_host_respects_prefer
test_queue_status_returns_hosts

# Cleanup
rm -rf "$TEMP_DIR"

# Summary
echo ""
echo "=== Results ==="
echo "Tests run: $TESTS_RUN"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
exit 0
