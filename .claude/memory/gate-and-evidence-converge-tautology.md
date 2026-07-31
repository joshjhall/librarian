---
name: gate-and-evidence-converge-tautology
description: A test where one fixture both ARMS a gate and SATISFIES it passes either way — the two branches converge on the same output
metadata: 
  node_type: memory
  type: feedback
  originSessionId: ab1d6887-91ec-4575-876c-79691dad387e
  modified: 2026-07-31T01:01:15.274Z
---

A second, distinct tautology shape from [[anchored-regex-tautological-test]].
There the fixture never reached the detector. Here it reaches it fine — but the
same fixture plays **both roles**, so both branches produce identical output.

On #600 the go arm's `*/fixtures/*` exclusion test put a single
`tests/fixtures/sample_test.go` naming the symbol, and asserted no row:

- **with** the exclusion → the candidate list is empty, the conservative gate is
  never armed → no row
- **without** it → the fixture arms the gate *and* satisfies the symbol → no row

Same result, so the assertion held either way. `assert_output_empty` on a
scanner with a **precondition gate** is the smell: emptiness has two causes, and
the test cannot tell which one it observed.

**Why:** a two-stage scanner (gate → evidence) needs the gate armed by something
*other* than the artifact under test, or the test collapses. This is why the fix
was to add a separate real `tests/real_test.go` that arms the gate while naming a
different symbol, leaving the fixture as the only mention of the one asserted.
Note the assertion also flipped from "no row" to "row FIRES" — a positive
assertion about the symbol is far harder to satisfy vacuously.

**How to apply:** when a scanner has a gate, ask *"what else in this fixture
tree could produce this same output?"* before trusting a passing case. Then
mutation-test it — that is what caught this one; the case passed with the
exclusion deleted. If a mutation leaves a case green, the case is the bug, not
the mutation. See [[comment-asserts-intent-not-code]] and
[[blocking-empty-is-not-nothing-to-fix]].
