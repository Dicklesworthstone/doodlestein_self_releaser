# Embedded by the ordinary Windows installer generator. Source installation is
# explicit execution of repository/dependency code with existing Git and Rust/Go;
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
    Assert-DsrFields $Source @('language', 'subdir') @('entry', 'package')
    if (-not (Test-DsrSourceRelativePath $Source.subdir -Root)) { Stop-DsrInstall 'Invalid embedded Windows source directory' }
    if ($Source.language -ceq 'go') {
        Assert-DsrFields $Source @('language', 'subdir', 'entry')
        if ($Source.entry -isnot [string] -or ($Source.entry -and -not (Test-DsrSourceRelativePath $Source.entry -Root))) {
            Stop-DsrInstall 'Invalid embedded Windows Go source selection'
        }
    } elseif ($Source.language -ceq 'rust') {
        Assert-DsrFields $Source @('language', 'subdir', 'package')
        if ($Source.package -isnot [string] -or ($Source.package -and
            ($Source.package.Length -gt 128 -or -not (Test-DsrName $Source.package)))) {
            Stop-DsrInstall 'Invalid embedded Windows Rust source selection'
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
            Stop-DsrInstall 'Source installation requires regular tracked files; submodules and symbolic links are unsupported' 4
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

# Go workspace paths are relative to the file declaring them. Resolve them
# within the fetched tree, including ordinary ../ siblings, without admitting
# an ambient workspace, an absolute checkout path or a linked module root.
function Resolve-DsrGoSourceModule {
    param([string]$Source, [string]$Base, $Relative, [string[]]$Files)
    if ($Relative -isnot [string] -or -not $Relative -or $Relative.Length -gt 1024) {
        Stop-DsrInstall 'Invalid Go workspace module path' 4
    }
    $relativePath = $Relative.Replace('\', '/')
    foreach ($part in $relativePath.Split('/')) {
        if ($part -cin @('.', '..')) { continue }
        if (-not (Test-DsrSourceRelativePath $part)) { Stop-DsrInstall 'Unsafe Go workspace module path' 4 }
    }
    $root = [IO.Path]::GetFullPath([IO.Path]::Combine($Base, $relativePath))
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
        $null = Get-DsrPlainPath ([IO.Path]::Combine($BuildRoot, 'go.mod')) -File
        $vendor = Get-DsrPlainPath ([IO.Path]::Combine($BuildRoot, 'vendor'))
        return @{ workspace = 'off'; module_mode = $(if ([IO.Directory]::Exists($vendor)) { 'vendor' } else { 'readonly' }); receipt = $null }
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
    if ($lockRelative -cnotin $Files -or $manifestRelative -cnotin $Files) {
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
        $current = @($packages | Where-Object { [IO.Path]::GetFullPath($_.manifest_path).Equals($manifest, $pathComparison) })
        if ($current.Count -eq 1) { $packages = $current }
        elseif ($metadata.Contains('workspace_default_members')) {
            $packages = @($packages | Where-Object { $_.id -cin $metadata.workspace_default_members })
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
        source_package = $Policy.source.package; source_entries = @($providers) }
}

function Build-DsrSourceFamily {
    param($Policy, $Selection, [string]$Platform, [string]$Reference, [string]$Work, [int]$Timeout)
    Assert-DsrSourcePolicy $Policy.source
    if ($Reference -cnotmatch '^(HEAD|[0-9a-fA-F]{40}|[0-9a-fA-F]{64}|refs/(heads|tags)/[A-Za-z0-9][A-Za-z0-9._/+\-]*)$' -or
        $Reference.Contains('..') -or $Reference.EndsWith('/') -or $Reference.EndsWith('.')) {
        Stop-DsrInstall 'Use HEAD, a full commit SHA, refs/heads/BRANCH or refs/tags/TAG for -SourceRef'
    }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $compilerName = if ($Policy.source.language -ceq 'rust') { 'cargo' } else { 'go' }
    $compilerTool = Get-Command $compilerName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $rustc = if ($Policy.source.language -ceq 'rust') { Get-Command rustc -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
    if ($null -eq $git -or $null -eq $compilerTool -or ($Policy.source.language -ceq 'rust' -and $null -eq $rustc)) {
        Stop-DsrInstall ('Source installation requires existing Git and ' + $compilerName + ' tools; no toolchain is installed automatically') 3
    }
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
    } else {
        $compilerDetails = Build-DsrRustSourceOutputs $Policy $Selection $Platform $source $files $buildRoot $output $logs $Work $Timeout $compilerTool.Source $rustc.Source
    }
    $finalCommit = (Invoke-DsrSourceGit @gitBase -Arguments @('rev-parse', '--verify', 'HEAD^{commit}') -Log ([IO.Path]::Combine($logs, 'git-final-pin')) -Capture).Trim()
    if ($finalCommit -cne $commit -or (Get-DsrSourceTreeEvidence $source $files) -cne $sourceEvidence) {
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
    foreach ($key in $compilerDetails.Keys) { $receipt[$key] = $compilerDetails[$key] }
    Write-DsrNewTextFile ([IO.Path]::Combine($Work, 'source-receipt.json')) ($receipt | ConvertTo-Json -Depth 8 -Compress)
    return @{ directory = $output; receipt = $receipt; expected = $expected }
}
