---
name: poll-pattern-matches-its-own-process
description: "A wait-loop whose pgrep/ps pattern also matches its OWN command line never exits — it waits on itself until timeout, while the thing it should watch never runs"
metadata:
  type: feedback
---

`until ! pgrep -f 'tests/run-all.sh' >/dev/null; do sleep 10; done` **never
exits**: the loop's own shell was invoked with that string in its command line,
so `pgrep -f` matches the waiter itself. It waits on its own existence.

**Why:** `pgrep -f` matches the FULL command line of every process, and a monitor
or `bash -c` wrapper carries the pattern verbatim as an argument. The predicate
is therefore true because the poll is running, which is exactly the condition it
treats as "still busy". Self-reference is invisible in the source — the line
reads as a perfectly ordinary wait.

The failure is silent and expensive in the worst way: it looks like patience.
Observed live in #928 — two successive Monitors each burned their full timeout
while the suite they were "waiting for" **was never started**, because a
`&&`-chained launch sat behind the loop that would not finish. ~50 minutes lost,
and the tell was a contradiction I should have caught sooner: `pgrep` said a run
was in flight while the log file that run would create **did not exist**. When a
waiter's two signals disagree, suspect the waiter.

**How to apply:** prefer a mechanism with no polling at all — a plain background
task that re-invokes on exit (Bash `run_in_background`) beats a hand-rolled
`until` loop for "tell me when this finishes". When you must poll:

- Watch an **artifact**, not a process: `until [ -f done.marker ]`, or grep the
  log for its own terminal banner. Files do not match themselves.
- If you must match a process, exclude self — `pgrep -f pat | grep -v $$`, or
  match on something the waiter cannot contain (a pidfile).
- Sanity-check the predicate once by hand before trusting a long wait, and treat
  "process present but its output file absent" as proof the match is wrong.

Sibling shapes where a check accidentally includes itself:
[[escaped-fixture-cannot-self-match]], [[self-skipping-test-hides-the-risky-branch]].
Different mechanism from [[idle-detector-false-positive-own-monitors]] (a
detector misreading a pane), same family: the observer contaminating its own
measurement — cf. [[observer-resolves-its-own-cwd-not-the-subjects]].
