---
name: review-fix-is-the-riskiest-code
description: Code written to fix a review finding is the most defect-dense code in a PR — review the fix at least as hard as the original
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 1ee159fd-a0ac-4290-bd02-ee3f15deda76
  modified: 2026-08-14T17:34:29.282Z
---

A fix commit written under review pressure is **more** likely to carry a defect
than the code it fixes. Treat each fix delta as new, unreviewed code — never as a
verified correction.

**Why:** the original code was written deliberately; the fix is written fast,
narrowly targeted at one finding, usually without re-checking the surrounding
invariants — and it inherits the reviewers' attention *least*, because everyone
has already formed the view that this area was just examined.

**How to apply:**

- Tell the next cycle's reviewers explicitly which commits are fixes and that
  they are the highest-risk part of the diff.
- Mutation-check every fix (revert it; its test must fail). A fix without a test
  that binds is indistinguishable from no fix.
- When a fix adds a **documented recipe**, hold it to a higher bar than internal
  code: prose is meant to be run verbatim, so an unsafe idiom propagates. Check
  it against how the repo's own scripts already do that operation.

Observed on #673: of five blocking defects across five cycles, **two were
introduced by the previous cycle's fix** — a `/tmp` symlink race in a recipe the
prior fix added, and a defect in a file three fixes had already touched. This is
the mechanism behind the standing "a fix commit invalidates the prior cycle's
clean read", and it is why each cycle earns its own tally row rather than being
folded into the last.

Related: [[cap-stop-is-not-convergence]] (the loop can exhaust its budget on
exactly this churn), [[harden-one-knob-grep-every-sibling]] (what the hurried fix
typically misses).
