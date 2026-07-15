---
name: ship-worktree-merge-cleanup
description: "gh pr merge --delete-branch fails local cleanup in a worktree (main checked out elsewhere); the remote merge still lands — verify, then clean up manually"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 4eeefecf-9dbf-47ae-9c14-40e1ca49a8cc
---

When `/ship-issue` auto-merges (L3–L4) from inside a git worktree,
`gh pr merge <N> --squash --delete-branch` can exit non-zero with
`fatal: 'main' is already used by worktree at <parent>` — because its local
post-merge step tries to check out `main`, which the parent worktree already
holds.

**Why:** the failure is only the LOCAL checkout/branch-delete half. The remote
squash-merge itself has already succeeded by then.

**How to apply:** do NOT treat the non-zero exit as a dead-end / failed merge.
Verify with `gh pr view <N> --json state,mergedAt,mergeCommit` (state=MERGED),
confirm the diff is on origin/main and the issue auto-closed, then finish the
cleanup the failed step skipped: `gh issue edit <N> --remove-label
status/in-progress`, `git push origin --delete <branch>`, issue comment, delete
state file. Mirrors [[verify-squash-merge-landed]]. Distinct from
[[auto-mode-blocks-self-merge]] (a full denial, no merge happens).
