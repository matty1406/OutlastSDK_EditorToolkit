<#
.SYNOPSIS
  Rename a script mod made with MakeMod.bat, everywhere it appears.

.DESCRIPTION
  Renames, in order:

    1. The mod folder, Development\Src\<OldName> -> <NewName>. Done first, so a
       folder that is in use stops the rename before anything else has changed.
    2. Files named after the mod or one of its classes: the workspace, the
       manifest, any class starting with the old name, localization files.
    3. The old name inside the mod's text files, as a whole word only: package
       references, class names, the bats, the workspace, the manifest's Id.
       Classes keep the rest of their name, so OldNameGame becomes NewNameGame.
    4. The ModEditPackages registration, in place, so compile order is kept.

  Then deletes the stale OLGame\Script\<OldName>.u and Output\<OldName>\, which
  belong to a package that no longer exists. Recompile afterwards.

.PARAMETER OldName
  The mod to rename. Defaults to $env:OldName, which is how RenameMod.bat passes it.

.PARAMETER NewName
  The new name. Turned into PascalCase if it is not a valid package name, the same
  way MakeMod does it. Defaults to $env:NewName.

.PARAMETER EngineRoot
  Root of the UnrealEngine3 tree. Defaults to the parent of MakeModSrcFiles.
#>
[CmdletBinding()]
param(
    [string] $OldName = $env:OldName,

    [string] $NewName = $env:NewName,

    [string] $EngineRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "ModNames.ps1")

# RenameMod.bat passes "<root>\.", and the path comparisons below need it plain.
$EngineRoot = [IO.Path]::GetFullPath($EngineRoot).TrimEnd('\')

# Rename a file or folder. A change of case alone needs a hop through a temporary
# name, since Windows treats the two names as the same path.
function Rename-Path([string] $Path, [string] $NewLeaf)
{
    $parent = Split-Path -Parent $Path
    $target = Join-Path $parent $NewLeaf

    if ((Split-Path -Leaf $Path) -ieq $NewLeaf)
    {
        $temp = Join-Path $parent ("~rename~" + [guid]::NewGuid().ToString("N"))
        Move-Item -LiteralPath $Path -Destination $temp
        Move-Item -LiteralPath $temp -Destination $target
    }
    else
    {
        Move-Item -LiteralPath $Path -Destination $target
    }
}

# Read a text file in whatever encoding it has, so UTF-16 localization files and
# plain ANSI sources both come back byte-for-byte apart from the renamed words.
# Latin-1 maps every byte to one char, which makes a file with no BOM round-trip.
function Read-Text([string] $Path)
{
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $reader = New-Object IO.StreamReader($Path, $latin1, $true)
    $text   = $reader.ReadToEnd()
    $enc    = $reader.CurrentEncoding
    $reader.Close()
    return @{ Text = $text; Encoding = $enc }
}

# --- Checks -------------------------------------------------------------------

$OldName = "$OldName".Trim()
if (-not $OldName)
{
    throw "No mod name given."
}

$SrcRoot = Join-Path $EngineRoot "Development\Src"
$OldDir  = Join-Path $SrcRoot $OldName

# Only folders MakeMod made, so an engine package such as Engine or OutlastSDK can
# never be renamed by mistake.
if (-not (Test-Path (Join-Path $OldDir "Compile.bat")))
{
    throw "No mod named '$OldName' in Development\Src. RenameMod only renames mods made with MakeMod.bat."
}

# Use the folder's real spelling, since every match below is case-sensitive. Get-Item
# would echo back the spelling as typed, so read it from the parent's listing.
$OldName = (Get-ChildItem -LiteralPath $SrcRoot -Directory | Where-Object { $_.Name -ieq $OldName }).Name
$OldDir  = Join-Path $SrcRoot $OldName

$Typed   = "$NewName".Trim()
$NewName = ConvertTo-ModName $Typed
if (-not $NewName)
{
    throw "'$Typed' has no letters to make a mod name from."
}
if ($NewName -cne $Typed)
{
    Write-Host "  '$Typed' is not a valid package name, using '$NewName'"
}

if ($NewName -ceq $OldName)
{
    throw "'$OldName' already has that name."
}

$NewDir = Join-Path $SrcRoot $NewName
if ((Test-Path $NewDir) -and ($NewName -ine $OldName))
{
    throw "Development\Src\$NewName already exists."
}

# Old name -> new name, for the package and for every class that starts with it.
# Ordinal, because a plain @{} ignores case and every match here is case-sensitive.
$Renames = New-Object Collections.Hashtable ([StringComparer]::Ordinal)
$Renames[$OldName] = $NewName
$ClassDir = Join-Path $OldDir "Classes"
if (Test-Path $ClassDir)
{
    foreach ($uc in Get-ChildItem -LiteralPath $ClassDir -Filter *.uc -Recurse)
    {
        if ($uc.BaseName.StartsWith($OldName, [StringComparison]::Ordinal))
        {
            $Renames[$uc.BaseName] = $NewName + $uc.BaseName.Substring($OldName.Length)
        }
    }
}

# --- 1. Folder ----------------------------------------------------------------

try
{
    Rename-Path $OldDir $NewName
}
catch
{
    throw "Could not rename Development\Src\$OldName. Close anything using it (VS Code, a terminal, an Explorer window) and try again.`n$($_.Exception.Message)"
}
Write-Host "  renamed  Development\Src\$OldName -> $NewName"

# Output\ holds an old Deploy, rebuilt from scratch every time, so leave it out.
$OutputDir = Join-Path $NewDir "Output"
$ModFiles  = Get-ChildItem -LiteralPath $NewDir -File -Recurse |
             Where-Object { -not $_.FullName.StartsWith($OutputDir + "\", [StringComparison]::OrdinalIgnoreCase) }

# --- 2. File names ------------------------------------------------------------

foreach ($file in $ModFiles)
{
    # "Name.code-workspace" has the base name "Name", which is what we want here.
    $base = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    if ($Renames.ContainsKey($base) -and $Renames[$base] -cne $base)
    {
        $newLeaf = $Renames[$base] + $file.Extension
        Rename-Path $file.FullName $newLeaf
        Write-Host "  renamed  $($file.Name) -> $newLeaf"
    }
}

# --- 3. Contents --------------------------------------------------------------

# Longest names first, so OldNameGame is matched whole before OldName alone.
$names   = $Renames.Keys | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }
$pattern = New-Object regex ('(?<![A-Za-z0-9_])(' + ($names -join '|') + ')(?![A-Za-z0-9_])')
$swap    = [Text.RegularExpressions.MatchEvaluator] { param($m) $Renames[$m.Value] }

$TextExts = '.uc', '.uci', '.bat', '.json', '.code-workspace', '.ini', '.int', '.txt', '.md'
$LocDir   = Join-Path $NewDir "Localization"

$ModFiles = Get-ChildItem -LiteralPath $NewDir -File -Recurse |
            Where-Object { -not $_.FullName.StartsWith($OutputDir + "\", [StringComparison]::OrdinalIgnoreCase) }

foreach ($file in $ModFiles)
{
    $isLoc = $file.FullName.StartsWith($LocDir + "\", [StringComparison]::OrdinalIgnoreCase)
    if ($isLoc -or ($TextExts -contains $file.Extension.ToLower()))
    {
        $read    = Read-Text $file.FullName
        $updated = $pattern.Replace($read.Text, $swap)
        if ($updated -cne $read.Text)
        {
            [IO.File]::WriteAllText($file.FullName, $updated, $read.Encoding)
            Write-Host "  updated  $($file.FullName.Substring($NewDir.Length + 1))"
        }
    }
}

# --- 4. Registration ----------------------------------------------------------

# Swap the name on the line it is already on, so it keeps its place in the compile
# order. Register-Package then adds it if the old name was never registered.
$entry = '^(\s*\+?ModEditPackages\s*=\s*)' + [regex]::Escape($OldName) + '\s*$'
foreach ($ini in "OLGame\Config\DefaultEngine.ini", "OLGame\Config\OLEngine.ini")
{
    $iniPath = Join-Path $EngineRoot $ini
    if (Test-Path $iniPath)
    {
        $lines   = @(Get-Content $iniPath -Encoding ASCII)
        $changed = $false
        for ($i = 0; $i -lt $lines.Count; $i++)
        {
            if ($lines[$i] -match $entry)
            {
                $lines[$i] = $Matches[1] + $NewName
                $changed = $true
            }
        }

        if ($changed)
        {
            Set-Content -Path $iniPath -Value $lines -Encoding ASCII
            Write-Host "  updated  $(Split-Path $iniPath -Leaf) ($OldName -> $NewName)"
        }
    }
}

& (Join-Path $PSScriptRoot "Register-Package.ps1") -EngineRoot $EngineRoot -Package OutlastSDK, $NewName

# --- Stale builds -------------------------------------------------------------

# Both belong to a package name that no longer exists, so neither can be reused.
$OldU = Join-Path $EngineRoot "OLGame\Script\$OldName.u"
if (Test-Path $OldU)
{
    Remove-Item -LiteralPath $OldU -Force
    Write-Host "  removed  OLGame\Script\$OldName.u (old build)"
}

$OldOutput = Join-Path $OutputDir $OldName
if (Test-Path $OldOutput)
{
    Remove-Item -LiteralPath $OldOutput -Recurse -Force
    Write-Host "  removed  Output\$OldName\ (old deploy)"
}

Write-Host ""
Write-Host "$OldName is now $NewName. Run Compile.bat to rebuild it."
Write-Host "If another mod requires this one by Id, update its SDKModRequires by hand."