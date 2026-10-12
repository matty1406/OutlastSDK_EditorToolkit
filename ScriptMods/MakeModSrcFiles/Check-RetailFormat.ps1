<#
.SYNOPSIS
  Report a script package's version stamp, and fail unless retail Outlast can load it.

.DESCRIPTION
  Retail Outlast loads packages stamped file version 868, or 867 from older Retail Package Patch builds. Anything else was written in this engine's own format, which means -SaveAsRetail did nothing.

.PARAMETER Package
  The .u to check.

.PARAMETER Classes
  Optional. The mod's Classes folder, to warn when a source file changed after the .u was built.
#>
param(
    [Parameter(Mandatory = $true)] [string] $Package,
    [string] $Classes
)

# The file version and licensee version sit right after the 4-byte package tag.
$bytes = New-Object byte[] 8
$file = [IO.File]::OpenRead($Package)
[void]$file.Read($bytes, 0, 8)
$file.Close()

$version = [BitConverter]::ToUInt16($bytes, 4)
$licensee = [BitConverter]::ToUInt16($bytes, 6)
$item = Get-Item -LiteralPath $Package
$code = 0

if ($version -eq 868 -or $version -eq 867)
{
    # 'g' is the local short date and time, matching what cmd prints for the same file.
    Write-Host "  $($item.Name) is in retail format ($version / $licensee), built $($item.LastWriteTime.ToString('g'))."

    # A source edited after the build would ship without that edit.
    if ($Classes -and (Test-Path -LiteralPath $Classes))
    {
        $newer = Get-ChildItem -LiteralPath $Classes -Filter *.uc -Recurse | Where-Object { $_.LastWriteTime -gt $item.LastWriteTime } | Select-Object -First 1
        if ($newer)
        {
            Write-Host "  Warning: $($newer.Name) changed after $($item.Name) was built, so this package may be out of date. Run CompileRetail.bat again to include it." -ForegroundColor Yellow
        }
    }
}
else
{
    Write-Host "  $($item.Name) is stamped $version / $licensee, this engine's own format, so retail Outlast cannot load it." -ForegroundColor Red
    $code = 1
}

exit $code