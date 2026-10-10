#!/usr/bin/env bash
# Production mapper, snapshot verifier, archive extraction and generation switch.
# Payloads are owned fixtures, not compiled GNU/musl programs. No network calls.
# Real Minisign is required unless DSR_TEST_MINISIGN_FIXTURE=1 explicitly selects
# the deterministic key/hash boundary fixture (not cryptographic qualification).
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 jq bash tar zip unzip xz sha256sum; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
python3 - "$ROOT" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix="dsr-install-variants-"))
print("Retained evidence: " + str(work), flush=True)
passed = failed = calls = 0
pin = "1" * 40
builder = "dsr:installer-variant-test"
repo = "example/app"
tag = "v1.2.3"
machine = platform.machine().lower()
if platform.system() != "Linux" or machine not in ("x86_64", "amd64", "aarch64", "arm64"):
    raise SystemExit("Requires a native Linux AMD64/ARM64 test host")
arch = "amd64" if machine in ("x86_64", "amd64") else "arm64"
cpu = "x86_64" if arch == "amd64" else "aarch64"
target = "linux/" + arch
gnu, musl = cpu + "-unknown-linux-gnu", cpu + "-unknown-linux-musl"
runtime = work / "runtime"
runtime.mkdir()
for name, variable in (("release_install.sh", "RELEASE_INSTALL_TEST_MODULE"), ("slsa.sh", "SLSA_TEST_MODULE"),
                       ("slsa_remote.sh", "SLSA_REMOTE_TEST_MODULE"), ("packaging.sh", "PACKAGING_TEST_MODULE")):
    shutil.copy2(os.environ.get(variable, root / "src" / name), runtime / name)


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print("PASS " + label, flush=True)
    else:
        failed += 1
        print("FAIL " + label, flush=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True) + "\n")
    return path


def load(path):
    return json.loads(path.read_text())


bin_dir = work / "bin"
bin_dir.mkdir()
env = {k: v for k, v in os.environ.items() if not k.startswith("BASH_FUNC_") and k not in ("BASH_ENV", "ENV")}
env["PATH"] = str(bin_dir) + ":" + env["PATH"]
# Any accidental HTTP access is a hard failure, including a public no-token call.
for name in ("gh", "curl", "wget"):
    script = bin_dir / name
    script.write_text('#!/bin/sh\nprintf "unexpected network\\n" >&2\nexit 99\n')
    script.chmod(0o755)
public, secret = work / "trusted.pub", work / "test-only.key"
fixture = os.environ.get("DSR_TEST_MINISIGN_FIXTURE") == "1"
if fixture:
    print("Signer mode: EXPLICIT key/hash CLI fixture; no cryptographic qualification", flush=True)
    token = "A" * 56
    public.write_text("untrusted comment: explicit test fixture\n" + token + "\n")
    script = bin_dir / "minisign"
    script.write_text('''#!/usr/bin/env python3
# Explicit TEST-ONLY stand-in, not an implementation of Minisign cryptography.
import hashlib, pathlib, sys
args = sys.argv[1:]
try:
    assert "-V" in args
    token = args[args.index("-P") + 1]
    proof = pathlib.Path(args[args.index("-m") + 1])
    sig = pathlib.Path(args[args.index("-x") + 1])
    expected = "TEST-ONLY:" + token + ":" + hashlib.sha256(proof.read_bytes()).hexdigest() + "\\n"
    assert sig.read_text() == expected
except (AssertionError, ValueError, IndexError, OSError):
    sys.exit(1)
''')
    script.chmod(0o755)
else:
    if not shutil.which("minisign"):
        print("Missing Minisign. DSR_TEST_MINISIGN_FIXTURE=1 explicitly selects only a signer boundary fixture.", file=sys.stderr)
        sys.exit(3)
    subprocess.run(["minisign", "-G", "-W", "-p", str(public), "-s", str(secret)], check=True, capture_output=True, timeout=30)
    print("Signer mode: real Minisign", flush=True)


def invoke(command, expected=0, label="command"):
    global calls
    calls += 1
    result = subprocess.run(list(map(str, command)), env=env, capture_output=True, timeout=45)
    (work / ("%03d.stdout" % calls)).write_bytes(result.stdout)
    (work / ("%03d.stderr" % calls)).write_bytes(result.stderr)
    check(label + " exit=" + str(expected), result.returncode == expected)
    if result.returncode != expected:
        print(result.stderr.decode(errors="replace"), flush=True)
    return result


def sign(proof):
    signature = Path(str(proof) + ".minisig")
    if fixture:
        signature.write_text("TEST-ONLY:" + token + ":" + digest(proof) + "\n")
    else:
        # Only owned proof files are signed; this key never leaves the test dir.
        subprocess.run(["minisign", "-S", "-s", str(secret), "-m", str(proof), "-x", str(signature),
                        "-t", "dsr installer variant test"], check=True, capture_output=True, timeout=30)


def make_snapshot(label, variants=(gnu, musl), explicit=True):
    base = work / label
    base.mkdir()
    snapshot = base / "snapshot"
    assets = snapshot / "artifacts"
    assets.mkdir(parents=True)
    rows, environments = [], []
    for index, triple in enumerate(variants):
        payload = base / ("payload-%d" % index)
        payload.mkdir()
        # Safe script bodies record accidental execution, rather than simulating
        # native code. Only archive/member bytes and executable bits are tested.
        for binary in ("app", "helper"):
            (payload / binary).write_text("#!/bin/sh\nprintf '%s\\n' 'TEST " + triple + " " + binary + "'\nexit 93\n")
            (payload / binary).chmod(0o755)
        fmt = "tar.gz" if index == 0 else "tar.xz"
        archive_name = "payload-%d.%s" % (index, fmt)
        subprocess.run(["bash", "-c", 'source "$1"; packaging_build_archive "$2" "$3" "$4" app helper', "_",
                        str(runtime / "packaging.sh"), fmt, str(assets / archive_name), str(payload)],
                       env=env, check=True, capture_output=True, timeout=30)
        raw_name = "alias-%d" % index
        shutil.copy2(payload / "app", assets / raw_name)
        for name, format_name in ((archive_name, fmt), (raw_name, "binary")):
            file = assets / name
            rows.append(dict(name=name, target=target, target_triple=triple, archive_format=format_name,
                             sha256=digest(file), size_bytes=file.stat().st_size))
        environments.append(dict(target=target, target_triple=triple, method="native", host="fixture"))
    manifest = dict(schema_version="1.0.0", tool="app", version=tag, source=dict(git_sha=pin, git_ref="refs/tags/" + tag, dependencies=[]),
                    run_id="12345678-1234-4123-8123-123456789abc", built_at="2026-10-10T01:02:03Z", status="success",
                    requested_targets=[target], summary=dict(total=len(variants), success=len(variants), failed=0),
                    build_environments=environments, artifacts=rows)
    if explicit:
        manifest["required_variants"] = [dict(target=target, target_triple=v) for v in variants]
    producer = save(base / "producer.json", manifest)
    proof = snapshot / "release.intoto.jsonl"
    result = invoke(["bash", runtime / "slsa.sh", "generate-manifest", producer, assets, "--repository", repo,
                     "--builder", builder, "--output", proof], label=label + " producer mapper")
    if result.returncode:
        raise RuntimeError("could not construct admitted fixture")
    sign(proof)
    save(snapshot / "download.json", dict(fixture=True, note="Unauthenticated download receipt is deliberately not authority"))
    return snapshot, producer


def recipe_for(index, triple=None):
    fmt = "tar.gz" if index == 0 else "tar.xz"
    value = dict(schema_version=1, target=target, executables=[
        dict(name="app", artifact="payload-%d.%s" % (index, fmt), member="app"),
        dict(name="helper", artifact="payload-%d.%s" % (index, fmt), member="helper"),
        dict(name="alias", artifact="alias-%d" % index)])
    if triple is not None:
        value["target_triple"] = triple
    return value


def install(label, snapshot, recipe, prefix=None, expected=0, extra=()):
    file = save(work / (label + "-recipe.json"), recipe)
    prefix = prefix or work / (label + "-prefix")
    result = invoke(["bash", runtime / "release_install.sh", "--snapshot", snapshot, "--recipe", file,
                     "--prefix", prefix, "--repo", repo, "--tag", tag, "--sha", pin, "--builder", builder,
                     "--targets", target, "--public-key", public, *extra], expected, label)
    value = json.loads(result.stdout)
    check(label + " one result agrees with process exit", value.get("kind") == "dsr-release-install" and value.get("exit_code") == result.returncode)
    if expected:
        check(label + " failure cannot claim activation", value.get("status") == "error" and value.get("activated") is False)
    else:
        check(label + " snapshot is not claimed current", value.get("authenticated") is True and value.get("remote_current") is False)
    return value, prefix


def state(prefix):
    return {str(p.relative_to(prefix)): (p.lstat().st_ino, os.readlink(p) if p.is_symlink() else digest(p))
            for p in prefix.rglob("*") if p.is_symlink() or p.is_file()}


snapshot, producer = make_snapshot("matrix")
proof = load(snapshot / "release.intoto.jsonl")
check("public proof retains two signed compiler variants", {a.get("target_triple") for a in proof["dsr_evidence"]["artifacts"]} == {gnu, musl})
# An untyped recipe used to install from this ambiguous platform silently.
result, prefix = install("untyped-matrix", snapshot, recipe_for(0), expected=4)
check("ambiguous selection creates no installation or lock", not prefix.exists() and not Path(str(prefix) + ".lock").exists())

result, prefix = install("gnu-plan", snapshot, recipe_for(0, gnu), extra=("--dry-run",))
check("typed planning keeps its selection without activation", result.get("target_triple") == gnu and not prefix.exists())
first, prefix = install("gnu-install", snapshot, recipe_for(0, gnu))
if first.get("status") == "installed":
    first_state = state(prefix)
    first_id = first["generation"]
    receipt = load(prefix / "generations" / first_id / "receipt.json")
    check("generation receipt binds recipe and every executable to GNU", receipt.get("target_triple") == gnu and
          receipt["recipe"].get("target_triple") == gnu and all(e.get("target_triple") == gnu for e in receipt["executables"]))
    check("archive and raw alias install exact named source bytes", (prefix / "current/bin/app").read_bytes() ==
          (snapshot / "artifacts/alias-0").read_bytes() and (prefix / "current/bin/alias").read_bytes() == (prefix / "current/bin/app").read_bytes())
    same, _ = install("gnu-retry", snapshot, recipe_for(0, gnu), prefix)
    check("same compiler retry preserves every inode and pointer", same.get("generation") == first_id and same.get("activated") is False and state(prefix) == first_state)
    mixed = recipe_for(0, gnu)
    mixed["executables"][2]["artifact"] = "alias-1"
    install("mixed-workspace", snapshot, mixed, prefix, 4, ("--replace",))
    check("mixed compiler workspace cannot change existing generation", state(prefix) == first_state)
    install("unapproved-switch", snapshot, recipe_for(1, musl), prefix, 2)
    check("switching ABI still requires replacement consent", state(prefix) == first_state)
    second, _ = install("musl-switch", snapshot, recipe_for(1, musl), prefix, extra=("--replace",))
    check("one pointer switches the complete musl executable set", second.get("target_triple") == musl and second.get("previous_generation") == first_id and
          (prefix / "current/bin/app").read_bytes() == (snapshot / "artifacts/alias-1").read_bytes())
    check("GNU generation remains retained after ABI switch", (prefix / "generations" / first_id / "bin/helper").is_file())
    rollback, _ = install("gnu-rollback", snapshot, recipe_for(0, gnu), prefix, extra=("--replace",))
    check("rollback reauthenticates and reuses prior compiler generation", rollback.get("generation") == first_id and
          (prefix / "generations" / first_id / "bin/helper").stat().st_ino == first_state["generations/" + first_id + "/bin/helper"][0])

for label, triple in (("wrong-variant", musl), ("unknown-variant", cpu + "-unknown-linux-other")):
    result, prefix = install(label, snapshot, recipe_for(0, triple), expected=4)
    check(label + " leaves no installation", not prefix.exists())

# The identical path and bytes cannot satisfy a different signed identity.
for label, bad in (("null", None), ("number", 7), ("array", []), ("boolean", False), ("unsafe", "../gnu"),
                   ("empty", ""), ("control", "gnu\n"), ("long", "x" * 129)):
    recipe = recipe_for(0, gnu)
    recipe["target_triple"] = bad
    file = save(work / ("bad-recipe-" + label + ".json"), recipe)
    invoke(["bash", runtime / "release_install.sh", "describe-recipe", "--recipe", file], 4, "malformed recipe " + label)
    dest = work / ("signed-" + label)
    shutil.copytree(snapshot, dest)
    statement = load(dest / "release.intoto.jsonl")
    statement["dsr_evidence"]["artifacts"][0]["target_triple"] = bad
    save(dest / "release.intoto.jsonl", statement)
    sign(dest / "release.intoto.jsonl")
    result, prefix = install("malformed-signed-" + label, dest, recipe_for(0, gnu), expected=4)
    check("malformed signed " + label + " never creates a prefix", not prefix.exists())

mixed_snapshot = work / "mixed-proof"
shutil.copytree(snapshot, mixed_snapshot)
statement = load(mixed_snapshot / "release.intoto.jsonl")
del statement["dsr_evidence"]["artifacts"][0]["target_triple"]
save(mixed_snapshot / "release.intoto.jsonl", statement)
sign(mixed_snapshot / "release.intoto.jsonl")
install("mixed-proof-untyped", mixed_snapshot, recipe_for(0), expected=4)
install("missing-signed-identity", mixed_snapshot, recipe_for(0, gnu), expected=4)
# Mutation without a new signature must fail before compiler admission.
save(mixed_snapshot / "release.intoto.jsonl", proof)
install("unsigned-identity-edit", mixed_snapshot, recipe_for(0, gnu), expected=1)

singleton, singleton_producer = make_snapshot("singleton", (gnu,))
singleton_proof = load(singleton / "release.intoto.jsonl")
check("explicit singleton compiler identity survives the public mapper", all(a.get("target_triple") == gnu for a in singleton_proof["dsr_evidence"]["artifacts"]))
check("singleton identity does not invent extra compiler tasks", "build_tasks" not in singleton_proof["dsr_evidence"])
install("singleton-typed", singleton, recipe_for(0, gnu))
legacy, _ = make_snapshot("legacy", (gnu,), explicit=False)
check("legacy singleton statement keeps the existing field shape", all("target_triple" not in a for a in load(legacy / "release.intoto.jsonl")["dsr_evidence"]["artifacts"]))
legacy_result, legacy_prefix = install("legacy-untyped", legacy, recipe_for(0))
check("legacy installation remains untyped without fabricated compiler identity", "target_triple" not in legacy_result and
      all("target_triple" not in a for a in legacy_result.get("executables", [])))
install("legacy-cannot-prove-typed", legacy, recipe_for(0, gnu), expected=4)

# Every payload in the signed snapshot must still verify, even when the recipe
# selects only GNU. The installer never narrows whole-release authentication.
broken = work / "broken-unselected"
shutil.copytree(snapshot, broken)
(broken / "artifacts/alias-1").write_bytes(b"changed unselected musl bytes")
result, prefix = install("unselected-payload-drift", broken, recipe_for(0, gnu), expected=1)
check("unselected payload drift blocks all installation state", not prefix.exists())
if first.get("status") == "installed":
    prior = state(prefix := work / "gnu-install-prefix")
    (prefix / "current/bin/helper").write_bytes(b"modified installed helper")
    result, _ = install("retained-generation-drift", snapshot, recipe_for(0, gnu), prefix, 7)
    check("changed installed generation is not silently repaired", (prefix / "current/bin/helper").read_bytes() == b"modified installed helper")

save(work / "summary.json", dict(passed=passed, failed=failed, signer="fixture" if fixture else "minisign",
                                  native_compilation=False, host=target, root=str(root)))
# Never export a real test signing key along with public validation evidence.
if secret.exists():
    secret.unlink()
print("Results: %d passed, %d failed\nEvidence: %s" % (passed, failed, work), flush=True)
sys.exit(1 if failed else 0)
PY
