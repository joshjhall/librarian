---
name: stale-artifact-makes-the-stub-pass
description: "A test whose stub produces no output passed locally only because a real earlier run had left the output file behind; CI, with a clean tree, failed"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 26ef5638-3597-4602-8550-bb61f308f37a
  modified: 2026-08-23T17:17:35.957Z
---

A gate that drives a script with a **stub** tool can pass locally for a reason
that has nothing to do with its assertion: an **earlier real run left the output
artifact on disk**, and the script's "did it produce output?" check found *that*
file. CI checks out clean, the stub produces nothing, and the same test fails.

Concretely (#748): `validate-coverage-runner.sh` ran `coverage-python.sh` with a
stub `coverage` that answers `--version` and exits 0 without writing data. The
script then failed at `coverage.xml is empty` — legitimately. Locally a stale
`coverage.xml` from my own earlier real runs satisfied that check, so the test
was green through several rounds and only went red on CI.

**Why:** the assertion was also too broad — `assert_not_contains "[FAIL]"` could
not distinguish *"the flag I am testing fired"* from *"the stub produced no
data"*: two different failures wearing the same string. A stale artifact plus a
string-matching assertion is a passing test that verifies nothing.

**How to apply:** when a test stubs a tool whose real job is to WRITE something,
delete that output first and re-run — `rm -f <artifact> && <gate>` — before
believing a green. And assert the specific diagnostic (the one naming the flag or
branch under test), never the generic failure marker, so an unrelated later
failure cannot masquerade as the condition being asserted. Related:
[[gate-and-evidence-converge-tautology]], [[measure-suppression-before-keeping-it]],
[[self-skipping-test-hides-the-risky-branch]].
