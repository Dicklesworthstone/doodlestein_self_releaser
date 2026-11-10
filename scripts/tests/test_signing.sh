#!/usr/bin/env bash
# test_signing.sh - Unit tests for src/signing.sh
#
# Run: ./scripts/tests/test_signing.sh [--encrypted-only|--init-only]
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
    'source "$1" && signing_init --force --no-password' _ "$SIGNING_TEST_MODULE"
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

test_signing_init_preserves_identities() {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "initialization custody tests require python3"
    return
  fi
  local report="$TEMP_DIR/init-results" status=0 line
  # Every generated key and signature below is produced and verified by real
  # Minisign. Only the clock and explicitly named filesystem/process failure
  # boundaries are controlled; none of those adapters manufactures success.
  python3 - "$SIGNING_TEST_MODULE" "$TEMP_DIR/init-custody" \
    "$(command -v minisign)" > "$report" <<'PY' || status=$?
import hashlib
import os
from pathlib import Path
import secrets
import signal
import stat
import subprocess
import sys

module, directory, real_minisign = sys.argv[1:]
root = Path(directory)
root.mkdir(mode=0o700)
failures = 0

def check(condition, label):
    global failures
    print(("PASS: " if condition else "FAIL: ") + label, flush=True)
    failures += not condition
    return bool(condition)

def run(command, *, env=None, data=b"", timeout=30):
    process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        out, err = process.communicate(data, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        out, err = process.communicate()
        return subprocess.CompletedProcess(command, 124, out, err)
    return subprocess.CompletedProcess(command, process.returncode, out, err)

def case(name, *, populated=True):
    folder = root / name
    folder.mkdir(mode=0o700)
    config = folder / "config"
    config.mkdir(mode=0o700)
    private_dir = config / "secrets"
    private_dir.mkdir(mode=0o700)
    private, public = private_dir / "minisign.key", config / "minisign.pub"
    if populated:
        generated = run([real_minisign, "-G", "-W", "-s", str(private), "-p", str(public)])
        if generated.returncode != 0:
            raise RuntimeError("real Minisign fixture generation failed")
        private.chmod(0o600)
    return folder, config, private, public

frozen_clock = '''date() {
    case "$*" in
        *%Y%m%dT%H%M%SZ*) printf '%s\\n' 20400101T000000Z ;;
        *) command date "$@" ;;
    esac
}
'''

def invoke(paths, arguments, *, before="", data=b"", overrides=None):
    folder, config, private, public = paths
    env = {"PATH": os.environ["PATH"], "HOME": str(folder), "LANG": "C", "NO_COLOR": "1",
           "DSR_CONFIG_DIR": str(config), "DSR_STATE_DIR": str(folder / "state"),
           "DSR_CACHE_DIR": str(folder / "cache"), "DSR_MINISIGN_KEY": str(private),
           "DSR_TEST_REAL_MINISIGN": real_minisign}
    env.update(overrides or {})
    script = 'set -uo pipefail\nsource "$1"\nshift\n' + frozen_clock + before + '\nsigning_init "$@"\n'
    return run(["bash", "-c", script, "init-custody", module, *arguments], env=env, data=data)

def key_bytes(paths):
    return tuple(path.read_bytes() for path in paths[2:])

def custody(paths):
    return tuple((path.lstat().st_dev, path.lstat().st_ino, path.lstat().st_mode,
                  path.lstat().st_size, path.lstat().st_mtime_ns,
                  hashlib.sha256(path.read_bytes()).hexdigest()) for path in paths)

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

def backups(paths, expected):
    config, private, public = paths[1:]
    found = []
    for live, contents in zip((private, public), expected):
        matches = [path for path in live.parent.glob(live.name + ".bak.*")
                   if path.is_file() and not path.is_symlink() and path.read_bytes() == contents]
        found.append(matches)
    return found

def signs_and_verifies(private, public, folder, name, *, password=b""):
    artifact = folder / (name + ".bin")
    artifact.write_bytes(b"real signature recovery probe\n")
    signature = folder / (name + ".minisig")
    signed = run([real_minisign, "-S", "-s", str(private), "-m", str(artifact), "-x", str(signature)],
                 data=password + b"\n")
    verified = run([real_minisign, "-V", "-p", str(public), "-m", str(artifact), "-x", str(signature)])
    if signed.returncode != 0 or verified.returncode != 0:
        print("INFO: real Minisign recovery statuses:", signed.returncode, verified.returncode,
              (signed.stderr + verified.stderr).decode(errors="replace"), flush=True)
    return signed.returncode == 0 and verified.returncode == 0

rotations = case("same-second")
old_pairs = [key_bytes(rotations)]
first = invoke(rotations, ["--force", "--no-password"])
old_pairs.append(key_bytes(rotations))
second = invoke(rotations, ["--force", "--no-password"])
check(first.returncode == 0 and second.returncode == 0 and len(set(old_pairs + [key_bytes(rotations)])) == 3,
      "two same-second forced initializations generate three distinct real signing identities")
retained = [backups(rotations, pair) for pair in old_pairs]
complete = all(private and public for private, public in retained)
check(complete, "both same-second rotations retain every original private/public key byte")
check(complete and all(stat.S_IMODE(private[0].stat().st_mode) == 0o600
                       for private, public in retained),
      "every retained private signing identity has mode 600")
check(complete and all(signs_and_verifies(private[0], public[0], rotations[0], "restored-" + str(index))
                       for index, (private, public) in enumerate(retained)),
      "each retained original signing identity independently signs and verifies a real artifact")
check(signs_and_verifies(rotations[2], rotations[3], rotations[0], "current"),
      "the final active key pair independently signs and verifies a real artifact")

occupied = case("occupied-backup")
sentinels = [Path(str(path) + ".bak.20400101T000000Z") for path in occupied[2:]]
for path in sentinels:
    path.write_bytes(b"previous retained signing generation\n")
    path.chmod(0o600)
before = custody(sentinels)
old = key_bytes(occupied)
result = invoke(occupied, ["--force", "--no-password"])
check(result.returncode == 0 and custody(sentinels) == before and all(backups(occupied, old)),
      "occupied timestamp backup names remain untouched while a distinct generation is retained")

for label, args, overrides in [
        ("local", ["--force", "--no-password", "--dry-run"], {}),
        ("global", ["--force", "--no-password"], {"DRY_RUN": "true"}),
        ("short", ["--force", "--no-password", "-n"], {})]:
    paths = case(label + "-preview")
    before = inventory(paths[0])
    result = invoke(paths, args, overrides=overrides)
    check(result.returncode == 0 and inventory(paths[0]) == before,
          label + " initialization preview preserves all bytes, modes, inodes, and directory entries")

fresh_preview = case("fresh-preview", populated=False)
before = inventory(fresh_preview[0])
result = invoke(fresh_preview, ["--dry-run", "--no-password"])
check(result.returncode == 0 and inventory(fresh_preview[0]) == before,
      "fresh initialization preview creates no keys, leases, staging files, or backup directories")
unknown = case("unknown-option")
before = inventory(unknown[0])
result = invoke(unknown, ["--force", "--no-password", "--unknown-init-option"])
check(result.returncode == 4 and inventory(unknown[0]) == before,
      "unknown initialization options fail before any filesystem change")

generation = case("failed-generator")
before = custody(generation[2:])
result = invoke(generation, ["--force", "--no-password"], before='''minisign() {
    command "$DSR_TEST_REAL_MINISIGN" "$@" || return $?
    return 73
}
''')
check(result.returncode != 0 and custody(generation[2:]) == before,
      "injected failure after real key generation preserves both original active keys and identities")

copy_failure = case("failed-backup-copy")
before = custody(copy_failure[2:])
result = invoke(copy_failure, ["--force", "--no-password"], before='''cp() {
    command cp "$@" || return $?
    return 73
}
''')
check(result.returncode != 0 and custody(copy_failure[2:]) == before,
      "injected backup-copy failure preserves both original active keys and identities")

size_limit = case("actual-file-size-limit")
before = custody(size_limit[2:])
result = invoke(size_limit, ["--force", "--no-password"], before="ulimit -f 0\n")
check(result.returncode != 0 and custody(size_limit[2:]) == before,
      "actual RLIMIT_FSIZE write refusal preserves both original keys without replacement")

backup_failure = case("failed-backup-publication")
before = custody(backup_failure[2:])
result = invoke(backup_failure, ["--force", "--no-password"], before='''ln() {
    local destination="${!#}"
    case "$destination" in *.bak.*) return 73 ;; esac
    command ln "$@"
}
''')
check(result.returncode != 0 and custody(backup_failure[2:]) == before,
      "injected backup-publication failure prevents either active key from changing")

publication = case("failed-second-publication")
old = key_bytes(publication)
result = invoke(publication, ["--force", "--no-password"], before='''mv() {
    local destination="${!#}"
    [[ "$destination" != "$SIGNING_PUBLIC_KEY" ]] || return 73
    command mv "$@"
}
''')
check(result.returncode != 0 and key_bytes(publication) == old,
      "injected second-key publication failure restores the complete original active pair")
check(key_bytes(publication) == old and all(backups(publication, old))
      and signs_and_verifies(publication[2], publication[3], publication[0], "rollback"),
      "failed pair publication retains recoverable backups and a usable original signing identity")

if os.geteuid() != 0:
    permissions = case("actual-directory-write-refusal")
    permissions[2].chmod(0o400)
    old = key_bytes(permissions)
    result = invoke(permissions, ["--force", "--no-password"], before='''minisign() {
    command "$DSR_TEST_REAL_MINISIGN" "$@" || return $?
    chmod 500 "$DSR_CONFIG_DIR"
}
''')
    permissions[1].chmod(0o700)
    check(result.returncode != 0 and key_bytes(permissions) == old
          and stat.S_IMODE(permissions[2].stat().st_mode) == 0o400,
          "actual directory-write refusal restores both original keys and private-key mode")
else:
    print("SKIP: actual directory-write refusal requires an unprivileged user", flush=True)

interrupted = case("interrupted-generator")
before = custody(interrupted[2:])
result = invoke(interrupted, ["--force", "--no-password"], before='''minisign() {
    command "$DSR_TEST_REAL_MINISIGN" "$@" || return $?
    kill -TERM "$$"
    return 73
}
''')
check(result.returncode != 0 and custody(interrupted[2:]) == before,
      "real process interruption after staged generation preserves the original active pair")
retry = invoke(interrupted, ["--force", "--no-password"])
check(retry.returncode != 0 and custody(interrupted[2:]) == before,
      "interrupted initialization retains a lease that refuses an unreviewed retry")

for kind in ("symlink", "directory", "FIFO", "dangling-symlink"):
    unsafe = case("unsafe-" + kind, populated=False)
    target = unsafe[0] / "unrelated-target"
    target.write_bytes(b"unrelated bytes must survive\n")
    if kind == "symlink":
        unsafe[2].symlink_to(target)
    elif kind == "directory":
        unsafe[2].mkdir()
    elif kind == "FIFO":
        os.mkfifo(unsafe[2], 0o600)
    else:
        unsafe[2].symlink_to(unsafe[0] / "missing-target")
    before = inventory(unsafe[0])
    result = invoke(unsafe, ["--force", "--no-password"])
    check(result.returncode != 0 and result.returncode != 124 and inventory(unsafe[0]) == before,
          kind + " key destination is refused promptly without changing unrelated files")

hardlink = case("existing-hardlink")
unrelated = hardlink[0] / "unrelated-private-copy"
os.link(hardlink[2], unrelated)
before = custody([unrelated])
result = invoke(hardlink, ["--force", "--no-password"])
check(custody([unrelated]) == before and (result.returncode != 0 or key_bytes(hardlink)[0] != unrelated.read_bytes()),
      "forced initialization never overwrites the inode of an unrelated private-key hardlink")

aliased = case("identical-key-destinations", populated=False)
result = invoke(aliased, ["--force", "--no-password"], overrides={"DSR_MINISIGN_KEY": str(aliased[3])})
check(result.returncode != 0 and not aliased[3].exists(),
      "identical private/public key destinations are refused before publication")

custom = case("external-private-key", populated=False)
custom_private = custom[0] / "external keys" / "identity.key"
custom_private.parent.mkdir(mode=0o700)
result = invoke(custom, ["--no-password"], overrides={"DSR_MINISIGN_KEY": str(custom_private)})
check(result.returncode == 0 and custom_private.is_file()
      and stat.S_IMODE(custom_private.stat().st_mode) == 0o600
      and signs_and_verifies(custom_private, custom[3], custom[0], "external"),
      "configured private-key paths outside the default secrets directory create a usable pair")

encrypted = case("encrypted-initialization", populated=False)
password = secrets.token_hex(24).encode()
result = invoke(encrypted, [], data=(password + b"\n") * 2)
if result.returncode != 0:
    print("INFO: encrypted initialization status:", result.returncode,
          result.stderr.decode(errors="replace"), flush=True)
check(result.returncode == 0 and signs_and_verifies(encrypted[2], encrypted[3], encrypted[0], "encrypted", password=password),
      "default initialization retains real password-protected Minisign key generation")
wrong_signature = encrypted[0] / "wrong-password.minisig"
wrong_password = run([real_minisign, "-S", "-s", str(encrypted[2]),
                      "-m", str(encrypted[0] / "encrypted.bin"), "-x", str(wrong_signature)],
                     data=b"deliberately incorrect initialization fixture password\n")
check(result.returncode == 0 and wrong_password.returncode != 0 and not wrong_signature.exists(),
      "the initialized protected key refuses a wrong password without publishing a signature")
check(password not in result.stdout + result.stderr,
      "encrypted initialization never prints the password")

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
    fail "initialization custody regression driver completed (exit $status)"
  fi
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
elif [[ "${1:-}" == "--init-only" ]]; then
  test_signing_init_preserves_identities
else
test_signing_require_minisign_missing
test_signing_init_creates_keys
test_signing_check_valid
test_signing_fix_permissions
test_signing_init_force_and_dry_run
test_signing_init_preserves_identities
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
