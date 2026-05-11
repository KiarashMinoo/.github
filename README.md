# KiarashMinoo/.github

Organization-level repository for shared GitHub Actions workflows and CI/CD infrastructure used across all ThunderPropagator repositories.

## Purpose

This repository centralizes reusable GitHub Actions workflows to avoid duplication across:
- **ThunderPropagator.BuildingBlocks**
- **ThunderPropagator.Clients.DotNet**
- **ThunderPropagator.Feeviders**
- **ThunderPropagator.Channels**
- **ThunderPropagator.Web**

## Repository Structure

```
.github/
  workflows/
    reusable-beta-ci.yml          # Called on develop branch pushes
    reusable-release-ci.yml       # Called on release/* branch pushes
  scripts/
    show-version.ps1              # Display git branch, tag, and version
    update-version.ps1            # Bump version in Directory.Build.props or .csproj
    generate-release-notes.ps1    # Generate release notes from commits
    pack-solution.ps1             # Build and pack NuGet packages
    publish-packages.ps1          # Publish packages to NuGet.org
    (other helper scripts)
  prompts/
    release-notes.prompt.md       # AI-driven changelog generation
    repo-docs.prompt.md           # AI-driven documentation generation
    repo-tests.prompt.md          # AI-driven test generation
```

## Workflows

### 1. Reusable Beta CI (`reusable-beta-ci.yml`)

**Triggered on**: `develop` branch push  
**Purpose**: Build, bump beta version, pack, and upload artifacts

**Inputs**:
- `solution-path` (string, default: `**/*.sln*`) — Path to `.sln`/`.slnx` or project glob
- `dotnet-versions` (string, default: `8.0.x`, `9.0.x`, `10.0.x`) — .NET SDK versions

**Secrets**:
- `gh-token` (required) — GitHub token for commits and tagging

**Jobs**:
1. **bump-beta** — Increments patch version with `-beta.N` suffix
2. **pack** — Builds and packs across matrix: `[Debug/Release] × [AnyCpu/x86/x64/ARM64]`

**Artifacts**:
- `pkg-{Configuration}{Suffix}` — NuGet packages
- `symbols-{Configuration}{Suffix}` — PDB symbol files (if present)

---

### 2. Reusable Release CI (`reusable-release-ci.yml`)

**Triggered on**: `release/**` branch push  
**Purpose**: Finalize version, create GitHub Release, pack, and publish to NuGet.org

**Inputs**:
- `solution-path` (string, default: `**/*.sln*`) — Path to `.sln`/`.slnx` or project glob
- `dotnet-versions` (string, default: `8.0.x`, `9.0.x`, `10.0.x`) — .NET SDK versions

**Secrets**:
- `gh-token` (required) — GitHub token for releases and tagging
- `nuget-api-key` (optional) — NuGet.org API key for publishing

**Jobs**:
1. **finalize-and-tag** — Strips `-beta.*` suffix, creates tag and GitHub Release
2. **sync-develop-version** — Syncs finalized version back to `develop` branch
3. **pack** — Builds and packs across matrix (same as beta CI)
4. **publish** — Publishes Release AnyCPU packages to NuGet.org (if secret provided)
5. **cleanup** — Deletes all run artifacts after publish

---

## Usage in Other Repositories

### Step 1: Copy the scripts folder

```powershell
cp -r .github/scripts <target-repo>/.github/scripts
```

### Step 2: Create `.github/workflows/ci.yml` in the target repo

```yaml
name: CI

on:
  push:
    branches: [develop, release/**]
  workflow_dispatch: {}

jobs:
  beta-ci:
    if: github.ref == 'refs/heads/develop'
    uses: KiarashMinoo/.github/.github/workflows/reusable-beta-ci.yml@main
    with:
      solution-path: 'ThunderPropagator.BuildingBlocks.sln'
    secrets:
      gh-token: ${{ secrets.GITHUB_TOKEN }}

  release-ci:
    if: startsWith(github.ref, 'refs/heads/release/')
    uses: KiarashMinoo/.github/.github/workflows/reusable-release-ci.yml@main
    with:
      solution-path: 'ThunderPropagator.BuildingBlocks.sln'
    secrets:
      gh-token: ${{ secrets.GITHUB_TOKEN }}
      nuget-api-key: ${{ secrets.NUGET_API_KEY }}
```

### Step 3: Create `Directory.Build.props` (optional)

If your repo uses centralized versioning, add `Directory.Build.props` at the root:

```xml
<Project>
  <PropertyGroup>
    <Version>1.0.0-beta.1</Version>
    <TargetFramework>net9.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <!-- ... other shared properties ... -->
  </PropertyGroup>
</Project>
```

**If no `Directory.Build.props` exists**, the workflows will automatically update version directly in `.csproj` files.

### Step 4: Set up GitHub secrets (for release CI)

In target repo **Settings > Secrets and variables > Actions**:
- `NUGET_API_KEY` — Your NuGet.org API key (optional, for publishing)

---

## Version Management

### How versioning works:

**Directory.Build.props approach** (recommended):
- Single `<Version>` node in `Directory.Build.props` at repo root
- All `.csproj` files inherit version automatically
- Workflows update this file on beta/release builds

**Direct .csproj approach** (fallback):
- No `Directory.Build.props` file
- Workflows search for `.csproj` files and update `<Version>` directly
- Specify `-UpdateCsproj` flag in version script

### Version bump flow:

1. **Develop branch** → bumps patch + adds `-beta.N`:
   - `1.0.0` → `1.0.1-beta.1`
   - `1.0.1-beta.1` → `1.0.1-beta.2`

2. **Release branch** → strips prerelease, creates stable tag:
   - `1.0.1-beta.5` → `1.0.1` (tag: `v1.0.1`)

3. **Sync back to develop** → versions develop with stable version:
   - Develop gets `1.0.1` after release

---

## Displaying Version Information

The `show-version.ps1` script displays:
- Current git branch
- Current git tag (if on a tag)
- Version from `Directory.Build.props` or first `.csproj` file

Run manually:
```powershell
pwsh ./.github/scripts/show-version.ps1
```

Workflows call this automatically before packing.

---

## Required Scripts

All repositories must copy these scripts from `.github/scripts/`:

| Script | Purpose |
|--------|---------|
| `update-version.ps1` | Bump version, handle Directory.Build.props or .csproj |
| `generate-release-notes.ps1` | Generate release notes from commit messages |
| `pack-solution.ps1` | Build and pack NuGet packages |
| `publish-packages.ps1` | Publish packages to NuGet.org |
| `show-version.ps1` | Display branch, tag, and version |

---

## Environment Variables (Workflows)

| Variable | Source | Usage |
|----------|--------|-------|
| `GH_TOKEN` | Secret `gh-token` | Git operations, releasing |
| `NUGET_API_KEY` | Secret `nuget-api-key` | Publishing to NuGet.org |
| `REL_NOTES` | Generated by script | Release notes in beta packing |

---

## AI Prompts for Code Generation & Documentation

This repository includes reusable GitHub Copilot prompts for autonomous code generation tasks. Copy the `prompts` folder to your target repository and use them with Copilot Chat.

### Available Prompts

#### 1. Changelog Generator (`release-notes.prompt.md`)

**Purpose**: Automatically generate or update `CHANGELOG.md` from git commits  
**Features**:
- Per-branch incremental tracking (resumes from last processed commit)
- Release mode: generates from previous release tag to current tag
- Conventional Commit grouping (feat, fix, perf, refactor, etc.)
- State management via `.github/changelog-state.json`

#### 2. Documentation Generator (`repo-docs.prompt.md`)

**Purpose**: Automatically generate rich documentation structure under `/docs`  
**Features**:
- Deep recursion: creates `/docs/<path>/README.md` for every folder
- Auto-generates Docs Catalog in root README
- Extracts NuGet package metadata from `.csproj` files
- Mermaid diagrams per folder
- Idempotent (safe to run multiple times)

#### 3. Test Generator (`repo-tests.prompt.md`)

**Purpose**: Automatically generate unit and architecture tests  
**Features**:
- Reuses or creates `UnitTests` and `ArchTests` projects under `Tests/` folder
- xUnit + NSubstitute + FluentAssertions unit tests
- NetArchTest architecture tests for API contracts
- Targets `net10.0` with preview features
- Never modifies production code

### How to Use Prompts in Your Repository

**Copy prompts to your repository**:
```bash
cp -r .github/prompts <target-repo>/.github/prompts/
```

**Usage in Copilot Chat** — Use the `@workspace` agent with file reference:
```
@workspace #file:.github/prompts/<prompt-name>.md

[Your instructions]
```

**Examples:**

Generate Changelog:
```
@workspace #file:.github/prompts/release-notes.prompt.md

Generate changelog for the repository.
```

Generate Documentation:
```
@workspace #file:.github/prompts/repo-docs.prompt.md

Generate documentation for all folders with reset=true.
```

Generate Tests:
```
@workspace #file:.github/prompts/repo-tests.prompt.md

Generate unit tests and architecture tests for this repository.
```

### State Files (for incremental updates)

Commit these files to enable resuming from the last run:
- `.github/changelog-state.json` — Per-branch tracking
- `.github/docs-state.json` — Folder cache

Do not modify these manually; they're auto-managed by prompts.

### Customization

Edit prompts in `.github/prompts/` to match your repository's conventions:
- Path prefixes to strip (company name, project prefix)
- NuGet feed URLs
- Test framework choices
- Documentation structure and folder depth

---

## Troubleshooting

### Workflow fails: "Directory.Build.props not found"
- **Solution**: Workflows now support both approaches. If no `Directory.Build.props` exists, pass `-UpdateCsproj` flag.

### Version not bumping
- Check `update-version.ps1` can access `.csproj` or `Directory.Build.props`
- Ensure PowerShell execution policy allows running scripts

### NuGet publish fails
- Verify `NUGET_API_KEY` secret is set in target repo
- Confirm API key has appropriate package permissions
- Check package version doesn't already exist on NuGet.org

### Prompts not generating complete results
- Ensure all source files are readable (not in .gitignore)
- Check Copilot Chat context window isn't exceeded
- Try `incremental=true` or `dryRun=true` to debug

---

## Contributing

To update workflows, scripts, or prompts:
1. Edit files in this repository
2. Test changes in a test branch before merging to `main`
3. All dependent repos will automatically use updated workflows on next CI run
4. For prompts, publish updates to the `.github/prompts/` folder

---

## License

MIT — See LICENSE file
