# Windows runs use the production CMD launcher and Win32 handles. The explicit
# Linux mode shares only the cache test's documented OS/process adapters; its
# real Cargo builds are evidence of context semantics, never native CMD proof.
[CmdletBinding()]
param([switch]$PortableStorageSemantics, [string]$BashPath, [switch]$ToolchainOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$contextTestPath = $PSCommandPath
$cacheTestPath = Join-Path $PSScriptRoot 'test_cargo_cache_windows.ps1'
$moduleRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../src')).Path
. $cacheTestPath -BackendPath (Join-Path $moduleRoot 'cargo_cache_windows.ps1') `
    -PortableStorageSemantics:$PortableStorageSemantics -InitializeBackendOnly
$script:ContextChecks = 0
$utf8 = [Text.UTF8Encoding]::new($false)
$work = Join-Path ([IO.Path]::GetTempPath()) ('dsr-cargo-context-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($work)
Write-Output "Retained context fixtures: $work"

function Check {
    param([string]$Label, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Label" }
    $script:ContextChecks++
    Write-Output "PASS $Label"
}
function Refused {
    param([string]$Label, [scriptblock]$Action, [string]$Pattern='')
    $failure = $null
    try { $null = & $Action } catch { $failure = $_ }
    Check $Label ($null -ne $failure)
    if ($Pattern -and $failure.Exception.Message -notmatch $Pattern) {
        throw "Wrong refusal for ${Label}: $($failure.Exception.Message)"
    }
}
function Write-Text {
    param([string]$Path, [string]$Text)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Invoke-Exe {
    param([string]$Path, [string[]]$Arguments, [switch]$ExpectFailure)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Path
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill($true); throw "Timed out: $Path" }
        $result = [pscustomobject]@{ExitCode=$process.ExitCode; Stdout=$stdout.GetAwaiter().GetResult(); Stderr=$stderr.GetAwaiter().GetResult()}
        if (-not $ExpectFailure -and $result.ExitCode -ne 0) { throw "Command failed: $Path $($Arguments -join ' ')`n$($result.Stderr)" }
        return $result
    } finally { $process.Dispose() }
}
function Invoke-ContextChecked {
    param($Context, [string]$Operation)
    $result = Invoke-DsrCargoContext -Context $Context -Operation $Operation -CaptureOutput
    if ($result.ExitCode -ne 0) { throw "Cargo context $Operation failed: $($result.Stderr)" }
    return $result
}
function Copy-MutableLinker {
    param([string]$Original,[string]$Directory)
    $null=[IO.Directory]::CreateDirectory($Directory)
    $path=Join-Path $Directory ([IO.Path]::GetFileName($Original))
    [IO.File]::Copy($Original,$path)
    $environment=@()
    if ($script:WindowsHost) {
        # MSVC's private PDB/runtime DLLs remain unchanged beside the copy.
        foreach ($dll in [IO.Directory]::EnumerateFiles([IO.Path]::GetDirectoryName($Original),'*.dll')) {
            [IO.File]::Copy($dll,(Join-Path $Directory ([IO.Path]::GetFileName($dll))))
        }
        $pdbServer=Join-Path ([IO.Path]::GetDirectoryName($Original)) 'mspdbsrv.exe'
        if (Test-Path -LiteralPath $pdbServer -PathType Leaf) {
            [IO.File]::Copy($pdbServer,(Join-Path $Directory 'mspdbsrv.exe'))
        }
    } else {
        [IO.File]::SetUnixFileMode($path,[IO.File]::GetUnixFileMode($Original))
        # GCC discovers private executables and plugins relative to argv[0].
        # Preserve its actual installed support prefix while copying its EXE.
        $libgcc=(Invoke-Exe $Original @('-print-libgcc-file-name')).Stdout.Trim()
        if (-not (Test-Path -LiteralPath $libgcc -PathType Leaf)) { throw 'Portable mutation fixture requires the genuine GCC support directory' }
        $supportDirectory=[IO.Path]::GetDirectoryName($libgcc)
        $supportPrefix=[IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($supportDirectory))
        $environment+='GCC_EXEC_PREFIX=' + $supportPrefix + [IO.Path]::DirectorySeparatorChar
    }
    return @{Path=$path; Environment=$environment}
}
function Invoke-GeneratedContext {
    param([ValidateSet('Metadata','Build','Finish')][string]$Operation,
        [string]$BuildCommand, [string[]]$ConfiguredEnvironment, [string]$Suffix, $Admission,
        [switch]$ExpectFailure)
    $generator = @'
source "$1" || exit $?
shift
_act_windows_cargo_cache_runtime() { :; }
_act_windows_cargo_context_runtime() { :; }
_act_windows_cargo_sources_runtime() { :; }
case "$1" in
Metadata)
    _act_windows_private_cargo_home_script "$2" "$3" || exit $?
    _act_windows_cargo_metadata_body "$4" "$5" || exit $?
    printf '%s\n' '$dsrPrivateSummary | ConvertTo-Json -Compress -Depth 100; exit 0'
    ;;
Build)
    _act_windows_strict_cargo_build_script "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
    ;;
Finish)
    exec 3>&1
    _act_windows_cache_command() { printf '%s\n' "$3" >&3; return 75; }
    _act_finish_windows_private_cargo_home fixture-host "$2" "$3" "$4" "$5" "$6" "$7" "$8"
    result=$?
    [[ "$result" -eq 75 ]] || exit 1
    ;;
esac
'@
    $sourceArgument = if ($script:WindowsHost) { $source.Replace('\','/') } else { 'C:/dsr-context-source' }
    $homeArgument = if ($null -eq $Admission) { '' }
        elseif ($script:WindowsHost) { $Admission.cargo_home } else { 'C:/dsr-context-home' }
    $arguments = @('-c',$generator,'_', (Join-Path $moduleRoot 'act_runner.sh').Replace('\','/'), $Operation)
    if ($Operation -eq 'Metadata') { $arguments += @($sourceArgument,$Suffix,$BuildCommand,($ConfiguredEnvironment -join "`n")) }
    elseif ($Operation -eq 'Build') { $arguments += @($sourceArgument,$homeArgument,$BuildCommand,($ConfiguredEnvironment -join "`n"),
        $Admission.cargo_context.fingerprint,$Admission.cargo_context.receipt_sha256,$Admission.receipt_sha256,
        ($Admission.dependency_sources | ConvertTo-Json -Compress -Depth 100)) }
    else { $arguments += @($homeArgument,$Admission.receipt_sha256,$sourceArgument,
        ($Admission.dependency_sources | ConvertTo-Json -Compress -Depth 100),$BuildCommand,($ConfiguredEnvironment -join "`n"),
        ($Admission.cargo_context | ConvertTo-Json -Compress -Depth 100)) }
    $generated = Invoke-Exe $bash $arguments
    $body = $generated.Stdout
    if (-not $script:WindowsHost) {
        # Literal fixture root mapping only. The generated program and context
        # algorithm execute unchanged, using the explicitly loaded OS adapters.
        $body = $body.Replace('C:/dsr-context-source',$source)
        if ($null -ne $Admission) { $body = $body.Replace('C:/dsr-context-home',$Admission.cargo_home) }
    }
    $programPath = Join-Path $work ('generated-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    Write-Text $programPath $body
    $childArguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',$cacheTestPath,
        '-BackendPath',(Join-Path $moduleRoot 'cargo_cache_windows.ps1'),'-GeneratedScriptPath',$programPath)
    if ($PortableStorageSemantics) { $childArguments += '-PortableStorageSemantics' }
    return Invoke-Exe ([Environment]::ProcessPath) $childArguments -ExpectFailure:$ExpectFailure
}

$cargo = (Get-Command cargo -CommandType Application | Select-Object -First 1).Source
$rustc = (Get-Command rustc -CommandType Application | Select-Object -First 1).Source
$rustup = (Get-Command rustup -CommandType Application | Select-Object -First 1).Source
$sysroot = (Invoke-Exe $rustc @('--print','sysroot')).Stdout.Trim()
$hostTriple = ((Invoke-Exe $rustc @('-vV')).Stdout -split "`n" | Where-Object { $_.StartsWith('host: ') }).Substring(6).Trim()
if ($BashPath) { $bash = $BashPath }
elseif ($script:WindowsHost) {
    $git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $bash = Join-Path (Split-Path -Parent (Split-Path -Parent $git)) 'bin/bash.exe'
} else { $bash = (Get-Command bash -CommandType Application | Select-Object -First 1).Source }
if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) { throw 'Git Bash is required; pass -BashPath explicitly.' }
$extension = if ($script:WindowsHost) { '.exe' } else { '' }
$proxyDirectory = Join-Path $work 'tool directory with spaces'
$null = [IO.Directory]::CreateDirectory($proxyDirectory)
$proxyCargo = Join-Path $proxyDirectory ('cargo' + $extension)
[IO.File]::Copy($rustup, $proxyCargo)
if (-not $script:WindowsHost) {
    [IO.File]::SetUnixFileMode($proxyCargo, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
}
$privateRustup = Join-Path $work 'private-rustup'
$warmHome = Join-Path $work 'warm-cargo'
$privateHome = Join-Path $work 'private-cargo'
foreach ($path in @($privateRustup,$warmHome,$privateHome)) { $null = [IO.Directory]::CreateDirectory($path) }
$source = Join-Path $work 'project/source'
$manifest = Join-Path $source 'Cargo.toml'
Write-Text $manifest @'
[package]
name="dsr-context-probe"
version="1.0.0"
edition="2021"
[features]
default=["default-mode"]
default-mode=[]
selected=[]
selected-two=[]
metadata-only=["dep:closure-dependency"]
[dependencies]
closure-dependency={path="closure-dependency",optional=true}
'@
Write-Text (Join-Path $source 'src/main.rs') @'
fn main() {
    #[cfg(all(feature="selected", feature="selected-two", not(feature="default-mode")))] println!("selected");
    #[cfg(any(not(feature="selected"), not(feature="selected-two"), feature="default-mode"))] println!("wrong-features");
}
'@
Write-Text (Join-Path $source 'closure-dependency/Cargo.toml') "[package]`nname=`"closure-dependency`"`nversion=`"1.0.0`"`nedition=`"2021`"`n"
Write-Text (Join-Path $source 'closure-dependency/src/lib.rs') 'pub fn value() -> u32 { 42 }'
$null = Invoke-Exe $cargo @('generate-lockfile','--offline','--manifest-path',$manifest)
$saved = @{}
foreach ($name in @('RUSTUP_HOME','RUSTUP_TOOLCHAIN','CARGO_HOME','RUSTFLAGS','RUSTC_WRAPPER','NoDefaultCurrentDirectoryInExePath')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
}
try {
    $env:RUSTUP_HOME = $privateRustup
    $env:CARGO_HOME = $warmHome
    $null = Invoke-Exe $rustup @('toolchain','link','dsr-context-selected',$sysroot)
    $env:RUSTUP_TOOLCHAIN = 'dsr-context-unavailable'
    $bare = Invoke-Exe $proxyCargo @('--version') -ExpectFailure
    Check 'the fixture default toolchain is genuinely unavailable' ($bare.ExitCode -ne 0 -and $bare.Stderr -match 'dsr-context-unavailable')
    $env:RUSTFLAGS = '--this-ambient-flag-must-not-enter-the-context'
    $env:RUSTC_WRAPPER = 'unavailable-ambient-wrapper'
    $targetDir = Join-Path $work 'build-output'
    $baseEnvironment = @("RUSTUP_HOME=$privateRustup",'RUSTUP_TOOLCHAIN=dsr-context-unavailable',
        "CARGO_TARGET_DIR=$targetDir",'cargo_home=ignored-operator-home','RCH_DISABLED=0','RCH_CARGO_WRAPPER_BYPASS=0')
    $command = '"' + $proxyCargo + '" "+dsr-context-selected" build -j1 --locked --offline --no-default-features --features "selected, selected-two" --target ' + $hostTriple
    if ($script:WindowsHost) {
        $launcherEnvironment=New-DsrCargoContextEnvironment -CargoHome $privateHome -Environment $baseEnvironment
        $launcherContext=[pscustomobject]@{SourceRoot=$source; Environment=$launcherEnvironment.Environment;
            CmdPath=(Get-DsrCargoCmdPath $launcherEnvironment.Environment)}
        $launcherResult=Invoke-DsrCargoCommand -Context $launcherContext -Command 'echo dsr-native-cmd-launcher' -CaptureOutput $true
        Check 'slash-normalized CMD identity launches its literal command without parsing argv0 as a switch' (
            $launcherContext.CmdPath.Contains('/') -and $launcherResult.ExitCode -eq 0 -and
            $launcherResult.Stdout.Trim() -ceq 'dsr-native-cmd-launcher' -and -not $launcherResult.Stderr.Trim())
    }
    $context = New-DsrCargoContext -BuildCommand $command -SourceRoot $source -CargoHome $privateHome -Environment $baseEnvironment -ExpectedTarget $hostTriple
    if ($script:WindowsHost) {
        $comspecResult=Invoke-Exe $context.Environment['COMSPEC'] @('/d','/v:off','/s','/c','echo dsr-native-comspec')
        Check 'the admitted COMSPEC environment launches correctly in downstream native processes' (
            -not $context.Environment['COMSPEC'].Contains('/') -and $comspecResult.ExitCode -eq 0 -and
            $comspecResult.Stdout.Trim() -ceq 'dsr-native-comspec' -and -not $comspecResult.Stderr.Trim())
    }
    Check 'literal quoted executable and toolchain prefix are retained exactly' ($context.CargoPrefix -ceq ('"' + $proxyCargo + '" "+dsr-context-selected"'))
    Check 'metadata selects the same explicit installed toolchain' ($context.MetadataCommand.StartsWith($context.CargoPrefix + ' metadata '))
    Check 'metadata retains conservative all-features source closure' ($context.MetadataCommand -match ' --all-features ' -and $context.MetadataCommand -match ' --filter-platform ')
    Check 'managed Cargo home and RCH bypass values override differently cased configured selectors' (
        $context.Environment['CARGO_HOME'] -eq (Get-DsrCacheFullPath $privateHome) -and $context.Environment['RCH_DISABLED'] -eq '1' -and $context.Environment['RCH_CARGO_WRAPPER_BYPASS'] -eq '1')
    Check 'unconfigured ambient Rust selectors are removed from both operations' (-not $context.Environment.ContainsKey('RUSTFLAGS') -and -not $context.Environment.ContainsKey('RUSTC_WRAPPER'))
    $identity=$context.ToolchainIdentity
    $realCargo=Join-Path $sysroot ('bin/cargo' + $extension)
    $realRustc=Join-Path $sysroot ('bin/rustc' + $extension)
    Check 'Cargo attestation binds the selected rustup proxy bytes and the actual selected toolchain Cargo' (
        $identity.tools.cargo.selected_path -ceq (Get-DsrCacheFullPath $proxyCargo) -and
        $identity.tools.cargo.selected_sha256 -ceq (Get-FileHash -LiteralPath $proxyCargo -Algorithm SHA256).Hash.ToLowerInvariant() -and
        $identity.tools.cargo.resolved_path -ceq (Resolve-DsrCargoPhysicalToolPath $realCargo) -and
        $identity.tools.cargo.resolved_sha256 -ceq (Get-FileHash -LiteralPath $realCargo -Algorithm SHA256).Hash.ToLowerInvariant())
    Check 'compiler attestation resolves the same explicit rustup toolchain and verbose host identity' (
        $identity.tools.rustc.resolved_path -ceq (Resolve-DsrCargoPhysicalToolPath $realRustc) -and
        $identity.tools.rustc.resolved_sha256 -ceq (Get-FileHash -LiteralPath $realRustc -Algorithm SHA256).Hash.ToLowerInvariant() -and
        $identity.tools.rustc.version -match ('(?m)^host: ' + [regex]::Escape($hostTriple)) -and
        $identity.tools.cargo.version -match '(?m)^release: ' -and $identity.tools.rustc.version -match '(?m)^commit-hash: ')
    Check 'default linker attestation uses the executable selected by real rustc linking' (
        $identity.target_triple -ceq $hostTriple -and
        (Test-Path -LiteralPath $identity.tools.linker.selected_path -PathType Leaf) -and
        $identity.tools.linker.selected_sha256 -ceq (Get-FileHash -LiteralPath $identity.tools.linker.selected_path -Algorithm SHA256).Hash.ToLowerInvariant() -and
        $identity.tools.linker.version.Length -gt 0)
    $isolatedBin=Join-Path $work 'proxies-without-helper'
    $null=[IO.Directory]::CreateDirectory($isolatedBin)
    foreach ($tool in @('cargo','rustc')) {
        $destination=Join-Path $isolatedBin ($tool+$extension)
        [IO.File]::Copy($rustup,$destination)
        if (-not $script:WindowsHost) { [IO.File]::SetUnixFileMode($destination,[IO.File]::GetUnixFileMode($rustup)) }
    }
    $isolatedPath=@($isolatedBin)
    foreach ($directory in $env:PATH.Split([IO.Path]::PathSeparator)) {
        if ($directory -and -not (Test-Path -LiteralPath (Join-Path $directory.Trim('"') ('rustup'+$extension)) -PathType Leaf)) { $isolatedPath+=$directory }
    }
    $isolatedEnvironment=@("RUSTUP_HOME=$privateRustup",'RUSTUP_TOOLCHAIN=dsr-context-selected',
        ('PATH='+($isolatedPath -join [IO.Path]::PathSeparator)),"CARGO_TARGET_DIR=$targetDir")
    $isolatedCommand='"'+(Join-Path $isolatedBin ('cargo'+$extension))+'" build --locked --offline'
    $isolatedContext=New-DsrCargoContext -BuildCommand $isolatedCommand -SourceRoot $source -CargoHome $privateHome -Environment $isolatedEnvironment
    Check 'genuine default Rustup proxies resolve actual executables without any Rustup helper on PATH' (
        -not (Resolve-DsrCargoTool -Context $isolatedContext -Program rustup -Optional) -and
        $isolatedContext.ToolchainIdentity.tools.cargo.resolved_sha256 -ceq $identity.tools.cargo.resolved_sha256 -and
        $isolatedContext.ToolchainIdentity.tools.rustc.resolved_sha256 -ceq $identity.tools.rustc.resolved_sha256)
    $differentHelper=Join-Path $isolatedBin ('rustup'+$extension)
    [IO.File]::Copy($realCargo,$differentHelper)
    if (-not $script:WindowsHost) { [IO.File]::SetUnixFileMode($differentHelper,[IO.File]::GetUnixFileMode($realCargo)) }
    $isolatedContext=New-DsrCargoContext -BuildCommand $isolatedCommand -SourceRoot $source -CargoHome $privateHome -Environment $isolatedEnvironment
    Check 'a mismatched executable named Rustup cannot hide actual proxy-dispatched compiler identity' (
        $isolatedContext.ToolchainIdentity.tools.cargo.resolved_sha256 -ceq $identity.tools.cargo.resolved_sha256 -and
        $isolatedContext.ToolchainIdentity.tools.rustc.resolved_sha256 -ceq $identity.tools.rustc.resolved_sha256)
    $directContext=New-DsrCargoContext -BuildCommand ('"'+$realCargo+'" build --locked --offline') -SourceRoot $source -CargoHome $privateHome -Environment ($baseEnvironment+"RUSTC=$realRustc")
    Check 'genuine direct Cargo and compiler executables remain supported without Rustup dispatch' (
        $directContext.ToolchainIdentity.tools.cargo.selected_sha256 -ceq $identity.tools.cargo.resolved_sha256 -and
        $directContext.ToolchainIdentity.tools.rustc.selected_sha256 -ceq $identity.tools.rustc.resolved_sha256)
    # Compile a real native forwarding entrypoint. Its child can report real
    # Rustup version/which output, but those observations cannot prove that
    # the selected bytes themselves are an installed Rustup manager.
    $forwarderDirectory=Join-Path $work 'unrecognized-native-forwarder'
    $forwarderSource=Join-Path $forwarderDirectory 'forwarder.rs'
    Write-Text $forwarderSource @'
use std::{env, process::{Command, exit}};
#[cfg(unix)] use std::os::unix::process::CommandExt;
fn main() {
    let mut command = Command::new(env::var_os("DSR_REAL_TOOL").expect("real tool"));
    #[cfg(unix)]
    if env::var_os("DSR_PRESERVE_ARG0").is_some() {
        command.arg0(env::args_os().next().expect("argv0"));
    }
    let status = command.args(env::args_os().skip(1)).status().expect("child");
    exit(status.code().unwrap_or(1));
}
'@
    $forwarderCargo=Join-Path $forwarderDirectory ('cargo'+$extension)
    $null=Invoke-Exe $realRustc @($forwarderSource,'-o',$forwarderCargo)
    $forwarderRustc=Join-Path $forwarderDirectory ('rustc'+$extension)
    $forwarderRustup=Join-Path $forwarderDirectory ('rustup'+$extension)
    foreach ($copy in @($forwarderRustc,$forwarderRustup)) {
        [IO.File]::Copy($forwarderCargo,$copy)
        if (-not $script:WindowsHost) { [IO.File]::SetUnixFileMode($copy,[IO.File]::GetUnixFileMode($forwarderCargo)) }
    }
    $forwarderEnvironment=$isolatedEnvironment+"DSR_REAL_TOOL=$proxyCargo"
    $probeEnvironment=New-DsrCargoContextEnvironment -CargoHome $privateHome -Environment $forwarderEnvironment
    $forwarderProbe=[pscustomobject]@{SourceRoot=$source; CmdPath=$context.CmdPath; Environment=$probeEnvironment.Environment}
    $forwardedVersion=Invoke-DsrCargoToolProbe -Context $forwarderProbe -Program $forwarderCargo -Arguments @('--version')
    Check 'the compiled Cargo forwarder genuinely invokes the selected Cargo toolchain' ($forwardedVersion.Stdout -match '^cargo ')
    foreach ($selector in @('', '+dsr-context-selected ')) {
        Refused ('unrecognized native Cargo cannot claim Rustup resolution with selector ['+$selector.Trim()+']') {
            New-DsrCargoContext -BuildCommand ('"'+$forwarderCargo+'" '+$selector+'build --locked --offline') `
                -SourceRoot $source -CargoHome $privateHome -Environment $forwarderEnvironment
        } 'Unresolved Rustup dispatch|proven rustup Cargo proxy'
    }
    $compilerForwarderEnvironment=$isolatedEnvironment+@("RUSTC=$forwarderRustc",('DSR_REAL_TOOL='+ (Join-Path $isolatedBin ('rustc'+$extension))))
    Refused 'a native compiler forwarding Rustup cannot receive selected-only compiler evidence' {
        New-DsrCargoContext -BuildCommand $isolatedCommand -SourceRoot $source -CargoHome $privateHome -Environment $compilerForwarderEnvironment
    } 'Unresolved Rustup dispatch'
    if (-not $script:WindowsHost) {
        $aliasEnvironment=$forwarderEnvironment+'DSR_PRESERVE_ARG0=1'
        $aliasProbeEnvironment=New-DsrCargoContextEnvironment -CargoHome $privateHome -Environment $aliasEnvironment
        $aliasProbe=[pscustomobject]@{SourceRoot=$source; CmdPath=$context.CmdPath; Environment=$aliasProbeEnvironment.Environment}
        $aliasVersion=Invoke-DsrCargoToolProbe -Context $aliasProbe -Program $forwarderRustup -Arguments @('--version')
        $aliasWhich=Invoke-DsrCargoToolProbe -Context $aliasProbe -Program $forwarderRustup -Arguments @('which','cargo')
        Check 'a byte-identical forwarding Rustup alias can mimic manager behavior without manager bytes' (
            $aliasVersion.Stdout -match '^rustup ' -and
            (Resolve-DsrCargoPhysicalToolPath $aliasWhich.Stdout.Trim()) -ceq (Resolve-DsrCargoPhysicalToolPath $realCargo) -and
            (Get-DsrCargoToolFileHash $forwarderRustup) -ceq (Get-DsrCargoToolFileHash $forwarderCargo) -and
            (Get-DsrCargoToolFileHash $forwarderRustup) -cne (Get-DsrCargoToolFileHash $rustup))
        foreach ($selector in @('', '+dsr-context-selected ')) {
            Refused ('a matching sibling forwarding Rustup cannot authorize Cargo with selector ['+$selector.Trim()+']') {
                New-DsrCargoContext -BuildCommand ('"'+$forwarderCargo+'" '+$selector+'build --locked --offline') `
                    -SourceRoot $source -CargoHome $privateHome -Environment $aliasEnvironment
            } 'Unresolved Rustup dispatch|proven rustup Cargo proxy'
        }
    }
    $metadata = Invoke-ContextChecked $context Metadata
    $metadataJson = ConvertFrom-Json $metadata.Stdout
    Check 'real selected Cargo metadata includes the optional source dependency' (@($metadataJson.packages | Where-Object name -eq 'closure-dependency').Count -eq 1)
    $receiptPath = Join-Path $work 'context-receipt.json'
    $receipt = Write-DsrCargoContextReceipt -Context $context -Path $receiptPath
    Check 'context receipt binds exact persisted bytes' ((Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $receipt.receipt_sha256)
    $durableContext=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    Check 'durable context receipt retains full executable evidence authenticated by its fingerprint' (
        $durableContext.toolchain_sha256 -ceq (Get-DsrCacheBytesHash ($utf8.GetBytes((ConvertTo-DsrCacheCanonicalJson $identity) + "`n"))) -and
        (ConvertTo-DsrCacheCanonicalJson $durableContext.toolchain) -ceq (ConvertTo-DsrCacheCanonicalJson $identity) -and
        (ConvertTo-DsrCacheCanonicalJson $receipt.toolchain) -ceq (ConvertTo-DsrCacheCanonicalJson $identity))
    Assert-DsrCargoContextReceipt -Context $context -Path $receiptPath -Fingerprint $receipt.fingerprint -ReceiptSha256 $receipt.receipt_sha256
    $null = Invoke-ContextChecked $context Build
    $binary = Join-Path $targetDir ($hostTriple + '/debug/dsr-context-probe' + $extension)
    Check 'real selected Cargo builds and runs with the requested feature set' ((Invoke-Exe $binary @()).Stdout.Trim() -eq 'selected')
    Assert-DsrCargoContextReceipt -Context $context -Path $receiptPath -Fingerprint $receipt.fingerprint -ReceiptSha256 $receipt.receipt_sha256
    Check 'successful real compilation preserves the admitted context receipt' $true
    Check 'durable receipts retain digests rather than configured environment values' (-not ([IO.File]::ReadAllText($receiptPath).Contains($privateRustup)))

    $changed = New-DsrCargoContext -BuildCommand ($command + ' --release') -SourceRoot $source -CargoHome $privateHome -Environment $baseEnvironment
    Refused 'changed build arguments cannot reuse admitted metadata authority' { Assert-DsrCargoContextReceipt -Context $changed -Path $receiptPath -Fingerprint $receipt.fingerprint -ReceiptSha256 $receipt.receipt_sha256 } 'changed'
    $changed = New-DsrCargoContext -BuildCommand $command -SourceRoot $source -CargoHome $privateHome -Environment ($baseEnvironment + 'RUSTFLAGS=-C debuginfo=1')
    Refused 'changed configured compiler environment cannot reuse metadata authority' { Assert-DsrCargoContextReceipt -Context $changed -Path $receiptPath -Fingerprint $receipt.fingerprint -ReceiptSha256 $receipt.receipt_sha256 } 'changed'
    Refused 'receipt digest substitution is refused' { Assert-DsrCargoContextReceipt -Context $context -Path $receiptPath -Fingerprint $receipt.fingerprint -ReceiptSha256 ('0' * 64) } 'changed'
    Refused 'an existing context receipt is never overwritten' { Write-DsrCargoContextReceipt -Context $context -Path $receiptPath }
    $mutated = New-DsrCargoContext -BuildCommand $command -SourceRoot $source -CargoHome $privateHome -Environment $baseEnvironment
    $mutated.Environment['PATH'] += [IO.Path]::PathSeparator + (Join-Path $work 'different-lookup')
    Refused 'in-memory executable lookup drift is refused before launch' { Invoke-DsrCargoContext -Context $mutated -Operation Build -CaptureOutput } 'changed before launch'
    $configPath = Join-Path $source '.cargo/config.toml'
    Write-Text $configPath "[build]`njobs=1`n"
    Refused 'new source Cargo configuration invalidates admitted metadata' { Assert-DsrCargoContextReceipt -Context $context -Path $receiptPath -Fingerprint $receipt.fingerprint -ReceiptSha256 $receipt.receipt_sha256 } 'changed'
    Refused 'new source Cargo configuration prevents a build launch' { Invoke-DsrCargoContext -Context $context -Operation Build -CaptureOutput } 'changed before launch'
    $fresh = New-DsrCargoContext -BuildCommand $command -SourceRoot $source -CargoHome $privateHome -Environment $baseEnvironment
    $null = Invoke-ContextChecked $fresh Metadata
    $null = Invoke-ContextChecked $fresh Build
    Check 'fresh admission can build with the new tracked Cargo configuration' $true

    if (-not $ToolchainOnly) {
    $generatedTarget = Join-Path $work 'generated-target'
    $generatedEnvironment = @("RUSTUP_HOME=$privateRustup",'RUSTUP_TOOLCHAIN=dsr-context-unavailable',
        "CARGO_TARGET_DIR=$generatedTarget",'cargo_home=must-not-override-private-home')
    $prepared = Invoke-GeneratedContext Metadata $command $generatedEnvironment 'metadata-context' $null
    $admission = ConvertFrom-Json $prepared.Stdout
    Check 'generated metadata admits both cache and Cargo context receipts' (
        $admission.cargo_context.fingerprint -match '^[0-9a-f]{64}$' -and $admission.cargo_context.receipt_sha256 -match '^[0-9a-f]{64}$')
    Check 'generated metadata returns actual tool identities for durable coordinator retention' (
        $admission.toolchain.tools.cargo.resolved_sha256 -ceq $identity.tools.cargo.resolved_sha256 -and
        $admission.toolchain.tools.rustc.resolved_sha256 -ceq $identity.tools.rustc.resolved_sha256 -and
        $admission.toolchain.tools.linker.selected_sha256 -ceq $identity.tools.linker.selected_sha256)
    $generatedMetadata = Get-Content -LiteralPath (Join-Path $admission.cargo_home '.dsr-cargo-metadata.json') -Raw | ConvertFrom-Json
    Check 'generated selected-toolchain metadata retains optional source closure' (@($generatedMetadata.packages | Where-Object name -eq 'closure-dependency').Count -eq 1)
    $null = Invoke-GeneratedContext Build $command $generatedEnvironment '' $admission
    $generatedBinary = Join-Path $generatedTarget ($hostTriple + '/debug/dsr-context-probe' + $extension)
    Check 'generated native build program executes the same selected Cargo context' ((Invoke-Exe $generatedBinary @()).Stdout.Trim() -eq 'selected')
    $finished = Invoke-GeneratedContext Finish $command $generatedEnvironment '' $admission
    $final = ConvertFrom-Json $finished.Stdout
    $null = Invoke-DsrCargoCache -Operation verify -First $admission.cargo_home -Second $final.receipt_path
    Check 'generated metadata build and finish retain a verifiable final cache receipt' ($final.mode -eq 'inventory')
    $forgedAdmission=$admission | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $forgedAdmission.cargo_context.fingerprint='0' * 64
    $forgedFinish=Invoke-GeneratedContext Finish $command $generatedEnvironment '' $forgedAdmission -ExpectFailure
    Check 'independent finish refuses a substituted coordinator-held context fingerprint' (
        $forgedFinish.ExitCode -ne 0 -and $forgedFinish.Stderr -match 'context changed')
    $finishTool=Copy-MutableLinker -Original $identity.tools.linker.selected_path -Directory (Join-Path $work 'finish-drift-linker')
    $finishTarget=Join-Path $work 'finish-drift-target'
    $finishLinkerVariable='CARGO_TARGET_' + ($hostTriple.ToUpperInvariant() -replace '[^A-Z0-9]','_') + '_LINKER'
    $finishEnvironment=@($generatedEnvironment) + @("CARGO_TARGET_DIR=$finishTarget", "$finishLinkerVariable=$($finishTool.Path)") + $finishTool.Environment
    $finishPrepared=Invoke-GeneratedContext Metadata $command $finishEnvironment 'metadata-finish-drift' $null
    $finishAdmission=ConvertFrom-Json $finishPrepared.Stdout
    $null=Invoke-GeneratedContext Build $command $finishEnvironment '' $finishAdmission
    Check 'the independent admission fixture completes and runs an actual Cargo build' (
        (Invoke-Exe (Join-Path $finishTarget ($hostTriple + '/debug/dsr-context-probe' + $extension)) @()).Stdout.Trim() -ceq 'selected')
    $driftStream=[IO.File]::Open($finishTool.Path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $driftBytes=$utf8.GetBytes('post-build linker drift'); $driftStream.Write($driftBytes,0,$driftBytes.Length) }
    finally { $driftStream.Dispose() }
    $driftFinish=Invoke-GeneratedContext Finish $command $finishEnvironment '' $finishAdmission -ExpectFailure
    Check 'independent finish refuses executable drift after the build postamble has succeeded' (
        $driftFinish.ExitCode -ne 0 -and $driftFinish.Stderr -match 'context changed' -and
        -not (Test-Path -LiteralPath ($finishAdmission.cargo_home + '.final.json')))
    $changedBuild = Invoke-GeneratedContext Build ($command + ' --release') $generatedEnvironment '' $admission -ExpectFailure
    Check 'generated build rejects changed arguments before compilation' (
        $changedBuild.ExitCode -ne 0 -and $changedBuild.Stderr -match 'context changed' -and
        -not (Test-Path -LiteralPath (Join-Path $generatedTarget ($hostTriple + '/release/dsr-context-probe' + $extension))))
    $changedEnvironment = Invoke-GeneratedContext Build $command ($generatedEnvironment + 'RUSTFLAGS=-C debuginfo=1') '' $admission -ExpectFailure
    Check 'generated build rejects changed compiler environment before compilation' ($changedEnvironment.ExitCode -ne 0 -and $changedEnvironment.Stderr -match 'context changed')
    # Genuine compilation changes one previously admitted Cargo input from its
    # build script. The post-build context check must refuse success afterward.
    Write-Text (Join-Path $source 'build.rs') 'fn main() { std::fs::write(".cargo/config.toml", "[build]\njobs=2\n").unwrap(); }'
    $postTarget = Join-Path $work 'post-build-target'
    $postEnvironment = @("RUSTUP_HOME=$privateRustup",'RUSTUP_TOOLCHAIN=dsr-context-unavailable',"CARGO_TARGET_DIR=$postTarget")
    $postPrepared = Invoke-GeneratedContext Metadata $command $postEnvironment 'metadata-post-build' $null
    $postAdmission = ConvertFrom-Json $postPrepared.Stdout
    $postBuild = Invoke-GeneratedContext Build $command $postEnvironment '' $postAdmission -ExpectFailure
    Check 'a real build that changes admitted Cargo inputs cannot report success' (
        $postBuild.ExitCode -ne 0 -and $postBuild.Stderr -match 'context changed' -and
        (Test-Path -LiteralPath (Join-Path $postTarget ($hostTriple + '/debug/dsr-context-probe' + $extension))))
    }

    foreach ($bad in @(
        'cargo build & echo unsafe', 'cargo build | more', 'cargo build > out', 'cargo build < in',
        'cargo build --features "%EXPAND%"', 'cargo build --features "!EXPAND!"', 'cargo build ^--offline',
        'cargo build (echo unsafe)', "cargo build`necho unsafe", "cargo build`techo unsafe",
        '"car"go build', 'cargo build --features="selected"', 'cargo build --target "unclosed',
        'cargo build --target "x86_64-pc-windows-msvc\"', 'call cargo build', 'powershell cargo build',
        'cargo +%TOOLCHAIN% build', 'cargo + build', 'cargo test', 'cargo build --config settings.toml',
        'cargo build -Zunstable-options', 'cargo rustc -- -C opt-level=3', 'cargo build --target',
        ('cargo build --target ' + $hostTriple + ' --target ' + $hostTriple),
        'cargo build --manifest-path ../other/Cargo.toml', 'C:cargo.exe build', '\\server\share\cargo.exe build'
    )) {
        Refused "unsupported literal command is refused: $($bad.Replace("`n",'<newline>').Replace("`t",'<tab>'))" {
            New-DsrCargoContext -BuildCommand $bad -SourceRoot $source -CargoHome $privateHome -Environment $baseEnvironment
        }
    }
    Refused 'an explicit compiler target cannot contradict the admitted native variant' {
        New-DsrCargoContext -BuildCommand ('cargo build --target ' + $hostTriple) -SourceRoot $source -CargoHome $privateHome -Environment $baseEnvironment -ExpectedTarget wasm32-unknown-unknown
    } 'disagrees'
    $caseParent=Join-Path $work 'manifest-case'
    $null=[IO.Directory]::CreateDirectory($caseParent)
    if ($script:WindowsHost) {
        $null=Invoke-Exe (Join-Path ([Environment]::SystemDirectory) 'fsutil.exe') @('file','setCaseSensitiveInfo',$caseParent,'enable') -ExpectFailure
    }
    $caseSource=Join-Path $caseParent 'Project'; $otherCaseSource=Join-Path $caseParent 'project'
    foreach ($path in @($caseSource,$otherCaseSource)) { $null=[IO.Directory]::CreateDirectory($path) }
    $caseEntry=Open-DsrCacheEntry (Get-DsrCacheFullPath $caseSource) -Directory $true
    $otherCaseEntry=Open-DsrCacheEntry (Get-DsrCacheFullPath $otherCaseSource) -Directory $true
    try { $caseSensitive=$caseEntry.FileId -cne $otherCaseEntry.FileId }
    finally { $caseEntry.Dispose(); $otherCaseEntry.Dispose() }
    if ($caseSensitive) {
        $caseManifest=Join-Path $caseSource 'Cargo.toml'; $otherManifest=Join-Path $otherCaseSource 'Cargo.toml'
        Write-Text $caseManifest "[package]`nname='admitted-case'`nversion='1.0.0'`n"
        Write-Text $otherManifest "[package]`nname='different-case'`nversion='1.0.0'`n"
        Refused 'case-only different source roots cannot substitute the build manifest' {
            Get-DsrCargoContextSelection -BuildCommand ('cargo build --manifest-path "'+$otherManifest+'"') -SourceRoot $caseSource -Environment $context.Environment
        } 'physical source root manifest'
        $hardlinkSource=Join-Path $caseParent 'pRoJeCt'; $null=[IO.Directory]::CreateDirectory($hardlinkSource)
        $hardlinkManifest=Join-Path $hardlinkSource 'Cargo.toml'
        $null=New-Item -ItemType HardLink -Path $hardlinkManifest -Target $caseManifest
        Refused 'a hardlinked manifest in another case-only source directory cannot redirect relative inputs' {
            Get-DsrCargoContextSelection -BuildCommand ('cargo build --manifest-path "'+$hardlinkManifest+'"') -SourceRoot $caseSource -Environment $context.Environment
        } 'physical source root manifest'
    } else { Write-Output 'LIMITATION: case-sensitive directory manifest probes unavailable on this filesystem.' }
    $targetContext = New-DsrCargoContext -BuildCommand ('"' + $proxyCargo + '" +dsr-context-selected build') -SourceRoot $source -CargoHome $privateHome -Environment ($baseEnvironment + "cargo_build_target=$hostTriple")
    Check 'case-insensitive configured target selection reaches metadata filtering' ($targetContext.Target -eq $hostTriple -and $targetContext.MetadataCommand.Contains($hostTriple))

    # Copy a genuine linker. Appending an inert overlay preserves its ability
    # to link while changing the actual executable bytes. The real build script
    # performs that write between compilation phases; no tool results are mocked.
    $mutableSource=Join-Path $work 'mutable-source'
    $mutableHome=Join-Path $work 'mutable-home'
    $mutableTarget=Join-Path $work 'mutable-target'
    $mutableBin=Join-Path $work 'mutable-linker'
    $null=[IO.Directory]::CreateDirectory($mutableHome)
    $mutableTool=Copy-MutableLinker -Original $identity.tools.linker.selected_path -Directory $mutableBin
    $mutableLinker=$mutableTool.Path
    Write-Text (Join-Path $mutableSource 'Cargo.toml') "[package]`nname=`"tool-mutation-probe`"`nversion=`"1.0.0`"`nedition=`"2021`"`n"
    Write-Text (Join-Path $mutableSource 'src/main.rs') 'fn main() { println!("compiled-after-tool-mutation"); }'
    Write-Text (Join-Path $mutableSource 'build.rs') @'
use std::io::Write;
fn main() {
    let path = std::env::var_os("DSR_MUTATE_TOOL").unwrap();
    std::fs::OpenOptions::new().append(true).open(path).unwrap().write_all(b"DSR executable identity mutation\n").unwrap();
}
'@
    $null=Invoke-Exe $proxyCargo @('+dsr-context-selected','generate-lockfile','--offline','--manifest-path',(Join-Path $mutableSource 'Cargo.toml'))
    $linkerVariable='CARGO_TARGET_' + ($hostTriple.ToUpperInvariant() -replace '[^A-Z0-9]','_') + '_LINKER'
    $mutableEnvironment=@("RUSTUP_HOME=$privateRustup",'RUSTUP_TOOLCHAIN=dsr-context-unavailable',"CARGO_TARGET_DIR=$mutableTarget",
        "$linkerVariable=$mutableLinker","DSR_MUTATE_TOOL=$mutableLinker") + $mutableTool.Environment
    $mutableCommand='"' + $proxyCargo + '" +dsr-context-selected build -j1 --locked --offline --target ' + $hostTriple
    $mutableContext=New-DsrCargoContext -BuildCommand $mutableCommand -SourceRoot $mutableSource -CargoHome $mutableHome -Environment $mutableEnvironment
    $null=Invoke-ContextChecked $mutableContext Metadata
    $mutableReceiptPath=Join-Path $work 'mutable-tool-receipt.json'
    $mutableReceipt=Write-DsrCargoContextReceipt -Context $mutableContext -Path $mutableReceiptPath
    Refused 'a genuine successful build cannot admit a linker replaced by its build script' {
        Invoke-ContextChecked $mutableContext Build
    } 'context changed during execution'
    $mutatedBinary=Join-Path $mutableTarget ($hostTriple + '/debug/tool-mutation-probe' + $extension)
    Check 'the tool-mutation fixture really linked and runs before artifact admission rejects it' (
        (Invoke-Exe $mutatedBinary @()).Stdout.Trim() -ceq 'compiled-after-tool-mutation')
    Refused 'the coordinator-held receipt continues refusing the changed executable' {
        Assert-DsrCargoContextReceipt -Context $mutableContext -Path $mutableReceiptPath -Fingerprint $mutableReceipt.fingerprint -ReceiptSha256 $mutableReceipt.receipt_sha256
    } 'context changed'
    Check 'refused tool mutation leaves the originally admitted executable hashes intact in the receipt' (
        (Get-Content -LiteralPath $mutableReceiptPath -Raw | ConvertFrom-Json).toolchain.tools.linker.selected_sha256 -ceq $mutableContext.ToolchainIdentity.tools.linker.selected_sha256 -and
        (Get-FileHash -LiteralPath $mutableLinker -Algorithm SHA256).Hash.ToLowerInvariant() -cne $mutableContext.ToolchainIdentity.tools.linker.selected_sha256)

    foreach ($environment in @(
        'RUSTC_WRAPPER=unsupported-compiler-wrapper', 'CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER=unsupported-workspace-wrapper',
        'RUSTFLAGS=-Clinker=unattested-linker', 'CARGO_ENCODED_RUSTFLAGS=@unattested-response-file',
        'CARGO_UNSTABLE_HOST_CONFIG=true', 'RUSTUP_FORCE_ARG0=rustc'
    )) {
        Refused "executable-selecting environment fails closed: $($environment.Split('=')[0])" {
            New-DsrCargoContext -BuildCommand $command -SourceRoot $source -CargoHome $privateHome -Environment ($baseEnvironment+$environment)
        }
    }
    $configSource=Join-Path $work 'config-source'; $configHome=Join-Path $work 'config-home'
    $null=[IO.Directory]::CreateDirectory($configHome)
    Write-Text (Join-Path $configSource 'Cargo.toml') "[package]`nname=`"config-selection-probe`"`nversion=`"1.0.0`"`nedition=`"2021`"`n"
    Write-Text (Join-Path $configSource 'src/main.rs') 'fn main() {}'
    $null=Invoke-Exe $proxyCargo @('+dsr-context-selected','generate-lockfile','--offline','--manifest-path',(Join-Path $configSource 'Cargo.toml'))
    $selectionConfig=Join-Path $configSource '.cargo/config.toml'
    Write-Text $selectionConfig ("[build]`njobs=1`nrustc='" + $realRustc + "'`nrustflags=[`n '-C', # literal array with comment`n 'debuginfo=0',`n]`n[target.'" + $hostTriple + "']`nlinker='" + $identity.tools.linker.selected_path + "'`n")
    $configuredContext=New-DsrCargoContext -BuildCommand $mutableCommand -SourceRoot $configSource -CargoHome $configHome -Environment $baseEnvironment
    Check 'tracked literal configuration selects actual compiler and linker executable identities' (
        $configuredContext.ToolchainIdentity.tools.rustc.selected_path -ceq (Get-DsrCacheFullPath $realRustc) -and
        $configuredContext.ToolchainIdentity.tools.linker.selected_path -ceq $identity.tools.linker.selected_path -and
        $configuredContext.ToolchainIdentity.selection.cargo_config[0].sha256 -ceq (Get-FileHash -LiteralPath $selectionConfig -Algorithm SHA256).Hash.ToLowerInvariant())
    $null=Invoke-ContextChecked $configuredContext Metadata
    $null=Invoke-ContextChecked $configuredContext Build
    Check 'real Cargo consumes the attested literal compiler and linker configuration' $true
    foreach ($configText in @(
        'build.rustc="hidden-rustc"', ('[build]'+"`n"+'rustc={value="hidden-rustc"}'),
        ('[target.''cfg(windows)'']'+"`n"+'linker="hidden-linker"'), ('[env]'+"`n"+'RUSTC="hidden-rustc"'),
        'include=["hidden.toml"]', ('[build]'+"`n"+'rustflags=["-Clinker=hidden-linker"]'),
        ('[build]'+"`n"+'rustc-wrapper="hidden-wrapper"')
    )) {
        Write-Text $selectionConfig $configText
        Refused 'unsupported tracked Cargo tool selection cannot receive an executable attestation' {
            New-DsrCargoContext -BuildCommand $mutableCommand -SourceRoot $configSource -CargoHome $configHome -Environment $baseEnvironment
        }
    }

    if ($script:WindowsHost) {
        foreach ($relativePath in @('C:relative-tools','\relative-tools','/relative-tools')) {
            Refused 'rooted but drive-relative PATH entries cannot change native executable resolution' {
                New-DsrCargoContext -BuildCommand $command -SourceRoot $source -CargoHome $privateHome -Environment ($baseEnvironment + "PATH=$relativePath;$env:PATH")
            } 'literal absolute PATH entries'
        }
        Refused 'a configured alternate COMSPEC cannot replace the system command interpreter' {
            New-DsrCargoContext -BuildCommand $command -SourceRoot $source -CargoHome $privateHome -Environment ($baseEnvironment + "ComSpec=$proxyCargo")
        } 'system cmd.exe'
        Check 'native launcher binds the actual system CMD path' (
            [StringComparer]::OrdinalIgnoreCase.Equals($context.CmdPath, ([IO.Path]::Combine([Environment]::SystemDirectory,'cmd.exe')).Replace('\','/')))
        # These recorder wrappers delegate every invocation to the same genuine
        # rustup Cargo proxy. Their logs identify which CMD lookup rule selected
        # the program; both metadata and compilation still execute real Cargo.
        $lookupSource = Join-Path $work 'lookup/source'
        Write-Text (Join-Path $lookupSource 'Cargo.toml') "[package]`nname=`"lookup-probe`"`nversion=`"1.0.0`"`nedition=`"2021`"`n"
        Write-Text (Join-Path $lookupSource 'src/main.rs') 'fn main() { println!("lookup-ok"); }'
        $null = Invoke-Exe $proxyCargo @('+dsr-context-selected','generate-lockfile','--offline','--manifest-path',(Join-Path $lookupSource 'Cargo.toml'))
        $lookupBin = Join-Path $work 'lookup/bin'
        $null = [IO.Directory]::CreateDirectory($lookupBin)
        $wrapperSource = Join-Path $work 'cargo-recorder.rs'
        Write-Text $wrapperSource @'
use std::{env, fs::OpenOptions, io::Write, process::{Command, exit}};
fn main() {
    let args: Vec<_> = env::args_os().skip(1).collect();
    let mut log = OpenOptions::new().create(true).append(true).open(env::var_os("DSR_CONTEXT_LOG").unwrap()).unwrap();
    writeln!(log, "EXE|{}|{:?}", env::current_exe().unwrap().display(), args).unwrap();
    let status = Command::new(env::var_os("DSR_CONTEXT_REAL_CARGO").unwrap()).args(args).status().unwrap();
    exit(status.code().unwrap_or(1));
}
'@
        # Invoke the real compiler directly; the deliberately unavailable rustup
        # default and ambient selectors must not affect this recorder fixture.
        $beforeFlags = $env:RUSTFLAGS; $beforeWrapper = $env:RUSTC_WRAPPER
        try {
            Remove-Item Env:RUSTFLAGS,Env:RUSTC_WRAPPER -ErrorAction SilentlyContinue
            $null = Invoke-Exe (Join-Path $sysroot 'bin/rustc.exe') @('--crate-name','cargo_recorder','--edition','2021',$wrapperSource,'-o',(Join-Path $lookupBin 'cargo.exe'))
        } finally { $env:RUSTFLAGS=$beforeFlags; $env:RUSTC_WRAPPER=$beforeWrapper }
        $batch = "@echo off`r`necho CMD^|%~f0^|%*>>`"%DSR_CONTEXT_LOG%`"`r`n`"%DSR_CONTEXT_REAL_CARGO%`" %*`r`nexit /b %ERRORLEVEL%`r`n"
        Write-Text (Join-Path $lookupBin 'cargo.cmd') $batch
        Write-Text (Join-Path $lookupSource 'cargo.cmd') $batch
        Remove-Item Env:NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue
        foreach ($case in @(
            @{Name='cwd-first'; Selector='cargo'; Extensions='.CMD;.EXE'; SkipCwd=$false; Expected=(Join-Path $lookupSource 'cargo.cmd')},
            @{Name='no-cwd'; Selector='cargo'; Extensions='.CMD;.EXE'; SkipCwd=$true; Expected=(Join-Path $lookupBin 'cargo.cmd')},
            @{Name='pathext-exe'; Selector='cargo'; Extensions='.EXE;.CMD'; SkipCwd=$true; Expected=(Join-Path $lookupBin 'cargo.exe')},
            @{Name='explicit-exe'; Selector='cargo.exe'; Extensions='.CMD'; SkipCwd=$true; Expected=(Join-Path $lookupBin 'cargo.exe')}
        )) {
            $log = Join-Path $work ($case.Name + '.log')
            $output = Join-Path $work ($case.Name + '-target')
            $lookupEnvironment = @("RUSTUP_HOME=$privateRustup",'RUSTUP_TOOLCHAIN=dsr-context-unavailable',
                "PATH=$lookupBin;$env:PATH","PATHEXT=$($case.Extensions)","CARGO_TARGET_DIR=$output",
                "DSR_CONTEXT_REAL_CARGO=$proxyCargo","DSR_CONTEXT_LOG=$log")
            if ($case.SkipCwd) { $lookupEnvironment += 'NoDefaultCurrentDirectoryInExePath=0' }
            $lookupCommand=$case.Selector + ' +dsr-context-selected build --offline --locked'
            $lookupEffective=New-DsrCargoContextEnvironment -CargoHome $privateHome -Environment $lookupEnvironment
            $lookupSelection=Get-DsrCargoContextSelection -BuildCommand $lookupCommand -SourceRoot $lookupSource -Environment $lookupEffective.Environment
            $lookup=[pscustomobject]@{SourceRoot=$lookupSource; Environment=$lookupEffective.Environment;
                CmdPath=(Get-DsrCargoCmdPath $lookupEffective.Environment)}
            foreach ($operation in @($lookupSelection.MetadataCommand,$lookupCommand)) {
                $lookupResult=Invoke-DsrCargoCommand -Context $lookup -Command $operation -CaptureOutput $true
                if ($lookupResult.ExitCode -ne 0) { throw ('Native lookup fixture failed: ' + $lookupResult.Stderr) }
            }
            $lines = @(Get-Content -LiteralPath $log)
            Check "native CMD $($case.Name) uses the same selected program for metadata and build" (
                $lines.Count -eq 2 -and @($lines | Where-Object { -not $_.Contains($case.Expected) }).Count -eq 0 -and
                $lines[0].Contains('metadata') -and $lines[1].Contains('build'))
            Check "native CMD $($case.Name) compiles and runs the real program" (
                (Invoke-Exe (Join-Path $output 'debug/lookup-probe.exe') @()).Stdout.Trim() -eq 'lookup-ok')
            Refused "native CMD $($case.Name) opaque Cargo wrapper cannot receive a toolchain attestation" {
                New-DsrCargoContext -BuildCommand $lookupCommand -SourceRoot $lookupSource -CargoHome $privateHome -Environment $lookupEnvironment
            } 'wrapper|proven rustup'
        }
        $shadowCompiler=Join-Path $lookupSource 'rustc.exe'
        [IO.File]::Copy((Join-Path $lookupBin 'cargo.exe'),$shadowCompiler)
        $shadowTarget=Join-Path $work 'shadow-compiler-target'
        $shadowEnvironment=@("RUSTUP_HOME=$privateRustup",'RUSTUP_TOOLCHAIN=dsr-context-unavailable',"CARGO_TARGET_DIR=$shadowTarget")
        $shadowCommand='"' + $proxyCargo + '" +dsr-context-selected build --locked --offline'
        Refused 'a differing cwd compiler cannot silently change native Cargo lookup authority' {
            New-DsrCargoContext -BuildCommand $shadowCommand -SourceRoot $lookupSource -CargoHome $privateHome -Environment $shadowEnvironment
        } 'Ambiguous native Cargo compiler lookup'
        Check 'native compiler shadow refusal occurs before the actual Cargo build creates output' (-not (Test-Path -LiteralPath $shadowTarget))
        $pinnedCompiler=New-DsrCargoContext -BuildCommand $shadowCommand -SourceRoot $lookupSource -CargoHome $privateHome -Environment ($shadowEnvironment + "RUSTC=$realRustc")
        $null=Invoke-ContextChecked $pinnedCompiler Metadata
        $null=Invoke-ContextChecked $pinnedCompiler Build
        Check 'an explicit absolute compiler executes successfully despite a differing cwd executable' (
            (Invoke-Exe (Join-Path $shadowTarget 'debug/lookup-probe.exe') @()).Stdout.Trim() -ceq 'lookup-ok')
    } else {
        Write-Output 'LIMITATION: native CMD quoting, PATHEXT, current-directory lookup, COMSPEC, and batch dispatch cases were not run.'
    }
} finally {
    foreach ($name in $saved.Keys) {
        if ($null -eq $saved[$name]) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
    }
}

$proof = if ($script:WindowsHost) { 'native CMD/Win32 with genuine Cargo compilation' } else { 'explicit portable adapters with genuine Cargo compilation; no native Windows proof' }
Write-Output "$script:ContextChecks context checks passed ($proof)."
