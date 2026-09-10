---
name: surviving-mutant-may-be-a-noop
description: A mutant that survives may never have changed behavior — check the mutation is reachable and not overwritten before blaming the test
metadata:
  type: feedback
---

A surviving mutant is **two** hypotheses, not one: the test is weak, OR the
mutation never took effect. Check the second before rewriting the test.

Measured (#870, `measure-spawn-prefix.py`): a mutant that read spawn identity
from the transcript's first record instead of its first *billed* turn survived
the new test twice. Both survivals were false alarms, of different kinds:

1. **Overwritten.** The mutation set `session`/`started` early, but the original
   assignment two lines later ran unconditionally and overwrote them. Diffing
   the mutant's *output* against the original's showed byte-identical reports —
   the code changed, the behavior did not.
2. **Unreachable.** An earlier attempt placed the capture after a `continue`
   guard (`if context <= 0`) that skips exactly the unbilled records the
   mutation was meant to exercise.

Only a mutant that *removed* the original capture was live, and the test killed
it immediately.

**Why:** a false "survived" reads as a weak test and sends you editing an
assertion that was fine — or, worse, weakening a correct one until it "catches"
something. The tell is cheap: run mutant and original over the same fixture and
diff stdout. Same bytes ⇒ no-op mutant.

**How to apply:** before concluding a test is weak, (a) diff mutant vs original
output on the fixture, and (b) check the mutated line is reachable and not
overwritten downstream. Then, separately, confirm the fixture actually
distinguishes the two readings — a decoy that sorts away harmlessly yields the
same result either way; see [[fixture-must-express-the-divergent-case]].
Related: [[mutation-harness-keyed-on-exit-code]],
[[asymmetric-mutation-reads-as-untested]].
