# Real PowerShell, filesystem, Git, and Cargo regression for the Windows cache
# backend. Fixtures are retained so failed Windows runs remain inspectable.
# Linux may explicitly substitute the Windows handle and path boundaries; that
# mode proves PowerShell/cache semantics, not NTFS behavior or a Windows build.
[CmdletBinding()]
param(
    [string]$BackendPath = (Join-Path $PSScriptRoot '../../src/cargo_cache_windows.ps1'),
    [switch]$PortableStorageSemantics,
    [string]$BashPath,
    [string]$GeneratedScriptPath,
    [switch]$InitializeBackendOnly,
    [switch]$InjectMalformedMetadata
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Checks = 0
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:WindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if (-not $script:WindowsHost -and -not $PortableStorageSemantics) {
    throw 'Run on Windows, or explicitly use -PortableStorageSemantics for the limited Linux check.'
}
if ($script:WindowsHost -and $PortableStorageSemantics) {
    throw 'Windows regression must use the production Win32 storage boundary.'
}

. $BackendPath
. (Join-Path (Split-Path -Parent $BackendPath) 'cargo_context_windows.ps1')
. (Join-Path (Split-Path -Parent $BackendPath) 'cargo_sources_windows.ps1')

if ($PortableStorageSemantics) {
    if (-not $IsLinux -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') {
        throw 'The explicit portable handle adapter is limited to Linux x86_64.'
    }
    if (-not $GeneratedScriptPath) {
        Write-Output 'LIMITATION: Linux handle/path and direct-process adapters; native CMD, NTFS, Windows paths, and Windows compilation remain unproved.'
    }
    # The OS handle and path representation boundaries are replaced. Open/fstat/dup are real libc
    # operations, rejecting symlinks and nonregular entries without following
    # them. Production traversal, copying, receipts, hashes and Git checks run
    # unchanged. Linux has no Win32 share-mode equivalent.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public sealed class DsrLinuxCacheTestEntry : IDisposable {
    [StructLayout(LayoutKind.Sequential)]
    private struct Stat {
        public ulong Dev, Ino, Nlink;
        public uint Mode, Uid, Gid;
        public int Pad;
        public ulong Rdev;
        public long Size, BlockSize, Blocks;
        public long Atime, AtimeNs, Mtime, MtimeNs, Ctime, CtimeNs;
        public long Reserved0, Reserved1, Reserved2;
    }
    [DllImport("libc", SetLastError=true)] private static extern int open(string path, int flags);
    [DllImport("libc", SetLastError=true)] private static extern int fstat(int fd, out Stat info);
    [DllImport("libc", SetLastError=true)] private static extern int dup(int fd);
    [DllImport("libc", SetLastError=true)] private static extern int close(int fd);
    private int fd = -1;
    public string Path { get; private set; }
    private Stat ReadStat() {
        Stat info;
        if (fd < 0 || fstat(fd, out info) != 0) throw new IOException("cache handle stat failed");
        return info;
    }
    public DsrLinuxCacheTestEntry(string path, bool directory) {
        Path = path;
        fd = open(path, 0x20000 | 0x800 | (directory ? 0x10000 : 0));
        if (fd < 0) throw new IOException("linked, missing, or inaccessible cache entry: " + path);
        try {
            uint mode = ReadStat().Mode & 0xF000;
            if (mode != (directory ? 0x4000 : 0x8000))
                throw new IOException("linked or special cache entry: " + path);
        } catch { Dispose(); throw; }
    }
    public string GetIdentity() {
        Stat s = ReadStat();
        return String.Join(":", s.Dev, s.Ino, s.Mode, s.Size, s.Mtime, s.MtimeNs,
                           s.Ctime, s.CtimeNs, s.Nlink);
    }
    public ulong LinkCount { get { return ReadStat().Nlink; } }
    public string FileId { get { Stat s = ReadStat(); return s.Dev + ":" + s.Ino; } }
    public long Length { get { return ReadStat().Size; } }
    public bool IsDirectory { get { return (ReadStat().Mode & 0xF000) == 0x4000; } }
    public FileStream OpenRead() {
        int copy = dup(fd);
        if (copy < 0) throw new IOException("cache handle duplication failed");
        var stream = new FileStream(new SafeFileHandle((IntPtr)copy, true), FileAccess.Read);
        stream.Position = 0;
        return stream;
    }
    public void Dispose() { if (fd >= 0) { close(fd); fd = -1; } }
}
'@
    function Open-DsrCacheEntry {
        param([string]$Path, [bool]$Directory)
        return [DsrLinuxCacheTestEntry]::new($Path, $Directory)
    }
    function Get-DsrCacheFullPath {
        param([string]$Path)
        if (-not $Path.StartsWith('/') -or $Path.Contains([char]0)) {
            throw 'Portable cache paths must be absolute Unix paths'
        }
        foreach ($part in $Path.Trim('/').Split('/')) {
            if ($part -eq '.' -or $part -eq '..') { throw 'Ambiguous portable cache path component' }
        }
        if ($Path -eq '/') { return '/' }
        return $Path.TrimEnd('/')
    }
    function Open-DsrCachePathGuard {
        param([string]$Path)
        $handles = [Collections.Generic.List[object]]::new()
        try {
            $current = '/'
            $handles.Add((Open-DsrCacheEntry $current -Directory $true))
            foreach ($part in $Path.Trim('/').Split('/')) {
                if (-not $part) { continue }
                $current = $current.TrimEnd('/') + '/' + $part
                $handles.Add((Open-DsrCacheEntry $current -Directory $true))
            }
            return ,$handles
        } catch {
            foreach ($handle in $handles) { $handle.Dispose() }
            throw
        }
    }
    function Get-DsrCargoCmdPath {
        param($Environment)
        # A stable inert path is bound into the receipt. No CMD is claimed on
        # Linux: Invoke-DsrCargoCommand below uses the explicit process adapter.
        return '/bin/false'
    }
    function Invoke-DsrCargoCommand {
        param($Context, [string]$Command, [bool]$CaptureOutput=$false)
        $tokens = @(Split-DsrCargoLiteralCommand -Command $Command)
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $tokens[0].Value
        $info.WorkingDirectory = $Context.SourceRoot
        $info.UseShellExecute = $false
        for ($index = 1; $index -lt $tokens.Count; $index++) { $info.ArgumentList.Add($tokens[$index].Value) }
        $info.Environment.Clear()
        foreach ($name in $Context.Environment.Keys) { $info.Environment[$name] = $Context.Environment[$name] }
        $info.RedirectStandardOutput = $CaptureOutput
        $info.RedirectStandardError = $CaptureOutput
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        try {
            $null = $process.Start()
            if ($CaptureOutput) {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
            }
            if (-not $process.WaitForExit(120000)) { $process.Kill($true); throw 'Portable Cargo process timed out' }
            $out = ''; $err = ''
            if ($CaptureOutput) { $out = $stdout.GetAwaiter().GetResult(); $err = $stderr.GetAwaiter().GetResult() }
            return [pscustomobject]@{ExitCode=$process.ExitCode; Stdout=$out; Stderr=$err}
        } finally { $process.Dispose() }
    }
}

if ($InitializeBackendOnly) { return }

if ($GeneratedScriptPath) {
    if ($InjectMalformedMetadata) {
        # Only the metadata result is malformed. Context construction and all
        # executable identity probes still run the genuine installed tools.
        $cargoCommandBeforeMetadataFault=(Get-Command Invoke-DsrCargoCommand -CommandType Function).ScriptBlock
        $metadataFaultCommand={
            param($Context,[string]$Command,[bool]$CaptureOutput=$false)
            if ($Context.PSObject.Properties['MetadataCommand'] -and $Command -ceq $Context.MetadataCommand) {
                [Console]::Error.WriteLine('DSR_TEST_INJECTED_ZERO_EXIT_METADATA')
                return [pscustomobject]@{ExitCode=0; Stdout='invalid-metadata'; Stderr=''}
            }
            return & $cargoCommandBeforeMetadataFault -Context $Context -Command $Command -CaptureOutput $CaptureOutput
        }.GetNewClosure()
        Set-Item -LiteralPath Function:Invoke-DsrCargoCommand -Value $metadataFaultCommand
    }
    & $GeneratedScriptPath
    exit $LASTEXITCODE
}

function Assert-Check {
    param([string]$Label, [bool]$Condition)
    if (-not $Condition) { throw "FAIL $Label" }
    $script:Checks++
    Write-Output "PASS $Label"
}

function Assert-Refused {
    param([string]$Label, [scriptblock]$Action, [string]$MessagePattern)
    $failure = $null
    try { $null = & $Action } catch { $failure = $_ }
    Assert-Check $Label ($null -ne $failure)
    if ($MessagePattern -and $failure.Exception.Message -notmatch $MessagePattern) {
        throw "Wrong refusal for ${Label}: $($failure.Exception.Message)"
    }
}

function Write-FixtureText {
    param([string]$Path, [string]$Value)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Value, $script:Utf8)
}

function Get-Digest {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-Program {
    param([string]$Executable, [string[]]$Arguments, [switch]$ExpectFailure)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $null = $process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(90000)) {
        $process.Kill($true)
        throw "Fixture process timed out: $Executable"
    }
    $result = [pscustomobject]@{
        Code = $process.ExitCode
        Out = $stdout.GetAwaiter().GetResult()
        Err = $stderr.GetAwaiter().GetResult()
    }
    $process.Dispose()
    if (-not $ExpectFailure -and $result.Code -ne 0) {
        throw "Fixture command failed: $Executable $($Arguments -join ' ')`n$($result.Err)"
    }
    return $result
}

function Invoke-GeneratedCacheProgram {
    param([ValidateSet('metadata','ordinary','finish')][string]$Operation, [string]$Path,
        [string]$Argument, [switch]$ExpectFailure, [switch]$InjectMalformedMetadata)
    $generator = @'
source "$1" || exit $?
shift
# Load the production backend in the child PowerShell harness; suppress only
# its repeated transport embedding, retaining all orchestration code verbatim.
_act_windows_cargo_cache_runtime() { :; }
_act_windows_cargo_context_runtime() { :; }
_act_windows_cargo_sources_runtime() { :; }
case "$1" in
metadata)
    _act_windows_private_cargo_home_script "$2" "$3" || exit $?
    _act_windows_cargo_metadata_body 'cargo build' '' || exit $?
    printf '%s\n' '$dsrPrivateSummary | ConvertTo-Json -Compress -Depth 100; exit 0'
    ;;
ordinary|finish)
    exec 3>&1
    # Capture the actual generated finish program before SSH transport. The
    # distinguished return code prevents any host access or simulated summary.
    _act_windows_cache_command() { printf '%s\n' "$3" >&3; return 75; }
    if [[ "$1" == ordinary ]]; then
        _act_prepare_windows_nonstrict_cargo_home fixture-host "$2" "$2/dsr-build-ordinary" "$2/dsr-build-ordinary/c"
    else
        _act_finish_windows_private_cargo_home fixture-host "$2" "$3"
    fi
    result=$?
    [[ "$result" -eq 75 ]] || exit 1
    ;;
esac
'@
    $module = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $BackendPath) 'act_runner.sh')).Path.Replace('\','/')
    $generatorPath = if ($script:WindowsHost) { $Path.Replace('\','/') } else { 'C:/dsr-cache-fixture' }
    $generated = Invoke-Program $script:BashExecutable @('-c', $generator, '_', $module, $Operation, $generatorPath, $Argument)
    $body = $generated.Out
    if (-not $script:WindowsHost) {
        # The generator accepts Windows paths only. Map its one fixture root
        # literal for Linux engine validation; Windows executes its exact text.
        $body = $body.Replace('C:/dsr-cache-fixture', $Path)
    }
    $programPath = Join-Path $script:Work ('generated-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    Write-FixtureText $programPath $body
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath,
        '-BackendPath', (Resolve-Path -LiteralPath $BackendPath).Path, '-GeneratedScriptPath', $programPath)
    if ($PortableStorageSemantics) { $arguments += '-PortableStorageSemantics' }
    if ($InjectMalformedMetadata) { $arguments += '-InjectMalformedMetadata' }
    return Invoke-Program ([Environment]::ProcessPath) $arguments -ExpectFailure:$ExpectFailure
}

# libgit2 reserves a pack-lock suffix below each .git root before opening it.
# Keep the fixture prefix short like production's dsr-build-<12hex>/{s,c}; the
# profile's Temp path already consumes part of that native Windows path budget.
$script:Work = Join-Path ([IO.Path]::GetTempPath()) ('dsr-cache-' + [Guid]::NewGuid().ToString('N').Substring(0,12))
$null = [IO.Directory]::CreateDirectory($script:Work)
Write-Output "Retained fixtures: $script:Work"

function New-CacheFixture {
    param([string]$Name)
    $caseRoot = Join-Path $script:Work $Name
    $ambient = Join-Path $caseRoot 'ambient cargo'
    $private = Join-Path $caseRoot 'private cargo'
    Write-FixtureText (Join-Path $ambient 'registry/src/example/probe-1.0.0/src/lib.rs') 'pub fn answer() -> u32 { 42 }'
    Write-FixtureText (Join-Path $ambient 'registry/cache/example/probe-1.0.0.crate') "cached archive`n"
    Write-FixtureText (Join-Path $ambient 'git/checkouts/probe/revision/build.rs') 'fn main() {}'
    $null = [IO.Directory]::CreateDirectory((Join-Path $ambient 'registry/index/empty'))
    Write-FixtureText (Join-Path $ambient 'config.toml') '[build]'
    Write-FixtureText (Join-Path $ambient 'credentials.toml') 'DO-NOT-COPY'
    Write-FixtureText (Join-Path $ambient 'bin/cargo.exe') 'DO-NOT-COPY'
    return [pscustomobject]@{ Root = $caseRoot; Ambient = $ambient; Private = $private }
}

$f = New-CacheFixture 'snapshot'
$seed = Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second $f.Private
Assert-Check 'snapshot records copied cache payloads' ($seed.mode -eq 'private-copy' -and $seed.file_count -eq 3)
Assert-Check 'both cache types survive as plain directories' (
    ($seed.caches -join ',') -eq 'git,registry' -and
    (Test-Path -LiteralPath (Join-Path $f.Private 'registry/index/empty') -PathType Container))
Assert-Check 'configuration credentials and executable shims are not imported' (
    (@(Get-ChildItem -LiteralPath $f.Private -Force | Sort-Object Name | ForEach-Object Name) -join ',') -eq '.dsr-cache-seed.json,git,registry')
Assert-Check 'receipt hash binds the exact durable JSON bytes' ((Get-Digest $seed.receipt_path) -eq $seed.receipt_sha256)
$receipt = Get-Content -LiteralPath $seed.receipt_path -Raw | ConvertFrom-Json
Assert-Check 'relative inventory paths use canonical forward slashes' (
    @($receipt.inventory.files | Where-Object { $_.path.Contains('\') }).Count -eq 0)
$verified = Invoke-DsrCargoCache -Operation verify -First $f.Private -Second $seed.receipt_path
Assert-Check 'unmodified snapshot verifies against its receipt' ($verified.receipt_sha256 -eq $seed.receipt_sha256)
Assert-DsrCargoHome -Path $f.Private
Assert-DsrCargoSeed -CargoHome $f.Private -ExpectedSha256 $seed.receipt_sha256
Assert-Check 'retained seed admission accepts authenticated private caches' $true

$relative = 'registry/src/example/probe-1.0.0/src/lib.rs'
$originalFile = Join-Path $f.Ambient $relative
$privateFile = Join-Path $f.Private $relative
$originalEntry = Open-DsrCacheEntry -Path $originalFile -Directory $false
$privateEntry = Open-DsrCacheEntry -Path $privateFile -Directory $false
try {
    Assert-Check 'snapshot files have separate filesystem identities' ($originalEntry.GetIdentity() -ne $privateEntry.GetIdentity())
    Assert-Check 'snapshot files have no shared hardlinks' ($privateEntry.LinkCount -eq 1)
} finally {
    $originalEntry.Dispose()
    $privateEntry.Dispose()
}
Write-FixtureText $originalFile 'ambient operator mutation'
Assert-Check 'ambient in-place writes cannot mutate private bytes' (([IO.File]::ReadAllText($privateFile)) -eq 'pub fn answer() -> u32 { 42 }')
[IO.Directory]::Move($f.Ambient, (Join-Path $f.Root 'retained ambient'))
$null = Invoke-DsrCargoCache -Operation verify -First $f.Private -Second $seed.receipt_path
Assert-Check 'verification survives disappearance of original cache paths' $true
Write-FixtureText $privateFile 'private mutation'
Assert-Refused 'changed private bytes invalidate the retained seed' {
    Invoke-DsrCargoCache -Operation verify -First $f.Private -Second $seed.receipt_path
}
Assert-Refused 'receipt hashes cannot be replaced during seed admission' {
    Assert-DsrCargoSeed -CargoHome $f.Private -ExpectedSha256 ('0' * 64)
}

$f = New-CacheFixture 'resolved'
$seed = Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second $f.Private
Write-FixtureText (Join-Path $f.Private 'registry/cache/example/new.crate') 'new dependency download'
Assert-Refused 'newly resolved files do not silently match the original inventory' {
    Invoke-DsrCargoCache -Operation verify -First $f.Private -Second $seed.receipt_path
}
$finalPath = Join-Path $f.Root 'resolved.json'
$final = Invoke-DsrCargoCache -Operation inventory -First $f.Private -Second $finalPath
Assert-Check 'resolved dependencies receive a separate final inventory' ($final.mode -eq 'inventory' -and $final.file_count -eq 4)
$null = Invoke-DsrCargoCache -Operation verify -First $f.Private -Second $finalPath
Assert-Check 'final inventory verifies downloaded cache bytes' $true
$before = Get-Digest $finalPath
Assert-Refused 'existing receipts cannot be overwritten' {
    Invoke-DsrCargoCache -Operation inventory -First $f.Private -Second $finalPath
}
Assert-Check 'refused receipt replacement preserves its bytes' ((Get-Digest $finalPath) -eq $before)

$f = New-CacheFixture 'cold'
$cold = Invoke-DsrCargoCache -Operation snapshot -First '' -Second $f.Private
Assert-Check 'a cold cache is valid and explicitly empty' ($cold.file_count -eq 0 -and @($cold.caches).Count -eq 0)
$null = Invoke-DsrCargoCache -Operation verify -First $f.Private -Second $cold.receipt_path
Assert-Check 'empty cache inventory can be authenticated' $true
Assert-Check 'empty cache receipts preserve arrays rather than null values' (
    [IO.File]::ReadAllText($cold.receipt_path).Contains('"inventory":{"caches":[],"directories":[],"files":[]}'))
Assert-Refused 'an explicitly missing ambient cache fails closed' {
    Invoke-DsrCargoCache -Operation snapshot -First (Join-Path $f.Root 'missing') -Second (Join-Path $f.Root 'missing-private')
}
Assert-Refused 'relative destination paths are rejected' {
    Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second 'relative-home'
}
Assert-Refused 'overlapping source and destination are rejected' {
    Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second (Join-Path $f.Ambient 'nested')
}
$coldHash = Get-Digest $cold.receipt_path
Assert-Refused 'existing private homes are never replaced' {
    Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second $f.Private
}
Assert-Check 'refused snapshot leaves the admitted seed unchanged' ((Get-Digest $cold.receipt_path) -eq $coldHash)

foreach ($kind in @('schema', 'mode', 'home', 'duplicate')) {
    $text = [IO.File]::ReadAllText($cold.receipt_path)
    if ($kind -eq 'duplicate') {
        $text = '{"schema_version":1,' + $text.Substring(1)
    } else {
        $value = ConvertFrom-Json $text
        if ($kind -eq 'schema') { $value.schema_version = 2 }
        if ($kind -eq 'mode') { $value.kind = 'ambient-junction' }
        if ($kind -eq 'home') { $value.cargo_home += '-different' }
        # Construct canonical but untrusted receipts, so refusal must come from
        # identity/schema validation, not merely malformed JSON formatting.
        $text = (ConvertTo-DsrCacheCanonicalJson $value) + "`n"
    }
    $forged = Join-Path $f.Root ($kind + '.json')
    Write-FixtureText $forged $text
    Assert-Refused "receipt rejects invalid $kind authority" {
        Invoke-DsrCargoCache -Operation verify -First $f.Private -Second $forged
    }
}

foreach ($name in @('config', 'config.toml', 'credentials', 'credentials.toml')) {
    $f = New-CacheFixture ('forbidden-' + $name)
    $null = Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second $f.Private
    Write-FixtureText (Join-Path $f.Private $name) 'ambient authority'
    Assert-Refused "private Cargo home rejects $name" { Assert-DsrCargoHome -Path $f.Private }
}

foreach ($pointer in @('git/db/probe/objects/info/alternates', 'git/db/probe/commondir', 'git/checkouts/probe/revision/.git')) {
    $f = New-CacheFixture ('external-git-' + [Guid]::NewGuid().ToString('N'))
    Write-FixtureText (Join-Path $f.Ambient $pointer) '/outside/object/store'
    Assert-Refused "external Git storage pointer is rejected: $pointer" {
        Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second $f.Private
    } 'Git|storage|reference'
    Assert-Check 'a failed Git cache snapshot publishes no seed receipt' (
        -not (Test-Path -LiteralPath (Join-Path $f.Private '.dsr-cache-seed.json')))
}

$f = New-CacheFixture 'reparse'
$outside = Join-Path $f.Root 'outside'
$null = [IO.Directory]::CreateDirectory($outside)
Write-FixtureText (Join-Path $outside 'secret') 'operator-owned'
$link = Join-Path $f.Ambient 'registry/escape'
$linkKind = if ($script:WindowsHost) { 'Junction' } else { 'SymbolicLink' }
$null = New-Item -ItemType $linkKind -Path $link -Target $outside
Assert-Refused "nested $linkKind cache escapes are rejected" {
    Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second $f.Private
}
Assert-Check 'reparse refusal preserves external target bytes' ([IO.File]::ReadAllText((Join-Path $outside 'secret')) -eq 'operator-owned')
$ambientLink = Join-Path $f.Root 'ambient alias'
$null = New-Item -ItemType $linkKind -Path $ambientLink -Target $f.Ambient
Assert-Refused "top-level $linkKind source roots are rejected" {
    Invoke-DsrCargoCache -Operation snapshot -First $ambientLink -Second (Join-Path $f.Root 'alias-private')
}
$ancestorLink = Join-Path $f.Root 'ancestor alias'
$null = New-Item -ItemType $linkKind -Path $ancestorLink -Target $outside
$null = [IO.Directory]::CreateDirectory((Join-Path $outside 'cache/registry'))
Assert-Refused "a $linkKind ancestor cannot authorize an otherwise plain cache root" {
    Invoke-DsrCargoCache -Operation snapshot -First (Join-Path $ancestorLink 'cache') -Second (Join-Path $f.Root 'ancestor-private')
}

if ($script:WindowsHost) {
    $f = New-CacheFixture 'active-writer'
    $writer = [IO.File]::Open((Join-Path $f.Ambient $relative), [IO.FileMode]::Open,
        [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try {
        Assert-Refused 'a concurrent Windows writer prevents cache admission' {
            Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second $f.Private
        }
    } finally { $writer.Dispose() }
    $directory = Open-DsrCacheEntry -Path $f.Ambient -Directory $true
    try {
        Assert-Refused 'a pinned Windows cache directory cannot be renamed' {
            [IO.Directory]::Move($f.Ambient, (Join-Path $f.Root 'replacement'))
        }
        Assert-Check 'directory custody permits ordinary cache enumeration' (
            (Get-DsrCacheChildren $f.Ambient).Count -gt 0)
        $newChild = Join-Path $f.Ambient 'registry/new-download'
        Write-FixtureText $newChild 'downloaded while the parent is pinned'
        Assert-Check 'directory custody permits new Cargo download files' (
            [IO.File]::ReadAllText($newChild) -ceq 'downloaded while the parent is pinned')
    } finally { $directory.Dispose() }
    Assert-Check 'Windows sharing refusal leaves the original cache intact' (
        Test-Path -LiteralPath (Join-Path $f.Ambient $relative) -PathType Leaf)

    $guards = Open-DsrCachePathGuard (Get-DsrCacheFullPath (Join-Path $f.Ambient 'registry'))
    try {
        Assert-Refused 'a guarded Windows cache ancestor cannot be renamed' {
            [IO.Directory]::Move($f.Ambient, (Join-Path $f.Root 'replacement'))
        }
        Assert-Refused 'the guarded Windows cache leaf cannot be renamed' {
            [IO.Directory]::Move((Join-Path $f.Ambient 'registry'), (Join-Path $f.Ambient 'retained-registry'))
        }
    } finally { foreach ($guard in $guards) { $guard.Dispose() } }
    $releasedDirectory = Join-Path $f.Root 'released-cache'
    [IO.Directory]::Move($f.Ambient, $releasedDirectory)
    Assert-Check 'disposing directory custody permits an ordinary rename' (
        (Test-Path -LiteralPath (Join-Path $releasedDirectory $relative) -PathType Leaf) -and
        -not (Test-Path -LiteralPath $f.Ambient))

    $f = New-CacheFixture 'native-stream-lifetime'
    $lifetimeFile = Join-Path $f.Ambient $relative
    $entry = Open-DsrCacheEntry -Path $lifetimeFile -Directory $false
    try {
        $identity = $entry.GetIdentity()
        $stream = $entry.OpenRead()
        try { Assert-Check 'a duplicated Windows cache handle reads the original file' ($stream.ReadByte() -eq 112) }
        finally { $stream.Dispose() }
        Assert-Check 'closing a cache stream preserves the owning native handle' ($entry.GetIdentity() -ceq $identity)
        Assert-Refused 'the owning Windows handle still blocks writers after stream disposal' {
            $attemptWriter = [IO.File]::Open($lifetimeFile, [IO.FileMode]::Open,
                [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $attemptWriter.Dispose()
        }
        Assert-Refused 'the owning Windows handle still blocks replacement after stream disposal' {
            [IO.File]::Move($lifetimeFile, (Join-Path $f.Root 'retained-renamed-file'))
        }
    } finally { $entry.Dispose() }
    Write-FixtureText $lifetimeFile 'available after custody release'
    Assert-Check 'disposing the owning Windows handle releases write exclusion' (
        [IO.File]::ReadAllText($lifetimeFile) -ceq 'available after custody release')
}

$f = New-CacheFixture 'ambient-hardlink'
$originalFile = Join-Path $f.Ambient $relative
$outsideFile = Join-Path $f.Root 'operator-file'
$null = New-Item -ItemType HardLink -Path $outsideFile -Target $originalFile
$seed = Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second $f.Private
Write-FixtureText $outsideFile 'mutation through ambient hardlink'
Assert-Check 'ambient hardlinks are copied into independent private files' (
    [IO.File]::ReadAllText((Join-Path $f.Private $relative)) -eq 'pub fn answer() -> u32 { 42 }')
$null = Invoke-DsrCargoCache -Operation verify -First $f.Private -Second $seed.receipt_path
Assert-Check 'ambient hardlink mutation does not invalidate a private snapshot' $true

$f = New-CacheFixture 'external-private-hardlink'
$seed = Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second $f.Private
$null = New-Item -ItemType HardLink -Path (Join-Path $f.Root 'outside-private-link') -Target (Join-Path $f.Private $relative)
Assert-Refused 'unchanged bytes shared with an external owner cannot verify' {
    Invoke-DsrCargoCache -Operation verify -First $f.Private -Second $seed.receipt_path
} 'hardlink|private|link'

$f = New-CacheFixture 'hardlink-graft'
$null = Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second $f.Private
$null = New-Item -ItemType HardLink -Path (Join-Path $f.Private 'registry/ambient-graft') -Target (Join-Path $f.Ambient $relative)
Assert-Refused 'final inventory refuses an ambient hardlink graft' {
    Invoke-DsrCargoCache -Operation inventory -First $f.Private -Second (Join-Path $f.Root 'grafted.json')
} 'hardlink|private|link'

$f = New-CacheFixture 'internal-hardlink'
$null = Invoke-DsrCargoCache -Operation snapshot -First $f.Ambient -Second $f.Private
$null = New-Item -ItemType HardLink -Path (Join-Path $f.Private 'git/internal-link') -Target (Join-Path $f.Private $relative)
$final = Invoke-DsrCargoCache -Operation inventory -First $f.Private -Second (Join-Path $f.Root 'internal.json')
Assert-Check 'hardlinks entirely inside private cache trees remain usable' ($final.file_count -eq 4)
$null = Invoke-DsrCargoCache -Operation verify -First $f.Private -Second $final.receipt_path
Assert-Check 'private Git-style internal hardlinks verify' $true

# A genuine Git dependency is warmed once, then both upstream and ambient cache
# paths disappear. Cargo must compile from a fresh private copy while offline.
$cargo = (Get-Command cargo -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
if ($BashPath) {
    $script:BashExecutable = $BashPath
} elseif ($script:WindowsHost) {
    $script:BashExecutable = Join-Path (Split-Path -Parent (Split-Path -Parent $git)) 'bin/bash.exe'
    if (-not (Test-Path -LiteralPath $script:BashExecutable -PathType Leaf)) {
        throw 'Git Bash is required for generated Windows orchestration tests; pass -BashPath explicitly.'
    }
} else {
    $script:BashExecutable = (Get-Command bash -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}
$cargoCase = Join-Path $script:Work 'real-cargo'
$ambient = Join-Path $cargoCase 'ambient cargo'
$dependency = Join-Path $cargoCase 'dependency'
$source = Join-Path $cargoCase 'source'
$seedHome = Join-Path $cargoCase 'retained-seed'
$buildHome = Join-Path $cargoCase 'private-build'
$targetDirectory = Join-Path $cargoCase 'target'
$null = [IO.Directory]::CreateDirectory($ambient)
Write-FixtureText (Join-Path $dependency 'Cargo.toml') "[package]`nname=`"dsr_cache_dependency`"`nversion=`"1.0.0`"`nedition=`"2021`"`n"
Write-FixtureText (Join-Path $dependency 'src/lib.rs') 'pub fn answer() -> u32 { 42 }'
$null = Invoke-Program $git @('-C', $dependency, 'init', '-q')
$null = Invoke-Program $git @('-C', $dependency, 'add', '.')
$null = Invoke-Program $git @('-C', $dependency, '-c', 'user.name=DSR Cache Test', '-c', 'user.email=dsr@example.invalid', 'commit', '-qm', 'fixture')
$revision = (Invoke-Program $git @('-C', $dependency, 'rev-parse', 'HEAD')).Out.Trim()
$dependencyUri = ([Uri]::new($dependency + [IO.Path]::DirectorySeparatorChar)).AbsoluteUri.TrimEnd('/')
Write-FixtureText (Join-Path $source 'Cargo.toml') (
    "[package]`nname=`"dsr-cache-probe`"`nversion=`"1.0.0`"`nedition=`"2021`"`n" +
    "[dependencies]`ndsr_cache_dependency={git=`"$dependencyUri`",rev=`"$revision`"}`n")
Write-FixtureText (Join-Path $source 'src/main.rs') 'fn main() { println!("{}", dsr_cache_dependency::answer()); }'
$savedEnvironment = @{}
foreach ($name in @('CARGO_HOME', 'CARGO_NET_OFFLINE', 'CARGO_TARGET_DIR', 'RUSTFLAGS', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER', 'RCH_DISABLED', 'RCH_CARGO_WRAPPER_BYPASS')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
}
try {
    $env:RCH_DISABLED = '1'
    $env:RCH_CARGO_WRAPPER_BYPASS = '1'
    $env:CARGO_HOME = $ambient
    $manifest = Join-Path $source 'Cargo.toml'
    $null = Invoke-Program $cargo @('metadata', '--format-version', '1', '--manifest-path', $manifest)
    Assert-Check 'real Cargo resolves a pinned local Git dependency' (Test-Path -LiteralPath (Join-Path $source 'Cargo.lock'))
    Write-FixtureText (Join-Path $ambient 'config.toml') "[build]`nrustc-wrapper=`"forbidden-ambient-wrapper`"`n"
    Write-FixtureText (Join-Path $ambient 'credentials.toml') 'DO-NOT-COPY'
    $seed = Invoke-DsrCargoCache -Operation snapshot -First $ambient -Second $seedHome
    $seedHash = Get-Digest $seed.receipt_path
    Assert-Check 'real Cargo Git cache can be privately snapshotted' ($seed.file_count -gt 0)
    Assert-DsrCargoSeed -CargoHome $seedHome -ExpectedSha256 $seed.receipt_sha256
    $null = Invoke-DsrCargoCache -Operation snapshot -First $seedHome -Second $buildHome
    [IO.Directory]::Move($ambient, (Join-Path $cargoCase 'retained ambient'))
    [IO.Directory]::Move($dependency, (Join-Path $cargoCase 'retained dependency'))
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $cargoCase 'retained ambient/git/checkouts') -Filter lib.rs -Recurse -File) {
        Write-FixtureText $file.FullName 'compile_error!("ambient cache mutation escaped isolation");'
    }
    $env:CARGO_HOME = $buildHome
    $env:CARGO_NET_OFFLINE = 'true'
    $metadata = Invoke-Program $cargo @('metadata', '--locked', '--offline', '--format-version', '1', '--manifest-path', $manifest)
    $package = @((ConvertFrom-Json $metadata.Out).packages | Where-Object name -eq 'dsr_cache_dependency')
    Assert-Check 'offline metadata resolves dependencies inside the private copy' (
        $package.Count -eq 1 -and $package[0].manifest_path.StartsWith($buildHome, [StringComparison]::OrdinalIgnoreCase))
    $null = Invoke-Program $cargo @('build', '--locked', '--offline', '--manifest-path', $manifest, '--target-dir', $targetDirectory)
    $binaryName = if ($script:WindowsHost) { 'dsr-cache-probe.exe' } else { 'dsr-cache-probe' }
    $answer = Invoke-Program (Join-Path $targetDirectory ('debug/' + $binaryName)) @()
    Assert-Check 'real offline compilation survives ambient mutation and upstream disappearance' ($answer.Out.Trim() -eq '42')
    Assert-Check 'metadata and compilation leave retained seed receipts unchanged' ((Get-Digest $seed.receipt_path) -eq $seedHash)
    Assert-DsrCargoSeed -CargoHome $seedHome -ExpectedSha256 $seed.receipt_sha256
    Assert-Check 'the retained seed remains authentic after real compilation' $true
    $resolved = Invoke-DsrCargoCache -Operation inventory -First $buildHome -Second (Join-Path $cargoCase 'resolved-build.json')
    $null = Invoke-DsrCargoCache -Operation verify -First $buildHome -Second $resolved.receipt_path
    Assert-Check 'actual Cargo output caches can be sealed and verified' ($resolved.file_count -gt 0)

    $coldHome = Join-Path $cargoCase 'cold-private'
    $cold = Invoke-DsrCargoCache -Operation snapshot -First '' -Second $coldHome
    $env:CARGO_HOME = $coldHome
    $failed = Invoke-Program $cargo @('metadata', '--locked', '--offline', '--format-version', '1', '--manifest-path', $manifest) -ExpectFailure
    Assert-Check 'cold offline cache failure is explicit and cannot use vanished ambient state' (
        $failed.Code -ne 0 -and $failed.Err -match 'offline')
    $retryHome = Join-Path $cargoCase 'retry-private'
    $null = Invoke-DsrCargoCache -Operation snapshot -First $seedHome -Second $retryHome
    $env:CARGO_HOME = $retryHome
    $null = Invoke-Program $cargo @('metadata', '--locked', '--offline', '--format-version', '1', '--manifest-path', $manifest)
    Assert-Check 'a fresh private retry succeeds without replacing the admitted seed' ((Get-Digest $seed.receipt_path) -eq $seedHash)

    $emptyAmbient = Join-Path $cargoCase 'orchestrator-empty-ambient'
    $null = [IO.Directory]::CreateDirectory($emptyAmbient)
    $canonicalSeed = Join-Path $cargoCase '.cargo-home'
    $env:CARGO_HOME = $emptyAmbient
    $failed = Invoke-GeneratedCacheProgram metadata $source 'metadata-cold' -ExpectFailure
    if ($failed.Code -eq 0 -or $failed.Err -notmatch 'offline') {
        [Console]::Error.WriteLine('Generated cold metadata exit: ' + $failed.Code)
        foreach ($field in @('Out','Err')) {
            $diagnostic = [string]$failed.$field
            [Console]::Error.WriteLine($field + ': ' + $diagnostic.Substring(0,[Math]::Min(4096,$diagnostic.Length)))
        }
    }
    Assert-Check 'generated strict metadata refuses unresolved cold dependencies' ($failed.Code -ne 0 -and $failed.Err -match 'offline')
    Assert-Check 'failed strict metadata never publishes the canonical retained seed' (-not (Test-Path -LiteralPath $canonicalSeed))
    $warmAmbient = Join-Path $cargoCase 'orchestrator-refilled-ambient'
    $null = Invoke-DsrCargoCache -Operation snapshot -First $seedHome -Second $warmAmbient
    $env:CARGO_HOME = $warmAmbient
    $prepared = Invoke-GeneratedCacheProgram metadata $source 'metadata-refilled'
    $preparedSummary = ConvertFrom-Json $prepared.Out
    Assert-Check 'generated strict metadata succeeds after ambient refill' ($preparedSummary.mode -eq 'private-copy')
    $canonicalReceipt = Join-Path $canonicalSeed '.dsr-cache-seed.json'
    $canonicalHash = Get-Digest $canonicalReceipt
    $null = Invoke-DsrCargoCache -Operation verify -First $canonicalSeed -Second $canonicalReceipt
    Assert-Check 'only successful metadata publishes a fully verifiable canonical seed' $true
    $env:CARGO_HOME = Join-Path $cargoCase 'missing-ambient'
    $retry = Invoke-GeneratedCacheProgram metadata $source 'metadata-retry'
    $retrySummary = ConvertFrom-Json $retry.Out
    Assert-Check 'generated metadata retries have distinct private homes' ($retrySummary.cargo_home -ne $preparedSummary.cargo_home)
    Assert-Check 'generated metadata reuses the admitted seed after ambient disappearance' ((Get-Digest $canonicalReceipt) -eq $canonicalHash)
    $completed = Invoke-GeneratedCacheProgram finish $retrySummary.cargo_home $retrySummary.receipt_sha256
    $completedSummary = ConvertFrom-Json $completed.Out
    Assert-Check 'generated finish seals the actual attempt cache' (
        $completedSummary.mode -eq 'inventory' -and $completedSummary.receipt_path -eq ($retrySummary.cargo_home + '.final.json'))
    $null = Invoke-DsrCargoCache -Operation verify -First $retrySummary.cargo_home -Second $completedSummary.receipt_path
    Assert-Check 'generated final receipt independently verifies' $true
    Write-FixtureText (Join-Path $preparedSummary.cargo_home 'config.toml') '[build]'
    $failed = Invoke-GeneratedCacheProgram finish $preparedSummary.cargo_home $preparedSummary.receipt_sha256 -ExpectFailure
    Assert-Check 'generated finish refuses injected Cargo configuration before collection' ($failed.Code -ne 0 -and $failed.Err -match 'configuration|credentials')
    $canonicalEntry = Get-ChildItem -LiteralPath (Join-Path $canonicalSeed 'git/checkouts') -Filter lib.rs -File -Recurse | Select-Object -First 1
    Write-FixtureText $canonicalEntry.FullName 'compile_error!("retained seed was changed");'
    $failed = Invoke-GeneratedCacheProgram metadata $source 'metadata-drift' -ExpectFailure
    Assert-Check 'generated strict resume refuses changed retained seed bytes' ($failed.Code -ne 0 -and $failed.Err -match 'inventory|cache')

    # A malformed successful command must never admit a seed. This one case
    # substitutes only the metadata result after genuine toolchain probes;
    # every compilation continues to use actual Cargo and the Rust compiler.
    $malformedSource = Join-Path $cargoCase 'malformed-metadata/source'
    Write-FixtureText (Join-Path $malformedSource 'Cargo.toml') ([IO.File]::ReadAllText($manifest))
    $env:CARGO_HOME = $seedHome
    $failed = Invoke-GeneratedCacheProgram metadata $malformedSource 'metadata-garbage' -ExpectFailure -InjectMalformedMetadata
    Assert-Check 'command boundary: zero-exit malformed Cargo metadata is refused' (
        $failed.Code -ne 0 -and $failed.Err -match 'metadata|JSON' -and $failed.Err -match 'DSR_TEST_INJECTED_ZERO_EXIT_METADATA')
    Assert-Check 'command boundary: malformed metadata cannot admit a retained seed' (
        -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $malformedSource) '.cargo-home')))

    $ordinaryRoot = Join-Path $cargoCase 'ordinary'
    $null = [IO.Directory]::CreateDirectory($ordinaryRoot)
    Write-FixtureText (Join-Path $seedHome 'config.toml') "[build]`nrustc-wrapper=`"forbidden-ambient-wrapper`"`n"
    $env:CARGO_HOME = $seedHome
    $ordinary = Invoke-GeneratedCacheProgram ordinary $ordinaryRoot ''
    $ordinarySummary = ConvertFrom-Json $ordinary.Out
    Assert-Check 'generated ordinary preparation creates a private cache in its build stage' (
        $ordinarySummary.mode -eq 'private-copy' -and $ordinarySummary.cargo_home.EndsWith('/dsr-build-ordinary/c'))
    Assert-Check 'generated ordinary preparation omits ambient compiler configuration' (
        -not (Test-Path -LiteralPath (Join-Path $ordinarySummary.cargo_home 'config.toml')))
    [IO.Directory]::Move($seedHome, (Join-Path $cargoCase 'retained ordinary ambient'))
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $cargoCase 'retained ordinary ambient/git/checkouts') -Filter lib.rs -Recurse -File) {
        Write-FixtureText $file.FullName 'compile_error!("ordinary cache shares ambient bytes");'
    }
    $env:CARGO_HOME = $ordinarySummary.cargo_home
    $ordinaryTarget = Join-Path $cargoCase 'ordinary-target'
    $null = Invoke-Program $cargo @('build', '--locked', '--offline', '--manifest-path', $manifest, '--target-dir', $ordinaryTarget)
    $answer = Invoke-Program (Join-Path $ordinaryTarget ('debug/' + $binaryName)) @()
    Assert-Check 'real ordinary offline build survives disappearance and mutation of its ambient seed' ($answer.Out.Trim() -eq '42')
    $ordinaryFinished = Invoke-GeneratedCacheProgram finish $ordinarySummary.cargo_home $ordinarySummary.receipt_sha256
    $ordinaryFinal = ConvertFrom-Json $ordinaryFinished.Out
    $null = Invoke-DsrCargoCache -Operation verify -First $ordinarySummary.cargo_home -Second $ordinaryFinal.receipt_path
    Assert-Check 'ordinary cache collection has an independently verified final inventory' ($ordinaryFinal.mode -eq 'inventory')
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
    }
}

$proof = if ($script:WindowsHost) { 'native Windows / NTFS and real Cargo' } else { 'portable PowerShell semantics / Linux handles and real Cargo' }
Write-Output "$script:Checks checks passed ($proof)."
