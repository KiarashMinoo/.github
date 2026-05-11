---
mode: agent
description: "Scan and generate tests. Reuse or create UnitTests and ArchTests projects under a 'Tests' solution folder. xUnit + NSubstitute + FluentAssertions unit tests; NetArchTest architecture tests. Non-interactive and idempotent. Targets net10.0 with preview features."
tools: ['runCommands', 'editFiles', 'search/codebase']
---

# Test Generator

Act autonomously. **Do not ask for confirmations.** Make idempotent changes.  
**Never modify production code** — only create or update files inside the test projects.

---

## 0) Global behavior

- Perform a **full scan** of the repository.
- **Reuse** existing test projects whose assembly name ends with `UnitTests` or `ArchTests`.
- If missing, **create** them under `Tests/UnitTests` and `Tests/ArchTests`.
- Both projects must be inside the `.sln` under a solution folder named **`Tests`**.
- If no `.sln` exists, create one named after the repo root folder.
- **Target framework**: `net10.0`.
- **Enable preview features** (`<EnablePreviewFeatures>true</EnablePreviewFeatures>`).

---

## 1) Discovery

Walk the entire repo, excluding:
- `Tests/**`, `.git`, `.github` (keep `.github/prompts`), `.vs`, `.idea`, `bin`, `obj`, `node_modules`
- Any path segment matching (case-insensitive): `test`, `tests`, `.tests`, `*unit*test*`, `*integration*test*`

For each non-excluded directory with C# code:
- Enumerate **public concrete types** (classes, records, structs) containing logic.
- Note `[MemoryDiagnoser]` / `[Benchmark]` types — list in the report but skip unit test generation.

**Path mapping:** Strip leading root segments (`src`, `source`, `app`, `apps`, `packages`, `projects`, `modules`).  
Example: `src/Application/Foo/Bar.cs` → `Application/Foo/BarTests.cs`

---

## 2) csproj baselines (create only if missing)

Auto-discover `ProjectReference` entries by scanning all non-test `*.csproj` files under `src/` and adding relative paths.

**UnitTests.csproj**
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <IsPackable>false</IsPackable>
    <EnablePreviewFeatures>true</EnablePreviewFeatures>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.12.0" />
    <PackageReference Include="xunit" Version="2.9.3" />
    <PackageReference Include="xunit.runner.visualstudio" Version="3.0.2">
      <IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
      <PrivateAssets>all</PrivateAssets>
    </PackageReference>
    <PackageReference Include="NSubstitute" Version="5.3.0" />
    <PackageReference Include="FluentAssertions" Version="7.2.0" />
    <PackageReference Include="BenchmarkDotNet" Version="0.14.0" />
    <PackageReference Include="coverlet.collector" Version="6.0.4">
      <PrivateAssets>all</PrivateAssets>
      <IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
    </PackageReference>
  </ItemGroup>
</Project>
```

**ArchTests.csproj**
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <IsPackable>false</IsPackable>
    <EnablePreviewFeatures>true</EnablePreviewFeatures>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.12.0" />
    <PackageReference Include="xunit" Version="2.9.3" />
    <PackageReference Include="xunit.runner.visualstudio" Version="3.0.2">
      <IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
      <PrivateAssets>all</PrivateAssets>
    </PackageReference>
    <PackageReference Include="NetArchTest.Rules" Version="1.3.2" />
    <PackageReference Include="FluentAssertions" Version="7.2.0" />
  </ItemGroup>
</Project>
```

---

## 3) Unit test rules

For every public concrete type:
- File: `<TypeName>Tests.cs` at the mirrored path in the UnitTests project.
- Framework: `[Fact]` for single-case, `[Theory]` + `[InlineData]` for data-driven.
- Mocks: `NSubstitute` — `Substitute.For<IInterface>()`.
- Assertions: `FluentAssertions` — `result.Should()...`.
- Layout: **AAA** — `// Arrange`, `// Act`, `// Assert` in each test.
- Naming: class = `<TypeName>Tests`; method = `<Method>_<Scenario>_<Expected>`.
- Cover: constructors, public methods, edge cases (null, empty, boundary values).
- Never test private members; never modify production code.

---

## 4) Architecture test rules

Use `NetArchTest.Rules`:

1. Auto-detect layers by scanning namespace roots in `src/`.
2. For each layer pair where one must not depend on the other, generate a `Types.InAssembly(...).Should().NotHaveDependencyOn(...)` assertion.
3. Enforce that types reside in their expected namespaces.
4. Enforce that types in namespaces containing `Helpers` are declared `static`.
5. Enforce no circular assembly-level dependencies.

---

## 5) Idempotency

- Existing test methods: merge new ones in; never overwrite.
- Duplicate method names: skip.
- Duplicate project references: skip.
- Two runs on the same repo must produce identical output.

---

## 6) Output report

- Test files created / updated.
- Test methods added.
- Types skipped (with reason).
- Architecture violations found.
