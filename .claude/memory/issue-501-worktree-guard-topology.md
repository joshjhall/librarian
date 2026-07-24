---
name: issue-501-worktree-guard-topology
description: worktree-guard.sh submodule+bare topology enforcement; core.worktree beats --show-superproject-working-tree from a linked worktree cwd
metadata: 
  node_type: memory
  type: project
  originSessionId: 31721a8b-5dfb-4ebc-a187-5c8993a89434
  modified: 2026-07-24T04:57:59.744Z
---

**#501** (follow-up to [[issue-475-worktree-guard]]): worktree-guard.sh derived
main_root as parent-of-git-common-dir (only correct for a top-level `.git`);
loud-fail-opened on submodule + bare topologies. SHIPPED via `/golem 501
--level 4` from main checkout (also the vehicle for #451 AC#1 L4 live exercise,
mirroring how #475→AC#2 and #485→AC#3).

**BIG LESSON = the guard's trust anchor must be NON-POISONABLE.** A golem worktree
session can `git config` its own SHARED common-dir config (core.* not
worktree-scoped). The pre-PR review found THREE dynamic-repro silent-bypasses,
each fixed by deriving from PATH STRUCTURE not config:

1. reading core.bare/core.worktree from common-dir config → `git config core.bare
   true` flips to silent-allow. FIX: main_root from common-dir PATH — submodule =
   `${cd%%/.git/modules/*}` (superproject; leak into submodule checkout still
   DENIED bc inside it); standard = `${cd%/*}`; else LOUD fail-open.
2. residual branch's `--is-bare-repository` ALSO reads core.bare → separate-git-dir
   (`git init --separate-git-dir`) + poison = silent-allow. FIX: dropped is-bare
   entirely; bare+exotic both LOUD fail-open. Moved topology-INDEPENDENT
   worktree-first ALLOW ABOVE derivation so bare host's own edits pass silently.
3. `rev-parse --show-toplevel` for worktree_root is redirectable via
   `extensions.worktreeConfig=true` + `git config --worktree core.worktree <main>`
   → worktree-first allow matches main → silent leak. FIX: worktree_root from
   `<git_dir>/gitdir` pointer file (written at `git worktree add`, NOT config) +
   cwd-under-root cross-check (cwd from PreToolUse JSON, non-config).

Bypasses 1(part) & 3 REPRODUCE on pre-#501 origin/main = pre-existing #475 gaps.

**ISSUE TEXT WAS WRONG:** proposed `--show-superproject-working-tree` — returns
EMPTY from a submodule LINKED worktree (prints only from PRIMARY checkout) + names
superproject not submodule checkout. Structural common-dir path is the answer.

Submodule deny-reason made topology-aware (prefix-substitution recovery hint is
wrong for submodule — worktree doesn't mirror superproject layout).

STILL OPEN → **#506**: golem rewriting its own `$WT/.git` gitlink defeats the #475
git-dir==common-dir main-session gate (cross-cut fix spanning this gate +
bash-guard; pre-existing, out of #501 scope).

32 guard tests (7 poison/misconfig regressions, each proven to fail vs old logic)
plus run-all green. MERGED PR #507 (squash 884cdfe) — operator authorized merge
despite the 3-cycle-cap dead-end ("good enough for now"), filed #508 for a later
systematic adversarial re-review of the guard trust anchors. #451 CLOSED with an
L4 limitation note: an L4 golem can't do the literal AUTO-MERGE (auto-mode blocks
self-authored merges) — it verifies L4 mechanics up to correctly PARKING at the
merge gate; true unattended auto-merge needs a non-golem context.
