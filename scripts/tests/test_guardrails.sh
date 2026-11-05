#!/usr/bin/env bash
# test_guardrails.sh - Tests for src/guardrails.sh
#
# Run: ./scripts/tests/test_guardrails.sh

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
export DSR_CACHE_DIR="$TEMP_DIR/cache"
mkdir -p "$DSR_STATE_DIR" "$DSR_CACHE_DIR"

# Stub logging functions
log_info() { :; }
log_warn() { :; }
log_error() { echo "ERROR: $*" >&2; }
log_debug() { :; }
export -f log_info log_warn log_error log_debug

# Source the guardrails module
source "$PROJECT_ROOT/src/guardrails.sh"

# ============================================================================
# Bash Version Tests
# ============================================================================

test_require_bash_4_passes() {
  ((TESTS_RUN++))

  # Current shell should be Bash 4+
  if require_bash_4 2>/dev/null; then
    pass "require_bash_4 passes on current shell"
  else
    fail "require_bash_4 should pass (current: $BASH_VERSION)"
  fi
}

# ============================================================================
# Path Resolution Tests
# ============================================================================

test_resolve_path_absolute() {
  ((TESTS_RUN++))

  local result
  result=$(resolve_path "/usr/bin")

  if [[ "$result" == "/usr/bin" ]]; then
    pass "resolve_path handles absolute paths"
  else
    fail "resolve_path absolute: expected /usr/bin, got $result"
  fi
}

test_resolve_path_tilde() {
  ((TESTS_RUN++))

  local result
  result=$(resolve_path "~")

  if [[ "$result" == "$HOME" ]]; then
    pass "resolve_path expands ~"
  else
    fail "resolve_path tilde: expected $HOME, got $result"
  fi
}

test_resolve_path_tilde_subdir() {
  ((TESTS_RUN++))

  local result
  # shellcheck disable=SC2088  # Testing that resolve_path handles literal tilde
  result=$(resolve_path "~/test/path")

  if [[ "$result" == "$HOME/test/path" ]]; then
    pass "resolve_path expands ~/subdir"
  else
    fail "resolve_path tilde subdir: expected $HOME/test/path, got $result"
  fi
}

test_resolve_path_rejects_relative() {
  ((TESTS_RUN++))

  if resolve_path "relative/path" 2>/dev/null; then
    fail "resolve_path should reject relative paths"
  else
    pass "resolve_path rejects relative paths"
  fi
}

test_resolve_path_rejects_empty() {
  ((TESTS_RUN++))

  if resolve_path "" 2>/dev/null; then
    fail "resolve_path should reject empty paths"
  else
    pass "resolve_path rejects empty paths"
  fi
}

test_resolve_path_or_default() {
  ((TESTS_RUN++))

  local result
  result=$(resolve_path_or_default "" "/default/path")

  if [[ "$result" == "/default/path" ]]; then
    pass "resolve_path_or_default uses default"
  else
    fail "resolve_path_or_default: expected /default/path, got $result"
  fi
}

# ============================================================================
# Safe Deletion Tests
# ============================================================================

test_safe_rm_under_state_dir() {
  ((TESTS_RUN++))

  local test_file="$DSR_STATE_DIR/test_file.txt"
  echo "test" > "$test_file"

  if safe_rm "$test_file" && [[ ! -f "$test_file" ]]; then
    pass "safe_rm deletes file under DSR_STATE_DIR"
  else
    fail "safe_rm should delete file under DSR_STATE_DIR"
  fi
}

test_safe_rm_under_cache_dir() {
  ((TESTS_RUN++))

  local test_file="$DSR_CACHE_DIR/test_file.txt"
  echo "test" > "$test_file"

  if safe_rm "$test_file" && [[ ! -f "$test_file" ]]; then
    pass "safe_rm deletes file under DSR_CACHE_DIR"
  else
    fail "safe_rm should delete file under DSR_CACHE_DIR"
  fi
}

test_safe_rm_under_tmp() {
  ((TESTS_RUN++))

  # Create a file explicitly under /tmp (not TMPDIR which may be elsewhere)
  local test_file
  test_file="/tmp/dsr_test_$$_$(date +%s).txt"
  echo "test" > "$test_file"

  if safe_rm "$test_file" && [[ ! -f "$test_file" ]]; then
    pass "safe_rm deletes file under /tmp"
  else
    fail "safe_rm should delete file under /tmp"
    rm -f "$test_file"
  fi
}

test_safe_rm_refuses_outside() {
  ((TESTS_RUN++))

  # Try to delete something outside allowed roots
  if safe_rm "/usr/bin/ls" 2>/dev/null; then
    fail "safe_rm should refuse paths outside allowed roots"
  else
    pass "safe_rm refuses paths outside allowed roots"
  fi
}

test_safe_rm_refuses_root_dir() {
  ((TESTS_RUN++))

  # Try to delete a root directory itself
  if safe_rm "$DSR_STATE_DIR" 2>/dev/null; then
    fail "safe_rm should refuse to delete root directories"
  else
    pass "safe_rm refuses to delete root directories"
  fi
}

test_safe_rm_directory() {
  ((TESTS_RUN++))

  local test_dir="$DSR_STATE_DIR/test_dir"
  mkdir -p "$test_dir"
  echo "test" > "$test_dir/file.txt"

  if safe_rm "$test_dir" && [[ ! -d "$test_dir" ]]; then
    pass "safe_rm deletes directories"
  else
    fail "safe_rm should delete directories"
    rm -rf "$test_dir"
  fi
}

test_safe_rm_nonexistent() {
  ((TESTS_RUN++))

  if safe_rm "$DSR_STATE_DIR/nonexistent_file_xyz" 2>/dev/null; then
    pass "safe_rm succeeds on nonexistent paths"
  else
    fail "safe_rm should succeed on nonexistent paths"
  fi
}

# ============================================================================
# Safe Tmpdir Tests
# ============================================================================

test_safe_tmpdir_creates_under_tmp() {
  ((TESTS_RUN++))

  local tmpdir
  tmpdir=$(safe_tmpdir "test")

  if [[ -d "$tmpdir" && "$tmpdir" == /tmp/test.* ]]; then
    pass "safe_tmpdir creates directory under /tmp"
    rm -rf "$tmpdir"
  else
    fail "safe_tmpdir should create directory under /tmp, got $tmpdir"
  fi
}

test_safe_tmpdir_default_prefix() {
  ((TESTS_RUN++))

  local tmpdir
  tmpdir=$(safe_tmpdir)

  if [[ -d "$tmpdir" && "$tmpdir" == /tmp/dsr.* ]]; then
    pass "safe_tmpdir uses default prefix"
    rm -rf "$tmpdir"
  else
    fail "safe_tmpdir should use dsr prefix by default, got $tmpdir"
  fi
}

# ============================================================================
# NO_COLOR Tests
# ============================================================================

test_is_color_disabled_with_no_color() {
  ((TESTS_RUN++))

  NO_COLOR=1 is_color_disabled
  local result=$?

  if [[ $result -eq 0 ]]; then
    pass "is_color_disabled returns true when NO_COLOR set"
  else
    fail "is_color_disabled should return true when NO_COLOR set"
  fi
}

test_is_color_disabled_with_flag() {
  ((TESTS_RUN++))

  DSR_NO_COLOR=true is_color_disabled
  local result=$?

  if [[ $result -eq 0 ]]; then
    pass "is_color_disabled returns true when DSR_NO_COLOR=true"
  else
    fail "is_color_disabled should return true when DSR_NO_COLOR=true"
  fi
}

test_color_returns_empty_when_disabled() {
  ((TESTS_RUN++))

  local result
  result=$(NO_COLOR=1 color red)

  if [[ -z "$result" ]]; then
    pass "color returns empty when NO_COLOR set"
  else
    fail "color should return empty when NO_COLOR set"
  fi
}

# ============================================================================
# Non-Interactive Tests
# ============================================================================

test_is_non_interactive_with_ci() {
  ((TESTS_RUN++))

  CI=true is_non_interactive
  local result=$?

  if [[ $result -eq 0 ]]; then
    pass "is_non_interactive returns true when CI set"
  else
    fail "is_non_interactive should return true when CI set"
  fi
}

test_is_non_interactive_with_flag() {
  ((TESTS_RUN++))

  DSR_NON_INTERACTIVE=true is_non_interactive
  local result=$?

  if [[ $result -eq 0 ]]; then
    pass "is_non_interactive returns true with DSR_NON_INTERACTIVE"
  else
    fail "is_non_interactive should return true with DSR_NON_INTERACTIVE"
  fi
}

test_confirm_uses_default_in_ci() {
  ((TESTS_RUN++))

  local result
  CI=true confirm "Test?" y
  result=$?

  if [[ $result -eq 0 ]]; then
    pass "confirm uses default yes in CI"
  else
    fail "confirm should use default yes in CI"
  fi
}

test_command_deadline_consumers() {
  if ! command -v python3 >/dev/null || ! command -v jq >/dev/null; then
    printf '%s\n' 'SKIP: command deadline integration requires python3 and jq'
    return
  fi
  ((TESTS_RUN++))
  if python3 - "$PROJECT_ROOT/src" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

module = Path(sys.argv[1])
root = Path(tempfile.mkdtemp(prefix="dsr-command-deadlines-"))
print("Retained command deadline fixture: " + str(root), flush=True)
checks = 0
failures = 0

def check(label, valid):
    global checks, failures
    checks += 1
    failures += not valid
    print(("PASS " if valid else "FAIL ") + label, flush=True)

probe = """#!/usr/bin/env python3
import os, pathlib, sys, time
case = pathlib.Path(os.environ["DSR_DEADLINE_CASE"])
with (case / "calls").open("a") as out:
    out.write("called\\n")
print("Latest version: 1.2.3\\nUpdate available", flush=True)
if os.environ["DSR_DEADLINE_MODE"] == "slow":
    time.sleep(2)
(case / "completed").write_text("completed\\n")
"""
driver = r'''
source "$1/logging.sh" || exit 90
source "$1/host_health.sh" || exit 90
source "$1/canary.sh" || exit 90
source "$1/upgrade_verify.sh" || exit 90
if [[ "$2" == portable ]]; then
    _dsr_timeout_cmd() { printf ''; }
    _hh_timeout_cmd() { printf ''; }
    _canary_timeout_cmd() { printf ''; }
fi
# Only configuration lookup is replaced. The real verification entry points,
# subprocess execution, deadline ownership and JSON verdicts are exercised.
_upgrade_tool_binary_name() { printf '%s\n' timeout-probe; }
_upgrade_check_args() { printf '%s\n' upgrade --check; }
UPGRADE_VERIFY_TIMEOUT=1
case "$3" in
    health)
        _HH_SSH_TIMEOUT=1
        _hh_check_connectivity fixture ssh fixture
        ;;
    canary) _canary_run_with_timeout 1 timeout-probe ;;
    upgrade_plain) upgrade_verify_tool fixture --version 1.2.3 ;;
    upgrade_json) upgrade_verify_json fixture --version 1.2.3 ;;
esac
'''
for engine in ("system", "portable"):
    for consumer in ("health", "canary", "upgrade_plain", "upgrade_json"):
        for mode in ("quick", "slow"):
            label = engine + "/" + consumer + "/" + mode
            case = root / (engine + "-" + consumer + "-" + mode)
            (case / "bin").mkdir(parents=True)
            for name in ("ssh", "timeout-probe"):
                executable = case / "bin" / name
                executable.write_text(probe)
                executable.chmod(0o755)
            env = dict(os.environ, DSR_DEADLINE_CASE=str(case), DSR_DEADLINE_MODE=mode,
                       PATH=str(case / "bin") + os.pathsep + os.environ["PATH"], NO_COLOR="1")
            result = subprocess.run(["bash", "-c", driver, "_", str(module), engine, consumer],
                                    env=env, input="", text=True, capture_output=True, timeout=8)
            (case / "stdout").write_text(result.stdout)
            (case / "stderr").write_text(result.stderr)
            expected = 0 if mode == "quick" else (124 if consumer == "canary" else 1)
            check(label + ": actual completion/deadline status", result.returncode == expected)
            check(label + ": one invocation and no post-deadline work",
                  (case / "calls").is_file() and (case / "calls").read_text() == "called\n" and
                  (case / "completed").exists() == (mode == "quick"))
            if consumer == "health":
                report = json.loads(result.stdout)
                check(label + ": health admission follows probe result",
                      report["reachable"] == (mode == "quick"))
            elif consumer == "upgrade_json":
                report = json.loads(result.stdout)
                check(label + ": positive text cannot override a timeout",
                      report["status"] == ("passed" if mode == "quick" else "failed") and
                      report["found_asset"] == (mode == "quick") and
                      report["exit_code"] == (0 if mode == "quick" else 124) and
                      report["latest_version"] == "1.2.3")

# Public callers may wrap a transport in an unexported function. GNU timeout
# cannot execute that function, so exercise the actual inherited definition.
public_driver = r'''
source "$1/guardrails.sh" || exit 90
if [[ "$2" == portable ]]; then _dsr_timeout_cmd() { printf ''; }; fi
secret_value='retained local value'
payload() { printf '<%s> <%s>\n' "$secret_value" "$1"; cat; return 23; }
run_with_timeout 1 payload 'space argument'
'''
for engine in ("system", "portable"):
    result = subprocess.run(["bash", "-c", public_driver, "_", str(module), engine],
                            input="original stdin\n", text=True, capture_output=True, timeout=5)
    check(engine + ": public API preserves unexported function, arguments, stdin and status",
          result.returncode == 23 and
          result.stdout == "<retained local value> <space argument>\noriginal stdin\n")
    function_deadline = subprocess.run(["bash", "-c", r'''
source "$1/guardrails.sh" || exit 90
if [[ "$2" == portable ]]; then _dsr_timeout_cmd() { printf ''; }; fi
payload() { sleep 2; printf 'late\n'; }
run_with_timeout 0.2 payload
''', "_", str(module), engine], capture_output=True, text=True, timeout=8)
    check(engine + ": unexported function cannot run beyond its deadline",
          function_deadline.returncode == 124 and function_deadline.stdout == "")
    builtin = subprocess.run(["bash", "-c", r'''
source "$1/guardrails.sh" || exit 90
if [[ "$2" == portable ]]; then _dsr_timeout_cmd() { printf ''; }; fi
run_with_timeout 1 printf '<%s>\n' 'space argument' ''
''', "_", str(module), engine], capture_output=True, text=True, timeout=5)
    check(engine + ": public API preserves shell builtin arguments",
          builtin.returncode == 0 and builtin.stdout == "<space argument>\n<>\n")
    sleep_override = subprocess.run(["bash", "-c", r'''
source "$1/guardrails.sh" || exit 90
if [[ "$2" == portable ]]; then _dsr_timeout_cmd() { printf ''; }; fi
sleep() { printf 'caller sleep must not control the deadline\n' >&2; return 0; }
run_with_timeout 1 bash -c 'command sleep 0.1; printf "completed\n"'
''', "_", str(module), engine], capture_output=True, text=True, timeout=5)
    check(engine + ": internal clock bypasses caller backoff functions",
          sleep_override.returncode == 0 and sleep_override.stdout == "completed\n" and
          "caller sleep" not in sleep_override.stderr)
    for duration in ("0", "0.00", "-1", "bad", "1m"):
        refused = subprocess.run(["bash", "-c", r'''
source "$1/guardrails.sh" || exit 90
if [[ "$2" == portable ]]; then _dsr_timeout_cmd() { printf ''; }; fi
run_with_timeout "$3" printf 'must not start\n'
''', "_", str(module), engine, duration], capture_output=True, text=True, timeout=5)
        check(engine + ": invalid deadline refuses before execution: " + duration,
              refused.returncode == 4 and refused.stdout == "")

empty_path = root / "no-executables"
empty_path.mkdir()
missing_sleep = subprocess.run(["bash", "-c", r'''
source "$1/guardrails.sh" || exit 90
sleep() { return 0; }
payload() { printf 'must not start\n'; }
PATH="$2"
run_with_timeout 1 payload
''', "_", str(module), str(empty_path)], capture_output=True, text=True, timeout=5)
check("a sleep function cannot replace the missing external clock",
      missing_sleep.returncode == 3 and missing_sleep.stdout == "" and
      "sleep is required" in missing_sleep.stderr)

print("Command deadline integration: %d checks, %d failures" % (checks, failures), flush=True)
raise SystemExit(bool(failures))
PY
  then
    pass "Host admission, canaries and upgrade verification enforce owned deadlines"
  else
    fail "Command deadline consumer integration"
  fi
}

# Cleanup
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "Running guardrails module tests..."
echo ""

# Bash version tests
test_require_bash_4_passes

# Path resolution tests
test_resolve_path_absolute
test_resolve_path_tilde
test_resolve_path_tilde_subdir
test_resolve_path_rejects_relative
test_resolve_path_rejects_empty
test_resolve_path_or_default

# Safe deletion tests
test_safe_rm_under_state_dir
test_safe_rm_under_cache_dir
test_safe_rm_under_tmp
test_safe_rm_refuses_outside
test_safe_rm_refuses_root_dir
test_safe_rm_directory
test_safe_rm_nonexistent

# Safe tmpdir tests
test_safe_tmpdir_creates_under_tmp
test_safe_tmpdir_default_prefix

# NO_COLOR tests
test_is_color_disabled_with_no_color
test_is_color_disabled_with_flag
test_color_returns_empty_when_disabled

# Non-interactive tests
test_is_non_interactive_with_ci
test_is_non_interactive_with_flag
test_confirm_uses_default_in_ci

# Real public consumers with and without GNU timeout
test_command_deadline_consumers

echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN"
echo "Passed:    $TESTS_PASSED"
echo "Failed:    $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
