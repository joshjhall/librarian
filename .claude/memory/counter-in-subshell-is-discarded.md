---
name: counter-in-subshell-is-discarded
description: A shell counter incremented inside $(...) never reaches the parent — a shadowed callback then repeats forever and the test misreports what happened
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 237ae268-417c-4953-a378-41e10f8333d5
  modified: 2026-08-29T06:37:07.407Z
---

A test shadowed an allocator so its FIRST call returned a squatted port and later
calls delegated to the real one. The shadow incremented a plain shell variable.
But the production code invokes it as `port="$(free_port)"` — a command
substitution, i.e. a **subshell** — so every increment was discarded, the shadow
returned the squatted port on *every* attempt, and the retry could never
succeed.

The failure presented as "the retry does not recover" — pointing at the code
under test, when the fixture was the broken part. The counter read `0` after two
real calls, which was the tell.

**Why:** `$(...)`, a pipeline stage, and a backgrounded block all run in
subshells. Assignments there are invisible to the parent. This bites hardest in
*test doubles*, where the double's state is the thing being asserted, so a lost
write silently turns a behavioral test into one that measures nothing.

**How to apply:**

- When a double is invoked through `$(...)`, keep its call count in a **file**
  (`printf > "$WORKDIR/calls"`), never a variable.
- Same trap in the assertion: `if with_free_port 0 true; then` runs in-shell and
  sees the callee's `FREE_PORT=""`; `err="$(with_free_port 0 true 2>&1)"` does
  not — that arm passed only because the test had seeded the value itself.
  Redirect stderr to a file and call in-shell when the callee's variable writes
  are what you assert.
- Before blaming the code under test for a fixture-driven failure, verify the
  fixture actually did what it claims — print its counter.

Related: [[fixture-must-express-the-divergent-case]],
[[side-effect-invisible-to-the-assertion]].
