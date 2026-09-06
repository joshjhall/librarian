---
name: next-issue-read-issue-comments
description: "next-issue/ship-issue must read issue COMMENTS, not just the body — follow-ups fold in requirements, and can INVERT the plan"
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

**A comment can invert the conclusion, not just extend it (#467).** That issue's
body reported keystroke-simulation as unworkable and proposed
cancel-then-text-directive. Its own comment, posted the same day, reported a
**validated forward-order keystroke sequence** (`↑/↓`+`Enter`, widget
auto-advances, submit at all-`☒`) and narrowed the real failure to *backward*
navigation. Planning from the body alone shipped a cancel-only protocol that
would have discarded a working path on every form — worse than the status quo,
and contrary to the issue's most recent guidance. The review scored that finding
**LOW (0.12)** and filed it `deferrable`, so `blocking: []` would have merged it.

**Why:** acceptance criteria, folded-in scope, and *corrections to the issue's
own analysis* frequently live in comments. A body-only read silently
under-scopes — or mis-scopes — the work.

**How to apply:** in Phase 2 (read the issue), fetch comments too —
`gh issue view {N} --comments` (or `--json body,comments`) — and treat later
comments as authoritative amendments to the body, including where they overturn
it. This lesson pre-dated #467 and was violated anyway: the body was rich enough
(two candidate directions, a detailed failure narrative) to feel complete, which
is exactly when the comment check gets skipped. Read comments **because** the
body looks sufficient. The pre-PR review harness is a backstop, not the primary
catch. See [[verify-squash-merge-landed]] for another "trust but verify the
actual state" lesson, and [[blocking-empty-is-not-nothing-to-fix]] — this is a
worked instance of it.
