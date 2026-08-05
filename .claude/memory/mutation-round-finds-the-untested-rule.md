---
name: mutation-round-finds-the-untested-rule
description: "Run the mutation round over EVERY rule, not just the ones you wrote tests for — the rule with no failing test is the one it exists to find"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 621fe101-e237-498d-9198-a05d816bf523
  modified: 2026-08-05T03:30:26.679Z
---

When mutation-verifying a new detector, mutate **every rule it implements**, not
just the ones you deliberately wrote fixtures for. In #663 a full round over ten
mutations found nine went red and **one did not**: the cluster-adjacency guard
had no failing test at all — the suite stayed green with the guard removed. Two
later review cycles found the same shape twice more (the bare `fan-in N` evidence
branch; the standalone Rust `#[test]` attribute carry).

**Why:** a rule nothing asserts is a rule that regresses silently, and you cannot
tell which one that is by reading your own test list — the whole point is that it
*looks* covered. This is the same family as
[[anchored-regex-tautological-test]] and
[[gate-and-evidence-converge-tautology]], but the detection method is different:
those are about a fixture that cannot fail, this is about a rule no fixture
reaches.

**How to apply:** enumerate the predicates/branches in the implementation (not
the tests), mutate each one, and record the per-mutation failure count. A `0`
names an untested rule — write its fixture then. Give each negative assertion a
**positive control** in the same case (e.g. raise a threshold so the same fixture
must now fire) so the negative cannot pass merely because the detector broke
wholesale. Mutate **both** impls when a tool has a bash↔python pair: parity is
relative, so a shared misconception passes both.
