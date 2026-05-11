---
mode: agent
description: "Deep recursion docs under /docs. Generate rich README.md for every non-test folder from *.cs; never leave a README empty. Strip leading src and common project-name prefixes from paths. Include NuGet package metadata. Mermaid diagrams per folder. Auto-generated Docs Catalog in root README. Per-folder retry up to 3 passes. Parents link to children only."
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# Docs Generator

Act autonomously and **do not ask for confirmations** unless Copilot requires it. Use safe defaults.

## Structural Rules

* **Deep recursion**: create `/docs/<canonical path>/README.md` for **every** non-excluded folder (any depth).
* **Only README.md files** (plus `/docs/README.md` and **root/solution `/README.md` update at the end**).
* **Parents link to direct children only** (no child content merged into parent).
* **Drop all `src` segments** from docs paths (case-insensitive).
* **Strip the common project-name prefix** from each path segment: detect it from the repository root folder name or the solution name (e.g. if the repo is named `Foo.Bar`, strip `Foo.Bar.` from each segment).
* **Exclude tests** entirely.
* **Wipe `/docs`** before rebuilding.
* **NuGet packages**: detect the feed URL from `NuGet.Config` in the repo root. If not found, use `https://api.nuget.org/v3/index.json`.
* **Create `/docs/README.md`** landing and link to each top-level layer found under `src/`.
* **Update root/solution `/README.md` at the end** to link to `docs/README.md` and embed the auto-generated **Docs Catalog** (see policies below).
* **No “Source Location” / file system paths** in docs. Use **cross-doc links + anchors** only.

### Run Controls (flags)

* `reset` (bool, default: **true**): when **true**, delete the entire `/docs` folder first (full rebuild).
* `incremental` (bool, default: **false**): when **true**, do **not** delete `/docs`; update only changed/missing READMEs. Still enforces empty-prevention.
* `dryRun` (bool, default: **false**): compute what would change (including catalog/coverage updates) but do not write files; print a summary.
* `maxRetries` (int, default: **3**): cap per-folder retries to converge non-empty READMEs.
* `readmeTarget` (enum: **auto** | root | solution, default: **auto**):
  * **auto**: prefer repository root `/README.md` if present or writeable; otherwise, if exactly one `*.sln` exists, update/create `README.md` **next to that solution**; if multiple `.sln` files, fall back to root.
  * **root**: update/create `/README.md` at repo root only.
  * **solution**: update/create `README.md` **alongside the primary solution** (see detection rules).
* `readmeMode` (enum: **replaceSection** | append, default: **replaceSection**):
  * **replaceSection**: update only the managed block between markers (idempotent).
  * **append**: append the generated block to the end (keeps prior blocks intact).

## Empty-Prevention Rules (required)

A folder README **must not** be empty or skeletal. If initial extraction yields too little, escalate **in the same run**:

**Pass 1 — Public surface (normal)**

* Parse `*.cs` in this folder for **public** types/members, XML docs, attributes (serialization/validation).
* Produce all required sections (see “Folder README — Required Sections”).

**If README is still sparse (e.g., < 10 meaningful lines OR no Types table when code exists), do Pass 2.**

**Pass 2 — Broader scan (internal)**

* Include **internal** types/members for summaries.
* Use symbol names, attributes, and usage patterns to infer one-liners.
* Build a **Files** table for every file in the folder (ignore tests), with a short inferred responsibility.

**If sparse again, do Pass 3.**

**Pass 3 — Heuristics & fallbacks**

* Derive concepts from file/namespace names (e.g., “Pipelines”, “Adapters”, “Models”).
* Generate at least:
  * Overview (2–5 sentences),
  * Files table (all files),
  * A minimal **API Reference (Summary)** listing key types (public+internal) with one-line descriptions,
  * One **Usage Recipe** relevant to the folder (even if generic, but realistic for the domain).
* If absolutely no `.cs` files and no children: create a **Leaf README** with “Files: *None*” and a TODO line prompting future description.
* Mark the README with a gentle banner if content relied on heuristics:

  > *Note: Some details inferred due to limited XML docs. Consider adding summaries/remarks to source.*

**Never leave a README with only a title and one small paragraph.**

## Canonicalization (paths & titles)

1. Split repo path → segments.
2. Remove every `src` segment (case-insensitive).
3. For each remaining segment, strip the common project-name prefix: detect it from the solution name or repo root folder name (regex `^(<detected-prefix>)([.\-_])?`, case-insensitive). If no prefix is detected, leave the segment unchanged.
4. Normalize: collapse duplicate separators/dots/hyphens/underscores; trim; drop empties.
5. Collision safety: if two sources canonicalize to the same docs path, keep the first; suffix later (e.g., `-rs` or short hash). Record in audit.
6. Destination: /docs/<canonical>/README.md

## Exclusions (strict)

* Skip paths whose any segment matches (case-insensitive): `test`, `tests`, `testing`, `.tests`, `*unit*test*`, `*integration*test*`.
* Skip: `.git`, `.github` (except `.github/prompts`), `.vs`, `.idea`, `node_modules`, `bin`, `obj`, caches/build artifacts.
* Do not traverse `/docs` during generation.

## Cross-Document Linking & Bookmarks (required)

* Every README has `## Contents` with anchor links to all major sections.
* Use relative links: `./Child/README.md`, `../Sibling/README.md#api-reference-summary`.
* Stable anchors: default Markdown slugs; for types use `### TypeName` → `#typename`.
* End long sections with `[↑ Back to top](#contents)`.

---

## **Diagrams (Mermaid & Graphs) — Add / Keep / Update**

> Ensure every relevant README includes an up-to-date **Diagrams** section. Prefer **Mermaid** code blocks. Keep existing diagrams, update when APIs/flows change, and add new ones when helpful.

### What to include

* **Architecture overviews** (module boundaries, data/control flow).
* **Class/Type relationships** (interfaces, inheritance, key dependencies).
* **Sequences** (client ↔ server, pipeline stages, async flows).
* **State/Activity** (state machines, background jobs).
* **Graphs** (simple node/edge overviews) using Mermaid `graph`.

### General rules

* Embed diagrams as fenced code blocks:

  \`\`\`
  ```mermaid
  graph TD
    A[Entry] --> B{Validate}
    B -->|ok| C[Handle]
    B -->|error| E[Fail]
  ```
  \`\`\`

* **Keep** any existing ` ```mermaid` blocks in source docs or prior READMEs. **Update** nodes/edges to match current APIs/types.
* For images (PNG/SVG) already in repo, keep relative links and filenames; do **not** hardcode absolute paths. Place under `/docs/assets/<canonical>/` if exporting.
* Keep diagrams **small and legible**: ≤ 30 nodes per diagram; split into multiple diagrams if larger.
* Cross-link from **Files** and **Types** sections to the **Diagrams** anchors where relevant (e.g., “see [Pipeline sequence](#pipeline-sequence)”).
* If uncertain, add an *Assumptions* bullet under the diagram and mark with the heuristics banner.

### When to auto-generate

* If a folder exposes **>2 public types** that collaborate, generate at least one diagram (sequence or class graph).
* For folders named like `Pipelines`, `Adapters`, `Handlers`, `Controllers`, or `Stores`, include a **sequence** and a **component** diagram.
* If a `*.csproj` references packages from a private NuGet feed (detected via `NuGet.Config`), add a small **dependency graph** (packages ↔ this assembly).

### Mermaid templates

* **Sequence (request → handler → store)**

  \`\`\`
  ```mermaid
  sequenceDiagram
    participant C as Client
    participant H as <Handler>
    participant R as <Repository/Store>
    C->>H: Execute(command)
    H->>R: Load/Save
    R-->>H: Result
    H-->>C: Response
  ```
  \`\`\`

* **Class (key types)**

  \`\`\`
  ```mermaid
  classDiagram
    class FooService {
      +Execute(cmd): Result
      -logger: ILogger
    }
    interface IFooRepository
    FooService --> IFooRepository : uses
  ```
  \`\`\`

* **Component/Graph (module overview)**

  \`\`\`
  ```mermaid
  graph LR
    API[Web API] --> Core[Core Services]
    Core --> Cache[(Cache)]
    Core --> DB[(Database)]
  ```
  \`\`\`

### Update policy

* Regenerate or edit diagrams **in the same pass** when types/methods changed.
* Keep anchors stable: `## Diagrams`, then `### <Short Name>` per diagram.
* Add a short caption under each diagram (1–2 sentences) explaining the scenario.

---

## Folder README — Required Sections

(omit only if truly N/A and write ***Not applicable***)

1. **Title & TOC**
2. **Overview** (2–5 sentences)
3. **Files / Scripts**

   * **Files table (C#/general):**
     | File | Primary type(s) | LOC (approx) | Responsibility |
   * **Scripts table (when `*.ps1`/`*.psm1` exist):**
     | Script | Type (script/module) | Synopsis | Requires (modules/tools) | Notes |
4. **Types & Members** (when any C# types exist in this folder)

   * Types table:
     | Type | Kind | Summary | Inherits/Implements | Key Members |
   * Per-type details:

     * `### <TypeName>`

       * Kind, Namespace
       * Inherits/Implements
       * Attributes (serialization/validation)
       * Key Properties (name : type — one-liner, nullability)
       * Key Methods (signature — one-liner; notable params)
       * Events (if any)
       * Constructors/Factories (notable)
       * Thread-safety / immutability
       * Serialization notes
       * Validation notes
       * **Usage Recipe** (realistic, **no test examples**)
5. **Script Parameters & Examples** (when scripts exist)

   * For each script/function, include a **Parameters** table:
     | Name | Type | Mandatory | Position | Pipeline | Default | Validation |
   * Include **Examples** from help or inferred realistic calls.
   * **Execution** subsection with safe invocation notes (ExecutionPolicy, relative paths).
6. **Serialization & Contracts** (if applicable)
7. **Validation & Constraints** (if applicable)
8. **Performance Notes** (if applicable)
9. **NuGet Dependencies** (if used here)

   * Table (**Package | Version | Description | Links**)
   * Links: NuGet feed URL (from `NuGet.Config`), Repo URL (if any), internal anchors
10. **Benchmarks / Architecture / Diagrams** (if present)

* Always include a **Diagrams** subsection; for scripts, prefer a Mermaid **flowchart** or **sequence** depicting the control flow and external tools.

11. **Examples** (short; no tests)
12. **See Also** (siblings/parent)

### Leaf README (no child folders)

* Title & TOC
* Overview
* Files (or “*None*”)
* API Reference (Summary) if any types exist
* **Diagrams** (add at least one Mermaid graph when helpful; otherwise mark *Not applicable*)
* Optional sections as applicable
* Back-to-top

## NuGet Dependencies

* Detect the NuGet feed URL from `NuGet.Config` at the repo root; fall back to `https://api.nuget.org/v3/index.json`.
* Detect packages from `*.csproj`, `Directory.Packages.props`, `packages.lock.json`, or `dotnet list package`.
* Record: `Id`, resolved `Version`, `Description`, `Project URL`, `Repository URL` (if any), `License`, `Authors`.
* Per-folder README: add table + internal deep links to usage anchors.
* Root `/README.md`: roll-up table of all unique packages with deep links to folders’ `#nuget-dependencies`.
## Docs Landing + Root/Solution README

* Create `/docs/README.md` (landing): title, short intro, links to `./Application/README.md` & `./Infrastructure/README.md` (if present), plus other top-level areas.
* **Docs Catalog for Root/Solution `/README.md` (auto-generated):**

  * Add a **Documentation** section that embeds a **catalog** derived from the `/docs` tree.
  * Catalog format:

    * Top-level list of areas (one level deep): each item links to the corresponding `/docs/<area>/README.md`.
    * For each area, include an indented sub-list of its **direct children** (folders) with links.
    * Show **badges** per folder:

      * `Types:n` (number of public types found)
      * `Files:n` (non-test files)
      * `Diagrams:✓/✗` (presence under **Diagrams** section)
    * Add a small **Last generated** timestamp.
  * Include a short intro sentence and a link to `docs/README.md`.
* **Update root/solution `/README.md`** to link to `docs/README.md`, show NuGet sources (parse `nuget.config`, show add-source for GitHub feed if missing) and:

  ```bash
  dotnet restore
  dotnet build -c Release
  ```

### Docs Catalog — Generation Rules (Root/Solution README)

* Source of truth is the **/docs** folder produced in this run (do **not** parse `src`).
* Build a **two-level** hierarchy (Area → Child): parents list only direct children.
* For each listed folder, compute badges:

  * **C# types present:**

    * `Types` = count of **public** types summarized (fallback to internal if public is 0 but types exist).
    * `Files` = number of non-test files in **Files** table.
  * **Scripts present:**

    * `Scripts` = number of `ps1/psm1` items.
    * `Functions` = exported or top-level functions counted from docs.
  * Always include `Diagrams` = `✓` if a `## Diagrams` section has ≥1 Mermaid block; else `✗`.
* Render badges as inline code; sort areas/children alphabetically; keep stable across runs.
* If a README is flagged with the heuristics banner, append `(heuristic)`; if missing required sections, append `(needs details)`.

## Coverage Audit (append to `/docs/README.md`)

List every traversed folder with a ✅ if required sections (incl. **Diagrams**) are present, or ❌ with reasons and retry counts. Include collision/rename notes.

---

## Root/Solution README — Example Catalog Snippet

> The generator should produce something like the following (structure-only):

```markdown
## Documentation

This repository publishes generated documentation under [`/docs`](docs/README.md). The catalog below links to areas and key subfolders.

- Application `Types:12` `Files:23` `Diagrams:✓`
  - Adapters `Types:3` `Files:6` `Diagrams:✓`
  - Handlers `Types:5` `Files:8` `Diagrams:✓`
- Infrastructure `Types:9` `Files:17` `Diagrams:✗`
  - Persistence `Types:4` `Files:7` `Diagrams:✗`
  - Messaging `Types:3` `Files:5` `Diagrams:✓`
```
**Last generated:** January 2025