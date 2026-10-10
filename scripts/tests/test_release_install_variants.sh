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
import hashlib, os, pathlib, sys
args = sys.argv[1:]
try:
    assert "-V" in args
    token = args[args.index("-P") + 1]
    proof = pathlib.Path(args[args.index("-m") + 1])
    sig = pathlib.Path(args[args.index("-x") + 1])
    expected = "TEST-ONLY:" + token + ":" + hashlib.sha256(proof.read_bytes()).hexdigest() + "\\n"
    assert sig.read_text() == expected
    if os.environ.get("DSR_INSTALL_CONTRACT_MUTATE"):
        pathlib.Path(os.environ["DSR_INSTALL_CONTRACT_MUTATE"]).write_text('{"changed":true}\\n')
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

# The distributable installer embeds this exact production installation engine.
# A partial validation checkout can explicitly omit only unused ONLINE module
# bodies; fail-if-sourced sentinels prove those paths are not an offline shortcut.
shutil.copy2(os.environ.get("INSTALL_GEN_RELEASE_TEST_MODULE", root / "src/install_gen_release.sh"),
             runtime / "install_gen_release.sh")
offline_stubs = []
for module_name in ("sbom_release.sh", "sbom.sh", "github.sh"):
    original = root / "src" / module_name
    if original.is_file():
        shutil.copy2(original, runtime / module_name)
    elif os.environ.get("DSR_TEST_OFFLINE_ENGINE_STUBS") == "1":
        offline_stubs.append(module_name)
        (runtime / module_name).write_text('#!/usr/bin/env bash\n# EXPLICIT TEST-ONLY: unused online module.\n'
            'printf "unexpected online engine invocation\\n" >&2\nreturn 99 2>/dev/null || exit 99\n')
    else:
        raise RuntimeError("Missing " + module_name + "; full checkout required, or explicitly set DSR_TEST_OFFLINE_ENGINE_STUBS=1 for offline-only tests")
if offline_stubs:
    print("Embedded online inventory: EXPLICIT unused fail-if-sourced sentinels: " + ", ".join(offline_stubs), flush=True)


def policy_for(recipes):
    return dict(schema_version=1, repo=repo, tag=tag, source_sha=pin, builder=builder,
                targets=[target], recipes=recipes)


def generate(label, policy, output=None, expected=0):
    policy_path = save(work / (label + "-policy.json"), policy)
    output = output or work / (label + "-install.sh")
    result = invoke(["bash", runtime / "install_gen_release.sh", "--policy", policy_path,
                     "--public-key", public, "--output", output], expected, label + " generation")
    value = json.loads(result.stdout)
    check(label + " generation envelope agrees with exit", value.get("kind") == "dsr-release-installer-generation" and
          value.get("exit_code") == result.returncode)
    if expected:
        check(label + " invalid policy produces no installer", not output.exists())
    else:
        check(label + " generation makes no authentication claim", value.get("authenticated") is False)
    return value, output


def generated_install(label, script, selected_snapshot, prefix, extra=(), expected=0, streamed=False):
    command = ["bash", str(script), "--snapshot", str(selected_snapshot), "--prefix", str(prefix), *extra]
    if streamed:
        command = ["bash", "-c", 'cat -- "$1" | bash -s -- "${@:2}"', "_", *command[1:]]
    result = invoke(command, expected, label)
    value = json.loads(result.stdout)
    check(label + " standalone result agrees with process", value.get("kind") == "dsr-release-install" and value.get("exit_code") == result.returncode)
    if expected:
        check(label + " standalone failure never claims activation", value.get("status") == "error" and value.get("activated") is False)
    else:
        check(label + " standalone result preserves offline authentication scope", value.get("authenticated") is True and value.get("remote_current") is False)
    return value


matrix_policy = policy_for([recipe_for(1, musl), recipe_for(0, gnu)])
generated, standalone = generate("both-compilers", matrix_policy)
if generated.get("status") == "generated":
    inspected = json.loads(invoke(["bash", standalone, "--inspect"], label="inspect dual compiler installer").stdout)
    check("inspection retains both exact compiler recipes without authentication", inspected.get("authenticated") is False and
          [r.get("target_triple") for r in inspected["policy"]["recipes"]] == [gnu, musl])
    check("inspection identifies the actual embedded installation engine", inspected["engines"]["release_install.sh"] == digest(runtime / "release_install.sh"))
    script_identity = (digest(standalone), standalone.stat().st_ino)
    reordered_policy = copy.deepcopy(matrix_policy)
    reordered_policy["recipes"].reverse()
    for r in reordered_policy["recipes"]:
        r["executables"].reverse()
    regenerated, _ = generate("canonical-variants", reordered_policy, output=standalone)
    check("recipe and executable ordering reuse the identical generated script", regenerated.get("reused") is True and
          (digest(standalone), standalone.stat().st_ino) == script_identity)
    selected_prefix = work / "standalone-prefix"
    generated_install("standalone-ambiguous", standalone, snapshot, selected_prefix, expected=4)
    check("ambiguous compiler selection creates no persistent installation state", not selected_prefix.exists() and not Path(str(selected_prefix) + ".lock").exists())
    for label, selector in (("unknown", cpu + "-unknown-linux-other"), ("empty", ""), ("unsafe", "../gnu"), ("control", "gnu\n")):
        generated_install("standalone-" + label, standalone, snapshot, selected_prefix, ("--target-triple", selector), 4)
        check("unavailable/malformed " + label + " does not choose a fallback", not selected_prefix.exists())
    planned = generated_install("standalone-plan", standalone, snapshot, selected_prefix, ("--target-triple", musl, "--dry-run"))
    check("standalone plan selects musl and activates nothing", planned.get("target_triple") == musl and planned.get("status") == "planned" and not selected_prefix.exists())
    active = generated_install("standalone-gnu", standalone, snapshot, selected_prefix, ("--target-triple", gnu), streamed=True)
    active_id = active.get("generation")
    frozen_state = state(selected_prefix)
    check("streamed installer activates the complete GNU executable set", active.get("target_triple") == gnu and
          {p.name for p in (selected_prefix / "current/bin").iterdir()} == {"app", "alias", "helper"} and
          (selected_prefix / "current/bin/app").read_bytes() == (snapshot / "artifacts/alias-0").read_bytes())
    generated_install("standalone-no-consent", standalone, snapshot, selected_prefix, ("--target-triple", musl), 2)
    check("generated selector cannot bypass replacement consent", state(selected_prefix) == frozen_state)
    switched = generated_install("standalone-musl", standalone, snapshot, selected_prefix, ("--target-triple", musl, "--replace"))
    check("generated installer switches all commands to musl together", switched.get("previous_generation") == active_id and
          all(e.get("target_triple") == musl for e in switched["executables"]) and
          (selected_prefix / "current/bin/app").read_bytes() == (snapshot / "artifacts/alias-1").read_bytes())
    switched_state = state(selected_prefix)
    retry = generated_install("standalone-musl-retry", standalone, snapshot, selected_prefix, ("--target-triple", musl))
    check("identical standalone retry keeps generation and pointer inodes", retry.get("activated") is False and state(selected_prefix) == switched_state)
    rolled = generated_install("standalone-rollback", standalone, snapshot, selected_prefix, ("--target-triple", gnu, "--replace"))
    check("generated rollback reuses retained GNU generation", rolled.get("generation") == active_id and
          (selected_prefix / "generations" / active_id / "bin/helper").stat().st_ino == frozen_state["generations/" + active_id + "/bin/helper"][0])
    # The artifact names deliberately do not encode an ABI. Selected names
    # must still agree with the signed compiler record for every executable.
    contradiction = copy.deepcopy(matrix_policy)
    contradiction["recipes"][1]["executables"][2]["artifact"] = "alias-1"
    bad_result, contradictory_script = generate("mixed-signed-workspace", contradiction)
    if bad_result.get("status") == "generated":
        before = state(selected_prefix)
        generated_install("standalone-mixed-signed", contradictory_script, snapshot, selected_prefix, ("--target-triple", gnu, "--replace"), 4)
        check("valid embedded selector does not authorize differently signed bytes", state(selected_prefix) == before)
    before = state(selected_prefix)
    generated_install("standalone-unselected-corrupt", standalone, broken, selected_prefix, ("--target-triple", gnu, "--replace"), 1)
    check("generated selector cannot narrow complete snapshot authentication", state(selected_prefix) == before)
    for flag in ("--repo", "--sha", "--builder", "--public-key", "--recipe"):
        generated_install("standalone-trust-override-" + flag[2:], standalone, snapshot, selected_prefix,
                          ("--target-triple", gnu, flag, "override"), 4)
    check("runtime compiler selection leaves all fixed trust fields immutable", state(selected_prefix) == before)
    # The actual source/key/policy files are not runtime dependencies. Rename
    # this owned engine directory and key, then run from embedded bytes only.
    runtime.rename(work / "engines-offline")
    public.rename(work / "key-offline.pub")
    try:
        detached = generated_install("standalone-detached", standalone, snapshot, selected_prefix, ("--target-triple", gnu))
        check("standalone offline retry needs no original engine or key file", detached.get("generation") == active_id and state(selected_prefix) == before)
    finally:
        (work / "engines-offline").rename(runtime)
        (work / "key-offline.pub").rename(public)
else:
    print("Dependent dual-compiler installer checks not reached because generation failed", flush=True)

for label, selected_snapshot, selected_recipe in (("legacy-generated", legacy, recipe_for(0)),
                                                 ("singleton-generated", singleton, recipe_for(0, gnu))):
    generated, script = generate(label, policy_for([selected_recipe]))
    if generated.get("status") != "generated":
        continue
    selected_prefix = work / (label + "-prefix")
    installed = generated_install(label + "-default", script, selected_snapshot, selected_prefix)
    check(label + " preserves its fixed singleton policy", installed.get("target_triple") == selected_recipe.get("target_triple"))
    before = state(selected_prefix)
    if "target_triple" not in selected_recipe:
        generated_install("legacy-cannot-invent-compiler", script, selected_snapshot, selected_prefix, ("--target-triple", gnu), 4)
    else:
        generated_install("singleton-cannot-override-compiler", script, selected_snapshot, selected_prefix, ("--target-triple", musl), 4)
    check(label + " rejects overrides without changing active bytes", state(selected_prefix) == before)

for mutation in ("duplicate-compiler", "implicit-and-explicit", "duplicate-implicit", "missing-platform", "foreign-platform",
                 "null-compiler", "unsafe-compiler", "empty-recipes", "too-many-recipes"):
    bad = copy.deepcopy(matrix_policy)
    if mutation == "duplicate-compiler":
        bad["recipes"].append(copy.deepcopy(bad["recipes"][0]))
        bad["recipes"][-1]["executables"][0]["name"] = "another-command"
    elif mutation == "implicit-and-explicit":
        del bad["recipes"][0]["target_triple"]
    elif mutation == "duplicate-implicit":
        bad["recipes"] = [recipe_for(0), recipe_for(1)]
    elif mutation == "missing-platform":
        bad["targets"].append("darwin/arm64")
    elif mutation == "foreign-platform":
        bad["recipes"][0]["target"] = "darwin/arm64"
    elif mutation == "null-compiler":
        bad["recipes"][0]["target_triple"] = None
    elif mutation == "unsafe-compiler":
        bad["recipes"][0]["target_triple"] = "../compiler"
    elif mutation == "empty-recipes":
        bad["recipes"] = []
    else:
        bad["recipes"] = [recipe_for(0, "compiler-%d" % i) for i in range(65)]
    generate("bad-generated-" + mutation, bad, expected=4)
    check(mutation + " leaves no persistent generator lock", not (work / ("bad-generated-" + mutation + "-install.sh.lock")).exists())


# Independent content policy must survive installation, not just a standalone
# verifier call. All recipe-selected GNU files can exist in a signed release
# that silently omitted the musl half. A platform/recipe check alone accepts it.
contract = dict(schema_version=1,
    required_assets=[{k: a[k] for k in ("name", "target", "target_triple", "archive_format")}
                     for a in load(producer)["artifacts"]],
    required_variants=load(producer)["required_variants"])
contract_file = save(work / "install-contract.json", contract)
descriptor = json.loads(invoke(["bash", runtime / "slsa_remote.sh", "describe-contract", "--release-contract", contract_file,
                               "--targets", target], label="installation content contract").stdout)
contract_hash = descriptor["contract_sha256"]
contract_flags = ("--release-contract", str(contract_file))
planned, selected_prefix = install("contract-plan", snapshot, recipe_for(0, gnu), extra=(*contract_flags, "--dry-run"))
check("content-bound plan authenticates without persistent installation state", planned.get("release_contract_sha256") == contract_hash and
      not selected_prefix.exists() and not Path(str(selected_prefix) + ".lock").exists())
active, selected_prefix = install("contract-active", snapshot, recipe_for(0, gnu), extra=contract_flags)
if active.get("status") == "installed":
    contract_id = active["generation"]
    current_state = state(selected_prefix)
    receipt = load(selected_prefix / "generations" / contract_id / "receipt.json")
    check("generation retains the complete independent contract, not the downloaded receipt",
          receipt.get("release_contract") == descriptor["contract"] and receipt.get("release_contract_sha256") == contract_hash)
    check("content policy contributes to generation identity even for identical executable bytes", contract_id != first.get("generation"))
    reordered_contract = copy.deepcopy(contract)
    reordered_contract["required_assets"].reverse()
    reordered_contract["required_variants"].reverse()
    reordered_file = save(work / "contract-reordered.json", reordered_contract)
    again, _ = install("contract-retry", snapshot, recipe_for(0, gnu), selected_prefix,
                       extra=("--release-contract", str(reordered_file)))
    check("semantically identical contract preserves all installation inodes", again.get("generation") == contract_id and state(selected_prefix) == current_state)
    install("contract-drop-no-consent", snapshot, recipe_for(0, gnu), selected_prefix, expected=2)
    check("dropping independent requirements is not an implicit policy update", state(selected_prefix) == current_state)
    weaker = copy.deepcopy(contract)
    weaker.pop("required_variants")
    for asset in weaker["required_assets"]:
        asset.pop("target_triple")
    weaker_file = save(work / "contract-weaker.json", weaker)
    install("contract-change-no-consent", snapshot, recipe_for(0, gnu), selected_prefix, expected=2,
            extra=("--release-contract", str(weaker_file)))
    check("changed contract requires explicit replacement", state(selected_prefix) == current_state)
    replaced, _ = install("contract-change-consented", snapshot, recipe_for(0, gnu), selected_prefix,
                          extra=("--release-contract", str(weaker_file), "--replace"))
    check("explicit policy change selects a new generation and retains the old one",
          replaced.get("generation") != contract_id and replaced.get("previous_generation") == contract_id and
          (selected_prefix / "generations" / contract_id / "receipt.json").is_file())
    rolled, _ = install("contract-policy-rollback", snapshot, recipe_for(0, gnu), selected_prefix, extra=(*contract_flags, "--replace"))
    check("original contract rollback reuses retained generation", rolled.get("generation") == contract_id)

subset = work / "signed-gnu-only"
shutil.copytree(snapshot, subset)
statement = load(subset / "release.intoto.jsonl")
omitted = {a["name"] for a in statement["dsr_evidence"]["artifacts"] if a.get("target_triple") == musl}
statement["subject"] = [s for s in statement["subject"] if s["name"] not in omitted]
statement["dsr_evidence"]["artifacts"] = [a for a in statement["dsr_evidence"]["artifacts"] if a["name"] not in omitted]
retained = work / "omitted-musl-retained"
retained.mkdir()
for name in omitted:
    (subset / "artifacts" / name).rename(retained / name)
save(subset / "release.intoto.jsonl", statement)
sign(subset / "release.intoto.jsonl")
without_contract, _ = install("signed-subset-platform-only", subset, recipe_for(0, gnu))
check("paired platform-only control actually installs the signed GNU subset", without_contract.get("status") == "installed")
rejected, rejected_prefix = install("signed-subset-content-bound", subset, recipe_for(0, gnu), expected=7, extra=contract_flags)
check("missing unselected variant prevents content-bound activation", not rejected_prefix.exists() and not Path(str(rejected_prefix) + ".lock").exists())

for mutation in ("null-contract", "missing-recipe-asset", "recipe-format", "recipe-compiler", "duplicate-json"):
    bad = copy.deepcopy(contract)
    if mutation == "null-contract":
        bad = None
    elif mutation == "missing-recipe-asset":
        bad["required_assets"] = [a for a in bad["required_assets"] if a["name"] != "alias-0"]
    elif mutation == "recipe-format":
        next(a for a in bad["required_assets"] if a["name"] == "alias-0")["archive_format"] = "zip"
    elif mutation == "recipe-compiler":
        next(a for a in bad["required_assets"] if a["name"] == "alias-0")["target_triple"] = musl
    bad_file = save(work / (mutation + ".json"), bad)
    if mutation == "duplicate-json":
        bad_file.write_text('{"schema_version":1,"schema_version":1,"required_assets":[]}\n')
    rejected, p = install("contract-refuses-" + mutation, snapshot, recipe_for(0, gnu), expected=4,
                          extra=("--release-contract", str(bad_file)))
    check(mutation + " stops before installation state", not p.exists())

if fixture:
    mutable = save(work / "install-mutable-contract.json", contract)
    env["DSR_INSTALL_CONTRACT_MUTATE"] = str(mutable)
    try:
        rejected, p = install("contract-input-drift", snapshot, recipe_for(0, gnu), expected=7,
                              extra=("--release-contract", str(mutable)))
        check("original contract drift cannot change the frozen policy or activate", not p.exists())
    finally:
        env.pop("DSR_INSTALL_CONTRACT_MUTATE")

contract_policy = dict(copy.deepcopy(matrix_policy), release_contract=contract)
generation, contract_script = generate("content-bound-generated", contract_policy)
if generation.get("status") == "generated":
    inspected = json.loads(invoke(["bash", contract_script, "--inspect"], label="inspect content-bound installer").stdout)
    check("generated policy embeds the complete normalized independent contract",
          inspected["policy"].get("release_contract") == descriptor["contract"] and inspected.get("authenticated") is False)
    script_identity = (digest(contract_script), contract_script.stat().st_ino)
    canonical_policy = copy.deepcopy(contract_policy)
    canonical_policy["release_contract"]["required_assets"].reverse()
    canonical_policy["release_contract"]["required_variants"].reverse()
    regeneration, _ = generate("contract-order-reuse", canonical_policy, output=contract_script)
    check("contract ordering preserves exact standalone bytes and inode", regeneration.get("reused") is True and
          (digest(contract_script), contract_script.stat().st_ino) == script_identity)
    p = work / "contract-generated-prefix"
    generated_install("generated-contract-subset-refusal", contract_script, subset, p, ("--target-triple", gnu), 7)
    check("generated contract rejects signed missing musl despite selecting GNU", not p.exists())
    installed = generated_install("generated-contract-complete", contract_script, snapshot, p, ("--target-triple", gnu), streamed=True)
    check("direct and streamed generated installation share the same content-bound identity",
          installed.get("generation") == active.get("generation") and installed.get("release_contract_sha256") == contract_hash)
    original = state(p)
    generated_install("generated-contract-override", contract_script, snapshot, p,
                      ("--target-triple", gnu, "--release-contract", str(weaker_file)), 4)
    check("embedded contract is not a runtime override", state(p) == original)
    runtime.rename(work / "contract-engines-offline")
    public.rename(work / "contract-key-offline.pub")
    contract_file.rename(work / "contract-input-offline.json")
    try:
        detached = generated_install("generated-contract-detached", contract_script, snapshot, p, ("--target-triple", gnu))
        check("standalone content policy needs no original contract, key or engine path", detached.get("generation") == installed.get("generation") and state(p) == original)
    finally:
        (work / "contract-engines-offline").rename(runtime)
        (work / "contract-key-offline.pub").rename(public)
        (work / "contract-input-offline.json").rename(contract_file)
    generated_install("generated-contract-byte-refusal", contract_script, broken, p, ("--target-triple", gnu, "--replace"), 1)
    check("content selection retains full payload verification", state(p) == original)

# Exercise online installation with the real fetch/local reauthentication
# pipeline. Only API observation/acquisition use local-file callbacks; every
# document/policy/payload/snapshot operation in slsa_remote remains production.
online_runtime = work / "online-runtime"
shutil.copytree(runtime, online_runtime)
(online_runtime / "sbom_release.sh").write_text('''#!/usr/bin/env bash
# Explicit TEST-ONLY API/transport boundary; not a production online module.
_sbr_require() { :; }
_sbr_run() { "$@"; }
_sbr_context() { cat "$DSR_INSTALL_REMOTE_CASE/context.json"; }
_sbr_inventory() { cat "$DSR_INSTALL_REMOTE_CASE/inventory.json"; }
_sbr_named_asset() { jq -ce --arg n "$2" '[.[]|select(.name==$n)]|if length==1 then .[0] else error("ambiguous asset") end' <<< "$1"; }
_sbr_payload_names() { jq -c '[.[]|select(.name!="release.intoto.jsonl" and .name!="release.intoto.jsonl.minisig")|.name]|sort' <<< "$1"; }
_sbr_asset_digest() { [[ "$(jq -r .digest <<< "$1")" == "sha256:$2" ]]; }
gh_download_release_asset() {
    [[ "$1" == example/app ]] || return 99
    printf 'download:%s\\n' "$2" >> "$DSR_INSTALL_REMOTE_CASE/events"
    cp -- "$DSR_INSTALL_REMOTE_CASE/assets/$2" "$3"
}
_sbr_download() {
    local file="$4/owned-$(jq -r .id <<< "$2")"
    gh_download_release_asset "$1" "$(jq -r .id <<< "$2")" "$file" || return 8
    [[ "$(_slsa_sha256 "$file")" == "$3" ]] || return 7
    printf '%s\\n' "$file"
}
_sbr_inventory_sha256() { printf '%s' "$1" | sha256sum | cut -d ' ' -f 1; }
''')
for label, source_snapshot, expected in (("complete", snapshot, 0), ("subset", subset, 7)):
    remote = work / ("online-" + label)
    (remote / "assets").mkdir(parents=True)
    inventory = []
    sources = [source_snapshot / "release.intoto.jsonl", source_snapshot / "release.intoto.jsonl.minisig",
               *sorted((source_snapshot / "artifacts").iterdir())]
    for asset_id, source in enumerate(sources, 1):
        shutil.copy2(source, remote / "assets" / str(asset_id))
        inventory.append(dict(id=asset_id, name=source.name, size=source.stat().st_size, state="uploaded", digest="sha256:" + digest(source)))
    save(remote / "inventory.json", inventory)
    save(remote / "context.json", dict(repository=dict(id=12, full_name=repo), release=dict(id=34, tag_name=tag, draft=False), tag_commit=pin))
    recipe_file = save(remote / "recipe.json", recipe_for(0, gnu))
    env["DSR_INSTALL_REMOTE_CASE"] = str(remote)
    online_prefix = remote / "prefix"
    response = invoke(["bash", online_runtime / "release_install.sh", "--fetch", "--recipe", recipe_file, "--prefix", online_prefix,
                       "--repo", repo, "--tag", tag, "--sha", pin, "--builder", builder, "--targets", target,
                       "--public-key", public, *contract_flags], expected, "online content-bound " + label)
    result = json.loads(response.stdout)
    if expected == 0:
        check("online fetch and local reauthentication retain the same contract and installation identity",
              result.get("release_contract_sha256") == contract_hash and result.get("generation") == active.get("generation") and
              result.get("download", {}).get("verification", {}).get("release_contract_sha256") == contract_hash)
        check("online content-bound installation acquires every release payload",
              all("download:" + str(i) in (remote / "events").read_text() for i in range(3, len(sources) + 1)))
    else:
        check("online signed subset never acquires payloads or creates installation state",
              not online_prefix.exists() and result.get("activated") is False and
              not any("download:" + str(i) in (remote / "events").read_text() for i in range(3, len(sources) + 1)))
env.pop("DSR_INSTALL_REMOTE_CASE")

for mutation in ("null", "missing-recipe-asset", "wrong-format", "wrong-compiler", "missing-platform"):
    bad = copy.deepcopy(contract_policy)
    if mutation == "null":
        bad["release_contract"] = None
    elif mutation == "missing-recipe-asset":
        bad["release_contract"]["required_assets"] = [a for a in bad["release_contract"]["required_assets"] if a["name"] != "alias-0"]
    elif mutation == "wrong-format":
        next(a for a in bad["release_contract"]["required_assets"] if a["name"] == "alias-0")["archive_format"] = "zip"
    elif mutation == "wrong-compiler":
        next(a for a in bad["release_contract"]["required_assets"] if a["name"] == "alias-0")["target_triple"] = musl
    else:
        bad["targets"].append("darwin/arm64")
    generate("bad-content-policy-" + mutation, bad, expected=4)


save(work / "summary.json", dict(passed=passed, failed=failed, signer="fixture" if fixture else "minisign",
                                  native_compilation=False, offline_engine_stubs=offline_stubs, host=target, root=str(root)))
# Never export a real test signing key along with public validation evidence.
if secret.exists():
    secret.unlink()
print("Results: %d passed, %d failed\nEvidence: %s" % (passed, failed, work), flush=True)
sys.exit(1 if failed else 0)
PY
