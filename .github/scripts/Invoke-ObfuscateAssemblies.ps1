#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Obfuscates a repo's packable assemblies in place, right after Build and before Pack,
  driven entirely by a repo-committed obfuscar.xml.

.DESCRIPTION
  Called from reusable-ci.yml's pack job, gated on hashFiles('obfuscar.xml') != '' -- a
  repo opts in just by committing that file at its root; no separate boolean switch
  input exists anywhere in this pipeline for this.

  Only the <Module file="..."/> entries' FILENAMES are read from the checked-in
  obfuscar.xml (e.g. "ThunderPropagator.Application.dll") -- its InPath/OutPath are
  intentionally ignored here, because this script runs once per CI matrix leg
  (Platform x Configuration), and each leg's actual build output can land in a different
  bin/ subfolder (MSBuild only inserts a platform segment for non-default platforms:
  AnyCPU builds under bin/<Configuration>/<TFM>/, but x86/x64/ARM64 build under
  bin/<Platform>/<Configuration>/<TFM>/) and multi-targeting produces one copy per TFM on
  top of that. Hardcoding any of those paths in the single repo-committed config would be
  wrong for most legs. Instead: find every real build-output copy of each named assembly
  under bin/ that matches this leg's Configuration, group by containing folder (one group
  per TFM), and generate a throwaway config per folder with InPath=OutPath=that folder
  (obfuscating in place) plus an AssemblySearchPath covering it and the NuGet cache (for
  resolving referenced assemblies Obfuscar doesn't rename but still needs to load). Every
  OTHER <Var> in the checked-in config (KeepPublicApi, HidePrivateApi, RenameProperties,
  etc.) is copied through unchanged, so the actual obfuscation POLICY still lives in the
  repo's own obfuscar.xml, reviewable like any other source file.

  Obfuscating in place means the following Pack step (`dotnet pack --no-build`) picks up
  the obfuscated DLLs automatically -- no change needed to pack-solution.ps1.

  Requires obfuscar.globaltool to already be available as `obfuscar.console`, e.g. via
  `dotnet tool restore` against a repo-committed .config/dotnet-tools.json (the caller
  step in reusable-ci.yml does this before invoking this script).

.PARAMETER Configuration
  The build configuration for this matrix leg (e.g. Release, Cluster). Only non-Debug
  configurations should ever reach this script -- the caller step's `if:` already
  enforces that, but this script also treats Configuration as a required, exact filter
  for which bin/ output to touch.

.PARAMETER Platform
  The platform for this matrix leg (AnyCpu, x86, x64, ARM64). Not used to construct
  paths directly (see DESCRIPTION) -- kept as a parameter for CI log clarity only.

.PARAMETER ConfigPath
  Path to the repo's Obfuscar config. Defaults to obfuscar.xml at the repo root.

.EXAMPLE
  pwsh .github/scripts/Invoke-ObfuscateAssemblies.ps1 -Configuration Release -Platform AnyCpu
#>
param(
    [Parameter(Mandatory = $true)][string]$Configuration,
    [Parameter(Mandatory = $true)][string]$Platform,
    [string]$ConfigPath = 'obfuscar.xml'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== Obfuscate Assemblies ===" -ForegroundColor Cyan
Write-Host "Configuration: $Configuration"
Write-Host "Platform:      $Platform"
Write-Host "Config:        $ConfigPath"

if (-not (Test-Path $ConfigPath)) {
    Write-Host "No $ConfigPath found at repo root -- nothing to do." -ForegroundColor Gray
    exit 0
}

[xml]$xml = Get-Content -Path $ConfigPath -Raw

# Carry every policy <Var> through unchanged except InPath/OutPath, which this script
# always overrides per discovered output folder (see DESCRIPTION).
$policyVars = [ordered]@{}
foreach ($varNode in @($xml.Obfuscator.Var)) {
    if ($varNode.name -notin @('InPath', 'OutPath')) {
        $policyVars[$varNode.name] = $varNode.value
    }
}

$moduleNames = @(
    @($xml.Obfuscator.Module) | ForEach-Object { Split-Path -Leaf $_.file } | Where-Object { $_ }
)
if ($moduleNames.Count -eq 0) {
    Write-Warning "No <Module> entries found in $ConfigPath -- nothing to obfuscate."
    exit 0
}
Write-Host "Configured assemblies: $($moduleNames -join ', ')"

# Group every real build-output copy of each configured assembly by its containing
# folder -- one folder per TFM (and, for non-AnyCPU platforms, implicitly scoped to this
# leg's platform too, since that's baked into the path MSBuild itself chose).
$outputDirs = [ordered]@{}
foreach ($name in $moduleNames) {
    $found = @(
        Get-ChildItem -Path '.' -Recurse -Filter $name -File -ErrorAction SilentlyContinue |
            Where-Object {
                $normalized = $_.FullName -replace '\\', '/'
                $normalized -match '/bin/' -and $normalized -match "(^|/)$([regex]::Escape($Configuration))(/|$)"
            }
    )
    foreach ($f in $found) {
        $dir = $f.DirectoryName
        if (-not $outputDirs.Contains($dir)) {
            $outputDirs[$dir] = [System.Collections.Generic.List[string]]::new()
        }
        $outputDirs[$dir].Add($name)
    }
}

if ($outputDirs.Count -eq 0) {
    Write-Warning "No built copies of any configured assembly found under bin/**/$Configuration/** -- nothing to obfuscate. Did the Build step run first?"
    exit 0
}

$nugetCache = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $HOME '.nuget/packages' }
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("obfuscar-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$failures = [System.Collections.Generic.List[string]]::new()
$i = 0
foreach ($dir in $outputDirs.Keys) {
    $i++
    $names = $outputDirs[$dir]
    Write-Host ""
    Write-Host "--- [$i/$($outputDirs.Count)] $dir ---" -ForegroundColor Yellow
    Write-Host "  Assemblies: $($names -join ', ')"

    $genConfigPath = Join-Path $workDir "obfuscar-$i.xml"
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<?xml version="1.0"?>')
    $lines.Add('<Obfuscator>')
    $lines.Add("  <Var name=`"InPath`" value=`"$dir`" />")
    $lines.Add("  <Var name=`"OutPath`" value=`"$dir`" />")
    foreach ($key in $policyVars.Keys) {
        $lines.Add("  <Var name=`"$key`" value=`"$($policyVars[$key])`" />")
    }
    $lines.Add("  <AssemblySearchPath path=`"$dir`" />")
    if (Test-Path $nugetCache) {
        # A single recursive search path over the ENTIRE nuget cache (every package,
        # every version ever restored, every asset kind -- lib/, ref/, runtimes/,
        # analyzers/, build/, contentFiles/, tools packages, ...) is what this used to
        # be, and it reliably failed to resolve real third-party dependencies (observed:
        # "Unable to resolve dependency: ThunderPropagator.BuildingBlocks.Application",
        # a package that IS restored and present in the cache) -- almost certainly
        # because a package built with ProduceReferenceAssembly=true (every
        # ThunderPropagator family package is) publishes the SAME assembly filename
        # under BOTH ref/<tfm>/ (a metadata-only stub with every method body replaced)
        # and lib/<tfm>/ (the real, loadable implementation), for EVERY target
        # framework the package multi-targets -- so a blind recursive search hands
        # Obfuscar a haystack containing several same-named candidates, several of them
        # wrong (stub bodies, or a different TFM's copy), with no guarantee it finds a
        # right one, let alone prefers it.
        #
        # Narrow this to exactly the folders that can possibly be right: every lib/<tfm>
        # directory in the cache whose <tfm> segment matches the TFM this leg's own
        # output directory ($dir) was built for (that segment is $dir's own leaf name --
        # MSBuild's bin/ layout always ends in .../<Configuration>/<TFM>/, regardless of
        # platform). Explicitly matching the path segment immediately before it as "lib"
        # (via the trailing /lib/<tfm> requirement below) is what excludes every ref/,
        # runtimes/, analyzers/, build/, and contentFiles/ folder that happens to share
        # the same leaf folder name -- so Obfuscar only ever sees real, loadable,
        # correct-TFM implementation assemblies, not their stub or wrong-TFM siblings.
        # Kept non-recursive per match (each is already the exact folder wanted) and
        # listed ahead of anything else so a correct match always wins first.
        $tfm = Split-Path -Leaf $dir
        $libTfmDirs = @(
            Get-ChildItem -Path $nugetCache -Recurse -Directory -Filter $tfm -ErrorAction SilentlyContinue |
                Where-Object { ($_.FullName -replace '\\', '/') -match "(^|/)lib/$([regex]::Escape($tfm))$" }
        )
        Write-Host "  Found $($libTfmDirs.Count) lib/$tfm folder(s) in the NuGet cache for dependency resolution."
        foreach ($libDir in $libTfmDirs) {
            $lines.Add("  <AssemblySearchPath path=`"$($libDir.FullName)`" />")
        }
        # Kept as a last-resort fallback for anything that doesn't follow the lib/<tfm>
        # convention above (e.g. a dependency whose package only ships a
        # lib/netstandard2.0/ asset that NuGet resolved as TFM-compatible rather than an
        # exact match) -- listed last so an exact match from the loop above is always
        # tried first.
        $lines.Add("  <AssemblySearchPath path=`"$nugetCache`" recursive=`"true`" />")
    }
    foreach ($name in $names) {
        $lines.Add("  <Module file=`"`$(InPath)/$name`" />")
    }
    $lines.Add('</Obfuscator>')
    Set-Content -Path $genConfigPath -Value ($lines -join "`n") -Encoding UTF8

    & dotnet tool run obfuscar.console $genConfigPath
    if ($LASTEXITCODE -ne 0) {
        Write-Host "::error::Obfuscation failed for $dir (exit $LASTEXITCODE)"
        $failures.Add($dir)
    }
    else {
        Write-Host "  Obfuscated in place: $($names -join ', ')" -ForegroundColor Green
    }
}

if ($failures.Count -gt 0) {
    Write-Host "::error::Obfuscation failed for $($failures.Count) output folder(s): $($failures -join ', ')"
    exit 1
}

Write-Host ""
Write-Host "Obfuscation complete ($($outputDirs.Count) output folder(s))." -ForegroundColor Green
exit 0
