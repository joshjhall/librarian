---
name: golem-watch-trap-signal-testing
description: "Why golem-watch trap INT/TERM coverage needs a structural grep, not just a behavioural signal test — bash EXIT-arm masking + group-signal semantics"
metadata: 
  node_type: memory
  type: project
  originSessionId: 73dfa9da-6deb-4da9-b76b-6d1f4bb5dea5
---

Testing `golem-watch.sh`'s `trap cleanup_pane EXIT INT TERM` for the INT/TERM
arms (issue #254, PR #358) is subtle — a naive "send SIGINT, assert reaped" test
is tautological. Empirically verified on bash 5.2:

- bash **defers** a *trapped* INT/TERM until the blocking foreground command
  (`--stream | sed`) returns — a PID-targeted signal does nothing until then.
- A real Ctrl-C is a **process-GROUP** signal (must `setsid` + `kill -INT -<pgid>`
  to model it), not PID-targeted.
- The **EXIT arm ALSO runs on group-signal death**, so a group SIGINT reaps the
  worker even against the exit-only regression → a behavioural test **cannot**
  discriminate EXIT-only from INT/TERM, and cannot catch the exact "dropped INT
  TERM" regression the issue names.
- A behavioural **TERM** case is impossible: the cleanup trap itself reaps via
  SIGTERM (`pkill -P`/`kill`), so a worker rigged to survive a group TERM survives
  the trap too.

**What shipped (PR #358):** a STRUCTURAL-ONLY assertion — grep the real trap line
and require it arms both INT and TERM. Deterministic, portable (macOS bash 3.2),
and the strongest guard for the named regression (fact c: no behavioural test can
catch "dropped INT TERM"). Mutation-check: dropping INT/TERM (or just TERM) fails
it.

**Behavioural test SHIPPED for #359 (PR pending) — setsid-free + self-gating.**
The earlier setsid+group-SIGINT prototype was CI-fragile (group signal never
landed on the GH runner; process tree leaked as orphans). #359 solved BOTH the
fragility and the tautology:

- **Tautology fix (the key trick):** a group SIGINT hits every member DIRECTLY, so
  a naive fake pane worker dies from the signal itself — reaped regardless of the
  trap. Make the fake pane worker **`trap '' INT`** (ignore INT): now only
  `cleanup_pane`'s `kill` (SIGTERM) can end it, so its death PROVES the trap ran.
  The foreground `--stream` fake does NOT ignore INT and BLOCKS, so the group
  signal ends it → pipeline returns → bash runs the (un-deferred) trap. Catches the
  no-trap regression (worker leaks); still can't discriminate INT-vs-EXIT (that
  stays the structural case-3 grep's job — a behavioural test never can, fact c).
- **Fragility fix:** a `group_signal_unavailable()` capability probe (`set -m`
  child in own pgid, confirm `kill -INT -<pgid>` kills it) SKIPS honestly where
  delivery is unreliable (the CI runner) instead of flaking. Plus a
  `( sleep 8; kill -KILL -<pgid> )` watchdog so a swallowed signal can't wedge the
  suite. Verified 20/20 deterministic locally, zero orphan leak, mutation-checked
  (no-op trap → FAIL). Setsid-free via `set -m` + `kill -INT -<pgid>`, bash-3.2
  clean. #360 (readiness-polling of the remaining fixed sleeps) still open.

Note: a PID-targeted (non-group) trapped INT is DEFERRED by bash until the ~30s
foreground pipeline returns → hangs (reproduced as a real 2-min timeout). Do not
PID-target; group-signal + INT-ignoring-worker is the working shape.

**If you DO build the behavioural test:** resolve the signal target as the pane
worker's own pgid via `ps -o pgid= -p $worker`, NOT `pgrep -f golem-watch.sh |
head -1` — that cmdline matches BOTH the setsid leader AND golem-watch's internal
`(watch|sed) &` subshell (never execs), and under a `timeout` wrapper the outer
`timeout` is also a pid==pgid leader. The worker is a child inside golem-watch's
group, so its pgid is that group unambiguously. But per the CI failure above, that
still wasn't enough on the runner — the fragility is signal delivery to the group,
not target resolution.
