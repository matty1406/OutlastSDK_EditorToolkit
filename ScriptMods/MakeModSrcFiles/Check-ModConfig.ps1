<#
.SYNOPSIS
  Works out which ini files a script mod reads, writes a starter for any that are missing, and warns about settings left empty.

.DESCRIPTION
  A class declared config(X) reads its config variables from DefaultX.ini, under a [Package.Class] section. This reads the mod's sources, so it knows every section and key before the game looks for them. A missing Config\DefaultX.ini is created with every key, filled from defaultproperties where the class sets a value. An existing file is never changed; keys it lacks or leaves empty are reported instead.

  With -ModIniOut it packages the config for the OutlastSDK instead: when the mod has a manifest, every Config\Default*.ini is merged into one mod.ini in that folder, since the SDK reads a mod's config from Mods\<Package>\mod.ini.

.PARAMETER Classes
  The mod's Classes folder. Config\ sits next to it.

.PARAMETER Package
  The mod's package name, which starts every section name.

.PARAMETER EngineRoot
  Optional. Root of the engine tree, used to find which ini a class inherits from an engine parent.

.PARAMETER ModIniOut
  Optional. A deploy folder to write mod.ini into, instead of checking.
#>
param(
    [Parameter(Mandatory = $true)] [string] $Classes,
    [Parameter(Mandatory = $true)] [string] $Package,
    [string] $EngineRoot,
    [string] $ModIniOut
)

$ErrorActionPreference = 'Stop'

# Config names the game ships its own DefaultX.ini for. Shipping one of these would replace the game's file.
$GameConfigs = @('Engine', 'Game', 'Input', 'UI', 'Editor', 'EditorKeyBindings', 'EditorUserSettings', 'SystemSettings', 'Lightmass', 'Enemy')

# Types whose empty ini value just reads as zero, so leaving one empty is not worth a warning.
$NumberTypes = @('int', 'byte', 'float')

# Words that can come before the type in a var declaration.
$Specifiers = @('config', 'globalconfig', 'const', 'localized', 'transient', 'native', 'private', 'protected', 'public', 'privatewrite', 'protectedwrite', 'editconst', 'editinline', 'editinlineuse', 'editfixedsize', 'edithide', 'editortextbox', 'editoronly', 'noexport', 'noimport', 'noclear', 'nontransactional', 'notforconsole', 'export', 'input', 'interp', 'instanced', 'deprecated', 'databinding', 'duplicatetransient', 'repnotify', 'repretry', 'archetype', 'crosslevelactive', 'crosslevelpassive', 'serializetext', 'init')

# Blanks out comments but keeps line breaks. String and name literals match first, so a // inside one survives.
function Remove-Comments([string] $Text)
{
    $evaluator = [Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $value = $m.Value
        if ($value.StartsWith('/'))
        {
            $value = [regex]::Replace($value, '[^\n]', ' ')
        }
        return $value
    }
    return [regex]::Replace($Text, '"(?:[^"\\\n]|\\.)*"|''[^''\n]*''|//[^\n]*|/\*[\s\S]*?\*/', $evaluator)
}

# A class's name, parent and config(X), with its source minus comments. $null for a file with no class line.
function Read-UcClass([string] $Path)
{
    $text = Remove-Comments ([IO.File]::ReadAllText($Path))
    $decl = [regex]::Match($text, '(?i)\bclass\s+(\w+)(?:\s+extends\s+([\w.]+))?([^;{]*);')
    $info = $null

    if ($decl.Success)
    {
        $spec = $decl.Groups[3].Value
        $config = [regex]::Match($spec, '(?i)\bconfig\s*\(\s*(\w+)\s*\)')
        $configName = ''
        if ($config.Success)
        {
            $configName = $config.Groups[1].Value
        }

        $info = [pscustomobject]@{
            Name      = $decl.Groups[1].Value
            Parent    = $decl.Groups[2].Value -replace '^.*\.', ''
            Config    = $configName
            PerObject = $spec -match '\bperobjectconfig\b'
            Text      = $text
            Body      = $text.Substring($decl.Index + $decl.Length)
        }
    }
    return $info
}

# Splits a declaration into words, keeping a <...> group such as array<string> with its word.
function Split-Declaration([string] $Decl)
{
    $tokens = New-Object 'System.Collections.Generic.List[string]'
    $current = ''
    $depth = 0

    foreach ($c in $Decl.ToCharArray())
    {
        if ($c -eq '<')
        {
            # "array <string>" has a space before the group, so take the word back first.
            if ($depth -eq 0 -and $current -eq '' -and $tokens.Count -gt 0 -and $tokens[$tokens.Count - 1] -ne ',')
            {
                $current = $tokens[$tokens.Count - 1]
                $tokens.RemoveAt($tokens.Count - 1)
            }
            $depth++
            $current += $c
        }
        elseif ($c -eq '>' -and $depth -gt 0)
        {
            $depth--
            $current += $c
        }
        elseif ($depth -gt 0)
        {
            $current += $c
        }
        elseif ([char]::IsWhiteSpace($c) -or $c -eq ',')
        {
            if ($current)
            {
                $tokens.Add($current)
                $current = ''
            }
            if ($c -eq ',')
            {
                $tokens.Add(',')
            }
        }
        else
        {
            $current += $c
        }
    }

    if ($current)
    {
        $tokens.Add($current)
    }
    return ,$tokens
}

# The config variables a class declares itself: name, whether it is a dynamic array, and its static size if it has one.
function Get-ConfigVars([string] $Body)
{
    # Declarations end where defaultproperties starts.
    $cut = [regex]::Match($Body, '(?i)\bdefaultproperties\b')
    if ($cut.Success)
    {
        $Body = $Body.Substring(0, $cut.Index)
    }

    $vars = @()
    foreach ($m in [regex]::Matches($Body, '(?i)\bvar\s*(?:\([^)]*\))?([^;]*);'))
    {
        $tokens = Split-Declaration $m.Groups[1].Value
        $i = 0
        $isConfig = $false
        while ($i -lt $tokens.Count -and $Specifiers -contains $tokens[$i])
        {
            if ($tokens[$i] -eq 'config' -or $tokens[$i] -eq 'globalconfig')
            {
                $isConfig = $true
            }
            $i++
        }

        # An inline enum or struct declaration has no simple type to read, and is never config in practice.
        if ($isConfig -and $i -lt $tokens.Count - 1 -and @('enum', 'struct') -notcontains $tokens[$i])
        {
            $type = $tokens[$i]
            $isArray = $type -match '^array\s*<'
            for ($j = $i + 1; $j -lt $tokens.Count; $j++)
            {
                # Metadata such as <ClampMin=0> follows the name, and a static size sits in brackets.
                $name = $tokens[$j] -replace '<.*$', ''
                $size = ''
                if ($name -match '^(\w+)\[(\w+)\]$')
                {
                    $name = $Matches[1]
                    $size = $Matches[2]
                }

                if ($name -match '^\w+$')
                {
                    $vars += [pscustomobject]@{ Name = $name; Type = $type; IsArray = $isArray; Size = $size }
                }
            }
        }
    }
    return $vars
}

# The entry for one property in a defaults table, created on first use.
function Get-DefaultEntry([hashtable] $Defaults, [string] $Name)
{
    $entry = $Defaults[$Name]
    if (-not $entry)
    {
        $entry = [pscustomobject]@{ Scalar = $null; Items = New-Object 'System.Collections.Generic.SortedDictionary[int,string]' }
        $Defaults[$Name] = $entry
    }
    return $entry
}

# What a class sets in defaultproperties: Scalar for Name=Value, Items for Name(i)=Value and Name.Add(Value).
function Get-Defaults([string] $Text)
{
    $defaults = @{}
    $start = [regex]::Match($Text, '(?i)\bdefaultproperties\s*\{')

    if ($start.Success)
    {
        $from = $start.Index + $start.Length
        $to = $Text.LastIndexOf('}')
        $depth = 0

        foreach ($raw in $Text.Substring($from, [Math]::Max(0, $to - $from)) -split "`n")
        {
            $line = $raw.Trim()

            # Subobjects set their own properties, not the class's.
            if ($line -match '^begin\s+object\b')
            {
                $depth++
            }
            elseif ($line -match '^end\s+object\b')
            {
                $depth--
            }
            elseif ($depth -eq 0)
            {
                if ($line -match '^(\w+)\s*\.\s*Add\s*\((.*)\)\s*;?$')
                {
                    $name = $Matches[1]
                    $value = $Matches[2].Trim()
                    $entry = Get-DefaultEntry $defaults $name
                    $next = 0
                    if ($entry.Items.Count -gt 0)
                    {
                        $next = @($entry.Items.Keys)[-1] + 1
                    }
                    $entry.Items[$next] = $value
                }
                elseif ($line -match '^(\w+)\s*[\(\[]\s*(\d+)\s*[\)\]]\s*=\s*(.*?)\s*;?$')
                {
                    $name = $Matches[1]
                    $index = [int]$Matches[2]
                    $value = $Matches[3]
                    $entry = Get-DefaultEntry $defaults $name
                    $entry.Items[$index] = $value
                }
                elseif ($line -match '^(\w+)\s*=\s*(.*?)\s*;?$')
                {
                    $name = $Matches[1]
                    $value = $Matches[2]
                    $entry = Get-DefaultEntry $defaults $name
                    $entry.Scalar = $value
                }
            }
        }
    }
    return $defaults
}

# A defaultproperties value as an ini value: strings and names lose their quotes, everything else is kept as written.
function ConvertTo-IniValue([string] $Value)
{
    $result = $Value
    if ($Value -match '^"(.*)"$')
    {
        $result = $Matches[1] -replace '\\(.)', '$1'
    }
    elseif ($Value -match "^'(.*)'$")
    {
        $result = $Matches[1]
    }
    return $result
}

# The ini lines for one class's config variables, filled from its defaults.
function Get-IniLines($Vars, [hashtable] $Defaults)
{
    $lines = @()
    foreach ($v in $Vars)
    {
        $d = $Defaults[$v.Name]
        if ($v.IsArray)
        {
            if ($d -and $d.Items.Count -gt 0)
            {
                foreach ($value in $d.Items.Values)
                {
                    $lines += "$($v.Name)=$(ConvertTo-IniValue $value)"
                }
            }
            else
            {
                $lines += "; $($v.Name)=   (one line per entry)"
            }
        }
        elseif ($v.Size)
        {
            if ($d -and $d.Items.Count -gt 0)
            {
                foreach ($k in $d.Items.Keys)
                {
                    $lines += "$($v.Name)[$k]=$(ConvertTo-IniValue $d.Items[$k])"
                }
            }
            else
            {
                $lines += "; $($v.Name)[0]=   (one line per index)"
            }
        }
        else
        {
            # An unset bool or number is written as its zero, so the file shows the value the game will use.
            $value = ''
            if ($d -and $null -ne $d.Scalar)
            {
                $value = ConvertTo-IniValue $d.Scalar
            }
            elseif ($v.Type -eq 'bool')
            {
                $value = 'False'
            }
            elseif ($NumberTypes -contains $v.Type)
            {
                $value = '0'
            }
            $lines += "$($v.Name)=$value"
        }
    }
    return ,$lines
}

# Sections and keys of an ini file, case-insensitive. A +, -, . or ! prefix counts as the key itself.
function Read-Ini([string] $Path)
{
    $ini = @{}
    $section = $null
    foreach ($raw in [IO.File]::ReadAllLines($Path))
    {
        $line = $raw.Trim()
        if ($line -match '^\[(.+)\]$')
        {
            $name = $Matches[1].Trim()
            if (-not $ini.ContainsKey($name))
            {
                $ini[$name] = @{}
            }
            $section = $ini[$name]
        }
        elseif ($null -ne $section -and -not $line.StartsWith(';') -and $line -match '^[+\-.!]?([^=]+?)\s*=(.*)$')
        {
            $section[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $ini
}

# CRLF text with no trailing newline, in ASCII when it fits and UTF-16 otherwise: the two encodings the engine reads.
function Write-IniFile([string] $Path, [string] $Text)
{
    $Text = ($Text -replace '\r?\n', "`r`n").TrimEnd()
    $encoding = [Text.Encoding]::ASCII
    if ($Text -match '[^\x00-\x7F]')
    {
        $encoding = [Text.Encoding]::Unicode
    }
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

# An engine class by name, from Development\Src\*\Classes. The folder is indexed once, on first use.
$script:engineIndex = $null
$script:engineCache = @{}
function Read-EngineClass([string] $Name)
{
    $info = $null
    if ($EngineRoot)
    {
        if ($null -eq $script:engineIndex)
        {
            $script:engineIndex = @{}
            foreach ($file in Get-ChildItem -Path (Join-Path $EngineRoot 'Development\Src\*\Classes\*.uc') -ErrorAction SilentlyContinue)
            {
                if (-not $script:engineIndex.ContainsKey($file.BaseName))
                {
                    $script:engineIndex[$file.BaseName] = $file.FullName
                }
            }
        }

        if ($script:engineCache.ContainsKey($Name))
        {
            $info = $script:engineCache[$Name]
        }
        elseif ($script:engineIndex.ContainsKey($Name))
        {
            $info = Read-UcClass $script:engineIndex[$Name]
            $script:engineCache[$Name] = $info
        }
    }
    return $info
}

# The config name a class ends up with: its own config(X), else the nearest parent's, through engine classes too. '' when unknown.
function Resolve-ConfigName([string] $ClassName)
{
    $name = ''
    $current = $ClassName
    for ($hops = 0; $hops -lt 32 -and $current -and -not $name; $hops++)
    {
        $info = $modClasses[$current]
        if (-not $info)
        {
            $info = Read-EngineClass $current
        }

        $current = ''
        if ($info)
        {
            $name = $info.Config
            $current = $info.Parent
        }
    }
    return $name
}

$modDir = Split-Path -Parent (Resolve-Path -LiteralPath $Classes).Path
$configDir = Join-Path $modDir 'Config'

$modClasses = @{}
foreach ($file in Get-ChildItem -LiteralPath $Classes -Filter *.uc -Recurse)
{
    $info = Read-UcClass $file.FullName
    if ($info)
    {
        $modClasses[$info.Name] = $info
    }
}
$hasManifest = @($modClasses.Values | Where-Object { $_.Parent -eq 'SDKModManifest' }).Count -gt 0

# --- Deploy: one mod.ini for the OutlastSDK ---------------------------------------------------------

if ($ModIniOut)
{
    $sources = @()
    if (Test-Path -LiteralPath $configDir)
    {
        $sources = @(Get-ChildItem -LiteralPath $configDir -Filter 'Default*.ini' | Sort-Object Name)
    }

    if ($hasManifest -and $sources.Count -gt 0)
    {
        $parts = foreach ($source in $sources)
        {
            "; From Config\$($source.Name)`r`n" + ([IO.File]::ReadAllText($source.FullName)).Trim()
        }
        Write-IniFile (Join-Path $ModIniOut 'mod.ini') ($parts -join "`r`n`r`n")
        Write-Host "  mod.ini, merged from Config\ for the OutlastSDK"
    }
    exit 0
}

# --- Compile: which files the classes read ----------------------------------------------------------

$files = [ordered]@{}
$warnings = @()

foreach ($info in $modClasses.Values | Sort-Object Name)
{
    $vars = @(Get-ConfigVars $info.Body)
    if ($vars.Count -gt 0)
    {
        $configName = $info.Config
        $inherited = -not $configName
        if ($inherited)
        {
            $configName = Resolve-ConfigName $info.Parent
        }

        if ($info.PerObject)
        {
            Write-Host "  $($info.Name) is perobjectconfig, so its sections are named per object and are not checked." -ForegroundColor DarkGray
        }
        elseif ($configName -and $GameConfigs -notcontains $configName)
        {
            if (-not $files.Contains($configName))
            {
                $files[$configName] = New-Object System.Collections.ArrayList
            }
            [void]$files[$configName].Add([pscustomobject]@{
                Class   = $info.Name
                Section = "$Package.$($info.Name)"
                Vars    = $vars
                Lines   = Get-IniLines $vars (Get-Defaults $info.Text)
            })
        }
        elseif ($inherited)
        {
            $where = "its parent's ini"
            if ($configName)
            {
                $where = "Default$configName.ini, the game's own file"
            }
            $warnings += "$($info.Name) has config variables but no config(...) of its own, so they would be read from $where. Add config(SomeName) to its class line to give the mod its own file."
        }
        else
        {
            $warnings += "$($info.Name) uses config($configName), the game's own Default$configName.ini. Shipping that file would replace the game's, so give it a config name of its own."
        }
    }
}

foreach ($configName in $files.Keys)
{
    $fileName = "Default$configName.ini"
    $path = Join-Path $configDir $fileName
    $sections = $files[$configName]
    $classList = ($sections | ForEach-Object { $_.Class }) -join ', '

    if (Test-Path -LiteralPath $path)
    {
        Write-Host "  Config\$fileName, read by $classList"
    }
    else
    {
        $text = ($sections | ForEach-Object { "[$($_.Section)]`r`n" + ($_.Lines -join "`r`n") }) -join "`r`n`r`n"
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
        Write-IniFile $path $text
        Write-Host "  Created Config\$fileName for $classList. Fill in its values."
    }

    # Arrays may be left empty on purpose, so only single values are held to having one.
    $ini = Read-Ini $path
    foreach ($s in $sections)
    {
        $section = $ini[$s.Section]
        if ($null -eq $section)
        {
            $warnings += "Config\$fileName has no [$($s.Section)] section, so $($s.Class) keeps its defaultproperties values."
        }
        else
        {
            foreach ($v in $s.Vars | Where-Object { -not $_.IsArray -and -not $_.Size })
            {
                if (-not $section.ContainsKey($v.Name))
                {
                    $warnings += "Config\$fileName has no $($v.Name) under [$($s.Section)]."
                }
                elseif (-not $section[$v.Name] -and $v.Type -ne 'bool' -and $NumberTypes -notcontains $v.Type)
                {
                    $warnings += "Config\$fileName leaves $($v.Name) empty."
                }
            }
        }
    }
}

foreach ($warning in $warnings)
{
    Write-Host "  Warning: $warning" -ForegroundColor Yellow
}

if ($files.Count -eq 0 -and $warnings.Count -eq 0)
{
    Write-Host "  No class keeps settings in an ini." -ForegroundColor DarkGray
}
elseif ($files.Count -gt 0)
{
    if ($hasManifest)
    {
        Write-Host "  Deploy.bat ships Config\, and merges it into mod.ini, which is where the OutlastSDK reads it." -ForegroundColor DarkGray
    }
    else
    {
        Write-Host "  Deploy.bat ships Config\. Without the SDK, its files go in the game's OLGame\Config folder." -ForegroundColor DarkGray
    }
}
exit 0