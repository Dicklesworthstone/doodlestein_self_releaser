# Native Windows private Cargo caches. This file defines functions only so the
# coordinator can send the same implementation to an SSH host without requiring
# another DSR installation. Receipts use the existing cargo_cache.sh schema.

function Initialize-DsrCargoCacheNative {
    if ('DsrCargoCacheNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class DsrCargoCacheHandle : IDisposable {
    internal SafeFileHandle handle;
    public string Path { get; private set; }
    public bool IsDirectory { get; private set; }
    internal DsrCargoCacheHandle(string path, bool directory) {
        Path = path; IsDirectory = directory;
        string native = path.Replace('/', '\\');
        if (!native.StartsWith(@"\\?\", StringComparison.Ordinal)) native = @"\\?\" + native;
        // Metadata-only FILE_READ_ATTRIBUTES handles do not participate in
        // sharing checks. Include FILE_LIST_DIRECTORY so withholding
        // FILE_SHARE_DELETE actually pins directories against replacement.
        // Files additionally deny writers throughout each read/copy.
        uint access = directory ? 0x81u : 0x80000000u;
        uint sharing = directory ? 3u : 1u;
        handle = DsrCargoCacheNative.CreateFileW(native, access, sharing, IntPtr.Zero,
            3, 0x00200000u | 0x02000000u, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open cache entry: " + path);
        try {
            DsrCargoCacheNative.FileInfo value = Info();
            if ((value.Attributes & (0x400u | 0x40u)) != 0 ||
                ((value.Attributes & 0x10u) != 0) != directory ||
                DsrCargoCacheNative.GetFileType(handle) != 1)
                throw new IOException("Linked, special, or unexpected cache entry: " + path);
        } catch { handle.Dispose(); throw; }
    }
    DsrCargoCacheNative.FileInfo Info() {
        DsrCargoCacheNative.FileInfo value;
        if (!DsrCargoCacheNative.GetFileInformationByHandle(handle, out value))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot inspect cache entry: " + Path);
        return value;
    }
    public string FileId { get {
        DsrCargoCacheNative.FileInfo value = Info();
        return value.Volume.ToString("x8") + ":" + value.IndexHigh.ToString("x8") + value.IndexLow.ToString("x8");
    } }
    public long LinkCount { get { return Info().Links; } }
    public long Length { get {
        DsrCargoCacheNative.FileInfo value = Info();
        return ((long)value.SizeHigh << 32) | value.SizeLow;
    } }
    public string GetIdentity() {
        DsrCargoCacheNative.FileInfo value = Info();
        DsrCargoCacheNative.BasicInfo basic;
        if (!DsrCargoCacheNative.GetFileInformationByHandleEx(handle, 0, out basic, 40))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot inspect cache change time: " + Path);
        return String.Join(":", new string[] {
            value.Volume.ToString("x8"), value.IndexHigh.ToString("x8"), value.IndexLow.ToString("x8"),
            value.Attributes.ToString("x8"), value.SizeHigh.ToString("x8"), value.SizeLow.ToString("x8"),
            value.CreationHigh.ToString("x8"), value.CreationLow.ToString("x8"),
            value.WriteHigh.ToString("x8"), value.WriteLow.ToString("x8"), value.Links.ToString("x8"),
            basic.ChangeTime.ToString("x16") });
    }
    public FileStream OpenRead() {
        if (IsDirectory) throw new IOException("Cannot read a cache directory as a file");
        // FileStream disposes the SafeFileHandle it receives. Give it a real
        // duplicate so closing the stream cannot release the entry's native
        // write/delete exclusion before the enclosing custody check finishes.
        SafeFileHandle duplicate;
        IntPtr process = DsrCargoCacheNative.GetCurrentProcess();
        if (!DsrCargoCacheNative.DuplicateHandle(process, handle, process, out duplicate, 0, false, 2))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot duplicate cache read handle: " + Path);
        try {
            return new FileStream(duplicate, FileAccess.Read, 1048576, false);
        } catch { duplicate.Dispose(); throw; }
    }
    public void Dispose() { handle.Dispose(); }
}

public static class DsrCargoCacheNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct FileInfo {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh,
            WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct BasicInfo {
        public long CreationTime, AccessTime, WriteTime, ChangeTime;
        public uint Attributes;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    internal static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out BasicInfo info, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    internal static extern uint GetFileType(SafeFileHandle handle);
    [DllImport("kernel32.dll")]
    internal static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DuplicateHandle(IntPtr sourceProcess, SafeFileHandle source,
        IntPtr targetProcess, out SafeFileHandle target, uint access,
        [MarshalAs(UnmanagedType.Bool)] bool inherit, uint options);
    public static DsrCargoCacheHandle Open(string path, bool directory) {
        if (Environment.OSVersion.Platform != PlatformID.Win32NT)
            throw new PlatformNotSupportedException("Native Windows cache handles require Windows");
        return new DsrCargoCacheHandle(path, directory);
    }
    public static string Quote(string value) {
        StringBuilder result = new StringBuilder("\"");
        foreach (char c in value) {
            if (c == '\"') result.Append("\\\"");
            else if (c == '\\') result.Append("\\\\");
            else if (c == '\b') result.Append("\\b");
            else if (c == '\f') result.Append("\\f");
            else if (c == '\n') result.Append("\\n");
            else if (c == '\r') result.Append("\\r");
            else if (c == '\t') result.Append("\\t");
            else if (c < 32 || c > 126) result.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
            else result.Append(c);
        }
        return result.Append('"').ToString();
    }
}
'@
}

function Open-DsrCacheEntry {
    param([Parameter(Mandatory=$true)][string]$Path, [bool]$Directory=$false)
    Initialize-DsrCargoCacheNative
    return [DsrCargoCacheNative]::Open($Path, $Directory)
}

function Get-DsrCacheFullPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $pathValue = $Path.Replace('\', '/')
    if ($pathValue -notmatch '^[A-Za-z]:/' -or $pathValue -match '[\x00-\x1f<>"|?*]' -or
        $pathValue.Substring(2).Contains(':')) { throw 'Cargo paths must be ordinary absolute Windows paths' }
    $pathValue = $pathValue.TrimEnd('/')
    if ($pathValue.Length -eq 2) { return $pathValue.Substring(0,1).ToUpperInvariant() + ':/' }
    foreach ($part in $pathValue.Substring(3).Split('/')) {
        if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part.EndsWith('.') -or
            $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw 'Ambiguous Windows cache path component'
        }
    }
    return $pathValue.Substring(0,1).ToUpperInvariant() + $pathValue.Substring(1)
}

function Get-DsrCacheChildren {
    param([string]$Path)
    $children = [IO.Directory]::GetFileSystemEntries($Path)
    [Array]::Sort($children, [StringComparer]::Ordinal)
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($child in $children) {
        $name = [IO.Path]::GetFileName($child)
        if (-not $names.Add($name)) { throw 'Case-colliding Windows cache entries' }
        $null = Get-DsrCacheFullPath ($Path.TrimEnd('/') + '/' + $name)
    }
    return ,$children
}

function Open-DsrCachePathGuard {
    param([string]$Path)
    $handles = New-Object 'System.Collections.Generic.List[object]'
    try {
        $current = $Path.Substring(0,3)
        $handles.Add((Open-DsrCacheEntry $current -Directory $true))
        if ($Path.Length -gt 3) {
            foreach ($part in $Path.Substring(3).Split('/')) {
                $current = $current.TrimEnd('/') + '/' + $part
                $handles.Add((Open-DsrCacheEntry $current -Directory $true))
            }
        }
        return ,$handles
    } catch {
        foreach ($handle in $handles) { $handle.Dispose() }
        throw
    }
}

function ConvertTo-DsrCacheCanonicalJson {
    param([AllowNull()]$Value)
    Initialize-DsrCargoCacheNative
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return [DsrCargoCacheNative]::Quote($Value) }
    if ($Value -is [bool]) { if ($Value) { return 'true' }; return 'false' }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or
        $Value -is [int64] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]) {
        return $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]) {
        if ($Value -is [Collections.IDictionary]) { $keys = [string[]]@($Value.Keys) }
        else { $keys = [string[]]@($Value.PSObject.Properties.Name) }
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $members = foreach ($key in $keys) {
            # Assignment outside the branch preserves empty arrays; pipeline
            # output from an if-expression would collapse them into null.
            if ($Value -is [Collections.IDictionary]) { $item = $Value[$key] } else { $item = $Value.$key }
            [DsrCargoCacheNative]::Quote($key) + ':' + (ConvertTo-DsrCacheCanonicalJson $item)
        }
        return '{' + ($members -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = foreach ($item in $Value) { ConvertTo-DsrCacheCanonicalJson $item }
        return '[' + ($items -join ',') + ']'
    }
    throw 'Unsupported value in Cargo cache receipt'
}

function Get-DsrCacheBytesHash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-DsrCacheInside {
    param([string]$Path, [string]$Root)
    return [StringComparer]::OrdinalIgnoreCase.Equals($Path, $Root) -or
        $Path.StartsWith($Root.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DsrCargoHome {
    param([Parameter(Mandatory=$true)][string]$Path)
    $homePath = Get-DsrCacheFullPath $Path
    $guards = Open-DsrCachePathGuard $homePath
    try {
        foreach ($entry in (Get-DsrCacheChildren $homePath)) {
            if ([IO.Path]::GetFileName($entry) -in @('config','config.toml','credentials','credentials.toml')) {
                throw 'Private CARGO_HOME contains configuration or credentials'
            }
        }
    } finally { foreach ($guard in $guards) { $guard.Dispose() } }
}

# A source may have hardlinks; each copied destination is independently opened
# with CreateNew. An admitted private cache must account for every hardlink in
# its registry/git trees, because an outside owner can mutate shared bytes.
function Get-DsrCargoCacheInventory {
    param([string]$CargoHome, [string]$CopyTo='', [bool]$RequirePrivate=$true)
    $guards = Open-DsrCachePathGuard $CargoHome
    $files = New-Object 'System.Collections.Generic.List[object]'
    $directories = New-Object 'System.Collections.Generic.List[string]'
    $caches = New-Object 'System.Collections.Generic.List[string]'
    $observed = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $links = @{}
    function Visit-DsrCargoCache {
        param([string]$Relative, [bool]$Recheck=$false)
        $pathValue = $CargoHome.TrimEnd('/') + '/' + $Relative
        $attributes = [IO.File]::GetAttributes($pathValue)
        $directory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
        $entry = Open-DsrCacheEntry $pathValue -Directory $directory
        try {
            $identity = $entry.GetIdentity()
            if ($Recheck) {
                if (-not $observed.ContainsKey($Relative) -or $observed[$Relative] -cne $identity) {
                    throw ('Private cache entry changed after reading: ' + $Relative)
                }
            } else { $observed.Add($Relative, $identity) }
            if ($directory) {
                $children = Get-DsrCacheChildren $pathValue
                if (-not $Recheck) {
                    $directories.Add($Relative)
                    if ($CopyTo) { $null = [IO.Directory]::CreateDirectory($CopyTo.TrimEnd('/') + '/' + $Relative) }
                }
                foreach ($child in $children) {
                    Visit-DsrCargoCache ($Relative + '/' + [IO.Path]::GetFileName($child)) $Recheck
                }
                $after = Get-DsrCacheChildren $pathValue
                if (($children -join [char]0) -cne ($after -join [char]0)) { throw 'Cache directory changed during inventory' }
            } elseif (-not $Recheck) {
                $parts = $Relative.Split('/')
                if ($parts[0] -eq 'git' -and ($parts[-1] -eq '.git' -or
                    ($entry.Length -gt 0 -and ($Relative.EndsWith('/objects/info/alternates', [StringComparison]::OrdinalIgnoreCase) -or
                    ($parts[-1] -eq 'commondir' -and ('.git' -in $parts -or ($parts.Length -eq 4 -and $parts[1] -eq 'db'))))))) {
                    throw ('External Git storage reference: ' + $Relative)
                }
                if ($RequirePrivate) {
                    $id = $entry.FileId
                    if ($links.ContainsKey($id)) {
                        if ($links[$id].expected -ne $entry.LinkCount) { throw 'Cache hardlinks changed during inventory' }
                        $links[$id].count++
                    } else { $links[$id] = @{expected=$entry.LinkCount; count=1; path=$Relative} }
                }
                $inputStream = $null; $outputStream = $null; $sha = [Security.Cryptography.SHA256]::Create()
                try {
                    $inputStream = $entry.OpenRead()
                    if ($CopyTo) {
                        $outputStream = [IO.FileStream]::new(($CopyTo.TrimEnd('/') + '/' + $Relative),
                            [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    }
                    $buffer = New-Object byte[] 1048576
                    $size = [long]0
                    while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $null = $sha.TransformBlock($buffer, 0, $count, $buffer, 0)
                        if ($null -ne $outputStream) { $outputStream.Write($buffer, 0, $count) }
                        $size += $count
                    }
                    $null = $sha.TransformFinalBlock($buffer, 0, 0)
                    if ($null -ne $outputStream) { $outputStream.Flush() }
                    if ($size -ne $entry.Length -or $entry.GetIdentity() -cne $identity) { throw 'Cache file changed while reading' }
                    # Windows has no POSIX execute bits; retain the same field
                    # with zero rather than invent a permission attestation.
                    $files.Add(@{path=$Relative; sha256=([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant();
                        size_bytes=$size; executable_bits=0})
                } finally {
                    if ($null -ne $outputStream) { $outputStream.Dispose() }
                    $sha.Dispose()
                    # The entry retains the native handle when its stream is
                    # disposed. The enclosing finally releases that custody.
                    if ($null -ne $inputStream) { $inputStream.Dispose() }
                }
                $check = Open-DsrCacheEntry $pathValue
                try { if ($check.GetIdentity() -cne $identity) { throw 'Cache file replaced after reading' } }
                finally { $check.Dispose() }
                return
            }
            if ($entry.GetIdentity() -cne $identity) { throw 'Cache entry changed during inventory' }
        } finally { $entry.Dispose() }
    }
    try {
        $rootNames = @{}
        foreach ($child in (Get-DsrCacheChildren $CargoHome)) { $rootNames[[IO.Path]::GetFileName($child)] = $true }
        foreach ($name in @('git','registry')) {
            if ($rootNames.ContainsKey($name)) {
                $root = Open-DsrCacheEntry ($CargoHome.TrimEnd('/') + '/' + $name) -Directory $true
                $root.Dispose()
                $caches.Add($name)
                Visit-DsrCargoCache $name
            }
        }
        $afterNames = @{}
        foreach ($child in (Get-DsrCacheChildren $CargoHome)) { $afterNames[[IO.Path]::GetFileName($child)] = $true }
        foreach ($name in @('git','registry')) {
            if ($rootNames.ContainsKey($name) -ne $afterNames.ContainsKey($name)) { throw 'Cargo cache root changed during inventory' }
        }
        if ($RequirePrivate) {
            foreach ($name in $caches) { Visit-DsrCargoCache $name $true }
            foreach ($item in $links.Values) {
                if ($item.expected -ne $item.count) { throw ('Cache file has hardlinks outside its private trees: ' + $item.path) }
            }
        }
        $sortedDirectories = $directories.ToArray()
        [Array]::Sort($sortedDirectories, [StringComparer]::Ordinal)
        $sortedFiles = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)
        foreach ($file in $files) { $sortedFiles.Add($file.path, $file) }
        return @{caches=@($caches.ToArray()); directories=@($sortedDirectories); files=@($sortedFiles.Values)}
    } finally { foreach ($guard in $guards) { $guard.Dispose() } }
}

function Read-DsrCargoReceipt {
    param([string]$Path)
    $parent = $Path.Substring(0, $Path.LastIndexOf('/'))
    if ($parent.Length -eq 2) { $parent += '/' }
    $guards = Open-DsrCachePathGuard $parent
    $entry = $null; $stream = $null; $memory = $null
    try {
        $entry = Open-DsrCacheEntry $Path
        if ($entry.LinkCount -ne 1) { throw 'Cargo receipt has shared hardlink ownership' }
        $before = $entry.GetIdentity()
        $stream = $entry.OpenRead(); $memory = New-Object IO.MemoryStream
        $stream.CopyTo($memory)
        if ($entry.GetIdentity() -cne $before) { throw 'Cargo receipt changed while reading' }
        $bytes = $memory.ToArray()
        $text = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $value = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        if (((ConvertTo-DsrCacheCanonicalJson $value) + "`n") -cne $text) { throw 'Cargo receipt is not canonical or has duplicate fields' }
        return @{value=$value; sha256=(Get-DsrCacheBytesHash $bytes)}
    } finally {
        if ($null -ne $memory) { $memory.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $entry) { $entry.Dispose() }
        foreach ($guard in $guards) { $guard.Dispose() }
    }
}

function New-DsrCargoReceipt {
    param([string]$Path, $Value)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-DsrCacheCanonicalJson $Value) + "`n")
    $parent = $Path.Substring(0, $Path.LastIndexOf('/'))
    if ($parent.Length -eq 2) { $parent += '/' }
    $guards = Open-DsrCachePathGuard $parent
    try {
        $temporary = $parent.TrimEnd('/') + '/.dsr-cargo-receipt.' + [Guid]::NewGuid().ToString('N')
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        # Same-volume rename is atomic and refuses an existing destination.
        # On failure retain the unadmitted temporary evidence for inspection.
        [IO.File]::Move($temporary, $Path)
        return Get-DsrCacheBytesHash $bytes
    } finally { foreach ($guard in $guards) { $guard.Dispose() } }
}

function Get-DsrCargoCacheSummary {
    param([string]$Path, $Receipt, [string]$Digest)
    $size = [long]0
    foreach ($entry in $Receipt.inventory.files) { $size += [long]$entry.size_bytes }
    $inventoryBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-DsrCacheCanonicalJson $Receipt.inventory) + "`n")
    return @{schema_version=1; mode=$Receipt.kind; cargo_home=$Receipt.cargo_home;
        receipt_path=$Path; receipt_sha256=$Digest; inventory_sha256=(Get-DsrCacheBytesHash $inventoryBytes);
        caches=@($Receipt.inventory.caches); file_count=@($Receipt.inventory.files).Count; size_bytes=$size}
}

function Assert-DsrCargoSeed {
    param([Parameter(Mandatory=$true)][string]$CargoHome, [Parameter(Mandatory=$true)][string]$ExpectedSha256)
    if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid admitted Cargo seed digest' }
    $homePath = Get-DsrCacheFullPath $CargoHome
    Assert-DsrCargoHome $homePath
    $read = Read-DsrCargoReceipt ($homePath.TrimEnd('/') + '/.dsr-cache-seed.json')
    if ($read.sha256 -cne $ExpectedSha256 -or $read.value.kind -cne 'private-copy' -or
        $read.value.cargo_home -cne $homePath) { throw 'Private Cargo cache seed receipt changed' }
}

function Invoke-DsrCargoCache {
    param([Parameter(Mandatory=$true)][ValidateSet('snapshot','inventory','verify')][string]$Operation,
        [AllowEmptyString()][string]$First, [Parameter(Mandatory=$true)][string]$Second)
    $secondPath = Get-DsrCacheFullPath $Second
    if ($Operation -eq 'snapshot') {
        $source = if ($First) { Get-DsrCacheFullPath $First } else { $null }
        if ($source -and ((Test-DsrCacheInside $source $secondPath) -or (Test-DsrCacheInside $secondPath $source))) {
            throw 'Source and private Cargo homes must not overlap'
        }
        if ($secondPath.Length -le 3) { throw 'Private cache destination must be a new child directory' }
        $parent = $secondPath.Substring(0,$secondPath.LastIndexOf('/'))
        if ($parent.Length -eq 2) { $parent += '/' }
        $guards = Open-DsrCachePathGuard $parent
        $sourceGuards = $null
        try {
            if ($source) {
                $sourceGuards = Open-DsrCachePathGuard $source
                $sourceId = $sourceGuards[$sourceGuards.Count - 1].FileId
                foreach ($guard in $guards) {
                    if ($guard.FileId -ceq $sourceId) { throw 'Source and private Cargo homes overlap through a filesystem alias' }
                }
            }
            foreach ($existing in (Get-DsrCacheChildren $parent)) {
                if ([StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFileName($existing), [IO.Path]::GetFileName($secondPath))) {
                    throw 'Private Cargo cache destination already exists'
                }
            }
            # CreateDirectory accepts existing directories. New-Item without
            # -Force instead refuses a colliding home below the pinned parent.
            $null = New-Item -ItemType Directory -Path $secondPath -ErrorAction Stop
            $inventory = if ($source) { Get-DsrCargoCacheInventory $source $secondPath $false }
                else { @{caches=@();directories=@();files=@()} }
            $selected = ConvertTo-DsrCacheCanonicalJson $inventory
            if ((ConvertTo-DsrCacheCanonicalJson (Get-DsrCargoCacheInventory $secondPath)) -cne $selected) {
                throw 'Private cache copy does not match its seed'
            }
            if ($source -and (ConvertTo-DsrCacheCanonicalJson (Get-DsrCargoCacheInventory $source -RequirePrivate $false)) -cne $selected) {
                throw 'Source cache changed during snapshot'
            }
            Assert-DsrCargoHome $secondPath
            $receipt = @{schema_version=1;kind='private-copy';cargo_home=$secondPath;seed_source=$source;inventory=$inventory}
            $receiptPath = $secondPath + '/.dsr-cache-seed.json'
            $digest = New-DsrCargoReceipt $receiptPath $receipt
            return Get-DsrCargoCacheSummary $receiptPath $receipt $digest
        } finally {
            if ($null -ne $sourceGuards) { foreach ($guard in $sourceGuards) { $guard.Dispose() } }
            foreach ($guard in $guards) { $guard.Dispose() }
        }
    }
    $homePath = Get-DsrCacheFullPath $First
    Assert-DsrCargoHome $homePath
    if ($Operation -eq 'inventory') {
        foreach ($name in @('registry','git')) {
            if (Test-DsrCacheInside $secondPath ($homePath.TrimEnd('/') + '/' + $name)) { throw 'Receipt must live outside cache trees' }
        }
        $receipt = @{schema_version=1;kind='inventory';cargo_home=$homePath;seed_source=$null;
            inventory=(Get-DsrCargoCacheInventory $homePath)}
        Assert-DsrCargoHome $homePath
        $digest = New-DsrCargoReceipt $secondPath $receipt
        return Get-DsrCargoCacheSummary $secondPath $receipt $digest
    }
    $read = Read-DsrCargoReceipt $secondPath
    $receipt = $read.value
    $keys = [string[]]@($receipt.PSObject.Properties.Name); [Array]::Sort($keys,[StringComparer]::Ordinal)
    if (($keys -join ',') -cne 'cargo_home,inventory,kind,schema_version,seed_source' -or
        ($receipt.schema_version -isnot [long] -and $receipt.schema_version -isnot [int]) -or
        $receipt.schema_version -ne 1 -or $receipt.kind -cnotin @('private-copy','inventory') -or
        $receipt.cargo_home -cne $homePath -or
        (ConvertTo-DsrCacheCanonicalJson $receipt.inventory) -cne
        (ConvertTo-DsrCacheCanonicalJson (Get-DsrCargoCacheInventory $homePath))) {
        throw 'Private Cargo cache does not match its inventory'
    }
    return Get-DsrCargoCacheSummary $secondPath $receipt $read.sha256
}
