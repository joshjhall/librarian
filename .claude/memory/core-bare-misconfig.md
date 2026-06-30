---
name: core-bare-misconfig
description: "If git says \"this operation must be run in a work tree\" in /workspace/librarian, .git/config has a stray core.bare=true — set it false"
metadata:
  node_type: memory
  type: project
  originSessionId: 9d03d497-52a7-4a29-8c82-1ca6971f87ee
---

In the devcontainer, `/workspace/librarian/.git/config` can carry a stray
`core.bare = true` even though the repo plainly has a working tree (files
present, HEAD resolves, branch checked out). Some earlier tooling mis-set it.

**Symptom:** `git checkout`, `git rev-parse --is-inside-work-tree`, and any
write op fail with `fatal: this operation must be run in a work tree`, while
read-ish ops (`git fetch`, `git branch --show-current`, `git log`) still work —
so a session can look "clean" at startup and only break when you try to branch.
It also MASKS real working-tree changes: `git status` reports nothing under the
bad config, hiding pre-existing uncommitted edits.

**Fix:** `git config core.bare false` (origin was `file:.git/config`). Then
`git rev-parse --is-inside-work-tree` → `true` and checkout works.

**Why:** not the GIT_DIR/GIT_WORK_TREE env leak from [[flaky-golem-gate-watch-test]]
— that's `GIT_*` env vars; this is a persisted config key. Check both when git
acts like it can't see the work tree. After fixing, re-run `git status` to see
the working tree's ACTUAL state before branching/committing.
