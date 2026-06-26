#!/usr/bin/env bash
# test_act_build_cmd_tokens.sh - Unit tests for act_substitute_build_cmd_tokens
#
# Regression coverage for beads_viewer#174: DSR must resolve ${version} (and the
# other documented build tokens) in build_cmd itself, rather than relying on the
# remote build shell to expand them. cmd.exe on a Windows native build host does
# not POSIX-expand ${version}, so the literal placeholder was being baked into
# the bv ldflag and shipped in the v0.17.0 Windows binary.
#
# Usage: ./scripts/tests/test_act_build_cmd_tokens.sh
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#
# shellcheck disable=SC2016 # Tests use literal ${var} patterns that must not expand

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the module under test
# shellcheck source=../../src/act_runner.sh
source "$PROJECT_ROOT/src/act_runner.sh"

# Test counters
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

log_pass() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [PASS] $*" >&2; }
log_fail() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [FAIL] $*" >&2; }
log_info() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO] $*" >&2; }

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-assertion}"
    ((TEST_COUNT++))
    if [[ "$expected" == "$actual" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  expected: '$expected'"
        log_fail "  actual:   '$actual'"
        return 1
    fi
}

# --- Tests -----------------------------------------------------------------

# The exact bv build_cmd that produced beads_viewer#174. The version is given
# WITH a leading "v" (as DSR resolves it) and must be injected stripped, so the
# ldflag carries "0.17.1" (bv's normalizeVersion re-adds the "v").
test_bv_version_token() {
    local out
    out=$(act_substitute_build_cmd_tokens \
        'go build -ldflags="-s -w -X github.com/Dicklesworthstone/beads_viewer/pkg/version.version=${version}" -o bv ./cmd/bv' \
        'bv' 'v0.17.1' 'windows' 'amd64')
    assert_eq \
        'go build -ldflags="-s -w -X github.com/Dicklesworthstone/beads_viewer/pkg/version.version=0.17.1" -o bv ./cmd/bv' \
        "$out" \
        'bv ${version} token is resolved (and v-stripped), no literal placeholder remains'
}

# No DSR token at all -> command must be byte-for-byte unchanged (this is the
# overwhelming majority of fleet repos; they must not be perturbed).
test_no_token_unchanged() {
    local out
    out=$(act_substitute_build_cmd_tokens 'cargo build --release' 'xf' 'v1.2.3' 'linux' 'amd64')
    assert_eq 'cargo build --release' "$out" 'build_cmd with no DSR token is unchanged'
}

# Shell constructs that are NOT DSR tokens ($HOME, $PATH, unbraced $version)
# must be left untouched for the shell (cf. jfp_premium's build_cmd).
test_shell_vars_untouched() {
    local out
    out=$(act_substitute_build_cmd_tokens \
        'export PATH="$HOME/.bun/bin:$PATH" && bun install && ./build.sh' \
        'jfp' 'v2.0.0' 'linux' 'arm64')
    assert_eq \
        'export PATH="$HOME/.bun/bin:$PATH" && bun install && ./build.sh' \
        "$out" \
        '$HOME/$PATH (non-DSR shell vars) are left for the shell'
}

# os/arch/name tokens resolve from the platform (forward-looking; no current
# repo uses these in build_cmd, but the token set should be consistent).
test_os_arch_name_tokens() {
    local out
    out=$(act_substitute_build_cmd_tokens \
        'go build -o ${name}-${os}-${arch} .' \
        'mytool' '0.1.0' 'darwin' 'arm64')
    assert_eq 'go build -o mytool-darwin-arm64 .' "$out" 'name/os/arch tokens resolve'
}

# Version without a leading "v" is passed through as-is.
test_version_without_v() {
    local out
    out=$(act_substitute_build_cmd_tokens 'echo ${version}' 'x' '3.4.5' 'linux' 'amd64')
    assert_eq 'echo 3.4.5' "$out" 'version without leading v is preserved'
}

# --- Run -------------------------------------------------------------------

log_info "Running act_substitute_build_cmd_tokens unit tests"
test_bv_version_token
test_no_token_unchanged
test_shell_vars_untouched
test_os_arch_name_tokens
test_version_without_v

log_info "Results: $PASS_COUNT/$TEST_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
