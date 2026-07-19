---
name: git-index-corruption-partial-commit
description: "A truncated .git/index can silently capture a partial tree in a commit — verify the pushed tree, don't trust that git add staged everything"
metadata: 
  node_type: memory
  type: project
  originSessionId: 9abee550-dd13-4109-9ea0-7af93076167d
  modified: 2026-07-19T06:17:06.625Z
---

On 2026-07-18 (PR #403, issue #238) the local `.git/index` got truncated to
112 bytes mid-session — it held **only 1 of ~384 tracked files**. Effects:
`git status` showed nearly the entire repo as **untracked**; `git add <my 4
files>` then `git commit` produced a commit whose tree contained **only
`.agnix.toml`** (the ADR / README / SKILL.md were silently dropped); that
partial commit was **pushed and opened as a PR**. All working-tree files were
intact on disk the whole time — the damage was index-only. No `GIT_DIR` /
`GIT_INDEX_FILE` env leak was present; cause appears to be a transient bad index
write (distinct from [[core-bare-misconfig]], where `core.bare=true` is the
tell — here `core.bare` was correctly `false`).

**Why:** the index is the staging source of truth. A corrupt/truncated index
makes git see a tiny tree as "everything," so `add`+`commit` faithfully records a
near-empty tree with **no error** — a silent partial commit. Left uncaught it
merges a PR that contains almost none of the intended change.

**How to apply:**

- **Detect:** `git ls-files | wc -l` far below the real file count, or `git
  status` showing huge swaths of the repo as untracked, or a commit/PR whose
  file list is missing files you know you changed. After any push, sanity-check
  `gh pr view <N> --json files` matches the files you intended.
- **Recover (index-only corruption, working tree intact):**
  `git read-tree <last-good-commit>` to rebuild the index from a known-full tree
  (e.g. `HEAD^` / `origin/main`), then `git reset --mixed <last-good-commit>` so
  your working-tree changes reappear as normal modifications; re-stage the real
  files, verify `git ls-tree -r HEAD --name-only | wc -l` is back to full, commit,
  and **`git push --force-with-lease`** to replace the bad commit on the branch.
- Objects are usually fine (only the index was hit) — the good tree is still
  reachable via `HEAD^` / the remote, so no data is lost.

Related: [[verify-squash-merge-landed]] (verify what actually landed),
[[stale-base-squash-reverts-merged-pr]] (another silent-tree-loss class),
[[core-bare-misconfig]], [[typos-gate-blocks-push]].
