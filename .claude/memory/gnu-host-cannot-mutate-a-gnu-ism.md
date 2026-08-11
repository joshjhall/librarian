---
name: gnu-host-cannot-mutate-a-gnu-ism
description: Reverting a portability fix to its GNU spelling is a NO-OP mutation on a GNU host — mutate to what the OTHER platform produces
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 749bcb5c-e042-45b3-a811-f801d495df1c
  modified: 2026-08-10T23:31:19.272Z
---

When a fix replaces a **GNU-only** construct (`\s`, `\w`, BRE `\|`, `grep -P`)
with a POSIX one, the obvious mutation — revert to the GNU spelling, check that a
test fails — **proves nothing on a Linux/CI host**. GNU grep/sed implement those
extensions, so the reverted code still works, every test still passes, and the
round reports "this rule is UNTESTED" when the truth is "that mutation was a
no-op." Measured on #679: reverting `sed -E` to the `\|` BRE still extracted the
right symbol, because GNU sed supports `\|`. That invisibility on GNU hosts is
*why* the bug shipped in the first place.

**Why:** the mutation must reproduce the other platform's **OUTCOME**, not its
source text. Rewrite the pattern so it genuinely fails to match on the host you
have — `[[:space:]]` → a literal `s`, or an anchor like `^nomatch` that can never
fire. That is host-independent and is what the test actually guards.

**How to apply:** make any mutation harness (1) assert the file actually changed
(`cmp -s` against the backup) before believing a "0 failures" result, and (2)
mutate to the broken **behaviour**, not the old **spelling**. Three sibling traps
from the same issue, each of which produced a check that passed with the broken
code until caught:

- `sed --posix` is NOT a general BSD proxy — it reproduces `\s`/`\|` but still
  ACCEPTS a multi-command `{a;b;p}` brace block, so it cannot exercise that bug.
- PATH-based tool sabotage never reaches a gate that runs as a **child process**:
  a shell startup file can rewrite PATH, so the child sees the real binary.
  Verify the sabotage is live *inside* the process under test, or pick another
  lever. (For a pure-bash rewrite, "no subprocess left to fail" is a stronger and
  simpler claim than any sabotage.)
- A **dotfile** fixture is skipped outright by some scanners (`typos` among
  them), so a `.probe.md` planted to prove a gate fires never arms it.

When a construct genuinely cannot be exercised on the available host, say so in
the PR and cover it *by construction* (delete the dependency, add a lint gate
that keeps it deleted) rather than shipping a test that only looks like proof.

Related: [[mutation-round-finds-the-untested-rule]],
[[gate-and-evidence-converge-tautology]], [[anchored-regex-tautological-test]],
[[escaped-fixture-cannot-self-match]].
