---
name: issue-390-ship-ci-hang-deadend
description: "#390 (Mode-3 container token consume) shipped to PR #440 but DEAD-ENDED at the merge gate on the run-all.sh CI runner hang (#441); parked for human"
metadata: 
  node_type: memory
  type: project
  originSessionId: f3d19024-d122-4503-beaa-14c19df8b5da
  modified: 2026-07-20T05:07:30.068Z
---

**#390** (feat: golem-status consumes Mode-3 container token usage — read-only
consume of externally-POSTed `top_level_tokens`+`_at`, `container` vs
`container-pending` split, `_frozen_phrase` dedup, anchor allowlisted to
`%Y-%m-%dT%H:%M:%SZ`, count numeric-guarded, docs/schema/tests) implemented +
reviewed clean at L3, PR **#440**, rebased clean onto latest main.

**DEAD-ENDED at the merge gate (2026-07-20).** PR is `MERGEABLE` (no conflict)
but blocked on CI: the `Skill/agent quality gates` "Run test suite" step was
**cancelled at the 20-min job timeout on 3 consecutive runs** (initial + 2
reruns). This is NOT the diff — the same suite passes **locally in 74s, exit 0,
all stages**. It's the pre-existing systematic `run-all.sh` CI-runner hang
tracked in **#441** (fix PR **#442** open + UNMERGED: per-stage `timeout` +
`[>>]`/`[ok]` stage markers). main passes in ~2.5min; sibling
`feature/issue-397` hangs identically.

**Merge invariant** (`orchestrate/autonomy-levels.md` §dead-end): never merge
un-green even at L3/L4 → parked, issue #390 keeps `status/pr-pending`, dead-end
note posted on PR #440, state file `next-issue-390.json` kept.

**Resume:** once #442 lands, rebase `feature/issue-390` + re-run CI; or a human
merges once a quality-gates run gets a healthy runner. Do NOT blind-retry CI
again — 3 hangs already, the fix is #442. Adversarial review's deferrables were
folded INTO the PR (anchor allowlist, corrupt/partial-POST tests, scope-drift
wording), so nothing outstanding beyond the CI unblock. See
[[auto-mode-blocks-self-merge]], [[verify-squash-merge-landed]].
