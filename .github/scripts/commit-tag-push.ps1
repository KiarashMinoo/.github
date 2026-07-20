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

# Keep .ci-scripts (checked out separately by the caller workflow for the shared helper
# scripts, with its own nested .git) out of every commit. Left alone, git silently records
# it as an "embedded repository" gitlink the moment `git add -A` sees it -- which then
# breaks actions/checkout's own post-job submodule cleanup on every subsequent checkout in
# the run ("fatal: No url found for submodule path '.ci-scripts' in .gitmodules", surfaced
# as a `##[warning]` annotation).
#
# A prior version of this script tried to detect-and-untrack it AFTER `git add -A` (via
# `git ls-files --error-unmatch` + `git rm -r --cached`, with output silenced by `*>
# $null` and its exit code never checked) -- in practice that `git rm` did not reliably
# take effect (observed live: .ci-scripts still showed up as `create mode 160000
# .ci-scripts` in the resulting commit), because failures were being swallowed silently.
# Two changes, applied BEFORE `git add -A` this time so .ci-scripts is never staged in
# the first place:
#   1) Add .ci-scripts to .git/info/exclude (a local-only, never-committed ignore rule)
#      so `git add -A` skips it outright instead of racing to untrack it afterwards.
#   2) Unconditionally run `git rm -r --cached --ignore-unmatch .ci-scripts` first, in
#      case an earlier buggy run already committed it as a gitlink sometime in this
#      branch's history -- `--ignore-unmatch` makes this a safe no-op when it was never
#      tracked, so it doesn't need its own exit-code check.
$excludeFile = '.git/info/exclude'
$alreadyExcluded = (Test-Path $excludeFile) -and ((Get-Content $excludeFile -Raw) -match '(?m)^\.ci-scripts$')
if (-not $alreadyExcluded) {
    Add-Content -Path $excludeFile -Value '.ci-scripts'
}
& git rm -r --cached --ignore-unmatch .ci-scripts *> $null

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
        Write-Host "Tag $candidateTag already exists locally; skipping tag creation." -ForegroundColor Gray
        $tag = $candidateTag
    }
    else {
        $tagMsg = $TagMessage -replace '\{TAG\}', $candidateTag -replace '\{VERSION\}', $Version
        Write-Host "Creating tag $candidateTag"
        # Both `git tag` and `git push origin <tag>` can fail with an "already exists"
        # error even after the local rev-parse check above says the tag is missing --
        # e.g. a re-run whose local checkout is missing a tag that another run already
        # pushed to the remote in the meantime. Rather than hard-failing the whole run
        # over a tag that, for all practical purposes, already exists where it needs to
        # (the remote), pattern-match the git output for "already exists" and treat that
        # specific case as success and move on; any other failure still fails the run.
        $tagCreateOutput = & git tag -a "$candidateTag" -m "$tagMsg" 2>&1
        $tagCreateExit = $LASTEXITCODE
        if ($tagCreateExit -ne 0) {
            if ($tagCreateOutput -match 'already exists') {
                Write-Host "Tag $candidateTag already exists (created by another run); continuing." -ForegroundColor Gray
            }
            else {
                Write-Error "git tag failed (exit $tagCreateExit): $tagCreateOutput"
                exit 1
            }
        }
        Write-Host "Pushing tag $candidateTag..."
        $tagPushOutput = & git push origin "$candidateTag" 2>&1
        $tagPushExit = $LASTEXITCODE
        if ($tagPushExit -ne 0) {
            if ($tagPushOutput -match 'already exists') {
                Write-Host "Tag $candidateTag already exists on the remote; treating as success (idempotent re-run)." -ForegroundColor Gray
            }
            else {
                Write-Error "git push tag failed (exit $tagPushExit): $tagPushOutput"
                exit 1
            }
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
