---
name: upstream-guard-hides-the-branch-under-test
description: "A fixture that arms the condition too early is caught by an upstream guard, so the test passes without ever reaching the branch it names"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 75f55751-ed5c-4a63-b08a-68720a95fc00
  modified: 2026-08-29T00:35:35.395Z
---

A test for a LATE guard can be satisfied by an EARLY one and never reach its
target. On #813 a test for a re-check that runs immediately before a destructive
force dirtied the file *before* invoking the script — so the up-front check
refused it, the run exited, and the re-check never executed. Every assertion
passed (exit 1, work preserved) because the outcome was right; it was reached by
the wrong path. The mutation round is what exposed it: neutering the guard under
test changed nothing.

The same shape appeared twice more in one change: a walk-up test whose fixture
removed an admin dir, flipping a `listed` flag and routing execution into a
different branch entirely; and an absence assertion that could not distinguish
the false claim from its own negation, because both sentences shared their whole
tail (`cannot verify whether X has uncommitted changes` contains
`has uncommitted changes`).

**Why:** defense-in-depth means several guards accept the same input. A fixture
that arms the condition at the top of the pipeline is consumed by whichever
guard sees it first, and a passing assertion says nothing about which one that
was. This is [[gate-and-evidence-converge-tautology]] with distance added — the
fixture does not arm and satisfy the *same* gate, it arms an earlier one.

**How to apply:** to test the Nth guard, the input must be **clean past guards
1..N-1 and only become dirty at N** — which usually means mutating state
mid-run (a stub that acts when the subject calls out to it), not before it. Then
mutate the target guard and confirm red; a surviving mutation on a
freshly-written test means the fixture, not the code. And anchor an absence
assertion on what makes the bad message unique (a sentence start, a prefix), not
on words it shares with the correct one.
