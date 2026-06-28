---
name: verify-squash-merge-landed
description: "After merging a PR, verify the intended changes are actually on origin/main — don't trust the merge commit title"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 5ef35931-1874-450d-9431-6255128dc6e2
---

After a squash-merge, always confirm the *content* landed on `origin/main`, not
just that the PR shows "merged". In this repo a PR (#30) squash-merged but
carried only stale pre-existing commits — the squash commit had the right
*title* but the wrong *diff*, and the intended doc/hook work was silently
dropped. Recovered by cherry-picking the original local commit onto a fresh
branch off `origin/main` (#34).

**Why:** A PR's squash commit message is composed from the branch's commits, so
it can read correctly while the actual diff is wrong — especially when the
branch was cut from a local `main` that was *ahead of* `origin/main` with
unrelated unpushed commits (those ride along into the PR and can dominate the
squash).

**How to apply:**

- Before branching, check `git log --oneline origin/main..main` — if local main
  is ahead, branch from `origin/main` explicitly
  (`git checkout -b foo origin/main`), not from local `main`.
- After merge, verify on the merge commit: `git show <merge-sha> --stat` should
  list YOUR files; grep a sentinel string from your change in the working tree
  after `git reset --hard origin/main`.
- `gh pr view <n> --json files,commits` is authoritative for what a PR actually
  contained.
- Related: this repo's local clone had a missing git blob for
  `.devcontainer/docker-compose.yml`; regenerate from the worktree with
  `git hash-object -w <file>` (it re-creates the exact SHA).
