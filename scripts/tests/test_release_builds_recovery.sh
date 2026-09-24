#!/usr/bin/env bash
# Real coordinator, collector, manifest/hash admission and filesystem recovery.
# Compilers are explicit command-boundary fixtures; no live Rust/Windows claim.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 bash jq flock timeout sha256sum; do
    command -v "$tool" >/dev/null || { printf 'SKIP requires %s\n' "$tool"; exit 0; }
done
[[ "$(uname -s)" == Linux ]] || { printf 'SKIP requires Linux\n'; exit 0; }
python3 - "$ROOT" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix="dsr-compiled-import-"))
checks = 0
print("Fixtures: " + str(work), flush=True)


def check(label, condition):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print("PASS " + label, flush=True)


def save(p, value):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value) + "\n")


def read(p):
    return json.loads(p.read_text())


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


install = work / "install"
(install / "src").mkdir(parents=True)
(install / "scripts").mkdir()
for module in ("release_builds", "release_bundle", "slsa"):
    shutil.copyfile(source / "src" / (module + ".sh"), install / "src" / (module + ".sh"))
# These two production command paths are the only substituted implementation.
(install / "dsr").write_text('#!/usr/bin/env bash\nexec python3 "$(dirname "$0")/driver.py" dsr "$@"\n')
(install / "scripts/xwin-build.sh").write_text('#!/usr/bin/env bash\nexec python3 "$(dirname "$0")/../driver.py" xwin "$@"\n')
(install / "driver.py").write_text(r'''
import hashlib, json, os, sys
from pathlib import Path
kind, args = sys.argv[1], sys.argv[2:]
def arg(flag): return args[args.index(flag) + 1]
if kind == "dsr":
    cfg = Path(os.environ["DSR_CONFIG_DIR"])
    spec = json.loads((cfg / "config.yaml").read_text())
    out = Path(arg("--output-dir"))
    manifest = out / "demo-v1.2.3-manifest.json"
    target = "linux/amd64"
    names = ["demo-linux", "helper-linux"]
else:
    spec = json.loads(Path(arg("--manifest")).read_text())
    out = Path(arg("--run-dir")) / "artifacts"
    manifest = out.parent / "release/build-manifest.json"
    target = "windows/arm64"
    binaries = [args[i+1] for i, a in enumerate(args) if a == "--bin"]
    assert binaries == ["demo", "helper"]
    names = [b + "-aarch64-pc-windows-msvc.exe" for b in binaries]
    assert json.loads(Path(arg("--sibling-crates")).read_text()) == []
case = Path(spec["case"])
with (case / "calls").open("a") as f: f.write(kind + "\n")
mode = (case / "mode").read_text().strip()
out.mkdir(parents=True)
artifacts = []
for name in names:
    data = ("compiled fixture " + name + "\n").encode()
    (case / name).write_bytes(data)
    if mode != "missing" or name != names[-1]:
        (out / name).write_bytes(data)
        (out / name).chmod(0o755)
    artifacts.append(dict(name=name, target=target, archive_format="binary", size_bytes=len(data),
                          sha256=hashlib.sha256(data).hexdigest()))
uuid = "11111111-1111-4111-8111-111111111111"
value = dict(schema_version="1.0.0", tool="demo", version="v1.2.3", run_id=uuid, built_at="2026-09-24T00:00:00Z",
             source=dict(git_sha="a"*40, git_ref="refs/tags/v1.2.3", dependencies=[]),
             requested_targets=[target], status="success", publishable=True, build_purpose="release",
             summary=dict(total=1, success=1, failed=0), artifacts=artifacts)
if mode == "wrong-source": value["source"]["git_sha"] = "b"*40
manifest.parent.mkdir(parents=True, exist_ok=True)
manifest.write_text(json.dumps(value) + "\n")
if kind == "dsr":
    if spec["resume"]:
        checkpoint = Path(os.environ["DSR_STATE_DIR"]) / "builds/demo/v1.2.3" / uuid / "state.json"
        checkpoint.parent.mkdir(parents=True)
        checkpoint.write_text(json.dumps(dict(tool="demo", version="v1.2.3", git_sha="a"*40, run_id=uuid,
            targets=[target], status="completed", context=dict(output_dir=str(out), build_purpose="release", publishable=True))))
    envelope = dict(command="build", status="success", exit_code=0, details=dict(manifest=str(manifest)))
else:
    envelope = dict(kind="dsr-xwin-build", status="verified", exit_code=0,
                    release_manifest=dict(path=str(manifest), sha256=hashlib.sha256(manifest.read_bytes()).hexdigest()))
print(json.dumps(envelope))
sys.exit(23 if mode == "nonzero" else 0)
''')


def fixture(label, driver="xwin", resume=False):
    case = work / label
    case.mkdir()
    (case / "mode").write_text("missing")
    target = "windows/arm64" if driver == "xwin" else "linux/amd64"
    spec = dict(case=str(case), resume=resume)
    if driver == "xwin":
        save(case / "toolchain.json", spec)
        save(case / "siblings.json", [])
        job = dict(id="compiled", driver=driver, targets=[target], project=str(case / "project"),
                   toolchain_manifest=str(case / "toolchain.json"), toolchain_sha256=digest(case / "toolchain.json"),
                   binaries=["helper", "demo"], package="workspace", offline=True,
                   siblings=dict(path=str(case / "siblings.json"), sha256=digest(case / "siblings.json")), timeout=30)
        names = ["demo-aarch64-pc-windows-msvc.exe", "helper-aarch64-pc-windows-msvc.exe"]
    else:
        save(case / "config/config.yaml", spec)
        save(case / "config/repos.yaml", {})
        save(case / "config/hosts.yaml", {})
        job = dict(id="compiled", driver=driver, targets=[target], config_dir=str(case / "config"),
                   config_files={p.name: digest(p) for p in (case / "config").iterdir()}, resume=resume, timeout=30)
        names = ["demo-linux", "helper-linux"]
    plan = dict(schema_version=1, repo="owner/demo", tool="demo", tag="v1.2.3", source_sha="a"*40,
                required_targets=[target], required_assets=[dict(name=n, target=target, archive_format="binary") for n in names],
                builds=[job])
    save(case / "plan.json", plan)
    return case


def run(case, expected=0):
    p = subprocess.run(["bash", str(install / "src/release_builds.sh"), "--plan", str(case / "plan.json"),
                        "--output-dir", str(case / "builds"), "--jobs", "2"], capture_output=True, timeout=40)
    (case / "last.stdout").write_bytes(p.stdout)
    (case / "last.stderr").write_bytes(p.stderr)
    check("coordinator returns expected exit " + str(expected), p.returncode == expected)
    value = json.loads(p.stdout)
    check("single typed result matches process status", value["exit_code"] == expected)
    return value


def job_state(case):
    return read(case / "builds/state.json")["jobs"]["compiled"]


def attempt(case):
    return case / "builds/attempts/compiled/000001"


def repair(case):
    selected = job_state(case)["candidate"]
    manifest = read(Path(selected["manifest"]))
    for asset in manifest["artifacts"]:
        dest = Path(selected["artifacts_dir"]) / asset["name"]
        if not dest.exists():
            shutil.copyfile(case / asset["name"], dest)
            dest.chmod(0o755)


def retained(case):
    files = [p for p in attempt(case).rglob("*") if p.is_file() and "import." not in str(p) and
             "admission-recovery-" not in str(p) and p.name != "admission.log"]
    return {str(p): (p.stat().st_ino, digest(p)) for p in files}


try:
    for driver, resume in (("xwin", False), ("dsr", False), ("dsr", True)):
        case = fixture(driver + str(resume), driver, resume)
        result = run(case, 1)
        state = job_state(case)
        pin = copy.deepcopy(state["candidate"])
        check("successful compiler selects a candidate despite missing companion", pin is not None and state["complete"] is None)
        check("partial import is not a publishable matrix", not result["publishable"] and not (case / "builds/bundle").exists())
        before = retained(case)
        run(case, 1)
        check("repeated missing bytes retain the exact selected pin", job_state(case)["candidate"] == pin)
        check("recovery never reruns the successful compiler", len((case / "calls").read_text().splitlines()) == 1)
        check("recovery does not add a compiler attempt", len(job_state(case)["attempts"]) == 1)
        repair(case)
        # Recovery consumes pinned local copies, not the original config/toolchain.
        offline = [case / "toolchain.json", case / "siblings.json"] if driver == "xwin" else [case / "config"]
        for p in offline:
            p.rename(p.with_name(p.name + ".offline"))
        result = run(case)
        check("recovery completes the same manifest selection", job_state(case)["complete"] == pin and job_state(case)["candidate"] is None)
        check("source-side evidence is not rewritten", all(retained(case).get(p) == identity for p, identity in before.items()))
        check("one compiler invocation is sufficient through completion", len((case / "calls").read_text().splitlines()) == 1)
        manifest = read(Path(result["bundle"]["manifest"]))
        check("full aggregate includes every companion", len(manifest["artifacts"]) == 2 and manifest["component_builds"][0]["manifest_sha256"] == pin["manifest_sha256"])
        checkpoint = case / "builds/completed/compiled/build-manifest.json"
        identity = (checkpoint.stat().st_ino, digest(checkpoint))
        Path(pin["artifacts_dir"]).rename(Path(pin["artifacts_dir"]).with_name("offline-output"))
        run(case)
        check("accepted checkpoint survives original output disappearance", identity == (checkpoint.stat().st_ino, digest(checkpoint)))
        check("post-import retry still never recompiles", len((case / "calls").read_text().splitlines()) == 1)

    for driver, relative, mutation in (
        ("xwin", "command.json", lambda v: v + ["--bin", "unselected"]),
        ("xwin", "inputs.json", lambda v: dict(v, plan_sha256="0"*64)),
        ("xwin", "stdout.json", lambda v: dict(v, exit_code=True)),
        ("xwin", "stdout.json", lambda v: dict(v, release_manifest=dict(path="/elsewhere", sha256="0"*64))),
        ("xwin", "toolchain.json", lambda v: dict(v, changed=True)),
        ("xwin", "siblings.json", lambda v: [{}]),
        ("dsr", "command.json", lambda v: v + ["--no-sync"]),
        ("dsr", "stdout.json", lambda v: dict(v, details=None)),
        ("dsr", "config/config.yaml", lambda v: dict(v, changed=True)),
    ):
        case = fixture("drift-" + str(checks), driver)
        run(case, 1)
        pin = copy.deepcopy(job_state(case)["candidate"])
        repair(case)
        file = attempt(case) / relative
        original = file.read_bytes()
        original_mode = file.stat().st_mode & 0o777
        file.chmod(original_mode | 0o200)  # Deliberate owner-side drift of pinned test inputs.
        save(file, mutation(read(file)))
        run(case, 1)
        check("changed retained evidence cannot be bypassed by recompilation", job_state(case)["candidate"] == pin and len((case / "calls").read_text().splitlines()) == 1)
        check("damaged evidence cannot complete a build", not (case / "builds/completed/compiled").exists())
        file.write_bytes(original)
        file.chmod(original_mode)
        run(case)
        check("restoring original evidence recovers without another compiler", len((case / "calls").read_text().splitlines()) == 1)

    case = fixture("manifest-drift")
    run(case, 1)
    pin = copy.deepcopy(job_state(case)["candidate"])
    repair(case)
    file = Path(pin["manifest"])
    original = file.read_bytes()
    save(file, dict(read(file), built_at="2026-09-24T01:00:00Z"))
    run(case, 1)
    check("new manifest bytes are never silently repinned", job_state(case)["candidate"] == pin and len((case / "calls").read_text().splitlines()) == 1)
    file.write_bytes(original)
    run(case)

    case = fixture("candidate-path")
    run(case, 1)
    repair(case)
    saved = read(case / "builds/state.json")
    modified = copy.deepcopy(saved)
    modified["jobs"]["compiled"]["candidate"]["artifacts_dir"] = str(case)
    save(case / "builds/state.json", modified)
    run(case, 1)
    check("candidate cannot redirect reads to another directory", len((case / "calls").read_text().splitlines()) == 1 and not (case / "builds/completed/compiled").exists())
    save(case / "builds/state.json", saved)
    run(case)

    case = fixture("nonzero")
    (case / "mode").write_text("nonzero")
    run(case, 1)
    check("success-shaped output from a nonzero compiler has no candidate", job_state(case)["candidate"] is None)
    (case / "mode").write_text("good")
    run(case)
    check("actual compiler failure still starts a fresh attempt", len((case / "calls").read_text().splitlines()) == 2 and len(job_state(case)["attempts"]) == 2)

    case = fixture("wrong-source")
    (case / "mode").write_text("wrong-source")
    run(case, 1)
    pin = copy.deepcopy(job_state(case)["candidate"])
    (case / "mode").write_text("good")
    run(case, 1)
    check("shared source admission is not weakened by import recovery", job_state(case)["candidate"] == pin and not (case / "builds/bundle").exists())
    check("wrong-source receipt cannot trigger automatic replacement compilation", len((case / "calls").read_text().splitlines()) == 1)

    # A bad candidate does not prevent independently pinned jobs from finishing.
    case = fixture("independent", "dsr")
    run(case, 1)
    plan = read(case / "plan.json")
    # Add a second job before initializing a separate output, preserving the
    # ordinary frozen-plan rule rather than changing a running coordinator.
    other = fixture("independent-windows")
    (other / "mode").write_text("good")
    plan["builds"].append(dict(read(other / "plan.json")["builds"][0], id="windows"))
    plan["required_targets"].append("windows/arm64")
    plan["required_assets"] += read(other / "plan.json")["required_assets"]
    (case / "builds").rename(case / "first-plan")
    save(case / "plan.json", plan)
    run(case, 1)
    state = read(case / "builds/state.json")
    check("independent target finishes while compiler import remains incomplete", state["jobs"]["windows"]["complete"] is not None)
    repair(case)
    run(case)
    check("recovery retains the independent completed job", len((other / "calls").read_text().splitlines()) == 1)

    print("\nCompiled import recovery: %d passed" % checks, flush=True)
finally:
    # Keep failed fixtures and diagnostics; only this suite's successful
    # temporary installation is eligible for its normal test cleanup.
    if sys.exc_info()[0] is None:
        shutil.rmtree(work)
PY
