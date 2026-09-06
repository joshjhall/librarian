---
name: combined-label-call-partially-applies
description: gh issue edit --add-label X --remove-label Y applies the REMOVE then fails the add — the issue is left with no label, not unchanged
metadata:
  type: reference
---

`gh issue edit N --add-label X --remove-label Y` is **not** atomic, and the
"failed" call leaves state changed. Measured on librarian #921 (2026-09-06)
against the live API:

```text
$ gh issue edit 921 --add-label status/definitely-not-real \
                    --remove-label status/in-progress
failed to update …: 'status/definitely-not-real' not found   # rc=1
$ gh issue view 921 --json labels    # -> NO status label at all
```

The remove lands and persists; the add then fails validation. So a bad add does
not "take the remove down with it" — it is the reverse, and the surviving
effect is the destructive one.

**Why the intuition is wrong in the dangerous direction.** "Validates up front,
fails the whole call" sounds like a safe transaction and makes the bug read as
cosmetic. It is the opposite: an issue with no status label is re-selectable by
the next-issue priority walk — a double-dispatch window in a parallel golem run.

**How to apply:** never combine an add and a remove in one label call. Add
first as its own call, remove only if it succeeded — the failure mode is then a
stuck label (visible, one manual edit) rather than an absent one (invisible,
costs a collision). Same shape as
[[tolerating-a-failure-still-needs-the-order-right]]: the partial op had already
destroyed state before failing. Verify with a live probe, not a stub — a stub
encodes whichever model its author believed
([[comment-asserts-intent-not-code]]).
