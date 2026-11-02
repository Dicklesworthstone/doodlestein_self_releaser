#!/usr/bin/env bash
# Public CLI adapter for the existing authenticated installation engines.
# Keep their policy parsers, verification results and exit codes authoritative.

installer_release_cli() {
    local module="${BASH_SOURCE[0]}" worker='' signals=0 seen=0 rc=0
    local old_int old_term old_hup trap_command
    local -a old_commands=()
    if ! command -v python3 >/dev/null; then
        log_error 'Python 3 is required for authenticated release installation'
        if ${JSON_MODE:-false}; then
            json_envelope installer error 3 \
                "$(jq -nc --arg action "$1" '{action:$action,error:"Python 3 is required"}')"
        fi
        return 3
    fi
    old_int=$(trap -p INT); old_term=$(trap -p TERM); old_hup=$(trap -p HUP)
    # Decode the caller's handlers as data; never eval a trap record. Preserve
    # ignored signals and trailing newlines as well as ordinary handler bodies.
    while IFS= read -r -d '' trap_command; do
        old_commands+=("$trap_command")
    done < <(printf '%s\0' "$old_int" "$old_term" "$old_hup" | python3 -I -c '
import os, shlex, sys
try:
    records = sys.stdin.buffer.read().split(b"\0")
    if len(records) != 4 or records[-1] != b"":
        raise ValueError()
    commands = []
    for record, signal_name in zip(records[:3], ("SIGINT", "SIGTERM", "SIGHUP")):
        fields = shlex.split(os.fsdecode(record)) if record else []
        if record and (len(fields) != 4 or fields[:2] != ["trap", "--"] or fields[3] != signal_name):
            raise ValueError()
        commands.append(fields[2] if fields else "")
    for command in commands:
        sys.stdout.buffer.write(os.fsencode(command) + b"\0")
except (ValueError, OSError):
    raise SystemExit(3)
')
    if [[ ${#old_commands[@]} -ne 3 ]]; then
        log_error 'Cannot preserve prior signal handlers for authenticated installation'
        if ${JSON_MODE:-false}; then
            json_envelope installer error 3 \
                "$(jq -nc --arg action "$1" '{action:$action,error:"Cannot preserve prior signal handlers"}')"
        fi
        return 3
    fi
    trap 'signals=$((signals+1)); [[ -z "$worker" ]] || kill -TERM "$worker" 2>/dev/null || true' INT TERM HUP
    BASH_ENV='' ENV='' bash "$module" "${JSON_MODE:-false}" "${DRY_RUN:-false}" "$DSR_VERSION" "$@" &
    worker=$!
    if ((signals > 0)); then kill -TERM "$worker" 2>/dev/null || true; fi
    # A signal interrupts wait before the engine finishes its own cleanup and
    # final receipt. Wait for that receipt instead of inventing activation state.
    while :; do
        seen=$signals
        rc=0; wait "$worker" || rc=$?
        ((signals == seen)) && break
    done
    worker=''
    trap - INT TERM HUP
    [[ -z "$old_int" ]] || trap -- "${old_commands[0]}" INT
    [[ -z "$old_term" ]] || trap -- "${old_commands[1]}" TERM
    [[ -z "$old_hup" ]] || trap -- "${old_commands[2]}" HUP
    return "$rc"
}

_installer_release_cli_execute() {
    local module_dir
    module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || return 3
    exec python3 -I - "$module_dir" "$@" <<'PY'
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

module = Path(sys.argv[1])
json_mode, dry_run = sys.argv[2] == "true", sys.argv[3] == "true"
version, action = sys.argv[4:6]
arguments = sys.argv[6:]
started = time.monotonic()
started_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
child = None
interrupted = False


class Failure(Exception):
    def __init__(self, message, code=7):
        super().__init__(message)
        self.code = code


def stop(signum, frame):
    global interrupted
    if not interrupted:
        interrupted = True
        if child is not None and child.poll() is None:
            try:
                child.send_signal(signal.SIGTERM)
            except ProcessLookupError:
                pass


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, stop)


def pairs(items):
    value = {}
    for key, item in items:
        if key in value:
            raise ValueError("duplicate engine result key")
        value[key] = item
    return value


def emit(details, code, raw=None):
    if json_mode:
        result = dict(command="installer", status="success" if code == 0 else "error", exit_code=code,
                      run_id=str(uuid.uuid4()), started_at=started_at,
                      duration_ms=int((time.monotonic() - started) * 1000), tool="dsr", version=version,
                      details=dict(details, action=action))
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    elif raw is not None:
        sys.stdout.buffer.write(raw)
    else:
        print(json.dumps(details, sort_keys=True, separators=(",", ":")))


try:
    if action not in ("generate-release", "install", "describe-recipe"):
        raise Failure("unknown authenticated installer action", 4)
    # Preserve exact values and duplicate options for the engine's strict
    # parser. Only the public global dry-run flag needs translation.
    arguments = ["--dry-run" if value == "-n" else value for value in arguments]
    if dry_run and action != "describe-recipe" and "--dry-run" not in arguments:
        arguments.append("--dry-run")
    script = module / ("install_gen_release.sh" if action == "generate-release" else "release_install.sh")
    command = ["bash", str(script)]
    if action == "describe-recipe":
        command.append(action)
    command.extend(arguments)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("BASH_FUNC_") and key not in ("BASH_ENV", "ENV")}
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env=environment, start_new_session=True)
    if interrupted:
        child.send_signal(signal.SIGTERM)
    output, diagnostics = child.communicate()
    code = child.returncode
    if diagnostics:
        sys.stderr.buffer.write(diagnostics)
        sys.stderr.buffer.flush()
    if code < 0:
        raise Failure("authenticated installer interrupted before returning a complete result", 5)
    try:
        details = json.loads(output, object_pairs_hook=pairs,
                             parse_constant=lambda value: (_ for _ in ()).throw(ValueError("non-finite result")))
    except (ValueError, UnicodeError):
        if code == 0 and any(arg in ("--help", "-h") for arg in arguments):
            emit(dict(help=output.decode("utf-8")), 0, output)
            sys.exit(0)
        raise Failure("authenticated installer did not return one complete JSON result", code or 7)
    expected = ("dsr-release-installer-generation" if action == "generate-release" else
                "dsr-install-recipe" if action == "describe-recipe" and code == 0 else "dsr-release-install")
    if not isinstance(details, dict) or details.get("kind") != expected:
        raise Failure("unexpected authenticated installer result", 7)
    if action == "describe-recipe" and code == 0:
        if details.get("authenticated") is not False or not isinstance(details.get("recipe"), dict):
            raise Failure("invalid recipe description", 7)
    elif type(details.get("exit_code")) is not int or details["exit_code"] != code:
        raise Failure("authenticated installer result disagrees with its process exit", 7)
    # A completed activation can win a race with cancellation. The engine's
    # final status and activated field remain authoritative in that case.
    emit(details, code, output)
    sys.exit(code)
except (Failure, OSError, ValueError, TypeError, KeyError) as error:
    code = getattr(error, "code", 7)
    print("[installer] " + str(error), file=sys.stderr)
    emit(dict(status="error", exit_code=code, error=str(error)), code)
    sys.exit(code)
finally:
    if child is not None and child.poll() is None:
        child.send_signal(signal.SIGTERM)
        child.wait()
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _installer_release_cli_execute "$@"
fi
