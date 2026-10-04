<#
.SYNOPSIS
  Scaffold a new SDK script mod in this source tree.

.DESCRIPTION
  Does the three things between "I want a mod" and "I can hit Compile":

    1. Creates Development\Src\<ModName>\Classes\ with a manifest class. Every SDK
       script mod needs one - it extends SDKModManifest, which is how the SDK finds
       and lists the mod.
    2. Expands the templates in MakeModSrcFiles into the mod folder (Compile /
       CompileRetail / Deploy bats, VS Code workspace + tasks).
    3. Registers OutlastSDK and then the mod with the make commandlet, via
       Register-Package.ps1. Order matters: OutlastSDK holds SDKModManifest and
       OutlastSDKLibrary, so it has to compile first.

.PARAMETER ModName
  Package name. Becomes the folder name, the script package name, and the .u
  filename. Letters, digits and underscores only.

.PARAMETER Author
  Your author name, as players see it. The mod's Id is namespaced by it, with
  spaces and punctuation dropped: "Matty D." gives "MattyD.<ModName>".

.PARAMETER EngineRoot
  Root of the UnrealEngine3 tree. Defaults to the parent of MakeModSrcFiles.

.EXAMPLE
  .\MakeMod.ps1 -ModName MyMod -Author "Matty D."
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ModName,

    [Parameter(Mandatory = $true)]
    [string] $Author,

    [string] $EngineRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = 'Stop'

if ($ModName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
    throw "Invalid mod name '$ModName'. Use letters, digits and underscores, starting with a letter."
}

# The author lands inside an UnrealScript string literal, so quotes and backslashes
# would break the manifest.
$Author = $Author.Trim()
$AuthorId = $Author -replace '[^A-Za-z0-9]', ''
if ($Author -match '["\\]' -or -not $AuthorId) {
    throw "Invalid author name '$Author'. It needs at least one letter or digit, and no quotes or backslashes."
}

$ModDir = Join-Path $EngineRoot "Development\Src\$ModName"
if (Test-Path $ModDir) {
    throw "This mod already exists: $ModDir"
}

if (-not (Test-Path (Join-Path $EngineRoot "Development\Src\OutlastSDK\Classes\SDKModManifest.uc"))) {
    throw @"
Not an engine tree with the toolkit installed: $EngineRoot

MakeMod.bat has to run from the engine root, next to Development\ and Binaries\.
If you are running the copy inside OutlastSDK_EditorToolkit\ScriptMods\, run the
toolkit's Install.bat instead - that puts a working copy at the engine root.
"@
}

# --- 1. Folders ---------------------------------------------------------------

New-Item -ItemType Directory -Force -Path (Join-Path $ModDir "Classes")  | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ModDir ".vscode")  | Out-Null

# --- 2. Templates -------------------------------------------------------------

# Source template -> destination, relative to the mod folder. __MODNAME__ in the
# template body (and in the destination name) is replaced with the real name, and
# __AUTHOR__ / __AUTHORID__ with the author as typed and as the Id prefix.
$Templates = @(
    @{ From = "Compile.bat.template";        To = "Compile.bat"                     },
    @{ From = "CompileRetail.bat.template";  To = "CompileRetail.bat"               },
    @{ From = "Deploy.bat.template";         To = "Deploy.bat"                      },
    @{ From = "tasks.json.template";         To = ".vscode\tasks.json"              },
    @{ From = "Mod.code-workspace.template"; To = "__MODNAME__.code-workspace"      },
    @{ From = "ModManifest.uc.template";     To = "Classes\__MODNAME__Manifest.uc"  }
)

foreach ($Template in $Templates) {
    $SourcePath = Join-Path $PSScriptRoot $Template.From
    if (-not (Test-Path $SourcePath)) {
        throw "Missing template: $SourcePath"
    }

    $DestPath = Join-Path $ModDir ($Template.To -replace '__MODNAME__', $ModName)
    $Body     = (Get-Content $SourcePath -Raw) -replace '__MODNAME__', $ModName
    $Body     = $Body.Replace('__AUTHORID__', $AuthorId).Replace('__AUTHOR__', $Author)

    # -NoNewline so the files match the rest of the tree (no trailing blank line).
    Set-Content -Path $DestPath -Value $Body -Encoding ASCII -NoNewline
    Write-Host "  created  $($Template.To -replace '__MODNAME__', $ModName)"
}

# --- 3. Register with make ----------------------------------------------------

& (Join-Path $PSScriptRoot "Register-Package.ps1") -EngineRoot $EngineRoot -Package OutlastSDK, $ModName

Write-Host ""
Write-Host "$ModName is ready."
Write-Host ""
Write-Host "  Mod Id     $AuthorId.$ModName"
Write-Host "  Source     Development\Src\$ModName\Classes\$($ModName)Manifest.uc"
Write-Host "  Output     OLGame\Script\$ModName.u"
Write-Host "  Build      Development\Src\$ModName\Compile.bat        (normal engine version)"
Write-Host "             Development\Src\$ModName\CompileRetail.bat  (867/3/10907, loads in retail Outlast)"
Write-Host "  Package    Development\Src\$ModName\Deploy.bat         (stages a retail build into Output\$ModName\)"
Write-Host "  VS Code    Development\Src\$ModName\$ModName.code-workspace"