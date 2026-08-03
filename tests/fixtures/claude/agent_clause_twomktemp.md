---
name: agent-clause-twomktemp
description: NEGATIVE FIXTURE agent — proves the clause check evaluates each bullet alone, even when two mention the sandbox. Not a real agent; do not install.
tools: Read, Bash, Grep
---

# agent-clause-twomktemp (negative fixture)

The second adversarial shape. `agent_clause_scattered.md` pins that the check is
not section-wide; this one pins that it is not "every `mktemp -d`-bearing bullet
merged together" either — an intermediate design that anchored on the sandbox
token and grepped **all** matching bullets as one blob.

Two bullets below mention `mktemp -d`. Neither states the full invariant: the
real clause has the sandbox and the `#426` marker but no path-resolution rule,
and the aside has the path wording but no provenance. Merging them satisfies all
four tokens, so the blob design reports this agent compliant; scoring each bullet
independently reports a genuine near-miss.

The detector must return a **non-empty** report here (the nearest bullet lacks
`provenance`).

## Restrictions

MUST NOT:

- Write output outside a fresh `mktemp -d` sandbox, per the rule from #426
- Reuse a `mktemp -d` scratch dir between runs; canonicalize its path before
  writing and never leave an unresolved symlink behind

## Output Format

Nothing. This agent is never dispatched.
