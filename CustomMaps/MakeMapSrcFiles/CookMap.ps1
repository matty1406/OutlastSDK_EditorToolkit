<#
.SYNOPSIS
  Cooks a map project for retail Outlast and copies only the files its maps use to the output folder.

.DESCRIPTION
  Called by the project's Cook.bat. Finds the maps, makes sure the engine has retail's cooker data, runs the cooker, then keeps the cooked maps, their sublevels and the texture caches they reference. Everything else the cooker writes (Wwise banks retail already has, cooker data, shader caches, files from other cooks) is left out. Each package is checked for retail format and for names retail already uses before anything is copied.

.PARAMETER Name
  The project name. It is also the cook's DLC name, so the texture caches come out as Textures_<Name>.tfc and so on.

.PARAMETER EngineRoot
  Root of the UnrealEngine3 tree.

.PARAMETER ProjectDir
  The project folder, CustomMaps\<Name>, holding Cook.bat and Map.ini.
#>
param(
    [Parameter(Mandatory = $true)] [string] $Name,
    [Parameter(Mandatory = $true)] [string] $EngineRoot,
    [Parameter(Mandatory = $true)] [string] $ProjectDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UPackage.ps1')

function Fail([string] $Text)
{
    Write-Host ""
    Write-Host $Text -ForegroundColor Red
    exit 1
}

# "16.7 MB" or "897 KB", so small sublevels do not show as 0.0 MB.
function Format-Size([long] $Bytes)
{
    $text = "{0:N0} KB" -f [Math]::Ceiling($Bytes / 1KB)
    if ($Bytes -ge 1MB)
    {
        $text = "{0:N1} MB" -f ($Bytes / 1MB)
    }
    return $text
}

# Reads the settings from Map.ini; anything else in the file is ignored.
function Read-MapSettings([string] $Path)
{
    $settings = @{ Name = ''; Author = ''; Version = ''; Menu = ''; Start = ''; Checkpoints = ''; Output = ''; Maps = ''; AllowRetailNames = '' }
    if (Test-Path -LiteralPath $Path)
    {
        foreach ($line in Get-Content -LiteralPath $Path)
        {
            if ($line -match '^\s*(Name|Author|Version|Menu|Start|Checkpoints|Output|Maps|AllowRetailNames)\s*=\s*(.*?)\s*$')
            {
                $settings[$Matches[1]] = $Matches[2]
            }
        }
    }
    return $settings
}


# The keys in a language file, each with its section and the line as written, so quoting survives the copy.
function Read-LocFile([string] $Path)
{
    $section = ''
    foreach ($line in [IO.File]::ReadAllLines($Path))
    {
        if ($line -match '^\s*\[(.+)\]\s*$')
        {
            $section = $Matches[1]
        }
        elseif ($section -and $line -match '^\s*([^;\s][^=]*?)\s*=')
        {
            [pscustomobject] @{ Section = $section; Key = $Matches[1]; Line = $line }
        }
    }
}

# Whether a map names this key: a tutorial, objective, prompt, item or checkpoint location, or a document as
# <Name> and <Name>_Title. The engine stores a trailing _<number> apart from the name, so Note_2 is listed as Note.
function Test-KeyUsed([string] $Key, $Names)
{
    $base = $Key -replace '_Title$', ''
    $used = $Names.Contains($Key) -or $Names.Contains($base)
    if (-not $used -and $base -match '^(.+)_(0|[1-9]\d*)$')
    {
        $used = $Names.Contains($Matches[1])
    }
    return $used
}

# The text the maps need that retail lacks, one entry per language file. A file named like one of retail's (OLGame.int
# and so on) gives only the keys retail does not have, so the game's own text is never replaced. A shared folder gives
# only keys the maps name, and its other files only when named after a shipped package.
function Find-MapText($Sources, [string] $RetailDir, $Names, $Packages)
{
    $found = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $retailKeys = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $taken = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($source in $Sources)
    {
        $langDirs = @()
        if (Test-Path -LiteralPath $source.Dir)
        {
            $langDirs = @(Get-ChildItem -LiteralPath $source.Dir -Directory)
        }

        foreach ($langDir in $langDirs)
        {
            foreach ($file in Get-ChildItem -LiteralPath $langDir.FullName -File | Where-Object { $_.Extension -eq ".$($langDir.Name)" })
            {
                $relative = "$($langDir.Name)\$($file.Name)"
                $retailFile = Join-Path $RetailDir $relative
                if (Test-Path -LiteralPath $retailFile)
                {
                    if (-not $retailKeys.ContainsKey($relative))
                    {
                        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                        foreach ($entry in @(Read-LocFile $retailFile))
                        {
                            [void] $set.Add("$($entry.Section)`n$($entry.Key)")
                        }
                        $retailKeys[$relative] = $set
                    }

                    foreach ($entry in @(Read-LocFile $file.FullName))
                    {
                        $id = "$relative`n$($entry.Section)`n$($entry.Key)"
                        $wanted = -not $retailKeys[$relative].Contains("$($entry.Section)`n$($entry.Key)") -and -not $taken.Contains($id)
                        if ($wanted -and $source.Shared)
                        {
                            $wanted = Test-KeyUsed $entry.Key $Names
                        }

                        if ($wanted)
                        {
                            [void] $taken.Add($id)
                            if (-not $found.ContainsKey($relative))
                            {
                                $found[$relative] = [pscustomobject] @{ Relative = $relative; Whole = $null; Entries = (New-Object 'System.Collections.Generic.List[object]') }
                            }
                            $found[$relative].Entries.Add($entry)
                        }
                    }
                }
                elseif (-not $found.ContainsKey($relative) -and (-not $source.Shared -or $Packages -contains $file.BaseName))
                {
                    $found[$relative] = [pscustomobject] @{ Relative = $relative; Whole = $file; Entries = $null }
                }
            }
        }
    }

    return @($found.Values)
}

# Writes keys grouped under their sections, in UTF-16 like retail's own language files, with a blank line after each section as the engine lays out its files.
function Write-LocFile([string] $Path, $Entries)
{
    $sections = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $Entries)
    {
        if (-not ($sections -contains $entry.Section))
        {
            $sections.Add($entry.Section)
        }
    }

    $text = ''
    foreach ($section in $sections)
    {
        $text += "[$section]`r`n"
        foreach ($entry in $Entries | Where-Object { $_.Section -eq $section })
        {
            $text += "$($entry.Line)`r`n"
        }
        $text += "`r`n"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $text, [Text.Encoding]::Unicode)
}

$EngineRoot = (Resolve-Path -LiteralPath $EngineRoot).Path
$ProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
$com = Join-Path $EngineRoot 'Binaries\Win64\OLGame.com'
$contentDir = Join-Path $EngineRoot "OLGame\Content\CustomMaps\$Name"
$cookedDir = Join-Path $EngineRoot 'OLGame\CookedPCConsoleDLC'
$settings = Read-MapSettings (Join-Path $ProjectDir 'Map.ini')

# A total conversion can mean to replace retail's own files, such as its menu or checkpoint level.
$allowRetailNames = $settings.AllowRetailNames -match '^(true|yes|1)$'

# The game is needed for retail's cooker data and text. Find-Outlast throws when it finds nothing.
$game = $null
try
{
    $game = & (Join-Path $PSScriptRoot 'Find-Outlast.ps1')
}
catch
{
    $game = $null
}

if (-not (Test-Path -LiteralPath $com))
{
    Fail "The engine was not found at $EngineRoot. This project has to stay in CustomMaps\$Name inside the engine tree."
}

# The cook saves a package called GuidCache_<Name>, and the engine refuses package names over 30 characters.
if ($Name.Length -gt 20)
{
    Fail "The project name $Name is $($Name.Length) characters long and can be at most 20, since the cook saves a file called GuidCache_$Name and the engine refuses names over 30. Make a project with a shorter name using MakeMap.bat, then move your maps and Map.ini settings into it."
}

# The output folder is settled before cooking, so a bad setting fails in seconds rather than after a cook.
$cleanFirst = $false
$outputNote = ''
if (-not $settings.Output -or $settings.Output -eq 'Game')
{
    # Cooking never installs into the game, the same as building a mod; copying the folder over is yours.
    if ($settings.Output -eq 'Game')
    {
        $outputNote = "Output=Game no longer installs into the game, so this cooks into Output\$Name. Copy that into Outlast\OLGame\Mods\_Maps to play it."
    }
    $outDir = Join-Path $ProjectDir "Output\$Name"
    $cleanFirst = $true
}
elseif ([IO.Path]::IsPathRooted($settings.Output))
{
    $outDir = $settings.Output
}
else
{
    $outDir = Join-Path $ProjectDir $settings.Output
}
$outDir = [IO.Path]::GetFullPath($outDir)

# The SDK reads the map's own Localization folder after the game's, key by key, so its text adds to the game's.
$locRoot = Join-Path $outDir 'Localization'

# Cooked copies under Content would clash with the source maps every time the editor starts.
if ($outDir.StartsWith((Join-Path $EngineRoot 'OLGame\Content'), [StringComparison]::OrdinalIgnoreCase))
{
    Fail "The output folder $outDir is inside OLGame\Content, where the editor would find the cooked copies and clash with your maps. Pick another folder in Map.ini."
}

Write-Host "Project: $Name"
Write-Host "Maps:    OLGame\Content\CustomMaps\$Name"
Write-Host "Output:  $outDir"
if ($game)
{
    Write-Host "Outlast: $game"
}
if ($outputNote)
{
    Write-Host $outputNote -ForegroundColor Yellow
}
Write-Host ""

# --- 1. Maps ---------------------------------------------------------------------------------------

Write-Host "[1/5] Finding your maps"

$maps = @()
$udks = @()
if ($settings.Maps)
{
    # Names may be typed as MyMap.udk or with a folder; the cooked file is just MyMap.upk, so keep the bare name.
    $maps = @($settings.Maps -split ',' | ForEach-Object { [IO.Path]::GetFileName($_.Trim()) -replace '\.(udk|upk)$', '' } | Where-Object { $_ })
    Write-Host "  From Map.ini: $($maps -join ', ')"
}
else
{
    $udks = @()
    if (Test-Path -LiteralPath $contentDir)
    {
        $udks = @(Get-ChildItem -LiteralPath $contentDir -Filter *.udk -Recurse)
    }

    if ($udks.Count -eq 0)
    {
        Fail "No maps in OLGame\Content\CustomMaps\$Name. Save your maps there, or list them under Maps= in Map.ini."
    }

    $maps = @(Get-PersistentMaps $udks | ForEach-Object { $_.BaseName })
    if ($maps.Count -eq 0)
    {
        Fail "Every map in OLGame\Content\CustomMaps\$Name looks like a sublevel of another. List the maps to cook under Maps= in Map.ini."
    }

    $sublevels = @($udks | Where-Object { $maps -notcontains $_.BaseName } | ForEach-Object { $_.BaseName })
    Write-Host "  Cooking: $($maps -join ', ')"
    if ($sublevels.Count -gt 0)
    {
        Write-Host "  Sublevels, cooked with their map: $($sublevels -join ', ')" -ForegroundColor DarkGray
    }
}

# A map named like a retail package would replace the game's own file. Sublevels kept outside the
# project folder are only known after the cook, so they are checked again then.
$retailNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$retailNames.UnionWith([string[]] @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'RetailPackages.txt') | Where-Object { $_ -and -not $_.StartsWith('#') }))
$known = @($maps)
if ($udks)
{
    $known += @($udks | ForEach-Object { $_.BaseName })
}
# The same limit holds for every map. The editor will not save a longer name, but a file can be renamed by hand.
$long = @($known | Where-Object { $_.Length -gt 30 } | Sort-Object -Unique)
if ($long.Count -gt 0)
{
    Fail ("These map names are over 30 characters, which the engine refuses to cook: " + ($long -join ', ') + ". Rename them in the editor (File, Save As), then cook again.")
}

$early = @($known | Where-Object { $retailNames.Contains($_) } | Sort-Object -Unique)
if ($early.Count -gt 0)
{
    if ($allowRetailNames)
    {
        Write-Host ("  Warning: " + ($early -join ', ') + " will replace retail Outlast's own files. AllowRetailNames is on in Map.ini, so cooking anyway.") -ForegroundColor Yellow
    }
    else
    {
        Fail ("Retail Outlast already has packages called " + ($early -join ', ') + ", so cooking these would replace the game's own files. Rename those maps in the editor (File, Save As), then cook again. If this project is meant to replace them, set AllowRetailNames=True in Map.ini.")
    }
}
Write-Host ""

# --- 2. Retail cooker data -------------------------------------------------------------------------

# The cooker shares textures with retail's own texture caches only when it cooks against retail's cooker data.
Write-Host "[2/5] Retail cooker data"

$treeData = Join-Path $EngineRoot 'OLGame\CookedPCConsole\GlobalPersistentCookerData.upk'
if ($game)
{
    $retailData = Join-Path $game 'OLGame\CookedPCConsole\GlobalPersistentCookerData.upk'
    if (-not (Test-Path -LiteralPath $retailData))
    {
        Fail "Your Outlast install has no OLGame\CookedPCConsole\GlobalPersistentCookerData.upk. Verify the game files, then cook again."
    }

    $same = (Test-Path -LiteralPath $treeData) -and ((Get-FileHash -LiteralPath $treeData).Hash -eq (Get-FileHash -LiteralPath $retailData).Hash)
    if ($same)
    {
        Write-Host "  Already in place."
    }
    else
    {
        New-Item -ItemType Directory -Force -Path (Split-Path $treeData) | Out-Null
        if (Test-Path -LiteralPath $treeData)
        {
            Copy-Item -LiteralPath $treeData -Destination "$treeData.bak" -Force
            Write-Host "  Kept the previous copy as GlobalPersistentCookerData.upk.bak"
        }
        Copy-Item -LiteralPath $retailData -Destination $treeData -Force
        Write-Host "  Copied from your Outlast install."
    }
}
elseif (Test-Path -LiteralPath $treeData)
{
    Write-Host "  Outlast was not found, so using the copy already in the engine. Set OUTLAST_DIR if it is out of date." -ForegroundColor Yellow
}
else
{
    Fail "Outlast was not found, and the cook needs its cooker data. Set it once with:  setx OUTLAST_DIR `"C:\path\to\Outlast`"  then open a new window."
}
Write-Host ""

# --- 3. Cook ---------------------------------------------------------------------------------------

Write-Host "[3/5] Cooking"

$logName = "Cook_$Name.log"
$cookStart = (Get-Date).AddSeconds(-5)

# Arguments go over as an array; PowerShell would split a typed -LOG=Cook_X.log at the dot.
$cookArgs = @('CookPackages', '-platform=PCConsole', "-DLCName=$Name", '-SaveAsRetail', '-full') + $maps + @('-CookShadersIntoMapsForPCConsole', '-unattended', "-LOG=$logName")

# A full cook first clears the previous one out of CookedPCConsoleDLC, one line per file. Fold those into one line.
$cleared = 0
& $com @cookArgs | ForEach-Object {
    if ("$_".StartsWith('Deleting: '))
    {
        $cleared++
    }
    else
    {
        if ($cleared -gt 0)
        {
            Write-Host "Cleared $cleared files left from the previous cook."
            $cleared = 0
        }
        Write-Host $_
    }
}
$cookResult = $LASTEXITCODE

$log = Join-Path $EngineRoot "OLGame\Logs\$logName"
$patched = (Test-Path -LiteralPath $log) -and (Select-String -LiteralPath $log -Pattern 'Outlast Retail Package Patch: installed' -SimpleMatch -Quiet)
if (-not $patched)
{
    Fail "The Retail Package Patch is not built into this engine, so the cook cannot target retail Outlast. Install the patch, rebuild the engine, then cook again."
}
if ($cookResult -ne 0)
{
    Fail "The cook failed. The errors are above, and the full log is OLGame\Logs\$logName."
}
Write-Host ""

# --- 4. Pick the files the maps use ----------------------------------------------------------------

Write-Host "[4/5] Picking the files your maps use"

$usedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$importedPackages = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$classPackages = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$ship = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
$queued = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

# Each map, then the sublevels its own header says it pulls in, remembering which map pulls in each.
$packages = New-Object 'System.Collections.Generic.List[string]'
$ownerMap = @{}
foreach ($map in $maps)
{
    $file = Get-ChildItem -LiteralPath $cookedDir -Filter "$map.upk" | Select-Object -First 1
    if (-not $file -or $file.LastWriteTime -lt $cookStart)
    {
        Fail "$map was not cooked. Check the name matches a map in OLGame\Content, then see OLGame\Logs\$logName."
    }

    foreach ($package in @($map) + @((Read-UPackage $file.FullName).AdditionalPackagesToCook))
    {
        if ($queued.Add($package))
        {
            $packages.Add($package)
            $ownerMap[$package] = $map
        }
    }
}

foreach ($package in $packages)
{
    $file = Get-ChildItem -LiteralPath $cookedDir -Filter "$package.upk" | Select-Object -First 1
    if (-not $file -or $file.LastWriteTime -lt $cookStart)
    {
        Fail "$package was not cooked, though a map streams it. See OLGame\Logs\$logName."
    }

    $info = Read-UPackage $file.FullName -Names -Imports
    if ($info.Version -ne 868 -and $info.Version -ne 867)
    {
        Fail "$($file.Name) is stamped $($info.Version) / $($info.Licensee), not retail format. Check the Retail Package Patch is built into this engine."
    }

    $usedNames.UnionWith([string[]] $info.Names)
    $importedPackages.UnionWith([string[]] $info.ImportedPackages)
    $classPackages.UnionWith([string[]] $info.ClassPackages)
    $ship.Add($file)

    # Localised text for a map comes out as <Map>_LOC_<language>.upk.
    foreach ($loc in Get-ChildItem -LiteralPath $cookedDir -Filter "$($file.BaseName)_LOC_*.upk")
    {
        if ($loc.LastWriteTime -ge $cookStart)
        {
            $ship.Add($loc)
        }
    }
}

# A texture cache ships only when a shipped package names it. The cooker also fills caches for
# textures nothing ends up using, such as ones only reached through cooked-out material paths.
$unused = @()
foreach ($tfc in Get-ChildItem -LiteralPath $cookedDir -Filter "*_$Name.tfc")
{
    if ($tfc.LastWriteTime -ge $cookStart)
    {
        if ($usedNames.Contains($tfc.BaseName))
        {
            $ship.Add($tfc)
        }
        else
        {
            $unused += $tfc
        }
    }
}

# Classes are never copied into a cooked map, so a map using a class from a mod's script package keeps an
# import of it, and that .u has to ship alongside. Content the maps use is already inside them.
# Any reference to a mod counts, since Kismet and actor factories name classes through properties too.
$scripts = @(Find-CustomScriptPackages -Imports ([string[]] $importedPackages) -EngineRoot $EngineRoot -RetailNames $retailNames -ModPackages (Get-ModPackages $EngineRoot))
$scriptNotes = @()
$scriptProblems = @()
foreach ($script in $scripts)
{
    $why = ""
    if ($script.Via)
    {
        $why = " (needed by $($script.Via))"
    }

    if ($script.Kind -eq 'Engine')
    {
        # Editor-only leftovers such as group actors keep a dangling reference, so only warn when an object
        # in the maps really is one of this package's classes.
        if (-not $script.Via -and $classPackages.Contains($script.Name))
        {
            $scriptNotes += "Warning: your maps use classes from $($script.Name), an engine package retail Outlast does not have, so those objects will not load there."
        }
    }
    elseif ($script.Name -eq 'OutlastSDK')
    {
        $scriptNotes += "Uses OutlastSDK.u$why, which the OutlastSDK supplies, so it is not copied."
    }
    elseif (-not $script.Path)
    {
        $scriptProblems += "$($script.Name).u$why has not been compiled. Run CompileRetail.bat in Development\Src\$($script.Name), then cook again."
    }
    elseif ($script.Version -ne 868 -and $script.Version -ne 867)
    {
        $scriptProblems += "$($script.Name).u$why is in this engine's own format ($($script.Version) / $($script.Licensee)), so retail Outlast cannot load it. Run CompileRetail.bat in Development\Src\$($script.Name), then cook again."
    }
    else
    {
        $ship.Add((Get-Item -LiteralPath $script.Path))
        if ($script.Stale)
        {
            $scriptNotes += "Warning: $($script.Stale) changed after $($script.Name).u was built, so the copy shipped may be out of date. Run CompileRetail.bat in Development\Src\$($script.Name) to include it."
        }
        if ($script.Sources -and (Test-Path -LiteralPath (Join-Path $script.Sources 'Config')))
        {
            $scriptNotes += "$($script.Name) also has Config files. Deploy.bat in Development\Src\$($script.Name) packages those; ship them with your maps."
        }
    }
}

if ($scriptProblems.Count -gt 0)
{
    Fail ("Your maps use classes from script packages that cannot ship yet:`n  " + ($scriptProblems -join "`n  "))
}

# Text comes from this project's Localization folder, then the script packages that ship, then the engine's own
# folder, which every project shares and the editor shows.
$mapText = @()
if ($game)
{
    $textSources = @([pscustomobject] @{ Dir = (Join-Path $ProjectDir 'Localization'); Shared = $false })
    foreach ($script in $scripts)
    {
        if ($script.Kind -eq 'Mod' -and $script.Name -ne 'OutlastSDK' -and $script.Sources)
        {
            $textSources += [pscustomobject] @{ Dir = (Join-Path $script.Sources 'Localization'); Shared = $false }
        }
    }
    $textSources += [pscustomobject] @{ Dir = (Join-Path $EngineRoot 'OLGame\Localization'); Shared = $true }

    $mapText = @(Find-MapText $textSources (Join-Path $game 'OLGame\Localization') $usedNames @($ship | ForEach-Object { $_.BaseName }))
}
else
{
    $scriptNotes += "Warning: Outlast was not found, so your maps' text was not checked against retail's. Set OUTLAST_DIR to include it."
}

# A shipped file named like a retail one would replace the game's own copy.
$clashes = @($ship | Where-Object { $retailNames.Contains($_.BaseName) } | ForEach-Object { $_.BaseName })
if ($clashes.Count -gt 0)
{
    if ($allowRetailNames)
    {
        Write-Host ("  Warning: shipping " + ($clashes -join ', ') + ", which will replace retail Outlast's own files. AllowRetailNames is on in Map.ini.") -ForegroundColor Yellow
    }
    else
    {
        Fail ("Retail Outlast already has packages called " + ($clashes -join ', ') + ", so these would replace the game's own files. Rename those maps in the editor, or rename the project if the clash is a texture cache. If this project is meant to replace them, set AllowRetailNames=True in Map.ini.")
    }
}

# Map.ini's levels and start checkpoint have to be among what was cooked, or the SDK would look for
# things that are not there and the game would stall on the menu.
$cookedLevels = @($ship | Where-Object { $_.Extension -eq '.upk' } | ForEach-Object { $_.BaseName })
$settingProblems = @()
foreach ($key in 'Menu', 'Checkpoints')
{
    $level = $settings[$key]
    if ($level -and $cookedLevels -notcontains $level)
    {
        $settingProblems += "$key=$level is not one of the cooked maps ($($cookedLevels -join ', ')). Check the name, or add the map to Maps=."
    }
}

# Every checkpoint the cooked maps hold, with the level it is in and the persistent map it names,
# and what each level's checkpoint list names.
$checkpoints = @()
$listOrder = @()
$lists = @{}
foreach ($level in @($ship | Where-Object { $_.Extension -eq '.upk' }))
{
    $found = Read-Checkpoints $level.FullName
    foreach ($cp in $found.Checkpoints)
    {
        $checkpoints += [pscustomobject] @{ Name = $cp.Name; PersistentLevel = $cp.PersistentLevel; Level = $level.BaseName }
    }
    if ($found.ListOrder.Count -gt 0)
    {
        $lists[$level.BaseName] = @($found.ListOrder)
    }
    if ($listOrder.Count -eq 0)
    {
        $listOrder = @($found.ListOrder)
    }
}

# New Game starts at Start, or when Map.ini leaves it empty, at the first checkpoint: the first one a
# checkpoint list names, else the first one in the maps.
$start = $settings.Start
$startHow = 'set in Map.ini'
if (-not $start -and $listOrder.Count -gt 0)
{
    $start = $listOrder[0]
    $startHow = 'the first in your checkpoint list'
}
elseif (-not $start -and $checkpoints.Count -gt 0)
{
    $start = $checkpoints[0].Name
    $startHow = 'the first checkpoint in your maps'
}
$startCp = $checkpoints | Where-Object { $_.Name -eq $start } | Select-Object -First 1

# A start that names a persistent map is in a checkpoint level, which the SDK streams into the game's menu.
# One that names none is inside the map it starts, which the SDK opens at that checkpoint instead.
$checkpointLevel = $settings.Checkpoints
$startMap = ''
if ($startCp -and $startCp.PersistentLevel -and -not $checkpointLevel)
{
    $checkpointLevel = $startCp.Level
}
elseif ($startCp -and -not $startCp.PersistentLevel -and -not $checkpointLevel)
{
    $startMap = $ownerMap[$startCp.Level]
}

if ($start -and -not $startCp)
{
    $settingProblems += "Start=$start is not a checkpoint in the cooked maps. Their checkpoints: $(($checkpoints | ForEach-Object { $_.Name }) -join ', ')."
}
if ($startCp -and $settings.Checkpoints -and $startCp.Level -ne $settings.Checkpoints)
{
    $settingProblems += "Start=$start is in $($startCp.Level), not in Checkpoints=$($settings.Checkpoints), so the menu could not find it."
}
if ($startCp -and $settings.Checkpoints -and -not $startCp.PersistentLevel)
{
    $settingProblems += "Start=$start names no persistent map, so New Game from Checkpoints=$($settings.Checkpoints) would have nowhere to go. Set PersistentLevelName on that checkpoint."
}
if ($settingProblems.Count -gt 0)
{
    Fail ("Map.ini names things this cook did not make:`n  " + ($settingProblems -join "`n  "))
}

if ($startMap)
{
    $scriptNotes += "New Game streams $startMap in and starts at $start ($startHow)."
}
elseif (-not $start -and -not $settings.Menu)
{
    $scriptNotes += "Warning: your maps hold no OLCheckpoint, so New Game still starts the base game while this map is active."
}

# The game lists a save in Continue and Load only when a checkpoint list on the menu names its checkpoint.
# Without a checkpoint level, nothing names them, so a map without one cannot be continued.
if ($start -and -not $checkpointLevel -and -not $settings.Menu)
{
    $scriptNotes += "Warning: no checkpoint level, so Continue and Load will not list this map's saves. Put your checkpoints and an OLCheckpointList in a level of their own, like the game's X_Checkpoints, with PersistentLevelName set on each."
}
elseif ($checkpointLevel -and -not $lists.ContainsKey($checkpointLevel))
{
    $scriptNotes += "Warning: $checkpointLevel holds no OLCheckpointList, so Continue and Load will not list this map's saves."
}
elseif ($checkpointLevel)
{
    $unlisted = @($checkpoints | Where-Object { $_.Level -eq $checkpointLevel -and $lists[$checkpointLevel] -notcontains $_.Name } | ForEach-Object { $_.Name })
    if ($unlisted.Count -gt 0)
    {
        $scriptNotes += "Saves at $($unlisted -join ', ') are not listed in Continue or Load, since $checkpointLevel's checkpoint list leaves them out."
    }
}

foreach ($file in $ship)
{
    $label = ""
    if ($file.Extension -eq '.u')
    {
        $label = "  script package your maps use"
        $entry = $scripts | Where-Object { $_.Name -eq $file.BaseName -and $_.Via } | Select-Object -First 1
        if ($entry)
        {
            $label = "  script package $($entry.Via) needs"
        }
    }
    Write-Host ("  {0,-40} {1,10}{2}" -f $file.Name, (Format-Size $file.Length), $label)
}
foreach ($text in $mapText)
{
    if ($text.Whole)
    {
        Write-Host ("  {0,-40} {1,10}  text" -f "Localization\$($text.Relative)", (Format-Size $text.Whole.Length))
    }
    else
    {
        $keyWord = 'keys'
        if ($text.Entries.Count -eq 1)
        {
            $keyWord = 'key'
        }
        Write-Host ("  {0,-40} {1,10}  text retail lacks" -f "Localization\$($text.Relative)", "$($text.Entries.Count) $keyWord")
    }
}
foreach ($note in $scriptNotes)
{
    $colour = 'Yellow'
    if ($note.StartsWith('Uses OutlastSDK'))
    {
        $colour = 'DarkGray'
    }
    Write-Host "  $note" -ForegroundColor $colour
}
foreach ($tfc in $unused)
{
    Write-Host ("  {0,-40} left out: no map uses it" -f $tfc.Name) -ForegroundColor DarkGray
}
$leftOut = @(Get-ChildItem -LiteralPath $cookedDir -File -Recurse | Where-Object { $_.LastWriteTime -ge $cookStart } | Where-Object { $ship.FullName -notcontains $_.FullName -and $unused.FullName -notcontains $_.FullName }).Count
Write-Host "  Left out $leftOut other files from this cook: cooker data and shader caches retail does not need." -ForegroundColor DarkGray
Write-Host "  Wwise banks are left out too, since retail already has them." -ForegroundColor DarkGray
Write-Host ""

# --- 5. Copy to the output folder ------------------------------------------------------------------

Write-Host "[5/5] Copying to the output folder"

if ($cleanFirst -and (Test-Path -LiteralPath $outDir))
{
    Remove-Item -LiteralPath $outDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# What this project wrote last time, so its leftovers can be removed and another project's text left alone.
$record = Join-Path $ProjectDir 'LastOutput.txt'
$previous = @()
if (Test-Path -LiteralPath $record)
{
    $previous = @(Get-Content -LiteralPath $record | Where-Object { $_ })
}

# A text file already there that this project did not write belongs to another project, so it is not replaced.
$texts = @()
foreach ($text in $mapText)
{
    $dest = Join-Path $locRoot $text.Relative
    if ((Test-Path -LiteralPath $dest) -and $previous -notcontains $dest)
    {
        Write-Host "  Left $dest as it is: another project's text is already there. Merge yours into it by hand, or delete it and cook again." -ForegroundColor Yellow
    }
    else
    {
        $texts += [pscustomobject] @{ Text = $text; Dest = $dest }
    }
}

# Files this project copied last time that this cook no longer makes, so a renamed map does not linger.
if (-not $cleanFirst)
{
    $keep = @($ship | ForEach-Object { Join-Path $outDir $_.Name }) + @($texts | ForEach-Object { $_.Dest })
    $removed = 0
    foreach ($old in $previous)
    {
        $ours = ((Split-Path $old) -eq $outDir) -or $old.StartsWith("$locRoot\", [StringComparison]::OrdinalIgnoreCase)
        if ($ours -and $keep -notcontains $old -and (Test-Path -LiteralPath $old))
        {
            Remove-Item -LiteralPath $old -Force
            $removed++
        }
    }

    if ($removed -eq 1)
    {
        Write-Host "  Removed 1 file from the last cook that this one no longer makes."
    }
    elseif ($removed -gt 1)
    {
        Write-Host "  Removed $removed files from the last cook that this one no longer makes."
    }
}

$written = @()
foreach ($file in $ship)
{
    $dest = Join-Path $outDir $file.Name
    Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
    $written += $dest
}
foreach ($text in $texts)
{
    if ($text.Text.Whole)
    {
        New-Item -ItemType Directory -Force -Path (Split-Path $text.Dest) | Out-Null
        Copy-Item -LiteralPath $text.Text.Whole.FullName -Destination $text.Dest -Force
    }
    else
    {
        Write-LocFile $text.Dest $text.Text.Entries
    }
    $written += $text.Dest
}

# What the SDK reads to know this map. UTF-16, so a name or author outside plain English survives, ending in a blank line as the engine writes its inis.
$shownName = $settings.Name
if (-not $shownName)
{
    $shownName = $Name
}
$info = @('[Map]', "Name=$shownName", "Author=$($settings.Author)", "Version=$($settings.Version)",
          "Menu=$($settings.Menu)", "Start=$start", "Checkpoints=$checkpointLevel", "StartMap=$startMap")
$infoPath = Join-Path $outDir 'map.ini'
[IO.File]::WriteAllText($infoPath, ($info -join "`r`n") + "`r`n`r`n", [Text.Encoding]::Unicode)
$written += $infoPath

# The picture the Mods menu shows beside the map: the first Thumbnail image next to Map.ini.
$thumbnail = Get-ChildItem -LiteralPath $ProjectDir -File |
    Where-Object { $_.BaseName -eq 'Thumbnail' -and $_.Extension -in '.png', '.jpg', '.jpeg', '.bmp' } |
    Select-Object -First 1
if ($thumbnail)
{
    $thumbPath = Join-Path $outDir $thumbnail.Name
    Copy-Item -LiteralPath $thumbnail.FullName -Destination $thumbPath -Force
    $written += $thumbPath
}

[IO.File]::WriteAllText($record, ($written -join "`r`n"))

$total = ($ship | Measure-Object -Property Length -Sum).Sum
$fileWord = 'files'
if ($ship.Count -eq 1)
{
    $fileWord = 'file'
}
Write-Host ("  {0} {1}, {2}, in {3}" -f $ship.Count, $fileWord, (Format-Size $total), $outDir)
if ($texts.Count -gt 0)
{
    Write-Host "  Text in $locRoot"
}
Write-Host "  map.ini: $shownName, $(if ($settings.Menu) { "its own menu ($($settings.Menu))" } else { "the game's menu" })$(if ($start) { ", New Game at $start" })"
if ($thumbnail)
{
    Write-Host "  Thumbnail: $($thumbnail.Name)"
}
else
{
    Write-Host "  No thumbnail. Put a Thumbnail.png or Thumbnail.jpg next to Map.ini to show one in the Mods menu." -ForegroundColor DarkGray
}
Write-Host "  To play it, copy this folder into Outlast\OLGame\Mods\_Maps, then load the map from the Maps tab of the Mods menu." -ForegroundColor DarkGray
exit 0