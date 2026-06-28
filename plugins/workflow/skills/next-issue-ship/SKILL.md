---
description: Ship the current next-issue work — commit, deliver (PR or push), label the issue, and optionally loop back. Use after implementation and testing are complete for an issue started with /next-issue.
---

# Next Issue — Ship

Delivers the completed work for an issue previously selected and planned by
`/next-issue`. Handles committing, pushing, PR creation, issue labeling, and
state cleanup.

**Prerequisite**: Implementation and testing must be complete before invoking
this skill. The state file written by `/next-issue` must exist.

## Pipeline

This skill is the delivery half of the `/next-issue` → `/next-issue-ship`
pipeline (the two are kept as separate skills on purpose — see `## Pipeline` in
the `next-issue` skill for the rationale). The hand-off is the state file
`.claude/memory/tmp/next-issue-{N}.json`: `/next-issue` writes `phase` +
`checkpoint`; this skill reads them in Step 1. It can be invoked three ways:

- **Manually** after a `/clear` — the normal flow for `effort/medium`/`large`
  work, where planning context was reset before implementation.
- **Auto-invoked by `/next-issue --ship`** (alias `--now`) — the fast-path for
  `effort/trivial`/`small` issues, which chains here in the same context with
  no `/clear`. Being reached this way is **NOT autonomous**: the `--ship`
  fast-path keeps the plan-approval gate and leaves `autonomous` false, so this
  run still prompts for shipping mode (Step 3) and every other interactive gate.
- **Auto-chained by `/next-issue --auto`** — the autonomous flow, which sets
  `"autonomous": true` (see below). Autonomous `/next-issue` invokes this skill
  **in the same turn** (via the `Skill` tool) once implementation and testing
  complete — it does not stop and suggest a manual run. This skill therefore
  must work whether reached in-turn (state file already current in context) or
  fresh after a turn-exit (re-read from the state file in Step 1); both paths
  detect autonomy via the toggle below.

## Autonomous Mode

The run is **autonomous** when ANY of the following holds: the literal token
`--auto` appears in the invocation arguments, the environment variable
`NEXT_ISSUE_AUTONOMOUS=1` is set, OR the state file read in Step 1 has
`"autonomous": true`. Autonomy is strictly opt-in.

When autonomous:

- Do NOT call `AskUserQuestion` anywhere in this skill. Every gate takes its
  documented default with no interactive tool call.
- Always Branch + PR (Option 1), regardless of branch name.
- Always wait for CI and auto-fix failures (no prompt).
- Stop at green CI with a structured completion summary for human merge (see
  Option 1 "Autonomous completion summary"). Never auto-merge unless BOTH
  `AUTOMERGE=1` and `AUTOMERGE_AUTONOMOUS=1` are set (the second is a required
  consent because auto-merge skips the review loop — see Environment Variables).

When NOT autonomous, behavior is unchanged — every interactive prompt below
runs verbatim as the default.

## Golem Execution Model (for orchestrators)

A golem running this skill is an OS **process**, never itself a Workflow
subagent. This skill drives the adversarial review harness
(`next-issue-ship/workflow.js`, Step 3.5 item 6 and the Step 4 multi-cycle
loop), which in turn fans out the `code-reviewer` agent. The Workflow tool
permits only **one level of nesting** (`workflow()` inside a workflow throws),
and that nesting level is reserved for the review harness's own fan-out — so a
golem MUST be its own process and own the single Workflow invocation tree.

Orchestrators (e.g. the master-orchestrator in #524) MUST spawn golems as
**processes** (subprocess / container / worktree), NOT as Workflow subagents.
Spawning a golem as a Workflow subagent would consume the one nesting level and
make the review harness invocation throw.

## Environment Variables

These env vars toggle non-default behavior; all are opt-in:

- `AUTOMERGE=1` — in Option 1 (Branch + PR), queue the PR for GitHub's
  native auto-merge via `gh pr merge --auto --squash --delete-branch`
  immediately after PR creation and exit, skipping the CI-wait loop. Because
  the fast path exits before the post-CI multi-cycle review loop, it
  **intentionally skips that loop** — `AUTOMERGE=1` is the per-invocation
  escape hatch from the review gate. GitHub only. Skipped for
  `severity/critical` issues. Falls through to the normal CI-wait loop if
  `gh pr merge --auto` fails (e.g., auto-merge not enabled on the repo). See
  Option 1 "Auto-merge fast path" below. The orchestrate **integration train**
  (`orchestrate` § Phase T) is the batch consumer of this same
  `gh pr merge --auto` settle-on-green path: it lands a set of PRs with one
  up-front approval, relying on `--auto` to merge each as its (already-green)
  checks settle rather than a manual merge + wait per PR.
- `AUTOMERGE_AUTONOMOUS=1` — **required second consent** to allow the
  `AUTOMERGE=1` fast path *while autonomous*. Auto-merge skips the entire
  adversarial review loop, and an autonomous golem sets autonomy from the
  environment — so `AUTOMERGE=1` alone in an autonomous run would merge to the
  default branch unreviewed and unseen. To prevent that, when the run is
  autonomous the auto-merge fast path is taken ONLY if BOTH `AUTOMERGE=1` and
  `AUTOMERGE_AUTONOMOUS=1` are set. If `AUTOMERGE=1` is set but
  `AUTOMERGE_AUTONOMOUS=1` is not, the run ignores auto-merge and falls through
  to the normal CI-wait loop + review, stopping at green CI for human merge.
  Has no effect in non-autonomous runs (interactive `AUTOMERGE=1` is unchanged
  — the human is already in the loop). **Operational note:** the two-variable
  scheme is a real consent gate only if the variables come from *separate*
  sources — setting both in the same `.env` block, compose `environment:`, or
  CI secret group defeats the "second consent" intent (one copy-paste enables
  unreviewed merges). Inject `AUTOMERGE_AUTONOMOUS=1` from a distinct
  configuration source (e.g. a separate 1Password entry / secret group) than
  `AUTOMERGE=1`, and only for golem environments that are meant to auto-merge.
  The integration train does **not** weaken this: its single batch approval
  authorizes the *sequence* of merges, but each PR's auto-merge still requires
  BOTH `AUTOMERGE=1` and `AUTOMERGE_AUTONOMOUS=1` when the train runs autonomously.
- `PRE_REVIEW_STRICT=true` — pre-review gates (Step 3.5) block Option 1 PR
  creation on HIGH certainty findings instead of warning only.
- `REVIEW_MAX_CYCLES` — integer, default `3`. Caps the post-CI multi-cycle
  adversarial review loop (Option 1). The cap lives in this skill, not in
  `workflow.js`, which runs exactly one review cycle per invocation.
- `REVIEW_STRICT=true` — treat MEDIUM-certainty findings as blocking in the
  adversarial review (Step 3.5 item 6 and the Step 4 loop), in addition to the
  default HIGH-certainty blocking set. Parallels `PRE_REVIEW_STRICT`.

## Step 1 — Read State

1. **Discover the current state file**:

   - List JSON state files: `ls .claude/memory/tmp/next-issue-*.json 2>/dev/null`
   - **If multiple files exist**: list them and ask which issue to ship
   - **If exactly one file**: use it
   - **If none exist**: check for legacy `.md` files:
     - `ls .claude/memory/tmp/next-issue-*.md 2>/dev/null`
     - If found, migrate to `.json`: read YAML frontmatter fields, write `.json`
       with those fields plus `"version": 2`, delete the `.md` file
     - Also check for `.claude/memory/tmp/next-issue-state.md` (legacy singleton)
       — read its `issue:` field, migrate to `.claude/memory/tmp/next-issue-{N}.json`

1. Extract: `issue` (number), `title`, `platform` (`github` or `gitlab`),
   `branch` (if set), `autonomous` (boolean — feeds the autonomy toggle
   above), and `plan_comment_url` (if present)

1. If no state file is found, tell the user:

   > No in-progress issue found. Run `/next-issue` first to select and plan
   > an issue.

   Then stop.

## Step 2 — Detect Platform

Use the `platform` field from the state file. If missing, detect from
`git remote -v`:

| Pattern in remote URL     | Platform | CLI    |
| ------------------------- | -------- | ------ |
| `github.com` or `ghe.`    | GitHub   | `gh`   |
| `gitlab.com` or `gitlab.` | GitLab   | `glab` |

## Step 2.5 — Agent Worktree Detection

Check if the current branch is an agent worktree:

```bash
CURRENT_BRANCH=$(git branch --show-current)
```

Apply this precedence (first match wins):

1. **If autonomous**: skip Step 3, go to Option 1 (Branch + PR) regardless of
   branch name (including `^agent`).
1. **Else if `$CURRENT_BRANCH` matches `^agent`** (e.g., `agent01`, `agent02`):
   - **Skip Step 3** (do not ask the user for shipping mode)
   - **Go directly to Option 3** (commit only, no push)
   - Agents never create PRs or push — the orchestrator owns delivery
1. **Else** (branch does not match `^agent`): proceed to Step 3 as normal.

Autonomous mode decouples commit-only from `^agent` detection — autonomy
pushes and opens a PR; commit-only remains the default for `^agent` branches
only in non-autonomous (legacy local-merge) runs.

## Step 3 — Choose Shipping Mode

When autonomous, skip the prompt and select Option 1 (Branch + PR). Otherwise
use `AskUserQuestion` to present three options:

**Option 1 — Branch + PR** (recommended for feature work):

> Create a feature branch (if not already on one), commit, push, and open a
> pull request. Adds `status/pr-pending` label to the issue.

**Option 2 — Commit to main + push**:

> Commit directly to main and push. The `Closes #{N}` keyword auto-closes
> the issue on push.

**Option 3 — Commit only (no push)**:

> Commit on the current branch but do not push. Adds `status/commit-pending`
> label so the issue is not re-selected.

## Step 3.5 — Pre-Ship Validation

Before executing the chosen shipping mode, run these safety checks:

1. **Run test suite** — auto-detect the project's test runner (see
   `orchestrate/merge-protocol.md` § Test Runner Detection for the detection
   order: `package.json` → `pyproject.toml` → `go.mod` → `Cargo.toml` →
   `Gemfile` → `Makefile` → `build.gradle`).

   - If tests **pass**: proceed to Step 4
   - If tests **fail**:
     - Show the failure summary to the user
     - Ask: **Fix failures now, or ship anyway?**
     - **Option 1 (Branch + PR)**: test failure is **blocking** — do NOT
       create a PR with failing tests. The user must fix first or switch to
       Option 3 (commit only)
     - **Option 2/3**: test failure is **advisory** — warn but allow commit
     - **When autonomous** (always Option 1): test failure stays **blocking**
       — never open a PR with red tests — but do NOT prompt. Attempt an
       autonomous fix in a capped loop (cap at 3 attempts), re-running tests
       each time. If still failing after the cap, STOP and emit the
       structured completion summary (see Option 1 "Autonomous completion
       summary") reporting the test failure, rather than asking
   - If **no test runner detected**: skip this check and note it in the output

1. **Verify git status** — check for untracked files that look like they
   should be staged (new source files, new test files). Warn if found.

1. **Check branch freshness** (Option 1 only) — if on a feature branch,
   check if main has advanced:

   ```bash
   git fetch origin main
   git rev-list --count HEAD..origin/main
   ```

   If count > 0, warn: "Main has {N} new commits since this branch was
   created. Consider rebasing before PR."

   When autonomous, do not prompt — branch freshness is advisory; record the
   warning as a note for the completion summary and proceed.

1. **Check for plan drift** (optional) — fetch the issue body and check for
   "Affected Files" or "Acceptance Criteria" sections. If either exists,
   run drift analysis (see `drift-detect` skill for full workflow):

   - Compare planned files from the issue against actual files from
     `git diff --name-only origin/main...HEAD`
   - Check acceptance criteria checkboxes for unaddressed items
   - **If HIGH-severity drift found**: warn and ask — "Fix drift now,
     ship anyway, or skip?"
   - **If only MEDIUM/LOW drift**: show summary, proceed automatically
   - **If no plan sections found in issue**: skip this check silently

   This check is advisory — the user can always choose to ship anyway.

   When autonomous, do not prompt — drift is advisory; record any findings as
   notes for the completion summary and proceed.

1. **Pre-review gates** (advisory by default) — run deterministic quality
   scanning on changed files to catch mechanical issues before review:

   a. Generate file list from the diff:

   ```bash
   git diff --name-only origin/main...HEAD > /tmp/pre-review-files.txt
   ```

   b. Run the pre-review scanner (locate `pre-review-gates.sh` in the same
   directory as this skill file):

   ```bash
   bash pre-review-gates.sh /tmp/pre-review-files.txt
   ```

   c. Parse TSV output — each line: `file\tline\tcategory\tevidence\tcertainty`

   **Categories detected:**

   | Category              | What it catches                                  | Certainty |
   | --------------------- | ------------------------------------------------ | --------- |
   | `ai-slop`             | Hedging phrases, buzzword inflation, filler text | HIGH      |
   | `debug-statement`     | print(), console.log, debugger, breakpoint       | HIGH      |
   | `missing-test-file`   | Source files with no corresponding test file     | HIGH      |
   | `untested-public-api` | Public functions not referenced in any test file | HIGH      |

   **Handling findings:**

   - **No findings**: proceed silently to Step 4
   - **Findings exist (advisory mode — the default)**:
     - Show a summary table: category, count, top examples
     - For HIGH certainty `ai-slop` or `debug-statement` findings: offer to
       auto-fix (remove debug lines, trim AI slop phrases) before committing
     - For `missing-test-file` / `untested-public-api`: note these in the PR
       description (Option 1) so reviewers are aware
     - Proceed to Step 4 regardless of findings
   - **Strict mode** (`PRE_REVIEW_STRICT=true` in environment):
     - HIGH certainty findings **block Option 1** (PR creation) — the user
       must fix them or explicitly choose "ship anyway"
     - Options 2/3 remain advisory (warn only)

   **PR description integration** (Option 1 only): if findings remain after
   auto-fix, append a "Pre-review findings" section to the PR body:

   ```markdown
   ## Pre-review findings

   - 2x debug-statement (src/handler.py:42, src/utils.py:18)
   - 1x missing-test-file (src/new_module.py)
   ```

   **Autonomous mode**: never prompt. Apply auto-fixes as in advisory mode and
   record any remaining findings as notes for the completion summary (and in
   the PR description as above). Pre-review stays advisory unless
   `PRE_REVIEW_STRICT=true`, in which case HIGH certainty findings still block
   Option 1 — but the run STOPS and emits the structured completion summary
   (see Option 1 "Autonomous completion summary") rather than prompting.

   **Graceful degradation**: if `pre-review-gates.sh` is not found or fails
   to execute, skip this check with a note: "Pre-review gates skipped
   (scanner not available)." Never block shipping due to scanner errors.

1. **Adversarial pre-PR review** (Option 1 only) — run a multi-dimension
   adversarial review of the changes **before** the PR is opened, so the PR's
   first impression is review-clean. This complements the deterministic
   pre-review gates above with LLM reviewers (security, correctness, tests,
   CLAUDE.md conventions, scope-drift) plus a fresh judge and gatekeeper.

   a. Compute the review scope from the diff against `main`:

   ```bash
   git fetch origin main
   git diff --name-only origin/main...HEAD   # -> files
   git diff origin/main...HEAD               # -> diff (context)
   ```

   If there are no committed changes yet (work is staged but not committed),
   stage and make the implementation commit first (Step 4 Option 1 steps 1-3),
   then compute the scope — the review needs a diff to read.

   b. **Invoke the `Workflow` tool** with the script bundled alongside this
   skill at `~/.claude/skills/next-issue-ship/workflow.js`, passing:

   ```text
   args: {
     phase: "pre-pr",
     cycle: 1,
     maxCycles: <REVIEW_MAX_CYCLES, default 3>,
     files: [<changed files>],
     diff: "<diff text>",
     issue: { number: {N}, title: "{title}" }
   }
   ```

   The harness fans the dimensions as one parallel barrier under a single
   token budget, re-scores certainty with a fresh judge, and returns
   `{ blocking[], deferrable[], summary, budget_exhausted, clean }`. The review
   agents are **read-only** — applying fixes and filing deferrals is this
   skill's job (below).

   c. **Resolve the blocking findings**: for each finding in `blocking`, make
   the fix in the working tree, then amend or add a commit. Re-run step (b)
   (incrementing `cycle`) until `clean` is true or `cycle` exceeds
   `REVIEW_MAX_CYCLES`. When `REVIEW_STRICT=true`, also treat MEDIUM-certainty
   findings as blocking.

   d. **Collect the deferrables**: keep the `deferrable` list for filing
   **after** the PR exists (so the filed issues can link the PR) — see Option 1
   "File deferred review findings".

   e. **Cap / budget exhaustion**: if `cycle` exceeds `REVIEW_MAX_CYCLES` or
   `budget_exhausted` is true with blocking findings still open:

   - **Interactive**: ask — **Fix remaining blocking findings now, ship anyway,
     or defer them?**
   - **Autonomous**: do NOT prompt. Proceed to open the PR, but record the
     remaining blocking findings as a STOP note for the completion summary
     (Option 1 "Autonomous completion summary" → "Review status").

   **Graceful degradation**: if the `Workflow` tool or
   `~/.claude/skills/next-issue-ship/workflow.js` is unavailable, skip this
   step with a note: "Adversarial pre-PR review skipped (harness not
   available)." Never block shipping due to harness errors.

## Step 4 — Execute

### Option 1 — Branch + PR

1. **Ensure on a feature branch**:

   - If currently on `main` (or the default branch), create and switch to a
     new branch using the naming convention from `next-issue/state-format.md`:

     ```bash
     git fetch origin main
     git checkout -b {prefix}/issue-{N}-{slug} origin/main
     ```

   - If already on a feature branch, stay on it

1. **Stage and commit**. The commit message MUST include `Closes #{N}` in
   the body:

   ```text
   {type}({scope}): {description}

   {optional body explaining the change}

   Closes #{N}
   ```

   Where `{type}` matches the branch prefix: `fix/` → `fix:`,
   `feature/` → `feat:`, `docs/` → `docs:`, `test/` → `test:`,
   `refactor/` → `refactor:`, `chore/` → `chore:`.

1. **Verify** the commit message: run `git log -1 --format=%B` and confirm
   `Closes #{N}` is present. If missing, amend to add it.

1. **Push** the branch:

   ```bash
   git push -u origin HEAD
   ```

1. **Create a PR**:

   - GitHub:

     ```bash
     gh pr create --title "{type}({scope}): {description}" --body "$(cat <<'EOF'
     ## Summary
     - {what changed and why}

     ## Test plan
     - {how this was tested}

     Closes #{N}
     EOF
     )"
     ```

   - GitLab:

     ```bash
     glab mr create --title "{type}({scope}): {description}" \
       --description "## Summary\n- {what changed and why}\n\n## Test plan\n- {how this was tested}\n\nCloses #{N}"
     ```

1. **Auto-merge fast path** (if `AUTOMERGE=1`):

   When `AUTOMERGE=1` is set in the environment, hand the PR off to
   GitHub's native auto-merge and skip the CI-wait loop below. This is
   intended for routine low-risk issues where "wait for checks, then merge"
   is pure overhead.

   **Skip conditions** (fall through to the CI-wait loop instead):

   - Platform is not GitHub — the toggle is GitHub-only
   - **Run is autonomous AND `AUTOMERGE_AUTONOMOUS=1` is NOT set** — print
     `"auto-merge skipped (autonomous run requires AUTOMERGE_AUTONOMOUS=1)"`
     and continue. Auto-merge skips the adversarial review loop entirely; an
     autonomous golem must carry the explicit second consent before it may
     merge unreviewed. Without it, fall through to the normal CI-wait +
     review loop and stop at green CI for human merge.
   - Issue carries `severity/critical` — print
     `"auto-merge skipped (severity/critical)"` and continue
   - `gh pr merge --auto` exits non-zero (e.g., auto-merge not enabled on
     the repo) — log the error output and continue

   Otherwise:

   ```bash
   gh pr merge "$PR_NUM" --auto --squash --delete-branch
   ```

   On success, do the Option 1 cleanup inline and exit the skill:

   a. Update the state file `.claude/memory/tmp/next-issue-{N}.json` so
   `"phase"` is `"auto-merge-queued"` (preserves an audit trail if any
   step after this fails before the file is deleted)
   b. Label the issue `status/pr-pending` and remove `status/in-progress`:

   ```bash
   gh issue edit {N} --add-label "status/pr-pending" --remove-label "status/in-progress"
   ```

   c. Comment on the issue:

   ```bash
   gh issue comment {N} --body "Fix submitted in PR #{pr_number}. Queued for auto-merge (squash + delete-branch)."
   ```

   d. `git checkout main`
   e. Delete the state file (`.claude/memory/tmp/next-issue-{N}.json`)
   f. Show the PR URL to the user
   g. **Exit** — do not proceed to the CI-wait loop, labeling, or any other
   subsequent step in this option

   **Squash-by-default rationale**: `/next-issue` PRs are single-issue,
   single-deliverable units; squash keeps history linear and the merged
   commit still references the issue. Users who want merge-commits can
   run Option 1 without `AUTOMERGE=1`.

1. **Monitor CI and remediate failures** (advisory; the `ci-fixer` Workflow
   harness caps fixes at 3 attempts per check):

   Before labeling the issue, optionally monitor CI checks and auto-fix
   failures. Ask the user:

   - **Wait for CI** — monitor checks and auto-fix failures if possible
   - **Skip CI monitoring** — proceed to labeling immediately

   When autonomous, do not prompt — ALWAYS wait for CI and auto-fix (proceed
   as if the user chose "Wait for CI").

   If the user chooses to wait:

   a. **Poll for check completion**:

   - GitHub: `gh pr checks {pr_number} --json name,state,conclusion`
     (poll every 30 seconds until no checks have `state: "pending"`)
   - GitLab: `glab ci status` (check for completion)

   b. **If all checks pass**: inform the user and proceed to labeling

   c. **If checks fail**: hand the failures to the `ci-fixer` Workflow harness,
   which owns the retry loop (hard-capped at 3 attempts per check) and fans
   independent checks in parallel under one shared token budget — you no longer
   track an iteration counter by hand.

   - Collect every failing check into a `checks` array. For each one, grab the
     name and its run-failed logs:

     ```bash
     gh pr checks {pr_number} --json name,state,conclusion,link \
       | jq '[.[] | select(.conclusion == "failure")]'
     gh run view {run_id} --log-failed 2>&1 | tail -200   # one per failing check
     ```

   - **Invoke the `Workflow` tool** with the script at
     `~/.claude/agents/ci-fixer/workflow.js` (it ships bundled with the
     `ci-fixer` agent), passing
     `args: { checks: [{ name, logs, pr: {pr_number} }, …] }`. The harness runs
     a capped `parse → fix → verify` loop per check and returns
     `{ results: [{ check, fixed, summary, files_changed, remainingFailures, … }] }`.
     Agents never push — applying the commits is your job:

     - For each result with `fixed: true`: stage its `files_changed`, then make
       one commit `fix(ci): {summary}` (combine multiple fixed checks into a
       single commit when convenient), `git push`, and go back to (a) to
       re-check CI. **Before staging, hard-filter `files_changed` against the
       CI-config denylist** — drop any path matching `.github/workflows/`,
       `.gitlab-ci.yml`, `.github/actions/`, or `*/action.yml`. The `ci-fixer`
       agent is instructed not to touch CI config, but it has tree-wide edit
       access, so enforce it here rather than trusting the guardrail: if a
       result's `files_changed` contains a denylisted path, do NOT stage that
       path, and surface it to the user (autonomous: record as a STOP note in
       the completion summary) as "ci-fixer attempted a CI-config edit
       ({path}) — skipped; manual review required." Never let an automated CI
       fix rewrite the CI definition that gates it.
     - For each result with `fixed: false`: inform the user "CI check {check}
       appears to be {failure_type} — {summary}. Remaining: {remainingFailures}.
       Requires manual intervention." Ask: **Fix manually now, or ship with
       failing CI?** If fix manually, pause then go back to (a); if ship anyway,
       proceed to labeling. **When autonomous**: do NOT prompt — STOP and emit
       the structured completion summary (see "Autonomous completion summary"
       below) noting the unresolved CI failure; do not leave the run in a
       prompting state.

   The harness stops on its own once the per-check cap or the shared budget is
   reached, so there is no separate "after 3 attempts" step — surface any
   still-failing results to the user as above.

   **Graceful degradation**: If `gh pr checks` is unavailable or errors,
   skip CI monitoring with a note and proceed to labeling. CI monitoring
   never blocks shipping.

1. **Multi-cycle PR review loop** (after green CI) — re-review the PR after
   fixes land, because resolving one finding (or a CI fix) can silently
   introduce another. Each cycle re-runs the adversarial review harness **and**
   folds in open PR review comments, then resolves-or-defers everything.
   Skipped entirely when `AUTOMERGE=1` took the auto-merge fast path above.

   Run the loop with `cycle = 1` and `cap = REVIEW_MAX_CYCLES` (default 3):

   a. **Gather the changed scope** (now includes any CI fixes):

   ```bash
   git diff --name-only origin/main...HEAD   # -> files
   git diff origin/main...HEAD               # -> diff
   ```

   b. **Gather open PR review comments** and normalize unresolved review-thread
   comments + issue-style PR comments into a `prComments` array of
   `{ id, author, path?, line?, body, url? }`:

   ```bash
   gh pr view {pr_number} --json reviews,comments
   ```

   c. **Invoke the `Workflow` tool** with
   `~/.claude/skills/next-issue-ship/workflow.js`, passing:

   ```text
   args: {
     phase: "pr-cycle",
     cycle: <cycle>,
     maxCycles: <cap>,
     files: [<changed files>],
     diff: "<diff text>",
     prComments: [<normalized comments>],
     issue: { number: {N}, title: "{title}" }
   }
   ```

   It returns `{ blocking[], deferrable[], comments_addressed[], summary,
   budget_exhausted, clean }`.

   d. **Resolve or defer**:

   - For each `blocking` finding (and any comment triaged `blocking`): fix it
     in the working tree and stage. When `REVIEW_STRICT=true`, MEDIUM-certainty
     findings are blocking too.
   - For each `deferrable` finding (and any comment triaged `deferrable`): file
     it via Option 1 "File deferred review findings" below, then reply to the
     originating PR review comment (if any) with the new issue link so the
     comment is **resolved-or-deferred**, not dropped.

   e. **If any fixes were applied this cycle**: commit
   `fix(review): address cycle {cycle} findings`, `git push`, and re-run the
   CI-monitor sub-step above (wait for green, auto-fix via `ci-fixer`).

   f. **Terminate the loop** when ALL of the following hold:

   - `clean` is true (no blocking findings remain), **and**
   - CI is green, **and**
   - every PR comment is resolved-or-deferred (none left unaddressed).

   Otherwise `cycle++`; if `cycle` exceeds `cap`, **STOP** and surface the
   remaining blocking findings / unresolved comments. **Interactive**: ask
   **Keep fixing, ship as-is, or defer the rest?** **Autonomous**: do NOT
   prompt — STOP and record the remaining items for the completion summary
   (Review status: stopped-with-blocking).

   The cap and budget bound the loop: `workflow.js` runs one cycle per
   invocation and returns partial results if its shared budget is exhausted, so
   the loop always terminates.

   **Graceful degradation**: if the `Workflow` tool or the harness script is
   unavailable, skip this loop with a note ("Multi-cycle review skipped
   (harness not available)") and proceed to labeling. Review never blocks
   shipping due to harness errors.

1. **File deferred review findings** — for each deferrable finding collected in
   the pre-PR pass (Step 3.5 item 6) and every loop cycle above:

   - Preferred: invoke **`/file-issue`** with the finding's title, severity,
     category, and description as the seed (its auto-labeling and scope checks
     apply). In autonomous mode, pre-answer `/file-issue`'s questions from the
     finding fields so it does not prompt.
   - Autonomous fallback (to avoid a nested interactive skill): create the
     issue directly with the same label taxonomy `/file-issue` uses. Pass the
     body via `--body-file`, **never** by interpolating `{finding.description}`
     into a `--body "..."` argument: the description is LLM-generated and may
     contain backticks, `$(...)`, quotes, or newlines that would break out of
     the quoted string and execute in the shell — and this path runs unattended
     under `--auto` with no human gate. Use the **`Write` tool** to write the
     body to a temp file (so the content never passes through a shell at all),
     then reference it:

     1. `Write` the body to `/tmp/deferred-finding-{n}.md` — the finding's
        description followed by `\n\nDeferred from PR #{pr_number} (review
        finding).`
     2. Create the issue from that file:

        ```bash
        gh issue create --title "{finding.title}" \
          --body-file /tmp/deferred-finding-{n}.md \
          --label "type/{type},severity/{sev},component/{comp}"
        ```

   Keep `--title` short and free of shell metacharacters (it is a finding
   name); if a title could contain them, write it into the body and use a
   generic title.

   - After filing, link the deferred issues on the PR in one comment:

     ```bash
     gh pr comment {pr_number} --body "Deferred review findings filed: #{A}, #{B}. Addressed on this PR: {count} blocking finding(s) across {cycles} review cycle(s)."
     ```

   - Append a "Review findings" section to the PR body (mirrors the
     "Pre-review findings" convention), listing fixed-on-PR vs deferred-to-#.

   Nothing is silently dropped: every confirmed finding is either fixed on the
   PR or filed as a linked issue.

1. **Label the issue** `status/pr-pending` and remove `status/in-progress`:

   - GitHub: `gh issue edit {N} --add-label "status/pr-pending" --remove-label "status/in-progress"`
   - GitLab: `glab issue update {N} --label "status/pr-pending" --unlabel "status/in-progress"`

1. **Comment on the issue**:

   If CI remediation was performed, include a summary in the comment:

   - GitHub: `gh issue comment {N} --body "Fix submitted in PR #{pr_number}. CI remediation: {N} fix(es) applied automatically."`
   - GitLab: `glab issue note {N} --message "Fix submitted in MR !{mr_number}. CI remediation: {N} fix(es) applied automatically."`

   If no CI remediation was needed or CI was skipped:

   - GitHub: `gh issue comment {N} --body "Fix submitted in PR #{pr_number}"`
   - GitLab: `glab issue note {N} --message "Fix submitted in MR !{mr_number}"`

1. **Checkout main**: `git checkout main`

1. **Delete state file** (remove `.claude/memory/tmp/next-issue-{N}.json`)

1. **Show the PR/MR URL** to the user

1. **Autonomous completion summary** (autonomous only) — after green CI,
   labeling, and the issue comment, emit a STRUCTURED COMPLETION SUMMARY and
   STOP for human merge. This summary replaces the interactive Step 5 prompt
   when autonomous. Format as a markdown block:

   ```markdown
   ## Autonomous ship summary

   - **Issue**: #{N} — {title}
   - **PR/MR**: {pr_or_mr_url}
   - **Branch**: {branch}
   - **CI**: {green | stopped-with-failure: {detail}}
   - **CI fixes applied**: {count} — {one-line summaries}
   - **Review cycles**: {cycles} run (cap {REVIEW_MAX_CYCLES})
   - **Review status**: {clean | stopped-with-blocking: {detail}}
   - **Findings fixed**: {count} blocking, on this PR
   - **Findings deferred**: {#A, #B (filed), or "none"}
   - **Comments resolved-or-deferred**: {n}/{total}
   - **Deferred notes**: {drift / branch-freshness / pre-review findings, or "none"}
   - **Plan comment**: {plan_comment_url, if present}

   No auto-merge unless `AUTOMERGE=1`. Ready for human merge.
   ```

   Then STOP — do not proceed to Step 5.

### Option 2 — Commit to main + push

1. Ensure on `main` (or warn if on a different branch and confirm)

1. **Stage and commit** with `Closes #{N}` in the body (same format as above)

1. **Verify** the commit message includes `Closes #{N}`

1. **Push**:

   ```bash
   git push origin main
   ```

1. **Remove `status/in-progress` label**:

   - GitHub: `gh issue edit {N} --remove-label "status/in-progress"`
   - GitLab: `glab issue update {N} --unlabel "status/in-progress"`

1. **Delete state file** (remove `.claude/memory/tmp/next-issue-{N}.json`;
   the `Closes` keyword auto-closes the issue on push)

1. Tell the user the issue will auto-close when the push is processed

### Option 3 — Commit only (no push)

1. **Stage and commit** with `Closes #{N}` in the body (same format as above)
1. **Verify** the commit message includes `Closes #{N}`
1. **Do NOT push**
1. **Label the issue** `status/commit-pending` and remove `status/in-progress`:
   - GitHub: `gh issue edit {N} --add-label "status/commit-pending" --remove-label "status/in-progress"`
   - GitLab: `glab issue update {N} --label "status/commit-pending" --unlabel "status/in-progress"`
1. **Comment on the issue** with the commit SHA:
   - **Agent mode** (branch matches `^agent`):
     - GitHub: `gh issue comment {N} --body "Agent {branch} committed fix. Ready for orchestrator review. Commit: {sha}"`
     - GitLab: `glab issue note {N} --message "Agent {branch} committed fix. Ready for orchestrator review. Commit: {sha}"`
   - **Normal mode**:
     - GitHub: `gh issue comment {N} --body "Fix committed locally (not yet pushed). Commit: {sha}"`
     - GitLab: `glab issue note {N} --message "Fix committed locally (not yet pushed). Commit: {sha}"`
1. **Delete state file** (remove `.claude/memory/tmp/next-issue-{N}.json`)
1. Tell the user the commit is local and needs to be pushed later

## Step 5 — Context Reset & Continue

When autonomous, skip this step entirely — the run already emitted its
completion summary (see Option 1 "Autonomous completion summary") and exits. A
single golem owns one issue; looping is the orchestrator's responsibility and
out of scope here.

After shipping, tell the user:

> Issue #{N} shipped. Run `/clear` to start fresh, then `/next-issue` to
> pick up the next issue.

Then ask with `AskUserQuestion`:

- **Pick next issue** — invoke `/next-issue` to select and plan the next one
- **Stop** — end the session

**Agent worktree mode**: When running on an agent branch (`^agent`), this
behavior persists across invocations — `/next-issue-ship` will always
auto-select commit-only mode (Option 3) without prompting.
