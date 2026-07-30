# Next Issue — Autonomy Levels

Companion to `next-issue/SKILL.md`. Load this to decide the run's **autonomy
level** and how each gate is dispatched. The authoritative contract for the
level model — the two gate categories, the L1–L4 table, the merge invariant, the
dead-end rule, and the `severity/critical` cap — is
`orchestrate/autonomy-levels.md` (#174); this file is how `/workflow:next-issue` **applies**
it. It carries the level selection, the per-gate disposition, the plan-gate rule,
and the shipping handoff. The old alias flags and back-compat surface were
hard-removed in #215 — `--level {1,2,3,4}` is the sole dial.

> **The decision table is code, not prose.** Level selection, the critical cap,
> per-gate disposition, the dead-end override, and the derived
> `autonomous`/`plan_gated` dispositions are all computed by the resolver
> **`${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh`** (issue #190) — the
> authoritative implementation of the `orchestrate/autonomy-levels.md` (#174)
> contract. **Call it** rather than re-deriving the rules by hand; the tables and
> pseudo-code below *describe* its behavior so a reader can follow along. Run
> `autonomy-resolve.sh` with no args for usage.

## Level selection

The run's **autonomy level** is an integer **1–4**, chosen once and persisted as
`autonomy_level` in the state file. Compute it (plus the runtime dispositions and
the critical cap in one shot) by calling the resolver:

```bash
# $ARGS = this invocation's raw flag string (may hold --level N);
# $SEV = the issue's severity label ("critical" or "" — fetched in Phase 1).
eval "$(${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh level \
    --from-args "$ARGS" --severity "$SEV")"
# -> sets autonomy_level, autonomous, plan_gated, capped, perm_mode
```

For a level chosen at setup (an orchestrator dispatch or the operator's
interactive L1–L4 answer) with no CLI flag, pass it as `--chosen-level {N}`. The
resolver applies this precedence:

- an explicit **`--level {1,2,3,4}`** flag; else
- a level **already chosen at setup by an orchestrator** (the track's
  `autonomy_level`, passed as `--level {N}` at dispatch); else
- for a **lone interactive `/workflow:next-issue`** (no flag, no orchestrator), **ask the
  operator** — the setup-flow "rules of engagement" question, scaled to one
  issue: an `AskUserQuestion` offering **L1–L4**, each with its one-line
  description (`orchestrate/autonomy-levels.md` § "The four levels"). A
  `severity/critical` issue offers **L1–L3 only** (the cap). **Wait indefinitely**
  for the answer — never lapse-and-default to L1 because the operator stepped
  away (`autonomy-levels.md` § *Standing rule*). Ask **once per run**, in Phase 1
  right after the issue's `effort/*`/`severity/*` labels are fetched (so the
  critical cap is known) and **before** the Phase 0/2 plan-mode deferral, since
  the chosen level decides whether plan mode is even entered.

The old **silent L1 default** is gone for an interactive run — L1 is now a
*choice the operator can make*, not an unannounced fallback. (A non-interactive
context with no TTY to ask — e.g. a headless invocation that is somehow neither
`--level`-flagged nor orchestrator-dispatched — still falls back to the L1
disposition rather than hang on an unanswerable prompt.)

`severity/critical` issues are **capped at L3**: an L4 selection (via `--level 4`)
on a critical issue is silently reduced to L3, so a critical issue always keeps
its escalation gates — including plan approval — in front of a human. (Full
carve-out in `orchestrate/autonomy-levels.md`; the override-removal cleanup is
issue #179.)

**State file.** `autonomy_level` (1–4) is the only autonomy field written.
`/workflow:ship-issue` reads it back via `autonomy-resolve.sh read --state-level`; there is
no `autonomous`/`plan_gated` mirror and no legacy-boolean fallback (both removed
in #215).

## Per-gate disposition

Each gate is **routine** or **escalation** (categories defined in
`orchestrate/autonomy-levels.md`); the level decides whether it is auto-passed or
raised to a human. Resolve any single gate with
`autonomy-resolve.sh gate {routine|escalation} --level {N} [--dead-end]` →
`disposition=auto|human`; the table below is the same rule, tabulated:

| Gate class                                             | L1     | L2     | L3     | L4     |
| ------------------------------------------------------ | ------ | ------ | ------ | ------ |
| Harness permission mode                                | `acceptEdits` | `auto` | `auto` | `auto` |
| Routine (push, PR-open, merge-on-green+clean, prune)   | human  | human  | auto   | auto   |
| Escalation (plan approval, arch/directional fork, wall)| human  | human  | human  | auto   |

The **plan-approval checkpoint is an escalation gate** — human at L1–L3,
auto-passed at L4 — subject to the critical cap (critical never exceeds L3, so it
always keeps the plan gate). A **dead-end** (an escalation gate whose only
auto-resolution would break the merge invariant) defers to a human at **every**
level, L4 included.

The harness-perm-mode row (L1 `acceptEdits` vs L2–L4 `auto`) is surfaced in the
**golem launch command**, not forced mid-session by a plain interactive
`/workflow:next-issue`.

> **Flag note.** `--level {1,2,3,4}` is the only autonomy-level signal. It is
> distinct from the Claude Code harness flag `--permission-mode auto` (which the
> launch command sets separately) — that is not an autonomy-level input.

## Applying the level in `/workflow:next-issue`

- **Gate-skipping (L3–L4).** At L3 and L4, do NOT call `AskUserQuestion` for a
  routine gate — issue acceptance, branch-freshness, drift, shipping mode, CI
  waits each take their documented default with no interactive tool call. At
  L1–L2 these gates stay human.
- **Plan-skipping (L4 only, minus the critical cap).** Whether the plan
  checkpoint (`EnterPlanMode`/`ExitPlanMode`) is skipped is the **`plan_gated`
  disposition** the resolver emitted (`plan_gated=false` ⇒ skip; `true` ⇒
  keep) — it depends on the level, **not** the effort/severity labels:

  ```text
  IF plan_gated == false (i.e. level 4, and the critical cap did not fire):
      → PLAN AUTO-PASSED: skip plan mode entirely. Use the autonomous planning
        path in Phase 2 (state file + issue comment, no EnterPlanMode), then
        implement and ship in-turn.
  ELSE (plan_gated == true — level 1-3, incl. a capped critical):
      → PLAN GATE KEPT: call EnterPlanMode, build the plan, and STOP at
        ExitPlanMode for human approval. A golem shows up BLOCKED in
        `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`; the human runs
        `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`, reviews and refines
        the plan in the SAME session, then approves. Everything AFTER plan
        approval proceeds at the run's level (implement → test → adversarial
        review → push/PR).
  ```

  This replaces the old effort-based rule: the level is the dial. Note the
  consequence — an L4 run on an `effort/medium` issue now **skips** the plan
  (it was plan-gated under the binary model); a `severity/critical` issue still
  keeps the plan gate because it caps at L3.

  **"L4 but keep the plan gate" is just L3.** There is no override that keeps the
  plan gate on an L4 run — the removed `--plan-gate`/`--force-auto` flags (#215)
  expressed that, and their behavior is now exactly **L3** (routine gates
  auto-pass, plan gate kept). On a `severity/critical` issue an L4 selection
  cannot auto-pass the plan gate anyway: the **critical cap** holds the run at L3,
  and there is no override that lifts it — a critical issue's plan gate is always
  human (`orchestrate/autonomy-levels.md` § *The critical carve-out*).
- **Shipping handoff (L3–L4).** A run that reaches implementation without a
  human at every routine gate — L3 or L4 — must not stop before delivery. Once
  implementation and testing are complete — for a plan-gate-kept run, that means
  *after* the human approves the plan and implementation finishes — **invoke the
  `/workflow:ship-issue` skill in the same turn** (call the `Skill` tool with
  `ship-issue`). Do NOT end the turn after merely printing a "next step". The
  handoff is an actual in-turn skill invocation, not narrative: a single
  `claude '/workflow:next-issue <N> --level 4'` prompt must reach a pushed PR on its own,
  because the model ending its turn after `/workflow:next-issue` does not start a second
  skill. `/workflow:ship-issue` then detects the level independently (from the persisted
  `autonomy_level`) and continues to Branch + PR. See the autonomous planning
  path in Phase 2 for the exact point at which the invocation happens.
- **Mid-flight escalation gate (all levels).** The plan gate is not the only
  escalation gate. If a **non-mechanical** decision surfaces *during
  implementation or testing* — competing architectural approaches, a directional
  fork the plan left open, or a wall with more than one viable escape — it is an
  **escalation gate**, dispatched by level exactly like plan approval: **human at
  L1–L3, auto-passed (agent picks its recommendation) at L4**, and a **dead-end**
  (whose only auto-resolution would break the merge invariant) blocks at **every**
  level, L4 included. Follow `escalation-protocol.md` for the payload format
  (decision, options + tradeoffs, recommendation), the feed emission
  (`ESCALATION:`-prefixed message → `golem-notify.sh`, surfaced distinctly by
  `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`), and the **never-time-out**
  rule at this gate. Err toward escalating when unsure.
- **Persist the level** to the state file: `"autonomy_level": <1-4>` (the only
  autonomy field) — so `/workflow:ship-issue` and any post-`/clear` resume inherit it (see
  Phase 1 and Phase 2 below). The `plan_gated`/`perm_mode` dispositions the
  `autonomy-resolve.sh level` call emitted are runtime-only; do not persist them.

At an **L1 disposition** (no level chosen — the interactive default), behavior is
unchanged: every interactive prompt and plan-mode step below runs verbatim.
