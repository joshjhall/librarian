---
name: agent-clause-scattered
description: NEGATIVE FIXTURE agent — proves the clause check is per-bullet, not per-section. Not a real agent; do not install.
tools: Read, Bash, Grep
---

# agent-clause-scattered (negative fixture)

The adversarial case for a section-wide keyword sweep. Its `## Restrictions`
section contains all four invariant tokens — `mktemp -d`, "canonicalize",
"unresolved", and `#426` — but **scattered across unrelated bullets**, none of
which actually prohibits destructive shell.

A per-section check reports this agent compliant. That is #426's own failure mode
(prose that is technically compliant while stating no real restriction) recurring
inside the gate built to prevent it, so the detector must fold each bullet and
require the tokens to co-occur in **one** prohibition.

The detector must report `canonicalize`, `unresolved`, and `provenance` as
missing: a clause bullet is found (it mentions `mktemp -d`) but does not carry
the rest of the invariant.

## Restrictions

MUST NOT:

- Write scratch output anywhere except a `mktemp -d` directory of your own
- Canonicalize the findings payload before emitting it — pass it through verbatim
- Leave an unresolved template placeholder in generated output
- Skip the schema check introduced in #426

## Output Format

Nothing. This agent is never dispatched.
