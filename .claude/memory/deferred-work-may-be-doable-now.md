---
name: deferred-work-may-be-doable-now
description: An issue's "wait for Phase N" note is an estimate, not a finding — probe the blocker before accepting the deferral
metadata:
  type: feedback
---

When an issue defers the better option ("prefer option 1 once #838 has
restructured the dispatch"), that deferral is a **prior estimate made while
writing something else**, not a measured constraint. Probe it before accepting
it: build the smallest throwaway prototype of the deferred approach against the
real tree and see whether the blocker actually blocks.

**Why:** on #847 the issue said per-category narrowing needed Phase 1 (#838)
first, because mapping a matrix column to its backing source region supposedly
required the arms to be rewritten. A 20-line probe against all four scanners
showed the mapping worked *today* — binding a column to the arms emitting its
category tag reproduced every matrix exactly in both runtimes. The deferral had
been written by someone reasoning about the code, not measuring it. Accepting it
would have shipped the weaker option 2 and left a live gap until an unrelated
large issue landed.

**How to apply:** when a plan inherits a "blocked on X" claim, spend the ten
minutes to falsify it first, and say in the plan and the commit *why* the
deferral no longer holds — the next reader needs to know the blocker was tested,
not ignored. If the probe confirms the deferral, that is cheap too and the note
is now evidence rather than hearsay. Related: [[exemption-is-a-runtime-claim-measure-it]],
[[surviving-mutation-may-be-a-real-no-op]].
