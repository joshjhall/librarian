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
  no `/clear`. Being reached this way is **not an autonomy signal**: the `--ship`
  fast-path keeps the plan-approval gate and leaves the level at **L1**, so this
  run still prompts for shipping mode (Step 3) and every other interactive gate.
- **Auto-chained by `/next-issue --level 3|4`** (or the `--autonomous`/`--auto`
  L4 aliases) — the higher-autonomy flow, which persists `autonomy_level` in the
  state file (see below). That `/next-issue` invokes this skill **in the same
  turn** (via the `Skill` tool) once implementation and testing complete — it
  does not stop and suggest a manual run. This skill therefore must work whether
  reached in-turn (state file already current in context) or fresh after a
  turn-exit (re-read from the state file in Step 1); both paths resolve the level
  from `autonomy_level` in Step 1.

## Autonomy Level

Ship reads the run's **autonomy level** (L1–L4) from the state file's
`autonomy_level` (Step 1), falling back to the legacy `autonomous` boolean
(`true` → L4, `false`/absent → L1). The level — not a binary flag — decides how
each gate below is dispatched, per the contract in
`orchestrate/autonomy-levels.md` (#174). The two gate dispositions that matter to
ship:

- **Routine gates** (push, PR-open, **merge on green CI + clean review**, prune)
  — **auto-passed at L3–L4**, **human-authorized at L1–L2**. Resolve the
  disposition with
  `${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh gate routine --level {N}`
  (→ `disposition=auto|human`, #190) rather than re-deriving the L3–L4 cutoff.
- The **merge invariant** (below) is uncrossable at **every** level, L4 included.

> **Level, not "autonomous".** The old binary `autonomous` flag is retired as the
> control (its state-file mirror is read only for back-compat, mapping to L4/L1).
> `--autonomous`/`--auto`/`NEXT_ISSUE_AUTONOMOUS=1` remain **aliases for L4**.
> `gh pr merge --auto` (GitHub's auto-merge flag) and `--permission-mode auto`
> (the harness flag) are unrelated to the autonomy level.

**Behavior by level:**

- **L3–L4** — do NOT call `AskUserQuestion`; every gate takes its documented
  default. Always Branch + PR (Option 1), regardless of branch name. Always wait
  for CI and auto-fix failures. After **green CI + clean review**, **auto-merge**
  (squash, delete-branch) then prune — this is the routine-gate merge (see Step 4).
- **L1–L2** — every interactive prompt runs verbatim: prompt for shipping mode
  (Step 3), and **stop at green CI + clean review with the completion summary for
  a human to merge**. Ship never merges at L1–L2.

**The merge invariant (all levels, including L4).** Never merge unless CI is green
**and** the PR review loop terminated clean. If either fails and cannot be
mechanically resolved, it is a **dead-end** (see `orchestrate/autonomy-levels.md`
§ dead-end rule and #181): park the PR, emit the dead-end summary, and wait for a
human — **even at L4**. The level decides whether merging needs a human keystroke,
never whether an un-green or un-reviewed PR may merge.

When at an **L1 disposition** (the interactive default), behavior is unchanged —
every prompt below runs verbatim.

## Golem Execution Model & Environment Variables

**Companion file**: `ship-protocol.md` in this skill directory carries (1) the
**Golem Execution Model** — a golem running this skill is an OS **process**,
never a Workflow subagent, because the one permitted Workflow nesting level is
reserved for this skill's review harness; orchestrators MUST spawn golems as
processes (subprocess / container / worktree), and (2) the full **Environment
Variables** contract: `PRE_REVIEW_STRICT` / `REVIEW_STRICT` / `REVIEW_MAX_CYCLES`
(review gating), and the `LIBRARIAN_CI_*` family (CI-wait threshold/extensions and
infra-flake triage tuning). The legacy `AUTOMERGE` / `AUTOMERGE_AUTONOMOUS`
double-consent is **retired as the merge path** — merge is now the level-aware
routine gate in Step 4 (L3–L4 auto after green + clean; L1–L2 human). The vars are
retained-but-deprecated until #178 removes them. Load `ship-protocol.md` before
relying on any of these toggles.

## Step 1 — Read State

1. **Discover the current state file**:

   - List JSON state files (the singleton `next-issue-queue.json` is a
     dependency-queue record, NOT a per-issue state file — exclude it):
     `ls .claude/memory/tmp/next-issue-*.json 2>/dev/null | command grep -v '/next-issue-queue\.json$'`
   - **If multiple files exist**: list them and ask which issue to ship
   - **If exactly one file**: use it
   - **If none exist**: check for legacy `.md` files:
     - `ls .claude/memory/tmp/next-issue-*.md 2>/dev/null`
     - If found, migrate to `.json`: read YAML frontmatter fields, write `.json`
       with those fields plus `"version": 2`, delete the `.md` file
     - Also check for `.claude/memory/tmp/next-issue-state.md` (legacy singleton)
       — read its `issue:` field, migrate to `.claude/memory/tmp/next-issue-{N}.json`

1. Extract: `issue` (number), `title`, `platform` (`github` or `gitlab`),
   `branch` (if set), `autonomy_level` (integer 1–4 — the primary autonomy
   field; feeds the level model above), `autonomous` (legacy boolean — read
   only for back-compat), and `plan_comment_url` (if present).

   **Resolve the run's level** by calling the resolver (issue #190) — the same
   authoritative implementation `/next-issue` uses — rather than re-deriving the
   back-compat precedence by hand:

   ```bash
   # $STATE_LEVEL = the state file's autonomy_level ("" if absent);
   # $STATE_AUTO  = the legacy autonomous boolean ("true"/"false"/"" if absent).
   eval "$(${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh read \
       --state-level "$STATE_LEVEL" --state-autonomous "$STATE_AUTO")"
   # -> sets autonomy_level (1-4)
   ```

   The resolver applies the precedence (see
   `next-issue/schemas/next-issue-state.schema.json`): a present `autonomy_level`
   wins (1–4); else legacy `autonomous: true` → **L4**, `false`/absent → **L1**.

   The level decides every gate below: **L1–L2** keep human gates (stop for a
   human at shipping mode and at merge), **L3–L4** auto-pass the routine gates
   (push, PR-open, merge-on-green+clean, prune). The `severity/critical` cap
   (issue L3 max) is applied by `/next-issue` when it writes `autonomy_level`, so
   ship trusts the stored level as-is.

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

1. **If L3–L4**: skip Step 3, go to Option 1 (Branch + PR) regardless of
   branch name (including `^agent`).
1. **Else if `$CURRENT_BRANCH` matches `^agent`** (e.g., `agent01`, `agent02`):
   - **Skip Step 3** (do not ask the user for shipping mode)
   - **Go directly to Option 3** (commit only, no push)
   - Agents never create PRs or push — the orchestrator owns delivery
1. **Else** (L1–L2 and branch does not match `^agent`): proceed to Step 3 as
   normal.

An **L3–L4** run decouples commit-only from `^agent` detection — it pushes and
opens a PR; commit-only remains the default for `^agent` branches only in an
**L1–L2** (legacy local-merge) run.

## Step 3 — Choose Shipping Mode

At **L3–L4**, skip the prompt and select Option 1 (Branch + PR). At **L1–L2**,
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

1. **Run test suite** (auto-detect runner) — blocking for Option 1 / L3–L4
   (never open a PR with red tests; an L3–L4 run attempts a capped 3-fix loop
   then STOPs with a completion summary); advisory for Options 2/3.
1. **Verify git status** — warn on untracked source/test files that look stageable.
1. **Check branch freshness** (Option 1) — warn if `origin/main` has advanced;
   advisory (an L3–L4 run records a note and proceeds).
1. **Check for plan drift** (optional) — compare planned vs actual files +
   acceptance criteria; advisory (an L3–L4 run records notes and proceeds).
1. **Pre-review gates** — run `pre-review-gates.sh` over the diff; advisory by
   default, HIGH-certainty findings block Option 1 under `PRE_REVIEW_STRICT=true`.
1. **Adversarial pre-PR review** (Option 1) — run the `workflow.js` harness
   (`phase: "pre-pr"`); fix `blocking` findings in a `REVIEW_MAX_CYCLES`-capped
   loop, collect `deferrable` for filing after the PR exists.

Each check degrades gracefully (a missing scanner/harness is skipped with a note,
never a hard-fail) and never prompts at L3–L4. See `pre-ship-validation.md`
for the per-check commands, tables, and per-level rules.

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

   > **The review-skipping `AUTOMERGE` fast path is retired.** Earlier versions
   > queued `gh pr merge --auto` right here, *before* the review loop, as an
   > escape hatch from the review gate (guarded by
   > `AUTOMERGE`/`AUTOMERGE_AUTONOMOUS`). That path is **gone** — there is no
   > unreviewed merge anymore. Merge is now a **routine gate** that fires **after**
   > the CI-wait + review loop terminates green **and** clean (see the merge step
   > below). The env vars are retained-but-deprecated for one release; their
   > removal is #178's cleanup sweep. See `ship-protocol.md` § Environment
   > Variables.

1. **Monitor CI, run the multi-cycle review loop, and file deferred findings**
   — **Companion file**: `ci-review-protocol.md` in this skill directory carries
   the full protocol for these three post-PR-creation steps. This loop always
   runs before any merge — there is no path that skips it. In brief:

   - **Monitor CI and remediate failures** (advisory; `ci-fixer` caps fixes at 3
     attempts per check). An L3–L4 run always waits. Poll `gh pr checks` every
     30 s against the `LIBRARIAN_CI_WAIT_TIMEOUT` checkpoint (L3–L4 auto-extends
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
   note, never a hard-fail) and never prompts at L3–L4. See
   `ci-review-protocol.md` for the commands, the failure-triage classifier, the
   loop-termination rule, and the deferred-filing safety contract.

1. **Merge gate — level-aware, merge on green CI + clean review.** Reached only
   once the loop above **terminated green + clean** (CI green, `clean` true, every
   PR comment resolved-or-deferred). This is the **routine-gate merge** — merge
   *because* CI is green AND the review loop ran AND came back clean.

   **The merge invariant is checked first, at every level (incl. L4):** if the
   loop did **not** reach green + clean — CI still red after `ci-fixer`'s cap, an
   unresolved blocking finding, or an unaddressed comment — this is a **dead-end**
   (`orchestrate/autonomy-levels.md`; #181). Do **NOT** merge at any level. Park
   the PR, emit the dead-end summary (what is un-green/unclean, what was
   attempted, what remains), leave `status/pr-pending` on the issue, and STOP for
   a human. Then skip the rest of this step.

   With the invariant satisfied, dispatch by level:

   - **L3–L4 — auto-merge, then prune.** Merge the PR yourself (squash,
     delete-branch), then do the cleanup inline:

     ```bash
     gh pr merge "$PR_NUM" --squash --delete-branch
     ```

     a. Label the issue `status/pr-pending` → the `Closes #{N}` in the PR body
     closes it on merge; remove `status/in-progress`:

        ```bash
        gh issue edit {N} --add-label "status/pr-pending" --remove-label "status/in-progress"
        ```

     b. Comment on the issue:

        ```bash
        gh issue comment {N} --body "Fix merged in PR #{pr_number} (squash + delete-branch) after green CI + clean review."
        ```

     c. `git checkout main` (then `git pull` to fast-forward the merge)
     d. Delete the state file (`.claude/memory/tmp/next-issue-{N}.json`)
     e. Show the PR URL, then **exit** — skip the L1–L2 labeling/comment steps
     below and Step 5.

     If `gh pr merge` exits non-zero (e.g., branch protection needs a human
     approval the golem can't supply, or auto-merge/merge is disabled), treat it
     as a **dead-end**: log the error, leave the PR open + labeled, emit the
     dead-end summary, and STOP for a human. Never loop-retry a merge that the
     platform refused.

   - **L1–L2 — stop for a human merge.** Do NOT merge. Emit the completion
     summary (CI green, review clean, PR URL) and hand off to a human to merge —
     today's default behavior. Continue to the labeling + comment steps below,
     then Step 5.

   **Squash-by-default rationale**: `/next-issue` PRs are single-issue,
   single-deliverable units; squash keeps history linear and the merged commit
   still references the issue.

1. **Label the issue** `status/pr-pending` and remove `status/in-progress`
   (L1–L2 path; the L3–L4 path already did this inline above):

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

1. **Completion summary** (L2 only; L1 falls through to the interactive Step 5) —
   after green CI + clean review, labeling, and the issue comment, emit a
   STRUCTURED COMPLETION SUMMARY and STOP for a human to merge. (An L3–L4 run
   already merged and exited above; an L1 interactive run uses Step 5's prompt.)
   Format as a markdown block:

   ```markdown
   ## Ship summary (L{1-2} — ready for human merge)

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

   CI green + review clean. At L1–L2 the merge gate is a human's — ready for
   human merge. (An L3–L4 run would have auto-merged.)
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

At **L2–L4**, skip this step entirely — an L3–L4 run already merged and exited,
and an L2 run already emitted its completion summary (see Option 1 "Completion
summary") and stops for a human merge. A single golem owns one issue; looping is
the orchestrator's responsibility and out of scope here. Only an **L1**
interactive run reaches the prompt below.

After shipping, tell the user:

> Issue #{N} shipped. Run `/clear` to start fresh, then `/next-issue` to
> pick up the next issue.

Then ask with `AskUserQuestion`:

- **Pick next issue** — invoke `/next-issue` to select and plan the next one
- **Stop** — end the session

**Agent worktree mode**: When running on an agent branch (`^agent`), this
behavior persists across invocations — `/ship-issue` will always
auto-select commit-only mode (Option 3) without prompting.
