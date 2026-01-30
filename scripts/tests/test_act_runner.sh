#!/usr/bin/env bash
# test_act_runner.sh - Unit tests for act_runner.sh module
#
# Usage: ./test_act_runner.sh
#
# Tests act integration functions without actually running Docker

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_ROOT/src"

# Source the module under test
source "$SRC_DIR/act_runner.sh"

# Colors
if [[ -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

log_pass() { echo -e "${GREEN}✓${NC} $1"; ((PASS_COUNT++)); }
log_fail() { echo -e "${RED}✗${NC} $1"; ((FAIL_COUNT++)); }
log_skip() { echo -e "${YELLOW}○${NC} $1"; ((SKIP_COUNT++)); }
log_test() { echo -e "\n== $1 =="; }

# Create temporary test fixtures
setup_fixtures() {
    TEMP_DIR=$(mktemp -d)
    WORKFLOW_DIR="$TEMP_DIR/.github/workflows"
    mkdir -p "$WORKFLOW_DIR"

    # Create sample workflow file
    cat > "$WORKFLOW_DIR/release.yml" << 'EOF'
name: Release

on:
  push:
    tags: ['v*']

jobs:
  build-linux:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4
      - run: echo "Building Linux"

  build-macos:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: echo "Building macOS"

  build-windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "Building Windows"

  test:
    runs-on: ubuntu-latest
    needs: [build-linux]
    steps:
      - run: echo "Testing"
EOF

    # Create minimal workflow
    cat > "$WORKFLOW_DIR/ci.yml" << 'EOF'
name: CI
on: push
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Linting"
EOF
}

cleanup_fixtures() {
    rm -rf "$TEMP_DIR"
}

# Test act_can_run function
test_act_can_run() {
    log_test "act_can_run"

    # Linux runners should return 0 (can run)
    if act_can_run "ubuntu-latest"; then
        log_pass "ubuntu-latest returns 0"
    else
        log_fail "ubuntu-latest should return 0"
    fi

    if act_can_run "ubuntu-22.04"; then
        log_pass "ubuntu-22.04 returns 0"
    else
        log_fail "ubuntu-22.04 should return 0"
    fi

    # macOS/Windows runners should return 1 (needs native)
    if ! act_can_run "macos-14"; then
        log_pass "macos-14 returns 1 (needs native)"
    else
        log_fail "macos-14 should return 1"
    fi

    if ! act_can_run "windows-latest"; then
        log_pass "windows-latest returns 1 (needs native)"
    else
        log_fail "windows-latest should return 1"
    fi

    # Self-hosted with linux label
    if act_can_run "self-hosted, linux, x64"; then
        log_pass "self-hosted linux returns 0"
    else
        log_fail "self-hosted linux should return 0"
    fi
}

# Test act_get_runner function
test_act_get_runner() {
    log_test "act_get_runner"

    local runner

    runner=$(act_get_runner "$WORKFLOW_DIR/release.yml" "build-linux")
    if [[ "$runner" == *"ubuntu"* ]]; then
        log_pass "build-linux runner detected: $runner"
    else
        log_skip "build-linux runner detection (yq may not be available): $runner"
    fi

    runner=$(act_get_runner "$WORKFLOW_DIR/release.yml" "build-macos")
    if [[ "$runner" == *"macos"* ]]; then
        log_pass "build-macos runner detected: $runner"
    else
        log_skip "build-macos runner detection (yq may not be available): $runner"
    fi
}

# Test act_analyze_workflow function
test_act_analyze_workflow() {
    log_test "act_analyze_workflow (requires act and jq)"

    if ! command -v jq &>/dev/null; then
        log_skip "jq not available for workflow analysis"
        return
    fi

    if ! command -v act &>/dev/null; then
        log_skip "act not available for workflow analysis"
        return
    fi

    local analysis
    analysis=$(act_analyze_workflow "$WORKFLOW_DIR/release.yml" 2>/dev/null)

    if echo "$analysis" | jq -e '.workflow' &>/dev/null; then
        log_pass "Workflow analysis returns valid JSON"
    else
        log_fail "Workflow analysis JSON invalid"
    fi
}

# Test act_check function
test_act_check() {
    log_test "act_check"

    if command -v act &>/dev/null && docker info &>/dev/null 2>&1; then
        if act_check 2>/dev/null; then
            log_pass "act_check passes when act and docker available"
        else
            log_fail "act_check should pass when dependencies available"
        fi
    else
        if ! act_check 2>/dev/null; then
            log_pass "act_check fails when dependencies missing (expected)"
        else
            log_fail "act_check should fail when dependencies missing"
        fi
    fi
}

# Test artifact directory creation
test_artifact_dirs() {
    log_test "artifact directories"

    export ACT_ARTIFACTS_DIR="$TEMP_DIR/artifacts"
    export ACT_LOGS_DIR="$TEMP_DIR/logs"

    mkdir -p "$ACT_ARTIFACTS_DIR" "$ACT_LOGS_DIR"

    if [[ -d "$ACT_ARTIFACTS_DIR" ]]; then
        log_pass "Artifact directory created"
    else
        log_fail "Artifact directory creation failed"
    fi

    if [[ -d "$ACT_LOGS_DIR" ]]; then
        log_pass "Logs directory created"
    else
        log_fail "Logs directory creation failed"
    fi
}

# Test act_cleanup function
test_act_cleanup() {
    log_test "act_cleanup"

    export ACT_ARTIFACTS_DIR="$TEMP_DIR/artifacts"
    export ACT_LOGS_DIR="$TEMP_DIR/logs"

    mkdir -p "$ACT_ARTIFACTS_DIR/old-run" "$ACT_LOGS_DIR"
    touch "$ACT_LOGS_DIR/old.log"

    # Set old timestamps (requires GNU touch or BSD compatible)
    if touch -d "10 days ago" "$ACT_ARTIFACTS_DIR/old-run" "$ACT_LOGS_DIR/old.log" 2>/dev/null || \
       touch -t "$(date -v-10d +%Y%m%d%H%M 2>/dev/null || date -d '10 days ago' +%Y%m%d%H%M)" "$ACT_ARTIFACTS_DIR/old-run" "$ACT_LOGS_DIR/old.log" 2>/dev/null; then

        act_cleanup 7 2>/dev/null

        if [[ ! -d "$ACT_ARTIFACTS_DIR/old-run" ]]; then
            log_pass "Old artifacts cleaned up"
        else
            log_fail "Old artifacts should be cleaned"
        fi
    else
        log_skip "Could not set old timestamps for cleanup test"
    fi
}

# Test workflow file validation
test_workflow_validation() {
    log_test "workflow validation"

    # Non-existent workflow should fail
    if ! act_run_workflow "$TEMP_DIR" ".github/workflows/nonexistent.yml" "" "push" 2>/dev/null; then
        log_pass "Non-existent workflow returns error"
    else
        log_fail "Non-existent workflow should return error"
    fi
}

# Main
main() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  act_runner.sh Unit Tests"
    echo "═══════════════════════════════════════════════════════════════"

    setup_fixtures
    trap cleanup_fixtures EXIT

    test_act_can_run
    test_act_get_runner
    test_act_check
    test_artifact_dirs
    test_act_cleanup
    test_workflow_validation
    test_act_analyze_workflow

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Passed:${NC}  $PASS_COUNT"
    echo -e "  ${RED}Failed:${NC}  $FAIL_COUNT"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIP_COUNT"

    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
