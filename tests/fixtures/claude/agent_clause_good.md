---
name: agent-clause-good
description: POSITIVE FIXTURE agent — proves the destructive-shell clause detector accepts a reworded clause. Not a real agent; do not install.
tools: Read, Bash, Grep
---

# agent-clause-good (positive fixture)

Companion to `agent_clause_bad.md`. Its `## Restrictions` section states the #426
invariant in wording that matches **no** real agent verbatim — the sentence
order, framing, and surrounding bullets are all different.

That is the point: the gate asserts an invariant *core*, not one fixed sentence.
`checker.md` extends the clause with agnix autofix fencing and `debugger.md`
reframes it for a write-capable agent; both are legitimate adaptations and both
must keep passing. This fixture pins that tolerance, so a future tightening of
the detector into a literal-string match fails here first.

## Restrictions

MUST NOT:

- Invent findings not supported by the scanned input
- Touch git state or delete files in the working tree. Any command that has to
  create or remove something runs in a throwaway `mktemp -d` directory instead.
  Canonicalize every path you hand it first (`cd <dir> && pwd`) — an unresolved
  `..` must never reach a destructive command (#426).
- Emit output outside the documented schema

## Output Format

Nothing. This agent is never dispatched.
