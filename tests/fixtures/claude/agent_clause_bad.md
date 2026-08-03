---
name: agent-clause-bad
description: NEGATIVE FIXTURE agent — proves the destructive-shell clause detector fires. Not a real agent; do not install.
tools: Read, Bash, Grep
---

# agent-clause-bad (negative fixture)

Deliberately broken fixture for `tests/lint-skills-agents.sh`. It has a
well-formed `## Restrictions` section — so the section extractor finds something
to scan — but that section carries **no** destructive-shell policy, exactly like
the nine agents #587 found unprotected.

The detector must therefore report **all four** invariant tokens as missing.

DO NOT add the sandbox / path-resolution / provenance wording to the section
below, and do not quote it anywhere else in this file: the guard needs something
to catch, and a fixture that satisfies the gate it is meant to arm proves
nothing (the gate-and-evidence-converge tautology).

## Restrictions

MUST NOT:

- Modify production source code — this fixture is inert
- Do anything at all, in fact; it exists only to be scanned

## Output Format

Nothing. This agent is never dispatched.
