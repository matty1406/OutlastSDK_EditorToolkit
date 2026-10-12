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
    $settings = @{ Output = ''; Maps = ''; AllowRetailNames = '' }
    if (Test-Path -LiteralPath $Path)
    {
        foreach ($line in Get-Content -LiteralPath $Path)
        {
            if ($line -match '^\s*(Output|Maps|AllowRetailNames)\s*=\s*(.*?)\s*$')
            {
                $settings[$Matches[1]] = $Matches[2]
            }
        }
    }
    return $settings
}

$EngineRoot = (Resolve-Path -LiteralPath $EngineRoot).Path
$ProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
$com = Join-Path $EngineRoot 'Binaries\Win64\OLGame.com'
$contentDir = Join-Path $EngineRoot "OLGame\Content\CustomMaps\$Name"
$cookedDir = Join-Path $EngineRoot 'OLGame\CookedPCConsoleDLC'
$settings = Read-MapSettings (Join-Path $ProjectDir 'Map.ini')

# A total conversion can mean to replace retail's own files, such as its menu or checkpoint level.
$allowRetailNames = $settings.AllowRetailNames -match '^(true|yes|1)$'

# The game is needed for retail's cooker data and for Output=Game. Find-Outlast throws when it finds nothing.
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

# The output folder is settled before cooking, so a bad setting fails in seconds rather than after a cook.
$cleanFirst = $false
if (-not $settings.Output)
{
    $outDir = Join-Path $ProjectDir "Output\$Name"
    $cleanFirst = $true
}
elseif ($settings.Output -eq 'Game')
{
    if (-not $game)
    {
        Fail "Output=Game needs your Outlast install, which was not found. Set OUTLAST_DIR, or pick another folder in Map.ini."
    }
    $outDir = Join-Path $game 'OLGame\CookedPCConsole'
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
Write-Host ""

# --- 1. Maps ---------------------------------------------------------------------------------------

Write-Host "[1/5] Finding your maps"

$maps = @()
$udks = @()
if ($settings.Maps)
{
    $maps = @($settings.Maps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
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

# Each map, then the sublevels its own header says it pulls in.
$packages = New-Object 'System.Collections.Generic.List[string]'
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
        if ($script.Sources -and ((Test-Path -LiteralPath (Join-Path $script.Sources 'Config')) -or (Test-Path -LiteralPath (Join-Path $script.Sources 'Localization'))))
        {
            $scriptNotes += "$($script.Name) also has Config or Localization files. Deploy.bat in Development\Src\$($script.Name) packages those; ship them with your maps."
        }
    }
}

if ($scriptProblems.Count -gt 0)
{
    Fail ("Your maps use classes from script packages that cannot ship yet:`n  " + ($scriptProblems -join "`n  "))
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

# Files this project copied last time that this cook no longer makes, so a renamed map does not linger.
$record = Join-Path $ProjectDir 'LastOutput.txt'
if (-not $cleanFirst -and (Test-Path -LiteralPath $record))
{
    $removed = 0
    foreach ($old in Get-Content -LiteralPath $record)
    {
        $stillShipped = $ship | Where-Object { (Join-Path $outDir $_.Name) -eq $old }
        if ($old -and -not $stillShipped -and (Split-Path $old) -eq $outDir -and (Test-Path -LiteralPath $old))
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
[IO.File]::WriteAllText($record, ($written -join "`r`n"))

$total = ($ship | Measure-Object -Property Length -Sum).Sum
$fileWord = 'files'
if ($ship.Count -eq 1)
{
    $fileWord = 'file'
}
Write-Host ("  {0} {1}, {2}, in {3}" -f $ship.Count, $fileWord, (Format-Size $total), $outDir)
exit 0