<#
.SYNOPSIS
  Reads the parts of an Unreal package the map tools need: its version stamp, its sublevel list and its name table. Dot-source it.

.DESCRIPTION
  Cooked packages are LZO-compressed, so the reader carries its own LZO decompressor. It is plain C# compiled by PowerShell on first use, so nothing extra needs installing.
#>

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace OutlastToolkit
{
    // The header fields, name table and imported packages of one package.
    public class UPackageInfo
    {
        public string Path;
        public int Version;
        public int Licensee;
        public int EngineVersion;
        public uint PackageFlags;
        public uint CompressionFlags;
        public string[] AdditionalPackagesToCook = new string[0];
        public string[] Names = new string[0];

        // Every outside package this one imports from, and the ones its own objects take their class from.
        public string[] ImportedPackages = new string[0];
        public string[] ClassPackages = new string[0];
    }

    // One OLCheckpoint: its CheckpointName, and the persistent map it names ("" when it names none, so it
    // belongs to the map it is in).
    public class CheckpointEntry
    {
        public string Name;
        public string PersistentLevel;
    }

    // The checkpoints a package holds, in the order they are stored, and the order its first
    // OLCheckpointList gives.
    public class CheckpointInfo
    {
        public CheckpointEntry[] Checkpoints = new CheckpointEntry[0];
        public string[] ListOrder = new string[0];
    }

    // Where the tables are, and the compressed chunks that hold the rest.
    class Header
    {
        public int NameCount;
        public int NameOffset;
        public int ExportCount;
        public int ExportOffset;
        public int ImportCount;
        public int ImportOffset;
        public int ChunkCount;
        public int[,] Chunks;
    }

    // The import table, kept just long enough to resolve where each import lives.
    class ImportTable
    {
        public int[] Outer;
        public string[] ObjectName;
        public string[] ClassName;

        // The top-level package an import sits in, found by following its outers.
        public string TopPackage(int index)
        {
            string top = ObjectName[index];
            int outer = Outer[index];
            int steps = 0;
            while (outer < 0 && -outer - 1 < Outer.Length && steps < 64)
            {
                index = -outer - 1;
                top = ObjectName[index];
                outer = Outer[index];
                steps++;
            }
            return top;
        }
    }

    public static class UPackageReader
    {
        const uint PackageTag = 0x9E2A83C1;
        const uint CompressLzo = 2;

        public static UPackageInfo Read(string path, bool readNames, bool readImports)
        {
            byte[] data = File.ReadAllBytes(path);
            UPackageInfo info = new UPackageInfo();
            info.Path = path;
            Header h = ParseHeader(data, info);

            if (readNames || readImports)
            {
                ReadTables(info, data, h.NameOffset, h.NameCount, h.ImportOffset, h.ImportCount, h.ExportOffset, h.ExportCount, h.Chunks, h.ChunkCount, readImports);
            }

            return info;
        }

        static Header ParseHeader(byte[] data, UPackageInfo info)
        {
            Header h = new Header();
            int p = 0;

            if (ReadU32(data, ref p) != PackageTag)
            {
                throw new InvalidDataException(info.Path + " is not an Unreal package.");
            }

            uint fileVersion = ReadU32(data, ref p);
            info.Version = (int)(fileVersion & 0xFFFF);
            info.Licensee = (int)(fileVersion >> 16);

            // TotalHeaderSize, then the folder name.
            p += 4;
            ReadFString(data, ref p, data.Length);

            info.PackageFlags = ReadU32(data, ref p);
            h.NameCount = ReadI32(data, ref p);
            h.NameOffset = ReadI32(data, ref p);

            h.ExportCount = ReadI32(data, ref p);
            h.ExportOffset = ReadI32(data, ref p);
            h.ImportCount = ReadI32(data, ref p);
            h.ImportOffset = ReadI32(data, ref p);

            // Depends offset, import/export GUIDs, thumbnail table and package GUID.
            p += 4 + 12 + 4 + 16;

            int generationCount = ReadI32(data, ref p);
            p += 12 * generationCount;

            info.EngineVersion = ReadI32(data, ref p);
            p += 4;
            info.CompressionFlags = ReadU32(data, ref p);

            h.ChunkCount = ReadI32(data, ref p);
            h.Chunks = new int[h.ChunkCount, 4];
            for (int i = 0; i < h.ChunkCount; i++)
            {
                for (int j = 0; j < 4; j++)
                {
                    h.Chunks[i, j] = ReadI32(data, ref p);
                }
            }

            // PackageSource, then the sublevels a persistent map pulls into the cook.
            p += 4;
            int additionalCount = ReadI32(data, ref p);
            info.AdditionalPackagesToCook = new string[additionalCount];
            for (int i = 0; i < additionalCount; i++)
            {
                info.AdditionalPackagesToCook[i] = ReadFString(data, ref p, data.Length);
            }

            return h;
        }

        // The whole package, decompressed: every chunk, not just as far as the tables reach.
        static byte[] Inflate(byte[] data, UPackageInfo info, Header h)
        {
            byte[] buffer = data;
            if (info.CompressionFlags != 0 && h.ChunkCount > 0)
            {
                if (info.CompressionFlags != CompressLzo)
                {
                    throw new NotSupportedException(info.Path + " uses compression " + info.CompressionFlags + ", only LZO is supported.");
                }

                int total = 0;
                for (int i = 0; i < h.ChunkCount; i++)
                {
                    total = Math.Max(total, h.Chunks[i, 0] + h.Chunks[i, 1]);
                }

                buffer = new byte[total];
                Buffer.BlockCopy(data, 0, buffer, 0, Math.Min(h.Chunks[0, 0], data.Length));
                for (int i = 0; i < h.ChunkCount; i++)
                {
                    DecompressChunk(data, h.Chunks[i, 2], buffer, h.Chunks[i, 0], h.Chunks[i, 1]);
                }
            }
            return buffer;
        }

        // The OLCheckpoints a package holds and the order its OLCheckpointList puts them in. Read from each
        // object's tagged properties, found by their tag, so an actor's own preamble does not have to be parsed.
        public static CheckpointInfo ReadCheckpoints(string path)
        {
            byte[] data = File.ReadAllBytes(path);
            UPackageInfo info = new UPackageInfo();
            info.Path = path;
            Header h = ParseHeader(data, info);
            byte[] buffer = Inflate(data, info, h);

            string[] names = ParseNames(buffer, buffer.Length, h.NameOffset, h.NameCount);
            ImportTable imports = names != null ? ParseImports(buffer, buffer.Length, h.ImportOffset, h.ImportCount, names) : null;
            CheckpointInfo result = new CheckpointInfo();

            if (imports != null)
            {
                int cpName = Array.IndexOf(names, "CheckpointName");
                int levelName = Array.IndexOf(names, "PersistentLevelName");
                int listName = Array.IndexOf(names, "CheckpointList");
                int nameProp = Array.IndexOf(names, "NameProperty");
                int arrayProp = Array.IndexOf(names, "ArrayProperty");
                List<CheckpointEntry> found = new List<CheckpointEntry>();

                int p = h.ExportOffset;
                for (int i = 0; i < h.ExportCount && p + 48 <= buffer.Length; i++)
                {
                    int classIndex = BitConverter.ToInt32(buffer, p);
                    int size = BitConverter.ToInt32(buffer, p + 32);
                    int offset = BitConverter.ToInt32(buffer, p + 36);
                    int netCount = BitConverter.ToInt32(buffer, p + 44);
                    string cls = (classIndex < 0 && -classIndex - 1 < imports.ObjectName.Length) ? imports.ObjectName[-classIndex - 1] : "";
                    bool inside = size > 0 && offset >= 0 && (long)offset + size <= buffer.Length;

                    if (inside && cls == "OLCheckpoint")
                    {
                        CheckpointEntry e = new CheckpointEntry();
                        e.Name = FindNameProperty(buffer, offset, offset + size, cpName, nameProp, names);
                        e.PersistentLevel = FindNameProperty(buffer, offset, offset + size, levelName, nameProp, names);
                        if (e.Name != "")
                        {
                            found.Add(e);
                        }
                    }
                    else if (inside && cls == "OLCheckpointList" && result.ListOrder.Length == 0)
                    {
                        result.ListOrder = FindNameArrayProperty(buffer, offset, offset + size, listName, arrayProp, names);
                    }

                    p += 48 + 4 * Math.Max(netCount, 0) + 20;
                }
                result.Checkpoints = found.ToArray();
            }
            return result;
        }

        // A name property's value: its tag is (name, NameProperty, size 8, index 0), the value follows. "" when
        // the object does not set it, or sets it to None.
        static string FindNameProperty(byte[] b, int start, int end, int prop, int nameProp, string[] names)
        {
            string value = "";
            if (prop >= 0 && nameProp >= 0)
            {
                for (int p = start; p + 32 <= end && value == ""; p++)
                {
                    if (BitConverter.ToInt32(b, p) == prop && BitConverter.ToInt32(b, p + 4) == 0 &&
                        BitConverter.ToInt32(b, p + 8) == nameProp && BitConverter.ToInt32(b, p + 12) == 0 &&
                        BitConverter.ToInt32(b, p + 16) == 8 && BitConverter.ToInt32(b, p + 20) == 0)
                    {
                        value = FormatName(names, BitConverter.ToInt32(b, p + 24), BitConverter.ToInt32(b, p + 28));
                        if (value == "None")
                        {
                            value = "";
                        }
                        break;
                    }
                }
            }
            return value;
        }

        // An array<name> property: its tag, then a count and that many names.
        static string[] FindNameArrayProperty(byte[] b, int start, int end, int prop, int arrayProp, string[] names)
        {
            string[] value = new string[0];
            if (prop >= 0 && arrayProp >= 0)
            {
                for (int p = start; p + 28 <= end; p++)
                {
                    if (BitConverter.ToInt32(b, p) == prop && BitConverter.ToInt32(b, p + 4) == 0 &&
                        BitConverter.ToInt32(b, p + 8) == arrayProp && BitConverter.ToInt32(b, p + 12) == 0 &&
                        BitConverter.ToInt32(b, p + 20) == 0)
                    {
                        int size = BitConverter.ToInt32(b, p + 16);
                        int count = BitConverter.ToInt32(b, p + 24);
                        if (count >= 0 && size == 4 + 8 * count && p + 28 + 8 * count <= end)
                        {
                            value = new string[count];
                            for (int i = 0; i < count; i++)
                            {
                                value[i] = FormatName(names, BitConverter.ToInt32(b, p + 28 + 8 * i), BitConverter.ToInt32(b, p + 32 + 8 * i));
                            }
                            break;
                        }
                    }
                }
            }
            return value;
        }

        // Decompresses only as far as the wanted tables reach, then parses them into info.
        static void ReadTables(UPackageInfo info, byte[] data, int nameOffset, int nameCount, int importOffset, int importCount, int exportOffset, int exportCount, int[,] chunks, int chunkCount, bool readImports)
        {
            byte[] buffer = data;
            int filled = data.Length;
            int nextChunk = chunkCount;

            if (info.CompressionFlags != 0 && chunkCount > 0)
            {
                if (info.CompressionFlags != CompressLzo)
                {
                    throw new NotSupportedException(info.Path + " uses compression " + info.CompressionFlags + ", only LZO is supported.");
                }

                int total = 0;
                for (int i = 0; i < chunkCount; i++)
                {
                    total = Math.Max(total, chunks[i, 0] + chunks[i, 1]);
                }

                buffer = new byte[total];
                Buffer.BlockCopy(data, 0, buffer, 0, Math.Min(chunks[0, 0], data.Length));
                filled = chunks[0, 0];
                nextChunk = 0;
            }

            string[] names = null;
            ImportTable imports = null;
            string[] classPackages = null;
            bool done = false;

            while (!done)
            {
                if (names == null)
                {
                    names = ParseNames(buffer, filled, nameOffset, nameCount);
                }
                if (readImports && names != null && imports == null)
                {
                    imports = ParseImports(buffer, filled, importOffset, importCount, names);
                }
                if (readImports && imports != null && classPackages == null)
                {
                    classPackages = ParseClassPackages(buffer, filled, exportOffset, exportCount, imports);
                }

                bool complete = names != null && (!readImports || classPackages != null);
                if (complete || nextChunk >= chunkCount)
                {
                    done = true;
                }
                else
                {
                    DecompressChunk(data, chunks[nextChunk, 2], buffer, chunks[nextChunk, 0], chunks[nextChunk, 1]);
                    filled = chunks[nextChunk, 0] + chunks[nextChunk, 1];
                    nextChunk++;
                }
            }

            if (names == null || (readImports && classPackages == null))
            {
                throw new InvalidDataException("Could not read the tables of " + info.Path);
            }

            info.Names = names;
            if (imports != null)
            {
                List<string> packages = new List<string>();
                for (int i = 0; i < imports.Outer.Length; i++)
                {
                    if (imports.Outer[i] == 0 && imports.ClassName[i] == "Package")
                    {
                        packages.Add(imports.ObjectName[i]);
                    }
                }
                info.ImportedPackages = packages.ToArray();
                info.ClassPackages = classPackages;
            }
        }

        // Each import is ClassPackage, ClassName, OuterIndex, ObjectName. Returns null when the table runs past the buffer.
        static ImportTable ParseImports(byte[] buffer, int limit, int offset, int count, string[] names)
        {
            ImportTable table = null;

            if ((long)offset + (long)count * 28 <= limit)
            {
                table = new ImportTable();
                table.Outer = new int[count];
                table.ObjectName = new string[count];
                table.ClassName = new string[count];

                for (int i = 0; i < count; i++)
                {
                    int p = offset + i * 28;
                    table.ClassName[i] = FormatName(names, BitConverter.ToInt32(buffer, p + 8), BitConverter.ToInt32(buffer, p + 12));
                    table.Outer[i] = BitConverter.ToInt32(buffer, p + 16);
                    table.ObjectName[i] = FormatName(names, BitConverter.ToInt32(buffer, p + 20), BitConverter.ToInt32(buffer, p + 24));
                }
            }

            return table;
        }

        // The packages this package's own objects take their class from. Each export starts with its class
        // index; a negative one is an import. Entries are 68 bytes plus 4 per generation net object count.
        // Returns null when the table runs past the buffer.
        static string[] ParseClassPackages(byte[] buffer, int limit, int offset, int count, ImportTable imports)
        {
            HashSet<string> packages = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            int p = offset;
            bool complete = true;

            for (int i = 0; i < count && complete; i++)
            {
                if (p + 48 > limit)
                {
                    complete = false;
                }
                else
                {
                    int classIndex = BitConverter.ToInt32(buffer, p);
                    int netObjectCount = BitConverter.ToInt32(buffer, p + 44);
                    int size = 48 + 4 * netObjectCount + 20;

                    if (netObjectCount < 0 || p + size > limit)
                    {
                        complete = false;
                    }
                    else
                    {
                        if (classIndex < 0 && -classIndex - 1 < imports.Outer.Length)
                        {
                            packages.Add(imports.TopPackage(-classIndex - 1));
                        }
                        p += size;
                    }
                }
            }

            string[] result = null;
            if (complete)
            {
                result = new string[packages.Count];
                packages.CopyTo(result);
            }
            return result;
        }

        // A name with a number of N is written Name_(N-1).
        static string FormatName(string[] names, int index, int number)
        {
            string name = "?";
            if (index >= 0 && index < names.Length)
            {
                name = names[index];
            }
            if (number > 0)
            {
                name = name + "_" + (number - 1);
            }
            return name;
        }

        // Returns null when the table runs past what has been decompressed so far.
        static string[] ParseNames(byte[] buffer, int limit, int offset, int count)
        {
            string[] names = new string[count];
            int p = offset;
            bool complete = true;

            for (int i = 0; i < count && complete; i++)
            {
                string name = TryReadFString(buffer, ref p, limit);
                if (name == null || p + 8 > limit)
                {
                    complete = false;
                }
                else
                {
                    names[i] = name;
                    p += 8;
                }
            }

            return complete ? names : null;
        }

        static void DecompressChunk(byte[] src, int offset, byte[] dst, int dstOffset, int dstSize)
        {
            int q = offset;
            ReadU32(src, ref q);
            int blockSize = ReadI32(src, ref q);
            ReadI32(src, ref q);
            int uncompressedTotal = ReadI32(src, ref q);
            int blockCount = (uncompressedTotal + blockSize - 1) / blockSize;

            int[] compressedSizes = new int[blockCount];
            int[] uncompressedSizes = new int[blockCount];
            for (int b = 0; b < blockCount; b++)
            {
                compressedSizes[b] = ReadI32(src, ref q);
                uncompressedSizes[b] = ReadI32(src, ref q);
            }

            int op = dstOffset;
            for (int b = 0; b < blockCount; b++)
            {
                Lzo1xDecompress(src, q, dst, op, uncompressedSizes[b]);
                q += compressedSizes[b];
                op += uncompressedSizes[b];
            }

            if (op - dstOffset != dstSize)
            {
                throw new InvalidDataException("A compressed chunk did not match its recorded size.");
            }
        }

        // LZO1X decompression, written as the states of the reference decoder.
        static void Lzo1xDecompress(byte[] src, int ip, byte[] dst, int op, int outLength)
        {
            const int Loop = 0;
            const int FirstLiteralRun = 1;
            const int Match = 2;
            const int MatchDone = 3;

            int start = op;
            int t = 0;
            int mpos;
            int state = Loop;
            bool done = false;

            if (src[ip] > 17)
            {
                t = src[ip] - 17;
                ip++;
                CopyBytes(src, ref ip, dst, ref op, t);
                if (t < 4)
                {
                    t = src[ip];
                    ip++;
                    state = Match;
                }
                else
                {
                    state = FirstLiteralRun;
                }
            }

            while (!done)
            {
                if (state == Loop)
                {
                    t = src[ip];
                    ip++;
                    if (t >= 16)
                    {
                        state = Match;
                    }
                    else
                    {
                        if (t == 0)
                        {
                            while (src[ip] == 0)
                            {
                                t += 255;
                                ip++;
                            }
                            t += 15 + src[ip];
                            ip++;
                        }
                        CopyBytes(src, ref ip, dst, ref op, t + 3);
                        state = FirstLiteralRun;
                    }
                }
                else if (state == FirstLiteralRun)
                {
                    t = src[ip];
                    ip++;
                    if (t >= 16)
                    {
                        state = Match;
                    }
                    else
                    {
                        mpos = op - (1 + 0x0800) - (t >> 2) - (src[ip] << 2);
                        ip++;
                        CopyMatch(dst, ref op, mpos, 3);
                        state = MatchDone;
                    }
                }
                else if (state == Match)
                {
                    if (t >= 64)
                    {
                        mpos = op - 1 - ((t >> 2) & 7) - (src[ip] << 3);
                        ip++;
                        CopyMatch(dst, ref op, mpos, (t >> 5) - 1 + 2);
                    }
                    else if (t >= 32)
                    {
                        t &= 31;
                        if (t == 0)
                        {
                            while (src[ip] == 0)
                            {
                                t += 255;
                                ip++;
                            }
                            t += 31 + src[ip];
                            ip++;
                        }
                        int v = src[ip] | (src[ip + 1] << 8);
                        ip += 2;
                        mpos = op - 1 - (v >> 2);
                        CopyMatch(dst, ref op, mpos, t + 2);
                    }
                    else if (t >= 16)
                    {
                        mpos = op - ((t & 8) << 11);
                        t &= 7;
                        if (t == 0)
                        {
                            while (src[ip] == 0)
                            {
                                t += 255;
                                ip++;
                            }
                            t += 7 + src[ip];
                            ip++;
                        }
                        int v = src[ip] | (src[ip + 1] << 8);
                        ip += 2;
                        mpos -= v >> 2;

                        // A distance of zero marks the end of the stream.
                        if (mpos == op)
                        {
                            done = true;
                        }
                        else
                        {
                            mpos -= 0x4000;
                            CopyMatch(dst, ref op, mpos, t + 2);
                        }
                    }
                    else
                    {
                        mpos = op - 1 - (t >> 2) - (src[ip] << 2);
                        ip++;
                        CopyMatch(dst, ref op, mpos, 2);
                    }

                    if (!done)
                    {
                        state = MatchDone;
                    }
                }
                else
                {
                    t = src[ip - 2] & 3;
                    if (t == 0)
                    {
                        state = Loop;
                    }
                    else
                    {
                        CopyBytes(src, ref ip, dst, ref op, t);
                        t = src[ip];
                        ip++;
                        state = Match;
                    }
                }
            }

            if (op - start != outLength)
            {
                throw new InvalidDataException("An LZO block did not decompress to its recorded size.");
            }
        }

        static void CopyBytes(byte[] src, ref int ip, byte[] dst, ref int op, int count)
        {
            Buffer.BlockCopy(src, ip, dst, op, count);
            ip += count;
            op += count;
        }

        // Byte by byte, because a match may overlap the bytes it is writing.
        static void CopyMatch(byte[] dst, ref int op, int mpos, int count)
        {
            for (int i = 0; i < count; i++)
            {
                dst[op] = dst[mpos + i];
                op++;
            }
        }

        static uint ReadU32(byte[] data, ref int p)
        {
            uint value = BitConverter.ToUInt32(data, p);
            p += 4;
            return value;
        }

        static int ReadI32(byte[] data, ref int p)
        {
            int value = BitConverter.ToInt32(data, p);
            p += 4;
            return value;
        }

        static string ReadFString(byte[] data, ref int p, int limit)
        {
            string value = TryReadFString(data, ref p, limit);
            if (value == null)
            {
                throw new InvalidDataException("A string ran past the end of the package header.");
            }
            return value;
        }

        // Positive length is ANSI, negative is UTF-16; both include the terminator.
        static string TryReadFString(byte[] data, ref int p, int limit)
        {
            string value = null;

            if (p + 4 <= limit)
            {
                int length = BitConverter.ToInt32(data, p);
                if (length == 0)
                {
                    value = "";
                    p += 4;
                }
                else if (length > 0 && p + 4 + length <= limit)
                {
                    value = Encoding.GetEncoding(28591).GetString(data, p + 4, length - 1);
                    p += 4 + length;
                }
                else if (length < 0 && p + 4 - length * 2 <= limit)
                {
                    value = Encoding.Unicode.GetString(data, p + 4, (-length - 1) * 2);
                    p += 4 - length * 2;
                }
            }

            return value;
        }
    }
}
'@

if (-not ('OutlastToolkit.UPackageReader' -as [type]))
{
    Add-Type -TypeDefinition $source -Language CSharp
}

# Reads a package header, its name table with -Names, and the packages it imports from with -Imports.
function Read-UPackage
{
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [switch] $Names,
        [switch] $Imports
    )

    return [OutlastToolkit.UPackageReader]::Read($Path, $Names.IsPresent, $Imports.IsPresent)
}

# The checkpoints a cooked map holds, each with the persistent map it names, and the order its checkpoint
# list gives them.
function Read-Checkpoints([string] $Path)
{
    return [OutlastToolkit.UPackageReader]::ReadCheckpoints($Path)
}

# The script packages retail lacks that a set of imports needs. Kind is Mod for a package registered with
# the compiler as a mod (+ModEditPackages), followed through its own imports in turn, or Engine for one of
# this engine's own packages that retail does not have, such as UnrealEd. Via names the mod that pulled a
# package in, and is empty for one the maps import directly. Anything else imported is retail's
# always-loaded content. The SDK supplies its own checked copy of OutlastSDK, so what OutlastSDK itself
# needs is not followed.
function Find-CustomScriptPackages
{
    param(
        [string[]] $Imports,
        [string] $EngineRoot,
        $RetailNames,
        $ModPackages
    )

    $scriptDir = Join-Path $EngineRoot 'OLGame\Script'
    $found = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $order = New-Object 'System.Collections.Generic.List[object]'
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($name in $Imports)
    {
        $queue.Enqueue([pscustomobject]@{ Name = $name; Via = $null })
    }

    while ($queue.Count -gt 0)
    {
        $item = $queue.Dequeue()
        $name = $item.Name
        if (-not $RetailNames.Contains($name) -and -not $found.ContainsKey($name))
        {
            # Read the real file name, since imports are not always in the package's own case.
            $uFile = Get-ChildItem -LiteralPath $scriptDir -Filter "$name.u" -ErrorAction SilentlyContinue | Select-Object -First 1
            $classes = Join-Path $EngineRoot "Development\Src\$name\Classes"
            $isMod = $ModPackages.Contains($name)

            if ($isMod -or $uFile)
            {
                $entry = [pscustomobject]@{ Name = $name; Kind = 'Engine'; Via = $item.Via; Path = $null; Version = 0; Licensee = 0; Sources = $null; Stale = $null }
                if ($uFile)
                {
                    $entry.Name = $uFile.BaseName
                }
                if ($isMod)
                {
                    $entry.Kind = 'Mod'
                }
                if (Test-Path -LiteralPath $classes)
                {
                    $entry.Sources = Split-Path $classes
                }

                if ($isMod -and $uFile)
                {
                    $u = $uFile.FullName
                    $info = Read-UPackage $u -Imports
                    $entry.Path = $u
                    $entry.Version = $info.Version
                    $entry.Licensee = $info.Licensee

                    # A source file edited after the build would ship without that edit.
                    if ($entry.Sources)
                    {
                        $newer = Get-ChildItem -LiteralPath $classes -Filter *.uc -Recurse | Where-Object { $_.LastWriteTime -gt $uFile.LastWriteTime } | Select-Object -First 1
                        if ($newer)
                        {
                            $entry.Stale = $newer.Name
                        }
                    }

                    if ($name -ne 'OutlastSDK')
                    {
                        foreach ($dependency in $info.ImportedPackages)
                        {
                            $queue.Enqueue([pscustomobject]@{ Name = $dependency; Via = $entry.Name })
                        }
                    }
                }

                $found[$name] = $entry
                $order.Add($entry)
            }
        }
    }

    return $order
}

# The packages registered with the compiler as mods, read from DefaultEngine.ini and the generated OLEngine.ini.
function Get-ModPackages([string] $EngineRoot)
{
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($ini in 'DefaultEngine.ini', 'OLEngine.ini')
    {
        $path = Join-Path $EngineRoot "OLGame\Config\$ini"
        if (Test-Path -LiteralPath $path)
        {
            foreach ($line in Get-Content -LiteralPath $path)
            {
                if ($line -match '^\s*\+?ModEditPackages\s*=\s*(\S+)\s*$')
                {
                    [void] $set.Add($Matches[1])
                }
            }
        }
    }
    return ,$set
}

# A case-insensitive set of a package's names, for quick lookups.
function Get-UPackageNameSet([string] $Path)
{
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $set.UnionWith([string[]] (Read-UPackage $Path -Names).Names)
    return ,$set
}

# Keeps the maps that are not a sublevel of another map in the list. A map owns sublevels when it has
# streaming level objects, and it names each sublevel it streams.
function Get-PersistentMaps([System.IO.FileInfo[]] $Files)
{
    $owners = @{}
    foreach ($file in $Files)
    {
        $set = Get-UPackageNameSet $file.FullName
        if ($set.Contains('LevelStreamingKismet') -or $set.Contains('LevelStreamingAlwaysLoaded') -or $set.Contains('LevelStreamingDistance'))
        {
            $owners[$file.BaseName] = $set
        }
    }

    foreach ($file in $Files)
    {
        $isSublevel = $false
        foreach ($owner in $owners.Keys)
        {
            if ($owner -ne $file.BaseName -and $owners[$owner].Contains($file.BaseName))
            {
                $isSublevel = $true
            }
        }

        if (-not $isSublevel)
        {
            $file
        }
    }
}