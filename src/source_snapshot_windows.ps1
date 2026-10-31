# Strict Windows source snapshots retain the original Git archive and manifest.
# Contained tracked file links become regular copies, authenticated against both
# their original link blobs and the exact tracked referent. No links are created.
# Functions only: the coordinator sends this same runtime to every source gate.

function Assert-DsrWindowsSourceRuntime {
    if ($PSVersionTable.PSVersion.Major -lt 7 -or
        ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 4)) {
        throw 'Strict Windows source snapshots require PowerShell 7.4 or newer with System.Formats.Tar'
    }
    try { $null=[Reflection.Assembly]::Load('System.Formats.Tar') }
    catch { throw 'Strict Windows source snapshots require PowerShell 7.4 or newer with System.Formats.Tar' }
    if ('DsrWindowsSourceIO' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class DsrWindowsSourceIO {
    [StructLayout(LayoutKind.Sequential)]
    struct AttributeTag { public uint Attributes; public uint ReparseTag; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true, ExactSpelling=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind,
        out AttributeTag info, uint size);
    [DllImport("kernel32.dll", SetLastError=true, ExactSpelling=true)]
    static extern uint GetFileType(SafeFileHandle handle);

    // Hold Windows directories without write/delete sharing so a checked
    // ancestor cannot become a junction or be replaced while children are used.
    // Portable tests use genuine local I/O but do not establish NTFS sharing.
    static SafeFileHandle OpenPlain(string path, bool directory) {
        string full=Path.GetFullPath(path).Replace('/', '\\');
        if (full.StartsWith(@"\\") || full.Length < 3 || full[1] != ':')
            throw new InvalidDataException("Source path must be drive-qualified: " + path);
        // Metadata-only handles do not participate in Windows sharing checks;
        // FILE_LIST_DIRECTORY makes the directory guard actually pin its node.
        SafeFileHandle handle=CreateFileW(@"\\?\" + full, directory ? 0x81u : 0x80000000u, 1, IntPtr.Zero, 3,
            0x02000000 | 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid) { int error=Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error, "Cannot hold source node: " + path); }
        try {
            AttributeTag info;
            if (!GetFileInformationByHandleEx(handle, 9, out info, 8))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot inspect source node: " + path);
            if (((info.Attributes & 0x10) != 0) != directory ||
                (info.Attributes & (0x400 | 0x40)) != 0 || GetFileType(handle) != 1)
                throw new InvalidDataException("Source node is linked, special or has the wrong type: " + path);
            return handle;
        } catch { handle.Dispose(); throw; }
    }

    public static IDisposable GuardDirectory(string path) {
        return OperatingSystem.IsWindows() ? OpenPlain(path, true) : null;
    }

    public static FileStream OpenRead(string path) {
        if (!OperatingSystem.IsWindows())
            return File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        SafeFileHandle handle=OpenPlain(path, false);
        try { return new FileStream(handle, FileAccess.Read); }
        catch { handle.Dispose(); throw; }
    }

    public static string GitBlob(Stream input, long length, Stream output) {
        if (length < 0) throw new InvalidDataException("Negative source blob length");
        using (IncrementalHash hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA1)) {
            byte[] header=Encoding.ASCII.GetBytes("blob " + length.ToString(CultureInfo.InvariantCulture) + "\0");
            hash.AppendData(header);
            byte[] buffer=new byte[65536]; long count=0; int read;
            while ((read=input.Read(buffer, 0, buffer.Length)) != 0) {
                count=checked(count + read);
                if (count > length) throw new InvalidDataException("Source blob exceeds its authenticated length");
                hash.AppendData(buffer, 0, read);
                if (output != null) output.Write(buffer, 0, read);
            }
            if (count != length) throw new InvalidDataException("Source blob is truncated");
            return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
        }
    }
}
'@ -ErrorAction Stop
}

function Assert-DsrWindowsSourceMember {
    param([string]$Path)
    # This is the coordinator's existing ASCII grammar plus Windows name
    # constraints. It rejects alternate streams, device names and aliases that
    # would collapse distinct tracked paths on an ordinary NTFS directory.
    if (-not $Path -or $Path.Length -gt 32760 -or
        $Path -cnotmatch '\A[A-Za-z0-9_./+@~#,=()\[\] -]+\z' -or
        $Path.StartsWith('/') -or $Path.Contains('..')) {
        throw ('Unsafe strict Windows source path: ' + $Path)
    }
    foreach ($part in $Path.Split('/')) {
        if (-not $part -or $part -ceq '.' -or $part.Length -gt 255 -or
            $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -ieq '.git' -or
            $part -imatch '\A(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|\z)') {
            throw ('Unsafe NTFS source component in: ' + $Path)
        }
    }
}

function Assert-DsrWindowsSourceNode {
    param([string]$Path, [ValidateSet('file','directory')][string]$Kind)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.FileSystemInfo] -or
        (($item.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Device)) -ne 0) -or
        (($Kind -ceq 'directory') -ne [bool]$item.PSIsContainer)) {
        throw ('Strict source node is not a plain ' + $Kind + ': ' + $Path)
    }
}

function Open-DsrWindowsSourceAncestors {
    param([string]$Directory)
    $paths=New-Object 'System.Collections.Generic.List[string]'
    $current=[IO.Path]::GetFullPath($Directory)
    while ($current) {
        $paths.Insert(0,$current)
        $parent=[IO.Directory]::GetParent($current)
        $current=if ($null -eq $parent) { '' } else { $parent.FullName }
    }
    $guards=New-Object 'System.Collections.Generic.List[IDisposable]'
    try {
        foreach ($path in $paths) {
            Assert-DsrWindowsSourceNode $path directory
            $guard=[DsrWindowsSourceIO]::GuardDirectory($path)
            if ($null -ne $guard) { $guards.Add($guard) }
            Assert-DsrWindowsSourceNode $path directory
        }
        return ,$guards.ToArray()
    } catch { foreach ($guard in $guards) { $guard.Dispose() }; throw }
}

function Open-DsrWindowsSourceFile {
    param([string]$Path)
    Assert-DsrWindowsSourceNode $Path file
    $stream=[DsrWindowsSourceIO]::OpenRead($Path)
    try { Assert-DsrWindowsSourceNode $Path file; return $stream }
    catch { $stream.Dispose(); throw }
}

function Get-DsrWindowsSourceStreamHash {
    param([IO.Stream]$Stream)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position=0
        return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant()
    } finally { $sha.Dispose(); $Stream.Position=0 }
}

function Get-DsrWindowsSourceLinkReferent {
    param([string]$Path, [string]$Target, $Rows, $Directories)
    if (-not $Target -or $Target.StartsWith('/') -or $Target.Length -gt 32760 -or
        $Target -cnotmatch '\A[A-Za-z0-9_./+@~#,=()\[\] -]+\z') {
        throw ('Unsafe tracked source link: ' + $Path + ' -> ' + $Target)
    }
    $parts=New-Object 'System.Collections.Generic.List[string]'
    $slash=$Path.LastIndexOf('/')
    if ($slash -ge 0) { foreach ($part in $Path.Substring(0,$slash).Split('/')) { $parts.Add($part) } }
    foreach ($part in $Target.Split('/')) {
        # Validate traversal before collapsing '..'. A regular file or another
        # link cannot act as the directory in "file/../target".
        $cursor=$parts -join '/'
        if ($cursor -and -not $Directories.Contains($cursor)) {
            throw ('Tracked source link traverses a non-directory: ' + $Path + ' -> ' + $Target)
        }
        if (-not $part -or $part -ceq '.') { continue }
        if ($part -ceq '..') {
            if ($parts.Count -eq 0) { throw ('Tracked source link escapes its snapshot: ' + $Path + ' -> ' + $Target) }
            $parts.RemoveAt($parts.Count-1); continue
        }
        Assert-DsrWindowsSourceMember $part
        $parts.Add($part)
    }
    $relative=$parts -join '/'
    if (-not $Rows.ContainsKey($relative) -or $Rows[$relative].Mode -cnotin @('100644','100755')) {
        throw ('Tracked source link must name an exact tracked regular file, without chains: ' + $Path + ' -> ' + $Target)
    }
    return $relative
}

function Get-DsrWindowsSourcePlan {
    param([Parameter(Mandatory=$true)][string]$ArchivePath,
        [Parameter(Mandatory=$true)][string]$ManifestPath,
        [Parameter(Mandatory=$true)][string]$ExpectedManifestSha256,
        [Parameter(Mandatory=$true)][long]$ExpectedObjectCount,
        [string]$ExpectedArchiveSha256='')
    Assert-DsrWindowsSourceRuntime
    if ($ExpectedManifestSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $ExpectedObjectCount -lt 1 -or
        $ExpectedObjectCount -gt 1000000 -or ($ExpectedArchiveSha256 -and $ExpectedArchiveSha256 -cnotmatch '\A[0-9a-f]{64}\z')) {
        throw 'Invalid controller-held strict source identity'
    }
    $archive=[IO.Path]::GetFullPath($ArchivePath); $manifest=[IO.Path]::GetFullPath($ManifestPath)
    $guards=New-Object 'System.Collections.Generic.List[IDisposable]'
    $inputArchive=$null; $inputManifest=$null; $manifestReader=$null; $tar=$null
    try {
        $guards.AddRange([IDisposable[]](Open-DsrWindowsSourceAncestors ([IO.Path]::GetDirectoryName($archive))))
        $guards.AddRange([IDisposable[]](Open-DsrWindowsSourceAncestors ([IO.Path]::GetDirectoryName($manifest))))
        $inputArchive=Open-DsrWindowsSourceFile $archive
        $inputManifest=Open-DsrWindowsSourceFile $manifest
        if ($inputManifest.Length -gt 67108864 -or $inputArchive.Length -lt 512) { throw 'Invalid or oversized strict source evidence' }
        $manifestHash=Get-DsrWindowsSourceStreamHash $inputManifest
        $archiveHash=Get-DsrWindowsSourceStreamHash $inputArchive
        if ($manifestHash -cne $ExpectedManifestSha256 -or ($ExpectedArchiveSha256 -and $archiveHash -cne $ExpectedArchiveSha256)) {
            throw 'Strict source archive or manifest differs from its controller-held digest'
        }
        $rows=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
        $directories=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        $spelling=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
        $manifestReader=[IO.StreamReader]::new($inputManifest,[Text.UTF8Encoding]::new($false,$true),$false,4096,$true)
        while ($null -ne ($line=$manifestReader.ReadLine())) {
            $fields=$line.Split([char]9)
            if ($fields.Count -ne 3 -or $fields[0] -cnotmatch '\A[0-9a-f]{40}\z' -or
                $fields[1] -cnotin @('100644','100755','120000','160000')) { throw 'Invalid tracked source manifest row' }
            $path=$fields[2]; Assert-DsrWindowsSourceMember $path
            if ($rows.ContainsKey($path)) { throw ('Repeated tracked source path: ' + $path) }
            $rows.Add($path,[pscustomobject]@{Path=$path; Mode=$fields[1]; Oid=$fields[0]; Length=[long]-1;
                LinkTarget=$null; ReferentPath=$null; ReferentOid=$null})
            $node=$path
            while ($node) {
                if ($spelling.ContainsKey($node) -and $spelling[$node] -cne $node) {
                    throw ('Case-colliding Windows source paths: ' + $spelling[$node] + ' / ' + $node)
                }
                $spelling[$node]=$node
                if ($node -cne $path -or $fields[1] -ceq '160000') { $null=$directories.Add($node) }
                $slash=$node.LastIndexOf('/'); $node=if ($slash -lt 0) { '' } else { $node.Substring(0,$slash) }
            }
            if ($rows.Count -gt 500000 -or $spelling.Count -gt $ExpectedObjectCount) { throw 'Strict source manifest exceeds its declared object bound' }
        }
        $manifestReader.Dispose(); $manifestReader=$null
        if ($rows.Count -eq 0 -or $spelling.Count -ne $ExpectedObjectCount) { throw 'Strict source manifest object count differs from the controller' }
        foreach ($row in $rows.Values) {
            if ($row.Mode -cne '160000' -and $directories.Contains($row.Path)) { throw ('Source file is also a directory: ' + $row.Path) }
            if ($row.Mode -ceq '160000') {
                foreach ($node in $spelling.Keys) {
                    if ($node.StartsWith($row.Path+'/',[StringComparison]::Ordinal)) { throw ('Tracked Git link is not empty: ' + $row.Path) }
                }
            }
        }
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $tar=[System.Formats.Tar.TarReader]::new($inputArchive,$true)
        $globalSeen=$false; $plainBytes=[long]0
        while ($null -ne ($entry=$tar.GetNextEntry($false))) {
            $kind=[string]$entry.EntryType
            if ($kind -ceq 'GlobalExtendedAttributes') {
                if ($globalSeen -or $seen.Count -gt 0 -or $entry.GlobalExtendedAttributes.Count -ne 1 -or
                    -not $entry.GlobalExtendedAttributes.ContainsKey('comment') -or
                    $entry.GlobalExtendedAttributes['comment'] -cnotmatch '\A[0-9a-f]{40}\z') {
                    throw 'Unsupported global metadata in strict Git source archive'
                }
                $globalSeen=$true; continue
            }
            $path=$entry.Name
            if ($kind -ceq 'Directory' -and $path.EndsWith('/')) { $path=$path.Substring(0,$path.Length-1) }
            Assert-DsrWindowsSourceMember $path
            if (-not $seen.Add($path)) { throw ('Duplicate source archive entry: ' + $path) }
            if ($kind -ceq 'Directory') {
                if (-not $directories.Contains($path) -or $entry.Length -ne 0) { throw ('Unexpected source archive directory: ' + $path) }
                continue
            }
            if (-not $rows.ContainsKey($path)) { throw ('Source archive entry is absent from the tracked manifest: ' + $path) }
            $row=$rows[$path]
            if ($kind -ceq 'SymbolicLink' -and $row.Mode -ceq '120000' -and $entry.Length -eq 0) {
                $row.LinkTarget=$entry.LinkName
                $row.ReferentPath=Get-DsrWindowsSourceLinkReferent $path $row.LinkTarget $rows $directories
                $row.ReferentOid=$rows[$row.ReferentPath].Oid
                $bytes=[Text.Encoding]::ASCII.GetBytes($row.LinkTarget)
                $linkStream=[IO.MemoryStream]::new($bytes,$false)
                try { $oid=[DsrWindowsSourceIO]::GitBlob($linkStream,$bytes.Length,$null) }
                finally { $linkStream.Dispose() }
                if ($oid -cne $row.Oid) { throw ('Tracked source link text differs from its Git blob: ' + $path) }
                continue
            }
            if ($kind -cnotin @('RegularFile','V7RegularFile') -or $row.Mode -cnotin @('100644','100755') -or
                $entry.Length -lt 0 -or $entry.Length -gt $inputArchive.Length -or
                (($row.Mode -ceq '100755') -ne (([int]$entry.Mode -band 73) -ne 0))) {
                throw ('Unsupported or mismatched strict source archive entry: ' + $path)
            }
            $data=if ($null -eq $entry.DataStream) { [IO.Stream]::Null } else { $entry.DataStream }
            if ([DsrWindowsSourceIO]::GitBlob($data,$entry.Length,$null) -cne $row.Oid) { throw ('Source archive bytes differ from the tracked Git blob: ' + $path) }
            $row.Length=[long]$entry.Length
            if ($plainBytes -gt [long]::MaxValue-$row.Length) { throw 'Strict source size overflow' }
            $plainBytes+=$row.Length
        }
        $tar.Dispose(); $tar=$null
        if ($seen.Count -ne $ExpectedObjectCount -or @($spelling.Keys | Where-Object { -not $seen.Contains($_) }).Count -ne 0) {
            throw 'Source archive inventory differs from the tracked manifest'
        }
        $materializedBytes=[long]0; $materializations=New-Object 'System.Collections.Generic.List[object]'
        foreach ($row in $rows.Values) {
            if ($row.Mode -cne '120000') { continue }
            $row.Length=$rows[$row.ReferentPath].Length
            if ($row.Length -lt 0 -or $materializedBytes -gt [long]::MaxValue-$row.Length) { throw ('Invalid materialized source size: ' + $row.Path) }
            $materializedBytes+=$row.Length
            $materializations.Add([pscustomobject]@{path=$row.Path; git_blob=$row.Oid; link_target=$row.LinkTarget;
                referent_path=$row.ReferentPath; referent_git_blob=$row.ReferentOid; size_bytes=$row.Length})
        }
        if ($plainBytes -gt [long]::MaxValue-$materializedBytes) { throw 'Strict source expansion size overflow' }
        if ((Get-DsrWindowsSourceStreamHash $inputArchive) -cne $archiveHash -or
            (Get-DsrWindowsSourceStreamHash $inputManifest) -cne $manifestHash) { throw 'Strict source evidence changed during planning' }
        return [pscustomobject]@{ArchivePath=$archive; ManifestPath=$manifest; ArchiveSha256=$archiveHash;
            ManifestSha256=$manifestHash; ObjectCount=$ExpectedObjectCount; ExpandedBytes=[long]($plainBytes+$materializedBytes);
            MaterializedBytes=$materializedBytes; SymlinkCount=$materializations.Count;
            Rows=$rows; Directories=$directories; Materializations=$materializations.ToArray()}
    } finally {
        if ($null -ne $tar) { $tar.Dispose() }; if ($null -ne $manifestReader) { $manifestReader.Dispose() }
        if ($null -ne $inputManifest) { $inputManifest.Dispose() }; if ($null -ne $inputArchive) { $inputArchive.Dispose() }
        foreach ($guard in $guards) { $guard.Dispose() }
    }
}

function Assert-DsrWindowsSourceEvidence {
    param($Plan)
    foreach ($record in @(@{Path=$Plan.ArchivePath; Hash=$Plan.ArchiveSha256},
            @{Path=$Plan.ManifestPath; Hash=$Plan.ManifestSha256})) {
        $guards=Open-DsrWindowsSourceAncestors ([IO.Path]::GetDirectoryName($record.Path)); $stream=$null
        try {
            $stream=Open-DsrWindowsSourceFile $record.Path
            if ((Get-DsrWindowsSourceStreamHash $stream) -cne $record.Hash) { throw ('Strict source evidence changed: ' + $record.Path) }
        } finally { if ($null -ne $stream) { $stream.Dispose() }; foreach ($guard in $guards) { $guard.Dispose() } }
    }
}

function Test-DsrWindowsSourceSnapshot {
    param([Parameter(Mandatory=$true)]$Plan, [Parameter(Mandatory=$true)][string]$DestinationPath)
    Assert-DsrWindowsSourceRuntime
    Assert-DsrWindowsSourceEvidence $Plan
    $root=[IO.Path]::GetFullPath($DestinationPath)
    $guards=New-Object 'System.Collections.Generic.List[IDisposable]'
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    try {
        $guards.AddRange([IDisposable[]](Open-DsrWindowsSourceAncestors $root))
        $pending=New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push('')
        while ($pending.Count -gt 0) {
            $relative=$pending.Pop(); $directory=if ($relative) { Join-Path $root $relative } else { $root }
            foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                $leaf=[IO.Path]::GetFileName($child); $path=if ($relative) { $relative+'/'+$leaf } else { $leaf }
                Assert-DsrWindowsSourceMember $path
                if (-not $seen.Add($path)) { throw ('Repeated source snapshot entry: ' + $path) }
                if ($seen.Count -gt $Plan.ObjectCount) { throw ('Unexpected source snapshot entry: ' + $path) }
                if ($Plan.Directories.Contains($path)) {
                    Assert-DsrWindowsSourceNode $child directory
                    $guard=[DsrWindowsSourceIO]::GuardDirectory($child); if ($null -ne $guard) { $guards.Add($guard) }
                    Assert-DsrWindowsSourceNode $child directory
                    $pending.Push($path); continue
                }
                if (-not $Plan.Rows.ContainsKey($path) -or $Plan.Rows[$path].Mode -ceq '160000') { throw ('Unexpected source snapshot file: ' + $path) }
                $row=$Plan.Rows[$path]; $stream=$null
                try {
                    $stream=Open-DsrWindowsSourceFile $child
                    $expected=if ($row.Mode -ceq '120000') { $row.ReferentOid } else { $row.Oid }
                    if ($stream.Length -ne $row.Length -or [DsrWindowsSourceIO]::GitBlob($stream,$row.Length,$null) -cne $expected) {
                        throw ('Source snapshot bytes differ from their tracked Git blob: ' + $path)
                    }
                    Assert-DsrWindowsSourceNode $child file
                } finally { if ($null -ne $stream) { $stream.Dispose() } }
            }
        }
        if ($seen.Count -ne $Plan.ObjectCount) { throw 'Source snapshot has missing filesystem nodes' }
        Assert-DsrWindowsSourceEvidence $Plan
    } finally { foreach ($guard in $guards) { $guard.Dispose() } }
}

function Expand-DsrWindowsSourceSnapshot {
    param([Parameter(Mandatory=$true)]$Plan, [Parameter(Mandatory=$true)][string]$DestinationPath)
    Assert-DsrWindowsSourceRuntime
    Assert-DsrWindowsSourceEvidence $Plan
    $root=[IO.Path]::GetFullPath($DestinationPath)
    $guards=New-Object 'System.Collections.Generic.List[IDisposable]'
    $inputArchive=$null; $tar=$null
    try {
        $guards.AddRange([IDisposable[]](Open-DsrWindowsSourceAncestors $root))
        if (@([IO.Directory]::EnumerateFileSystemEntries($root)).Count -ne 0) { throw 'Strict Windows source destination must be fresh and empty' }
        foreach ($path in $Plan.Directories) {
            $directory=Join-Path $root $path
            if ($directory.Length -gt 32760) { throw ('Windows source path exceeds the native path bound: ' + $path) }
            $null=[IO.Directory]::CreateDirectory($directory)
            $guard=[DsrWindowsSourceIO]::GuardDirectory($directory); if ($null -ne $guard) { $guards.Add($guard) }
            Assert-DsrWindowsSourceNode $directory directory
        }
        $guards.AddRange([IDisposable[]](Open-DsrWindowsSourceAncestors ([IO.Path]::GetDirectoryName($Plan.ArchivePath))))
        $inputArchive=Open-DsrWindowsSourceFile $Plan.ArchivePath
        if ((Get-DsrWindowsSourceStreamHash $inputArchive) -cne $Plan.ArchiveSha256) { throw 'Strict source archive changed before expansion' }
        $tar=[System.Formats.Tar.TarReader]::new($inputArchive,$true)
        while ($null -ne ($entry=$tar.GetNextEntry($false))) {
            if ([string]$entry.EntryType -cnotin @('RegularFile','V7RegularFile')) { continue }
            $path=$entry.Name
            if (-not $Plan.Rows.ContainsKey($path) -or $Plan.Rows[$path].Mode -cnotin @('100644','100755')) { throw ('Unplanned source archive file: ' + $path) }
            $row=$Plan.Rows[$path]; $destination=Join-Path $root $path
            if ($destination.Length -gt 32760) { throw ('Windows source path exceeds the native path bound: ' + $path) }
            $output=$null
            try {
                $output=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $data=if ($null -eq $entry.DataStream) { [IO.Stream]::Null } else { $entry.DataStream }
                if ([DsrWindowsSourceIO]::GitBlob($data,$row.Length,$output) -cne $row.Oid) { throw ('Source bytes changed during extraction: ' + $path) }
                $output.Flush($true)
            } finally { if ($null -ne $output) { $output.Dispose() } }
        }
        $tar.Dispose(); $tar=$null
        if ((Get-DsrWindowsSourceStreamHash $inputArchive) -cne $Plan.ArchiveSha256) { throw 'Strict source archive changed during expansion' }
        foreach ($row in $Plan.Rows.Values) {
            if ($row.Mode -cne '120000') { continue }
            $referent=Join-Path $root $row.ReferentPath; $destination=Join-Path $root $row.Path
            $referentStream=$null; $output=$null
            try {
                $referentStream=Open-DsrWindowsSourceFile $referent
                if ($referentStream.Length -ne $row.Length) { throw ('Materialized source referent changed: ' + $row.Path) }
                $output=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                if ([DsrWindowsSourceIO]::GitBlob($referentStream,$row.Length,$output) -cne $row.ReferentOid) { throw ('Materialized source referent differs from its Git blob: ' + $row.Path) }
                $output.Flush($true)
            } finally { if ($null -ne $output) { $output.Dispose() }; if ($null -ne $referentStream) { $referentStream.Dispose() } }
        }
        Test-DsrWindowsSourceSnapshot -Plan $Plan -DestinationPath $root
    } finally {
        if ($null -ne $tar) { $tar.Dispose() }; if ($null -ne $inputArchive) { $inputArchive.Dispose() }
        foreach ($guard in $guards) { $guard.Dispose() }
    }
}
