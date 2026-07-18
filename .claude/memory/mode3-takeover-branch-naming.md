---
name: mode3-takeover-branch-naming
description: "Mode 2 vs Mode 3 golem branch naming (feature/issue-{N} vs agent{N}) and where the takeover contract must branch on it"
metadata: 
  node_type: memory
  type: reference
  originSessionId: a7eed4ad-552a-4435-9f8a-8dd328150255
  modified: 2026-07-18T19:30:06.986Z
---

Worktree golem (Mode 2) branch = `feature/issue-{N}`, tmux session `golem-{N}`.
Container golem (Mode 3) branch = `agent{N}` (its `$AGENT_ID`), Claude session
`claude` inside the container; provisioned via `git worktree add
.worktrees/agent{N} -b agent{N}` and its PR is queried `gh pr list --head
"$AGENT_ID"` (provision-protocol.md:170,259). Teardown differs too: Mode 2 =
`tmux kill-session` / `worktree-rm.sh`; Mode 3 = `docker compose -f
.worktrees/docker-compose.agents.yml stop/rm <agent>`.

Issue #370 (PR #385) made the `mode-protocol.md` § *Slow-review takeover contract*
recipe mode-aware: both the "stop the golem" step AND the mandatory pre-kill PR
check had hardcoded the Mode-2 spelling. The pre-kill check bug (a `--head
feature/issue-{N}` that silently returns "no PR" for a Mode 3 golem → permits a
redundant kill even after the container golem already PR'd) was surfaced by the
ship-issue adversarial pre-PR review, not the plan — a docs edit exposing a
latent correctness gap in adjacent *unchanged* prose. The same one-line check is
restated in `monitor-protocol.md` (~line 144); both had to change in lockstep or
the companion docs drift. See [[review-wedge-root-cause]] for the takeover
contract's origin.
