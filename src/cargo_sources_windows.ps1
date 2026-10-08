# Authenticated sources for strict native Windows Cargo builds. Functions only;
# load cargo_cache_windows.ps1 first. PowerShell 7.4+ supplies .NET's TAR/JSON
# readers. Inventories alone never establish the authenticity of cached bytes.

function Initialize-DsrCargoSourcesNative {
    if ($PSVersionTable.PSVersion -lt [version]'7.4') { throw 'Windows source authentication requires PowerShell 7.4 or newer' }
    Initialize-DsrCargoCacheNative
    Add-Type -AssemblyName System.Formats.Tar
    if ('DsrCargoSourceObjects' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

public static class DsrCargoSourceObjects {
    public static void Member(string name) {
        if (String.IsNullOrEmpty(name) || name.Length > 32700 || name.IndexOfAny(new char[] {'\\', ':', '<', '>', '"', '|', '?', '*'}) >= 0)
            throw new InvalidDataException("Unsafe authenticated source member");
        foreach (char c in name) if (c < 32 || c == 127) throw new InvalidDataException("Control character in source member");
        foreach (string part in name.Split('/')) {
            if (part.Length == 0 || part == "." || part == ".." || part.Equals(".git", StringComparison.OrdinalIgnoreCase) ||
                part.EndsWith(".", StringComparison.Ordinal) || part.EndsWith(" ", StringComparison.Ordinal) ||
                Regex.IsMatch(part, @"^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)"))
                throw new InvalidDataException("Ambiguous Windows source member");
        }
    }
    public static string Hash(Stream stream) {
        using (SHA256 hash = SHA256.Create()) return Convert.ToHexString(hash.ComputeHash(stream)).ToLowerInvariant();
    }
    sealed class ObjectData { public byte[] Data; public string Hash; public long Size; }
    sealed class Reader : IDisposable {
        readonly Process process;
        readonly Stream output;
        readonly Stream input;
        public Reader(string executable, string admin) {
            ProcessStartInfo info = new ProcessStartInfo(executable);
            info.UseShellExecute = false;
            info.ArgumentList.Add("-c"); info.ArgumentList.Add("protocol.allow=never");
            info.ArgumentList.Add("--git-dir=" + admin); info.ArgumentList.Add("cat-file"); info.ArgumentList.Add("--batch");
            List<string> names = new List<string>();
            foreach (string name in info.Environment.Keys) if (name.StartsWith("GIT_", StringComparison.OrdinalIgnoreCase)) names.Add(name);
            foreach (string name in names) info.Environment.Remove(name);
            info.Environment["GIT_CONFIG_NOSYSTEM"] = "1";
            info.Environment["GIT_CONFIG_GLOBAL"] = OperatingSystem.IsWindows() ? "NUL" : "/dev/null";
            info.Environment["GIT_NO_REPLACE_OBJECTS"] = "1";
            info.Environment["GIT_NO_LAZY_FETCH"] = "1";
            info.Environment["GIT_ALLOW_PROTOCOL"] = "";
            info.Environment["GIT_TERMINAL_PROMPT"] = "0";
            info.Environment["GIT_OPTIONAL_LOCKS"] = "0"; info.Environment["LC_ALL"] = "C";
            info.RedirectStandardInput = true; info.RedirectStandardOutput = true; info.RedirectStandardError = true;
            process = Process.Start(info);
            if (process == null) throw new IOException("Cannot start locked Git object reader");
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args) { };
            process.BeginErrorReadLine();
            input = process.StandardInput.BaseStream; output = process.StandardOutput.BaseStream;
        }
        void Read(byte[] buffer, int count) {
            int offset = 0;
            while (offset < count) {
                var read = output.ReadAsync(buffer, offset, count - offset);
                if (!read.Wait(30000)) throw new IOException("Locked Git object read timed out");
                int size = read.GetAwaiter().GetResult();
                if (size <= 0) throw new InvalidDataException("Truncated locked Git object");
                offset += size;
            }
        }
        public ObjectData Get(string oid, string kind) {
            if (!Regex.IsMatch(oid, "^[0-9a-f]{40}$")) throw new InvalidDataException("Invalid locked Git object ID");
            byte[] request = Encoding.ASCII.GetBytes(oid + "\n"); input.Write(request, 0, request.Length); input.Flush();
            byte[] one = new byte[1]; StringBuilder header = new StringBuilder();
            while (true) {
                Read(one, 1); if (one[0] == 10) break;
                if (one[0] < 32 || one[0] > 126 || header.Length >= 128) throw new InvalidDataException("Invalid locked Git object header");
                header.Append((char)one[0]);
            }
            string[] fields = header.ToString().Split(' '); long length;
            if (fields.Length != 3 || fields[0] != oid || fields[1] != kind || !Int64.TryParse(fields[2], out length) ||
                length < 0 || length > (kind == "blob" ? 1073741824L : 67108864L))
                throw new InvalidDataException("Missing, wrong-type or oversized locked Git object");
            using (SHA1 identity = SHA1.Create()) using (SHA256 contents = SHA256.Create()) {
                byte[] prefix = Encoding.ASCII.GetBytes(kind + " " + length.ToString(System.Globalization.CultureInfo.InvariantCulture) + "\0");
                identity.TransformBlock(prefix, 0, prefix.Length, prefix, 0);
                byte[] data = kind == "blob" ? null : new byte[(int)length];
                byte[] buffer = new byte[1048576]; long consumed = 0;
                while (consumed < length) {
                    int count = (int)Math.Min(buffer.Length, length - consumed); Read(buffer, count);
                    identity.TransformBlock(buffer, 0, count, buffer, 0); contents.TransformBlock(buffer, 0, count, buffer, 0);
                    if (data != null) Buffer.BlockCopy(buffer, 0, data, (int)consumed, count);
                    consumed += count;
                }
                identity.TransformFinalBlock(buffer, 0, 0); contents.TransformFinalBlock(buffer, 0, 0); Read(one, 1);
                if (one[0] != 10 || Convert.ToHexString(identity.Hash).ToLowerInvariant() != oid)
                    throw new InvalidDataException("Locked Git object bytes do not match their ID");
                return new ObjectData { Data = data, Hash = Convert.ToHexString(contents.Hash).ToLowerInvariant(), Size = length };
            }
        }
        public void Finish() { input.Close(); if (!process.WaitForExit(10000) || process.ExitCode != 0) throw new IOException("Locked Git object reader failed"); }
        public void Dispose() {
            if (!process.HasExited) { process.Kill(true); process.WaitForExit(); }
            input.Dispose(); output.Dispose(); process.Dispose();
        }
    }
    public static Dictionary<string, object> Git(string executable, string admin, string revision) {
        SortedDictionary<string, object> files = new SortedDictionary<string, object>(StringComparer.Ordinal);
        SortedSet<string> directories = new SortedSet<string>(StringComparer.Ordinal);
        HashSet<string> namespaceNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string tree;
        using (Reader reader = new Reader(executable, admin)) {
            ObjectData commit = reader.Get(revision, "commit");
            string first = new UTF8Encoding(false, true).GetString(commit.Data).Split('\n')[0];
            if (!Regex.IsMatch(first, "^tree [0-9a-f]{40}$")) throw new InvalidDataException("Invalid locked Git commit tree");
            tree = first.Substring(5);
            Stack<Tuple<string, string>> pending = new Stack<Tuple<string, string>>(); pending.Push(Tuple.Create("", tree));
            int count = 0;
            while (pending.Count > 0) {
                var current = pending.Pop(); byte[] data = reader.Get(current.Item2, "tree").Data; int offset = 0;
                while (offset < data.Length) {
                    int end = Array.IndexOf(data, (byte)0, offset);
                    if (end <= offset || end + 21 > data.Length) throw new InvalidDataException("Malformed locked Git tree");
                    string entry = new UTF8Encoding(false, true).GetString(data, offset, end - offset);
                    int separator = entry.IndexOf(' ');
                    if (separator <= 0) throw new InvalidDataException("Malformed locked Git tree mode");
                    string mode = entry.Substring(0, separator), leaf = entry.Substring(separator + 1);
                    Member(leaf); if (leaf.Contains('/')) throw new InvalidDataException("Invalid locked Git tree leaf");
                    string name = current.Item1 + leaf; Member(name);
                    if (++count > 500000 || !namespaceNames.Add(name)) throw new InvalidDataException("Ambiguous or oversized locked Git tree");
                    string oid = Convert.ToHexString(data, end + 1, 20).ToLowerInvariant(); offset = end + 21;
                    if (mode == "40000") { directories.Add(name); pending.Push(Tuple.Create(name + "/", oid)); }
                    else {
                        if (mode != "100644" && mode != "100755") throw new InvalidDataException("Locked Git sources contain a link or submodule");
                        ObjectData blob = reader.Get(oid, "blob");
                        files.Add(name, new Dictionary<string, object> { {"path", name}, {"sha256", blob.Hash}, {"size_bytes", blob.Size}, {"executable_bits", 0} });
                    }
                }
            }
            reader.Finish();
        }
        return new Dictionary<string, object> { {"files", new List<object>(files.Values)}, {"directories", new List<string>(directories)}, {"tree", tree} };
    }
}
'@
}

function Get-DsrCargoSourceBytes {
    param([Parameter(Mandatory=$true)][string]$Path, [long]$Maximum=268435456)
    $pathValue = Get-DsrCacheFullPath $Path
    $guards = Open-DsrCachePathGuard (([IO.Path]::GetDirectoryName($pathValue)).Replace('\','/'))
    $entry = $null; $stream = $null; $memory = $null
    try {
        $entry = Open-DsrCacheEntry $pathValue
        if ($entry.Length -gt $Maximum) { throw 'Oversized Cargo authentication input' }
        $before = $entry.GetIdentity(); $stream = $entry.OpenRead(); $memory = [IO.MemoryStream]::new()
        $stream.CopyTo($memory)
        if ($memory.Length -ne $entry.Length -or $entry.GetIdentity() -cne $before) { throw 'Cargo authentication input changed while reading' }
        return ,$memory.ToArray()
    } finally {
        if ($null -ne $memory) { $memory.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $entry) { $entry.Dispose() }
        foreach ($guard in $guards) { $guard.Dispose() }
    }
}

function Get-DsrCargoSourceFileHash {
    param([Parameter(Mandatory=$true)][string]$Path)
    $pathValue = Get-DsrCacheFullPath $Path
    $guards = Open-DsrCachePathGuard (([IO.Path]::GetDirectoryName($pathValue)).Replace('\','/'))
    $entry = $null; $stream = $null; $sha = $null
    try {
        $entry = Open-DsrCacheEntry $pathValue; $before = $entry.GetIdentity(); $stream = $entry.OpenRead()
        $sha = [Security.Cryptography.SHA256]::Create()
        $digest = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
        if ($entry.GetIdentity() -cne $before) { throw 'Cargo authentication input changed while hashing' }
        return $digest
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $entry) { $entry.Dispose() }
        foreach ($guard in $guards) { $guard.Dispose() }
    }
}

function ConvertFrom-DsrCargoSourceJson {
    param([byte[]]$Bytes)
    $text = [Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    $document = [Text.Json.JsonDocument]::Parse($text)
    function Assert-DsrSourceJsonKeys {
        param($Element)
        if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $names.Add($property.Name)) { throw 'Duplicate or case-ambiguous Cargo metadata JSON key' }
                Assert-DsrSourceJsonKeys $property.Value
            }
        } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
            foreach ($item in $Element.EnumerateArray()) { Assert-DsrSourceJsonKeys $item }
        }
    }
    try { Assert-DsrSourceJsonKeys $document.RootElement }
    finally { $document.Dispose() }
    return ConvertFrom-Json -InputObject $text -Depth 100 -ErrorAction Stop
}

function Get-DsrCargoSourceTree {
    param([string]$Root, [ValidateSet('registry','git','directory')][string]$Kind)
    $guards = Open-DsrCachePathGuard $Root
    $files = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $directories = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $count = [long[]]@(0)
    function Visit-DsrCargoSource {
        param([string]$Path, [string]$Prefix)
        $directory = Open-DsrCacheEntry $Path -Directory $true
        try {
            $before = $directory.GetIdentity(); $children = Get-DsrCacheChildren $Path
            foreach ($child in $children) {
                if (++$count[0] -gt 500000) { throw 'Dependency tree exceeds 500000 entries' }
                $leaf = [IO.Path]::GetFileName($child); $relative = $Prefix + $leaf
                if ($Kind -eq 'git' -and -not $Prefix -and $leaf -ceq '.git') {
                    $admin = Open-DsrCacheEntry $child -Directory $true
                    try { $null = $directories.Add('.git') } finally { $admin.Dispose() }
                    continue
                }
                [DsrCargoSourceObjects]::Member($relative)
                $attributes = [IO.File]::GetAttributes($child)
                if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    $null = $directories.Add($relative); Visit-DsrCargoSource $child ($relative + '/'); continue
                }
                $entry = Open-DsrCacheEntry $child; $stream = $null
                try {
                    $identity = $entry.GetIdentity(); $stream = $entry.OpenRead()
                    $digest = [DsrCargoSourceObjects]::Hash($stream)
                    if ($entry.GetIdentity() -cne $identity) { throw 'Dependency source changed while reading' }
                    $files.Add($relative, @{path=$relative;sha256=$digest;size_bytes=$entry.Length;executable_bits=0})
                } finally {
                    if ($null -ne $stream) { $stream.Dispose() }; $entry.Dispose()
                }
            }
            if ($directory.GetIdentity() -cne $before -or
                ($children -join [char]0) -cne ((Get-DsrCacheChildren $Path) -join [char]0)) { throw 'Dependency source directory changed during inventory' }
        } finally { $directory.Dispose() }
    }
    try {
        Visit-DsrCargoSource $Root ''
        return @{kind=$Kind;path=$Root;directories=@($directories);files=@($files.Values)}
    } finally { foreach ($guard in $guards) { $guard.Dispose() } }
}

function Assert-DsrCargoSourceTree {
    param($Tree, $Files, $Directories)
    $actual = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($file in $Tree.files) { $actual.Add($file.path, $file) }
    foreach ($file in $Files) { if ($file.path -ieq '.cargo-ok') { throw 'Upstream source occupies Cargo completion marker' } }
    if ($actual.ContainsKey('.cargo-ok')) {
        if ($actual['.cargo-ok'].size_bytes -gt 64) { throw 'Oversized Cargo completion marker' }
        $bytes = Get-DsrCargoSourceBytes -Path ($Tree.path + '/.cargo-ok') -Maximum 64
        $marker = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $valid = $marker -ceq 'ok' -or ($Tree.kind -eq 'git' -and $marker -ceq '')
        if (-not $valid) {
            try {
                $value = ConvertFrom-DsrCargoSourceJson $bytes
                $valid = @($value.PSObject.Properties.Name).Count -eq 1 -and $value.PSObject.Properties['v'] -and
                    ($value.v -is [int] -or $value.v -is [long]) -and $value.v -eq 1
            } catch { $valid = $false }
        }
        if (-not $valid) { throw 'Unrecognized Cargo completion marker' }
        $null = $actual.Remove('.cargo-ok')
    }
    $expected = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($file in $Files) { $expected.Add($file.path, $file) }
    if ((ConvertTo-DsrCacheCanonicalJson @($actual.Values)) -cne (ConvertTo-DsrCacheCanonicalJson @($expected.Values))) {
        throw ('Dependency source files differ from locked content: ' + $Tree.path)
    }
    $actualDirectories = [string[]]@($Tree.directories | Where-Object { -not ($Tree.kind -eq 'git' -and $_ -ceq '.git') })
    $expectedDirectories = [string[]]@($Directories)
    [Array]::Sort($actualDirectories,[StringComparer]::Ordinal); [Array]::Sort($expectedDirectories,[StringComparer]::Ordinal)
    if (($actualDirectories -join [char]0) -cne ($expectedDirectories -join [char]0)) { throw 'Dependency directories differ from locked content' }
}

function Get-DsrCargoRegistryProof {
    param($Package, $Tree, [string]$Checksum, [string]$CargoHome)
    if ($Checksum -cnotmatch '^[0-9a-f]{64}$') { throw 'Registry dependency has no SHA-256 in Cargo.lock' }
    $registry = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($Tree.path))
    $name = [IO.Path]::GetFileName($Tree.path)
    $archive = Get-DsrCacheFullPath ($CargoHome + '/registry/cache/' + $registry + '/' + $name + '.crate')
    $guards = Open-DsrCachePathGuard (([IO.Path]::GetDirectoryName($archive)).Replace('\','/'))
    $entry = $null; $stream = $null; $gzip = $null; $tar = $null
    $files = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $directories = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        $entry = Open-DsrCacheEntry $archive; $before = $entry.GetIdentity(); $stream = $entry.OpenRead()
        if ([DsrCargoSourceObjects]::Hash($stream) -cne $Checksum) { throw ('Cached crate archive differs from Cargo.lock: ' + $Package.name) }
        $stream.Position = 0
        $gzip = [IO.Compression.GZipStream]::new($stream,[IO.Compression.CompressionMode]::Decompress,$true)
        $tar = [System.Formats.Tar.TarReader]::new($gzip,$true)
        while ($null -ne ($member = $tar.GetNextEntry($false))) {
            $isDirectory = $member.EntryType -eq [System.Formats.Tar.TarEntryType]::Directory
            $memberName = if ($isDirectory) { $member.Name.TrimEnd('/') } else { $member.Name }
            [DsrCargoSourceObjects]::Member($memberName)
            if ($seen.Count -ge 500000 -or -not $seen.Add($memberName)) { throw 'Duplicate, case-colliding or oversized crate archive' }
            if ($memberName -ceq $name) { if (-not $isDirectory) { throw 'Crate root is not a directory' }; continue }
            if (-not $memberName.StartsWith($name + '/', [StringComparison]::Ordinal)) { throw 'Crate archive has another package root' }
            $relative = $memberName.Substring($name.Length + 1); [DsrCargoSourceObjects]::Member($relative)
            $parent = $relative
            while ($parent.Contains('/')) { $parent = $parent.Substring(0,$parent.LastIndexOf('/')); $null = $directories.Add($parent) }
            if ($isDirectory) { $null = $directories.Add($relative); continue }
            if ($member.EntryType -notin @([System.Formats.Tar.TarEntryType]::RegularFile,[System.Formats.Tar.TarEntryType]::V7RegularFile) -or
                $member.Length -lt 0 -or $member.Length -gt 1073741824 -or ($member.Length -gt 0 -and $null -eq $member.DataStream)) { throw 'Linked, special or oversized crate member' }
            $digest = if ($null -eq $member.DataStream) { Get-DsrCacheBytesHash ([byte[]]@()) } else { [DsrCargoSourceObjects]::Hash($member.DataStream) }
            $files.Add($relative,@{path=$relative;sha256=$digest;size_bytes=$member.Length;executable_bits=0})
        }
        if ($files.Count -eq 0) { throw 'Empty crate archive' }
        if ($entry.GetIdentity() -cne $before) { throw 'Crate archive changed during authentication' }
    } finally {
        if ($null -ne $tar) { $tar.Dispose() }; if ($null -ne $gzip) { $gzip.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }; if ($null -ne $entry) { $entry.Dispose() }
        foreach ($guard in $guards) { $guard.Dispose() }
    }
    Assert-DsrCargoSourceTree $Tree @($files.Values) @($directories)
    return @{basis='lockfile-crate-sha256';archive_sha256=$Checksum}
}

function Get-DsrCargoGitProof {
    param($Tree, [string]$Source)
    $revision = $Source.Substring($Source.LastIndexOf('#') + 1)
    if ($revision -cnotmatch '^[0-9a-f]{40}$') { throw 'Git source requires a full locked SHA-1 commit' }
    $admin = $Tree.path + '/.git'; $custody = Open-DsrCargoGitCustody $admin
    try {
        $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $expected = [DsrCargoSourceObjects]::Git($git.Source,$admin,$revision)
        Assert-DsrCargoGitCustody $custody
        Assert-DsrCargoSourceTree $Tree $expected.files $expected.directories
        return @{basis='lockfile-git-objects';commit=$revision;tree=$expected.tree}
    } finally { Close-DsrCargoGitCustody $custody }
}

function Get-DsrCargoSourceKey {
    param([string]$Name, [string]$Version, [string]$Source)
    if (-not $Name -or -not $Version -or -not $Source -or ($Name + $Version + $Source) -match '[\x00-\x1f\x7f]') { throw 'Invalid lockfile package identity' }
    if ($Source -ceq 'sparse+https://index.crates.io/') { $Source = 'registry+https://github.com/rust-lang/crates.io-index' }
    return $Name + [char]0 + $Version + [char]0 + $Source
}

function Assert-DsrCargoSourceBoundary {
    param([string]$Path, [string]$Root, [switch]$Exact, [switch]$File)
    $rootGuards = Open-DsrCachePathGuard $Root
    $pathGuards = $null; $entry = $null
    try {
        $directory = if ($File) { ([IO.Path]::GetDirectoryName($Path)).Replace('\','/') } else { $Path }
        $pathGuards = Open-DsrCachePathGuard $directory
        $rootId = $rootGuards[$rootGuards.Count-1].FileId
        $inside = if ($Exact) { $pathGuards[$pathGuards.Count-1].FileId -ceq $rootId }
            else { @($pathGuards | Where-Object { $_.FileId -ceq $rootId }).Count -gt 0 }
        if (-not $inside) { throw 'Cargo source path escapes its admitted physical root' }
        if ($File) {
            $entry = Open-DsrCacheEntry $Path
            if ($Exact) {
                # The workspace's Cargo.lock is the authority. A case-sensitive
                # NTFS directory can contain a different cargo.lock alongside it.
                $expected = Open-DsrCacheEntry ($Root.TrimEnd('/') + '/Cargo.lock')
                try { if ($entry.FileId -cne $expected.FileId) { throw 'Cargo lockfile differs from the admitted physical lockfile' } }
                finally { $expected.Dispose() }
            }
        }
    } finally {
        if ($null -ne $entry) { $entry.Dispose() }
        if ($null -ne $pathGuards) { foreach ($guard in $pathGuards) { $guard.Dispose() } }
        foreach ($guard in $rootGuards) { $guard.Dispose() }
    }
}

function Invoke-DsrCargoSources {
    param([Parameter(Mandatory=$true)][ValidateSet('capture','verify')][string]$Operation,
        [Parameter(Mandatory=$true)][string]$MetadataPath, [Parameter(Mandatory=$true)][string]$ReceiptPath,
        [Parameter(Mandatory=$true)][string]$Lockfile, [Parameter(Mandatory=$true)][string]$CargoHome,
        [Parameter(Mandatory=$true)][string]$SourceRoot, [string]$ExpectedSha256='')
    Initialize-DsrCargoSourcesNative
    $metadataPathValue = Get-DsrCacheFullPath $MetadataPath; $receiptPathValue = Get-DsrCacheFullPath $ReceiptPath
    $source = Get-DsrCacheFullPath $SourceRoot; $homePath = Get-DsrCacheFullPath $CargoHome; $lockPath = Get-DsrCacheFullPath $Lockfile
    if ($Operation -eq 'verify' -and $ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Source verification requires the controller-held receipt digest' }
    $held = if ($Operation -eq 'verify') { Read-DsrCargoReceipt $receiptPathValue } else { $null }
    if ($null -ne $held -and $held.sha256 -cne $ExpectedSha256) { throw 'Admitted dependency source receipt changed' }
    $metadataBytes = Get-DsrCargoSourceBytes $metadataPathValue
    $metadata = ConvertFrom-DsrCargoSourceJson $metadataBytes
    if (-not $metadata.PSObject.Properties['workspace_root'] -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals((Get-DsrCacheFullPath $metadata.workspace_root),$source) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals($lockPath,($source.TrimEnd('/') + '/Cargo.lock'))) { throw 'Cargo metadata workspace or lockfile escapes the admitted source root' }
    # Path spelling is retained in receipts, but case folding is not ownership:
    # Windows supports case-sensitive directories containing distinct siblings.
    Assert-DsrCargoSourceBoundary -Path (Get-DsrCacheFullPath $metadata.workspace_root) -Root $source -Exact
    Assert-DsrCargoSourceBoundary -Path $lockPath -Root $source -Exact -File
    $rawLock = Get-DsrCargoSourceBytes $lockPath
    $locked = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($package in [DsrCargoSourceLock]::Read($rawLock)) {
        if (-not $package.ContainsKey('source')) { continue }
        $key = Get-DsrCargoSourceKey $package.name $package.version $package.source
        if (-not $locked.TryAdd($key,$package)) { throw 'Ambiguous lockfile package identity' }
    }
    $byPackage = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $byNode = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if (-not $metadata.PSObject.Properties['packages'] -or $metadata.packages -isnot [array] -or
        -not $metadata.PSObject.Properties['resolve'] -or $null -eq $metadata.resolve -or
        -not $metadata.resolve.PSObject.Properties['nodes'] -or $metadata.resolve.nodes -isnot [array]) { throw 'Cargo metadata lacks a resolved dependency graph' }
    foreach ($package in $metadata.packages) {
        if (-not $package.PSObject.Properties['id'] -or $package.id -isnot [string] -or -not $package.id -or
            -not $byPackage.TryAdd($package.id,$package)) { throw 'Invalid or repeated Cargo package ID' }
    }
    foreach ($node in $metadata.resolve.nodes) {
        if (-not $node.PSObject.Properties['id'] -or $node.id -isnot [string] -or -not $byPackage.ContainsKey($node.id) -or
            -not $node.PSObject.Properties['dependencies'] -or $node.dependencies -isnot [array] -or
            -not $byNode.TryAdd($node.id,$node)) { throw 'Invalid resolved Cargo node' }
        foreach ($dependency in $node.dependencies) { if ($dependency -isnot [string]) { throw 'Invalid resolved dependency ID' } }
    }
    if (-not $metadata.PSObject.Properties['workspace_members'] -or $metadata.workspace_members -isnot [array] -or
        $metadata.workspace_members.Count -eq 0) { throw 'Cargo metadata has no workspace membership' }
    $selected = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Stack[string]]::new()
    foreach ($id in $metadata.workspace_members) {
        if ($id -isnot [string] -or -not $byNode.ContainsKey($id) -or -not $selected.Add($id)) { throw 'Invalid selected workspace member' }
        $package = $byPackage[$id]
        if (-not $package.PSObject.Properties['source'] -or $null -ne $package.source -or
            -not $package.PSObject.Properties['manifest_path']) { throw 'Workspace member is not a local package' }
        $localManifest = Get-DsrCacheFullPath $package.manifest_path
        Assert-DsrCargoSourceBoundary -Path $localManifest -Root $source -File
        $pending.Push($id)
    }
    $reachable = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    while ($pending.Count -gt 0) {
        $id = $pending.Pop()
        if (-not $byNode.ContainsKey($id)) { throw 'Resolved Cargo dependency is missing' }
        if ($reachable.Add($id)) { foreach ($dependency in $byNode[$id].dependencies) { $pending.Push($dependency) } }
    }
    $roots = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $admitted = [Collections.Generic.List[object]]::new()
    foreach ($id in $reachable) {
        $package = $byPackage[$id]
        if (-not $package.PSObject.Properties['source']) { throw 'Missing Cargo source identity' }
        if ($null -eq $package.source) { continue }
        if ($package.source -isnot [string] -or $package.source -cnotmatch '^(registry\+|sparse\+|git\+)') { throw 'Unsupported remote Cargo dependency source' }
        foreach ($field in @('name','version','manifest_path','targets')) { if (-not $package.PSObject.Properties[$field]) { throw 'Incomplete Cargo dependency metadata' } }
        $manifest = Get-DsrCacheFullPath $package.manifest_path
        if ([IO.Path]::GetFileName($manifest) -cne 'Cargo.toml') { throw 'Unexpected dependency manifest name' }
        $root = ([IO.Path]::GetDirectoryName($manifest)).Replace('\','/'); $kind = 'directory'
        $registryPrefix = $homePath.TrimEnd('/') + '/registry/src/'
        $gitPrefix = $homePath.TrimEnd('/') + '/git/checkouts/'
        if ($package.source -cmatch '^(registry\+|sparse\+)' -and $root.StartsWith($registryPrefix,[StringComparison]::OrdinalIgnoreCase)) {
            $relative = $root.Substring($registryPrefix.Length).Split('/')
            if ($relative.Count -ne 2 -or $relative[1] -cne ($package.name + '-' + $package.version)) { throw 'Registry cache path differs from its package identity' }
            $kind = 'registry'
        } elseif ($package.source.StartsWith('git+',[StringComparison]::Ordinal) -and $root.StartsWith($gitPrefix,[StringComparison]::OrdinalIgnoreCase)) {
            $relative = $root.Substring($gitPrefix.Length).Split('/')
            if ($relative.Count -lt 2) { throw 'Incomplete Cargo Git checkout path' }
            $root = $gitPrefix + $relative[0] + '/' + $relative[1]; $kind = 'git'
        } else {
            if (-not (Test-DsrCacheInside $root $source)) { throw 'External directory source needs committed workspace coverage' }
            Assert-DsrCargoSourceBoundary -Path $root -Root $source
            $descriptor = ConvertFrom-DsrCargoSourceJson (Get-DsrCargoSourceBytes ($root + '/.cargo-checksum.json'))
            if (-not $descriptor.PSObject.Properties['files'] -or $descriptor.files -isnot [pscustomobject]) { throw 'Dependency is not an admitted Cargo directory source' }
        }
        if ($kind -ne 'directory') { Assert-DsrCargoSourceBoundary -Path $root -Root $homePath }
        if (Test-DsrCacheInside $receiptPathValue $root) { throw 'Receipt cannot be inside dependency sources' }
        if ($roots.ContainsKey($root) -and $roots[$root] -cne $kind) { throw 'Conflicting dependency source root' }
        $roots[$root] = $kind
        $key = Get-DsrCargoSourceKey $package.name $package.version $package.source
        if (-not $locked.ContainsKey($key)) { throw ('Resolved dependency is not pinned by Cargo.lock: ' + $package.name) }
        $admitted.Add(@{package_id=$id;source=$package.source;name=$package.name;version=$package.version;root=$root;manifest=$manifest.Substring($root.Length+1)})
        if ($package.targets -isnot [array]) { throw 'Invalid Cargo dependency targets' }
        foreach ($target in $package.targets) {
            if (-not $target.PSObject.Properties['src_path']) { throw 'Missing dependency target source' }
            $path = Get-DsrCacheFullPath $target.src_path
            if (-not (Test-DsrCacheInside $path $root) -or $path -ieq $root) { throw 'Dependency target escapes its source tree' }
            Assert-DsrCargoSourceBoundary -Path $path -Root $root -File
        }
    }
    $trees = [Collections.Generic.List[object]]::new(); $indexed = @{}
    foreach ($root in $roots.Keys) {
        $tree = Get-DsrCargoSourceTree $root $roots[$root]; $trees.Add($tree); $indexed[$root] = $tree
    }
    $proofs = [Collections.Generic.List[object]]::new(); $gitProofs = @{}
    foreach ($package in $admitted) {
        $tree = $indexed[$package.root]; $fileNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($file in $tree.files) { $null = $fileNames.Add($file.path) }
        if (-not $fileNames.Contains($package.manifest)) { throw 'Missing dependency manifest' }
        foreach ($target in $byPackage[$package.package_id].targets) {
            $path = Get-DsrCacheFullPath $target.src_path
            if (-not $fileNames.Contains($path.Substring($package.root.Length+1))) { throw 'Missing dependency target source' }
        }
        $key = Get-DsrCargoSourceKey $package.name $package.version $package.source
        if ($tree.kind -eq 'registry') {
            $pin = $locked[$key]; $checksum = if ($pin.ContainsKey('checksum')) { $pin['checksum'] } else { '' }
            $proof = Get-DsrCargoRegistryProof $package $tree $checksum $homePath
        } elseif ($tree.kind -eq 'git') {
            $gitKey = $package.root + [char]0 + $package.source
            if (-not $gitProofs.ContainsKey($gitKey)) { $gitProofs[$gitKey] = Get-DsrCargoGitProof $tree $package.source }
            $proof = $gitProofs[$gitKey]
        } else { $proof = @{basis='caller-verified-workspace-snapshot';path=$package.root.Substring($source.Length+1)} }
        $proofs.Add(@{package_id=$package.package_id} + $proof)
    }
    foreach ($tree in $trees) {
        if ((ConvertTo-DsrCacheCanonicalJson $tree) -cne (ConvertTo-DsrCacheCanonicalJson (Get-DsrCargoSourceTree $tree.path $tree.kind))) {
            throw 'Dependency source changed during authentication'
        }
    }
    $lockDigest = Get-DsrCacheBytesHash $rawLock
    if ((Get-DsrCargoSourceFileHash $lockPath) -cne $lockDigest -or
        (Get-DsrCargoSourceFileHash $metadataPathValue) -cne (Get-DsrCacheBytesHash $metadataBytes)) { throw 'Cargo metadata or lockfile changed during authentication' }
    $evidence = @{schema_version=1;kind='dsr-cargo-dependency-sources';selected_packages=@($selected);packages=@($admitted);roots=@($trees);
        authentication=@{lockfile_sha256=$lockDigest;packages=@($proofs)}}
    if ($Operation -eq 'capture') { $digest = New-DsrCargoReceipt $receiptPathValue $evidence }
    else {
        if ((ConvertTo-DsrCacheCanonicalJson $held.value) -cne (ConvertTo-DsrCacheCanonicalJson $evidence) -or
            (Get-DsrCargoSourceFileHash $receiptPathValue) -cne $ExpectedSha256) { throw 'Resolved dependency source bytes or receipt changed' }
        $digest = $ExpectedSha256
    }
    $fileCount = 0; $size = [long]0
    foreach ($tree in $trees) { foreach ($file in $tree.files) { $fileCount++; $size += $file.size_bytes } }
    return @{schema_version=1;kind='dsr-cargo-dependency-sources';sha256=$digest;package_count=$admitted.Count;root_count=$trees.Count;
        file_count=$fileCount;size_bytes=$size;authentication=@{lockfile_sha256=$lockDigest;
            locked_archive_packages=@($proofs | Where-Object { $_.basis -eq 'lockfile-crate-sha256' }).Count;
            locked_git_packages=@($proofs | Where-Object { $_.basis -eq 'lockfile-git-objects' }).Count;
            workspace_snapshot_packages=@($proofs | Where-Object { $_.basis -eq 'caller-verified-workspace-snapshot' }).Count}}
}
