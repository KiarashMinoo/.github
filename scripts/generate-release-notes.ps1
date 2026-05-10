<#
.SYNOPSIS
  Generate release notes from git history for CI/CD workflows.

.DESCRIPTION
  Generates filtered release notes by:
   - Extracting commit messages between commits
   - Excluding merge commits
   - Filtering out version bump/packageversion commits
   - Formatting as markdown bullet list

  Outputs to file and optionally to GITHUB_ENV for Actions.

.PARAMETER Before
  Starting commit (exclusive). If empty, uses last 50 commits.

.PARAMETER After
  Ending commit (inclusive). Defaults to HEAD.

.PARAMETER OutputFile
  File to write release notes to (default: release-notes.txt)

.PARAMETER SetGitHubEnv
  Write to GITHUB_ENV as REL_NOTES variable (escaped for Actions)

.EXAMPLE
  pwsh .github/scripts/generate-release-notes.ps1 -Before abc123 -After def456
  pwsh .github/scripts/generate-release-notes.ps1 -SetGitHubEnv
#>

param(
    [string]$Before,
    [string]$After = 'HEAD',
    [string]$OutputFile = 'release-notes.txt',
    [switch]$SetGitHubEnv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== Generate Release Notes ===" -ForegroundColor Cyan

# Get commit messages
$gitArgs = @('log', '--no-merges', '--format=%s')

if ($Before) {
    $gitArgs += "$Before..$After"
    Write-Host "Range: $Before..$After"
}
else {
    $gitArgs += '-n', '50', $After
    Write-Host "Range: Last 50 commits from $After"
}

$rawMessages = & git @gitArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Git log command failed. Using empty release notes."
    $rawMessages = @()
}

# Filter out version bump commits
$filterPattern = '(packageversion|package version|bump version|version bump|^bump\s|beta bump.*packageversion)'
$filteredMessages = $rawMessages | Where-Object { 
    $_ -and $_ -notmatch $filterPattern 
}

# Format as bullet list
$notes = $filteredMessages | ForEach-Object {
    $line = $_.Trim()
    if ($line) {
        "- $line" 
    }
}

# Default message if empty
if (-not $notes) {
    $notes = @('- No user-facing changes in this push.')
}

# Write to file
$notes | Out-File -FilePath $OutputFile -Encoding utf8 -NoNewline
Write-Host "Release notes written to: $OutputFile" -ForegroundColor Green
Write-Host ""
Write-Host "--- Release Notes ---" -ForegroundColor Yellow
$notes | ForEach-Object { Write-Host $_ }
Write-Host "---------------------" -ForegroundColor Yellow

# Set GitHub environment variable if requested
if ($SetGitHubEnv) {
    $githubEnv = $env:GITHUB_ENV
    if ($githubEnv) {
        # Escape for GitHub Actions (replace newlines with \n)
        $escaped = ($notes -join '\n')
        Add-Content -Path $githubEnv -Value "REL_NOTES=$escaped" -Encoding utf8
        Write-Host "`nSet GITHUB_ENV variable: REL_NOTES" -ForegroundColor Green
    }
    else {
        Write-Warning "GITHUB_ENV not set. Skipping environment variable."
    }
}

exit 0
