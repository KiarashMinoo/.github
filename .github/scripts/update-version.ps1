<#
.SYNOPSIS
  Bump project version in Directory.Build.props for beta or release channels.

.DESCRIPTION
  PowerShell 5.1 compatible helper used by GitHub Actions to increment version:
   - beta channel:
     * First beta after release: bump -BumpComponent (default major) and add
       -beta.1 (e.g. major: 1.1.1 -> 2.0.0-beta.1; minor: 1.1.1 -> 1.2.0-beta.1;
       patch: 1.1.1 -> 1.1.2-beta.1)
     * Subsequent betas: increment beta.N (1.1.2-beta.1 -> 1.1.2-beta.2)
   - release channel:
     * From a prerelease (e.g. 1.1.2-beta.5): strip the suffix only (the
       component was already bumped when the beta cycle started) -> 1.1.2
     * From a plain version with no prerelease (release-only flow, no beta
       stage, e.g. IIIF): bump -BumpComponent directly (e.g. minor: 1.1.2 -> 1.2.0)
   - SetVersion: Set version to a specific value (used for syncing branches)

  -BumpComponent controls which part of the version gets incremented in the "starting
  fresh from a version with no prerelease suffix" case above (default 'major', matching
  the original protocol of bumping major once per beta cycle / release-only push).
  Pass -BumpComponent minor for repos that should grow the minor version and keep major
  fixed instead (e.g. IIIF). 'patch' keeps the original pre-this-flag behavior. Bumping
  major or minor resets the lower component(s) to 0, per normal SemVer convention.

  Returns outputs via GITHUB_OUTPUT: version=<new-version>, and when -CommitAndTag is
  used, sha=<commit-sha> of the version-bump commit (so callers can check out the
  exact commit instead of relying on a tag/branch ref).

  Usage examples:
    pwsh .github/scripts/update-version.ps1 -Channel beta
    pwsh .github/scripts/update-version.ps1 -Channel beta -BumpComponent minor
    pwsh .github/scripts/update-version.ps1 -Channel release
    pwsh .github/scripts/update-version.ps1 -SetVersion 1.2.3
    pwsh .github/scripts/update-version.ps1 -Channel release -CommitAndTag -SkipTag   # commit+push only, no git tag
#>
param(
    [ValidateSet('release', 'beta', '')][string]$Channel = '',
    [string]$SetVersion = '',
    [string]$PropsPath = 'Directory.Build.props',
    [switch]$CommitAndTag,
    [switch]$SkipTag,
    [string]$CommitMessage = 'chore: bump version to {VERSION} [skip ci]',
    [string]$TagPrefix = 'v',
    [string]$TagMessage = 'Release {TAG}',
    [switch]$UpdateCsproj,
    [ValidateSet('major', 'minor', 'patch')][string]$BumpComponent = 'major'
)

# Validate parameters
# Use $PSBoundParameters to detect whether a caller explicitly provided a parameter.
# This avoids treating the default empty string as "provided" which previously caused
# the script to think both -Channel and -SetVersion were specified when callers only
# passed -SetVersion.
$channelBound = $PSBoundParameters.ContainsKey('Channel')
$setVersionBound = $PSBoundParameters.ContainsKey('SetVersion')

# Consider a parameter present only if it was explicitly bound and not empty/whitespace
$hasChannel = $channelBound -and -not [string]::IsNullOrWhiteSpace($Channel)
$hasSetVersion = $setVersionBound -and -not [string]::IsNullOrWhiteSpace($SetVersion)

# If both are present, prefer SetVersion (CI environments may sometimes bind defaults unexpectedly)
if ($hasChannel -and $hasSetVersion) {
    Write-Host "Both -Channel and -SetVersion were provided; preferring -SetVersion and ignoring -Channel" -ForegroundColor Yellow
    $hasChannel = $false
}

if (-not $hasChannel -and -not $hasSetVersion) {
    Write-Error "Either -Channel or -SetVersion must be specified"
    exit 1
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Node($xml, $localName) {
    $ns = $xml.DocumentElement.GetAttribute('xmlns')
    if ($ns) {
        $nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $nsm.AddNamespace('msb', $ns)
        return $xml.SelectSingleNode("//msb:$localName", $nsm)
    }
    else {
        return $xml.SelectSingleNode("//$localName")
    }
}

# Determine if we should use Directory.Build.props or .csproj files
$usePropsFile = Test-Path $PropsPath
if (-not $usePropsFile -and -not $UpdateCsproj) {
    Write-Error "Props file not found: $PropsPath (use -UpdateCsproj to update .csproj files instead)"
    exit 2
}

if (-not $usePropsFile -and $UpdateCsproj) {
    # Find all .csproj files
    $csprojFiles = @(Get-ChildItem -Recurse -Filter '*.csproj' -ErrorAction SilentlyContinue)
    if ($csprojFiles.Count -eq 0) {
        Write-Error "No .csproj files found and $PropsPath not found"
        exit 2
    }
    Write-Host "Found $($csprojFiles.Count) .csproj file(s); will update all"
}
else {
    $csprojFiles = @()
}

# Process props file if it exists
if ($usePropsFile) {
    [xml]$xml = Get-Content -Raw $PropsPath

    $pkgNode = Get-Node $xml 'Version'
    if (-not $pkgNode) {
        Write-Error "<Version> node not found in $PropsPath"
        exit 3
    }

    $current = $pkgNode.InnerText.Trim()
    if (-not $current) { 
        Write-Error '<Version> is empty.'
        exit 4 
    }
}
else {
    # Get current version from first .csproj file
    [xml]$firstXml = Get-Content -Raw $csprojFiles[0].FullName
    $pkgNode = Get-Node $firstXml 'Version'
    if (-not $pkgNode) {
        Write-Error "<Version> node not found in $($csprojFiles[0].FullName)"
        exit 3
    }
    $current = $pkgNode.InnerText.Trim()
    if (-not $current) {
        Write-Error '<Version> is empty.'
        exit 4
    }
}

# Handle SetVersion mode (for syncing branches)
if ($SetVersion) {
    $target = $SetVersion.Trim()
    if ($current -eq $target) {
        Write-Host ('Version already at ' + $target + '; no change needed.')
    }
    else {
        $pkgNode.InnerText = $target
        $xml.Save($PropsPath)
        Write-Host ('Version updated: ' + $current + ' -> ' + $target)
    }
    
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "version=$target"
    }
    else {
        Write-Host "version=$target"
    }
    exit 0
}

# Match 3- or 4-part version with optional prerelease
$m4 = [regex]::Match($current, '^(?<maj>\d+)\.(?<min>\d+)\.(?<bld>\d+)\.(?<rev>\d+)(?:-(?<pre>.+))?$')
$m3 = [regex]::Match($current, '^(?<maj>\d+)\.(?<min>\d+)\.(?<bld>\d+)(?:-(?<pre>.+))?$')

if ($m4.Success) {
    $maj = [int]$m4.Groups['maj'].Value
    $min = [int]$m4.Groups['min'].Value
    $bld = [int]$m4.Groups['bld'].Value
    $rev = [int]$m4.Groups['rev'].Value
    $pre = $m4.Groups['pre'].Value
    $format = '4'
}
elseif ($m3.Success) {
    $maj = [int]$m3.Groups['maj'].Value
    $min = [int]$m3.Groups['min'].Value
    $bld = [int]$m3.Groups['bld'].Value
    $rev = 0
    $pre = $m3.Groups['pre'].Value
    $format = '3'
}
else {
    Write-Error "Version '$current' must be 3- or 4-part (e.g., 1.2.3 or 1.2.3.0, optionally -prerelease)."
    exit 5
}

if ($hasChannel -and $Channel -eq 'beta') {
    # Beta channel: bump -BumpComponent if no prerelease, otherwise increment beta.N
    if (-not $pre) {
        # First beta after stable release: bump the configured component and add -beta.1
        switch ($BumpComponent) {
            'major' { $maj += 1; $min = 0; $bld = 0 }
            'minor' { $min += 1; $bld = 0 }
            default { $bld += 1 } # patch
        }
        $rev = if ($format -eq '4') {
            0
        }
        else {
            $null
        }
        $pre = "beta.1"
    }
    else {
        # Subsequent betas: just increment beta.N
        $preMatch = [regex]::Match($pre, '^(?<label>[A-Za-z0-9\-]+)(?:\.(?<n>\d+))?$')
        if ($preMatch.Success) {
            $nStr = $preMatch.Groups['n'].Value
            $n = if ($nStr) {
                [int]$nStr + 1 
            }
            else {
                1 
            }
            $pre = "beta.$n"
        }
        else {
            $pre = "beta.1"
        }
    }

    # Format new version matching input structure
    if ($format -eq '4') {
        $newVersion = "{0}.{1}.{2}.{3}-{4}" -f $maj, $min, $bld, $rev, $pre
    }
    else {
        $newVersion = "{0}.{1}.{2}-{3}" -f $maj, $min, $bld, $pre
    }
}
elseif ($hasChannel -and $Channel -eq 'release') {
    # Release channel: if coming from a prerelease (e.g. 1.1.2-beta.5), just strip the
    # suffix — the patch was already bumped when the beta cycle started. If there's no
    # prerelease suffix at all, this is a release-only flow with no preceding beta stage
    # (e.g. IIIF), so bump the configured component directly instead of re-tagging the
    # same version.
    if (-not $pre) {
        switch ($BumpComponent) {
            'major' { $maj += 1; $min = 0; $bld = 0 }
            'minor' { $min += 1; $bld = 0 }
            default { $bld += 1 } # patch
        }
        if ($format -eq '4') { $rev = 0 }
        Write-Host "No prerelease suffix on current version -- release-only flow, bumping $BumpComponent" -ForegroundColor Yellow
    }
    if ($format -eq '4') {
        $newVersion = "{0}.{1}.{2}.{3}" -f $maj, $min, $bld, $rev
    }
    else {
        $newVersion = "{0}.{1}.{2}" -f $maj, $min, $bld
    }
}

Write-Host ('Current: ' + $current)
Write-Host ('New:     ' + $newVersion)

# Update version in files
if ($usePropsFile) {
    $pkgNode.InnerText = $newVersion
    $xml.Save($PropsPath)
    $updatedFiles = @($PropsPath)
}
else {
    # Update all .csproj files
    $updatedFiles = @()
    foreach ($csprojFile in $csprojFiles) {
        [xml]$csprojXml = Get-Content -Raw $csprojFile.FullName
        $csprojNode = Get-Node $csprojXml 'Version'
        if ($csprojNode) {
            $csprojNode.InnerText = $newVersion
            $csprojXml.Save($csprojFile.FullName)
            $updatedFiles += $csprojFile.FullName
            Write-Host "Updated: $($csprojFile.Name)"
        }
    }
}

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "version=$newVersion"
}
else {
    Write-Host "version=$newVersion"
}

Write-Host ('Version updated successfully to ' + $newVersion)

if ($CommitAndTag) {
    Write-Host "`n--- Commit (and tag, unless -SkipTag) ---" -ForegroundColor Yellow

    # Configure git user (same as workflows)
    & git config user.name "github-actions[bot]" 2>$null
    & git config user.email "41898282+github-actions[bot]@users.noreply.github.com" 2>$null

    # Check for changes
    $porcelain = (& git status --porcelain) -join "`n"
    if ([string]::IsNullOrEmpty($porcelain)) {
        Write-Host "No changes to commit." -ForegroundColor Gray
    }
    else {
        # Stage updated files
        foreach ($file in $updatedFiles) {
            & git add $file
        }

        # Prepare commit message
        $commitMsg = $CommitMessage -replace '\{VERSION\}', $newVersion
        Write-Host "Committing: $commitMsg"
        & git commit -m $commitMsg
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "git commit failed (exit $LASTEXITCODE)"
        }
        else {
            Write-Host "Pushing commit to current branch..."
            & git push
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "git push failed (exit $LASTEXITCODE)"
            }
        }

        if (-not $SkipTag) {
            # Tag
            $tag = "$TagPrefix$newVersion"
            # detect if tag exists (git rev-parse exits non-zero when missing)
            $null = & git rev-parse "$tag" 2>$null
            $tagExists = ($LASTEXITCODE -eq 0)
            if ($tagExists) {
                Write-Host "Tag $tag already exists; skipping." -ForegroundColor Gray
            }
            else {
                $tagMsg = $TagMessage -replace '\{TAG\}', $tag -replace '\{VERSION\}', $newVersion
                Write-Host "Creating tag $tag"
                & git tag -a "$tag" -m "$tagMsg"
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "git tag failed (exit $LASTEXITCODE)"
                }
                else {
                    Write-Host "Pushing tag $tag..."
                    & git push origin "$tag"
                }
            }
        }
        else {
            Write-Host "Skipping tag creation (-SkipTag)." -ForegroundColor Gray
        }
    }

    # Always report the current HEAD commit SHA, whether or not there were changes to
    # commit (e.g. a re-run where the version was already bumped) -- callers use this to
    # check out the exact commit instead of relying on a tag or the moving branch tip.
    $headSha = (& git rev-parse HEAD).Trim()
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "sha=$headSha"
    }
    else {
        Write-Host "sha=$headSha"
    }
}

exit 0
