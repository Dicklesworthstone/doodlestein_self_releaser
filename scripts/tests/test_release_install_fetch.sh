#!/usr/bin/env bash
# Complete remote SLSA fetch, offline reauthentication and generation installer.
# GitHub transport and Minisign are explicit fixtures; no live network/crypto claim.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DSR_SNAPSHOT_FIXTURES_ONLY=true source "$HERE/test_slsa_snapshot.sh"
new_case online-install
INSTALL="$CASE/installation"
mkdir -p "$INSTALL/src"
for module in release_install slsa_remote slsa platforms guardrails; do
    cp "$ROOT/src/$module.sh" "$INSTALL/src/" || exit 1
done
# Only the transport module is substituted; both authenticators and the
# installer execute the actual complete production implementation in new CLIs.
{
    printf '%s\n' '#!/usr/bin/env bash' 'CASE=$DSR_ONLINE_CASE; MODE=$(cat "$CASE/mode")'
    declare -f trace _sbr_run _sbr_context _sbr_inventory _sbr_named_asset _sbr_payload_names _sbr_asset_digest _sbr_inventory_sha256 _sbr_download gh_download_release_asset
    cat <<'TRANSPORT'
_sbr_require() {
    trace auth
    [[ "${DSR_GH_TOKEN:-}" == fixture-token && -z "${GH_ENTERPRISE_TOKEN:-}" ]] || return 3
    if [[ "$MODE" == slow ]]; then
        printf '%s\n' "$BASHPID" > "$CASE/slow-pid"
        sleep 120
    fi
}
TRANSPORT
} > "$INSTALL/src/sbom_release.sh"
printf 'normal\n' > "$CASE/mode"
export DSR_ONLINE_CASE="$CASE" DSR_GH_TOKEN=fixture-token GH_ENTERPRISE_TOKEN=must-not-inherit
[[ "${DSR_ONLINE_FIXTURES_ONLY:-false}" != true ]] || return 0
python3 - "$INSTALL" "$CASE" "$PIN" <<'PY'
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

install, case, pin = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
script = install / "src/release_install.sh"
checks = 0
recipe = case / "recipe.json"
recipe.write_text(json.dumps({"schema_version": 1, "target": "linux/amd64", "executables": [
    {"name": "demo", "artifact": "demo-linux"}, {"name": "helper", "artifact": "demo-linux-alias"}]}) + "\n")
prefix = case / "prefix"
policy = ["--repo", "owner/demo", "--tag", "v1.2.3", "--sha", pin, "--builder", "dsr:test",
          "--targets", "linux/amd64,windows/arm64", "--public-key", str(case / "key.pub")]

def check(label, yes):
    global checks
    if not yes:
        raise AssertionError(label)
    checks += 1
    print("PASS " + label, flush=True)

def command(extra=(), dest=prefix, origin=("--fetch",), selected_policy=policy, selected_recipe=recipe):
    return ["bash", str(script), *origin, "--recipe", str(selected_recipe), "--prefix", str(dest), *selected_policy, *extra]

def run(expected=0, **kw):
    p = subprocess.run(command(**kw), capture_output=True, timeout=30)
    (case / "last.stdout").write_bytes(p.stdout)
    (case / "last.stderr").write_bytes(p.stderr)
    if p.returncode != expected:
        raise AssertionError(f"wanted {expected}, got {p.returncode}: {p.stdout!r} {p.stderr!r}")
    result = json.loads(p.stdout)
    check("single typed result matches exit", result["exit_code"] == expected)
    if expected:
        check("failure does not claim activation", result["status"] == "error" and not result["activated"])
    return result

def calls():
    return (case / "calls").read_text().splitlines()

def active():
    p = prefix / "current"
    return (p.lstat().st_ino, os.readlink(p))

def payload_identity(directory):
    return {p.name: (p.stat().st_ino, hashlib.sha256(p.read_bytes()).hexdigest()) for p in directory.iterdir()}

def payload_calls(since):
    return [c for c in calls()[since:] if c in ("download 1", "download 2", "download 3")]

# This suite needs no compiler fixtures: the installer never executes even
# these deliberately non-executable producer byte fixtures.
preview = run(extra=("--dry-run",))
check("online planning authenticates but never creates installation state", preview["status"] == "planned" and not prefix.exists() and not Path(str(prefix) + ".lock").exists())
check("fetch reads every signed platform and alias", [c for c in calls() if c.startswith("download ")] == ["download 4", "download 5", "download 1", "download 2", "download 3"])
check("download observation is not a continuing freshness promise", preview["authenticated"] and not preview["remote_current"] and preview["download"]["verification"]["release"]["draft"] is False)
check("private snapshot paths are not exposed", "snapshot" not in preview["download"])
first = run()
check("network to complete generation requires one invocation", first["status"] == "installed" and first["activated"] and
      {p.name for p in (prefix / "current/bin").iterdir()} == {"demo", "helper"})
identity = active()
again = run()
check("fresh download reuses identical generation and pointer", again["generation"] == first["generation"] and not again["activated"] and active() == identity)
before_parallel = len(calls())
parallel = run(extra=("--download-jobs", "2", "--dry-run"))
check("parallel installation authenticates the same complete release and generation", parallel["status"] == "planned" and
      parallel["authenticated"] and parallel["generation"] == first["generation"] and active() == identity and
      sorted(c for c in calls()[before_parallel:] if c.startswith("download ")) ==
      ["download 1", "download 2", "download 3", "download 4", "download 5"])
check("online helper staging is cleaned", not list(case.glob(".dsr-install-*")))
# Persistent acquisition must use the actual resumable verifier. An interrupted
# full release never becomes a partial successful installation, and a retry
# must preserve the complete signed payloads already retained on disk.
cache = case / "download cache"
cache_flags = ("--download-cache", str(cache))
(case / "mode").write_text("late-failure\n")
run(8, extra=(*cache_flags, "--dry-run"), dest=case / "initial-cache-plan")
retained = Path(str(cache) + ".partial") / "artifacts"
kept = payload_identity(retained)
check("late online failure retains only complete authenticated payloads", set(kept) == {"demo-linux", "demo-linux-alias"} and
      not cache.exists() and not (case / "initial-cache-plan").exists() and
      not (case / "initial-cache-plan.lock").exists() and active() == identity)
(case / "mode").write_text("normal\n")
before_resume = len(calls())
resumed = run(extra=(*cache_flags, "--download-jobs", "2"))
check("installer retry downloads only missing payload and retains existing inodes", payload_calls(before_resume) == ["download 3"] and
      all(payload_identity(retained)[name] == saved for name, saved in kept.items()))
check("cache and scheduling do not change generation identity", resumed["generation"] == first["generation"] and
      not resumed["activated"] and active() == identity and resumed["download"]["cache"] == str(cache) and
      resumed["download"]["resumable"] and
      resumed["download"]["acquisition"] == dict(reused_payloads=2, downloaded_payloads=1))
complete = payload_identity(cache / "artifacts")
historical = (cache / "download.json").read_bytes()
before_resume = len(calls())
cached = run(extra=(*cache_flags, "--dry-run"), dest=case / "cache-preview")
check("completed cache retry reauthenticates current proof without redownloading payloads", not payload_calls(before_resume) and
      [c for c in calls()[before_resume:] if c.startswith("download ")] == ["download 4", "download 5"] and
      cached["download"]["acquisition"] == dict(reused_payloads=3, downloaded_payloads=0))
check("cached planning preserves snapshot and creates no installation state", cached["status"] == "planned" and
      cached["generation"] == first["generation"] and not (case / "cache-preview").exists() and
      not (case / "cache-preview.lock").exists() and payload_identity(cache / "artifacts") == complete and
      (cache / "download.json").read_bytes() == historical)
# Adding an independently correct pin still changes the frozen selection. A
# different key comment leaves cryptographic verification valid, but changes
# the exact key bytes bound by the existing checkpoint contract.
before_refusals = len(calls())
run(7, extra=(*cache_flags, "--statement-sha256", hashlib.sha256((case / "remote/4").read_bytes()).hexdigest()))
key_bytes = (case / "key.pub").read_bytes()
(case / "key.pub").write_bytes(key_bytes + b"different local key comment\n")
run(7, extra=cache_flags)
(case / "key.pub").write_bytes(key_bytes)
inventory_bytes = (case / "inventory.json").read_bytes()
inventory = json.loads(inventory_bytes)
inventory[0]["id"] += 100
(case / "inventory.json").write_text(json.dumps(inventory))
run(7, extra=cache_flags)
(case / "inventory.json").write_bytes(inventory_bytes)
check("cache selection key and inventory drift cannot trigger payload replacement", not payload_calls(before_refusals) and
      payload_identity(cache / "artifacts") == complete and active() == identity)
damaged = cache / "artifacts/demo-windows.exe"
intact = damaged.read_bytes()
damaged.chmod(0o600)
damaged.write_bytes(intact + b"corrupt")
before_corruption = len(calls())
run(1, extra=cache_flags)
check("unused cached platform corruption is refused before networking and is never repaired", len(calls()) == before_corruption and
      damaged.read_bytes() == intact + b"corrupt" and active() == identity)
damaged.write_bytes(intact)
damaged.chmod(0o400)
# A completed cache remains online policy, never a silent fallback after an
# unavailable release. Explicit offline use still authenticates its bytes.
(case / "mode").write_text("network-failure\n")
run(8, extra=cache_flags)
before_offline_cache = len(calls())
from_cache = run(origin=("--snapshot", str(cache)))
check("explicit snapshot mode can install cached bytes without any remote calls", len(calls()) == before_offline_cache and
      from_cache["generation"] == first["generation"] and "download" not in from_cache)
(case / "mode").write_text("normal\n")
# All persistent cache names must be disjoint from installation state and
# policy inputs before any network request or cache lock is created.
before_paths = len(calls())
for cache_path, selected_prefix in ((prefix, prefix), (case, prefix), (prefix / "cache", prefix),
                                    (case / "overlap", case / "overlap.partial"),
                                    (case / "overlap", case / "overlap.lock"),
                                    (Path(str(prefix) + ".lock"), prefix), (recipe, prefix)):
    run(4, extra=("--download-cache", str(cache_path)), dest=selected_prefix)
protected_key = case / "selected.lock"
protected_key.write_bytes(key_bytes)
key_policy = list(policy)
key_policy[key_policy.index("--public-key") + 1] = str(protected_key)
run(4, extra=("--download-cache", str(case / "selected")), selected_policy=key_policy)
partial_input = case / "protected.partial"
partial_input.mkdir()
partial_recipe = partial_input / "recipe.json"
partial_recipe.write_bytes(recipe.read_bytes())
run(4, extra=("--download-cache", str(case / "protected")), selected_recipe=partial_recipe)
run(4, extra=("--download-cache", "relative-cache"))
run(4, extra=(*cache_flags, *cache_flags))
run(4, origin=("--snapshot", str(cache)), extra=cache_flags)
(case / "linked.partial").symlink_to(retained.parent, target_is_directory=True)
run(7, extra=("--download-cache", str(case / "linked")))
check("invalid cache namespaces have no network or installation side effects", len(calls()) == before_paths and
      protected_key.read_bytes() == key_bytes and partial_recipe.read_bytes() == recipe.read_bytes() and
      not (case / "overlap.lock").exists() and not (case / "protected.lock").exists() and active() == identity)
# Exercise real installer cancellation after two checkpoint commits, with a
# second CLI attempting the same destination while its transfer is blocked.
cancel_cache = case / "cancel-cache"
cancel_flags = ("--download-cache", str(cancel_cache))
(case / "mode").write_text("blocked-body\n")
process = subprocess.Popen(command(extra=cancel_flags), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    until = time.monotonic() + 10
    while time.monotonic() < until and not (case / "body-blocked").exists() and process.poll() is None:
        time.sleep(.025)
    check("cached installer reaches an actual incomplete transfer", (case / "body-blocked").exists())
    cancelled_payloads = Path(str(cancel_cache) + ".partial") / "artifacts"
    cancelled_kept = payload_identity(cancelled_payloads)
    check("only complete payloads are retained before cancellation", set(cancelled_kept) == {"demo-linux", "demo-linux-alias"})
    before_competitor = len(calls())
    run(2, extra=cancel_flags)
    check("competing cached installer fails before remote acquisition", len(calls()) == before_competitor)
    process.send_signal(signal.SIGTERM)
    out, err = process.communicate(timeout=10)
    check("cached cancellation reports its actual unactivated interrupted state", process.returncode == 5 and
          json.loads(out)["exit_code"] == 5 and not json.loads(out)["activated"] and not cancel_cache.exists())
    with Path(str(cancel_cache) + ".lock").open("rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        check("owned transfer releases cache custody before installer returns", payload_identity(cancelled_payloads) == cancelled_kept)
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
(case / "mode").write_text("normal\n")
before_resume = len(calls())
after_cancel = run(extra=cancel_flags)
check("cancelled installer reuses retained payloads on retry", payload_calls(before_resume) == ["download 3"] and
      after_cancel["download"]["acquisition"] == dict(reused_payloads=2, downloaded_payloads=1) and active() == identity)
# Make a separately retained snapshot through the actual SLSA CLI, not a fake
# downloaded directory. Offline and online must select the same generation.
snapshot = case / "snapshot"
p = subprocess.run(["bash", str(install / "src/slsa_remote.sh"), "fetch-release", "--output-dir", str(snapshot), *policy],
                   env={k: v for k, v in os.environ.items() if k != "GH_ENTERPRISE_TOKEN"}, capture_output=True, timeout=20)
check("standalone fetch produces a reusable copy", p.returncode == 0)
(case / "mode").write_text("network-failure\n")
before = calls()
offline = run(origin=("--snapshot", str(snapshot)))
check("offline mode performs no remote operations", calls() == before)
check("online and offline trust the same generation identity", offline["generation"] == first["generation"] and "download" not in offline and active() == identity)
# Policies and target checks cannot be bypassed before doing any network work.
run(4, origin=("--snapshot", str(snapshot)), extra=("--allow-draft",))
for jobs in ("0", "33", "-1", "many"):
    run(4, extra=("--download-jobs", jobs))
run(4, extra=("--download-jobs", "2", "--download-jobs", "3"))
run(4, origin=("--snapshot", str(snapshot)), extra=("--download-jobs", "1"))
run(4, extra=("--snapshot", str(snapshot)))
original_recipe = recipe.read_bytes()
value = json.loads(original_recipe)
value["target"] = "darwin/arm64"
recipe.write_text(json.dumps(value))
run(4)
check("wrong host and conflicting origins are rejected before networking", calls() == before)
recipe.write_bytes(original_recipe)
for mode, code in (("network-failure", 8), ("interrupted", 5), ("corrupt-body", 7), ("changed-tag", 7)):
    original_context = (case / "context.json").read_bytes()
    (case / "mode").write_text(mode + "\n")
    run(code)
    check(mode + " preserves the active generation", active() == identity)
    (case / "context.json").write_bytes(original_context)
# Fetch may read a draft, but installation needs additional explicit consent.
(case / "mode").write_text("normal\n")
value = json.loads((case / "context.json").read_text())
value["release"]["draft"] = True
(case / "context.json").write_text(json.dumps(value))
run(4)
check("authenticated draft is not silently installed", active() == identity)
draft = run(extra=("--allow-draft",))
check("explicit draft policy retains truthful download evidence", draft["download"]["verification"]["release"]["draft"] and active() == identity)
value["release"]["draft"] = False
(case / "context.json").write_text(json.dumps(value))
# A correct receipt cannot substitute for the downloaded proof itself.
proof = case / "remote/5"
original_signature = proof.read_bytes()
proof.write_bytes(b"forged\n")
run(7)
check("bad proof never switches an existing executable set", active() == identity)
proof.write_bytes(original_signature)
# The outer installer owns the full fetch helper session, not just verification.
(case / "mode").write_text("slow\n")
run(5, extra=("--timeout", "1"))
check("network timeout leaves installation unchanged", active() == identity)
(case / "slow-pid").rename(case / "timeout-pid")
p = subprocess.Popen(command(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    until = time.monotonic() + 10
    while time.monotonic() < until and not (case / "slow-pid").exists() and p.poll() is None:
        time.sleep(.05)
    check("online operation reached cancellation boundary", (case / "slow-pid").exists())
    p.send_signal(signal.SIGTERM)
    out, err = p.communicate(timeout=8)
    check("public CLI cancellation reports interrupted error", p.returncode == 5 and json.loads(out)["exit_code"] == 5)
    check("cancellation preserves active installation", active() == identity)
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
for marker in ("slow-pid", "timeout-pid"):
    pid = int((case / marker).read_text())
    path = Path(f"/proc/{pid}/stat")
    check("owned network helper is stopped", not path.exists() or path.read_text().split(") ", 1)[1].split()[0] == "Z")
(case / "mode").write_text("normal\n")
run()
check("cancelled online install remains retryable", active() == identity)
print("\nOnline release installation: %d passed" % checks, flush=True)
PY
