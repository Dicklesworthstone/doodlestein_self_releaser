#!/usr/bin/env bash
# Real controller, checkpoint imports, aggregate admission and finalizer entry.
# The xwin compiler driver and finalizer network engine are explicit boundaries;
# no plan, collector, SLSA validator or state implementation is replaced.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 jq bash flock sha256sum timeout; do
    command -v "$tool" >/dev/null || { printf 'SKIP requires %s\n' "$tool"; exit 0; }
done
[[ "$(uname -s)" == Linux ]] || { printf 'SKIP requires Linux\n'; exit 0; }
python3 - "$ROOT" <<'PY'
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix="dsr-build-assets-"))
repo = work / "repo"
(repo / "src").mkdir(parents=True)
(repo / "scripts").mkdir()
for name in ("release_builds.sh", "release_bundle.sh", "slsa.sh", "release_finalize.sh", "release_finalize_core.sh"):
    shutil.copyfile(source / "src" / name, repo / "src" / name)
checks = 0
print("Fixtures: " + str(work), flush=True)


def check(label, condition):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print("PASS " + label, flush=True)


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + "\n")


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


# The driver parses the repeated argv contract and supplies producer fixtures.
# These bytes are not asserted to be Windows executables or Rust compilation.
(repo / "scripts/xwin-build.sh").write_text('''#!/usr/bin/env bash
exec python3 "$(dirname "$0")/driver.py" "$@"
''')
(repo / "scripts/driver.py").write_text(r'''
import hashlib, json, sys
from pathlib import Path
args = sys.argv[1:]
def arg(key): return args[args.index(key)+1]
selected = [args[i+1] for i, v in enumerate(args) if v == '--bin']
assert len(selected) == len(set(selected)) and selected
assert arg('--release-repo') == 'owner/app' and arg('--tool') == 'app'
spec = json.loads(Path(arg('--manifest')).read_text())
mode = Path(spec['control']).read_text().strip()
with Path(spec['trace']).open('a') as log: log.write(json.dumps(args)+'\n')
if mode == 'fail': sys.exit(42)
root = Path(arg('--run-dir')); (root/'artifacts').mkdir(parents=True)
artifacts = []
for binary in selected:
    name = arg('--asset-name') if '--asset-name' in args else binary+'-aarch64-pc-windows-msvc.exe'
    data = (binary+' producer fixture\n').encode()
    (root/'artifacts'/name).write_bytes(data)
    artifacts.append({'name':name,'target':'windows/arm64','archive_format':'binary',
                      'sha256':hashlib.sha256(data).hexdigest(),'size_bytes':len(data)})
if mode == 'omit': artifacts.pop()
if mode == 'extra': artifacts.append(dict(artifacts[0],name='extra.exe'))
if mode == 'rename': artifacts[-1]['name'] = 'substitute.exe'
if mode == 'format': artifacts[-1]['archive_format'] = 'none'
if mode == 'corrupt': (root/'artifacts'/artifacts[-1]['name']).write_bytes(b'changed payload')
manifest = root/'release/build-manifest.json'; manifest.parent.mkdir()
manifest.write_text(json.dumps({'schema_version':'1.0.0','tool':arg('--tool'),'version':arg('--release-tag'),
    'run_id':'11111111-1111-4111-8111-111111111111','built_at':'2026-09-24T00:00:00Z','status':'success',
    'source':{'git_sha':arg('--source-sha'),'git_ref':'refs/tags/'+arg('--release-tag'),'dependencies':[]},
    'summary':{'total':1,'success':1,'failed':0},'artifacts':artifacts}))
print(json.dumps({'kind':'dsr-xwin-build','status':'verified','exit_code':0,
                  'release_manifest':{'path':str(manifest),'sha256':hashlib.sha256(manifest.read_bytes()).hexdigest()}}))
''')
control = work / "control"
control.write_text("good")
trace = work / "calls.jsonl"
toolchain = work / "toolchain.json"
save(toolchain, {"control": str(control), "trace": str(trace)})
linux = work / "linux"
(linux / "artifacts").mkdir(parents=True)
(linux / "artifacts/app-linux").write_bytes(b"linux producer fixture\n")
linux_manifest = {"schema_version": "1.0.0", "tool": "app", "version": "v1.2.3", "status": "success",
                  "run_id": "22222222-2222-4222-8222-222222222222", "built_at": "2026-09-24T00:00:00Z",
                  "source": {"git_sha": "a" * 40, "git_ref": "refs/tags/v1.2.3", "dependencies": []},
                  "summary": {"total": 1, "success": 1, "failed": 0},
                  "artifacts": [{"name": "app-linux", "target": "linux/amd64", "archive_format": "binary",
                                 "sha256": digest(linux / "artifacts/app-linux"), "size_bytes": 23}]}
# Derive the fixture byte length, not the expected selected filename.
linux_manifest["artifacts"][0]["size_bytes"] = (linux / "artifacts/app-linux").stat().st_size
save(linux / "manifest.json", linux_manifest)
plan = {"schema_version": 1, "repo": "owner/app", "tool": "app", "tag": "v1.2.3", "source_sha": "a" * 40,
        "required_targets": ["windows/arm64", "linux/amd64"],
        "required_assets": [
            {"name": "helper-aarch64-pc-windows-msvc.exe", "target": "windows/arm64", "archive_format": "binary"},
            {"name": "app-linux", "target": "linux/amd64", "archive_format": "binary"},
            {"name": "app-aarch64-pc-windows-msvc.exe", "target": "windows/arm64", "archive_format": "binary"}],
        "builds": [
            {"id": "windows", "driver": "xwin", "targets": ["windows/arm64"], "project": str(work / "project"),
             "toolchain_manifest": str(toolchain), "toolchain_sha256": digest(toolchain), "binaries": ["helper", "app"]},
            {"id": "linux", "driver": "import", "targets": ["linux/amd64"], "manifest": str(linux / "manifest.json"),
             "manifest_sha256": digest(linux / "manifest.json"), "artifacts_dir": str(linux / "artifacts")}]}
planfile = work / "plan.json"
save(planfile, plan)


def run(out, expected=0, selected=planfile, extra=()):
    result = subprocess.run(["bash", str(repo / "src/release_builds.sh"), "--plan", str(selected),
                             "--output-dir", str(out), *extra], capture_output=True, timeout=45)
    if result.returncode != expected:
        raise AssertionError(f"wanted {expected}, got {result.returncode}: {result.stderr.decode()} {result.stdout.decode()}")
    value = json.loads(result.stdout)
    check("one controller receipt agrees with process exit", value["exit_code"] == expected)
    return value


# The actual public finalizer entry point performs preview, build execution,
# frozen-plan comparison, collection and manifest handoff. Only its network
# engine is replaced here, after all those production checks have run.
bridge = work / "finalize.sh"
bridge.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$1/src/release_finalize.sh" || exit $?
shift
release_finalize() {
    local root=$1 manifest=''
    shift
    while (($#)); do
        case "$1" in --build-manifest) manifest=$2; shift 2 ;; *) shift ;; esac
    done
    _slsa_manifest_statement "$manifest" owner/app test:handoff >/dev/null || return $?
    printf 'called\n' >> "$TEST_ENGINE_CALLS"
    jq -cn --slurpfile manifest "$manifest" '{kind:"dsr-release-finalization-result",status:"ready",exit_code:0,
        required_assets:$manifest[0].required_assets,artifact_count:($manifest[0].artifacts|length)}'
}
release_finalize_build_plan "$@"
''')


def pipeline(label, selected, expected=0, mutation=""):
    import os
    result = subprocess.run(["bash", str(bridge), str(repo), "--build-plan", str(selected),
                             "--build-dir", str(work / label)],
                            env=dict(os.environ, TEST_ENGINE_CALLS=str(work / "engine-calls"), TEST_SET_MUTATION=mutation),
                            capture_output=True, timeout=45)
    if result.returncode != expected:
        raise AssertionError(f"pipeline wanted {expected}, got {result.returncode}: {result.stdout.decode()} {result.stderr.decode()}")
    value = json.loads(result.stdout)
    check("one finalizer receipt agrees with process exit", value["exit_code"] == expected)
    return value


try:
    out = work / "complete"
    preview = run(out, extra=("--dry-run",))
    check("preview canonicalizes both binary selection and complete asset contract",
          preview["plan"]["builds"][1]["binaries"] == ["app", "helper"] and
          preview["plan"]["required_assets"] == sorted(plan["required_assets"], key=lambda a: a["name"]))
    check("planning creates neither state nor compiler calls", not out.exists() and not trace.exists())
    result = run(out, extra=("--jobs", "2"))
    calls = [json.loads(line) for line in trace.read_text().splitlines()]
    check("one compiler invocation receives both literal --bin arguments",
          len(calls) == 1 and [calls[0][i+1] for i, a in enumerate(calls[0]) if a == "--bin"] == ["app", "helper"])
    aggregate = read(Path(result["bundle"]["manifest"]))
    expected_assets = sorted(plan["required_assets"], key=lambda a: a["name"])
    check("full contract survives input plan, generated build set and aggregate",
          read(out / "build-set.json")["required_assets"] == expected_assets and aggregate["required_assets"] == expected_assets)
    check("all selected binaries survive immutable checkpoint import", len(aggregate["artifacts"]) == 3)
    initial = (Path(result["bundle"]["manifest"]).stat().st_ino, result["bundle"]["manifest_sha256"])
    reordered = copy.deepcopy(plan)
    reordered["required_assets"].reverse()
    reordered["builds"][0]["binaries"].reverse()
    save(work / "reordered.json", reordered)
    before = trace.read_bytes()
    retry = run(out, selected=work / "reordered.json")
    check("reordered retry never recompiles or changes bundle identity",
          before == trace.read_bytes() and initial == (Path(retry["bundle"]["manifest"]).stat().st_ino, retry["bundle"]["manifest_sha256"]))

    without = copy.deepcopy(plan)
    without.pop("required_assets")
    save(work / "implicit.json", without)
    for mode in ("omit", "extra", "rename", "format", "corrupt"):
        control.write_text(mode)
        folder = work / ("bad-" + mode)
        failed = run(folder, 1, work / "implicit.json")
        check(mode + " cannot hide behind a successful target without an explicit asset contract",
              failed["failed_builds"] == ["windows"] and failed["completed_builds"] == 1 and
              not (folder / "completed/windows").exists() and not (folder / "bundle").exists())
    control.write_text("good")
    run(work / "bad-omit", selected=work / "implicit.json")
    check("failed multi-binary job is retried without replacing completed native output",
          len(read(work / "bad-omit/state.json")["jobs"]["linux"]["attempts"]) == 1)

    for label, mutate in (
        ("binary-and-binaries", lambda p: p["builds"][0].update(binary="app")),
        ("empty-binaries", lambda p: p["builds"][0].update(binaries=[])),
        ("null-binaries", lambda p: p["builds"][0].update(binaries=None)),
        ("string-binaries", lambda p: p["builds"][0].update(binaries="app")),
        ("case-binaries", lambda p: p["builds"][0].update(binaries=["app", "APP"])),
        ("too-many-binaries", lambda p: p["builds"][0].update(binaries=[f"bin{i}" for i in range(33)])),
        ("path-binary", lambda p: p["builds"][0].update(binaries=["../app"])),
        ("set-rename", lambda p: p["builds"][0].update(asset_name="one.exe")),
        ("null-assets", lambda p: p.update(required_assets=None)),
        ("extra-asset", lambda p: p["required_assets"].append(dict(p["required_assets"][0], name="extra.exe"))),
        ("bad-format", lambda p: p["required_assets"][0].update(archive_format="zip")),
        ("missing-native", lambda p: p.update(required_assets=[a for a in p["required_assets"] if a["target"] != "linux/amd64"])),
    ):
        value = copy.deepcopy(plan)
        mutate(value)
        save(work / "invalid.json", value)
        before = trace.read_bytes()
        folder = work / ("invalid-" + label)
        run(folder, 4, work / "invalid.json")
        check(label + " rejected before creating build state or starting compilers", not folder.exists() and before == trace.read_bytes())

    single = copy.deepcopy(without)
    single["builds"][0].pop("binaries")
    single["builds"][0].update(binary="app", asset_name="custom.exe")
    save(work / "single.json", single)
    value = run(work / "single", selected=work / "single.json")
    check("existing single-binary custom naming remains operational",
          any(a["name"] == "custom.exe" for a in read(Path(value["bundle"]["manifest"]))["artifacts"]))
    value = pipeline("pipeline", planfile)
    check("real combined entry point hands off complete contract and all payloads",
          value["required_assets"] == expected_assets and value["artifact_count"] == 3 and value["builds"]["status"] == "verified")
    control.write_text("omit")
    before_engine = (work / "engine-calls").read_bytes()
    value = pipeline("pipeline-incomplete", planfile, 1)
    check("missing companion prevents any network-finalizer call",
          value["status"] == "builds_incomplete" and before_engine == (work / "engine-calls").read_bytes())
    control.write_text("good")
    pipeline("pipeline-incomplete", planfile)
    check("same combined command recovers the missing companion", len((work / "engine-calls").read_text().splitlines()) == 2)

    # Fault injection after the actual controller succeeds. A self-consistent
    # changed build-set hash must not erase the independently reviewed contract
    # at the finalizer handoff. The real plan/build/checkpoint code still runs.
    actual = repo / "src/release_builds_actual.sh"
    shutil.copyfile(repo / "src/release_builds.sh", actual)
    (repo / "src/release_builds.sh").write_text(r'''#!/usr/bin/env bash
set -uo pipefail
result=$(mktemp)
bash "$(dirname "$0")/release_builds_actual.sh" "$@" > "$result"
rc=$?
if [[ $rc != 0 || "$*" == *--dry-run* || -z "${TEST_SET_MUTATION:-}" ]]; then
    cat "$result"; exit "$rc"
fi
python3 - "$result" <<'INJECT'
import hashlib, json, os, sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
path = Path(result['build_set'])
plan = json.loads(path.read_text())
if os.environ['TEST_SET_MUTATION'] == 'drop':
    plan.pop('required_assets')
else:
    plan['required_assets'] = [a for a in plan['required_assets'] if not a['name'].startswith('helper-')]
path.write_text(json.dumps(plan)+'\n')
result['build_set_sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
print(json.dumps(result))
INJECT
''')
    for mutation in ("drop", "subset"):
        before_engine = (work / "engine-calls").read_bytes()
        value = pipeline("handoff-" + mutation, planfile, 7, mutation)
        check(mutation + " contract substitution is rejected before finalizer invocation",
              value["status"] == "error" and before_engine == (work / "engine-calls").read_bytes())
    shutil.copyfile(actual, repo / "src/release_builds.sh")

    # All three original input locations can disappear after completed import.
    toolchain.rename(work / "offline-toolchain.json")
    linux.rename(work / "offline-linux")
    before = trace.read_bytes()
    run(out)
    check("completed multi-binary verification is independent of original build inputs", trace.read_bytes() == before)
    print(f"\nBuild-plan asset contracts: {checks} passed, 0 failed", flush=True)
except Exception:
    print("Failing fixtures retained: " + str(work), file=sys.stderr)
    raise
PY
