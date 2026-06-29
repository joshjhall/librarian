---
description: Periodic codebase sweep that identifies tech debt, security issues, test gaps, architecture problems, and documentation staleness. Creates actionable GitHub/GitLab issues grouped by category. Invoke with /codebase-audit.
---

# Codebase Audit

**Companion files**: See `finding-schema.md` for the JSON contract all scanners
follow. See `issue-templates.md` for issue grouping rules and platform commands.
Load both when running an audit.

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
`aggregate`, then `issue-writer`). Steps 1, 2, and 2.5 below describe what the
`checker` does in its `map` and `scan` modes — they are the reference the
harness and agents follow, not a separate hand-run pass.

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

- **Map** — one `checker` call (`mode: map`) does Steps 1–2 below plus check-\*
  skill / audit-agent discovery, returning one manifest per scanner domain.
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

The remaining steps document the domain knowledge the harness and agents
consume. They are **not** a separate hand-run dispatch loop — `Task`
fan-out, scanner-completion bookkeeping, and aggregation are the harness's job.

### Step 1: Map the Codebase

1. Run `Glob("**/*")` to get the full file tree within `scope`
1. **Exclude vendored / submodule paths**: Run `git submodule status --recursive`
   via Bash. If any submodules are detected, extract their paths and remove all
   files under those directories from the file tree. Apply the same exclusion to
   any vendored / third-party directories the project lists (e.g. a
   `[tool.codebase-audit] exclude = [...]` entry, an `.audit-ignore` file, or the
   conventional `vendor/`, `third_party/`, `node_modules/` paths). This prevents
   filing findings against code that belongs to a different repository. Log each
   excluded path so the user knows it was skipped (e.g.,
   "Excluded submodule/vendored path: <path>")
1. Run `wc -l` via Bash on source files to get line counts
1. Classify files into categories by extension and path:

| Classification | Extensions / Patterns                                                                   |
| -------------- | --------------------------------------------------------------------------------------- |
| Source         | `.py`, `.js`, `.ts`, `.go`, `.rs`, `.rb`, `.java`, `.kt`, `.sh`, `.c`, `.cpp`, `.h`     |
| Test           | `test_*`, `*_test.*`, `*.test.*`, `*.spec.*`, `tests/`, `spec/`, `__tests__/`           |
| Config         | `.json`, `.yaml`, `.yml`, `.toml`, `.ini`, `.env*`, `Makefile`, `Dockerfile`            |
| Doc            | `.md`, `.rst`, `.txt`, `README*`, `CHANGELOG*`, `docs/`                                 |
| AI Config      | `.claude/`, `CLAUDE.md`, `**/CLAUDE.md`, skill/agent `.md` files, `.claude.json`, hooks |

4. Filter untracked `.env*` files out of scanner manifests. Run
   `git ls-files --error-unmatch <file>` for each `.env*` match — if the file
   is not tracked by git, exclude it from all scanner file lists (untracked
   env files are local-only and not a repository risk)
5. Detect language(s) from config files (`package.json`, `pyproject.toml`,
   `Cargo.toml`, `go.mod`, `Gemfile`, `build.gradle`, etc.)
6. Detect platform (GitHub or GitLab) from `git remote -v`
7. For `quick` depth: run `git log --oneline -50 --name-only` to limit to
   recently changed files. For `deep` depth: run `git log --format='%aN' --name-only` for contributor stats per file
8. **Discover project-level audit agents**: Glob for
   `.claude/agents/audit-*/audit-*.md` in the project root. For each match,
   read the YAML frontmatter to extract `name` and `description`. Build a
   `project_scanners` list. If a project agent shares a name with a built-in
   scanner, the project agent takes precedence (log: "Project agent overrides
   built-in: {name}"). Log each discovered agent (e.g., "Discovered project
   agent: audit-perf-regression"). If no matches, proceed with built-ins only

### Step 2: Build Work Manifest

Batch files by line count targeting ~2000 lines per batch. Route files to
scanners based on classification:

| File Type               | Routed To                           |
| ----------------------- | ----------------------------------- |
| Source files            | code-health, security, architecture |
| Test files              | test-gaps only                      |
| Config files            | security only                       |
| Doc files               | docs, ai-config                     |
| AI Config files         | ai-config only                      |
| Source + paired test    | test-gaps (paired)                  |
| High-churn files (deep) | all scanners                        |
| All files (per scope)   | project agents (self-filtering)     |

Build a manifest object for each scanner:

```json
{
  "scanner": "<name>",
  "files": ["path/to/file1.py", "path/to/file2.py"],
  "thresholds": {
    "file_length_warning": 300,
    "file_length_high": 500,
    "complexity_warning": 10,
    "complexity_high": 20,
    "duplication_warning": 10,
    "duplication_high": 20
  },
  "context": {
    "languages": ["python"],
    "framework": "django",
    "project_name": "myproject"
  }
}
```

For `test-gaps`, include `source_files`, `test_files`, and `test_patterns`
fields instead of a flat `files` list.

For `architecture`, include `file_tree` and `git_stats` (if available from
deep mode) in addition to `files`.

For project-level agents, build a manifest with `files` set to all classified
files within scope and include the agent's `description` under a
`routing_hint` field. The agent self-filters to relevant files. Use the same
`thresholds` and `context` as built-in scanners.

### Step 2.5: Deterministic Pre-Scan

Before dispatching LLM scanners, run deterministic pattern detection to catch
regex-matchable findings at zero LLM cost.

1. **Discover check-\* skills with patterns.sh**: Glob for
   `~/.claude/skills/check-*/patterns.sh` (user-level) and
   `.claude/skills/check-*/patterns.sh` (project-level)

1. **For each patterns.sh found**: Write the file manifest (one path per line)
   to a temp file, then run:

   ```bash
   bash <skill-dir>/patterns.sh <tempfile>
   ```

1. **Parse TSV output**: Each line is
   `file\tline\tcategory\tevidence\tcertainty`. Collect findings with certainty
   `HIGH` and method `deterministic`.

1. **Map findings to scanner domains**: Match check-\* skill names to audit
   agent domains (e.g., `check-security` → `audit-security`,
   `check-code-health` → `audit-code-health`). Unmatched findings go into a
   standalone `pre-scan` findings group.

1. **Include pre-scan findings in scanner manifests**: When dispatching each
   audit agent in Step 3, include the relevant pre-scan findings in the task
   prompt under a `## Pre-Scan Findings` section. Instruct the agent: "These
   patterns were already detected deterministically. Skip re-detecting them.
   Focus on context-dependent analysis that regex cannot do."

1. **Add pre-scan findings to final output**: Deterministic findings with HIGH
   certainty go directly into the aggregated findings (Step 4) without needing
   LLM confirmation.

If no check-\* skills with patterns.sh are found, skip this step silently.
If a patterns.sh exits non-zero, log the error and continue with remaining
skills.

### Step 3: Scan Each Domain (harness Scan + Verify phases)

The harness drives `checker` once per domain (`scan:<domain>`) over that
domain's manifest from Step 2, then immediately re-runs a **fresh** `checker`
(`verify`) on that domain's findings. The `checker` agent owns the per-domain
work: prescan (Step 2.5) → heuristic pass → judgment pass → within-skill dedup,
emitting the `finding-schema.md` object via StructuredOutput.

The active scanner set is whatever `map` discovered, with the domain-override
precedence (a `check-*` skill overrides the `audit-*` agent for its domain; a
project agent overrides a built-in of the same name). Built-in domains:
code-health, security, test-gaps, architecture, docs, ai-config; plus any
project agents discovered under `.claude/agents/audit-*`. The `categories`
parameter restricts the set.

The **verify** pass is adversarial: a fresh `checker` that did not produce the
findings re-scores each one's certainty and refutes false positives (no
producer self-grading). The harness drops a finding only on an explicit
refutation and keeps everything else, so a verify failure or budget exhaustion
never silently loses a real finding.

### Step 4: Aggregate and Deduplicate (harness Aggregate phase)

The harness collects every verified finding and drives one `checker`
(`mode: aggregate`) that applies, over the full set:

1. **Within-scanner dedup**: Same file + category + overlapping line ranges →
   merge into one finding (keep broader range, combine evidence)
1. **Cross-scanner correlation** (see `issue-templates.md` for rules):
   - Dead code (code-health) + orphaned file (architecture) → merge
   - Security issue + test gap on same file → bump severity of the group
   - Stale comment (docs) + deprecated API (code-health) → merge
   - CLAUDE.md drift (ai-config) + outdated README (docs) → merge
   - MCP misconfiguration (ai-config) + hardcoded secret (security) → merge
   - Any project-scanner finding + any other scanner finding on same file →
     cross-reference note only (do not merge). Predefined merge rules apply
     only between built-in scanner pairs
1. **Filter**: Remove findings below `severity-threshold`
1. **Sort**: By severity (critical first), then by effort (trivial first —
   quick wins surface to the top)
1. **Group** into issue payloads (same file + category → one issue; same
   pattern across files → one issue, max 10 findings, splitting larger groups
   with `(1/N)` suffixes). For project-scanner findings, derive the category
   label as `audit/<scanner-name-without-audit-prefix>` (e.g.,
   `audit-perf-regression` → `audit/perf-regression`) and set
   `create_label: true`.

Acknowledged findings (`acknowledged_findings` from each scan) flow through to
the harness's `report_markdown` for the final report.

### Step 5: Create Issues (or Dry-Run Report) (harness File phase)

**If `dryRun` is true**: the harness returns `report_markdown` (the Dry-Run
Output Format from `issue-templates.md`) and files nothing.

**If `dryRun` is false**: the harness fans one `issue-writer` per group in
parallel, each handling duplicate detection + issue creation independently
(Issue-Writer Sub-Agent Protocol in `issue-templates.md`). If no `gh`/`glab`
platform was detected, it falls back to the dry-run report. The returned
`issues[]` array carries each writer's `{action, url, title, reason}`.

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
