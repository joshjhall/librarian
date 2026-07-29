---
name: blocking-empty-is-not-nothing-to-fix
description: "A review cycle returning blocking==[] is not a verdict of \"nothing to fix\" — twice in the #567 batch the DEFERRABLE bucket held a real, confirmed defect"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 1b582930-bded-4097-8522-3105eb5893f8
  modified: 2026-07-29T14:42:14.791Z
---

The `/ship-issue` review harness returns `{blocking[], deferrable[], clean}`.
`clean` is the skill's termination signal, so it is tempting to read
`blocking: []` as "review found nothing that matters" and go straight to merge.
**That reading has been wrong twice in a row**, in consecutive issues of the
measurement batch for #567:

- **#544** (PR #572): cycle 1 clean. Cycle 2 — on the *fix commit* — returned a
  HIGH-certainty finding that the new bounded-probe test never exercised the
  bound (`stub_dir` had no `timeout` symlink, so every case took the unbounded
  branch). Merging on "cycle 1 clean + CI green" would have shipped an untested
  bound.
- **#549** (PR #574): cycle 1 returned `blocking: []` with 2 deferrable. One of
  them, at HIGH/0.92, was a **live parity defect in the code the PR itself
  rewrites**: the `IFS=:` → bare `read -r raw` change traded a trailing-colon
  strip for a trailing-whitespace strip. Confirmed by hand in minutes; fixed at
  all 78 sites. See [[check-docs-staleness-ifs-colon-parity]].

**Why:** the judge's blocking/deferrable split is advice about *scheduling* —
"must this PR wait?" — produced by an agent that does not know which lines the
PR exists to change. It is an input to judgement, not a substitute for it. A
defect the judge calls deferrable can still be one whose whole point is that
this PR was supposed to eliminate it.

**How to apply:** read every finding on merit, not just the `blocking` array.
Take anything that is a live defect in code the PR itself rewrites, regardless
of disposition, and say in the commit body that you took a deferrable one and
why. Corollary: **a fix commit invalidates the cycle that preceded it** — cycle
N's verdict covers only the bytes cycle N saw, so always re-review after
fixing rather than merging on the earlier clean. Related:
[[issue-553-review-token-ceiling]], [[review-cost-after-2026-07-28]].
