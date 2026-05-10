<#
.SYNOPSIS
  Build and pack .NET solution for CI/CD workflows.

.DESCRIPTION
  PowerShell script that handles:
   - Solution file discovery/validation
   - Platform normalization (AnyCpu -> "Any CPU")
   - Clean, Restore, Build, Pack operations
   - Release notes generation from git history
   - Artifact organization

  Used by GitHub Actions pack jobs.

.PARAMETER Configuration
  Build configuration (Debug or Release)

.PARAMETER Platform
  Platform target (AnyCpu, x86, x64, ARM64)

.PARAMETER SolutionPath
  Optional: explicit solution file path. If not provided, auto-discovers single .sln at repo root.

.PARAMETER OutputDir
  Directory for packed artifacts (default: artifacts/pkg)

.PARAMETER SkipClean
  Skip the clean step

.PARAMETER SkipRestore
  Skip the restore step

.PARAMETER SkipBuild
  Skip the build step

.PARAMETER ReleaseNotes
  Optional release notes to embed in packages

.EXAMPLE
  pwsh .github/scripts/pack-solution.ps1 -Configuration Release -Platform AnyCpu
  pwsh .github/scripts/pack-solution.ps1 -Configuration Debug -Platform x64 -SolutionPath MySolution.sln
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration,
    
    [Parameter(Mandatory = $true)]
    [ValidateSet('AnyCpu', 'x86', 'x64', 'ARM64')]
    [string]$Platform,
    
    [string]$SolutionPath,
    [string]$OutputDir = 'artifacts/pkg',
    [switch]$SkipClean,
    [switch]$SkipRestore,
    [switch]$SkipBuild,
    [string]$ReleaseNotes = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== .NET Solution Pack Script ===" -ForegroundColor Cyan
Write-Host "Configuration: $Configuration"
Write-Host "Platform: $Platform"

# Normalize platform for solution builds
$platformSol = if ($Platform -match '^[Aa]ny[Cc]pu$') { 
    'Any CPU' 
}
else { 
    $Platform 
}
Write-Host "Platform (normalized): $platformSol"

# Determine artifact suffix (used by workflow artifact names)
$artifactSuffix = if ($Platform -match '^[Aa]ny[Cc]pu$') { '' } else { "-$Platform" }

# Export platform and artifact suffix to GitHub Actions if available
if ($env:GITHUB_OUTPUT) {
  Add-Content -Path $env:GITHUB_OUTPUT -Value "platform_sol=$platformSol"
  Add-Content -Path $env:GITHUB_OUTPUT -Value "artifact_suffix=$artifactSuffix"
}

# Resolve solution file
if (-not $SolutionPath) {
  # Ensure the result is always an array so .Count works even when a single file is returned
  $slnFiles = @(Get-ChildItem -Filter '*.sln' -File | Select-Object -ExpandProperty Name)
  if ($slnFiles.Count -eq 0) {
    Write-Error "No .sln file found at repo root. Specify -SolutionPath."
    exit 1
  }
  elseif ($slnFiles.Count -gt 1) {
    Write-Error "Multiple .sln files found: $($slnFiles -join ', '). Specify -SolutionPath."
    exit 1
  }
  $SolutionPath = $slnFiles[0]
}

if (-not (Test-Path $SolutionPath)) {
    Write-Error "Solution file not found: $SolutionPath"
    exit 1
}

Write-Host "Solution: $SolutionPath" -ForegroundColor Green

# Clean
if (-not $SkipClean) {
    Write-Host "`n--- Clean ---" -ForegroundColor Yellow
    dotnet clean $SolutionPath --nologo `
        -c $Configuration `
        -p:Platform="$platformSol"
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE 
    }
}

# Restore
if (-not $SkipRestore) {
    Write-Host "`n--- Restore ---" -ForegroundColor Yellow
    dotnet restore $SolutionPath --nologo -p:Platform="$platformSol"
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE 
    }
}

# Build
if (-not $SkipBuild) {
    Write-Host "`n--- Build ---" -ForegroundColor Yellow
    dotnet build $SolutionPath --nologo `
        -c $Configuration `
        -p:Platform="$platformSol" `
        -p:ContinuousIntegrationBuild=true `
        --no-restore
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE 
    }
}

# Pack
Write-Host "`n--- Pack ---" -ForegroundColor Yellow
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$packArgs = @(
    'pack'
    $SolutionPath
    '--nologo'
    '-c', $Configuration
    '-p:Platform=' + $platformSol
    '-p:ContinuousIntegrationBuild=true'
    '-o', $OutputDir
    '--no-build'
)

if (-not [string]::IsNullOrWhiteSpace($ReleaseNotes)) {
  # MSBuild command-line parsing will break if release notes contain newlines
  # (they can be interpreted as separate switches, e.g. a stray 'net9.0').
  # Normalize release notes to a single-line value and remove double-quotes
  $safeReleaseNotes = $ReleaseNotes -replace "\r?\n", ' '
  $safeReleaseNotes = $safeReleaseNotes -replace '"', "'"
  $packArgs += ('-p:PackageReleaseNotes="{0}"' -f $safeReleaseNotes)
}

$markerOk = Join-Path $OutputDir '.PACK_OK'
$markerFail = Join-Path $OutputDir '.PACK_FAIL'

# Remove old markers
Remove-Item -Path $markerOk -Force -ErrorAction SilentlyContinue
Remove-Item -Path $markerFail -Force -ErrorAction SilentlyContinue

& dotnet @packArgs
if ($LASTEXITCODE -ne 0) {
    New-Item -ItemType File -Path $markerFail -Force | Out-Null
    exit $LASTEXITCODE 
}

# Create success marker
New-Item -ItemType File -Path $markerOk -Force | Out-Null

# Summary
Write-Host "`n=== Pack Complete ===" -ForegroundColor Green
$packages = Get-ChildItem -Path $OutputDir -Filter '*.nupkg' | Select-Object -ExpandProperty Name
Write-Host "Packages created ($($packages.Count)):"
foreach ($pkg in $packages) {
    Write-Host "  - $pkg" -ForegroundColor Cyan
}

$symbols = Get-ChildItem -Path $OutputDir -Filter '*.snupkg' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
if ($symbols) {
    Write-Host "Symbols created ($($symbols.Count)):"
    foreach ($sym in $symbols) {
        Write-Host "  - $sym" -ForegroundColor Cyan
    }
}

Write-Host "`nOutput directory: $OutputDir" -ForegroundColor Green
exit 0
