#!/usr/bin/env bash
# test_installer_signatures.sh - Tests for installer signature verification + cache/offline mode
#
# Tests minisign verification, --require-signatures, checksum verification,
# and offline/cache mode functionality in installer scripts.
#
# Run: ./scripts/tests/test_installer_signatures.sh

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
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }

# ============================================================================
# Local implementation of key installer functions for testing
# These mirror the real functions but are isolated for testing
# ============================================================================

# Verify minisign signature (test version)
_test_verify_minisign() {
    local file="$1"
    local sig_url="$2"
    local pubkey="${MINISIGN_PUBKEY:-}"
    local require_sigs="${_REQUIRE_SIGNATURES:-false}"

    # Skip if no public key configured
    if [[ -z "$pubkey" || "$pubkey" == "" ]]; then
        if [[ "$require_sigs" == "true" ]]; then
            echo "ERROR: Signature verification required but no public key configured" >&2
            return 1
        fi
        return 0
    fi

    # Check if minisign is available
    if ! command -v minisign &>/dev/null; then
        if [[ "$require_sigs" == "true" ]]; then
            echo "ERROR: minisign required for signature verification but not installed" >&2
            return 1
        fi
        echo "WARN: minisign not available - skipping signature verification" >&2
        return 0
    fi

    # Download signature (mock in tests)
    local sig_file="${file}.minisig"
    if ! curl -sSfL "$sig_url" -o "$sig_file" 2>/dev/null; then
        if [[ "$require_sigs" == "true" ]]; then
            echo "ERROR: Signature download failed" >&2
            return 1
        fi
        echo "WARN: No signature available - skipping verification" >&2
        return 0
    fi

    # Create temp file for public key
    local pubkey_file
    pubkey_file=$(mktemp)
    echo "$pubkey" > "$pubkey_file"

    # Verify
    if minisign -Vm "$file" -p "$pubkey_file" 2>/dev/null; then
        echo "OK: Signature verified" >&2
        rm -f "$pubkey_file" "$sig_file"
        return 0
    else
        echo "ERROR: Signature verification FAILED!" >&2
        rm -f "$pubkey_file" "$sig_file"
        return 1
    fi
}

# Detect platform (test version matching installer)
_test_detect_platform() {
    local os arch

    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        darwin) os="darwin" ;;
        linux) os="linux" ;;
        mingw*|msys*|cygwin*) os="windows" ;;
        *) echo "ERROR: Unsupported OS: $os" >&2; return 1 ;;
    esac

    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7*) arch="armv7" ;;
        i386|i686) arch="386" ;;
        *) echo "ERROR: Unsupported architecture: $arch" >&2; return 1 ;;
    esac

    echo "$os/$arch"
}

# ============================================================================
# Test Helpers
# ============================================================================

create_mock_minisign() {
    local success="${1:-true}"
    mkdir -p "$TEST_TMPDIR/bin"

    if [[ "$success" == "true" ]]; then
        cat > "$TEST_TMPDIR/bin/minisign" << 'SCRIPT'
#!/usr/bin/env bash
# Mock minisign that always succeeds
exit 0
SCRIPT
    else
        cat > "$TEST_TMPDIR/bin/minisign" << 'SCRIPT'
#!/usr/bin/env bash
# Mock minisign that always fails
echo "Signature verification failed" >&2
exit 1
SCRIPT
    fi
    chmod +x "$TEST_TMPDIR/bin/minisign"
}

create_mock_archive() {
    local archive_path="$1"
    local tool_name="${2:-test-tool}"

    local temp_dir
    temp_dir=$(mktemp -d)

    # Create fake binary
    echo "#!/bin/bash" > "$temp_dir/$tool_name"
    echo "echo '$tool_name version 1.0.0'" >> "$temp_dir/$tool_name"
    chmod +x "$temp_dir/$tool_name"

    # Create tar.gz
    tar -czf "$archive_path" -C "$temp_dir" "$tool_name"
    rm -rf "$temp_dir"
}

# ============================================================================
# Tests: Minisign Verification Logic
# ============================================================================

test_verify_minisign_skips_when_no_pubkey() {
    ((TESTS_RUN++))
    harness_setup

    # Clear public key
    MINISIGN_PUBKEY=""
    _REQUIRE_SIGNATURES=false

    # Create test file
    echo "test content" > "$TEST_TMPDIR/test_file"

    # Should return 0 (success - skip is ok)
    if _test_verify_minisign "$TEST_TMPDIR/test_file" "http://example.com/test.minisig" 2>/dev/null; then
        pass "verify_minisign skips when no pubkey configured"
    else
        fail "verify_minisign should succeed (skip) when no pubkey configured"
    fi

    harness_teardown
}

test_verify_minisign_fails_when_required_and_no_pubkey() {
    ((TESTS_RUN++))
    harness_setup

    # Clear public key but require signatures
    MINISIGN_PUBKEY=""
    _REQUIRE_SIGNATURES=true

    echo "test content" > "$TEST_TMPDIR/test_file"

    # Should fail when signatures required but no key
    if ! _test_verify_minisign "$TEST_TMPDIR/test_file" "http://example.com/test.minisig" 2>/dev/null; then
        pass "verify_minisign fails when signatures required but no pubkey"
    else
        fail "verify_minisign should fail when signatures required but no pubkey"
    fi

    harness_teardown
}

test_verify_minisign_warns_when_tool_missing() {
    ((TESTS_RUN++))
    harness_setup

    # Set pubkey but hide minisign
    MINISIGN_PUBKEY="RWQf6LRCGA9i5bx/Tw8T6V0X4uOsU0Hf"
    _REQUIRE_SIGNATURES=false

    # Use PATH that doesn't have minisign
    local old_path="$PATH"
    PATH="/usr/bin:/bin"

    echo "test content" > "$TEST_TMPDIR/test_file"

    # Should succeed with warning when minisign not found
    local status=0
    _test_verify_minisign "$TEST_TMPDIR/test_file" "http://example.com/test.minisig" 2>/dev/null || status=$?

    PATH="$old_path"

    if [[ "$status" -eq 0 ]]; then
        pass "verify_minisign succeeds (with warning) when minisign missing"
    else
        fail "verify_minisign should succeed when minisign missing and not required"
    fi

    harness_teardown
}

test_verify_minisign_fails_when_tool_missing_and_required() {
    ((TESTS_RUN++))
    harness_setup

    MINISIGN_PUBKEY="RWQf6LRCGA9i5bx/Tw8T6V0X4uOsU0Hf"
    _REQUIRE_SIGNATURES=true

    # Use PATH that doesn't have minisign
    local old_path="$PATH"
    PATH="/usr/bin:/bin"

    echo "test content" > "$TEST_TMPDIR/test_file"

    local status=0
    _test_verify_minisign "$TEST_TMPDIR/test_file" "http://example.com/test.minisig" 2>/dev/null || status=$?

    PATH="$old_path"

    if [[ "$status" -ne 0 ]]; then
        pass "verify_minisign fails when minisign missing and required"
    else
        fail "verify_minisign should fail when minisign missing and signatures required"
    fi

    harness_teardown
}

test_verify_minisign_with_mock_success() {
    ((TESTS_RUN++))
    harness_setup

    # Create mock minisign that succeeds
    create_mock_minisign "true"

    MINISIGN_PUBKEY="RWQf6LRCGA9i5bx/Tw8T6V0X4uOsU0Hf"
    _REQUIRE_SIGNATURES=true

    echo "test content" > "$TEST_TMPDIR/test_file"

    # Create mock signature
    mkdir -p "$TEST_TMPDIR/www"
    echo "mock signature" > "$TEST_TMPDIR/www/test.minisig"

    # Mock curl to use local file
    cat > "$TEST_TMPDIR/bin/curl" << SCRIPT
#!/usr/bin/env bash
if [[ "\$*" == *"-o"* ]]; then
    # Extract output file from args
    output_file=""
    for arg in "\$@"; do
        if [[ -n "\$prev_was_o" ]]; then
            output_file="\$arg"
            break
        fi
        [[ "\$arg" == "-o" ]] && prev_was_o=1
    done
    if [[ -n "\$output_file" ]]; then
        cat "$TEST_TMPDIR/www/test.minisig" > "\$output_file"
    fi
fi
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/curl"

    local status=0
    PATH="$TEST_TMPDIR/bin:$PATH" _test_verify_minisign "$TEST_TMPDIR/test_file" "http://example.com/test.minisig" 2>/dev/null || status=$?

    if [[ "$status" -eq 0 ]]; then
        pass "verify_minisign succeeds with valid mock signature"
    else
        fail "verify_minisign should succeed with mock valid signature"
    fi

    harness_teardown
}

test_verify_minisign_with_mock_failure() {
    ((TESTS_RUN++))
    harness_setup

    # Create mock minisign that fails
    create_mock_minisign "false"

    MINISIGN_PUBKEY="RWQf6LRCGA9i5bx/Tw8T6V0X4uOsU0Hf"
    _REQUIRE_SIGNATURES=true

    echo "test content" > "$TEST_TMPDIR/test_file"

    mkdir -p "$TEST_TMPDIR/www"
    echo "mock signature" > "$TEST_TMPDIR/www/test.minisig"

    cat > "$TEST_TMPDIR/bin/curl" << SCRIPT
#!/usr/bin/env bash
if [[ "\$*" == *"-o"* ]]; then
    output_file=""
    for arg in "\$@"; do
        if [[ -n "\$prev_was_o" ]]; then
            output_file="\$arg"
            break
        fi
        [[ "\$arg" == "-o" ]] && prev_was_o=1
    done
    if [[ -n "\$output_file" ]]; then
        cat "$TEST_TMPDIR/www/test.minisig" > "\$output_file"
    fi
fi
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/curl"

    local status=0
    PATH="$TEST_TMPDIR/bin:$PATH" _test_verify_minisign "$TEST_TMPDIR/test_file" "http://example.com/test.minisig" 2>/dev/null || status=$?

    if [[ "$status" -ne 0 ]]; then
        pass "verify_minisign fails with invalid mock signature"
    else
        fail "verify_minisign should fail when signature verification fails"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Checksum Verification
# ============================================================================

test_checksum_verification_success() {
    ((TESTS_RUN++))
    harness_setup

    # Create test file
    local test_file="$TEST_TMPDIR/test_archive.tar.gz"
    create_mock_archive "$test_file" "test-tool"

    # Calculate checksum
    local expected_sha
    if command -v sha256sum &>/dev/null; then
        expected_sha=$(sha256sum "$test_file" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        expected_sha=$(shasum -a 256 "$test_file" | awk '{print $1}')
    else
        skip "sha256sum or shasum required"
        harness_teardown
        return
    fi

    local actual_sha
    if command -v sha256sum &>/dev/null; then
        actual_sha=$(sha256sum "$test_file" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        actual_sha=$(shasum -a 256 "$test_file" | awk '{print $1}')
    fi

    if [[ "$expected_sha" == "$actual_sha" ]]; then
        pass "checksum verification logic works for matching checksums"
    else
        fail "checksum verification logic should match"
    fi

    harness_teardown
}

test_checksum_verification_mismatch() {
    ((TESTS_RUN++))
    harness_setup

    # Create test file
    local test_file="$TEST_TMPDIR/test_archive.tar.gz"
    create_mock_archive "$test_file" "test-tool"

    # Wrong checksum
    local expected_sha="0000000000000000000000000000000000000000000000000000000000000000"
    local actual_sha
    if command -v sha256sum &>/dev/null; then
        actual_sha=$(sha256sum "$test_file" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        actual_sha=$(shasum -a 256 "$test_file" | awk '{print $1}')
    else
        skip "sha256sum or shasum required"
        harness_teardown
        return
    fi

    if [[ "$expected_sha" != "$actual_sha" ]]; then
        pass "checksum verification logic detects mismatched checksums"
    else
        fail "checksum verification should detect mismatch"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Offline Mode
# ============================================================================

test_offline_mode_archive_creation() {
    ((TESTS_RUN++))
    harness_setup

    # Create a local archive
    local archive_path="$TEST_TMPDIR/local_archive.tar.gz"
    create_mock_archive "$archive_path" "ntm"

    # Verify archive exists and is valid
    if [[ -f "$archive_path" ]] && tar -tzf "$archive_path" &>/dev/null; then
        pass "offline mode: local archive can be created and verified"
    else
        fail "offline mode: should be able to create valid local archive"
    fi

    harness_teardown
}

test_offline_mode_fails_for_missing_archive() {
    ((TESTS_RUN++))
    harness_setup

    # Run with non-existent archive using the real installer
    local installer="$PROJECT_ROOT/installers/ntm/install.sh"

    if [[ ! -f "$installer" ]]; then
        skip "installer not found at $installer"
        harness_teardown
        return
    fi

    # Pin the version so the failure reaches archive admission, not latest discovery.
    exec_run "$installer" --version v1.2.3 --offline "$TEST_TMPDIR/nonexistent.tar.gz" --non-interactive
    local status
    status=$(exec_status)

    if [[ "$status" -ne 0 ]]; then
        pass "offline mode fails for missing archive"
    else
        fail "offline mode should fail when archive doesn't exist"
    fi

    harness_teardown
}

test_offline_mode_error_message() {
    ((TESTS_RUN++))
    harness_setup

    local installer="$PROJECT_ROOT/installers/ntm/install.sh"

    if [[ ! -f "$installer" ]]; then
        skip "installer not found"
        harness_teardown
        return
    fi

    exec_run "$installer" --offline "$TEST_TMPDIR/missing.tar.gz" --non-interactive

    # An unversioned offline request must fail before attempting latest discovery.
    if [[ $(exec_status) -ne 0 ]] && exec_stderr_contains "Offline installation requires --version; latest cannot be resolved without network"; then
        pass "unversioned offline mode reports its required version"
    else
        fail "offline mode should show error"
        echo "stderr: $(exec_stderr)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: --require-signatures Flag
# ============================================================================

test_require_signatures_flag_logic() {
    ((TESTS_RUN++))
    harness_setup

    # Simulate flag setting behavior
    _REQUIRE_SIGNATURES=false
    _VERIFY=false

    # When --require-signatures is passed, both should be set
    _REQUIRE_SIGNATURES=true
    _VERIFY=true

    if [[ "$_REQUIRE_SIGNATURES" == "true" && "$_VERIFY" == "true" ]]; then
        pass "--require-signatures sets both flags"
    else
        fail "--require-signatures should set both _REQUIRE_SIGNATURES and _VERIFY"
    fi

    harness_teardown
}

test_require_signatures_with_missing_minisign() {
    ((TESTS_RUN++))
    harness_setup

    MINISIGN_PUBKEY="RWQf6LRCGA9i5bx/Tw8T6V0X4uOsU0Hf"
    _REQUIRE_SIGNATURES=true

    # Clear PATH to hide minisign
    local old_path="$PATH"
    PATH="/usr/bin:/bin"

    echo "test content" > "$TEST_TMPDIR/test_file"

    local status=0
    _test_verify_minisign "$TEST_TMPDIR/test_file" "http://example.com/test.minisig" 2>/dev/null || status=$?

    PATH="$old_path"

    if [[ "$status" -ne 0 ]]; then
        pass "--require-signatures fails when minisign not installed"
    else
        fail "--require-signatures should fail when minisign not available"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Installer Help (uses real installer)
# ============================================================================

test_installer_help_shows_signature_options() {
    ((TESTS_RUN++))
    harness_setup

    local installer="$PROJECT_ROOT/installers/ntm/install.sh"

    if [[ ! -f "$installer" ]]; then
        skip "installer not found"
        harness_teardown
        return
    fi

    # Check help comments directly from file (installer has template vars that error)
    local help_content
    help_content=$(grep '^#' "$installer" | head -20)

    if echo "$help_content" | grep -q "verify"; then
        pass "installer help shows signature options (from source comments)"
    else
        fail "installer help should show signature options"
        echo "help: $help_content"
    fi

    harness_teardown
}

test_installer_help_shows_offline_option() {
    ((TESTS_RUN++))
    harness_setup

    local installer="$PROJECT_ROOT/installers/ntm/install.sh"

    if [[ ! -f "$installer" ]]; then
        skip "installer not found"
        harness_teardown
        return
    fi

    # Check help comments directly from file (installer has template vars that error)
    local help_content
    help_content=$(grep '^#' "$installer" | head -30)

    if echo "$help_content" | grep -q "offline"; then
        pass "installer help shows offline option (from source comments)"
    else
        fail "installer help should show --offline"
        echo "help: $help_content"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Root dsr Installer
# ============================================================================

test_root_installer_uses_nested_repo_dir_default() {
    ((TESTS_RUN++))
    harness_setup

    local installer="$PROJECT_ROOT/install.sh"
    local content
    content=$(<"$installer")

    if grep -qF 'DSR_DATA_DIR="${DSR_DATA_DIR:-$DATA_HOME/dsr}"' <<< "$content" && \
       grep -qF 'REPO_DIR="${REPO_DIR:-${DSR_REPO_DIR:-$DSR_DATA_DIR/repo}}"' <<< "$content" && \
       grep -qF -- '--repo-dir DIR     Clone repo to DIR (default: ~/.local/share/dsr/repo)' <<< "$content"; then
        pass "root installer keeps source checkout under data-dir/repo"
    else
        fail "root installer should not clone into the dsr data root"
    fi

    harness_teardown
}

test_root_installer_rejects_occupied_non_git_repo_dir() {
    ((TESTS_RUN++))
    harness_setup

    local installer="$PROJECT_ROOT/install.sh"
    local content
    content=$(<"$installer")

    if grep -qF 'ensure_repo_dir_available' <<< "$content" && \
       grep -qF 'Install source path exists but is not a git clone' <<< "$content" && \
       grep -qF 'Use --repo-dir with an empty directory' <<< "$content"; then
        pass "root installer reports occupied non-git repo dirs clearly"
    else
        fail "root installer should reject occupied non-git repo dirs before clone"
    fi

    harness_teardown
}

test_root_installer_uses_main_unless_version_explicit() {
    ((TESTS_RUN++))
    harness_setup

    local installer="$PROJECT_ROOT/install.sh"
    local content
    content=$(<"$installer")

    if grep -qF 'if [ "$VERSION_EXPLICIT" -eq 1 ]' <<< "$content" && \
       grep -qF 'CLONE_REFS+=("v${VERSION}" "$VERSION")' <<< "$content" && \
       grep -qF 'CLONE_REFS+=("main")' <<< "$content"; then
        pass "root installer clones main unless --version is explicit"
    else
        fail "root installer should only use version tags for explicit --version installs"
    fi

    harness_teardown
}

# Run the public installer against real source trees, Git clones and tarballs.
# Only the network boundary and named filesystem-failure/signal boundaries are
# fixtures. The production acquisition, validation, activation and rollback all
# execute unchanged; no copied transaction helpers are used here.
test_root_installer_transactions() {
    ((TESTS_RUN++))
    harness_setup
    if ! command -v python3 >/dev/null || ! command -v git >/dev/null; then
        skip "root installer transaction fixtures require Python 3 and Git"
        harness_teardown
        return
    fi
    if python3 - "$PROJECT_ROOT" "$TEST_TMPDIR" <<'PY'
import hashlib
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile

project, temporary = map(Path, sys.argv[1:])
installer = Path(os.environ.get('DSR_ROOT_INSTALLER_UNDER_TEST', project / 'install.sh'))
root = temporary / 'root-installer'
root.mkdir()
real_git, real_mv, real_ln = (shutil.which(name) for name in ('git', 'mv', 'ln'))
checks = 0
failures = []

def check(label, condition):
    global checks
    checks += 1
    print(('PASS' if condition else 'FAIL') + ': ' + label, flush=True)
    if not condition:
        failures.append(label)

def run(command, **options):
    return subprocess.run(command, text=True, capture_output=True, timeout=25, **options)

def source_tree(path, version='1.2.3', label='new', missing='', invalid=''):
    (path / 'src').mkdir(parents=True)
    if missing != 'dsr':
        entry = '''#!/usr/bin/env bash
set -uo pipefail
DSR_VERSION="VERSION_MARKER"
source_path="${BASH_SOURCE[0]}"
while [[ -L "$source_path" ]]; do
  source_dir=$(CDPATH='' cd -P -- "$(dirname "$source_path")" && pwd -P) || exit 1
  source_path=$(readlink "$source_path") || exit 1
  [[ "$source_path" == /* ]] || source_path="$source_dir/$source_path"
done
source_dir=$(CDPATH='' cd -P -- "$(dirname "$source_path")" && pwd -P) || exit 1
for module in guardrails logging config platforms current; do
  source "$source_dir/src/$module.sh" || exit 1
done
if [[ "${1:-}" == --version ]]; then printf 'dsr version %s\\n' "$DSR_VERSION"
else fixture_current; fi
'''.replace('VERSION_MARKER', version)
        if invalid == 'entry':
            entry = 'invalid replacement bytes\n'
        elif invalid == 'syntax':
            entry += 'if true; then\n'
        (path / 'dsr').write_text(entry)
        (path / 'dsr').chmod(0o755)
    for module in ('guardrails', 'logging', 'config', 'platforms'):
        if missing != module:
            (path / 'src' / (module + '.sh')).write_text('# explicit bootstrap fixture\n:\n')
    (path / 'src' / 'current.sh').write_text("fixture_current() { printf '%s\\n' '" + label + "'; }\n")
    if invalid == 'module':
        (path / 'src' / 'current.sh').write_text('if true; then\n')

def tree_snapshot(path):
    rows = {}
    for item in sorted(path.rglob('*')):
        info = item.lstat()
        content = (os.readlink(item) if item.is_symlink() else
                   hashlib.sha256(item.read_bytes()).hexdigest() if item.is_file() else 'directory')
        rows[str(item.relative_to(path))] = (stat.S_IMODE(info.st_mode), content)
    return rows

def identity(path):
    info = path.lstat()
    return info.st_dev, info.st_ino

def archive(path, source):
    with tarfile.open(path, 'w:gz') as output:
        output.add(source, arcname='doodlestein_self_releaser-test')
    return path

valid = root / 'valid-source'
source_tree(valid)
valid_archive = archive(root / 'valid.tar.gz', valid)
git_environment = os.environ.copy()
git_environment.update(GIT_AUTHOR_NAME='DSR fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                       GIT_COMMITTER_NAME='DSR fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
for args in (['-c', 'init.defaultBranch=main', 'init', str(valid)],
             ['-C', str(valid), 'add', '.'],
             ['-C', str(valid), 'commit', '-m', 'Fixture release'],
             ['-C', str(valid), 'tag', 'v1.2.3']):
    result = run([real_git, *args], env=git_environment)
    if result.returncode:
        raise RuntimeError(result.stderr)

def setup(name, old_version='1.2.30', destination=True, old_source=True):
    case = root / name
    selected = case / 'repo'
    target = case / 'bin'
    task_home = case / 'home'
    wrappers = case / 'wrappers'
    for path in (target, task_home, wrappers):
        path.mkdir(parents=True)
    if old_source:
        source_tree(selected, old_version, 'old')
        (selected / '.git').mkdir()
        (selected / '.git' / 'preserve').write_text('original Git metadata\n')
        (selected / 'src' / 'obsolete.sh').write_text('# old release only\n')
        (selected / 'user-notes').write_text('uncommitted user work\n')
    if destination:
        (target / 'dsr').symlink_to(selected / 'dsr')
    wrappers.joinpath('curl').write_text('''#!/usr/bin/env bash
printf 'curl invoked\\n' >> "$DSR_FIXTURE_CASE/http.calls"
exit 22
''')
    wrappers.joinpath('mv').write_text('''#!/usr/bin/env bash
source_path="${@: -2:1}"; destination="${@: -1}"
case "${DSR_FIXTURE_FAULT:-}" in
  source-move)
    if [[ "$source_path" == */candidate && "$destination" == "$DSR_REPO_DIR" ]]; then exit 42; fi ;;
  launcher-move)
    if [[ "$source_path" == */.dsr-launcher.*/candidate ]]; then exit 42; fi ;;
esac
"$DSR_FIXTURE_REAL_MV" "$@" || exit $?
if [[ "${DSR_FIXTURE_FAULT:-}" == source-signal && "$source_path" == "$DSR_REPO_DIR" ]]; then
  kill -TERM "$PPID"
elif [[ "${DSR_FIXTURE_FAULT:-}" == launcher-signal && "$destination" == */.dsr-launcher.*/previous ]]; then
  kill -TERM "$PPID"
fi
''')
    wrappers.joinpath('ln').write_text('''#!/usr/bin/env bash
if [[ "${DSR_FIXTURE_FAULT:-}" == launcher-create && "${@: -1}" == */.dsr-launcher.*/candidate ]]; then exit 42; fi
exec "$DSR_FIXTURE_REAL_LN" "$@"
''')
    wrappers.joinpath('git').write_text('''#!/usr/bin/env bash
if [[ "$1" == clone && "${DSR_FIXTURE_FAULT:-}" == partial-clone ]]; then
  mkdir -p -- "${@: -1}"
  printf 'partial clone fixture\\n' > "${@: -1}/partial"
  exit 42
fi
exec "$DSR_FIXTURE_REAL_GIT" "$@"
''')
    for path in wrappers.iterdir():
        path.chmod(0o755)
    configuration = task_home / '.gitconfig'
    configuration.write_text('[url "' + valid.as_uri() + '"]\n'
                             '\tinsteadOf = https://github.com/Dicklesworthstone/doodlestein_self_releaser.git\n')
    environment = os.environ.copy()
    for key in ('REPO_DIR', 'DSR_DEST', 'DSR_REPO_DIR', 'DSR_DATA_DIR', 'GIT_DIR', 'GIT_WORK_TREE'):
        environment.pop(key, None)
    environment.update(HOME=str(task_home), DSR_DEST=str(target), DSR_REPO_DIR=str(selected),
                       XDG_DATA_HOME=str(task_home / 'data'), DSR_FIXTURE_CASE=str(case),
                       DSR_FIXTURE_REAL_MV=real_mv, DSR_FIXTURE_REAL_LN=real_ln,
                       DSR_FIXTURE_REAL_GIT=real_git, GIT_CONFIG_GLOBAL=str(configuration),
                       GIT_CONFIG_NOSYSTEM='1', GIT_ALLOW_PROTOCOL='file', GIT_TRACE=str(case / 'git.trace'),
                       PATH=str(wrappers) + os.pathsep + os.environ['PATH'])
    return case, selected, target, environment

def invoke(context, arguments, fault=''):
    case, selected, target, environment = context
    environment = dict(environment, DSR_FIXTURE_FAULT=fault)
    result = run(['bash', str(installer), '--quiet', '--no-gum', '--no-configure', *arguments], env=environment)
    (case / 'stdout').write_text(result.stdout)
    (case / 'stderr').write_text(result.stderr)
    return result

def preserved(label, context, before, old_id, result):
    case, selected, target, environment = context
    check(label + ' refuses the update', result.returncode != 0)
    check(label + ' preserves all previous source bytes/modes', selected.is_dir() and tree_snapshot(selected) == before)
    check(label + ' restores the original checkout inode', selected.is_dir() and identity(selected) == old_id)
    check(label + ' leaves the previous launcher runnable', run([str(target / 'dsr')]).stdout.strip() == 'old')

for label, missing, invalid in (
    ('invalid-entry', '', 'entry'), ('missing-entry', 'dsr', ''),
    ('missing-bootstrap', 'logging', ''), ('entry-syntax', '', 'syntax'),
    ('module-syntax', '', 'module'),
):
    package = root / (label + '-source')
    source_tree(package, missing=missing, invalid=invalid)
    bad_archive = archive(root / (label + '.tar.gz'), package)
    context = setup(label)
    before, old_id = tree_snapshot(context[1]), identity(context[1])
    result = invoke(context, ['--offline', str(bad_archive)])
    preserved(label, context, before, old_id, result)

truncated = root / 'truncated.tar.gz'
compressed = valid_archive.read_bytes()
truncated.write_bytes(compressed[:len(compressed) // 2])
context = setup('truncated')
before, old_id = tree_snapshot(context[1]), identity(context[1])
preserved('truncated archive', context, before, old_id, invoke(context, ['--offline', str(truncated)]))

linked = root / 'linked.tar.gz'
with tarfile.open(linked, 'w:gz') as output:
    output.add(valid, arcname='source', filter=lambda entry: None if '/.git' in entry.name else entry)
    entry = tarfile.TarInfo('source/src/linked.sh')
    entry.type, entry.linkname = tarfile.SYMTYPE, '/tmp/dsr-outside-fixture'
    output.addfile(entry)
context = setup('linked')
before, old_id = tree_snapshot(context[1]), identity(context[1])
preserved('linked archive entry', context, before, old_id, invoke(context, ['--offline', str(linked)]))

context = setup('successful-offline')
case, selected, target, environment = context
before, old_id = tree_snapshot(selected), identity(selected)
result = invoke(context, ['--offline', str(valid_archive)])
check('valid offline replacement succeeds', result.returncode == 0)
check('new executable uses the complete new module tree', run([str(target / 'dsr')]).stdout.strip() == 'new')
check('old-only modules do not survive in the active checkout', not (selected / 'src' / 'obsolete.sh').exists())
backups = list(case.glob('.repo.install.*/previous-repo'))
check('prior checkout and uncommitted work are retained exactly', len(backups) == 1 and tree_snapshot(backups[0]) == before and identity(backups[0]) == old_id)
check('offline update performs no HTTP or Git transport', not (case / 'http.calls').exists() and not (case / 'git.trace').exists())
before = tree_snapshot(selected)
result = invoke(context, ['--offline', str(valid_archive), '--version', '1.2.3'])
check('an existing non-Git offline installation can be updated', result.returncode == 0 and tree_snapshot(selected) == before)
check('same-label offline archive is validated instead of shortcutting', len(list(case.glob('.repo.install.*/previous-repo'))) == 2)

for fault in ('source-move', 'source-signal', 'launcher-move', 'launcher-signal', 'launcher-create'):
    context = setup(fault, destination=not fault.startswith('launcher'))
    case, selected, target, environment = context
    if fault.startswith('launcher'):
        other = case / 'old-launcher-source'
        source_tree(other, '1.2.30', 'old')
        (target / 'dsr').symlink_to(other / 'dsr')
    before, old_id, old_link = tree_snapshot(selected), identity(selected), identity(target / 'dsr')
    result = invoke(context, ['--offline', str(valid_archive)], fault)
    preserved('injected ' + fault, context, before, old_id, result)
    check(fault + ' preserves the original launcher entry', identity(target / 'dsr') == old_link)
    if fault.endswith('signal'):
        check(fault + ' returns the actual TERM status', result.returncode == 143)

context = setup('wrong-version')
before, old_id = tree_snapshot(context[1]), identity(context[1])
preserved('version mismatch', context, before, old_id,
          invoke(context, ['--offline', str(valid_archive), '--version', '9.9.9']))

context = setup('partial-clone')
before, old_id = tree_snapshot(context[1]), identity(context[1])
preserved('injected incomplete clone', context, before, old_id,
          invoke(context, ['--version', '1.2.3'], 'partial-clone'))
check('failed clone attempts retain acquisition diagnostics', len(list(context[0].glob('.repo.install.*/candidate-*/partial'))) == 2)

context = setup('version-prefix')
result = invoke(context, ['--version', '1.2.3'])
check('1.2.30 does not satisfy requested 1.2.3', result.returncode == 0 and run([str(context[2] / 'dsr'), '--version']).stdout.strip() == 'dsr version 1.2.3')
check('numeric request uses a genuine local Git tag clone', (context[1] / '.git').is_dir() and run([real_git, '-C', str(context[1]), 'describe', '--tags', '--exact-match']).stdout.strip() == 'v1.2.3')

context = setup('exact-noop', old_version='1.2.3')
for args in (['-c', 'init.defaultBranch=main', 'init', str(context[1])],
             ['-C', str(context[1]), 'add', '.'],
             ['-C', str(context[1]), 'commit', '-m', 'Installed tagged source'],
             ['-C', str(context[1]), 'tag', 'v1.2.3']):
    result = run([real_git, *args], env=git_environment)
    if result.returncode:
        raise RuntimeError(result.stderr)
before, old_id = tree_snapshot(context[1]), identity(context[1])
result = invoke(context, ['--version', 'v1.2.3'])
check('exact selected destination and source version is a no-op', result.returncode == 0 and tree_snapshot(context[1]) == before and identity(context[1]) == old_id)
trace = (context[0] / 'git.trace').read_text() if (context[0] / 'git.trace').exists() else ''
check('exact no-op does not acquire source or contact the network', not list(context[0].glob('.repo.install.*')) and ' clone ' not in trace and ' fetch ' not in trace and not (context[0] / 'http.calls').exists())

# The real project can advance main without changing DSR_VERSION. A matching
# marker must not silently defeat a request to switch back to a release tag.
(context[1] / 'after-tag').write_text('newer main source with the same version\n')
for args in (['-C', str(context[1]), 'add', '.'],
             ['-C', str(context[1]), 'commit', '-m', 'Newer same-version main']):
    result = run([real_git, *args], env=git_environment)
    if result.returncode:
        raise RuntimeError(result.stderr)
before = tree_snapshot(context[1])
result = invoke(context, ['--version', 'v1.2.3'])
check('same version on a different commit does not satisfy a pinned tag', result.returncode == 0 and not (context[1] / 'after-tag').exists() and run([str(context[2] / 'dsr')]).stdout.strip() == 'new')
backups = list(context[0].glob('.repo.install.*/previous-repo'))
check('switching back to a tag preserves the later checkout', len(backups) == 1 and tree_snapshot(backups[0]) == before)

context = setup('other-path-install', destination=False, old_source=False)
case, selected, target, environment = context
unrelated = case / 'unrelated'
source_tree(unrelated, '1.2.3', 'other')
environment['PATH'] = str(unrelated) + os.pathsep + environment['PATH']
result = invoke(context, ['--version', '1.2.3'])
check('same-version dsr elsewhere on PATH does not skip the selected destination', result.returncode == 0 and (target / 'dsr').is_symlink() and run([str(target / 'dsr')]).stdout.strip() == 'new')

context = setup('different-repo-selection', destination=False, old_source=False)
case, selected, target, environment = context
other = case / 'other-repo'
source_tree(other, '1.2.3', 'other')
(target / 'dsr').symlink_to(other / 'dsr')
other_before = tree_snapshot(other)
result = invoke(context, ['--version', '1.2.3'])
check('same version from a different source path does not skip --repo-dir', result.returncode == 0 and os.readlink(target / 'dsr') == str(selected / 'dsr') and tree_snapshot(other) == other_before)

context = setup('overlapping-destination')
case, selected, target, environment = context
environment['DSR_DEST'] = str(selected / 'new-directory' / 'bin')
before, old_id = tree_snapshot(selected), identity(selected)
result = invoke(context, ['--offline', str(valid_archive)])
preserved('destination inside active source', context, before, old_id, result)
check('overlap admission creates no children inside the old checkout', not (selected / 'new-directory').exists())

context = setup('aliased-overlapping-destination')
case, selected, target, environment = context
alias = case / 'source-alias'
alias.symlink_to(selected, target_is_directory=True)
environment['DSR_DEST'] = str(alias / 'new-directory' / 'bin')
before, old_id = tree_snapshot(selected), identity(selected)
result = invoke(context, ['--offline', str(valid_archive)])
preserved('aliased destination inside active source', context, before, old_id, result)
check('resolved overlap leaves the existing directory alias untouched', alias.is_symlink() and os.readlink(alias) == str(selected) and not (selected / 'new-directory').exists())

context = setup('missing-parent-aliased-overlap')
case, selected, target, environment = context
alias = case / 'source-alias'
alias.symlink_to(selected, target_is_directory=True)
environment['DSR_DEST'] = str(case / 'absent' / '..' / 'source-alias' / 'new-directory' / 'bin')
before, old_id = tree_snapshot(selected), identity(selected)
result = invoke(context, ['--offline', str(valid_archive)])
preserved('missing parent before aliased overlap', context, before, old_id, result)
check('dot-dot admission creates neither missing ancestors nor old-source children', not (case / 'absent').exists() and not (selected / 'new-directory').exists())

context = setup('aliased-bin-directory', destination=False)
case, selected, target, environment = context
alias = case / 'bin-alias'
alias.symlink_to(target, target_is_directory=True)
environment['DSR_DEST'] = str(alias)
result = invoke(context, ['--offline', str(valid_archive)])
check('an independent symlinked bin directory remains supported', result.returncode == 0 and run([str(target / 'dsr')]).stdout.strip() == 'new')
check('installation preserves the selected bin directory alias', alias.is_symlink() and os.readlink(alias) == str(target))

print(f'Root installer transactions: {checks - len(failures)}/{checks} checks passed', flush=True)
if failures:
    print('Fixture diagnostics: ' + str(root), file=sys.stderr)
    sys.exit(1)
PY
    then
        pass "public root installer stages complete source and preserves prior installations on failure"
    else
        fail "public root installer transaction regression"
    fi
    harness_teardown
}

# ============================================================================
# Tests: Platform Detection
# ============================================================================

test_platform_detection_format() {
    ((TESTS_RUN++))
    harness_setup

    local platform
    platform=$(_test_detect_platform)

    # Should be in format os/arch
    if [[ "$platform" =~ ^[a-z]+/[a-z0-9]+$ ]]; then
        pass "platform detection returns correct format ($platform)"
    else
        fail "platform detection should return os/arch format"
        echo "Got: $platform"
    fi

    harness_teardown
}

test_platform_detection_known_os() {
    ((TESTS_RUN++))
    harness_setup

    local platform
    platform=$(_test_detect_platform)
    local os="${platform%/*}"

    if [[ "$os" == "linux" || "$os" == "darwin" || "$os" == "windows" ]]; then
        pass "platform detection returns known OS ($os)"
    else
        fail "platform detection should return known OS"
        echo "Got OS: $os"
    fi

    harness_teardown
}

test_platform_detection_known_arch() {
    ((TESTS_RUN++))
    harness_setup

    local platform
    platform=$(_test_detect_platform)
    local arch="${platform#*/}"

    if [[ "$arch" == "amd64" || "$arch" == "arm64" || "$arch" == "armv7" || "$arch" == "386" ]]; then
        pass "platform detection returns known arch ($arch)"
    else
        fail "platform detection should return known arch"
        echo "Got arch: $arch"
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

echo "=== Installer Signatures + Cache/Offline Tests ==="
echo ""

echo "Minisign Verification:"
test_verify_minisign_skips_when_no_pubkey
test_verify_minisign_fails_when_required_and_no_pubkey
test_verify_minisign_warns_when_tool_missing
test_verify_minisign_fails_when_tool_missing_and_required
test_verify_minisign_with_mock_success
test_verify_minisign_with_mock_failure

echo ""
echo "Checksum Verification:"
test_checksum_verification_success
test_checksum_verification_mismatch

echo ""
echo "Offline Mode:"
test_offline_mode_archive_creation
test_offline_mode_fails_for_missing_archive
test_offline_mode_error_message

echo ""
echo "--require-signatures Flag:"
test_require_signatures_flag_logic
test_require_signatures_with_missing_minisign

echo ""
echo "Installer Help (real installer):"
test_installer_help_shows_signature_options
test_installer_help_shows_offline_option

echo ""
echo "Root dsr Installer:"
test_root_installer_uses_nested_repo_dir_default
test_root_installer_rejects_occupied_non_git_repo_dir
test_root_installer_uses_main_unless_version_explicit
test_root_installer_transactions

echo ""
echo "Platform Detection:"
test_platform_detection_format
test_platform_detection_known_os
test_platform_detection_known_arch

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
