#!/usr/bin/env bash
# test_install_gen.sh - Unit tests for install_gen.sh
#
# Tests cache/offline mode and gh release download fallback.
#
# Run: ./scripts/tests/test_install_gen.sh

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

# Temp directory for test isolation
TEMP_DIR=""

setup() {
    TEMP_DIR=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    export DSR_CONFIG_DIR="$TEMP_DIR/config/dsr"
    export DSR_CACHE_DIR="$TEMP_DIR/cache/dsr"
    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    mkdir -p "$DSR_CACHE_DIR/installers"
}

teardown() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

# ============================================================================
# Tests: Template Cache Logic
# ============================================================================

test_template_cache_path_logic() {
    ((TESTS_RUN++))
    setup

    source "$PROJECT_ROOT/src/install_gen.sh"

    local template
    template=$(_install_gen_template 2>/dev/null)

    # Verify cache path construction logic exists
    # Note: use <<< to avoid SIGPIPE with grep -q on large templates under pipefail
    if grep -q 'echo "\${_CACHE_DIR}/\${TOOL_NAME}/' <<< "$template"; then
        pass "template has cache path construction"
    else
        fail "template missing cache path construction"
    fi

    teardown
}

test_template_cache_get_logic() {
    ((TESTS_RUN++))
    setup

    source "$PROJECT_ROOT/src/install_gen.sh"

    local template
    template=$(_install_gen_template 2>/dev/null)

    # Verify cache check logic
    if grep -q 'if \[\[ -f "\$cache_file" \]\]' <<< "$template"; then
        pass "template has cache file check"
    else
        fail "template missing cache file check"
    fi

    teardown
}

test_template_cache_put_logic() {
    ((TESTS_RUN++))
    setup

    source "$PROJECT_ROOT/src/install_gen.sh"

    local template
    template=$(_install_gen_template 2>/dev/null)

    # Verify cache put creates directories and copies file
    if grep -q 'mkdir -p "\$cache_dir"' <<< "$template" && \
       grep -q 'cp "\$src_file" "\$cache_file"' <<< "$template"; then
        pass "template has cache put logic"
    else
        fail "template missing cache put logic"
    fi

    teardown
}

test_template_offline_mode_error() {
    ((TESTS_RUN++))
    setup

    source "$PROJECT_ROOT/src/install_gen.sh"

    local template
    template=$(_install_gen_template 2>/dev/null)

    # Verify offline mode fails fast with clear error
    if grep -q 'Offline mode: no cached archive' <<< "$template"; then
        pass "template has offline mode error message"
    else
        fail "template missing offline mode error message"
    fi

    teardown
}

# ============================================================================
# Tests: Template Generation
# ============================================================================

test_template_has_cache_flags() {
    ((TESTS_RUN++))
    setup

    source "$PROJECT_ROOT/src/install_gen.sh"

    # Get the template content
    local template
    template=$(_install_gen_template 2>/dev/null)

    if grep -q -- "--cache-dir" <<< "$template"; then
        pass "template includes --cache-dir flag"
    else
        fail "template missing --cache-dir flag"
    fi

    teardown
}

test_template_has_offline_flag() {
    ((TESTS_RUN++))
    setup

    source "$PROJECT_ROOT/src/install_gen.sh"

    local template
    template=$(_install_gen_template 2>/dev/null)

    if grep -q -- "--offline" <<< "$template"; then
        pass "template includes --offline flag"
    else
        fail "template missing --offline flag"
    fi

    teardown
}

test_template_has_prefer_gh_flag() {
    ((TESTS_RUN++))
    setup

    source "$PROJECT_ROOT/src/install_gen.sh"

    local template
    template=$(_install_gen_template 2>/dev/null)

    if grep -q -- "--prefer-gh" <<< "$template"; then
        pass "template includes --prefer-gh flag"
    else
        fail "template missing --prefer-gh flag"
    fi

    teardown
}

test_template_has_gh_download_function() {
    ((TESTS_RUN++))
    setup

    source "$PROJECT_ROOT/src/install_gen.sh"

    local template
    template=$(_install_gen_template 2>/dev/null)

    if grep -q "_gh_download" <<< "$template"; then
        pass "template includes _gh_download function"
    else
        fail "template missing _gh_download function"
    fi

    teardown
}

test_template_has_cache_get_function() {
    ((TESTS_RUN++))
    setup

    source "$PROJECT_ROOT/src/install_gen.sh"

    local template
    template=$(_install_gen_template 2>/dev/null)

    if grep -q "_cache_get" <<< "$template"; then
        pass "template includes _cache_get function"
    else
        fail "template missing _cache_get function"
    fi

    teardown
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    teardown 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== Unit Tests: install_gen.sh ==="
echo ""

echo "Template Cache Logic:"
test_template_cache_path_logic
test_template_cache_get_logic
test_template_cache_put_logic
test_template_offline_mode_error

echo ""
echo "Template Flags:"
test_template_has_cache_flags
test_template_has_offline_flag
test_template_has_prefer_gh_flag
test_template_has_gh_download_function
test_template_has_cache_get_function

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
