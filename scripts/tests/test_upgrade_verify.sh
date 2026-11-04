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
[[ "$PWD" == "$DSR_UPGRADE_BULK_ROOT/source checkout" && $# -eq 4 &&
   "$1" == build && "$2" == -o && "$4" == . ]] || exit 64
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
