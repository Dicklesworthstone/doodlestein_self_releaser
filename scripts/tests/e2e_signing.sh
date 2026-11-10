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

test_signing_init_json_and_custody() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "public signing initialization custody tests require python3"
        return
    fi
    harness_setup
    local report="$TEST_TMPDIR/init-cli-results" status=0 line
    # Invoke the actual executable with real keys. The alias cases exercise
    # startup logging as well as cmd_signing, which a sourced-module test cannot.
    python3 - "$DSR_CMD" "$TEST_TMPDIR/init-cli" "$(command -v minisign)" \
        "$PROJECT_ROOT/schemas/envelope.json" \
        > "$report" <<'PY' || status=$?
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys

cli, directory, real_minisign, envelope_schema = sys.argv[1:]
root = Path(directory)
root.mkdir(mode=0o700)
failures = 0
documents = []

def check(condition, label):
    global failures
    print(("PASS: " if condition else "FAIL: ") + label, flush=True)
    failures += not condition

def run(command, env=None):
    process = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        out, err = process.communicate(timeout=20)
        return subprocess.CompletedProcess(command, process.returncode, out, err)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        out, err = process.communicate()
        return subprocess.CompletedProcess(command, 124, out, err)

def case(name, populated=True):
    folder = root / name
    folder.mkdir(mode=0o700)
    config = folder / "config"
    private, public = config / "secrets" / "minisign.key", config / "minisign.pub"
    if populated:
        private.parent.mkdir(mode=0o700, parents=True)
        result = run([real_minisign, "-G", "-W", "-s", str(private), "-p", str(public)])
        if result.returncode:
            raise RuntimeError("real Minisign fixture generation failed")
        private.chmod(0o600)
    env = {"PATH": os.environ["PATH"], "HOME": str(folder), "LANG": "C", "NO_COLOR": "1",
           "DSR_CONFIG_DIR": str(config), "DSR_STATE_DIR": str(folder / "state"),
           "DSR_CACHE_DIR": str(folder / "cache"), "DSR_MINISIGN_KEY": str(private)}
    return folder, private, public, env

def inventory(folder):
    result = {}
    for path in sorted([folder, *folder.rglob("*")]):
        info = path.lstat()
        value = (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns)
        if stat.S_ISREG(info.st_mode):
            value += (hashlib.sha256(path.read_bytes()).hexdigest(),)
        elif stat.S_ISLNK(info.st_mode):
            value += (os.readlink(path),)
        result[str(path)] = value
    return result

def invoke(paths, arguments):
    result = run([cli, *arguments], env=paths[3])
    try:
        payload = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError):
        payload = {}
        print("INFO: initialization returned no JSON:", arguments, "status", result.returncode,
              result.stderr.decode(errors="replace"), flush=True)
    documents.append(payload)
    return result, payload

def truthful(result, payload):
    return (isinstance(payload, dict) and payload.get("command") == "signing"
            and payload.get("exit_code") == result.returncode
            and payload.get("status") == ("success" if result.returncode == 0 else "error")
            and all(field in payload for field in ("run_id", "started_at", "duration_ms", "tool", "version")))

for position in ("global", "local", "short"):
    for alias in ("private", "public", "hardlink"):
        paths = case(position + "-" + alias)
        if alias == "hardlink":
            log = paths[0] / "session.log"
            os.link(paths[1], log)
        else:
            log = paths[1] if alias == "private" else paths[2]
        paths[3]["LOG_FILE"] = str(log)
        before = inventory(paths[0])
        arguments = ["--json", "--dry-run", "signing", "init", "--force", "--no-password"]
        if position == "local":
            arguments = ["signing", "init", "--force", "--no-password", "--json", "--dry-run"]
        elif position == "short":
            arguments = ["signing", "init", "--force", "--no-password", "-j", "-n"]
        result, payload = invoke(paths, arguments)
        details = payload.get("details", {})
        check(result.returncode == 0 and truthful(result, payload)
              and details.get("status") == "planned" and details.get("initialized") is False
              and details.get("dry_run") is True and details.get("backup_paths") == []
              and inventory(paths[0]) == before,
              position + " JSON preview preserves every file with a " + alias + " signing-key log alias")

fresh = case("fresh-preview", populated=False)
before = inventory(fresh[0])
result, payload = invoke(fresh, ["--json", "signing", "init", "--dry-run", "--no-password"])
check(result.returncode == 0 and truthful(result, payload)
      and payload.get("details", {}).get("initialized") is False and inventory(fresh[0]) == before,
      "fresh public CLI preview reports a plan without creating config, state, cache, or logs")

unknown = case("unknown-option")
unknown[3]["LOG_FILE"] = str(unknown[1])
before = inventory(unknown[0])
result, payload = invoke(unknown, ["--json", "signing", "init", "--force", "--unknown-init-option"])
check(result.returncode == 4 and truthful(result, payload)
      and payload.get("details", {}).get("initialized") is False
      and payload.get("details", {}).get("errors") and inventory(unknown[0]) == before,
      "invalid public initialization returns a truthful JSON error without logging into either key")

held = case("interrupted-lease")
Path(str(held[1]) + ".init.lock").mkdir(mode=0o700)
before = inventory(held[0])
result, payload = invoke(held, ["--json", "signing", "init", "--force", "--no-password"])
check(result.returncode == 2 and truthful(result, payload)
      and payload.get("details", {}).get("recovery_required") is True
      and inventory(held[0]) == before,
      "an existing initialization lease returns conflict and exposes recovery without mutation")

missing_parser = case("missing-json-parser")
bin_dir = missing_parser[0] / "bin"
bin_dir.mkdir()
# Preserve real commands, including Minisign; only jq is absent. This avoids a
# fake parser or a fake generator reporting success for an unexecuted operation.
for name in ("bash", "dirname", "basename", "date", "cat", "tr", "mkdir", "stat", "cp", "chmod",
             "mktemp", "ln", "mv", "rm", "rmdir", "readlink", "head", "sed", "cut", "awk", "sha256sum"):
    executable = shutil.which(name)
    if executable:
        (bin_dir / name).symlink_to(executable)
(bin_dir / "minisign").symlink_to(real_minisign)
missing_parser[3]["PATH"] = str(bin_dir)
missing_parser[3]["LOG_FILE"] = str(missing_parser[1])
before = inventory(missing_parser[0])
result = run([cli, "--json", "signing", "init", "--force", "--no-password"], missing_parser[3])
check(shutil.which("jq", path=str(bin_dir)) is None and result.returncode == 3
      and b"jq is required" in result.stderr and not result.stdout
      and inventory(missing_parser[0]) == before,
      "missing real JSON dependency refuses forced initialization before keys or backups change")

for alias in ("private", "public"):
    paths = case("forced-" + alias)
    old = tuple(path.read_bytes() for path in paths[1:3])
    paths[3]["LOG_FILE"] = str(paths[1] if alias == "private" else paths[2])
    result, payload = invoke(paths, ["signing", "init", "--force", "--no-password", "--json"])
    details = payload.get("details", {})
    backup_paths = [Path(path) for path in details.get("backup_paths", [])]
    saved = [path.read_bytes() for path in backup_paths if path.is_file()]
    check(result.returncode == 0 and truthful(result, payload) and details.get("initialized") is True
          and details.get("status") == "initialized" and details.get("dry_run") is False
          and details.get("password_protected") is False and len(saved) == 2
          and all(key in saved for key in old),
          "forced JSON initialization reports both preserved originals with a " + alias + " log alias")
    artifact = paths[0] / "artifact.bin"
    artifact.write_bytes(b"actual CLI signing identity\n")
    signed = run([cli, "signing", "sign", str(artifact)], paths[3])
    verified = run([real_minisign, "-V", "-p", str(paths[2]), "-m", str(artifact)])
    check(signed.returncode == 0 and verified.returncode == 0,
          "the rotated " + alias + "-alias CLI identity signs artifacts accepted by independent Minisign")

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:
    print("SKIP: public initialization JSON schema validation requires jsonschema", flush=True)
else:
    validator = Draft202012Validator(json.loads(Path(envelope_schema).read_text()),
                                     format_checker=FormatChecker())
    errors = [error.message for document in documents for error in validator.iter_errors(document)]
    check(len(documents) == 14 and not errors,
          "all 14 actual initialization JSON responses satisfy the published envelope schema")
    if errors:
        print("INFO: JSON schema errors:", errors, flush=True)

sys.exit(bool(failures))
PY
    while IFS= read -r line; do
        case "$line" in
            'PASS: '*) ((TESTS_RUN++)); pass "${line#PASS: }" ;;
            'FAIL: '*) ((TESTS_RUN++)); fail "${line#FAIL: }" ;;
            'SKIP: '*) skip "${line#SKIP: }" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$report"
    if ((status != 0)) && ! grep -q '^FAIL: ' "$report"; then
        ((TESTS_RUN++))
        fail "public initialization regression driver completed (exit $status)"
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
test_signing_init_json_and_custody

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
