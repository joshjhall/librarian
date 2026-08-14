# Index: git, worktrees & releases

<!-- Sub-index of MEMORY.md. Not a memory — no frontmatter, one line per entry. -->
<!-- rumdl-disable MD013 MD033 -->

## Releases

- [Release from worktree (git-cliff)](release-from-worktree-gitcliff.md) — git-cliff scopes to cwd; needs --include-path or it wipes CHANGELOG
- [cosign bundle format](cosign-bundle-format.md) — use --bundle (.sigstore.json); cosign 3.x ignores --output-signature (#153)
- [git-cliff checksum is sha512](git-cliff-checksum-sha512.md) — per-asset .tar.gz.sha512, not .sha256; verify against the published sibling

## Committing, merging & pushing

- [Verify squash-merge landed](verify-squash-merge-landed.md) — confirm the diff landed on origin/main, not just the title
- [Never tail a git push](never-tail-a-git-push.md) — `tail -2` hides the hook rejection; compare remote SHA to HEAD. Background it from the first attempt: pre-push runs the whole suite (~353 s) and blows the 120 s default
- [Git index corruption → partial commit](git-index-corruption-partial-commit.md) — committed 1 of ~384 files with NO error; verify `gh pr view --json files`
- [L1-L2 self-merge also blocked](l2-selfmerge-blocked-by-classifier.md) — a stored merge preference is not per-instance approval

## Worktrees

- [Stale-base squash reverts merged PR](stale-base-squash-reverts-merged-pr.md) — `reset --soft origin/main` from a pre-merge worktree reverts that PR
- [Worktree merge cleanup fails locally](ship-worktree-merge-cleanup.md) — `--delete-branch` errors, but the REMOTE merge still landed
- [Marketplace source = reaped worktree](marketplace-source-reaped-worktree.md) — registering a golem worktree → reap → plugins DOA
