# Next Issue — Context Handoff Protocol

On-demand companion for `next-issue/SKILL.md` and `phase2-plan.md`. Load this at
a **reset point** (see `state-format.md` § Reset Points) when the run is a golem
or any long unattended session, or whenever `golem-status.sh` shows a golem at
`HANDOFF DUE`.

It exists because a session that runs to exhaustion pays for its own length.
Every request re-sends the whole accumulated context, so the last decile of a
long session costs roughly **3x** the first decile for identical work — measured
price-weighted across 28 local transcripts (ratios 2.2–5.3x, median ~3.0x). The
fix is not to compact harder; it is to **stop the session at a bounded size** and
resume in a fresh one that starts at the floor.

## The signal

```bash
# worktree-safe-exempt: this is the MAIN-CHECKOUT form; the worktree spelling
# is the second block below
"${CLAUDE_PLUGIN_ROOT}/scripts/context-budget.sh" check <worktree-dir>
```

**Inside a worktree, spell it so the Bash tool can statically evaluate it
(#809, #815).** The form above is correct only for a session in the **main
checkout**. A session that has entered a worktree — every `/workflow:golem` run
past Phase B, which is the main consumer of this protocol — must instead use a
literal path and `.`, as `golem/SKILL.md` § Phase C shows:

```bash
<skill-base-dir>/../../scripts/context-budget.sh check .
```

The harness refuses a Bash command it cannot verify stays in-tree, and both
`${CLAUDE_PLUGIN_ROOT}` and `"$PWD"` trip that check. A refused command is an
**unknown** budget, which the fail-loud rule below already covers — but it is
worth avoiding rather than reporting, since it makes the reading unavailable for
the entire run.

This is **not** a lone exception: every recipe `/workflow:next-issue` and
`/workflow:ship-issue` execute inside a golem is isolated too. The measured
spelling matrix, the boundary condition, and both safe rewriting patterns live in
`worktree-safe-recipes.md` — read it rather than re-deriving the rule here.

Emits `key=value` lines — `context_tokens`, `floor`, `threshold`,
`pct_of_threshold`, `verdict`. Read the **verdict**; do not re-derive it from the
token count. (Same division of labour as `threshold-check.sh`: the script owns
the arithmetic, the model runtime performs the action. Prose that asks a model to
do the comparison by hand is how #327's golems wedged.)

| verdict | meaning | what to do |
| --- | --- | --- |
| `ok` | under 80% of threshold | nothing |
| `advise` | at/over 80% | finish the step you are on; do not start a new one |
| `handoff` | at/over threshold | check point and end the session (golem), or surface a one-line note (interactive) |

**Fail-loud, so a missing reading is never silence.** Exit 2 (no transcript) and
exit 3 (no jq) mean *the budget is unknown*, not *the budget is fine*. Treat an
unknown budget as `ok` and **say so in one line** — never report a bounded
session on a reading that did not happen.

## Interactive sessions are advised, never cycled

A human at the terminal holds context the state file does not: what they are
about to ask next, why they rejected the last approach, what they are watching
for. Ending that session to save tokens spends something more expensive than
tokens. So at **any** verdict an interactive session gets **one advisory line and
nothing else** — no automatic checkpoint, no session end, no prompt to confirm a
cycle. The operator decides.

Only a **golem** — a `/workflow:golem` or `/workflow:orchestrate` session working
one issue unattended — acts on `handoff` automatically. That is the shape that
runs 400–800 turns with nobody watching, and the shape whose entire state is
already designed to survive a `/clear`.

## The handoff

**No new state format.** The handoff writes the `checkpoint` object that
`state-format.md` already defines, in `.claude/memory/tmp/next-issue-{N}.json`.
This is the same mechanism the `/clear` reset points and the plan-gated resume
path already use — a context handoff is just a reset point chosen by size rather
than by phase.

1. **Write the checkpoint** — `completed_phase`, `key_decisions`,
   `files_modified`, `files_planned`, `warnings`, and an explicit `next_action`.
   Carry `autonomy_level` forward unchanged.

1. **Make `next_action` executable, not descriptive.** It is the whole reason the
   resumed session does not re-derive the plan. "Continue implementation" forces
   a re-read of everything; "Implement the verdict-render block in
   golem-status.sh; context-budget.sh and its tests are done and green" does not.
   The test is whether a session with **no** memory of this one could act on it
   directly.

1. **End the session** without starting new work. A golem that is mid-step
   finishes that step first — the checkpoint is cheaper to write at a step
   boundary, and a half-finished edit is exactly what `files_modified` cannot
   describe.

1. **Resume.** A fresh `/workflow:next-issue {N}` reads the state file, sees a
   populated checkpoint, and picks up at `next_action`. Inside a worktree, re-enter
   it first — `EnterWorktree({ path: ".worktrees/issue-{N}" })` — exactly as the
   worktree-aware reset suggestion in `state-format.md` describes.

## Why the threshold is 175k

Because it was **derived**, and the derivation is worth knowing before anyone
retunes it (full record + reproduction recipe:
`docs/verification/context-threshold-tally-784.md`):

- **Token cost alone cannot pick a threshold.** It is monotonic — cycling sooner
  always wins, all the way down to the floor. Any number sweep over pure token
  cost returns "cycle immediately", which is obviously wrong.
- **The counterweight is re-derivation work.** Each handoff buys some number of
  re-orientation requests — re-reading the state file, the plan, the files
  already read — that produce nothing. Pricing that in yields a real interior
  optimum.
- **175k is the robust choice, not the point estimate.** Sweeping the handoff
  cost across its whole plausible range, the best threshold moves only
  150k → 200k, and 175k minimizes **worst-case regret** (4.1%, against 6.1% at
  150k and 14.5% at 250k). It is chosen to be least-bad across the uncertainty
  rather than best under one guess.

This **supersedes the 250–300k figure in #784's body**, which assumed a 78k
floor; the measured floor is ~91k. Both knobs are env-overridable
(`CONTEXT_BUDGET_THRESHOLD`, `CONTEXT_BUDGET_FLOOR`), so retuning is a variable,
not an edit — but retune from the derivation, not from a round number.
