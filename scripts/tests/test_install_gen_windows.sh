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

python3 - "$PROJECT_ROOT" "$@" <<'PY'
import argparse
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
import time
import zipfile

arguments = argparse.ArgumentParser(description="Genuine generated Windows installer regression")
arguments.add_argument("project")
arguments.add_argument("--recovery-only", action="store_true", help="Run signed install and interruption/recovery controls")
arguments.add_argument("--baseline-project", type=Path, help="Optional frozen pre-recovery checkout for a paired functional comparison")
options = arguments.parse_args()
project = Path(options.project).resolve()
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

def command(args, label, *, extra=None, cwd=None, timeout=120, terminate_at=None):
    selected = env.copy()
    selected.update(extra or {})
    invocation = [str(arg) for arg in args]
    if terminate_at is None:
        result = subprocess.run(invocation, cwd=cwd or project, env=selected,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    else:
        # The fixture publishes this barrier only after a genuine file move or
        # completion-marker publication. TerminateProcess/SIGKILL bypasses the
        # installer's finally blocks; an exception is not a crash substitute.
        with (root / (label + ".stdout")).open("wb") as output, (root / (label + ".stderr")).open("wb") as errors:
            process = subprocess.Popen(invocation, cwd=cwd or project, env=selected, stdout=output, stderr=errors)
            deadline = time.monotonic() + timeout
            try:
                while process.poll() is None and not Path(terminate_at).exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
                if not Path(terminate_at).exists() and time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(invocation, timeout)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
        result = subprocess.CompletedProcess(invocation, process.returncode,
            (root / (label + ".stdout")).read_bytes(), (root / (label + ".stderr")).read_bytes())
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

baseline_runtime = None
if options.baseline_project:
    baseline_project = options.baseline_project.resolve()
    baseline_output = root / "baseline-generated"
    baseline_generated = command([baseline_project / "dsr", "--json", "--non-interactive", "installer", "generate", "win-demo",
        "--shell", "powershell"], "generate-baseline", extra={"DSR_INSTALLER_DIR": str(baseline_output)}, cwd=baseline_project)
    baseline_runtime = baseline_output / "win-demo/install.ps1"
    check("frozen baseline CLI generates the same embedded release policy", baseline_generated.returncode == 0 and
          baseline_runtime.is_file() and encoded[0] in baseline_runtime.read_text(), baseline_generated.stderr.decode(errors="replace"))
    if baseline_generated.returncode or not baseline_runtime.is_file():
        raise SystemExit(1)

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
if ($fixture.Contains('http_client_fixture') -and $fixture.http_client_fixture) {
    # Exercise the real HTTP request/redirect/streaming implementation using
    # HttpClient's supported handler boundary. Responses are local fixtures;
    # request headers and credential decisions are production code.
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
public sealed class DsrInstallerFixtureHandler : HttpMessageHandler {
    private readonly JsonElement fixture;
    public DsrInstallerFixtureHandler(string path) {
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
            method = request.Method.Method,
            accept = request.Headers.Accept.ToString(), user_agent = request.Headers.UserAgent.ToString()
        }) + "\n");
        if (fixture.GetProperty("parameters").TryGetProperty("Offline", out JsonElement offline) && offline.GetBoolean()) {
            throw new HttpRequestException("Offline runtime crossed the HTTP boundary");
        }
        if (fixture.TryGetProperty("expected_token", out JsonElement expected) && request.RequestUri.Host == "api.github.com" &&
            authorization != expected.GetString()) {
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized));
        }
        if (request.RequestUri.Host != "api.github.com" && authorization.Length != 0) {
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadRequest));
        }
        if (request.RequestUri.AbsolutePath.Contains("/releases/assets/") &&
            request.Headers.Accept.ToString() != "application/octet-stream") {
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotAcceptable));
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
        $client = [Net.Http.HttpClient]::new([DsrInstallerFixtureHandler]::new($script:FixturePath), $true)
        $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
        return $client
    }
} else {
    function Invoke-DsrDownload {
        param([string]$Url, [string]$Destination, [switch]$Optional, [long]$MaximumBytes = 2147483648,
              [switch]$ApiAsset)
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
}
if ($fixture.Contains('journal_publish_fault') -and $fixture.journal_publish_fault) {
    function Publish-DsrInstallJournal {
        param([string]$Source, [string]$Destination)
        [IO.File]::Move($Source, $Destination, $false)
        throw 'Injected handled interruption after atomic journal publication'
    }
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
if ($fixture.Contains('pause_after_move')) {
    $script:Moves = 0
    function Move-DsrInstalledFile {
        param([string]$Source, [string]$Destination)
        [IO.File]::Move($Source, $Destination, $true)
        $script:Moves++
        if ($script:Moves -eq $script:Fixture.pause_after_move) {
            [IO.File]::WriteAllText($script:Fixture.pause_marker, 'real move completed')
            while ($true) { Start-Sleep -Seconds 1 }
        }
    }
}
if ($fixture.Contains('pause_after_completion')) {
    $script:RealCompletion = ${function:Write-DsrTransactionCompletion}
    function Write-DsrTransactionCompletion {
        param($Transaction, [string]$State)
        & $script:RealCompletion $Transaction $State
        if ($State -ceq $script:Fixture.pause_after_completion) {
            [IO.File]::WriteAllText($script:Fixture.pause_marker, 'real completion marker published')
            while ($true) { Start-Sleep -Seconds 1 }
        }
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

def release(label, *, kind="good", checksum="SHA256SUMS", signed=True, selected=policy, raw=False, version="v1.2.3"):
    directory = root / ("release-" + label)
    directory.mkdir()
    chosen = asset_for(selected, version.removeprefix("v"))
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
    url = "https://github.com/" + selected["repo"] + "/releases/download/" + version + "/"
    downloads = {url + path.name: str(path) for path in directory.iterdir()}
    return downloads

def run_case(label, downloads=None, *, selected_runtime=runtime, cache=None, prefix=None,
             offline=False, version="1.2.3", yes=True, options=None, credentials=None, recover=False):
    cache = Path(cache or root / ("cache-" + label))
    prefix = Path(prefix or root / ("prefix-" + label))
    requests = root / (label + ".requests")
    parameters = {"Prefix": str(prefix), "Json": True, "Yes": yes}
    if recover:
        parameters["Recover"] = True
    else:
        parameters["CacheDir"] = str(cache)
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
                      "-RuntimePath", selected_runtime, "-CasePath", case], label, extra=credentials,
                      terminate_at=(options or {}).get("pause_marker"))
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

def exercise_recovery(cache):
    originals = {"app.exe": b"previous application bytes", "worker.exe": b"previous worker bytes",
                 "unrelated.txt": b"preserve unrelated user data"}
    family = ("app.exe", "worker.exe")
    pending_name = ".dsr-windows-install.pending.json"

    def prepare(label, missing=()):
        prefix = root / ("prefix-" + label)
        prefix.mkdir()
        for name, value in originals.items():
            if name not in missing:
                (prefix / name).write_bytes(value)
        return prefix

    def observed(prefix):
        return {name: (prefix / name).read_bytes() if (prefix / name).exists() else None for name in originals}

    def interrupted(label, prefix, *, after=1, selected_runtime=runtime, completion=False):
        marker = root / (label + ".barrier")
        control = {"pause_marker": str(marker)}
        if completion:
            control["pause_after_completion"] = "committed"
        else:
            control["pause_after_move"] = after
        result = run_case(label, selected_runtime=selected_runtime, cache=cache, prefix=prefix,
                          offline=True, options=control)
        check(label + " reaches a genuine filesystem boundary and is forcibly terminated",
              marker.is_file() and result[0].returncode != 0, result[0].stderr.decode(errors="replace"))
        if not marker.is_file():
            raise RuntimeError("Cannot qualify crash recovery without reaching the real mutation barrier")
        return result

    if baseline_runtime is not None:
        baseline_prefix = prepare("baseline-interrupted")
        interrupted("baseline-after-first-move", baseline_prefix, selected_runtime=baseline_runtime)
        check("frozen baseline leaves a mixed family without a recoverable journal",
              (baseline_prefix / "app.exe").read_bytes() == (root / "app.exe").read_bytes() and
              (baseline_prefix / "worker.exe").read_bytes() == originals["worker.exe"] and
              not (baseline_prefix / pending_name).exists())
        baseline_retry, _, _, _, _ = run_case("baseline-retry-without-recovery", selected_runtime=baseline_runtime,
                                              cache=cache, prefix=baseline_prefix, offline=True)
        check("frozen baseline accepts another update over the unrecovered mixed family", baseline_retry.returncode == 0 and
              all((baseline_prefix / name).read_bytes() == (root / name).read_bytes() for name in family),
              baseline_retry.stderr.decode(errors="replace"))
        baseline_recover, _, _, _, _ = run_case("baseline-recovery-unavailable", selected_runtime=baseline_runtime,
                                                prefix=baseline_prefix, recover=True)
        check("frozen baseline cannot restore the previous family through explicit recovery",
              baseline_recover.returncode != 0 and observed(baseline_prefix) != originals)

    publish_prefix = prepare("handled-journal-publication")
    publish_failure, _, _, _, _ = run_case("handled-journal-publication", cache=cache, prefix=publish_prefix,
                                          offline=True, options={"journal_publish_fault": True})
    publish_pending = publish_prefix / pending_name
    check("handled interruption immediately after real journal publication retains the pending record and original family",
          publish_failure.returncode == 7 and publish_pending.is_file() and observed(publish_prefix) == originals,
          publish_failure.stderr.decode(errors="replace"))
    if not publish_pending.is_file():
        raise RuntimeError("Publication-boundary control did not retain its real pending journal")
    publish_journal = json.loads(publish_pending.read_bytes())
    publish_stage = publish_prefix / (".dsr-install-" + publish_journal["transaction_id"])
    check("ambiguous publication return cannot delete backups referenced by the pending journal",
          all((publish_stage / "old" / name).read_bytes() == originals[name] for name in family))
    publish_recovery, _, _, _, _ = run_case("recover-handled-journal-publication", prefix=publish_prefix, recover=True)
    check("explicit recovery safely completes a handled interruption before the first executable replacement",
          publish_recovery.returncode == 0 and observed(publish_prefix) == originals and
          not publish_pending.exists() and not publish_stage.exists(), publish_recovery.stderr.decode(errors="replace"))

    prefix = prepare("interrupted-family")
    interrupted("kill-after-first-move", prefix)
    pending = prefix / pending_name
    check("crashed update records the immutable complete family before replacing its first executable",
          pending.is_file() and (prefix / "app.exe").read_bytes() == (root / "app.exe").read_bytes() and
          (prefix / "worker.exe").read_bytes() == originals["worker.exe"])
    if not pending.is_file():
        raise RuntimeError("Missing journal after a real interrupted candidate installation")
    journal_bytes = pending.read_bytes()
    journal = json.loads(journal_bytes)
    stage = prefix / (".dsr-install-" + journal["transaction_id"])
    check("crashed update preserves exact original bytes for every family member",
          len(journal["binaries"]) == 2 and all((stage / "old" / name).read_bytes() == originals[name] for name in family))
    mixed = observed(prefix)
    retry, _, _, _, _ = run_case("pending-refuses-update", cache=cache, prefix=prefix, offline=True)
    check("ordinary retry refuses the interrupted transaction without replacing its mixed family",
          retry.returncode == 2 and observed(prefix) == mixed and pending.read_bytes() == journal_bytes,
          retry.stderr.decode(errors="replace"))
    no_consent, _, _, _, no_consent_requests = run_case("recovery-needs-yes", prefix=prefix, recover=True, yes=False)
    check("recovery requires explicit consent before changing executables or using HTTP",
          no_consent.returncode == 2 and observed(prefix) == mixed and not no_consent_requests.exists())
    busy, _, _, _, _ = run_case("recovery-held-lease", prefix=prefix, recover=True, options={"held_lease": True})
    check("recovery retains the same exclusive kernel lease as normal installation",
          busy.returncode == 2 and observed(prefix) == mixed, busy.stderr.decode(errors="replace"))

    # Reject every destination before mutating the first one: an unrelated
    # writer's bytes must survive even when another member needs restoration.
    (prefix / "worker.exe").write_bytes(b"independent user modification")
    externally_changed = observed(prefix)
    altered, _, _, _, _ = run_case("recovery-modified-destination", prefix=prefix, recover=True)
    check("recovery refuses an externally changed family before restoring any other member",
          altered.returncode == 7 and observed(prefix) == externally_changed and pending.read_bytes() == journal_bytes,
          altered.stderr.decode(errors="replace"))
    (prefix / "worker.exe").write_bytes(originals["worker.exe"])

    malformed = []
    foreign = copy.deepcopy(journal)
    foreign["repository"] = "fixture/another-tool"
    malformed.append(("foreign-repository", json.dumps(foreign).encode()))
    escaping = copy.deepcopy(journal)
    escaping["transaction_id"] = "../outside"
    malformed.append(("escaping-stage", json.dumps(escaping).encode()))
    duplicate = journal_bytes.replace(b'"schema_version":1', b'"schema_version":1,"schema_version":1', 1)
    if duplicate == journal_bytes:
        raise RuntimeError("Duplicate-key fixture did not mutate the genuine compact journal")
    malformed.append(("duplicate-json-key", duplicate))
    invalid_evidence = copy.deepcopy(journal)
    invalid_evidence["binaries"][0]["previous"]["size_bytes"] = "17"
    malformed.append(("untyped-evidence", json.dumps(invalid_evidence).encode()))
    for label, content in malformed:
        pending.write_bytes(content)
        refused, _, _, _, attempted_http = run_case("recovery-" + label, prefix=prefix, recover=True)
        check("recovery refuses " + label + " without following journal paths or mutating the family",
              refused.returncode == 7 and observed(prefix) == mixed and pending.read_bytes() == content and
              not attempted_http.exists(), refused.stderr.decode(errors="replace"))
        pending.write_bytes(journal_bytes)

    backup = stage / "old/app.exe"
    backup.write_bytes(b"changed private backup")
    bad_backup, _, _, _, _ = run_case("recovery-changed-backup", prefix=prefix, recover=True)
    check("recovery authenticates every original backup before changing the destination family",
          bad_backup.returncode == 7 and observed(prefix) == mixed and pending.read_bytes() == journal_bytes,
          bad_backup.stderr.decode(errors="replace"))
    backup.write_bytes(originals["app.exe"])
    if sys.platform != "win32":
        saved_backup = root / "saved-original-app.exe"
        backup.rename(saved_backup)
        outside = root / "outside-recovery-sentinel"
        outside.write_bytes(b"never change the link target")
        backup.symlink_to(outside)
        linked, _, _, _, _ = run_case("recovery-linked-backup", prefix=prefix, recover=True)
        check("recovery refuses link-bearing staging without changing its target or the installed family",
              linked.returncode == 7 and observed(prefix) == mixed and outside.read_bytes() == b"never change the link target",
              linked.stderr.decode(errors="replace"))
        backup.unlink()
        saved_backup.rename(backup)

    recovered, recovered_details, recovery_cache, _, recovery_requests = run_case("recover-previous-family",
        prefix=prefix, recover=True, options={"without_minisign": True}, credentials={"DSR_GH_TOKEN": "invalid fixture token"})
    check("explicit recovery restores exact prior bytes offline without a token, verifier or release cache",
          recovered.returncode == 0 and recovered_details.get("recovery_action") == "rolled_back" and
          recovered_details.get("transaction_state") == "rolled_back" and observed(prefix) == originals and
          not recovery_requests.exists() and not recovery_cache.exists() and not pending.exists() and not stage.exists() and
          "signature_verified" not in recovered_details, recovered.stderr.decode(errors="replace") + " " + json.dumps(recovered_details))
    check("recovery receipt identifies the complete restored family and original evidence",
          len(recovered_details.get("binaries", [])) == 2 and
          all(row["present"] is True and row["evidence"]["sha256"] == hashlib.sha256(originals[row["name"]]).hexdigest()
              for row in recovered_details.get("binaries", [])))

    partial = prepare("interrupted-recovery")
    interrupted("kill-after-entire-family-moved", partial, after=2)
    partial_pending = partial / pending_name
    partial_journal = json.loads(partial_pending.read_bytes())
    partial_stage = partial / (".dsr-install-" + partial_journal["transaction_id"])
    recovery_marker = root / "kill-during-recovery.barrier"
    killed_recovery, _, _, _, _ = run_case("kill-during-recovery", prefix=partial, recover=True,
        options={"pause_after_move": 1, "pause_marker": str(recovery_marker)})
    check("a second genuine process kill interrupts restoration after its first real replacement",
          recovery_marker.is_file() and killed_recovery.returncode != 0 and
          (partial / "app.exe").read_bytes() == (root / "app.exe").read_bytes() and
          (partial / "worker.exe").read_bytes() == originals["worker.exe"] and
          all((partial_stage / "old" / name).read_bytes() == originals[name] for name in family),
          killed_recovery.stderr.decode(errors="replace"))
    resumed, resumed_details, _, _, _ = run_case("resume-interrupted-recovery", prefix=partial, recover=True)
    check("recovery resumes after another process kill because original backups were never consumed",
          resumed.returncode == 0 and resumed_details.get("recovery_action") == "rolled_back" and
          observed(partial) == originals and not partial_pending.exists(), resumed.stderr.decode(errors="replace"))

    added_member = prepare("interrupted-added-member", missing=("worker.exe",))
    interrupted("kill-after-added-member-moved", added_member, after=2)
    removed_new, removed_details, _, _, _ = run_case("recover-previously-absent-member", prefix=added_member, recover=True)
    check("recovery removes only the transaction's newly introduced executable and preserves existing user files",
          removed_new.returncode == 0 and (added_member / "app.exe").read_bytes() == originals["app.exe"] and
          not (added_member / "worker.exe").exists() and (added_member / "unrelated.txt").read_bytes() == originals["unrelated.txt"] and
          any(row["name"] == "worker.exe" and row["present"] is False for row in removed_details.get("binaries", [])),
          removed_new.stderr.decode(errors="replace"))

    committed_prefix = prepare("committed-before-cleanup")
    interrupted("kill-after-commit-marker", committed_prefix, completion=True)
    committed_pending = committed_prefix / pending_name
    committed_journal = json.loads(committed_pending.read_bytes())
    committed_stage = committed_prefix / (".dsr-install-" + committed_journal["transaction_id"])
    completed_marker = json.loads((committed_stage / "complete.json").read_bytes())
    check("completion marker binds the exact immutable journal after the entire new family is checked",
          completed_marker["state"] == "committed" and
          completed_marker["journal_sha256"] == hashlib.sha256(committed_pending.read_bytes()).hexdigest() and
          all((committed_prefix / name).read_bytes() == (root / name).read_bytes() for name in family))
    completion, completion_details, _, _, _ = run_case("recover-committed-cleanup", prefix=committed_prefix, recover=True)
    check("recovery after the commit point completes cleanup without rolling back a successful installation",
          completion.returncode == 0 and completion_details.get("recovery_action") == "completed_cleanup" and
          completion_details.get("transaction_state") == "committed" and not committed_pending.exists() and
          not committed_stage.exists() and all((committed_prefix / name).read_bytes() == (root / name).read_bytes() for name in family) and
          (committed_prefix / "unrelated.txt").read_bytes() == originals["unrelated.txt"], completion.stderr.decode(errors="replace"))

    handled = prepare("recovery-handled-failure")
    rollback, rollback_details, _, _, _ = run_case("recovery-handled-second-move", cache=cache, prefix=handled,
                                                 offline=True, options={"move_fault": True})
    check("handled second-move failure still restores the whole prior family and clears its transaction",
          rollback.returncode == 7 and rollback_details.get("status") == "error" and observed(handled) == originals and
          not (handled / pending_name).exists() and not list(handled.glob(".dsr-install-*")),
          rollback.stderr.decode(errors="replace"))

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
exercise_recovery(good_cache)
if options.recovery_only:
    print(f"\nWindows installer recovery checks: {passed + failed}; passed: {passed}; failed: {failed}", flush=True)
    print("Qualified here: genuine generated PowerShell, signed Go PE families, process termination and local recovery.", flush=True)
    print("Not qualified here: native Windows ACL/NTFS, power-loss durability or live GitHub transport.", flush=True)
    raise SystemExit(1 if failed else 0)
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
latest_path.write_text(json.dumps({"id": 4242, "tag_name": "v1.2.3", "draft": False, "prerelease": False}))
latest_downloads["https://api.github.com/repos/fixture/win-demo/releases/latest"] = str(latest_path)
latest, latest_details, _, _, latest_requests = run_case("latest-online", latest_downloads, version=None)
check("online latest selects a real exact tag before payload lookup", latest.returncode == 0 and
      latest_details.get("version") == "v1.2.3" and latest_requests.read_text().splitlines()[0].endswith("/releases/latest"),
      latest.stderr.decode(errors="replace"))

# This path uses the real download/request implementation. Only HttpClient's
# response handler is a fixture; policy, pagination, exact asset selection,
# headers, redirects, transfer limits, checksums and signatures stay genuine.
fixture_token = "dsr-fixture-token-for-private-releases"
credentials = {"DSR_GH_TOKEN": fixture_token, "GITHUB_TOKEN": "fixture-github-fallback",
               "GH_TOKEN": "fixture-gh-fallback"}
api = "https://api.github.com/repos/fixture/win-demo"
release_id = 4242

def private_release(label, *, kind="good", checksum="SHA256SUMS", version="v1.2.3", padding=100):
    public = release("private-" + label, kind=kind, checksum=checksum, version=version)
    directory = root / ("private-metadata-" + label)
    directory.mkdir()
    metadata = {"id": release_id, "tag_name": version, "draft": False, "prerelease": False}
    rows = [{"id": index + 1, "name": "other-platform-" + str(index) + ".zip", "state": "uploaded", "size": 1}
            for index in range(padding)]
    if rows:
        # Dictionary keys may shadow PowerShell's adapted .Count property;
        # unrelated legal release names must not break subsequent pages.
        rows[0]["name"] = "Count"
    downloads = {}
    for index, source in enumerate(public.values(), start=1001):
        path = Path(source)
        rows.append({"id": index, "name": path.name, "state": "uploaded", "size": path.stat().st_size,
                     # These remote URL fields must never become request targets.
                     "url": "https://example.invalid/untrusted-asset-url",
                     "browser_download_url": "https://example.invalid/untrusted-browser-url"})
        downloads[api + "/releases/assets/" + str(index)] = source
    if kind == "duplicate-asset-name":
        row = copy.deepcopy(rows[-3])
        row["id"] = 2001
        rows.append(row)
    elif kind == "duplicate-asset-id":
        row = copy.deepcopy(rows[-3])
        row["name"] = "another-name.zip"
        rows.append(row)
    elif kind == "missing-payload":
        rows = [row for row in rows if row["name"] != asset_for(policy, version.removeprefix("v"))]
    elif kind == "missing-signature":
        rows = [row for row in rows if not row["name"].endswith(".minisig")]
    elif kind == "incomplete-payload":
        next(row for row in rows if row["name"] == asset_for(policy, version.removeprefix("v")))["state"] = "starter"
    elif kind == "changed-size":
        next(row for row in rows if row["name"] == asset_for(policy, version.removeprefix("v")))["size"] += 1
    elif kind == "wrong-tag":
        metadata["tag_name"] = "v9.9.9"
    elif kind == "array-tag":
        metadata["tag_name"] = [version]
    elif kind == "empty-array-tag":
        metadata["tag_name"] = []
    elif kind == "repeated-array-tag":
        metadata["tag_name"] = [version, version]
    elif kind == "draft-release":
        metadata["draft"] = True
    metadata_path = directory / "release.json"
    metadata_path.write_text(json.dumps(metadata))
    downloads[api + "/releases/tags/" + version] = str(metadata_path)
    downloads[api + "/releases/latest"] = str(metadata_path)
    for start in range(0, len(rows) + 1, 100):
        page = start // 100 + 1
        value = rows[start:start + 100]
        if kind == "object-page":
            value = {"not": "an array"}
        page_path = directory / ("page-" + str(page) + ".json")
        page_path.write_text(json.dumps(value))
        downloads[api + "/releases/4242/assets?per_page=100&page=" + str(page)] = str(page_path)
    return downloads

def http_options(**options):
    return {"http_client_fixture": True, "expected_token": fixture_token, **options}

def request_rows(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

latest_api = api + "/releases/latest"
latest_browser = "https://github.com/fixture/win-demo/releases/latest"
latest_tag_url = "https://github.com/fixture/win-demo/releases/tag/v1.2.3"
latest_downloads = dict(good)
latest_page = root / "latest-release-page.html"
latest_page.write_text("<html>Do not scrape this body for a release version.</html>\n")
latest_downloads[latest_tag_url] = str(latest_page)

for status in (403, 408, 429, 503):
    outcome, parsed, _, prefix, observed = run_case("public-latest-http-" + str(status), latest_downloads,
        version=None, options={"http_client_fixture": True, "statuses": {latest_api: status},
                               "redirects": {latest_browser: latest_tag_url}})
    rows = request_rows(observed)
    check("anonymous latest survives API HTTP " + str(status) + " with a verified complete family",
          outcome.returncode == 0 and parsed.get("version") == "v1.2.3" and
          parsed.get("signature_verified") is True and
          all((prefix / name).read_bytes() == (root / name).read_bytes() for name in ("app.exe", "worker.exe")),
          outcome.stderr.decode(errors="replace"))
    if status == 403:
        check("latest fallback uses bounded HEAD discovery and never attaches credentials",
              [row["url"] for row in rows[:3]] == [latest_api, latest_browser, latest_tag_url] and
              all(row["method"] == "HEAD" for row in rows if row["url"] in (latest_browser, latest_tag_url)) and
              all(not row["authorization_sha256"] for row in rows) and
              all(row["url"].startswith(base_url) and row["method"] == "GET" for row in rows[3:]))

for fault in ("request", "timeout"):
    outcome, parsed, _, _, observed = run_case("public-latest-transport-" + fault, latest_downloads,
        version=None, options={"http_client_fixture": True, "transport_failures": {latest_api: fault},
                               "redirects": {latest_browser: latest_tag_url}})
    check("injected API " + fault + " failure still admits an independently verified public release",
          outcome.returncode == 0 and parsed.get("signature_verified") is True and
          any(row["url"] == latest_browser for row in request_rows(observed)),
          outcome.stderr.decode(errors="replace"))

latest_metadata = root / "valid-latest.json"
latest_metadata.write_text(json.dumps({"id": release_id, "tag_name": "v1.2.3", "draft": False, "prerelease": False}))
api_latest_downloads = {**good, latest_api: str(latest_metadata)}
api_latest, api_latest_result, _, _, api_latest_requests = run_case("public-latest-api-success", api_latest_downloads,
    version=None, options={"http_client_fixture": True})
check("successful published latest API discovery keeps the ordinary verified path",
      api_latest.returncode == 0 and api_latest_result.get("signature_verified") is True and
      not any(row["url"] == latest_browser for row in request_rows(api_latest_requests)),
      api_latest.stderr.decode(errors="replace"))

for kind, content in (
        ("malformed-json", '{"tag_name":'),
        ("draft", json.dumps({"id": release_id, "tag_name": "v1.2.3", "draft": True, "prerelease": False})),
        ("prerelease", json.dumps({"id": release_id, "tag_name": "v1.2.3", "draft": False, "prerelease": True})),
        ("invalid-prerelease", json.dumps({"id": release_id, "tag_name": "v1.2.3", "draft": False, "prerelease": []})),
        ("missing-id", json.dumps({"tag_name": "v1.2.3", "draft": False, "prerelease": False}))):
    metadata_path = root / ("latest-" + kind + ".json")
    metadata_path.write_text(content)
    outcome, _, _, _, observed = refusal("public-latest-" + kind,
        downloads={**latest_downloads, latest_api: str(metadata_path)}, version=None,
        options={"http_client_fixture": True, "redirects": {latest_browser: latest_tag_url}})
    check("successful but " + kind + " API metadata never authorizes browser fallback",
          [row["url"] for row in request_rows(observed)] == [latest_api])

unsafe_latest_redirects = (
    "http://github.com/fixture/win-demo/releases/tag/v1.2.3",
    "https://example.invalid/fixture/win-demo/releases/tag/v1.2.3",
    "https://github.com/other/repository/releases/tag/v1.2.3",
    "https://github.com/login",
    "https://github.com:444/fixture/win-demo/releases/tag/v1.2.3",
    "https://user@github.com/fixture/win-demo/releases/tag/v1.2.3",
    latest_tag_url + "?redirect=other",
    latest_tag_url + "#untrusted",
    "https://github.com/fixture/win-demo/releases/tag/v1.2.3%2Fother",
    "https://github.com/fixture/win-demo/releases/tag/v1.2.3%0A")
for index, target in enumerate(unsafe_latest_redirects):
    outcome, _, _, _, observed = refusal("public-latest-unsafe-redirect-" + str(index),
        downloads=latest_downloads, version=None, expected=8,
        options={"http_client_fixture": True, "statuses": {latest_api: 503},
                 "redirects": {latest_browser: target}})
    check("unsafe public latest redirect " + str(index) + " is rejected before any target request",
          [row["url"] for row in request_rows(observed)] == [latest_api, latest_browser])

for label, statuses, redirects, expected_requests in (
        ("unresolved", {latest_api: 403, latest_browser: 200}, {}, 2),
        ("missing-tag-page", {latest_api: 403, latest_tag_url: 404}, {latest_browser: latest_tag_url}, 3),
        ("redirect-loop", {latest_api: 403}, {latest_browser: latest_browser}, 7)):
    outcome, _, _, _, observed = refusal("public-latest-" + label, downloads=latest_downloads,
        version=None, expected=8, options={"http_client_fixture": True, "statuses": statuses, "redirects": redirects})
    check("public latest " + label + " cannot select an unproved tag or exceed the redirect bound",
          len(request_rows(observed)) == expected_requests)

tag_with_plus = "v1.2.3+build.4"
encoded_tag_url = "https://github.com/fixture/win-demo/releases/tag/v1.2.3%2Bbuild.4"
encoded_downloads = {url.replace("+", "%2B"): path for url, path in release("latest-plus", version=tag_with_plus).items()}
encoded_downloads[encoded_tag_url] = str(latest_page)
encoded_result, encoded_details, _, _, _ = run_case("public-latest-encoded-tag", encoded_downloads,
    version=None, options={"http_client_fixture": True, "statuses": {latest_api: 429},
                           "redirects": {latest_browser: "/fixture/win-demo/releases/tag/v1.2.3%2Bbuild.4"}})
check("relative latest redirects preserve an exact percent-encoded plus tag and verified payload",
      encoded_result.returncode == 0 and encoded_details.get("version") == tag_with_plus and
      encoded_details.get("signature_verified") is True, encoded_result.stderr.decode(errors="replace"))

private_downloads = private_release("complete")
payload_url = next(url for url, path in private_downloads.items() if Path(path).name == asset)
redirect_url = "https://release-assets.githubusercontent.com/fixture/payload?signature=fixture-only"
private_downloads[redirect_url] = private_downloads.pop(payload_url)
private_result, private_details, private_cache, private_prefix, private_requests = run_case(
    "private-paginated-family", private_downloads, credentials=credentials,
    options=http_options(redirects={payload_url: redirect_url}))
private_rows = request_rows(private_requests)
check("authenticated asset-ID acquisition installs the signed complete family from a later page",
      private_result.returncode == 0 and private_details.get("signature_verified") is True and
      all((private_prefix / name).read_bytes() == (root / name).read_bytes() for name in ("app.exe", "worker.exe")) and
      any(row["url"].endswith("assets?per_page=100&page=2") for row in private_rows),
      private_result.stderr.decode(errors="replace") + " " + json.dumps(private_details))
expected_token_hash = hashlib.sha256(fixture_token.encode()).hexdigest()
api_rows = [row for row in private_rows if row["url"].startswith(api + "/")]
check("selected token precedence and repository API scope govern every authenticated request",
      bool(api_rows) and all(row["authorization_sha256"] == expected_token_hash and
      row["authorization_scheme"] == "Bearer" for row in api_rows) and
      all(row["user_agent"].startswith("doodlestein_self_releaser-installer/") for row in private_rows) and
      all(row["url"].startswith(api + "/") or row["url"] == redirect_url for row in private_rows))
binary_rows = [row for row in private_rows if "/releases/assets/" in row["url"]]
check("primary checksum and signature use octet-stream requests and object storage receives no credential",
      len(binary_rows) == 3 and all(row["accept"] == "application/octet-stream" for row in binary_rows) and
      any(row["url"] == redirect_url and not row["authorization_sha256"] for row in private_rows))
check("authentication values never enter result diagnostics cache or request evidence",
      all(value.encode() not in private_result.stdout + private_result.stderr + private_requests.read_bytes()
          for value in credentials.values()) and
      all(fixture_token.encode() not in path.read_bytes() for path in private_cache.rglob("*") if path.is_file()))
private_offline, private_offline_details, _, private_offline_prefix, private_offline_requests = run_case(
    "private-offline-without-token", cache=private_cache, offline=True, options={"http_client_fixture": True})
check("authenticated cache is reusable offline without a token or HTTP and still verifies its signature",
      private_result.returncode == 0 and private_offline.returncode == 0 and
      private_offline_details.get("signature_verified") is True and not private_offline_requests.exists() and
      (private_offline_prefix / "worker.exe").read_bytes() == (root / "worker.exe").read_bytes(),
      private_offline.stderr.decode(errors="replace"))

for kind, expected in (("duplicate-asset-name", 7), ("duplicate-asset-id", 7), ("missing-payload", 8),
                       ("missing-signature", 8), ("incomplete-payload", 7), ("changed-size", 7),
                       ("wrong-tag", 7), ("array-tag", 7), ("empty-array-tag", 7), ("repeated-array-tag", 7),
                       ("draft-release", 7), ("object-page", 7),
                       ("bad-checksum", 7), ("bad-signature", 7)):
    outcome, _, _, _, observed = refusal("private-" + kind, downloads=private_release(kind, kind=kind),
        expected=expected, credentials=credentials, options=http_options())
    check("private " + kind + " refusal never downgrades to public acquisition",
          all(row["url"].startswith(api + "/") for row in request_rows(observed)))

for checksum, padding in (("sidecar", 98), ("checksums.sha256", 97)):
    # 98 unrelated + 3 relevant = a singleton final page; 97 + 3 =
    # a full page followed by [], exercising both JSON cardinalities.
    outcome, _, _, _, observed = run_case("private-" + checksum, private_release(checksum, checksum=checksum, padding=padding),
        credentials=credentials, options=http_options())
    check("private checksum fallback and complete " + ("singleton" if padding == 98 else "empty") + " final page",
          outcome.returncode == 0 and any(row["url"].endswith("page=2") for row in request_rows(observed)),
          outcome.stderr.decode(errors="replace"))

named_tag = "release-2026.11"
named, named_details, _, _, named_requests = run_case("named-public-tag", release("named-public", version=named_tag), version=named_tag)
check("explicit nonnumeric release tag is preserved on the public acquisition path", named.returncode == 0 and
      named_details.get("version") == named_tag and all("/download/" + named_tag + "/" in url
      for url in named_requests.read_text().splitlines()), named.stderr.decode(errors="replace"))
named_private, named_private_details, _, _, named_private_requests = run_case("named-private-tag",
    private_release("named", version=named_tag), version=named_tag, credentials=credentials, options=http_options())
check("explicit nonnumeric tag resolves its exact private release instead of adding v", named_private.returncode == 0 and
      named_private_details.get("version") == named_tag and request_rows(named_private_requests)[0]["url"] ==
      api + "/releases/tags/" + named_tag, named_private.stderr.decode(errors="replace"))
private_latest, private_latest_details, _, _, private_latest_requests = run_case("private-latest",
    private_release("latest"), version=None, credentials=credentials, options=http_options())
check("authenticated latest reuses its validated release ID for complete asset discovery", private_latest.returncode == 0 and
      private_latest_details.get("version") == "v1.2.3" and request_rows(private_latest_requests)[0]["url"].endswith("/releases/latest") and
      not any("/releases/tags/" in row["url"] for row in request_rows(private_latest_requests)),
      private_latest.stderr.decode(errors="replace"))

rejected_auth, _, _, _, rejected_auth_requests = refusal("private-auth-refusal",
    downloads=private_release("auth-refusal"), expected=8, credentials=credentials,
    options=http_options(statuses={api + "/releases/tags/v1.2.3": 403}))
check("authentication refusal cannot fall back to a different account or anonymous download",
      len(request_rows(rejected_auth_requests)) == 1 and fixture_token.encode() not in rejected_auth.stderr)
latest_auth, _, _, _, latest_auth_requests = refusal("private-latest-rate-limit",
    downloads=private_release("latest-rate-limit"), expected=8, credentials=credentials, version=None,
    options=http_options(statuses={latest_api: 403}, redirects={latest_browser: latest_tag_url}))
check("authenticated latest rate limits never downgrade to anonymous browser discovery",
      [row["url"] for row in request_rows(latest_auth_requests)] == [latest_api] and
      fixture_token.encode() not in latest_auth.stderr)
unsafe_redirects = ("http://release-assets.githubusercontent.com/fixture/payload",
                    "https://api.github.com/repos/other/repository/releases/assets/77",
                    "https://release-assets.githubusercontent.com:444/fixture/payload")
for index, target in enumerate(unsafe_redirects):
    outcome, _, _, _, observed = refusal("private-unsafe-redirect-" + str(index), downloads=private_downloads,
        expected=8, credentials=credentials, options=http_options(redirects={payload_url: target}))
    check("unsafe redirect " + str(index) + " is refused before contacting its target",
          all(row["url"] != target for row in request_rows(observed)))

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
