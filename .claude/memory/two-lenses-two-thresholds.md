---
name: two-lenses-two-thresholds
description: A fixture sized to clear the audit lens (300 LOC) leaves the review lens (500) silent — and the mutation survives green
metadata:
  type: project
---

The decomposition **audit** lens and **review** lens have different default LOC
thresholds: audit warns at 300 production LOC (`DECOMP_LOC_WARN`), review at 500
(`REVIEW_LOC_WARN`). Look them up rather than trusting this line — the point is
that they *differ*, not the numbers.

So a parity fixture padded "over threshold" by copying an existing fixture's size
can clear one lens and leave the other emitting **nothing** — and two empty
outputs agree, so the parity assertion passes vacuously. On #754 a 400-line
mixed-case `.TS` fixture killed every `py` mutation and left both `ts`-arm
mutations SURVIVING; the corpus's own `Model.swift` (~330 lines) is sized for the
audit lens only and is the tempting thing to copy.

**Why:** "over threshold" is not one fact. A fixture is non-vacuous per *lens*,
and the suite that runs both will not tell you which one went quiet.

**How to apply:** when adding a fixture meant to produce rows in both lenses,
size it past the **larger** threshold, and prove it with a mutation rather than
by reading the size. Related: [[fixture-must-express-the-divergent-case]],
[[mutation-round-finds-the-untested-rule]].
