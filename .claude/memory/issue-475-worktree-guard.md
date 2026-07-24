---
name: issue-475-worktree-guard
description: "#475 PreToolUse worktree-scope guard blocks golem edits leaking into the main checkout; shipped PR #502 (L2, awaiting merge); adversarial review caught a HIGH silent-bypass"
metadata: 
  node_type: memory
  type: project
  originSessionId: 2e00fe92-7847-4f32-8736-90367f40c1a5
  modified: 2026-07-24T04:57:44.302Z
---

**#475** SHIPPED PR #502 (L2, awaiting human merge) — new
`plugins/workflow/hooks/worktree-guard.sh` PreToolUse hook (matcher
`Write|Edit|MultiEdit|NotebookEdit`) DENIES a golem edit whose absolute target
resolves under the main checkout but outside the current worktree. Mirrors
[[issue-426-harness-rm-rf]]'s bash-guard.sh contract (fail-open+loud,
jq-optional pure-bash fallback, deny-in-JSON envelope, exit always 0, bash-3.2
clean, tools via /usr/bin/* except `git` via `command -v`). Discriminator is
git-worktree scope (git-dir != git-common-dir), NOT agent_id — the leak is in
the golem's OWN main loop, not a subagent. Fixes the
[[edits-landed-in-main-not-worktree]] class.

**Why:** golem worktree edits with a main-checkout absolute path land SILENTLY
in main (worktree git status stays clean) and can revert a merged PR on naive
recovery ([[stale-base-squash-reverts-merged-pr]]).

**How to apply / REUSABLE bugs from the adversarial pre-PR review:**

- HIGH silent-bypass: `main_root="${common_dir_abs%/*}"` (parent-of-common) is
  the main checkout ONLY in the standard top-level `.git` topology. Submodule
  (common-dir=`.git/modules/<name>`) and bare-repo-host mis-scope → a false
  ALLOW = silent leak. FIX = gate on `*/.git` common-dir, else fail-open LOUDLY
  (detectable degraded-allow, never silent). Full submodule/bare enforcement via
  config.sh's `--show-superproject-working-tree` ([[repo-root-submodule-superproject]])
  deferred to #501. Lesson: a fail-OPEN guard's silent mis-scope is as bad as no
  guard — make every un-scopable case LOUD.
- MED: `$WT/../<file>` normalizes to a main path — the NATURAL leak shape, not an
  edge. Don't fail-open on `..`; do a pure-bash lexical `.`/`..` segment collapse
  BEFORE prefix-scoping; only a root-escaping `..` fails open.
- Test path arithmetic: WT=MAIN/.worktrees/issue-1, so `$WT/../../seed`==main
  (two levels), `../../../` overshoots to $FIXTURE (outside repo→allowed).

Live-verified #451 AC#2 (L2 human-merge /golem path) end-to-end from the main
checkout. Teardown pending: `/golem --teardown 475` after human merges #502.
