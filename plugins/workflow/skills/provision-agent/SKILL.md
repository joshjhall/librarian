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

- `/provision-agent` or `/provision-agent setup` → provision new agents
- `/provision-agent teardown <agent>` → stop and remove an agent
- `/provision-agent teardown all` → stop and remove all agents

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

1. **Create directories**:

   ```bash
   mkdir -p .worktrees/.status
   ```

1. **Write `.worktrees/docker-compose.agents.yml`** based on devcontainer config
   with these transforms:

   - **Same base image and Dockerfile** as devcontainer
   - **Same `INCLUDE_*` flags** — agents need the same language tools
   - **Add `SKIP_LSP_INSTALL=true`** — no IDE, no LSP servers needed
   - **Working directory**: `/workspace/{project}` (same as devcontainer)
   - **Volumes**: bind-mount `.worktrees/agent{N}/` as the project source,
     plus shared `.worktrees/.status/` for coordination
   - **Supporting services**: same services as devcontainer, with per-agent
     namespacing (e.g., separate database per agent)
   - **Resource limits**: `deploy.resources.limits` defaulting to 4 CPUs / 8GB
     RAM, overridable via `AGENT_CPUS` / `AGENT_MEMORY`. Each golem runs the
     autonomous pipeline, which spawns its own Workflow fan-out (the pre-PR
     review panel, the multi-cycle PR review, and ci-fixer). The Workflow
     concurrency cap is `min(16, cores − 2)`, so a 2-CPU golem serializes that
     fan-out to ≈0 concurrent agents; 4 CPUs yields ≈2 concurrent agents.
     Raise `AGENT_CPUS` for wider review fan-out.
   - **Agent environment**: `NEXT_ISSUE_AUTONOMOUS=1` (ambient autonomy opt-in),
     `AGENT_ISSUE` (the assigned issue), `REVIEW_MAX_CYCLES` (default 3), and a
     pass-through `GITHUB_TOKEN`/`GH_TOKEN` so the golem can push and open PRs.
     Optional: `PRE_REVIEW_STRICT`, `REVIEW_STRICT`, `AUTOMERGE`,
     `AUTOMERGE_AUTONOMOUS`. **Note:** golems are autonomous, and
     `/next-issue-ship` only takes the auto-merge fast path autonomously when
     BOTH `AUTOMERGE=1` and `AUTOMERGE_AUTONOMOUS=1` are set (the second is a
     required consent because auto-merge skips the adversarial review loop — see
     `next-issue-ship` SKILL.md § Environment Variables). Passing `AUTOMERGE=1`
     alone to a golem is intentionally a no-op: it falls through to the normal
     review loop and stops at a green PR for human merge.
   - **Init system**: `init: true` for tini zombie reaping
   - **Capabilities**: same as devcontainer (`cap_add`, `devices`)
   - **Command**: `sleep infinity` (entrypoint handles startup, tmux starts
     Claude)

   Example generated service:

   ```yaml
   services:
     agent01:
       build:
         context: ..
         dockerfile: containers/Dockerfile
         args:
           <<: *common-build-args
           SKIP_LSP_INSTALL: "true"
       volumes:
         - ../:/workspace/project:ro
         - ./.worktrees/agent01:/workspace/project-worktree
         - ./.status:/workspace/.worktrees/.status
       working_dir: /workspace/project-worktree
       environment:
         AGENT_ID: agent01
         AGENT_MODE: headless
         AGENT_ISSUE: "${AGENT01_ISSUE:-}"
         NEXT_ISSUE_AUTONOMOUS: "1"
         REVIEW_MAX_CYCLES: "${REVIEW_MAX_CYCLES:-3}"
         # Auto-merge requires BOTH keys for an autonomous golem (see notes
         # above + next-issue-ship § Environment Variables). Default off.
         AUTOMERGE: "${AUTOMERGE:-}"
         AUTOMERGE_AUTONOMOUS: "${AUTOMERGE_AUTONOMOUS:-}"
         GITHUB_TOKEN: "${GITHUB_TOKEN:-}"
         GH_TOKEN: "${GH_TOKEN:-${GITHUB_TOKEN:-}}"
       init: true
       deploy:
         resources:
           limits:
             cpus: "${AGENT_CPUS:-4}"
             memory: "${AGENT_MEMORY:-8G}"
       command: ["sleep", "infinity"]
   ```

1. **Write `.worktrees/agent-entrypoint.sh`** — a wrapper script that verifies
   git-host auth, then launches the **autonomous golem pipeline**
   (`/next-issue --auto` → `/next-issue-ship`) in a named tmux session. A
   background poller mirrors live PR state into the golem status cache. The
   human can still attach to watch via
   `docker exec -it <container> tmux attach -t claude`.

   ```bash
   #!/bin/bash
   # Agent entrypoint — runs the autonomous golem pipeline for one issue.
   # Attach to watch:  docker exec -it <container> tmux attach -t claude
   set -uo pipefail

   AGENT_ID="${AGENT_ID:-agent01}"
   ISSUE="${AGENT_ISSUE:-}"
   STATUS_FILE="/workspace/.worktrees/.status/${AGENT_ID}.json"

   # Ambient autonomy opt-in (see next-issue / next-issue-ship contract).
   export NEXT_ISSUE_AUTONOMOUS=1
   export REVIEW_MAX_CYCLES="${REVIEW_MAX_CYCLES:-3}"
   # Optional pass-throughs (inherited from the environment if set):
   #   PRE_REVIEW_STRICT, REVIEW_STRICT, AUTOMERGE, AUTOMERGE_AUTONOMOUS
   # (autonomous auto-merge needs BOTH AUTOMERGE=1 and AUTOMERGE_AUTONOMOUS=1).

   now() { command date -u +%Y-%m-%dT%H:%M:%SZ; }

   # Rewrite the golem status cache. Args: <state> [error-message]
   # Cache only — the orchestrator's monitor poll (PR + issue-label state) is
   # authoritative (golem-status.schema.json).
   write_status() {
       local state="$1" err="${2:-}"
       command mkdir -p "$(command dirname "$STATUS_FILE")"
       AGENT_ID="$AGENT_ID" ISSUE="$ISSUE" STATE="$state" ERR="$err" \
       LA="$(now)" command python3 - "$STATUS_FILE" <<'PY'
   import json, os, sys
   path = sys.argv[1]
   try:
       with open(path) as f:
           doc = json.load(f)
   except (OSError, ValueError):
       doc = {}
   doc["golem"] = os.environ["AGENT_ID"]
   doc["kind"] = "container"
   issue = os.environ.get("ISSUE", "")
   if issue.isdigit():
       doc["issue"] = int(issue)
   doc["state"] = os.environ["STATE"]
   doc["last_activity"] = os.environ["LA"]
   err = os.environ.get("ERR", "")
   doc["errors"] = [err] if err else doc.get("errors", [])
   with open(path, "w") as f:
       json.dump(doc, f, indent=2)
   PY
   }

   # No (or invalid) issue assigned → plain interactive session. ISSUE is
   # interpolated into a `claude '/next-issue ${ISSUE} …'` command below, so it
   # MUST be a bare integer — a non-numeric value could break out of the
   # single-quoted argument into the container shell. Reject anything that is
   # not all digits. (The guard is independent of permission mode: golems run
   # under the repo's `auto` mode, NOT --dangerously-skip-permissions; see the
   # orchestrate skill § Supervised launch & central feed.)
   if ! printf '%s' "$ISSUE" | command grep -qE '^[0-9]+$'; then
       if [ -n "$ISSUE" ]; then
           echo "WARNING: AGENT_ISSUE='$ISSUE' is not a numeric issue id — starting interactive session instead" >&2
       fi
       tmux new-session -d -s claude "claude"
       echo "Claude Code started in tmux session 'claude' (interactive)"
       echo "Attach with: tmux attach -t claude"
       exec sleep infinity
   fi

   # Auth precondition — a golem opens PRs and re-requests review, so a working
   # gh/GITHUB_TOKEN is required. Fail fast instead of hanging with no human
   # attached. Resolve via the repo's OP_*_REF + setup-gh convention.
   if command -v setup-gh >/dev/null 2>&1; then
       setup-gh >/dev/null 2>&1 || true
   fi
   if ! command gh auth status >/dev/null 2>&1; then
       msg="golem auth missing: gh is not authenticated. Set GITHUB_TOKEN \
   (e.g. OP_GITHUB_TOKEN_REF) or run setup-gh before launch."
       echo "ERROR: $msg" >&2
       write_status error "$msg"
       exec sleep infinity   # stay alive for inspection/teardown
   fi

   write_status working

   # Background poller: derive golem state from live PR signals every ~30s.
   status_poller() {
       while true; do
           command sleep 30
           local pr ci review state="working" blocking="false"
           pr="$(command gh pr list --head "$AGENT_ID" --state open \
               --json number --jq '.[0].number' 2>/dev/null)"
           if [ -z "$pr" ]; then
               write_status working
               continue
           fi
           # 3-state CI: a check still running must read as pending, NOT
           # passing — otherwise the cache flags the golem green while CI is
           # mid-flight. fail > pending > passing precedence.
           local checks_out
           checks_out="$(command gh pr checks "$pr" 2>/dev/null)"
           if printf '%s' "$checks_out" | command grep -qiE '\bfail'; then
               ci="failing"
           elif printf '%s' "$checks_out" | command grep -qiE '\bpending|\bin_progress|\bqueued'; then
               ci="pending"
           else
               ci="passing"
           fi
           review="$(command gh pr view "$pr" --json reviewDecision \
               --jq '.reviewDecision // "none"' 2>/dev/null)"
           if [ "$ci" = "failing" ]; then
               state="ci-failing"; blocking="true"
           elif [ "$review" = "CHANGES_REQUESTED" ]; then
               state="review-cycle"; blocking="true"
           elif [ "$ci" = "passing" ]; then
               state="pr-open"
           fi
           # Merge the richer cache fields for the monitor display.
           PR="$pr" CI="$ci" REVIEW="$review" BLOCKING="$blocking" \
           STATE="$state" LA="$(now)" command python3 - "$STATUS_FILE" <<'PY'
   import json, os, sys
   path = sys.argv[1]
   try:
       with open(path) as f:
           doc = json.load(f)
   except (OSError, ValueError):
       doc = {}
   doc["pr"] = int(os.environ["PR"])
   doc["ci"] = {"passing": "passing", "failing": "failing"}.get(
       os.environ["CI"], "pending")
   rd = os.environ["REVIEW"]
   doc["review"] = {"APPROVED": "approved",
                    "CHANGES_REQUESTED": "changes-requested",
                    "REVIEW_REQUIRED": "none"}.get(rd, "none")
   doc["blocking"] = os.environ["BLOCKING"] == "true"
   doc["state"] = os.environ["STATE"]
   doc["last_activity"] = os.environ["LA"]
   with open(path, "w") as f:
       json.dump(doc, f, indent=2)
   PY
       done
   }
   status_poller &
   POLLER_PID=$!

   # Run the autonomous pipeline in tmux: select+plan, then ship to a green,
   # review-clean PR awaiting human merge. Write a terminal state on exit.
   #
   # Chain the two prompts with ';', NOT '&&': autonomous /next-issue invokes
   # /next-issue-ship in-turn, so the second prompt is only a resume backstop for
   # a premature turn-exit — and it is needed most when the first prompt exits
   # non-zero, exactly the case '&&' would skip. If the first already shipped,
   # the second is a near no-op ("No in-progress issue found" → stop).
   #
   # Golems run in `auto` permission mode via the EXPLICIT `--permission-mode
   # auto` flag (the classifier is the noise filter; the settings' `ask` rules
   # still gate push/PR/merge) — NOT --dangerously-skip-permissions, which gates
   # nothing. The flag is explicit because a fresh worktree is untrusted, so its
   # copied settings.local.json `defaultMode: auto` is not loaded on its own and
   # the session would fall back to `default` (#585). The harness
   # `--permission-mode auto` is distinct from the `/next-issue` `--auto` skill
   # flag — both are needed. When a golem hits a genuinely risky prompt, the
   # Notification hook flags it and a human attaches via `tmux attach -t claude`.
   # See orchestrate § Supervised launch.
   tmux new-session -d -s claude "
       claude --permission-mode auto '/next-issue ${ISSUE} --auto' ; \
       claude --permission-mode auto '/next-issue-ship --auto';
       echo \$? > /tmp/golem-rc
   "
   echo "Autonomous golem started for issue #${ISSUE} in tmux session 'claude'"
   echo "Attach with: tmux attach -t claude"

   # Wait for the pipeline to finish, then settle the status cache.
   while ! tmux has-session -t claude 2>/dev/null; do command sleep 1; done
   while tmux has-session -t claude 2>/dev/null; do command sleep 10; done
   command kill "$POLLER_PID" 2>/dev/null || true

   rc="$(command cat /tmp/golem-rc 2>/dev/null || echo 1)"
   pr="$(command gh pr list --head "$AGENT_ID" --state open \
       --json number --jq '.[0].number' 2>/dev/null)"
   if [ "$rc" = "0" ] && [ -n "$pr" ]; then
       write_status green
   elif [ -n "$pr" ]; then
       write_status blocked "pipeline exited rc=$rc with PR #$pr open"
   else
       write_status blocked "pipeline exited rc=$rc with no PR"
   fi

   # Keep container alive for attach / inspection / teardown.
   exec sleep infinity
   ```

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
   `/next-issue --auto` → `/next-issue-ship` in the `claude` tmux session), so
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

To assign issues, use: /orchestrate spawn (assigns from priority queue)
To interact directly: docker exec -it <container> tmux attach -t claude
To check status: /orchestrate status
```

## Teardown

### Single Agent

`/provision-agent teardown agent01`:

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

`/provision-agent teardown all`:

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
- `/orchestrate spawn` delegates here for container creation
- Setting up a container agent environment for the first time
- Tearing down agents after work is complete

## When NOT to Use

- Ephemeral worktrees (Mode 2) — use `git worktree add` directly
- Single-session work — no container needed
- Projects without a devcontainer or Dockerfile
