---
name: whole-repo-diff-bounded-by-repo-content
description: "A gate that diffs two impls \"over the whole repo\" only covers shapes the repo contains; absent inputs read as parity"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 5fd8b772-404e-4cce-8dea-13525dc7da6a
  modified: 2026-08-31T18:54:59.286Z
---

A differential gate that compares two implementations across every tracked file
proves agreement **only on the input shapes the tree happens to contain**. An
absent shape is not tested — and the gate still exits green, indistinguishable
from real coverage.

Measured (#836): `check-lifecycle`'s bash and Python `is_test_file` disagreed on
paths under a `test_*`-named directory for ~2 years while
`validate-prescan-differential.sh` reported parity every run. Cause:
`git ls-files | grep -c "/test_[^/]*/"` → **0**. The divergent input did not
exist anywhere in the repo, so the diff had nothing to find.

**Why:** breadth of *files* is not breadth of *behavior*. The corpus is whatever
the repo looks like today, and it silently narrows when the last file of some
shape is deleted — no failure, no log line. Same family as
[[stale-artifact-makes-the-stub-pass]] and the 77-sentinel reasoning: a check
that never really ran must not look like one that passed.

**How to apply:** before trusting a whole-corpus parity/differential gate, ask
*which inputs does this corpus actually contain?* and grep for the shape the
predicate under test discriminates on. If the count is 0, the gate is silent on
exactly the case you care about — write a purpose-built fixture supplying that
shape (see [[fixture-must-express-the-divergent-case]]) rather than adding
another broad sweep. Related: [[parity-gate-hides-shared-defect]] (both impls
wrong the same way also passes green) — the two failure modes are independent,
and a gate can have both.
