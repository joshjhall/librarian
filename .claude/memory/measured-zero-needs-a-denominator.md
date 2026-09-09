---
name: measured-zero-needs-a-denominator
description: A measurement returning zero must distinguish absent-from-zero and carry a denominator, or it is unfalsifiable
type: feedback
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8152d5e8-438d-4142-8f53-05dd43014899
  modified: 2026-09-09T19:46:51.000Z
---

When a measurement's headline result is a **zero** — "no X happened" — that zero
is the claim most likely to be an artifact of the counter, and it needs two
things a non-zero result does not.

**1. Absent must not read as zero.** A tool that finds nothing must exit a
distinct non-zero status (3, or the 77 sentinel for an unavailable runtime), never
0 with "count: 0". An empty corpus, a wrong root, a mis-keyed classifier and a
genuine zero all produce identical output otherwise — and only the last is
evidence. Assert this in the gate: it is the single most important test in a
zero-reporting tool. Same shape as the silence-reads-as-a-pass family
(#538/#571) and [[detector-must-fail-open-on-its-own-failure]].

**2. A zero needs a denominator.** "Nobody did X" is equally consistent with
"nobody had occasion to". Measure the opportunities alongside the occurrences:
zero against zero is a quiet sample, zero against many is a finding. Without the
denominator the result cannot be acted on and cannot be argued with.

**And say what the zero does NOT establish.** At n=0 a question is *untested* — a
third state distinct from both "held" and "did not visibly break". Recording
either of those is a false claim about work that did not happen. Related:
[[blocking-empty-is-not-nothing-to-fix]].

**Why:** #797 measured whether the #785 delegation guidance was being followed and
found zero delegated investigations. The boring explanations (looked in the wrong
place, classified everything into one bucket) produce byte-identical output to the
real finding, so the zero was worth nothing until the tool could rule them out. It
became a finding only once 49 qualifying-but-not-delegated opportunities sat
beside it.

**How to apply:** Ship the count as code, not a hand tally — a second reader must
be able to re-derive it. Mutation-test the classifier against a fixture holding
**both** kinds in equal number: one stuck on a constant reproduces a lopsided real
corpus by accident and passes a test built on it. The denominator arm must not be
gated on the numerator's precondition either — keying "opportunities" on
spawns-existing would suppress the evidence in exactly the zero case it is for.
