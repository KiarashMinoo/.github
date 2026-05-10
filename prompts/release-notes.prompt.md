---
mode: 'agent'
description: 'Generate/update release notes with content-aware summaries; optimized for C++ (.cpp/.hpp), supports incremental updates via last processed commit state'
tools: ['runCommands', 'editFiles', 'search/codebase']
---

# Goal

Generate or update **${input:outputFile:CHANGELOG.md}** from git tags and commits with **content-aware analysis** focused on **C/C++** sources/headers while still handling all file types.
- Include an **Unreleased** section comparing the selected start point to `HEAD` (latest tag by default, or last processed commit if state exists and refresh is not requested).
- Group commits by Conventional Commit type (feat, fix, perf, refactor, docs, chore, build, ci, test, style, revert, deps, other).
- Derive smart summaries using **diff contents**: API/ABI changes in headers, function signature changes, template/class updates, build system changes (CMake/Conan/vcpkg/Bazel), config/security/perf notes.
- Persist and reuse **last processed commit** to support **incremental** updates when `${input:refresh:false}` is not set.
- Link each tag section to a GitHub compare URL when ${input:repoOwner} and ${input:repoName} are provided.
- **If ${input:resetAll:false} is true, rebuild the file from scratch (overwrite)** and reset persisted state.

# Inputs

- **Tag filter (glob/regex)**: ${input:tagFilter:^v?\d+\.\d+\.\d+$}
- **Output file**: ${input:outputFile:CHANGELOG.md}
- **Repo owner**: ${input:repoOwner}
- **Repo name**: ${input:repoName}
- **Date format**: ${input:dateFormat:yyyy-MM-dd}
- **Section title**: ${input:title:Changelog}
- **Include Unreleased**: ${input:includeUnreleased:true}
- **🔁 Reset all (overwrite file)**: ${input:resetAll:false}
- **🔄 Refresh (ignore saved state and recompute from tags)**: ${input:refresh:false}
- **💾 State file path**: ${input:stateFile:.github/release-notes.state.json}

## Scope & Presentation
- **Summary style** (`concise` | `standard` | `detailed`): ${input:summaryStyle:standard}
- **Max highlights per tag**: ${input:maxHighlights:6}
- **Max bullets per section** (0 = unlimited): ${input:maxBulletsPerSection:0}
- **Include file lists**: ${input:includeFiles:true}
- **Include small code snippets**: ${input:includeSnippets:true}
- **Snippet max chars**: ${input:snippetLimit:320}

## Diff & Analysis Controls
- **Diff context lines** (0..5): ${input:diffContext:0}
- **Max files per commit** (0 = unlimited): ${input:fileLimit:0}
- **Max hunks per file** (0 = unlimited): ${input:hunkLimit:2}
- **Max lines per hunk** (0 = unlimited): ${input:linesPerHunk:40}
- **Max total diff lines per commit**: ${input:linesPerCommit:300}
- **Include paths (glob, comma-separated)**: ${input:pathInclude:**/*.{h,hpp,hxx,hh,c,cc,cpp,cxx},CMakeLists.txt,**/*.cmake,conanfile.*,vcpkg.json,**/*.bazel,WORKSPACE,.clang-format,.clang-tidy}
- **Exclude paths (glob, comma-separated)**: ${input:pathExclude:}
- **Skip types (comma-separated)**: ${input:skipTypes:}
- **Fold empty sections**: ${input:foldEmpty:true}

## Contents Modes
- **🧩 Include diff contents**: ${input:includeContents:true}
- **Contents mode** (`diff-hunks` | `added-lines` | `removed-lines` | `api-changes`): ${input:contentsMode:api-changes}
- **Language mode** (`auto` | `cpp`): ${input:languageMode:cpp}

# Plan

1. **Determine start point (incremental vs full)**  
   - Compute `HEAD_SHA=$(git rev-parse HEAD)` and `BRANCH=$(git rev-parse --abbrev-ref HEAD)`.
   - If **resetAll=true** → **full** run from tags; delete `${input:stateFile}` if present.
   - Else if **refresh=true** → **full** run from tags; ignore `${input:stateFile}`.
   - Else, if `${input:stateFile}` exists and contains a valid `lastProcessedSha` on the **same branch** (or the same repo ref):
     - Use `START_SHA = lastProcessedSha` and run **incremental** only for the range `START_SHA..HEAD`.
     - If `START_SHA == HEAD_SHA`, there is nothing new; still update timestamps if needed.
   - Else (no state) → **full** run from tags as before.

2. **Collect tags & ranges (for full runs)** — **ALL tags** (no trimming)
   - `git fetch --tags --force`
   - List tags (filter using **tagFilter** in-memory). **Do not pipe to `Select-Object -Last N` in PowerShell.**
     - Bash/PowerShell (oldest → newest):
       ```
       git for-each-ref --format='%(refname:short)|%(creatordate:short)' --sort=creatordate refs/tags
       ```
     - Bash/PowerShell (newest → oldest):
       ```
       git for-each-ref --format='%(refname:short)|%(creatordate:short)' --sort=-creatordate refs/tags
       ```
     - Windows cmd.exe (escape `%` as `%%`):
       ```
       git for-each-ref --format="%%(refname:short)|%%(creatordate:short)" --sort=-creatordate refs/tags
       ```
   - Build ranges per tag (first tag uses `<tag>^!` if release commit style; else `<prevTag>..<tag>`).
   - If **includeUnreleased**: add `<latestTag>..HEAD` as **Unreleased**.

3. **Collect commits, files, and diffs (for both full & incremental)**
   - Base commit header (prefixed `@@@`):
     - `--pretty=format:'@@@%H%x09%h%x09%ad%x09%s%x09%an'`
   - Recommended for analysis (files + hunks):
     ```bash
     git log --date=short \
  --pretty=format:'@@@%H%x09%h%x09%ad%x09%s%x09%an' \
  --name-status --patch --unified=${input:diffContext:0} --text \
  <RANGE> --
     ```
   - Enforce **fileLimit**, **hunkLimit**, **linesPerHunk**, **linesPerCommit** when rendering.

4. **C/C++-aware analysis rules**  
   (API/ABI detection in headers, function signatures, templates, build system changes, etc. — same as previous version.)

5. **Render & write**  
   - If **incremental**: update only the **Unreleased** section with the commits in `START_SHA..HEAD`, preserving previous tag sections.
   - If **full**: render Unreleased + all tag sections (respecting `${input:foldEmpty}`).
   - Write to `${input:outputFile}`:
     - **If ${input:resetAll:false} is true**: overwrite the whole file.
     - Else: update only the managed block between markers:
       ```
       <!-- BEGIN AUTO-RELEASE-NOTES -->
       ...generated markdown...
       <!-- END AUTO-RELEASE-NOTES -->
       ```

6. **Persist state**  
   - After a successful run, write `${input:stateFile}` JSON with:
     ```json
     {
       "lastProcessedSha": "<HEAD_SHA>",
       "branch": "<BRANCH>",
       "updatedAt": "<ISO8601 UTC>",
       "outputFile": "${input:outputFile}"
     }
     ```
   - Create the directory if it doesn’t exist (e.g., `.github/`).

7. **Report**
   - Print whether the run was **incremental** or **full**, the start SHA used, total commits/files analyzed, and which sections changed.

# Implementation snippets

```bash
# Detect state
STATE="${input:stateFile:.github/release-notes.state.json}"
if [[ "${input:resetAll:false}" == "true" ]]; then rm -f "$STATE"; fi

HEAD_SHA=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)

START_SHA=""
if [[ "${input:refresh:false}" != "true" && -f "$STATE" ]]; then
  if command -v jq >/dev/null 2>&1; then
    LAST=$(jq -r '.lastProcessedSha // empty' "$STATE")
    LAST_BRANCH=$(jq -r '.branch // empty' "$STATE")
  else
    LAST=$(grep -oE '"lastProcessedSha"\s*:\s*"[^"]+"' "$STATE" | sed -E 's/.*:"([^"]+)"/\1/')
    LAST_BRANCH=$(grep -oE '"branch"\s*:\s*"[^"]+"' "$STATE" | sed -E 's/.*:"([^"]+)"/\1/')
  fi
  if [[ -n "$LAST" && "$LAST_BRANCH" == "$BRANCH" ]]; then
    # Ensure START_SHA is ancestor of HEAD; otherwise fallback to full
    if git merge-base --is-ancestor "$LAST" "$HEAD_SHA"; then
      START_SHA="$LAST"
    fi
  fi
fi

# Choose ranges
if [[ -n "$START_SHA" ]]; then
  RANGES=("$START_SHA..$HEAD_SHA")
  MODE="incremental"
else
  MODE="full"
  # Build tag ranges as described in Plan step 2...
fi
```

# Constraints & Quality Bar

- Respect **tagFilter**; skip non-matching tags.
- Escape Markdown in subjects, paths, and snippets.
- Deterministic/idempotent given the same git state and state file.
- If the starting SHA is not an ancestor of `HEAD` (force-push/rebase), fallback to **full** run and rewrite state.
- If branch changed from saved state, fallback to **full** unless `${input:refresh:true}` is set.

# Now execute

1) Resolve start SHA (state vs refresh). 2) Collect logs for chosen ranges. 3) Analyze diffs. 4) Update Unreleased (incremental) or rebuild (full). 5) Persist `lastProcessedSha`. 6) Print a concise report.
