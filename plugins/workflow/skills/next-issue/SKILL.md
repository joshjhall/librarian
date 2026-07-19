---
description: Issue-driven development workflow that picks the next issue by severity/effort priority and creates an implementation plan. Use when working through a backlog, picking up the next issue, or resuming in-progress work. After implementation, use /ship-issue to deliver.
---

# Next Issue

**Companion file**: See `state-format.md` in this skill directory for the state
file schema (JSON), priority ordering commands, branch naming convention,
checkpoint structure, and reset points. Load it at the start of every
invocation. See `escalation-protocol.md` when a **mid-flight** architectural or
directional decision arises during implementation (the escalation gate — human
at L1–L3, auto at L4).

Accepts an optional issue number argument: `/next-issue 123` skips priority
selection and targets that specific issue.

Adding the `--level {1,2,3,4}` flag — `/next-issue 123 --level 3` — sets the
run's **autonomy level** (L1–L4) per the contract in
`orchestrate/autonomy-levels.md`. The level is the single dial that decides how
each gate is dispatched: routine gates (push, PR-open, merge-on-green, prune) are
auto-passed at L3–L4 and human at L1–L2; escalation gates (plan approval, a
mid-flight fork, a wall) are auto-passed at L4 only and human at L1–L3.
`--level {1,2,3,4}` is the sole autonomy dial; absence of any signal is the
interactive default (an **L1 disposition** — every gate asks). `severity/critical`
issues are **capped at L3** (an L4 request reduces to L3), so a critical issue
always keeps its plan gate. See `## Autonomy Levels` below.

The level splits into **two** dispositions (see `## Autonomy Levels` for the full
rule):

- **Gate-skipping** — at **L3–L4**, routine gates take their documented default
  with no `AskUserQuestion`; at L1–L2 they stay human.
- **Plan-skipping** — the plan checkpoint (`EnterPlanMode`/`ExitPlanMode`) is an
  **escalation gate**: auto-passed at **L4 only**, kept (human approval) at
  L1–L3. Because `severity/critical` caps at L3, a critical issue always keeps
  the plan gate. This is **level-driven, not effort-driven** — an L4 run skips
  the plan even on an `effort/medium` issue. There is no override that keeps the
  plan gate on an L4 run: "L4 but keep the plan gate" is simply **L3** (the old
  `--plan-gate` / `--force-auto` overrides were removed in #215).

Adding the `--ship` flag (alias `--now`) — `/next-issue 123 --ship` — is a
fast-path for **small work**: after plan approval and implementation it invokes
`/ship-issue` directly instead of suggesting a `/clear` + manual resume.
`--ship` is **not** autonomy — it keeps the interactive plan-approval gate
(`EnterPlanMode`/`ExitPlanMode`) and never selects L4; it only removes the
context-reset ceremony between implement and ship. It is honored **only for
`effort/trivial` and `effort/small`** issues; for `effort/medium`/`large` (or
no effort label) it is ignored with a one-line note, preserving the `/clear`
boundary that keeps planning context out of the longer implement/review budget.
See `## Pipeline` and the conditional final step of Phase 2.

Adding the `--force-target` flag (alias `--no-deps`) — `/next-issue 5
--force-target` — changes how an **explicitly-named** issue with open
dependencies is handled. By default, naming an issue whose declared
dependencies are still open **queues those dependencies first** and works them
toward the named target (see Phase 1 below and `state-format.md` §
Dependency Queue). `--force-target` restores the legacy warn-and-proceed: it
plans the named issue directly, ignoring its open blockers, with the plan gate
as the only backstop. It governs dependency handling only — orthogonal to the
`--level` autonomy dial.

**IMPORTANT — Plan mode is entered in Phase 2, never Phase 0**: at **every**
disposition, including an **L1** interactive default, `EnterPlanMode` is called
in **Phase 2** — *after* Phase 0's resume check and *after* Phase 1 has
selected, assigned, labeled, and **written the hand-off state file**. It is
**not** called at the start of the invocation. This ordering is load-bearing:
plan mode permits only edits to the plan file, so the Phase 1 mutations (`gh`
assign/label and the `Write` of `.claude/memory/tmp/next-issue-{N}.json`) and
the Phase 2 `phase: "plan"` state write **must complete before `EnterPlanMode`**
— otherwise plan mode silently blocks them, the run implements without ever
looping back, and the hand-off record `/ship-issue` reads never lands
(issue #409). After Phase 2 plan approval, use `ExitPlanMode` to begin
implementation.
An **L4** run (non-critical) never calls `EnterPlanMode`/`ExitPlanMode` at all —
the plan gate is auto-passed — while an **L1–L3** run (including any capped
critical, and the L1 default) calls both in Phase 2 and pauses at plan approval.
The `severity/critical` label that can cap an L4 request down to L3 is not known
until Phase 1, a further reason the plan-mode call waits for Phase 2. See
`## Autonomy Levels` below.

## Autonomy Levels

**Companion file**: the full rule lives in `autonomy.md` in this skill
directory — load it to decide the run's level and apply it. It carries the level
selection (`--level {1,2,3,4}` is the sole dial; #215 removed the old aliases and
overrides), the per-gate disposition table, the plan-gate rule, and the shipping
handoff. The authoritative model is `orchestrate/autonomy-levels.md` (#174),
implemented by the resolver `${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh`
(#190) — **call it** to compute the level and per-gate disposition rather than
re-deriving them here. The summary below is the operational gist.

The run's **autonomy level** (int 1–4) is set by `--level {1,2,3,4}` (the sole
autonomy dial); or, absent any signal, defaults to an **L1 disposition** (every
gate asks). A `severity/critical` issue **caps at L3**. The level is persisted
as `autonomy_level` (the only autonomy field in the state file); the run-time
`plan_gated` / `perm_mode` dispositions are computed from it by the resolver, not
stored. The level splits into **two dispositions**:

- **Gate-skipping (L3–L4).** At L3–L4, do NOT call `AskUserQuestion` for a
  routine gate — issue acceptance, branch-freshness, drift, shipping mode, CI
  waits take their documented default. At L1–L2 these stay human.
- **Plan-skipping (L4 only).** The plan checkpoint
  (`EnterPlanMode`/`ExitPlanMode`) is an escalation gate: auto-passed at **L4**
  (`plan_gated: false`), kept at **L1–L3** (`plan_gated: true`) where it builds
  the plan and STOPS at `ExitPlanMode` for human approval, then continues at the
  run's level through implement → review → push/PR. Because critical caps at L3,
  a critical issue always keeps the gate. This is level-driven, not
  effort-driven. There is no override that lifts the plan gate on an L1–L3 run —
  "L4 but keep the plan gate" is simply **L3** (#215; the old
  `--plan-gate`/`--force-auto` overrides were removed).

After implementation and testing complete, an **L3–L4** run **invokes
`/ship-issue` in the same turn** (call the `Skill` tool) — never end the turn
with only a "next step" note. Persist `"autonomy_level"` to the state file so
ship and any post-`/clear` resume inherit the level.

At an **L1 disposition** (no level chosen), behavior is unchanged — every
interactive prompt and plan-mode step below runs verbatim as the default.

**Standing rule — never time out a human gate.** Whenever a gate below is kept
for a human — every `AskUserQuestion`, the plan-approval checkpoint, the
mid-flight escalation gate, and a dead-end at any level — **wait indefinitely for
the answer; never lapse-and-default because the operator stepped away.** The only
thing that resolves a gate without a human is genuine level auto-passing (routine
at L3–L4, escalation at L4); a dead-end waits at every level, L4 included. See
`orchestrate/autonomy-levels.md` § *Standing rule: wait indefinitely at a human
gate*.

## Agent Worktree Mode

Before starting Phase 0, check if the current branch is an agent worktree:

```bash
CURRENT_BRANCH=$(git branch --show-current)
```

If `$CURRENT_BRANCH` matches `^agent` (e.g., `agent01`, `agent02`):

- Inform the user: "Running in agent worktree mode on branch `{branch}`.
  Commits will stay local — the orchestrator handles delivery."
- Note that `/ship-issue` will auto-select commit-only mode (Option 3)

**Note on state isolation**: In agent worktree mode, each worktree has its own
working directory, so per-issue state files are naturally isolated per agent.
No disambiguation is needed.

Proceed with Phase 0 as normal regardless of mode.

## Phase 0 — Resume Check

1. **Do NOT enter plan mode at the start of Phase 0 — at any level.** Phase 0
   (resume check) and Phase 1 (select, assign, label, and the state-file write)
   run with read-only tools, Bash, and the permitted `gh`/`Write` mutations; none
   of them needs plan mode, and entering it here would **trap those mutations**.
   (The one exception is the **plan-gated resume sub-case** below, where the state
   file already exists and no Phase 1 mutation is pending — that path *does* call
   `EnterPlanMode`/`ExitPlanMode` to re-present the stored plan.) Plan mode permits
   only edits to the plan file, so an `EnterPlanMode` at Phase 0 silently blocks
   the Phase 1 assign/label and the `Write` of
   `.claude/memory/tmp/next-issue-{N}.json` — the run then implements without
   looping back and the hand-off record `/ship-issue` reads is never created
   (issue #409). An **L4** run is doubly trapped: it never calls `ExitPlanMode`,
   so its write/edit tools would stay blocked for the whole run. The plan-mode
   call is therefore **deferred to Phase 2** for every disposition, once the
   effective level is known (the `severity/critical` label that can cap an L4
   request down to L3 is not fetched until Phase 1): an **L1–L3** run (including
   a capped critical and the L1 default) calls `EnterPlanMode` there — after the
   Phase 1/2 state writes have landed — then `ExitPlanMode` for approval; an
   **L4** (non-critical) run never enters plan mode at all. See
   `## Autonomy Levels`.

1. **Discover state files** (the singleton `next-issue-queue.json` is NOT a
   per-issue state file — exclude it from this glob):

   ```bash
   ls .claude/memory/tmp/next-issue-*.json 2>/dev/null \
     | command grep -v '/next-issue-queue\.json$'
   ```

1. **Dependency-queue resume** — if `.claude/memory/tmp/next-issue-queue.json`
   exists AND **no** explicit issue number was passed to this invocation, resume
   the queue toward its `target` before ordinary priority selection (see
   `state-format.md` § Dependency Queue → "Advancing / resuming the queue"):

   - Read the queue file. If its `active` issue is now **closed**, drop it from
     `remaining`.
   - Recompute `active` = the first entry in `remaining` that is open **and**
     unblocked, and target that issue for this run (skip Phase 1 priority
     selection, jump to the assign/label/state-write steps for `active`).
   - When `remaining` is just `target` and `target` is unblocked, target it,
     **delete** the queue file, and plan the target normally.
   - If nothing in `remaining` is actionable, surface a one-line status
     (`queue toward #{target} blocked — #{N} still open`) and stop.
   - An explicit `/next-issue {N}` **ignores** an existing queue (it is
     target-keyed, not a global override) — leave the queue file untouched and
     let Phase 1 handle `{N}` (which may build its own queue). If `{N}` equals
     the queue's `target`, Phase 1's dependency check will rebuild/refresh it.

1. **If multiple state files exist** (parallel agents scenario):

   - List all active issues with their number, title, phase, and branch
   - Ask: **Which issue to resume, or start fresh?**
   - If the user picks one: validate and resume that issue (see below)
   - If start fresh: proceed to Phase 1
   - **If at L3–L4 AND a specific issue number was provided** (resume-selection
     is a routine gate): do not prompt — target that issue's state
     non-interactively (resume its recorded phase if a valid open state file
     exists for it, else start fresh for that issue)

1. **If exactly one state file exists**: validate and offer to resume (see below)

1. **If no state files exist**: proceed to Phase 1

**Validation** (for a single state file or user-selected file):

- Read the `.json` file and extract `phase`, `issue`, `branch` fields
- Check if the issue is still open (`gh issue view {N} --json state` or
  `glab issue view {N}`)
- Check if the branch still exists (`git branch --list {branch}`)
- **If issue is closed or branch is missing**: the state is stale — silently
  delete the state file and proceed to Phase 1 (no need to ask the user)
- **If issue is still open and branch exists**: offer to resume:
  - Show the issue number, title, current phase, and branch
  - **If the state file has a `checkpoint` object**: show `key_decisions` and
    `next_action` so the user has context for the decision
  - Ask: **Resume this work or start fresh?**
  - If resume: jump to the recorded phase
  - If fresh: delete the state file and proceed to Phase 1
  - **If at L3–L4 AND a specific issue number was provided** (resume-selection
    is a routine gate): do not prompt — resume the recorded phase
    non-interactively (the state file is already validated open above);
    otherwise start fresh for that issue

**Plan-gated resume sub-case.** When the resumed state file has a plan-gated
level (`autonomy_level` 1–3, i.e. the plan gate is kept), `"phase": "plan"`, and
a populated `checkpoint` (`completed_phase: "plan"`, `files_planned`,
`key_decisions`), the plan was already built and the run paused at the human
plan-approval gate before a prior context loss. Do **NOT** re-enter Phase 2 and re-run exploration from scratch
(that discards the stored plan and burns the budget re-deriving it). Instead
jump straight to **re-presenting the stored plan for approval**: reconstruct the
plan from the checkpoint (`plan` one-liner + `files_planned` + `key_decisions` +
`warnings`), call `EnterPlanMode` then `ExitPlanMode` with that reconstructed
plan, and wait for approval. After approval, continue autonomously through
implement → test → `/ship-issue` exactly as the Phase 2 plan-gated path
does. Only fall back to a fresh Phase 2 exploration if the checkpoint is missing
or has no `files_planned` (nothing to re-present).

## Phase 1 — Select

1. **Detect platform** from `git remote -v`:

   - `github.com` or `ghe.` → GitHub (`gh`)
   - `gitlab.com` or `gitlab.` → GitLab (`glab`)

1. **If a specific issue number was provided**: fetch that issue directly and
   skip the priority query. Run the **blocked-by check** (see `state-format.md`
   § Blocked-by Exclusion) on it:

   - **No open blockers** → proceed to plan the named issue as normal.
   - **Open blockers, default behavior** → do **not** plan the named issue
     against them. Build a **dependency queue** and work the blockers first,
     toward the named target (full algorithm in `state-format.md` §
     Dependency Queue): resolve open blockers transitively, order them
     topologically (deepest first, target last), write
     `.claude/memory/tmp/next-issue-queue.json`, and select the **first open,
     unblocked** entry (usually a dependency) to plan **this** run instead of
     the named issue. Continue Phase 1's assign/label/state-write steps for that
     selected issue. A subsequent `/next-issue` advances the queue.
   - **Open blockers, `--force-target` (alias `--no-deps`)** → restore the
     legacy warn-and-proceed: emit a one-line `WARNING:` listing the open
     blockers and plan the named issue directly (the plan gate is the backstop).
   - **Dependency cycle detected** → do not loop; emit the `ERROR:` cycle line
     from `state-format.md` and stop, pointing at `--force-target` as the escape
     hatch.

   Never hard-block an explicitly-named issue — `--force-target` always plans it
   directly, and a cycle errors out with that same escape hatch.

1. **Otherwise query by priority** using the nested severity x effort loop
   (see `state-format.md` for exact commands). **Important**: all queries
   MUST exclude issues with `status/in-progress`, `status/pr-pending`,
   `status/commit-pending`, `status/on-hold`, or `status/blocked` labels — see
   `state-format.md` for the exact `--search` / post-filter syntax. For each
   candidate the query returns, also apply the **blocked-by exclusion**
   (`state-format.md` § Blocked-by Exclusion): parse `Blocked by #N` /
   `Depends on #N` / native `blockedBy` references and **skip** the candidate
   when any referenced blocker is still open, surfacing a one-line skip reason
   (`#572 skipped — blocked by open #467, #563`), then continue the priority
   walk. Pick the first open, unassigned, **unblocked** issue returned

1. **If no labeled issues found**: fall back to oldest open issue (also
   excluding `status/in-progress`, `status/pr-pending`,
   `status/commit-pending`, `status/on-hold`, and `status/blocked`, and applying
   the same per-candidate blocked-by exclusion)

   > **Pool refill (orchestrate Phase P):** when selection is driven by the
   > orchestrate worker pool rather than a plain `/next-issue`, layer the
   > **in-flight collision check** over this priority order — prefer the first
   > priority issue predicted disjoint from in-flight golems' files, holding the
   > slot if only colliding candidates remain. See `state-format.md` §
   > Collision-aware selection. A standalone `/next-issue` ignores this and picks
   > strictly by priority. The **blocked-by exclusion** is applied first in both
   > cases (it lives in the shared priority walk), so a blocked candidate is
   > skipped before the collision check ever sees it — dispatch and pool refill
   > inherit dependency-awareness automatically.

1. Show the selected issue to the user — title, labels, body excerpt

1. Ask: **Work on this issue?** (user can accept, skip to next, or pick
   a different one) — when the run's level is already known to be **L3–L4** (a
   `--level` flag or an orchestrator-passed level, i.e. issue acceptance is a
   routine gate that auto-passes), accept the selected issue automatically (no
   prompt).

1. **Choose the rules of engagement (autonomy level)** — for a **lone
   interactive `/next-issue`** whose level was NOT already fixed by a flag or an
   orchestrator, ask the operator now: an `AskUserQuestion` offering **L1–L4**,
   each with its one-line description (`orchestrate/autonomy-levels.md` § "The
   four levels"). The issue's `effort/*`/`severity/*` labels are known here, so
   apply the **critical cap**: a `severity/critical` issue offers **L1–L3 only**.
   **Wait indefinitely** for the answer — never lapse-and-default to L1 because
   the operator stepped away (`autonomy-levels.md` § *Standing rule*). Skip this
   question entirely when the level is already set (a `--level` flag or an
   orchestrator-passed level), and in a non-interactive context with no TTY fall
   back to the L1 disposition rather than hang. This resolves `autonomy_level` **before** the
   Phase 2 plan-mode decision, which depends on it. See `## Autonomy Levels` §
   Level selection.

1. Assign the issue to yourself

1. **Label the issue** `status/in-progress`:

   - GitHub: `gh issue edit {N} --add-label "status/in-progress"`
   - GitLab: `glab issue update {N} --label "status/in-progress"`

1. **Write state file** to `.claude/memory/tmp/next-issue-{N}.json`. This write —
   and the assign/label mutations above it — happen **now, in Phase 1, before
   Phase 2 enters plan mode**. It is the hand-off record `/ship-issue` reads
   (`phase` + `checkpoint`); if it were deferred into plan mode it would be
   silently blocked and never land (issue #409), so it MUST be on disk before
   `EnterPlanMode` is ever called.

   ```json
   {
     "version": 2,
     "issue": {N},
     "title": "{title}",
     "phase": "select",
     "started": "{YYYY-MM-DD}",
     "platform": "{github|gitlab}",
     "autonomy_level": {1-4}
   }
   ```

   Do **not** hand-derive the level — call the resolver, which computes level
   selection and the critical cap in one shot (see `## Autonomy Levels` and
   `autonomy.md` § Level selection):

   ```bash
   eval "$(${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh level \
       --from-args "$ARGS" --severity "$SEV" [--chosen-level "$CHOSEN"])"
   ```

   where `$ARGS` is this invocation's raw flag string (carrying any `--level N`),
   `$SEV` is the issue's severity label (`critical` or empty), and `$CHOSEN` is a
   level chosen at setup — an orchestrator-passed `--level` or the **operator's
   answer to the L1–L4 rules-of-engagement question** asked above (omit it for a
   pure-CLI run; with no signal at all the resolver returns the **L1** fallback).
   The call sets `autonomy_level`, `plan_gated`, `capped`, and `perm_mode`; write
   only `autonomy_level` into the state file (the `plan_gated`/`perm_mode`
   dispositions are consumed at runtime, not persisted). The `severity/critical`
   cap (L4 → L3, `capped=true`) is applied inside the resolver; none of this
   depends on effort labels.

## Phase 2 — Plan

**Companion file**: the full Phase 2 step sequence lives in `phase2-plan.md` in
this skill directory — **load it now** once a run reaches planning. It carries,
in order: read the issue body → explore the code → **assess scope** from effort
labels (trivial/small = inline plan + `--ship`-eligible; medium/large = load
`development-workflow` phase-details.md, not `--ship`-eligible) → append the
**MANDATORY** `/ship-issue` final step → **write the state file** with
`phase: "plan"` + `checkpoint` → the **autonomous planning path** that branches
on the plan gate (`plan_gated`, from Phase 1's resolver call): an **L4**
(`plan_gated: false`, non-critical) run posts the plan as an issue comment,
records `plan_comment_url`, and proceeds straight to implementation with no
approval gate; an **L1–L3** run (`plan_gated: true`, incl. a capped critical)
calls `EnterPlanMode` (deferred from Phase 0) then `ExitPlanMode` and **waits
indefinitely** for human approval → **implement** and test (with the mid-flight
escalation gate — load `escalation-protocol.md`) → then an **L3–L4** run invokes
`/ship-issue` **in this same turn**, while an **L1–L2** run hands off at the
routine ship gates. The final **hand-off** step chooses the `--ship` fast-path
(trivial/small only) vs the default `/clear` suggestion. Carry `autonomy_level`
forward unchanged from Phase 1; `--ship`/`--now` is not autonomy and never
selects L4. See `## Autonomy Levels` and `autonomy.md`.

## Platform Detection

Detect from the first `origin` remote URL:

| Pattern in remote URL     | Platform | CLI    |
| ------------------------- | -------- | ------ |
| `github.com` or `ghe.`    | GitHub   | `gh`   |
| `gitlab.com` or `gitlab.` | GitLab   | `glab` |

If neither matches, ask the user which platform to use.

## Pipeline

`/next-issue` and `/ship-issue` are two halves of one issue-driven
pipeline, deliberately kept as **separate** skills:

```text
/next-issue        →  (implement + test)  →  /ship-issue
  select + plan          your work             commit · PR/push · CI · review · label
       └──────────────── next-issue-{N}.json ────────────────┘
              (phase / checkpoint carry state across the gap)
```

The hand-off is the state file `.claude/memory/tmp/next-issue-{N}.json` (schema
in `state-format.md`): `/next-issue` writes `phase` + a `checkpoint` block;
`/ship-issue` reads them. This lets the implement step happen later, in a
fresh context, or across a `/clear` — the planning context does not have to
stay resident through implementation, review, and CI.

They are NOT merged into one command on purpose: the `/clear` boundary keeps
planning tokens out of the longer implement/review/CI budget; plan is
read-only/plan-mode while ship is all side effects (commit/push/PR), which are
easier to gate as distinct runs; and a failure stays attributable to one phase.

For genuinely small work that boundary is pure overhead — `/next-issue --ship`
(alias `--now`; see the flag docs above) collapses the hand-off in-context for
`effort/trivial`/`small` issues while still keeping the plan-approval gate.

## When to Use

- Working through a backlog of audit-created issues
- Picking up the next issue in a sprint
- Resuming work after a context window reset
- Systematic issue-by-issue cleanup

## When NOT to Use

- Exploratory work without a filed issue
- Issues requiring cross-repo coordination (handle manually)
- Emergency hotfixes (branch directly, skip priority selection)
- When you want to work on a specific PR rather than an issue
