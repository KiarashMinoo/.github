<# 
.SYNOPSIS
  Generate detailed release notes grouped by tags, with summaries, contributors, grouped changes, noise filtering,
  commit links, compare links, optional file lists and diff snippets. PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    [string]$Repo = ".",
    [string]$Output = "RELEASE_NOTES.md",
    [bool]$IncludeMerges = $false,
    [int]$MaxCommits = 0,
    [string]$SinceTag,
    [string]$UntilTag,
    [switch]$ShowProgress,

    # Optional tuning:
  [string[]]$ExcludeRegex = @(),   # extra patterns to skip entirely (additive to defaults)
  [string[]]$CollapseRegex = @(),  # extra patterns to collapse into a count
  [int]$MaxContributors = 10,      # top N contributors listed per tag
  [switch]$IncludeNoise,           # show everything (disable default noise filters/collapses)
  [switch]$ShowAuthorAndDate,      # include author and short ISO date on each bullet
  [int]$MaxHighlights = 0,         # limit per-group bullets (0 = no limit)

  # Optional files/snippets
  [switch]$IncludeFiles,
  [int]$FileLimit = 5,
  [switch]$IncludeSnippets,
    [ValidateSet('none', 'diff-hunks', 'added-lines')] [string]$ContentsMode = 'none',
    [int]$HunkLimit = 2,
    [int]$LinesPerHunk = 40,
    [int]$LinesPerCommit = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------- helpers ----------------

function Exec-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

    if (-not $Args -or $Args.Count -eq 0 -or -not (($Args -join ' ').Trim())) {
        $caller = (Get-PSCallStack | Select-Object -Skip 1 -First 1).Command
        throw "Exec-Git was called with NO arguments (caller: $caller)."
    }

    $repoPath = (Resolve-Path $Repo).Path
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git.exe"
    $psi.WorkingDirectory = $repoPath
    $psi.Arguments = ($Args -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    try {
        $p = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        throw "Unable to start Git. Is it installed and on PATH? Error: $($_.Exception.Message)"
    }

    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    if ($p.ExitCode -ne 0) {
        $cmd = "git " + ($Args -join ' ')
        $msg = if ($err.Trim()) {
            $err.Trim() 
        }
        else {
            "(no stderr; invalid repo path or arguments?)" 
        }
        throw "Command failed ($($p.ExitCode)): `"$cmd`" in `"$repoPath`"`n$msg"
    }

    return $out
}

function Get-OriginInfo {
    try {
        $url = (Exec-Git "remote", "get-url", "origin").Trim() 
    }
    catch {
        $url = $null 
    }
    if ($url -match "github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)(?:\.git)?$") {
        return @{ Url = $url; Host = "github.com"; Owner = $Matches.owner; Name = $Matches.repo; Type = "github" }
    }
    if ($url -match "gitlab\.com[:/](?<owner>.+)/(?<repo>[^/.]+)(?:\.git)?$") {
        return @{ Url = $url; Host = "gitlab.com"; Owner = $Matches.owner; Name = $Matches.repo; Type = "gitlab" }
    }
    return @{ Url = $url; Host = $null; Owner = $null; Name = $null; Type = $null }
}

function Make-CompareLink($origin, $base, $head) {
    if (-not $origin.Type) {
        return $null 
    }
    switch ($origin.Type) {
        "github" {
            "https://$($origin.Host)/$($origin.Owner)/$($origin.Name)/compare/$base...$head" 
        }
        "gitlab" {
            "https://$($origin.Host)/$($origin.Owner)/$($origin.Name)/-/compare/$base...$head" 
        }
        default {
            $null 
        }
    }
}

function Make-CommitLink($origin, $sha) {
    if (-not $origin.Type) {
        return $null 
    }
    switch ($origin.Type) {
        "github" {
            "https://$($origin.Host)/$($origin.Owner)/$($origin.Name)/commit/$sha" 
        }
        "gitlab" {
            "https://$($origin.Host)/$($origin.Owner)/$($origin.Name)/-/commit/$sha" 
        }
        default {
            $null 
        }
    }
}

function Link-IssueRefs($origin, [string]$text) {
    if (-not $text) {
        return $text 
    }
    if (-not $origin.Type) {
        return $text 
    }
    $re = [regex]::new('(?<!\w)#(?<num>\d+)', 'IgnoreCase')
    switch ($origin.Type) {
        "github" {
            return $re.Replace($text, ('[#${num}](https://{0}/{1}/{2}/issues/${num})' -f $origin.Host, $origin.Owner, $origin.Name))
        }
        "gitlab" {
            return $re.Replace($text, ('[#${num}](https://{0}/{1}/{2}/-/issues/${num})' -f $origin.Host, $origin.Owner, $origin.Name))
        }
        default {
            return $text 
        }
    }
}

function Get-CommitList {
    $list = (Exec-Git "rev-list", "--first-parent", "HEAD") -split "`n" | Where-Object { $_ -match '^[0-9a-f]{7,40}$' }
    if ($MaxCommits -gt 0) {
        $list = $list | Select-Object -First $MaxCommits 
    }
    , @($list)
}

# NUL-separated, subject only (robust for 5.1)
function Get-CommitMeta {
    param([string]$sha)
    $nullChar = [char]0
    $fmt = "%H%x00%P%x00%ad%x00%an%x00%s"
    $log = Exec-Git "log", "-n", "1", "--date=iso-strict", "--pretty=$fmt", "-z", $sha
    $parts = $log -split ([string]$nullChar)
    if (-not $parts -or $parts.Count -lt 4) {
        throw "Unexpected git log format for $sha (got $($parts.Count))." 
    }

    $shaVal = ($parts[0] | ForEach-Object { $_ })
    $parents = @()
    if ($parts.Count -ge 2 -and $parts[1]) {
        $parents = $parts[1] -split ' ' 
    }
    $dateVal = if ($parts.Count -ge 3) {
        $parts[2] 
    }
    else {
        "" 
    }
    $authorVal = if ($parts.Count -ge 4) {
        $parts[3] 
    }
    else {
        "" 
    }
    $subject = if ($parts.Count -ge 5) {
        $parts[4] 
    }
    else {
        "" 
    }

    New-Object psobject -Property @{
        Sha     = $shaVal
        Parents = $parents
        Date    = $dateVal
        Author  = $authorVal
        Subject = $subject
    }
}

function Get-DiffSummary {
    param([string]$sha)
    $short = (Exec-Git "diff-tree", "--root", "--no-commit-id", "--shortstat", "-r", $sha).Trim()
    if (-not $short) {
        return @{ Files = 0; Insertions = 0; Deletions = 0 } 
    }
    $files = if ($short -match "(\d+)\s+files?\s+changed") {
        [int]$Matches[1] 
    }
    else {
        0 
    }
    $ins = if ($short -match "(\d+)\s+insertions?\(\+\)") {
        [int]$Matches[1] 
    }
    else {
        0 
    }
    $del = if ($short -match "(\d+)\s+deletions?\(-\)") {
        [int]$Matches[1] 
    }
    else {
        0 
    }
    @{ Files = $files; Insertions = $ins; Deletions = $del }
}

function Parse-Conventional {
    param([string]$subject)
    if (-not $subject) {
        return @{ Type = "other"; Scope = $null; Breaking = $false; Desc = "" } 
    }
    $m = [regex]::Match($subject, '^(?<type>\w+)(\((?<scope>[^)]+)\))?(?<bang>!)?:\s*(?<desc>.+)$')
    if (-not $m.Success) { 
        return @{ Type = "other"; Scope = $null; Breaking = $false; Desc = $subject }
    }
    @{
        Type     = $m.Groups["type"].Value
        Scope    = $( if ($m.Groups["scope"].Success) {
                $m.Groups["scope"].Value 
            }
            else {
                $null 
            } )
        Breaking = $m.Groups["bang"].Success
        Desc     = $m.Groups["desc"].Value
    }
}

function Type-Emoji {
    param([string]$type, [bool]$breaking)
    if ($breaking) {
        return "💥" 
    }
    switch ($type) {
        "feat" {
            "✨" 
        }
        "fix" {
            "🐛" 
        }
        "docs" {
            "📝" 
        }
        "perf" {
            "🏎️" 
        }
        "refactor" {
            "♻️" 
        }
        "test" {
            "✅" 
        }
        "build" {
            "📦" 
        }
        "ci" {
            "🤖" 
        }
        "chore" {
            "🧹" 
        }
        default {
            "•" 
        }
    }
}

# --------- noise filtering & collapsing ---------
$GLOBAL:NoiseRegexes = @(
    '\[skip ci\]',
    '^\s*(chore|ci|build)\b.*(bump|version|beta|pack(\s|-)and(\s|-)push|yaml|workflow|github actions|nuspec|nuget\.config)',
    '^\s*(docs?)\b.*(readme|documentation|doc[s]?)',
    '^\s*update pack(\s|-)and(\s|-)push\.yml',
    '^\s*beta bump',
    '^\s*update project version',
    '^\s*sync version',
    '^\s*nuget packages',
    '^\s*update nuget packages',
    '^\s*upgrade nuget packages'
) | ForEach-Object { [regex]::new($_, 'IgnoreCase') }

$GLOBAL:CollapseSpecs = @(
    @{ Name = "Beta bumps"; Re = [regex]::new('^\s*beta bump', 'IgnoreCase') },
    @{ Name = "NuGet package updates"; Re = [regex]::new('^\s*(update|upgrade|upgrading)\s+nuget packages', 'IgnoreCase') },
    @{ Name = "CI / workflow tweaks"; Re = [regex]::new('^\s*(update\s+pack(\s|-)and(\s|-)push\.yml|github actions|workflow|yaml)', 'IgnoreCase') },
    @{ Name = "Docs churn"; Re = [regex]::new('^\s*(docs?|readme|documentation)', 'IgnoreCase') }
)

foreach ($pat in $ExcludeRegex) {
    $GLOBAL:NoiseRegexes += [regex]::new($pat, 'IgnoreCase') 
}
foreach ($pat in $CollapseRegex) {
    $GLOBAL:CollapseSpecs += @{ Name = $pat; Re = [regex]::new($pat, 'IgnoreCase') } 
}

function Should-SkipCommit([string]$subject) {
    if (-not $subject) {
        return $true 
    }
    foreach ($re in $GLOBAL:NoiseRegexes) {
        if ($re.IsMatch($subject)) {
            return $true 
        }
    }
    return $false
}

function Try-MatchCollapse([string]$subject) {
    foreach ($spec in $GLOBAL:CollapseSpecs) {
        if ($spec.Re.IsMatch($subject)) {
            return $spec.Name 
        }
    }
    return $null
}

# --------- tag helpers (annotated + lightweight) ---------
$script:TagCache = @{}      # sha -> [tags]
$script:TagAnno = @{}      # tag -> subject/title

function Get-TagsForCommit([string]$sha) {
    if ($script:TagCache.ContainsKey($sha)) {
        return $script:TagCache[$sha] 
    }
    $tags = @()
    try {
        $out = Exec-Git "tag", "--points-at", $sha
        if ($out) {
            $tags = $out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
    }
    catch {
        $tags = @() 
    }
    $script:TagCache[$sha] = , @($tags)
    return $script:TagCache[$sha]
}

function Get-TagTitle([string]$tag) {
    if (-not $tag) {
        return "" 
    }
    if ($script:TagAnno.ContainsKey($tag)) {
        return $script:TagAnno[$tag] 
    }
    $title = ""
    try {
        $res = Exec-Git "for-each-ref", "refs/tags/$tag", "--format=%(subject)"
        if ($res) {
            $title = (($res -split "`n")[0]).Trim() 
        }
    }
    catch {
        $title = "" 
    }
    $script:TagAnno[$tag] = $title
    return $title
}

# ---------------- start ----------------
try {
    $null = Exec-Git "rev-parse", "--git-dir" 
}
catch {
    throw "Not a git repository (or not accessible): $Repo`n$($_.Exception.Message)" 
}

$origin = Get-OriginInfo
$commits = Get-CommitList

# Stub if no commits
if (-not $commits -or $commits.Count -eq 0) {
    if ([IO.Path]::IsPathRooted($Output)) {
        $fullPath = $Output
    }
    else {
        $fullPath = [IO.Path]::Combine((Resolve-Path $Repo).Path, $Output)
    }
    $dir = [IO.Path]::GetDirectoryName($fullPath)
    if ($dir -and -not (Test-Path $dir)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null 
    }
    [IO.File]::WriteAllText($fullPath, "# Release Notes`n`n_No commits found_`n", (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Release notes written (no commits): $fullPath"
    return
}

# Progress
$total = $commits.Count
$i = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$progressEvery = [math]::Max([int]([math]::Ceiling(($total) / 100.0)), 1)

# Bucketing
$currentBucket = New-Object System.Collections.Generic.List[object]
$sections = New-Object System.Collections.Generic.List[object]
$seenTags = New-Object System.Collections.Generic.HashSet[string]
$stopNow = $false
$script:collapseTally = @{}

foreach ($sha in $commits) {
    if ($stopNow) {
        break 
    }
    $i++

    if ($ShowProgress -and (($i % $progressEvery) -eq 0 -or $i -eq $total)) {
        $pct = if ($total -gt 0) {
            [int](($i * 100.0) / $total) 
        }
        else {
            0 
        }
        $shortShaDisp = if ($sha -and $sha.Length -ge 7) {
            $sha.Substring(0, 7) 
        }
        else {
            (if ($sha) { $sha } else { "" }) 
        }
        $eta = if ($i -gt 5) {
            $avgMs = $sw.Elapsed.TotalMilliseconds / [math]::Max($i, 1)
            [TimeSpan]::FromMilliseconds($avgMs * ($total - $i))
        }
        else {
            [TimeSpan]::Zero 
        }
        Write-Progress -Activity "Generating release notes" `
            -Status ("Commit {0}/{1} · {2} · ETA {3:hh\:mm\:ss}" -f $i, $total, $shortShaDisp, $eta) `
            -PercentComplete $pct `
            -CurrentOperation "Analyzing commit $shortShaDisp"
    }

    try {
        $meta = Get-CommitMeta -sha $sha 
    }
    catch {
        Write-Warning ("Skipping commit {0}: {1}" -f ($sha.Substring(0, [Math]::Min(7, $sha.Length))), $_.Exception.Message); continue 
    }
    if (-not $IncludeMerges -and $meta.Parents.Count -gt 1) {
        continue 
    }

    # Filters
    if (-not $IncludeNoise) {
        if (Should-SkipCommit $meta.Subject) {
            continue 
        }
        $collapseKey = Try-MatchCollapse $meta.Subject
        if ($collapseKey) {
            if (-not $script:collapseTally.ContainsKey($collapseKey)) {
                $script:collapseTally[$collapseKey] = 0 
            }
            $script:collapseTally[$collapseKey] = [int]$script:collapseTally[$collapseKey] + 1
            continue
        }
    }

    $diff = Get-DiffSummary -sha $sha
    $conv = Parse-Conventional -subject $meta.Subject
    $emoji = Type-Emoji -type $conv.Type -breaking $conv.Breaking
    $scope = if ($conv.Scope) {
        "**($($conv.Scope))** " 
    }
    else {
        "" 
    }

    $shortSha = if ($meta.Sha -and $meta.Sha.Length -ge 7) {
        $meta.Sha.Substring(0, 7) 
    }
    else {
        $meta.Sha 
    }
    $bt = [char]96
    $mdSha = "$bt$shortSha$bt"

    # Optional author/date suffix
    $dateShort = ""
    if ($ShowAuthorAndDate) {
        try {
            $dateShort = [datetime]::Parse($meta.Date).ToString("yyyy-MM-dd") 
        }
        catch {
            $dateShort = $meta.Date 
        }
    }
    $suffix = ""
    if ($ShowAuthorAndDate -and $meta.Author) {
        if ($dateShort) {
            $suffix = " · $($meta.Author), $dateShort" 
        }
        else {
            $suffix = " · $($meta.Author)" 
        }
    }
    elseif ($ShowAuthorAndDate -and $dateShort) {
        $suffix = " · $dateShort"
    }

    # Link commit if origin known
    $commitUrl = $null
    if ($origin.Type) {
        $commitUrl = Make-CommitLink $origin $meta.Sha 
    }

    $descText = if ($conv.Type -eq "other") {
        $meta.Subject 
    }
    else {
        "$scope$($conv.Desc)" 
    }
    $descText = Link-IssueRefs $origin $descText

    $lineCore = "- $emoji $descText — $mdSha · +$($diff.Insertions)/-$($diff.Deletions) in $($diff.Files) file(s)$suffix"
    $line = if ($commitUrl) {
        $mdShaLinked = "[$mdSha]($commitUrl)"
        $lineCore -replace [regex]::Escape($mdSha), $mdShaLinked
    }
    else {
        $lineCore
    }

    $currentBucket.Add((New-Object psobject -Property @{
                Sha        = $meta.Sha
                ShortSha   = $shortSha
                Line       = $line
                Date       = $meta.Date
                Author     = $meta.Author
                Type       = $conv.Type
                Breaking   = $conv.Breaking
                Files      = $diff.Files
                Insertions = $diff.Insertions
                Deletions  = $diff.Deletions
            }))

    # Seal on tags
    $tagsForCommit = Get-TagsForCommit $meta.Sha
    if ($tagsForCommit.Count -gt 0) {
        foreach ($t in $tagsForCommit) {
            if ($SinceTag -and $t -eq $SinceTag) {
                $stopNow = $true; break 
            }
            if (-not $seenTags.Contains($t)) {
                $seenTags.Add($t) | Out-Null
                $sections.Add((New-Object psobject -Property @{
                            Kind      = "tag"
                            Name      = $t
                            Title     = (Get-TagTitle $t)
                            Commits   = [System.Collections.Generic.List[object]]($currentBucket | ForEach-Object { $_ })
                            Collapses = $script:collapseTally
                        }))
                $script:collapseTally = @{}
            }
        }
        $currentBucket.Clear()
        if ($UntilTag -and ($tagsForCommit -contains $UntilTag)) {
            $stopNow = $true 
        }
    }
}

if ($currentBucket.Count -gt 0 -or $sections.Count -eq 0) {
    # if nothing sealed yet, everything is Unreleased
    $sections.Add((New-Object psobject -Property @{ Kind = "unreleased"; Name = "Unreleased"; Title = ""; Commits = $currentBucket; Collapses = $script:collapseTally }))
    $script:collapseTally = @{}
}

if ($ShowProgress) {
    Write-Progress -Activity "Generating release notes" -Completed -Status "Done" 
}

# ---------------- compose markdown ----------------

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Release Notes")
[void]$sb.AppendLine()

# top-level compare (first tag..HEAD)
$firstTagObj = $sections | Where-Object { $_.Kind -eq 'tag' } | Select-Object -First 1
$firstTag = if ($firstTagObj) {
    $firstTagObj.Name 
}
else {
    $null 
}
if ($origin.Type -and $firstTag) {
    $headToFirst = Make-CompareLink $origin $firstTag "HEAD"
    if ($headToFirst) {
        [void]$sb.AppendLine("> Compare: [$firstTag…HEAD]($headToFirst)")
        [void]$sb.AppendLine()
    }
}

function Render-SectionHeader {
    param($sec, [int]$index, $sectionsRef, $sbRef, $originRef)

    if ($sec.Kind -eq "tag") {
        if ($sec.Title) {
            [void]$sbRef.AppendLine("## $($sec.Name) — $($sec.Title)") 
        }
        else {
            [void]$sbRef.AppendLine("## $($sec.Name)") 
        }
    }
    elseif ($sec.Kind -eq "unreleased") {
        [void]$sbRef.AppendLine("## Unreleased")
    }
    else {
        [void]$sbRef.AppendLine("## Older")
    }

    if ($sec.Commits.Count -gt 0) {
        $dates = @()
        foreach ($c in $sec.Commits) {
            if ($c.Date) {
                $dates += [datetime]::Parse($c.Date) 
            }
        }
        $minDate = $null; $maxDate = $null
        if ($dates.Count -gt 0) {
            $minDate = ($dates | Sort-Object | Select-Object -First 1)
            $maxDate = ($dates | Sort-Object -Descending | Select-Object -First 1)
        }

        $totalCommits = $sec.Commits.Count
        $totalFiles = ($sec.Commits | Measure-Object -Property Files -Sum).Sum
        $totalIns = ($sec.Commits | Measure-Object -Property Insertions -Sum).Sum
        $totalDel = ($sec.Commits | Measure-Object -Property Deletions -Sum).Sum

        $dateRange = ""
        if ($minDate -and $maxDate) {
            $dateRange = ("{0:yyyy-MM-dd} → {1:yyyy-MM-dd}" -f $minDate, $maxDate) 
        }

        [void]$sbRef.AppendLine()
        [void]$sbRef.AppendLine("| Summary | Value |")
        [void]$sbRef.AppendLine("|---|---:|")
        [void]$sbRef.AppendLine(("| Commits | {0} |" -f $totalCommits))
        [void]$sbRef.AppendLine(("| Files changed | {0} |" -f $totalFiles))
        [void]$sbRef.AppendLine(("| Insertions (+) | {0} |" -f $totalIns))
        [void]$sbRef.AppendLine(("| Deletions (-) | {0} |" -f $totalDel))
        if ($dateRange) {
            [void]$sbRef.AppendLine(("| Date range | {0} |" -f $dateRange)) 
        }

        $authors = $sec.Commits | ForEach-Object { $_.Author } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending
        if ($authors.Count -gt 0) {
            $topN = [math]::Min($authors.Count, [math]::Max(1, $MaxContributors))
            $names = @()
            for ($k = 0; $k -lt $topN; $k++) {
                $names += ("{0} ({1})" -f $authors[$k].Name, $authors[$k].Count) 
            }
            [void]$sbRef.AppendLine(("| Contributors | {0} |" -f ([string]::Join(", ", $names))))
        }
        [void]$sbRef.AppendLine()
    }
    else {
        [void]$sbRef.AppendLine()
    }

    if ($sec.Kind -eq "tag" -and $originRef.Type) {
        $prevTag = $null
        for ($j = $index + 1; $j -lt $sectionsRef.Count; $j++) {
            if ($sectionsRef[$j].Kind -eq 'tag') {
                $prevTag = $sectionsRef[$j].Name; break 
            }
        }
        $base = if ($prevTag) {
            $prevTag 
        }
        else {
            "$($sec.Name)^" 
        }
        $cmp = Make-CompareLink $originRef $base $sec.Name
        if ($cmp) {
            [void]$sbRef.AppendLine("_Changes since **$base**_: [$base…$($sec.Name)]($cmp)`n") 
        }
    }

    if ($sec.PSObject.Properties.Name -contains 'Collapses' -and $sec.Collapses) {
        $any = $false
        foreach ($k in $sec.Collapses.Keys) {
            $count = [int]$sec.Collapses[$k]
            if ($count -gt 0) {
                [void]$sbRef.AppendLine("- **$k**: $count changes")
                $any = $true
            }
        }
        if ($any) {
            [void]$sbRef.AppendLine() 
        }
    }
}

function Render-Group {
    param(
        [string]$title,
        [System.Collections.Generic.List[object]]$items,
        [System.Text.StringBuilder]$sbRef,
        [System.Collections.Generic.HashSet[string]]$highlightSet,
        [int]$maxHighlights = 0
    )
    if (-not $items -or $items.Count -eq 0) { return }

    $total = $items.Count
    [void]$sbRef.AppendLine("### $title ($total)")

    $limit = if ($maxHighlights -gt 0) {
        [Math]::Min($maxHighlights, $total)
    } else {
        $total
    }

    for ($i = 0; $i -lt $limit; $i++) {
        $line = [string]$items[$i]
        if ($highlightSet) { $null = $highlightSet.Add($line) }
        [void]$sbRef.AppendLine($line)
    }

    if ($total -gt $limit) {
        $remaining = $total - $limit
        $suffix = if ($remaining -eq 1) { "commit" } else { "commits" }
        [void]$sbRef.AppendLine("- _...and $remaining more ${suffix}_")
    }

    [void]$sbRef.AppendLine()
}

# Render all sections
for ($s = 0; $s -lt $sections.Count; $s++) {
    $sec = $sections[$s]
    Render-SectionHeader -sec $sec -index $s -sectionsRef $sections -sbRef $sb -originRef $origin

    if ($sec.Commits.Count -eq 0 -and (-not $sec.Collapses -or $sec.Collapses.Keys.Count -eq 0)) {
        [void]$sb.AppendLine("_No changes_`n")
        continue
    }

    $groups = @{
        "Breaking" = New-Object System.Collections.Generic.List[object]
        "Added"    = New-Object System.Collections.Generic.List[object]
        "Fixed"    = New-Object System.Collections.Generic.List[object]
        "Changed"  = New-Object System.Collections.Generic.List[object]
        "Docs"     = New-Object System.Collections.Generic.List[object]
        "CI"       = New-Object System.Collections.Generic.List[object]
        "Chore"    = New-Object System.Collections.Generic.List[object]
        "Other"    = New-Object System.Collections.Generic.List[object]
    }

    foreach ($c in $sec.Commits) {
        if ($c.Breaking) {
            $groups["Breaking"].Add($c.Line); continue 
        }
        switch ($c.Type) {
            'feat' {
                $groups["Added"].Add($c.Line) 
            }
            'fix' {
                $groups["Fixed"].Add($c.Line) 
            }
            'perf' {
                $groups["Changed"].Add($c.Line) 
            }
            'refactor' {
                $groups["Changed"].Add($c.Line) 
            }
            'docs' {
                $groups["Docs"].Add($c.Line) 
            }
            'ci' {
                $groups["CI"].Add($c.Line) 
            }
            'build' {
                $groups["CI"].Add($c.Line) 
            }
            'chore' {
                $groups["Chore"].Add($c.Line) 
            }
            default {
                $groups["Other"].Add($c.Line) 
            }
        }
    }

    $highlightedLines = New-Object 'System.Collections.Generic.HashSet[string]'

    Render-Group "Breaking" $groups["Breaking"] $sb $highlightedLines $MaxHighlights
    Render-Group "Added"    $groups["Added"]    $sb $highlightedLines $MaxHighlights
    Render-Group "Fixed"    $groups["Fixed"]    $sb $highlightedLines $MaxHighlights
    Render-Group "Changed"  $groups["Changed"]  $sb $highlightedLines $MaxHighlights
    Render-Group "Docs"     $groups["Docs"]     $sb $highlightedLines $MaxHighlights
    Render-Group "CI"       $groups["CI"]       $sb $highlightedLines $MaxHighlights
    Render-Group "Chore"    $groups["Chore"]    $sb $highlightedLines $MaxHighlights
    Render-Group "Other"    $groups["Other"]    $sb $highlightedLines $MaxHighlights

    # -------- Optional: file lists & diff snippets for printed commits --------
    if ($IncludeFiles -or $IncludeSnippets) {
        $btLocal = [char]96

        foreach ($commit in $sec.Commits) {
            # Only enrich commits that were actually highlighted
            if (-not $highlightedLines.Contains($commit.Line)) {
                continue 
            }

            # Files (name/status)
            if ($IncludeFiles) {
                $fOut = Exec-Git "show", "--name-status", "--no-patch", "--pretty=format:''", $commit.Sha
                if ($fOut) {
                    $rows = @()
                    foreach ($ln in ($fOut -split "`n")) {
                        $t = $ln.Trim(); if (-not $t) {
                            continue 
                        }
                        $parts = $t -split "`t"
                        if ($parts.Count -ge 2) {
                            $rows += , @{ Status = $parts[0]; Path = $parts[1] } 
                        }
                    }
                    if ($rows.Count -gt 0) {
                        $files = $rows | Select-Object -First $FileLimit
                        $more = [Math]::Max($rows.Count - $files.Count, 0)
                        $fileNames = New-Object System.Collections.Generic.List[string]
                        foreach ($r in $files) {
                            $fileNames.Add("$btLocal$($r.Path)$btLocal") 
                        }
                        $fileStr = [string]::Join(", ", $fileNames.ToArray())
                        if ($more -gt 0) {
                            $fileStr = "$fileStr _(+$more more)_" 
                        }
                        [void]$sb.AppendLine("  - Files: $fileStr")
                    }
                }
            }

            # Diff snippets
            if ($IncludeSnippets -and $ContentsMode -ne 'none') {
                $u = [Math]::Max($LinesPerHunk, 0)
                $dOut = Exec-Git "show", "--unified=$u", "--pretty=format:''", $commit.Sha
                if ($dOut) {
                    $hunks = @()
                    $currentFile = $null
                    $current = $null
                    $lineCount = 0
                    $perFileHunks = @{}

                    foreach ($ln in ($dOut -split "`n")) {
                        if ($lineCount -ge $LinesPerCommit) {
                            break 
                        }
                        if ($ln.StartsWith('diff --git')) {
                            if ($current) {
                                $hunks += , $current; $current = $null 
                            }
                            if ($ln -match ' b/(.+)$') {
                                $currentFile = $Matches[1] 
                            }
                            else {
                                $currentFile = $null 
                            }
                        }
                        elseif ($ln.StartsWith('@@') -and $currentFile) {
                            if (-not $perFileHunks.ContainsKey($currentFile)) {
                                $perFileHunks[$currentFile] = 0 
                            }
                            if ($perFileHunks[$currentFile] -ge $HunkLimit) {
                                continue 
                            }
                            if ($current) {
                                $hunks += , $current 
                            }
                            $current = [pscustomobject]@{ File = $currentFile; Header = $ln; Lines = @() }
                            $perFileHunks[$currentFile]++
                        }
                        elseif ($current -and ($ln.StartsWith('+') -or $ln.StartsWith('-') -or $ln.StartsWith(' '))) {
                            if ($current.Lines.Count -lt $LinesPerHunk) {
                                if ($ContentsMode -eq 'added-lines' -and -not $ln.StartsWith('+')) {
                                    continue 
                                }
                                $current.Lines += , $ln
                                $lineCount++
                            }
                        }
                    }
                    if ($current) {
                        $hunks += , $current 
                    }

                    if ($hunks.Count -gt 0) {
                        [void]$sb.AppendLine('  ```diff')
                        $printedLines = 0
                        foreach ($hk in ($hunks | Select-Object -First $HunkLimit)) {
                            foreach ($l in ($hk.Lines | Select-Object -First $LinesPerHunk)) {
                                if ($printedLines -ge $LinesPerCommit) {
                                    break 
                                }
                                [void]$sb.AppendLine("  $l")
                                $printedLines++
                            }
                        }
                        [void]$sb.AppendLine('  ```')
                    }
                }
            }
        }

        [void]$sb.AppendLine()
    }
}

# Write output
if ([IO.Path]::IsPathRooted($Output)) {
    $fullPath = $Output
}
else {
    $fullPath = [IO.Path]::Combine((Resolve-Path $Repo).Path, $Output)
}
$dir = [IO.Path]::GetDirectoryName($fullPath)
if ($dir -and -not (Test-Path $dir)) {
    [IO.Directory]::CreateDirectory($dir) | Out-Null 
}
[IO.File]::WriteAllText($fullPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
Write-Host "Release notes written to $fullPath"
