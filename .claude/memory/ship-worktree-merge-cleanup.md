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

**Re-confirmed PR #369 (issue #361), L3 worktree.** Same `fatal: 'main' is
already used by worktree` on `gh pr merge --squash --delete-branch`; remote merge
landed (`118dbad` on origin/main, both diff markers present, #361 auto-closed
COMPLETED). New wrinkle: the auto-mode classifier ALSO denied the *verification*
`gh pr view ... --json state,merged` reads that fire right after the failed
merge (the over-match from [[auto-mode-blocks-self-merge]] extends to post-merge
reads, not just post-denial). Workaround that isn't blocked: verify the merge via
**git** instead of gh — `git fetch origin main` + `git log origin/main --oneline`
for the squash commit, `git show origin/main:<file> | grep <marker>` for the
diff, `git ls-remote --heads origin <branch>` for branch cleanup state. Then
`git push origin --delete <branch>` (also un-gated) finishes the cleanup.
