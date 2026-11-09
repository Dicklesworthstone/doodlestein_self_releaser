# Embedded by the ordinary Windows installer generator. Source installation is
# explicit execution of repository/dependency code with existing Git and Go;
# its receipts never claim authentication as a published, signed release.

function Test-DsrSourceRelativePath {
    param($Value, [switch]$Root)
    if ($Root -and $Value -ceq '.') { return $true }
    if ($Value -isnot [string] -or -not $Value -or $Value.Length -gt 1024 -or
        $Value -match '[\\:<>"|?*\x00-\x1f\x7f]') { return $false }
    $parts = $Value.Split('/')
    if ($parts.Count -gt 64) { return $false }
    foreach ($part in $parts) {
        if (-not $part -or $part.Length -gt 240 -or $part -cin @('.', '..') -or
            $part.Equals('.git', [StringComparison]::OrdinalIgnoreCase) -or $part.EndsWith('.') -or $part.EndsWith(' ') -or
            $part -imatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { return $false }
    }
    return $true
}

function Assert-DsrSourcePolicy {
    param($Source)
    Assert-DsrFields $Source @('language', 'subdir', 'entry')
    if ($Source.language -cne 'go' -or -not (Test-DsrSourceRelativePath $Source.subdir -Root) -or
        $Source.entry -isnot [string] -or ($Source.entry -and -not (Test-DsrSourceRelativePath $Source.entry -Root))) {
        Stop-DsrInstall 'Invalid embedded Windows Go source selection'
    }
}

function Invoke-DsrSourceCommand {
    param([string]$Executable, [string[]]$Arguments, [string]$Directory, [string]$Log,
        [int]$Timeout, $Environment = @{}, [int]$FailureCode = 6, [switch]$Capture)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($name in $Environment.Keys) {
        if ($null -eq $Environment[$name]) { $null = $start.Environment.Remove($name) }
        else { $start.Environment[$name] = [string]$Environment[$name] }
    }
    $output = New-DsrPrivateFile ($Log + '.stdout')
    $errors = $null
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    $deadline = [Threading.CancellationTokenSource]::new($Timeout * 1000)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $copies = $null
    try {
        $errors = New-DsrPrivateFile ($Log + '.stderr')
        if (-not $process.Start()) { Stop-DsrInstall 'Could not start an installed source-build tool' 3 }
        $started = $true
        $copyOutput = $process.StandardOutput.BaseStream.CopyToAsync($output, 65536, $deadline.Token)
        $copyErrors = $process.StandardError.BaseStream.CopyToAsync($errors, 65536, $deadline.Token)
        $copies = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($copyOutput, $copyErrors))
        $remaining = [Math]::Max(0, $Timeout * 1000 - [int]$clock.ElapsedMilliseconds)
        if (-not $process.WaitForExit($remaining)) {
            Stop-DsrInstall ('Source command exceeded its deadline; diagnostics: ' + $Log) 5
        }
        # A parent can exit while a descendant retains an inherited output
        # pipe. Parent exit never removes the deadline from stream draining.
        $remaining = [Math]::Max(0, $Timeout * 1000 - [int]$clock.ElapsedMilliseconds)
        if ([Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($copies), $remaining) -lt 0 -or
            $deadline.IsCancellationRequested) {
            Stop-DsrInstall ('Source command output exceeded its deadline; diagnostics: ' + $Log) 5
        }
        $null = $copies.GetAwaiter().GetResult()
        $output.Flush($true)
        $errors.Flush($true)
        if ($process.ExitCode -ne 0) {
            Stop-DsrInstall ('Source command failed with exit ' + $process.ExitCode + '; diagnostics: ' + $Log) $FailureCode
        }
    } finally {
        $deadline.Cancel()
        if ($started -and -not $process.HasExited) {
            try { $process.Kill($true); $null = $process.WaitForExit(1000) } catch { }
        }
        # .NET can terminate a live parent's descendants. It cannot establish
        # custody of descendants already orphaned by an exited parent. Close
        # our pipes and return a timeout; do not claim that such children died.
        if ($started) { $process.StandardOutput.Dispose(); $process.StandardError.Dispose() }
        if ($null -ne $copies) { $null = [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($copies), 1000) }
        $process.Dispose()
        $deadline.Dispose()
        if ($null -ne $errors) { $errors.Dispose() }
        $output.Dispose()
    }
    if ($Capture) { return Read-DsrTextFile ($Log + '.stdout') 33554432 }
}

function Get-DsrSourceGitEnvironment {
    param([string]$Repository, [switch]$Authenticate)
    $environment = @{}
    foreach ($name in [Environment]::GetEnvironmentVariables().Keys) {
        if ($name.StartsWith('GIT_', [StringComparison]::OrdinalIgnoreCase)) { $environment[$name] = $null }
    }
    $environment.GIT_CONFIG_NOSYSTEM = '1'
    $environment.GIT_CONFIG_GLOBAL = if ([OperatingSystem]::IsWindows()) { 'NUL' } else { '/dev/null' }
    $environment.GIT_TERMINAL_PROMPT = '0'
    $environment.GIT_NO_REPLACE_OBJECTS = '1'
    $environment.GIT_NO_LAZY_FETCH = '1'
    $environment.GIT_ALLOW_PROTOCOL = 'https'
    $environment.DSR_INSTALLER_GIT_AUTHORIZATION = $null
    if ($Authenticate) {
        $token = Get-DsrGitHubToken
        if ($token) {
            $authorization = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('x-access-token:' + $token))
            $environment.DSR_INSTALLER_GIT_AUTHORIZATION = 'Authorization: Basic ' + $authorization
        }
    }
    return $environment
}

function Get-DsrSourceRepositoryUrl {
    param([string]$Repository)
    return 'https://github.com/' + $Repository + '.git'
}

function Invoke-DsrSourceGit {
    param([string]$Git, [string[]]$Arguments, [string]$Directory, [string]$Log,
        [int]$Timeout, [string]$Repository, $Environment, [switch]$Capture)
    $nullDevice = if ([OperatingSystem]::IsWindows()) { 'NUL' } else { '/dev/null' }
    $options = @('-c', ('core.hooksPath=' + $nullDevice), '-c', 'core.fsmonitor=false', '-c', 'submodule.recurse=false',
        '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', '-c', 'credential.helper=', '-c', 'credential.interactive=false',
        '-c', 'core.askPass=', '-c', 'http.extraHeader=', '-c', 'http.followRedirects=false', '-c', 'http.sslVerify=true',
        '-c', 'protocol.allow=never', '-c', 'protocol.https.allow=always')
    if ([OperatingSystem]::IsWindows()) { $options += @('-c', 'core.longpaths=true') }
    if ($Environment.DSR_INSTALLER_GIT_AUTHORIZATION) {
        # Git 2.31+ reads the repository-scoped header from the child environment.
        # It never appears in a URL, process argument, retained config or log.
        $options += ('--config-env=http.https://github.com/' + $Repository + '.git.extraHeader=DSR_INSTALLER_GIT_AUTHORIZATION')
    }
    return Invoke-DsrSourceCommand $Git ($options + $Arguments) $Directory $Log $Timeout $Environment -FailureCode 8 -Capture:$Capture
}

function Get-DsrSourceFiles {
    param([string]$Listing)
    if (-not $Listing -or -not $Listing.EndsWith([string][char]0)) { Stop-DsrInstall 'Missing or incomplete pinned source inventory' 7 }
    $files = [Collections.Generic.List[string]]::new()
    $nodes = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Listing.Split([char]0)) {
        if (-not $entry) { continue }
        if ($files.Count -ge 100000 -or $entry -cnotmatch '^(100644|100755) blob ([0-9a-f]{40}|[0-9a-f]{64})\t(.+)$') {
            Stop-DsrInstall 'Go source installation requires regular tracked files; submodules and symbolic links are unsupported' 4
        }
        $name = $Matches[3]
        if (-not (Test-DsrSourceRelativePath $name)) { Stop-DsrInstall 'Unsafe Windows source member' 4 }
        $parts = $name.Split('/')
        $prefix = ''
        for ($index = 0; $index -lt $parts.Count; $index++) {
            $prefix = if ($prefix) { $prefix + '/' + $parts[$index] } else { $parts[$index] }
            $kind = if ($index -eq $parts.Count - 1) { 'file' } else { 'directory' }
            if ($nodes.ContainsKey($prefix)) {
                $prior = $nodes[$prefix]
                if ($prior.path -cne $prefix -or $prior.kind -cne $kind -or $kind -ceq 'file') {
                    Stop-DsrInstall 'Case-colliding or ambiguous Windows source tree' 4
                }
            } else { $nodes.Add($prefix, @{ path = $prefix; kind = $kind }) }
        }
        $files.Add($name)
    }
    $files.Sort([StringComparer]::Ordinal)
    return ,$files.ToArray()
}

function Get-DsrSourceTreeEvidence {
    param([string]$Root, [string[]]$Files)
    $rows = [Text.StringBuilder]::new()
    foreach ($name in $Files) {
        $path = Get-DsrPlainPath ([IO.Path]::Combine($Root, $name)) -File
        $evidence = Get-DsrFileEvidence $path
        $null = $rows.Append($name).Append([char]0).Append($evidence.sha256).Append([char]0)
        $null = $rows.Append($evidence.size_bytes.ToString([Globalization.CultureInfo]::InvariantCulture)).Append("`n")
    }
    return Get-DsrBytesHash ([Text.Encoding]::UTF8.GetBytes($rows.ToString()))
}

function Build-DsrGoSourceFamily {
    param($Policy, $Selection, [string]$Platform, [string]$Reference, [string]$Work, [int]$Timeout)
    Assert-DsrSourcePolicy $Policy.source
    if ($Reference -cnotmatch '^(HEAD|[0-9a-fA-F]{40}|[0-9a-fA-F]{64}|refs/(heads|tags)/[A-Za-z0-9][A-Za-z0-9._/+\-]*)$' -or
        $Reference.Contains('..') -or $Reference.EndsWith('/') -or $Reference.EndsWith('.')) {
        Stop-DsrInstall 'Use HEAD, a full commit SHA, refs/heads/BRANCH or refs/tags/TAG for -SourceRef'
    }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $go = Get-Command go -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git -or $null -eq $go) { Stop-DsrInstall 'Source installation requires existing Git and Go executables; no toolchain is installed automatically' 3 }
    $logs = New-DsrPrivateDirectory ([IO.Path]::Combine($Work, 'logs'))
    $source = New-DsrPrivateDirectory ([IO.Path]::Combine($Work, 'source'))
    $output = New-DsrPrivateDirectory ([IO.Path]::Combine($Work, 'output'))
    $gitEnvironment = Get-DsrSourceGitEnvironment $Policy.repo -Authenticate
    $repositoryUrl = Get-DsrSourceRepositoryUrl $Policy.repo
    $gitBase = @{ Git = $git.Source; Directory = $source; Timeout = $Timeout; Repository = $Policy.repo; Environment = $gitEnvironment }
    $null = Invoke-DsrSourceGit @gitBase -Arguments @('init', '--quiet', '--template=', '.') -Log ([IO.Path]::Combine($logs, 'git-init'))
    if ($Reference.StartsWith('refs/', [StringComparison]::Ordinal)) {
        $null = Invoke-DsrSourceGit @gitBase -Arguments @('check-ref-format', $Reference) -Log ([IO.Path]::Combine($logs, 'git-ref'))
    }
    $null = Invoke-DsrSourceGit @gitBase -Arguments @('remote', 'add', 'origin', $repositoryUrl) -Log ([IO.Path]::Combine($logs, 'git-origin'))
    $null = Invoke-DsrSourceGit @gitBase -Arguments @('fetch', '--quiet', '--depth=1', '--no-tags', '--recurse-submodules=no', 'origin', $Reference) -Log ([IO.Path]::Combine($logs, 'git-fetch'))
    $commit = (Invoke-DsrSourceGit @gitBase -Arguments @('rev-parse', '--verify', 'FETCH_HEAD^{commit}') -Log ([IO.Path]::Combine($logs, 'git-pin')) -Capture).Trim()
    if ($commit -cnotmatch '^([0-9a-f]{40}|[0-9a-f]{64})$' -or
        ($Reference -match '^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$' -and $commit -cne $Reference.ToLowerInvariant())) {
        Stop-DsrInstall 'Fetched source does not match the selected commit' 7
    }
    $listing = Invoke-DsrSourceGit @gitBase -Arguments @('ls-tree', '-rz', '--full-tree', $commit) -Log ([IO.Path]::Combine($logs, 'git-tree')) -Capture
    $files = Get-DsrSourceFiles $listing
    $null = Invoke-DsrSourceGit @gitBase -Arguments @('-c', 'advice.detachedHead=false', 'checkout', '--quiet', '--detach', $commit) -Log ([IO.Path]::Combine($logs, 'git-checkout'))
    $sourceEvidence = Get-DsrSourceTreeEvidence $source $files
    $buildRoot = if ($Policy.source.subdir -ceq '.') { $source } else { [IO.Path]::Combine($source, $Policy.source.subdir) }
    $buildRoot = Get-DsrPlainPath $buildRoot -Directory
    $null = Get-DsrPlainPath ([IO.Path]::Combine($buildRoot, 'go.mod')) -File
    $primary = $Policy.binary_name
    if (-not $primary.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $primary += '.exe' }
    $entries = @()
    foreach ($name in $Selection.binaries) {
        $entry = ''
        $isPrimary = $name.Equals($primary, [StringComparison]::OrdinalIgnoreCase)
        if ($isPrimary) { $entry = $Policy.source.entry }
        if (-not $entry) {
            $entry = 'cmd/' + $name.Substring(0, $name.Length - 4)
            $candidate = Get-DsrPlainPath ([IO.Path]::Combine($buildRoot, $entry))
            if ($isPrimary -and -not [IO.Directory]::Exists($candidate) -and -not [IO.File]::Exists($candidate)) { $entry = '.' }
        }
        if (-not (Test-DsrSourceRelativePath $entry -Root)) { Stop-DsrInstall 'Unsafe Go source entry selection' }
        $entryPath = if ($entry -ceq '.') { $buildRoot } else { [IO.Path]::Combine($buildRoot, $entry) }
        $null = Get-DsrPlainPath $entryPath -Directory
        $entries += $entry
    }
    $environment = Get-DsrSourceGitEnvironment $Policy.repo
    $environment.GOENV = 'off'
    $environment.GOWORK = 'off'
    $environment.GOTOOLCHAIN = 'local'
    $environment.GOFLAGS = ''
    $environment.GOOS = 'windows'
    $environment.GOARCH = $Platform.Substring('windows/'.Length)
    $goBase = @{ Executable = $go.Source; Directory = $buildRoot; Timeout = $Timeout; Environment = $environment }
    $compiler = (Invoke-DsrSourceCommand $go.Source @('version') $buildRoot ([IO.Path]::Combine($logs, 'compiler')) $Timeout $environment -Capture).Trim()
    if (-not $compiler -or $compiler.Length -gt 4096) { Stop-DsrInstall 'Invalid installed Go compiler identity' 6 }
    $moduleMode = 'readonly'
    $vendor = Get-DsrPlainPath ([IO.Path]::Combine($buildRoot, 'vendor'))
    if ([IO.Directory]::Exists($vendor)) { $moduleMode = 'vendor' }
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $goArguments = @('list', ('-mod=' + $moduleMode), '-f', '{{.Name}}', ('./' + $entries[$index]))
        $provider = (Invoke-DsrSourceCommand @goBase -Arguments $goArguments -Log ([IO.Path]::Combine($logs, ('package-' + $index))) -Capture).Trim()
        if ($provider -cne 'main') { Stop-DsrInstall ('Requested Go package is not one executable: ' + $Selection.binaries[$index]) 6 }
    }
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $target = [IO.Path]::Combine($output, $Selection.binaries[$index])
        $goArguments = @('build', ('-mod=' + $moduleMode), '-trimpath', '-o', $target, ('./' + $entries[$index]))
        $null = Invoke-DsrSourceCommand @goBase -Arguments $goArguments -Log ([IO.Path]::Combine($logs, ('build-' + $index)))
    }
    $finalCommit = (Invoke-DsrSourceGit @gitBase -Arguments @('rev-parse', '--verify', 'HEAD^{commit}') -Log ([IO.Path]::Combine($logs, 'git-final-pin')) -Capture).Trim()
    if ($finalCommit -cne $commit -or (Get-DsrSourceTreeEvidence $source $files) -cne $sourceEvidence) {
        Stop-DsrInstall 'Source compilation changed the pinned tracked inputs' 7
    }
    $rows = @()
    $expected = @{}
    $sourceEntries = @()
    for ($index = 0; $index -lt $Selection.binaries.Count; $index++) {
        $sourceEntries += @{ name = $Selection.binaries[$index]; entry = $entries[$index] }
    }
    foreach ($name in $Selection.binaries) {
        $path = Get-DsrPlainPath ([IO.Path]::Combine($output, $name)) -File
        Assert-DsrPeMachine $path $Platform
        $evidence = Get-DsrFileEvidence $path
        $expected[$name] = $evidence
        $rows += @{ name = $name; sha256 = $evidence.sha256; size_bytes = $evidence.size_bytes }
    }
    $primaryRow = @($rows | Where-Object { $_.name.Equals($primary, [StringComparison]::OrdinalIgnoreCase) })[0]
    $receipt = @{ schema_version = 1; method = 'source'; repository = $Policy.repo; requested_ref = $Reference;
        source_commit = $commit; source_tree_sha256 = $sourceEvidence; language = 'go'; compiler = $compiler;
        platform = $Platform; go_target = @{ os = 'windows'; arch = $environment.GOARCH };
        release_target_triple = $Selection.target_triple; source_subdir = $Policy.source.subdir;
        source_entry = $Policy.source.entry; source_entries = @($sourceEntries);
        binaries = @($rows); sha256 = $primaryRow.sha256; size_bytes = $primaryRow.size_bytes; signed_release = $false }
    Write-DsrNewTextFile ([IO.Path]::Combine($Work, 'source-receipt.json')) ($receipt | ConvertTo-Json -Depth 8 -Compress)
    return @{ directory = $output; receipt = $receipt; expected = $expected }
}
