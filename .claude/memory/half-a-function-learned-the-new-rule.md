---
name: half-a-function-learned-the-new-rule
description: "After widening a traversal, grep the SAME function for sibling loops still walking the old, narrower set — the second loop keeps the old scope and its silence reads as a pass"
type: feedback
metadata:
  node_type: memory
  originSessionId: fa608522-9973-4620-9bbb-8ebcd928aaf8
  modified: 2026-09-16T21:18:42.440Z
---

When you widen **what a pass walks** — root-level to recursive, one directory to
many, one file type to several — the change lands in the loop you were looking
at. Any *sibling* loop in the same function keeps the old, narrower set, and its
silence on the newly-visible items reads exactly like a clean result.

Worked case (#934, `bundle_graph.scan_bundle`). I taught the **graph** half of
the function (orphan / dangling / multi-index) to walk subdirectories, which was
the whole point of the change. The **health** half — staleness and per-type body
requirements — sat forty lines below in the same function, still iterating the
root's concepts only. So a concept stopped being health-checked the moment it was
filed into a directory, which is precisely what the transform being shipped does
to an entire bundle. Measured on the real bundle: **80 findings became 1, at exit
0**. No fixture caught it; the suite's healthy-bundle case only asserted *zero
rows*, so reverting the eventual fix was invisible until positive nested cases
were added.

**Why:** this is [[harden-one-knob-grep-every-sibling]] and
[[third-instance-means-fix-the-shape]] at their tightest radius — not a sibling
file or a sibling call site, but a sibling *loop inside the function you are
editing*. That closeness is what defeats the usual instinct to go look elsewhere,
and it is why "I only changed one function" is not a defense. Note also who wrote
it: two earlier cycles on that same PR had flagged this exact shape in code I was
*reviewing*, and I then committed it in code I was *writing*.

**How to apply:** after changing the set a pass enumerates, grep the enclosing
function (and file) for every other `for`/`while` over the old collection, and
ask of each whether the new members belong in it. Where the answer is yes, feed
them the same collection. Where it is no — a deliberate boundary, like "a
directory with no index has not adopted the routing scheme and is not judged" —
write the boundary down as a comment and give it its own negative fixture, or the
next reader cannot tell a decision from an oversight.

And distrust a metric that *improves* after a widening. Fewer findings looks like
progress; here it meant the checker had stopped looking
([[dry-run-against-real-data]], [[vacuous-scan-reads-as-a-clean-verdict]]).
