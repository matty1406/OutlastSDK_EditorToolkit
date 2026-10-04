<#
.SYNOPSIS
  Register a script package with the make commandlet.

.DESCRIPTION
  Adds "+ModEditPackages=<Package>" under [UnrealEd.EditorEngine]. UMakeCommandlet
  reads that key and appends it to EditPackages, so registered packages compile
  after OLGame and can subclass it.

  Written to BOTH DefaultEngine.ini and the generated OLEngine.ini: make reads the
  generated one at runtime, while the Default is what survives a regeneration. The
  '+' prefix is AddUnique, so listing it twice is not a double registration.

  Packages compile in the order they are registered, so register a dependency
  (OutlastSDK) before anything that uses it.

  Idempotent - a package that is already listed is left alone.

.PARAMETER EngineRoot
  Root of the UnrealEngine3 tree.

.PARAMETER Package
  One or more package names, registered in the order given.

.EXAMPLE
  .\Register-Package.ps1 -EngineRoot C:\...\UnrealEngine3 -Package OutlastSDK,MyMod
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $EngineRoot,

    [Parameter(Mandatory = $true)]
    [string[]] $Package
)

$ErrorActionPreference = 'Stop'

function Add-ModEditPackage
{
    param(
        [string] $IniPath,
        [string] $Name
    )

    if (-not (Test-Path $IniPath)) {
        Write-Host "  skipped  $(Split-Path $IniPath -Leaf) (not found)"
        return
    }

    $Lines   = @(Get-Content $IniPath -Encoding ASCII)
    $NewLine = "+ModEditPackages=$Name"

    # Match the plus-less form too. The engine regenerates OLEngine.ini from the
    # Default and writes the key as "ModEditPackages=X", so checking only for the
    # '+' form would add a duplicate every time the ini was rebuilt.
    if (($Lines | Where-Object { $_.Trim() -match "^\+?ModEditPackages\s*=\s*$([regex]::Escape($Name))$" })) {
        Write-Host "  ok       $(Split-Path $IniPath -Leaf) already lists $Name"
        return
    }

    $SectionStart = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq '[UnrealEd.EditorEngine]') {
            $SectionStart = $i
            break
        }
    }

    if ($SectionStart -lt 0) {
        throw "No [UnrealEd.EditorEngine] section in $IniPath - cannot register $Name."
    }

    # Walk to the end of the section (next section header, or end of file).
    $InsertAt = $Lines.Count
    for ($i = $SectionStart + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].TrimStart().StartsWith('[')) {
            $InsertAt = $i
            break
        }
    }

    # Back up over trailing blank lines so the new key sits with its section.
    while ($InsertAt -gt $SectionStart + 1 -and $Lines[$InsertAt - 1].Trim() -eq '') {
        $InsertAt--
    }

    $Updated = @()
    $Updated += $Lines[0..($InsertAt - 1)]
    $Updated += $NewLine
    if ($InsertAt -lt $Lines.Count) {
        $Updated += $Lines[$InsertAt..($Lines.Count - 1)]
    }

    Set-Content -Path $IniPath -Value $Updated -Encoding ASCII
    Write-Host "  updated  $(Split-Path $IniPath -Leaf) (+ModEditPackages=$Name)"
}

foreach ($Name in $Package) {
    Add-ModEditPackage -IniPath (Join-Path $EngineRoot "OLGame\Config\DefaultEngine.ini") -Name $Name
    Add-ModEditPackage -IniPath (Join-Path $EngineRoot "OLGame\Config\OLEngine.ini")      -Name $Name
}