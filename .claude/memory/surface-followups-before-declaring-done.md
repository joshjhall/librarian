---
name: surface-followups-before-declaring-done
description: Never end a shipping flow without listing every deferred finding and asking whether to file it — with a recommendation
metadata:
  type: feedback
---

At the end of any ship/review flow, **before** the completion summary, list every
follow-up the work surfaced and **ask whether to file each one**, with a
recommendation and a one-line rationale. Do not wait to be asked. Do not leave
them in prose that scrolls away.

Sources of a follow-up: a review finding triaged `deferrable`, something noticed
mid-implementation and deliberately scoped out, a defect found in pre-existing
code, or a "worth checking whether X shares this shape" observation.

**Why:** the user has had to ask "any follow ups to file?" repeatedly. A deferred
finding that lives only in a PR comment or a session summary is lost the moment
the session ends — which defeats the deferral, since deferring is supposed to
mean "later", not "never". `ship-issue`'s own
`ci-review-protocol.md` § *File deferred review findings* already mandates this
("Nothing is silently dropped: every confirmed finding is either fixed on the PR
or filed as a linked issue") — so skipping it is a missed step, not a judgment
call.

**How to apply:** end the flow with a short block — each candidate, a recommended
disposition (file / don't file), and why. Batch them into ONE `AskUserQuestion`
rather than asking per item. A finding I rejected on merit still gets listed,
with the measurement that killed it, so the user can overrule. Repo choice is the
user's call, not a default: see [[ask-before-choosing-issue-repo]]. Related:
[[blocking-empty-is-not-nothing-to-fix]].
