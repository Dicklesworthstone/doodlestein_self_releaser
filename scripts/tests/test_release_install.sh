#!/usr/bin/env bash
# Real snapshot authentication, archive safety and generation activation.
# Minisign/GitHub are explicit fixtures inherited from the snapshot suite.
# Only this test, never the installer, executes the tiny installed test binary.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
for tool in python3 jq bash tar zip unzip xz flock sha256sum; do
    command -v "$tool" >/dev/null || { printf 'SKIP requires %s\n' "$tool"; exit 0; }
done
[[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] || { printf 'SKIP native Linux x86_64 fixture\n'; exit 0; }
DSR_SNAPSHOT_FIXTURES_ONLY=true source "$HERE/test_slsa_snapshot.sh"
source "$ROOT/src/packaging.sh"
new_case installer
mkdir "$CASE/payload"
if command -v cc >/dev/null; then
    cat > "$CASE/fixture.c" <<'C'
#include <stdio.h>
int main(void) { return puts("native-install-fixture") < 0; }
C
    cc "$CASE/fixture.c" -o "$CASE/payload/demo" || exit 1
    printf 'Fixture compiler: cc (native binary executed by test only)\n'
else
    printf '#!/bin/sh\nprintf "native-install-fixture\\n"\n' > "$CASE/payload/demo"
    chmod 755 "$CASE/payload/demo"
    printf 'Fixture compiler unavailable: shell executable fallback\n'
fi
cp "$CASE/payload/demo" "$CASE/payload/helper"
packaging_build_archive tar.gz "$CASE/assets/demo-linux.tar.gz" "$CASE/payload" demo helper || exit 1
cp "$CASE/assets/demo-linux.tar.gz" "$CASE/remote/1"
cp "$CASE/payload/demo" "$CASE/assets/demo-linux-alias"
cp "$CASE/payload/demo" "$CASE/remote/2"
jq --arg hash "$(_slsa_sha256 "$CASE/remote/1")" --argjson size "$(wc -c < "$CASE/remote/1")" \
   --arg raw "$(_slsa_sha256 "$CASE/remote/2")" --argjson rawsize "$(wc -c < "$CASE/remote/2")" \
   '.artifacts[0] |= (.name="demo-linux.tar.gz"|.archive_format="tar.gz"|.sha256=$hash|.size_bytes=$size) |
    .artifacts[1] |= (.sha256=$raw|.size_bytes=$rawsize)' "$CASE/build.json" > "$CASE/updated.json"
cp "$CASE/updated.json" "$CASE/build.json"
_slsa_manifest_statement "$CASE/build.json" owner/demo dsr:test > "$CASE/remote/4" || exit 1
sign_fixture "$CASE/remote/4" "$CASE/remote/5"
refresh_remote
jq 'map(if .id==1 then .name="demo-linux.tar.gz" else . end)' "$CASE/inventory.json" > "$CASE/updated.json"
cp "$CASE/updated.json" "$CASE/inventory.json"
fetch > "$CASE/fetched.json" || exit 1
# All installation calls below are real new CLI processes. Poisoning network
# commands makes accidental offline network access an explicit test failure.
export DSR_INSTALL_FIXTURE_CASE="$CASE"
python3 - "$ROOT" "$CASE" "$TOKEN" "$PIN" <<'PY'
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import time

root, case, token, pin = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
checks = 0
script = root / "src/release_install.sh"
snapshot = case / "snapshot"
prefix = case / "prefix"
recipe = case / "install.json"
public = case / "key.pub"
base = {"schema_version": 1, "target": "linux/amd64", "executables": [
    {"name": "demo", "artifact": "demo-linux.tar.gz", "member": "demo"},
    {"name": "helper", "artifact": "demo-linux.tar.gz", "member": "helper"},
    {"name": "raw-alias", "artifact": "demo-linux-alias"}]}


def check(label, condition):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print("PASS " + label, flush=True)


def save(path, value):
    path.write_text(json.dumps(value) + "\n")


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


save(recipe, base)
network_bin = case / "network-poison"
network_bin.mkdir()
for name in ("curl", "wget", "gh"):
    file = network_bin / name
    file.write_text('#!/bin/sh\nprintf "network called\\n" >> "$DSR_INSTALL_FIXTURE_CASE/network-called"\nexit 99\n')
    file.chmod(0o755)
environment = dict(os.environ, PATH=str(network_bin) + ":" + os.environ["PATH"])


def command(selected_snapshot=snapshot, selected_recipe=recipe, selected_prefix=prefix, extra=(), key=public,
            tag="v1.2.3", source_sha=pin):
    return ["bash", str(script), "--snapshot", str(selected_snapshot), "--recipe", str(selected_recipe),
            "--prefix", str(selected_prefix), "--repo", "owner/demo", "--tag", tag, "--sha", source_sha,
            "--builder", "dsr:test", "--targets", "windows/arm64,linux/amd64", "--public-key", str(key), *extra]


def run(expected=0, **kwargs):
    env = kwargs.pop("env", environment)
    p = subprocess.run(command(**kwargs), env=env, capture_output=True, timeout=40)
    (case / "install.stdout").write_bytes(p.stdout)
    (case / "install.stderr").write_bytes(p.stderr)
    if p.returncode != expected:
        raise AssertionError(f"wanted {expected}, got {p.returncode}: {p.stderr.decode()} {p.stdout.decode()}")
    result = json.loads(p.stdout)
    check("single installation result agrees with exit " + str(expected), result["exit_code"] == expected)
    if expected:
        check("failed install never claims successful activation", result["status"] == "error" and not result["activated"])
    else:
        check("installation authenticates offline without claiming current remote state",
              result["authenticated"] is True and result["remote_current"] is False)
    return result


def state():
    return {str(p.relative_to(prefix)): (p.lstat().st_ino, os.readlink(p) if p.is_symlink() else digest(p))
            for p in prefix.rglob("*") if p.is_symlink() or p.is_file()}


def repin_snapshot(directory):
    """Fixture signer updates exact bytes, never a production admission shortcut."""
    proof = directory / "release.intoto.jsonl"
    value = read(proof)
    for item in value["dsr_evidence"]["artifacts"]:
        payload = directory / "artifacts" / item["name"]
        if payload.exists() and not payload.is_symlink():
            item["size_bytes"] = payload.stat().st_size
            next(s for s in value["subject"] if s["name"] == item["name"])["digest"]["sha256"] = digest(payload)
    save(proof, value)
    (directory / "release.intoto.jsonl.minisig").write_text(token + ":" + digest(proof) + "\n")


def variant(label):
    dest = case / label
    shutil.copytree(snapshot, dest)
    return dest


result = run(extra=("--dry-run",))
check("planning authenticates/extracts but creates no installation state", result["status"] == "planned" and not prefix.exists() and not Path(str(prefix) + ".lock").exists())
check("planning declares the complete executable set", [e["name"] for e in result["executables"]] == ["demo", "helper", "raw-alias"])
first = run()
first_id = first["generation"]
first_dir = prefix / "generations" / first_id
check("one managed pointer activates the complete generation", os.readlink(prefix / "current") == "generations/" + first_id and first["activated"])
check("stable generation-specific path is returned", first["generation_bin_dir"] == str(first_dir / "bin"))
check("all binaries are installed as ordinary executable files", all(stat.S_IMODE((first_dir / "bin" / n).stat().st_mode) == 0o755 for n in ("demo", "helper", "raw-alias")))
for name in ("demo", "helper", "raw-alias"):
    p = subprocess.run([str(prefix / "current/bin" / name)], capture_output=True, timeout=5)
    check("test executes installed " + name, p.returncode == 0 and p.stdout == b"native-install-fixture\n")
check("no credential file is installed", {p.name for p in first_dir.iterdir()} == {"bin", "receipt.json", "release.intoto.jsonl", "release.intoto.jsonl.minisig"})
original = state()
same = run()
check("identical retry changes no generation or pointer inode", not same["activated"] and state() == original)
reordered = copy.deepcopy(base)
reordered["executables"].reverse()
save(recipe, reordered)
same = run()
check("equivalent recipe ordering retains one generation", same["generation"] == first_id and state() == original)
save(recipe, base)

# A different executable set is a different generation, even with the same
# signed snapshot. Upgrades require explicit permission and retain old files.
upgrade_recipe = case / "upgrade.json"
upgrade = copy.deepcopy(base)
upgrade["executables"] = [{"name": "demo-v2", "artifact": "demo-linux.tar.gz", "member": "demo"},
                          {"name": "helper-v2", "artifact": "demo-linux.tar.gz", "member": "helper"}]
save(upgrade_recipe, upgrade)
run(2, selected_recipe=upgrade_recipe)
check("unapproved upgrade leaves the complete installation untouched", state() == original)
second = run(selected_recipe=upgrade_recipe, extra=("--replace",))
check("upgrade switches every executable through one pointer", second["activated"] and second["previous_generation"] == first_id and
      {p.name for p in (prefix / "current/bin").iterdir()} == {"demo-v2", "helper-v2"})
check("upgrading preserves the previous executable generation", (first_dir / "bin/helper").exists() and digest(first_dir / "bin/helper") == digest(case / "payload/helper"))
rolled = run(extra=("--replace",))
check("explicit rollback reauthenticates and reuses old generation", rolled["generation"] == first_id and rolled["previous_generation"] == second["generation"])
check("rollback preserves original generation inode", (first_dir / "bin/demo").stat().st_ino == original[f"generations/{first_id}/bin/demo"][0])

# A real version/source transition keeps the same command names while every
# selected executable changes. Derive a fresh statement with the real mapper.
next_snapshot = variant("next-version")
next_payload = case / "payload-next"
next_payload.mkdir()
compiler = shutil.which("cc")
if compiler:
    (case / "fixture-next.c").write_text('#include <stdio.h>\nint main(void) { return puts("native-install-fixture-v2") < 0; }\n')
    subprocess.run([compiler, str(case / "fixture-next.c"), "-o", str(next_payload / "demo")], check=True, timeout=30)
else:
    (next_payload / "demo").write_text('#!/bin/sh\nprintf "native-install-fixture-v2\\n"\n')
    (next_payload / "demo").chmod(0o755)
shutil.copy2(next_payload / "demo", next_payload / "helper")
next_archive = case / "next.tar.gz"
subprocess.run(["bash", "-c", 'source "$1/src/packaging.sh"; packaging_build_archive tar.gz "$2" "$3" demo helper',
                "_", str(root), str(next_archive), str(next_payload)], check=True, capture_output=True, timeout=30)
(next_snapshot / "artifacts/demo-linux.tar.gz").write_bytes(next_archive.read_bytes())
(next_snapshot / "artifacts/demo-linux-alias").write_bytes((next_payload / "demo").read_bytes())
manifest = read(case / "build.json")
manifest.update(version="v1.2.4", run_id="22222222-2222-4222-8222-222222222222", built_at="2026-09-24T01:00:00Z")
manifest["source"].update(git_sha="b"*40, git_ref="refs/tags/v1.2.4")
for artifact in manifest["artifacts"]:
    payload = next_snapshot / "artifacts" / artifact["name"]
    artifact.update(sha256=digest(payload), size_bytes=payload.stat().st_size)
save(case / "build-next.json", manifest)
p = subprocess.run(["bash", "-c", 'source "$1/src/slsa.sh"; _slsa_manifest_statement "$2" owner/demo dsr:test',
                    "_", str(root), str(case / "build-next.json")], capture_output=True, check=True, timeout=15)
(next_snapshot / "release.intoto.jsonl").write_bytes(p.stdout)
(next_snapshot / "release.intoto.jsonl.minisig").write_text(token + ":" + digest(next_snapshot / "release.intoto.jsonl") + "\n")
before_version = state()
run(2, selected_snapshot=next_snapshot, tag="v1.2.4", source_sha="b"*40)
check("new release needs replacement consent", state() == before_version)
next_result = run(selected_snapshot=next_snapshot, tag="v1.2.4", source_sha="b"*40, extra=("--replace",))
check("new source and release select a distinct complete generation", next_result["generation"] != first_id and next_result["previous_generation"] == first_id)
for executable in ("demo", "helper", "raw-alias"):
    p = subprocess.run([str(prefix / "current/bin" / executable)], capture_output=True, timeout=5)
    check("new release updates " + executable + " bytes", p.returncode == 0 and p.stdout == b"native-install-fixture-v2\n")
run(extra=("--replace",))
check("rollback across actual releases leaves newer generation available", (prefix / "generations" / next_result["generation"] / "bin/helper").is_file())
check("rollback restores original source and all companion bytes", all(digest(prefix / "current/bin" / e) == digest(case / "payload/demo") for e in ("demo", "helper", "raw-alias")))

# All three archive formats use the actual archive module; raw aliases are
# copied, never executed by the installer.
for fmt in ("tar.xz", "zip"):
    selected_snapshot = variant("format-" + fmt)
    archive = selected_snapshot / "artifacts/demo-linux.tar.gz"
    alternate = case / ("alternate." + fmt)
    p = subprocess.run(["bash", "-c", 'source "$1/src/packaging.sh"; packaging_build_archive "$2" "$3" "$4" demo helper',
                        "_", str(root), fmt, str(alternate), str(case / "payload")], capture_output=True, timeout=30)
    check(fmt + " fixture built with actual archive helper", p.returncode == 0)
    archive.write_bytes(alternate.read_bytes())
    proof = read(selected_snapshot / "release.intoto.jsonl")
    next(a for a in proof["dsr_evidence"]["artifacts"] if a["name"] == "demo-linux.tar.gz")["archive_format"] = fmt
    save(selected_snapshot / "release.intoto.jsonl", proof)
    repin_snapshot(selected_snapshot)
    format_prefix = case / ("installed-" + fmt)
    run(selected_snapshot=selected_snapshot, selected_prefix=format_prefix,
        env=dict(environment, TAR_OPTIONS="--nonexistent-ambient-option", XZ_OPT="bad-option", ZIPOPT="bad-option"))
    check(fmt + " installation retains actual executable bytes", digest(format_prefix / "current/bin/helper") == digest(case / "payload/helper"))

current = state()
for label, mutate in (
    ("missing-companion", lambda r: r["executables"][1].update(member="absent")),
    ("foreign-target", lambda r: r.update(target="darwin/arm64")),
    ("wrong-artifact-target", lambda r: r["executables"][0].update(artifact="demo-windows.exe")),
    ("raw-member", lambda r: r["executables"][2].update(member="demo")),
    ("traversal", lambda r: r["executables"][0].update(member="../outside")),
    ("case-collision", lambda r: r["executables"][1].update(name="DEMO")),
    ("unknown-key", lambda r: r.update(command="execute")),
    ("null-executables", lambda r: r.update(executables=None)),
    ("empty", lambda r: r.update(executables=[])),
):
    value = copy.deepcopy(base)
    mutate(value)
    bad = case / (label + ".json")
    save(bad, value)
    run(7 if label == "missing-companion" else 4, selected_recipe=bad, extra=("--replace",))
    check(label + " preserves previous active generation", state() == current)

for target in ("demo-linux.tar.gz", "demo-windows.exe", "demo-linux-alias"):
    bad = variant("corrupt-" + target)
    with (bad / "artifacts" / target).open("ab") as f:
        f.write(b"changed")
    run(1, selected_snapshot=bad, extra=("--replace",))
    check("any corrupted platform or alias blocks install: " + target, state() == current)
bad = variant("forged-proof")
(bad / "release.intoto.jsonl.minisig").write_text("forged")
(bad / "download.json").write_text('{"authenticated":true}')
run(1, selected_snapshot=bad, extra=("--replace",))
check("forged historical verification status cannot authorize binaries", state() == current)
wrongkey = case / "wrong.pub"
wrongkey.write_text("untrusted comment: wrong\n" + "B"*56 + "\n")
run(1, key=wrongkey, extra=("--replace",))
check("wrong independently selected key cannot activate", state() == current)

# Signed archive bytes can still be unsafe to extract. These validly fixture-
# signed containers must be rejected by the real archive validator.
for label in ("traversal", "symlink", "hardlink", "fifo", "duplicate"):
    bad = variant("unsafe-" + label)
    archive = bad / "artifacts/demo-linux.tar.gz"
    with tarfile.open(archive, "w:gz") as out:
        info = tarfile.TarInfo("demo")
        data = (case / "payload/demo").read_bytes()
        info.size, info.mode = len(data), 0o755
        out.addfile(info, io.BytesIO(data))
        attack = tarfile.TarInfo("../escaped" if label == "traversal" else "demo" if label == "duplicate" else "helper")
        if label in ("symlink", "hardlink"):
            attack.type = tarfile.SYMTYPE if label == "symlink" else tarfile.LNKTYPE
            attack.linkname = "demo"
        elif label == "fifo":
            attack.type = tarfile.FIFOTYPE
        else:
            attack.size = 1
        out.addfile(attack, io.BytesIO(b"x") if attack.size else None)
    repin_snapshot(bad)
    run(4, selected_snapshot=bad, extra=("--replace",))
    check("signed unsafe " + label + " never changes current", state() == current)
check("unsafe archives created no escaped path", not (case / "escaped").exists())

# Managed-prefix ownership and generation integrity are independent of a
# successful fresh snapshot verification. Never adopt or silently repair.
corrupted = first_dir / "bin/helper"
old = corrupted.read_bytes()
corrupted.write_bytes(b"corrupted installation")
corrupt_hash = digest(corrupted)
run(7)
check("corrupt installed generation is not silently repaired", digest(corrupted) == corrupt_hash and os.readlink(prefix / "current") == "generations/" + first_id)
corrupted.write_bytes(old)
corrupted.chmod(0o755)
run()
unmanaged = case / "unmanaged"
unmanaged.mkdir()
(unmanaged / "keep").write_text("owned by someone else")
run(2, selected_prefix=unmanaged)
check("unmanaged prefix keeps its own files", {p.name for p in unmanaged.iterdir()} == {"keep"})
foreign = case / "foreign"
foreign.mkdir()
save(foreign / "installation.json", {"schema_version": 1, "kind": "dsr-release-install-root", "repository": "other/repo", "target": "linux/amd64"})
run(2, selected_prefix=foreign)
linked = case / "linked"
linked.symlink_to(prefix, target_is_directory=True)
run(7, selected_prefix=linked)
check("symlink prefix cannot redirect installation", os.readlink(prefix / "current") == "generations/" + first_id)
import fcntl
with Path(str(prefix) + ".lock").open("a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    run(2, extra=("--replace",))
check("occupied installation lock protects current generation", os.readlink(prefix / "current") == "generations/" + first_id)

# Block actual archive extraction, not validation logic. The trusted host tool
# wrapper supplies a deterministic interruption/mutation boundary for the test.
boundary = case / "boundary-bin"
boundary.mkdir()
real_tar = shutil.which("tar")
(boundary / "tar").write_text('#!/usr/bin/env bash\nexec python3 "' + str(case / "boundary.py") + '" "$@"\n')
(boundary / "tar").chmod(0o755)
(case / "boundary.py").write_text(r'''
import os, pathlib, subprocess, sys, time
case = pathlib.Path(os.environ["DSR_INSTALL_FIXTURE_CASE"])
if "-xzf" in sys.argv[1:]:
    mode = (case / "boundary-mode").read_text().strip()
    if mode == "recipe-drift":
        (case / "install.json").write_text('{"changed":true}\n')
    if mode == "key-drift":
        with (case / "key.pub").open("a") as f: f.write("changed\n")
    if mode in ("wait", "timeout"):
        child = subprocess.Popen(["sleep", "120"])
        (case / "boundary-marker").write_text(str(os.getpid()) + " " + str(child.pid))
        time.sleep(120)
os.execv(os.environ["DSR_REAL_TAR"], [os.environ["DSR_REAL_TAR"], *sys.argv[1:]])
''')
boundary_env = dict(environment, PATH=str(boundary) + ":" + environment["PATH"], DSR_REAL_TAR=real_tar)
for mode in ("recipe-drift", "key-drift"):
    saved_key = public.read_bytes()
    (case / "boundary-mode").write_text(mode)
    run(7, env=boundary_env, extra=("--replace",))
    check(mode + " between authentication and activation is rejected", os.readlink(prefix / "current") == "generations/" + first_id)
    save(recipe, base)
    public.write_bytes(saved_key)


def stopped(pid):
    file = Path("/proc") / str(pid) / "stat"
    return not file.exists() or file.read_text().split(") ", 1)[1].split()[0] == "Z"


(case / "boundary-mode").write_text("timeout")
run(5, env=boundary_env, extra=("--replace", "--timeout", "10"))
check("timeout reached archive extraction boundary", (case / "boundary-marker").exists())
pids = [int(v) for v in (case / "boundary-marker").read_text().split()]
check("extraction timeout stops owned tool and descendant", all(stopped(p) for p in pids))
check("extraction timeout leaves old generation active", os.readlink(prefix / "current") == "generations/" + first_id)
(case / "boundary-marker").rename(case / "previous-marker")
(case / "boundary-mode").write_text("wait")
with (case / "cancel.stdout").open("wb") as out, (case / "cancel.stderr").open("wb") as err:
    process = subprocess.Popen(command(extra=("--replace",)), env=boundary_env, stdout=out, stderr=err)
    try:
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline and not (case / "boundary-marker").exists() and process.poll() is None:
            time.sleep(.05)
        check("CLI cancellation reached owned extraction process", (case / "boundary-marker").exists())
        process.send_signal(signal.SIGTERM)
        check("cancelled installer reports interruption", process.wait(timeout=10) == 5)
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
pids = [int(v) for v in (case / "boundary-marker").read_text().split()]
check("cancellation stops only owned extraction descendants", all(stopped(p) for p in pids))
check("cancellation returns one nonactivated result", read(case / "cancel.stdout")["activated"] is False)
check("cancellation retains previous full executable set", {p.name for p in (prefix / "current/bin").iterdir()} == {"demo", "helper", "raw-alias"})
run()
check("no installer call used the network", not (case / "network-called").exists())
check("handled failure and success clean private staging", not list(case.glob(".dsr-install-*")))
print("\nAuthenticated release installation: %d passed" % checks, flush=True)
PY
