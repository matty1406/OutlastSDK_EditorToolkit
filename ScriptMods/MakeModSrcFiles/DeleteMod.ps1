<#
.SYNOPSIS
  Delete a script mod made with MakeMod.bat, and everything MakeMod set up for it.

.DESCRIPTION
  Lists what it is about to remove and asks for the mod's name to confirm. Then:

    1. Sends Development\Src\<ModName> to the Recycle Bin. Done first, so a folder
       that is in use stops the delete before anything else has changed.
    2. Sends the built OLGame\Script\<ModName>.u to the Recycle Bin.
    3. Removes the ModEditPackages registration from both engine inis.

  OutlastSDK stays registered, since other mods compile against it.

.PARAMETER ModName
  The mod to delete. Defaults to $env:ModName, which is how DeleteMod.bat passes it.

.PARAMETER EngineRoot
  Root of the UnrealEngine3 tree. Defaults to the parent of MakeModSrcFiles.
#>
[CmdletBinding()]
param(
    [string] $ModName = $env:ModName,

    [string] $EngineRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = 'Stop'

# DeleteMod.bat passes "<root>\.", and the paths below read better plain.
$EngineRoot = [IO.Path]::GetFullPath($EngineRoot).TrimEnd('\')

Add-Type -AssemblyName Microsoft.VisualBasic

# --- Checks -------------------------------------------------------------------

$ModName = "$ModName".Trim()
if (-not $ModName)
{
    throw "No mod name given."
}

$SrcRoot = Join-Path $EngineRoot "Development\Src"
$ModDir  = Join-Path $SrcRoot $ModName

# Only folders MakeMod made, so an engine package such as Engine or OutlastSDK can
# never be deleted by mistake.
if (-not (Test-Path (Join-Path $ModDir "Compile.bat")))
{
    throw "No mod named '$ModName' in Development\Src. DeleteMod only deletes mods made with MakeMod.bat."
}

# The folder's real spelling, for the messages and the ini match.
$ModName = (Get-ChildItem -LiteralPath $SrcRoot -Directory | Where-Object { $_.Name -ieq $ModName }).Name
$ModDir  = Join-Path $SrcRoot $ModName
$ModU    = Join-Path $EngineRoot "OLGame\Script\$ModName.u"
$Inis    = "OLGame\Config\DefaultEngine.ini", "OLGame\Config\OLEngine.ini" | ForEach-Object { Join-Path $EngineRoot $_ }
$Entry   = '^\s*\+?ModEditPackages\s*=\s*' + [regex]::Escape($ModName) + '\s*$'

# --- Confirm ------------------------------------------------------------------

Write-Host ""
Write-Host "This will delete $($ModName):"
Write-Host "  Development\Src\$ModName\   (to the Recycle Bin)"
if (Test-Path $ModU)
{
    Write-Host "  OLGame\Script\$ModName.u   (to the Recycle Bin)"
}
foreach ($ini in $Inis)
{
    if ((Test-Path $ini) -and (Get-Content $ini -Encoding ASCII | Where-Object { $_ -match $Entry }))
    {
        Write-Host "  its registration in $(Split-Path $ini -Leaf)"
    }
}
Write-Host ""
Write-Host "Type $ModName to confirm, or anything else to cancel"

# ReadLine rather than Read-Host, so it also reads from redirected input.
$answer = [Console]::ReadLine()
if ("$answer".Trim() -ine $ModName)
{
    Write-Host "Cancelled. Nothing was deleted."
}
else
{
    # --- 1. Folder ------------------------------------------------------------

    try
    {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($ModDir, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
    catch
    {
        throw "Could not delete Development\Src\$ModName. Close anything using it (VS Code, a terminal, an Explorer window) and try again.`n$($_.Exception.Message)"
    }
    Write-Host "  deleted  Development\Src\$ModName\"

    # --- 2. Build -------------------------------------------------------------

    if (Test-Path $ModU)
    {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($ModU, 'OnlyErrorDialogs', 'SendToRecycleBin')
        Write-Host "  deleted  OLGame\Script\$ModName.u"
    }

    # --- 3. Registration ------------------------------------------------------

    foreach ($ini in $Inis)
    {
        if (Test-Path $ini)
        {
            $lines = @(Get-Content $ini -Encoding ASCII)
            $kept  = @($lines | Where-Object { $_ -notmatch $Entry })
            if ($kept.Count -ne $lines.Count)
            {
                Set-Content -Path $ini -Value $kept -Encoding ASCII
                Write-Host "  updated  $(Split-Path $ini -Leaf) (removed $ModName)"
            }
        }
    }

    Write-Host ""
    Write-Host "$ModName is deleted. The Recycle Bin has it if you change your mind."
    Write-Host "If another mod requires this one by Id, update its SDKModRequires by hand."
}