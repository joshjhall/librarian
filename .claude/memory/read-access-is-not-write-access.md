---
name: read-access-is-not-write-access
description: "Probing a blocker with a read call proves only that reads work — test the ACTUAL verb before reporting the blocker lifted"
metadata:
  node_type: memory
  type: feedback
---

When an issue says an action is blocked on access, probe it with the **verb the
task needs**, not a cheaper one that shares the resource. A successful read says
nothing about write.

Measured (#793): the issue recorded that filing upstream against
`anthropics/claude-plugins-official` failed with `Resource not accessible by
personal access token`. I ran `gh api repos/anthropics/claude-plugins-official`,
got **200**, and told the user in a plan that "both blockers are gone — the token
limitation no longer applies." It was still there. `gh issue create` returned the
same refusal; `permissions` read `{pull: true, push: false}`. The 200 only ever
proved the repo was public.

**Why:** a probe is evidence about the capability it exercised. Sharing a
resource, an endpoint, or a CLI does not make two verbs one permission — and the
asymmetry favors the wrong conclusion, because the cheap probe is almost always
the read. Worse, this lands in a *plan*: the user approves work premised on a
blocker being lifted, and the gap only surfaces at execution, after the plan was
agreed.

**How to apply:**

- Probe with the real verb, or with an explicit capability read
  (`gh api repos/OWNER/REPO --jq .permissions`) — never infer write from read.
- Where a real probe would be destructive, say the capability is **unverified**
  rather than asserting it. "I can read it; write is untested" is honest and
  costs nothing.
- Re-probing a recorded blocker is right — blockers do lift. Just do not let
  *wanting* it lifted pick the easier test. Same failure shape as
  [[verify-blocked-action-before-reporting-it-blocked]] (don't over-read a
  denial's scope) seen from the other side: don't over-read a success's scope.
  Cross-ref [[deferred-work-may-be-doable-now]] — probe the blocker, but probe
  the right thing.
