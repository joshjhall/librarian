---
name: crashed-mutation-reads-as-survivor
description: A mutation harness that treats "suite passed" as survival reports an un-applied mutation as an untested arm; assert the edit landed
metadata:
  type: feedback
---

In a mutation round, "the suite passed" means **survivor** only if the mutation
was actually applied. A loop that mutates via a helper which can `raise` (an
`assert count == 1` that fails because the literal also appears elsewhere in the
file) leaves the source **unmutated**, the suite passes on correct code, and the
harness reports `SURVIVED (untested!)` for an arm that is in fact well covered.
Measured: 2 of 8 arms reported as survivors were both harness crashes; scoping
the replacement to the one dict literal killed all 8.

**Why:** the harness conflates two very different states — "mutation applied and
undetected" (a real coverage gap) and "mutation never applied" (a broken tool).
Both present as exit 0. Chasing the false ones wastes a cycle; worse, a real
survivor hidden among them gets dismissed as another crash.

**How to apply:** make the mutation step **fail loud and separately** from the
test step — check the helper's exit status, or diff the file against its snapshot
and abort if unchanged — before running the suite. Read the harness's own stderr,
not just its verdict line. And restore from a snapshot copy, never
`git checkout` ([[mutation-restore-must-not-be-git-checkout]]). Related:
[[asymmetric-mutation-reads-as-untested]],
[[surviving-mutation-may-be-a-real-no-op]].
