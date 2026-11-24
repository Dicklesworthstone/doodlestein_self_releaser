#!/usr/bin/env bash
# Offline SBOM publication regressions. Files, hashing, jq, links and moves are
# real; the Syft executable is an explicit process fixture, not a real scan.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MODULE="${SBOM_TEST_MODULE:-$ROOT/src/sbom.sh}"

# Real Bash/supervisor/process groups and filesystem publication, with an
# explicit scanner process fixture. Every invocation has the same independent
# nine-second outer guard, including runs against the unchanged module. This
# exercises scanner lifecycle; it does not claim package-detection coverage.
sbom_lifecycle_checks() {
    python3 - "$ROOT" "$MODULE" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

root, module = map(Path, sys.argv[1:])
work = Path(tempfile.mkdtemp(prefix='dsr-sbom-lifecycle-'))
binary = work / 'bin'
binary.mkdir()
checks = failures = 0
print('SBOM lifecycle fixtures: ' + str(work), flush=True)
portable = work / 'without-timeout'
portable.mkdir()
# Keep real scanner dependencies while exercising a host with no timer CLI.
for directory in os.get_exec_path():
    source = Path(directory or '.').absolute()
    if not source.is_dir():
        continue
    for executable in source.iterdir():
        target = portable / executable.name
        if executable.name not in ('timeout', 'gtimeout') and not target.exists() and \
                executable.is_file() and os.access(executable, os.X_OK):
            target.symlink_to(executable)
document = dict(spdxVersion='SPDX-2.3', dataLicense='CC0-1.0', SPDXID='SPDXRef-DOCUMENT',
                name='scanner-fixture', documentNamespace='https://example.test/lifecycle',
                creationInfo=dict(creators=['Tool: process-fixture'], created='2026-11-14T00:00:00Z'),
                packages=[])
(work / 'document.json').write_text(json.dumps(document) + '\n')
scanner = binary / 'syft'
scanner.write_text(r'''#!/usr/bin/env python3
import json, os, signal, sys, time
from pathlib import Path
case = Path(os.environ['SBOM_LIFECYCLE_CASE'])
mode = os.environ.get('SBOM_LIFECYCLE_MODE', 'healthy')
version = sys.argv[1:] == ['version']
name = next((Path(a[5:]).name for a in sys.argv[1:] if a.startswith('file:')), '')
with (case / 'calls').open('a') as log: log.write(json.dumps(sys.argv[1:])+'\n')
output = 'syft 1.0.0\n' if version else Path(os.environ['SBOM_LIFECYCLE_DOCUMENT']).read_text()
if mode == 'stdin' and sys.stdin.buffer.read():
    print('scanner consumed caller input', file=sys.stderr); sys.exit(17)
if mode == 'deadline' or (mode == 'partial' and name == 'b.bin'):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print(output, end='', flush=True)
    print('scanner is deliberately blocked', file=sys.stderr, flush=True)
    (case / 'ready').write_text(str(os.getpid()))
    while True: time.sleep(1)
if mode == 'late-writer':
    reader, writer = os.pipe()
    child = os.fork()
    if child == 0:
        os.close(reader)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        os.write(writer, b'ready'); os.close(writer)
        time.sleep(2)
        (case / 'late-write').write_text('descendant wrote after scanner exit\n')
        print('late scanner output', flush=True)
        os._exit(0)
    os.close(writer); assert os.read(reader, 5) == b'ready'; os.close(reader)
    (case / 'child-pid').write_text(str(child))
print(output, end='', flush=True)
''')
scanner.chmod(0o700)
driver = work / 'driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$1/src/guardrails.sh" || exit 3
source "$2" || exit 3
engine=$3 action=$4
shift 4
if [[ "$engine" == strict-caller ]]; then set -e -o posix; export SHELLOPTS; fi
case "$action" in
    version) sbom_version ;;
    generate) sbom_generate "$@" ;;
    batch) sbom_generate_artifacts "$@" ;;
    json) sbom_generate_json "$@" ;;
    exported) bash -c 'sbom_generate "$@"' _ "$@" ;;
    *) exit 4 ;;
esac
''')

def check(label, condition):
    global checks, failures
    checks += 1
    failures += not condition
    print(('ok ' if condition else 'not ok ') + str(checks) + ' - ' + label, flush=True)

def new_case(label):
    case = work / label
    case.mkdir()
    (case / 'input.bin').write_bytes(b'opaque scanner input\n')
    return case

def run(case, engine='gnu', action='generate', mode='healthy', seconds='1', args=None, incoming=b''):
    if args is None:
        args = [] if action == 'version' else [case / 'input.bin', '--output', case / 'proof.json']
    number = len(list(case.glob('invocation-*.json')))
    out, err = case / ('stdout-'+str(number)), case / ('stderr-'+str(number))
    path = str(portable) if engine == 'portable' else os.environ['PATH']
    env = dict(os.environ, PATH=str(binary)+':'+path, DSR_SBOM_TIMEOUT=seconds,
               SBOM_OUTPUT_DIR='', SBOM_LIFECYCLE_CASE=str(case), SBOM_LIFECYCLE_MODE=mode,
               SBOM_LIFECYCLE_DOCUMENT=str(work / 'document.json'))
    started = time.monotonic()
    expired = False
    with out.open('wb') as stdout, err.open('wb') as stderr:
        process = subprocess.Popen(['bash', str(driver), str(root), str(module), engine, action,
                                    *map(str, args)], env=env, stdin=subprocess.PIPE,
                                   stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            process.communicate(input=incoming, timeout=9)
        except subprocess.TimeoutExpired:
            expired = True
            # The baseline's scanner remains in this invocation's session.
            # Candidate supervision must finish before this independent guard.
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=4)
    record = dict(exit_code=process.returncode, outer_timeout=expired,
                  elapsed_seconds=round(time.monotonic()-started, 3), engine=engine, action=action)
    (case / ('invocation-'+str(number)+'.json')).write_text(json.dumps(record)+'\n')
    return record, out.read_text(), err.read_text()

def valid(path):
    try: return json.loads(path.read_text()) == document
    except (OSError, ValueError): return False

for engine in ('gnu', 'portable'):
    case = new_case(engine+'-healthy')
    result, output, _ = run(case, engine)
    check(engine+' supervised healthy scan publishes one complete document',
          result['exit_code'] == 0 and output.strip() == str(case/'proof.json') and valid(case/'proof.json'))
    check(engine+' healthy scan removes only its completed staging', not list(case.glob('.dsr-sbom.*')))

    case = new_case(engine+'-late-writer')
    result, output, _ = run(case, engine, mode='late-writer')
    check(engine+' scanner exit zero initially produces a successful result', result['exit_code'] == 0)
    time.sleep(2.3)
    check(engine+' stopped descendant cannot write after success', not (case/'late-write').exists())
    check(engine+' published SBOM remains valid after descendant write opportunity', valid(case/'proof.json'))

    case = new_case(engine+'-deadline')
    original = json.dumps(dict(document, name='retained-original'))+'\n'
    (case/'proof.json').write_text(original)
    result, output, errors = run(case, engine, mode='deadline')
    check(engine+' blocked TERM-resistant scan finishes within the independent guard',
          not result['outer_timeout'] and result['exit_code'] == 5)
    check(engine+' deadline never publishes the valid-looking partial scanner output',
          output == '' and (case/'proof.json').read_text() == original)
    stages = list(case.glob('.dsr-sbom.*'))
    check(engine+' failed scan retains its actual deadline and scanner diagnostics',
          len(stages) == 1 and (stages[0]/'scan-timeout-seconds').is_file() and
          (stages[0]/'scan-timeout-seconds').read_text() == '1\n' and
          'deliberately blocked' in (stages[0]/'scanner.stderr').read_text() and
          str(stages[0]) in errors)

    case = new_case(engine+'-version-deadline')
    result, output, _ = run(case, engine, action='version', mode='deadline')
    check(engine+' version discovery has the same deadline and cannot bless partial output',
          not result['outer_timeout'] and result['exit_code'] == 5 and output == '')

case = new_case('partial-batch')
artifacts = case / 'artifacts'
artifacts.mkdir()
for name in ('a.bin', 'b.bin'): (artifacts/name).write_bytes((name+' opaque input\n').encode())
result, output, _ = run(case, action='batch', mode='partial', args=[artifacts])
check('batch timeout stops before claiming complete coverage',
      not result['outer_timeout'] and result['exit_code'] == 5 and output == '' and
      not (artifacts/'sbom-manifest.spdx.json').exists() and not (artifacts/'b.bin.sbom.spdx.json').exists())
retained = artifacts / 'a.bin.sbom.spdx.json.dsr.json'
retained_bytes = retained.read_bytes() if retained.exists() else b''
proof_bytes = (artifacts/'a.bin.sbom.spdx.json').read_bytes() if retained.exists() else b''
check('completed batch evidence survives a later scanner timeout', bool(retained_bytes) and bool(proof_bytes))
result, output, _ = run(case, action='batch', seconds='2', args=[artifacts])
check('healthy retry completes the same frozen batch',
      result['exit_code'] == 0 and output.strip() == str(artifacts/'sbom-manifest.spdx.json'))
calls = [json.loads(line) for line in (case/'calls').read_text().splitlines()]
check('retry preserves completed proof bytes and does not rescan them',
      retained.exists() and retained.read_bytes() == retained_bytes and
      (artifacts/'a.bin.sbom.spdx.json').read_bytes() == proof_bytes and
      sum(any(a.endswith('/a.bin') for a in command) for command in calls) == 1)

for seconds in ('', '0', '-1', '1.5', '01', '86401', '99999999999999999999'):
    case = new_case('invalid-'+str(checks))
    result, output, _ = run(case, seconds=seconds)
    check('invalid scan bound is refused before invoking Syft: '+repr(seconds),
          result['exit_code'] == 4 and output == '' and not (case/'calls').exists() and
          not list(case.glob('.dsr-sbom.*')))

case = new_case('explicit-override')
result, _, _ = run(case, seconds='invalid', args=[case/'input.bin', '--output', case/'proof.json', '--scan-timeout', '2'])
check('explicit scan deadline overrides the ambient default', result['exit_code'] == 0 and valid(case/'proof.json'))
case = new_case('stdin')
result, _, _ = run(case, mode='stdin', incoming=b'caller control stream\n')
check('scanner stdin cannot consume its caller control stream', result['exit_code'] == 0 and valid(case/'proof.json'))
case = new_case('exported')
result, _, _ = run(case, action='exported')
check('exported scanner API retains the real supervisor dependencies', result['exit_code'] == 0 and valid(case/'proof.json'))
case = new_case('strict-caller')
result, _, _ = run(case, engine='strict-caller')
check('exported caller errexit and POSIX options cannot break scanner supervision',
      result['exit_code'] == 0 and valid(case/'proof.json'))

print('SBOM lifecycle checks: '+str(checks)+'; failures: '+str(failures), flush=True)
sys.exit(bool(failures))
PY
}

if [[ "${1:-}" == --lifecycle-only ]]; then
    sbom_lifecycle_checks
    exit $?
fi
WORK=$(mktemp -d)
WORK=$(cd "$WORK" && pwd -P) || exit 1
trap 'if [[ "${DSR_TEST_KEEP_TEMP:-0}" != 1 ]]; then rm -rf -- "$WORK"; fi' EXIT
trap 'exit 5' HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/cases"
export PATH="$WORK/bin:$PATH" SBOM_FIXTURES="$WORK"
export SBOM_OUTPUT_DIR=""
cat > "$WORK/spdx.json" <<'JSON'
{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"fixture","documentNamespace":"https://example.test/sbom/fixture","creationInfo":{"creators":["Tool: syft-fixture"],"created":"2026-09-18T00:00:00Z"},"packages":[]}
JSON
cat > "$WORK/cyclonedx.json" <<'JSON'
{"bomFormat":"CycloneDX","specVersion":"1.6","version":1,"components":[]}
JSON
cat > "$WORK/bin/syft" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
[[ "$1" != version ]] || { echo 'syft 1.0.0'; exit; }
printf '%s\0' "$@" > "$SBOM_FIXTURES/args"
printf 'scan\n' >> "$SBOM_FIXTURES/scans"
format=spdx
[[ "$2" != cyclonedx-json ]] || format=cyclonedx
case "${SBOM_FIXTURE_MODE:-valid}" in
    fail) printf '{"partial":'; echo 'scanner failed' >&2; exit 17 ;;
    empty) exit 0 ;;
    malformed) echo '{broken'; exit 0 ;;
    scalar) echo true; exit 0 ;;
    multiple) cat "$SBOM_FIXTURES/$format.json" "$SBOM_FIXTURES/$format.json"; exit ;;
    wrong) [[ "$format" == spdx ]] && format=cyclonedx || format=spdx ;;
    thin) echo '{"spdxVersion":"SPDX-2.3"}'; exit 0 ;;
    drift) printf changed >> "$SBOM_MUTATE_SOURCE" ;;
    snapshot-drift)
        for arg in "$@"; do
            case "$arg" in file:*) printf changed >> "${arg#file:}" ;; esac
        done ;;
    destination-drift) printf changed >> "$SBOM_MUTATE_DEST" ;;
    late-signature) printf signed > "$SBOM_MUTATE_DEST.minisig" ;;
esac
[[ -z "${SBOM_FIXTURE_NOISE:-}" ]] || echo 'scanner progress' >&2
cat "$SBOM_FIXTURES/$format.json"
SH
chmod +x "$WORK/bin/syft"
# The baseline required an external logger. The current module has a fallback.
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_info() { printf '[INFO] %s\n' "$*" >&2; }
log_ok() { printf '[OK] %s\n' "$*" >&2; }
log_debug() { :; }
# shellcheck source=/dev/null
source "$MODULE"
checks=0 failures=0 status=0 output="" CASE=""
check() {
    local description="$1"
    shift
    checks=$((checks + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$checks" "$description"
    else
        printf 'not ok %d - %s\n' "$checks" "$description"
        failures=$((failures + 1))
    fi
}
new_case() {
    CASE="$WORK/cases/$1"
    mkdir -p "$CASE"
    printf 'artifact payload\n' > "$CASE/tool.tar.gz"
    unset SBOM_FIXTURE_MODE SBOM_MUTATE_SOURCE SBOM_MUTATE_DEST SBOM_FIXTURE_NOISE
}
capture() {
    status=0
    "$@" > "$CASE/stdout" 2> "$CASE/stderr" || status=$?
    output=$(cat "$CASE/stdout")
}
nonzero() { [[ "$1" -ne 0 ]]; }
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
contains() { grep -F -- "$2" "$1" >/dev/null; }

new_case formats
capture sbom_generate "$CASE/tool.tar.gz"
check 'SPDX generation succeeds' test "$status" -eq 0
check 'full archive basename is preserved' test "$output" = "$CASE/tool.tar.gz.sbom.spdx.json"
check 'published SPDX document validates' sbom_verify "$CASE/tool.tar.gz.sbom.spdx.json"
printf 'different archive\n' > "$CASE/tool.tar.xz"
capture sbom_generate "$CASE/tool.tar.xz"
check 'tar.xz generation succeeds independently' test "$status" -eq 0
check 'compression variants have distinct documents' test -f "$CASE/tool.tar.xz.sbom.spdx.json"
capture sbom_generate "$CASE/tool.tar.gz" --format cyclonedx
check 'CycloneDX generation succeeds' test "$status" -eq 0
check 'CycloneDX retains full basename' test "$output" = "$CASE/tool.tar.gz.sbom.cdx.json"
capture sbom_generate "$CASE/tool.tar.gz" --format cdx --output "$CASE/custom proof.json"
check 'format alias and custom output work' test "$status" -eq 0
check 'custom output path is not polluted by logs' test "$output" = "$CASE/custom proof.json"

new_case filename
mkdir -p "$CASE/dotted.dir"
printf bytes > "$CASE/dotted.dir/plain"
capture sbom_generate "$CASE/dotted.dir/plain"
check 'dot in parent directory cannot truncate output path' test "$output" = "$CASE/dotted.dir/plain.sbom.spdx.json"
printf bytes > "$CASE/tool with spaces"
capture sbom_generate "$CASE/tool with spaces"
check 'space-containing artifact path works' test "$status" -eq 0
check 'space-containing basename remains exact' test "$output" = "$CASE/tool with spaces.sbom.spdx.json"

for mode in fail empty malformed scalar multiple wrong thin; do
    new_case "invalid-$mode"
    export SBOM_FIXTURE_MODE="$mode"
    capture sbom_generate "$CASE/tool.tar.gz"
    check "$mode scanner result cannot succeed" nonzero "$status"
    check "$mode scanner result leaves no final document" absent "$CASE/tool.tar.gz.sbom.spdx.json"
    check "$mode scanner result emits no success path" test -z "$output"
    command cp "$WORK/spdx.json" "$CASE/retained.json"
    capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/retained.json"
    check "$mode failure preserves retained proof bytes" cmp -s "$WORK/spdx.json" "$CASE/retained.json"
done

new_case verify
for data in 'null' '[]' '{}' '{"spdxVersion":true}' '{"bomFormat":"not-cyclonedx","specVersion":"1.6","version":1}' '{"bomFormat":"CycloneDX","specVersion":"1.6","version":0}' '{"bomFormat":"CycloneDX","specVersion":"1.6","version":1,"components":{}}'; do
    printf '%s\n' "$data" > "$CASE/bad.json"
    capture sbom_verify "$CASE/bad.json"
    check "document contract rejects $data" nonzero "$status"
done
cat "$WORK/spdx.json" "$WORK/cyclonedx.json" > "$CASE/multiple.json"
capture sbom_verify "$CASE/multiple.json"
check 'verification rejects a stream of multiple documents' nonzero "$status"
capture sbom_verify "$WORK/cyclonedx.json" --format spdx
check 'verification enforces requested format' nonzero "$status"

new_case arguments
for flag in --format --output; do
    capture sbom_generate "$CASE/tool.tar.gz" "$flag"
    check "missing $flag value is invalid arguments" test "$status" -eq 4
    check "missing $flag value leaves no output" test -z "$output"
done
capture sbom_generate "$CASE/tool.tar.gz" --unknown
check 'unknown option rejected' test "$status" -eq 4
capture sbom_generate "$CASE/tool.tar.gz" --format unknown
check 'unknown format rejected' test "$status" -eq 4
capture sbom_generate
check 'missing target rejected' test "$status" -eq 4

new_case drift
export SBOM_FIXTURE_MODE=drift SBOM_MUTATE_SOURCE="$CASE/tool.tar.gz"
capture sbom_generate "$CASE/tool.tar.gz"
check 'source change during scan fails' nonzero "$status"
check 'source change leaves no unbound proof' absent "$CASE/tool.tar.gz.sbom.spdx.json"
export SBOM_FIXTURE_MODE=snapshot-drift
capture sbom_generate "$CASE/tool.tar.gz"
check 'snapshot change during scan fails' nonzero "$status"
check 'snapshot change leaves no proof' absent "$CASE/tool.tar.gz.sbom.spdx.json"

new_case destinations
ln -s "$CASE/tool.tar.gz" "$CASE/linked-input"
capture sbom_generate "$CASE/linked-input"
check 'linked input rejected' nonzero "$status"
mkfifo "$CASE/fifo"
capture sbom_generate "$CASE/fifo"
check 'special input rejected' nonzero "$status"
ln -s "$CASE/tool.tar.gz" "$CASE/linked-output"
command cp "$CASE/tool.tar.gz" "$CASE/original"
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/linked-output"
check 'linked output rejected' nonzero "$status"
check 'linked output cannot change artifact' cmp -s "$CASE/tool.tar.gz" "$CASE/original"
ln "$CASE/tool.tar.gz" "$CASE/hardlink-output"
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/hardlink-output"
check 'hardlink input/output overlap rejected' nonzero "$status"
command cp "$WORK/spdx.json" "$CASE/signed.json"
printf signature > "$CASE/signed.json.minisig"
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/signed.json"
check 'signed proof is not regenerated' nonzero "$status"
check 'signed proof bytes preserved' cmp -s "$WORK/spdx.json" "$CASE/signed.json"
printf '{"existing":true}\n' > "$CASE/invalid.json"
command cp "$CASE/invalid.json" "$CASE/invalid.before"
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/invalid.json"
check 'invalid retained proof is not trusted' nonzero "$status"
check 'invalid retained proof preserved for diagnosis' cmp -s "$CASE/invalid.before" "$CASE/invalid.json"
command cp "$WORK/spdx.json" "$CASE/changing.json"
export SBOM_FIXTURE_MODE=destination-drift SBOM_MUTATE_DEST="$CASE/changing.json"
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/changing.json"
check 'concurrent destination mutation rejected' nonzero "$status"
check 'concurrent writer data not overwritten' contains "$CASE/changing.json" changed
export SBOM_FIXTURE_MODE=late-signature SBOM_MUTATE_DEST="$CASE/late.json"
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/late.json"
check 'late signature prevents publication' nonzero "$status"
check 'late signature does not acquire unrelated proof' absent "$CASE/late.json"

new_case project
mkdir "$CASE/project[1]"
capture sbom_generate_project "$CASE/project[1]" --output "$CASE/project[1]/sbom[1].json" --quiet
check 'project wrapper preserves custom output' test "$output" = "$CASE/project[1]/sbom[1].json"
tr '\0' '\n' < "$WORK/args" > "$CASE/args.txt"
check 'directory scan excludes its output with literal glob quoting' contains "$CASE/args.txt" './sbom\[1\].json'
check 'directory scan excludes private staging tree' contains "$CASE/args.txt" './.dsr-sbom.'

new_case json
export SBOM_FIXTURE_NOISE=true
capture sbom_generate_json "$CASE/tool.tar.gz" --output "$CASE/custom.json" --format cyclonedx
check 'JSON wrapper succeeds' test "$status" -eq 0
check 'JSON wrapper preserves output option' jq -e --arg p "$CASE/custom.json" '.output_file == $p and .status == "success" and .exit_code == 0' "$CASE/stdout"
check 'JSON wrapper keeps diagnostics out of path' jq -e '.output_file | contains("scanner") | not' "$CASE/stdout"
export SBOM_FIXTURE_MODE=fail
capture sbom_generate_json "$CASE/tool.tar.gz"
check 'JSON wrapper preserves scanner failure status' test "$status" -eq 1
check 'JSON scanner failure has typed error and null output' jq -e '.status == "error" and .exit_code == 1 and .output_file == null and (.error | contains("scanner failed"))' "$CASE/stdout"
capture sbom_generate_json "$CASE/tool.tar.gz" --format
check 'JSON malformed option exit is invalid arguments' test "$status" -eq 4
check 'JSON malformed option still emits one JSON object' jq -e -s 'length == 1 and .[0].exit_code == 4' "$CASE/stdout"
capture sbom_generate_json
check 'JSON missing target exit is invalid arguments' test "$status" -eq 4
check 'JSON missing target is structured' jq -e '.output_file == null and .status == "error"' "$CASE/stdout"

new_case io
command cp "$WORK/spdx.json" "$CASE/retained.json"
# Different valid scanner result forces the atomic replacement path.
jq '.name = "replacement"' "$WORK/spdx.json" > "$WORK/changed.json"
command cp "$WORK/spdx.json" "$WORK/unchanged.json"
command cp "$WORK/changed.json" "$WORK/spdx.json"
mv() { return 19; }
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/retained.json"
check 'failed publication remains failure' nonzero "$status"
check 'failed publication preserves original document' cmp -s "$WORK/unchanged.json" "$CASE/retained.json"
unset -f mv
command cp "$WORK/unchanged.json" "$WORK/spdx.json"
cp() { return 19; }
capture sbom_generate "$CASE/tool.tar.gz"
check 'snapshot copy failure cannot report success' nonzero "$status"
check 'snapshot copy failure publishes nothing' absent "$CASE/tool.tar.gz.sbom.spdx.json"
unset -f cp

printf '\nSBOM release regression checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]] || exit 1
sbom_lifecycle_checks
