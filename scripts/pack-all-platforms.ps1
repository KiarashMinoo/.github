<#
.SYNOPSIS
  Run `pack-solution.ps1` across the CI matrix of platforms/configurations in parallel.

.DESCRIPTION
  Convenience developer script to reproduce the GitHub Actions pack matrix locally
  or in a CI runner. It launches one background job per (platform,configuration)
  combination and places per-leg logs under the chosen output root.

.PARAMETER Platforms
  Array of platform identifiers (AnyCpu, x86, x64, ARM64). Default: AnyCpu,x86,x64,ARM64

.PARAMETER Configurations
  Array of configurations (Debug,Release). Default: Release

.PARAMETER SolutionPath
  Optional path to the .sln file. If omitted, `pack-solution.ps1` will auto-discover.

.PARAMETER OutputRoot
  Root directory where per-leg outputs/logs will be written. Default: artifacts/pkg-matrix

.PARAMETER ParallelLimit
  Maximum concurrent jobs. Default: value of processor count.

.PARAMETER SkipClean, SkipRestore, SkipBuild
  Passed-through switches to `pack-solution.ps1` to speed up smoke tests.

.PARAMETER ReleaseNotes
  Optional release notes text to pass into pack step.

.EXAMPLE
  # Run all platforms/releases in parallel (local dev)
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\github\scripts\pack-all-platforms.ps1 -Configurations Release -ParallelLimit 4

.EXAMPLE
  # Smoke test with no build/restore for two platforms
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\github\scripts\pack-all-platforms.ps1 -Platforms AnyCpu,x64 -Configurations Release -SkipBuild -SkipRestore -SkipClean
#>

param(
    [string[]]$Platforms = @('AnyCpu', 'x86', 'x64', 'ARM64'),
    [string[]]$Configurations = @('Debug', 'Release'),
    [string]$SolutionPath,
    [string]$OutputRoot = 'artifacts/pkg-matrix',
    [int]$ParallelLimit = [Math]::Max(1, [Environment]::ProcessorCount),
    [switch]$SkipClean,
    [switch]$SkipRestore,
    [switch]$SkipBuild,
    [string]$ReleaseNotes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== pack-all-platforms: starting ===" -ForegroundColor Cyan
Write-Host "Platforms: $($Platforms -join ', ')"
Write-Host "Configurations: $($Configurations -join ', ')"
Write-Host "OutputRoot: $OutputRoot"
Write-Host "ParallelLimit: $ParallelLimit"

# Normalize if caller passed comma-joined strings as single elements (common from YAML/CLI)
if ($Platforms.Count -eq 1 -and $Platforms[0] -like '*,*') {
    $Platforms = ($Platforms -split ',') | ForEach-Object { $_.Trim() }
    Write-Host "Normalized Platforms: $($Platforms -join ', ')"
}
if ($Configurations.Count -eq 1 -and $Configurations[0] -like '*,*') {
    $Configurations = ($Configurations -split ',') | ForEach-Object { $_.Trim() }
    Write-Host "Normalized Configurations: $($Configurations -join ', ')"
}

# Resolve script path
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$packScript = Join-Path $scriptDir 'pack-solution.ps1'
if (-not (Test-Path $packScript)) {
    Write-Error "pack-solution.ps1 not found at $packScript"
    exit 2
}

# Ensure output root exists
if (-not (Test-Path $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

# Prepare the job queue
$jobs = @()

# Determine a cross-platform PowerShell executable (pwsh preferred)
$pwshExe = $null
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd) {
    $pwshExe = $pwshCmd.Path 
}
else {
    $psExeCmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($psExeCmd) {
        $pwshExe = $psExeCmd.Path 
    }
}
if (-not $pwshExe) {
    Write-Error "No PowerShell executable found (pwsh or powershell.exe). Cannot start legs."
    exit 2
}

foreach ($platform in $Platforms) {
    foreach ($configuration in $Configurations) {
        $legDir = Join-Path $OutputRoot ("$platform-$configuration")
        if (-not (Test-Path $legDir)) {
            New-Item -ItemType Directory -Path $legDir -Force | Out-Null 
        }

        $logFile = Join-Path $legDir 'pack.log'
        $markerOk = Join-Path $legDir '.PACK_OK'
        $markerFail = Join-Path $legDir '.PACK_FAIL'

        # Build argument list for inner script invocation
        $innerArgs = @(
            '-Configuration', $configuration
            '-Platform', $platform
            '-OutputDir', $legDir
        )
        
        if ($SolutionPath) {
            $innerArgs += '-SolutionPath', $SolutionPath
        }
        
        if (-not [string]::IsNullOrWhiteSpace($ReleaseNotes)) {
            $innerArgs += '-ReleaseNotes', $ReleaseNotes
        }
        
        if ($SkipClean) {
            $innerArgs += '-SkipClean'
        }
        
        if ($SkipRestore) {
            $innerArgs += '-SkipRestore'
        }
        
        if ($SkipBuild) {
            $innerArgs += '-SkipBuild'
        }

        # Start each leg as a separate process (cross-platform) and redirect output to per-leg log
        try {
            $startArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $packScript) + $innerArgs
            $errFile = $logFile + '.err'
            # Use separate stderr file because Start-Process doesn't allow stdout and stderr to be the same file
            $proc = Start-Process -FilePath $pwshExe -ArgumentList $startArgs -RedirectStandardOutput $logFile -RedirectStandardError $errFile -NoNewWindow -PassThru
            $jobs += [pscustomobject]@{ Process = $proc; Platform = $platform; Configuration = $configuration; Log = $logFile; Err = $errFile; LegDir = $legDir }
        }
        catch {
            $_ | Out-String | Out-File -FilePath $logFile -Append -Encoding utf8
            New-Item -ItemType File -Path $markerFail -Force | Out-Null
            $jobs += [pscustomobject]@{ Process = $null; Platform = $platform; Configuration = $configuration; Log = $logFile; LegDir = $legDir }
        }

        # Throttle: if we reached ParallelLimit, wait for any job to finish before starting more
        while (@($jobs | Where-Object { $_.Process -and -not $_.Process.HasExited }).Count -ge $ParallelLimit) {
            Start-Sleep -Seconds 1
        }
    }
}

# Wait for all legs to finish
Write-Host "Waiting for $($jobs.Count) legs to complete..."
$running = $jobs | Where-Object { $_.Process -ne $null } | ForEach-Object { $_.Process }
if ($running) {
    try {
        Wait-Process -Id ($running | Select-Object -ExpandProperty Id) -ErrorAction SilentlyContinue
    }
    catch {
        # ignore wait errors and proceed to check statuses
    }
}

# Collect results by inspecting per-leg marker files or process exit codes
$failedLegs = @()
foreach ($entry in $jobs) {
    $legDir = $entry.LegDir
    $markerFail = Join-Path $legDir '.PACK_FAIL'
    $markerOk = Join-Path $legDir '.PACK_OK'
    
    # If stderr file exists, append it into main log for easy inspection
    if ($entry.Err -and (Test-Path $entry.Err)) {
        try {
            Get-Content $entry.Err -Raw | Out-File -FilePath $entry.Log -Append -Encoding utf8
            Remove-Item $entry.Err -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }
    
    # Check marker files first (most reliable)
    if (Test-Path $markerFail) {
        $failedLegs += $entry
        continue
    }
    
    if (Test-Path $markerOk) {
        continue
    }
    
    # Fallback: check if packages were created in the leg output directory
    try {
        $createdPkgs = @(Get-ChildItem -Path $legDir -Filter '*.nupkg' -File -ErrorAction SilentlyContinue)
        if ($createdPkgs.Count -gt 0) {
            New-Item -ItemType File -Path $markerOk -Force | Out-Null
            continue
        }
    }
    catch { }
    
    # Fallback: check process exit code if available
    if ($entry.Process -and $entry.Process.HasExited) {
        try {
            $exit = $entry.Process.ExitCode
            if ($exit -eq 0) {
                New-Item -ItemType File -Path $markerOk -Force | Out-Null
                continue
            }
            else {
                $failedLegs += $entry
                continue
            }
        }
        catch {
            $failedLegs += $entry
            continue
        }
    }
    
    # No success indication found — treat as failure
    $failedLegs += $entry
}

Write-Host "All jobs finished."
if ($failedLegs.Count -gt 0) {
    $failedLegsStr = ($failedLegs | ForEach-Object { $_.Platform + '-' + $_.Configuration }) -join ', '
    Write-Host "Failed legs: $failedLegsStr" -ForegroundColor Red
    Write-Host "Per-leg logs are available under $OutputRoot" -ForegroundColor Yellow
    exit 3
}
else {
    Write-Host "All legs succeeded. Per-leg outputs/logs are under $OutputRoot" -ForegroundColor Green
    exit 0
}
