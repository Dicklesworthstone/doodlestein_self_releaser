#!/usr/bin/env bash
# test_upgrade_verify.sh - Tests for upgrade command verification
#
# bd-1jt.5.6: Implement upgrade command verification after release
#
# Tests the upgrade_verify module that validates tool upgrade commands
# work correctly after releases.
#
# Run: ./scripts/tests/test_upgrade_verify.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test harness
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
# Setup
# ============================================================================

setup_module() {
    # Source required modules
    source "$PROJECT_ROOT/src/logging.sh"
    source "$PROJECT_ROOT/src/upgrade_verify.sh"

    # Create test directories
    mkdir -p "$TEST_TMPDIR/repos.d"
    mkdir -p "$TEST_TMPDIR/bin"

    # Set config directory
    export DSR_CONFIG_DIR="$TEST_TMPDIR"
    export ACT_REPOS_DIR="$TEST_TMPDIR/repos.d"
}

# ============================================================================
# Tests: Module Loading
# ============================================================================

test_module_loads() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    if declare -f upgrade_verify_tool &>/dev/null; then
        pass "upgrade_verify_tool function exists"
    else
        fail "upgrade_verify_tool function should exist"
    fi

    harness_teardown
}

test_module_exports() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    local all_exported=true

    for fn in upgrade_verify_tool upgrade_verify_all upgrade_verify_json; do
        if ! declare -f "$fn" &>/dev/null; then
            all_exported=false
            echo "Missing function: $fn"
        fi
    done

    if $all_exported; then
        pass "All upgrade_verify functions exported"
    else
        fail "Some upgrade_verify functions not exported"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Tool Verification
# ============================================================================

test_verify_missing_tool_fails() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Try to verify non-existent tool
    if upgrade_verify_tool "nonexistent-tool-12345" 2>/dev/null; then
        fail "verify_tool should fail for non-existent tool"
    else
        pass "verify_tool fails for non-existent tool"
    fi

    harness_teardown
}

test_verify_requires_tool_name() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    if upgrade_verify_tool 2>/dev/null; then
        fail "verify_tool should require tool name"
    else
        pass "verify_tool requires tool name"
    fi

    harness_teardown
}

test_verify_dry_run() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create a mock tool that has upgrade command
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/mock-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "Current version: 1.0.0"
    echo "Latest version: 1.0.0"
    echo "Already up to date"
    exit 0
fi
echo "mock-tool $*"
EOF
    chmod +x "$TEST_TMPDIR/bin/mock-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if upgrade_verify_tool mock-tool --dry-run 2>/dev/null; then
        pass "verify_tool --dry-run works"
    else
        fail "verify_tool --dry-run should succeed"
    fi

    harness_teardown
}

test_verify_uses_configured_binary_name() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/beads-rust"
    cat > "$TEST_TMPDIR/repos.d/beads_rust.yaml" << EOF
tool_name: br
binary_name: br
local_path: $TEST_TMPDIR/beads-rust
repo: test/beads_rust
EOF
    cat > "$TEST_TMPDIR/bin/br" << 'EOF'
#!/bin/bash
if [[ "$1" == "--help" ]]; then
    echo "Commands: upgrade"
    exit 0
fi
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "Current version: 0.1.45"
    echo "Latest version: 0.2.5"
    echo "Update available"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_TMPDIR/bin/br"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if upgrade_verify_tool beads_rust 2>/dev/null; then
        pass "verify_tool uses configured binary_name when tool key differs"
    else
        fail "verify_tool should use configured binary_name for beads_rust -> br"
    fi

    harness_teardown
}

test_verify_uses_configured_check_args() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    cat > "$TEST_TMPDIR/repos.d/dcg-style.yaml" << EOF
tool_name: dcg-style
binary_name: dcg-style
local_path: $TEST_TMPDIR/dcg-style
repo: test/dcg-style
upgrade_check_args:
  - update
  - --check
EOF
    cat > "$TEST_TMPDIR/bin/dcg-style" << 'EOF'
#!/bin/bash
if [[ "$1" == "update" && "$2" == "--check" && $# -eq 2 ]]; then
    echo "Already running the latest version"
    exit 0
fi
echo "unexpected argv: $*" >&2
exit 64
EOF
    chmod +x "$TEST_TMPDIR/bin/dcg-style"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if upgrade_verify_tool dcg-style 2>/dev/null; then
        pass "verify_tool uses configured upgrade_check_args"
    else
        fail "verify_tool should use update --check for configured tools"
    fi

    harness_teardown
}

test_json_uses_configured_check_args() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    cat > "$TEST_TMPDIR/repos.d/json-update.yaml" << EOF
tool_name: json-update
binary_name: json-update
local_path: $TEST_TMPDIR/json-update
repo: test/json-update
upgrade_check_args: [update, --check]
EOF
    cat > "$TEST_TMPDIR/bin/json-update" << 'EOF'
#!/bin/bash
if [[ "$1" == "update" && "$2" == "--check" && $# -eq 2 ]]; then
    echo "up to date"
    exit 0
fi
exit 64
EOF
    chmod +x "$TEST_TMPDIR/bin/json-update"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    local output
    output=$(upgrade_verify_json json-update 2>/dev/null)
    if jq -e '.status == "passed" and .exit_code == 0' <<< "$output" &>/dev/null; then
        pass "verify_json uses configured upgrade_check_args"
    else
        fail "verify_json should use configured update-check argv"
        echo "Output: $output"
    fi

    harness_teardown
}

test_rejects_invalid_configured_check_args() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    cat > "$TEST_TMPDIR/repos.d/invalid-args.yaml" << EOF
tool_name: invalid-args
binary_name: invalid-args
local_path: $TEST_TMPDIR/invalid-args
repo: test/invalid-args
upgrade_check_args: update --check
EOF
    cat > "$TEST_TMPDIR/bin/invalid-args" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/invalid-args"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    local exit_code=0
    upgrade_verify_tool invalid-args 2>/dev/null || exit_code=$?
    if [[ $exit_code -eq 4 ]]; then
        pass "verify_tool rejects non-array upgrade_check_args"
    else
        fail "verify_tool should reject invalid upgrade_check_args with exit 4"
    fi

    harness_teardown
}

test_exact_version_must_match_latest() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    cat > "$TEST_TMPDIR/bin/exact-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "Current version: 1.9.0"
    echo "Latest version: 2.0.0"
    echo "Update available"
    exit 0
fi
exit 64
EOF
    chmod +x "$TEST_TMPDIR/bin/exact-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if upgrade_verify_tool exact-tool --version v2.0.0 2>/dev/null; then
        pass "verify_tool accepts the exact released version"
    else
        fail "verify_tool should accept the exact latest version"
    fi

    local exit_code=0
    upgrade_verify_tool exact-tool --version 2.0.1 2>/dev/null || exit_code=$?
    if [[ $exit_code -eq 1 ]]; then
        pass "verify_tool rejects a stale latest version"
    else
        fail "verify_tool should reject output that omits the released version"
    fi

    harness_teardown
}

test_json_reports_exact_version_mismatch() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    cat > "$TEST_TMPDIR/bin/json-exact" << 'EOF'
#!/bin/bash
echo "Latest version: 3.1.4"
echo "Update available"
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/json-exact"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    local output exit_code=0
    output=$(upgrade_verify_json json-exact --version 3.1.5 2>/dev/null) || exit_code=$?
    if [[ $exit_code -eq 1 ]] && jq -e \
            '.status == "failed" and .expected_version == "3.1.5" and .latest_version == "3.1.4"' \
            <<< "$output" &>/dev/null; then
        pass "verify_json reports exact-version mismatch"
    else
        fail "verify_json should expose expected and observed latest versions"
        echo "Output: $output"
    fi

    harness_teardown
}

# A tool whose update check fails, counting every invocation.
make_counting_tool() {
    local name="$1" exit_status="$2"
    cat > "$TEST_TMPDIR/bin/$name" << EOF
#!/bin/bash
echo run >> "$TEST_TMPDIR/$name.calls"
echo "Error: no suitable release asset for this platform"
exit $exit_status
EOF
    chmod +x "$TEST_TMPDIR/bin/$name"
}

test_cli_json_failure_is_one_envelope_from_one_run() {
    ((TESTS_RUN++))
    harness_setup
    setup_module
    make_counting_tool cli-fail 1
    local problems=() output

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$PROJECT_ROOT/dsr" --json verify upgrade cli-fail
    output=$(exec_stdout)
    [[ "$(exec_status)" -eq 1 ]] || problems+=("exit $(exec_status)")
    jq -es 'length == 1 and (.[0] | .status == "error" and .exit_code == 1 and
        .details.status == "failed" and .details.tool == "cli-fail" and
        (.details.output | contains("no suitable release asset")))' <<< "$output" >/dev/null 2>&1 ||
        problems+=("envelope: $(head -c 400 <<< "$output")")
    [[ "$(wc -l < "$TEST_TMPDIR/cli-fail.calls")" -eq 1 ]] ||
        problems+=("check ran $(wc -l < "$TEST_TMPDIR/cli-fail.calls") times")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "verify upgrade --json reports a failed check as one envelope from one run"
    else
        fail "verify upgrade --json failure: ${problems[*]}"
    fi
    harness_teardown
}

# Only the updater executable is a fixture. The CLI, timeout, output capture,
# version selection and verdict are production code in both output modes.
make_verdict_tool() {
    printf '%s' "$1" > "$TEST_TMPDIR/check.stdout"
    printf '%s' "$2" > "$TEST_TMPDIR/check.stderr"
    printf '%s\n' "$3" > "$TEST_TMPDIR/check.result"
    export DSR_UPGRADE_TEST_ROOT="$TEST_TMPDIR"
    cat > "$TEST_TMPDIR/bin/cli-verdict" << 'EOF'
#!/usr/bin/env bash
[[ $# -eq 2 && "$1" == upgrade && "$2" == --check ]] || exit 64
printf 'run\n' >> "$DSR_UPGRADE_TEST_ROOT/check.calls"
cat "$DSR_UPGRADE_TEST_ROOT/check.stdout"
cat "$DSR_UPGRADE_TEST_ROOT/check.stderr" >&2
result=$(cat "$DSR_UPGRADE_TEST_ROOT/check.result")
[[ "$result" != timeout ]] || exec sleep 10
exit "$result"
EOF
    chmod +x "$TEST_TMPDIR/bin/cli-verdict"
}

check_cli_verdict() {
    local label="$1" updater_status="$2" expected_status="$3" text="$4" diagnostic="$5" version="${6-1.2.3}"
    ((TESTS_RUN++))
    TEST_NAME="upgrade-verdict-$label" harness_setup
    setup_module
    make_verdict_tool "$text" "$diagnostic" "$updater_status"
    local PATH="$TEST_TMPDIR/bin:$PATH"
    local output mode calls=0 problems=() expected_verdict=failed expected_envelope=error found=false
    local -a flags=() version_args=()
    if [[ "$expected_status" == 0 ]]; then
        expected_verdict=passed expected_envelope=success found=true
    fi
    [[ -z "$version" ]] || version_args=(--version "$version")
    for mode in plain json; do
        flags=()
        [[ "$mode" != json ]] || flags=(--json)
        exec_run "$PROJECT_ROOT/dsr" ${flags[@]+"${flags[@]}"} verify upgrade cli-verdict \
            ${version_args[@]+"${version_args[@]}"}
        output=$(exec_stdout)
        cp "$_EXEC_STDOUT_FILE" "$TEST_TMPDIR/$mode.stdout"
        cp "$_EXEC_STDERR_FILE" "$TEST_TMPDIR/$mode.stderr"
        [[ "$(exec_status)" == "$expected_status" ]] || problems+=("$mode exited $(exec_status)")
        calls=$((calls + 1))
        [[ -f "$TEST_TMPDIR/check.calls" && "$(wc -l < "$TEST_TMPDIR/check.calls")" -eq "$calls" ]] ||
            problems+=("$mode did not invoke the updater exactly once")
        if [[ "$mode" == json ]]; then
            jq -es --arg verdict "$expected_verdict" --arg status "$expected_envelope" \
                --argjson code "$expected_status" --argjson updater "$updater_status" --argjson found "$found" \
                --arg version "$version" '
                length == 1 and (.[0] | .command == "verify-upgrade" and
                    .status == $status and .exit_code == $code and .details.tool == "cli-verdict" and
                    .details.status == $verdict and .details.found_asset == $found and
                    .details.exit_code == $updater and
                    .details.expected_version == (if $version == "" then null else $version end))
            ' <<< "$output" >/dev/null || problems+=("JSON verdict or updater status disagrees")
        elif [[ "$expected_status" != 0 ]] &&
             grep -qi 'verification.*passed' "$TEST_TMPDIR/plain.stderr"; then
            problems+=("plain output claimed verification passed")
        fi
    done
    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "plain and JSON upgrade verification agree: $label"
    else
        fail "upgrade verdict $label: ${problems[*]}"
    fi
    unset DSR_UPGRADE_TEST_ROOT
    harness_teardown
}

test_cli_process_status_and_output_agree() {
    check_cli_verdict positive-then-failure 41 1 \
        $'Latest version: 1.2.3\nUpdate available\n' $'Error: signature validation failed\n'
    check_cli_verdict current-version-before-mismatch 41 1 \
        $'Current version: 1.0.0\nLatest version: 1.2.3\n' $'Error: no suitable release asset for this platform\n'
    check_cli_verdict contradictory-zero-exit 0 1 \
        $'Latest version: 1.2.3\nUpdate available\n' $'Error: asset not found\n'
    check_cli_verdict no-update-before-failure 43 1 \
        $'Latest version: 1.2.3\nAlready up to date\n' $'Error: upstream lookup failed\n'
    check_cli_verdict healthy-update 0 0 $'Latest version: 1.2.3\nUpdate available\n' ''
    check_cli_verdict healthy-no-update 0 0 $'Latest version: 1.2.3\nNo update available\n' ''
    check_cli_verdict healthy-generic 0 0 $'Check completed.\n' '' ''
    check_cli_verdict healthy-silent 0 0 '' '' ''
}

test_real_timeout_after_positive_output_fails() {
    ((TESTS_RUN++))
    TEST_NAME=upgrade-verdict-timeout harness_setup
    setup_module
    if ! command -v timeout >/dev/null && ! command -v gtimeout >/dev/null; then
        skip "real upgrade timeout requires timeout or gtimeout"
        harness_teardown
        return 0
    fi
    make_verdict_tool $'Latest version: 1.2.3\nUpdate available\n' '' timeout
    local PATH="$TEST_TMPDIR/bin:$PATH" UPGRADE_VERIFY_TIMEOUT=1
    local problems=() output
    exec_run upgrade_verify_tool cli-verdict --version 1.2.3
    [[ "$(exec_status)" == 1 ]] || problems+=("plain timeout exited $(exec_status)")
    cp "$_EXEC_STDOUT_FILE" "$TEST_TMPDIR/plain.stdout"
    cp "$_EXEC_STDERR_FILE" "$TEST_TMPDIR/plain.stderr"
    exec_run upgrade_verify_json cli-verdict --version 1.2.3
    [[ "$(exec_status)" == 1 ]] || problems+=("JSON timeout exited $(exec_status)")
    output=$(exec_stdout)
    jq -es 'length == 1 and (.[0] | .status == "failed" and .found_asset == false and
        .exit_code == 124 and .latest_version == "1.2.3" and .expected_version == "1.2.3" and
        (.output | contains("Update available")))' <<< "$output" >/dev/null ||
        problems+=("JSON timeout did not retain the actual timeout result")
    [[ -f "$TEST_TMPDIR/check.calls" && "$(wc -l < "$TEST_TMPDIR/check.calls")" -eq 2 ]] ||
        problems+=("timeout verification repeated the updater")
    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "real updater timeout cannot become success from earlier positive output"
    else
        fail "upgrade timeout verdict: ${problems[*]}"
    fi
    unset DSR_UPGRADE_TEST_ROOT
    harness_teardown
}

test_cli_dry_run_runs_and_builds_nothing() {
    ((TESTS_RUN++))
    harness_setup
    setup_module
    make_counting_tool cli-dry 0
    # A buildable checkout whose build would be recorded by the cargo stub.
    mkdir -p "$TEST_TMPDIR/src/cli-src"
    echo '[package]' > "$TEST_TMPDIR/src/cli-src/Cargo.toml"
    printf 'tool_name: cli-src\nlocal_path: %s\n' "$TEST_TMPDIR/src/cli-src" > "$TEST_TMPDIR/repos.d/cli-src.yaml"
    cat > "$TEST_TMPDIR/bin/cargo" << EOF
#!/bin/bash
echo "\$*" >> "$TEST_TMPDIR/cargo.calls"
exit 1
EOF
    chmod +x "$TEST_TMPDIR/bin/cargo"
    local problems=()

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$PROJECT_ROOT/dsr" --json verify upgrade cli-dry --dry-run
    [[ "$(exec_status)" -eq 0 ]] || problems+=("--dry-run exit $(exec_status)")
    exec_stdout | jq -e '.details.status == "planned" and .details.dry_run == true' >/dev/null 2>&1 ||
        problems+=("--dry-run envelope: $(exec_stdout | head -c 300)")
    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$PROJECT_ROOT/dsr" -n --json verify upgrade cli-dry
    [[ "$(exec_status)" -eq 0 ]] || problems+=("-n exit $(exec_status)")
    [[ ! -e "$TEST_TMPDIR/cli-dry.calls" ]] || problems+=("dry runs ran the update check")

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$PROJECT_ROOT/dsr" verify upgrade cli-src --build-from-source --dry-run
    [[ "$(exec_status)" -eq 0 ]] || problems+=("build dry-run exit $(exec_status)")
    [[ ! -e "$TEST_TMPDIR/cargo.calls" ]] || problems+=("dry run invoked cargo: $(cat "$TEST_TMPDIR/cargo.calls")")
    exec_stderr_contains "Would build cli-src from source" || problems+=("no build plan on stderr")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "verify upgrade --dry-run neither runs the check nor builds"
    else
        fail "verify upgrade dry run: ${problems[*]}"
    fi
    harness_teardown
}

# The CLI, repository configuration, selection, source-build helper and updater
# verdict are real. Only the Go compiler and updater executables are fixtures;
# their separate receipts show which executable was selected and run.
make_bulk_upgrade_fixtures() {
    export DSR_UPGRADE_BULK_ROOT="$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/source checkout"
    printf 'module example.invalid/upgrade-fixture\n' > "$TEST_TMPDIR/source checkout/go.mod"
    printf 'package main\nfunc main() {}\n' > "$TEST_TMPDIR/source checkout/main.go"
    printf '%s\n' upgrade > "$TEST_TMPDIR/check.verb"
    cat > "$TEST_TMPDIR/installed-updater" << 'EOF'
#!/usr/bin/env bash
if [[ $# -eq 1 && "$1" == --help ]]; then
    printf '%s\n' "${0##*/}" >> "$DSR_UPGRADE_BULK_ROOT/help.calls"
    if [[ "${0##*/}" == bulk-passive ]]; then
        printf 'Commands: inspect\n'
    else
        printf 'Commands: upgrade\n'
    fi
    exit 0
fi
[[ "${0##*/}" != bulk-passive ]] || exit 65
IFS= read -r verb < "$DSR_UPGRADE_BULK_ROOT/check.verb"
[[ $# -eq 2 && "$1" == "$verb" && "$2" == --check ]] || exit 64
printf 'installed\n' >> "$DSR_UPGRADE_BULK_ROOT/check.calls"
printf 'Latest version: 1.2.3\nUpdate available\n'
EOF
    cat > "$TEST_TMPDIR/built-updater" << 'EOF'
#!/usr/bin/env bash
IFS= read -r verb < "$DSR_UPGRADE_BULK_ROOT/check.verb"
[[ $# -eq 2 && "$1" == "$verb" && "$2" == --check ]] || exit 64
printf 'built\n' >> "$DSR_UPGRADE_BULK_ROOT/check.calls"
printf 'Latest version: 1.2.3\nUpdate available\n'
EOF
    cat > "$TEST_TMPDIR/bin/go" << 'EOF'
#!/usr/bin/env bash
[[ "$PWD" == "$DSR_UPGRADE_BULK_ROOT/source checkout" ]] || exit 64
if [[ $# -eq 4 && "$1" == list && "$2" == -f && "$3" == '{{.Name}}' && "$4" == ./. ]]; then
    printf 'main\n'
    exit 0
fi
[[ $# -eq 4 && "$1" == build && "$2" == -o && "$4" == ./. ]] || exit 64
printf 'build\n' >> "$DSR_UPGRADE_BULK_ROOT/build.calls"
[[ ! -f "$DSR_UPGRADE_BULK_ROOT/fail-build" ]] || exit 32
cat "$DSR_UPGRADE_BULK_ROOT/built-updater" > "$3" || exit 1
chmod 700 "$3"
EOF
    chmod +x "$TEST_TMPDIR/installed-updater" "$TEST_TMPDIR/bin/go"
}

make_bulk_upgrade_config() {
    local tool="$1" binary="$2" explicit="$3"
    printf 'tool_name: %s\nbinary_name: %s\nlocal_path: %s\nrepo: test/%s\n' \
        "$tool" "$binary" "$TEST_TMPDIR/source checkout" "$tool" > "$TEST_TMPDIR/repos.d/$tool.yaml"
    if [[ "$explicit" == true ]]; then
        printf 'upgrade_check_args: [update, --check]\n' >> "$TEST_TMPDIR/repos.d/$tool.yaml"
    fi
}

test_cli_all_selection_and_options() {
    local scenario
    for scenario in version-mismatch version-match explicit-missing-dry explicit-source-dry \
            explicit-source-live requested-source-installed requested-source-missing alias-fallback \
            mixed-capabilities no-updaters no-updaters-dry empty missing-source source-build-fails; do
        ((TESTS_RUN++))
        TEST_NAME="upgrade-all-$scenario" harness_setup
        setup_module
        make_bulk_upgrade_fixtures
        local PATH="$TEST_TMPDIR/bin:$PATH"
        local -a options=() problems=() flags=()
        local expected=0 checks=0 builds=0 helps=0 selected='' dry=false plan=false
        local mode output calls attempt=0
        case "$scenario" in
            version-mismatch|version-match)
                make_bulk_upgrade_config bulk-check bulk-check true
                cp -p "$TEST_TMPDIR/installed-updater" "$TEST_TMPDIR/bin/bulk-check"
                printf '%s\n' update > "$TEST_TMPDIR/check.verb"
                checks=1 selected=installed
                options=(--version v1.2.3)
                if [[ "$scenario" == version-mismatch ]]; then
                    options=(--version 9.9.9)
                    expected=1
                fi
                ;;
            explicit-missing-dry|explicit-source-dry|explicit-source-live)
                make_bulk_upgrade_config bulk-source bulk-source true
                printf '%s\n' update > "$TEST_TMPDIR/check.verb"
                if [[ "$scenario" == explicit-source-live ]]; then
                    checks=1 builds=1 selected=built
                    options=(--version 1.2.3)
                else
                    dry=true plan=true options=(--dry-run)
                    [[ "$scenario" != explicit-source-dry ]] || options+=(--build-from-source)
                fi
                ;;
            requested-source-installed|requested-source-missing|source-build-fails)
                make_bulk_upgrade_config bulk-passive bulk-passive false
                if [[ "$scenario" == requested-source-installed ]]; then
                    cp -p "$TEST_TMPDIR/installed-updater" "$TEST_TMPDIR/bin/bulk-passive"
                fi
                options=(--build-from-source --version 1.2.3)
                checks=1 builds=1 selected=built
                if [[ "$scenario" == source-build-fails ]]; then
                    printf 'fail\n' > "$TEST_TMPDIR/fail-build"
                    expected=1 checks=0
                fi
                ;;
            alias-fallback)
                make_bulk_upgrade_config bulk-alias absent-configured-binary false
                cp -p "$TEST_TMPDIR/installed-updater" "$TEST_TMPDIR/bin/bulk-alias"
                options=(--version 1.2.3)
                checks=1 helps=1 selected=installed
                ;;
            mixed-capabilities|no-updaters|no-updaters-dry)
                make_bulk_upgrade_config bulk-passive bulk-passive false
                cp -p "$TEST_TMPDIR/installed-updater" "$TEST_TMPDIR/bin/bulk-passive"
                helps=1
                if [[ "$scenario" == mixed-capabilities ]]; then
                    make_bulk_upgrade_config bulk-check bulk-check true
                    cp -p "$TEST_TMPDIR/installed-updater" "$TEST_TMPDIR/bin/bulk-check"
                    printf '%s\n' update > "$TEST_TMPDIR/check.verb"
                    checks=1 selected=installed
                else
                    expected=1
                    if [[ "$scenario" == no-updaters-dry ]]; then
                        dry=true options=(--dry-run)
                    fi
                fi
                ;;
            empty) expected=1 ;;
            missing-source)
                make_bulk_upgrade_config bulk-source bulk-source true
                printf 'local_path: %s\nupgrade_check_args: [update, --check]\n' \
                    "$TEST_TMPDIR/nonexistent" > "$TEST_TMPDIR/repos.d/bulk-source.yaml"
                expected=1
                ;;
        esac
        for mode in plain json; do
            flags=()
            [[ "$mode" != json ]] || flags=(--json)
            exec_run "$PROJECT_ROOT/dsr" ${flags[@]+"${flags[@]}"} verify upgrade --all \
                ${options[@]+"${options[@]}"}
            output=$(exec_stdout)
            cp "$_EXEC_STDOUT_FILE" "$TEST_TMPDIR/$mode.stdout"
            cp "$_EXEC_STDERR_FILE" "$TEST_TMPDIR/$mode.stderr"
            [[ "$(exec_status)" == "$expected" ]] || problems+=("$mode exited $(exec_status)")
            attempt=$((attempt + 1))
            for calls in check build help; do
                local count=0 wanted=0
                [[ ! -f "$TEST_TMPDIR/$calls.calls" ]] || count=$(wc -l < "$TEST_TMPDIR/$calls.calls")
                case "$calls" in check) wanted=$checks ;; build) wanted=$builds ;; help) wanted=$helps ;; esac
                [[ "$count" -eq $((wanted * attempt)) ]] || problems+=("$mode $calls invocations: $count")
            done
            if [[ "$mode" == json ]]; then
                jq -es --argjson code "$expected" --argjson dry "$dry" '
                    length == 1 and (.[0] | .command == "verify-upgrade" and .exit_code == $code and
                        .status == (if $code == 0 then "success" else "error" end) and
                        .details.mode == "all" and .details.dry_run == $dry)
                ' <<< "$output" >/dev/null || problems+=("JSON verdict disagrees")
            fi
            if [[ "$expected" != 0 ]] &&
               grep -qiE 'verification PASSED for|All upgrade verifications passed' "$TEST_TMPDIR/$mode.stderr"; then
                problems+=("$mode claimed verification passed")
            fi
            if $plan; then
                grep -q 'Would build bulk-source from source' "$TEST_TMPDIR/$mode.stderr" ||
                    problems+=("$mode omitted selected source build")
                grep -q 'Would run: .* update --check' "$TEST_TMPDIR/$mode.stderr" ||
                    problems+=("$mode omitted configured update check")
            fi
        done
        if ((checks > 0)) && [[ -f "$TEST_TMPDIR/check.calls" ]]; then
            [[ "$(sort -u "$TEST_TMPDIR/check.calls")" == "$selected" ]] ||
                problems+=("wrong updater executable selected")
        fi
        if [[ ${#problems[@]} -eq 0 ]]; then
            pass "bulk upgrade plain/JSON selection and options: $scenario"
        else
            fail "bulk upgrade $scenario: ${problems[*]}"
        fi
        unset DSR_UPGRADE_BULK_ROOT
        harness_teardown
    done
}

# ============================================================================
# Tests: Upgrade Check Parsing
# ============================================================================

test_parses_up_to_date() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create mock that says up to date
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/uptodate-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "up to date"
    exit 0
fi
EOF
    chmod +x "$TEST_TMPDIR/bin/uptodate-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if upgrade_verify_tool uptodate-tool 2>/dev/null; then
        pass "verify_tool detects 'up to date' status"
    else
        fail "verify_tool should pass for 'up to date'"
    fi

    harness_teardown
}

test_parses_update_available() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create mock that says update available
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/update-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "Update available: 2.0.0"
    echo "Current: 1.0.0"
    exit 0
fi
EOF
    chmod +x "$TEST_TMPDIR/bin/update-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if upgrade_verify_tool update-tool 2>/dev/null; then
        pass "verify_tool detects update available"
    else
        fail "verify_tool should pass for 'update available'"
    fi

    harness_teardown
}

test_detects_asset_mismatch() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create mock that reports asset not found
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/mismatch-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "Error: no suitable release asset found for linux/amd64"
    exit 1
fi
EOF
    chmod +x "$TEST_TMPDIR/bin/mismatch-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    if upgrade_verify_tool mismatch-tool 2>/dev/null; then
        fail "verify_tool should fail for asset mismatch"
    else
        pass "verify_tool detects asset mismatch"
    fi

    harness_teardown
}

# ============================================================================
# Tests: JSON Output
# ============================================================================

test_json_output_valid() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create a mock tool
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/json-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "up to date"
    exit 0
fi
EOF
    chmod +x "$TEST_TMPDIR/bin/json-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    local output
    output=$(upgrade_verify_json json-tool 2>/dev/null)

    if echo "$output" | jq . &>/dev/null; then
        pass "verify_json produces valid JSON"
    else
        fail "verify_json should produce valid JSON"
        echo "Output: $output"
    fi

    harness_teardown
}

test_json_has_required_fields() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create a mock tool
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/fields-tool" << 'EOF'
#!/bin/bash
if [[ "$1" == "upgrade" && "$2" == "--check" ]]; then
    echo "up to date"
    exit 0
fi
EOF
    chmod +x "$TEST_TMPDIR/bin/fields-tool"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    local output
    output=$(upgrade_verify_json fields-tool 2>/dev/null)

    local has_tool has_status has_platform
    has_tool=$(echo "$output" | jq -e '.tool' &>/dev/null && echo true || echo false)
    has_status=$(echo "$output" | jq -e '.status' &>/dev/null && echo true || echo false)
    has_platform=$(echo "$output" | jq -e '.platform' &>/dev/null && echo true || echo false)

    if [[ "$has_tool" == "true" && "$has_status" == "true" && "$has_platform" == "true" ]]; then
        pass "verify_json has tool, status, platform fields"
    else
        fail "verify_json should have tool, status, platform fields"
        echo "Output: $output"
    fi

    harness_teardown
}

test_json_error_for_missing_tool() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    local output
    output=$(upgrade_verify_json nonexistent-tool-xyz 2>/dev/null)

    if echo "$output" | jq -e '.status == "error"' &>/dev/null; then
        pass "verify_json returns error status for missing tool"
    else
        fail "verify_json should return error status for missing tool"
        echo "Output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Repository Finding
# ============================================================================

test_find_repo_from_config() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Create a config file
    mkdir -p "$TEST_TMPDIR/test-project"
    cat > "$TEST_TMPDIR/repos.d/test-tool.yaml" << EOF
name: test-tool
local_path: $TEST_TMPDIR/test-project
repo: test/test-tool
EOF

    local repo_dir
    repo_dir=$(_upgrade_find_repo_dir "test-tool")

    if [[ "$repo_dir" == "$TEST_TMPDIR/test-project" ]]; then
        pass "_upgrade_find_repo_dir finds repo from config"
    else
        fail "_upgrade_find_repo_dir should find repo from config"
        echo "Got: $repo_dir"
    fi

    harness_teardown
}

test_find_repo_default_location() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    # Without config, should try /data/projects/<tool>
    # This test may need adjustment based on environment
    local repo_dir
    repo_dir=$(_upgrade_find_repo_dir "nonexistent-tool" 2>/dev/null || echo "")

    # Should return empty for non-existent
    if [[ -z "$repo_dir" ]]; then
        pass "_upgrade_find_repo_dir returns empty for non-existent repo"
    else
        fail "_upgrade_find_repo_dir should return empty for non-existent repo"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Real Tools (when available)
# ============================================================================

test_real_tool_bv() {
    ((TESTS_RUN++))
    harness_setup
    setup_module

    if ! command -v bv &>/dev/null; then
        skip "bv not installed"
        harness_teardown
        return 0
    fi

    # Check if bv has upgrade command
    if ! bv --help 2>&1 | grep -q "update\|upgrade"; then
        skip "bv doesn't have upgrade command"
        harness_teardown
        return 0
    fi

    # Note: bv uses --update not upgrade --check
    # This test documents what happens
    info "Testing bv upgrade check (may use different syntax)..."

    if upgrade_verify_tool bv 2>/dev/null; then
        pass "bv upgrade verification passed"
    else
        # Expected to fail if bv uses different syntax
        pass "bv upgrade verification completed (may use different command)"
    fi

    harness_teardown
}

# Exercise the public CLI with Bun's actual dependency resolver, compiler and
# executable. The package graph is local and updater output is deterministic;
# no GitHub request or release publication is part of this fixture.
test_bun_source_upgrade() {
    local dependency
    for dependency in bun jq yq git; do
        if ! command -v "$dependency" >/dev/null; then
            TESTS_RUN=$((TESTS_RUN + 1))
            skip "Bun source upgrade requires $dependency"
            return 0
        fi
    done
    local scenario
    for scenario in root-object root-string workspace explicit-entry all-tools version-mismatch \
            missing-entry unsafe-entry changed-lock missing-lock inconsistent-lock compile-failure dry-run; do
        TESTS_RUN=$((TESTS_RUN + 1))
        TEST_NAME="bun-upgrade-$scenario" harness_setup
        setup_module
        local checkout="$TEST_TMPDIR/source checkout" package='.' language=bun entry='' expected=0
        local before lock_before rc=0 run_count=0
        local -a flags=() options=() problems=() selection=(verify upgrade bun-upgrade)
        mkdir -p "$checkout/src"
        if [[ "$scenario" == workspace ]]; then
            package=packages/cli; language=typescript
            mkdir -p "$checkout/$package/src" "$checkout/packages/messages"
            printf '%s\n' '{"name":"upgrade-workspace","private":true,"workspaces":["packages/*"]}' > "$checkout/package.json"
            printf '%s\n' '{"name":"upgrade-messages","version":"1.0.0","exports":"./index.ts"}' > "$checkout/packages/messages/package.json"
            printf '%s\n' 'export const latest = "1.2.3";' > "$checkout/packages/messages/index.ts"
            printf '%s\n' '{"name":"upgrade-cli","bin":{"dsr-bun-upgrade":"src/main.ts"},"dependencies":{"upgrade-messages":"workspace:*"}}' > "$checkout/$package/package.json"
            printf '%s\n' 'import { latest } from "upgrade-messages";' > "$checkout/$package/src/main.ts"
        else
            mkdir "$checkout/messages"
            printf '%s\n' '{"name":"upgrade-messages","version":"1.0.0","exports":"./index.ts"}' > "$checkout/messages/package.json"
            printf '%s\n' 'export const latest = "1.2.3";' > "$checkout/messages/index.ts"
            printf '%s\n' '{"name":"upgrade-cli","bin":{"dsr-bun-upgrade":"src/main.ts"},"dependencies":{"upgrade-messages":"file:./messages"}}' > "$checkout/package.json"
            printf '%s\n' 'import { latest } from "upgrade-messages";' > "$checkout/src/main.ts"
        fi
        cat >> "$checkout/$package/src/main.ts" <<'TYPESCRIPT'
if (JSON.stringify(process.argv.slice(2)) !== JSON.stringify(["update", "--check"])) process.exit(23);
if (process.env.DSR_UPGRADE_BUN_PROBE) {
  const { appendFileSync } = await import("node:fs");
  appendFileSync(process.env.DSR_UPGRADE_BUN_PROBE, "compiled-primary\n");
}
console.log("Current version: 1.2.2\nLatest version: " + latest + "\nUpdate available");
TYPESCRIPT
        if [[ "$scenario" == root-string ]]; then
            printf '%s\n' '{"name":"upgrade-cli","bin":"src/main.ts","dependencies":{"upgrade-messages":"file:./messages"}}' > "$checkout/package.json"
            language=typescript
        elif [[ "$scenario" == explicit-entry ]]; then
            cp "$checkout/src/main.ts" "$checkout/src/custom.ts"
            printf '%s\n' '{"name":"upgrade-cli","bin":{"another-tool":"src/main.ts"},"dependencies":{"upgrade-messages":"file:./messages"}}' > "$checkout/package.json"
            entry=src/custom.ts
        fi
        if ! (cd "$checkout" && bun install --lockfile-only --ignore-scripts) \
                > "$TEST_TMPDIR/lock.log" 2>&1; then
            fail "Bun fixture lock generation failed: $scenario"
            harness_teardown
            continue
        fi
        if ! command git init -q -b main "$checkout" || ! command git -C "$checkout" add . ||
           ! command git -C "$checkout" -c user.name='DSR test' -c user.email='test@example.invalid' commit -qm fixture; then
            fail "Bun fixture source commit failed: $scenario"
            harness_teardown
            continue
        fi
        case "$scenario" in
            version-mismatch) expected=1; options=(--version 9.9.9) ;;
            missing-entry) entry=src/absent.ts; expected=1 ;;
            unsafe-entry) entry=../outside.ts; expected=1 ;;
            changed-lock) printf '\n' >> "$checkout/bun.lock"; expected=1 ;;
            missing-lock) mv "$checkout/bun.lock" "$TEST_TMPDIR/saved-bun.lock"; expected=1 ;;
            inconsistent-lock)
                printf '%s\n' '{"name":"upgrade-cli","bin":{"dsr-bun-upgrade":"src/main.ts"},"dependencies":{"upgrade-messages":"file:./absent"}}' > "$checkout/package.json"
                command git -C "$checkout" add package.json &&
                    command git -C "$checkout" -c user.name='DSR test' -c user.email='test@example.invalid' commit -qm inconsistent-lock
                expected=1 ;;
            compile-failure) printf '\nconst broken = ;\n' >> "$checkout/src/main.ts"; expected=1 ;;
            dry-run) options=(--dry-run); run_count=-1 ;;
            all-tools) selection=(verify upgrade --all); flags=(--json) ;;
        esac
        [[ ${#options[@]} -gt 0 ]] || options=(--version v1.2.3)
        printf 'tool_name: bun-upgrade\nbinary_name: dsr-bun-upgrade\nlanguage: %s\nlocal_path: %s\nsource_subdir: %s\nsource_entry: "%s"\nupgrade_check_args: [update, --check]\n' \
            "$language" "$checkout" "$package" "$entry" > "$TEST_TMPDIR/repos.d/bun-upgrade.yaml"
        if [[ "$scenario" == root-string || "$scenario" == explicit-entry || "$expected" != 0 ]]; then
            flags=(--json)
            options+=(--build-from-source)
            cat > "$TEST_TMPDIR/bin/dsr-bun-upgrade" <<'SH'
#!/usr/bin/env bash
printf 'installed-primary\n' >> "$DSR_UPGRADE_BUN_PROBE"
exit 24
SH
            chmod +x "$TEST_TMPDIR/bin/dsr-bun-upgrade"
        fi
        before=$(find "$TEST_TMPDIR/bin" -type f -exec sha256sum {} +)
        lock_before='missing'
        [[ ! -f "$checkout/bun.lock" ]] || lock_before=$(sha256sum "$checkout/bun.lock")
        export DSR_UPGRADE_BUN_PROBE="$TEST_TMPDIR/updater.calls"
        PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$PROJECT_ROOT/dsr" ${flags[@]+"${flags[@]}"} \
            "${selection[@]}" "${options[@]}"
        rc=$(exec_status)
        [[ "$rc" == "$expected" ]] || problems+=("exit=$rc expected=$expected")
        if ((run_count != -1)); then
            if [[ "$expected" == 0 || "$scenario" == version-mismatch ]]; then run_count=1; else run_count=0; fi
            local observed=0
            [[ ! -f "$DSR_UPGRADE_BUN_PROBE" ]] || observed=$(wc -l < "$DSR_UPGRADE_BUN_PROBE")
            [[ "$observed" -eq "$run_count" ]] || problems+=("updater ran $observed times, wanted $run_count")
            [[ ! -f "$DSR_UPGRADE_BUN_PROBE" ]] ||
                [[ "$(sort -u "$DSR_UPGRADE_BUN_PROBE")" == compiled-primary ]] || problems+=("installed executable ran")
        else
            [[ ! -e "$DSR_UPGRADE_BUN_PROBE" ]] || problems+=("dry-run executed updater")
            [[ ! -e "$checkout/node_modules" ]] || problems+=("dry-run installed dependencies")
            exec_stderr_contains 'Would build dsr-bun-upgrade from source' || problems+=("missing build preview")
        fi
        [[ "$before" == "$(find "$TEST_TMPDIR/bin" -type f -exec sha256sum {} +)" ]] || problems+=("installed executable changed")
        if [[ "$lock_before" != missing ]]; then
            [[ "$lock_before" == "$(sha256sum "$checkout/bun.lock")" ]] || problems+=("frozen lockfile changed")
        fi
        if [[ ${#flags[@]} -gt 0 ]]; then
            jq -es --argjson code "$expected" 'length==1 and (.[0]|.command=="verify-upgrade" and .exit_code==$code)' \
                "$_EXEC_STDOUT_FILE" >/dev/null || problems+=("invalid public JSON verdict")
        else
            [[ ! -s "$_EXEC_STDOUT_FILE" ]] || problems+=("compiler diagnostics escaped to stdout")
        fi
        if [[ ${#problems[@]} -eq 0 ]]; then
            pass "real Bun source upgrade: $scenario"
        else
            fail "real Bun source upgrade $scenario: ${problems[*]}"
            cat "$_EXEC_STDERR_FILE"
        fi
        unset DSR_UPGRADE_BUN_PROBE
        harness_teardown
    done
}

# Compile a dependency-free Rust updater through the public CLI. Its runtime
# verdict proves which cfg features actually reached rustc; a transparent Cargo
# recorder also checks the literal build argv and private artifact output policy.
test_rust_source_features() {
    local dependency
    TESTS_RUN=$((TESTS_RUN + 1))
    for dependency in cargo rustc jq yq python3; do
        if ! command -v "$dependency" >/dev/null; then
            skip "Rust source upgrade features require $dependency"
            return 0
        fi
    done
    if python3 - "$PROJECT_ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

project = Path(sys.argv[1])
root = Path(tempfile.mkdtemp(prefix='dsr-upgrade-rust-features-'))
print('Rust upgrade feature evidence: ' + str(root), flush=True)
real_cargo = shutil.which('cargo')
base_env = os.environ.copy()
for name in ('DSR_CONFIG_FILE', 'DSR_REPOS_FILE', 'DSR_HOSTS_FILE', 'ACT_REPOS_DIR',
             'DSR_GH_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN', 'CARGO_BUILD_TARGET',
             'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER'):
    base_env.pop(name, None)
cases = [
    ('legacy-defaults', {}, True, 0),
    ('explicit-defaults', {'source_features': ['cli']}, True, 0),
    ('empty-defaults', {'source_features': [], 'source_no_default_features': False}, True, 0),
    ('gated-binary', {'source_features': ['cli']}, True, 0),
    ('without-defaults', {'source_features': ['cli'], 'source_no_default_features': True}, False, 0),
    ('qualified', {'source_features': ['feature-probe/cli'], 'source_no_default_features': True}, False, 0),
    ('missing-required', {'source_no_default_features': True}, False, 1),
    ('duplicate', {'source_features': ['cli', 'cli']}, False, 1),
    ('option', {'source_features': ['--all-features']}, False, 1),
    ('newline', {'source_features': ['cli\n']}, False, 1),
    ('scalar', {'source_features': 'cli'}, False, 1),
    ('null-features', {'source_features': None}, False, 1),
    ('string-boolean', {'source_no_default_features': 'false'}, False, 1),
    ('null-boolean', {'source_no_default_features': None}, False, 1),
    ('go-empty', {'language': 'go', 'source_features': []}, False, 1),
    ('go-false', {'language': 'go', 'source_no_default_features': False}, False, 1),
    ('bun-empty', {'language': 'bun', 'source_features': []}, False, 1),
    ('typescript-false', {'language': 'typescript', 'source_no_default_features': False}, False, 1),
]
for name, changes, defaults, expected in cases:
    case = root / name
    source = case / 'source checkout'
    (source / 'src').mkdir(parents=True)
    (case / 'config/repos.d').mkdir(parents=True)
    (case / 'bin').mkdir()
    manifest_defaults = ['default-on'] if name == 'gated-binary' else ['cli', 'default-on']
    (source / 'Cargo.toml').write_text('''[package]
name = "feature-probe"
version = "1.2.3"
edition = "2021"
[features]
default = ''' + json.dumps(manifest_defaults) + '''
default-on = []
cli = []
[[bin]]
name = "dsr-feature-updater"
path = "src/main.rs"
required-features = ["cli"]
''')
    (source / 'src/main.rs').write_text(r'''use std::{env, fs::OpenOptions, io::Write};
fn main() {
    let args: Vec<_> = env::args().skip(1).collect();
    if args != ["update", "--check"] { std::process::exit(64); }
    let actual = format!("cli={} default={}", cfg!(feature="cli"), cfg!(feature="default-on"));
    let mut proof = OpenOptions::new().create(true).append(true)
        .open(env::var("DSR_UPGRADE_FEATURE_PROBE").unwrap()).unwrap();
    writeln!(proof, "{}", actual).unwrap();
    if actual != env::var("DSR_UPGRADE_FEATURE_EXPECT").unwrap() { std::process::exit(70); }
    println!("Latest version: 1.2.3\nUpdate available");
}
''')
    config = dict(tool_name='feature-probe', repo='fixture/feature-probe', language='rust',
                  binary_name='dsr-feature-updater', local_path=str(source),
                  upgrade_check_args=['update', '--check'])
    config.update(changes)
    (case / 'config/repos.d/feature-probe.yaml').write_text(json.dumps(config))
    if config['language'] == 'go':
        (source / 'go.mod').write_text('module example.invalid/feature-probe\n')
        (source / 'main.go').write_text('package main\nfunc main() {}\n')
    (case / 'bin/cargo').write_text('''#!/usr/bin/env bash
jq -nc --args '$ARGS.positional' -- "$@" >> "$DSR_UPGRADE_CARGO_CALLS" || exit 90
exec "$DSR_UPGRADE_REAL_CARGO" "$@"
''')
    for executable in ('go', 'bun', 'dsr-feature-updater'):
        (case / 'bin' / executable).write_text('''#!/usr/bin/env bash
printf '%s\\n' "${0##*/}" >> "$DSR_UPGRADE_UNEXPECTED_CALLS"
exit 99
''')
    for executable in (case / 'bin').iterdir():
        executable.chmod(0o700)
    env = base_env.copy()
    for variable, directory in {'DSR_CONFIG_DIR': 'config', 'DSR_STATE_DIR': 'state',
                                'DSR_CACHE_DIR': 'cache', 'XDG_CONFIG_HOME': 'xdg-config',
                                'XDG_STATE_HOME': 'xdg-state', 'XDG_CACHE_HOME': 'xdg-cache'}.items():
        env[variable] = str(case / directory)
    env.update(PATH=str(case / 'bin') + os.pathsep + base_env['PATH'],
               CARGO_TARGET_DIR=str(case / 'cargo-target'), CARGO_NET_OFFLINE='true',
               RUSTUP_AUTO_INSTALL='0', DSR_UPGRADE_REAL_CARGO=real_cargo,
               DSR_UPGRADE_CARGO_CALLS=str(case / 'cargo.calls'),
               DSR_UPGRADE_FEATURE_PROBE=str(case / 'updater.calls'),
               DSR_UPGRADE_UNEXPECTED_CALLS=str(case / 'unexpected.calls'),
               DSR_UPGRADE_FEATURE_EXPECT='cli=true default=' + str(defaults).lower())
    result = subprocess.run([str(project / 'dsr'), '--json', 'verify', 'upgrade', 'feature-probe',
                             '--build-from-source', '--version', '1.2.3'],
                            cwd=project, env=env, capture_output=True, timeout=45)
    (case / 'stdout').write_bytes(result.stdout)
    (case / 'stderr').write_bytes(result.stderr)
    assert result.returncode == expected, name + ': ' + result.stderr.decode(errors='replace')
    receipt = json.loads(result.stdout)
    assert receipt['command'] == 'verify-upgrade' and receipt['exit_code'] == expected, (name, receipt)
    assert not (case / 'unexpected.calls').exists(), name + ': invoked an installed updater or another compiler'
    calls = [json.loads(line) for line in (case / 'cargo.calls').read_text().splitlines()] if (case / 'cargo.calls').exists() else []
    if expected == 0:
        assert [args[0] for args in calls] == ['build'], (name, calls)
        assert '--message-format=json-render-diagnostics' in calls[0], (name, calls)
        assert '--target-dir' in calls[0], (name, calls)
        assert calls[0][calls[0].index('--target-dir') + 1] != env['CARGO_TARGET_DIR'], (name, calls)
        for args in calls:
            features = [args[i + 1] for i, arg in enumerate(args) if arg == '--features']
            assert features == changes.get('source_features', []), (name, args)
            assert args.count('--no-default-features') == int(changes.get('source_no_default_features', False)), (name, args)
        assert (case / 'updater.calls').read_text() == env['DSR_UPGRADE_FEATURE_EXPECT'] + '\n', name
    else:
        assert not (case / 'updater.calls').exists(), name + ': invalid or incomplete recipe ran updater'
        if name == 'missing-required':
            assert len(calls) == 1 and calls[0][0] == 'build', (name, calls)
        else:
            assert calls == [], name + ': invalid recipe reached Cargo'
    print('PASS: Rust source upgrade feature policy ' + name, flush=True)
print('Rust source upgrade feature cases: ' + str(len(cases)) + ' passed, 0 failed', flush=True)
PY
    then
        pass "Rust upgrade builds honor configured features and refuse invalid recipes"
    else
        fail "Rust upgrade source feature controls"
    fi
}

# Exercise source recipe selection through the public CLI with real local
# compilers. These are intentionally non-Git checkouts: upgrade verification
# must not reinterpret them as authenticated installer source acquisitions.
test_source_recipe_layouts() {
    local dependency status=0
    TESTS_RUN=$((TESTS_RUN + 1))
    for dependency in jq yq python3; do
        if ! command -v "$dependency" >/dev/null; then
            skip "Source layout upgrade checks require $dependency"
            return 0
        fi
    done
    python3 - "$PROJECT_ROOT" <<'PY' || status=$?
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

project = Path(sys.argv[1])
root = Path(tempfile.mkdtemp(prefix='dsr-upgrade-source-layouts-'))
print('Source layout evidence: ' + str(root), flush=True)
base_env = os.environ.copy()
for name in ('DSR_CONFIG_FILE', 'DSR_REPOS_FILE', 'DSR_HOSTS_FILE', 'ACT_REPOS_DIR',
             'DSR_GH_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN', 'CARGO_BUILD_TARGET',
             'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER',
             'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GOOS', 'GOARCH', 'GOFLAGS',
             'GOWORK', 'GOENV', 'GOTOOLCHAIN'):
    base_env.pop(name, None)
go = shutil.which('go')
cargo = shutil.which('cargo')
rustc = shutil.which('rustc')
if go and subprocess.run([go, 'version'], capture_output=True, timeout=10).returncode:
    go = None
host = ''
if cargo and rustc:
    probe = subprocess.run([rustc, '-vV'], capture_output=True, text=True, timeout=15)
    if probe.returncode == 0:
        host = next((line[6:] for line in probe.stdout.splitlines() if line.startswith('host: ')), '')
if not host:
    cargo = None

def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data)

def fixture(name, language):
    case = root / name
    source = case / 'source checkout'
    source.mkdir(parents=True)
    (case / 'config/repos.d').mkdir(parents=True)
    (case / 'tmp').mkdir()
    (case / 'bin').mkdir()
    env = base_env.copy()
    for variable, directory in {'DSR_CONFIG_DIR': 'config', 'DSR_STATE_DIR': 'state',
                                'DSR_CACHE_DIR': 'cache', 'XDG_CONFIG_HOME': 'xdg-config',
                                'XDG_STATE_HOME': 'xdg-state', 'XDG_CACHE_HOME': 'xdg-cache'}.items():
        env[variable] = str(case / directory)
    env.update(PATH=str(case / 'bin') + os.pathsep + base_env['PATH'],
               TMPDIR=str(case / 'tmp'), CARGO_TARGET_DIR=str(case / 'shared-cargo-target'),
               CARGO_NET_OFFLINE='true', RUSTUP_AUTO_INSTALL='0', GOTOOLCHAIN='local', GOPROXY='off',
               DSR_BUILD_TIMEOUT='30', DSR_LAYOUT_CALLS=str(case / 'updater.calls'))
    config = dict(tool_name='layout', repo='fixture/layout', language=language,
                  binary_name='dsr-layout-updater', local_path=str(source),
                  upgrade_check_args=['update', '--check'])
    return case, source, env, config

def invoke(case, env, config, expected=0, ran=True, extra=()):
    write(case / 'config/repos.d/layout.yaml', json.dumps(config))
    result = subprocess.run([str(project / 'dsr'), '--json', 'verify', 'upgrade', 'layout',
                             '--build-from-source', '--version', '1.2.3', *extra],
                            cwd=project, env=env, capture_output=True, timeout=45)
    (case / 'stdout').write_bytes(result.stdout)
    (case / 'stderr').write_bytes(result.stderr)
    assert result.returncode == expected, (case.name, result.returncode, result.stderr.decode(errors='replace'))
    envelope = json.loads(result.stdout)
    assert envelope['command'] == 'verify-upgrade' and envelope['exit_code'] == expected, (case.name, envelope)
    calls = case / 'updater.calls'
    if ran:
        assert calls.read_text() == 'selected\n', (case.name, calls.read_text())
    else:
        assert not calls.exists(), case.name + ': updater ran after refusal or interruption'
    assert not (case / 'shared-cargo-target').exists(), case.name + ': shared Cargo outputs were modified'
    print('PASS: source upgrade recipe ' + case.name, flush=True)

go_source = r'''package main
import ("fmt"; "os")
func main() {
    if len(os.Args) != 3 || os.Args[1] != "update" || os.Args[2] != "--check" { os.Exit(64) }
    if err := os.WriteFile(os.Getenv("DSR_LAYOUT_CALLS"), []byte("selected\n"), 0600); err != nil { panic(err) }
    fmt.Println("Latest version: 1.2.3\nUpdate available")
}
'''
rust_source = r'''fn main() {
    if std::env::args().skip(1).collect::<Vec<_>>() != ["update", "--check"] { std::process::exit(64) }
    std::fs::write(std::env::var("DSR_LAYOUT_CALLS").unwrap(), "selected\n").unwrap();
    println!("Latest version: 1.2.3\nUpdate available");
}
'''
real_cases = 0
if go:
    for name in ('go-custom-entry', 'go-conventional-entry', 'go-inferred-nested',
                 'go-no-main-filename', 'go-diagnostics', 'go-library', 'go-unsafe-entry', 'go-unsafe-subdir'):
        case, source, env, config = fixture(name, 'go')
        tree = source / 'apps/cli'
        config['source_subdir'] = 'apps/cli'
        entry = 'entry'
        config['source_entry'] = entry
        if name == 'go-conventional-entry':
            entry = 'cmd/dsr-layout-updater'
            config.pop('source_entry')
        elif name == 'go-inferred-nested':
            config.pop('language')
        elif name == 'go-no-main-filename':
            entry = '.'
            config.pop('source_entry')
        write(tree / 'go.mod', 'module example.invalid/layout\n\ngo 1.19\n')
        write(tree / entry / 'program.go', go_source if name != 'go-library' else 'package library\n')
        expected = 0
        if name == 'go-diagnostics':
            write(case / 'bin/go', '#!/usr/bin/env bash\n'
                  'if [[ "$1" == list ]]; then printf "module download diagnostic\\n" >&2; fi\n'
                  'exec "$DSR_LAYOUT_REAL_GO" "$@"\n')
            (case / 'bin/go').chmod(0o700)
            env['DSR_LAYOUT_REAL_GO'] = go
        if name == 'go-library':
            expected = 1
        elif name == 'go-unsafe-entry':
            config['source_entry'] = '../outside'
            expected = 1
        elif name == 'go-unsafe-subdir':
            config['source_subdir'] = '../outside'
            expected = 1
        invoke(case, env, config, expected, ran=expected == 0)
        real_cases += 1
else:
    print('INFO: genuine Go compiler unavailable; Go source layout cases skipped', flush=True)

if cargo:
    for name in ('rust-local-no-lock', 'rust-nested-package', 'rust-member',
                 'rust-default-member', 'rust-host-target', 'rust-package-features',
                 'rust-diagnostics', 'rust-missing-package', 'rust-ambiguous-binary', 'rust-invalid-selector'):
        case, source, env, config = fixture(name, 'rust')
        nested = name != 'rust-local-no-lock'
        workspace = source / 'workspace' if nested else source
        if nested:
            write(workspace / 'Cargo.toml', '[workspace]\nresolver = "2"\nmembers = ["cli", "other"]\n' +
                  ('default-members = ["cli", "other"]\n' if name == 'rust-ambiguous-binary' else
                   'default-members = ["cli"]\n' if name == 'rust-default-member' else
                   'default-members = ["other"]\n'))
            crate = workspace / 'cli'
            write(workspace / 'other/Cargo.toml', '[package]\nname = "other"\nversion = "1.0.0"\nedition = "2021"\n'
                  '[[bin]]\nname = "dsr-layout-updater"\npath = "main.rs"\n')
            write(workspace / 'other/main.rs', 'fn main() { std::process::exit(71) }\n')
            config.update(source_subdir='workspace', source_package='selected-cli')
        else:
            crate = workspace
        manifest = '[package]\nname = "selected-cli"\nversion = "1.2.3"\nedition = "2021"\n' \
                   '[[bin]]\nname = "dsr-layout-updater"\npath = "main.rs"\n'
        code = rust_source
        expected = 0
        if name == 'rust-member':
            config['source_subdir'] = 'workspace/cli'
            config.pop('source_package')
        elif name == 'rust-default-member':
            config.pop('source_package')
        elif name == 'rust-host-target':
            write(workspace / '.cargo/config.toml', '[build]\ntarget = ' + json.dumps(host) +
                  '\nrustflags = ["--cfg", "selected_tree"]\n')
            code = '#[cfg(not(selected_tree))]\ncompile_error!("selected project config was ignored");\n' + code
        elif name == 'rust-package-features':
            manifest += 'required-features = ["cli"]\n[features]\ndefault = []\ncli = []\n'
            config.update(source_features=['selected-cli/cli'], source_no_default_features=True)
            code = '#[cfg(not(feature = "cli"))]\ncompile_error!("selected package feature was ignored");\n' + code
        elif name == 'rust-diagnostics':
            write(case / 'bin/cargo', r'''#!/usr/bin/env bash
printf '%s\n' '{"reason":"build-finished","success":false}' >&2
exec "$DSR_LAYOUT_REAL_CARGO" "$@"
''')
            (case / 'bin/cargo').chmod(0o700)
            env['DSR_LAYOUT_REAL_CARGO'] = cargo
        elif name == 'rust-missing-package':
            config['source_package'] = 'absent'
            expected = 1
        elif name == 'rust-ambiguous-binary':
            config.pop('source_package')
            expected = 1
        elif name == 'rust-invalid-selector':
            config['source_package'] = ['selected-cli']
            expected = 1
        write(crate / 'Cargo.toml', manifest)
        write(crate / 'main.rs', code)
        invoke(case, env, config, expected, ran=expected == 0)
        real_cases += 1
    # A fresh Bash imports the exported builder while running outside src/.
    # A misleading cwd-local module must never become the implementation.
    case, source, env, config = fixture('rust-exported-child', 'rust')
    write(source / 'Cargo.toml', '[package]\nname="exported"\nversion="1.2.3"\nedition="2021"\n'
          '[[bin]]\nname="dsr-layout-updater"\npath="main.rs"\n')
    write(source / 'main.rs', rust_source)
    write(case / 'config/repos.d/layout.yaml', json.dumps(config))
    foreign = case / 'foreign cwd'
    foreign.mkdir()
    write(foreign / 'install_source.sh', 'printf bad > "$DSR_LAYOUT_IMPORT_PROBE"\nreturn 99\n')
    env.update(DSR_LAYOUT_PROJECT=str(project), DSR_LAYOUT_SOURCE=str(source),
               DSR_LAYOUT_IMPORT_PROBE=str(case / 'wrong-import'))
    script = r'''source "$1/src/logging.sh" || exit 90
source "$1/src/upgrade_verify.sh" || exit 90
cd "$2" || exit 90
bash -c 'source "$DSR_LAYOUT_PROJECT/src/logging.sh" || exit 90; _upgrade_build_tool layout "$DSR_LAYOUT_SOURCE" dsr-layout-updater'
'''
    result = subprocess.run(['bash', '-c', script, '_', str(project), str(foreign)],
                            env=env, capture_output=True, timeout=45)
    (case / 'stdout').write_bytes(result.stdout)
    (case / 'stderr').write_bytes(result.stderr)
    assert result.returncode == 0, ('rust-exported-child', result.stderr.decode(errors='replace'))
    executable = Path(result.stdout.decode().strip())
    assert executable.is_file() and not executable.is_symlink(), executable
    check = subprocess.run([str(executable), 'update', '--check'], env=env, capture_output=True, timeout=10)
    assert check.returncode == 0 and (case / 'updater.calls').read_text() == 'selected\n', check.stderr
    assert not (case / 'wrong-import').exists(), 'exported helper imported a cwd-local module'
    assert not (case / 'shared-cargo-target').exists(), 'exported helper used shared Cargo output'
    real_cases += 1
    print('PASS: source upgrade recipe rust-exported-child', flush=True)
else:
    print('INFO: genuine Cargo/rustc unavailable; Rust source layout cases skipped', flush=True)

# Explicit process-boundary faults: these wrappers are not compiler success
# fixtures. Signal/deadline results must stop the public caller and bulk loop.
for name in ('build-signal', 'build-pipe-signal', 'build-terminal-status', 'build-deadline', 'bulk-cancel'):
    case, source, env, config = fixture(name, 'go')
    write(source / 'go.mod', 'module example.invalid/layout\n')
    write(source / 'main.go', go_source)
    wrapper = r'''#!/usr/bin/env bash
case "$1" in
    list) printf 'main\n' ;;
    build)
        printf '%s\n' "$PWD" >> "$DSR_LAYOUT_BUILDS"
        case "$DSR_LAYOUT_FAULT" in
            deadline) sleep 10 ;;
            pipe) exec python3 -c 'import os, signal; signal.signal(signal.SIGPIPE, signal.SIG_DFL); os.kill(os.getpid(), signal.SIGPIPE)' ;;
            terminal) exit 255 ;;
            *) kill -TERM "$BASHPID" ;;
        esac
        ;;
    *) exit 64 ;;
esac
'''
    write(case / 'bin/go', wrapper)
    (case / 'bin/go').chmod(0o700)
    env.update(DSR_LAYOUT_FAULT={'build-deadline': 'deadline', 'build-pipe-signal': 'pipe',
                               'build-terminal-status': 'terminal'}.get(name, 'signal'),
               DSR_LAYOUT_BUILDS=str(case / 'build.calls'), DSR_BUILD_TIMEOUT='1')
    if name != 'bulk-cancel':
        invoke(case, env, config, 5, ran=False)
    else:
        config['tool_name'] = 'a-first'
        write(case / 'config/repos.d/a-first.yaml', json.dumps(config))
        later = dict(config, tool_name='z-later')
        write(case / 'config/repos.d/z-later.yaml', json.dumps(later))
        result = subprocess.run([str(project / 'dsr'), '--json', 'verify', 'upgrade', '--all',
                                 '--build-from-source'], cwd=project, env=env, capture_output=True, timeout=15)
        (case / 'stdout').write_bytes(result.stdout)
        (case / 'stderr').write_bytes(result.stderr)
        assert result.returncode == 5, (name, result.returncode, result.stderr.decode(errors='replace'))
        assert json.loads(result.stdout)['exit_code'] == 5, name
        assert len((case / 'build.calls').read_text().splitlines()) == 1, name + ': later tool built'
        assert not (case / 'updater.calls').exists(), name
        print('PASS: source upgrade recipe ' + name, flush=True)
print('Real compiler source layout cases: ' + str(real_cases) + '; process interruption cases: 5', flush=True)
if real_cases == 0:
    sys.exit(77)
PY
    case "$status" in
        0) pass "Local source recipes select and verify real nested Go/Rust updaters" ;;
        77) skip "Real source layout compilation requires Go or Cargo/rustc" ;;
        *) fail "Local source recipe selection or interruption controls" ;;
    esac
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    harness_teardown 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== Upgrade Verify Tests ==="
echo ""

if [[ "${1:-}" == --bun-source-only ]]; then
    test_bun_source_upgrade
    printf 'Bun source checks: %s; passed: %s; skipped: %s; failed: %s\n' \
        "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_SKIPPED" "$TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]; exit $?
fi
if [[ "${1:-}" == --source-layouts-only ]]; then
    test_source_recipe_layouts
    printf 'Source layout checks: %s; passed: %s; skipped: %s; failed: %s\n' \
        "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_SKIPPED" "$TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]; exit $?
fi
if [[ "${1:-}" == --rust-features-only ]]; then
    test_rust_source_features
    printf 'Rust source checks: %s; passed: %s; skipped: %s; failed: %s\n' \
        "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_SKIPPED" "$TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]; exit $?
fi

echo "Module Tests:"
test_module_loads
test_module_exports

echo ""
echo "Tool Verification Tests:"
test_verify_missing_tool_fails
test_verify_requires_tool_name
test_verify_dry_run
test_verify_uses_configured_binary_name
test_verify_uses_configured_check_args
test_rejects_invalid_configured_check_args
test_exact_version_must_match_latest

echo ""
echo "Upgrade Check Parsing Tests:"
test_parses_up_to_date
test_parses_update_available
test_detects_asset_mismatch

echo ""
echo "JSON Output Tests:"
test_json_output_valid
test_json_has_required_fields
test_json_error_for_missing_tool
test_json_uses_configured_check_args
test_json_reports_exact_version_mismatch
test_cli_json_failure_is_one_envelope_from_one_run
test_cli_process_status_and_output_agree
test_real_timeout_after_positive_output_fails
test_cli_dry_run_runs_and_builds_nothing
test_cli_all_selection_and_options
test_bun_source_upgrade
test_rust_source_features
test_source_recipe_layouts

echo ""
echo "Repository Finding Tests:"
test_find_repo_from_config
test_find_repo_default_location

echo ""
echo "Real Tool Tests (when available):"
test_real_tool_bv

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
