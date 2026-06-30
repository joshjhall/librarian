---
description: Periodic codebase sweep that identifies tech debt, security issues, test gaps, architecture problems, and documentation staleness. Creates actionable GitHub/GitLab issues grouped by category. Invoke with /codebase-audit.
---

# Codebase Audit

**Companion files**: See `orchestration-protocol.md` for the full Step 1–5
domain-knowledge reference (file routing, prescan, scan/verify, aggregate,
file). See `finding-schema.md` for the JSON contract all scanners follow. See
`issue-templates.md` for issue grouping rules and platform commands. Load them
when running an audit.

## Parameters

Accept these from the user's invocation (all optional):

| Parameter            | Default        | Description                                                       |
| -------------------- | -------------- | ----------------------------------------------------------------- |
| `scope`              | entire repo    | Directory or glob pattern to limit the scan                       |
| `categories`         | all discovered | Scanner names to run (comma-separated)                            |
| `depth`              | `standard`     | `quick`: last 50 commits; `standard`: full; `deep`: + git history |
| `severity-threshold` | `medium`       | Minimum severity to report                                        |
| `dry-run`            | `false`        | Output findings report without creating issues                    |

## Orchestration Protocol

The fan-out is owned by the bundled **`workflow.js`** harness (invoked via the
Workflow tool), not by hand-dispatched `Task` calls. The harness makes the
scanner fan-out deterministic, puts every scan + verify under **one shared
token budget** with a resumable per-domain checkpoint, runs a **fresh
adversarial verify** pass before any issue is filed, and fans the issue-writer
creation in parallel. This skill supplies the harness its domain knowledge —
the file-routing manifest (Step 2), the deterministic prescan contract (Step
2.5), the finding schema (`finding-schema.md`), and the grouping / template
rules (`issue-templates.md`) — all of which stay authoritative and unchanged.

Because the harness runs in the sandboxed Workflow JS engine (no filesystem,
shell, or git), every step that touches the tree, runs `patterns.sh`, or calls
`gh`/`glab` happens inside the `checker` and `issue-writer` agents, which the
harness drives in discriminated **modes** (`map`, `scan:<domain>`, `verify`,
`aggregate`, then `issue-writer`). Steps 1, 2, and 2.5 in
`orchestration-protocol.md` describe what the `checker` does in its `map` and
`scan` modes — they are the reference the harness and agents follow, not a
separate hand-run pass.

### Invoke the Harness

**Invoke the `Workflow` tool** with the script bundled alongside this skill at
`~/.claude/skills/codebase-audit/workflow.js`, passing the user's parameters:

```text
args: {
  scope:             "<dir or glob, or omit for whole repo>",
  categories:        [<scanner/domain names>, …],   // omit for all discovered
  depth:             "quick" | "standard" | "deep",  // default "standard"
  severityThreshold: "critical" | "high" | "medium" | "low",  // default "medium"
  dryRun:            <true|false>                    // default false
}
```

The harness phases are **Map → Scan → Verify → Aggregate → File**:

- **Map** — one `checker` call (`mode: map`) does Steps 1–2 (in
  `orchestration-protocol.md`) plus check-\* skill / audit-agent discovery,
  returning one manifest per scanner domain.
- **Scan → Verify** — a pipeline **without a barrier**: each domain's
  `scan:<domain>` (Steps 1–2.5 deterministic prescan + heuristic + judgment,
  per the `checker` agent) streams straight into a **fresh** `checker`
  `verify` that re-scores certainty and refutes false positives — domains
  verify as soon as they finish scanning, not after all scans complete.
- **Aggregate** — a barrier `checker` step (`mode: aggregate`) applies Step 4
  dedup + cross-scanner correlation and Step 5 grouping, returning issue
  payloads keyed by finding ref plus the dry-run report.
- **File** — if `dryRun`, the harness returns the report and stops; otherwise
  it fans one `issue-writer` per group in parallel (dedupe-before-create), and
  falls back to a dry-run report when no `gh`/`glab` platform is detected.

The harness returns `{ scanner, dry_run, platform, scanned_domains, totals,
report_markdown, issues[], summary, budget_exhausted }`. Surface
`report_markdown` to the user, and list the created issues from `issues[]`.

The remaining domain knowledge — the file-routing manifest, the deterministic
prescan contract, and the dedup / grouping rules the harness and agents consume
— lives in **`orchestration-protocol.md`** (Steps 1–5). It is **not** a separate
hand-run dispatch loop: `Task` fan-out, scanner-completion bookkeeping, and
aggregation are the harness's job.

- **Step 1 — Map the Codebase**: glob the tree, exclude submodule/vendored
  paths, classify files, detect language + platform, discover project audit
  agents.
- **Step 2 — Build Work Manifest**: batch by line count, route file types to
  scanners, emit per-scanner manifest objects.
- **Step 2.5 — Deterministic Pre-Scan**: run `check-*/patterns.sh` for
  zero-LLM-cost regex findings, fed into each scanner's prompt.
- **Step 3 — Scan Each Domain**: harness Scan + adversarial Verify phases over
  each manifest.
- **Step 4 — Aggregate & Deduplicate**: within-scanner dedup, cross-scanner
  correlation, filter, sort, group into issue payloads.
- **Step 5 — Create Issues (or Dry-Run Report)**: fan one `issue-writer` per
  group, or return the dry-run report.

See `orchestration-protocol.md` for the full step-by-step reference.

## Auto-Fix (Opt-In)

When invoked with `--auto-fix` or when the user confirms, the pipeline can
automatically fix CRITICAL and HIGH certainty findings with trivial or small
effort.

**Eligibility**: `certainty.level` in (`CRITICAL`, `HIGH`) AND `effort` in
(`trivial`, `small`).

### Auto-Fix Workflow

1. **Filter eligible findings** from the aggregated results

1. **Group by file** to minimize edit conflicts

1. **For each group**, dispatch the `refactorer` agent with:

   - The finding's `file`, `line_start`/`line_end`, `description`, `suggestion`
   - Instruction: apply the suggestion, preserve surrounding code

1. **Re-scan** modified files with the original scanner to verify the fix
   resolved the finding without introducing new ones

1. **Report** results:

   ```text
   ## Auto-Fix Results

   | Finding ID         | Category         | Certainty | Status      |
   |--------------------|------------------|-----------|-------------|
   | security-001       | hardcoded-secret | CRITICAL  | ✓ fixed     |
   | code-health-003    | unused-import    | HIGH      | ✓ fixed     |
   | code-health-007    | dead-code        | MEDIUM    | — skipped   |
   | architecture-002   | bus-factor       | MEDIUM    | — flagged   |

   Auto-fixed: 2 | Flagged for review: 1 | Report only: 1
   ```

### Safety

- CRITICAL fixes (secrets, injection) add a warning comment explaining
  what was changed and why
- Never auto-fix MEDIUM or LOW certainty — these require human judgment
- If re-scan shows new findings after fix, revert the fix and flag for
  human review
- Auto-fix never modifies test files

## When to Use

- Quarterly codebase health reviews
- Before major refactoring efforts (understand what needs attention)
- After onboarding to an unfamiliar codebase
- When preparing for a security audit
- When tech debt feels high but isn't quantified

## When NOT to Use

- For real-time CI/CD checks (too slow, use linters instead)
- On generated or vendored code
- On codebases under active rewrite (findings will be obsolete)

## Depth Modes

| Mode       | Files Scanned                        | Git History    | Best For            |
| ---------- | ------------------------------------ | -------------- | ------------------- |
| `quick`    | Changed in last 50 commits           | Recent commits | Regular check-ins   |
| `standard` | All source files in scope            | None           | Quarterly reviews   |
| `deep`     | All source files + contributor stats | Full history   | Comprehensive audit |

## Error Handling

- If a scanner returns invalid JSON: log the error, skip that scanner's
  findings, note in the final report
- If a scanner returns zero findings: include it in the summary with zero
  counts (this is normal, not an error)
- If `gh`/`glab` is not available and `dry-run` is false: fall back to
  dry-run mode and inform the user
- If no source files match the scope: report early with a clear message
