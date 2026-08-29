---
name: tolerating-a-failure-still-needs-the-order-right
description: "\"Treat this failure as success\" is only half a fix — a partial operation already destroyed state on its way to failing"
metadata:
  type: feedback
---

When an issue asks you to **tolerate** an expected failure ("the warning is
alarming for a condition that is harmless"), the framing invites a message-only
change. Ask first: **what did the failing operation already do before it
failed?** A partial operation is not a no-op.

Worked case (#834): `rm -rf` does not stop at the first undeletable entry — it
removes everything it can, *then* reports failure. So on a bindfs/FUSE overlay
it deleted the deregistered worktree's dangling `.git` while leaving the
undeletable subtree, destroying the fingerprint a later guard requires. A re-run
then hit `no-fingerprint` and exited 1 with "may never have been a worktree" — a
hard failure whose text was affirmatively false. The scary warning the issue
described was the *lesser* half; the real defect was ordering.

Fix shape: control the order so the **evidence survives the partial failure**
(clear contents first, remove the fingerprint last, and only once the contents
are fully gone), rather than relaxing the guard that reads it. Relaxing the
guard would have "fixed" the symptom while removing a protection.

**Why:** a message-only fix passes the obvious test (exit 0, no WARNING) and
leaves a worse bug — one reached only on the *second* run, i.e. in unattended
teardown where nobody is watching. This is [[fix-reintroduces-its-own-failure]]
seen from the other side, and my own first attempt committed it: I removed
`.git` unconditionally after the contents pass, reintroducing the exact loss.
The probe caught it, not the reasoning.

**How to apply:**

- Before tolerating a failure, run it and **diff the filesystem/state** — do not
  reason about whether the operation is atomic. Mine wasn't.
- Gate the follow-up step on the **observed state**, not the exit status: batched
  commands (`find -exec … +`, `rm -rf`) report one status for many operations, so
  the status cannot say what survived.
- Mutate the **message-only version** of your fix specifically. If it passes,
  your tests only pin the wording and the ordering bug ships. Here that mutation
  failed 2 of 4 tests — that is the check that proves the ordering is tested.
- A count or detail you print but never assert is untested: dropping the `.git`
  exclusion from the survivor count survived the first mutation round until the
  exact value was pinned ([[mutation-round-finds-the-untested-rule]]).
