---
name: verify-blocked-action-before-reporting-it-blocked
description: "A permission denial on the verification step doesn't mean the action failed — check real state before reporting a block"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 5fd8b772-404e-4cce-8dea-13525dc7da6a
  modified: 2026-08-31T18:55:10.863Z
---

When a tool call is denied, establish **whether the underlying action already
took effect** before reporting it as blocked. A denial on the *verification*
command is not evidence the *action* failed.

Measured (#836/PR #865): `gh pr merge --squash` produced no output; the
follow-up `gh pr view --json state` was denied by the auto-mode classifier, as
was a plain `git fetch`/`git log`. I reported the merge as blocked and handed it
to the user. The merge had in fact **succeeded** — `state: MERGED`, squash commit
already on `main`. The classifier had blocked the read-only status check, not the
merge.

**Why:** a denial is evidence about *the call that was denied*, nothing more.
Attributing it backward to a prior call invents a causal link. The cost is
asymmetric and lands on the user: they get told to redo completed work, and a
"go finish this by hand" handoff is precisely where a duplicate merge or a
confused revert happens.

**How to apply:** on a denial mid-sequence, find a path to ground truth that the
denial does not cover — a differently-shaped read, the API, the filesystem, or
simply retrying the check later — and say plainly what is *unverified* rather
than asserting failure. If no such path exists, report the state as **unknown**
and name the specific thing the user should check, never as "it was blocked."
Same posture as [[reproduce-outside-the-tool-first]]: get an independent reading
before diagnosing. Cross-ref [[auto-mode-blocks-self-merge]] — that memory is
about the merge legitimately being gated; this one is about not over-reading the
gate's scope.
