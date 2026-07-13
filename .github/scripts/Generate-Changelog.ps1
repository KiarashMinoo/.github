#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generates (or prepends to) CHANGELOG.md for a new release, following the shared
    Changelog Generator Agent prompt (Conventional Commits categorization, Keep a Changelog
    sections, emoji headers). Shared across all repos via KiarashMinoo/.github.

.DESCRIPTION
    Resumes from the most recent v*.*.* tag reachable from HEAD (or the repository's first
    commit if no tag exists yet), walks the commits since then, categorizes each one by its
    Conventional Commits prefix (falling back to inferring the type from changed file paths
    when a subject doesn't follow that convention), and prepends a new "## [Version] - Date"
    section to CHANGELOG.md. Also writes the new section alone to -NotesPath so a release step
    can use it directly as a GitHub Release body without re-parsing the full changelog.

    Works the same way for both beta and release channels -- the tag graph (not the channel)
    determines the commit range, so a beta tag's changelog section only covers what changed
    since the previous tag (beta or release), and likewise for a release tag.

    Supersedes the older ad-hoc generate-changelog.ps1 that lived in this file (full-history
    rebuild with a managed HTML-comment block and a JSON state file) -- that one was never
    wired into any reusable workflow. This version is the one actually invoked by
    reusable-ci.yml, modeled on IIIF.Manifest.Serializer.Net's scripts/generate-changelog.ps1.

.PARAMETER Version
    The new version being released, without a leading "v" (e.g. "3.0.3" or "3.0.3-beta.2").

.PARAMETER ChangelogPath
    Path to the changelog file to update. Defaults to CHANGELOG.md at the repo root.

.PARAMETER NotesPath
    Path to write the new section's content to on its own, for use as a release body.
    Defaults to release-notes.md at the repo root.

.EXAMPLE
    ./.github/scripts/generate-changelog.ps1 -Version 3.0.3
.EXAMPLE
    ./.github/scripts/generate-changelog.ps1 -Version 3.0.3-beta.2
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(-.+)?$')]
    [string]$Version,

    [string]$ChangelogPath,

    [string]$NotesPath
)

$ErrorActionPreference = "Stop"

$repoRoot = (git rev-parse --show-toplevel).Trim()
if (-not $ChangelogPath) { $ChangelogPath = Join-Path $repoRoot "CHANGELOG.md" }
if (-not $NotesPath) { $NotesPath = Join-Path $repoRoot "release-notes.md" }

# --- Determine the commit range to cover: since the last v*.*.* tag reachable from HEAD, or
#     the whole history if this is the first release. This deliberately uses the tag graph
#     rather than a checked-in state file, so nothing needs to be persisted across releases -
#     the previous tag *is* the state. Matches both release tags (v1.2.3) and beta tags
#     (v1.2.3-beta.4). ---
$previousTag = $null
try {
    $previousTag = (git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>$null).Trim()
    if ($LASTEXITCODE -ne 0) { $previousTag = $null }
} catch {
    $previousTag = $null
}

if ($previousTag) {
    $range = "$previousTag..HEAD"
    Write-Host "Resuming from previous tag $previousTag" -ForegroundColor Cyan
} else {
    $range = "HEAD"
    Write-Host "No previous v*.*.* tag found - generating changelog from the first commit" -ForegroundColor Cyan
}

# --- Collect commits (oldest first, merges excluded - a merge commit carries no diff of its
#     own and its constituent commits are already listed individually). ---
$sep = [char]0x1f
$logFormat = "%H$sep%h$sep%an$sep%s"
$rawCommits = git log --no-merges --reverse --format=$logFormat $range
if (-not $rawCommits) {
    Write-Host "No new commits since $(if ($previousTag) { $previousTag } else { 'the first commit' }) - nothing to add." -ForegroundColor Yellow
}

$sectionOrder = @(
    @{ Key = "feat"; Title = "Features"; Emoji = "🚀" }
    @{ Key = "fix"; Title = "Bug Fixes"; Emoji = "🐛" }
    @{ Key = "perf"; Title = "Performance"; Emoji = "⚡" }
    @{ Key = "refactor"; Title = "Refactoring"; Emoji = "♻️" }
    @{ Key = "deps"; Title = "Dependencies"; Emoji = "📦" }
    @{ Key = "ci"; Title = "CI / Tooling"; Emoji = "⚙️" }
    @{ Key = "docs"; Title = "Documentation"; Emoji = "📝" }
    @{ Key = "test"; Title = "Tests"; Emoji = "🧪" }
    @{ Key = "chore"; Title = "Chores"; Emoji = "🏠" }
)

$conventionalMap = @{
    feat     = "feat"
    fix      = "fix"
    perf     = "perf"
    refactor = "refactor"
    docs     = "docs"
    test     = "test"
    tests    = "test"
    build    = "ci"
    ci       = "ci"
    chore    = "chore"
    style    = "chore"
    revert   = "chore"
}

function Get-ChangedFiles([string]$Sha) {
    return (git diff-tree --no-commit-id --name-only -r $Sha) -split "`n" | Where-Object { $_ }
}

function Get-CommitCategory([string]$Sha, [string]$Subject) {
    # Strip a leading "[RepoName#123] " issue-reference tag, e.g. "[IIIF.Manifest.Serializer.Net#13] SDK Phase 7: ..."
    $Subject = $Subject -replace '^\[[^\]]*\]\s*', ''

    if ($Subject -match '^(?<type>\w+)(\([^)]*\))?!?:\s*(?<rest>.+)$' -and $conventionalMap.ContainsKey($Matches.type.ToLowerInvariant())) {
        return @{ Category = $conventionalMap[$Matches.type.ToLowerInvariant()]; CleanSubject = $Matches.rest }
    }

    $files = Get-ChangedFiles $Sha
    $category = $null

    # Note: test/docs/deps require *every* changed file to match - a commit that mixes real
    # source changes with incidental test or doc updates (extremely common) should be
    # classified by its actual content, not by the fact that it also touched a test file.
    if ($files.Count -gt 0 -and ($files | Where-Object { $_ -match 'Directory\.Packages\.props$' }).Count -eq $files.Count) {
        $category = "deps"
    } elseif ($files | Where-Object { $_ -match '^\.github/workflows/' -or $_ -match '^scripts/' -or $_ -match '(^|/)Dockerfile$' }) {
        $category = "ci"
    } elseif ($files.Count -gt 0 -and ($files | Where-Object { $_ -match '(^|/)[^/]*Tests?[./]' -or $_ -match '^tests/' }).Count -eq $files.Count) {
        $category = "test"
    } elseif ($files.Count -gt 0 -and ($files | Where-Object { $_ -match '\.md$' -and $_ -notmatch '^CHANGELOG\.md$' }).Count -eq $files.Count) {
        $category = "docs"
    } elseif ($Subject -match '(?i)\bfix(e[sd])?\b') {
        $category = "fix"
    } elseif ($Subject -match '(?i)\brefactor') {
        $category = "refactor"
    } elseif ($files | Where-Object { $_ -match '^(src|extensions|core)/' }) {
        $category = "feat"
    } else {
        $category = "chore"
    }

    return @{ Category = $category; CleanSubject = $Subject }
}

function Get-DependencyRows([string]$Sha) {
    $diff = git show $Sha -- ':(glob)**/Directory.Packages.props'
    if (-not $diff) { return @() }

    $rows = [ordered]@{}
    $removed = @{}
    foreach ($line in $diff) {
        if ($line -match '^-\s*<PackageVersion Include="(?<id>[^"]+)" Version="(?<ver>[^"]+)"') {
            $removed[$Matches.id] = $Matches.ver
        } elseif ($line -match '^\+\s*<PackageVersion Include="(?<id>[^"]+)" Version="(?<ver>[^"]+)"') {
            $id = $Matches.id
            $newVer = $Matches.ver
            $oldVer = if ($removed.ContainsKey($id)) { $removed[$id] } else { "-" }
            $rows[$id] = "| $id | $oldVer | $newVer |"
        }
    }
    return $rows.Values
}

$buckets = @{}
foreach ($section in $sectionOrder) { $buckets[$section.Key] = New-Object System.Collections.Generic.List[string] }
$dependencyRows = New-Object System.Collections.Generic.List[string]

$commitCount = 0
foreach ($line in $rawCommits) {
    if (-not $line) { continue }
    $parts = $line -split [regex]::Escape([string]$sep)
    if ($parts.Count -lt 4) { continue }
    $fullSha, $shortSha, $author, $subject = $parts
    $commitCount++

    $classified = Get-CommitCategory -Sha $fullSha -Subject $subject
    $cleanSubject = $classified.CleanSubject.TrimEnd('.', ' ')
    $buckets[$classified.Category].Add("- $cleanSubject ``($shortSha)`` — $author")

    if ($classified.Category -eq "deps") {
        foreach ($row in (Get-DependencyRows $fullSha)) { $dependencyRows.Add($row) }
    }
}

# --- Compose the new section ---
$date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("## [$Version] — $date")
$lines.Add("")

foreach ($section in $sectionOrder) {
    $entries = $buckets[$section.Key]
    if ($entries.Count -eq 0) { continue }

    $lines.Add("### $($section.Emoji) $($section.Title)")
    $lines.Add("")

    if ($section.Key -eq "deps" -and $dependencyRows.Count -gt 0) {
        $lines.Add("| Package | Old | New |")
        $lines.Add("|---------|-----|-----|")
        foreach ($row in ($dependencyRows | Select-Object -Unique)) { $lines.Add($row) }
        $lines.Add("")
    }

    foreach ($entry in $entries) { $lines.Add($entry) }
    $lines.Add("")
}

if ($commitCount -eq 0) {
    $lines.Add("_No user-facing changes in this release._")
    $lines.Add("")
}

$newSection = ($lines -join "`n").TrimEnd() + "`n"
Set-Content -Path $NotesPath -Value $newSection -NoNewline

if (Test-Path $ChangelogPath) {
    $existing = Get-Content $ChangelogPath -Raw
    # Insert after the standing header/intro (everything up to and including the first blank
    # line that precedes a "## [" section, or the whole file if there are no prior sections yet).
    $headerEnd = $existing.IndexOf("`n## [")
    if ($headerEnd -lt 0) {
        $header = $existing.TrimEnd() + "`n`n"
        $rest = ""
    } else {
        $header = $existing.Substring(0, $headerEnd + 1)
        $rest = $existing.Substring($headerEnd + 1)
    }
    $combined = $header + $newSection + "`n" + $rest
} else {
    $intro = "# Changelog`n`nAll notable changes to this project will be documented in this file.`nFormat follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).`n`n"
    $combined = $intro + $newSection
}

Set-Content -Path $ChangelogPath -Value $combined.TrimEnd("`n") -NoNewline
Add-Content -Path $ChangelogPath -Value "`n"

Write-Host "`nProcessed $commitCount commit(s) into $ChangelogPath (range: $range)." -ForegroundColor Green
