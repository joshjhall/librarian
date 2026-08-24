---
name: preserved-fixture-can-heal
description: an environment-dependent repro kept as a fixture can self-heal before you test against it; capture the evidence now and verify against whatever is broken at that moment
metadata: 
  node_type: memory
  type: feedback
  originSessionId: fc26bda0-7917-4736-9473-51d688830491
  modified: 2026-08-23T07:05:46.763Z
---

When a bug reproduces only under some environment condition (a filesystem
artifact, a race, a timing window), **do not plan the verification around one
preserved instance of it.** The instance can heal while you build the fix, and
then it proves nothing — worse, it tears down/passes via the ordinary path and
*looks* like a successful verification.

**Why:** #768's `worktree-rm.sh` false positive came from virtiofs/bindfs
reporting `nlink=0 size=0` on a committed symlink. A worktree was deliberately
kept as the end-to-end fixture. By the time the fix merged, that worktree read
`nlink=1 size=9` with a clean `status --porcelain` — fully healed. It removed via
the ordinary path and never exercised the carve-out at all. What actually proved
the fix was a *different* worktree (incidental debugging debris) that happened to
be stale at that moment.

**How to apply:**

1. **Capture the evidence when you see it**, not later — the raw command output,
   the `stat`/`--raw` lines, the hashes. That capture is what lets you build an
   honest stub (see the PATH-stub in `tests/golem-scripts/45-worktree-rm-symlink.sh`,
   which replays a real observed line rather than an invented one).
2. **Verify against whatever is broken NOW**, not against the one you set aside.
   For a class of artifact that recurs, there is usually another instance around.
3. **Don't infer the range from the first sighting.** #768 was filed as a
   macOS/virtiofs issue; both live confirmations were a Linux devcontainer on a
   bind mount. "Where it was first seen" is not "where it happens".
4. If a preserved fixture is genuinely the only path, say so in the tally and
   expect to re-catch the condition rather than assume it waits.

Related: [[reproduce-outside-the-tool-first]],
[[gate-and-evidence-converge-tautology]], [[self-skipping-test-hides-the-risky-branch]].
