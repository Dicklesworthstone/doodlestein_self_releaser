#!/usr/bin/env bash
# test_act_runner_native.sh - Unit tests for act_runner.sh native build SSH logic
#
# Usage: ./test_act_runner_native.sh
#
# Tests native build SSH command construction with mocks.
# Covers: command construction, path handling, env vars, SCP, error handling.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_ROOT/src"

# Retained, non-destructive cache tests. The compilation lane must be invoked
# through RCH/DSR; the ordinary lane runs no compiler or build command.
if [[ "${1:-}" == --strict-cargo-cache-tests || "${1:-}" == --strict-cargo-cache-cargo-tests ]]; then
    source "$SRC_DIR/act_runner.sh"
    # Matches the native host launcher; the Cargo test mode belongs on RCH/DSR.
    export RCH_CARGO_WRAPPER_BYPASS=1 RCH_DISABLED=1
    cache_test_root=$(mktemp -d /var/tmp/dsr-cargo-cache-test.XXXXXXXX) || exit 1
    cache_test_root=$(cd "$cache_test_root" && pwd -P)
    printf 'Retained cache fixture: %s\n' "$cache_test_root"
    mkdir -m 700 "$cache_test_root/cache" "$cache_test_root/source" || exit 1
    printf '[package]\nname="cache_probe"\nversion="0.1.0"\nedition="2021"\n' > "$cache_test_root/source/Cargo.toml"
    cache_contract='{"tool":"cache-test","platform":"native","profile":"dev","command":"fixture"}'
    cache_run() (
        cd "$cache_test_root/source" || exit 1
        export CARGO_TARGET_DIR="$cache_test_root/$1"
        bash -c "$(_act_strict_cargo_cache_script "$cache_test_root/cache" "$cache_contract" "$2")"
    )
    if [[ "$1" == --strict-cargo-cache-cargo-tests ]]; then
        mkdir -p "$cache_test_root/dep/src" "$cache_test_root/source/src" || exit 1
        cat > "$cache_test_root/dep/Cargo.toml" <<'EOF'
[package]
name="cache_dep"
version="0.1.0"
edition="2021"
EOF
        printf 'pub fn value() -> u32 { 42 }\n' > "$cache_test_root/dep/src/lib.rs"
        printf '\n[dependencies]\ncache_dep={path="../dep"}\n' >> "$cache_test_root/source/Cargo.toml"
        printf 'fn main() { println!("first:{}", cache_dep::value()); }\n' > "$cache_test_root/source/src/main.rs"
        cache_run first 'cargo build --offline --message-format=json' > "$cache_test_root/first.jsonl" || exit 1
        [[ "$("$cache_test_root/first/debug/cache_probe")" == first:42 ]] || exit 1
        # A distinct immutable source path; the stable dependency simulates the
        # unchanged registry source, while first-party source must be recompiled.
        cp -R "$cache_test_root/source" "$cache_test_root/second-source" || exit 1
        printf 'fn main() { println!("second:{}", cache_dep::value()); }\n' > "$cache_test_root/second-source/src/main.rs"
        (
            cd "$cache_test_root/second-source" || exit 1
            export CARGO_TARGET_DIR="$cache_test_root/second"
            bash -c "$(_act_strict_cargo_cache_script "$cache_test_root/cache" "$cache_contract" 'cargo build --offline --message-format=json')"
        ) > "$cache_test_root/second.jsonl" || exit 1
        [[ "$("$cache_test_root/second/debug/cache_probe")" == second:42 ]] || exit 1
        python3 - "$cache_test_root/second.jsonl" <<'PY' || exit 1
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.startswith('{')]
assert any(row.get('reason') == 'compiler-artifact' and row['target']['name'] == 'cache_dep' and row['fresh'] for row in rows)
assert any(row.get('reason') == 'compiler-artifact' and row['target']['name'] == 'cache_probe' and not row['fresh'] for row in rows)
PY
        cp -R "$cache_test_root/source" "$cache_test_root/invalid-source" || exit 1
        printf 'compile_error!("planted cache stale-output refusal");\n' > "$cache_test_root/invalid-source/src/main.rs"
        if (
            cd "$cache_test_root/invalid-source" || exit 1
            export CARGO_TARGET_DIR="$cache_test_root/failed"
            bash -c "$(_act_strict_cargo_cache_script "$cache_test_root/cache" "$cache_contract" 'cargo build --offline --message-format=json')"
        ) > "$cache_test_root/failed.jsonl"; then
            echo 'FAIL: invalid source accepted' >&2; exit 1
        fi
        [[ ! -e "$cache_test_root/failed/debug/cache_probe" && ! -e "$cache_test_root/failed.cache-receipt.json" ]] || exit 1
        [[ "$("$cache_test_root/first/debug/cache_probe")" == first:42 ]] || exit 1
        echo 'PASS: actual two-source dependency reuse, changed marker, failed-build stale-output refusal'
        exit 0
    fi
    cache_run first 'mkdir -p "$CARGO_BUILD_BUILD_DIR" "$CARGO_TARGET_DIR"; printf first > "$CARGO_BUILD_BUILD_DIR/shared"; ln "$CARGO_BUILD_BUILD_DIR/shared" "$CARGO_TARGET_DIR/result"' || exit 1
    python3 - "$cache_test_root" <<'PY' || exit 1
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
receipt = json.loads((root / 'first.cache-receipt.json').read_text())
assert (root / 'first/result').stat().st_nlink == 1
(pathlib.Path(receipt['build_dir']) / 'shared').write_text('changed-cache')
assert (root / 'first/result').read_text() == 'first'
PY
    cache_run same 'mkdir -p "$CARGO_BUILD_BUILD_DIR" "$CARGO_TARGET_DIR"' || exit 1
    (export RUSTFLAGS='--cfg dsr_cache_changed'; cache_run changed 'mkdir -p "$CARGO_BUILD_BUILD_DIR" "$CARGO_TARGET_DIR"') || exit 1
    (cache_contract='{"tool":"cache-test","platform":"native","profile":"dev","command":"changed"}'; cache_run configured 'mkdir -p "$CARGO_BUILD_BUILD_DIR" "$CARGO_TARGET_DIR"') || exit 1
    python3 - "$cache_test_root" <<'PY' || exit 1
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
def key(name):
    return json.loads((root / (name + '.cache-receipt.json')).read_text())['namespace']
assert key('first') == key('same')
assert key('first') != key('changed')
assert key('first') != key('configured')
PY
    cache_run holder 'mkdir -p "$CARGO_BUILD_BUILD_DIR" "$CARGO_TARGET_DIR"; touch "$CARGO_TARGET_DIR/ready"; sleep 3' &
    holder_pid=$!
    for _ in {1..100}; do
        [[ -e "$cache_test_root/holder/ready" ]] && break
        sleep 0.05
    done
    [[ -e "$cache_test_root/holder/ready" ]] || exit 1
    if cache_run contender 'exit 0'; then
        echo 'FAIL: concurrent custody admitted' >&2; exit 1
    fi
    wait "$holder_pid" || exit 1
    ln -s "$cache_test_root/cache" "$cache_test_root/unsafe" || exit 1
    if (
        cd "$cache_test_root/source" || exit 1
        export CARGO_TARGET_DIR="$cache_test_root/unsafe-target"
        bash -c "$(_act_strict_cargo_cache_script "$cache_test_root/unsafe" "$cache_contract" 'exit 0')"
    ); then
        echo 'FAIL: symlink cache admitted' >&2; exit 1
    fi
    if cache_run first 'exit 0'; then
        echo 'FAIL: nonfresh final target admitted' >&2; exit 1
    fi
    mkdir "$cache_test_root/fake-bin" || exit 1
    # Same version output is insufficient: this unknown launcher injects a
    # build flag while forwarding version probes unchanged. No build is run.
    real_launcher=$(command -v cargo)
    printf '#!/bin/sh\nexport RUSTFLAGS="--cfg injected_by_unknown_wrapper"\nexec "%s" "$@"\n' "$real_launcher" > "$cache_test_root/fake-bin/cargo"
    chmod 700 "$cache_test_root/fake-bin/cargo" || exit 1
    if (export PATH="$cache_test_root/fake-bin:$PATH"; cache_run unknown-wrapper 'exit 0'); then
        echo 'FAIL: same-version unknown compiler script admitted' >&2; exit 1
    fi
    [[ ! -e "$cache_test_root/unknown-wrapper.cache-receipt.json" ]] || exit 1
    if (export RUSTC_WRAPPER="$cache_test_root/fake-bin/cargo"; cache_run rustc-wrapper 'exit 0'); then
        echo 'FAIL: explicit rustc wrapper admitted' >&2; exit 1
    fi
    if cache_run linked-final 'mkdir -p "$CARGO_BUILD_BUILD_DIR"; ln -s "$CARGO_BUILD_BUILD_DIR" "$CARGO_TARGET_DIR"'; then
        echo 'FAIL: linked final target admitted' >&2; exit 1
    fi
    [[ ! -e "$cache_test_root/linked-final.cache-receipt.json" ]] || exit 1
    echo 'PASS: namespace reuse/flags/config invalidation, hardlink detachment, exclusive custody, unsafe path/nonfresh output/unknown and rustc wrapper/linked final refusal'
    exit 0
fi

# Colors
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0

log_pass() { echo -e "${GREEN}PASS${NC} $1"; ((PASS_COUNT++)); }
log_fail() { echo -e "${RED}FAIL${NC} $1"; ((FAIL_COUNT++)); }
log_test() { echo -e "\n${YELLOW}===${NC} $1 ${YELLOW}===${NC}"; }

# Create mock directories
MOCK_DIR=$(mktemp -d)
export ACT_LOGS_DIR="$MOCK_DIR/logs"
export ACT_ARTIFACTS_DIR="$MOCK_DIR/artifacts"
export ACT_REPOS_DIR="$MOCK_DIR/repos.d"
export ACT_CONFIG_DIR="$MOCK_DIR"

# State capture files (avoids subshell variable loss)
SSH_ARGS_FILE="$MOCK_DIR/ssh_args.txt"
SCP_ARGS_FILE="$MOCK_DIR/scp_args.txt"
SSH_EXIT_CODE_FILE="$MOCK_DIR/ssh_exit_code.txt"
SCP_EXIT_CODE_FILE="$MOCK_DIR/scp_exit_code.txt"
RAW_SSH_ARGS_FILE="$MOCK_DIR/raw_ssh_args.txt"
RSYNC_ARGS_FILE="$MOCK_DIR/rsync_args.txt"
RAW_SSH_EXIT_CODE_FILE="$MOCK_DIR/raw_ssh_exit_code.txt"
RSYNC_EXIT_CODE_FILE="$MOCK_DIR/rsync_exit_code.txt"

mkdir -p "$ACT_LOGS_DIR" "$ACT_ARTIFACTS_DIR" "$ACT_REPOS_DIR"

# Default exit codes (can be overridden per test)
echo "0" > "$SSH_EXIT_CODE_FILE"
echo "0" > "$SCP_EXIT_CODE_FILE"
echo "0" > "$RAW_SSH_EXIT_CODE_FILE"
echo "0" > "$RSYNC_EXIT_CODE_FILE"

# Source the module under test
source "$SRC_DIR/act_runner.sh"

# Decode a `-EncodedCommand` payload back to the PowerShell text so mocks can
# assert on the script the host would actually run (mirrors the helper in
# test_act_orchestration.sh). A cmd.exe line wrapped by
# _act_windows_cmd_via_powershell is unwrapped to the cmd line itself.
_test_decode_remote_command() {
    local command="$1" decoded inner
    if [[ "$command" == powershell\ -NoProfile\ -NonInteractive\ * ||
          "$command" == pwsh\ -NoProfile\ -NonInteractive\ * ]]; then
        decoded=$(_act_windows_command_script "$command") || return 1
        if [[ "$decoded" == *'$dsrBuildScript='* ]]; then
            decoded=$(printf '%s' "$decoded" | python3 -c '
import re, sys
source = sys.stdin.read()
match = re.search(r"(?m)^\$dsrBuildScript=\x27((?:[^\x27]|\x27\x27)*)\x27\n\$dsrBuildEncoded=", source)
if match is None:
    raise SystemExit("missing guarded build script")
sys.stdout.write(match[1].replace("\x27\x27", "\x27"))
') || return 1
        fi
        decoded="${decoded#\$ProgressPreference=\'SilentlyContinue\'; }"
        if [[ "$decoded" == "\$ErrorActionPreference='Stop'; \$c=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"* ]]; then
            inner="${decoded#*FromBase64String(\'}"
            inner="${inner%%\'*}"
            printf '%s' "$inner" | base64 -d 2>/dev/null
            return 0
        fi
        printf '%s' "$decoded"
        return 0
    fi
    printf '%s' "$command"
}

# ============================================================================
# Mock Functions (override after sourcing act_runner.sh)
# ============================================================================

# Mock logging
_log_info()  { :; }  # Silent for tests
_log_error() { :; }
_log_ok()    { :; }
_log_warn()  { :; }

# Run commands directly so shell-function mocks for ssh/rsync are honored.
_act_run_with_timeout() {
    local _seconds="$1"
    shift
    "$@"
}

# Mock _act_ssh_exec - captures args to file
_act_ssh_exec() {
    local host="$1"
    local cmd
    cmd=$(_test_decode_remote_command "$2")
    # Append for subshell-safe capture: a build now issues follow-up exec
    # calls (stage-root cleanup) and the build command must stay recorded.
    # Prefix every line so get_ssh_cmd retains the complete PowerShell command,
    # including the body and tail of embedded functions.
    printf '%s\n' "HOST:$host" >> "$SSH_ARGS_FILE"
    local command_line
    while IFS= read -r command_line || [[ -n "$command_line" ]]; do
        printf 'CMD:%s\n' "$command_line" >> "$SSH_ARGS_FILE"
    done <<< "$cmd"
    local exit_code
    exit_code=$(cat "$SSH_EXIT_CODE_FILE")
    if [[ "$exit_code" -eq 0 && "$cmd" == *"Cargo target source identity mismatch"* && \
          "$cmd" =~ Write-Output\ \'([A-Za-z]:/d/t/[0-9a-f-]+/(amd64|arm64))\' ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
    return "$exit_code"
}

# Write a minimal but format-valid executable for the collection gate
# (_act_accept_collected_binary validates real ELF/Mach-O/PE headers, so an
# empty `touch`ed file no longer passes). Kind is MOCK_ARTIFACT_KIND, or
# inferred: .exe -> PE32+ x64, otherwise Mach-O arm64 (most tests build
# darwin/arm64).
write_mock_artifact() {
    local dest="$1"
    local kind="${MOCK_ARTIFACT_KIND:-auto}"
    if [[ "$kind" == "auto" ]]; then
        case "$dest" in
            *.exe) kind="pe-amd64" ;;
            *) kind="macho-arm64" ;;
        esac
    fi
    case "$kind" in
        macho-arm64)
            { printf '\317\372\355\376\014\000\000\001'; head -c 24 /dev/zero; } > "$dest"
            ;;
        macho-amd64)
            { printf '\317\372\355\376\007\000\000\001'; head -c 24 /dev/zero; } > "$dest"
            ;;
        elf-amd64)
            { printf '\177ELF\002\001'; head -c 12 /dev/zero; printf '\076\000'; head -c 44 /dev/zero; } > "$dest"
            ;;
        elf-arm64)
            { printf '\177ELF\002\001'; head -c 12 /dev/zero; printf '\267\000'; head -c 44 /dev/zero; } > "$dest"
            ;;
        pe-amd64)
            { printf 'MZ'; head -c 58 /dev/zero; printf '\100\000\000\000PE\000\000\144\206'; head -c 18 /dev/zero; printf '\013\002'; head -c 6 /dev/zero; } > "$dest"
            ;;
        *)
            : > "$dest"
            ;;
    esac
    chmod 755 "$dest" 2>/dev/null || true
}

# Mock scp - captures args to file
scp() {
    printf '%s\n' "$@" > "$SCP_ARGS_FILE"
    local exit_code
    exit_code=$(cat "$SCP_EXIT_CODE_FILE")
    if [[ "$exit_code" -eq 0 ]]; then
        # Materialize the target file (last arg) to simulate a download
        local target="${!#}"
        if [[ "$target" == *:* ]]; then
            # Launcher uploads must not create a bogus host:path tree locally.
            local source="${*: -2:1}"
            if [[ "$target" == */build.ps1 && -f "$source" ]]; then
                cat "$source" > "$MOCK_DIR/staged-build.ps1"
            fi
            return 0
        fi
        mkdir -p "$(dirname "$target")" 2>/dev/null || true
        write_mock_artifact "$target" 2>/dev/null || true
    fi
    return "$exit_code"
}

ssh() {
    local -a ssh_args=()
    local ssh_arg
    for ssh_arg in "$@"; do
        ssh_args+=("$(_test_decode_remote_command "$ssh_arg")")
    done
    printf '%s\n' "${ssh_args[@]}" > "$RAW_SSH_ARGS_FILE"
    local exit_code
    exit_code=$(cat "$RAW_SSH_EXIT_CODE_FILE")
    if [[ "$exit_code" -eq 0 && -n "${MOCK_SSH_STREAM_FILE:-}" ]]; then
        cat "$MOCK_SSH_STREAM_FILE"
    fi
    return "$exit_code"
}

rsync() {
    printf '%s\n' "$@" > "$RSYNC_ARGS_FILE"
    local exit_code
    exit_code=$(cat "$RSYNC_EXIT_CODE_FILE")
    return "$exit_code"
}

# Mock yq for config parsing
# Handles: yq -r 'query' file OR yq 'query' file
yq() {
    local query

    # The strict workspace selector now validates the entire JSON config.
    # These command-construction fixtures are single-binary repositories.
    if [[ "${1:-}" == -o=json && "${2:-}" == -I=0 ]]; then
        case "${3:-}" in
            .) printf '{}\n'; return 0 ;;
            '.hosts[strenv(DSR_STORAGE_HOST)].windows_storage')
                printf 'null\n'; return 0 ;;
            '.workspace_archive_files[strenv(DSR_TARGET_PLATFORM)] // []'|\
            '.workspace_additional_artifacts[strenv(DSR_TARGET_PLATFORM)] // []')
                printf '[]\n'; return 0 ;;
        esac
    fi

    # Skip -r flag if present
    if [[ "$1" == "-r" ]]; then
        shift
    fi

    query="${1:-}"
    # $2 is the file path (unused in mock - we return based on query pattern)

    # Handle various config queries
    case "$query" in
        '.tool_name // ""')
            echo "${MOCK_TOOL_NAME:-tool}"
            ;;
        '.repo // ""')
            echo "${MOCK_REPO:-owner/tool}"
            ;;
        '.local_path // ""')
            echo "${MOCK_LOCAL_PATH:-/local/path/tool}"
            ;;
        '.language // ""')
            echo "${MOCK_LANGUAGE:-go}"
            ;;
        '.binary_name // ""')
            echo "${MOCK_BINARY_NAME:-tool}"
            ;;
        '.build_cmd // ""')
            echo "${MOCK_BUILD_CMD:-go build}"
            ;;
        *'.build_cmd // .build_cmd // ""')
            echo "${MOCK_BUILD_CMD:-go build}"
            ;;
        '.build_profile // "release"')
            echo "${MOCK_BUILD_PROFILE:-release}"
            ;;
        '.workflow // ".github/workflows/release.yml"')
            echo ".github/workflows/release.yml"
            ;;
        '.host_paths.'*' // ""')
            # Extract host name from query like .host_paths.mmini // ""
            local host_match
            host_match=$(echo "$query" | sed -n 's/.*\.host_paths\.\([a-zA-Z]*\).*/\1/p')
            case "$host_match" in
                mmini) echo "${MOCK_HOST_PATH_MMINI:-}" ;;
                wlap)  echo "${MOCK_HOST_PATH_WLAP:-}" ;;
                trj)   echo "${MOCK_HOST_PATH_TRJ:-}" ;;
                *)     echo "" ;;
            esac
            ;;
        '.env // {} | to_entries | map(.key + "=" + .value) | .[]')
            echo "${MOCK_GLOBAL_ENV:-}"
            ;;
        '.hosts.'*'.build_root // ""')
            echo "${MOCK_HOST_BUILD_ROOT:-}"
            ;;
        *'.cross_compile.'*'.env'*)
            echo "${MOCK_PLATFORM_ENV:-}"
            ;;
        '.sibling_crates // [] | length')
            if [[ -n "${MOCK_SIBLING_RELATIVE:-}" ]]; then echo 1; else echo 0; fi
            ;;
        '.sibling_crates[0].relative_path // ""')
            echo "${MOCK_SIBLING_RELATIVE:-}"
            ;;
        '.sibling_crates[0].local_path // ""')
            echo "${MOCK_SIBLING_LOCAL_PATH:-}"
            ;;
        *'.linux_glibc_floor'*)
            echo "${MOCK_GLIBC_FLOOR:-}"
            ;;
        '.derive_cargo_build_target // ""')
            echo "${MOCK_DERIVE_OPT:-}"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Reset test state
reset_state() {
    : > "$MOCK_DIR/staged-build.ps1"
    rm -f "$SSH_ARGS_FILE" "$SCP_ARGS_FILE" "$RAW_SSH_ARGS_FILE" "$RSYNC_ARGS_FILE"
    echo "0" > "$SSH_EXIT_CODE_FILE"
    echo "0" > "$SCP_EXIT_CODE_FILE"
    echo "0" > "$RAW_SSH_EXIT_CODE_FILE"
    echo "0" > "$RSYNC_EXIT_CODE_FILE"

    # Reset mock config values
    unset MOCK_TOOL_NAME MOCK_REPO MOCK_LOCAL_PATH MOCK_LANGUAGE
    unset MOCK_BINARY_NAME MOCK_BUILD_CMD MOCK_BUILD_PROFILE
    unset MOCK_HOST_PATH_MMINI MOCK_HOST_PATH_WLAP MOCK_HOST_PATH_TRJ
    unset MOCK_GLOBAL_ENV MOCK_PLATFORM_ENV
    unset MOCK_SSH_STREAM_FILE
    unset MOCK_SIBLING_RELATIVE MOCK_SIBLING_LOCAL_PATH
    unset MOCK_ARTIFACT_KIND MOCK_GLIBC_FLOOR MOCK_DERIVE_OPT

    # Defaults
    MOCK_LOCAL_PATH="/local/path/tool"
    MOCK_LANGUAGE="go"
    MOCK_BINARY_NAME="tool"
    MOCK_BUILD_CMD="go build"

    # Create mock config file
    touch "$ACT_REPOS_DIR/tool.yaml"
}

# Get captured SSH command
get_ssh_cmd() {
    if [[ -f "$SSH_ARGS_FILE" ]]; then
        grep "^CMD:" "$SSH_ARGS_FILE" | sed 's/^CMD://'
        cat "$MOCK_DIR/staged-build.ps1"
    else
        echo ""
    fi
}

# Full captured SSH exchange, including every line of multi-line commands
# (get_ssh_cmd keeps only lines that start with CMD:, which drops the tail of
# a command containing embedded newlines, e.g. the staged glibc-floor shim).
get_ssh_capture() {
    if [[ -f "$SSH_ARGS_FILE" ]]; then
        cat "$SSH_ARGS_FILE"
    else
        echo ""
    fi
}

# Get captured SSH host
get_ssh_host() {
    if [[ -f "$SSH_ARGS_FILE" ]]; then
        grep "^HOST:" "$SSH_ARGS_FILE" | sed 's/^HOST://'
    else
        echo ""
    fi
}

# Get captured SCP args as a single line
get_scp_args() {
    if [[ -f "$SCP_ARGS_FILE" ]]; then
        tr '\n' ' ' < "$SCP_ARGS_FILE"
    else
        echo ""
    fi
}

get_raw_ssh_args() {
    if [[ -f "$RAW_SSH_ARGS_FILE" ]]; then
        tr '\n' ' ' < "$RAW_SSH_ARGS_FILE"
    else
        echo ""
    fi
}

get_rsync_args() {
    if [[ -f "$RSYNC_ARGS_FILE" ]]; then
        tr '\n' ' ' < "$RSYNC_ARGS_FILE"
    else
        echo ""
    fi
}

# ============================================================================
# Test Cases: Unix Command Construction
# ============================================================================

test_unix_cd_command() {
    log_test "Unix: cd command uses single quotes"
    reset_state
    MOCK_LOCAL_PATH="/local/path/tool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *"cd '/local/path/tool'"* ]]; then
        log_pass "cd uses single quotes: cd '/local/path/tool'"
    else
        log_fail "Expected cd '/local/path/tool' but got: $cmd"
    fi
}

test_unix_env_export_syntax() {
    log_test "Unix: env vars use export syntax"
    reset_state
    MOCK_GLOBAL_ENV="CARGO_TERM_COLOR=always"
    MOCK_PLATFORM_ENV="RUST_BACKTRACE=1"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *'export "CARGO_TERM_COLOR=always"'* ]] || [[ "$cmd" == *"export CARGO_TERM_COLOR=always"* ]]; then
        log_pass "Uses export for env vars"
    else
        log_fail "Expected export syntax for CARGO_TERM_COLOR in: $cmd"
    fi
}

test_unix_rust_unsets_ambient_cargo_path_env() {
    log_test "Unix Rust: ambient Cargo path env is cleared unless configured"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BUILD_CMD="cargo build --release"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *"unset CARGO_TARGET_DIR; unset CARGO_BUILD_TARGET;"* && \
          "$cmd" == *"export RCH_DISABLED=1; export RCH_CARGO_WRAPPER_BYPASS=1;"* && \
          "$cmd" == *"cargo build --release"* ]]; then
        log_pass "Unsets ambient Cargo paths and keeps native Rust compilation local"
    else
        log_fail "Expected Cargo path env unsets in: $cmd"
    fi
}

test_unix_rust_isolation_guards_ram_backed_root() {
    log_test "Unix Rust: staging creates the isolation root and refuses tmpfs/ramfs"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BUILD_CMD="cargo build --release"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *"mkdir -p '/private/tmp'; _dsr_fstype=\$( (findmnt -no FSTYPE -T '/private/tmp'"* && \
          "$cmd" == *"tmpfs|ramfs) echo \"[dsr] refusing to stage the build under RAM-backed /private/tmp"* && \
          "$cmd" == *"mkdir '/private/tmp/dsr-build-tool-darwin-arm64-"* ]]; then
        log_pass "Isolation root is created and guarded against RAM-backed filesystems"
    else
        log_fail "Expected isolation root mkdir + RAM-backed guard in: $cmd"
    fi
}

test_unix_rust_isolation_honors_host_build_root() {
    log_test "Unix Rust: hosts.yaml build_root replaces the default isolation root"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BUILD_CMD="cargo build --release"
    MOCK_HOST_BUILD_ROOT="/srv/dsr-builds"
    export DSR_HOSTS_FILE="$MOCK_DIR/hosts.yaml"
    touch "$DSR_HOSTS_FILE"

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null)

    local cmd
    cmd=$(get_ssh_cmd)
    unset DSR_HOSTS_FILE MOCK_HOST_BUILD_ROOT

    if [[ "$cmd" == *"mkdir -p '/srv/dsr-builds'; _dsr_fstype="* && \
          "$cmd" == *"mkdir '/srv/dsr-builds/dsr-build-tool-darwin-arm64-"* && \
          "$cmd" != *"/private/tmp/dsr-build-"* ]] && \
       jq -e '.cargo_isolation.source_root | startswith("/srv/dsr-builds/dsr-build-tool-darwin-arm64-")' \
          <<< "$result" >/dev/null; then
        log_pass "hosts.yaml build_root is used for the Rust isolation root"
    else
        log_fail "Expected /srv/dsr-builds isolation root in: $cmd result=$result"
    fi
}

test_unix_rust_isolation_rejects_invalid_host_build_root() {
    log_test "Unix Rust: an unsafe hosts.yaml build_root fails closed"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BUILD_CMD="cargo build --release"
    MOCK_HOST_BUILD_ROOT="/srv/../etc"
    export DSR_HOSTS_FILE="$MOCK_DIR/hosts.yaml"
    touch "$DSR_HOSTS_FILE"

    local result status=0
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || status=$?
    local cmd
    cmd=$(get_ssh_cmd)
    unset DSR_HOSTS_FILE MOCK_HOST_BUILD_ROOT

    if [[ $status -eq 4 && -z "$cmd" ]] && \
       jq -e '.status == "error" and .error == "Invalid hosts.yaml build_root"' <<< "$result" >/dev/null; then
        log_pass "Invalid build_root aborts before any remote command runs"
    else
        log_fail "Expected exit 4 and no remote command for invalid build_root: status=$status cmd=$cmd result=$result"
    fi
}

test_unix_rust_keeps_configured_cargo_path_env() {
    log_test "Unix Rust: configured absolute target is restored after sanitization"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BUILD_CMD="cargo build --release"
    MOCK_PLATFORM_ENV=$'CARGO_TARGET_DIR=/Users/jemanuel/tmp/rch-target-dsr\nCARGO_HOME=/Users/jemanuel/.cargo-operator'

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null)

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *"unset CARGO_HOME; unset CARGO_TARGET_DIR;"* ]] && \
       [[ "$cmd" == *'export "CARGO_TARGET_DIR=/Users/jemanuel/tmp/rch-target-dsr"'* ]] && \
       [[ "$cmd" == *'export "CARGO_HOME=/private/tmp/dsr-build-tool-darwin-arm64-'* ]] && \
       [[ "$cmd" != *'/Users/jemanuel/.cargo-operator'* ]] && \
       jq -e \
          '.cargo_isolation.target_dir == "/Users/jemanuel/tmp/rch-target-dsr" and
           .cargo_isolation.cargo_home == .build_influence_env.CARGO_HOME and
           (.cargo_isolation.source_root | startswith("/private/tmp/dsr-build-tool-darwin-arm64-"))' \
          <<< "$result" >/dev/null; then
        log_pass "Configured target survives while operator CARGO_HOME is replaced"
    else
        log_fail "Expected sanitize-then-restore Cargo isolation command: $cmd result=$result"
    fi
}

test_unix_rust_isolation_executes_outside_operator_config() {
    log_test "Unix Rust: real Cargo invocation excludes every operator config category"
    reset_state

    local source_root="$MOCK_DIR/remote-rust-source"
    local sibling_root="$MOCK_DIR/operator-dep"
    local operator_home="$MOCK_DIR/operator-home"
    local probe_output="$MOCK_DIR/isolation-probe.txt"
    local expected_target="$MOCK_DIR/.dsr-cargo-target-tool-linux-amd64"
    mkdir -p "$source_root/src" "$sibling_root/src" "$operator_home/.cargo"
    printf '[package]\nname = "isolation_probe"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\noperator_dep = { path = "../operator-dep" }\n' \
        > "$source_root/Cargo.toml"
    printf 'pub fn probe() -> bool { operator_dep::probe() }\n' > "$source_root/src/lib.rs"
    printf '[package]\nname = "operator_dep"\nversion = "0.1.0"\nedition = "2021"\n' \
        > "$sibling_root/Cargo.toml"
    printf 'pub fn probe() -> bool { true }\n' > "$sibling_root/src/lib.rs"
    git -C "$source_root" init -q
    git -C "$source_root" config user.name "DSR Test"
    git -C "$source_root" config user.email "dsr-test@example.invalid"
    git -C "$source_root" add Cargo.toml src/lib.rs
    git -C "$source_root" commit -qm "initial fixture"
    printf '%s\n' \
        '[alias]' \
        'operator-alias = "metadata --format-version 1 --no-deps"' \
        '[build]' \
        'rustc-wrapper = "/definitely/not/a/rustc-wrapper"' \
        'target-dir = "/definitely/operator-target"' \
        '[target.x86_64-unknown-linux-gnu]' \
        'linker = "/definitely/not/a/linker"' \
        '[source.crates-io]' \
        'replace-with = "operator-source"' \
        '[source.operator-source]' \
        'registry = "sparse+https://example.invalid/index/"' \
        '[patch.crates-io]' \
        'serde = { path = "/definitely/not/a/serde-checkout" }' \
        > "$operator_home/.cargo/config.toml"
    mkdir -p "$operator_home/.cargo/git/checkouts/shared-mutable-checkout"

    MOCK_LOCAL_PATH="$source_root"
    MOCK_LANGUAGE="rust"
    MOCK_ARTIFACT_KIND="elf-amd64"
    MOCK_SIBLING_RELATIVE="operator-dep"
    MOCK_SIBLING_LOCAL_PATH="$sibling_root"
    # This checks Cargo configuration isolation on the executing host. The
    # separately synthetic ELF collection fixture does not require installing
    # a Linux standard library on a Mac merely to check a two-function library.
    MOCK_BUILD_CMD='git diff-index --quiet HEAD -- && cargo check --offline --quiet --target "$(rustc -vV | sed -n "s/^host: //p")" && if cargo operator-alias >/dev/null 2>&1; then exit 91; fi && printf "%s\n%s\n" "$PWD" "$CARGO_HOME" > "$DSR_PROBE_OUTPUT" && mkdir -p "$CARGO_TARGET_DIR/$CARGO_BUILD_TARGET/release" && { printf "\177ELF\002\001"; head -c 12 /dev/zero; printf "\076\000"; head -c 44 /dev/zero; } > "$CARGO_TARGET_DIR/$CARGO_BUILD_TARGET/release/tool" && chmod 755 "$CARGO_TARGET_DIR/$CARGO_BUILD_TARGET/release/tool"'
    MOCK_PLATFORM_ENV="CARGO_HOME=$operator_home/.cargo
CARGO_TARGET_DIR=relative-operator-target
DSR_PROBE_OUTPUT=$probe_output"

    local result status=0
    result=$(
        _act_ssh_exec() { bash -c "$2"; }
        CARGO_HOME="$operator_home/.cargo" \
        RUSTC_WRAPPER="/definitely/ambient-wrapper" \
            act_run_native_build "tool" "linux/amd64" "v1.0.0" "isolation-run"
    ) 2>/dev/null || status=$?

    local observed_source="" observed_home=""
    if [[ -f "$probe_output" ]]; then
        observed_source=$(sed -n '1p' "$probe_output")
        observed_home=$(sed -n '2p' "$probe_output")
    fi
    if [[ $status -eq 0 && -n "$observed_source" && -n "$observed_home" ]] && \
       jq -e \
          --arg original "$source_root" \
          --arg source "$observed_source" \
          --arg home "$observed_home" \
          --arg target "$expected_target" \
          --arg sibling "${observed_source%/source}/operator-dep" '
            .status == "success" and
            .cargo_isolation.original_source_root == $original and
            .cargo_isolation.source_root == $source and
            .cargo_isolation.cargo_home == $home and
            .cargo_isolation.target_dir == $target and
            .cargo_isolation.sibling_roots == [{
              relative_path: "operator-dep",
              original_source_root: ($original | sub("/remote-rust-source$"; "/operator-dep")),
              source_root: $sibling
            }] and
            .build_influence_env.CARGO_HOME == $home and
            .build_influence_env.CARGO_TARGET_DIR == $target and
            (.cargo_isolation.excluded_cargo_home_entries | sort) ==
              (["config", "config.toml", "credentials", "credentials.toml"] | sort)' \
          <<< "$result" >/dev/null && \
       [[ "$observed_source" == /var/tmp/dsr-build-tool-linux-amd64-*/source ]] && \
       [[ "$observed_source" != "$source_root" ]] && \
       [[ "$observed_home" != "$operator_home/.cargo" ]] && \
       [[ ! -e "$observed_home/git" ]] && \
       [[ ! -e "$observed_home/config.toml" ]]; then
        log_pass "Cargo ran with isolated mutable Git state and a config-free home"
    else
        log_fail "Operator Cargo config leaked or isolation receipt disagreed: status=$status result=$result"
    fi
}

test_windows_rust_isolation_receipt_matches_command() {
    log_test "Windows Rust: receipt paths exactly match the sanitized process command"
    reset_state
    MOCK_LOCAL_PATH="C:/Users/jeffr/projects/tool"
    MOCK_LANGUAGE="rust"
    MOCK_BUILD_CMD="cargo build --release --locked"
    MOCK_PLATFORM_ENV=$'CARGO_HOME=C:/Users/jeffr/.cargo-operator\nCARGO_TARGET_DIR=relative-target'

    local result cmd source home target
    result=$(act_run_native_build "tool" "windows/amd64" "v1.0.0" "windows-isolation" 2>/dev/null)
    cmd=$(get_ssh_cmd)
    source=$(jq -r '.cargo_isolation.source_root' <<< "$result")
    home=$(jq -r '.cargo_isolation.cargo_home' <<< "$result")
    target=$(jq -r '.cargo_isolation.target_dir' <<< "$result")

    local win_source="${source//\//\\}"
    local win_home="${home//\//\\}"
    if jq -e \
         '.status == "success" and
          (.cargo_isolation.stage_root | startswith("C:/d/dsr-build-")) and
          .cargo_isolation.cargo_home == .build_influence_env.CARGO_HOME and
          .cargo_isolation.target_dir == .build_influence_env.CARGO_TARGET_DIR' \
         <<< "$result" >/dev/null && \
       [[ "$target" == "C:/Users/jeffr/projects/.dsr-cargo-target-tool-windows-amd64" ]] && \
       [[ "$cmd" == *"WorkingDirectory='$win_source'"* ]] && \
       [[ "$cmd" == *"EnvironmentVariables['CARGO_HOME']='$win_home'"* ]] && \
       [[ "$cmd" != *'C:\Users\jeffr\.cargo-operator'* ]]; then
        log_pass "Windows process and receipt share one unique public isolation root"
    else
        log_fail "Windows command diverged from its isolation receipt: cmd=$cmd result=$result"
    fi
}

test_frankenterm_profile_override_rejection() {
    log_test "Strict FrankenTerm: merged profile overrides fail before identity or compilation"
    local platform placement case_dir remote_root bound_host result status key
    local MOCK_LANGUAGE=rust MOCK_BUILD_CMD=PROFILE_BUILD_MUST_NOT_RUN
    local MOCK_BUILD_PROFILE=release-interactive MOCK_TOOL_NAME=frankenterm
    local MOCK_LOCAL_PATH=/local/path/frankenterm MOCK_BINARY_NAME=tool
    local MOCK_GLOBAL_ENV MOCK_PLATFORM_ENV
    local SSH_ARGS_FILE SCP_ARGS_FILE RAW_SSH_ARGS_FILE RSYNC_ARGS_FILE
    touch "$ACT_REPOS_DIR/frankenterm.yaml"

    for platform in darwin/arm64 linux/amd64 linux/arm64 windows/amd64; do
        case "$platform" in
            windows/*) remote_root=C:/build/.dsr-release-snapshots/profile/source; bound_host=wlap ;;
            darwin/*) remote_root=/remote/.dsr-release-snapshots/profile/source; bound_host=mmini ;;
            *) remote_root=/remote/.dsr-release-snapshots/profile/source; bound_host=trj ;;
        esac
        for placement in global target clean; do
            case_dir="$MOCK_DIR/profile-${platform//\//-}-$placement"
            mkdir -p "$case_dir"
            SSH_ARGS_FILE="$case_dir/ssh"
            SCP_ARGS_FILE="$case_dir/scp"
            RAW_SSH_ARGS_FILE="$case_dir/raw-ssh"
            RSYNC_ARGS_FILE="$case_dir/rsync"
            : > "$MOCK_DIR/staged-build.ps1"
            MOCK_GLOBAL_ENV=""
            MOCK_PLATFORM_ENV=$'CARGO_PROFILE=allowed-near-prefix\nCARGO_PROFILES_RELEASE_OPT_LEVEL=allowed-near-prefix\nCARGO_BUILD_JOBS=2'
            if [[ "$placement" == global ]]; then
                key=CARGO_PROFILE_RELEASE_INTERACTIVE_OPT_LEVEL
                MOCK_GLOBAL_ENV="$key=private-profile-value"
            elif [[ "$placement" == target ]]; then
                key=cArGo_PrOfIlE_ReLeAsE_PaNiC
                MOCK_PLATFORM_ENV+=$'\n'"$key="
            fi
            status=0
            result=$(
                host_health_is_ready() { return 0; }
                _log_error() { printf '%s\n' "$*" >&2; }
                _act_frankenterm_build_identity() {
                    printf 'identity reached\n' > "$case_dir/identity-reached"
                    return 73
                }
                # Ambient inputs are removed by the existing host launcher;
                # they must not be mistaken for explicitly configured inputs.
                export CARGO_PROFILE_RELEASE_OPT_LEVEL=ambient-profile-value
                act_run_native_build frankenterm "$platform" v1.0.0 22222222-2222-4222-8222-222222222222 \
                    "$remote_root" 1111111111111111111111111111111111111111 v1.0.0 "$bound_host" \
                    2> "$case_dir/stderr"
            ) || status=$?
            if [[ "$placement" == clean ]]; then
                if [[ "$status" -eq 4 && -s "$case_dir/identity-reached" ]]; then
                    log_pass "$platform source profile reaches identity despite unrelated or ambient inputs"
                else
                    log_fail "$platform source profile did not reach identity: status=$status result=$result"
                fi
            elif [[ "$status" -eq 4 && ! -e "$case_dir/identity-reached" ]] && \
                 jq -e --arg key "$key" \
                    '.status == "error" and .exit_code == 4 and
                     (.error | contains($key)) and
                     (.error | contains("change committed Cargo.toml")) and
                     (.error | contains("private-profile-value") | not)' <<< "$result" >/dev/null && \
                 grep -F "$key" "$case_dir/stderr" >/dev/null && \
                 grep -F 'change committed Cargo.toml' "$case_dir/stderr" >/dev/null && \
                 ! grep -F 'private-profile-value' "$case_dir/stderr" >/dev/null && \
                 ! grep -F 'PROFILE_BUILD_MUST_NOT_RUN' "$SSH_ARGS_FILE" >/dev/null 2>&1; then
                log_pass "$platform $placement override rejected before identity/build without its value"
            else
                log_fail "$platform $placement profile override escaped rejection: status=$status result=$result"
            fi
        done
    done
}

test_profile_overrides_preserve_ordinary_and_other_tools() {
    log_test "Ordinary FrankenTerm and strict other tools retain configured profile overrides"
    local platform mode tool_name case_dir result status command remote_root run_id encoded_key
    local MOCK_LANGUAGE=rust MOCK_BUILD_CMD=env MOCK_BUILD_PROFILE=release-interactive
    local MOCK_BINARY_NAME=tool MOCK_LOCAL_PATH=/local/path/tool
    local MOCK_GLOBAL_ENV=CARGO_PROFILE_RELEASE_INTERACTIVE_OPT_LEVEL=3
    local MOCK_PLATFORM_ENV="" MOCK_SSH_STREAM_FILE
    local SSH_ARGS_FILE SCP_ARGS_FILE RAW_SSH_ARGS_FILE RSYNC_ARGS_FILE
    touch "$ACT_REPOS_DIR/tool.yaml" "$ACT_REPOS_DIR/frankenterm.yaml"
    for platform in darwin/arm64 windows/amd64; do
        for mode in ordinary-frankenterm strict-other-tool; do
            case_dir="$MOCK_DIR/profile-preserved-${platform//\//-}-$mode"
            mkdir -p "$case_dir"
            SSH_ARGS_FILE="$case_dir/ssh"
            SCP_ARGS_FILE="$case_dir/scp"
            RAW_SSH_ARGS_FILE="$case_dir/raw-ssh"
            RSYNC_ARGS_FILE="$case_dir/rsync"
            : > "$MOCK_DIR/staged-build.ps1"
            MOCK_SSH_STREAM_FILE="$case_dir/artifact"
            if [[ "$platform" == windows/* ]]; then
                MOCK_LOCAL_PATH=C:/build/tool
                remote_root=C:/build/.dsr-release-snapshots/profile/source
                MOCK_ARTIFACT_KIND=pe-amd64 write_mock_artifact "$MOCK_SSH_STREAM_FILE"
            else
                MOCK_LOCAL_PATH=/local/path/tool
                remote_root=/remote/.dsr-release-snapshots/profile/source
                MOCK_ARTIFACT_KIND=macho-arm64 write_mock_artifact "$MOCK_SSH_STREAM_FILE"
            fi
            status=0
            if [[ "$mode" == ordinary-frankenterm ]]; then
                tool_name=frankenterm
                run_id=33333333-3333-4333-8333-333333333333
                result=$(act_run_native_build "$tool_name" "$platform" v1.0.0 "$run_id" 2>/dev/null) || status=$?
            else
                tool_name=tool
                run_id=44444444-4444-4444-8444-444444444444
                result=$(act_run_native_build "$tool_name" "$platform" v1.0.0 "$run_id" "$remote_root" 2>/dev/null) || status=$?
            fi
            command=$(get_ssh_cmd)
            encoded_key=$(printf '%s' CARGO_PROFILE_RELEASE_INTERACTIVE_OPT_LEVEL | base64 | tr -d '\r\n')
            if [[ "$status" -eq 0 && ( "$command" == *CARGO_PROFILE_RELEASE_INTERACTIVE_OPT_LEVEL* || \
                  "$command" == *"$encoded_key"* ) ]] && \
               jq -e '.status == "success" and
                  .build_influence_env.CARGO_PROFILE_RELEASE_INTERACTIVE_OPT_LEVEL == "3"' \
                  <<< "$result" >/dev/null; then
                log_pass "$platform $mode preserves the configured profile and its receipt"
            else
                log_fail "$platform $mode changed ordinary profile behavior: status=$status result=$result"
            fi
        done
    done
}

test_rust_build_influence_name_xwin_boundaries() {
    log_test "Rust build influence names: XWIN matching is case-insensitive and bounded"

    local name expected actual
    local failures=""
    while IFS='|' read -r name expected; do
        if _act_is_rust_build_influence_name "$name"; then
            actual="match"
        else
            actual="miss"
        fi
        if [[ "$actual" != "$expected" ]]; then
            failures+=" $name:$actual"
        fi
    done <<'CASES'
XWIN_FUTURE_TOOLCHAIN_SWITCH|match
xwin_cache_dir|match
XwIn_MsVc_SySrOoT_Download_Url|match
DSR_RELEASE_GIT_SHA|match
dsr_release_git_ref|match
FT_ATOMIC_BUILD_IDENTITY|match
ft_atomic_build_profile|match
FT_ATOMIC_BUILD_IDENTITY_EXTRA|miss
NOT_FT_ATOMIC_BUILD_PROFILE|miss
XWIN|miss
XWINNER_CACHE_DIR|miss
NOT_XWIN_CACHE_DIR|miss
XWIN-CACHE-DIR|miss
DSR_RELEASE_GIT_SHA_EXTRA|miss
OPENSSL_DIR|match
openssl_static|match
X86_64_PC_WINDOWS_MSVC_OPENSSL_DIR|match
aarch64_unknown_linux_gnu_OPENSSL_NO_VENDOR|match
PKG_CONFIG|match
PKG_CONFIG_PATH_aarch64-unknown-linux-gnu|match
PKG_CONFIG_LIBDIR_aarch64_unknown_linux_gnu|match
HOST_PKG_CONFIG|match
TARGET_PKG_CONFIG_SYSROOT_DIR|match
FONTCONFIG_NO_PKG_CONFIG|match
LIBCLANG_PATH|match
libclang_path|match
OPENSSL|miss
OPENSSLX_DIR|miss
NOTPKG_CONFIG|miss
HOST_PKG_CONFIGURED|miss
LIBCLANG_PATH_EXTRA|miss
NOT_LIBCLANG_PATH|miss
CASES

    if [[ -z "$failures" ]]; then
        log_pass "XWIN build influence matching accepts case variants without prefix near-misses"
    else
        log_fail "Unexpected XWIN influence classifications:$failures"
    fi
}

test_unix_rust_sdk_environment() {
    log_test "Unix strict and ordinary Rust: configured SDK selectors replace ambient values"
    local mode result cmd launch observed status
    for mode in strict ordinary; do
        reset_state
        MOCK_LANGUAGE=rust
        MOCK_PLATFORM_ENV=$'OPENSSL_DIR=/configured/openssl with spaces\nOPENSSL_STATIC=1\nPKG_CONFIG=/configured/pkg-config\nPKG_CONFIG_LIBDIR_aarch64_unknown_linux_gnu=/configured/pkgconfig\nLIBCLANG_PATH=/configured/libclang'
        MOCK_BUILD_CMD="env"
        MOCK_SSH_STREAM_FILE="$MOCK_DIR/sdk-unix-$mode-artifact"
        write_mock_artifact "$MOCK_SSH_STREAM_FILE"
        status=0
        if [[ "$mode" == strict ]]; then
            result=$(act_run_native_build tool darwin/arm64 v1.0.0 sdk-unix \
                /remote/.dsr-release-snapshots/sdk/source 2>/dev/null) || status=$?
        else
            result=$(act_run_native_build tool darwin/arm64 v1.0.0 sdk-unix 2>/dev/null) || status=$?
        fi
        cmd=$(get_ssh_cmd)
        if [[ "$status" -ne 0 || "$cmd" != *'for sdk_variable in '* ]]; then
            log_fail "$mode Unix SDK command construction failed: status=$status result=$result"
            continue
        fi
        # Execute the actual generated environment portion without staging a
        # source tree or running a compiler. The configured build command is env.
        launch="for sdk_variable in ${cmd#*for sdk_variable in }"
        observed=$(OPENSSL_DIR=/ambient/openssl OPENSSL_NO_VENDOR=1 \
            X86_64_PC_WINDOWS_MSVC_OPENSSL_DIR=/ambient/target-openssl \
            PKG_CONFIG=/ambient/pkg-config TARGET_PKG_CONFIG_PATH=/ambient/target-pc \
            HOST_PKG_CONFIG=/ambient/host-pc FONTCONFIG_NO_PKG_CONFIG=1 \
            LIBCLANG_PATH=/ambient/libclang LIBCLANG_PATH_EXTRA=preserve \
            "$BASH" -c "set -e; $launch") || status=$?
        if [[ "$status" -eq 0 ]] && printf '%s\n' "$observed" | \
            grep -Fx 'OPENSSL_DIR=/configured/openssl with spaces' >/dev/null && \
           printf '%s\n' "$observed" | grep -Fx 'LIBCLANG_PATH_EXTRA=preserve' >/dev/null && \
           ! printf '%s\n' "$observed" | grep -E '^(OPENSSL_NO_VENDOR|X86_64_PC_WINDOWS_MSVC_OPENSSL_DIR|TARGET_PKG_CONFIG_PATH|HOST_PKG_CONFIG|FONTCONFIG_NO_PKG_CONFIG)=' >/dev/null && \
           jq -e '.status == "success" and
             .build_influence_env.OPENSSL_DIR == "/configured/openssl with spaces" and
             .build_influence_env.OPENSSL_STATIC == "1" and
             .build_influence_env.PKG_CONFIG == "/configured/pkg-config" and
             .build_influence_env.PKG_CONFIG_LIBDIR_aarch64_unknown_linux_gnu == "/configured/pkgconfig" and
             .build_influence_env.LIBCLANG_PATH == "/configured/libclang" and
             (.build_influence_env | has("OPENSSL_NO_VENDOR") | not)' <<< "$result" >/dev/null; then
            log_pass "$mode Unix generated SDK cleanup removes inherited selectors and records configured values"
        else
            log_fail "$mode Unix SDK environment/receipt mismatch: status=$status result=$result"
        fi
        status=0
        observed=$(env 'PKG_CONFIG_PATH_aarch64-unknown-linux-gnu=/ambient/target-pc' \
            "$BASH" -c "set -e; $launch" 2>&1) || status=$?
        if [[ "$status" -eq 4 && "$observed" == *'SDK environment name cannot be isolated by this shell: PKG_CONFIG_PATH_aarch64-unknown-linux-gnu'* ]]; then
            log_pass "$mode Unix refuses inherited SDK names that shell unset silently preserves"
        else
            log_fail "$mode Unix leaked an unsupported target SDK selector: status=$status"
        fi
    done
}

test_windows_rust_sdk_environment() {
    log_test "Windows strict and ordinary Rust: SDK cleanup, last assignment, and receipt agree"
    local mode result cmd status script observed env_section first_prefix last_prefix
    local first_b64 last_b64
    first_b64=$(printf '%s' 'C:/configured/first' | base64 | tr -d '\r\n')
    last_b64=$(printf '%s' 'C:/configured/last with spaces' | base64 | tr -d '\r\n')
    for mode in strict ordinary; do
        reset_state
        MOCK_LANGUAGE=rust
        MOCK_BUILD_CMD='echo fixture-only'
        MOCK_LOCAL_PATH='C:/Users/dsr/projects/tool'
        MOCK_PLATFORM_ENV=$'OpenSSL_DIR=C:/configured/first\nopenssl_dir=C:/configured/last with spaces\nOPENSSL_STATIC=1\nX86_64_PC_WINDOWS_MSVC_OPENSSL_DIR=C:/configured/target\nPKG_CONFIG=C:/configured/pkg-config\nPKG_CONFIG_LIBDIR_aarch64_unknown_linux_gnu=C:/configured/pkgconfig\nLIBCLANG_PATH=C:/configured/libclang'
        MOCK_SSH_STREAM_FILE="$MOCK_DIR/sdk-windows-$mode-artifact"
        MOCK_ARTIFACT_KIND=pe-amd64 write_mock_artifact "$MOCK_SSH_STREAM_FILE"
        status=0
        if [[ "$mode" == strict ]]; then
            result=$(act_run_native_build tool windows/amd64 v1.0.0 \
                12345678-1234-4234-8234-123456789abc \
                C:/build/.dsr-release-snapshots/sdk/source 2>/dev/null) || status=$?
        else
            result=$(act_run_native_build tool windows/amd64 v1.0.0 sdk-windows 2>/dev/null) || status=$?
        fi
        cmd=$(get_ssh_cmd)
        first_prefix="${cmd%%"$first_b64"*}"
        last_prefix="${cmd%%"$last_b64"*}"
        if [[ "$status" -ne 0 || "$cmd" != *"$first_b64"* || "$cmd" != *"$last_b64"* || \
              ${#first_prefix} -ge ${#last_prefix} ]] || \
           ! jq -e '.status == "success" and
             .build_influence_env.OPENSSL_DIR == "C:/configured/last with spaces" and
             ([.build_influence_env | keys[] | select(ascii_upcase == "OPENSSL_DIR")] | length) == 1 and
             .build_influence_env.OPENSSL_STATIC == "1" and
             .build_influence_env.X86_64_PC_WINDOWS_MSVC_OPENSSL_DIR == "C:/configured/target" and
             .build_influence_env.PKG_CONFIG == "C:/configured/pkg-config" and
             .build_influence_env.PKG_CONFIG_LIBDIR_AARCH64_UNKNOWN_LINUX_GNU == "C:/configured/pkgconfig" and
             .build_influence_env.LIBCLANG_PATH == "C:/configured/libclang"' <<< "$result" >/dev/null; then
            log_fail "$mode Windows SDK command/receipt mismatch: status=$status result=$result"
            continue
        fi
        log_pass "$mode Windows SDK receipt preserves configured values and case-insensitive last assignment"
        if ! command -v pwsh >/dev/null 2>&1; then
            printf 'SKIP %s Windows SDK runtime control: pwsh is not installed\n' "$mode"
            continue
        fi
        # Run only the generated environment mutations. StringDictionary has
        # Windows' case-insensitive environment semantics even on a POSIX test
        # host; this is a PowerShell control, not a native Windows build proof.
        env_section="${cmd#*\$psi.UseShellExecute=\$false; }"
        env_section="${env_section%%\$psi.FileName=*}"
        if [[ "$mode" == strict ]]; then
            # The staged job guard stores the script in a single-quoted
            # PowerShell string. All configured values here are base64.
            env_section="${env_section//\'\'/\'}"
        fi
        if [[ "$env_section" == "$cmd" || "$env_section" != *"$(_act_rust_sdk_influence_regex)"* ]]; then
            log_fail "$mode Windows generated environment section is missing"
            continue
        fi
        script="$MOCK_DIR/sdk-windows-$mode.ps1"
        cat > "$script" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$sdkEnvironment = New-Object System.Collections.Specialized.StringDictionary
foreach ($sdkName in @('OPENSSL_DIR', 'OPENSSL_NO_VENDOR', 'X86_64_PC_WINDOWS_MSVC_OPENSSL_DIR', 'PKG_CONFIG', 'PKG_CONFIG_PATH_aarch64-unknown-linux-gnu', 'HOST_PKG_CONFIG', 'TARGET_PKG_CONFIG_PATH', 'FONTCONFIG_NO_PKG_CONFIG', 'LIBCLANG_PATH')) {
    $sdkEnvironment[$sdkName] = 'ambient-value'
}
$sdkEnvironment['LIBCLANG_PATH_EXTRA'] = 'preserve'
$psi = [pscustomobject]@{ EnvironmentVariables = $sdkEnvironment }
POWERSHELL
        printf '%s\n' "$env_section" >> "$script"
        cat >> "$script" <<'POWERSHELL'
$sdkObserved = @{}
foreach ($sdkName in $psi.EnvironmentVariables.Keys) {
    $sdkObserved[$sdkName.ToUpperInvariant()] = $psi.EnvironmentVariables[$sdkName]
}
$sdkObserved | ConvertTo-Json -Compress
POWERSHELL
        observed=$(pwsh -NoProfile -NonInteractive -File "$script") || status=$?
        if [[ "$status" -eq 0 ]] && jq -e '
            .OPENSSL_DIR == "C:/configured/last with spaces" and .OPENSSL_STATIC == "1" and
            .X86_64_PC_WINDOWS_MSVC_OPENSSL_DIR == "C:/configured/target" and
            .PKG_CONFIG == "C:/configured/pkg-config" and
            .PKG_CONFIG_LIBDIR_AARCH64_UNKNOWN_LINUX_GNU == "C:/configured/pkgconfig" and
            .LIBCLANG_PATH == "C:/configured/libclang" and .LIBCLANG_PATH_EXTRA == "preserve" and
            (has("OPENSSL_NO_VENDOR") | not) and
            (has("PKG_CONFIG_PATH_AARCH64-UNKNOWN-LINUX-GNU") | not) and
            (has("HOST_PKG_CONFIG") | not) and (has("TARGET_PKG_CONFIG_PATH") | not) and
            (has("FONTCONFIG_NO_PKG_CONFIG") | not)' <<< "$observed" >/dev/null; then
            log_pass "$mode Windows generated PowerShell removes ambient SDK selectors before configured assignments"
        else
            log_fail "$mode Windows generated SDK cleanup failed: status=$status observed=$observed"
        fi
    done
}

test_frankenterm_windows_archive_manifest() {
    log_test "Windows family ZIP: exact manifest bytes and hostile namespace rejection"
    local fixture="$MOCK_DIR/windows-family-zip"
    mkdir "$fixture" || { log_fail "Cannot create Windows ZIP fixtures"; return; }
    python3 - "$fixture" <<'PY'
import hashlib, json, pathlib, stat, sys, zipfile
root = pathlib.Path(sys.argv[1])
components = {"ft.exe":"ft", "frankenterm-gui.exe":"frankenterm-gui",
    "frankenterm-mux-server.exe":"frankenterm-mux-server",
    "frankenterm-pty-guardian.exe":"frankenterm-pty-guardian"}
files = {name: ("synthetic ZIP-parser fixture: " + name).encode() for name in components}
files["verify-components.sh"] = b"synthetic verifier fixture"
manifest_name = "ft-windows-amd64.component-manifest.json"
records = []
for name, data in files.items():
    record = dict(path=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                  executable=name.endswith(".sh"), kind="executable" if name in components else "verifier")
    if name in components:
        record["component"] = components[name]
    records.append(record)
manifest = dict(schema_version="ft.atomic_component_manifest.v1", identity=dict(
    build_id="a"*64, source_revision="b"*40, version="1.2.3",
    target="x86_64-pc-windows-msvc", profile="release-interactive",
    feature_contract="application-family-gui-ft-mux-server-pty-guardian-default-features-v1"),
    inventory=dict(mode="exact", file_count=5), files=records)
def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
manifest["manifest_id"] = "sha256:" + hashlib.sha256(encoded(manifest)).hexdigest()
files[manifest_name] = encoded(manifest)
for case in ("valid", "bytes", "manifest", "duplicate", "case", "traversal", "missing", "symlink"):
    entries = list(files.items())
    if case == "bytes": entries[0] = (entries[0][0], b"changed executable")
    if case == "manifest": entries[-1] = (manifest_name, files[manifest_name].replace(b'"1.2.3"', b'"9.9.9"'))
    if case == "duplicate": entries[-1] = entries[0]
    if case == "case": entries[0] = ("FT.exe", entries[0][1])
    if case == "traversal": entries[0] = ("../ft.exe", entries[0][1])
    if case == "missing": entries.pop(1)
    with zipfile.ZipFile(root / (case + ".zip"), "x") as archive:
        for name, data in entries:
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            mode = stat.S_IFREG | (0o700 if name.endswith(".sh") else 0o600)
            if case == "symlink" and name == "ft.exe": mode = stat.S_IFLNK | 0o777
            info.external_attr = mode << 16
            archive.writestr(info, data)
PY
    if [[ $? -ne 0 ]]; then log_fail "Windows ZIP fixture generation failed"; return; fi
    local revision=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    local identity=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    local case
    if _act_validate_frankenterm_windows_archive "$fixture/valid.zip" "$revision" 1.2.3 "$identity"; then
        log_pass "Exact Windows family ZIP manifest accepted (parser fixture only)"
    else
        log_fail "Exact Windows family ZIP manifest rejected"
    fi
    for case in bytes manifest duplicate case traversal missing symlink; do
        if _act_validate_frankenterm_windows_archive "$fixture/$case.zip" "$revision" 1.2.3 "$identity" >/dev/null 2>&1; then
            log_fail "Windows ZIP accepted invalid $case fixture"
        else
            log_pass "Windows ZIP rejected $case fixture"
        fi
    done
}

test_unix_strict_rust_forces_out_of_snapshot_target_dir() {
    log_test "Unix Rust strict build: Cargo output stays outside source snapshot"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BUILD_CMD="cargo build --release"
    MOCK_BINARY_NAME="tool"
    MOCK_PLATFORM_ENV=$'CARGO_TARGET_DIR=in-tree-target\nCARGO_HOME=/ambient/cargo-home\nRUSTFLAGS=-C target-cpu=apple-m4\nXWIN_CACHE_DIR=/pinned/xwin-cache\nXWIN_MSVC_SYSROOT_DOWNLOAD_URL=https://example.invalid/pinned-sysroot.tar.xz'
    export RUSTC_WRAPPER="/ambient/evil-wrapper"
    export RUSTFLAGS="-C link-arg=ambient-evil"
    export CARGO_PROFILE_RELEASE_OPT_LEVEL="0"
    export CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER="/ambient/evil-linker"
    export XWIN_CACHE_DIR="/ambient/evil-xwin-cache"
    export XWIN_CROSS_COMPILER="ambient-evil-compiler"
    export DSR_RELEASE_GIT_SHA="ambient-evil-sha"
    export DSR_RELEASE_GIT_REF="ambient-evil-ref"
    MOCK_SSH_STREAM_FILE="$MOCK_DIR/strict-unix-artifact"
    write_mock_artifact "$MOCK_SSH_STREAM_FILE"

    local result
    result=$(
        host_health_is_ready() { [[ "$1" == "mmini" ]]; }
        act_run_native_build \
            "tool" "darwin/arm64" "v1.0.0" "run1" \
            "/remote/.dsr-release-snapshots/tool-run/source" \
            "1111111111111111111111111111111111111111" "v1.0.0" "mmini" 2>/dev/null
    )

    local cmd scp_args raw_ssh_args expected_target expected_home
    cmd=$(get_ssh_cmd)
    scp_args=$(get_scp_args)
    raw_ssh_args=$(get_raw_ssh_args)
    expected_target="/remote/.dsr-release-snapshots/tool-run/.cargo-target-darwin-arm64"
    expected_home="/remote/.dsr-release-snapshots/tool-run/.cargo-home"
    if [[ "$cmd" == *"export \"CARGO_TARGET_DIR=$expected_target\""* && \
          "$cmd" == *"export \"CARGO_HOME=$expected_home\""* && \
          "$cmd" == *"unset RUSTC_WRAPPER;"* && "$cmd" == *"unset RUSTFLAGS;"* && \
          "$cmd" == *'case "$variable" in CARGO_*|RUST*|XWIN_*'* && \
          "$cmd" == *'export "RUSTFLAGS=-C target-cpu=apple-m4"'* && \
          "$cmd" == *'export "XWIN_CACHE_DIR=/pinned/xwin-cache"'* && \
          "$cmd" == *'export "XWIN_MSVC_SYSROOT_DOWNLOAD_URL=https://example.invalid/pinned-sysroot.tar.xz"'* && \
          "$cmd" == *'export "DSR_RELEASE_GIT_SHA=1111111111111111111111111111111111111111"'* && \
          "$cmd" == *'export "DSR_RELEASE_GIT_REF=v1.0.0"'* && \
          "$cmd" != *"/ambient/evil-wrapper"* && "$cmd" != *"ambient-evil"* && \
          "$cmd" != *"/ambient/evil-linker"* && \
          "$cmd" != *"CARGO_TARGET_DIR=in-tree-target"* && \
          "$cmd" != *"CARGO_HOME=/ambient/cargo-home"* && \
          -z "$scp_args" && "$raw_ssh_args" == *"cat --"* ]] && \
       echo "$result" | jq -e \
            --arg home "$expected_home" \
            '.build_influence_env.CARGO_HOME == $home and
             .build_influence_env.RUSTFLAGS == "-C target-cpu=apple-m4" and
             .build_influence_env.XWIN_CACHE_DIR == "/pinned/xwin-cache" and
             .build_influence_env.XWIN_MSVC_SYSROOT_DOWNLOAD_URL == "https://example.invalid/pinned-sysroot.tar.xz" and
             .build_influence_env.DSR_RELEASE_GIT_SHA == "1111111111111111111111111111111111111111" and
             .build_influence_env.DSR_RELEASE_GIT_REF == "v1.0.0" and
             (.build_influence_env | has("RUSTC_WRAPPER") | not) and
             .status == "success" and
             (.collected_sha256 | test("^[0-9a-f]{64}$")) and
             .collected_size_bytes > 0 and
             (.collected_identity | test("^(gnu:|bsd:)"))' >/dev/null; then
        log_pass "Strict Unix build isolates Cargo config and compiler influence env"
    else
        log_fail "Strict Unix Cargo/env isolation was not enforced: cmd=$cmd scp=$scp_args result=$result"
    fi
    unset RUSTC_WRAPPER RUSTFLAGS CARGO_PROFILE_RELEASE_OPT_LEVEL
    unset XWIN_CACHE_DIR XWIN_CROSS_COMPILER DSR_RELEASE_GIT_SHA DSR_RELEASE_GIT_REF
    unset CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER
}

test_unix_strict_rust_executes_xwin_sanitizer_before_exports() {
    log_test "Unix Rust strict build: XWIN sanitizer runs before configured exports"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="tool"
    MOCK_PLATFORM_ENV="XWIN_CACHE_DIR=/configured/xwin-cache"

    local strict_root="$MOCK_DIR/unix-xwin-order/run"
    local observed_env="$MOCK_DIR/unix-xwin-order/observed-env"
    mkdir -p "$strict_root/source" "$strict_root/.cargo-home"
    MOCK_BUILD_CMD="printf '%s\\n' \"\${XWIN_CACHE_DIR-<unset>}\" \"\${XWIN_CROSS_COMPILER-<unset>}\" > '$observed_env'"
    MOCK_SSH_STREAM_FILE="$MOCK_DIR/unix-xwin-order/artifact"
    write_mock_artifact "$MOCK_SSH_STREAM_FILE"
    export XWIN_CACHE_DIR="/ambient/evil-xwin-cache"
    export XWIN_CROSS_COMPILER="ambient-evil-compiler"

    local result status=0
    result=$(
        _act_ssh_exec() {
            printf '%s\n' "HOST:$1" "CMD:$2" > "$SSH_ARGS_FILE"
            "$BASH" -c "$2"
        }
        act_run_native_build \
            "tool" "darwin/arm64" "v1.0.0" "run1" \
            "$strict_root/source" 2>/dev/null
    ) || status=$?

    local -a observed_values=()
    if [[ -f "$observed_env" ]]; then
        mapfile -t observed_values < "$observed_env"
    fi
    if [[ $status -eq 0 && ${#observed_values[@]} -eq 2 && \
          "${observed_values[0]}" == "/configured/xwin-cache" && \
          "${observed_values[1]}" == "<unset>" ]] && \
       echo "$result" | jq -e \
            '.status == "success" and
             .build_influence_env.XWIN_CACHE_DIR == "/configured/xwin-cache" and
             (.build_influence_env | has("XWIN_CROSS_COMPILER") | not)' >/dev/null; then
        log_pass "Ambient XWIN values are removed before configured XWIN values are exported"
    else
        log_fail "Executed XWIN sanitizer ordering was incorrect: status=$status values=${observed_values[*]-} result=$result"
    fi
    unset XWIN_CACHE_DIR XWIN_CROSS_COMPILER
}

test_windows_strict_rust_forces_out_of_snapshot_target_dir() {
    log_test "Windows Rust strict build: Cargo output stays outside source snapshot"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BUILD_CMD="cargo build --release"
    MOCK_BINARY_NAME="tool"
    MOCK_PLATFORM_ENV=$'CARGO_TARGET_DIR=in-tree-target\nCARGO_HOME=C:/ambient/cargo-home\nRUSTFLAGS=-C target-feature=+crt-static\nXwIn_CaChE_DiR=C:/pinned/xwin-cache-first\nxwin_cache_dir=C:/pinned/xwin-cache-last\nXWIN_MSVC_SYSROOT_DOWNLOAD_URL=https://example.invalid/pinned-sysroot.tar.xz'
    export RUSTC_WRAPPER="C:/ambient/evil-wrapper.exe"
    export RUSTFLAGS="-C link-arg=ambient-evil"
    export CARGO_PROFILE_RELEASE_OPT_LEVEL="0"
    export CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER="C:/ambient/evil-linker.exe"
    export XWIN_CACHE_DIR="C:/ambient/evil-xwin-cache"
    export XWIN_CROSS_COMPILER="ambient-evil-compiler"
    MOCK_SSH_STREAM_FILE="$MOCK_DIR/strict-windows-artifact"
    MOCK_ARTIFACT_KIND=pe-amd64 write_mock_artifact "$MOCK_SSH_STREAM_FILE"

    local result
    result=$(act_run_native_build \
        "tool" "windows/amd64" "v1.0.0" "12345678-1234-4234-8234-123456789abc" \
        "C:/build/.dsr-release-snapshots/tool-run/source" 2>/dev/null)

    local cmd scp_args raw_ssh_args expected_target expected_home expected_home_win
    local first_xwin_value_b64 last_xwin_value_b64 first_xwin_prefix last_xwin_prefix
    cmd=$(get_ssh_cmd)
    scp_args=$(get_scp_args)
    raw_ssh_args=$(get_raw_ssh_args)
    first_xwin_value_b64=$(printf '%s' 'C:/pinned/xwin-cache-first' | base64 | tr -d '\r\n')
    last_xwin_value_b64=$(printf '%s' 'C:/pinned/xwin-cache-last' | base64 | tr -d '\r\n')
    first_xwin_prefix="${cmd%%"$first_xwin_value_b64"*}"
    last_xwin_prefix="${cmd%%"$last_xwin_value_b64"*}"
    expected_target="C:/d/t/12345678-1234-4234-8234-123456789abc/amd64"
    expected_home="C:/build/.dsr-release-snapshots/tool-run/.cargo-home"
    expected_home_win="C:\\build\\.dsr-release-snapshots\\tool-run\\.cargo-home"
    if [[ "$cmd" == *"$expected_home_win"* && \
          "$cmd" == *'$cargoHome=Get-Item'* && \
          "$cmd" != *'$home=Get-Item'* && \
          "$cmd" == *"System.Diagnostics.ProcessStartInfo"* && \
          "$cmd" == *"^(CARGO_|RUST|XWIN_)"* && \
          "$cmd" == *"EnvironmentVariables.Remove"* && \
          "$cmd" == *"FromBase64String"* && \
          "$cmd" == *"$first_xwin_value_b64"* && \
          "$cmd" == *"$last_xwin_value_b64"* && \
          ${#first_xwin_prefix} -lt ${#last_xwin_prefix} && \
          "$cmd" != *"C:/ambient/evil-wrapper.exe"* && "$cmd" != *"ambient-evil"* && \
          "$cmd" != *"C:/ambient/evil-linker.exe"* && \
          "$cmd" != *"CARGO_TARGET_DIR=in-tree-target"* && \
          "$cmd" != *"CARGO_HOME=C:/ambient/cargo-home"* && \
          "$scp_args" == *"/build.ps1"* && "$raw_ssh_args" == *"File]::OpenRead"* && \
          "$raw_ssh_args" == *"CopyTo"* && \
          "$raw_ssh_args" == *'$output.Dispose()'* ]] && \
       echo "$result" | jq -e \
            --arg home "$expected_home" \
            '.build_influence_env.CARGO_HOME == $home and
             .build_influence_env.RUSTFLAGS == "-C target-feature=+crt-static" and
             .build_influence_env.XWIN_CACHE_DIR == "C:/pinned/xwin-cache-last" and
             ([.build_influence_env | keys[] | select(ascii_upcase == "XWIN_CACHE_DIR")] | length) == 1 and
             .build_influence_env.XWIN_MSVC_SYSROOT_DOWNLOAD_URL == "https://example.invalid/pinned-sysroot.tar.xz" and
             (.build_influence_env | has("RUSTC_WRAPPER") | not) and
             .status == "success" and
             (.collected_sha256 | test("^[0-9a-f]{64}$")) and
             .collected_size_bytes > 0 and
             (.collected_identity | test("^(gnu:|bsd:)"))' >/dev/null; then
        log_pass "Strict Windows build isolates Cargo config and compiler influence env"
    else
        log_fail "Strict Windows Cargo/env isolation was not enforced: cmd=$cmd scp=$scp_args result=$result"
    fi
    unset RUSTC_WRAPPER RUSTFLAGS CARGO_PROFILE_RELEASE_OPT_LEVEL
    unset XWIN_CACHE_DIR XWIN_CROSS_COMPILER
    unset CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER
}

test_strict_native_source_binding() {
    log_test "Strict native source binding: reject absent or unhealthy authority before side effects"
    local binding_case result status source_root bound_host sentinel
    for binding_case in missing-root missing-host unhealthy missing-health; do
        reset_state
        source_root="/remote/release/source"
        bound_host="mmini"
        sentinel="$MOCK_DIR/binding-$binding_case-side-effect"
        [[ "$binding_case" == "missing-root" ]] && source_root=""
        [[ "$binding_case" == "missing-host" ]] && bound_host=""
        status=0
        result=$(
            act_get_native_host() { printf 'selected\n' >> "$sentinel"; printf 'wlap\n'; }
            act_get_local_path() { printf 'configured\n' >> "$sentinel"; printf '/local/path/tool\n'; }
            _act_ssh_exec() { printf 'ssh\n' >> "$sentinel"; return 99; }
            host_health_is_ready() { [[ "$binding_case" != "unhealthy" ]]; }
            [[ "$binding_case" != "missing-health" ]] || unset -f host_health_is_ready
            act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" \
                "$source_root" "1111111111111111111111111111111111111111" "v1.0.0" "$bound_host"
        ) || status=$?
        if [[ "$status" -eq 4 && ! -e "$sentinel" ]] && \
           jq -e '.status == "error" and .exit_code == 4' <<< "$result" >/dev/null; then
            log_pass "Strict $binding_case fails before selection, configuration, or SSH"
        else
            log_fail "Strict $binding_case escaped its source boundary: status=$status result=$result"
        fi
    done

    reset_state
    sentinel="$MOCK_DIR/binding-positive-selector"
    MOCK_SSH_STREAM_FILE="$MOCK_DIR/binding-positive-artifact"
    write_mock_artifact "$MOCK_SSH_STREAM_FILE"
    status=0
    result=$(
        act_get_native_host() { printf 'selected\n' > "$sentinel"; printf 'wlap\n'; }
        host_health_is_ready() { [[ "$1" == "mmini" ]]; }
        act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" \
            "/remote/release/source" "1111111111111111111111111111111111111111" "v1.0.0" "mmini"
    ) || status=$?
    if [[ "$status" -eq 0 && ! -e "$sentinel" ]] && \
       jq -e '.status == "success" and .host == "mmini"' <<< "$result" >/dev/null && \
       [[ "$(get_ssh_cmd)" == *"/remote/release/source"* ]]; then
        log_pass "Strict native build stays on its synchronized host despite selector drift"
    else
        log_fail "Strict native build lost its source host: status=$status result=$result"
    fi
}

test_unix_strict_validation_failure_stops_build() {
    log_test "Unix Rust strict build: isolation failure stops build command"
    reset_state
    MOCK_LANGUAGE="rust"
    local strict_root="$MOCK_DIR/unix-fail-fast/run"
    local sentinel="$MOCK_DIR/unix-fail-fast-build-ran"
    mkdir -p "$strict_root/source" "$strict_root/.cargo-home"
    printf '[net]\noffline = false\n' > "$strict_root/.cargo-home/config.toml"
    MOCK_BUILD_CMD="printf reached > '$sentinel'"

    local status=0
    (
        _act_ssh_exec() { /opt/homebrew/bin/bash -c "$2"; }
        act_run_native_build \
            "tool" "darwin/arm64" "v1.0.0" "run1" \
            "$strict_root/source" >/dev/null 2>&1
    ) || status=$?

    if [[ $status -ne 0 && ! -e "$sentinel" ]]; then
        log_pass "Unix strict validation failure prevented the build sentinel"
    else
        log_fail "Unix strict validation failure reached the build command"
    fi
}

test_windows_strict_validation_failure_stops_build() {
    log_test "Windows Rust strict build: validation guards process launch"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BUILD_CMD="echo reached"
    local sentinel="$MOCK_DIR/windows-fail-fast-build-ran"
    local status=0
    (
        _act_ssh_exec() {
            local command_text
            command_text=$(_test_decode_remote_command "$2")
            if [[ "$2" == powershell* && \
                  "$command_text" == *"throw 'Strict CARGO_HOME"* && \
                  "$command_text" == *'$process=[Diagnostics.Process]::Start'* ]]; then
                return 1
            fi
            printf 'reached\n' > "$sentinel"
            return 1
        }
        act_run_native_build \
            "tool" "windows/amd64" "v1.0.0" "run1" \
            "C:/build/.dsr-release-snapshots/tool-run/source" >/dev/null 2>&1
    ) || status=$?

    if [[ $status -ne 0 && ! -e "$sentinel" ]]; then
        log_pass "Windows strict validation failure prevented process launch"
    else
        log_fail "Windows strict validation failure reached process launch"
    fi
}

test_strict_collector_keeps_symlink_victim_unchanged() {
    log_test "Strict collection: held descriptor defeats destination replacement"
    reset_state

    local destination="$MOCK_DIR/strict-race/artifact"
    local victim="$MOCK_DIR/strict-race/victim"
    mkdir -p "$(dirname "$destination")"
    printf 'victim must remain unchanged\n' > "$victim"

    local status=0
    (
        replace_destination_then_stream() {
            mv "$destination" "${destination}.opened" || return 1
            ln -s "$victim" "$destination" || return 1
            printf 'artifact bytes\n'
        }
        _act_collect_stream_exclusive \
            "$destination" 700 replace_destination_then_stream
    ) >/dev/null 2>&1 || status=$?

    if [[ $status -eq 4 && "$(cat "$victim")" == "victim must remain unchanged" ]]; then
        log_pass "Strict collector rejected replacement without touching symlink victim"
    else
        log_fail "Strict collector accepted destination replacement or changed victim"
    fi
}

test_strict_collector_rejects_partial_producer_failure() {
    log_test "Strict collection: partial producer failure has no receipt"
    reset_state

    local destination="$MOCK_DIR/strict-partial/artifact"
    mkdir -p "$(dirname "$destination")"
    local receipt status=0
    receipt=$(
        partial_producer() {
            printf 'partial bytes\n'
            return 23
        }
        _act_collect_stream_exclusive "$destination" 700 partial_producer
    ) || status=$?

    if [[ $status -eq 7 && -z "$receipt" && -s "$destination" ]]; then
        log_pass "Strict collector retained partial evidence but emitted no receipt"
    else
        log_fail "Partial producer failure was accepted: status=$status receipt=$receipt"
    fi
}

test_strict_collection_loop_streams_every_remote_artifact() {
    log_test "Strict collection: remote streams never drain the collection loop"
    reset_state

    # Production collects workspace members and additional artifacts inside
    # `while read` loops fed by process substitutions.  A remote stream that
    # inherits that stdin (ssh without -n) swallows the loop's remaining
    # lines, so only the FIRST artifact was ever collected — silently, since
    # the loop simply ended.  The fake ssh reads stdin to EOF exactly like
    # the real one before answering; three artifacts per transport are
    # expected on the other side.
    local loop_dir="$MOCK_DIR/strict-loop"
    local collected_file="$loop_dir/collected.txt"
    mkdir -p "$loop_dir/unix" "$loop_dir/windows"
    (
        ssh() {
            cat >/dev/null
            printf 'artifact bytes for %s\n' "${!#}"
        }
        local name
        while IFS= read -r name; do
            if _act_collect_stream_exclusive "$loop_dir/unix/$name" 600 \
                    _act_stream_remote_unix_file mock-unix "/remote/$name" >/dev/null; then
                printf 'unix:%s\n' "$name" >> "$collected_file"
            fi
        done < <(printf '%s\n' first second third)
        while IFS= read -r name; do
            if _act_collect_stream_exclusive "$loop_dir/windows/$name" 600 \
                    _act_stream_remote_windows_file mock-windows "C:/remote/$name" >/dev/null; then
                printf 'windows:%s\n' "$name" >> "$collected_file"
            fi
        done < <(printf '%s\n' first second third)
    ) 2>/dev/null

    local expected
    expected=$(printf '%s\n' unix:first unix:second unix:third \
        windows:first windows:second windows:third)
    if [[ -f "$collected_file" && "$(cat "$collected_file")" == "$expected" && \
          -s "$loop_dir/unix/third" && -s "$loop_dir/windows/third" ]]; then
        log_pass "Every artifact in the collection loop was streamed"
    else
        log_fail "Collection loop lost artifacts: collected=$(tr '\n' ' ' < "$collected_file" 2>/dev/null)"
    fi
}

test_strict_windows_bare_name_retry_uses_fresh_destination() {
    log_test "Strict collection: Windows bare-name retry gets a fresh destination"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BUILD_CMD="cargo build --release"
    MOCK_BINARY_NAME="tool"

    local attempts_file="$MOCK_DIR/strict-windows-retry-attempts"
    local complete_file="$MOCK_DIR/strict-windows-complete"
    MOCK_ARTIFACT_KIND=pe-amd64 write_mock_artifact "$complete_file"
    local result
    result=$(
        ssh() {
            local remote_command
            remote_command=$(_test_decode_remote_command "${!#}")
            printf '%s\n' "$remote_command" >> "$attempts_file"
            if [[ "$remote_command" == *"tool.exe"* ]]; then
                printf 'partial exe attempt\n'
                return 1
            fi
            cat "$complete_file"
        }
        act_run_native_build \
            "tool" "windows/amd64" "v1.0.0" "23456789-1234-4234-8234-123456789abc" \
            "C:/build/.dsr-release-snapshots/tool-run/source" 2>/dev/null
    )

    local collected_path attempt_count retained_count
    collected_path=$(jq -r '.artifact_path // empty' <<< "$result")
    attempt_count=$(wc -l < "$attempts_file" | tr -d ' ')
    retained_count=$(find "$ACT_ARTIFACTS_DIR" -path '*23456789-1234-4234-8234-123456789abc*' \
        -type f -name 'tool.exe' | wc -l | tr -d ' ')
    if [[ "$attempt_count" -eq 2 && "$retained_count" -eq 2 && \
          "$collected_path" == */retry.*/tool.exe && "$(get_scp_args)" == *"/build.ps1"* ]] && \
       jq -e '.status == "success" and (.collected_sha256 | test("^[0-9a-f]{64}$"))' \
           <<< "$result" >/dev/null; then
        log_pass "Strict Windows retry retained partial evidence and streamed the bare-name executable"
    else
        log_fail "Strict Windows retry did not isolate attempts: result=$result attempts=$attempt_count files=$retained_count"
    fi
}

test_unix_chained_with_and() {
    log_test "Unix: commands run under fail-fast shell mode"
    reset_state

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == "set -e; cd "* ]]; then
        log_pass "Commands run with set -e before cd and build"
    else
        log_fail "Expected fail-fast command construction in: $cmd"
    fi
}

test_unix_host_path_override() {
    log_test "Unix: uses host_paths override when set"
    reset_state
    MOCK_HOST_PATH_MMINI="/Users/jemanuel/projects/tool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *"cd '/Users/jemanuel/projects/tool'"* ]]; then
        log_pass "Uses host_paths override: /Users/jemanuel/projects/tool"
    else
        log_fail "Expected host_paths override in: $cmd"
    fi
}

test_unix_fallback_to_local_path() {
    log_test "Unix: falls back to local_path when no host_paths"
    reset_state
    MOCK_HOST_PATH_MMINI=""  # No override
    MOCK_LOCAL_PATH="/data/projects/mytool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *"cd '/data/projects/mytool'"* ]]; then
        log_pass "Falls back to local_path"
    else
        log_fail "Expected fallback to local_path in: $cmd"
    fi
}

# ============================================================================
# Test Cases: Windows Command Construction
# ============================================================================

test_windows_build_guard_transport_and_timeout_validation() {
    log_test "Windows guard: literal source survives transport and invalid deadlines fail"
    local script=$'Write-Output '\''日本語 '\'''\'' quoted'\''\nexit 37'
    local guard encoded decoded bad rejected=true
    guard=$(_act_windows_build_guard_script 30 "$script") || {
        log_fail "Guard construction failed"
        return
    }
    encoded=$(_act_windows_encoded_powershell "$guard") || {
        log_fail "Guard transport encoding failed"
        return
    }
    decoded=$(_test_decode_remote_command "$encoded")
    if [[ "$decoded" == "$script" ]]; then
        log_pass "Guard preserves exact Unicode, quoting, newline and exit script"
    else
        log_fail "Guard changed the original build script"
    fi
    for bad in 0 -1 2147484 invalid '1;exit'; do
        if _act_windows_build_guard_script "$bad" "$script" >/dev/null 2>&1; then
            rejected=false
        fi
    done
    if $rejected; then
        log_pass "Guard rejects invalid or overflowing remote deadlines"
    else
        log_fail "Guard accepted an invalid remote deadline"
    fi
}

test_windows_cd_command() {
    log_test "Windows: cd /d with double quotes and backslashes"
    reset_state
    MOCK_LOCAL_PATH="/c/Users/jeffr/projects/tool"

    act_run_native_build "tool" "windows/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    # Windows should convert / to \ and use double quotes
    if [[ "$cmd" == *'cd /d "'* ]] && [[ "$cmd" == *'\'* ]]; then
        log_pass "Windows uses cd /d with backslashes"
    else
        log_fail "Expected Windows cd /d with backslashes in: $cmd"
    fi
}

test_windows_env_set_syntax() {
    log_test "Windows: env vars use set syntax"
    reset_state
    MOCK_LOCAL_PATH="/c/Users/jeffr/projects/tool"
    MOCK_GLOBAL_ENV="CARGO_TERM_COLOR=always"

    act_run_native_build "tool" "windows/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    if [[ "$cmd" == *'set "'*'='*'"'* ]] || [[ "$cmd" == *'set "CARGO_TERM_COLOR=always"'* ]]; then
        log_pass "Windows uses set for env vars"
    else
        log_fail "Expected Windows set syntax in: $cmd"
    fi
}

test_windows_slash_conversion() {
    log_test "Windows: forward slashes converted to backslashes"
    reset_state
    MOCK_LOCAL_PATH="/c/Users/jeffr/projects/tool"

    act_run_native_build "tool" "windows/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    # Check for backslash in the path
    if [[ "$cmd" == *'\c\Users\jeffr\projects\tool'* ]]; then
        log_pass "Forward slashes converted to backslashes"
    else
        log_fail "Expected backslash path in: $cmd"
    fi
}

test_windows_rsync_path_conversion() {
    log_test "Windows: rsync path uses /cygdrive form"
    reset_state

    local path
    path=$(_act_windows_rsync_path "C:/Users/jeffr/release-work/tool")

    if [[ "$path" == "/cygdrive/c/Users/jeffr/release-work/tool" ]]; then
        log_pass "Windows rsync path converted to /cygdrive form"
    else
        log_fail "Expected /cygdrive path but got: $path"
    fi
}

test_windows_rsync_probe_uses_where() {
    log_test "Windows: rsync probe uses where, not command -v"
    reset_state

    _act_has_rsync "wlap" >/dev/null 2>&1 || true

    local ssh_args
    ssh_args=$(get_raw_ssh_args)

    if [[ "$ssh_args" == *"where rsync >NUL 2>&1"* ]]; then
        log_pass "Windows rsync probe uses where"
    else
        log_fail "Expected Windows rsync probe to use where in: $ssh_args"
    fi
}

test_windows_sync_uses_cygdrive_remote_path() {
    log_test "Windows: rsync sync uses cygdrive remote path"
    reset_state

    local local_src="$MOCK_DIR/local-src"
    mkdir -p "$local_src"
    printf 'hello\n' > "$local_src/hello.txt"

    _act_sync_source "wlap" "$local_src" "C:/Users/jeffr/release-work/tool" >/dev/null 2>&1

    local rsync_args
    rsync_args=$(get_rsync_args)

    if [[ "$rsync_args" == *"wlap:/cygdrive/c/Users/jeffr/release-work/tool/"* ]]; then
        log_pass "Windows rsync sync uses /cygdrive remote path"
    else
        log_fail "Expected /cygdrive rsync target in: $rsync_args"
    fi
}

test_sync_uses_gitignore_exclude_file_by_default() {
    log_test "Sync: uses .gitignore as rsync exclude file by default"
    reset_state

    local local_src="$MOCK_DIR/local-src-gitignore"
    mkdir -p "$local_src"
    printf 'src/test_*.rs\n' > "$local_src/.gitignore"
    printf 'hello\n' > "$local_src/hello.txt"

    _act_sync_source "wlap" "$local_src" "C:/Users/jeffr/release-work/tool" >/dev/null 2>&1

    local rsync_args
    rsync_args=$(get_rsync_args)

    if [[ "$rsync_args" == *"--exclude-from=$local_src/.gitignore"* ]]; then
        log_pass ".gitignore is injected into rsync excludes by default"
    else
        log_fail "Expected --exclude-from=.gitignore in: $rsync_args"
    fi
}

test_sync_can_disable_gitignore_exclude_file() {
    log_test "Sync: can disable .gitignore rsync excludes"
    reset_state

    local local_src="$MOCK_DIR/local-src-gitignore-disabled"
    mkdir -p "$local_src"
    printf 'src/test_*.rs\n' > "$local_src/.gitignore"
    printf 'hello\n' > "$local_src/hello.txt"

    _act_sync_source "wlap" "$local_src" "C:/Users/jeffr/release-work/tool" --no-gitignore-excludes >/dev/null 2>&1

    local rsync_args
    rsync_args=$(get_rsync_args)

    if [[ "$rsync_args" == *"--exclude-from="* ]]; then
        log_fail "Did not expect --exclude-from=.gitignore in: $rsync_args"
    else
        log_pass ".gitignore excludes can be disabled per sync"
    fi
}

# ============================================================================
# Test Cases: Path Handling
# ============================================================================

test_path_with_spaces_unix() {
    log_test "Path with spaces (Unix): properly quoted"
    reset_state
    MOCK_LOCAL_PATH="/Users/John Doe/My Projects/tool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    # Single quotes should protect spaces
    if [[ "$cmd" == *"cd '/Users/John Doe/My Projects/tool'"* ]]; then
        log_pass "Spaces handled with single quotes"
    else
        log_fail "Expected proper quoting for spaces in: $cmd"
    fi
}

test_path_with_single_quote() {
    log_test "Path with single quote: properly escaped"
    reset_state
    MOCK_LOCAL_PATH="/Users/O'Brien/projects/tool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_cmd)

    # Single quote should be escaped as '\''
    if [[ "$cmd" == *"'\\''"* ]] || [[ "$cmd" == *"O'Brien"* ]]; then
        log_pass "Single quote in path handled"
    else
        log_fail "Expected escaped single quote in: $cmd"
    fi
}

# ============================================================================
# Test Cases: SCP Commands
# ============================================================================

test_scp_unix_artifact_path() {
    log_test "SCP Unix: correct artifact path for Go"
    reset_state
    MOCK_LANGUAGE="go"
    MOCK_BINARY_NAME="mytool"
    MOCK_LOCAL_PATH="/local/path/mytool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local scp_args
    scp_args=$(get_scp_args)

    # Go binary should be at project root
    # Note: scp now uses separate shell arguments, so path is not embedded-quoted
    if [[ "$scp_args" == *"mmini:/local/path/mytool/mytool "* ]]; then
        log_pass "Go artifact path correct: /local/path/mytool/mytool"
    else
        log_fail "Expected Go artifact path in: $scp_args"
    fi
}

test_go_artifact_path_honors_gobin() {
    log_test "Go artifact path honors absolute GOBIN outside the source root"

    local unix_path windows_path
    unix_path=$(act_get_remote_artifact_path \
        "go" "/snapshot/source" $'GOBIN=/snapshot/go-bin-linux-amd64' \
        "mytool" "linux/amd64")
    windows_path=$(act_get_remote_artifact_path \
        "go" "/snapshot/source" $'GOBIN=/snapshot/go-bin-windows-amd64' \
        "mytool" "windows/amd64")

    if [[ "$unix_path" == "/snapshot/go-bin-linux-amd64/mytool" && \
          "$windows_path" == "/snapshot/go-bin-windows-amd64/mytool.exe" ]]; then
        log_pass "Go artifact paths resolve from GOBIN for Unix and Windows targets"
    else
        log_fail "Unexpected GOBIN artifact paths: unix=$unix_path windows=$windows_path"
    fi
}

test_scp_rust_artifact_path() {
    log_test "SCP Unix: Rust default target is derived outside staged source"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_LOCAL_PATH="/local/path/mytool"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local scp_args
    scp_args=$(get_scp_args)

    if [[ "$scp_args" == *"mmini:/local/path/.dsr-cargo-target-tool-darwin-arm64/aarch64-apple-darwin/release/mytool "* ]]; then
        log_pass "Rust artifact path is stable outside the ephemeral source copy"
    else
        log_fail "Expected Rust artifact path in: $scp_args"
    fi
}

test_scp_rust_artifact_path_with_absolute_cargo_target_dir() {
    log_test "SCP Unix: Rust honors absolute CARGO_TARGET_DIR"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_LOCAL_PATH="/local/path/mytool"
    MOCK_PLATFORM_ENV="CARGO_TARGET_DIR=/Users/jemanuel/tmp/rch-target-dsr"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local scp_args
    scp_args=$(get_scp_args)

    if [[ "$scp_args" == *"mmini:/Users/jemanuel/tmp/rch-target-dsr/aarch64-apple-darwin/release/mytool "* ]]; then
        log_pass "Rust artifact path honors absolute CARGO_TARGET_DIR"
    else
        log_fail "Expected absolute CARGO_TARGET_DIR artifact path in: $scp_args"
    fi
}

test_scp_rust_artifact_path_with_relative_cargo_target_dir() {
    log_test "SCP Unix: Rust replaces unsafe relative CARGO_TARGET_DIR"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_LOCAL_PATH="/local/path/mytool"
    MOCK_PLATFORM_ENV="CARGO_TARGET_DIR=custom-target"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local scp_args
    scp_args=$(get_scp_args)

    if [[ "$scp_args" == *"mmini:/local/path/.dsr-cargo-target-tool-darwin-arm64/aarch64-apple-darwin/release/mytool "* ]]; then
        log_pass "Relative CARGO_TARGET_DIR cannot follow the ephemeral source cwd"
    else
        log_fail "Expected derived absolute CARGO_TARGET_DIR artifact path in: $scp_args"
    fi
}

test_scp_rust_artifact_path_with_cargo_build_target() {
    log_test "SCP Unix: Rust honors CARGO_BUILD_TARGET subdirectory"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_LOCAL_PATH="/local/path/mytool"
    MOCK_PLATFORM_ENV=$'CARGO_TARGET_DIR=/Users/jemanuel/tmp/rch-target-dsr\nCARGO_BUILD_TARGET=x86_64-apple-darwin'

    act_run_native_build "tool" "darwin/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local scp_args
    scp_args=$(get_scp_args)

    if [[ "$scp_args" == *"mmini:/Users/jemanuel/tmp/rch-target-dsr/x86_64-apple-darwin/release/mytool "* ]]; then
        log_pass "Rust artifact path honors CARGO_BUILD_TARGET subdirectory"
    else
        log_fail "Expected CARGO_BUILD_TARGET artifact path in: $scp_args"
    fi
}

test_scp_rust_artifact_path_with_custom_profile() {
    log_test "SCP Unix: Rust honors configured Cargo profile directory"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_LOCAL_PATH="/local/path/mytool"
    MOCK_BUILD_PROFILE="release-interactive"
    MOCK_PLATFORM_ENV=$'CARGO_TARGET_DIR=/Users/jemanuel/tmp/rch-target-dsr\nCARGO_BUILD_TARGET=aarch64-apple-darwin'

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local scp_args
    scp_args=$(get_scp_args)

    if [[ "$scp_args" == *"mmini:/Users/jemanuel/tmp/rch-target-dsr/aarch64-apple-darwin/release-interactive/mytool "* ]]; then
        log_pass "Rust artifact path honors configured Cargo profile directory"
    else
        log_fail "Expected custom-profile artifact path in: $scp_args"
    fi
}

test_scp_windows_exe_extension() {
    log_test "SCP Windows: .exe extension added"
    reset_state
    MOCK_LANGUAGE="go"
    MOCK_BINARY_NAME="mytool"
    MOCK_LOCAL_PATH="/c/projects/mytool"

    act_run_native_build "tool" "windows/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local scp_args
    scp_args=$(get_scp_args)

    if [[ "$scp_args" == *".exe"* ]]; then
        log_pass "Windows artifact has .exe extension"
    else
        log_fail "Expected .exe extension in: $scp_args"
    fi
}

test_scp_windows_forward_slash_path() {
    log_test "SCP Windows: forward slashes (OpenSSH SCP convention)"
    reset_state
    MOCK_LANGUAGE="go"
    MOCK_BINARY_NAME="mytool"
    MOCK_LOCAL_PATH="/c/Users/jeffr/projects/mytool"

    act_run_native_build "tool" "windows/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local scp_args
    scp_args=$(get_scp_args)

    # OpenSSH SCP uses forward slashes even on Windows (see act_runner.sh line 1144)
    if [[ "$scp_args" == *"/c/Users/jeffr/projects/mytool/mytool.exe"* ]]; then
        log_pass "Windows SCP path uses forward slashes (OpenSSH convention)"
    else
        log_fail "Expected forward-slash path in SCP args: $scp_args"
    fi
}

# ============================================================================
# Test Cases: Host Detection
# ============================================================================

test_host_detection_darwin() {
    log_test "Host detection: darwin/* -> mmini"
    reset_state

    local host
    host=$(act_get_native_host "darwin/arm64")

    if [[ "$host" == "mmini" ]]; then
        log_pass "darwin/arm64 -> mmini"
    else
        log_fail "Expected mmini but got: $host"
    fi
}

test_host_detection_windows() {
    log_test "Host detection: windows/* -> wlap"
    reset_state

    local amd64_host arm64_host
    amd64_host=$(act_get_native_host "windows/amd64")
    arm64_host=$(act_get_native_host "windows/arm64")

    if [[ "$amd64_host" == "wlap" && "$arm64_host" == "wlap" ]]; then
        log_pass "windows/amd64 and windows/arm64 -> wlap"
    else
        log_fail "Expected wlap but got: amd64=$amd64_host arm64=$arm64_host"
    fi
}

test_host_detection_linux() {
    log_test "Host detection: linux/* -> trj"
    reset_state

    local host
    host=$(act_get_native_host "linux/amd64")

    if [[ "$host" == "trj" ]]; then
        log_pass "linux/amd64 -> trj"
    else
        log_fail "Expected trj but got: $host"
    fi
}

test_host_detection_unknown() {
    log_test "Host detection: unknown platform returns empty"
    reset_state

    local host
    host=$(act_get_native_host "freebsd/amd64")

    if [[ -z "$host" ]]; then
        log_pass "Unknown platform returns empty"
    else
        log_fail "Expected empty but got: $host"
    fi
}

# ============================================================================
# Test Cases: Host Selection (health/capacity-aware)
# ============================================================================

# The selector and the static mapping are both optional collaborators that
# act_get_native_host discovers with `declare -F`. Define them locally so these
# tests exercise the real resolution order without a live health cache.
_stub_host_resolution() {
    local mapped="$1"
    local selected="$2"

    # Same reason as the SSH/SCP capture files above: act_get_native_host is
    # usually called through $( ), so a stub recording to a variable would lose
    # it with the subshell. Lives under MOCK_DIR so suite teardown reaps it.
    _STUB_SELECTOR_ARGS_FILE="$MOCK_DIR/selector_args.txt"
    : > "$_STUB_SELECTOR_ARGS_FILE"

    eval "config_get_host_for_platform() { printf '%s\n' '$mapped'; }"
    if [[ -n "$selected" ]]; then
        eval "selector_choose_host() { printf '%s' \"\$*\" > '$_STUB_SELECTOR_ARGS_FILE'; printf '%s\n' '$selected'; }"
    else
        eval "selector_choose_host() { printf '%s' \"\$*\" > '$_STUB_SELECTOR_ARGS_FILE'; return 1; }"
    fi
}

_unstub_host_resolution() {
    unset -f config_get_host_for_platform selector_choose_host 2>/dev/null || true
    unset DSR_DISABLE_HOST_SELECTOR
    unset _STUB_SELECTOR_ARGS_FILE
    # Unconditional success: a bare `[[ ]] && ...` tail would return non-zero
    # whenever the guard is false, and callers here run under `set -o pipefail`.
    return 0
}

test_host_selection_selector_wins() {
    log_test "Host selection: healthy selector result overrides platform_mapping"
    reset_state
    _stub_host_resolution "wlap" "wsurf"

    local host
    host=$(act_get_native_host "windows/amd64")

    if [[ "$host" == "wsurf" ]]; then
        log_pass "selector choice used instead of mapped host"
    else
        log_fail "Expected wsurf but got: $host"
    fi
    _unstub_host_resolution
}

test_host_selection_prefers_mapped_host() {
    log_test "Host selection: platform_mapping host is passed as --prefer"
    reset_state
    _stub_host_resolution "wlap" "wlap"

    act_get_native_host "windows/amd64" >/dev/null

    local selector_args
    selector_args=$(cat "$_STUB_SELECTOR_ARGS_FILE" 2>/dev/null || true)

    if [[ "$selector_args" == *"--prefer wlap"* ]]; then
        log_pass "mapped host forwarded as --prefer"
    else
        log_fail "Expected --prefer wlap in selector args: $selector_args"
    fi
    _unstub_host_resolution
}

test_host_selection_falls_back_to_mapping() {
    log_test "Host selection: selector failure falls back to platform_mapping"
    reset_state
    _stub_host_resolution "wlap" ""

    local host
    host=$(act_get_native_host "windows/amd64")

    if [[ "$host" == "wlap" ]]; then
        log_pass "fell back to mapped host when selector found nothing"
    else
        log_fail "Expected wlap but got: $host"
    fi
    _unstub_host_resolution
}

test_host_selection_can_be_disabled() {
    log_test "Host selection: DSR_DISABLE_HOST_SELECTOR=1 bypasses selector"
    reset_state
    _stub_host_resolution "wlap" "wsurf"
    export DSR_DISABLE_HOST_SELECTOR=1

    local host
    host=$(act_get_native_host "windows/amd64")

    if [[ "$host" == "wlap" ]]; then
        log_pass "selector bypassed, mapped host used"
    else
        log_fail "Expected wlap but got: $host"
    fi
    _unstub_host_resolution
}

# ============================================================================
# Test Cases: Error Handling
# ============================================================================

test_ssh_failure_propagates() {
    log_test "Error: SSH failure returns exit code 6"
    reset_state
    echo "1" > "$SSH_EXIT_CODE_FILE"

    local result exit_code=0
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || exit_code=$?

    if [[ "$exit_code" -eq 6 ]]; then
        log_pass "SSH failure returns exit code 6"
    else
        log_fail "Expected exit code 6 but got: $exit_code"
    fi
}

test_ssh_failure_json_status() {
    log_test "Error: SSH failure sets status to 'failed'"
    reset_state
    echo "1" > "$SSH_EXIT_CODE_FILE"

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local status
    status=$(echo "$result" | jq -r '.status // "unknown"')

    if [[ "$status" == "failed" ]]; then
        log_pass "SSH failure status is 'failed'"
    else
        log_fail "Expected status 'failed' but got: $status"
    fi
}

test_ssh_timeout_returns_5() {
    log_test "Error: SSH timeout (exit 124) returns code 5"
    reset_state
    echo "124" > "$SSH_EXIT_CODE_FILE"

    local exit_code=0
    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 5 ]]; then
        log_pass "SSH timeout returns exit code 5"
    else
        log_fail "Expected exit code 5 but got: $exit_code"
    fi
}

test_ssh_timeout_json_status() {
    log_test "Error: SSH timeout sets status to 'timeout'"
    reset_state
    echo "124" > "$SSH_EXIT_CODE_FILE"

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local status
    status=$(echo "$result" | jq -r '.status // "unknown"')

    if [[ "$status" == "timeout" ]]; then
        log_pass "SSH timeout status is 'timeout'"
    else
        log_fail "Expected status 'timeout' but got: $status"
    fi
}

test_scp_failure_returns_7() {
    log_test "Error: SCP failure returns exit code 7"
    reset_state
    echo "0" > "$SSH_EXIT_CODE_FILE"  # SSH succeeds
    echo "1" > "$SCP_EXIT_CODE_FILE"  # SCP fails

    local exit_code=0
    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 7 ]]; then
        log_pass "SCP failure returns exit code 7"
    else
        log_fail "Expected exit code 7 but got: $exit_code"
    fi
}

test_scp_failure_empty_artifact_path() {
    log_test "Error: SCP failure sets artifact_path to empty"
    reset_state
    echo "0" > "$SSH_EXIT_CODE_FILE"
    echo "1" > "$SCP_EXIT_CODE_FILE"

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local artifact_path
    artifact_path=$(echo "$result" | jq -r '.artifact_path // "null"')

    if [[ "$artifact_path" == "" || "$artifact_path" == "null" ]]; then
        log_pass "SCP failure clears artifact_path"
    else
        log_fail "Expected empty artifact_path but got: $artifact_path"
    fi
}

test_missing_config_returns_4() {
    log_test "Error: Missing config returns exit code 4"
    reset_state
    rm -f "$ACT_REPOS_DIR/tool.yaml"

    local exit_code=0
    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1 || exit_code=$?

    # Recreate for other tests
    touch "$ACT_REPOS_DIR/tool.yaml"

    if [[ "$exit_code" -eq 4 ]]; then
        log_pass "Missing config returns exit code 4"
    else
        log_fail "Expected exit code 4 but got: $exit_code"
    fi
}

test_unknown_platform_returns_4() {
    log_test "Error: Unknown platform returns exit code 4"
    reset_state

    local exit_code=0
    act_run_native_build "tool" "freebsd/amd64" "v1.0.0" "run1" >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 4 ]]; then
        log_pass "Unknown platform returns exit code 4"
    else
        log_fail "Expected exit code 4 but got: $exit_code"
    fi
}

# ============================================================================
# Test Cases: Result JSON Structure
# ============================================================================

test_result_json_has_required_fields() {
    log_test "Result JSON: has all required fields"
    reset_state

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local has_all=true
    for field in tool platform host method status exit_code duration_seconds artifact_path log_file; do
        if ! echo "$result" | jq -e "has(\"$field\")" >/dev/null 2>&1; then
            log_fail "Missing field: $field"
            has_all=false
        fi
    done

    if $has_all; then
        log_pass "All required fields present"
    fi
}

test_result_json_correct_platform() {
    log_test "Result JSON: platform matches input"
    reset_state

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local platform
    platform=$(echo "$result" | jq -r '.platform')

    if [[ "$platform" == "darwin/arm64" ]]; then
        log_pass "Platform correct: darwin/arm64"
    else
        log_fail "Expected darwin/arm64 but got: $platform"
    fi
}

test_result_json_method_native() {
    log_test "Result JSON: method is 'native'"
    reset_state

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local method
    method=$(echo "$result" | jq -r '.method')

    if [[ "$method" == "native" ]]; then
        log_pass "Method is 'native'"
    else
        log_fail "Expected 'native' but got: $method"
    fi
}

test_result_json_success_has_artifact() {
    log_test "Result JSON: success includes artifact_path"
    reset_state

    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || true

    local artifact_path
    artifact_path=$(echo "$result" | jq -r '.artifact_path')

    if [[ "$artifact_path" == *"$ACT_ARTIFACTS_DIR"* ]]; then
        log_pass "Success result has artifact_path"
    else
        log_fail "Expected artifact in $ACT_ARTIFACTS_DIR but got: $artifact_path"
    fi
}

test_rust_derives_build_target_and_dsr_env() {
    log_test "Rust: CARGO_BUILD_TARGET and DSR_TARGET_* derived from the platform"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_BUILD_CMD="cargo build --release"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_capture)

    if [[ "$cmd" == *'export "CARGO_BUILD_TARGET=aarch64-apple-darwin"'* && \
          "$cmd" == *'export "DSR_TARGET_PLATFORM=darwin/arm64"'* && \
          "$cmd" == *'export "DSR_TARGET_OS=darwin"'* && \
          "$cmd" == *'export "DSR_TARGET_ARCH=arm64"'* ]]; then
        log_pass "Derived CARGO_BUILD_TARGET and DSR_TARGET_* are exported"
    else
        log_fail "Expected derived target env in: $cmd"
    fi
}

test_rust_derive_build_target_opt_out() {
    log_test "Rust: derive_cargo_build_target: false suppresses the derived triple"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_BUILD_CMD="cargo build --release"
    MOCK_DERIVE_OPT="false"

    act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_capture)

    if [[ "$cmd" != *'export "CARGO_BUILD_TARGET='* && \
          "$cmd" == *'export "DSR_TARGET_PLATFORM=darwin/arm64"'* ]]; then
        log_pass "Opt-out keeps the build untargeted while DSR_TARGET_* remain"
    else
        log_fail "Expected no derived CARGO_BUILD_TARGET in: $cmd"
    fi
}

test_windows_rejects_posix_source_root() {
    log_test "Windows: POSIX source root is rejected before any remote work"
    reset_state
    MOCK_LOCAL_PATH="/dp/tool"

    local result status=0
    result=$(act_run_native_build "tool" "windows/amd64" "v1.0.0" "run1" 2>/dev/null) || status=$?

    if [[ $status -eq 4 && "$result" == *"drive-qualified"* && ! -f "$SSH_ARGS_FILE" ]]; then
        log_pass "POSIX root on a Windows host fails fast with an actionable error"
    else
        log_fail "Expected exit 4 with drive-qualified error, got status=$status result=$result"
    fi
}

test_rust_linux_glibc_floor_shim_injected() {
    log_test "Rust linux: glibc floor shim staged and env exported by default"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_BUILD_CMD="cargo build --release"
    MOCK_ARTIFACT_KIND="elf-amd64"

    act_run_native_build "tool" "linux/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_capture)

    if [[ "$cmd" == *"DSR_ZIG_SHIM_EOF"* && \
          "$cmd" == *'export "DSR_ZIG_TARGET=x86_64-unknown-linux-gnu.2.28"'* && \
          "$cmd" == *"/.dsr-bin':\"\$PATH\""* ]]; then
        log_pass "Default 2.28 floor stages the cargo shim and PATH override"
    else
        log_fail "Expected glibc floor shim in: $cmd"
    fi
}

test_rust_linux_glibc_floor_native_opt_out() {
    log_test "Rust linux: linux_glibc_floor: native disables the shim"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_BUILD_CMD="cargo build --release"
    MOCK_GLIBC_FLOOR="native"
    MOCK_ARTIFACT_KIND="elf-amd64"

    act_run_native_build "tool" "linux/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_capture)

    if [[ "$cmd" != *"DSR_ZIG_SHIM_EOF"* && "$cmd" != *"DSR_ZIG_TARGET"* ]]; then
        log_pass "native opt-out builds against the host glibc"
    else
        log_fail "Expected no glibc floor shim in: $cmd"
    fi
}

test_rust_linux_glibc_floor_skips_musl() {
    log_test "Rust linux: musl targets get no glibc floor"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_BUILD_CMD="cargo build --release"
    MOCK_PLATFORM_ENV="CARGO_BUILD_TARGET=x86_64-unknown-linux-musl"
    MOCK_ARTIFACT_KIND="elf-amd64"

    act_run_native_build "tool" "linux/amd64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_capture)

    if [[ "$cmd" != *"DSR_ZIG_TARGET"* ]]; then
        log_pass "musl target is already portable; no floor applied"
    else
        log_fail "Expected no glibc floor for musl in: $cmd"
    fi
}

test_rust_linux_glibc_floor_skips_operator_linker() {
    log_test "Rust linux: an operator cross toolchain suppresses the floor"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_BUILD_CMD="cargo build --release"
    MOCK_PLATFORM_ENV=$'CARGO_BUILD_TARGET=aarch64-unknown-linux-gnu\nCARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc'
    MOCK_ARTIFACT_KIND="elf-arm64"

    act_run_native_build "tool" "linux/arm64" "v1.0.0" "run1" >/dev/null 2>&1

    local cmd
    cmd=$(get_ssh_capture)

    if [[ "$cmd" != *"DSR_ZIG_TARGET"* && "$cmd" == *'export "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc"'* ]]; then
        log_pass "Configured cross linker owns the libc baseline; floor skipped"
    else
        log_fail "Expected operator toolchain to suppress floor in: $cmd"
    fi
}

test_collection_rejects_wrong_arch() {
    log_test "Collection: wrong-architecture artifact is refused"
    reset_state
    MOCK_LANGUAGE="rust"
    MOCK_BINARY_NAME="mytool"
    MOCK_BUILD_CMD="cargo build --release"
    MOCK_ARTIFACT_KIND="elf-amd64"

    local result status=0
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1" 2>/dev/null) || status=$?

    local json_status
    json_status=$(jq -r '.status' <<< "$result" 2>/dev/null)

    if [[ "$json_status" == "failed" && $status -eq 7 ]]; then
        log_pass "An x86-64 ELF cannot ship under a darwin/arm64 name"
    else
        log_fail "Expected failed/7 for wrong-arch artifact, got status=$status json=$result"
    fi
}

test_glibc_version_helpers() {
    log_test "glibc helpers: max version extraction and comparison"
    local probe="$MOCK_DIR/glibc-probe.bin"
    printf 'junkGLIBC_9.9junk\0GLIBC_2.17\0GLIBC_2.2.5\0GLIBC_2.34\0GLIBC_PRIVATE\0GLIBC_ABI_DT_RELR\0' > "$probe"

    local max_version
    max_version=$(_act_max_glibc_version "$probe")

    if [[ "$max_version" == "2.34" ]] && \
       _act_glibc_version_le "2.34" "2.34" && \
       _act_glibc_version_le "2.28" "2.34" && \
       ! _act_glibc_version_le "2.34" "2.28" && \
       ! _act_glibc_version_le "2.2.5" "2.2" && \
       _act_glibc_version_le "2.2.5" "2.3"; then
        log_pass "NUL-token scan finds 2.34 and ordering is numeric"
    else
        log_fail "glibc helpers misbehaved: max=$max_version"
    fi
}

test_windows_strict_cargo_metadata_command() {
    log_test "Strict Cargo metadata: Windows command is locked and offline"
    reset_state

    local command_file="$MOCK_DIR/windows_metadata_command.txt"
    local status=0
    (
        _act_is_windows_host() { return 0; }
        _act_ssh_exec() {
            printf '%s\n' "$(_test_decode_remote_command "$2")" >> "$command_file"
            printf '%s\n' 'C:\build\source'
            printf '%s\n' '{"workspace_root":"C:\\\\build\\\\source","packages":[{"manifest_path":"C:\\\\build\\\\source\\\\Cargo.toml","source":null}]}'
        }
        _act_validate_strict_cargo_source_closure \
            "wlap" "C:/build/source" '[]' >/dev/null
    ) 2>/dev/null || status=$?

    if [[ $status -eq 0 ]] && \
       grep -Fq "if (-not (Test-Path -LiteralPath \$strict))" "$command_file" && \
       grep -Fq "if (-not (Test-Path -LiteralPath \$dest))" "$command_file" && \
       grep -Fq "contains ambient configuration" "$command_file" && \
       grep -Fq "\$env:CARGO_HOME=\$strict" "$command_file" && \
       grep -Fq "Set-Location -LiteralPath 'C:\build\source'; Write-Output ((Get-Location).Path)" \
            "$command_file" && \
       ! grep -Fq 'physical_source_root=' "$command_file" && \
       grep -Fq "cargo metadata --locked --offline --all-features --format-version 1 --manifest-path 'C:\build\source\Cargo.toml'" \
            "$command_file"; then
        log_pass "Windows strict metadata command is locked and offline"
    else
        log_fail "Windows strict metadata command was not constructed safely"
    fi
}

# ============================================================================
# Run All Tests
# ============================================================================

test_windows_split_target_and_collection() {
    log_test "Windows split storage preserves source binding and initializes collection"
    local result status=0
    result=$(
        source "$SRC_DIR/config.sh"
        config_windows_storage_json() {
            printf '%s' '{"drive":"R","source_drive":"C","server":"192.0.2.1","export":"/owned/builds","source_budget_bytes":2147483648,"source_reserve_bytes":8589934592,"target_min_free_bytes":21474836480}'
        }
        reset_state
        local canonical='C:/owned/run/.cargo-target-windows-amd64' target command
        target=$(_act_windows_short_target_directory mock-windows "$canonical" \
            12345678-1234-4234-8234-123456789abc windows/amd64) || exit 1
        [[ "$target" == R:/d/t/12345678-1234-4234-8234-123456789abc/amd64 ]] || exit 2
        command=$(get_ssh_cmd)
        [[ "$command" == *"\$root='R:/'"* && "$command" == *"'$canonical'"* &&
           "$command" == *"Build scratch is not a plain directory"* ]] || exit 3
        MOCK_SSH_STREAM_FILE="$MOCK_DIR/split-stream-input"
        MOCK_ARTIFACT_KIND=pe-amd64 write_mock_artifact "$MOCK_SSH_STREAM_FILE"
        _act_stream_remote_windows_file mock-windows "$target/tool.exe" > "$MOCK_DIR/split-stream-output" || exit 4
        cmp "$MOCK_SSH_STREAM_FILE" "$MOCK_DIR/split-stream-output" || exit 5
        command=$(get_raw_ssh_args)
        [[ "$command" == *"DSR NFS mapping identity mismatch"* &&
           "$command" == *"File]::OpenRead"* && "$command" == *'-o fileaccess=777'* ]] || exit 6
        printf 'split-target-and-binary-collection-pass'
    ) || status=$?
    if [[ $status -eq 0 && "$result" == split-target-and-binary-collection-pass ]]; then
        log_pass "Mapped output retains canonical source marker and binary-safe initialized collection"
    else
        log_fail "Split target/collection: status=$status result=$result"
    fi
}

test_windows_split_source_budget() {
    log_test "Windows source admission charges retained archives and sibling allocations"
    local mode result status script expected
    if ! command -v pwsh >/dev/null; then log_fail "PowerShell required for source admission tests"; return; fi
    script=$(
        _act_windows_storage_config() {
            printf '%s' '{"source_drive":"C","source_budget_bytes":2147483648,"source_reserve_bytes":8589934592}'
        }
        _act_windows_source_budget_script fixture C:/owned/run 400000000 20000
    )
    for mode in valid sibling_overflow low_source; do
        status=0
        expected=ADMITTED
        [[ "$mode" == valid ]] || expected='Source archives and sibling allocation exceed split-storage admission'
        result=$(
            {
                printf "\$ErrorActionPreference='Stop'; \$mode='%s';\n" "$mode"
                cat <<'POWERSHELL'
function Test-Path { return ($mode -eq 'sibling_overflow') }
function Get-ChildItem { return [pscustomobject]@{Attributes=0;PSIsContainer=$false;Length=1500000000} }
function Get-CimInstance { $free=if($mode -eq 'low_source'){8800000000}else{12GB}; return [pscustomobject]@{FreeSpace=$free} }
try {
POWERSHELL
                printf '%s\n' "$script"
                printf '%s\n\n' 'Write-Output ADMITTED } catch { Write-Output $_.Exception.Message }'
            } | pwsh -NoLogo -NoProfile -NonInteractive -Command -
        ) || status=$?
        result=$(printf '%s' "$result" | tr -d '\r')
        if [[ $status -eq 0 && "$result" == "$expected" ]]; then
            log_pass "Source allocation $mode causal branch"
        else
            log_fail "Source allocation $mode: status=$status result=$result expected=$expected"
        fi
    done
}

test_windows_cache_junction_identity() {
    log_test "Windows cache junctions must resolve to the admitted ambient targets"
    local mode script result expected status
    script=$(_act_windows_cache_junction_guard_script C:/owned/run/.cargo-home true) || { log_fail "Cache guard generation failed"; return; }
    for mode in valid wrong_target plain_directory; do
        expected=ADMITTED
        [[ "$mode" != wrong_target ]] || expected='Strict Cargo cache junction target mismatch'
        [[ "$mode" != plain_directory ]] || expected='Strict Cargo cache junction authority missing'
        status=0
        result=$(
            {
                printf "\$mode='%s';\n" "$mode"
                cat <<'POWERSHELL'
$env:CARGO_HOME='C:/ambient'
function Test-Path { return $true }
function Join-Path { param($Path,$ChildPath); return "$Path/$ChildPath" }
function Resolve-Path { param($LiteralPath); return [pscustomobject]@{ProviderPath=$LiteralPath} }
function Get-Item {
    param($LiteralPath)
    $name=($LiteralPath -split '/')[-1]
    $target=if($mode -eq 'wrong_target'){"D:/foreign/$name"}else{"C:/ambient/$name"}
    $attributes=if($mode -eq 'plain_directory'){0}else{1024}
    return [pscustomobject]@{PSIsContainer=$true;Attributes=$attributes;Target=@($target)}
}
try {
POWERSHELL
                printf '%s\n' "$script"
                printf '%s\n\n' 'Write-Output ADMITTED } catch { Write-Output $_.Exception.Message }'
            } | pwsh -NoLogo -NoProfile -NonInteractive -Command -
        ) || status=$?
        result=$(printf '%s' "$result" | tr -d '\r')
        if [[ $status -eq 0 && "$result" == "$expected" ]]; then
            log_pass "Cache junction $mode causal branch"
        else
            log_fail "Cache junction $mode: status=$status result=$result expected=$expected"
        fi
    done
}

main() {
    if [[ "${1:-}" == --windows-storage-only ]]; then
        test_windows_split_target_and_collection
        test_windows_split_source_budget
        test_windows_cache_junction_identity
        printf 'Windows storage tests: passed=%s failed=%s fixtures=%s\n' "$PASS_COUNT" "$FAIL_COUNT" "$MOCK_DIR"
        [[ "$FAIL_COUNT" -eq 0 ]]
        return $?
    fi
    if [[ "${1:-}" == --profile-env-only ]]; then
        test_frankenterm_profile_override_rejection
        test_profile_overrides_preserve_ordinary_and_other_tools
        printf 'Profile environment tests: passed=%s failed=%s fixtures=%s\n' "$PASS_COUNT" "$FAIL_COUNT" "$MOCK_DIR"
        [[ "$FAIL_COUNT" -eq 0 ]]
        return $?
    fi
    if [[ "${1:-}" == --sdk-env-only ]]; then
        test_rust_build_influence_name_xwin_boundaries
        test_unix_rust_sdk_environment
        test_windows_rust_sdk_environment
        test_unix_strict_rust_forces_out_of_snapshot_target_dir
        test_unix_strict_rust_executes_xwin_sanitizer_before_exports
        test_windows_strict_rust_forces_out_of_snapshot_target_dir
        test_windows_rust_isolation_receipt_matches_command
        test_strict_native_source_binding
        printf 'SDK environment tests: passed=%s failed=%s fixtures=%s\n' "$PASS_COUNT" "$FAIL_COUNT" "$MOCK_DIR"
        [[ "$FAIL_COUNT" -eq 0 ]]
        return $?
    fi
    if [[ "${1:-}" == --windows-family-only ]]; then
        test_rust_build_influence_name_xwin_boundaries
        test_frankenterm_windows_archive_manifest
        printf 'Windows family parser tests: passed=%s failed=%s fixtures=%s\n' "$PASS_COUNT" "$FAIL_COUNT" "$MOCK_DIR"
        [[ "$FAIL_COUNT" -eq 0 ]]
        return $?
    fi
    echo "================================================================"
    echo "  act_runner.sh Native Build Unit Tests"
    echo "================================================================"

    # Unix command construction
    test_unix_cd_command
    test_unix_env_export_syntax
    test_unix_rust_unsets_ambient_cargo_path_env
    test_unix_rust_isolation_guards_ram_backed_root
    test_unix_rust_isolation_honors_host_build_root
    test_unix_rust_isolation_rejects_invalid_host_build_root
    test_unix_rust_keeps_configured_cargo_path_env
    test_unix_rust_isolation_executes_outside_operator_config
    test_windows_rust_isolation_receipt_matches_command
    test_frankenterm_profile_override_rejection
    test_profile_overrides_preserve_ordinary_and_other_tools
    test_rust_build_influence_name_xwin_boundaries
    test_unix_rust_sdk_environment
    test_windows_rust_sdk_environment
    test_frankenterm_windows_archive_manifest
    test_unix_strict_rust_forces_out_of_snapshot_target_dir
    test_unix_strict_rust_executes_xwin_sanitizer_before_exports
    test_windows_strict_rust_forces_out_of_snapshot_target_dir
    test_strict_native_source_binding
    test_unix_strict_validation_failure_stops_build
    test_windows_strict_validation_failure_stops_build
    test_strict_collector_keeps_symlink_victim_unchanged
    test_strict_collector_rejects_partial_producer_failure
    test_strict_collection_loop_streams_every_remote_artifact
    test_strict_windows_bare_name_retry_uses_fresh_destination
    test_unix_chained_with_and
    test_unix_host_path_override
    test_unix_fallback_to_local_path

    # Windows command construction
    test_windows_build_guard_transport_and_timeout_validation
    test_windows_cd_command
    test_windows_env_set_syntax
    test_windows_slash_conversion
    test_windows_rsync_path_conversion
    test_windows_rsync_probe_uses_where
    test_windows_sync_uses_cygdrive_remote_path
    test_sync_uses_gitignore_exclude_file_by_default
    test_sync_can_disable_gitignore_exclude_file

    # Path handling
    test_path_with_spaces_unix
    test_path_with_single_quote

    # SCP commands
    test_scp_unix_artifact_path
    test_go_artifact_path_honors_gobin
    test_scp_rust_artifact_path
    test_scp_rust_artifact_path_with_absolute_cargo_target_dir
    test_scp_rust_artifact_path_with_relative_cargo_target_dir
    test_scp_rust_artifact_path_with_cargo_build_target
    test_scp_rust_artifact_path_with_custom_profile
    test_scp_windows_exe_extension
    test_scp_windows_forward_slash_path

    # Host detection
    test_host_detection_darwin
    test_host_detection_windows
    test_host_detection_linux
    test_host_detection_unknown

    # Host selection (health/capacity-aware)
    test_host_selection_selector_wins
    test_host_selection_prefers_mapped_host
    test_host_selection_falls_back_to_mapping
    test_host_selection_can_be_disabled

    # Error handling
    test_ssh_failure_propagates
    test_ssh_failure_json_status
    test_ssh_timeout_returns_5
    test_ssh_timeout_json_status
    test_scp_failure_returns_7
    test_scp_failure_empty_artifact_path
    test_missing_config_returns_4
    test_unknown_platform_returns_4

    # Result JSON structure
    test_result_json_has_required_fields
    test_result_json_correct_platform
    test_result_json_method_native
    test_result_json_success_has_artifact
    test_windows_strict_cargo_metadata_command
    test_windows_split_target_and_collection
    test_windows_split_source_budget
    test_windows_cache_junction_identity

    # Derived build identity, Windows path guard, glibc floor (issues #7/#8/#9)
    test_rust_derives_build_target_and_dsr_env
    test_rust_derive_build_target_opt_out
    test_windows_rejects_posix_source_root
    test_rust_linux_glibc_floor_shim_injected
    test_rust_linux_glibc_floor_native_opt_out
    test_rust_linux_glibc_floor_skips_musl
    test_rust_linux_glibc_floor_skips_operator_linker
    test_collection_rejects_wrong_arch
    test_glibc_version_helpers

    # Summary
    echo ""
    echo "================================================================"
    echo "  Summary"
    echo "================================================================"
    echo -e "  ${GREEN}Passed:${NC}  $PASS_COUNT"
    echo -e "  ${RED}Failed:${NC}  $FAIL_COUNT"

    # Cleanup
    if [[ "${DSR_TEST_KEEP_TEMP:-0}" != 1 ]]; then
        rm -rf "$MOCK_DIR"
    else
        printf 'Retained fixtures: %s\n' "$MOCK_DIR"
    fi

    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
