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

test_descriptor_lock_backends() {
  ((TESTS_RUN++))
  if python3 - "$PROJECT_ROOT/src/guardrails.sh" <<'PY'
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

module = Path(sys.argv[1])
root = Path(tempfile.mkdtemp(prefix="dsr-descriptor-locks-"))
print("Retained descriptor lock fixture: " + str(root), flush=True)
bash = shutil.which("bash")
python = shutil.which("python3")
portable = root / "portable-bin"
portable.mkdir()
(portable / "python3").symlink_to(python)
empty = root / "empty-bin"
empty.mkdir()
checks = 0

def check(label, valid):
    global checks
    if not valid:
        raise AssertionError(label)
    checks += 1
    print("PASS " + label, flush=True)

def until(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("fixture barrier timed out")

driver = r'''
source "$1" || exit 90
PATH="$2"
dsr_lock_available || exit $?
exec 9>> "$3" || exit 91
dsr_lock_fd 9 "$4" || exit $?
if [[ "$5" == hold ]]; then
    printf 'locked\n' > "$6"
    read -r _
elif [[ "$5" == child ]]; then
    "$7" - "$6" "$8" <<'CHILD' &
import os, pathlib, sys, time
os.fstat(9)
pathlib.Path(sys.argv[1]).write_text("inherited\n")
deadline = time.monotonic() + 8
while not pathlib.Path(sys.argv[2]).exists() and time.monotonic() < deadline:
    time.sleep(0.02)
CHILD
    wait "$!"
fi
'''

def arguments(path, lock, seconds="0", action="probe", ready="", stop=""):
    return [bash, "-c", driver, "lock-fixture", str(module), path,
            str(lock), seconds, action, str(ready), python, str(stop)]

def contender(path, lock, seconds="0"):
    return subprocess.run(arguments(path, lock, seconds), capture_output=True,
                          text=True, timeout=4)

paths = {"python": str(portable)}
if shutil.which("flock"):
    paths["flock"] = os.environ["PATH"]

for backend, path in paths.items():
    for action in ("hold", "child"):
        case = root / (backend + "-" + action)
        case.mkdir()
        lock, ready, stop = (case / name for name in ("lock", "ready", "stop"))
        with (case / "stderr").open("wb") as diagnostics:
            owner = subprocess.Popen(arguments(path, lock, action=action,
                                               ready=ready, stop=stop),
                                     stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                     stderr=diagnostics)
            try:
                until(ready.exists)
                original_inode = lock.stat().st_ino
                for other, other_path in paths.items():
                    probe = contender(other_path, lock)
                    check(backend + "/" + action + ": independent " + other + " process is excluded",
                          probe.returncode == 1 and probe.stdout == "")
                if action == "hold":
                    began = time.monotonic()
                    timed = contender(path, lock, "1")
                    elapsed = time.monotonic() - began
                    check(backend + ": timed contention expires without acquiring",
                          timed.returncode == 1 and 0.8 <= elapsed < 3)
                owner.kill()
                owner.wait(timeout=3)
                if action == "child":
                    probe = contender(path, lock)
                    check(backend + ": inherited child keeps the lease after coordinator crash",
                          probe.returncode == 1)
                    stop.write_text("release\n")
                until(lambda: contender(path, lock).returncode == 0)
                check(backend + "/" + action + ": last close releases the same lock inode",
                      lock.stat().st_ino == original_inode)
            finally:
                stop.write_text("release\n")
                if owner.poll() is None:
                    owner.kill()
                owner.wait(timeout=3)
                owner.stdin.close()

# A caller cannot start a transaction without a usable kernel-lock backend.
missing = subprocess.run([bash, "-c", r'''
source "$1" || exit 90
PATH="$2"
dsr_lock_available || exit $?
printf 'must not mutate\n'
''', "missing-backend", str(module), str(empty)], capture_output=True, text=True, timeout=3)
check("missing lock backends refuse before mutation",
      missing.returncode == 3 and missing.stdout == "")
broken = root / "broken-python"
broken.mkdir()
(broken / "python3").write_text("#!/bin/sh\nexit 1\n")
(broken / "python3").chmod(0o755)
unusable = subprocess.run([bash, "-c", r'''
source "$1" || exit 90
PATH="$2"
dsr_lock_available || exit $?
printf 'must not mutate\n'
''', "unusable-backend", str(module), str(broken)], capture_output=True, text=True, timeout=3)
check("an unusable Python fcntl backend refuses before mutation",
      unusable.returncode == 3 and unusable.stdout == "")

# Exported users need the same standalone dependency closure as sourced users.
exported = subprocess.run([bash, "-c", r'''
source "$1" || exit 90
PATH="$2"
"$3" -c 'dsr_lock_available && { exec 9>> "$1"; dsr_lock_fd 9 0; }' child "$4"
''', "exported-lock", str(module), str(portable), bash, str(root / "exported.lock")],
    cwd=str(root), capture_output=True, text=True, timeout=3)
check("child Bash can use the exported Python lock backend outside the repository",
      exported.returncode == 0 and exported.stdout == "" and exported.stderr == "")
print("Descriptor lock integration: %d checks, 0 failures" % checks, flush=True)
PY
  then
    pass "Kernel locks retain exclusion through helper exit and coordinator loss"
  else
    fail "Descriptor lock backend integration"
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
import signal
import subprocess
import sys
import tempfile
import time

module = Path(sys.argv[1])
root = Path(tempfile.mkdtemp(prefix="dsr-command-deadlines-"))
print("Retained command deadline fixture: " + str(root), flush=True)
checks = 0
failures = 0
portable = root / "without-timeout"
portable.mkdir()
# Exercise the same real tools with only the optional timer providers absent.
for directory in os.get_exec_path():
    source = Path(directory or ".").absolute()
    if not source.is_dir():
        continue
    for executable in source.iterdir():
        target = portable / executable.name
        if executable.name not in ("timeout", "gtimeout") and not target.exists() and \
                executable.is_file() and os.access(executable, os.X_OK):
            target.symlink_to(executable)
paths = {"system": os.environ["PATH"], "portable": str(portable)}

def environment(engine):
    return dict(os.environ, PATH=paths[engine])

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
                       PATH=str(case / "bin") + os.pathsep + paths[engine], NO_COLOR="1")
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

# Public callers may wrap a transport in an unexported function. Exercise the
# actual inherited definition both with and without external timeout commands.
public_driver = r'''
source "$1/guardrails.sh" || exit 90
secret_value='retained local value'
payload() { printf '<%s> <%s>\n' "$secret_value" "$1"; cat; return 23; }
run_with_timeout 1 payload 'space argument'
'''
for engine in ("system", "portable"):
    result = subprocess.run(["bash", "-c", public_driver, "_", str(module), engine],
                            input="original stdin\n", text=True, capture_output=True, timeout=5,
                            env=environment(engine))
    check(engine + ": public API preserves unexported function, arguments, stdin and status",
          result.returncode == 23 and
          result.stdout == "<retained local value> <space argument>\noriginal stdin\n")
    function_deadline = subprocess.run(["bash", "-c", r'''
source "$1/guardrails.sh" || exit 90
payload() { sleep 2; printf 'late\n'; }
run_with_timeout 0.2 payload
''', "_", str(module), engine], capture_output=True, text=True, timeout=8, env=environment(engine))
    check(engine + ": unexported function cannot run beyond its deadline",
          function_deadline.returncode == 124 and function_deadline.stdout == "")
    builtin = subprocess.run(["bash", "-c", r'''
source "$1/guardrails.sh" || exit 90
run_with_timeout 1 printf '<%s>\n' 'space argument' ''
''', "_", str(module), engine], capture_output=True, text=True, timeout=5, env=environment(engine))
    check(engine + ": public API preserves shell builtin arguments",
          builtin.returncode == 0 and builtin.stdout == "<space argument>\n<>\n")
    sleep_override = subprocess.run(["bash", "-c", r'''
source "$1/guardrails.sh" || exit 90
sleep() { printf 'caller sleep must not control the deadline\n' >&2; return 0; }
run_with_timeout 1 bash -c 'command sleep 0.1; printf "completed\n"'
''', "_", str(module), engine], capture_output=True, text=True, timeout=5, env=environment(engine))
    check(engine + ": internal clock bypasses caller backoff functions",
          sleep_override.returncode == 0 and sleep_override.stdout == "completed\n" and
          "caller sleep" not in sleep_override.stderr)
    for duration in ("0", "0.00", "-1", "bad", "1m"):
        refused = subprocess.run(["bash", "-c", r'''
source "$1/guardrails.sh" || exit 90
run_with_timeout "$3" printf 'must not start\n'
''', "_", str(module), engine, duration], capture_output=True, text=True, timeout=5,
            env=environment(engine))
        check(engine + ": invalid deadline refuses before execution: " + duration,
              refused.returncode == 4 and refused.stdout == "")

# Signal the live anchor itself, leaving the waiter to consume its receipt.
# A descendant writes only after surviving TERM long enough to prove the
# cancellation grace is retained, and must be gone before the API returns.
anchor_payload = root / "signal-anchor.py"
anchor_payload.write_text(r'''
import os, signal, sys, time
from pathlib import Path
case = Path(sys.argv[1])
if os.fork() == 0:
    received = []
    signal.signal(signal.SIGTERM, lambda *_: received.append(True))
    (case / "child.pid").write_text(str(os.getpid()))
    while not received:
        time.sleep(0.01)
    time.sleep(0.5)
    (case / "grace").write_text("survived TERM\n")
    time.sleep(30)
    raise SystemExit(0)
deadline = time.monotonic() + 5
while not (case / "child.pid").exists():
    if time.monotonic() >= deadline:
        raise SystemExit(97)
    time.sleep(0.01)
os.kill(os.getpgrp(), int(sys.argv[2]))
time.sleep(30)
''')
anchor_driver = r'''
source "$1/guardrails.sh" || exit 90
run_with_timeout 15 "$3" "$4" "$5" "$6"
'''
for engine in ("system", "portable"):
    for signum in (signal.SIGINT, signal.SIGTERM):
        label = engine + "/" + signal.Signals(signum).name
        case = root / ("anchor-" + engine + "-" + str(int(signum)))
        case.mkdir()
        began = time.monotonic()
        result = subprocess.run(
            ["bash", "-c", anchor_driver, "_", str(module), engine,
             sys.executable, str(anchor_payload), str(case), str(int(signum))],
            input="", text=True, capture_output=True, timeout=23, env=environment(engine))
        elapsed = time.monotonic() - began
        (case / "stdout").write_text(result.stdout)
        (case / "stderr").write_text(result.stderr)
        check(label + ": anchor cancellation preserves the raw signal status",
              result.returncode == 128 + signum and result.stdout == "")
        check(label + ": cancellation retains the resistant descendant grace",
              (case / "grace").exists() and elapsed >= 1.5)
        state = "missing pid"
        if (case / "child.pid").is_file():
            pid = int((case / "child.pid").read_text())
            for _ in range(50):
                status = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                                        capture_output=True, text=True, timeout=5)
                state = status.stdout.strip()
                if not state or state.startswith("Z"):
                    break
                time.sleep(0.02)
        check(label + ": cancellation drains the resistant descendant",
              not state or state.startswith("Z"))

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

test_timeout_provider_independence() {
  if ! command -v python3 >/dev/null; then
    printf '%s\n' 'SKIP: timeout provider regression requires python3'
    return
  fi
  ((TESTS_RUN++))
  if python3 - "${DSR_TEST_GUARDRAILS:-$PROJECT_ROOT/src/guardrails.sh}" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

module = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix="dsr-timeout-providers-"))
print("Retained timeout provider fixture: " + str(root), flush=True)
bash = shutil.which("bash")
sleep = shutil.which("sleep")
assert bash and sleep, "the real Bash and sleep executables are required"
portable = root / "without-timeout"
portable.mkdir()
(portable / "sleep").symlink_to(sleep)
unusable = root / "unusable-timeout"
unusable.mkdir()
calls = root / "provider-calls"
for name in ("timeout", "gtimeout"):
    executable = unusable / name
    executable.write_text('#!/bin/sh\nprintf "called\\n" >> "$DSR_TEST_TIMEOUT_CALLS"\nexit 99\n')
    executable.chmod(0o755)
paths = {"system": os.environ["PATH"], "without-timeout": str(portable),
         "unusable-timeout": str(unusable) + os.pathsep + str(portable)}
# An actual provider (for example the official uutils 0.10.0 binary) can be
# supplied without downloading tools or substituting its signal semantics.
selected = os.environ.get("DSR_TEST_TIMEOUT_EXECUTABLE", "")
if selected:
    executable = Path(selected).resolve(strict=True)
    assert executable.is_file() and os.access(executable, os.X_OK)
    provider = root / "selected-provider"
    provider.mkdir()
    (provider / "timeout").symlink_to(executable)
    paths["selected-provider"] = str(provider) + os.pathsep + str(portable)

checks = failures = 0
for provider, path in paths.items():
    for ignored in (False, True):
        def inherited_signal():
            signal.signal(signal.SIGINT, signal.SIG_IGN if ignored else signal.SIG_DFL)
        cases = [("exit-" + str(code), "raise SystemExit(" + str(code) + ")", code)
                 for code in (0, 2, 23)]
        cases += [(name, "import os,signal; signal.signal(signal." + name +
                   ",signal.SIG_DFL); os.kill(os.getpid(),signal." + name + ")", 128 + int(number))
                  for name, number in (("SIGINT", signal.SIGINT), ("SIGTERM", signal.SIGTERM),
                                       ("SIGPIPE", signal.SIGPIPE))]
        for name, program, expected in cases:
            label = provider + "/" + ("ignored-INT" if ignored else "default-INT") + "/" + name
            result = subprocess.run([bash, "-c", 'source "$1" || exit 90; run_with_timeout 3 "$2" -c "$3"',
                                     "_", str(module), sys.executable, program],
                                    env=dict(os.environ, PATH=path, DSR_TEST_TIMEOUT_CALLS=str(calls)),
                                    capture_output=True, text=True, preexec_fn=inherited_signal, timeout=8)
            valid = result.returncode == expected and result.stdout == ""
            checks += 1
            failures += not valid
            print(("PASS " if valid else "FAIL ") + label + ": expected " + str(expected) +
                  ", observed " + str(result.returncode), flush=True)
checks += 1
failures += calls.exists()
print(("FAIL " if calls.exists() else "PASS ") + "external timeout providers are never invoked", flush=True)
print("Timeout providers: %d checks, %d failures" % (checks, failures), flush=True)
raise SystemExit(bool(failures))
PY
  then
    pass "Actual command statuses survive timeout provider and inherited signal differences"
  else
    fail "Timeout provider independence"
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

if [[ "${1:-}" == --timeout-providers-only ]]; then
  test_timeout_provider_independence
  [[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
fi

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

# Real public consumers with and without external timeout executables.
test_command_deadline_consumers
test_timeout_provider_independence

# The same inherited lock domain with util-linux or Python, including crashes.
test_descriptor_lock_backends

echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN"
echo "Passed:    $TESTS_PASSED"
echo "Failed:    $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
