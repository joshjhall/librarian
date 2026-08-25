---
name: absence-assertion-needs-a-leak-fixture
description: A test asserting something is ABSENT passes trivially when its predicate breaks — pin it with a synthetic fixture that must be detected
metadata: 
  node_type: memory
  type: feedback
  originSessionId: af6b1b7a-db5d-4281-8295-44415867b420
  modified: 2026-08-25T03:47:28.494Z
---

An assertion of the form `ok(!text.includes(MARKER))` — "this string has not
leaked in" — is green against clean source **and** green when the predicate is
broken. If the text-extraction step silently stops producing text (a regex that
eats the string literals, a slice that returns ""), the check matches nothing,
forever, and nothing announces it. The absence is real; the *checking* is gone.

This is distinct from the tautological-fixture family ([[gate-and-evidence-converge-tautology]],
[[anchored-regex-tautological-test]]): there the fixture fails to arm the gate.
Here there is no fixture at all — the assertion's failure path is never walked.

**How to apply.** Extract the predicate into a named function and pin it in both
directions with synthetic strings:

```js
const leaks = (js, markers) => markers.filter(m => stripComments(js).includes(m))
eq(leaks(SYNTHETIC_LEAKED, MARKERS).length, 2, "has teeth: a leak IS detected")
eq(leaks(SYNTHETIC_CLEAN,  MARKERS).length, 0, "is narrow: near-misses do NOT trip")
```

The *narrowness* half matters as much as the teeth. A guard that also fires on
correct, desirable edits gets deleted by the next person it annoys, and then
catches nothing — so pin the near-miss it must tolerate, not only the hit it must
catch.

Two traps hit while doing exactly this (#785, `tests/workflow-helpers/delegation.mjs`):

- **Re-implementing the function's logic inside the test proves only that the
  copy matches itself.** Fixing "the rethrow is untested" by pasting its `if` into
  the test body is the same tautology in a new place. Add a seam instead — a
  default parameter (`reader = p => readFileSync(p)`) lets a test inject the error
  and drive the *real* function.
- **Mutating the extraction can be a no-op against a fixture that never contained
  the thing being stripped.** An over-broad `//`-comment strip "survived" against
  a fixture holding no `//` at all. Trace a survivor before believing it
  ([[surviving-mutation-may-be-a-real-no-op]]); the real mutation was a strip that
  ate string literals, and that one failed correctly.

Related: [[measure-suppression-before-keeping-it]],
[[mutation-round-finds-the-untested-rule]],
[[concat-boundary-defeats-phrase-matcher]].
