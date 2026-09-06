---
name: edits-landed-in-main-not-worktree
description: Using main-checkout absolute paths from a worktree session lands edits in the wrong tree (on stale main) — verify cwd/worktree before editing
metadata: 
  node_type: memory
  type: feature
  originSessionId: b5836d04-7414-4c51-9f1b-8ae1719f1769
  modified: 2026-07-21T13:36:13.842Z
---

Working #406 in worktree `.worktrees/issue-406` (branch feature/issue-406, base

# 464 `8144952`), I passed **main-checkout absolute paths** (`/workspace/librarian/plugins/...`)

to Edit instead of the worktree paths (`/workspace/librarian/.worktrees/issue-406/plugins/...`).
All edits + the earlier reads/tests silently landed in the MAIN checkout, which
was sitting on a STALE `main` (`9e91112`, behind origin/main `af55d36`) and
LACKED #464's `reaped` event kind. The worktree `git status` was clean, which is
what surfaced the mistake at ship time.

**Why dangerous:** the main checkout's base for golem-notify.sh/test was OLDER
than the worktree's (no `reaped`). Blindly copying the edited files into the
worktree would have reverted #464 — the [[stale-base-squash-reverts-merged-pr]]
class. Also the main checkout had UNRELATED pre-existing dirty files (checker.md,
memory .md) that were NOT mine.

**Recovery that worked:**

1. `git -C /workspace/librarian checkout -- <my 3 files>` — restore ONLY my files
   in the main checkout, leaving the unrelated dirty files untouched.
2. Re-apply all edits FRESH in the worktree via `.worktrees/issue-406/...`
   absolute paths, anchoring on the worktree's own (newer) content so `reaped`
   lines are preserved.
3. Verify: worktree `git status` shows exactly the 3 intended files; `grep -c
   reaped` on hook+test confirms #464 survived; run-all green.

**How to apply:** In a worktree session, ALWAYS target `.worktrees/issue-{N}/...`
paths (or `cd` into the worktree and use the Bash cwd). Before shipping, if
worktree `git status` is unexpectedly clean, check the main checkout
(`git -C <main> status`) — your edits may be there. Compare base blob hashes
(`git show HEAD:<file> | git hash-object --stdin`) between trees before copying
anything; DIFFER means a merged commit lives in one and not the other. See
[[verify-squash-merge-landed]], [[ship-review-diff-must-be-faithful]].

## Second vector: `cd` in Bash, not just absolute paths in Edit (#816, 2026-09-03)

The rule above says "always target `.worktrees/issue-{N}/...` paths". That is
necessary and NOT sufficient — it names the *Edit* vector and misses the *Bash*
one. In #816 the session ran under a harness directive to prefer Bash for file
work (`sed`, heredocs, `python3 - <<EOF`), and the very first command was
`cd /workspace/librarian && ...`. Every subsequent relative path was then
main-relative, and 40 files landed in main while the worktree stayed clean.
Absolute Edit paths were never involved.

**The tell that did NOT fire:** each Bash call reported "Shell cwd was reset to
/workspace/librarian/.worktrees/issue-816" — cwd resets between calls, so the
worktree looked correct while every in-command `cd` silently overrode it.

**What actually caught it:** the #475 worktree guard, on the first `Write` (Bash
edits are not guarded). So in a Bash-heavy session the guard fires LATE — after
an arbitrary amount of work — or never, if the task uses no Write/Edit at all.

**How to apply:** in a worktree session, never `cd` to the repo root in a Bash
command. Either use no `cd` (the harness already sets cwd to the worktree) or
`cd` to the worktree path explicitly. Before the first commit, run
`git -C <main> status --porcelain | wc -l` — a non-zero count in a session that
believes it edited only the worktree is the bug, not noise.

**Migration is safe only when the bases agree.** Before copying anything across,
compare the two branches' commits (`git rev-parse main feature/issue-{N}`) and
diff per-file blobs. In #816 both were at the identical commit with zero
divergence, so a straight copy carried no [[stale-base-squash-reverts-merged-pr]]
risk; had they diverged, the fix is to re-apply fresh on the worktree's own base.
