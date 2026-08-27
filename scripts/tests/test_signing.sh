#!/usr/bin/env bash
# test_signing.sh - Unit tests for src/signing.sh
#
# Run: ./scripts/tests/test_signing.sh
#
# Real-behavior tests using actual minisign. Skips if minisign is missing.
# (No-mocks compliant per bd-3py)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ============================================================================
# Dependency Check (no-mocks compliance: skip if missing, don't fake)
# ============================================================================
if ! command -v minisign &>/dev/null; then
    echo "SKIP: minisign is required for signing tests"
    echo "  Install: brew install minisign OR apt install minisign"
    exit 0
fi

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

# Temporary test environment
TEMP_DIR=$(mktemp -d)
BIN_DIR="$TEMP_DIR/bin"
mkdir -p "$BIN_DIR"

export DSR_CONFIG_DIR="$TEMP_DIR/config"
mkdir -p "$DSR_CONFIG_DIR"

export SIGNING_SECRETS_DIR="$DSR_CONFIG_DIR/secrets"
export SIGNING_PRIVATE_KEY="$SIGNING_SECRETS_DIR/minisign.key"
export SIGNING_PUBLIC_KEY="$DSR_CONFIG_DIR/minisign.pub"

# Source module under test
# shellcheck disable=SC1091
source "$PROJECT_ROOT/src/signing.sh"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# NOTE: Using real minisign (no stub) per no-mocks policy
# Tests will generate real keys and signatures

# Helpers
run_cmd() {
  local label="$1"
  shift
  ((TESTS_RUN++))
  if "$@"; then
    pass "$label"
    return 0
  fi
  fail "$label"
  return 1
}

run_expect_fail() {
  local label="$1"
  shift
  ((TESTS_RUN++))
  if "$@"; then
    fail "$label"
    return 1
  fi
  pass "$label"
  return 0
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]]
}

assert_mode() {
  local path="$1"
  local expected="$2"
  local actual
  actual=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || echo "")
  [[ "$actual" == "$expected" ]]
}

# Tests
test_signing_require_minisign_missing() {
  ((TESTS_RUN++))
  local old_path="$PATH"
  # shellcheck disable=SC2123 # Intentionally override PATH to simulate missing minisign
  PATH="/nonexistent"
  if signing_require_minisign 2>/dev/null; then
    PATH="$old_path"
    fail "signing_require_minisign should fail without minisign"
    return 1
  fi
  PATH="$old_path"
  pass "signing_require_minisign fails without minisign"
}

test_signing_init_creates_keys() {
  # Uses real minisign (no stub)
  run_cmd "signing_init creates keypair" signing_init --no-password
  run_cmd "private key exists" assert_file_exists "$SIGNING_PRIVATE_KEY"
  run_cmd "public key exists" assert_file_exists "$SIGNING_PUBLIC_KEY"
  run_cmd "private key perms 600" assert_mode "$SIGNING_PRIVATE_KEY" "600"
}

test_signing_check_valid() {
  run_cmd "signing_check passes with keys" signing_check >/dev/null
}

test_signing_fix_permissions() {
  chmod 644 "$SIGNING_PRIVATE_KEY"
  run_cmd "signing_fix_permissions sets 600" signing_fix_permissions >/dev/null
  run_cmd "private key perms fixed" assert_mode "$SIGNING_PRIVATE_KEY" "600"
}

test_signing_sign_and_verify() {
  local artifact="$TEMP_DIR/artifact.bin"
  echo "data" > "$artifact"

  run_cmd "signing_sign creates minisig" signing_sign "$artifact" >/dev/null
  run_cmd "signature file exists" assert_file_exists "${artifact}.minisig"
  run_cmd "signing_verify succeeds" signing_verify "$artifact" >/dev/null
}

test_signing_verify_failure() {
  local artifact="$TEMP_DIR/tampered.bin"
  echo "original data" > "$artifact"
  signing_sign "$artifact" >/dev/null

  # Tamper with the file AFTER signing to cause verification failure
  echo "tampered data" > "$artifact"
  run_expect_fail "signing_verify fails for tampered file" signing_verify "$artifact" >/dev/null
}

test_signing_sign_batch() {
  local a="$TEMP_DIR/a.bin"
  local b="$TEMP_DIR/b.bin"
  echo "a" > "$a"
  echo "b" > "$b"

  run_cmd "signing_sign_batch succeeds" signing_sign_batch "$a" "$b" >/dev/null
  run_cmd "batch signature a exists" assert_file_exists "${a}.minisig"
  run_cmd "batch signature b exists" assert_file_exists "${b}.minisig"
}

test_signing_exact_creates_verified_signature_without_clobbering() {
  local artifact="$TEMP_DIR/exact.bin"
  local signature="${artifact}.strict.minisig"
  local token expected_signature="$TEMP_DIR/exact.expected.minisig"
  echo "exact data" > "$artifact"
  token=$(signing_public_key_token "$SIGNING_PUBLIC_KEY")

  run_cmd "signing_sign_exact creates a verified signature" \
    signing_sign_exact "$artifact" "$signature" "$SIGNING_PRIVATE_KEY" \
      "$token" "exact signing test"
  run_cmd "signing_verify_exact accepts the generated signature" \
    signing_verify_exact "$artifact" "$signature" "$token"
  cp "$signature" "$expected_signature"
  run_expect_fail "signing_sign_exact refuses to clobber an existing signature" \
    signing_sign_exact "$artifact" "$signature" "$SIGNING_PRIVATE_KEY" \
      "$token" "replacement signing test"
  run_cmd "existing exact signature remains byte-identical" \
    cmp -s "$expected_signature" "$signature"
}

test_signing_exact_wrong_key_leaves_no_signature() {
  local artifact="$TEMP_DIR/wrong-exact.bin"
  local signature="${artifact}.minisig"
  local wrong_public="$TEMP_DIR/wrong-exact.pub"
  local wrong_private="$TEMP_DIR/wrong-exact.key"
  local token
  echo "wrong signer data" > "$artifact"
  token=$(signing_public_key_token "$SIGNING_PUBLIC_KEY")
  minisign -G -W -p "$wrong_public" -s "$wrong_private" >/dev/null 2>&1

  run_expect_fail "signing_sign_exact rejects a wrong private key" \
    signing_sign_exact "$artifact" "$signature" "$wrong_private" \
      "$token" "wrong exact signing test"
  run_cmd "wrong-key exact signing leaves no final signature" \
    test ! -e "$signature"
}

test_signing_exact_rejects_legacy_signature() {
  local artifact="$TEMP_DIR/legacy-exact.bin"
  local signature="${artifact}.minisig"
  local token
  echo "legacy signature data" > "$artifact"
  token=$(signing_public_key_token "$SIGNING_PUBLIC_KEY")
  minisign -S -l -s "$SIGNING_PRIVATE_KEY" -m "$artifact" \
    -x "$signature" -t "legacy signature test" >/dev/null 2>&1

  run_expect_fail "signing_verify_exact rejects legacy signatures" \
    signing_verify_exact "$artifact" "$signature" "$token"
}

test_signing_exact_rejects_symlink_private_key() {
  local artifact="$TEMP_DIR/symlink-key.bin"
  local signature="${artifact}.minisig"
  local private_link="$TEMP_DIR/private-link.key"
  local token
  echo "symlink private key data" > "$artifact"
  token=$(signing_public_key_token "$SIGNING_PUBLIC_KEY")
  ln -s "$SIGNING_PRIVATE_KEY" "$private_link"

  run_expect_fail "signing_sign_exact rejects a symlink private key" \
    signing_sign_exact "$artifact" "$signature" "$private_link" \
      "$token" "symlink key test"
  run_cmd "symlink-key rejection leaves no final signature" \
    test ! -e "$signature"
}

test_signing_sign_missing_key() {
  rm -f "$SIGNING_PRIVATE_KEY"
  run_expect_fail "signing_sign fails without private key" signing_sign "$TEMP_DIR/ghost.bin" >/dev/null
}

test_signing_sign_multiple_files_error() {
  # Restore key for this test
  signing_init --no-password >/dev/null 2>&1
  local a="$TEMP_DIR/multi_a.bin"
  local b="$TEMP_DIR/multi_b.bin"
  echo "a" > "$a"
  echo "b" > "$b"

  # signing_sign should reject multiple files (use signing_sign_batch instead)
  run_expect_fail "signing_sign rejects multiple files" signing_sign "$a" "$b" 2>/dev/null
}

test_signing_verify_multiple_files_error() {
  local a="$TEMP_DIR/verify_a.bin"
  local b="$TEMP_DIR/verify_b.bin"
  echo "a" > "$a"
  echo "b" > "$b"
  signing_sign "$a" >/dev/null 2>&1
  signing_sign "$b" >/dev/null 2>&1

  # signing_verify should reject multiple files
  run_expect_fail "signing_verify rejects multiple files" signing_verify "$a" "$b" 2>/dev/null
}

# Main
echo "Running signing module tests..."
echo ""

test_signing_require_minisign_missing
test_signing_init_creates_keys
test_signing_check_valid
test_signing_fix_permissions
test_signing_sign_and_verify
test_signing_verify_failure
test_signing_sign_batch
test_signing_exact_creates_verified_signature_without_clobbering
test_signing_exact_wrong_key_leaves_no_signature
test_signing_exact_rejects_legacy_signature
test_signing_exact_rejects_symlink_private_key
test_signing_sign_missing_key
test_signing_sign_multiple_files_error
test_signing_verify_multiple_files_error

echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN"
echo "Passed:    $TESTS_PASSED"
echo "Failed:    $TESTS_FAILED"
echo "Skipped:   $TESTS_SKIPPED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
