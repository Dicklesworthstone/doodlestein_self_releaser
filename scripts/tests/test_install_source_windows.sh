#!/usr/bin/env bash
# Genuine generated source installation: real Git pins, Rust/Go Windows PE
# families, retained receipts and the ordinary installation transaction. The
# portable fixture adapts host detection and Git/HTTP transport only; it does
# not claim live GitHub, native Windows ACL/NTFS or Windows process acceptance.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
for dependency in pwsh git go cargo rustc minisign python3 jq yq; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'SKIP: Windows source installation tests require %s\n' "$dependency"
        exit 0
    fi
done

python3 - "$PROJECT_ROOT" "$@" <<'PY'
import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

arguments = argparse.ArgumentParser(description="Generated Windows Rust/Go source installation regression")
arguments.add_argument("project", type=Path)
arguments.add_argument("--baseline-project", type=Path, help="Frozen checkout before Windows source installation")
arguments.add_argument("--rust-baseline-project", type=Path, help="Frozen checkout before Windows Rust source installation")
options = arguments.parse_args()
project = options.project.resolve()
root = Path(tempfile.mkdtemp(prefix="dsr-windows-source-", dir=os.environ.get("TMPDIR"))).resolve()
os.chmod(root, 0o700)
print(f"Windows source fixture evidence: {root}", flush=True)
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


def required(args, label, **kwargs):
    result = command(args, label, **kwargs)
    if result.returncode:
        raise SystemExit(f"Fixture setup failed ({label}): {result.stderr.decode(errors='replace')}")
    return result.stdout.decode().strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def machine(path):
    data = path.read_bytes()
    offset = struct.unpack_from("<I", data, 60)[0]
    if data[:2] != b"MZ" or data[offset:offset + 4] != b"PE\0\0":
        return None
    return struct.unpack_from("<H", data, offset + 4)[0]


upstream = root / "upstream"
upstream.mkdir()
required(["git", "init", "--quiet", "--initial-branch=main", upstream], "git-init")
required(["git", "-C", upstream, "config", "user.email", "fixture@example.invalid"], "git-email")
required(["git", "-C", upstream, "config", "user.name", "DSR Source Fixture"], "git-name")
files = {
    "project/go.mod": "module example.invalid/windows-source\n\ngo 1.22\n",
    "project/apps/primary/main.go": 'package main\nimport "fmt"\nfunc main() { fmt.Println("primary-v1") }\n',
    "project/cmd/helper/main.go": 'package main\nimport "fmt"\nfunc main() { fmt.Println("helper-v1") }\n',
    "project/cmd/arm-helper/main.go": 'package main\nimport "fmt"\nfunc main() { fmt.Println("arm-helper-v1") }\n',
    ".github/source-note.txt": "A normal leading-dot tracked directory.\n",
    "docs/space name.txt": "A normal tracked filename containing a space.\n",
}
for name, value in files.items():
    path = upstream / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)
required(["git", "-C", upstream, "add", "."], "git-add-v1")
required(["git", "-C", upstream, "commit", "--quiet", "-m", "Initial source family"], "git-commit-v1")
first_commit = required(["git", "-C", upstream, "rev-parse", "HEAD"], "git-pin-v1")
required(["git", "-C", upstream, "tag", "-a", "v1.2.3", "-m", "Annotated source release"], "git-tag")
(upstream / "project/apps/primary/main.go").write_text(files["project/apps/primary/main.go"].replace("v1", "v2"))
required(["git", "-C", upstream, "add", "."], "git-add-v2")
required(["git", "-C", upstream, "commit", "--quiet", "-m", "Advance source HEAD"], "git-commit-v2")
second_commit = required(["git", "-C", upstream, "rev-parse", "HEAD"], "git-pin-v2")
required(["minisign", "-G", "-W", "-p", root / "key.pub", "-s", root / "key.sec"], "keygen")
public_key = (root / "key.pub").read_text().splitlines()[-1]


def config(tool="source-demo", **changes):
    value = {"tool_name": tool, "repo": "fixture/" + tool, "binary_name": "app", "language": "go",
             "local_path": str(upstream), "targets": ["windows/amd64", "windows/arm64"],
             "target_triples": {"windows/amd64": "x86_64-pc-windows-msvc", "windows/arm64": "aarch64-pc-windows-msvc"},
             "archive_format": "zip", "artifact_naming": "${name}-${version}-${os}-${arch}",
             "workspace_binaries": ["app", "helper"],
             "workspace_binaries_by_target": {"windows/arm64": ["app", "arm-helper"]},
             "source_subdir": "project", "source_entry": "apps/primary", "minisign_pubkey": public_key}
    value.update(changes)
    (root / "config/repos.d" / (tool + ".yaml")).write_text(json.dumps(value))
    return value


def generate(tool, label, *, checkout=project, destination=None):
    extra = {"DSR_INSTALLER_DIR": str(destination)} if destination else {}
    result = command([checkout / "dsr", "--json", "--non-interactive", "installer", "generate", tool,
                      "--shell", "powershell"], label, extra=extra, cwd=checkout)
    runtime = (destination or root / "generated") / tool / "install.ps1"
    policy = None
    if runtime.is_file():
        encoded = re.findall(r"\$script:DsrWindowsInstallPolicyBase64 = '([A-Za-z0-9+/=]+)'", runtime.read_text())
        policy = json.loads(base64.b64decode(encoded[0]))
    return result, runtime, policy


config()
generated, runtime, policy = generate("source-demo", "generate")
check("public CLI publishes parse-checked standalone source-capable PowerShell", generated.returncode == 0 and runtime.is_file(),
      generated.stderr.decode(errors="replace"))
if generated.returncode or policy is None:
    raise SystemExit(1)
check("embedded source selectors and both target-specific families match configuration",
      policy.get("source") == {"language": "go", "subdir": "project", "entry": "apps/primary"} and
      policy["platforms"]["windows/amd64"]["binaries"] == ["app.exe", "helper.exe"] and
      policy["platforms"]["windows/arm64"]["binaries"] == ["app.exe", "arm-helper.exe"])

driver = root / "driver.ps1"
driver.write_text(r'''param([string]$RuntimePath, [string]$CasePath)
$ErrorActionPreference = 'Stop'
$fixture = ConvertFrom-Json ([IO.File]::ReadAllText($CasePath)) -AsHashtable
$text = [IO.File]::ReadAllText($RuntimePath)
$marker = '# DSR_WINDOWS_INSTALL_DISPATCH:'
$offset = $text.IndexOf($marker, [StringComparison]::Ordinal)
if ($offset -le 0 -or $text.LastIndexOf($marker, [StringComparison]::Ordinal) -ne $offset) { throw 'Dispatch marker is not unique' }
. ([scriptblock]::Create($text.Substring(0, $offset)))
$script:Fixture = $fixture
function Get-DsrHostPlatform { return $script:Fixture.platform }
if (Get-Command Invoke-DsrSourceGit -ErrorAction SilentlyContinue) {
    # Only the remote boundary changes: Git itself performs every real init,
    # fetch, pin, inventory and checkout using this separate local repository.
    function Get-DsrSourceRepositoryUrl { param([string]$Repository); return $script:Fixture.repository_url }
    $script:RealSourceGit = ${function:Invoke-DsrSourceGit}
    function Invoke-DsrSourceGit {
        param([string]$Git, [string[]]$Arguments, [string]$Directory, [string]$Log,
            [int]$Timeout, [string]$Repository, $Environment, [switch]$Capture)
        $Environment.GIT_ALLOW_PROTOCOL = 'file'
        & $script:RealSourceGit $Git (@('-c', 'protocol.file.allow=always') + $Arguments) $Directory $Log $Timeout $Repository $Environment -Capture:$Capture
    }
    $script:RealSourceCommand = ${function:Invoke-DsrSourceCommand}
    $script:MutatedSource = $false
    function Invoke-DsrSourceCommand {
        param([string]$Executable, [string[]]$Arguments, [string]$Directory, [string]$Log,
            [int]$Timeout, $Environment = @{}, [int]$FailureCode = 6, [switch]$Capture)
        [IO.File]::AppendAllText($script:Fixture.commands, ((@{ executable = $Executable; arguments = @($Arguments) } | ConvertTo-Json -Compress) + "`n"))
        $result = & $script:RealSourceCommand @PSBoundParameters
        if ($script:Fixture.Contains('mutate_source') -and $script:Fixture.mutate_source -and
            -not $script:MutatedSource -and $Arguments[0] -ceq 'build') {
            $member = if ($script:Fixture.Contains('mutate_source_member')) { $script:Fixture.mutate_source_member } else { 'apps/primary/main.go' }
            [IO.File]::AppendAllText([IO.Path]::Combine($Directory, $member), "`n// injected tracked-source mutation`n")
            $script:MutatedSource = $true
        }
        if ($Capture) { return $result }
    }
    if ($fixture.Contains('mutate_output') -and $fixture.mutate_output) {
        $script:RealBuildSource = ${function:Build-DsrSourceFamily}
        function Build-DsrSourceFamily {
            param($Policy, $Selection, [string]$Platform, [string]$Reference, [string]$Work, [int]$Timeout)
            $built = & $script:RealBuildSource @PSBoundParameters
            $path = [IO.Path]::Combine($built.directory, $Selection.binaries[0])
            $stream = [IO.File]::Open($path, [IO.FileMode]::Append, [IO.FileAccess]::Write)
            try { $stream.WriteByte(42) } finally { $stream.Dispose() }
            return $built
        }
    }
}
function Invoke-DsrDownload {
    param([string]$Url, [string]$Destination, [switch]$Optional, [long]$MaximumBytes = 2147483648, [switch]$ApiAsset)
    [IO.File]::AppendAllText($script:Fixture.requests, $Url + "`n")
    if (-not $script:Fixture.downloads.Contains($Url)) {
        if ($Optional) { return $false }
        Stop-DsrInstall 'Fixture release HTTP unavailable' 8
    }
    $source = $script:Fixture.downloads[$Url]
    if ([IO.FileInfo]::new($source).Length -gt $MaximumBytes) { Stop-DsrInstall 'Fixture exceeds download size limit' 7 }
    Copy-DsrNewFile $source $Destination
    return $true
}
if ($fixture.Contains('move_fault') -and $fixture.move_fault) {
    $script:Moves = 0
    function Move-DsrInstalledFile {
        param([string]$Source, [string]$Destination)
        $script:Moves++
        if ($script:Moves -eq 2) { throw 'Injected second executable replacement failure' }
        [IO.File]::Move($Source, $Destination, $true)
    }
}
if ($fixture.Contains('without_tools') -and $fixture.without_tools) { $env:PATH = '' }
if ($fixture.Contains('pipe_probe')) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $code = 0
    try {
        Invoke-DsrSourceCommand $fixture.pipe_probe @() $fixture.probe_directory $fixture.probe_log 1
    } catch {
        $code = if ($_.Exception.Data.Contains('DsrExitCode')) { [int]$_.Exception.Data['DsrExitCode'] } else { 7 }
    }
    [Console]::Out.WriteLine((@{ exit_code = $code; elapsed_ms = $clock.ElapsedMilliseconds } | ConvertTo-Json -Compress))
    exit $code
}
$parameters = $fixture.parameters
exit (Invoke-DsrWindowsInstaller @parameters)
''')


def invoke(label, *, parameters=None, selected_runtime=runtime, extra=None, **changes):
    params = {"FromSource": True, "SourceRef": "refs/tags/v1.2.3", "SourceTimeout": 60,
              "Prefix": str(root / (label + "-prefix")), "CacheDir": str(root / (label + "-cache")), "Yes": True, "Json": True}
    params.update(parameters or {})
    fixture = {"platform": "windows/amd64", "repository_url": upstream.as_uri(), "parameters": params,
               "requests": str(root / (label + ".requests")), "commands": str(root / (label + ".commands")), "downloads": {}}
    fixture.update(changes)
    case = root / (label + ".json")
    case.write_text(json.dumps(fixture))
    result = command(["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", driver,
                      "-RuntimePath", selected_runtime, "-CasePath", case], label, extra=extra)
    try:
        value = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError):
        value = {}
    return result, value, fixture


def calls(fixture):
    path = Path(fixture["commands"])
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def no_http(fixture):
    path = Path(fixture["requests"])
    return not path.exists() or not path.read_bytes()


if options.baseline_project:
    baseline, baseline_runtime, baseline_policy = generate("source-demo", "generate-baseline",
        checkout=options.baseline_project.resolve(), destination=root / "baseline-generated")
    release_policy = copy.deepcopy(policy)
    release_policy.pop("source")
    check("frozen baseline and candidate preserve the same release selection and signer policy",
          baseline.returncode == 0 and baseline_policy == release_policy, baseline.stderr.decode(errors="replace"))
    old, _, old_fixture = invoke("baseline-source", selected_runtime=baseline_runtime)
    check("same real source fixture exposes the baseline's missing FromSource caller flow",
          old.returncode != 0 and b"FromSource" in old.stderr and not Path(old_fixture["parameters"]["Prefix"]).exists())

tagged, tag_result, tag_fixture = invoke("tagged-source", extra={"GOOS": "plan9", "GOARCH": "386", "GOFLAGS": "-invalid-source-fixture", "GOTOOLCHAIN": "missing-fixture"})
check("annotated tag source build installs the genuine complete x64 executable family", tagged.returncode == 0,
      tagged.stderr.decode(errors="replace"))
if tagged.returncode:
    raise SystemExit(1)
tag_prefix = Path(tag_fixture["parameters"]["Prefix"])
check("source receipt pins the annotated tag's commit despite a newer repository HEAD",
      tag_result["source"]["source_commit"] == first_commit and first_commit != second_commit and
      tag_result["source"]["requested_ref"] == "refs/tags/v1.2.3")
check("real installed outputs have independent x64 PE headers and exact complete-family hashes",
      {row["name"] for row in tag_result["binaries"]} == {"app.exe", "helper.exe"} and all(
          machine(tag_prefix / row["name"]) == 0x8664 and digest(tag_prefix / row["name"]) == row["sha256"] and
          (tag_prefix / row["name"]).stat().st_size == row["size_bytes"] for row in tag_result["binaries"]))
check("explicit source result preserves the release/source trust distinction and actual Go target",
      tag_result["method"] == "source" and tag_result["signed_release"] is False and
      tag_result["signature_verified"] is False and tag_result["source"]["signed_release"] is False and
      tag_result["go_target"] == {"os": "windows", "arch": "amd64"} and "target_triple" not in tag_result)
check("source receipt records real compiler, monorepo selection and per-executable entries",
      tag_result["source"]["compiler"].startswith("go version go") and
      tag_result["source"]["source_subdir"] == "project" and tag_result["source"]["source_entry"] == "apps/primary" and
      {row["name"]: row["entry"] for row in tag_result["source"]["source_entries"]} == {"app.exe": "apps/primary", "helper.exe": "cmd/helper"})
receipt = Path(tag_result["source_receipt"]["path"])
check("durable receipt remains after successful source-work cleanup and binds all installed bytes",
      receipt.is_file() and json.loads(receipt.read_text()) == tag_result["source"] and
      digest(receipt) == tag_result["source_receipt"]["sha256"] and receipt.stat().st_size == tag_result["source_receipt"]["size_bytes"] and
      not list(Path(tag_fixture["parameters"]["CacheDir"]).glob(".dsr-source-*")))
check("source path performs real Git/Go work without crossing release HTTP acquisition", no_http(tag_fixture) and
      any(row["arguments"][0] == "build" for row in calls(tag_fixture)))
metadata = required(["go", "version", "-m", tag_prefix / "app.exe"], "built-metadata")
check("independent Go metadata confirms pinned source commit and overridden ambient target settings",
      "GOOS=windows" in metadata and "GOARCH=amd64" in metadata and "vcs.revision=" + first_commit in metadata)

head, head_result, head_fixture = invoke("head-source", parameters={"SourceRef": "HEAD", "Prefix": str(tag_prefix)})
check("HEAD is resolved once and upgrades the existing complete family through the shared transaction",
      head.returncode == 0 and head_result.get("source", {}).get("source_commit") == second_commit and
      {row["name"] for row in head_result.get("binaries", [])} == {"app.exe", "helper.exe"}, head.stderr.decode(errors="replace"))
arm, arm_result, arm_fixture = invoke("arm-source", parameters={"SourceRef": first_commit}, platform="windows/arm64")
check("explicit full SHA builds the configured ARM64-specific executable family", arm.returncode == 0 and
      arm_result.get("source", {}).get("source_commit") == first_commit, arm.stderr.decode(errors="replace"))
check("genuine ARM64 PE bytes and receipt select app/arm-helper without the x64-only companion",
      arm.returncode == 0 and arm_result.get("go_target") == {"os": "windows", "arch": "arm64"} and
      {row["name"] for row in arm_result.get("binaries", [])} == {"app.exe", "arm-helper.exe"} and all(
          machine(Path(arm_fixture["parameters"]["Prefix"]) / row["name"]) == 0xAA64 for row in arm_result.get("binaries", [])))

for label, parameters, expected in (
    ("source-without-consent", {"FromSource": False}, 4),
    ("source-with-release-version", {"Version": "v1.2.3"}, 4),
    ("source-offline", {"Offline": True}, 4),
    ("source-invalid-ref", {"SourceRef": "refs/heads/../unsafe"}, 4),
    ("source-invalid-timeout", {"SourceTimeout": 0}, 4),
):
    refused, result, fixture = invoke(label, parameters=parameters)
    check(label + " refuses before source commands, HTTP or destination writes", refused.returncode == expected and
          not calls(fixture) and no_http(fixture) and not Path(fixture["parameters"]["Prefix"]).exists(), refused.stderr.decode(errors="replace"))
missing, _, fixture = invoke("missing-tools", without_tools=True)
check("missing installed tools refuse without an implicit compiler download", missing.returncode == 3 and
      not calls(fixture) and no_http(fixture) and not Path(fixture["parameters"]["Prefix"]).exists())

config("missing-companion", workspace_binaries=["app", "missing"])
missing_generated, missing_runtime, _ = generate("missing-companion", "generate-missing-companion")
check("missing companion fixture uses the public generator", missing_generated.returncode == 0)
missing, _, fixture = invoke("missing-companion", selected_runtime=missing_runtime)
check("all source providers are resolved before any compiler build or installation", missing.returncode == 7 and
      not any(row["arguments"][0] == "build" for row in calls(fixture)) and not Path(fixture["parameters"]["Prefix"]).exists())
(upstream / "project/cmd/helper/main.go").write_text("package helper\nfunc Exported() {}\n")
required(["git", "-C", upstream, "add", "."], "git-add-non-main")
required(["git", "-C", upstream, "commit", "--quiet", "-m", "Non-executable companion fixture"], "git-commit-non-main")
non_main_commit = required(["git", "-C", upstream, "rev-parse", "HEAD"], "git-pin-non-main")
prior_family = {name: digest(tag_prefix / name) for name in ("app.exe", "helper.exe")}
non_main, _, fixture = invoke("non-main", parameters={"SourceRef": non_main_commit, "Prefix": str(tag_prefix)})
check("real Go package resolution refuses a non-main companion before building the primary", non_main.returncode == 6 and
      not any(row["arguments"][0] == "build" for row in calls(fixture)) and
      all(digest(tag_prefix / name) == value for name, value in prior_family.items()))
(upstream / "project/cmd/helper/main.go").write_text('package main\nvar invalid int = "not an integer"\nfunc main() {}\n')
required(["git", "-C", upstream, "add", "."], "git-add-compiler-failure")
required(["git", "-C", upstream, "commit", "--quiet", "-m", "Later compiler failure fixture"], "git-commit-compiler-failure")
compiler_failure_commit = required(["git", "-C", upstream, "rev-parse", "HEAD"], "git-pin-compiler-failure")
compiler_failure, compiler_result, fixture = invoke("later-compiler-failure", parameters={"SourceRef": compiler_failure_commit, "Prefix": str(tag_prefix)})
check("a real second-member compiler failure preserves the entire previously installed family", compiler_failure.returncode == 6 and
      len([row for row in calls(fixture) if row["arguments"][0] == "build"]) == 2 and
      all(digest(tag_prefix / name) == value for name, value in prior_family.items()) and
      Path(compiler_result.get("source_diagnostics", "/nonexistent")).is_dir(), compiler_failure.stderr.decode(errors="replace"))
drift, drift_result, fixture = invoke("source-drift", mutate_source=True)
check("tracked source drift after real compilation prevents installation and retains diagnostics", drift.returncode == 7 and
      "changed the pinned tracked inputs" in drift_result.get("error", "") and
      Path(drift_result.get("source_diagnostics", "/nonexistent")).is_dir() and not Path(fixture["parameters"]["Prefix"]).exists())


def seed_prefix(label):
    prefix = root / (label + "-prefix")
    prefix.mkdir()
    before = {"app.exe": b"old-primary", "helper.exe": b"old-helper", "unrelated.txt": b"keep-me"}
    for name, data in before.items():
        (prefix / name).write_bytes(data)
    return prefix, before


for label, injection, message in (
    ("output-drift", {"mutate_output": True}, "verified source outputs are rebound before transaction publication"),
    ("source-rollback", {"move_fault": True}, "a later source-family move failure restores every prior executable"),
):
    prefix, before = seed_prefix(label)
    refused, result, fixture = invoke(label, parameters={"Prefix": str(prefix)}, **injection)
    check(message, refused.returncode == 7 and all((prefix / name).read_bytes() == data for name, data in before.items()) and
          not (prefix / ".dsr-windows-install.pending.json").exists(), refused.stderr.decode(errors="replace"))
    check(label + " keeps failed build diagnostics and never uses release fallback", "source_diagnostics" in result and
          Path(result["source_diagnostics"]).is_dir() and no_http(fixture))

config("rust-release", language="rust", source_entry="")
rust_generated, rust_runtime, rust_policy = generate("rust-release", "generate-rust")
check("genuine Rust configuration now embeds its explicit Cargo source policy", rust_generated.returncode == 0 and
      rust_policy is not None and rust_policy.get("source") == {"language": "rust", "subdir": "project", "package": ""},
      rust_generated.stderr.decode(errors="replace"))
rust_help = command(["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", rust_runtime, "-Help", "-Json"], "rust-help")
check("generated Rust installer still exposes normal Help", rust_help.returncode == 0 and json.loads(rust_help.stdout).get("status") == "help")
config("unsupported-source", language="bun")
unsupported_generated, unsupported_runtime, unsupported_policy = generate("unsupported-source", "generate-unsupported")
unsupported_source, _, fixture = invoke("unsupported-source-refusal", selected_runtime=unsupported_runtime)
check("unsupported source language refuses without changing ordinary release behavior", unsupported_generated.returncode == 0 and
      "source" not in unsupported_policy and unsupported_source.returncode == 4 and
      not calls(fixture) and no_http(fixture) and not Path(fixture["parameters"]["Prefix"]).exists())
release = root / "signed-release"
release.mkdir()
asset = rust_policy["platforms"]["windows/amd64"]["name"].replace("${version}", "1.2.3")
archive = release / asset
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
    for name in ("app.exe", "helper.exe"):
        package.write(tag_prefix / name, name)
checksum = release / (asset + ".sha256")
checksum.write_text(digest(archive) + "  " + asset + "\n")
signature = release / (asset + ".minisig")
required(["minisign", "-S", "-s", root / "key.sec", "-m", archive, "-x", signature], "sign-release")
base = "https://github.com/fixture/rust-release/releases/download/v1.2.3/"
downloads = {base + path.name: str(path) for path in (archive, checksum, signature)}
release_parameters = {"FromSource": False, "SourceRef": "", "SourceTimeout": 3600, "Version": "v1.2.3"}
installed, installed_result, fixture = invoke("rust-signed-release", parameters=release_parameters,
    selected_runtime=rust_runtime, downloads=downloads)
check("normal Rust release selection installs a real Minisign-verified complete PE family", installed.returncode == 0 and
      installed_result.get("signature_verified") is True and len(installed_result.get("binaries", [])) == 2 and not calls(fixture),
      installed.stderr.decode(errors="replace"))
signature.write_text("invalid signature fixture\n")
bad_signature, _, fixture = invoke("rust-bad-signature", parameters=release_parameters, selected_runtime=rust_runtime, downloads=downloads)
check("failed configured signature never executes the newly embedded source engine", bad_signature.returncode == 7 and
      not calls(fixture) and not Path(fixture["parameters"]["Prefix"]).exists())

published = runtime.read_bytes()
config(source_subdir="../escape")
bad_config, _, _ = generate("source-demo", "generate-invalid-source")
check("invalid Go source configuration is rejected without replacing an already published installer", bad_config.returncode != 0 and
      runtime.read_bytes() == published)

# A real Cargo workspace with a companion outside the default package is the
# missing Windows caller flow. No compiler, metadata or PE output is mocked.
rust_upstream = root / "rust-upstream"
rust_upstream.mkdir()
required(["git", "init", "--quiet", "--initial-branch=main", rust_upstream], "rust-git-init")
required(["git", "-C", rust_upstream, "config", "user.email", "fixture@example.invalid"], "rust-git-email")
required(["git", "-C", rust_upstream, "config", "user.name", "DSR Rust Source Fixture"], "rust-git-name")
rust_files = {
    "project/Cargo.toml": '[workspace]\nmembers = ["primary", "worker"]\ndefault-members = ["primary"]\nresolver = "2"\n',
    "project/primary/Cargo.toml": '[package]\nname = "primary-provider"\nversion = "0.1.0"\nedition = "2021"\n\n[[bin]]\nname = "app"\npath = "src/main.rs"\n',
    "project/primary/src/main.rs": 'fn main() { println!("rust-primary-v1"); }\n',
    "project/worker/Cargo.toml": '[package]\nname = "worker-provider"\nversion = "0.1.0"\nedition = "2021"\n\n[[bin]]\nname = "helper"\npath = "src/main.rs"\n',
    "project/worker/src/main.rs": 'fn main() { println!("rust-worker-v1"); }\n',
}
for name, value in rust_files.items():
    path = rust_upstream / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)
required(["cargo", "generate-lockfile", "--offline", "--manifest-path", rust_upstream / "project/Cargo.toml"], "rust-lockfile")
required(["git", "-C", rust_upstream, "add", "."], "rust-add-v1")
required(["git", "-C", rust_upstream, "commit", "--quiet", "-m", "Pinned Rust family"], "rust-commit-v1")
rust_first_commit = required(["git", "-C", rust_upstream, "rev-parse", "HEAD"], "rust-pin-v1")
required(["git", "-C", rust_upstream, "tag", "-a", "v1.2.3", "-m", "Annotated Rust source release"], "rust-tag")
(rust_upstream / "project/primary/src/main.rs").write_text(rust_files["project/primary/src/main.rs"].replace("v1", "v2"))
required(["git", "-C", rust_upstream, "add", "."], "rust-add-v2")
required(["git", "-C", rust_upstream, "commit", "--quiet", "-m", "Advance Rust source HEAD"], "rust-commit-v2")
rust_second_commit = required(["git", "-C", rust_upstream, "rev-parse", "HEAD"], "rust-pin-v2")
rust_target = os.environ.get("DSR_TEST_WINDOWS_RUST_TARGET", "x86_64-pc-windows-gnu")


def rust_config(tool="rust-source", **changes):
    selection = dict(language="rust", source_subdir="project", source_entry="", source_package="",
                     local_path=str(rust_upstream), targets=["windows/amd64"],
                     target_triples={"windows/amd64": rust_target}, workspace_binaries_by_target={})
    selection.update(changes)
    return config(tool, **selection)


rust_config()
rust_generated, rust_source_runtime, rust_source_policy = generate("rust-source", "generate-rust-source")
check("public generator embeds Windows Rust source selectors and the complete Cargo family", rust_generated.returncode == 0 and
      rust_source_policy.get("source") == {"language": "rust", "subdir": "project", "package": ""} and
      rust_source_policy["platforms"]["windows/amd64"]["binaries"] == ["app.exe", "helper.exe"],
      rust_generated.stderr.decode(errors="replace"))
if rust_generated.returncode:
    raise SystemExit(1)


def invoke_rust(label, *, selected_runtime=rust_source_runtime, extra=None, **changes):
    selected_env = {"CARGO_NET_OFFLINE": "true"}
    selected_env.update(extra or {})
    return invoke(label, selected_runtime=selected_runtime, repository_url=rust_upstream.as_uri(), extra=selected_env, **changes)


if options.rust_baseline_project:
    old_generated, old_runtime, old_policy = generate("rust-source", "generate-rust-baseline",
        checkout=options.rust_baseline_project.resolve(), destination=root / "rust-baseline-generated")
    old, _, old_fixture = invoke_rust("rust-baseline-source", selected_runtime=old_runtime)
    check("frozen baseline lacks the Rust source route while retaining identical release policy",
          old_generated.returncode == 0 and old_policy == {key: value for key, value in rust_source_policy.items() if key != "source"} and
          old.returncode == 4 and not calls(old_fixture) and not Path(old_fixture["parameters"]["Prefix"]).exists())

rust_tagged, rust_result, rust_fixture = invoke_rust("rust-tagged", extra={
    "CARGO_BUILD_TARGET": "invalid-ambient-target", "RUSTFLAGS": "--invalid-ambient-option",
    "CARGO_ENCODED_RUSTFLAGS": "--invalid-encoded-option", "RUSTC_WRAPPER": "/nonexistent-rust-wrapper",
    "CARGO_TARGET_DIR": str(root / "ambient-cargo-target"),
})
check("Rust source installs a real Windows PE family from the pinned annotated tag", rust_tagged.returncode == 0,
      rust_tagged.stderr.decode(errors="replace"))
if rust_tagged.returncode:
    raise SystemExit(1)
rust_prefix = Path(rust_fixture["parameters"]["Prefix"])
check("Rust source pins the older tag despite HEAD advancement and reports its explicit Cargo target",
      rust_result["source"]["source_commit"] == rust_first_commit and rust_first_commit != rust_second_commit and
      rust_result["cargo_target"] == rust_target and rust_result["source"]["cargo_target"] == rust_target and
      rust_result["source"]["release_target_triple"] == rust_target and "go_target" not in rust_result)
check("Rust compiler metadata resolves the non-default workspace companion and binds every installed PE",
      {row["name"]: row["package"] for row in rust_result["source"]["source_entries"]} ==
      {"app.exe": "primary-provider", "helper.exe": "worker-provider"} and all(
          machine(rust_prefix / row["name"]) == 0x8664 and digest(rust_prefix / row["name"]) == row["sha256"] and
          (rust_prefix / row["name"]).stat().st_size == row["size_bytes"] for row in rust_result["binaries"]))
rust_builds = [row["arguments"] for row in calls(rust_fixture) if row["arguments"][0] == "build"]
check("one locked Cargo invocation builds all selected workspace executables into private output",
      len(rust_builds) == 1 and "--locked" in rust_builds[0] and "--workspace" in rust_builds[0] and
      "--target" in rust_builds[0] and rust_target in rust_builds[0] and rust_builds[0].count("--bin") == 2 and
      not (root / "ambient-cargo-target").exists() and no_http(rust_fixture))
rust_receipt = Path(rust_result["source_receipt"]["path"])
check("Rust receipts retain real compiler identities and explicitly unsigned byte evidence",
      rust_result["source"]["compiler"].startswith("rustc ") and rust_result["source"]["cargo_version"].startswith("cargo ") and
      rust_result["signed_release"] is False and rust_result["signature_verified"] is False and
      rust_result["source"]["signed_release"] is False and json.loads(rust_receipt.read_text()) == rust_result["source"] and
      digest(rust_receipt) == rust_result["source_receipt"]["sha256"])
previous_rust = {row["name"]: (rust_prefix / row["name"]).read_bytes() for row in rust_result["binaries"]}
rust_head, rust_head_result, _ = invoke_rust("rust-head", parameters={"SourceRef": "HEAD", "Prefix": str(rust_prefix)})
check("Rust HEAD upgrades the existing family through the shared transaction",
      rust_head.returncode == 0 and rust_head_result["source"]["source_commit"] == rust_second_commit and
      (rust_prefix / "app.exe").read_bytes() != previous_rust["app.exe"], rust_head.stderr.decode(errors="replace"))

# Remove only the fixture's index entry, leaving its file intact. The fetched
# commit genuinely has no Cargo.lock; later fixture commits can re-add it.
required(["git", "-C", rust_upstream, "update-index", "--force-remove", "project/Cargo.lock"], "rust-untrack-lock")
required(["git", "-C", rust_upstream, "commit", "--quiet", "-m", "Fixture missing committed lock"], "rust-commit-no-lock")
no_lock_commit = required(["git", "-C", rust_upstream, "rev-parse", "HEAD"], "rust-pin-no-lock")
missing_lock, _, fixture = invoke_rust("rust-missing-lock", parameters={"SourceRef": no_lock_commit})
check("a missing committed Cargo.lock refuses before compilation or installation", missing_lock.returncode != 0 and
      not any(row["arguments"][0] == "build" for row in calls(fixture)) and
      not Path(fixture["parameters"]["Prefix"]).exists() and no_http(fixture))

(rust_upstream / "project/worker/src/main.rs").write_text("fn main() { this is a genuine Rust compiler error }\n")
required(["git", "-C", rust_upstream, "add", "."], "rust-add-compiler-error")
required(["git", "-C", rust_upstream, "commit", "--quiet", "-m", "Fixture failing companion"], "rust-commit-compiler-error")
bad_rust_commit = required(["git", "-C", rust_upstream, "rev-parse", "HEAD"], "rust-pin-compiler-error")
prefix, before = seed_prefix("rust-compiler-failure")
bad_rust, bad_rust_result, fixture = invoke_rust("rust-compiler-failure", parameters={"SourceRef": bad_rust_commit, "Prefix": str(prefix)})
check("a real companion compiler failure preserves every previous executable and private diagnostics",
      bad_rust.returncode == 6 and all((prefix / name).read_bytes() == data for name, data in before.items()) and
      any(row["arguments"][0] == "build" for row in calls(fixture)) and
      Path(bad_rust_result.get("source_diagnostics", "/nonexistent")).is_dir() and no_http(fixture),
      bad_rust.stderr.decode(errors="replace"))

(rust_upstream / "project/worker/src/main.rs").write_text(rust_files["project/worker/src/main.rs"])
(rust_upstream / "project/Cargo.toml").write_text(rust_files["project/Cargo.toml"].replace('["primary", "worker"]', '["primary", "worker", "duplicate"]'))
(rust_upstream / "project/duplicate/src").mkdir(parents=True)
(rust_upstream / "project/duplicate/Cargo.toml").write_text(rust_files["project/primary/Cargo.toml"].replace("primary-provider", "duplicate-provider"))
(rust_upstream / "project/duplicate/src/main.rs").write_text('fn main() { println!("wrong provider"); }\n')
required(["cargo", "generate-lockfile", "--offline", "--manifest-path", rust_upstream / "project/Cargo.toml"], "rust-duplicate-lock")
required(["git", "-C", rust_upstream, "add", "."], "rust-add-duplicate")
required(["git", "-C", rust_upstream, "commit", "--quiet", "-m", "Fixture ambiguous Cargo provider"], "rust-commit-duplicate")
duplicate_commit = required(["git", "-C", rust_upstream, "rev-parse", "HEAD"], "rust-pin-duplicate")
duplicate_rust, _, fixture = invoke_rust("rust-duplicate", parameters={"SourceRef": duplicate_commit})
check("ambiguous workspace binary providers refuse before the first compilation",
      duplicate_rust.returncode == 6 and b"exactly one source provider" in duplicate_rust.stderr and
      not any(row["arguments"][0] == "build" for row in calls(fixture)) and not Path(fixture["parameters"]["Prefix"]).exists())
rust_config("rust-primary", source_package="primary-provider", workspace_binaries=["app"])
primary_generated, primary_runtime, primary_policy = generate("rust-primary", "generate-rust-primary")
primary_rust, primary_result, fixture = invoke_rust("rust-primary", selected_runtime=primary_runtime,
    parameters={"SourceRef": duplicate_commit})
check("source_package selects its actual package even when another workspace member has the same binary name",
      primary_generated.returncode == 0 and primary_rust.returncode == 0 and primary_result["source"]["source_package"] == "primary-provider" and
      [row["name"] for row in primary_result["binaries"]] == ["app.exe"], primary_rust.stderr.decode(errors="replace"))
rust_config("rust-restricted", source_package="primary-provider")
restricted_generated, restricted_runtime, _ = generate("rust-restricted", "generate-rust-restricted")
restricted_rust, _, fixture = invoke_rust("rust-restricted", selected_runtime=restricted_runtime)
check("source_package cannot borrow a requested companion from another package", restricted_generated.returncode == 0 and
      restricted_rust.returncode == 6 and not any(row["arguments"][0] == "build" for row in calls(fixture)) and
      not Path(fixture["parameters"]["Prefix"]).exists())

(rust_upstream / "project/primary/Cargo.toml").write_text(rust_files["project/primary/Cargo.toml"].replace('version = "0.1.0"', 'version = "0.2.0"'))
required(["git", "-C", rust_upstream, "add", "."], "rust-add-stale-lock")
required(["git", "-C", rust_upstream, "commit", "--quiet", "-m", "Fixture stale Cargo lock"], "rust-commit-stale-lock")
stale_commit = required(["git", "-C", rust_upstream, "rev-parse", "HEAD"], "rust-pin-stale-lock")
stale_rust, stale_result, fixture = invoke_rust("rust-stale-lock", selected_runtime=primary_runtime,
    parameters={"SourceRef": stale_commit})
check("locked Cargo compilation refuses dependency-resolution changes without installing",
      stale_rust.returncode == 6 and not Path(fixture["parameters"]["Prefix"]).exists() and
      Path(stale_result.get("source_diagnostics", "/nonexistent")).is_dir(), stale_rust.stderr.decode(errors="replace"))
for label, injection, expected in (
    ("rust-source-drift", {"mutate_source": True, "mutate_source_member": "primary/src/main.rs"}, 7),
    ("rust-output-drift", {"mutate_output": True}, 7),
    ("rust-rollback", {"move_fault": True}, 7),
):
    prefix, before = seed_prefix(label)
    refused, result, fixture = invoke_rust(label, parameters={"Prefix": str(prefix)}, **injection)
    check(label + " refuses and preserves the complete previous family", refused.returncode == expected and
          all((prefix / name).read_bytes() == data for name, data in before.items()) and
          not (prefix / ".dsr-windows-install.pending.json").exists() and
          Path(result.get("source_diagnostics", "/nonexistent")).is_dir() and no_http(fixture),
          refused.stderr.decode(errors="replace"))

published_rust = rust_source_runtime.read_bytes()
rust_config(source_package="../invalid-package")
invalid_package, _, _ = generate("rust-source", "generate-invalid-rust-package")
check("invalid Rust package selection cannot replace a published installer", invalid_package.returncode != 0 and
      rust_source_runtime.read_bytes() == published_rust)

# Real parent/descendant process fixture, portable across supported Go hosts.
# The child intentionally inherits stdout/stderr after its parent exits. It
# finishes naturally; this proves bounded installer return, not orphan cleanup.
probe_source = root / "pipe-probe.go"
probe_source.write_text('''package main
import ("fmt"; "os"; "os/exec"; "time")
func main() {
    if len(os.Args) > 1 { time.Sleep(3*time.Second); return }
    child := exec.Command(os.Args[0], "child")
    child.Stdout = os.Stdout; child.Stderr = os.Stderr
    if err := child.Start(); err != nil { panic(err) }
    fmt.Print("parent-exited")
}
''')
probe = root / ("pipe-probe.exe" if sys.platform == "win32" else "pipe-probe")
host_env = json.loads(required(["go", "env", "-json", "GOHOSTOS", "GOHOSTARCH"], "go-host"))
required(["go", "build", "-o", probe, probe_source], "build-pipe-probe",
         extra={"GOOS": host_env["GOHOSTOS"], "GOARCH": host_env["GOHOSTARCH"], "GOFLAGS": ""})
timed, timed_result, _ = invoke("inherited-pipe-timeout", pipe_probe=str(probe), probe_directory=str(root), probe_log=str(root / "pipe-probe-command"))
check("source command deadline also bounds inherited output pipes after the real parent exits", timed.returncode == 5 and
      800 <= timed_result.get("elapsed_ms", 0) < 2500, timed.stdout.decode(errors="replace") + timed.stderr.decode(errors="replace"))

print(f"Windows source installation checks: {passed} passed, {failed} failed", flush=True)
raise SystemExit(1 if failed else 0)
PY
