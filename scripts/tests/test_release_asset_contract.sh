#!/usr/bin/env bash
# Exact operator-selected asset contracts through real collection, manifests,
# provenance and direct upload admission. Payloads are producer byte fixtures;
# no compiler, signer, network adapter, or validation function is replaced.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 jq bash flock sha256sum; do
    command -v "$tool" >/dev/null || { printf 'SKIP requires %s\n' "$tool"; exit 0; }
done
python3 - "$ROOT" <<'PY'
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
checks = 0
work = Path(tempfile.mkdtemp(prefix="dsr-asset-contract-"))
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


# Expectations are selected independently of each producer's output inventory.
contract = [
    {"name": "app-linux", "target": "linux/amd64", "archive_format": "binary"},
    {"name": "app-v1-linux", "target": "linux/amd64", "archive_format": "binary"},
    {"name": "app-windows.exe", "target": "windows/arm64", "archive_format": "binary"},
    {"name": "helper-windows.exe", "target": "windows/arm64", "archive_format": "binary"},
    {"name": "app-windows.zip", "target": "windows/arm64", "archive_format": "zip"},
]


def fixture(label):
    directory = work / label
    directory.mkdir()
    records = []
    for identity, target in (("linux", "linux/amd64"), ("windows", "windows/arm64")):
        root = directory / identity / "artifacts"
        root.mkdir(parents=True)
        artifacts = []
        names = ["app-linux", "app-v1-linux"] if identity == "linux" else [
            "app-windows.exe", "helper-windows.exe", "app-windows.zip"]
        for name in names:
            data = ("main fixture\n" if identity == "linux" else name + " fixture\n").encode()
            (root / name).write_bytes(data)
            artifacts.append({"name": name, "target": target,
                              "archive_format": "zip" if name.endswith(".zip") else "binary",
                              "sha256": digest(root / name), "size_bytes": len(data)})
        manifest = directory / identity / "manifest.json"
        save(manifest, {"schema_version": "1.0.0", "tool": "app", "version": "v1.2.3",
                        "run_id": "11111111-1111-4111-8111-111111111111", "status": "success",
                        "built_at": "2026-09-24T00:00:00Z", "publishable": True,
                        "source": {"git_sha": "a" * 40, "git_ref": "refs/tags/v1.2.3", "dependencies": []},
                        "summary": {"total": 1, "success": 1, "failed": 0},
                        "requested_targets": [target], "artifacts": artifacts})
        records.append({"id": identity, "targets": [target], "manifest": str(manifest),
                        "manifest_sha256": digest(manifest), "artifacts_dir": str(root)})
    plan = {"schema_version": 1, "repo": "owner/app", "tool": "app", "tag": "v1.2.3",
            "source_sha": "a" * 40, "required_targets": ["linux/amd64", "windows/arm64"],
            "required_assets": copy.deepcopy(contract), "builds": records}
    save(directory / "plan.json", plan)
    return directory, plan


def collect(directory, expected=0, plan=None, output=None, dry=False):
    plan = plan or directory / "plan.json"
    output = output or directory / "bundle"
    args = ["bash", str(repo / "src/release_bundle.sh"), "--plan", str(plan), "--output-dir", str(output)]
    if dry:
        args.append("--dry-run")
    p = subprocess.run(args, capture_output=True, timeout=30)
    if p.returncode != expected:
        raise AssertionError(f"collection wanted {expected}, got {p.returncode}: {p.stderr.decode()}")
    check("collection exit matches selected outcome", p.returncode == expected)
    if expected not in (0, 1):
        check("rejected collection emits no success JSON", not p.stdout)
        return None
    return json.loads(p.stdout)


def admission(manifest, expected=0):
    for program in (
        'source "$1/src/slsa.sh"; _slsa_manifest_statement "$2" owner/app test:assets',
        'source "$1/src/slsa.sh"; source "$1/src/release_payloads.sh"; _rup_manifest "$2" owner/app v1.2.3 ' + "a" * 40,
    ):
        p = subprocess.run(["bash", "-c", program, "_", str(repo), str(manifest)], capture_output=True, timeout=10)
        check("shared admission and direct upload agree", p.returncode == expected)
        if expected:
            check("failed shared admission has empty stdout", not p.stdout)


def mutate(directory, plan, change):
    manifest = directory / "windows/manifest.json"
    value = read(manifest)
    change(value)
    save(manifest, value)
    # Repin on purpose, so failures prove contract enforcement, not hash drift.
    plan["builds"][1]["manifest_sha256"] = digest(manifest)
    save(directory / "plan.json", plan)


try:
    directory, plan = fixture("complete")
    result = collect(directory, dry=True)
    check("dry-run retains selected asset contract without creating state",
          result["plan"]["required_assets"] == sorted(contract, key=lambda r: r["name"]) and not (directory / "bundle").exists())
    result = collect(directory)
    manifest = Path(result["manifest"])
    aggregate = read(manifest)
    check("aggregate retains independent expected payloads", aggregate["required_assets"] == sorted(contract, key=lambda r: r["name"]))
    check("aliases count as assets, not platforms", len(aggregate["artifacts"]) == 5 and aggregate["summary"]["total"] == 2)
    admission(manifest)
    before = (manifest.read_bytes(), manifest.stat().st_ino)
    reordered = copy.deepcopy(plan)
    reordered["required_assets"].reverse()
    reordered["required_targets"].reverse()
    reordered["builds"].reverse()
    save(directory / "reordered.json", reordered)
    collect(directory, plan=directory / "reordered.json")
    check("reordered contract reuses identical manifest inode and bytes", before == (manifest.read_bytes(), manifest.stat().st_ino))
    changed = copy.deepcopy(plan)
    changed["required_assets"][0]["name"] = "different-name"
    save(directory / "changed.json", changed)
    collect(directory, 2, plan=directory / "changed.json")
    changed.pop("required_assets")
    save(directory / "omitted.json", changed)
    collect(directory, 2, plan=directory / "omitted.json")
    check("changed or omitted contracts never replace completed data", before == (manifest.read_bytes(), manifest.stat().st_ino))

    proof = directory / "release.intoto.jsonl"
    p = subprocess.run(["bash", str(repo / "src/slsa.sh"), "generate-manifest", str(manifest), result["artifacts_dir"],
                        "--repository", "owner/app", "--builder", "test:assets", "--output", str(proof)], capture_output=True, timeout=10)
    check("full contract passes actual provenance generation", p.returncode == 0)
    check("statement covers every companion and installer alias", len(read(proof)["subject"]) == len(contract))
    p = subprocess.run(["bash", str(repo / "src/slsa.sh"), "verify-release", str(proof), result["artifacts_dir"],
                        "--manifest", str(manifest), "--repository", "owner/app", "--builder", "test:assets"], capture_output=True, timeout=10)
    check("real complete-manifest verification succeeds", p.returncode == 0)

    for label, change in (
        ("missing-companion", lambda m: m["artifacts"].pop(1)),
        ("missing-archive", lambda m: m["artifacts"].pop(2)),
        ("wrong-format", lambda m: m["artifacts"][0].update(archive_format="none")),
        ("renamed-companion", lambda m: m["artifacts"][1].update(name="other.exe")),
        ("extra-binary", lambda m: m["artifacts"].append(dict(m["artifacts"][0], name="extra.exe"))),
    ):
        case, selected = fixture(label)
        mutate(case, selected, change)
        # The unchanged target count would admit each reduced manifest alone.
        if label.startswith("missing"):
            admission(case / "windows/manifest.json")
        collect(case, 7)
        check(label + " blocks publication and the bad checkpoint", not (case / "bundle/release").exists() and not (case / "bundle/inputs/windows").exists())
        check(label + " preserves the independently completed Linux shard", (case / "bundle/inputs/linux/build-manifest.json").is_file())

    for label, edit in (
        ("null", lambda p: p.update(required_assets=None)),
        ("empty", lambda p: p.update(required_assets=[])),
        ("string", lambda p: p.update(required_assets="app.exe")),
        ("duplicate", lambda p: p["required_assets"].append(copy.deepcopy(p["required_assets"][0]))),
        ("case-collision", lambda p: p["required_assets"].append(dict(p["required_assets"][0], name="APP-LINUX"))),
        ("traversal", lambda p: p["required_assets"][0].update(name="../app")),
        ("unknown-field", lambda p: p["required_assets"][0].update(path="/untrusted")),
        ("missing-format", lambda p: p["required_assets"][0].pop("archive_format")),
        ("unknown-format", lambda p: p["required_assets"][0].update(archive_format="rar")),
        ("bad-target", lambda p: p["required_assets"][0].update(target="freebsd/amd64")),
        ("long-name", lambda p: p["required_assets"][0].update(name="x" * 129)),
        ("missing-platform", lambda p: p.update(required_assets=p["required_assets"][:2])),
        ("many-assets", lambda p: p.update(required_assets=[dict(contract[0], name=f"asset-{i}") for i in range(257)])),
    ):
        value = copy.deepcopy(plan)
        edit(value)
        file = directory / (label + ".json")
        save(file, value)
        out = directory / ("invalid-" + label)
        collect(directory, 4, plan=file, output=out)
        check(label + " is rejected before output mutation", not out.exists())
        invalid = copy.deepcopy(aggregate)
        invalid["required_assets"] = value["required_assets"]
        save(directory / "bad-manifest.json", invalid)
        admission(directory / "bad-manifest.json", 4)

    for label, change in (
        ("drop-alias", lambda m: m["artifacts"].pop(1)),
        ("drop-companion", lambda m: m["artifacts"].pop(-1)),
        ("change-format", lambda m: m["artifacts"][0].update(archive_format="none")),
        ("switch-target", lambda m: m["artifacts"][0].update(target="windows/arm64")),
    ):
        value = copy.deepcopy(aggregate)
        change(value)
        save(directory / "bad-manifest.json", value)
        admission(directory / "bad-manifest.json", 4)
        check(label + " leaves original published proof untouched", len(read(proof)["subject"]) == 5)

    partial, selected = fixture("recover")
    missing = partial / "windows/artifacts/helper-windows.exe"
    missing.rename(partial / "held-helper.exe")
    result = collect(partial, 1)
    check("absent required bytes report an incomplete build", result["missing_builds"] == ["windows"] and not result["publishable"])
    retained = partial / "bundle/inputs/linux/build-manifest.json"
    retained_before = (retained.read_bytes(), retained.stat().st_ino)
    (partial / "linux").rename(partial / "offline-linux")
    (partial / "held-helper.exe").rename(missing)
    collect(partial)
    check("missing payload recovery retains existing checkpoint inode and bytes", retained_before == (retained.read_bytes(), retained.stat().st_ino))
    check("restored companion is imported without original Linux outputs", (partial / "bundle/release/artifacts/helper-windows.exe").read_bytes() == missing.read_bytes())

    legacy, value = fixture("legacy")
    value.pop("required_assets")
    save(legacy / "plan.json", value)
    legacy_result = collect(legacy)
    check("omitted contract retains existing manifest format", "required_assets" not in read(Path(legacy_result["manifest"])))
    print(f"\nRelease asset contract: {checks} passed, 0 failed", flush=True)
except Exception:
    print("Failing fixtures retained: " + str(work), file=sys.stderr)
    raise
PY
