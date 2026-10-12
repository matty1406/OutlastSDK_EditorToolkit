<#
.SYNOPSIS
  Prints where Outlast is installed. OUTLAST_DIR wins if set, otherwise Steam, Epic and GOG installs are found automatically.
#>

$ErrorActionPreference = 'Stop'

# A real install has the 64-bit game exe.
function Test-Outlast([string] $Path)
{
    return ($Path -and (Test-Path (Join-Path $Path 'Binaries\Win64\OLGame.exe')))
}

# Every Steam library on the machine, from the Steam install and its libraryfolders.vdf.
function Get-SteamCandidates
{
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')
    {
        $props = Get-ItemProperty $key -ErrorAction SilentlyContinue
        $steam = @($props.SteamPath, $props.InstallPath) | Where-Object { $_ } | Select-Object -First 1

        if ($steam)
        {
            $steam = $steam.Replace('/', '\')
            $libraries = @($steam)

            $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
            if (Test-Path $vdf)
            {
                $libraries += Select-String -Path $vdf -Pattern '"path"\s*"(.+?)"' | ForEach-Object { $_.Matches[0].Groups[1].Value.Replace('\\', '\') }
            }

            return ($libraries | ForEach-Object { Join-Path $_ 'steamapps\common\Outlast' })
        }
    }
}

# Epic writes one JSON manifest per installed game.
function Get-EpicCandidates
{
    $manifests = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'

    if (Test-Path $manifests)
    {
        foreach ($file in Get-ChildItem $manifests -Filter *.item)
        {
            try
            {
                $item = Get-Content $file.FullName -Raw | ConvertFrom-Json
                if ($item.DisplayName -eq 'Outlast')
                {
                    $item.InstallLocation
                }
            }
            catch
            {
                # A broken manifest belongs to some other game; skip it.
            }
        }
    }
}

# GOG Galaxy and the GOG installers record each game under GOG.com\Games.
function Get-GogCandidates
{
    foreach ($root in 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games', 'HKLM:\SOFTWARE\GOG.com\Games')
    {
        if (Test-Path $root)
        {
            foreach ($game in Get-ChildItem $root | ForEach-Object { Get-ItemProperty $_.PSPath })
            {
                if ($game.gameName -eq 'Outlast')
                {
                    $game.path
                }
            }
        }
    }
}

if ($env:OUTLAST_DIR -and -not (Test-Outlast $env:OUTLAST_DIR))
{
    Write-Warning "OUTLAST_DIR is set to '$env:OUTLAST_DIR', but that is not an Outlast install. Searching instead."
}

$candidates = @($env:OUTLAST_DIR) + @(Get-SteamCandidates) + @(Get-EpicCandidates) + @(Get-GogCandidates)
$found = $candidates | Where-Object { Test-Outlast $_ } | Select-Object -First 1

if (-not $found)
{
    throw "Could not find Outlast. Set it once with:  setx OUTLAST_DIR `"C:\path\to\Outlast`"  then open a new terminal."
}

return (Resolve-Path $found).Path