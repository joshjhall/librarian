---
name: read-the-memory-body-not-just-the-index
description: "Recognizing an index line is not reading the memory — open the body before doing the thing it names, or you re-pay the cost it already documents"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8c18d381-5905-4b08-a734-d468be4e3b1b
  modified: 2026-09-06T22:16:30.230Z
---

The root `MEMORY.md` index line is a *pointer*, not the lesson. Recognizing one
as familiar and proceeding is how a memory gets re-learned at full price.

Measured on librarian #936, twice in one session. I had read the index line
"Scratch file under memory fails the push — rumdl lints `.claude/memory/`
ignoring gitignore; keep scratch prose in `/tmp/`", then wrote a PR body and an
issue body to `.claude/memory/tmp/` anyway — costing a ~17-minute pre-push cycle.
The memory's **body** named my exact failure (MD018 on a line beginning with an
issue reference like `#742`, parsed as a heading) and its fix. The index line
could not carry that, and its one-line remedy (`/tmp/`) did not even apply, since
`/tmp` does not survive a session handoff — the body covered that too.

**Why:** an index line compresses to a topic. The part that changes behavior —
the trigger, the failure signature, the exception — lives in the body by design.

**How to apply:** when a task is about to touch what an index line names, open
the file first. One Read against a multi-minute failure. Especially when the
one-line remedy does not fit your situation: that is a sign the body carries a
case you have not seen, not a sign the memory is inapplicable.

Related: [[scratch-file-under-memory-fails-the-push]].
