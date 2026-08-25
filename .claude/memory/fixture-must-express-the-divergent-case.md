---
name: fixture-must-express-the-divergent-case
description: "A test pins nothing unless its INPUT makes fixed and unfixed code differ — solve for the divergent value, don't pick a plausible one"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 928777c5-82e1-47cf-8b1e-a7b507d03905
  modified: 2026-08-24T21:58:47.707Z
---

When a fix changes *how* a value is computed, the test's chosen input must be one
where the old and new computations **actually disagree**. A plausible-looking
input usually is not: both spellings agree on most values, so the test passes
identically with and without the fix.

**Why:** five instances in one session (#784), every one green, every one caught
only by mutating the fix away:

1. **Two-expression rounding.** Fixed a `pct`/`verdict` divergence, then tested at
   `threshold=300150` — where old and new both return `ok`. Had to *solve* for the
   divergent value (`250126`: old form floors `advise_at` to exactly the context
   and says `advise`, while `pct` says 79).
2. **Ordered guards.** Three parse guards, one all-garbage stub → only the FIRST
   ever fires. Each guard needs an input that **satisfies its predecessors**.
3. **Newest-file selection.** Named the fixture `newer.jsonl`, which sorts
   *before* `session.jsonl`, so glob-first and mtime-newest picked the same file.
   (Also: same-second files have equal mtimes and `-nt` compares whole seconds —
   backdate the OLD file rather than touching the new one.)
4. **Env-var propagation.** Tested an `export` by passing the var as an env
   prefix — already inherited, so it propagated with the `export` deleted. Set it
   as a plain **shell variable** so only a real `export` can carry it.
5. **Path traversal.** Pointed the traversal at a nonexistent path, so guarded and
   unguarded both rendered `unknown`. The escaped path must reach a real planted
   artifact for the two arms to differ.

**How to apply:** after writing the test, revert the fix and confirm it fails. If
it survives, either the fixture does not express the divergence (fix the fixture)
or the change is a real no-op — see [[surviving-mutation-may-be-a-real-no-op]];
prove which, then say so in the comment rather than shipping a test whose stated
purpose it does not serve. Two "coverage gaps" in that same session were no-ops:
a jq gate and an `-x` guard whose stderr the caller already redirected, both
byte-identical with and without.

Related: [[anchored-regex-tautological-test]],
[[escaped-fixture-cannot-self-match]], [[mutate-after-every-security-fixture]],
[[gate-and-evidence-converge-tautology]], [[mutation-round-finds-the-untested-rule]].
