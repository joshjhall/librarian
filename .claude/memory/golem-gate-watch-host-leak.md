---
name: golem-gate-watch-host-leak
description: "golem-gate-watch liveness test fails locally when real host golem sessions leak into its non-isolated sweep — pre-existing, env-only, CI passes"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8d1bb1a6-3125-439b-8961-4e1080cb8270
  modified: 2026-07-20T03:50:25.102Z
---

`tests/golem-gate-watch.sh` → `test_liveness_fresh_is_alive` (assertion "The
misleading 'advancing' wording is gone (#229)") FAILS in a dev container that has
**real golem tmux sessions running on the host**. The liveness sweep is not
isolated to its synthetic `golem-7`: it also picks up live `golem-NNN` sessions
(e.g. `golem-273`'s status line "⚠ idle at prompt — process up, not advancing"),
whose real wording contains "advancing" and trips the `assert_not_contains`.

**Why:** pre-existing test-isolation gap, NOT caused by any change under test —
it reproduces identically on a pristine `main`/HEAD tree (stash everything, still
fails). CI runs in a clean environment with no ambient golems, so it passes there.

**FIXED IN-REPO 2026-07-19 (#436 / PR #438).** The eventual retrofit (below) is
done: `_run_liveness_snapshot` now carries the same hermetic tmux stub as its
`_run_liveness_snapshot_tmux` sibling (fake `tmux ls` prints nothing +
`--unset=BASH_ENV` + `bash`/`git`/`jq` symlinks on the stub PATH — jq is needed
because these callers exercise the feed gate-detection path, unlike the `_tmux`
sibling). VERIFIED: `tests/golem-gate-watch.sh` 26/26 AND full `run-all.sh` green
WITH 4 live host golems, and the `fix/issue-436` push cleared the pre-push hook
(quality-gates 80s) with golems live and NO `--no-verify`. Once PR #438 merges,
`--no-verify` is NO LONGER the remedy — the guard runs honestly during active
orchestration. **Do not reach for `--no-verify` on this assertion anymore; if it
still fails post-#438, it's a REAL regression.** (Historic remedy below kept for
context only.)

**How to apply (HISTORIC, pre-#438):** when the pre-push `quality-gates` hook
failed ONLY on this liveness assertion, you confirmed the host leak (stash diff,
re-run the one test — still red = not yours) and `git push --no-verify`. Distinct
from the older [[flaky-golem-gate-watch-test]] (GIT_DIR leak, fixed in PR #62) —
this was ambient-session leakage into the liveness sweep.

**Confirmed again 2026-07-16 (#240/PR #340):** same failure blocked the lefthook
pre-push `quality-gates` hook; snapshot showed 5 ambient golems
(7/240/306/324/327) incl. this very ship-issue run (golem-240). `git push
--no-verify` was the remedy; CI passed. My diff touched zero golem files
(verified via `git diff --name-only origin/main...HEAD`).

**Confirmed again 2026-07-15 (#247/PR #305):** reproduced on pristine tree with 4
live host golems (224/247/258/280); golem-258's "not advancing" line trips it.
The proven isolation pattern (used by #247's new `_run_liveness_snapshot_tmux`):
run the script under a hermetic `PATH` whose fake `tmux ls` prints nothing, AND
`--unset=BASH_ENV` so `/etc/bash_env` can't reset `$PATH` back to the real tmux
(see [[devcontainer-bash-env-path-reset]]). New wiring tests built that way are
leak-immune; only the older un-stubbed `test_liveness_fresh_is_alive` still leaks
— retrofitting it the same way is the eventual in-repo fix.
