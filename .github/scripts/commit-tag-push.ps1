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

  Idempotency guard (runs first, before touching the working tree at all): the version
  job's checkout has no pinned `ref`, so it resolves to the fixed commit that originally
  triggered the run -- on a "Re-run all jobs" this checks out that SAME pre-bump commit
  again, every time, never the tip this script itself already pushed on a prior attempt.
  Left unchecked, that means a "Re-run all jobs" always recomputes the identical next
  version, tries to commit+push it again as a brand-new commit built on the stale base,
  and the push is rejected as non-fast-forward (the remote is already ahead, from the
  earlier successful attempt) -- or, if it somehow got past that, tag creation/push then
  fails because that tag already exists remotely. So before doing anything else, this
  script asks the remote directly (`git ls-remote`, no local fetch needed) whether the
  tag for -Version already exists: if it does, this exact version was already fully
  committed, pushed, and tagged by a previous attempt, so it just reports that existing
  commit/tag as this run's output and exits, without staging or pushing anything new.

  If that guard doesn't fire (genuinely new version, or a race with another run), it
  proceeds as before: commits once (skipped if nothing is staged), pushes to whatever
  branch triggered the workflow -- with a fallback if that push is itself rejected as
  non-fast-forward, in case another run pushed the identical change in the meantime --
  then tags the resulting commit (unless -SkipTag) and pushes the tag too, tolerating
  "already exists" on both the local pre-check and reactively on the git commands
  themselves.

  Outputs via GITHUB_OUTPUT: sha=<commit-sha>, tag=<tag-name, empty only if -SkipTag>,
  pushed=<true|false -- false whenever the idempotency guard above short-circuited or the
  push-conflict fallback adopted someone else's commit, since nothing new was pushed>.

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

function Write-Outputs([string]$Sha, [string]$Tag, [bool]$Pushed) {
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "sha=$Sha"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "tag=$Tag"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "pushed=$($Pushed.ToString().ToLower())"
    }
    else {
        Write-Host "sha=$Sha"
        Write-Host "tag=$Tag"
        Write-Host "pushed=$($Pushed.ToString().ToLower())"
    }
}

$branchName = (& git rev-parse --abbrev-ref HEAD).Trim()
$candidateTag = "$TagPrefix$Version"

# --- Idempotency guard: has a previous attempt already fully processed this version? ---
if (-not $SkipTag) {
    Write-Host "Checking origin directly for tag $candidateTag before doing anything else..."
    $lsRemoteOutput = @(& git ls-remote --exit-code --tags origin "refs/tags/$candidateTag" 2>&1)
    if ($LASTEXITCODE -eq 0) {
        # Tag already lives on the remote -- another attempt (an earlier try of this same
        # "Re-run all jobs", or a concurrent run) already committed, pushed, and tagged
        # this exact version. Don't redo any of that; just report its existing state.
        # An annotated tag's ls-remote output has two lines: the tag object itself, and a
        # second "...^{}" line dereferenced to the commit it actually points at -- prefer
        # that one; a lightweight tag only ever has the one line, which IS the commit.
        $derefLine = $lsRemoteOutput | Where-Object { $_ -match '\^\{\}\s*$' } | Select-Object -First 1
        $chosenLine = if ($derefLine) { $derefLine } else { $lsRemoteOutput | Select-Object -First 1 }
        $existingSha = ($chosenLine -split '\s+')[0]
        Write-Host "Tag $candidateTag already exists on the remote (commit $existingSha) -- this version was already fully processed by a previous attempt. Skipping commit/push/tag and reusing that state." -ForegroundColor Gray
        Write-Outputs -Sha $existingSha -Tag $candidateTag -Pushed $false
        exit 0
    }
    Write-Host "Tag $candidateTag not found on the remote -- proceeding normally."
}

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
    $pushOutput = & git push 2>&1
    $pushExit = $LASTEXITCODE
    if ($pushExit -ne 0) {
        # Rejected as non-fast-forward almost always means another attempt (a previous
        # try of this same re-run, or a concurrent run) already pushed while we were
        # working -- the idempotency guard above should normally catch that via the tag,
        # but only once a tag actually exists; this covers the narrower window where a
        # commit landed on the remote just before ours but before it got tagged yet.
        # Fetch and check whether the remote tip is the SAME change we were about to push
        # (identical tree) before deciding: if so, adopt it and carry on; if the remote
        # diverged for any other reason, this is a real conflict and should still fail
        # loudly rather than silently discarding whatever is actually on the remote.
        if ($pushOutput -match 'non-fast-forward|fetch first|behind') {
            Write-Host "Push rejected as non-fast-forward -- checking whether the remote already has this exact change..." -ForegroundColor Yellow
            & git fetch origin "refs/heads/$branchName" 2>&1 | Out-Null
            $remoteTip = (& git rev-parse "origin/$branchName").Trim()
            $localTree = (& git rev-parse 'HEAD^{tree}').Trim()
            $remoteTree = (& git rev-parse "$remoteTip^{tree}").Trim()
            if ($localTree -eq $remoteTree) {
                Write-Host "Remote HEAD ($remoteTip) already matches this exact change -- another attempt already pushed it. Adopting it and continuing." -ForegroundColor Gray
                & git reset --hard $remoteTip
                $pushed = $false
            }
            else {
                Write-Error "git push failed (exit $pushExit) and the remote has genuinely diverged (different content), not just a re-run collision: $pushOutput"
                exit 1
            }
        }
        else {
            Write-Error "git push failed (exit $pushExit): $pushOutput"
            exit 1
        }
    }
    else {
        $pushed = $true
    }
}

$tag = ''
if (-not $SkipTag) {
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
Write-Outputs -Sha $headSha -Tag $tag -Pushed $pushed

exit 0
