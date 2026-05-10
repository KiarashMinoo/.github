---
mode: agent
description: "Always scan and generate tests (no inputs). Reuse or create ThunderPropagator.UnitTests and ThunderPropagator.ArchTests, ensure they are in the .sln under a 'Tests' solution folder. Generate xUnit + NSubstitute unit tests mirroring source, and architecture tests with NetArchTest. Non-interactive and idempotent."
---

# Repo Test Generator (no inputs; always scan & update)

Act autonomously and **do not ask for confirmations**. Use safe defaults. Make idempotent changes.  
**Never modify production code** — only create/update files inside the test projects.

---

## 0) Global behavior (no arguments)
- Always perform a **full scan** of the repository.
- **Reuse** existing test projects named:
  - `ThunderPropagator.UnitTests`
  - `ThunderPropagator.ArchTests`
- If missing, **create** them under `Tests/UnitTests` and `Tests/ArchTests`.
- **Always** make sure both projects are inside a **solution (`.sln`)** under a solution folder named **`Tests`**.  
  - If no `.sln` exists, create one at the repo root (name it after the repo folder).

---

## 1) Discovery (filesystem, deep, no depth limit)
- Walk the entire repo except:
  - `Tests/**`
  - `.git`, `.github` (keep `.github/prompts`), `.vs`, `.idea`
  - `bin`, `obj`, `node_modules`, caches/artifacts
  - any path whose **segment** matches (case-insensitive): `test`, `tests`, `.tests`, `*unit*test*`, `*integration*test*`
- Identify **testable source projects**: `*.csproj` not under excluded paths and not themselves test projects.
- For each directory with C# code, enumerate **public concrete types** (classes/records/structs) that contain logic.

**Path mapping from code → tests**  
When creating test file paths, **drop common root segments** if they appear at the start of a path (case-insensitive):  
`src`, `source`, `app`, `apps`, `packages`, `projects`, `modules`.  
Examples:
- `src/Infrastructure/Pipelines/ChannelService.cs` → `Infrastructure/Pipelines/ChannelServiceTests.cs`
- `app/Application/Channel/Direct.cs` → `Application/Channel/DirectTests.cs`

---

## 2) Test projects (reuse or create)

### Reuse if found
- Search for csproj whose filename or `<AssemblyName>` equals **ThunderPropagator.UnitTests** and **ThunderPropagator.ArchTests** (case-insensitive).
- Record absolute paths; **keep original names/locations**.

### Create if missing
- `Tests/UnitTests/UnitTests.csproj`
- `Tests/ArchTests/ArchTests.csproj`

**csproj baselines (only when creating new)**

**UnitTests.csproj**
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />
    <PackageReference Include="xunit" Version="2.9.2" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.8.2">
      <IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
      <PrivateAssets>all</PrivateAssets>
    </PackageReference>
    <PackageReference Include="NSubstitute" Version="5.1.0" />
    <PackageReference Include="coverlet.collector" Version="6.0.2">
      <PrivateAssets>all</PrivateAssets>
      <IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
    </PackageReference>
  </ItemGroup>
</Project>
