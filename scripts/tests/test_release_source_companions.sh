#!/usr/bin/env bash
# Actual Git objects, producer admission, archive parity and immutable retries.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 git jq tar zip unzip xz; do
    command -v "$tool" >/dev/null || { printf 'SKIP requires %s\n' "$tool"; exit 3; }
done
python3 - "$ROOT" <<'PY'
import copy
import hashlib
import io
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

root = Path(sys.argv[1])
script = Path(os.environ.get("DSR_PACKAGING_TEST_SCRIPT", str(root / "src/release_packaging.sh")))
work = Path(tempfile.mkdtemp(prefix="dsr-source-companions-"))
passed = 0

def check(label, condition):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print("PASS " + label, flush=True)

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def write(p, value):
    p.write_text(json.dumps(value))

def git(*args, data=None):
    return subprocess.run(["git", "-C", str(checkout), *args], input=data, capture_output=True, check=True).stdout

def archive(p, members):
    if p.suffix == ".zip":
        with zipfile.ZipFile(p, "w", compression=zipfile.ZIP_DEFLATED) as z:
            for n, data, mode in members:
                info = zipfile.ZipInfo(n, (2020, 1, 2, 3, 4, 6))
                info.create_system = 3
                info.external_attr = ((stat.S_IFDIR if n.endswith("/") else stat.S_IFREG) | mode) << 16
                z.writestr(info, data)
    else:
        with tarfile.open(p, "w:xz" if str(p).endswith(".xz") else "w:gz") as t:
            for n, data, mode in members:
                info = tarfile.TarInfo(n)
                info.size, info.mode, info.mtime = len(data), mode, 1600000000
                if n.endswith("/"):
                    info.type = tarfile.DIRTYPE
                t.addfile(info, io.BytesIO(data))

def payload(p):
    if p.suffix == ".zip":
        with zipfile.ZipFile(p) as z:
            return {m.filename: (z.read(m), (m.external_attr >> 16) & 0o111) for m in z.infolist()}
    with tarfile.open(p) as t:
        return {m.name: (t.extractfile(m).read(), m.mode & 0o111) for m in t.getmembers() if m.isfile()}

def manifest_for(directory, filename):
    formats = {".zip": "zip", ".gz": "tar.gz", ".xz": "tar.xz"}
    assets = [dict(name=p.name, target="linux/amd64", archive_format=formats.get(p.suffix, "binary"),
                   sha256=sha(p), size_bytes=p.stat().st_size, signed=True, signature_file=p.name + ".minisig")
              for p in sorted(directory.iterdir())]
    value = dict(schema_version="1.0.0", tool="demo", version="v1.2.3", run_id="companion-producer-run",
                 status="success", built_at="2026-09-24T10:00:00Z", build_purpose="release", publishable=True,
                 source=dict(repository="owner/demo", git_sha=commit, git_ref="refs/tags/v1.2.3", dependencies=[]),
                 summary=dict(total=1, success=1, failed=0), requested_targets=["linux/amd64"], artifacts=assets,
                 required_assets=[{k: a[k] for k in ("name", "target", "archive_format")} for a in assets],
                 build_environments=[dict(target="linux/amd64", compiler_receipt="preserve-verbatim")],
                 checksums_file="old-checksums", signature_file="old-signature", sbom_file="old-sbom")
    write(filename, value)
    return value

def run(output, expected=0, selected=None, source_repo=True, producer=None, env=None):
    recipe_path = work / "selected.json"
    write(recipe_path, selected or recipe)
    source_manifest, source_artifacts = producer or (manifest, incoming)
    pin = pins[source_manifest] if source_manifest in pins else sha(source_manifest)
    command = ["bash", str(script), "--recipe", str(recipe_path), "--manifest", str(source_manifest),
               "--manifest-sha256", pin, "--artifacts-dir", str(source_artifacts), "--output-dir", str(output),
               "--repo", "owner/demo", "--tag", "v1.2.3", "--sha", commit]
    if source_repo:
        command += ["--source-repo", str(checkout)]
    p = subprocess.run(command, capture_output=True, timeout=90, env=env)
    result = json.loads(p.stdout)
    if p.returncode != expected or result["exit_code"] != expected:
        raise AssertionError(f"expected {expected}, got {p.returncode}: {p.stdout.decode()}\n{p.stderr.decode()}")
    if expected:
        check(output.name + " refuses publication", not result["publishable"] and result["status"] == "error")
    return result

try:
    checkout = work / "checkout"
    checkout.mkdir()
    git("init", "-q")
    git("config", "user.name", "DSR Test")
    git("config", "user.email", "dsr-test@example.invalid")
    git("config", "core.autocrlf", "false")
    git("remote", "add", "origin", "https://github.com/owner/demo.git")
    (checkout / "docs").mkdir()
    committed = {"LICENSE": b"Complete license\nAdditional rider must survive.\n",
                 "docs/README.md": b"Tagged README\n$Format:%H$\n",
                 "install.sh": b"#!/bin/sh\nexit 0\n", "EMPTY": b""}
    for n, data in committed.items():
        (checkout / n).write_bytes(data)
    (checkout / "install.sh").chmod(0o755)
    (checkout / "linked-license").symlink_to("LICENSE")
    (checkout / "linked-docs").symlink_to("docs", target_is_directory=True)
    (checkout / ".gitattributes").write_text("LICENSE export-ignore\ndocs/README.md export-subst\n")
    git("add", ".")
    git("commit", "-qm", "pinned release source")
    git("tag", "-a", "v1.2.3", "-m", "tagged release")
    commit = git("rev-parse", "HEAD").decode().strip()
    (checkout / "LICENSE").write_text("WRONG uncommitted license\n")
    (checkout / "install.sh").chmod(0o644)
    (checkout / "untracked").write_text("not committed")
    before_status = git("status", "--porcelain=v1")
    app = b"#!/bin/sh\nexit 17\n"
    incoming = work / "producer"
    incoming.mkdir()
    for fmt in ("tar.gz", "tar.xz", "zip"):
        archive(incoming / ("producer." + fmt), [("demo", app, 0o755)])
    (incoming / "raw-app").write_bytes(app)
    (incoming / "raw-app").chmod(0o755)
    manifest = work / "producer.json"
    original = manifest_for(incoming, manifest)
    pins = {manifest: sha(manifest)}
    includes = [dict(source=s, path=Path(s).name) for s in committed]
    recipe = dict(schema_version=1, artifacts=[dict(name="final." + fmt, target="linux/amd64", archive_format=fmt,
        source="producer." + fmt, source_files=includes, aliases=["compat." + fmt]) for fmt in ("tar.gz", "tar.xz", "zip")])
    recipe["artifacts"].append(dict(name="from-raw.zip", target="linux/amd64", archive_format="zip",
                                    members=[dict(source="raw-app", path="demo")], source_files=includes))
    write(work / "preview.json", recipe)
    p = subprocess.run(["bash", str(script), "--recipe", str(work / "preview.json"), "--describe"], capture_output=True, check=True)
    preview = json.loads(p.stdout)
    check("preview separates source companions from producer coverage", preview["source_files"] == sorted(committed) and len(preview["inputs"]) == 4)
    out = work / "packaged"
    result = run(out, env=dict(os.environ, GIT_DIR="/does/not/exist", GIT_WORK_TREE="/wrong", GIT_CONFIG_COUNT="1",
                               GIT_CONFIG_KEY_0="remote.origin.url", GIT_CONFIG_VALUE_0="https://wrong.invalid/repo"))
    dist = Path(result["artifacts_dir"])
    expected = {Path(s).name: (b, 0o111 if s == "install.sh" else 0) for s, b in committed.items()}
    expected["demo"] = (app, 0o111)
    for n in ("final.tar.gz", "final.tar.xz", "final.zip", "from-raw.zip"):
        check(n + " preserves exact Git companions and binary bytes/modes", payload(dist / n) == expected)
    check("aliases retain final archive bytes", all(sha(dist / ("final." + f)) == sha(dist / ("compat." + f)) for f in ("tar.gz", "tar.xz", "zip")))
    exported = json.loads(Path(result["manifest"]).read_text())
    proof = exported["packaging_evidence"]["source_companions"]
    check("packaging evidence does not invent compiler evidence", proof["git_sha"] == commit and
          proof["kind"] == "git-commit-source-files" and exported["build_environments"] == original["build_environments"] and
          exported["run_id"] == original["run_id"] and exported["built_at"] == original["built_at"])
    check("outputs never inherit stale signatures or SBOMs", all(not a["signed"] for a in exported["artifacts"]) and
          all(k not in exported for k in ("signature_file", "checksums_file", "sbom_file")))
    check("producer and dirty checkout stay untouched", sha(manifest) == pins[manifest] and
          all(sha(incoming / a["name"]) == a["sha256"] for a in original["artifacts"]) and git("status", "--porcelain=v1") == before_status)
    check("Git proof binds nested paths and executable modes", {f["source"] for f in proof["files"]} == set(committed) and
          any(f["git_mode"] == "100755" and f["source"] == "install.sh" for f in proof["files"]) and
          sum(o["name"].startswith("tree-") for o in proof["objects"]) == 2)
    legacy = copy.deepcopy(recipe)
    for artifact in legacy["artifacts"]:
        del artifact["source_files"]
    legacy_result = run(work / "no-companions", selected=legacy, source_repo=False)
    legacy_manifest = json.loads(Path(legacy_result["manifest"]).read_text())
    check("recipes without companions retain their existing evidence shape", "source_companions" not in legacy_manifest["packaging_evidence"])
    check("prebuilt preservation remains unchanged without companions", all(
        sha(Path(legacy_result["artifacts_dir"]) / ("final." + f)) == sha(incoming / ("producer." + f))
        for f in ("tar.gz", "tar.xz", "zip")))
    retry = work / "missing-source-repo"
    run(retry, 4, source_repo=False)
    check("failed preparation exposes no partial release", not (retry / "release").exists())
    run(retry)
    check("retry completes the same admitted selection", (retry / "release/result.json").is_file())
    for source in ("absent", "untracked", "linked-license", "linked-docs/README.md", "docs"):
        bad = copy.deepcopy(recipe)
        bad["artifacts"][0]["source_files"] = [dict(source=source, path="LICENSE")]
        run(work / ("reject-" + source.replace("/", "-")), 4, selected=bad)
    for label, change in (
        ("source-traversal", lambda a: a.update(source_files=[dict(source="../LICENSE", path="LICENSE")])),
        ("destination-traversal", lambda a: a.update(source_files=[dict(source="LICENSE", path="../LICENSE")])),
        ("null-source-list", lambda a: a.update(source_files=None)),
        ("empty-source-list", lambda a: a.update(source_files=[])),
        ("case-collision", lambda a: a.update(source_files=[dict(source="LICENSE", path="LICENSE"), dict(source="EMPTY", path="license")])),
        ("producer-collision", lambda a: a.update(source_files=[dict(source="LICENSE", path="DEMO")])),
    ):
        bad = copy.deepcopy(recipe)
        change(bad["artifacts"][-1])
        run(work / label, 4, selected=bad)
    git("remote", "set-url", "origin", "https://github.com/other/demo")
    run(work / "wrong-origin", 4)
    git("remote", "set-url", "origin", "https://github.com/owner/demo.git")
    git("add", "LICENSE")
    git("commit", "-qm", "later source")
    later = git("rev-parse", "HEAD").decode().strip()
    git("tag", "-f", "v1.2.3", later)
    run(work / "wrong-tag", 4)
    git("tag", "-f", "v1.2.3", commit)
    license_oid = next(f["git_blob_sha"] for f in proof["files"] if f["source"] == "LICENSE")
    replacement = git("hash-object", "-w", "--stdin", data=b"forged via git replace\n").decode().strip()
    git("replace", license_oid, replacement)
    rr = run(work / "git-replacement")
    check("Git replacements cannot change pinned companions", payload(Path(rr["artifacts_dir"]) / "final.zip") == expected)
    for fmt in ("tar.xz", "zip"):
        complete = work / ("complete-" + fmt)
        complete.mkdir()
        archive(complete / ("ready." + fmt), [(n, b, 0o644 | x) for n, (b, x) in expected.items()])
        m = work / ("complete-" + fmt + ".json")
        manifest_for(complete, m)
        selected = dict(schema_version=1, artifacts=[dict(name="ready." + fmt, target="linux/amd64", archive_format=fmt,
                                                        source="ready." + fmt, source_files=includes)])
        rr = run(work / ("complete-output-" + fmt), selected=selected, producer=(m, complete))
        check(fmt + " with matching includes is not recompressed", sha(Path(rr["artifacts_dir"]) / ("ready." + fmt)) == sha(complete / ("ready." + fmt)))
        for label, companion in (("conflict", ("LICENSE", b"wrong license", 0o644)),
                                 ("wrong-mode", ("LICENSE", committed["LICENSE"], 0o755)),
                                 ("wrong-case", ("license", committed["LICENSE"], 0o644)),
                                 ("directory", ("LICENSE/", b"", 0o755))):
            archive(complete / ("ready." + fmt), [("demo", app, 0o755), companion])
            manifest_for(complete, m)
            folder = work / (fmt + "-" + label)
            run(folder, 4, selected=selected, producer=(m, complete))
            check(folder.name + " exposes no weaker archive", not (folder / "release").exists())
    retained = out / "release/source/companions"
    for prefix in ("commit-", "tree-", "blob-"):
        file = next(p for p in retained.iterdir() if p.name.startswith(prefix))
        saved = file.read_bytes()
        file.write_bytes(saved + b"tampered")
        run(out, 7)
        check(prefix + " corruption is not repaired", file.read_bytes() != saved)
        file.write_bytes(saved)
    (retained / "unlisted").write_text("extra")
    run(out, 7)
    (retained / "unlisted").rename(work / "held-unlisted-proof")
    manifest_out = out / "release/build-manifest.json"
    saved = manifest_out.read_bytes()
    forged = json.loads(saved)
    forged["packaging_evidence"]["source_companions"]["files"][0]["git_mode"] = "100755"
    write(manifest_out, forged)
    run(out, 7)
    manifest_out.write_bytes(saved)
    snapshots = {str(p.relative_to(out)): (p.stat().st_ino, p.stat().st_mtime_ns, sha(p)) for p in out.rglob("*") if p.is_file()}
    incoming.rename(work / "offline-producer")
    manifest.rename(work / "offline-manifest")
    checkout.rename(work / "offline-source")
    run(out, source_repo=False)
    after = {str(p.relative_to(out)): (p.stat().st_ino, p.stat().st_mtime_ns, sha(p)) for p in out.rglob("*") if p.is_file()}
    check("offline resume revalidates evidence without rewriting any file", snapshots == after)
    print(f"Source companion integration: {passed} assertions passed", flush=True)
finally:
    shutil.rmtree(work)
PY
