# Native Windows private Cargo caches. This file defines functions only so the
# coordinator can send the same implementation to an SSH host without requiring
# another DSR installation. Receipts use the existing cargo_cache.sh schema.

function Initialize-DsrCargoCacheNative {
    if ('DsrCargoCacheNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

// Shared bounded Cargo.lock reader for download selection and source proofs.
// Every token is consumed; this is not a general TOML configuration parser.
public sealed class DsrCargoSourceLock {
    readonly string input;
    int position;
    DsrCargoSourceLock(byte[] bytes) { input = new UTF8Encoding(false, true).GetString(bytes); }
    void Require(bool value, string message) { if (!value) throw new InvalidDataException(message); }
    void Space(bool lines) {
        while (position < input.Length) {
            char c = input[position];
            if (c == ' ' || c == '\t' || (lines && (c == '\r' || c == '\n'))) { position++; continue; }
            if (lines && c == '#') { while (position < input.Length && input[position] != '\n') position++; continue; }
            break;
        }
    }
    void EndLine() {
        Space(false);
        if (position < input.Length && input[position] == '#') {
            while (position < input.Length && input[position] != '\r' && input[position] != '\n') position++;
        }
        if (position < input.Length && input[position] == '\r') position++;
        Require(position == input.Length || input[position] == '\n', "Unsupported Cargo.lock syntax after a value");
        if (position < input.Length) position++;
    }
    string String() {
        Require(position < input.Length && input[position++] == '"', "Cargo.lock requires single-line basic strings");
        StringBuilder text = new StringBuilder();
        while (position < input.Length) {
            char c = input[position++];
            if (c == '"') return text.ToString();
            Require(c >= 32 && c != 127, "Control character in Cargo.lock string");
            if (c != '\\') { text.Append(c); continue; }
            Require(position < input.Length, "Unclosed Cargo.lock string escape");
            c = input[position++];
            switch (c) {
                case '"': text.Append('"'); break;
                case '\\': text.Append('\\'); break;
                case 'b': text.Append('\b'); break;
                case 't': text.Append('\t'); break;
                case 'n': text.Append('\n'); break;
                case 'f': text.Append('\f'); break;
                case 'r': text.Append('\r'); break;
                case 'u': case 'U':
                    int length = c == 'u' ? 4 : 8;
                    Require(position + length <= input.Length, "Truncated Cargo.lock unicode escape");
                    string hex = input.Substring(position, length);
                    Require(Regex.IsMatch(hex, "^[0-9a-fA-F]+$"), "Invalid Cargo.lock unicode escape");
                    uint point = Convert.ToUInt32(hex, 16);
                    Require(point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff), "Invalid Cargo.lock unicode scalar");
                    text.Append(char.ConvertFromUtf32((int)point)); position += length; break;
                default: throw new InvalidDataException("Unsupported Cargo.lock string escape");
            }
        }
        throw new InvalidDataException("Unclosed Cargo.lock string");
    }
    string[] Array() {
        Require(position < input.Length && input[position++] == '[', "Cargo.lock dependencies must be string arrays");
        List<string> values = new List<string>();
        Space(true);
        while (position < input.Length && input[position] != ']') {
            Require(values.Count < 500000, "Oversized Cargo.lock dependencies");
            values.Add(String()); Space(true);
            if (position < input.Length && input[position] == ']') break;
            Require(position < input.Length && input[position++] == ',', "Missing Cargo.lock array separator");
            Space(true);
        }
        Require(position < input.Length && input[position++] == ']', "Unclosed Cargo.lock dependencies");
        return values.ToArray();
    }
    List<Dictionary<string, object>> Parse() {
        List<Dictionary<string, object>> packages = new List<Dictionary<string, object>>();
        List<Dictionary<string, object>> allPackages = new List<Dictionary<string, object>>();
        Dictionary<string, object> package = null;
        bool version = false;
        while (true) {
            Space(true); if (position == input.Length) break;
            if (input[position] == '[') {
                const string activeHeader = "[[package]]", unusedHeader = "[[patch.unused]]";
                bool active = position + activeHeader.Length <= input.Length && string.CompareOrdinal(input, position, activeHeader, 0, activeHeader.Length) == 0;
                string header = active ? activeHeader : unusedHeader;
                Require(position + header.Length <= input.Length && string.CompareOrdinal(input, position, header, 0, header.Length) == 0,
                    "Unsupported Cargo.lock table");
                position += header.Length; EndLine();
                Require(version && allPackages.Count < 500000, "Cargo.lock version must precede its packages");
                package = new Dictionary<string, object>(StringComparer.Ordinal); allPackages.Add(package);
                // Unused patches use the same grammar but are not authority.
                if (active) packages.Add(package);
                continue;
            }
            int start = position;
            while (position < input.Length && ((input[position] >= 'a' && input[position] <= 'z') || input[position] == '_')) position++;
            string key = input.Substring(start, position - start);
            Require(key.Length > 0, "Unsupported Cargo.lock key"); Space(false);
            Require(position < input.Length && input[position++] == '=', "Missing Cargo.lock assignment"); Space(false);
            if (package == null) {
                Require(key == "version" && !version, "Duplicate or unsupported Cargo.lock root key");
                Require(position < input.Length && (input[position] == '3' || input[position] == '4'), "Cargo.lock v3 or v4 required");
                position++; version = true;
            } else {
                Require(!package.ContainsKey(key), "Duplicate Cargo.lock package key");
                Require(key == "name" || key == "version" || key == "source" || key == "checksum" || key == "dependencies" || key == "replace",
                    "Unsupported Cargo.lock package key");
                package.Add(key, key == "dependencies" ? (object)Array() : String());
            }
            EndLine();
        }
        Require(version && packages.Count > 0, "Cargo.lock has no packages");
        foreach (var item in allPackages) {
            Require(item.ContainsKey("name") && item.ContainsKey("version") && ((string)item["name"]).Length > 0 && ((string)item["version"]).Length > 0,
                "Cargo.lock has an incomplete package identity");
        }
        return packages;
    }
    public static List<Dictionary<string, object>> Read(byte[] bytes) { return new DsrCargoSourceLock(bytes).Parse(); }
}

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
    static async Task<string> ReadProbe(TextReader reader) {
        StringBuilder text = new StringBuilder(); char[] buffer = new char[4096]; int count;
        while ((count = await reader.ReadAsync(buffer, 0, buffer.Length)) > 0) {
            if (text.Length + count > 4194304) throw new IOException("Oversized local Git selection result");
            text.Append(buffer, 0, count);
        }
        return text.ToString();
    }
    static async Task WriteProbe(StreamWriter writer, string incoming) {
        try { if (incoming != null) await writer.WriteAsync(incoming); }
        finally { writer.Close(); }
    }
    public static string GitProbe(string executable, string admin, string[] arguments, string incoming) {
        ProcessStartInfo info = new ProcessStartInfo(executable);
        info.UseShellExecute = false;
        info.ArgumentList.Add("--git-dir=" + admin);
        info.ArgumentList.Add("-c"); info.ArgumentList.Add("core.fsmonitor=false");
        info.ArgumentList.Add("-c"); info.ArgumentList.Add("core.hooksPath=" + (OperatingSystem.IsWindows() ? "NUL" : "/dev/null"));
        foreach (string argument in arguments) info.ArgumentList.Add(argument);
        List<string> names = new List<string>();
        foreach (string name in info.Environment.Keys) if (name.StartsWith("GIT_", StringComparison.OrdinalIgnoreCase)) names.Add(name);
        foreach (string name in names) info.Environment.Remove(name);
        info.Environment["GIT_CONFIG_NOSYSTEM"] = "1";
        info.Environment["GIT_CONFIG_GLOBAL"] = OperatingSystem.IsWindows() ? "NUL" : "/dev/null";
        info.Environment["GIT_NO_REPLACE_OBJECTS"] = "1";
        info.Environment["GIT_NO_LAZY_FETCH"] = "1";
        // This allowlist also overrides repository-local protocol policies.
        info.Environment["GIT_ALLOW_PROTOCOL"] = "";
        info.Environment["GIT_TERMINAL_PROMPT"] = "0";
        info.Environment["GIT_OPTIONAL_LOCKS"] = "0";
        info.Environment["LC_ALL"] = "C";
        info.RedirectStandardInput = true; info.RedirectStandardOutput = true; info.RedirectStandardError = true;
        using (Process process = Process.Start(info)) {
            if (process == null) throw new IOException("Cannot start local Git download selection");
            try {
                Task<string> output = ReadProbe(process.StandardOutput), error = ReadProbe(process.StandardError);
                Task input = WriteProbe(process.StandardInput, incoming);
                try {
                    if (!Task.WhenAll(output, error, input).Wait(30000)) return "";
                } catch (AggregateException) { return ""; }
                if (!process.WaitForExit(1000) || process.ExitCode != 0) return "";
                return output.Result;
            } finally {
                if (!process.HasExited) { process.Kill(true); process.WaitForExit(5000); }
            }
        }
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

# Selection reads use the same native handles as copying. The caller keeps a
# lockfile handle open until publication; its bytes are never read by pathname.
function Get-DsrCacheHeldBytes {
    param($Entry, [long]$Maximum=16777216)
    if ($Entry.Length -gt $Maximum) { throw 'Oversized Cargo cache selection input' }
    $before = $Entry.GetIdentity(); $stream = $null; $memory = [IO.MemoryStream]::new()
    try {
        $stream = $Entry.OpenRead()
        # DuplicateHandle shares the underlying Win32 file position with the
        # held entry. Each bounded reread must start at byte zero explicitly.
        $stream.Position = 0
        $buffer = New-Object byte[] 65536
        while (($count = $stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            if ($memory.Length + $count -gt $Maximum) { throw 'Oversized Cargo cache selection input' }
            $memory.Write($buffer,0,$count)
        }
        if ($Entry.GetIdentity() -cne $before -or $memory.Length -ne $Entry.Length) { throw 'Cargo cache selection input changed while reading' }
        return ,$memory.ToArray()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $memory.Dispose()
    }
}

# Missing candidates are unavailable seeds. Existing ancestors are still
# opened without following links, including when a deeper component is absent.
function Open-DsrCargoCacheCandidate {
    param([string]$CargoHome, [string]$Relative, [bool]$Directory=$false)
    $guards = Open-DsrCachePathGuard $CargoHome; $complete = $false
    try {
        $parts = $Relative.Split('/'); $pathValue = $CargoHome.TrimEnd('/')
        for ($index = 0; $index -lt $parts.Length; $index++) {
            $pathValue = Get-DsrCacheFullPath ($pathValue + '/' + $parts[$index])
            try { $null = [IO.File]::GetAttributes($pathValue) }
            catch [IO.FileNotFoundException] { return $null }
            catch [IO.DirectoryNotFoundException] { return $null }
            $isDirectory = $index -lt $parts.Length - 1 -or $Directory
            $guards.Add((Open-DsrCacheEntry $pathValue -Directory $isDirectory))
        }
        $complete = $true
        return ,$guards
    } finally { if (-not $complete) { foreach ($guard in $guards) { $guard.Dispose() } } }
}

function Get-DsrCargoCacheRoutes {
    param([string]$CargoHome, [string]$Relative)
    $guards = Open-DsrCargoCacheCandidate $CargoHome $Relative -Directory $true
    if ($null -eq $guards) { return ,([string[]]@()) }
    try {
        $pathValue = $CargoHome.TrimEnd('/') + '/' + $Relative
        $names = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        $folded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        # Inspect only namespace routes, never registry/src or git/checkouts.
        # Invalid unrelated names and non-directory routing entries are ignored.
        foreach ($child in [IO.Directory]::GetFileSystemEntries($pathValue)) {
            $name = [IO.Path]::GetFileName($child)
            if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$' -or $name.EndsWith('.') -or
                $name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { continue }
            try { $attributes = [IO.File]::GetAttributes($child) }
            catch [IO.FileNotFoundException] { continue }
            catch [IO.DirectoryNotFoundException] { continue }
            if (($attributes -band [IO.FileAttributes]::Directory) -eq 0) { continue }
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('Linked Cargo download namespace: ' + $Relative + '/' + $name)
            }
            if (-not $folded.Add($name)) { throw 'Case-colliding Windows cache download routes' }
            $null = $names.Add($name)
        }
        return ,([string[]]@($names))
    } finally { foreach ($guard in $guards) { $guard.Dispose() } }
}

function Get-DsrCargoCacheCandidateHash {
    param([string]$CargoHome, [string]$Relative, [switch]$PresenceOnly)
    $guards = Open-DsrCargoCacheCandidate $CargoHome $Relative
    if ($null -eq $guards) { return $null }
    $stream = $null; $sha = $null
    try {
        if ($PresenceOnly) { return $true }
        $entry = $guards[$guards.Count-1]; $before = $entry.GetIdentity()
        $stream = $entry.OpenRead(); $sha = [Security.Cryptography.SHA256]::Create()
        $digest = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
        if ($entry.GetIdentity() -cne $before) { throw 'Selected crate download changed while reading' }
        return $digest
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        foreach ($guard in $guards) { $guard.Dispose() }
    }
}

# Git reads its object store itself. Hold every administrative entry while it
# runs; an inventory of paths taken before launching Git is not custody.
# Both source proofs and download selection use this same storage boundary.
function Open-DsrCargoGitCustody {
    param([string]$Admin)
    $guards = Open-DsrCachePathGuard $Admin
    $entries = [Collections.Generic.List[object]]::new()
    $directories = [Collections.Generic.List[object]]::new()
    function Open-DsrCargoGitAdministrativeEntry {
        param([string]$Relative)
        if ($entries.Count -ge 500000) { throw 'Oversized Cargo Git administrative storage' }
        if ($Relative -in @('commondir','objects/info/alternates','objects/info/http-alternates')) {
            throw 'External Git object storage is not an admitted source'
        }
        $pathValue = if ($Relative) { $Admin.TrimEnd('/') + '/' + $Relative } else { $Admin }
        $attributes = [IO.File]::GetAttributes($pathValue)
        $directory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
        if (-not $directory -and [IO.Path]::GetFileName($pathValue) -ieq '.git') { throw 'External Git directory reference is not admitted' }
        $entry = Open-DsrCacheEntry $pathValue -Directory $directory
        $entries.Add(@{entry=$entry;identity=$entry.GetIdentity()})
        if ($directory) {
            $children = Get-DsrCacheChildren $pathValue
            $directories.Add(@{entry=$entry;children=($children -join [char]0)})
            foreach ($child in $children) {
                $name = [IO.Path]::GetFileName($child)
                Open-DsrCargoGitAdministrativeEntry $(if ($Relative) { $Relative + '/' + $name } else { $name })
            }
        }
    }
    try {
        Open-DsrCargoGitAdministrativeEntry ''
        return @{guards=$guards;entries=$entries;directories=$directories}
    } catch {
        foreach ($item in $entries) { $item.entry.Dispose() }
        foreach ($guard in $guards) { $guard.Dispose() }
        throw
    }
}

function Assert-DsrCargoGitCustody {
    param($Custody)
    foreach ($item in $Custody.entries) {
        if ($item.entry.GetIdentity() -cne $item.identity) { throw 'Git administrative storage changed during a local read' }
    }
    foreach ($directory in $Custody.directories) {
        if (((Get-DsrCacheChildren $directory.entry.Path) -join [char]0) -cne $directory.children) {
            throw 'Git object storage changed during a local read'
        }
    }
}

function Close-DsrCargoGitCustody {
    param($Custody)
    foreach ($item in $Custody.entries) { $item.entry.Dispose() }
    foreach ($guard in $Custody.guards) { $guard.Dispose() }
}

function Invoke-DsrCargoCacheGitProbe {
    param([string]$Admin, [string[]]$Arguments, [AllowNull()][string]$Incoming=$null)
    $custody = Open-DsrCargoGitCustody $Admin
    try {
        $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $result = [DsrCargoCacheNative]::GitProbe($git.Source,$Admin,$Arguments,$Incoming)
        Assert-DsrCargoGitCustody $custody
        return $result
    } finally { Close-DsrCargoGitCustody $custody }
}

function Get-DsrCargoLockSelection {
    param([AllowEmptyString()][string]$CargoHome, [byte[]]$LockBytes)
    Initialize-DsrCargoCacheNative
    $packages = [DsrCargoSourceLock]::Read($LockBytes)
    if ($packages.Count -gt 10000) { throw 'Oversized Cargo.lock download selection' }
    $archives = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $registries = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $revisions = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $names = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($package in $packages) {
        $name = [string]$package['name']; $version = [string]$package['version']
        $origin = if ($package.ContainsKey('source')) { [string]$package['source'] } else { $null }
        if ($name -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
            $version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?$' -or
            ($null -ne $origin -and $origin -match '[\x00-\x1f\x7f]')) { throw 'Unsafe locked package identity for download selection' }
        if (-not $seen.Add($name + [char]0 + $version + [char]0 + $origin)) { throw 'Duplicate Cargo.lock package' }
        if ($null -eq $origin) { continue }
        if ($origin.StartsWith('registry+', [StringComparison]::Ordinal) -or $origin.StartsWith('sparse+', [StringComparison]::Ordinal)) {
            if (-not $package.ContainsKey('checksum') -or [string]$package['checksum'] -cnotmatch '^[0-9a-f]{64}$') {
                throw 'Locked registry package lacks a SHA256 checksum'
            }
            $archive = $name + '-' + $version + '.crate'
            if (-not $archives.ContainsKey($archive)) { $archives.Add($archive,[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)) }
            $null = $archives[$archive].Add([string]$package['checksum'])
            $null = $registries.Add($origin.Substring($origin.IndexOf('+')+1).TrimEnd('/'))
            $null = $names.Add($name.ToLowerInvariant())
        } elseif ($origin.StartsWith('git+', [StringComparison]::Ordinal) -and $origin -cmatch '#[0-9a-f]{40}$') {
            $null = $revisions.Add($origin.Substring($origin.LastIndexOf('#')+1))
        } else { throw 'Unsupported or unpinned Cargo.lock source' }
    }
    $selected = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    function Add-DsrCargoDownload {
        param([string]$Relative)
        $parts = $Relative.Split('/'); $node = $selected
        for ($index = 0; $index -lt $parts.Length - 1; $index++) {
            $part = $parts[$index]
            if ($node.ContainsKey($part) -and $null -eq $node[$part]) { return }
            if (-not $node.ContainsKey($part)) { $node.Add($part,[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)) }
            $node = $node[$part]
        }
        $node[$parts[-1]] = $null
    }
    $selectedRegistries = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($CargoHome -and $archives.Count -gt 0) {
        foreach ($registry in (Get-DsrCargoCacheRoutes $CargoHome 'registry/cache')) {
            foreach ($archive in $archives.Keys) {
                $relative = 'registry/cache/' + $registry + '/' + $archive
                $digest = Get-DsrCargoCacheCandidateHash $CargoHome $relative
                if ($null -ne $digest -and $archives[$archive].Contains($digest)) {
                    Add-DsrCargoDownload $relative; $expected.Add($relative,$digest)
                    $null = $selectedRegistries.Add($registry)
                }
            }
        }
        foreach ($registry in (Get-DsrCargoCacheRoutes $CargoHome 'registry/index')) {
            if (-not $selectedRegistries.Contains($registry)) { continue }
            $prefix = 'registry/index/' + $registry + '/'
            foreach ($name in $names) {
                $route = if ($name.Length -eq 1) { '1/' } elseif ($name.Length -eq 2) { '2/' }
                    elseif ($name.Length -eq 3) { '3/' + $name.Substring(0,1) + '/' }
                    else { $name.Substring(0,2) + '/' + $name.Substring(2,2) + '/' }
                $relative = $prefix + '.cache/' + $route + $name
                if (Get-DsrCargoCacheCandidateHash $CargoHome $relative -PresenceOnly) { Add-DsrCargoDownload $relative }
            }
            if (Get-DsrCargoCacheCandidateHash $CargoHome ($prefix + 'config.json') -PresenceOnly) { Add-DsrCargoDownload ($prefix + 'config.json') }
            $gitGuards = Open-DsrCargoCacheCandidate $CargoHome ($prefix + '.git') -Directory $true
            if ($null -ne $gitGuards) {
                try {
                    $origin = (Invoke-DsrCargoCacheGitProbe ($CargoHome.TrimEnd('/') + '/' + $prefix + '.git') @('config','--local','--get','remote.origin.url')).Trim().TrimEnd('/')
                    if ($registries.Contains($origin)) { Add-DsrCargoDownload ($prefix + '.git') }
                } finally { foreach ($guard in $gitGuards) { $guard.Dispose() } }
            }
        }
    }
    if ($CargoHome -and $revisions.Count -gt 0) {
        $request = (@($revisions) -join "`n") + "`n"
        foreach ($database in (Get-DsrCargoCacheRoutes $CargoHome 'git/db')) {
            $relative = 'git/db/' + $database
            $rows = Invoke-DsrCargoCacheGitProbe ($CargoHome.TrimEnd('/') + '/' + $relative) @('cat-file','--batch-check') $request
            foreach ($row in $rows.Split("`n")) {
                if ($row.TrimEnd("`r") -cmatch '^([0-9a-f]{40}) commit [0-9]+$' -and $revisions.Contains($Matches[1])) {
                    Add-DsrCargoDownload $relative; break
                }
            }
        }
    }
    return @{paths=$selected;checksums=$expected;selection=@{kind='cargo-lock-downloads';
        lockfile_sha256=(Get-DsrCacheBytesHash $LockBytes);registry_packages=$archives.Count;git_revisions=@($revisions)}}
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
    param([string]$CargoHome, [string]$CopyTo='', [bool]$RequirePrivate=$true, $SelectedPaths=$null)
    $guards = Open-DsrCachePathGuard $CargoHome
    $files = New-Object 'System.Collections.Generic.List[object]'
    $directories = New-Object 'System.Collections.Generic.List[string]'
    $caches = New-Object 'System.Collections.Generic.List[string]'
    $observed = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $links = @{}
    function Visit-DsrCargoCache {
        param([string]$Relative, [bool]$Recheck=$false, $Selection=$null)
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
                if ($null -eq $Selection) { $children = Get-DsrCacheChildren $pathValue }
                else {
                    # Open only selected routing children. Retain full native
                    # directory identity checks: unlike Unix openat, child
                    # opens here still use absolute Windows paths.
                    $names = [string[]]@($Selection.Keys); [Array]::Sort($names,[StringComparer]::Ordinal)
                    $children = @($names | ForEach-Object { $pathValue + '/' + $_ })
                }
                if (-not $Recheck) {
                    $directories.Add($Relative)
                    if ($CopyTo) { $null = [IO.Directory]::CreateDirectory($CopyTo.TrimEnd('/') + '/' + $Relative) }
                }
                foreach ($child in $children) {
                    $name = [IO.Path]::GetFileName($child)
                    $childSelection = $null
                    if ($null -ne $Selection) { $childSelection = $Selection[$name] }
                    Visit-DsrCargoCache ($Relative + '/' + $name) $Recheck $childSelection
                }
                if ($null -eq $Selection) {
                    $after = Get-DsrCacheChildren $pathValue
                    if (($children -join [char]0) -cne ($after -join [char]0)) { throw 'Cache directory changed during inventory' }
                }
            } elseif (-not $Recheck) {
                if ($null -ne $Selection) { throw 'Selected cache ancestor is not a directory' }
                $parts = $Relative.Split('/')
                if ($null -ne $SelectedPaths -and
                    ($Relative -imatch '^registry/index/[^/]+/\.git$' -or
                    $Relative -imatch '^(?:git/db/[^/]+|registry/index/[^/]+/\.git)/(?:commondir|objects/info/(?:http-)?alternates)$')) {
                    throw ('External Git storage reference in selected downloads: ' + $Relative)
                }
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
        if ($null -eq $SelectedPaths) {
            foreach ($child in (Get-DsrCacheChildren $CargoHome)) { $rootNames[[IO.Path]::GetFileName($child)] = $true }
        } else { foreach ($name in $SelectedPaths.Keys) { $rootNames[$name] = $true } }
        foreach ($name in @('git','registry')) {
            if ($rootNames.ContainsKey($name)) {
                $root = Open-DsrCacheEntry ($CargoHome.TrimEnd('/') + '/' + $name) -Directory $true
                $root.Dispose()
                $caches.Add($name)
                $rootSelection = $null
                if ($null -ne $SelectedPaths) { $rootSelection = $SelectedPaths[$name] }
                Visit-DsrCargoCache $name $false $rootSelection
            }
        }
        if ($null -eq $SelectedPaths) {
            $afterNames = @{}
            foreach ($child in (Get-DsrCacheChildren $CargoHome)) { $afterNames[[IO.Path]::GetFileName($child)] = $true }
            foreach ($name in @('git','registry')) {
                if ($rootNames.ContainsKey($name) -ne $afterNames.ContainsKey($name)) { throw 'Cargo cache root changed during inventory' }
            }
        }
        if ($RequirePrivate) {
            foreach ($name in $caches) {
                $rootSelection = $null
                if ($null -ne $SelectedPaths) { $rootSelection = $SelectedPaths[$name] }
                Visit-DsrCargoCache $name $true $rootSelection
            }
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
    $summary = @{schema_version=1; mode=$Receipt.kind; cargo_home=$Receipt.cargo_home;
        receipt_path=$Path; receipt_sha256=$Digest; inventory_sha256=(Get-DsrCacheBytesHash $inventoryBytes);
        caches=@($Receipt.inventory.caches); file_count=@($Receipt.inventory.files).Count; size_bytes=$size}
    $hasSelection = if ($Receipt -is [Collections.IDictionary]) { $Receipt.Contains('selection') }
        else { $null -ne $Receipt.PSObject.Properties['selection'] }
    if ($hasSelection) { $summary.selection = $Receipt.selection }
    return $summary
}

function Assert-DsrCargoCacheSelection {
    param($Selection)
    if ($Selection -is [Collections.IDictionary]) { $keys = [string[]]@($Selection.Keys) }
    elseif ($Selection -is [pscustomobject]) { $keys = [string[]]@($Selection.PSObject.Properties.Name) }
    else { throw 'Invalid Cargo cache download selection' }
    [Array]::Sort($keys,[StringComparer]::Ordinal)
    if (($keys -join ',') -cne 'git_revisions,kind,lockfile_sha256,registry_packages' -or
        $Selection.kind -isnot [string] -or $Selection.kind -cne 'cargo-lock-downloads' -or
        $Selection.lockfile_sha256 -isnot [string] -or $Selection.lockfile_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        ($Selection.registry_packages -isnot [int] -and $Selection.registry_packages -isnot [long]) -or
        $Selection.registry_packages -lt 0 -or $Selection.registry_packages -gt 10000 -or
        $Selection.git_revisions -isnot [Array] -or $Selection.git_revisions.Count -gt 10000) { throw 'Invalid Cargo cache download selection' }
    $previous = $null
    foreach ($revision in $Selection.git_revisions) {
        if ($revision -isnot [string] -or $revision -cnotmatch '^[0-9a-f]{40}$' -or
            ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous,$revision) -ge 0)) {
            throw 'Invalid selected Cargo Git revisions'
        }
        $previous = $revision
    }
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
        [AllowEmptyString()][string]$First, [Parameter(Mandatory=$true)][string]$Second,
        [string]$Lockfile='')
    if ($PSBoundParameters.ContainsKey('Lockfile') -and -not $Lockfile) { throw 'Cargo.lock selection requires a nonempty lockfile path' }
    if ($Lockfile -and $Operation -ne 'snapshot') { throw 'Cargo.lock selection is supported only for cache snapshots' }
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
        $sourceGuards = $null; $lockGuards = $null; $lockEntry = $null; $selection = $null; $selectedPaths = $null
        try {
            if ($Lockfile) {
                $lockPath = Get-DsrCacheFullPath $Lockfile
                $lockParent = ([IO.Path]::GetDirectoryName($lockPath)).Replace('\','/')
                $lockGuards = Open-DsrCachePathGuard $lockParent
                $lockEntry = Open-DsrCacheEntry $lockPath
                $lockIdentity = $lockEntry.GetIdentity()
                $selection = Get-DsrCargoLockSelection $source (Get-DsrCacheHeldBytes $lockEntry)
                $selectedPaths = $selection.paths
            }
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
            $inventory = if ($source) { Get-DsrCargoCacheInventory $source $secondPath $false $selectedPaths }
                else { @{caches=@();directories=@();files=@()} }
            if ($null -ne $selection) {
                foreach ($file in $inventory.files) {
                    if ($selection.checksums.ContainsKey($file.path) -and $selection.checksums[$file.path] -cne $file.sha256) {
                        throw 'Selected crate archive changed after lockfile admission'
                    }
                }
            }
            $selected = ConvertTo-DsrCacheCanonicalJson $inventory
            if ((ConvertTo-DsrCacheCanonicalJson (Get-DsrCargoCacheInventory $secondPath)) -cne $selected) {
                throw 'Private cache copy does not match its seed'
            }
            if ($source -and (ConvertTo-DsrCacheCanonicalJson (Get-DsrCargoCacheInventory $source -RequirePrivate $false -SelectedPaths $selectedPaths)) -cne $selected) {
                throw 'Source cache changed during snapshot'
            }
            Assert-DsrCargoHome $secondPath
            $receipt = @{schema_version=1;kind='private-copy';cargo_home=$secondPath;seed_source=$source;inventory=$inventory}
            if ($null -ne $selection) {
                if ($lockEntry.GetIdentity() -cne $lockIdentity -or
                    (Get-DsrCacheBytesHash (Get-DsrCacheHeldBytes $lockEntry)) -cne $selection.selection.lockfile_sha256) {
                    throw 'Cargo.lock changed during download snapshot'
                }
                Assert-DsrCargoCacheSelection $selection.selection
                $receipt.selection = $selection.selection
            }
            $receiptPath = $secondPath + '/.dsr-cache-seed.json'
            $digest = New-DsrCargoReceipt $receiptPath $receipt
            return Get-DsrCargoCacheSummary $receiptPath $receipt $digest
        } finally {
            if ($null -ne $lockEntry) { $lockEntry.Dispose() }
            if ($null -ne $lockGuards) { foreach ($guard in $lockGuards) { $guard.Dispose() } }
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
    $hasSelection = $null -ne $receipt.PSObject.Properties['selection']
    $expectedKeys = if ($hasSelection) { 'cargo_home,inventory,kind,schema_version,seed_source,selection' }
        else { 'cargo_home,inventory,kind,schema_version,seed_source' }
    if ($hasSelection) {
        if ($receipt.kind -cne 'private-copy') { throw 'Cargo download selection requires a private-copy receipt' }
        Assert-DsrCargoCacheSelection $receipt.selection
    }
    if (($keys -join ',') -cne $expectedKeys -or
        ($receipt.schema_version -isnot [long] -and $receipt.schema_version -isnot [int]) -or
        $receipt.schema_version -ne 1 -or $receipt.kind -cnotin @('private-copy','inventory') -or
        $receipt.cargo_home -cne $homePath -or
        (ConvertTo-DsrCacheCanonicalJson $receipt.inventory) -cne
        (ConvertTo-DsrCacheCanonicalJson (Get-DsrCargoCacheInventory $homePath))) {
        throw 'Private Cargo cache does not match its inventory'
    }
    return Get-DsrCargoCacheSummary $secondPath $receipt $read.sha256
}
