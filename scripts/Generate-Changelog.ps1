<# 
Keep-a-Changelog generator (PowerShell 5.1)

- Tag ranges (default) so tags like v1.0.128 always show
- Optional Unreleased from latest tag..HEAD
- Groups by Conventional Commit types (same set as the Python tool)
- Path include/exclude globs
- Compare/commit links
- Managed block update & incremental state (per branch)
#>
[CmdletBinding()]
param(
    [string]$Repo = ".",
    [string]$Output = "CHANGELOG.md",
    [switch]$IncludeUnreleased = $true,
    [string]$TagFilter = '^v?\d+\.(Q\d+|\d+)\.\d+$',
    [string]$Title = "Changelog",

    # Presentation
    [int]$MaxHighlights = 6,
    [switch]$IncludeFiles = $true,
    [int]$FileLimit = 5,

    # Paths
    [string]$PathInclude = '',
    [string]$PathExclude = '',

    # Types
    [string]$SkipTypes = '',

    # Behavior
    [switch]$ResetAll,
    [switch]$Refresh,
    [string]$State = ".github/release-notes.state.json",
    [switch]$ShowProgress
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# reuse core helpers from ReleaseNotes (minimal copy)
function Get-RepoPath() {
    (Resolve-Path $Repo).Path
}
function G() {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a)
    $psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName = "git.exe"; $psi.WorkingDirectory = (Get-RepoPath)
    $psi.Arguments = ($a -join ' '); $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
        throw "git $( $a -join ' ' ) failed: $e"
    }; $o
}
function Origin() {
    try {
        $u = (G "remote get-url origin").Trim()
    }
    catch {
        $u = $null
    }
    if ($u -match 'github\.com[:/](?<o>[^/]+)/(?<r>[^/.]+)(?:\.git)?$') {
        return @{ Type = 'github'; Host = 'github.com'; Owner = $Matches.o; Name = $Matches.r }
    }
    if ($u -match 'gitlab\.com[:/](?<o>.+)/(?<r>[^/.]+)(?:\.git)?$') {
        return @{ Type = 'gitlab'; Host = 'gitlab.com'; Owner = $Matches.o; Name = $Matches.r }
    }
    @{ Type = $null }
}
function Cmp($o, $b, $h) {
    if (-not $o.Type) {
        return $null
    }; if ($o.Type -eq 'github') {
        "https://$( $o.Host )/$( $o.Owner )/$( $o.Name )/compare/$b...$h"
    }
    elseif ($o.Type -eq 'gitlab') {
        "https://$( $o.Host )/$( $o.Owner )/$( $o.Name )/-/compare/$b...$h"
    }
}
function Com($o, $s) {
    if (-not $o.Type) {
        return $null
    }; if ($o.Type -eq 'github') {
        "https://$( $o.Host )/$( $o.Owner )/$( $o.Name )/commit/$s"
    }
    elseif ($o.Type -eq 'gitlab') {
        "https://$( $o.Host )/$( $o.Owner )/$( $o.Name )/-/commit/$s"
    }
}
function Esc([string]$s) {
    if (-not $s) {
        return ""
    }; $s.Replace('_', '\_').Replace('*', '\*').Replace('[', '\[').Replace(']', '\]')
}
function CSV([string]$s) {
    $result = New-Object 'System.Collections.Generic.List[string]'
    if (-not $s) {
        return $result
    }

    foreach ($part in ($s.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $null = $result.Add($part)
    }
    return $result
}
$Types = @('feat', 'fix', 'perf', 'refactor', 'docs', 'chore', 'build', 'ci', 'test', 'style', 'revert', 'deps', 'other')
$Skip = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($val in (CSV $SkipTypes | % { $_.ToLowerInvariant() })) {
    if ($val) { $null = $Skip.Add($val) }
}
function T([string]$sub) {
    $m = [regex]::Match($sub, '^(?<t>\w+)(\([^)]*\))?:\s+'); if ($m.Success -and ($Types -contains $m.Groups['t'].Value.ToLowerInvariant())) {
        $m.Groups['t'].Value.ToLowerInvariant()
    }
    else {
        'other'
    }
}
function Tags([regex]$re) {
    ,@((G "tag -l --sort=-creatordate") -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $re.IsMatch($_) })
}
function Head() {
    (G "rev-parse HEAD").Trim()
}
function Branch() {
    (G "rev-parse --abbrev-ref HEAD").Trim()
}
function StateLoad($p) {
    if ([IO.Path]::IsPathRooted($p)) {
        $fullPath = $p
    } else {
        $fullPath = [IO.Path]::Combine((Get-RepoPath), $p)
    }

    if (-not (Test-Path $fullPath)) {
        return $null
    }; try {
        Get-Content $fullPath -Raw | ConvertFrom-Json
    }
    catch {
        $null
    }
}
function StateSave($p, $o) {
    if ([IO.Path]::IsPathRooted($p)) {
        $fullPath = $p
    } else {
        $fullPath = [IO.Path]::Combine((Get-RepoPath), $p)
    }

    $d = [IO.Path]::GetDirectoryName($fullPath); if ($d -and -not (Test-Path $d)) {
        [IO.Directory]::CreateDirectory($d) | Out-Null
    }
    ($o | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $fullPath -Encoding UTF8
}

# ranges
$origin = Origin
$tagRe = New-Object System.Text.RegularExpressions.Regex($TagFilter)
$tags = @()
try {
    $tags = @(Tags $tagRe)
}
catch {
}

$head = Head
$branch = Branch
if ($ResetAll -and (Test-Path $State)) {
    Remove-Item $State -Force
}
$stateCache = if ($Refresh) {
    $null
}
else {
    StateLoad -p $State
}

$ranges = New-Object System.Collections.Generic.List[hashtable]
if ($tags.Count -gt 0) {
    if ($IncludeUnreleased) {
        $ranges.Add(@{ Label = 'Unreleased'; Base = $tags[0]; Head = 'HEAD' })
    }
    for ($i = 0; $i -lt $tags.Count; $i++) {
        $cur = $tags[$i]; $prev = if ($i -lt $tags.Count - 1) {
            $tags[$i + 1]
        }
        else {
            $null
        }
        $ranges.Add(@{ Label = $cur; Base = $cur; Head = $prev })
    }
}
else {
    $ranges.Add(@{ Label = 'Unreleased'; Base = $head; Head = $null })
}

# gather & render
$inc = CSV $PathInclude
$exc = CSV $PathExclude
$hasInc = $inc -and $inc.Count -gt 0
$hasExc = $exc -and $exc.Count -gt 0
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# $Title")
[void]$sb.AppendLine()
[void]$sb.AppendLine("All notable changes to this project will be documented in this file.")
[void]$sb.AppendLine("The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).")
[void]$sb.AppendLine()

foreach ($r in $ranges) {
    $label = $r.Label
    $spec = if ($r.Head) {
        "$( $r.Base )..$( $r.Head )"
    }
    else {
        "$( $r.Base )^!"
    }
    $cmp = if ($origin.Type -and $r.Head) {
        Cmp $origin $r.Base $r.Head
    }
    elseif ($origin.Type -and $label -eq 'Unreleased') {
        Cmp $origin $r.Base 'HEAD'
    }
    else {
        $null
    }
    $title = if ($cmp) {
        "[$label]($cmp)"
    }
    else {
        $label
    }
    [void]$sb.AppendLine("## $title")
    [void]$sb.AppendLine()

    $fmt = "%H%x09%h%x09%ad%x09%s%x09%an"
    $log = G "log --date=short --pretty=format:'$fmt' $spec --"
    $lines = @()
    if ($log) {
        $lines = $log -split "`n"
    }

    $items = @()
    foreach ($ln in $lines) {
        $p = $ln -split "`t"; if ($p.Count -lt 5) {
            continue
        }
        $items += , ([pscustomobject]@{ Sha = $p[0]; Short = $p[1]; Date = $p[2]; Subject = $p[3]; Author = $p[4] })
    }

    # file filter if requested
    if ($hasInc -or $hasExc) {
        $items = $items | Where-Object {
            $sha = $_.Sha
            $names = G "show --name-only --pretty=format:'' $sha"
            if (-not $names) { return $true }

            foreach ($f in ($names -split "`n")) {
                $n = $f.Trim()
                if (-not $n) { continue }

                $normalized = ($n -replace '\\', '/')
                if (-not $normalized) { continue }

                $isExcluded = $false
                if ($hasExc) {
                    foreach ($e in $exc) {
                        $pattern = ($e -replace '\*\*', '*')
                        if ($normalized -like $pattern) {
                            $isExcluded = $true
                            break
                        }
                    }
                }
                if ($isExcluded) { continue }

                $matchesInclude = $false
                if (-not $hasInc) {
                    $matchesInclude = $true
                } else {
                    foreach ($i in $inc) {
                        $pattern = ($i -replace '\*\*', '*')
                        if ($normalized -like $pattern) {
                            $matchesInclude = $true
                            break
                        }
                    }
                }

                if ($matchesInclude) { return $true }
            }

            return $false
        }
    }

    # group & print
    $groups = @{ }
    foreach ($t in $Types) {
        $groups[$t] = New-Object System.Collections.Generic.List[object]
    }
    foreach ($c in $items) {
        $t = T $c.Subject
        if ( $Skip.Contains($t)) {
            continue
        }
        $groups[$t].Add($c)
    }

    $order = @($Types | Where-Object { $groups[$_] -and $groups[$_].Count -gt 0 })
    if ($order.Count -eq 0) {
        [void]$sb.AppendLine("_No changes in this release._`n")
        continue
    }

    foreach ($t in $order) {
        [void]$sb.AppendLine("### $($t.Substring(0, 1).ToUpper() )$($t.Substring(1) )")
        $take = if ($MaxHighlights -gt 0) {
            [System.Linq.Enumerable]::Take($groups[$t], [int]$MaxHighlights)
        }
        else {
            $groups[$t]
        }
        foreach ($c in $take) {
            $lnk = if ($origin.Type) {
                "([`$($c.Short)`]($( Com $origin $c.Sha )))"
            }
            else {
                "(`$($c.Short)`)"
            }
            [void]$sb.AppendLine("- $( Esc $c.Subject ) $lnk")
        }
        if ($MaxHighlights -gt 0 -and $groups[$t].Count -gt $MaxHighlights) {
            [void]$sb.AppendLine("- _...and $( $groups[$t].Count - $MaxHighlights ) more commits_")
        }
        [void]$sb.AppendLine()
    }
}

# write with managed block
$begin = '<!-- BEGIN AUTO-RELEASE-NOTES -->'; $end = '<!-- END AUTO-RELEASE-NOTES -->'
$block = "$begin`r`n$($sb.ToString() )`r`n$end`r`n"
if ([IO.Path]::IsPathRooted($Output)) {
    $full = $Output
} else {
    $full = [IO.Path]::Combine((Get-RepoPath), $Output)
}
$dir = [IO.Path]::GetDirectoryName($full); if ($dir -and -not (Test-Path $dir)) {
    [IO.Directory]::CreateDirectory($dir) | Out-Null
}

if ($ResetAll -or -not (Test-Path $full)) {
    Set-Content -LiteralPath $full -Value $block -Encoding UTF8
}
else {
    $old = Get-Content -LiteralPath $full -Raw -EA SilentlyContinue
    if ($old -and $old.Contains($begin) -and $old.Contains($end)) {
        $pre = $old.Split($begin)[0]; $post = $old.Split($end, 2)[1]
        Set-Content -LiteralPath $full -Value ($pre + $block + $post) -Encoding UTF8
    }
    else {
        Add-Content -LiteralPath $full -Value "`r`n$block" -Encoding UTF8
    }
}

StateSave -p $State -o @{ lastProcessedSha = $head; branch = $branch; updatedAt = (Get-Date).ToUniversalTime().ToString("o"); outputFile = $Output }
Write-Host "Changelog updated: $full"
