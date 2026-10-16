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

source = Path(os.environ.get("DSR_TEST_RUNNER_SOURCE", sys.argv[1]))
work = Path(tempfile.mkdtemp(prefix="dsr-runner-regressions-"))
scripts = work / "scripts"
tests = scripts / "tests"
tests.mkdir(parents=True)
(work / "tests").mkdir()
shutil.copyfile(source / "scripts/run-all-tests.sh", scripts / "run-all-tests.sh")
for name, code in (("test_selected_pass.sh", 0), ("test_selected_fail.sh", 19), ("test_other.sh", 0)):
    (tests / name).write_text("#!/usr/bin/env bash\nexit " + str(code) + "\n")
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
