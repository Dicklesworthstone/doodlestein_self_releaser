# Genuine Cargo registry/Git dependency source authentication. No network
# service is required: an in-process sparse registry serves a real .crate.
# Fixtures remain inspectable. The explicit Linux adapter proves PowerShell,
# Cargo, hashes and admission logic; it does not claim Windows/NTFS evidence.
[CmdletBinding()]
param([switch]$PortableStorageSemantics, [string]$BashPath, [switch]$SubmodulesOnly,
    [string]$BackendPath=(Join-Path $PSScriptRoot '../../src/cargo_sources_windows.ps1'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Checks = 0
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:WindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$sourceBackendFile = $BackendPath
$sourceModuleRoot = (Resolve-Path (Split-Path -Parent $sourceBackendFile)).Path
$sourceCacheHarness = Join-Path $PSScriptRoot 'test_cargo_cache_windows.ps1'
$sourceBashPath = $BashPath
. $sourceCacheHarness -BackendPath (Join-Path $sourceModuleRoot 'cargo_cache_windows.ps1') -PortableStorageSemantics:$PortableStorageSemantics -InitializeBackendOnly
. $sourceBackendFile
Initialize-DsrCargoSourcesNative

function Assert-Check {
    param([string]$Label, [bool]$Condition)
    if (-not $Condition) { throw ('FAIL ' + $Label) }
    $script:Checks++; Write-Output ('PASS ' + $Label)
}

function Assert-Refused {
    param([string]$Label, [scriptblock]$Action, [string]$Pattern)
    $failure = $null
    try { $null = & $Action } catch { $failure = $_ }
    Assert-Check $Label ($null -ne $failure)
    if ($Pattern -and $failure.Exception.Message -notmatch $Pattern) { throw ('Wrong refusal for ' + $Label + ': ' + $failure.Exception.Message) }
}

function Assert-GeneratedSourceRefusal {
    param([string]$Label, $Result, [string]$Pattern)
    $condition = $Result.Code -ne 0 -and $Result.Err -match $Pattern
    if (-not $condition) {
        [Console]::Error.WriteLine('Unexpected generated source result for ' + $Label + ': exit=' + $Result.Code)
        [Console]::Error.WriteLine('Bash=' + $sourceBashPath + '; PowerShell=' + [Environment]::ProcessPath + '; modules=' + $sourceModuleRoot)
        foreach ($field in @('Out','Err')) {
            $message = [string]$Result[$field]
            if ($message.Length -gt 4096) { $message = $message.Substring(0,4096) + '[truncated]' }
            [Console]::Error.WriteLine($field + ': ' + $message)
        }
    }
    Assert-Check $Label $condition
}

function Write-FixtureText {
    param([string]$Path, [string]$Value)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,$Value,$script:Utf8)
}

function New-GeneratedSourceFixture {
    param([string]$Name, [string]$FromWorkspace=$workspace)
    $parent = $root + '/' + $Name; $source = $parent + '/source'
    foreach ($relative in @('Cargo.toml','Cargo.lock','.cargo/config.toml','src/main.rs')) {
        Write-FixtureText ($source + '/' + $relative) ([IO.File]::ReadAllText($FromWorkspace + '/' + $relative))
    }
    $marker = $parent + '/compiler-ran'
    Write-FixtureText ($source + '/build.rs') ('fn main() { std::fs::write(r#"' + $marker + '"#, b"compiled").unwrap(); }')
    return @{Parent=$parent; SourceRoot=$source; CompilerMarker=$marker}
}

function Invoke-Program {
    param([string]$Executable, [string[]]$Arguments, [string]$Directory, [switch]$ExpectFailure)
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
    $info.Environment['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
    if ($Directory) { $info.WorkingDirectory = $Directory }
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill($true); throw ('Fixture process timed out: ' + $Executable) }
        $result = @{Code=$process.ExitCode;Out=$stdout.GetAwaiter().GetResult();Err=$stderr.GetAwaiter().GetResult()}
        if (-not $ExpectFailure -and $result.Code -ne 0) { throw ('Fixture command failed: ' + $Executable + ' ' + ($Arguments -join ' ') + "`n" + $result.Err) }
        return $result
    } finally { $process.Dispose() }
}

function Invoke-GeneratedSourceProgram {
    param([ValidateSet('Metadata','Build','Finish')][string]$Operation,
        [string]$SourceRoot, [string]$BuildCommand, [string[]]$ConfiguredEnvironment,
        [string]$Suffix, $Admission, [switch]$ExpectFailure)
    $generator = @'
source "$1" || exit $?
shift
# Only transport embedding is replaced: the child imports these same modules
# before executing the generated production program in its own process.
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
    $sourceArgument = if ($script:WindowsHost) { $SourceRoot.Replace('\','/') } else { 'C:/dsr-auth-source' }
    $homeArgument = if ($null -eq $Admission) { '' }
        elseif ($script:WindowsHost) { $Admission.cargo_home } else { 'C:/dsr-auth-home' }
    $arguments = @('-c',$generator,'_',(Join-Path $sourceModuleRoot 'act_runner.sh').Replace('\','/'),$Operation)
    if ($Operation -eq 'Metadata') { $arguments += @($sourceArgument,$Suffix,$BuildCommand,($ConfiguredEnvironment -join "`n")) }
    elseif ($Operation -eq 'Build') { $arguments += @($sourceArgument,$homeArgument,$BuildCommand,($ConfiguredEnvironment -join "`n"),
        $Admission.cargo_context.fingerprint,$Admission.cargo_context.receipt_sha256,$Admission.receipt_sha256,
        ($Admission.dependency_sources | ConvertTo-Json -Compress -Depth 100)) }
    else { $arguments += @($homeArgument,$Admission.receipt_sha256,$sourceArgument,
        ($Admission.dependency_sources | ConvertTo-Json -Compress -Depth 100),$BuildCommand,($ConfiguredEnvironment -join "`n"),
        ($Admission.cargo_context | ConvertTo-Json -Compress -Depth 100)) }
    $body = (Invoke-Program $sourceBashPath $arguments).Out
    if (-not $script:WindowsHost) {
        # Windows executes the generated text verbatim. The explicit Linux
        # adapter maps only the two platform-specific fixture root literals.
        $body = $body.Replace('C:/dsr-auth-source',$SourceRoot)
        if ($null -ne $Admission) { $body = $body.Replace('C:/dsr-auth-home',$Admission.cargo_home) }
    }
    $programPath = $root + '/generated-' + [Guid]::NewGuid().ToString('N') + '.ps1'
    Write-FixtureText $programPath $body
    $childArguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',$sourceCacheHarness,
        '-BackendPath',(Join-Path $sourceModuleRoot 'cargo_cache_windows.ps1'),'-GeneratedScriptPath',$programPath)
    if ($PortableStorageSemantics) { $childArguments += '-PortableStorageSemantics' }
    return Invoke-Program ([Environment]::ProcessPath) $childArguments -ExpectFailure:$ExpectFailure
}

function Test-DsrLockedGitSubmodules {
    # Cargo/libgit2 constructs these checkouts itself, including the nested
    # self-contained object stores. No fabricated metadata or source receipt
    # substitutes for actual locked resolution, compilation or admission.
    $caseRoot = $root + '/submodules'
    $producers = $caseRoot + '/upstreams'
    $leaf = $producers + '/leaf'; $middle = $producers + '/middle'; $top = $producers + '/top'
    $subWorkspace = $caseRoot + '/workspace'; $subHome = $caseRoot + '/ambient'
    $savedHome = [Environment]::GetEnvironmentVariable('CARGO_HOME')
    $null = [IO.Directory]::CreateDirectory($subHome)
    [Environment]::SetEnvironmentVariable('CARGO_HOME',$subHome)
    try {
        foreach ($repo in @($leaf,$middle,$top)) {
            $null = Invoke-Program $git @('init','--initial-branch=main',$repo)
        }
        Write-FixtureText ($leaf + '/value.rs') "pub const VALUE: u32 = 42;`n"
        $null = Invoke-Program $git @('-C',$leaf,'add','value.rs')
        $null = Invoke-Program $git @('-C',$leaf,'-c','user.name=DSR Fixture','-c','user.email=dsr-fixture@example.invalid','commit','-m','nested source')
        $leafRevision = (Invoke-Program $git @('-C',$leaf,'rev-parse','HEAD')).Out.Trim()
        $leafTree = (Invoke-Program $git @('-C',$leaf,'rev-parse','HEAD^{tree}')).Out.Trim()
        $leafUri = [Uri]::new($leaf).AbsoluteUri
        Write-FixtureText ($middle + '/.gitmodules') ("[submodule `"inner`"]`npath = inner`nurl = $leafUri`n")
        $null = Invoke-Program $git @('-C',$middle,'add','.gitmodules')
        $null = Invoke-Program $git @('-C',$middle,'update-index','--add','--cacheinfo',('160000,' + $leafRevision + ',inner'))
        $null = Invoke-Program $git @('-C',$middle,'-c','user.name=DSR Fixture','-c','user.email=dsr-fixture@example.invalid','commit','-m','parent-pinned leaf')
        $middleRevision = (Invoke-Program $git @('-C',$middle,'rev-parse','HEAD')).Out.Trim()
        $middleTree = (Invoke-Program $git @('-C',$middle,'rev-parse','HEAD^{tree}')).Out.Trim()
        $middleUri = [Uri]::new($middle).AbsoluteUri
        Write-FixtureText ($top + '/Cargo.toml') "[package]`nname=`"source_submodule_dep`"`nversion=`"1.0.0`"`nedition=`"2021`"`n"
        Write-FixtureText ($top + '/src/lib.rs') "include!(`"../vendor/inner/value.rs`");`npub fn answer() -> u32 { VALUE }`n"
        Write-FixtureText ($top + '/.gitmodules') ("[submodule `"vendor`"]`npath = vendor`nurl = $middleUri`n")
        $null = Invoke-Program $git @('-C',$top,'add','Cargo.toml','src/lib.rs','.gitmodules')
        $null = Invoke-Program $git @('-C',$top,'update-index','--add','--cacheinfo',('160000,' + $middleRevision + ',vendor'))
        $null = Invoke-Program $git @('-C',$top,'-c','user.name=DSR Fixture','-c','user.email=dsr-fixture@example.invalid','commit','-m','dependency with nested submodules')
        $topRevision = (Invoke-Program $git @('-C',$top,'rev-parse','HEAD')).Out.Trim()
        $topUri = [Uri]::new($top).AbsoluteUri
        Write-FixtureText ($subWorkspace + '/Cargo.toml') ("[package]`nname=`"submodule_source_app`"`nversion=`"1.0.0`"`nedition=`"2021`"`n" +
            "[dependencies]`nsource_submodule_dep = { git = `"$topUri`", rev = `"$topRevision`" }`n")
        Write-FixtureText ($subWorkspace + '/.cargo/config.toml') ''
        Write-FixtureText ($subWorkspace + '/src/main.rs') "fn main() { println!(`"{}`", source_submodule_dep::answer()); }`n"
        $null = Invoke-Program $cargo @('fetch','--manifest-path',($subWorkspace + '/Cargo.toml')) $subWorkspace
        $metadataPath = $caseRoot + '/metadata.json'
        Write-FixtureText $metadataPath (Invoke-Program $cargo @('metadata','--locked','--offline','--all-features','--format-version','1') $subWorkspace).Out
        $graph = ConvertFrom-Json ([IO.File]::ReadAllText($metadataPath)) -Depth 100
        $package = $graph.packages | Where-Object { $_.name -ceq 'source_submodule_dep' }
        $checkout = ([IO.Path]::GetDirectoryName($package.manifest_path)).Replace('\','/')
        $childRoot = $checkout + '/vendor/inner'; $childAdmin = $childRoot + '/.git'; $childSource = $childRoot + '/value.rs'
        Assert-Check 'real Cargo resolves nested self-contained Git submodule stores' ([IO.Directory]::Exists($checkout + '/vendor/.git') -and [IO.Directory]::Exists($childAdmin))
        $binary = '/debug/submodule_source_app' + $(if ($script:WindowsHost) { '.exe' } else { '' })
        $null = Invoke-Program $cargo @('build','--locked','--offline','-j1','--target-dir',($caseRoot + '/target-clean')) $subWorkspace
        Assert-Check 'genuine offline compilation consumes the parent-pinned nested source' ((Invoke-Program ($caseRoot + '/target-clean' + $binary) @()).Out.Trim() -ceq '42')
        $arguments = @{MetadataPath=$metadataPath;ReceiptPath=($caseRoot + '/sources.json');Lockfile=($subWorkspace + '/Cargo.lock');CargoHome=$subHome;SourceRoot=$subWorkspace}
        $summary = Invoke-DsrCargoSources -Operation capture @arguments
        $evidence = (Read-DsrCargoReceipt $arguments.ReceiptPath).value
        $proof = @($evidence.authentication.packages)[0]
        Assert-Check 'submodule proof retains both exact parent-pinned commits and trees' ($summary.authentication.locked_git_packages -eq 1 -and
            $proof.commit -ceq $topRevision -and @($proof.submodules).Count -eq 1 -and $proof.submodules[0].path -ceq 'vendor' -and
            $proof.submodules[0].commit -ceq $middleRevision -and $proof.submodules[0].tree -ceq $middleTree -and
            @($proof.submodules[0].submodules).Count -eq 1 -and $proof.submodules[0].submodules[0].path -ceq 'inner' -and
            $proof.submodules[0].submodules[0].commit -ceq $leafRevision -and $proof.submodules[0].submodules[0].tree -ceq $leafTree)
        $null = Invoke-DsrCargoSources -Operation verify -ExpectedSha256 $summary.sha256 @arguments
        Assert-Check 'independent verification accepts unchanged nested Git source evidence' $true
        $childHead = $childAdmin + '/HEAD'; $originalHead = [IO.File]::ReadAllText($childHead)
        Write-FixtureText $childHead (('f' * 40) + "`n")
        try {
            $headArguments = $arguments.Clone(); $headArguments.ReceiptPath = $caseRoot + '/changed-head-sources.json'
            $headSummary = Invoke-DsrCargoSources -Operation capture @headArguments
            $headProof = @((Read-DsrCargoReceipt $headArguments.ReceiptPath).value.authentication.packages)[0]
            Assert-Check 'mutable child HEAD cannot replace parent-gitlink authority' ($headSummary.authentication.locked_git_packages -eq 1 -and
                $headProof.submodules[0].submodules[0].commit -ceq $leafRevision)
        } finally { Write-FixtureText $childHead $originalHead }
        $bad = $arguments.Clone(); $bad.ReceiptPath = $caseRoot + '/refused-sources.json'
        $original = [IO.File]::ReadAllText($childSource)
        Write-FixtureText $childSource "pub const VALUE: u32 = 43;`n"
        $null = Invoke-Program $cargo @('build','--locked','--offline','-j1','--target-dir',($caseRoot + '/target-poisoned')) $subWorkspace
        Assert-Check 'nested source poison changes an actual ungated Cargo executable' ((Invoke-Program ($caseRoot + '/target-poisoned' + $binary) @()).Out.Trim() -ceq '43')
        Assert-Refused 'nested source poison fails independent verification' { Invoke-DsrCargoSources -Operation verify -ExpectedSha256 $summary.sha256 @arguments } 'differ from locked content'
        Assert-Refused 'fresh receipt cannot authorize pre-existing nested source poison' { Invoke-DsrCargoSources -Operation capture @bad } 'differ from locked content'
        Write-FixtureText $childSource $original

        # A fresh generated admission must refuse poisoned selected checkouts
        # without publishing a canonical seed or entering project compilation.
        $failedFixture = New-GeneratedSourceFixture 'submodule-poisoned-admission' -FromWorkspace $subWorkspace
        $buildCommand = 'cargo build --locked --offline -j1'
        $failedConfigured = @('CARGO_TARGET_DIR=' + $failedFixture.Parent + '/target')
        if ($env:RUSTUP_HOME) { $failedConfigured += 'RUSTUP_HOME=' + $env:RUSTUP_HOME }
        Write-FixtureText $childSource "pub const VALUE: u32 = 43;`n"
        $failedAdmission = Invoke-GeneratedSourceProgram -Operation Metadata -SourceRoot $failedFixture.SourceRoot -BuildCommand $buildCommand `
            -ConfiguredEnvironment $failedConfigured -Suffix poisoned-submodule -ExpectFailure
        Assert-GeneratedSourceRefusal 'generated metadata rejects poisoned selected submodule content' $failedAdmission 'differ from locked content'
        Assert-Check 'failed submodule admission publishes no seed or compiler marker' (-not [IO.Directory]::Exists($failedFixture.Parent + '/.cargo-home') -and
            -not [IO.File]::Exists($failedFixture.CompilerMarker) -and
            -not [IO.File]::Exists($failedFixture.Parent + '/.cargo-home-poisoned-submodule/.dsr-cargo-sources.json'))
        Write-FixtureText $childSource $original

        $retainedAdmin = $caseRoot + '/retained-child-admin'
        [IO.Directory]::Move($childAdmin,$retainedAdmin)
        try {
            Assert-Refused 'missing nested Git administration cannot inherit parent authority' { Invoke-DsrCargoSources -Operation capture @bad }
            Write-FixtureText $childAdmin ('gitdir: ' + $retainedAdmin)
            Assert-Refused 'external nested gitdir pointer is refused' { Invoke-DsrCargoSources -Operation capture @bad } 'linked|special|Git|directory|cache entry'
            [IO.File]::Move($childAdmin,($caseRoot + '/retained-gitdir-pointer'))
            $null = Invoke-Program $git @('init','--initial-branch=main',$childRoot)
            Assert-Refused 'unrelated child object store cannot prove the parent-pinned commit' { Invoke-DsrCargoSources -Operation capture @bad } 'Missing|missing|wrong-type|Git object'
            [IO.Directory]::Move($childAdmin,($caseRoot + '/retained-unrelated-child-admin'))
        } finally { [IO.Directory]::Move($retainedAdmin,$childAdmin) }
        foreach ($pointer in @('commondir','objects/info/alternates','objects/info/http-alternates')) {
            $path = $childAdmin + '/' + $pointer
            Write-FixtureText $path ''
            Assert-Refused ('empty nested external storage pointer is refused: ' + $pointer) { Invoke-DsrCargoSources -Operation capture @bad } 'External Git object storage|external'
            $refusedSeed = $caseRoot + '/refused-seed-' + $pointer.Replace('/','-')
            Assert-Refused ('selected submodule cache refuses external storage before admission: ' + $pointer) {
                Invoke-DsrCargoCache -Operation snapshot -First $subHome -Second $refusedSeed -Lockfile ($subWorkspace + '/Cargo.lock')
            } 'External|external'
            Assert-Check ('external storage does not publish a seed receipt: ' + $pointer) (-not [IO.File]::Exists($refusedSeed + '/.dsr-cache-seed.json'))
            [IO.File]::Move($path,($caseRoot + '/retained-' + $pointer.Replace('/','-')))
        }
        $extraAdmin = $checkout + '/src/.git'
        $null = Invoke-Program $git @('init','--bare',$extraAdmin)
        Assert-Refused 'unlisted nested Git administration is not exempted from exact inventory' { Invoke-DsrCargoSources -Operation capture @bad } 'directories differ|unlisted|Unexpected'
        [IO.Directory]::Move($extraAdmin,($caseRoot + '/retained-unlisted-admin'))
        $extraDirectory = $childRoot + '/unlisted-empty'; $null = [IO.Directory]::CreateDirectory($extraDirectory)
        Assert-Refused 'unlisted nested empty directories are refused' { Invoke-DsrCargoSources -Operation capture @bad } 'directories differ'
        [IO.Directory]::Move($extraDirectory,($caseRoot + '/retained-extra-directory'))
        if (-not $script:WindowsHost) {
            $caseFile = $childRoot + '/VALUE.rs'; Write-FixtureText $caseFile $original
            Assert-Refused 'case-colliding nested source names are refused' { Invoke-DsrCargoSources -Operation capture @bad } 'ambiguous|collid|differ from locked content'
            [IO.File]::Move($caseFile,($caseRoot + '/retained-case-collision.rs'))
        }
        $retainedChild = $caseRoot + '/retained-linked-child'; [IO.Directory]::Move($childRoot,$retainedChild)
        $linkKind = if ($script:WindowsHost) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $linkKind -Path $childRoot -Target $retainedChild
        Assert-Refused 'nested source directory reparse is refused before following it' { Invoke-DsrCargoSources -Operation capture @bad } 'linked|special|reparse'
        [IO.Directory]::Move($childRoot,($caseRoot + '/retained-child-reparse'))
        [IO.Directory]::Move($retainedChild,$childRoot)
        Assert-Check 'every failed nested source capture leaves its receipt unpublished' (-not [IO.File]::Exists($bad.ReceiptPath))

        $unlocked = ([IO.Path]::GetDirectoryName($checkout)).Replace('\','/') + '/unlocked-fixture'
        $null = Invoke-Program $git @('init','--initial-branch=main',$unlocked)
        Write-FixtureText ($unlocked + '/unrelated.txt') 'not selected by Cargo.lock'
        $null = Invoke-Program $git @('-C',$unlocked,'add','unrelated.txt')
        $null = Invoke-Program $git @('-C',$unlocked,'-c','user.name=DSR Fixture','-c','user.email=dsr-fixture@example.invalid','commit','-m','unlocked ambient checkout')
        $outside = $caseRoot + '/unselected-outside'; Write-FixtureText ($outside + '/sentinel') 'unchanged'
        $null = New-Item -ItemType $linkKind -Path ($unlocked + '/unrelated-link') -Target $outside
        $null = New-Item -ItemType $linkKind -Path ($subHome + '/git/checkouts/unrelated-linked') -Target $outside
        $fixture = New-GeneratedSourceFixture 'submodule-generated-stage' -FromWorkspace $subWorkspace
        $target = $fixture.Parent + '/target'
        $configured = @('CARGO_TARGET_DIR=' + $target)
        if ($env:RUSTUP_HOME) { $configured += 'RUSTUP_HOME=' + $env:RUSTUP_HOME }
        $generated = @{SourceRoot=$fixture.SourceRoot;BuildCommand=$buildCommand;ConfiguredEnvironment=$configured}
        $admission = ConvertFrom-Json (Invoke-GeneratedSourceProgram -Operation Metadata -Suffix nested-clean @generated).Out -Depth 100
        $seed = $fixture.Parent + '/.cargo-home'; $seedReceipt = $seed + '/.dsr-cache-seed.json'
        $seedDigest = Get-DsrCargoSourceFileHash $seedReceipt
        $checkoutRelative = $checkout.Substring($subHome.Length + 1)
        Assert-Check 'selected seed retains the exact locked checkout and both submodule object stores' (
            $admission.selection.git_revisions.Count -eq 1 -and $admission.selection.git_revisions[0] -ceq $topRevision -and
            [IO.Directory]::Exists($seed + '/' + $checkoutRelative + '/vendor/.git/objects') -and
            [IO.Directory]::Exists($seed + '/' + $checkoutRelative + '/vendor/inner/.git/objects') -and
            -not [IO.File]::Exists($fixture.CompilerMarker))
        Assert-Check 'wrong-HEAD ambient checkout and its unrelated reparse stay outside the seed' (
            -not [IO.Directory]::Exists($seed + '/' + $unlocked.Substring($subHome.Length + 1)) -and
            -not [IO.Directory]::Exists($seed + '/git/checkouts/unrelated-linked') -and
            [IO.File]::ReadAllText($outside + '/sentinel') -ceq 'unchanged')
        $null = Invoke-GeneratedSourceProgram -Operation Build -Admission $admission @generated
        Assert-Check 'generated strict build compiles the authenticated nested dependency' ((Invoke-Program ($target + $binary) @()).Out.Trim() -ceq '42' -and [IO.File]::Exists($fixture.CompilerMarker))
        $final = ConvertFrom-Json (Invoke-GeneratedSourceProgram -Operation Finish -Admission $admission @generated).Out -Depth 100
        Assert-Check 'independent collection accepts original nested dependency authority' ($final.mode -ceq 'inventory' -and $final.cargo_home -ceq $admission.cargo_home)
        $retainedHome = $caseRoot + '/retained-ambient'; $retainedProducers = $caseRoot + '/retained-upstreams'
        [IO.Directory]::Move($subHome,$retainedHome); [IO.Directory]::Move($producers,$retainedProducers)
        try {
            $retry = ConvertFrom-Json (Invoke-GeneratedSourceProgram -Operation Metadata -Suffix nested-offline @generated).Out -Depth 100
            Assert-Check 'retained seed resolves nested submodules after ambient and upstream loss' ($retry.cargo_home -cne $admission.cargo_home -and
                $retry.dependency_sources.authentication.locked_git_packages -eq 1 -and
                (Get-DsrCargoSourceFileHash $seedReceipt) -ceq $seedDigest)
            $null = Invoke-GeneratedSourceProgram -Operation Build -Admission $retry @generated
            Assert-Check 'retained submodule seed supports a genuine offline retry build' ((Invoke-Program ($target + $binary) @()).Out.Trim() -ceq '42')
            $null = Invoke-GeneratedSourceProgram -Operation Finish -Admission $retry @generated
            $attemptSource = $retry.cargo_home + '/' + $checkoutRelative + '/vendor/inner/value.rs'
            Write-FixtureText $attemptSource "pub const VALUE: u32 = 99;`n"
            $rejectedBuild = Invoke-GeneratedSourceProgram -Operation Build -Admission $retry -ExpectFailure @generated
            Assert-GeneratedSourceRefusal 'generated build refuses changed private submodule source' $rejectedBuild 'differ from locked content'
            $rejectedFinish = Invoke-GeneratedSourceProgram -Operation Finish -Admission $retry -ExpectFailure @generated
            Assert-GeneratedSourceRefusal 'independent collection refuses changed private submodule source' $rejectedFinish 'differ from locked content'
            Assert-Check 'private-attempt poison does not change the retained submodule seed' ((Get-DsrCargoSourceFileHash $seedReceipt) -ceq $seedDigest -and
                [IO.File]::ReadAllText($seed + '/' + $checkoutRelative + '/vendor/inner/value.rs') -ceq $original)
        } finally {
            [IO.Directory]::Move($retainedProducers,$producers); [IO.Directory]::Move($retainedHome,$subHome)
        }
    } finally { [Environment]::SetEnvironmentVariable('CARGO_HOME',$savedHome) }
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
public sealed class DsrSourceRegistryFixture : IDisposable {
    readonly TcpListener listener;
    readonly Dictionary<string, byte[]> routes = new Dictionary<string, byte[]>(StringComparer.Ordinal);
    Task loop;
    volatile bool running;
    public string Url { get; private set; }
    public DsrSourceRegistryFixture(byte[] crate, string checksum) {
        listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        Url = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/";
        routes.Add("/config.json", Encoding.UTF8.GetBytes("{\"dl\":\"" + Url + "api/v1/crates\"}"));
        routes.Add("/so/ur/source_registry_dep", Encoding.UTF8.GetBytes(
            "{\"name\":\"source_registry_dep\",\"vers\":\"1.0.0\",\"deps\":[],\"cksum\":\"" + checksum + "\",\"features\":{},\"yanked\":false}\n"));
        routes.Add("/api/v1/crates/source_registry_dep/1.0.0/download", crate);
        running = true; loop = Task.Run((Action)Run);
    }
    void Run() {
        while (running) {
            TcpClient client;
            try { client = listener.AcceptTcpClient(); } catch (SocketException) { if (!running) break; throw; }
            using (client) using (NetworkStream stream = client.GetStream()) {
                client.ReceiveTimeout = 10000; client.SendTimeout = 10000;
                using (StreamReader reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true)) {
                    string request = reader.ReadLine();
                    string line; do { line = reader.ReadLine(); } while (!String.IsNullOrEmpty(line));
                    string path = request == null ? "" : request.Split(' ')[1]; byte[] body;
                    bool found = routes.TryGetValue(path, out body); if (!found) body = Encoding.ASCII.GetBytes("not found");
                    byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 " + (found ? "200 OK" : "404 Not Found") +
                        "\r\nContent-Length: " + body.Length + "\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n");
                    stream.Write(header, 0, header.Length); stream.Write(body, 0, body.Length); stream.Flush();
                }
            }
        }
    }
    public void Dispose() { running = false; listener.Stop(); loop.GetAwaiter().GetResult(); }
}
'@

$root = Join-Path ([IO.Path]::GetTempPath()) ('dsr-source-auth-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
$root = $root.Replace('\','/')
$crate = $root + '/registry-producer'; $upstream = $root + '/git-producer'; $workspace = $root + '/workspace'
$cargoHomePath = $root + '/cargo-home'; $null = [IO.Directory]::CreateDirectory($cargoHomePath)
$cargo = (Get-Command cargo -CommandType Application | Select-Object -First 1).Source
$git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
if (-not $sourceBashPath) {
    $sourceBashPath = if ($script:WindowsHost) { Join-Path (Split-Path -Parent (Split-Path -Parent $git)) 'bin/bash.exe' }
        else { (Get-Command bash -CommandType Application | Select-Object -First 1).Source }
}
if (-not (Test-Path -LiteralPath $sourceBashPath -PathType Leaf)) { throw 'Git Bash is required; pass -BashPath explicitly.' }
$oldCargoHome = [Environment]::GetEnvironmentVariable('CARGO_HOME')
$oldWrapper = [Environment]::GetEnvironmentVariable('RUSTC_WRAPPER')
$oldWorkspaceWrapper = [Environment]::GetEnvironmentVariable('RUSTC_WORKSPACE_WRAPPER')
[Environment]::SetEnvironmentVariable('CARGO_HOME',$cargoHomePath)
[Environment]::SetEnvironmentVariable('RUSTC_WRAPPER',$null)
[Environment]::SetEnvironmentVariable('RUSTC_WORKSPACE_WRAPPER',$null)
$server = $null
try {
    if ($SubmodulesOnly) {
        Test-DsrLockedGitSubmodules
        Write-Output ('Source submodule authentication checks: ' + $script:Checks + '; fixtures: ' + $root)
        return
    }
    Write-FixtureText ($crate + '/Cargo.toml') "[package]`nname=`"source_registry_dep`"`nversion=`"1.0.0`"`nedition=`"2021`"`n"
    Write-FixtureText ($crate + '/src/lib.rs') "pub fn answer() -> u32 { 40 }`n"
    Write-FixtureText ($crate + '/empty.txt') ''
    Write-FixtureText ($crate + '/nested/path/long-member-name-that-exercises-gnu-archive-extended-header-handling-and-keeps-windows-ordinary-path-constraints.txt') 'archive long-name fixture'
    $null = Invoke-Program $cargo @('package','--allow-dirty','--no-verify','--offline','--manifest-path',($crate + '/Cargo.toml')) $crate
    $archive = $crate + '/target/package/source_registry_dep-1.0.0.crate'
    $archiveBytes = [IO.File]::ReadAllBytes($archive)
    $server = [DsrSourceRegistryFixture]::new($archiveBytes,(Get-DsrCacheBytesHash $archiveBytes))
    Write-FixtureText ($upstream + '/Cargo.toml') "[package]`nname=`"source_git_dep`"`nversion=`"1.0.0`"`nedition=`"2021`"`n"
    Write-FixtureText ($upstream + '/src/lib.rs') "pub fn answer() -> u32 { 2 }`n"
    $null = Invoke-Program $git @('init','--initial-branch=main',$upstream)
    $null = Invoke-Program $git @('-C',$upstream,'add','Cargo.toml','src/lib.rs')
    $null = Invoke-Program $git @('-C',$upstream,'-c','user.name=DSR Fixture','-c','user.email=dsr-fixture@example.invalid','commit','-m','source authentication fixture')
    $revision = (Invoke-Program $git @('-C',$upstream,'rev-parse','HEAD')).Out.Trim()
    $upstreamUri = [Uri]::new($upstream).AbsoluteUri
    Write-FixtureText ($workspace + '/Cargo.toml') ("[package]`nname=`"source_auth_app`"`nversion=`"1.0.0`"`nedition=`"2021`"`n" +
        "[dependencies]`nsource_registry_dep = { version = `"=1.0.0`", registry = `"fixture`" }`n" +
        "source_git_dep = { git = `"$upstreamUri`", rev = `"$revision`" }`n")
    Write-FixtureText ($workspace + '/.cargo/config.toml') ("[registries.fixture]`nindex = `"sparse+" + $server.Url + "`"`n")
    Write-FixtureText ($workspace + '/src/main.rs') "fn main() { println!(`"{}`", source_registry_dep::answer() + source_git_dep::answer()); }`n"
    $null = Invoke-Program $cargo @('fetch','--manifest-path',($workspace + '/Cargo.toml')) $workspace
    $server.Dispose(); $server = $null
    # Genuine metadata after the registry server is gone uses only admitted
    # cached index, archive, checkout and object bytes.
    $metadataPath = $root + '/metadata.json'; $receiptPath = $root + '/sources.json'
    $metadataText = (Invoke-Program $cargo @('metadata','--locked','--offline','--all-features','--format-version','1','--manifest-path',($workspace + '/Cargo.toml')) $workspace).Out
    Write-FixtureText $metadataPath $metadataText
    $arguments = @{MetadataPath=$metadataPath;ReceiptPath=$receiptPath;Lockfile=($workspace + '/Cargo.lock');CargoHome=$cargoHomePath;SourceRoot=$workspace}
    $summary = Invoke-DsrCargoSources -Operation capture @arguments
    Assert-Check 'real registry and Git packages authenticated against Cargo.lock' ($summary.package_count -eq 2 -and $summary.authentication.locked_archive_packages -eq 1 -and $summary.authentication.locked_git_packages -eq 1)
    $evidence = (Read-DsrCargoReceipt $receiptPath).value
    $registryEvidence = $evidence.roots | Where-Object { $_.kind -ceq 'registry' }
    Assert-Check 'empty crate members and GNU long names are authenticated' (@($registryEvidence.files | Where-Object { $_.path -ceq 'empty.txt' -and $_.size_bytes -eq 0 }).Count -eq 1 -and
        @($registryEvidence.files | Where-Object { $_.path.Length -gt 100 }).Count -eq 1)
    Assert-Check 'receipt digest is held independently of its parsed fields' ($summary.sha256 -ceq (Get-DsrCargoSourceFileHash $receiptPath))
    $verified = Invoke-DsrCargoSources -Operation verify -ExpectedSha256 $summary.sha256 @arguments
    Assert-Check 'same real source bytes reverify with the held receipt' ((ConvertTo-DsrCacheCanonicalJson $summary) -ceq (ConvertTo-DsrCacheCanonicalJson $verified))
    $null = Invoke-Program $cargo @('build','--locked','--offline','--target-dir',($root + '/target-clean')) $workspace
    $binary = '/debug/source_auth_app' + $(if ($script:WindowsHost) { '.exe' } else { '' })
    $answer = (Invoke-Program ($root + '/target-clean' + $binary) @()).Out.Trim()
    Assert-Check 'genuine offline dependency build produces expected behavior' ($answer -ceq '42')
    $metadata = ConvertFrom-Json $metadataText -Depth 100
    $registryPackage = $metadata.packages | Where-Object { $_.name -ceq 'source_registry_dep' }
    $gitPackage = $metadata.packages | Where-Object { $_.name -ceq 'source_git_dep' }
    $registryRoot = ([IO.Path]::GetDirectoryName($registryPackage.manifest_path)).Replace('\','/')
    $gitRoot = ([IO.Path]::GetDirectoryName($gitPackage.manifest_path)).Replace('\','/')
    $registryLib = $registryRoot + '/src/lib.rs'; $registryOriginal = [IO.File]::ReadAllText($registryLib)
    $gitLib = $gitRoot + '/src/lib.rs'; $gitOriginal = [IO.File]::ReadAllText($gitLib)
    Write-FixtureText $registryLib "pub fn answer() -> u32 { 41 }`n"
    $null = Invoke-Program $cargo @('build','--locked','--offline','--target-dir',($root + '/target-registry-poison')) $workspace
    $answer = (Invoke-Program ($root + '/target-registry-poison' + $binary) @()).Out.Trim()
    Assert-Check 'poisoned cached registry bytes change a genuine Cargo build' ($answer -ceq '43')
    Assert-Refused 'registry poison refused against controller-held receipt' { Invoke-DsrCargoSources -Operation verify -ExpectedSha256 $summary.sha256 @arguments } 'differ from locked content'
    $badCapture = $arguments.Clone(); $badCapture.ReceiptPath = $root + '/poison-receipt.json'
    Assert-Refused 'fresh receipt cannot launder pre-existing registry poison' { Invoke-DsrCargoSources -Operation capture @badCapture } 'differ from locked content'
    Assert-Check 'poisoned receipt was never published' (-not [IO.File]::Exists($badCapture.ReceiptPath))
    Write-FixtureText $registryLib $registryOriginal
    Write-FixtureText $gitLib "pub fn answer() -> u32 { 3 }`n"
    $null = Invoke-Program $cargo @('build','--locked','--offline','--target-dir',($root + '/target-git-poison')) $workspace
    $answer = (Invoke-Program ($root + '/target-git-poison' + $binary) @()).Out.Trim()
    Assert-Check 'poisoned cached Git bytes change a genuine Cargo build' ($answer -ceq '43')
    Assert-Refused 'Git checkout poison refused against locked object bytes' { Invoke-DsrCargoSources -Operation verify -ExpectedSha256 $summary.sha256 @arguments } 'differ from locked content'
    Assert-Refused 'fresh receipt cannot launder pre-existing Git poison' { Invoke-DsrCargoSources -Operation capture @badCapture } 'differ from locked content'
    Write-FixtureText $gitLib $gitOriginal
    $extra = $registryRoot + '/injected.rs'; Write-FixtureText $extra 'unlisted input'
    Assert-Refused 'unlisted registry input is refused' { Invoke-DsrCargoSources -Operation capture @badCapture } 'differ from locked content'
    [IO.File]::Move($extra,($root + '/retained-injected.rs'))
    $extraDirectory = $gitRoot + '/injected-empty'; $null = [IO.Directory]::CreateDirectory($extraDirectory)
    Assert-Refused 'unlisted empty Git source directory is refused' { Invoke-DsrCargoSources -Operation capture @badCapture } 'directories differ'
    [IO.Directory]::Move($extraDirectory,($root + '/retained-empty'))
    $heldText = [IO.File]::ReadAllText($receiptPath)
    Write-FixtureText $receiptPath ($heldText + ' ')
    Assert-Refused 'rewritten source receipt cannot replace held authority' { Invoke-DsrCargoSources -Operation verify -ExpectedSha256 $summary.sha256 @arguments } 'canonical|receipt changed'
    Write-FixtureText $receiptPath $heldText
    Assert-Refused 'verify requires a controller-held digest' { Invoke-DsrCargoSources -Operation verify @arguments } 'controller-held'
    Assert-Refused 'wrong held digest fails before source admission' { Invoke-DsrCargoSources -Operation verify -ExpectedSha256 ('0'*64) @arguments } 'receipt changed'
    $outside = $arguments.Clone(); $outside.SourceRoot = $root
    Assert-Refused 'metadata workspace cannot escape selected source root' { Invoke-DsrCargoSources -Operation capture @outside } 'escapes'
    $outside = $arguments.Clone(); $outside.Lockfile = $crate + '/Cargo.lock'
    Assert-Refused 'unrelated lockfile cannot authenticate workspace' { Invoke-DsrCargoSources -Operation capture @outside } 'escapes'
    $unsafeReceipt = $arguments.Clone(); $unsafeReceipt.ReceiptPath = $registryRoot + '/proof.json'
    Assert-Refused 'receipt must be outside dependency tree' { Invoke-DsrCargoSources -Operation capture @unsafeReceipt } 'inside dependency'
    $duplicateMetadata = $root + '/duplicate-metadata.json'
    Write-FixtureText $duplicateMetadata ($metadataText.TrimEnd().Substring(0,$metadataText.TrimEnd().Length-1) + ',"packages":[]}')
    $duplicateArguments = $badCapture.Clone(); $duplicateArguments.MetadataPath = $duplicateMetadata
    Assert-Refused 'duplicate metadata keys cannot replace the resolved graph' { Invoke-DsrCargoSources -Operation capture @duplicateArguments } 'Duplicate'
    $lockPath = $workspace + '/Cargo.lock'; $lockText = [IO.File]::ReadAllText($lockPath)
    Write-FixtureText $lockPath ($lockText + "`n[metadata]`nchecksum = `"" + ('0'*64) + "`"`n")
    Assert-Refused 'unsupported lockfile tables do not manufacture checksums' { Invoke-DsrCargoSources -Operation capture @badCapture } 'Unsupported Cargo.lock table'
    Write-FixtureText $lockPath $lockText
    $unusedRegistryLock = $lockText.Replace("[[package]]`nname = `"source_registry_dep`"", "[[patch.unused]]`nname = `"source_registry_dep`"").Replace("[[package]]`r`nname = `"source_registry_dep`"", "[[patch.unused]]`r`nname = `"source_registry_dep`"")
    Assert-Check 'unused-patch refusal fixture changes the actual registry table' ($unusedRegistryLock -cne $lockText)
    Write-FixtureText $lockPath $unusedRegistryLock
    Assert-Refused 'unused patch entries cannot authenticate resolved dependency packages' { Invoke-DsrCargoSources -Operation capture @badCapture } 'not pinned by Cargo.lock'
    Write-FixtureText $lockPath $lockText
    $malformedLocks = @(
        "version=4`n[[package]]`nname=`"x`"`nversion=`"1`"`nsource=`"registry+https://example.invalid`"`nchecksum=`"a`"`nchecksum=`"b`"`n",
        "version=4`n[[package]]`nname=`"x`"`nversion=`"1`"`nsource=`"registry+https://example.invalid`"`nchecksum=`"`"`"`nchecksum=`"a`"`n`"`"`"`n",
        "version=4`nversion=3`n[[package]]`nname=`"x`"`nversion=`"1`"`n",
        "version=40`n[[package]]`nname=`"x`"`nversion=`"1`"`n")
    foreach ($malformed in $malformedLocks) { Assert-Refused 'bounded lock parser rejects ambiguous Cargo.lock grammar' { [DsrCargoSourceLock]::Read($script:Utf8.GetBytes($malformed)) } }
    $parsedLock = [DsrCargoSourceLock]::Read($script:Utf8.GetBytes("# checksum is a comment`nversion = 3`n[[package]] # package comment`nname = `"x`"`nversion = `"1`"`ndependencies = [`"a`", # comment`n`"b`",]`n"))
    Assert-Check 'v3 Cargo-generated comments and dependency arrays parse structurally' ($parsedLock.Count -eq 1 -and $parsedLock[0].dependencies.Count -eq 2)
    foreach ($member in @('../escape','pkg/../escape','pkg/.git/config','pkg/NUL','pkg/trailing.','pkg/stream:name','pkg\alias','pkg//alias')) {
        Assert-Refused ('unsafe authenticated archive/object member ' + $member) { [DsrCargoSourceObjects]::Member($member) }
    }
    $unsafeAdmin = $gitRoot + '/.git/objects/info/alternates'; Write-FixtureText $unsafeAdmin ($root + '/outside-objects')
    Assert-Refused 'Git external object alternates cannot supply authority' { Invoke-DsrCargoSources -Operation capture @badCapture } 'External Git object storage'
    [IO.File]::Move($unsafeAdmin,($root + '/retained-alternates'))
    $originalObjects = $gitRoot + '/.git/objects'; $retainedObjects = $root + '/retained-git-objects'
    [IO.Directory]::Move($originalObjects,$retainedObjects)
    $objectPath = $gitRoot + '/.git/objects/' + $revision.Substring(0,2) + '/' + $revision.Substring(2)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($objectPath))
    $poisonCommit = $script:Utf8.GetBytes("tree " + ('0'*40) + "`nauthor attacker`n`npoisoned identity`n")
    $objectPrefix = $script:Utf8.GetBytes('commit ' + $poisonCommit.Length + [char]0)
    $objectStream = [IO.FileStream]::new($objectPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    $compressor = [IO.Compression.ZLibStream]::new($objectStream,[IO.Compression.CompressionLevel]::Optimal)
    try { $compressor.Write($objectPrefix); $compressor.Write($poisonCommit) } finally { $compressor.Dispose(); $objectStream.Dispose() }
    Assert-Refused 'Git object filename cannot authenticate different object bytes' { Invoke-DsrCargoSources -Operation capture @badCapture } 'object bytes do not match'
    [IO.Directory]::Move($originalObjects,($root + '/retained-poison-objects'))
    [IO.Directory]::Move($retainedObjects,$originalObjects)
    $cachedArchive = $cargoHomePath + '/registry/cache/' + [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($registryRoot)) + '/' + [IO.Path]::GetFileName($registryRoot) + '.crate'
    $originalArchiveBytes = [IO.File]::ReadAllBytes($cachedArchive)
    [IO.File]::WriteAllBytes($cachedArchive,[byte[]]@(0,1,2,3))
    Assert-Refused 'cached archive contents must match the lockfile checksum' { Invoke-DsrCargoSources -Operation capture @badCapture } 'archive differs'
    [IO.File]::WriteAllBytes($cachedArchive,$originalArchiveBytes)
    $retainedArchive = $root + '/retained.crate'; [IO.File]::Move($cachedArchive,$retainedArchive)
    Assert-Refused 'an inventory cannot replace a missing locked archive' { Invoke-DsrCargoSources -Operation capture @badCapture }
    [IO.File]::Move($retainedArchive,$cachedArchive)
    $vendorWorkspace = $root + '/vendor-workspace'
    Write-FixtureText ($vendorWorkspace + '/Cargo.toml') ([IO.File]::ReadAllText($workspace + '/Cargo.toml'))
    Write-FixtureText ($vendorWorkspace + '/Cargo.lock') $lockText
    Write-FixtureText ($vendorWorkspace + '/src/main.rs') ([IO.File]::ReadAllText($workspace + '/src/main.rs'))
    $registryConfiguration = [IO.File]::ReadAllText($workspace + '/.cargo/config.toml')
    Write-FixtureText ($vendorWorkspace + '/.cargo/config.toml') $registryConfiguration
    $vendorConfiguration = (Invoke-Program $cargo @('vendor','--locked','--offline',($vendorWorkspace + '/vendor')) $vendorWorkspace).Out
    Write-FixtureText ($vendorWorkspace + '/.cargo/config.toml') ($registryConfiguration + "`n" + $vendorConfiguration)
    $vendorMetadata = $root + '/vendor-metadata.json'
    Write-FixtureText $vendorMetadata (Invoke-Program $cargo @('metadata','--locked','--offline','--all-features','--format-version','1') $vendorWorkspace).Out
    $vendorArguments = @{MetadataPath=$vendorMetadata;ReceiptPath=($root + '/vendor-receipt.json');Lockfile=($vendorWorkspace + '/Cargo.lock');CargoHome=$cargoHomePath;SourceRoot=$vendorWorkspace}
    $vendorSummary = Invoke-DsrCargoSources -Operation capture @vendorArguments
    Assert-Check 'genuine cargo vendor sources retain the distinct committed-workspace trust basis' ($vendorSummary.package_count -eq 2 -and
        $vendorSummary.authentication.workspace_snapshot_packages -eq 2 -and $vendorSummary.authentication.locked_archive_packages -eq 0 -and
        $vendorSummary.authentication.locked_git_packages -eq 0)
    $vendorGraph = ConvertFrom-Json ([IO.File]::ReadAllText($vendorMetadata)) -Depth 100
    $vendorPackage = $vendorGraph.packages | Where-Object { $_.name -ceq 'source_registry_dep' }
    $vendorOriginal = $vendorPackage.manifest_path
    $vendorPackage.manifest_path = $registryPackage.manifest_path
    # An external directory pretending to be a vendor is not covered by the
    # caller's committed primary snapshot, even with an editable descriptor.
    $externalVendor = $root + '/external-vendor'; $null = [IO.Directory]::CreateDirectory($externalVendor)
    Write-FixtureText ($externalVendor + '/Cargo.toml') '[package]'
    Write-FixtureText ($externalVendor + '/.cargo-checksum.json') '{"files":{}}'
    $vendorPackage.manifest_path = $externalVendor + '/Cargo.toml'
    Write-FixtureText $vendorMetadata ($vendorGraph | ConvertTo-Json -Depth 100 -Compress)
    Assert-Refused 'external vendor descriptors cannot confer workspace authenticity' { Invoke-DsrCargoSources -Operation capture @vendorArguments } 'External directory source'
    $vendorPackage.manifest_path = $vendorOriginal
    Write-FixtureText $vendorMetadata ($vendorGraph | ConvertTo-Json -Depth 100 -Compress)
    $simpleWorkspace = $root + '/simple-workspace'
    Write-FixtureText ($simpleWorkspace + '/Cargo.toml') "[package]`nname=`"no_dependency_app`"`nversion=`"1.0.0`"`nedition=`"2021`"`n[patch.crates-io]`nunused_dependency = { path = `"unused`" }`n"
    Write-FixtureText ($simpleWorkspace + '/src/lib.rs') 'pub fn value() -> u32 { 42 }'
    Write-FixtureText ($simpleWorkspace + '/unused/Cargo.toml') "[package]`nname=`"unused_dependency`"`nversion=`"1.0.0`"`nedition=`"2021`"`n"
    Write-FixtureText ($simpleWorkspace + '/unused/src/lib.rs') 'pub fn unused() {}'
    $null = Invoke-Program $cargo @('generate-lockfile','--offline') $simpleWorkspace
    Assert-Check 'real Cargo generates the standard unused local patch table' ([IO.File]::ReadAllText($simpleWorkspace + '/Cargo.lock').Contains('[[patch.unused]]'))
    $simpleMetadata = $root + '/simple-metadata.json'
    Write-FixtureText $simpleMetadata (Invoke-Program $cargo @('metadata','--locked','--offline','--all-features','--format-version','1') $simpleWorkspace).Out
    $simpleSummary = Invoke-DsrCargoSources -Operation capture -MetadataPath $simpleMetadata -ReceiptPath ($root + '/simple-sources.json') -Lockfile ($simpleWorkspace + '/Cargo.lock') -CargoHome $cargoHomePath -SourceRoot $simpleWorkspace
    Assert-Check 'genuine workspace without remote dependencies admits an authenticated empty closure' ($simpleSummary.package_count -eq 0 -and
        $simpleSummary.root_count -eq 0 -and $simpleSummary.file_count -eq 0 -and $simpleSummary.authentication.lockfile_sha256 -cmatch '^[0-9a-f]{64}$')

    $caseUpper = $root + '/case-boundary/Project'; $caseLower = $root + '/case-boundary/project'
    $null = [IO.Directory]::CreateDirectory($caseUpper); $null = [IO.Directory]::CreateDirectory($caseLower)
    $upperHandle = Open-DsrCacheEntry $caseUpper -Directory $true; $lowerHandle = Open-DsrCacheEntry $caseLower -Directory $true
    try { $distinctCaseRoots = $upperHandle.FileId -cne $lowerHandle.FileId }
    finally { $upperHandle.Dispose(); $lowerHandle.Dispose() }
    if ($distinctCaseRoots) {
        Assert-Check 'case-sensitive fixture has distinct directories despite case-insensitive path equality' ([StringComparer]::OrdinalIgnoreCase.Equals($caseUpper,$caseLower))
        foreach ($directory in @($caseUpper,$caseLower)) {
            Write-FixtureText ($directory + '/Cargo.toml') "[package]`nname=`"case_boundary_app`"`nversion=`"1.0.0`"`nedition=`"2021`"`n"
            Write-FixtureText ($directory + '/src/lib.rs') 'pub fn value() -> u32 { 42 }'
        }
        $null = Invoke-Program $cargo @('generate-lockfile','--offline') $caseLower
        Write-FixtureText ($caseUpper + '/Cargo.lock') ([IO.File]::ReadAllText($caseLower + '/Cargo.lock'))
        $caseMetadata = $root + '/case-metadata.json'
        Write-FixtureText $caseMetadata (Invoke-Program $cargo @('metadata','--locked','--offline','--all-features','--format-version','1') $caseLower).Out
        $caseArguments = @{MetadataPath=$caseMetadata;ReceiptPath=($root + '/case-receipt.json');Lockfile=($caseUpper + '/Cargo.lock');CargoHome=$cargoHomePath;SourceRoot=$caseUpper}
        Assert-Refused 'distinct case-colliding workspace cannot borrow another physical source root' { Invoke-DsrCargoSources -Operation capture @caseArguments } 'physical root'
        Assert-Refused 'case-colliding vendor or cache directory cannot borrow physical containment' { Assert-DsrCargoSourceBoundary -Path ($caseLower + '/src') -Root $caseUpper } 'physical root'
        Assert-Refused 'case-colliding dependency target cannot escape its physical source tree' { Assert-DsrCargoSourceBoundary -Path ($caseLower + '/src/lib.rs') -Root $caseUpper -File } 'physical root'
        Write-FixtureText ($caseLower + '/cargo.lock') ([IO.File]::ReadAllText($caseLower + '/Cargo.lock'))
        $canonicalLock = Open-DsrCacheEntry ($caseLower + '/Cargo.lock'); $otherLock = Open-DsrCacheEntry ($caseLower + '/cargo.lock')
        try { $distinctLocks = $canonicalLock.FileId -cne $otherLock.FileId } finally { $canonicalLock.Dispose(); $otherLock.Dispose() }
        if ($distinctLocks) {
            $caseArguments.SourceRoot = $caseLower; $caseArguments.Lockfile = $caseLower + '/cargo.lock'
            Assert-Refused 'a distinct case-colliding lockfile cannot replace Cargo.lock authority' { Invoke-DsrCargoSources -Operation capture @caseArguments } 'physical lockfile'
        }
    } else {
        Assert-DsrCargoSourceBoundary -Path $caseLower -Root $caseUpper -Exact
        Assert-Check 'ordinary Windows case aliases retain the same physical source identity' $true
    }

    $generatedFixture = New-GeneratedSourceFixture 'generated-stage'
    $generatedParent = $generatedFixture.Parent; $generatedSource = $generatedFixture.SourceRoot
    $generatedTarget = $root + '/target-generated'
    $configured = @('CARGO_TARGET_DIR=' + $generatedTarget)
    if ($env:RUSTUP_HOME) { $configured += 'RUSTUP_HOME=' + $env:RUSTUP_HOME }
    $buildCommand = 'cargo build --locked --offline -j1'
    $generatedArguments = @{SourceRoot=$generatedSource;BuildCommand=$buildCommand;ConfiguredEnvironment=$configured}
    Write-FixtureText $registryLib "pub fn answer() -> u32 { 41 }`n"
    Write-FixtureText $gitLib "pub fn answer() -> u32 { 3 }`n"
    $null = Invoke-Program $cargo @('build','--locked','--offline','--target-dir',($root + '/target-generated-ungated')) $workspace
    Assert-Check 'ungated Cargo compiles both poisoned ambient source trees' ((Invoke-Program ($root + '/target-generated-ungated' + $binary) @()).Out.Trim() -ceq '44')
    $unrelatedArchive = $cargoHomePath + '/registry/cache/unrelated-cache/unrelated-9.9.9.crate'
    Write-FixtureText $unrelatedArchive 'unrelated download must not enter the admitted seed'
    $largeArchive = [IO.File]::OpenWrite($unrelatedArchive)
    try { $largeArchive.SetLength(64MB) } finally { $largeArchive.Dispose() }
    $unrelatedOutside = $root + '/unrelated-linked-source'; Write-FixtureText ($unrelatedOutside + '/sentinel') 'untouched'
    $linkKind = if ($script:WindowsHost) { 'Junction' } else { 'SymbolicLink' }
    foreach ($relative in @('registry/src/unrelated-linked','git/checkouts/unrelated-linked')) {
        $null = New-Item -ItemType $linkKind -Path ($cargoHomePath + '/' + $relative) -Target $unrelatedOutside
    }
    $admission = ConvertFrom-Json (Invoke-GeneratedSourceProgram -Operation Metadata -Suffix reconstructed @generatedArguments).Out -Depth 100
    Assert-Check 'generated metadata reconstructs authenticated registry and Git sources from locked downloads' ($admission.dependency_sources.authentication.locked_archive_packages -eq 1 -and
        $admission.dependency_sources.authentication.locked_git_packages -eq 1 -and [IO.Directory]::Exists($generatedParent + '/.cargo-home'))
    $canonicalSeed = $generatedParent + '/.cargo-home'
    $canonicalReceipt = Read-DsrCargoReceipt ($canonicalSeed + '/.dsr-cache-seed.json')
    Assert-Check 'retained download selection binds the actual lock and excludes extracted sources and unrelated payloads' (
        $admission.selection.kind -ceq 'cargo-lock-downloads' -and
        $admission.selection.lockfile_sha256 -ceq (Get-DsrCargoSourceFileHash ($generatedSource + '/Cargo.lock')) -and
        $admission.selection.registry_packages -eq 1 -and @($admission.selection.git_revisions).Count -eq 1 -and
        $admission.selection.git_revisions[0] -ceq $revision -and
        (ConvertTo-DsrCacheCanonicalJson $admission.selection) -ceq (ConvertTo-DsrCacheCanonicalJson $canonicalReceipt.value.selection) -and
        -not [IO.Directory]::Exists($canonicalSeed + '/registry/src') -and
        -not [IO.Directory]::Exists($canonicalSeed + '/git/checkouts') -and
        -not [IO.File]::Exists($canonicalSeed + '/registry/cache/unrelated-cache/unrelated-9.9.9.crate') -and
        $admission.size_bytes -lt 64MB -and
        [IO.File]::ReadAllText($unrelatedOutside + '/sentinel') -ceq 'untouched')
    Assert-Check 'authenticated metadata and seed admission do not compile the project' (-not [IO.File]::Exists($generatedFixture.CompilerMarker))
    $attemptMetadata = $admission.cargo_home + '/.dsr-cargo-metadata.json'; $attemptReceipt = $admission.cargo_home + '/.dsr-cargo-sources.json'
    Assert-Check 'generated metadata retains both independently held source-evidence digests' ($admission.dependency_sources.metadata_sha256 -ceq (Get-DsrCargoSourceFileHash $attemptMetadata) -and
        $admission.dependency_sources.sha256 -ceq (Get-DsrCargoSourceFileHash $attemptReceipt))
    $admittedSeedDigest = Get-DsrCargoSourceFileHash ($generatedParent + '/.cargo-home/.dsr-cache-seed.json')
    $null = Invoke-GeneratedSourceProgram -Operation Build -Admission $admission @generatedArguments
    Assert-Check 'generated admitted build performs authentic compilation despite poisoned ambient extraction' (
        (Invoke-Program ($generatedTarget + $binary) @()).Out.Trim() -ceq '42' -and [IO.File]::Exists($generatedFixture.CompilerMarker))
    Write-FixtureText $registryLib $registryOriginal
    Write-FixtureText $gitLib $gitOriginal
    $final = ConvertFrom-Json (Invoke-GeneratedSourceProgram -Operation Finish -Admission $admission @generatedArguments).Out -Depth 100
    Assert-Check 'independent generated finish accepts the exact coordinator-held evidence' ($final.mode -ceq 'inventory' -and
        $final.cargo_home -ceq $admission.cargo_home -and $final.receipt_sha256 -ceq (Get-DsrCargoSourceFileHash $final.receipt_path))
    Assert-Check 'final expanded cache inventory does not claim download-only selection' ($final.PSObject.Properties.Name -cnotcontains 'selection')
    Assert-Check 'metadata recovery and actual build preserve the admitted canonical seed' ((Get-DsrCargoSourceFileHash ($generatedParent + '/.cargo-home/.dsr-cache-seed.json')) -ceq $admittedSeedDigest)
    $retainedAmbient = $root + '/retained-ambient-after-admission'
    [IO.Directory]::Move($cargoHomePath,$retainedAmbient)
    try {
        $retryAdmission = ConvertFrom-Json (Invoke-GeneratedSourceProgram -Operation Metadata -Suffix ambient-gone @generatedArguments).Out -Depth 100
        Assert-Check 'fresh metadata reconstructs both dependencies from the unchanged retained seed after ambient loss' (
            $retryAdmission.cargo_home -cne $admission.cargo_home -and
            $retryAdmission.dependency_sources.authentication.locked_archive_packages -eq 1 -and
            $retryAdmission.dependency_sources.authentication.locked_git_packages -eq 1 -and
            (ConvertTo-DsrCacheCanonicalJson $retryAdmission.selection) -ceq (ConvertTo-DsrCacheCanonicalJson $admission.selection) -and
            (Get-DsrCargoSourceFileHash ($canonicalSeed + '/.dsr-cache-seed.json')) -ceq $admittedSeedDigest -and
            -not [IO.Directory]::Exists($canonicalSeed + '/registry/src') -and
            -not [IO.Directory]::Exists($canonicalSeed + '/git/checkouts'))
    } finally { [IO.Directory]::Move($retainedAmbient,$cargoHomePath) }
    $attemptGraph = ConvertFrom-Json ([IO.File]::ReadAllText($attemptMetadata)) -Depth 100
    $attemptRegistryPackage = $attemptGraph.packages | Where-Object { $_.name -ceq 'source_registry_dep' }
    $attemptRegistryLib = ([IO.Path]::GetDirectoryName($attemptRegistryPackage.manifest_path)).Replace('\','/') + '/src/lib.rs'
    $attemptOriginal = [IO.File]::ReadAllText($attemptRegistryLib)
    Write-FixtureText $attemptRegistryLib "pub fn answer() -> u32 { 99 }`n"
    $rejectedBuild = Invoke-GeneratedSourceProgram -Operation Build -Admission $admission -ExpectFailure @generatedArguments
    Assert-GeneratedSourceRefusal 'generated build rejects altered attempt dependency bytes before compilation' $rejectedBuild 'differ from locked content'
    $rejectedFinish = Invoke-GeneratedSourceProgram -Operation Finish -Admission $admission -ExpectFailure @generatedArguments
    Assert-GeneratedSourceRefusal 'independent finish rejects altered dependency bytes before artifact collection' $rejectedFinish 'differ from locked content'
    Write-FixtureText $attemptRegistryLib $attemptOriginal
    $attemptMetadataText = [IO.File]::ReadAllText($attemptMetadata)
    Write-FixtureText $attemptMetadata ($attemptMetadataText + ' ')
    $rejectedFinish = Invoke-GeneratedSourceProgram -Operation Finish -Admission $admission -ExpectFailure @generatedArguments
    Assert-GeneratedSourceRefusal 'independent finish rejects changed metadata against the held digest' $rejectedFinish 'coordinator-held authority'
    Write-FixtureText $attemptMetadata $attemptMetadataText
    $attemptReceiptText = [IO.File]::ReadAllText($attemptReceipt)
    Write-FixtureText $attemptReceipt ($attemptReceiptText + ' ')
    $rejectedFinish = Invoke-GeneratedSourceProgram -Operation Finish -Admission $admission -ExpectFailure @generatedArguments
    Assert-GeneratedSourceRefusal 'independent finish rejects changed source receipt against the held digest' $rejectedFinish 'coordinator-held authority'
    Write-FixtureText $attemptReceipt $attemptReceiptText
    Assert-Check 'failed final admissions preserve previously published final receipt bytes' ((Get-DsrCargoSourceFileHash $final.receipt_path) -ceq $final.receipt_sha256)

    # Real locked downloads are damaged independently. Omitted candidates must
    # fail actual offline resolution; linked selected storage fails even before
    # metadata. No failure may publish a canonical seed or compile the project.
    $registryNamespace = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($registryRoot))
    foreach ($damage in @('archive-missing','archive-corrupt','git-missing','git-corrupt','archive-linked','git-linked','git-alternates')) {
        $caseFixture = New-GeneratedSourceFixture ('required-' + $damage)
        $caseAmbient = $caseFixture.Parent + '/ambient'
        $null = Invoke-DsrCargoCache -Operation snapshot -First $cargoHomePath -Second $caseAmbient -Lockfile ($caseFixture.SourceRoot + '/Cargo.lock')
        $caseArchiveDirectory = $caseAmbient + '/registry/cache/' + $registryNamespace
        $caseArchive = $caseArchiveDirectory + '/source_registry_dep-1.0.0.crate'
        $caseDatabase = Get-ChildItem -LiteralPath ($caseAmbient + '/git/db') -Directory | Select-Object -First 1
        switch ($damage) {
            'archive-missing' { [IO.File]::Move($caseArchive,($caseFixture.Parent + '/retained.crate')) }
            'archive-corrupt' { [IO.File]::WriteAllBytes($caseArchive,[byte[]]@(0,1,2,3)) }
            'git-missing' { [IO.Directory]::Move($caseDatabase.FullName,($caseFixture.Parent + '/retained-db')) }
            'git-corrupt' { Write-FixtureText ($caseDatabase.FullName + '/HEAD') 'not a Git reference' }
            'archive-linked' {
                $retained = $caseFixture.Parent + '/retained-archive-directory'
                [IO.Directory]::Move($caseArchiveDirectory,$retained)
                $null = New-Item -ItemType $linkKind -Path $caseArchiveDirectory -Target $retained
            }
            'git-linked' {
                $retained = $caseFixture.Parent + '/retained-db'
                [IO.Directory]::Move($caseDatabase.FullName,$retained)
                $null = New-Item -ItemType $linkKind -Path $caseDatabase.FullName -Target $retained
            }
            'git-alternates' { Write-FixtureText ($caseDatabase.FullName + '/objects/info/alternates') ($root + '/outside-object-store') }
        }
        if ($damage -in @('archive-linked','git-linked','git-alternates')) {
            $refusedHome = $caseFixture.Parent + '/refused-private'
            Assert-Refused ('selected ' + $damage + ' storage is refused before metadata') {
                Invoke-DsrCargoCache -Operation snapshot -First $caseAmbient -Second $refusedHome -Lockfile ($caseFixture.SourceRoot + '/Cargo.lock')
            } 'linked|Linked|reparse|special|Git|storage|reference'
            Assert-Check ('refused ' + $damage + ' snapshot publishes no seed receipt') (-not [IO.File]::Exists($refusedHome + '/.dsr-cache-seed.json'))
        } else {
            $caseConfigured = @('CARGO_TARGET_DIR=' + $caseFixture.Parent + '/target')
            if ($env:RUSTUP_HOME) { $caseConfigured += 'RUSTUP_HOME=' + $env:RUSTUP_HOME }
            [Environment]::SetEnvironmentVariable('CARGO_HOME',$caseAmbient)
            try {
                $failed = Invoke-GeneratedSourceProgram -Operation Metadata -SourceRoot $caseFixture.SourceRoot -BuildCommand $buildCommand `
                    -ConfiguredEnvironment $caseConfigured -Suffix required-input -ExpectFailure
            } finally { [Environment]::SetEnvironmentVariable('CARGO_HOME',$cargoHomePath) }
            $failurePattern = if ($damage.StartsWith('archive-')) { 'offline|archive|checksum|download' } else { 'offline|Git|git|object|revision' }
            Assert-GeneratedSourceRefusal ('required ' + $damage + ' cannot reach authenticated metadata admission') $failed $failurePattern
        }
        Assert-Check ('required ' + $damage + ' failure admits no canonical seed, source receipt, or project compilation') (
            -not [IO.Directory]::Exists($caseFixture.Parent + '/.cargo-home') -and
            -not [IO.File]::Exists($caseFixture.Parent + '/.cargo-home-required-input/.dsr-cargo-sources.json') -and
            -not [IO.File]::Exists($caseFixture.CompilerMarker))
    }
    if ($script:WindowsHost) {
        $nativeInput = Open-DsrCacheEntry $registryLib
        try {
            Assert-Refused 'native source read handle denies simultaneous writer' { $writer = [IO.FileStream]::new($registryLib,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite); $writer.Dispose() }
            Assert-Refused 'native source read handle denies replacement' { [IO.File]::Move($registryLib,($root + '/unexpected-move.rs')) }
        } finally { $nativeInput.Dispose() }
    }
    $retainedParent = $root + '/retained-registry'; [IO.Directory]::Move($registryRoot,$retainedParent)
    $link = if ($script:WindowsHost) { 'Junction' } else { 'SymbolicLink' }
    $null = New-Item -ItemType $link -Path $registryRoot -Target $retainedParent
    Assert-Refused 'registry source reparse cannot redirect authenticated reads' { Invoke-DsrCargoSources -Operation capture @badCapture } 'Linked|linked|special|reparse'
    # Keep the refused reparse fixture intact for inspection.
    Test-DsrLockedGitSubmodules
    Write-Output ('Source authentication checks: ' + $script:Checks + '; fixtures: ' + $root)
} finally {
    if ($null -ne $server) { $server.Dispose() }
    [Environment]::SetEnvironmentVariable('CARGO_HOME',$oldCargoHome)
    [Environment]::SetEnvironmentVariable('RUSTC_WRAPPER',$oldWrapper)
    [Environment]::SetEnvironmentVariable('RUSTC_WORKSPACE_WRAPPER',$oldWorkspaceWrapper)
}
