---
name: collect-all-test-assertions-must-not-throw
description: "tests/validate-workflow-helpers.mjs is collect-all (ok/eq push to failures, never throw) — a bare property access on a missing entry throws a TypeError that aborts the whole run and masks every later assertion; use optional chaining"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f7727210-6758-48e9-8623-221d5189530e
  modified: 2026-07-29T02:33:36.826Z
---

`tests/validate-workflow-helpers.mjs` uses a **collect-all** assertion harness:
`ok(cond, msg)` pushes to a `failures[]` array and `eq()` delegates to it —
neither ever throws. The run reports every failure at the end
(`✗ N workflow-helper assertion(s) failed:`).

That contract is easy to break from the *outside*. A new assertion that reaches
into a possibly-missing result — `byName["security"].diff` when the whole point
of the test is that the entry may be absent — throws a raw `TypeError` before
`eq()` is ever called. Node aborts the module, so the harness prints a stack
trace instead of its failure list and **every later assertion in the file
silently never runs**.

Caught while writing the #529 regression tests (PR #565): the missing-entry case
was exactly the bug being pinned, so the "failing" direction was the common path,
not the exotic one.

**Why:** a test that aborts the run is strictly worse than one that fails — it
converts one known failure into an unknown number of unrun siblings, and the
output no longer tells you which.

**How to apply:** in any assertion whose subject may legitimately be missing, use
optional chaining (`byName["security"]?.diff`) or `.find(...)?.field` so the
lookup yields `undefined` and `eq` *records* the failure. Verify a new regression
test by actually reverting the fix and confirming the run prints the collect-all
failure list — not a stack trace. Related: [[test-workflow-js-pure-helpers]].
