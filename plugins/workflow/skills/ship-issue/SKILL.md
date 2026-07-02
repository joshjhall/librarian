---
description: Ship the current next-issue work — commit, deliver (PR or push), label the issue, and optionally loop back. Use after implementation and testing are complete for an issue started with /next-issue.
---

# Ship Issue

Delivers the completed work for an issue previously selected and planned by
`/next-issue`. Handles committing, pushing, PR creation, issue labeling, and
state cleanup.

**Prerequisite**: Implementation and testing must be complete before invoking
this skill. The state file written by `/next-issue` must exist.

## Pipeline

This skill is the delivery half of the `/next-issue` → `/ship-issue`
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
- **Auto-chained by `/next-issue --autonomous`** — the autonomous flow, which sets
  `"autonomous": true` (see below). Autonomous `/next-issue` invokes this skill
  **in the same turn** (via the `Skill` tool) once implementation and testing
  complete — it does not stop and suggest a manual run. This skill therefore
  must work whether reached in-turn (state file already current in context) or
  fresh after a turn-exit (re-read from the state file in Step 1); both paths
  detect autonomy via the toggle below.

## Autonomous Mode

The run is **autonomous** when ANY of the following holds: the literal token
`--autonomous` (deprecated alias `--auto`) appears in the invocation arguments,
the environment variable `NEXT_ISSUE_AUTONOMOUS=1` is set, OR the state file
read in Step 1 has `"autonomous": true`. Autonomy is strictly opt-in.

> **Flag rename (deprecation).** `--autonomous` is the autonomy flag; `--auto`
> remains a **deprecated alias** for one release and behaves identically. This
> is distinct from `gh pr merge --auto` (GitHub's auto-merge flag, used
> verbatim below) and from `--permission-mode auto` (the Claude Code harness
> flag) — neither of those is affected by this rename.

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

## Golem Execution Model & Environment Variables

**Companion file**: `ship-protocol.md` in this skill directory carries (1) the
**Golem Execution Model** — a golem running this skill is an OS **process**,
never a Workflow subagent, because the one permitted Workflow nesting level is
reserved for this skill's review harness; orchestrators MUST spawn golems as
processes (subprocess / container / worktree), and (2) the full **Environment
Variables** contract: `AUTOMERGE` plus `AUTOMERGE_AUTONOMOUS` (the auto-merge
fast path and its autonomous double-consent), `PRE_REVIEW_STRICT` /
`REVIEW_STRICT` / `REVIEW_MAX_CYCLES` (review gating), and the `LIBRARIAN_CI_*`
family (CI-wait threshold/extensions and infra-flake triage tuning). Load
`ship-protocol.md` before relying on any of these toggles.

## Step 1 — Read State

1. **Discover the current state file**:

   - List JSON state files (the singleton `next-issue-queue.json` is a
     dependency-queue record, NOT a per-issue state file — exclude it):
     `ls .claude/memory/tmp/next-issue-*.json 2>/dev/null | grep -v '/next-issue-queue\.json$'`
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

   > **Dependency queue:** if `.claude/memory/tmp/next-issue-queue.json` exists
   > and the issue being shipped is that queue's `active` entry, **leave the
   > queue file in place** — do NOT delete or mutate it here. The next
   > `/next-issue` run advances the queue on resume (it re-reads the queue,
   > drops the now-closed entry, and recomputes `active` — see
   > `next-issue/state-format.md` § Dependency Queue). Shipping only deletes the
   > per-issue `next-issue-{N}.json`, never the queue file.

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

**Companion file**: `pre-ship-validation.md` in this skill directory carries the
full six-check pre-ship validation sequence. Before executing the chosen shipping
mode, run these safety checks in order:

1. **Run test suite** (auto-detect runner) — blocking for Option 1 / autonomous
   (never open a PR with red tests; autonomous attempts a capped 3-fix loop then
   STOPs with a completion summary); advisory for Options 2/3.
1. **Verify git status** — warn on untracked source/test files that look stageable.
1. **Check branch freshness** (Option 1) — warn if `origin/main` has advanced;
   advisory (autonomous records a note and proceeds).
1. **Check for plan drift** (optional) — compare planned vs actual files +
   acceptance criteria; advisory (autonomous records notes and proceeds).
1. **Pre-review gates** — run `pre-review-gates.sh` over the diff; advisory by
   default, HIGH-certainty findings block Option 1 under `PRE_REVIEW_STRICT=true`.
1. **Adversarial pre-PR review** (Option 1) — run the `workflow.js` harness
   (`phase: "pre-pr"`); fix `blocking` findings in a `REVIEW_MAX_CYCLES`-capped
   loop, collect `deferrable` for filing after the PR exists.

Each check degrades gracefully (a missing scanner/harness is skipped with a note,
never a hard-fail) and never prompts when autonomous. See `pre-ship-validation.md`
for the per-check commands, tables, and autonomous-mode rules.

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

1. **Monitor CI, run the multi-cycle review loop, and file deferred findings**
   — **Companion file**: `ci-review-protocol.md` in this skill directory carries
   the full protocol for these three post-PR-creation steps. Skipped entirely
   when `AUTOMERGE=1` took the auto-merge fast path above. In brief:

   - **Monitor CI and remediate failures** (advisory; `ci-fixer` caps fixes at 3
     attempts per check). Autonomous always waits. Poll `gh pr checks` every 30 s
     against the `LIBRARIAN_CI_WAIT_TIMEOUT` checkpoint (autonomous auto-extends
     up to `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS`, then STOPs). On failure, **triage
     infra-flake vs real first** (classify by failing-step name vs the diff;
     auto-retry an infra flake once via `gh run rerun --failed`; collapse cascade
     failures to their root cause), then hand real failures to the `ci-fixer`
     `workflow.js` harness — applying its commits (hard-filtered against the
     CI-config denylist), pushing, and re-polling.
   - **Multi-cycle PR review loop** (after green CI) — re-run the `workflow.js`
     harness (`phase: "pr-cycle"`) folding in open PR comments, resolve `blocking`
     / file `deferrable`, commit + push + re-check CI each cycle, terminate when
     clean + green + every comment resolved-or-deferred (cap `REVIEW_MAX_CYCLES`).
   - **File deferred review findings** — file each via `/file-issue` (autonomous
     fallback: `gh issue create --body-file`, never interpolating LLM text into a
     shell arg), link them on the PR, and append a "Review findings" section to
     the PR body. Nothing is silently dropped.

   Every sub-step degrades gracefully (a missing harness/`gh` is skipped with a
   note, never a hard-fail) and never prompts when autonomous. See
   `ci-review-protocol.md` for the commands, the failure-triage classifier, the
   loop-termination rule, and the deferred-filing safety contract.

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
behavior persists across invocations — `/ship-issue` will always
auto-select commit-only mode (Option 3) without prompting.
