---
description: Detect drift between issue plans and actual implementation. Compares planned files, acceptance criteria, and scope against git changes. Use before shipping to catch scope drift early.
---

# drift-detect

Compare documented plans (issue descriptions, implementation plans) against
actual implementation to identify divergence before shipping.

**Companion files**: See `contract.md` for the output report format. See
`thresholds.yml` for configurable severity levels. Load both before starting.

## When to Use

- Before running `/ship-issue` to verify implementation matches the plan
- After completing implementation to check for scope drift
- As part of pre-ship validation (auto-invoked by `/ship-issue`)

## Workflow

### Step 1 — Resolve Issue Context

1. **Check for next-issue state**:

   ```bash
   # Exclude the singleton next-issue-queue.json — it is a dependency-queue
   # record, not a per-issue state file.
   ls .claude/memory/tmp/next-issue-*.json 2>/dev/null \
     | command grep -v '/next-issue-queue\.json$'
   ls .claude/memory/tmp/next-issue-*.md 2>/dev/null
   ```

   - If a state file exists: extract `issue` number and `branch`
   - If multiple state files: ask which issue to check
   - If no state file: ask the user for the issue number

1. **Detect platform** from `git remote -v`:

   | Pattern              | Platform | CLI    |
   | -------------------- | -------- | ------ |
   | `github.com`, `ghe.` | GitHub   | `gh`   |
   | `gitlab.com`         | GitLab   | `glab` |

### Step 2 — Gather Plan and Implementation Data

1. **Fetch issue body**:

   - GitHub: `gh issue view {N} --json body --jq .body`
   - GitLab: `glab issue view {N} --output json | jq -r .description`

1. **Extract planned file paths** from the issue body:

   - Look for an "Affected Files" or "Files to Change" section (H2 or H3)
   - Extract file paths from list items (lines starting with `-` or `*`)
   - Strip backticks, trailing descriptions, and markdown formatting
   - If no such section exists: record `planned_files: []` and note that
     file-level drift detection is unavailable

1. **Extract acceptance criteria** from the issue body:

   - Look for an "Acceptance Criteria" section (H2 or H3)
   - Parse checkbox items: `- [ ]` (unchecked) and `- [x]` (checked)
   - If no such section exists: record `acceptance_criteria: null` and skip
     criteria checking

1. **Get actual file changes — scope to the GOLEM'S OWN commits, not base
   drift.** The right scope is "what did *this golem* change," which is the
   branch's own commits — NOT everything that differs from `origin/main`. In a
   worktree golem, a plain base diff also surfaces **base noise**: gitignored /
   untracked host-tree artifacts (e.g. `.claude/memory/*.md`, machine-local
   config) and files last touched by *other* merged commits, none of which the
   golem authored. Reviewing that noise nearly caused false "out-of-scope
   changes" judgments (#26).

   Use the **three-dot merge-base** range, which diffs against the point the
   branch forked from (so files another PR changed on `main` after the fork do
   NOT appear), and for a single-commit branch prefer `git show HEAD`:

   ```bash
   git fetch origin main 2>/dev/null
   # Branch's own contribution vs its fork point (three-dot = merge-base..HEAD):
   git diff --name-only origin/main...HEAD
   # Single-commit golem branch — the golem's exact contribution:
   git show --name-only --format= HEAD
   ```

   **Two-dot `git diff origin/main..HEAD` is wrong here** — it compares tips, so
   it folds in every file that diverged on `main` since the fork, inflating the
   apparent scope. Always use the three-dot form (or `git show HEAD`).

   If not on a feature branch (e.g., on main with uncommitted work):

   ```bash
   git diff --name-only --cached HEAD
   git diff --name-only HEAD
   ```

### Step 3 — Detect Drift

Compare planned vs actual across four categories:

#### 3a. Planned files not touched (`planned-not-touched`)

Files listed in the issue's "Affected Files" section that do not appear in the
git diff. **Severity: HIGH** — planned work was skipped.

Exceptions (reduce to MEDIUM):

- File paths that are directories (plan may list a directory, impl touches
  files within it)
- Files listed as "optional" or "if needed" in the plan

#### 3b. Unplanned files modified (`unplanned-modification`)

Files in the git diff that are not listed in the issue's "Affected Files"
section. **Severity: MEDIUM** — could be legitimate supporting changes.

Exceptions (reduce to LOW):

- Test files for planned source files (e.g., `tests/test_foo.py` when
  `src/foo.py` is planned)
- Configuration files commonly touched as side effects (`.gitignore`,
  `package-lock.json`, `go.sum`, lock files)

Exceptions (**exclude entirely** — base noise, not the golem's work, #26):

- **Base-noise paths** that leak into a worktree golem's diff without being
  part of its commit — gitignored / untracked host-tree artifacts and
  machine-local config, e.g. `.claude/memory/*.md`, `.devcontainer/docker-compose*.yml`,
  `.env*`. These trace to the bare host tree or to other merged commits, not to
  the golem. Scoping the actual-files step to the branch's own commits (Step 2,
  three-dot range / `git show HEAD`) already drops most of them; if any still
  appear, drop them here rather than reporting them as `unplanned-modification`.
  Confirm a suspected base-noise file is not the golem's by checking it is
  absent from `git show --name-only --format= HEAD` (the golem's own commit).

#### 3c. Unchecked acceptance criteria (`unchecked-criteria`)

Acceptance criteria checkboxes that remain unchecked (`- [ ]`). Uses LLM
judgment to determine whether the implementation addresses the criterion even
if the checkbox wasn't manually checked. **Severity: HIGH** for criteria
clearly not addressed; **MEDIUM** for ambiguous cases.

#### 3d. Scope additions (`scope-addition`)

Unplanned files that introduce new functionality beyond the issue's scope
(not just supporting changes). Determined by LLM judgment examining the diff
content. **Severity: LOW** — informational.

### Step 4 — Report

Generate a drift report following the format in `contract.md`.

**If called standalone** (`/drift-detect`):

- Display the report as a formatted table
- Summarize: "N findings (X high, Y medium, Z low)"
- If zero findings: "No drift detected — implementation matches the plan"

**If called from ship-issue** (pre-ship validation):

- Return the structured JSON report
- Let ship-issue handle the user prompt based on severity

### Step 5 — Run Deterministic Pre-Scan (Optional)

If `patterns.sh` is available and a file list can be constructed from the diff,
run it for deterministic checks:

```bash
git diff --name-only origin/main...HEAD > /tmp/drift-detect-files.txt
./patterns.sh /tmp/drift-detect-files.txt
```

Merge any TSV findings into the report alongside the LLM-judged findings.

## Integration with ship-issue

This skill is invoked automatically by `/ship-issue` in Step 3.5
(Pre-Ship Validation) as the 4th check. The integration is optional — if the
issue body has no "Affected Files" or "Acceptance Criteria" sections, the check
is skipped silently.

## What This Does NOT Do

- Semantic code analysis (planned for future iteration)
- Cross-repo drift detection
- Performance or quality assessment of the implementation
- Automated fixing of drift (reports only)
