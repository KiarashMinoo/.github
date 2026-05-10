<#
.SYNOPSIS
Display current branch, tag, and version information

.DESCRIPTION
Shows the current git branch, tag (if on one), and the version from either:
- Directory.Build.props (if it exists)
- First .csproj file found (if Directory.Build.props doesn't exist)

.EXAMPLE
pwsh ./show-version.ps1
#>

Write-Host "Current branch: $(git rev-parse --abbrev-ref HEAD)"
$currentTag = git describe --tags --exact-match 2>$null
if ($currentTag) {
  Write-Host "Current tag: $currentTag"
} else {
  Write-Host "Current tag: N/A"
}
Write-Host ""

if (Test-Path 'Directory.Build.props') {
  Write-Host "Directory.Build.props version:"
  $line = (Select-String -Path Directory.Build.props -Pattern '<Version>' -SimpleMatch).Line
  if ($line) { 
    Write-Host "  $line" 
  } else { 
    Write-Host "  <Version> node not found" 
  }
} else {
  Write-Host ".csproj version (from first project file):"
  $csproj = Get-ChildItem -Recurse -Filter '*.csproj' | Select-Object -First 1
  if ($csproj) {
    $line = (Select-String -Path $csproj.FullName -Pattern '<Version>' -SimpleMatch).Line
    if ($line) { 
      Write-Host "  $line" 
    } else { 
      Write-Host "  <Version> node not found" 
    }
  } else {
    Write-Host "  No .csproj files found"
  }
}
