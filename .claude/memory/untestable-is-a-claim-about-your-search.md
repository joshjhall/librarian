---
name: untestable-is-a-claim-about-your-search
description: "I couldn't find a way to test this" is a fact about the attempt, not a property of the code — never write it into the source as the latter
metadata:
  type: feedback
---

A failed attempt to test something is evidence about **the attempt**. Writing it
into the source as "this branch cannot be tested" states it as a property of the
code, where the next reader inherits it as settled and stops looking — and a
guard believed untestable is the one someone later deletes as low-value.

**Why:** in #946 a PATH stub was tried, was never invoked, and the conclusion
"untestable" went into a source comment and a verification doc. The real cause
was `BASH_ENV` pointing at a profile that **re-sources and restores `PATH`**,
discarding the stub before the script ran. `--unset=BASH_ENV` fixed it — and the
repo's own harness already used that exact idiom, in the same file, for the same
reason. A reviewer disproved the claim by *running* the stub the draft had only
reasoned about.

**How to apply:** before recording something as untestable, check whether the
harness already solves it (grep the sibling helpers for the mechanism). If the
gap is real, describe **what you tried and why it failed**, never "this cannot be
tested". And when a test does land, mutate the guard to confirm it fails without
it — a vacuous test that reports coverage it lacks is worse than a stated gap.
Related: [[the-correct-copy-is-the-one-under-test]], [[parity-gate-hides-shared-defect]].
