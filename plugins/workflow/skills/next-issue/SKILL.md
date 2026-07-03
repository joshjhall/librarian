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
`--autonomous` (deprecated alias `--auto`, or `NEXT_ISSUE_AUTONOMOUS=1`) is an
**alias for L4**; absence of any signal is the interactive default (an **L1
disposition** — every gate asks). `severity/critical` issues are **capped at L3**
(an L4 request reduces to L3), so a critical issue always keeps its plan gate.
See `## Autonomous Mode` below.

The level splits into **two** dispositions (see `## Autonomous Mode` for the full
rule):

- **Gate-skipping** — at **L3–L4**, routine gates take their documented default
  with no `AskUserQuestion`; at L1–L2 they stay human.
- **Plan-skipping** — the plan checkpoint (`EnterPlanMode`/`ExitPlanMode`) is an
  **escalation gate**: auto-passed at **L4 only**, kept (human approval) at
  L1–L3. Because `severity/critical` caps at L3, a critical issue always keeps
  the plan gate. This is **level-driven, not effort-driven** — an L4 run skips
  the plan even on an `effort/medium` issue. The legacy `--plan-gate` /
  `--force-auto` overrides still parse and map onto the level; neither can lift
  the critical cap (#179 removed the old env-var critical-bypass that once did).

Adding the `--ship` flag (alias `--now`) — `/next-issue 123 --ship` — is a
fast-path for **small work**: after plan approval and implementation it invokes
`/ship-issue` directly instead of suggesting a `/clear` + manual resume.
`--ship` is **not** autonomy — it keeps the interactive plan-approval gate
(`EnterPlanMode`/`ExitPlanMode`) and leaves `autonomous` false; it only removes
the context-reset ceremony between implement and ship. It is honored **only for
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
as the only backstop. It is orthogonal to `--force-auto` (which governs
plan-skipping, not dependencies) — do not conflate the two.

**IMPORTANT — Plan mode**: At an **L1 disposition** (no level chosen — the
interactive default), use the `EnterPlanMode` tool immediately at the start of
every `/next-issue` invocation (before any other work). Phases 0-2 are planning
phases that only need read-only tools and Bash. After Phase 2 plan approval, use
`ExitPlanMode` to begin implementation. When a **level** is set the plan-mode
call is **deferred to Phase 2** (the `severity/critical` label that can cap L4→L3
is not known until Phase 1): an **L4** run (non-critical) never calls
`EnterPlanMode`/`ExitPlanMode` at all — the plan gate is auto-passed — while an
**L1–L3** run (including any capped critical) calls both in Phase 2 and pauses at
plan approval. See `## Autonomous Mode` below.

## Autonomous Mode

**Companion file**: the full rule lives in `autonomous-mode.md` in this skill
directory — load it to decide the run's level and apply it. It carries the level
selection + aliases, the per-gate disposition table, the plan-gate rule, the
legacy `--plan-gate` / `--force-auto` overrides (superseded by the level; removed
in #179), and the shipping handoff. The authoritative model is
`orchestrate/autonomy-levels.md` (#174). The summary below is the operational
gist.

The run's **autonomy level** (int 1–4) is set by `--level {1,2,3,4}`; by
`--autonomous` / deprecated `--auto` / `NEXT_ISSUE_AUTONOMOUS=1` (each an **alias
for L4**); or, absent any signal, defaults to an **L1 disposition** (every gate
asks). A `severity/critical` issue **caps at L3**. The level is persisted as
`autonomy_level`, with derived `autonomous` (= L4) and `plan_gated` mirrors
written for the not-yet-level-aware `/ship-issue` (dropped by #177); a legacy
`autonomous: true` file with no `autonomy_level` reads as **L4**. The level
splits into **two dispositions**:

- **Gate-skipping (L3–L4).** At L3–L4, do NOT call `AskUserQuestion` for a
  routine gate — issue acceptance, branch-freshness, drift, shipping mode, CI
  waits take their documented default. At L1–L2 these stay human.
- **Plan-skipping (L4 only).** The plan checkpoint
  (`EnterPlanMode`/`ExitPlanMode`) is an escalation gate: auto-passed at **L4**
  (`plan_gated: false`), kept at **L1–L3** (`plan_gated: true`) where it builds
  the plan and STOPS at `ExitPlanMode` for human approval, then continues at the
  run's level through implement → review → push/PR. Because critical caps at L3,
  a critical issue always keeps the gate. This is level-driven, not
  effort-driven. Legacy overrides still map onto the level; the old env-var
  critical-bypass has been **removed** (the cap subsumes it — #179).

After implementation and testing complete, an **L3–L4** run **invokes
`/ship-issue` in the same turn** (call the `Skill` tool) — never end the turn
with only a "next step" note. Persist `"autonomy_level"` (plus the derived
`"autonomous"` / `"plan_gated"` mirrors) to the state file so ship and any
post-`/clear` resume inherit the level.

At an **L1 disposition** (no level chosen), behavior is unchanged — every
interactive prompt and plan-mode step below runs verbatim as the default.

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

1. **Enter plan mode** (call `EnterPlanMode` tool). At an **L1 disposition** (no
   level chosen — the interactive default), call it here immediately. When a
   **level** is set, do NOT call it here — **defer** the decision: the
   `severity/critical` label that can cap an L4 request down to L3 (keeping the
   plan gate) is not fetched until Phase 1, and entering plan mode now would trap
   an L4 run in plan mode (it never calls `ExitPlanMode`, so its write/edit tools
   would stay blocked). The plan-mode call is made in Phase 2 once the effective
   level is known: an **L1–L3** run (including a capped critical) calls
   `EnterPlanMode` there (then `ExitPlanMode` for approval); an **L4**
   (non-critical) run never enters plan mode at all. See `## Autonomous Mode`.

1. **Legacy migration** — run in order:

   a. If `.claude/memory/tmp/next-issue-state.md` exists (legacy singleton),
   read its `issue:` field, rename to `.claude/memory/tmp/next-issue-{N}.md`

   b. If any `.claude/memory/tmp/next-issue-*.md` files exist (YAML format),
   migrate each to `.json`: read the YAML frontmatter fields, write a new
   `.json` file with those fields plus `"version": 2`, delete the `.md` file

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

**Plan-gated resume sub-case.** When the resumed state file has
`"plan_gated": true`, `"phase": "plan"`, and a populated `checkpoint`
(`completed_phase: "plan"`, `files_planned`, `key_decisions`), the plan was
already built and the run paused at the human plan-approval gate before a prior
context loss. Do **NOT** re-enter Phase 2 and re-run exploration from scratch
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
   a different one) — at **L3–L4** (issue acceptance is a routine gate), accept
   the selected issue automatically (no prompt)

1. Assign the issue to yourself

1. **Label the issue** `status/in-progress`:

   - GitHub: `gh issue edit {N} --add-label "status/in-progress"`
   - GitLab: `glab issue update {N} --label "status/in-progress"`

1. **Write state file** to `.claude/memory/tmp/next-issue-{N}.json`:

   ```json
   {
     "version": 2,
     "issue": {N},
     "title": "{title}",
     "phase": "select",
     "started": "{YYYY-MM-DD}",
     "platform": "{github|gitlab}",
     "autonomy_level": {1-4},
     "autonomous": {true|false},
     "plan_gated": {true|false}
   }
   ```

   Set `"autonomy_level"` from level selection (see `## Autonomous Mode`):
   `--level {1,2,3,4}`; else `--autonomous`/`--auto`/`NEXT_ISSUE_AUTONOMOUS=1` →
   `4`; else `1` (the interactive default) unless an orchestrator chose a level
   at setup. Then apply the **critical cap** to the just-fetched labels: if the
   issue is `severity/critical` and the selected level is `4`, record `3`. Write
   the two derived back-compat mirrors: `"autonomous"` = `(autonomy_level == 4)`;
   `"plan_gated"` = `true` when the plan gate is **kept** — i.e. `autonomy_level
   <= 3` (which includes every capped critical) — and `false` at L4. The legacy
   `--plan-gate` override forces `plan_gated: true` (keep the gate); `--force-auto`
   maps to L4 (subject to the cap). These no longer depend on effort labels.

## Phase 2 — Plan

1. Read the full issue body

1. Explore the relevant code areas (use Grep/Glob/Read)

1. **Assess scope** from labels (note the effort tier — the final step uses it
   to decide whether `--ship` applies):

   - `effort/trivial` or `effort/small`: Write a brief inline plan (3-5
     bullets) directly in the conversation. These tiers are `--ship`-eligible.
   - `effort/medium` or `effort/large`: Load `development-workflow`
     phase-details.md and create a thorough plan following its Phase 1-3
     structure. These tiers are NOT `--ship`-eligible (the `/clear` boundary is
     preserved).

1. **MANDATORY final step** — always append this verbatim as the last step
   of the plan:

   > **After all implementation and testing is complete**, invoke `/ship-issue`
   > to commit, deliver, and close the issue.

   If in agent worktree mode, also append:

   > Agent worktree mode: `/ship-issue` will auto-select commit-only
   > (Option 3). The orchestrator handles PR creation and delivery.

1. **Update state file** — write the full JSON with `phase: "plan"`, a
   one-line `plan` summary, and the `checkpoint` object:

   ```json
   {
     "version": 2,
     "issue": {N},
     "title": "{title}",
     "phase": "plan",
     "branch": "{branch}",
     "plan": "{one-line summary}",
     "started": "{date}",
     "platform": "{platform}",
     "autonomy_level": {1-4},
     "autonomous": {true|false},
     "plan_gated": {true|false},
     "checkpoint": {
       "completed_phase": "plan",
       "key_decisions": ["{non-obvious choice 1}", "{non-obvious choice 2}"],
       "files_modified": [],
       "files_planned": ["{file1}", "{file2}"],
       "warnings": ["{anything the implementation phase should know}"],
       "next_action": "Begin implementation"
     }
   }
   ```

   Carry `"autonomy_level"` (and its derived `"autonomous"` / `"plan_gated"`
   mirrors) forward from Phase 1 unchanged — the level is fixed at selection,
   including the critical cap. Note a `--ship`/`--now` run is **L1** (it is not
   autonomy; it only skips the `/clear`, keeping the interactive plan gate). The
   template above deliberately omits `"plan_comment_url"`: add that field **only**
   on the **L4 (plan-auto-passed)** path (see the autonomous planning path below),
   where the plan is posted as an issue comment. An **L1–L3** run uses
   `EnterPlanMode`/`ExitPlanMode` instead and must NOT add it.

1. **Autonomous planning path** — branches on the plan gate (`"plan_gated"`
   from Phase 1 / `## Autonomous Mode`):

   > **Note (dependency queue):** if Phase 1 built a dependency queue for an
   > explicitly-named blocked issue, the `active` issue selected there — a
   > dependency, not the named target — is what this autonomous run plans,
   > implements, and ships (its own PR). The run works exactly **one** queue
   > entry; the queue file persists for the next cycle to advance toward the
   > target (see `state-format.md` § Dependency Queue → "Autonomous
   > interaction"). Do NOT try to auto-advance the whole chain in one turn.

   - **L4 run (`plan_gated: false`, non-critical)** — do NOT enter plan mode.
     After exploring and forming the plan: (1) write the plan to the state file
     exactly as above, AND (2) post the plan as an issue comment for
     traceability —

     ```bash
     gh issue comment {N} --body "..."      # GitHub
     glab issue note {N} --message "..."    # GitLab
     ```

     Capture the returned comment URL and record it in the state file as
     `"plan_comment_url"`. Then proceed DIRECTLY to implementation — no
     `ExitPlanMode`, no approval gate. This path SKIPS both the "Exit plan mode"
     and "Suggest context reset" steps below.

   - **L1–L3 run (`plan_gated: true`, includes a capped critical)** — do NOT
     take the comment-only shortcut. Call **`EnterPlanMode`** now (it was
     deferred in Phase 0), build the plan, then call **`ExitPlanMode`** (next
     step) to present it for human approval. A golem is now BLOCKED
     awaiting input (surfaced by `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`); the human attaches via
     `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`, refines the plan in-session, and approves.
     **After approval**, the run continues at its level: at **L3** skip the
     "Suggest context reset" step, proceed directly through implementation and
     testing, then invoke `/ship-issue` in-turn exactly as the shipping handoff
     below; at **L1–L2** the routine gates (shipping mode, push, PR) remain
     human, so follow the normal non-autonomous hand-off. Posting a plan issue
     comment is optional here (the plan is already visible in the approval
     prompt); skip `"plan_comment_url"`.

   **Then, once implementation and testing are complete — for an L1–L3 run that
   kept the plan gate, that means only after the `ExitPlanMode` approval below
   AND the subsequent "Implement" step both finish — an L3–L4 run invokes the
   `/ship-issue` skill in this same turn** (call the `Skill` tool with
   `ship-issue`). Do NOT invoke ship before `ExitPlanMode` approval (when the
   gate was kept) or before the work exists. Do NOT stop after implementation to
   *suggest* shipping, and do NOT merely print a "next step: /ship-issue" line —
   actually invoke it. This is the whole point of L3–L4: a single
   `claude '/next-issue <N> --autonomous'` (i.e. `--level 4`) prompt must reach a
   pushed PR + labeled issue without a second manual command. Ending the turn
   after `/next-issue` leaves the work uncommitted with no PR. (As a
   belt-and-suspenders for a premature turn-exit, the orchestrate golem launch
   also chains a second `; claude '/ship-issue --autonomous'` prompt — see the
   orchestrate skill — but the in-turn invocation here is the primary path and
   must not be skipped.) An **L1–L2** run instead stops for the human at the
   routine ship gates — follow the default hand-off below.

1. **Exit plan mode** (call `ExitPlanMode` tool) — this presents the plan to
   the user for approval before implementation begins. Skipped only on the
   **L4 (non-critical)** path; an **L1–L3** run (including a capped critical)
   DOES call `ExitPlanMode` here and waits for human approval (see the autonomous
   planning path above).

1. **Implement** — after plan approval, carry out the plan: make the changes
   and run the tests. The two steps below fire only **once implementation and
   testing are complete** — do NOT invoke `/ship-issue` or suggest a
   `/clear` before the work exists.

   **Mid-flight escalation gate.** If, while implementing or testing, you reach a
   decision that is **not mechanical** — competing architectural approaches, a
   directional choice the plan left open, or a wall with more than one viable
   escape — this is an **escalation gate**, not something to silently decide.
   Load `escalation-protocol.md` and follow it: assemble the payload (decision,
   options + tradeoffs, recommendation), then dispatch by level — **L1–L3 block
   and wait indefinitely** for a human (surfaced as an `escalation` on the feed +
   an issue comment; inline for a lone `/next-issue`), **L4 auto-selects the
   recommendation** and continues, **unless it is a dead-end** (no safe option /
   would violate the merge invariant), which blocks at every level including L4.
   Err toward escalating when unsure. This is distinct from the plan gate above,
   which is handled structurally by `ExitPlanMode`.

1. **Hand off — suggest a context reset, OR take the `--ship` fast-path.**
   Reached only after implementation and testing complete (previous step).
   (Skipped on the **L3–L4** paths — they ship in-turn via the autonomous
   planning path above, never via a `/clear`.) Choose by flag + effort:

   - **`--ship` (or `--now`) set AND effort is `trivial`/`small`**: do NOT
     suggest a `/clear`. Invoke `/ship-issue` directly to deliver in this
     same context. The plan was still approved interactively above, so the
     human remains in the loop; only the reset ceremony is skipped. The run stays
     **L1** (`autonomy_level: 1`, `autonomous: false`) — the ship run will still
     prompt for shipping mode etc.

   - **`--ship`/`--now` set BUT effort is `medium`/`large` (or there is no
     `effort/*` label)**: emit a one-line note — "`--ship` skipped for
     {effort/medium,effort/large,no effort label} — preserving the `/clear`
     boundary" — then fall through to the default suggestion below.

   - **Default (no `--ship`/`--now`)** — tell the user:

     > Planning phase complete. Context can be safely cleared — state saved to
     > `.claude/memory/tmp/next-issue-{N}.json`. Run `/clear` then `/next-issue`
     > to resume from implementation.

     This is advisory — continue normally if the user declines.

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
