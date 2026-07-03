---
name: ship-then-merge-and-prune
description: "On non-autonomous /ship-issue, carry through to merge + prune once CI is green and review is clean — don't stop at green CI"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 1df5864d-1662-4c76-9cc9-e6676a9a9548
---

When shipping an issue via `/ship-issue` in **non-autonomous** mode, the skill
by design stops at green CI and hands off to the human for the merge. The user
wants me to **carry through**: once CI is green **and** the review is clean
(the merge invariant — see [[../../plugins/workflow/skills/orchestrate/autonomy-levels.md]]),
squash-merge with `--delete-branch`, then prune the local branch and clear any
stale `status/pr-pending` label on the now-closed issue. Confirmed on PR #188
(issue #174), where the user asked "you never merged the pr and prune the
branches."

**Why:** the green-CI stop is fine for an unattended golem, but in an
interactive session where the human is present and has already approved the
plan, stopping short just adds a manual step. The merge invariant is still
respected — never merge on red CI or an unclean review.

**How to apply:** after `/ship-issue` reaches green CI + clean review on a
non-autonomous run, proceed to `gh pr merge <N> --squash --delete-branch`,
then `git checkout main && git pull --ff-only`, `git branch -D <feature>` if it
lingers, `git fetch --prune`, and `gh issue edit <N> --remove-label
status/pr-pending`. Do NOT do this if CI is red or the review requested changes
— surface that instead. Relates to [[never-timeout-human-gate.md]] (still WAIT
at genuine human choice gates like shipping mode; this is about not stopping
*after* the work is verified green).
