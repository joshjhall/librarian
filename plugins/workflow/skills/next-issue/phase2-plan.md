# Phase 2 — Plan

Companion to `next-issue/SKILL.md`. Load this when a run reaches the planning
phase (after Phase 1 selection). It carries the full Phase 2 step sequence:
scope assessment, the plan-lens sizing step (`plan-sizing.md`), the mandatory
`/workflow:ship-issue` final step, the state-file write,
the plan-gate branch (L4 comment-only vs L1–L3 `EnterPlanMode`/`ExitPlanMode`),
the implement step with its mid-flight escalation gate, and the hand-off /
`--ship` fast-path. The authoritative level model is
`orchestrate/autonomy-levels.md`; the level fields come from Phase 1's resolver
call (see SKILL.md `## Autonomy Levels` and `autonomy.md`).

1. Read the full issue body

1. Explore the relevant code areas (use Grep/Glob/Read).

   **Route fan-out reading to a subagent — load `/dev-core:delegating-investigation`
   and apply its break-even.** Planning is the most investigation-heavy phase in
   the pipeline, and its reading is exactly the shape that pays: wide surveys
   collapsing to a short conclusion. Delegate when
   `result_tokens x turns_resident > ~24,568` (the measured median spawn prefix,
   #787) — surveying a tree, tracing a convention across the repo, "where is X
   handled". Read **inline** when the file and line are already known: below the
   break-even a subagent is slower *and* dearer. A delegated investigation
   returns the answer plus `file:line` anchors, never a transcript of what it
   read — otherwise the plan context absorbs the exploration anyway and the
   delegation bought nothing.

1. **Run the plan-lens sizing step** — load `plan-sizing.md` and follow it.
   Build the candidate file list from the exploration you just did, estimate the
   lines the plan adds to each, and run
   `${CLAUDE_PLUGIN_ROOT}/skills/ship-issue/plan-lens.sh`. It reports files
   already over budget **and** — the row no other lens can produce — files
   *under* budget that this plan would push over.

   A **cheap, mechanical** seam is folded into the plan here as ordinary steps
   before the feature work; a **swamping** one raises the swamp gate (four
   options: fold in / follow-up issue / decompose first / proceed unchanged),
   dispatched by level exactly like any other escalation — human at L1–L3,
   auto-selected at L4. Record every outcome in `checkpoint.scope_expansions`
   so the growth does not later read as drift. If the scanner is unavailable,
   note it in one line and keep planning — this step never blocks the pipeline.

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

   > **After all implementation and testing is complete**, invoke `/workflow:ship-issue`
   > to commit, deliver, and close the issue.

   If in agent worktree mode, also append:

   > Agent worktree mode: `/workflow:ship-issue` will auto-select commit-only
   > (Option 3). The orchestrator handles PR creation and delivery.

1. **Update state file** — write the full JSON with `phase: "plan"`, a
   one-line `plan` summary, and the `checkpoint` object. This physical write MUST
   complete **before** the `EnterPlanMode` call in the autonomous-planning path
   below: an L1–L3 run enters plan mode next, and plan mode permits only edits to
   the plan file, so a state write attempted after `EnterPlanMode` is silently
   blocked and the `/workflow:ship-issue` hand-off record never lands (issue #409). Do the
   write here, then enter plan mode.

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

   Carry `"autonomy_level"` forward from Phase 1 unchanged — the level is fixed
   at selection, including the critical cap. Note `--ship`/`--now` is **not
   autonomy** and never
   selects L4 — it keeps the interactive plan gate and only skips the `/clear`; a
   lone `--ship` run still answers the L1–L4 question in Phase 1 (any of L1–L3),
   and its plan-approval gate is preserved at every one of those. The
   template above deliberately omits `"plan_comment_url"`: add that field **only**
   on the **L4 (plan-auto-passed)** path (see the autonomous planning path below),
   where the plan is posted as an issue comment. An **L1–L3** run uses
   `EnterPlanMode`/`ExitPlanMode` instead and must NOT add it.

1. **Autonomous planning path** — branches on the plan gate (`plan_gated`,
   derived from `autonomy_level` — kept at L1–L3, auto-passed at L4; see
   `## Autonomy Levels`):

   > **Note (dependency queue):** if Phase 1 built a dependency queue for an
   > explicitly-named blocked issue, the `active` issue selected there — a
   > dependency, not the named target — is what this autonomous run plans,
   > implements, and ships (its own PR). The run works exactly **one** queue
   > entry; the queue file persists for the next cycle to advance toward the
   > target (see `dependency-queue.md` § Dependency Queue → "Gate-skipping
   > (L3–L4) interaction"). Do NOT try to auto-advance the whole chain in one turn.

   - **L4 run (`plan_gated: false`, non-critical)** — do NOT enter plan mode.
     After exploring and forming the plan: (1) write the plan to the state file
     exactly as above, AND (2) post the plan as an issue comment for
     traceability —

     ```bash
     gh issue comment {N} --body "..."      # GitHub
     glab issue note {N} --message "..."    # GitLab
     ```

     Capture the returned comment URL and record it in the state file as
     `"plan_comment_url"`. **The comment must carry any plan-lens scope
     expansion** — folded-in decomposition steps, and any swamp-gate resolution
     this level auto-selected, with its rationale (`plan-sizing.md`). L4 is the
     path with no human in the loop, so this comment is the only place that
     scope growth becomes visible. Then proceed DIRECTLY to implementation — no
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
     testing, then invoke `/workflow:ship-issue` in-turn exactly as the shipping handoff
     below; at **L1–L2** the routine gates (shipping mode, push, PR) remain
     human, so follow the normal non-autonomous hand-off. Posting a plan issue
     comment is optional here (the plan is already visible in the approval
     prompt); skip `"plan_comment_url"`.

   **Then, once implementation and testing are complete — for an L1–L3 run that
   kept the plan gate, that means only after the `ExitPlanMode` approval below
   AND the subsequent "Implement" step both finish — an L3–L4 run invokes the
   `/workflow:ship-issue` skill in this same turn** (call the `Skill` tool with
   `ship-issue`). Do NOT invoke ship before `ExitPlanMode` approval (when the
   gate was kept) or before the work exists. Do NOT stop after implementation to
   *suggest* shipping, and do NOT merely print a "next step: /workflow:ship-issue" line —
   actually invoke it. This is the whole point of L3–L4: a single
   `claude '/workflow:next-issue <N> --level 4'` prompt must reach a pushed PR + labeled
   issue without a second manual command. Ending the turn after `/workflow:next-issue`
   leaves the work uncommitted with no PR. (As a belt-and-suspenders for a
   premature turn-exit, the orchestrate golem launch also chains a second
   `; claude '/workflow:ship-issue'` prompt — see the orchestrate skill — but the in-turn
   invocation here is the primary path and must not be skipped.) An **L1–L2** run instead stops for the human at the
   routine ship gates — follow the default hand-off below.

1. **Exit plan mode** (call `ExitPlanMode` tool) — this presents the plan to
   the user for approval before implementation begins. Skipped only on the
   **L4 (non-critical)** path; an **L1–L3** run (including a capped critical)
   DOES call `ExitPlanMode` here and **waits indefinitely** for human approval —
   never lapse-and-default and start implementing because the operator stepped
   away (the standing rule above; `autonomy-levels.md` § *Standing rule*). See
   the autonomous planning path above.

1. **Implement** — after plan approval, carry out the plan: make the changes
   and run the tests. The two steps below fire only **once implementation and
   testing are complete** — do NOT invoke `/workflow:ship-issue` or suggest a
   `/clear` before the work exists.

   **Mid-flight escalation gate.** If, while implementing or testing, you reach a
   decision that is **not mechanical** — competing architectural approaches, a
   directional choice the plan left open, or a wall with more than one viable
   escape — this is an **escalation gate**, not something to silently decide.
   Load `escalation-protocol.md` and follow it: assemble the payload (decision,
   options + tradeoffs, recommendation), then dispatch by level — **L1–L3 block
   and wait indefinitely** for a human (surfaced as an `escalation` on the feed +
   an issue comment; inline for a lone `/workflow:next-issue`), **L4 auto-selects the
   recommendation** and continues, **unless it is a dead-end** (no safe option /
   would violate the merge invariant), which blocks at every level including L4.
   Err toward escalating when unsure. This is distinct from the plan gate above,
   which is handled structurally by `ExitPlanMode`.

1. **Hand off — suggest a context reset, OR take the `--ship` fast-path.**
   Reached only after implementation and testing complete (previous step).
   (Skipped on the **L3–L4** paths — they ship in-turn via the autonomous
   planning path above, never via a `/clear`.) Choose by flag + effort:

   - **`--ship` (or `--now`) set AND effort is `trivial`/`small`**: do NOT
     suggest a `/clear`. Invoke `/workflow:ship-issue` directly to deliver in this
     same context. The plan was still approved interactively above, so the
     human remains in the loop; only the reset ceremony is skipped. The run stays
     at its chosen level (an L1–L3 answer; `--ship` never selects L4) — the ship
     run will still stop for the human at any routine gate that level keeps.

   - **`--ship`/`--now` set BUT effort is `medium`/`large` (or there is no
     `effort/*` label)**: emit a one-line note — "`--ship` skipped for
     {effort/medium,effort/large,no effort label} — preserving the `/clear`
     boundary" — then fall through to the default suggestion below.

   - **Default (no `--ship`/`--now`)** — the reset suggestion is
     **worktree-aware**. Detect a linked worktree with the repo-standard idiom
     (`git rev-parse --git-dir` != `git rev-parse --git-common-dir`; the same
     check the golem nesting guard and `ship-issue/execute-protocol.md` use):

     - **Primary checkout** (`--git-dir` == `--git-common-dir`) — tell the user:

       > Planning phase complete. Context can be safely cleared — state saved to
       > `.claude/memory/tmp/next-issue-{N}.json`. Run `/clear` then `/workflow:next-issue`
       > to resume from implementation.

     - **Linked worktree** (`--git-dir` != `--git-common-dir` — e.g. a `/workflow:golem`
       run) — a bare `/clear` may return the session to the **main checkout** and
       drop the worktree cwd, so the resume note carries the re-entry step:

       > Planning phase complete. Context can be safely cleared — state saved to
       > `.claude/memory/tmp/next-issue-{N}.json`. `/clear` may return you to the
       > main checkout, so after it re-enter this worktree with
       > `EnterWorktree({ path: ".worktrees/issue-{N}" })`, then run `/workflow:next-issue`
       > to resume from implementation.

     This is advisory — continue normally if the user declines.
