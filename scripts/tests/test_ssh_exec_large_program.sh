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
#   - authentic lockfile selections above 128 KiB survive the private-cache
#     receiver, strict preparation receipt and ordinary native caller without
#     becoming Python/jq arguments or exported shell variables.
#   - coordinator matrix/Zig planning accepts large generated observers while
#     preserving target refusal, worker environment isolation and caller stdin.
#
# --metadata-interruption-only exercises real signalled SSH processes and
# descendant cleanup through strict metadata/source-closure admission.
# --metadata-admission-only exercises real target/task loops around a failed
# metadata service, including diagnostic serialization failure.
# Usage: ./scripts/tests/test_ssh_exec_large_program.sh [--cargo-selection-only|--coordinator-planning-only|--metadata-interruption-only|--metadata-admission-only]
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACT_RUNNER_MODULE="${DSR_TEST_ACT_RUNNER:-$PROJECT_ROOT/src/act_runner.sh}"
MODE=all
if [[ "${1:-}" == --cargo-selection-only && $# == 1 ]]; then
    MODE=cargo-selection
elif [[ "${1:-}" == --coordinator-planning-only && $# == 1 ]]; then
    MODE=coordinator-planning
elif [[ "${1:-}" == --metadata-interruption-only && $# == 1 ]]; then
    MODE=metadata-interruption
elif [[ "${1:-}" == --metadata-admission-only && $# == 1 ]]; then
    MODE=metadata-admission
elif (( $# != 0 )); then
    printf 'Usage: %s [--cargo-selection-only|--coordinator-planning-only|--metadata-interruption-only|--metadata-admission-only]\n' "$0" >&2
    exit 4
fi

# shellcheck source=../../src/act_runner.sh
source "$ACT_RUNNER_MODULE"

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

# A recording ssh executable exercises the same process boundary as real SSH.
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
        LC_ALL=$1; source "$2"; _act_unix_program_needs_stdin "$3" &&
        [[ "$LC_ALL" == "$1" && ${#3} -eq 30000 ]]' _ "$utf8_locale" "$ACT_RUNNER_MODULE" "$euros"
}

test_small_command_keeps_argv() {
    TEST_LOCAL_HOST=false
    new_ssh_capture || return
    _act_ssh_exec test-host 'printf small' 30 </dev/null
    check "Small command keeps ssh -n" grep -qx -- '-n' "$DSR_TEST_SSH_DIR/ssh.args"
    check "Small command is the final ssh argument" test "$(tail -1 "$DSR_TEST_SSH_DIR/ssh.args")" = 'printf small'
    check "Small command sends nothing on stdin" test ! -s "$DSR_TEST_SSH_DIR/ssh.stdin"
}

test_large_coordinator_planning() {
    local directory target environment padding command program status output input
    local bash_env target_status zig_status malformed_status
    directory=$(mktemp -d "$WORK/coordinator-planning.XXXXXXXX") || return 1
    target=x86_64-unknown-linux-gnu
    bash_env="$directory/worker-startup.sh"
    printf 'printf executed > %q\n' "$directory/startup-executed" > "$bash_env"
    # These are worker settings. Neither its startup files nor its PATH may
    # affect the coordinator's nonexecuting command selection.
    environment="CARGO_BUILD_TARGET=$target"$'\n'"DSR_TARGET_TRIPLE=$target"$'\n'"BASH_ENV=$bash_env"$'\n'"ENV=$bash_env"$'\n''PATH=/worker-only/compiler/bin'
    status=0
    _act_validate_native_target_command "cargo build --locked --target $target" "$environment" "$target" \
        > "$directory/small-target.out" 2> "$directory/small-target.err" || status=$?
    check "Small matrix command keeps its real target admission" test "$status" -eq 0
    check "Matrix target admission emits no compiler output" test ! -s "$directory/small-target.out"

    # The valid recipe itself is comfortably below MAX_ARG_STRLEN. Shell
    # quoting plus the production observer is what exceeds the process limit.
    # Keep the Cargo command literal; the large comment must never execute.
    printf -v padding '%60000s' ''
    command="cargo build --locked --target $target # $padding"
    program=$(_act_toolchain_identity_script target /dev/null "$command") || return 1
    check "Large recipe still fits one ordinary process argument" test "$(byte_length "$command")" -lt 131072
    check "Actual matrix observer exceeds the process argument limit" test "$(byte_length "$program")" -gt 131072
    target_status=0
    input=""
    {
        _act_validate_native_target_command "$command" "$environment" "$target" \
            > "$directory/large-target.out" 2> "$directory/large-target.err" || target_status=$?
        IFS= read -r input || true
    } <<< 'matrix caller input'
    check "Large matrix command is admitted without executing Cargo" test "$target_status" -eq 0
    check "Large matrix planning preserves caller input" test "$input" = 'matrix caller input'
    check "Large matrix planning emits no compiler output" test ! -s "$directory/large-target.out"

    malformed_status=0
    _act_validate_native_target_command "$command" "$environment" aarch64-unknown-linux-gnu \
        > "$directory/mismatch.out" 2> "$directory/mismatch.err" || malformed_status=$?
    check "Large matrix command still refuses a contradictory scheduled target" test "$malformed_status" -eq 4

    command="cargo zigbuild --release --target $target.2.28 # $padding"
    program=$(_act_toolchain_identity_script selection /dev/null "$command") || return 1
    check "Actual Zig observer exceeds the process argument limit" test "$(byte_length "$program")" -gt 131072
    zig_status=0
    input=""
    {
        _act_explicit_zigbuild_selection "$command" "$environment" \
            > "$directory/zig.json" 2> "$directory/zig.err" || zig_status=$?
        IFS= read -r input || true
    } <<< 'zig caller input'
    check "Large explicit Zig command is admitted without executing Cargo" test "$zig_status" -eq 0
    check "Large Zig selection preserves exact target and ABI floor" jq -e \
        '. == {rust_target:"x86_64-unknown-linux-gnu",zig_target:"x86_64-unknown-linux-gnu.2.28",glibc_floor:"2.28"}' \
        "$directory/zig.json"
    check "Large Zig planning preserves caller input" test "$input" = 'zig caller input'
    check "Worker startup hooks never execute during coordinator planning" test ! -e "$directory/startup-executed"

    status=0
    output=$(_act_explicit_zigbuild_selection 'cargo build --locked' "$environment" \
        2> "$directory/plain.err") || status=$?
    check "Ordinary Cargo commands still have no explicit Zig selection" test "$status:$output" = '0:null'
    status=0
    output=$(_act_explicit_zigbuild_selection "cargo zigbuild --target aarch64-unknown-linux-gnu.2.28 # $padding" \
        "$environment" 2> "$directory/zig-mismatch.err") || status=$?
    check "Large explicit Zig commands retain target disagreement refusal" test "$status" -ne 0
    check "Refused Zig selection emits no successful receipt" test -z "$output"
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

test_metadata_interruption() {
    python3 -I - "$ACT_RUNNER_MODULE" "$WORK" <<'PY'
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

module = Path(sys.argv[1]).resolve()
work = Path(sys.argv[2]) / 'metadata-interruption'
work.mkdir(mode=0o700)
bin_dir = work / 'bin'
bin_dir.mkdir()
checks, failures = 0, []


def check(label, valid):
    global checks
    checks += 1
    print(('PASS ' if valid else 'FAIL ') + label, flush=True)
    if not valid:
        failures.append(label)


# Only the remote Cargo operation is a service boundary. The generated
# production program, external SSH argv/stdin, owned supervisor, metadata
# decoder and source-closure status propagation are real. No compiler or
# authenticated dependency-source success is claimed by this transport test.
ssh = bin_dir / 'ssh'
ssh.write_text(r'''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
from pathlib import Path
case = Path(os.environ['DSR_METADATA_CASE'])
args = sys.argv[1:]
with (case / 'launches.jsonl').open('a') as stream:
    stream.write(json.dumps({'argv': args, 'pid': os.getpid()}) + '\n')
program = sys.stdin.buffer.read()
(case / 'program.sh').write_bytes(program)
if len(program) <= 131072 or args[-1] != 'exec "$SHELL" -s':
    raise SystemExit(97)
mode = os.environ['DSR_METADATA_MODE']
if mode in ('130', '143'):
    # Retire an actual receiver with SIGINT/SIGTERM while its ordinary child
    # ignores TERM. The production supervisor must drain that child before
    # returning the receiver's native cancellation status.
    ready = case / 'descendant.ready'
    child = subprocess.Popen([sys.executable, '-c',
        'import os,signal,sys,time; '
        'signal.signal(signal.SIGTERM,signal.SIG_IGN); '
        'open(sys.argv[1],"w").write(str(os.getpid())); time.sleep(60)', str(ready)])
    deadline = time.monotonic() + 5
    while not ready.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    if not ready.exists():
        raise SystemExit(97)
    # A complete-looking response must never override an unsuccessful exit.
    source = os.environ['DSR_METADATA_SOURCE']
    print(source, flush=True)
    print(json.dumps({'workspace_root': source, 'packages': [
        {'manifest_path': source + '/Cargo.toml', 'source': None}]}), flush=True)
    stopped = signal.SIGINT if mode == '130' else signal.SIGTERM
    signal.signal(stopped, signal.SIG_DFL)
    os.kill(os.getpid(), stopped)
elif mode == 'malformed':
    print('partial metadata')
elif mode == 'success':
    source = os.environ['DSR_METADATA_SOURCE']
    print(source)
    print(json.dumps({'workspace_root': source, 'packages': [
        {'manifest_path': source + '/Cargo.toml', 'source': None}]}))
else:
    raise SystemExit(int(mode))
''')
ssh.chmod(0o700)
driver = work / 'driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$1" || exit $?
_act_is_local_host() { return 1; }
_act_is_windows_host() { return 1; }
_act_get_ssh_destination() { printf '%s\n' fixture-metadata; }
case "$2" in
    metadata) _act_strict_cargo_metadata_json fixture "$DSR_METADATA_SOURCE" ;;
    closure) _act_validate_strict_cargo_source_closure fixture "$DSR_METADATA_SOURCE" '[]' ;;
    *) exit 97 ;;
esac
''')


def running(pid):
    observed = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True)
    return observed.returncode == 0 and bool(observed.stdout.strip()) and not observed.stdout.lstrip().startswith('Z')


for action in ('metadata', 'closure'):
    for mode in ('130', '143', '255', '124', '4', 'malformed', 'success'):
        case = work / (action + '-' + mode)
        case.mkdir()
        source = case / 'source'
        source.mkdir()
        environment = dict(os.environ, DSR_METADATA_CASE=str(case), DSR_METADATA_MODE=mode,
                           DSR_METADATA_SOURCE=str(source), DSR_SYNC_TIMEOUT='15', SHELL=shutil.which('bash'),
                           PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])
        result = subprocess.run(['bash', str(driver), str(module), action], env=environment,
                                capture_output=True, timeout=25, input=b'caller input must stay isolated\n')
        (case / 'stdout').write_bytes(result.stdout)
        (case / 'stderr').write_bytes(result.stderr)
        expected = int(mode) if mode in ('130', '143') else 0 if mode == 'success' else 4
        label = action + '/' + mode
        check(label + ': retains cancellation and existing ordinary refusal classification (actual %d, expected %d)' %
              (result.returncode, expected), result.returncode == expected)
        launches = [json.loads(row) for row in (case / 'launches.jsonl').read_text().splitlines()]
        check(label + ': exactly one bounded SSH argv carries the oversized production program on stdin',
              len(launches) == 1 and max(len(os.fsencode(arg)) for arg in launches[0]['argv']) < 65536
              and (case / 'program.sh').stat().st_size > 131072)
        if mode != 'success':
            check(label + ': failed receiver emits no accepted metadata or source receipt', result.stdout == b'')
        elif action == 'metadata':
            receipt = json.loads(result.stdout)
            check(label + ': valid service response retains the exact source binding',
                  receipt['source_root'] == str(source) and receipt['metadata']['workspace_root'] == str(source))
        if mode in ('130', '143'):
            pid = int((case / 'descendant.ready').read_text())
            check(label + ': owned TERM-resistant descendant is drained before return', not running(pid))

print('Metadata interruption: %d/%d passed' % (checks - len(failures), checks), flush=True)
raise SystemExit(bool(failures))
PY
}

test_metadata_admission() {
    command -v yq >/dev/null || { log_fail "Missing metadata admission test dependency: yq"; return 3; }
    python3 -I - "$ACT_RUNNER_MODULE" "$WORK" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

module = Path(sys.argv[1]).resolve()
work = Path(sys.argv[2]) / 'metadata-admission'
work.mkdir(mode=0o700)
checks, failures = 0, []


def check(label, valid):
    global checks
    checks += 1
    print(('PASS ' if valid else 'FAIL ') + label, flush=True)
    if not valid:
        failures.append(label)


# These helpers consume a source route already admitted by the coordinator.
# Keep canonical path construction, real recipe/target selection, task loops,
# metadata program generation and status policy in the test. Only the remote
# metadata service is substituted; this does not qualify snapshot creation or
# native compilation. The separate interruption test exercises actual signals.
driver = work / 'driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$1" || exit $?
act_load_repo_config metafixture || exit $?
run_id=01234567-89ab-4cde-8fab-0123456789ab
first_root=$(_act_strict_source_root_path "$ACT_REPO_LOCAL_PATH" metafixture "$run_id" first) || exit $?
later_root=$(_act_strict_source_root_path "$ACT_REPO_LOCAL_PATH" metafixture "$run_id" later) || exit $?
roots=$(jq -nc --arg first "$first_root" --arg later "$later_root" '{first:$first,later:$later}') || exit $?
printf '%s\n' "$roots" > "$DSR_METADATA_CASE/roots.json" || exit $?
real_jq=$(command -v jq) || exit $?
if [[ "$DSR_METADATA_SERIALIZER_FAIL" == 1 ]]; then
    jq() {
        local argument
        for argument in "$@"; do
            if [[ "$argument" == *'error: $error'* ]]; then
                printf '%s\n' diagnostic > "$DSR_METADATA_CASE/serializer.called" || return 97
                return 73
            fi
        done
        "$real_jq" "$@"
    }
fi
_act_ssh_exec() {
    local call_index source_root
    printf '%s\n' "$1" >> "$DSR_METADATA_CASE/calls" || return 97
    call_index=$(wc -l < "$DSR_METADATA_CASE/calls") || return 97
    printf '%s' "$2" > "$DSR_METADATA_CASE/programs/$call_index.sh" || return 97
    if [[ "$DSR_METADATA_MODE" != success ]]; then
        return "$DSR_METADATA_MODE"
    fi
    source_root=$("$real_jq" -r --arg host "$1" '.[$host]' "$DSR_METADATA_CASE/roots.json") || return 97
    printf '%s\n' "$source_root"
    "$real_jq" -nc --arg root "$source_root" '{workspace_root:$root,
      packages:[{manifest_path:($root+"/Cargo.toml"),source:null}]}'
}
case "$DSR_METADATA_ACTION" in
    target)
        _act_validate_strict_target_cargo_source_closure metafixture linux/amd64 1.0.0 first "$first_root" '[]'
        ;;
    tasks)
        hosts='{"linux/amd64@x86_64-unknown-linux-gnu":"first","linux/amd64@x86_64-unknown-linux-musl":"first","linux/arm64":"later"}'
        tasks='[{"key":"linux/amd64@x86_64-unknown-linux-gnu","platform":"linux/amd64","target_triple":"x86_64-unknown-linux-gnu"},{"key":"linux/amd64@x86_64-unknown-linux-musl","platform":"linux/amd64","target_triple":"x86_64-unknown-linux-musl"},{"key":"linux/arm64","platform":"linux/arm64","target_triple":"aarch64-unknown-linux-gnu"}]'
        _act_validate_strict_task_sources metafixture 1.0.0 "$run_id" "$roots" "$hosts" "$tasks" '[]'
        ;;
    *) exit 97 ;;
esac
''')

cases = [(action, mode, False) for action in ('target', 'tasks')
         for mode in ('130', '143', '255', '124', '4', 'success')]
cases += [('tasks', mode, True) for mode in ('130', '143')]
for action, mode, serializer_fail in cases:
    label = action + '/' + mode + ('/serializer-failure' if serializer_fail else '')
    case = work / label.replace('/', '-')
    config = case / 'config'
    (config / 'repos.d').mkdir(parents=True)
    (case / 'programs').mkdir()
    (case / 'checkout').mkdir()
    recipe = dict(tool_name='metafixture', repo='fixture/metafixture', language='rust',
                  local_path=str(case / 'checkout'), binary_name='metafixture',
                  build_cmd='cargo build --release --locked --offline',
                  targets=['linux/amd64', 'linux/arm64'],
                  target_triples={'linux/amd64': ['x86_64-unknown-linux-gnu', 'x86_64-unknown-linux-musl'],
                                  'linux/arm64': 'aarch64-unknown-linux-gnu'},
                  env={'CARGO_BUILD_JOBS': '2'})
    (config / 'repos.d/metafixture.yaml').write_text(json.dumps(recipe) + '\n')
    (config / 'hosts.yaml').write_text(json.dumps(dict(hosts={
        host: dict(platform='linux/amd64', connection='ssh', hostname='fixture.invalid',
                   build_root=str(case / host)) for host in ('first', 'later')})) + '\n')
    environment = dict(os.environ, DSR_CONFIG_DIR=str(config), ACT_CONFIG_DIR=str(config), ACT_REPOS_DIR=str(config / 'repos.d'),
                       DSR_HOSTS_FILE=str(config / 'hosts.yaml'), DSR_METADATA_CASE=str(case),
                       DSR_METADATA_ACTION=action, DSR_METADATA_MODE=mode,
                       DSR_METADATA_SERIALIZER_FAIL='1' if serializer_fail else '0')
    environment.pop('DSR_STRICT_BUILD_ROOT', None)
    result = subprocess.run(['bash', str(driver), str(module)], env=environment,
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
    (case / 'stdout').write_bytes(result.stdout)
    (case / 'stderr').write_bytes(result.stderr)
    expected = int(mode) if mode in ('130', '143') else 0 if mode == 'success' else 4
    check(label + ': original cancellation or ordinary refusal reaches the caller (actual %d, expected %d)' %
          (result.returncode, expected), result.returncode == expected)
    calls = (case / 'calls').read_text().splitlines() if (case / 'calls').exists() else []
    expected_calls = ['first', 'first'] + (['later'] if action == 'tasks' else []) if mode == 'success' else ['first']
    check(label + ': failure stops before the next compiler variant or host; success admits the complete route',
          calls == expected_calls)
    programs = list((case / 'programs').glob('*.sh'))
    check(label + ': each observed service call receives the actual oversized metadata program',
          len(programs) == len(expected_calls) and all(path.stat().st_size > 131072 for path in programs))
    if serializer_fail:
        check(label + ': failed diagnostic serialization cannot replace cancellation or emit a partial receipt',
              (case / 'serializer.called').is_file() and result.stdout == b'')
    elif action == 'tasks' and mode != 'success':
        try:
            receipt = json.loads(result.stdout)
        except (ValueError, UnicodeDecodeError):
            receipt = {}
        check(label + ': admission diagnostic remains non-successful and binds its original status',
              receipt.get('status') == 'error' and receipt.get('targets') == []
              and receipt.get('exit_code', result.returncode) == expected
              and (mode not in ('130', '143') or 'interrupted' in receipt.get('error', '')))
    else:
        check(label + ': no task or source receipt escapes a component-only admission call', result.stdout == b'')

print('Metadata target/task admission: %d/%d passed' % (checks - len(failures), checks), flush=True)
raise SystemExit(bool(failures))
PY
}

test_large_cargo_selection_receipts() {
    local tool
    for tool in python3 bash sh zsh jq yq; do
        command -v "$tool" >/dev/null || { log_fail "Missing Cargo selection test dependency: $tool"; return 3; }
    done
    python3 -I - "$ACT_RUNNER_MODULE" "$WORK" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys

module = Path(sys.argv[1]).resolve()
work = Path(sys.argv[2]) / 'cargo-selection'
work.mkdir(mode=0o700)
os.umask(0o077)
checks, failures = 0, []


def check(label, condition):
    global checks
    checks += 1
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    if not condition:
        failures.append(label)
    return condition


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identity(path):
    info = path.stat()
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns, digest(path))


def invoke(argv, environment, label, timeout=90):
    result = subprocess.run(list(map(str, argv)), env=environment, stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=timeout)
    (work / (label + '.stdout')).write_bytes(result.stdout)
    (work / (label + '.stderr')).write_bytes(result.stderr)
    if result.returncode:
        print(label + ' exit=' + str(result.returncode) + '\n' +
              result.stderr.decode(errors='replace')[-1800:], flush=True)
    return result


def document(result):
    try:
        # One complete document is required; log chatter or a second receipt
        # on stdout must not be accepted by looking only at its last line.
        value = json.loads(result.stdout)
    except (ValueError, UnicodeError):
        return {}
    return value if isinstance(value, dict) else {}


def make_lock(case, count):
    source = case / 'source'
    source.mkdir(parents=True)
    revisions = [hashlib.sha1(('selection-fixture-%d' % index).encode()).hexdigest()
                 for index in range(count)]
    rows = ['version = 4\n']
    for index, revision in enumerate(revisions):
        rows.append('[[package]]\nname = "dependency_%d"\nversion = "1.0.0"\n'
                    'source = "git+https://example.invalid/dependency_%d#%s"\n' %
                    (index, index, revision))
    (source / 'Cargo.lock').write_text('\n'.join(rows))
    (source / 'Cargo.toml').write_text('[package]\nname="selection-probe"\nversion="1.0.0"\n')
    return source, sorted(revisions)


def selection_matches(receipt, source, revisions):
    return receipt.get('selection') == {
        'kind': 'cargo-lock-downloads', 'lockfile_sha256': digest(source / 'Cargo.lock'),
        'registry_packages': 0, 'git_revisions': revisions}


def private_receipt_matches(receipt, home, source, revisions):
    path = home / '.dsr-cache-seed.json'
    return (receipt.get('mode') == 'private-copy' and receipt.get('cargo_home') == str(home) and
            receipt.get('receipt_path') == str(path) and path.is_file() and
            receipt.get('receipt_sha256') == digest(path) and
            stat.S_IMODE(home.stat().st_mode) == 0o700 and
            selection_matches(receipt, source, revisions))


# Only the network boundary is local. Production _act_ssh_exec still builds
# and launches a real external SSH command, and this executable then execs
# the requested Bash/sh/zsh receiver with its actual argv and stdin. Python,
# jq, cache inventory, filesystem custody and all receipt serializers are real.
bin_dir = work / 'bin'
bin_dir.mkdir()
ssh = bin_dir / 'ssh'
ssh.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['DSR_SELECTION_TRANSPORT_LOG'], 'a') as log:
    log.write(json.dumps({'argv_bytes': [len(os.fsencode(value)) for value in args],
                          'shell': os.environ['SHELL']}) + '\\n')
null_stdin = False
while args and args[0].startswith('-'):
    if args[0] == '-n':
        null_stdin = True
    args = args[2:] if args[0] in ('-o', '-p', '-l') else args[1:]
if len(args) != 2 or args[0] != 'fixture-shell':
    raise SystemExit(97)
if null_stdin:
    descriptor = os.open(os.devnull, os.O_RDONLY)
    os.dup2(descriptor, 0)
    os.close(descriptor)
shell = os.environ['SHELL']
os.execv(shell, [shell, '-c', args[1]])
''')
ssh.chmod(0o700)
build_root = work / 'native-build-root'
build_root.mkdir()
host_os = {'Linux': 'linux', 'Darwin': 'darwin'}.get(platform.system())
host_arch = {'x86_64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine())
if not host_os or not host_arch:
    raise SystemExit('Cargo selection receiver controls require a supported native Unix host')
target = host_os + '/' + host_arch
triple = {'linux/amd64': 'x86_64-unknown-linux-gnu', 'linux/arm64': 'aarch64-unknown-linux-gnu',
          'darwin/amd64': 'x86_64-apple-darwin', 'darwin/arm64': 'aarch64-apple-darwin'}[target]
hosts = work / 'hosts.json'
hosts.write_text(json.dumps({'hosts': {'receiver': {
    'platform': target, 'connection': 'ssh', 'ssh_host': 'fixture-shell', 'build_root': str(build_root)}}}))
configs = work / 'config/repos.d'
configs.mkdir(parents=True)
ambient = work / 'empty-ambient'
ambient.mkdir()
environment = dict(os.environ, DSR_HOSTS_FILE=str(hosts), DSR_CONFIG_DIR=str(configs.parent),
                   DSR_SELECTION_CONFIGS=str(configs), DSR_SELECTION_PLATFORM=target,
                   DSR_SELECTION_ARTIFACTS=str(work / 'artifacts'),
                   DSR_SELECTION_LOGS=str(work / 'logs'), DSR_KEEP_BUILD_STAGES='1',
                   CARGO_HOME=str(ambient), NO_COLOR='1',
                   PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])
driver = work / 'driver.bash'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
module=$1
shift
source "$module" || exit $?
source "${module%/*}/cargo_cache.sh" || exit $?
case $1 in
    seed)
        shift
        _cargo_cache_run snapshot "" "$1/.cargo-home" "$1/source/Cargo.lock"
        ;;
    private)
        source_root=$2/source
        suffix=$3
        program=$(_act_unix_private_cargo_home_script "$source_root" "$suffix") || exit $?
        program+=$'\n''printf '\''%s\n'\'' "$dsr_private_summary"'
        _act_ssh_exec receiver "$program" 60
        ;;
    prepare)
        # Deliberate serialization boundary: no Cargo resolution, dependency
        # authentication or compilation is claimed by this empty-cache test.
        # Everything before/after metadata, including actual seed promotion,
        # private-copy inventory, transport and receipt validation, is real.
        _act_unix_cargo_metadata_body() {
            cat <<'METADATA_BOUNDARY'
dsr_dependency_sources=$(cat "$physical_source_root/.serialization-boundary.json")
if $dsr_seed_pending; then
    _cargo_cache_run snapshot "$strict_home" "$dsr_seed_home" "$physical_source_root/Cargo.lock" >/dev/null
fi
METADATA_BOUNDARY
        }
        _act_prepare_unix_private_cargo_home receiver "$2/source" "$3"
        ;;
    native)
        ACT_REPOS_DIR=$DSR_SELECTION_CONFIGS
        ACT_ARTIFACTS_DIR=$DSR_SELECTION_ARTIFACTS
        ACT_LOGS_DIR=$DSR_SELECTION_LOGS
        # Host readiness is an explicit fixture boundary. The actual native
        # policy, source staging, cache, supervisor and result emission run.
        host_health_is_ready() { [[ "$1" == receiver ]]; }
        act_run_native_build selection-probe "$DSR_SELECTION_PLATFORM" v1.0.0 "$3" \
            "" "" "" receiver "" "$2/source"
        ;;
    finish)
        _act_finish_unix_private_cargo_home --native-execution receiver "$2" "$3"
        ;;
    *) exit 4 ;;
esac
''')


def receiver(shell, label, exported=False):
    env = dict(environment, SHELL=shutil.which(shell),
               DSR_SELECTION_TRANSPORT_LOG=str(work / (label + '.transport.jsonl')))
    if exported:
        # Assignment must not preserve an inherited export attribute for
        # either growing summary: exec limits apply to environment strings too.
        env.update(dsr_seed_summary='ambient-seed', dsr_private_summary='ambient-private')
    return env


def run(action, case, suffix, env, label, *extra):
    return invoke(['bash', driver, module, action, case, suffix, *extra], env, label)


print('Cargo selection fixture: real lock-scoped empty cache; no Cargo resolution or compilation', flush=True)
for count in (10, 3200):
    case = work / ('pins-%d' % count)
    source, revisions = make_lock(case, count)
    seeded = run('seed', case, '', receiver('bash', 'seed-%d' % count), 'seed-%d' % count)
    seed = document(seeded)
    if not check('%d-pin producer emits authentic exact selection' % count,
                 seeded.returncode == 0 and private_receipt_matches(seed, case / '.cargo-home', source, revisions)):
        continue
    check('%d-pin fixture summary has the intended argv size' % count,
          (len(seeded.stdout) > 131072) if count == 3200 else (len(seeded.stdout) < 4096))
    held_seed = identity(case / '.cargo-home/.dsr-cache-seed.json')
    for shell in ('bash', 'sh', 'zsh'):
        label = 'private-%d-%s' % (count, shell)
        result = run('private', case, label, receiver(shell, label), label)
        receipt = document(result)
        check(label + ' prepares successfully with one pure receipt on stdout', result.returncode == 0 and bool(receipt))
        check(label + ' retains exact selection and independent private receipt',
              private_receipt_matches(receipt, case / ('.cargo-home-' + label), source, revisions) and
              (case / ('.cargo-home-' + label) / '.dsr-cache-seed.json').stat().st_ino !=
              (case / '.cargo-home/.dsr-cache-seed.json').stat().st_ino)
        check(label + ' does not mutate the retained seed',
              identity(case / '.cargo-home/.dsr-cache-seed.json') == held_seed)
    if count == 3200:
        for shell in ('bash', 'sh', 'zsh'):
            label = 'exported-%d-%s' % (count, shell)
            result = run('private', case, label, receiver(shell, label, exported=True), label)
            check(label + ' clears inherited exports before assigning large summaries',
                  result.returncode == 0 and
                  private_receipt_matches(document(result), case / ('.cargo-home-' + label), source, revisions))

    old_lock = (source / 'Cargo.lock').read_text()
    (source / 'Cargo.lock').write_text(old_lock.replace(revisions[0], 'f' * 40, 1))
    for shell in ('bash', 'sh', 'zsh'):
        label = 'changed-%d-%s' % (count, shell)
        result = run('private', case, label, receiver(shell, label), label)
        check(label + ' refuses the changed selection semantically with empty stdout',
              result.returncode == 1 and not result.stdout and
              b'private Cargo cache seed or lockfile selection changed during preparation' in result.stderr and
              b'argument list too long' not in result.stderr.lower())
        check(label + ' preserves admitted seed bytes and inode',
              identity(case / '.cargo-home/.dsr-cache-seed.json') == held_seed)
    (source / 'Cargo.lock').write_text(old_lock)

    # Exercise the actual strict caller's cold and retained-seed paths. Only
    # the named metadata boundary above is controlled; its small source summary
    # is not the oversized fixture. The authentic cache selection is oversized.
    for shell in ('bash', 'sh', 'zsh'):
        cold = work / ('cold-%d-%s' % (count, shell))
        cold_source, cold_revisions = make_lock(cold, count)
        sources = {'schema_version': 1, 'kind': 'dsr-cargo-dependency-sources',
                   'sha256': '0' * 64, 'metadata_sha256': '1' * 64,
                   'package_count': 0, 'root_count': 0, 'file_count': 0, 'size_bytes': 0,
                   'authentication': {'lockfile_sha256': digest(cold_source / 'Cargo.lock'),
                                      'locked_archive_packages': 0, 'locked_git_packages': 0,
                                      'workspace_snapshot_packages': 0}}
        (cold_source / '.serialization-boundary.json').write_text(json.dumps(sources))
        for attempt in ('cold', 'retry'):
            label = '%s-%d-%s' % (attempt, count, shell)
            result = run('prepare', cold, label, receiver(shell, label, exported=attempt == 'retry'), label)
            receipt = document(result)
            check(label + ' strict caller emits one complete preparation receipt',
                  result.returncode == 0 and
                  private_receipt_matches(receipt, cold / ('.cargo-home-' + label), cold_source, cold_revisions) and
                  receipt.get('dependency_sources') == sources)

# Producer's admitted upper bound stays unchanged; no increased limits or
# suppressed failures are needed to fix the transport of legitimate receipts.
for count in (10000, 10001):
    case = work / ('bound-%d' % count)
    source, revisions = make_lock(case, count)
    label = 'bound-%d' % count
    result = run('seed', case, '', receiver('bash', label), label)
    if count == 10000:
        check('10000 pinned downloads remain admitted without truncation',
              result.returncode == 0 and private_receipt_matches(document(result), case / '.cargo-home', source, revisions))
        result = run('private', case, 'bound-attempt', receiver('bash', 'bound-attempt'), 'bound-attempt')
        check('10000-pin retained seed comparison uses the same real receiver',
              result.returncode == 0 and private_receipt_matches(document(result), case / '.cargo-home-bound-attempt', source, revisions))
    else:
        check('10001 locked packages are still refused before seed publication',
              result.returncode == 4 and not result.stdout and
              b'invalid or oversized Cargo.lock' in result.stderr and
              not (case / '.cargo-home/.dsr-cache-seed.json').exists())

# A deliberate failing shell recipe exercises real ordinary native admission
# and public result serialization without pretending to compile these packages.
for count in (10, 3200):
    case = work / ('native-%d' % count)
    source, revisions = make_lock(case, count)
    probe = case / 'recipe-private-home'
    configuration = {'tool_name': 'selection-probe', 'repo': 'fixture/selection-probe',
                     'local_path': str(source), 'language': 'rust', 'binary_name': 'selection-probe',
                     'linux_glibc_floor': 'native',
                     'build_cmd': 'printf "%s\\n" "$CARGO_HOME" > "$DSR_SELECTION_PROBE"; exit 17',
                     'env': {'CARGO_BUILD_TARGET': triple, 'DSR_SELECTION_PROBE': str(probe)}}
    (configs / 'selection-probe.yaml').write_text(json.dumps(configuration))
    label = 'native-%d' % count
    result = run('native', case, label, receiver('bash', label), label)
    report = document(result)
    seed = report.get('cargo_isolation', {}).get('dependency_cache', {}).get('seed', {})
    check(label + ' reaches the intentional recipe exit and returns pure failure JSON',
          result.returncode == 6 and report.get('status') == 'failed' and
          report.get('native_execution', {}).get('command_exit_code') == 17 and probe.is_file())
    check(label + ' public result retains exact cache selection without artifacts',
          selection_matches(seed, source, revisions) and not report.get('artifact_paths') and
          not report.get('collected_sha256') and bool(report.get('log_file')) and
          Path(report.get('log_file', '/nonexistent')).is_file())
    if probe.is_file() and seed:
        home = Path(probe.read_text().strip())
        check(label + ' recipe ran in the recorded private cache',
              private_receipt_matches(seed, home, source, revisions))
        # The final inventory envelope is naturally bounded. Verify actual
        # finalization/status instead of padding it with imaginary fields.
        finished = run('finish', home, seed['receipt_sha256'], receiver('bash', label + '-final'), label + '-final')
        final = document(finished)
        check(label + ' final envelope preserves real status and receipt',
              finished.returncode == 0 and final.get('command_exit_code') == 0 and
              final.get('receipt', {}).get('mode') == 'inventory' and
              final['receipt']['cargo_home'] == str(home))
        seed_path = home / '.dsr-cache-seed.json'
        seed_path.write_bytes(seed_path.read_bytes() + b'\n')
        refused = run('finish', home, seed['receipt_sha256'], receiver('bash', label + '-changed'), label + '-changed')
        refusal = document(refused)
        check(label + ' changed seed finalization refuses with its original command status',
              refused.returncode != 0 and refusal.get('command_exit_code') == refused.returncode and
              'receipt' in refusal and refusal['receipt'] is None and
              b'private Cargo cache seed receipt changed' in refused.stderr)

launches = [json.loads(line) for path in work.glob('*.transport.jsonl') for line in path.read_text().splitlines()]
check('all actual SSH exec arguments stay within the existing program bound',
      bool(launches) and max(size for launch in launches for size in launch['argv_bytes']) <= 65535)
print('Cargo selection results: %d passed, %d failed (%d checks)' %
      (checks - len(failures), len(failures), checks), flush=True)
(work / 'results.json').write_text(json.dumps({'checks': checks, 'failures': failures}, indent=2) + '\n')
raise SystemExit(bool(failures))
PY
}

if [[ "$MODE" == metadata-admission ]]; then
    check "Strict target/task loops preserve metadata cancellation and diagnostic failure precedence" test_metadata_admission
    log_info "Results: $PASS_COUNT/$TEST_COUNT passed, $FAIL_COUNT failed"
    [[ "$FAIL_COUNT" -eq 0 ]]
    exit $?
fi

if [[ "$MODE" == metadata-interruption ]]; then
    check "Strict metadata retains real transport cancellation and drains owned descendants" test_metadata_interruption
    log_info "Results: $PASS_COUNT/$TEST_COUNT passed, $FAIL_COUNT failed"
    [[ "$FAIL_COUNT" -eq 0 ]]
    exit $?
fi

if [[ "$MODE" == coordinator-planning ]]; then
    test_large_coordinator_planning
    log_info "Results: $PASS_COUNT/$TEST_COUNT passed, $FAIL_COUNT failed"
    [[ "$FAIL_COUNT" -eq 0 ]]
    exit $?
fi

if [[ "$MODE" == cargo-selection ]]; then
    check "Actual large Cargo selection receipts survive every caller boundary" test_large_cargo_selection_receipts
    log_info "Results: $PASS_COUNT/$TEST_COUNT passed, $FAIL_COUNT failed"
    [[ "$FAIL_COUNT" -eq 0 ]]
    exit $?
fi

log_info "Running large Unix program transport tests (dsr-00n2)"
test_actual_metadata_program_routes_to_stdin
test_argv_bound_counts_bytes_at_the_boundary
test_small_command_keeps_argv
test_large_coordinator_planning
test_large_program_reaches_ssh_only_on_stdin
test_large_program_runs_locally_on_stdin
test_large_program_with_syntax_error_runs_nothing
test_large_program_timeout_status
test_actual_metadata_program_reaches_first_command
test_linux_argv_negative_control
check "Strict metadata retains real transport cancellation and drains owned descendants" test_metadata_interruption
check "Strict target/task loops preserve metadata cancellation and diagnostic failure precedence" test_metadata_admission
check "Actual large Cargo selection receipts survive every caller boundary" test_large_cargo_selection_receipts

log_info "Results: $PASS_COUNT/$TEST_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
