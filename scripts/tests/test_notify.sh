#!/usr/bin/env bash
# test_notify.sh - Unit tests for notify.sh module
#
# Tests notification system without mocks where possible.
# Uses fake binaries only when testing external integrations.
#
# Run: ./scripts/tests/test_notify.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the test harness
source "$PROJECT_ROOT/tests/helpers/test_harness.bash"

# Source the module under test
source "$PROJECT_ROOT/src/notify.sh"

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

# ============================================================================
# Helper: Setup test environment
# ============================================================================

setup_notify_test() {
    harness_setup

    # Override notification state directory
    _NOTIFY_STATE_DIR="$TEST_TMPDIR/notifications"
    _NOTIFY_SENT_FILE="$_NOTIFY_STATE_DIR/sent.jsonl"

    # Clear any env vars that might affect tests
    unset DSR_SLACK_WEBHOOK DSR_DISCORD_WEBHOOK DSR_AGENT_MAIL_HOOK
    export DSR_NOTIFY_METHODS="terminal"
}

teardown_notify_test() {
    harness_teardown
}

# ============================================================================
# Tests: notify_init
# ============================================================================

test_notify_init_creates_directory() {
    ((TESTS_RUN++))
    setup_notify_test

    if notify_init; then
        if [[ -d "$_NOTIFY_STATE_DIR" ]]; then
            pass "notify_init creates notification directory"
        else
            fail "notify_init should create notification directory"
        fi
    else
        fail "notify_init should succeed"
    fi

    teardown_notify_test
}

test_notify_init_idempotent() {
    ((TESTS_RUN++))
    setup_notify_test

    notify_init
    notify_init

    if [[ -d "$_NOTIFY_STATE_DIR" ]]; then
        pass "notify_init is idempotent"
    else
        fail "notify_init should be idempotent"
    fi

    teardown_notify_test
}

# ============================================================================
# Tests: notify_should_send and notify_mark_sent (deduplication)
# ============================================================================

test_should_send_new_event() {
    ((TESTS_RUN++))
    setup_notify_test
    notify_init

    if notify_should_send "run-123" "build_complete"; then
        pass "notify_should_send returns true for new event"
    else
        fail "notify_should_send should return true for new event"
    fi

    teardown_notify_test
}

test_should_send_after_mark_sent() {
    ((TESTS_RUN++))
    setup_notify_test
    notify_init

    notify_mark_sent "run-456" "build_complete"

    if ! notify_should_send "run-456" "build_complete"; then
        pass "notify_should_send returns false after mark_sent"
    else
        fail "notify_should_send should return false after mark_sent"
    fi

    teardown_notify_test
}

test_should_send_different_run_id() {
    ((TESTS_RUN++))
    setup_notify_test
    notify_init

    notify_mark_sent "run-111" "build_complete"

    if notify_should_send "run-222" "build_complete"; then
        pass "notify_should_send returns true for different run_id"
    else
        fail "notify_should_send should return true for different run_id"
    fi

    teardown_notify_test
}

test_should_send_different_event() {
    ((TESTS_RUN++))
    setup_notify_test
    notify_init

    notify_mark_sent "run-333" "build_complete"

    if notify_should_send "run-333" "release_complete"; then
        pass "notify_should_send returns true for different event"
    else
        fail "notify_should_send should return true for different event"
    fi

    teardown_notify_test
}

test_should_send_empty_run_id() {
    ((TESTS_RUN++))
    setup_notify_test
    notify_init

    # Empty run_id should always allow sending (no dedup)
    if notify_should_send "" "build_complete"; then
        pass "notify_should_send allows empty run_id"
    else
        fail "notify_should_send should allow empty run_id"
    fi

    teardown_notify_test
}

# ============================================================================
# Tests: _notify_json_escape
# ============================================================================

test_json_escape_quotes() {
    ((TESTS_RUN++))
    setup_notify_test

    local result
    result=$(_notify_json_escape 'Hello "World"')

    if [[ "$result" == 'Hello \"World\"' ]]; then
        pass "_notify_json_escape escapes quotes"
    else
        fail "_notify_json_escape should escape quotes (got: $result)"
    fi

    teardown_notify_test
}

test_json_escape_newlines() {
    ((TESTS_RUN++))
    setup_notify_test

    local result
    result=$(_notify_json_escape $'Hello\nWorld')

    if [[ "$result" == 'Hello\nWorld' ]]; then
        pass "_notify_json_escape escapes newlines"
    else
        fail "_notify_json_escape should escape newlines (got: $result)"
    fi

    teardown_notify_test
}

test_json_escape_backslashes() {
    ((TESTS_RUN++))
    setup_notify_test

    local result
    result=$(_notify_json_escape 'C:\path\to\file')

    if [[ "$result" == 'C:\\path\\to\\file' ]]; then
        pass "_notify_json_escape escapes backslashes"
    else
        fail "_notify_json_escape should escape backslashes (got: $result)"
    fi

    teardown_notify_test
}

# ============================================================================
# Tests: notify_event with terminal method
# ============================================================================

test_notify_event_terminal() {
    ((TESTS_RUN++))
    setup_notify_test
    export DSR_NOTIFY_METHODS="terminal"

    # Capture stderr
    local stderr_output
    stderr_output=$(notify_event "test_event" "info" "Test Title" "Test message" "run-001" 2>&1)

    if [[ "$stderr_output" == *"Test Title"* ]] && [[ "$stderr_output" == *"Test message"* ]]; then
        pass "notify_event terminal outputs title and message"
    else
        fail "notify_event terminal should output title and message"
        echo "stderr: $stderr_output"
    fi

    teardown_notify_test
}

test_notify_event_none_method() {
    ((TESTS_RUN++))
    setup_notify_test
    export DSR_NOTIFY_METHODS="none"

    # Should produce no output
    local stderr_output
    stderr_output=$(notify_event "test_event" "info" "Test Title" "Test message" "run-002" 2>&1)

    if [[ -z "$stderr_output" ]]; then
        pass "notify_event with 'none' produces no output"
    else
        fail "notify_event with 'none' should produce no output"
        echo "stderr: $stderr_output"
    fi

    teardown_notify_test
}

test_notify_event_dedup() {
    ((TESTS_RUN++))
    setup_notify_test
    export DSR_NOTIFY_METHODS="terminal"

    # First send
    notify_event "test_event" "info" "Title" "Message" "run-dup" >/dev/null 2>&1

    # Second send should be deduped
    local stderr_output
    stderr_output=$(notify_event "test_event" "info" "Title" "Message" "run-dup" 2>&1)

    if [[ "$stderr_output" == *"already sent"* ]]; then
        pass "notify_event deduplicates by run_id+event"
    else
        fail "notify_event should deduplicate by run_id+event"
        echo "stderr: $stderr_output"
    fi

    teardown_notify_test
}

test_notify_event_marks_sent() {
    ((TESTS_RUN++))
    setup_notify_test
    export DSR_NOTIFY_METHODS="terminal"

    notify_event "build_done" "success" "Build" "Complete" "run-mark" >/dev/null 2>&1

    # Check that it was recorded
    if [[ -f "$_NOTIFY_SENT_FILE" ]] && grep -q "run-mark" "$_NOTIFY_SENT_FILE"; then
        pass "notify_event marks notification as sent"
    else
        fail "notify_event should mark notification as sent"
    fi

    teardown_notify_test
}

# ============================================================================
# Tests: Slack notifications (mock webhook)
# ============================================================================

test_notify_slack_missing_webhook() {
    ((TESTS_RUN++))
    setup_notify_test
    unset DSR_SLACK_WEBHOOK

    local stderr_output
    stderr_output=$(_notify_slack "Title" "Message" 2>&1)
    local status=$?

    if [[ "$status" -ne 0 ]] && [[ "$stderr_output" == *"not configured"* ]]; then
        pass "_notify_slack fails without webhook configured"
    else
        fail "_notify_slack should fail without webhook (status: $status)"
        echo "stderr: $stderr_output"
    fi

    teardown_notify_test
}

test_notify_slack_with_mock_curl() {
    ((TESTS_RUN++))
    setup_notify_test

    # Create mock curl that records what it received
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/curl" << 'SCRIPT'
#!/usr/bin/env bash
# Record the payload
echo "$@" > /tmp/curl_args_$$
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/curl"

    export DSR_SLACK_WEBHOOK="https://hooks.slack.com/test/webhook"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if _notify_slack "Test Title" "Test Message"; then
        pass "_notify_slack succeeds with configured webhook"
    else
        fail "_notify_slack should succeed with configured webhook"
    fi

    teardown_notify_test
}

test_notify_webhook_http_error_is_retried() {
    ((TESTS_RUN++))
    setup_notify_test

    # Behaves like curl: an HTTP 404 from a revoked webhook exits 0 unless
    # --fail is given (then 22). Every call is recorded.
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/curl" << SCRIPT
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_TMPDIR/curl.calls"
if [[ "\$*" == *revoked* ]]; then
    [[ " \$* " == *" --fail "* ]] && exit 22
    exit 0
fi
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/curl"
    local problems=() stderr_output

    PATH="$TEST_TMPDIR/bin:$PATH" DSR_NOTIFY_METHODS=slack \
        DSR_SLACK_WEBHOOK="https://hooks.slack.com/services/revoked" \
        bash -c 'source "$1"; _NOTIFY_STATE_DIR="$2"; _NOTIFY_SENT_FILE="$2/sent.jsonl"
            notify_event e1 warn T M run-1; notify_event e1 warn T M run-1' \
        _ "$PROJECT_ROOT/src/notify.sh" "$TEST_TMPDIR/notifications" 2> "$TEST_TMPDIR/err.txt"
    stderr_output=$(cat "$TEST_TMPDIR/err.txt")
    [[ "$(grep -c revoked "$TEST_TMPDIR/curl.calls")" -eq 2 ]] ||
        problems+=("failed delivery suppressed the retry ($(grep -c revoked "$TEST_TMPDIR/curl.calls") posts)")
    [[ "$stderr_output" == *"Slack notification failed"* ]] || problems+=("no failure warning")
    grep -q -- "--max-time" "$TEST_TMPDIR/curl.calls" || problems+=("no --max-time")

    PATH="$TEST_TMPDIR/bin:$PATH" DSR_NOTIFY_METHODS=slack \
        DSR_SLACK_WEBHOOK="https://hooks.slack.com/services/working" \
        bash -c 'source "$1"; _NOTIFY_STATE_DIR="$2"; _NOTIFY_SENT_FILE="$2/sent.jsonl"
            notify_event e2 warn T M run-1; notify_event e2 warn T M run-1' \
        _ "$PROJECT_ROOT/src/notify.sh" "$TEST_TMPDIR/notifications" 2>/dev/null
    [[ "$(grep -c working "$TEST_TMPDIR/curl.calls")" -eq 1 ]] ||
        problems+=("delivered event was not deduplicated")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "a webhook HTTP error is a failed delivery and is retried; a delivered event is sent once"
    else
        fail "webhook failure handling: ${problems[*]}"
    fi

    teardown_notify_test
}

test_webhooks_from_config_notifications() {
    ((TESTS_RUN++))
    setup_notify_test

    if ! command -v yq &>/dev/null; then
        skip "yq required for nested config keys"
        teardown_notify_test
        return 0
    fi
    mkdir -p "$TEST_TMPDIR/cfg"
    cat > "$TEST_TMPDIR/cfg/config.yaml" << 'YAML'
schema_version: "1.0.0"
notifications:
  slack_webhook: "https://hooks.slack.com/services/T000/B000/cfg"
  discord_webhook: "https://discord.com/api/webhooks/1/cfg"
YAML
    local got
    got=$(env -u DSR_SLACK_WEBHOOK -u DSR_DISCORD_WEBHOOK DSR_CONFIG_DIR="$TEST_TMPDIR/cfg" \
        DSR_CONFIG_FILE="$TEST_TMPDIR/cfg/config.yaml" bash -c '
            source "$1/src/logging.sh"; source "$1/src/config.sh"; source "$1/src/secrets.sh"
            secrets_get_slack_webhook; secrets_get_discord_webhook
            DSR_SLACK_WEBHOOK=https://hooks.slack.com/services/T1/B1/env secrets_get_slack_webhook' \
        _ "$PROJECT_ROOT" 2>/dev/null)

    if [[ "$got" == $'https://hooks.slack.com/services/T000/B000/cfg\nhttps://discord.com/api/webhooks/1/cfg\nhttps://hooks.slack.com/services/T1/B1/env' ]]; then
        pass "webhooks come from config notifications.* unless the environment sets them"
    else
        fail "config notifications webhooks not used: $got"
    fi

    teardown_notify_test
}

# ============================================================================
# Tests: Discord notifications (mock webhook)
# ============================================================================

test_notify_discord_missing_webhook() {
    ((TESTS_RUN++))
    setup_notify_test
    unset DSR_DISCORD_WEBHOOK

    local stderr_output
    stderr_output=$(_notify_discord "Title" "Message" 2>&1)
    local status=$?

    if [[ "$status" -ne 0 ]] && [[ "$stderr_output" == *"not configured"* ]]; then
        pass "_notify_discord fails without webhook configured"
    else
        fail "_notify_discord should fail without webhook (status: $status)"
        echo "stderr: $stderr_output"
    fi

    teardown_notify_test
}

# ============================================================================
# Tests: Desktop notifications
# ============================================================================

test_notify_desktop_linux() {
    ((TESTS_RUN++))
    setup_notify_test

    # Create mock notify-send
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/notify-send" << 'SCRIPT'
#!/usr/bin/env bash
echo "notify-send: $*" >&2
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/notify-send"

    # Remove osascript from PATH if present
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if _notify_desktop "Test Title" "Test Message" 2>/dev/null; then
        pass "_notify_desktop succeeds with notify-send"
    else
        fail "_notify_desktop should succeed with notify-send"
    fi

    teardown_notify_test
}

test_notify_desktop_missing_tools() {
    ((TESTS_RUN++))
    setup_notify_test

    # Save original PATH before modification
    local saved_path="$PATH"

    # Create a PATH with no osascript or notify-send
    mkdir -p "$TEST_TMPDIR/empty_bin"
    export PATH="$TEST_TMPDIR/empty_bin"

    local stderr_output
    stderr_output=$(_notify_desktop "Title" "Message" 2>&1)
    local status=$?

    # Restore PATH before any further operations
    export PATH="$saved_path"

    if [[ "$status" -ne 0 ]] && [[ "$stderr_output" == *"not available"* ]]; then
        pass "_notify_desktop fails when tools missing"
    else
        fail "_notify_desktop should fail when tools missing (status: $status)"
        echo "stderr: $stderr_output"
    fi

    teardown_notify_test
}

# ============================================================================
# Tests: Agent Mail hook
# ============================================================================

test_notify_agent_mail_missing_hook() {
    ((TESTS_RUN++))
    setup_notify_test
    unset DSR_AGENT_MAIL_HOOK

    local stderr_output
    stderr_output=$(_notify_agent_mail '{"test": "payload"}' 2>&1)
    local status=$?

    if [[ "$status" -ne 0 ]] && [[ "$stderr_output" == *"not configured"* ]]; then
        pass "_notify_agent_mail fails without hook configured"
    else
        fail "_notify_agent_mail should fail without hook (status: $status)"
        echo "stderr: $stderr_output"
    fi

    teardown_notify_test
}

test_notify_agent_mail_with_hook() {
    ((TESTS_RUN++))
    setup_notify_test

    # Create hook script
    local hook_script="$TEST_TMPDIR/agent_mail_hook.sh"
    cat > "$hook_script" << 'SCRIPT'
#!/usr/bin/env bash
cat > /tmp/agent_mail_payload_$$
exit 0
SCRIPT
    chmod +x "$hook_script"

    export DSR_AGENT_MAIL_HOOK="$hook_script"

    if _notify_agent_mail '{"event":"test"}'; then
        pass "_notify_agent_mail succeeds with configured hook"
    else
        fail "_notify_agent_mail should succeed with configured hook"
    fi

    teardown_notify_test
}

test_notify_agent_mail_non_executable_hook() {
    ((TESTS_RUN++))
    setup_notify_test

    # Create non-executable hook
    local hook_script="$TEST_TMPDIR/non_exec_hook.sh"
    echo "#!/bin/bash" > "$hook_script"
    # Intentionally NOT chmod +x

    export DSR_AGENT_MAIL_HOOK="$hook_script"

    local stderr_output
    stderr_output=$(_notify_agent_mail '{"test": "payload"}' 2>&1)
    local status=$?

    if [[ "$status" -ne 0 ]] && [[ "$stderr_output" == *"not executable"* ]]; then
        pass "_notify_agent_mail fails with non-executable hook"
    else
        fail "_notify_agent_mail should fail with non-executable hook (status: $status)"
        echo "stderr: $stderr_output"
    fi

    teardown_notify_test
}

# ============================================================================
# Tests: notify_event with multiple methods
# ============================================================================

test_notify_event_all_method() {
    ((TESTS_RUN++))
    setup_notify_test

    # Set up mocks for all methods
    mkdir -p "$TEST_TMPDIR/bin"

    # Mock notify-send for desktop
    cat > "$TEST_TMPDIR/bin/notify-send" << 'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/notify-send"

    # Mock curl for slack/discord
    cat > "$TEST_TMPDIR/bin/curl" << 'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/curl"

    export PATH="$TEST_TMPDIR/bin:$PATH"
    export DSR_NOTIFY_METHODS="all"
    export DSR_SLACK_WEBHOOK="https://hooks.slack.com/test"
    export DSR_DISCORD_WEBHOOK="https://discord.com/test"

    # Create agent mail hook
    local hook_script="$TEST_TMPDIR/am_hook.sh"
    cat > "$hook_script" << 'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
    chmod +x "$hook_script"
    export DSR_AGENT_MAIL_HOOK="$hook_script"

    local stderr_output
    stderr_output=$(notify_event "multi_test" "info" "Title" "Message" "run-multi" 2>&1)

    # Should succeed (no error about unknown method)
    if [[ "$stderr_output" != *"Unknown notify method"* ]]; then
        pass "notify_event 'all' sends to multiple channels"
    else
        fail "notify_event 'all' should send to multiple channels"
        echo "stderr: $stderr_output"
    fi

    teardown_notify_test
}

test_notify_event_comma_separated() {
    ((TESTS_RUN++))
    setup_notify_test

    export DSR_NOTIFY_METHODS="terminal,desktop"

    # Mock notify-send
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/notify-send" << 'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/notify-send"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    local stderr_output
    stderr_output=$(notify_event "comma_test" "info" "Title" "Message" "run-comma" 2>&1)

    # Should include terminal output
    if [[ "$stderr_output" == *"Title"* ]]; then
        pass "notify_event processes comma-separated methods"
    else
        fail "notify_event should process comma-separated methods"
        echo "stderr: $stderr_output"
    fi

    teardown_notify_test
}

# Exercise the public notification boundary with actual helper processes and
# the production process-group supervisor. The executables are explicit local
# adapters; no notification is sent to a real service or desktop session.
test_notify_delivery_deadlines() {
    ((TESTS_RUN++))
    setup_notify_test
    if ! command -v python3 >/dev/null; then
        skip "Python 3 is required for notification deadline regressions"
        teardown_notify_test
        return
    fi
    if python3 -I - "$PROJECT_ROOT" "$TEST_TMPDIR" <<'PY'
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

project, root = map(Path, sys.argv[1:])
root = root / "delivery-deadlines"
root.mkdir()
shell = shutil.which("bash")
programs = {name: shutil.which(name) for name in
            ("bash", "cat", "date", "dirname", "grep", "jq", "mkdir", "sleep")}
assert all(programs.values()), programs
adapter = r'''#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$DSR_NOTIFY_TEST_PHASE" >> "$DSR_NOTIFY_TEST_CASE/calls"
case "$DSR_NOTIFY_TEST_PHASE" in
    stalled)
        printf 'started\n' > "$DSR_NOTIFY_TEST_CASE/started"
        sleep 3
        printf 'escaped\n' > "$DSR_NOTIFY_TEST_CASE/escaped"
        ;;
    descendant)
        bash -c 'printf "started\n" > "$DSR_NOTIFY_TEST_CASE/child";
            sleep 3; printf "escaped\n" > "$DSR_NOTIFY_TEST_CASE/escaped"' &
        while [[ ! -f "$DSR_NOTIFY_TEST_CASE/child" ]]; do sleep 0.02; done
        ;;
    healthy)
        if [[ "$DSR_NOTIFY_METHODS" == agent_mail ]]; then
            cat > "$DSR_NOTIFY_TEST_CASE/payload.json"
        fi
        ;;
    *) exit 17 ;;
esac
'''
driver = r'''
source "$1/src/notify.sh" || exit $?
if [[ "$DSR_NOTIFY_TEST_PHASE" == resolver ]]; then
    secrets_get_slack_webhook() {
        printf 'started\n' > "$DSR_NOTIFY_TEST_CASE/started"
        sleep 3
        printf 'escaped\n' > "$DSR_NOTIFY_TEST_CASE/escaped"
        printf 'https://fixture.invalid/slack\n'
    }
fi
notify_event build.done info 'Release title' 'Release message' notification-deadline
'''

def make_case(name, method, executable):
    case = root / name
    case.mkdir()
    binaries = case / "bin"
    binaries.mkdir()
    for program, source in programs.items():
        (binaries / program).symlink_to(source)
    helper = binaries / executable
    helper.write_text(adapter)
    helper.chmod(0o700)
    env = {key: value for key, value in os.environ.items() if not key.startswith("BASH_FUNC_")}
    env.update(PATH=str(binaries), DSR_STATE_DIR=str(case / "state"),
               DSR_NOTIFY_TEST_CASE=str(case), DSR_NOTIFY_METHODS=method,
               DSR_NOTIFY_TIMEOUT="1", DSR_AGENT_MAIL_HOOK=str(helper),
               DSR_SLACK_WEBHOOK="https://fixture.invalid/slack",
               DSR_DISCORD_WEBHOOK="https://fixture.invalid/discord")
    return case, env

def invoke(case, env, phase):
    env = dict(env, DSR_NOTIFY_TEST_PHASE=phase)
    started = time.monotonic()
    child = subprocess.Popen([shell, "-c", driver, "notification-test", str(project)],
                             env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, start_new_session=True)
    try:
        stdout, stderr = child.communicate(timeout=8)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        stdout, stderr = child.communicate()
        raise AssertionError((case.name, "notification outlived the independent 8s guard", stderr))
    (case / (phase + ".stdout")).write_text(stdout)
    (case / (phase + ".stderr")).write_text(stderr)
    assert child.returncode == 0, (case.name, phase, child.returncode, stderr)
    assert stdout == "", (case.name, phase, stdout)
    return time.monotonic() - started

def sent(case):
    path = case / "state" / "notifications" / "sent.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

passed = 0
failed = []
def check(name, operation):
    global passed
    try:
        operation()
        passed += 1
        print("PASS notification deadline:", name, flush=True)
    except (AssertionError, OSError, ValueError) as error:
        failed.append(name)
        print("FAIL notification deadline:", name, repr(error), flush=True)

for method, executable in (("agent_mail", "notification-hook"), ("desktop", "notify-send"),
                           ("desktop", "osascript"), ("slack", "curl"), ("discord", "curl")):
    for phase in ("healthy", "stalled"):
        name = method + "-" + executable + "-" + phase
        def probe(name=name, method=method, executable=executable, phase=phase):
            case, env = make_case(name, method, executable)
            invoke(case, env, phase)
            assert (case / "calls").read_text() == phase + "\n", name
            assert not (case / "escaped").exists(), (name, "helper continued past its deadline")
            assert len(sent(case)) == (1 if phase == "healthy" else 0), (name, sent(case))
            if phase == "stalled":
                assert (case / "started").read_text() == "started\n", name
            elif method == "agent_mail":
                payload = json.loads((case / "payload.json").read_text())
                assert payload["event"] == "build.done" and payload["title"] == "Release title", payload
        check(name, probe)

for bound in ("0", "-1", "unlimited", "1000000"):
    def invalid(bound=bound):
        case, env = make_case("invalid-" + bound, "agent_mail", "notification-hook")
        env["DSR_NOTIFY_TIMEOUT"] = bound
        invoke(case, env, "healthy")
        assert not (case / "calls").exists(), (bound, "invalid deadline still launched delivery")
        assert not sent(case), (bound, sent(case))
    check("invalid deadline " + bound, invalid)

def retry():
    case, env = make_case("retry", "agent_mail", "notification-hook")
    invoke(case, env, "stalled")
    assert not sent(case) and not (case / "escaped").exists(), case
    invoke(case, env, "healthy")
    invoke(case, env, "healthy")
    assert (case / "calls").read_text() == "stalled\nhealthy\n", case
    assert len(sent(case)) == 1, sent(case)
check("timeout remains retryable and successful retry is deduplicated", retry)

def resolver():
    case, env = make_case("resolver", "slack", "curl")
    invoke(case, env, "resolver")
    assert (case / "started").read_text() == "started\n", case
    assert not (case / "escaped").exists() and not (case / "calls").exists(), case
    assert not sent(case), sent(case)
check("channel deadline includes webhook resolution", resolver)

def descendants():
    case, env = make_case("descendants", "agent_mail", "notification-hook")
    invoke(case, env, "descendant")
    assert (case / "child").read_text() == "started\n", case
    time.sleep(3.2)
    assert not (case / "escaped").exists(), "successful helper left a live descendant"
    assert len(sent(case)) == 1, sent(case)
check("successful helper completion retires its descendants", descendants)

print("Notification deadline controls: %d passed, %d failed" % (passed, len(failed)))
sys.exit(bool(failed))
PY
    then
        pass "notification deadlines preserve progress, retries, payloads and descendant cleanup"
    else
        fail "notification deadline or delivery regression"
    fi
    teardown_notify_test
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    harness_teardown 2>/dev/null || true
}
trap cleanup EXIT

if [[ "${1:-}" == --delivery-deadlines-only ]]; then
    test_notify_delivery_deadlines
    [[ $TESTS_FAILED -eq 0 && $TESTS_PASSED -eq 1 ]] && exit 0 || exit 1
fi

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== Unit Tests: notify.sh ==="
echo ""

echo "Init Tests:"
test_notify_init_creates_directory
test_notify_init_idempotent

echo ""
echo "Deduplication Tests:"
test_should_send_new_event
test_should_send_after_mark_sent
test_should_send_different_run_id
test_should_send_different_event
test_should_send_empty_run_id

echo ""
echo "JSON Escape Tests:"
test_json_escape_quotes
test_json_escape_newlines
test_json_escape_backslashes

echo ""
echo "Terminal Notification Tests:"
test_notify_event_terminal
test_notify_event_none_method
test_notify_event_dedup
test_notify_event_marks_sent

echo ""
echo "Slack Tests:"
test_notify_slack_missing_webhook
test_notify_slack_with_mock_curl
test_notify_webhook_http_error_is_retried
test_webhooks_from_config_notifications

echo ""
echo "Discord Tests:"
test_notify_discord_missing_webhook

echo ""
echo "Desktop Tests:"
test_notify_desktop_linux
test_notify_desktop_missing_tools

echo ""
echo "Agent Mail Tests:"
test_notify_agent_mail_missing_hook
test_notify_agent_mail_with_hook
test_notify_agent_mail_non_executable_hook

echo ""
echo "Multiple Methods Tests:"
test_notify_event_all_method
test_notify_event_comma_separated
test_notify_delivery_deadlines

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
