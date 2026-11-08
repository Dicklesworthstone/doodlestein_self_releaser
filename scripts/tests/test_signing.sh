#!/usr/bin/env bash
# test_signing.sh - Unit tests for src/signing.sh
#
# Run: ./scripts/tests/test_signing.sh [--encrypted-only]
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
unset DSR_MINISIGN_PASSWORD_FILE

# An alternate module permits running the same real-key regression against an
# incumbent implementation. It does not replace Minisign or its verification.
SIGNING_TEST_MODULE="${DSR_TEST_SIGNING_MODULE:-$PROJECT_ROOT/src/signing.sh}"
# Source module under test
# shellcheck disable=SC1090,SC1091 # Optional incumbent module for the same regression.
source "$SIGNING_TEST_MODULE"

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

key_digest() {
  cat "$SIGNING_PRIVATE_KEY" "$SIGNING_PUBLIC_KEY" | sha256sum | cut -d' ' -f1
}

test_signing_init_force_and_dry_run() {
  local before after backups
  before=$(key_digest)

  run_cmd "signing_init --dry-run --force succeeds" signing_init --dry-run --force --no-password
  run_cmd "global DRY_RUN signing_init --force succeeds" env DRY_RUN=true bash -c \
    "source '$PROJECT_ROOT/src/signing.sh' && signing_init --force --no-password"
  ((TESTS_RUN++))
  backups=$(find "$DSR_CONFIG_DIR" -name '*.bak.*' | wc -l)
  if [[ "$(key_digest)" == "$before" && "$backups" -eq 0 ]]; then
    pass "dry runs leave the key pair untouched"
  else
    fail "dry runs changed keys or wrote backups ($backups)"
  fi

  run_expect_fail "signing_init refuses existing keys without --force" signing_init --no-password

  run_cmd "signing_init --force replaces the key pair" signing_init --force --no-password
  after=$(key_digest)
  ((TESTS_RUN++))
  local old_priv old_pub
  old_priv=$(find "$SIGNING_SECRETS_DIR" -name 'minisign.key.bak.*' | head -1)
  old_pub=$(find "$DSR_CONFIG_DIR" -maxdepth 1 -name 'minisign.pub.bak.*' | head -1)
  if [[ "$after" != "$before" && -n "$old_priv" && -n "$old_pub" ]] &&
     [[ "$(cat "$old_priv" "$old_pub" | sha256sum | cut -d' ' -f1)" == "$before" ]] &&
     assert_mode "$old_priv" 600 && assert_mode "$SIGNING_PRIVATE_KEY" 600; then
    pass "--force keeps the previous pair as mode-preserving backups"
  else
    fail "--force should replace keys and back up the old pair (backups: '$old_priv' '$old_pub')"
  fi
  run_cmd "replaced key pair passes signing_check" signing_check >/dev/null
}

test_signing_config_is_honored() {
  # config_load stores config.yaml as dotted keys.
  local out
  out=$(bash -c '
    source "$1/src/signing.sh"
    declare -gA DSR_CONFIG=([signing.enabled]=false)
    signing_wanted && echo wanted || echo off
    DSR_CONFIG=([signing.enabled]=true [signing.key_path]="~/keys/release.key")
    signing_wanted && echo wanted || echo off
    echo "$SIGNING_PRIVATE_KEY"
    DSR_MINISIGN_KEY=/env/key; SIGNING_PRIVATE_KEY=/env/key; signing_apply_config; echo "$SIGNING_PRIVATE_KEY"
    DSR_CONFIG=([signing_enabled]=false); unset DSR_MINISIGN_KEY; signing_wanted && echo wanted || echo off
  ' _ "$PROJECT_ROOT" 2>/dev/null)
  ((TESTS_RUN++))
  if [[ "$out" == $'off\nwanted\n'"$HOME/keys/release.key"$'\n/env/key\noff' ]]; then
    pass "signing.enabled and signing.key_path from config.yaml are honored (env key wins)"
  else
    fail "signing config not honored: $(tr '\n' '|' <<< "$out")"
  fi
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

test_signing_exact_publish_failure_leaves_no_signature() {
  local artifact="$TEMP_DIR/publish-failure.bin"
  local signature="${artifact}.minisig"
  local token
  echo "publish failure data" > "$artifact"
  token=$(signing_public_key_token "$SIGNING_PUBLIC_KEY")

  ln() { return 1; }
  run_expect_fail "signing_sign_exact fails closed when atomic publication fails" \
    signing_sign_exact "$artifact" "$signature" "$SIGNING_PRIVATE_KEY" \
      "$token" "publication failure test"
  unset -f ln
  run_cmd "failed exact publication leaves no final signature" \
    test ! -e "$signature"
}

test_signing_exact_preserves_competing_publish_replacement() {
  local artifact="$TEMP_DIR/publish-replaced.bin"
  local signature="${artifact}.minisig"
  local token
  echo "publish replacement data" > "$artifact"
  token=$(signing_public_key_token "$SIGNING_PUBLIC_KEY")

  ln() {
    local destination="${!#}"
    command ln "$@" || return $?
    printf 'competing signature bytes\n' > "${destination}.replacement"
    command mv "${destination}.replacement" "$destination"
  }
  run_expect_fail "signing_sign_exact rejects a replaced published path" \
    signing_sign_exact "$artifact" "$signature" "$SIGNING_PRIVATE_KEY" \
      "$token" "publication replacement test"
  unset -f ln
  run_cmd "signing failure preserves the competing replacement" \
    test "$(cat "$signature")" = "competing signature bytes"
  run_cmd "competing replacement failure removes private staging directories" \
    test -z "$(find "$TEMP_DIR" -maxdepth 1 -name '.*.dsr-signing.*' -print -quit)"
}

test_signing_exact_fails_closed_on_post_publish_input_mutation() {
  local artifact="$TEMP_DIR/post-publish-mutation.bin"
  local frozen_artifact="$TEMP_DIR/post-publish-mutation.frozen.bin"
  local signature="${artifact}.minisig"
  local token
  echo "original post-publish data" > "$artifact"
  cp "$artifact" "$frozen_artifact"
  token=$(signing_public_key_token "$SIGNING_PUBLIC_KEY")

  ln() {
    command ln "$@" || return $?
    printf 'mutated after publication\n' > "$artifact"
  }
  run_expect_fail "signing_sign_exact detects post-publication input mutation" \
    signing_sign_exact "$artifact" "$signature" "$SIGNING_PRIVATE_KEY" \
      "$token" "post-publication mutation test"
  unset -f ln
  run_cmd "post-publication failure leaves the published pathname untouched" \
    test -f "$signature"
  run_expect_fail "retained signature cannot verify mutated input" \
    signing_verify_exact "$artifact" "$signature" "$token"
  run_cmd "retained signature remains bound to the frozen input bytes" \
    signing_verify_exact "$frozen_artifact" "$signature" "$token"
  run_cmd "post-publication failure removes private staging directories" \
    test -z "$(find "$TEMP_DIR" -maxdepth 1 -name '.*.dsr-signing.*' -print -quit)"
}

test_signing_exact_preserves_competing_symlink_replacement() {
  local artifact="$TEMP_DIR/publish-symlink-replaced.bin"
  local signature="${artifact}.minisig"
  local competitor="$TEMP_DIR/competing-signature-target"
  local token
  echo "publish symlink replacement data" > "$artifact"
  echo "competing symlink bytes" > "$competitor"
  token=$(signing_public_key_token "$SIGNING_PUBLIC_KEY")

  ln() {
    local destination="${!#}"
    command ln "$@" || return $?
    command mv "$destination" "${destination}.original"
    command ln -s "$competitor" "$destination"
  }
  run_expect_fail "signing_sign_exact rejects a symlink-replaced published path" \
    signing_sign_exact "$artifact" "$signature" "$SIGNING_PRIVATE_KEY" \
      "$token" "publication symlink replacement test"
  unset -f ln
  run_cmd "signing failure preserves the competing symlink" \
    test -L "$signature"
  run_cmd "preserved symlink still resolves to competing bytes" \
    test "$(cat "$signature")" = "competing symlink bytes"
  run_cmd "symlink replacement failure removes private staging directories" \
    test -z "$(find "$TEMP_DIR" -maxdepth 1 -name '.*.dsr-signing.*' -print -quit)"
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

test_signing_encrypted_key_input() {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "encrypted-key input tests require python3"
    return
  fi
  local report="$TEMP_DIR/encrypted-results" status=0 line
  # Keep the optional external fixture for a before/after run with the exact
  # same encrypted key, password, and artifact inventory.
  python3 - "$SIGNING_TEST_MODULE" \
    "${DSR_SIGNING_ENCRYPTED_FIXTURE:-$TEMP_DIR/encrypted}" \
    "$(command -v minisign)" > "$report" <<'PY' || status=$?
import hashlib
import json
import os
from pathlib import Path
import pty
import secrets
import select
import signal
import subprocess
import sys
import termios
import time

module, directory, real_minisign = sys.argv[1:]
root = Path(directory)
root.mkdir(parents=True, exist_ok=True, mode=0o700)
config = root / "config"
config.mkdir(exist_ok=True, mode=0o700)
private = config / "minisign.key"
public = config / "minisign.pub"
provider = root / "password file"
if not provider.exists():
    provider.write_bytes(secrets.token_hex(24).encode() + b"\n")
    provider.chmod(0o600)
password = provider.read_bytes().rstrip(b"\n")
failures = 0

def check(condition, label):
    global failures
    print(("PASS: " if condition else "FAIL: ") + label, flush=True)
    failures += not condition
    return bool(condition)

def run(command, *, env=None, data=b"", timeout=40):
    process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        out, err = process.communicate(data, timeout=timeout)
        return subprocess.CompletedProcess(command, process.returncode, out, err)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        out, err = process.communicate()
        return subprocess.CompletedProcess(command, 124, out, err)

if not private.exists():
    generated = run([real_minisign, "-G", "-s", str(private), "-p", str(public)],
                    data=(password + b"\n") * 2)
    if not check(generated.returncode == 0, "real Minisign generates an encrypted key"):
        sys.exit(1)
else:
    check(public.is_file(), "retained real encrypted-key fixture is available")

# The observer records process metadata and delegates every operation to the
# real binary without reading or replacing its stdin or successful result.
observer_dir = root / "observer"
observer_dir.mkdir(exist_ok=True)
observer = observer_dir / "minisign"
audit = root / "minisign-processes.jsonl"
audit.write_text("")
observer.write_text("#!" + sys.executable + "\n" + '''import json, os, sys
with open(os.environ["DSR_TEST_PROCESS_AUDIT"], "a") as output:
    output.write(json.dumps({"argv": sys.argv, "env": dict(os.environ)}) + "\\n")
os.execv(os.environ["DSR_TEST_REAL_MINISIGN"], ["minisign"] + sys.argv[1:])
''')
observer.chmod(0o700)
# Do not copy unrelated user credentials into the observer's metadata log.
env = {"PATH": str(observer_dir) + os.pathsep + os.environ["PATH"],
       "HOME": str(root), "LANG": "C", "NO_COLOR": "1",
       "DSR_CONFIG_DIR": str(config), "DSR_MINISIGN_KEY": str(private),
       "DSR_MINISIGN_PASSWORD_FILE": str(provider), "NON_INTERACTIVE": "true",
       "DSR_TEST_PROCESS_AUDIT": str(audit), "DSR_TEST_REAL_MINISIGN": real_minisign}

def invoke(arguments, *, overrides=None, data=b"", body=None, trace=False):
    selected_env = dict(env)
    for key, value in (overrides or {}).items():
        if value is None:
            selected_env.pop(key, None)
        else:
            selected_env[key] = str(value)
    script = 'set -uo pipefail\nsource "$1"\nshift\n'
    script += body if body is not None else '"$@"'
    return run(["bash", "-x" if trace else "-c", *( ["-c"] if trace else [] ),
                script, "encrypted-signing-test", module, *map(str, arguments)],
               env=selected_env, data=data)

def artifact(name):
    path = root / name
    path.write_text("immutable release bytes for " + name + "\n")
    return path

def signature(path):
    return Path(str(path) + ".minisig")

def verify(path):
    return run([real_minisign, "-V", "-p", str(public), "-m", str(path),
                "-x", str(signature(path))]).returncode == 0

def custody(paths):
    return {str(path): (path.stat().st_dev, path.stat().st_ino, path.stat().st_mode,
                        path.stat().st_size, path.stat().st_mtime_ns,
                        path.stat().st_ctime_ns, hashlib.sha256(path.read_bytes()).hexdigest())
            for path in paths}

first, second = artifact("loop one.bin"), artifact("loop two.bin")
inventory = (str(first) + "\n" + str(second) + "\n").encode()
observed = root / "observed-inventory"
observed.write_text("")
before = custody([private, public, provider, first, second])
loop = invoke([observed], data=inventory, trace=True, body='''
while IFS= read -r artifact; do
    signing_sign "$artifact" --trusted-comment "encrypted inventory" || exit $?
    printf '%s\\n' "$artifact" >> "$1"
done
''')
check(loop.returncode == 0, "encrypted signing succeeds inside a real artifact-list loop")
check(observed.read_bytes() == inventory, "each signer preserves the complete enclosing stdin inventory")
check(verify(first) and verify(second), "both loop artifacts have real independently verified signatures")
check(custody([private, public, provider, first, second]) == before,
      "encrypted signing preserves key, password, and payload bytes and identities")
check(password not in loop.stdout + loop.stderr + audit.read_bytes(),
      "password is absent from stdout, stderr, shell trace, argv, and environment")
if failures:
    # The incumbent already provides a decisive real-key counterexample. Do
    # not turn missing first signatures into dozens of dependent failures.
    sys.exit(1)

retained = custody([signature(first), signature(second)])
missing = {"DSR_MINISIGN_PASSWORD_FILE": root / "absent-password",
           "DSR_MINISIGN_KEY": root / "absent-private-key"}
single_reuse = invoke(["signing_sign", first, "--trusted-comment", "encrypted inventory"], overrides=missing)
batch_reuse = invoke(["signing_sign_batch", first, second], overrides=missing)
check(single_reuse.returncode == 0 and batch_reuse.returncode == 0,
      "verified single and batch retries need neither password file nor private key")
check(custody([signature(first), signature(second)]) == retained,
      "credential-free retries preserve retained signatures byte-for-byte")

third, fourth = artifact("batch one.bin"), artifact("batch two.bin")
batch = invoke(["signing_sign_batch", third, fourth])
check(batch.returncode == 0 and verify(third) and verify(fourth),
      "a real encrypted-key batch signs and verifies every new artifact")
fifth = artifact("resume batch.bin")
mixed = invoke(["signing_sign_batch", third, fifth])
check(mixed.returncode == 0 and verify(third) and verify(fifth),
      "a partial encrypted-key batch resumes retained and new signatures together")

for label, contents, mode in [("no-final-newline", password, 0o600),
                              ("CRLF", password + b"\r\n", 0o600),
                              ("read-only", password + b"\n", 0o400)]:
    selected = root / (label + "-password")
    selected.write_bytes(contents)
    selected.chmod(mode)
    payload = artifact(label + ".bin")
    result = invoke(["signing_sign", payload], overrides={"DSR_MINISIGN_PASSWORD_FILE": selected})
    check(result.returncode == 0 and verify(payload),
          label + " private password file creates a real verified signature")

startup = root / "python-startup"
startup.mkdir()
sentinel = root / "unexpected-python-startup"
(startup / "sitecustomize.py").write_text(
    "from pathlib import Path\nPath(" + repr(str(sentinel)) + ").write_text('executed')\n")
isolated = artifact("isolated-reader.bin")
# Bypass the Python metadata observer here: only the password reader is under
# test, and the actual Minisign binary has no Python startup behavior.
result = invoke(["signing_sign", isolated], overrides={
    "PATH": os.environ["PATH"], "PYTHONPATH": startup})
check(result.returncode == 0 and verify(isolated) and not sentinel.exists(),
      "password reader ignores inherited Python startup hooks")

wrong_provider = root / "wrong-password"
wrong_provider.write_bytes(b"deliberately incorrect fixture password\n")
wrong_provider.chmod(0o600)
wrong = artifact("wrong-password.bin")
rejected = invoke(["signing_sign", wrong], overrides={"DSR_MINISIGN_PASSWORD_FILE": wrong_provider})
check(rejected.returncode == 4 and not signature(wrong).exists(),
      "incorrect password fails without publishing a detached signature")
wrong_batch = artifact("wrong-batch.bin")
retained = custody([signature(third)])
rejected_batch = invoke(["signing_sign_batch", third, wrong_batch],
                        overrides={"DSR_MINISIGN_PASSWORD_FILE": wrong_provider})
check(rejected_batch.returncode == 4 and not signature(wrong_batch).exists()
      and custody([signature(third)]) == retained,
      "incorrect password preserves retained batch signatures and publishes no new one")
retry = invoke(["signing_sign", wrong])
check(retry.returncode == 0 and verify(wrong), "a failed password attempt can retry with the correct provider")

unsigned = artifact("no-provider.bin")
closed = invoke([unsigned], overrides={"DSR_MINISIGN_PASSWORD_FILE": None},
                data=b"untouched inventory row\n", body='''
signing_sign "$1"
status=$?
IFS= read -r remaining
printf '%s\\n' "$remaining"
exit "$status"
''')
check(closed.returncode == 4 and not signature(unsigned).exists()
      and closed.stdout == b"untouched inventory row\n",
      "noninteractive encrypted signing fails without consuming caller stdin")
check(b"DSR_MINISIGN_PASSWORD_FILE" in closed.stderr,
      "missing unattended password reports the explicit provider setting")

invalid = []
for label, contents, mode in [("public", password + b"\n", 0o644),
                              ("empty", b"", 0o600),
                              ("multiline", password + b"\nsecond\n", 0o600),
                              ("nul", password + b"\0\n", 0o600),
                              ("oversized", b"x" * 1023 + b"\n", 0o600)]:
    path = root / (label + "-provider")
    path.write_bytes(contents)
    path.chmod(mode)
    invalid.append((label, path))
link = root / "symlink-provider"
link.symlink_to(provider)
invalid.append(("symlink", link))
fifo = root / "fifo-provider"
os.mkfifo(fifo, 0o600)
invalid.append(("FIFO", fifo))
folder = root / "directory-provider"
folder.mkdir(mode=0o700)
invalid.append(("directory", folder))
hardlink_source = root / "hardlink-source"
hardlink_source.write_bytes(password + b"\n")
hardlink_source.chmod(0o600)
hardlink = root / "hardlink-provider"
os.link(hardlink_source, hardlink)
invalid.append(("multiply linked", hardlink))
invalid.append(("missing", root / "missing-provider"))
for label, path in invalid:
    payload = artifact(label + "-provider.bin")
    result = invoke(["signing_sign", payload], overrides={"DSR_MINISIGN_PASSWORD_FILE": path})
    check(result.returncode == 4 and not signature(payload).exists(),
          label + " password provider is refused promptly without publishing")

# The terminal is controlling stderr, while stdin remains an artifact stream.
# This catches a check of `-t 0`, which silently loses interactive loop support.
tty_artifact = artifact("interactive.bin")
master, slave = pty.openpty()
tty_env = dict(env)
tty_env.pop("DSR_MINISIGN_PASSWORD_FILE")
tty_env["NON_INTERACTIVE"] = "false"
script = '''set -uo pipefail
source "$1"
signing_sign "$2"
status=$?
IFS= read -r remaining
printf '%s\\n' "$remaining"
exit "$status"
'''
def controlling_terminal():
    os.setsid()
    import fcntl
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

process = subprocess.Popen(["bash", "-c", script, "tty-signing-test", module, str(tty_artifact)],
                           env=tty_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=slave, preexec_fn=controlling_terminal)
os.close(slave)
process.stdin.write(b"interactive inventory remains\n")
process.stdin.close()
terminal_output = b""
sent = False
deadline = time.monotonic() + 40
while process.poll() is None and time.monotonic() < deadline:
    ready, _, _ = select.select([master], [], [], 0.2)
    if ready:
        try:
            terminal_output += os.read(master, 8192)
        except OSError:
            break
        if b"Password:" in terminal_output and not sent:
            os.write(master, password + b"\n")
            sent = True
if process.poll() is None:
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
output = process.stdout.read()
os.close(master)
check(sent and process.returncode == 0 and verify(tty_artifact)
      and output == b"interactive inventory remains\n",
      "interactive signing reads a separate controlling terminal and preserves inventory stdin")
check(password not in terminal_output, "interactive Minisign keeps the password out of terminal output")
check(custody([private, public, provider, first, second]) == before,
      "all password failures and retries preserve original signing inputs")
check(not list(root.rglob("*.dsr-signing.*")) and not list(root.rglob("*.dsr-batch.*")),
      "successful and failed encrypted signing leave no private staging directories")
sys.exit(bool(failures))
PY
  while IFS= read -r line; do
    case "$line" in
      'PASS: '*) ((TESTS_RUN++)); pass "${line#PASS: }" ;;
      'FAIL: '*) ((TESTS_RUN++)); fail "${line#FAIL: }" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$report"
  if ((status != 0)) && ! grep -q '^FAIL: ' "$report"; then
    ((TESTS_RUN++))
    fail "encrypted-key regression driver completed (exit $status)"
  fi
}

# Main
echo "Running signing module tests..."
echo ""

if [[ "${1:-}" == "--encrypted-only" ]]; then
  test_signing_encrypted_key_input
else
test_signing_require_minisign_missing
test_signing_init_creates_keys
test_signing_check_valid
test_signing_fix_permissions
test_signing_init_force_and_dry_run
test_signing_config_is_honored
test_signing_sign_and_verify
test_signing_verify_failure
test_signing_sign_batch
test_signing_exact_creates_verified_signature_without_clobbering
test_signing_exact_wrong_key_leaves_no_signature
test_signing_exact_publish_failure_leaves_no_signature
test_signing_exact_preserves_competing_publish_replacement
test_signing_exact_fails_closed_on_post_publish_input_mutation
test_signing_exact_preserves_competing_symlink_replacement
test_signing_exact_rejects_legacy_signature
test_signing_exact_rejects_symlink_private_key
test_signing_sign_missing_key
test_signing_sign_multiple_files_error
test_signing_verify_multiple_files_error
test_signing_encrypted_key_input
fi

echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN"
echo "Passed:    $TESTS_PASSED"
echo "Failed:    $TESTS_FAILED"
echo "Skipped:   $TESTS_SKIPPED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
