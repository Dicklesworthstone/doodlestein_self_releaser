#!/usr/bin/env bash
# Generate real self-contained installers and execute them outside a DSR tree.
# GitHub transport and Minisign are explicit fixtures. Only the test executes
# installed native C binaries; the generated installer never runs payload code.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DSR_ONLINE_FIXTURES_ONLY=true source "$HERE/test_release_install_fetch.sh"
for module in install_gen_release packaging; do
    cp "$ROOT/src/$module.sh" "$INSTALL/src/" || exit 1
done
# The transport closure is explicitly substituted; it does not test gh/curl.
# No production validator, archive helper or installation engine is replaced.
printf '#!/usr/bin/env bash\n# Unused GitHub transport fixture.\n' > "$INSTALL/src/github.sh"
printf '#!/usr/bin/env bash\n# Unused SBOM transport dependency fixture.\n' > "$INSTALL/src/sbom.sh"
mkdir "$CASE/payload"
if command -v cc >/dev/null; then
    printf '#include <stdio.h>\nint main(void) { return puts("generated-native-fixture") < 0; }\n' > "$CASE/program.c"
    cc "$CASE/program.c" -o "$CASE/payload/demo" || exit 1
else
    printf '#!/bin/sh\nprintf "generated-native-fixture\\n"\n' > "$CASE/payload/demo"
    chmod 755 "$CASE/payload/demo"
fi
cp "$CASE/payload/demo" "$CASE/payload/helper"
source "$ROOT/src/packaging.sh"
packaging_build_archive tar.gz "$CASE/remote/payload.tar.gz" "$CASE/payload" demo helper || exit 1
cp "$CASE/remote/payload.tar.gz" "$CASE/remote/1"
cp "$CASE/payload/demo" "$CASE/remote/2"
jq --arg hash "$(_slsa_sha256 "$CASE/remote/1")" --argjson size "$(wc -c < "$CASE/remote/1")" \
    --arg raw "$(_slsa_sha256 "$CASE/remote/2")" --argjson rawsize "$(wc -c < "$CASE/remote/2")" \
    '.artifacts[0] |= (.name="demo-linux.tar.gz"|.archive_format="tar.gz"|.sha256=$hash|.size_bytes=$size) |
     .artifacts[1] |= (.sha256=$raw|.size_bytes=$rawsize)' "$CASE/build.json" > "$CASE/changed-build.json"
cp "$CASE/changed-build.json" "$CASE/build.json"
_slsa_manifest_statement "$CASE/build.json" owner/demo dsr:test > "$CASE/remote/4" || exit 1
sign_fixture "$CASE/remote/4" "$CASE/remote/5"
refresh_remote
jq 'map(if .id==1 then .name="demo-linux.tar.gz" else . end)' "$CASE/inventory.json" > "$CASE/updated.json"
cp "$CASE/updated.json" "$CASE/inventory.json"
fetch > "$CASE/snapshot-result.json" || exit 1
python3 - "$INSTALL" "$CASE" "$PIN" <<'PY'
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

install, case, pin = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
engine = install / "src/release_install.sh"
policy_file = case / "policy.json"
script = case / "install.sh"
key = case / "key.pub"
snapshot = case / "snapshot"
prefix = case / "prefix"
checks = 0
policy = dict(schema_version=1, repo="owner/demo", tag="v1.2.3", source_sha=pin, builder="dsr:test",
    targets=["windows/arm64", "linux/amd64"], recipes=[dict(schema_version=1, target="linux/amd64", executables=[
        dict(name="demo", artifact="demo-linux.tar.gz", member="demo"),
        dict(name="helper", artifact="demo-linux.tar.gz", member="helper"),
        dict(name="raw", artifact="demo-linux-alias")])])

def save(file, value):
    file.write_text(json.dumps(value) + "\n")

def check(label, condition):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print("PASS " + label, flush=True)

def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def generate(expected=0, output=script, selected=policy_file, extra=()):
    p = subprocess.run(["bash", str(engine), "generate-installer", "--policy", str(selected), "--public-key", str(key),
                        "--output", str(output), *extra], capture_output=True, timeout=30)
    (case / "generation.stdout").write_bytes(p.stdout)
    (case / "generation.stderr").write_bytes(p.stderr)
    if p.returncode != expected:
        raise AssertionError(f"generation expected {expected}: {p.stdout!r} {p.stderr!r}")
    value = json.loads(p.stdout)
    check("generation returns its actual exit status", value["exit_code"] == expected)
    return value

def run(expected=0, extra=(), selected=script, dest=prefix, piped=False):
    args = ["bash", "-s", "--"] if piped else ["bash", str(selected)]
    p = subprocess.run([*args, "--prefix", str(dest), *extra], input=selected.read_bytes() if piped else None,
                       capture_output=True, timeout=40)
    (case / "runtime.stdout").write_bytes(p.stdout)
    (case / "runtime.stderr").write_bytes(p.stderr)
    if p.returncode != expected:
        raise AssertionError(f"installer expected {expected}: {p.stdout!r} {p.stderr!r}")
    value = json.loads(p.stdout)
    check("standalone result matches exit status", value["exit_code"] == expected)
    if expected:
        check("failed standalone invocation never claims successful installation", value["status"] == "error")
    return value

def pointer():
    p = prefix / "current"
    return (p.lstat().st_ino, os.readlink(p))

save(policy_file, policy)
result = generate()
original_script = script.read_bytes()
check("generation does not claim payload authentication", not result["authenticated"])
check("generated source bytes match returned checksum", result["sha256"] == digest(script))
check("output is executable and Bash-valid", script.stat().st_mode & 0o777 == 0o755 and subprocess.run(["bash", "-n", str(script)]).returncode == 0)
identity = (script.stat().st_ino, digest(script))
reordered = copy.deepcopy(policy)
reordered["targets"].reverse()
reordered["recipes"][0]["executables"].reverse()
save(policy_file, reordered)
agreed = generate()
check("canonical policy reordering preserves generated bytes and inode", agreed["reused"] and identity == (script.stat().st_ino, digest(script)))
save(policy_file, policy)
p = subprocess.run(["bash", str(script), "--inspect"], capture_output=True, timeout=10)
inspect = json.loads(p.stdout)
check("inspection emits selected trust policy without authentication", p.returncode == 0 and not inspect["authenticated"] and inspect["policy"]["source_sha"] == pin)
check("embedded module inventory binds actual source bytes", all(digest(install / "src" / n) == h for n, h in inspect["engines"].items()))
check("generation starts no release installation", not prefix.exists())
# Detach the generation environment. All following installs must use embedded
# engines, not any original path, external policy or external public key file.
offline_install = case / "offline-engine"
install.rename(offline_install)
policy_file.rename(case / "offline-policy.json")
key.rename(case / "offline-key.pub")
try:
    planned = run(extra=("--dry-run",), piped=True)
    check("piped installer authenticates all bytes without activating", planned["status"] == "planned" and not prefix.exists())
    first = run(piped=True)
    check("standalone streamed install activates every companion", first["authenticated"] and first["activated"] and
          {p.name for p in (prefix / "current/bin").iterdir()} == {"demo", "helper", "raw"})
    for n in ("demo", "helper", "raw"):
        p = subprocess.run([str(prefix / "current/bin" / n)], capture_output=True, timeout=5)
        check("test executes installed native " + n, p.returncode == 0 and p.stdout == b"generated-native-fixture\n")
    before = pointer()
    again = run(extra=("--snapshot", str(snapshot)))
    check("offline retry selects the same signed generation", again["generation"] == first["generation"] and not again["activated"] and pointer() == before)
    calls = (case / "calls").read_bytes()
    for args in (("--public-key", "/other/key"), ("--sha", "b"*40), ("--repo", "other/repo"),
                 ("--targets", "linux/amd64"), ("--from-source",), ("--version", "v2.0.0"), ("--timeout", "1", "--timeout", "2")):
        run(4, extra=args)
    check("runtime cannot weaken embedded policy or execute source fallback", (case / "calls").read_bytes() == calls and pointer() == before)
    # Even the platform not installed locally must remain complete and signed.
    payload = snapshot / "artifacts/demo-windows.exe"
    old = payload.read_bytes()
    payload.write_bytes(old + b"corrupt")
    run(1, extra=("--snapshot", str(snapshot)))
    check("unused-platform corruption preserves complete active generation", pointer() == before)
    payload.write_bytes(old)
    (case / "mode").write_text("network-failure\n")
    run(8)
    check("online failure cannot silently fall back to unverified local data", pointer() == before)
    run(extra=("--snapshot", str(snapshot)))
    (case / "mode").write_text("normal\n")
    # Catch accidental bootstrap data damage before any module is executed.
    damaged = case / "damaged.sh"
    text = script.read_text()
    encoded = text.split("BUNDLE = '", 1)[1].split("'", 1)[0]
    bad = ("A" if encoded[0] != "A" else "B") + encoded[1:]
    damaged.write_text(text.replace(encoded, bad, 1))
    run(7, selected=damaged)
    check("embedded corruption cannot change active installation", pointer() == before)
    # The generated wrapper must forward cancellation through the actual engine.
    (case / "mode").write_text("slow\n")
    process = subprocess.Popen(["bash", str(script), "--prefix", str(prefix)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        until = time.monotonic() + 10
        while time.monotonic() < until and not (case / "slow-pid").exists() and process.poll() is None:
            time.sleep(.05)
        check("generated CLI reaches its owned fetch process", (case / "slow-pid").exists())
        process.send_signal(signal.SIGTERM)
        out, err = process.communicate(timeout=10)
        check("generated CLI preserves the engine's interrupted result", process.returncode == 5 and json.loads(out)["exit_code"] == 5)
        check("cancelled generated installer preserves activation state", not json.loads(out)["activated"] and pointer() == before)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    (case / "mode").write_text("normal\n")
    run()
    check("runtime removes private embedded-engine staging", not list(case.glob(".dsr-installer-*")))
finally:
    offline_install.rename(install)
    (case / "offline-policy.json").rename(policy_file)
    (case / "offline-key.pub").rename(key)

# Invalid independent selections fail before creating an installer file/lock.
for label, change in (
    ("zero-source", lambda p: p.update(source_sha="0"*40)),
    ("unknown-field", lambda p: p.update(command="touch bad")),
    ("null-recipes", lambda p: p.update(recipes=None)),
    ("duplicate-target", lambda p: p["targets"].append("linux/amd64")),
    ("missing-host-recipe", lambda p: p["targets"].append("darwin/arm64")),
    ("duplicate-recipe", lambda p: p["recipes"].append(copy.deepcopy(p["recipes"][0]))),
    ("unsafe-name", lambda p: p["recipes"][0]["executables"][0].update(name="../bad")),
    ("colliding-name", lambda p: p["recipes"][0]["executables"][1].update(name="DEMO")),
    ("bad-member", lambda p: p["recipes"][0]["executables"][0].update(member="../outside")),
    ("null-build-pin", lambda p: p.update(statement_sha256=None)),
):
    changed = copy.deepcopy(policy)
    change(changed)
    file = case / (label + ".json")
    save(file, changed)
    out = case / (label + ".sh")
    generate(4, output=out, selected=file)
    check(label + " leaves no output or persistent lock", not out.exists() and not Path(str(out) + ".lock").exists())
file = case / "duplicate.json"
file.write_text(policy_file.read_text().rstrip()[:-1] + ',"schema_version":1}\n')
generate(4, selected=file)
check("invalid replacement leaves original installer intact", identity == (script.stat().st_ino, digest(script)))
# A literal builder is data even when it resembles shell/Python/template code.
literal = copy.deepcopy(policy)
literal["builder"] = "dsr:$(touch " + str(case / "must-not-exist") + "); '__DSR_RELEASE_BUNDLE__'"
save(case / "literal.json", literal)
generate(0, selected=case / "literal.json", output=case / "literal.sh")
p = subprocess.run(["bash", str(case / "literal.sh"), "--inspect"], capture_output=True, timeout=10)
check("builder metacharacters round-trip without execution", p.returncode == 0 and json.loads(p.stdout)["policy"]["builder"] == literal["builder"] and not (case / "must-not-exist").exists())
# Explicitly generate a new source/tag policy; runtime cannot override it.
changed = copy.deepcopy(policy)
changed.update(tag="v1.2.4", source_sha="b"*40)
save(case / "next.json", changed)
generate(2, selected=case / "next.json")
check("different installer policy requires explicit file replacement", identity == (script.stat().st_ino, digest(script)))
next_installer = generate(0, selected=case / "next.json", extra=("--replace",))
check("explicit generator replacement changes the selected source policy", next_installer["sha256"] != identity[1])
run(7, extra=("--snapshot", str(snapshot)))
check("new installer cannot authenticate an old source/tag snapshot", pointer() == before)
# An actual version/source transition changes all selected executable bytes.
# Construct its signed fixture with the real manifest mapper, then test the
# complete generated upgrade and rollback paths without any DSR dependency.
next_snapshot = case / "next-snapshot"
shutil.copytree(snapshot, next_snapshot)
next_payload = case / "next-payload"
next_payload.mkdir()
if shutil.which("cc"):
    source = case / "next.c"
    source.write_text('#include <stdio.h>\nint main(void) { return puts("generated-version-two") < 0; }\n')
    subprocess.run(["cc", str(source), "-o", str(next_payload / "demo")], check=True)
else:
    (next_payload / "demo").write_text('#!/bin/sh\nprintf "generated-version-two\\n"\n')
    (next_payload / "demo").chmod(0o755)
shutil.copy2(next_payload / "demo", next_payload / "helper")
subprocess.run(["bash", "-c", 'source "$1/packaging.sh"; packaging_build_archive tar.gz "$2" "$3" demo helper',
    "_", str(install / "src"), str(next_snapshot / "artifacts/demo-linux.tar.gz"), str(next_payload)], check=True)
shutil.copy2(next_payload / "demo", next_snapshot / "artifacts/demo-linux-alias")
manifest = json.loads((case / "build.json").read_text())
manifest.update(version="v1.2.4", built_at="2026-09-24T01:00:00Z")
manifest["source"].update(git_sha="b"*40, git_ref="refs/tags/v1.2.4")
for asset in manifest["artifacts"]:
    file = next_snapshot / "artifacts" / asset["name"]
    asset.update(sha256=digest(file), size_bytes=file.stat().st_size)
save(case / "next-build.json", manifest)
proof = next_snapshot / "release.intoto.jsonl"
with proof.open("wb") as out:
    subprocess.run(["bash", "-c", 'source "$1/slsa.sh"; _slsa_manifest_statement "$2" owner/demo dsr:test',
        "_", str(install / "src"), str(case / "next-build.json")], stdout=out, check=True)
(next_snapshot / "release.intoto.jsonl.minisig").write_text(key.read_text().splitlines()[1] + ":" + digest(proof) + "\n")
run(2, extra=("--snapshot", str(next_snapshot)))
check("generated version upgrade requires explicit replacement", pointer() == before)
upgraded = run(extra=("--snapshot", str(next_snapshot), "--replace"), piped=True)
check("generated upgrade activates the newly authenticated generation", upgraded["generation"] != first["generation"] and upgraded["previous_generation"] == first["generation"])
for name in ("demo", "helper", "raw"):
    p = subprocess.run([str(prefix / "current/bin" / name)], capture_output=True, timeout=5)
    check("test executes upgraded " + name, p.returncode == 0 and p.stdout == b"generated-version-two\n")
rollback_script = case / "rollback.sh"
rollback_script.write_bytes(original_script)
rolled = run(selected=rollback_script, extra=("--snapshot", str(snapshot), "--replace"))
check("old standalone installer reauthenticates an explicit rollback", rolled["generation"] == first["generation"] and rolled["previous_generation"] == upgraded["generation"])
# The shared recipe normalizer used by generation is a public no-write query.
p = subprocess.run(["bash", str(engine), "describe-recipe", "--recipe", str(case / "offline-policy.json")], capture_output=True)
check("recipe query refuses a nonexistent selection", p.returncode != 0)
print("\nGenerated authenticated installers: %d passed" % checks, flush=True)
PY
