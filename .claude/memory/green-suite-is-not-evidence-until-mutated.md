---
name: green-suite-is-not-evidence-until-mutated
description: An assertion is not evidence until it has been shown to fail; mutate every guard, and re-mutate the whole battery after adding one
type: feedback
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8152d5e8-438d-4142-8f53-05dd43014899
  modified: 2026-09-09T19:46:51.000Z
---

**A passing test proves nothing until you have watched it fail.** Write the
assertion, then break the code it names and confirm it goes red. If it stays
green, the test is decoration — and it will stay decoration through every future
refactor that breaks the thing it was supposed to protect.

Eleven assertions in one PR (#797) passed while proving nothing. Every one was
caught by mutation; **not one** was caught by reading. Four recurring shapes:

1. **The substring appears in the surrounding prose.** `assert_contains "$OUT"
   "no"` matched the letters inside "u**n**anch**o**red" in the report's own
   trailing explanation. Hit four times. *Pin the whole row, never the cell.*
2. **The fixture does not discriminate.** A plain `example.com:8080` was already
   rejected one condition earlier, so the test passed with the guard it named
   deleted. *Solve for the input where the two implementations differ* — see
   [[fixture-must-express-the-divergent-case]].
3. **The bound is too loose to separate the arms.** A 30s ceiling on a
   17ms-vs-8,444ms difference passed under its own mutation. *Measure both arms
   and put the bound between them.*
4. **The harness call was a no-op.** `bash bin/bounded-run.sh 3 …` returns 0
   without running anything — that file is *sourced* and provides a function.
   *Verify the tool ran at all before trusting what it reported.*

**The compounding trap: adding a guard can silently disarm an existing test.**
A path-separator check landed ahead of an extension check, so the
extension-check fixture was rejected earlier and its test passed with the
extension check reverted. So **re-run the whole battery after every change**, not
just the mutation for the new guard. That is what turned this from ten findings
into eleven.

**Why:** five adversarial review cycles found a blocking defect each, and two of
them were regressions the previous cycle's fix introduced. Ad-hoc patching of one
predicate produced seven errors in both directions before it was replaced with a
single regex stating the shape once. Incremental guards each fix one shape and
break another; a structural statement is checkable at a glance.

**How to apply:** mutate each guard independently and name which assertion caught
it — if two mutations trip the same test, one guard is untested. Before spending
another cycle on a predicate, **measure its reach**: forcing that function to
return a constant changed no conclusion in the document it fed, which reframed
"fix it again" as "record the scope and move on". Related:
[[measured-zero-needs-a-denominator]], [[cap-stop-is-not-convergence]].
