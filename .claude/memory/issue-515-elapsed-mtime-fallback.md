---
name: issue-515-elapsed-mtime-fallback
description: "#515 golem-status ELAPSED mtime fallback when .started absent; anchor on .git gitlink not worktree dir; review→#522"
metadata: 
  node_type: memory
  type: project
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-07-24T20:35:49.743Z
---

Issue #515 (L3, /next-issue→/ship-issue): `golem-status.sh --checkpoint` rendered
ELAPSED `—` for any golem cache lacking `.started` (Mode-2 dispatch =
worktree-new.sh + golem-launch.sh writes NO cache). FIX = read-side fallback in
`emit_checkpoint_row`: when `.started` absent/unparsable, anchor ELAPSED on the
worktree mtime (epoch = TZ-agnostic, UTC-safe), render `~<age>` marked
approximate. Added `STAT=$(_bin stat)` + a local `_mtime_epoch` mirroring
golem-gate-watch.sh (golem-status had neither).

**Why:** the missing stamp forced the operator off the tool onto `tmux ls`
(prints LOCAL) vs UTC caches → silent TZ offset; live a ~3h park read as ~8h
(the [[gate-watch-misses-standing-gates]] incident). Chose option 1 (read-side)
over option 2 (dispatch backfill) — heals ALREADY-running golems.

**How to apply:** the review MEDIUM that mattered — anchor on the worktree's
`.git` GITLINK FILE (written once by `git worktree add`, never rewritten by inner
git ops), NOT the worktree DIR mtime, which re-bumps whenever a top-level entry
is added (committed file, node_modules/, cp'd local files) and would REWIND
ELAPSED toward ~0. Dir is last-resort only. Also numeric-guard `.issue` before
path interpolation (case `''|*[!0-9]*`) so a corrupt cache value can't stat
outside .worktrees/. ELAPSED stays OUT of cp_sig (AC#3) → #488 suppression safe.

Adversarial pre-PR review: clean/0-blocking, 5 deferrable; applied 2 (gitlink
anchor + numeric guard) + malformed-.started test inline, filed the 2 test-only
gaps (stat fail-open, cp_sig-under-fallback --watch) as **#522**.
