---
name: side-effect-invisible-to-the-assertion
description: "A test can corrupt real state while every assertion passes — the assertion looks at output, the damage lands somewhere else"
metadata:
  node_type: memory
  type: feedback
---

A test that **executes** a real component can mutate real state that **no
assertion looks at**. Every check passes, the suite is green, and the corruption
is invisible precisely because the test is asking a different question.

Worked case (#782, `tests/lint-hook-silence.sh`): the gate ran each shipped hook
against a no-op payload and asserted **stdout was zero bytes**. But
`golem-notify.sh` resolves its status feed from the **actual process cwd**
(`git rev-parse --git-common-dir`) — it never reads the payload's `cwd` field. So
every gate run appended a synthetic line to the LIVE
`.worktrees/.status/feed.jsonl` that `golem-status.sh` and gate-watch read to
decide golem state:

```text
bytes: 122575 -> 122685   (delta 110)
lines: 1110 -> 1111
{"ts":"...","golem":"golem-782","event":"idle","message":"..."}
```

attributed to the very golem running the suite. Under a `just test` / pre-push
run inside a golem worktree, that injects spurious events into that golem's own
status history. The stdout assertions passed the whole time.

**Why:** an assertion constrains **one channel**. Running real code exercises
**every** channel it touches — files, network, env, git state. A passing test is
evidence about the channel it measures and says nothing about the rest, so
"green" is not evidence of "no side effects."

**How to apply:** when a test *executes* a component rather than parsing it, ask
what that component writes **besides** the thing being asserted, then isolate it
before it runs — cwd into a throwaway dir, redirect its config env, and neuter
its network sinks. Confirm with a **probe rather than a re-read**: measure the
real target's size/mtime immediately before and after one run and require delta
0. The probe is what turns "I think it's isolated" into evidence, and it is the
same instrument that found the bug ([[reproduce-outside-the-tool-first]]).

Payload fields are not authority: a hook may take `cwd` from the process, not
from the JSON handed to it. Read the consumer to learn which, rather than
assuming the payload configures it.

Related: the damage here was to state a *different* tool consumes, so it also
would not have surfaced in this suite's own output
([[stale-artifact-makes-the-stub-pass]] is the inverse — leftover state making a
stub pass).
