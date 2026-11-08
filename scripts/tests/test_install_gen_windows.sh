#!/usr/bin/env bash
# Real generated PowerShell runtime, ZIP/PE, Minisign, cache and transaction
# regressions. Linux adapts only native host detection and HTTP acquisition;
# no fixture claims native Windows ACL/NTFS or live GitHub qualification.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
for dependency in pwsh minisign go python3 jq yq; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'SKIP: Windows installer runtime tests require %s\n' "$dependency"
        exit 0
    fi
done

python3 - "$PROJECT_ROOT" <<'PY'
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

project = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix="dsr-windows-installer-", dir=os.environ.get("TMPDIR"))).resolve()
os.chmod(root, 0o700)
print(f"Windows installer fixture evidence: {root}", flush=True)
env = os.environ.copy()
for key, value in {
    "DSR_CONFIG_DIR": root / "config", "DSR_STATE_DIR": root / "state",
    "DSR_CACHE_DIR": root / "dsr-cache", "DSR_INSTALLER_DIR": root / "generated",
    "XDG_CONFIG_HOME": root / "xdg-config", "XDG_CACHE_HOME": root / "xdg-cache",
    "XDG_STATE_HOME": root / "xdg-state", "CI": "1", "GOTOOLCHAIN": "local",
}.items():
    env[key] = str(value)
for key in ("DSR_GH_TOKEN", "GITHUB_TOKEN", "GH_TOKEN", "DSR_REPOS_FILE"):
    env.pop(key, None)
(root / "config/repos.d").mkdir(parents=True)
(root / "go-fixture").mkdir()
(root / "go-fixture/main.go").write_text('package main\nimport "fmt"\nvar role = "app"\nfunc main() { fmt.Println(role) }\n')

passed = 0
failed = 0

def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"PASS: {name}", flush=True)
    else:
        failed += 1
        print(f"FAIL: {name}: {detail}", flush=True)

def command(args, label, *, extra=None, cwd=None, timeout=120):
    selected = env.copy()
    selected.update(extra or {})
    result = subprocess.run([str(arg) for arg in args], cwd=cwd or project, env=selected,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    (root / (label + ".stdout")).write_bytes(result.stdout)
    (root / (label + ".stderr")).write_bytes(result.stderr)
    return result

for binary in ("app", "worker"):
    built = command(["go", "build", "-trimpath", "-ldflags", "-X main.role=" + binary,
                     "-o", root / (binary + ".exe"), root / "go-fixture/main.go"],
                    "build-" + binary, extra={"GOOS": "windows", "GOARCH": "amd64", "CGO_ENABLED": "0"}, timeout=180)
    if built.returncode:
        raise SystemExit(f"Could not compile genuine Windows PE fixture: {built.stderr.decode(errors='replace')}")
keygen = command(["minisign", "-G", "-W", "-p", root / "key.pub", "-s", root / "key.sec"], "keygen")
if keygen.returncode:
    raise SystemExit("Could not create genuine Minisign fixture key")
public_key = (root / "key.pub").read_text().splitlines()[-1]

def config(tool="win-demo", *, signed=True, family=("app", "worker"), archive="zip", targets=("windows/amd64",), naming=None):
    document = {"tool_name": tool, "repo": "fixture/" + tool, "binary_name": "app", "language": "go",
                "local_path": str(root / "go-fixture"), "targets": list(targets),
                "target_triples": {"windows/amd64": "x86_64-pc-windows-msvc"},
                "archive_format": archive, "workspace_binaries": list(family),
                "artifact_naming": naming or "${name}-${version}-${os}-${arch}"}
    if signed:
        document["minisign_pubkey"] = public_key
    (root / "config/repos.d" / (tool + ".yaml")).write_text(json.dumps(document))
    return document

def generate(tool, label):
    result = command([project / "dsr", "--json", "--non-interactive", "installer", "generate", tool,
                      "--shell", "powershell"], label)
    path = root / "generated" / tool / "install.ps1"
    return result, path

config()
generated, runtime = generate("win-demo", "generate")
check("public CLI generates a real parse-checked PowerShell installer", generated.returncode == 0 and runtime.is_file(),
      generated.stderr.decode(errors="replace"))
if generated.returncode or not runtime.is_file():
    raise SystemExit(1)
script = runtime.read_text()
encoded = re.findall(r"\$script:DsrWindowsInstallPolicyBase64 = '([A-Za-z0-9+/=]+)'", script)
policy = json.loads(base64.b64decode(encoded[0]))
check("generated data policy preserves the complete Windows executable family",
      len(encoded) == 1 and script.startswith("#requires -Version 7.4\n") and
      policy["platforms"]["windows/amd64"]["binaries"] == ["app.exe", "worker.exe"] and
      policy["public_key"] == public_key)
help_result = command(["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", runtime, "-Help", "-Json"], "help")
check("unchanged generated script implements -Help before host detection",
      help_result.returncode == 0 and json.loads(help_result.stdout)["status"] == "help",
      help_result.stderr.decode(errors="replace"))
validated = command([project / "dsr", "--json", "--non-interactive", "installer", "validate", "win-demo",
                     "--shell", "powershell"], "validate")
check("public CLI validates the published PowerShell generation", validated.returncode == 0,
      validated.stderr.decode(errors="replace"))
if sys.platform != "win32":
    unsupported = command(["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", runtime,
                           "-Version", "1.2.3", "-Json"], "native-host-refusal")
    check("unchanged runtime refuses a non-Windows host", unsupported.returncode == 3 and
          json.loads(unsupported.stdout)["status"] == "error")

driver = root / "driver.ps1"
driver.write_text(r'''param([string]$RuntimePath, [string]$CasePath)
$ErrorActionPreference = 'Stop'
$fixture = ConvertFrom-Json ([IO.File]::ReadAllText($CasePath)) -AsHashtable
$text = [IO.File]::ReadAllText($RuntimePath)
$marker = '# DSR_WINDOWS_INSTALL_DISPATCH:'
$offset = $text.IndexOf($marker, [StringComparison]::Ordinal)
if ($offset -le 0 -or $text.LastIndexOf($marker, [StringComparison]::Ordinal) -ne $offset) { throw 'Dispatch marker is not unique' }
# The genuine generated policy and all runtime helpers are loaded unchanged.
# Only the platform/HTTP boundaries below are adapted for this Linux fixture.
. ([scriptblock]::Create($text.Substring(0, $offset)))
$script:Fixture = $fixture
if ($fixture.Contains('without_minisign') -and $fixture.without_minisign) {
    # Real dependency absence after PowerShell starts, never a verifier stub.
    $env:PATH = ''
}
function Get-DsrHostPlatform { return $script:Fixture.platform }
function Invoke-DsrDownload {
    param([string]$Url, [string]$Destination, [switch]$Optional, [long]$MaximumBytes = 2147483648)
    [IO.File]::AppendAllText($script:Fixture.requests, $Url + "`n")
    if ($script:Fixture.parameters.Contains('Offline') -and $script:Fixture.parameters.Offline) {
        throw 'Offline runtime crossed the HTTP boundary'
    }
    if (-not $script:Fixture.downloads.Contains($Url)) {
        if ($Optional) { return $false }
        Stop-DsrInstall 'Fixture HTTP 404' 8
    }
    $source = $script:Fixture.downloads[$Url]
    if ([IO.FileInfo]::new($source).Length -gt $MaximumBytes) { Stop-DsrInstall 'Fixture exceeds real download limit' 7 }
    Copy-DsrNewFile $source $Destination
    return $true
}
if ($fixture.Contains('move_fault') -and $fixture.move_fault) {
    # Explicit injected boundary: first replacement performs the real move;
    # the second throws. Backup, rollback and final byte checks remain real.
    $script:Moves = 0
    function Move-DsrInstalledFile {
        param([string]$Source, [string]$Destination)
        $script:Moves++
        if ($script:Moves -eq 2) { throw 'Injected second replacement failure' }
        [IO.File]::Move($Source, $Destination, $true)
    }
}
if ($fixture.Contains('cleanup_fault') -and $fixture.cleanup_fault) {
    $script:RealCleanup = ${function:Remove-DsrPrivateTree}
    function Remove-DsrPrivateTree {
        param([string]$Path)
        if ($Path.StartsWith([IO.Path]::Combine($script:Fixture.parameters.Prefix, '.dsr-install-'))) {
            throw 'Injected post-commit private-stage cleanup refusal'
        }
        & $script:RealCleanup $Path
    }
}
$held = $null
try {
    if ($fixture.Contains('held_lease') -and $fixture.held_lease) {
        $held = [IO.FileStream]::new([IO.Path]::Combine($fixture.parameters.Prefix, '.dsr-windows-install.lock'),
            [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    }
    $arguments = $fixture.parameters
    $code = Invoke-DsrWindowsInstaller @arguments
} finally { if ($null -ne $held) { $held.Dispose() } }
if ($fixture.Contains('cleanup_fault') -and $fixture.cleanup_fault) {
    $probe = [IO.FileStream]::new([IO.Path]::Combine($fixture.parameters.Prefix, '.dsr-windows-install.lock'),
        [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    $probe.Dispose()
    [IO.File]::WriteAllText($fixture.lease_probe, 'released')
}
exit $code
''')

def asset_for(selected=policy, version="1.2.3"):
    return selected["platforms"]["windows/amd64"]["name"].replace("${version}", version)

asset = asset_for()
base_url = "https://github.com/fixture/win-demo/releases/download/v1.2.3/"

def release(label, *, kind="good", checksum="SHA256SUMS", signed=True, selected=policy, raw=False):
    directory = root / ("release-" + label)
    directory.mkdir()
    chosen = asset_for(selected)
    payload = directory / chosen
    app = (root / "app.exe").read_bytes()
    worker = (root / "worker.exe").read_bytes()
    if kind == "wrong-machine":
        app = bytearray(app)
        offset = int.from_bytes(app[0x3c:0x40], "little")
        app[offset + 4:offset + 6] = (0xaa64).to_bytes(2, "little")
        app = bytes(app)
    if kind == "not-pe":
        app = b"This payload is not an executable.\n"
    if raw:
        payload.write_bytes(app)
    else:
        with zipfile.ZipFile(payload, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("bin/app.exe", app)
            if kind != "missing-member":
                archive.writestr("libexec/worker.exe", worker)
            archive.writestr("README.txt", "Fixture payloads are never executed.\n")
            if kind == "traversal":
                archive.writestr("../escape", "outside")
            if kind == "case-collision":
                archive.writestr("BIN/extra.txt", "ambiguous")
            if kind == "duplicate-provider":
                archive.writestr("other/app.exe", app)
            if kind == "symlink":
                link = zipfile.ZipInfo("bin/link")
                link.create_system = 3
                link.external_attr = 0o120777 << 16
                archive.writestr(link, "../../outside")
    digest = hashlib.sha256(payload.read_bytes()).hexdigest()
    checksum_name = chosen + ".sha256" if checksum == "sidecar" else checksum
    checksum_path = directory / checksum_name
    content = digest + "  " + chosen + "\n"
    if checksum == "sidecar":
        content = digest + "\n"
    if kind == "bad-checksum":
        content = "0" * 64 + "  " + chosen + "\n"
    if kind == "duplicate-checksum":
        content += content
    if kind == "missing-checksum-entry":
        content = digest + "  unrelated.zip\n"
    checksum_path.write_text(content)
    if signed:
        signed_result = command(["minisign", "-S", "-s", root / "key.sec", "-m", payload,
                                 "-x", str(payload) + ".minisig"], "sign-" + label)
        if signed_result.returncode:
            raise RuntimeError("Minisign fixture signing failed")
        if kind == "bad-signature":
            Path(str(payload) + ".minisig").write_text("invalid signature\n")
    url = "https://github.com/" + selected["repo"] + "/releases/download/v1.2.3/"
    downloads = {url + path.name: str(path) for path in directory.iterdir()}
    return downloads

def run_case(label, downloads=None, *, selected_runtime=runtime, cache=None, prefix=None,
             offline=False, version="1.2.3", yes=True, options=None):
    cache = Path(cache or root / ("cache-" + label))
    prefix = Path(prefix or root / ("prefix-" + label))
    requests = root / (label + ".requests")
    parameters = {"Prefix": str(prefix), "CacheDir": str(cache), "Json": True, "Yes": yes}
    if version is not None:
        parameters["Version"] = version
    if offline:
        parameters["Offline"] = True
    spec = {"platform": "windows/amd64", "parameters": parameters,
            "requests": str(requests), "downloads": downloads or {}}
    spec.update(options or {})
    case = root / (label + ".json")
    case.write_text(json.dumps(spec))
    result = command(["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", driver,
                      "-RuntimePath", selected_runtime, "-CasePath", case], label)
    try:
        parsed = json.loads(result.stdout)
    except Exception:
        parsed = {"parse_error": result.stdout.decode(errors="replace")}
    return result, parsed, cache, prefix, requests

def refusal(label, *, downloads=None, expected=7, **kwargs):
    result, parsed, cache, prefix, requests = run_case(label, downloads, **kwargs)
    check(label, result.returncode == expected and parsed.get("status") == "error" and not prefix.exists(),
          result.stderr.decode(errors="replace") + " " + json.dumps(parsed))
    return result, parsed, cache, prefix, requests

good = release("good")
success, details, good_cache, installed, requests = run_case("signed-family", good)
check("signed ZIP installs the full genuine PE family with exact result hashes", success.returncode == 0 and
      details.get("signature_verified") is True and len(details.get("binaries", [])) == 2 and
      all((installed / name).read_bytes() == (root / name).read_bytes() for name in ("app.exe", "worker.exe")) and
      all(row["sha256"] == hashlib.sha256(Path(row["path"]).read_bytes()).hexdigest() for row in details.get("binaries", [])),
      success.stderr.decode(errors="replace") + " " + json.dumps(details))
if success.returncode:
    print("Cannot exercise cache/rollback controls until the genuine successful path works", flush=True)
    raise SystemExit(1)
if sys.platform != "win32":
    created_files = [path for path in good_cache.rglob("*") if path.is_file()] + list(installed.iterdir())
    check("shared exclusive creation gives every POSIX fixture proof and installed file private mode",
          bool(created_files) and all(path.stat().st_mode & 0o777 == 0o600 for path in created_files))
offline_result, offline_details, _, offline_prefix, offline_requests = run_case("offline-family", cache=good_cache, offline=True)
check("offline mode revalidates complete signed evidence without any HTTP request", offline_result.returncode == 0 and
      offline_details.get("cache", {}).get("offline") is True and not offline_requests.exists() and
      (offline_prefix / "worker.exe").read_bytes() == (root / "worker.exe").read_bytes(), offline_result.stderr.decode(errors="replace"))
missing_verifier, missing_verifier_details, _, missing_verifier_prefix, missing_verifier_requests = run_case(
    "offline-missing-minisign", cache=good_cache, offline=True, options={"without_minisign": True})
check("signed offline cache requires the genuine verifier before any install or HTTP", missing_verifier.returncode == 3 and
      missing_verifier_details.get("status") == "error" and not missing_verifier_prefix.exists() and
      not missing_verifier_requests.exists(), missing_verifier.stderr.decode(errors="replace"))
refusal("offline-requires-version", cache=good_cache, offline=True, version=None, expected=4)
refusal("offline-exact-version-miss", cache=good_cache, offline=True, version="9.9.9")
tampered_cache = root / "cache-tampered"
shutil.copytree(good_cache, tampered_cache)
cached_entry = next(path for path in tampered_cache.iterdir() if path.is_dir())
(cached_entry / asset).write_bytes(b"changed payload")
refusal("offline-corrupt-payload", cache=tampered_cache, offline=True)
unsafe_cache = root / "cache-foreign-writes"
shutil.copytree(good_cache, unsafe_cache)
os.chmod(unsafe_cache, 0o777)
refusal("offline-refuses-writable-cache", cache=unsafe_cache, offline=True)

for kind in ("bad-checksum", "duplicate-checksum", "missing-checksum-entry", "bad-signature",
             "traversal", "case-collision", "duplicate-provider", "symlink", "missing-member", "wrong-machine", "not-pe"):
    refusal(kind, downloads=release(kind, kind=kind))

missing_signature = dict(good)
missing_signature.pop(base_url + asset + ".minisig")
refusal("configured-signature-missing", downloads=missing_signature, expected=8)
for checksum in ("sidecar", "checksums.sha256", "SHA256SUMS.txt", "checksums.txt", "win-demo-1.2.3-SHA256SUMS.txt"):
    label = "checksum-" + checksum.replace(".", "-")
    outcome, _, _, _, _ = run_case(label, release(label, checksum=checksum))
    check("exact checksum fallback " + checksum, outcome.returncode == 0, outcome.stderr.decode(errors="replace"))

latest_downloads = dict(good)
latest_path = root / "latest.json"
latest_path.write_text(json.dumps({"tag_name": "v1.2.3", "draft": False}))
latest_downloads["https://api.github.com/repos/fixture/win-demo/releases/latest"] = str(latest_path)
latest, latest_details, _, _, latest_requests = run_case("latest-online", latest_downloads, version=None)
check("online latest selects a real exact tag before payload lookup", latest.returncode == 0 and
      latest_details.get("version") == "v1.2.3" and latest_requests.read_text().splitlines()[0].endswith("/releases/latest"),
      latest.stderr.decode(errors="replace"))

old_prefix = root / "prefix-rollback"
old_prefix.mkdir()
originals = {"app.exe": b"old application bytes", "worker.exe": b"old worker bytes", "unrelated.txt": b"keep this file"}
for name, value in originals.items():
    (old_prefix / name).write_bytes(value)
rollback, rollback_details, _, _, _ = run_case("rollback-second-move", cache=good_cache, prefix=old_prefix,
                                               offline=True, options={"move_fault": True})
check("injected second move failure rolls back the complete old executable family", rollback.returncode == 7 and
      rollback_details.get("status") == "error" and all((old_prefix / name).read_bytes() == value for name, value in originals.items()) and
      not list(old_prefix.glob(".dsr-install-*")), rollback.stderr.decode(errors="replace"))
unauthorized, unauthorized_details, _, _, _ = run_case("replacement-needs-yes", cache=good_cache, prefix=old_prefix, offline=True, yes=False)
check("existing selected executables require explicit replacement consent", unauthorized.returncode == 2 and
      unauthorized_details.get("status") == "error" and all((old_prefix / name).read_bytes() == value for name, value in originals.items()))
held, _, _, _, _ = run_case("held-kernel-lease", cache=good_cache, prefix=old_prefix, offline=True, options={"held_lease": True})
check("real held kernel lease refuses a second installer without changing prior bytes", held.returncode == 2 and
      all((old_prefix / name).read_bytes() == value for name, value in originals.items()), held.stderr.decode(errors="replace"))
hardlink_prefix = root / "prefix-lock-hardlink"
hardlink_prefix.mkdir()
unrelated = root / "unrelated-empty-file"
unrelated.write_bytes(b"")
os.link(unrelated, hardlink_prefix / ".dsr-windows-install.lock")
hardlink, _, _, _, _ = run_case("hardlinked-empty-lock", cache=good_cache, prefix=hardlink_prefix, offline=True)
check("existing empty hardlinked lock never overwrites unrelated bytes", hardlink.returncode == 2 and
      unrelated.read_bytes() == b"" and (hardlink_prefix / ".dsr-windows-install.lock").read_bytes() == b"" and
      not (hardlink_prefix / "app.exe").exists(), hardlink.stderr.decode(errors="replace"))
cleanup_probe = root / "cleanup-lease-released"
cleanup, cleanup_details, _, cleanup_prefix, _ = run_case("cleanup-after-commit", cache=good_cache, offline=True,
    options={"cleanup_fault": True, "lease_probe": str(cleanup_probe)})
check("injected cleanup refusal retains successful install and releases the real lease", cleanup.returncode == 0 and
      cleanup_details.get("status") == "success" and cleanup_probe.read_text() == "released" and
      (cleanup_prefix / "app.exe").read_bytes() == (root / "app.exe").read_bytes() and
      bool(list(cleanup_prefix.glob(".dsr-install-*"))), cleanup.stderr.decode(errors="replace"))

config("raw-demo", signed=False, family=("app",), archive="none", naming="portable-payload")
raw_generated, raw_runtime = generate("raw-demo", "generate-raw")
check("generator supports a raw single executable with a literal non-exe asset basename", raw_generated.returncode == 0,
      raw_generated.stderr.decode(errors="replace"))
if raw_generated.returncode == 0:
    raw_encoded = re.search(r"\$script:DsrWindowsInstallPolicyBase64 = '([A-Za-z0-9+/=]+)'", raw_runtime.read_text()).group(1)
    raw_policy = json.loads(base64.b64decode(raw_encoded))
    raw_downloads = release("raw", signed=False, selected=raw_policy, raw=True)
    raw_result, raw_details, _, raw_prefix, _ = run_case("raw-single", raw_downloads, selected_runtime=raw_runtime)
    check("raw PE installs under configured executable name without executing it", raw_result.returncode == 0 and
          raw_details.get("signature_verified") is False and
          (raw_prefix / "app.exe").read_bytes() == (root / "app.exe").read_bytes(), raw_result.stderr.decode(errors="replace"))

before = runtime.read_bytes()
config(archive="none")
invalid_generation, _ = generate("win-demo", "refuse-raw-family")
check("unsupported raw multi-executable policy preserves the prior published installer", invalid_generation.returncode == 4 and
      runtime.read_bytes() == before, invalid_generation.stderr.decode(errors="replace"))
config(targets=("linux/amd64",))
missing_windows, _ = generate("win-demo", "refuse-no-windows")
check("missing Windows target refuses generation and preserves the prior installer", missing_windows.returncode == 4 and
      runtime.read_bytes() == before, missing_windows.stderr.decode(errors="replace"))

print(f"\nWindows installer checks: {passed + failed}; passed: {passed}; failed: {failed}", flush=True)
print("Qualified here: genuine PowerShell/Go PE/Minisign, local cache/archive/filesystem/rollback logic.", flush=True)
print("Not qualified here: native Windows ACL/NTFS behavior or live GitHub transport.", flush=True)
raise SystemExit(1 if failed else 0)
PY
