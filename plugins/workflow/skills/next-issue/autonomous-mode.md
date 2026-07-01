# Next Issue — Autonomous Mode

Companion to `next-issue/SKILL.md`. Load this when the run is autonomous (or to
decide whether it is). It carries the full autonomy rule: the toggle, the
gate-skipping vs plan-skipping split, the `--force-auto` / `--plan-gate`
overrides, the `severity/critical` second-consent, and the shipping handoff.

The run is **autonomous** when EITHER the literal token `--autonomous` (or its
deprecated alias `--auto`) appears in the invocation arguments OR the
environment variable `NEXT_ISSUE_AUTONOMOUS=1` is set. Autonomy is strictly
opt-in.

> **Flag rename (deprecation).** The autonomy flag is `--autonomous`. The old
> spelling `--auto` remains a **deprecated alias** for one release and behaves
> identically; prefer `--autonomous` in new launch commands and docs. The
> rename disambiguates it from the Claude Code harness flag
> `--permission-mode auto` and from `/next-issue`'s orthogonal **plan-gate**
> override `--skip-plan` (alias of `--force-auto`) — autonomy (run unattended)
> and plan-gating (keep the plan checkpoint) are independent concerns.

**Announce the mode when it is active via the env var.** When the run is
autonomous because `NEXT_ISSUE_AUTONOMOUS=1` is set (rather than an explicit
`--autonomous` on this invocation), print one visible line up front —
`Autonomous mode active (NEXT_ISSUE_AUTONOMOUS=1) — all human gates bypassed,
will proceed to a pushed PR.` — so an operator who didn't type `--autonomous`
notices that gates are off. The env var is persistent across invocations in a
shell or container, so a manually-typed `/next-issue` inherits autonomy silently
without this banner. (Set `NEXT_ISSUE_AUTONOMOUS=1` only in dedicated headless
golem environments, never in a shared interactive shell.)

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
      → FULLY AUTONOMOUS: skip plan mode entirely (the --autonomous behavior).
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
  `ship-issue` auto-merge double-consent (which requires BOTH `AUTOMERGE=1`
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
  plan and implementation finishes — **invoke the `/ship-issue` skill in
  the same turn** (call the `Skill` tool with `ship-issue`). Do NOT end the
  turn after merely printing a "next step". The handoff is an actual in-turn
  skill invocation, not narrative: a single `claude '/next-issue <N> --autonomous'`
  prompt must reach a pushed PR on its own, because the model ending its turn
  after `/next-issue` does not start a second skill. `/ship-issue` then
  detects autonomy independently (via the same toggle and the persisted
  state-file signal) and continues to Branch + PR. See the autonomous planning
  path in Phase 2 for the exact point at which the invocation happens.
- **Persist the signals** to the state file: `"autonomous": true`, plus
  `"plan_gated": true` when the run is plan-gated (see Phase 1 and Phase 2
  below) so `/ship-issue` and any post-`/clear` resume inherit them.

When NOT autonomous (no `--autonomous`/`--auto`, no env var), behavior is unchanged — every
interactive prompt and plan-mode step below runs verbatim as the default.
