---
description: Issue-driven development workflow that picks the next issue by severity/effort priority and creates an implementation plan. Use when working through a backlog, picking up the next issue, or resuming in-progress work. After implementation, use /next-issue-ship to deliver.
---

# Next Issue

**Companion file**: See `state-format.md` in this skill directory for the state
file schema (JSON), priority ordering commands, branch naming convention,
checkpoint structure, and reset points. Load it at the start of every
invocation.

Accepts an optional issue number argument: `/next-issue 123` skips priority
selection and targets that specific issue.

Adding the `--auto` flag — `/next-issue 123 --auto` (or setting the
`NEXT_ISSUE_AUTONOMOUS=1` environment variable) — runs the workflow
autonomously: every human gate resolves to its documented default and no
interactive tool is called — **except** the plan-approval checkpoint, which is
itself gated by the issue's effort/severity (see below). See `## Autonomous
Mode` below.

Autonomy has **two** independent sub-behaviors (see `## Autonomous Mode` for the
full rule):

- **Gate-skipping** — always on when autonomous: no `AskUserQuestion`, every
  human gate takes its documented default.
- **Plan-skipping** — conditional: the plan checkpoint
  (`EnterPlanMode`/`ExitPlanMode`) is skipped **only** for `effort/trivial` or
  `effort/small` issues that are **not** `severity/critical`. For
  `effort/medium`, `effort/large`, `severity/critical`, or an issue with no
  `effort/*` label, the autonomous run is **plan-gated**: it still builds the
  plan and STOPS at plan approval for a human, then continues autonomously
  through implement → review → push/PR. This mirrors the `--ship` effort gating
  below. Override per run with `--plan-gate` (force the checkpoint on a small
  issue) or `--force-auto` (force full plan-skipping on a medium+/critical one).

Adding the `--ship` flag (alias `--now`) — `/next-issue 123 --ship` — is a
fast-path for **small work**: after plan approval and implementation it invokes
`/next-issue-ship` directly instead of suggesting a `/clear` + manual resume.
`--ship` is **not** autonomy — it keeps the interactive plan-approval gate
(`EnterPlanMode`/`ExitPlanMode`) and leaves `autonomous` false; it only removes
the context-reset ceremony between implement and ship. It is honored **only for
`effort/trivial` and `effort/small`** issues; for `effort/medium`/`large` (or
no effort label) it is ignored with a one-line note, preserving the `/clear`
boundary that keeps planning context out of the longer implement/review budget.
See `## Pipeline` and the conditional final step of Phase 2.

**IMPORTANT — Plan mode**: In **non-autonomous** mode, use the `EnterPlanMode`
tool immediately at the start of every `/next-issue` invocation (before any
other work). Phases 0-2 are planning phases that only need read-only tools and
Bash. After Phase 2 plan approval, use `ExitPlanMode` to begin implementation.
In **autonomous** mode the plan-mode call is **deferred to Phase 2** (the
effort/severity labels that decide the plan gate are not known until Phase 1):
a **fully-autonomous** run — `effort/trivial` or `effort/small` and not
`severity/critical` — never calls `EnterPlanMode`/`ExitPlanMode` at all, while a
**plan-gated** autonomous run calls both in Phase 2 and pauses at plan approval.
See `## Autonomous Mode` below.

## Autonomous Mode

The run is **autonomous** when EITHER the literal token `--auto` appears in
the invocation arguments OR the environment variable `NEXT_ISSUE_AUTONOMOUS=1`
is set. Autonomy is strictly opt-in.

**Announce the mode when it is active via the env var.** When the run is
autonomous because `NEXT_ISSUE_AUTONOMOUS=1` is set (rather than an explicit
`--auto` on this invocation), print one visible line up front —
`Autonomous mode active (NEXT_ISSUE_AUTONOMOUS=1) — all human gates bypassed,
will proceed to a pushed PR.` — so an operator who didn't type `--auto` notices
that gates are off. The env var is persistent across invocations in a shell or
container, so a manually-typed `/next-issue` inherits autonomy silently without
this banner. (Set `NEXT_ISSUE_AUTONOMOUS=1` only in dedicated headless golem
environments, never in a shared interactive shell.)

Autonomy splits into **two independent sub-behaviors**. Keep them distinct —
the plan gate is the whole point of this skill:

- **Gate-skipping (always on when autonomous).** Do NOT call any
  `AskUserQuestion`. Every human gate in the phases below — issue acceptance,
  branch-freshness, drift, shipping mode, CI waits — takes its documented
  default with no interactive tool call.
- **Plan-skipping (conditional).** Whether the plan checkpoint
  (`EnterPlanMode`/`ExitPlanMode`) is skipped depends on the issue's effort and
  severity labels:

  ```text
  IF (effort/trivial OR effort/small) AND NOT severity/critical:
      → FULLY AUTONOMOUS: skip plan mode entirely (today's --auto behavior).
        Use the autonomous planning path in Phase 2 (state file + issue
        comment, no EnterPlanMode), then implement and ship in-turn.
  ELSE (effort/medium | effort/large | severity/critical | no effort label):
      → PLAN-GATED AUTONOMY: still call EnterPlanMode, build the plan, and STOP
        at ExitPlanMode for human approval. A golem shows up BLOCKED in
        `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`; the human runs `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`, reviews and
        refines the plan in the SAME session, then approves. Everything AFTER
        plan approval stays autonomous (implement → test → adversarial review →
        push/PR), with the refined plan in-context.
  ```

  **Overrides** (per-run, take precedence over the label rule above): `--plan-gate`
  (alias `--no-skip-plan`) forces the checkpoint even on a trivial/small issue;
  `--force-auto` (alias `--skip-plan`) forces full plan-skipping even on a
  medium/large/critical one. If both appear, `--plan-gate` wins (safer default).

  **`--force-auto` on a `severity/critical` issue needs a second consent.**
  `--force-auto` removes the plan gate, which on a critical issue is the **sole
  human checkpoint** before a fully-autonomous implement → push/PR. Mirror the
  `next-issue-ship` auto-merge double-consent (which requires BOTH `AUTOMERGE=1`
  and `AUTOMERGE_AUTONOMOUS=1` while autonomous): when the run is autonomous AND
  the issue is `severity/critical`, `--force-auto` is honored **only if** the
  environment variable `FORCE_AUTO_CRITICAL=1` is **also** set. The two signals
  must come from *separate* sources — `--force-auto` is a per-invocation flag an
  operator types; `FORCE_AUTO_CRITICAL=1` should be injected from a distinct
  configuration source, never co-located with the launch command, so one
  copy-paste cannot silently disarm the critical-issue gate.

  - **`--force-auto` + critical + `FORCE_AUTO_CRITICAL=1` set** → honor the
    override: print a prominent banner —
    `WARNING: --force-auto bypassing the plan gate on severity/critical #{N}
    "{title}" (FORCE_AUTO_CRITICAL=1) — no human checkpoint before push/PR.` —
    then run fully-autonomous (`plan_gated: false`).
  - **`--force-auto` + critical but `FORCE_AUTO_CRITICAL` NOT set** → **ignore**
    `--force-auto` and fall back to plan-gated autonomy (keep the
    `ExitPlanMode` checkpoint). Print
    `--force-auto ignored on severity/critical #{N} — set FORCE_AUTO_CRITICAL=1
    (from a separate source) to bypass the plan gate on a critical issue;
    keeping the plan gate.`
  - **Non-critical issue, or non-autonomous run** → `--force-auto` behaves as
    before (`FORCE_AUTO_CRITICAL` has no effect; the human is in the loop on a
    non-autonomous run, and a non-critical issue keeps the existing override
    semantics). `--force-auto` must never appear in a templated golem launch
    command — it is operator-interactive only.
- **Shipping handoff (both paths).** Once implementation and testing are
  complete — for a plan-gated run, that means *after* the human approves the
  plan and implementation finishes — **invoke the `/next-issue-ship` skill in
  the same turn** (call the `Skill` tool with `next-issue-ship`). Do NOT end the
  turn after merely printing a "next step". The handoff is an actual in-turn
  skill invocation, not narrative: a single `claude '/next-issue <N> --auto'`
  prompt must reach a pushed PR on its own, because the model ending its turn
  after `/next-issue` does not start a second skill. `/next-issue-ship` then
  detects autonomy independently (via the same toggle and the persisted
  state-file signal) and continues to Branch + PR. See the autonomous planning
  path in Phase 2 for the exact point at which the invocation happens.
- **Persist the signals** to the state file: `"autonomous": true`, plus
  `"plan_gated": true` when the run is plan-gated (see Phase 1 and Phase 2
  below) so `/next-issue-ship` and any post-`/clear` resume inherit them.

When NOT autonomous (no `--auto`, no env var), behavior is unchanged — every
interactive prompt and plan-mode step below runs verbatim as the default.

## Agent Worktree Mode

Before starting Phase 0, check if the current branch is an agent worktree:

```bash
CURRENT_BRANCH=$(git branch --show-current)
```

If `$CURRENT_BRANCH` matches `^agent` (e.g., `agent01`, `agent02`):

- Inform the user: "Running in agent worktree mode on branch `{branch}`.
  Commits will stay local — the orchestrator handles delivery."
- Note that `/next-issue-ship` will auto-select commit-only mode (Option 3)

**Note on state isolation**: In agent worktree mode, each worktree has its own
working directory, so per-issue state files are naturally isolated per agent.
No disambiguation is needed.

Proceed with Phase 0 as normal regardless of mode.

## Phase 0 — Resume Check

1. **Enter plan mode** (call `EnterPlanMode` tool). In **non-autonomous** mode,
   call it here immediately. In **autonomous** mode, do NOT call it here —
   **defer** the decision: the effort/severity labels that decide whether this
   run is fully-autonomous (skip plan) or plan-gated (keep plan) are not fetched
   until Phase 1, and entering plan mode now would trap a fully-autonomous run
   in plan mode (it never calls `ExitPlanMode`, so its write/edit tools would
   stay blocked). The plan-mode call is made in Phase 2 once `plan_gated` is
   known: a **plan-gated** run calls `EnterPlanMode` there (then `ExitPlanMode`
   for approval); a **fully-autonomous** run never enters plan mode at all
   (today's `--auto` behavior). See `## Autonomous Mode`.

1. **Legacy migration** — run in order:

   a. If `.claude/memory/tmp/next-issue-state.md` exists (legacy singleton),
   read its `issue:` field, rename to `.claude/memory/tmp/next-issue-{N}.md`

   b. If any `.claude/memory/tmp/next-issue-*.md` files exist (YAML format),
   migrate each to `.json`: read the YAML frontmatter fields, write a new
   `.json` file with those fields plus `"version": 2`, delete the `.md` file

1. **Discover state files**:

   ```bash
   ls .claude/memory/tmp/next-issue-*.json 2>/dev/null
   ```

1. **If multiple state files exist** (parallel agents scenario):

   - List all active issues with their number, title, phase, and branch
   - Ask: **Which issue to resume, or start fresh?**
   - If the user picks one: validate and resume that issue (see below)
   - If start fresh: proceed to Phase 1
   - **If autonomous AND a specific issue number was provided**: do not
     prompt — target that issue's state non-interactively (resume its
     recorded phase if a valid open state file exists for it, else start
     fresh for that issue)

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
  - **If autonomous AND a specific issue number was provided**: do not
    prompt — resume the recorded phase non-interactively (the state file is
    already validated open above); otherwise start fresh for that issue

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
implement → test → `/next-issue-ship` exactly as the Phase 2 plan-gated path
does. Only fall back to a fresh Phase 2 exploration if the checkpoint is missing
or has no `files_planned` (nothing to re-present).

## Phase 1 — Select

1. **Detect platform** from `git remote -v`:

   - `github.com` or `ghe.` → GitHub (`gh`)
   - `gitlab.com` or `gitlab.` → GitLab (`glab`)

1. **If a specific issue number was provided**: fetch that issue directly and
   skip the priority query. Still run the **blocked-by check** (see
   `state-format.md` § Blocked-by Exclusion) on it — but because the operator
   named the issue, **do not skip it**: emit a one-line `WARNING:` listing the
   open blockers and proceed (the plan gate is the backstop). Never hard-block
   an explicitly-named issue.

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
   a different one) — when autonomous, accept the selected issue
   automatically (no prompt)

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
     "autonomous": {true|false},
     "plan_gated": {true|false}
   }
   ```

   Set `"autonomous"` from the toggle (true when `--auto` or
   `NEXT_ISSUE_AUTONOMOUS=1`, false otherwise). Set `"plan_gated"` by applying
   the plan-skip rule from `## Autonomous Mode` to the issue's just-fetched
   effort/severity labels: `true` when autonomous AND (the issue is
   `effort/medium`/`large`/`severity/critical`/no-effort-label OR `--plan-gate`
   was passed) AND `--force-auto` did not take effect; `false` otherwise
   (including every non-autonomous run). **`--force-auto` takes effect** only
   when it was passed AND, for a `severity/critical` issue, the second-consent
   `FORCE_AUTO_CRITICAL=1` is also set (see `## Autonomous Mode`); on a critical
   issue without that second signal, `--force-auto` is ignored and `plan_gated`
   stays `true`. A `true` value means this run keeps the plan checkpoint;
   `false` means it skips plan mode.

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

   > **After all implementation and testing is complete**, invoke `/next-issue-ship`
   > to commit, deliver, and close the issue.

   If in agent worktree mode, also append:

   > Agent worktree mode: `/next-issue-ship` will auto-select commit-only
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

   Set `"autonomous"` from the toggle: `true` only when `--auto` or
   `NEXT_ISSUE_AUTONOMOUS=1`; `false` otherwise — **including `--ship`/`--now`
   runs**, which are not autonomous (see the conditional final step below). Set
   `"plan_gated"` per the rule in Phase 1 / `## Autonomous Mode` (an autonomous
   medium+/critical/no-effort-label run, or any autonomous run with
   `--plan-gate`, unless `--force-auto` **took effect** — which on a
   `severity/critical` issue additionally requires `FORCE_AUTO_CRITICAL=1`). The template above deliberately omits
   `"plan_comment_url"`: add that field **only** on the **fully-autonomous**
   path (see the autonomous planning path below), where the plan is posted as an
   issue comment. A plan-gated run uses `EnterPlanMode`/`ExitPlanMode` instead
   and must NOT add it; a non-autonomous run never adds it either.

1. **Autonomous planning path** — branches on the plan gate (`"plan_gated"`
   from Phase 1 / `## Autonomous Mode`):

   - **Fully-autonomous run (`plan_gated: false`)** — do NOT enter plan mode.
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

   - **Plan-gated autonomous run (`plan_gated: true`)** — do NOT take the
     comment-only shortcut. Call **`EnterPlanMode`** now (it was deferred in
     Phase 0), build the plan, then call **`ExitPlanMode`** (next step) to
     present it for human approval. The golem is now BLOCKED
     awaiting input (surfaced by `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`); the human attaches via
     `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`, refines the plan in-session, and approves.
     **After approval**, the run is autonomous again: skip the "Suggest context
     reset" step, proceed directly through implementation and testing, and then
     invoke `/next-issue-ship` in-turn exactly as the shipping handoff below.
     Posting a plan issue comment is optional here (the plan is already visible
     in the approval prompt); skip `"plan_comment_url"`.

   **Then, once implementation and testing are complete — for a plan-gated run,
   that means only after the `ExitPlanMode` approval below AND the subsequent
   "Implement" step both finish — invoke the `/next-issue-ship`
   skill in this same turn** (call the `Skill` tool with `next-issue-ship`). Do
   NOT invoke ship before `ExitPlanMode` approval or before the work exists. Do
   NOT stop after implementation to *suggest* shipping,
   and do NOT merely print a "next step: /next-issue-ship" line — actually
   invoke it. This is the whole point of `--auto`: a single
   `claude '/next-issue <N> --auto'` prompt must reach a pushed PR + labeled
   issue without a second manual command. Ending the turn after `/next-issue`
   leaves the work uncommitted with no PR. (As a belt-and-suspenders for a
   premature turn-exit, the orchestrate golem launch also chains a second
   `; claude '/next-issue-ship --auto'` prompt — see the orchestrate skill — but
   the in-turn invocation here is the primary path and must not be skipped.)

1. **Exit plan mode** (call `ExitPlanMode` tool) — this presents the plan to
   the user for approval before implementation begins. Skipped only on the
   **fully-autonomous** path; a **plan-gated** autonomous run DOES call
   `ExitPlanMode` here and waits for human approval (see the autonomous planning
   path above).

1. **Implement** — after plan approval, carry out the plan: make the changes
   and run the tests. The two steps below fire only **once implementation and
   testing are complete** — do NOT invoke `/next-issue-ship` or suggest a
   `/clear` before the work exists.

1. **Hand off — suggest a context reset, OR take the `--ship` fast-path.**
   Reached only after implementation and testing complete (previous step).
   (Skipped on **both** autonomous paths — fully-autonomous and plan-gated alike
   ship in-turn via the autonomous planning path above, never via a `/clear`.)
   Choose by flag + effort:

   - **`--ship` (or `--now`) set AND effort is `trivial`/`small`**: do NOT
     suggest a `/clear`. Invoke `/next-issue-ship` directly to deliver in this
     same context. The plan was still approved interactively above, so the
     human remains in the loop; only the reset ceremony is skipped. The state
     file's `"autonomous"` stays `false` — the ship run will still prompt for
     shipping mode etc.

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

`/next-issue` and `/next-issue-ship` are two halves of one issue-driven
pipeline, deliberately kept as **separate** skills:

```text
/next-issue        →  (implement + test)  →  /next-issue-ship
  select + plan          your work             commit · PR/push · CI · review · label
       └──────────────── next-issue-{N}.json ────────────────┘
              (phase / checkpoint carry state across the gap)
```

The hand-off is the state file `.claude/memory/tmp/next-issue-{N}.json` (schema
in `state-format.md`): `/next-issue` writes `phase` + a `checkpoint` block;
`/next-issue-ship` reads them. This lets the implement step happen later, in a
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
