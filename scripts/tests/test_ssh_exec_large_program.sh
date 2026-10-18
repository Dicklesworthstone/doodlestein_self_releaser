#!/usr/bin/env bash
# test_ssh_exec_large_program.sh - Large Unix programs never travel in argv
#
# Regression coverage for dsr-00n2: the strict Cargo metadata program is larger
# than Linux's 128 KiB single-argument limit (MAX_ARG_STRLEN), and _act_ssh_exec
# passed it as the one ssh command argument, so the remote login shell's `-c`
# exec failed with "Argument list too long" before any build started.
#
# Covered here:
#   - the actual generated strict metadata program is routed to stdin;
#   - small commands keep the original argv transport (`ssh -n ... cmd`);
#   - a large program reaches ssh only on stdin (ssh -T, no pty), wrapped in a
#     brace group that the remote login shell (`exec "$SHELL" -s`) parses
#     before running;
#   - real local execution of a >128 KiB program via stdin keeps exit status and
#     gives the program /dev/null as stdin; a syntax error runs nothing; the
#     deadline still returns the timeout status;
#   - the actual generated metadata program runs through stdin up to its first
#     real command;
#   - on Linux, the same program in argv fails with E2BIG (negative control).
#
# Usage: ./scripts/tests/test_ssh_exec_large_program.sh
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../src/act_runner.sh
source "$PROJECT_ROOT/src/act_runner.sh"

TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

log_pass() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [PASS] $*" >&2; }
log_fail() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [FAIL] $*" >&2; }
log_info() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO] $*" >&2; }

check() {
    local msg="$1"
    shift
    ((TEST_COUNT++))
    if "$@"; then
        ((PASS_COUNT++))
        log_pass "$msg"
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
    fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-ssh-large-program.XXXXXXXX") || exit 1
log_info "Retained fixtures: $WORK"
mkdir -p "$WORK/bin"

# A recording ssh executable (a shell function would not survive `timeout`).
cat > "$WORK/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$DSR_TEST_SSH_DIR/ssh.args"
cat > "$DSR_TEST_SSH_DIR/ssh.stdin"
exit "${DSR_TEST_SSH_RC:-0}"
MOCK
chmod +x "$WORK/bin/ssh"
PATH="$WORK/bin:$PATH"

# Each case records into its own new directory; nothing is ever removed.
new_ssh_capture() {
    DSR_TEST_SSH_DIR=$(mktemp -d "$WORK/ssh-capture.XXXXXXXX") || return 1
    export DSR_TEST_SSH_DIR
}

TEST_LOCAL_HOST=false
_act_is_windows_host() { return 1; }
_act_is_local_host() { [[ "$TEST_LOCAL_HOST" == true ]]; }
_act_get_ssh_destination() { printf 'builder@test-host\n'; }

byte_length() ( LC_ALL=C; printf '%s' "${#1}" )

# The same program _act_strict_cargo_metadata_json builds for a Unix host.
actual_metadata_program() {
    local source_root="$1" program body
    program=$(_act_unix_private_cargo_home_script "$source_root" metadata-0123456789abcdef) || return 1
    body=$(_act_unix_cargo_metadata_body "cargo build --release --locked" "CARGO_BUILD_JOBS=12") || return 1
    program+=$'\n'"$body"$'\n''printf '\''%s\n'\'' "$physical_source_root"; cat "$strict_home/.dsr-cargo-metadata.json"'
    printf '%s' "$program"
}

# Padding keeps the payload inert: a quoted heredoc to the null command.
padded_program() {
    local pad
    pad=$(head -c 140000 /dev/zero | tr '\0' 'x')
    printf 'set -e\n: <<'\''DSR_PAD'\''\n%s\nDSR_PAD\n%s\n' "$pad" "$1"
}

test_actual_metadata_program_routes_to_stdin() {
    local program bytes
    program=$(actual_metadata_program /data/dsr-build-root/demo-1.0.0/source) || { check "metadata program generated" false; return; }
    bytes=$(byte_length "$program")
    log_info "Generated strict metadata program: $bytes bytes"
    check "Generated metadata program exceeds the argv program bound" test "$bytes" -gt "${_ACT_UNIX_ARGV_PROGRAM_MAX_BYTES:-0}"
    check "Generated metadata program is routed to stdin" _act_unix_program_needs_stdin "$program"
}

argv_kept() { ! _act_unix_program_needs_stdin "$1"; }

test_argv_bound_counts_bytes_at_the_boundary() {
    local at_bound over_bound euros locale_before utf8_locale=""
    at_bound=$(head -c 65535 /dev/zero | tr '\0' 'a')
    over_bound=$(head -c 65536 /dev/zero | tr '\0' 'a')
    check "65535-byte command keeps argv" argv_kept "$at_bound"
    check "65536-byte command goes to stdin" _act_unix_program_needs_stdin "$over_bound"
    for candidate in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if LC_ALL=$candidate bash -c '[[ "$(printf "\xe2\x82\xac" | wc -m | tr -d " ")" == 1 ]]' 2>/dev/null; then
            utf8_locale=$candidate
            break
        fi
    done
    if [[ -z "$utf8_locale" ]]; then
        log_info "SKIP UTF-8 byte-vs-character check: no UTF-8 locale on this host"
        return
    fi
    # 30,000 euro signs: 30,000 characters but 90,000 bytes.
    euros=$(head -c 30000 /dev/zero | tr '\0' 'x' | sed 's/x/€/g')
    locale_before=$(LC_ALL=$utf8_locale; printf '%s' "${#euros}")
    check "UTF-8 fixture is 30000 characters under $utf8_locale" test "$locale_before" -eq 30000
    check "Bound counts bytes, not characters, under $utf8_locale" bash -c '
        LC_ALL=$1; source "$2/src/act_runner.sh"; _act_unix_program_needs_stdin "$3" &&
        [[ "$LC_ALL" == "$1" && ${#3} -eq 30000 ]]' _ "$utf8_locale" "$PROJECT_ROOT" "$euros"
}

test_small_command_keeps_argv() {
    TEST_LOCAL_HOST=false
    new_ssh_capture || return
    _act_ssh_exec test-host 'printf small' 30 </dev/null
    check "Small command keeps ssh -n" grep -qx -- '-n' "$DSR_TEST_SSH_DIR/ssh.args"
    check "Small command is the final ssh argument" test "$(tail -1 "$DSR_TEST_SSH_DIR/ssh.args")" = 'printf small'
    check "Small command sends nothing on stdin" test ! -s "$DSR_TEST_SSH_DIR/ssh.stdin"
}

test_large_program_reaches_ssh_only_on_stdin() {
    local program expected longest
    TEST_LOCAL_HOST=false
    program=$(actual_metadata_program /data/dsr-build-root/demo-1.0.0/source) || return
    new_ssh_capture || return
    _act_ssh_exec test-host "$program" 30 </dev/null
    local args="$DSR_TEST_SSH_DIR/ssh.args"
    check "ssh was invoked for the large program" test -s "$args"
    # shellcheck disable=SC2016 # the remote command is literal
    check "Remote command is the login shell reading stdin" test "$(tail -1 "$args")" = 'exec "$SHELL" -s'
    check "Large program disables pty allocation (ssh -T)" grep -qx -- '-T' "$args"
    check "Large program does not use ssh -n" bash -c '! grep -qx -- -n "$1"' _ "$args"
    longest=$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$args")
    check "No ssh argument approaches the argv bound ($longest bytes)" test "$longest" -lt 4096
    printf -v expected '{\n%s\n} </dev/null\n' "$program"
    printf '%s' "$expected" > "$DSR_TEST_SSH_DIR/expected.stdin"
    check "ssh stdin is exactly the wrapped program" cmp -s "$DSR_TEST_SSH_DIR/expected.stdin" "$DSR_TEST_SSH_DIR/ssh.stdin"
    check "Remote ssh exit status is returned" remote_exit_status_is_returned "$program"
}

# A subshell, not `bash -c`: the program itself must never become an argument.
remote_exit_status_is_returned() (
    DSR_TEST_SSH_RC=7
    export DSR_TEST_SSH_RC
    new_ssh_capture || exit 1
    _act_ssh_exec test-host "$1" 30 </dev/null
    test $? -eq 7
)

test_large_program_runs_locally_on_stdin() {
    local program output rc=0
    TEST_LOCAL_HOST=true
    program=$(padded_program 'printf "reached stdin=[%s]\n" "$(cat)"; exit 7')
    check "Local fixture program exceeds 128 KiB" test "$(byte_length "$program")" -gt 131072
    output=$(printf 'caller stdin must not leak\n' | _act_ssh_exec local-host "$program" 60 2>/dev/null) || rc=$?
    check "Local large program keeps its exit status" test "$rc" -eq 7
    check "Local large program ran and saw /dev/null on stdin" grep -qx 'reached stdin=\[\]' <<< "$output"
    TEST_LOCAL_HOST=false
}

test_large_program_with_syntax_error_runs_nothing() {
    local program output rc=0
    TEST_LOCAL_HOST=true
    # Line-by-line stdin execution would print the marker before reaching the
    # error; the brace group must refuse the whole program instead. A stray
    # `done` is a parse error in bash and zsh alike (`if then fi` is valid zsh).
    program=$(padded_program 'printf "ran before the syntax error\n"
done')
    output=$(_act_ssh_exec local-host "$program" 60 2>&1) || rc=$?
    check "Large program with a syntax error fails" test "$rc" -ne 0
    check "No part of a program with a syntax error runs" bash -c '! grep -q "ran before the syntax error" <<< "$1"' _ "$output"
    TEST_LOCAL_HOST=false
}

test_large_program_timeout_status() {
    local program rc=0 started elapsed
    if [[ -z "$(_act_timeout_cmd)" ]]; then
        log_info "SKIP large program timeout: no timeout command on this host"
        return
    fi
    TEST_LOCAL_HOST=true
    program=$(padded_program 'sleep 30')
    started=$(date +%s)
    _act_ssh_exec local-host "$program" 2 >/dev/null 2>&1 || rc=$?
    elapsed=$(( $(date +%s) - started ))
    check "Large program past its deadline returns the timeout status (rc=$rc)" test "$rc" -eq 124
    check "Large program deadline is enforced (${elapsed}s)" test "$elapsed" -lt 20
    TEST_LOCAL_HOST=false
}

test_actual_metadata_program_reaches_first_command() {
    local source_root="$WORK/missing-snapshot/source" program errors rc=0
    TEST_LOCAL_HOST=true
    program=$(actual_metadata_program "$source_root") || return
    _act_ssh_exec local-host "$program" 60 > "$WORK/metadata.out" 2> "$WORK/metadata.err" || rc=$?
    errors=$(cat "$WORK/metadata.err")
    check "Actual metadata program fails only at its missing source root" test "$rc" -ne 0
    check "Failure is the first command (cd), not transport or parsing" bash -c '
        grep -q "missing-snapshot/source" <<< "$1" &&
        ! grep -qiE "argument list too long|syntax error|unexpected end of file" <<< "$1"' _ "$errors"
    TEST_LOCAL_HOST=false
}

test_linux_argv_negative_control() {
    local program rc=0 errors
    if [[ "$(uname -s)" != Linux ]]; then
        log_info "SKIP Linux argv negative control on $(uname -s) (no per-argument exec limit)"
        return
    fi
    program=$(actual_metadata_program "$WORK/missing-snapshot/source") || return
    errors=$(bash -lc "$program" 2>&1 >/dev/null) || rc=$?
    check "Linux refuses the same program in argv (exit 126)" test "$rc" -eq 126
    check "Linux reports Argument list too long" grep -qi 'argument list too long' <<< "$errors"
}

log_info "Running large Unix program transport tests (dsr-00n2)"
test_actual_metadata_program_routes_to_stdin
test_argv_bound_counts_bytes_at_the_boundary
test_small_command_keeps_argv
test_large_program_reaches_ssh_only_on_stdin
test_large_program_runs_locally_on_stdin
test_large_program_with_syntax_error_runs_nothing
test_large_program_timeout_status
test_actual_metadata_program_reaches_first_command
test_linux_argv_negative_control

log_info "Results: $PASS_COUNT/$TEST_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
