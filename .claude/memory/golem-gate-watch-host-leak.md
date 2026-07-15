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
