---
name: tool-absence-fixture-needs-a-symlink-farm
description: Forcing one tool absent via a hand-listed stub PATH fails 127 at a different tool each time, and each failure looks like the no-op arm passing
metadata:
  type: feedback
---

To test "tool X absent → clean no-op", build the stub PATH as a **symlink farm**:
every executable on the real PATH *except* X. Do **not** enumerate the tools the
script "needs" — that list is always incomplete, and it grows through the
script's transitive callees, not just its own body.

**Why:** measured on #810's `gh`-absent arm, a hand-listed stub failed **three
times in a row** at a different tool: `dirname` (the script's own line 18), then
`basename`/`uname` (inside `git-submodule`, which the script shells out to), then
`mktemp` (inside `seed-worktree-trust.sh`, a sibling it invokes). Each was exit
127 or 1 — and the surrounding assertion "no config was written" was **green
every time**, because the script died before reaching the code under test. The
fixture looked like it was proving the no-op arm while proving nothing.

Two traps that ride along:

- **`BASH_ENV` restores PATH.** This image sets `BASH_ENV=/etc/bash_env`, sourced
  by every non-interactive bash, and it *rebuilds* PATH — so `command -v gh`
  still resolved `/usr/bin/gh` under a PATH of only the stub dir. Pass
  `env --unset=BASH_ENV`, as `gate_age_unit`'s `nojq` arm in
  `tests/lib/golem-sandbox.sh` already does.
- **Force absence; never skip on it** — see
  [[self-skipping-test-hides-the-risky-branch]].

**How to apply:** loop the real `$PATH` dirs, symlink each executable into the
stub (first dir wins, mirroring resolution order), `continue` past the one or two
you are suppressing. Then confirm the arm has teeth with a mutation —
[[mutation-round-finds-the-untested-rule]] is what catches a fixture that passes
for the wrong reason.
