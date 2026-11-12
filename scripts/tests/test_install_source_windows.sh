#!/usr/bin/env bash
# Genuine generated source installation: real Git pins, Rust/Go/Bun Windows PE
# families, retained receipts and the ordinary installation transaction. The
# portable fixture adapts host detection and Git/HTTP transport only; it does
# not claim live GitHub, native Windows ACL/NTFS or Windows process acceptance.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
dependencies=(pwsh git go cargo rustc minisign python3 jq yq)
if [[ " $* " == *' --bun-only '* || " $* " == *' --bun-workspaces-only '* ]]; then
    dependencies=(pwsh git bun minisign python3 jq yq)
elif [[ " $* " == *' --freshness-only '* || " $* " == *' --go-only '* || " $* " == *' --go-workspace-only '* ]]; then
    dependencies=(pwsh git go minisign python3 jq yq)
fi
for dependency in "${dependencies[@]}"; do
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

arguments = argparse.ArgumentParser(description="Generated Windows Rust/Go/Bun source installation regression")
arguments.add_argument("project", type=Path)
arguments.add_argument("--baseline-project", type=Path, help="Frozen checkout before Windows source installation")
arguments.add_argument("--rust-baseline-project", type=Path, help="Frozen checkout before Windows Rust source installation")
arguments.add_argument("--workspace-baseline-project", type=Path, help="Frozen checkout before committed Go workspace support")
arguments.add_argument("--go-workspace-only", action="store_true", help="Run the generated Go workspace caller regression")
arguments.add_argument("--go-only", action="store_true", help="Run Go source and signed-release controls without Rust compilation")
arguments.add_argument("--bun-only", action="store_true", help="Run genuine Bun/TypeScript Windows source installation controls")
arguments.add_argument("--bun-workspaces-only", action="store_true", help="Run generated Bun workspace source installation controls")
arguments.add_argument("--bun-baseline-project", type=Path, help="Frozen checkout before Windows Bun source installation")
arguments.add_argument("--freshness-only", action="store_true", help="Run signed release-first freshness and pinned source-upgrade controls")
arguments.add_argument("--freshness-baseline-project", type=Path, help="Frozen checkout before Windows freshness source upgrades")
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


runtime = None
policy = None
if not options.bun_only and not options.bun_workspaces_only:
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
        [IO.File]::AppendAllText($script:Fixture.commands, ((@{ executable = $Executable; arguments = @($Arguments); directory = $Directory;
            go_environment = @{ GOWORK = $Environment['GOWORK']; GOENV = $Environment['GOENV'];
                GOFLAGS = $Environment['GOFLAGS']; GO111MODULE = $Environment['GO111MODULE'];
                GOTOOLCHAIN = $Environment['GOTOOLCHAIN'] };
            bun_environment = @{ NODE_OPTIONS = $Environment['NODE_OPTIONS']; BUN_OPTIONS = $Environment['BUN_OPTIONS'] }
        } | ConvertTo-Json -Compress) + "`n"))
        $result = & $script:RealSourceCommand @PSBoundParameters
        if ($script:Fixture.Contains('inject_untracked_workspace') -and $script:Fixture.inject_untracked_workspace -and
            'checkout' -cin $Arguments) {
            [IO.File]::WriteAllText([IO.Path]::Combine($Directory, 'go.work'), "go 1.22`nuse ./project`n")
        }
        if ($script:Fixture.Contains('inject_untracked_vendor') -and $script:Fixture.inject_untracked_vendor -and
            'checkout' -cin $Arguments) {
            $vendor = [IO.Path]::Combine($Directory, 'vendor')
            $null = [IO.Directory]::CreateDirectory($vendor)
            [IO.File]::WriteAllText([IO.Path]::Combine($vendor, 'modules.txt'), "## workspace`n")
        }
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
if ($fixture.Contains('http_client_fixture') -and $fixture.http_client_fixture) {
    # The source upgrade fixture keeps actual request construction, credential
    # selection, response checks, deadlines and streaming. Only HTTP delivery
    # is adapted, just as the existing release integration fixture does.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
public sealed class DsrSourceFixtureHandler : HttpMessageHandler {
    private readonly JsonElement fixture;
    public DsrSourceFixtureHandler(string path) {
        using (JsonDocument document = JsonDocument.Parse(File.ReadAllText(path))) {
            fixture = document.RootElement.Clone();
        }
    }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        token.ThrowIfCancellationRequested();
        string url = request.RequestUri.AbsoluteUri;
        string authorization = request.Headers.Authorization == null ? "" : request.Headers.Authorization.Parameter;
        string authorizationHash = authorization.Length == 0 ? "" : Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(authorization))).ToLowerInvariant();
        File.AppendAllText(fixture.GetProperty("requests").GetString(), JsonSerializer.Serialize(new {
            url, authorization_sha256 = authorizationHash,
            authorization_scheme = request.Headers.Authorization == null ? "" : request.Headers.Authorization.Scheme,
            method = request.Method.Method, accept = request.Headers.Accept.ToString(),
            user_agent = request.Headers.UserAgent.ToString()
        }) + "\n");
        if (fixture.TryGetProperty("expected_token", out JsonElement expected) && request.RequestUri.Host == "api.github.com" &&
            authorization != expected.GetString()) {
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized));
        }
        if (request.RequestUri.Host != "api.github.com" && authorization.Length != 0) {
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadRequest));
        }
        if (fixture.TryGetProperty("transport_failures", out JsonElement failures) && failures.TryGetProperty(url, out JsonElement failure)) {
            if (failure.GetString() == "timeout") { throw new OperationCanceledException("Injected response deadline"); }
            throw new HttpRequestException("Injected HTTPS transport failure");
        }
        if (fixture.TryGetProperty("statuses", out JsonElement statuses) && statuses.TryGetProperty(url, out JsonElement status)) {
            return Task.FromResult(new HttpResponseMessage((HttpStatusCode)status.GetInt32()));
        }
        if (fixture.TryGetProperty("redirects", out JsonElement redirects) && redirects.TryGetProperty(url, out JsonElement location)) {
            var response = new HttpResponseMessage(HttpStatusCode.Redirect);
            response.Headers.Location = new Uri(location.GetString(), UriKind.RelativeOrAbsolute);
            return Task.FromResult(response);
        }
        if (fixture.GetProperty("downloads").TryGetProperty(url, out JsonElement source)) {
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) {
                Content = new ByteArrayContent(File.ReadAllBytes(source.GetString()))
            });
        }
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound));
    }
}
'@
    $script:FixturePath = $CasePath
    function New-DsrHttpClient {
        $client = [Net.Http.HttpClient]::new([DsrSourceFixtureHandler]::new($script:FixturePath), $true)
        $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
        return $client
    }
} else {
    function Invoke-DsrDownload {
        param([string]$Url, [string]$Destination, [switch]$Optional, [long]$MaximumBytes = 2147483648,
              [switch]$ApiAsset, [switch]$SourceMetadata)
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


def test_release_freshness():
    tagged, tagged_result, tagged_fixture = invoke("freshness-release-source")
    check("real Go compilation supplies the pinned annotated-tag release family", tagged.returncode == 0 and
          tagged_result.get("source", {}).get("source_commit") == first_commit,
          tagged.stderr.decode(errors="replace"))
    if tagged.returncode:
        return
    release_prefix = Path(tagged_fixture["parameters"]["Prefix"])
    original = {name: digest(release_prefix / name) for name in ("app.exe", "helper.exe")}
    asset = policy["platforms"]["windows/amd64"]["name"].replace("${version}", "1.2.3")
    api = "https://api.github.com/repos/fixture/source-demo"
    head_url = api + "/commits?per_page=1"
    base_url = api + "/commits/tags%2Fv1.2.3"
    compare_url = api + "/compare/" + first_commit + "..." + second_commit + "?per_page=1"

    def metadata(name, value, *, raw=False):
        path = root / ("freshness-" + name + ".json")
        path.write_text(value if raw else json.dumps(value))
        return str(path)

    def release(label, kind="good"):
        directory = root / ("freshness-release-" + label)
        directory.mkdir()
        archive = directory / asset
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
            for name in original:
                data = (release_prefix / name).read_bytes()
                if kind == "wrong-machine" and name == "app.exe":
                    data = bytearray(data)
                    offset = struct.unpack_from("<I", data, 60)[0]
                    struct.pack_into("<H", data, offset + 4, 0xAA64)
                package.writestr(name, data)
            if kind == "unsafe-archive":
                package.writestr("../escape.exe", b"untrusted member")
        checksum = directory / "SHA256SUMS"
        checksum.write_text(("0" * 64 if kind == "bad-checksum" else digest(archive)) + "  " + asset + "\n")
        signature = directory / (asset + ".minisig")
        required(["minisign", "-S", "-s", root / "key.sec", "-m", archive, "-x", signature], "sign-freshness-" + label)
        if kind == "bad-signature":
            signature.write_text("invalid signature fixture\n")
        base = "https://github.com/fixture/source-demo/releases/download/v1.2.3/"
        downloads = {base + path.name: str(path) for path in (archive, checksum, signature)}
        downloads[api + "/releases/latest"] = metadata(label + "-release", {
            "id": 4242, "tag_name": "v1.2.3", "draft": False, "prerelease": False})
        rows = []
        for index, path in enumerate((archive, checksum, signature), start=1):
            rows.append({"id": index, "name": path.name, "state": "uploaded", "size": path.stat().st_size})
            downloads[api + "/releases/assets/" + str(index)] = str(path)
        downloads[api + "/releases/4242/assets?per_page=100&page=1"] = metadata(label + "-assets", rows)
        return downloads

    comparison = {"base_commit": {"sha": first_commit}, "merge_base_commit": {"sha": first_commit},
                  "ahead_by": 1, "behind_by": 0, "total_commits": 1, "status": "ahead", "commits": []}
    downloads = release("good")
    downloads.update({head_url: metadata("head", [{"sha": second_commit}]),
                      base_url: metadata("base", {"sha": first_commit}),
                      compare_url: metadata("compare", comparison)})
    parameters = {"FromSource": False, "SourceRef": "", "SourceTimeout": 60,
                  "AllowSourceBuild": True, "SourceIfStale": 0}

    def run(label, *, params=None, selected=runtime, payload=None, **changes):
        selected_params = dict(parameters)
        selected_params.update(params or {})
        return invoke("freshness-" + label, parameters=selected_params, selected_runtime=selected,
                      downloads=downloads if payload is None else payload, http_client_fixture=True, **changes)

    def requests(fixture):
        path = Path(fixture["requests"])
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def release_installed(result, fixture):
        prefix = Path(fixture["parameters"]["Prefix"])
        return result.get("version") == "v1.2.3" and result.get("signature_verified") is True and \
            all((prefix / name).is_file() and digest(prefix / name) == value for name, value in original.items())

    if options.freshness_baseline_project:
        prior, prior_runtime, prior_policy = generate("source-demo", "freshness-baseline-generate",
            checkout=options.freshness_baseline_project.resolve(), destination=root / "freshness-baseline-generated")
        before, _, before_fixture = run("baseline", selected=prior_runtime)
        check("same fixture proves frozen baseline lacks opt-in stale-release upgrade", prior.returncode == 0 and
              prior_policy == policy and before.returncode != 0 and b"AllowSourceBuild" in before.stderr and
              not calls(before_fixture) and no_http(before_fixture))

    ordinary, ordinary_result, ordinary_fixture = run("ordinary", params={"AllowSourceBuild": False,
        "SourceIfStale": None, "SourceTimeout": 3600})
    check("ordinary latest mode verifies the signed family without freshness requests or source execution",
          ordinary.returncode == 0 and release_installed(ordinary_result, ordinary_fixture) and not calls(ordinary_fixture) and
          head_url not in [row["url"] for row in requests(ordinary_fixture)], ordinary.stderr.decode(errors="replace"))
    if ordinary.returncode:
        return
    installed_prefix = Path(ordinary_fixture["parameters"]["Prefix"])
    fresh, fresh_result, fresh_fixture = run("threshold", params={"SourceIfStale": 1})
    check("distance equal to the threshold keeps actual signed release bytes without compiling",
          fresh.returncode == 0 and release_installed(fresh_result, fresh_fixture) and not calls(fresh_fixture) and
          fresh_result.get("freshness", {}).get("status") == "fresh" and
          fresh_result["freshness"].get("commits_behind") == 1, fresh.stderr.decode(errors="replace"))

    # Real upstream advances after the observed API head. Source installation
    # must fetch the exact observed second commit, never resolve HEAD again.
    (upstream / "project/apps/primary/main.go").write_text(files["project/apps/primary/main.go"].replace("v1", "v3"))
    required(["git", "-C", upstream, "add", "."], "freshness-moving-head-add")
    required(["git", "-C", upstream, "commit", "--quiet", "-m", "Head moves after freshness observation"], "freshness-moving-head-commit")
    advanced_head = required(["git", "-C", upstream, "rev-parse", "HEAD"], "freshness-moving-head-pin")
    token = "dsr-freshness-private-fixture"
    credentials = {"DSR_GH_TOKEN": token, "GITHUB_TOKEN": "fixture-other-github", "GH_TOKEN": "fixture-other-gh"}
    stale, stale_result, stale_fixture = run("stale-private", extra=credentials, expected_token=token)
    check("verified stale private release builds the exact observed pin after the live branch advances",
          stale.returncode == 0 and stale_result.get("method") == "source" and
          stale_result.get("source", {}).get("source_commit") == second_commit and advanced_head != second_commit and
          stale_result["source"].get("requested_ref") == second_commit, stale.stderr.decode(errors="replace"))
    if stale.returncode:
        return
    source_prefix = Path(stale_fixture["parameters"]["Prefix"])
    check("real compiled x64 PE family contains the observed source and binds every installed byte",
          {row["name"] for row in stale_result["binaries"]} == set(original) and
          b"primary-v2" in (source_prefix / "app.exe").read_bytes() and
          b"primary-v3" not in (source_prefix / "app.exe").read_bytes() and all(
              machine(source_prefix / row["name"]) == 0x8664 and digest(source_prefix / row["name"]) == row["sha256"] and
              (source_prefix / row["name"]).stat().st_size == row["size_bytes"] for row in stale_result["binaries"]))
    check("source upgrade records comparison and durable unsigned provenance without the old release version",
          stale_result.get("signed_release") is False and stale_result.get("signature_verified") is False and
          "version" not in stale_result and stale_result["freshness"] == {
              "status": "stale", "repository": "fixture/source-demo", "release_version": "v1.2.3",
              "release_commit": first_commit, "head_commit": second_commit, "commits_behind": 1, "threshold": 0} and
          json.loads(Path(stale_result["source_receipt"]["path"]).read_text()) == stale_result["source"])
    observed = requests(stale_fixture)
    credential_hash = hashlib.sha256(token.encode()).hexdigest()
    check("private release and all three freshness requests use only the selected repository credential",
          all(row["authorization_sha256"] == credential_hash and row["authorization_scheme"] == "Bearer" and
              row["url"].startswith(api + "/") for row in observed) and
          [row["url"] for row in observed][-3:] == [head_url, base_url, compare_url] and
          all("doodlestein_self_releaser" in row["user_agent"] for row in observed) and
          token not in (stale.stdout + stale.stderr).decode(errors="replace") and
          token not in Path(stale_fixture["commands"]).read_text())
    fetches = [row["arguments"] for row in calls(stale_fixture) if "fetch" in row["arguments"]]
    check("actual Git fetch receives the immutable observed SHA and no moving source selector",
          len(fetches) == 1 and fetches[0][-1] == second_commit and "HEAD" not in fetches[0])

    unknowns = [
        ("denied", None, None, {"statuses": {head_url: 403}}),
        ("empty-head", head_url, [], {}),
        ("object-head", head_url, {"sha": second_commit}, {}),
        ("invalid-tag", base_url, {"sha": "not-a-commit"}, {}),
        ("diverged", compare_url, {**comparison, "status": "diverged", "behind_by": 1}, {}),
        ("wrong-base", compare_url, {**comparison, "merge_base_commit": {"sha": second_commit}}, {}),
        ("wrong-count", compare_url, {**comparison, "total_commits": 2}, {}),
        ("boolean-count", compare_url, {**comparison, "ahead_by": True}, {}),
        ("duplicate-keys", compare_url, '{"status":"ahead","status":"identical"}', {"raw": True}),
        ("redirect", None, None, {"redirects": {head_url: "https://example.invalid/untrusted-source"}}),
        ("transport-timeout", None, None, {"transport_failures": {head_url: "timeout"}}),
    ]
    for label, url, value, controls in unknowns:
        selected = dict(downloads)
        controls = dict(controls)
        if url:
            selected[url] = metadata(label, value, raw=controls.pop("raw", False))
        outcome, result, fixture = run("unknown-" + label, payload=selected, **controls)
        check(label + " metadata keeps the verified release and never starts Git or a compiler",
              outcome.returncode == 0 and release_installed(result, fixture) and not calls(fixture) and
              result.get("freshness", {}).get("status") == "unknown" and
              all(row["url"].startswith(api + "/") or row["url"].startswith("https://github.com/fixture/source-demo/")
                  for row in requests(fixture)), outcome.stderr.decode(errors="replace"))

    for label, values in (
        ("missing-consent", {"AllowSourceBuild": False}), ("missing-threshold", {"SourceIfStale": None}),
        ("exact-version", {"Version": "v1.2.3"}), ("offline", {"Offline": True}),
        ("explicit-source", {"FromSource": True}), ("moving-selector", {"SourceRef": "HEAD"}),
        ("negative-threshold", {"SourceIfStale": -1}), ("large-threshold", {"SourceIfStale": 1000000}),
        ("invalid-timeout", {"SourceTimeout": 0}), ("recovery", {"Recover": True}),
    ):
        refused, _, fixture = run("invalid-" + label, params=values)
        check(label + " is refused before HTTP, Git, compilation or installation", refused.returncode == 4 and
              no_http(fixture) and not calls(fixture) and not Path(fixture["parameters"]["Prefix"]).exists(),
              refused.stderr.decode(errors="replace"))
    for kind in ("bad-checksum", "bad-signature", "unsafe-archive", "wrong-machine"):
        selected = dict(downloads)
        selected.update(release(kind, kind))
        refused, _, fixture = run(kind, payload=selected, params={"Prefix": str(installed_prefix)})
        check(kind + " refuses before freshness and preserves every previously installed executable",
              refused.returncode == 7 and not calls(fixture) and
              head_url not in [row["url"] for row in requests(fixture)] and
              all(digest(installed_prefix / name) == value for name, value in original.items()),
              refused.stderr.decode(errors="replace"))
    rolled_back, rolled_result, _ = run("rollback", params={"Prefix": str(installed_prefix)}, move_fault=True)
    check("failed source-family replacement restores every old executable and retains source diagnostics",
          rolled_back.returncode == 7 and all(digest(installed_prefix / name) == value for name, value in original.items()) and
          Path(rolled_result.get("source_diagnostics", "/nonexistent")).is_dir() and
          rolled_result.get("freshness", {}).get("status") == "stale", rolled_back.stderr.decode(errors="replace"))


if options.freshness_only:
    test_release_freshness()
    print(f"Windows release freshness checks: {passed} passed, {failed} failed", flush=True)
    print("Portable PowerShell, real Git/Go/Minisign and adapted HTTP delivery; native Windows and live GitHub remain unqualified.", flush=True)
    raise SystemExit(1 if failed else 0)


def test_bun_sources():
    bun_upstream = root / "bun-upstream"
    bun_upstream.mkdir()
    required(["git", "init", "--quiet", "--initial-branch=main", bun_upstream], "bun-git-init")
    required(["git", "-C", bun_upstream, "config", "user.email", "fixture@example.invalid"], "bun-git-email")
    required(["git", "-C", bun_upstream, "config", "user.name", "DSR Bun Source Fixture"], "bun-git-name")
    manifest = {"name": "dsr-bun-source", "version": "1.0.0", "bin": {"helper": "./src/helper.ts", "arm-helper": "src/arm-helper.ts"},
                "dependencies": {"local-fixture": "file:./local-fixture"}}
    sources = {"project/package.json": json.dumps(manifest),
               "project/src/primary.ts": 'import { value } from "local-fixture"; console.log("pinned-bun-primary-v1", value);\n',
               "project/src/helper.ts": 'console.log("pinned-bun-helper-v1");\n',
               "project/src/arm-helper.ts": 'console.log("pinned-bun-arm-helper-v1");\n',
               "project/local-fixture/package.json": json.dumps({"name": "local-fixture", "version": "1.0.0", "main": "index.ts"}),
               "project/local-fixture/index.ts": 'export const value = "committed-bun-dependency";\n',
               "project/other-dependency/package.json": json.dumps({"name": "local-fixture", "version": "2.0.0", "main": "index.ts"}),
               "project/other-dependency/index.ts": 'export const value = "other-committed-dependency";\n',
               ".gitignore": "node_modules/\n"}
    for name, value in sources.items():
        path = bun_upstream / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
    required(["bun", "install", "--lockfile-only"], "bun-lock", cwd=bun_upstream / "project")
    required(["git", "-C", bun_upstream, "add", "."], "bun-add")
    required(["git", "-C", bun_upstream, "commit", "--quiet", "-m", "Pinned Bun source family"], "bun-commit")
    commit = required(["git", "-C", bun_upstream, "rev-parse", "HEAD"], "bun-pin")
    required(["git", "-C", bun_upstream, "tag", "-a", "v1.2.3", "-m", "Bun source release"], "bun-tag")
    config("bun-source", language="bun", local_path=str(bun_upstream), source_entry="src/primary.ts")
    generated_bun, bun_runtime, bun_policy = generate("bun-source", "bun-generate")
    check("public generator embeds Bun source entry and target-specific executable families",
          generated_bun.returncode == 0 and bun_policy.get("source") ==
          {"language": "bun", "subdir": "project", "entry": "src/primary.ts"}, generated_bun.stderr.decode(errors="replace"))
    if generated_bun.returncode:
        return
    if options.bun_baseline_project:
        prior, prior_runtime, prior_policy = generate("bun-source", "bun-baseline-generate",
            checkout=options.bun_baseline_project.resolve(), destination=root / "bun-baseline-generated")
        before, before_result, before_fixture = invoke("bun-baseline", selected_runtime=prior_runtime,
            repository_url=bun_upstream.as_uri())
        release_policy = copy.deepcopy(bun_policy)
        release_policy.pop("source")
        check("same caller's frozen baseline has no Bun source route and identical release policy",
              prior.returncode == 0 and prior_policy == release_policy and before.returncode == 4 and
              "source policy" in before_result.get("error", "") and not calls(before_fixture) and no_http(before_fixture))
    built, result, fixture = invoke("bun-pinned-family", selected_runtime=bun_runtime,
        repository_url=bun_upstream.as_uri(), extra={"NODE_OPTIONS": "--require=/missing/ambient-preload.js",
                                                   "BUN_OPTIONS": "--preload=/missing/ambient-bun-preload.ts"})
    check("real frozen Bun dependency install compiles the complete pinned x64 source family",
          built.returncode == 0 and result.get("method") == "source" and result.get("source", {}).get("source_commit") == commit and
          result.get("bun_target") == "bun-windows-x64-baseline" and no_http(fixture), built.stderr.decode(errors="replace"))
    if built.returncode:
        return
    prefix = Path(fixture["parameters"]["Prefix"])
    old_family = {row["name"]: digest(prefix / row["name"]) for row in result["binaries"]}
    check("real Windows PE payloads retain compiled primary, companion and dependency bytes with exact receipts",
          set(old_family) == {"app.exe", "helper.exe"} and all(machine(prefix / row["name"]) == 0x8664 and
          digest(prefix / row["name"]) == row["sha256"] and (prefix / row["name"]).stat().st_size == row["size_bytes"]
          for row in result["binaries"]) and b"pinned-bun-primary-v1" in (prefix / "app.exe").read_bytes() and
          b"committed-bun-dependency" in (prefix / "app.exe").read_bytes() and
          b"pinned-bun-helper-v1" in (prefix / "helper.exe").read_bytes())
    receipt = json.loads(Path(result["source_receipt"]["path"]).read_text())
    check("durable Bun source receipt binds lockfile, manifest, compiler, target and every provider",
          receipt == result["source"] and receipt["signed_release"] is False and
          receipt["language"] == "bun" and "cargo_target" not in receipt and "go_target" not in receipt and
          receipt["source_entries"] == [{"name": "app.exe", "entry": "src/primary.ts"}, {"name": "helper.exe", "entry": "src/helper.ts"}] and
          receipt["package_json_sha256"] == digest(bun_upstream / "project/package.json") and
          receipt["bun_lockfiles"][0]["sha256"] == digest(bun_upstream / "project/bun.lock") and
          re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.+-]+)?", receipt["compiler"]) is not None)
    selected_calls = calls(fixture)
    check("Bun install uses frozen lock and each build uses an explicit private Windows target",
          sum(row["arguments"][:2] == ["install", "--frozen-lockfile"] for row in selected_calls) == 1 and
          sum(row["arguments"][:3] == ["build", "--compile", "--target=bun-windows-x64-baseline"] for row in selected_calls) == 2)
    bun_calls = [row for row in selected_calls if Path(row["executable"]).name.lower() in ("bun", "bun.exe")]
    check("actual Bun commands remove inherited Node and Bun preloads before execution",
          len(bun_calls) == 5 and all(row["bun_environment"] == {"NODE_OPTIONS": None, "BUN_OPTIONS": None} for row in bun_calls))
    config("typescript-source", language="typescript", local_path=str(bun_upstream), source_entry="src/primary.ts")
    typescript, ts_runtime, ts_policy = generate("typescript-source", "typescript-generate")
    arm, arm_result, arm_fixture = invoke("bun-arm64", selected_runtime=ts_runtime,
        repository_url=bun_upstream.as_uri(), platform="windows/arm64")
    check("TypeScript configuration builds actual ARM64-specific Windows executable family",
          typescript.returncode == 0 and ts_policy["source"]["language"] == "typescript" and arm.returncode == 0 and
          arm_result.get("bun_target") == "bun-windows-arm64" and
          {row["name"] for row in arm_result.get("binaries", [])} == {"app.exe", "arm-helper.exe"} and
          all(machine(Path(arm_fixture["parameters"]["Prefix"]) / row["name"]) == 0xAA64 for row in arm_result.get("binaries", [])),
          arm.stderr.decode(errors="replace"))
    for label, injection in (("bun-source-drift", {"mutate_source": True, "mutate_source_member": "src/primary.ts"}),
                             ("bun-output-drift", {"mutate_output": True}), ("bun-rollback", {"move_fault": True})):
        refused, _, _ = invoke(label, selected_runtime=bun_runtime, repository_url=bun_upstream.as_uri(),
            parameters={"Prefix": str(prefix)}, **injection)
        check(label + " preserves the entire previously installed executable family",
              refused.returncode == 7 and all(digest(prefix / name) == value for name, value in old_family.items()),
              refused.stderr.decode(errors="replace"))

    def changed_commit(label, content):
        (bun_upstream / "project/package.json").write_text(json.dumps(content))
        required(["git", "-C", bun_upstream, "add", "project"], label + "-add")
        required(["git", "-C", bun_upstream, "commit", "--quiet", "-m", label], label + "-commit")
        return required(["git", "-C", bun_upstream, "rev-parse", "HEAD"], label + "-pin")

    scalar_manifest = copy.deepcopy(manifest)
    scalar_manifest["bin"] = "./src/primary.ts"
    scalar_revision = changed_commit("bun-scalar-bin", scalar_manifest)
    config("bun-single", language="bun", local_path=str(bun_upstream), source_entry="",
           workspace_binaries=["app"], workspace_binaries_by_target={}, targets=["windows/amd64"])
    single_generated, single_runtime, _ = generate("bun-single", "bun-scalar-generate")
    single, single_result, single_fixture = invoke("bun-scalar-bin", selected_runtime=single_runtime,
        repository_url=bun_upstream.as_uri(), parameters={"SourceRef": scalar_revision})
    check("a scalar package bin supplies the primary entry without an explicit source_entry",
          single_generated.returncode == 0 and single.returncode == 0 and
          single_result.get("source", {}).get("source_entries") == [{"name": "app.exe", "entry": "src/primary.ts"}] and
          [row["name"] for row in single_result.get("binaries", [])] == ["app.exe"] and
          machine(Path(single_fixture["parameters"]["Prefix"]) / "app.exe") == 0x8664,
          single.stderr.decode(errors="replace"))

    release = root / "bun-signed-release"
    release.mkdir()
    asset = bun_policy["platforms"]["windows/amd64"]["name"].replace("${version}", "1.2.3")
    archive = release / asset
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
        for name in ("app.exe", "helper.exe"):
            package.write(prefix / name, name)
    checksum = release / (asset + ".sha256")
    checksum.write_text(digest(archive) + "  " + asset + "\n")
    signature = release / (asset + ".minisig")
    signature.write_text("invalid signature fixture\n")
    base = "https://github.com/fixture/bun-source/releases/download/v1.2.3/"
    downloads = {base + path.name: str(path) for path in (archive, checksum, signature)}
    release_parameters = {"FromSource": False, "SourceRef": "", "SourceTimeout": 3600,
                          "Version": "v1.2.3", "Prefix": str(prefix)}
    failed_release, _, release_fixture = invoke("bun-bad-signature", parameters=release_parameters,
        selected_runtime=bun_runtime, downloads=downloads)
    check("failed configured release signatures never invoke Bun source installation or replace installed bytes",
          failed_release.returncode == 7 and not calls(release_fixture) and
          all(digest(prefix / name) == value for name, value in old_family.items()),
          failed_release.stderr.decode(errors="replace"))

    for label, change in (("bun-missing-provider", {}), ("bun-escaping-provider", {"helper": "../outside.ts"}),
                          ("bun-invalid-provider", {"helper": ["src/helper.ts"]})):
        selected = copy.deepcopy(manifest)
        selected["bin"] = change
        revision = changed_commit(label, selected)
        refused, _, rejected_fixture = invoke(label, selected_runtime=bun_runtime, repository_url=bun_upstream.as_uri(),
            parameters={"Prefix": str(prefix), "SourceRef": revision})
        check(label + " fails before dependency installation or compilation and preserves installed bytes",
              refused.returncode == 4 and not any(row["arguments"][0] in ("install", "build") for row in calls(rejected_fixture)) and
              all(digest(prefix / name) == value for name, value in old_family.items()))
    selected = copy.deepcopy(manifest)
    selected["dependencies"]["local-fixture"] = "file:./other-dependency"
    revision = changed_commit("bun-stale-lock", selected)
    stale, stale_result, stale_fixture = invoke("bun-stale-lock", selected_runtime=bun_runtime, repository_url=bun_upstream.as_uri(),
        parameters={"Prefix": str(prefix), "SourceRef": revision})
    diagnostic_root = Path(stale_result.get("source_diagnostics", "/nonexistent")) / "logs"
    dependency_diagnostics = "\n".join(path.read_text(errors="replace") for path in
        (diagnostic_root / "dependencies.stdout", diagnostic_root / "dependencies.stderr") if path.is_file()).lower()
    check("a stale committed lock cannot update dependencies or reach compilation",
          stale.returncode == 6 and any(row["arguments"][:2] == ["install", "--frozen-lockfile"] for row in calls(stale_fixture)) and
          "frozen" in dependency_diagnostics and "lockfile" in dependency_diagnostics and
          not any(row["arguments"][0] == "build" for row in calls(stale_fixture)) and
          all(digest(prefix / name) == value for name, value in old_family.items()),
          dependency_diagnostics)
    unfrozen = root / "bun-unfrozen-control"
    required(["git", "clone", "--quiet", "--no-local", bun_upstream, unfrozen], "bun-unfrozen-clone")
    required(["git", "-C", unfrozen, "checkout", "--quiet", "--detach", revision], "bun-unfrozen-checkout")
    old_lock = digest(unfrozen / "project/bun.lock")
    unlocked_install = command(["bun", "install"], "bun-unfrozen-install", cwd=unfrozen / "project", extra={"CI": ""})
    check("the same valid dependency change succeeds and rewrites its lock when freezing is absent",
          unlocked_install.returncode == 0 and digest(unfrozen / "project/bun.lock") != old_lock,
          unlocked_install.stderr.decode(errors="replace"))
    (bun_upstream / "project/src/helper.ts").write_text('this is not valid TypeScript !!!\n')
    revision = changed_commit("bun-failed-companion", manifest)
    partial, _, partial_fixture = invoke("bun-failed-companion", selected_runtime=bun_runtime, repository_url=bun_upstream.as_uri(),
        parameters={"Prefix": str(prefix), "SourceRef": revision})
    check("genuine later companion compiler failure never activates the completed primary",
          partial.returncode == 6 and sum(row["arguments"][0] == "build" for row in calls(partial_fixture)) == 2 and
          all(digest(prefix / name) == value for name, value in old_family.items()))
    required(["git", "-C", bun_upstream, "update-index", "--force-remove", "project/bun.lock"], "bun-missing-lock-index")
    required(["git", "-C", bun_upstream, "commit", "--quiet", "-m", "Missing Bun lock"], "bun-missing-lock-commit")
    revision = required(["git", "-C", bun_upstream, "rev-parse", "HEAD"], "bun-missing-lock-pin")
    missing, _, missing_fixture = invoke("bun-missing-lock", selected_runtime=bun_runtime, repository_url=bun_upstream.as_uri(),
        parameters={"Prefix": str(prefix), "SourceRef": revision})
    check("missing committed Bun lock is refused before dependency or compiler execution",
          missing.returncode == 4 and not any(row["arguments"][0] in ("install", "build", "--version") for row in calls(missing_fixture)) and
          all(digest(prefix / name) == value for name, value in old_family.items()))


def test_bun_workspaces():
    workspace_upstream = root / "bun-workspace-upstream"
    workspace_upstream.mkdir()
    required(["git", "init", "--quiet", "--initial-branch=main", workspace_upstream], "workspace-git-init")
    required(["git", "-C", workspace_upstream, "config", "user.email", "fixture@example.invalid"], "workspace-git-email")
    required(["git", "-C", workspace_upstream, "config", "user.name", "DSR Bun Workspace Fixture"], "workspace-git-name")
    root_manifest = {"name": "workspace-root", "private": True, "workspaces": ["packages/*"]}
    member_manifest = {"name": "app", "version": "1.0.0", "bin": {"app": "src/app.ts", "helper": "src/helper.ts"},
                       "dependencies": {"shared": "workspace:*"}}
    contents = {".gitignore": "node_modules/\n", "workspace/package.json": json.dumps(root_manifest),
                "workspace/packages/app/package.json": json.dumps(member_manifest),
                "workspace/packages/app/src/app.ts": 'import { value } from "shared"; console.log("workspace-primary-" + value);\n',
                "workspace/packages/app/src/helper.ts": 'import { value } from "shared"; console.log("workspace-helper-" + value);\n',
                "workspace/packages/shared/package.json": json.dumps({"name": "shared", "version": "1.0.0", "main": "index.ts"}),
                "workspace/packages/shared/index.ts": 'export const value = "pinned-bun-workspace-dependency";\n',
                "workspace/unrelated/package.json": json.dumps({"name": "unrelated", "bin": "entry.ts"}),
                "workspace/unrelated/entry.ts": 'console.log("unrelated");\n',
                "workspace/extra/package.json": json.dumps({"name": "extra", "version": "1.0.0", "main": "index.ts"}),
                "workspace/extra/index.ts": 'export const extra = 1;\n'}
    for name, value in contents.items():
        path = workspace_upstream / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
    required(["bun", "install", "--lockfile-only"], "workspace-bun-lock", cwd=workspace_upstream / "workspace")
    required(["git", "-C", workspace_upstream, "add", "."], "workspace-git-add")
    required(["git", "-C", workspace_upstream, "commit", "--quiet", "-m", "Pin Bun workspace family"], "workspace-git-commit")
    pin = required(["git", "-C", workspace_upstream, "rev-parse", "HEAD"], "workspace-git-pin")
    required(["git", "-C", workspace_upstream, "tag", "v1.2.3"], "workspace-git-tag")
    config("bun-workspace", language="bun", local_path=str(workspace_upstream), source_subdir="workspace/packages/app",
           source_entry="", targets=["windows/amd64"], target_triples={"windows/amd64": "x86_64-pc-windows-msvc"},
           workspace_binaries_by_target={})
    generated, workspace_runtime, _ = generate("bun-workspace", "workspace-generate")
    check("public PowerShell generator admits a configured Bun workspace package", generated.returncode == 0,
          generated.stderr.decode(errors="replace"))
    if generated.returncode:
        return
    built, result, fixture = invoke("bun-workspace-family", selected_runtime=workspace_runtime,
        repository_url=workspace_upstream.as_uri(), extra={"NODE_OPTIONS": "--require=/missing/ambient-preload.js",
                                                          "BUN_OPTIONS": "--preload=/missing/ambient-bun-preload.ts"})
    check("genuine Windows Bun family builds from a selected package and its root frozen lock",
          built.returncode == 0 and result.get("source", {}).get("source_commit") == pin and no_http(fixture),
          built.stderr.decode(errors="replace"))
    if built.returncode:
        return
    prefix = Path(fixture["parameters"]["Prefix"])
    expected = {name: digest(prefix / name) for name in ("app.exe", "helper.exe")}
    check("Bun workspace compiles distinct complete x64 PE files with the pinned sibling dependency",
          all(machine(prefix / name) == 0x8664 and b"pinned-bun-workspace-dependency" in (prefix / name).read_bytes()
              for name in expected) and expected["app.exe"] != expected["helper.exe"])
    receipt = result["source"]
    check("Bun workspace receipt binds root/member manifests, committed lock and each installed payload",
          receipt["bun_workspace"] == {"root": "workspace", "member": "packages/app",
              "package_json_sha256": digest(workspace_upstream / "workspace/package.json")} and
          receipt["package_json_sha256"] == digest(workspace_upstream / "workspace/packages/app/package.json") and
          receipt["bun_lockfiles"][0]["path"] == "workspace/bun.lock" and
          receipt["bun_lockfiles"][0]["sha256"] == digest(workspace_upstream / "workspace/bun.lock") and
          all(row["sha256"] == expected[row["name"]] for row in result["binaries"]) and
          json.loads(Path(result["source_receipt"]["path"]).read_text()) == receipt)
    install_calls = [row for row in calls(fixture) if row["arguments"] == ["install", "--frozen-lockfile"]]
    check("Bun installs the admitted workspace root exactly once before compiling the selected package",
          len(install_calls) == 1 and install_calls[0]["directory"].endswith("/source/workspace") and
          sum(row["arguments"] == ["pm", "bin"] for row in calls(fixture)) == 1)

    config("bun-unrelated", language="bun", local_path=str(workspace_upstream), source_subdir="workspace/unrelated",
           source_entry="", targets=["windows/amd64"], target_triples={"windows/amd64": "x86_64-pc-windows-msvc"},
           workspace_binaries=["app"], workspace_binaries_by_target={})
    unrelated_generated, unrelated_runtime, _ = generate("bun-unrelated", "workspace-unrelated-generate")
    unrelated, unrelated_result, unrelated_fixture = invoke("bun-unrelated-workspace", selected_runtime=unrelated_runtime,
        repository_url=workspace_upstream.as_uri(), parameters={"Prefix": str(prefix)})
    check("unrelated nested package cannot borrow an ancestor Bun workspace lock",
          unrelated_generated.returncode == 0 and unrelated.returncode == 4 and
          "dependency root" in unrelated_result.get("error", "") and
          all(row["arguments"][0] != "install" for row in calls(unrelated_fixture)) and
          all(digest(prefix / name) == value for name, value in expected.items()))

    root_manifest["dependencies"] = {"extra": "file:./extra"}
    (workspace_upstream / "workspace/package.json").write_text(json.dumps(root_manifest))
    required(["git", "-C", workspace_upstream, "add", "workspace/package.json"], "workspace-stale-add")
    required(["git", "-C", workspace_upstream, "commit", "--quiet", "-m", "Change pinned dependencies without lock update"], "workspace-stale-commit")
    stale, _, stale_fixture = invoke("bun-workspace-stale-lock", selected_runtime=workspace_runtime,
        repository_url=workspace_upstream.as_uri(), parameters={"SourceRef": "HEAD", "Prefix": str(prefix)})
    check("stale workspace root lock stops before compilation and preserves the installed family",
          stale.returncode == 6 and any(row["arguments"] == ["install", "--frozen-lockfile"] for row in calls(stale_fixture)) and
          all(row["arguments"][0] != "build" for row in calls(stale_fixture)) and
          all(digest(prefix / name) == value for name, value in expected.items()))

    required(["git", "-C", workspace_upstream, "update-index", "--force-remove", "workspace/bun.lock"], "workspace-missing-lock-index")
    required(["git", "-C", workspace_upstream, "commit", "--quiet", "-m", "Pin a source tree without its Bun lock"], "workspace-missing-lock-commit")
    missing, _, missing_fixture = invoke("bun-workspace-missing-lock", selected_runtime=workspace_runtime,
        repository_url=workspace_upstream.as_uri(), parameters={"SourceRef": "HEAD", "Prefix": str(prefix)})
    check("missing workspace lock cannot reach compiler probes or mutate installed executables",
          missing.returncode == 4 and all(Path(row["executable"]).name.lower() not in ("bun", "bun.exe") for row in calls(missing_fixture)) and
          all(digest(prefix / name) == value for name, value in expected.items()))


if options.bun_only or options.bun_workspaces_only:
    if options.bun_only:
        test_bun_sources()
    test_bun_workspaces()
    print(f"Windows Bun source tests: {passed} passed, {failed} failed", flush=True)
    raise SystemExit(1 if failed else 0)


def test_go_workspaces():
    workspace_upstream = root / "workspace-upstream"
    workspace_upstream.mkdir()
    required(["git", "init", "--quiet", "--initial-branch=main", workspace_upstream], "workspace-git-init")
    required(["git", "-C", workspace_upstream, "config", "user.email", "fixture@example.invalid"], "workspace-git-email")
    required(["git", "-C", workspace_upstream, "config", "user.name", "DSR Go Workspace Fixture"], "workspace-git-name")
    project_mod = "module example.invalid/workspace-app\n\ngo 1.22\nrequire example.invalid/workspace-shared v0.0.0\n"
    shared_mod = "module example.invalid/workspace-shared\n\ngo 1.22\n"
    main_source = 'package main\nimport ("fmt"; "example.invalid/workspace-shared")\nfunc main() { fmt.Println(shared.Value()) }\n'
    workspace_files = {
        "go.work": "go 1.22\nuse (\n ./project\n ./shared\n)\n",
        "project/go.mod": project_mod,
        "project/apps/primary/main.go": main_source,
        "project/cmd/helper/main.go": main_source,
        "project/cmd/arm-helper/main.go": main_source,
        "shared/go.mod": shared_mod,
        "shared/value.go": 'package shared\nfunc Value() string { return "pinned-workspace-shared" }\n',
    }

    def write_files(changes):
        for name, value in changes.items():
            path = workspace_upstream / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)

    def commit(label):
        required(["git", "-C", workspace_upstream, "add", "."], label + "-add")
        required(["git", "-C", workspace_upstream, "commit", "--quiet", "-m", label], label + "-commit")
        return required(["git", "-C", workspace_upstream, "rev-parse", "HEAD"], label + "-pin")

    def workspace_invoke(label, *, selected_runtime, reference="HEAD", parameters=None, **changes):
        params = {"SourceRef": reference}
        params.update(parameters or {})
        selected_env = {"GOPROXY": "off", "GOSUMDB": "off"}
        selected_env.update(changes.pop("extra", {}))
        return invoke(label, selected_runtime=selected_runtime, parameters=params, extra=selected_env,
                      repository_url=workspace_upstream.as_uri(), **changes)

    write_files(workspace_files)
    workspace_commit = commit("workspace-pinned-sibling")
    config("workspace-source", local_path=str(workspace_upstream))
    generated_workspace, workspace_runtime, workspace_policy = generate("workspace-source", "workspace-generate")
    check("public generator embeds unchanged Go source selectors for committed workspace layouts",
          generated_workspace.returncode == 0 and workspace_policy["source"] == policy["source"])
    if generated_workspace.returncode:
        return
    if options.workspace_baseline_project:
        old_generated, old_runtime, old_policy = generate("workspace-source", "workspace-baseline-generate",
            checkout=options.workspace_baseline_project.resolve(), destination=root / "workspace-baseline-generated")
        old, _, old_fixture = workspace_invoke("workspace-baseline", selected_runtime=old_runtime,
                                               reference=workspace_commit)
        check("frozen baseline cannot resolve a real offline sibling through its committed Go workspace",
              old_generated.returncode == 0 and old_policy == workspace_policy and old.returncode == 6 and
              not Path(old_fixture["parameters"]["Prefix"]).exists() and no_http(old_fixture))

    ambient_work = root / "ambient.go.work"
    ambient_work.write_text("go 1.22\nuse ./outside-ambient-module\n")
    ambient_env = root / "ambient-go-env"
    ambient_env.write_text("GOFLAGS=-invalid-ambient-go-flag\n")
    installed, result, fixture = workspace_invoke("workspace-subdir", selected_runtime=workspace_runtime,
        reference=workspace_commit, extra={"GOWORK": str(ambient_work), "GOENV": str(ambient_env),
            "GOFLAGS": "-invalid-ambient-go-flag", "GO111MODULE": "off", "GOTOOLCHAIN": "go0.0.0+auto"})
    check("a configured subdirectory compiles its real x64 family using the pinned ancestor workspace",
          installed.returncode == 0 and result.get("source", {}).get("source_commit") == workspace_commit,
          installed.stderr.decode(errors="replace"))
    if installed.returncode:
        return
    workspace_receipt = result["source"].get("go_workspace", {})
    check("receipt binds the exact committed workspace and both Go module manifests without temporary paths",
          workspace_receipt.get("path") == "go.work" and workspace_receipt.get("sha256") == digest(workspace_upstream / "go.work") and
          workspace_receipt.get("modules") == [
              {"path": "project", "module_path": "example.invalid/workspace-app", "go_mod_sha256": digest(workspace_upstream / "project/go.mod")},
              {"path": "shared", "module_path": "example.invalid/workspace-shared", "go_mod_sha256": digest(workspace_upstream / "shared/go.mod")}] and
          workspace_receipt.get("local_replacements") == [] and workspace_receipt.get("vendor") is False and
          str(root) not in json.dumps(workspace_receipt))
    compiler_calls = [row for row in calls(fixture) if row["arguments"][0] in ("work", "mod", "list", "build")]
    check("actual Go commands ignore ambient workspace, flags, module mode and automatic toolchain selectors",
          bool(compiler_calls) and all(row["go_environment"]["GOENV"] == "off" and
              row["go_environment"]["GOFLAGS"] == "" and row["go_environment"]["GO111MODULE"] == "on" and
              row["go_environment"]["GOTOOLCHAIN"] == "local" and
              (row["go_environment"]["GOWORK"] == "off" if row["arguments"][0] in ("work", "mod") else
               row["go_environment"]["GOWORK"].endswith("/source/go.work")) for row in compiler_calls))
    check("workspace installs real dependency-bearing Windows executables and rebinds each byte receipt",
          {row["name"] for row in result["binaries"]} == {"app.exe", "helper.exe"} and all(
              machine(Path(fixture["parameters"]["Prefix"]) / row["name"]) == 0x8664 and
              digest(Path(fixture["parameters"]["Prefix"]) / row["name"]) == row["sha256"] and
              b"pinned-workspace-shared" in (Path(fixture["parameters"]["Prefix"]) / row["name"]).read_bytes()
              for row in result["binaries"]) and no_http(fixture))
    arm, arm_result, arm_fixture = workspace_invoke("workspace-arm64", selected_runtime=workspace_runtime,
        reference=workspace_commit, platform="windows/arm64")
    check("the same committed workspace compiles the actual ARM64-specific family",
          arm.returncode == 0 and {row["name"] for row in arm_result.get("binaries", [])} == {"app.exe", "arm-helper.exe"} and
          all(machine(Path(arm_fixture["parameters"]["Prefix"]) / row["name"]) == 0xAA64 for row in arm_result.get("binaries", [])),
          arm.stderr.decode(errors="replace"))

    write_files({"go.work": "go 1.22\nuse ./unused-missing-module\n",
                 "project/go.work": "go 1.22\nuse (\n .\n ../shared\n)\n"})
    nearest_commit = commit("workspace-nearest-with-parent-sibling")
    nearest, nearest_result, _ = workspace_invoke("workspace-nearest", selected_runtime=workspace_runtime,
                                                 reference=nearest_commit)
    check("nearest committed workspace wins and its parent-relative sibling stays inside the source pin",
          nearest.returncode == 0 and nearest_result.get("source", {}).get("go_workspace", {}).get("path") == "project/go.work",
          nearest.stderr.decode(errors="replace"))

    write_files({"project/go.work": "go 1.22\nuse .\n",
                 "project/go.mod": project_mod + "replace example.invalid/workspace-shared => ../shared\n",
                 "shared/go.mod": shared_mod + "replace example.invalid/unused => ../../outside-ignored-replacement\n"})
    replace_commit = commit("workspace-module-replacement")
    replaced, replaced_result, _ = workspace_invoke("workspace-module-replace", selected_runtime=workspace_runtime,
                                                   reference=replace_commit)
    expected_replacement = [{"module_path": "example.invalid/workspace-shared", "version": "", "path": "shared",
        "replacement_module_path": "example.invalid/workspace-shared", "go_mod_sha256": digest(workspace_upstream / "shared/go.mod")}]
    check("main-module local replacements are confined and retained while dependency replace directives remain inactive",
          replaced.returncode == 0 and replaced_result.get("source", {}).get("go_workspace", {}).get("local_replacements") == expected_replacement,
          replaced.stderr.decode(errors="replace"))
    write_files({"project/go.mod": project_mod + "replace example.invalid/workspace-shared v0.0.0 => ../../outside-shadowed-replacement\n",
                 "project/go.work": "go 1.22\nuse .\nreplace example.invalid/workspace-shared => ../shared\n"})
    override_commit = commit("workspace-overrides-module-replacement")
    overridden, override_result, _ = workspace_invoke("workspace-override", selected_runtime=workspace_runtime,
                                                      reference=override_commit)
    check("a committed workspace override supersedes an otherwise external main-module replacement",
          overridden.returncode == 0 and override_result.get("source", {}).get("go_workspace", {}).get("local_replacements") == expected_replacement,
          overridden.stderr.decode(errors="replace"))

    write_files({"go.work": "go 1.22\nuse (\n ./cmd/app\n ./cmd/helper\n ./shared\n)\n",
                 "cmd/app/go.mod": project_mod.replace("workspace-app", "workspace-root-app"),
                 "cmd/app/main.go": main_source,
                 "cmd/helper/go.mod": project_mod.replace("workspace-app", "workspace-root-helper"),
                 "cmd/helper/main.go": main_source,
                 "shared/go.mod": shared_mod})
    root_commit = commit("workspace-moduleless-root")
    config("workspace-root", local_path=str(workspace_upstream), source_subdir=".", source_entry="",
           targets=["windows/amd64"], workspace_binaries_by_target={})
    root_generated, root_runtime, _ = generate("workspace-root", "workspace-root-generate")
    moduleless, moduleless_result, moduleless_fixture = workspace_invoke("workspace-root", selected_runtime=root_runtime,
                                                                       reference=root_commit)
    check("a moduleless workspace root resolves and compiles a family from separate main modules",
          root_generated.returncode == 0 and moduleless.returncode == 0 and not (workspace_upstream / "go.mod").exists() and
          [row["path"] for row in moduleless_result.get("source", {}).get("go_workspace", {}).get("modules", [])] ==
          ["cmd/app", "cmd/helper", "shared"], moduleless.stderr.decode(errors="replace"))
    if moduleless.returncode:
        return
    root_prefix = Path(moduleless_fixture["parameters"]["Prefix"])
    original_family = {name: digest(root_prefix / name) for name in ("app.exe", "helper.exe")}
    for label, member in (("workspace-workfile-drift", "go.work"), ("workspace-manifest-drift", "shared/go.mod")):
        drift, drift_result, _ = workspace_invoke(label, selected_runtime=root_runtime, reference=root_commit,
            parameters={"Prefix": str(root_prefix)}, mutate_source=True, mutate_source_member=member)
        check(label + " after actual compilation preserves the complete previous family",
              drift.returncode == 7 and "changed the pinned tracked inputs" in drift_result.get("error", "") and
              all(digest(root_prefix / name) == value for name, value in original_family.items()), drift.stderr.decode(errors="replace"))

    write_files({"go.work": "go 1.22\nuse (\n ./cmd/app\n ./cmd/helper\n)\nreplace example.invalid/workspace-shared => ./shared\n"})
    required(["go", "work", "vendor"], "workspace-vendor-command", cwd=workspace_upstream,
             extra={"GOWORK": str(workspace_upstream / "go.work"), "GOFLAGS": "", "GOENV": "off", "GO111MODULE": "on", "GOPROXY": "off"})
    vendor_commit = commit("workspace-committed-vendor")
    vendored, vendor_result, vendor_fixture = workspace_invoke("workspace-vendor", selected_runtime=root_runtime,
                                                              reference=vendor_commit)
    check("committed workspace-root vendor data supports the real complete offline family",
          vendored.returncode == 0 and vendor_result.get("source", {}).get("go_workspace", {}).get("vendor") is True and
          vendor_result["source"]["go_workspace"].get("vendor_modules_sha256") == digest(workspace_upstream / "vendor/modules.txt") and
          vendor_result["source"]["go_workspace"].get("local_replacements") == [] and
          all("-mod=vendor" in row["arguments"] for row in calls(vendor_fixture) if row["arguments"][0] in ("list", "build")),
          vendored.stderr.decode(errors="replace"))
    original_vendor_manifest = (workspace_upstream / "vendor/modules.txt").read_text()
    write_files({"vendor/modules.txt": original_vendor_manifest.replace("v0.0.0", "v9.0.0")})
    inconsistent_commit = commit("workspace-inconsistent-vendor")
    inconsistent, _, inconsistent_fixture = workspace_invoke("workspace-inconsistent-vendor", selected_runtime=root_runtime,
                                                             reference=inconsistent_commit)
    check("an inconsistent marked workspace vendor inventory fails actual Go admission before any compiler build",
          inconsistent.returncode != 0 and not any(row["arguments"][0] == "build" for row in calls(inconsistent_fixture)) and
          not Path(inconsistent_fixture["parameters"]["Prefix"]).exists())
    required(["git", "-C", workspace_upstream, "update-index", "--force-remove", "vendor/modules.txt"], "workspace-vendor-untrack")
    required(["git", "-C", workspace_upstream, "commit", "--quiet", "-m", "Workspace vendor missing manifest"], "workspace-vendor-untrack-commit")
    incomplete, incomplete_result, incomplete_fixture = workspace_invoke("workspace-vendor-incomplete", selected_runtime=root_runtime)
    check("a vendor directory without workspace metadata retains actual readonly workspace resolution",
          incomplete.returncode == 0 and incomplete_result.get("source", {}).get("go_workspace", {}).get("vendor") is False and
          all("-mod=readonly" in row["arguments"] for row in calls(incomplete_fixture) if row["arguments"][0] in ("list", "build")),
          incomplete.stderr.decode(errors="replace"))
    write_files({"vendor/modules.txt": "\n".join(original_vendor_manifest.splitlines()[1:]) + "\n"})
    legacy_vendor_commit = commit("workspace-legacy-module-vendor")
    legacy, legacy_result, legacy_fixture = workspace_invoke("workspace-legacy-vendor", selected_runtime=root_runtime,
                                                            reference=legacy_vendor_commit)
    check("legacy single-module vendor metadata cannot redirect a workspace away from its committed modules",
          legacy.returncode == 0 and legacy_result.get("source", {}).get("go_workspace", {}).get("vendor") is False and
          all("-mod=readonly" in row["arguments"] for row in calls(legacy_fixture) if row["arguments"][0] in ("list", "build")),
          legacy.stderr.decode(errors="replace"))

    outside_original = root / "workspace-vendor-original"
    outside_original.mkdir()
    (outside_original / "go.mod").write_text(shared_mod)
    (outside_original / "value.go").write_text(workspace_files["shared/value.go"])
    write_files({"go.work": "go 1.22\nuse (\n ./cmd/app\n ./cmd/helper\n)\nreplace example.invalid/workspace-shared => ../workspace-vendor-original\n"})
    required(["go", "work", "vendor"], "workspace-external-vendor-command", cwd=workspace_upstream,
             extra={"GOWORK": str(workspace_upstream / "go.work"), "GOFLAGS": "", "GOENV": "off", "GO111MODULE": "on", "GOPROXY": "off"})
    external_vendor_commit = commit("workspace-self-contained-vendor")
    external_vendor, external_result, external_fixture = workspace_invoke("workspace-external-vendor", selected_runtime=root_runtime,
                                                                         reference=external_vendor_commit)
    check("self-contained committed vendor builds offline when its replacement original is absent from the fetched checkout",
          external_vendor.returncode == 0 and external_result.get("source", {}).get("go_workspace", {}).get("vendor") is True and
          external_result["source"]["go_workspace"].get("local_replacements") == [] and
          external_result["source"]["go_workspace"].get("vendor_modules_sha256") == digest(workspace_upstream / "vendor/modules.txt") and
          all("-mod=vendor" in row["arguments"] for row in calls(external_fixture) if row["arguments"][0] in ("list", "build")),
          external_vendor.stderr.decode(errors="replace"))
    vendor_drift, vendor_drift_result, _ = workspace_invoke("workspace-vendor-drift", selected_runtime=root_runtime,
        reference=external_vendor_commit, parameters={"Prefix": str(root_prefix)}, mutate_source=True,
        mutate_source_member="vendor/example.invalid/workspace-shared/value.go")
    check("changes to the actually compiled committed vendor bytes prevent installation and preserve the old family",
          vendor_drift.returncode == 7 and "changed the pinned tracked inputs" in vendor_drift_result.get("error", "") and
          all(digest(root_prefix / name) == value for name, value in original_family.items()), vendor_drift.stderr.decode(errors="replace"))
    untracked_vendor, _, untracked_vendor_fixture = workspace_invoke("workspace-untracked-vendor", selected_runtime=root_runtime,
        reference=root_commit, inject_untracked_vendor=True)
    check("an injected untracked workspace vendor manifest cannot authorize vendored source",
          untracked_vendor.returncode == 4 and not any(row["arguments"][0] == "build" for row in calls(untracked_vendor_fixture)) and
          not Path(untracked_vendor_fixture["parameters"]["Prefix"]).exists())
    # The following path guards exercise readonly selection, independently of
    # Go's earlier consistency rejection for stale marked vendor inventories.
    write_files({"vendor/modules.txt": "# Legacy module vendor fixture\n"})

    for label, workfile in (
        ("workspace-outside-use", "go 1.22\nuse (\n ./cmd/app\n ../outside\n)\n"),
        ("workspace-absolute-use", "go 1.22\nuse /outside-absolute-module\n"),
        ("workspace-case-mismatch", "go 1.22\nuse ./cmd/App\n"),
        ("workspace-missing-module", "go 1.22\nuse ./missing\n"),
        ("workspace-external-replacement", "go 1.22\nuse ./cmd/app\nreplace example.invalid/workspace-shared => ../outside\n"),
        ("workspace-malformed", "go 1.22\nuse (\n"),
    ):
        write_files({"go.work": workfile})
        refused_commit = commit(label)
        refused, _, refused_fixture = workspace_invoke(label, selected_runtime=root_runtime, reference=refused_commit)
        check(label + " refuses before compiling or installing any member",
              refused.returncode != 0 and not any(row["arguments"][0] == "build" for row in calls(refused_fixture)) and
              not Path(refused_fixture["parameters"]["Prefix"]).exists() and no_http(refused_fixture),
              refused.stderr.decode(errors="replace"))

    write_files({"go.work": "go 1.22\nuse ./linked\n"})
    required(["git", "-C", workspace_upstream, "add", "."], "workspace-linked-add")
    # Put an actual link in the Git tree without requiring Windows symlink
    # privileges merely to construct the negative source fixture.
    link_contents = root / "workspace-link-target"
    link_contents.write_text("shared")
    link_blob = required(["git", "-C", workspace_upstream, "hash-object", "-w", link_contents], "workspace-linked-blob")
    required(["git", "-C", workspace_upstream, "update-index", "--add", "--cacheinfo", f"120000,{link_blob},linked"], "workspace-linked-index")
    required(["git", "-C", workspace_upstream, "commit", "--quiet", "-m", "Workspace linked module"], "workspace-linked-commit")
    link_commit = required(["git", "-C", workspace_upstream, "rev-parse", "HEAD"], "workspace-linked-pin")
    linked, _, linked_fixture = workspace_invoke("workspace-linked-module", selected_runtime=root_runtime, reference=link_commit)
    check("a tracked workspace module symlink cannot reach a compiler or installation",
          linked.returncode == 4 and not any(row["arguments"][0] == "build" for row in calls(linked_fixture)) and
          not Path(linked_fixture["parameters"]["Prefix"]).exists())
    required(["git", "-C", workspace_upstream, "update-index", "--force-remove", "linked"], "workspace-unlink-index")
    ordinary_blob = required(["git", "-C", workspace_upstream, "hash-object", "-w", workspace_upstream / "shared/value.go"], "workspace-case-blob")
    for spelling in ("shared/Case.go", "shared/case.go"):
        required(["git", "-C", workspace_upstream, "update-index", "--add", "--cacheinfo", f"100644,{ordinary_blob},{spelling}"],
                 "workspace-case-" + spelling.rsplit("/", 1)[1])
    required(["git", "-C", workspace_upstream, "commit", "--quiet", "-m", "Workspace case-colliding files"], "workspace-case-commit")
    collision_commit = required(["git", "-C", workspace_upstream, "rev-parse", "HEAD"], "workspace-case-pin")
    collision, _, collision_fixture = workspace_invoke("workspace-case-collision", selected_runtime=root_runtime, reference=collision_commit)
    check("a case-colliding committed workspace tree is refused before any compiler or installation",
          collision.returncode == 4 and not any(row["arguments"][0] == "build" for row in calls(collision_fixture)) and
          not Path(collision_fixture["parameters"]["Prefix"]).exists())
    untracked, _, untracked_fixture = invoke("workspace-untracked-file", inject_untracked_workspace=True)
    check("an injected untracked workspace is refused instead of becoming implicit source authority",
          untracked.returncode == 4 and not any(row["arguments"][0] == "build" for row in calls(untracked_fixture)) and
          not Path(untracked_fixture["parameters"]["Prefix"]).exists())


test_go_workspaces()
if options.go_workspace_only:
    print(f"Windows Go workspace source tests: {passed} passed, {failed} failed", flush=True)
    raise SystemExit(1 if failed else 0)


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
config("unsupported-source", language="python")
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

if options.go_only:
    print(f"Windows Go source and release tests: {passed} passed, {failed} failed", flush=True)
    raise SystemExit(1 if failed else 0)

# A real Cargo workspace with a companion outside the default package is the
# missing Windows caller flow. No compiler, metadata or PE output is mocked.
rust_upstream = root / "rust-upstream"
rust_upstream.mkdir()
required(["git", "init", "--quiet", "--initial-branch=main", rust_upstream], "rust-git-init")
required(["git", "-C", rust_upstream, "config", "user.email", "fixture@example.invalid"], "rust-git-email")
required(["git", "-C", rust_upstream, "config", "user.name", "DSR Rust Source Fixture"], "rust-git-name")
rust_files = {
    "project/Cargo.toml": '[workspace]\nmembers = ["primary", "worker"]\ndefault-members = ["primary"]\nresolver = "2"\n',
    "project/.cargo/config.toml": '[build]\nrustflags = ["--cfg", "dsr_project_cfg"]\n',
    "project/primary/Cargo.toml": '[package]\nname = "primary-provider"\nversion = "0.1.0"\nedition = "2021"\n\n[[bin]]\nname = "app"\npath = "src/main.rs"\n',
    "project/primary/src/main.rs": '#[cfg(not(dsr_project_cfg))]\ncompile_error!("committed Cargo build.rustflags was ignored");\nfn main() { println!("rust-primary-v1"); }\n',
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
    "CARGO_BUILD_RUSTFLAGS": "--invalid-build-option",
    "CARGO_TARGET_DIR": str(root / "ambient-cargo-target"),
})
check("Rust source installs a real Windows PE family from the pinned annotated tag", rust_tagged.returncode == 0,
      rust_tagged.stderr.decode(errors="replace"))
if rust_tagged.returncode:
    raise SystemExit(1)
check("committed Cargo cfg flags apply while inherited RUSTFLAGS, CARGO_ENCODED_RUSTFLAGS and CARGO_BUILD_RUSTFLAGS are ignored",
      rust_tagged.returncode == 0 and rust_result["source"]["source_commit"] == rust_first_commit)
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
