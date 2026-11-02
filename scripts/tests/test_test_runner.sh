#!/usr/bin/env bash
# Exercise the real runner with small executable test files. No suite selection,
# accounting or worker implementation is replaced by a canned result.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

source = Path(os.environ.get("DSR_TEST_RUNNER_SOURCE", sys.argv[1]))
work = Path(tempfile.mkdtemp(prefix="dsr-runner-regressions-"))
scripts = work / "scripts"
tests = scripts / "tests"
tests.mkdir(parents=True)
(work / "tests").mkdir()
shutil.copyfile(source / "scripts/run-all-tests.sh", scripts / "run-all-tests.sh")
for name, code in (("test_selected_pass.sh", 0), ("test_selected_fail.sh", 19), ("test_other.sh", 0)):
    (tests / name).write_text("#!/usr/bin/env bash\nexit " + str(code) + "\n")
(tests / "test_selected_fail.sh").write_text(
    '#!/usr/bin/env bash\nprintf "\\033[31mFAIL retained diagnostic <source> & detail\\033[0m\\n"\nexit 19\n')
(tests / "test_skip_failure.sh").write_text('#!/usr/bin/env bash\nprintf "SKIP: marker before failure\\n"\nexit 19\n')
for label, message in (("colon", "SKIP: optional runtime unavailable"), ("space", "SKIP requires optional runtime")):
    (tests / ("test_skip_" + label + ".sh")).write_text('#!/usr/bin/env bash\nprintf "' + message + '\\n"\nexit 0\n')
for name, assertion in (("test_selected_pass.bats", "true"), ("test_selected_fail.bats", "false")):
    (work / "tests" / name).write_text('@test "runner fixture" { ' + assertion + '; }\n')

checks = 0
failures = 0
def check(label, condition):
    global checks, failures
    checks += 1
    if not condition:
        failures += 1
    print(("PASS " if condition else "FAIL ") + label, flush=True)

def run(label, args, expected, env=None):
    result = subprocess.run(["bash", str(scripts / "run-all-tests.sh"), *args],
                            env=env, capture_output=True, timeout=30)
    (work / (label + ".stdout")).write_bytes(result.stdout)
    (work / (label + ".stderr")).write_bytes(result.stderr)
    check(label + " exit agrees", result.returncode == expected)
    return result

print("Retained runner fixtures: " + str(work), flush=True)
literal = run("literal-selection", ["--shell-only", "--filter", "test_selected_pass.sh"], 0)
summary = json.loads(literal.stdout)
check("literal selection still executes its passing file",
      summary["tests_run"] == 1 and summary["tests_passed"] == 1)
for parallel in ("1", "2"):
    result = run("glob-" + parallel,
                 ["--shell-only", "--filter", "*selected*", "--parallel", parallel], 1)
    summary = json.loads(result.stdout)
    check("glob executes both matching shell files with parallel=" + parallel,
          summary["tests_run"] == 2 and summary["tests_passed"] == 1 and
          summary["tests_failed"] == 1 and summary["failed_tests"] == ["test_selected_fail.sh"])
    result = run("exclude-" + parallel,
                 ["--shell-only", "--filter", "*selected*", "--exclude", "*fail*", "--parallel", parallel], 0)
    summary = json.loads(result.stdout)
    check("exclusion retains matching passing test with parallel=" + parallel,
          summary["tests_run"] == 1 and summary["tests_passed"] == 1 and summary["tests_failed"] == 0
          and summary["failed_tests"] == [])
result = run("no-match", ["--filter", "*does-not-exist*", "--parallel", "2"], 1)
check("empty selection cannot print a successful zero-test summary", b'"tests_passed": 0' not in result.stdout)
result = run("skip-before-failure", ["--shell-only", "--filter", "test_skip_failure.sh"], 1)
summary = json.loads(result.stdout)
check("a skip marker cannot hide a failing process",
      summary["tests_run"] == 1 and summary["tests_failed"] == 1 and summary["tests_skipped"] == 0)
for label in ("colon", "space"):
    result = run("skip-" + label, ["--shell-only", "--filter", "test_skip_" + label + ".sh"], 0)
    summary = json.loads(result.stdout)
    check(label + " dependency skip cannot be misreported as an executed pass",
          summary["tests_run"] == 1 and summary["tests_passed"] == 0 and summary["tests_skipped"] == 1)
listing = run("bats-list", ["--bats-only", "--filter", "*selected*", "--exclude", "*fail*", "--list"], 0)
check("Bats discovery uses the same glob/exclusion rules",
      b"test_selected_pass.bats" in listing.stdout and b"test_selected_fail.bats" not in listing.stdout)
if shutil.which("bats"):
    result = run("bats-execution", ["--bats-only", "--filter", "*selected*", "--parallel", "2"], 1)
    summary = json.loads(result.stdout)
    check("actual Bats pass and failure remain distinct",
          summary["tests_run"] == 2 and summary["tests_passed"] == 1 and summary["tests_failed"] == 1)
else:
    print("NOTE: Bats execution unavailable; discovery was checked, runtime not qualified", flush=True)

# The oldest test waits for the third test. With two slots, the third must
# start when the second finishes, rather than waiting for the oldest PID.
# Record actual overlap under a file lock so a fix cannot simply exceed two.
actor = work / "slot-actor.py"
actor.write_text('''import fcntl, json, pathlib, sys, time
root, name = pathlib.Path(sys.argv[1]), sys.argv[2]
state = root / "slot-state.json"
def change(delta):
    with state.open("a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        data = json.loads(f.read() or '{"active":0,"peak":0,"started":0}')
        data["active"] += delta
        data["peak"] = max(data["peak"], data["active"])
        data["started"] += int(delta > 0)
        f.seek(0)
        f.truncate()
        json.dump(data, f)
change(1)
try:
    if name == "first":
        (root / "slot-first-started").touch()
        deadline = time.monotonic() + 5
        while not (root / "slot-third-started").exists():
            if time.monotonic() >= deadline:
                raise SystemExit(27)
            time.sleep(0.02)
    elif name == "second":
        time.sleep(0.2)
    else:
        deadline = time.monotonic() + 5
        while not (root / "slot-first-started").exists():
            if time.monotonic() >= deadline:
                raise SystemExit(28)
            time.sleep(0.02)
        (root / "slot-third-started").touch()
finally:
    change(-1)
''')
import shlex
for index, name in enumerate(("first", "second", "third")):
    (tests / ("test_slot_%d.sh" % index)).write_text(
        '#!/usr/bin/env bash\nexec ' + shlex.join([sys.executable, str(actor), str(work), name]) + '\n')
result = run("slot-reuse", ["--shell-only", "--filter", "test_slot_*", "--parallel", "2"], 0)
summary = json.loads(result.stdout)
slot_state = json.loads((work / "slot-state.json").read_text())
check("finished slot is reused while the oldest test is still running",
      summary["tests_run"] == 3 and summary["tests_passed"] == 3)
check("slot reuse keeps the configured concurrency and reaps every test",
      slot_state == {"active": 0, "peak": 2, "started": 3})

# Both processes execute the same file in the same checkout. Synchronization
# makes the second writer replace the first writer's daily log on the old
# runner before either process classifies its output.
(tests / "test_concurrent.sh").write_text('''#!/usr/bin/env bash
printf '%s\\n' "$DSR_RUNNER_ROW"
: > "$DSR_RUNNER_READY"
for attempt in {1..400}; do
    [[ ! -e "$DSR_RUNNER_RELEASE" ]] || exit 0
    sleep 0.025
done
exit 18
''')
release = work / "concurrent-release"
children = []
ready = True
try:
    for label, row in (("pass", "PASS independent assertion"), ("skip", "SKIP: optional dependency")):
        marker = work / ("concurrent-" + label + ".ready")
        child = subprocess.Popen(
            ["bash", str(scripts / "run-all-tests.sh"), "--shell-only", "--filter", "test_concurrent.sh", "--ci"],
            env=dict(os.environ, DSR_RUNNER_ROW=row, DSR_RUNNER_READY=str(marker),
                     DSR_RUNNER_RELEASE=str(release)), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        children.append((label, child))
        deadline = time.monotonic() + 10
        while not marker.exists() and child.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        if not marker.exists():
            ready = False
            break
finally:
    release.write_text("continue\n")
    concurrent = {}
    for label, child in children:
        out, err = child.communicate(timeout=15)
        (work / ("concurrent-" + label + ".stdout")).write_bytes(out)
        (work / ("concurrent-" + label + ".stderr")).write_bytes(err)
        concurrent[label] = (child.returncode, json.loads(out))
check("both concurrent runner processes execute and finish",
      ready and len(concurrent) == 2 and all(code == 0 for code, _ in concurrent.values()))
check("a concurrent dependency skip cannot replace an executed pass",
      concurrent.get("pass", (None, {}))[1].get("tests_passed") == 1 and
      concurrent["pass"][1]["tests_skipped"] == 0)
check("the concurrent dependency skip keeps its own result",
      concurrent.get("skip", (None, {}))[1].get("tests_skipped") == 1 and
      concurrent["skip"][1]["tests_passed"] == 0)
reports = list((work / "logs/tests").rglob("junit.xml"))
check("default concurrent JUnit reports have distinct retained paths", len(reports) == 2)
try:
    report_roots = [ET.parse(path).getroot() for path in reports]
    outcomes = sorted((int(node.attrib["tests"]), int(node.attrib["failures"]),
                       len(node.findall(".//skipped"))) for node in report_roots)
except (ET.ParseError, OSError, KeyError, ValueError) as error:
    print("JUnit parse failure: " + str(error), flush=True)
    outcomes = []
check("retained JUnit reports preserve the independent pass and skip",
      outcomes == [(1, 0, 0), (1, 0, 1)])
before = set(reports)
run("junit-failure", ["--shell-only", "--filter", "test_selected_fail.sh", "--ci"], 1)
fresh_reports = set((work / "logs/tests").rglob("junit.xml")) - before
failure_text = ""
if len(fresh_reports) == 1:
    try:
        failure_text = "".join(ET.parse(fresh_reports.pop()).getroot().itertext())
    except (ET.ParseError, OSError) as error:
        print("Failed-test JUnit parse failure: " + str(error), flush=True)
check("failed-test JUnit preserves colored diagnostics as valid XML text",
      "FAIL retained diagnostic <source> & detail" in failure_text)

# Create a real unwritable result directory at the mktemp boundary. This leaves
# worker execution intact and makes the OS reject result writes. Run unprivileged
# so the boundary is real, not a root-only permission simulation.
if os.geteuid() != 0:
    bin_dir = work / "bin"
    bin_dir.mkdir()
    mktemp = shutil.which("mktemp")
    check("real mktemp is available", mktemp is not None)
    (bin_dir / "mktemp").write_text('#!/usr/bin/env bash\n'
        'directory=$("$DSR_RUNNER_REAL_MKTEMP" "$@") || exit $?\n'
        'chmod 500 "$directory" || exit $?\nprintf "%s\\n" "$directory"\n')
    (bin_dir / "mktemp").chmod(0o755)
    result = run("missing-worker-result", ["--shell-only", "--filter", "*pass*", "--parallel", "2"], 1,
                 env=dict(os.environ, DSR_RUNNER_REAL_MKTEMP=mktemp,
                          PATH=str(bin_dir) + ":" + os.environ["PATH"]))
    summary = json.loads(result.stdout)
    check("missing worker result is counted as a named failure",
          summary["tests_run"] == 1 and summary["tests_failed"] == 1 and
          summary["failed_tests"] == ["test_selected_pass.sh"])
else:
    print("NOTE: root bypasses write permissions; storage refusal not qualified", flush=True)
print("Runner selection/accounting: %d passed, %d failed" % (checks - failures, failures), flush=True)
sys.exit(1 if failures else 0)
PY
