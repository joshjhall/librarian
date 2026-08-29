---
name: mutation-restore-must-not-be-git-checkout
description: A mutation harness that restores with `git checkout --` reverts to HEAD and DELETES the uncommitted fix under test
metadata:
  type: feedback
---

A mutation round's `restore()` must snapshot and copy back — **never**
`git checkout -- <file>`. `git checkout` restores from **HEAD**, not from the
pre-mutation working tree, so while the fix is still uncommitted the *first*
mutation's restore silently deletes the entire implementation. Every later case
then mutates pristine HEAD, where the target line no longer exists, and reports
`VACUOUS` — which reads as "my sed expression was wrong", not "my harness ate
the work". The signal that distinguishes them: a *sudden run* of vacuous results
after one or two normal `killed` lines.

**Why:** a restore that discards the very state under test is
indistinguishable, from inside the harness, from a mutation that failed to
apply. Both print "nothing changed". The harness cannot detect its own data
loss, so it is only visible in `git status` afterwards — by which point the
round has produced a full page of confident, meaningless output. This is
[[fix-reintroduces-its-own-failure]] in the tooling rather than in the fix.

**How to apply:** copy each target into a `mktemp -d` snapshot before the first
mutation and `cp` back from there. Add two guards that make the failure loud:

1. **Baseline-green check** before any mutation — if the suites already fail,
   abort, because every subsequent "killed" is noise.
2. **Compare against the snapshot, not against git**, to decide whether a
   mutation took (`cmp -s "$f" "$SNAP/$f"`), and treat `VACUOUS` as a *failure*
   of the round rather than a skip.

Also: never run a mutation round concurrently with the same suites in the
foreground. Both mutate the same files, so the foreground run reports failures
belonging to the background round's current mutation — one false diagnosis
before the race was noticed.

Related: [[mutation-round-finds-the-untested-rule]],
[[surviving-mutation-may-be-a-real-no-op]].
