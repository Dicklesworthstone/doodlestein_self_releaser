#!/usr/bin/env bash
# e2e_signing.sh - E2E tests for dsr signing command
#
# Tests the full signing workflow using real minisign when available.
# Skips with actionable install instructions if minisign is missing.
#
# Run: ./scripts/tests/e2e_signing.sh

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
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }

# ============================================================================
# Dependency Check
# ============================================================================
if ! require_command minisign "minisign signing tool" "Install: brew install minisign OR apt install minisign" 2>/dev/null; then
    echo "SKIP: minisign is required for E2E signing tests"
    echo "  Install: brew install minisign OR apt install minisign"
    exit 0
fi

# ============================================================================
# Tests: Help and Basic Invocation
# ============================================================================

test_signing_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" signing --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "init" && exec_stdout_contains "sign"; then
        pass "signing --help shows usage information"
    else
        fail "signing --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_signing_check_before_init() {
    ((TESTS_RUN++))
    harness_setup

    # Check should fail before init (no keys)
    exec_run "$DSR_CMD" signing check
    local status
    status=$(exec_status)

    if [[ "$status" -ne 0 ]]; then
        pass "signing check fails when keys not initialized"
    else
        fail "signing check should fail without keys"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Key Initialization
# ============================================================================

test_signing_init_creates_keypair() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" signing init --no-password
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "signing init succeeds with --no-password"
    else
        fail "signing init failed (exit code: $status)"
        echo "stderr: $(exec_stderr)"
    fi

    harness_teardown
}

test_signing_init_creates_private_key() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" signing init --no-password

    # dsr uses DSR_CONFIG_DIR (which defaults to XDG_CONFIG_HOME/dsr when not set)
    local priv_key="$DSR_CONFIG_DIR/secrets/minisign.key"
    if [[ -f "$priv_key" ]]; then
        pass "signing init creates private key"
    else
        fail "signing init should create $priv_key"
        echo "XDG dir contents: $(ls -laR "$XDG_CONFIG_HOME" 2>&1)"
    fi

    harness_teardown
}

test_signing_init_creates_public_key() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" signing init --no-password

    # dsr uses DSR_CONFIG_DIR (which defaults to XDG_CONFIG_HOME/dsr when not set)
    local pub_key="$DSR_CONFIG_DIR/minisign.pub"
    if [[ -f "$pub_key" ]]; then
        pass "signing init creates public key"
    else
        fail "signing init should create $pub_key"
    fi

    harness_teardown
}

test_signing_init_private_key_permissions() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" signing init --no-password

    # dsr uses DSR_CONFIG_DIR (which defaults to XDG_CONFIG_HOME/dsr when not set)
    local priv_key="$DSR_CONFIG_DIR/secrets/minisign.key"
    local perms
    perms=$(stat -c '%a' "$priv_key" 2>/dev/null || stat -f '%Lp' "$priv_key" 2>/dev/null || echo "")

    if [[ "$perms" == "600" ]]; then
        pass "private key has 600 permissions"
    else
        fail "private key should have 600 permissions, got: $perms"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Key Check
# ============================================================================

test_signing_check_after_init() {
    ((TESTS_RUN++))
    harness_setup

    "$DSR_CMD" signing init --no-password >/dev/null 2>&1
    exec_run "$DSR_CMD" signing check
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "signing check passes after init"
    else
        fail "signing check should pass after init"
        echo "stderr: $(exec_stderr)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Sign and Verify
# ============================================================================

test_signing_sign_creates_signature() {
    ((TESTS_RUN++))
    harness_setup

    # Initialize keys
    "$DSR_CMD" signing init --no-password >/dev/null 2>&1

    # Create test artifact
    local artifact="$TEST_TMPDIR/test-artifact.tar.gz"
    echo "test artifact content" > "$artifact"

    exec_run "$DSR_CMD" signing sign "$artifact"
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 && -f "${artifact}.minisig" ]]; then
        pass "signing sign creates .minisig file"
    else
        fail "signing sign should create signature file (exit: $status)"
        echo "stderr: $(exec_stderr)"
    fi

    harness_teardown
}

test_signing_verify_valid_signature() {
    ((TESTS_RUN++))
    harness_setup

    # Initialize keys and sign
    "$DSR_CMD" signing init --no-password >/dev/null 2>&1

    local artifact="$TEST_TMPDIR/verify-test.bin"
    echo "verify test content" > "$artifact"
    "$DSR_CMD" signing sign "$artifact" >/dev/null 2>&1

    exec_run "$DSR_CMD" signing verify "$artifact"
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "signing verify succeeds for valid signature"
    else
        fail "signing verify should pass for valid signature"
        echo "stderr: $(exec_stderr)"
    fi

    harness_teardown
}

test_signing_verify_tampered_file() {
    ((TESTS_RUN++))
    harness_setup

    # Initialize keys and sign
    "$DSR_CMD" signing init --no-password >/dev/null 2>&1

    local artifact="$TEST_TMPDIR/tamper-test.bin"
    echo "original content" > "$artifact"
    "$DSR_CMD" signing sign "$artifact" >/dev/null 2>&1

    # Tamper with the file after signing
    echo "tampered content" > "$artifact"

    exec_run "$DSR_CMD" signing verify "$artifact"
    local status
    status=$(exec_status)

    if [[ "$status" -ne 0 ]]; then
        pass "signing verify fails for tampered file"
    else
        fail "signing verify should fail for tampered file"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Public Key Display
# ============================================================================

test_signing_pubkey_displays_key() {
    ((TESTS_RUN++))
    harness_setup

    "$DSR_CMD" signing init --no-password >/dev/null 2>&1

    exec_run "$DSR_CMD" signing pubkey
    local status
    status=$(exec_status)

    # Public key should start with RW (minisign Ed25519 prefix)
    if [[ "$status" -eq 0 ]] && exec_stdout_contains "RW"; then
        pass "signing pubkey displays Ed25519 public key"
    else
        fail "signing pubkey should display key"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_signing_pubkey_oneline() {
    ((TESTS_RUN++))
    harness_setup

    "$DSR_CMD" signing init --no-password >/dev/null 2>&1

    exec_run "$DSR_CMD" signing pubkey --oneline
    local output
    output=$(exec_stdout | tr -d '\n')

    # One-line output should be a single base64-encoded key
    if [[ "$output" =~ ^RW[A-Za-z0-9+/=]+$ ]]; then
        pass "signing pubkey --oneline outputs single-line key"
    else
        fail "signing pubkey --oneline should output single-line key"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: JSON Output
# ============================================================================

test_signing_check_json_output() {
    ((TESTS_RUN++))
    harness_setup

    "$DSR_CMD" signing init --no-password >/dev/null 2>&1

    exec_run "$DSR_CMD" --json signing check
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "signing check --json produces valid JSON"
    else
        fail "signing check --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_signing_check_json_has_valid_field() {
    ((TESTS_RUN++))
    harness_setup

    "$DSR_CMD" signing init --no-password >/dev/null 2>&1

    exec_run "$DSR_CMD" --json signing check
    local output
    output=$(exec_stdout)

    # JSON output has 'valid' field, not 'status'
    if echo "$output" | jq -e '.valid' >/dev/null 2>&1; then
        pass "signing check JSON has valid field"
    else
        fail "signing check JSON should have valid field"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Permission Fix
# ============================================================================

test_signing_fix_restores_permissions() {
    ((TESTS_RUN++))
    harness_setup

    "$DSR_CMD" signing init --no-password >/dev/null 2>&1

    # dsr uses DSR_CONFIG_DIR (which defaults to XDG_CONFIG_HOME/dsr when not set)
    local priv_key="$DSR_CONFIG_DIR/secrets/minisign.key"
    # Mess up permissions
    chmod 644 "$priv_key"

    exec_run "$DSR_CMD" signing fix
    local perms
    perms=$(stat -c '%a' "$priv_key" 2>/dev/null || stat -f '%Lp' "$priv_key" 2>/dev/null || echo "")

    if [[ "$perms" == "600" ]]; then
        pass "signing fix restores 600 permissions"
    else
        fail "signing fix should restore 600 permissions, got: $perms"
    fi

    harness_teardown
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    exec_cleanup 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== E2E: dsr signing Tests ==="
echo ""

echo "Help and Basic Invocation:"
test_signing_help
test_signing_check_before_init

echo ""
echo "Key Initialization:"
test_signing_init_creates_keypair
test_signing_init_creates_private_key
test_signing_init_creates_public_key
test_signing_init_private_key_permissions

echo ""
echo "Key Check:"
test_signing_check_after_init

echo ""
echo "Sign and Verify:"
test_signing_sign_creates_signature
test_signing_verify_valid_signature
test_signing_verify_tampered_file

echo ""
echo "Public Key Display:"
test_signing_pubkey_displays_key
test_signing_pubkey_oneline

echo ""
echo "JSON Output:"
test_signing_check_json_output
test_signing_check_json_has_valid_field

echo ""
echo "Permission Fix:"
test_signing_fix_restores_permissions

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
