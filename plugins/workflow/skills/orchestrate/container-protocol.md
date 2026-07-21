# Phase 5 — Container Management

Companion to `orchestrate/SKILL.md`. Load this only for `/orchestrate spawn <N>`
or `/orchestrate teardown <agent>` — the container/worktree golem lifecycle. It
is the least-frequently-needed orchestrate section; the default PR-per-golem
topology (Phases D/M/R) does not touch it.

## Spawn

Invoked via `/orchestrate spawn <N>` (and by Phase D for container golems).

1. **Check prerequisites**: `docker info > /dev/null 2>&1`,
   `git rev-parse --show-toplevel`.

1. **Invoke `/provision-agent`** to read the devcontainer config, generate the
   agent docker-compose, build the image, create worktrees, and start containers.
   Each agent runs Claude Code in a tmux session.

1. **Assign issues** (priority order from `next-issue/state-format.md`) and
   launch the autonomous pipeline per golem (Phase D step 3). Write initial
   cache files to `.worktrees/.status/`.

   **Wire the container golem's gate events back to the host (#407).** A
   container golem shares no filesystem with the orchestrator, so its
   `feed.jsonl` gates are invisible to the host feed/pane channels. To surface
   them the moment they emit, point the container's `GOLEM_EVENT_SINKS` (the
   #406 multi-sink emitter env) at the host's optional
   `golem-event-listener.sh` receiver — e.g. `GOLEM_EVENT_SINKS=http://<host>:${GOLEM_EVENT_LISTEN_PORT:-8787}/`,
   reaching the host over the containers#735 transport — and arm the receiver on
   the orchestrator side (see `monitor-protocol.md` § *Receive a container
   golem's gate*). The receiver appends each POST into the host `feed.jsonl`, so
   the gate then surfaces through the **same** feed channel as a worktree golem's.
   This is optional and additive: absent the sink/receiver, the container golem
   still gates correctly — its gate is just not host-visible until a sweep.

1. **Report** spawned golems with access commands:

   ```text
   | # | Agent   | Container          | Issue | Access                                                   |
   |---|---------|--------------------|-------|----------------------------------------------------------|
   | 1 | agent01 | project-agent01-1  | #142  | docker exec -it project-agent01-1 tmux attach -t claude  |
   ```

## Teardown

Invoked via `/orchestrate teardown <agent>` or `teardown all`. Tear down only
after the golem's PR is merged or abandoned.

**Worktree golem (Mode 2).** Removing the worktree, deleting its branch, **and
killing its `tmux` session is a single step** — `worktree-rm.sh` does all three
(#27):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/worktree-rm.sh {N}
```

It kills `golem-{N}` idempotently (ignore-if-absent), so a finished golem no
longer lingers in `tmux ls` / `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`
after a merge+prune. The Phase P refill loop already calls `worktree-rm.sh` when
a slot frees, so pooled golems get their sessions reaped automatically — no
separate manual `tmux kill-session -t golem-{N}` is needed. A leftover
`golem-*` session whose worktree is already gone is still cleaned by re-running
`worktree-rm.sh {N}` (the worktree/branch steps no-op; the session is killed).

**Container golem (Mode 3):**

1. `docker compose -f .worktrees/docker-compose.agents.yml stop <agent>`
1. `docker compose -f .worktrees/docker-compose.agents.yml rm -f <agent>`
1. **Remove worktree** (if the PR merged): `git worktree remove .worktrees/<agent>`
   then `git branch -d <agent>`
1. **Clean cache**: remove `.worktrees/.status/<agent>.json`
1. **Report** the teardown result.
