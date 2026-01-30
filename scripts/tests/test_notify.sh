#!/usr/bin/env bash
# test_notify.sh - Tests for src/notify.sh
#
# Run: ./scripts/tests/test_notify.sh

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
mkdir -p "$DSR_STATE_DIR"

# Stub logging functions
log_info() { :; }
log_warn() { :; }
log_error() { :; }
log_debug() { :; }
export -f log_info log_warn log_error log_debug

# Source notify module
source "$PROJECT_ROOT/src/notify.sh"

test_notify_should_send_default() {
  ((TESTS_RUN++))

  if notify_should_send "run-1" "event.test"; then
    pass "notify_should_send allows first send"
  else
    fail "notify_should_send should allow first send"
  fi
}

test_notify_event_marks_sent() {
  ((TESTS_RUN++))

  export DSR_NOTIFY_METHODS="terminal"
  notify_event "event.test" "info" "Title" "Message" "run-1"

  local sent_file="$DSR_STATE_DIR/notifications/sent.jsonl"
  if [[ -f "$sent_file" ]] && grep -F "\"run_id\":\"run-1\",\"event\":\"event.test\"" "$sent_file" >/dev/null 2>&1; then
    pass "notify_event marks run_id+event as sent"
  else
    fail "notify_event did not mark run_id+event as sent"
  fi
}

test_notify_event_dedup() {
  ((TESTS_RUN++))

  local sent_file="$DSR_STATE_DIR/notifications/sent.jsonl"
  local before after
  before=$(wc -l < "$sent_file" | tr -d ' ')

  notify_event "event.test" "info" "Title" "Message" "run-1"
  after=$(wc -l < "$sent_file" | tr -d ' ')

  if [[ "$before" == "$after" ]]; then
    pass "notify_event deduplicates by run_id+event"
  else
    fail "notify_event should not add duplicate entries"
  fi
}

# Run tests
test_notify_should_send_default
test_notify_event_marks_sent
test_notify_event_dedup

# Summary
echo ""
echo "Tests run: $TESTS_RUN"
echo "Passed:    $TESTS_PASSED"
echo "Failed:    $TESTS_FAILED"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if [[ $TESTS_FAILED -eq 0 ]]; then
  exit 0
else
  exit 1
fi
