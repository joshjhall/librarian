---
name: umbrella-issue-closes-vs-contributes
description: "Shipping one decomposed slice of a multi-part issue must use \"Contributes to"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 3e7b68e6-26a7-4425-9e2d-58282ad21d47
---

When an `effort/large` issue explicitly calls for per-port/per-plugin
decomposition and you ship only the first slice, the commit/PR MUST say
**`Contributes to #N`** (or "part of #N"), NOT `Closes #N` — otherwise the merge
auto-closes the umbrella while most acceptance criteria are unaddressed, silently
dropping the rest. File a **follow-up issue** for the remaining slices so the
umbrella stays tracked, and remove `status/pr-pending` from the umbrella (it is
not itself a single PR).

**Why:** ship-issue's adversarial pre-PR review (scope-drift dimension) flagged
exactly this as HIGH/blocking on #243 (I'd written `Closes #243` for a 5-of-14
slice). The review measured live coverage across all 14 ports to prove 9 were
still incomplete. It was correct — a real premature-closure bug.

**How to apply:** on any decomposed-slice PR, check the trailer before pushing;
`Contributes to #N` + a filed follow-up (#348 for #243's remaining 9 ports) is
the pattern. See [[stale-base-squash-reverts-merged-pr]] for the other trap that
bit this same ship (the reset --soft revert).
