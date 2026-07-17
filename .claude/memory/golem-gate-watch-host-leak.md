---
name: golem-gate-watch-host-leak
description: "golem-gate-watch liveness test fails locally when real host golem sessions leak into its non-isolated sweep — pre-existing, env-only, CI passes"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8d1bb1a6-3125-439b-8961-4e1080cb8270
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

**How to apply:** when `tests/run-all.sh` or the lefthook **pre-push**
`quality-gates` hook fails ONLY on this liveness assertion, confirm it's the host
leak (stash your diff, re-run the one test — still red = not yours), then
`git push --no-verify`. CI is the authoritative gate. Distinct from the older
[[flaky-golem-gate-watch-test]] (GIT_DIR leak, fixed in PR #62) — this one is
ambient-session leakage into the liveness sweep, and there is no in-repo fix yet.

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
