---
name: moving-a-check-drops-its-freshness
description: "Relocating a guard to fix its ordering silently drops the freshness the old placement gave for free — the old site needs the check too, not instead"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 75f55751-ed5c-4a63-b08a-68720a95fc00
  modified: 2026-08-29T00:35:21.618Z
---

Fixing a check that ran too LATE by moving it EARLIER can drop a property the
late placement provided for free: proximity to the thing it authorizes.

On #813 a dirty-check ran *after* a `git worktree remove` that deregisters the
worktree on failure, so it probed something that no longer existed. The fix moved
it before the removal — correct for the reported bug. But the old code had also
been reading status *inside* the removal-failure branch, immediately before the
`--force` retry, so the force was always authorized by the freshest possible
read. After the move, a tree classified clean, then dirtied, then failing the
plain removal **because of** that new work, would be force-removed on the stale
verdict and the work silently discarded. The comment above the force even
asserted "safe because the tree was already classified clean" — a safety the
code no longer guaranteed.

**Why:** a guard has two properties — WHEN it runs relative to a mutation, and
HOW FRESH it is at the moment of use. An ordering fix attends to the first and
quietly trades away the second, because the old call site disappears from view
once the new one is written.

**How to apply:** when moving a check, ask what the *old* placement was buying,
not only what was wrong with it. The answer is usually "check in both places" —
early enough to survive a mutation that would corrupt the probe, and again
immediately before the irreversible step. When re-adding the late check, route it
through the same filters the early one uses: re-checking with a rawer predicate
re-broke a carve-out that absorbs a known platform false positive, failing every
teardown on the affected platform until the filter was reapplied. See also
[[fix-reintroduces-its-own-failure]] and [[comment-asserts-intent-not-code]] —
the stale comment claiming the old safety is the tell.
