#!/usr/bin/env bash
# test_signing.sh - Unit tests for src/signing.sh
#
# Run: ./scripts/tests/test_signing.sh
#
# Uses a local minisign stub so tests do not require minisign installed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# Create a stub minisign in PATH
setup_minisign_stub() {
  cat > "$BIN_DIR/minisign" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail

mode=""
pub=""
priv=""
file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -G) mode="gen"; shift ;;
    -S) mode="sign"; shift ;;
    -V) mode="verify"; shift ;;
    -p) pub="$2"; shift 2 ;;
    -s) priv="$2"; shift 2 ;;
    -m) file="$2"; shift 2 ;;
    -W) shift ;; # no-password
    -t|-c) shift 2 ;; # comments
    *) shift ;;
  esac
done

case "$mode" in
  gen)
    [[ -n "$priv" && -n "$pub" ]] || exit 1
    mkdir -p "$(dirname "$priv")"
    echo "untrusted comment: fake key" > "$priv"
    echo "RWRfAKEKEY" >> "$priv"
    echo "fake-public-key" > "$pub"
    exit 0
    ;;
  sign)
    [[ -n "$file" ]] || exit 1
    echo "fake signature for $file" > "${file}.minisig"
    exit 0
    ;;
  verify)
    [[ "${MINISIGN_FAIL_VERIFY:-}" == "1" ]] && exit 1
    [[ -n "$file" && -f "${file}.minisig" ]] || exit 1
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$BIN_DIR/minisign"
  export PATH="$BIN_DIR:$PATH"
}

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
  setup_minisign_stub
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
  echo "data" > "$artifact"
  signing_sign "$artifact" >/dev/null

  MINISIGN_FAIL_VERIFY=1 run_expect_fail "signing_verify fails when minisign reports error" signing_verify "$artifact" >/dev/null
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

test_signing_sign_missing_key() {
  rm -f "$SIGNING_PRIVATE_KEY"
  run_expect_fail "signing_sign fails without private key" signing_sign "$TEMP_DIR/ghost.bin" >/dev/null
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
test_signing_sign_missing_key

echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN"
echo "Passed:    $TESTS_PASSED"
echo "Failed:    $TESTS_FAILED"
echo "Skipped:   $TESTS_SKIPPED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
