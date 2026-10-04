---
name: cap-stop-is-not-convergence
description: "A review loop that stops on C1-cap has run out of budget, not converged — re-run the predicate uncapped before treating stop as a merge signal"
type: feedback
metadata:
  node_type: memory
  originSessionId: 1ee159fd-a0ac-4290-bd02-ee3f15deda76
  modified: 2026-08-14T17:34:16.420Z
---

`review-convergence.sh check` returning `verdict=stop` does **not** mean the
review converged. Read `rule=` and `capped_over=`:

- `stop` / `C4-zero` — genuine convergence. Merge signal.
- `stop` / **`C1-cap`** with a non-empty `capped_over=` — the loop hit
  `REVIEW_MAX_CYCLES` while the predicate still wanted to continue. **Budget
  artifact, not convergence.**

The disambiguation is free, because the predicate is a pure function of its
inputs: re-run it with a raised `--max-cycles`. If the verdict flips to
`continue`, the cap was masking real signal.

**Why:** a caller reading only `verdict` cannot tell "reviewed to exhaustion"
from "ran out of cycles". Both print `stop`, and merging on the second is
defensible by the letter of the rule and wrong in substance — it is how an
unreviewed defect reaches main with a green-looking audit trail.

**How to apply:** on the last cycle, always re-run uncapped before deciding.
Exhausting `REVIEW_MAX_CYCLES` without convergence is a **dead-end** under the
merge invariant — park the PR for a human at every level, including L4. Weight
the substance too: if every cycle found a blocking defect and severity never
reached zero, "converged" was never a defensible reading regardless of what the
predicate says.

Observed on #673: five cycles, a blocking defect in each, `capped_over=C8-novel`
with `novel=4`; uncapped it returned `continue`. Predicted in advance by the #613
tally's rows 4–5, which flagged this masking and named the uncapped re-run as the
fix. See [[blocking-empty-is-not-nothing-to-fix]] for the sibling failure on the
other side of the same gate.

**The last permitted cycle is the dangerous one.** The cap counts cycles that
*produced a review*, so a blocking finding on cycle `REVIEW_MAX_CYCLES` gets a
local fix that no cycle remains to review — the predicate prints `stop`/`C1-cap`
and the final commit is unreviewed. Open the PR **parked** (`status/pr-pending`,
no auto-merge, even at L3/L4) and name the unreviewed commit SHA in the PR body,
so the human knows exactly what no reviewer saw.

**Budget the terminator.** A clean-but-`C3-narrow-zero` cycle cannot terminate
(a narrow delta proves nothing about the whole) yet still burns a capped slot and
advises `next_scope=full`. When a cycle advises `full` with one cycle left, that
full review is the final word: anything blocking it returns will ship
unreviewed. A defect chain where each fix breeds the next adjacent defect is the
early signal the cap will bind — decide then, not after the last fix.

Observed on #1057 (PR #1112): cycles 1–3 each blocked, each fix spawning the next
defect in a growing state machine; cycle 4 clean but `C3-narrow-zero`; cycle 5's
full review found a fourth. Sibling shape on a different rule:
[[c6-duplicate-stop-can-hold-a-live-defect]].
