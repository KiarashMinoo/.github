# Security and quality tooling

Five tools are rolled out to every ThunderPropagator repository. CI logic lives here, in
reusable workflows; each repo has a thin `.github/workflows/security-scan.yml` caller plus a few config files.

| Tool | Purpose | Reusable workflow | Per-repo files |
|---|---|---|---|
| [gitleaks](https://github.com/gitleaks/gitleaks) | Hardcoded secrets in git history | `reusable-secret-scan.yml` | `.gitleaks.toml` |
| [OSV-Scanner](https://google.github.io/osv-scanner/) | Known-vulnerable dependencies (NuGet CPM / csproj, npm, GitHub Actions ...) | `reusable-osv-scan.yml` | none (optional `osv-scanner.toml`) |
| [jscpd](https://github.com/kucherenko/jscpd) | Copy/paste duplication | `reusable-code-quality.yml` | `.jscpd.json` |
| [knip](https://github.com/webpro-nl/knip) | Unused files, exports, dependencies in JS/TS | `reusable-code-quality.yml` | `knip.json` (only once a repo has a `package.json`) |
| [Lefthook](https://github.com/evilmartians/lefthook) | Local git hooks running the above before commit/push | n/a | `lefthook.yml` |

## When things run

`security-scan.yml` runs on pushes to the default branch, on pull requests, weekly (Monday 06:00 UTC) and on demand.

- **gitleaks** scans only the *new* commits of a push or pull request and **fails the run on any finding**. The weekly and manual runs scan the
  *full history* and report findings (SARIF artifact, code scanning) without failing, because a leaked historical secret has to be rotated, not
  fixed by a code change. Findings are always redacted.
- **OSV-Scanner** fails when it reports a vulnerability. Exit code 128 (no supported manifests, e.g. spec-only repos) counts as clean.
- **jscpd** fails when duplicated lines exceed `threshold` in `.jscpd.json`. Thresholds were set just above each repo's measured baseline
  (tests, generated code and build output excluded), so they stop duplication from growing. `ThunderPropagator.ClusterMessageBuses` sits at
  about 22% by design (19 transports mirror each other), hence its threshold of 25; `ThunderPropagator.Feeviders` is about 5.5%.
  `ThunderPropagator.Clients`, `ThunderPropagator.SharedBuild` and `.github` have no application code and get no jscpd job.
- **knip** is wired into `reusable-code-quality.yml` and skips itself when there is no `package.json`. When a repo gains a front-end, add a
  `knip.json` there; the existing `code-quality` job (or one added to that repo's caller) then picks it up.

## Local hooks

```
lefthook install          # once per clone, after installing lefthook and gitleaks
```

`pre-commit` scans staged changes with gitleaks. `pre-push` runs osv-scanner and (code repos) jscpd. A tool that is not installed is skipped with a
notice, so a fresh clone is never blocked; CI is the enforcing gate. Bypass in an emergency with `LEFTHOOK=0 git commit ...`.

## Operating it

- **Bump gitleaks**: change both `gitleaks-version` and `gitleaks-sha256` (the `linux_x64` tarball hash from the release page) in `reusable-secret-scan.yml`.
- **Bump OSV-Scanner / jscpd / knip**: change the version default in the corresponding reusable workflow (jscpd is also pinned in each `lefthook.yml`).
- **Accept a verified false positive** (gitleaks): add an inline `gitleaks:allow` comment on the line, or its fingerprint to `.gitleaksignore`.
  If the secret was real, rotate it instead.
- **Accept a known vulnerability** (OSV): add an `[[IgnoredVulns]]` entry with a reason and `ignoreUntil` date to an `osv-scanner.toml` next to the manifest.
- **Relax a gate for one repo**: pass `fail-on-findings: false`, `fail-on-history-findings: false` or `fail-on-vulnerabilities: false` in that repo's caller.
