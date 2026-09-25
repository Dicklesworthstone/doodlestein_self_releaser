#!/usr/bin/env bash
# Complete remote SLSA fetch, offline reauthentication and generation installer.
# GitHub transport and Minisign are explicit fixtures; no live network/crypto claim.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DSR_SNAPSHOT_FIXTURES_ONLY=true source "$HERE/test_slsa_snapshot.sh"
new_case online-install
INSTALL="$CASE/installation"
mkdir -p "$INSTALL/src"
for module in release_install slsa_remote slsa; do
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

def command(extra=(), dest=prefix, origin=("--fetch",)):
    return ["bash", str(script), *origin, "--recipe", str(recipe), "--prefix", str(dest), *policy, *extra]

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
check("online helper staging is cleaned", not list(case.glob(".dsr-install-*")))
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
