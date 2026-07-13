#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Commit whatever is currently modified on disk (version bump + CHANGELOG.md), push it to
  the executing branch, then create and push an annotated tag pointing at that commit.

.DESCRIPTION
  Used by reusable-ci.yml after update-version.ps1 (bump only, no -CommitAndTag) and
  generate-changelog.ps1 have both already run and left modified/new files on disk (the
  bumped Directory.Build.props/.csproj files, plus CHANGELOG.md). Since each caller job
  starts from a fresh checkout, the working tree is guaranteed clean before those two
  scripts run -- so this script simply stages everything (`git add -A`) rather than
  requiring an explicit path list.

  Commits once (skipped if there's nothing staged, e.g. a re-run after the version was
  already bumped), pushes to whatever branch triggered the workflow, then tags the
  resulting commit (unless -SkipTag) and pushes the tag too. Tag creation is skipped
  gracefully if the tag already exists (idempotent re-runs).

  Outputs via GITHUB_OUTPUT: sha=<commit-sha>, tag=<tag-name, empty if -SkipTag or
  already existed... no, empty only if -SkipTag>, pushed=<true|false>.

.PARAMETER Version
  The new version being released (no leading "v"), used to build the tag name and
  substitute {VERSION}/{TAG} placeholders in -CommitMessage/-TagMessage.

.EXAMPLE
  pwsh .github/scripts/commit-tag-push.ps1 -Version 1.2.3
.EXAMPLE
  pwsh .github/scripts/commit-tag-push.ps1 -Version 1.2.3-beta.4 -TagMessage 'Beta {TAG}'
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$CommitMessage = 'chore: bump version to {VERSION} [skip ci]',
    [string]$TagPrefix = 'v',
    [string]$TagMessage = 'Release {TAG}',
    [switch]$SkipTag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& git config user.name "github-actions[bot]" 2>$null
& git config user.email "41898282+github-actions[bot]@users.noreply.github.com" 2>$null

& git add -A

# NOTE: `--cached` is a `git diff` option, not a `git status` one -- passing it here made
# every `git status` call fail with a usage error, which silently produced an EMPTY
# $porcelain every single time (native command stderr isn't captured by PowerShell here),
# so this always concluded "nothing to commit" and skipped the commit entirely, then went
# on to tag whatever the pre-existing HEAD was. Since `git add -A` already staged
# everything, plain `--porcelain` correctly reflects the staged changes.
$porcelain = (& git status --porcelain) -join "`n"
$pushed = $false
if ([string]::IsNullOrEmpty($porcelain)) {
    Write-Host "No staged changes to commit." -ForegroundColor Gray
}
else {
    $commitMsg = $CommitMessage -replace '\{VERSION\}', $Version
    Write-Host "Committing: $commitMsg"
    & git commit -m $commitMsg
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git commit failed (exit $LASTEXITCODE)"
        exit 1
    }
    Write-Host "Pushing commit to current branch..."
    & git push
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git push failed (exit $LASTEXITCODE)"
        exit 1
    }
    $pushed = $true
}

$tag = ''
if (-not $SkipTag) {
    $candidateTag = "$TagPrefix$Version"
    $null = & git rev-parse "$candidateTag" 2>$null
    $tagExists = ($LASTEXITCODE -eq 0)
    if ($tagExists) {
        Write-Host "Tag $candidateTag already exists; skipping tag creation." -ForegroundColor Gray
        $tag = $candidateTag
    }
    else {
        $tagMsg = $TagMessage -replace '\{TAG\}', $candidateTag -replace '\{VERSION\}', $Version
        Write-Host "Creating tag $candidateTag"
        & git tag -a "$candidateTag" -m "$tagMsg"
        if ($LASTEXITCODE -ne 0) {
            Write-Error "git tag failed (exit $LASTEXITCODE)"
            exit 1
        }
        Write-Host "Pushing tag $candidateTag..."
        & git push origin "$candidateTag"
        if ($LASTEXITCODE -ne 0) {
            Write-Error "git push tag failed (exit $LASTEXITCODE)"
            exit 1
        }
        $tag = $candidateTag
    }
}
else {
    Write-Host "Skipping tag creation (-SkipTag)." -ForegroundColor Gray
}

$headSha = (& git rev-parse HEAD).Trim()
if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "sha=$headSha"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "tag=$tag"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "pushed=$($pushed.ToString().ToLower())"
}
else {
    Write-Host "sha=$headSha"
    Write-Host "tag=$tag"
    Write-Host "pushed=$($pushed.ToString().ToLower())"
}

exit 0
