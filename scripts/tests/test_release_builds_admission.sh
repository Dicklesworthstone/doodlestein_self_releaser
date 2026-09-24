#!/usr/bin/env bash
# Actual coordinator and collector. cp/hash wrappers create explicit blocked
# storage boundaries; they do not replace any manifest or payload validator.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 bash jq flock sha256sum cp; do
    command -v "$tool" >/dev/null || { printf 'SKIP requires %s\n' "$tool"; exit 0; }
done
[[ "$(uname -s)" == Linux ]] || { printf 'SKIP requires Linux\n'; exit 0; }
python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix="dsr-admission-"))
checks = 0
print("Fixtures: " + str(work), flush=True)


def check(label, condition):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print("PASS " + label, flush=True)


def save(file, value):
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(json.dumps(value) + "\n")


def read(file):
    return json.loads(file.read_text())


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


install = work / "install"
(install / "src").mkdir(parents=True)
for name in ("release_builds", "release_bundle", "slsa"):
    selected = Path(os.environ["DSR_TEST_COORDINATOR"]) if name == "release_builds" and "DSR_TEST_COORDINATOR" in os.environ else root / "src" / (name + ".sh")
    shutil.copyfile(selected, install / "src" / (name + ".sh"))
commands = {name: shutil.which(name) for name in ("cp", "sha256sum")}
(install / "bin").mkdir()
for name in commands:
    (install / "bin" / name).write_text('#!/usr/bin/env bash\nexec python3 "' + str(install / 'boundary.py') + '" ' + name + ' "$@"\n')
    (install / "bin" / name).chmod(0o755)
save(install / "commands.json", commands)
(install / "boundary.py").write_text(r'''
import json, os, signal, subprocess, sys, time
from pathlib import Path
role, args = sys.argv[1], sys.argv[2:]
case = Path(os.environ["DSR_ADMISSION_CASE"])
mode = (case / "mode").read_text().strip()
selected = False
if role == "cp" and args:
    dest = args[-1]
    selected = (mode in ("import", "leak") and "/attempts/" in dest and "/import." in dest) or (mode == "collection" and "/bundle/" in dest)
elif role == "sha256sum":
    source = os.readlink("/proc/self/fd/0")
    selected = mode == "verify" and "/completed/" in source
marker = case / "marker.json"
if selected and not marker.exists():
    # Deliberately retain inherited lock descriptors in the sleeping child.
    child = subprocess.Popen(["sleep", "120"], close_fds=False)
    marker.write_text(json.dumps(dict(pid=os.getpid(), child=child.pid, group=os.getpgrp())))
    if mode != "leak":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(120)
commands = json.loads((Path(__file__).parent / "commands.json").read_text())
os.execv(commands[role], [commands[role]] + args)
''')


def fixture(label):
    case = work / label
    case.mkdir()
    (case / "mode").write_text("good")
    (case / "artifacts").mkdir()
    file = case / "artifacts/demo"
    file.write_bytes(b"admitted producer fixture\n")
    file.chmod(0o755)
    manifest = dict(schema_version="1.0.0", tool="demo", version="v1.2.3", status="success",
        run_id="11111111-1111-4111-8111-111111111111", built_at="2026-09-24T00:00:00Z",
        source=dict(git_sha="a"*40, git_ref="refs/tags/v1.2.3", dependencies=[]),
        requested_targets=["linux/amd64"], summary=dict(total=1, success=1, failed=0),
        artifacts=[dict(name="demo", target="linux/amd64", archive_format="binary", size_bytes=file.stat().st_size, sha256=digest(file))])
    save(case / "manifest.json", manifest)
    save(case / "plan.json", dict(schema_version=1, repo="owner/demo", tool="demo", tag="v1.2.3", source_sha="a"*40,
        required_targets=["linux/amd64"], builds=[dict(id="producer", driver="import", targets=["linux/amd64"],
            manifest=str(case / "manifest.json"), manifest_sha256=digest(case / "manifest.json"), artifacts_dir=str(case / "artifacts"))]))
    return case


def command(case, *extra):
    return ["bash", str(install / "src/release_builds.sh"), "--plan", str(case / "plan.json"), "--output-dir", str(case / "builds"), *extra]


def env(case):
    return dict(os.environ, DSR_ADMISSION_CASE=str(case), PATH=str(install / "bin") + ":" + os.environ["PATH"])


def run(case, expected=0, *extra):
    proc = subprocess.run(command(case, *extra), env=env(case), capture_output=True, timeout=35)
    (case / "last.stdout").write_bytes(proc.stdout)
    (case / "last.stderr").write_bytes(proc.stderr)
    check("expected coordinator exit " + str(expected), proc.returncode == expected)
    value = json.loads(proc.stdout)
    check("one JSON result agrees with exit status", value["exit_code"] == expected)
    return value


def stopped(pid):
    file = Path("/proc") / str(pid) / "stat"
    return not file.exists() or file.read_text().split(") ", 1)[1].split()[0] == "Z"


def wait_stopped(pid):
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline and not stopped(pid):
        time.sleep(0.05)
    return stopped(pid)


def cancelled(case, phase):
    (case / "mode").write_text(phase)
    with (case / "cancel.stdout").open("wb") as out, (case / "cancel.stderr").open("wb") as err:
        proc = subprocess.Popen(command(case), env=env(case), stdout=out, stderr=err, start_new_session=True)
        marker = None
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not (case / "marker.json").exists() and proc.poll() is None:
                time.sleep(0.05)
            check(phase + " reaches the real helper's storage boundary", (case / "marker.json").exists())
            marker = read(case / "marker.json")
            run(case, 2)
            proc.send_signal(signal.SIGTERM)
            try:
                code = proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                raise AssertionError(phase + " did not respond to CLI cancellation")
            check(phase + " cancellation returns interrupted status", code == 5)
            value = read(case / "cancel.stdout")
            check("cancellation has no success claim", value["exit_code"] == 5 and value["status"] == "error" and not value["publishable"])
            check("owned blocked storage process stopped", wait_stopped(marker["pid"]))
            check("owned storage descendant stopped", wait_stopped(marker["child"]))
        finally:
            # These groups were created by this test or returned by its own
            # instrumented child, never selected from repository state.
            for group in {proc.pid, marker["group"] if marker else proc.pid}:
                if group != os.getpgrp():
                    try:
                        os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            proc.wait()
    return value


def completed_identity(case):
    return {str(p): (p.stat().st_ino, digest(p)) for p in (case / "builds/completed").rglob("*") if p.is_file()}


try:
    # First probe requires no new option, so the unchanged baseline demonstrates
    # the cancellation bug rather than merely rejecting an unfamiliar flag.
    case = fixture("cancel-import")
    unrelated = subprocess.Popen(["sleep", "120"])
    try:
        cancelled(case, "import")
        check("unrelated processes are not signalled", unrelated.poll() is None)
    finally:
        unrelated.terminate()
        unrelated.wait()
    state = read(case / "builds/state.json")["jobs"]["producer"]
    check("interrupted import retains its candidate", state["candidate"] is not None and state["complete"] is None)
    check("interrupted import never creates a complete release", not (case / "builds/bundle").exists())
    (case / "mode").write_text("good")
    run(case, 0, "--admission-timeout", "20")
    check("retry after cancellation admits the complete matrix", (case / "builds/bundle/release/artifacts/demo").read_bytes() == (case / "artifacts/demo").read_bytes())

    for phase in ("collection", "verify"):
        case = fixture("cancel-" + phase)
        if phase == "verify":
            run(case)
            before = completed_identity(case)
        cancelled(case, phase)
        if phase == "collection":
            before = completed_identity(case)
        check("completed producer checkpoint survives " + phase + " cancellation", bool(before) and before == completed_identity(case))
        (case / "mode").write_text("good")
        run(case)
        check(phase + " retry preserves completed checkpoint bytes and inode", before == completed_identity(case))

    for phase in ("import", "collection", "verify"):
        case = fixture("deadline-" + phase)
        if phase == "verify":
            run(case)
        (case / "mode").write_text(phase)
        # Collection begins after real producer import and verification. Give
        # those unblocked stages time to complete; the selected copy then
        # blocks for 120 seconds, well beyond this actual deadline.
        budget = "10" if phase == "collection" else "1"
        value = run(case, 1 if phase == "import" else 5, "--admission-timeout", budget)
        check(phase + " reaches its intended deadline boundary", (case / "marker.json").exists())
        marker = read(case / "marker.json")
        check(phase + " deadline terminates storage process and descendants", wait_stopped(marker["pid"]) and wait_stopped(marker["child"]))
        check("timed-out admission never reports publishable success", not value["publishable"])
        if phase == "import":
            state = read(case / "builds/state.json")["jobs"]["producer"]
            check("import deadline is recorded without discarding candidate", state["attempts"][-1]["exit_code"] == 5 and state["candidate"] is not None)
        else:
            check("global deadline names its cause", "timed out" in value["error"])
        frozen_plan = read(case / "builds/state.json")["plan_sha256"]
        (case / "mode").write_text("good")
        run(case, 0, "--admission-timeout", "20")
        check("deadline budget can change without changing frozen plan", read(case / "builds/state.json")["plan_sha256"] == frozen_plan)

    case = fixture("leaked-helper-child")
    (case / "mode").write_text("leak")
    run(case)
    check("successful admission cannot leave group descendants holding the lock", wait_stopped(read(case / "marker.json")["child"]))
    run(case)

    case = fixture("crashed-coordinator")
    (case / "mode").write_text("import")
    with (case / "crash.stdout").open("wb") as out, (case / "crash.stderr").open("wb") as err:
        proc = subprocess.Popen(command(case), env=env(case), stdout=out, stderr=err, start_new_session=True)
        marker = None
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not (case / "marker.json").exists() and proc.poll() is None:
                time.sleep(0.05)
            check("crash probe reaches owned admission helper", (case / "marker.json").exists())
            marker = read(case / "marker.json")
            check("admission owns a separate group from its coordinator", marker["group"] != proc.pid)
            proc.kill()
            proc.wait()
            run(case, 2)
            check("orphaned live admission retains the coordinator lock", not stopped(marker["pid"]))
        finally:
            if marker:
                os.killpg(marker["group"], signal.SIGKILL)
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
    check("crash probe helpers stop before retry", wait_stopped(marker["pid"]) and wait_stopped(marker["child"]))
    (case / "mode").write_text("good")
    run(case)
    check("crash retry retains interrupted import history", [a["status"] for a in read(case / "builds/state.json")["jobs"]["producer"]["attempts"]] == ["interrupted", "completed"])

    case = fixture("options")
    value = run(case, 0, "--dry-run", "--admission-timeout", "7")
    check("preview exposes the selected admission deadline without state", value["admission_timeout"] == 7 and not (case / "builds").exists())
    default = run(case, 0, "--dry-run")
    check("default admission budget is finite", default["admission_timeout"] == 900)
    for bad in ("0", "-1", "86401", "1.5", "no"):
        run(case, 4, "--admission-timeout", bad)
        check("invalid deadline cannot create state", not (case / "builds").exists())
    run(case, 4, "--admission-timeout", "2", "--admission-timeout", "3")
    check("duplicate deadline never creates state", not (case / "builds").exists())
    print("\nBounded build admission: %d passed" % checks, flush=True)
finally:
    if sys.exc_info()[0] is None:
        shutil.rmtree(work)
PY
