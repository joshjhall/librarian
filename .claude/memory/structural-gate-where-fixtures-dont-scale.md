---
name: structural-gate-where-fixtures-dont-scale
description: When a defect is per-arm across many sites, assert over the SOURCE; the fixture that pins one arm leaves its siblings green
metadata:
  type: feedback
---

A behavioral fixture pins the arms its corpus happens to exercise. When the same
defect can recur **independently at every arm of every site**, that is not enough
and adding fixtures does not fix it — on #754, `split-verify.sh`'s `py` arm was
killed by a new fixture while its `ts` arm reverted green, and pinning all ~68
arms across 11 sites by fixture would have needed a corpus file per language per
site.

The fix is a gate that reads the **source** and asserts the property directly.
It killed 11/11 arms including the one no fixture reached, and immediately found
a site the hand-conversion had missed (`check-code-health`'s third `case` block,
which sat outside both shared regions so the sync gate said nothing about it).

**Why:** fixtures sample behavior; the invariant is over the code. A sampling
test cannot cover a space that grows as sites × arms, and its green result reads
identical to full coverage.

**How to apply:** reach for a structural gate when a defect class is (a) silent,
(b) per-arm/per-site, and (c) spread by copy-paste to new files no fixture scans.
Three things it needs, all mutation-verified, or it becomes decorative:

- **Narrow the rule to the real invariant.** A blanket "no literal `*.ext`
  anywhere" flagged 42 correct lines here (skip-globs, path-prefixed
  classification, comments). Narrowing to *pure language-dispatch arms* left 1.
- **Key exemptions off the other side.** One scanner's python twin matches
  literally, so converting its bash arm would *create* drift — the gate exempts
  it by reading the twin, not by a hardcoded allowlist that would rot.
- **Give it vacuity guards and mutate them.** A parser that stops matching
  reports zero defects and looks exactly like a clean tree. Assert the scan found
  a plausible arm count and a non-empty derived table, then break each on purpose.

Related: [[harden-one-knob-grep-every-sibling]],
[[mutation-round-finds-the-untested-rule]],
[[surviving-mutation-may-be-a-real-no-op]].
