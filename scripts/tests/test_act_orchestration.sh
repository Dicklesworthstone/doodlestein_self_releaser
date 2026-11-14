#!/usr/bin/env bash
# test_act_orchestration.sh - Tests for hybrid build orchestration functions
#
# These tests verify the orchestration layer that coordinates act + SSH builds
# Run --dispatch-stdin-only for the issue #48 scheduler regression without
# compiler, Docker, SSH, or host-health fixtures. --output-queue-only exercises
# deferred shared outputs, independent hosts, cancellation and exact-run resume.
# --host-capacity-only covers the same queue with real one-slot host leases.
# --artifact-inventory-only exercises large completion receipts and reuse
# against real files without compilers, Docker, SSH, or host-health fixtures.
# --workflow-inventory-only exercises complete typed workflow collection and
# admission beyond the exec argument limit using actual ZIP and payload bytes.
# --receipt-producer-only checks real inventory bytes, namespace refusals and
# hashing custody. DSR_TEST_RECEIPT_BASELINE may name a saved, unchanged producer
# function for a paired comparison over the same files in that invocation.
# --strict-manifest-inventory-only compiles a local C executable and exercises
# exact strict manifests with real Git source, staged receipts and companions.
# Its Rust compiler-policy envelopes are explicit synthetic unit fixtures;
# actual Rust compilation/observation is covered by test_native_source_sync.sh.
# --native-matrix-inventory-only exercises complete native matrix admission
# with actual archives/receipts; GNU/musl worker selection is fixture metadata.
# --backend-receipt-only exercises exact backend stdout admission and proves
# diagnostic JSON cannot become durable success or reusable artifact evidence.
# --invocation-identity-only exercises singleton execution identity through
# coordinator completion and exact-run resume of real frozen artifact bytes.

set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { echo -e "${GREEN}✓${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}✗${NC} $1"; ((FAIL++)); }
skip() { echo -e "${YELLOW}○${NC} $1"; ((SKIP++)); }

# Populate the compiler boundary only for tests that deliberately replace the
# native Rust backend. These values are synthetic protocol data, not observations
# of Cargo/rustc execution. Collection, staging, manifest and policy validators
# remain production code, and negative cases remove or corrupt this authority.
_fixture_strict_rust_result() {
    local result="$1" sha="$2" ref="$3" source_root="$4" platform triple
    platform=$(jq -er '.platform' <<< "$result") || return 4
    triple=$(jq -r '.target_triple // ""' <<< "$result") || return 4
    [[ -n "$triple" ]] || triple=$(_act_default_rust_target_triple "$platform") || return 4
    jq -c --arg sha "$sha" --arg ref "$ref" --arg source "$source_root" --arg triple "$triple" '
        def tool($name): {
            program:$name, selected_path:("/synthetic-rust-fixture/" + $name),
            selected_sha256:("5" * 64), selected_kind:"executable",
            version:"synthetic unit fixture; compiler not executed"
        };
        .method = "native" |
        .host = (.host // "synthetic-rust-fixture") |
        .build_influence_env = ((.build_influence_env // {}) + {
            DSR_RUST_ENV_POLICY:"1", DSR_RELEASE_GIT_SHA:$sha, DSR_RELEASE_GIT_REF:$ref
        }) |
        .cargo_isolation = {
            mode:"strict-release-snapshot", source_boundary:"canonical-fresh-source-root",
            cargo_home:"/synthetic-rust-fixture/cargo-home", target_dir:"/synthetic-rust-fixture/target",
            ancestor_config_policy:"reject", cache_reuse:[],
            toolchain:{schema_version:1, cwd:$source, target_triple:$triple, linker_variable:null,
                tools:{cargo:tool("cargo"), rustc:tool("rustc"), linker:tool("cc")},
                selection:{rustup_toolchain:null, cargo_commands:["build"], cargo_config:[],
                    native_environment:{DSR_RUST_ENV_POLICY:"1"}}}
        }
    ' <<< "$result"
}

test_backend_receipt_isolation() {
    local project_root dependency
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    for dependency in python3 bash jq; do
        command -v "$dependency" >/dev/null || { echo "Missing test dependency: $dependency" >&2; return 77; }
    done
    python3 -I - "${DSR_TEST_ACT_RUNNER:-$project_root/src/act_runner.sh}" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

module = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix='dsr-backend-receipt-')).resolve()
print('Retained backend receipt fixtures: ' + str(root), flush=True)
checks, failures = 0, []


def check(label, condition):
    global checks
    checks += 1
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    if not condition:
        failures.append(label)


driver = r'''set -uo pipefail
source "$1" || exit 90
fixture=$2 boundary=$3
umask 0027
umask > "$fixture/caller.umask"
if [[ "$boundary" == worker ]]; then set -o noclobber; fi
ACT_LOGS_DIR="$fixture/logs"
ACT_ARTIFACTS_DIR="$fixture/artifacts"
ACT_REPO_LOCAL_PATH="$fixture"
ACT_REPO_WORKFLOW=workflow.yml
fixture_backend() {
    printf 'started\n' >> "$fixture/backend.started"
    umask > "$fixture/backend.umask"
    printf '%s\n' "$-" > "$fixture/backend.flags"
    : > "$fixture/backend.created"
    cat "$fixture/backend.stdout"
    cat "$fixture/backend.stderr" >&2
    return "$(cat "$fixture/backend.exit")"
}
if [[ "$boundary" == workflow* ]]; then
    PATH="$fixture/bin:$PATH"
    act_check() { return 0; }
    if [[ "$boundary" == workflow-serializer ]]; then
        jq() {
            local argument
            for argument in "$@"; do
                if [[ "$argument" == run_id ]]; then
                    printf 'injected workflow result serialization failure\n' >&2
                    return 23
                fi
            done
            command jq "$@"
        }
    fi
    act_run_workflow "$fixture" workflow.yml build push v1.0.0 -P ubuntu-latest=fixture
    exit $?
fi
if [[ "$boundary" == native ]]; then
    act_platform_uses_act() { return 1; }
    act_run_native_build() { fixture_backend; }
else
    act_platform_uses_act() { return 0; }
    act_run_workflow() { fixture_backend; }
    _act_workflow_payload_plans_json() { printf '{}\n'; }
    _act_source_plan_for_tool() { printf 'null\n'; }
    act_get_flags() { printf '[]\n'; }
    act_get_job_for_target() { printf 'build\n'; }
fi
if [[ "$boundary" == worker ]]; then
    _act_build_orchestration_target() { fixture_backend; }
    _act_run_target_worker tool v1.0.0 fixture-run linux/amd64 1 \
        "$fixture/attempt.log" "$fixture/attempt.json" false null '{}' '' '' fixture-host release
else
    _act_build_orchestration_target tool v1.0.0 fixture-run linux/amd64 false null '{}' '' '' fixture-host
fi
'''


def run(case, boundary):
    result = subprocess.run(['bash', '-c', driver, '_', str(module), str(case), boundary],
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
    (case / 'driver.stdout').write_bytes(result.stdout)
    (case / 'driver.stderr').write_bytes(result.stderr)
    try:
        raw = (case / 'attempt.json').read_bytes() if boundary == 'worker' else result.stdout
        value = json.loads(raw)
        value = value if isinstance(value, dict) else {}
    except (OSError, ValueError, UnicodeError):
        value = {}
    return result, value


def fixture(boundary, name):
    case = root / (boundary + '-' + name)
    case.mkdir()
    (case / 'logs').mkdir()
    artifact = case / 'artifact.bin'
    artifact.write_bytes(b'genuine collected output\n')
    receipt = dict(status='success', exit_code=0, platform='linux/amd64', method=boundary,
                   host='fixture-host', artifact_count=1, artifact_path=str(artifact))
    if boundary == 'worker':
        receipt['method'] = 'act'
    return case, artifact, receipt


cases = ('valid-pretty', 'valid-failure', 'success-nonzero', 'success-declared-failure',
         'success-string-exit', 'success-null-exit', 'failure-zero', 'failure-mismatched-exit',
         'unknown-status', 'stderr-only', 'empty-zero', 'missing-nonzero', 'chatter',
         'multiple', 'trailing-malformed', 'null', 'array', 'wrong-platform',
         'missing-platform', 'wrong-method', 'missing-method', 'wrong-host', 'missing-host')
for boundary in ('native', 'act', 'worker'):
    for name in cases:
        # Workflow producers do not select their task identity: the production
        # orchestration adapter supplies it from the actual act invocation.
        # Native producers and completed worker receipts must retain theirs.
        if boundary == 'act' and name.startswith(('wrong-', 'missing-')) and name != 'missing-nonzero':
            continue
        case, artifact, receipt = fixture(boundary, name)
        raw = json.dumps(receipt, indent=2) + '\n'
        # This is real diagnostic output at the controlled backend boundary.
        # Production consumers, process groups, freezing and persistence run.
        noise = 'compiler diagnostic retained separately\n'
        expected, success = 0, name == 'valid-pretty'
        if name == 'valid-pretty':
            noise += json.dumps(dict(status='failed', exit_code=99, error='diagnostic JSON')) + '\n'
        elif name == 'valid-failure':
            raw = json.dumps(dict(status='failed', exit_code=17, error='actual backend failure')) + '\n'
            expected = 17
        elif name == 'success-nonzero':
            expected = 17
        elif name in ('success-declared-failure', 'success-string-exit', 'success-null-exit'):
            receipt['exit_code'] = {'success-declared-failure': 17,
                                    'success-string-exit': '0', 'success-null-exit': None}[name]
            raw = json.dumps(receipt) + '\n'
            expected = 4
        elif name in ('failure-zero', 'failure-mismatched-exit'):
            raw = json.dumps(dict(status='failed', exit_code=17,
                                  error='backend reported a failed build')) + '\n'
            expected = 4 if name == 'failure-zero' else 23
        elif name == 'unknown-status':
            receipt['status'] = 'unknown'
            raw = json.dumps(receipt) + '\n'
            expected = 4
        elif name in ('wrong-platform', 'missing-platform', 'wrong-method',
                      'missing-method', 'wrong-host', 'missing-host'):
            field = name.split('-', 1)[1]
            if name.startswith('missing-'):
                receipt.pop(field)
            else:
                receipt[field] = {'platform': 'darwin/arm64', 'host': 'different-builder',
                                  'method': 'act' if boundary == 'native' else 'native'}[field]
            raw = json.dumps(receipt) + '\n'
            expected = 4
        elif name in ('stderr-only', 'empty-zero', 'missing-nonzero'):
            raw = ''
            if name == 'stderr-only':
                noise += json.dumps(receipt) + '\n'
            expected = 23 if name == 'missing-nonzero' else 4
        elif name == 'chatter':
            raw = 'unexpected result-channel chatter\n' + json.dumps(receipt) + '\n'
            expected = 4
        elif name == 'multiple':
            raw = json.dumps(receipt) + '\n' + json.dumps(receipt) + '\n'
            expected = 4
        elif name == 'trailing-malformed':
            raw = json.dumps(receipt) + '\n{unfinished\n'
            expected = 4
        else:
            raw = json.dumps(None if name == 'null' else [receipt]) + '\n'
            expected = 4
        exit_code = 17 if name in ('valid-failure', 'success-nonzero') else 23 if name in (
            'missing-nonzero', 'failure-mismatched-exit') else 0
        (case / 'backend.stdout').write_text(raw)
        (case / 'backend.stderr').write_text(noise)
        (case / 'backend.exit').write_text(str(exit_code) + '\n')
        result, value = run(case, boundary)
        label = boundary + '/' + name
        check(label + ': observed status and complete receipt agree',
              result.returncode == expected and value.get('exit_code') == expected and
              value.get('status') == ('success' if success else 'failed'))
        if success:
            check(label + ': valid multiline receipt preserves the actual artifact identity',
                  value.get('artifact_path') == str(artifact) and value.get('method') == receipt['method'])
            check(label + ': caller umask still controls backend-created files',
                  int((case / 'backend.umask').read_text().strip(), 8) == 0o027 and
                  stat.S_IMODE((case / 'backend.created').stat().st_mode) == 0o640)
            if boundary == 'worker':
                check(label + ': private stdout mode does not change backend noclobber policy',
                      stat.S_IMODE((case / 'attempt.json.stdout').stat().st_mode) == 0o600 and
                      'C' in (case / 'backend.flags').read_text())
                frozen = value.get('resume_artifacts', [])
                check(label + ': real artifact bytes become durable reuse evidence',
                      len(frozen) == 1 and frozen[0]['path'] == str(artifact) and
                      frozen[0]['sha256'] == hashlib.sha256(artifact.read_bytes()).hexdigest())
        else:
            check(label + ': invalid or unsuccessful output cannot authorize reuse',
                  'resume_artifacts' not in value and value.get('status') != 'success')
        diagnostics = (case / 'attempt.log').read_bytes() if boundary == 'worker' else result.stderr
        check(label + ': original diagnostic text is retained', noise.encode() in diagnostics)

# Retained bytes cannot rehabilitate a contradictory outcome from an earlier
# run. Use the real successful worker receipt and its actual frozen artifact,
# changing only the declared exit code at the production reuse boundary.
completed = root / 'worker-valid-pretty'
saved = json.loads((completed / 'attempt.json').read_bytes())
reuse_driver = r'''set -uo pipefail
source "$1" || exit 90
result=$(cat -- "$2") || exit 4
_act_target_result_available "$result" release true
'''
for name, code in (('zero', 0), ('missing', 0), ('nonzero', 17), ('string', '0'),
                   ('null', None), ('fraction', 0.5), ('negative', -1), ('boolean', False)):
    candidate = dict(saved)
    if name == 'missing':
        candidate.pop('exit_code', None)
    else:
        candidate['exit_code'] = code
    receipt = completed / ('reuse-' + name + '.json')
    receipt.write_text(json.dumps(candidate) + '\n')
    result = subprocess.run(['bash', '-c', reuse_driver, '_', str(module), str(receipt)],
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
    (completed / ('reuse-' + name + '.stderr')).write_bytes(result.stderr)
    check('retained/' + name + ': only a coherent success can authorize frozen-byte reuse',
          result.returncode == (0 if name in ('zero', 'missing') else 1))

# The raw attempt channel is write-once too; a conflicting file, link, FIFO or
# directory cannot be overwritten or opened by a backend before admission.
for kind in ('regular', 'symlink', 'fifo', 'directory'):
    case, artifact, receipt = fixture('worker', 'occupied-' + kind)
    path = case / 'attempt.json.stdout'
    held = case / 'held-evidence'
    held.write_bytes(b'original retained evidence\n')
    if kind == 'regular':
        path.write_bytes(held.read_bytes())
    elif kind == 'symlink':
        path.symlink_to(held)
    elif kind == 'fifo':
        os.mkfifo(path)
    else:
        path.mkdir()
    (case / 'backend.stdout').write_text(json.dumps(receipt) + '\n')
    (case / 'backend.stderr').write_text('backend must never run\n')
    (case / 'backend.exit').write_text('0\n')
    before = path.lstat()
    result, value = run(case, 'worker')
    after = path.lstat()
    check('worker/occupied-' + kind + ': refuse before execution and preserve prior evidence',
          result.returncode != 0 and value.get('status') == 'failed' and
          value.get('backend_started') is False and
          not (case / 'backend.started').exists() and
          (before.st_dev, before.st_ino, before.st_mode, before.st_size) ==
          (after.st_dev, after.st_ino, after.st_mode, after.st_size) and
          held.read_bytes() == b'original retained evidence\n' and
          (kind != 'regular' or path.read_bytes() == held.read_bytes()))

# Exercise the real workflow producer around an external act executable.
# No Docker/compiler behavior is simulated as proof of compilation here.
for name in ('success', 'failure', 'serializer'):
    case, artifact, receipt = fixture('workflow', name)
    (case / 'workflow.yml').write_text('name: fixture\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n')
    (case / 'bin').mkdir()
    executable = case / 'bin/act'
    executable.write_text('''#!/usr/bin/env bash
set -uo pipefail
while (( $# )); do
    if [[ "$1" == --artifact-server-path ]]; then
        printf 'real workflow output\\n' > "$2/output.bin"
        shift
    fi
    shift
done
printf 'workflow stdout diagnostic\\n'
printf '{"status":"success","artifact_count":999,"log_record":true}\\n'
printf 'workflow stderr diagnostic\\n' >&2
exit ''' + ('17' if name == 'failure' else '0') + '\n')
    executable.chmod(0o700)
    result, value = run(case, 'workflow-serializer' if name == 'serializer' else 'workflow')
    expected = 4 if name == 'serializer' else 6 if name == 'failure' else 0
    check('workflow/' + name + ': actual producer preserves execution or serialization failure',
          result.returncode == expected and
          (not result.stdout if name == 'serializer' else
           value.get('exit_code') == expected and value.get('artifact_count') == 1 and
           value.get('status') == ('success' if name == 'success' else 'failed')))
    check('workflow/' + name + ': stdout and stderr logs stay diagnostic',
          b'workflow stdout diagnostic' in result.stderr and
          b'workflow stderr diagnostic' in result.stderr and
          b'"log_record":true' in result.stderr and b'"log_record":true' not in result.stdout)
    logs = list((case / 'logs').glob('*.log'))
    check('workflow/' + name + ': original compiler streams remain in the durable log',
          len(logs) == 1 and b'workflow stdout diagnostic' in logs[0].read_bytes() and
          b'workflow stderr diagnostic' in logs[0].read_bytes())

(root / 'summary.json').write_text(json.dumps(dict(checks=checks, failures=failures)) + '\n')
print('Backend receipt isolation: %d checks, %d failures' % (checks, len(failures)), flush=True)
raise SystemExit(bool(failures))
PY
}

if [[ "${1:-}" == --backend-receipt-only ]]; then
    test_backend_receipt_isolation
    exit $?
fi

test_receipt_producer() {
    local project_root dependency
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    for dependency in python3 bash jq; do
        command -v "$dependency" >/dev/null || { echo "Missing test dependency: $dependency" >&2; return 77; }
    done
    python3 -I - "${DSR_TEST_ACT_RUNNER:-$project_root/src/act_runner.sh}" "${DSR_TEST_RECEIPT_BASELINE:-}" <<'PY'
import ctypes
import hashlib
import json
import os
from pathlib import Path
import select
import stat
import struct
import subprocess
import sys
import tempfile
import time

module = Path(sys.argv[1]).resolve()
baseline = Path(sys.argv[2]).resolve() if sys.argv[2] else None
work = Path(tempfile.mkdtemp(prefix='dsr-receipt-producer-')).resolve()
print('Retained receipt producer fixtures: ' + str(work), flush=True)
checks, failures, timings = 0, [], {}


def check(label, condition):
    global checks
    checks += 1
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    if not condition:
        failures.append(label)


driver = r'''set -uo pipefail
source "$1" || exit 90
if [[ "$3" == incumbent ]]; then source "$4" || exit 91; fi
if [[ "$3" == portable ]]; then
    command() {
        if [[ $# == 2 && "$1" == -v && "$2" == python3 ]]; then return 1; fi
        builtin command "$@"
    }
elif [[ "$3" == python-failure || "$3" == python-empty || "$3" == python-late-failure || "$3" == python-documents ]]; then
    receipt_fixture_fallback_marker=$5
    receipt_fixture_python_mode=$3
    set +o pipefail
    python3() {
        case "$receipt_fixture_python_mode" in
            python-failure) return 17 ;;
            python-empty) return 0 ;;
            python-late-failure) printf '[]\n'; return 17 ;;
            python-documents) printf '[]\n[]\n'; return 0 ;;
        esac
    }
    _act_sha256() { printf 'unexpected fallback\n' > "$receipt_fixture_fallback_marker"; return 91; }
fi
result=$(cat "$2") || exit 4
if [[ "$3" == reuse ]]; then
    _act_target_result_available "$result" release true
else
    _act_result_artifact_receipts "$result"
fi
'''


def arguments(input_path, mode):
    return ['bash', '-c', driver, '_', str(module), str(input_path), mode,
            str(baseline or ''), str(work / 'unexpected-fallback')]


def save(name, value):
    path = work / (name + '.json')
    path.write_text(json.dumps(value) + '\n')
    return path


def run(input_path, mode, label):
    started = time.monotonic()
    result = subprocess.run(arguments(input_path, mode), capture_output=True, timeout=120)
    timings[label] = time.monotonic() - started
    (work / (label + '.stdout')).write_bytes(result.stdout)
    (work / (label + '.stderr')).write_bytes(result.stderr)
    return result


def receipt_matches(result, paths):
    try:
        rows = json.loads(result.stdout)
        expected = {str(path): path for path in paths}
        return (result.returncode == 0 and isinstance(rows, list) and
                len(rows) == len(expected) and {row['path'] for row in rows} == set(expected) and
                all(set(row) == {'path', 'sha256', 'size_bytes', 'identity'} and
                    row['sha256'] == hashlib.sha256(expected[row['path']].read_bytes()).hexdigest() and
                    row['size_bytes'] == expected[row['path']].stat().st_size and row['identity'] in (
                        'gnu:%s:%s' % (expected[row['path']].stat().st_dev, expected[row['path']].stat().st_ino),
                        'bsd:%s' % expected[row['path']].stat().st_ino) for row in rows))
    except (OSError, ValueError, TypeError, KeyError):
        return False


def snapshot(paths):
    return [(str(path), path.stat().st_dev, path.stat().st_ino, path.stat().st_mode,
             path.stat().st_nlink, path.stat().st_uid, path.stat().st_gid, path.stat().st_size,
             path.stat().st_mtime_ns, path.stat().st_ctime_ns,
             hashlib.sha256(path.read_bytes()).hexdigest()) for path in paths]


files = work / 'actual-artifacts'
files.mkdir()
for index in range(198):
    (files / ('artifact-%03d.bin' % index)).write_bytes(bytes(range(256)) * (index % 31 + 1))
(files / 'empty').write_bytes(b'')
special = files / "quote'comma,backslash\\unicode-界面\nartifact"
special.write_bytes(b'path framing and exact digest\n')
(files / 'multiple-read-blocks.bin').write_bytes(bytes(range(256)) * 16385)
paths = sorted(files.iterdir())
input_path = save('complete', dict(artifact_dir=str(files), artifact_paths=[str(special)]))
before = snapshot(paths)
candidate = run(input_path, 'candidate', 'candidate-complete')
check('one producer preserves every real path, digest, size and inode', receipt_matches(candidate, paths))
check('inventory capture preserves all artifact bytes, modes and identities', snapshot(paths) == before)
if baseline:
    incumbent = run(input_path, 'incumbent', 'incumbent-complete')
    check('actual incumbent in the same invocation captures the same complete files', receipt_matches(incumbent, paths))
    check('candidate and actual incumbent receipts are byte-identical', candidate.stdout == incumbent.stdout)
    check('paired capture preserves every original artifact', snapshot(paths) == before)
    print('Paired real-file capture: files=%d candidate=%.6fs incumbent=%.6fs' %
          (len(paths), timings['candidate-complete'], timings['incumbent-complete']), flush=True)
    print('Incumbent function sha256=' + hashlib.sha256(baseline.read_bytes()).hexdigest(), flush=True)

framing = work / 'filename-framing'
framing.mkdir()
characters = [chr(index) for index in range(1, 32)] + [chr(index) for index in (127, 133, 160, 0x2028, 0x2029, 0x1f603, 0xffff)]
for index, character in enumerate(characters):
    (framing / ('name-%02d-%s-tail' % (index, character))).write_bytes(b'exact JSON filename framing\n')
framing_paths = sorted(framing.iterdir())
input_path = save('filename-framing', dict(artifact_dir=str(framing)))
framed = run(input_path, 'candidate', 'candidate-framing')
check('control characters, DEL and Unicode retain exact paths and digests', receipt_matches(framed, framing_paths))
if baseline:
    original = run(input_path, 'incumbent', 'incumbent-framing')
    check('all supported filename escapes match the actual incumbent byte for byte',
          original.returncode == 0 and original.stdout == framed.stdout)
if framed.returncode == 0:
    reusable = save('framing-reuse', dict(status='success', method='native', build_purpose='release',
                                        publishable=True, artifact_dir=str(framing),
                                        resume_artifacts=json.loads(framed.stdout)))
    check('actual reuse admission accepts unchanged files with every supported filename escape',
          run(reusable, 'reuse', 'framing-reuse').returncode == 0)
else:
    check('actual reuse admission accepts unchanged files with every supported filename escape', False)

controls = work / 'controls'
controls.mkdir()
plain = controls / 'plain'
plain.write_bytes(b'ordinary data\n')
empty = controls / 'empty'
empty.write_bytes(b'')
linked = controls / 'file-link'
linked.symlink_to(plain)
tree = controls / 'ordinary-tree'
(tree / 'nested').mkdir(parents=True)
(tree / 'one').write_bytes(b'one\n')
(tree / 'nested/two').write_bytes(b'two\n')
(tree / 'file-link').symlink_to(plain)
(tree / 'directory-link').symlink_to(files, target_is_directory=True)
os.mkfifo(tree / 'pipe')
plain_workflow = controls / 'plain-workflow'
plain_workflow.mkdir()
(plain_workflow / 'output').write_bytes(b'workflow output\n')
workflow_link = controls / 'workflow-root-link'
workflow_link.symlink_to(plain_workflow, target_is_directory=True)
hard_workflow = controls / 'hardlink-workflow'
hard_workflow.mkdir()
os.link(plain, hard_workflow / 'output')
special_workflow = controls / 'special-workflow'
special_workflow.mkdir()
os.mkfifo(special_workflow / 'pipe')
empty_tree = controls / 'empty-tree'
empty_tree.mkdir()
cases = [
    ('array-precedence', dict(artifact_paths=[str(plain), str(empty)], artifact_path=str(controls / 'missing')), [plain, empty]),
    ('deduplication', dict(artifact_paths=[str(plain), str(plain), str(empty)],
                          additional_artifacts=[dict(path=str(plain))]), [plain, empty]),
    ('legacy-paths', dict(artifact_path=str(plain) + ',' + str(empty)), [plain, empty]),
    ('ordinary-links-and-specials', dict(artifact_dir=str(tree)), [tree / 'one', tree / 'nested/two']),
    ('workflow-regular-files', dict(workflow_payload_dir=str(plain_workflow)), [plain_workflow / 'output']),
    ('missing-file', dict(artifact_paths=[str(plain), str(controls / 'missing')]), None),
    ('explicit-symlink', dict(artifact_paths=[str(linked)]), None),
    ('explicit-fifo', dict(artifact_paths=[str(tree / 'pipe')]), None),
    ('empty-tree', dict(artifact_dir=str(empty_tree)), None),
    ('workflow-root-symlink', dict(workflow_payload_dir=str(workflow_link)), None),
    ('workflow-hardlink', dict(workflow_artifact_dir=str(hard_workflow)), None),
    ('workflow-special-file', dict(workflow_artifact_dir=str(special_workflow)), None),
    ('workflow-linked-namespace', dict(workflow_payload_dir=str(tree)), None),
    ('malformed-path-array', dict(artifact_paths='not an array'), None),
    ('malformed-additional-array', dict(additional_artifacts='not an array'), None),
]
unreadable = controls / 'unreadable'
unreadable.write_bytes(b'permission refusal\n')
unreadable.chmod(0)
if not os.access(unreadable, os.R_OK):
    cases.append(('unreadable-file', dict(artifact_paths=[str(unreadable)]), None))
else:
    print('SKIP unreadable-file control: this user can read mode000 files', flush=True)
for name, content, expected in cases:
    input_path = save(name, content)
    observed = {}
    for mode in ('candidate', 'incumbent') if baseline else ('candidate',):
        result = run(input_path, mode, mode + '-' + name)
        observed[mode] = result
        check(mode + ': ' + name,
              receipt_matches(result, expected) if expected is not None else
              result.returncode == 4 and not result.stdout)
    if baseline and expected is not None:
        check(name + ': both producers emit identical receipts', observed['candidate'].stdout == observed['incumbent'].stdout)

portable = save('portable', dict(artifact_paths=[str(plain), str(empty), str(special)]))
check('Python absence retains the actual portable producer and exact filenames',
      receipt_matches(run(portable, 'portable', 'portable'), [plain, empty, special]))
refused = run(save('portable-missing', dict(artifact_paths=[str(controls / 'missing')])),
              'portable', 'portable-missing')
check('portable producer still refuses missing files without partial JSON', refused.returncode == 4 and not refused.stdout)
refused = run(portable, 'python-failure', 'python-failure')
check('a failed Python producer never falls back even without caller pipefail',
      refused.returncode == 17 and not refused.stdout and not (work / 'unexpected-fallback').exists())
for mode, expected_status in (('python-empty', 4), ('python-late-failure', 17), ('python-documents', 4)):
    refused = run(portable, mode, mode)
    check(mode + ': failed or incomplete producer evidence never reaches stdout without caller pipefail',
          refused.returncode == expected_status and not refused.stdout and not (work / 'unexpected-fallback').exists())

# Observe a real first read before changing a real regular file. No hash,
# stat, filesystem or producer implementation is replaced by this control.
# The sparse extent bounds storage while the real hash still reads its bytes.
if sys.platform.startswith('linux'):
    unrepresentable = controls / 'non-utf8-tree'
    unrepresentable.mkdir()
    with open(os.fsencode(unrepresentable) + b'/invalid-\xff', 'wb') as stream:
        stream.write(b'cannot claim a replacement-character JSON path\n')
    refused = run(save('non-utf8', dict(artifact_dir=str(unrepresentable))), 'candidate', 'non-utf8')
    check('unrepresentable filesystem names refuse instead of changing the JSON path',
          refused.returncode == 4 and not refused.stdout)
    libc = ctypes.CDLL(None, use_errno=True)
    libc.inotify_init1.argtypes, libc.inotify_init1.restype = [ctypes.c_int], ctypes.c_int
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    libc.inotify_add_watch.restype = ctypes.c_int
    races = [(mode, mutation) for mutation in ('truncate', 'replace')
             for mode in (('incumbent', 'candidate') if baseline else ('candidate',))]
    for mode, mutation in races:
        label = mode + '-' + mutation
        path = controls / ('changing-' + label)
        with path.open('wb') as stream:
            stream.truncate(256 * 1024 * 1024)
        input_path = save('changing-' + label, dict(artifact_paths=[str(path)]))
        descriptor = libc.inotify_init1(os.O_CLOEXEC)
        if descriptor < 0:
            raise OSError(ctypes.get_errno(), 'inotify_init1')
        process = None
        observed_read = False
        try:
            if libc.inotify_add_watch(descriptor, os.fsencode(path), 1) < 0:
                raise OSError(ctypes.get_errno(), 'inotify_add_watch')
            process = subprocess.Popen(arguments(input_path, mode), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if select.select([descriptor], [], [], 10)[0]:
                event = os.read(descriptor, 4096)
                observed_read = bool(struct.unpack_from('iIII', event)[1] & 1)
                if mutation == 'replace':
                    path.rename(controls / ('retained-original-' + label))
                with path.open('wb') as stream:
                    stream.write(b'changed while hashing\n')
            stdout, stderr = process.communicate(timeout=20)
        finally:
            os.close(descriptor)
            if process is not None and process.poll() is None:
                process.kill()
                process.communicate()
        (work / (label + '-changing.stdout')).write_bytes(stdout)
        (work / (label + '-changing.stderr')).write_bytes(stderr)
        check(label + ': mutation occurs after a real file read', observed_read)
        if mode == 'candidate':
            check(mutation + ': held-file capture refuses changed bytes with empty stdout',
                  process.returncode == 4 and not stdout and b'artifact changed' in stderr.lower())
        else:
            # This is evidence of the original defect, never an expected
            # admission for the candidate or an excuse to suppress a refusal.
            unsafe = subprocess.CompletedProcess([], process.returncode, stdout, stderr)
            check(mutation + ': actual incumbent demonstrates an inconsistent receipt during mutation',
                  process.returncode == 0 and not receipt_matches(unsafe, [path]))

summary = dict(checks=checks, failures=failures, timings=timings, artifact_count=len(paths))
(work / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print('Receipt producer: %d checks, %d failures' % (checks, len(failures)), flush=True)
raise SystemExit(bool(failures))
PY
}

if [[ "${1:-}" == --receipt-producer-only ]]; then
    test_receipt_producer
    exit $?
fi

# Only the build backend is controlled here. The actual target worker owns
# the process group, captures checksums/inodes, serializes its attempt result,
# and independently verifies the same files for reuse.
test_worker_artifact_inventory() {
    local project_root dependency
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    for dependency in python3 bash jq; do
        command -v "$dependency" >/dev/null || { echo "Missing test dependency: $dependency" >&2; return 77; }
    done
    python3 -I - "${DSR_TEST_ACT_RUNNER:-$project_root/src/act_runner.sh}" <<'PY'
import errno
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

module = Path(sys.argv[1]).resolve()
work = Path(tempfile.mkdtemp(prefix='dsr-worker-artifact-inventory-')).resolve()
print('Retained worker artifact fixtures: ' + str(work), flush=True)
checks, failures = 0, []


def check(label, condition):
    global checks
    checks += 1
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    if not condition:
        failures.append(label)


driver = r'''set -uo pipefail
source "$1" || exit 90
fixture=$2
ACT_LOGS_DIR="$fixture/logs"
act_platform_uses_act() { return 0; }
_act_build_orchestration_target() { cat "$fixture/backend.json"; }
if [[ "$3" == verify ]]; then
    result=$(cat "$fixture/attempt.json") || exit 4
    _act_target_result_available "$result" release true
    exit $?
fi
if [[ "$3" == serializer-failure ]]; then
    jq() {
        local argument
        for argument in "$@"; do
            if [[ "$argument" == receipts ]]; then
                printf 'injected receipt serialization failure\n' >&2
                return 23
            fi
        done
        command jq "$@"
    }
fi
_act_run_target_worker tool v1.0.0 fixture-run linux/amd64 1 \
    "$fixture/attempt.log" "$fixture/attempt.json" false null '{}' '' '' act-local release
'''


def fixture(name, count):
    case = work / name
    artifact_dir = case / 'artifact files'
    if count > 1:
        # Real long stage paths cross the argv byte bound with fewer hashes.
        # Each component and full path remains within macOS/Linux limits;
        # no invented fields or padded receipt strings create the scale case.
        for component in (
                'pinned-source-workspace-with-local-dependency-repositories',
                'target-x86_64-unknown-linux-gnu-for-portable-release-builds',
                'locked-offline-profile-with-generated-native-build-support',
                'package-manager-and-native-installer-companion-collection',
                'retained-release-candidate-550e8400-e29b-41d4-a716-446655440010',
                'compiler-and-linker-verified-artifact-staging-area',
                'workflow-matrix-compatibility-and-debug-symbol-outputs',
                'source-archive-binary-bundle-and-supplemental-manifests'):
            artifact_dir /= component
    artifact_dir.mkdir(parents=True)
    (case / 'logs').mkdir()
    for index in range(count):
        path = artifact_dir / ('package-%04d-1.0.0-linux-x86_64.payload' % index)
        path.write_bytes(('genuine retained artifact %d\n' % index).encode())
    # Inventory framing must also preserve legal filesystem names that cannot
    # safely pass through a newline/comma-separated path list.
    special = artifact_dir / "quote'comma,unicode-界面\nartifact"
    special.write_bytes(b'framing boundary\n')
    (case / 'backend.json').write_text(json.dumps({
        'platform': 'linux/amd64', 'method': 'act', 'host': 'act-local', 'status': 'success',
        'exit_code': 0, 'artifact_dir': str(artifact_dir),
        'artifact_paths': sorted(map(str, artifact_dir.iterdir()))}) + '\n')
    return case


def invoke(case, mode, label):
    result = subprocess.run(['bash', '-c', driver, '_', str(module), str(case), mode],
                            capture_output=True, text=True, timeout=120)
    (case / (label + '.stdout')).write_text(result.stdout)
    (case / (label + '.stderr')).write_text(result.stderr)
    return result


def document(case):
    try:
        return json.loads((case / 'attempt.json').read_text())
    except (OSError, ValueError):
        return {}


for name, count in (('small', 1), ('large', 200)):
    case = fixture(name, count)
    result = invoke(case, 'worker', 'completion')
    receipt = document(case)
    check(name + ': actual worker completes with one valid successful result',
          result.returncode == 0 and receipt.get('status') == 'success' and
          receipt.get('exit_code') == 0 and receipt.get('backend_started') is True)
    entries = receipt.get('resume_artifacts', [])
    paths = {str(path): path for path in (case / 'artifact files').rglob('*') if path.is_file()}
    check(name + ': completion preserves every path, checksum, size and inode',
          len(entries) == len(paths) and {row['path'] for row in entries} == set(paths) and
          all(row['sha256'] == hashlib.sha256(paths[row['path']].read_bytes()).hexdigest() and
              row['size_bytes'] == paths[row['path']].stat().st_size and
              row['identity'] in (
                  'gnu:%s:%s' % (paths[row['path']].stat().st_dev, paths[row['path']].stat().st_ino),
                  'bsd:%s' % paths[row['path']].stat().st_ino) for row in entries))
    if name == 'large':
        serialized = json.dumps(entries, separators=(',', ':'))
        check('large: authentic inventory exceeds the Linux single-argument limit',
              len(serialized.encode()) > 131072)
        if sys.platform.startswith('linux'):
            try:
                subprocess.run([shutil.which('jq'), '-n', '--argjson', 'receipts', serialized, '$receipts'],
                               capture_output=True, check=False)
            except OSError as error:
                check('large: unchanged argv transport fails with actual E2BIG', error.errno == errno.E2BIG)
            else:
                check('large: unchanged argv transport fails with actual E2BIG', False)
    check(name + ': independent reuse verification accepts all unchanged bytes',
          invoke(case, 'verify', 'reuse').returncode == 0)
    selected = min(paths.values())
    original = selected.read_bytes()
    selected.write_bytes(original + b'changed after completion\n')
    check(name + ': changed artifact bytes refuse reuse without changing the receipt',
          invoke(case, 'verify', 'changed').returncode != 0 and document(case) == receipt)
    selected.write_bytes(original)
    selected.rename(case / 'retained-missing-artifact')
    check(name + ': missing artifact refuses reuse without dropping its frozen row',
          invoke(case, 'verify', 'missing').returncode != 0 and document(case) == receipt)

case = fixture('serializer-failure', 1)
result = invoke(case, 'serializer-failure', 'completion')
receipt = document(case)
check('serialization failure returns nonzero and retains an explicit failed attempt',
      result.returncode == 4 and receipt.get('status') == 'failed' and
      receipt.get('exit_code') == 4 and receipt.get('backend_started') is True and
      'could not be frozen' in receipt.get('error', '') and 'resume_artifacts' not in receipt and
      'injected receipt serialization failure' in result.stderr)
check('serialization failure cannot produce reusable success evidence',
      invoke(case, 'verify', 'reuse').returncode != 0)

case = fixture('missing-at-completion', 1)
(case / 'backend.json').write_text(json.dumps({
    'platform': 'linux/amd64', 'method': 'act', 'status': 'success',
    'exit_code': 0, 'artifact_path': str(case / 'does-not-exist')}) + '\n')
result = invoke(case, 'worker', 'completion')
receipt = document(case)
check('missing output cannot be frozen as a successful attempt',
      result.returncode == 4 and receipt.get('status') == 'failed' and
      receipt.get('exit_code') == 4 and 'resume_artifacts' not in receipt)

(work / 'summary.json').write_text(json.dumps({'checks': checks, 'failures': failures}) + '\n')
print('Worker artifact inventory: %d checks, %d failures' % (checks, len(failures)), flush=True)
raise SystemExit(bool(failures))
PY
}

if [[ "${1:-}" == --artifact-inventory-only ]]; then
    test_worker_artifact_inventory
    exit $?
fi

# Exercise the production ZIP collector and independent workflow admission.
# The Linux fixture uses existing files below valid deep stage paths to cross
# the argument limit without hundreds of archive/content validation processes.
test_workflow_artifact_inventory() {
    local project_root dependency
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    for dependency in python3 bash jq tar gzip unzip; do
        command -v "$dependency" >/dev/null || { echo "Missing test dependency: $dependency" >&2; return 77; }
    done
    python3 -I - "${DSR_TEST_ACT_RUNNER:-$project_root/src/act_runner.sh}" <<'PY'
import copy
import errno
import hashlib
import io
import json
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile

module = Path(sys.argv[1]).resolve()
work = Path(tempfile.mkdtemp(prefix='dsr-workflow-inventory-')).resolve()
print('Retained workflow inventory fixtures: ' + str(work), flush=True)
checks, failures = 0, []


def check(label, condition):
    global checks
    checks += 1
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    if not condition:
        failures.append(label)


driver = r'''set -uo pipefail
source "$1" || exit 90
fixture=$2
ACT_ARTIFACTS_DIR=$(cat "$fixture/stage-path") || exit 4
plan=$(cat "$fixture/plan.json") || exit 4
result=$(cat "$fixture/$3.json") || exit 4
if [[ "$3" == backend ]]; then
    _act_materialize_workflow_payloads "$result" "$plan"
else
    _act_validate_workflow_payload_result "$result" "$plan"
fi
'''


def invoke(name):
    result = subprocess.run(['bash', '-c', driver, '_', str(module), str(work), name],
                            capture_output=True, text=True, timeout=120)
    (work / (name + '.stdout')).write_text(result.stdout)
    (work / (name + '.stderr')).write_text(result.stderr)
    return result


def save(name, value):
    (work / (name + '.json')).write_text(json.dumps(value) + '\n')


stage = work / 'retained-build-stage'
large = sys.platform.startswith('linux')
if large:
    # Leave ample room below Linux PATH_MAX for the private workflow directory
    # and its payload names. Every byte contributing to the JSON size names a
    # real directory or file; no fake inventory entries or padding are used.
    index = 0
    while len(str(stage).encode()) < 3760:
        stage /= 'release-candidate-%02d-source-dependencies-and-compiler-artifact-staging' % index
        index += 1
stage.mkdir(parents=True)
(work / 'stage-path').write_text(str(stage) + '\n')
raw = stage / 'uploads'
raw.mkdir()

header = bytearray(64)
header[:7] = b'\x7fELF\x02\x01\x01'
struct.pack_into('<HHI', header, 16, 2, 62, 1)
header.extend(b'inert format-admission fixture; never executed\n')
primary_name = 'inventory-tool-1.0.0-linux-amd64.tar.gz'
primary = io.BytesIO()
with tarfile.open(fileobj=primary, mode='w:gz') as archive:
    member = tarfile.TarInfo('inventory-tool')
    member.size, member.mode, member.mtime = len(header), 0o755, 0
    archive.addfile(member, io.BytesIO(header))
payloads = {primary_name: primary.getvalue()}
triple = 'x86_64-unknown-linux-gnu'
outputs = {primary_name: dict(role='primary', format='tar.gz', required=True, target_triple=triple)}
for index in range(33 if large else 2):
    name = 'dependency-release-metadata-%02d.json' % index
    payloads[name] = json.dumps(dict(dependency=index, target=triple, retained=True)).encode() + b'\n'
    outputs[name] = dict(role='additional', format='json', required=True,
                         owner_target_triple=triple, target_triple=triple)
wrapper = raw / 'release-uploads.zip'
with zipfile.ZipFile(wrapper, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name, data in payloads.items():
        member = zipfile.ZipInfo('dist/' + name)
        member.create_system = 3
        member.external_attr = (stat.S_IFREG | 0o644) << 16
        archive.writestr(member, data)
plan = dict(target='linux/amd64', job='build-release', version='v1.0.0',
            primaries=[dict(target_triple=triple, primary=primary_name, compat=primary_name,
                            archive_format='tar.gz')], binaries=['inventory-tool'], outputs=outputs,
            act_arguments_sha256=hashlib.sha256(b'[]').hexdigest(), matrix=None)
save('plan', plan)
save('backend', dict(method='act', platform='linux/amd64', job='build-release',
                     status='success', exit_code=0, artifact_dir=str(raw)))
result = invoke('backend')
try:
    collected = json.loads(result.stdout)
except ValueError:
    collected = {}
check('actual ZIP collection materializes a valid complete workflow result',
      result.returncode == 0 and collected.get('status') == 'success')
if not collected:
    print('Collection stderr retained in ' + str(work / 'backend.stderr'), flush=True)
    raise SystemExit(1)
save('collected', collected)
payload_dir = Path(collected['workflow_payload_dir'])
inventory = collected['workflow_inventory']
actual_paths = {str(wrapper), *(str(payload_dir / name) for name in payloads)}
check('complete transport and payload receipts bind existing paths, bytes, sizes and inodes',
      len(inventory) == len(actual_paths) and {row['path'] for row in inventory} == actual_paths and
      all(row['sha256'] == hashlib.sha256(Path(row['path']).read_bytes()).hexdigest() and
          row['size_bytes'] == Path(row['path']).stat().st_size and row['identity'] in (
              'gnu:%s:%s' % (Path(row['path']).stat().st_dev, Path(row['path']).stat().st_ino),
              'bsd:%s' % Path(row['path']).stat().st_ino) for row in inventory))
check('every declared companion retains its exact bytes and configured compiler owner',
      len(collected['additional_artifacts']) == len(payloads) - 1 and
      all(row['target_triple'] == triple and Path(row['path']).read_bytes() == payloads[Path(row['path']).name]
          for row in collected['additional_artifacts']) and
      collected['artifact_paths'] == [str(payload_dir / primary_name)] and
      collected['workflow_payload_plan'] == plan and collected['artifact_count'] == len(payloads))
if large:
    for label, document in (('companions', collected['additional_artifacts']), ('inventory', inventory),
                            ('complete result', collected)):
        serialized = json.dumps(document, separators=(',', ':'))
        check(label + ': real complete JSON exceeds the single-argument limit', len(serialized.encode()) > 131072)
        try:
            subprocess.run([shutil.which('jq'), '-n', '--argjson', 'value', serialized, '$value'],
                           capture_output=True, check=False)
        except OSError as error:
            check(label + ': previous argv transport fails with E2BIG', error.errno == errno.E2BIG)
        else:
            check(label + ': previous argv transport fails with E2BIG', False)

# The real independent validator must still reject contradictory collection
# receipts even while all original artifact bytes and inventory rows match.
contradictory = copy.deepcopy(collected)
contradictory['additional_artifacts'].pop()
save('contradictory', contradictory)
refused = invoke('contradictory')
check('independent admission rejects a missing companion receipt despite intact bytes',
      refused.returncode == 4 and 'contradictory payload receipts' in refused.stderr)

selected = payload_dir / sorted(name for name in payloads if name != primary_name)[0]
original = selected.read_bytes()
selected.write_bytes(original + b'changed after collection\n')
refused = invoke('collected')
check('changed payload bytes cannot reuse the frozen workflow inventory', refused.returncode == 4)
selected.write_bytes(original)
wrapper.rename(work / 'retained-missing-wrapper.zip')
refused = invoke('collected')
check('missing original transport cannot reuse otherwise intact payloads', refused.returncode == 4)

(work / 'summary.json').write_text(json.dumps(dict(checks=checks, failures=failures)) + '\n')
print('Workflow artifact inventory: %d checks, %d failures' % (checks, len(failures)), flush=True)
raise SystemExit(bool(failures))
PY
}

if [[ "${1:-}" == --workflow-inventory-only ]]; then
    test_workflow_artifact_inventory
    exit $?
fi

test_strict_manifest_inventory() {
    local project_root dependency
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    for dependency in python3 bash cc git jq yq; do
        command -v "$dependency" >/dev/null || { echo "Missing test dependency: $dependency" >&2; return 77; }
    done
    python3 -I - "$project_root" "${DSR_TEST_ACT_RUNNER:-$project_root/src/act_runner.sh}" \
        "$(declare -f _fixture_strict_rust_result)" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time

root, module = map(Path, sys.argv[1:3])
rust_fixture_helper = sys.argv[3]
architecture = {'x86_64': ('amd64', 'x86_64'), 'aarch64': ('arm64', 'aarch64')}.get(platform.machine())
if platform.system() != 'Linux' or architecture is None:
    print('SKIP: strict manifest executable fixture requires native Linux amd64/arm64')
    raise SystemExit(77)
target, triple = 'linux/' + architecture[0], architecture[1] + '-unknown-linux-gnu'
work = Path(tempfile.mkdtemp(prefix='dsr-strict-manifest-inventory-')).resolve()
for name in ('source', 'config/repos.d', 'payloads', 'release'):
    (work / name).mkdir(parents=True)
print('Strict manifest inventory evidence: ' + str(work), flush=True)
checks = 0

def check(label, condition):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print('PASS: ' + label, flush=True)

def save(path, value):
    path.write_text(json.dumps(value) + '\n')

def identity(path):
    info = path.stat()
    return info.st_dev, info.st_ino, info.st_mode, hashlib.sha256(path.read_bytes()).hexdigest()

def run(*args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, timeout=30)

source = work / 'source/inventoryapp.c'
source.write_text('#include <stdio.h>\nint main(void) { puts("strict inventory fixture"); return 0; }\n')
run('git', '-C', work / 'source', 'init', '-q', '-b', 'main')
run('git', '-C', work / 'source', 'add', 'inventoryapp.c')
run('git', '-C', work / 'source', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
    'commit', '-qm', 'strict manifest source fixture')
run('git', '-C', work / 'source', 'tag', 'v1.2.3')
sha = run('git', '-C', work / 'source', 'rev-parse', 'HEAD').stdout.decode().strip()
run('cc', source, '-o', work / 'inventoryapp')
check('tagged local C source produces a runnable native executable',
      run(work / 'inventoryapp').stdout == b'strict inventory fixture\n')

driver = rust_fixture_helper + '\n' + r'''set -uo pipefail
root=$1 module=$2 work=$3 target=$4 triple=$5; shift 5
export DSR_CONFIG_DIR="$work/config" DSR_REPOS_FILE="$work/config/repos.yaml"
export ACT_REPOS_DIR="$work/config/repos.d" ACT_ARTIFACTS_DIR="$work/artifacts"
export ACT_REPO_LOCAL_PATH="$work/source" NO_COLOR=1
source "$root/src/config.sh" || exit 90
source "$module" || exit 90
operation=$1; shift
case "$operation" in
    receipts) _act_result_artifact_receipts "$(cat "$1")" > "$2" ;;
    stage)
        tool=$1; shift
        mkdir "$work/collected-$tool" || exit 90
        receipt=$(_act_collect_stream_exclusive "$work/collected-$tool/inventoryapp" 700 _act_stream_local_file "$work/inventoryapp") || exit $?
        result=$(jq -c --arg target "$target" --arg triple "$triple" '
            . + {platform:$target,method:"native",host:"local-fixture",status:"success",
                 target_triple:$triple,build_purpose:"release",publishable:true,
                 artifact_path:.path,collected_sha256:.sha256,collected_size_bytes:.size_bytes,
                 collected_identity:.identity}' <<< "$receipt") || exit $?
        fixture_sha=$(git -C "$work/source" rev-parse HEAD) || exit $?
        result=$(_fixture_strict_rust_result "$result" "$fixture_sha" v1.2.3 "$work/source") || exit $?
        contract=$(config_get_release_contract_json "$tool") || exit $?
        _act_stage_contract_primary "$tool" v1.2.3 12345678-1234-1234-1234-123456789abc "$target" "$result" "$contract" > "$1" ;;
    manifest) act_generate_manifest "$(cat "$1")" "$2" ;;
    collected) _act_verify_collected_manifest "$@" ;;
    admission)
        source "$root/src/slsa.sh" || exit 90
        _slsa_manifest_statement "$1" fixture/strictinventory dsr:strict-manifest-fixture > "$2" ;;
    empty-environments|object-environments|trailing-environments)
        _act_build_environments_json() {
            case "$operation" in
                empty-environments) printf '\n' ;;
                object-environments) printf '{}\n' ;;
                trailing-environments) printf '[]\n[]\n' ;;
            esac
        }
        act_generate_manifest "$(cat "$1")" "$2" ;;
    empty-artifacts|object-artifacts|trailing-artifacts)
        # Fault injection at the final array producer, after real byte/custody
        # admission. Every other jq invocation remains the installed binary.
        jq() {
            if [[ $# -eq 2 && "$1" == -s && "$2" == . ]]; then
                case "$operation" in
                    empty-artifacts) printf '[]\n' ;;
                    object-artifacts) printf '{}\n' ;;
                    trailing-artifacts) printf '[]\n[]\n' ;;
                esac
            else command jq "$@"; fi
        }
        act_generate_manifest "$(cat "$1")" "$2" ;;
    *) exit 90 ;;
esac
'''

def invoke(label, operation, *args, input=None):
    started = time.monotonic()
    result = subprocess.run(['bash', '-c', driver, '_', str(root), str(module), str(work), target, triple,
                             operation, *map(str, args)], input=input, capture_output=True, timeout=105)
    (work / (label + '.stdout')).write_bytes(result.stdout)
    (work / (label + '.stderr')).write_bytes(result.stderr)
    print('%s: exit=%d, seconds=%.3f' % (label, result.returncode, time.monotonic() - started), flush=True)
    if result.returncode:
        print(result.stderr.decode(errors='replace')[-1200:], file=sys.stderr, flush=True)
    return result

# These legal 242-byte names and genuine files exceed argv's limit without a
# padded receipt field. The single-file control traverses the same public path.
paths = [work / 'payloads' / ('notes-%04d-' % i + 'x' * 226 + '.json') for i in range(280)]
for i, path in enumerate(paths):
    save(path, {'component': i})
original = {str(p): identity(p) for p in paths}
results, expected_rows, staged_paths = {}, {}, []
for count in (1, 280):
    tool = 'strictinventory' + str(count)
    save(work / ('config/repos.d/' + tool + '.yaml'), {
        'tool_name': tool, 'language': 'rust', 'binary_name': 'inventoryapp', 'local_path': str(work / 'source'),
        'targets': [target], 'target_triples': {target: triple}, 'act_job_map': {target: None},
        'workspace_additional_artifacts': {target: [p.name for p in paths[:count]]},
        'release_contract': {'checksum_sidecar': 'sha256',
            'exact_primary_assets': {target: 'inventoryapp-native'},
            'exact_additional_assets': [p.name for p in paths[:count]]}})
    staged = work / ('staged-%d.json' % count)
    check('production exclusive collection and strict staging succeed for %d-file case' % count,
          invoke('stage-%d' % count, 'stage', tool, staged).returncode == 0)
    row = json.loads(staged.read_bytes())
    staged_paths.append(Path(row['artifact_path']))
    original[str(staged_paths[-1])] = identity(staged_paths[-1])
    receipt_input, receipts = work / ('companions-%d.json' % count), work / ('receipts-%d.json' % count)
    save(receipt_input, {'artifact_paths': list(map(str, paths[:count]))})
    check('production receipts cover every actual companion in %d-file case' % count,
          invoke('receipts-%d' % count, 'receipts', receipt_input, receipts).returncode == 0 and
          len(json.loads(receipts.read_bytes())) == count)
    row['additional_artifacts'] = json.loads(receipts.read_bytes())
    result = {'tool': tool, 'version': '1.2.3', 'run_id': '12345678-1234-1234-1234-123456789abc',
              'git_sha': sha, 'git_ref': 'v1.2.3', 'source_dependencies': [],
              'status': 'success', 'build_purpose': 'release', 'publishable': True,
              'requested_targets': [target], 'duration_seconds': 7,
              'summary': {'total': 1, 'success': 1, 'failed': 0}, 'targets': [row]}
    results[count] = result
    expected = [{'name': 'inventoryapp-native', 'target': target, 'target_triple': triple,
                 'sha256': row['staged_sha256'], 'size_bytes': row['staged_size_bytes'],
                 'archive_format': 'binary', 'signed': False, 'signature_file': '',
                 'build_purpose': 'release', 'publishable': True}]
    expected += [{'name': Path(r['path']).name, 'sha256': r['sha256'], 'size_bytes': r['size_bytes'],
                  'archive_format': 'binary', 'signed': False, 'signature_file': '', 'target': 'additional',
                  'build_purpose': 'release', 'publishable': True} for r in row['additional_artifacts']]
    expected_rows[count] = expected
    result_path, manifest = work / ('result-%d.json' % count), work / ('manifest-%d.json' % count)
    save(result_path, result)
    generated = invoke('manifest-%d' % count, 'manifest', result_path, manifest)
    check('public strict manifest succeeds for %d actual companions' % count,
          generated.returncode == 0 and manifest.is_file() and not generated.stdout)
    observed = json.loads(manifest.read_bytes())
    check('%d-file strict manifest retains exact names, hashes, sizes, owners and source' % count,
          observed['artifacts'] == expected and observed['summary'] == result['summary'] and
          observed['source'] == {'git_sha': sha, 'git_ref': 'v1.2.3', 'dependencies': []} and
          observed['duration_ms'] == 7000 and observed['requested_targets'] == [target])
    if count == 280:
        assembled = [{k: v for k, v in r.items() if k not in ('build_purpose', 'publishable')} for r in expected]
        size = len(json.dumps(assembled, indent=2).encode())
        check('complete real strict artifact array exceeds the single-argument limit (%d bytes)' % size, size > 131072)

manifest = work / 'manifest-280.json'
for path in [staged_paths[-1], *paths]:
    shutil.copyfile(path, work / 'release' / path.name)
framed = b''.join(p.name.encode() + b'\0' for p in [staged_paths[-1], *paths])
check('all 281 strict payloads pass independent final collected-byte/name admission',
      invoke('collected', 'collected', manifest, work / 'release', '--collected', input=framed).returncode == 0)
check('complete strict manifest passes the shared successful-release profile',
      invoke('profile', 'admission', manifest, work / 'release-proof.json').returncode == 0 and
      len(json.loads((work / 'release-proof.json').read_bytes())['subject']) == 281)

def refused(label, value=None, operation='manifest', output=None, diagnostic=None):
    result_path = work / (label + '-result.json')
    save(result_path, results[280] if value is None else value)
    output = work / (label + '-manifest.json') if output is None else output
    previous = (output.stat().st_ino, output.read_bytes()) if output.exists() else None
    result = invoke(label, operation, result_path, output)
    preserved = not output.exists() if previous is None else (output.stat().st_ino, output.read_bytes()) == previous
    check(label + ' returns 4 without stdout or output mutation', result.returncode == 4 and not result.stdout and preserved)
    if diagnostic is not None:
        check(label + ' reaches the compiler-policy refusal', diagnostic in result.stderr)

# Only the compiler envelope is synthetic. Exercise the same shared fixture
# helper as the broad strict Rust orchestration cases, including refusal of old
# receipts rather than teaching the production gate to accept missing evidence.
for label, mutation, diagnostic in (
    ('missing-rust-policy', lambda r: r['targets'][0]['build_influence_env'].pop('DSR_RUST_ENV_POLICY'),
     b'lacks the current observed native compiler environment policy'),
    ('obsolete-rust-policy', lambda r: r['targets'][0]['build_influence_env'].update(DSR_RUST_ENV_POLICY='0'),
     b'lacks the current observed native compiler environment policy'),
    ('missing-rust-observation', lambda r: r['targets'][0]['cargo_isolation']['toolchain']['selection'].pop('native_environment'),
     b'lacks the current observed native compiler environment policy'),
    ('wrong-rust-source', lambda r: r['targets'][0]['build_influence_env'].update(DSR_RELEASE_GIT_SHA='1' * 40),
     b'lacks the current observed native compiler environment policy'),
    ('unreviewed-rust-selector', lambda r: r['targets'][0]['build_influence_env'].update(CPATH='/unreviewed'),
     b'no longer matches the reviewed and observed native C/SDK selectors'),
    ('changed-rust-observation', lambda r: r['targets'][0]['cargo_isolation']['toolchain']['selection']['native_environment'].update(CPATH='/unreviewed'),
     b'no longer matches the reviewed and observed native C/SDK selectors'),
):
    changed = copy.deepcopy(results[1])
    mutation(changed)
    refused(label, changed, diagnostic=diagnostic)

for label, mutation in (
    ('omitted-companion', lambda r: r['targets'][0]['additional_artifacts'].pop(0)),
    ('duplicate-companion', lambda r: r['targets'][0]['additional_artifacts'].append(copy.deepcopy(r['targets'][0]['additional_artifacts'][0]))),
    ('invented-compiler-owner', lambda r: r['targets'][0]['additional_artifacts'][0].update(target_triple=architecture[1] + '-unknown-linux-musl')),
    ('wrong-platform-owner', lambda r: r['targets'][0].update(platform='linux/arm64' if target == 'linux/amd64' else 'linux/amd64')),
    ('wrong-summary', lambda r: r['summary'].update(total=2)),
):
    changed = copy.deepcopy(results[280])
    mutation(changed)
    refused(label, changed)

first, held = paths[0], work / 'held-companion'
first.rename(held)
try:
    refused('missing-companion')
    first.write_bytes(held.read_bytes())
    refused('replaced-companion-inode')
    first.rename(work / 'retained-replacement')
    first.symlink_to(held)
    refused('symlink-companion')
    first.rename(work / 'retained-symlink')
finally:
    if first.exists() or first.is_symlink():
        first.rename(work / 'retained-unexpected-companion')
    held.rename(first)
body = first.read_bytes()
first.write_bytes(body + b'changed bytes\n')
try:
    refused('changed-companion-bytes')
finally:
    first.write_bytes(body)

changed = copy.deepcopy(results[1])
changed['targets'][0]['staged_sha256'] = '0' * 64
refused('changed-primary-receipt', changed)
for operation in ('empty-environments', 'object-environments', 'trailing-environments',
                  'empty-artifacts', 'object-artifacts', 'trailing-artifacts'):
    refused(operation, results[1], operation)
sentinel = work / 'existing-manifest.json'
sentinel.write_bytes(b'preserve existing strict output\n')
refused('serializer-preserves-existing-output', results[1], 'trailing-environments', sentinel)
refused('strict-output-never-clobbers', results[1], output=sentinel)
stdout = invoke('stdout-manifest', 'manifest', work / 'result-1.json', '')
check('stdout contains exactly one complete strict manifest document',
      stdout.returncode == 0 and json.loads(stdout.stdout)['artifacts'] == expected_rows[1])
diagnostic = copy.deepcopy(results[1])
for row in [diagnostic, *diagnostic['targets']]:
    row.update(build_purpose='diagnostic-native', publishable=False)
save(work / 'diagnostic-result.json', diagnostic)
generated = invoke('diagnostic', 'manifest', work / 'diagnostic-result.json', work / 'diagnostic-manifest.json')
check('diagnostic strict manifests retain nonpublishable purpose on every row', generated.returncode == 0 and
      all(r['build_purpose'] == 'diagnostic-native' and r['publishable'] is False
          for r in [json.loads((work / 'diagnostic-manifest.json').read_bytes()),
                    *json.loads((work / 'diagnostic-manifest.json').read_bytes())['artifacts']]))
check('all original staged and companion bytes, modes and inodes survive success and refusals', original ==
      {str(p): identity(p) for p in [*paths, *staged_paths]})
check('tagged source remains clean', not run('git', '-C', work / 'source', 'status', '--porcelain').stdout)
print('Strict manifest inventory: %d checks passed' % checks, flush=True)
print('Compilation is local cc; Rust compiler envelopes are synthetic unit data, not native Rust execution evidence.', flush=True)
PY
}

if [[ "${1:-}" == --strict-manifest-inventory-only ]]; then
    test_strict_manifest_inventory
    exit $?
fi

test_native_matrix_inventory() {
    local project_root dependency
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    for dependency in python3 bash cc git jq yq; do
        command -v "$dependency" >/dev/null || { echo "Missing test dependency: $dependency" >&2; return 77; }
    done
    python3 -I - "$project_root" "${DSR_TEST_ACT_RUNNER:-$project_root/src/act_runner.sh}" <<'PY'
import copy
import hashlib
import io
import json
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
import time

root, module = map(Path, sys.argv[1:])
architecture = {'x86_64': ('amd64', 'x86_64'), 'aarch64': ('arm64', 'aarch64')}.get(platform.machine())
if platform.system() != 'Linux' or architecture is None:
    print('SKIP: native matrix archive fixture requires local Linux amd64/arm64')
    raise SystemExit(77)
target = 'linux/' + architecture[0]
triples = [architecture[1] + '-unknown-linux-' + libc for libc in ('gnu', 'musl')]
work = Path(tempfile.mkdtemp(prefix='dsr-native-matrix-inventory-')).resolve()
for name in ('source', 'config/repos.d', 'payloads'):
    (work / name).mkdir(parents=True)
print('Native matrix inventory evidence: ' + str(work), flush=True)
checks = 0

def check(label, condition):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print('PASS: ' + label, flush=True)

def save(path, value):
    path.write_text(json.dumps(value) + '\n')

def identity(path):
    info = path.stat()
    return info.st_dev, info.st_ino, info.st_mode, hashlib.sha256(path.read_bytes()).hexdigest()

def run(*args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, timeout=30)

source = work / 'source/inventoryapp.c'
source.write_text('#include <stdio.h>\nint main(void) { puts("matrix inventory fixture"); return 0; }\n')
run('git', '-C', work / 'source', 'init', '-q', '-b', 'main')
run('git', '-C', work / 'source', 'add', 'inventoryapp.c')
run('git', '-C', work / 'source', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
    'commit', '-qm', 'matrix manifest source fixture')
run('git', '-C', work / 'source', 'tag', 'v1.2.3')
sha = run('git', '-C', work / 'source', 'rev-parse', 'HEAD').stdout.decode().strip()
run('cc', source, '-o', work / 'inventoryapp')
check('archive payload is a real locally compiled and runnable C executable',
      run(work / 'inventoryapp').stdout == b'matrix inventory fixture\n')
save(work / 'config/repos.d/matrixinventory.yaml', {
    'tool_name': 'matrixinventory', 'binary_name': 'inventoryapp', 'local_path': str(work / 'source'),
    'targets': [target], 'act_job_map': {target: None}, 'target_triples': {target: triples}})

driver = r'''set -uo pipefail
root=$1 module=$2 work=$3; shift 3
export DSR_CONFIG_DIR="$work/config" DSR_REPOS_FILE="$work/config/repos.yaml"
export ACT_REPOS_DIR="$work/config/repos.d" ACT_REPO_LOCAL_PATH="$work/source" NO_COLOR=1
source "$root/src/config.sh" || exit 90
source "$module" || exit 90
operation=$1; shift
case "$operation" in
    receipts) _act_result_artifact_receipts "$(cat "$1")" > "$2" ;;
    manifest) act_generate_manifest "$(cat "$1")" "$2" ;;
    retained) _act_validate_native_manifest_inventory matrixinventory "$(cat "$1")" ;;
    matrix) _act_validate_native_matrix_result_inventory matrixinventory "$(cat "$1")" "$(cat "$2")" ;;
    rows-only) _act_validate_native_matrix_result_inventory matrixinventory "$(cat "$1")" ;;
    collected) _act_verify_collected_manifest "$@" ;;
    *) exit 90 ;;
esac
'''

def invoke(label, operation, *args, input=None):
    started = time.monotonic()
    result = subprocess.run(['bash', '-c', driver, '_', str(root), str(module), str(work), operation,
                             *map(str, args)], input=input, capture_output=True, timeout=105)
    (work / (label + '.stdout')).write_bytes(result.stdout)
    (work / (label + '.stderr')).write_bytes(result.stderr)
    print('%s: exit=%d, seconds=%.3f' % (label, result.returncode, time.monotonic() - started), flush=True)
    if result.returncode:
        print(result.stderr.decode(errors='replace')[-1200:], file=sys.stderr, flush=True)
    return result

# The selected compiler identities are controlled worker metadata. The payload
# is compiled by local cc, so this does not claim musl compilation or execution.
# Both archive families and their distinguishing producer labels are real bytes.
families, payloads, expected = {}, {}, {}
for triple in triples:
    archive = work / (triple + '.tar.gz')
    with tarfile.open(archive, 'w:gz') as output:
        for name, body, mode in (
            ('inventoryapp', (work / 'inventoryapp').read_bytes(), 0o755),
            ('producer.json', json.dumps({'fixture_selected_triple': triple}).encode(), 0o644),
        ):
            member = tarfile.TarInfo(name)
            member.size, member.mode = len(body), mode
            output.addfile(member, io.BytesIO(body))
    payloads[triple] = archive.read_bytes()
    paths = [work / 'payloads' / ('component-%04d-' % i + 'x' * 202 + '-' + triple + '.tar.gz')
             for i in range(150)]
    for path in paths:
        path.write_bytes(payloads[triple])
    families[triple] = paths
    expected[triple] = {'sha256': hashlib.sha256(payloads[triple]).hexdigest(), 'size_bytes': len(payloads[triple])}
all_paths = [p for triple in triples for p in families[triple]]
original = {str(p): identity(p) for p in all_paths}
results, expected_rows = {}, {}
for count in (1, 150):
    rows, artifacts = [], []
    for triple in triples:
        row = {'platform': target, 'target_triple': triple, 'task_key': target + '@' + triple,
               'method': 'native', 'host': 'controlled-fixture', 'status': 'success',
               'artifact_paths': list(map(str, families[triple][:count]))}
        row_path = work / ('row-%s-%d.json' % (triple, count))
        receipt_path = work / ('receipts-%s-%d.json' % (triple, count))
        save(row_path, row)
        check('production receipts cover %d actual %s archive files' % (count, triple),
              invoke('receipts-%s-%d' % (triple, count), 'receipts', row_path, receipt_path).returncode == 0 and
              len(json.loads(receipt_path.read_bytes())) == count)
        row['resume_artifacts'] = json.loads(receipt_path.read_bytes())
        rows.append(row)
        artifacts += [{'name': p.name, 'target': target, 'target_triple': triple, **expected[triple],
                       'archive_format': 'tar.gz', 'signed': False, 'signature_file': '',
                       'build_purpose': 'release', 'publishable': True} for p in families[triple][:count]]
    result = {'tool': 'matrixinventory', 'version': '1.2.3', 'run_id': '12345678-1234-1234-1234-123456789abc',
              'git_sha': sha, 'git_ref': 'v1.2.3', 'status': 'success',
              'summary': {'total': 2, 'success': 2, 'failed': 0}, 'requested_targets': [target], 'targets': rows}
    results[count], expected_rows[count] = result, artifacts
    result_path, manifest = work / ('result-%d.json' % count), work / ('manifest-%d.json' % count)
    save(result_path, result)
    generated = invoke('manifest-%d' % count, 'manifest', result_path, manifest)
    check('public native matrix manifest succeeds for %d actual archives' % (count * 2),
          generated.returncode == 0 and manifest.is_file() and not generated.stdout)
    observed = json.loads(manifest.read_bytes())
    check('%d-file native manifest retains every name, triple, hash, size and source' % (count * 2),
          observed['artifacts'] == artifacts and observed['summary'] == result['summary'] and
          observed['source'] == {'git_sha': sha, 'git_ref': 'v1.2.3', 'dependencies': []} and
          observed['requested_targets'] == [target])
    if count == 150:
        assembled = [{k: v for k, v in r.items() if k not in ('build_purpose', 'publishable')} for r in artifacts]
        size = len(json.dumps(assembled, separators=(',', ':')).encode())
        check('complete compact matrix inventory exceeds one exec argument (%d bytes)' % size, size > 131072)
        save(work / 'artifacts.json', assembled)

manifest = work / 'manifest-150.json'
framed = b''.join(p.name.encode() + b'\0' for p in all_paths)
check('every final matrix archive passes independent byte and collected-name admission',
      invoke('collected', 'collected', manifest, work / 'payloads', '--collected', input=framed).returncode == 0)
check('large retained manifest passes the publication-side native matrix admission',
      invoke('retained', 'retained', manifest).returncode == 0)
check('historical row-only inventory admission still accepts complete native tasks',
      invoke('rows-only', 'rows-only', work / 'result-1.json').returncode == 0)
save(work / 'no-artifacts.json', [])
failed = copy.deepcopy(results[1])
failed.update(status='failed', summary={'total': 2, 'success': 0, 'failed': 2})
for row in failed['targets']:
    row['status'] = 'failed'
save(work / 'failed-result.json', failed)
check('failed native tasks still admit an explicit empty optional artifact array',
      invoke('failed-empty', 'matrix', work / 'failed-result.json', work / 'no-artifacts.json').returncode == 0)
check('successful native tasks cannot use an empty artifact inventory',
      invoke('success-empty', 'matrix', work / 'result-1.json', work / 'no-artifacts.json').returncode == 4)
save(work / 'missing-variant-artifacts.json', [r for r in assembled if r['target_triple'] == triples[0]])
check('complete native matrix refuses an artifact inventory missing its second variant',
      invoke('missing-variant', 'matrix', work / 'result-150.json', work / 'missing-variant-artifacts.json').returncode == 4)
(work / 'trailing-artifacts.json').write_text((work / 'artifacts.json').read_text() + '[]\n')
check('matrix artifact input cannot contain a trailing second array document',
      invoke('trailing-artifacts', 'matrix', work / 'result-150.json', work / 'trailing-artifacts.json').returncode == 4)

def refused(label, value=None):
    result_path, output = work / (label + '-result.json'), work / (label + '-manifest.json')
    save(result_path, results[150] if value is None else value)
    result = invoke(label, 'manifest', result_path, output)
    check(label + ' returns 4 without stdout or a publishable manifest',
          result.returncode == 4 and not result.stdout and not output.exists())

for label, mutation in (
    ('missing-worker', lambda r: r['targets'].pop()),
    ('duplicate-worker', lambda r: r['targets'].__setitem__(1, copy.deepcopy(r['targets'][0]))),
    ('collapsed-summary', lambda r: r['summary'].update(total=1, success=1)),
    ('failed-worker-in-success', lambda r: r['targets'][0].update(status='failed')),
):
    changed = copy.deepcopy(results[150])
    mutation(changed)
    refused(label, changed)
changed = copy.deepcopy(results[1])
for row, triple in zip(changed['targets'], reversed(triples)):
    row.update(target_triple=triple, task_key=target + '@' + triple)
refused('swapped-compiler-owners', changed)
first, held = all_paths[0], work / 'held-archive'
first.rename(held)
try:
    refused('missing-archive')
    first.write_bytes(held.read_bytes())
    refused('replaced-archive-inode')
finally:
    if first.exists() or first.is_symlink():
        first.rename(work / 'retained-replacement')
    held.rename(first)
first.write_bytes(payloads[triples[0]] + b'changed\n')
try:
    refused('changed-archive-bytes')
finally:
    first.write_bytes(payloads[triples[0]])
check('all original archive bytes, modes and inodes survive generation and refusals',
      original == {str(p): identity(p) for p in all_paths})
stdout = invoke('stdout-manifest', 'manifest', work / 'result-1.json', '')
check('stdout contains exactly one complete native matrix manifest',
      stdout.returncode == 0 and json.loads(stdout.stdout)['artifacts'] == expected_rows[1])
print('Native matrix inventory: %d checks passed' % checks, flush=True)
print('Archives, C payload, hashes, receipts and admission are real; GNU/musl compiler selection is fixture metadata.', flush=True)
PY
}

if [[ "${1:-}" == --native-matrix-inventory-only ]]; then
    test_native_matrix_inventory
    exit $?
fi

# Exercise output-conflict scheduling with the real planner, coordinator,
# workers, process groups, host slots and checkpoints. Only compilation is a
# controlled subprocess; barriers prove event order without timing a build.
test_parallel_output_queue() {
    local project_root required_tool
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    for required_tool in python3 jq yq; do
        command -v "$required_tool" >/dev/null || { echo "Missing test dependency: $required_tool" >&2; return 77; }
    done
    python3 - "$project_root" "${DSR_TEST_ACT_RUNNER:-$project_root/src/act_runner.sh}" "${1:-all}" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import uuid

project, module = map(Path, sys.argv[1:3])
selection = sys.argv[3]
lookup_adapter = os.environ.get('DSR_TEST_SELECTOR_LOOKUP_ADAPTER')
if lookup_adapter:
    print('TEST-ONLY PID namespace lookup adapter: ' + lookup_adapter +
          '; production ownership lookup is not qualified by this run', flush=True)
root = Path(tempfile.mkdtemp(prefix='dsr-output-queue-'))
print('Retained output queue fixtures: ' + str(root), flush=True)
checks = failures = 0


def check(label, condition):
    global checks, failures
    checks += 1
    failures += not condition
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)


def read(path):
    return json.loads(path.read_text())


def events(case, phase='first'):
    path = case / 'events.jsonl'
    return [row for row in map(json.loads, path.read_text().splitlines())
            if row['phase'] == phase] if path.exists() else []


def until(process, predicate):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return True
        if process.poll() is not None:
            break
        time.sleep(0.02)
    return predicate()


def stopped(row):
    if lookup_adapter:
        observation = subprocess.run(['bash', '-c', 'source "$1" && _sel_process_start "$2"',
                                      'namespace-observer', lookup_adapter, str(row['pid'])],
                                     capture_output=True, text=True, timeout=10)
        return observation.returncode == 1 or (observation.returncode == 0 and
                observation.stdout.strip() != 'proc:' + row['start_ticks'])
    return subprocess.run(['ps', '-p', str(row['pid']), '-o', 'stat='],
                          capture_output=True).stdout.strip() in (b'', b'Z')


producer = root / 'producer.py'
producer.write_text(r'''import json, os, sys, time
from pathlib import Path
case, target, host, phase, mode, route = Path(sys.argv[1]), *sys.argv[2:]
targets = json.loads((case / 'targets.json').read_text())
def event(state):
    leases = []
    for path in (case / 'state/selector/locks' / host).glob('*.lock'):
        try:
            leases.append(json.loads(path.read_text()))
        except FileNotFoundError:
            pass
    owned = any(('-' + target.replace('/', '-') + '-attempt-') in row['run_id'] for row in leases)
    row = dict(target=target, host=host, state=state, phase=phase, pid=os.getpid(), lease=owned,
               start_ticks=Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()[19]
                   if Path('/proc/self/stat').exists() else '',
               stage=os.environ.get('DSR_NATIVE_OUTPUT_STAGE'), at=time.monotonic_ns())
    fd = os.open(case / 'events.jsonl', os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)
    try:
        os.write(fd, (json.dumps(row) + '\n').encode())
    finally:
        os.close(fd)
event('start')
if phase == 'first' and (target == targets[0] or
        ((mode == 'cancel' or route == 'capacity') and target == targets[-1])):
    while not (case / 'release').exists():
        time.sleep(0.02)
failed = phase == 'first' and mode == 'retry' and target == targets[1]
result = dict(platform=target, method='native', host=host,
              status='failed' if failed else 'success', exit_code=9 if failed else 0)
if failed:
    result['error'] = 'controlled compiler failure after deferred dispatch'
else:
    artifact = case / 'output' / (phase + '-' + target.replace('/', '-') + '.bin')
    with artifact.open('xb') as out:
        out.write(('scheduler fixture: ' + target + '\n').encode())
    result.update(artifact_path=str(artifact), artifact_paths=[str(artifact)])
event('end')
print(json.dumps(result), flush=True)
raise SystemExit(result['exit_code'])
''')
driver = root / 'driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$DSR_QUEUE_PROJECT/src/logging.sh" || exit
source "$DSR_QUEUE_PROJECT/src/config.sh" || exit
source "$DSR_QUEUE_PROJECT/src/build_state.sh" || exit
source "$DSR_QUEUE_MODULE" || exit
source "$DSR_QUEUE_PROJECT/src/host_selector.sh" || exit
# Opt-in executor adaptation is explicit and applies only to process lookup;
# normal runs retain the production selector and every test uses real leases.
if [[ -n "${DSR_TEST_SELECTOR_LOOKUP_ADAPTER:-}" ]]; then
    source "$DSR_TEST_SELECTOR_LOOKUP_ADAPTER" || exit
fi
source <(declare -f selector_has_capacity | sed '1s/selector_has_capacity/_fixture_has_capacity/')
selector_has_capacity() {
    printf '%s\n' "$1" >> "$DSR_QUEUE_CASE/$DSR_QUEUE_PHASE.capacity-probes"
    _fixture_has_capacity "$@"
}
act_run_native_build() {
    _act_run_with_timeout 45 python3 "$DSR_QUEUE_PRODUCER" "$DSR_QUEUE_CASE" \
        "$2" "$8" "$DSR_QUEUE_PHASE" "$DSR_QUEUE_MODE" "$DSR_QUEUE_ROUTE"
}
args=(--run-id "$DSR_QUEUE_RUN")
[[ "$DSR_QUEUE_PHASE" != resume ]] || args=(--resume-run-id "$DSR_QUEUE_RUN")
act_orchestrate_build queuefixture 1.0.0 --parallel-jobs 2 --no-source-sync-gate \
    --output-dir "$DSR_QUEUE_CASE/output" "${args[@]}"
''')
holder = root / 'holder.sh'
holder.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$DSR_QUEUE_PROJECT/src/host_selector.sh" || exit
if [[ -n "${DSR_TEST_SELECTOR_LOOKUP_ADAPTER:-}" ]]; then
    source "$DSR_TEST_SELECTOR_LOOKUP_ADAPTER" || exit
fi
release() {
    selector_release_slot shared external-shared
    selector_release_slot independent external-independent
}
trap release EXIT
trap 'exit 130' INT TERM HUP
selector_acquire_slot shared external-shared || exit
selector_acquire_slot independent external-independent || exit
printf 'held\n' > "$DSR_QUEUE_CASE/holders.ready"
deadline=$((SECONDS + 60))
while [[ ! -f "$DSR_QUEUE_CASE/release-holders" ]]; do
    (( SECONDS < deadline )) || exit 4
    sleep 0.02
done
''')


def invoke(case, env, targets, mode, phase):
    env = dict(env, DSR_QUEUE_PHASE=phase)
    workspace = case / 'state/builds/queuefixture/1.0.0' / env['DSR_QUEUE_RUN']
    prior_leases = {path: path.read_bytes() for path in (case / 'state/selector/locks').rglob('*.lock')}
    with open(case / (phase + '.stdout'), 'wb') as out, open(case / (phase + '.stderr'), 'wb') as err:
        process = subprocess.Popen(['bash', str(driver)], env=env, stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=err, start_new_session=True)
        try:
            if phase == 'first' and mode != 'busy':
                started = lambda target: any(row['target'] == target and row['state'] == 'start'
                                             for row in events(case))
                check(case.name + ': first conflicting target reaches its barrier', until(process, lambda: started(targets[0])))
                check(case.name + ': later independent host starts before the blocked output is released',
                      until(process, lambda: started(targets[-1])))
                checkpoint = read(workspace / 'state.json')
                (case / 'queued.state.json').write_text(json.dumps(checkpoint) + '\n')
                pending = checkpoint['target_statuses'][targets[1]]
                check(case.name + ': deferred target stays pending with zero attempts',
                      pending['status'] == 'pending' and pending['attempts'] == 0 and not pending.get('result'))
                check(case.name + ': deferral creates no immutable log, result or capacity lease',
                      not list(workspace.glob('logs/002-*.log')) and not list(workspace.glob('results/002-*.json')) and
                      not list((case / 'state/selector/locks').rglob('*-' + targets[1].replace('/', '-') + '-attempt-*.lock')))
                check(case.name + ': conflicting backend has not started or staged a different output',
                      not started(targets[1]) and all(row['stage'] == '0' for row in events(case)))
                if mode == 'cancel':
                    process.send_signal(signal.SIGTERM)
                else:
                    (case / 'release').write_text('release the first output\n')
            code = process.wait(timeout=35)
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
    result, state = read(case / (phase + '.stdout')), read(workspace / 'state.json')
    expected = 130 if phase == 'first' and mode == 'cancel' else 1 if phase == 'first' and mode == 'retry' \
        else 6 if phase == 'first' and mode == 'busy' else 0
    if code != expected:
        print((case / (phase + '.stderr')).read_text()[-8000:], file=sys.stderr, flush=True)
        print(json.dumps(result), file=sys.stderr, flush=True)
    check(case.name + '/' + phase + ': aggregate retains the actual outcome',
          code == expected and result['exit_code'] == code and result['run_id'] == env['DSR_QUEUE_RUN'])
    check(case.name + '/' + phase + ': results preserve configured task order',
          [row['task_key'] for row in result['targets']] == targets)
    check(case.name + '/' + phase + ': every worker slot is released and existing external leases are unchanged',
          {path: path.read_bytes() for path in (case / 'state/selector/locks').rglob('*.lock')} == prior_leases)
    return result, state, workspace


cases = [('windows', 'success'), ('external', 'retry'), ('external', 'cancel')]
capacity_cases = [('capacity', mode) for mode in ('success', 'retry', 'cancel', 'busy')]
if selection == '--host-capacity-only':
    cases = capacity_cases
elif selection != '--output-queue-only':
    cases += capacity_cases
for route, mode in cases:
    case = root / (route + '-' + mode)
    for directory in ('config/repos.d', 'source', 'output'):
        (case / directory).mkdir(parents=True)
    targets = ['windows/amd64', 'windows/arm64', 'linux/amd64'] if route == 'windows' else [
        'linux/amd64', 'linux/arm64', 'darwin/arm64']
    (case / 'targets.json').write_text(json.dumps(targets))
    hosts = {target: 'shared' if target != targets[-1] else 'independent' for target in targets}
    config = dict(tool_name='queuefixture', repo='fixture/queuefixture', language='go',
                  local_path=str(case / 'source'), binary_name='fixture', targets=targets,
                  build_cmd='go build -o fixture ./cmd/fixture', act_job_map={target: None for target in targets},
                  cross_compile={target: {'host': host} for target, host in hosts.items()})
    if route == 'external':
        config['env'] = {'GOBIN': str(case / 'shared-bin')}
    elif route == 'capacity':
        # Rust output paths are isolated by the runner. The only blocker in
        # this case is the actual host lease, not a shared-output fixture.
        config['language'] = 'rust'
        config['build_cmd'] = 'cargo build --release'
    (case / 'config/repos.d/queuefixture.yaml').write_text(json.dumps(config))
    (case / 'config/hosts.yaml').write_text(json.dumps(dict(platform_mapping=hosts, hosts={
        'shared': dict(platform=targets[0], connection='local', concurrency=1 if route == 'capacity' else 3),
        'independent': dict(platform=targets[-1], connection='local', concurrency=1 if mode == 'busy' else 3)})))
    env = {key: value for key, value in os.environ.items()
           if key not in ('BASH_ENV', 'ENV') and not key.startswith('BASH_FUNC_')}
    env.update(DSR_QUEUE_PROJECT=str(project), DSR_QUEUE_MODULE=str(module), DSR_QUEUE_PRODUCER=str(producer),
               DSR_QUEUE_CASE=str(case), DSR_QUEUE_RUN=str(uuid.uuid4()), DSR_QUEUE_MODE=mode, DSR_QUEUE_ROUTE=route,
               DSR_CONFIG_DIR=str(case / 'config'), DSR_HOSTS_FILE=str(case / 'config/hosts.yaml'),
               ACT_REPOS_DIR=str(case / 'config/repos.d'), DSR_STATE_DIR=str(case / 'state'),
               DSR_CACHE_DIR=str(case / 'cache'), ACT_LOGS_DIR=str(case / 'logs'),
               ACT_ARTIFACTS_DIR=str(case / 'artifacts'), DSR_BUILD_LOCK_HELD_BY_CALLER='0',
               DSR_DISABLE_HOST_SELECTOR='1', NO_COLOR='1')
    if mode == 'busy':
        env.update(DSR_SELECTOR_WAIT_TIMEOUT='1', DSR_RETRY_MAX='1')
        with open(case / 'holders.log', 'wb') as out:
            holding = subprocess.Popen(['bash', str(holder)], env=env, stdin=subprocess.DEVNULL,
                                       stdout=out, stderr=out, start_new_session=True)
            try:
                if not until(holding, lambda: (case / 'holders.ready').exists()):
                    raise AssertionError('external real host leases were not acquired')
                result, state, workspace = invoke(case, env, targets, mode, 'first')
            finally:
                (case / 'release-holders').write_text('release external leases\n')
                holding.wait(timeout=10)
        check(case.name + ': a full externally busy pass reaches bounded worker capacity refusals',
              not events(case) and all(row['stage'] == 'host_capacity' and row['exit_code'] == 2 and
                  not row['backend_started'] and 'no build slot' in row['error'] for row in result['targets']) and
              all(state['target_statuses'][target]['attempts'] == 1 and
                  state['target_statuses'][target]['host_capacity_failures'] == 1 for target in targets))
        check(case.name + ': external holders release only their own leases',
              holding.returncode == 0 and not list((case / 'state/selector/locks').rglob('*.lock')))
        env['DSR_SELECTOR_WAIT_TIMEOUT'] = '5'
        resumed, after, _ = invoke(case, env, targets, mode, 'resume')
        check(case.name + ': exact-run resume retains compiler allowance after capacity-only attempts',
              [row['attempt'] for row in resumed['targets']] == [2, 2, 2] and
              all(row['status'] == 'success' and not row.get('retry_limit_exceeded') for row in resumed['targets']) and
              all(after['target_statuses'][target]['host_capacity_failures'] == 1 for target in targets) and
              sorted(row['target'] for row in events(case, 'resume') if row['state'] == 'start') == sorted(targets))
        continue
    result, state, workspace = invoke(case, env, targets, mode, 'first')
    timeline = events(case)
    check(case.name + ': every backend starts under its real bound-host lease',
          bool(timeline) and all(row['lease'] and row['host'] == hosts[row['target']]
                                 for row in timeline if row['state'] == 'start'))
    starts = {row['target']: row['at'] for row in timeline if row['state'] == 'start'}
    ends = {row['target']: row['at'] for row in timeline if row['state'] == 'end'}
    if mode == 'cancel':
        check(case.name + ': cancellation retains only the two actually started attempts',
              set(starts) == {targets[0], targets[-1]} and
              [row['attempt'] for row in result['targets']] == [1, 0, 1] and
              result['targets'][1]['status'] == 'skipped' and not result['targets'][1]['execution_started'] and
              state['target_statuses'][targets[1]]['status'] == 'pending' and
              len(list(workspace.glob('results/*.json'))) == 2)
        check(case.name + ': every started descendant stops before the coordinator returns',
              bool(timeline) and all(stopped(row) for row in timeline if row['state'] == 'start'))
        continue
    check(case.name + ': independent work overlaps while conflicting outputs remain serialized',
          set(starts) == set(targets) and len(timeline) == 6 and starts[targets[1]] >= ends[targets[0]] and
          starts[targets[-1]] < ends[targets[0]])
    check(case.name + ': original ordinal is retained in every immutable receipt path', all(
        Path(row['result_path']).name.startswith('%03d-%s.attempt-1.' % (index + 1, target.replace('/', '-'))) and
        Path(row['log_path']).name.startswith('%03d-%s.attempt-1.' % (index + 1, target.replace('/', '-'))) and
        row['attempt'] == 1 and state['target_statuses'][target]['attempts'] == 1
        for index, (target, row) in enumerate(zip(targets, result['targets']))))
    retained = {path: hashlib.sha256(path.read_bytes()).hexdigest()
                for pattern in ('results/*.json', 'logs/*.log') for path in workspace.glob(pattern)}
    resumed, after, _ = invoke(case, env, targets, mode, 'resume')
    expected_attempts = [1, 2, 1] if mode == 'retry' else [1, 1, 1]
    check(case.name + ': resume keeps exact task ordinals and reruns only the failed compiler',
          [row['attempt'] for row in resumed['targets']] == expected_attempts and
          [after['target_statuses'][target]['attempts'] for target in targets] == expected_attempts and
          [row['target'] for row in events(case, 'resume') if row['state'] == 'start'] ==
          ([targets[1]] if mode == 'retry' else []) and
          all(row['status'] == 'success' for row in resumed['targets']) and
          after['status'] == 'targets-complete')
    check(case.name + ': successful outputs are reused and old immutable evidence is unchanged',
          all(row.get('resume_reused') for index, row in enumerate(resumed['targets'])
              if mode != 'retry' or index != 1) and
          all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in retained.items()))
    if route == 'capacity' and mode == 'success':
        check(case.name + ': completed resume performs no capacity hint or lease acquisition',
              not (case / 'resume.capacity-probes').exists() and not events(case, 'resume'))

(root / 'summary.json').write_text(json.dumps(dict(checks=checks, failures=failures)) + '\n')
print('Output queue: %d checks, %d failures' % (checks, failures), flush=True)
raise SystemExit(bool(failures))
PY
}

if [[ "${1:-}" == --output-queue-only || "${1:-}" == --host-capacity-only ]]; then
    test_parallel_output_queue "$1"
    exit $?
fi

# Exercise the real task stream, worker wrapper, timeout, immutable receipts,
# state transitions and resume admission. Normal cases replace only native
# compilation and capacity acquisition; both deliberately read stdin. Reading in the slot
# prelude catches a redirect placed too late, inside the native build alone.
test_worker_stdin_isolation() {
    local project_root required_tool
    [[ -c /dev/null ]] || { echo 'Worker stdin tests require a working /dev/null device' >&2; return 1; }
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    for required_tool in python3 jq yq; do
        command -v "$required_tool" >/dev/null || { echo "Missing test dependency: $required_tool" >&2; return 77; }
    done
    if ! command -v timeout >/dev/null && ! command -v gtimeout >/dev/null; then
        echo 'Missing test dependency: GNU timeout or gtimeout' >&2
        return 77
    fi
    python3 - "$project_root" "${DSR_TEST_ACT_RUNNER:-$project_root/src/act_runner.sh}" "${1:-all}" <<'PY'
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import uuid

project, module = map(Path, sys.argv[1:3])
root = Path(tempfile.mkdtemp(prefix='dsr-worker-stdin-'))
print('Retained worker stdin fixture: ' + str(root), flush=True)
targets = ['linux/amd64', 'linux/arm64', 'darwin/amd64',
           'darwin/arm64', 'windows/amd64', 'windows/arm64']
checks = 0


def check(label, valid):
    global checks
    if not valid:
        raise AssertionError(label)
    checks += 1
    print('PASS: ' + label, flush=True)


def read(path):
    return json.loads(path.read_text())


def events(case):
    path = case / 'invocations.jsonl'
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def wait_for(process, predicate, label):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if predicate():
            return
        if process is not None and process.poll() is not None:
            break
        time.sleep(0.02)
    process_status = '' if process is None else ' (process exit: %r)' % process.poll()
    raise AssertionError(label + process_status)


worker = root / 'native.py'
worker.write_text(r'''import json, os, stat, sys, time
from pathlib import Path
case, target, attempt, mode, host = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
slug = target.replace('/', '-') + '.attempt-' + str(attempt)
descriptor, null = os.fstat(0), os.stat(os.devnull)
is_null = stat.S_ISCHR(descriptor.st_mode) and descriptor.st_rdev == null.st_rdev
(case / (slug + '.child.stdin')).write_bytes(sys.stdin.buffer.read())
event = dict(target=target, attempt=attempt, mode=mode, pid=os.getpid(), stdin_is_null=is_null)
fd = os.open(case / 'invocations.jsonl', os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
os.write(fd, (json.dumps(event) + '\n').encode())
os.close(fd)
if mode == 'readiness':
    # The actual native runner converts this health refusal into its own
    # structured result. No compiler or successful artifact is simulated.
    raise SystemExit(1)
if mode in ('cancel', 'custody-cancel') or (mode == 'timeout' and target == 'linux/amd64'):
    while True:
        time.sleep(0.05)
if mode == 'failure' and target == 'linux/amd64':
    print(json.dumps(dict(platform=target, method='native', status='failed', exit_code=9,
                         error='deliberate stdin-consuming build failure')), flush=True)
    raise SystemExit(9)
if mode in ('child-malformed-zero', 'child-malformed-exit'):
    print('{unfinished-result}', flush=True)
    raise SystemExit(0)
artifact = case / 'output' / (slug + '.bin')
artifact.write_bytes(('artifact for ' + target + '\n').encode())
status = 'ok' if mode == 'child-ok-exit' else 'passed' if mode == 'child-passed-exit' else 'success'
print(json.dumps(dict(platform=target, method='native', host=host, status=status, exit_code=0,
                     artifact_path=str(artifact), artifact_paths=[str(artifact)])), flush=True)
''')

driver = root / 'driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$DSR_STDIN_PROJECT/src/logging.sh"
source "$DSR_STDIN_PROJECT/src/config.sh"
source "${DSR_TEST_BUILD_STATE:-$DSR_STDIN_PROJECT/src/build_state.sh}"
source "$DSR_STDIN_MODULE"
if [[ "$DSR_STDIN_MODE" == source-sync-recovery || "$DSR_STDIN_MODE" == readiness-recovery ]]; then
    # Keep the real state updater. Pause its caller at two precise durable
    # boundaries so SIGKILL leaves an authentic coordinator-loss checkpoint.
    source <(declare -f build_state_update_target |
        sed '1s/build_state_update_target/_fixture_build_state_update_target/')
    _fixture_pause_state_update() {
        local ready_path="$DSR_STDIN_CASE/$DSR_STDIN_PHASE.state-update.ready"
        printf '%s\n' "$BASHPID" > "$ready_path.tmp" &&
            mv "$ready_path.tmp" "$ready_path" || return 1
        local deadline=$((SECONDS + 30))
        while [[ ! -f "$DSR_STDIN_CASE/$DSR_STDIN_PHASE.release-update" ]]; do
            ((SECONDS < deadline)) || return 1
            sleep 0.02
        done
    }
    build_state_update_target() {
        local admission_failure=false refusal_stage=source_sync
        [[ "$DSR_STDIN_MODE" != readiness-recovery ]] || refusal_stage=host_readiness
        if [[ "$4" == failed ]] && jq -e --arg stage "$refusal_stage" \
            '.result.stage == $stage' <<< "$5" >/dev/null; then
            admission_failure=true
        fi
        if $admission_failure && [[ "$DSR_STDIN_PHASE" == first ]]; then
            _fixture_pause_state_update || return 1
        fi
        _fixture_build_state_update_target "$@" || return $?
        if $admission_failure && [[ "$DSR_STDIN_PHASE" == resume-reconcile* ]] &&
           jq -e '.reconciled_from_sidecar == true' <<< "$5" >/dev/null; then
            _fixture_pause_state_update || return 1
        fi
    }
fi
selector_acquire_slot() {
    cat > "$DSR_STDIN_CASE/prelude.$2.stdin"
    printf '%s\n' "$BASHPID" > "$DSR_STDIN_CASE/prelude.$2.ready"
    while [[ ! -f "$DSR_STDIN_CASE/release" ]]; do sleep 0.02; done
}
selector_release_slot() {
    printf '%s\n' "$2" >> "$DSR_STDIN_CASE/released-slots"
    if [[ "$DSR_STDIN_MODE" == child-durable-success-killed &&
          "$DSR_STDIN_PHASE" == first && "$2" == *-linux-amd64-attempt-1 ]]; then
        # A durable receipt already exists at this boundary. The coordinator
        # must preserve completed success even if its outer worker now dies.
        kill -KILL "$BASHPID"
    fi
    if [[ ( "$DSR_STDIN_MODE" == sidecar-* || "$DSR_STDIN_MODE" == custody-cancel ) &&
          "$DSR_STDIN_PHASE" == first ]]; then
        # The real worker has saved its terminal receipt, but the coordinator
        # cannot reap it or save the embedded result until this barrier ends.
        local ready_path="$DSR_STDIN_CASE/sidecar.$2.ready"
        printf '%s\n' "$BASHPID" > "$ready_path.tmp" &&
            mv "$ready_path.tmp" "$ready_path" || return 1
        local deadline=$((SECONDS + 30))
        while [[ ! -f "$DSR_STDIN_CASE/release-workers" ]]; do
            ((SECONDS < deadline)) || return 1
            sleep 0.02
        done
    fi
}
act_run_native_build() {
    if [[ ( "$DSR_STDIN_MODE" == readiness && "$2" == darwin/* ) ||
          ( "$DSR_STDIN_MODE" == readiness-recovery && "$2" == linux/amd64 ) ||
          "$DSR_STDIN_MODE" == cli-readiness ]]; then
        (
            # Re-enter the production native runner in this child only. Its
            # real admission gate must retain target identity on refusal;
            # replacing the runner with prebuilt JSON would hide that bug.
            source "$DSR_STDIN_MODULE"
            host_health_is_ready() {
                _act_run_with_timeout 10 python3 "$DSR_STDIN_WORKER" \
                    "$DSR_STDIN_CASE" "$platform" "$attempt" readiness "$host"
            }
            act_run_native_build "$@"
        )
        return $?
    fi
    local deadline=10 native_mode="$DSR_STDIN_MODE"
    [[ "$native_mode" != readiness ]] || native_mode=success
    [[ "$native_mode" != sidecar-failure-recovery ]] || native_mode=failure
    [[ "$DSR_STDIN_MODE" != cancel && "$DSR_STDIN_MODE" != custody-cancel ]] || deadline=60
    if [[ "$DSR_STDIN_MODE" == timeout && "$2" == linux/amd64 ]]; then deadline=1; fi
    _act_run_with_timeout "$deadline" python3 "$DSR_STDIN_WORKER" \
        "$DSR_STDIN_CASE" "$2" "$attempt" "$native_mode" "$8"
}
# Explicit fault injection at the worker boundary tests the real parent's
# recovery of a missing receipt, including an actual uncatchable child death.
case "$DSR_STDIN_MODE" in
    missing-receipt) _act_run_target_worker() { return 0; } ;;
    killed-worker) _act_run_target_worker() { kill -KILL "$BASHPID"; } ;;
    coordinator-exit|coordinator-stream|coordinator-identity)
        # The real coordinator must reject a damaged terminal receipt even
        # when the outer worker exits zero. Preserve its original bytes.
        _act_run_target_worker() {
            local slug artifact result receipts
            slug=$(printf '%s' "$4" | tr / -) || return 4
            artifact="$DSR_STDIN_CASE/output/coordinator-$slug.bin"
            printf 'retained artifact for %s\n' "$4" > "$artifact" || return 4
            printf 'Injected incoherent worker receipt\n' >> "$6" || return 4
            result=$(jq -nc --arg target "$4" --arg artifact "$artifact" --arg host "${13}" \
                '{platform:$target,task_key:$target,method:"native",host:$host,status:"success",exit_code:0,
                  build_purpose:"release",publishable:true,artifact_path:$artifact}') || return 4
            receipts=$(_act_result_artifact_receipts "$result") || return 4
            result=$(jq -c --argjson receipts "$receipts" \
                '. + {resume_artifacts:$receipts}' <<< "$result") || return 4
            if [[ "$DSR_STDIN_MODE" == coordinator-exit ]]; then
                result=$(jq -c '.exit_code=17' <<< "$result") || return 4
            elif [[ "$DSR_STDIN_MODE" == coordinator-identity ]]; then
                # Each row corrupts a different identity field while retaining
                # its real frozen artifact and matching scheduled task key.
                case "$4" in
                    linux/amd64) result=$(jq -c '.platform="darwin/arm64"' <<< "$result") ;;
                    linux/arm64) result=$(jq -c 'del(.platform)' <<< "$result") ;;
                    darwin/amd64) result=$(jq -c '.method="act"' <<< "$result") ;;
                    darwin/arm64) result=$(jq -c 'del(.method)' <<< "$result") ;;
                    windows/amd64) result=$(jq -c '.host="different-builder"' <<< "$result") ;;
                    windows/arm64) result=$(jq -c 'del(.host)' <<< "$result") ;;
                esac
            fi
            printf '%s\n' "$result" > "$7" || return 4
            if [[ "$DSR_STDIN_MODE" == coordinator-stream ]]; then
                printf '%s\n' "$result" >> "$7" || return 4
            fi
            cp -- "$7" "$DSR_STDIN_CASE/coordinator-$slug.retained" || return 4
        }
        ;;
    child-*)
        # The real outer worker must observe this command's actual status.
        # A native backend can already have printed successful JSON when its
        # orchestration child dies before normalization or strict staging.
        # Do not replace the outer worker, wait, sidecar writer or scheduler.
        _act_build_orchestration_target() {
            local mode=success
            [[ "$4" != linux/amd64 ]] || mode="$DSR_STDIN_MODE"
            python3 "$DSR_STDIN_WORKER" "$DSR_STDIN_CASE" "$4" "$attempt" "$mode" "${10}" || return $?
            case "$mode" in
                child-success-killed) kill -KILL "$BASHPID" ;;
                child-*-exit) return 9 ;;
            esac
            return 0
        }
        ;;
esac
args=(--run-id "$DSR_STDIN_RUN")
if [[ "$DSR_STDIN_PHASE" == resume* ]]; then args=(--resume-run-id "$DSR_STDIN_RUN"); fi
if [[ "$DSR_STDIN_PHASE" == cli ]]; then
    for module in git_ops artifact_naming packaging; do
        source "$DSR_STDIN_PROJECT/src/$module.sh" || exit 1
    done
    export SCRIPT_DIR="$DSR_STDIN_PROJECT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture
    declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
    # Load the real public command and envelope as the native release fixtures
    # do; do not duplicate or substitute its per-target JSON projection.
    source <(awk '/^(_dsr_require|cmd_build)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' \
        "$DSR_STDIN_PROJECT/dsr") || exit 1
    source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' \
        "$DSR_STDIN_PROJECT/dsr") || exit 1
    cmd_build stdinfixture --version 1.0.0 --no-sync --jobs "$DSR_STDIN_JOBS" \
        --output-dir "$DSR_STDIN_CASE/output"
else
    source_args=(--no-source-sync-gate)
    if [[ -f "$DSR_STDIN_CASE/source-sync.json" ]]; then
        source_args=(--source-sync-json "$(cat "$DSR_STDIN_CASE/source-sync.json")")
    fi
    act_orchestrate_build stdinfixture 1.0.0 --parallel-jobs "$DSR_STDIN_JOBS" \
        "${source_args[@]}" --output-dir "$DSR_STDIN_CASE/output" "${args[@]}"
fi
''')


def fixture(jobs, mode):
    case = root / ('jobs-%d-%s' % (jobs, mode))
    for directory in ('config/repos.d', 'state', 'cache', 'source', 'output'):
        (case / directory).mkdir(parents=True, exist_ok=True)
    hosts = {target: 'host-' + target.replace('/', '-') for target in targets}
    (case / 'config/hosts.yaml').write_text(json.dumps({
        'schema_version': '1.0.0', 'platform_mapping': hosts,
        'hosts': {host: {'platform': target, 'connection': 'local'}
                  for target, host in hosts.items()}}))
    (case / 'config/repos.d/stdinfixture.yaml').write_text(json.dumps({
        'tool_name': 'stdinfixture', 'repo': 'fixture/stdinfixture', 'language': 'go',
        'local_path': str(case / 'source'), 'binary_name': 'fixture',
        'targets': targets, 'cross_compile': {target: {'host': host}
                                             for target, host in hosts.items()}}))
    return case, str(uuid.uuid4())


def invocation_env(case, identity, jobs, mode, phase, retry_max=3):
    env = dict(os.environ, DSR_STATE_DIR=str(case / 'state'), DSR_CACHE_DIR=str(case / 'cache'),
               DSR_CONFIG_DIR=str(case / 'config'), ACT_REPOS_DIR=str(case / 'config/repos.d'),
               ACT_LOGS_DIR=str(case / 'logs'), ACT_ARTIFACTS_DIR=str(case / 'artifacts'),
               DSR_STDIN_PROJECT=str(project), DSR_STDIN_MODULE=str(module),
               DSR_STDIN_WORKER=str(worker), DSR_STDIN_CASE=str(case), DSR_STDIN_RUN=identity,
               DSR_STDIN_JOBS=str(jobs), DSR_STDIN_MODE=mode, DSR_STDIN_PHASE=phase,
               DSR_DISABLE_HOST_SELECTOR='1', DSR_RETRY_MAX=str(retry_max), NO_COLOR='1')
    env.pop('DSR_BUILD_LOCK_HELD_BY_CALLER', None)
    return env


def invoke(case, identity, jobs, mode, phase, retry_max=3, expected_code=None):
    env = invocation_env(case, identity, jobs, mode, phase, retry_max)
    out = open(case / (phase + '.stdout'), 'wb')
    err = open(case / (phase + '.stderr'), 'wb')
    process = subprocess.Popen(['bash', str(driver)], env=env, stdin=subprocess.DEVNULL,
                               stdout=out, stderr=err, start_new_session=True)
    try:
        if phase == 'first' and mode not in ('missing-receipt', 'killed-worker',
                                            'coordinator-exit', 'coordinator-stream', 'coordinator-identity'):
            # Each admitted worker blocks in its capacity prelude. The next
            # batch cannot start until we release this exact initial wave.
            wait_for(process, lambda: len(list(case.glob('prelude.*.ready'))) == jobs,
                     str(case) + ': initial worker wave did not reach its barrier')
            (case / 'release').write_text('continue\n')
            if mode == 'cancel':
                wait_for(process, lambda: len(events(case)) == jobs,
                         str(case) + ': cancellable descendants did not start')
                process.send_signal(signal.SIGTERM)
        code = process.wait(timeout=45)
    except BaseException:
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        raise
    finally:
        out.close()
        err.close()
    value = read(case / (phase + '.stdout'))
    if phase == 'cli':
        check(case.name + ': real build command preserves failure in one JSON envelope',
              code == 6 and value['command'] == 'build' and value['exit_code'] == code and
              value['status'] == 'error')
        details = value['details']
        state = read(case / 'state/builds/stdinfixture/1.0.0' / details['run_id'] / 'state.json')
        return details, state
    state_path = case / 'state/builds/stdinfixture/1.0.0' / identity / 'state.json'
    state = read(state_path)
    (case / (phase + '.state.json')).write_text(json.dumps(state) + '\n')
    if expected_code is None:
        expected_code = (0 if mode in ('child-success', 'child-durable-success-killed') else 1) \
            if mode.startswith('child-') else {
            'success': 0, 'failure': 1, 'timeout': 1, 'readiness': 1, 'cancel': 130,
            'missing-receipt': 6, 'killed-worker': 6,
            'coordinator-exit': 6, 'coordinator-stream': 6, 'coordinator-identity': 6}[mode]
    check(case.name + '/' + phase + ': aggregate preserves the real exit status', code == expected_code)
    check(case.name + '/' + phase + ': exactly six ordered target rows',
          value['run_id'] == identity and value['summary']['total'] == 6 and
          [row['platform'] for row in value['targets']] == targets)
    return value, state


def verify_attempts(case, value, state, expected_counts, expected_codes, label, dispatch_counts=None):
    seen = events(case)
    successes = sum(target in expected_counts and target not in expected_codes for target in targets)
    check(label + ': aggregate counts match completed and unsuccessful targets',
          value['summary'] == {'total': 6, 'success': successes, 'failed': 6 - successes} and
          value['status'] == ('success' if successes == 6 else 'partial' if successes else 'failed'))
    check(label + ': actual invocations match each configured target exactly',
          Counter(event['target'] for event in seen) == Counter(expected_counts))
    check(label + ': worker prelude and descendant receive isolated stdin',
          all(event['stdin_is_null'] for event in seen) and
          len(list(case.glob('prelude.*.stdin'))) == len(seen) and
          all(path.stat().st_size == 0 for path in case.glob('*.stdin')))
    check(label + ': every acquired slot is released',
          len((case / 'released-slots').read_text().splitlines()) == len(seen))
    for row in value['targets']:
        target = row['platform']
        saved = state['target_statuses'][target]
        expected = (dispatch_counts if dispatch_counts is not None else expected_counts).get(target, 0)
        check(label + ': ' + target + ' attempt count matches execution',
              saved['attempts'] == expected and row['attempt'] == expected)
        if not expected:
            check(label + ': ' + target + ' remains pending without fabricated receipts',
                  row['status'] == 'skipped' and row['exit_code'] == 130 and
                  saved['status'] == 'pending' and not saved.get('result') and
                  not any(row.get(key) for key in ('log_path', 'result_path', 'resume_artifacts')))
            continue
        code = expected_codes.get(target, 0)
        receipt = Path(row['result_path'])
        check(label + ': ' + target + ' has real immutable execution receipts',
              Path(row['log_path']).is_file() and receipt.is_file() and
              read(receipt)['exit_code'] == code and row['exit_code'] == code and
              saved['result']['exit_code'] == code and
              saved['status'] == ('completed' if code == 0 else 'failed'))
        if code == 0:
            frozen = row['resume_artifacts']
            check(label + ': ' + target + ' artifact bytes match the frozen receipt',
                  row['status'] == 'success' and len(frozen) == 1 and
                  frozen[0]['sha256'] == hashlib.sha256(Path(frozen[0]['path']).read_bytes()).hexdigest() and
                  frozen[0]['size_bytes'] == Path(frozen[0]['path']).stat().st_size)
        elif code == 4:
            check(label + ': ' + target + ' retains the actual host-readiness refusal',
                  row['status'] == 'error' and row['method'] == 'native' and
                  row['stage'] == 'host_readiness' and
                  saved['host_readiness_failures'] == expected and
                  row['host'] == 'host-' + target.replace('/', '-') and
                  row['error'] == 'Native build host is not ready' and
                  not row.get('resume_artifacts') and
                  read(receipt)['platform'] == target and
                  read(receipt)['task_key'] == target and
                  read(receipt)['stage'] == 'host_readiness' and
                  not list((case / 'output').glob(target.replace('/', '-') + '.attempt-*.bin')))
        else:
            check(label + ': ' + target + ' failure cannot supply successful artifacts',
                  row['status'] == 'failed' and not row.get('resume_artifacts'))
    completed = not expected_codes and all(expected_counts.get(target, 0) for target in targets)
    check(label + ': target completion does not claim finalized publication',
          (state['status'] == 'targets-complete') == completed and
          state['status'] != 'completed' and not (case / 'output/.dsr-build-purpose.json').exists())


def invocation_identity_cases():
    for jobs in (1, 3):
        case, identity = fixture(jobs, 'invocation-valid')
        first, state = invoke(case, identity, jobs, 'success', 'first')
        verify_attempts(case, first, state, {target: 1 for target in targets}, {}, case.name + '/first')
        resumed, state = invoke(case, identity, jobs, 'success', 'resume')
        check(case.name + ': matching singleton outputs are reused without another backend',
              len(events(case)) == 6 and all(row.get('resume_reused') for row in resumed['targets']) and
              all(row['host'] == 'host-' + row['platform'].replace('/', '-') and
                  row['method'] == 'native' for row in resumed['targets']))
        state_path = case / 'state/builds/stdinfixture/1.0.0' / identity / 'state.json'
        sidecar = Path(state['target_statuses'][targets[0]]['result_path'])
        original_state, original_sidecar = state_path.read_bytes(), sidecar.read_bytes()
        original_events = events(case)
        artifacts = {path: path.read_bytes() for path in (case / 'output').glob('*.bin')}
        for boundary in ('embedded', 'sidecar'):
            for field in ('platform', 'method', 'host'):
                for missing in (False, True):
                    # Each corruption is a fresh test of the same completed
                    # invocation. Restore only these fixture-owned bytes;
                    # production recovery must never perform this rewrite.
                    state_path.write_bytes(original_state)
                    sidecar.write_bytes(original_sidecar)
                    candidate = json.loads(original_state if boundary == 'embedded' else original_sidecar)
                    row = candidate['target_statuses'][targets[0]]['result'] if boundary == 'embedded' else candidate
                    if missing:
                        row.pop(field)
                    else:
                        row[field] = {'platform': 'darwin/arm64', 'method': 'act',
                                      'host': 'different-builder'}[field]
                    changed = state_path if boundary == 'embedded' else sidecar
                    changed.write_text(json.dumps(candidate) + '\n')
                    before_state, before_sidecar = state_path.read_bytes(), sidecar.read_bytes()
                    label = 'resume-%s-%s-%s' % (boundary, 'missing' if missing else 'wrong', field)
                    refused = subprocess.run(['bash', str(driver)], stdin=subprocess.DEVNULL,
                                             env=invocation_env(case, identity, jobs, 'success', label),
                                             capture_output=True, timeout=45)
                    (case / (label + '.stdout')).write_bytes(refused.stdout)
                    (case / (label + '.stderr')).write_bytes(refused.stderr)
                    check(case.name + '/' + label + ': refuse before any new backend or checkpoint change',
                          refused.returncode == 4 and b'does not belong to its scheduled invocation' in refused.stderr and
                          events(case) == original_events and state_path.read_bytes() == before_state and
                          sidecar.read_bytes() == before_sidecar and
                          all(path.read_bytes() == data for path, data in artifacts.items()))
        state_path.write_bytes(original_state)
        sidecar.write_bytes(original_sidecar)

        case, identity = fixture(jobs, 'coordinator-identity')
        first, state = invoke(case, identity, jobs, 'coordinator-identity', 'first')
        check(case.name + ': foreign singleton receipts never become completed targets',
              not events(case) and first['summary'] == {'total': 6, 'success': 0, 'failed': 6} and
              state['status'] == 'failed' and not (case / 'output/.dsr-build-purpose.json').exists())
        for row in first['targets']:
            target = row['platform']
            saved = state['target_statuses'][target]
            retained = case / ('coordinator-' + target.replace('/', '-') + '.retained')
            check(case.name + ': reject ' + target + ' while preserving the original sidecar and artifact',
                  row['status'] == 'failed' and row['exit_code'] == 4 and not row.get('resume_artifacts') and
                  saved['status'] == 'failed' and saved['result'] == row and
                  Path(row['result_path']).read_bytes() == retained.read_bytes() and
                  read(retained)['status'] == 'success' and bool(read(retained)['resume_artifacts']) and
                  Path(row['artifact_path']).read_bytes() == ('retained artifact for ' + target + '\n').encode())


if sys.argv[3] in ('all', '--invocation-identity-only'):
    invocation_identity_cases()
if sys.argv[3] == '--invocation-identity-only':
    print('Invocation identity: %d checks passed' % checks, flush=True)
    raise SystemExit(0)


def coordinator_custody_cases():
    def signal_defaults():
        # Noninteractive Bash cannot trap a signal inherited as ignored.
        signal.signal(signal.SIGHUP, signal.SIG_DFL)

    def running(pid):
        probe = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True)
        return probe.returncode == 0 and bool(probe.stdout.strip()) and not probe.stdout.strip().startswith(b'Z')

    def signal_worker(pid, session):
        try:
            if os.getsid(pid) == session:
                os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    def lock_info(case):
        env = dict(os.environ, DSR_STATE_DIR=str(case / 'state'))
        probe = subprocess.run(['bash', '-c', 'source "${DSR_TEST_BUILD_STATE:-$1/src/build_state.sh}"; '
                                'build_state_init && build_lock_info stdinfixture 1.0.0',
                                'fixture', str(project)], env=env, capture_output=True, timeout=5)
        check(case.name + ': custody inspection succeeds', probe.returncode == 0)
        return json.loads(probe.stdout)

    for jobs in (1, 3):
        for crash_signal in (signal.SIGKILL, signal.SIGHUP):
            case, identity = fixture(jobs, 'custody-' + crash_signal.name)
            workspace = case / 'state/builds/stdinfixture/1.0.0' / identity
            env = invocation_env(case, identity, jobs, 'custody-cancel', 'first')
            with open(case / 'first.stdout', 'wb') as out, open(case / 'first.stderr', 'wb') as err:
                process = subprocess.Popen(['bash', str(driver)], env=env, stdin=subprocess.DEVNULL,
                                           stdout=out, stderr=err, start_new_session=True,
                                           preexec_fn=signal_defaults)
                workers = []
                try:
                    wait_for(process, lambda: len(list(case.glob('prelude.*.ready'))) == jobs,
                             case.name + ': initial worker wave did not start')
                    workers = [int(path.read_text()) for path in case.glob('prelude.*.ready')]
                    (case / 'release').write_text('continue\n')
                    wait_for(process, lambda: len(events(case)) == jobs,
                             case.name + ': native descendants did not start')
                    original_events = events(case)
                    checkpoint = (workspace / 'state.json').read_bytes()
                    check(case.name + ': custody covers the real running coordinator and workers',
                          lock_info(case).get('locked') is True and
                          all(running(event['pid']) for event in original_events))
                    process.send_signal(crash_signal)
                    if crash_signal == signal.SIGKILL:
                        check(case.name + ': coordinator loss leaves genuine active backend work',
                              process.wait(timeout=5) == -signal.SIGKILL and
                              all(running(event['pid']) for event in original_events))

                    # The original worker's release barrier retains its lease
                    # even if HUP cleanup finishes before this retry gets CPU.
                    # Every retry must refuse before state or attempt changes.
                    for retry in (1, 2):
                        phase = 'resume-blocked-%d' % retry
                        blocked_env = invocation_env(case, identity, jobs, 'success', phase)
                        blocked = subprocess.run(['bash', str(driver)], env=blocked_env,
                                                 stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
                        (case / (phase + '.stdout')).write_bytes(blocked.stdout)
                        (case / (phase + '.stderr')).write_bytes(blocked.stderr)
                        check(case.name + '/' + phase + ': exact resume refuses inherited live custody',
                              blocked.returncode == 2 and json.loads(blocked.stdout)['status'] == 'error')
                        check(case.name + '/' + phase + ': refusal does not dispatch or spend an attempt',
                              events(case) == original_events and
                              (workspace / 'state.json').read_bytes() == checkpoint)
                    if crash_signal == signal.SIGKILL:
                        held = lock_info(case)
                        check(case.name + ': a dead coordinator PID cannot make inherited custody stale',
                              held['locked'] is True and held['custody'] == 'held' and
                              held['process_alive'] is False and held['stale'] is False)
                        for pid in workers:
                            signal_worker(pid, process.pid)
                    wait_for(None, lambda: len(list(case.glob('sidecar.*.ready'))) == jobs,
                             case.name + ': cancelled workers did not retain terminal receipts')
                    check(case.name + ': interrupted descendants stop before worker lease release',
                          all(not running(event['pid']) for event in original_events) and
                          all(running(pid) for pid in workers) and
                          all(read(path)['exit_code'] == 130 for path in (workspace / 'results').glob('*.json')))
                    immutable = {path: path.read_bytes() for directory in ('logs', 'results')
                                 for path in (workspace / directory).rglob('*') if path.is_file()}
                finally:
                    # Only fixture-owned workers are signalled. Retain files
                    # and unblock all barriers on both pass and failure.
                    (case / 'release-workers').write_text('continue\n')
                    for pid in workers:
                        signal_worker(pid, process.pid)
                    if process.poll() is None:
                        process.send_signal(signal.SIGTERM)
                        try:
                            process.wait(timeout=12)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait(timeout=5)
                    wait_for(None, lambda: all(not running(pid) for pid in workers),
                             case.name + ': owned workers did not drain')
                if crash_signal == signal.SIGHUP:
                    check(case.name + ': hangup returns managed cancellation and all configured rows',
                          process.returncode == 130 and read(case / 'first.stdout')['summary'] ==
                          {'total': 6, 'success': 0, 'failed': 6})
            free = lock_info(case)
            check(case.name + ': kernel custody is free only after the last inherited worker closes it',
                  free['locked'] is False and free['custody'] == 'free')
            resumed, state = invoke(case, identity, jobs, 'success', 'resume')
            counts = {target: 2 if target in targets[:jobs] else 1 for target in targets}
            verify_attempts(case, resumed, state, counts, {}, case.name + '/resume')
            check(case.name + ': exact recovery preserves original interruption evidence',
                  all(path.read_bytes() == data for path, data in immutable.items()))
            after = events(case)
            repeated, repeated_state = invoke(case, identity, jobs, 'success', 'resume-again')
            check(case.name + ': repeated exact resume reuses every success without executing again',
                  events(case) == after and all(row.get('resume_reused') for row in repeated['targets']) and
                  all(entry['attempts'] == counts[target]
                      for target, entry in repeated_state['target_statuses'].items()))


if sys.argv[3] in ('all', '--stdin-isolation-only', '--coordinator-custody-only'):
    coordinator_custody_cases()
if sys.argv[3] == '--coordinator-custody-only':
    print('Coordinator custody: %d checks passed' % checks, flush=True)
    raise SystemExit(0)


for jobs in (() if sys.argv[3] in ('--coordinator-receipt-only', '--sidecar-recovery-only',
                                  '--worker-completion-only', '--host-readiness-cli-only') else (1, 3)):
    for mode in (('readiness',) if sys.argv[3] == '--host-readiness-only' else
                 ('success', 'failure', 'timeout', 'readiness', 'cancel')):
        case, identity = fixture(jobs, mode)
        first, state = invoke(case, identity, jobs, mode, 'first')
        counts = {target: 1 for target in (targets[:jobs] if mode == 'cancel' else targets)}
        codes = ({target: 130 for target in targets[:jobs]} if mode == 'cancel' else
                 {target: 4 for target in targets if target.startswith('darwin/')} if mode == 'readiness' else
                 {'linux/amd64': {'failure': 9, 'timeout': 124}[mode]}
                 if mode in ('failure', 'timeout') else {})
        verify_attempts(case, first, state, counts, codes, case.name + '/first')
        if mode == 'readiness':
            check(case.name + ': only unready hosts are refused before compilation',
                  {event['target'] for event in events(case) if event['mode'] == 'readiness'} ==
                  {target for target in targets if target.startswith('darwin/')} and
                  len(list((case / 'output').glob('*.bin'))) == 4)
        if mode == 'cancel':
            for event in events(case):
                probe = subprocess.run(['ps', '-p', str(event['pid']), '-o', 'stat='], capture_output=True)
                check(case.name + ': cancelled descendant has stopped',
                      probe.returncode != 0 or probe.stdout.strip().startswith(b'Z'))
        # Preserve failed and successful evidence alike. A retry may create
        # new receipts, but cannot alter any prior attempt's logs or bytes.
        immutable = {path: path.read_bytes() for directory in ('output', 'logs', 'results')
                     for path in ((case / directory) if directory == 'output' else
                                  case / 'state/builds/stdinfixture/1.0.0' / identity / directory).rglob('*')
                     if path.is_file()}
        if mode == 'readiness':
            # The native gate refuses before any compiler starts. Repeated
            # exact-run retries must preserve evidence and allow recovery
            # even after more refusals than the compiler retry allowance.
            for refused_attempt in (2, 3, 4):
                refused, refused_state = invoke(case, identity, jobs, mode,
                                                 'resume-unready-%d' % refused_attempt)
                counts = {target: count + (1 if target in codes else 0)
                          for target, count in counts.items()}
                verify_attempts(case, refused, refused_state, counts, codes,
                                case.name + '/unready-%d' % refused_attempt)
                check(case.name + ': readiness retry %d retains prior immutable evidence' % refused_attempt,
                      all(path.read_bytes() == contents for path, contents in immutable.items()))
                immutable.update({path: path.read_bytes() for directory in ('output', 'logs', 'results')
                                  for path in ((case / directory) if directory == 'output' else
                                               case / 'state/builds/stdinfixture/1.0.0' / identity / directory).rglob('*')
                                  if path.is_file()})
        resumed, resumed_state = invoke(case, identity, jobs, 'success', 'resume')
        resumed_counts = {target: counts.get(target, 0) + (0 if target in counts and target not in codes else 1)
                          for target in targets}
        verify_attempts(case, resumed, resumed_state, resumed_counts, {}, case.name + '/resume')
        check(case.name + ': resume reuses only completed targets',
              all(bool(row.get('resume_reused')) == (row['platform'] in counts and row['platform'] not in codes)
                  for row in resumed['targets']))
        check(case.name + ': retries preserve all earlier attempt evidence',
              all(path.read_bytes() == contents for path, contents in immutable.items()))
        if mode == 'readiness':
            check(case.name + ': repaired hosts compile once after four retained readiness refusals',
                  all(resumed_state['target_statuses'][target]['attempts'] == 5 and
                      resumed_state['target_statuses'][target]['host_readiness_failures'] == 4
                      for target in codes) and
                  Counter(event['target'] for event in events(case) if event['mode'] == 'success') ==
                  Counter({target: 1 for target in targets}))

for jobs in (() if sys.argv[3] in ('--sidecar-recovery-only', '--worker-completion-only',
                                  '--host-readiness-only', '--host-readiness-cli-only') else (1, 3)):
    for mode, observed_exit in (('missing-receipt', 0), ('killed-worker', 137),
                                ('coordinator-exit', 0), ('coordinator-stream', 0)):
        case, identity = fixture(jobs, mode)
        first, state = invoke(case, identity, jobs, mode, 'first')
        check(case.name + ': lost worker receipts cannot report compilation or publication success',
              not events(case) and first['status'] == 'failed' and state['status'] == 'failed' and
              first['summary'] == {'total': 6, 'success': 0, 'failed': 6} and
              not (case / 'output/.dsr-build-purpose.json').exists())
        immutable = {}
        for row in first['targets']:
            saved = state['target_statuses'][row['platform']]
            result_path, log_path = Path(row['result_path']), Path(row['log_path'])
            if mode.startswith('coordinator-'):
                original = case / ('coordinator-' + row['platform'].replace('/', '-') + '.retained')
                check(case.name + ': ' + row['platform'] + ' refuses incoherent completion without rewriting it',
                      row['status'] == 'failed' and
                      row['exit_code'] == (4 if mode == 'coordinator-exit' else 6) and
                      row['attempt'] == 1 and saved['attempts'] == 1 and saved['status'] == 'failed' and
                      saved['result'] == row and not row.get('resume_artifacts') and
                      result_path.read_bytes() == original.read_bytes())
            else:
                receipt = read(result_path)
                check(case.name + ': ' + row['platform'] + ' retains the observed child exit separately',
                      row['status'] == 'failed' and row['exit_code'] == (observed_exit or 6) and
                      row['worker_exit_code'] == observed_exit and row['receipt_source'] == 'coordinator' and
                      row['attempt'] == 1 and saved['attempts'] == 1 and saved['status'] == 'failed' and
                      receipt == saved['result'] and receipt == row and not receipt.get('resume_artifacts'))
            immutable[result_path] = result_path.read_bytes()
            immutable[log_path] = log_path.read_bytes()
        (case / 'release').write_text('continue\n')
        if mode == 'coordinator-stream':
            # A malformed multi-document sidecar remains an explicit recovery
            # refusal; it must never become a reusable success on the next run.
            env = invocation_env(case, identity, jobs, 'success', 'resume')
            refused = subprocess.run(['bash', str(driver)], env=env, stdin=subprocess.DEVNULL,
                                     capture_output=True, timeout=45)
            (case / 'resume-refused.stdout').write_bytes(refused.stdout)
            (case / 'resume-refused.stderr').write_bytes(refused.stderr)
            check(case.name + ': malformed retained receipts cannot authorize any resumed compiler',
                  refused.returncode != 0 and not events(case) and
                  all(path.read_bytes() == contents for path, contents in immutable.items()))
            continue
        resumed, resumed_state = invoke(case, identity, jobs, 'success', 'resume')
        verify_attempts(case, resumed, resumed_state, {target: 1 for target in targets}, {},
                        case.name + '/resume', {target: 2 for target in targets})
        check(case.name + ': exact resume runs each compiler once and preserves failed receipts',
              all(not row.get('resume_reused') for row in resumed['targets']) and
              all(path.read_bytes() == contents for path, contents in immutable.items()))

for jobs in ((1, 3) if sys.argv[3] in ('all', '--stdin-isolation-only', '--worker-completion-only') else ()):
    for mode, observed_exit in (('child-success-killed', 137), ('child-success-exit', 9),
                                ('child-ok-exit', 9), ('child-passed-exit', 9),
                                ('child-malformed-zero', 0), ('child-malformed-exit', 9),
                                ('child-success', 0), ('child-durable-success-killed', 0)):
        case, identity = fixture(jobs, mode)
        first, state = invoke(case, identity, jobs, mode, 'first')
        codes = {} if mode in ('child-success', 'child-durable-success-killed') else {
            'linux/amd64': observed_exit or 6}
        verify_attempts(case, first, state, {target: 1 for target in targets}, codes,
                        case.name + '/first')
        failed = first['targets'][0]
        log = Path(failed['log_path']).read_text()
        if mode not in ('child-malformed-zero', 'child-malformed-exit'):
            raw = [json.loads(line) for line in log.splitlines() if line.startswith('{')][-1]
            check(case.name + ': child emitted real artifact success before its observed exit',
                  raw['status'] in ('success', 'ok', 'passed') and raw['exit_code'] == 0 and
                  Path(raw['artifact_path']).is_file())
        if observed_exit:
            check(case.name + ': unsuccessful child cannot persist a reusable success receipt',
                  read(Path(failed['result_path']))['status'] == 'failed' and
                  state['target_statuses']['linux/amd64']['status'] == 'failed' and
                  not failed.get('resume_artifacts'))
        workspace = case / 'state/builds/stdinfixture/1.0.0' / identity
        immutable = {path: path.read_bytes() for directory in ('output', 'logs', 'results')
                     for path in ((case / directory) if directory == 'output' else
                                  workspace / directory).rglob('*') if path.is_file()}
        resumed, resumed_state = invoke(case, identity, jobs, 'success', 'resume')
        counts = {target: 1 + (1 if target in codes else 0) for target in targets}
        verify_attempts(case, resumed, resumed_state, counts, {}, case.name + '/resume')
        check(case.name + ': actual compiler attempts advance exactly once on retry',
              all(sorted(event['attempt'] for event in events(case) if event['target'] == target) ==
                  list(range(1, counts[target] + 1)) for target in targets))
        check(case.name + ': exact resume retries only the unfinished command and preserves all prior evidence',
              all(bool(row.get('resume_reused')) == (row['platform'] not in codes)
                  for row in resumed['targets']) and
              all(path.read_bytes() == contents for path, contents in immutable.items()))


def worker_running(pid):
    probe = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True)
    return probe.returncode == 0 and bool(probe.stdout.strip()) and not probe.stdout.strip().startswith(b'Z')


sidecar_cases = [] if sys.argv[3] in (
    '--coordinator-receipt-only', '--worker-completion-only',
    '--host-readiness-only', '--host-readiness-cli-only') else [
        (jobs, mode) for jobs in (1, 3) for mode in
        ('sidecar-failure-recovery', 'sidecar-missing-recovery', 'sidecar-recovery')]
for jobs, crash_mode in sidecar_cases:
    case, identity = fixture(jobs, crash_mode)
    workspace = case / 'state/builds/stdinfixture/1.0.0' / identity
    env = invocation_env(case, identity, jobs, crash_mode, 'first',
                         retry_max=3 if crash_mode == 'sidecar-recovery' else 1)
    with open(case / 'first.stdout', 'wb') as out, open(case / 'first.stderr', 'wb') as err:
        process = subprocess.Popen(['bash', str(driver)], env=env, stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=err, start_new_session=True)
        workers = []
        try:
            wait_for(process, lambda: len(list(case.glob('prelude.*.ready'))) == jobs,
                     case.name + ': initial workers did not reach capacity barrier')
            (case / 'release').write_text('continue\n')
            wait_for(process, lambda: len(list(case.glob('sidecar.*.ready'))) == jobs,
                     case.name + ': worker sidecars did not reach the publication barrier')
            workers = [int(path.read_text()) for path in case.glob('sidecar.*.ready')]
            check(case.name + ': real workers are alive after writing their sidecars',
                  len(set(workers)) == jobs and all(worker_running(pid) for pid in workers))
            process.kill()
            check(case.name + ': coordinator really dies before collecting worker results',
                  process.wait(timeout=5) == -signal.SIGKILL)
            before = read(workspace / 'state.json')
            (case / 'first.state.json').write_text(json.dumps(before) + '\n')
            check(case.name + ': checkpoint retains admitted attempts without embedded completion',
                  before['status'] == 'running' and
                  all(before['target_statuses'][target]['status'] == 'running' and
                      before['target_statuses'][target]['attempts'] == 1 and
                      before['target_statuses'][target].get('result') is None
                      for target in targets[:jobs]))
            check(case.name + ': undispatched targets remain pending with zero attempts',
                  all(before['target_statuses'][target]['status'] == 'pending' and
                      before['target_statuses'][target]['attempts'] == 0
                      for target in targets[jobs:]))
            check(case.name + ': exactly the admitted targets executed before the crash',
                  Counter(event['target'] for event in events(case)) == Counter(targets[:jobs]))
        finally:
            # Release only this fixture's blocked workers, including on an
            # assertion failure. At the sidecar barrier their native
            # descendants have already exited; an earlier failure still lets
            # the live coordinator cancel those descendants normally.
            (case / 'release-workers').write_text('continue\n')
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            wait_for(None, lambda: all(not worker_running(pid) for pid in workers),
                     case.name + ': released workers did not exit')

    unavailable_receipt = None
    if crash_mode == 'sidecar-missing-recovery':
        # Retain the actual bytes outside their expected path to model a lost
        # receipt after a real coordinator crash; never synthesize worker JSON.
        prior_path = Path(before['target_statuses'][targets[0]]['result_path'])
        unavailable_receipt = case / 'unavailable-sidecar.json'
        prior_path.rename(unavailable_receipt)
        unavailable_bytes = unavailable_receipt.read_bytes()
    immutable = {path: path.read_bytes() for directory in ('output', 'logs', 'results')
                 for path in ((case / directory) if directory == 'output' else workspace / directory).rglob('*')
                 if path.is_file()}
    if crash_mode != 'sidecar-recovery':
        known_failure = crash_mode == 'sidecar-failure-recovery'
        for phase, limit in (('resume', 1), ('resume-again', '01')):
            resumed, state = invoke(case, identity, jobs, 'success', phase,
                                    retry_max=limit, expected_code=1)
            failed = resumed['targets'][0]
            saved = state['target_statuses'][targets[0]]
            prior = before['target_statuses'][targets[0]]
            check(case.name + '/' + phase + ': exhausted target preserves dispatch identity and failed state',
                  failed['status'] == 'failed' and failed['attempt'] == 1 and
                  failed['log_path'] == prior['log_path'] and
                  (failed.get('result_path') == prior['result_path'] if known_failure else 'result_path' not in failed) and
                  failed.get('retry_limit_exceeded') is True and not failed.get('resume_reused') and
                  saved['status'] == 'failed' and saved['result'] == failed and
                  state['status'] == 'partial' and
                  resumed['summary'] == {'total': 6, 'success': 5, 'failed': 1})
            check(case.name + '/' + phase + ': retry budget admits every pending target but never reruns consumed attempts',
                  Counter(event['target'] for event in events(case)) ==
                  Counter({target: 1 for target in targets}) and
                  all(entry['attempts'] == 1 for entry in state['target_statuses'].values()) and
                  len(list(workspace.glob('logs/*.log'))) == 6 and
                  len((case / 'released-slots').read_text().splitlines()) == 6)
            if known_failure:
                verify_attempts(case, resumed, state, {target: 1 for target in targets},
                                {targets[0]: 9}, case.name + '/' + phase)
                check(case.name + '/' + phase + ': original failed sidecar keeps its actual exit and error',
                      failed['exit_code'] == 9 and
                      failed['error'] == 'deliberate stdin-consuming build failure' and
                      saved.get('reconciled_from_sidecar') is True)
            else:
                check(case.name + '/' + phase + ': missing worker evidence remains an explicit coordinator refusal',
                      failed['exit_code'] == 6 and failed['stage'] == 'resume' and
                      failed['receipt_source'] == 'coordinator' and
                      not any(key in failed for key in ('worker_exit_code', 'artifact_path',
                                                       'artifact_paths', 'resume_artifacts')) and
                      'result_path' not in failed and not prior_path.exists() and
                      unavailable_receipt.read_bytes() == unavailable_bytes and
                      len(list(workspace.glob('results/*.json'))) == 5)
            check(case.name + '/' + phase + ': successful work and every retained receipt remain unchanged',
                  all(row['status'] == 'success' and row['attempt'] == 1 for row in resumed['targets'][1:]) and
                  all(path.read_bytes() == contents for path, contents in immutable.items()))
        continue
    resumed, state = invoke(case, identity, jobs, 'success', 'resume')
    for row in resumed['targets'][:jobs]:
        target = row['platform']
        prior = before['target_statuses'][target]
        check(case.name + ': ' + target + ' sidecar recovery retains its authoritative attempt and receipt paths',
              row.get('attempt') == prior['attempts'] and
              row.get('log_path') == prior['log_path'] and
              row.get('result_path') == prior['result_path'] and
              row.get('resume_reused') is True and
              state['target_statuses'][target].get('reconciled_from_sidecar') is True)
        check(case.name + ': ' + target + ' embeds the complete recovered result in state',
              state['target_statuses'][target]['result'] == row)
    verify_attempts(case, resumed, state, {target: 1 for target in targets}, {}, case.name + '/resume')
    check(case.name + ': resume reuses only successful sidecars and preserves their bytes',
          all(bool(row.get('resume_reused')) == (row['platform'] in targets[:jobs])
              for row in resumed['targets']) and
          all(path.read_bytes() == contents for path, contents in immutable.items()))

    immutable = {path: path.read_bytes() for directory in ('output', 'logs', 'results')
                 for path in ((case / directory) if directory == 'output' else workspace / directory).rglob('*')
                 if path.is_file()}
    again, again_state = invoke(case, identity, jobs, 'success', 'resume-again')
    verify_attempts(case, again, again_state, {target: 1 for target in targets}, {}, case.name + '/resume-again')
    check(case.name + ': second resume reuses every embedded result without new attempts or changed receipts',
          all(row.get('resume_reused') is True for row in again['targets']) and
          all(path.read_bytes() == contents for path, contents in immutable.items()))

    # A completed result becomes non-reusable when its frozen payload is no
    # longer available. An exhausted retry budget must not turn it back into
    # successful publication evidence or silently compile a second attempt.
    artifact = Path(again['targets'][0]['artifact_path'])
    retained_artifact = case / 'unavailable-artifact.bin'
    artifact.rename(retained_artifact)
    retained_bytes = retained_artifact.read_bytes()
    immutable = {path: path.read_bytes() for directory in ('logs', 'results')
                 for path in (workspace / directory).rglob('*') if path.is_file()}
    for phase in ('resume-artifact-lost', 'resume-artifact-lost-again'):
        blocked, blocked_state = invoke(case, identity, jobs, 'success', phase,
                                        retry_max=1, expected_code=1)
        row = blocked['targets'][0]
        saved = blocked_state['target_statuses'][targets[0]]
        check(case.name + '/' + phase + ': unavailable completed artifacts cannot bypass the exhausted budget',
              row['status'] == 'failed' and row['exit_code'] == 6 and row['attempt'] == 1 and
              row['stage'] == 'resume' and row['receipt_source'] == 'coordinator' and
              row.get('retry_limit_exceeded') is True and
              not any(key in row for key in ('worker_exit_code', 'artifact_path',
                                             'artifact_paths', 'resume_artifacts')) and
              saved['status'] == 'failed' and saved['result'] == row and
              blocked_state['status'] == 'partial' and
              blocked['summary'] == {'total': 6, 'success': 5, 'failed': 1})
        check(case.name + '/' + phase + ': no new execution or receipt replaces the missing artifact evidence',
              Counter(event['target'] for event in events(case)) ==
              Counter({target: 1 for target in targets}) and
              all(entry['attempts'] == 1 for entry in blocked_state['target_statuses'].values()) and
              not artifact.exists() and retained_artifact.read_bytes() == retained_bytes and
              all(path.read_bytes() == contents for path, contents in immutable.items()) and
              len(list(workspace.glob('logs/*.log'))) == 6 and
              len(list(workspace.glob('results/*.json'))) == 6)

for refusal_kind in (('source-sync', 'readiness') if sidecar_cases else ()):
    recovery_mode = refusal_kind + '-recovery'
    readiness = refusal_kind == 'readiness'
    refusal_stage = 'host_readiness' if readiness else 'source_sync'
    refusal_exit = 4 if readiness else 1
    counter_key = 'host_readiness_failures' if readiness else 'source_sync_failures'
    case, identity = fixture(1, recovery_mode)
    workspace = case / 'state/builds/stdinfixture/1.0.0' / identity
    host_map = {target: 'host-' + target.replace('/', '-') for target in targets}
    sync_rows = [dict(host=host, path=str(case / 'source'),
                      status='failed' if target == targets[0] else 'success')
                 for target, host in host_map.items()]
    sync_rows[0]['error'] = 'deliberate source transport refusal'
    sync_receipt = dict(status='partial', synced=5, failed=1, target_hosts=host_map,
                        hosts=sync_rows,
                        source_roots={row['host']: row['path'] for row in sync_rows
                                      if row['status'] == 'success'})
    if not readiness:
        (case / 'source-sync.json').write_text(json.dumps(sync_receipt) + '\n')

    def crash_at_state_update(phase):
        env = invocation_env(case, identity, 1, recovery_mode, phase, retry_max=1)
        marker = case / (phase + '.state-update.ready')
        with open(case / (phase + '.stdout'), 'wb') as out, open(case / (phase + '.stderr'), 'wb') as err:
            process = subprocess.Popen(['bash', str(driver)], env=env, stdin=subprocess.DEVNULL,
                                       stdout=out, stderr=err, start_new_session=True)
            try:
                wait_for(process, marker.is_file,
                         case.name + '/' + phase + ': coordinator did not reach the real state boundary')
                check(case.name + '/' + phase + ': state barrier belongs to the actual coordinator',
                      int(marker.read_text()) == process.pid)
                process.kill()
                check(case.name + '/' + phase + ': actual coordinator death preserves the checkpoint',
                      process.wait(timeout=5) == -signal.SIGKILL)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
        state = read(workspace / 'state.json')
        (case / (phase + '.state.json')).write_text(json.dumps(state) + '\n')
        return state

    # The state boundary, not capacity waiting, must hold this checkpoint.
    (case / 'release').write_text('continue\n')
    before = crash_at_state_update('first')
    prior = before['target_statuses'][targets[0]]
    check(case.name + ': admission refusal completed before its result reached state',
          before['status'] == 'running' and prior['status'] == 'running' and
          prior['attempts'] == 1 and prior.get('result') is None and
          prior.get(counter_key, 0) == 0 and
          read(Path(prior['result_path']))['stage'] == refusal_stage and
          read(Path(prior['result_path']))['exit_code'] == refusal_exit and
          len(events(case)) == int(readiness) and
          all(event['mode'] == 'readiness' and event['stdin_is_null'] for event in events(case)) and
          len(list(case.glob('prelude.*.ready'))) == int(readiness) and
          not list((case / 'output').iterdir()))
    immutable = {Path(prior[key]): Path(prior[key]).read_bytes() for key in ('log_path', 'result_path')}
    for phase in ('resume-reconcile', 'resume-reconcile-again'):
        reconciled = crash_at_state_update(phase)
        saved = reconciled['target_statuses'][targets[0]]
        result = saved['result']
        check(case.name + '/' + phase + ': one admission refusal earns exactly one compiler-budget discount',
              saved['status'] == 'failed' and saved['attempts'] == 1 and
              saved.get(counter_key) == 1 and saved.get('reconciled_from_sidecar') is True and
              result['stage'] == refusal_stage and result['exit_code'] == refusal_exit and
              result['attempt'] == 1 and result['log_path'] == prior['log_path'] and
              result['result_path'] == prior['result_path'] and len(events(case)) == int(readiness) and
              all(reconciled['target_statuses'][target]['attempts'] == 0 for target in targets[1:]) and
              all(path.read_bytes() == contents for path, contents in immutable.items()))

    # Repair the admission gate and exercise the existing controlled compiler
    # payload boundary. Its first execution fails; max1 must then stop another
    # execution despite two earlier reconciliations of the same refused receipt.
    for row in sync_rows:
        row['status'] = 'success'
        row.pop('error', None)
    sync_receipt.update(status='success', synced=6, failed=0,
                        source_roots={row['host']: row['path'] for row in sync_rows})
    if not readiness:
        (case / 'source-sync.json').write_text(json.dumps(sync_receipt) + '\n')
    for phase, mode in (('resume-repaired', 'failure'), ('resume-budget-exhausted', 'success')):
        value, state = invoke(case, identity, 1, mode, phase, retry_max=1, expected_code=1)
        dispatches = {target: 2 if target == targets[0] else 1 for target in targets}
        observed_counts = {target: 2 if readiness and target == targets[0] else 1 for target in targets}
        verify_attempts(case, value, state, observed_counts,
                        {targets[0]: 9}, case.name + '/' + phase, dispatch_counts=dispatches)
        check(case.name + '/' + phase + ': repair admits exactly one real compiler attempt without over-discounting',
              state['target_statuses'][targets[0]].get(counter_key) == 1 and
              value['targets'][0]['attempt'] == 2 and
              sorted(event['attempt'] for event in events(case)
                     if event['target'] == targets[0] and event['mode'] != 'readiness') == [2] and
              len(list(workspace.glob('results/*.json'))) == 7 and
              len(list(workspace.glob('logs/*.log'))) == 7 and
              all(path.read_bytes() == contents for path, contents in immutable.items()))
        if phase == 'resume-budget-exhausted':
            check(case.name + ': admission discount does not admit a second compiler failure',
                  value['targets'][0].get('retry_limit_exceeded') is True and
                  value['targets'][0]['exit_code'] == 9)


if sys.argv[3] not in ('--coordinator-receipt-only', '--sidecar-recovery-only', '--worker-completion-only'):
    case = root / 'early-worker-refusal'
    case.mkdir()
    early_script = r'''
source "$1"
case_dir="$2"
selector_acquire_slot() { : > "$case_dir/unexpected-slot"; }
_act_build_orchestration_target() { : > "$case_dir/unexpected-build"; return 99; }
_act_run_target_worker fixture 1.0.0 55555555-5555-4555-8555-555555555555 \
    linux/amd64 1 "$case_dir/worker.log" "$case_dir/result.json" \
    true null '{}' '' '' unbound-host release x86_64-unknown-linux-musl \
    linux/amd64@x86_64-unknown-linux-musl
'''
    early = subprocess.run(['bash', '-c', early_script, '_', str(module), str(case)],
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
    (case / 'stdout').write_bytes(early.stdout)
    (case / 'stderr').write_bytes(early.stderr)
    receipt = read(case / 'result.json')
    check('early worker admission: missing source identity retains the attempted matrix task',
          early.returncode == 4 and receipt['status'] == 'failed' and receipt['exit_code'] == 4 and
          receipt['error'] == 'Missing strict worker source binding' and
          receipt['platform'] == 'linux/amd64' and receipt['host'] == 'unbound-host' and
          receipt['target_triple'] == 'x86_64-unknown-linux-musl' and
          receipt['task_key'] == 'linux/amd64@x86_64-unknown-linux-musl' and
          not receipt.get('resume_artifacts') and not (case / 'unexpected-slot').exists() and
          not (case / 'unexpected-build').exists())

    case, identity = fixture(3, 'cli-readiness')
    source = case / 'source'
    (source / 'README').write_text('Readiness-refusal fixture; no compiler should run.\n')
    for command in (['git', 'init', '-q', '--initial-branch=main', str(source)],
                    ['git', '-C', str(source), 'add', 'README'],
                    ['git', '-C', str(source), '-c', 'user.name=Fixture',
                     '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'],
                    ['git', '-C', str(source), 'tag', 'v1.0.0']):
        subprocess.run(command, check=True, capture_output=True)
    (case / 'release').write_text('continue\n')
    details, state = invoke(case, identity, 3, 'cli-readiness', 'cli')
    check('public CLI: every configured target keeps its real refusal instead of becoming skipped',
          [row['platform'] for row in details['targets']] == targets and
          (details['total'], details['success'], details['failed']) == (6, 0, 6))
    for row in details['targets']:
        target = row['platform']
        saved = state['target_statuses'][target]
        check('public CLI: ' + target + ' exposes host readiness, attempt and immutable receipts',
              row['status'] == 'failed' and row['exit_code'] == 4 and row['attempt'] == 1 and
              row['stage'] == 'host_readiness' and row['method'] == 'native' and
              row['host'] == 'host-' + target.replace('/', '-') and
              row['error'] == 'Native build host is not ready' and
              Path(row['log_path']).is_file() and Path(row['result_path']).is_file() and
              read(Path(row['result_path']))['platform'] == target and
              saved['attempts'] == 1 and saved['status'] == 'failed' and saved['result']['exit_code'] == 4)
    check('public CLI: all six stdin-reading health probes actually ran without compilation',
          Counter(event['target'] for event in events(case)) == Counter({target: 1 for target in targets}) and
          all(event['stdin_is_null'] and event['mode'] == 'readiness' for event in events(case)) and
          all(path.stat().st_size == 0 for path in case.glob('*.stdin')) and
          not list((case / 'output').glob('*.bin')))
    check('public CLI: readiness refusals retain failed state and cannot authorize publication',
          state['status'] == 'failed' and not details['publishable'] and not details['manifest_path'] and
          read(case / 'output/.dsr-build-purpose.json')['publishable'] is False)

(root / 'summary.json').write_text(json.dumps({'checks': checks, 'failures': 0}) + '\n')
print('Worker stdin isolation: %d checks, 0 failures' % checks, flush=True)
PY
}

# Faults at reservation or completion must retain genuine attempts, stop peers
# and permit exact resume without changing immutable evidence. Exercise the
# actual coordinator, state writer and worker processes; only payloads and the
# named failing write are substituted.
test_dispatch_reservation_recovery() {
    local project_root required_tool
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    for required_tool in python3 jq yq; do
        command -v "$required_tool" >/dev/null || return 77
    done
    python3 - "$project_root" "${DSR_TEST_ACT_RUNNER:-$project_root/src/act_runner.sh}" "${1:-all}" <<'PY'
from collections import Counter
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import uuid

project, module = map(Path, sys.argv[1:3])
root = Path(tempfile.mkdtemp(prefix='dsr-dispatch-reservation-'))
print('Retained dispatch reservation fixture: ' + str(root), flush=True)
targets = ['linux/amd64', 'linux/arm64', 'darwin/arm64']
checks = 0


def check(label, valid):
    global checks
    if not valid:
        raise AssertionError(label)
    checks += 1
    print('PASS: ' + label, flush=True)


def read(path):
    return json.loads(path.read_text())


def events(case):
    path = case / 'invocations.jsonl'
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


payload = root / 'payload.py'
payload.write_text(r'''import json, os, sys, time
from pathlib import Path
case, target, attempt, hold = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4] == 'true'
outcome, host = sys.argv[5], sys.argv[6]
assert sys.stdin.buffer.read() == b''
fd = os.open(case / 'invocations.jsonl', os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
os.write(fd, (json.dumps(dict(target=target, attempt=attempt, pid=os.getpid(), outcome=outcome)) + '\n').encode())
os.close(fd)
if hold:
    (case / 'peer.ready').write_text(str(os.getpid()))
    while True:
        time.sleep(0.02)
if outcome == 'failure':
    print(json.dumps(dict(platform=target, method='native', status='failed', exit_code=17,
                         error='controlled backend failure after a real execution')), flush=True)
    raise SystemExit(17)
path = case / 'output' / (target.replace('/', '-') + '.attempt-' + str(attempt))
path.write_bytes(('payload:' + target + ':' + str(attempt)).encode())
print(json.dumps(dict(platform=target, method='native', host=host, status='success', exit_code=0,
                     artifact_path=str(path), artifact_paths=[str(path)])), flush=True)
''')
driver = root / 'driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$DSR_RES_PROJECT/src/logging.sh"
source "$DSR_RES_PROJECT/src/config.sh"
source "$DSR_RES_PROJECT/src/build_state.sh"
source "$DSR_RES_MODULE"
eval "$(declare -f build_state_update_target | sed '1s/build_state_update_target/_real_target_update/')"
eval "$(declare -f build_state_update_host | sed '1s/build_state_update_host/_real_host_update/')"
eval "$(declare -f build_state_get | sed '1s/build_state_get/_real_state_read/')"
wait_for_active_peer() {
    [[ "$DSR_RES_JOBS" != 1 ]] || return 0
    local deadline=$((SECONDS + 15))
    while [[ ! -f "$DSR_RES_CASE/peer.ready" ]]; do
        ((SECONDS < deadline)) || return 1
        sleep 0.02
    done
}
build_state_update_target() {
    if [[ "$DSR_RES_MODE" == resume-* && "$3" == "$DSR_RES_FAULT_TARGET" &&
          ( "$4" == completed || "$4" == failed ) ]]; then
        if [[ "$DSR_RES_PHASE" == first ]] ||
           { [[ "$DSR_RES_PHASE" == resume-refusal ]] &&
             { [[ "$DSR_RES_MODE" == resume-budget* ]] && jq -e '.result.retry_limit_exceeded == true' <<< "$5" >/dev/null; }; }; then
            return 1
        fi
        if [[ "$DSR_RES_PHASE" == resume-refusal && "$DSR_RES_MODE" != resume-budget* &&
              "$DSR_RES_MODE" != resume-counter && "$DSR_RES_MODE" != resume-purpose &&
              "$DSR_RES_MODE" != resume-reservation-signal ]]; then
            jq -e '.reconciled_from_sidecar == true' <<< "$5" >/dev/null || return 90
            wait_for_active_peer || return 1
            return 1
        fi
    fi
    if [[ "$DSR_RES_PHASE" == resume-refusal && "$DSR_RES_MODE" == resume-reservation-signal &&
          "$3" == "$DSR_RES_FAULT_TARGET" && "$4" == running ]]; then
        _real_target_update "$@" || return $?
        wait_for_active_peer || return 1
        kill -TERM "$BASHPID"
        return 0
    fi
    if [[ "$DSR_RES_PHASE" == resume-refusal && "$3" == linux/amd64 && "$4" == running &&
          ( "$DSR_RES_MODE" == resume-counter || "$DSR_RES_MODE" == resume-purpose ) ]]; then
        _real_target_update "$@" || return $?
        local corrupt='{"attempts":"untrusted"}'
        if [[ "$DSR_RES_MODE" == resume-purpose ]]; then
            corrupt='{"result":{"platform":"linux/arm64","task_key":"linux/arm64","status":"failed","build_purpose":"diagnostic-native","publishable":false}}'
        fi
        # Corrupt only this owned checkpoint after admission, through the real
        # state writer. Immutable worker receipts and all other entries stay intact.
        _real_target_update "$1" "$2" "$DSR_RES_FAULT_TARGET" running "$corrupt" "$6"
        return $?
    fi
    if [[ ( "$DSR_RES_PHASE" == first || "$DSR_RES_PHASE" == cli ) &&
          "$3" == "$DSR_RES_FAULT_TARGET" &&
          ( "$4" == completed || "$4" == failed ) &&
          ( "$DSR_RES_MODE" == complete-target || "$DSR_RES_MODE" == failed-target ) ]]; then
        wait_for_active_peer || return 1
        return 1
    fi
    if [[ ( "$DSR_RES_PHASE" == first || "$DSR_RES_PHASE" == cli ) &&
          "$3" == "$DSR_RES_FAULT_TARGET" && "$4" == running ]]; then
        if [[ "$DSR_RES_MODE" == target-write ]]; then
            wait_for_active_peer || return 1
            return 1
        fi
        _real_target_update "$@" || return $?
        if [[ "$DSR_RES_MODE" == crash || "$DSR_RES_MODE" == signal ]]; then
            printf 'reserved\n' > "$DSR_RES_CASE/reserved"
            if [[ "$DSR_RES_MODE" == crash ]]; then kill -KILL "$BASHPID"; else kill -TERM "$BASHPID"; fi
        fi
        return 0
    fi
    _real_target_update "$@"
}
build_state_get() {
    if [[ "$DSR_RES_PHASE" == resume-refusal && -n "${worker_pids[0]:-}" &&
          ( "$DSR_RES_MODE" == resume-counter || "$DSR_RES_MODE" == resume-purpose ) ]]; then
        wait_for_active_peer || return 1
    fi
    if [[ "$DSR_RES_PHASE" == resume-refusal && "$DSR_RES_MODE" == resume-aggregation &&
          "${interrupted:-false}" == true && "${active_workers:-0}" == 0 ]]; then
        # Model an unreadable queued counter after the owned workers are
        # drained. Do not rewrite the saved checkpoint or any sidecar.
        _real_state_read "$@" | jq '.target_statuses["darwin/arm64"].attempts = "untrusted"'
        return $?
    fi
    _real_state_read "$@"
}
build_state_update_host() {
    if [[ "$DSR_RES_PHASE" == first && "$DSR_RES_MODE" == resume-unstarted &&
          "$3" == "host-${DSR_RES_FAULT_TARGET//\//-}" && "$4" == running ]]; then
        return 1
    fi
    if [[ ( "$DSR_RES_PHASE" == first || "$DSR_RES_PHASE" == cli ) &&
          "$3" == "host-${DSR_RES_FAULT_TARGET//\//-}" &&
          ( "$4" == completed || "$4" == failed ) &&
          ( "$DSR_RES_MODE" == complete-host || "$DSR_RES_MODE" == failed-host ) ]]; then
        wait_for_active_peer || return 1
        return 1
    fi
    if [[ ( "$DSR_RES_PHASE" == first || "$DSR_RES_PHASE" == cli ) &&
          "$3" == "host-${DSR_RES_FAULT_TARGET//\//-}" && "$4" == running &&
          ( "$DSR_RES_MODE" == host-write || "$DSR_RES_MODE" == log-write || "$DSR_RES_MODE" == receipt-write ) ]]; then
        wait_for_active_peer || return 1
        [[ "$DSR_RES_MODE" != host-write ]] || return 1
        _real_host_update "$@" || return $?
        if [[ "$DSR_RES_MODE" == log-write || "$DSR_RES_MODE" == receipt-write ]]; then
            mkdir "$log_path" || return 1
            if [[ "$DSR_RES_MODE" == receipt-write ]]; then mkdir "$result_path" || return 1; fi
        fi
        return 0
    fi
    _real_host_update "$@"
}
selector_acquire_slot() {
    if [[ ( "$DSR_RES_PHASE" == first || "$DSR_RES_PHASE" == cli ) && "$DSR_RES_MODE" == completion-receipt &&
          "$host" == "host-${DSR_RES_FAULT_TARGET//\//-}" ]]; then
        # Keep the directory and all its evidence, but make the destination
        # unavailable for both the real worker and coordinator receipt writes.
        # Restoring this exact directory models repairing the storage outage.
        local receipt_directory="${result_path%/*}"
        [[ ! -e "$receipt_directory.unavailable" ]] || return 1
        mv "$receipt_directory" "$receipt_directory.unavailable" || return 1
    fi
    return 0
}
selector_release_slot() { return 0; }
act_run_native_build() {
    local hold=false outcome=success
    if [[ "$DSR_RES_PHASE" == first && "$DSR_RES_JOBS" == 3 &&
          "$DSR_RES_MODE" != crash && "$DSR_RES_MODE" != signal &&
          "$DSR_RES_MODE" != resume-* && "$2" == linux/amd64 ]]; then hold=true; fi
    if [[ "$DSR_RES_PHASE" == first && "$DSR_RES_JOBS" == 2 && "$2" == linux/arm64 ]]; then
        hold=true
    fi
    if [[ ( "$DSR_RES_PHASE" == first || "$DSR_RES_PHASE" == cli ) &&
          "$2" == "$DSR_RES_FAULT_TARGET" ]]; then
        case "$DSR_RES_MODE" in
            complete-*|failed-*|completion-receipt) wait_for_active_peer || return 1 ;;
        esac
        case "$DSR_RES_MODE" in
            failed-*|completion-receipt) outcome=failure ;;
        esac
    fi
    if [[ "$DSR_RES_MODE" == resume-* ]]; then
        if [[ "$DSR_RES_PHASE" == first && "$2" == linux/amd64 ]]; then outcome=failure; fi
        if [[ "$DSR_RES_PHASE" == first && "$2" == "$DSR_RES_FAULT_TARGET" &&
              ( "$DSR_RES_MODE" == resume-failed || "$DSR_RES_MODE" == resume-budget* ||
                "$DSR_RES_MODE" == resume-reservation-signal ) ]]; then outcome=failure; fi
        if [[ "$DSR_RES_PHASE" == resume-refusal && "$DSR_RES_JOBS" == 3 && "$2" == linux/amd64 ]]; then hold=true; fi
    fi
    python3 "$DSR_RES_PAYLOAD" "$DSR_RES_CASE" "$2" "$attempt" "$hold" "$outcome" "$8"
}
args=(--run-id "$DSR_RES_RUN")
[[ "$DSR_RES_PHASE" == first ]] || args=(--resume-run-id "$DSR_RES_RUN")
if [[ "$DSR_RES_PHASE" == cli ]]; then
    for module in git_ops artifact_naming packaging; do
        source "$DSR_RES_PROJECT/src/$module.sh" || exit 1
    done
    export SCRIPT_DIR="$DSR_RES_PROJECT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture
    declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
    source <(awk '/^(_dsr_require|cmd_build)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' \
        "$DSR_RES_PROJECT/dsr") || exit 1
    source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' \
        "$DSR_RES_PROJECT/dsr") || exit 1
    cmd_build reservationfixture --version 1.0.0 --no-sync --jobs "$DSR_RES_JOBS" \
        --output-dir "$DSR_RES_CASE/output"
else
    orchestration_status=0
    act_orchestrate_build reservationfixture 1.0.0 --parallel-jobs "$DSR_RES_JOBS" \
        --no-source-sync-gate --output-dir "$DSR_RES_CASE/output" "${args[@]}" || orchestration_status=$?
    trap -p INT TERM > "$DSR_RES_CASE/$DSR_RES_PHASE.caller-traps"
    exit "$orchestration_status"
fi
''')


def invoke(case, run, jobs, mode, phase, retry_max=3):
    env = dict(os.environ, DSR_STATE_DIR=str(case / 'state'), DSR_CACHE_DIR=str(case / 'cache'),
               DSR_CONFIG_DIR=str(case / 'config'), ACT_REPOS_DIR=str(case / 'config/repos.d'),
               ACT_LOGS_DIR=str(case / 'logs'), ACT_ARTIFACTS_DIR=str(case / 'artifacts'),
               DSR_DISABLE_HOST_SELECTOR='1', DSR_RETRY_MAX=str(retry_max), NO_COLOR='1',
               DSR_RES_PROJECT=str(project), DSR_RES_MODULE=str(module), DSR_RES_PAYLOAD=str(payload),
               DSR_RES_CASE=str(case), DSR_RES_RUN=run, DSR_RES_JOBS=str(jobs),
               DSR_RES_MODE=mode, DSR_RES_PHASE=phase,
               DSR_RES_FAULT_TARGET=targets[0] if mode in ('crash', 'signal', 'complete-target',
                   'complete-host', 'failed-target', 'failed-host', 'completion-receipt') or phase == 'cli' else targets[1])
    env.pop('DSR_BUILD_LOCK_HELD_BY_CALLER', None)
    with open(case / (phase + '.stdout'), 'wb') as out, open(case / (phase + '.stderr'), 'wb') as err:
        process = subprocess.Popen(['bash', str(driver)], env=env, stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=err, start_new_session=True)
        try:
            code = process.wait(timeout=45)
        except BaseException:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            raise
    value = None if code == -signal.SIGKILL or not (case / (phase + '.stdout')).stat().st_size else read(case / (phase + '.stdout'))
    if phase == 'cli':
        run = value['details']['run_id']
    state = read(case / 'state/builds/reservationfixture/1.0.0' / run / 'state.json')
    return code, value, state


def resume_fixture(label):
    case = root / label
    for directory in ('config/repos.d', 'state', 'cache', 'source', 'output'):
        (case / directory).mkdir(parents=True, exist_ok=True)
    hosts = {target: 'host-' + target.replace('/', '-') for target in targets}
    (case / 'config/hosts.yaml').write_text(json.dumps({
        'schema_version': '1.0.0', 'platform_mapping': hosts,
        'hosts': {host: {'platform': target, 'connection': 'local'} for target, host in hosts.items()}}))
    (case / 'config/repos.d/reservationfixture.yaml').write_text(json.dumps({
        'tool_name': 'reservationfixture', 'repo': 'fixture/reservationfixture', 'language': 'go',
        'local_path': str(case / 'source'), 'binary_name': 'fixture', 'targets': targets,
        'cross_compile': {target: {'host': host} for target, host in hosts.items()}}))
    return case, str(uuid.uuid4())


resume_cases = [] if sys.argv[3] == '--completion-persistence-only' else (
    [(jobs, mode) for jobs in (1, 3) for mode in ('resume-success', 'resume-failed', 'resume-unstarted')] +
    [(1, 'resume-budget'), (1, 'resume-budget-missing'), (1, 'resume-budget-empty'),
     (3, 'resume-counter'), (3, 'resume-purpose'), (3, 'resume-aggregation')])
for jobs, mode in resume_cases:
    case, run = resume_fixture('jobs-%d-%s' % (jobs, mode))
    workspace = case / 'state/builds/reservationfixture/1.0.0' / run
    # The real serial producer leaves target one failed and target two's
    # completed sidecar ahead of its checkpoint. Target three never starts.
    seed_code, seed, seed_state = invoke(case, run, 1, mode, 'first')
    original_entry = seed_state['target_statuses'][targets[1]]
    original_path = Path(original_entry['result_path'])
    original_receipt = read(original_path)
    original_bytes = original_path.read_bytes()
    unstarted = mode == 'resume-unstarted'
    budget = mode.startswith('resume-budget')
    check(case.name + ': actual seed retains an uncheckpointed immutable target outcome',
          seed_code == 4 and original_entry['status'] == 'running' and not original_entry.get('result') and
          original_entry['attempts'] == 1 and seed_state['target_statuses'][targets[2]]['attempts'] == 0 and
          Counter(event['target'] for event in events(case)) ==
          Counter({targets[0]: 1, **({} if unstarted else {targets[1]: 1})}))
    missing_path = None
    if mode in ('resume-budget-missing', 'resume-budget-empty'):
        missing_path = case / 'retained-unavailable-sidecar.json'
        original_path.rename(missing_path)
        if mode == 'resume-budget-empty':
            original_path.write_bytes(b'')
    immutable = {path: path.read_bytes() for directory in (case / 'output', workspace / 'logs', workspace / 'results')
                 for path in directory.rglob('*') if path.is_file() and
                 not (mode == 'resume-budget-empty' and path == original_path)}
    code, result, state = invoke(case, run, jobs, mode, 'resume-refusal', retry_max=1 if budget else 3)
    row, peer, queued = result['targets'][1], result['targets'][0], result['targets'][2]
    reason = ('Invalid or unavailable source synchronization/readiness/capacity/build attempt counters' if mode == 'resume-counter'
              else 'Resume target result has missing or different build purpose' if mode == 'resume-purpose'
              else 'Could not persist retry-budget outcome' if budget
              else 'Could not persist recovered target outcome')
    check(case.name + ': resume failure remains a first-cause coordinator error, not operator interruption',
          code == 4 and result['exit_code'] == 4 and result['status'] == 'failed' and
          reason in result['error'] and targets[1] in result['error'] and state['status'] == 'failed')
    check(case.name + ': refused resume does not allocate a new attempt for recovered or queued work',
          len([event for event in events(case) if event['target'] == targets[1]]) == int(not unstarted) and
          not any(event['target'] == targets[2] for event in events(case)) and
          state['target_statuses'][targets[2]]['attempts'] == 0)
    if mode in ('resume-counter', 'resume-purpose'):
        check(case.name + ': invalid authority is an explicit refusal without borrowed receipt paths',
              row['status'] == 'failed' and row['exit_code'] == 4 and row['stage'] == 'resume' and
              row['execution_started'] is False and row['receipt_source'] == 'coordinator' and
              not any(key in row for key in ('result_path', 'log_path', 'artifact_path', 'resume_artifacts')) and
              (('attempt' not in row) if mode == 'resume-counter' else row['attempt'] == 1))
    elif mode in ('resume-budget-missing', 'resume-budget-empty'):
        check(case.name + ': missing historical receipt never becomes a reported file or observed worker exit',
              row['status'] == 'failed' and row['exit_code'] == 6 and row['attempt'] == 1 and
              row['stage'] == 'resume' and row['retry_limit_exceeded'] is True and
              'result_path' not in row and 'worker_exit_code' not in row and
              missing_path.read_bytes() == original_bytes)
        if mode == 'resume-budget-empty':
            check(case.name + ': an empty sidecar stays unmodified and never becomes admitted receipt evidence',
                  original_path.is_file() and original_path.read_bytes() == b'')
    else:
        check(case.name + ': failed checkpoint preserves the verified historical outcome and attempt',
              row['status'] == original_receipt['status'] and row['exit_code'] == original_receipt['exit_code'] and
              row['attempt'] == 1 and row['result_path'] == str(original_path) and
              original_path.read_bytes() == original_bytes and
              bool(row.get('retry_limit_exceeded')) == budget)
        if original_receipt['status'] == 'success':
            check(case.name + ': recovered success retains actual execution and complete frozen artifact evidence',
                  row.get('resume_reused') is True and row['execution_started'] is True and
                  row['resume_artifacts'] == original_receipt['resume_artifacts'])
        if unstarted:
            check(case.name + ': a coordinator dispatch refusal remains explicitly unstarted after recovery',
                  row['execution_started'] is False and row['stage'] == 'dispatch' and
                  'log_path' not in original_receipt and 'log_path' not in row and not row.get('resume_artifacts'))
    if mode == 'resume-aggregation':
        check(case.name + ': aggregation refuses unreadable history without inventing an attempt or changing the first cause',
              queued['status'] == 'failed' and queued['exit_code'] == 4 and 'attempt' not in queued and
              'result_path' not in queued and 'log_path' not in queued and
              result['error'] == 'Could not persist recovered target outcome for ' + targets[1])
    else:
        check(case.name + ': queued target remains unstarted with its original zero-attempt history',
              queued['status'] == 'skipped' and queued['exit_code'] == 4 and queued['attempt'] == 0 and
              queued['execution_started'] is False and result['error'] in queued['error'] and
              'result_path' not in queued and 'log_path' not in queued)
    check(case.name + ': coordinator failures leave caller INT and TERM dispositions usable',
          not (case / 'resume-refusal.caller-traps').read_text())
    if jobs == 3:
        check(case.name + ': started peer is cancelled with the actual second attempt and receipt',
              peer['status'] == 'failed' and peer['exit_code'] == 130 and peer['attempt'] == 2 and
              peer['execution_started'] is True and Path(peer['result_path']).is_file())
        event = next(event for event in events(case) if event['target'] == targets[0] and event['attempt'] == 2)
        live = subprocess.run(['ps', '-p', str(event['pid']), '-o', 'stat='], capture_output=True, text=True)
        check(case.name + ': actual descendant stops before failed resume returns',
              live.returncode != 0 or not live.stdout.strip() or live.stdout.strip().startswith('Z'))
    check(case.name + ': refusal preserves every original artifact, log and sidecar byte',
          all(path.read_bytes() == contents for path, contents in immutable.items()))
    if missing_path is not None:
        if mode == 'resume-budget-empty':
            original_path.rename(case / 'retained-empty-sidecar.json')
        missing_path.rename(original_path)
    if mode in ('resume-counter', 'resume-purpose'):
        # Repair only the corrupted entry; retain the peer's actual interrupted
        # second attempt and all other checkpoint updates from this invocation.
        repaired = read(workspace / 'state.json')
        repaired['target_statuses'][targets[1]] = original_entry
        (workspace / 'state.json').write_text(json.dumps(repaired) + '\n')
    repaired_code, repaired, repaired_state = invoke(case, run, jobs, mode, 'resume-repaired')
    expected = {targets[0]: 3 if jobs == 3 else 2,
                targets[1]: 1 if original_receipt['status'] == 'success' else 2, targets[2]: 1}
    check(case.name + ': exact resume after repair reuses successes and retries only necessary attempts',
          repaired_code == 0 and repaired['summary'] == dict(total=3, success=3, failed=0) and
          all(row['attempt'] == expected[row['platform']] for row in repaired['targets']) and
          all(repaired_state['target_statuses'][target]['attempts'] == expected[target] for target in targets) and
          original_path.read_bytes() == original_bytes)
    expected_events = dict(expected)
    if unstarted:
        expected_events[targets[1]] -= 1
    check(case.name + ': execution events distinguish reserved-only history from real attempts',
          Counter(event['target'] for event in events(case)) == Counter(expected_events))
    before_repeat = events(case)
    repeated_code, repeated, repeated_state = invoke(case, run, jobs, mode, 'resume-again')
    check(case.name + ': repeated exact resume does not allocate or execute another attempt',
          repeated_code == 0 and events(case) == before_repeat and
          all(row.get('resume_reused') is True and row['attempt'] == expected[row['platform']] for row in repeated['targets']) and
          all(path.read_bytes() == contents for path, contents in immutable.items()))

if sys.argv[3] != '--completion-persistence-only':
    for jobs in (1, 3):
        case, run = resume_fixture('reserved-retry-signal-%d' % jobs)
        code, _, state = invoke(case, run, 1, 'resume-reservation-signal', 'first')
        old = state['target_statuses'][targets[1]]
        sidecar = Path(old['result_path'])
        contents = sidecar.read_bytes()
        code, result, state = invoke(case, run, jobs, 'resume-reservation-signal', 'resume-refusal')
        refused = result['targets'][1]
        check(case.name + ': real cancellation after retry reservation reports the new unstarted attempt',
              code == 130 and result['exit_code'] == 130 and 'error' not in result and
              refused['status'] == 'skipped' and refused['exit_code'] == 130 and refused['attempt'] == 2 and
              refused['execution_started'] is False and 'result_path' not in refused and 'log_path' not in refused and
              state['target_statuses'][targets[1]]['attempts'] == 2 and
              state['target_statuses'][targets[1]]['result'] is None and sidecar.read_bytes() == contents and
              len([event for event in events(case) if event['target'] == targets[1]]) == 1)
        repaired_code, repaired, repaired_state = invoke(case, run, jobs, 'resume-reservation-signal', 'resume-repaired')
        expected = {targets[0]: 2 if jobs == 1 else 3, targets[1]: 3, targets[2]: 1}
        check(case.name + ': repaired resume preserves both the old failure and the interrupted reservation',
              repaired_code == 0 and all(row['attempt'] == expected[row['platform']] for row in repaired['targets']) and
              repaired_state['target_statuses'][targets[1]]['attempts'] == 3 and sidecar.read_bytes() == contents and
              len([event for event in events(case) if event['target'] == targets[1]]) == 2)
    for invalid in ('counter', 'purpose'):
        case, run = resume_fixture('preflight-' + invalid)
        code, _, state = invoke(case, run, 1, 'resume-success', 'first')
        workspace = case / 'state/builds/reservationfixture/1.0.0' / run
        state_path = workspace / 'state.json'
        original = state_path.read_bytes()
        corrupted = read(state_path)
        entry = corrupted['target_statuses'][targets[1]]
        if invalid == 'counter':
            entry['attempts'] = 'untrusted'
        else:
            entry['result'] = dict(read(Path(entry['result_path'])), build_purpose='diagnostic-native', publishable=False)
        state_path.write_text(json.dumps(corrupted) + '\n')
        corrupted_bytes = state_path.read_bytes()
        before = events(case)
        refused_code, refused, _ = invoke(case, run, 3, 'resume-success', 'resume-preflight')
        check(case.name + ': invalid saved authority refuses before any worker or attempt allocation',
              code == 4 and refused_code == 4 and refused is None and events(case) == before and
              state_path.read_bytes() == corrupted_bytes and
              ('attempt counters' if invalid == 'counter' else 'build purpose') in (case / 'resume-preflight.stderr').read_text())
        state_path.write_bytes(original)
        repaired_code, repaired, _ = invoke(case, run, 3, 'resume-success', 'resume-repaired')
        check(case.name + ': preflight refusal releases the run lock for exact repaired resume',
              repaired_code == 0 and repaired['summary'] == dict(total=3, success=3, failed=0))

if sys.argv[3] == '--resume-persistence-only':
    print('Resume persistence recovery: %d checks, 0 failures' % checks, flush=True)
    sys.exit(0)


for jobs in (() if sys.argv[3] == '--completion-persistence-only' else (1, 3)):
    for mode in ('target-write', 'host-write', 'log-write', 'receipt-write', 'crash', 'signal'):
        case = root / ('jobs-%d-%s' % (jobs, mode))
        for directory in ('config/repos.d', 'state', 'cache', 'source', 'output'):
            (case / directory).mkdir(parents=True, exist_ok=True)
        hosts = {target: 'host-' + target.replace('/', '-') for target in targets}
        (case / 'config/hosts.yaml').write_text(json.dumps({
            'schema_version': '1.0.0', 'platform_mapping': hosts,
            'hosts': {host: {'platform': target, 'connection': 'local'} for target, host in hosts.items()}}))
        (case / 'config/repos.d/reservationfixture.yaml').write_text(json.dumps({
            'tool_name': 'reservationfixture', 'repo': 'fixture/reservationfixture', 'language': 'go',
            'local_path': str(case / 'source'), 'binary_name': 'fixture', 'targets': targets,
            'cross_compile': {target: {'host': host} for target, host in hosts.items()}}))
        run = str(uuid.uuid4())
        workspace = case / 'state/builds/reservationfixture/1.0.0' / run
        code, result, state = invoke(case, run, jobs, mode, 'first')
        label = case.name
        if mode in ('crash', 'signal'):
            check(label + ': actual signal stops the coordinator after durable reservation',
                  code == (-signal.SIGKILL if mode == 'crash' else 130) and (case / 'reserved').is_file())
            check(label + ': no immutable log or worker exists before the reserved dispatch',
                  state['target_statuses'][targets[0]]['attempts'] == 1 and not events(case) and
                  not list((workspace / 'logs').iterdir()) and not list((workspace / 'results').iterdir()))
            if mode == 'signal':
                check(label + ': genuine cancellation remains exit 130',
                      result['exit_code'] == 130 and all(row['exit_code'] == 130 for row in result['targets']))
            expected_attempts = {targets[0]: 2, targets[1]: 1, targets[2]: 1}
        else:
            refused = result['targets'][1]
            reserved = mode != 'target-write'
            check(label + ': persistence refusal remains a coordinator error, not cancellation',
                  code == 4 and result['exit_code'] == 4 and result['status'] == 'failed')
            check(label + ': unstarted target is explicitly classified without a build log',
                  refused['stage'] == 'dispatch' and refused['exit_code'] == 4 and
                  refused['execution_started'] is False and refused['attempt'] == int(reserved) and
                  refused['status'] == ('failed' if reserved else 'skipped') and 'log_path' not in refused)
            check(label + ': queued target remains undispatched with its real reason',
                  result['targets'][2]['status'] == 'skipped' and result['targets'][2]['attempt'] == 0 and
                  result['targets'][2]['stage'] == 'dispatch' and result['targets'][2]['exit_code'] == 4 and
                  state['target_statuses'][targets[2]]['attempts'] == 0)
            check(label + ': no payload ran for the refused or queued target',
                  Counter(event['target'] for event in events(case)) == Counter({targets[0]: 1}))
            if not reserved:
                check(label + ': failed reservation creates no orphan log or result',
                      state['target_statuses'][targets[1]]['attempts'] == 0 and
                      not list((workspace / 'logs').glob('*linux-arm64*')) and
                      not list((workspace / 'results').glob('*linux-arm64*')) and 'result_path' not in refused)
            elif mode == 'receipt-write':
                check(label + ': failed receipt publication never invents a result path',
                      'result_path' not in refused and
                      state['target_statuses'][targets[1]]['result'].get('result_path') is None and
                      list((workspace / 'results').glob('*linux-arm64*'))[0].is_dir())
            else:
                check(label + ': reserved refusal retains its exact immutable receipt',
                      Path(refused['result_path']).is_file() and read(Path(refused['result_path'])) == refused and
                      state['target_statuses'][targets[1]]['result'] == refused)
            if jobs == 3:
                check(label + ': started peer is cancelled and reaped with its own actual attempt',
                      result['targets'][0]['exit_code'] == 130 and result['targets'][0]['attempt'] == 1 and
                      Path(result['targets'][0]['result_path']).is_file())
                pid = events(case)[0]['pid']
                observed = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
                check(label + ': started descendant is no longer doing work',
                      observed.returncode != 0 or not observed.stdout.strip() or observed.stdout.strip().startswith('Z'))
            expected_attempts = {targets[0]: 1 if jobs == 1 else 2,
                                 targets[1]: 2 if reserved else 1, targets[2]: 1}

        immutable = {path: path.read_bytes() for directory in (case / 'output', workspace / 'logs', workspace / 'results')
                     for path in directory.rglob('*') if path.is_file()}
        retained_directories = {path for directory in (workspace / 'logs', workspace / 'results')
                                for path in directory.iterdir() if path.is_dir()}
        resumed_code, resumed, resumed_state = invoke(case, run, jobs, mode, 'resume')
        check(label + ': exact-run resume finishes every target with monotonic attempt numbers',
              resumed_code == 0 and resumed['summary'] == dict(total=3, success=3, failed=0) and
              [row['platform'] for row in resumed['targets']] == targets and
              all(row['attempt'] == expected_attempts[row['platform']] for row in resumed['targets']) and
              all(resumed_state['target_statuses'][target]['attempts'] == expected_attempts[target] for target in targets))
        expected_counts = {target: 1 for target in targets}
        if jobs == 3 and mode not in ('crash', 'signal'):
            expected_counts[targets[0]] = 2
        check(label + ': resume performs exactly the missing work and reuses completed bytes',
              Counter(event['target'] for event in events(case)) == Counter(expected_counts) and
              all(path.read_bytes() == contents for path, contents in immutable.items()) and
              all(path.is_dir() for path in retained_directories))
        check(label + ': every success has real payloads and immutable attempt evidence',
              all(Path(row['artifact_path']).is_file() and Path(row['log_path']).is_file() and
                  Path(row['result_path']).is_file() and row['resume_artifacts'] for row in resumed['targets']))

for jobs in (1, 2):
    for mode in ('complete-target', 'complete-host', 'failed-target', 'failed-host', 'completion-receipt'):
        case = root / ('jobs-%d-%s' % (jobs, mode))
        for directory in ('config/repos.d', 'state', 'cache', 'source', 'output'):
            (case / directory).mkdir(parents=True, exist_ok=True)
        hosts = {target: 'host-' + target.replace('/', '-') for target in targets}
        (case / 'config/hosts.yaml').write_text(json.dumps({
            'schema_version': '1.0.0', 'platform_mapping': hosts,
            'hosts': {host: {'platform': target, 'connection': 'local'} for target, host in hosts.items()}}))
        (case / 'config/repos.d/reservationfixture.yaml').write_text(json.dumps({
            'tool_name': 'reservationfixture', 'repo': 'fixture/reservationfixture', 'language': 'go',
            'local_path': str(case / 'source'), 'binary_name': 'fixture', 'targets': targets,
            'cross_compile': {target: {'host': host} for target, host in hosts.items()}}))
        run = str(uuid.uuid4())
        workspace = case / 'state/builds/reservationfixture/1.0.0' / run
        code, result, state = invoke(case, run, jobs, mode, 'first')
        label = case.name
        completed = mode.startswith('complete-')
        observed = result['targets'][0]
        expected_exit = 0 if completed else 4 if mode == 'completion-receipt' else 17
        check(label + ': completion persistence failure is exit 4 with a stable machine-readable cause',
              code == 4 and result['exit_code'] == 4 and result['status'] == 'failed' and
              result['error'] == 'Could not retain completed target outcome for ' + targets[0] and
              state['status'] == 'failed')
        check(label + ': the actual attempt and backend outcome survive failed bookkeeping',
              observed['platform'] == targets[0] and observed['attempt'] == 1 and
              observed['execution_started'] is True and observed['exit_code'] == expected_exit and
              observed['status'] == ('success' if completed else 'failed') and
              Path(observed['log_path']).is_file() and state['target_statuses'][targets[0]]['attempts'] == 1)
        check(label + ': no additional compiler was started for queued targets',
              Counter(event['target'] for event in events(case)) == Counter({target: 1 for target in targets[:jobs]}) and
              all(row['status'] == 'skipped' and row['exit_code'] == 4 and row['attempt'] == 0 and
                  row['stage'] == 'dispatch' and row['execution_started'] is False and
                  result['error'] in row['error'] and 'log_path' not in row and 'result_path' not in row and
                  state['target_statuses'][row['platform']]['attempts'] == 0 for row in result['targets'][jobs:]))
        if mode == 'completion-receipt':
            check(label + ': unavailable sidecar storage cannot erase observed worker exits or invent paths',
                  observed['worker_exit_code'] == 4 and observed['receipt_source'] == 'coordinator' and
                  'result_path' not in observed and 'artifact_path' not in observed and
                  'controlled backend failure after a real execution' in Path(observed['log_path']).read_text() and
                  not (workspace / 'results').exists() and
                  (workspace / 'results.unavailable').is_dir() and
                  not list((workspace / 'results.unavailable').iterdir()))
        else:
            receipt = read(Path(observed['result_path']))
            check(label + ': original worker receipt retains the genuine result without coordinator rewrites',
                  receipt['status'] == observed['status'] and receipt['exit_code'] == expected_exit and
                  receipt['platform'] == targets[0] and 'execution_started' not in receipt)
            saved = state['target_statuses'][targets[0]]
            check(label + ': failed target or host write leaves its truthful durable boundary',
                  (saved['status'] == 'running' and saved.get('result') is None)
                  if mode.endswith('-target') else
                  (saved['status'] == ('completed' if completed else 'failed') and saved['result'] == observed))
        if jobs == 2:
            peer = result['targets'][1]
            check(label + ': active peer retains a real cancelled attempt and cannot be mistaken for queued work',
                  peer['status'] == 'failed' and peer['exit_code'] == 130 and peer['attempt'] == 1 and
                  peer['execution_started'] is True and Path(peer['log_path']).is_file())
            peer_event = next(event for event in events(case) if event['target'] == targets[1])
            probe = subprocess.run(['ps', '-p', str(peer_event['pid']), '-o', 'stat='], capture_output=True, text=True)
            check(label + ': cancellation reaps the running descendant before returning',
                  probe.returncode != 0 or not probe.stdout.strip() or probe.stdout.strip().startswith('Z'))
            if mode == 'completion-receipt':
                check(label + ': a peer receipt failure preserves the first coordinator cause',
                      'result_path' not in peer and peer['worker_exit_code'] == 130 and
                      result['error'].endswith(targets[0]))
            else:
                check(label + ': peer cancellation retains its immutable interrupted receipt',
                      Path(peer['result_path']).is_file() and read(Path(peer['result_path']))['exit_code'] == 130)

        immutable = {path: path.read_bytes() for directory in (case / 'output', workspace / 'logs', workspace / 'results')
                     for path in directory.rglob('*') if path.is_file()}
        if mode == 'completion-receipt':
            unavailable = workspace / 'results.unavailable'
            receipt_identity = (unavailable.stat().st_dev, unavailable.stat().st_ino)
            unavailable.rename(workspace / 'results')
            restored = workspace / 'results'
            check(label + ': repair restores the original retained receipt directory',
                  (restored.stat().st_dev, restored.stat().st_ino) == receipt_identity)
        expected_attempts = {targets[0]: 1 if completed else 2, targets[1]: jobs, targets[2]: 1}
        resumed_code, resumed, resumed_state = invoke(case, run, jobs, mode, 'resume')
        check(label + ': exact-run resume completes every target with the correct attempt identities',
              resumed_code == 0 and resumed['summary'] == dict(total=3, success=3, failed=0) and
              all(row['attempt'] == expected_attempts[row['platform']] for row in resumed['targets']) and
              all(resumed_state['target_statuses'][target]['attempts'] == expected_attempts[target]
                  for target in targets))
        check(label + ': resume reuses completed bytes and retries only failed or missing work',
              Counter(event['target'] for event in events(case)) == Counter(expected_attempts) and
              bool(resumed['targets'][0].get('resume_reused')) == completed and
              all(path.read_bytes() == contents for path, contents in immutable.items()))
        check(label + ': resumed artifacts retain real immutable receipts and validated bytes',
              all(Path(row['artifact_path']).is_file() and Path(row['log_path']).is_file() and
                  Path(row['result_path']).is_file() and row['resume_artifacts'] for row in resumed['targets']))
        before_repeat = list(events(case))
        repeated_code, repeated, repeated_state = invoke(case, run, jobs, mode, 'resume-again')
        check(label + ': repeated exact resume performs no further execution or attempt allocation',
              repeated_code == 0 and events(case) == before_repeat and
              all(row.get('resume_reused') and row['attempt'] == expected_attempts[row['platform']]
                  for row in repeated['targets']) and
              all(repeated_state['target_statuses'][target]['attempts'] == expected_attempts[target]
                  for target in targets) and all(path.read_bytes() == contents for path, contents in immutable.items()))

def cli_fixture(name, configured_targets):
    case = root / name
    for directory in ('config/repos.d', 'state', 'cache', 'source', 'output'):
        (case / directory).mkdir(parents=True, exist_ok=True)
    hosts = {target: 'host-' + target.replace('/', '-') for target in configured_targets}
    (case / 'config/hosts.yaml').write_text(json.dumps({
        'schema_version': '1.0.0', 'platform_mapping': hosts,
        'hosts': {host: {'platform': target, 'connection': 'local'} for target, host in hosts.items()}}))
    (case / 'config/repos.d/reservationfixture.yaml').write_text(json.dumps({
        'tool_name': 'reservationfixture', 'repo': 'fixture/reservationfixture', 'language': 'go',
        'local_path': str(case / 'source'), 'binary_name': 'fixture', 'targets': configured_targets,
        'cross_compile': {target: {'host': host} for target, host in hosts.items()}}))
    for command in (['git', '-C', str(case / 'source'), 'init', '-q'],
                    ['git', '-C', str(case / 'source'), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                     'commit', '--allow-empty', '-qm', 'source identity']):
        subprocess.run(command, check=True, capture_output=True)
    return case


case = cli_fixture('public-cli-refusal', targets)
code, envelope, state = invoke(case, str(uuid.uuid4()), 1, 'host-write', 'cli')
details = envelope['details']
refused = details['targets'][0]
check('public CLI: coordinator refusal remains exit 4 with all configured targets represented',
      code == 4 and envelope['exit_code'] == 4 and envelope['command'] == 'build' and
      [row['platform'] for row in details['targets']] == targets and
      (details['total'], details['success'], details['failed']) == (3, 0, 3))
check('public CLI: reserved refusal retains actual receipt without fabricating a worker log',
      refused['status'] == 'failed' and refused['stage'] == 'dispatch' and
      refused['exit_code'] == 4 and refused['execution_started'] is False and refused['attempt'] == 1 and
      'log_path' not in refused and Path(refused['result_path']).is_file() and
      read(Path(refused['result_path']))['execution_started'] is False and
      state['target_statuses'][targets[0]]['result']['result_path'] == refused['result_path'])
check('public CLI: queued targets remain unstarted and release publication remains blocked',
      all(row['status'] == 'skipped' and row['attempt'] == 0 and row['stage'] == 'dispatch' and
          row['exit_code'] == 4 and row['execution_started'] is False and
          'log_path' not in row and 'result_path' not in row for row in details['targets'][1:]) and
      not events(case) and state['status'] == 'failed' and not details['publishable'] and not details['manifest_path'])

case = cli_fixture('public-cli-completion', targets[:1])
code, envelope, state = invoke(case, str(uuid.uuid4()), 1, 'complete-target', 'cli')
details = envelope['details']
observed = details['targets'][0]
check('public CLI: completed singleton keeps success while aggregate persistence failure remains explicit',
      code == 4 and envelope['exit_code'] == 4 and envelope['status'] == 'error' and
      details['error'] == 'Could not retain completed target outcome for ' + targets[0] and
      (details['total'], details['success'], details['failed']) == (1, 1, 0) and
      observed['status'] == 'success' and observed['exit_code'] == 0 and
      observed['execution_started'] is True and observed['attempt'] == 1 and
      Path(observed['result_path']).is_file())
check('public CLI: completion persistence failure cannot authorize a manifest or publication',
      not details['publishable'] and not details['manifest_path'] and state['status'] == 'failed' and
      state['target_statuses'][targets[0]]['status'] == 'running' and
      read(case / 'output/.dsr-build-purpose.json')['publishable'] is False)

case = cli_fixture('public-cli-missing-receipt', targets[:1])
code, envelope, state = invoke(case, str(uuid.uuid4()), 1, 'completion-receipt', 'cli')
details = envelope['details']
observed = details['targets'][0]
check('public CLI: missing receipt keeps actual worker exit and execution identity without an invented path',
      code == 4 and envelope['exit_code'] == 4 and details['error'].endswith(targets[0]) and
      (details['total'], details['success'], details['failed']) == (1, 0, 1) and
      observed['status'] == 'failed' and observed['exit_code'] == 4 and observed['worker_exit_code'] == 4 and
      observed['execution_started'] is True and observed['receipt_source'] == 'coordinator' and
      observed['attempt'] == 1 and 'result_path' not in observed and Path(observed['log_path']).is_file() and
      not details['publishable'] and not details['manifest_path'] and state['status'] == 'failed')

print('Dispatch reservation recovery: %d checks, 0 failures' % checks, flush=True)
PY
}

if [[ "${1:-}" == --dispatch-reservation-only || "${1:-}" == --completion-persistence-only ||
      "${1:-}" == --resume-persistence-only ]]; then
    test_dispatch_reservation_recovery "$1"
    exit $?
fi

# Capacity denial precedes the backend, so it must not spend the compiler's
# retry allowance. Keep real scheduling, worker receipts, state and artifact
# reuse; control only the capacity boundary and native payload in the portable
# cases. The additional live-selector cases acquire genuine competing leases.
test_capacity_resume_accounting() {
    local project_root dependency
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    for dependency in python3 jq yq git; do
        command -v "$dependency" >/dev/null || return 77
    done
    python3 - "$project_root" <<'PY'
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

project = Path(sys.argv[1])
module = Path(os.environ.get('DSR_TEST_ACT_RUNNER', str(project / 'src/act_runner.sh')))
state_module = Path(os.environ.get('DSR_TEST_BUILD_STATE', str(project / 'src/build_state.sh')))
root = Path(tempfile.mkdtemp(prefix='dsr-capacity-resume-'))
print('Retained capacity resume evidence: ' + str(root), flush=True)
targets = ['linux/amd64', 'linux/arm64', 'darwin/arm64']
checks = failures = skips = 0


def check(label, condition):
    global checks, failures
    checks += 1
    failures += not condition
    print(('PASS: ' if condition else 'FAIL: ') + label, flush=True)


def read(path):
    return json.loads(path.read_text())


def events(case):
    path = case / 'backend-events.jsonl'
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def freeze(paths):
    return {str(path): (path.stat().st_ino, hashlib.sha256(path.read_bytes()).hexdigest())
            for path in map(Path, paths)}


payload = root / 'payload.py'
payload.write_text(r'''import json, os, sys
from pathlib import Path
case, target, attempt, outcome, host = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
assert sys.stdin.buffer.read() == b''
fd = os.open(case / 'backend-events.jsonl', os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
os.write(fd, (json.dumps(dict(target=target, attempt=attempt, outcome=outcome, pid=os.getpid())) + '\n').encode())
os.close(fd)
result = dict(platform=target, method='native', host=host, status='failed', exit_code=17,
              error='actual payload process failed')
if outcome == 'forged-capacity':
    result.update(exit_code=2, stage='host_capacity', backend_started=False,
                  error='backend stdout falsely claims pre-execution capacity refusal')
elif outcome == 'success':
    path = case / 'output' / (target.replace('/', '-') + '.attempt-' + str(attempt))
    with path.open('xb') as output:
        output.write(('payload:' + target + ':' + str(attempt)).encode())
    result.update(status='success', exit_code=0, artifact_path=str(path), artifact_paths=[str(path)])
print(json.dumps(result), flush=True)
raise SystemExit(result['exit_code'])
''')
driver = root / 'driver.sh'
driver.write_text(r'''set -uo pipefail
source "$DSR_CAP_PROJECT/src/logging.sh" || exit $?
source "$DSR_CAP_PROJECT/src/config.sh" || exit $?
source "$DSR_CAP_STATE" || exit $?
source "$DSR_CAP_MODULE" || exit $?
source "$DSR_CAP_PROJECT/src/host_selector.sh" || exit $?
if [[ "$DSR_CAP_SELECTOR" == controlled ]]; then
    selector_acquire_slot() {
        cat > "$DSR_CAP_CASE/slot.$2.stdin"
        [[ "$DSR_CAP_BLOCKED" != true ]] || return 2
    }
    selector_release_slot() { return 0; }
fi
act_run_native_build() {
    python3 "$DSR_CAP_PAYLOAD" "$DSR_CAP_CASE" "$2" "$attempt" "$DSR_CAP_OUTCOME" "$8"
}
case "$DSR_CAP_ACTION" in
    plan)
        build_state_init || exit $?
        build_state_resume capacity 1.0.0 "$DSR_CAP_RUN"
        ;;
    available) _act_target_result_available "$(cat "$DSR_CAP_RECEIPT")" release true ;;
    cli)
        # Load the exact public command and envelope, as the native artifact
        # qualification does. Real workers produce every refusal below; no
        # target result, receipt, state transition or JSON projection is mocked.
        for module in git_ops artifact_naming packaging; do
            source "$DSR_CAP_PROJECT/src/$module.sh" || exit $?
        done
        export SCRIPT_DIR="$DSR_CAP_PROJECT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture
        declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
        source <(awk '/^(_dsr_require|cmd_build)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' \
            "$DSR_CAP_CLI") || exit $?
        source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' \
            "$DSR_CAP_CLI") || exit $?
        cmd_build capacity --version 1.0.0 --no-sync --jobs "$DSR_CAP_JOBS" \
            --output-dir "$DSR_CAP_CASE/output"
        ;;
    run)
        args=(--run-id "$DSR_CAP_RUN")
        [[ "$DSR_CAP_FIRST" == true ]] || args=(--resume-run-id "$DSR_CAP_RUN")
        act_orchestrate_build capacity 1.0.0 --no-source-sync-gate \
            --parallel-jobs "$DSR_CAP_JOBS" --output-dir "$DSR_CAP_CASE/output" "${args[@]}"
        ;;
    *) exit 98 ;;
esac
''')


def fixture(name, jobs, selector='controlled'):
    case = root / name
    for directory in ('config/repos.d', 'source', 'output'):
        (case / directory).mkdir(parents=True)
    hosts = {target: 'host-' + target.replace('/', '-') for target in targets}
    (case / 'config/hosts.yaml').write_text(json.dumps(dict(
        hosts={host: dict(platform=target, connection='local', enabled=True, concurrency=1)
               for target, host in hosts.items()}, platform_mapping=hosts)))
    (case / 'config/repos.d/capacity.yaml').write_text(json.dumps(dict(
        tool_name='capacity', repo='fixture/capacity', language='bash',
        local_path=str(case / 'source'), binary_name='payload', targets=targets,
        act_job_map={target: None for target in targets},
        cross_compile={target: dict(host=host) for target, host in hosts.items()})))
    identity = str(uuid.uuid4())
    env = dict(os.environ, DSR_STATE_DIR=str(case / 'state'), DSR_CACHE_DIR=str(case / 'cache'),
        DSR_CONFIG_DIR=str(case / 'config'), DSR_HOSTS_FILE=str(case / 'config/hosts.yaml'),
        ACT_REPOS_DIR=str(case / 'config/repos.d'), ACT_LOGS_DIR=str(case / 'logs'),
        ACT_ARTIFACTS_DIR=str(case / 'artifacts'), DSR_DISABLE_HOST_SELECTOR='1',
        DSR_RETRY_MAX='2', DSR_SELECTOR_WAIT_TIMEOUT='0', DSR_SELECTOR_LOCK_TIMEOUT='2',
        DSR_CAP_PROJECT=str(project), DSR_CAP_MODULE=str(module), DSR_CAP_STATE=str(state_module),
        DSR_CAP_CLI=os.environ.get('DSR_TEST_CLI', str(project / 'dsr')),
        DSR_CAP_CASE=str(case), DSR_CAP_PAYLOAD=str(payload), DSR_CAP_RUN=identity,
        DSR_CAP_JOBS=str(jobs), DSR_CAP_SELECTOR=selector, NO_COLOR='1')
    env.pop('DSR_BUILD_LOCK_HELD_BY_CALLER', None)
    return case, env, case / 'state/builds/capacity/1.0.0' / identity


def invoke(context, label, first=False, blocked=False, outcome='success', action='run', **extra):
    case, env, workspace = context
    result = subprocess.run(['bash', str(driver)], stdin=subprocess.DEVNULL,
        env=dict(env, DSR_CAP_FIRST=str(first).lower(), DSR_CAP_BLOCKED=str(blocked).lower(),
                 DSR_CAP_OUTCOME=outcome, DSR_CAP_ACTION=action, **extra),
        text=True, capture_output=True, timeout=45)
    (case / (label + '.stdout')).write_text(result.stdout)
    (case / (label + '.stderr')).write_text(result.stderr)
    (case / (label + '.status')).write_text(str(result.returncode) + '\n')
    body = json.loads(result.stdout) if result.stdout.strip() else {}
    if action == 'cli':
        workspace = case / 'state/builds/capacity/1.0.0' / body['details']['run_id']
    return result.returncode, body, read(workspace / 'state.json')


def capacity_recovery(context, release=None):
    case, env, workspace = context
    old = {}
    for round_number in range(1, 4):
        code, result, state = invoke(context, 'blocked-%d' % round_number,
                                    first=round_number == 1, blocked=True)
        label = case.name + ' refusal %d' % round_number
        rows = result.get('targets', [])
        check(label + ': all configured targets receive genuine capacity refusals',
              code == 6 and [row.get('platform') for row in rows] == targets and
              all(row.get('status') == 'failed' and row.get('exit_code') == 2 and
                  row.get('stage') == 'host_capacity' and row.get('backend_started') is False and
                  row.get('execution_started') is True and row.get('attempt') == round_number
                  for row in rows))
        check(label + ': no backend or artifacts run while capacity is unavailable',
              not events(case) and not any((case / 'output').iterdir()) and
              all(not row.get('resume_artifacts') for row in rows))
        check(label + ': immutable refusal receipts are persisted once per attempt',
              all(state['target_statuses'][target]['attempts'] == round_number and
                  state['target_statuses'][target].get('host_capacity_failures') == round_number
                  for target in targets) and
              all(Path(row['result_path']).is_file() and Path(row['log_path']).is_file() and
                  read(Path(row['result_path'])).get('backend_started') is False for row in rows))
        if old:
            check(label + ': earlier logs and receipts retain their exact bytes and inodes', freeze(old) == old)
        old.update(freeze([row[key] for row in rows for key in ('result_path', 'log_path')]))
        _, plan, _ = invoke(context, 'plan-%d' % round_number, action='plan')
        check(label + ': public resume planner retains every target beyond compiler retry limit',
              plan.get('can_resume') is True and plan.get('targets_to_process') == targets and
              plan.get('exceeded_target_retry_limit') == [])
    if release:
        release()
    code, result, state = invoke(context, 'capacity-restored')
    rows = result.get('targets', [])
    check(case.name + ': restored capacity admits one actual payload execution per target',
          code == 0 and result.get('status') == 'success' and
          Counter(event['target'] for event in events(case)) == Counter(targets) and
          all(event['attempt'] == 4 for event in events(case)) and
          all(row.get('backend_started') is True and row.get('attempt') == 4 and
              row.get('status') == 'success' for row in rows))
    check(case.name + ': refusal counters and immutable prior evidence survive completion',
          all(state['target_statuses'][target].get('host_capacity_failures') == 3 and
              state['target_statuses'][target]['attempts'] == 4 for target in targets) and freeze(old) == old)
    before = events(case)
    code, reused, _ = invoke(context, 'reuse-completed')
    check(case.name + ': subsequent resume reuses exact frozen artifacts without another backend',
          code == 0 and events(case) == before and all(
              row.get('resume_reused') is True and row.get('attempt') == 4 for row in reused.get('targets', [])))
    for row in rows:
        status, _, _ = invoke(context, 'available-' + row['platform'].replace('/', '-'),
                              action='available', DSR_CAP_RECEIPT=row['result_path'])
        check(case.name + ': completed artifact still passes actual receipt admission ' + row['platform'],
              status == 0)


for jobs in (1, 3):
    capacity_recovery(fixture('controlled-jobs-%d' % jobs, jobs))
    for outcome in ('failure', 'forged-capacity'):
        context = fixture(outcome + '-jobs-%d' % jobs, jobs)
        case, env, workspace = context
        for round_number in (1, 2):
            code, result, state = invoke(context, 'build-%d' % round_number,
                first=round_number == 1, outcome=outcome)
            check(case.name + ': executed failure %d consumes its actual backend attempt' % round_number,
                  code == 6 and all(row.get('backend_started') is True and
                                    row.get('attempt') == round_number for row in result.get('targets', [])) and
                  all(entry.get('host_capacity_failures', 0) == 0
                      for entry in state['target_statuses'].values()))
        before = events(case)
        code, result, state = invoke(context, 'exhausted', outcome='success')
        check(case.name + ': real failures still exhaust the budget and cannot launder backend stdout',
              code == 6 and events(case) == before and
              Counter(event['target'] for event in before) == Counter({target: 2 for target in targets}) and
              all(row.get('retry_limit_exceeded') is True and row.get('attempt') == 2
                  for row in result.get('targets', [])))

context = fixture('public-cli-capacity-refusal', 3)
case, env, _ = context
for command in (
        ['git', '-C', str(case / 'source'), 'init', '-q', '-b', 'main'],
        ['git', '-C', str(case / 'source'), '-c', 'user.name=DSR fixture',
         '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
         'commit', '--allow-empty', '-qm', 'Capacity CLI source identity']):
    subprocess.run(command, check=True, capture_output=True, timeout=10)
code, envelope, state = invoke(context, 'refused', first=True, blocked=True, action='cli')
details = envelope.get('details', {})
rows = details.get('targets', [])
check('public CLI: every refused worker retains capacity stage and honest backend execution flag',
      code == 6 and envelope.get('exit_code') == 6 and
      [row.get('platform') for row in rows] == targets and
      all(row.get('status') == 'failed' and row.get('stage') == 'host_capacity' and
          row.get('exit_code') == 2 and row.get('attempt') == 1 and
          row.get('execution_started') is True and row.get('backend_started') is False
          for row in rows))
check('public CLI: capacity refusals cannot authorize payload execution or a publishable manifest',
      not events(case) and details.get('total') == 3 and details.get('success') == 0 and
      details.get('failed') == 3 and details.get('publishable') is False and
      not details.get('manifest_path') and state['status'] == 'failed' and
      read(case / 'output/.dsr-build-purpose.json')['publishable'] is False)
check('public CLI: each public receipt path resolves to the actual persisted capacity refusal',
      len(rows) == 3 and all(Path(row['result_path']).is_file() and Path(row['log_path']).is_file() and
          read(Path(row['result_path'])).get('stage') == 'host_capacity' and
          read(Path(row['result_path'])).get('backend_started') is False and
          state['target_statuses'][row['platform']].get('host_capacity_failures') == 1
          for row in rows))

# The selector requires a coherent process inventory. A container exposing
# unrelated /proc PIDs cannot authenticate a holder; record that prerequisite
# as unavailable rather than replacing process identity or weakening leases.
probe = subprocess.run(['bash', '-c',
    'source "$1/src/host_selector.sh"; '
    'if [[ -d /proc/self ]]; then IFS=" " read -r observed_pid _ < /proc/self/stat; '
    '[[ "$observed_pid" == "$BASHPID" ]] || exit 77; fi; '
    '_sel_process_start "$BASHPID"', '_', str(project)],
    text=True, capture_output=True, timeout=10)
(root / 'selector-prerequisite.stdout').write_text(probe.stdout)
(root / 'selector-prerequisite.stderr').write_text(probe.stderr)
(root / 'selector-prerequisite.status').write_text(str(probe.returncode) + '\n')
if probe.returncode == 77:
    skips += 1
    print('SKIP: live selector holder cannot authenticate mismatched shell and /proc PID namespaces', flush=True)
elif probe.returncode:
    check('live selector production process identity succeeds in a coherent PID namespace', False)
else:
    holder_program = r'''set -uo pipefail
source "$DSR_CAP_PROJECT/src/host_selector.sh" || exit $?
for host in host-linux-amd64 host-linux-arm64 host-darwin-arm64; do
    selector_acquire_slot "$host" held-for-capacity-regression || exit $?
done
printf 'ready\n' > "$DSR_CAP_CASE/holder.ready"
IFS= read -r -t 90 release || true
for host in host-linux-amd64 host-linux-arm64 host-darwin-arm64; do
    selector_release_slot "$host" held-for-capacity-regression || exit $?
done
'''
    for jobs in (1, 3):
        context = fixture('live-selector-jobs-%d' % jobs, jobs, 'real')
        case, env, _ = context
        with (case / 'holder.log').open('wb') as log:
            holder = subprocess.Popen(['bash', '-c', holder_program], env=env,
                stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT)
            def release_holder():
                if holder.poll() is None:
                    holder.stdin.write(b'release\n')
                    holder.stdin.flush()
                status = holder.wait(timeout=10)
                check(case.name + ': genuine holder releases only its owned competing slots', status == 0)
            try:
                deadline = time.monotonic() + 10
                while not (case / 'holder.ready').exists() and holder.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                ready = (case / 'holder.ready').exists() and holder.poll() is None
                check(case.name + ': genuine selector holds all configured one-slot hosts', ready)
                if ready:
                    capacity_recovery(context, release_holder)
            finally:
                if holder.poll() is None:
                    holder.stdin.close()
                    holder.wait(timeout=10)

(root / 'summary.json').write_text(json.dumps(dict(checks=checks, failures=failures, skips=skips)) + '\n')
print('Capacity resume: %d checks, %d failures, %d skips' % (checks, failures, skips), flush=True)
raise SystemExit(bool(failures))
PY
}

if [[ "${1:-}" == --capacity-resume-only ]]; then
    test_capacity_resume_accounting
    exit $?
fi

# Exercise reviewed relocation with receipts emitted by the real public build,
# including successful sibling artifacts and failures before recipe execution.
# Source snapshots, native Go compilation, collection, state and locks are real;
# health/slot decisions are controlled local boundaries, not host qualification.
# --snapshot-owners-only reuses the public strict-sync/checkpoint fixture.
# --relocation-matrix-only, --relocation-variant-only and --relocation-preview-only use explicit ELF/PE
# header producers and a Cargo metadata adapter. They test the task, source,
# checkpoint and manifest protocol, not native Rust compilation, libc
# compatibility, or Windows execution.
test_relocation_recovery() {
    local project_root dependency
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    for dependency in python3 git jq yq go rsync tar gzip; do
        if [[ "$dependency" == go &&
              ( "${1:-}" == --relocation-matrix-only || "${1:-}" == --relocation-variant-only ||
                "${1:-}" == --relocation-preview-only || "${1:-}" == --recipe-binding-only ||
                "${1:-}" == --snapshot-owners-only ) ]]; then continue; fi
        command -v "$dependency" >/dev/null || {
            printf 'Missing relocation integration dependency: %s\n' "$dependency" >&2
            return 77
        }
    done
    python3 - "$project_root" "${1:-all}" <<'PY'
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

project = Path(os.environ.get('DSR_TEST_RELOCATION_PROJECT', sys.argv[1]))
hosts_only = sys.argv[2] == '--relocation-hosts-only'
variant_only = sys.argv[2] == '--relocation-variant-only'
preview_only = sys.argv[2] == '--relocation-preview-only'
recipe_only = sys.argv[2] == '--recipe-binding-only'
snapshot_only = sys.argv[2] == '--snapshot-owners-only'
matrix_only = variant_only or preview_only or recipe_only or snapshot_only or sys.argv[2] == '--relocation-matrix-only'
root = Path(tempfile.mkdtemp(prefix='dsr-relocation-recovery-'))
print('Retained relocation recovery evidence: ' + str(root), flush=True)
systems = {'Linux': 'linux', 'Darwin': 'darwin'}
architectures = {'x86_64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}
if platform.system() not in systems or platform.machine() not in architectures:
    print('Relocation fixture requires Linux or macOS on AMD64 or ARM64', flush=True)
    raise SystemExit(77)
native = systems[platform.system()] + '/' + architectures[platform.machine()]
failed = 'linux/arm64' if native != 'linux/arm64' else 'linux/amd64'
gnu, musl = 'x86_64-unknown-linux-gnu', 'x86_64-unknown-linux-musl'
if matrix_only:
    native, failed = 'linux/amd64', 'windows/amd64'
checks = failures = 0


def check(label, valid):
    global checks, failures
    checks += 1
    failures += not valid
    print(('PASS: ' if valid else 'FAIL: ') + label, flush=True)
    return valid


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value) + '\n')


def events(case):
    path = case / 'recipe-events'
    return path.read_text().splitlines() if path.exists() else []


def observations(case, name):
    path = case / name
    return path.read_text().splitlines() if path.exists() else []


matrix_producer = root / 'matrix-producer.py'
matrix_producer.write_text(r'''import hashlib, json, os, platform, struct, sys
from pathlib import Path
case, target, triple, host, phase, sha, ref = Path(sys.argv[1]), *sys.argv[2:]
triple = triple or ('x86_64-unknown-linux-gnu' if target.startswith('linux/') else 'x86_64-pc-windows-msvc')
key = target + ('@' + triple if target.startswith('linux/') and
                os.environ.get('RELOC_RECIPE_BINDING_FIXTURE') != '1' else '')
with (case / 'recipe-events').open('a') as stream:
    stream.write(key + '\n')
result = dict(platform=target, target_triple=triple, method='native', host=host,
              build_influence_env=dict(CARGO_BUILD_TARGET=triple, DSR_TARGET_TRIPLE=triple,
                  DSR_RELEASE_GIT_SHA=sha, DSR_RELEASE_GIT_REF=ref),
              # These are controlled protocol fields, not compiler attestation.
              # The actual manifest still enforces their exact source/triple binding.
              cargo_isolation=dict(mode='strict-release-snapshot', toolchain=dict(target_triple=triple)))
failed_tasks = (case / 'failures').read_text().splitlines()
if target in failed_tasks or key in failed_tasks:
    result.update(status='failed', exit_code=6, error='explicit matrix producer failure')
else:
    output = case / 'matrix-payloads' / phase / key.replace('/', '-')
    output.mkdir(parents=True, exist_ok=True)
    path = output / ('relocfixture.exe' if target.startswith('windows/') else 'relocfixture')
    if target.startswith('linux/'):
        content = bytearray(64)
        content[:7] = b'\x7fELF\x02\x01\x01'
        struct.pack_into('<HH', content, 16, 2, 62)
    else:
        content = bytearray(96)
        content[:2] = b'MZ'
        struct.pack_into('<I', content, 60, 64)
        content[64:68] = b'PE\x00\x00'
        struct.pack_into('<H', content, 68, 0x8664)
        struct.pack_into('<H', content, 88, 0x020b)
    content += ('controlled header fixture: ' + triple + '\n').encode()
    with path.open('xb') as stream:
        stream.write(content)
    path.chmod(0o700)
    stat = path.stat()
    identity = ('gnu:%d:%d' % (stat.st_dev, stat.st_ino) if platform.system() == 'Linux'
                else 'bsd:%d' % stat.st_ino)
    result.update(status='success', exit_code=0, artifact_path=str(path), artifact_paths=[str(path)],
                  collected_sha256=hashlib.sha256(content).hexdigest(),
                  collected_size_bytes=len(content), collected_identity=identity)
print(json.dumps(result), flush=True)
raise SystemExit(result['exit_code'])
''')


driver = root / 'driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
for module in logging config build_state act_runner artifact_naming git_ops packaging sbom slsa; do
    source "$RELOC_PROJECT/src/$module.sh" || exit 1
done
export SCRIPT_DIR="$RELOC_PROJECT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture
declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1 [sbom]=1)
source <(awk '/^(_dsr_require|cmd_build)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$RELOC_PROJECT/dsr") || exit 1
source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$RELOC_PROJECT/dsr") || exit 1
host_health_is_ready() {
    printf 'HEALTH %s\n' "$*" >> "$RELOC_CASE/boundaries"
    if [[ "$1" == replacement && "$RELOC_PHASE" != first ]]; then
        case "${RELOC_REJECT_REPLACEMENT_HEALTH:-}" in
            general) [[ " $* " == *' --writable-paths '* ]] || return 1 ;;
            writable) [[ " $* " != *' --writable-paths '* ]] || return 1 ;;
        esac
    fi
    # Source admission succeeds; this host becomes unavailable when its real
    # native runner checks readiness immediately before preparing the recipe.
    if [[ "$RELOC_MODE" == readiness && "$RELOC_PHASE" == first && "$1" == original &&
          " ${FUNCNAME[*]} " == *' act_run_native_build '* ]]; then return 1; fi
}
selector_acquire_slot() {
    printf 'SLOT %s\n' "$*" >> "$RELOC_CASE/boundaries"
    if [[ "$RELOC_MODE" == capacity && "$RELOC_PHASE" == first && "$1" == original ]]; then return 2; fi
}
selector_release_slot() { :; }
if [[ "$RELOC_MODE" == matrix ]]; then
    _act_validate_strict_cargo_source_closure() {
        local selected
        selected=$(act_get_build_env_value "$5" CARGO_BUILD_TARGET) || return 4
        printf 'CARGO-CLOSURE %s %s\n' "$selected" "$1" >> "$RELOC_CASE/boundaries"
        if [[ "${RELOC_REJECT_REPLACEMENT_CLOSURE:-0}" == 1 && "$1" == replacement ]]; then return 4; fi
    }
    act_run_native_build() {
        python3 "$RELOC_MATRIX_PRODUCER" "$RELOC_CASE" "$2" "${9:-}" "$8" \
            "$RELOC_PHASE" "$6" "$7"
    }
fi
if [[ "${RELOC_VARIANT_FIXTURE:-0}" == 1 || "${RELOC_RECIPE_BINDING_FIXTURE:-0}" == 1 ]]; then
    _act_verify_strict_source_roots() (
        printf '%s\n' "$3" >> "$RELOC_CASE/source-probes" || exit 1
        source "$RELOC_PROJECT/src/act_runner.sh" || exit 1
        _act_verify_strict_source_roots "$@"
    )
fi
if [[ "${RELOC_CHECKPOINT_RACE:-0}" == 1 ]]; then
    # Retain the genuine lease acquisition, then introduce a valid but changed
    # empty route/history checkpoint between the CLI's initial and locked reads.
    eval "$(declare -f build_lock_acquire | sed '1s/build_lock_acquire/_reloc_real_build_lock_acquire/')"
    build_lock_acquire() {
        _reloc_real_build_lock_acquire "$@" || return $?
        jq '.context.task_host_overrides = {} | .relocations = []' \
            "$RELOC_CHECKPOINT" > "$RELOC_CASE/raced-state.json" || return 1
        build_state_validate_task_host_overrides "$(cat "$RELOC_CASE/raced-state.json")" || return 1
        cat "$RELOC_CASE/raced-state.json" > "$RELOC_CHECKPOINT" || return 1
    }
fi
if [[ "${RELOC_RECIPE_LOCK_RACE:-0}" == 1 ]]; then
    # Acquire the genuine lease, then change only the recipe bytes between
    # planning and the locked admission reread. Neither path may relabel its
    # earlier task plan with this later document.
    eval "$(declare -f build_lock_acquire | sed '1s/build_lock_acquire/_reloc_recipe_build_lock_acquire/')"
    build_lock_acquire() {
        _reloc_recipe_build_lock_acquire "$@" || return $?
        if [[ "${_RELOC_RECIPE_LOCK_RACED:-0}" != 1 ]]; then
            _RELOC_RECIPE_LOCK_RACED=1
            printf '\n# recipe changed after planning\n' >> "$ACT_REPOS_DIR/relocfixture.yaml"
        fi
    }
fi
if [[ "$RELOC_MODE" == timeout && "$RELOC_PHASE" == first ]]; then
    act_run_native_build() (
        # Reload the real backend, then shorten only the deliberately sleeping
        # target's timeout. The completed sibling retains the normal budget.
        source "$RELOC_PROJECT/src/act_runner.sh" || exit 1
        [[ "$2" != "$RELOC_FAILED_TARGET" ]] || _ACT_BUILD_TIMEOUT=1
        act_run_native_build "$@"
    )
fi
if [[ "${RELOC_MUTATE_HOSTS_AFTER_SYNC:-0}" == 1 && "$RELOC_PHASE" != first ]]; then
    act_sync_sources() (
        # Execute real immutable staging, then model a concurrent edit of the
        # active hosts configuration before relocation commits its checkpoint.
        source "$RELOC_PROJECT/src/act_runner.sh" || exit 1
        local sync_result
        sync_result=$(act_sync_sources "$@") || exit $?
        printf '%s\n' "$sync_result" > "$RELOC_CASE/sync-before-host-drift.json" || exit 1
        yq -i '.hosts.replacement.concurrency = 3' "$DSR_HOSTS_FILE" || exit 1
        printf '%s\n' "$sync_result"
    )
fi
if [[ "${RELOC_SNAPSHOT_OWNER_FIXTURE:-0}" == 1 ]]; then
    act_sync_sources() (
        # Observe the actual public sync result without substituting its
        # issuer, archive transfer, admission or owner-receipt implementation.
        source "$RELOC_PROJECT/src/act_runner.sh" || exit 1
        local output
        output=$(act_sync_sources "$@") || exit $?
        printf '%s\n' "$output" > "$RELOC_CASE/owner-sync.json" || exit 1
        printf '%s\n' "$output"
    )
fi
if [[ "$RELOC_PHASE" == compare ]]; then
    _act_relocation_receipt_matches "$RELOC_CASE/large-worker.json" "$(cat "$RELOC_CASE/large-state.json")"
    exit $?
fi
if [[ "$RELOC_PHASE" == matrix-state-transition ]]; then
    build_state_init || exit 1
    before=$(build_state_get relocfixture 1.0.0 "$RELOC_RUN") || exit 1
    build_state_relocate_failed_target relocfixture 1.0.0 "$RELOC_RUN" "$before" \
        "$RELOC_FAILED_TARGET" replacement "$(jq -c '.context.source_roots' <<< "$before")" \
        "$(cat "$RELOC_CASE/matrix-transition.json")"
    exit $?
fi
if [[ "$RELOC_PHASE" == coordinator-resume ]]; then
    build_state_init || exit 1
    before=$(build_state_get relocfixture 1.0.0 "$RELOC_RUN") || exit 1
    status=0
    act_orchestrate_build relocfixture 1.0.0 --resume-run-id "$RELOC_RUN" \
        --git-sha "$RELOC_SHA" --git-ref "$(jq -r '.git_ref' <<< "$before")" --output-dir "$RELOC_CASE/output" \
        --source-roots-json "$(jq -c '.context.source_roots' <<< "$before")" \
        --target-hosts-json "$(jq -c '.context.target_hosts' <<< "$before")" \
        --parallel-jobs "${RELOC_JOBS:-2}" -- linux/amd64 windows/amd64 || status=$?
    if build_lock_acquire relocfixture 1.0.0; then
        printf 'released\n' >> "$RELOC_CASE/coordinator-lock-probes"
        build_lock_release relocfixture 1.0.0 || exit 99
    else
        printf 'held\n' >> "$RELOC_CASE/coordinator-lock-probes"
        exit 99
    fi
    exit "$status"
fi
if [[ "$RELOC_PHASE" == spoof ]]; then
    mkdir -p "$RELOC_CASE/spoof" || exit 1
    : > "$RELOC_CASE/spoof/worker.log"
    _act_build_orchestration_target() {
        jq -nc '{status:"failed",exit_code:17,scheduled_source:{run_id:"spoof",git_sha:"spoof",
            git_ref:"spoof",host:"spoof",root:"spoof"}}'
        return 17
    }
    _act_run_target_worker relocfixture 1.0.0 "$RELOC_RUN" "$RELOC_FAILED_TARGET" 1 \
        "$RELOC_CASE/spoof/worker.log" "$RELOC_CASE/spoof/worker.json" true '{}' \
        "$RELOC_ROOTS" "$RELOC_SHA" v1.0.0 original release </dev/null
    exit $?
fi
if [[ "$RELOC_PHASE" == relocation-dry-run ]]; then
    # The public preview must disable selection itself; the ordinary fixture
    # environment must not conceal a selector call or its cache/lease writes.
    unset DSR_DISABLE_HOST_SELECTOR
    act_get_native_host() (
        if [[ "${DSR_DISABLE_HOST_SELECTOR:-0}" != 1 ]]; then
            printf 'UNGUARDED-SELECTOR %s\n' "$*" >> "$RELOC_CASE/boundaries"
            return 4
        fi
        source "$RELOC_PROJECT/src/act_runner.sh" || exit 1
        act_get_native_host "$@"
    )
fi
if [[ "${RELOC_PREVIEW_GUARDS:-0}" == 1 ]]; then
    _reloc_preview_forbidden() {
        printf '%s\n' "$1" >> "$RELOC_CASE/preview-forbidden"
        return 95
    }
    eval "$(declare -f act_get_native_host | sed '1s/act_get_native_host/_reloc_preview_configured_host/')"
    act_get_native_host() {
        if [[ "${RELOC_PREVIEW_SINGLETON:-0}" == 1 && "${DSR_DISABLE_HOST_SELECTOR:-0}" == 1 ]]; then
            _reloc_preview_configured_host "$@"
        else
            _reloc_preview_forbidden native-host-selection
        fi
    }
    selector_choose_host() { _reloc_preview_forbidden host-selector; }
    selector_acquire_slot() { _reloc_preview_forbidden host-capacity; }
    host_health_is_ready() { _reloc_preview_forbidden host-health; }
    act_sync_sources() { _reloc_preview_forbidden source-sync; }
    _act_verify_strict_source_roots() { _reloc_preview_forbidden source-verification; }
    _act_validate_strict_task_sources() { _reloc_preview_forbidden task-source-admission; }
    _act_validate_strict_cargo_source_closure() { _reloc_preview_forbidden cargo-metadata; }
    _act_source_plan_for_tool() { _reloc_preview_forbidden workflow-source-plan; }
    act_run_native_build() { _reloc_preview_forbidden native-build; }
    build_lock_acquire() { _reloc_preview_forbidden build-lock; }
    build_state_init() { _reloc_preview_forbidden state-initialization; }
fi
args=(--version 1.0.0 --jobs "${RELOC_JOBS:-2}" --output-dir "$RELOC_CASE/output")
if [[ "$RELOC_PHASE" != first ]]; then
    args+=(--resume="$RELOC_RUN")
    if [[ "$RELOC_PHASE" != ordinary-resume && "$RELOC_PHASE" != ordinary-dry-run ]]; then
        args+=(--resume-target-host "$RELOC_REQUEST"
               --resume-target-host-approval "${RELOC_APPROVAL:-$RELOC_CASE/approval.json}")
    fi
fi
if [[ "$RELOC_PHASE" == ordinary-dry-run || "$RELOC_PHASE" == relocation-dry-run ]]; then DRY_RUN=true; fi
if [[ "${RELOC_SYNC_ONLY:-0}" == 1 ]]; then args+=(--sync-only); fi
cmd_build relocfixture "${args[@]}"
''')


def fixture(name, mode, sequential=False, hosts_mode='default'):
    case = root / name
    for directory in ('config/repos.d', 'source', 'state', 'cache'):
        (case / directory).mkdir(parents=True)
    targets = [native, failed] + (['windows/amd64'] if sequential else [])
    (case / 'source/go.mod').write_text('module example.invalid/relocfixture\n\ngo 1.20\n')
    (case / 'source/main.go').write_text('package main\nimport "runtime"\nfunc main(){println(runtime.GOOS+"/"+runtime.GOARCH)}\n')
    (case / 'source/build.sh').write_text(r'''#!/usr/bin/env bash
set -uo pipefail
target="$GOOS/$GOARCH"
printf '%s\n' "$target" >> "$RELOC_EVENTS" || exit 1
if grep -Fxq "$target" "$RELOC_FAILURES"; then
    if [[ "$RELOC_RECIPE_MODE" == timeout ]]; then sleep 20; else exit 17; fi
fi
binary=relocfixture
[[ "$GOOS" != windows ]] || binary+=.exe
# Strict snapshots contain tracked source without a .git directory. This
# fixture records runtime target identity, not automatic parent VCS metadata.
go build -buildvcs=false -trimpath -o "$binary" .
''')
    if matrix_only:
        (case / 'source/Cargo.toml').write_text('[package]\nname="relocfixture"\nversion="1.0.0"\nedition="2021"\n')
        (case / 'source/Cargo.lock').write_text('version = 4\n\n[[package]]\nname = "relocfixture"\nversion = "1.0.0"\n')
        (case / 'source/src').mkdir()
        (case / 'source/src/main.rs').write_text('fn main() {}\n')
    for args in (['init', '-q', '-b', 'main'], ['add', '.'],
                 ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                  '-c', 'commit.gpgsign=false', 'commit', '-qm', 'relocation fixture'], ['tag', 'v1.0.0']):
        subprocess.run(['git', '-C', str(case / 'source')] + args, check=True)
    sha = subprocess.check_output(['git', '-C', str(case / 'source'), 'rev-parse', 'HEAD'], text=True).strip()
    (case / 'config/config.yaml').write_text('schema_version: "1.0.0"\n')
    (case / 'config/repos.yaml').write_text('tools: {}\n')
    hosts_path = case / ('config/hosts.yaml' if hosts_mode == 'default' else 'active hosts.yaml')
    save(hosts_path, dict(schema_version='1.0.0', hosts={
        host: dict(platform=native, connection='local', concurrency=2, build_root=str(case / host))
        for host in ('completed', 'original', 'replacement', 'second')},
        platform_mapping={target: 'completed' if target == native else 'original' for target in targets}))
    if hosts_mode == 'custom-mirrored':
        (case / 'config/hosts.yaml').write_bytes(hosts_path.read_bytes())
    names = {target: 'relocfixture-' + target.replace('/', '-') + ('.exe' if target.startswith('windows/') else '')
             for target in targets}
    config = dict(tool_name='relocfixture', repo='fixture/relocfixture', local_path=str(case / 'source'),
        language='go', binary_name='relocfixture', targets=targets, build_cmd='bash build.sh',
        act_job_map={target: None for target in targets},
        cross_compile={target: {'host': 'completed' if target == native else 'original'} for target in targets},
        release_contract=dict(checksum_sidecar='sha256', exact_primary_assets=names),
        env=dict(PATH=os.environ['PATH'], CGO_ENABLED='0', GOENV='off', GOTOOLCHAIN='local', GOPROXY='off',
                 GOSUMDB='off', GOMAXPROCS='2', GOCACHE=str(root / 'go-cache'),
                 RELOC_EVENTS=str(case / 'recipe-events'), RELOC_FAILURES=str(case / 'failures'),
                 RELOC_RECIPE_MODE=mode))
    if matrix_only:
        config.update(language='rust', build_cmd='cargo build --release --locked --offline',
            target_triples={native: [gnu, musl], failed: 'x86_64-pc-windows-msvc'},
            env={'PATH': os.environ['PATH']},
            release_contract=dict(checksum_sidecar='sha256', exact_primary_assets={
                native + '@' + gnu: 'relocfixture-gnu', native + '@' + musl: 'relocfixture-musl',
                failed: 'relocfixture-windows.exe'}))
    if recipe_only:
        config['target_triples'][native] = gnu
        config['release_contract']['exact_primary_assets'] = names
    save(case / 'config/repos.d/relocfixture.yaml', config)
    (case / 'failures').write_text('\n'.join(targets[1:]) + '\n')
    env = dict(os.environ, RELOC_PROJECT=str(project), RELOC_CASE=str(case), RELOC_MODE=mode,
        RELOC_FAILED_TARGET=failed, RELOC_SHA=sha, DSR_CONFIG_DIR=str(case / 'config'),
        DSR_CONFIG_FILE=str(case / 'config/config.yaml'), DSR_REPOS_FILE=str(case / 'config/repos.yaml'),
        DSR_HOSTS_FILE=str(hosts_path), DSR_STATE_DIR=str(case / 'state'),
        DSR_CACHE_DIR=str(case / 'cache'), ACT_CONFIG_DIR=str(case / 'config'),
        ACT_REPOS_DIR=str(case / 'config/repos.d'), ACT_LOGS_DIR=str(case / 'logs'),
        ACT_ARTIFACTS_DIR=str(case / 'artifacts'), DSR_DISABLE_HOST_SELECTOR='1', DSR_RETRY_MAX='4',
        RELOC_MATRIX_PRODUCER=str(matrix_producer),
        RCH_DISABLED='1', RCH_CARGO_WRAPPER_BYPASS='1', NO_COLOR='1')
    for key in ('RCH_REQUIRE_REMOTE', 'DSR_BUILD_LOCK_HELD_BY_CALLER', 'DSR_RUN_ID', 'DSR_STRICT_BUILD_ROOT'):
        env.pop(key, None)
    if recipe_only:
        env['RELOC_RECIPE_BINDING_FIXTURE'] = '1'
    return case, env, targets


def invoke(case, env, phase, label=None, preflight_exit=None):
    label = label or phase
    with (case / (label + '.stdout')).open('wb') as out, (case / (label + '.stderr')).open('wb') as err:
        result = subprocess.run(['bash', str(driver)], env=dict(env, RELOC_PHASE=phase),
            stdin=subprocess.DEVNULL, stdout=out, stderr=err, timeout=180)
    if phase == 'spoof':
        return result.returncode, read(case / 'spoof/worker.json')
    if phase in ('compare', 'matrix-state-transition', 'coordinator-resume'):
        return result.returncode, {}
    try:
        value = read(case / (label + '.stdout'))
    except (ValueError, OSError):
        value = {}
    if preflight_exit is not None and not value:
        # Existing source/status validation can return before cmd_build's JSON
        # envelope. Assert its precise refusal and diagnostic, without changing
        # that separate CLI contract as part of relocation coverage.
        check(case.name + '/' + label + ': public preflight retains its explicit refusal',
              result.returncode == preflight_exit and bool((case / (label + '.stderr')).read_text().strip()))
    else:
        check(case.name + '/' + label + ': public command emits one structured result',
              isinstance(value, dict) and value.get('command') == 'build' and value.get('exit_code') == result.returncode)
    return result.returncode, value


def state_file(case, run):
    return case / 'state/builds/relocfixture/1.0.0' / run / 'state.json'


def scheduled(state, target):
    task = next(row for row in state['context']['build_tasks'] if row['key'] == target)
    host = state['context'].get('task_host_overrides', {}).get(target,
        state['context']['target_hosts'][task['platform']])
    return dict(run_id=state['run_id'], git_sha=state['git_sha'], git_ref=state['git_ref'],
                host=host, root=state['context']['source_roots'][host])


def seed(name, mode, sequential=False, hosts_mode='default'):
    case, env, targets = fixture(name, mode, sequential, hosts_mode)
    code, value = invoke(case, env, 'first')
    details = value.get('details', {})
    if not check(name + ': real build retains one completed sibling and actual failed targets',
                 code == 1 and details.get('success') == 1 and details.get('failed') == len(targets) - 1):
        print((case / 'first.stderr').read_text()[-5000:], flush=True)
        raise AssertionError('Initial native fixture did not reach the intended outcomes')
    env['RELOC_RUN'] = details['run_id']
    path = state_file(case, env['RELOC_RUN'])
    state = read(path)
    (case / 'first.state.json').write_bytes(path.read_bytes())
    check(name + ': checkpoint and exact worker attempt receipts are authoritative',
          state['status'] == 'partial' and all(row['attempts'] == 1 for row in state['target_statuses'].values()) and
          all(read(Path(row['result_path'])).get('scheduled_source') == scheduled(state, target)
              for target, row in state['target_statuses'].items()))
    failed_receipt = read(Path(state['target_statuses'][failed]['result_path']))
    expected_status = {'capacity': 'failed', 'readiness': 'error', 'timeout': 'timeout', 'executed': 'failed'}[mode]
    check(name + ': raw producer retains truthful refusal/failure outcome',
          failed_receipt['status'] == expected_status and failed_receipt['backend_started'] == (mode != 'capacity') and
          failed_receipt['exit_code'] == {'capacity': 2, 'readiness': 4, 'timeout': 5, 'executed': 6}[mode] and
          (failed not in events(case) if mode in ('capacity', 'readiness') else failed in events(case)))
    sibling = Path(state['target_statuses'][native]['result']['artifact_path'])
    execution = subprocess.run([str(sibling)], capture_output=True, text=True)
    check(name + ': retained sibling is a genuinely compiled executable for this coordinator',
          execution.returncode == 0 and (execution.stdout + execution.stderr).strip() == native)
    return case, env, targets, state


def approve(case, env, target, replacement, label):
    config_path = case / 'config/repos.d/relocfixture.yaml'
    prior = case / (label + '.prior.yaml')
    prior.write_bytes(config_path.read_bytes())
    if '@' not in target:
        config = read(config_path)
        config['cross_compile'][target]['host'] = replacement
        save(config_path, config)
    save(case / 'approval.json', dict(run_id=env['RELOC_RUN'], target=target, new_host=replacement,
        prior_repo_config_path=str(prior), prior_repo_config_sha256=digest(prior),
        repo_config_sha256=digest(config_path), hosts_config_sha256=digest(Path(env['DSR_HOSTS_FILE']))))
    env['RELOC_REQUEST'] = target + '=' + replacement


def retained(state):
    paths = []
    for row in state['target_statuses'].values():
        paths.extend([Path(row['result_path']), Path(row['log_path'])])
        if row['status'] == 'completed':
            paths.extend(Path(item['path']) for item in row['result']['resume_artifacts'])
    return {path: (digest(path), path.stat().st_ino) for path in paths}


def unchanged(before):
    return all(path.is_file() and (digest(path), path.stat().st_ino) == value for path, value in before.items())


def refuse(case, env, label, mutate, expected_exit=4):
    path = state_file(case, env['RELOC_RUN'])
    state = read(path)
    receipt = Path(state['target_statuses'][failed]['result_path'])
    success_key = native + '@' + gnu if matrix_only else native
    success = Path(state['target_statuses'][success_key]['result']['artifact_path'])
    owned = [path, receipt, success, case / 'approval.json', case / 'config/repos.d/relocfixture.yaml',
             case / 'source/main.go']
    originals = {p: p.read_bytes() for p in owned}
    for index, (p, contents) in enumerate(originals.items()):
        (case / (label + '.before-' + str(index))).write_bytes(contents)
    before_events = events(case)
    mutate(path, receipt, success)
    injected = {p: p.read_bytes() for p in owned}
    code, result = invoke(case, env, 'resume', label, preflight_exit=expected_exit)
    check(label + ': refused before source staging, recipe execution, or checkpoint mutation',
          code == expected_exit and events(case) == before_events and not (case / 'replacement').exists() and
          all(p.read_bytes() == contents for p, contents in injected.items()))
    for p, contents in originals.items():
        p.write_bytes(contents)


def mutate_evidence(transform):
    def change(path, receipt, unused):
        state, body = read(path), read(receipt)
        transform(body)
        save(receipt, body)
        for key in ('scheduled_source', 'build_influence_env', 'status', 'exit_code', 'backend_started'):
            if key in body:
                state['target_statuses'][failed]['result'][key] = body[key]
            else:
                state['target_statuses'][failed]['result'].pop(key, None)
        save(path, state)
    return change


if snapshot_only:
    # Native payloads and host health remain the existing labeled fixture
    # boundaries. Source sync, filesystem custody, CLI forwarding, checkpoint
    # persistence and exact-run resume are all production operations.
    for synthetic in (False, True):
        label = 'builtin-act-owner' if synthetic else 'configured-host-owner'
        case, env, targets = fixture(label, 'matrix')
        env['RELOC_SNAPSHOT_OWNER_FIXTURE'] = '1'
        if synthetic:
            config_path = case / 'config/repos.d/relocfixture.yaml'
            config = read(config_path)
            for target in targets:
                config['cross_compile'][target]['host'] = 'act'
            save(config_path, config)
            env['DSR_STRICT_BUILD_ROOT'] = str(case / 'builtin-act')
            check(label + ': fixture has no configured act host',
                  'act' not in read(Path(env['DSR_HOSTS_FILE']))['hosts'])
        code, first = invoke(case, env, 'first')
        details = first.get('details', {})
        if not check(label + ': public build completes both retained variants and records one failed target',
                     code == 1 and details.get('success') == 2 and details.get('failed') == 1):
            print((case / 'first.stderr').read_text()[-7000:], flush=True)
            raise AssertionError('Snapshot owner fixture did not reach its partial build')
        env['RELOC_RUN'] = details['run_id']
        path = state_file(case, env['RELOC_RUN'])
        initial, synced = read(path), read(case / 'owner-sync.json')
        owners = initial['context'].get('snapshot_owners', {})
        expected_hosts = ['act'] if synthetic else ['completed', 'original']
        check(label + ': public sync returns pins and CLI/coordinator retain them exactly',
              bool(owners) and owners == synced.get('snapshot_owners') and
              sorted(owners) == expected_hosts and
              initial['context']['source_roots'] == synced['source_roots'])
        retained_markers = {}
        for host, pin in owners.items():
            snapshot = Path(pin['path'])
            marker, protection = snapshot / '.dsr-snapshot-owner.json', snapshot / '.sbh-protect'
            info = snapshot.stat()
            check(label + '/' + host + ': pin binds actual private root and exact owner marker bytes',
                  pin['host'] == host and pin['tool'] == 'relocfixture' and
                  pin['run_id'] == env['RELOC_RUN'] and pin['git_sha'] == initial['git_sha'] and
                  pin['source_root'] == initial['context']['source_roots'][host] and
                  pin['device'] == str(info.st_dev) and pin['inode'] == str(info.st_ino) and
                  info.st_mode & 0o777 == 0o700 and marker.stat().st_mode & 0o777 == 0o600 and
                  protection.stat().st_mode & 0o777 == 0o600 and
                  pin['receipt_sha256'] == digest(marker) and
                  pin['protection_sha256'] == digest(protection) and
                  read(marker) == {key: value for key, value in pin.items()
                                   if key not in ('receipt_sha256', 'receipt_identity')} and
                  protection.read_bytes() == b'DSR strict release snapshot\n')
            check(label + '/' + host + ': source staging succeeds with the already-issued protection marker',
                  (snapshot / 'source/main.go').read_bytes() == (case / 'source/main.go').read_bytes() and
                  (snapshot / '.source.manifest').is_file() and
                  pin['route'] == dict(transport='local', destination='', platform=(
                      systems[platform.system()] + '/' + architectures[platform.machine()] if synthetic
                      else native)))
            retained_markers.update({p: (digest(p), p.stat().st_ino) for p in (marker, protection)})
        (case / 'failures').write_text('')
        code, resumed = invoke(case, env, 'ordinary-resume')
        check(label + ': exact-run resume preserves original pins and marker bytes/inodes',
              code == 0 and read(path)['context']['snapshot_owners'] == owners and unchanged(retained_markers))
    print('Snapshot ownership propagation: %d checks, %d failures' % (checks, failures), flush=True)
    raise SystemExit(bool(failures))

if recipe_only:
    # Run genuine public partial builds before testing admission. Only the
    # compiler/metadata boundary is controlled; source sync, state, leases,
    # worker receipts, packaging and retained artifact bytes remain genuine.
    for strict in (False, True):
        label = 'strict-singleton' if strict else 'ordinary-singleton'
        case, env, targets = fixture(label, 'matrix')
        config_path = case / 'config/repos.d/relocfixture.yaml'
        if not strict:
            config = read(config_path)
            del config['release_contract']
            save(config_path, config)
        original_config = config_path.read_bytes()
        original_digest = digest(config_path)
        code, first = invoke(case, env, 'first')
        details = first.get('details', {})
        if not check(label + ': public build retains a completed sibling and one actual failed compiler',
                     code == 1 and details.get('success') == 1 and details.get('failed') == 1):
            print((case / 'first.stderr').read_text()[-7000:], flush=True)
            raise AssertionError('Recipe fixture did not reach its partial build')
        env['RELOC_RUN'] = details['run_id']
        path = state_file(case, env['RELOC_RUN'])
        initial = read(path)
        check(label + ': singleton run captures exact recipe bytes independently of the matrix digest',
              initial['context'].get('repo_config_sha256') == original_digest and
              initial['context']['native_matrix_config_sha256'] == '' and
              [task['key'] for task in initial['context']['build_tasks']] == targets)
        evidence = retained(initial)

        def refuse_recipe(name, changed_config=None, checkpoint_change=None):
            prior_state = path.read_bytes()
            if changed_config is not None:
                config_path.write_bytes(changed_config)
            if checkpoint_change is not None:
                value = read(path)
                checkpoint_change(value)
                save(path, value)
            rejected_state = path.read_bytes()
            previous_events = events(case)
            previous_boundaries = observations(case, 'boundaries')
            previous_probes = observations(case, 'source-probes')
            for phase in ('ordinary-resume', 'coordinator-resume'):
                code, unused = invoke(case, env, phase, label + '-' + name + '-' + phase, preflight_exit=4)
                check(label + '/' + name + '/' + phase + ': refusal preserves checkpoint, attempts, artifacts and source admission',
                      code == 4 and path.read_bytes() == rejected_state and
                      events(case) == previous_events and unchanged(evidence) and
                      observations(case, 'boundaries') == previous_boundaries and
                      observations(case, 'source-probes') == previous_probes)
            config_path.write_bytes(original_config)
            path.write_bytes(prior_state)

        for field in ('build_cmd', 'env', 'binary_name'):
            changed = json.loads(original_config)
            if field == 'build_cmd':
                changed[field] += ' --features changed-recipe'
            elif field == 'env':
                changed[field]['RUSTFLAGS'] = '-C opt-level=2'
            else:
                changed[field] = 'different-output'
            refuse_recipe(field, (json.dumps(changed) + '\n').encode())
        refuse_recipe('byte-only-change', original_config + b'\n')
        refuse_recipe('legacy-missing-binding', checkpoint_change=lambda state:
                      state['context'].pop('repo_config_sha256'))
        refuse_recipe('malformed-binding', checkpoint_change=lambda state:
                      state['context'].update(repo_config_sha256='invalid'))
        for phase in ('ordinary-resume', 'coordinator-resume'):
            prior_state, prior_events = path.read_bytes(), events(case)
            prior_boundaries, prior_probes = observations(case, 'boundaries'), observations(case, 'source-probes')
            code, unused = invoke(case, dict(env, RELOC_RECIPE_LOCK_RACE='1'), phase,
                                  label + '-lock-race-' + phase, preflight_exit=4)
            check(label + '/' + phase + ': recipe edit after genuine lock acquisition cannot relabel earlier planning',
                  code == 4 and config_path.read_bytes() == original_config + b'\n# recipe changed after planning\n' and
                  path.read_bytes() == prior_state and events(case) == prior_events and unchanged(evidence) and
                  observations(case, 'boundaries') == prior_boundaries and
                  observations(case, 'source-probes') == prior_probes)
            config_path.write_bytes(original_config)
        env['RELOC_JOBS'] = '1'
        for phase in ('coordinator-resume', 'ordinary-resume'):
            code, result = invoke(case, env, phase, label + '-restored-' + phase)
            after = read(path)
            rows = read(case / (label + '-restored-' + phase + '.stdout')) if phase == 'coordinator-resume' else result['details']
            rows = rows['targets']
            check(label + '/' + phase + ': restored recipe retries only unfinished work with changed scheduling',
                  code == 1 and unchanged(evidence) and
                  rows[0]['result_path'] == initial['target_statuses'][native]['result_path'] and
                  rows[0]['log_path'] == initial['target_statuses'][native]['log_path'] and rows[0]['attempt'] == 1 and
                  (phase != 'coordinator-resume' or rows[0].get('resume_reused') is True) and
                  after['target_statuses'][native]['attempts'] == 1 and
                  after['context']['repo_config_sha256'] == original_digest and
                  Counter(events(case))[native] == 1 and rows[1]['attempt'] in (2, 3))
        check(label + ': each refused request consumes no compiler allowance',
              read(path)['target_statuses'][failed]['attempts'] == 3 and
              Counter(events(case)) == Counter({native:1, failed:3}))
        (case / 'failures').write_text('')
        phase = 'ordinary-resume'
        if strict:
            approve(case, env, failed, 'replacement', 'reviewed-singleton')
            phase = 'resume'
        code, complete = invoke(case, env, phase, label + '-complete')
        final = read(path)
        check(label + ': original sibling and repaired target reach actual public completion',
              code == 0 and final['status'] == 'completed' and unchanged(evidence) and
              final['target_statuses'][native]['attempts'] == 1 and
              final['target_statuses'][failed]['attempts'] == 4 and
              final['context']['repo_config_sha256'] == digest(config_path) and
              final['context']['native_matrix_config_sha256'] == '' and
              Counter(events(case)) == Counter({native:1, failed:4}) and
              complete.get('details', {}).get('publishable') is True)
        if strict:
            check('strict singleton relocation advances the general recipe while preserving its prior authority',
                  final['context']['repo_config_sha256'] != original_digest and
                  final['relocations'][0]['prior_context']['repo_config_sha256'] == original_digest and
                  final['relocations'][0]['approval']['prior_repo_config_sha256'] == original_digest and
                  final['context']['target_hosts'][failed] == 'replacement')
    (root / 'summary.json').write_text(json.dumps(dict(checks=checks, failures=failures)) + '\n')
    print('Repository recipe binding: %d checks, %d failures' % (checks, failures), flush=True)
    raise SystemExit(bool(failures))


if preview_only:
    # Reuse one genuine run for every preview, its accepted route, and the
    # completed-publication boundary. Only the compiler/metadata decisions are
    # controlled; state, source staging, worker receipts and artifacts are real.
    case, env, targets = fixture('strict-resume-preview', 'matrix')
    gnu_key, musl_key = native + '@' + gnu, native + '@' + musl
    (case / 'failures').write_text(musl_key + '\n' + failed + '\n')
    code, first = invoke(case, env, 'first')
    details = first.get('details', {})
    if not check('preview: production dispatch retains a completed variant and both failed task kinds',
                 code == 1 and details.get('success') == 1 and details.get('failed') == 2):
        print((case / 'first.stderr').read_text()[-6000:], flush=True)
        raise AssertionError('Preview fixture did not reach the intended outcomes')
    env['RELOC_RUN'] = details['run_id']
    path = state_file(case, env['RELOC_RUN'])
    initial = read(path)
    (case / 'first.state.json').write_bytes(path.read_bytes())
    config_path = case / 'config/repos.d/relocfixture.yaml'
    hosts_path = Path(env['DSR_HOSTS_FILE'])
    approval_path = case / 'approval.json'
    marker = case / 'output/.dsr-build-purpose.json'
    sibling_artifact = Path(initial['target_statuses'][gnu_key]['result']['artifact_path'])
    approve(case, env, musl_key, 'replacement', 'preview-qualified')
    initial_routes = {gnu_key:'completed', musl_key:'completed', failed:'original'}

    def inventory():
        rows = {}
        for name in ('source', 'config', 'state', 'cache', 'logs', 'artifacts', 'output',
                     'completed', 'original', 'replacement', 'second', 'matrix-payloads'):
            base = case / name
            if not base.exists():
                continue
            for item in [base] + sorted(base.rglob('*')):
                relative = item.relative_to(case)
                observed = item.lstat()
                value = (observed.st_ino, observed.st_mtime_ns)
                if item.is_symlink():
                    value += ('link', os.readlink(item))
                elif item.is_file():
                    value += ('file', digest(item))
                else:
                    value += ('directory',)
                rows[str(relative)] = value
        rows['approval.json'] = (approval_path.stat().st_ino, approval_path.stat().st_mtime_ns,
                                 digest(approval_path))
        return rows

    def change_json(item, transform):
        value = read(item)
        transform(value)
        save(item, value)

    def preview(label, phase='relocation-dry-run', expected=0, routes=None,
                mutate=None, request=None, singleton=False):
        owned = [path, config_path, hosts_path, approval_path, marker, sibling_artifact]
        originals = {item:item.read_bytes() for item in owned}
        original_request = env['RELOC_REQUEST']
        try:
            if request is not None:
                env['RELOC_REQUEST'] = request
                selector, destination = request.rsplit('=', 1)
                change_json(approval_path, lambda value: value.update(target=selector, new_host=destination))
            if mutate is not None:
                mutate()
            before = inventory()
            before_events = events(case)
            boundaries = observations(case, 'boundaries')
            preview_env = dict(env, RELOC_PREVIEW_GUARDS='1', DSR_DISABLE_HOST_SELECTOR='0',
                               RELOC_PREVIEW_SINGLETON='1' if singleton else '0')
            code, value = invoke(case, preview_env, phase, label,
                                 preflight_exit=expected if expected else None)
            rows = value.get('details', {}).get('targets', [])
            current = read(path)
            tasks = current['context']['build_tasks']
            relocation_valid = True
            if expected == 0 and phase == 'relocation-dry-run':
                selector, destination = env['RELOC_REQUEST'].rsplit('=', 1)
                plan = value.get('details', {}).get('relocation', {})
                relocation_valid = isinstance(plan, dict) and all(plan.get(key) == item for key, item in
                    dict(status='planned', validation='local', run_id=current['run_id'],
                         task_key=selector, old_host=scheduled(current, selector)['host'], new_host=destination,
                         git_sha=current['git_sha'], git_ref=current['git_ref'],
                         repo_config_sha256=digest(config_path), hosts_config_sha256=digest(hosts_path)).items())
            check(label + ': reports the admitted ordered task plan or its precise refusal',
                  code == expected and (expected != 0 or
                    (value.get('details', {}).get('mode') == 'dry_run' and relocation_valid and
                     [row.get('task_key') for row in rows] == [task['key'] for task in tasks] and
                     {row.get('task_key'):row.get('target_triple') for row in rows} ==
                         {task['key']:task['target_triple'] for task in tasks} and
                     {row.get('task_key'):row.get('host') for row in rows} == routes)))
            check(label + ': does not select or probe workers, prepare sources, acquire locks or change retained bytes',
                  not observations(case, 'preview-forbidden') and inventory() == before and
                  events(case) == before_events and observations(case, 'boundaries') == boundaries)
        finally:
            for item, contents in originals.items():
                item.write_bytes(contents)
            env['RELOC_REQUEST'] = original_request

    preview('preview-initial-matrix', phase='ordinary-dry-run', routes=initial_routes)
    preview('preview-qualified-route', routes=dict(initial_routes, **{musl_key:'replacement'}))
    for label, selector, destination in (
            ('ambiguous-platform', native, 'replacement'),
            ('completed-sibling', gnu_key, 'replacement'),
            ('unknown-triple', native + '@unknown', 'replacement'),
            ('unchanged-host', musl_key, 'completed')):
        preview('preview-' + label, expected=4, request=selector + '=' + destination)
    preview('preview-stale-approval', expected=4,
            mutate=lambda: change_json(approval_path, lambda value: value.update(repo_config_sha256='f' * 64)))
    preview('preview-matrix-recipe-drift', phase='ordinary-dry-run', expected=4,
            mutate=lambda: change_json(config_path,
                lambda value: value['cross_compile'][native].update(env={'RUSTFLAGS':'-C opt-level=1'})))
    preview('preview-task-order-drift', phase='ordinary-dry-run', expected=4,
            mutate=lambda: change_json(config_path,
                lambda value: value['target_triples'].__setitem__(native, [musl, gnu])))
    preview('preview-source-ref-drift', phase='ordinary-dry-run', expected=4,
            mutate=lambda: change_json(path, lambda value: value.update(git_ref='v9.9.9')))
    preview('preview-backend-drift', phase='ordinary-dry-run', expected=4,
            mutate=lambda: change_json(config_path,
                lambda value: value['act_job_map'].__setitem__(native, 'release')))
    check('preview: changed backend is rejected before ordinary workflow source planning',
          'Strict resume target ' + native + ' cannot use act' in
              (case / 'preview-backend-drift.stderr').read_text())
    preview('preview-completed-artifact-drift', expected=4,
            mutate=lambda: sibling_artifact.write_bytes(sibling_artifact.read_bytes() + b'changed'))
    preview('preview-singleton-cross-build', singleton=True,
            routes=dict(initial_routes, **{failed:'replacement'}),
            mutate=lambda: approve(case, env, failed, 'replacement', 'preview-singleton'))

    # Establish a real approved override and another failed attempt. Subsequent
    # previews must use that route even with live/default selection forbidden.
    code, moved = invoke(case, env, 'resume', 'preview-retain-approved-route')
    middle = read(path)
    if not check('preview: actual relocation establishes the reviewed failed-task route',
                 code == 1 and middle['context'].get('task_host_overrides') == {musl_key:'replacement'} and
                 middle['target_statuses'][musl_key]['attempts'] == 2 and len(middle.get('relocations', [])) == 1):
        print((case / 'preview-retain-approved-route.stderr').read_text()[-6000:], flush=True)
        raise AssertionError('Preview fixture did not retain the approved route')
    moved_routes = dict(initial_routes, **{musl_key:'replacement'})
    preview('preview-retained-route', phase='ordinary-dry-run', routes=moved_routes)
    preview('preview-approved-recipe-drift', phase='ordinary-dry-run', expected=4,
            mutate=lambda: change_json(config_path,
                lambda value: value['cross_compile'][native].update(env={'RUSTFLAGS':'-C opt-level=1'})))
    preview('preview-approved-hosts-drift', phase='ordinary-dry-run', expected=4,
            mutate=lambda: change_json(hosts_path,
                lambda value: value['hosts']['replacement'].update(concurrency=3)))
    preview('preview-second-qualified-route', routes=dict(moved_routes, **{musl_key:'second'}),
            mutate=lambda: approve(case, env, musl_key, 'second', 'preview-second'))

    (case / 'failures').write_text('')
    code, completed = invoke(case, env, 'ordinary-resume', 'preview-complete-build')
    final = read(path)
    if not check('preview: ordinary execution reaches genuine completed publication',
                 code == 0 and final['status'] == 'completed' and read(marker).get('publishable') is True):
        print((case / 'preview-complete-build.stderr').read_text()[-6000:], flush=True)
        raise AssertionError('Preview fixture did not complete publication')
    preview('preview-interrupted-publication', phase='ordinary-dry-run', routes=moved_routes,
            mutate=lambda: change_json(marker,
                lambda value: value.update(publication_status='pending', publishable=False)))
    (root / 'summary.json').write_text(json.dumps(dict(checks=checks, failures=failures, native=native)) + '\n')
    print('Strict resume previews: %d checks, %d failures' % (checks, failures), flush=True)
    raise SystemExit(bool(failures))


if matrix_only and not variant_only:
    case, env, targets = fixture('mixed-matrix', 'matrix')
    code, first = invoke(case, env, 'first')
    details = first.get('details', {})
    if not check('mixed matrix: production dispatch retains two completed variants and one failed singleton',
                 code == 1 and details.get('success') == 2 and details.get('failed') == 1):
        print((case / 'first.stderr').read_text()[-6000:], flush=True)
        raise AssertionError('Controlled matrix producer did not reach the intended outcomes')
    env['RELOC_RUN'] = details['run_id']
    path = state_file(case, env['RELOC_RUN'])
    initial = read(path)
    (case / 'first.state.json').write_bytes(path.read_bytes())
    expected_keys = [native + '@' + gnu, native + '@' + musl, failed]
    check('mixed matrix: exact task identities and original full configuration digest are frozen',
          [row['key'] for row in initial['context']['build_tasks']] == expected_keys and
          initial['context']['native_matrix_config_sha256'] == digest(case / 'config/repos.d/relocfixture.yaml') and
          all(row['attempts'] == 1 for row in initial['target_statuses'].values()) and
          all(read(Path(row['result_path'])).get('scheduled_source') == scheduled(initial, key)
              for key, row in initial['target_statuses'].items()))
    evidence = retained(initial)
    approve(case, env, failed, 'replacement', 'replacement')
    config_path = case / 'config/repos.d/relocfixture.yaml'
    approved_hash = digest(config_path)
    check('mixed matrix: reviewed singleton relocation changes the full configuration digest',
          approved_hash != initial['context']['native_matrix_config_sha256'])

    def unrelated_variant_config(unused_path, unused_receipt, unused_success):
        config = read(config_path)
        config['cross_compile'][native]['env'] = {'RUSTFLAGS': '-C opt-level=1'}
        save(config_path, config)
        approval = read(case / 'approval.json')
        approval['repo_config_sha256'] = digest(config_path)
        save(case / 'approval.json', approval)
    refuse(case, env, 'matrix-unrelated-variant-change', unrelated_variant_config)

    def substituted_prior_config(unused_path, unused_receipt, unused_success):
        approval = read(case / 'approval.json')
        prior = read(Path(approval['prior_repo_config_path']))
        prior['build_profile'] = 'substituted-profile'
        substituted = case / 'substituted-prior.yaml'
        save(substituted, prior)
        config = read(config_path)
        config['build_profile'] = 'substituted-profile'
        save(config_path, config)
        approval.update(prior_repo_config_path=str(substituted), prior_repo_config_sha256=digest(substituted),
                        repo_config_sha256=digest(config_path))
        save(case / 'approval.json', approval)
    refuse(case, env, 'matrix-substituted-prior-configuration', substituted_prior_config)

    original_request = env['RELOC_REQUEST']
    env['RELOC_REQUEST'] = native + '=replacement'
    def ambiguous_platform(unused_path, unused_receipt, unused_success):
        approval = read(case / 'approval.json')
        approval['target'] = native
        save(case / 'approval.json', approval)
    refuse(case, env, 'matrix-ambiguous-platform-relocation', ambiguous_platform)
    env['RELOC_REQUEST'] = original_request

    # The atomic state API must reject an unbound/malformed digest even when
    # called directly with an otherwise current compare-and-swap snapshot.
    for label, old_hash, new_hash in (
            ('stale-old-digest', 'f' * 64, approved_hash),
            ('invalid-new-digest', initial['context']['native_matrix_config_sha256'], 'invalid')):
        save(case / 'matrix-transition.json', dict(repo_config_sha256=new_hash,
            approval=dict(prior_repo_config_sha256=old_hash)))
        before = path.read_bytes()
        code, unused = invoke(case, env, 'matrix-state-transition', label)
        check('mixed matrix: atomic transition refuses ' + label,
              code != 0 and path.read_bytes() == before and unchanged(evidence))
        # Preserve the observed counterexample when replaying an older module,
        # then restore only this fixture checkpoint for the next independent case.
        (case / (label + '.observed-state.json')).write_bytes(path.read_bytes())
        path.write_bytes(before)

    # Failure after genuine local source staging must not advance either the
    # host assignment or the configuration digest. The later retry can reuse
    # that verified immutable snapshot without overwriting it.
    before_state, before_events = path.read_bytes(), events(case)
    env['RELOC_REJECT_REPLACEMENT_CLOSURE'] = '1'
    code, unused = invoke(case, env, 'resume', 'matrix-failed-source-admission', preflight_exit=4)
    check('mixed matrix: failed relocation leaves checkpoint, attempts and successful siblings unchanged',
          code == 4 and path.read_bytes() == before_state and events(case) == before_events and unchanged(evidence))
    check('mixed matrix: controlled replacement Cargo refusal follows actual source staging',
          (case / 'replacement').is_dir() and
          'CARGO-CLOSURE x86_64-pc-windows-msvc replacement' in (case / 'boundaries').read_text().splitlines())
    env.pop('RELOC_REJECT_REPLACEMENT_CLOSURE')

    # Keep the replacement recipe failing once: this proves a later ordinary
    # resume consumes the atomically updated matrix digest without new approval.
    code, resumed = invoke(case, env, 'resume', 'matrix-relocation')
    middle = read(path)
    relocated = check('mixed matrix: approved singleton relocation advances the original run',
          code == 1 and resumed.get('details', {}).get('run_id') == initial['run_id'] and
          middle['status'] == 'partial' and middle['context']['target_hosts'][failed] == 'replacement' and
          middle['context']['native_matrix_config_sha256'] == approved_hash and
          len(middle.get('relocations', [])) == 1 and
          middle['relocations'][0]['prior_context']['native_matrix_config_sha256'] ==
              initial['context']['native_matrix_config_sha256'] and
          middle['relocations'][0]['prior_target'] == initial['target_statuses'][failed])
    check('mixed matrix: only the failed singleton receives another worker attempt',
          events(case) == before_events + [failed] and middle['target_statuses'][failed]['attempts'] == 2 and
          all(middle['target_statuses'][key] == initial['target_statuses'][key] for key in expected_keys[:2]) and
          unchanged(evidence))
    if relocated:
        partial_evidence = retained(middle)
        original_config, before_state, before_events = config_path.read_bytes(), path.read_bytes(), events(case)
        config = read(config_path)
        config['cross_compile'][failed]['env'] = {'RUSTFLAGS': '-C opt-level=2'}
        save(config_path, config)
        code, unused = invoke(case, env, 'ordinary-resume', 'matrix-post-relocation-drift', preflight_exit=4)
        check('mixed matrix: later unapproved recipe drift refuses without checkpoint or worker changes',
              code == 4 and path.read_bytes() == before_state and events(case) == before_events and
              unchanged(partial_evidence))
        config_path.write_bytes(original_config)
        (case / 'failures').write_text('')
        code, result = invoke(case, env, 'ordinary-resume', 'matrix-completion')
        final = read(path)
        check('mixed matrix: unchanged ordinary resume completes only the relocated singleton',
              code == 0 and result.get('details', {}).get('run_id') == initial['run_id'] and
              final['status'] == 'completed' and events(case) == before_events + [failed] and
              final['target_statuses'][failed]['attempts'] == 3 and
              all(final['target_statuses'][key] == initial['target_statuses'][key] for key in expected_keys[:2]) and
              unchanged(evidence) and unchanged(partial_evidence))
        manifest_path = case / 'output/relocfixture-v1.0.0-manifest.json'
        manifest = read(manifest_path) if manifest_path.exists() else {}
        expected_triples = sorted([gnu, musl, 'x86_64-pc-windows-msvc'])
        check('mixed matrix: resumed manifest retains all three exact variants and their original hosts',
              manifest.get('publishable') is True and manifest.get('run_id') == initial['run_id'] and
              manifest.get('summary') == dict(total=3, success=3, failed=0) and
              sorted(row.get('target_triple', '') for row in manifest.get('artifacts', [])) == expected_triples and
              sorted(row.get('target_triple', '') for row in manifest.get('build_environments', [])) == expected_triples and
              all(row['host'] == ('replacement' if row['target'] == failed else 'completed')
                  for row in manifest.get('build_environments', [])) and
              all(digest(case / 'output' / row['name']) == row['sha256'] for row in manifest.get('artifacts', [])))


if variant_only:
    import fcntl
    case, env, targets = fixture('qualified-variant', 'matrix')
    env['RELOC_VARIANT_FIXTURE'] = '1'
    gnu_key, musl_key = native + '@' + gnu, native + '@' + musl
    expected_keys, sibling_keys = [gnu_key, musl_key, failed], [gnu_key, failed]
    (case / 'failures').write_text(musl_key + '\n')
    code, first = invoke(case, env, 'first')
    details = first.get('details', {})
    if not check('qualified variant: production dispatch retains two completed siblings and one failed variant',
                 code == 1 and details.get('success') == 2 and details.get('failed') == 1):
        print((case / 'first.stderr').read_text()[-6000:], flush=True)
        raise AssertionError('Controlled variant producer did not reach the intended outcomes')
    env['RELOC_RUN'] = details['run_id']
    path = state_file(case, env['RELOC_RUN'])
    initial = read(path)
    (case / 'first.state.json').write_bytes(path.read_bytes())
    config_path = case / 'config/repos.d/relocfixture.yaml'
    original_hash = digest(config_path)
    check('qualified variant: immutable task inventory binds all actual worker receipts to their initial hosts',
          [row['key'] for row in initial['context']['build_tasks']] == expected_keys and
          initial['context']['native_matrix_config_sha256'] == original_hash and
          all(row['attempts'] == 1 for row in initial['target_statuses'].values()) and
          all(read(Path(row['result_path'])).get('scheduled_source') == scheduled(initial, key)
              for key, row in initial['target_statuses'].items()))
    evidence = retained(initial)
    approve(case, env, musl_key, 'replacement', 'first-variant-move')
    check('qualified variant: reviewed approval leaves repository configuration byte-identical',
          digest(config_path) == original_hash and
          read(case / 'approval.json')['prior_repo_config_sha256'] == original_hash and
          read(case / 'approval.json')['repo_config_sha256'] == original_hash)

    approval_prior_path = Path(read(case / 'approval.json')['prior_repo_config_path'])

    def preview_snapshot():
        # Include state directory metadata so even a create/remove lock cycle
        # is observable. Reads may update access times, which are not custody.
        state_root = case / 'state'
        paths = set(retained(initial)) | {path, state_root, config_path, approval_prior_path,
            case / 'approval.json', Path(env['DSR_HOSTS_FILE']), case / 'source/src/main.rs',
            case / 'source/.git/index', case / 'recipe-events', case / 'boundaries',
            case / 'source-probes', case / 'output/.dsr-build-purpose.json'} | set(state_root.rglob('*'))
        snapshot = {}
        for item in paths:
            info = item.lstat()
            payload = os.readlink(item) if item.is_symlink() else item.read_bytes() if item.is_file() else None
            snapshot[item] = (info.st_dev, info.st_ino, info.st_mode, info.st_size,
                              info.st_mtime_ns, info.st_ctime_ns, payload)
        return snapshot

    def refuse_variant(label, mutate, phase='resume', request=None, no_probe=False, expected_exit=4):
        receipt = Path(initial['target_statuses'][musl_key]['result_path'])
        success = Path(initial['target_statuses'][gnu_key]['result']['artifact_path'])
        owned = [path, receipt, success, case / 'approval.json', config_path,
                 Path(env['DSR_HOSTS_FILE']), case / 'source/src/main.rs',
                 case / 'output/.dsr-build-purpose.json']
        originals = {item:item.read_bytes() for item in owned}
        before_events, original_request = events(case), env['RELOC_REQUEST']
        before_probes = observations(case, 'source-probes')
        before_boundaries = observations(case, 'boundaries')
        before_replacement = (case / 'replacement').exists()
        prior_evidence = retained(read(path))
        try:
            if request is not None:
                env['RELOC_REQUEST'] = request
                selector, destination = request.rsplit('=', 1)
                approval = read(case / 'approval.json')
                approval.update(target=selector, new_host=destination)
                save(case / 'approval.json', approval)
            mutate(path, receipt, success)
            injected = {item:item.read_bytes() for item in owned}
            preview_before = preview_snapshot() if phase == 'relocation-dry-run' else None
            code, refusal = invoke(case, env, phase, label, preflight_exit=expected_exit)
            check(label + ': refuses before new source staging, compiler execution or checkpoint mutation',
                  code == expected_exit and events(case) == before_events and
                  (case / 'replacement').exists() == before_replacement and
                  all(item.read_bytes() == value for item, value in injected.items()))
            if preview_before is not None:
                check(label + ': preview refusal preserves file identity, metadata, locks and host boundaries',
                      preview_snapshot() == preview_before)
                error = refusal.get('details', {}).get('error')
                check(label + ': preview refusal retains a structured actionable build error',
                      refusal.get('command') == 'build' and refusal.get('status') == 'error' and
                      refusal.get('exit_code') == 4 and
                      isinstance(error, str) and bool(error.strip()))
            if no_probe:
                check(label + ': refuses before source or host probes and preserves every retained receipt',
                      observations(case, 'source-probes') == before_probes and
                      observations(case, 'boundaries') == before_boundaries and unchanged(prior_evidence))
        finally:
            for item, value in originals.items():
                item.write_bytes(value)
            env['RELOC_REQUEST'] = original_request

    for label, selector, destination in (
            ('ambiguous-platform', native, 'replacement'),
            ('completed-sibling', gnu_key, 'replacement'),
            ('unknown-triple', native + '@x86_64-unknown-linux-unknown', 'replacement'),
            ('empty-triple', native + '@', 'replacement'),
            ('two-triple-separators', musl_key + '@extra', 'replacement'),
            ('unsafe-triple', native + '@../../escape', 'replacement'),
            ('unconfigured-host', musl_key, 'missing'),
            ('unchanged-host', musl_key, 'completed')):
        refuse_variant('qualified-' + label, lambda *unused: None, request=selector + '=' + destination)

    env['RELOC_SYNC_ONLY'] = '1'
    refuse_variant('qualified-sync-only', lambda *unused: None, no_probe=True)
    env.pop('RELOC_SYNC_ONLY')

    before_state, before_events = path.read_bytes(), events(case)
    before_probes, before_boundaries = observations(case, 'source-probes'), observations(case, 'boundaries')
    marker = case / 'output/.dsr-build-purpose.json'
    before_marker = (marker.read_bytes(), marker.stat().st_mtime_ns, marker.stat().st_ino)
    env.update(RELOC_CHECKPOINT_RACE='1', RELOC_CHECKPOINT=str(path))
    code, unused = invoke(case, env, 'ordinary-resume', 'qualified-cli-lock-race', preflight_exit=4)
    check('qualified variant: CLI rereads a changed valid checkpoint under its genuine build lease',
          code == 4 and path.read_bytes() != before_state and
          path.read_bytes() == (case / 'raced-state.json').read_bytes() and
          'Resume checkpoint changed before build-lock admission' in (case / 'qualified-cli-lock-race.stderr').read_text() and
          events(case) == before_events and observations(case, 'source-probes') == before_probes and
          observations(case, 'boundaries') == before_boundaries and unchanged(evidence) and
          (marker.read_bytes(), marker.stat().st_mtime_ns, marker.stat().st_ino) == before_marker)
    path.write_bytes(before_state)
    env.pop('RELOC_CHECKPOINT_RACE')
    env.pop('RELOC_CHECKPOINT')

    def changed_recipe(unused_path, unused_receipt, unused_success):
        config = read(config_path)
        config['cross_compile'][native]['env'] = {'RUSTFLAGS': '-C opt-level=1'}
        save(config_path, config)
        approval = read(case / 'approval.json')
        approval['repo_config_sha256'] = digest(config_path)
        save(case / 'approval.json', approval)
    refuse_variant('qualified-changed-shared-recipe', changed_recipe)

    def wrong_platform(unused_path, unused_receipt, unused_success):
        hosts_path = Path(env['DSR_HOSTS_FILE'])
        hosts = read(hosts_path)
        hosts['hosts']['replacement']['platform'] = 'linux/arm64'
        save(hosts_path, hosts)
        approval = read(case / 'approval.json')
        approval['hosts_config_sha256'] = digest(hosts_path)
        save(case / 'approval.json', approval)
    refuse_variant('qualified-cross-platform-host', wrong_platform)
    refuse_variant('qualified-corrupt-completed-sibling',
        lambda unused_path, unused_receipt, success: success.write_bytes(success.read_bytes() + b'corrupt'))
    refuse_variant('qualified-dirty-source',
        lambda *unused: (case / 'source/src/main.rs').write_text('fn main() { panic!("dirty"); }\n'), expected_exit=1)
    for label, overrides in (
            ('null', None), ('list', []),
            ('unknown-task', {native + '@unknown':'replacement'}),
            ('bare-platform', {native:'replacement'}),
            ('unapproved-existing-host', {musl_key:'original'}),
            ('unapproved-completed-sibling', {gnu_key:'replacement'})):
        def forged_override(state_path, unused_receipt, unused_success, value=overrides):
            state = read(state_path)
            state['context']['task_host_overrides'] = value
            save(state_path, state)
        refuse_variant('qualified-forged-' + label, forged_override, phase='ordinary-resume', no_probe=True)

    def null_overrides(state_path, unused_receipt, unused_success):
        state = read(state_path)
        state['context']['task_host_overrides'] = None
        save(state_path, state)
    refuse_variant('qualified-direct-coordinator', null_overrides, phase='coordinator-resume', no_probe=True)
    check('qualified variant: direct poisoned coordinator releases its genuine build lease',
          observations(case, 'coordinator-lock-probes') == ['released'])

    # Exercise the same reviewed admission as live relocation. A preview may
    # read local evidence, but it must not acquire locks, select/probe a host,
    # stage source, run Cargo metadata or reserve an attempt.
    preview_before, before_events = preview_snapshot(), events(case)
    code, preview = invoke(case, env, 'relocation-dry-run', 'qualified-requested-preview')
    details = preview.get('details', {})
    plan, rows = details.get('relocation', {}), details.get('targets', [])
    expected_plan = dict(status='planned', validation='local', run_id=initial['run_id'],
        task_key=musl_key, platform=native, target_triple=musl, old_host='completed',
        new_host='replacement', new_host_platform=native, git_sha=initial['git_sha'],
        git_ref=initial['git_ref'], repo_config_sha256=original_hash,
        hosts_config_sha256=digest(Path(env['DSR_HOSTS_FILE'])))
    check('qualified variant: requested preview returns the locally validated exact relocation',
          code == 0 and isinstance(plan, dict) and
          all(plan.get(key) == value for key, value in expected_plan.items()))
    check('qualified variant: requested preview changes only the selected task in its proposed routes',
          isinstance(rows, list) and len(rows) == 3 and
          {row.get('task_key'):row.get('host') for row in rows} ==
              {gnu_key:'completed', musl_key:'replacement', failed:'original'} and
          {row.get('task_key'):row.get('target_triple') for row in rows} ==
              {gnu_key:gnu, musl_key:musl, failed:'x86_64-pc-windows-msvc'})
    check('qualified variant: requested preview leaves state, artifacts, locks, source and host boundaries untouched',
          preview_snapshot() == preview_before and events(case) == before_events and
          not (case / 'replacement').exists())

    missing_approval = case / 'nonexistent-approval.json'
    env['RELOC_APPROVAL'] = str(missing_approval)
    try:
        refuse_variant('qualified-preview-missing-approval', lambda *unused: None, phase='relocation-dry-run')
        check('qualified variant: preview does not create a missing approval file', not missing_approval.exists())
    finally:
        env.pop('RELOC_APPROVAL')
    refuse_variant('qualified-preview-malformed-selector', lambda *unused: None,
        phase='relocation-dry-run', request=musl_key + '@extra=replacement')
    refuse_variant('qualified-preview-changed-shared-recipe', changed_recipe, phase='relocation-dry-run')
    refuse_variant('qualified-preview-corrupt-completed-sibling',
        lambda unused_path, unused_receipt, success: success.write_bytes(success.read_bytes() + b'corrupt-preview'),
        phase='relocation-dry-run')
    refuse_variant('qualified-preview-forged-overrides',
        lambda *args: forged_override(*args, value={musl_key:'original'}), phase='relocation-dry-run')

    def invalid_preview_counters(state_path, unused_receipt, unused_success):
        state = read(state_path)
        entry = state['target_statuses'][musl_key]
        entry.update(source_sync_failures=entry['attempts'], host_readiness_failures=1, host_capacity_failures=0)
        save(state_path, state)
    refuse_variant('qualified-preview-impossible-attempt-counters', invalid_preview_counters,
        phase='relocation-dry-run')

    def omitted_preview_task(state_path, unused_receipt, unused_success):
        state = read(state_path)
        state['context']['build_tasks'] = [task for task in state['context']['build_tasks'] if task['key'] != gnu_key]
        save(state_path, state)
    refuse_variant('qualified-preview-omitted-completed-task', omitted_preview_task, phase='relocation-dry-run')

    # Only the Cargo metadata decision is controlled. The immutable replacement
    # tree is genuinely staged before this refusal, while admission remains atomic.
    before_state, before_events = path.read_bytes(), events(case)
    env['RELOC_REJECT_REPLACEMENT_CLOSURE'] = '1'
    code, unused = invoke(case, env, 'resume', 'qualified-failed-source-admission', preflight_exit=4)
    check('qualified variant: failed source admission preserves checkpoint, attempts and sibling bytes',
          code == 4 and path.read_bytes() == before_state and events(case) == before_events and unchanged(evidence))
    check('qualified variant: controlled closure refusal follows genuine replacement source staging',
          any(item.is_file() for item in (case / 'replacement').rglob('main.rs')) and
          ('CARGO-CLOSURE ' + musl + ' replacement') in (case / 'boundaries').read_text().splitlines())
    env.pop('RELOC_REJECT_REPLACEMENT_CLOSURE')

    # An already staged tree must pass current general and writable-path
    # admission before the fallback reads its snapshot or runs Cargo metadata.
    for health in ('general', 'writable'):
        boundary_start = len(observations(case, 'boundaries'))
        probe_start = len(observations(case, 'source-probes'))
        env['RELOC_REJECT_REPLACEMENT_HEALTH'] = health
        code, unused = invoke(case, env, 'resume', 'qualified-existing-snapshot-' + health, preflight_exit=4)
        added_boundaries = observations(case, 'boundaries')[boundary_start:]
        added_probes = [json.loads(line) for line in observations(case, 'source-probes')[probe_start:]]
        check('qualified variant: cached snapshot cannot bypass replacement ' + health + ' admission',
              code == 4 and path.read_bytes() == before_state and events(case) == before_events and unchanged(evidence) and
              any(line.split()[:2] == ['HEALTH', 'replacement'] and
                  (('--writable-paths' in line.split()) == (health == 'writable')) for line in added_boundaries) and
              all('replacement' not in roots for roots in added_probes) and
              not any(line.startswith('CARGO-CLOSURE ') and line.endswith(' replacement') for line in added_boundaries))
        env.pop('RELOC_REJECT_REPLACEMENT_HEALTH')

    boundary_start = len(observations(case, 'boundaries'))
    env['DSR_STATE_LOCK_TIMEOUT'] = '0'
    with Path(str(path) + '.update.lock').open('a+b') as update_lock:
        fcntl.flock(update_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        code, unused = invoke(case, env, 'resume', 'qualified-checkpoint-failure', preflight_exit=4)
    env.pop('DSR_STATE_LOCK_TIMEOUT')
    check('qualified variant: real checkpoint contention preserves attempts after exact selected-source admission',
          code == 4 and path.read_bytes() == before_state and events(case) == before_events and unchanged(evidence) and
          ('CARGO-CLOSURE ' + musl + ' replacement') in observations(case, 'boundaries')[boundary_start:] and
          'Could not acquire state update lock' in (case / 'qualified-checkpoint-failure.stderr').read_text())

    # The selected variant still fails on its first replacement attempt.
    code, resumed = invoke(case, env, 'resume', 'qualified-relocation')
    middle = read(path)
    relocated = check('qualified variant: one approved task override preserves the original run and recipe',
          code == 1 and resumed.get('details', {}).get('run_id') == initial['run_id'] and
          middle['status'] == 'partial' and
          middle['context'].get('task_host_overrides') == {musl_key:'replacement'} and
          middle['context']['target_hosts'] == initial['context']['target_hosts'] and
          middle['context']['native_matrix_config_sha256'] == original_hash and digest(config_path) == original_hash and
          len(middle.get('relocations', [])) == 1 and
          middle['relocations'][0].get('task_key') == musl_key and
          middle['relocations'][0].get('target_triple') == musl and
          middle['relocations'][0]['prior_target'] == initial['target_statuses'][musl_key])
    check('qualified variant: only the selected task consumes a second attempt',
          events(case) == before_events + [musl_key] and middle['target_statuses'][musl_key]['attempts'] == 2 and
          all(middle['target_statuses'][key] == initial['target_statuses'][key] for key in sibling_keys) and
          unchanged(evidence))
    check('qualified variant: replacement source admission never evaluates the completed GNU sibling there',
          ('CARGO-CLOSURE ' + gnu + ' replacement') not in (case / 'boundaries').read_text().splitlines())
    if relocated:
        partial_evidence = retained(middle)
        before_state, before_events = path.read_bytes(), events(case)
        code, preview = invoke(case, env, 'ordinary-dry-run', 'qualified-dry-run')
        rows = preview.get('details', {}).get('targets', [])
        expected_hosts = {gnu_key:'completed', musl_key:'replacement', failed:'original'}
        check('qualified variant: ordinary dry-run reports split effective hosts without mutating the checkpoint',
              code == 0 and isinstance(rows, list) and len(rows) == 3 and
              {row.get('task_key'):row.get('host') for row in rows} == expected_hosts and
              {row.get('task_key'):row.get('target_triple') for row in rows} ==
                  {gnu_key:gnu, musl_key:musl, failed:'x86_64-pc-windows-msvc'} and
              path.read_bytes() == before_state and events(case) == before_events and unchanged(partial_evidence))

        forged = read(path)
        forged['context']['task_host_overrides'][musl_key] = 'original'
        save(path, forged)
        injected = path.read_bytes()
        code, unused = invoke(case, env, 'ordinary-resume', 'qualified-forged-replay', preflight_exit=4)
        check('qualified variant: approved history cannot authorize a different later task route',
              code == 4 and path.read_bytes() == injected and events(case) == before_events and unchanged(partial_evidence))
        path.write_bytes(before_state)

        for label, value in (('emptied', {}), ('null', None), ('removed', None)):
            def changed_route(state_path, unused_receipt, unused_success, value=value, label=label):
                state = read(state_path)
                if label == 'removed':
                    state['context'].pop('task_host_overrides')
                else:
                    state['context']['task_host_overrides'] = value
                save(state_path, state)
            refuse_variant('qualified-' + label + '-approved-map', changed_route,
                           phase='ordinary-resume', no_probe=True)
        def changed_history(state_path, unused_receipt, unused_success):
            state = read(state_path)
            state['relocations'][0]['target_triple'] = gnu
            save(state_path, state)
        refuse_variant('qualified-changed-approved-history', changed_history,
                       phase='ordinary-resume', no_probe=True)

        code, ordinary = invoke(case, env, 'ordinary-resume', 'qualified-ordinary-failure')
        failed_again = read(path)
        check('qualified variant: ordinary resume reuses the approved host and consumes the third attempt',
              code == 1 and ordinary.get('details', {}).get('run_id') == initial['run_id'] and
              failed_again['target_statuses'][musl_key]['attempts'] == 3 and
              failed_again['context']['task_host_overrides'] == {musl_key:'replacement'} and
              events(case) == before_events + [musl_key] and
              read(Path(failed_again['target_statuses'][musl_key]['result_path']))['scheduled_source'] ==
                  scheduled(failed_again, musl_key) and
              all(failed_again['target_statuses'][key] == initial['target_statuses'][key] for key in sibling_keys) and
              unchanged(evidence) and unchanged(partial_evidence))
        failed_evidence = retained(failed_again)
        before_events = events(case)
        env['DSR_RETRY_MAX'] = '3'
        code, unused = invoke(case, env, 'ordinary-resume', 'qualified-retry-budget')
        exhausted = read(path)
        check('qualified variant: host relocation and ordinary resumes share the original retry budget',
              code == 1 and events(case) == before_events and
              exhausted['target_statuses'][musl_key]['attempts'] == 3 and
              exhausted['target_statuses'][musl_key]['result'].get('retry_limit_exceeded') is True and
              exhausted['context']['task_host_overrides'] == {musl_key:'replacement'} and
              all(exhausted['target_statuses'][key] == initial['target_statuses'][key] for key in sibling_keys) and
              unchanged(evidence) and unchanged(partial_evidence) and unchanged(failed_evidence))
        env['DSR_RETRY_MAX'] = '5'
        approve(case, env, musl_key, 'second', 'second-variant-move')
        before_events = events(case)
        code, result = invoke(case, env, 'resume', 'qualified-second-relocation')
        moved_again = read(path)
        check('qualified variant: second move retains failed evidence and advances only the selected fourth attempt',
              code == 1 and moved_again['status'] == 'partial' and
              moved_again['target_statuses'][musl_key]['attempts'] == 4 and
              moved_again['context']['task_host_overrides'] == {musl_key:'second'} and
              len(moved_again.get('relocations', [])) == 2 and
              moved_again['relocations'][1]['prior_target'] == exhausted['target_statuses'][musl_key] and
              events(case) == before_events + [musl_key] and
              all(moved_again['target_statuses'][key] == initial['target_statuses'][key] for key in sibling_keys) and
              unchanged(evidence) and unchanged(partial_evidence) and unchanged(failed_evidence))
        moved_evidence = retained(moved_again)
        before_events = events(case)
        boundary_start = len(observations(case, 'boundaries'))
        probe_start = len(observations(case, 'source-probes'))
        (case / 'failures').write_text('')
        code, result = invoke(case, env, 'ordinary-resume', 'qualified-completion')
        final = read(path)
        check('qualified variant: later ordinary resume completes the same task on its second approved host',
              code == 0 and result.get('details', {}).get('run_id') == initial['run_id'] and
              final['status'] == 'completed' and final['target_statuses'][musl_key]['attempts'] == 5 and
              events(case) == before_events + [musl_key] and
              final['context']['task_host_overrides'] == {musl_key:'second'} and
              final['context']['target_hosts'] == initial['context']['target_hosts'] and
              final['context']['native_matrix_config_sha256'] == original_hash and digest(config_path) == original_hash and
              len(final.get('relocations', [])) == 2 and
              final['relocations'][1]['old_host'] == 'replacement' and
              final['relocations'][1]['prior_target'] == exhausted['target_statuses'][musl_key] and
              all(final['target_statuses'][key] == initial['target_statuses'][key] for key in sibling_keys) and
              unchanged(evidence) and unchanged(partial_evidence) and unchanged(failed_evidence) and unchanged(moved_evidence))
        check('qualified variant: active source custody drops only the unused intermediate destination',
              set(final['context']['source_roots']) == {'completed', 'original', 'second'} and
              'replacement' in final['relocations'][1]['prior_context']['source_roots'] and
              read(Path(final['target_statuses'][musl_key]['result_path']))['scheduled_source'] ==
                  scheduled(final, musl_key))
        check('qualified variant: later ordinary source admission never visits the inactive intermediate host',
              all('replacement' not in json.loads(line)
                  for line in observations(case, 'source-probes')[probe_start:]) and
              not any(line.startswith('CARGO-CLOSURE ') and line.endswith(' replacement')
                      for line in observations(case, 'boundaries')[boundary_start:]) and
              ('CARGO-CLOSURE ' + musl + ' second') in observations(case, 'boundaries')[boundary_start:])
        rows = result.get('details', {}).get('targets', [])
        check('qualified variant: final public output reports each actual execution host',
              isinstance(rows, list) and len(rows) == 3 and
              {row.get('task_key'):row.get('host') for row in rows} ==
                  {gnu_key:'completed', musl_key:'second', failed:'original'})
        manifest_path = case / 'output/relocfixture-v1.0.0-manifest.json'
        manifest = read(manifest_path) if manifest_path.exists() else {}
        expected_triples = sorted([gnu, musl, 'x86_64-pc-windows-msvc'])
        check('qualified variant: final manifest binds every retained artifact to its exact variant and real host',
              manifest.get('publishable') is True and manifest.get('run_id') == initial['run_id'] and
              manifest.get('summary') == dict(total=3, success=3, failed=0) and
              sorted(row.get('target_triple', '') for row in manifest.get('artifacts', [])) == expected_triples and
              sorted(row.get('target_triple', '') for row in manifest.get('build_environments', [])) == expected_triples and
              {row['target_triple']:row['host'] for row in manifest.get('build_environments', [])} ==
                  {gnu:'completed', musl:'second', 'x86_64-pc-windows-msvc':'original'} and
              all(digest(case / 'output' / row['name']) == row['sha256'] for row in manifest.get('artifacts', [])))


for mode in (() if hosts_only or matrix_only else ('capacity', 'readiness', 'executed', 'timeout')):
    case, env, targets, initial = seed(mode, mode)
    evidence = retained(initial)
    approve(case, env, failed, 'replacement', 'replacement')
    if mode == 'capacity':
        large = read(Path(initial['target_statuses'][failed]['result_path']))
        large['retained_detail'] = 'x' * 160000
        save(case / 'large-worker.json', large)
        save(case / 'large-state.json', dict(large, execution_started=True, retry_limit_exceeded=True))
        code, unused = invoke(case, env, 'compare', 'large-receipt-matches')
        check('large receipts compare through stdin without the executable argument-size limit', code == 0)
        large['retained_detail'] += 'changed'
        save(case / 'large-state.json', dict(large, execution_started=True))
        code, unused = invoke(case, env, 'compare', 'large-receipt-drift')
        check('large substantive receipt drift remains a refusal', code != 0)
        for field, replacement in (('run_id', '00000000-0000-4000-8000-000000000000'),
                                   ('git_sha', 'f' * 40), ('git_ref', 'v9.9.9'),
                                   ('host', 'other'), ('root', str(case / 'unbound'))):
            refuse(case, env, 'wrong-scheduled-' + field,
                   mutate_evidence(lambda body, key=field, value=replacement:
                       body.setdefault('scheduled_source', {}).__setitem__(key, value)))
        refuse(case, env, 'missing-source-binding', mutate_evidence(lambda body: body.pop('scheduled_source', None)))
        refuse(case, env, 'contradictory-partial-rust-source', mutate_evidence(lambda body:
            body.__setitem__('build_influence_env', {'DSR_RELEASE_GIT_SHA': 'f' * 40})))
        for field in ('execution_started', 'resume_reused', 'retry_limit_exceeded'):
            def bad_annotation(path, unused_receipt, unused_success, key=field):
                state = read(path)
                state['target_statuses'][failed]['result'][key] = 'true'
                save(path, state)
            refuse(case, env, 'invalid-annotation-' + field, bad_annotation)
        for exit_code in (0, 1.5, 130, 143):
            refuse(case, env, 'invalid-failure-exit-' + str(exit_code),
                   mutate_evidence(lambda body, value=exit_code: body.__setitem__('exit_code', value)))
        refuse(case, env, 'cancelled-receipt', mutate_evidence(lambda body: body.__setitem__('status', 'cancelled')))
        for status in ('running', 'cancelled'):
            def invalid_state(path, unused_receipt, unused_success, value=status):
                state = read(path)
                if value == 'running': state['target_statuses'][failed]['status'] = value
                else: state['status'] = value
                save(path, state)
            refuse(case, env, 'ineligible-state-' + status, invalid_state)
        def mismatched_state(path, unused_receipt, unused_success):
            state = read(path)
            state['target_statuses'][failed]['result']['error'] = 'different retained observation'
            save(path, state)
        refuse(case, env, 'receipt-state-drift', mismatched_state)
        def invalid_approval(unused_path, unused_receipt, unused_success):
            approval = read(case / 'approval.json'); approval['repo_config_sha256'] = 'f' * 64
            save(case / 'approval.json', approval)
        refuse(case, env, 'invalid-approval', invalid_approval)
        def global_config(unused_path, unused_receipt, unused_success):
            config_path = case / 'config/repos.d/relocfixture.yaml'
            config = read(config_path); config['build_cmd'] = 'exit 19'; save(config_path, config)
            approval = read(case / 'approval.json'); approval['repo_config_sha256'] = digest(config_path)
            save(case / 'approval.json', approval)
        refuse(case, env, 'global-config-drift', global_config)
        def dirty_source(unused_path, unused_receipt, unused_success):
            with (case / 'source/main.go').open('ab') as out: out.write(b'\n// changed source\n')
        refuse(case, env, 'source-drift', dirty_source, expected_exit=1)
        def changed_success(unused_path, unused_receipt, success):
            with success.open('ab') as out: out.write(b'changed retained artifact\n')
        refuse(case, env, 'completed-artifact-drift', changed_success)
        env['RELOC_ROOTS'] = json.dumps(initial['context']['source_roots'])
        code, spoofed = invoke(case, env, 'spoof')
        check('backend cannot replace its immutable strict dispatch source binding',
              code == 17 and spoofed.get('scheduled_source') == scheduled(initial, failed))
    (case / 'failures').write_text('')
    before = events(case)
    code, resumed = invoke(case, env, 'resume')
    state = read(state_file(case, env['RELOC_RUN']))
    check(mode + ': reviewed public relocation completes the original UUID',
          code == 0 and resumed.get('details', {}).get('run_id') == initial['run_id'] and
          state['status'] == 'completed' and state['context']['target_hosts'][failed] == 'replacement')
    check(mode + ': only the failed target compiles again and receives attempt two',
          events(case) == before + [failed] and state['target_statuses'][failed]['attempts'] == 2 and
          state['target_statuses'][native] == initial['target_statuses'][native] and unchanged(evidence))
    replacement_result = state['target_statuses'][failed]['result']
    check(mode + ': replacement receipt binds the new host to the same frozen source',
          replacement_result.get('scheduled_source') == scheduled(state, failed) and
          len(state.get('relocations', [])) == 1 and
          state['relocations'][0]['prior_target'] == initial['target_statuses'][failed])
    manifest = case / 'output/relocfixture-v1.0.0-manifest.json'
    manifest_value = read(manifest) if manifest.exists() else {}
    check(mode + ': publication manifest covers both verified source-bound target artifacts',
          manifest_value.get('publishable') is True and manifest_value.get('run_id') == initial['run_id'] and
          manifest_value.get('source', {}).get('git_sha') == initial['git_sha'] and
          manifest_value.get('summary') == dict(total=2, success=2, failed=0) and
          all(digest(case / 'output' / row['name']) == row['sha256'] for row in manifest_value.get('artifacts', [])))

if not hosts_only and not matrix_only:
    # Two failed targets can move in successive reviewed invocations. The second
    # approval binds the first relocation's configuration, and neither completed
    # target is compiled again while the remaining target advances to attempt 3.
    case, env, targets, initial = seed('sequential', 'executed', True)
    evidence = retained(initial)
    approve(case, env, failed, 'replacement', 'first-relocation')
    (case / 'failures').write_text('windows/amd64\n')
    code, result = invoke(case, env, 'resume', 'first-relocation')
    middle = read(state_file(case, env['RELOC_RUN']))
    check('first sequential relocation retains partial outcome of the other failed target',
          code == 1 and middle['status'] == 'partial' and
          middle['target_statuses'][failed]['status'] == 'completed' and
          middle['target_statuses']['windows/amd64']['status'] == 'failed')
    middle_evidence = retained(middle)
    approve(case, env, 'windows/amd64', 'second', 'second-relocation')
    (case / 'failures').write_text('')
    before = events(case)
    code, result = invoke(case, env, 'resume', 'second-relocation')
    final = read(state_file(case, env['RELOC_RUN']))
    check('second sequential relocation completes only the remaining target in the same run',
          code == 0 and final['run_id'] == initial['run_id'] and final['status'] == 'completed' and
          events(case) == before + ['windows/amd64'] and
          final['target_statuses']['windows/amd64']['attempts'] == 3 and
          final['target_statuses'][native] == initial['target_statuses'][native] and
          final['target_statuses'][failed] == middle['target_statuses'][failed] and
          len(final.get('relocations', [])) == 2 and unchanged(evidence) and unchanged(middle_evidence))

# Host selection, health and transport honor DSR_HOSTS_FILE. Approval and later
# resume must bind those same bytes, even when an unrelated default file exists.
for hosts_mode in (() if matrix_only else ('default', 'custom-absent')):
    case, env, targets, initial = seed('hosts-' + hosts_mode, 'executed', hosts_mode=hosts_mode)
    evidence, before_events = retained(initial), events(case)
    approve(case, env, failed, 'replacement', 'relocation')
    active_hosts = Path(env['DSR_HOSTS_FILE'])
    reviewed_hash = digest(active_hosts)
    if hosts_mode == 'default':
        env.pop('DSR_HOSTS_FILE')  # The supported default remains a valid authority.
        (case / 'failures').write_text('')
    code, value = invoke(case, env, 'resume')
    state = read(state_file(case, env['RELOC_RUN']))
    relocated = check(hosts_mode + ': reviewed active hosts configuration permits real relocation',
        code == (0 if hosts_mode == 'default' else 1) and
        state['status'] == ('completed' if hosts_mode == 'default' else 'partial') and
        state['context']['target_hosts'][failed] == 'replacement' and
        state.get('relocations', [{}])[-1].get('hosts_config_sha256') == reviewed_hash and
        events(case) == before_events + [failed] and unchanged(evidence))
    if hosts_mode == 'custom-absent':
        check('custom hosts relocation does not require or create the default hosts file',
              not (case / 'config/hosts.yaml').exists())
        if relocated:
            # Content identity permits another path to the same reviewed bytes.
            alias = case / 'active hosts alias.yaml'
            alias.symlink_to(active_hosts)
            env['DSR_HOSTS_FILE'] = str(alias)
            (case / 'config/hosts.yaml').write_text('unrelated inactive configuration\n')
            before_events = events(case)
            partial_evidence = retained(state)
            (case / 'failures').write_text('')
            code, value = invoke(case, env, 'ordinary-resume', 'same-hosts-alias')
            check('ordinary resume accepts an alias of reviewed hosts bytes and ignores inactive default drift',
                  code == 0 and events(case) == before_events + [failed] and unchanged(partial_evidence) and
                  read(state_file(case, env['RELOC_RUN']))['status'] == 'completed' and
                  read(state_file(case, env['RELOC_RUN']))['target_statuses'][failed]['attempts'] == 3)

for timing in (() if matrix_only else ('before-sync', 'after-sync', 'ordinary-resume')):
    case, env, targets, initial = seed('hosts-drift-' + timing, 'executed', hosts_mode='custom-mirrored')
    approve(case, env, failed, 'replacement', 'relocation')
    active_hosts, default_hosts = Path(env['DSR_HOSTS_FILE']), case / 'config/hosts.yaml'
    approved_hash = digest(default_hosts)
    if timing == 'ordinary-resume':
        # Keep the replacement's recipe failing so a later ordinary retry has
        # real pending work and a persisted, approved relocation to protect.
        code, value = invoke(case, env, 'resume', 'retained-relocation')
        partial = read(state_file(case, env['RELOC_RUN']))
        check('host drift fixture retains a real failed replacement attempt and reviewed relocation',
              code == 1 and partial['status'] == 'partial' and
              partial['target_statuses'][failed]['attempts'] == 2 and
              partial.get('relocations', [{}])[-1].get('hosts_config_sha256') == approved_hash)
    path = state_file(case, env['RELOC_RUN'])
    before_state, before_events = path.read_bytes(), events(case)
    evidence = retained(read(path))
    if timing == 'after-sync':
        env['RELOC_MUTATE_HOSTS_AFTER_SYNC'] = '1'
    else:
        hosts = read(active_hosts)
        hosts['hosts']['replacement']['concurrency'] = 3
        save(active_hosts, hosts)
    (case / 'failures').write_text('')
    phase = 'ordinary-resume' if timing == 'ordinary-resume' else 'resume'
    code, value = invoke(case, env, phase, 'changed-active-hosts', preflight_exit=4)
    check(timing + ': changed active hosts refuse without another recipe or checkpoint transition',
          code == 4 and path.read_bytes() == before_state and events(case) == before_events and
          unchanged(evidence) and digest(default_hosts) == approved_hash and digest(active_hosts) != approved_hash)
    if timing == 'before-sync':
        check('unreviewed active hosts are refused before replacement source staging',
              not (case / 'replacement').exists())
    elif timing == 'after-sync':
        sync_path = case / 'sync-before-host-drift.json'
        staged = read(sync_path) if sync_path.exists() else {}
        check('post-staging active hosts drift is checked after genuine immutable source synchronization',
              staged.get('status') == 'success' and staged.get('target_hosts') == {failed: 'replacement'} and
              all(Path(path).is_dir() for path in staged.get('source_roots', {}).values()))

(root / 'summary.json').write_text(json.dumps(dict(checks=checks, failures=failures, native=native)) + '\n')
print('Relocation recovery: %d checks, %d failures' % (checks, failures), flush=True)
raise SystemExit(bool(failures))
PY
}

if [[ "${1:-}" == --relocation-recovery-only || "${1:-}" == --relocation-hosts-only ||
      "${1:-}" == --relocation-matrix-only || "${1:-}" == --relocation-variant-only ||
      "${1:-}" == --relocation-preview-only || "${1:-}" == --recipe-binding-only ||
      "${1:-}" == --snapshot-owners-only ]]; then
    test_relocation_recovery "$1"
    exit $?
fi

# Exercise the real worker and owned process groups without requiring a native
# compiler, Docker, SSH, or null-device type checks. Resistant descendants must
# stop before a live worker releases capacity or publishes interruption.
test_worker_group_lifecycle() {
    local project_root required_tool
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    for required_tool in python3 jq; do
        command -v "$required_tool" >/dev/null || return 77
    done
    python3 - "${DSR_TEST_ACT_RUNNER:-$project_root/src/act_runner.sh}" <<'PY'
import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

module = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix='dsr-worker-lifecycle-'))
print('Retained worker lifecycle fixture: ' + str(root), flush=True)
checks = failures = 0
if sys.platform.startswith('linux'):
    # Reap orphaned fixture grandchildren after parent-loss probes.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'PR_SET_CHILD_SUBREAPER')


def check(label, valid):
    global checks, failures
    checks += 1
    failures += not valid
    print(('PASS: ' if valid else 'FAIL: ') + label, flush=True)


def alive(pid):
    try:
        result = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)],
                                capture_output=True, text=True, check=False)
        return result.returncode == 0 and bool(result.stdout.strip()) and not result.stdout.lstrip().startswith('Z')
    except ProcessLookupError:
        return False


def fixture_signals():
    # A tool runner or CI shell may ignore HUP. Bash cannot trap a signal
    # ignored on entry, so restore its normal disposition before exec.
    signal.signal(signal.SIGHUP, signal.SIG_DFL)


def until(predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


probe = root / 'probe.py'
probe.write_text(r'''import json, os, pathlib, signal, subprocess, sys, time
case = pathlib.Path(sys.argv[1])
def alive(pid):
    result = subprocess.run(['ps','-o','stat=','-p',str(pid)],
                            capture_output=True,text=True,check=False)
    return result.returncode == 0 and bool(result.stdout.strip()) and not result.stdout.lstrip().startswith('Z')
if sys.argv[2] == 'child':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    (case / 'descendant.json').write_text(json.dumps(dict(pid=os.getpid(), pgid=os.getpgrp(), sid=os.getsid(0))))
    while True:
        time.sleep(0.05)
else:
    pids = [int((case / 'backend.pid').read_text())] if (case / 'backend.pid').exists() else []
    if (case / 'descendant.json').exists():
        pids.append(json.loads((case / 'descendant.json').read_text())['pid'])
    (case / 'released.json').write_text(json.dumps(dict(pids=pids, alive=[pid for pid in pids if alive(pid)])))
''')

driver = root / 'driver.bash'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$1" || exit 90
CASE="$2" MODE="$3" PROBE="$4"
export CASE MODE PROBE
ACT_LOGS_DIR="$CASE/logs"
mkdir "$ACT_LOGS_DIR"
act_platform_uses_act() { return 0; }
selector_acquire_slot() { printf '%s\n' "$BASHPID" > "$CASE/acquired"; }
selector_release_slot() { python3 "$PROBE" "$CASE" release; }
_act_build_orchestration_target() {
    set +m
    printf '%s\n' "$BASHPID" > "$CASE/backend.pid"
    if [[ "$MODE" == success ]]; then
        printf 'owned artifact\n' > "$CASE/artifact.bin"
        jq -nc --arg path "$CASE/artifact.bin" --arg host "${10}" \
            '{platform:"linux/amd64",method:"act",host:$host,status:"success",exit_code:0,artifact_path:$path}'
        return 0
    fi
    if [[ "$MODE" == failure ]]; then
        jq -nc '{platform:"linux/amd64",method:"act",status:"failed",exit_code:17,error:"fixture failure"}'
        return 17
    fi
    if [[ "$MODE" == leader_ignores || "$MODE" == worker_hangup || "$MODE" == parent_lost ]]; then
        trap '' TERM
    else
        trap 'exit 143' TERM
    fi
    python3 "$PROBE" "$CASE" child &
    local descendant="$!"
    while [[ ! -s "$CASE/descendant.json" ]]; do sleep 0.01; done
    if [[ "$MODE" == completed_with_orphan || "$MODE" == closed_reader ]]; then
        jq -nc '{platform:"linux/amd64",method:"act",status:"failed",exit_code:17,error:"fixture failure"}'
        return 17
    fi
    wait "$descendant"
}
if [[ "$MODE" == closed_reader ]]; then
    # Exercise a lost status reader before completion is reported. A fatal
    # SIGPIPE here must not bypass cleanup of the still-owned group.
    _act_run_target_group "$CASE/attempt.log" _act_build_orchestration_target
    exit $?
fi
# An existing coprocess has private descriptors and must remain usable after
# the target worker. Exercise both caller monitor states on normal completion.
if [[ "$MODE" == success || "$MODE" == failure ]]; then
    [[ "$MODE" != success ]] || set -m
    coproc FOREIGN_WORKER {
        IFS= read -r request
        printf 'foreign:%s\n' "$request"
        # Keep the read descriptor live until its owner observed the reply.
        IFS= read -r acknowledgement && [[ "$acknowledgement" == received ]]
    }
    foreign_pid="$FOREIGN_WORKER_PID"
    foreign_read="${FOREIGN_WORKER[0]}"
    foreign_write="${FOREIGN_WORKER[1]}"
    before_flags="$-"
fi
status=0
_act_run_target_worker tool v1.0.0 run linux/amd64 1 \
    "$CASE/attempt.log" "$CASE/attempt.json" false '{}' '{}' '' '' act-local release || status=$?
if [[ "$MODE" == success || "$MODE" == failure ]]; then
    after_flags="$-"
    printf 'still-owned\n' >&"$foreign_write"
    IFS= read -r -u "$foreign_read" foreign_response || exit 91
    [[ "$foreign_response" == foreign:still-owned ]] || exit 92
    printf 'received\n' >&"$foreign_write"
    wait "$foreign_pid" || exit 93
    if [[ "$before_flags" == *m* ]]; then
        [[ "$after_flags" == *m* ]] || exit 94
    else
        [[ "$after_flags" != *m* ]] || exit 95
    fi
    printf 'preserved\n' > "$CASE/caller-state"
fi
exit "$status"
''')

sentinel = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'],
                            start_new_session=True)
try:
    for mode in ('success', 'failure', 'completed_with_orphan', 'closed_reader',
                 'leader_ignores', 'descendant_survives', 'worker_hangup', 'parent_lost'):
        case = root / mode
        case.mkdir()
        env = os.environ.copy()
        env.update(DSR_STATE_DIR=str(case / 'state'), DSR_CACHE_DIR=str(case / 'cache'),
                   DSR_CONFIG_DIR=str(case / 'config'))
        owned = {}
        with (case / 'driver.log').open('wb') as log:
            process = subprocess.Popen(['bash', str(driver), str(module), str(case), mode, str(probe)],
                                       env=env, stdin=subprocess.PIPE if mode == 'closed_reader' else None,
                                       stdout=subprocess.PIPE if mode == 'closed_reader' else log,
                                       stderr=log, start_new_session=True,
                                       preexec_fn=fixture_signals)
            try:
                if mode == 'closed_reader':
                    process.stdout.close()
                    process.stdin.write(b'start\n')
                    process.stdin.flush()
                if mode in ('success', 'failure'):
                    process.wait(timeout=10)
                    receipt = json.loads((case / 'attempt.json').read_text())
                    expected = 0 if mode == 'success' else 17
                    check(mode + ': preserves actual backend exit and receipt',
                          process.returncode == expected and receipt['exit_code'] == expected)
                    check(mode + ': preserves caller job control and unrelated coprocess',
                          (case / 'caller-state').read_text() == 'preserved\n')
                    if mode == 'success':
                        check('success: retains frozen artifact evidence',
                              receipt['status'] == 'success' and len(receipt['resume_artifacts']) == 1)
                else:
                    def ready():
                        try:
                            owned.update(json.loads((case / 'descendant.json').read_text()))
                            owned['backend'] = int((case / 'backend.pid').read_text())
                            return owned['sid'] == process.pid and (
                                mode in ('completed_with_orphan', 'closed_reader') or alive(owned['pid']))
                        except (FileNotFoundError, ValueError, KeyError):
                            return False
                    if not until(ready):
                        raise AssertionError('owned backend/descendant did not reach the barrier')
                    if mode in ('leader_ignores', 'descendant_survives'):
                        os.kill(process.pid, signal.SIGTERM)
                    elif mode == 'worker_hangup':
                        os.kill(process.pid, signal.SIGHUP)
                    elif mode == 'parent_lost':
                        os.kill(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                    check(mode + ': owned descendants retire after bounded cleanup',
                          until(lambda: not alive(owned['backend']) and not alive(owned['pid']), 8))
                    if mode == 'closed_reader':
                        check('closed status reader: drains before the anchor exits',
                              process.returncode == -signal.SIGKILL)
                    elif mode == 'parent_lost':
                        check('parent loss: does not invent cleanup or completion receipts',
                              process.returncode == -signal.SIGKILL and
                              not (case / 'attempt.json').exists() and not (case / 'released.json').exists())
                    else:
                        receipt = json.loads((case / 'attempt.json').read_text())
                        expected = 17 if mode == 'completed_with_orphan' else 130
                        check(mode + ': retains actual failure or interrupted attempt identity',
                              process.returncode == expected and receipt['exit_code'] == expected and
                              receipt['status'] == 'failed' and receipt['platform'] == 'linux/amd64' and
                              receipt['task_key'] == 'linux/amd64')
                if mode not in ('parent_lost', 'closed_reader'):
                    released = json.loads((case / 'released.json').read_text())
                    check(mode + ': releases capacity only after owned work stops', released['alive'] == [])
                check(mode + ': leaves unrelated process alive', sentinel.poll() is None)
            except (AssertionError, OSError, KeyError, ValueError, subprocess.TimeoutExpired) as error:
                check(mode + ': ' + str(error), False)
            finally:
                if process.stdin is not None:
                    process.stdin.close()
                # Restrict failure cleanup to the exact owned fixture session.
                if owned:
                    for pid in (owned.get('backend'), owned.get('pid')):
                        try:
                            if pid and os.getsid(pid) == process.pid:
                                os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    try:
                        if os.getsid(owned['pgid']) == process.pid:
                            os.killpg(owned['pgid'], signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if process.poll() is None:
                    process.kill()
                process.wait()
                if sys.platform.startswith('linux'):
                    while True:
                        try:
                            pid, _ = os.waitpid(-1, os.WNOHANG)
                            if not pid:
                                break
                        except ChildProcessError:
                            break
finally:
    sentinel.terminate()
    sentinel.wait(timeout=5)
(root / 'summary.json').write_text(json.dumps(dict(checks=checks, failures=failures)) + '\n')
print('Worker lifecycle: %d checks, %d failures' % (checks, failures), flush=True)
raise SystemExit(bool(failures))
PY
}

if [[ "${1:-}" == --worker-lifecycle-only ]]; then
    test_worker_group_lifecycle
    exit $?
fi

if [[ "${1:-}" == --stdin-isolation-only || "${1:-}" == --coordinator-receipt-only ||
      "${1:-}" == --sidecar-recovery-only || "${1:-}" == --worker-completion-only ||
      "${1:-}" == --host-readiness-only || "${1:-}" == --host-readiness-cli-only ||
      "${1:-}" == --coordinator-custody-only || "${1:-}" == --invocation-identity-only ]]; then
    test_worker_stdin_isolation "$1"
    exit $?
fi

# Setup test environment BEFORE sourcing (critical for config path resolution)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR=$(mktemp -d)

# These MUST be set before sourcing act_runner.sh as it calculates paths at load time
export DSR_STATE_DIR="$TEMP_DIR/state"
export DSR_CACHE_DIR="$TEMP_DIR/cache"
export DSR_CONFIG_DIR="$TEMP_DIR/config"
export DSR_STRICT_BUILD_ROOT="$TEMP_DIR/strict-build-root"

mkdir -p "$DSR_STATE_DIR" "$DSR_CACHE_DIR" "$DSR_CONFIG_DIR/repos.d"

cat > "$DSR_CONFIG_DIR/hosts.yaml" << 'EOF'
schema_version: "1.0.0"
hosts:
  trj:
    platform: linux/amd64
    connection: local
  mmini:
    platform: darwin/arm64
    connection: ssh
    ssh_host: mac-mini-max
  wlap:
    platform: windows/amd64
    connection: ssh
    ssh_host: surfacebookje
platform_mapping:
  linux/amd64: trj
  darwin/amd64: mmini
  darwin/arm64: mmini
  windows/amd64: wlap
  windows/arm64: wlap
EOF

# Source the modules (order matters - config dirs must be set first)
source "$SCRIPT_DIR/src/logging.sh"
source "$SCRIPT_DIR/src/config.sh"
source "$SCRIPT_DIR/src/build_state.sh"
source "$SCRIPT_DIR/src/act_runner.sh"

# Decode a `-EncodedCommand` payload back to the PowerShell text so mocks can
# assert on the script the host would actually run.
_test_decode_remote_command() {
    local command="$1" encoded decoded inner
    if [[ "$command" == *'-Command "& ([ScriptBlock]::Create([IO.StreamReader]::new('* ]]; then
        inner="${command#*FromBase64String(\'}"
        inner="${inner%%\'*}"
        decoded=$(printf '%s' "$inner" | base64 -d 2>/dev/null | gzip -dc) || return 1
        printf '%s' "${decoded#\$ProgressPreference=\'SilentlyContinue\'; }"
        return 0
    fi
    if [[ "$command" == *"-EncodedCommand "* ]]; then
        encoded="${command##*-EncodedCommand }"
        encoded="${encoded%% *}"
        decoded=$(printf '%s' "$encoded" | base64 -d 2>/dev/null | iconv -f UTF-16LE -t UTF-8 2>/dev/null)
        if [[ "$decoded" == "\$DSRScriptGzip='"* ]]; then
            inner="${decoded#\$DSRScriptGzip=\'}"
            inner="${inner%%\'*}"
            decoded=$(printf '%s' "$inner" | base64 -d 2>/dev/null | gzip -dc) || return 1
        fi
        decoded="${decoded#\$ProgressPreference=\'SilentlyContinue\'; }"
        # A cmd.exe line wrapped by _act_windows_cmd_via_powershell: unwrap it
        # so assertions see the cmd line the host would run.
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


# Verify ACT_REPOS_DIR is correctly set from DSR_CONFIG_DIR
ACT_REPOS_DIR="$DSR_CONFIG_DIR/repos.d"

# Initialize logging (suppress output)
# Note: LOG_LEVEL is used by logging.sh
export LOG_LEVEL=0
log_init >/dev/null 2>&1
build_state_init

# The task planner, scheduler, worker, state and resume receipts are production
# code. Only native execution is a controlled subprocess that reads stdin and
# writes small payloads; these fixtures are not cross-compilation evidence.
test_dispatch_stdin_isolation() {
    python3 - "$SCRIPT_DIR" "$TEMP_DIR" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

project, temporary = map(Path, sys.argv[1:])
root = temporary / 'dispatch-stdin'
root.mkdir()
print('Retained dispatch stdin fixtures:', root, flush=True)
platforms = ['linux/amd64', 'linux/arm64', 'darwin/amd64', 'darwin/arm64',
             'windows/amd64', 'windows/arm64']
gnu, musl = 'x86_64-unknown-linux-gnu', 'x86_64-unknown-linux-musl'
checks, failures = 0, []

def check(label, condition):
    global checks
    checks += 1
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    if not condition:
        failures.append(label)

producer = r'''import json, os, sys, time
from pathlib import Path
root, platform, triple, phase, jobs = Path(sys.argv[1]), *sys.argv[2:]
key = platform + ('@' + triple if triple else '')
slug = key.replace('/', '-')
captured = sys.stdin.buffer.read()
(root / (phase + '-' + slug + '.stdin')).write_bytes(captured)
def event(state):
    row = json.dumps(dict(phase=phase, key=key, state=state, at=time.monotonic_ns())) + '\n'
    fd = os.open(root / 'events.jsonl', os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)
    try:
        os.write(fd, row.encode())
    finally:
        os.close(fd)
event('start')
# Make overlap observable without a wall-clock performance assertion. Even
# the broken dispatcher must finish this fixture if it lost the second task.
if phase == 'first' and int(jobs) > 1 and platform == 'linux/amd64' and triple.endswith('-gnu'):
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        rows = [json.loads(line) for line in (root / 'events.jsonl').read_text().splitlines()]
        if sum(row['phase'] == phase and row['state'] == 'start' for row in rows) >= 2:
            break
        time.sleep(0.02)
time.sleep(0.2)
failed = phase == 'first' and jobs == '2' and platform == 'linux/arm64'
result = dict(platform=platform, method='native', host='fixture-' + platform.replace('/', '-'),
              status='failed' if failed else 'success', exit_code=9 if failed else 0,
              target_triple=triple or None)
if failed:
    result['error'] = 'deliberate native transport failure'
else:
    payload = root / 'payloads' / (phase + '-' + slug)
    with payload.open('xb') as output:
        output.write(('scheduler payload ' + key + '\n').encode())
    result.update(artifact_path=str(payload), artifact_paths=[str(payload)])
event('end')
print(json.dumps(result, separators=(',', ':')), flush=True)
sys.exit(result['exit_code'])
'''

driver = r'''source "$1/src/logging.sh"
source "$1/src/config.sh"
source "$1/src/build_state.sh"
source "$1/src/act_runner.sh"
unset -f selector_acquire_slot selector_release_slot
act_run_native_build() {
    # Retain the real timeout wrapper and a real stdin-reading descendant.
    _act_run_with_timeout 12 python3 "$DSR_DISPATCH_FIXTURE/producer.py" \
        "$DSR_DISPATCH_FIXTURE" "$2" "${9:-}" "$DSR_DISPATCH_PHASE" "$DSR_DISPATCH_JOBS"
}
args=(stdinfixture v1.0.0 --parallel-jobs "$DSR_DISPATCH_JOBS" \
      --output-dir "$DSR_DISPATCH_FIXTURE/output" --source-sync-json "$(cat "$DSR_DISPATCH_FIXTURE/sync.json")")
if [[ -n "${DSR_DISPATCH_RESUME:-}" ]]; then
    args+=(--resume-run-id "$DSR_DISPATCH_RESUME")
fi
act_orchestrate_build "${args[@]}"
status=$?
exit "$status"
'''

def run(directory, phase, jobs, resume=''):
    env = {key: value for key, value in os.environ.items()
           if key not in ('BASH_ENV', 'ENV') and not key.startswith('BASH_FUNC_')}
    env.update(DSR_DISPATCH_FIXTURE=str(directory), DSR_DISPATCH_PHASE=phase,
               DSR_DISPATCH_JOBS=str(jobs), DSR_DISPATCH_RESUME=resume,
               DSR_CONFIG_DIR=str(directory / 'config'), DSR_REPOS_FILE=str(directory / 'config/repos.yaml'),
               DSR_HOSTS_FILE=str(directory / 'config/hosts.yaml'), ACT_REPOS_DIR=str(directory / 'config/repos.d'),
               DSR_STATE_DIR=str(directory / 'state'), DSR_CACHE_DIR=str(directory / 'cache'),
               ACT_ARTIFACTS_DIR=str(directory / 'artifacts'), ACT_LOGS_DIR=str(directory / 'logs'),
               DSR_RUN_ID='', DSR_BUILD_LOCK_HELD_BY_CALLER='0', NO_COLOR='1')
    result = subprocess.run(['bash', '-c', driver, '_', str(project)], env=env,
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
    (directory / (phase + '.stdout')).write_bytes(result.stdout)
    (directory / (phase + '.stderr')).write_bytes(result.stderr)
    try:
        body = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError):
        raise AssertionError('Missing structured scheduler result: ' + result.stderr.decode(errors='replace'))
    state_files = list((directory / 'state/builds').rglob('state.json'))
    matches = [json.loads(path.read_text()) for path in state_files]
    matches = [value for value in matches if value.get('run_id') == body['run_id']]
    if len(matches) != 1:
        raise AssertionError('Missing unique production build state: ' + str(state_files))
    state = matches[0]
    (directory / (phase + '.state.json')).write_text(json.dumps(state) + '\n')
    return result.returncode, body, state

def events(directory, phase):
    path = directory / 'events.jsonl'
    return [row for row in map(json.loads, path.read_text().splitlines()) if row['phase'] == phase]

def verify_phase(label, directory, phase, jobs, result, state, expected, expected_failures=0):
    rows = result['targets']
    check(label + ': complete ordered task results', [row.get('task_key') for row in rows] == expected)
    check(label + ': exact success/failure summary', result['summary'] == dict(
        total=len(expected), success=len(expected) - expected_failures, failed=expected_failures))
    check(label + ': every task has an actual attempt and immutable result path',
          all(row.get('attempt', 0) >= 1 and Path(row.get('result_path', '/nonexistent')).is_file()
              for row in rows))
    check(label + ': no pending or synthetic missing-result target',
          all(entry['status'] != 'pending' and entry.get('attempts', 0) >= 1
              for entry in state['target_statuses'].values()) and
          all(row.get('error') != 'No target result' for row in rows))
    timeline = events(directory, phase)
    starts = [row['key'] for row in timeline if row['state'] == 'start']
    check(label + ': each expected worker actually executes exactly once',
          sorted(starts) == sorted(expected) and len(starts) == len(set(starts)))
    captures = list(directory.glob(phase + '-*.stdin'))
    check(label + ': workers receive EOF rather than coordinator task JSON',
          len(captures) == len(expected) and all(path.read_bytes() == b'' for path in captures))
    active = peak = 0
    for row in sorted(timeline, key=lambda value: value['at']):
        active += 1 if row['state'] == 'start' else -1
        peak = max(peak, active)
    check(label + ': worker execution reaches its bound without exceeding it', peak == jobs and active == 0)
    successful = [row for row in rows if row.get('status') == 'success']
    check(label + ': successful receipts bind actual payload bytes', all(
        len(row.get('resume_artifacts', [])) == 1 and
        row['resume_artifacts'][0]['path'] == row['artifact_path'] and
        row['resume_artifacts'][0]['sha256'] == hashlib.sha256(Path(row['artifact_path']).read_bytes()).hexdigest()
        for row in successful))

for jobs in (1, 2):
    directory = root / ('jobs-' + str(jobs))
    for relative in ('config/repos.d', 'output', 'payloads', 'sources'):
        (directory / relative).mkdir(parents=True)
    config = dict(tool_name='stdinfixture', repo='example/stdinfixture', language='rust',
                  local_path=str(directory / 'sources'), binary_name='tool', targets=platforms,
                  build_cmd='cargo build --release --target ${TARGET_TRIPLE}',
                  act_job_map={platform: None for platform in platforms})
    expected = platforms[:]
    if jobs == 2:
        config['target_triples'] = {'linux/amd64': [gnu, musl]}
        expected = ['linux/amd64@' + gnu, 'linux/amd64@' + musl] + platforms[1:]
    (directory / 'config/repos.d/stdinfixture.yaml').write_text(json.dumps(config) + '\n')
    hosts = {platform: 'fixture-' + platform.replace('/', '-') for platform in platforms}
    roots = {host: str(directory / 'sources' / host) for host in hosts.values()}
    for path in roots.values():
        Path(path).mkdir()
    sync = dict(status='success', synced=len(roots), failed=0, target_hosts=hosts, source_roots=roots,
                hosts=[dict(host=host, path=path, status='success') for host, path in roots.items()])
    (directory / 'sync.json').write_text(json.dumps(sync) + '\n')
    (directory / 'producer.py').write_text(producer)
    status, first, state = run(directory, 'first', jobs)
    label = 'jobs=' + str(jobs)
    check(label + ': scheduler exit preserves worker outcome', status == (0 if jobs == 1 else 1))
    verify_phase(label, directory, 'first', jobs, first, state, expected, jobs - 1)
    if jobs != 2:
        continue
    # Continue only after a complete first attempt; a broken dispatcher still
    # produces its own retained failure evidence rather than fabricated rows.
    if any(not row.get('result_path') for row in first['targets']):
        continue
    first_rows = {row['task_key']: row for row in first['targets']}
    preserved = {path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
                 for row in first['targets'] for path in (row['result_path'], row['log_path'])}
    mutated_key = expected[0]
    Path(first_rows[mutated_key]['artifact_path']).write_bytes(b'tampered after frozen receipt\n')
    status, resumed, resumed_state = run(directory, 'resume', jobs, first['run_id'])
    rebuilt = {mutated_key, 'linux/arm64'}
    check('resume: same run completes all physical and variant tasks', status == 0 and
          resumed['run_id'] == first['run_id'] and resumed['summary'] == dict(total=7, success=7, failed=0))
    check('resume: only failed and byte-changed tasks execute again',
          {row['key'] for row in events(directory, 'resume') if row['state'] == 'start'} == rebuilt)
    check('resume: completed untouched tasks retain verified reuse', all(
        (row.get('resume_reused') is True and row['attempt'] == 1 and
         row['result_path'] == first_rows[row['task_key']]['result_path'])
        if row['task_key'] not in rebuilt else (not row.get('resume_reused') and row['attempt'] == 2)
        for row in resumed['targets']))
    check('resume: both attempted workers receive EOF',
          len(list(directory.glob('resume-*.stdin'))) == 2 and
          all(path.read_bytes() == b'' for path in directory.glob('resume-*.stdin')))
    check('resume: original success and failure evidence is immutable', all(
        hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest for path, digest in preserved.items()))
    check('resume: no pending state and exact per-task attempt counts', all(
        entry['status'] == 'completed' and entry['attempts'] == (2 if key in rebuilt else 1)
        for key, entry in resumed_state['target_statuses'].items()))
    before = (directory / 'events.jsonl').read_bytes()
    status, reused, unused_state = run(directory, 'verified-reuse', jobs, first['run_id'])
    check('verified reuse: no new build and every task result remains present', status == 0 and
          len(reused['targets']) == len(expected) and
          all(row.get('resume_reused') is True for row in reused['targets']) and
          (directory / 'events.jsonl').read_bytes() == before)

(root / 'summary.json').write_text(json.dumps(dict(checks=checks, failures=failures)) + '\n')
print('Dispatch stdin: %d checks, %d failures' % (checks, len(failures)), flush=True)
sys.exit(bool(failures))
PY
}

if test_dispatch_stdin_isolation; then
    pass "dispatch owns its task stream through failure and verified resume"
else
    fail "a worker consumed scheduler input or lost task/state/receipt coverage"
fi
if [[ "${1:-}" == --dispatch-stdin-only ]]; then
    [[ $FAIL -eq 0 ]]
    exit $?
fi

# Target-specific executable families must use real selection and reject
# malformed declarations before a native executable can enter an archive.
family_config="$TEMP_DIR/family-targets.yaml"
cat > "$family_config" <<'EOF'
workspace_binaries: [ft, frankenterm-mux-server]
workspace_binaries_by_target:
  windows/amd64: [ft, frankenterm-mux-server, frankenterm-gui.EXE]
  linux/arm64: []
EOF
if [[ "$(_act_workspace_binaries_for_target "$family_config" windows/amd64)" == \
      $'ft\nfrankenterm-mux-server\nfrankenterm-gui.exe' ]] && \
   [[ "$(_act_workspace_binaries_for_target "$family_config" darwin/arm64)" == \
      $'ft\nfrankenterm-mux-server' ]] && \
   [[ -z "$(_act_workspace_binaries_for_target "$family_config" linux/arm64)" ]]; then
    pass "target executable override preserves other platforms and explicit empty selection"
else
    fail "target executable family selection changed the wrong platform"
fi

for invalid_family in \
    '{"workspace_binaries_by_target":{"windows/amd64":["ft","FT.EXE"]}}' \
    '{"workspace_binaries_by_target":{"windows/amd64":["../ft"]}}' \
    '{"workspace_binaries_by_target":{"windows/amd64":["ft\nGUI"]}}' \
    '{"workspace_binaries_by_target":{"windows/amd64":["ft\n"]}}' \
    '{"workspace_binaries_by_target":{"windows/amd64":null}}' \
    '{"workspace_binaries_by_target":[]}' \
    '{"workspace_binaries":[false]}' \
    '{"workspace_binaries":["ft","ft"]}'; do
    printf '%s\n' "$invalid_family" > "$family_config"
    if _act_workspace_binaries_for_target "$family_config" windows/amd64 >/dev/null 2>&1; then
        fail "invalid target executable family was admitted"
    else
        pass "invalid target executable family is rejected"
    fi
done

echo "═══════════════════════════════════════════════════════════════"
echo "  Hybrid Build Orchestration Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

large_windows_script="$(printf '# %5000s\n' '')"$'\n'"Write-Output '界面'; exit 37"
large_windows_command=$(_act_windows_encoded_powershell "$large_windows_script")
if [[ ${#large_windows_command} -lt 7100 ]] && \
   [[ "$(_test_decode_remote_command "$large_windows_command")" == "$large_windows_script" ]]; then
    pass "large Windows scripts round-trip UTF-8 and newlines within the command limit"
else
    fail "large Windows script transport changed bytes or exceeded its limit"
fi

medium_windows_script="# $(awk 'BEGIN { srand(2); for (i=0;i<3500;i++) printf "%c",33+int(rand()*90) }')"$'\n'"Write-Output '界面'; exit 37"
medium_windows_command=$(_act_windows_encoded_powershell "$medium_windows_script" pwsh)
if [[ "$medium_windows_command" == 'pwsh -NoProfile -NonInteractive -Command '* ]] && \
   [[ ${#medium_windows_command} -le 7000 ]] && \
   [[ "$(_test_decode_remote_command "$medium_windows_command")" == "$medium_windows_script" ]]; then
    pass "moderately compressible Windows scripts avoid nested base64 expansion"
else
    fail "moderately compressible Windows script transport changed bytes or exceeded its limit"
fi

oversized_windows_script=$(awk 'BEGIN { srand(1); for (i=0;i<16000;i++) printf "%c",33+int(rand()*90) }')
for script_to_stage in "Write-Output 'small'; exit 37" "$large_windows_script" "$medium_windows_script"; do
    command_to_stage=$(_act_windows_encoded_powershell "$script_to_stage" pwsh)
    decoded_to_stage=$(_act_windows_command_script "$command_to_stage")
    if [[ "$decoded_to_stage" == "\$ProgressPreference='SilentlyContinue'; $script_to_stage" ]]; then
        pass "plain-file staging recovers exact original script bytes"
    else
        fail "plain-file staging changed the script"
    fi
done
if _act_windows_command_script 'pwsh -Command Write-Output unexpected' >/dev/null 2>&1; then
    fail "plain-file staging accepted a non-generated command form"
else
    pass "plain-file staging refuses arbitrary command syntax"
fi
oversized_windows_status=0
_act_windows_encoded_powershell "$oversized_windows_script" >/dev/null 2>&1 || oversized_windows_status=$?
if [[ $oversized_windows_status -eq 4 ]]; then
    pass "incompressible oversized Windows scripts fail before remote truncation"
else
    fail "oversized Windows script transport did not fail closed"
fi

# Check if yq is available (required for YAML parsing)
if ! command -v yq &>/dev/null; then
    skip "yq not installed - skipping YAML-dependent tests"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Passed:${NC}  $PASS"
    echo -e "  ${RED}Failed:${NC}  $FAIL"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIP"
    echo ""
    echo "Note: Install yq to run full test suite: sudo snap install yq"
    exit 0
fi

# Create a test config
cat > "$ACT_REPOS_DIR/testool.yaml" << 'EOF'
tool_name: testool
repo: Test/testool
local_path: /tmp/testool
language: go
binary_name: testool
build_cmd: echo "building testool"
targets:
  - linux/amd64
  - darwin/arm64
  - windows/amd64
workflow: .github/workflows/release.yml
act_job_map:
  linux/amd64: build
  darwin/arm64: null
  windows/amd64: null
act_overrides:
  platform_image: catthehacker/ubuntu:full-22.04
act_matrix:
  "linux/amd64":
    os: ubuntu-latest
    target: linux/amd64
env:
  CGO_ENABLED: "0"
cross_compile:
  darwin/arm64:
    method: native
    env:
      GOOS: darwin
      GOARCH: arm64
EOF

mkdir -p "$TEMP_DIR/source-repo"
cat > "$ACT_REPOS_DIR/focrtest.yaml" << EOF
tool_name: focrtest
repo: Test/focrtest
local_path: $TEMP_DIR/source-repo
language: rust
binary_name: focr
build_cmd: cargo build --release
targets:
  - linux/amd64
  - linux/arm64
  - darwin/amd64
  - darwin/arm64
  - windows/amd64
  - windows/arm64
workflow: .github/workflows/release.yml
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: focr-x86_64-unknown-linux-gnu
    linux/arm64: focr-aarch64-unknown-linux-gnu
    darwin/amd64: focr-x86_64-apple-darwin
    darwin/arm64: focr-aarch64-apple-darwin-neon-sdot-i8mm
    windows/amd64: focr-x86_64-pc-windows-msvc.exe
    windows/arm64: focr-aarch64-pc-windows-msvc.exe
EOF

cat > "$ACT_REPOS_DIR/focrarchive.yaml" << EOF
tool_name: focrarchive
repo: Test/focrarchive
local_path: $TEMP_DIR/source-repo
language: rust
binary_name: focr
build_cmd: cargo build --release
targets:
  - linux/amd64
  - windows/amd64
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: focr-1.0.0-linux_amd64.tar.gz
    windows/amd64: focr-1.0.0-windows_amd64.zip
EOF

cat > "$ACT_REPOS_DIR/focrworkspace.yaml" << EOF
tool_name: focrworkspace
repo: Test/focrworkspace
local_path: $TEMP_DIR/source-repo
language: rust
binary_name: focr
build_cmd: cargo build --release --bins
targets:
  - linux/amd64
workspace_binaries:
  - focr
  - fw
include_files:
  - README.md
  - docs/NOTICE.txt
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: focrworkspace-1.0.0-linux_amd64.tar.gz
EOF

cat > "$ACT_REPOS_DIR/focrextra.yaml" << EOF
tool_name: focrextra
repo: Test/focrextra
local_path: $TEMP_DIR/source-repo
language: rust
binary_name: focr
build_cmd: cargo build --release
targets:
  - linux/amd64
workspace_additional_artifacts:
  linux/amd64:
    - name: supplemental.tar.xz
      format: tar.xz
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: focrextra-linux-amd64.tar.gz
  exact_additional_assets:
    - supplemental.tar.xz
EOF

echo "== act_get_build_cmd =="

# Test get_build_cmd
build_cmd=$(act_get_build_cmd "testool")
if [[ "$build_cmd" == 'echo "building testool"' ]]; then
    pass "act_get_build_cmd returns correct command"
else
    fail "act_get_build_cmd returned: $build_cmd"
fi

# Test missing tool
if ! act_get_build_cmd "nonexistent" &>/dev/null; then
    pass "act_get_build_cmd returns error for missing tool"
else
    fail "act_get_build_cmd should fail for missing tool"
fi

echo ""
echo "== act_get_build_env =="

# Test global env
env_vars=$(act_get_build_env "testool" "linux/amd64")
if [[ "$env_vars" == *"CGO_ENABLED=0"* ]]; then
    pass "act_get_build_env returns global env vars"
else
    fail "act_get_build_env missing global env: $env_vars"
fi

# Test platform-specific env
env_vars=$(act_get_build_env "testool" "darwin/arm64")
if [[ "$env_vars" == *"GOOS=darwin"* ]] && [[ "$env_vars" == *"GOARCH=arm64"* ]]; then
    pass "act_get_build_env returns platform-specific env vars"
else
    fail "act_get_build_env missing platform env: $env_vars"
fi

echo ""
echo "== act_get_local_path =="

local_path=$(act_get_local_path "testool")
if [[ "$local_path" == "/tmp/testool" ]]; then
    pass "act_get_local_path returns correct path"
else
    fail "act_get_local_path returned: $local_path"
fi

echo ""
echo "== act_get_flags (matrix) =="

matrix_flags=$(act_get_flags "testool" "linux/amd64")
if jq -e '. == ["-P", "ubuntu-latest=catthehacker/ubuntu:full-22.04",
    "--matrix", "os:ubuntu-latest", "--matrix", "target:linux/amd64"]' <<< "$matrix_flags" >/dev/null; then
    pass "act_get_flags includes platform image and matrix filters"
else
    fail "act_get_flags missing platform image or matrix filters: $matrix_flags"
fi

echo ""
echo "== act_get_build_strategy =="

# Test act strategy
strategy=$(act_get_build_strategy "testool" "linux/amd64")
method=$(echo "$strategy" | jq -r '.method')
job=$(echo "$strategy" | jq -r '.job')
if [[ "$method" == "act" ]] && [[ "$job" == "build" ]]; then
    pass "act_get_build_strategy returns act method for linux"
else
    fail "act_get_build_strategy returned: $strategy"
fi

# Test native strategy
strategy=$(act_get_build_strategy "testool" "darwin/arm64")
method=$(echo "$strategy" | jq -r '.method')
host=$(echo "$strategy" | jq -r '.host')
if [[ "$method" == "native" ]] && [[ "$host" == "mmini" ]]; then
    pass "act_get_build_strategy returns native method for darwin"
else
    fail "act_get_build_strategy returned: $strategy"
fi

mmini_probe_args=$(
    (
        _act_run_with_timeout() { printf '%s\n' "$*"; }
        _act_has_rsync "mmini"
    ) 2>/dev/null
)
if [[ "$mmini_probe_args" == *"ssh"* && "$mmini_probe_args" == *"mac-mini-max"* && \
      "$mmini_probe_args" != *" mmini "* ]]; then
    pass "mmini health probes use configured SSH destination mac-mini-max"
else
    fail "mmini health probe used the logical key instead of ssh_host: $mmini_probe_args"
fi

wlap_exec_args=$(
    (
        _act_run_with_timeout() { printf '%s\n' "$*"; }
        _act_ssh_exec "wlap" "echo ready" 30
    ) 2>/dev/null
)
if [[ "$wlap_exec_args" == *"ssh"* && "$wlap_exec_args" == *"surfacebookje"* && \
      "$wlap_exec_args" != *" wlap "* ]]; then
    pass "wlap remote commands use configured SSH destination surfacebookje"
else
    fail "wlap remote command used the logical key instead of ssh_host: $wlap_exec_args"
fi

echo ""
echo "== act_build_matrix =="

matrix=$(act_build_matrix "testool")
count=$(echo "$matrix" | jq 'length')
if [[ "$count" -eq 3 ]]; then
    pass "act_build_matrix returns all 3 targets"
else
    fail "act_build_matrix returned $count targets"
fi

echo ""
echo "== act_generate_manifest =="

# Test manifest generation
artifact_path="$TEMP_DIR/artifacts/testool-linux-amd64.tar.gz"
mkdir -p "$(dirname "$artifact_path")"
echo "dummy artifact" > "$artifact_path"

test_result=$(jq -nc --arg path "$artifact_path" '{
  tool: "testool",
  version: "v1.0.0",
  run_id: "550e8400-e29b-41d4-a716-446655440010",
  git_sha: "1111111111111111111111111111111111111111",
  git_ref: "v1.0.0",
  status: "success",
  summary: {total: 1, success: 1, failed: 0},
  targets: [
    {
      platform: "linux/amd64",
      host: "trj",
      method: "act",
      status: "success",
      artifact_path: $path,
      build_influence_env: {CARGO_TARGET_DIR: "/tmp/dsr-target"},
      cargo_isolation: {
        mode: "ephemeral-staged-source",
        source_boundary: "system-temporary-root-outside-user-home",
        cargo_home: "/tmp/dsr-build/cargo-home",
        target_dir: "/tmp/dsr-target",
        ancestor_config_policy: "detect-original-and-reject-staging",
        cache_reuse: ["registry", "git"]
      },
      duration_seconds: 10
    }
  ]
}')
manifest=$(act_generate_manifest "$test_result" "")
schema_ver=$(echo "$manifest" | jq -r '.schema_version')
artifacts_count=$(echo "$manifest" | jq '.artifacts | length')

if [[ "$schema_ver" == "1.0.0" ]] && [[ "$artifacts_count" -eq 1 ]] && \
   jq -e '
       .build_environments == [{
         target: "linux/amd64",
         host: "trj",
         method: "act",
         build_influence_env: {CARGO_TARGET_DIR: "/tmp/dsr-target"},
         cargo_isolation: {
           mode: "ephemeral-staged-source",
           source_boundary: "system-temporary-root-outside-user-home",
           cargo_home: "/tmp/dsr-build/cargo-home",
           target_dir: "/tmp/dsr-target",
           ancestor_config_policy: "detect-original-and-reject-staging",
           cache_reuse: ["registry", "git"]
         }
       }]' \
      <<< "$manifest" >/dev/null; then
    pass "act_generate_manifest records the effective build isolation boundary"
else
    fail "act_generate_manifest returned invalid manifest"
fi

# Regression: a matrix workflow under one act job emits the SAME set of
# cross-platform artifacts under multiple orchestration targets, and each
# matrix run lands them in its own per-target artifact_dir. So the manifest
# sees the same basename in multiple distinct paths, often with different
# content (each matrix run rebuilds, so SHAs drift slightly).
#
# Pre-fix, the path-based seen_paths dedup missed those (paths differ) and
# four orchestration iterations × four files each → 16 manifest entries with
# duplicate names + conflicting targets + conflicting SHAs. That cascaded
# into a SHA256SUMS that failed `sha256sum --check` on every collided name
# and into incorrect "target" labels in the manifest itself.
#
# Post-fix the basename-based dedup collapses the 16 to 4, and filename-
# inference labels each with the right canonical target.
mkdir -p "$TEMP_DIR/dup-artifacts/per-target/linux-amd64"
mkdir -p "$TEMP_DIR/dup-artifacts/per-target/linux-arm64"
mkdir -p "$TEMP_DIR/dup-artifacts/per-target/windows-amd64"
mkdir -p "$TEMP_DIR/dup-artifacts/per-target/darwin-arm64"

# Each per-target dir contains a full matrix output. Content varies per dir
# so SHAs differ — this is what defeats the path-based seen_paths dedup.
for d in linux-amd64 linux-arm64 windows-amd64 darwin-arm64; do
    base="$TEMP_DIR/dup-artifacts/per-target/$d"
    echo "linux-amd64-binary-from-$d"   > "$base/testool-v1.0.0-linux_amd64.tar.gz"
    echo "linux-arm64-binary-from-$d"   > "$base/testool-v1.0.0-linux_arm64.tar.gz"
    echo "darwin-arm64-binary-from-$d"  > "$base/testool-v1.0.0-darwin_arm64.tar.gz"
    echo "windows-amd64-binary-from-$d" > "$base/testool-v1.0.0-windows_amd64.tar.gz"
done

dup_result=$(jq -nc \
  --arg d_la "$TEMP_DIR/dup-artifacts/per-target/linux-amd64" \
  --arg d_lr "$TEMP_DIR/dup-artifacts/per-target/linux-arm64" \
  --arg d_w  "$TEMP_DIR/dup-artifacts/per-target/windows-amd64" \
  --arg d_d  "$TEMP_DIR/dup-artifacts/per-target/darwin-arm64" '{
  tool: "testool",
  version: "v1.0.0",
  run_id: "550e8400-e29b-41d4-a716-446655440011",
  git_sha: "1111111111111111111111111111111111111111",
  git_ref: "v1.0.0",
  status: "success",
  summary: {total: 4, success: 4, failed: 0},
  targets: [
    { platform: "linux/amd64",  host: "trj",   method: "act", status: "success", artifact_dir: $d_la },
    { platform: "linux/arm64",  host: "trj",   method: "act", status: "success", artifact_dir: $d_lr },
    { platform: "windows/amd64",host: "wlap",  method: "ssh", status: "success", artifact_dir: $d_w  },
    { platform: "darwin/arm64", host: "mmini", method: "ssh", status: "success", artifact_dir: $d_d  }
  ]
}')
dup_manifest=$(act_generate_manifest "$dup_result" "")
dup_total=$(echo "$dup_manifest" | jq '.artifacts | length')
dup_unique=$(echo "$dup_manifest" | jq '.artifacts | map(.name) | unique | length')

if [[ "$dup_total" -eq 4 ]] && [[ "$dup_unique" -eq 4 ]]; then
    pass "act_generate_manifest dedupes same-basename across distinct dirs (broken-v0.1.45 scenario)"
else
    fail "act_generate_manifest emitted $dup_total entries with $dup_unique unique names (expected 4/4)"
fi

# Critically: target labels must match the filename, not the orchestration-
# step target. Pre-fix, every artifact got the orchestration-step target
# attached (first iteration's "linux/amd64" for all four files).
linux_amd_target=$(echo "$dup_manifest" | jq -r '.artifacts[] | select(.name == "testool-v1.0.0-linux_amd64.tar.gz")   | .target')
linux_arm_target=$(echo "$dup_manifest" | jq -r '.artifacts[] | select(.name == "testool-v1.0.0-linux_arm64.tar.gz")   | .target')
windows_target=$(echo "$dup_manifest"   | jq -r '.artifacts[] | select(.name == "testool-v1.0.0-windows_amd64.tar.gz") | .target')
darwin_target=$(echo "$dup_manifest"    | jq -r '.artifacts[] | select(.name == "testool-v1.0.0-darwin_arm64.tar.gz")  | .target')

if [[ "$linux_amd_target" == "linux/amd64" ]] && \
   [[ "$linux_arm_target" == "linux/arm64" ]] && \
   [[ "$windows_target"   == "windows/amd64" ]] && \
   [[ "$darwin_target"    == "darwin/arm64" ]]; then
    pass "act_generate_manifest infers target from filename when matrix-shared"
else
    fail "act_generate_manifest mislabeled targets: linux_amd=$linux_amd_target linux_arm=$linux_arm_target windows=$windows_target darwin=$darwin_target"
fi

# The musl filename keeps the scheduling platform "linux/<arch>", while
# target_triple preserves its configured libc identity in the receipt.
mkdir -p "$TEMP_DIR/musl"
echo "musl-amd64-binary" > "$TEMP_DIR/musl/testool-v1.0.0-linux_musl_amd64.tar.gz"
musl_result=$(jq -nc --arg dir "$TEMP_DIR/musl" '{
  tool: "testool", version: "v1.0.0", run_id: "550e8400-e29b-41d4-a716-446655440012",
  git_sha: "1111111111111111111111111111111111111111", git_ref: "v1.0.0",
  status: "success", summary: {total: 1, success: 1, failed: 0},
  targets: [{ platform: "linux/amd64", host: "trj", method: "act", status: "success", artifact_dir: $dir }]
}')
musl_status=0
musl_manifest=$(act_generate_manifest "$musl_result" "" \
    2> "$TEMP_DIR/musl-unconfigured.stderr") || musl_status=$?
if [[ "$musl_status" -eq 4 && -z "$musl_manifest" ]] && \
   grep -Fq 'unconfigured target variant' "$TEMP_DIR/musl-unconfigured.stderr"; then
    pass "act_generate_manifest refuses musl under the default GNU-only configuration"
else
    fail "act_generate_manifest admitted an unconfigured musl variant (status $musl_status)"
fi

# Isolate the explicit variant policy so the remaining testool build and
# orchestration fixtures retain their own unchanged configuration.
yq '.tool_name="musltestool" |
    .target_triples."linux/amd64"=["x86_64-unknown-linux-gnu","x86_64-unknown-linux-musl"]' \
    "$ACT_REPOS_DIR/testool.yaml" > "$ACT_REPOS_DIR/musltestool.yaml"
musl_result=$(jq '.tool="musltestool"' <<< "$musl_result")
musl_status=0
musl_manifest=$(act_generate_manifest "$musl_result" "") || musl_status=$?
musl_target=$(jq -r '.artifacts[0].target' <<< "$musl_manifest")
musl_triple=$(jq -r '.artifacts[0].target_triple' <<< "$musl_manifest")

if [[ "$musl_status" -eq 0 && "$musl_target" == "linux/amd64" && \
      "$musl_triple" == "x86_64-unknown-linux-musl" ]]; then
    pass "act_generate_manifest maps configured musl to linux/amd64 with its explicit target_triple"
else
    fail "act_generate_manifest mapped configured musl to '$musl_target' / '$musl_triple' (status $musl_status)"
fi

echo ""
echo "== bounded parallel orchestration and resume =="

if rg 'running_worker_pids=\$\(jobs -pr\)' "$SCRIPT_DIR/src/act_runner.sh" >/dev/null &&
   rg 'grep -Fqx "\$reap_pid"' "$SCRIPT_DIR/src/act_runner.sh" >/dev/null &&
   ! rg 'kill -0 "\$reap_pid"' "$SCRIPT_DIR/src/act_runner.sh" >/dev/null; then
    pass "worker reaping uses the shell job table instead of PID liveness"
else
    fail "worker reaping can hang on an exited child or a reused PID"
fi

comma_artifact="$TEMP_DIR/resume,artifact"
printf 'comma-safe artifact\n' > "$comma_artifact"
comma_result=$(jq -nc --arg path "$comma_artifact" '
    {status: "success", artifact_path: $path, artifact_paths: [$path]}
')
comma_receipts=$(_act_result_artifact_receipts "$comma_result")
comma_frozen_result=$(jq -c --argjson receipts "$comma_receipts" \
    '.resume_artifacts = $receipts' <<< "$comma_result")
if [[ "$(jq -r 'length' <<< "$comma_receipts")" -eq 1 ]] &&
   [[ "$(jq -r '.[0].path' <<< "$comma_receipts")" == "$comma_artifact" ]] &&
   _act_target_result_available "$comma_frozen_result"; then
    pass "resume receipts preserve comma-containing paths from the authoritative array"
else
    fail "resume receipt parsing split an authoritative comma-containing path"
fi

duplicate_status=0
duplicate_result=$(
    (
        build_lock_acquire() { return 0; }
        build_lock_release() { return 0; }
        act_run_native_build() { return 99; }
        act_orchestrate_build "testool" "v-duplicate" -- \
            linux/amd64 linux/amd64
    ) 2>/dev/null
) || duplicate_status=$?
if [[ "$duplicate_status" -eq 4 ]] &&
   jq -e '.status == "error" and (.error | contains("Duplicate"))' \
      <<< "$duplicate_result" &>/dev/null; then
    pass "orchestration rejects duplicate targets before launching workers"
else
    fail "orchestration accepted duplicate targets: status=$duplicate_status result=$duplicate_result"
fi

parallel_root="$TEMP_DIR/parallel-orchestration"
parallel_output="$parallel_root/output"
parallel_timeline="$parallel_root/timeline"
parallel_log="$parallel_root/orchestration.log"
mkdir -p "$parallel_output" "$parallel_timeline"

parallel_status=0
parallel_result=$(
    (
        build_lock_acquire() { return 0; }
        build_lock_release() { return 0; }
        unset -f selector_acquire_slot selector_release_slot
        act_platform_uses_act() { return 1; }
        act_get_native_host() { printf 'host-%s\n' "${1//\//-}"; }
        act_run_native_build() {
            local target="$2" slug="${2//\//-}"
            local artifact="$parallel_output/$slug"
            printf '%s\n' "$(date +%s%N)" > "$parallel_timeline/$slug.start"
            printf 'call\n' >> "$parallel_timeline/$slug.calls"
            case "$target" in
                linux/amd64)
                    local deadline=$((SECONDS + 30)) observed_third=false
                    while (( SECONDS < deadline )); do
                        if [[ -f "$parallel_timeline/windows-amd64.start" ]]; then
                            observed_third=true
                            break
                        fi
                        sleep 0.05
                    done
                    printf '%s\n' "$observed_third" > "$parallel_timeline/linux-amd64.observed-third"
                    ;;
                darwin/arm64) sleep 0.25 ;;
                *)            sleep 0.15 ;;
            esac
            printf 'artifact %s\n' "$target" > "$artifact"
            printf '%s\n' "$(date +%s%N)" > "$parallel_timeline/$slug.end"
            jq -nc --arg platform "$target" --arg path "$artifact" --arg host "$8" '
                {platform: $platform, method:"native", host:$host, status: "success", exit_code: 0,
                 artifact_path: $path, artifact_paths: [$path]}'
        }
        act_orchestrate_build "testool" "v-parallel" \
            --parallel-jobs 2 --output-dir "$parallel_output" -- \
            linux/amd64 darwin/arm64 windows/amd64
    ) 2> "$parallel_log"
) || parallel_status=$?

parallel_max=0
third_start=""
earliest_finish=""
long_first_finish=""
long_first_observed_third=""
if [[ -f "$parallel_timeline/linux-amd64.start" &&
      -f "$parallel_timeline/darwin-arm64.start" &&
      -f "$parallel_timeline/windows-amd64.start" &&
      -f "$parallel_timeline/linux-amd64.end" &&
      -f "$parallel_timeline/darwin-arm64.end" &&
      -f "$parallel_timeline/windows-amd64.end" ]]; then
    parallel_max=$(awk '
        FILENAME ~ /[.]start$/ {events[++n]=$1 " +1"}
        FILENAME ~ /[.]end$/   {events[++n]=$1 " -1"}
        END {
          for (i=1; i<=n; i++) for (j=i+1; j<=n; j++)
            if ((events[i]+0) > (events[j]+0)) {t=events[i]; events[i]=events[j]; events[j]=t}
          active=0; max=0
          for (i=1; i<=n; i++) {split(events[i], p, " "); active += p[2]; if (active>max) max=active}
          print max
        }
    ' "$parallel_timeline"/*.start "$parallel_timeline"/*.end)
    third_start=$(< "$parallel_timeline/windows-amd64.start")
    first_finish=$(< "$parallel_timeline/linux-amd64.end")
    second_finish=$(< "$parallel_timeline/darwin-arm64.end")
    long_first_finish="$first_finish"
    if [[ -f "$parallel_timeline/linux-amd64.observed-third" ]]; then
        long_first_observed_third=$(< "$parallel_timeline/linux-amd64.observed-third")
    fi
    earliest_finish="$first_finish"
    [[ "$second_finish" -lt "$earliest_finish" ]] && earliest_finish="$second_finish"
fi
parallel_run_id=$(jq -r '.run_id // empty' <<< "$parallel_result")
parallel_state_status=""
if [[ -n "$parallel_run_id" ]]; then
    parallel_state_status=$(build_state_get "testool" "v-parallel" "$parallel_run_id" 2>/dev/null |
        jq -r '.status // empty')
fi

if [[ $parallel_status -eq 0 && "$parallel_max" -eq 2 &&
      "$third_start" =~ ^[0-9]+$ && "$earliest_finish" =~ ^[0-9]+$ &&
      "$third_start" -ge "$earliest_finish" &&
      "$long_first_finish" =~ ^[0-9]+$ && "$third_start" -lt "$long_first_finish" &&
      "$long_first_observed_third" == true &&
      "$parallel_state_status" == "targets-complete" ]] &&
   jq -e '
      .status == "success" and .summary == {total: 3, success: 3, failed: 0} and
      [.targets[].platform] == ["linux/amd64", "darwin/arm64", "windows/amd64"] and
      ([.targets[].log_path] | length == 3 and length == (unique | length))
   ' <<< "$parallel_result" &>/dev/null; then
    pass "parallel orchestration is work-conserving, respects bound=2, and aggregates in target order"
else
    fail "parallel orchestration bound/order mismatch: status=$parallel_status max=$parallel_max state=$parallel_state_status result=$parallel_result"
    tail -20 "$parallel_log" >&2 || true
fi

contradictory_root="$TEMP_DIR/contradictory-orchestration"
contradictory_output="$contradictory_root/output"
contradictory_log="$contradictory_root/orchestration.log"
mkdir -p "$contradictory_output"
contradictory_status=0
contradictory_result=$(
    (
        build_lock_acquire() { return 0; }
        build_lock_release() { return 0; }
        unset -f selector_acquire_slot selector_release_slot
        act_platform_uses_act() { return 1; }
        act_get_native_host() { printf 'host-%s\n' "${1//\//-}"; }
        act_run_native_build() {
            local target="$2" artifact="$contradictory_output/claimed-success"
            printf 'untrusted output\n' > "$artifact"
            jq -nc --arg platform "$target" --arg path "$artifact" --arg host "$8" '
                {platform: $platform, method:"native", host:$host, status: "success", exit_code: 0,
                 artifact_path: $path, artifact_paths: [$path]}'
            return 9
        }
        act_orchestrate_build "testool" "v-contradictory" \
            --parallel-jobs 1 --output-dir "$contradictory_output" -- linux/amd64
    ) 2> "$contradictory_log"
) || contradictory_status=$?
if [[ "$contradictory_status" -eq 6 ]] &&
   jq -e '
      .status == "failed" and .summary == {total: 1, success: 0, failed: 1} and
      .targets[0].status == "failed" and .targets[0].exit_code == 9 and
      (.targets[0].error | contains("nonzero"))
   ' <<< "$contradictory_result" &>/dev/null; then
    pass "nonzero worker exit overrides contradictory success JSON"
else
    fail "orchestration trusted contradictory success JSON: status=$contradictory_status result=$contradictory_result"
    tail -20 "$contradictory_log" >&2 || true
fi

resume_root="$TEMP_DIR/resume-orchestration"
resume_output="$resume_root/output"
resume_calls="$resume_root/calls"
resume_first_log="$resume_root/first.log"
resume_second_log="$resume_root/second.log"
mkdir -p "$resume_output" "$resume_calls"
resume_first_status=0
resume_first=$(
    (
        build_lock_acquire() { return 0; }
        build_lock_release() { return 0; }
        unset -f selector_acquire_slot selector_release_slot
        act_platform_uses_act() { return 1; }
        act_get_native_host() { printf 'host-%s\n' "${1//\//-}"; }
        act_run_native_build() {
            local target="$2" slug="${2//\//-}"
            local native_log="$ACT_LOGS_DIR/testool-${slug}-${4}.log"
            printf 'first attempt source %s\n' "$4" > "$native_log"
            printf 'call\n' >> "$resume_calls/$slug"
            if [[ "$target" == "darwin/arm64" ]]; then
                jq -nc --arg platform "$target" --arg log "$native_log" \
                    '{platform: $platform, status: "failed", exit_code: 9, error: "fixture failure",log_file:$log}'
                return 9
            fi
            local artifact="$resume_output/$slug"
            printf 'artifact %s\n' "$target" > "$artifact"
            jq -nc --arg platform "$target" --arg path "$artifact" --arg host "$8" '
                {platform: $platform, method:"native", host:$host, status: "success", exit_code: 0,
                 artifact_path: $path, artifact_paths: [$path]}'
        }
        act_orchestrate_build "testool" "v-resume" \
            --parallel-jobs 3 --output-dir "$resume_output" -- \
            linux/amd64 darwin/arm64 windows/amd64
    ) 2> "$resume_first_log"
) || resume_first_status=$?
resume_run_id=$(jq -r '.run_id // empty' <<< "$resume_first")
resume_first_native_log=$(jq -r '.targets[] | select(.platform == "darwin/arm64") | .log_file' <<< "$resume_first")
resume_first_native_hash=$(_act_sha256 "$resume_first_native_log")

# A completed target is reusable only while its artifact bytes and filesystem
# identity still match the immutable receipt. Mutate one successful artifact so
# resume must rebuild it alongside the originally failed target.
printf 'mutated after receipt\n' > "$resume_output/linux-amd64"

resume_second_status=0
resume_second=$(
    (
        build_lock_acquire() { return 0; }
        build_lock_release() { return 0; }
        unset -f selector_acquire_slot selector_release_slot
        act_platform_uses_act() { return 1; }
        act_get_native_host() { printf 'host-%s\n' "${1//\//-}"; }
        act_run_native_build() {
            local target="$2" slug="${2//\//-}"
            local native_log="$ACT_LOGS_DIR/testool-${slug}-${4}.log"
            printf 'second attempt source %s\n' "$4" > "$native_log"
            printf 'call\n' >> "$resume_calls/$slug"
            local artifact="$resume_output/$slug"
            printf 'artifact %s\n' "$target" > "$artifact"
            jq -nc --arg platform "$target" --arg path "$artifact" --arg log "$native_log" --arg host "$8" '
                {platform: $platform, method:"native", host:$host, status: "success", exit_code: 0,
                 artifact_path: $path, artifact_paths: [$path],log_file:$log}'
        }
        act_orchestrate_build "testool" "v-resume" \
            --resume-run-id "$resume_run_id" --parallel-jobs 2 \
            --output-dir "$resume_output" -- \
            linux/amd64 darwin/arm64 windows/amd64
    ) 2> "$resume_second_log"
) || resume_second_status=$?

linux_calls=0
darwin_calls=0
windows_calls=0
[[ -f "$resume_calls/linux-amd64" ]] && linux_calls=$(wc -l < "$resume_calls/linux-amd64")
[[ -f "$resume_calls/darwin-arm64" ]] && darwin_calls=$(wc -l < "$resume_calls/darwin-arm64")
[[ -f "$resume_calls/windows-amd64" ]] && windows_calls=$(wc -l < "$resume_calls/windows-amd64")
resume_state_status=""
if [[ -n "$resume_run_id" ]]; then
    resume_state_status=$(build_state_get "testool" "v-resume" "$resume_run_id" 2>/dev/null |
        jq -r '.status // empty')
fi
if [[ $resume_first_status -eq 1 && $resume_second_status -eq 0 && \
      "$linux_calls" -eq 2 && "$darwin_calls" -eq 2 && "$windows_calls" -eq 1 &&
      "$resume_state_status" == "targets-complete" ]] &&
   jq -e --arg run_id "$resume_run_id" '
      .run_id == $run_id and .status == "success" and
      .summary == {total: 3, success: 3, failed: 0} and
      [.targets[].platform] == ["linux/amd64", "darwin/arm64", "windows/amd64"] and
      (.targets[0].resume_reused != true) and (.targets[1].resume_reused != true) and
      (.targets[2].resume_reused == true)
   ' <<< "$resume_second" &>/dev/null; then
    pass "resume reuses exact receipts and rebuilds failed or mutated targets"
else
    fail "resume replay mismatch: first=$resume_first_status second=$resume_second_status calls=$linux_calls/$darwin_calls/$windows_calls state=$resume_state_status result=$resume_second"
    tail -20 "$resume_first_log" >&2 || true
    tail -20 "$resume_second_log" >&2 || true
fi

resume_second_native_log=$(jq -r '.targets[] | select(.platform == "darwin/arm64") | .log_file' <<< "$resume_second")
if [[ "$resume_first_native_log" != "$resume_second_native_log" &&
      "$(_act_sha256 "$resume_first_native_log")" == "$resume_first_native_hash" &&
      "$(cat "$resume_first_native_log")" == "first attempt source $resume_run_id" &&
      "$(cat "$resume_second_native_log")" == "second attempt source $resume_run_id" ]]; then
    pass "native retries preserve old log bytes and keep the exact source run UUID"
else
    fail "native retry changed the prior log or source run UUID"
fi

if (
    occupied_log="$TEMP_DIR/occupied-attempt.log"
    occupied_result="$TEMP_DIR/occupied-attempt.json"
    occupied_calls="$TEMP_DIR/occupied-attempt-calls"
    mkdir "${occupied_log%.log}.native"
    printf 'retained native evidence\n' > "${occupied_log%.log}.native/keep.log"
    act_platform_uses_act() { return 1; }
    act_get_native_host() { printf 'fixture-native\n'; }
    act_run_native_build() { printf 'unexpected invocation\n' > "$occupied_calls"; return 99; }
    occupied_status=0
    _act_run_target_worker testool v1 22222222-2222-4222-8222-222222222222 windows/amd64 2 \
        "$occupied_log" "$occupied_result" false null '{}' '' '' fixture-native release || occupied_status=$?
    [[ "$occupied_status" -eq 4 && ! -e "$occupied_calls" &&
       "$(cat "${occupied_log%.log}.native/keep.log")" == 'retained native evidence' ]] &&
        jq -e '.status == "failed" and .exit_code == 4 and
            .error == "Native attempt log directory already exists or is unavailable"' "$occupied_result" >/dev/null
) 2>/dev/null; then
    pass "existing native attempt log directory refuses launch without changing evidence"
else
    fail "existing native attempt log directory did not protect retained evidence"
fi

cancel_root="$TEMP_DIR/cancel-orchestration"
cancel_output="$cancel_root/output"
cancel_markers="$cancel_root/markers"
cancel_result_file="$cancel_root/result.json"
cancel_log="$cancel_root/orchestration.log"
mkdir -p "$cancel_output" "$cancel_markers"

(
    build_lock_acquire() { return 0; }
    build_lock_release() { return 0; }
    unset -f selector_acquire_slot selector_release_slot
    act_platform_uses_act() { return 1; }
    act_get_native_host() { printf 'host-%s\n' "${1//\//-}"; }
    act_run_native_build() {
        local target="$2" slug="${2//\//-}" child_pid
        sleep 300 &
        child_pid=$!
        printf '%s\n' "$child_pid" > "$cancel_markers/$slug.pid"
        wait "$child_pid"
    }
    act_orchestrate_build "testool" "v-cancel" \
        --parallel-jobs 2 --output-dir "$cancel_output" -- \
        linux/amd64 darwin/arm64
) > "$cancel_result_file" 2> "$cancel_log" &
cancel_coordinator_pid=$!

for _ in {1..100}; do
    marker_count=$(find "$cancel_markers" -type f -name '*.pid' 2>/dev/null | wc -l)
    [[ "$marker_count" -eq 2 ]] && break
    sleep 0.05
done

kill -TERM "$cancel_coordinator_pid" 2>/dev/null || true
cancel_status=0
wait "$cancel_coordinator_pid" || cancel_status=$?
cancel_result=$(grep '^{.*}$' "$cancel_result_file" | tail -1)
cancel_run_id=$(jq -r '.run_id // empty' <<< "$cancel_result" 2>/dev/null || true)
cancel_state_status=""
if [[ -n "$cancel_run_id" ]]; then
    cancel_state_status=$(build_state_get "testool" "v-cancel" "$cancel_run_id" 2>/dev/null |
        jq -r '.status // empty')
fi
cancel_children_stopped=true
while IFS= read -r marker; do
    child_pid=$(< "$marker")
    if [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$child_pid" 2>/dev/null; then
        cancel_children_stopped=false
    fi
done < <(find "$cancel_markers" -type f -name '*.pid' 2>/dev/null)

if [[ "$marker_count" -eq 2 && "$cancel_status" -eq 130 &&
      "$cancel_state_status" == "failed" && "$cancel_children_stopped" == true ]] &&
   jq -e '
      .status == "failed" and .exit_code == 130 and
      .summary == {total: 2, success: 0, failed: 2}
   ' <<< "$cancel_result" &>/dev/null; then
    pass "cancellation returns 130, persists failure, and terminates descendant builds"
else
    fail "cancellation mismatch: markers=$marker_count status=$cancel_status state=$cancel_state_status children_stopped=$cancel_children_stopped result=$cancel_result"
    tail -30 "$cancel_log" >&2 || true
fi

echo ""
echo "== strict release contract =="

write_minimal_target_binary() {
    local path="$1"
    local target="$2"
    local machine

    case "$target" in
        linux/amd64|linux/arm64)
            machine='\x3e\x00'
            [[ "$target" == "linux/arm64" ]] && machine='\xb7\x00'
            printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00%b' "$machine" > "$path"
            printf '\x00%.0s' {1..44} >> "$path"
            chmod +x "$path"
            ;;
        darwin/amd64|darwin/arm64)
            machine='\x07\x00\x00\x01'
            [[ "$target" == "darwin/arm64" ]] && machine='\x0c\x00\x00\x01'
            printf '\xcf\xfa\xed\xfe%b\x00\x00\x00\x00\x02\x00\x00\x00' "$machine" > "$path"
            printf '\x00%.0s' {1..16} >> "$path"
            chmod +x "$path"
            ;;
        windows/amd64|windows/arm64)
            machine='\x64\x86'
            [[ "$target" == "windows/arm64" ]] && machine='\x64\xaa'
            printf 'MZ' > "$path"
            printf '\x00%.0s' {1..58} >> "$path"
            printf '\x40\x00\x00\x00PE\x00\x00%b' "$machine" >> "$path"
            printf '\x00%.0s' {1..18} >> "$path"
            printf '\x0b\x02' >> "$path"
            ;;
        *)
            return 4
            ;;
    esac
}

with_collection_receipt() {
    local result_json="$1"
    local source_path="$2"
    local sha size identity
    sha=$(_act_sha256 "$source_path") || return 4
    size=$(_act_file_size "$source_path") || return 4
    identity=$(_act_file_identity "$source_path") || return 4
    jq -c \
        --arg sha "$sha" \
        --argjson size "$size" \
        --arg identity "$identity" '
        .collected_sha256 = $sha |
        .collected_size_bytes = $size |
        .collected_identity = $identity
    ' <<< "$result_json"
}

contract_sha="2222222222222222222222222222222222222222"
contract_ref="v1.0.0"
contract_target_hosts=$(config_get_release_contract_json "focrtest" | \
    jq -c '.exact_primary_assets | with_entries(.value = "stub-host")')
contract_raw_root="$TEMP_DIR/contract-raw"
mkdir -p "$contract_raw_root/shared-evidence"
printf '{"kind":"build-evidence"}\n' > "$contract_raw_root/shared-evidence/evidence.json"
printf 'unrelated matrix output\n' > "$contract_raw_root/shared-evidence/other-target-primary"
for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64 windows/arm64; do
    target_slug="${target//\//-}"
    raw_name="focr"
    [[ "$target" == windows/* ]] && raw_name="focr.exe"
    mkdir -p "$contract_raw_root/$target_slug"
    write_minimal_target_binary "$contract_raw_root/$target_slug/$raw_name" "$target"
done

missing_source_status=0
missing_source_result=$(
    (
        act_run_workflow() { return 99; }
        act_run_native_build() { return 99; }
        act_orchestrate_build "focrtest" "v1.0.0"
    ) 2>/dev/null
) || missing_source_status=$?
if [[ $missing_source_status -eq 4 ]] && \
   echo "$missing_source_result" | jq -e '.status == "error" and (.error | contains("source identity"))' &>/dev/null; then
    pass "strict orchestration rejects missing source identity before builds"
else
    fail "strict orchestration accepted missing source identity: status=$missing_source_status result=$missing_source_result"
fi

zero_source_status=0
zero_source_result=$(
    (
        act_run_workflow() { return 99; }
        act_run_native_build() { return 99; }
        act_orchestrate_build "focrtest" "v1.0.0" \
            --git-sha "0000000000000000000000000000000000000000" --git-ref "$contract_ref"
    ) 2>/dev/null
) || zero_source_status=$?
if [[ $zero_source_status -eq 4 ]] && echo "$zero_source_result" | jq -e '.status == "error"' &>/dev/null; then
    pass "strict orchestration rejects an all-zero source SHA before builds"
else
    fail "strict orchestration accepted an all-zero source SHA"
fi

for dirty_case in tracked untracked; do
    dirty_line=' M src/lib.rs'
    [[ "$dirty_case" == "untracked" ]] && dirty_line='?? untracked-release-input'
    dirty_source_status=0
    dirty_source_result=$(
        (
            git() {
                case "$*" in
                    *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                        printf '%s\n' "$contract_sha"
                        ;;
                    *"status --porcelain --untracked-files=all"*) printf '%s\n' "$dirty_line" ;;
                    *) return 1 ;;
                esac
            }
            act_run_workflow() { return 99; }
            act_run_native_build() { return 99; }
            act_orchestrate_build "focrtest" "v1.0.0" \
                --git-sha "$contract_sha" --git-ref "$contract_ref"
        ) 2>/dev/null
    ) || dirty_source_status=$?
    if [[ $dirty_source_status -eq 4 ]] && echo "$dirty_source_result" | jq -e '.status == "error"' &>/dev/null; then
        pass "strict orchestration rejects $dirty_case source-tree dirtiness before builds"
    else
        fail "strict orchestration accepted $dirty_case source-tree dirtiness"
    fi
done

noncanonical_root_status=0
noncanonical_root_result=$(
    (
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        act_platform_uses_act() { return 1; }
        act_get_native_host() { printf 'stub-host\n'; }
        act_run_native_build() { return 99; }
        act_orchestrate_build "focrtest" "v1.0.0" \
            --git-sha "$contract_sha" --git-ref "$contract_ref" \
            --run-id "550e8400-e29b-41d4-a716-446655440029" \
            --source-roots-json '{"stub-host":"/tmp/caller-chosen-root"}' \
            --target-hosts-json "$contract_target_hosts"
    ) 2>/dev/null
) || noncanonical_root_status=$?
if [[ $noncanonical_root_status -eq 4 ]] && \
   echo "$noncanonical_root_result" | jq -e '.status == "error"' &>/dev/null; then
    pass "strict orchestration rejects caller-chosen noncanonical source roots before builds"
else
    fail "strict orchestration accepted a noncanonical source root"
fi

contract_run_id="550e8400-e29b-41d4-a716-446655440030"
contract_source_root=$(_act_strict_source_root_path \
    "$TEMP_DIR/source-repo" "focrtest" "$contract_run_id")
contract_source_roots=$(jq -nc --arg path "$contract_source_root" '{"stub-host": $path}')
contract_selector_log="$TEMP_DIR/strict-selector-drift.log"
contract_slot_log="$TEMP_DIR/strict-host-slots.log"
contract_result=$(
    (
        build_lock_acquire() { return 0; }
        build_lock_release() { return 0; }

        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        act_platform_uses_act() { return 1; }
        act_get_native_host() { printf 'selected\n' >> "$contract_selector_log"; printf 'unsynced-host\n'; }
        selector_acquire_slot() { printf '%s\n' "$1" >> "$contract_slot_log"; }
        selector_release_slot() { return 0; }
        _act_validate_strict_cargo_source_closure() { return 0; }
        _act_verify_strict_source_roots() { return 0; }
        act_run_native_build() {
            local target="$2"
            local remote_override="$5"
            local release_git_sha="$6"
            local release_git_ref="$7"
            [[ "${8:-}" == "stub-host" ]] || return 99
            local target_slug="${target//\//-}"
            local raw_name="focr"
            [[ "$target" == windows/* ]] && raw_name="focr.exe"
            local raw_path="$contract_raw_root/$target_slug/$raw_name"
            local native_result
            native_result=$(jq -nc \
                --arg platform "$target" \
                --arg path "$raw_path" \
                --arg dir "$contract_raw_root/shared-evidence" \
                --arg remote_override "$remote_override" \
                --arg release_git_sha "$release_git_sha" \
                --arg release_git_ref "$release_git_ref" \
                '{
                    platform: $platform,
                    host: "stub-host",
                    method: "native",
                    status: "success",
                    exit_code: 0,
                    duration_seconds: 1,
                    artifact_path: $path,
                    artifact_paths: [$path],
                    artifact_dir: $dir,
                    observed_remote_path: $remote_override,
                    observed_release_git_sha: $release_git_sha,
                    observed_release_git_ref: $release_git_ref
                }')
            native_result=$(_fixture_strict_rust_result "$native_result" \
                "$release_git_sha" "$release_git_ref" "$remote_override") || return 4
            with_collection_receipt "$native_result" "$raw_path"
        }

        act_orchestrate_build "focrtest" "v1.0.0" \
            --git-sha "$contract_sha" --git-ref "$contract_ref" \
            --run-id "$contract_run_id" \
            --source-roots-json "$contract_source_roots" \
            --target-hosts-json "$contract_target_hosts"
    ) 2>/dev/null
)

if echo "$contract_result" | jq -e \
    --arg sha "$contract_sha" --arg ref "$contract_ref" --arg source_root "$contract_source_root" '
        .status == "success" and
        .git_sha == $sha and
        .git_ref == $ref and
        (.run_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
        .source_dependencies == [] and
        .summary == {total: 6, success: 6, failed: 0} and
        (.targets | length) == 6 and
        all(.targets[];
            .observed_remote_path == $source_root and
            .observed_release_git_sha == $sha and
            .observed_release_git_ref == $ref)
    ' &>/dev/null; then
    pass "strict orchestration passes supplied source identity to all 6 native builds"
else
    fail "strict orchestration source/summary mismatch: $contract_result"
fi

contract_state=$(build_state_get "focrtest" "v1.0.0" "$contract_run_id")
if [[ ! -e "$contract_selector_log" && -f "$contract_slot_log" ]] && \
   [[ "$(wc -l < "$contract_slot_log" | tr -d ' ')" -eq 6 ]] && \
   [[ "$(sort -u "$contract_slot_log")" == "stub-host" ]] && \
   jq -e --argjson hosts "$contract_target_hosts" --argjson roots "$contract_source_roots" \
       '.context.target_hosts == $hosts and .context.source_roots == $roots' \
       <<< "$contract_state" >/dev/null; then
    pass "strict scheduling, slots, native execution, and persisted resume share the synchronized host binding"
else
    fail "strict source binding was reselected or lost from persisted state"
fi

for binding_case in absent malformed missing-target extra-target missing-root changed-resume-host legacy-resume; do
    binding_hosts="$contract_target_hosts"
    binding_roots="$contract_source_roots"
    binding_resume_args=()
    case "$binding_case" in
        absent) binding_hosts='{}' ;;
        malformed) binding_hosts='[]' ;;
        missing-target) binding_hosts=$(jq -c 'del(."linux/amd64")' <<< "$binding_hosts") ;;
        extra-target) binding_hosts=$(jq -c '. + {"extra/target":"stub-host"}' <<< "$binding_hosts") ;;
        missing-root) binding_roots='{}' ;;
        changed-resume-host|legacy-resume) binding_resume_args=(--resume-run-id "$contract_run_id") ;;
    esac
    binding_sentinel="$TEMP_DIR/strict-binding-$binding_case-reached-worker"
    binding_error_log="$TEMP_DIR/strict-binding-$binding_case-error.log"
    binding_status=0
    (
        _act_validate_contract_source_identity() { return 0; }
        _act_validate_strict_cargo_source_closure() { return 0; }
        _act_verify_strict_source_roots() { return 0; }
        act_platform_uses_act() { return 1; }
        act_get_native_host() { printf 'selected\n' > "$binding_sentinel"; printf 'unsynced-host\n'; }
        _act_run_target_worker() { printf 'worker\n' > "$binding_sentinel"; return 99; }
        build_lock_acquire() { return 0; }
        build_lock_release() { return 0; }
        if [[ "$binding_case" == "changed-resume-host" || "$binding_case" == "legacy-resume" ]]; then
            build_state_get() {
                if [[ "$binding_case" == "legacy-resume" ]]; then
                    jq -c 'del(.context.target_hosts)' <<< "$contract_state"
                else
                    jq -c '.context.target_hosts["linux/amd64"] = "other-host"' <<< "$contract_state"
                fi
            }
        fi
        act_orchestrate_build "focrtest" "v1.0.0" \
            --git-sha "$contract_sha" --git-ref "$contract_ref" \
            --run-id "$contract_run_id" --source-roots-json "$binding_roots" \
            --target-hosts-json "$binding_hosts" "${binding_resume_args[@]}"
    ) >/dev/null 2> "$binding_error_log" || binding_status=$?
    binding_reason_matches=true
    if [[ "$binding_case" == "changed-resume-host" || "$binding_case" == "legacy-resume" ]]; then
        grep -Fq "Resume target hosts do not match the strict snapshot" "$binding_error_log" || binding_reason_matches=false
    fi
    if [[ "$binding_status" -eq 4 && ! -e "$binding_sentinel" && "$binding_reason_matches" == true ]]; then
        pass "strict $binding_case is rejected before selection or worker launch"
    else
        fail "strict $binding_case admitted unsynchronized source authority: status=$binding_status"
    fi
done

strict_resume_status=0
strict_resume_result=$(
    _act_validate_contract_source_identity() { return 0; }
    _act_validate_strict_cargo_source_closure() { return 0; }
    _act_verify_strict_source_roots() { return 0; }
    act_platform_uses_act() { return 1; }
    act_get_native_host() { printf 'selected\n' >> "$contract_selector_log"; printf 'unsynced-host\n'; }
    _act_run_target_worker() { printf 'worker\n' >> "$contract_selector_log"; return 99; }
    build_lock_acquire() { return 0; }
    build_lock_release() { return 0; }
    act_orchestrate_build "focrtest" "v1.0.0" --resume-run-id "$contract_run_id" \
        --git-sha "$contract_sha" --git-ref "$contract_ref" \
        --run-id "$contract_run_id" --source-roots-json "$contract_source_roots" \
        --target-hosts-json "$contract_target_hosts"
) || strict_resume_status=$?
if [[ "$strict_resume_status" -eq 0 && ! -e "$contract_selector_log" ]] && \
   jq -e '.status == "success" and (.targets | length) == 6 and all(.targets[]; .resume_reused == true)' \
       <<< "$strict_resume_result" >/dev/null; then
    pass "strict resume reuses all six verified targets without reselecting a source host"
else
    fail "strict resume lost its frozen source binding: status=$strict_resume_status result=$strict_resume_result"
fi

for worker_binding_case in missing-host missing-root; do
    worker_binding_host="stub-host"
    worker_binding_roots="$contract_source_roots"
    [[ "$worker_binding_case" != "missing-host" ]] || worker_binding_host=""
    [[ "$worker_binding_case" != "missing-root" ]] || worker_binding_roots='{}'
    worker_binding_sentinel="$TEMP_DIR/worker-$worker_binding_case-side-effect"
    worker_binding_result="$TEMP_DIR/worker-$worker_binding_case-result.json"
    worker_binding_status=0
    (
        act_get_native_host() { printf 'selected\n' > "$worker_binding_sentinel"; printf 'unsynced-host\n'; }
        selector_acquire_slot() { printf 'slot\n' > "$worker_binding_sentinel"; return 99; }
        _act_build_orchestration_target() { printf 'build\n' > "$worker_binding_sentinel"; return 99; }
        _act_run_target_worker focrtest v1.0.0 "$contract_run_id" linux/amd64 1 \
            "$TEMP_DIR/worker-$worker_binding_case.log" "$worker_binding_result" \
            true null "$worker_binding_roots" "$contract_sha" "$contract_ref" "$worker_binding_host"
    ) || worker_binding_status=$?
    if [[ "$worker_binding_status" -eq 4 && ! -e "$worker_binding_sentinel" ]] && \
       jq -e '.status == "failed" and .exit_code == 4' "$worker_binding_result" >/dev/null; then
        pass "strict worker $worker_binding_case fails before selection, capacity, or execution"
    else
        fail "strict worker $worker_binding_case escaped its source boundary"
    fi
done

ordinary_identity=$(
    act_platform_uses_act() { return 1; }
    act_run_native_build() {
        jq -nc --arg root "$5" --arg sha "$6" --arg ref "$7" --arg host "$8" \
            '{status:"failed",exit_code:6,root:$root,sha:$sha,ref:$ref,host:$host}'
        return 6
    }
    _act_build_orchestration_target testool v1.0.0 ordinary linux/amd64 false null '{}' \
        "$contract_sha" main trj
)
if jq -e '.root == "" and .sha == "" and .ref == "" and .host == "trj"' \
    <<< "$ordinary_identity" >/dev/null; then
    pass "ordinary run provenance does not impersonate a strict native snapshot"
else
    fail "ordinary native build received an incomplete strict identity"
fi

# bd-1ldf: an act job that exits 0 but collects no artifacts must fail the
# target instead of letting packaging warn and the build exit 0.
act_zero_artifact_check() {
    local count_json="$1" status=0 output
    output=$(
        # Read by the production _act_build_orchestration_target loaded above.
        # shellcheck disable=SC2034
        ACT_REPO_WORKFLOW=".github/workflows/release.yml" ACT_REPO_LOCAL_PATH="$TEMP_DIR"
        act_platform_uses_act() { return 0; }
        act_get_job_for_target() { printf 'build-linux\n'; }
        act_get_flags() { printf '[]\n'; }
        act_run_workflow() {
            jq -nc --argjson count "$count_json" \
                '{status:"success",exit_code:0,artifact_count:$count}'
        }
        _act_build_orchestration_target testool v1.0.0 ordinary linux/amd64 false null '{}' \
            2>/dev/null
    ) || status=$?
    printf '%s\t%s\n' "$status" "$output"
}
zero_artifact_result=$(act_zero_artifact_check 0)
some_artifact_result=$(act_zero_artifact_check 2)
missing_count_result=$(act_zero_artifact_check null)
if [[ "${zero_artifact_result%%$'\t'*}" -eq 6 ]] &&
   jq -e '.status == "failed" and .exit_code == 6 and (.error | test("without producing any artifacts"))' \
       <<< "${zero_artifact_result#*$'\t'}" >/dev/null &&
   [[ "${missing_count_result%%$'\t'*}" -eq 6 ]] &&
   [[ "${some_artifact_result%%$'\t'*}" -eq 0 ]] &&
   jq -e '.status == "success" and .artifact_count == 2 and .method == "act"' \
       <<< "${some_artifact_result#*$'\t'}" >/dev/null; then
    pass "act targets that collect zero artifacts fail closed"
else
    fail "act zero-artifact handling: zero=$zero_artifact_result some=$some_artifact_result missing=$missing_count_result"
fi

strict_method_sentinel="$TEMP_DIR/strict-method-drift-executed"
strict_method_status=0
strict_method_result=$(
    act_platform_uses_act() { return 0; }
    act_run_workflow() { printf 'workflow\n' > "$strict_method_sentinel"; return 99; }
    _act_build_orchestration_target focrtest v1.0.0 "$contract_run_id" linux/amd64 \
        true null "$contract_source_roots" "$contract_sha" "$contract_ref" stub-host
) || strict_method_status=$?
if [[ "$strict_method_status" -eq 4 && ! -e "$strict_method_sentinel" ]] && \
   jq -e '.error == "Strict release targets must use native builds"' <<< "$strict_method_result" >/dev/null; then
    pass "strict target rejects build-method drift before executing any workflow"
else
    fail "strict target escaped native source binding after configuration drift"
fi

staged_valid=true
while IFS=$'\t' read -r target staged_path; do
    expected_name=$(config_get_release_contract_json "focrtest" | \
        jq -r --arg target "$target" '.exact_primary_assets[$target]')
    if [[ ! -f "$staged_path" || -L "$staged_path" || "$(basename "$staged_path")" != "$expected_name" ]]; then
        staged_valid=false
    fi
done < <(echo "$contract_result" | jq -r '.targets[] | [.platform, .artifact_path] | @tsv')

if $staged_valid; then
    pass "strict orchestration stages raw native binaries under exact configured basenames"
else
    fail "strict orchestration did not stage every configured primary"
fi

archive_contract=$(config_get_release_contract_json "focrarchive")
archive_linux_source="$TEMP_DIR/archive-linux-source/focr"
archive_windows_source="$TEMP_DIR/archive-windows-source/focr.exe"
mkdir -p "$(dirname "$archive_linux_source")" "$(dirname "$archive_windows_source")"
write_minimal_target_binary "$archive_linux_source" "linux/amd64"
write_minimal_target_binary "$archive_windows_source" "windows/amd64"

archive_linux_result=$(with_collection_receipt \
    "$(jq -nc --arg path "$archive_linux_source" '{
        platform: "linux/amd64", status: "success", artifact_path: $path, artifact_paths: [$path]
    }')" "$archive_linux_source")
archive_windows_result=$(with_collection_receipt \
    "$(jq -nc --arg path "$archive_windows_source" '{
        platform: "windows/amd64", status: "success", artifact_path: $path, artifact_paths: [$path]
    }')" "$archive_windows_source")
# These archive producers are synthetic native backends, just like the strict
# scheduler fixture above. Keep policy evidence explicit before real staging.
archive_linux_result=$(_fixture_strict_rust_result "$archive_linux_result" \
    "$contract_sha" "$contract_ref" "$TEMP_DIR/source-repo")
archive_windows_result=$(_fixture_strict_rust_result "$archive_windows_result" \
    "$contract_sha" "$contract_ref" "$TEMP_DIR/source-repo")

archive_linux_staged=$(_act_stage_contract_primary \
    "focrarchive" "v1.0.0" "550e8400-e29b-41d4-a716-446655440040" \
    "linux/amd64" "$archive_linux_result" "$archive_contract")
archive_windows_staged=$(_act_stage_contract_primary \
    "focrarchive" "v1.0.0" "550e8400-e29b-41d4-a716-446655440040" \
    "windows/amd64" "$archive_windows_result" "$archive_contract")
archive_linux_path=$(jq -r '.artifact_path' <<< "$archive_linux_staged")
archive_windows_path=$(jq -r '.artifact_path' <<< "$archive_windows_staged")

if [[ "$(basename "$archive_linux_path")" == "focr-1.0.0-linux_amd64.tar.gz" ]] && \
   [[ "$(tar -tzf "$archive_linux_path")" == "focr" ]] && \
   tar -xOzf "$archive_linux_path" focr | cmp -s -- "$archive_linux_source" -; then
    pass "strict staging packages a Linux binary as the contracted one-file tar.gz"
else
    fail "strict staging did not produce the contracted one-file Linux tar.gz"
fi

if [[ "$(basename "$archive_windows_path")" == "focr-1.0.0-windows_amd64.zip" ]] && \
   [[ "$(unzip -Z1 "$archive_windows_path")" == "focr.exe" ]] && \
   unzip -p "$archive_windows_path" focr.exe | cmp -s -- "$archive_windows_source" -; then
    pass "strict staging packages a Windows binary as the contracted one-file zip"
else
    fail "strict staging did not produce the contracted one-file Windows zip"
fi

workspace_bundle_dir="$TEMP_DIR/prepackaged-workspace"
windows_family_dir="$TEMP_DIR/windows-family"
mkdir -p "$windows_family_dir"
cat > "$TEMP_DIR/windows-family.yaml" <<'EOF'
workspace_binaries: [focr]
workspace_binaries_by_target:
  windows/amd64: [focr, gui]
include_files: []
EOF
write_minimal_target_binary "$windows_family_dir/focr.exe" "windows/amd64"
write_minimal_target_binary "$windows_family_dir/gui.exe" "windows/amd64"
(cd "$windows_family_dir" && zip -q "$TEMP_DIR/windows-family.zip" focr.exe gui.exe)
(cd "$windows_family_dir" && zip -q "$TEMP_DIR/windows-family-missing.zip" focr.exe)
if _act_validate_workspace_archive "$TEMP_DIR/windows-family.zip" zip windows/amd64 \
       "$TEMP_DIR/windows-family.yaml" && \
   ! _act_validate_workspace_archive "$TEMP_DIR/windows-family-missing.zip" zip windows/amd64 \
       "$TEMP_DIR/windows-family.yaml" >/dev/null 2>&1; then
    pass "Windows target family validates both native members and rejects missing GUI"
else
    fail "Windows target archive did not enforce its executable override"
fi
write_minimal_target_binary "$windows_family_dir/gui.exe" "linux/amd64"
(cd "$windows_family_dir" && zip -q "$TEMP_DIR/windows-family-wrong-arch.zip" focr.exe gui.exe)
if _act_validate_workspace_archive "$TEMP_DIR/windows-family-wrong-arch.zip" zip windows/amd64 \
       "$TEMP_DIR/windows-family.yaml" >/dev/null 2>&1; then
    fail "Windows GUI bypassed native architecture validation"
else
    pass "Windows GUI override retains native architecture validation"
fi

workspace_archive_source="$TEMP_DIR/focrworkspace-1.0.0-linux_amd64.tar.gz"
mkdir -p "$workspace_bundle_dir/docs"
write_minimal_target_binary "$workspace_bundle_dir/focr" "linux/amd64"
write_minimal_target_binary "$workspace_bundle_dir/fw" "linux/amd64"
printf 'workspace readme\n' > "$workspace_bundle_dir/README.md"
printf 'workspace notice\n' > "$workspace_bundle_dir/docs/NOTICE.txt"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$workspace_archive_source" -C "$workspace_bundle_dir" \
    focr fw README.md docs/NOTICE.txt
workspace_archive_result=$(with_collection_receipt \
    "$(jq -nc --arg path "$workspace_archive_source" '{
        platform: "linux/amd64", status: "success", artifact_path: $path, artifact_paths: [$path]
    }')" "$workspace_archive_source")
workspace_archive_result=$(_fixture_strict_rust_result "$workspace_archive_result" \
    "$contract_sha" "$contract_ref" "$TEMP_DIR/source-repo")
workspace_archive_staged=$(_act_stage_contract_primary \
    "focrworkspace" "v1.0.0" "550e8400-e29b-41d4-a716-446655440042" \
    "linux/amd64" "$workspace_archive_result" \
    "$(config_get_release_contract_json "focrworkspace")")
workspace_archive_path=$(jq -r '.artifact_path' <<< "$workspace_archive_staged")

if [[ "$(basename "$workspace_archive_path")" == \
      "focrworkspace-1.0.0-linux_amd64.tar.gz" ]] && \
   cmp -s -- "$workspace_archive_source" "$workspace_archive_path" && \
   [[ "$(tar -tzf "$workspace_archive_path" | LC_ALL=C sort)" == \
      $'README.md\ndocs/NOTICE.txt\nfocr\nfw' ]]; then
    pass "strict staging preserves an already packaged multi-binary workspace archive"
else
    fail "strict staging rejected or rewrote a valid multi-binary workspace archive"
fi

# Keep the real archive and member checks, but make abandoning a verbose
# listing deterministically observable even on fast machines with tiny files.
# Empty trailing lines cannot change the selected member's metadata.
workspace_listing_tar=$(command -v gtar || command -v tar)
gtar() {
    "$workspace_listing_tar" "$@" || return $?
    case "$1" in
        -tvzf|-tvJf)
            awk 'BEGIN { for (i=0; i<262144; i++) print "" }'
            ;;
    esac
}
if _act_validate_workspace_archive "$workspace_archive_source" tar.gz linux/amd64 \
    "$ACT_REPOS_DIR/focrworkspace.yaml"; then
    pass "workspace validation drains verbose producers under pipefail"
else
    fail "workspace validation abandoned a verbose archive producer"
fi
unset -f gtar

workspace_extra_archive="$TEMP_DIR/prepackaged-workspace-extra/focrworkspace-1.0.0-linux_amd64.tar.gz"
mkdir -p "$(dirname "$workspace_extra_archive")"
printf 'unexpected\n' > "$workspace_bundle_dir/extra.txt"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$workspace_extra_archive" -C "$workspace_bundle_dir" \
    focr fw README.md docs/NOTICE.txt extra.txt
workspace_extra_result=$(with_collection_receipt \
    "$(jq -nc --arg path "$workspace_extra_archive" '{
        platform: "linux/amd64", status: "success", artifact_path: $path, artifact_paths: [$path]
    }')" "$workspace_extra_archive")
workspace_extra_status=0
_act_stage_contract_primary \
    "focrworkspace" "v1.0.0" "550e8400-e29b-41d4-a716-446655440043" \
    "linux/amd64" "$workspace_extra_result" \
    "$(config_get_release_contract_json "focrworkspace")" \
    >/dev/null 2>&1 || workspace_extra_status=$?
if [[ $workspace_extra_status -eq 4 ]]; then
    pass "strict staging rejects extra members in a prepackaged workspace archive"
else
    fail "strict staging accepted an unconfigured workspace archive member"
fi

raw_archive_impostor="$TEMP_DIR/raw-archive-impostor.tar.gz"
cp "$archive_linux_source" "$raw_archive_impostor"
if ! _act_validate_target_archive \
    "$raw_archive_impostor" "tar.gz" "focr" "linux/amd64" 2>/dev/null; then
    pass "strict archive validation rejects raw executable bytes under an archive name"
else
    fail "strict archive validation accepted raw executable bytes as tar.gz"
fi

multi_member_dir="$TEMP_DIR/multi-member-archive"
mkdir -p "$multi_member_dir"
cp "$archive_linux_source" "$multi_member_dir/focr"
printf 'unexpected member\n' > "$multi_member_dir/extra.txt"
tar -czf "$TEMP_DIR/multi-member.tar.gz" -C "$multi_member_dir" focr extra.txt
if ! _act_validate_target_archive \
    "$TEMP_DIR/multi-member.tar.gz" "tar.gz" "focr" "linux/amd64" 2>/dev/null; then
    pass "strict archive validation rejects additional archive members"
else
    fail "strict archive validation accepted a multi-member primary archive"
fi

wrong_arch_archive_dir="$TEMP_DIR/wrong-arch-archive"
mkdir -p "$wrong_arch_archive_dir"
write_minimal_target_binary "$wrong_arch_archive_dir/focr" "linux/arm64"
tar -czf "$TEMP_DIR/wrong-arch.tar.gz" -C "$wrong_arch_archive_dir" focr
if ! _act_validate_target_archive \
    "$TEMP_DIR/wrong-arch.tar.gz" "tar.gz" "focr" "linux/amd64" 2>/dev/null; then
    pass "strict archive validation rejects a wrong-architecture member"
else
    fail "strict archive validation accepted a wrong-architecture member"
fi

nonexec_archive_dir="$TEMP_DIR/nonexec-archive"
mkdir -p "$nonexec_archive_dir"
cp "$archive_linux_source" "$nonexec_archive_dir/focr"
chmod 644 "$nonexec_archive_dir/focr"
tar -czf "$TEMP_DIR/nonexec.tar.gz" -C "$nonexec_archive_dir" focr
if ! _act_validate_target_archive \
    "$TEMP_DIR/nonexec.tar.gz" "tar.gz" "focr" "linux/amd64" 2>/dev/null; then
    pass "strict archive validation rejects a non-executable Unix member"
else
    fail "strict archive validation accepted a non-executable Unix member"
fi

COPYFILE_DISABLE=1 tar --no-xattrs -cJf "$TEMP_DIR/valid.tar.xz" \
    -C "$(dirname "$archive_linux_source")" focr
if _act_validate_target_archive \
    "$TEMP_DIR/valid.tar.xz" "tar.xz" "focr" "linux/amd64" 2>/dev/null; then
    pass "strict archive validation accepts a valid one-file tar.xz"
else
    fail "strict archive validation rejected a valid one-file tar.xz"
fi

if command -v xattr &>/dev/null && command -v gtar &>/dev/null; then
    xattr_archive_dir="$TEMP_DIR/xattr-archive"
    mkdir -p "$xattr_archive_dir"
    cp "$archive_linux_source" "$xattr_archive_dir/focr"
    xattr -w com.apple.provenance proof "$xattr_archive_dir/focr"
    tar -cJf "$TEMP_DIR/xattr-member.tar.xz" -C "$xattr_archive_dir" focr
    if gtar -tf "$TEMP_DIR/xattr-member.tar.xz" 2>/dev/null | grep -qx '._focr'; then
        if ! _act_validate_target_archive \
            "$TEMP_DIR/xattr-member.tar.xz" "tar.xz" "focr" "linux/amd64" 2>/dev/null; then
            pass "strict archive validation rejects macOS metadata members visible to GNU tar"
        else
            fail "strict archive validation accepted a hidden AppleDouble member"
        fi
    else
        skip "local tar did not encode the xattr as an AppleDouble member"
    fi
else
    skip "xattr and gtar required for AppleDouble portability regression"
fi

payload_mismatch_status=0
(
    cmp() { return 1; }
    _act_stage_contract_primary \
        "focrarchive" "v1.0.0" "550e8400-e29b-41d4-a716-446655440041" \
        "linux/amd64" "$archive_linux_result" "$archive_contract"
) >/dev/null 2>&1 || payload_mismatch_status=$?
if [[ $payload_mismatch_status -eq 4 ]]; then
    pass "strict staging rejects an archive payload that fails source-byte comparison"
else
    fail "strict staging accepted an archive payload mismatch"
fi

archive_manifest_input=$(jq -nc \
    --arg sha "$contract_sha" \
    --arg ref "$contract_ref" \
    --argjson linux "$archive_linux_staged" \
    --argjson windows "$archive_windows_staged" '
    {
        tool: "focrarchive",
        build_purpose: "release", publishable: true,
        version: "v1.0.0",
        run_id: "550e8400-e29b-41d4-a716-446655440040",
        git_sha: $sha,
        git_ref: $ref,
        source_dependencies: [],
        status: "success",
        summary: {total: 2, success: 2, failed: 0},
        targets: ([$linux, $windows] | map(. + {build_purpose: "release", publishable: true}))
    }
')
archive_manifest=$(
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        act_generate_manifest "$archive_manifest_input" ""
    ) 2>/dev/null
)
if jq -e '
    .status == "success" and
    .summary == {total: 2, success: 2, failed: 0} and
    ([.artifacts[] | {target, archive_format}] | sort_by(.target)) == [
        {target: "linux/amd64", archive_format: "tar.gz"},
        {target: "windows/amd64", archive_format: "zip"}
    ]
' <<< "$archive_manifest" &>/dev/null; then
    pass "strict manifest validates and records contracted archive formats"
else
    fail "strict manifest rejected valid contracted archives: $archive_manifest"
fi

workspace_manifest_input=$(jq -nc \
    --arg sha "$contract_sha" \
    --arg ref "$contract_ref" \
    --argjson linux "$workspace_archive_staged" '
    {
        tool: "focrworkspace",
        build_purpose: "release", publishable: true,
        version: "v1.0.0",
        run_id: "550e8400-e29b-41d4-a716-446655440042",
        git_sha: $sha,
        git_ref: $ref,
        source_dependencies: [],
        status: "success",
        summary: {total: 1, success: 1, failed: 0},
        targets: [$linux + {build_purpose: "release", publishable: true}]
    }
')
workspace_manifest=$(
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        act_generate_manifest "$workspace_manifest_input" ""
    ) 2>/dev/null
)
if jq -e --arg sha "$(_act_sha256 "$workspace_archive_source")" '
    .status == "success" and
    .summary == {total: 1, success: 1, failed: 0} and
    .artifacts == [{
        name: "focrworkspace-1.0.0-linux_amd64.tar.gz",
        target: "linux/amd64",
        sha256: $sha,
        size_bytes: .artifacts[0].size_bytes,
        archive_format: "tar.gz",
        signed: false,
        signature_file: "",
        build_purpose: "release",
        publishable: true
    }]
' <<< "$workspace_manifest" &>/dev/null; then
    pass "strict manifest accepts a validated prepackaged multi-binary workspace archive"
else
    fail "strict manifest rejected the validated workspace archive: $workspace_manifest"
fi

extra_primary_result=$(_act_stage_contract_primary \
    "focrextra" "v1.0.0" "550e8400-e29b-41d4-a716-446655440044" \
    "linux/amd64" "$archive_linux_result" \
    "$(config_get_release_contract_json focrextra)")
extra_payload_dir="$TEMP_DIR/additional-payload"
extra_payload="$TEMP_DIR/supplemental.tar.xz"
mkdir -p "$extra_payload_dir"
printf 'manifest-bound additional bytes\n' > "$extra_payload_dir/proof.txt"
tar -cJf "$extra_payload" -C "$extra_payload_dir" proof.txt
extra_receipt=$(jq -nc --arg path "$extra_payload" \
    --arg sha256 "$(_act_sha256 "$extra_payload")" \
    --argjson size_bytes "$(_act_file_size "$extra_payload")" \
    --arg identity "$(_act_file_identity "$extra_payload")" \
    '{path: $path, sha256: $sha256, size_bytes: $size_bytes, identity: $identity}')
extra_primary_result=$(jq -c --argjson receipt "$extra_receipt" \
    '.additional_artifacts = [$receipt]' <<< "$extra_primary_result")
extra_manifest_input=$(jq -nc \
    --arg sha "$contract_sha" --arg ref "$contract_ref" \
    --argjson target "$extra_primary_result" '
    {
        tool: "focrextra",
        build_purpose: "release", publishable: true,
        version: "v1.0.0",
        run_id: "550e8400-e29b-41d4-a716-446655440044",
        git_sha: $sha,
        git_ref: $ref,
        source_dependencies: [],
        status: "success",
        summary: {total: 1, success: 1, failed: 0},
        targets: [$target + {build_purpose: "release", publishable: true}]
    }
')
extra_manifest=$(
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        act_generate_manifest "$extra_manifest_input" ""
    ) 2>/dev/null
)
if jq -e --arg extra_sha "$(_act_sha256 "$extra_payload")" '
    (.artifacts | length) == 2 and
    any(.artifacts[];
        .target == "additional" and .name == "supplemental.tar.xz" and
        .sha256 == $extra_sha and .archive_format == "tar.xz")
' <<< "$extra_manifest" >/dev/null; then
    pass "strict manifest binds the configured additional artifact bytes"
else
    fail "strict manifest omitted or rejected its additional artifact: $extra_manifest"
fi

missing_extra_status=0
missing_extra_input=$(jq -c '.targets[0].additional_artifacts = []' \
    <<< "$extra_manifest_input")
(
    ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
    git() {
        case "$*" in
            *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                printf '%s\n' "$contract_sha"
                ;;
            *"status --porcelain --untracked-files=all"*) return 0 ;;
            *) return 1 ;;
        esac
    }
    act_generate_manifest "$missing_extra_input" ""
) >/dev/null 2>&1 || missing_extra_status=$?
if [[ "$missing_extra_status" -eq 4 ]]; then
    pass "strict manifest fails closed when a base additional artifact is missing"
else
    fail "strict manifest accepted a missing base additional artifact"
fi

changing_source="$TEMP_DIR/changing-source/focr"
mkdir -p "$(dirname "$changing_source")"
write_minimal_target_binary "$changing_source" "linux/amd64"
changing_result=$(jq -nc --arg path "$changing_source" '{
    platform: "linux/amd64",
    status: "success",
    artifact_path: $path,
    artifact_paths: [$path]
}')
changing_result=$(with_collection_receipt "$changing_result" "$changing_source")
changing_stage_status=0
(
    cat() {
        command cat "$@" || return
        printf 'changed during copy\n' >> "$changing_source"
    }
    _act_stage_contract_primary \
        "focrtest" "v1.0.0" "changing-source-run" "linux/amd64" \
        "$changing_result" "$(config_get_release_contract_json "focrtest")"
) >/dev/null 2>&1 || changing_stage_status=$?
if [[ $changing_stage_status -eq 4 ]]; then
    pass "strict staging rejects a source that changes during copy"
else
    fail "strict staging accepted a source that changed during copy"
fi

replaced_source="$TEMP_DIR/replaced-collected-source/focr"
mkdir -p "$(dirname "$replaced_source")"
write_minimal_target_binary "$replaced_source" "linux/amd64"
replaced_result=$(with_collection_receipt \
    "$(jq -nc --arg path "$replaced_source" '{
        platform: "linux/amd64", status: "success", artifact_path: $path, artifact_paths: [$path]
    }')" "$replaced_source")
mv "$replaced_source" "${replaced_source}.original"
write_minimal_target_binary "$replaced_source" "linux/amd64"
replaced_stage_status=0
_act_stage_contract_primary \
    "focrtest" "v1.0.0" "550e8400-e29b-41d4-a716-446655440024" "linux/amd64" \
    "$replaced_result" "$(config_get_release_contract_json "focrtest")" \
    >/dev/null 2>&1 || replaced_stage_status=$?
if [[ $replaced_stage_status -eq 4 ]]; then
    pass "strict staging rejects a pathname replaced after native collection"
else
    fail "strict staging accepted a post-collection pathname replacement"
fi

symlink_source="$TEMP_DIR/symlink-stage-source/focr"
symlink_stage_dir="$TEMP_DIR/precreated-stage-dir"
symlink_victim="$TEMP_DIR/stage-symlink-victim"
mkdir -p "$(dirname "$symlink_source")" "$symlink_stage_dir"
write_minimal_target_binary "$symlink_source" "linux/amd64"
printf 'must remain unchanged\n' > "$symlink_victim"
ln -s "$symlink_victim" "$symlink_stage_dir/focr-x86_64-unknown-linux-gnu"
symlink_result=$(jq -nc --arg path "$symlink_source" '{
    platform: "linux/amd64", status: "success", artifact_path: $path, artifact_paths: [$path]
}')
symlink_result=$(with_collection_receipt "$symlink_result" "$symlink_source")
symlink_stage_status=0
(
    mktemp() { printf '%s\n' "$symlink_stage_dir"; }
    _act_stage_contract_primary \
        "focrtest" "v1.0.0" "550e8400-e29b-41d4-a716-446655440020" "linux/amd64" \
        "$symlink_result" "$(config_get_release_contract_json "focrtest")"
) >/dev/null 2>&1 || symlink_stage_status=$?
if [[ $symlink_stage_status -eq 4 && "$(cat "$symlink_victim")" == "must remain unchanged" ]]; then
    pass "strict staging refuses a pre-created symlink destination"
else
    fail "strict staging followed or accepted a pre-created symlink destination"
fi

race_source="$TEMP_DIR/race-stage-source/focr"
race_stage_dir="$TEMP_DIR/race-stage-dir"
race_victim="$TEMP_DIR/race-stage-victim"
race_staged_path="$race_stage_dir/focr-x86_64-unknown-linux-gnu"
mkdir -p "$(dirname "$race_source")" "$race_stage_dir"
write_minimal_target_binary "$race_source" "linux/amd64"
printf 'race victim must remain unchanged\n' > "$race_victim"
race_result=$(jq -nc --arg path "$race_source" '{
    platform: "linux/amd64", status: "success", artifact_path: $path, artifact_paths: [$path]
}')
race_result=$(with_collection_receipt "$race_result" "$race_source")
race_stage_status=0
(
    mktemp() { printf '%s\n' "$race_stage_dir"; }
    cat() {
        mv "$race_staged_path" "$race_staged_path.opened" || return
        ln -s "$race_victim" "$race_staged_path" || return
        command cat "$@"
    }
    _act_stage_contract_primary \
        "focrtest" "v1.0.0" "550e8400-e29b-41d4-a716-446655440022" "linux/amd64" \
        "$race_result" "$(config_get_release_contract_json "focrtest")"
) >/dev/null 2>&1 || race_stage_status=$?
if [[ $race_stage_status -eq 4 && \
      "$(cat "$race_victim")" == "race victim must remain unchanged" ]]; then
    pass "strict staging keeps its exclusive file descriptor across a symlink race"
else
    fail "strict staging followed or accepted a destination symlink race"
fi

strict_stage_rejected() {
    local source_path="$1"
    local target="$2"
    local candidate
    candidate=$(jq -nc --arg path "$source_path" --arg target "$target" '{
        platform: $target, status: "success", artifact_path: $path, artifact_paths: [$path]
    }')
    candidate=$(with_collection_receipt "$candidate" "$source_path") || return 0
    ! _act_stage_contract_primary \
        "focrtest" "v1.0.0" "550e8400-e29b-41d4-a716-446655440021" "$target" \
        "$candidate" "$(config_get_release_contract_json "focrtest")" >/dev/null 2>&1
}

invalid_binary="$TEMP_DIR/invalid-binary/focr"
mkdir -p "$(dirname "$invalid_binary")"
printf 'not an executable format\n' > "$invalid_binary"
chmod +x "$invalid_binary"
if strict_stage_rejected "$invalid_binary" "linux/amd64"; then
    pass "strict staging rejects a non-ELF Linux primary"
else
    fail "strict staging accepted a non-ELF Linux primary"
fi

wrong_arch_binary="$TEMP_DIR/wrong-arch/focr"
mkdir -p "$(dirname "$wrong_arch_binary")"
write_minimal_target_binary "$wrong_arch_binary" "linux/arm64"
if strict_stage_rejected "$wrong_arch_binary" "linux/amd64"; then
    pass "strict staging rejects a binary whose architecture mismatches its target"
else
    fail "strict staging accepted a wrong-architecture binary"
fi

nonexec_binary="$TEMP_DIR/nonexec/focr"
mkdir -p "$(dirname "$nonexec_binary")"
write_minimal_target_binary "$nonexec_binary" "linux/amd64"
chmod 644 "$nonexec_binary"
if strict_stage_rejected "$nonexec_binary" "linux/amd64"; then
    pass "strict staging rejects a Unix primary without executable permission"
else
    fail "strict staging accepted a non-executable Unix primary"
fi

wrong_input_name="$TEMP_DIR/wrong-input-name/not-focr"
mkdir -p "$(dirname "$wrong_input_name")"
write_minimal_target_binary "$wrong_input_name" "linux/amd64"
if strict_stage_rejected "$wrong_input_name" "linux/amd64"; then
    pass "strict staging rejects a primary not named focr or focr.exe for its target"
else
    fail "strict staging accepted a wrong input basename"
fi

contract_manifest_input="$contract_result"

for dirty_case in tracked untracked; do
    dirty_line=' M src/lib.rs'
    [[ "$dirty_case" == "untracked" ]] && dirty_line='?? post-build-untracked-input'
    dirty_manifest_status=0
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) printf '%s\n' "$dirty_line" ;;
                *) return 1 ;;
            esac
        }
        act_generate_manifest "$contract_manifest_input" "" >/dev/null
    ) 2>/dev/null || dirty_manifest_status=$?
    if [[ $dirty_manifest_status -eq 4 ]]; then
        pass "strict manifest rejects $dirty_case source drift after orchestration"
    else
        fail "strict manifest accepted $dirty_case source drift after orchestration"
    fi
done
contract_manifest=$(
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        act_generate_manifest "$contract_manifest_input" ""
    ) 2>/dev/null
)

contract_json=$(config_get_release_contract_json "focrtest")
if echo "$contract_manifest" | jq -e \
    --arg sha "$contract_sha" --arg ref "$contract_ref" --argjson contract "$contract_json" '
        .status == "success" and
        .summary == {total: 6, success: 6, failed: 0} and
        .source == {git_sha: $sha, git_ref: $ref, dependencies: []} and
        (.artifacts | length) == 6 and
        all(.artifacts[];
            $contract.exact_primary_assets[.target] == .name and
            .archive_format == "binary" and
            (.sha256 | test("^[a-f0-9]{64}$")) and
            .size_bytes > 0
        )
    ' &>/dev/null; then
    pass "strict manifest finalizes the exact configured 6/6 primary rows"
else
    fail "strict manifest does not match release contract: $contract_manifest"
fi

dependency_sha="3333333333333333333333333333333333333333"
dependency_path="$TEMP_DIR/pinned-dependency"
dependency_json=$(jq -nc --arg sha "$dependency_sha" '[{relative_path: "frankentorch", git_sha: $sha}]')
dependency_checkouts=$(jq -nc --arg path "$dependency_path" --arg sha "$dependency_sha" \
    '[{relative_path: "frankentorch", local_path: $path, git_sha: $sha}]')

missing_dependency_status=0
(
    config_get_release_source_dependencies_json() { printf '%s\n' "$dependency_json"; }
    _config_get_release_source_dependency_checkouts_json() { printf '%s\n' "$dependency_checkouts"; }
    git() {
        case "$*" in
            *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                printf '%s\n' "$contract_sha"
                ;;
            *"status --porcelain --untracked-files=all"*) return 0 ;;
            *) return 1 ;;
        esac
    }
    _act_validate_contract_source_identity "v1.0.0" "$contract_sha" "$contract_ref" "focrtest"
) >/dev/null 2>&1 || missing_dependency_status=$?
if [[ $missing_dependency_status -eq 4 ]]; then
    pass "strict source validation rejects a missing pinned sibling checkout"
else
    fail "strict source validation accepted a missing pinned sibling checkout"
fi

mkdir -p "$dependency_path"
revision_mismatch_status=0
(
    config_get_release_source_dependencies_json() { printf '%s\n' "$dependency_json"; }
    _config_get_release_source_dependency_checkouts_json() { printf '%s\n' "$dependency_checkouts"; }
    git() {
        if [[ "${2:-}" == "$dependency_path" && "$*" == *"HEAD^{commit}"* ]]; then
            printf '%040d\n' 4
        elif [[ "${2:-}" == "$dependency_path" && "$*" == *"${dependency_sha}^{commit}"* ]]; then
            printf '%s\n' "$dependency_sha"
        else
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        fi
    }
    _act_validate_contract_source_identity "v1.0.0" "$contract_sha" "$contract_ref" "focrtest"
) >/dev/null 2>&1 || revision_mismatch_status=$?
if [[ $revision_mismatch_status -eq 4 ]]; then
    pass "strict source validation rejects a sibling at the wrong revision"
else
    fail "strict source validation accepted a sibling at the wrong revision"
fi

pinned_manifest_input=$(echo "$contract_manifest_input" | \
    jq --argjson dependencies "$dependency_json" '.source_dependencies = $dependencies')
pinned_manifest=$(
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        config_get_release_source_dependencies_json() { printf '%s\n' "$dependency_json"; }
        _config_get_release_source_dependency_checkouts_json() { printf '%s\n' "$dependency_checkouts"; }
        git() {
            if [[ "${2:-}" == "$dependency_path" ]]; then
                case "$*" in
                    *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify ${dependency_sha}^{commit}"*)
                        printf '%s\n' "$dependency_sha"
                        ;;
                    *"status --porcelain --untracked-files=all"*) return 0 ;;
                    *) return 1 ;;
                esac
            else
                case "$*" in
                    *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                        printf '%s\n' "$contract_sha"
                        ;;
                    *"status --porcelain --untracked-files=all"*) return 0 ;;
                    *) return 1 ;;
                esac
            fi
        }
        act_generate_manifest "$pinned_manifest_input" ""
    ) 2>/dev/null
)
if echo "$pinned_manifest" | jq -e --argjson dependencies "$dependency_json" \
    '.source.dependencies == $dependencies' &>/dev/null; then
    pass "strict manifest records canonical pinned sibling revisions"
else
    fail "strict manifest omitted or changed pinned sibling revisions: $pinned_manifest"
fi

dirty_dependency_status=0
(
    ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
    config_get_release_source_dependencies_json() { printf '%s\n' "$dependency_json"; }
    _config_get_release_source_dependency_checkouts_json() { printf '%s\n' "$dependency_checkouts"; }
    git() {
        if [[ "${2:-}" == "$dependency_path" ]]; then
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify ${dependency_sha}^{commit}"*)
                    printf '%s\n' "$dependency_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) printf '?? untracked-dependency-input\n' ;;
                *) return 1 ;;
            esac
        else
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        fi
    }
    act_generate_manifest "$pinned_manifest_input" "" >/dev/null
) 2>/dev/null || dirty_dependency_status=$?
if [[ $dirty_dependency_status -eq 4 ]]; then
    pass "strict manifest rejects post-build dirtiness in a pinned sibling checkout"
else
    fail "strict manifest accepted a dirty pinned sibling checkout"
fi

rehash_valid=true
while IFS=$'\t' read -r target manifest_sha manifest_size; do
    staged_path=$(echo "$contract_manifest_input" | jq -r --arg target "$target" \
        '.targets[] | select(.platform == $target) | .artifact_path')
    actual_sha=$(_act_sha256 "$staged_path")
    actual_size=$(_act_file_size "$staged_path")
    if [[ "$manifest_sha" != "$actual_sha" || "$manifest_size" != "$actual_size" ]]; then
        rehash_valid=false
    fi
done < <(echo "$contract_manifest" | jq -r '.artifacts[] | [.target, .sha256, (.size_bytes | tostring)] | @tsv')
if $rehash_valid; then
    pass "strict manifest recomputes staged file hashes and sizes"
else
    fail "strict manifest hash/size metadata does not match staged files"
fi

shared_manifest_dir="$TEMP_DIR/shared-manifest-artifacts"
mkdir -p "$shared_manifest_dir"
printf '{"kind":"evidence"}\n' > "$shared_manifest_dir/evidence.json"
while IFS=$'\t' read -r target expected_name; do
    write_minimal_target_binary "$shared_manifest_dir/$expected_name" "$target"
done < <(echo "$contract_json" | jq -r '.exact_primary_assets | to_entries[] | [.key, .value] | @tsv')
shared_manifest_input=$(echo "$contract_manifest_input" | jq --arg dir "$shared_manifest_dir" '
    .targets |= map(.artifact_path = "" | .artifact_paths = [] | .artifact_dir = $dir)
')
while IFS=$'\t' read -r target expected_name; do
    shared_path="$shared_manifest_dir/$expected_name"
    shared_sha=$(_act_sha256 "$shared_path")
    shared_size=$(_act_file_size "$shared_path")
    shared_identity=$(_act_file_identity "$shared_path")
    shared_manifest_input=$(echo "$shared_manifest_input" | jq \
        --arg target "$target" \
        --arg sha "$shared_sha" \
        --argjson size "$shared_size" \
        --arg identity "$shared_identity" '
            .targets |= map(
                if .platform == $target then
                    .staged_sha256 = $sha |
                    .staged_size_bytes = $size |
                    .staged_identity = $identity
                else . end
            )
        ')
done < <(echo "$contract_json" | jq -r '.exact_primary_assets | to_entries[] | [.key, .value] | @tsv')
shared_manifest=$(
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        act_generate_manifest "$shared_manifest_input" ""
    ) 2>/dev/null
)
if echo "$shared_manifest" | jq -e '.artifacts | length == 6' &>/dev/null; then
    pass "strict manifest selects exact primaries from a shared noisy artifact directory"
else
    fail "strict manifest rejected a valid shared artifact directory: $shared_manifest"
fi

strict_manifest_rejected() {
    local candidate="$1"
    (
        ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
        git() {
            case "$*" in
                *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                    printf '%s\n' "$contract_sha"
                    ;;
                *"status --porcelain --untracked-files=all"*) return 0 ;;
                *) return 1 ;;
            esac
        }
        ! act_generate_manifest "$candidate" "" >/dev/null 2>&1
    )
}

mutated_staged_source="$TEMP_DIR/mutated-staged-source/focr"
mkdir -p "$(dirname "$mutated_staged_source")"
write_minimal_target_binary "$mutated_staged_source" "linux/amd64"
mutated_staged_result=$(_act_stage_contract_primary \
    "focrtest" "v1.0.0" "550e8400-e29b-41d4-a716-446655440023" "linux/amd64" \
    "$(with_collection_receipt "$(jq -nc --arg path "$mutated_staged_source" '{
        platform: "linux/amd64", status: "success", artifact_path: $path, artifact_paths: [$path]
    }')" "$mutated_staged_source")" "$(config_get_release_contract_json "focrtest")")
mutated_staged_result=$(_fixture_strict_rust_result "$mutated_staged_result" \
    "$contract_sha" "$contract_ref" "$TEMP_DIR/source-repo")
mutated_staged_input=$(echo "$contract_manifest_input" | jq \
    --argjson replacement "$mutated_staged_result" '
        .targets |= map(if .platform == "linux/amd64" then $replacement else . end)
    ')
mutated_staged_path=$(echo "$mutated_staged_result" | jq -r '.artifact_path')
printf 'different valid executable bytes\n' >> "$mutated_staged_path"
if strict_manifest_rejected "$mutated_staged_input"; then
    pass "strict manifest rejects valid-architecture bytes changed after staging"
else
    fail "strict manifest blessed an artifact that changed after staging"
fi

bad_summary=$(echo "$contract_manifest_input" | \
    jq '.status = "partial" | .summary = {total: 6, success: 5, failed: 1}')
if strict_manifest_rejected "$bad_summary"; then
    pass "strict manifest rejects non-N/N orchestration summary"
else
    fail "strict manifest accepted a non-N/N orchestration summary"
fi

missing_primary=$(echo "$contract_manifest_input" | \
    jq '.targets[0].artifact_path = "/nonexistent/focr" | .targets[0].artifact_paths = ["/nonexistent/focr"]')
if strict_manifest_rejected "$missing_primary"; then
    pass "strict manifest rejects a missing primary"
else
    fail "strict manifest accepted a missing primary"
fi

duplicate_dir="$TEMP_DIR/contract-duplicate"
mkdir -p "$duplicate_dir"
first_name=$(echo "$contract_manifest_input" | jq -r '.targets[0].artifact_path | split("/")[-1]')
printf 'duplicate primary\n' > "$duplicate_dir/$first_name"
duplicate_primary=$(echo "$contract_manifest_input" | jq \
    --arg duplicate "$duplicate_dir/$first_name" \
    '.targets[0].artifact_paths += [$duplicate]')
if strict_manifest_rejected "$duplicate_primary"; then
    pass "strict manifest rejects duplicate primaries"
else
    fail "strict manifest accepted duplicate primaries"
fi

extra_path="$TEMP_DIR/unexpected-evidence.json"
printf '{"evidence":true}\n' > "$extra_path"
extra_primary=$(echo "$contract_manifest_input" | jq --arg extra "$extra_path" \
    '.targets[0].artifact_paths += [$extra]')
if strict_manifest_rejected "$extra_primary"; then
    pass "strict manifest rejects explicit extra files"
else
    fail "strict manifest accepted an explicit extra file"
fi

wrong_target=$(echo "$contract_manifest_input" | jq \
    '.targets[0].artifact_path = .targets[1].artifact_path |
     .targets[0].artifact_paths = [.targets[1].artifact_path]')
if strict_manifest_rejected "$wrong_target"; then
    pass "strict manifest rejects a primary assigned to the wrong target"
else
    fail "strict manifest accepted a wrong-target primary"
fi

write_status=0
(
    ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
    git() {
        case "$*" in
            *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                printf '%s\n' "$contract_sha"
                ;;
            *"status --porcelain --untracked-files=all"*) return 0 ;;
            *) return 1 ;;
        esac
    }
    act_generate_manifest "$contract_manifest_input" "$TEMP_DIR" >/dev/null 2>&1
) || write_status=$?
if [[ $write_status -ne 0 ]]; then
    pass "manifest output write failures propagate"
else
    fail "manifest output write failure was swallowed"
fi

manifest_sentinel="$TEMP_DIR/manifest-sentinel"
manifest_symlink="$TEMP_DIR/manifest-link.json"
printf 'sentinel must survive\n' > "$manifest_sentinel"
ln -s "$manifest_sentinel" "$manifest_symlink"
symlink_write_status=0
(
    ACT_REPO_LOCAL_PATH="$TEMP_DIR/source-repo"
    git() {
        case "$*" in
            *"rev-parse --verify HEAD^{commit}"*|*"rev-parse --verify refs/tags/v1.0.0^{commit}"*)
                printf '%s\n' "$contract_sha"
                ;;
            *"status --porcelain --untracked-files=all"*) return 0 ;;
            *) return 1 ;;
        esac
    }
    act_generate_manifest "$contract_manifest_input" "$manifest_symlink" >/dev/null 2>&1
) || symlink_write_status=$?
if [[ $symlink_write_status -ne 0 && "$(cat "$manifest_sentinel")" == "sentinel must survive" ]]; then
    pass "strict manifest refuses a symlink destination without changing its target"
else
    fail "strict manifest followed a symlink destination"
fi

echo ""
echo "== strict Cargo source closure =="

closure_source_root="$TEMP_DIR/closure-snapshot/source"
closure_snapshot_parent="${closure_source_root%/*}"
closure_sha="4444444444444444444444444444444444444444"
closure_internal_metadata=$(jq -nc --arg root "$closure_source_root" '{
    workspace_root: $root,
    packages: [
        {manifest_path: ($root + "/Cargo.toml"), source: null},
        {manifest_path: ($root + "/crates/internal/Cargo.toml"), source: null},
        {manifest_path: "/cargo/registry/cache/Cargo.toml", source: "registry+https://github.com/rust-lang/crates.io-index"}
    ]
}')
if _act_validate_cargo_metadata_source_closure \
    "$closure_source_root" '[]' "$closure_internal_metadata" >/dev/null 2>&1; then
    pass "strict Cargo closure accepts internal workspace packages"
else
    fail "strict Cargo closure rejected internal workspace packages"
fi

closure_pins=$(jq -nc --arg path "$TEMP_DIR/local-frankentorch" --arg sha "$closure_sha" '[{
    relative_path: "frankentorch",
    local_path: $path,
    git_sha: $sha
}]')
closure_sibling_metadata=$(jq -nc \
    --arg root "$closure_source_root" \
    --arg sibling "$closure_snapshot_parent/frankentorch/crates/ft-core/Cargo.toml" '{
        workspace_root: $root,
        packages: [
            {manifest_path: ($root + "/Cargo.toml"), source: null},
            {manifest_path: $sibling, source: null}
        ]
    }')
if _act_validate_cargo_metadata_source_closure \
    "$closure_source_root" "$closure_pins" "$closure_sibling_metadata" >/dev/null 2>&1; then
    pass "strict Cargo closure accepts a configured pinned sibling workspace"
else
    fail "strict Cargo closure rejected a configured pinned sibling workspace"
fi

closure_unconfigured_metadata=$(jq -nc \
    --arg root "$closure_source_root" \
    --arg escaped "$closure_source_root/../../unconfigured/Cargo.toml" '{
        workspace_root: $root,
        packages: [
            {manifest_path: ($root + "/Cargo.toml"), source: null},
            {manifest_path: $escaped, source: null}
        ]
    }')
if ! _act_validate_cargo_metadata_source_closure \
    "$closure_source_root" '[]' "$closure_unconfigured_metadata" >/dev/null 2>&1; then
    pass "strict Cargo closure rejects canonicalized escaping and unconfigured package paths"
else
    fail "strict Cargo closure accepted an escaping unconfigured package path"
fi

closure_workspace_escape=$(jq -nc \
    --arg root "$closure_source_root" \
    --arg workspace "$closure_source_root/../outside-workspace" '{
        workspace_root: $workspace,
        packages: [{manifest_path: ($root + "/Cargo.toml"), source: null}]
    }')
if ! _act_validate_cargo_metadata_source_closure \
    "$closure_source_root" '[]' "$closure_workspace_escape" >/dev/null 2>&1; then
    pass "strict Cargo closure rejects a workspace root outside the fresh snapshot"
else
    fail "strict Cargo closure accepted an escaping workspace root"
fi

closure_two_pins=$(jq -nc --arg path "$TEMP_DIR/local-pins" --arg sha "$closure_sha" '[
    {relative_path: "frankentorch", local_path: ($path + "/frankentorch"), git_sha: $sha},
    {relative_path: "frankensqlite", local_path: ($path + "/frankensqlite"), git_sha: $sha}
]')
if ! _act_validate_cargo_metadata_source_closure \
    "$closure_source_root" "$closure_two_pins" "$closure_sibling_metadata" >/dev/null 2>&1; then
    pass "strict Cargo closure requires metadata-discovered siblings to equal manifest pins"
else
    fail "strict Cargo closure accepted a missing manifest pin"
fi

closure_metadata_command_file="$TEMP_DIR/strict-cargo-metadata-command"
closure_metadata_command_status=0
(
    _act_is_windows_host() { return 1; }
    _act_ssh_exec() {
        printf '%s\n' "$2" > "$closure_metadata_command_file"
        printf '%s\n%s\n' "$closure_source_root" "$closure_internal_metadata"
    }
    _act_validate_strict_cargo_source_closure \
        "stub-host" "$closure_source_root" '[]'
) >/dev/null 2>&1 || closure_metadata_command_status=$?
if [[ $closure_metadata_command_status -eq 0 ]] && \
   grep -Fq 'ancestor=${physical_source_root%/*}' "$closure_metadata_command_file" && \
   grep -Fq "cd '$closure_source_root'" "$closure_metadata_command_file" && \
   grep -Fq 'export CARGO_HOME="$strict_home" RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1' \
        "$closure_metadata_command_file" && \
   grep -Fq "cargo_argv + ['metadata', '--locked', '--offline', '--all-features'," \
        "$closure_metadata_command_file"; then
    pass "strict Cargo metadata uses the build cwd while isolating ancestor config"
else
    fail "strict Cargo metadata cwd/config isolation was not constructed"
fi

closure_resume_source="$TEMP_DIR/closure-resume-snapshot/source"
closure_resume_ambient="$TEMP_DIR/closure-resume-ambient"
mkdir -p "$closure_resume_source/src" "$closure_resume_ambient"
printf '%s\n' \
    '[package]' \
    'name = "closure-resume"' \
    'version = "0.1.0"' \
    'edition = "2021"' \
    > "$closure_resume_source/Cargo.toml"
printf '%s\n' 'pub fn proof() {}' > "$closure_resume_source/src/lib.rs"
closure_resume_status=0
if ! CARGO_HOME="$closure_resume_ambient" cargo generate-lockfile --offline \
        --manifest-path "$closure_resume_source/Cargo.toml" >/dev/null 2>&1; then
    closure_resume_status=1
fi
(
    export CARGO_HOME="$closure_resume_ambient"
    _act_is_windows_host() { return 1; }
    _act_is_local_host() { return 0; }
    [[ $closure_resume_status -eq 0 ]]
    _act_validate_strict_cargo_source_closure \
        "stub-host" "$closure_resume_source" '[]' >/dev/null
    _act_validate_strict_cargo_source_closure \
        "stub-host" "$closure_resume_source" '[]' >/dev/null
) 2>/dev/null || closure_resume_status=$?
if [[ $closure_resume_status -eq 0 && \
      -d "$TEMP_DIR/closure-resume-snapshot/.cargo-home" && \
      ! -L "$TEMP_DIR/closure-resume-snapshot/.cargo-home" && \
      ! -e "$TEMP_DIR/closure-resume-snapshot/.cargo-home/config" && \
      ! -e "$TEMP_DIR/closure-resume-snapshot/.cargo-home/config.toml" ]]; then
    pass "strict Cargo closure validation safely reuses its isolated home on resume"
else
    fail "strict Cargo closure validation was not honestly resumable"
fi

closure_windows_metadata_command_file="$TEMP_DIR/strict-cargo-windows-metadata-command"
closure_windows_metadata_command_status=0
(
    _act_is_windows_host() { return 0; }
    _act_ssh_exec() {
        printf '%s\n' "$(_test_decode_remote_command "$2")" >> "$closure_windows_metadata_command_file"
        printf '%s\n{}\n' 'C:/build/source'
    }
    _act_validate_cargo_metadata_source_closure() { return 0; }
    _act_validate_strict_cargo_source_closure \
        "wlap" "C:/build/source" '[]'
) >/dev/null 2>&1 || closure_windows_metadata_command_status=$?
if [[ $closure_windows_metadata_command_status -eq 0 ]] && \
   grep -Fq "('Env:' + \$_.Name)" "$closure_windows_metadata_command_file" && \
   ! grep -Fq '("Env:" + $_.Name)' "$closure_windows_metadata_command_file"; then
    pass "strict Windows Cargo metadata preserves the Env provider path literal"
else
    fail "strict Windows Cargo metadata emitted a command-shell-broken Env path"
fi

closure_alias_logical_root="/tmp/dsr-closure-snapshot/source"
closure_alias_physical_root="/private$closure_alias_logical_root"
closure_alias_physical_metadata=$(jq -nc --arg root "$closure_alias_physical_root" '{
    workspace_root: $root,
    packages: [{manifest_path: ($root + "/Cargo.toml"), source: null}]
}')
closure_alias_command_file="$TEMP_DIR/strict-cargo-physical-command"
closure_alias_command_status=0
(
    _act_is_windows_host() { return 1; }
    _act_ssh_exec() {
        printf '%s\n' "$2" > "$closure_alias_command_file"
        printf '%s\n%s\n' "$closure_alias_physical_root" "$closure_alias_physical_metadata"
    }
    _act_validate_strict_cargo_source_closure \
        "stub-host" "$closure_alias_logical_root" '[]'
) >/dev/null 2>&1 || closure_alias_command_status=$?
if [[ $closure_alias_command_status -eq 0 ]] && \
   grep -Fq "physical_source_root=\$(cd '$closure_alias_logical_root' && pwd -P)" \
        "$closure_alias_command_file" && \
   grep -Fq 'strict_home="${physical_source_root%/*}/.cargo-home"' \
        "$closure_alias_command_file" && \
   grep -Fq 'ancestor=${physical_source_root%/*}' "$closure_alias_command_file" && \
   grep -Fq 'cd "$physical_source_root"' "$closure_alias_command_file" && \
   grep -Fq "'--manifest-path', str(pathlib.Path.cwd() / 'Cargo.toml')" \
        "$closure_alias_command_file"; then
    pass "strict Cargo metadata normalizes the macOS /tmp alias at the producer"
else
    fail "strict Cargo metadata mixed logical and physical source roots"
fi

closure_alias_lexical_metadata=$(jq -nc --arg root "$closure_alias_logical_root" '{
    workspace_root: $root,
    packages: [{manifest_path: ($root + "/Cargo.toml"), source: null}]
}')
if ! _act_validate_cargo_metadata_source_closure \
        "$closure_alias_physical_root" '[]' "$closure_alias_lexical_metadata" \
        >/dev/null 2>&1; then
    pass "strict Cargo closure rejects a direct lexical alias mismatch"
else
    fail "strict Cargo closure accepted mixed /tmp and /private/tmp roots"
fi

closure_large_metadata=$(jq -nc --arg root "$closure_source_root" '{
    workspace_root: $root,
    packages: [{manifest_path: ($root + "/Cargo.toml"), source: null}],
    padding: ("x" * (3 * 1024 * 1024))
}')
closure_large_metadata_status=0
(
    _act_is_windows_host() { return 1; }
    jq() {
        local argument
        for argument in "$@"; do
            [[ ${#argument} -le 65536 ]] || return 126
        done
        command jq "$@"
    }
    _act_ssh_exec() {
        printf '%s\n%s\n' "$closure_source_root" "$closure_large_metadata"
    }
    _act_validate_strict_cargo_source_closure \
        "stub-host" "$closure_source_root" '[]'
) >/dev/null 2>&1 || closure_large_metadata_status=$?
if [[ $closure_large_metadata_status -eq 0 ]]; then
    pass "strict Cargo metadata streams multi-megabyte output without argv overflow"
else
    fail "strict Cargo metadata exceeded the local process argv limit"
fi

linux_identity_command="$(declare -f _act_file_identity); exec 9< /etc/os-release; path_identity=\$(_act_file_identity /etc/os-release); fd_identity=\$(_act_file_identity /dev/fd/9); exec 9<&-; printf '%s %s\\n' \"\$path_identity\" \"\$fd_identity\"; test \"\$path_identity\" = \"\$fd_identity\""
linux_identity_status=0
linux_identity_output=$(command ssh \
    -o BatchMode=yes -o ConnectTimeout=5 trj \
    "$linux_identity_command" 2>/dev/null) || linux_identity_status=$?
if [[ $linux_identity_status -eq 0 && \
      "$linux_identity_output" =~ ^gnu:[0-9]+:[1-9][0-9]*\ gnu:[0-9]+:[1-9][0-9]*$ ]]; then
    pass "GNU/Linux identity dereferences an open descriptor to device and inode"
elif [[ $linux_identity_status -ne 0 ]]; then
    skip "GNU/Linux identity host unavailable"
else
    fail "GNU/Linux descriptor identity did not match its path: $linux_identity_output"
fi

echo ""
echo "== strict fresh source sync =="

# Exercise the actual Git archive, manifest and generated Unix verifier without
# SSH. Spaces are data; manifest separators and traversal remain forbidden.
strict_space_repo="$TEMP_DIR/strict-space-repo"
strict_space_root="$TEMP_DIR/strict-space-root"
strict_space_archive="$TEMP_DIR/strict-space.tar"
strict_space_manifest="$TEMP_DIR/strict-space.manifest"
strict_space_status=0
(
    set -e
    mkdir -p "$strict_space_repo/space directory" "$strict_space_root"
    printf 'literal archive payload\n' > "$strict_space_repo/space directory/hello world.sh"
    chmod +x "$strict_space_repo/space directory/hello world.sh"
    git -C "$strict_space_repo" init -q
    git -C "$strict_space_repo" add -- .
    git -C "$strict_space_repo" -c user.name=DSR-Test -c user.email=dsr-test@example.invalid \
        commit -qm 'space path fixture'
    sha=$(git -C "$strict_space_repo" rev-parse HEAD)
    _act_write_tracked_manifest "$strict_space_repo" "$sha" "$strict_space_manifest"
    _act_write_git_archive_evidence "$strict_space_repo" "$sha" "$strict_space_archive"
    tar -xf "$strict_space_archive" -C "$strict_space_root"
    count=$(_act_tracked_manifest_object_count "$strict_space_manifest")
    test "$count" = 2
    cmp "$strict_space_repo/space directory/hello world.sh" "$strict_space_root/space directory/hello world.sh"
    _act_verify_tracked_manifest_local "$strict_space_root" "$strict_space_manifest"
    digest=$(_act_sha256 "$strict_space_manifest")
    script=$(_act_unix_strict_snapshot_verify_script "$strict_space_root" "$strict_space_archive" \
        "$strict_space_manifest" "$digest" "$count")
    sh -c "$script"
    printf 'changed bytes\n' >> "$strict_space_root/space directory/hello world.sh"
    if _act_verify_tracked_manifest_local "$strict_space_root" "$strict_space_manifest"; then exit 1; fi
    if sh -c "$script"; then exit 1; fi
) > "$TEMP_DIR/strict-space-test.log" 2>&1
strict_space_status=$?
if [[ $strict_space_status -eq 0 ]]; then
    pass "strict archives preserve spaced file and ancestor names and reject changed bytes"
else
    cat "$TEMP_DIR/strict-space-test.log"
    fail "strict archive spaced-path roundtrip failed"
fi

strict_bad_index=0
for strict_bad_path in $'tab\tname' $'line\nname' '../escape' '/absolute'; do
    strict_bad_index=$((strict_bad_index + 1))
    strict_bad_manifest="$TEMP_DIR/strict-bad-$strict_bad_index.manifest"
    printf '%040d\t100644\t%s\n' 1 "$strict_bad_path" > "$strict_bad_manifest"
    strict_bad_status=0
    (
        set -e
        if _act_tracked_manifest_object_count "$strict_bad_manifest"; then exit 1; fi
        if _act_verify_tracked_manifest_local "$strict_space_root" "$strict_bad_manifest"; then exit 1; fi
        digest=$(_act_sha256 "$strict_bad_manifest")
        script=$(_act_unix_strict_snapshot_verify_script "$strict_space_root" "$strict_space_archive" \
            "$strict_bad_manifest" "$digest" 2)
        if sh -c "$script"; then exit 1; fi
        # Real tracked control characters must fail during manifest admission,
        # before tar extraction. Git cannot contain the traversal fixtures.
        if [[ "$strict_bad_index" -le 2 ]]; then
            repo="$TEMP_DIR/strict-bad-repo-$strict_bad_index"
            mkdir -p "$repo"
            printf 'unsafe name payload\n' > "$repo/$strict_bad_path"
            git -C "$repo" init -q
            git -C "$repo" add -- .
            git -C "$repo" -c user.name=DSR-Test -c user.email=dsr-test@example.invalid \
                commit -qm 'control character fixture'
            sha=$(git -C "$repo" rev-parse HEAD)
            if _act_write_tracked_manifest "$repo" "$sha" "$TEMP_DIR/rejected-$strict_bad_index.manifest"; then exit 1; fi
        fi
    ) > "$TEMP_DIR/strict-bad-$strict_bad_index.log" 2>&1
    strict_bad_status=$?
    if [[ "$strict_bad_status" -eq 0 ]]; then
        pass "strict source rejects unsafe path case $strict_bad_index"
    else
        cat "$TEMP_DIR/strict-bad-$strict_bad_index.log"
        fail "strict source accepted unsafe path case $strict_bad_index"
    fi
done

strict_sync_repo="$TEMP_DIR/strict-sync-repo"
strict_sync_base="$TEMP_DIR/strict-sync-remote/project"
strict_sync_run_id="550e8400-e29b-41d4-a716-446655440040"
strict_gitlink_repo="$TEMP_DIR/strict-gitlink-repo"
mkdir -p "$strict_gitlink_repo"
printf 'pinned submodule commit\n' > "$strict_gitlink_repo/README.md"
git -C "$strict_gitlink_repo" init -q
git -C "$strict_gitlink_repo" add README.md
git -C "$strict_gitlink_repo" -c user.name=DSR-Test -c user.email=dsr-test@example.invalid \
    commit -qm 'gitlink fixture'
strict_gitlink_sha=$(git -C "$strict_gitlink_repo" rev-parse HEAD)
mkdir -p "$strict_sync_repo"
printf 'tracked release bytes\n' > "$strict_sync_repo/tracked.txt"
printf 'tracked crlf bytes\r\nsecond line\r\n' > "$strict_sync_repo/crlf.txt"
mkdir -p "$strict_sync_repo/site/functions/model"
printf 'export async function onRequest() {}\n' > \
    "$strict_sync_repo/site/functions/model/[[path]].js"
mkdir -p "$strict_sync_repo/vendor/git.sr.ht/~sbinet/gg"
printf 'tilde namespace license\n' > \
    "$strict_sync_repo/vendor/git.sr.ht/~sbinet/gg/LICENSE.md"
mkdir -p "$strict_sync_repo/vendor/github.com/alecthomas/chroma/v2/lexers/embedded"
printf 'sharp lexer fixture\n' > \
    "$strict_sync_repo/vendor/github.com/alecthomas/chroma/v2/lexers/embedded/c#.xml"
mkdir -p "$strict_sync_repo/vendor/harfbuzz/fonts"
printf 'font fixture with character set\n' > \
    "$strict_sync_repo/vendor/harfbuzz/fonts/Mplus1p-Regular.660E,6975.ttf"
printf 'font fixture with variation axes\n' > \
    "$strict_sync_repo/vendor/harfbuzz/fonts/Roboto.wght=300,wdth=90.ttf"
printf 'font fixture with parenthesized suffix\n' > \
    "$strict_sync_repo/vendor/harfbuzz/fonts/fuzz-harfbuzz_fuzzer(1)"
printf 'ignored.cache\n' > "$strict_sync_repo/.gitignore"
printf 'must never reach a strict builder\n' > "$strict_sync_repo/ignored.cache"
git -C "$strict_sync_repo" init -q
git -C "$strict_sync_repo" add tracked.txt crlf.txt .gitignore 'site/functions/model/[[path]].js' \
    'vendor/git.sr.ht/~sbinet/gg/LICENSE.md' \
    'vendor/github.com/alecthomas/chroma/v2/lexers/embedded/c#.xml' \
    'vendor/harfbuzz/fonts/Mplus1p-Regular.660E,6975.ttf' \
    'vendor/harfbuzz/fonts/Roboto.wght=300,wdth=90.ttf' \
    'vendor/harfbuzz/fonts/fuzz-harfbuzz_fuzzer(1)'
git -C "$strict_sync_repo" update-index --add \
    --cacheinfo "160000,$strict_gitlink_sha,vendor/submodule"
mkdir -p "$strict_sync_repo/vendor/submodule"
git -C "$strict_sync_repo" -c user.name=DSR-Test -c user.email=dsr-test@example.invalid \
    commit -qm 'strict sync fixture'
strict_sync_sha=$(git -C "$strict_sync_repo" rev-parse HEAD)

cat > "$ACT_REPOS_DIR/synctest.yaml" << EOF
tool_name: synctest
repo: Test/synctest
local_path: $strict_sync_repo
language: rust
binary_name: focr
build_cmd: cargo build --release
targets:
  - linux/amd64
act_job_map:
  linux/amd64: null
host_paths:
  trj: $strict_sync_base
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: focr-x86_64-unknown-linux-gnu
EOF

legacy_strict_sync_status=0
(
    rsync() { return 99; }
    act_sync_sources "synctest" "linux/amd64"
) >/dev/null 2>&1 || legacy_strict_sync_status=$?
if [[ $legacy_strict_sync_status -eq 4 ]]; then
    pass "strict tools refuse legacy source sync that could invoke rsync --delete"
else
    fail "strict tool accepted legacy source sync"
fi

archive_race_evidence_dir="$TEMP_DIR/archive-race-evidence"
archive_race_path="$archive_race_evidence_dir/source.tar"
archive_race_victim="$TEMP_DIR/archive-race-victim"
mkdir -p "$archive_race_evidence_dir"
printf 'archive victim must remain unchanged\n' > "$archive_race_victim"
archive_race_status=0
(
    mktemp() { printf '%s\n' "$archive_race_evidence_dir"; }
    git() {
        if [[ "$*" == *" archive --format=tar "* ]]; then
            mv "$archive_race_path" "$archive_race_path.opened" || return
            ln -s "$archive_race_victim" "$archive_race_path" || return
        fi
        command git "$@"
    }
    _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" \
        "$TEMP_DIR/archive-race-remote/run/source" "source.tar" "archive-race"
) >/dev/null 2>&1 || archive_race_status=$?
if [[ $archive_race_status -eq 4 && \
      "$(cat "$archive_race_victim")" == "archive victim must remain unchanged" ]]; then
    pass "strict evidence archive creation rejects a post-open symlink race"
else
    fail "strict evidence archive creation followed or accepted a symlink race"
fi

manifest_race_evidence_dir="$TEMP_DIR/manifest-race-evidence"
manifest_race_path="$manifest_race_evidence_dir/source.manifest"
manifest_race_victim="$TEMP_DIR/manifest-race-victim"
mkdir -p "$manifest_race_evidence_dir"
printf 'manifest victim must remain unchanged\n' > "$manifest_race_victim"
manifest_race_status=0
(
    mktemp() { printf '%s\n' "$manifest_race_evidence_dir"; }
    git() {
        if [[ "$*" == *" ls-tree -r --full-tree "* ]]; then
            mv "$manifest_race_path" "$manifest_race_path.opened" || return
            ln -s "$manifest_race_victim" "$manifest_race_path" || return
        fi
        command git "$@"
    }
    _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" \
        "$TEMP_DIR/manifest-race-remote/run/source" "source.tar" "manifest-race"
) >/dev/null 2>&1 || manifest_race_status=$?
if [[ $manifest_race_status -eq 4 && \
      "$(cat "$manifest_race_victim")" == "manifest victim must remain unchanged" ]]; then
    pass "strict evidence manifest creation rejects a post-open symlink race"
else
    fail "strict evidence manifest creation followed or accepted a symlink race"
fi

strict_sync_status=0
strict_missing_host_status=0
strict_missing_host_sentinel="$TEMP_DIR/strict-missing-host-sync-ran"
(
    act_get_native_host() { return 1; }
    _act_sync_strict_checkout() { printf 'sync\n' > "$strict_missing_host_sentinel"; return 99; }
    act_sync_sources "synctest" --strict-release \
        --run-id "$strict_sync_run_id" --git-sha "$strict_sync_sha" -- "linux/amd64"
) >/dev/null 2>&1 || strict_missing_host_status=$?
if [[ "$strict_missing_host_status" -eq 4 && ! -e "$strict_missing_host_sentinel" ]]; then
    pass "strict sync refuses a missing target host before writing any snapshot"
else
    fail "strict sync skipped an unbound target or reached snapshot creation"
fi

strict_sync_output=$(
    (
        rsync() { return 99; }
        act_sync_sources "synctest" --strict-release \
            --run-id "$strict_sync_run_id" --git-sha "$strict_sync_sha" -- "linux/amd64"
    ) 2>/dev/null
) || strict_sync_status=$?
strict_sync_root=$(echo "$strict_sync_output" | jq -r '.source_roots.trj // empty')
strict_sync_manifest="${strict_sync_root%/source}/.source.manifest"
strict_sync_object_count=$(_act_tracked_manifest_object_count "$strict_sync_manifest" 2>/dev/null || true)
if [[ $strict_sync_status -eq 0 && -n "$strict_sync_root" && \
      -f "$strict_sync_root/tracked.txt" && ! -e "$strict_sync_root/.git" && \
      ! -e "$strict_sync_root/ignored.cache" && \
      -d "$strict_sync_root/vendor/submodule" && \
      -z "$(find "$strict_sync_root/vendor/submodule" -mindepth 1 -print -quit)" && \
      -f "$strict_sync_root/site/functions/model/[[path]].js" && \
      -f "$strict_sync_root/vendor/git.sr.ht/~sbinet/gg/LICENSE.md" && \
      -f "$strict_sync_root/vendor/github.com/alecthomas/chroma/v2/lexers/embedded/c#.xml" && \
      -f "$strict_sync_root/vendor/harfbuzz/fonts/Mplus1p-Regular.660E,6975.ttf" && \
      -f "$strict_sync_root/vendor/harfbuzz/fonts/Roboto.wght=300,wdth=90.ttf" && \
      -f "$strict_sync_root/vendor/harfbuzz/fonts/fuzz-harfbuzz_fuzzer(1)" && \
      -f "$strict_sync_root/crlf.txt" && \
      "$strict_sync_object_count" == "25" ]] && \
   grep -Fq "$strict_gitlink_sha"$'\t160000\tvendor/submodule' "$strict_sync_manifest" && \
   grep -Fq $'\t100644\tsite/functions/model/[[path]].js' "$strict_sync_manifest" && \
   grep -Fq $'\t100644\tvendor/git.sr.ht/~sbinet/gg/LICENSE.md' "$strict_sync_manifest" && \
   grep -Fq $'\t100644\tvendor/github.com/alecthomas/chroma/v2/lexers/embedded/c#.xml' "$strict_sync_manifest" && \
   echo "$strict_sync_output" | jq -e \
        '.status == "success" and (.source_roots | keys) == ["trj"] and
         .target_hosts == {"linux/amd64":"trj"}' &>/dev/null; then
    pass "strict sync authenticates gitlinks as empty directory placeholders"
else
    fail "strict fresh source sync failed: status=$strict_sync_status output=$strict_sync_output"
fi

# Used indirectly by the sourced strict-source verifier.
# shellcheck disable=SC2034
ACT_REPO_LOCAL_PATH="$strict_sync_repo"
if _act_verify_strict_source_roots \
    "synctest" "$strict_sync_sha" "$(echo "$strict_sync_output" | jq -c '.source_roots')" \
    >/dev/null 2>&1; then
    pass "strict source-root verification accepts an unchanged transferred snapshot"
else
    fail "strict source-root verification rejected an unchanged transferred snapshot"
fi

strict_crlf_status=0
(
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0=core.autocrlf
    export GIT_CONFIG_VALUE_0=true
    _act_verify_tracked_manifest_local "$strict_sync_root" "$strict_sync_manifest"
) >/dev/null 2>&1 || strict_crlf_status=$?
if [[ $strict_crlf_status -eq 0 ]]; then
    pass "strict byte verification ignores operator Git line-ending filters"
else
    fail "strict byte verification applied operator Git line-ending filters"
fi

strict_hash_calls="$TEMP_DIR/strict-hash-calls"
strict_batch_status=0
(
    git() {
        if [[ "$*" == *" hash-object "* ]]; then
            printf 'hash\n' >> "$strict_hash_calls"
        fi
        command git "$@"
    }
    _act_verify_tracked_manifest_local "$strict_sync_root" "$strict_sync_manifest"
) >/dev/null 2>&1 || strict_batch_status=$?
if [[ $strict_batch_status -eq 0 && "$(wc -l < "$strict_hash_calls" | tr -d ' ')" == "1" ]]; then
    pass "strict source inventory hashes every file with one Git process"
else
    fail "strict source inventory failed or launched per-file Git processes"
fi

strict_batch_status=0
(
    git() {
        command git "$@" || return
        if [[ "$*" == *" hash-object "* ]]; then
            return 23
        fi
    }
    _act_verify_tracked_manifest_local "$strict_sync_root" "$strict_sync_manifest"
) >/dev/null 2>&1 || strict_batch_status=$?
if [[ $strict_batch_status -eq 4 ]]; then
    pass "strict batch hashing rejects valid stdout from failed Git"
else
    fail "strict batch hashing ignored Git failure"
fi

strict_batch_status=0
(
    git() {
        command git "$@" || return
        if [[ "$*" == *" hash-object "* ]]; then
            chmod +x "$strict_sync_root/tracked.txt"
        fi
    }
    _act_verify_tracked_manifest_local "$strict_sync_root" "$strict_sync_manifest"
) >/dev/null 2>&1 || strict_batch_status=$?
chmod -x "$strict_sync_root/tracked.txt"
if [[ $strict_batch_status -eq 4 ]]; then
    pass "strict batch hashing rejects mode changes during hashing"
else
    fail "strict batch hashing accepted a post-hash mode change"
fi

strict_gitlink_tamper_root="$TEMP_DIR/strict-gitlink-tamper/run/source"
if _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_gitlink_tamper_root" \
        "source.tar" "gitlink-tamper" >/dev/null 2>&1; then
    printf 'must not enter a gitlink placeholder\n' > \
        "$strict_gitlink_tamper_root/vendor/submodule/injected.txt"
fi
if ! _act_verify_strict_checkout_snapshot \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_gitlink_tamper_root" \
        "source.tar" "gitlink-tamper" >/dev/null 2>&1; then
    pass "strict source verification rejects content beneath a gitlink placeholder"
else
    fail "strict source verification accepted content beneath a gitlink placeholder"
fi

strict_extra_file_root="$TEMP_DIR/strict-extra-file/run/source"
if _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_extra_file_root" \
        "source.tar" "extra-file" >/dev/null 2>&1; then
    printf 'post-build output\n' > "$strict_extra_file_root/post-build-output"
fi
if ! _act_verify_strict_checkout_snapshot \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_extra_file_root" \
        "source.tar" "extra-file" >/dev/null 2>&1; then
    pass "strict local source verification rejects an extra file"
else
    fail "strict local source verification accepted an extra file"
fi

strict_extra_symlink_root="$TEMP_DIR/strict-extra-symlink/run/source"
if _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_extra_symlink_root" \
        "source.tar" "extra-symlink" >/dev/null 2>&1; then
    ln -s "tracked.txt" "$strict_extra_symlink_root/post-build-link"
fi
if ! _act_verify_strict_checkout_snapshot \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_extra_symlink_root" \
        "source.tar" "extra-symlink" >/dev/null 2>&1; then
    pass "strict local source verification rejects an extra symlink"
else
    fail "strict local source verification accepted an extra symlink"
fi

strict_extra_dir_root="$TEMP_DIR/strict-extra-dir/run/source"
if _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_extra_dir_root" \
        "source.tar" "extra-directory" >/dev/null 2>&1; then
    mkdir "$strict_extra_dir_root/post-build-directory"
fi
if ! _act_verify_strict_checkout_snapshot \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_extra_dir_root" \
        "source.tar" "extra-directory" >/dev/null 2>&1; then
    pass "strict local source verification rejects an extra directory"
else
    fail "strict local source verification accepted an extra directory"
fi

strict_unix_file_root="$TEMP_DIR/strict-unix-file/run/source"
_act_sync_strict_checkout \
    "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_file_root" \
    "source.tar" "unix-extra-file" >/dev/null 2>&1
printf 'remote build output\n' > "$strict_unix_file_root/remote-output"
strict_unix_file_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 1; }
    _act_get_ssh_destination() { printf 'mock-unix\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command; remote_command=$(_test_decode_remote_command "${!#}")
        "$BASH" -c "$remote_command"
    }
    _act_verify_strict_checkout_snapshot \
        "mmini" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_file_root" \
        "source.tar" "unix-extra-file"
) >/dev/null 2>&1 || strict_unix_file_status=$?
if [[ $strict_unix_file_status -eq 4 ]]; then
    pass "strict mocked Unix SSH verification rejects an extra file"
else
    fail "strict mocked Unix SSH verification accepted an extra file"
fi

strict_unix_gitlink_root="$TEMP_DIR/strict-unix-gitlink/run/source"
_act_sync_strict_checkout \
    "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_gitlink_root" \
    "source.tar" "unix-gitlink" >/dev/null 2>&1
strict_unix_gitlink_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 1; }
    _act_get_ssh_destination() { printf 'mock-unix\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command; remote_command=$(_test_decode_remote_command "${!#}")
        env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf \
            GIT_CONFIG_VALUE_0=true "$BASH" -c "$remote_command"
    }
    _act_verify_strict_checkout_snapshot \
        "mmini" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_gitlink_root" \
        "source.tar" "unix-gitlink"
) >/dev/null 2>&1 || strict_unix_gitlink_status=$?
if [[ $strict_unix_gitlink_status -eq 0 ]]; then
    pass "strict mocked Unix SSH verification accepts an empty gitlink placeholder"
else
    fail "strict mocked Unix SSH verification rejected an empty gitlink placeholder"
fi

strict_unix_symlink_root="$TEMP_DIR/strict-unix-symlink/run/source"
_act_sync_strict_checkout \
    "trj" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_symlink_root" \
    "source.tar" "unix-extra-symlink" >/dev/null 2>&1
ln -s "tracked.txt" "$strict_unix_symlink_root/remote-link"
strict_unix_symlink_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 1; }
    _act_get_ssh_destination() { printf 'mock-unix\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command; remote_command=$(_test_decode_remote_command "${!#}")
        "$BASH" -c "$remote_command"
    }
    _act_verify_strict_checkout_snapshot \
        "mmini" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_symlink_root" \
        "source.tar" "unix-extra-symlink"
) >/dev/null 2>&1 || strict_unix_symlink_status=$?
if [[ $strict_unix_symlink_status -eq 4 ]]; then
    pass "strict mocked Unix SSH verification rejects an extra symlink"
else
    fail "strict mocked Unix SSH verification accepted an extra symlink"
fi

strict_windows_archive_digest=$(_act_git_archive_sha256 "$strict_sync_repo" "$strict_sync_sha")
strict_windows_gitlink_command_file="$TEMP_DIR/strict-windows-gitlink-command"
strict_windows_gitlink_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 0; }
    _act_get_ssh_destination() { printf 'mock-windows\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command manifest_digest; remote_command=$(_test_decode_remote_command "${!#}")
        printf '%s\n' "$remote_command" > "$strict_windows_gitlink_command_file"
        manifest_digest=$(printf '%s\n' "$remote_command" | grep -Eo '[0-9a-f]{64}' | head -1)
        printf '%s %s\n' "$strict_windows_archive_digest" "$manifest_digest"
    }
    _act_verify_strict_checkout_snapshot \
        "wlap" "$strict_sync_repo" "$strict_sync_sha" \
        "C:/build/.dsr-release-snapshots/windows-gitlink/run/source" \
        "source.tar" "windows-gitlink"
) >/dev/null 2>&1 || strict_windows_gitlink_status=$?
if [[ $strict_windows_gitlink_status -eq 0 ]] && \
   grep -Fq "parts[1] -eq '160000'" "$strict_windows_gitlink_command_file" && \
   grep -Fq '^[A-Za-z0-9_./+@~#,=()\[\] -]+$' "$strict_windows_gitlink_command_file" && \
   grep -Fq 'hash-object --no-filters --stdin-paths' "$strict_windows_gitlink_command_file" && \
   grep -Fq '$LASTEXITCODE -ne 0' "$strict_windows_gitlink_command_file" && \
   grep -Fq '$hashes.Count -ne $expected.Count' "$strict_windows_gitlink_command_file" && \
   grep -Fq 'Get-ChildItem -LiteralPath $node -Force' "$strict_windows_gitlink_command_file"; then
    pass "strict Windows verification accepts safe namespace paths and requires empty gitlinks"
else
    fail "strict Windows verification omitted the safe-path or gitlink contract"
fi

strict_windows_verify_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 0; }
    _act_get_ssh_destination() { printf 'mock-windows\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command manifest_digest; remote_command=$(_test_decode_remote_command "${!#}")
        if [[ "$remote_command" == *"Get-ChildItem"* && "$remote_command" == *'.Count -ne '* ]]; then
            return 20
        fi
        manifest_digest=$(printf '%s\n' "$remote_command" | grep -Eo '[0-9a-f]{64}' | head -1)
        printf '%s %s\n' "$strict_windows_archive_digest" "$manifest_digest"
    }
    _act_verify_strict_checkout_snapshot \
        "wlap" "$strict_sync_repo" "$strict_sync_sha" \
        "C:/build/.dsr-release-snapshots/windows-extra/run/source" \
        "source.tar" "windows-extra-file"
) >/dev/null 2>&1 || strict_windows_verify_status=$?
if [[ $strict_windows_verify_status -eq 4 ]]; then
    pass "strict mocked Windows verification rejects an extra file"
else
    fail "strict mocked Windows verification accepted an extra file"
fi

strict_windows_reparse_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 0; }
    _act_get_ssh_destination() { printf 'mock-windows\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command manifest_digest; remote_command=$(_test_decode_remote_command "${!#}")
        if [[ "$remote_command" == *"ReparsePoint"* ]]; then
            return 21
        fi
        manifest_digest=$(printf '%s\n' "$remote_command" | grep -Eo '[0-9a-f]{64}' | head -1)
        printf '%s %s\n' "$strict_windows_archive_digest" "$manifest_digest"
    }
    _act_verify_strict_checkout_snapshot \
        "wlap" "$strict_sync_repo" "$strict_sync_sha" \
        "C:/build/.dsr-release-snapshots/windows-reparse/run/source" \
        "source.tar" "windows-extra-symlink"
) >/dev/null 2>&1 || strict_windows_reparse_status=$?
if [[ $strict_windows_reparse_status -eq 4 ]]; then
    pass "strict mocked Windows verification rejects a reparse-point symlink"
else
    fail "strict mocked Windows verification accepted a reparse-point symlink"
fi

strict_windows_sync_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 0; }
    _act_get_ssh_destination() { printf 'mock-windows\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command; remote_command=$(_test_decode_remote_command "${!#}")
        if [[ "$remote_command" == *"ReparsePoint"* ]]; then
            return 22
        fi
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum | awk '{print $1}'
        else
            shasum -a 256 | awk '{print $1}'
        fi
    }
    _act_sync_strict_checkout \
        "wlap" "$strict_sync_repo" "$strict_sync_sha" \
        "C:/build/.dsr-release-snapshots/windows-sync/run/source" \
        "source.tar" "windows-reparse-sync"
) >/dev/null 2>&1 || strict_windows_sync_status=$?
if [[ $strict_windows_sync_status -eq 4 ]]; then
    pass "strict mocked Windows sync rejects a reparse-point parent or component"
else
    fail "strict mocked Windows sync accepted a reparse-point parent or component"
fi

strict_windows_scp_log="$TEMP_DIR/strict-windows-scp.log"
strict_windows_ssh_log="$TEMP_DIR/strict-windows-ssh.log"
strict_windows_archive_digest_file="$TEMP_DIR/strict-windows-archive.digest"
strict_windows_manifest_digest_file="$TEMP_DIR/strict-windows-manifest.digest"
strict_windows_scp_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 0; }
    _act_get_ssh_destination() { printf 'mock-windows\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    scp() {
        local source_index=$(( $# - 1 )) source_path destination
        source_path="${!source_index}"
        destination="${!#}"
        printf '%s -> %s\n' "$source_path" "$destination" >> "$strict_windows_scp_log"
        if [[ "$destination" == *'.source.tar' ]]; then
            sha256sum "$source_path" | awk '{print $1}' > "$strict_windows_archive_digest_file"
        elif [[ "$destination" == *'.source.manifest' ]]; then
            sha256sum "$source_path" | awk '{print $1}' > "$strict_windows_manifest_digest_file"
        else
            return 23
        fi
    }
    ssh() {
        local remote_command; remote_command=$(_test_decode_remote_command "${!#}")
        printf '%s\n' "$remote_command" >> "$strict_windows_ssh_log"
        if [[ "$remote_command" == *'hash-object --no-filters --stdin-paths'* ]]; then
            # Pre-build admission of the extracted checkout (issue #20).
            printf 'ADMISSION\n' >> "$strict_windows_ssh_log"
            printf '%s %s\n' "$(cat "$strict_windows_archive_digest_file")" \
                "$(cat "$strict_windows_manifest_digest_file")"
        elif [[ "$remote_command" == *'Get-FileHash'*'.source.manifest'* ]]; then
            cat "$strict_windows_manifest_digest_file"
        elif [[ "$remote_command" == *'Get-FileHash'*'.source.tar'* ]]; then
            cat "$strict_windows_archive_digest_file"
        fi
    }
    _act_sync_strict_checkout \
        "wlap" "$strict_sync_repo" "$strict_sync_sha" \
        "C:/build/.dsr-release-snapshots/windows-scp/run/source" \
        "source.tar" "windows-scp-sync"
) >/dev/null 2>&1 || strict_windows_scp_status=$?
if [[ $strict_windows_scp_status -eq 0 ]] && \
   [[ $(wc -l < "$strict_windows_scp_log") -eq 2 ]] && \
   grep -Fq '.source.tar' "$strict_windows_scp_log" && \
   grep -Fq '.source.manifest' "$strict_windows_scp_log" && \
   ! grep -Fq 'OpenStandardInput' "$strict_windows_ssh_log" &&
   grep -Fq "& (Join-Path \$env:SystemRoot 'System32\\tar.exe') -xf" "$strict_windows_ssh_log" && \
   [[ "$(tail -1 "$strict_windows_ssh_log")" == "ADMISSION" ]]; then
    pass "strict mocked Windows sync uploads with SCP, then admits the extracted checkout"
else
    fail "strict mocked Windows sync did not preserve the SCP and verification contract"
fi

# Issue #20: a remote Unix staging filesystem that cannot hold Git modes is
# refused at sync time, naming the offending path, before any compiler runs.
# The real generated verifier runs against the extracted copy; only the SSH
# transport is replaced. chmod +x simulates ExFAT's all-executable view.
strict_unix_mode_root="$TEMP_DIR/strict-unix-mode/run/source"
strict_unix_mode_stderr="$TEMP_DIR/strict-unix-mode.stderr"
strict_unix_mode_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 1; }
    _act_get_ssh_destination() { printf 'mock-unix\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command; remote_command=$(_test_decode_remote_command "${!#}")
        if [[ "$remote_command" == *'--stdin-paths'* ]]; then
            chmod +x "$strict_unix_mode_root/tracked.txt"
        fi
        "$BASH" -c "$remote_command"
    }
    _act_sync_strict_checkout \
        "mmini" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_mode_root" \
        "source.tar" "unix-mode-admission"
) >/dev/null 2>"$strict_unix_mode_stderr" || strict_unix_mode_status=$?
if [[ $strict_unix_mode_status -eq 4 ]] && \
   grep -Fq 'tracked.txt must have Git mode 100644' "$strict_unix_mode_stderr" && \
   grep -Fq 'POSIX-mode-preserving filesystem' "$strict_unix_mode_stderr" && \
   grep -Fq 'failed admission on mmini' "$strict_unix_mode_stderr"; then
    pass "strict Unix sync refuses a mode-losing staging filesystem before building, naming the path"
else
    fail "strict Unix sync did not refuse a mode mismatch at admission (status $strict_unix_mode_status)"
fi

strict_unix_admit_root="$TEMP_DIR/strict-unix-admit/run/source"
strict_unix_admit_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 1; }
    _act_get_ssh_destination() { printf 'mock-unix\n'; }
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local remote_command; remote_command=$(_test_decode_remote_command "${!#}")
        "$BASH" -c "$remote_command"
    }
    _act_sync_strict_checkout \
        "mmini" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_admit_root" \
        "source.tar" "unix-admission"
) >/dev/null 2>&1 || strict_unix_admit_status=$?
if [[ $strict_unix_admit_status -eq 0 ]] && [[ -f "$strict_unix_admit_root/tracked.txt" ]]; then
    pass "strict Unix sync admits an intact extracted checkout"
else
    fail "strict Unix sync refused an intact extracted checkout (status $strict_unix_admit_status)"
fi

# Issue #22: a verifier that exceeds DSR_SYNC_TIMEOUT names the host, the
# snapshot and the remedy instead of failing as an anonymous sync error.
strict_unix_timeout_root="$TEMP_DIR/strict-unix-timeout/run/source"
strict_unix_timeout_stderr="$TEMP_DIR/strict-unix-timeout.stderr"
strict_unix_timeout_status=0
(
    _act_is_local_host() { return 1; }
    _act_is_windows_host() { return 1; }
    _act_get_ssh_destination() { printf 'mock-unix\n'; }
    _act_run_with_timeout() {
        shift
        [[ "${!#}" == *'--stdin-paths'* ]] && return 124
        "$@"
    }
    ssh() {
        local remote_command; remote_command=$(_test_decode_remote_command "${!#}")
        "$BASH" -c "$remote_command"
    }
    _act_sync_strict_checkout \
        "mmini" "$strict_sync_repo" "$strict_sync_sha" "$strict_unix_timeout_root" \
        "source.tar" "unix-timeout"
) >/dev/null 2>"$strict_unix_timeout_stderr" || strict_unix_timeout_status=$?
if [[ $strict_unix_timeout_status -eq 4 ]] && \
   grep -Fq "verification of $strict_unix_timeout_root on mmini timed out" "$strict_unix_timeout_stderr" && \
   grep -Fq 'raise DSR_SYNC_TIMEOUT and resume' "$strict_unix_timeout_stderr"; then
    pass "strict verifier timeout names the host, snapshot and remedy"
else
    fail "strict verifier timeout was not diagnosed (status $strict_unix_timeout_status)"
fi

cat > "$ACT_REPOS_DIR/stdinlooptest.yaml" << EOF
tool_name: stdinlooptest
repo: Test/stdinlooptest
local_path: $strict_sync_repo
language: rust
binary_name: focr
build_cmd: cargo build --release
targets:
  - darwin/arm64
  - linux/amd64
act_job_map:
  darwin/arm64: null
  linux/amd64: null
sibling_crates:
  - local_path: $strict_sync_repo
    relative_path: dependency-a
    revision: "$strict_sync_sha"
  - local_path: $strict_sync_repo
    relative_path: dependency-b
    revision: "$strict_sync_sha"
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    darwin/arm64: focr-aarch64-apple-darwin
    linux/amd64: focr-x86_64-unknown-linux-gnu
EOF

stdin_loop_remote_source="$TEMP_DIR/stdin-loop-remote/run/source"
stdin_loop_local_source="$TEMP_DIR/stdin-loop-local/run/source"
stdin_loop_fixture_status=0
for stdin_loop_source in "$stdin_loop_remote_source" "$stdin_loop_local_source"; do
    _act_sync_strict_checkout \
        "trj" "$strict_sync_repo" "$strict_sync_sha" "$stdin_loop_source" \
        "source.tar" "stdin-loop-source" >/dev/null 2>&1 || stdin_loop_fixture_status=$?
    for stdin_loop_dependency in dependency-a dependency-b; do
        _act_sync_strict_checkout \
            "trj" "$strict_sync_repo" "$strict_sync_sha" \
            "${stdin_loop_source%/source}/$stdin_loop_dependency" \
            "dependency-${stdin_loop_dependency}.tar" "$stdin_loop_dependency" \
            >/dev/null 2>&1 || stdin_loop_fixture_status=$?
    done
done

stdin_loop_source_roots=$(jq -nc \
    --arg remote "$stdin_loop_remote_source" \
    --arg local "$stdin_loop_local_source" \
    '{mmini: $remote, trj: $local}')
stdin_loop_host_log="$TEMP_DIR/stdin-loop-hosts.log"
stdin_loop_ssh_log="$TEMP_DIR/stdin-loop-ssh.log"
stdin_loop_first_status=0
stdin_loop_second_status=0
(
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local detached=false argument remote_command; remote_command=$(_test_decode_remote_command "${!#}")
        for argument in "$@"; do
            [[ "$argument" == "-n" ]] && detached=true
        done
        if $detached; then
            command cat </dev/null >/dev/null
        else
            command cat >/dev/null
            printf 'missing-detach\n' >> "$stdin_loop_ssh_log"
        fi
        if [[ "$remote_command" == *"archive_digest="* ]]; then
            printf 'verify\n' >> "$stdin_loop_ssh_log"
        else
            printf 'exec\n' >> "$stdin_loop_ssh_log"
        fi
        "$BASH" -c "$remote_command"
    }

    while IFS= read -r stdin_loop_host; do
        printf '%s\n' "$stdin_loop_host" >> "$stdin_loop_host_log"
        if [[ "$stdin_loop_host" == "mmini" ]]; then
            _act_ssh_exec "$stdin_loop_host" true 30 >/dev/null
        fi
    done < <(printf 'mmini\ntrj\n')

    _act_verify_strict_source_roots \
        "stdinlooptest" "$strict_sync_sha" "$stdin_loop_source_roots"
) >/dev/null 2>&1 || stdin_loop_first_status=$?
stdin_loop_first_verify_count=$(grep -c '^verify$' "$stdin_loop_ssh_log" 2>/dev/null || true)
stdin_loop_first_missing_detach=$(grep -c '^missing-detach$' "$stdin_loop_ssh_log" 2>/dev/null || true)

printf 'post-build dependency mutation\n' >> \
    "${stdin_loop_local_source%/source}/dependency-b/tracked.txt"
: > "$stdin_loop_ssh_log"
(
    _act_run_with_timeout() { shift; "$@"; }
    ssh() {
        local detached=false argument remote_command; remote_command=$(_test_decode_remote_command "${!#}")
        for argument in "$@"; do
            [[ "$argument" == "-n" ]] && detached=true
        done
        if $detached; then
            command cat </dev/null >/dev/null
        else
            command cat >/dev/null
            printf 'missing-detach\n' >> "$stdin_loop_ssh_log"
        fi
        printf 'verify\n' >> "$stdin_loop_ssh_log"
        "$BASH" -c "$remote_command"
    }
    _act_verify_strict_source_roots \
        "stdinlooptest" "$strict_sync_sha" "$stdin_loop_source_roots"
) >/dev/null 2>&1 || stdin_loop_second_status=$?
stdin_loop_second_verify_count=$(grep -c '^verify$' "$stdin_loop_ssh_log" 2>/dev/null || true)
stdin_loop_second_missing_detach=$(grep -c '^missing-detach$' "$stdin_loop_ssh_log" 2>/dev/null || true)

if [[ $stdin_loop_fixture_status -eq 0 && $stdin_loop_first_status -eq 0 && \
      "$(cat "$stdin_loop_host_log")" == $'mmini\ntrj' && \
      "$stdin_loop_first_verify_count" == "3" && \
      "$stdin_loop_first_missing_detach" == "0" && \
      $stdin_loop_second_status -eq 4 && \
      "$stdin_loop_second_verify_count" == "3" && \
      "$stdin_loop_second_missing_detach" == "0" ]]; then
    pass "strict SSH validation preserves host and dependency loop input"
else
    fail "strict SSH validation skipped stdin-fed work: fixture=$stdin_loop_fixture_status first=$stdin_loop_first_status first_verify=$stdin_loop_first_verify_count first_detach=$stdin_loop_first_missing_detach second=$stdin_loop_second_status second_verify=$stdin_loop_second_verify_count second_detach=$stdin_loop_second_missing_detach hosts=$(tr '\n' ',' < "$stdin_loop_host_log")"
fi

printf 'post-build mutation\n' >> "$strict_sync_root/tracked.txt"
if ! _act_verify_strict_source_roots \
    "synctest" "$strict_sync_sha" "$(echo "$strict_sync_output" | jq -c '.source_roots')" \
    >/dev/null 2>&1; then
    pass "strict source-root verification rejects changed remote tracked bytes"
else
    fail "strict source-root verification accepted changed remote tracked bytes"
fi

cat > "$ACT_REPOS_DIR/actsynctest.yaml" << EOF
tool_name: actsynctest
repo: Test/actsynctest
local_path: $strict_sync_repo
language: rust
binary_name: focr
build_cmd: cargo build --release
targets:
  - linux/amd64
act_job_map:
  linux/amd64: build-linux
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: focr-x86_64-unknown-linux-gnu
EOF
strict_act_sync_sentinel="$TEMP_DIR/strict-act-sync-ran"
strict_act_sync_status=0
strict_act_sync_output=$(
    (
        _act_sync_strict_checkout() {
            printf 'called\n' > "$strict_act_sync_sentinel"
            return 99
        }
        act_sync_sources "actsynctest" --strict-release \
            --run-id "550e8400-e29b-41d4-a716-446655440042" \
            --git-sha "$strict_sync_sha" -- "linux/amd64"
    ) 2>/dev/null
) || strict_act_sync_status=$?
if [[ $strict_act_sync_status -eq 4 && ! -e "$strict_act_sync_sentinel" ]] && \
   echo "$strict_act_sync_output" | jq -e \
        '.status == "error" and (.error | contains("native builds"))' &>/dev/null; then
    pass "strict source sync rejects act targets before creating a snapshot"
else
    fail "strict source sync reached act snapshot work: status=$strict_act_sync_status output=$strict_act_sync_output"
fi

strict_act_build_sentinel="$TEMP_DIR/strict-act-build-ran"
strict_act_build_status=0
strict_act_build_output=$(
    (
        act_run_workflow() {
            printf 'called\n' > "$strict_act_build_sentinel"
            return 99
        }
        act_orchestrate_build "actsynctest" "v1.0.0" "linux/amd64"
    ) 2>/dev/null
) || strict_act_build_status=$?
if [[ $strict_act_build_status -eq 4 && ! -e "$strict_act_build_sentinel" ]] && \
   echo "$strict_act_build_output" | jq -e \
        '.status == "error" and (.error | contains("native builds"))' &>/dev/null; then
    pass "strict orchestration rejects act targets before workflow execution"
else
    fail "strict orchestration reached act workflow work: status=$strict_act_build_status output=$strict_act_build_output"
fi

reused_sync_status=0
(
    rsync() { return 99; }
    act_sync_sources "synctest" --strict-release \
        --run-id "$strict_sync_run_id" --git-sha "$strict_sync_sha" -- "linux/amd64"
) >/dev/null 2>&1 || reused_sync_status=$?
if [[ $reused_sync_status -ne 0 ]]; then
    pass "strict sync refuses a pre-existing source root"
else
    fail "strict sync reused a pre-existing source root"
fi

# Strict dependency sync and verification iterate `while read` loops over the
# pinned sibling checkouts. A transfer command that inherits the loop's stdin
# (ssh/scp without -n, as the Windows path once did) swallows the remaining
# records, so only the FIRST sibling reached the host (focr: asupersync synced,
# frankensqlite/frankentorch silently missing). The stubs below read stdin to
# EOF exactly like such a transfer; every sibling on every host must still be
# processed.
dependency_loop_log="$TEMP_DIR/dependency-loop.log"
dependency_loop_checkouts=$(jq -nc --arg sha "$strict_sync_sha" '[
    {relative_path: "asupersync", local_path: "/deps/asupersync", git_sha: $sha},
    {relative_path: "frankensqlite", local_path: "/deps/frankensqlite", git_sha: $sha},
    {relative_path: "frankentorch", local_path: "/deps/frankentorch", git_sha: $sha}]')
dependency_loop_status=0
(
    _act_release_source_dependency_checkouts_json() { printf '%s\n' "$dependency_loop_checkouts"; }
    _act_validate_strict_checkout_at_revision() { return 0; }
    _act_validate_no_absolute_cargo_paths() { return 0; }
    _act_sync_strict_checkout() { cat > /dev/null; printf 'sync %s\n' "$6" >> "$dependency_loop_log"; }
    act_sync_sources "synctest" --strict-release \
        --run-id "550e8400-e29b-41d4-a716-446655440042" --git-sha "$strict_sync_sha" -- "linux/amd64"
) >/dev/null 2>&1 || dependency_loop_status=$?
(
    _act_release_source_dependency_checkouts_json() { printf '%s\n' "$dependency_loop_checkouts"; }
    _act_verify_strict_checkout_snapshot() { cat > /dev/null; printf 'verify %s %s\n' "$1" "$6" >> "$dependency_loop_log"; }
    _act_verify_strict_source_roots synctest "$strict_sync_sha" \
        '{"trj":"/r/trj/source","wlap":"C:/d/r/source"}'
) >/dev/null 2>&1 || dependency_loop_status=$?
if [[ $dependency_loop_status -eq 0 && "$(cat "$dependency_loop_log")" == \
      "$(printf '%s\n' 'sync synctest' 'sync asupersync' 'sync frankensqlite' 'sync frankentorch' \
          'verify trj synctest' 'verify trj asupersync' 'verify trj frankensqlite' 'verify trj frankentorch' \
          'verify wlap synctest' 'verify wlap asupersync' 'verify wlap frankensqlite' 'verify wlap frankentorch')" ]]; then
    pass "strict sync and verification reach every pinned sibling on every host"
else
    fail "a stdin-reading transfer drained the sibling/host loop (status=$dependency_loop_status): $(tr '\n' ';' < "$dependency_loop_log" 2>/dev/null)"
fi

printf '[dependencies]\nasupersync = { path = "/dp/asupersync" }\n' > "$strict_sync_repo/Cargo.toml"
git -C "$strict_sync_repo" add Cargo.toml
git -C "$strict_sync_repo" -c user.name=DSR-Test -c user.email=dsr-test@example.invalid \
    commit -qm 'absolute path rejection fixture'
absolute_path_sha=$(git -C "$strict_sync_repo" rev-parse HEAD)
absolute_path_status=0
(
    rsync() { return 99; }
    act_sync_sources "synctest" --strict-release \
        --run-id "550e8400-e29b-41d4-a716-446655440041" \
        --git-sha "$absolute_path_sha" -- "linux/amd64"
) >/dev/null 2>&1 || absolute_path_status=$?
if [[ $absolute_path_status -ne 0 ]]; then
    pass "strict sync rejects absolute Cargo sibling paths instead of rewriting tag bytes"
else
    fail "strict sync accepted and could mutate an absolute Cargo sibling path"
fi

# Diagnostic purpose controls exercise the real coordinator, staging, receipts,
# and manifest against a real clean tagged local repository. Only the native
# transport/source-root verifier is simulated; these are not native build proofs.
diagnostic_repo="$TEMP_DIR/diagnostic-source"
mkdir -p "$diagnostic_repo"
git -C "$diagnostic_repo" init -q
git -C "$diagnostic_repo" config user.name DSR-Test
git -C "$diagnostic_repo" config user.email dsr-test@example.invalid
printf 'diagnostic source\n' > "$diagnostic_repo/source.txt"
git -C "$diagnostic_repo" add source.txt
git -C "$diagnostic_repo" commit -qm 'diagnostic source fixture'
git -C "$diagnostic_repo" tag v1.0.0
diagnostic_sha=$(git -C "$diagnostic_repo" rev-parse HEAD)
diagnostic_run="550e8400-e29b-41d4-a716-446655440091"
diagnostic_root=$(_act_strict_source_root_path "$diagnostic_repo" diagnostictest "$diagnostic_run" mmini)
diagnostic_roots=$(jq -nc --arg root "$diagnostic_root" '{mmini: $root}')
diagnostic_calls="$TEMP_DIR/diagnostic-native-calls"
diagnostic_payload="$TEMP_DIR/diagnostictest"
write_minimal_target_binary "$diagnostic_payload" darwin/arm64
cat > "$ACT_REPOS_DIR/diagnostictest.yaml" <<EOF
tool_name: diagnostictest
repo: test/diagnostictest
local_path: $diagnostic_repo
language: go
build_cmd: go build ./...
binary_name: diagnostictest
targets: [linux/amd64, darwin/arm64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: diagnostictest-linux-amd64
    darwin/arm64: diagnostictest-darwin-arm64
EOF
run_diagnostic_fixture() (
    act_platform_uses_act() { return 1; }
    selector_acquire_slot() { return 0; }
    selector_release_slot() { return 0; }
    _act_verify_strict_source_roots() {
        [[ "$1" == diagnostictest && "$2" == "$diagnostic_sha" && "$3" == "$diagnostic_roots" ]]
    }
    act_run_native_build() {
        printf '%s\n' "$*" >> "$diagnostic_calls"
        [[ "$2" == darwin/arm64 && "$5" == "$diagnostic_root" &&
           "$6" == "$diagnostic_sha" && "$7" == v1.0.0 && "$8" == mmini ]] || return 99
        # A command's claim to be publishable is deliberately hostile input.
        with_collection_receipt "$(jq -nc --arg path "$diagnostic_payload" \
            '{platform: "darwin/arm64", host: "mmini", method: "native",
              status: "success", artifact_path: $path, artifact_paths: [$path],
              build_purpose: "release", publishable: true}')" "$diagnostic_payload"
    }
    act_orchestrate_build diagnostictest v1.0.0 "$@" \
        --git-sha "$diagnostic_sha" --git-ref v1.0.0 --run-id "$diagnostic_run" \
        --output-dir "$DSR_STATE_DIR/diagnostics/diagnostictest-v1.0.0/$diagnostic_run" \
        --source-roots-json "$diagnostic_roots" \
        --target-hosts-json '{"darwin/arm64":"mmini"}' -- darwin/arm64
)
diagnostic_status=0
run_diagnostic_fixture > "$TEMP_DIR/diagnostic-normal-refused.json" \
    2> "$TEMP_DIR/diagnostic-normal-refused.log" || diagnostic_status=$?
if [[ "$diagnostic_status" -eq 4 && ! -e "$diagnostic_calls" ]]; then
    pass "normal strict subset is refused before native transport"
else
    fail "normal strict subset reached native transport"
fi
diagnostic_status=0
diagnostic_result=$(run_diagnostic_fixture --diagnostic-native \
    2> "$TEMP_DIR/diagnostic-native.log") || diagnostic_status=$?
act_load_repo_config diagnostictest >/dev/null 2>&1 || diagnostic_status=$?
diagnostic_manifest=$(act_generate_manifest "$diagnostic_result" "" \
    2> "$TEMP_DIR/diagnostic-manifest.log") || diagnostic_status=$?
diagnostic_state=$(build_state_get diagnostictest v1.0.0 "$diagnostic_run")
if [[ "$diagnostic_status" -eq 0 && "$(wc -l < "$diagnostic_calls" | tr -d ' ')" -eq 1 ]] && \
   jq -en --argjson result "$diagnostic_result" --argjson manifest "$diagnostic_manifest" \
       --argjson state "$diagnostic_state" --arg sha "$diagnostic_sha" '
        $result.status == "success" and $result.summary == {total:1, success:1, failed:0} and
        $result.build_purpose == "diagnostic-native" and $result.publishable == false and
        all($result.targets[]; .build_purpose == "diagnostic-native" and .publishable == false) and
        $state.context.build_purpose == "diagnostic-native" and $state.context.publishable == false and
        $manifest.source.git_sha == $sha and $manifest.source.git_ref == "v1.0.0" and
        $manifest.build_purpose == "diagnostic-native" and $manifest.publishable == false and
        $manifest.requested_targets == ["darwin/arm64"] and
        ($manifest.artifacts | length) == 1 and
        all($manifest.artifacts[]; .target == "darwin/arm64" and
            .build_purpose == "diagnostic-native" and .publishable == false)
    ' >/dev/null; then
    pass "diagnostic subset keeps source/target receipts and cannot inherit command publication claims"
else
    fail "diagnostic subset purpose/source/manifest mismatch (status=$diagnostic_status)"
fi
diagnostic_target=$(jq -c '.targets[0]' <<< "$diagnostic_result")
diagnostic_stream=$(printf '%s\n%s\n' "$diagnostic_target" \
    '{"build_purpose":"release","publishable":true}')
if ! _act_build_purpose_matches "$diagnostic_stream" release true; then
    pass "purpose authority rejects diagnostic-then-release JSON streams"
else
    fail "purpose authority accepted the last object of a mixed JSON stream"
fi
if _act_target_result_available "$diagnostic_target" diagnostic-native true && \
   ! _act_target_result_available "$diagnostic_target" release true && \
   ! _act_target_result_available "$diagnostic_target"; then
    pass "diagnostic bytes can only be reused by the same explicit purpose"
else
    fail "diagnostic artifact availability crossed purpose boundary"
fi
for purpose_mutation in \
    'del(.build_purpose)' '.publishable = true' \
    'del(.requested_targets)' '.targets[0].method = "act"' \
    '.targets[0].build_purpose = "release"' 'del(.targets[0].publishable)' \
    '.build_purpose = "release" | .publishable = true | .targets[] |= (.build_purpose = "release" | .publishable = true)'; do
    poisoned_result=$(jq -c "$purpose_mutation" <<< "$diagnostic_result")
    if act_generate_manifest "$poisoned_result" "" \
        > "$TEMP_DIR/diagnostic-poison-output" 2> "$TEMP_DIR/diagnostic-poison.log"; then
        fail "strict manifest accepted purpose mutation: $purpose_mutation"
    else
        pass "strict manifest refuses purpose mutation: $purpose_mutation"
    fi
done

# Configuration removal cannot relabel the already classified result through
# the ordinary manifest writer.
if ( _act_release_contract_json() { printf 'null\n'; }
     act_generate_manifest "$diagnostic_result" "" ) \
    > "$TEMP_DIR/diagnostic-config-drift-output" 2> "$TEMP_DIR/diagnostic-config-drift.log"; then
    fail "ordinary manifest writer laundered diagnostic result after config drift"
else
    pass "ordinary manifest writer rejects diagnostic result after config drift"
fi

# Each mutation restores the same real run context first. Check embedded state
# and immutable sidecars independently; no additional native work may be admitted.
diagnostic_workspace=$(build_state_workspace diagnostictest v1.0.0 "$diagnostic_run")
diagnostic_state_file="$diagnostic_workspace/state.json"
diagnostic_sidecar=$(jq -r '.targets[0].result_path' <<< "$diagnostic_result")
diagnostic_saved_sidecar=$(cat "$diagnostic_sidecar")
for purpose_case in context_missing context_mixed embedded_missing embedded_mixed sidecar_missing sidecar_mixed sidecar_stream; do
    printf '%s\n' "$diagnostic_saved_sidecar" > "$diagnostic_sidecar"
    case "$purpose_case" in
        context_missing) purpose_mutation='del(.context.build_purpose)' ;;
        context_mixed) purpose_mutation='.context.build_purpose = "release" | .context.publishable = true' ;;
        embedded_missing) purpose_mutation='del(.target_statuses["darwin/arm64"].result.build_purpose)' ;;
        embedded_mixed) purpose_mutation='.target_statuses["darwin/arm64"].result.publishable = true' ;;
        sidecar_missing)
            purpose_mutation='.'
            jq 'del(.build_purpose)' <<< "$diagnostic_saved_sidecar" > "$diagnostic_sidecar" ;;
        sidecar_mixed)
            purpose_mutation='.'
            jq '.publishable = true' <<< "$diagnostic_saved_sidecar" > "$diagnostic_sidecar" ;;
        sidecar_stream)
            purpose_mutation='.'
            jq '.build_purpose = "release" | .publishable = true' <<< "$diagnostic_saved_sidecar" > "$diagnostic_sidecar"
            printf '%s\n' "$diagnostic_saved_sidecar" >> "$diagnostic_sidecar" ;;
    esac
    jq "$purpose_mutation" <<< "$diagnostic_state" > "$diagnostic_state_file"
    diagnostic_status=0
    run_diagnostic_fixture --diagnostic-native --resume-run-id "$diagnostic_run" \
        > "$TEMP_DIR/diagnostic-resume-$purpose_case.json" \
        2> "$TEMP_DIR/diagnostic-resume-$purpose_case.log" || diagnostic_status=$?
    if [[ "$diagnostic_status" -eq 4 && "$(wc -l < "$diagnostic_calls" | tr -d ' ')" -eq 1 ]]; then
        pass "resume refuses $purpose_case before any native work"
    else
        fail "resume admitted invalid diagnostic purpose: $purpose_case status=$diagnostic_status"
    fi
done
printf '%s\n' "$diagnostic_saved_sidecar" > "$diagnostic_sidecar"
printf '%s\n' "$diagnostic_state" > "$diagnostic_state_file"
diagnostic_status=0
diagnostic_resumed=$(run_diagnostic_fixture --diagnostic-native --resume-run-id "$diagnostic_run" \
    2> "$TEMP_DIR/diagnostic-resume-same-purpose.log") || diagnostic_status=$?
if [[ "$diagnostic_status" -eq 0 && "$(wc -l < "$diagnostic_calls" | tr -d ' ')" -eq 1 ]] && \
   jq -e '.status == "success" and .targets[0].resume_reused == true and
       .targets[0].build_purpose == "diagnostic-native" and .targets[0].publishable == false' \
       <<< "$diagnostic_resumed" >/dev/null; then
    pass "same-purpose diagnostic resume reuses the frozen target without rebuilding"
else
    fail "same-purpose diagnostic resume lost exact retained authority"
fi

# Configured family requirements are selected before output exists; absent
# selected additions and ambiguous/unowned additions must fail closed.
diagnostic_contract=$(config_get_release_contract_json diagnostictest)
diagnostic_owned_contract=$(jq '.exact_additional_assets = ["darwin-proof", "linux-proof", "SHA256SUMS"]' <<< "$diagnostic_contract")
printf '\nworkspace_additional_artifacts:\n  darwin/arm64: [{name: darwin-proof, format: file}]\n  linux/amd64: [linux-proof]\n' >> "$ACT_REPOS_DIR/diagnostictest.yaml"
diagnostic_projection=$(_act_contract_for_build_purpose diagnostictest "$diagnostic_owned_contract" \
    '["darwin/arm64"]' diagnostic-native)
if jq -e '.exact_additional_assets == ["darwin-proof"] and
    (.exact_primary_assets | keys) == ["darwin/arm64"]' <<< "$diagnostic_projection" >/dev/null && \
   ! _act_generate_contract_manifest "$diagnostic_result" "" "$diagnostic_owned_contract" \
       > "$TEMP_DIR/diagnostic-missing-family.json" 2> "$TEMP_DIR/diagnostic-missing-family.log" && \
   ! _act_contract_for_build_purpose diagnostictest "$diagnostic_contract" \
       '["darwin/arm64"]' diagnostic-native > "$TEMP_DIR/diagnostic-unowned.json" \
       2> "$TEMP_DIR/diagnostic-unowned.log"; then
    pass "diagnostic projection requires selected configured additions and rejects unowned mappings"
else
    fail "diagnostic projection weakened configured family requirements"
fi

# Relocation admission uses real retained state and attempt files. Only remote
# transfer/verification are fixture boundaries; no network or compiler runs.
test_failed_target_relocation() (
    local failed_target="${1:-windows/amd64}" replacement_platform="${2:-windows/amd64}"
    local command_scope="${3:-target}"
    local fixture="$TEMP_DIR/relocation-${failed_target//\//-}-${replacement_platform//\//-}-$command_scope"
    mkdir -p "$fixture/config/repos.d" || exit 1
    local TEMP_DIR="$fixture" DSR_STATE_DIR="$fixture/state" DSR_CONFIG_DIR="$fixture/config"
    local DSR_HOSTS_FILE="$fixture/config/hosts.yaml" ACT_REPOS_DIR="$fixture/config/repos.d"
    local DSR_DISABLE_HOST_SELECTOR=1
    local old_root='/old-cross/source' new_root='/new-cross/source'
    if [[ "$replacement_platform" == windows/* ]]; then
        old_root='C:/old/source'
        new_root='C:/new/source'
    fi
    jq -nc --arg target "$failed_target" --arg platform "$replacement_platform" '
        {hosts:{trj:{platform:"linux/amd64",connection:"local"},
                wlap:{platform:$platform,connection:"ssh"},
                wsurf:{platform:$platform,connection:"ssh"}},
         platform_mapping:{($target):"wsurf","linux/amd64":"trj"}}' > "$DSR_HOSTS_FILE"
    build_state_init || exit 1
    local run='d942514f-43b5-4a55-9988-23d44bf18b50' version='v-relocation'
    local tool='relocationtest' sha="$strict_gitlink_sha"
    local approval="$TEMP_DIR/relocation-approval.json" prior="$TEMP_DIR/relocation-prior.yaml"
    local config="$ACT_REPOS_DIR/relocationtest.yaml" before after receipt failure status
    local log="$TEMP_DIR/relocation-old.log" result="$TEMP_DIR/relocation-old.json"
    local good="$TEMP_DIR/relocation-completed.bin" good_hash old_hash sync_calls="$TEMP_DIR/relocation-sync"
    local ACT_REPO_LANGUAGE=go ACT_REPO_LOCAL_PATH="$strict_gitlink_repo"
    export DSR_STATE_DIR DSR_DISABLE_HOST_SELECTOR ACT_REPO_LANGUAGE
    local good_sidecar="$TEMP_DIR/relocation-good.json" staged="$TEMP_DIR/relocation-staged"
    local expected_archive expected_manifest manifest="$TEMP_DIR/relocation-expected.manifest"
    expected_archive=$(_act_git_archive_sha256 "$ACT_REPO_LOCAL_PATH" "$sha") || exit 1
    _act_write_tracked_manifest "$ACT_REPO_LOCAL_PATH" "$sha" "$manifest" || exit 1
    expected_manifest=$(_act_sha256 "$manifest") || exit 1
    printf 'completed bytes\n' > "$good"
    printf 'original failed attempt\n' > "$log"
    jq -nc --arg target "$failed_target" --arg scope "$command_scope" '
        {cross_compile:{($target):{host:"wlap",build_cmd:"old"}},build_profile:"release-interactive"} |
        if $scope == "global" then .build_cmd="inherited" | del(.cross_compile[$target].build_cmd) else . end' > "$prior"
    jq -nc --arg target "$failed_target" --arg scope "$command_scope" '
        {cross_compile:{($target):{host:"wsurf",build_cmd:"new"}},build_profile:"release-interactive"} |
        if $scope == "global" then .build_cmd="inherited" | del(.cross_compile[$target].build_cmd) else . end' > "$config"
    good_hash=$(_act_sha256 "$good")
    receipt=$(jq -nc --arg path "$good" --arg hash "$good_hash" \
        '{status:"success",method:"native",host:"trj",platform:"linux/amd64",task_key:"linux/amd64",build_purpose:"release",publishable:true,artifact_path:$path,collected_sha256:$hash}')
    printf '%s\n' "$receipt" > "$good_sidecar"
    failure=$(jq -nc --arg sha "$sha" --arg target "$failed_target" \
        '{status:"failed",exit_code:17,host:"wlap",platform:$target,build_purpose:"release",publishable:true,
          build_influence_env:{DSR_RELEASE_GIT_SHA:$sha,DSR_RELEASE_GIT_REF:"v-relocation"}}')
    printf '%s\n' "$failure" > "$result"
    old_hash=$(_act_sha256 "$result")
    local prior_roots replacement_roots prior_hosts replacement_hosts
    prior_roots=$(jq -nc --arg root "$old_root" '{trj:"/old-linux/source",wlap:$root}')
    replacement_roots=$(jq -nc --arg root "$new_root" '{trj:"/old-linux/source",wsurf:$root}')
    prior_hosts=$(jq -nc --arg target "$failed_target" '{"linux/amd64":"trj",($target):"wlap"}')
    replacement_hosts=$(jq -nc --arg target "$failed_target" '{"linux/amd64":"trj",($target):"wsurf"}')
    DSR_RUN_ID="$run" build_state_create "$tool" "$version" "linux/amd64,$failed_target" >/dev/null || exit 1
    build_state_set_context "$tool" "$version" "$run" "$sha" "$version" \
        "$prior_roots" "$TEMP_DIR" 1 "$prior_hosts" release '' '' null "$(_act_sha256 "$prior")" || exit 1
    build_state_update_target "$tool" "$version" linux/amd64 completed \
        "$(jq -nc --argjson result "$receipt" --arg path "$good_sidecar" '{attempts:1,host:"trj",result:$result,result_path:$path}')" "$run" || exit 1
    build_state_update_target "$tool" "$version" "$failed_target" failed \
        "$(jq -nc --argjson result "$failure" --arg path "$result" --arg log "$log" \
        '{attempts:1,host:"wlap",result:$result,result_path:$path,log_path:$log}')" "$run" || exit 1
    before=$(build_state_get "$tool" "$version" "$run") || exit 1
    jq -n --arg run "$run" --arg path "$prior" --arg target "$failed_target" --arg old "$(_act_sha256 "$prior")" \
        --arg new "$(_act_sha256 "$config")" --arg hosts "$(_act_sha256 "$DSR_CONFIG_DIR/hosts.yaml")" \
        '{run_id:$run,target:$target,new_host:"wsurf",prior_repo_config_path:$path,
          prior_repo_config_sha256:$old,repo_config_sha256:$new,hosts_config_sha256:$hosts}' > "$approval"
    act_platform_uses_act() { return 1; }
    [[ "$(act_get_native_host "$failed_target" "$tool")" == wsurf &&
       "$(_act_get_host_platform wsurf)" == "$replacement_platform" ]] || exit 1
    _act_target_result_available() {
        [[ "$(jq -r .status <<< "$1")" == success ]] &&
            [[ "$(_act_sha256 "$(jq -r .artifact_path <<< "$1")")" == "$(jq -r .collected_sha256 <<< "$1")" ]]
    }
    _act_verify_strict_source_roots() {
        [[ "${RELOCATION_BAD_SOURCE:-0}" == 0 && -f "$staged" ]] &&
            [[ "$3" == "$replacement_roots" || "$3" == "$(jq -nc --arg root "$new_root" '{wsurf:$root}')" ]]
    }
    _act_release_source_dependency_checkouts_json() { printf '[]\n'; }
    _act_strict_source_root_path() {
        case "$4" in trj) printf '/old-linux/source\n';; wlap) printf '%s\n' "$old_root";; wsurf) printf '%s\n' "$new_root";; *) return 4;; esac
    }
    act_sync_sources() {
        local argument
        for argument in "$@"; do
            if [[ "$argument" == --admission-only ]]; then
                printf 'admission\n' >> "$sync_calls"
                return 0
            fi
        done
        printf 'sync\n' >> "$sync_calls"
        [[ "${RELOCATION_FAIL_SYNC:-0}" == 0 ]] || return 4
        [[ ! -e "$staged" ]] || return 4
        printf 'complete staged snapshot\n' > "$staged"
        jq -nc --arg target "$failed_target" --arg root "$new_root" \
            '{status:"success",failed:0,target_hosts:{($target):"wsurf"},source_roots:{wsurf:$root}}'
    }
    if [[ "$replacement_platform" != "$failed_target" ]]; then
        # The platform mapping resolves to wsurf too, so removing the explicit
        # cross-host selection still reaches the old host equality check. An
        # approved hash must not turn that fallback or an unusable recipe into
        # permission to stage sources or advance retained build state.
        local route_case route_dir route_approval
        for route_case in missing-host wrong-host empty-command whitespace-command object-command; do
            [[ "$command_scope" != global || "$route_case" == *-host ]] || continue
            route_dir="$TEMP_DIR/route-$route_case"
            route_approval="$route_dir/approval.json"
            mkdir -p "$route_dir" || exit 1
            jq --arg target "$failed_target" --arg case "$route_case" '
                if $case == "missing-host" then del(.cross_compile[$target].host)
                elif $case == "wrong-host" then .cross_compile[$target].host="other"
                elif $case == "empty-command" then .cross_compile[$target].build_cmd=""
                elif $case == "whitespace-command" then .cross_compile[$target].build_cmd=" \t "
                else .cross_compile[$target].build_cmd={} end' "$config" > "$route_dir/$tool.yaml"
            jq --arg hash "$(_act_sha256 "$route_dir/$tool.yaml")" \
                '.repo_config_sha256=$hash' "$approval" > "$route_approval"
            if ACT_REPOS_DIR="$route_dir" _act_relocate_failed_target "$tool" "$version" "$run" \
                "$before" "$failed_target=wsurf" "$route_approval" >/dev/null 2>&1; then exit 1; fi
        done
        local original_hosts="$TEMP_DIR/relocation-hosts.original" unknown_hosts="$TEMP_DIR/relocation-hosts.unknown"
        cp "$DSR_HOSTS_FILE" "$original_hosts" || exit 1
        jq '.hosts.wsurf.platform="unknown"' "$original_hosts" > "$unknown_hosts"
        cp "$unknown_hosts" "$DSR_HOSTS_FILE" || exit 1
        jq --arg hash "$(_act_sha256 "$DSR_HOSTS_FILE")" \
            '.hosts_config_sha256=$hash' "$approval" > "$TEMP_DIR/unknown-host-approval.json"
        if _act_relocate_failed_target "$tool" "$version" "$run" "$before" "$failed_target=wsurf" \
            "$TEMP_DIR/unknown-host-approval.json" >/dev/null 2>&1; then exit 1; fi
        cp "$original_hosts" "$DSR_HOSTS_FILE" || exit 1
        [[ ! -e "$sync_calls" && "$(build_state_get "$tool" "$version" "$run")" == "$before" ]] || exit 1
    fi
    for status in completed running pending; do
        if _act_relocate_failed_target "$tool" "$version" "$run" \
            "$(jq -c --arg status "$status" --arg target "$failed_target" '.target_statuses[$target].status=$status' <<< "$before")" \
            "$failed_target=wsurf" "$approval" >/dev/null 2>&1; then exit 1; fi
    done
    [[ ! -e "$sync_calls" ]] || exit 1
    # Tampering actual retained sidecars or artifact bytes must refuse before
    # transport, independently of the in-memory state's unchanged claims.
    printf '{"host":"foreign"}\n' > "$result"
    if _act_relocate_failed_target "$tool" "$version" "$run" "$before" "$failed_target=wsurf" "$approval" >/dev/null 2>&1; then exit 1; fi
    printf '%s\n' "$failure" > "$result"
    printf '{"status":"success","host":"foreign"}\n' > "$good_sidecar"
    if _act_relocate_failed_target "$tool" "$version" "$run" "$before" "$failed_target=wsurf" "$approval" >/dev/null 2>&1; then exit 1; fi
    printf '%s\n' "$receipt" > "$good_sidecar"
    printf 'tampered completed bytes\n' > "$good"
    if _act_relocate_failed_target "$tool" "$version" "$run" "$before" "$failed_target=wsurf" "$approval" >/dev/null 2>&1; then exit 1; fi
    printf 'completed bytes\n' > "$good"
    [[ ! -e "$sync_calls" ]] || exit 1
    # Changed failure provenance cannot be supplied as strings in the approval.
    if _act_relocate_failed_target "$tool" "$version" "$run" \
        "$(jq -c --arg target "$failed_target" '.target_statuses[$target].result.host="foreign"' <<< "$before")" \
        "$failed_target=wsurf" "$approval" >/dev/null 2>&1; then exit 1; fi
    [[ ! -e "$sync_calls" ]] || exit 1
    # Even an operator-approved current config hash cannot authorize unrelated
    # release profile drift through a target-only relocation.
    local bad_config="$TEMP_DIR/relocation-bad-config.yaml" bad_approval="$TEMP_DIR/relocation-bad-approval.json"
    jq '.build_profile="release-abort-probe"' "$config" > "$bad_config"
    local bad_config_dir="$TEMP_DIR/relocation-bad-config"
    mkdir -p "$bad_config_dir"
    cp "$bad_config" "$bad_config_dir/$tool.yaml"
    jq --arg hash "$(_act_sha256 "$bad_config")" '.repo_config_sha256=$hash' "$approval" > "$bad_approval"
    if ACT_REPOS_DIR="$bad_config_dir" _act_relocate_failed_target "$tool" "$version" "$run" "$before" \
        "$failed_target=wsurf" "$bad_approval" >/dev/null 2>&1; then exit 1; fi
    [[ ! -e "$sync_calls" ]] || exit 1
    if RELOCATION_FAIL_SYNC=1 _act_relocate_failed_target "$tool" "$version" "$run" "$before" \
        "$failed_target=wsurf" "$approval" >/dev/null 2>&1; then exit 1; fi
    [[ "$(build_state_get "$tool" "$version" "$run")" == "$before" ]] || exit 1
    if RELOCATION_BAD_SOURCE=1 _act_relocate_failed_target "$tool" "$version" "$run" "$before" \
        "$failed_target=wsurf" "$approval" >/dev/null 2>&1; then exit 1; fi
    [[ "$(build_state_get "$tool" "$version" "$run")" == "$before" ]] || exit 1
    # Existing but invalid staging remains a refusal, never an overwrite.
    if RELOCATION_BAD_SOURCE=1 _act_relocate_failed_target "$tool" "$version" "$run" "$before" \
        "$failed_target=wsurf" "$approval" >/dev/null 2>&1; then exit 1; fi
    [[ "$(build_state_get "$tool" "$version" "$run")" == "$before" ]] || exit 1
    # Exercise the real resumed scheduler: the relocated target starts attempt
    # two, while the successful target never reaches native execution.
    build_lock_acquire() { [[ "${RELOCATION_LOCK_HELD:-0}" == 0 ]]; }
    build_lock_release() { return 0; }
    unset -f selector_acquire_slot selector_release_slot
    act_load_repo_config() { return 0; }
    _act_release_contract_json() { printf '{}\n'; }
    # Packaging has its own real-file tests above; this fixture exercises
    # coordinator admission and immutable attempt receipts without a compiler.
    _act_stage_contract_primary() { printf '%s\n' "$5"; }
    _act_contract_for_build_purpose() { return 0; }
    _act_validate_contract_source_identity() { return 0; }
    _act_release_source_dependencies_json() { printf '[]\n'; }
    _act_release_source_dependency_checkouts_json() { printf '[]\n'; }
    local native_calls="$TEMP_DIR/relocation-native-calls" resumed
    act_run_native_build() {
        printf '%s\n' "$2" >> "$native_calls"
        [[ "$2" == "$failed_target" && "$8" == wsurf && "$5" == "$new_root" && "$6" == "$sha" && "$7" == "$version" ]] || return 99
        jq -nc --arg path "$good" --arg hash "$good_hash" --arg target "$failed_target" \
            '{status:"success",method:"native",exit_code:0,host:"wsurf",platform:$target,build_purpose:"release",publishable:true,
              artifact_path:$path,artifact_paths:[$path],collected_sha256:$hash}'
    }
    local sync_before lock_status=0 args=("$tool" "$version" --resume-run-id "$run"
        --resume-target-host "$failed_target=wsurf" --resume-target-host-approval "$approval"
        --git-sha "$sha" --git-ref "$version" --output-dir "$TEMP_DIR"
        --source-roots-json "$prior_roots"
        --target-hosts-json "$prior_hosts" -- linux/amd64 "$failed_target")
    sync_before=$(cat "$sync_calls")
    RELOCATION_LOCK_HELD=1 act_orchestrate_build "${args[@]}" >/dev/null 2>&1 || lock_status=$?
    [[ "$lock_status" -eq 2 && "$(cat "$sync_calls")" == "$sync_before" && ! -e "$native_calls" ]] || exit 1
    resumed=$(act_orchestrate_build "${args[@]}") || exit 1
    [[ "$(cat "$native_calls")" == "$failed_target" ]] || exit 1
    jq -e '.summary == {total:2,success:2,failed:0} and .targets[0].resume_reused == true' <<< "$resumed" >/dev/null || exit 1
    after=$(build_state_get "$tool" "$version" "$run") || exit 1
    jq -e --argjson old "$before" --arg hash "$old_hash" --arg archive "$expected_archive" --arg manifest "$expected_manifest" \
        --arg target "$failed_target" --arg platform "$replacement_platform" --argjson roots "$replacement_roots" '
        .context.target_hosts[$target] == "wsurf" and
        .context.source_roots == $roots and
        .relocations[0].new_host_platform == $platform and
        .relocations[0].prior_result_sha256 == $hash and
        .relocations[0].verified_source_sync.reused_verified_snapshot == true and
        .relocations[0].verified_source_inventory[0].archive_sha256 == $archive and
        .relocations[0].verified_source_inventory[0].manifest_sha256 == $manifest and
        .target_statuses[$target].attempts == 2 and
        .target_statuses["linux/amd64"] == $old.target_statuses["linux/amd64"] and
        .relocations[0].prior_target == $old.target_statuses[$target]' <<< "$after" >/dev/null || exit 1
    [[ "$(_act_sha256 "$result")" == "$old_hash" && "$(_act_sha256 "$good")" == "$good_hash" ]] || exit 1
    if build_state_relocate_failed_target "$tool" "$version" "$run" "$before" "$failed_target" \
        wsurf '{"wsurf":"other"}' '{}' >/dev/null 2>&1; then exit 1; fi
    # A later ordinary retry remains bound to the approved command/config.
    if ACT_REPOS_DIR="$bad_config_dir" act_orchestrate_build "$tool" "$version" \
        --resume-run-id "$run" --git-sha "$sha" --git-ref "$version" --output-dir "$TEMP_DIR" \
        --source-roots-json "$replacement_roots" --target-hosts-json "$replacement_hosts" \
        -- linux/amd64 "$failed_target" >/dev/null 2>&1; then exit 1; fi
    [[ "$(build_state_get "$tool" "$version" "$run")" == "$after" && "$(cat "$native_calls")" == "$failed_target" ]] || exit 1
)
if test_failed_target_relocation; then
    pass "failed-target relocation preserves completed bytes, attempt count, history and failed-staging authority"
else
    fail "failed-target relocation violated retained authority"
fi
for relocation_target in linux/arm64 windows/amd64; do
    if test_failed_target_relocation "$relocation_target" linux/amd64; then
        pass "Linux-hosted $relocation_target relocation preserves source, completed targets and failed attempt history"
    else
        fail "Linux-hosted $relocation_target relocation failed"
    fi
done
if test_failed_target_relocation linux/arm64 linux/amd64 global; then
    pass "cross-build relocation accepts an explicitly selected host with the inherited build command"
else
    fail "cross-build relocation rejected the inherited build command"
fi

# A long-running main must not resume parsing newly appended/replaced source.
# Exercise the actual entrypoint and retain an old-dispatch negative control.
test_dispatch_source_growth() (
    local fixture="$TEMP_DIR/dispatch-source-growth" status expected mode script
    mkdir -p "$fixture"
    tail -n 4 "$SCRIPT_DIR/dsr" > "$fixture/entrypoint"
    for mode in current legacy; do
        for expected in 0 7; do
            script="$fixture/$mode-$expected.sh"
            cat > "$script" <<'EOF'
main() {
    printf 'printf "UNEXPECTED_APPEND\\n"\nexit 99\n' >> "$0"
    return "$1"
}
EOF
            if [[ "$mode" == current ]]; then
                cat "$fixture/entrypoint" >> "$script"
            else
                printf 'main "$@"\n' >> "$script"
            fi
            status=0
            bash "$script" "$expected" > "$script.stdout" 2> "$script.stderr" || status=$?
            if [[ "$mode" == current ]]; then
                [[ "$status" -eq "$expected" && ! -s "$script.stdout" && ! -s "$script.stderr" ]] || exit 1
            else
                [[ "$status" -eq 99 && "$(cat "$script.stdout")" == UNEXPECTED_APPEND ]] || exit 1
            fi
        done
    done
)
if test_dispatch_source_growth; then
    pass "dispatch preserves command status without parsing source appended during main"
else
    fail "dispatch resumed parsing changed source or lost command status"
fi

# --parallel targets on ONE host whose build_cmd writes the same in-tree file
# (`go build -o ntm ./cmd/ntm`) used to overwrite each other's binary: ntm
# 1.36.0's linux/arm64 lane collected the amd64 build. This drives the real
# native runner on a local host with a build that holds the shared file across
# a window. The negative control disables detection and must reproduce the
# wrong-architecture collection; the fix gives the second target a private
# source copy and both targets collect their own architecture.
test_parallel_shared_output_isolation() (
    local root="$TEMP_DIR/shared-output" mode status result
    mkdir -p "$root/src" "$root/fixtures"
    write_minimal_target_binary "$root/fixtures/amd64" linux/amd64
    write_minimal_target_binary "$root/fixtures/arm64" linux/arm64
    cat > "$ACT_REPOS_DIR/outtest.yaml" <<EOF
tool_name: outtest
repo: test/outtest
local_path: $root/src
language: go
binary_name: outtest
build_cmd: cp "$root/fixtures/\$GOARCH" outtest && sleep 3
targets: [linux/amd64, linux/arm64]
act_job_map:
  linux/amd64: null
  linux/arm64: null
cross_compile:
  linux/amd64:
    host: trj
    env:
      GOOS: linux
      GOARCH: amd64
  linux/arm64:
    host: trj
    env:
      GOOS: linux
      GOARCH: arm64
EOF
    build_lock_acquire() { return 0; }
    build_lock_release() { return 0; }
    selector_acquire_slot() { return 0; }
    selector_release_slot() { return 0; }
    for mode in control fixed; do
        status=0
        result=$(
            if [[ "$mode" == control ]]; then
                _act_native_output_paths() { :; }
            fi
            act_orchestrate_build outtest "v1.0.0-$mode" --parallel-jobs 2 \
                --output-dir "$root/out-$mode" -- linux/amd64 linux/arm64
        ) 2> "$root/$mode.log" || status=$?
        printf '%s\n' "$result" > "$root/$mode.json"
        if [[ "$mode" == control ]]; then
            # Detection off: one lane must have collected the other's binary.
            jq -e '.summary.failed >= 1' <<< "$result" >/dev/null || exit 1
            jq -r '.targets[].log_path' <<< "$result" | xargs grep -l 'is not a linux/' >/dev/null || exit 1
        else
            [[ $status -eq 0 ]] || exit 1
            jq -e '.status == "success" and .summary == {total: 2, success: 2, failed: 0}' \
                <<< "$result" >/dev/null || exit 1
            local platform artifact
            for platform in linux/amd64 linux/arm64; do
                artifact=$(jq -r --arg p "$platform" '.targets[] | select(.platform == $p) | .artifact_path' <<< "$result")
                [[ -f "$artifact" ]] && _act_validate_target_binary "$artifact" "$platform" || exit 1
            done
            jq -r '.targets[] | select(.platform == "linux/arm64") | .log_path' <<< "$result" |
                xargs grep -l 'private output stage /var/tmp/dsr-build-outtest-linux-arm64-' >/dev/null || exit 1
            # The private copy is gone and the shared tree only ever held the
            # in-place lane's output.
            ! compgen -G "/var/tmp/dsr-build-outtest-linux-*" >/dev/null || exit 1
            cmp -s "$root/src/outtest" "$root/fixtures/amd64" || exit 1
        fi
    done
)
if test_parallel_shared_output_isolation; then
    pass "parallel same-host targets with a shared -o path each collect their own architecture"
else
    fail "parallel same-host targets still share one output file"
fi

# A cancelled run (Ctrl-C / TERM) TERMs every worker's build process group,
# which never reaches the removals after the build command. The private
# source copy must still be removed, or each interrupted release leaves a full
# repo copy in /var/tmp with nothing to reap it.
test_parallel_shared_output_stage_removed_on_cancel() (
    local root="$TEMP_DIR/shared-output-cancel" orchestrator_pid waited
    mkdir -p "$root/src" "$root/fixtures"
    write_minimal_target_binary "$root/fixtures/amd64" linux/amd64
    write_minimal_target_binary "$root/fixtures/arm64" linux/arm64
    cat > "$ACT_REPOS_DIR/cancelout.yaml" <<EOF
tool_name: cancelout
repo: test/cancelout
local_path: $root/src
language: go
binary_name: cancelout
build_cmd: cp "$root/fixtures/\$GOARCH" cancelout && sleep 60
targets: [linux/amd64, linux/arm64]
act_job_map:
  linux/amd64: null
  linux/arm64: null
cross_compile:
  linux/amd64:
    host: trj
    env:
      GOOS: linux
      GOARCH: amd64
  linux/arm64:
    host: trj
    env:
      GOOS: linux
      GOARCH: arm64
EOF
    build_lock_acquire() { return 0; }
    build_lock_release() { return 0; }
    selector_acquire_slot() { return 0; }
    selector_release_slot() { return 0; }
    act_orchestrate_build cancelout v1.0.0-cancel --parallel-jobs 2 \
        --output-dir "$root/out" -- linux/amd64 linux/arm64 \
        > "$root/result.json" 2> "$root/orchestrator.log" &
    orchestrator_pid=$!
    # Wait for the staged lane's copy to exist and its build to be running.
    for ((waited = 0; waited < 300; waited++)); do
        compgen -G "/var/tmp/dsr-build-cancelout-linux-arm64-*/source/cancelout" >/dev/null && break
        sleep 0.1
    done
    compgen -G "/var/tmp/dsr-build-cancelout-linux-arm64-*/source/cancelout" >/dev/null || {
        kill -TERM "$orchestrator_pid" 2>/dev/null; wait "$orchestrator_pid" 2>/dev/null; exit 1; }
    kill -TERM "$orchestrator_pid"
    wait "$orchestrator_pid" 2>/dev/null
    # Cleanup runs in the cancelled build's own subshell; allow it to finish.
    for ((waited = 0; waited < 200; waited++)); do
        compgen -G "/var/tmp/dsr-build-cancelout-linux-*" >/dev/null || exit 0
        sleep 0.1
    done
    exit 1
)
if test_parallel_shared_output_stage_removed_on_cancel; then
    pass "a cancelled parallel run removes the private output-stage source copy"
else
    fail "a cancelled parallel run left its output-stage source copy: $(compgen -G '/var/tmp/dsr-build-cancelout-linux-*' | tr '\n' ' ')"
fi

# Where a private source copy cannot make the shared file private (a Windows
# host, or an absolute GOBIN outside the tree), the colliding targets run one
# after the other; unrelated targets keep running in parallel.
test_parallel_shared_output_serialization() (
    local root="$TEMP_DIR/shared-output-serial" case_name
    mkdir -p "$root"
    build_lock_acquire() { return 0; }
    build_lock_release() { return 0; }
    selector_acquire_slot() { return 0; }
    selector_release_slot() { return 0; }
    act_run_native_build() {
        local slug="${2//\//-}"
        printf '%s start %s stage=%s\n' "$(date +%s%N)" "$slug" "${DSR_NATIVE_OUTPUT_STAGE:-}" >> "$root/$case_name.timeline"
        sleep 1
        printf '%s end %s\n' "$(date +%s%N)" "$slug" >> "$root/$case_name.timeline"
        jq -nc --arg platform "$2" '{platform: $platform, status: "failed", exit_code: 6}'
        return 6
    }
    for case_name in windows gobin; do
        if [[ "$case_name" == windows ]]; then
            cat > "$ACT_REPOS_DIR/serialtest.yaml" <<'EOF'
tool_name: serialtest
repo: test/serialtest
local_path: C:/d/serialtest
language: go
binary_name: serialtest
build_cmd: go build -o serialtest.exe ./cmd/serialtest
targets: [windows/amd64, windows/arm64, linux/amd64]
act_job_map: {windows/amd64: null, windows/arm64: null, linux/amd64: null}
cross_compile:
  windows/amd64: {host: wlap}
  windows/arm64: {host: wlap}
  linux/amd64: {host: trj}
EOF
            act_orchestrate_build serialtest "v1.0.0-$case_name" --parallel-jobs 3 \
                --output-dir "$root/out-$case_name" -- linux/amd64 windows/amd64 windows/arm64 \
                > /dev/null 2>&1
        else
            cat > "$ACT_REPOS_DIR/serialtest.yaml" <<'EOF'
tool_name: serialtest
repo: test/serialtest
local_path: /srv/serialtest
language: go
binary_name: serialtest
build_cmd: go build -o "$GOBIN/serialtest" ./cmd/serialtest
targets: [linux/amd64, linux/arm64, darwin/arm64]
act_job_map: {linux/amd64: null, linux/arm64: null, darwin/arm64: null}
env:
  GOBIN: /srv/shared-bin
cross_compile:
  linux/amd64: {host: trj}
  linux/arm64: {host: trj}
  darwin/arm64: {host: mmini}
EOF
            act_orchestrate_build serialtest "v1.0.0-$case_name" --parallel-jobs 3 \
                --output-dir "$root/out-$case_name" -- darwin/arm64 linux/amd64 linux/arm64 \
                > /dev/null 2>&1
        fi
    done
    # Replay each timeline: the two colliding targets never overlap, the
    # unrelated target (launched first) runs alongside them, and nothing was
    # staged. The barrier suite also covers an unrelated target listed last.
    local first second third
    for case_name in windows gobin; do
        if [[ "$case_name" == windows ]]; then
            first=windows-amd64 second=windows-arm64 third=linux-amd64
        else
            first=linux-amd64 second=linux-arm64 third=darwin-arm64
        fi
        ! grep -q 'stage=1' "$root/$case_name.timeline" || exit 1
        awk -v a="$first" -v b="$second" -v c="$third" '
            $2 == "start" { start[$3] = $1 } $2 == "end" { stop[$3] = $1 }
            END {
                if (!(a in stop) || !(b in start) || !(c in start)) exit 1
                if (start[b] < stop[a]) exit 1
                if (start[a] > stop[c]) exit 1
            }' "$root/$case_name.timeline" || exit 1
    done
)
if test_parallel_shared_output_serialization; then
    pass "unstageable shared outputs (Windows host, external GOBIN) serialize only the colliding targets"
else
    fail "unstageable shared outputs ran concurrently or blocked unrelated targets"
fi

output_queue_status=0
test_parallel_output_queue || output_queue_status=$?
case "$output_queue_status" in
    0) pass "deferred output collisions leave independent hosts runnable and preserve retry and cancellation receipts" ;;
    77) skip "output queue barriers require Python, jq and yq" ;;
    *) fail "output collision queue blocked independent hosts or changed durable attempt identity" ;;
esac

# A target whose host is at its concurrency limit must queue for a slot for up
# to one build timeout instead of failing after the selector's short default
# (trj's 4-slot lane failed focr linux/arm64 after 300s while a 2.5h build held
# the slots). The failure, when the budget really expires, names the host,
# the wait, and the fix.
test_worker_capacity_wait_budget() (
    local fixture="$TEMP_DIR/capacity-wait" budget_log status mode
    mkdir -p "$fixture"
    budget_log="$fixture/budgets"
    act_platform_uses_act() { return 1; }
    selector_release_slot() { return 0; }
    _act_build_orchestration_target() {
        printf 'built\n' >> "$fixture/built"
        jq -nc '{platform: "linux/arm64", host: "trj", status: "failed", exit_code: 6}'
        return 6
    }
    _ACT_BUILD_TIMEOUT=10800
    for mode in default override granted; do
        status=0
        if [[ "$mode" == granted ]]; then
            selector_acquire_slot() { printf '%s\n' "$DSR_SELECTOR_WAIT_TIMEOUT" >> "$budget_log"; return 0; }
        else
            selector_acquire_slot() { printf '%s\n' "$DSR_SELECTOR_WAIT_TIMEOUT" >> "$budget_log"; return 2; }
        fi
        if [[ "$mode" == override ]]; then
            DSR_SELECTOR_WAIT_TIMEOUT=77 _act_run_target_worker capwait v1.0.0 capwait-run linux/arm64 1 \
                "$fixture/$mode.log" "$fixture/$mode.json" false null '{}' "" "" trj \
                > /dev/null 2>&1 || status=$?
        else
            _act_run_target_worker capwait v1.0.0 capwait-run linux/arm64 1 \
                "$fixture/$mode.log" "$fixture/$mode.json" false null '{}' "" "" trj \
                > /dev/null 2>&1 || status=$?
        fi
        printf '%s %s\n' "$mode" "$status" >> "$fixture/statuses"
    done
    [[ "$(cat "$budget_log")" == $'10800\n77\n10800' ]] || exit 1
    [[ "$(cat "$fixture/statuses")" == $'default 2\noverride 2\ngranted 6' ]] || exit 1
    [[ "$(cat "$fixture/built")" == built ]] || exit 1
    jq -e '.exit_code == 2 and
        (.error | startswith("Host capacity acquisition failed: no build slot on trj after waiting")) and
        (.error | contains("budget 10800s"))' "$fixture/default.json" >/dev/null || exit 1
    jq -e '.error | contains("budget 77s")' "$fixture/override.json" >/dev/null || exit 1
)
if test_worker_capacity_wait_budget; then
    pass "capacity-limited targets queue for one build timeout and fail with an actionable error"
else
    fail "capacity-limited target wait budget or failure message is wrong"
fi

if test_capacity_resume_accounting; then
    pass "capacity refusals preserve compiler retry allowance through exact-run resume"
else
    fail "capacity refusal accounting exhausted retries or trusted backend classification"
fi

relocation_test_status=0
test_relocation_recovery || relocation_test_status=$?
case "$relocation_test_status" in
    0) pass "reviewed relocation uses genuine worker receipts and preserves completed target evidence" ;;
    77) skip "relocation integration requires Go and its local fixture dependencies" ;;
    *) fail "reviewed relocation rejected genuine target outcomes or lost receipt/source authority" ;;
esac
relocation_matrix_status=0
test_relocation_recovery --relocation-matrix-only || relocation_matrix_status=$?
case "$relocation_matrix_status" in
    0) pass "reviewed singleton relocation preserves completed native variants and updates their matrix configuration binding" ;;
    77) skip "mixed relocation integration requires its local fixture dependencies" ;;
    *) fail "mixed native matrix could not safely relocate its failed singleton target" ;;
esac
relocation_variant_status=0
test_relocation_recovery --relocation-variant-only || relocation_variant_status=$?
case "$relocation_variant_status" in
    0) pass "reviewed exact-variant relocation preserves siblings, recipe custody and retry budgets across repeated resume" ;;
    77) skip "qualified variant relocation integration requires its local fixture dependencies" ;;
    *) fail "qualified native variant relocation lost task, source, retry or manifest authority" ;;
esac
relocation_preview_status=0
test_relocation_recovery --relocation-preview-only || relocation_preview_status=$?
case "$relocation_preview_status" in
    0) pass "strict resume previews validate exact approved task routes without worker access or state changes" ;;
    77) skip "strict resume preview integration requires its local fixture dependencies" ;;
    *) fail "strict resume previews changed evidence or admitted an invalid task, recipe or relocation" ;;
esac
recipe_binding_status=0
test_relocation_recovery --recipe-binding-only || recipe_binding_status=$?
case "$recipe_binding_status" in
    0) pass "ordinary and strict singleton resumes retain exact recipe authority and reviewed relocation" ;;
    77) skip "repository recipe binding integration requires its local fixture dependencies" ;;
    *) fail "repository recipe drift admitted stale completed output or prevented an honest retry" ;;
esac

if test_backend_receipt_isolation; then
    pass "backend and worker stdout retain exact result authority independent of diagnostic logs"
else
    fail "diagnostic output authorized backend success or replaced an exact worker result"
fi

if test_receipt_producer; then
    pass "artifact receipt producer preserves complete bytes and hashing custody"
else
    fail "artifact receipt producer lost bytes or admitted changed files"
fi

if test_worker_artifact_inventory; then
    pass "complete artifact inventories survive worker persistence and exact-byte reuse checks"
else
    fail "worker artifact inventory was truncated, lost, or admitted changed output"
fi

if test_workflow_artifact_inventory; then
    pass "complete workflow inventories survive materialization and independent admission"
else
    fail "workflow inventory was truncated, lost, or admitted contradictory output"
fi

if test_worker_group_lifecycle; then
    pass "owned target groups drain before receipts and capacity release"
else
    fail "target worker cancellation or descendant lifecycle regressed"
fi

if test_worker_stdin_isolation; then
    pass "stdin-consuming target workers preserve dispatch, receipts, cancellation and resume"
else
    fail "target worker stdin isolation or execution accounting regressed"
fi

if test_dispatch_reservation_recovery; then
    pass "dispatch persistence and coordinator loss preserve immutable attempts and exact resume"
else
    fail "dispatch reservation recovery or coordinator refusal classification regressed"
fi

# Cleanup
if [[ "${DSR_TEST_KEEP_TMP:-0}" == "1" ]]; then
    echo "Retained test fixture: $TEMP_DIR" >&2
else
    rm -rf "$TEMP_DIR"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Summary"
echo "═══════════════════════════════════════════════════════════════"
echo -e "  ${GREEN}Passed:${NC}  $PASS"
echo -e "  ${RED}Failed:${NC}  $FAIL"
echo -e "  ${YELLOW}Skipped:${NC} $SKIP"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
