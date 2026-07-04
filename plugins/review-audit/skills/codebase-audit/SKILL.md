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

| Parameter            | Default          | Description                                                                     |
| -------------------- | ---------------- | ------------------------------------------------------------------------------- |
| `scope`              | entire repo      | Directory or glob pattern to limit the scan                                     |
| `categories`         | all discovered   | Scanner names to run (comma-separated)                                          |
| `depth`              | `standard`       | `quick`: last 50 commits; `standard`: full; `deep`: + git history               |
| `severity-threshold` | `medium`         | Minimum severity to report                                                      |
| `output`             | *asked per run*  | Objective artifact: `issues` (file in tracker) or `files` (write `./audit/…`). Asked interactively when omitted; see § Resolve the Objective |
| `report`             | `true`           | Also persist the report summary to `./audit/{timestamp}-audit-report.md` (passed to the harness as `writeReport`) |

> **`dry-run` is gone.** The audit no longer has a "preview, produce nothing"
> mode — every run yields durable artifacts, and the only question is *what
> kind*. A run that used `dry-run: true` to avoid touching the tracker maps to
> `output: files` (structured findings + a report written under `./audit/`,
> tracker untouched). See § Resolve the Objective and the CHANGELOG note.

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

### Resolve the Objective (before invoking the harness)

The harness runs in the sandboxed Workflow JS engine — it **cannot** call
`AskUserQuestion` (to ask the objective per run) or `Date` (to stamp the run).
So this skill (the main agent) resolves two things **first** and passes them in
as `args`:

1. **Objective (`output`)** — where the actionable findings go:
   - If the user gave `output` (or the legacy intent "don't file issues" → map
     to `files`), honor it without asking.
   - Otherwise **ask** with `AskUserQuestion`: **File issues** (create tracker
     issues) vs **Generate files** (write `./audit/{timestamp}/`). Offer the
     `issues` option **only** when a tracker platform exists — detect it with
     `git remote -v` (`github.com`/`ghe.` → GitHub; `gitlab.com`/`gitlab.` →
     GitLab). With no platform, don't offer `issues`; use `files`.
   - In a **non-interactive / headless** context (no TTY to ask), default to
     `files` — never mutate a tracker unprompted.
2. **Timestamp** — compute a filesystem-safe run stamp via Bash, e.g.
   `date -u +%Y-%m-%dT%H%M`, and pass it as `timestamp`. It becomes the
   `./audit/{timestamp}/` subdir and the `{timestamp}-audit-report.md` name.

The **report summary** is written by default (`report: true`) regardless of
objective; pass `report: false` only if the user asked to suppress the file
(the roll-up is still returned to chat either way).

> **Design note — ask, don't auto-file.** Issue #214 sketched a precedence of
> "explicit arg → future config → detected platform → files", which implied a
> GitHub/GitLab repo would *default* to filing issues (the old `dryRun:false`
> behavior). We deliberately resolve an omitted `output` by **asking** (or, when
> headless, defaulting to `files`) instead of silently filing: creating tracker
> issues is an outward, hard-to-undo side effect, and the whole point of this
> change is that the objective is a per-run choice. A detected platform gates
> whether `issues` is *offered*, not whether it is chosen unprompted. Pass
> `output: issues` explicitly (or answer the prompt) for the classic file-issues
> flow.

### Invoke the Harness

**Invoke the `Workflow` tool** with the script bundled alongside this skill at
`~/.claude/skills/codebase-audit/workflow.js`, passing the resolved parameters:

```text
args: {
  scope:             "<dir or glob, or omit for whole repo>",
  categories:        [<scanner/domain names>, …],   // omit for all discovered
  depth:             "quick" | "standard" | "deep",  // default "standard"
  severityThreshold: "critical" | "high" | "medium" | "low",  // default "medium"
  output:            "issues" | "files",             // resolved above (asked if omitted)
  writeReport:       <true|false>,                   // default true
  timestamp:         "<YYYY-MM-DDTHHMM>",             // computed above (engine has no Date)
  auditDir:          "./audit"                        // default; root for file artifacts
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
  payloads keyed by finding ref plus the report summary.
- **File** — routes by objective: `output: issues` fans one `issue-writer` per
  group in parallel (dedupe-before-create); `output: files` dispatches one
  `artifact-writer` to write `./audit/{timestamp}/findings.json` + one markdown
  file per group. The report summary (`writeReport`) is written under `./audit/`
  in either case. With no `gh`/`glab` platform, an `issues` objective is
  coerced to `files` (the tracker is never mutated unprompted).

The harness returns `{ scanner, output, report_path, platform,
scanned_domains, totals, report_markdown, issues[], artifacts, summary,
budget_exhausted }`. Surface `report_markdown` to the user; for `output:
issues` list the created issues from `issues[]`, and for `output: files` report
`artifacts.files_written` and `report_path`.

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
  zero-LLM-cost regex findings, fed into each scanner's prompt. Project-level
  scripts (`.claude/skills/...` in the repo under audit) and project-level
  `audit-*` agents are an execution surface for a hostile repo — both run only
  when `CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS=1` is set (see
  `orchestration-protocol.md`).
- **Step 3 — Scan Each Domain**: harness Scan + adversarial Verify phases over
  each manifest.
- **Step 4 — Aggregate & Deduplicate**: within-scanner dedup, cross-scanner
  correlation, filter, sort, group into issue payloads.
- **Step 5 — Route Artifacts by Objective**: for `output: issues` fan one
  `issue-writer` per group; for `output: files` dispatch one `artifact-writer`
  to write `./audit/{timestamp}/`. The report summary is written under `./audit/`
  either way (unless `writeReport` is false).

See `orchestration-protocol.md` for the full step-by-step reference.

## Auto-Fix (Opt-In)

> **Not yet implemented in the Workflow harness (legacy model-driven path
> only).** This section describes the auto-fix loop as the original
> model-driven orchestration ran it. The current `workflow.js` harness — the
> default execution path — does **not** implement it: there is no `autoFix`
> arg and no `refactorer` dispatch (the #18 mandate was orchestration-only, and
> the harness never edits code). Treat the steps below as the design contract
> for a future harness capability, not an available flag today.

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
- If the objective is `issues` but no `gh`/`glab` platform is detected: the
  harness coerces the run to `files` (writes `./audit/{timestamp}/` instead of
  filing) and logs the substitution — the tracker is never mutated unprompted.
  Inform the user their findings were written to files.
- If the `artifact-writer` fails to write (permissions, disk): the run is marked
  a partial failure; surface `artifacts.reason` to the user.
- If no source files match the scope: report early with a clear message
