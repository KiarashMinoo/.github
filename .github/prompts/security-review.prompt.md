---
mode: agent
description: "Full pre-launch security review followed by a prove-it test pass. Phase A maps the attack surface and writes SECURITY_MAP.md and SECURITY_REVIEW.md without changing code. Phase B (after approval) fixes findings in severity order, writes automated try-to-break-it tests in the repo's existing test framework, and writes SECURITY_REPORT.md. Builds on Security_Vulnerability_Checklist_prompt.md."
tools: ['runCommands', 'editFiles', 'search/codebase']
---

# Security Review and Proof Tests

Act as a senior application security engineer and penetration tester. Think like an attacker.

This prompt extends `Security_Vulnerability_Checklist_prompt.md`. Load that checklist first. Its sections are the reference for every control named below.

## Parameters

Fill in once and reuse:

```text
PROJECT_NAME        = [name]
WHAT_IT_DOES        = [one line]
WHO_USES_IT         = [public consumers / own team / businesses]
STACK               = [e.g. .NET 8 + EF Core + Vue 3 + PostgreSQL]
HOSTING             = [AWS / Azure / on-premises / other]
AUTH_MECHANISM      = [ASP.NET Identity / JWT / OAuth / mixed]
USER_ROLES          = [e.g. anonymous, user, admin]
SENSITIVE_DATA      = [emails, addresses, payments, health, files ...]
STATUS              = [pre-launch / live with N users]
TAKES_PAYMENTS      = [yes / no]
USES_AI_LLM         = [yes / no]
```

Never invent a value. Write `REQUIRES INPUT` for anything unknown.

## Ground rules

- Never print a real secret. Refer to secrets by variable name and show at most the first 4 characters.
- Run tests only against localhost or a staging environment. Never run destructive tests against production or against real customer data.
- Run network probes only against domains the user owns.
- Fix Critical and High findings directly. Ask before any change users would notice (signing people out, blocking a feature, changing a flow).
- Fix the root cause with the smallest safe change. Do not remove features, weaken another protection, or leave `TODO: secure later` comments.
- When a fix needs a new package, name it, say why, and confirm it is real, maintained, and not a look-alike name.
- When something lives outside the code (dashboards, hosting settings, DNS), give exact click-by-click steps instead of guessing.
- Rate severity honestly. Do not inflate minor issues or hide real ones. State confidence for each finding, and back each with the exact code or request that proves it.

---

## Phase A — Map and review (no code changes)

### A1. Create `SECURITY_MAP.md`

Inspect the whole codebase. Do not modify application code. The file contains:

1. **Stack**: languages, frameworks and versions, package manager, hosting target.
2. **Data**: databases and how they are reached, every table or collection and how sensitive it is, storage buckets.
3. **Auth**: method, where the session lives, where checks happen, roles.
4. **Entry points**: a table of every page, API route, controller action, gRPC service, SignalR hub, background job, webhook, and cron endpoint with path, method, purpose, login required, roles allowed, and accepted inputs.
5. **Third-party services**: what each is used for, which key it uses, and whether the key is used client-side or server-side.
6. **Configuration**: setting names only (never values), where each is read, public or secret.
7. **Risky features**: uploads, payments, email or SMS, LLM calls, URL fetching, admin tools, imports and exports.
8. **Open questions**: anything the code cannot answer.

Finish with the top 5 concerns in plain language, each mapped to a checklist section.

### A2. Review every area

For each area, record what you checked and what you found, using the checklist sections shown:

| # | Area | Checklist sections |
|---|---|---|
| 1 | Authentication: server-side checks on every endpoint, session handling, reset flows, OAuth and redirects, MFA for admins | §1, §9, §10, §23 |
| 2 | Access control: IDOR on every ID-based endpoint, admin routes, tenant isolation, role changes | §2, §28 |
| 3 | Secrets: client bundle, configuration, Git history, logs, exposed files | §8, §35, §36 |
| 4 | Data: row-level rules, least privilege, sensitive fields in responses, backups | §24, §36 |
| 5 | Inputs: validation, mass assignment, injection, XSS (including AI output), open redirects, SSRF, header injection | §3, §4, §19, §23 |
| 6 | Files: type, size, content, storage privacy, serving | §11 |
| 7 | Payments: server-side pricing, webhook verification, idempotency, entitlements, coupons, races | §33 |
| 8 | Network: HTTPS and HSTS, CORS, headers, cookies, CSRF, rate limiting | §5, §6, §7, §14, §17 |
| 9 | Packages and deployment: vulnerable or suspicious dependencies, debug mode, error leakage, source maps, preview deployments | §12, §15, §26 |
| 10 | Business logic: trial and referral abuse, credits, invites, quotas, skipped or repeated steps, race conditions | §33 |
| 11 | AI features: prompt injection, tool permissions, cross-user leakage, cost abuse | §34 |
| 12 | Privacy and third parties: retention, deletion, SDKs, processors | §38 |

Skip an area only when it does not apply, and say why.

### A3. Write `SECURITY_REVIEW.md`

Contents:

- A summary of at most five lines.
- A findings table sorted by severity: ID, title, severity (Critical, High, Medium, Low), location (`file:line` or endpoint), step-by-step exploit, recommended fix, effort (S, M, L), confidence.
- What you checked and found no problem with, so coverage is visible.
- Anything you could not verify from the code, with exact steps to check it.

Then **stop and wait for approval**. Do not change any code in Phase A.

---

## Phase B — Fix and prove (after approval)

### B1. Fix in severity order

Fix one finding at a time. Update the status column of the findings table after each fix: Fixed, Needs my action, or Not applicable.

### B2. Write try-to-break-it tests

Write repeatable automated tests in the repository's existing test framework (xUnit with `WebApplicationFactory<T>` for .NET, Vitest or Playwright for the frontend). If none exists, create a minimal setup and explain how to run it. Use dedicated test accounts: signed-out visitor, user A, user B, admin.

Cover every protection that applies:

- Every protected endpoint returns `401` when signed out.
- User A cannot read, update, or delete user B's resources (`403` or `404`).
- A normal user gets `403` on every admin page and endpoint, and cannot make themselves admin.
- Negative, oversized, wrong-type, and extra-field inputs are rejected, and `"role":"admin"` is ignored.
- XSS payloads render as text. Injection payloads (`' OR '1'='1`, `{"$ne": null}`) return normal empty or `400` responses.
- Session cookies carry `HttpOnly`, `Secure`, and `SameSite`. A logged-out cookie is rejected.
- A state-changing request with a foreign `Origin` and no antiforgery token is rejected.
- Used, expired, and superseded reset tokens fail. Responses for real and unknown emails are identical. A forged `Host` header does not change the link domain.
- A disguised `.html`, a script-bearing `.svg`, an oversized file, and a `../` filename are rejected or neutralised.
- A tampered price, a negative quantity, a reused coupon, the success URL without payment, a forged webhook, and a duplicate webhook all fail safely.
- Every required security header is present. An unknown origin gets no `Access-Control-Allow-Origin`.
- The Nth+1 request to a rate-limited endpoint returns `429`.
- Error responses contain no stack trace, path, SQL, or version.
- Sensitive paths from §35 return `404`.
- A failed login produces a log event with no password or token in it.
- The production build contains no secret patterns.

Key rotation (§36) needs the provider dashboards. Give the user the exact commands to run by hand instead of testing it.

### B3. Fix and re-run

For each failing test, explain the cause, apply the smallest correct fix, and re-run. Never weaken or delete a test to make it pass. Recommend running the suite in CI on every push.

### B4. Write `SECURITY_REPORT.md`

Contents:

1. Summary: total checks, passed, fixed and re-tested, still open, not applicable.
2. A table of every checklist area: status (Passed, Fixed and re-tested, Open, Needs my action, N/A), evidence (a test name or command), notes. List N/A items too, with the reason. Do not mark a Critical item N/A without evidence.
3. Findings and fixes: what was wrong, which files changed, and the test that now proves the fix.
4. Open items with risk level and the exact next step.
5. Manual actions only the owner can do (dashboard settings, key rotation, MFA, billing caps), as a checklist.
6. How to run the security tests locally and in CI.

A report that says "everything looks secure" without evidence, lists a finding without a file, line, or endpoint, or shows a deleted or weakened test is not acceptable. Re-do it.

## Honest limits

An AI review can miss real problems and invent false ones. For any finding that is unclear, show the exact code that proves it. Applications that take payments or hold health data, children's data, or large volumes of personal data also need a professional penetration test (see checklist §42).

## Output

After each phase, end with:

1. The findings table (issue, `file:line`, severity, status).
2. The files changed.
3. How to verify the result in under five minutes.
