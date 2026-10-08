# One literal CMD context for strict native Windows Cargo metadata and builds.
# Functions only: the coordinator stages this beside cargo_cache_windows.ps1.
# The command and Cargo configuration grammars are deliberately bounded. Tool
# identities are measured in this context, never in the coordinator's shell.

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
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
        [IO.Path]::IsPathRooted($executable) -and $executable -notmatch '^[A-Za-z]:[\\/]') {
        throw 'Rooted Cargo selectors must include their drive'
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
                if (-not [StringComparer]::Ordinal.Equals([IO.Path]::GetFullPath($candidate), [IO.Path]::GetFullPath($manifest))) {
                    # NTFS can enable case sensitivity per directory. A
                    # spelling alias must designate both the same directory
                    # and the same file; a hardlinked manifest elsewhere can
                    # still select different src files and relative crates.
                    $candidatePath=Get-DsrCacheFullPath ([IO.Path]::GetFullPath($candidate))
                    $manifestPath=Get-DsrCacheFullPath ([IO.Path]::GetFullPath($manifest))
                    $candidateGuards=@(); $manifestGuards=@(); $candidateEntry=$null; $manifestEntry=$null
                    try {
                        $candidateGuards=Open-DsrCachePathGuard (([IO.Path]::GetDirectoryName($candidatePath)).Replace('\','/'))
                        $manifestGuards=Open-DsrCachePathGuard (([IO.Path]::GetDirectoryName($manifestPath)).Replace('\','/'))
                        $candidateEntry=Open-DsrCacheEntry $candidatePath; $manifestEntry=Open-DsrCacheEntry $manifestPath
                        if ($candidateGuards[$candidateGuards.Count-1].FileId -cne $manifestGuards[$manifestGuards.Count-1].FileId -or
                            $candidateEntry.FileId -cne $manifestEntry.FileId) {
                            throw 'Strict Windows Cargo must use the admitted physical source root manifest'
                        }
                    } finally {
                        if ($null -ne $candidateEntry) { $candidateEntry.Dispose() }; if ($null -ne $manifestEntry) { $manifestEntry.Dispose() }
                        foreach ($guard in $candidateGuards) { $guard.Dispose() }; foreach ($guard in $manifestGuards) { $guard.Dispose() }
                    }
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
    return @{CargoPrefix=$prefix; CargoProgram=$executable; Toolchain=$toolchain; Target=$target; MetadataCommand=$metadata}
}

function ConvertFrom-DsrCargoConfigString {
    param([string]$Value)
    if ($Value -cmatch "^'([^'\x00-\x1f]*)'$") { return $Matches[1] }
    if ($Value -cnotmatch '^"(?:[^"\\\x00-\x1f]|\\["\\bfnrt]|\\u[0-9A-Fa-f]{4})*"$') {
        throw 'Unsupported Cargo configuration string; use a single-line literal string'
    }
    return ConvertFrom-Json -InputObject $Value -ErrorAction Stop
}

function Get-DsrCargoToolConfiguration {
    param($Context)
    # This is an admission grammar, not a general TOML parser. Every byte of
    # every admitted statement is consumed. Unsupported syntax fails before
    # Cargo runs, so dotted keys, inline tables, cfg selectors, includes and
    # environment indirection cannot hide a compiler or linker override.
    $config = @{build=@{}; target=(New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)); receipts=@()}
    $directories = New-Object 'System.Collections.Generic.List[string]'
    $current = [IO.DirectoryInfo]::new($Context.SourceRoot)
    while ($null -ne $current) { $directories.Insert(0,(Get-DsrCacheFullPath $current.FullName)); $current=$current.Parent }
    foreach ($directory in $directories) {
        $path = Join-Path $directory '.cargo/config'
        if (-not (Test-Path -LiteralPath $path)) { $path = Join-Path $directory '.cargo/config.toml' }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $path = Get-DsrCacheFullPath $path
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($directory,$Context.SourceRoot)) {
            throw 'Untracked ancestor Cargo config is forbidden'
        }
        $rawBytes = [IO.File]::ReadAllBytes($path)
        $raw = [Text.UTF8Encoding]::new($false,$true).GetString($rawBytes)
        if ($raw.Length -gt 1048576) { throw 'Cargo configuration exceeds the bounded attestation limit' }
        $section=''; $target=''; $pending=''; $keys=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($line in ($raw -split '\r?\n')) {
            $quote=[char]0; $escape=$false; $end=$line.Length
            for ($i=0; $i -lt $line.Length; $i++) {
                $character=$line[$i]
                if ($escape) { $escape=$false; continue }
                if ($quote -eq '"' -and $character -eq '\') { $escape=$true; continue }
                if ($quote -ne [char]0) { if ($character -eq $quote) { $quote=[char]0 }; continue }
                if ($character -eq '"' -or $character -eq "'") { $quote=$character }
                elseif ($character -eq '#') { $end=$i; break }
            }
            if ($quote -ne [char]0) { throw 'Multiline Cargo configuration strings are not attested' }
            $statement=$line.Substring(0,$end).Trim()
            if (-not $statement) { continue }
            if ($pending) { $statement=$pending + ' ' + $statement; $pending='' }
            if ($statement -cmatch '^([A-Za-z0-9_-]+)\s*=\s*\[' -and -not $statement.EndsWith(']')) {
                $pending=$statement; continue
            }
            if ($statement -cmatch '^\[\s*(build|net|term|registry|env)\s*\]$') {
                $section=$Matches[1]; $target=''; continue
            }
            if ($statement -cmatch '^\[\s*(target|source|registries)\s*\.\s*("(?:[^"\\]|\\.)*"|''[^'']*''|[A-Za-z0-9_-]+)\s*\]$') {
                $section=$Matches[1]; $target=$Matches[2]
                if ($target.StartsWith('"') -or $target.StartsWith("'")) { $target=ConvertFrom-DsrCargoConfigString $target }
                if ($target -cnotmatch '^[A-Za-z0-9_-]+$') { throw 'Cargo cfg and dynamic target configuration are not attested' }
                if ($section -eq 'target' -and -not $config.target.ContainsKey($target)) { $config.target[$target]=@{} }
                continue
            }
            if ($statement -cnotmatch '^([A-Za-z0-9_-]+)\s*=\s*(.+)$' -or -not $section) {
                throw 'Unsupported Cargo configuration syntax in strict Windows toolchain attestation'
            }
            $key=$Matches[1]; $text=$Matches[2].Trim()
            if (-not $keys.Add($section + '.' + $target + '.' + $key)) { throw 'Repeated Cargo configuration key' }
            $allowed = switch ($section) {
                build { @('jobs','target','target-dir','incremental','rustc','rustc-wrapper','rustc-workspace-wrapper','rustflags') }
                target { @('linker','rustflags','runner') }
                source { @('registry','local-registry','directory','git','branch','tag','rev','replace-with') }
                registries { @('index','protocol') }
                net { @('offline','retry','git-fetch-with-cli') }
                term { @('color','verbose','quiet') }
                registry { @('default') }
                env { @('RUST_MIN_STACK') }
            }
            if ($key -cnotin $allowed) { throw ('Unsupported Cargo configuration selector: ' + $section + '.' + $key) }
            $value=$null
            if ($text.StartsWith('[')) {
                if ($key -cnotin @('rustflags','runner') -or -not $text.EndsWith(']')) { throw 'Unsupported Cargo configuration array' }
                $values=New-Object 'System.Collections.Generic.List[string]'; $rest=$text.Substring(1,$text.Length-2).Trim()
                while ($rest) {
                    if ($rest -cnotmatch '^("(?:[^"\\\x00-\x1f]|\\["\\bfnrt]|\\u[0-9A-Fa-f]{4})*"|''[^''\x00-\x1f]*'')\s*(,\s*|$)') { throw 'Cargo configuration arrays must contain literal strings only' }
                    $matched=$Matches[0]; $values.Add((ConvertFrom-DsrCargoConfigString $Matches[1])); $rest=$rest.Substring($matched.Length)
                }
                $value=$values.ToArray()
            } elseif ($text -cmatch '^-?[0-9]+$' -or $text -cin @('true','false')) {
                if ($key -cnotin @('jobs','incremental','offline','retry','git-fetch-with-cli','verbose','quiet')) { throw 'Cargo executable selectors require literal strings' }
                $value=$text
            } else { $value=ConvertFrom-DsrCargoConfigString $text }
            if ($section -eq 'env' -and ($value -isnot [string] -or $value -cnotmatch '^[1-9][0-9]*$')) {
                throw 'Cargo configuration environment changes are not attested'
            }
            if (($section -eq 'build' -and $key -in @('rustc','rustc-wrapper','rustc-workspace-wrapper')) -or
                ($section -eq 'target' -and $key -eq 'linker')) {
                if ($value -isnot [string] -or -not $value) { throw 'Cargo executable selectors require nonempty literal strings' }
                if ($value -match '[\\/]' -and -not [IO.Path]::IsPathRooted($value)) { $value=[IO.Path]::GetFullPath((Join-Path $directory $value)) }
            }
            if ($section -eq 'build') { $config.build[$key]=$value }
            elseif ($section -eq 'target') { $config.target[$target][$key]=$value }
        }
        if ($pending) { throw 'Unfinished Cargo configuration array' }
        $configDigest=Get-DsrCacheBytesHash $rawBytes
        if ((Get-DsrCargoToolFileHash $path) -cne $configDigest) { throw 'Cargo configuration changed while parsing executable selection' }
        $config.receipts += @{path=$path; sha256=$configDigest}
    }
    return $config
}

function Resolve-DsrCargoPhysicalToolPath {
    param([string]$Path)
    # Tool installations legitimately contain rustup aliases and file links.
    # Resolve them explicitly; the cache handle guards then pin only the final
    # physical path while its bytes are read.
    $full=[IO.Path]::GetFullPath($Path); $root=[IO.Path]::GetPathRoot($full); $current=$root
    foreach ($part in $full.Substring($root.Length).Split([char[]]@('/','\'),[StringSplitOptions]::RemoveEmptyEntries)) {
        $current=Join-Path $current $part
        $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $resolved=$item.ResolveLinkTarget($true)
            if ($null -eq $resolved) { throw 'Unable to resolve selected executable link' }
            $current=$resolved.FullName
        }
    }
    return Get-DsrCacheFullPath $current
}

function Get-DsrCargoToolFileHash {
    param([string]$Path)
    $physical=Resolve-DsrCargoPhysicalToolPath $Path
    $guards=Open-DsrCachePathGuard (([IO.Path]::GetDirectoryName($physical)).Replace('\','/')); $entry=$null; $stream=$null; $sha=$null
    try {
        $entry=Open-DsrCacheEntry $physical; $before=$entry.GetIdentity(); $stream=$entry.OpenRead(); $sha=[Security.Cryptography.SHA256]::Create()
        $digest=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
        if ($entry.GetIdentity() -cne $before -or (Resolve-DsrCargoPhysicalToolPath $Path) -cne $physical) { throw 'Selected executable changed while hashing' }
        return $digest
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }; if ($null -ne $stream) { $stream.Dispose() }; if ($null -ne $entry) { $entry.Dispose() }
        foreach ($guard in $guards) { $guard.Dispose() }
    }
}

function Resolve-DsrCargoTool {
    param($Context,[string]$Program,[switch]$CargoLookup,[switch]$Optional)
    if (-not $Program -or $Program -match '[\x00-\x1f"%!*?<>|]' -or
        ($Program.Contains(':') -and $Program -notmatch '^[A-Za-z]:[\\/][^:]+$') -or $Program.StartsWith('\\')) {
        throw 'Ambiguous executable selector in Windows Cargo context'
    }
    $native=[Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    if ($native -and [IO.Path]::IsPathRooted($Program) -and $Program -notmatch '^[A-Za-z]:[\\/]') { throw 'Rooted executable selectors must include their drive' }
    $hasPath=$Program -match '[\\/]' -or [IO.Path]::IsPathRooted($Program)
    $directories=New-Object 'System.Collections.Generic.List[string]'
    if ($hasPath) { $directories.Add($Context.SourceRoot) }
    else {
        # CMD respects NoDefaultCurrentDirectoryInExePath by presence, even
        # when its value is zero. Rust does not use CMD's implicit cwd lookup.
        if ($CargoLookup -and $native -and -not $Context.Environment.ContainsKey('NoDefaultCurrentDirectoryInExePath')) { $directories.Add($Context.SourceRoot) }
        if ($Context.Environment.ContainsKey('PATH')) {
            foreach ($directory in $Context.Environment['PATH'].Split([IO.Path]::PathSeparator)) {
                if (-not $directory) {
                    if ($CargoLookup -and $native -and $Context.Environment.ContainsKey('NoDefaultCurrentDirectoryInExePath')) { throw 'Empty PATH entries with disabled CMD cwd lookup are ambiguous' }
                    continue
                }
                if ($directory.StartsWith('"') -and $directory.EndsWith('"')) { $directory=$directory.Substring(1,$directory.Length-2) }
                if ($directory.Contains('"') -or -not [IO.Path]::IsPathRooted($directory) -or
                    ($native -and $directory -notmatch '^[A-Za-z]:[\\/]')) {
                    throw 'Executable attestation requires literal absolute PATH entries'
                }
                $directories.Add($directory)
            }
        }
    }
    $extensions=@('')
    if ($native -and -not [IO.Path]::GetExtension($Program)) {
        if ($CargoLookup) {
            $pathExt=if ($Context.Environment.ContainsKey('PATHEXT')) { $Context.Environment['PATHEXT'] } else { '.COM;.EXE;.BAT;.CMD' }
            $extensions=@($pathExt.Split(';'))
            if ($extensions.Count -eq 0 -or @($extensions | Where-Object { $_ -notmatch '^\.[A-Za-z0-9]+$' }).Count) { throw 'Ambiguous PATHEXT in Windows Cargo context' }
        } else { $extensions=@('.exe') }
    }
    foreach ($directory in $directories) {
        foreach ($extension in $extensions) {
            $path=if ([IO.Path]::IsPathRooted($Program)) { $Program+$extension } else { Join-Path $directory ($Program+$extension) }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $path=Get-DsrCacheFullPath ([IO.Path]::GetFullPath($path))
            if ([IO.Path]::GetExtension($path) -in @('.cmd','.bat','.ps1')) { throw 'Cargo and compiler script wrappers are outside executable attestation' }
            if ($native -and [IO.Path]::GetExtension($path) -notin @('.exe','.com')) { throw 'Windows file-association wrappers are outside executable attestation' }
            return $path
        }
    }
    if ($Optional) { return '' }
    throw ('Required toolchain executable was not found: ' + $Program)
}

function ConvertTo-DsrCargoProbeArgument {
    param([string]$Value)
    # Unlike user-supplied shell text these are single, already resolved probe
    # arguments. Quoted parentheses are needed for Program Files (x86).
    if (-not $Value -or $Value -match '[\x00-\x1f\x7f"%!^&|<>]' -or $Value.EndsWith('\')) { throw 'Unrepresentable executable probe argument' }
    return '"' + $Value + '"'
}

function Invoke-DsrCargoToolProbe {
    param($Context,[string]$Program,[string[]]$Arguments,[switch]$AllowFailure)
    $words=@((ConvertTo-DsrCargoProbeArgument $Program))
    foreach ($argument in $Arguments) { $words+=ConvertTo-DsrCargoProbeArgument $argument }
    $bounded=[pscustomobject]@{SourceRoot=$Context.SourceRoot; CmdPath=$Context.CmdPath;
        Environment=$Context.Environment; ProbeTimeoutMilliseconds=60000}
    $result=Invoke-DsrCargoCommand -Context $bounded -Command ($words -join ' ') -CaptureOutput $true
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) { throw ('Toolchain executable probe failed: ' + $Program + ': ' + $result.Stderr.Trim()) }
    return $result
}

function Get-DsrCargoExecutableIdentity {
    param($Context,[string]$Program,[string[]]$VersionArguments,[string]$RustupPath='',
        [string]$RustupHash='', [string]$RustupTool='', [switch]$CargoLookup)
    $selected=Resolve-DsrCargoTool -Context $Context -Program $Program -CargoLookup:$CargoLookup
    $physical=Resolve-DsrCargoPhysicalToolPath $selected
    $sha=Get-DsrCargoToolFileHash $selected
    $magic=[IO.File]::OpenRead($physical)
    try {
        $first=$magic.ReadByte(); $second=$magic.ReadByte()
        if ($first -eq 35 -and $second -eq 33) { throw 'Unresolved executable script wrappers are not attested' }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and ($first -ne 77 -or $second -ne 90)) { throw 'Selected Windows tool is not a native executable' }
    } finally { $magic.Dispose() }
    $versionResult=Invoke-DsrCargoToolProbe -Context $Context -Program $selected -Arguments $VersionArguments
    $version=($versionResult.Stdout+$versionResult.Stderr).Trim()
    if (-not $version) { throw ('Executable did not report a version: ' + $selected) }
    $record=@{program=$Program; selected_path=$selected; selected_sha256=$sha; selected_kind='executable'; version=$version}
    $resolved=$physical; $router=$RustupPath; $routerContext=$Context
    $isRustup=$RustupTool -and $RustupPath -and $sha -ceq $RustupHash
    if ($RustupTool -and -not $isRustup) {
        # A copied proxy can work without rustup on PATH, or alongside a
        # different rustup version. Rustup documents FORCE_ARG0 for testing its
        # multicall dispatch: https://rust-lang.github.io/rustup/dev-guide/tips-and-tricks.html
        # Use it only in this private identity probe; the
        # actual version and every build keep the admitted environment.
        $routerEnvironment=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $Context.Environment.Keys) { $routerEnvironment[$name]=$Context.Environment[$name] }
        $routerEnvironment['RUSTUP_FORCE_ARG0']='rustup'
        $routerContext=[pscustomobject]@{SourceRoot=$Context.SourceRoot; CmdPath=$Context.CmdPath;
            Environment=$routerEnvironment; Toolchain=$Context.Toolchain}
        $routerVersion=Invoke-DsrCargoToolProbe -Context $routerContext -Program $selected -Arguments @('--version') -AllowFailure
        $isRustup=$routerVersion.ExitCode -eq 0 -and $routerVersion.Stdout.Trim() -cmatch '^rustup [0-9]+\.[0-9]+\.[0-9]+(?:[-+ ][^\r\n]*)?$'
        $router=$selected
    }
    if ($isRustup) {
        $arguments=@('which')
        if ($Context.Toolchain) { $arguments+=@('--toolchain',$Context.Toolchain) }
        $arguments+=$RustupTool
        $which=Invoke-DsrCargoToolProbe -Context $routerContext -Program $router -Arguments $arguments
        $candidate=$which.Stdout.Trim()
        if (-not [IO.Path]::IsPathRooted($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'Rustup did not resolve the selected executable' }
        $resolved=Resolve-DsrCargoPhysicalToolPath $candidate
        if ($resolved -ceq $physical) { throw 'Rustup proxy resolved back to itself' }
    } elseif ($CargoLookup -and $Context.Toolchain) {
        throw 'An explicit +toolchain requires a proven rustup Cargo proxy'
    }
    if ($resolved -cne $selected) {
        $magic=[IO.File]::OpenRead($resolved)
        try {
            $first=$magic.ReadByte(); $second=$magic.ReadByte()
            if (($first -eq 35 -and $second -eq 33) -or
                ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and ($first -ne 77 -or $second -ne 90))) {
                throw 'Rustup resolved an unsupported executable wrapper'
            }
        } finally { $magic.Dispose() }
        $record.resolved_path=$resolved; $record.resolved_sha256=Get-DsrCargoToolFileHash $resolved; $record.resolved_kind='executable'
    }
    if ((Get-DsrCargoToolFileHash $selected) -cne $sha) { throw 'Toolchain executable changed during its version probe' }
    return $record
}

function Get-DsrCargoPrintedLinker {
    param([string]$Output,$Context)
    # rustc --print link-args prints Rust's quoted Command representation.
    # Consume environment assignments, then exactly the program token. Never
    # evaluate this diagnostic text as CMD or PowerShell source.
    $remaining=$Output.Trim(); $quoted='"(?:[^"\\\x00-\x1f]|\\["\\bfnrt]|\\u[0-9A-Fa-f]{4})*"'
    $linkEnvironment=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Context.Environment.Keys) { $linkEnvironment[$name]=$Context.Environment[$name] }
    while ($remaining -cmatch ('^([A-Za-z_][A-Za-z0-9_]*)=('+$quoted+')\s+')) {
        $matchText=$Matches[0]; $linkEnvironment[$Matches[1]]=ConvertFrom-Json $Matches[2]; $remaining=$remaining.Substring($matchText.Length)
    }
    if ($remaining -cnotmatch ('^('+$quoted+')\s+')) { throw 'Unable to attest rustc default linker command; configure an absolute target linker' }
    $program=ConvertFrom-Json $Matches[1]
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and -not [IO.Path]::IsPathRooted($program)) {
        # Windows' Rust Command formatter does not include its child PATH.
        # An absolute MSVC discovery result is authoritative; a bare GNU/LLD
        # driver needs an explicit absolute target-linker configuration.
        throw 'Rustc did not report an absolute Windows linker; configure an absolute target linker'
    }
    $lookup=[pscustomobject]@{SourceRoot=$Context.SourceRoot; Environment=$linkEnvironment; CmdPath=$Context.CmdPath; Toolchain=$Context.Toolchain}
    return @{program=(Resolve-DsrCargoTool -Context $lookup -Program $program); context=$lookup}
}

function Get-DsrCargoToolchainIdentity {
    param($Context)
    $config=Get-DsrCargoToolConfiguration $Context
    if ($Context.Environment.ContainsKey('RUSTUP_FORCE_ARG0')) { throw 'Configured Rustup dispatch overrides are outside executable attestation' }
    foreach ($key in @('RUSTC_WRAPPER','RUSTC_WORKSPACE_WRAPPER','CARGO_BUILD_RUSTC_WRAPPER','CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER')) {
        if ($Context.Environment.ContainsKey($key) -and $Context.Environment[$key]) { throw ('Unresolved compiler wrapper cannot be attested: ' + $key) }
    }
    foreach ($key in @('rustc-wrapper','rustc-workspace-wrapper')) {
        if ($config.build.ContainsKey($key) -and $config.build[$key]) { throw ('Unresolved Cargo compiler wrapper cannot be attested: ' + $key) }
    }
    foreach ($name in $Context.Environment.Keys) {
        if ($name -match '^CARGO_UNSTABLE_' -and $Context.Environment[$name]) { throw 'Unstable Cargo selector environments are outside Windows toolchain attestation' }
    }
    $effective=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Context.Environment.Keys) { $effective[$name]=$Context.Environment[$name] }
    if ($Context.Toolchain) { $effective['RUSTUP_TOOLCHAIN']=$Context.Toolchain }
    $probe=[pscustomobject]@{SourceRoot=$Context.SourceRoot; CargoHome=$Context.CargoHome; CmdPath=$Context.CmdPath; Environment=$effective; Toolchain=$Context.Toolchain}
    $rustupPath=Resolve-DsrCargoTool -Context $probe -Program rustup -Optional
    $rustupHash=if ($rustupPath) { Get-DsrCargoToolFileHash $rustupPath } else { '' }
    $cargoArgs=@(); if ($Context.Toolchain) { $cargoArgs+='+'+$Context.Toolchain }; $cargoArgs+='-vV'
    $cargo=Get-DsrCargoExecutableIdentity -Context $probe -Program $Context.CargoProgram -VersionArguments $cargoArgs -RustupPath $rustupPath -RustupHash $rustupHash -RustupTool cargo -CargoLookup
    if ($cargo.version -cnotmatch '^cargo [0-9]+\.') { throw 'Selected executable does not report a Cargo version' }
    $compiler='rustc'; $compilerConfigured=$false
    if ($config.build.ContainsKey('rustc')) { $compiler=$config.build.rustc; $compilerConfigured=$true }
    foreach ($name in @('CARGO_BUILD_RUSTC','RUSTC')) { if ($effective.ContainsKey($name) -and $effective[$name]) { $compiler=$effective[$name]; $compilerConfigured=$true } }
    if ($compilerConfigured -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and -not [IO.Path]::IsPathRooted($compiler)) {
        throw 'Configured Windows rustc must use an absolute or config-relative executable path'
    }
    $rustc=Get-DsrCargoExecutableIdentity -Context $probe -Program $compiler -VersionArguments @('-vV') -RustupPath $rustupPath -RustupHash $rustupHash -RustupTool rustc
    if (-not $compilerConfigured -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        # Cargo versions may resolve rustc beside their own executable rather
        # than through a rustup PATH proxy. Both must identify the same actual
        # compiler; refuse differing installations instead of guessing.
        $cargoPhysical=if ($cargo.ContainsKey('resolved_path')) { $cargo.resolved_path } else { Resolve-DsrCargoPhysicalToolPath $cargo.selected_path }
        $rustcPhysical=if ($rustc.ContainsKey('resolved_path')) { $rustc.resolved_path } else { Resolve-DsrCargoPhysicalToolPath $rustc.selected_path }
        $rustcHash=Get-DsrCargoToolFileHash $rustcPhysical
        foreach ($directory in @($Context.SourceRoot,[IO.Path]::GetDirectoryName($cargoPhysical),[Environment]::SystemDirectory,[Environment]::GetFolderPath('Windows'))) {
            if (-not $directory) { continue }
            $candidate=Join-Path $directory 'rustc.exe'
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Get-DsrCargoToolFileHash $candidate) -cne $rustcHash) {
                throw 'Ambiguous native Cargo compiler lookup; configure an absolute RUSTC executable'
            }
        }
    }
    if ($rustc.version -cnotmatch '(?m)^host: ([A-Za-z0-9_]+(?:-[A-Za-z0-9_]+){2,})\r?$') { throw 'Selected compiler did not report its host target' }
    $hostTriple=$Matches[1]; $triple=$Context.Target
    if (-not $triple -and $config.build.ContainsKey('target')) { $triple=$config.build.target }
    if (-not $triple) { $triple=$hostTriple }
    if ($triple -isnot [string] -or $triple -cnotmatch '^[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+){2,}$') { throw 'Cargo target must be a literal target triple' }
    $linkerVariable='CARGO_TARGET_' + ($triple.ToUpperInvariant() -replace '[^A-Z0-9]','_') + '_LINKER'
    $linker=''
    if ($config.target.ContainsKey($triple) -and $config.target[$triple].ContainsKey('linker')) { $linker=$config.target[$triple].linker }
    if ($effective.ContainsKey($linkerVariable) -and $effective[$linkerVariable]) { $linker=$effective[$linkerVariable] }
    if ($linker -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and -not [IO.Path]::IsPathRooted($linker)) {
        throw 'Configured Windows linker must use an absolute or config-relative executable path'
    }
    $flags=New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $effective.Keys) { if ($name -match 'RUSTFLAGS$') { $flags.Add($effective[$name]) } }
    if ($config.build.ContainsKey('rustflags')) { $flags.Add(($config.build.rustflags -join ' ')) }
    foreach ($targetConfig in $config.target.Values) { if ($targetConfig.ContainsKey('rustflags')) { $flags.Add(($targetConfig.rustflags -join ' ')) } }
    foreach ($text in $flags) {
        if ($text -match '(?i)(linker|link-self-contained|codegen-backend|gcc-ld|sysroot|--target|@)') {
            throw 'Rustflags can change executable selection; configure an explicit Cargo target linker and compiler'
        }
    }
    $tools=@{cargo=$cargo; rustc=$rustc}
    $linkerContext=$probe
    if (-not $linker) {
        # Ask the selected rustc to perform a real tiny link. On MSVC this
        # discovers Visual Studio's linker even when PATH contains another
        # link.exe. All generated bytes stay outside the source and cache.
        $parent=[IO.Path]::GetDirectoryName($Context.CargoHome)
        $probeRoot=Join-Path $parent ('.dsr-toolchain-probe-' + [Guid]::NewGuid().ToString('N'))
        if (Test-DsrCacheInside $probeRoot $Context.SourceRoot) { throw 'Toolchain probe storage must be outside the source snapshot' }
        $null=[IO.Directory]::CreateDirectory($probeRoot)
        $probeSource=Join-Path $probeRoot 'main.rs'
        [IO.File]::WriteAllText($probeSource,'fn main() {}',[Text.UTF8Encoding]::new($false))
        $arguments=@('--crate-name','dsr_toolchain_probe','--edition=2021','--crate-type=bin','--target',$triple,'--print=link-args',$probeSource,'-o',(Join-Path $probeRoot 'probe.exe'))
        $result=Invoke-DsrCargoToolProbe -Context $probe -Program $rustc.selected_path -Arguments $arguments
        $printed=Get-DsrCargoPrintedLinker -Output $result.Stdout -Context $probe
        $linker=$printed.program; $linkerContext=$printed.context
    }
    $linkerPath=Resolve-DsrCargoTool -Context $linkerContext -Program $linker
    $versionArgs=if ([IO.Path]::GetFileName($linkerPath) -ieq 'link.exe') { @('/?') } else { @('--version') }
    $tools.linker=Get-DsrCargoExecutableIdentity -Context $linkerContext -Program $linkerPath -VersionArguments $versionArgs
    $tools.linker.version=($tools.linker.version -split '\r?\n')[0]
    # Command plugins are excluded by the literal invocation parser. State
    # that boundary explicitly; an unused cargo-build.exe is not provenance.
    return @{schema_version=1; cwd=$Context.SourceRoot; target_triple=$triple;
        linker_variable=$(if ($effective.ContainsKey($linkerVariable)) { $linkerVariable } else { $null }); tools=$tools;
        selection=@{rustup_toolchain=$(if ($Context.Toolchain) { $Context.Toolchain } elseif ($effective.ContainsKey('RUSTUP_TOOLCHAIN')) { $effective['RUSTUP_TOOLCHAIN'] } else { $null });
            cargo_commands=@((@((Split-DsrCargoLiteralCommand $Context.BuildCommand) | Where-Object { $_.Value -cin @('build','rustc') })[0].Value)); cargo_config=$config.receipts}}
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
        CargoProgram=$selection.CargoProgram; Toolchain=$selection.Toolchain; Target=$selection.Target; Environment=$effective;
        ConfiguredNames=$environmentContext.ConfiguredNames; ToolchainIdentity=$null; Fingerprint=''}
    $context.ToolchainIdentity = Get-DsrCargoToolchainIdentity $context
    if ($ExpectedTarget -and $context.ToolchainIdentity.target_triple -cne $ExpectedTarget) { throw 'Cargo configuration target disagrees with the selected native variant' }
    $context.Fingerprint = Get-DsrCargoContextFingerprint $context -UseRecordedToolchain
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
    param($Context,[switch]$UseRecordedToolchain)
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
    $identity=if ($UseRecordedToolchain) { $Context.ToolchainIdentity } else { Get-DsrCargoToolchainIdentity $Context }
    $digests.toolchain_sha256=Get-DsrCacheBytesHash ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-DsrCacheCanonicalJson $identity) + "`n"))
    return $digests
}

function Get-DsrCargoContextFingerprint {
    param([Parameter(Mandatory=$true)]$Context,[switch]$UseRecordedToolchain)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-DsrCacheCanonicalJson (Get-DsrCargoContextDigests $Context -UseRecordedToolchain:$UseRecordedToolchain)) + "`n")
    return Get-DsrCacheBytesHash $bytes
}

function Write-DsrCargoContextReceipt {
    param([Parameter(Mandatory=$true)]$Context, [Parameter(Mandatory=$true)][string]$Path)
    $digests = Get-DsrCargoContextDigests $Context
    $fingerprint = Get-DsrCacheBytesHash ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-DsrCacheCanonicalJson $digests) + "`n"))
    $recordedToolchainHash=Get-DsrCacheBytesHash ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-DsrCacheCanonicalJson $Context.ToolchainIdentity) + "`n"))
    if ($fingerprint -cne $Context.Fingerprint -or $recordedToolchainHash -cne $digests.toolchain_sha256) { throw 'Cargo context changed during metadata preparation' }
    $receipt = @{schema_version=1; fingerprint=$fingerprint; selection_sha256=$digests.selection_sha256;
        environment_sha256=$digests.environment_sha256; inputs_sha256=$digests.inputs_sha256;
        toolchain_sha256=$digests.toolchain_sha256; toolchain=$Context.ToolchainIdentity}
    $digest = New-DsrCargoReceipt -Path (Get-DsrCacheFullPath $Path) -Value $receipt
    return @{schema_version=1; fingerprint=$fingerprint; receipt_sha256=$digest; toolchain=$Context.ToolchainIdentity}
}

function Assert-DsrCargoContextReceipt {
    param([Parameter(Mandatory=$true)]$Context, [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Fingerprint, [Parameter(Mandatory=$true)][string]$ReceiptSha256)
    if ($Fingerprint -cnotmatch '^[0-9a-f]{64}$' -or $ReceiptSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid Cargo context admission digest' }
    $receipt = Read-DsrCargoReceipt -Path (Get-DsrCacheFullPath $Path)
    if ($receipt.sha256 -cne $ReceiptSha256 -or $receipt.value.schema_version -ne 1 -or
        $receipt.value.fingerprint -cne $Fingerprint -or $Context.Fingerprint -cne $Fingerprint -or
        (ConvertTo-DsrCacheCanonicalJson $receipt.value.toolchain) -cne (ConvertTo-DsrCacheCanonicalJson $Context.ToolchainIdentity) -or
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
    $psi.FileName = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $Context.CmdPath.Replace('/','\')
    } else { $Context.CmdPath }
    $psi.WorkingDirectory = $Context.SourceRoot
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
        if ($Context.PSObject.Properties['ProbeTimeoutMilliseconds']) {
            if (-not $process.WaitForExit($Context.ProbeTimeoutMilliseconds)) {
                $process.Kill($true)
                throw 'Toolchain executable probe exceeded its bounded runtime'
            }
        } else { $process.WaitForExit() }
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
    $result=Invoke-DsrCargoCommand -Context $Context -Command $command -CaptureOutput ($CaptureOutput.IsPresent -or $Operation -eq 'Metadata')
    if ((Get-DsrCargoContextFingerprint $Context) -cne $Context.Fingerprint) { throw 'Windows Cargo context changed during execution; refusing artifact collection' }
    return $result
}
