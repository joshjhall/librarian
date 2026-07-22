---
name: grep-c-zero-count-exit-1
description: "grep -c exits 1 on a zero count (not an error) — a `|| fallback` double-appends; count with grep -o | wc -l instead"
metadata: 
  node_type: memory
  type: reference
  originSessionId: bc646c9d-c374-405f-9c2e-5183bd04bb68
  modified: 2026-07-22T00:46:23.514Z
---

GNU `grep -c PATTERN` prints the count (including `0`) but **exits 1 whenever
the count is zero** — a documented quirk, not an error. So the common idiom
`n="$(... | grep -c PATTERN 2>/dev/null || echo 0)"` is **buggy at zero**: grep
prints `0` AND exits 1, so the `|| echo 0` fallback *also* fires, and `n` becomes
the two-line string `0\n0`. Downstream that splits a rendered line in two.

Caught in #488 (golem-status heartbeat `(N golem(s))` count): the zero-golem +
pool.json idle case rendered `— no change since HH:MM (0\n0 golem(s))`. Fix =
count occurrences without leaning on grep's exit status:
`n="$(... | grep -o PATTERN | wc -l | tr -d ' ')"; [ -n "$n" ] || n=0`.

The adversarial pre-PR review (workflow.js harness) found this by **executing**
the script with the empty-pool fixture — the six original tests all planted ≥1
row so the zero path was never exercised. Lesson: a count-path test needs an
explicit **zero** fixture. See [[test-assert-blocked-list-not-feed-echo]] for the
sibling "assert the render form, not a substring" discipline.
