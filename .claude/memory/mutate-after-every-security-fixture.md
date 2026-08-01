---
name: mutate-after-every-security-fixture
description: "An injection/collision fixture must be mutation-checked — two of mine passed with AND without the fix (#596)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: e27f9ded-9f74-48fe-ba56-da0a45c3cf33
  modified: 2026-07-31T23:52:59.234Z
---

After writing a security regression fixture (injection, collision, forgery),
**revert the fix and confirm the test fails.** Do not trust that a fixture
exercises the vector just because it was written to.

Two fixtures in #596 were non-differentials until mutation caught them:

1. **C6 newline injection** — I put the newline BEFORE the forged fingerprint, so
   the real `:line:category` suffix landed on the forged line and `grep -x` never
   matched. The payload must come FIRST, newline after.
2. **Colon collision** — I used an arbitrary colon-bearing path, which collides
   with nothing. A delimiter-collision fixture must be a genuine COLLIDING PAIR:
   `file="a.js:10" line=0 cat="x"` vs `file="a.js" line=10 cat="0:x"` — both
   join to `a.js:10:0:x`.

**Why:** an injection fixture is doubly deceptive — it looks adversarial, so it
reads as rigorous, and it passes, so nothing complains. The specific arrangement
of the payload is what does the work, and getting it slightly wrong yields a test
that asserts nothing while looking like it asserts everything.

**How to apply:** for each security fixture, mutate the defence to a no-op and
require the specific test to fail. Also add the complement (that sanitization does
not break legitimate matching), else a mutant that empties every key passes all
the injection tests by making nothing match. Same discipline as
[[anchored-regex-tautological-test]] and [[gate-and-evidence-converge-tautology]].
