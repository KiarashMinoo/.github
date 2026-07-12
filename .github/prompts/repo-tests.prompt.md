---
mode: agent
description: "Scan and generate tests for whichever stack(s) are detected in the repo. .NET: xUnit + NSubstitute + FluentAssertions (pinned <8.0.0, Apache-2.0) + NetArchTest under a 'Tests' solution folder. Node/TS: Vitest + dependency-cruiser. Python: pytest + unittest.mock + import-linter. Go: stdlib testing + testify. Java/Kotlin: JUnit5 + Mockito + AssertJ + ArchUnit. All libraries are free/OSS with no paid tier — never Moq, never FluentAssertions >=8.0.0. Non-interactive and idempotent."
tools: ['runCommands', 'editFiles', 'search/codebase']
---

# Test Generator

Act autonomously. **Do not ask for confirmations.** Make idempotent changes.
**Never modify production code** — only create or update files inside test projects/directories.

---

## 0) Stack detection

Detect every stack present in the repo — a repo may contain more than one (e.g. a .NET backend + a TS frontend):

| Stack | Detected by |
|---|---|
| .NET | `*.sln`, `*.slnx`, `*.csproj` |
| Node / TypeScript | `package.json` |
| Python | `pyproject.toml`, `setup.py`, `requirements*.txt` |
| Go | `go.mod` |
| Java / Kotlin | `pom.xml`, `build.gradle(.kts)` |

Apply the matching section below to each detected stack, scoped to that stack's own source subtree. Sections not listed here (Discovery, Idempotency, Output report) apply to every stack.

## 1) Library selection rule (applies to every stack)

- Only select testing/mocking/assertion libraries that are permissively licensed (MIT, BSD, Apache-2.0) with **no paid tier, no commercial-license requirement, and no telemetry/sponsorware mechanism**.
- Explicitly excluded, regardless of version: **Moq** (2023 SponsorLink telemetry incident) and **FluentAssertions ≥ 8.0.0** (relicensed to a paid commercial model in 2024/2025 — pin to the last Apache-2.0 line, `7.x`, and never let it float past `8.0.0`).
- Prefer the language's own standard-library test tooling first (e.g. Go's `testing`, Python's `unittest.mock`); reach for a third-party package only when the stdlib is insufficient.

## 2) Discovery (all stacks)

Walk the entire repo, excluding:
- Existing test directories/projects, `.git`, `.github` (keep `.github/prompts`), `.vs`, `.idea`, `bin`, `obj`, `node_modules`, `dist`, `build`, `.venv`, `__pycache__`, `target`
- Any path segment matching (case-insensitive): `test`, `tests`, `.tests`, `*unit*test*`, `*integration*test*`

For each non-excluded directory with source code in a detected stack:
- Enumerate the public/exported concrete types, classes, or functions containing logic (see each stack's section for the exact rule).
- Note benchmark-only code (e.g. `[MemoryDiagnoser]`/`[Benchmark]` in .NET) — list in the report but skip unit test generation for it.

**Path mapping:** strip each stack's conventional source-root segments (`src`, `source`, `app`, `apps`, `packages`, `projects`, `modules`, `lib`) when mirroring into the test tree.
Example: `src/Application/Foo/Bar.cs` → `Application/Foo/BarTests.cs`; `src/foo/bar.py` → `tests/foo/test_bar.py`.

---

## .NET

### Global behavior

- **Reuse** existing test projects whose assembly name ends with `UnitTests` or `ArchTests`.
- If missing, **create** them under `Tests/UnitTests` and `Tests/ArchTests`.
- Both projects must be inside the `.sln` under a solution folder named **`Tests`**.
- If no `.sln` exists, create one named after the repo root folder.
- **Target framework**: `net10.0`.
- **Enable preview features** (`<EnablePreviewFeatures>true</EnablePreviewFeatures>`).

### csproj baselines (create only if missing)

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
    <!-- NSubstitute, not Moq: no SponsorLink telemetry, plain MIT license -->
    <PackageReference Include="NSubstitute" Version="5.3.0" />
    <!-- Pinned <8.0.0: FluentAssertions 8+ requires a paid commercial license -->
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

### Unit test rules

For every public concrete type:
- File: `<TypeName>Tests.cs` at the mirrored path in the UnitTests project.
- Framework: `[Fact]` for single-case, `[Theory]` + `[InlineData]` for data-driven.
- Mocks: `NSubstitute` — `Substitute.For<IInterface>()`.
- Assertions: `FluentAssertions` (`7.x`) — `result.Should()...`.
- Layout: **AAA** — `// Arrange`, `// Act`, `// Assert` in each test.
- Naming: class = `<TypeName>Tests`; method = `<Method>_<Scenario>_<Expected>`.
- Cover: constructors, public methods, edge cases (null, empty, boundary values).
- Never test private members; never modify production code.

### Architecture test rules

Use `NetArchTest.Rules`:

1. Auto-detect layers by scanning namespace roots in `src/`.
2. For each layer pair where one must not depend on the other, generate a `Types.InAssembly(...).Should().NotHaveDependencyOn(...)` assertion.
3. Enforce that types reside in their expected namespaces.
4. Enforce that types in namespaces containing `Helpers` are declared `static`.
5. Enforce no circular assembly-level dependencies.

---

## Node / TypeScript

### Global behavior

- **Reuse** an existing test config (`vitest.config.ts`/`.js`, or a `vitest` block in `package.json`); create one only if missing.
- Test files live next to source as `<name>.test.ts` (or under a mirrored `tests/`/`__tests__/` tree if that's the repo's existing convention — detect and follow it).
- Framework: **Vitest** (MIT) — bundles test runner, `expect` assertions, and `vi.fn()`/`vi.mock()` mocking in one dependency, so no separate mocking/assertion library is needed.

### Unit test rules

For every exported function/class:
- Use `describe`/`it` blocks; one `describe` per exported symbol.
- Mocks: `vi.fn()`, `vi.spyOn()`, `vi.mock()` — never a third-party mocking library.
- Assertions: built-in `expect(...)`.
- Naming: `it('<method> <scenario> <expected>', ...)`.
- Cover: exported functions/classes, edge cases (undefined, empty, boundary values).
- Never test unexported (non-`export`ed) symbols; never modify production code.

### Architecture test rules

Use `dependency-cruiser` (MIT):
1. Auto-detect layers from top-level folders under `src/`.
2. For each layer pair where one must not depend on the other, add a `forbidden` rule to `.dependency-cruiser.js`.
3. Enforce no circular imports (`no-circular` rule).
4. Run via `depcruise --validate`; report violations, do not auto-fix.

---

## Python

### Global behavior

- **Reuse** an existing `tests/` directory and `pytest` configuration (`pyproject.toml [tool.pytest.ini_options]` or `pytest.ini`); create if missing.
- Test files: `tests/<mirrored path>/test_<module>.py`.
- Framework: **pytest** (MIT).

### Unit test rules

For every public function/class (not prefixed `_`):
- One `test_<function>_<scenario>_<expected>` function per case; use `@pytest.mark.parametrize` for data-driven cases.
- Mocks: stdlib `unittest.mock` (`Mock`, `MagicMock`, `patch`) — no third-party mocking library needed.
- Assertions: plain `assert` statements (pytest rewrites them for rich failure output) — no assertion library needed.
- Cover: public functions/classes, edge cases (`None`, empty, boundary values).
- Never test private (`_`-prefixed) members; never modify production code.

### Architecture test rules

Use `import-linter` (BSD) with a `.importlinter` contracts file:
1. Auto-detect layers from top-level packages.
2. For each layer pair where one must not import the other, add a `forbidden` contract.
3. Add a `layers` contract enforcing overall layer ordering.
4. Run via `lint-imports`; report violations, do not auto-fix.

---

## Go

### Global behavior

- **Reuse** existing `_test.go` files; create new ones alongside the code they test (Go convention — same package, same directory).
- Framework: standard library `testing`.

### Unit test rules

For every exported (capitalized) function/type:
- File: `<file>_test.go` next to `<file>.go`.
- Style: table-driven tests (`[]struct{ name string; ... }` + `t.Run(tt.name, ...)`).
- Assertions: plain `if got != want { t.Errorf(...) }`; add `testify/assert` (MIT) only if the repo already uses it or table-driven stdlib checks get unwieldy.
- Mocks: hand-written fakes implementing the interface, or `testify/mock` (MIT) if already in use — avoid introducing a new mocking dependency for a small interface.
- Naming: `Test<Function>_<Scenario>`.
- Never test unexported identifiers directly (test via the exported API, or via an internal `_test.go` in the same package when necessary); never modify production code.

### Architecture test rules

No third-party tool needed — Go's own tooling is sufficient:
1. Auto-detect layers from top-level packages under the module root.
2. For each layer pair where one must not depend on the other, write a small test using `go/build` or `golang.org/x/tools/go/packages` to inspect the import graph and fail if a forbidden import exists.
3. Enforce no import cycles (Go's compiler already rejects these; the test only needs to check cross-layer direction).

---

## Java / Kotlin

### Global behavior

- **Reuse** existing `src/test/java` or `src/test/kotlin` source sets; create if missing (standard Maven/Gradle layout).
- Framework: **JUnit 5** (EPL 2.0, free).

### Unit test rules

For every public concrete class:
- File: `<ClassName>Test.java`/`.kt` at the mirrored path under `src/test/...`.
- Mocks: **Mockito** (MIT) — `mock(Interface.class)` / `mockk` idioms for Kotlin.
- Assertions: **AssertJ** (Apache-2.0) — `assertThat(result)...`.
- Naming: class = `<ClassName>Test`; method = `<method>_<scenario>_<expected>`.
- Cover: constructors, public methods, edge cases (null, empty, boundary values).
- Never test private members; never modify production code.

### Architecture test rules

Use **ArchUnit** (Apache-2.0):
1. Auto-detect layers by scanning top-level packages.
2. For each layer pair where one must not depend on the other, generate a `noClasses().that().resideInAPackage(...).should().dependOnClassesThat().resideInAPackage(...)` rule.
3. Enforce that classes reside in their expected packages.
4. Enforce no cyclic package dependencies (`slices().matching(...).should().beFreeOfCycles()`).

---

## Idempotency (all stacks)

- Existing test methods/cases: merge new ones in; never overwrite.
- Duplicate method/case names: skip.
- Duplicate project/module references: skip.
- Two runs on the same repo must produce identical output.

---

## Output report (all stacks)

- Stack(s) detected.
- Test files created / updated, per stack.
- Test methods/cases added.
- Types/symbols skipped (with reason).
- Architecture violations found.
