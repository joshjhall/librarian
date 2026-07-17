---
name: next-issue-read-issue-comments
description: "next-issue/ship-issue must read issue COMMENTS, not just the body — follow-ups fold in requirements"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 552d98d0-aaf1-4deb-bf59-9701cde7d19f
---

`gh issue view {N} --json body` returns ONLY the issue body, omitting comments.
On #328 the repo owner posted a **follow-up comment** folding an extra
requirement into the fix (make `repo_root()`'s scrub readonly-`GIT_DIR`-safe),
which the body-only fetch missed — the ship-issue adversarial pre-PR review
caught it as a HIGH-certainty scope-drift blocker.

**Why:** acceptance criteria and folded-in scope frequently live in comments,
not the original body. A body-only read silently under-scopes the work.

**How to apply:** in Phase 2 (read the issue), fetch comments too —
`gh issue view {N} --comments` (or `--json body,comments`) — and treat later
comments as authoritative amendments to the body. The pre-PR review harness is a
backstop, not the primary catch. See [[verify-squash-merge-landed]] for another
"trust but verify the actual state" lesson.
