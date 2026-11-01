#!/usr/bin/env bash
# Genuine archive construction/repacking, manifest admission and CLI handoff.
# Producer identities and payloads are owned fixtures, not native compiler proof.
# Only the finalizer's network/signing engine is replaced in the handoff case.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 jq tar zip unzip xz; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
python3 - "$ROOT" "${RELEASE_PACKAGING_TEST_MODULE:-$ROOT/src/release_packaging.sh}" \
    "${RELEASE_FINALIZE_TEST_MODULE:-$ROOT/src/release_finalize.sh}" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile

root, packager, finalizer = map(Path, sys.argv[1:])
work = Path(tempfile.mkdtemp(prefix="dsr-package-variants-"))
print("Retained evidence: " + str(work), flush=True)
passed = 0
calls = 0
source_sha = "1" * 40

def check(label, condition):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print("PASS " + label, flush=True)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True) + "\n")
    return path

def read(path):
    return json.loads(path.read_text())

def invoke(command, expected=0, env=None):
    global calls
    calls += 1
    result = subprocess.run(list(map(str, command)), capture_output=True, timeout=90, env=env)
    (work / ("call-%03d.stdout" % calls)).write_bytes(result.stdout)
    (work / ("call-%03d.stderr" % calls)).write_bytes(result.stderr)
    check("process exit matches expected %d" % expected, result.returncode == expected)
    return result

def package_command(recipe, manifest, incoming, output, pin=None):
    return ["bash", packager, "--recipe", recipe, "--manifest", manifest,
            "--manifest-sha256", pin or sha(manifest), "--artifacts-dir", incoming,
            "--output-dir", output, "--repo", "example/app", "--tag", "v1.2.3", "--sha", source_sha]

def fixture(arch, label=None):
    base = work / (label or arch)
    incoming = base / "incoming"
    incoming.mkdir(parents=True)
    platform = "linux/" + arch
    cpu = "x86_64" if arch == "amd64" else "aarch64"
    artifacts, environments = [], []
    for name, target, triple, mode in (
        ("raw-gnu", platform, cpu + "-unknown-linux-gnu", 0o751),
        ("raw-musl", platform, cpu + "-unknown-linux-musl", 0o750),
        ("raw-win.exe", "windows/arm64", "aarch64-pc-windows-msvc", 0o755),
    ):
        path = incoming / name
        path.write_bytes(("Owned packaging fixture " + triple + "\n").encode())
        path.chmod(mode)
        artifacts.append(dict(name=name, target=target, target_triple=triple,
            archive_format="binary", sha256=sha(path), size_bytes=path.stat().st_size))
        environments.append(dict(target=target, target_triple=triple, method="native", host="fixture",
            build_influence_env=dict(CARGO_BUILD_TARGET=triple, DSR_TARGET_TRIPLE=triple,
                DSR_RELEASE_GIT_SHA=source_sha, DSR_RELEASE_GIT_REF="v1.2.3"),
            cargo_isolation=dict(toolchain=dict(target_triple=triple))))
    variants = [dict(target=a["target"], target_triple=a["target_triple"]) for a in artifacts]
    manifest = write(base / "manifest.json", dict(schema_version="1.0.0", tool="app", version="v1.2.3",
        run_id="12345678-1234-4123-8123-123456789abc", source=dict(git_sha=source_sha, git_ref="v1.2.3", dependencies=[]),
        status="success", built_at="2026-10-09T01:02:03Z", build_purpose="release", publishable=True,
        summary=dict(total=3, success=3, failed=0), requested_targets=[platform, "windows/arm64"],
        required_variants=variants, artifacts=artifacts, build_environments=environments))
    selected = dict(schema_version=1, artifacts=[])
    for index, (original, fmt) in enumerate(((artifacts[0], "tar.gz"), (artifacts[1], "tar.xz"),
                                          (artifacts[1], "zip"), (artifacts[2], "zip"))):
        selected["artifacts"].append(dict(name="package-%d.%s" % (index, fmt), target=original["target"],
            target_triple=original["target_triple"], archive_format=fmt,
            members=[dict(source=original["name"], path="app.exe" if index == 3 else "app")],
            aliases=["alias-%d.%s" % (index, fmt)] if index == 0 else []))
    recipe = write(base / "recipe.json", selected)
    plan = write(base / "plan.json", dict(schema_version=1, repo="example/app", tool="app", tag="v1.2.3",
        source_sha=source_sha, required_targets=[platform, "windows/arm64"], required_variants=variants,
        required_assets=[{k:a[k] for k in ("name", "target", "target_triple", "archive_format")} for a in artifacts],
        builds=[dict(id="native", targets=[platform, "windows/arm64"], variants=variants,
            manifest=str(manifest), manifest_sha256=sha(manifest), artifacts_dir=str(incoming))]))
    return base, incoming, manifest, recipe, plan

def preflight(plan, preview, expected=0):
    return invoke(["bash", "-c", 'source "$1"; _rf_log() { printf "%s\\n" "$*" >&2; }; '
                   '_rf_packaging_contract "$2" "$3"', "_", root / "src/release_packaging_pipeline.sh", plan, preview], expected)

def shared_fixture(label):
    base, incoming, manifest, recipe, plan = fixture("amd64", label)
    producer, selected, execution = read(manifest), read(recipe), read(plan)
    physical = copy.deepcopy(producer["artifacts"])
    for name, payload in (("NOTICE", b"Owned release notice\n"),
                          ("runtime.json", b'{"fixture":true,"schema_version":1}\n'),
                          ("documentation.txt", b"Owned release documentation\n")):
        path = incoming / name
        path.write_bytes(payload)
        producer["artifacts"].append(dict(name=name, target="additional", archive_format="none",
            sha256=sha(path), size_bytes=len(payload)))
    producer["required_assets"] = [{k:a[k] for k in ("name", "target", "target_triple", "archive_format") if k in a}
                                   for a in producer["artifacts"]]
    write(manifest, producer)
    selected["artifacts"] += [dict(name=name, source=name, target="additional", archive_format="none")
                              for name in ("NOTICE", "runtime.json")]
    selected["artifacts"].append(dict(name="documentation.tar.gz", target="additional", archive_format="tar.gz",
        members=[dict(source="documentation.txt", path="README.txt")], aliases=["documentation-compat.tar.gz"]))
    write(recipe, selected)
    execution["required_assets"] = producer["required_assets"]
    execution["builds"] = []
    for index, (identity, artifact) in enumerate(zip(("gnu", "musl", "win"), physical)):
        shard = copy.deepcopy(producer)
        shard["artifacts"] = [artifact] + (producer["artifacts"][3:] if index == 0 else [])
        shard["required_assets"] = [{k:a[k] for k in ("name", "target", "target_triple", "archive_format") if k in a}
                                    for a in shard["artifacts"]]
        shard["required_variants"] = [producer["required_variants"][index]]
        shard["build_environments"] = [producer["build_environments"][index]]
        shard["requested_targets"] = [artifact["target"]]
        shard["summary"] = dict(total=1, success=1, failed=0)
        shard_dir = base / "shards" / identity
        payload_dir = shard_dir / "artifacts"
        payload_dir.mkdir(parents=True)
        for asset in shard["artifacts"]:
            shutil.copy2(incoming / asset["name"], payload_dir / asset["name"])
        shard_manifest = write(shard_dir / "manifest.json", shard)
        execution["builds"].append(dict(id=identity, driver="import", targets=shard["requested_targets"],
            variants=shard["required_variants"], manifest=str(shard_manifest), manifest_sha256=sha(shard_manifest),
            artifacts_dir=str(payload_dir)))
    write(plan, execution)
    return base, incoming, manifest, recipe, plan

def shared_payload_cases():
    # Real coordinator/import/collection/packaging/handoff. Only the downstream
    # signing/network engine is a fixture; the imported manifests do not claim
    # that these payload bytes were produced by native compilers in this test.
    cli = work / "shared-cli"
    cli.mkdir()
    for source, filename in ((finalizer, "release_finalize.sh"), (packager, "release_packaging.sh")):
        shutil.copy2(source, cli / filename)
    for filename in ("release_builds.sh", "release_bundle.sh", "slsa.sh", "platforms.sh", "guardrails.sh",
                     "packaging.sh", "release_packaging_pipeline.sh"):
        shutil.copy2(root / "src" / filename, cli / filename)
    (cli / "release_finalize_core.sh").write_text('''#!/usr/bin/env bash
_rf_log() { printf '%s\\n' "$*" >&2; }
release_finalize() {
    local root=$1 manifest='' repo=''
    shift
    while (($#)); do
        case "$1" in --build-manifest) manifest=$2; shift 2 ;; --repo) repo=$2; shift 2 ;; *) shift ;; esac
    done
    _slsa_manifest_statement "$manifest" "$repo" dsr/fixture > "${DSR_PACKAGE_FIXTURE:?}/proof.json" || return 99
    _slsa_release_assets "$DSR_PACKAGE_FIXTURE/proof.json" "$root" || return 99
    jq -e '.packaging_evidence.kind=="manifest-bound-packaging" and .summary.total==3 and
        (.required_variants|length)==3 and (.required_assets|length)==9 and
        ([.artifacts[]|select(.target=="additional")]|length)==4 and
        all(.artifacts[]|select(.target=="additional"); has("target_triple")|not)' "$manifest" >/dev/null || return 99
    printf 'called\\n' >> "$DSR_PACKAGE_FIXTURE/calls"
    printf '{"kind":"dsr-release-finalization-result","status":"ready","exit_code":0,"fixture":true,"authenticated":false}\\n'
}
''')
    env = dict(os.environ, DSR_PACKAGE_FIXTURE=str(cli))
    base, incoming, manifest, recipe, plan = shared_fixture("shared")
    original, selection = read(manifest), read(plan)
    original_bytes = {p.name: (sha(p), stat.S_IMODE(p.stat().st_mode)) for p in incoming.iterdir()}
    preview = json.loads(invoke(["bash", root / "src/release_builds.sh", "--plan", plan,
                                "--output-dir", base / "dry-run", "--dry-run"]).stdout)
    check("shared requirements do not add workers or physical targets to the plan",
          preview["status"] == "planned" and preview["publishable"] is False and
          preview["plan"]["required_targets"] == ["linux/amd64", "windows/arm64"] and
          len(preview["plan"]["builds"]) == 3 and len(preview["plan"]["required_variants"]) == 3 and
          not (base / "dry-run").exists())
    described = invoke(["bash", packager, "--recipe", recipe, "--describe"])
    preview_file = base / "preview.json"
    preview_file.write_bytes(described.stdout)
    descriptor = read(preview_file)
    check("recipe preview includes each shared input and only explicitly selected shared outputs",
          len(descriptor["inputs"]) == 6 and len(descriptor["required_assets"]) == 9 and
          {a["name"] for a in descriptor["inputs"] if a["target"] == "additional"} ==
              {"NOTICE", "runtime.json", "documentation.txt"} and
          all("target_triple" not in a for a in descriptor["inputs"] + descriptor["required_assets"]
              if a["target"] == "additional"))
    preflight(plan, preview_file)
    output = base / "executed"
    command = ["bash", cli / "release_finalize.sh", "--build-plan", plan, "--build-dir", output,
               "--packaging-recipe", recipe]
    handoff = json.loads(invoke(command, env=env).stdout)
    packaged = handoff["packaging"]
    dist, exported_file = Path(packaged["artifacts_dir"]), Path(packaged["manifest"])
    exported = read(exported_file)
    check("exact execution plan reaches actual packaging and the downstream finalizer",
          handoff["status"] == "ready" and handoff["fixture"] is True and handoff["authenticated"] is False and
          packaged["status"] == "verified" and packaged["publishable"] is True)
    check("shared outputs preserve the physical compiler matrix and success count",
          exported["requested_targets"] == original["requested_targets"] and
          exported["required_variants"] == original["required_variants"] and
          sorted(exported["build_environments"], key=lambda e:(e["target"], e["target_triple"])) ==
              sorted(original["build_environments"], key=lambda e:(e["target"], e["target_triple"])) and
          exported["summary"] == original["summary"])
    check("selected shared owners survive bundle admission exactly once",
          read(output / "bundle/release/build-manifest.json")["required_assets"] ==
              preview["plan"]["required_assets"] and
          len(read(output / "bundle/release/build-manifest.json")["artifacts"]) == 6)
    check("packaged manifest and directory have the exact selected output inventory",
          exported["required_assets"] == descriptor["required_assets"] and
          {p.name for p in dist.iterdir()} == {a["name"] for a in descriptor["required_assets"]} and
          all("target_triple" not in a for a in exported["artifacts"] if a["target"] == "additional"))
    check("all packaged shared and physical outputs are provenance subjects",
          {a["name"]:a["digest"]["sha256"] for a in read(cli / "proof.json")["subject"]} ==
          {a["name"]:sha(dist / a["name"]) for a in exported["artifacts"]})
    check("raw shared payloads keep their names and exact bytes",
          all((dist / n).read_bytes() == (incoming / n).read_bytes() for n in ("NOTICE", "runtime.json")))
    with tarfile.open(dist / "documentation.tar.gz") as archive:
        check("shared archive contains only its selected member and bytes",
              archive.getnames() == ["README.txt"] and
              archive.extractfile("README.txt").read() == (incoming / "documentation.txt").read_bytes())
    check("shared archive aliases are explicit byte-identical outputs",
          sha(dist / "documentation.tar.gz") == sha(dist / "documentation-compat.tar.gz") and
          {a["name"] for a in exported["artifacts"] if a["target"] == "additional"} ==
              {"NOTICE", "runtime.json", "documentation.tar.gz", "documentation-compat.tar.gz"})
    check("shared packaging leaves producer bytes and modes intact",
          original_bytes == {p.name:(sha(p), stat.S_IMODE(p.stat().st_mode)) for p in incoming.iterdir()})
    proof = base / "packaged.intoto.jsonl"
    invoke(["bash", root / "src/slsa.sh", "generate-manifest", exported_file, dist,
            "--repository", "example/app", "--builder", "dsr/test", "--output", proof])
    invoke(["bash", root / "src/slsa.sh", "verify-release", proof, dist, "--manifest", exported_file,
            "--repository", "example/app", "--builder", "dsr/test"])
    retained = {str(p.relative_to(output)):(sha(p), p.stat().st_ino)
                for p in output.rglob("*") if p.is_file() and
                ("/release/" in str(p) or p.name == "build-set.json")}
    incoming.rename(base / "offline-inputs")
    (base / "shards").rename(base / "offline-shards")
    again = json.loads(invoke(command, env=env).stdout)
    check("offline retry reuses admitted shared payloads and packaged outputs without rewriting",
          again["status"] == "ready" and retained ==
          {str(p.relative_to(output)):(sha(p), p.stat().st_ino)
           for p in output.rglob("*") if p.is_file() and
           ("/release/" in str(p) or p.name == "build-set.json")})
    check("offline retry does not create another producer attempt",
          all(len(j["attempts"]) == 1 for j in read(output / "state.json")["jobs"].values()))
    check("only the two verified shared-package invocations reach finalization",
          (cli / "calls").read_text().splitlines() == ["called", "called"])

    for title in ("shared-triple", "null-triple", "shared-job-target", "shared-required-target",
                  "missing-physical-target", "duplicate-name"):
        bad = copy.deepcopy(selection)
        notice = next(a for a in bad["required_assets"] if a["name"] == "NOTICE")
        if title in ("shared-triple", "null-triple"):
            notice["target_triple"] = "x86_64-unknown-linux-gnu" if title == "shared-triple" else None
        elif title == "shared-job-target":
            bad["builds"][0]["targets"].append("additional")
        elif title == "shared-required-target":
            bad["required_targets"].append("additional")
        elif title == "missing-physical-target":
            bad["required_assets"] = [a for a in bad["required_assets"] if a["target"] != "windows/arm64"]
        else:
            bad["required_assets"].append(dict(notice, name="notice"))
        bad_file = write(base / (title + "-plan.json"), bad)
        target = base / (title + "-builds")
        failed = json.loads(invoke(["bash", root / "src/release_builds.sh", "--plan", bad_file,
                                   "--output-dir", target, "--dry-run"], 4).stdout)
        check("execution plan rejects " + title + " before creating work",
              failed["publishable"] is False and not target.exists())

    win = next(a for a in selection["required_assets"] if a["target"] == "windows/arm64")
    variant = dict(target=win["target"], target_triple=win["target_triple"])
    xwin = dict(id="win", driver="xwin", targets=[win["target"]], variants=[variant], binary="app",
                asset_name=win["name"], project=str(base / "xwin-project"),
                toolchain_manifest=str(base / "xwin-toolchain.json"), toolchain_sha256="2" * 64)
    only_xwin = dict(selection, required_targets=[win["target"]], required_variants=[variant], builds=[xwin],
                     required_assets=[win, next(a for a in selection["required_assets"] if a["name"] == "NOTICE")])
    only_xwin_file = write(base / "only-xwin.json", only_xwin)
    failure = invoke(["bash", root / "src/release_builds.sh", "--plan", only_xwin_file,
                      "--output-dir", base / "only-xwin", "--dry-run"], 4)
    check("all-xwin shared selection is refused before compilation with an actionable reason",
          b"shared required assets need a DSR or imported producer" in failure.stderr and
          json.loads(failure.stdout)["publishable"] is False and not (base / "only-xwin").exists())
    mixed = copy.deepcopy(selection)
    mixed["builds"] = [xwin if j["id"] == "win" else j for j in mixed["builds"]]
    mixed_file = write(base / "mixed-xwin-import.json", mixed)
    mixed_preview = json.loads(invoke(["bash", root / "src/release_builds.sh", "--plan", mixed_file,
                                      "--output-dir", base / "mixed-xwin-import", "--dry-run"]).stdout)
    check("mixed xwin/import plans may select shared payloads for admitted import ownership",
          mixed_preview["status"] == "planned" and len(mixed_preview["plan"]["builds"]) == 3 and
          not (base / "mixed-xwin-import").exists())

    recipe_only_plan = copy.deepcopy(only_xwin)
    recipe_only_plan.pop("required_assets")
    recipe_only_file = write(base / "recipe-only-xwin.json", recipe_only_plan)
    recipe_only = read(recipe)
    recipe_only["artifacts"] = [a for a in recipe_only["artifacts"]
                                if a["target"] == "windows/arm64" or a["name"] == "NOTICE"]
    recipe_only_recipe = write(base / "recipe-only-xwin-packaging.json", recipe_only)
    for dry_run in (True, False):
        target = base / ("recipe-only-xwin-dry" if dry_run else "recipe-only-xwin-execute")
        refused = invoke(["bash", cli / "release_finalize.sh", "--build-plan", recipe_only_file,
                          "--build-dir", target, "--packaging-recipe", recipe_only_recipe] +
                         (["--dry-run"] if dry_run else []), 4, env=env)
        refusal = json.loads(refused.stdout)
        check("all-xwin recipe-only shared selection fails before creating " + ("dry-run" if dry_run else "execution") + " state",
              refusal["status"] == "error" and refusal["exit_code"] == 4 and
              "shared packaging inputs need a DSR or imported producer" in refusal["error"] and
              not target.exists() and (cli / "calls").read_text().splitlines() == ["called", "called"])
    recipe_only["artifacts"] = [a for a in recipe_only["artifacts"] if a["target"] == "windows/arm64"]
    ordinary_xwin_recipe = write(base / "ordinary-xwin-packaging.json", recipe_only)
    ordinary_xwin = json.loads(invoke(["bash", cli / "release_finalize.sh", "--build-plan", recipe_only_file,
                                      "--build-dir", base / "ordinary-xwin-dry", "--packaging-recipe", ordinary_xwin_recipe,
                                      "--dry-run"], env=env).stdout)
    check("ordinary xwin executable packaging remains valid without an optional exact asset contract",
          ordinary_xwin["status"] == "planned" and not (base / "ordinary-xwin-dry").exists())
    # Completed build sets deliberately omit driver fields; their pinned
    # manifests remain the authoritative shared-payload ownership evidence.
    preflight(output / "build-set.json", preview_file)

    base2, source2, manifest2, recipe2, plan2 = shared_fixture("shared-recipe-controls")
    for title in ("shared-triple", "null-triple", "dropped-shared", "retargeted-shared", "mixed-shared-members",
                  "dropped-physical"):
        bad = read(recipe2)
        notice = next(a for a in bad["artifacts"] if a["name"] == "NOTICE")
        if title in ("shared-triple", "null-triple"):
            notice["target_triple"] = "x86_64-unknown-linux-gnu" if title == "shared-triple" else None
        elif title == "dropped-shared":
            bad["artifacts"] = [a for a in bad["artifacts"] if a["name"] != "runtime.json"]
        elif title == "retargeted-shared":
            notice.update(target="linux/amd64", target_triple="x86_64-unknown-linux-gnu")
        elif title == "mixed-shared-members":
            next(a for a in bad["artifacts"] if a["name"] == "documentation.tar.gz")["members"].append(
                dict(source="raw-gnu", path="app"))
        else:
            bad["artifacts"] = [a for a in bad["artifacts"] if a["target"] != "windows/arm64"]
        bad_file = write(base2 / (title + ".json"), bad)
        failed = json.loads(invoke(package_command(bad_file, manifest2, source2, base2 / title), 4).stdout)
        check("packaging rejects " + title + " before publishing output",
              failed["publishable"] is False and not (base2 / title / "release").exists())
        if title not in ("shared-triple", "null-triple"):
            bad_preview = base2 / (title + "-preview.json")
            bad_preview.write_bytes(invoke(["bash", packager, "--recipe", bad_file, "--describe"]).stdout)
            preflight(plan2, bad_preview, 4)

    for title, expected in (("missing-shared", 1), ("changed-shared", 1), ("unselected-shared", 1),
                            ("duplicate-owner", 7), ("unproduced-shared", 4)):
        case, _, _, _, case_plan = shared_fixture(title)
        policy = read(case_plan)
        owner = next(j for j in policy["builds"] if j["id"] == "gnu")
        shared = Path(owner["artifacts_dir"]) / "NOTICE"
        if title == "missing-shared":
            shared.rename(case / "offline-NOTICE")
        elif title == "changed-shared":
            shared.write_bytes(shared.read_bytes() + b"unexpected drift\n")
        elif title == "unselected-shared":
            document = read(Path(owner["manifest"]))
            extra = Path(owner["artifacts_dir"]) / "UNSELECTED"
            extra.write_bytes(b"unselected owned fixture\n")
            document["artifacts"].append(dict(name=extra.name, target="additional", archive_format="none",
                sha256=sha(extra), size_bytes=extra.stat().st_size))
            document["required_assets"].append(dict(name=extra.name, target="additional", archive_format="none"))
            write(Path(owner["manifest"]), document)
            owner["manifest_sha256"] = sha(Path(owner["manifest"]))
        elif title == "duplicate-owner":
            other = next(j for j in policy["builds"] if j["id"] == "musl")
            document = read(Path(other["manifest"]))
            asset = next(a for a in read(Path(owner["manifest"]))["artifacts"] if a["name"] == "NOTICE")
            document["artifacts"].append(asset)
            document["required_assets"].append(dict(name="NOTICE", target="additional", archive_format="none"))
            shutil.copy2(shared, Path(other["artifacts_dir"]) / "NOTICE")
            write(Path(other["manifest"]), document)
            other["manifest_sha256"] = sha(Path(other["manifest"]))
        else:
            policy["required_assets"].append(dict(name="absent.json", target="additional", archive_format="none"))
        write(case_plan, policy)
        failed = json.loads(invoke(["bash", root / "src/release_builds.sh", "--plan", case_plan,
                                   "--output-dir", case / "executed"], expected).stdout)
        check("collection withholds publishable output for " + title,
              failed["publishable"] is False and not (case / "executed/bundle/release").exists())

    changed = (dist / "runtime.json").read_bytes() + b"unexpected completed-output drift\n"
    (dist / "runtime.json").write_bytes(changed)
    invoke(command, 7, env=env)
    check("completed shared-output drift blocks finalization without repairing retained bytes",
          (cli / "calls").read_text().splitlines() == ["called", "called"] and
          (dist / "runtime.json").read_bytes() == changed)

shared_payload_cases()
if os.environ.get("DSR_PACKAGING_SHARED_ONLY") == "1":
    print("Results: %d passed, 0 failed\nEvidence: %s" % (passed, work), flush=True)
    sys.exit(0)

for arch in ("amd64", "arm64"):
    base, incoming, manifest, recipe, plan = fixture(arch)
    selected, producer = read(recipe), read(manifest)
    pin = sha(manifest)
    original = {p.name: (sha(p), stat.S_IMODE(p.stat().st_mode)) for p in incoming.iterdir()}
    preview = invoke(["bash", packager, "--recipe", recipe, "--describe"])
    preview_file = base / "preview.json"
    preview_file.write_bytes(preview.stdout)
    descriptor = read(preview_file)
    check(arch + " preview retains compiler identities on all inputs and outputs",
          len(descriptor["inputs"]) == 3 and len(descriptor["required_assets"]) == 5 and
          all("target_triple" in a for a in descriptor["inputs"] + descriptor["required_assets"]))
    preflight(plan, preview_file)
    output = base / "packaged"
    result = json.loads(invoke(package_command(recipe, manifest, incoming, output)).stdout)
    dist, exported = Path(result["artifacts_dir"]), read(Path(result["manifest"]))
    check(arch + " successful envelope is exact and explicitly publishable",
          result["status"] == "verified" and result["exit_code"] == 0 and result["publishable"] is True)
    check(arch + " packaging preserves the exact compiler matrix and receipts",
          exported["required_variants"] == producer["required_variants"] and
          exported["build_environments"] == producer["build_environments"] and exported["summary"] == producer["summary"])
    check(arch + " every archive and alias keeps its recipe-selected variant",
          exported["required_assets"] == descriptor["required_assets"] and
          all(a["target_triple"] == next(r["target_triple"] for r in descriptor["required_assets"] if r["name"] == a["name"])
              for a in exported["artifacts"]))
    check(arch + " original source manifest is retained byte for byte", sha(output / "release/source/build-manifest.json") == pin)
    for row in selected["artifacts"]:
        member = row["members"][0]
        source = incoming / member["source"]
        if row["archive_format"] == "zip":
            with zipfile.ZipFile(dist / row["name"]) as archive:
                names = archive.namelist()
                payload = archive.read(member["path"])
                bits = (archive.getinfo(member["path"]).external_attr >> 16) & 0o111
        else:
            with tarfile.open(dist / row["name"]) as archive:
                names = archive.getnames()
                payload = archive.extractfile(member["path"]).read()
                bits = archive.getmember(member["path"]).mode & 0o111
        check(arch + " exact bytes/member/mode survive " + row["archive_format"],
              names == [member["path"]] and payload == source.read_bytes() and bits == (source.stat().st_mode & 0o111))
    check(arch + " alias is byte-identical but is not another compiler task",
          sha(dist / "alias-0.tar.gz") == sha(dist / "package-0.tar.gz") and exported["summary"]["total"] == 3)
    check(arch + " producer payloads and permissions were not mutated",
          original == {p.name: (sha(p), stat.S_IMODE(p.stat().st_mode)) for p in incoming.iterdir()})
    proof = base / "packaged.intoto.jsonl"
    invoke(["bash", root / "src/slsa.sh", "generate-manifest", result["manifest"], dist,
            "--repository", "example/app", "--builder", "dsr/test", "--output", proof])
    invoke(["bash", root / "src/slsa.sh", "verify-release", proof, dist, "--manifest", result["manifest"],
            "--repository", "example/app", "--builder", "dsr/test"])
    retained = {p.name: (sha(p), p.stat().st_ino) for p in dist.iterdir()}
    first_result = (output / "release/result.json").read_bytes()
    incoming.rename(base / "offline-inputs")
    manifest.rename(base / "offline-manifest.json")
    invoke(package_command(recipe, manifest, incoming, output, pin))
    check(arch + " offline retry preserves archive bytes, inodes and completion receipt",
          retained == {p.name: (sha(p), p.stat().st_ino) for p in dist.iterdir()} and
          first_result == (output / "release/result.json").read_bytes())
    (base / "offline-inputs").rename(incoming)
    (base / "offline-manifest.json").rename(manifest)
    repack = dict(schema_version=1, artifacts=[])
    for i, asset in enumerate(exported["artifacts"]):
        fmt = "tar.xz" if asset["archive_format"] == "tar.gz" else "tar.gz" if asset["archive_format"] == "tar.xz" else "zip"
        repack["artifacts"].append(dict(source=asset["name"], name="converted-%d.%s" % (i, fmt),
            target=asset["target"], target_triple=asset["target_triple"], archive_format=fmt))
    repack_file = write(base / "repack.json", repack)
    converted = json.loads(invoke(package_command(repack_file, Path(result["manifest"]), dist, base / "converted")).stdout)
    check(arch + " archive-to-archive packaging retains variant evidence through a second derivative",
          read(Path(converted["manifest"]))["required_variants"] == producer["required_variants"])
    check(arch + " same-format ZIP conversion remains byte-identical",
          sha(Path(converted["artifacts_dir"]) / "converted-3.zip") == sha(dist / "package-2.zip"))
    for title in ("missing-type", "wrong-compiler", "mixed-members", "null-type", "unsafe-type", "duplicate-source-policy"):
        bad = copy.deepcopy(selected)
        if title == "missing-type":
            bad["artifacts"][0].pop("target_triple")
        elif title == "wrong-compiler":
            bad["artifacts"][0]["target_triple"] = "x86_64-unknown-linux-other"
        elif title == "mixed-members":
            bad["artifacts"] = [bad["artifacts"][0], bad["artifacts"][3]]
            bad["artifacts"][0]["members"].append(dict(source="raw-musl", path="helper"))
        elif title == "null-type":
            bad["artifacts"][0]["target_triple"] = None
        elif title == "unsafe-type":
            bad["artifacts"][0]["target_triple"] = "../compiler"
        else:
            bad["artifacts"].append(dict(name="contradiction", source="raw-gnu", target="linux/" + arch,
                target_triple="x86_64-unknown-linux-other", archive_format="binary"))
        bad_file = write(base / (title + ".json"), bad)
        failure = json.loads(invoke(package_command(bad_file, manifest, incoming, base / title), 4).stdout)
        check(arch + " refuses " + title + " before output publication",
              failure["publishable"] is False and not (base / title / "release").exists())
        if title in ("missing-type", "wrong-compiler", "mixed-members"):
            bad_preview = invoke(["bash", packager, "--recipe", bad_file, "--describe"])
            path = base / (title + "-preview.json")
            path.write_bytes(bad_preview.stdout)
            preflight(plan, path, 4)

# Legacy untyped, single-variant packaging remains an explicit older contract;
# the new gate does not invent a compiler identity for those output names.
base = work / "amd64"
legacy = read(base / "manifest.json")
legacy["artifacts"] = legacy["artifacts"][:1]
legacy["build_environments"] = legacy["build_environments"][:1]
legacy["requested_targets"] = ["linux/amd64"]
legacy["summary"] = dict(total=1, success=1, failed=0)
legacy.pop("required_variants")
legacy_file = write(base / "legacy.json", legacy)
legacy_recipe = write(base / "legacy-recipe.json", dict(schema_version=1, artifacts=[
    dict(name="legacy", source="raw-gnu", target="linux/amd64", archive_format="binary")]))
old = json.loads(invoke(package_command(legacy_recipe, legacy_file, base / "incoming", base / "legacy-output")).stdout)
check("untyped singleton output retains the established field shape",
      "target_triple" not in read(Path(old["manifest"]))["artifacts"][0])

# Xwin has an exact compiler inventory even without required_assets. Retain
# that independent preflight when recipe inputs gain optional triple fields.
xwin_plan = write(base / "xwin-plan.json", dict(required_targets=["windows/arm64"], builds=[
    dict(driver="xwin", targets=["windows/arm64"], binary="app", asset_name="raw-win.exe")]))
xwin_recipe = write(base / "xwin-recipe.json", dict(schema_version=1, artifacts=[read(recipe)["artifacts"][3]]))
xwin_preview = base / "xwin-preview.json"
xwin_preview.write_bytes(invoke(["bash", packager, "--recipe", xwin_recipe, "--describe"]).stdout)
preflight(xwin_plan, xwin_preview)
wrong_xwin = read(xwin_recipe)
wrong_xwin["artifacts"][0]["target_triple"] = "x86_64-pc-windows-msvc"
wrong_xwin_file = write(base / "wrong-xwin.json", wrong_xwin)
xwin_preview.write_bytes(invoke(["bash", packager, "--recipe", wrong_xwin_file, "--describe"]).stdout)
preflight(xwin_plan, xwin_preview, 4)

# Exact source-name typing rejects a swap even though the full ABI set is
# unchanged. This must stop the finalizer before any collection/build work.
swap = read(base / "recipe.json")
for row in swap["artifacts"]:
    if row["target_triple"].endswith("-gnu"):
        row["target_triple"] = "x86_64-unknown-linux-musl"
    elif row["target_triple"].endswith("-musl"):
        row["target_triple"] = "x86_64-unknown-linux-gnu"
swap_file = write(base / "swap-recipe.json", swap)
swap_preview = base / "swap-preview.json"
swap_preview.write_bytes(invoke(["bash", packager, "--recipe", swap_file, "--describe"]).stdout)
preflight(base / "plan.json", swap_preview, 4)

# Actual public finalizer, bundle and packaging modules; only the external
# publication engine is a fixture. No compiler, signer or network is invoked.
cli = work / "cli"
cli.mkdir()
for source, filename in ((finalizer, "release_finalize.sh"), (packager, "release_packaging.sh")):
    shutil.copy2(source, cli / filename)
for filename in ("release_bundle.sh", "slsa.sh", "platforms.sh", "packaging.sh", "release_packaging_pipeline.sh"):
    shutil.copy2(root / "src" / filename, cli / filename)
(cli / "release_finalize_core.sh").write_text('''#!/usr/bin/env bash
_rf_log() { printf '%s\\n' "$*" >&2; }
release_finalize() {
    local root=$1 manifest='' repo=''
    shift
    while (($#)); do
        case "$1" in --build-manifest) manifest=$2; shift 2 ;; --repo) repo=$2; shift 2 ;; *) shift ;; esac
    done
    _slsa_manifest_statement "$manifest" "$repo" dsr/fixture > "${DSR_PACKAGE_FIXTURE:?}/proof.json" || return 99
    _slsa_release_assets "$DSR_PACKAGE_FIXTURE/proof.json" "$root" || return 99
    jq -e '.packaging_evidence.kind=="manifest-bound-packaging" and .summary.total==3 and
        (.required_assets|length)==5 and all(.artifacts[]; has("target_triple"))' "$manifest" >/dev/null || return 99
    printf 'called\\n' >> "$DSR_PACKAGE_FIXTURE/calls"
    printf '{"kind":"dsr-release-finalization-result","status":"ready","exit_code":0,"fixture":true,"authenticated":false}\\n'
}
''')
env = dict(os.environ, DSR_PACKAGE_FIXTURE=str(cli))
command = ["bash", cli / "release_finalize.sh", "--build-set", base / "plan.json",
           "--bundle-dir", base / "finalizer-bundle", "--packaging-recipe", base / "recipe.json"]
handoff = json.loads(invoke(command, env=env).stdout)
check("public finalizer receives complete packaged ABI outputs, not raw bundle paths",
      handoff["status"] == "ready" and handoff["fixture"] is True and handoff["authenticated"] is False and
      handoff["packaging"]["status"] == "verified")
before = sha(Path(handoff["packaging"]["manifest"]))
again = json.loads(invoke(command, env=env).stdout)
check("public finalizer reuses the same verified packaged manifest on retry",
      before == sha(Path(again["packaging"]["manifest"])) and (cli / "calls").read_text().count("called") == 2)
print("Results: %d passed, 0 failed\nEvidence: %s" % (passed, work), flush=True)
PY
