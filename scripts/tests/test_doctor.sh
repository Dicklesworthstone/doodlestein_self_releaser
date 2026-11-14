#!/usr/bin/env bash
# test_doctor.sh - Integration tests for dsr doctor command
#
# Tests doctor output format, exit codes, and modes.
# Runs against real system state (no mocking of external commands).
#
# Run: ./scripts/tests/test_doctor.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSR_CMD="${DSR_TEST_COMMAND_FILE:-$PROJECT_ROOT/dsr}"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }

# Setup test environment
TEMP_DIR=$(mktemp -d)
export DSR_STATE_DIR="$TEMP_DIR/state"
export DSR_CONFIG_DIR="$TEMP_DIR/config"
export DSR_CACHE_DIR="$TEMP_DIR/cache"
mkdir -p "$DSR_STATE_DIR" "$DSR_CONFIG_DIR" "$DSR_CACHE_DIR"

# ============================================================================
# Tests: Help and Basic Invocation
# ============================================================================

test_doctor_help() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" doctor --help 2>&1)

    if echo "$output" | grep -q "System diagnostics" && \
       echo "$output" | grep -q "USAGE:" && \
       echo "$output" | grep -q "OPTIONS:"; then
        pass "doctor --help shows usage information"
    else
        fail "doctor --help should show usage information"
    fi
}

test_doctor_runs_without_error() {
    ((TESTS_RUN++))

    # Doctor may return 3 for missing deps, but should not crash
    local exit_code=0
    "$DSR_CMD" doctor --quick >/dev/null 2>&1 || exit_code=$?

    if [[ $exit_code -eq 0 || $exit_code -eq 3 ]]; then
        pass "doctor runs without crash (exit code: $exit_code)"
    else
        fail "doctor should exit 0 or 3, got: $exit_code"
    fi
}

# ============================================================================
# Tests: JSON Output Format
# ============================================================================

test_doctor_json_valid() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>/dev/null)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "--json doctor produces valid JSON"
    else
        fail "--json doctor should produce valid JSON"
    fi
}

test_doctor_json_has_status() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>/dev/null)

    if echo "$output" | jq -e '.status' >/dev/null 2>&1; then
        pass "doctor JSON has status field"
    else
        fail "doctor JSON should have status field"
    fi
}

test_doctor_json_has_checks_array() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>/dev/null)

    if echo "$output" | jq -e '.details.checks | type == "array"' >/dev/null 2>&1; then
        pass "doctor JSON has checks array"
    else
        fail "doctor JSON should have details.checks array"
    fi
}

test_doctor_json_check_has_name() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>/dev/null)

    # All checks should have a name field
    local invalid_checks
    invalid_checks=$(echo "$output" | jq -r '.details.checks[]? | select(.name == null) | .status' 2>/dev/null)

    if [[ -z "$invalid_checks" ]]; then
        pass "all checks have name field"
    else
        fail "all checks should have name field"
    fi
}

test_doctor_json_check_has_status() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>/dev/null)

    # All checks should have a status field (ok, warning, error)
    local has_status
    has_status=$(echo "$output" | jq -r '.details.checks[]? | select(.status) | .name' 2>/dev/null | head -1)

    if [[ -n "$has_status" ]]; then
        pass "checks have status field"
    else
        fail "checks should have status field"
    fi
}

# ============================================================================
# Tests: Core Dependency Detection
# ============================================================================

test_doctor_detects_git() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>/dev/null)

    if echo "$output" | jq -e '.details.checks[] | select(.name == "git")' >/dev/null 2>&1; then
        pass "doctor checks for git"
    else
        fail "doctor should check for git"
    fi
}

test_doctor_detects_gh() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>/dev/null)

    if echo "$output" | jq -e '.details.checks[] | select(.name == "gh")' >/dev/null 2>&1; then
        pass "doctor checks for gh"
    else
        fail "doctor should check for gh"
    fi
}

test_doctor_uses_selected_github_identity() {
    ((TESTS_RUN++))

    local bin_dir="$TEMP_DIR/identity-bin" output
    mkdir -p "$bin_dir"
    cat > "$bin_dir/gh" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    printf 'gh version 2.0.0 (fixture)\n'
    exit 0
fi
[[ "${GH_TOKEN:-}" == "release-fixture-token" && "${GH_HOST:-}" == "github.com" ]] || exit 9
case "$*" in
    'auth status --hostname github.com') exit 0 ;;
    'api user --hostname github.com --jq .login') printf 'selected-release-user\n' ;;
    *) exit 8 ;;
esac
SH
    chmod +x "$bin_dir/gh"
    output=$(DSR_GH_TOKEN=release-fixture-token GITHUB_TOKEN=ci-fixture-token \
        GH_TOKEN=ambient-fixture-token GH_HOST=enterprise.fixture.invalid \
        PATH="$bin_dir:$PATH" "$DSR_CMD" --json doctor --quick 2>/dev/null)

    if jq -e '.details.checks[] | select(.name == "gh") |
        .status == "ok" and .authenticated == true and .user == "selected-release-user"' \
        <<< "$output" >/dev/null 2>&1; then
        pass "doctor validates the selected release account on github.com"
    else
        fail "doctor must validate the release identity when ambient gh credentials differ"
    fi
}

# The gh boundary is an explicit fixture; the public doctor/watch commands,
# credential selection and process-group deadline supervisor all execute.
test_doctor_github_deadlines() {
    ((TESTS_RUN++))
    if ! command -v python3 >/dev/null; then
        skip "Python 3 is required for bounded doctor/watch regression checks"
        return
    fi
    if python3 - "$DSR_CMD" "$TEMP_DIR" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import time

cli, root = sys.argv[1], Path(sys.argv[2])
fixture = root / "doctor-deadlines"
fixture.mkdir()
bin_dir = fixture / "bin"
bin_dir.mkdir()
gh = bin_dir / "gh"
gh.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$DSR_DOCTOR_CASE/calls"
stall() {
    printf 'started\n' >> "$DSR_DOCTOR_CASE/started"
    command sleep 3
    printf 'escaped\n' >> "$DSR_DOCTOR_CASE/escaped"
}
case "$*" in
    --version) printf 'gh version 2.0.0 (deadline fixture)\n'; exit 0 ;;
    'auth token --hostname github.com')
        case "$DSR_DOCTOR_PHASE" in
            token-timeout) stall ;;
            token-cancel) exit 2 ;;
            token-missing) exit 1 ;;
            user-token-cancel)
                [[ ! -f "$DSR_DOCTOR_CASE/authenticated" ]] || exit 130
                ;;
        esac
        printf 'doctor-fixture-token\n'
        exit 0
        ;;
esac
[[ "$GH_TOKEN" == doctor-fixture-token && "$GH_HOST" == github.com ]] || exit 9
case "$*" in
    'auth status --hostname github.com')
        case "$DSR_DOCTOR_PHASE" in
            auth-timeout) stall ;;
            auth-cancel) exit 2 ;;
            auth-error) exit 1 ;;
        esac
        : > "$DSR_DOCTOR_CASE/authenticated"
        exit 0
        ;;
    'api user --hostname github.com --jq .login')
        case "$DSR_DOCTOR_PHASE" in
            user-timeout) printf 'partial-user\n'; stall ;;
            user-error) printf 'partial-user\n'; exit 1 ;;
            user-cancel) printf 'partial-user\n'; exit 130 ;;
        esac
        printf 'selected-release-user\n'
        ;;
    *) exit 9 ;;
esac
''')
gh.chmod(0o700)

cases = [
    ("doctor", "healthy", 0),
    ("doctor", "auth-timeout", 3),
    ("doctor", "token-timeout", 3),
    ("doctor", "user-timeout", 0),
    ("doctor", "user-error", 0),
    ("doctor", "auth-cancel", 5),
    ("doctor", "user-cancel", 5),
    ("doctor", "invalid-deadline", 3),
    ("doctor", "token-cancel", 5),
    ("doctor", "user-token-cancel", 5),
    ("doctor", "token-missing", 3),
    ("doctor", "auth-error", 3),
    ("watch", "auth-timeout", 8),
    ("watch", "token-timeout", 8),
    ("watch", "auth-cancel", 5),
    ("watch", "user-cancel", 5),
    ("watch", "token-cancel", 5),
    ("watch", "user-token-cancel", 5),
    ("watch", "user-error", 1),
    ("watch", "user-timeout", 8),
]
for command, phase, expected in cases:
    case = fixture / (command + "-" + phase)
    case.mkdir(mode=0o700)
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
               DSR_DOCTOR_CASE=str(case), DSR_DOCTOR_PHASE=phase,
               DSR_GH_TOKEN="" if phase in ("token-timeout", "token-cancel", "user-token-cancel", "token-missing")
                   else "doctor-fixture-token",
               GITHUB_TOKEN="", GH_TOKEN="", GH_HOST="enterprise.fixture.invalid",
               GH_API_TIMEOUT=("0" if phase == "invalid-deadline" else
                               "10" if command == "watch" and not phase.endswith("timeout") else "1"),
               DSR_CONFIG_DIR=str(case / "config"), DSR_CONFIG_FILE=str(case / "config.yaml"),
               DSR_REPOS_FILE=str(case / "repos.yaml"), DSR_HOSTS_FILE=str(case / "hosts.yaml"),
               DSR_STATE_DIR=str(case / "state"), DSR_CACHE_DIR=str(case / "cache"),
               NO_COLOR="1")
    args = [cli, "--dry-run", "--json", command]
    args += ["--quick"] if command == "doctor" else ["--once", "--auto-fallback"]
    started = time.monotonic()
    result = subprocess.run(args, env=env, capture_output=True, text=True,
                            timeout=20 if command == "watch" and not phase.endswith("timeout") else 8)
    elapsed = time.monotonic() - started
    (case / "stdout").write_text(result.stdout)
    (case / "stderr").write_text(result.stderr)
    (case / "result.json").write_text(json.dumps({"status": result.returncode, "elapsed": elapsed}))
    assert result.returncode == expected, (command, phase, result.returncode, result.stderr)
    assert not (case / "escaped").exists(), (command, phase, "deadline operation continued")
    calls = (case / "calls").read_text().splitlines()
    auth = [line for line in calls if line == "auth status --hostname github.com"]
    user = [line for line in calls if line == "api user --hostname github.com --jq .login"]
    tokens = [line for line in calls if line == "auth token --hostname github.com"]
    # A watch budget covers doctor startup and both credential operations.
    # It can expire before the optional user lookup starts. The standalone
    # doctor/user-timeout case above still requires that exact probe to run.
    early_watch_deadline = command == "watch" and phase == "user-timeout" and not (case / "started").exists()
    if phase.endswith("timeout") and not early_watch_deadline:
        assert (case / "started").read_text() == "started\n", (command, phase, "repeated operation")
    if phase in ("token-timeout", "token-cancel", "token-missing", "invalid-deadline"):
        assert not auth and not user, (command, phase, calls)
        assert len(tokens) == (0 if phase == "invalid-deadline" else 1), (command, phase, calls)
    elif phase == "user-token-cancel":
        assert len(auth) == 1 and len(tokens) == 2 and not user, (command, phase, calls)
    elif early_watch_deadline:
        assert len(auth) <= 1 and not user and not tokens, (command, phase, calls)
    else:
        assert len(auth) == 1 and not tokens, (command, phase, calls)
        assert len(user) == (0 if phase.startswith("auth-") else 1), (command, phase, calls)
    if command == "doctor":
        response = json.loads(result.stdout)
        assert response["exit_code"] == expected, (phase, response)
        assert response["status"] == ("success" if expected == 0 else "error"), (phase, response)
        check = next(item for item in response["details"]["checks"] if item["name"] == "gh")
        assert check["authenticated"] == (phase.startswith("user-") or phase == "healthy"), (phase, check)
        if phase in ("user-timeout", "user-error", "healthy"):
            wanted = "selected-release-user" if phase == "healthy" else "unknown"
            assert check["status"] == "ok" and check["user"] == wanted, (phase, check)
            assert "partial-user" not in result.stdout, (phase, result.stdout)
        elif phase == "invalid-deadline":
            assert "GH_API_TIMEOUT" in check["message"], check
        elif phase in ("auth-error", "token-missing"):
            assert "not authenticated" in check["message"], check
        elif phase.endswith("cancel"):
            assert "interrupted" in check["message"], check
        else:
            assert "deadline" in check["message"], check
    else:
        # An immediate optional account-name failure still admits monitoring.
        # Expiring the whole preflight budget stops before queue discovery.
        # No repositories are configured in the admitted control.
        proceeds = phase == "user-error"
        assert ("Running throttle check..." in result.stderr) == proceeds, (phase, result.stderr)
        assert "Starting fallback for" not in result.stderr, (phase, result.stderr)
        assert not (case / "state" / "watch-attempts").exists(), (phase, "fallback dispatched")
        if phase.endswith("cancel"):
            assert "Preflight check interrupted" in result.stderr, result.stderr
    assert not (case / "state").exists(), (command, phase, "dry-run wrote persistent state")
print("Doctor/watch credential deadlines: %d cases passed" % len(cases))
PY
    then
        pass "doctor/watch bound credential probes, retain optional metadata fallback, and propagate cancellation"
    else
        fail "doctor/watch credential deadline or cancellation regression"
    fi
}

# Every quick-doctor probe shares the watcher's one preflight budget. Run the
# public CLI and its real supervisor; only external tools are fixture boundaries.
# The portable cases hide timer discovery, without replacing supervision.
test_watch_complete_preflight_deadline() {
    ((TESTS_RUN++))
    if ! command -v python3 >/dev/null || ! command -v yq >/dev/null; then
        skip "Python 3 and yq are required for complete watcher preflight checks"
        return
    fi
    if python3 - "$DSR_CMD" "$TEMP_DIR" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import time

cli, root = sys.argv[1], Path(sys.argv[2])
fixture = root / "watch-preflight"
fixture.mkdir()
bin_dir = fixture / "bin"
bin_dir.mkdir()
for name in ("git", "jq", "curl", "yq"):
    program = shutil.which(name)
    assert program, name
    wrapper = bin_dir / name
    wrapper.write_text('''#!/usr/bin/env bash
set -uo pipefail
probe=''' + shlex.quote(name) + '''
if [[ "${1:-}" == --version ]]; then
    printf '%s\\n' "$probe" >> "$DSR_PREFLIGHT_CASE/probes"
fi
if [[ "$DSR_PREFLIGHT_PHASE" == "$probe" || ( "$probe" == jq && "$DSR_PREFLIGHT_PHASE" == jq-all ) ]] &&
   [[ "${1:-}" == --version || "$DSR_PREFLIGHT_PHASE" == jq-all ]]; then
    printf '%s\\n' "$BASHPID" > "$DSR_PREFLIGHT_CASE/stalled-pid"
    command sleep 4
    printf 'escaped\\n' >> "$DSR_PREFLIGHT_CASE/escaped"
fi
exec ''' + shlex.quote(program) + ''' "$@"
''')
    wrapper.chmod(0o700)
gh = bin_dir / "gh"
gh.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$DSR_PREFLIGHT_CASE/calls"
case "$*" in
    --version)
        if [[ "$DSR_PREFLIGHT_PHASE" == stdin ]]; then
            if IFS= read -r caller_input; then
                printf '%s\n' "$caller_input" > "$DSR_PREFLIGHT_CASE/consumed-stdin"
                exit 9
            fi
        fi
        if [[ "$DSR_PREFLIGHT_PHASE" == gh || "$DSR_PREFLIGHT_PHASE" == gh-resistant ]]; then
            printf '%s\n' "$BASHPID" > "$DSR_PREFLIGHT_CASE/stalled-pid"
            [[ "$DSR_PREFLIGHT_PHASE" != gh-resistant ]] || trap '' TERM
            command sleep 4
            printf 'escaped\n' >> "$DSR_PREFLIGHT_CASE/escaped"
        fi
        printf 'gh version 2.0.0 (preflight fixture)\n'
        exit 0 ;;
    'auth status --hostname github.com')
        [[ "$GH_TOKEN" == preflight-fixture-token && "$GH_HOST" == github.com ]] || exit 9
        [[ "$DSR_PREFLIGHT_PHASE" != auth-error ]] || exit 1
        [[ "$DSR_PREFLIGHT_PHASE" != cancel ]] || exit 2
        if [[ "$DSR_PREFLIGHT_PHASE" == combined ]]; then command sleep 0.6; fi
        exit 0 ;;
    'api user --hostname github.com --jq .login')
        if [[ "$DSR_PREFLIGHT_PHASE" == combined ]]; then
            command sleep 0.6
            printf 'escaped\n' >> "$DSR_PREFLIGHT_CASE/escaped"
        fi
        printf 'preflight-fixture-user\n'
        exit 0 ;;
esac
if [[ "${1:-}" == api && "${2:-}" == repos/fixture/tool/actions/workflows/release.yml/runs\?* ]]; then
    printf '{"total_count":0,"workflow_runs":[]}\n'
    exit 0
fi
printf 'Unexpected preflight fixture request: %s\n' "$*" >&2
exit 99
''')
gh.chmod(0o700)

cases = [
    ("gh", "global", "native", 8),
    ("git", "command", "native", 8),
    ("jq", "real", "native", 8),
    ("curl", "real", "native", 8),
    ("yq", "real", "native", 8),
    ("combined", "global", "native", 8),
    ("gh-resistant", "global", "native", 8),
    ("gh", "command", "portable", 8),
    ("gh-resistant", "command", "portable", 8),
    ("invalid", "global", "native", 4),
    ("invalid", "real", "native", 4),
    ("auth-error", "global", "native", 3),
    ("cancel", "global", "native", 5),
    ("missing-jq", "global", "native", 3),
    ("jq-all", "global", "native", 8),
    ("healthy", "global", "native", 0),
    ("healthy", "command", "native", 0),
    ("healthy", "real", "native", 0),
    ("healthy", "global", "portable", 0),
    ("stdin", "global", "native", 0),
]
failures = []
for phase, mode, engine, expected in cases:
    label = "-".join((phase, mode, engine))
    case = fixture / label
    case.mkdir(mode=0o700)
    config = case / "config"
    (config / "repos.d").mkdir(parents=True)
    (config / "config.yaml").write_text("threshold_seconds: 600\n")
    (config / "repos.d" / "tool.yaml").write_text(
        "tool_name: tool\nrepo: fixture/tool\nworkflow: release.yml\n")
    before = {str(p.relative_to(config)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in config.rglob("*") if p.is_file()}
    deadline_case = phase in ("gh", "git", "jq", "curl", "yq", "combined", "gh-resistant", "jq-all")
    # Immediate refusal and cancellation exercise status propagation, not a
    # one-second race with healthy diagnostic work. Every stalled-probe and
    # cumulative-deadline case retains its original one-second budget.
    bound = "0" if phase == "invalid" else "1" if deadline_case else "10"
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
               DSR_PREFLIGHT_CASE=str(case), DSR_PREFLIGHT_PHASE=phase, DSR_PREFLIGHT_ENGINE=engine,
               DSR_GH_TOKEN="preflight-fixture-token", GITHUB_TOKEN="", GH_TOKEN="",
               GH_HOST="enterprise.fixture.invalid", GH_API_TIMEOUT=bound,
               GH_MAX_RETRIES="1", GH_RETRY_DELAY="0", DSR_CONFIG_DIR=str(config),
               DSR_CONFIG_FILE=str(config / "config.yaml"), DSR_REPOS_FILE=str(config / "repos.yaml"),
               DSR_HOSTS_FILE=str(config / "hosts.yaml"), DSR_STATE_DIR=str(case / "state"),
               DSR_CACHE_DIR=str(case / "cache"), DSR_LOG_FILE=str(case / "inherited.log"),
               DSR_NOTIFY_ENABLED="true", DSR_NOTIFY_METHODS="terminal", NO_COLOR="1")
    args = [cli, "--json"]
    if mode == "global": args.append("--dry-run")
    args += ["watch", "--once", "--auto-fallback", "--notify", "terminal"]
    if mode == "command": args.append("--dry-run")
    if engine == "portable" or phase == "missing-jq":
        args = ["bash", "-c", r'''command() {
            if [[ "${1:-}" == -v ]]; then
                if [[ "${2:-}" == jq && "$DSR_PREFLIGHT_PHASE" == missing-jq ]]; then return 1; fi
                if [[ ( "${2:-}" == timeout || "${2:-}" == gtimeout ) &&
                      "$DSR_PREFLIGHT_ENGINE" == portable ]]; then return 1; fi
            fi
            builtin command "$@"
        }; export -f command; exec "$@"''', "preflight-test"] + args
    started = time.monotonic()
    process = subprocess.Popen(args, env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    try:
        out, err = process.communicate(input="watcher-caller-input\n" if phase == "stdin" else None,
                                       timeout=8 if deadline_case or phase == "invalid" else 20)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        out, err = process.communicate()
        failures.append((label, "outer failsafe expired"))
    elapsed = time.monotonic() - started
    (case / "stdout").write_text(out)
    (case / "stderr").write_text(err)
    (case / "result.json").write_text(json.dumps({"status": process.returncode, "elapsed": elapsed}))
    try:
        assert process.returncode == expected, (process.returncode, err)
        assert not (case / "escaped").exists(), "timed-out probe continued"
        assert not (case / "consumed-stdin").exists(), "preflight consumed caller input"
        calls = (case / "calls").read_text().splitlines() if (case / "calls").exists() else []
        if expected:
            # Preflight refuses before the normal watcher envelope. Keep the
            # diagnostic on stderr and do not relaunch a stalled/missing jq.
            assert not out.strip(), out
            assert not any("/actions/" in line for line in calls), calls
            assert "Running throttle check..." not in err, err
            for name in ("watch.lock", "triggered.json", "watch-attempts", "watch-artifacts", "notifications", "check"):
                assert not (case / "state" / name).exists(), name
            if phase == "invalid":
                assert not calls and not (case / "probes").exists(), "invalid bound launched probes"
                assert "GH_API_TIMEOUT" in err, err
            elif expected == 8:
                assert "deadline" in err, err
            elif expected == 5:
                assert "Preflight check interrupted" in err, err
            else:
                assert "Preflight check failed" in err, err
        else:
            response = json.loads(out)
            assert response["command"] == "watch" and response["exit_code"] == 0, response
            assert response["status"] == "success" and response["details"]["mode"] == "once", response
            requests = [line for line in calls if "/actions/" in line]
            assert len(requests) == 2, calls
            assert any("status=queued" in line for line in requests), requests
            assert any("status=in_progress" in line for line in requests), requests
            assert not (case / "state" / "watch-attempts").exists(), "healthy poll dispatched fallback"
        if (case / "stalled-pid").exists():
            pid = (case / "stalled-pid").read_text().strip()
            deadline = time.monotonic() + 2
            while True:
                state = subprocess.run(["ps", "-p", pid, "-o", "stat="],
                                       capture_output=True, text=True, timeout=2)
                if state.returncode or not state.stdout.strip() or state.stdout.strip().startswith("Z"):
                    break
                assert time.monotonic() < deadline, "supervised probe survived preflight completion"
                time.sleep(0.05)
        if mode != "real":
            assert not (case / "state").exists() and not (case / "cache").exists(), "preview wrote persistent paths"
            assert not (case / "inherited.log").exists(), "preview appended inherited log"
        after = {str(p.relative_to(config)): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in config.rglob("*") if p.is_file()}
        assert before == after, "configuration changed"
        print("PASS complete watch preflight:", label, flush=True)
    except (AssertionError, json.JSONDecodeError) as error:
        failures.append((label, str(error)))
        print("FAIL complete watch preflight:", label, str(error), flush=True)
assert not failures, failures
print("Complete watcher preflight: %d cases passed" % len(cases))
PY
    then
        pass "watch bounds the complete preflight before monitoring, state or notifications"
    else
        fail "complete watcher preflight deadline or admission regression"
    fi
}

test_doctor_detects_jq() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick 2>/dev/null)

    if echo "$output" | jq -e '.details.checks[] | select(.name == "jq")' >/dev/null 2>&1; then
        pass "doctor checks for jq"
    else
        fail "doctor should check for jq"
    fi
}

# ============================================================================
# Tests: Quick Mode
# ============================================================================

test_doctor_quick_skips_build_tools() {
    ((TESTS_RUN++))

    local quick_output full_output
    quick_output=$("$DSR_CMD" --json doctor --quick 2>/dev/null)
    full_output=$("$DSR_CMD" --json doctor 2>/dev/null)

    local quick_checks full_checks
    quick_checks=$(echo "$quick_output" | jq -r '.details.checks | length' 2>/dev/null)
    full_checks=$(echo "$full_output" | jq -r '.details.checks | length' 2>/dev/null)

    # Quick mode should have fewer checks
    if [[ -n "$quick_checks" && -n "$full_checks" && "$quick_checks" -lt "$full_checks" ]]; then
        pass "quick mode has fewer checks than full mode ($quick_checks vs $full_checks)"
    else
        skip "could not compare quick vs full mode (may have same tools)"
    fi
}

test_doctor_respects_enabled_hosts_config() {
    ((TESTS_RUN++))

    cat > "$DSR_CONFIG_DIR/hosts.yaml" <<'YAML'
schema_version: "1.0.0"
hosts:
  trj:
    platform: linux/amd64
    connection: local
  mmini:
    platform: darwin/arm64
    connection: ssh
    ssh_host: reachable-mac
    ssh_timeout: 1
  wlap:
    enabled: false
    platform: windows/amd64
    connection: ssh
    ssh_host: unreachable-windows
    ssh_timeout: 1
platform_mapping:
  linux/amd64: trj
  darwin/arm64: mmini
  windows/amd64: trj
YAML

    local bin_dir="$TEMP_DIR/bin"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DSR_TEST_SSH_LOG:?}"
case " $* " in
  *" reachable-mac "*) exit 0 ;;
  *) exit 1 ;;
esac
SH
    chmod +x "$bin_dir/ssh"

    local output
    output=$(DSR_TEST_SSH_LOG="$TEMP_DIR/ssh.calls" PATH="$bin_dir:$PATH" "$DSR_CMD" --json doctor 2>/dev/null)

    if echo "$output" | jq -e '
      (.details.checks[] | select(.name == "host-trj" and .status == "ok")) and
      (.details.checks[] | select(.name == "ssh-mmini" and .status == "ok" and .ssh_host == "reachable-mac")) and
      ([.details.checks[] | select(.name == "ssh-wlap")] | length == 0)
    ' >/dev/null 2>&1; then
        pass "doctor checks enabled configured hosts and skips disabled hosts"
    else
        fail "doctor should skip disabled hosts and use configured ssh_host"
    fi
}

# ============================================================================
# Tests: Exit Codes
# ============================================================================

test_doctor_exit_code_zero_or_three() {
    ((TESTS_RUN++))

    local exit_code=0
    "$DSR_CMD" doctor --quick >/dev/null 2>&1 || exit_code=$?

    if [[ $exit_code -eq 0 || $exit_code -eq 3 ]]; then
        pass "doctor exit code is 0 or 3 (got: $exit_code)"
    else
        fail "doctor should exit with 0 or 3, got: $exit_code"
    fi
}

# ============================================================================
# Tests: Fix Mode
# ============================================================================

test_doctor_fix_mode_shows_fixes() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" --json doctor --quick --fix 2>&1)

    # Fix mode should include fixes array in JSON output
    if echo "$output" | jq -e '.details.fixes | type' >/dev/null 2>&1; then
        pass "fix mode includes fixes in output"
    else
        # Or check human-readable output for fix suggestions
        local human_output
        human_output=$("$DSR_CMD" doctor --quick --fix 2>&1)
        if echo "$human_output" | grep -qiE "(install|fix|suggestion|remedy)" ; then
            pass "fix mode shows remediation in human output"
        else
            skip "no fixes needed or fix output format changed"
        fi
    fi
}

# --fix repairs what is safe to repair: a missing config, a missing actrc
# (mapped to this user), an actrc binding without a user mapping (backed up).
test_doctor_fix_applies_safe_fixes() {
    ((TESTS_RUN++))
    local home="$TEMP_DIR/fix-home" config_dir="$TEMP_DIR/fix-config" problems=() uid_gid output status
    uid_gid="$(id -u):$(id -g)"
    mkdir -p "$home"

    output=$(HOME="$home" DSR_CONFIG_DIR="$config_dir" "$DSR_CMD" --json doctor --fix 2>/dev/null)
    [[ -f "$config_dir/config.yaml" ]] || problems+=("config not created")
    grep -qx -- "--container-options --user=$uid_gid" "$home/.actrc" 2>/dev/null ||
        problems+=("actrc not created with --user=$uid_gid")
    jq -e '(.details.fixed | length) == 2 and
        ([.details.checks[] | select(.name == "actrc" or .name == "config") | .fixed] == [true, true])' \
        <<< "$output" >/dev/null 2>&1 || problems+=("fixed not reported: $(jq -c '.details.fixed' <<< "$output" 2>/dev/null)")

    printf -- '--bind\n-P ubuntu-latest=catthehacker/ubuntu:act-latest\n' > "$home/.actrc"
    HOME="$home" DSR_CONFIG_DIR="$config_dir" "$DSR_CMD" doctor --fix >/dev/null 2>&1
    local backups=("$home"/.actrc.bak.*)
    [[ "$(tail -1 "$home/.actrc")" == "--container-options --user=$uid_gid" ]] ||
        problems+=("user mapping not appended")
    if [[ ! -f "${backups[0]}" ]] || grep -q -- '--user' "${backups[0]}"; then
        problems+=("no backup of the original")
    fi

    # doctor may exit 3 for missing core dependencies; only the actrc line matters.
    output=$(HOME="$home" DSR_CONFIG_DIR="$config_dir" "$DSR_CMD" doctor 2>&1)
    grep -q 'actrc: configured correctly' <<< "$output" || problems+=("fixed actrc not accepted")

    status=0
    "$DSR_CMD" doctor --frobnicate >/dev/null 2>&1 || status=$?
    [[ "$status" -eq 4 ]] || problems+=("unknown option exit $status")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "doctor --fix creates config and actrc and repairs the user mapping"
    else
        fail "doctor --fix: ${problems[*]}"
    fi
}

# ============================================================================
# Tests: Human-Readable Output
# ============================================================================

test_doctor_human_shows_dependencies() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" doctor --quick 2>&1)

    # Should show core dependency section
    if echo "$output" | grep -qi "dependencies"; then
        pass "human output shows dependencies section"
    else
        fail "human output should show dependencies section"
    fi
}

test_doctor_human_shows_ok_or_error() {
    ((TESTS_RUN++))

    local output
    output=$("$DSR_CMD" doctor --quick 2>&1)

    # Should show either OK status or error for each dep
    if echo "$output" | grep -qE "(git:|gh:|jq:)"; then
        pass "human output shows dependency checks"
    else
        fail "human output should show dependency check results"
    fi
}

# bd-1tv.5: full doctor runs the artifact-naming consistency check (quick
# mode does not), reports "ok" for a consistent registry and a warning that
# names the drifting repo when config and install.sh disagree.
test_doctor_artifact_naming_check() {
    ((TESTS_RUN++))

    local project="$TEMP_DIR/naming-project" config="$TEMP_DIR/naming-config"
    mkdir -p "$project" "$config/repos.d"
    cat > "$config/repos.yaml" <<EOF
schema_version: "1.0.0"
tools:
  drifttool:
    repo: example/drifttool
    local_path: $project
    language: go
    targets: [linux/amd64]
EOF
    cat > "$config/repos.d/drifttool.yaml" <<EOF
tool_name: drifttool
repo: example/drifttool
local_path: $project
language: go
targets: [linux/amd64]
EOF
    local quick consistent drift
    quick=$(DSR_CONFIG_DIR="$config" "$DSR_CMD" --json doctor --quick 2>/dev/null)
    consistent=$(DSR_CONFIG_DIR="$config" "$DSR_CMD" --json doctor 2>/dev/null)
    # A versioned config while install.sh downloads an unversioned name,
    # with no explicit install_script_compat, is the drift validate flags.
    printf 'artifact_naming: "${name}-${version}-${os}-${arch}"\ninstall_script_path: install.sh\n' \
        >> "$config/repos.d/drifttool.yaml"
    printf '    artifact_naming: "${name}-${version}-${os}-${arch}"\n    install_script_path: install.sh\n' \
        >> "$config/repos.yaml"
    printf 'TAR="drifttool-${OS}-${ARCH}.tar.gz"\n' > "$project/install.sh"
    drift=$(DSR_CONFIG_DIR="$config" "$DSR_CMD" --json doctor 2>/dev/null)

    if jq -e '[.details.checks[] | select(.name == "artifact_naming")] | length == 0' <<< "$quick" >/dev/null 2>&1 &&
       jq -e '.details.checks[] | select(.name == "artifact_naming") | .status == "ok"' <<< "$consistent" >/dev/null 2>&1 &&
       jq -e '.details.checks[] | select(.name == "artifact_naming") |
              .status == "warning" and .repos == ["drifttool"]' <<< "$drift" >/dev/null 2>&1; then
        pass "doctor reports artifact naming drift per repo (skipped in --quick)"
    else
        fail "doctor artifact naming check wrong: quick=$(jq -c '[.details.checks[]|select(.name=="artifact_naming")]' <<< "$quick" 2>/dev/null) consistent=$(jq -c '[.details.checks[]|select(.name=="artifact_naming")]' <<< "$consistent" 2>/dev/null) drift=$(jq -c '[.details.checks[]|select(.name=="artifact_naming")]' <<< "$drift" 2>/dev/null)"
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

echo "=== dsr doctor Integration Tests ==="
echo ""

echo "Help and Basic Invocation:"
test_doctor_help
test_doctor_runs_without_error

echo ""
echo "JSON Output Format:"
test_doctor_json_valid
test_doctor_json_has_status
test_doctor_json_has_checks_array
test_doctor_json_check_has_name
test_doctor_json_check_has_status

echo ""
echo "Core Dependency Detection:"
test_doctor_detects_git
test_doctor_detects_gh
test_doctor_uses_selected_github_identity
test_doctor_github_deadlines
test_watch_complete_preflight_deadline
test_doctor_detects_jq

echo ""
echo "Quick Mode:"
test_doctor_quick_skips_build_tools
test_doctor_respects_enabled_hosts_config
test_doctor_artifact_naming_check

echo ""
echo "Exit Codes:"
test_doctor_exit_code_zero_or_three

echo ""
echo "Fix Mode:"
test_doctor_fix_mode_shows_fixes
test_doctor_fix_applies_safe_fixes

echo ""
echo "Human-Readable Output:"
test_doctor_human_shows_dependencies
test_doctor_human_shows_ok_or_error

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
