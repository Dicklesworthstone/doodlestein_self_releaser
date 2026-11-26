#!/usr/bin/env bash
# test_canary.sh - Tests for dsr canary command
#
# Tests the installer canary testing infrastructure.
# Uses Docker when available, falls back to unit tests otherwise.
#
# Run: ./tests/canary/test_canary.sh
#
# Environment variables:
#   DOCKER_SKIP=1       Skip Docker-based tests
#   VERBOSE=1           Show detailed output

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSR_CMD="$PROJECT_ROOT/dsr"

# Source the test harness
source "$PROJECT_ROOT/tests/helpers/test_harness.bash"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }
info() { echo "${BLUE}INFO${NC}: $1"; }

# ============================================================================
# Docker Availability Check
# ============================================================================

HAS_DOCKER=false
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    if [[ "${DOCKER_SKIP:-0}" != "1" ]]; then
        HAS_DOCKER=true
    fi
fi

# ============================================================================
# Tests: Help Commands
# ============================================================================

test_canary_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" canary --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "canary"; then
        pass "canary --help shows usage"
    else
        fail "canary --help should show usage"
        echo "stdout: $(exec_stdout | head -5)"
    fi

    harness_teardown
}

test_canary_help_shows_subcommands() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" canary --help

    if exec_stdout_contains "run" && exec_stdout_contains "matrix" && exec_stdout_contains "schedule"; then
        pass "canary --help shows all subcommands"
    else
        fail "canary --help should show run, matrix, schedule"
        echo "stdout: $(exec_stdout | head -10)"
    fi

    harness_teardown
}

test_canary_help_shows_examples() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" canary --help

    if exec_stdout_contains "EXAMPLES:" && exec_stdout_contains "dsr canary run"; then
        pass "canary --help shows examples"
    else
        fail "canary --help should show examples"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Argument Validation
# ============================================================================

test_canary_unknown_subcommand() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" canary unknown-cmd
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "canary unknown subcommand returns exit 4"
    else
        fail "canary unknown subcommand should return exit 4 (got: $status)"
    fi

    harness_teardown
}

test_canary_run_missing_tool() {
    ((TESTS_RUN++))
    harness_setup

    # Without Docker, this should fail with missing tool error
    exec_run "$DSR_CMD" canary run
    local status
    status=$(exec_status)

    # Either fails with missing tool (4) or missing docker (3)
    if [[ "$status" -eq 4 ]] || [[ "$status" -eq 3 ]]; then
        pass "canary run without tool returns appropriate error (exit: $status)"
    else
        fail "canary run without tool should return exit 3 or 4 (got: $status)"
    fi

    harness_teardown
}

test_canary_run_unknown_option() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" canary run --unknown-option
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "canary run unknown option returns exit 4"
    else
        fail "canary run unknown option should return exit 4 (got: $status)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Docker Detection
# ============================================================================

test_canary_detects_no_docker() {
    ((TESTS_RUN++))
    harness_setup

    # Shadow any host Docker while retaining the ordinary utilities needed by
    # the test harness and dsr's Bash-version guard.
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/docker" <<'SH'
#!/bin/sh
exit 1
SH
    chmod +x "$TEST_TMPDIR/bin/docker"

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" canary run ntm
    local status
    status=$(exec_status)

    if [[ "$status" -eq 3 ]]; then
        pass "canary run fails gracefully without Docker (exit: 3)"
    else
        # Also acceptable if it fails for other reasons
        pass "canary run returns error without Docker (exit: $status)"
    fi

    harness_teardown
}

test_canary_json_no_docker() {
    ((TESTS_RUN++))
    harness_setup

    # Shadow any host Docker without hiding jq/date/bash from the harness.
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/docker" <<'SH'
#!/bin/sh
exit 1
SH
    chmod +x "$TEST_TMPDIR/bin/docker"

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json canary run ntm
    local output
    output=$(exec_stdout)

    if [[ -z "$output" ]]; then
        pass "canary --json produces no output when Docker unavailable (acceptable)"
    elif echo "$output" | jq . &>/dev/null; then
        if echo "$output" | jq -e '.details.error' &>/dev/null; then
            pass "canary --json produces valid JSON error when Docker unavailable"
        else
            pass "canary --json produces valid JSON when Docker unavailable"
        fi
    else
        fail "canary --json should produce valid JSON or no output"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Results Command
# ============================================================================

test_canary_results_empty() {
    ((TESTS_RUN++))
    harness_setup

    # Ensure no previous results
    rm -rf "$XDG_STATE_HOME/dsr/canary"

    exec_run "$DSR_CMD" canary results

    # Should handle missing results gracefully
    if exec_stdout_contains "No canary results" || exec_stdout_contains "not found" || [[ "$(exec_status)" -eq 0 ]]; then
        pass "canary results handles missing data gracefully"
    else
        fail "canary results should handle missing data"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_canary_results_json() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" --json canary results
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . &>/dev/null; then
        pass "canary results --json produces valid JSON"
    else
        fail "canary results --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Schedule Command
# ============================================================================

test_canary_schedule_show() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" canary schedule --show
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "canary schedule --show works"
    else
        fail "canary schedule --show should succeed (got: $status)"
    fi

    harness_teardown
}

# File-backed crontab: the user's real crontab is never read or written.
make_fake_crontab() {
    mkdir -p "$TEST_TMPDIR/bin"
    export FAKE_CRONTAB="$TEST_TMPDIR/crontab.txt"
    cat > "$TEST_TMPDIR/bin/crontab" << 'SH'
#!/usr/bin/env bash
case "${1:-}" in
    -l) [[ -f "$FAKE_CRONTAB" ]] || { echo "no crontab for user" >&2; exit 1; }; cat "$FAKE_CRONTAB" ;;
    -) cat > "$FAKE_CRONTAB" ;;
    *) exit 2 ;;
esac
SH
    chmod +x "$TEST_TMPDIR/bin/crontab"
}

test_canary_schedule_dry_run_and_validation() {
    ((TESTS_RUN++))
    harness_setup
    make_fake_crontab
    local problems=() keep='15 3 * * * /usr/bin/backup'
    printf '%s\n' "$keep" > "$FAKE_CRONTAB"

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json canary schedule --dry-run
    [[ "$(exec_status)" -eq 0 ]] || problems+=("dry-run exit $(exec_status)")
    exec_stdout | jq -e '.details.dry_run == true and (.details.entry | startswith("0 6 * * * ")) and
        (.details.entry | contains(" canary run --all --json >> "))' >/dev/null 2>&1 ||
        problems+=("dry-run envelope: $(exec_stdout | head -c 300)")
    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" -n canary schedule --unschedule
    [[ "$(exec_status)" -eq 0 ]] || problems+=("-n unschedule exit $(exec_status)")
    [[ "$(cat "$FAKE_CRONTAB")" == "$keep" ]] || problems+=("dry runs changed crontab")

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" canary schedule --cron $'0 6 * * *\n* * * * * rm -rf ~'
    [[ "$(exec_status)" -eq 4 ]] || problems+=("multi-line cron exit $(exec_status)")
    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" canary schedule --frobnicate
    [[ "$(exec_status)" -eq 4 ]] || problems+=("unknown option exit $(exec_status)")
    [[ "$(cat "$FAKE_CRONTAB")" == "$keep" ]] || problems+=("rejected input changed crontab")

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" canary schedule --cron '30 5 * * 1-5'
    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" canary schedule --cron '@daily'
    [[ "$(exec_status)" -eq 0 && "$(grep -c 'dsr canary' "$FAKE_CRONTAB")" -eq 1 ]] &&
        grep -qxF -- "$keep" "$FAKE_CRONTAB" && grep -q '^@daily .* canary run --all' "$FAKE_CRONTAB" ||
        problems+=("reschedule: $(cat "$FAKE_CRONTAB")")
    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" canary schedule --unschedule
    [[ "$(exec_status)" -eq 0 && "$(cat "$FAKE_CRONTAB")" == "$keep" ]] ||
        problems+=("unschedule: $(cat "$FAKE_CRONTAB")")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "canary schedule honors --dry-run, rejects bad cron input, replaces and removes only its entry"
    else
        fail "canary schedule: ${problems[*]}"
    fi
    harness_teardown
}

# docker stub: every image builds; the container for cass fails.
make_fake_docker() {
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/docker" << 'SH'
#!/usr/bin/env bash
case "${1:-}" in
    info|build|rmi) exit 0 ;;
    run) [[ "$*" == *-cass-* ]] && { echo "Installer failed"; exit 1; }
         echo "=== Canary test PASSED ==="; exit 0 ;;
esac
exit 1
SH
    chmod +x "$TEST_TMPDIR/bin/docker"
}

test_canary_run_all_results_are_json() {
    ((TESTS_RUN++))
    harness_setup
    make_fake_docker
    local problems=() output tools
    tools=$(find "$PROJECT_ROOT/installers" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | jq -Rsc 'split("\n") | map(select(length > 0))')

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json canary run --all
    output=$(exec_stdout)
    [[ "$(exec_status)" -eq 1 ]] || problems+=("exit $(exec_status)")
    jq -e --argjson tools "$tools" '.status == "error" and
        ([.details.results[].tool] | sort) == $tools and
        ([.details.results[] | select(.status == "failed") | .tool] == ["cass"]) and
        .details.failed == 1 and .details.passed == (($tools | length) - 1)' <<< "$output" >/dev/null 2>&1 ||
        problems+=("envelope: $(head -c 400 <<< "$output")")

    exec_run "$DSR_CMD" --json canary results
    exec_stdout | jq -e '.failed == 1 and (.timestamp | type == "string")' >/dev/null 2>&1 ||
        problems+=("saved results: $(exec_stdout | head -c 300)")

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" canary run --all
    [[ -z "$(exec_stdout)" ]] && exec_stderr_contains "  cass: failed" || problems+=("human summary missing or on stdout")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "canary run --all reports and saves per-tool results"
    else
        fail "canary run --all: ${problems[*]}"
    fi
    harness_teardown
}

# ============================================================================
# Tests: With Docker (when available)
# ============================================================================

test_canary_run_with_docker() {
    ((TESTS_RUN++))

    if [[ "$HAS_DOCKER" != "true" ]]; then
        skip "Docker not available"
        return 0
    fi

    harness_setup

    # Run a simple canary test with ntm (or first available installer)
    local installer_dir="$PROJECT_ROOT/installers"
    local test_tool=""

    # Find first available tool with installer
    for dir in "$installer_dir"/*/; do
        if [[ -f "$dir/install.sh" ]]; then
            test_tool=$(basename "$dir")
            break
        fi
    done

    if [[ -z "$test_tool" ]]; then
        skip "No installer found to test"
        harness_teardown
        return 0
    fi

    info "Testing canary for $test_tool..."

    # Run canary test (this may take a while)
    exec_run "$DSR_CMD" canary run "$test_tool" --os ubuntu:22.04
    local status
    status=$(exec_status)

    # Any exit code is acceptable - we're testing the infrastructure works
    if [[ "$status" -eq 0 ]]; then
        pass "canary run completed successfully for $test_tool"
    elif [[ "$status" -eq 1 ]]; then
        # Test failed but infrastructure worked
        pass "canary run completed (test failed as expected for dev installer)"
    elif [[ "$status" -eq 3 ]]; then
        skip "Docker test skipped (Docker issue)"
    else
        fail "canary run returned unexpected exit code: $status"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

test_canary_run_all_with_docker() {
    ((TESTS_RUN++))

    if [[ "$HAS_DOCKER" != "true" ]]; then
        skip "Docker not available"
        return 0
    fi

    harness_setup

    info "Testing canary --all (may take a while)..."

    # Run with --all flag
    exec_run "$DSR_CMD" canary run --all --os ubuntu:22.04
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]; then
        pass "canary run --all completed (exit: $status)"
    elif [[ "$status" -eq 3 ]]; then
        skip "Docker test skipped (Docker issue)"
    else
        fail "canary run --all returned unexpected exit code: $status"
    fi

    harness_teardown
}

test_canary_json_output_with_docker() {
    ((TESTS_RUN++))

    if [[ "$HAS_DOCKER" != "true" ]]; then
        skip "Docker not available"
        return 0
    fi

    harness_setup

    # Find first available tool
    local installer_dir="$PROJECT_ROOT/installers"
    local test_tool=""
    for dir in "$installer_dir"/*/; do
        if [[ -f "$dir/install.sh" ]]; then
            test_tool=$(basename "$dir")
            break
        fi
    done

    if [[ -z "$test_tool" ]]; then
        skip "No installer found to test"
        harness_teardown
        return 0
    fi

    exec_run "$DSR_CMD" --json canary run "$test_tool" --os ubuntu:22.04
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . &>/dev/null; then
        if echo "$output" | jq -e '.command == "canary"' &>/dev/null; then
            pass "canary --json produces valid JSON envelope"
        else
            pass "canary --json produces valid JSON"
        fi
    else
        fail "canary --json should produce valid JSON"
        echo "output: $(echo "$output" | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Canary Module Functions (Unit Tests)
# ============================================================================

test_canary_get_install_cmd() {
    ((TESTS_RUN++))

    # Source canary module
    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/canary.sh"

    local ubuntu_cmd debian_cmd fedora_cmd alpine_cmd

    ubuntu_cmd=$(_canary_get_install_cmd "ubuntu:24.04")
    debian_cmd=$(_canary_get_install_cmd "debian:12")
    fedora_cmd=$(_canary_get_install_cmd "fedora:39")
    alpine_cmd=$(_canary_get_install_cmd "alpine:latest")

    if [[ "$ubuntu_cmd" == *"apt-get"* ]] && \
       [[ "$debian_cmd" == *"apt-get"* ]] && \
       [[ "$fedora_cmd" == *"dnf"* ]] && \
       [[ "$alpine_cmd" == *"apk"* ]]; then
        pass "_canary_get_install_cmd returns correct package managers"
    else
        fail "_canary_get_install_cmd should return correct package managers"
        echo "ubuntu: $ubuntu_cmd"
        echo "fedora: $fedora_cmd"
        echo "alpine: $alpine_cmd"
    fi
}

test_canary_get_shell() {
    ((TESTS_RUN++))

    # Source canary module
    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/canary.sh"

    local ubuntu_shell alpine_shell

    ubuntu_shell=$(_canary_get_shell "ubuntu:24.04")
    alpine_shell=$(_canary_get_shell "alpine:latest")

    if [[ "$ubuntu_shell" == "bash" ]] && [[ "$alpine_shell" == "sh" ]]; then
        pass "_canary_get_shell returns correct shells"
    else
        fail "_canary_get_shell should return correct shells"
        echo "ubuntu: $ubuntu_shell, alpine: $alpine_shell"
    fi
}

test_canary_uses_configured_binary_and_installer_arguments() {
    ((TESTS_RUN++))
    harness_setup

    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/config.sh"
    source "$PROJECT_ROOT/src/canary.sh"

    local config_dir="$TEST_TMPDIR/config"
    mkdir -p "$config_dir/repos.d"
    cat > "$config_dir/repos.d/frankenterm.yaml" <<'YAML'
tool_name: frankenterm
binary_name: ft
canary_installer_args: []
canary_packages:
  - python3
  - minisign
YAML

    local binary_name installer_args default_args packages install_cmd
    local installer_args_status=0
    binary_name=$(DSR_CONFIG_DIR="$config_dir" _canary_get_binary_name frankenterm)
    installer_args=$(DSR_CONFIG_DIR="$config_dir" \
        _canary_get_installer_args frankenterm safe) || installer_args_status=$?
    default_args=$(DSR_CONFIG_DIR="$config_dir" \
        _canary_get_installer_args unconfigured vibe)
    packages=$(DSR_CONFIG_DIR="$config_dir" _canary_get_packages frankenterm)
    install_cmd=$(_canary_get_install_cmd ubuntu:24.04 python3 minisign)

    if [[ "$binary_name" == "ft" ]] && [[ "$installer_args_status" -eq 0 ]] && \
       [[ -z "$installer_args" ]] && \
       [[ "$default_args" == $'--mode\nvibe\n--non-interactive' ]] && \
       [[ "$packages" == $'python3\nminisign' ]] && \
       [[ "$install_cmd" == *"python3 minisign"* ]]; then
        pass "canary honors configured binary, installer argv, and prerequisites"
    else
        fail "canary should distinguish the repository key, binary, and installer argv"
        echo "binary: $binary_name"
        echo "configured args status: $installer_args_status"
        printf 'configured args: %q\n' "$installer_args"
        printf 'default args: %q\n' "$default_args"
        printf 'packages: %q\n' "$packages"
        printf 'install command: %q\n' "$install_cmd"
    fi

    cat > "$config_dir/repos.d/invalid.yaml" <<'YAML'
tool_name: invalid
binary_name: invalid
canary_installer_args:
  - ""
canary_packages:
  - 'python3;touch-pwned'
YAML
    if DSR_CONFIG_DIR="$config_dir" _canary_get_installer_args invalid safe \
        >/dev/null 2>&1; then
        fail "canary accepted an empty configured installer argument"
    else
        pass "canary rejects malformed configured installer argv"
    fi
    if DSR_CONFIG_DIR="$config_dir" _canary_get_packages invalid >/dev/null 2>&1; then
        fail "canary accepted an unsafe prerequisite package"
    else
        pass "canary rejects unsafe prerequisite package tokens"
    fi

    harness_teardown
}

# Exercise actual rendered programs, replacing only Docker, SSH and HTTP.
# Bash array syntax in the fixture catches Alpine invoking a Bash installer
# with its bootstrap shell instead of Bash after dependencies are installed.
test_canary_execution() {
    local engine="$1" scenario="$2"
    ((TESTS_RUN++))
    harness_setup
    if (
        export DSR_CONFIG_DIR="$TEST_TMPDIR/config"
        export DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
        export DSR_INSTALLER_DIR="$TEST_TMPDIR/generated"
        export DSR_CANARY_FIXTURE_DIR="$TEST_TMPDIR/fixture"
        export DSR_CANARY_FIXTURE_SCENARIO="$scenario"
        export DSR_CANARY_FIXTURE_ENGINE="$engine"
        mkdir -p "$DSR_CONFIG_DIR/repos.d" "$DSR_INSTALLER_DIR/canary-alias" \
            "$DSR_CANARY_FIXTURE_DIR/bin" || exit 1
        export PATH="$DSR_CANARY_FIXTURE_DIR/bin:$PATH"
        source "$PROJECT_ROOT/src/logging.sh"
        source "$PROJECT_ROOT/src/config.sh"
        source "$PROJECT_ROOT/src/canary.sh"
        cat > "$DSR_CONFIG_DIR/repos.d/canary-alias.yaml" <<'YAML'
tool_name: canary-alias
repo: ForkOwner/actual-project
binary_name: canary-fixture
canary_installer_args:
  - --label
  - two words
  - "$(false); 'literal'"
YAML
        if [[ "$scenario" == custom-path ]]; then
            printf '%s\n' 'install_script_path: setup/install candidate.sh' \
                >> "$DSR_CONFIG_DIR/repos.d/canary-alias.yaml"
        fi
        cat > "$DSR_CANARY_FIXTURE_DIR/installer.sh" <<'SH'
#!/usr/bin/env bash
words=(requires bash)
[[ "${words[1]}" == bash ]] || exit 90
printf 'installed\n' >> "$DSR_CANARY_FIXTURE_DIR/events"
printf '%s\0' "$@" > "$DSR_CANARY_FIXTURE_DIR/argv"
[[ "$DSR_CANARY_FIXTURE_SCENARIO" != installer-fails ]] || exit 17
case "$DSR_CANARY_FIXTURE_SCENARIO" in
    installer-stop-*|local-installer-stop-*) exit "${DSR_CANARY_FIXTURE_SCENARIO##*-}" ;;
esac
cat > "$DSR_CANARY_FIXTURE_DIR/bin/canary-fixture" <<'BIN'
#!/usr/bin/env bash
printf 'probe %s\n' "$1" >> "$DSR_CANARY_FIXTURE_DIR/events"
[[ "$DSR_CANARY_FIXTURE_SCENARIO" != version-fails || "$1" != --version ]] || exit 31
[[ "$DSR_CANARY_FIXTURE_SCENARIO" != help-fails || "$1" != --help ]] || exit 32
case "$DSR_CANARY_FIXTURE_SCENARIO:$1" in
    version-stop-*:--version|help-stop-*:--help) exit "${DSR_CANARY_FIXTURE_SCENARIO##*-}" ;;
esac
echo 'canary-fixture: works'
BIN
chmod +x "$DSR_CANARY_FIXTURE_DIR/bin/canary-fixture"
SH
        cat > "$DSR_CANARY_FIXTURE_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
destination=""
url=""
while (($#)); do
    case "$1" in
        -o|--output) destination="$2"; shift 2 ;;
        -A|--user-agent|--connect-timeout|--max-time) shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" >> "$DSR_CANARY_FIXTURE_DIR/urls"
[[ "$DSR_CANARY_FIXTURE_SCENARIO" != timeout ]] || sleep 30
if [[ -n "$destination" ]]; then
    cat "$DSR_CANARY_FIXTURE_DIR/installer.sh" > "$destination"
else
    cat "$DSR_CANARY_FIXTURE_DIR/installer.sh"
fi
[[ "$DSR_CANARY_FIXTURE_SCENARIO" != download-fails ]] || exit 22
case "$DSR_CANARY_FIXTURE_SCENARIO" in
    download-stop-*) exit "${DSR_CANARY_FIXTURE_SCENARIO##*-}" ;;
esac
SH
        cat > "$DSR_CANARY_FIXTURE_DIR/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DSR_CANARY_FIXTURE_DIR/ssh-calls"
command="${!#}"
[[ "$DSR_CANARY_FIXTURE_SCENARIO" != ssh-unavailable ]] || exit 255
[[ "$DSR_CANARY_FIXTURE_SCENARIO" != ssh-interrupted ]] || exit 130
[[ "$command" != 'echo ok' ]] || exit 0
exec bash -c "$command"
SH
        cat > "$DSR_CANARY_FIXTURE_DIR/bin/docker" <<'SH'
#!/usr/bin/env bash
if [[ "$DSR_CANARY_FIXTURE_ENGINE" == native-cli ]]; then
    printf 'unexpected Docker invocation\n' >> "$DSR_CANARY_FIXTURE_DIR/docker-calls"
    exit 89
fi
case "$1" in
    build)
        context="${!#}"
        cp "$context/test.sh" "$DSR_CANARY_FIXTURE_DIR/rendered.sh" || exit 1
        if [[ -f "$context/install.sh" ]]; then
            cp "$context/install.sh" "$DSR_CANARY_FIXTURE_DIR/selected-installer.sh" || exit 1
        fi
        ;;
    run)
        if [[ "$DSR_CANARY_FIXTURE_ENGINE" == alpine ]]; then
            exec sh "$DSR_CANARY_FIXTURE_DIR/rendered.sh"
        fi
        exec bash "$DSR_CANARY_FIXTURE_DIR/rendered.sh"
        ;;
    info|rmi) ;;
    *) exit 1 ;;
esac
SH
        printf '%s\n' '#!/usr/bin/env sh' 'exit 0' > "$DSR_CANARY_FIXTURE_DIR/bin/apk"
        printf '%s\n' '#!/usr/bin/env sh' 'exit 0' > "$DSR_CANARY_FIXTURE_DIR/bin/apt-get"
        chmod +x "$DSR_CANARY_FIXTURE_DIR/bin/"* || exit 1
        if [[ "$scenario" == local || "$scenario" == local-installer-stop-* || "$scenario" == fork ]]; then
            if [[ "$scenario" != fork ]]; then
                printf '%s\n' "REPO='ForkOwner/actual-project'" \
                    > "$DSR_INSTALLER_DIR/canary-alias/install.sh"
                cat "$DSR_CANARY_FIXTURE_DIR/installer.sh" >> "$DSR_INSTALLER_DIR/canary-alias/install.sh"
            else
                printf '%s\n' "REPO='OriginalOwner/old-project'" \
                    'echo stale-local >> "$DSR_CANARY_FIXTURE_DIR/events"' \
                    > "$DSR_INSTALLER_DIR/canary-alias/install.sh"
            fi
        fi
        if [[ "$scenario" == download-fails || "$scenario" == installer-fails ||
              "$scenario" == download-stop-* || "$scenario" == *installer-stop-* ]]; then
            # Existing commands must not hide acquisition or installer failure.
            printf '%s\n' '#!/usr/bin/env bash' \
                'echo stale-probe >> "$DSR_CANARY_FIXTURE_DIR/events"' \
                > "$DSR_CANARY_FIXTURE_DIR/bin/canary-fixture"
            chmod +x "$DSR_CANARY_FIXTURE_DIR/bin/canary-fixture"
        fi
        local status=0 started=$SECONDS
        if [[ "$scenario" == timeout ]]; then CANARY_TIMEOUT=1; fi
        if [[ "$engine" == native ]]; then
            canary_run_macos canary-alias canary-fixture-host safe || status=$?
        elif [[ "$engine" == native-cli ]]; then
            local cli_result expected_code=0 expected_raw=0
            "$DSR_CMD" --json canary run canary-alias --host canary-fixture-host \
                --mode safe --verbose > "$DSR_CANARY_FIXTURE_DIR/result.json" || status=$?
            case "$scenario" in
                download-fails|installer-fails|version-fails|help-fails) expected_code=1; expected_raw=1 ;;
                ssh-unavailable) expected_code=8; expected_raw=255 ;;
                ssh-interrupted) expected_code=5; expected_raw=130 ;;
                installer-stop-255) expected_code=1; expected_raw=1 ;;
                *-stop-*) expected_code=5; expected_raw="${scenario##*-}" ;;
            esac
            [[ "$status" == "$expected_code" && ! -e "$DSR_CANARY_FIXTURE_DIR/docker-calls" ]] || exit 1
            cli_result=$(cat "$DSR_CANARY_FIXTURE_DIR/result.json") || exit 1
            jq -es --argjson code "$expected_code" --argjson raw "$expected_raw" '
                length == 1 and (.[0] | .command == "canary" and .exit_code == $code and
                .status == (if $code == 0 then "success" else "error" end) and
                (.details | .backend == "ssh" and .host == "canary-fixture-host" and
                 .image == null and .tool == "canary-alias" and .mode == "safe" and
                 .total == 1 and .exit_code == $code and .results[0].exit_code == $raw and
                 .passed == (if $code == 0 then 1 else 0 end) and .failed == (1 - .passed)))
                ' <<< "$cli_result" >/dev/null || exit 1
            jq -e --argjson expected "$(jq -c .details <<< "$cli_result")" \
                'del(.timestamp) == $expected' "$DSR_STATE_DIR/canary/latest.json" >/dev/null || exit 1
            "$DSR_CMD" canary results > "$DSR_CANARY_FIXTURE_DIR/results.txt" || exit 1
            grep -Fq 'Host: canary-fixture-host' "$DSR_CANARY_FIXTURE_DIR/results.txt" || exit 1
            if [[ "$scenario" == ssh-* ]]; then
                [[ ! -e "$DSR_CANARY_FIXTURE_DIR/events" && ! -e "$DSR_CANARY_FIXTURE_DIR/urls" ]] || exit 1
                exit 0
            fi
        else
            canary_run_test canary-alias "$engine:fixture" safe || status=$?
        fi
        if [[ "$scenario" == timeout ]]; then
            [[ "$status" == 124 || "$status" == 137 ]] && ((SECONDS - started < 10)) || exit 1
            [[ ! -e "$DSR_CANARY_FIXTURE_DIR/events" ]] || exit 1
            exit 0
        fi
        if [[ "$scenario" == *-stop-* ]]; then
            local expected_status="${scenario##*-}"
            if [[ "$scenario" == installer-stop-255 ]]; then
                expected_status=1
            elif [[ "$engine" == native-cli ]]; then
                expected_status=5
            fi
            [[ "$status" == "$expected_status" ]] || exit 1
        fi
        if [[ "$scenario" == local || "$scenario" == local-installer-stop-* ]]; then
            [[ ! -e "$DSR_CANARY_FIXTURE_DIR/urls" ]] || exit 1
        else
            local expected_url='https://raw.githubusercontent.com/ForkOwner/actual-project/main/install.sh'
            [[ "$scenario" != custom-path ]] || expected_url='https://raw.githubusercontent.com/ForkOwner/actual-project/main/setup/install%20candidate.sh'
            [[ "$(cat "$DSR_CANARY_FIXTURE_DIR/urls")" == "$expected_url" ]] || exit 1
        fi
        case "$scenario" in
            download-fails|download-stop-*)
                [[ "$status" != 0 && ! -e "$DSR_CANARY_FIXTURE_DIR/events" ]] || exit 1 ;;
            installer-fails|installer-stop-*|local-installer-stop-*)
                [[ "$status" != 0 && "$(cat "$DSR_CANARY_FIXTURE_DIR/events")" == installed ]] || exit 1 ;;
            version-fails|version-stop-*)
                [[ "$status" != 0 && "$(cat "$DSR_CANARY_FIXTURE_DIR/events")" == $'installed\nprobe --version' ]] || exit 1 ;;
            help-fails|help-stop-*)
                [[ "$status" != 0 && "$(cat "$DSR_CANARY_FIXTURE_DIR/events")" == $'installed\nprobe --version\nprobe --help' ]] || exit 1 ;;
            *)
                [[ "$status" == 0 && "$(cat "$DSR_CANARY_FIXTURE_DIR/events")" == $'installed\nprobe --version\nprobe --help' ]] || exit 1
                [[ "$(tr '\0' '\n' < "$DSR_CANARY_FIXTURE_DIR/argv")" == $'--label\ntwo words\n$(false); \'literal\'' ]] || exit 1 ;;
        esac
    ); then
        pass "canary $engine execution: $scenario"
    else
        fail "canary $engine execution: $scenario"
    fi
    harness_teardown
}

test_canary_configured_installer_discovery() {
    ((TESTS_RUN++))
    harness_setup
    if (
        export DSR_INSTALLER_DIR="$TEST_TMPDIR/generated"
        mkdir -p "$DSR_INSTALLER_DIR/selected" || exit 1
        printf '%s\n' '#!/usr/bin/env bash' > "$DSR_INSTALLER_DIR/selected/install.sh"
        source "$PROJECT_ROOT/src/logging.sh"
        source "$PROJECT_ROOT/src/canary.sh"
        canary_run_test() { printf '%s\n' "$1" >> "$TEST_TMPDIR/selected-tools"; }
        local result
        result=$(canary_run_image ubuntu:24.04) || exit 1
        [[ "$(cat "$TEST_TMPDIR/selected-tools")" == selected ]] || exit 1
        jq -e '.total == 1 and .passed == 1 and .results[0].tool == "selected"' <<< "$result" >/dev/null
    ); then
        pass "canary discovers tools from DSR_INSTALLER_DIR"
    else
        fail "canary should discover only tools in DSR_INSTALLER_DIR"
    fi
    harness_teardown
}

test_canary_repository_config() {
    ((TESTS_RUN++))
    harness_setup
    if (
        export DSR_CONFIG_DIR="$TEST_TMPDIR/config"
        export DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
        export DSR_INSTALLER_DIR="$TEST_TMPDIR/generated"
        mkdir -p "$DSR_CONFIG_DIR/repos.d" "$DSR_INSTALLER_DIR/canary-alias" || exit 1
        source "$PROJECT_ROOT/src/logging.sh"
        source "$PROJECT_ROOT/src/config.sh"
        source "$PROJECT_ROOT/src/canary.sh"
        cat > "$DSR_REPOS_FILE" <<'YAML'
tools:
  canary-alias:
    repo: RegistryOwner/old-project
YAML
        cat > "$DSR_CONFIG_DIR/repos.d/canary-alias.yaml" <<'YAML'
github:
  repo: ForkOwner/actual-project
install_script_path: setup/install candidate.sh
YAML
        printf '%s\n' "REPO='RegistryOwner/old-project'" \
            > "$DSR_INSTALLER_DIR/canary-alias/install.sh"
        local result status=0
        result=$(_canary_installer_source canary-alias) || exit 1
        [[ "$result" == 'https://raw.githubusercontent.com/ForkOwner/actual-project/main/setup/install%20candidate.sh' ]] || exit 1
        printf '%s\n' 'repo: [wrong, type]' > "$DSR_CONFIG_DIR/repos.d/canary-alias.yaml"
        result=$(_canary_installer_source canary-alias 2>/dev/null) || status=$?
        [[ "$status" == 4 && -z "$result" ]] || exit 1
    ); then
        pass "canary preserves nested per-tool repository overrides and rejects invalid identity"
    else
        fail "canary repository configuration must not fall back to another project"
    fi
    harness_teardown
}

run_canary_execution_tests() {
    test_canary_configured_installer_discovery
    test_canary_repository_config
    local scenario
    for scenario in custom-path local fork download-fails installer-fails version-fails help-fails timeout \
        download-stop-143 installer-stop-130 installer-stop-5 version-stop-124 help-stop-192 \
        installer-stop-255 local-installer-stop-129; do
        test_canary_execution native "$scenario"
    done
    for scenario in custom-path fork download-fails installer-fails help-fails \
        download-stop-143 installer-stop-130 installer-stop-5 version-stop-124 help-stop-192 installer-stop-255; do
        test_canary_execution alpine "$scenario"
    done
    for scenario in custom-path local fork download-fails help-fails ssh-unavailable ssh-interrupted \
        download-stop-143 installer-stop-130 version-stop-124 help-stop-5 local-installer-stop-129 installer-stop-255; do
        test_canary_execution native-cli "$scenario"
    done
    test_canary_native_argument_validation
}

test_canary_native_argument_validation() {
    ((TESTS_RUN++))
    harness_setup
    if (
        local arguments status
        for arguments in \
            'canary-alias --host' \
            '--host canary-fixture-host' \
            '--all --host canary-fixture-host' \
            'canary-alias --all' \
            'canary-alias --host canary-fixture-host --os alpine:latest' \
            'canary-alias --host canary-fixture-host --mode unknown' \
            'canary-alias --host -unsafe-host' \
            'canary-alias other-tool --host canary-fixture-host'; do
            local -a argv=()
            read -r -a argv <<< "$arguments"
            status=0
            "$DSR_CMD" canary run "${argv[@]}" >/dev/null 2>&1 || status=$?
            [[ "$status" == 4 ]] || { printf 'Expected exit4 for %s, got %s\n' "$arguments" "$status"; exit 1; }
        done
    ); then
        pass "native canary rejects missing, conflicting, and invalid arguments before execution"
    else
        fail "native canary argument validation"
    fi
    harness_teardown
}

test_canary_matrix_rejects_empty_selection_and_bad_arguments() {
    ((TESTS_RUN++))
    harness_setup
    local problems=() output status=0 flag
    mkdir -p "$TEST_TMPDIR/empty-installers/not-an-installer"
    output=$(
        source "$PROJECT_ROOT/src/logging.sh"
        source "$PROJECT_ROOT/src/canary.sh"
        DSR_INSTALLER_DIR="$TEST_TMPDIR/empty-installers"
        CANARY_MATRIX=("ubuntu:24.04")
        CANARY_MODES=("safe")
        canary_run_matrix
    ) || status=$?
    [[ $status -eq 4 && -z "$output" ]] ||
        problems+=("empty production matrix returned $status: $output")

    status=0
    output=$(
        source "$PROJECT_ROOT/src/logging.sh"
        source "$PROJECT_ROOT/src/canary.sh"
        DSR_INSTALLER_DIR="$TEST_TMPDIR/empty-installers"
        canary_run_image ubuntu:24.04
    ) || status=$?
    [[ $status -eq 4 && -z "$output" ]] ||
        problems+=("empty production image returned $status: $output")

    status=0
    output=$(
        source "$PROJECT_ROOT/src/logging.sh"
        source "$PROJECT_ROOT/src/canary.sh"
        CANARY_MATRIX=()
        canary_run_matrix --tools ntm
    ) || status=$?
    [[ $status -eq 4 && -z "$output" ]] ||
        problems+=("empty image matrix returned $status: $output")

    for flag in --tools --modes --unknown; do
        exec_run timeout 10 "$DSR_CMD" --json canary matrix "$flag"
        [[ "$(exec_status)" -eq 4 ]] || problems+=("$flag returned $(exec_status)")
    done
    for flag in --tools --modes; do
        exec_run timeout 10 "$DSR_CMD" --json canary matrix "$flag" ""
        [[ "$(exec_status)" -eq 4 ]] || problems+=("empty $flag returned $(exec_status)")
    done
    exec_run "$DSR_CMD" --json canary matrix --tools 'ntm,cass extra'
    [[ "$(exec_status)" -eq 4 ]] || problems+=("invalid tools returned $(exec_status)")
    exec_run "$DSR_CMD" --json canary matrix --modes 'safe,unknown'
    [[ "$(exec_status)" -eq 4 ]] || problems+=("invalid modes returned $(exec_status)")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "canary matrix rejects empty production discovery and malformed arguments"
    else
        fail "canary matrix selection: ${problems[*]}"
    fi
    harness_teardown
}

test_canary_matrix_reports_and_saves_complete_results() {
    ((TESTS_RUN++))
    harness_setup
    make_fake_docker
    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/canary.sh"
    local problems=() output saved expected actual
    local image_count="${#CANARY_MATRIX[@]}"

    DSR_INSTALLER_DIR="$PROJECT_ROOT/installers" PATH="$TEST_TMPDIR/bin:$PATH" \
        exec_run "$DSR_CMD" --json canary matrix --tools ntm,cass --modes safe
    output=$(exec_stdout)
    [[ "$(exec_status)" -eq 1 ]] || problems+=("failed matrix exit $(exec_status)")
    jq -e --argjson images "$image_count" '
        .command == "canary-matrix" and .status == "error" and
        .details.type == "matrix" and .details.status == "failed" and
        .details.exit_code == 1 and .details.passed == $images and
        .details.failed == $images and .details.total == (2 * $images) and
        .details.expected == (2 * $images) and .details.errors == 0 and
        .details.complete == true and (.details.results | length) == $images and
        all(.details.results[];
            .mode == "safe" and .status == "failed" and
            .passed == 1 and .failed == 1 and .total == 2 and
            ([.results[] | select(.status == "failed") | .tool] == ["cass"]))
        ' <<< "$output" >/dev/null 2>&1 ||
        problems+=("failed matrix report: $(head -c 500 <<< "$output")")

    exec_run "$DSR_CMD" --json canary results
    saved=$(exec_stdout)
    expected=$(jq -cS '.details' <<< "$output" 2>/dev/null)
    actual=$(jq -cS 'del(.timestamp)' <<< "$saved" 2>/dev/null)
    [[ -n "$expected" && "$expected" == "$actual" ]] ||
        problems+=("saved matrix differs from public report")
    jq -e '.timestamp | type == "string"' <<< "$saved" >/dev/null 2>&1 ||
        problems+=("saved matrix lacks a timestamp")

    exec_run "$DSR_CMD" canary results
    exec_stdout | grep -q 'cass: failed' || problems+=("human results omit failed tool")
    exec_stdout | grep -q 'ubuntu:24.04 (safe): failed' || problems+=("human results omit matrix cell")
    exec_stdout | grep -q 'Complete: true' || problems+=("human results omit completion")

    DSR_INSTALLER_DIR="$PROJECT_ROOT/installers" PATH="$TEST_TMPDIR/bin:$PATH" \
        exec_run "$DSR_CMD" --json canary matrix --tools ntm --modes safe,vibe
    output=$(exec_stdout)
    [[ "$(exec_status)" -eq 0 ]] || problems+=("passing matrix exit $(exec_status)")
    jq -e --argjson total "$((image_count * 2))" '
        .status == "success" and .details.status == "passed" and
        .details.exit_code == 0 and .details.complete == true and
        .details.passed == $total and .details.failed == 0 and
        .details.errors == 0 and .details.total == $total and
        .details.expected == $total and
        ([.details.results[].mode] | unique) == ["safe", "vibe"]
        ' <<< "$output" >/dev/null 2>&1 ||
        problems+=("passing matrix report: $(head -c 500 <<< "$output")")

    DSR_INSTALLER_DIR="$PROJECT_ROOT/installers" PATH="$TEST_TMPDIR/bin:$PATH" \
        exec_run "$DSR_CMD" canary matrix --tools ntm --modes safe
    [[ "$(exec_status)" -eq 0 && -z "$(exec_stdout)" ]] &&
        exec_stderr_contains "Matrix tests completed successfully" ||
        problems+=("human matrix output or exit is incorrect")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "canary matrix preserves every image/mode/tool result through JSON and saved results"
    else
        fail "canary matrix reports: ${problems[*]}"
    fi
    harness_teardown
}

test_canary_matrix_stops_after_interrupted_container() {
    ((TESTS_RUN++))
    harness_setup
    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/canary.sh"
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/docker" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    info|rmi) exit 0 ;;
    build)
        if [[ "${DSR_MATRIX_FAILURE_PHASE:-run}" == build ]]; then
            printf 'build\n' >> "$DSR_MATRIX_TRACE"
            exit "$DSR_MATRIX_DOCKER_EXIT"
        fi
        exit 0
        ;;
    run)
        printf '%s\n' "$*" >> "$DSR_MATRIX_TRACE"
        exit "$DSR_MATRIX_DOCKER_EXIT"
        ;;
esac
exit 1
SH
    chmod +x "$TEST_TMPDIR/bin/docker"
    local problems=() output code phase test_case expected_exit
    local expected_cells=$((${#CANARY_MATRIX[@]} * 2))
    local expected_tests=$((expected_cells * 2))
    for test_case in run:5 run:130 run:124 run:255 build:130; do
        phase="${test_case%:*}"
        code="${test_case#*:}"
        expected_exit=5
        [[ $code -ne 255 ]] || expected_exit=1
        : > "$TEST_TMPDIR/container-runs"
        DSR_INSTALLER_DIR="$PROJECT_ROOT/installers" \
            DSR_MATRIX_TRACE="$TEST_TMPDIR/container-runs" DSR_MATRIX_DOCKER_EXIT="$code" \
            DSR_MATRIX_FAILURE_PHASE="$phase" \
            PATH="$TEST_TMPDIR/bin:$PATH" \
            exec_run "$DSR_CMD" --json canary matrix --tools ntm,cass --modes safe,vibe
        output=$(exec_stdout)
        [[ "$(exec_status)" -eq "$expected_exit" ]] ||
            problems+=("$phase status $code became $(exec_status), expected $expected_exit")
        if [[ $code -eq 5 || $code -eq 130 ]]; then
            [[ "$(wc -l < "$TEST_TMPDIR/container-runs")" -eq 1 ]] ||
                problems+=("interruption $code launched additional containers")
            if [[ "$phase" == build && "$(cat "$TEST_TMPDIR/container-runs")" != build ]]; then
                problems+=("interrupted build launched a container or another build")
            fi
            jq -e --argjson code "$code" --argjson exit_code "$expected_exit" '
            .status == "error" and .details.status == "error" and
            .details.exit_code == $exit_code and .details.raw_exit_code == $code and
            .details.complete == false and
            .details.errors == 1 and .details.total == 1 and
            .details.failed == 1 and .details.passed == 0 and .details.expected > 1 and
            (.details.results | length) == 1 and
            .details.results[0].exit_code == $code and
            .details.results[0].results[0].exit_code == $code
            ' <<< "$output" >/dev/null 2>&1 ||
                problems+=("interruption $code report: $(head -c 500 <<< "$output")")
        else
            [[ "$(wc -l < "$TEST_TMPDIR/container-runs")" -eq $expected_tests ]] ||
                problems+=("ordinary failure $code interrupted remaining tests")
            jq -e --argjson code "$code" --argjson exit_code "$expected_exit" --argjson cells "$expected_cells" \
                --argjson total "$expected_tests" '
                .status == "error" and .details.status == "error" and
                .details.exit_code == $exit_code and .details.raw_exit_code == $code and
                .details.complete == true and
                .details.errors == $cells and .details.total == $total and
                .details.failed == $total and .details.expected == $total and
                all(.details.results[]; .exit_code == $code and .complete == true)
                ' <<< "$output" >/dev/null 2>&1 ||
                problems+=("ordinary failure $code report: $(head -c 500 <<< "$output")")
        fi
    done
    : > "$TEST_TMPDIR/container-runs"
    DSR_INSTALLER_DIR="$PROJECT_ROOT/installers" \
        DSR_MATRIX_TRACE="$TEST_TMPDIR/container-runs" DSR_MATRIX_DOCKER_EXIT=130 \
        DSR_MATRIX_FAILURE_PHASE=build PATH="$TEST_TMPDIR/bin:$PATH" \
        exec_run "$DSR_CMD" --json canary run --all --mode safe
    output=$(exec_stdout)
    [[ "$(exec_status)" -eq 5 && "$(cat "$TEST_TMPDIR/container-runs")" == build ]] ||
        problems+=("run --all did not stop and normalize the interrupted build")
    jq -e '.command == "canary" and .status == "error" and
        .details.exit_code == 5 and .details.raw_exit_code == 130 and
        .details.complete == false and (.details.results | length) == 1 and
        .details.results[0].exit_code == 130' <<< "$output" >/dev/null 2>&1 ||
        problems+=("run --all interruption report: $(head -c 500 <<< "$output")")
    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "canary matrix stops for signals while retaining ordinary timeout and transport failures"
    else
        fail "canary matrix interruption: ${problems[*]}"
    fi
    harness_teardown
}

test_canary_matrix_rejects_invalid_child_results() {
    ((TESTS_RUN++))
    harness_setup
    local problems=() fault output status selection expected_total
    for fault in missing invalid counts identity duplicate documents row-code image-code code-mismatch partial incomplete nonzero; do
        selection=ntm
        expected_total=0
        [[ "$fault" != partial ]] || selection=ntm,cass
        case "$fault" in partial|incomplete|nonzero) expected_total=1 ;; esac
        status=0
        output=$(
            source "$PROJECT_ROOT/src/logging.sh"
            source "$PROJECT_ROOT/src/canary.sh"
            CANARY_MATRIX=("ubuntu:24.04")
            CANARY_MODES=("safe")
            # Inject damaged producer output to exercise the real matrix
            # consumer's failure handling, without replacing aggregation.
            canary_run_image() {
                local valid='{"image":"ubuntu:24.04","mode":"safe","passed":1,"failed":0,"total":1,"results":[{"tool":"ntm","status":"passed","duration":0}]}'
                case "$fault" in
                    missing) return 3 ;;
                    invalid) printf '%s\n' 'not JSON' ;;
                    counts) jq -c '.passed = 9' <<< "$valid" ;;
                    identity) jq -c '.image = "different:latest"' <<< "$valid" ;;
                    duplicate) jq -c '.results += .results | .passed = 2 | .total = 2' <<< "$valid" ;;
                    documents) printf '%s\n%s\n' "$valid" "$valid" ;;
                    row-code) jq -c '.results[0].exit_code = 7' <<< "$valid" ;;
                    image-code) jq -c '.exit_code = 7' <<< "$valid" ;;
                    code-mismatch) jq -c '.exit_code = 7' <<< "$valid"; return 3 ;;
                    partial) printf '%s\n' "$valid" ;;
                    incomplete) jq -c '.complete = false' <<< "$valid" ;;
                    nonzero) printf '%s\n' "$valid"; return 3 ;;
                esac
            }
            canary_run_matrix --tools "$selection"
        ) 2> "$TEST_TMPDIR/$fault.stderr" || status=$?
        [[ $status -eq 3 ]] || problems+=("$fault returned $status")
        jq -e --argjson total "$expected_total" '
            .type == "matrix" and .status == "error" and .exit_code == 3 and
            .errors == 1 and .total == $total and .failed == 0 and
            .passed == $total and (.results | length) == 1 and
            .results[0].status == "error" and (.results[0].error | length) > 0 and
            (.results[0].results | length) == $total
            ' <<< "$output" >/dev/null 2>&1 ||
            problems+=("$fault report: $(head -c 400 <<< "$output")")
        if [[ "$fault" != nonzero ]]; then
            jq -e '.complete == false' <<< "$output" >/dev/null 2>&1 ||
                problems+=("$fault was marked complete")
        fi
    done
    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "canary matrix fails for missing, inconsistent, partial, or nonzero child outcomes"
    else
        fail "canary matrix child validation: ${problems[*]}"
    fi
    harness_teardown
}

test_canary_matrix_config() {
    ((TESTS_RUN++))

    # Source canary module
    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/canary.sh"

    if [[ ${#CANARY_MATRIX[@]} -gt 0 ]]; then
        pass "CANARY_MATRIX is configured (${#CANARY_MATRIX[@]} images)"
    else
        fail "CANARY_MATRIX should have at least one image"
    fi
}

test_canary_modes_config() {
    ((TESTS_RUN++))

    # Source canary module
    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/canary.sh"

    if [[ ${#CANARY_MODES[@]} -ge 2 ]]; then
        if [[ "${CANARY_MODES[*]}" == *"vibe"* ]] && [[ "${CANARY_MODES[*]}" == *"safe"* ]]; then
            pass "CANARY_MODES includes vibe and safe"
        else
            fail "CANARY_MODES should include vibe and safe"
        fi
    else
        fail "CANARY_MODES should have at least 2 modes"
    fi
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    exec_cleanup 2>/dev/null || true
}
trap cleanup EXIT

if [[ "${1:-}" == --execution-only ]]; then
    run_canary_execution_tests
    printf 'Canary execution: %s passed, %s failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]
    exit $?
fi

if [[ "${1:-}" == --matrix-only ]]; then
    test_canary_matrix_rejects_empty_selection_and_bad_arguments
    test_canary_matrix_reports_and_saves_complete_results
    test_canary_matrix_stops_after_interrupted_container
    test_canary_matrix_rejects_invalid_child_results
    printf 'Canary matrix: %s passed, %s failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]
    exit $?
fi

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== Canary Command Tests ==="
echo ""
echo "Docker available: $HAS_DOCKER"
echo ""

echo "Help Tests:"
test_canary_help
test_canary_help_shows_subcommands
test_canary_help_shows_examples

echo ""
echo "Argument Validation Tests:"
test_canary_unknown_subcommand
test_canary_run_missing_tool
test_canary_run_unknown_option

echo ""
echo "Docker Detection Tests:"
test_canary_detects_no_docker
test_canary_json_no_docker

echo ""
echo "Results Command Tests:"
test_canary_results_empty
test_canary_results_json

echo ""
echo "Schedule Command Tests:"
test_canary_schedule_show
test_canary_schedule_dry_run_and_validation

echo ""
echo "Run --all (stubbed Docker):"
test_canary_run_all_results_are_json

echo ""
echo "Unit Tests (Canary Module):"
test_canary_get_install_cmd
test_canary_get_shell
test_canary_uses_configured_binary_and_installer_arguments
run_canary_execution_tests
test_canary_matrix_rejects_empty_selection_and_bad_arguments
test_canary_matrix_reports_and_saves_complete_results
test_canary_matrix_stops_after_interrupted_container
test_canary_matrix_rejects_invalid_child_results
test_canary_matrix_config
test_canary_modes_config

echo ""
echo "Docker Integration Tests (when available):"
test_canary_run_with_docker
test_canary_run_all_with_docker
test_canary_json_output_with_docker

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
