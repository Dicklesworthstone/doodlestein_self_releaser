#!/usr/bin/env bash
# Actual public CLI, generator, signed snapshot admission and atomic activation.
# Real Minisign signs private inert payload fixtures; no network or compiler.
# Cancellation fixtures delay only verifier execution or completed result delivery.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for dependency in python3 jq minisign bash tar; do
    command -v "$dependency" >/dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; exit 3; }
done
python3 - "$ROOT" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

root = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix="dsr-installer-cli-"))
print("Retained evidence: " + str(work), flush=True)
passed = calls = 0
schema = json.loads((root / "schemas/envelope.json").read_text())
try:
    from jsonschema import Draft202012Validator, FormatChecker
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
except ImportError:
    validator = None
    print("SKIP: Python jsonschema unavailable; envelope structure and exit agreement still checked", flush=True)

machine = platform.machine().lower()
operating_system = platform.system()
if operating_system not in ("Linux", "Darwin", "FreeBSD") or machine not in ("x86_64", "amd64", "aarch64", "arm64"):
    raise SystemExit("Requires a supported native POSIX AMD64/ARM64 test host")
arch = "amd64" if machine in ("x86_64", "amd64") else "arm64"
os_name = {"Linux": "linux", "Darwin": "darwin", "FreeBSD": "freebsd"}[operating_system]
if os_name == "freebsd" and arch != "amd64":
    raise SystemExit("FreeBSD fixture requires amd64")
target = os_name + "/" + arch
cpu = "x86_64" if arch == "amd64" else "aarch64"
triple = cpu + {"linux": "-unknown-linux-gnu", "darwin": "-apple-darwin", "freebsd": "-unknown-freebsd"}[os_name]
foreign_target = "windows/arm64"
targets = [target, foreign_target]
pin, repository, tag, builder = "1" * 40, "example/app", "v1.2.3", "dsr:public-installer-test"
public, secret = work / "trusted.pub", work / "test-only.key"
other_public, other_secret = work / "other.pub", work / "other-test-only.key"
real_minisign, real_python = shutil.which("minisign"), sys.executable
for key, private in ((public, secret), (other_public, other_secret)):
    subprocess.run([real_minisign, "-G", "-W", "-p", str(key), "-s", str(private)],
                   check=True, capture_output=True, timeout=30)
print("Signer mode: real Minisign; payloads are inert owned scripts, never executed", flush=True)
bin_dir, temporary, outputs = work / "bin", work / "tmp", work / "outputs"
for directory in (bin_dir, temporary, outputs):
    directory.mkdir()
env = {key: value for key, value in os.environ.items()
       if not key.startswith("BASH_FUNC_") and key not in ("BASH_ENV", "ENV")}
env.update(PATH=str(bin_dir) + ":" + env["PATH"], TMPDIR=str(temporary), NO_COLOR="1",
           DSR_STATE_DIR=str(work / "state"), DSR_CACHE_DIR=str(work / "cache"), DSR_CONFIG_DIR=str(work / "config"))
for name in ("gh", "curl", "wget"):
    command = bin_dir / name
    command.write_text("#!/bin/sh\nprintf 'unexpected network access\\n' >&2\nexit 99\n")
    command.chmod(0o755)


def check(label, condition):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print("PASS " + label, flush=True)


def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True) + "\n")
    return path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect_tree(path, include_root=False):
    if not path.exists():
        return None
    result = {}
    if include_root:
        info = path.stat()
        result["."] = (info.st_ino, info.st_mode, info.st_nlink, info.st_mtime_ns, info.st_ctime_ns)
    for directory, names, files in os.walk(path, followlinks=False):
        for name in names + files:
            file = Path(directory) / name
            info = file.lstat()
            contents = os.readlink(file) if stat.S_ISLNK(info.st_mode) else digest(file) if stat.S_ISREG(info.st_mode) else None
            result[str(file.relative_to(path))] = (info.st_ino, info.st_mode, info.st_nlink, contents)
    return result


def record(result, expected, label, action=None):
    global calls
    calls += 1
    (work / ("%03d.stdout" % calls)).write_bytes(result.stdout)
    (work / ("%03d.stderr" % calls)).write_bytes(result.stderr)
    if result.returncode != expected:
        raise AssertionError(label + " expected exit %d, got %d: %r %r" %
                             (expected, result.returncode, result.stdout, result.stderr))
    value = json.loads(result.stdout)
    check(label + " returns one envelope matching the process exit",
          isinstance(value, dict) and value.get("command") == "installer" and value.get("exit_code") == expected and
          value.get("status") == ("error" if expected else "success") and
          (action is None or value.get("details", {}).get("action") == action))
    if validator is not None:
        validator.validate(value)
        check(label + " follows the public envelope schema", True)
    return value["details"]


def invoke(action, arguments=(), expected=0, prefix=(), label=None, selected_env=None):
    command = ["bash", str(root / "dsr"), "--json", *prefix, "installer", action, *map(str, arguments)]
    result = subprocess.run(command, env=selected_env or env, capture_output=True, timeout=45)
    return record(result, expected, label or action, action)


def snapshot(label, generation):
    base = work / label
    assets = base / "snapshot/artifacts"
    payload = base / "payload"
    assets.mkdir(parents=True)
    (payload / "docs").mkdir(parents=True)
    for name in ("app", "helper"):
        (payload / name).write_text("#!/bin/sh\n# Inert authenticated fixture, not a compiled application.\n" +
                                   "printf 'unexpected execution\\n' >> " + shlex.quote(str(work / "executed-payload")) + "\nexit 93\n")
        (payload / name).chmod(0o755)
    (payload / "docs/help.txt").write_text("Owned application documentation\n")
    (payload / "docs/EMPTY").write_bytes(b"")
    archive = assets / "app.tar.gz"
    with tarfile.open(archive, "w:gz") as stream:
        for name in ("app", "helper", "docs/help.txt", "docs/EMPTY"):
            stream.add(payload / name, arcname=name, recursive=False)
    save(assets / "runtime.json", dict(generation=generation))
    (assets / "unused.txt").write_text("Unselected but authenticated subject\n")
    save(assets / "foreign.json", dict(platform=foreign_target))
    rows = []
    for name, owner, format_name, compiler in (
            ("app.tar.gz", target, "tar.gz", triple), ("runtime.json", "additional", "none", None),
            ("unused.txt", "additional", "none", None), ("foreign.json", foreign_target, "none", "aarch64-pc-windows-msvc")):
        file = assets / name
        item = dict(name=name, target=owner, archive_format=format_name, sha256=digest(file), size_bytes=file.stat().st_size)
        if compiler is not None:
            item["target_triple"] = compiler
        rows.append(item)
    environments = [dict(target=target, target_triple=triple, method="native", host="private-fixture"),
                    dict(target=foreign_target, target_triple="aarch64-pc-windows-msvc", method="native", host="private-fixture")]
    manifest = dict(schema_version="1.0.0", tool="app", version=tag,
                    source=dict(git_sha=pin, git_ref="refs/tags/" + tag, dependencies=[]),
                    run_id="12345678-1234-4123-8123-123456789abc", built_at="2026-10-10T01:02:03Z", status="success",
                    requested_targets=targets, required_variants=[dict(target=e["target"], target_triple=e["target_triple"]) for e in environments],
                    summary=dict(total=2, success=2, failed=0), build_environments=environments, artifacts=rows)
    producer = save(base / "producer.json", manifest)
    proof = assets.parent / "release.intoto.jsonl"
    result = subprocess.run(["bash", str(root / "src/slsa.sh"), "generate-manifest", str(producer), str(assets),
                             "--repository", repository, "--builder", builder, "--output", str(proof)],
                            env=env, capture_output=True, timeout=30)
    check(label + " maps a real complete manifest", result.returncode == 0)
    subprocess.run([real_minisign, "-S", "-s", str(secret), "-m", str(proof), "-x", str(proof) + ".minisig",
                    "-t", "private public-installer CLI fixture"], check=True, capture_output=True, timeout=30)
    save(assets.parent / "download.json", dict(fixture=True, authenticated=False, note="Not a source of installation trust"))
    return assets.parent


first = snapshot("first", 1)
second = snapshot("second", 2)
recipe = dict(schema_version=1, target=target, target_triple=triple, executables=[
    dict(name="app", artifact="app.tar.gz", member="app"), dict(name="helper", artifact="app.tar.gz", member="helper")],
    files=[dict(path="share/app/runtime.json", artifact="runtime.json"),
           dict(path="share/app/help.txt", artifact="app.tar.gz", member="docs/help.txt"),
           dict(path="share/app/EMPTY", artifact="app.tar.gz", member="docs/EMPTY")])
recipe_file = save(work / "recipe.json", recipe)
policy = dict(schema_version=1, repo=repository, tag=tag, source_sha=pin, builder=builder,
              targets=targets, recipes=[recipe])
policy_file = save(work / "policy.json", policy)
script = outputs / "install.sh"
generate_args = ["--policy", policy_file, "--public-key", public, "--output", script]
prefix = work / "managed prefix"


def install_args(source=first, destination=prefix, selected=recipe_file, key=public):
    return ["--snapshot", source, "--recipe", selected, "--prefix", destination, "--repo", repository,
            "--tag", tag, "--sha", pin, "--builder", builder, "--targets", ",".join(targets), "--public-key", key]


for action in ("generate-release", "install", "describe-recipe"):
    help_result = invoke(action, ["--help"], prefix=["--dry-run"], label=action + " help")
    check(action + " help is data without an authentication claim", "usage:" in help_result["help"] and "authenticated" not in help_result)

described = invoke("describe-recipe", ["--recipe", recipe_file], label="recipe preflight")
check("public recipe inspection retains normalized compiler and data selectors",
      described["authenticated"] is False and described["recipe"]["target_triple"] == triple and
      len(described["recipe"]["files"]) == 3)
output_state = inspect_tree(outputs, include_root=True)
planned = invoke("generate-release", generate_args, prefix=["--dry-run"], label="global generator dry-run")
check("generator dry-run validates its complete bundle without output or lock changes",
      planned["status"] == "planned" and planned["dry_run"] is True and planned["authenticated"] is False and
      len(planned["engines"]) == 8 and not planned["reused"] and inspect_tree(outputs, include_root=True) == output_state)
bad_policy = copy.deepcopy(policy)
bad_policy["recipes"][0]["files"][0]["path"] = "bin/runtime.json"
bad_policy_file = save(work / "bad-policy.json", bad_policy)
invoke("generate-release", ["--policy", bad_policy_file, "--public-key", public, "--output", script, "--dry-run"],
       expected=4, label="dry-run rejects unsafe recipe")
invalid_key = work / "invalid.pub"
invalid_key.write_text("not a public key\n")
invoke("generate-release", ["--policy", policy_file, "--public-key", invalid_key, "--output", script, "--dry-run"],
       expected=4, label="dry-run rejects invalid trust key")
invoke("generate-release", [*generate_args, "--output", outputs / "duplicate.sh", "--dry-run"],
       expected=4, label="duplicate generator option")
check("failed plans cannot create output or adjacent lock", inspect_tree(outputs, include_root=True) == output_state)
generated = invoke("generate-release", generate_args, label="public generation")
check("planned and actually published bytes agree",
      generated["sha256"] == planned["sha256"] == digest(script) and generated["policy_sha256"] == planned["policy_sha256"] and
      generated["status"] == "generated" and generated["authenticated"] is False and stat.S_IMODE(script.stat().st_mode) == 0o755)
inspection = subprocess.run(["bash", str(script), "--inspect"], env=env, capture_output=True, timeout=30)
check("publicly generated standalone installer inspects its embedded reviewed policy",
      inspection.returncode == 0 and json.loads(inspection.stdout)["policy"]["recipes"][0] == described["recipe"])
output_state = inspect_tree(outputs)
reused = invoke("generate-release", generate_args, label="identical generator retry")
check("identical public generation preserves output and lock identities", reused["reused"] and inspect_tree(outputs) == output_state)
planned_output_state = inspect_tree(outputs, include_root=True)
again = invoke("generate-release", [*generate_args, "--dry-run"], label="existing output dry-run")
check("existing-output plan reports reuse without any namespace changes", again["reused"] and inspect_tree(outputs, include_root=True) == planned_output_state)
different = copy.deepcopy(policy)
different["builder"] += ":next"
different_file = save(work / "different-policy.json", different)
changed_args = ["--policy", different_file, "--public-key", public, "--output", script]
invoke("generate-release", [*changed_args, "--dry-run"], expected=2, label="dry-run preserves replacement gate")
replacement_plan = invoke("generate-release", [*changed_args, "--dry-run", "--replace"], label="explicit replacement plan")
check("replacement preview is truthful and leaves existing installer untouched",
      not replacement_plan["reused"] and replacement_plan["sha256"] != digest(script) and
      inspect_tree(outputs, include_root=True) == planned_output_state)

planned_install = invoke("install", install_args(), prefix=["--dry-run"], label="global installation dry-run")
check("installation plan authenticates every subject and selects executable plus data bytes",
      planned_install["status"] == "planned" and planned_install["authenticated"] is True and
      planned_install["target_triple"] == triple and len(planned_install["files"]) == 3 and not prefix.exists())
installed = invoke("install", install_args(), label="public authenticated installation")
check("public activation uses one complete executable and data generation",
      installed["activated"] is True and installed["authenticated"] is True and
      (prefix / "current/bin/app").read_bytes() == (work / "first/payload/app").read_bytes() and
      json.loads((prefix / "current/share/app/runtime.json").read_text()) == {"generation": 1} and
      (prefix / "current/share/app/EMPTY").stat().st_size == 0 and
      stat.S_IMODE((prefix / "current/share/app/runtime.json").stat().st_mode) == 0o644)
installed_state = inspect_tree(prefix)
retry = invoke("install", install_args(), label="same generation retry")
check("same-generation retry preserves complete installed identity", retry["activated"] is False and inspect_tree(prefix) == installed_state)
invoke("install", install_args(source=second), expected=2, label="replacement requires consent")
check("refused replacement preserves prior installed family", inspect_tree(prefix) == installed_state)
changed = invoke("install", [*install_args(source=second), "--replace"], label="complete generation upgrade")
check("explicit replacement switches runtime data with the executable family",
      changed["activated"] is True and json.loads((prefix / "current/share/app/runtime.json").read_text()) == {"generation": 2})
rolled = invoke("install", [*install_args(), "--replace"], label="reauthenticated rollback")
check("rollback reselects the original complete generation", rolled["generation"] == installed["generation"] and
      json.loads((prefix / "current/share/app/runtime.json").read_text()) == {"generation": 1})
installed_state = inspect_tree(prefix)

invoke("install", [*install_args(source=second, key=other_public), "--replace"], expected=1, label="wrong signer")
for label, expected, mutate in (
        ("selected subject drift", 1, lambda p: (p / "artifacts/runtime.json").write_text('{"changed":true}\n')),
        ("unselected subject drift", 1, lambda p: (p / "artifacts/unused.txt").write_text("changed\n")),
        ("missing signed subject", 7, lambda p: (p / "artifacts/unused.txt").rename(work / "held-unused.txt"))):
    source = work / label.replace(" ", "-")
    shutil.copytree(first, source)
    mutate(source)
    invoke("install", [*install_args(source=source), "--replace"], expected=expected, label=label)
foreign_recipe = copy.deepcopy(recipe)
foreign_recipe["files"][0]["artifact"] = "foreign.json"
foreign_file = save(work / "foreign-recipe.json", foreign_recipe)
invoke("install", [*install_args(selected=foreign_file), "--replace"], expected=4, label="foreign data owner")
wrong_variant = copy.deepcopy(recipe)
wrong_variant["target_triple"] = cpu + "-unknown-linux-musl" if os_name == "linux" else triple + "-other"
wrong_variant_file = save(work / "wrong-variant.json", wrong_variant)
invoke("install", [*install_args(selected=wrong_variant_file), "--replace"], expected=4, label="unavailable compiler variant")
invoke("install", [*install_args(), "--public-key", public], expected=4, label="duplicate installer option")
invoke("install", [*install_args(), "--allow-source-build"], expected=4, label="source fallback cannot enter authenticated route")
check("all rejected selections preserve the previous complete installation", inspect_tree(prefix) == installed_state)

# Delay the real verifier at its subprocess boundary, with an owned descendant.
# Public-PID cancellation must stop that group and wait for the real engine's
# error receipt; no production validator or installation code is substituted.
verifier = bin_dir / "minisign"
verifier.write_text("#!" + real_python + "\n" + '''
import json, os, pathlib, subprocess, sys, time
if os.environ.get("DSR_CLI_BLOCK_VERIFIER") and "-V" in sys.argv:
    root = pathlib.Path(os.environ["DSR_CLI_BLOCK_VERIFIER"])
    child = subprocess.Popen([sys.executable, "-c", "import pathlib,time; time.sleep(4); pathlib.Path(" + repr(str(root / "late-write")) + ").write_text('unexpected')"])
    (root / "ready").write_text(json.dumps(dict(pid=os.getpid(), child=child.pid)))
    time.sleep(30)
os.execv(os.environ["DSR_CLI_REAL_MINISIGN"], [os.environ["DSR_CLI_REAL_MINISIGN"], *sys.argv[1:]])
''')
verifier.chmod(0o755)
cancel_dir = work / "cancel-before-activation"
cancel_dir.mkdir()
blocked_env = dict(env, DSR_CLI_BLOCK_VERIFIER=str(cancel_dir), DSR_CLI_REAL_MINISIGN=real_minisign)
command = ["bash", str(root / "dsr"), "--json", "installer", "install", *map(str, install_args(source=second)), "--replace"]
process = subprocess.Popen(command, env=blocked_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
deadline = time.monotonic() + 20
while not (cancel_dir / "ready").exists() and process.poll() is None and time.monotonic() < deadline:
    time.sleep(0.02)
check("cancellation reaches the real installation verifier", (cancel_dir / "ready").exists())
process.send_signal(signal.SIGTERM)
stdout, stderr = process.communicate(timeout=15)
cancelled = record(subprocess.CompletedProcess(command, process.returncode, stdout, stderr), 5, "public-PID cancellation", "install")
check("cancellation preserves the engine's actual unactivated state",
      cancelled["status"] == "error" and cancelled["activated"] is False and inspect_tree(prefix) == installed_state)
time.sleep(4.2)
check("cancelled verification cannot leave a writing descendant", not (cancel_dir / "late-write").exists())

# Hold only delivery of an already-completed genuine engine receipt. This
# deterministic boundary proves that a late TERM to dsr cannot rewrite a real
# committed activated:true result as a failed or unactivated installation.
interpreter = bin_dir / "python3"
interpreter.write_text("#!" + real_python + "\n" + '''
import os, pathlib, signal, subprocess, sys, time
real = os.environ["DSR_CLI_REAL_PYTHON"]
if os.environ.get("DSR_CLI_HOLD_RESULT") and len(sys.argv) > 3 and sys.argv[1] == "-" and "--prefix" in sys.argv:
    result = subprocess.run([real, *sys.argv[1:]], input=sys.stdin.buffer.read(), capture_output=True)
    released = False
    def release(signum, frame):
        global released
        released = True
    signal.signal(signal.SIGTERM, release)
    pathlib.Path(os.environ["DSR_CLI_HOLD_RESULT"]).write_bytes(result.stdout)
    deadline = time.monotonic() + 20
    while not released and time.monotonic() < deadline:
        time.sleep(0.01)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    sys.exit(result.returncode)
os.execv(real, [real, *sys.argv[1:]])
''')
interpreter.chmod(0o755)
delivered = work / "completed-engine-result.json"
delivery_env = dict(env, DSR_CLI_HOLD_RESULT=str(delivered), DSR_CLI_REAL_PYTHON=real_python, DSR_CLI_REAL_MINISIGN=real_minisign)
process = subprocess.Popen(command, env=delivery_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
deadline = time.monotonic() + 25
while not delivered.exists() and process.poll() is None and time.monotonic() < deadline:
    time.sleep(0.02)
check("late-cancellation boundary holds an actual committed engine result", delivered.exists() and
      json.loads(delivered.read_text()).get("activated") is True and
      json.loads((prefix / "current/share/app/runtime.json").read_text()) == {"generation": 2})
process.send_signal(signal.SIGTERM)
stdout, stderr = process.communicate(timeout=15)
completed = record(subprocess.CompletedProcess(command, process.returncode, stdout, stderr), 0,
                   "public-PID signal after activation", "install")
engine_result = json.loads(delivered.read_text())
check("completed activation receipt survives late cancellation unchanged",
      {key: value for key, value in completed.items() if key != "action"} == engine_result and completed["activated"] is True)

legacy = invoke("generate", ["owned-fixture", "--output-dir", outputs, "--dry-run"], label="legacy generation plan")
check("legacy generation remains a registry-based installer plan",
      legacy["action"] == "generate" and legacy["dry_run"] is True and legacy["installers"][0]["tool"] == "owned-fixture")
check("legacy dry-run does not publish an ordinary installer", not (outputs / "owned-fixture").exists())
check("test never executed an installed fixture", not (work / "executed-payload").exists())
print("Public authenticated installer CLI: %d/%d passed" % (passed, passed), flush=True)
PY
