# One literal CMD context for strict native Windows Cargo metadata and builds.
# Functions only: the coordinator stages this beside cargo_cache_windows.ps1.
# This is deliberately NOT a general CMD parser or executable/linker attestor.

function Split-DsrCargoLiteralCommand {
    param([Parameter(Mandatory=$true)][string]$Command)
    # Percent expansion happens even inside quotes. Disallow shell constructs
    # everywhere, including quoted values, rather than guess their CMD meaning.
    if (-not $Command.Trim() -or $Command -match '[\x00-\x1f\x7f%!^&|<>()]') {
        throw 'Strict Windows Cargo commands must contain only literal foreground arguments'
    }
    $tokens = New-Object 'System.Collections.Generic.List[object]'
    $position = 0
    while ($position -lt $Command.Length) {
        while ($position -lt $Command.Length -and $Command[$position] -eq ' ') { $position++ }
        if ($position -eq $Command.Length) { break }
        $start = $position
        if ($Command[$position] -eq '"') {
            $position++; $valueStart = $position
            while ($position -lt $Command.Length -and $Command[$position] -ne '"') { $position++ }
            if ($position -eq $Command.Length) { throw 'Unclosed quote in Windows Cargo command' }
            $value = $Command.Substring($valueStart, $position - $valueStart)
            # A backslash before a closing quote has CRT escape semantics; the
            # bounded grammar does not interpret CRT escape/concatenation rules.
            if (-not $value -or $value.EndsWith('\')) { throw 'Ambiguous quoted Windows Cargo argument' }
            $position++
            if ($position -lt $Command.Length -and $Command[$position] -ne ' ') {
                throw 'Windows Cargo quotes must enclose an entire argument'
            }
        } else {
            while ($position -lt $Command.Length -and $Command[$position] -ne ' ') {
                if ($Command[$position] -eq '"') { throw 'Windows Cargo quotes must enclose an entire argument' }
                $position++
            }
            $value = $Command.Substring($start, $position - $start)
        }
        $tokens.Add([pscustomobject]@{Value=$value; Raw=$Command.Substring($start, $position - $start)})
    }
    return $tokens.ToArray()
}

function ConvertTo-DsrCargoLiteralArgument {
    param([Parameter(Mandatory=$true)][string]$Value)
    if (-not $Value -or $Value -match '[\x00-\x1f\x7f"%!^&|<>()]' -or $Value.EndsWith('\')) {
        throw 'Value cannot be represented as a literal Windows Cargo argument'
    }
    return '"' + $Value + '"'
}

function Test-DsrCargoSanitizedEnvironmentName {
    param([string]$Name)
    return $Name -match '^(CARGO_|RUST|XWIN_)' -or
        $Name -match '^DSR_RELEASE_GIT_(SHA|REF)$' -or
        $Name -match '^(CC|CXX|CPP|AR|RANLIB|LD|NM|OBJCOPY|STRIP|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS|BINDGEN_EXTRA_CLANG_ARGS|SDKROOT|MACOSX_DEPLOYMENT_TARGET|IPHONEOS_DEPLOYMENT_TARGET|INCLUDE|LIB|LIBPATH)(_|$)' -or
        $Name -match '_(CC|CXX|AR|RANLIB|CFLAGS|CXXFLAGS|LDFLAGS)$' -or
        $Name -match '^(OPENSSL_|.+_OPENSSL_|PKG_CONFIG($|_)|(HOST|TARGET)_PKG_CONFIG($|_)|.+_NO_PKG_CONFIG$|LIBCLANG_PATH$)'
}

function Test-DsrCargoContextEnvironmentName {
    param([string]$Name)
    return (Test-DsrCargoSanitizedEnvironmentName $Name) -or
        $Name -match '^(PATH|PATHEXT|COMSPEC|SYSTEMROOT|WINDIR|USERPROFILE|HOMEDRIVE|HOMEPATH|TEMP|TMP|NoDefaultCurrentDirectoryInExePath|RCH_DISABLED|RCH_CARGO_WRAPPER_BYPASS|PROCESSOR_ARCHITECTURE|PROCESSOR_ARCHITEW6432)$' -or
        $Name -match '^(VC|VS|WINDOWSSDK|UNIVERSALCRT|UCRT|FRAMEWORK|EXTENSIONSDK|VISUALSTUDIO|DEVENV|NETFXSDK|PROGRAMFILES)'
}

function Get-DsrCargoCmdPath {
    param($Environment)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'The Windows Cargo CMD launcher requires native Windows'
    }
    $cmdPath = Get-DsrCacheFullPath ([IO.Path]::Combine([Environment]::SystemDirectory, 'cmd.exe'))
    if ($Environment.ContainsKey('COMSPEC') -and $Environment['COMSPEC']) {
        $selected = Get-DsrCacheFullPath $Environment['COMSPEC']
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($selected, $cmdPath)) {
            throw 'Strict Windows Cargo requires the system cmd.exe as COMSPEC'
        }
    }
    return $cmdPath
}

function Get-DsrCargoContextSelection {
    param([string]$BuildCommand, [string]$SourceRoot, $Environment, [string]$ExpectedTarget='')
    $tokens = @(Split-DsrCargoLiteralCommand $BuildCommand)
    if ($tokens.Count -lt 2 -or $tokens[0].Value -notmatch '(?i)(^|[\\/])cargo(?:\.(?:exe|cmd|bat))?$') {
        throw 'Strict Windows Rust builds require a direct literal Cargo command'
    }
    $executable = $tokens[0].Value
    if ($executable.Contains(':') -and $executable -notmatch '^[A-Za-z]:[\\/][^:]+$') {
        throw 'Drive-relative, device, and alternate-stream Cargo selectors are forbidden'
    }
    if ($executable.StartsWith('\\') -or $executable.StartsWith('//')) {
        throw 'UNC and device Cargo selectors are forbidden'
    }
    $prefix = $tokens[0].Raw; $toolchain = ''; $index = 1
    if ($tokens[$index].Value.StartsWith('+')) {
        if ($tokens[$index].Value -cnotmatch '^\+[A-Za-z0-9][A-Za-z0-9_.-]*$') {
            throw 'Cargo toolchain selection must be a literal rustup toolchain name'
        }
        $toolchain = $tokens[$index].Value.Substring(1)
        $prefix += ' ' + $tokens[$index].Raw; $index++
    }
    if ($index -ge $tokens.Count -or $tokens[$index].Value -cnotin @('build','rustc')) {
        throw 'Strict Windows Cargo supports built-in build and rustc commands only'
    }
    $index++; $target = ''; $manifest = Join-Path $SourceRoot 'Cargo.toml'
    $sawTarget = $false; $sawManifest = $false
    # These options consume a separate value. Recognizing them prevents values
    # such as --target from being misread as a selector in malformed commands.
    $valueOptions = @('--package','-p','--exclude','--bin','--example','--test','--bench',
        '--profile','--jobs','-j','--features','-F','--target-dir','--message-format','--color')
    $switchOptions = @('--lib','--bins','--examples','--tests','--benches','--all-targets',
        '--workspace','--all','--release','-r','--all-features','--no-default-features',
        '--locked','--offline','--frozen','--verbose','-v','-vv','--quiet','-q','--timings',
        '--keep-going','--ignore-rust-version','--future-incompat-report')
    while ($index -lt $tokens.Count) {
        $argument = $tokens[$index].Value; $index++
        if ($argument -ceq '--' -or $argument -cmatch '^(-C|-Z|--config(?:=|$))') {
            throw 'Cargo context overrides and rustc argument tails are not supported by strict Windows builds'
        }
        $option = $argument; $value = $null
        if ($argument.Contains('=')) {
            $split = $argument.IndexOf('='); $option = $argument.Substring(0,$split); $value = $argument.Substring($split+1)
        }
        if ($option -cin @('--target','--manifest-path') -or $option -cin $valueOptions) {
            if ($null -eq $value) {
                if ($index -ge $tokens.Count -or $tokens[$index].Value.StartsWith('-')) {
                    throw 'Cargo build option is missing its literal value'
                }
                $value = $tokens[$index].Value; $index++
            }
            if (-not $value) { throw 'Cargo build option has an empty value' }
            if ($option -ceq '--target') {
                if ($sawTarget -or $value -cnotmatch '^[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+){2,}$') {
                    throw 'Strict Windows Cargo requires one literal target triple'
                }
                $target = $value; $sawTarget = $true
            } elseif ($option -ceq '--manifest-path') {
                if ($sawManifest) { throw 'Repeated Cargo manifest selectors are forbidden' }
                if ($value.Contains(':') -and $value -notmatch '^[A-Za-z]:[\\/][^:]+$') {
                    throw 'Ambiguous Cargo manifest path'
                }
                if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
                    [IO.Path]::IsPathRooted($value) -and $value -notmatch '^[A-Za-z]:[\\/]') {
                    throw 'Cargo manifest selectors must include their drive when rooted'
                }
                $candidate = if ([IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $SourceRoot $value }
                if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($candidate), [IO.Path]::GetFullPath($manifest))) {
                    throw 'Strict Windows Cargo must use the admitted source root manifest'
                }
                $sawManifest = $true
            }
        } elseif ($argument -cin $switchOptions) {
            continue
        } elseif ($argument -cmatch '^(-p|-j|-F)[^-].*$' -or $argument -cmatch '^--timings=(html|json)(,(html|json))*$') {
            continue
        } else {
            throw 'Unsupported Cargo build argument in strict Windows literal command'
        }
    }
    if (-not $target -and $Environment.ContainsKey('CARGO_BUILD_TARGET')) { $target = $Environment['CARGO_BUILD_TARGET'] }
    if ($target -and $target -cnotmatch '^[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+){2,}$') {
        throw 'Strict Windows Cargo requires a literal environment target triple'
    }
    if ($ExpectedTarget -and $ExpectedTarget -cnotmatch '^[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+){2,}$') { throw 'Invalid expected Cargo target' }
    if ($target -and $ExpectedTarget -and $target -cne $ExpectedTarget) { throw 'Cargo command target disagrees with the selected native variant' }
    # No explicit target means a conservative unfiltered metadata closure. Do
    # not invent a TOML parser or mistake the host triple for build.target.
    $metadata = $prefix + ' metadata --locked --offline --all-features --format-version 1'
    if ($target) { $metadata += ' --filter-platform ' + (ConvertTo-DsrCargoLiteralArgument $target) }
    $metadata += ' --manifest-path ' + (ConvertTo-DsrCargoLiteralArgument $manifest)
    return @{CargoPrefix=$prefix; Toolchain=$toolchain; Target=$target; MetadataCommand=$metadata}
}

function New-DsrCargoContextEnvironment {
    param(
        [Parameter(Mandatory=$true)][string]$CargoHome,
        [AllowEmptyCollection()][string[]]$Environment=@())
    $effective = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if (-not (Test-DsrCargoSanitizedEnvironmentName $entry.Key)) { $effective[$entry.Key] = [string]$entry.Value }
    }
    $configured = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($assignment in $Environment) {
        if ($assignment -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=([^\x00\r\n]*)$') { throw 'Invalid configured Windows Cargo environment assignment' }
        $name = $Matches[1]; $value = $Matches[2]
        # Managed values win and are not additional configured influences.
        if ($name -in @('CARGO_HOME','RCH_DISABLED','RCH_CARGO_WRAPPER_BYPASS')) { continue }
        $effective[$name] = $value; $null = $configured.Add($name.ToUpperInvariant())
    }
    $effective['CARGO_HOME'] = $CargoHome
    $effective['RCH_DISABLED'] = '1'; $effective['RCH_CARGO_WRAPPER_BYPASS'] = '1'
    return @{Environment=$effective; ConfiguredNames=@($configured)}
}

function New-DsrCargoContext {
    param([Parameter(Mandatory=$true)][string]$BuildCommand,
        [Parameter(Mandatory=$true)][string]$SourceRoot,
        [Parameter(Mandatory=$true)][string]$CargoHome,
        [AllowEmptyCollection()][string[]]$Environment=@(), [string]$ExpectedTarget='')
    $source = Get-DsrCacheFullPath $SourceRoot
    $homePath = Get-DsrCacheFullPath $CargoHome
    $environmentContext = New-DsrCargoContextEnvironment -CargoHome $homePath -Environment $Environment
    $effective = $environmentContext.Environment
    $cmdPath = Get-DsrCargoCmdPath -Environment $effective
    $effective['COMSPEC'] = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $cmdPath.Replace('/','\') } else { $cmdPath }
    $selection = Get-DsrCargoContextSelection -BuildCommand $BuildCommand -SourceRoot $source -Environment $effective -ExpectedTarget $ExpectedTarget
    $context = [pscustomobject]@{SourceRoot=$source; CargoHome=$homePath; CmdPath=$cmdPath;
        BuildCommand=$BuildCommand; MetadataCommand=$selection.MetadataCommand; CargoPrefix=$selection.CargoPrefix;
        Toolchain=$selection.Toolchain; Target=$selection.Target; Environment=$effective;
        ConfiguredNames=$environmentContext.ConfiguredNames; Fingerprint=''}
    $context.Fingerprint = Get-DsrCargoContextFingerprint $context
    return $context
}

function Get-DsrCargoContextInputs {
    param($Context)
    $paths = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    $null = $paths.Add((Join-Path $Context.SourceRoot 'Cargo.toml'))
    $null = $paths.Add((Join-Path $Context.SourceRoot 'Cargo.lock'))
    $current = [IO.DirectoryInfo]::new($Context.SourceRoot)
    while ($null -ne $current) {
        foreach ($name in @('.cargo/config','.cargo/config.toml','rust-toolchain','rust-toolchain.toml')) {
            $null = $paths.Add((Join-Path $current.FullName $name))
        }
        $current = $current.Parent
    }
    foreach ($name in @('config','config.toml')) { $null = $paths.Add((Join-Path $Context.CargoHome $name)) }
    $rustupHome = if ($Context.Environment.ContainsKey('RUSTUP_HOME')) { $Context.Environment['RUSTUP_HOME'] }
        elseif ($Context.Environment.ContainsKey('USERPROFILE')) { Join-Path $Context.Environment['USERPROFILE'] '.rustup' }
        else { '' }
    if ($rustupHome) { $null = $paths.Add((Join-Path $rustupHome 'settings.toml')) }
    $inputs = New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in $paths) {
        $normalized = Get-DsrCacheFullPath $path
        if (-not (Get-Item -LiteralPath $normalized -Force -ErrorAction SilentlyContinue)) {
            $inputs.Add(@{path=$normalized; sha256=$null}); continue
        }
        $guards = Open-DsrCachePathGuard (([IO.Path]::GetDirectoryName($normalized)).Replace('\','/'))
        $entry = $null; $stream = $null; $sha = $null
        try {
            $entry = Open-DsrCacheEntry $normalized
            $before = $entry.GetIdentity(); $stream = $entry.OpenRead()
            $sha = [Security.Cryptography.SHA256]::Create()
            $digest = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
            if ($entry.GetIdentity() -cne $before) { throw 'Cargo context input changed while hashing' }
            $inputs.Add(@{path=$normalized; sha256=$digest})
        } finally {
            if ($null -ne $sha) { $sha.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
            if ($null -ne $entry) { $entry.Dispose() }
            foreach ($guard in $guards) { $guard.Dispose() }
        }
    }
    return ,$inputs.ToArray()
}

function Get-DsrCargoContextDigests {
    param($Context)
    $influences = @{}
    foreach ($name in $Context.Environment.Keys) {
        if ((Test-DsrCargoContextEnvironmentName $name) -or $name -in $Context.ConfiguredNames) {
            $influences[$name.ToUpperInvariant()] = $Context.Environment[$name]
        }
    }
    $selection = @{source_root=$Context.SourceRoot; cargo_home=$Context.CargoHome; cmd_path=$Context.CmdPath;
        build_command=$Context.BuildCommand; metadata_command=$Context.MetadataCommand;
        cargo_prefix=$Context.CargoPrefix; toolchain=$Context.Toolchain; target=$Context.Target}
    $digests = @{}
    foreach ($item in @(@('selection',$selection), @('environment',$influences), @('inputs',(Get-DsrCargoContextInputs $Context)))) {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-DsrCacheCanonicalJson $item[1]) + "`n")
        $digests[$item[0] + '_sha256'] = Get-DsrCacheBytesHash $bytes
    }
    return $digests
}

function Get-DsrCargoContextFingerprint {
    param([Parameter(Mandatory=$true)]$Context)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-DsrCacheCanonicalJson (Get-DsrCargoContextDigests $Context)) + "`n")
    return Get-DsrCacheBytesHash $bytes
}

function Write-DsrCargoContextReceipt {
    param([Parameter(Mandatory=$true)]$Context, [Parameter(Mandatory=$true)][string]$Path)
    $digests = Get-DsrCargoContextDigests $Context
    $fingerprint = Get-DsrCacheBytesHash ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-DsrCacheCanonicalJson $digests) + "`n"))
    if ($fingerprint -cne $Context.Fingerprint) { throw 'Cargo context changed during metadata preparation' }
    $receipt = @{schema_version=1; fingerprint=$fingerprint; selection_sha256=$digests.selection_sha256;
        environment_sha256=$digests.environment_sha256; inputs_sha256=$digests.inputs_sha256}
    $digest = New-DsrCargoReceipt -Path (Get-DsrCacheFullPath $Path) -Value $receipt
    return @{schema_version=1; fingerprint=$fingerprint; receipt_sha256=$digest}
}

function Assert-DsrCargoContextReceipt {
    param([Parameter(Mandatory=$true)]$Context, [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Fingerprint, [Parameter(Mandatory=$true)][string]$ReceiptSha256)
    if ($Fingerprint -cnotmatch '^[0-9a-f]{64}$' -or $ReceiptSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid Cargo context admission digest' }
    $receipt = Read-DsrCargoReceipt -Path (Get-DsrCacheFullPath $Path)
    if ($receipt.sha256 -cne $ReceiptSha256 -or $receipt.value.schema_version -ne 1 -or
        $receipt.value.fingerprint -cne $Fingerprint -or $Context.Fingerprint -cne $Fingerprint -or
        (Get-DsrCargoContextFingerprint $Context) -cne $Fingerprint) { throw 'Admitted Windows Cargo context changed' }
}

function Invoke-DsrCargoCommand {
    param([Parameter(Mandatory=$true)]$Context, [Parameter(Mandatory=$true)][string]$Command, [bool]$CaptureOutput=$false)
    # Both operations use native CMD lookup, including PATHEXT, current-directory
    # rules and batch selectors. PowerShell command precedence is never involved.
    $psi = New-Object Diagnostics.ProcessStartInfo
    # Keep slash-normalized paths in receipts, but launch CMD with its native
    # spelling. CMD also scans its own command-line image token for switches;
    # a /cmd.exe component can be interpreted as /c instead of the image name.
    $psi.FileName = $Context.CmdPath.Replace('/','\'); $psi.WorkingDirectory = $Context.SourceRoot
    $psi.UseShellExecute = $false
    $psi.Arguments = '/d /v:off /s /c "' + $Command + '"'
    $psi.EnvironmentVariables.Clear()
    foreach ($name in $Context.Environment.Keys) { $psi.EnvironmentVariables[$name] = $Context.Environment[$name] }
    $psi.RedirectStandardOutput = $CaptureOutput; $psi.RedirectStandardError = $CaptureOutput
    if ($CaptureOutput) {
        $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw 'Failed to start native Cargo CMD launcher' }
        if ($CaptureOutput) {
            # Drain concurrently: Cargo can fill stderr while metadata fills stdout.
            $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        }
        $process.WaitForExit()
        $stdout = ''; $stderr = ''
        if ($CaptureOutput) { $stdout = $stdoutTask.GetAwaiter().GetResult(); $stderr = $stderrTask.GetAwaiter().GetResult() }
        return [pscustomobject]@{ExitCode=$process.ExitCode; Stdout=$stdout; Stderr=$stderr}
    } finally { $process.Dispose() }
}

function Invoke-DsrCargoContext {
    param([Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][ValidateSet('Metadata','Build')][string]$Operation, [switch]$CaptureOutput)
    if ((Get-DsrCargoContextFingerprint $Context) -cne $Context.Fingerprint) { throw 'Windows Cargo context changed before launch' }
    $command = if ($Operation -eq 'Metadata') { $Context.MetadataCommand } else { $Context.BuildCommand }
    return Invoke-DsrCargoCommand -Context $Context -Command $command -CaptureOutput ($CaptureOutput.IsPresent -or $Operation -eq 'Metadata')
}
