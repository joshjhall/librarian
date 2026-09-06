---
name: confirm-pid-ownership-before-killing
description: On a shared host a PID you did not spawn may belong to a peer golem; never pkill by pattern, and confirm the worktree a process belongs to before proposing to kill it
metadata:
  type: feedback
---

Processes on this host belong to several concurrent golems. A PID this session
did not spawn is not automatically "leftover" — it may be another lane's
in-flight work.

**Why:** I ran `pkill -f 'lint-shell-portability.sh'` to clean up what I thought
was my own redundant run. The pattern also matched the gate running inside a live
pre-push hook, wedging my own push until it timed out at 900s. Later I proposed
killing PID 789786 as "stranded" — that lefthook tree belonged to
`.worktrees/issue-636`, a DIFFERENT golem's push. Killing it would have sabotaged
another lane's work.

**How to apply:** Never `pkill -f` on a pattern that names a shared script — kill
by exact PID or not at all. Before killing, establish ownership:
`ls -l /proc/<pid>/cwd` for the worktree it runs in, and walk `ppid` up to find
the session that spawned it. If it belongs to another worktree, leave it and
wait for the lock to clear. A shared script name appearing under a foreign parent
is the signal to stop, not to clean up. Related: [[slow-under-load-is-not-wedged]].
