---
name: one-tool-two-answers-for-one-file
description: Two passes in one scanner classify the same file differently — one hardcodes, the sibling reads config — and the false rows land in a baseline as accepted debt
metadata:
  type: feedback
---

When one tool makes the same classification in two passes, check whether both
use the same predicate. A pass that **hardcodes** what its sibling reads from
**config** makes the tool disagree with itself about one file, and the wrong
answer is indistinguishable from real debt.

Measured (#696): `check-okf-conformance`'s conformance pass routed on the literal
`case index.md`, while its own slice-B graph pass partitioned indexes with the
configurable `is_index()`/`read_index_names()`. So `MEMORY.md` was an *index* to
one pass and a *malformed concept* to the other — the concept path demands the
frontmatter OKF §8 says an index must not carry. All **6** baselined
`okf-unparseable-frontmatter` findings were that false positive (`MEMORY.md` plus
five `index-*.md`); **zero** were genuine. The fix was to call the predicate that
already existed twenty lines away, and the baseline went 6 → 0.

**Why:** three independent things hid it. The defect was identical in both
runtimes, so the byte-parity gate passed it green
([[parity-gate-hides-shared-defect]]). Every graph fixture asserted through a
**category filter**, and the spurious row was a *different* category than the one
each test was looking at — so no fixture could see it. And the rows had been
frozen into a baseline, which reads as "known debt someone triaged", not "the
detector is wrong".

**How to apply:** when a scanner has two passes over one corpus, grep for the
classification in both and make the narrower one call the broader one's helper —
a hardcoded list beside a configurable sibling is the smell, and the fix is
usually a one-line substitution, not a new rule. Assert it with an **unfiltered**
whole-output fixture (`assert_no_rows`, not per-category), because a filtered
assertion reproduces exactly the blindness that let it ship. Mutate each runtime
**separately**: a shared defect means same-output parity cannot be your evidence.
And treat a baseline as a claim to audit, not a settled fact —
[[measure-suppression-before-keeping-it]] and
[[pinned-behavior-may-be-a-bug-report]].
