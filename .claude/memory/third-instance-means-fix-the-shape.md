---
name: third-instance-means-fix-the-shape
description: When review finds the same class of defect a third time, stop patching instances and change the structure that keeps producing them
metadata:
  type: feedback
---

Review cycles hand back *instances*. Two of a kind is a coincidence; **the third
instance of one class means the structure is generating them**, and patching the
third the way you patched the first two guarantees a fourth.

Worked example (#838). Adding per-language lexical gating to `check-security`
narrowed which files a detector would scan. Three consecutive review cycles each
found one more group that had silently lost coverage:

1. config formats (`.yml`, `.ini`, `.env`)
2. the C-family (`.php`, `.c`)
3. "add `.json`"

I fixed 1 and 2 by appending those extensions to the table. The correct response
to 3 was not to append `.json` — it was to ask **how many more are there**. A
52-extension probe against `origin/main` answered it: **32 more**, including
`.tf`/`.tfvars` (Terraform), `.ps1`, `.pl`, `.lua`, `.sql`, `.vue`. The reviewer
had found three of thirty-five, one per cycle, and would have kept finding them.

The shape fix: key the table on the **comment marker** rather than the language,
because the marker *is* the lexical fact. Adding a language then means choosing
an existing family instead of discovering a gap.

**Why:** patching instances converges at one-per-cycle while the class stays
open; each cycle costs a full review and the gap is live the whole time.

**How to apply:** when a review finding matches the shape of one you already
fixed, do not fix it in place. First **measure the class** — enumerate the whole
input space the change touched and diff old-vs-new behavior across it (a probe
script over every extension / every arm / every config key). The count tells you
whether you have an instance or a class. Then re-key the structure on whatever
property the instances share, and write a **table-driven** test over that
property so the next member is covered on arrival rather than on discovery.

Corollary: a narrowing change (a gate, a filter, a new dispatch) needs a
whole-input-space differential *before* review, not after. All three findings
would have surfaced at once from the probe I eventually wrote.

Related: [[harden-one-knob-grep-every-sibling]],
[[survey-scoped-to-a-glob-misses-a-plugin]],
[[structural-gate-where-fixtures-dont-scale]],
[[blocking-empty-is-not-nothing-to-fix]]
