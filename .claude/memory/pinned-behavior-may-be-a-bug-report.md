---
name: pinned-behavior-may-be-a-bug-report
description: "A case-table row hedged as \"recorded, not asserted-as-desirable\" is a defect someone chose to pin instead of fix — read those rows as a to-do list, not as settled contract."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 194d7bbb-54ff-4b53-888b-202af055dcb6
  modified: 2026-08-23T19:59:51.246Z
---

When a test pins behavior with a comment hedging that it is **recorded, not
endorsed** — "this is what all three runtimes do", "harmless in practice", "a
fix in one impl would break parity with the other two" — that row is a **bug
report someone deferred**, not a contract. Read it as a to-do, and when the fix
lands, the row and its comment change **with** the code.

Worked example (#778, found while closing #772): `family_prefix` collapsed
`HTTPServer` to `h`, so a decomposition seam proposed `api/h.ts` at HIGH
certainty — confident wrong advice, which is worse than silence. #772's new
case table had pinned `PARSE -> p` with exactly that hedge: the same defect, on
the row where it looked harmless. The parity argument in the comment was true
but pointed the wrong way — it argued against fixing **one** impl, not against
fixing **all three together**.

**Why:** a hedged pin reads as settled, so the defect it documents gets
re-derived from scratch later by whoever hits the non-harmless case. And if the
code is fixed while the comment stays, the comment now asserts the opposite of
the code — [[comment-asserts-intent-not-code]].

**How to apply:** when touching a case table, read the hedged rows first — the
defect may already be written down there. Fixing one means changing the row, its
comment, and every runtime in the same commit; a parity gate exists to make that
simultaneous change safe, not to freeze the wrong answer. Then mutate the impls
**independently**, per [[parity-gate-hides-shared-defect]] — mutating them
together is exactly the blind spot that lets both stay wrong the same way.
