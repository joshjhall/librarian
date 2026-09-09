---
name: blocking-empty-is-not-nothing-to-fix
description: "A review cycle returning blocking==[] is not a verdict of \"nothing to fix\" — twice in the #567 batch the DEFERRABLE bucket held a real, confirmed defect"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 1b582930-bded-4097-8522-3105eb5893f8
  modified: 2026-07-31T19:03:57.137Z
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

**Root cause found and fixed (#580, 2026-07-31).** This was not judge caution —
the policy was *unsatisfiable*. BLOCKING required `severity ∈ {critical, high}`
AND non-LOW certainty; DEFERRABLE fired on `severity ∈ {medium, low}` OR
`certainty == LOW`. Producers emit medium/low almost exclusively, so the medium
band was swallowed whole by the deferrable `OR`: **1 blocking firing in 67
findings across 26 cycles**. The fix moved the decision out of judge prose into
`dispositionOf`, an ordered first-match rule list in `ship-issue/workflow.js`;
the judge now returns only observations (re-scored certainty + a `nature`
enum). Severity is demoted to a critical-only carve-out — the discriminator the
missed defects shared was "a live defect in code this PR just wrote", not
severity. A MEDIUM-certainty new-code defect now blocks.

**Why the rule below still stands anyway:** the disposition is now a sound rule
list, but it runs over a *judge's characterization*, and a mischaracterized
finding lands in the wrong bucket with no error. The split is advice about
*scheduling* — "must this PR wait?" — not a substitute for judgement. A defect
the judge calls deferrable can still be one whose whole point is that this PR
was supposed to eliminate it. (Confirmed live on #580's own PR: cycle 1 returned
no blocking findings, and its deferrable-tier notes held a real comment/code
mismatch I had written and a half-finished doc change.)

**Confirmed twice more, 2026-09-09 (4-lane tracks run) — with a new sub-shape:
the defect is in the CHECKER, not the subject.** Both golems were building a
*gate*, and every cycle's findings were about the gate's own fixtures rather
than about what the gate enforces:

- **#899** (PR #981): five review cycles, **every one returned `blocking: []`**,
  and every one still held something real — three genuine defects in cycle 1, a
  defect its own cycle-1 fix introduced in cycle 2, a fixture passing for the
  wrong reason in cycle 4, two dead branches in cycle 5. Not one was a defect in
  what the gate enforces. Shipping on the `blocking: []` label alone would have
  merged all of them.
- **#797** (PR #985): **11 assertions passed while proving nothing** and were
  caught only by mutation. The golem called that, not its headline
  zero-adoption finding, the reusable lesson of the issue.
- **#867** (PR #988), same day, third instance: cycle 1 returned `blocking: []`
  with two deferrable `tests` findings, **both real and both about the new
  gate's own vacuity guards** — a fixture with no arm asserting its purpose, and
  a reporter dispatched through `run_test` that could never fail (the #538/#571
  inert-gate shape, reproduced *inside a PR whose subject is exactly that
  shape*). Fixed rather than deferred; cycle 2 on the fix delta was clean.
  Mutation settled it in both directions — mutating the tracked scanner proved
  the corpus bites, mutating each new guard proved it can fail. Note the guards
  paid off **before** any reviewer saw them: two of the new regexes were wrong
  on their first run and the vacuity guard, not the review, caught them.

Why this sub-shape matters: when the subject under test IS a test, "the suite is
green" and "the suite would notice" are different claims, and a judge scoring
findings against the diff sees only the first. Both golems found their own
fixtures vacuous **by mutating them**, which is the check that separates the two.
So when a PR builds a gate, budget for mutation explicitly — see
[[structural-gate-where-fixtures-dont-scale]] and the test-validity index.

**How to apply:** read every finding on merit, not just the `blocking` array.
Take anything that is a live defect in code the PR itself rewrites, regardless
of disposition, and say in the commit body that you took a deferrable one and
why. Corollary: **a fix commit invalidates the cycle that preceded it** — cycle
N's verdict covers only the bytes cycle N saw, so always re-review after
fixing rather than merging on the earlier clean. This is now documented as a
standing rule in `ship-issue/ci-review-protocol.md` + `pre-ship-validation.md`.
Related: [[issue-580-disposition-rule-list]],
[[issue-553-review-token-ceiling]], [[review-cost-after-2026-07-28]].
