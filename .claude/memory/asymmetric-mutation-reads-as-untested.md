---
name: asymmetric-mutation-reads-as-untested
description: A mutation weaker than its twin SURVIVES for a reason unrelated to coverage — narrow it before writing a test
metadata:
  type: feedback
---

When a mutation survives in one runtime but its twin dies in the other, suspect
the **mutation**, not the coverage, before writing a test. A predicate spelled
as several independent arms can be neutered partially: removing one `if` leaves
a sibling arm that still answers the same way for the fixtures on hand, so the
suite stays green and the rule looks untested when it is merely
*under-mutated*.

**Why:** "SURVIVED" answers "did any test fail", not "is this rule tested". A
test written against a mis-read survivor either duplicates existing coverage or,
worse, pins the wrong arm — and the genuinely uncovered arm stays uncovered.

**How to apply:** narrow with a three-way follow-up before believing the result
— mutate **all** arms, then **each** arm alone. Reading the three outcomes:

- all-arms killed + each-arm-alone killed → fully covered; the original
  mutation was just weak.
- all-arms killed + one arm survives alone → that arm is genuinely unreachable
  from the fixtures. **Ask what input shape would reach it**, and check whether
  production supplies that shape.

Worked case (#851): `is_test_file`'s directory test is two arms — a
leading-segment `tests/...` and a mid-path `/tests/`. Every fixture in the tree
builds paths under an absolute `mktemp -d`, so only the mid-path arm was ever
exercised, while **production callers pass repo-relative paths** — the one shape
only the leading arm matches. The untested arm was the one real runs depend on
most. The fix was a fixture that runs the scanner with cwd *inside* the sandbox
and lists a relative path.

Generalizes: an absolute-path fixture cannot test a relative-path arm. If a
predicate branches on path *shape*, at least one fixture must supply each shape.

Related: [[mutation-round-finds-the-untested-rule]],
[[surviving-mutation-may-be-a-real-no-op]],
[[path-guard-must-expand-before-scoping]].
