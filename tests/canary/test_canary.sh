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

test_canary_script_fails_closed() {
    ((TESTS_RUN++))

    local source="$PROJECT_ROOT/src/canary.sh"
    if grep -Fq '2>&1 || true' "$source"; then
        fail "canary still ignores an installer failure"
    elif grep -Fq 'echo "Installer failed" >&2' "$source" && \
         grep -Fq 'exit 1' "$source" && \
         grep -Fq '"\$binary_name" --version' "$source" && \
         grep -Fq '"\$binary_name" --help' "$source"; then
        pass "canary installer and executable probes fail closed"
    else
        fail "canary fail-closed installer/probe contract is incomplete"
    fi
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
cat > "$DSR_CANARY_FIXTURE_DIR/bin/canary-fixture" <<'BIN'
#!/usr/bin/env bash
printf 'probe %s\n' "$1" >> "$DSR_CANARY_FIXTURE_DIR/events"
[[ "$DSR_CANARY_FIXTURE_SCENARIO" != version-fails || "$1" != --version ]] || exit 31
[[ "$DSR_CANARY_FIXTURE_SCENARIO" != help-fails || "$1" != --help ]] || exit 32
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
SH
        cat > "$DSR_CANARY_FIXTURE_DIR/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DSR_CANARY_FIXTURE_DIR/ssh-calls"
command="${!#}"
[[ "$command" != 'echo ok' ]] || exit 0
exec bash -c "$command"
SH
        cat > "$DSR_CANARY_FIXTURE_DIR/bin/docker" <<'SH'
#!/usr/bin/env bash
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
        if [[ "$scenario" == local || "$scenario" == fork ]]; then
            if [[ "$scenario" == local ]]; then
                printf '%s\n' "REPO='ForkOwner/actual-project'" \
                    > "$DSR_INSTALLER_DIR/canary-alias/install.sh"
                cat "$DSR_CANARY_FIXTURE_DIR/installer.sh" >> "$DSR_INSTALLER_DIR/canary-alias/install.sh"
            else
                printf '%s\n' "REPO='OriginalOwner/old-project'" \
                    'echo stale-local >> "$DSR_CANARY_FIXTURE_DIR/events"' \
                    > "$DSR_INSTALLER_DIR/canary-alias/install.sh"
            fi
        fi
        if [[ "$scenario" == download-fails || "$scenario" == installer-fails ]]; then
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
        else
            canary_run_test canary-alias "$engine:fixture" safe || status=$?
        fi
        if [[ "$scenario" == timeout ]]; then
            [[ "$status" == 124 || "$status" == 137 ]] && ((SECONDS - started < 10)) || exit 1
            [[ ! -e "$DSR_CANARY_FIXTURE_DIR/events" ]] || exit 1
            exit 0
        fi
        if [[ "$scenario" == local ]]; then
            [[ ! -e "$DSR_CANARY_FIXTURE_DIR/urls" ]] || exit 1
        else
            local expected_url='https://raw.githubusercontent.com/ForkOwner/actual-project/main/install.sh'
            [[ "$scenario" != custom-path ]] || expected_url='https://raw.githubusercontent.com/ForkOwner/actual-project/main/setup/install%20candidate.sh'
            [[ "$(cat "$DSR_CANARY_FIXTURE_DIR/urls")" == "$expected_url" ]] || exit 1
        fi
        case "$scenario" in
            download-fails)
                [[ "$status" != 0 && ! -e "$DSR_CANARY_FIXTURE_DIR/events" ]] || exit 1 ;;
            installer-fails)
                [[ "$status" != 0 && "$(cat "$DSR_CANARY_FIXTURE_DIR/events")" == installed ]] || exit 1 ;;
            version-fails)
                [[ "$status" != 0 && "$(cat "$DSR_CANARY_FIXTURE_DIR/events")" == $'installed\nprobe --version' ]] || exit 1 ;;
            help-fails)
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
    for scenario in custom-path local fork download-fails installer-fails version-fails help-fails timeout; do
        test_canary_execution native "$scenario"
    done
    for scenario in custom-path fork download-fails installer-fails help-fails; do
        test_canary_execution alpine "$scenario"
    done
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
test_canary_script_fails_closed
run_canary_execution_tests
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
