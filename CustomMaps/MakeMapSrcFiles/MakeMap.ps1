<#
.SYNOPSIS
  Creates a map project: a folder for your maps in Content, and a folder with Cook.bat and its settings.

.PARAMETER MapName
  The project name. It names both folders and the texture caches the cook writes, such as Textures_<MapName>.tfc. Letters, digits and underscores; anything else is turned into PascalCase. Defaults to $env:MapName, which is how MakeMap.bat passes it.

.PARAMETER EngineRoot
  Root of the UnrealEngine3 tree. Defaults to the parent of MakeMapSrcFiles.
#>
[CmdletBinding()]
param(
    [string] $MapName = $env:MapName,

    [string] $EngineRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "ModNames.ps1")

$typed = "$MapName".Trim()
$name = ConvertTo-ModName $typed

# The engine reads a trailing _<number> in a name as a separate number, which would break the texture cache names.
if ($name -match '_\d+$')
{
    $name = $name -replace '_(?=\d+$)', ''
}

if (-not $name)
{
    throw "'$typed' has no letters to make a project name from."
}
if ($name -cne $typed)
{
    Write-Host "  '$typed' is not a valid name, using '$name'"
}

if (-not (Test-Path (Join-Path $EngineRoot "Binaries\Win64\OLGame.com")))
{
    throw "Not an engine tree: $EngineRoot. Run the toolkit's Install.bat, then MakeMap.bat from the engine root."
}

# Retail ships Textures_dlc1.tfc and Textures_Patch.tfc, and the cook names its caches after the project.
$retail = Get-Content (Join-Path $PSScriptRoot "RetailPackages.txt") | Where-Object { $_ -and -not $_.StartsWith('#') }
if ($retail -contains "Textures_$name")
{
    throw "Retail Outlast already uses the name '$name' for its texture caches. Pick another name."
}

$projectDir = Join-Path $EngineRoot "CustomMaps\$name"
$contentDir = Join-Path $EngineRoot "OLGame\Content\CustomMaps\$name"
if ((Test-Path $projectDir) -or (Test-Path $contentDir))
{
    throw "This map project already exists: CustomMaps\$name"
}

New-Item -ItemType Directory -Force -Path $projectDir | Out-Null
New-Item -ItemType Directory -Force -Path $contentDir | Out-Null

$templates = @(
    @{ From = "Cook.bat.template"; To = "Cook.bat" },
    @{ From = "Map.ini.template";  To = "Map.ini"  }
)

foreach ($template in $templates)
{
    $body = (Get-Content (Join-Path $PSScriptRoot $template.From) -Raw) -replace '__MAPNAME__', $name

    # cmd misreads goto and call targets in LF-only batch files, so the .bat always gets CRLF.
    if ($template.To -like '*.bat')
    {
        $body = $body -replace '\r?\n', "`r`n"
    }

    Set-Content -Path (Join-Path $projectDir $template.To) -Value $body -Encoding ASCII -NoNewline
    Write-Host "  created  CustomMaps\$name\$($template.To)"
}
Write-Host "  created  OLGame\Content\CustomMaps\$name\"

Write-Host ""
Write-Host "$name is ready."
Write-Host ""
Write-Host "  Maps      Save your maps into OLGame\Content\CustomMaps\$name\"
Write-Host "  Cook      CustomMaps\$name\Cook.bat"
Write-Host "  Output    CustomMaps\$name\Output\$name\   (change it in CustomMaps\$name\Map.ini)"