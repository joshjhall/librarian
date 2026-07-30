---
description: Provision headless agent containers from devcontainer config. Generates docker-compose, creates worktrees, starts containers with tmux-attached Claude Code sessions. Use when spinning up container agents for parallel work.
---

# Provision Agent

> **Assumes a devcontainer-based setup.** This is the one container-flavored
> skill in the `workflow` plugin: it reads a project's
> `.devcontainer/`/`docker-compose` configuration and the `INCLUDE_*` build
> args it exposes (the containers dev-image convention) to generate agent
> containers. On a project without a devcontainer/compose setup it has nothing
> to discover and does not apply — use the worktree golem flow
> (`scripts/worktree-new.sh` + `scripts/golem-launch.sh launch {N}`) instead. It
> is kept in `workflow` rather than split out, but it is not portable in the way
> the rest of the plugin is.
>
> **Setup-time permission preflight (worktree-golem fallback, #29).** The
> container path below launches `tmux new-session` *inside* the container's own
> environment, so it is not subject to the host's auto-mode classifier. But the
> portable worktree-golem fallback launches `tmux new-session` on the **host**,
> where the auto-mode classifier denies it (`[Create Unsafe Agents]`) unless the
> launch rules are authorized. Before falling back to the worktree flow, run
> `${CLAUDE_PLUGIN_ROOT}/scripts/golem-launch.sh preflight` once — it checks
> BOTH `.claude/settings.local.json` and `~/.claude/settings.json` for
> `Bash(tmux new-session:*)`, `Bash(tmux ls:*)`, and `Bash(tmux kill-session:*)`,
> and if absent prints the exact rules + scope choice. **Suggest + ask, never
> write settings silently.** Then launch with one standalone `tmux new-session`
> per golem (`golem-launch.sh launch {N}`, once per issue — never a `for`-loop
> wrapper, which the rule does not match). See `orchestrate/mode-protocol.md` §
> *Supervised launch & central feed*.

Creates and manages headless agent containers for parallel issue processing.
Reads the project's devcontainer configuration to generate a lean agent
container with the same language tools but without LSP servers or IDE support.

Each agent runs Claude Code in a named `tmux` session — the human can attach
directly via `docker exec -it <container> tmux attach -t claude`.

**Invocation patterns:**

- `/workflow:provision-agent` or `/workflow:provision-agent setup` → provision new agents
- `/workflow:provision-agent teardown <agent>` → stop and remove an agent
- `/workflow:provision-agent teardown all` → stop and remove all agents

## Step 1 — Discover Project Config

1. **Find devcontainer config** — check in order:

   ```bash
   # Check for devcontainer docker-compose
   ls .devcontainer/docker-compose.yml 2>/dev/null
   ls .devcontainer/docker-compose.yaml 2>/dev/null
   # Check for standalone docker-compose
   ls docker-compose.yml 2>/dev/null
   ```

1. **Extract build configuration** from the compose file:

   - Base image (`build.args.BASE_IMAGE`)
   - Build args — all `INCLUDE_*` flags that are `true`
   - Dockerfile path (`build.dockerfile` or `build.context`)
   - Volumes (especially cache volumes)
   - Environment variables
   - Supporting services (postgres, redis, etc.)
   - Capabilities (`cap_add`, `devices`)

1. **Show config summary** to the user:

   ```text
   Devcontainer config found:
     Base: mcr.microsoft.com/devcontainers/base:trixie
     Features: python-dev, node-dev, rust-dev, golang-dev, docker, dev-tools
     Services: postgres, redis
     Capabilities: SYS_ADMIN, /dev/fuse
   ```

## Step 2 — Generate Agent Docker Compose

**Companion file**: the full Step 2 reference — the
`.worktrees/docker-compose.agents.yml` transforms, the example generated
service YAML, and the embedded `agent-entrypoint.sh` (auth check, status cache
with a background PR poller, autonomous pipeline in tmux) — lives in
`provision-protocol.md` § Step 2. In outline:

1. `mkdir -p .worktrees/.status`.
1. **Write `.worktrees/docker-compose.agents.yml`** from the devcontainer
   config: same base image / Dockerfile / `INCLUDE_*` flags, plus
   `SKIP_LSP_INSTALL=true`, per-agent worktree + `.status` volumes, the golem
   environment (`AGENT_ISSUE`, `REVIEW_MAX_CYCLES`, pass-through
   `GITHUB_TOKEN`/`GH_TOKEN`; autonomy is set on the launch line via `--level 4`),
   `deploy.resources.limits` (4 CPU / 8 GB defaults via
   `AGENT_CPUS`/`AGENT_MEMORY`), `init: true`, and `command: sleep infinity`.
1. **Write `.worktrees/agent-entrypoint.sh`** — verifies git-host auth, then
   launches the autonomous golem pipeline (`/workflow:next-issue --level 4` →
   `/workflow:ship-issue`) in a named tmux session with a background PR-state poller.

See `provision-protocol.md` for the verbatim YAML and entrypoint script.

## Step 3 — Build Agent Image

1. **Check if image already exists**:

   ```bash
   docker images -q "$(basename $(pwd)):agent-runner" 2>/dev/null
   ```

1. **If not built**, build with progress reporting:

   ```bash
   docker compose -f .worktrees/docker-compose.agents.yml build agent01
   ```

   Tell the user: "Building agent image. First build may take {estimate}
   based on {feature_count} features. Subsequent agents reuse this image."

1. **If already built**, skip and report: "Agent image ready."

## Step 4 — Create Worktrees and Start Containers

For each agent to provision (e.g., agent01 through agent{N}):

1. **Create git worktree**:

   ```bash
   git worktree add .worktrees/agent{N} -b agent{N}
   ```

1. **Start container**:

   ```bash
   docker compose -f .worktrees/docker-compose.agents.yml up -d agent{N}
   ```

1. **Write initial status file** to `.worktrees/.status/agent{N}.json`.
   Container golems take the PR-per-golem path, so use the
   `golem-status.schema.json` shape (not the legacy `agent-status` shape).
   The entrypoint's poller then maintains it; this is a **cache only** — the
   orchestrator's monitor poll over PR + issue-label state is authoritative:

   ```json
   {
     "golem": "agent{N}",
     "kind": "container",
     "container": "{project}-agent{N}-1",
     "issue": {ISSUE},
     "issue_title": "{title}",
     "branch": "agent{N}",
     "state": "starting",
     "started": "{ISO datetime}",
     "last_activity": "{ISO datetime}",
     "errors": []
   }
   ```

   The container's `agent-entrypoint.sh` owns pipeline startup (auth check →
   `/workflow:next-issue --level 4` → `/workflow:ship-issue` in the `claude` tmux session), so
   no separate `docker exec ... tmux new-session` is needed here.

## Step 5 — Report

Show a summary table with access commands:

```text
# Agents Provisioned

| # | Agent    | Container          | Branch   | Access Command                                           |
|---|----------|--------------------|----------|----------------------------------------------------------|
| 1 | agent01  | project-agent01-1  | agent01  | docker exec -it project-agent01-1 tmux attach -t claude  |
| 2 | agent02  | project-agent02-1  | agent02  | docker exec -it project-agent02-1 tmux attach -t claude  |
| 3 | agent03  | project-agent03-1  | agent03  | docker exec -it project-agent03-1 tmux attach -t claude  |

To assign issues, use: /workflow:orchestrate spawn (assigns from priority queue)
To interact directly: docker exec -it <container> tmux attach -t claude
To check status: /workflow:orchestrate status
```

## Teardown

### Single Agent

`/workflow:provision-agent teardown agent01`:

1. **Stop and remove container**:

   ```bash
   docker compose -f .worktrees/docker-compose.agents.yml stop agent01
   docker compose -f .worktrees/docker-compose.agents.yml rm -f agent01
   ```

1. **Check whether the work is safe to drop** — a golem's branch lives on its
   PR once pushed, so teardown is safe as soon as the PR exists, even if the
   worktree still holds local-only state:

   ```bash
   # If a PR exists (open OR merged), the work is on the PR — safe to remove.
   gh pr list --head agent01 --state all --json number,state

   # Only when NO PR exists, fall back to the local-commit check:
   cd .worktrees/agent01
   git status --porcelain
   git log --oneline agent01 ^main
   ```

   If a PR exists, proceed without warning. Only when there is **no PR** and
   there are uncommitted changes or unmerged commits, warn the user and ask
   for confirmation before removing the worktree.

1. **Remove worktree and branch** (if confirmed):

   ```bash
   git worktree remove .worktrees/agent01
   git branch -d agent01
   ```

1. **Remove status file**: Delete `.worktrees/.status/agent01.json`

### All Agents

`/workflow:provision-agent teardown all`:

Iterate over all agent status files in `.worktrees/.status/` and tear down
each one. Using the same PR-existence check as the single-agent path, warn
only about agents that have **no PR** and unmerged local work.

After all agents are removed, clean up:

```bash
# Remove docker-compose if no agents remain
rm -f .worktrees/docker-compose.agents.yml
rm -f .worktrees/agent-entrypoint.sh

# Remove .status directory if empty
rmdir .worktrees/.status 2>/dev/null
```

## When to Use

- Spinning up parallel agents for batch issue processing
- `/workflow:orchestrate spawn` delegates here for container creation
- Setting up a container agent environment for the first time
- Tearing down agents after work is complete

## When NOT to Use

- Ephemeral worktrees (Mode 2) — use `git worktree add` directly
- Single-session work — no container needed
- Projects without a devcontainer or Dockerfile
