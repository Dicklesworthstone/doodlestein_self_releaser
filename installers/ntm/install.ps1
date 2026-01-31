# install.ps1 - Install ntm on Windows
#
# Usage:
#   iwr -useb https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.ps1 | iex
#   iwr -useb https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.ps1 | iex; Install-Tool -Version 1.2.3 -Yes
#
# Options:
#   -Version     Install specific version (default: latest)
#   -Prefix      Installation directory (default: %LOCALAPPDATA%\Programs\ntm\bin)
#   -CacheDir    Cache directory (default: %LOCALAPPDATA%\dsr\cache\installers)
#   -Offline     Use cached archives only
#   -Yes         Skip prompts (non-interactive)
#   -Verbose     Enable verbose logging
#   -Json        Output JSON on stdout for automation
#   -Help        Show help

[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$Prefix = "",
    [string]$CacheDir = "",
    [switch]$Offline,
    [switch]$Yes,
    [switch]$Verbose,
    [switch]$Json,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ToolName = "ntm"
$Repo = "Dicklesworthstone/ntm"
$BinaryName = "ntm"
$ArchiveFormat = "zip"
$ArtifactNaming = '${name}-${version}-${os}-${arch}'
$MinisignPubKey = ""

function Write-Log {
    param([string]$Level, [string]$Message)
    [Console]::Error.WriteLine("[$ToolName] [$Level] $Message")
}

function Write-VerboseLog {
    param([string]$Message)
    if ($Verbose) {
        Write-Log "DEBUG" $Message
    }
}

function Write-JsonResult {
    param(
        [string]$Status,
        [string]$Message,
        [string]$OutVersion = "",
        [string]$Path = ""
    )

    if ($Json) {
        $obj = [ordered]@{
            tool = $ToolName
            status = $Status
            message = $Message
            version = $OutVersion
            path = $Path
        }
        $obj | ConvertTo-Json -Depth 4
    }
}

function Show-Help {
    @"
install.ps1 - Install $ToolName on Windows

Usage:
  iwr -useb https://raw.githubusercontent.com/$Repo/main/install.ps1 | iex
  iwr -useb https://raw.githubusercontent.com/$Repo/main/install.ps1 | iex; Install-Tool -Version 1.2.3 -Yes

Options:
  -Version     Install specific version (default: latest)
  -Prefix      Installation directory (default: %LOCALAPPDATA%\Programs\$ToolName\bin)
  -CacheDir    Cache directory (default: %LOCALAPPDATA%\dsr\cache\installers)
  -Offline     Use cached archives only
  -Yes         Skip prompts (non-interactive)
  -Verbose     Enable verbose logging
  -Json        Output JSON on stdout for automation
  -Help        Show this help
"@ | Write-Output
}

function Get-PlatformArch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if (-not $arch) {
        return "amd64"
    }

    switch ($arch.ToUpper()) {
        "AMD64" { return "amd64" }
        "ARM64" { return "arm64" }
        "X86" { return "386" }
        default { return "amd64" }
    }
}

function Get-LatestVersion {
    $url = "https://api.github.com/repos/$Repo/releases/latest"
    $headers = @{ "Accept" = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" }
    if ($env:GITHUB_TOKEN) {
        $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN"
    }

    try {
        $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
        return $resp.tag_name
    } catch {
        Write-Log "ERROR" "Failed to fetch latest version from GitHub"
        throw
    }
}

function Get-ArtifactName {
    param([string]$Ver, [string]$Arch)

    $versionNum = $Ver.TrimStart("v")
    $name = $ArtifactNaming.Replace("${name}", $ToolName)
    $name = $name.Replace("${version}", $versionNum)
    $name = $name.Replace("${os}", "windows")
    $name = $name.Replace("${arch}", $Arch)
    return $name
}

function Download-File {
    param([string]$Url, [string]$Destination)

    Write-VerboseLog "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

function Get-ChecksumForFile {
    param([string]$Checksums, [string]$Filename)

    foreach ($line in $Checksums -split "`n") {
        $parts = $line.Trim() -split "\s+"
        if ($parts.Length -ge 2 -and $parts[1] -eq $Filename) {
            return $parts[0]
        }
    }
    return ""
}

function Verify-Checksum {
    param([string]$FilePath, [string]$ChecksumsUrl)

    if (-not $ChecksumsUrl) {
        return $true
    }

    try {
        $checksums = Invoke-WebRequest -Uri $ChecksumsUrl -UseBasicParsing | Select-Object -ExpandProperty Content
    } catch {
        Write-Log "ERROR" "Failed to download checksums"
        return $false
    }

    $filename = [System.IO.Path]::GetFileName($FilePath)
    $expected = Get-ChecksumForFile -Checksums $checksums -Filename $filename
    if (-not $expected) {
        Write-Log "WARN" "No checksum entry for $filename"
        return $true
    }

    $actual = (Get-FileHash -Algorithm SHA256 -Path $FilePath).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) {
        Write-Log "ERROR" "Checksum mismatch for $filename"
        return $false
    }

    Write-VerboseLog "Checksum verified for $filename"
    return $true
}

function Verify-Minisign {
    param([string]$FilePath, [string]$SigUrl)

    if (-not $MinisignPubKey) {
        return $true
    }

    $minisign = Get-Command minisign -ErrorAction SilentlyContinue
    if (-not $minisign) {
        Write-Log "WARN" "minisign not found; skipping signature verification"
        return $true
    }

    $sigFile = "$FilePath.minisig"
    try {
        Invoke-WebRequest -Uri $SigUrl -OutFile $sigFile -UseBasicParsing
    } catch {
        Write-Log "ERROR" "Failed to download minisign signature"
        return $false
    }

    $result = & $minisign.Source -Vm $FilePath -x $sigFile -P $MinisignPubKey 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR" "Signature verification failed"
        return $false
    }

    Write-VerboseLog "Signature verified"
    return $true
}

function Install-Tool {
    if ($Help) {
        Show-Help
        return
    }

    $installDir = if ($Prefix) { $Prefix } else { Join-Path $env:LOCALAPPDATA "Programs\$ToolName\bin" }
    $cacheRoot = if ($CacheDir) { $CacheDir } else { Join-Path $env:LOCALAPPDATA "dsr\cache\installers" }
    $cacheDir = Join-Path $cacheRoot $ToolName

    $nonInteractive = $Yes -or ($env:CI -eq "1")

    if (-not $Version) {
        Write-Log "INFO" "Detecting latest version..."
        $Version = Get-LatestVersion
    }

    $arch = Get-PlatformArch
    $artifactBase = Get-ArtifactName -Ver $Version -Arch $arch
    $archiveFile = Join-Path $cacheDir ("$artifactBase.$ArchiveFormat")
    $downloadUrl = "https://github.com/$Repo/releases/download/$Version/$artifactBase.$ArchiveFormat"
    $checksumsUrl = "https://github.com/$Repo/releases/download/$Version/${ToolName}-$($Version.TrimStart('v'))-SHA256SUMS.txt"

    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

    if ($Offline) {
        if (-not (Test-Path $archiveFile)) {
            Write-Log "ERROR" "Offline mode: cached archive not found at $archiveFile"
            Write-JsonResult -Status "error" -Message "offline archive missing" -OutVersion $Version
            exit 1
        }
    } else {
        Write-Log "INFO" "Downloading $downloadUrl"
        Download-File -Url $downloadUrl -Destination $archiveFile
    }

    if (-not (Verify-Checksum -FilePath $archiveFile -ChecksumsUrl $checksumsUrl)) {
        Write-JsonResult -Status "error" -Message "checksum failed" -OutVersion $Version
        exit 1
    }

    $sigUrl = "$downloadUrl.minisig"
    if (-not (Verify-Minisign -FilePath $archiveFile -SigUrl $sigUrl)) {
        Write-JsonResult -Status "error" -Message "signature verification failed" -OutVersion $Version
        exit 1
    }

    $extractDir = Join-Path $cacheDir "extract"
    if (Test-Path $extractDir) {
        Remove-Item -Force -Recurse $extractDir
    }
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

    Expand-Archive -Path $archiveFile -DestinationPath $extractDir -Force

    $binaryFile = Get-ChildItem -Path $extractDir -Recurse -File | Where-Object { $_.Name -eq "$BinaryName.exe" } | Select-Object -First 1
    if (-not $binaryFile) {
        Write-Log "ERROR" "Binary not found in archive"
        Write-JsonResult -Status "error" -Message "binary not found" -OutVersion $Version
        exit 1
    }

    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    $destFile = Join-Path $installDir "$BinaryName.exe"

    if (Test-Path $destFile -and -not $nonInteractive) {
        $resp = Read-Host "Overwrite existing $destFile? (y/N)"
        if ($resp -ne "y" -and $resp -ne "Y") {
            Write-Log "INFO" "Installation cancelled"
            Write-JsonResult -Status "cancelled" -Message "user cancelled" -OutVersion $Version
            exit 0
        }
    } elseif (Test-Path $destFile -and $nonInteractive) {
        Write-Log "ERROR" "Existing file at $destFile (use -Yes to overwrite)"
        Write-JsonResult -Status "error" -Message "destination exists" -OutVersion $Version
        exit 1
    }

    Copy-Item -Force -Path $binaryFile.FullName -Destination $destFile

    Write-Log "OK" "Installed $ToolName $Version to $destFile"
    Write-JsonResult -Status "success" -Message "installed" -OutVersion $Version -Path $destFile
}

Install-Tool
