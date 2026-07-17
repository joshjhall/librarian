---
name: repo-root-submodule-superproject
description: repo_root() submodule bug — --git-common-dir yields .git/modules; fix uses --show-superproject-working-tree
metadata: 
  node_type: memory
  type: project
  originSessionId: 5d3fc5f2-3efa-4e95-88d0-cd62c1c2b8a0
---

Issue #324 (PR #335): `config.sh`'s `repo_root()` mis-placed golem worktrees
under `<super>/.git/modules/.worktrees/issue-N` when the scripts run from inside
a **git submodule** working tree.

Root cause: `repo_root()` derives the checkout root as
`dirname($(git rev-parse --path-format=absolute --git-common-dir))`. Inside a
submodule, `--git-common-dir` = `<super>/.git/modules/<name>`, so dirname →
`<super>/.git/modules` (git-internal). `worktree-new.sh` `cd`s there before
`git worktree add`.

Fix: probe `git rev-parse --path-format=absolute --show-superproject-working-tree`
FIRST — it prints the superproject root **only** inside a submodule (empty
otherwise), so it is both detector and value; empty falls through to the
unchanged `--git-common-dir` logic (normal repos + bare-repo worktree hosts).
The new probe carries the SAME `GIT_DIR/GIT_COMMON_DIR/...` scrub as the
common-dir probe ([[golem-gate-watch-host-leak]] / #279 hook-safety).

Verified empirically: build super+sub with
`git -c protocol.file.allow=always submodule add`; from inside `super/<name>`,
`repo_root` now prints `super`, not `.git/modules`. Sibling env-scrub work
tracked in #328. Deferred test-coverage follow-ups: #336 (super_root relative
absolutize arm), #337 (tainted-GIT_DIR scrub from submodule), #338 (e2e
worktree-new placement).
