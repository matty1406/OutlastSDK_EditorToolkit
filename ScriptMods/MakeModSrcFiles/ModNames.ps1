<#
.SYNOPSIS
  Name helpers shared by MakeMod.ps1 and RenameMod.ps1. Dot-source it.
#>

# "my cool mod" -> "MyCoolMod". Splits on anything that is not a letter or digit,
# capitalises the first letter of each part and keeps the rest as typed.
function ConvertTo-PascalCase([string] $Text)
{
    $parts = $Text -split '[^A-Za-z0-9]+' | Where-Object { $_ }
    $words = $parts | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }
    return ($words -join '')
}

# A package name as typed if it is already valid, otherwise its PascalCase form with
# any leading digits dropped. Returns "" when nothing usable is left.
function ConvertTo-ModName([string] $Text)
{
    $name = $Text.Trim()

    if ($name -notmatch '^[A-Za-z][A-Za-z0-9_]*$')
    {
        $name = (ConvertTo-PascalCase $name) -replace '^[0-9]+', ''
    }

    return $name
}