---
name: stale-base-squash-reverts-merged-pr
description: git reset --soft origin/main from a stale worktree silently reverts PRs merged mid-session; restore each advanced file before amending
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 091532d0-4b9a-4836-8736-f7d1b9e44f4b
---

When a ship run squashes with `git reset --soft origin/main` (or rebases) and
`origin/main` has **advanced since the worktree's branch point**, the reparented
commit silently **reverts every file the newly-merged PRs touched** — because the
worktree still holds the pre-advance version of those files. Symptom: `git show
--stat HEAD` lists files you never edited (with large `-` deltas).

**Why:** the worktree branched from an older base; `reset --soft` moves the ref
to the new base but leaves the old working-tree/index content, so the diff vs the
new base includes an accidental revert of the intervening merges.

**How to apply:** before amending, run `git diff --name-only <old-base>
origin/main` to list what advanced, and `git diff --name-only origin/main...HEAD`
to list what your commit touches. For any file in BOTH that you did not
intend to change, `git checkout origin/main -- <file>` (re-applying your own
additive edits if that file is genuinely one you edited — they usually live in a
different section and don't conflict), then amend. Verify the final
`git diff --stat origin/main...HEAD` shows ONLY your intended files.

This bit issue #269's ship (PR #296): both `codebase-audit/workflow.js` and
`tests/validate-workflow-helpers.mjs` were advanced by #294 mid-session. See
also [[verify-squash-merge-landed]] and [[auto-mode-blocks-self-merge]].
