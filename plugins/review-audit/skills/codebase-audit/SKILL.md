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

Follow these steps in order. Do not skip steps.

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

### Step 3: Dispatch Scanners in Parallel

Send **a single message** with one `Task` tool call per active scanner. If
total scanners exceed 6, dispatch in batches of 6. Each task prompt must
include:

1. The scanner's manifest (from Step 2)
1. The full finding schema (from `finding-schema.md`)
1. The severity threshold

Use the active scanner list assembled in Step 1:

**Built-in scanners** (unless overridden by a project agent of the same name):
audit-code-health, audit-security, audit-test-gaps, audit-architecture,
audit-docs, audit-ai-config

**Project scanners** (discovered from `.claude/agents/audit-*`):
Include all project agents from the `project_scanners` list.

Scanners use the model declared in their agent frontmatter
(`sonnet` or `opus` depending on task complexity) and `tools: Read, Grep, Glob, Bash, Task`.
Scanners with manifests exceeding 2000 source lines automatically fan out to
batch sub-agents (model: haiku) — see each scanner's agent definition for
details.

Skip scanners not in the `categories` parameter.

### Step 3.5: Verify Scanner Completion

Before proceeding to aggregation, validate all scanner results:

1. **Check completion** — verify all dispatched scanner Tasks completed
   (no timeouts or crashes). If a scanner timed out or errored:

   - Log which scanner failed and why
   - Proceed with partial results from successful scanners
   - Note the incomplete scan in the final summary

1. **Validate output** — for each scanner result:

   - Verify the response contains parseable JSON in a \`\`\`json fence
   - Check the `scanner` field matches the expected scanner name
   - Verify `findings` is an array (even if empty)
   - Verify each finding has the required fields per `finding-schema.md`
     (including the `certainty` object)
   - If validation fails: discard the malformed result and log the error

1. **Report** scanner status before proceeding:

   ```text
   Scanner completion: 6/6 succeeded
   ```

   Or if partial:

   ```text
   Scanner completion: 5/6 succeeded (audit-architecture: timeout)
   Proceeding with partial results.
   ```

### Step 4: Aggregate and Deduplicate

After all scanners return:

1. **Parse JSON** from each scanner's response (extract from \`\`\`json fences)
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
1. **Aggregate acknowledged findings**: Collect `acknowledged_findings` arrays
   from all scanners into a unified list for the final report
1. **Filter**: Remove findings below `severity-threshold`
1. **Sort**: By severity (critical first), then by effort (trivial first —
   quick wins surface to the top)
1. **Assign sequential IDs** across the merged set for the final report

### Step 5: Create Issues (or Dry-Run Report)

**If `dry-run` is true**: Output the summary table, findings list, and
acknowledged findings table as described in `issue-templates.md` (Dry-Run
Output Format section). Stop here.

**If `dry-run` is false**:

1. **Group findings** into issues following the rules in `issue-templates.md`:
   - Same file + same category → one issue
   - Same pattern across files → one issue (max 10 findings per issue)
   - Cross-scanner correlations → single merged issue
1. **Build issue payloads**: For each group, assemble the JSON payload described
   in `issue-templates.md` (Issue-Writer Sub-Agent Protocol section). For
   project-scanner findings, derive the category label as
   `audit/<scanner-name-without-audit-prefix>` (e.g., `audit-perf-regression`
   → `audit/perf-regression`) and set `create_label: true` in the payload
1. **Dispatch issue-writer sub-agents**: Send groups to `issue-writer` agents
   via the Task tool (model: haiku). Each issue-writer receives one group and
   handles duplicate detection + issue creation independently:
   - Dispatch up to 10 issue-writers in parallel per message
   - If more than 10 groups exist, send additional batches after the first
     batch completes
1. **Collect results**: Each issue-writer returns JSON with `action`
   (`created`/`skipped`/`error`), `url`, and `reason`
1. **Output summary**: List created issues with URLs, note any skipped
   duplicates or errors

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
