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
  Build configuration (e.g. Debug, Release, or any custom MSBuild configuration)

.PARAMETER Platform
  Platform target (AnyCpu, x86, x64, ARM64)

.PARAMETER SolutionPath
  Optional: explicit solution file path. If not provided, auto-discovers single .sln or .slnx at repo root.

.PARAMETER OutputDir
  Directory for packed artifacts (default: artifacts/pkg)

.PARAMETER SkipClean
  Skip the clean step

.PARAMETER SkipRestore
  Skip the restore step

.PARAMETER SkipBuild
  Skip the build step

.PARAMETER SkipPack
  Skip the pack step (used to split Build and Pack into separate CI steps, e.g. to
  run tests/ArchTests between them)

.PARAMETER ReleaseNotes
  Optional release notes to embed in packages

.PARAMETER ProjectPaths
  Optional: newline- or comma-separated list of explicit .csproj paths (relative to repo root)
  to pack instead of the whole solution. Use this when the solution's Directory.Build.props sets
  IsPackable=true globally (so `dotnet pack` on the .sln/.slnx would also try to pack test/example
  projects) -- listing only the real package projects here avoids that.

.EXAMPLE
  pwsh .github/scripts/pack-solution.ps1 -Configuration Release -Platform AnyCpu
  pwsh .github/scripts/pack-solution.ps1 -Configuration Debug -Platform x64 -SolutionPath MySolution.sln
  pwsh .github/scripts/pack-solution.ps1 -Configuration Release -Platform AnyCpu -SolutionPath MySolution.slnx
  pwsh .github/scripts/pack-solution.ps1 -Configuration Release -Platform AnyCpu -SkipPack   # build only
  pwsh .github/scripts/pack-solution.ps1 -Configuration Release -Platform AnyCpu -SkipClean -SkipRestore -SkipBuild  # pack only
  pwsh .github/scripts/pack-solution.ps1 -Configuration Release -Platform AnyCpu -SkipClean -SkipRestore -SkipBuild -ProjectPaths "src/A/A.csproj,src/B/B.csproj"
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$Configuration,

  [Parameter(Mandatory = $true)]
  [ValidateSet('AnyCpu', 'x86', 'x64', 'ARM64')]
  [string]$Platform,

  [string]$SolutionPath,
  [string]$OutputDir = 'artifacts/pkg',
  [switch]$SkipClean = $false,
  [switch]$SkipRestore = $false,
  [switch]$SkipBuild = $false,
  [switch]$SkipPack = $false,
  [string]$ReleaseNotes = '',
  [string]$ProjectPaths = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== .NET Solution Pack Script ===" -ForegroundColor Cyan
Write-Host "Configuration: $Configuration"
Write-Host "Platform: $Platform"

$repoRoot = (Get-Location).Path

# Normalize platform for solution builds
$platformSol = if ($Platform -match '^[Aa]ny[Cc]pu$') { 
  'Any CPU' 
}
else { 
  $Platform 
}
Write-Host "Platform (normalized): $platformSol"

# Determine artifact suffix (used by workflow artifact names)
$artifactSuffix = if ($Platform -match '^[Aa]ny[Cc]pu$') {
  '' 
}
else {
  "-$Platform" 
}

# Export platform and artifact suffix to GitHub Actions if available
if ($env:GITHUB_OUTPUT) {
  Add-Content -Path $env:GITHUB_OUTPUT -Value "platform_sol=$platformSol"
  Add-Content -Path $env:GITHUB_OUTPUT -Value "artifact_suffix=$artifactSuffix"
}

# Resolve solution file
if (-not $SolutionPath) {
  # Ensure the result is always an array so .Count works even when a single file is returned.
  # Support both .sln and .slnx files at repo root.
  $solutionFiles = @(
    Get-ChildItem -File |
      Where-Object { $_.Extension -in @('.sln', '.slnx') } |
      Select-Object -ExpandProperty Name
  )
  if ($solutionFiles.Count -eq 0) {
    Write-Error "No .sln or .slnx file found at repo root. Specify -SolutionPath."
    exit 1
  }
  elseif ($solutionFiles.Count -gt 1) {
    Write-Error "Multiple solution files found: $($solutionFiles -join ', '). Specify -SolutionPath."
    exit 1
  }
  $SolutionPath = $solutionFiles[0]
}
elseif ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($SolutionPath)) {
  $globPattern = $SolutionPath.Replace('\\', '/')
  $globPatterns = @($globPattern)
  if ($globPattern.StartsWith('**/')) {
    # Also match files located at repo root for patterns like **/*.sln*
    $globPatterns += $globPattern.Substring(3)
  }

  $wildcards = @(
    $globPatterns |
      Select-Object -Unique |
      ForEach-Object { [System.Management.Automation.WildcardPattern]::new($_, [System.Management.Automation.WildcardOptions]::IgnoreCase) }
  )

  $candidateFiles = @(
    Get-ChildItem -Path $repoRoot -Recurse -File |
      Where-Object {
        $ext = $_.Extension.ToLowerInvariant()
        if ($ext -notin @('.sln', '.slnx', '.csproj')) {
          return $false
        }

        $relative = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\\', '/')
        foreach ($wc in $wildcards) {
          if ($wc.IsMatch($relative)) {
            return $true
          }
        }
        return $false
      }
  )

  if ($candidateFiles.Count -eq 0) {
    Write-Error "No files matched SolutionPath pattern '$SolutionPath'."
    exit 1
  }

  if ($candidateFiles.Count -gt 1) {
    $matchedPaths = $candidateFiles | ForEach-Object {
      [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\\', '/')
    }
    Write-Error "Multiple files matched SolutionPath pattern '$SolutionPath': $($matchedPaths -join ', '). Specify an explicit path."
    exit 1
  }

  $SolutionPath = $candidateFiles[0].FullName
}
else {
  # Resolve non-wildcard paths relative to repo root, and recover from common path mismatches.
  $requestedPath = $SolutionPath
  $candidatePath = if ([System.IO.Path]::IsPathRooted($requestedPath)) {
    $requestedPath
  }
  else {
    Join-Path $repoRoot $requestedPath
  }

  if (Test-Path -LiteralPath $candidatePath) {
    $SolutionPath = $candidatePath
  }
  else {
    $requestedLeaf = [System.IO.Path]::GetFileName($requestedPath)
    $requestedRel = $requestedPath.Replace('\\', '/').TrimStart('./')

    $candidatesByLeaf = @(
      Get-ChildItem -Path $repoRoot -Recurse -File |
        Where-Object {
          $_.Name.Equals($requestedLeaf, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )

    $candidatesByRelative = @(
      $candidatesByLeaf |
        Where-Object {
          ([System.IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\\', '/'))
            .Equals($requestedRel, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )

    $finalCandidates = if ($candidatesByRelative.Count -gt 0) { $candidatesByRelative } else { $candidatesByLeaf }

    if ($finalCandidates.Count -eq 0) {
      $ext = [System.IO.Path]::GetExtension($requestedLeaf)
      $base = [System.IO.Path]::GetFileNameWithoutExtension($requestedLeaf)
      $altExt = if ($ext -ieq '.sln') { '.slnx' } elseif ($ext -ieq '.slnx') { '.sln' } else { '' }

      if ($altExt) {
        $altLeaf = "$base$altExt"
        $altMatches = @(
          Get-ChildItem -Path $repoRoot -Recurse -File |
            Where-Object {
              $_.Name.Equals($altLeaf, [System.StringComparison]::OrdinalIgnoreCase)
            }
        )
        if ($altMatches.Count -eq 1) {
          $SolutionPath = $altMatches[0].FullName
        }
      }
    }
    elseif ($finalCandidates.Count -eq 1) {
      $SolutionPath = $finalCandidates[0].FullName
    }
    else {
      $paths = $finalCandidates | ForEach-Object {
        [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\\', '/')
      }
      Write-Error "Multiple files matched SolutionPath '$requestedPath': $($paths -join ', '). Specify a more specific path."
      exit 1
    }
  }
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
  dotnet restore $SolutionPath --nologo --disable-parallel -p:Platform="$platformSol"
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE 
  }
}

# Build
if (-not $SkipBuild) {
  Write-Host "`n--- Build ---" -ForegroundColor Yellow
  dotnet build $SolutionPath --nologo `
    -c $Configuration `
    -m:1 `
    -p:Platform="$platformSol" `
    -p:BuildInParallel=false `
    -p:ContinuousIntegrationBuild=true `
    --no-restore
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE 
  }
}

# Pack
if ($SkipPack) {
  Write-Host "`n--- Pack skipped (-SkipPack) ---" -ForegroundColor Yellow
  exit 0
}

Write-Host "`n--- Pack ---" -ForegroundColor Yellow
if (-not (Test-Path $OutputDir)) {
  New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$commonPackArgs = @(
  '--nologo'
  '-c', $Configuration
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
  $commonPackArgs += ('-p:PackageReleaseNotes="{0}"' -f $safeReleaseNotes)
}

$markerOk = Join-Path $OutputDir '.PACK_OK'
$markerFail = Join-Path $OutputDir '.PACK_FAIL'

# Remove old markers
Remove-Item -Path $markerOk -Force -ErrorAction SilentlyContinue
Remove-Item -Path $markerFail -Force -ErrorAction SilentlyContinue

if (-not [string]::IsNullOrWhiteSpace($ProjectPaths)) {
  # Pack explicit project list instead of the whole solution.
  #
  # Deliberately NOT passing -p:Platform here. When a SOLUTION is built with
  # -p:Platform="Any CPU", MSBuild uses the .sln's solution-to-project platform
  # mapping, which normalizes "Any CPU" to the project's actual "AnyCPU" (no
  # space) -- the default, so no platform segment is inserted into the output
  # path (bin/Release/<tfm>/...). But invoking `dotnet pack` directly against a
  # single .csproj bypasses that solution-level mapping: MSBuild takes the
  # literal "Any CPU" string and DOES insert it into the path
  # (bin/Any CPU/Release/<tfm>/...), which doesn't match where Build actually
  # placed the DLL -- causing "file to be packed was not found on disk" with
  # --no-build. Omitting -p:Platform here lets each project fall back to its
  # own default (matching what the solution build already produced).
  $projects = @(
    $ProjectPaths -split '[,\r\n]' |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ }
  )
  Write-Host "Packing $($projects.Count) explicit project(s):"
  foreach ($proj in $projects) {
    Write-Host "  - $proj"
  }

  foreach ($proj in $projects) {
    $projPath = Join-Path $repoRoot $proj
    if (-not (Test-Path $projPath)) {
      Write-Error "Project not found: $proj"
      New-Item -ItemType File -Path $markerFail -Force | Out-Null
      exit 1
    }
    $packArgs = @('pack', $projPath) + $commonPackArgs
    & dotnet @packArgs
    if ($LASTEXITCODE -ne 0) {
      New-Item -ItemType File -Path $markerFail -Force | Out-Null
      exit $LASTEXITCODE
    }
  }
}
else {
  $packArgs = @('pack', $SolutionPath) + @('-p:Platform=' + $platformSol) + $commonPackArgs
  & dotnet @packArgs
  if ($LASTEXITCODE -ne 0) {
    New-Item -ItemType File -Path $markerFail -Force | Out-Null
    exit $LASTEXITCODE
  }
}

# Create success marker
New-Item -ItemType File -Path $markerOk -Force | Out-Null

# Summary
Write-Host "`n=== Pack Complete ===" -ForegroundColor Green
$packages = @(
  Get-ChildItem -Path $OutputDir -Filter '*.nupkg' |
    Select-Object -ExpandProperty Name
)
Write-Host "Packages created ($($packages.Count)):"
foreach ($pkg in $packages) {
  Write-Host "  - $pkg" -ForegroundColor Cyan
}

$symbols = @(
  Get-ChildItem -Path $OutputDir -Filter '*.snupkg' -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Name
)
if ($symbols) {
  Write-Host "Symbols created ($($symbols.Count)):"
  foreach ($sym in $symbols) {
    Write-Host "  - $sym" -ForegroundColor Cyan
  }
}

Write-Host "`nOutput directory: $OutputDir"
exit 0
