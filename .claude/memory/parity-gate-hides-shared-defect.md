---
name: parity-gate-hides-shared-defect
description: A gate comparing two impls to each other passes when both are wrong the same way — same-output is not same-intent
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 16a069af-0c7b-4077-af29-c8e08c876369
  modified: 2026-08-13T21:27:54.598Z
---

A parity gate compares two implementations **to each other**, never to what the
code was supposed to do. A defect present in **both** is therefore invisible by
construction, and the gate stays green for its entire lifetime.

Worked example (#684): the Go no-assertions pattern carried the same wrong
trailing `\b` in `patterns.sh` **and** `patterns.py`, rejecting
`t.Errorf`/`t.Fatalf`/`t.Logf` — Go's dominant assertion idioms — so ordinary Go
tests were reported as having NO assertions at HIGH. `validate-python-ports.sh`
pins byte-identical TSV output and passed throughout, including through all of
issue #679.

**Why:** ports are usually written by translating one impl into the other, so a
bug in the source is *reproduced faithfully*. Faithful reproduction is exactly
what the gate rewards. The same applies to any two-sided check — a golden-file
test regenerated from the code it tests, a snapshot updated to match new output.

**How to apply:** treat a green parity/snapshot gate as evidence of *agreement*,
never of correctness. The catching test asserts the **intended** match against a
hand-written fixture, and lives in the per-detector suite, not the parity gate.
When you fix one side of a port, fix both in the same commit and add the
intent-asserting case — parity will pass either way, so it tells you nothing
about whether the fix was right. Also note the second blind spot: a parity gate
can only compare on the host it runs on, so a divergence that appears only under
another platform's semantics is out of its reach entirely. See
[[gnu-host-cannot-mutate-a-gnu-ism]] and [[comment-asserts-intent-not-code]].
