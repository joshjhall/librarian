---
name: umbrella-issue-closes-vs-contributes
description: "Shipping one decomposed slice of a multi-part issue must use \"Contributes to"
type: feedback
metadata:
  node_type: memory
  originSessionId: 3e7b68e6-26a7-4425-9e2d-58282ad21d47
  modified: 2026-11-09T18:59:21.098Z
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

**Cross-repo variant (#400, PR #463):** when the real fix lives in another repo
(e.g. the pinned `containers` submodule, which librarian never edits — see
[[librarian-runs-outside-containers]]), the librarian issue's written AC still
describes the other repo's work. Here `Contributes to` is not the only fix:
**re-scope the issue's AC** into "librarian-side (what closing this records)"
vs "owned by <companion issue>", point at the companion, and then `Closes #N`
legitimately closes exactly what the diff delivers. Which repo the companion
goes in is the user's call ([[ask-before-choosing-issue-repo]]).
