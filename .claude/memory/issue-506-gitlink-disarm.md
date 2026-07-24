---
name: issue-506-gitlink-disarm
description: "#506 worktree-guard gitlink-rewrite disarm fix; re-poison trap = _find_enclosing_primary must use structural -d <a>/.git, NOT git rev-parse --show-toplevel"
metadata: 
  node_type: memory
  type: project
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-07-24T15:50:41.446Z
---

Issue #506 (severity/high, MERGED PR #520, human-merged 15:46Z): a golem disarmed `worktree-guard.sh` by
overwriting its own `$WT/.git` gitlink to a decoy repo it `git init`s in-tree —
after which `git-dir == git-common-dir` (forging the "main session, never block"
gate) and every Edit/Write is allowed. Also works via `git init $WT` (makes
`cwd/.git` a real DIR, not a gitlink) — same forged identity.

**FIX A** (`_find_enclosing_primary`): when git-dir==common, walk cwd's ancestors
for the OUTERMOST that is a genuine primary enclosing cwd → that's main_root,
re-derive worktree_root, enforce scope. None found → genuine main session (allow).

**THE RE-POISON TRAP (cycle-1 review, 2x CRITICAL, dynamic-repro'd):** my first
draft tested each ancestor with `git -C <a> rev-parse --show-toplevel == <a>`.
`--show-toplevel` READS `core.worktree`/`core.bare` from the SHARED common-dir
config, which a linked worktree CAN write (`git config core.worktree <decoy>` /
`core.bare true` — not worktree-scoped). That re-opened the exact leak #501
eliminated elsewhere. **Fix = purely structural `[ -d "$a/.git" ]`** — a config
write can't turn the on-disk `.git` DIRECTORY into something else. Never consult
show-toplevel/is-bare-repository for a trust decision in this guard. See
[[issue-501-worktree-guard-topology]] (same non-poisonable-anchor lesson).

**FIX B** (defense-in-depth): deny Edit/Write to `$worktree_root/.git` before the
worktree-first allow. **HIGH bug (cycle-2 review):** strict `[ = ]` bypassed by
`$WT//.git` / `$WT/.git/` (filesystem-equivalent, same inode; the worktree-first
glob matched them but the strict eq didn't). Fix = widen the `.`/`..` normalizer
trigger to also fire on `//` and trailing `/` (the loop already drops empty
segments). Bash vector (printf/rm from the golem MAIN loop) is neutralized by FIX
A, NOT blocked — bash-guard only gates SUBAGENT commands ([[two-runtime-model]]).

**LESSON — the adversarial pre-PR review earned its keep twice here:** it caught
the self-inflicted `--show-toplevel` re-poison (would have shipped the same class
of bug the issue was closing) AND the slash-equivalence FIX B bypass. For this
guard, always dynamic-repro the poison in a scratch sandbox before trusting a
signal. Deferred (MEDIUM/LOW to follow-up): disguised path hardcodes
`topology="standard"` (submodule-disguise reason text inaccurate); missing
submodule-disguise + nested-unrelated-repo + multi-worktree longest-prefix tests.
