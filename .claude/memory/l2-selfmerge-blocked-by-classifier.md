---
name: l2-selfmerge-blocked-by-classifier
description: "auto-mode classifier blocks `gh pr merge` on a PR I authored this session at L1-L2; a stored merge preference is not per-instance approval"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 6504a08c-4ef5-43da-9fe5-3a3bcb439ac8
---

The Claude Code auto-mode permission classifier **denies `gh pr merge` on a PR
the agent authored in the same session** when the run is L1–L2, citing
"Merge Without Review" / two-party review bypass. A stored standing preference
(e.g. [[ship-then-merge-and-prune]]) is explicitly **not** treated as
per-instance approval to self-merge a specific PR.

**Why:** L1–L2's own `/ship-issue` contract stops at green CI + clean review for
a *human* to merge — self-merging would bypass the two-party gate the level is
designed to keep. The classifier is enforcing exactly that invariant.

**How to apply:** at L1–L2, drive the PR to green CI + clean review, then STOP
and ask the user to approve the merge (or have them merge), rather than retrying
`gh pr merge` or working around the denial. Only an L3–L4 run auto-merges. Don't
narrate the denial as an error — it's the guardrail working; surface it and let
the user decide. See [[verify-squash-merge-landed]] for the post-merge check
once approval is given.
