---
name: release-from-worktree-gitcliff
description: git-cliff scopes commits to cwd; running release.sh from a worktree/subdir wiped the changelog — fixed with --include-path in PR
metadata:
  node_type: memory
  type: project
  originSessionId: 5ab6fd65-c6c6-433d-a590-2ec30160b58e
---

This repo's top-level checkout is a **bare** git repo with worktrees under
`.claude/worktrees/*`, so releases are cut from a worktree, not the repo root.

git-cliff 2.x scopes commits to the **current working directory**. Running
`bin/release.sh` from a worktree/subdir made git-cliff see no history and emit
an empty (header-only) `CHANGELOG.md` while exiting 0 — a silent wipe. Symptom:
`CHANGELOG.md` shrinks to ~6 lines with no `## [x.y.z]` sections.

**Fixed (PR #75):** `bin/release.sh` now passes `--include-path '**/*'` to pin
full-repo scope regardless of cwd, plus a guard that fails the release if the
generated changelog lacks the new version's `## [VERSION]` section. So
`just release-{patch,minor,major}` works from a worktree now.

Release flow recap (see [[release-process.md]]): script bumps VERSION + stamps
manifests + regenerates CHANGELOG but does NOT commit/tag/push. Order that
keeps the changelog complete: commit any fix/docs FIRST, then run the release
script (so those commits appear in the notes), then commit the artifacts, PR to
main, and only AFTER merge push the annotated `vX.Y.Z` tag (release.yml asserts
VERSION == tag on the tagged tree). Squash commits whose subject isn't
conventional-commit format (e.g. "Track N: ...") are filtered out of the
changelog by git-cliff. Verify the merge with [[verify-squash-merge-landed]].
