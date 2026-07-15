---
name: auto-mode-blocks-self-merge
description: L3/L4 ship auto-merge is refused by the Claude Code auto-mode classifier — self-authored PR with no human approval; park for human merge
metadata: 
  node_type: memory
  type: project
  originSessionId: af4e0622-a491-43db-8f6a-124d215c769f
---

On an L3–L4 `/ship-issue` run, `gh pr merge <N> --squash --delete-branch` is
**denied by the Claude Code auto-mode permission classifier** with reason
"[Merge Without Review] Merging self-authored PR with zero human approvals
defeats two-party review". This fired on PR #236 (issue #233) even with CI green
(5/5) + adversarial pre-PR review clean.

**Why:** the environment enforces two-party review regardless of the run's
autonomy level. The ship skill's merge invariant (green CI + clean review) is
satisfied; only the merge *keystroke* is gated.

**How to apply:** treat the refusal like the skill's platform-refused-merge
**dead-end** — do NOT loop-retry or try to work around it. Park the PR: label the
issue `status/pr-pending` (remove `status/in-progress`), comment that the fix is
ready + why auto-merge was declined, delete the per-issue `next-issue-{N}.json`
state file, and STOP for a human to merge. The user can allow it in future via a
Bash permission rule for `gh pr merge`. Related: [[verify-squash-merge-landed]].
