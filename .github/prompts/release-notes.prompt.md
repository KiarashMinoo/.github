---
mode: agent
description: 'Generate or update CHANGELOG.md from git commits. Reads per-branch state from .github/changelog-state.json to resume from where it left off. Falls back to the first commit when no state exists. On release branches generates from the previous release tag to the current one.'
tools: ['runCommands', 'editFiles', 'search/codebase']
---

# Changelog Generator

Act autonomously. Do not ask for confirmations unless a destructive action is ambiguous.  
Always write results to **`CHANGELOG.md`** at the repository root.

---

## Step 0 — Detect context

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
HEAD_SHA=$(git rev-parse HEAD)
REPO_ROOT=$(git rev-parse --show-toplevel)
STATE_FILE="$REPO_ROOT/.github/changelog-state.json"
```

Determine branch category:
- `develop` → **incremental develop** mode
- `release/*` or `main` → **release** mode
- anything else (`feature/*`, `bugfix/*`, `hotfix/*`) → **preview** mode (write output, do not save state)

---

## Step 1 — Load state

`$STATE_FILE` stores one JSON entry per branch:

```json
{
  "develop": { "lastSha": "abc123", "updatedAt": "2025-01-01T00:00:00Z" },
  "release/1.0.0": { "lastSha": "def456", "updatedAt": "2025-01-02T00:00:00Z" }
}
```

- File missing or no entry for `$BRANCH` → `lastSha` is empty.
- `lastSha` set but not an ancestor of `HEAD` (force-push / rebase) → fall back to empty, do a full rebuild.

---

## Step 2 — Determine commit range

### develop / preview mode

```bash
if [ -z "$LAST_SHA" ]; then
  START=$(git rev-list --max-parents=0 HEAD)   # very first commit
  RANGE="$START^..HEAD"
else
  RANGE="$LAST_SHA..HEAD"
fi
```

If `LAST_SHA == HEAD_SHA` → print "Nothing to update" and exit.

### release mode

1. Fetch and list all version tags (oldest → newest):

   ```bash
   git fetch --tags --force
   git for-each-ref --sort=creatordate --format='%(refname:short)' refs/tags \
     | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+'
   ```

2. Find the tag at or nearest before `HEAD`:

   ```bash
   CURRENT_TAG=$(git describe --tags --exact-match HEAD 2>/dev/null \
     || git describe --tags --abbrev=0 HEAD 2>/dev/null)
   ```

3. Find the tag immediately before `CURRENT_TAG` → `PREV_TAG`.
4. `RANGE="$PREV_TAG..$CURRENT_TAG"` (or `$PREV_TAG..HEAD` when not on an exact tag).
5. No previous tag → `$(git rev-list --max-parents=0 HEAD)^..HEAD`.

---

## Step 3 — Collect commits

```bash
git log "$RANGE" \
  --pretty=format:"%H|%h|%ad|%s|%an" \
  --date=short \
  --no-merges
```

Parse each line as: `FULL_SHA | SHORT_SHA | DATE | SUBJECT | AUTHOR`.

For ambiguous subjects, also collect changed files:

```bash
git log "$RANGE" --name-status --no-merges \
  --pretty=format:"COMMIT|%H|%s"
```

Skip commits whose subject contains `[skip ci]` or are authored by `github-actions[bot]`.  
Limits: max 50 changed files and 200 changed lines per commit.

---

## Step 4 — Categorise

Group by Conventional Commit type from `type(scope): message`:

| Section | Types |
|---------|-------|
| ⚠️ Breaking Changes | subject has `!` after type or body contains `BREAKING CHANGE` |
| 🚀 Features | `feat` |
| 🐛 Bug Fixes | `fix` |
| ⚡ Performance | `perf` |
| ♻️ Refactoring | `refactor` |
| 🔒 Security | `security` |
| 📦 Dependencies | `deps`; or `build` when a `.csproj`/`.props` file changed |
| ⚙️ CI / Tooling | `ci`, `build` |
| 📝 Documentation | `docs` |
| 🧪 Tests | `test` |
| 🏠 Chores | `chore`, `style`, `revert`, anything else |

When the subject does not follow Conventional Commits, infer the type from changed file paths:
- `*.cs` → feat or fix (use context)
- `*.csproj` / `*.props` → deps
- `*.yml` / `*.yaml` → ci
- `*.md` → docs
- `Tests/**` → test

Strip the `type(scope):` prefix from the displayed message.

---

## Step 5 — Write CHANGELOG.md

### File header (create once; never overwrite)

```markdown
# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
```

### Release mode — prepend a new tagged section

```markdown
## [1.2.0] — 2025-06-01

### ⚠️ Breaking Changes
- Removed `Foo.Bar()` overload `(abc1234)` — Author

### 🚀 Features
- Add new feature `(def5678)` — Author

### 📦 Dependencies
| Package | Old | New |
|---------|-----|-----|
| Some.Package | 1.0.0 | 1.1.0 |
```

Prepend immediately after the header. Keep all older sections intact.

### develop / preview mode — update `[Unreleased]`

Replace the `[Unreleased]` section if it exists; otherwise insert it after the header.  
Never touch tagged version sections below it.

```markdown
## [Unreleased]

### 🚀 Features
- ...
```

---

## Step 6 — Update state (skip for preview mode)

Merge only the entry for `$BRANCH`. Do not delete entries for other branches.

```json
{ "<branch>": { "lastSha": "<HEAD_SHA>", "updatedAt": "<ISO8601 UTC>" } }
```

Create `.github/` if it does not exist.

---

## Step 7 — Report

- Branch and mode (incremental / full-rebuild / release / preview).
- Commit range used.
- Sections written with entry counts.
- Whether state was updated.

---

## Quality rules

- Each entry: one line, capital first letter, no trailing period.
- Append short SHA in backticks: `(abc1234)`.
- Never duplicate an entry already in the file.
- NuGet version bumps detected from `.csproj` / `Directory.Build.props` diffs go in a 📦 Dependencies table (Package | Old | New).
- Commits touching only `Tests/**` → 🧪 Tests.
- Commits touching only `*.md` → 📝 Documentation.
