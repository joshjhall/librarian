---
name: surviving-mutation-may-be-a-real-no-op
description: "A mutation that survives is sometimes provably equivalent code, not a coverage gap — prove which before writing a test that cannot fail"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c65bf62a-a5be-45ca-adf3-2741defb9fa8
  modified: 2026-08-18T02:36:17.059Z
---

When a mutation round leaves one mutation **surviving**, the reflex is to write a
test for it. Check first whether the mutated code is *reachable in a
distinguishable state* — sometimes the mutation is a genuine no-op and no fixture
can tell the two versions apart.

Worked case (#589, `tests/lint-prose-budget.sh`): the ceiling was
`max(type_budget, baseline_entry)`, guarded three lines above by
`[ "$count" -gt "$budget" ] || continue`. Dropping the `max()` survived. That is
not missing coverage — under that guard the two forms provably agree: when
`base >= budget` they are the same number, and when `base < budget` the guard has
already established `count > budget > base`, so both fail. A test asserting the
difference would pass with **and** without the `max()`, which is the
tautological-fixture shape ([[gate-and-evidence-converge-tautology]],
[[anchored-regex-tautological-test]]).

**Why:** a test for a no-op is worse than no test. It adds a green assertion that
can never fail, so it reads as coverage while proving nothing, and the next
reader trusts it. Deleting the "dead" code is also wrong when it is what makes
the logic correct *independently* of a guard that may later move.

**How to apply:** on a surviving mutation, first try to construct the input that
distinguishes the two versions. If you can, that is the missing test — write it.
If you can prove you cannot, keep the code and record the invariant in a comment
saying what makes it currently unreachable and what would make it reachable again
("if the guard moves, this is what stops a hand-lowered entry from failing a file
within budget"). Report it as a proven no-op, not as a covered rule.

Distinguish this from a mutation that survives because the **fixture** was
malformed. In the same session a canary for an awk command-injection passed
against the vulnerable code, because a leading `"` in the planted filename closed
the shell quote so `sh` died on a syntax error before reaching the `$(...)`
payload ([[escaped-fixture-cannot-self-match]]). That one was a real gap. The
tell: the mutated code was plainly reachable, so "it survived" had to mean the
fixture never exercised it.
