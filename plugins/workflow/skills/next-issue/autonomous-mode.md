# Next Issue — Autonomy Levels

Companion to `next-issue/SKILL.md`. Load this to decide the run's **autonomy
level** and how each gate is dispatched. The authoritative contract for the
level model — the two gate categories, the L1–L4 table, the merge invariant, the
dead-end rule, and the `severity/critical` cap — is
`orchestrate/autonomy-levels.md` (#174); this file is how `/next-issue` **applies**
it. It carries the level selection and aliases, the per-gate disposition, the
plan-gate rule, the legacy overrides (superseded by the level; removed in #179),
and the shipping handoff.

> **The decision table is code, not prose.** Level selection, the critical cap,
> per-gate disposition, the dead-end override, and the derived
> `autonomous`/`plan_gated` mirrors are all computed by the resolver
> **`${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh`** (issue #190) — the
> authoritative implementation of the `orchestrate/autonomy-levels.md` (#174)
> contract. **Call it** rather than re-deriving the rules by hand; the tables and
> pseudo-code below *describe* its behavior so a reader can follow along. Run
> `autonomy-resolve.sh` with no args for usage.

## Level selection

The run's **autonomy level** is an integer **1–4**, chosen once and persisted as
`autonomy_level` in the state file. Compute it (plus the derived mirrors and the
critical cap in one shot) by calling the resolver:

```bash
# $ARGS = this invocation's raw flag string (may hold --level/--autonomous/…);
# $SEV = the issue's severity label ("critical" or "" — fetched in Phase 1).
eval "$(${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh level \
    --from-args "$ARGS" --env-autonomous "${NEXT_ISSUE_AUTONOMOUS:-0}" \
    --severity "$SEV")"
# -> sets autonomy_level, autonomous, plan_gated, capped, perm_mode
```

For a level chosen at setup (an orchestrator dispatch or the operator's
interactive L1–L4 answer) with no CLI flag, pass it as `--chosen-level {N}`. The
resolver applies this precedence:

- an explicit **`--level {1,2,3,4}`** flag; else
- **`--autonomous`** (or its deprecated alias **`--auto`**), or the environment
  variable **`NEXT_ISSUE_AUTONOMOUS=1`** — each an **alias for L4**; else
- a level **already chosen at setup by an orchestrator** (the track's
  `autonomy_level`, passed as `--level {N}` at dispatch); else
- for a **lone interactive `/next-issue`** (no flag, no orchestrator), **ask the
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
`--autonomous` nor orchestrator-dispatched — still falls back to the L1
disposition rather than hang on an unanswerable prompt.)

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
  checkpoint (`EnterPlanMode`/`ExitPlanMode`) is skipped is the **`plan_gated`
  mirror** the resolver already emitted (`plan_gated=false` ⇒ skip; `true` ⇒
  keep) — it depends on the level, **not** the effort/severity labels:

  ```text
  IF plan_gated == false (i.e. level 4, and the critical cap did not fire):
      → PLAN AUTO-PASSED: skip plan mode entirely. Use the autonomous planning
        path in Phase 2 (state file + issue comment, no EnterPlanMode), then
        implement and ship in-turn.
  ELSE (plan_gated == true — level 1-3, a capped critical, or --plan-gate):
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

  **Legacy overrides (superseded by the level).** The old per-run plan-gate flags
  still parse and map onto the level for continuity — the resolver reads them
  straight out of `--from-args`, so passing the raw invocation string is all that
  is needed: `--plan-gate` (alias `--no-skip-plan`) ⇒ **keep the plan gate**
  (forces `plan_gated=true`); `--force-auto` (alias `--skip-plan`) ⇒ **L4**
  (auto-pass the plan), still subject to the critical cap. If both appear,
  `--plan-gate` wins (safer default).

  On a `severity/critical` issue neither `--force-auto` nor an L4 selection can
  auto-pass the plan gate: the **critical cap** holds the run at L3, and there is
  no override that lifts it — a critical issue's plan gate is always human. (The
  cap subsumes the old env-var second-consent that once let `--force-auto` bypass
  a critical plan gate; see `orchestrate/autonomy-levels.md` § *The critical
  carve-out*.) Never place `--force-auto` in a templated golem launch command —
  it is operator-interactive only.
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
  derived back-compat mirrors `"autonomous"` and `"plan_gated"` — all three are
  fields the `autonomy-resolve.sh level` call already emitted (do not recompute
  them) — so `/ship-issue` and any post-`/clear` resume inherit them (see Phase 1
  and Phase 2 below).

At an **L1 disposition** (no level chosen — the interactive default), behavior is
unchanged: every interactive prompt and plan-mode step below runs verbatim.
