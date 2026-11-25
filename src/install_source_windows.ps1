# Embedded by the ordinary Windows installer generator. Source installation is
# explicit execution of repository/dependency code with existing Git and Rust/Go/Bun;
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
    Assert-DsrFields $Source @('language', 'subdir') @('entry', 'package', 'features', 'no_default_features')
    if (-not (Test-DsrSourceRelativePath $Source.subdir -Root)) { Stop-DsrInstall 'Invalid embedded Windows source directory' }
    if ($Source.language -cin @('go', 'bun', 'typescript')) {
        Assert-DsrFields $Source @('language', 'subdir', 'entry')
        if ($Source.entry -isnot [string] -or ($Source.entry -and -not (Test-DsrSourceRelativePath $Source.entry -Root))) {
            Stop-DsrInstall 'Invalid embedded Windows Go/Bun source selection'
        }
    } elseif ($Source.language -ceq 'rust') {
        Assert-DsrFields $Source @('language', 'subdir', 'package') @('features', 'no_default_features')
        if ($Source.package -isnot [string] -or ($Source.package -and
            ($Source.package.Length -gt 128 -or -not (Test-DsrName $Source.package)))) {
            Stop-DsrInstall 'Invalid embedded Windows Rust source selection'
        }
        if ($Source.Contains('features')) {
            if ($Source.features -isnot [array] -or $Source.features.Count -gt 64) {
                Stop-DsrInstall 'Rust source features must be an array of at most 64 literal feature names' 4
            }
            $features = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($feature in $Source.features) {
                if ($feature -isnot [string] -or $feature.Length -gt 128 -or
                    $feature -cnotmatch '\A[A-Za-z0-9_][A-Za-z0-9_.+\-]*(/[A-Za-z0-9_][A-Za-z0-9_.+\-]*)?\z' -or
                    -not $features.Add($feature)) {
                    Stop-DsrInstall 'Rust source features must be unique literal feature or package/feature names' 4
                }
            }
        }
        if ($Source.Contains('no_default_features') -and $Source.no_default_features -isnot [bool]) {
            Stop-DsrInstall 'Rust source no_default_features must be a Boolean' 4
        }
    } else {
        Stop-DsrInstall 'Unsupported embedded Windows source language'
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
        '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', '-c', 'core.symlinks=false', '-c', 'credential.helper=', '-c', 'credential.interactive=false',
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

function Get-DsrSourceInventory {
    param([string]$Listing)
    # An empty committed child tree is valid. ls-tree's successful exit is
    # already required by the acquisition caller; nonempty output is framed.
    if ($Listing -and -not $Listing.EndsWith([string][char]0)) { Stop-DsrInstall 'Incomplete pinned source inventory' 7 }
    $files = [Collections.Generic.List[string]]::new()
    $links = [Collections.Generic.List[object]]::new()
    $symlinks = [Collections.Generic.List[object]]::new()
    $rows = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $nodes = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Listing.Split([char]0)) {
        if (-not $entry) { continue }
        if ($files.Count + $links.Count + $symlinks.Count -ge 100000 -or
            $entry -cnotmatch '^(100644|100755|120000|160000) (blob|commit) ([0-9a-f]{40}|[0-9a-f]{64})\t(.+)$') {
            Stop-DsrInstall 'Unsupported or excessive pinned Windows source entries' 4
        }
        $mode = $Matches[1]
        $type = $Matches[2]
        $commit = $Matches[3]
        $name = $Matches[4]
        if (($mode -ceq '160000') -ne ($type -ceq 'commit')) { Stop-DsrInstall 'Invalid pinned source entry kind' 4 }
        if (-not (Test-DsrSourceRelativePath $name)) { Stop-DsrInstall 'Unsafe Windows source member' 4 }
        $parts = $name.Split('/')
        $prefix = ''
        for ($index = 0; $index -lt $parts.Count; $index++) {
            $prefix = if ($prefix) { $prefix + '/' + $parts[$index] } else { $parts[$index] }
            $kind = if ($index -lt $parts.Count - 1) { 'directory' } elseif ($mode -ceq '160000') { 'repository' } elseif ($mode -ceq '120000') { 'link' } else { 'file' }
            if ($nodes.ContainsKey($prefix)) {
                $prior = $nodes[$prefix]
                if ($prior.path -cne $prefix -or $prior.kind -cne $kind -or $kind -cne 'directory') {
                    Stop-DsrInstall 'Case-colliding or ambiguous Windows source tree' 4
                }
            } else { $nodes.Add($prefix, @{ path = $prefix; kind = $kind }) }
            if ($kind -ceq 'directory') { $null = $directories.Add($prefix) }
        }
        $rows.Add($name, @{ mode = $mode; git_blob = $commit })
        if ($mode -ceq '160000') { $links.Add(@{ path = $name; source_commit = $commit }) }
        elseif ($mode -ceq '120000') { $symlinks.Add(@{ path = $name; git_blob = $commit }) }
        else { $files.Add($name) }
    }
    $files.Sort([StringComparer]::Ordinal)
    return @{ files = $files.ToArray(); submodules = $links.ToArray(); symlinks = $symlinks.ToArray();
        rows = $rows; directories = $directories; entry_count = $files.Count + $links.Count + $symlinks.Count }
}

function Get-DsrSourceGitBlobHash {
    param([string]$Path, [string]$Expected)
    $stream = Open-DsrReadFile (Get-DsrPlainPath $Path -File)
    $algorithm = if ($Expected.Length -eq 40) { [Security.Cryptography.HashAlgorithmName]::SHA1 } else { [Security.Cryptography.HashAlgorithmName]::SHA256 }
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash($algorithm)
    try {
        $length = $stream.Length
        $header = 'blob ' + $length.ToString([Globalization.CultureInfo]::InvariantCulture) + [char]0
        $hash.AppendData([Text.Encoding]::ASCII.GetBytes($header))
        $buffer = [byte[]]::new(65536)
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $hash.AppendData($buffer, 0, $count) }
        if ($stream.Position -ne $length -or $stream.Length -ne $length) { Stop-DsrInstall 'Tracked source changed while its Git blob was checked' 7 }
        return [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
    } finally { $hash.Dispose(); $stream.Dispose() }
}

# Match the strict Windows snapshot policy: links select an exact regular
# tracked file in their own repository, never another link or repository.
function Resolve-DsrSourceLinkReferent {
    param([string]$Path, [string]$Target, $Inventory, [string]$DisplayPath)
    if (-not $Target -or $Target.StartsWith('/') -or $Target.Length -gt 32760 -or
        $Target -cnotmatch '\A[A-Za-z0-9_./+@~#,=()\[\] -]+\z') {
        Stop-DsrInstall ('Unsafe tracked source link: ' + $DisplayPath) 4
    }
    $parts = [Collections.Generic.List[string]]::new()
    $slash = $Path.LastIndexOf('/')
    if ($slash -ge 0) { foreach ($part in $Path.Substring(0, $slash).Split('/')) { $parts.Add($part) } }
    foreach ($part in $Target.Split('/')) {
        $cursor = $parts -join '/'
        if ($cursor -and -not $Inventory.directories.Contains($cursor)) {
            Stop-DsrInstall ('Tracked source link traverses a non-directory: ' + $DisplayPath) 4
        }
        if (-not $part -or $part -ceq '.') { continue }
        if ($part -ceq '..') {
            if ($parts.Count -eq 0) { Stop-DsrInstall ('Tracked source link escapes its repository: ' + $DisplayPath) 4 }
            $parts.RemoveAt($parts.Count - 1)
            continue
        }
        if (-not (Test-DsrSourceRelativePath $part)) { Stop-DsrInstall ('Unsafe tracked source link component: ' + $DisplayPath) 4 }
        $parts.Add($part)
        $cursor = $parts -join '/'
        if ($Inventory.rows.ContainsKey($cursor) -and $Inventory.rows[$cursor].mode -ceq '160000') {
            Stop-DsrInstall ('Tracked source link enters a nested repository: ' + $DisplayPath) 4
        }
    }
    $relative = $parts -join '/'
    if (-not $Inventory.rows.ContainsKey($relative) -or $Inventory.rows[$relative].mode -cnotin @('100644', '100755')) {
        Stop-DsrInstall ('Tracked source link requires an exact tracked regular file without chains: ' + $DisplayPath) 4
    }
    return $relative
}

function Convert-DsrSourceLinks {
    param($Node, $Graph, $Inventory)
    foreach ($link in $Inventory.symlinks) {
        $index = $Graph.materializations.Count
        $path = if ($Node.path) { $Node.path + '/' + $link.path } else { $link.path }
        if (-not (Test-DsrSourceRelativePath $path)) { Stop-DsrInstall 'Nested tracked source link exceeds the source bounds' 4 }
        $destination = Get-DsrPlainPath ([IO.Path]::Combine($Node.root, $link.path)) -File
        $literal = [IO.Path]::Combine($Node.logs, ('link-' + $index + '-literal'))
        Copy-DsrNewFile $destination $literal
        $literalEvidence = Get-DsrFileEvidence $literal
        if ($literalEvidence.size_bytes -lt 1 -or $literalEvidence.size_bytes -gt 32760) {
            Stop-DsrInstall ('Unsafe tracked source link text: ' + $path) 4
        }
        if ((Get-DsrSourceGitBlobHash $literal $link.git_blob) -cne $link.git_blob) {
            Stop-DsrInstall ('Tracked source link text differs from its pinned Git blob: ' + $path) 7
        }
        $stream = Open-DsrReadFile $literal
        $reader = $null
        try {
            # Do not consume a BOM or otherwise normalize the literal link.
            $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false, 4096, $true)
            $target = $reader.ReadToEnd()
        } catch { Stop-DsrInstall ('Invalid tracked source link text: ' + $path) 4 }
        finally { if ($null -ne $reader) { $reader.Dispose() }; $stream.Dispose() }
        $referent = Resolve-DsrSourceLinkReferent $link.path $target $Inventory $path
        $fullReferent = if ($Node.path) { $Node.path + '/' + $referent } else { $referent }
        if (-not (Test-DsrSourceRelativePath $fullReferent)) { Stop-DsrInstall 'Nested tracked link referent exceeds the source bounds' 4 }
        $referentPath = Get-DsrPlainPath ([IO.Path]::Combine($Node.root, $referent)) -File
        $referentBlob = $Inventory.rows[$referent].git_blob
        $evidence = Get-DsrFileEvidence $referentPath
        if ((Get-DsrSourceGitBlobHash $referentPath $referentBlob) -cne $referentBlob) {
            # Authenticate supported Git checkout conversions forward, as the
            # Bash source engine does. Never run an external filter as proof.
            $attributes = Invoke-DsrSourceAcquisitionGit $Node $Graph `
                @('--literal-pathspecs', 'check-attr', '-z', 'filter', '--', $referent) ('link-' + $index + '-attributes') -Capture
            $fields = $attributes.Split([char]0)
            if ($fields.Count -ne 4 -or $fields[0] -cne $referent -or $fields[1] -cne 'filter' -or $fields[3] -or
                $fields[2] -cnotmatch '^[A-Za-z0-9_/-][A-Za-z0-9._/-]*$') {
                Stop-DsrInstall ('Unsupported tracked link referent conversion: ' + $path) 4
            }
            $filter = $fields[2]
            $label = 'link-' + $index + '-referent'
            $null = Invoke-DsrSourceAcquisitionGit $Node $Graph `
                @('-c', ('filter.' + $filter + '.clean='), '-c', ('filter.' + $filter + '.smudge='),
                  '-c', ('filter.' + $filter + '.process='), '-c', ('filter.' + $filter + '.required=false'),
                  'cat-file', '--filters', ('--path=' + $referent), $referentBlob) $label
            $expected = Get-DsrFileEvidence ([IO.Path]::Combine($Node.logs, ($label + '.stdout')))
            if ($evidence.sha256 -cne $expected.sha256 -or $evidence.size_bytes -ne $expected.size_bytes) {
                Stop-DsrInstall ('Tracked link referent differs from its pinned source: ' + $path) 7
            }
        }
        $candidate = [IO.Path]::Combine($Node.logs, ('link-' + $index + '-copy'))
        Copy-DsrNewFile $referentPath $candidate
        $copied = Get-DsrFileEvidence $candidate
        if ($copied.sha256 -cne $evidence.sha256 -or $copied.size_bytes -ne $evidence.size_bytes) {
            Stop-DsrInstall ('Tracked link referent changed while materializing: ' + $path) 7
        }
        $null = Get-DsrPlainPath $destination -File
        [IO.File]::Move($candidate, $destination, $true)
        $Graph.materializations.Add(@{ path = $path; git_blob = $link.git_blob; link_target = $target;
            referent_path = $fullReferent; referent_git_blob = $referentBlob;
            sha256 = $evidence.sha256; size_bytes = $evidence.size_bytes;
            literal_path = $literal; literal_sha256 = $literalEvidence.sha256; literal_size_bytes = $literalEvidence.size_bytes })
        $Graph.files.Add($path)
    }
}

function Assert-DsrSourceMaterializations {
    param($Graph)
    foreach ($link in $Graph.materializations) {
        $literal = Get-DsrFileEvidence $link.literal_path
        if ($literal.sha256 -cne $link.literal_sha256 -or $literal.size_bytes -ne $link.literal_size_bytes -or
            (Get-DsrSourceGitBlobHash $link.literal_path $link.git_blob) -cne $link.git_blob) {
            Stop-DsrInstall ('Retained tracked link text changed: ' + $link.path) 7
        }
        foreach ($path in @($link.path, $link.referent_path)) {
            $evidence = Get-DsrFileEvidence (Get-DsrPlainPath ([IO.Path]::Combine($Graph.root, $path)) -File)
            if ($evidence.sha256 -cne $link.sha256 -or $evidence.size_bytes -ne $link.size_bytes) {
                Stop-DsrInstall ('Materialized tracked link or referent changed: ' + $link.path) 7
            }
        }
    }
}

function Resolve-DsrSourceSubmoduleRepository {
    param([string]$Parent, [string]$Url)
    if ($Url.StartsWith('https://github.com/', [StringComparison]::Ordinal)) { $repository = $Url.Substring(19) }
    elseif ($Url.StartsWith('../../', [StringComparison]::Ordinal)) { $repository = $Url.Substring(6) }
    elseif ($Url.StartsWith('../', [StringComparison]::Ordinal)) { $repository = $Parent.Split('/')[0] + '/' + $Url.Substring(3) }
    else { Stop-DsrInstall 'Submodules must select GitHub HTTPS repositories' 4 }
    if ($repository.EndsWith('.git', [StringComparison]::Ordinal)) { $repository = $repository.Substring(0, $repository.Length - 4) }
    if ($repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        Stop-DsrInstall 'Unsafe or unsupported submodule repository' 4
    }
    return $repository
}

# Every operation in acquisition or graph validation shares its caller's
# deadline. Repository count cannot multiply SourceTimeout into an unbounded
# sequence of requests or local identity checks.
function Invoke-DsrSourceAcquisitionGit {
    param($Node, $Graph, [string[]]$Arguments, [string]$Label, [switch]$Capture)
    $remaining = [Math]::Ceiling(($Graph.timeout * 1000 - $Graph.clock.ElapsedMilliseconds) / 1000.0)
    if ($remaining -le 0) { Stop-DsrInstall 'Source graph operation exceeded its complete-graph deadline' 5 }
    $result = Invoke-DsrSourceGit $Graph.git $Arguments $Node.root ([IO.Path]::Combine($Node.logs, $Label)) `
        ([int]$remaining) $Node.repository $Node.environment -Capture:$Capture
    if ($Graph.clock.ElapsedMilliseconds -ge $Graph.timeout * 1000) {
        Stop-DsrInstall 'Source graph operation exceeded its complete-graph deadline' 5
    }
    if ($Capture) { return $result }
}

function Get-DsrSourceSubmoduleDeclarations {
    param($Node, $Graph, $Inventory)
    $links = @($Inventory.submodules)
    if ($links.Count -eq 0) { return ,@() }
    if ('.gitmodules' -cnotin $Inventory.files) { Stop-DsrInstall 'Pinned gitlinks require a committed regular .gitmodules' 4 }
    # Parse the committed blob directly. Neither a working-tree replacement,
    # an include directive nor a custom update command supplies URL authority.
    try {
        $records = Invoke-DsrSourceAcquisitionGit $Node $Graph `
            @('config', '--no-includes', '--null', '--blob', ($Node.source_commit + ':.gitmodules'),
                '--get-regexp', '^submodule\..*\.(path|url)$') 'git-modules' -Capture
    } catch {
        if ($_.Exception.Data.Contains('DsrExitCode') -and $_.Exception.Data['DsrExitCode'] -eq 5) { throw }
        Stop-DsrInstall 'Invalid committed submodule declarations' 4
    }
    if (-not $records -or -not $records.EndsWith([string][char]0)) {
        Stop-DsrInstall 'Missing or incomplete committed submodule declarations' 4
    }
    $paths = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $urls = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $names = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $records.Split([char]0)) {
        if (-not $record) { continue }
        $separator = $record.IndexOf("`n", [StringComparison]::Ordinal)
        if ($separator -le 0) { Stop-DsrInstall 'Invalid committed submodule declaration' 4 }
        $key = $record.Substring(0, $separator)
        $value = $record.Substring($separator + 1)
        if ($key -cnotmatch '^submodule\.([A-Za-z0-9_][A-Za-z0-9._/-]*)\.(path|url)$') {
            Stop-DsrInstall 'Unsafe or unsupported submodule name' 4
        }
        $name = $Matches[1]
        $field = $Matches[2]
        if ($field -ceq 'path') {
            if (-not (Test-DsrSourceRelativePath $value) -or $paths.ContainsKey($name) -or $names.ContainsKey($value)) {
                Stop-DsrInstall 'Repeated, case-colliding or unsafe submodule path' 4
            }
            $paths.Add($name, $value)
            $names.Add($value, $name)
        } else {
            if ($urls.ContainsKey($name)) { Stop-DsrInstall 'Repeated submodule URL' 4 }
            $urls.Add($name, (Resolve-DsrSourceSubmoduleRepository $Node.repository $value))
        }
    }
    if ($paths.Count -ne $links.Count -or $urls.Count -ne $links.Count) {
        Stop-DsrInstall 'Submodule declarations must match every pinned gitlink exactly' 4
    }
    $children = [Collections.Generic.List[object]]::new()
    foreach ($link in $links) {
        if (-not $names.ContainsKey($link.path)) { Stop-DsrInstall 'Missing pinned submodule declaration' 4 }
        $name = $names[$link.path]
        if ($paths[$name] -cne $link.path -or -not $urls.ContainsKey($name)) {
            Stop-DsrInstall 'Ambiguous pinned submodule declaration' 4
        }
        $path = Get-DsrPlainPath ([IO.Path]::Combine($Node.root, $link.path)) -Directory
        if (@([IO.Directory]::EnumerateFileSystemEntries($path)).Count -ne 0) {
            Stop-DsrInstall 'Pinned submodule destination is not an empty plain directory' 7
        }
        $fullPath = if ($Node.path) { $Node.path + '/' + $link.path } else { $link.path }
        if (-not (Test-DsrSourceRelativePath $fullPath)) { Stop-DsrInstall 'Nested submodule path exceeds the source bounds' 4 }
        $children.Add(@{ root = $path; path = $fullPath; repository = $urls[$name]; source_commit = $link.source_commit })
    }
    return ,$children.ToArray()
}

function Add-DsrSourceRepository {
    param($Graph, [string]$Repository, [string]$Reference, [string]$Root, [string]$Path = '', [int]$Depth = 0)
    if ($Depth -gt 16 -or $Graph.nodes.Count -ge 256) { Stop-DsrInstall 'Source submodules exceed 16 levels or 256 repositories' 4 }
    $node = @{ repository = $Repository; path = $Path; root = (Get-DsrPlainPath $Root -Directory);
        environment = (Get-DsrSourceGitEnvironment $Repository -Authenticate);
        logs = (New-DsrPrivateDirectory ([IO.Path]::Combine($Graph.logs, ('source-' + $Graph.nodes.Count)))) }
    $null = Invoke-DsrSourceAcquisitionGit $node $Graph @('init', '--quiet', '--template=', '.') 'git-init'
    # Pin all repository plumbing, including after compiler code has run.
    # A later core.worktree, alternate index or ambient Git selector cannot
    # redirect our source identity checks to a different checkout.
    $gitDirectory = Get-DsrPlainPath ([IO.Path]::Combine($node.root, '.git')) -Directory
    $node.environment.GIT_DIR = $gitDirectory
    $node.environment.GIT_COMMON_DIR = $gitDirectory
    $node.environment.GIT_WORK_TREE = $node.root
    $node.environment.GIT_INDEX_FILE = [IO.Path]::Combine($gitDirectory, 'index')
    $node.environment.GIT_OBJECT_DIRECTORY = [IO.Path]::Combine($gitDirectory, 'objects')
    if ($Reference.StartsWith('refs/', [StringComparison]::Ordinal)) {
        $null = Invoke-DsrSourceAcquisitionGit $node $Graph @('check-ref-format', $Reference) 'git-ref'
    }
    $null = Invoke-DsrSourceAcquisitionGit $node $Graph @('remote', 'add', 'origin', (Get-DsrSourceRepositoryUrl $Repository)) 'git-origin'
    $null = Invoke-DsrSourceAcquisitionGit $node $Graph `
        @('fetch', '--quiet', '--depth=1', '--no-tags', '--recurse-submodules=no', 'origin', $Reference) 'git-fetch'
    $commit = (Invoke-DsrSourceAcquisitionGit $node $Graph @('rev-parse', '--verify', 'FETCH_HEAD^{commit}') 'git-pin' -Capture).Trim()
    if ($commit -cnotmatch '^([0-9a-f]{40}|[0-9a-f]{64})$' -or
        ($Reference -match '^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$' -and $commit -cne $Reference.ToLowerInvariant())) {
        Stop-DsrInstall 'Fetched source does not match the selected commit' 7
    }
    $node.source_commit = $commit
    $listing = Invoke-DsrSourceAcquisitionGit $node $Graph @('ls-tree', '-rz', '--full-tree', $commit) 'git-tree' -Capture
    $inventory = Get-DsrSourceInventory $listing
    $Graph.entry_count += $inventory.entry_count
    if ($Graph.entry_count -gt 100000) { Stop-DsrInstall 'Source graph exceeds 100000 tracked entries' 4 }
    $null = Invoke-DsrSourceAcquisitionGit $node $Graph `
        @('-c', 'advice.detachedHead=false', 'checkout', '--quiet', '--detach', $commit) 'git-checkout'
    $Graph.nodes.Add($node)
    foreach ($file in $inventory.files) {
        $fullPath = if ($Path) { $Path + '/' + $file } else { $file }
        if (-not (Test-DsrSourceRelativePath $fullPath)) { Stop-DsrInstall 'Nested source member exceeds the source bounds' 4 }
        $Graph.files.Add($fullPath)
    }
    Convert-DsrSourceLinks $node $Graph $inventory
    $children = Get-DsrSourceSubmoduleDeclarations $node $Graph $inventory
    if ($children.Count -gt 0 -and ($Depth -ge 16 -or $Graph.nodes.Count + $children.Count -gt 256)) {
        Stop-DsrInstall 'Source submodules exceed 16 levels or 256 repositories' 4
    }
    foreach ($child in $children) {
        Write-DsrInstallVerbose ('Fetching pinned submodule ' + $child.path + ' at ' + $child.source_commit)
        $null = Add-DsrSourceRepository $Graph $child.repository $child.source_commit $child.root $child.path ($Depth + 1)
    }
    return $node
}

function Assert-DsrSourceGraph {
    param($Graph, [string]$Phase)
    # Initial validation is still part of acquisition. Final validation gets
    # one fresh graph-wide budget after the independently bounded compilers.
    $verification = if ($Phase -ceq 'initial') { $Graph } else {
        @{ git = $Graph.git; timeout = $Graph.timeout; clock = [Diagnostics.Stopwatch]::StartNew() }
    }
    foreach ($node in $Graph.nodes) {
        $null = Get-DsrPlainPath $node.environment.GIT_DIR -Directory
        $null = Get-DsrPlainPath $node.environment.GIT_OBJECT_DIRECTORY -Directory
        $null = Get-DsrPlainPath $node.environment.GIT_INDEX_FILE -File
        try {
            $commit = (Invoke-DsrSourceAcquisitionGit $node $verification @('rev-parse', '--verify', 'HEAD^{commit}') `
                ('git-' + $Phase + '-pin') -Capture).Trim()
            if ($commit -cne $node.source_commit) { Stop-DsrInstall 'Source compilation changed a pinned repository identity' 7 }
            $null = Invoke-DsrSourceAcquisitionGit $node $verification `
                @('diff-index', '--cached', '--quiet', '--no-ext-diff', '--no-textconv', '--ignore-submodules=none', $node.source_commit, '--') `
                ('git-' + $Phase + '-index')
        } catch {
            if ($_.Exception.Data.Contains('DsrExitCode') -and $_.Exception.Data['DsrExitCode'] -eq 5) { throw }
            Stop-DsrInstall 'Source compilation changed a pinned repository identity or staged tree' 7
        }
    }
}

function Get-DsrSourceTreeEvidence {
    param([string]$Root, [string[]]$Files, [object[]]$Materializations = @())
    $rows = [Text.StringBuilder]::new()
    foreach ($name in $Files) {
        $path = Get-DsrPlainPath ([IO.Path]::Combine($Root, $name)) -File
        $evidence = Get-DsrFileEvidence $path
        $null = $rows.Append($name).Append([char]0).Append($evidence.sha256).Append([char]0)
        $null = $rows.Append($evidence.size_bytes.ToString([Globalization.CultureInfo]::InvariantCulture)).Append("`n")
    }
    foreach ($link in $Materializations) {
        $null = $rows.Append('materialized-symlink').Append([char]0).Append($link.path).Append([char]0)
        $null = $rows.Append($link.git_blob).Append([char]0).Append($link.link_target).Append([char]0)
        $null = $rows.Append($link.referent_path).Append([char]0).Append($link.referent_git_blob).Append([char]0)
        $null = $rows.Append($link.sha256).Append([char]0).Append($link.size_bytes.ToString([Globalization.CultureInfo]::InvariantCulture)).Append("`n")
    }
    return Get-DsrBytesHash ([Text.Encoding]::UTF8.GetBytes($rows.ToString()))
}

# Go workspace paths are relative to the file declaring them. Resolve them
# within the fetched tree, including ordinary ../ siblings, without admitting
# an ambient workspace, an absolute checkout path or a linked module root.
function Resolve-DsrGoSourceModule {
    param([string]$Source, [string]$Base, $Relative, [string[]]$Files)
    if ($Relative -isnot [string] -or -not $Relative -or $Relative.Length -gt 1024) {
        Stop-DsrInstall 'Invalid Go workspace module path' 4
    }
    $relativePath = $Relative.Replace('\', '/')
    $root = Get-DsrPlainPath $Base -Directory
    $basePath = [IO.Path]::GetRelativePath($Source, $root).Replace('\', '/')
    if (-not (Test-DsrSourceRelativePath $basePath -Root)) {
        Stop-DsrInstall 'Go module base escaped the pinned source checkout' 4
    }
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    # Inspect each traversed directory before resolving '..'. Checking only
    # GetFullPath's final answer would hide a linked or external ancestor that
    # happens to return to the checkout later in the declared path.
    foreach ($part in $relativePath.Split('/')) {
        if ($part -ceq '.') { continue }
        if ($part -ceq '..') {
            if ($root.Equals($Source, $comparison)) { Stop-DsrInstall 'Go module escaped the pinned source checkout' 4 }
            $root = [IO.Path]::GetDirectoryName($root)
            continue
        }
        if (-not (Test-DsrSourceRelativePath $part)) { Stop-DsrInstall 'Unsafe Go workspace module path' 4 }
        $root = Get-DsrPlainPath ([IO.Path]::Combine($root, $part)) -Directory
    }
    $path = [IO.Path]::GetRelativePath($Source, $root).Replace('\', '/')
    if (-not (Test-DsrSourceRelativePath $path -Root)) {
        Stop-DsrInstall 'Go workspace module escaped the pinned source checkout' 4
    }
    $root = Get-DsrPlainPath $root -Directory
    $manifest = [IO.Path]::Combine($root, 'go.mod')
    $manifestPath = [IO.Path]::GetRelativePath($Source, $manifest).Replace('\', '/')
    if ($manifestPath -cnotin $Files) {
        Stop-DsrInstall 'Go workspace modules require an exact committed go.mod' 4
    }
    $manifest = Get-DsrPlainPath $manifest -File
    $checksums = Get-DsrPlainPath ([IO.Path]::Combine($root, 'go.sum'))
    if ([IO.File]::Exists($checksums) -or [IO.Directory]::Exists($checksums)) {
        $checksumPath = [IO.Path]::GetRelativePath($Source, $checksums).Replace('\', '/')
        if ($checksumPath -cnotin $Files) { Stop-DsrInstall 'Go module checksums must be an exact committed file' 4 }
        $null = Get-DsrPlainPath $checksums -File
    }
    return @{ root = $root; path = $path; manifest = $manifest }
}

function Read-DsrGoSourceModule {
    param($Location, $GoBase, [string]$Logs, [int]$Index)
    $text = Invoke-DsrSourceCommand @GoBase -Arguments @('mod', 'edit', '-json', $Location.manifest) `
        -Log ([IO.Path]::Combine($Logs, ('go-module-' + $Index))) -Capture
    $document = ConvertFrom-DsrJson $text
    if ($document -isnot [Collections.IDictionary] -or -not $document.Contains('Module') -or
        $document.Module -isnot [Collections.IDictionary] -or -not $document.Module.Contains('Path') -or
        $document.Module.Path -isnot [string] -or -not $document.Module.Path -or
        $document.Module.Path -match '[\x00-\x20\x7f]') {
        Stop-DsrInstall 'Go returned an invalid committed module identity' 4
    }
    $replacements = @()
    if ($document.Contains('Replace') -and $null -ne $document.Replace) {
        if ($document.Replace -isnot [array]) { Stop-DsrInstall 'Invalid Go module replacement inventory' 4 }
        $replacements = @($document.Replace)
    }
    return @{ root = $Location.root; path = $Location.path; module_path = $document.Module.Path;
        go_mod_sha256 = (Get-DsrFileEvidence $Location.manifest).sha256; replacements = $replacements }
}

function Get-DsrGoSourceReplacement {
    param($Replacement)
    if ($Replacement -isnot [Collections.IDictionary] -or
        -not $Replacement.Contains('Old') -or -not $Replacement.Contains('New')) {
        Stop-DsrInstall 'Invalid Go replacement declaration' 4
    }
    foreach ($selection in @($Replacement.Old, $Replacement.New)) {
        if ($selection -isnot [Collections.IDictionary] -or -not $selection.Contains('Path') -or
            $selection.Path -isnot [string] -or -not $selection.Path -or
            ($selection.Contains('Version') -and $selection.Version -isnot [string])) {
            Stop-DsrInstall 'Invalid Go replacement module identity' 4
        }
    }
    $oldVersion = if ($Replacement.Old.Contains('Version')) { $Replacement.Old.Version } else { '' }
    $newVersion = if ($Replacement.New.Contains('Version')) { $Replacement.New.Version } else { '' }
    return @{ module_path = $Replacement.Old.Path; version = $oldVersion;
        replacement = $Replacement.New.Path; replacement_version = $newVersion }
}

function Get-DsrGoWorkspaceVendor {
    param([string]$Source, [string]$WorkspaceRoot, [string[]]$Files)
    $vendor = Get-DsrPlainPath ([IO.Path]::Combine($WorkspaceRoot, 'vendor'))
    if (-not [IO.Directory]::Exists($vendor)) { return $null }
    $manifest = Get-DsrPlainPath ([IO.Path]::Combine($vendor, 'modules.txt'))
    if (-not [IO.File]::Exists($manifest)) { return $null }
    # Match Go's bounded first-line workspace marker. Legacy module vendor
    # directories do not select vendor mode for a workspace.
    $stream = Open-DsrReadFile $manifest
    $bytes = [byte[]]::new(512)
    $length = 0
    try {
        while ($length -lt $bytes.Length) {
            $read = $stream.Read($bytes, $length, $bytes.Length - $length)
            if ($read -eq 0) { break }
            $length += $read
        }
    } finally { $stream.Dispose() }
    $firstLine = [Text.Encoding]::UTF8.GetString($bytes, 0, $length).Split("`n")[0]
    if (-not $firstLine.StartsWith('## ', [StringComparison]::Ordinal) -or
        -not @($firstLine.Substring(3).Split(';') | Where-Object { $_.Trim() -ceq 'workspace' }).Count) { return $null }
    $path = [IO.Path]::GetRelativePath($Source, $manifest).Replace('\', '/')
    if ($path -cnotin $Files) { Stop-DsrInstall 'Go workspace vendor mode requires committed vendor/modules.txt' 4 }
    return @{ path = $path; sha256 = (Get-DsrFileEvidence $manifest).sha256 }
}

function Get-DsrGoModuleContext {
    param([string]$Source, [string]$BuildRoot, [string[]]$Files, $GoBase, [string]$Logs)
    $location = Resolve-DsrGoSourceModule $Source $BuildRoot '.' $Files
    $module = Read-DsrGoSourceModule $location $GoBase $Logs 0
    $vendor = Get-DsrPlainPath ([IO.Path]::Combine($BuildRoot, 'vendor'))
    $vendorMode = [IO.Directory]::Exists($vendor)
    $vendorHash = ''
    if ($vendorMode) {
        $manifest = Get-DsrPlainPath ([IO.Path]::Combine($vendor, 'modules.txt'))
        if ([IO.File]::Exists($manifest) -or [IO.Directory]::Exists($manifest)) {
            $path = [IO.Path]::GetRelativePath($Source, $manifest).Replace('\', '/')
            if ($path -cnotin $Files) { Stop-DsrInstall 'Go module vendor metadata must be an exact committed file' 4 }
            $null = Get-DsrPlainPath $manifest -File
            $vendorHash = (Get-DsrFileEvidence $manifest).sha256
        }
        # Preserve legacy module vendor directories without modules.txt when
        # Go admits them. Explicit vendor mode never reads replacement originals.
    }
    $replacements = [Collections.Generic.List[object]]::new()
    $replacementModules = @{}
    $replacementModules[$module.path] = $module
    $moduleIndex = 1
    if (-not $vendorMode) {
        foreach ($replacement in $module.replacements) {
            $rule = Get-DsrGoSourceReplacement $replacement
            if ($rule.replacement_version) { continue }
            # Admission does not resolve an external dependency graph merely
            # to prove a declaration unused. Every main-module local rule must
            # stay within the selected commit, as it does for a Go workspace.
            $location = Resolve-DsrGoSourceModule $Source $BuildRoot $rule.replacement $Files
            if ($replacementModules.ContainsKey($location.path)) { $selected = $replacementModules[$location.path] }
            else {
                $selected = Read-DsrGoSourceModule $location $GoBase $Logs $moduleIndex
                $moduleIndex++
                $replacementModules[$location.path] = $selected
            }
            # Go ignores replace directives declared by dependency modules.
            $replacements.Add(@{ module_path = $rule.module_path; version = $rule.version;
                path = $selected.path; replacement_module_path = $selected.module_path; go_mod_sha256 = $selected.go_mod_sha256 })
        }
    }
    $receipt = @{ path = $module.path; module_path = $module.module_path; go_mod_sha256 = $module.go_mod_sha256;
        local_replacements = @($replacements.ToArray()); vendor = $vendorMode }
    if ($vendorHash) { $receipt.vendor_modules_sha256 = $vendorHash }
    return @{ workspace = 'off'; module_mode = $(if ($vendorMode) { 'vendor' } else { 'readonly' });
        receipt = $null; module_receipt = $receipt }
}

function Get-DsrGoSourceContext {
    param([string]$Source, [string]$BuildRoot, [string[]]$Files, $GoBase, [string]$Logs)
    $cursor = $BuildRoot
    $workspace = ''
    $workspacePath = ''
    while ($true) {
        $candidate = Get-DsrPlainPath ([IO.Path]::Combine($cursor, 'go.work'))
        if ([IO.File]::Exists($candidate) -or [IO.Directory]::Exists($candidate)) {
            $workspacePath = [IO.Path]::GetRelativePath($Source, $candidate).Replace('\', '/')
            if ($workspacePath -cnotin $Files) { Stop-DsrInstall 'Go workspace must be an exact committed file' 4 }
            $workspace = Get-DsrPlainPath $candidate -File
            break
        }
        if ($cursor -ceq $Source) { break }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
        $relative = [IO.Path]::GetRelativePath($Source, $cursor).Replace('\', '/')
        if (-not (Test-DsrSourceRelativePath $relative -Root)) {
            Stop-DsrInstall 'Go workspace discovery escaped the pinned source checkout' 4
        }
    }
    if (-not $workspace) {
        return Get-DsrGoModuleContext $Source $BuildRoot $Files $GoBase $Logs
    }

    # These parse-only commands keep GOWORK=off, GOENV=off and a local
    # toolchain. Go's own parser handles quoting and replacement syntax.
    $text = Invoke-DsrSourceCommand @GoBase -Arguments @('work', 'edit', '-json', $workspace) `
        -Log ([IO.Path]::Combine($Logs, 'go-workspace')) -Capture
    $document = ConvertFrom-DsrJson $text
    if ($document -isnot [Collections.IDictionary] -or -not $document.Contains('Use') -or
        $document.Use -isnot [array] -or $document.Use.Count -eq 0) {
        Stop-DsrInstall 'Go workspace must select committed main modules' 4
    }
    $workRules = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $selectedRules = [Collections.Generic.List[object]]::new()
    if ($document.Contains('Replace') -and $null -ne $document.Replace) {
        if ($document.Replace -isnot [array]) { Stop-DsrInstall 'Invalid Go workspace replacements' 4 }
        foreach ($replacement in $document.Replace) {
            $rule = Get-DsrGoSourceReplacement $replacement
            $key = $rule.module_path + [char]0 + $rule.version
            if ($workRules.ContainsKey($key)) { Stop-DsrInstall 'Duplicate Go workspace replacement' 4 }
            $workRules.Add($key, $rule)
            $selectedRules.Add(@{ rule = $rule; root = $cursor })
        }
    }
    $modules = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::Ordinal)
    $moduleNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $moduleIndex = 0
    foreach ($use in $document.Use) {
        if ($use -isnot [Collections.IDictionary] -or -not $use.Contains('DiskPath')) {
            Stop-DsrInstall 'Invalid Go workspace use declaration' 4
        }
        $location = Resolve-DsrGoSourceModule $Source $cursor $use.DiskPath $Files
        if ($modules.ContainsKey($location.path)) { Stop-DsrInstall 'Duplicate Go workspace module directory' 4 }
        $module = Read-DsrGoSourceModule $location $GoBase $Logs $moduleIndex
        $moduleIndex++
        if (-not $moduleNames.Add($module.module_path)) { Stop-DsrInstall 'Duplicate Go workspace module identity' 4 }
        $modules.Add($module.path, $module)
        foreach ($replacement in $module.replacements) {
            $rule = Get-DsrGoSourceReplacement $replacement
            # Workspace rules own their matching selections. A wildcard
            # workspace rule overrides every version-specific module rule.
            if ($workRules.ContainsKey($rule.module_path + [char]0 + $rule.version) -or
                $workRules.ContainsKey($rule.module_path + [char]0)) { continue }
            $selectedRules.Add(@{ rule = $rule; root = $module.root })
        }
    }
    $vendorManifest = Get-DsrGoWorkspaceVendor $Source $cursor $Files
    $vendorMode = $null -ne $vendorManifest
    $replacementModules = @{}
    $localReplacements = [Collections.Generic.List[object]]::new()
    foreach ($selection in $selectedRules) {
        $rule = $selection.rule
        # Explicit vendor mode consumes the committed vendor tree rather
        # than local replacement originals, which need not be available.
        # Every fetched file already passed the plain tracked-tree admission.
        if ($vendorMode -or $rule.replacement_version) { continue }
        $location = Resolve-DsrGoSourceModule $Source $selection.root $rule.replacement $Files
        if ($modules.ContainsKey($location.path)) { $module = $modules[$location.path] }
        elseif ($replacementModules.ContainsKey($location.path)) { $module = $replacementModules[$location.path] }
        else {
            $module = Read-DsrGoSourceModule $location $GoBase $Logs $moduleIndex
            $moduleIndex++
            $replacementModules[$location.path] = $module
        }
        # A replacement dependency's own replace directives do not apply in
        # Go. Retain its manifest identity without adopting those directives.
        $localReplacements.Add(@{ module_path = $rule.module_path; version = $rule.version;
            path = $module.path; replacement_module_path = $module.module_path; go_mod_sha256 = $module.go_mod_sha256 })
    }
    $moduleReceipts = @($modules.Values | ForEach-Object {
        @{ path = $_.path; module_path = $_.module_path; go_mod_sha256 = $_.go_mod_sha256 }
    })
    $receipt = @{ path = $workspacePath; sha256 = (Get-DsrFileEvidence $workspace).sha256;
        modules = $moduleReceipts; local_replacements = @($localReplacements.ToArray()); vendor = $vendorMode }
    if ($vendorMode) { $receipt.vendor_modules_sha256 = $vendorManifest.sha256 }
    return @{ workspace = $workspace; module_mode = $(if ($vendorMode) { 'vendor' } else { 'readonly' }); receipt = $receipt }
}

function Build-DsrRustSourceOutputs {
    param($Policy, $Selection, [string]$Platform, [string]$Source, [string[]]$Files,
        [string]$BuildRoot, [string]$Output, [string]$Logs, [string]$Work, [int]$Timeout,
        [string]$Cargo, [string]$Rustc)
    # Revalidate the embedded selection at the compiler boundary as well as
    # public admission. Each feature remains one argv value; repository data
    # never becomes a shell fragment or another Cargo option.
    Assert-DsrSourcePolicy $Policy.source
    [string[]]$features = @()
    if ($Policy.source.Contains('features')) { $features = @($Policy.source.features) }
    $noDefaultFeatures = $Policy.source.Contains('no_default_features') -and $Policy.source.no_default_features
    $featureArguments = @()
    if ($noDefaultFeatures) { $featureArguments += '--no-default-features' }
    foreach ($feature in $features) { $featureArguments += @('--features', $feature) }
    $target = $Selection.target_triple
    $targetPattern = switch ($Platform) {
        'windows/amd64' { '^x86_64-pc-windows-(msvc|gnu|gnullvm)$' }
        'windows/arm64' { '^aarch64-pc-windows-(msvc|gnullvm)$' }
        'windows/386' { '^i686-pc-windows-(msvc|gnu|gnullvm)$' }
        default { Stop-DsrInstall 'Unsupported Windows Rust source platform' 4 }
    }
    if ($target -cnotmatch $targetPattern) { Stop-DsrInstall 'Configured Cargo target does not match the Windows installation platform' 4 }
    $manifest = Get-DsrPlainPath ([IO.Path]::Combine($BuildRoot, 'Cargo.toml')) -File
    $targetDirectory = New-DsrPrivateDirectory ([IO.Path]::Combine($Work, 'cargo-target'))
    $environment = Get-DsrSourceGitEnvironment $Policy.repo
    # Respect the installed toolchain and dependency caches, but never install
    # a missing rustup-selected compiler or reuse the caller's build outputs.
    $environment.RUSTUP_AUTO_INSTALL = '0'
    $environment.RUSTC = $Rustc
    $environment.RUSTC_WRAPPER = ''
    $environment.RUSTC_WORKSPACE_WRAPPER = ''
    # An empty flag variable still overrides Cargo's committed configuration.
    # Remove ambient overrides so the selected project's own cfg/link flags apply.
    $environment.RUSTFLAGS = $null
    $environment.CARGO_ENCODED_RUSTFLAGS = $null
    $environment.CARGO_BUILD_RUSTFLAGS = $null
    $environment.CARGO_BUILD_TARGET = $target
    $environment.CARGO_TARGET_DIR = $targetDirectory
    $environment.CARGO_INCREMENTAL = '0'
    $cargoBase = @{ Executable = $Cargo; Directory = $BuildRoot; Timeout = $Timeout; Environment = $environment }
    $compiler = (Invoke-DsrSourceCommand $Rustc @('-vV') $BuildRoot ([IO.Path]::Combine($Logs, 'compiler')) $Timeout $environment -Capture).Trim()
    $cargoVersion = (Invoke-DsrSourceCommand @cargoBase -Arguments @('--version') -Log ([IO.Path]::Combine($Logs, 'cargo-version')) -Capture).Trim()
    if ($compiler -cnotmatch '^rustc [0-9]' -or $compiler.Length -gt 4096 -or
        $cargoVersion -cnotmatch '^cargo [0-9]' -or $cargoVersion.Length -gt 4096) {
        Stop-DsrInstall 'Invalid installed Rust compiler identity' 6
    }
    # Nonresolving metadata describes declared providers. A bare feature for
    # build --package can belong only to that member, not the current root;
    # applying it here would reject a valid build before package selection.
    $metadataArguments = @('metadata', '--format-version=1', '--no-deps', '--locked', '--manifest-path', $manifest)
    $metadataText = Invoke-DsrSourceCommand @cargoBase -Arguments $metadataArguments -Log ([IO.Path]::Combine($Logs, 'cargo-metadata')) -Capture
    $metadata = ConvertFrom-DsrJson $metadataText
    if ($metadata -isnot [Collections.IDictionary] -or -not $metadata.Contains('version') -or $metadata.version -ne 1 -or
        -not $metadata.Contains('packages') -or $metadata.packages -isnot [array] -or
        -not $metadata.Contains('workspace_members') -or $metadata.workspace_members -isnot [array] -or
        -not $metadata.Contains('workspace_root') -or $metadata.workspace_root -isnot [string]) {
        Stop-DsrInstall 'Cargo returned an incomplete source workspace' 6
    }
    $workspace = Get-DsrPlainPath $metadata.workspace_root -Directory
    $workspaceRelative = [IO.Path]::GetRelativePath($Source, $workspace).Replace('\', '/')
    if (-not (Test-DsrSourceRelativePath $workspaceRelative -Root)) { Stop-DsrInstall 'Cargo workspace escaped the pinned source checkout' 6 }
    $lock = [IO.Path]::Combine($workspace, 'Cargo.lock')
    $lockRelative = [IO.Path]::GetRelativePath($Source, $lock).Replace('\', '/')
    $manifestRelative = [IO.Path]::GetRelativePath($Source, $manifest).Replace('\', '/')
    $workspaceManifest = Get-DsrPlainPath ([IO.Path]::Combine($workspace, 'Cargo.toml')) -File
    $workspaceManifestRelative = [IO.Path]::GetRelativePath($Source, $workspaceManifest).Replace('\', '/')
    if ($lockRelative -cnotin $Files -or $manifestRelative -cnotin $Files -or $workspaceManifestRelative -cnotin $Files) {
        Stop-DsrInstall 'Rust source installation requires a committed Cargo.toml and workspace Cargo.lock' 4
    }
    $null = Get-DsrPlainPath $lock -File
    $pathComparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $packages = @($metadata.packages | Where-Object { $_.id -cin $metadata.workspace_members })
    if ($Policy.source.package) {
        $packages = @($packages | Where-Object { $_.name -ceq $Policy.source.package })
        if ($packages.Count -ne 1) { Stop-DsrInstall 'Requested Cargo source package is not one workspace member' 6 }
    } elseif ($Selection.binaries.Count -eq 1) {
        # Match cargo build's current-package/default-members behavior. A
        # complete multi-package family deliberately selects the workspace.
        if ($manifest.Equals($workspaceManifest, $pathComparison) -and $metadata.Contains('workspace_default_members')) {
            # An explicit workspace default-members selection also applies
            # when the workspace root is itself a package.
            $packages = @($packages | Where-Object { $_.id -cin $metadata.workspace_default_members })
        } else {
            $current = @($packages | Where-Object { [IO.Path]::GetFullPath($_.manifest_path).Equals($manifest, $pathComparison) })
            if ($current.Count -eq 1) { $packages = $current }
            elseif ($metadata.Contains('workspace_default_members')) {
                $packages = @($packages | Where-Object { $_.id -cin $metadata.workspace_default_members })
            }
        }
    }
    $providers = @()
    foreach ($name in $Selection.binaries) {
        $bin = $name.Substring(0, $name.Length - 4)
        $providerMatches = @()
        foreach ($package in $packages) {
            foreach ($candidate in $package.targets) {
                if ($candidate.name -ceq $bin -and 'bin' -cin $candidate.kind) {
                    $packageManifest = Get-DsrPlainPath $package.manifest_path -File
                    $entry = Get-DsrPlainPath $candidate.src_path -File
                    $packageRelative = [IO.Path]::GetRelativePath($Source, $packageManifest).Replace('\', '/')
                    $entryRelative = [IO.Path]::GetRelativePath($Source, $entry).Replace('\', '/')
                    if ($packageRelative -cnotin $Files -or $entryRelative -cnotin $Files) {
                        Stop-DsrInstall 'Cargo executable provider is outside the committed source inventory' 6
                    }
                    $providerMatches += @{ name = $name; cargo_bin = $bin; package = $package.name;
                        package_id = $package.id; manifest = $packageRelative; entry = $entryRelative }
                }
            }
        }
        if ($providerMatches.Count -ne 1) { Stop-DsrInstall ('Cargo must identify exactly one source provider for ' + $name) 6 }
        $providers += $providerMatches[0]
    }
    $buildArguments = @('build', '--locked', '--release', '--message-format=json-render-diagnostics',
        '--manifest-path', $manifest, '--target', $target, '--target-dir', $targetDirectory)
    if ($Policy.source.package) { $buildArguments += @('--package', $Policy.source.package) }
    elseif ($Selection.binaries.Count -gt 1) { $buildArguments += '--workspace' }
    foreach ($provider in $providers) { $buildArguments += @('--bin', $provider.cargo_bin) }
    $buildArguments += $featureArguments
    $buildText = Invoke-DsrSourceCommand @cargoBase -Arguments $buildArguments -Log ([IO.Path]::Combine($Logs, 'cargo-build')) -Capture
    $artifacts = @()
    foreach ($line in $buildText.Split("`n")) {
        if (-not $line.StartsWith('{', [StringComparison]::Ordinal)) { continue }
        $record = ConvertFrom-DsrJson $line
        if ($record -is [Collections.IDictionary] -and $record.Contains('reason') -and $record.reason -ceq 'compiler-artifact') {
            $artifacts += $record
        }
    }
    foreach ($provider in $providers) {
        $selected = @($artifacts | Where-Object { $_.target.name -ceq $provider.cargo_bin -and 'bin' -cin $_.target.kind })
        if ($selected.Count -ne 1 -or $selected[0].package_id -cne $provider.package_id -or
            $selected[0].executable -isnot [string] -or -not $selected[0].executable) {
            Stop-DsrInstall ('Cargo did not produce one executable from its selected provider: ' + $provider.name) 6
        }
        $record = $selected[0]
        if (-not $record.Contains('manifest_path') -or $record.manifest_path -isnot [string] -or
            -not [IO.Path]::IsPathFullyQualified($record.manifest_path) -or
            -not $record.target.Contains('src_path') -or $record.target.src_path -isnot [string] -or
            -not [IO.Path]::IsPathFullyQualified($record.target.src_path)) {
            Stop-DsrInstall ('Cargo executable lacks its admitted source identity: ' + $provider.name) 6
        }
        $builtManifest = Get-DsrPlainPath $record.manifest_path -File
        $builtEntry = Get-DsrPlainPath $record.target.src_path -File
        if (-not $builtManifest.Equals([IO.Path]::GetFullPath([IO.Path]::Combine($Source, $provider.manifest)), $pathComparison) -or
            -not $builtEntry.Equals([IO.Path]::GetFullPath([IO.Path]::Combine($Source, $provider.entry)), $pathComparison)) {
            Stop-DsrInstall ('Cargo executable changed its admitted source provider: ' + $provider.name) 6
        }
        $expected = [IO.Path]::Combine($targetDirectory, $target, 'release', $provider.name)
        $produced = Get-DsrPlainPath $selected[0].executable -File
        if (-not $produced.Equals($expected, $pathComparison)) { Stop-DsrInstall 'Cargo output escaped its private target selection' 6 }
        Assert-DsrPeMachine $produced $Platform
        $evidence = Get-DsrFileEvidence $produced
        $destination = [IO.Path]::Combine($Output, $provider.name)
        Copy-DsrNewFile $produced $destination
        if (-not (Test-DsrSameEvidence $evidence (Get-DsrFileEvidence $destination))) {
            Stop-DsrInstall 'Cargo output changed while staging the executable family' 7
        }
    }
    return @{ compiler = $compiler; cargo_version = $cargoVersion; cargo_target = $target;
        source_package = $Policy.source.package; source_entries = @($providers);
        cargo_features = @($features); cargo_no_default_features = [bool]$noDefaultFeatures }
}

function Get-DsrBunDependencyContext {
    param([string]$Source, [string]$BuildRoot, [string[]]$Files)
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $member = [IO.Path]::GetRelativePath($Source, $BuildRoot).Replace('\', '/')
    if (-not (Test-DsrSourceRelativePath $member -Root)) { Stop-DsrInstall 'Bun package escaped the pinned source checkout' 4 }
    $cursor = $BuildRoot
    while ($true) {
        $locks = @()
        foreach ($name in @('bun.lock', 'bun.lockb')) {
            $path = Get-DsrPlainPath ([IO.Path]::Combine($cursor, $name))
            if (-not [IO.File]::Exists($path)) { continue }
            $relative = [IO.Path]::GetRelativePath($Source, $path).Replace('\', '/')
            if ($relative -cnotin $Files) { Stop-DsrInstall 'Bun source lockfiles must be committed regular files' 4 }
            $evidence = Get-DsrFileEvidence $path
            $locks += @{ path = $relative; sha256 = $evidence.sha256; size_bytes = $evidence.size_bytes }
        }
        if ($locks.Count -gt 0) {
            $manifest = Get-DsrPlainPath ([IO.Path]::Combine($cursor, 'package.json')) -File
            $relative = [IO.Path]::GetRelativePath($Source, $manifest).Replace('\', '/')
            if ($relative -cnotin $Files) { Stop-DsrInstall 'Bun dependency root requires a committed package.json' 4 }
            if (-not $cursor.Equals($BuildRoot, $comparison)) {
                $document = ConvertFrom-DsrJson (Read-DsrTextFile $manifest 8388608)
                $patterns = $null
                if ($document -is [Collections.IDictionary] -and $document.Contains('workspaces')) { $patterns = $document.workspaces }
                if ($patterns -is [Collections.IDictionary]) { $patterns = $patterns['packages'] }
                if ($patterns -isnot [array] -or $patterns.Count -eq 0 -or
                    @($patterns | Where-Object { $_ -isnot [string] -or -not $_ }).Count -gt 0) {
                    Stop-DsrInstall 'Bun ancestor lock requires a declared workspace' 4
                }
            }
            return @{ root = $cursor; locks = @($locks); package_json_sha256 = (Get-DsrFileEvidence $manifest).sha256 }
        }
        if ($cursor.Equals($Source, $comparison)) { break }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    Stop-DsrInstall 'Bun source installation requires a committed bun.lock or bun.lockb in the selected package or its workspace' 4
}

function Build-DsrBunSourceOutputs {
    param($Policy, $Selection, [string]$Platform, [string]$Source, [string[]]$Files,
        [string]$BuildRoot, [string]$Output, [string]$Logs, [int]$Timeout, [string]$Bun)
    $target = switch ($Platform) {
        'windows/amd64' { 'bun-windows-x64-baseline' }
        'windows/arm64' { 'bun-windows-arm64' }
        default { Stop-DsrInstall 'Unsupported Windows Bun source platform' 4 }
    }
    $manifestPath = Get-DsrPlainPath ([IO.Path]::Combine($BuildRoot, 'package.json')) -File
    $manifestRelative = [IO.Path]::GetRelativePath($Source, $manifestPath).Replace('\', '/')
    if ($manifestRelative -cnotin $Files) { Stop-DsrInstall 'Bun source installation requires a committed package.json' 4 }
    $manifest = ConvertFrom-DsrJson (Read-DsrTextFile $manifestPath 8388608)
    if ($manifest -isnot [Collections.IDictionary]) { Stop-DsrInstall 'Bun package.json must be an object' 4 }
    $context = Get-DsrBunDependencyContext $Source $BuildRoot $Files
    $primary = $Policy.binary_name
    if (-not $primary.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $primary += '.exe' }
    $entries = @()
    foreach ($name in $Selection.binaries) {
        $isPrimary = $name.Equals($primary, [StringComparison]::OrdinalIgnoreCase)
        $entry = if ($isPrimary) { $Policy.source.entry } else { '' }
        if (-not $entry) {
            $key = $name.Substring(0, $name.Length - 4)
            $bins = if ($manifest.Contains('bin')) { $manifest.bin } else { $null }
            if ($bins -is [Collections.IDictionary]) {
                $matches = @($bins.Keys | Where-Object { $_ -ceq $key })
                if ($matches.Count -eq 1) { $entry = $bins[$matches[0]] }
            } elseif ($isPrimary -and $bins -is [string]) { $entry = $bins }
        }
        if ($entry -is [string] -and $entry.StartsWith('./', [StringComparison]::Ordinal)) { $entry = $entry.Substring(2) }
        if (-not (Test-DsrSourceRelativePath $entry)) {
            Stop-DsrInstall ('Missing or unsafe Bun source entry for ' + $name + '; declare package.json bin or source_entry') 4
        }
        $path = Get-DsrPlainPath ([IO.Path]::Combine($BuildRoot, $entry)) -File
        $relative = [IO.Path]::GetRelativePath($Source, $path).Replace('\', '/')
        if ($relative -cnotin $Files) { Stop-DsrInstall ('Bun entry must be a committed regular source file: ' + $entry) 4 }
        $entries += @{ name = $name; entry = $entry }
    }
    $environment = Get-DsrSourceGitEnvironment $Policy.repo
    # Ambient preloads must not replace the selected project's startup code.
    # Dependency settings and committed bunfig.toml still apply; this is an
    # explicitly requested source build, not a hermetic dependency sandbox.
    $environment.NODE_OPTIONS = $null
    $environment.BUN_OPTIONS = $null
    $bunBase = @{ Executable = $Bun; Directory = $BuildRoot; Timeout = $Timeout; Environment = $environment }
    $compiler = (Invoke-DsrSourceCommand @bunBase -Arguments @('--version') -Log ([IO.Path]::Combine($Logs, 'compiler')) -Capture).Trim()
    if ($compiler.Length -gt 256 -or $compiler -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.+-]+)?$') {
        Stop-DsrInstall 'Bun did not identify its compiler version' 6
    }
    # Bun supplies workspace membership and glob semantics. An ancestor lock
    # must never be borrowed by an unrelated nested package.
    $projectBin = (Invoke-DsrSourceCommand @bunBase -Arguments @('pm', 'bin') -Log ([IO.Path]::Combine($Logs, 'bun-project')) -Capture).TrimEnd([char[]]"`r`n")
    $expectedBin = [IO.Path]::Combine($context.root, 'node_modules', '.bin')
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $projectBin.Replace('\', '/').Equals($expectedBin.Replace('\', '/'), $comparison)) {
        Stop-DsrInstall 'Bun did not select the committed dependency root for this source package' 4
    }
    $null = Invoke-DsrSourceCommand $Bun @('install', '--frozen-lockfile') $context.root ([IO.Path]::Combine($Logs, 'dependencies')) $Timeout $environment
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $entry = $entries[$index]
        $null = Get-DsrPlainPath ([IO.Path]::Combine($BuildRoot, $entry.entry)) -File
        $path = [IO.Path]::Combine($Output, $entry.name)
        $arguments = @('build', '--compile', ('--target=' + $target), '--outfile', $path, ('./' + $entry.entry))
        $null = Invoke-DsrSourceCommand @bunBase -Arguments $arguments -Log ([IO.Path]::Combine($Logs, ('build-' + $index)))
    }
    $details = @{ compiler = $compiler; bun_target = $target; source_entry = $Policy.source.entry;
        source_entries = @($entries); bun_lockfiles = @($context.locks);
        package_json_sha256 = (Get-DsrFileEvidence $manifestPath).sha256 }
    if (-not $context.root.Equals($BuildRoot, $comparison)) {
        $details.bun_workspace = @{ root = [IO.Path]::GetRelativePath($Source, $context.root).Replace('\', '/');
            member = [IO.Path]::GetRelativePath($context.root, $BuildRoot).Replace('\', '/');
            package_json_sha256 = $context.package_json_sha256 }
    }
    return $details
}

function Build-DsrSourceFamily {
    param($Policy, $Selection, [string]$Platform, [string]$Reference, [string]$Work, [int]$Timeout)
    Assert-DsrSourcePolicy $Policy.source
    if ($Reference -cnotmatch '^(HEAD|[0-9a-fA-F]{40}|[0-9a-fA-F]{64}|refs/(heads|tags)/[A-Za-z0-9][A-Za-z0-9._/+\-]*)$' -or
        $Reference.Contains('..') -or $Reference.EndsWith('/') -or $Reference.EndsWith('.')) {
        Stop-DsrInstall 'Use HEAD, a full commit SHA, refs/heads/BRANCH or refs/tags/TAG for -SourceRef'
    }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $compilerName = switch ($Policy.source.language) {
        'rust' { 'cargo' }
        'go' { 'go' }
        default { 'bun' }
    }
    $compilerTool = Get-Command $compilerName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $rustc = if ($Policy.source.language -ceq 'rust') { Get-Command rustc -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
    if ($null -eq $git -or $null -eq $compilerTool -or ($Policy.source.language -ceq 'rust' -and $null -eq $rustc)) {
        Stop-DsrInstall ('Source installation requires existing Git and ' + $compilerName + ' tools; no toolchain is installed automatically') 3
    }
    $logs = New-DsrPrivateDirectory ([IO.Path]::Combine($Work, 'logs'))
    $source = New-DsrPrivateDirectory ([IO.Path]::Combine($Work, 'source'))
    $output = New-DsrPrivateDirectory ([IO.Path]::Combine($Work, 'output'))
    $graph = @{ git = $git.Source; root = $source; logs = $logs; timeout = $Timeout; clock = [Diagnostics.Stopwatch]::StartNew();
        nodes = [Collections.Generic.List[object]]::new(); files = [Collections.Generic.List[string]]::new(); entry_count = 0;
        materializations = [Collections.Generic.List[object]]::new() }
    $rootRepository = Add-DsrSourceRepository $graph $Policy.repo $Reference $source
    $commit = $rootRepository.source_commit
    $graph.files.Sort([StringComparer]::Ordinal)
    $files = $graph.files.ToArray()
    Assert-DsrSourceMaterializations $graph
    Assert-DsrSourceGraph $graph 'initial'
    $sourceEvidence = Get-DsrSourceTreeEvidence $source $files $graph.materializations.ToArray()
    $buildRoot = if ($Policy.source.subdir -ceq '.') { $source } else { [IO.Path]::Combine($source, $Policy.source.subdir) }
    $buildRoot = Get-DsrPlainPath $buildRoot -Directory
    $primary = $Policy.binary_name
    if (-not $primary.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $primary += '.exe' }
    if ($Policy.source.language -ceq 'go') {
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
        $environment.GO111MODULE = 'on'
        $environment.GOOS = 'windows'
        $environment.GOARCH = $Platform.Substring('windows/'.Length)
        $goBase = @{ Executable = $compilerTool.Source; Directory = $buildRoot; Timeout = $Timeout; Environment = $environment }
        $compiler = (Invoke-DsrSourceCommand $compilerTool.Source @('version') $buildRoot ([IO.Path]::Combine($logs, 'compiler')) $Timeout $environment -Capture).Trim()
        if (-not $compiler -or $compiler.Length -gt 4096) { Stop-DsrInstall 'Invalid installed Go compiler identity' 6 }
        $goContext = Get-DsrGoSourceContext $source $buildRoot $files $goBase $logs
        $environment.GOWORK = $goContext.workspace
        $moduleMode = $goContext.module_mode
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
        $sourceEntries = @()
        for ($index = 0; $index -lt $Selection.binaries.Count; $index++) {
            $sourceEntries += @{ name = $Selection.binaries[$index]; entry = $entries[$index] }
        }
        $compilerDetails = @{ compiler = $compiler; go_target = @{ os = 'windows'; arch = $environment.GOARCH };
            source_entry = $Policy.source.entry; source_entries = @($sourceEntries) }
        if ($null -ne $goContext.receipt) { $compilerDetails.go_workspace = $goContext.receipt }
        if ($goContext.Contains('module_receipt')) { $compilerDetails.go_module = $goContext.module_receipt }
    } elseif ($Policy.source.language -ceq 'rust') {
        $compilerDetails = Build-DsrRustSourceOutputs $Policy $Selection $Platform $source $files $buildRoot $output $logs $Work $Timeout $compilerTool.Source $rustc.Source
    } else {
        $compilerDetails = Build-DsrBunSourceOutputs $Policy $Selection $Platform $source $files $buildRoot $output $logs $Timeout $compilerTool.Source
    }
    Assert-DsrSourceGraph $graph 'final'
    Assert-DsrSourceMaterializations $graph
    if ((Get-DsrSourceTreeEvidence $source $files $graph.materializations.ToArray()) -cne $sourceEvidence) {
        Stop-DsrInstall 'Source compilation changed the pinned tracked inputs' 7
    }
    $rows = @()
    $expected = @{}
    foreach ($name in $Selection.binaries) {
        $path = Get-DsrPlainPath ([IO.Path]::Combine($output, $name)) -File
        Assert-DsrPeMachine $path $Platform
        $evidence = Get-DsrFileEvidence $path
        $expected[$name] = $evidence
        $rows += @{ name = $name; sha256 = $evidence.sha256; size_bytes = $evidence.size_bytes }
    }
    $primaryRow = @($rows | Where-Object { $_.name.Equals($primary, [StringComparison]::OrdinalIgnoreCase) })[0]
    $receipt = @{ schema_version = 1; method = 'source'; repository = $Policy.repo; requested_ref = $Reference;
        source_commit = $commit; source_tree_sha256 = $sourceEvidence; language = $Policy.source.language;
        platform = $Platform;
        release_target_triple = $Selection.target_triple; source_subdir = $Policy.source.subdir;
        binaries = @($rows); sha256 = $primaryRow.sha256; size_bytes = $primaryRow.size_bytes; signed_release = $false }
    if ($graph.nodes.Count -gt 1) {
        $receipt.submodules = @($graph.nodes | Where-Object { $_.path } | ForEach-Object {
            @{ path = $_.path; repository = $_.repository; source_commit = $_.source_commit }
        })
    }
    if ($graph.materializations.Count -gt 0) {
        $receipt.materialized_symlinks = @($graph.materializations | ForEach-Object {
            @{ path = $_.path; git_blob = $_.git_blob; link_target = $_.link_target;
                referent_path = $_.referent_path; referent_git_blob = $_.referent_git_blob;
                sha256 = $_.sha256; size_bytes = $_.size_bytes }
        })
    }
    foreach ($key in $compilerDetails.Keys) { $receipt[$key] = $compilerDetails[$key] }
    Write-DsrNewTextFile ([IO.Path]::Combine($Work, 'source-receipt.json')) ($receipt | ConvertTo-Json -Depth 8 -Compress)
    return @{ directory = $output; receipt = $receipt; expected = $expected }
}
