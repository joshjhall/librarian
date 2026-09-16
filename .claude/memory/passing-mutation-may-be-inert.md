---
name: passing-mutation-may-be-inert
description: "A mutation that passes means the test is weak OR the mutant never reached the changed line — read the mutated source and confirm reachability before concluding 'no coverage'"
type: feedback
metadata:
  node_type: memory
  originSessionId: fa608522-9973-4620-9bbb-8ebcd928aaf8
  modified: 2026-09-16T21:18:25.719Z
---

When a mutation **passes**, there are three distinct explanations and they demand
opposite responses:

1. **The test is weak** — write the assertion. (The usual assumption.)
2. **The mutant is inert** — an earlier guard makes the changed line unreachable
   in the fixture, so nothing was actually mutated. Fix the *mutant*.
3. **The mutant is equivalent** — provably the same behavior, so no test can
   distinguish it ([[surviving-mutation-may-be-a-real-no-op]]). Write nothing.

Only reading the mutated source tells them apart. A green result looks identical
in all three.

Both non-obvious cases showed up in one session (#934):

- **Inert.** Reverting a first-link-only loop to its pre-fix shape passed. The
  mutated `break` was never reached: a `case ... *) continue` two lines above
  still skipped the non-moving link, so the fixture exercised an unchanged path.
  The *faithful* pre-fix shape — restoring the whole branch, not just the line I
  had edited — reds the fixture immediately.
- **Equivalent.** Swapping a first-occurrence replacement for replace-all passed,
  and correctly so: the caller emits one row per occurrence, so N single
  replacements and one replace-all produce the same string. Recorded in the
  fixture as an equivalent mutant rather than left implied — and the comment says
  what the single replacement *does* buy (termination: a naive replace-all that
  rescans its own output hangs whenever the new value contains the old).

**Why:** a mutation round is an experiment, and a passing result is only evidence
about the test if the experiment ran. Mutating the line you happen to have
touched is not the same as restoring the prior behavior — guards, early
`continue`s and short-circuits routinely make a one-line revert a no-op.

**How to apply:** when a mutation passes, print the mutated region and trace the
fixture through it before touching the test. Prefer reverting a whole branch to
its pre-fix shape over flipping one line. If the region is genuinely unreachable
from any fixture, that is itself the finding. And write the verdict down: a
future reader seeing a mutant survive will otherwise redo the analysis, or worse,
add a test that cannot fail ([[anchored-regex-tautological-test]]).

Related: [[crashed-mutation-reads-as-survivor]] (a mutant that fails to *run*
reads as surviving), [[asymmetric-mutation-reads-as-untested]],
[[mutation-restore-must-not-be-git-checkout]].
