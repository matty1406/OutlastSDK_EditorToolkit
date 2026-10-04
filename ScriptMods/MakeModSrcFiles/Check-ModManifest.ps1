<#
.SYNOPSIS
  Fail a mod build whose manifest is incomplete or whose Id is not namespaced.

.DESCRIPTION
  Every mod must declare an Id, a display Name, a Version and an Author, and the Id
  must read "Author.Something" with the author part matching the declared Author. The
  SDK refuses a mod that does not, so this checks it at the build instead of at
  someone else's launch.

  A native mod is already held to most of this by the linker -- OL_MOD takes the Id
  and Name, and OL_MOD_VERSION / OL_MOD_AUTHOR are required symbols. This reports the
  same thing in a readable sentence rather than an unresolved external, and gives
  script mods the same guarantee, which they have no linker for.

  Load order is deliberately NOT checked: it defaults to 100 on both sides, and a mod
  that never thinks about load order is not making a mistake.

  Reads whichever set applies:
    .cpp   OL_MOD(L"Id", L"Name") + OL_MOD_VERSION / OL_MOD_AUTHOR
    .uc    SDKModId / SDKModName / SDKModVersion / SDKModAuthor

.PARAMETER File
  The mod source to check: a .cpp, a manifest .uc, or a folder to find the manifest
  in (any .uc extending SDKModManifest). A folder with no manifest passes with exit
  code 2, since a plain script package does not need one.
#>
param(
    [Parameter(Mandatory = $true)] [string] $File
)

function Fail($text)
{
    Write-Host ""
    Write-Host "BUILD FAILED: $text" -ForegroundColor Red
    Write-Host "  The SDK would refuse this mod at load. See MODDING.md." -ForegroundColor DarkGray
    exit 1
}

if (-not (Test-Path -LiteralPath $File))
{
    Fail "Check-ModManifest: no such file: $File"
}

# A folder means "find the manifest yourself" -- the script compile scripts pass the
# mod's Classes folder, since the manifest can be named anything.
$target = $File
if ((Get-Item -LiteralPath $File).PSIsContainer)
{
    $target = Get-ChildItem -LiteralPath $File -Filter *.uc -Recurse |
              Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'extends\s+SDKModManifest' } |
              Select-Object -First 1 -ExpandProperty FullName

    # No manifest means a plain script package that does not use the SDK, so there
    # is nothing to check. Exit 2 lets the build scripts say so once they finish.
    if (-not $target)
    {
        Write-Host "Check-ModManifest: no SDKModManifest class, skipped" -ForegroundColor DarkGray
        exit 2
    }
}

# Commented-out declarations are not declarations. Drop those lines before matching,
# so an example in a template comment cannot be mistaken for the real thing.
$lines = Get-Content -LiteralPath $target | Where-Object { $_.TrimStart() -notmatch '^(//|rem\s)' }
$text  = $lines -join "`n"
$name  = Split-Path -Leaf $target

# By content, not extension: a manifest is a class extending SDKModManifest whatever
# the file is called, which also covers the .uc.template the scaffolding expands.
$isUc  = $text -match 'extends\s+SDKModManifest' -or $target -match '\.uc(\.template)?$'

# field label -> pattern whose first capture group is the value
if ($isUc)
{
    $fields = [ordered]@{
        'SDKModId'      = 'SDKModId\s*=\s*"([^"]*)"'
        'SDKModName'    = 'SDKModName\s*=\s*"([^"]*)"'
        'SDKModVersion' = 'SDKModVersion\s*=\s*"([^"]*)"'
        'SDKModAuthor'  = 'SDKModAuthor\s*=\s*"([^"]*)"'
    }
    $idField     = 'SDKModId'
    $authorField = 'SDKModAuthor'
}
else
{
    $fields = [ordered]@{
        'OL_MOD (Id)'       = 'OL_MOD\s*\(\s*L"([^"]*)"'
        'OL_MOD (Name)'     = 'OL_MOD\s*\(\s*L"[^"]*"\s*,\s*L"([^"]*)"'
        'OL_MOD_VERSION'    = 'OL_MOD_VERSION\s*\(\s*L"([^"]*)"'
        'OL_MOD_AUTHOR'     = 'OL_MOD_AUTHOR\s*\(\s*L"([^"]*)"'
    }
    $idField     = 'OL_MOD (Id)'
    $authorField = 'OL_MOD_AUTHOR'
}

$values = @{}
$missing = @()
foreach ($f in $fields.Keys)
{
    $m = [regex]::Match($text, $fields[$f])
    if (-not $m.Success -or -not $m.Groups[1].Value.Trim())
    {
        $missing += $f
    }
    else
    {
        $values[$f] = $m.Groups[1].Value
    }
}

if ($missing.Count -gt 0)
{
    Fail "$name does not set $($missing -join ', ') -- a manifest needs an Id, Name, Version and Author"
}

$author = $values[$authorField]
$token  = ($author -replace '[^A-Za-z0-9]', '')

if (-not $token)
{
    Fail "$name has $authorField `"$author`", which has no letters or digits to namespace the Id with"
}

$id  = $values[$idField]
$dot = $id.IndexOf('.')

if ($dot -lt 1 -or $dot -ge $id.Length - 1)
{
    Fail "$name has Id `"$id`", which is not namespaced -- it must read `"$token.$id`""
}

$prefix = $id.Substring(0, $dot)
if ($prefix -ne $token -and $prefix.ToLower() -ne $token.ToLower())
{
    Fail "$name has Id `"$id`", which must start with `"$token.`" to match its $authorField `"$author`""
}

Write-Host "Check-ModManifest: $id  (author $author)" -ForegroundColor DarkGray
exit 0