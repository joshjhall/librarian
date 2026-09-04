---
description: Ship the current next-issue work — commit, deliver (PR or push), label the issue, and optionally loop back. Use after implementation and testing are complete for an issue started with /workflow:next-issue.
---

# Ship Issue

Delivers the completed work for an issue previously selected and planned by
`/workflow:next-issue`. Handles committing, pushing, PR creation, issue labeling, and
state cleanup.

**Prerequisite**: Implementation and testing must be complete before invoking
this skill. The state file written by `/workflow:next-issue` must exist.

## Pipeline

This skill is the delivery half of the `/workflow:next-issue` → `/workflow:ship-issue`
pipeline (the two are kept as separate skills on purpose — see `## Pipeline` in
the `next-issue` skill for the rationale). The hand-off is the state file
`.claude/memory/tmp/next-issue-{N}.json`: `/workflow:next-issue` writes `phase` +
`checkpoint`; this skill reads them in Step 1. It can be invoked three ways:

- **Manually** after a `/clear` — the normal flow for `effort/medium`/`large`
  work, where planning context was reset before implementation.
- **Auto-invoked by `/workflow:next-issue --ship`** (alias `--now`) — the fast-path for
  `effort/trivial`/`small` issues, chaining here in the same context with no
  `/clear`. **Not an autonomy signal**: it keeps the plan-approval gate and leaves
  the level at **L1**, so this run still prompts for shipping mode (Step 3) and
  every other interactive gate.
- **Auto-chained by `/workflow:next-issue --level 3|4`** — the higher-autonomy flow, which
  persists `autonomy_level` (see below) and invokes this skill **in the same
  turn** (via the `Skill` tool) once implementation + testing complete, without
  suggesting a manual run. Ship must work whether reached in-turn (state current
  in context) or fresh after a turn-exit (re-read in Step 1); both resolve the
  level from `autonomy_level` in Step 1.

## Autonomy Level

Ship reads the run's **autonomy level** (L1–L4) from the state file's
`autonomy_level` (Step 1); absent, it defaults to L1. The level — not a binary
flag — decides how each gate below is dispatched, per the contract in
`orchestrate/autonomy-levels.md` (#174). Resolve a routine-gate disposition with
`<skill-base-dir>/../../scripts/autonomy-resolve.sh gate routine --level {N}`
(→ `disposition=auto|human`, #190) rather than re-deriving the L3–L4 cutoff —
substituting `<skill-base-dir>` per `next-issue/worktree-safe-recipes.md`, since
ship runs worktree-isolated when chained in-turn (#815).
`autonomy_level` is the sole control — the old binary `autonomous`/`plan_gated`
mirrors and the `--autonomous`/`--auto`/`NEXT_ISSUE_AUTONOMOUS` aliases were
removed in #215 (and GitHub's `gh pr merge --auto` / the harness's
`--permission-mode auto` are unrelated).

<!-- contract: ship-autonomy-level-gates -->

| Level | Shipping mode (Step 3) | CI | Merge (Step 4) |
| ----- | ---------------------- | -- | -------------- |
| **L3–L4** | no prompt — always Branch + PR (Option 1) | always wait + auto-fix | **auto-merge** squash (+`--delete-branch` unless a worktree holds the branch), prune remote, then prune |
| **L1–L2** | prompt for mode | wait | **stop** at green+clean with the completion summary — human merges |

<!-- contract: ship-merge-invariant -->

**The merge invariant (all levels, including L4).** Never merge unless CI is green
**and** the PR review loop terminated clean. If either fails and cannot be
mechanically resolved, it is a **dead-end** (see `orchestrate/autonomy-levels.md`
§ dead-end rule and #181): park the PR, emit the dead-end summary, and wait for a
human — **even at L4**. The level decides whether merging needs a human keystroke,
never whether an un-green or un-reviewed PR may merge.

<!-- contract: end-ship-merge-invariant -->

A ship-issue dead-end is a **kept human gate**, so under an orchestrator it is
**brokerable** exactly like a mid-flight escalation (#227): mint a gate-id,
embed it in the `DEAD-END:` feed message, and wait on the inbox `consume` loop
rather than a per-golem attach — the operator answers park/redirect/abandon
centrally. See `next-issue/escalation-protocol.md` § *The dead-end exception* for
the shared mint-embed-consume mechanism; `golem-attach` stays the fallback.

**Standing rule — never time out a human gate.** Every gate this skill keeps for
a human — the shipping-mode prompt (Step 3), the L1–L2 stop-for-human-merge gate,
and a dead-end at any level — **waits indefinitely; never lapse-and-default
because the operator stepped away.** Full rule: `orchestrate/autonomy-levels.md`
§ *Standing rule: wait indefinitely at a human gate*.

## Golem Execution Model & Environment Variables

**Companion file**: `ship-protocol.md` in this skill directory carries (1) the
**Golem Execution Model** — a golem running this skill is an OS **process**, never
a Workflow subagent, because this skill's review harness already owns the one
permitted Workflow nesting level (§ *Golem Execution Model* there); (1b) the
**Workflow authority** rule (§ *Workflow authority* there, #637); and (2) the
full **Environment Variables** contract: `PRE_REVIEW_STRICT` / `REVIEW_MAX_CYCLES`
/ `REVIEW_MAX_ATTEMPTS` / `REVIEW_CONVERGENCE_SURFACE_RATIO` (review gating;
`REVIEW_MAX_CYCLES` is the hard ceiling on cycles that produced a review and the
convergence predicate is the stop signal, since #596; `REVIEW_MAX_ATTEMPTS`
bounds attempts so a crashed cycle can stop charging the cycle cap without the
loop becoming unbounded, since #616) and the `LIBRARIAN_CI_*` / `LIBRARIAN_WORKFLOW_*`
families (CI-wait + workflow-wall threshold/extensions, infra-flake triage). Load
it before relying on any of these toggles.

**Workflow authority — the review harness call is already opted in (#637).** The
`Workflow` tool requires the user to have explicitly opted into multi-agent
orchestration, and one of its own documented opt-in cases is *"the user invoked a
skill or slash command whose instructions tell you to call Workflow."*
`/workflow:ship-issue` **is** that command, so every harness invocation this
skill mandates (Step 3.5's adversarial pre-PR review, Step 4's multi-cycle loop,
`ci-fixer`) is authorized by the operator's invocation — **settled, not
re-derived per run.** Lacking permission is therefore never a reason to skip the
review or to replace it with a hand-rolled one; see `ship-protocol.md`
§ *Workflow authority* for the full rule and the graceful-degradation clauses it
governs.

## Step 1 — Read State

1. **Discover the current state file**:

   - List JSON state files (the singleton `next-issue-queue.json` is a
     dependency-queue record, NOT a per-issue state file — exclude it):
     `ls .claude/memory/tmp/next-issue-*.json 2>/dev/null | command grep -v '/next-issue-queue\.json$'`
   - **If multiple files exist**: list them and ask which issue to ship
   - **If exactly one file**: use it
   - **If none exist**: do NOT dead-end immediately — first attempt
     **state reconstruction** from the working context (see below). Only if
     reconstruction fails is there nothing to ship; then stop and tell the user
     to run `/workflow:next-issue` first.

   **State reconstruction (missing-state-file fallback).** The Phase 1/2 state
   write can legitimately be absent — an older `/workflow:next-issue` run that entered plan
   mode before the write ordering was fixed (issue #409), or a `/clear` that
   dropped an in-context-only state. When the glob finds no `next-issue-*.json`,
   reconstruct a minimal state from the branch + issue before giving up: parse the
   issue number from the branch, confirm the issue is `OPEN` **and**
   `status/in-progress`, then write the schema-required fields (defaulting
   `autonomy_level: 1`, `phase: "implement"`) and continue as if the file had been
   found. A non-issue branch or a closed / not-in-progress issue falls through to
   the "nothing to ship" stop, never a hard error. Full procedure (the per-step
   bash and the exact fields): `ship-protocol.md` § *State reconstruction
   (missing-state-file fallback)*.

1. Extract: `issue` (number), `title`, `platform` (`github` or `gitlab`),
   `branch` (if set), `autonomy_level` (integer 1–4 — the sole autonomy field;
   feeds the level model above), and `plan_comment_url` (if present).

   **Resolve the run's level** by calling the resolver (issue #190) — the same
   authoritative implementation `/workflow:next-issue` uses — rather than validating the
   level by hand:

   ```bash
   # {STATE_LEVEL} = the state file's autonomy_level ("" if absent).
   <skill-base-dir>/../../scripts/autonomy-resolve.sh read \
       --state-level {STATE_LEVEL}
   # -> PRINTS autonomy_level (1-4)
   ```

   **Run it bare and read the printed value — never `eval "$(...)"` (#815);**
   chained in-turn at L3–L4 this runs worktree-isolated, where a refused
   substitution silently yields L1. Substitution rule:
   `next-issue/worktree-safe-recipes.md`.

   The resolver applies the rule (see
   `next-issue/schemas/next-issue-state.schema.json`): a present `autonomy_level`
   wins (validated 1–4); absent → **L1**.

   The level decides every gate below: **L1–L2** keep human gates (stop for a
   human at shipping mode and at merge), **L3–L4** auto-pass the routine gates
   (push, PR-open, merge-on-green+clean, prune). The `severity/critical` cap
   (issue L3 max) is applied by `/workflow:next-issue` when it writes `autonomy_level`, so
   ship trusts the stored level as-is.

   > **Dependency queue:** if `.claude/memory/tmp/next-issue-queue.json` exists
   > and the issue being shipped is that queue's `active` entry, **leave the
   > queue file in place** — do NOT delete or mutate it here. The next
   > `/workflow:next-issue` run advances the queue on resume (it re-reads the queue,
   > drops the now-closed entry, and recomputes `active` — see
   > `next-issue/dependency-queue.md` § Dependency Queue). Shipping only deletes the
   > per-issue `next-issue-{N}.json`, never the queue file.

   (If no state file is found, stop and tell the user: *"No in-progress issue
   found. Run `/workflow:next-issue` first to select and plan an issue."*)

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
1. **Pre-review gates** — run `pre-review-gates.sh` over the diff, passing the
   `git diff --numstat` sidecar as its second argument so the **review-lens
   sizing** rows stay growth-graded (#695); advisory by default, HIGH-certainty
   findings block Option 1 under `PRE_REVIEW_STRICT=true`.
1. **Adversarial pre-PR review** (all modes) — run the `workflow.js` harness
   (`phase: "pre-pr"`) on the committed diff regardless of shipping mode; fix
   `blocking` findings in a loop that stops on the convergence predicate and is
   capped by `REVIEW_MAX_CYCLES` (#596), collect `deferrable`
   for filing after delivery. Option 2 runs it **before the push to main** (the
   three-dot diff empties post-push).

   **The `args` keys, so you never reconstruct them:** `phase`, `cycle`,
   `maxCycles`, `files`, `diff`, `issue`, `preScan`, `conventionsDigest`, plus
   opt-in `tokenCeiling` (omit unless `REVIEW_TOKEN_CEILING` is set).
   Unknown top-level keys are rejected outright (#597), and **no key has a
   path/file variant** — `diff` and `preScan` go inline whatever their size.
   Full block with per-key semantics: `pre-ship-validation.md` Step 3.5 b.

Each check degrades gracefully (a missing scanner/harness is skipped with a note,
never a hard-fail) and never prompts at L3–L4. See `pre-ship-validation.md`
for the per-check commands, tables, and per-level rules.

## Step 4 — Execute

### Option 1 — Branch + PR

**Companion file**: `execute-protocol.md` § *Option 1 — Branch + PR: opening the
PR* carries the mechanical sequence — ensure a feature branch (naming convention
in `next-issue/state-format.md`), stage and commit with `Closes #{N}` in the
body, **verify** the trailer landed, push, and open the PR. Load it now; the
same file continues straight into the post-PR half below.

1. **After the PR is open — Companion file**: the rest of Option 1 lives in
   `execute-protocol.md` § *Option 1 — Branch + PR: after the PR is open* — load
   it now. It carries, in order: **monitor CI + multi-cycle review loop + file
   deferred findings** (full protocol in `ci-review-protocol.md`; always runs
   before any merge) → the **level-aware merge gate** (the merge invariant is
   checked first at every level incl. L4 — a not-green-and-clean loop is a
   **dead-end** that parks the PR and waits for a human; with the invariant
   satisfied, **L3–L4** auto-merge squash then prune inline —
   **worktree-aware**: `--delete-branch` is withheld when **any worktree holds
   the PR branch** (not merely when the session sits in one, #653); the PR's real
   state is then read via `gh pr view --json state`, and **only on `MERGED`** is
   the remote branch pruned via `git push origin --delete` and the result
   **verified** rather than inferred from an exit code (a non-`MERGED` state is a
   dead-end that touches no branch); the local `checkout main` is skipped in a
   linked worktree — **L1–L2** stop for a human
   merge) → **clear the in-flight labels** (remove `status/in-progress` **and**
   `status/pr-pending`; the merge has landed, so adding pr-pending here would
   stamp a closing issue, #654) → **comment**, **checkout main** (skipped in a
   linked worktree), **delete state file**, **show the PR URL** → the **L2
   completion summary** block. Squash by default: single-issue PRs keep history
   linear.

### Options 2 & 3

**Companion file**: `execute-protocol.md` also carries **Option 2 — Commit to
main + push** and **Option 3 — Commit only (no push)** in full. Both commit with
`Closes #{N}` in the body; Option 2 pushes to `main` (auto-closes the issue) and
removes `status/in-progress`; Option 3 does not push, labels
`status/commit-pending`, and comments the commit SHA (agent-mode vs normal-mode
wording). Both delete the state file. Load it when the chosen mode is 2 or 3.

## Step 5 — Context Reset & Continue

**Companion file**: `ship-protocol.md` § *Step 5 — Context Reset & Continue*
carries this step. In brief: **L2–L4 skip it** (an L3–L4 run already merged and
exited; an L2 run already emitted its completion summary and stops for a human
merge). Only an **L1** interactive run reaches the loop-back — after shipping,
tell the user the issue is shipped and `AskUserQuestion` **Pick next issue**
(invoke `/workflow:next-issue`) vs **Stop**. On an `^agent` branch, commit-only (Option 3)
persists across invocations without prompting.
