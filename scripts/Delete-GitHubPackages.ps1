[CmdletBinding()]
param(
    # Optional: will be inferred from git config / remote if omitted
    [string]$GitHubUserName,

    # Optional: will be taken from env vars if omitted
    [string]$GitHubToken,

    # Package name filter (supports wildcards: *, ?)
    # Use '*' to clean ALL user packages
    [string]$PackageNameFilter = 'ThunderPropagator.BuildingBlocks*',
    [string[]]$PackageTypes = @('nuget'),
    [int]$PageSize = 1000,
    [switch]$SinglePass,
    [switch]$DryRun
)

function Get-GitHubUserName {
    param(
        [string]$ExplicitName
    )

    # Normalize input safely (handles arrays, chars, non-string values)
    function ConvertTo-PlainString {
        param($v)
        if ($null -eq $v) {
            return $null 
        }
        if ($v -is [System.Array]) {
            return ($v -join '') 
        }
        return [string]$v
    }

    $expName = ConvertTo-PlainString $ExplicitName
    if (-not [string]::IsNullOrWhiteSpace($expName)) {
        return ([string]$expName).Trim()
    }

    # Try git config github.user
    try {
        $name = git config --get github.user 2>$null
    }
    catch {
        $name = $null
    }

    $nameStr = ConvertTo-PlainString $name
    if (-not [string]::IsNullOrWhiteSpace($nameStr)) {
        return ([string]$nameStr).Trim()
    }

    # Try to parse from remote.origin.url (https or ssh)
    try {
        $remote = git config --get remote.origin.url 2>$null
    }
    catch {
        $remote = $null
    }

    $remoteStr = ConvertTo-PlainString $remote
    if (-not [string]::IsNullOrWhiteSpace($remoteStr)) {
        # Examples:
        #  https://github.com/username/repo.git
        #  git@github.com:username/repo.git
        if ($remoteStr -match 'github\.com[:/](?<user>[^/]+)/') {
            $user = ConvertTo-PlainString $Matches['user']
            if (-not [string]::IsNullOrWhiteSpace($user)) {
                return ([string]$user).Trim()
            }
        }
    }

    throw "GitHub user name could not be determined. Pass -GitHubUserName explicitly or configure git (github.user or remote.origin.url)."
}

function Get-GitHubToken {
    param(
        [string]$ExplicitToken
    )
    # Normalize helper (reuse above)
    function ConvertTo-PlainStringLocal {
        param($v) if ($null -eq $v) {
            return $null 
        } if ($v -is [System.Array]) {
            return ($v -join '') 
        } return [string]$v 
    }

    $expTok = ConvertTo-PlainStringLocal $ExplicitToken
    if (-not [string]::IsNullOrWhiteSpace($expTok)) {
        return ([string]$expTok).Trim()
    }

    # Try common env vars and normalize them
    $candidates = @($env:GITHUB_TOKEN, $env:GH_TOKEN, $env:GH_PAT) | ForEach-Object { ConvertTo-PlainStringLocal $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($candidates.Count -gt 0) {
        return ([string]$candidates[0]).Trim()
    }

    throw "GitHub token could not be determined. Set GITHUB_TOKEN / GH_TOKEN / GH_PAT environment variable or pass -GitHubToken explicitly."
}

$GitHubUserName = Get-GitHubUserName -ExplicitName $GitHubUserName
$GitHubToken = Get-GitHubToken    -ExplicitToken $GitHubToken

Write-Host "Using GitHub user: $GitHubUserName"
Write-Host "Using GitHub token from parameter/env."
Write-Host "Package name filter: '$PackageNameFilter'"
Write-Host ""

$baseUri = "https://api.github.com"
$headers = @{
    "Authorization"        = "Bearer $GitHubToken"
    "Accept"               = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

# Preflight token validation: verify token is valid and get token owner's login
try {
    $userUri = "$baseUri/user"
    $tokenInfo = Invoke-RestMethod -Uri $userUri -Headers $headers -Method Get -ErrorAction Stop
    if ($tokenInfo -and $tokenInfo.login) {
        $tokenOwner = [string]$tokenInfo.login
        Write-Host "Token valid for user: $tokenOwner"
        # If detected username differs from inferred username, prefer token owner (safer)
        if ($GitHubUserName -and ($GitHubUserName -ne $tokenOwner)) {
            Write-Warning "Specified -GitHubUserName '$GitHubUserName' differs from token owner '$tokenOwner'. Using token owner for package operations."
        }
        $GitHubUserName = $tokenOwner
    }
}
catch [System.Net.WebException] {
    Write-Error "GitHub token validation failed: $($_.Exception.Response.StatusCode) - $($_.Exception.Message)"
    Write-Error "Ensure the token provided in environment (GH_PAT/GH_TOKEN/GITHUB_TOKEN) has appropriate package permissions and is not empty."
    exit 2
}
catch {
    Write-Error "GitHub token validation failed: $($_.Exception.Message)"
    Write-Error "Ensure the token provided in environment (GH_PAT/GH_TOKEN/GITHUB_TOKEN) has appropriate package permissions and is not empty."
    exit 2
}

$maxIterations = if ($SinglePass) {
    1 
}
else {
    50 
}   # safety guard against infinite loops


$pageSize = $PageSize
Write-Host "Using page size: $pageSize (SinglePass: $SinglePass)"
$allPackages = @()

# Fetch packages for each requested package_type (API requires package_type)
foreach ($ptype in $PackageTypes) {
    $page = 1
    do {
        $uri = "$baseUri/users/$GitHubUserName/packages?package_type=$ptype&per_page=$pageSize&page=$page"
        try {
            $packages = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to list packages for type '$ptype': $($_.Exception.Message)"
            break
        }

        if ($packages -and $packages.Count -gt 0) {
            # ensure the package_type is present for downstream logic
            foreach ($p in $packages) {
                $p.package_type = $ptype 
            }
            $allPackages += $packages
            $page++
        }
        else {
            break 
        }
    } while ($true)
}

if (-not $allPackages -or $allPackages.Count -eq 0) {
    Write-Host "No packages found for user '$GitHubUserName'."
    exit 0
}

# Filter by name (supports wildcard)
$packagesToDelete = $allPackages | Where-Object {
    $_.name -like $PackageNameFilter
}

if (-not $packagesToDelete -or $packagesToDelete.Count -eq 0) {
    Write-Host "No packages match filter '$PackageNameFilter'. Nothing to delete."
    exit 0
}

Write-Host "Packages matching '$PackageNameFilter' in this iteration:"
$packagesToDelete | Select-Object id, name, package_type | Format-Table -AutoSize
Write-Host ""

foreach ($pkg in $packagesToDelete) {
    $packageName = $pkg.name
    $packageType = $pkg.package_type  # nuget, npm, container, etc.
    $deleteUri = "$baseUri/users/$GitHubUserName/packages/$packageType/$packageName"

    if ($DryRun) {
        Write-Host "Would DELETE: $deleteUri" -ForegroundColor Yellow
        continue
    }

    Write-Host "Deleting '$packageName' (type: $packageType)..."
    try {
        Invoke-RestMethod -Uri $deleteUri -Headers $headers -Method Delete -ErrorAction Stop
        Write-Host "Deleted '$packageName'."
    }
    catch {
        Write-Warning "Failed to delete '$packageName': $($_.Exception.Message)"
    }

    Write-Host ""
}


Write-Host "Done."
