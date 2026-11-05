#!/usr/bin/env bash
# Generate real self-contained installers and execute them outside a DSR tree.
# GitHub transport and Minisign are explicit fixtures. Only the test executes
# installed native C binaries; the generated installer never runs payload code.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DSR_ONLINE_FIXTURES_ONLY=true source "$HERE/test_release_install_fetch.sh"
for module in install_gen_release packaging secrets; do
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
python3 - "$INSTALL" "$CASE" "$PIN" "$ROOT" <<'PY'
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
project = Path(sys.argv[4])
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

def run(expected=0, extra=(), selected=script, dest=prefix, piped=False, env=None):
    args = ["bash", "-s", "--"] if piped else ["bash", str(selected)]
    p = subprocess.run([*args, "--prefix", str(dest), *extra], input=selected.read_bytes() if piped else None,
                       capture_output=True, timeout=40, env=env)
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
reordered["recipes"][0]["files"] = []
save(policy_file, reordered)
empty_data = generate()
check("empty runtime file selection preserves the executable-only installer identity",
      empty_data["reused"] and identity == (script.stat().st_ino, digest(script)))
save(policy_file, policy)
p = subprocess.run(["bash", str(script), "--inspect"], capture_output=True, timeout=10)
inspect = json.loads(p.stdout)
check("inspection emits selected trust policy without authentication", p.returncode == 0 and not inspect["authenticated"] and inspect["policy"]["source_sha"] == pin)
check("embedded module inventory binds actual source bytes", all(digest(install / "src" / n) == h for n, h in inspect["engines"].items()))
check("standalone inventory includes authentication deadlines and credential helpers",
      {"guardrails.sh", "secrets.sh"} <= set(inspect["engines"]))
check("generation starts no release installation", not prefix.exists())
# Generate with the complete unmodified production transport closure too. The
# larger online suite below replaces HTTP transport explicitly; it must not
# conceal a missing source-relative dependency in a distributable installer.
production_script = case / "production-install.sh"
production = subprocess.run(["bash", str(project / "src/install_gen_release.sh"), "--policy", str(policy_file),
    "--public-key", str(key), "--output", str(production_script)], capture_output=True, timeout=30)
check("complete production engines generate a standalone installer", production.returncode == 0)
if production.returncode:
    raise AssertionError(production.stderr)
production_bundle = json.loads(base64.b64decode(production_script.read_text().split("BUNDLE = '", 1)[1].split("'", 1)[0]))
production_modules = case / "production-modules"
production_modules.mkdir()
for name, record in production_bundle["modules"].items():
    (production_modules / name).write_bytes(base64.b64decode(record["content"]))
clean_env = {k: v for k, v in os.environ.items() if not k.startswith("BASH_FUNC_") and k not in ("BASH_ENV", "ENV")}
loaded = subprocess.run(["bash", "-c", 'source "$1/github.sh" && source "$1/slsa_remote.sh" && '
    'declare -F secrets_get_gh_token >/dev/null && declare -F run_with_timeout >/dev/null && '
    'declare -F dsr_lock_fd >/dev/null && declare -F gh_download_release_asset >/dev/null',
    "_", str(production_modules)], env=clean_env, capture_output=True, timeout=10)
check("bundled real GitHub adapter loads its complete credential and deadline closure", loaded.returncode == 0)
production_prefix = case / "production-prefix"
production_install = subprocess.run(["bash", str(production_script), "--prefix", str(production_prefix),
    "--snapshot", str(snapshot), "--dry-run"], env=clean_env, capture_output=True, timeout=30)
check("complete production standalone engine authenticates offline without a DSR installation",
      production_install.returncode == 0 and json.loads(production_install.stdout).get("authenticated") is True and
      not production_prefix.exists())
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
                 ("--targets", "linux/amd64"), ("--files", "/other/data.json"), ("--from-source",),
                 ("--version", "v2.0.0"), ("--timeout", "1", "--timeout", "2")):
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

# A generated installer and its embedded engine must agree on host identity.
# Only platform.system/machine are simulated; the complete signed snapshot,
# archive extraction, digest checks, recipe binding and activation are real.
# Payload execution on a foreign architecture is deliberately not attempted.
for target, system, machine, triple in (
    ("linux/armv7", "Linux", "armv7l", "armv7-unknown-linux-gnueabihf"),
    ("freebsd/amd64", "FreeBSD", "amd64", "x86_64-unknown-freebsd"),
):
    label = target.replace("/", "-")
    host_fixture = case / (label + "-host")
    host_fixture.mkdir()
    (host_fixture / "sitecustomize.py").write_text(
        "# Test-only host identity fixture. No production verifier is replaced.\nimport platform\n"
        "platform.system = lambda: " + repr(system) + "\nplatform.machine = lambda: " + repr(machine) + "\n")
    host_env = dict(os.environ, PYTHONPATH=str(host_fixture))
    foreign_snapshot = case / (label + "-snapshot")
    shutil.copytree(snapshot, foreign_snapshot)
    manifest = json.loads((case / "build.json").read_text())
    manifest["requested_targets"] = [target if t == "linux/amd64" else t for t in manifest["requested_targets"]]
    for asset in manifest["artifacts"]:
        if asset["target"] == "linux/amd64":
            asset.update(target=target, target_triple=triple)
        else:
            asset["target_triple"] = "aarch64-pc-windows-msvc"
    manifest["required_variants"] = [dict(target=target, target_triple=triple),
                                     dict(target="windows/arm64", target_triple="aarch64-pc-windows-msvc")]
    foreign_manifest = case / (label + "-build.json")
    save(foreign_manifest, manifest)
    proof = foreign_snapshot / "release.intoto.jsonl"
    with proof.open("wb") as out:
        subprocess.run(["bash", "-c", 'source "$1/slsa.sh"; _slsa_manifest_statement "$2" owner/demo dsr:test',
            "_", str(install / "src"), str(foreign_manifest)], stdout=out, check=True)
    (foreign_snapshot / "release.intoto.jsonl.minisig").write_text(key.read_text().splitlines()[1] + ":" + digest(proof) + "\n")
    foreign_policy = copy.deepcopy(policy)
    foreign_policy["targets"] = [target if t == "linux/amd64" else t for t in foreign_policy["targets"]]
    foreign_policy["recipes"][0].update(target=target, target_triple=triple)
    selected_policy, selected_script = case / (label + "-policy.json"), case / (label + "-install.sh")
    save(selected_policy, foreign_policy)
    generate(output=selected_script, selected=selected_policy)
    foreign_prefix = case / (label + "-prefix")
    foreign_result = run(selected=selected_script, dest=foreign_prefix, env=host_env,
                         extra=("--snapshot", str(foreign_snapshot)))
    check(target + " standalone installer authenticates and activates its exact compiler variant",
          foreign_result["authenticated"] and foreign_result["activated"] and
          foreign_result["target_triple"] == triple and
          json.loads((foreign_prefix / "current/receipt.json").read_text())["target"] == target)
    check(target + " installation preserves every selected executable",
          {p.name for p in (foreign_prefix / "current/bin").iterdir()} == {"demo", "helper", "raw"} and
          (foreign_prefix / "current/bin/demo").read_bytes() == (case / "payload/demo").read_bytes())
    retained_pointer = os.readlink(foreign_prefix / "current")
    unselected = foreign_snapshot / "artifacts/demo-windows.exe"
    unselected.write_bytes(unselected.read_bytes() + b"changed unselected platform")
    run(1, selected=selected_script, dest=foreign_prefix, env=host_env,
        extra=("--snapshot", str(foreign_snapshot)))
    check(target + " still authenticates unselected platforms before changing activation",
          os.readlink(foreign_prefix / "current") == retained_pointer)

# The complete allowlist is no longer limited by the old nine-element product.
all_platforms = ["linux/amd64", "linux/arm64", "linux/386", "linux/armv7", "darwin/amd64", "darwin/arm64",
                 "windows/amd64", "windows/arm64", "windows/386", "freebsd/amd64"]
complete = copy.deepcopy(policy)
complete["targets"] = all_platforms
complete["recipes"] = []
for target in all_platforms:
    if not target.startswith("windows/"):
        selected_recipe = copy.deepcopy(policy["recipes"][0])
        selected_recipe["target"] = target
        complete["recipes"].append(selected_recipe)
save(case / "complete-policy.json", complete)
complete_result = generate(output=case / "complete-install.sh", selected=case / "complete-policy.json")
check("all supported platform pairs fit one authenticated installer policy", len(complete_result["targets"]) == 7)

# Invalid independent selections fail before creating an installer file/lock.
for label, change in (
    ("zero-source", lambda p: p.update(source_sha="0"*40)),
    ("unknown-field", lambda p: p.update(command="touch bad")),
    ("null-recipes", lambda p: p.update(recipes=None)),
    ("duplicate-target", lambda p: p["targets"].append("linux/amd64")),
    ("unsupported-pair", lambda p: p["targets"].append("freebsd/armv7")),
    ("unsupported-recipe", lambda p: p["recipes"][0].update(target="windows/armv7")),
    ("target-with-newline", lambda p: p["targets"].append("linux/armv7\n")),
    ("missing-host-recipe", lambda p: p["targets"].append("darwin/arm64")),
    ("duplicate-recipe", lambda p: p["recipes"].append(copy.deepcopy(p["recipes"][0]))),
    ("unsafe-name", lambda p: p["recipes"][0]["executables"][0].update(name="../bad")),
    ("colliding-name", lambda p: p["recipes"][0]["executables"][1].update(name="DEMO")),
    ("bad-member", lambda p: p["recipes"][0]["executables"][0].update(member="../outside")),
    ("null-runtime-files", lambda p: p["recipes"][0].update(files=None)),
    ("runtime-file-outside-share", lambda p: p["recipes"][0].update(files=[dict(path="bin/data", artifact="runtime.json")])),
    ("runtime-file-traversal", lambda p: p["recipes"][0].update(files=[dict(path="share/app/../data", artifact="runtime.json")])),
    ("runtime-directory-case", lambda p: p["recipes"][0].update(files=[
        dict(path="share/Data/a", artifact="runtime.json"), dict(path="share/data/b", artifact="runtime.json")])),
    ("runtime-file-prefix", lambda p: p["recipes"][0].update(files=[
        dict(path="share/app/data", artifact="runtime.json"), dict(path="share/app/data/b", artifact="runtime.json")])),
    ("runtime-mode-override", lambda p: p["recipes"][0].update(files=[dict(path="share/app/data", artifact="runtime.json", mode=493)])),
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

# A complete program needs both a physical-platform archive and shared signed
# runtime data. Exercise the actual generated engine with both input families,
# then run the installed program separately to prove it can find its data.
data_versions = []
for number, tag, source_pin in ((1, "v1.2.3", pin), (2, "v1.2.4", "b" * 40)):
    label = "runtime-data-" + str(number)
    data_snapshot = case / (label + "-snapshot")
    shutil.copytree(snapshot, data_snapshot)
    payload = case / (label + "-payload")
    (payload / "docs").mkdir(parents=True)
    (payload / "app").write_text('#!/bin/sh\nset -eu\ndata="${0%/*}/../share/demo"\n'
        'test -f "$data/empty"\nprintf "runtime-app-' + str(number) + '\\n"\n'
        'cat "$data/runtime.json" "$data/docs/help.txt"\n')
    (payload / "app").chmod(0o755)
    (payload / "docs/help.txt").write_text("runtime-help-" + str(number) + "\n")
    (payload / "docs/help.txt").chmod(0o755)
    (payload / "docs/empty").write_bytes(b"")
    archive = data_snapshot / "artifacts/runtime-linux.tar.gz"
    subprocess.run(["bash", "-c", 'source "$1/packaging.sh"; packaging_build_archive tar.gz "$2" "$3" app docs',
        "_", str(install / "src"), str(archive), str(payload)], check=True)
    shared = data_snapshot / "artifacts/runtime.json"
    shared.write_text('{"runtime_version":' + str(number) + '}\n')
    manifest = json.loads((case / "build.json").read_text())
    manifest["version"] = tag
    manifest["source"].update(git_sha=source_pin, git_ref="refs/tags/" + tag)
    for file, target, fmt in ((archive, "linux/amd64", "tar.gz"), (shared, "additional", "none")):
        manifest["artifacts"].append(dict(name=file.name, target=target, archive_format=fmt,
                                           sha256=digest(file), size_bytes=file.stat().st_size))
    manifest_path = case / (label + "-build.json")
    save(manifest_path, manifest)
    proof = data_snapshot / "release.intoto.jsonl"
    with proof.open("wb") as out:
        subprocess.run(["bash", "-c", 'source "$1/slsa.sh"; _slsa_manifest_statement "$2" owner/demo dsr:test',
            "_", str(install / "src"), str(manifest_path)], stdout=out, check=True)
    (data_snapshot / "release.intoto.jsonl.minisig").write_text(key.read_text().splitlines()[1] + ":" + digest(proof) + "\n")
    data_policy = copy.deepcopy(policy)
    data_policy.update(tag=tag, source_sha=source_pin)
    data_policy["recipes"][0] = dict(schema_version=1, target="linux/amd64",
        executables=[dict(name="runtime", artifact=archive.name, member="app")], files=[
            dict(path="share/demo/runtime.json", artifact=shared.name),
            dict(path="share/demo/empty", artifact=archive.name, member="docs/empty"),
            dict(path="share/demo/docs/help.txt", artifact=archive.name, member="docs/help.txt")])
    selected_policy, selected_script = case / (label + "-policy.json"), case / (label + "-install.sh")
    save(selected_policy, data_policy)
    generate(output=selected_script, selected=selected_policy)
    generated_identity = (selected_script.stat().st_ino, digest(selected_script))
    data_policy["recipes"][0]["files"].reverse()
    save(selected_policy, data_policy)
    regenerated = generate(output=selected_script, selected=selected_policy)
    check(label + " canonical file ordering preserves generated script identity",
          regenerated["reused"] and generated_identity == (selected_script.stat().st_ino, digest(selected_script)))
    inspected = subprocess.run(["bash", str(selected_script), "--inspect"], capture_output=True, check=True, timeout=10)
    check(label + " standalone inspection contains the exact reviewed runtime data destinations",
          [f["path"] for f in json.loads(inspected.stdout)["policy"]["recipes"][0]["files"]] ==
          ["share/demo/docs/help.txt", "share/demo/empty", "share/demo/runtime.json"])
    data_versions.append((data_snapshot, selected_script, selected_policy))

data_prefix = case / "runtime-data-prefix"
detached = case / "runtime-data-detached-inputs"
detached.mkdir()
input_paths = [install, key, *(entry[2] for entry in data_versions)]
for path in input_paths:
    path.rename(detached / path.name)
try:
    original_data, original_installer, _ = data_versions[0]
    later_data, later_installer, _ = data_versions[1]
    initial = run(selected=original_installer, dest=data_prefix, extra=("--snapshot", str(original_data)), piped=True)
    initial_pointer = ((data_prefix / "current").lstat().st_ino, os.readlink(data_prefix / "current"))
    original_files = {item["path"]: ((data_prefix / "current" / item["path"]).stat().st_ino, item["sha256"])
                      for item in initial["files"]}
    check("generated install activates shared data and archive members in one generation",
          initial["activated"] and {f["target"] for f in initial["files"]} == {"linux/amd64", "additional"} and
          initial["share_dir"] == str(data_prefix / "current/share") and
          initial["generation_share_dir"] == str(data_prefix / "generations" / initial["generation"] / "share"))
    check("generated runtime files have fixed non-executable permissions and preserve empty data",
          all((data_prefix / "current" / f["path"]).stat().st_mode & 0o777 == 0o644 and f["mode"] == 0o644
              for f in initial["files"]) and (data_prefix / "current/share/demo/empty").stat().st_size == 0)
    app = data_prefix / "current/bin/runtime"
    executed = subprocess.run([str(app)], capture_output=True, timeout=5)
    check("test runs installed program with both authenticated runtime sources",
          executed.returncode == 0 and executed.stdout == b'runtime-app-1\n{"runtime_version":1}\nruntime-help-1\n')
    retried = run(selected=original_installer, dest=data_prefix, extra=("--snapshot", str(original_data)))
    check("generated complete data retry preserves pointer and every data inode",
          retried["generation"] == initial["generation"] and not retried["activated"] and
          ((data_prefix / "current").lstat().st_ino, os.readlink(data_prefix / "current")) == initial_pointer and
          all(((data_prefix / "current" / path).stat().st_ino, digest(data_prefix / "current" / path)) == identity
              for path, identity in original_files.items()))
    run(2, selected=later_installer, dest=data_prefix, extra=("--snapshot", str(later_data)))
    check("runtime data upgrade needs replacement consent",
          ((data_prefix / "current").lstat().st_ino, os.readlink(data_prefix / "current")) == initial_pointer)
    newer = run(selected=later_installer, dest=data_prefix, extra=("--snapshot", str(later_data), "--replace"), piped=True)
    executed = subprocess.run([str(app)], capture_output=True, timeout=5)
    check("one generated activation upgrades the executable and both runtime sources",
          newer["generation"] != initial["generation"] and newer["previous_generation"] == initial["generation"] and
          executed.returncode == 0 and executed.stdout == b'runtime-app-2\n{"runtime_version":2}\nruntime-help-2\n')
    restored = run(selected=original_installer, dest=data_prefix, extra=("--snapshot", str(original_data), "--replace"))
    executed = subprocess.run([str(app)], capture_output=True, timeout=5)
    check("old generated installer reauthenticates and restores the entire runtime generation",
          restored["generation"] == initial["generation"] and restored["previous_generation"] == newer["generation"] and
          executed.returncode == 0 and executed.stdout == b'runtime-app-1\n{"runtime_version":1}\nruntime-help-1\n' and
          all(((data_prefix / "current" / path).stat().st_ino, digest(data_prefix / "current" / path)) == identity
              for path, identity in original_files.items()))
    selected_shared = original_data / "artifacts/runtime.json"
    selected_shared.write_bytes(selected_shared.read_bytes() + b"changed signed data")
    preserved_pointer = ((data_prefix / "current").lstat().st_ino, os.readlink(data_prefix / "current"))
    run(1, selected=original_installer, dest=data_prefix, extra=("--snapshot", str(original_data)))
    check("corrupt shared runtime subject cannot alter a generated active installation",
          ((data_prefix / "current").lstat().st_ino, os.readlink(data_prefix / "current")) == preserved_pointer and
          all(((data_prefix / "current" / path).stat().st_ino, digest(data_prefix / "current" / path)) == identity
              for path, identity in original_files.items()))
finally:
    for path in input_paths:
        (detached / path.name).rename(path)
# The shared recipe normalizer used by generation is a public no-write query.
p = subprocess.run(["bash", str(engine), "describe-recipe", "--recipe", str(case / "offline-policy.json")], capture_output=True)
check("recipe query refuses a nonexistent selection", p.returncode != 0)
print("\nGenerated authenticated installers: %d passed" % checks, flush=True)
PY
