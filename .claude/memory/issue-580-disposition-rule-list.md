---
name: issue-580-disposition-rule-list
description: "#580 — the judge's blocking/deferrable prose policy was unsatisfiable (1 firing in 67 findings); replaced by dispositionOf, an ordered rule list over a judge-supplied `nature` enum"
metadata: 
  node_type: memory
  type: project
  originSessionId: 66a3c753-a2a9-4782-8d07-e66d16b78285
  modified: 2026-07-31T19:04:12.616Z
---

**#580 (shipped 2026-07-31).** `ship-issue/workflow.js`'s judge used to return a
`disposition` directly, applying two overlapping prose rules. BLOCKING needed
`severity ∈ {critical, high}` AND non-LOW certainty; DEFERRABLE fired on
`severity ∈ {medium, low}` **OR** `certainty == LOW`. Producers emit medium/low
almost exclusively, so the medium band was claimed in full by the deferrable
`OR` — `blocking` fired **once in 67 findings across 26 cycles**, and since
`clean` is computed from `blocking == []` and L4 auto-merges on clean + green
CI, the merge gate was effectively unguarded.

**The fix, and the transferable idea:** split *observation* from *decision*. The
judge now returns only what it can observe — the re-scored certainty plus a
`nature` enum (`defect-in-new-code` / `defect-in-preexisting-code` /
`incomplete-work` / `improvement`) — and a pure helper `dispositionOf` computes
the disposition via an **ordered first-match rule list** (R1–R8) whose last rule
is unconditional, so the policy is total and non-overlapping by construction.
Severity is demoted to a critical-only carve-out.

**Why:** an LLM applying prose cannot be unit-tested, so an unsatisfiable policy
has no failure mode — it just quietly returns a constant. A rule list in code
can be mutation-tested. That is what made #580's calibration gate possible at
all; the issue asked for the gate, but the gate is unbuildable without first
moving the policy into code.

**How to apply:**

- When a gate's verdict comes from a model, ask what it can *observe* vs what it
  must *derive*. Ask for the observation; compute the derivation.
- **Demote the axis producers don't populate.** Adding clauses to a predicate
  gated on an unpopulated field cannot fix it — the clause count was never the
  problem. Check the actual distribution first.
- A calibration gate must pin the cell at the *observed* distribution, not just
  "some input blocks". Asserting non-emptiness would have passed the old policy
  too via its critical row — the tautology trap in
  [[gate-and-evidence-converge-tautology]]. The mutation check is the proof:
  reverting `dispositionOf` to the old predicate fails 12 assertions.
- Review found two real defects in the deferrable tier of this PR's own review,
  including a comment claiming coverage the tests didn't have — the
  [[comment-asserts-intent-not-code]] pattern, now 4×. See
  [[blocking-empty-is-not-nothing-to-fix]].
