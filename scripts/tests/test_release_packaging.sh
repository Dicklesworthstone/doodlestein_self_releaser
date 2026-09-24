#!/usr/bin/env bash
# Real producer manifests, archives, extraction, hashes and immutable retries.
# No release APIs or signing fixtures are needed. A C compiler is optional.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 jq tar zip unzip xz; do
    command -v "$tool" >/dev/null || { printf 'SKIP requires %s\n' "$tool"; exit 0; }
done
python3 - "$ROOT" <<'PY'
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

root = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix="dsr-packaging-test-"))
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
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value))

def read(p):
    return json.loads(p.read_text())

script = root / "src/release_packaging.sh"
source_sha = "a" * 40
try:
    incoming = work / "producer"
    incoming.mkdir()
    cc = shutil.which("cc")
    for n, status in (("app", 0), ("helper", 17)):
        if cc:
            c = work / (n + ".c")
            c.write_text("int main(void) { return %d; }\n" % status)
            subprocess.run([cc, "-O2", str(c), "-o", str(incoming / n)], check=True)
        else:
            (incoming / n).write_text("#!/bin/sh\nexit %d\n" % status)
        (incoming / n).chmod(0o755 if n == "app" else 0o751)
    check("native fixture executable runs before packaging", subprocess.run([str(incoming / "helper")]).returncode == 17)
    with zipfile.ZipFile(incoming / "producer.zip", "w", compression=zipfile.ZIP_DEFLATED) as z:
        info = zipfile.ZipInfo("demo.exe", (2021, 1, 2, 3, 4, 6))
        info.create_system = 3
        info.external_attr = (stat.S_IFREG | 0o755) << 16
        z.writestr(info, b"archived producer payload\n")
    manifest = work / "producer.json"
    assets = []
    for n, target, fmt in (("app", "linux/amd64", "binary"), ("helper", "linux/amd64", "binary"),
                           ("producer.zip", "windows/arm64", "zip")):
        assets.append(dict(name=n, target=target, archive_format=fmt, sha256=sha(incoming / n),
                           size_bytes=(incoming / n).stat().st_size, signed=True, signature_file=n + ".minisig"))
    producer = dict(schema_version="1.0.0", tool="demo", version="v1.2.3", run_id="12345678-1234-4123-8123-123456789abc",
        status="success", built_at="2026-09-24T10:00:00Z", build_purpose="release", publishable=True,
        source=dict(repository="owner/demo", git_sha=source_sha, git_ref="refs/tags/v1.2.3", dependencies=[]),
        summary=dict(total=2, success=2, failed=0), artifacts=assets,
        requested_targets=["linux/amd64", "windows/arm64"],
        required_assets=[{k: a[k] for k in ("name", "target", "archive_format")} for a in assets],
        build_environments=[dict(target="linux/amd64", retained_evidence="x" * 150000)],
        checksums_file="old.sha256", signature_file="old.minisig", sbom_file="old.spdx.json")
    write(manifest, producer)
    original_pin = sha(manifest)
    selected = dict(schema_version=1, artifacts=[
        dict(name="demo-linux.tar.gz", target="linux/amd64", archive_format="tar.gz",
             members=[dict(source="app", path="demo"), dict(source="helper", path="helper")], aliases=["demo-linux.tgz"]),
        dict(name="demo-linux.tar.xz", target="linux/amd64", archive_format="tar.xz",
             members=[dict(source="app", path="demo"), dict(source="helper", path="helper")]),
        dict(name="demo-linux.zip", target="linux/amd64", archive_format="zip",
             members=[dict(source="app", path="demo"), dict(source="helper", path="helper")]),
        dict(name="demo", target="linux/amd64", archive_format="binary", source="app", aliases=["demo-linux"]),
        dict(name="demo-windows.zip", target="windows/arm64", archive_format="zip", source="producer.zip", aliases=["demo-windows-arm64.zip"]),
        dict(name="demo-windows.tar.xz", target="windows/arm64", archive_format="tar.xz", source="producer.zip")])
    recipe_file = work / "recipe.json"
    write(recipe_file, selected)
    def run(folder, expected=0, recipe=recipe_file, pin=original_pin, src=manifest, files=incoming, extra=(), env=None):
        command = ["bash", str(script), "--recipe", str(recipe), "--manifest", str(src), "--manifest-sha256", pin,
                   "--artifacts-dir", str(files), "--output-dir", str(folder), "--repo", "owner/demo", "--tag", "v1.2.3", "--sha", source_sha]
        p = subprocess.run(command + list(extra), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, env=env)
        if p.returncode != expected:
            raise AssertionError(f"expected {expected}, got {p.returncode}: {p.stdout.decode()}\n{p.stderr.decode()}")
        result = json.loads(p.stdout)
        check("one packaging envelope agrees with process exit", result["exit_code"] == expected)
        if expected:
            check("failure is never publishable", result["status"] == "error" and not result["publishable"])
        return result
    preview = subprocess.run(["bash", str(script), "--recipe", str(recipe_file), "--describe"], capture_output=True, check=True)
    plan = json.loads(preview.stdout)
    check("recipe preview expands every alias", len(plan["required_assets"]) == 9)
    check("preview identifies every producer input", len(plan["inputs"]) == 3)
    out = work / "packaged"
    result = run(out, env=dict(os.environ, TAR_OPTIONS="--remove-files", ZIPOPT="-m", UNZIP="-j", GZIP="invalid"))
    dist = Path(result["artifacts_dir"])
    exported = read(Path(result["manifest"]))
    check("all formats and aliases reach the final manifest", len(exported["artifacts"]) == 9)
    check("new artifact requirements replace the admitted producer requirements", exported["required_assets"] == plan["required_assets"])
    check("source and compiler evidence survive packaging", exported["source"] == producer["source"] and exported["build_environments"] == producer["build_environments"])
    check("large evidence never enters subprocess argument JSON", Path(result["manifest"]).stat().st_size > 131072)
    check("producer run and build time are not fabricated", exported["run_id"] == producer["run_id"] and exported["built_at"] == producer["built_at"])
    check("original producer manifest bytes are retained", sha(out / "release/source/build-manifest.json") == original_pin)
    check("old checksum, signature and SBOM pointers are removed", all(k not in exported for k in ("checksums_file", "signature_file", "sbom_file")))
    check("packaged assets never inherit producer signature claims", all(a["signed"] is False and a["signature_file"] == "" for a in exported["artifacts"]))
    check("packaging evidence binds producer and recipe", exported["packaging_evidence"]["source_manifest_sha256"] == original_pin and exported["packaging_evidence"]["recipe_sha256"] == plan["recipe_sha256"])
    check("raw binary alias remains executable", subprocess.run([str(dist / "demo-linux")]).returncode == 0)
    check("prebuilt same-format archive is byte-for-byte authoritative", (dist / "demo-windows.zip").read_bytes() == (incoming / "producer.zip").read_bytes())
    check("archive aliases are byte-identical", (dist / "demo-linux.tgz").read_bytes() == (dist / "demo-linux.tar.gz").read_bytes())
    check("aliases do not hardlink mutable producer files", (dist / "demo").stat().st_ino != (incoming / "app").stat().st_ino)
    for filename in ("demo-linux.tar.gz", "demo-linux.tar.xz"):
        with tarfile.open(dist / filename) as t:
            check(filename + " has exactly flat binary members", sorted(t.getnames()) == ["demo", "helper"])
            check(filename + " preserves helper bytes and executable bits", t.extractfile("helper").read() == (incoming / "helper").read_bytes() and t.getmember("helper").mode & 0o111 == 0o111)
    with zipfile.ZipFile(dist / "demo-linux.zip") as z:
        check("ZIP carries both binary payloads, not an archive wrapper", sorted(z.namelist()) == ["demo", "helper"] and z.read("demo") == (incoming / "app").read_bytes())
    with tarfile.open(dist / "demo-windows.tar.xz") as t:
        check("cross-format conversion extracts rather than nests the ZIP", t.getnames() == ["demo.exe"] and t.extractfile("demo.exe").read() == b"archived producer payload\n")
    inode = (dist / "demo-linux.tar.gz").stat().st_ino
    first = (out / "release/result.json").read_bytes()
    incoming.rename(work / "offline-producer")
    manifest.rename(work / "offline-manifest.json")
    run(out)
    check("retry uses retained inputs after producer disappears", (out / "release/result.json").read_bytes() == first and (dist / "demo-linux.tar.gz").stat().st_ino == inode)
    (work / "offline-producer").rename(incoming)
    (work / "offline-manifest.json").rename(manifest)
    reverse = copy.deepcopy(selected)
    reverse["artifacts"].reverse()
    reverse["artifacts"][-1]["members"].reverse()
    write(work / "reverse.json", reverse)
    run(out, recipe=work / "reverse.json")
    check("recipe ordering does not replace completed outputs", (dist / "demo-linux.tar.gz").stat().st_ino == inode)
    changed = copy.deepcopy(selected)
    changed["artifacts"][0]["aliases"] = ["changed.tgz"]
    write(work / "changed.json", changed)
    run(out, 2, recipe=work / "changed.json")
    for title, mutate in (
        ("missing-companion", lambda p: p["artifacts"].__setitem__(0, dict(p["artifacts"][0], source="absent"))),
        ("case-collision", lambda p: p["artifacts"][0].update(aliases=["DEMO-LINUX.TAR.gz"])),
        ("traversal", lambda p: p["artifacts"][0]["members"][0].update(path="../escape")),
        ("member-collision", lambda p: p["artifacts"][0]["members"][1].update(path="DEMO")),
        ("extension-mismatch", lambda p: p["artifacts"][0].update(archive_format="zip")),
        ("explicit-null", lambda p: p["artifacts"][0].update(aliases=None)),
        ("shell-command", lambda p: p["artifacts"][0].update(command="echo unsafe")),
        ("empty-members", lambda p: p["artifacts"][0].update(members=[])),
    ):
        bad = copy.deepcopy(selected); mutate(bad); write(work / "bad.json", bad)
        folder = work / title
        run(folder, 4, recipe=work / "bad.json")
        check(title + " does not publish output", not (folder / "release").exists())
    # Valid recipes that violate the actual admitted producer's contract.
    for title, bad in (
        ("unused-producer", dict(schema_version=1, artifacts=[dict(name="only-app", target="linux/amd64", archive_format="binary", source="app")])),
        ("wrong-target", dict(schema_version=1, artifacts=[dict(name="all.zip", target="linux/amd64", archive_format="zip",
            members=[dict(source=n, path=n) for n in ("app", "helper", "producer.zip")])])),
    ):
        write(work / "bad.json", bad); folder = work / title
        run(folder, 4, recipe=work / "bad.json")
        check(title + " cannot lose or retarget producer artifacts", not (folder / "release").exists())
    run(work / "wrong-pin", 7, pin="0" * 64)
    for key, value in (("publishable", False), ("status", "partial")):
        bad = copy.deepcopy(producer); bad[key] = value; write(work / "bad-manifest.json", bad)
        run(work / ("bad-" + key), 4, src=work / "bad-manifest.json", pin=sha(work / "bad-manifest.json"))
    saved = (incoming / "helper").read_bytes()
    (incoming / "helper").write_bytes(b"corrupt")
    run(work / "corrupt-producer", 1)
    (incoming / "helper").write_bytes(saved)
    # Revalidated output is immutable: reject rather than repair drift.
    for relative in ("artifacts/demo-linux", "source/artifacts/app", "build-manifest.json", "result.json", "recipe.json"):
        file = out / "release" / relative
        original = file.read_bytes(); file.write_bytes(b"{}\n" if file.suffix == ".json" else b"drift\n")
        p = subprocess.run(["bash", str(script), "--recipe", str(recipe_file), "--manifest", str(manifest), "--manifest-sha256", original_pin,
                           "--artifacts-dir", str(incoming), "--output-dir", str(out), "--repo", "owner/demo", "--tag", "v1.2.3", "--sha", source_sha], capture_output=True)
        check("completed drift is rejected: " + relative, p.returncode != 0 and not json.loads(p.stdout)["publishable"])
        check("completed drift is never overwritten: " + relative, file.read_bytes() != original)
        file.write_bytes(original)
    (out / "release/artifacts/unlisted").write_text("unlisted")
    run(out, 7)
    (out / "release/artifacts/unlisted").rename(work / "held-unlisted")
    # Real correctly hash-pinned ZIPs still require safe member semantics.
    for title in ("zip-traversal", "zip-symlink", "zip-duplicate"):
        hostile = work / title; hostile.mkdir()
        for n in ("app", "helper"):
            shutil.copy2(incoming / n, hostile / n)
        with zipfile.ZipFile(hostile / "producer.zip", "w") as z:
            if title == "zip-traversal": z.writestr("../escape", b"escape")
            elif title == "zip-symlink":
                info = zipfile.ZipInfo("demo.exe"); info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(info, b"/etc/passwd")
            else:
                z.writestr("demo.exe", b"first"); z.writestr("demo.exe", b"second")
        bad = copy.deepcopy(producer)
        bad["artifacts"][2].update(sha256=sha(hostile / "producer.zip"), size_bytes=(hostile / "producer.zip").stat().st_size)
        write(work / "hostile.json", bad)
        folder = work / (title + "-output")
        run(folder, 4, src=work / "hostile.json", pin=sha(work / "hostile.json"), files=hostile)
        check(title + " has no published release", not (folder / "release").exists())
    # Fail a real compressor boundary after source admission; retry is safe.
    fakebin = work / "bin"; fakebin.mkdir()
    (fakebin / "tar").write_text("#!/bin/sh\nexit 42\n"); (fakebin / "tar").chmod(0o755)
    run(work / "compressor-fail", 4, env=dict(os.environ, PATH=str(fakebin) + ":" + os.environ["PATH"]))
    check("compressor failure exposes no release", not (work / "compressor-fail/release").exists())
    run(work / "compressor-fail")
    check("retry after compressor failure retains source and produces a complete release", (work / "compressor-fail/release/result.json").is_file())
    print(f"\nRelease packaging: {passed} passed, 0 failed", flush=True)
except Exception:
    print("Retained failing fixtures: " + str(work), file=sys.stderr)
    raise
else:
    shutil.rmtree(work)
PY
