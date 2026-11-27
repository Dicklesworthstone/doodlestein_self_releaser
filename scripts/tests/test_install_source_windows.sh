#!/usr/bin/env bash
# Genuine generated source installation: real Git pins, Rust/Go/Bun Windows PE
# families, retained receipts and the ordinary installation transaction. The
# portable fixture adapts host detection and Git/HTTP transport only; it does
# not claim live GitHub, native Windows ACL/NTFS or Windows process acceptance.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Exercise the actual generated policy and Windows Rust source engine without
# requiring a Windows Rust standard library on this host. Cargo metadata and
# compiler identities are real. The Windows compilation response is an explicit
# protocol boundary backed by a genuine Go-produced PE, so this lane proves
# argv/receipt/copy admission, not native Windows Rust compilation.
test_rust_features_policy() {
    local dependency
    for dependency in pwsh git go cargo rustc minisign python3 jq yq; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            printf 'SKIP: Windows Rust feature controls require %s\n' "$dependency"
            return 0
        fi
    done
    python3 - "$PROJECT_ROOT" <<'PY'
import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

project = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix='dsr-windows-rust-features-'))
print('Windows Rust feature evidence: ' + str(work), flush=True)
env = os.environ.copy()
for name, directory in {'DSR_CONFIG_DIR': 'config', 'DSR_STATE_DIR': 'state',
                        'DSR_CACHE_DIR': 'cache', 'DSR_INSTALLER_DIR': 'generated',
                        'XDG_CONFIG_HOME': 'xdg-config', 'XDG_STATE_HOME': 'xdg-state',
                        'XDG_CACHE_HOME': 'xdg-cache'}.items():
    env[name] = str(work / directory)
for name in ('DSR_REPOS_FILE', 'DSR_GH_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN'):
    env.pop(name, None)
env.update(CARGO_NET_OFFLINE='true', RUSTUP_AUTO_INSTALL='0')
(work / 'config/repos.d').mkdir(parents=True)
source = work / 'source'
(source / 'src').mkdir(parents=True)
(source / 'Cargo.toml').write_text('''[package]
name = "feature-probe"
version = "0.1.0"
edition = "2021"
[features]
default = ["default-on"]
default-on = []
cli = []
[[bin]]
name = "app"
path = "src/main.rs"
required-features = ["cli"]
''')
(source / 'src/main.rs').write_text('fn main() { println!("feature-probe"); }\n')

def run(arguments, label, extra=None, timeout=30):
    selected = env.copy()
    selected.update(extra or {})
    result = subprocess.run(list(map(str, arguments)), env=selected, cwd=project,
                            capture_output=True, timeout=timeout)
    (work / (label + '.stdout')).write_bytes(result.stdout)
    (work / (label + '.stderr')).write_bytes(result.stderr)
    if result.returncode:
        raise AssertionError(label + ': ' + result.stderr.decode(errors='replace'))
    return result

run(['cargo', 'generate-lockfile', '--offline', '--manifest-path', source / 'Cargo.toml'], 'lock')
run(['minisign', '-G', '-W', '-p', work / 'key.pub', '-s', work / 'key.sec'], 'keygen')
go_source = work / 'pe.go'
go_source.write_text('package main\nfunc main() {}\n')
pe = work / 'fixture.exe'
run(['go', 'build', '-trimpath', '-o', pe, go_source], 'pe-fixture',
    dict(GOOS='windows', GOARCH='amd64', GOFLAGS='', GOENV='off', GOWORK='off',
         GOTOOLCHAIN='local', CGO_ENABLED='0'), timeout=60)
config = dict(tool_name='feature-probe', repo='fixture/feature-probe', binary_name='app',
              language='rust', local_path=str(source), targets=['windows/amd64'],
              target_triples={'windows/amd64': 'x86_64-pc-windows-msvc'}, archive_format='zip',
              artifact_naming='${name}-${version}-${os}-${arch}',
              source_features=['cli'], source_no_default_features=True,
              minisign_pubkey=(work / 'key.pub').read_text().splitlines()[-1])
(work / 'config/repos.d/feature-probe.yaml').write_text(json.dumps(config))
run([project / 'dsr', '--json', '--non-interactive', 'installer', 'generate',
     'feature-probe', '--shell', 'powershell'], 'generate')
runtime = work / 'generated/feature-probe/install.ps1'
encoded = re.findall(r"\$script:DsrWindowsInstallPolicyBase64 = '([A-Za-z0-9+/=]+)'", runtime.read_text())
assert len(encoded) == 1
policy = json.loads(base64.b64decode(encoded[0]))
assert policy['source']['features'] == ['cli'] and policy['source']['no_default_features'] is True
print('PASS: generated Windows policy retains explicit Rust feature selection', flush=True)

fixture = dict(source=str(source), pe=str(pe), cargo=shutil.which('cargo'), rustc=shutil.which('rustc'),
               work=str(work), policy=policy,
               source_module=os.environ.get('DSR_TEST_INSTALL_SOURCE_WINDOWS_MODULE', ''))
workspace = work / 'workspace'
workspace_files = {
    'Cargo.toml': '''[package]
name = "root-provider"
version = "0.1.0"
edition = "2021"
[workspace]
members = ["member", "companion"]
default-members = ["member"]
resolver = "2"
[[bin]]
name = "root-app"
path = "src/main.rs"
''',
    'src/main.rs': 'fn main() { println!("root-provider"); }\n',
    'member/Cargo.toml': '''[package]
name = "member-provider"
version = "0.1.0"
edition = "2021"
[features]
cli = []
[[bin]]
name = "app"
path = "src/main.rs"
[[bin]]
name = "app-feature"
path = "src/feature.rs"
required-features = ["cli"]
''',
    'member/src/main.rs': 'fn main() { println!("member-provider"); }\n',
    'member/src/feature.rs': '#[cfg(not(feature="cli"))]\ncompile_error!("cli is required");\nfn main() { println!("member-feature"); }\n',
    'companion/Cargo.toml': '''[package]
name = "companion-provider"
version = "0.1.0"
edition = "2021"
[[bin]]
name = "helper"
path = "src/main.rs"
''',
    'companion/src/main.rs': 'fn main() { println!("companion-provider"); }\n',
}
for relative, content in workspace_files.items():
    destination = workspace / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(content)
run(['cargo', 'generate-lockfile', '--offline', '--manifest-path', workspace / 'Cargo.toml'], 'workspace-lock')
run(['git', 'init', '-q', '-b', 'main', workspace], 'workspace-init')
run(['git', '-C', workspace, 'add', '.'], 'workspace-add')
run(['git', '-C', workspace, '-c', 'user.name=DSR installer fixture',
     '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'Pinned Rust workspace'], 'workspace-commit')
fixture['workspace'] = str(workspace)
fixture['workspace_files'] = run(['git', '-C', workspace, 'ls-files', '-z'], 'workspace-files').stdout.decode().split('\0')[:-1]
fixture['workspace_commit'] = run(['git', '-C', workspace, 'rev-parse', 'HEAD'], 'workspace-pin').stdout.decode().strip()
fixture['workspace_cases'] = []
compiler = run(['rustc', '-vV'], 'oracle-compiler').stdout.decode()
host = re.search(r'^host: (\S+)$', compiler, re.M).group(1)
for name, subdir, package, features, binaries in (
        ('default-member', '.', '', [], ['app']),
        ('member-feature', '.', 'member-provider', ['cli'], ['app-feature']),
        ('member-current', 'companion', '', [], ['helper']),
        ('workspace-family', '.', '', [], ['app', 'helper'])):
    arguments = ['cargo', 'build', '--locked', '--offline', '--release', '--message-format=json',
                 '--manifest-path', workspace / subdir / 'Cargo.toml', '--target', host,
                 '--target-dir', work / 'oracle-target']
    if package:
        arguments += ['--package', package]
    elif len(binaries) > 1:
        arguments += ['--workspace']
    for feature in features:
        arguments += ['--features', feature]
    for binary in binaries:
        arguments += ['--bin', binary]
    oracle = run(arguments, 'oracle-' + name,
                 dict(RUSTC=shutil.which('rustc'), RUSTC_WRAPPER='', RUSTC_WORKSPACE_WRAPPER='',
                      RUSTFLAGS='', CARGO_ENCODED_RUSTFLAGS=''), timeout=45)
    records = [json.loads(line) for line in oracle.stdout.decode().splitlines() if line.startswith('{')]
    providers = [record for record in records if record.get('reason') == 'compiler-artifact'
                 and record.get('target', {}).get('name') in binaries and record.get('executable')]
    assert len(providers) == len(binaries), name + ': actual Cargo did not identify the requested family'
    for provider in providers:
        run([provider['executable']], 'oracle-output-' + name + '-' + provider['target']['name'])
    fixture['workspace_cases'].append(dict(name=name, subdir=subdir, package=package, features=features,
                                          binaries=[binary + '.exe' for binary in binaries], providers=providers))
    print('PASS: real Cargo builds and executes ' + name + ' from the committed workspace', flush=True)
(work / 'fixture.json').write_text(json.dumps(fixture))
driver = work / 'driver.ps1'
driver.write_text(r'''param([string]$Runtime, [string]$FixturePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixture = ConvertFrom-Json ([IO.File]::ReadAllText($FixturePath)) -AsHashtable
$text = [IO.File]::ReadAllText($Runtime)
$marker = '# DSR_WINDOWS_INSTALL_DISPATCH:'
$offset = $text.IndexOf($marker, [StringComparison]::Ordinal)
if ($offset -le 0 -or $offset -ne $text.LastIndexOf($marker, [StringComparison]::Ordinal)) { throw 'Invalid dispatch marker' }
. ([scriptblock]::Create($text.Substring(0, $offset)))
if ($fixture.source_module) { . ([scriptblock]::Create([IO.File]::ReadAllText($fixture.source_module))) }
$script:FeatureChecks = 0
$script:FeatureFailures = 0
function Check-FeatureCase([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:FeatureChecks++; Write-Host ('PASS: ' + $Name) }
    else { $script:FeatureFailures++; Write-Host ('FAIL: ' + $Name) }
}
function New-FeaturePolicy {
    return @{ language='rust'; subdir='.'; package='' }
}
$valid = @( (New-FeaturePolicy),
    @{language='rust';subdir='.';package='';features=@();no_default_features=$false},
    @{language='rust';subdir='.';package='';features=@('cli','feature-probe/default-on','_private','named.feature+1','CLI')},
    @{language='rust';subdir='.';package='';features=@(0..63 | ForEach-Object { 'feature' + $_ })},
    @{language='rust';subdir='.';package='';features=@('a' * 128);no_default_features=$true})
foreach ($sourcePolicy in $valid) { Assert-DsrSourcePolicy $sourcePolicy }
Check-FeatureCase 'legacy, empty, qualified, case-distinct and bounded feature policies are accepted' $true
$invalid = @( $null, 'cli', 7, @(''), @('cli','cli'), @('--all-features'),
    @('cli,other'), @('cli other'), @("cli`n"), @("cli`t"), @('pkg/'), @('/cli'),
    @('pkg/cli/other'), @('dep:cli'), @('a' * 129), @(0..64 | ForEach-Object { 'feature' + $_ }))
$index = 0
foreach ($features in $invalid) {
    $candidate = New-FeaturePolicy
    $candidate.features = $features
    $refused = $false
    try { Assert-DsrSourcePolicy $candidate } catch { $refused = $true }
    Check-FeatureCase ('invalid feature selector is refused: ' + $index) $refused
    $index++
}
foreach ($value in @($null, 0, 1, 'true', 'false', @())) {
    $candidate = New-FeaturePolicy
    $candidate.no_default_features = $value
    $refused = $false
    try { Assert-DsrSourcePolicy $candidate } catch { $refused = $true }
    Check-FeatureCase ('non-Boolean default-feature policy is refused: ' + $index) $refused
    $index++
}
foreach ($language in @('go','bun','typescript')) {
    foreach ($property in @('features','no_default_features')) {
        $candidate = @{language=$language;subdir='.';entry=''}
        if ($property -ceq 'features') { $candidate.features=@() } else { $candidate.no_default_features=$false }
        $refused = $false
        try { Assert-DsrSourcePolicy $candidate } catch { $refused = $true }
        Check-FeatureCase ($language + ' rejects Rust-only policy ' + $property) $refused
    }
}
$script:RealFeatureCommand = ${function:Invoke-DsrSourceCommand}
$script:FeatureCalls = [Collections.Generic.List[object]]::new()
$script:FeatureMetadata = $null
$script:WorkspaceCase = $null
$script:ArtifactChange = ''
function Invoke-DsrSourceCommand {
    param([string]$Executable, [string[]]$Arguments, [string]$Directory, [string]$Log,
        [int]$Timeout, $Environment=@{}, [int]$FailureCode=6, [switch]$Capture)
    $script:FeatureCalls.Add(@{executable=$Executable;arguments=@($Arguments)})
    if ($Arguments[0] -ceq 'build') {
        # This is the only compiler protocol fixture. Metadata, private output
        # admission, PE validation, hashing and returned receipts remain real.
        $target = $Arguments[[Array]::IndexOf($Arguments, '--target') + 1]
        $directory = New-DsrDirectoryChain ([IO.Path]::Combine($Environment.CARGO_TARGET_DIR, $target, 'release'))
        if ($null -ne $script:WorkspaceCase) {
            $records = @()
            foreach ($provider in $script:WorkspaceCase.providers) {
                $record = ConvertFrom-DsrJson (ConvertTo-Json -Depth 30 -Compress -InputObject $provider)
                $destination = [IO.Path]::Combine($directory, ($record.target.name + '.exe'))
                Copy-DsrNewFile $fixture.pe $destination
                $record.executable = $destination
                $record.filenames = @($destination)
                switch ($script:ArtifactChange) {
                    'manifest' { $record.manifest_path = [IO.Path]::Combine($fixture.workspace, 'companion', 'Cargo.toml') }
                    'entry' { $record.target.src_path = [IO.Path]::Combine($fixture.workspace, 'companion', 'src', 'main.rs') }
                    'missing-manifest' { $record.Remove('manifest_path') }
                    'missing-entry' { $record.target.Remove('src_path') }
                    'package' { $record.package_id = 'unselected-package' }
                }
                $records += ConvertTo-Json -Depth 30 -Compress -InputObject $record
            }
            return $records -join "`n"
        }
        $destination = [IO.Path]::Combine($directory, 'app.exe')
        Copy-DsrNewFile $fixture.pe $destination
        $package = @($script:FeatureMetadata.packages | Where-Object { $_.name -ceq 'feature-probe' })[0]
        $entry = @($package.targets | Where-Object { $_.name -ceq 'app' -and 'bin' -cin $_.kind })[0]
        return (@{reason='compiler-artifact';package_id=$package.id;manifest_path=$package.manifest_path;
            target=@{name='app';kind=@('bin');src_path=$entry.src_path};
            executable=$destination} | ConvertTo-Json -Depth 8 -Compress)
    }
    $result = & $script:RealFeatureCommand @PSBoundParameters
    if ($Arguments[0] -ceq 'metadata') { $script:FeatureMetadata = ConvertFrom-Json $result -AsHashtable }
    if ($Capture) { return $result }
}
$selection = $fixture.policy.platforms['windows/amd64']
foreach ($case in @(
    @{name='legacy';source=(New-FeaturePolicy);features=@();disabled=$false},
    @{name='empty';source=@{language='rust';subdir='.';package='';features=@();no_default_features=$false};features=@();disabled=$false},
    @{name='enabled';source=$fixture.policy.source;features=@('cli');disabled=$true},
    @{name='qualified';source=@{language='rust';subdir='.';package='feature-probe';features=@('feature-probe/cli')};features=@('feature-probe/cli');disabled=$false})) {
    $script:FeatureCalls.Clear()
    $caseRoot = New-DsrPrivateDirectory ([IO.Path]::Combine($fixture.work, $case.name))
    $output = New-DsrPrivateDirectory ([IO.Path]::Combine($caseRoot, 'output'))
    $logs = New-DsrPrivateDirectory ([IO.Path]::Combine($caseRoot, 'logs'))
    $policy = @{repo='fixture/feature-probe';source=$case.source}
    $receipt = Build-DsrRustSourceOutputs $policy $selection 'windows/amd64' $fixture.source `
        @('Cargo.toml','Cargo.lock','src/main.rs') $fixture.source $output $logs $caseRoot 20 $fixture.cargo $fixture.rustc
    $requests = @($script:FeatureCalls | Where-Object { $_.arguments[0] -cin @('metadata','build') })
    Check-FeatureCase ($case.name + ' uses one real metadata request and one observed build request') ($requests.Count -eq 2)
    foreach ($request in $requests) {
        $selected = @()
        for ($i=0; $i -lt $request.arguments.Count; $i++) {
            if ($request.arguments[$i] -ceq '--features') { $selected += $request.arguments[++$i] }
        }
        if ($request.arguments[0] -ceq 'metadata') {
            Check-FeatureCase ($case.name + ' metadata describes declarations without resolving build features') `
                ($selected.Count -eq 0 -and '--no-default-features' -cnotin $request.arguments)
        } else {
            Check-FeatureCase ($case.name + ' build preserves literal feature argv and default policy') `
                (((ConvertTo-Json -Compress -InputObject @($selected)) -ceq (ConvertTo-Json -Compress -InputObject @($case.features))) -and
                 (('--no-default-features' -cin $request.arguments) -eq $case.disabled))
        }
    }
    Check-FeatureCase ($case.name + ' receipt retains exactly the selected Cargo feature policy') `
        (($receipt.cargo_features -is [array]) -and
         ((ConvertTo-Json -Compress -InputObject @($receipt.cargo_features)) -ceq (ConvertTo-Json -Compress -InputObject @($case.features))) -and
         ($receipt.cargo_no_default_features -is [bool]) -and ($receipt.cargo_no_default_features -eq $case.disabled))
    Check-FeatureCase ($case.name + ' preserves actual PE payload bytes during output admission') `
        (Test-DsrSameEvidence (Get-DsrFileEvidence $fixture.pe) (Get-DsrFileEvidence ([IO.Path]::Combine($output, 'app.exe'))))
}
$script:FeatureCalls.Clear()
$invalidPolicy = @{repo='fixture/feature-probe';source=@{language='rust';subdir='.';package='';features=@('--all-features')}}
$before = @(Get-ChildItem -LiteralPath $fixture.work -Force).Count
$refused = $false
try {
    $null = Build-DsrRustSourceOutputs $invalidPolicy $selection 'windows/amd64' $fixture.source `
        @('Cargo.toml','Cargo.lock','src/main.rs') $fixture.source '' '' ([IO.Path]::Combine($fixture.work, 'invalid')) 20 $fixture.cargo $fixture.rustc
} catch { $refused=$true }
Check-FeatureCase 'compiler boundary rejects malformed policy before tools or output allocation' `
    ($refused -and $script:FeatureCalls.Count -eq 0 -and @(Get-ChildItem -LiteralPath $fixture.work -Force).Count -eq $before)
$script:ProviderFailures = 0
function Check-ProviderCase([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:FeatureChecks++; Write-Host ('PASS: ' + $Name) }
    else { $script:ProviderFailures++; Write-Host ('FAIL: ' + $Name) }
}
function Invoke-WorkspaceProviderCase($Case, [string]$Suffix) {
    $script:FeatureCalls.Clear()
    $script:WorkspaceCase = $Case
    $caseRoot = New-DsrPrivateDirectory ([IO.Path]::Combine($fixture.work, ('provider-' + $Case.name + $Suffix)))
    $output = New-DsrPrivateDirectory ([IO.Path]::Combine($caseRoot, 'output'))
    $logs = New-DsrPrivateDirectory ([IO.Path]::Combine($caseRoot, 'logs'))
    $sourcePolicy = @{language='rust';subdir=$Case.subdir;package=$Case.package;features=@($Case.features)}
    $buildRoot = if ($Case.subdir -ceq '.') { $fixture.workspace } else { [IO.Path]::Combine($fixture.workspace, $Case.subdir) }
    $selected = @{target_triple='x86_64-pc-windows-msvc';binaries=@($Case.binaries)}
    $receipt = $null
    $failure = $null
    try {
        $receipt = Build-DsrRustSourceOutputs @{repo='fixture/workspace';source=$sourcePolicy} $selected `
            'windows/amd64' $fixture.workspace @($fixture.workspace_files) $buildRoot $output $logs $caseRoot `
            20 $fixture.cargo $fixture.rustc
    } catch { $failure = $_.Exception }
    return @{receipt=$receipt;failure=$failure;output=$output}
}
foreach ($case in $fixture.workspace_cases) {
    $result = Invoke-WorkspaceProviderCase $case ''
    Check-ProviderCase ($case.name + ' admits the same providers as an actual Cargo build') ($null -eq $result.failure)
    if ($null -ne $result.failure) { Write-Host ('Observed refusal: ' + $result.failure.Message); continue }
    foreach ($provider in $case.providers) {
        $name = $provider.target.name + '.exe'
        $entry = @($result.receipt.source_entries | Where-Object { $_.name -ceq $name })
        Check-ProviderCase ($case.name + ' receipt binds real package, manifest and entry for ' + $name) `
            ($entry.Count -eq 1 -and $entry[0].package_id -ceq $provider.package_id -and
             $entry[0].manifest -ceq [IO.Path]::GetRelativePath($fixture.workspace, $provider.manifest_path).Replace('\', '/') -and
             $entry[0].entry -ceq [IO.Path]::GetRelativePath($fixture.workspace, $provider.target.src_path).Replace('\', '/'))
        Check-ProviderCase ($case.name + ' stages the verified PE bytes for ' + $name) `
            (Test-DsrSameEvidence (Get-DsrFileEvidence $fixture.pe) (Get-DsrFileEvidence ([IO.Path]::Combine($result.output, $name))))
    }
    $requests = @($script:FeatureCalls | Where-Object { $_.arguments[0] -ceq 'build' })
    $features = @()
    $package = ''
    $bins = @()
    if ($requests.Count -eq 1) {
        $arguments = $requests[0].arguments
        for ($index=0; $index -lt $arguments.Count; $index++) {
            if ($arguments[$index] -ceq '--features') { $features += $arguments[++$index] }
            elseif ($arguments[$index] -ceq '--package') { $package = $arguments[++$index] }
            elseif ($arguments[$index] -ceq '--bin') { $bins += $arguments[++$index] }
        }
    }
    Check-ProviderCase ($case.name + ' preserves actual build package, features and complete binary selection') `
        ($requests.Count -eq 1 -and $package -ceq $case.package -and
         (ConvertTo-Json -Compress -InputObject @($features)) -ceq (ConvertTo-Json -Compress -InputObject @($case.features)) -and
         (ConvertTo-Json -Compress -InputObject @($bins)) -ceq (ConvertTo-Json -Compress -InputObject @($case.binaries | ForEach-Object { $_.Substring(0, $_.Length - 4) })) -and
         (('--workspace' -cin $requests[0].arguments) -eq ($case.binaries.Count -gt 1 -and -not $case.package)))
}
$case = @($fixture.workspace_cases | Where-Object { $_.name -ceq 'member-current' })[0]
# Use a distinct real source path for the identity attacks against helper.
$case = ConvertFrom-DsrJson (ConvertTo-Json -Depth 30 -Compress -InputObject $case)
$case.subdir = 'member'
$case.package = 'member-provider'
$case.features = @()
$case.binaries = @('app.exe')
$case.providers = @(@($fixture.workspace_cases | Where-Object { $_.name -ceq 'default-member' })[0].providers)
foreach ($mutation in @('manifest','entry','missing-manifest','missing-entry','package')) {
    $script:ArtifactChange = $mutation
    $result = Invoke-WorkspaceProviderCase $case ('-' + $mutation)
    Check-ProviderCase ('refuses changed artifact provider ' + $mutation) `
        ($null -ne $result.failure -and $result.failure.Data.Contains('DsrExitCode') -and $result.failure.Data['DsrExitCode'] -eq 6)
    Check-ProviderCase ('changed artifact provider stages no selected executable: ' + $mutation) `
        (-not [IO.File]::Exists([IO.Path]::Combine($result.output, 'app.exe')))
}
Write-Host ('Windows Rust provider checks: ' + $script:ProviderFailures + ' failed')
if ($script:ProviderFailures -or $script:FeatureFailures) { exit 1 }
Write-Host ('Windows Rust feature boundary checks: ' + $script:FeatureChecks + ' passed, 0 failed')
''')
result = run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', driver,
              runtime, work / 'fixture.json'], 'controls', timeout=90)
print(result.stdout.decode(), end='', flush=True)
PY
}

if [[ "$#" == 1 && "$1" == --rust-features-only ]]; then
    test_rust_features_policy
    exit $?
fi

dependencies=(pwsh git go cargo rustc minisign python3 jq yq)
if [[ " $* " == *' --bun-only '* || " $* " == *' --bun-workspaces-only '* ]]; then
    dependencies=(pwsh git bun minisign python3 jq yq)
elif [[ " $* " == *' --freshness-only '* || " $* " == *' --fallback-only '* || " $* " == *' --acquisition-errors-only '* || " $* " == *' --freshness-deadline-only '* || " $* " == *' --go-only '* || " $* " == *' --go-workspace-only '* || " $* " == *' --go-modules-only '* || " $* " == *' --submodules-only '* || " $* " == *' --symlinks-only '* ]]; then
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
import time
import zipfile

arguments = argparse.ArgumentParser(description="Generated Windows Rust/Go/Bun source installation regression")
arguments.add_argument("project", type=Path)
arguments.add_argument("--baseline-project", type=Path, help="Frozen checkout before Windows source installation")
arguments.add_argument("--rust-baseline-project", type=Path, help="Frozen checkout before Windows Rust source installation")
arguments.add_argument("--workspace-baseline-project", type=Path, help="Frozen checkout before committed Go workspace support")
arguments.add_argument("--go-workspace-only", action="store_true", help="Run the generated Go workspace caller regression")
arguments.add_argument("--go-modules-only", action="store_true", help="Run ordinary Go module source-custody and vendoring controls")
arguments.add_argument("--submodules-only", action="store_true", help="Run recursive pinned Git submodule source installation controls")
arguments.add_argument("--submodule-baseline-project", type=Path, help="Frozen checkout before Windows source submodule support")
arguments.add_argument("--symlinks-only", action="store_true", help="Run authenticated tracked-link materialization controls")
arguments.add_argument("--symlink-baseline-project", type=Path, help="Frozen checkout before Windows source tracked-link support")
arguments.add_argument("--module-baseline-project", type=Path, help="Frozen checkout before ordinary Go module confinement")
arguments.add_argument("--go-only", action="store_true", help="Run Go source and signed-release controls without Rust compilation")
arguments.add_argument("--bun-only", action="store_true", help="Run genuine Bun/TypeScript Windows source installation controls")
arguments.add_argument("--bun-workspaces-only", action="store_true", help="Run generated Bun workspace source installation controls")
arguments.add_argument("--bun-baseline-project", type=Path, help="Frozen checkout before Windows Bun source installation")
arguments.add_argument("--freshness-only", action="store_true", help="Run signed release-first freshness and pinned source-upgrade controls")
arguments.add_argument("--fallback-only", action="store_true", help="Run classified unavailable-release source fallback controls")
arguments.add_argument("--acquisition-errors-only", action="store_true", help="Keep HTTPS trust/protocol failures terminal while admitting real availability fallback")
arguments.add_argument("--fallback-baseline-project", type=Path, help="Frozen checkout before unavailable-release source fallback")
arguments.add_argument("--freshness-deadline-only", action="store_true", help="Exercise the actual owned freshness HTTP deadline")
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
    function Get-DsrSourceRepositoryUrl {
        param([string]$Repository)
        if ($script:Fixture.Contains('repositories')) {
            if (-not $script:Fixture.repositories.Contains($Repository)) { throw 'Unmapped fixture source repository' }
            return $script:Fixture.repositories[$Repository]
        }
        return $script:Fixture.repository_url
    }
    $script:RealSourceGit = ${function:Invoke-DsrSourceGit}
    function Invoke-DsrSourceGit {
        param([string]$Git, [string[]]$Arguments, [string]$Directory, [string]$Log,
            [int]$Timeout, [string]$Repository, $Environment, [switch]$Capture)
        $Environment.GIT_ALLOW_PROTOCOL = 'file'
        & $script:RealSourceGit $Git (@('-c', 'protocol.file.allow=always') + $Arguments) $Directory $Log $Timeout $Repository $Environment -Capture:$Capture
    }
    $script:RealSourceCommand = ${function:Invoke-DsrSourceCommand}
    $script:MutatedSource = $false
    $script:MutatedCheckout = $false
    function Invoke-DsrSourceCommand {
        param([string]$Executable, [string[]]$Arguments, [string]$Directory, [string]$Log,
            [int]$Timeout, $Environment = @{}, [int]$FailureCode = 6, [switch]$Capture)
        [IO.File]::AppendAllText($script:Fixture.commands, ((@{ executable = $Executable; arguments = @($Arguments); directory = $Directory;
            go_environment = @{ GOWORK = $Environment['GOWORK']; GOENV = $Environment['GOENV'];
                GOFLAGS = $Environment['GOFLAGS']; GO111MODULE = $Environment['GO111MODULE'];
                GOTOOLCHAIN = $Environment['GOTOOLCHAIN'] };
            bun_environment = @{ NODE_OPTIONS = $Environment['NODE_OPTIONS']; BUN_OPTIONS = $Environment['BUN_OPTIONS'] }
            git_authorization_sha256 = $(if ($Environment['DSR_INSTALLER_GIT_AUTHORIZATION']) {
                Get-DsrBytesHash ([Text.Encoding]::UTF8.GetBytes($Environment['DSR_INSTALLER_GIT_AUTHORIZATION']))
            } else { '' })
        } | ConvertTo-Json -Compress) + "`n"))
        $result = & $script:RealSourceCommand @PSBoundParameters
        if ($script:Fixture.Contains('mutate_checkout_member') -and -not $script:MutatedCheckout -and
            'checkout' -cin $Arguments) {
            $member = [IO.Path]::Combine($Directory, $script:Fixture.mutate_checkout_member)
            if ([IO.File]::Exists($member)) {
                [IO.File]::AppendAllText($member, 'x')
                $script:MutatedCheckout = $true
            }
        }
        if ($script:Fixture.Contains('acquisition_pause_ms') -and 'fetch' -cin $Arguments) {
            [Threading.Thread]::Sleep([int]$script:Fixture.acquisition_pause_ms)
        }
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
        if ($script:Fixture.Contains('inject_module_files') -and 'checkout' -cin $Arguments) {
            foreach ($name in $script:Fixture.inject_module_files.Keys) {
                $path = [IO.Path]::Combine($Directory, $name)
                $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
                [IO.File]::WriteAllText($path, $script:Fixture.inject_module_files[$name])
            }
        }
        if ($script:Fixture.Contains('mutate_source') -and $script:Fixture.mutate_source -and
            -not $script:MutatedSource -and $Arguments[0] -ceq 'build') {
            $member = if ($script:Fixture.Contains('mutate_source_member')) { $script:Fixture.mutate_source_member } else { 'apps/primary/main.go' }
            [IO.File]::AppendAllText([IO.Path]::Combine($Directory, $member), "`n// injected tracked-source mutation`n")
            $script:MutatedSource = $true
        }
        if ($script:Fixture.Contains('mutate_submodule_head') -and $script:Fixture.mutate_submodule_head -and
            -not $script:MutatedSource -and $Arguments[0] -ceq 'build') {
            $child = [IO.Path]::Combine($Directory, 'nested/lib')
            $head = (& git -C $child rev-parse HEAD).Trim()
            $tree = (& git -C $child rev-parse 'HEAD^{tree}').Trim()
            $replacement = (& git -C $child -c 'user.name=DSR Source Fixture' -c 'user.email=fixture@example.invalid' `
                commit-tree $tree -p $head -m 'Different commit with identical tracked bytes').Trim()
            if ($LASTEXITCODE -ne 0) { throw 'Submodule identity fixture could not create its real commit' }
            [IO.File]::WriteAllText([IO.Path]::Combine($child, '.git/HEAD'), $replacement + "`n")
            $script:MutatedSource = $true
        }
        if ($script:Fixture.Contains('mutate_submodule_index') -and $script:Fixture.mutate_submodule_index -and
            -not $script:MutatedSource -and $Arguments[0] -ceq 'build') {
            $child = [IO.Path]::Combine($Directory, 'nested/lib')
            & git -C $child update-index --chmod=+x -- value.go
            if ($LASTEXITCODE -ne 0) { throw 'Submodule index fixture could not change its staged file mode' }
            $script:MutatedSource = $true
        }
        if ($script:Fixture.Contains('mutate_link_evidence') -and $script:Fixture.mutate_link_evidence -and
            -not $script:MutatedSource -and $Arguments[0] -ceq 'build') {
            $evidence = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($Log)) -Recurse -File -Filter 'link-*-literal')
            if ($evidence.Count -eq 0) { throw 'Tracked-link fixture could not find its retained literal evidence' }
            [IO.File]::AppendAllText($evidence[0].FullName, 'x')
            $script:MutatedSource = $true
        }
        if ($script:Fixture.Contains('mutate_link_index') -and $script:Fixture.mutate_link_index -and
            -not $script:MutatedSource -and $Arguments[0] -ceq 'build') {
            $replacement = (& git -C $Directory hash-object -w --no-filters -- shared/message.txt).Trim()
            if ($LASTEXITCODE -ne 0) { throw 'Tracked-link fixture could not create its replacement Git blob' }
            & git -C $Directory update-index --cacheinfo "120000,$replacement,apps/primary/message.txt"
            if ($LASTEXITCODE -ne 0) { throw 'Tracked-link fixture could not replace the staged literal link blob' }
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
public sealed class DsrSourceFailureStream : Stream {
    private readonly Exception failure;
    private bool started;
    public DsrSourceFailureStream(HttpRequestError error) {
        failure = new HttpIOException(error, "Injected body failure https://example.invalid/?token=transport-secret");
    }
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) {
        if (!started && count > 0) { started = true; buffer[offset] = 0x50; return 1; }
        throw failure;
    }
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) {
        try { return Task.FromResult(Read(buffer, offset, count)); }
        catch (Exception error) { return Task.FromException<int>(error); }
    }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
    public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
}
public sealed class DsrSourceFixtureHandler : HttpMessageHandler {
    private readonly JsonElement fixture;
    public DsrSourceFixtureHandler(string path) {
        using (JsonDocument document = JsonDocument.Parse(File.ReadAllText(path))) {
            fixture = document.RootElement.Clone();
        }
    }
    private static async Task<HttpResponseMessage> WaitForDeadline(CancellationToken token) {
        await Task.Delay(Timeout.Infinite, token);
        throw new InvalidOperationException("Unbounded fixture unexpectedly completed");
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
            string kind = failure.GetString();
            string message = "Injected HTTPS failure https://example.invalid/?token=transport-secret";
            if (kind == "cancel") { throw new OperationCanceledException(message); }
            if (kind == "deadline") { return WaitForDeadline(token); }
            if (kind.StartsWith("body-", StringComparison.Ordinal)) {
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) {
                    Content = new StreamContent(new DsrSourceFailureStream(Enum.Parse<HttpRequestError>(kind.Substring(5))))
                });
            }
            if (kind == "network") { throw new HttpRequestException(HttpRequestError.ConnectionError, message); }
            if (kind == "legacy") { throw new HttpRequestException(message); }
            if (kind == "nested-auth") {
                throw new HttpRequestException(HttpRequestError.ConnectionError, message,
                    new System.Security.Authentication.AuthenticationException(message));
            }
            if (kind == "nested-cancel") {
                throw new HttpRequestException(HttpRequestError.ConnectionError, message, new OperationCanceledException(message));
            }
            if (kind == "nested-unknown") {
                throw new HttpRequestException(HttpRequestError.ConnectionError, message, new HttpRequestException(message));
            }
            if (kind == "aggregate-auth") {
                throw new HttpRequestException(HttpRequestError.ConnectionError, message,
                    new AggregateException(new IOException(message), new System.Security.Authentication.AuthenticationException(message)));
            }
            if (kind == "status-denied") {
                throw new HttpRequestException(HttpRequestError.ConnectionError, message, null, HttpStatusCode.Unauthorized);
            }
            throw new HttpRequestException(Enum.Parse<HttpRequestError>(kind), message);
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
if ($fixture.Contains('exception_graph_probe')) {
    $message = 'Untrusted diagnostic https://example.invalid/?token=transport-secret'
    $connection = [Net.Http.HttpRequestException]::new([Net.Http.HttpRequestError]::ConnectionError, $message, $null, $null)
    $tls = [Net.Http.HttpRequestException]::new([Net.Http.HttpRequestError]::SecureConnectionError, $message, $null, $null)
    $auth = [Security.Authentication.AuthenticationException]::new($message)
    $unknown = [Net.Http.HttpRequestException]::new($message)
    $aggregate = [AggregateException]::new($message, [Exception[]]@($connection, $auth))
    $cases = @(
        @{ name = 'owned-plain'; failure = [OperationCanceledException]::new($message); expired = $true },
        @{ name = 'owned-connection'; failure = [OperationCanceledException]::new($message, $connection); expired = $true },
        @{ name = 'owned-tls'; failure = [OperationCanceledException]::new($message, $tls); expired = $true },
        @{ name = 'owned-auth'; failure = [OperationCanceledException]::new($message, $auth); expired = $true },
        @{ name = 'owned-unknown'; failure = [OperationCanceledException]::new($message, $unknown); expired = $true },
        @{ name = 'owned-aggregate'; failure = [OperationCanceledException]::new($message, $aggregate); expired = $true },
        @{ name = 'explicit-plain'; failure = [OperationCanceledException]::new($message); expired = $false },
        @{ name = 'explicit-tls'; failure = [OperationCanceledException]::new($message, $tls); expired = $false }
    )
    $results = [Collections.Generic.List[object]]::new()
    foreach ($probe in $cases) {
        try { Stop-DsrHttpTransportFailure $probe.failure 'Bounded transport refusal' $probe.expired }
        catch {
            $failure = $_.Exception
            $code = if ($failure.Data.Contains('DsrExitCode')) { [int]$failure.Data['DsrExitCode'] } else { 7 }
            $results.Add(@{ name = $probe.name; exit_code = $code;
                unavailable = (Test-DsrReleaseAcquisitionUnavailable $failure); message = $failure.Message })
        }
    }
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject @($results.ToArray()) -Depth 8 -Compress))
    exit 0
}
if ($fixture.Contains('acquisition_matrix')) {
    # Run the complete public caller for each error in one PowerShell process.
    # Each case still gets its own request log, cache and production transaction.
    # The real HttpClient handler, source engine and installation code are used.
    $results = [Collections.Generic.List[object]]::new()
    foreach ($casePath in $fixture.acquisition_matrix) {
        $script:FixturePath = [string]$casePath
        $script:Fixture = ConvertFrom-Json ([IO.File]::ReadAllText($casePath)) -AsHashtable
        $parameters = $script:Fixture.parameters
        $output = [IO.StringWriter]::new()
        $previousOutput = [Console]::Out
        try {
            [Console]::SetOut($output)
            $code = Invoke-DsrWindowsInstaller @parameters
        } finally { [Console]::SetOut($previousOutput) }
        $results.Add(@{ case_path = [string]$casePath; exit_code = $code; stdout = $output.ToString() })
        $output.Dispose()
    }
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject @($results.ToArray()) -Depth 12 -Compress))
    exit 0
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
        # None means the caller omitted this optional argument. An explicitly
        # supplied empty string remains present and must be rejected.
        if selected_params.get("SourceIfStale") is None:
            selected_params.pop("SourceIfStale", None)
        return invoke("freshness-" + label, parameters=selected_params, selected_runtime=selected,
                      downloads=downloads if payload is None else payload, http_client_fixture=True, **changes)

    def requests(fixture):
        path = Path(fixture["requests"])
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def release_installed(result, fixture):
        prefix = Path(fixture["parameters"]["Prefix"])
        return result.get("version") == "v1.2.3" and result.get("signature_verified") is True and \
            all((prefix / name).is_file() and digest(prefix / name) == value for name, value in original.items())

    if options.freshness_deadline_only:
        started = time.monotonic()
        outcome, result, fixture = run("owned-deadline", transport_failures={head_url: "deadline"})
        elapsed = time.monotonic() - started
        check("the real unchanged 60-second metadata deadline keeps the verified release",
              outcome.returncode == 0 and elapsed >= 55 and release_installed(result, fixture) and
              not calls(fixture) and result.get("freshness", {}).get("status") == "unknown",
              f"elapsed={elapsed:.3f}s " + outcome.stderr.decode(errors="replace"))
        return

    if options.fallback_only or options.acquisition_errors_only:
        latest_url = api + "/releases/latest"
        public_latest = "https://github.com/fixture/source-demo/releases/latest"
        public_tag = "https://github.com/fixture/source-demo/releases/tag/v1.2.3"
        public_payload = "https://github.com/fixture/source-demo/releases/download/v1.2.3/" + asset
        private_payload = api + "/releases/assets/1"
        inventory_url = api + "/releases/4242/assets?per_page=100&page=1"
        exact_url = api + "/releases/tags/v1.2.3"
        downloads[exact_url] = downloads[latest_url]

        def fallback(label, *, params=None, **changes):
            chosen = {"SourceIfStale": None}
            chosen.update(params or {})
            return run("fallback-" + label, params=chosen, **changes)

        def source_selected(result, fixture, reference, commit):
            prefix = Path(fixture["parameters"]["Prefix"])
            rows = result.get("binaries", [])
            fetches = [row for row in calls(fixture) if "fetch" in row["arguments"]]
            return result.get("method") == "source" and result.get("signed_release") is False and \
                result.get("signature_verified") is False and "version" not in result and \
                result.get("source", {}).get("requested_ref") == reference and \
                result["source"].get("source_commit") == commit and \
                {row["name"] for row in rows} == set(original) and \
                len(fetches) == 1 and fetches[0]["arguments"][-1] == reference and all(
                    machine(prefix / row["name"]) == 0x8664 and digest(prefix / row["name"]) == row["sha256"]
                    for row in rows) and result.get("source_fallback", {}).get("requested_ref") == reference and \
                json.loads(Path(result["source_receipt"]["path"]).read_text()) == result["source"]

        if options.acquisition_errors_only:
            # The old blanket transient marker compiled source for these
            # failures. Exercise the generated caller and its real exception
            # handling, not a separately reconstructed classification table.
            terminal_errors = (
                "Unknown", "SecureConnectionError", "UserAuthenticationError", "ProxyTunnelError",
                "InvalidResponse", "HttpProtocolError", "VersionNegotiationError",
                "ExtendedConnectNotSupported", "ConfigurationLimitExceeded",
            )
            matrix = []
            scenarios = []
            for stage, failed_url, statuses in (
                ("discovery", latest_url, {}),
                ("public-head", public_latest, {latest_url: 503}),
                ("payload", public_payload, {}),
            ):
                for error in terminal_errors:
                    scenarios.append((stage + "-" + error, failed_url, error, statuses, 8))
            for error in ("legacy", "nested-auth", "nested-unknown", "aggregate-auth", "status-denied",
                          "body-InvalidResponse", "body-HttpProtocolError"):
                scenarios.append(("payload-" + error, public_payload, error, {}, 8))
            for stage, failed_url in (("discovery", latest_url), ("public-head", public_latest),
                                      ("payload", public_payload)):
                for error in ("cancel", "nested-cancel"):
                    scenarios.append((stage + "-" + error, failed_url, error,
                                      {latest_url: 503} if stage == "public-head" else {}, 5))
            for label, failed_url, error, statuses, code in scenarios:
                case = root / ("transport-" + label + ".json")
                fixture = {
                    "platform": "windows/amd64", "repository_url": upstream.as_uri(),
                    "parameters": {"FromSource": False, "AllowSourceBuild": True, "SourceTimeout": 60,
                                   "SourceRef": "", "Prefix": str(release_prefix),
                                   "CacheDir": str(root / ("transport-" + label + "-cache")), "Yes": True, "Json": True},
                    "requests": str(root / ("transport-" + label + ".requests")),
                    "commands": str(root / ("transport-" + label + ".commands")),
                    "downloads": downloads, "http_client_fixture": True,
                    "transport_failures": {failed_url: error}, "statuses": statuses,
                }
                case.write_text(json.dumps(fixture))
                matrix.append((label, case, fixture, code, failed_url))
            batch, _, _ = fallback("transport-matrix", acquisition_matrix=[str(row[1]) for row in matrix])
            try:
                observed = json.loads(batch.stdout)
            except (ValueError, UnicodeDecodeError):
                observed = []
            check("the complete typed transport-error matrix finishes with one result per caller",
                  batch.returncode == 0 and isinstance(observed, list) and len(observed) == len(matrix),
                  batch.stderr.decode(errors="replace"))
            for index, (label, case, fixture, code, failed_url) in enumerate(matrix):
                row = observed[index] if isinstance(observed, list) and index < len(observed) else {}
                try:
                    result = json.loads(row.get("stdout", ""))
                except (ValueError, TypeError):
                    result = {}
                observed_requests = requests(fixture)
                check(label + " is terminal before Git, compilation or family replacement",
                      row.get("case_path") == str(case) and row.get("exit_code") == code and
                      result.get("exit_code") == code and result.get("status") == "error" and
                      "source_fallback" not in result and not calls(fixture) and
                      observed_requests and observed_requests[-1]["url"] == failed_url and
                      all(digest(release_prefix / name) == value for name, value in original.items()),
                      json.dumps(row))
            check("typed transport diagnostics never expose exception-carried URL credentials",
                  b"transport-secret" not in batch.stdout + batch.stderr,
                  batch.stderr.decode(errors="replace"))

            graphs, _, _ = fallback("deadline-exception-graphs", exception_graph_probe=True)
            try:
                graph_rows = json.loads(graphs.stdout)
            except (ValueError, UnicodeDecodeError):
                graph_rows = []
            expected_graphs = (
                ("owned-plain", 8, True), ("owned-connection", 8, True),
                ("owned-tls", 8, False), ("owned-auth", 8, False),
                ("owned-unknown", 8, False), ("owned-aggregate", 8, False),
                ("explicit-plain", 5, False), ("explicit-tls", 5, False),
            )
            check("deadline exception graph probe emits exactly its eight independent decisions",
                  graphs.returncode == 0 and isinstance(graph_rows, list) and len(graph_rows) == len(expected_graphs),
                  graphs.stderr.decode(errors="replace"))
            for index, (name, code, unavailable) in enumerate(expected_graphs):
                row = graph_rows[index] if isinstance(graph_rows, list) and index < len(graph_rows) else {}
                check(name + " preserves cancellation and unsafe-inner precedence",
                      row.get("name") == name and row.get("exit_code") == code and
                      row.get("unavailable") is unavailable and "transport-secret" not in json.dumps(row),
                      json.dumps(row))

            token = "dsr-transport-selected-account"
            private, _, private_fixture = fallback("private-tls", extra={"DSR_GH_TOKEN": token},
                expected_token=token, transport_failures={latest_url: "SecureConnectionError"})
            check("selected-account TLS refusal does not retry public discovery or source",
                  private.returncode == 8 and not calls(private_fixture) and
                  len(requests(private_fixture)) == 1 and
                  requests(private_fixture)[0]["authorization_sha256"] == hashlib.sha256(token.encode()).hexdigest(),
                  private.stderr.decode(errors="replace"))
            for label, errors, expected_ref, expected_commit in (
                ("dns", {latest_url: "NameResolutionError", public_latest: "NameResolutionError"}, "HEAD", second_commit),
                ("connection", {public_payload: "ConnectionError"}, "refs/tags/v1.2.3", first_commit),
                ("premature-body", {public_payload: "body-ResponseEnded"}, "refs/tags/v1.2.3", first_commit),
            ):
                outcome, result, fixture = fallback("transport-" + label, transport_failures=errors)
                check(label + " availability still builds the complete genuine Go family from its exact source",
                      outcome.returncode == 0 and source_selected(result, fixture, expected_ref, expected_commit),
                      outcome.stderr.decode(errors="replace"))
            return

        if options.fallback_baseline_project:
            prior, prior_runtime, prior_policy = generate("source-demo", "fallback-baseline-generate",
                checkout=options.fallback_baseline_project.resolve(), destination=root / "fallback-baseline-generated")
            for label, statuses in (("latest", {latest_url: 404}), ("payload", {public_payload: 404})):
                before, _, fixture = fallback("baseline-" + label, selected=prior_runtime,
                    params={"SourceIfStale": 0}, statuses=statuses)
                check("same signed-source caller proves baseline has no unavailable-" + label + " fallback",
                      prior.returncode == 0 and prior_policy == policy and before.returncode == 8 and
                      not calls(fixture) and not Path(fixture["parameters"]["Prefix"]).exists(),
                      before.stderr.decode(errors="replace"))
            coerced, coerced_result, _ = fallback("baseline-fractional-threshold", selected=prior_runtime,
                params={"SourceIfStale": 0.5})
            check("actual baseline silently rounds fractional consent and compiles a source family",
                  coerced.returncode == 0 and coerced_result.get("method") == "source" and
                  coerced_result.get("freshness", {}).get("threshold") == 0,
                  coerced.stderr.decode(errors="replace"))

        available, available_result, available_fixture = fallback("available")
        check("source fallback consent alone keeps an available fully signed release without freshness requests",
              available.returncode == 0 and release_installed(available_result, available_fixture) and
              not calls(available_fixture) and "freshness" not in available_result,
              available.stderr.decode(errors="replace"))
        for label, params, statuses, expected_ref, expected_commit in (
            ("known-release", {}, {public_payload: 404}, "refs/tags/v1.2.3", first_commit),
            ("explicit-numeric", {"Version": "1.2.3"}, {public_payload: 410}, "refs/tags/v1.2.3", first_commit),
            ("missing-latest", {"SourceIfStale": 0}, {latest_url: 404}, "HEAD", second_commit),
            ("public-outage", {}, {latest_url: 503, public_latest: 503}, "HEAD", second_commit),
        ):
            outcome, result, fixture = fallback(label, params=params, statuses=statuses)
            check(label + " installs the genuine complete family from the correct source selection",
                  outcome.returncode == 0 and source_selected(result, fixture, expected_ref, expected_commit) and
                  result["source_fallback"].get("release_version") == (None if expected_ref == "HEAD" else "v1.2.3"),
                  outcome.stderr.decode(errors="replace"))
        redirected = dict(downloads)
        redirected[public_tag] = metadata("public-tag-head", {})
        resolved, resolved_result, resolved_fixture = fallback("public-redirect-tag", payload=redirected,
            statuses={latest_url: 429, public_payload: 404}, redirects={public_latest: public_tag})
        check("public redirect recovery binds unavailable payload fallback to its exact resolved release tag",
              resolved.returncode == 0 and source_selected(resolved_result, resolved_fixture, "refs/tags/v1.2.3", first_commit) and
              any(row["url"] == public_tag and row["method"] == "HEAD" for row in requests(resolved_fixture)),
              resolved.stderr.decode(errors="replace"))

        token = "dsr-fallback-selected-credential"
        credentials = {"DSR_GH_TOKEN": token, "GITHUB_TOKEN": "other-fixture-account", "GH_TOKEN": "third-fixture-account"}
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        authorization = "Authorization: Basic " + base64.b64encode(("x-access-token:" + token).encode()).decode()
        authorization_hash = hashlib.sha256(authorization.encode()).hexdigest()
        for label, params, failed_url, status, expected_ref, expected_commit in (
            ("private-discovery", {}, latest_url, 503, "HEAD", second_commit),
            ("private-exact", {"Version": "v1.2.3"}, exact_url, 408, "refs/tags/v1.2.3", first_commit),
            ("private-inventory", {}, inventory_url, 429, "refs/tags/v1.2.3", first_commit),
            ("private-payload", {}, private_payload, 503, "refs/tags/v1.2.3", first_commit),
        ):
            outcome, result, fixture = fallback(label, params=params, statuses={failed_url: status},
                extra=credentials, expected_token=token)
            fetches = [row for row in calls(fixture) if "fetch" in row["arguments"]]
            observed = requests(fixture)
            check(label + " retains the selected account through metadata outage and real source fetch",
                  outcome.returncode == 0 and source_selected(result, fixture, expected_ref, expected_commit) and
                  all(row["url"].startswith(api + "/") and row["authorization_sha256"] == token_hash for row in observed) and
                  len(fetches) == 1 and fetches[0].get("git_authorization_sha256") == authorization_hash and
                  token not in (outcome.stdout + outcome.stderr).decode(errors="replace") and
                  token not in Path(fixture["commands"]).read_text(), outcome.stderr.decode(errors="replace"))
        absent = dict(downloads)
        absent[inventory_url] = metadata("fallback-absent-primary", [
            row for row in json.loads(Path(downloads[inventory_url]).read_text()) if row["name"] != asset])
        omitted, omitted_result, omitted_fixture = fallback("private-absent-primary", payload=absent,
            extra=credentials, expected_token=token)
        check("complete authenticated inventory proves primary absence without an anonymous request",
              omitted.returncode == 0 and source_selected(omitted_result, omitted_fixture, "refs/tags/v1.2.3", first_commit) and
              all(row["url"].startswith(api + "/") and row["authorization_sha256"] == token_hash for row in requests(omitted_fixture)) and
              private_payload not in [row["url"] for row in requests(omitted_fixture)],
              omitted.stderr.decode(errors="replace"))

        for label, failed_url, status, authenticated in (
            ("public-api-denied", latest_url, 401, False),
            ("public-api-forbidden", latest_url, 403, False),
            ("public-payload-denied", public_payload, 401, False),
            ("public-payload-forbidden", public_payload, 403, False),
            ("private-api-denied", latest_url, 401, True),
            ("private-api-forbidden", latest_url, 403, True),
            ("private-api-hidden", latest_url, 404, True),
            ("private-payload-denied", private_payload, 401, True),
            ("private-payload-forbidden", private_payload, 403, True),
            ("private-payload-hidden", private_payload, 404, True),
        ):
            extra = {"extra": credentials, "expected_token": token} if authenticated else {}
            refused, _, fixture = fallback(label, statuses={failed_url: status}, **extra)
            check(label + " cannot authorize source execution or a replacement identity",
                  refused.returncode == 8 and not calls(fixture) and not Path(fixture["parameters"]["Prefix"]).exists() and
                  (not authenticated or all(row["authorization_sha256"] == token_hash for row in requests(fixture))),
                  refused.stderr.decode(errors="replace"))

        for label, changed in (
            ("no-consent", {"AllowSourceBuild": False, "SourceTimeout": 3600}),
            ("fractional-threshold", {"SourceIfStale": 0.5}),
            ("empty-threshold", {"SourceIfStale": ""}),
            ("empty-recovery-threshold", {"SourceIfStale": "", "Recover": True,
                "AllowSourceBuild": False, "SourceTimeout": 3600, "CacheDir": ""}),
            ("leading-zero", {"SourceIfStale": "01"}),
            ("offline", {"Offline": True, "Version": "v1.2.3"}),
        ):
            refused, _, fixture = fallback(label, params=changed, statuses={latest_url: 404})
            check(label + " cannot start an unavailable-release source build",
                  refused.returncode == (8 if label == "no-consent" else 4) and not calls(fixture) and
                  not Path(fixture["parameters"]["Prefix"]).exists() and (label == "no-consent" or no_http(fixture)),
                  refused.stderr.decode(errors="replace"))

        for label, failed_url in (("discovery-cancel", latest_url), ("payload-cancel", public_payload)):
            cancelled, _, fixture = fallback(label, transport_failures={failed_url: "cancel"})
            check(label + " stops explicitly without compiling or installing anything",
                  cancelled.returncode == 5 and not calls(fixture) and not Path(fixture["parameters"]["Prefix"]).exists(),
                  cancelled.stderr.decode(errors="replace"))
        for label, failed_url in (
            ("checksum-unavailable", public_payload.rsplit("/", 1)[0] + "/SHA256SUMS"),
            ("signature-unavailable", public_payload + ".minisig"),
        ):
            refused, _, fixture = fallback(label, statuses={failed_url: 503})
            check(label + " is a proof failure and never a source fallback",
                  refused.returncode == 8 and not calls(fixture) and not Path(fixture["parameters"]["Prefix"]).exists(),
                  refused.stderr.decode(errors="replace"))
        malformed = dict(downloads)
        malformed[latest_url] = metadata("malformed-latest", {"id": 4242, "tag_name": [], "draft": False})
        refused, _, fixture = fallback("malformed-latest", payload=malformed)
        check("malformed successful release metadata cannot be called an unavailable release",
              refused.returncode == 7 and not calls(fixture), refused.stderr.decode(errors="replace"))
        for kind in ("bad-checksum", "bad-signature", "unsafe-archive", "wrong-machine"):
            selected = dict(downloads)
            selected.update(release("fallback-" + kind, kind))
            refused, _, fixture = fallback(kind, payload=selected, params={"Prefix": str(release_prefix)})
            check(kind + " remains terminal under fallback consent and preserves the existing family",
                  refused.returncode == 7 and not calls(fixture) and
                  all(digest(release_prefix / name) == value for name, value in original.items()),
                  refused.stderr.decode(errors="replace"))

        warm, warm_result, warm_fixture = fallback("cache-warm", params={"Version": "v1.2.3"})
        reused, reused_result, reused_fixture = fallback("cache-reuse", params={"Version": "v1.2.3",
            "CacheDir": warm_fixture["parameters"]["CacheDir"]}, extra=credentials, statuses={exact_url: 401})
        check("verified exact cache still avoids failed acquisition and every source probe",
              warm.returncode == 0 and reused.returncode == 0 and release_installed(reused_result, reused_fixture) and
              no_http(reused_fixture) and not calls(reused_fixture), reused.stderr.decode(errors="replace"))
        cached_payload = Path(warm_result["cache"]["path"]) / asset
        with cached_payload.open("ab") as changed:
            changed.write(b"changed cached payload")
        corrupt, _, corrupt_fixture = fallback("cache-corrupt", params={"Version": "v1.2.3",
            "CacheDir": warm_fixture["parameters"]["CacheDir"]})
        check("corrupt cached proof cannot be replaced by source execution",
              corrupt.returncode == 7 and no_http(corrupt_fixture) and not calls(corrupt_fixture),
              corrupt.stderr.decode(errors="replace"))

        missing, missing_result, missing_fixture = fallback("missing-selected-tag", params={"Version": "v9.9.9",
            "Prefix": str(release_prefix)})
        missing_fetches = [row["arguments"] for row in calls(missing_fixture) if "fetch" in row["arguments"]]
        check("a missing exact source tag fails once without retrying moving HEAD",
              missing.returncode == 8 and len(missing_fetches) == 1 and missing_fetches[0][-1] == "refs/tags/v9.9.9" and
              missing_result.get("source_fallback", {}).get("requested_ref") == "refs/tags/v9.9.9" and
              all(digest(release_prefix / name) == value for name, value in original.items()),
              missing.stderr.decode(errors="replace"))
        rollback, rollback_result, _ = fallback("rollback", statuses={latest_url: 404}, move_fault=True,
            params={"Prefix": str(release_prefix)})
        check("fallback family replacement failure restores old bytes and retains diagnostics",
              rollback.returncode == 7 and all(digest(release_prefix / name) == value for name, value in original.items()) and
              Path(rollback_result.get("source_diagnostics", "/nonexistent")).is_dir(),
              rollback.stderr.decode(errors="replace"))
        (upstream / "project/cmd/helper/main.go").write_text("package main\nfunc main() { invalid Go source }\n")
        required(["git", "-C", upstream, "add", "."], "fallback-broken-add")
        required(["git", "-C", upstream, "commit", "--quiet", "-m", "Real later family compiler failure"], "fallback-broken-commit")
        broken, broken_result, broken_fixture = fallback("compiler-failure", statuses={latest_url: 404},
            params={"Prefix": str(release_prefix)})
        check("real later source compiler failure never installs a partial family or switches back to release",
              broken.returncode == 6 and sum(row["arguments"][0] == "build" for row in calls(broken_fixture)) == 2 and
              all(digest(release_prefix / name) == value for name, value in original.items()) and
              Path(broken_result.get("source_diagnostics", "/nonexistent")).is_dir(),
              broken.stderr.decode(errors="replace"))
        return

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
        ("transport-failure", None, None, {"transport_failures": {head_url: "network"}}),
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
        ("missing-consent", {"AllowSourceBuild": False}),
        ("exact-version", {"Version": "v1.2.3"}), ("offline", {"Offline": True}),
        ("explicit-source", {"FromSource": True}), ("moving-selector", {"SourceRef": "HEAD"}),
        ("negative-threshold", {"SourceIfStale": -1}), ("large-threshold", {"SourceIfStale": 1000000}),
        ("fractional-threshold", {"SourceIfStale": 1.5}), ("leading-zero-threshold", {"SourceIfStale": "01"}),
        ("empty-threshold", {"SourceIfStale": ""}), ("exponent-threshold", {"SourceIfStale": "1e0"}),
        ("invalid-timeout", {"SourceTimeout": 0}), ("recovery", {"Recover": True}),
    ):
        refused, _, fixture = run("invalid-" + label, params=values)
        check(label + " is refused before HTTP, Git, compilation or installation", refused.returncode == 4 and
              no_http(fixture) and not calls(fixture) and not Path(fixture["parameters"]["Prefix"]).exists(),
              refused.stderr.decode(errors="replace"))
    cancelled, _, cancelled_fixture = run("cancelled", transport_failures={head_url: "cancel"},
        params={"Prefix": str(installed_prefix)})
    check("explicit freshness cancellation stops instead of installing a verified old release",
          cancelled.returncode == 5 and not calls(cancelled_fixture) and
          all(digest(installed_prefix / name) == value for name, value in original.items()),
          cancelled.stderr.decode(errors="replace"))
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


if options.freshness_only or options.fallback_only or options.acquisition_errors_only or options.freshness_deadline_only:
    test_release_freshness()
    print(f"Windows release source-routing checks: {passed} passed, {failed} failed", flush=True)
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


def test_source_symlinks():
    def repository(label, contents, links=(), gitlinks=()):
        directory = root / (label + "-upstream")
        directory.mkdir()
        required(["git", "init", "--quiet", "--initial-branch=main", directory], label + "-init")
        required(["git", "-C", directory, "config", "user.email", "fixture@example.invalid"], label + "-email")
        required(["git", "-C", directory, "config", "user.name", "DSR Tracked Link Fixture"], label + "-name")
        for name, value in contents.items():
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
        required(["git", "-C", directory, "add", "."], label + "-add")
        # Actual Git symlink entries without requiring fixture OS privileges.
        for number, (path, target) in enumerate(links):
            literal = root / (label + "-literal-" + str(number))
            literal.write_bytes(target if isinstance(target, bytes) else target.encode())
            blob = required(["git", "-C", directory, "hash-object", "-w", "--no-filters", literal],
                            label + "-blob-" + str(number))
            required(["git", "-C", directory, "update-index", "--add", "--cacheinfo", f"120000,{blob},{path}"],
                     label + "-link-" + str(number))
        for number, (path, pin) in enumerate(gitlinks):
            required(["git", "-C", directory, "update-index", "--add", "--cacheinfo", f"160000,{pin},{path}"],
                     label + "-gitlink-" + str(number))
        required(["git", "-C", directory, "commit", "--quiet", "-m", label], label + "-commit")
        pin = required(["git", "-C", directory, "rev-parse", "HEAD"], label + "-pin")
        return directory, pin

    ordinary, ordinary_result, ordinary_fixture = invoke("links-ordinary-source")
    check("ordinary regular-file source still builds both configured genuine PE outputs",
          ordinary.returncode == 0 and len(ordinary_result.get("binaries", [])) == 2 and
          all(machine(Path(ordinary_fixture["parameters"]["Prefix"]) / row["name"]) == 0x8664
              for row in ordinary_result.get("binaries", [])),
          ordinary.stderr.decode(errors="replace"))

    main_source = 'package main\nimport ("fmt"; _ "embed")\n//go:embed message.txt\nvar message string\nfunc main() { fmt.Print(message) }\n'
    child_files = {
        "go.mod": "module example.invalid/source-links\n\ngo 1.22\n",
        "apps/primary/main.go": main_source,
        "cmd/helper/main.go": main_source,
        "shared/message.txt": "pinned-linked-source\n",
        ".gitattributes": "shared/message.txt text eol=crlf\n",
    }
    child_links = [("apps/primary/message.txt", "../../shared/message.txt"),
                   ("cmd/helper/message.txt", "../../shared/message.txt")]
    child, child_pin = repository("links-child", child_files, child_links)
    root_modules = '[submodule "tool"]\n path = vendor/tool\n url = ../links-child.git\n'
    root_files = {".gitmodules": root_modules, "docs/AGENTS.md": "Pinned vendor documentation.\n"}
    source, source_pin = repository("links-root", root_files, [("docs/CLAUDE.md", "AGENTS.md")],
                                    [("vendor/tool", child_pin)])
    repository_map = {"fixture/source-links": source.as_uri(), "fixture/links-child": child.as_uri()}
    config("source-links", local_path=str(source), source_subdir="vendor/tool")
    generated, selected_runtime, selected_policy = generate("source-links", "links-generate")
    check("public generator creates the source policy for the linked pinned child",
          generated.returncode == 0, generated.stderr.decode(errors="replace"))
    if generated.returncode:
        return

    def run(label, *, checkout_runtime=selected_runtime, source_ref=source_pin, repositories=None, parameters=None, **changes):
        params = {"SourceRef": source_ref}
        params.update(parameters or {})
        return invoke(label, selected_runtime=checkout_runtime, parameters=params,
                      extra={"GOPROXY": "off", "GOSUMDB": "off", "CGO_ENABLED": "0"},
                      repositories=repositories or repository_map, **changes)

    if options.symlink_baseline_project:
        old_generated, old_runtime, old_policy = generate("source-links", "links-baseline-generate",
            checkout=options.symlink_baseline_project.resolve(), destination=root / "links-baseline-generated")
        old, _, old_fixture = run("links-baseline", checkout_runtime=old_runtime)
        check("same genuine linked source graph reproduces the original installer refusal",
              old_generated.returncode == 0 and old_policy == selected_policy and old.returncode == 4 and
              not any(row["arguments"][0] == "build" for row in calls(old_fixture)),
              old.stderr.decode(errors="replace"))

    built, result, fixture = run("links-positive")
    check("relative tracked links at root and inside a pinned child compile and install a complete family",
          built.returncode == 0 and result.get("source", {}).get("source_commit") == source_pin and
          {row["name"] for row in result.get("binaries", [])} == {"app.exe", "helper.exe"},
          built.stderr.decode(errors="replace"))
    if built.returncode:
        return
    prefix = Path(fixture["parameters"]["Prefix"])
    original = {name: digest(prefix / name) for name in ("app.exe", "helper.exe")}
    copied = b"pinned-linked-source\r\n"
    check("both genuine PE binaries embed the authenticated Git-converted referent bytes",
          all(machine(prefix / name) == 0x8664 and copied in (prefix / name).read_bytes() for name in original))
    expected_links = {}
    for repository_path, pin, path, target, referent, materialized in [
        (source, source_pin, "docs/CLAUDE.md", "AGENTS.md", "docs/AGENTS.md", b"Pinned vendor documentation.\n"),
        (child, child_pin, "apps/primary/message.txt", "../../shared/message.txt", "shared/message.txt", copied),
        (child, child_pin, "cmd/helper/message.txt", "../../shared/message.txt", "shared/message.txt", copied),
    ]:
        prefix_path = "" if repository_path == source else "vendor/tool/"
        blob = required(["git", "-C", repository_path, "rev-parse", pin + ":" + path],
                        "links-expected-" + path.replace("/", "-"))
        referent_blob = required(["git", "-C", repository_path, "rev-parse", pin + ":" + referent],
                                 "links-referent-" + path.replace("/", "-"))
        expected_links[prefix_path + path] = {
            "path": prefix_path + path, "git_blob": blob, "link_target": target,
            "referent_path": prefix_path + referent, "referent_git_blob": referent_blob,
            "sha256": hashlib.sha256(materialized).hexdigest(), "size_bytes": len(materialized),
        }
    actual_links = result["source"].get("materialized_symlinks", [])
    check("receipt binds every original link blob and literal to the pinned referent and actual copied bytes",
          len(actual_links) == 3 and {row["path"]: row for row in actual_links} == expected_links)
    check("durable receipt retains exact child pin and link evidence without private filesystem paths",
          result["source"].get("submodules") == [{"path": "vendor/tool", "repository": "fixture/links-child",
                                                  "source_commit": child_pin}] and
          json.loads(Path(result["source_receipt"]["path"]).read_text()) == result["source"] and
          str(root) not in json.dumps(result["source"]))
    checkout_calls = [row for row in calls(fixture) if "checkout" in row["arguments"]]
    check("both real checkouts disable OS symlink creation and the source path performs no HTTP",
          len(checkout_calls) == 2 and all("core.symlinks=false" in row["arguments"] for row in checkout_calls) and no_http(fixture))

    for label, injection in (
        ("links-materialized-drift", {"mutate_source": True, "mutate_source_member": "apps/primary/message.txt"}),
        ("links-referent-drift", {"mutate_source": True, "mutate_source_member": "shared/message.txt"}),
        ("links-literal-drift", {"mutate_link_evidence": True}),
        ("links-index-drift", {"mutate_link_index": True}),
    ):
        refused, _, refused_fixture = run(label, parameters={"Prefix": str(prefix)}, **injection)
        check(label + " after genuine compilation refuses and preserves every installed executable",
              refused.returncode == 7 and any(row["arguments"][0] == "build" for row in calls(refused_fixture)) and
              all(digest(prefix / name) == value for name, value in original.items()),
              refused.stderr.decode(errors="replace"))
    rollback, _, _ = run("links-rollback", parameters={"Prefix": str(prefix)}, move_fault=True)
    check("linked source families retain ordinary second-move rollback",
          rollback.returncode == 7 and all(digest(prefix / name) == value for name, value in original.items()),
          rollback.stderr.decode(errors="replace"))
    for label, member in (("links-checkout-literal", "docs/CLAUDE.md"), ("links-checkout-referent", "docs/AGENTS.md")):
        refused, _, refused_fixture = run(label, parameters={"Prefix": str(prefix)}, mutate_checkout_member=member)
        check(label + " cannot supply unauthenticated bytes to the compiler",
              refused.returncode == 7 and not any(row["arguments"][0] == "build" for row in calls(refused_fixture)) and
              all(digest(prefix / name) == value for name, value in original.items()),
              refused.stderr.decode(errors="replace"))

    unsafe = [
        ("outside", [("docs/CLAUDE.md", "../../outside")]),
        ("absolute", [("docs/CLAUDE.md", "/outside")]),
        ("drive", [("docs/CLAUDE.md", "C:/outside")]),
        ("admin", [("docs/CLAUDE.md", "../.git/config")]),
        ("missing", [("docs/CLAUDE.md", "MISSING.md")]),
        ("directory", [("docs/CLAUDE.md", "../docs")]),
        ("case", [("docs/CLAUDE.md", "agents.md")]),
        ("transient-file", [("docs/CLAUDE.md", "AGENTS.md/../AGENTS.md")]),
        ("cross-submodule", [("docs/CLAUDE.md", "../vendor/tool/shared/message.txt")]),
        ("empty", [("docs/CLAUDE.md", "")]),
        ("newline", [("docs/CLAUDE.md", "AGENTS.md\n")]),
        ("invalid-utf8", [("docs/CLAUDE.md", b"\xff")]),
        ("chain", [("docs/CLAUDE.md", "SECOND.md"), ("docs/SECOND.md", "AGENTS.md")]),
        ("cycle", [("docs/CLAUDE.md", "SECOND.md"), ("docs/SECOND.md", "CLAUDE.md")]),
    ]
    for label, links in unsafe:
        invalid, pin = repository("links-" + label, root_files, links, [("vendor/tool", child_pin)])
        mapping = dict(repository_map, **{"fixture/source-links": invalid.as_uri()})
        refused, _, refused_fixture = run("links-" + label, repositories=mapping, source_ref=pin,
                                         parameters={"Prefix": str(prefix)})
        check(label + " link is refused before compilation and preserves the installed family",
              refused.returncode == 4 and not any(row["arguments"][0] == "build" for row in calls(refused_fixture)) and
              all(digest(prefix / name) == value for name, value in original.items()),
              refused.stderr.decode(errors="replace"))

    escaped_child, escaped_pin = repository("links-child-escape", child_files,
        [("apps/primary/message.txt", "../../../docs/AGENTS.md"), child_links[1]])
    escaped_root, escaped_root_pin = repository("links-child-escape-root", root_files, (),
                                               [("vendor/tool", escaped_pin)])
    refused, _, refused_fixture = run("links-child-escape",
        repositories={"fixture/source-links": escaped_root.as_uri(), "fixture/links-child": escaped_child.as_uri()},
        source_ref=escaped_root_pin, parameters={"Prefix": str(prefix)})
    check("a child link cannot escape to an otherwise tracked regular file in its parent repository",
          refused.returncode == 4 and not any(row["arguments"][0] == "build" for row in calls(refused_fixture)) and
          all(digest(prefix / name) == value for name, value in original.items()),
          refused.stderr.decode(errors="replace"))

    long_child, long_child_pin = repository("links-long-child", {"target": "bounded\n"}, [("l" * 240, "target")])
    long_path = "/".join(["p" * 200] * 4)
    long_root, long_pin = repository("links-long-root",
        {".gitmodules": root_modules.replace("vendor/tool", long_path)}, (), [(long_path, long_child_pin)])
    refused, _, refused_fixture = run("links-flattened-bound",
        repositories={"fixture/source-links": long_root.as_uri(), "fixture/links-child": long_child.as_uri()}, source_ref=long_pin)
    check("nested materialized links retain the existing flattened path-length bound",
          refused.returncode == 4 and b"Nested tracked source link exceeds the source bounds" in refused.stderr and
          not any(row["arguments"][0] == "build" for row in calls(refused_fixture)),
          refused.stderr.decode(errors="replace"))


if options.symlinks_only:
    test_source_symlinks()
    print(f"Windows tracked source-link tests: {passed} passed, {failed} failed", flush=True)
    print("Real Git and Go PE compilation through portable PowerShell; native Windows and live GitHub remain unqualified.", flush=True)
    raise SystemExit(1 if failed else 0)


def test_source_submodules():
    def repository(label, contents, gitlinks=()):
        directory = root / (label + "-upstream")
        directory.mkdir()
        required(["git", "init", "--quiet", "--initial-branch=main", directory], label + "-init")
        required(["git", "-C", directory, "config", "user.email", "fixture@example.invalid"], label + "-email")
        required(["git", "-C", directory, "config", "user.name", "DSR Submodule Fixture"], label + "-name")
        for name, value in contents.items():
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
        required(["git", "-C", directory, "add", "."], label + "-add")
        for number, (path, pin) in enumerate(gitlinks):
            required(["git", "-C", directory, "update-index", "--add", "--cacheinfo", f"160000,{pin},{path}"],
                     label + "-link-" + str(number))
        required(["git", "-C", directory, "commit", "--quiet", "-m", label], label + "-commit")
        pin = required(["git", "-C", directory, "rev-parse", "HEAD"], label + "-pin")
        return directory, pin

    leaf, leaf_pin = repository("submodule-leaf", {
        "go.mod": "module example.invalid/submodule-leaf\n\ngo 1.22\n",
        "value.go": 'package leaf\nfunc Value() string { return "pinned-recursive-submodule" }\n',
    })
    main_source = 'package main\nimport ("fmt"; leaf "example.invalid/submodule-leaf")\nfunc main() { fmt.Println(leaf.Value()) }\n'
    child, child_pin = repository("submodule-child", {
        "go.mod": "module example.invalid/submodule-app\n\ngo 1.22\nrequire example.invalid/submodule-leaf v0.0.0\nreplace example.invalid/submodule-leaf => ./nested/lib\n",
        "apps/primary/main.go": main_source,
        "cmd/helper/main.go": main_source.replace("leaf.Value()", '"helper-" + leaf.Value()'),
        "cmd/arm-helper/main.go": main_source.replace("leaf.Value()", '"arm-helper-" + leaf.Value()'),
        ".gitmodules": '[submodule "nested-library"]\n path = nested/lib\n url = ../../other/leaf.git\n branch = main\n ignore = all\n update = none\n',
    }, [("nested/lib", leaf_pin)])
    root_modules = '[submodule "tool"]\n path = vendor/tool\n url = ../child.git\n branch = main\n ignore = all\n update = none\n'
    source, source_pin = repository("submodule-root", {"README": "Pinned recursive source family\n", ".gitmodules": root_modules},
                                    [("vendor/tool", child_pin)])
    required(["git", "-C", source, "tag", "-a", "v1.2.3", "-m", "Pinned recursive family"], "submodule-root-tag")
    for label, directory, path, text in (("leaf", leaf, "value.go", 'package leaf\nfunc Value() string { return "unselected-newer-submodule" }\n'),
                                       ("child", child, "apps/primary/main.go", main_source.replace("leaf.Value()", '"unselected-newer-child"'))):
        (directory / path).write_text(text)
        required(["git", "-C", directory, "add", path], "submodule-advance-" + label + "-add")
        required(["git", "-C", directory, "commit", "--quiet", "-m", "Advance unselected branch"], "submodule-advance-" + label + "-commit")
    repository_map = {"fixture/submodule-source": source.as_uri(), "fixture/child": child.as_uri(), "other/leaf": leaf.as_uri()}
    config("submodule-source", local_path=str(source), source_subdir="vendor/tool")
    generated, selected_runtime, selected_policy = generate("submodule-source", "submodule-generate")
    check("public generator admits a Windows source root inside a pinned submodule", generated.returncode == 0,
          generated.stderr.decode(errors="replace"))
    if generated.returncode:
        return

    def run(label, *, checkout_runtime=selected_runtime, source_ref="refs/tags/v1.2.3", repositories=None, parameters=None, **changes):
        params = {"SourceRef": source_ref}
        params.update(parameters or {})
        extra = {"GOPROXY": "off", "GOSUMDB": "off", "CGO_ENABLED": "0"}
        extra.update(changes.pop("extra", {}))
        return invoke(label, selected_runtime=checkout_runtime, parameters=params, extra=extra,
                      repositories=repositories or repository_map, **changes)

    if options.submodule_baseline_project:
        old_generated, old_runtime, old_policy = generate("submodule-source", "submodule-baseline-generate",
            checkout=options.submodule_baseline_project.resolve(), destination=root / "submodule-baseline-generated")
        old, _, old_fixture = run("submodule-baseline", checkout_runtime=old_runtime)
        check("same real recursive Git fixture reproduces the original Windows submodule refusal",
              old_generated.returncode == 0 and old_policy == selected_policy and old.returncode == 4 and
              not any(row["arguments"][0] == "build" for row in calls(old_fixture)) and
              not Path(old_fixture["parameters"]["Prefix"]).exists(), old.stderr.decode(errors="replace"))

    token = "fixture-submodule-account"
    built, result, fixture = run("submodule-family", extra={"DSR_GH_TOKEN": token})
    check("recursive exact gitlink pins compile and install a complete genuine x64 PE family",
          built.returncode == 0 and result.get("source", {}).get("source_commit") == source_pin,
          built.stderr.decode(errors="replace"))
    if built.returncode:
        return
    prefix = Path(fixture["parameters"]["Prefix"])
    original = {name: digest(prefix / name) for name in ("app.exe", "helper.exe")}
    check("newer child branches and update/ignore settings cannot replace either committed pin",
          all(machine(prefix / name) == 0x8664 and b"pinned-recursive-submodule" in (prefix / name).read_bytes() and
              b"unselected-newer-submodule" not in (prefix / name).read_bytes() and
              b"unselected-newer-child" not in (prefix / name).read_bytes() for name in original))
    expected_submodules = [
        {"path": "vendor/tool", "repository": "fixture/child", "source_commit": child_pin},
        {"path": "vendor/tool/nested/lib", "repository": "other/leaf", "source_commit": leaf_pin},
    ]
    check("durable source receipt records each recursive repository and pin without temporary paths",
          result["source"].get("submodules") == expected_submodules and
          str(root) not in json.dumps(result["source"]) and
          json.loads(Path(result["source_receipt"]["path"]).read_text()) == result["source"] and
          all(row["sha256"] == original[row["name"]] for row in result["binaries"]))
    fetches = [row for row in calls(fixture) if "fetch" in row["arguments"]]
    expected_authorization = hashlib.sha256(b"Authorization: Basic " + base64.b64encode(("x-access-token:" + token).encode())).hexdigest()
    check("every exact-pin fetch uses the same selected account scoped to that child repository",
          len(fetches) == 3 and [row["arguments"][-1] for row in fetches] == ["refs/tags/v1.2.3", child_pin, leaf_pin] and
          all(row["git_authorization_sha256"] == expected_authorization and
              "--config-env=http.https://github.com/" + repository + ".git.extraHeader=DSR_INSTALLER_GIT_AUTHORIZATION" in row["arguments"]
              for row, repository in zip(fetches, ["fixture/submodule-source", "fixture/child", "other/leaf"])) and
          token not in Path(fixture["commands"]).read_text() and token not in (built.stdout + built.stderr).decode(errors="replace"))
    check("submodule source installation uses the existing committed Go local-module selection without HTTP",
          no_http(fixture) and result["source"].get("go_module", {}).get("local_replacements", [])[0].get("path") ==
          "vendor/tool/nested/lib")

    arm, arm_result, arm_fixture = run("submodule-arm64", platform="windows/arm64")
    check("the same recursive source graph builds the configured ARM64 executable family",
          arm.returncode == 0 and {row["name"] for row in arm_result.get("binaries", [])} == {"app.exe", "arm-helper.exe"} and
          all(machine(Path(arm_fixture["parameters"]["Prefix"]) / row["name"]) == 0xAA64 for row in arm_result.get("binaries", [])),
          arm.stderr.decode(errors="replace"))

    for label, injection in (("submodule-byte-drift", {"mutate_source": True, "mutate_source_member": "nested/lib/value.go"}),
                             ("submodule-head-drift", {"mutate_submodule_head": True}),
                             ("submodule-index-drift", {"mutate_submodule_index": True})):
        refused, _, _ = run(label, parameters={"Prefix": str(prefix)}, **injection)
        check(label + " after genuine compilation preserves every previous executable",
              refused.returncode == 7 and all(digest(prefix / name) == value for name, value in original.items()),
              refused.stderr.decode(errors="replace"))
    rollback, _, _ = run("submodule-rollback", parameters={"Prefix": str(prefix)}, move_fault=True)
    check("recursive source families retain ordinary second-move rollback", rollback.returncode == 7 and
          all(digest(prefix / name) == value for name, value in original.items()), rollback.stderr.decode(errors="replace"))

    invalid_cases = {
        "missing-declarations": {"README": "Missing .gitmodules\n"},
        "unknown-host": {".gitmodules": root_modules.replace("../child.git", "https://example.invalid/child.git")},
        "credential-url": {".gitmodules": root_modules.replace("../child.git", "https://secret@github.com/fixture/child.git")},
        "escape-path": {".gitmodules": root_modules.replace("vendor/tool", "../outside")},
        "duplicate-url": {".gitmodules": root_modules + " url = ../child.git\n"},
        "unmatched-declaration": {".gitmodules": root_modules.replace("vendor/tool", "vendor/other")},
        "case-declaration": {".gitmodules": root_modules.replace("vendor/tool", "vendor/Tool")},
        "malformed-declarations": {".gitmodules": '[submodule "tool"\n path = vendor/tool\n'},
    }
    for label, contents in invalid_cases.items():
        invalid, invalid_pin = repository("submodule-" + label, contents, [("vendor/tool", child_pin)])
        mapping = dict(repository_map, **{"fixture/submodule-source": invalid.as_uri()})
        refused, _, refused_fixture = run("submodule-" + label, repositories=mapping, source_ref=invalid_pin,
                                         parameters={"Prefix": str(prefix)})
        check(label + " is refused before any child fetch or compiler and preserves the old family",
              refused.returncode == 4 and len([row for row in calls(refused_fixture) if "fetch" in row["arguments"]]) == 1 and
              not any(row["arguments"][0] == "build" for row in calls(refused_fixture)) and
              all(digest(prefix / name) == value for name, value in original.items()), refused.stderr.decode(errors="replace"))

    collision, collision_pin = repository("submodule-case-collision", {".gitmodules": root_modules},
                                          [("vendor/tool", child_pin), ("vendor/Tool", child_pin)])
    collided, _, collided_fixture = run("submodule-case-collision",
        repositories=dict(repository_map, **{"fixture/submodule-source": collision.as_uri()}), source_ref=collision_pin)
    check("case-colliding gitlinks are refused before checkout or compiler execution",
          collided.returncode == 4 and not any("checkout" in row["arguments"] for row in calls(collided_fixture)))

    missing, missing_pin = repository("submodule-missing-pin", {".gitmodules": root_modules}, [("vendor/tool", "1" * 40)])
    missing_result, _, missing_fixture = run("submodule-missing-pin",
        repositories=dict(repository_map, **{"fixture/submodule-source": missing.as_uri()}), source_ref=missing_pin,
        parameters={"Prefix": str(prefix)})
    check("an unavailable gitlink never retries a branch or compiles a partial source graph",
          missing_result.returncode == 8 and [row["arguments"][-1] for row in calls(missing_fixture) if "fetch" in row["arguments"]] ==
          [missing_pin, "1" * 40] and not any(row["arguments"][0] == "build" for row in calls(missing_fixture)) and
          all(digest(prefix / name) == value for name, value in original.items()))

    limit_paths = ["child-" + str(index) for index in range(256)]
    limit_modules = "".join(f'[submodule "{path}"]\n path = {path}\n url = ../child.git\n' for path in limit_paths)
    limit_root, limit_pin = repository("submodule-count-bound", {".gitmodules": limit_modules},
                                      [(path, child_pin) for path in limit_paths])
    limit, _, limit_fixture = run("submodule-count-bound",
        repositories=dict(repository_map, **{"fixture/submodule-source": limit_root.as_uri()}), source_ref=limit_pin)
    check("the 256-repository graph bound refuses excessive children before fetching any",
          limit.returncode == 4 and len([row for row in calls(limit_fixture) if "fetch" in row["arguments"]]) == 1 and
          not any(row["arguments"][0] == "build" for row in calls(limit_fixture)))
    timeout, _, timeout_fixture = run("submodule-complete-deadline", acquisition_pause_ms=1200,
        parameters={"SourceTimeout": 2, "Prefix": str(prefix)})
    check("one deadline covers recursive acquisition instead of restarting for every repository",
          timeout.returncode == 5 and not any(row["arguments"][0] == "build" for row in calls(timeout_fixture)) and
          all(digest(prefix / name) == value for name, value in original.items()), timeout.stderr.decode(errors="replace"))


if options.submodules_only:
    test_source_submodules()
    print(f"Windows recursive source submodule tests: {passed} passed, {failed} failed", flush=True)
    print("Real Git and Go PE compilation through portable PowerShell; native Windows and live GitHub remain unqualified.", flush=True)
    raise SystemExit(1 if failed else 0)


def test_go_module_replacements():
    module_upstream = root / "module-upstream"
    module_upstream.mkdir()
    required(["git", "init", "--quiet", "--initial-branch=main", module_upstream], "module-git-init")
    required(["git", "-C", module_upstream, "config", "user.email", "fixture@example.invalid"], "module-git-email")
    required(["git", "-C", module_upstream, "config", "user.name", "DSR Go Module Fixture"], "module-git-name")
    module = "module example.invalid/module-app\n\ngo 1.22\nrequire example.invalid/module-shared v0.0.0\n"
    dependency = "module example.invalid/module-shared\n\ngo 1.22\n"
    main = 'package main\nimport ("fmt"; "example.invalid/module-shared")\nfunc main() { fmt.Println(shared.Value()) }\n'
    pinned_value = 'package shared\nfunc Value() string { return "pinned-ordinary-module" }\n'
    manifests = {"project/go.mod": module + "replace example.invalid/module-shared => ../shared\n",
        "project/apps/primary/main.go": main, "project/cmd/helper/main.go": main,
        "project/cmd/arm-helper/main.go": main, "shared/value.go": pinned_value,
        # Dependency-module replacement rules are deliberately inactive in Go.
        "shared/go.mod": dependency + "replace example.invalid/ignored => /outside-ignored-dependency\n"}

    def write_files(changes):
        for name, value in changes.items():
            path = module_upstream / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)

    def commit(label, untracked=()):
        required(["git", "-C", module_upstream, "add", "."], label + "-add")
        if untracked:
            required(["git", "-C", module_upstream, "update-index", "--force-remove", "--", *untracked], label + "-untrack")
        required(["git", "-C", module_upstream, "commit", "--quiet", "-m", label], label + "-commit")
        return required(["git", "-C", module_upstream, "rev-parse", "HEAD"], label + "-pin")

    def run(label, *, selected_runtime=None, reference="HEAD", parameters=None, **changes):
        params = {"SourceRef": reference}
        params.update(parameters or {})
        return invoke(label, selected_runtime=selected_runtime or module_runtime, parameters=params,
            extra={"GOPROXY": "off", "GOSUMDB": "off"}, repository_url=module_upstream.as_uri(), **changes)

    def installed_marker(result, fixture, marker, architecture=0x8664):
        prefix = Path(fixture["parameters"]["Prefix"])
        rows = result.get("binaries", [])
        return len(rows) == 2 and all((prefix / row["name"]).is_file() and
            machine(prefix / row["name"]) == architecture and digest(prefix / row["name"]) == row["sha256"] and
            marker.encode() in (prefix / row["name"]).read_bytes() for row in rows)

    write_files(manifests)
    pinned_commit = commit("module-committed-sibling")
    config("module-source", local_path=str(module_upstream))
    generated_module, module_runtime, module_policy = generate("module-source", "module-generate")
    check("ordinary module regression uses the unchanged public source and family policy",
          generated_module.returncode == 0 and module_policy["source"] == policy["source"],
          generated_module.stderr.decode(errors="replace"))
    if generated_module.returncode:
        return
    good, details, fixture = run("module-local-sibling", reference=pinned_commit)
    check("a standalone module builds its complete genuine PE family from a committed sibling",
          good.returncode == 0 and installed_marker(details, fixture, "pinned-ordinary-module") and
          details.get("source", {}).get("source_commit") == pinned_commit and no_http(fixture),
          good.stderr.decode(errors="replace"))
    if good.returncode:
        return
    prefix = Path(fixture["parameters"]["Prefix"])
    before = {name: digest(prefix / name) for name in ("app.exe", "helper.exe")}
    original_bytes = {name: (prefix / name).read_bytes() for name in before}

    def protected_prefix(label):
        selected = root / (label + "-protected-prefix")
        selected.mkdir()
        for name, data in original_bytes.items():
            (selected / name).write_bytes(data)
        return selected

    module_receipt = details["source"].get("go_module", {})
    check("ordinary source receipt identifies its main module and exact committed replacement without ambient paths",
          module_receipt.get("path") == "project" and module_receipt.get("module_path") == "example.invalid/module-app" and
          module_receipt.get("go_mod_sha256") == digest(module_upstream / "project/go.mod") and
          module_receipt.get("local_replacements") == [{"module_path": "example.invalid/module-shared", "version": "",
              "path": "shared", "replacement_module_path": "example.invalid/module-shared",
              "go_mod_sha256": digest(module_upstream / "shared/go.mod")}] and
          module_receipt.get("vendor") is False and "go_workspace" not in details["source"] and
          str(root) not in json.dumps(module_receipt), json.dumps(module_receipt))
    config("module-command", local_path=str(module_upstream), source_subdir="project/apps/primary",
        source_entry="", workspace_binaries=[], workspace_binaries_by_target={})
    nested_generated, nested_runtime, _ = generate("module-command", "module-generate-nested")
    check("a package-directory installer generates through the public CLI", nested_generated.returncode == 0,
          nested_generated.stderr.decode(errors="replace"))
    if nested_generated.returncode:
        return

    def nested_install(label, reference, marker, receipt):
        result, evidence, case = run(label, selected_runtime=nested_runtime, reference=reference)
        exe = Path(case["parameters"]["Prefix"]) / "app.exe"
        rows = evidence.get("binaries", [])
        check(label + " builds the nested Windows executable with the module-root inputs",
              result.returncode == 0 and len(rows) == 1 and exe.is_file() and machine(exe) == 0x8664 and
              rows[0]["sha256"] == digest(exe) and marker.encode() in exe.read_bytes() and
              evidence.get("source", {}).get("go_module") == receipt and no_http(case),
              result.stderr.decode(errors="replace"))

    nested_install("module-command-local", pinned_commit, "pinned-ordinary-module", module_receipt)
    arm, arm_details, arm_fixture = run("module-local-arm64", reference=pinned_commit, platform="windows/arm64")
    check("ordinary local module closure also compiles the selected ARM64 companion family",
          arm.returncode == 0 and installed_marker(arm_details, arm_fixture, "pinned-ordinary-module", 0xAA64) and
          {row["name"] for row in arm_details.get("binaries", [])} == {"app.exe", "arm-helper.exe"},
          arm.stderr.decode(errors="replace"))

    ambient = root / "ambient-module"
    ambient.mkdir()
    (ambient / "go.mod").write_text(dependency)
    (ambient / "value.go").write_text(pinned_value.replace("pinned-ordinary-module", "ambient-module-one"))
    absolute_rule = "replace example.invalid/module-shared => " + json.dumps(str(ambient)) + "\n"
    write_files({"project/go.mod": module + absolute_rule})
    outside_commit = commit("module-absolute-ambient-dependency")
    if options.module_baseline_project:
        old_generated, old_runtime, old_policy = generate("module-source", "module-baseline-generate",
            checkout=options.module_baseline_project.resolve(), destination=root / "module-baseline-generated")
        old, old_details, old_fixture = run("module-baseline-ambient-one", selected_runtime=old_runtime, reference=outside_commit)
        check("frozen baseline actually compiles the external host module under a pinned source receipt",
              old_generated.returncode == 0 and old_policy == module_policy and old.returncode == 0 and
              old_details.get("source", {}).get("source_commit") == outside_commit and
              installed_marker(old_details, old_fixture, "ambient-module-one"), old.stderr.decode(errors="replace"))
        (ambient / "value.go").write_text(pinned_value.replace("pinned-ordinary-module", "ambient-module-two"))
        changed, changed_details, changed_fixture = run("module-baseline-ambient-two", selected_runtime=old_runtime, reference=outside_commit)
        check("the same frozen source pin installs different real bytes after only the ambient dependency changes",
              changed.returncode == 0 and changed_details.get("source", {}).get("source_commit") == outside_commit and
              installed_marker(changed_details, changed_fixture, "ambient-module-two") and
              changed_details.get("source", {}).get("sha256") != old_details.get("source", {}).get("sha256"),
              changed.stderr.decode(errors="replace"))
    refused_prefix = protected_prefix("module-absolute-refusal")
    refused, _, refused_fixture = run("module-absolute-refusal", reference=outside_commit, parameters={"Prefix": str(refused_prefix)})
    check("an absolute local replacement cannot reach Go package loading or alter the existing family",
          refused.returncode == 4 and not any(row["arguments"][0] in ("list", "build") for row in calls(refused_fixture)) and
          all(digest(refused_prefix / name) == value for name, value in before.items()) and no_http(refused_fixture),
          refused.stderr.decode(errors="replace"))

    for label, rule in (
        ("module-relative-escape", "replace example.invalid/module-shared => ../../outside\n"),
        ("module-unused-escape", "replace example.invalid/module-shared => ../shared\nreplace example.invalid/unused => /outside-unused\n"),
        ("module-versioned-escape", "replace example.invalid/module-shared v0.0.0 => ../../outside\n"),
    ):
        write_files({"project/go.mod": module + rule})
        reference = commit(label)
        denied_prefix = protected_prefix(label)
        denied, _, denied_fixture = run(label, reference=reference, parameters={"Prefix": str(denied_prefix)})
        check(label + " fails before dependency loading and preserves the complete prior family",
              denied.returncode == 4 and not any(row["arguments"][0] in ("list", "build") for row in calls(denied_fixture)) and
              all(digest(denied_prefix / name) == value for name, value in before.items()), denied.stderr.decode(errors="replace"))

    injected_prefix = protected_prefix("module-untracked-checksums")
    injected, _, injected_fixture = run("module-untracked-checksums", reference=pinned_commit,
        inject_module_files={"shared/go.sum": ""}, parameters={"Prefix": str(injected_prefix)})
    check("untracked checksum metadata cannot become authority for a selected local module",
          injected.returncode == 4 and not any(row["arguments"][0] in ("list", "build") for row in calls(injected_fixture)) and
          all(digest(injected_prefix / name) == value for name, value in before.items()), injected.stderr.decode(errors="replace"))
    drift_prefix = protected_prefix("module-dependency-drift")
    drift, drift_details, _ = run("module-dependency-drift", reference=pinned_commit,
        parameters={"Prefix": str(drift_prefix)}, mutate_source=True, mutate_source_member="../shared/value.go")
    check("real compilation followed by tracked dependency drift cannot activate any new family member",
          drift.returncode == 7 and "changed the pinned tracked inputs" in drift_details.get("error", "") and
          all(digest(drift_prefix / name) == value for name, value in before.items()), drift.stderr.decode(errors="replace"))

    # Go vendor materialization, not a hand-written imitation, establishes the
    # exact metadata that makes the external replacement original irrelevant.
    write_files({"project/go.mod": module + absolute_rule})
    required(["go", "mod", "vendor"], "module-vendor-materialize", cwd=module_upstream / "project",
        extra={"GOWORK": "off", "GOENV": "off", "GOFLAGS": "", "GOPROXY": "off", "GOSUMDB": "off"})
    vendor_commit = commit("module-committed-vendor")
    vendor_marker = "ambient-module-two" if options.module_baseline_project else "ambient-module-one"
    (ambient / "value.go").write_text(pinned_value.replace("pinned-ordinary-module", "unused-after-vendoring"))
    vendored, vendor_details, vendor_fixture = run("module-committed-vendor", reference=vendor_commit)
    vendor_receipt = vendor_details.get("source", {}).get("go_module", {})
    check("committed ordinary vendor code builds without consuming its now-different external original",
          vendored.returncode == 0 and installed_marker(vendor_details, vendor_fixture, vendor_marker) and
          vendor_receipt.get("vendor") is True and vendor_receipt.get("local_replacements") == [] and
          vendor_receipt.get("vendor_modules_sha256") == digest(module_upstream / "project/vendor/modules.txt") and
          all("-mod=vendor" in row["arguments"] for row in calls(vendor_fixture) if row["arguments"][0] in ("list", "build")),
          vendored.stderr.decode(errors="replace"))
    nested_install("module-command-vendor", vendor_commit, vendor_marker, vendor_receipt)
    vendor_manifest = (module_upstream / "project/vendor/modules.txt").read_text()
    write_files({"project/vendor/modules.txt": vendor_manifest.replace("v0.0.0", "v9.0.0")})
    invalid_vendor_commit = commit("module-inconsistent-vendor")
    inconsistent_prefix = protected_prefix("module-inconsistent-vendor")
    inconsistent, _, inconsistent_fixture = run("module-inconsistent-vendor", reference=invalid_vendor_commit,
        parameters={"Prefix": str(inconsistent_prefix)})
    check("Go still rejects inconsistent committed vendor inventory before compiling any member",
          inconsistent.returncode != 0 and not any(row["arguments"][0] == "build" for row in calls(inconsistent_fixture)) and
          all(digest(inconsistent_prefix / name) == value for name, value in before.items()), inconsistent.stderr.decode(errors="replace"))

    injected_vendor_prefix = protected_prefix("module-untracked-vendor")
    injected_vendor, _, injected_vendor_fixture = run("module-untracked-vendor", reference=pinned_commit,
        inject_module_files={"project/vendor/modules.txt": vendor_manifest}, parameters={"Prefix": str(injected_vendor_prefix)})
    check("untracked module vendor metadata is refused before Go dependency loading",
          injected_vendor.returncode == 4 and not any(row["arguments"][0] in ("list", "build") for row in calls(injected_vendor_fixture)) and
          all(digest(injected_vendor_prefix / name) == value for name, value in before.items()), injected_vendor.stderr.decode(errors="replace"))

    simple = 'package main\nimport "fmt"\nfunc main() { fmt.Println("legacy-vendor-without-dependencies") }\n'
    write_files({"project/go.mod": "module example.invalid/module-app\n\ngo 1.22\n",
        "project/apps/primary/main.go": simple, "project/cmd/helper/main.go": simple})
    legacy_commit = commit("module-legacy-vendor", untracked=["project/vendor/modules.txt"])
    legacy, legacy_details, legacy_fixture = run("module-legacy-vendor", reference=legacy_commit)
    check("legacy committed vendor directories without modules.txt retain Go's no-dependency behavior",
          legacy.returncode == 0 and installed_marker(legacy_details, legacy_fixture, "legacy-vendor-without-dependencies") and
          legacy_details.get("source", {}).get("go_module", {}).get("vendor") is True and
          "vendor_modules_sha256" not in legacy_details.get("source", {}).get("go_module", {}),
          legacy.stderr.decode(errors="replace"))


if not options.go_workspace_only:
    test_go_module_replacements()
if options.go_modules_only:
    print(f"Windows ordinary Go module source tests: {passed} passed, {failed} failed", flush=True)
    print("Real Go PE compilation and Git pins with portable PowerShell; native Windows and live GitHub remain unqualified.", flush=True)
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
