---
name: issue-411-golem-verify-scope
description: "#411 /golem live-e2e verification — parked at PR #453; in-session run can only prove AC#3+#5, live ACs deferred to #451; adversarial review forced a re-scope"
metadata: 
  node_type: memory
  type: project
  originSessionId: 1a486152-805c-4c6f-80e9-634719f1d2b3
  modified: 2026-07-21T00:56:47.919Z
---

**#411 "Live end-to-end verification of /golem"** — shipped as PR #453 (docs-only),
**PARKED for human merge** (not auto-merged) 2026-07-20. `type/test severity/high
effort/small`, run at L3.

**The structural catch:** the `/next-issue 411` run executed *inside*
`.worktrees/issue-411`, so it could only prove the two in-session-verifiable ACs
and physically could not drive the live ones:

- **AC#3 (nesting guard)** — VERIFIED *live*: the guard idiom
  (`git rev-parse --git-dir` != `--git-common-dir`) fires in the worktree, exactly
  its designed refusal. The run proves AC#3 by *being* the failing case.
- **AC#5 (review-parity across ship modes)** — VERIFIED *static*: source-trace of
  `ship-issue/pre-ship-validation.md` **check #6** ("all shipping modes") + Options
  2/3 → Step 3.5 routing + PR #410 (`f740ff0`). Wiring present; live *fire* not observed.
- **AC#1/#2/#4 (L4 auto-merge, L2 human-merge, bare-invocation)** — DEFERRED to
  **#451**: need a main-checkout session + irreversible scratch PRs/merges to `main`.
  Runbook lives in `docs/verification/golem-e2e-411.md` (new `docs/verification/` tree).

**Why parked, not merged:** the adversarial pre-PR review (ship-issue's own harness,
the thing AC#5 documents) ran the full **3 cycles (cap)** and never went `clean`.
Cycle 1's 4 blocking findings all reduced to one real point — `Closes #411` while 3/5
ACs deferred violates `[[umbrella-issue-closes-vs-contributes]]`. Fixed by **re-scoping

# 411's body** to AC#3/#5 (sanctioned by the reviewer) so the close is honest. Residual

cycle-3 blocker (MEDIUM 0.55): AC#5 is *static* while the issue title says *"Live"* —
a genuine merge-time judgment call, so it's a **dead-end → human decides** (close on
static AC#5, or switch to `Contributes to #411` and let #451 close it). L3 merge
invariant = never auto-merge on a non-clean review loop, even when CI is green.

**Filed this run:** #451 (live exercise runbook), #454 (deferred process-integrity
findings: self-grading sequencing + live/static self-consistency).

**Reusable lesson:** a "live e2e verification" issue worked *from inside the target's
own worktree* can only ever do the static/nesting-guard half — the live half needs a
separate main-checkout session. Say so up front and split via a follow-up; don't let
`Closes #N` silently close a live-titled issue on static evidence. Also: retype a
docs-only verification-report commit `docs(...)`, not `test(...)`, for correct
git-cliff CHANGELOG grouping (caught by the conventions reviewer). Links:
[[umbrella-issue-closes-vs-contributes]], [[next-issue-read-issue-comments]].
