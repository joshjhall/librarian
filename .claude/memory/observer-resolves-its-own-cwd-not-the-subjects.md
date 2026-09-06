---
name: observer-resolves-its-own-cwd-not-the-subjects
description: A script run BY an observer ABOUT a subject must derive paths from the SUBJECT argument, not from repo_root/cwd
metadata:
  type: feedback
---

When a helper is invoked by one actor *about* another, any path it resolves from
`repo_root` or `$PWD` resolves to the **observer's** location, not the subject's.

**Why:** #890 — `golem-work.sh` resolved the status dir from `repo_root`, but the
liveness classifier is invoked by the gate-watch sweep from an unrelated cwd, so
it read a DIFFERENT, empty registry. An empty registry reads as "nothing open",
which was *exactly the false verdict being fixed* — the bug silently reverted
itself through the path resolution. The unit test never caught it because the
unit test runs from the right cwd; only the wiring test did.

**How to apply:** when a helper takes a subject path, derive every other path
from THAT argument and pass it explicitly — never re-derive from cwd. Ask "which
actor actually runs this?" as a first-class question, per
[[exemption-is-a-runtime-claim-measure-it]]. Beware the failure mode where the
wrong path yields *empty* rather than *missing*, since empty often reads as a
legitimate "nothing here" — see [[whole-repo-diff-bounded-by-repo-content]].
