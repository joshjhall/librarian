# Next Issue — Autonomy Levels

Companion to `next-issue/SKILL.md`. Load this to decide the run's **autonomy
level** and how each gate is dispatched. The authoritative contract for the
level model — the two gate categories, the L1–L4 table, the merge invariant, the
dead-end rule, and the `severity/critical` cap — is
`orchestrate/autonomy-levels.md` (#174); this file is how `/next-issue` **applies**
it. It carries the level selection and aliases, the per-gate disposition, the
plan-gate rule, the legacy overrides (superseded by the level; removed in #179),
and the shipping handoff.

## Level selection

The run's **autonomy level** is an integer **1–4**, chosen once and persisted as
`autonomy_level` in the state file. It is set by, in precedence order:

- an explicit **`--level {1,2,3,4}`** flag; else
- **`--autonomous`** (or its deprecated alias **`--auto`**), or the environment
  variable **`NEXT_ISSUE_AUTONOMOUS=1`** — each an **alias for L4**; else
- **nothing** → the interactive default, an **L1 disposition** (every gate asks),
  unless a level was chosen at setup by an orchestrator.

`severity/critical` issues are **capped at L3**: an L4 selection (via `--level 4`
or an `--autonomous` alias) on a critical issue is silently reduced to L3, so a
critical issue always keeps its escalation gates — including plan approval — in
front of a human. (Full carve-out in `orchestrate/autonomy-levels.md`; the
override-removal cleanup is #179.)

**Back-compat on read.** A legacy state file with `"autonomous": true` and no
`autonomy_level` migrates to **L4**; `autonomous:false`/absent with no
`autonomy_level` is **L1**. When both are present, `autonomy_level` wins.
`/next-issue` also **writes** the derived `autonomous` (= level 4) and
`plan_gated` mirrors so the not-yet-level-aware `/ship-issue` keeps working until
issue #177 lands.

## Per-gate disposition

Each gate is **routine** or **escalation** (categories defined in
`orchestrate/autonomy-levels.md`); the level decides whether it is auto-passed or
raised to a human:

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
`/next-issue`; wiring it into the launch scripts is coordinated with #179.

> **Flag notes (deprecation).** `--autonomous` and its deprecated alias `--auto`
> are L4 aliases; prefer `--level 4` (or `--autonomous`) in new launch commands.
> Both are distinct from the Claude Code harness flag `--permission-mode auto`
> and from `/next-issue`'s legacy plan-gate overrides below — none of those is an
> autonomy-level signal.

**Announce the mode when it is active via the env var.** When the run is
autonomous because `NEXT_ISSUE_AUTONOMOUS=1` is set (rather than an explicit
`--autonomous` on this invocation), print one visible line up front —
`Autonomous mode active (NEXT_ISSUE_AUTONOMOUS=1) — all human gates bypassed,
will proceed to a pushed PR.` — so an operator who didn't type `--autonomous`
notices that gates are off. The env var is persistent across invocations in a
shell or container, so a manually-typed `/next-issue` inherits autonomy silently
without this banner. (Set `NEXT_ISSUE_AUTONOMOUS=1` only in dedicated headless
golem environments, never in a shared interactive shell.)

## Applying the level in `/next-issue`

- **Gate-skipping (L3–L4).** At L3 and L4, do NOT call `AskUserQuestion` for a
  routine gate — issue acceptance, branch-freshness, drift, shipping mode, CI
  waits each take their documented default with no interactive tool call. At
  L1–L2 these gates stay human.
- **Plan-skipping (L4 only, minus the critical cap).** Whether the plan
  checkpoint (`EnterPlanMode`/`ExitPlanMode`) is skipped depends on the level,
  **not** the effort/severity labels:

  ```text
  IF level == 4 (and NOT severity/critical, which caps to L3):
      → PLAN AUTO-PASSED: skip plan mode entirely. Use the autonomous planning
        path in Phase 2 (state file + issue comment, no EnterPlanMode), then
        implement and ship in-turn. (plan_gated mirror: false)
  ELSE (level 1-3, OR severity/critical at any requested level):
      → PLAN GATE KEPT: call EnterPlanMode, build the plan, and STOP at
        ExitPlanMode for human approval. A golem shows up BLOCKED in
        `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`; the human runs
        `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`, reviews and refines
        the plan in the SAME session, then approves. Everything AFTER plan
        approval proceeds at the run's level (implement → test → adversarial
        review → push/PR). (plan_gated mirror: true)
  ```

  This replaces the old effort-based rule: the level is the dial. Note the
  consequence — an L4 run on an `effort/medium` issue now **skips** the plan
  (it was plan-gated under the binary model); a `severity/critical` issue still
  keeps the plan gate because it caps at L3.

  **Legacy overrides (superseded by the level; removed in #179).** The old
  per-run plan-gate flags still parse and map onto the level for continuity:
  `--plan-gate` (alias `--no-skip-plan`) ⇒ **keep the plan gate** (treat the run
  as ≤ L3 for the plan checkpoint); `--force-auto` (alias `--skip-plan`) ⇒
  **L4** (auto-pass the plan), still subject to the critical cap. If both appear,
  `--plan-gate` wins (safer default).

  The `FORCE_AUTO_CRITICAL=1` second-consent that once let `--force-auto` bypass
  the plan gate on a `severity/critical` issue is now **inert**: the critical cap
  holds a critical issue at L3, so its plan gate can no longer be auto-passed by
  any flag. The env var and the `--force-auto`-on-critical branch are retained
  only until #179 deletes them; do not rely on them, and never place
  `--force-auto` in a templated golem launch command (it is operator-interactive
  only).
- **Shipping handoff (L3–L4).** A run that reaches implementation without a
  human at every routine gate — L3 or L4 — must not stop before delivery. Once
  implementation and testing are complete — for a plan-gate-kept run, that means
  *after* the human approves the plan and implementation finishes — **invoke the
  `/ship-issue` skill in the same turn** (call the `Skill` tool with
  `ship-issue`). Do NOT end the turn after merely printing a "next step". The
  handoff is an actual in-turn skill invocation, not narrative: a single
  `claude '/next-issue <N> --autonomous'` (i.e. `--level 4`) prompt must reach a
  pushed PR on its own, because the model ending its turn after `/next-issue`
  does not start a second skill. `/ship-issue` then detects the level
  independently (from the persisted `autonomy_level`, falling back to the
  `autonomous` mirror until #177) and continues to Branch + PR. See the
  autonomous planning path in Phase 2 for the exact point at which the invocation
  happens.
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
- **Persist the signals** to the state file: `"autonomy_level": <1-4>`, plus the
  derived back-compat mirrors `"autonomous"` (= level 4) and `"plan_gated"` (true
  when the plan gate is kept — L1–L3, or a capped critical) so `/ship-issue` and
  any post-`/clear` resume inherit them (see Phase 1 and Phase 2 below).

At an **L1 disposition** (no level chosen — the interactive default), behavior is
unchanged: every interactive prompt and plan-mode step below runs verbatim.
