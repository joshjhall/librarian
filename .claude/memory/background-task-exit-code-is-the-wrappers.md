---
name: background-task-exit-code-is-the-wrappers
description: A <task-notification>'s "exit code 0" is the backgrounding wrapper's status, not the command's — read the captured log's own verdict
metadata:
  type: feedback
---

When a long command is moved to the background (timeout, or `run_in_background`),
the completion notification's `exit code N` reports the **wrapper**, not the
command. Observed on librarian #921: `bash tests/run-all.sh > /tmp/run.log 2>&1`
was backgrounded, the notification said **exit code 0**, and the log body said

```text
  One or more test stages FAILED
  [FAIL] status/pr-pending label lifecycle
Exit code is 1.
```

**Why:** the same lost-exit-code hazard CLAUDE.md documents for pipes (#854),
reached by a different route — capturing instead of piping does not protect you
once the run is backgrounded.

Seen again on #699, this time on **`git push`**: the notification said `exit
code 0` while the log ended `[FAIL] Shell portability` / `error: failed to push
some refs`. The pre-push hook had *blocked the push* — nothing was on the remote.
So this is not a test-runner quirk: it applies to any backgrounded command whose
real verdict is in its output, and a "successful" push notification is
specifically not evidence that the branch exists upstream (`git status -sb`, or
the absence of an `[ahead N]`, is).

**How to apply:** for a backgrounded gate, suite, or push, never report green off
the notification. Read the log's own verdict line (`run-all.sh` mirrors the banner
plus failed-stage names to stderr precisely so it survives). If a suite prints
no self-verdict, re-run it in the foreground before calling it green. A doubled
verdict in the log is expected under `2>&1` — the stdout copy plus the stderr
mirror, not two runs. See [[prepush-hook-already-runs-the-suite]] for when the
full run is worth paying at all.
