# Provision Protocol — Step 2: Generate Agent Docker Compose

Companion to `provision-agent/SKILL.md`. This is the full Step 2 reference: the
`.worktrees/docker-compose.agents.yml` transforms, the example generated
service, and the embedded `agent-entrypoint.sh` that runs the autonomous golem
pipeline. SKILL.md Steps 1, 3, 4, and 5 surround this step.

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
     Optional: `PRE_REVIEW_STRICT`, `REVIEW_STRICT`.
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
   (`/next-issue --autonomous` → `/ship-issue`) in a named tmux session. A
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

   # Ambient autonomy opt-in (see next-issue / ship-issue contract).
   export NEXT_ISSUE_AUTONOMOUS=1
   export REVIEW_MAX_CYCLES="${REVIEW_MAX_CYCLES:-3}"
   # Optional pass-throughs (inherited from the environment if set):
   #   PRE_REVIEW_STRICT, REVIEW_STRICT

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
   # /ship-issue in-turn, so the second prompt is only a resume backstop for
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
   # `--permission-mode auto` is distinct from the `/next-issue` `--autonomous`
   # skill flag (deprecated alias `--auto`) — both are needed. When a golem hits
   # a genuinely risky prompt, the
   # Notification hook flags it and a human attaches via `tmux attach -t claude`.
   # See orchestrate § Supervised launch.
   tmux new-session -d -s claude "
       claude --permission-mode auto '/workflow:next-issue ${ISSUE} --autonomous' ; \
       claude --permission-mode auto '/workflow:ship-issue --autonomous';
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
