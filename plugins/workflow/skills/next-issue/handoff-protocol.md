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
literal path and `.`:

```bash
<skill-base-dir>/../../scripts/context-budget.sh check .
```

Substitute `<skill-base-dir>` with the literal path from your invocation header
(`Base directory for this skill: …`). `.` is safe because the session's cwd **is**
the worktree being measured, and the script normalizes a trailing `/.` or `/`
before deriving the transcript slug (#809).

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

## Where the check runs

**At every pipeline boundary a golem passes — not only at reset points (#1057).**
The check used to live only in `golem/SKILL.md` § Phase C, which an orchestrated
golem never loads (it launches as a bare `/workflow:next-issue N --level L`), and
the L3–L4 exception in `state-format.md` § Reset Points bypasses every reset
point. Measured: five golems ran to 170k–400k and executed the check **zero**
times. So the check is pinned to three sites every golem executes, each marked
`budget-check-site` and enforced by `tests/lint-budget-check-sites.sh`:

| site | where |
| --- | --- |
| `plan-approved` | `phase2-plan.md` — before implementing |
| `impl-done` | `phase2-plan.md` — before invoking `/workflow:ship-issue` |
| `review-cycle` | `ship-issue/ci-review-protocol.md` — after each cycle's fixes |

The L3–L4 exception skips the `/clear` **suggestion**; it never skips this check.

**After every check, print exactly one line** — this is what makes an unknown
reading visible instead of indistinguishable from `ok`:

```text
context budget: <verdict> (<pct_of_threshold>% of threshold)
context budget: UNKNOWN (exit <n>) — proceeding
```

**Who acts.** A golem — a session launched with `GOLEM_ID` set, or a
`/workflow:golem` run — acts on `handoff` per § "The handoff" (write the
checkpoint **with `handoff_marker`**, then end the turn). Every other session
prints the line and continues (§ "Interactive sessions are advised, never
cycled").

**The fresh session is the orchestrator's job.** A model cannot exit its own
`claude` process, so ending the turn leaves the golem idle at its prompt. The
orchestrator's sweep detects that and relaunches it (`/clear`, then
`/workflow:next-issue N --level L`) via `golem-handoff-relaunch.sh` — see
`orchestrate/monitor-protocol.md`. The `handoff_marker` is what that detector
keys on: without it, a large golem parked at a human gate would look identical
and be cleared. **Never omit the marker on a handoff.**

**Resuming without an orchestrator.** A solo `/workflow:golem` run has no sweep
to relaunch it, so the operator does: resume with `/workflow:golem N` from the
main checkout (its collision guard re-enters the worktree, #1059), or
`/workflow:next-issue N` if still inside the worktree. Either way the fresh
session starts at the ~104k floor (#1056) instead of at 400k, and the
checkpoint's `next_action` is what stops it re-deriving the plan.

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
   populated checkpoint, and picks up at `next_action`. For a worktree run, prefer
   `/workflow:golem {N}` from the main checkout (it re-enters the worktree), with
   `EnterWorktree` + `/workflow:next-issue {N}` as the fallback — exactly as the
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
floor. Both knobs are env-overridable (`CONTEXT_BUDGET_THRESHOLD`,
`CONTEXT_BUDGET_FLOOR`), so retuning is a variable, not an edit — but retune from
the derivation, not from a round number.

**Re-derived on a 1M-era corpus (#1056), and 175k held.** #784's inputs were
measured under a 200k window. Re-running its method on current `claude-opus-5`
sessions kept the threshold and moved the floor to **104k** (it is bimodal by
session shape — ~84.4k main checkout vs ~104.4k worktree/golem). The threshold
survived for two reasons: the window is not an input to a *cost* optimum, and
the raised floor narrows the working band to 71k, so cycling sooner would roughly
double the handoff count for ~1.5pp of modeled saving. Record:
`docs/verification/context-threshold-rederivation-1056.md`.

## Recording `R` at a handoff

`R` — the re-orientation requests a handoff spends before productive work
resumes — was **swept** in #784 because nothing measured it, and the sweep is
why minimax was needed at all. A handoff now records what it cost, so the next
re-derivation looks the number up instead.

**No new state format** (see § "The handoff"): this is one optional field on the
`checkpoint` object, the same way `scope_expansions` was added for #756.

1. **Writing it.** When you act on a `handoff` verdict, copy the
   `context-budget.sh check` output that produced it into
   `checkpoint.handoff_marker` — `context_tokens`, `threshold`, `floor`,
   `pct_of_threshold`, and an ISO timestamp `at`. This is data already in hand;
   take no new measurement. Set `r_measured` to `null`.
1. **Filling it in.** A resumed session that finds a `handoff_marker` with
   `r_measured: null` is the only place that can close the loop. **Count from
   your first request**, and freeze the count at your first file-modifying
   request — `R` is everything before it: re-reading the state file, the plan,
   and files the prior session already read. Write the number to `r_measured`
   with a one-line note on what the re-orientation consisted of.
1. **Do not reconstruct it afterwards.** A count recalled once the work is
   underway is an estimate, not a measurement. If you lose it, write `null` and
   say so — an honest gap beats an invented number.
1. **Fail open.** A missing or malformed `handoff_marker` means "R unknown for
   this handoff" and **nothing else**. It must never error, block a resume, or
   gate the handoff it observes; it is telemetry riding along on a checkpoint
   that has a job to do.
