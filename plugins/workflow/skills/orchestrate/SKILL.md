---
description: Master orchestrator for PR-per-golem parallel work. Dispatch golems (one issue/branch/worktree/PR each) running the autonomous pipeline, monitor PR + issue-label state, surface progress, rebase across PRs, and run an integration train that lands a batch of green PRs (merge→rebase→merge) with one approval. Use when running 2+ independent issues in parallel, watching golem PRs, or integrating agent work. Local-merge topology preserved as opt-in.
---

# Orchestrate

The default topology is **PR-per-golem**: the orchestrator is a **live
interactive session** that dispatches **golems** (each a PROCESS owning one
issue → branch → worktree → PR, running the autonomous `/next-issue --autonomous` →
`/ship-issue` pipeline), then monitors, surfaces, and rebases across their
PRs. **The orchestrator never merges golem branches into its own** — humans
merge PRs (or per-golem auto-merge, which for an autonomous golem requires BOTH
`AUTOMERGE=1` and `AUTOMERGE_AUTONOMOUS=1` — see `ship-issue` §
Environment Variables).

**Hard constraints** (architecture — do not violate):

- **Golems are processes, never Workflow subagents.** Each golem's
  `/ship-issue` owns the single permitted Workflow nesting level (its review
  harness). Spawning a golem as a Workflow/Task subagent makes that harness
  throw. Dispatch golems as containers (`/provision-agent`) or worktree-bound
  shell processes — see `mode-protocol.md` § Golem Dispatch Modes.
- **The orchestrator session is live/interactive, not a workflow.** It surfaces
  progress and takes commands mid-flight. It uses the Workflow harness
  (`workflow.js`) ONLY for bounded fan-out: the monitor poll and the cross-PR
  rebase dispatch.
- **PR + issue-label state are authoritative**; `.worktrees/.status/*.json` is a
  fast cache consulted only to fill display gaps.

**Companion files** (load before the matching phase):

- `mode-protocol.md` — execution + golem dispatch modes, decision tree
- `pool-train-protocol.md` — Phase P (worker pool) + Phase T (integration train)
  full step-by-step protocol
- `merge-protocol.md` — cross-PR rebase conflict classification + test-runner
  detection + integration-train sequencing/CI-subset policy (live); merge/sync +
  local-merge sections marked opt-in legacy
- `workflow.js` — the monitor-poll + cross-PR-rebase + train-order + pool-refill
  harness (invoked via the Workflow tool; never edited at runtime)

**Invocation patterns:**

| Invocation | Phase |
| ---------- | ----- |
| `/orchestrate dispatch <N…>` or `dispatch <count>` | Phase D — Dispatch golems |
| `/orchestrate pool <N>` | Phase P — Worker pool (set size, refill from backlog) |
| `/orchestrate tracks [N]` | Phase P — Compose 2–4 ordered, low-collision tracks from the backlog |
| `/orchestrate drain` / `pause` / `resume` | Phase P — Pool refill controls |
| `/orchestrate` or `/orchestrate status` | Phase M — Monitor (one sweep) |
| `/orchestrate monitor` / `watch` | Phase M — Monitor loop |
| `/orchestrate rebase` or `rebase <N>` | Phase R — Cross-PR rebase |
| `/orchestrate train` or `train <N…>` | Phase T — Integration train (land a batch) |
| `/orchestrate mode` | Phase 0 — Mode selection |
| `/orchestrate spawn <N>` / `teardown <agent>` | Phase 5 — Container mgmt |
| `/orchestrate merge <N>` / `merge all` / `sync` | Local-merge (OPT-IN, legacy) |
| `/orchestrate review` | Local-merge review (OPT-IN, legacy) |

## Phase D — Dispatch

Spin up N golems, each owning one issue end-to-end. Golems are **processes**;
dispatch is sequential and cheap — **not** workflow-driven.

1. **Select issues** by priority using the ordering in
   `next-issue/state-format.md` (exclude issues already labeled
   `status/in-progress`, `status/pr-pending`, `status/commit-pending`,
   `status/on-hold`). Accept explicit issue numbers if provided. **Read each
   selected issue's `effort/*` and `severity/*` labels now** — they decide
   whether the golem launches fully-autonomous or **plan-gated** (step 3).

1. **Choose the dispatch mode** per issue from `mode-protocol.md`:

   - **Container golem** (Mode 3, primary) — `batch_size ≥ 2` or session at
     capacity. Invoke `/provision-agent` (Phase 5 Spawn).
   - **Worktree golem** (Mode 2) — 1–2 issues with session capacity.
     `git worktree add .worktrees/issue-{N} -b feat/issue-{N}` and launch the
     pipeline in a worktree-bound shell process.

1. **Preflight the launch permissions (once, before the first dispatch).** The
   documented worktree-golem launch is a bare `tmux new-session …`, which the
   auto-mode classifier **denies** (`[Create Unsafe Agents]`) unless the host
   has authorized the launch rules — a hard, opaque wall on the very first
   `/orchestrate dispatch`. Because the launch shape is fixed, detect this in
   advance instead of failing opaquely:

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/golem-launch.sh preflight
   ```

   It checks **both** scopes — project-local `.claude/settings.local.json` and
   global `~/.claude/settings.json` — for the three required rules
   (`Bash(tmux new-session:*)`, `Bash(tmux ls:*)`, `Bash(tmux kill-session:*)`).
   If they are present in either scope it is a no-op; if absent in both it
   prints the exact rules + the scope choice (project-local vs global) and exits
   3. **Suggest + ask, never write silently:** surface the suggestion and let
   the operator authorize the add — adding settings is itself permission-gated
   by design, so do NOT write the rule for them. Under auto mode a missing rule
   should yield a permission decision (always-allow → write the rule; allow-once
   → proceed this run), not a hard classifier wall.

1. **Launch the autonomous pipeline** as a process in each golem:

   ```bash
   # Inside the golem's container tmux or worktree shell — launch INTERACTIVE
   # with `--permission-mode auto` passed EXPLICITLY (never headless `claude -p`,
   # never --dangerously-skip-permissions — see golem-supervised-auto-mode / #570).
   # The explicit flag is required: a fresh worktree is untrusted, so Claude Code
   # does NOT load its copied settings.local.json `defaultMode: auto` and would
   # fall back to `default` and prompt-storm (#585). The harness
   # `--permission-mode auto` is distinct from the `/next-issue` `--autonomous`
   # skill flag (deprecated alias `--auto`) — both are needed.
   # Autonomous /next-issue invokes /ship-issue in-turn, so the first prompt
   # reaches Branch + PR on its own. The `;`-chained second prompt is a resume
   # backstop, NOT `&&`: it must run even if the first exits non-zero before
   # shipping. If the first already shipped (state file deleted), the second is a
   # near no-op ("No in-progress issue found" → stop):
   claude --permission-mode auto "/workflow:next-issue {N} --autonomous" ; claude --permission-mode auto "/workflow:ship-issue --autonomous"
   ```

   For a **worktree golem** the process is started by a `tmux new-session`.
   **Emit ONE standalone `tmux new-session` per golem** — use the bundled helper
   once per issue:

   ```bash
   # One bare new-session per golem (matches Bash(tmux new-session:*)).
   ${CLAUDE_PLUGIN_ROOT}/scripts/golem-launch.sh launch {N}
   ```

   **Never wrap N launches in a shell `for` loop.** The allow rule matches a
   *bare* `tmux new-session …` command, but a `for golem in …; do tmux
   new-session …; done` makes the whole Bash invocation a for-loop **string**
   that does NOT match `Bash(tmux new-session:*)` → re-denied by the classifier.
   To dispatch a batch, call `golem-launch.sh launch {N}` once per issue (one
   Bash tool call each), never a single looping call. (`golem-launch.sh print
   {N}` emits just the launch line if you want to run the bare `tmux
   new-session` yourself.)

   **Plan gate (from the labels read in step 1).** `--autonomous` is **not** a blanket
   plan-skip — `/next-issue` decides per issue (see `next-issue/SKILL.md` §
   Autonomous Mode):

   - **`effort/trivial` or `effort/small`, and NOT `severity/critical`** →
     fully autonomous, no plan stop. The launch above runs unattended to a PR.
   - **`effort/medium`, `effort/large`, `severity/critical`, or no `effort/*`
     label** → **plan-gated**: the golem builds the plan and BLOCKS at
     `ExitPlanMode` awaiting human approval (shown BLOCKED in
     `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`). The operator attaches via
     `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`, refines and approves the
     plan in-session — then the SAME session continues autonomously through
     implement → review → push/PR with the refined plan in-context.

   **Plan approval requires a HUMAN keystroke — it is not agent-drivable (#29).**
   At the `ExitPlanMode` prompt only **option 1 ("Yes, and use auto mode")** lets
   the SAME session continue autonomously to a PR, but selecting it trips the
   auto-mode classifier when an orchestrating agent relays it — so a human must
   press it in a real TTY (attach via `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh
   {N}`). When dispatching plan-gated (medium+/critical) golems, surface this:
   their plan approval is a human keystroke at the attached TTY, not something the
   orchestrator can answer for them. See `mode-protocol.md` § *Plan gate by
   effort/severity* for the full option-1-vs-option-2 classifier contract.

   The launch command is identical either way (the policy lives in
   `/next-issue`); dispatch only needs to **expect** medium+/critical golems to
   block at the plan step. To override per golem, append `--plan-gate` (force the
   checkpoint on a small issue) or `--force-auto` (force full autonomy on a
   medium+/critical one) to the `/next-issue {N} --autonomous` prompt.

   The pipeline runs unattended to a green, review-clean PR (after plan approval
   for a plan-gated golem), or, per-golem, queues GitHub auto-merge when BOTH
   `AUTOMERGE=1` and `AUTOMERGE_AUTONOMOUS=1` are set — `AUTOMERGE=1` alone is a
   no-op for an autonomous golem and falls through to human merge.

1. **Label + cache**: ensure each dispatched issue is `status/in-progress`
   (the autonomous `/next-issue` does this) and write the initial golem cache
   entry to `.worktrees/.status/{golem}.json` (schema:
   `schemas/golem-status.schema.json`).

1. **Report** the dispatch table: golem → issue → branch → mode → access
   command (for container golems, the `docker exec … tmux attach` line).

## Phase P — Worker Pool

**Companion file**: `pool-train-protocol.md` § Phase P (load before this phase)
carries the full worker-pool protocol. Phase D dispatches a fixed **set** of
golems once; Phase P turns it into a fixed-size self-refilling **pool**: up to
**N** concurrent golems, refilling each freed slot from the non-colliding backlog
into a **fresh** worktree — bounded footprint (≤ N) plus a clean **drain**
off-switch. The pool feeds work in; the train (Phase T) lands it. Pool policy
lives in `.worktrees/.status/pool.json` (schema `schemas/pool-status.schema.json`)
— `size` and the three-state `accepting` (`accepting`/`draining`/`paused`). The
refill loop advances on each Phase M sweep (no daemon) via `workflow.js`
(`mode: "pool"`); live controls (`pool <N>`/`drain`/`pause`/`resume`) flip
`pool.json` for the next sweep.

## Phase M — Monitor

Authoritative status comes from **PR + issue-label state**. The
`.worktrees/.status/*.json` cache only fills display gaps.

1. **Enumerate the open-PR set** and cross-reference linked issues:

   ```bash
   # GitHub
   gh pr list --state open --json number,headRefName,body,title
   # GitLab
   glab mr list --json   # or: glab mr list
   ```

   Map each PR to its issue via the `Closes #N` line that `/ship-issue`
   writes into the PR body.

1. **Invoke the Workflow tool** on `~/.claude/skills/orchestrate/workflow.js`
   with:

   ```text
   args: {
     prs:  [{ number, branch, issue, golem }, …],
     base: "<base branch, e.g. main>",
     mode: "poll"
   }
   ```

   The harness fans a read-only poll across all PRs as one parallel barrier
   under a shared budget (per-PR checkpoint → resumable mid-list) and returns
   `pr_status[]` (`ci`, `review`, `label_state`, `behind_base`, `review_cycle`,
   `blocking`, `summary`).

1. **Render the live status table** from `pr_status`:

   ```text
   # Golem Status

   | Golem   | Issue | Branch            | PR   | CI       | Review            | Cycle | Blocking |
   |---------|-------|-------------------|------|----------|-------------------|-------|----------|
   | agent01 | #142  | feat/issue-142    | #310 | passing  | approved          | 2     | —        |
   | agent02 | #89   | feat/issue-89     | #311 | failing  | changes-requested | 1     | ⚠ yes   |
   | agent03 | #201  | feat/issue-201    | —    | —        | (no PR yet)       | 0     | —        |
   ```

1. **Flag the human** when a PR is green + review-clean (`ci: passing`,
   `review: approved`/`none`, `blocking: false`) — it is awaiting merge.

1. **On a `ci: failing` PR, triage infra-flake vs real before surfacing it as a
   regression.** Each golem's own `/ship-issue` CI-wait already runs this
   triage (classify by failing-step name vs the PR's changed files; auto-retry a
   known infra/setup flake once via `gh run rerun --failed`; collapse a cascade
   aggregation failure to its upstream root cause — see `ship-issue`
   SKILL.md § "If checks fail — triage" and `mode-protocol.md` § *CI-failure
   triage contract*). When surfacing a failing PR in the monitor table, mirror
   that classification: report a cascade failure once under its root cause, and
   distinguish "infra flake — retried" from "real failure — escalated" so the
   operator is not flagged to investigate a buildx flake as if it were a code
   regression. The triage adds no new hard bound — its retry is env-overridable
   (`LIBRARIAN_CI_INFRA_RETRIES`, default 1) and degrades to escalate-with-note,
   never blocking shipping.

1. **Loop** (for `monitor`/`watch`): re-poll on an interval, surfacing changes.
   Between sweeps, accept mid-flight commands (see Surface below).

**Supervised live golems (pre-PR).** The PR poll above covers golems that have
opened a PR. While a golem is still working it has no PR yet, so watch it
TTY-free instead — `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh` renders the `.worktrees/.status/*.json` cache
(phase/branch/commits) and surfaces which golems are **BLOCKED** on a permission
decision, fed by the `Notification` hook (`.claude/hooks/golem-notify.sh` →
`.worktrees/.status/feed.jsonl`). When one is flagged, `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`
attaches its real TTY (worktree session `golem-{N}`, or a container golem's
`claude` session via `docker exec`) so the human answers the prompt and
detaches. Golems run interactive under `auto` mode — never headless
`claude -p` (no TTY = cannot answer prompts) and never
`--dangerously-skip-permissions`. See `mode-protocol.md` §
*Supervised launch & central feed*.

**Plan-gated golems block early, by design.** A golem dispatched on an
`effort/medium`/`large` or `severity/critical` issue (see Phase D step 3) pauses
at its plan checkpoint (`ExitPlanMode`) before writing any code, so it appears
BLOCKED in `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh` shortly after launch — that is the human plan
checkpoint, not a stall. Attach with `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`, refine and approve
the plan, and detach; the golem then proceeds autonomously to a PR.

**Proactive gate-watch (PUSH, not just PULL).** `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh` is a **pull**
check — the operator must run it to discover a golem parked at a permission gate
(`git push` / `gh pr create` / `gh pr merge` `ask` rules) or a plan-gate
`ExitPlanMode`. Golems park at these gates silently for minutes, so the live
session must **also arm a proactive PUSH watch at dispatch** (Phase D) and on
entering `monitor`/`watch` — otherwise it sits idle on PR-settle monitors while a
golem waits. Arm both gate channels via the `Monitor` tool (they are
**co-equal**, each catching what the other misses):

```text
Monitor({                                       # feed: ALL golems, TTY-free
  command: "${CLAUDE_PLUGIN_ROOT}/scripts/golem-gate-watch.sh --stream",
  description: "golem permission gates (feed.jsonl)",
  persistent: true,
})
Monitor({                                       # panes: live worktree golems
  command: "${CLAUDE_PLUGIN_ROOT}/scripts/golem-gate-watch.sh --stream-panes",
  description: "golem prompt overlays (tmux capture-pane)",
  persistent: true,
})
```

Each emitted `golem-{N}\t<message>` line is **one fresh gate** → raise it to the
operator and point them at `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`. The watcher emits only on the
**transition into** a fresh gate (a standing gate is not re-emitted; a gate that
clears and later re-occurs re-fires), so this is signal, not noise.

- **Feed channel** (`--stream`) — reads the classified `feed.jsonl`
  (`gate` vs `idle`, post-#600), so it works for **every** golem including
  headless/container ones and carries golem-id attribution (#587). A plan-gate
  shows here only as a generic `gate`.
- **Pane channel** (`--stream-panes`) — `tmux capture-pane` matched against the
  modal **prompt overlay** (`Do you want to proceed?` and the `ExitPlanMode`
  plan-approval prompt) on live `golem-*` sessions. It is the better catcher of
  **plan-gate** prompts (which the feed under-classifies): the prompt overlay
  renders over the alt-screen and is reliably scrapeable. A transient
  **zero-golem handoff window** (one session killed, the next not yet created) is
  a no-op poll, not a reason to terminate — the watch runs until the operator
  stops it (#621). See `mode-protocol.md` § *Gate-watch contract* for the prompt
  signatures and the capture-pane caveats.

A human operator gets the same proactive surface with **`${CLAUDE_PLUGIN_ROOT}/scripts/golem-watch.sh`**
(streams both channels). See `mode-protocol.md` § *Gate-watch contract* for the
notify/suppress/re-notify rules, and #600 (feed classification) / #587 (golem-id
attribution).

## Phase R — Cross-PR Rebase

When an earlier PR merges, later PRs touching the same files fall behind base.
Detect and rebase them — without merging anything into the orchestrator branch.

1. **Invoke the Workflow tool** on `~/.claude/skills/orchestrate/workflow.js`
   with `mode: "poll+rebase"` (same `prs`/`base` args as Phase M). The harness:

   - polls all PRs, then loops over the `behind_base` subset (loop-until-dry,
     resumable),
   - classifies each PR's conflict overlap (`none` / `trivial-only` /
     `has-logic`),
   - dispatches the **`rebase-agent`** (`agentType`) for trivial-only conflicts
     (lockfiles, generated files, imports, versions, whitespace — see
     `merge-protocol.md` § Conflict Classification),
   - escalates `has-logic` (same-function / add-add / delete-modify) conflicts.

1. **Report** `rebases[]` (auto-resolved, with strategy) and surface
   `escalations[]` **verbatim** to the human. A contradictory conflict the
   `rebase-agent` could not union is a **dead-end** — emit it with the dead-end
   summary template (`autonomy-levels.md` § *The dead-end summary template*) and
   a `dead-end` feed event (message begins `DEAD-END:`) so it surfaces distinctly
   and blocks at every level; the `rebase-agent`'s `escalated[]` entry already
   carries the why/attempted/remaining content to fold in.

1. **Push rebased branches** (the harness never pushes): for each rebased PR
   branch, the orchestrator pushes under human supervision:

   ```bash
   git push --force-with-lease origin <branch>
   ```

1. **Never** merge a golem branch into the orchestrator branch.

## Phase T — Integration Train

**Companion file**: `pool-train-protocol.md` § Phase T (load before this phase)
carries the full integration-train protocol. The train lands a **batch** of
already-green, already-approved PRs end-to-end — merge → rebase the next → merge
— with **one up-front authorization** instead of a gate per merge/rebase/push. It
is **not** a new merge mechanism but **sequencing + batch authorization** over
existing pieces: order computed by `workflow.js` (`mode: 'train'`), each rebase is
Phase R (`poll+rebase`), every outward action still flows through the live
session's `ask` gates. The flow: assemble the merge-ready batch → one up-front
`AskUserQuestion` batch approval (skipped when autonomous) → compute
`{ independents, chains, waves, order }` from pairwise file-overlap → drive the
merge/rebase/merge loop wave by wave, honoring the `pool.json` drain signal.
Autonomous runs keep every outward-action `ask` gate and the `AUTOMERGE` +
`AUTOMERGE_AUTONOMOUS` double-consent; a genuine conflict still stops the train.
The orchestrator still never merges a golem branch into its own.

## Surface — Mid-Flight Commands

Between monitor sweeps, the live session accepts:

- **`merge #N`** — the human merges PR #N (or run `gh pr merge #N` if the repo's
  merge policy allows). The orchestrator does not merge into its own branch.
- **`rebase #N`** — run Phase R scoped to PR #N.
- **`train [#N…]`** — run Phase T to land a batch of green, approved PRs
  (merge → rebase → merge) with one up-front approval.
- **`pool <N>`** — set the worker-pool size (Phase P). Grow fills free slots on
  the next sweep; shrink lets the excess golems drain.
- **`drain`** — stop pool refills; let in-flight golems finish to idle (Phase P).
- **`pause`** / **`resume`** — freeze / re-enable pool refills without draining.
- **`teardown <agent>`** — Phase 5 Teardown for a finished golem.
- **`status`** — re-run Phase M.

## Phase 0 — Mode Selection

Load `mode-protocol.md` before starting.

1. **Gather inputs**:

   ```bash
   git worktree list | /usr/bin/wc -l
   docker ps --filter "name=agent" --format "{{.Names}}" 2>/dev/null
   docker images -q "*:agent-runner" 2>/dev/null
   ```

1. **Assess the task** — effort label, batch size, file-overlap risk.

1. **Recommend a mode** using the decision tree in `mode-protocol.md`
   (including § Golem Dispatch Modes for parallel work), and present the
   tradeoff via `AskUserQuestion`.

1. **Execute**: Mode 1a/1b → run `/next-issue` directly; Mode 2 → worktree
   golem (Phase D); Mode 3 → container golem via `/provision-agent`.

## Phase 5 — Container Management

### Spawn

Invoked via `/orchestrate spawn <N>` (and by Phase D for container golems).

1. **Check prerequisites**: `docker info > /dev/null 2>&1`,
   `git rev-parse --show-toplevel`.

1. **Invoke `/provision-agent`** to read the devcontainer config, generate the
   agent docker-compose, build the image, create worktrees, and start containers.
   Each agent runs Claude Code in a tmux session.

1. **Assign issues** (priority order from `next-issue/state-format.md`) and
   launch the autonomous pipeline per golem (Phase D step 3). Write initial
   cache files to `.worktrees/.status/`.

1. **Report** spawned golems with access commands:

   ```text
   | # | Agent   | Container          | Issue | Access                                                   |
   |---|---------|--------------------|-------|----------------------------------------------------------|
   | 1 | agent01 | project-agent01-1  | #142  | docker exec -it project-agent01-1 tmux attach -t claude  |
   ```

### Teardown

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

## Local-Merge (OPT-IN, Legacy)

**Companion file**: the full local-merge protocol lives in `merge-protocol.md` §
*Local-Merge (OPT-IN, Legacy)*. Load it only when explicitly requested
(`/orchestrate merge`, `review`, `sync`).

> **OPT-IN LEGACY MODE.** The default topology is PR-per-golem (Phases D/M/R).
> Use local-merge ONLY for tightly-coupled work where golems push to no remote.
> The orchestrator merging golem branches into its own branch — and syncing back
> — is exactly what PR-per-golem replaces.

Its three legacy phases — **Merge**, **Review**, and **Sync** — are documented
step-by-step in `merge-protocol.md` § *Local-Merge (OPT-IN, Legacy)*.

## When to Use

- Running 2+ independent issues in parallel as golems (`/orchestrate dispatch`)
- Watching golem PRs through CI + review to green (`/orchestrate monitor`)
- Rebasing later PRs after an earlier PR merges (`/orchestrate rebase`)
- Landing a batch of green, approved PRs end-to-end with one approval
  (`/orchestrate train`)
- Running a fixed-size worker pool that daisy-chains a backlog and drains on
  command (`/orchestrate pool <N>`, `drain`/`pause`/`resume`)
- Composing the backlog into 2–4 ordered, low-collision tracks before dispatch
  (`/orchestrate tracks [N]`)
- Selecting an execution mode for a new task (`/orchestrate mode`)
- Spawning / tearing down container golems (`/orchestrate spawn`, `teardown`)
- Tightly-coupled worktree work with no PRs (opt-in local-merge)

## When NOT to Use

- Single-issue work — run `/next-issue` directly, no orchestration needed
- Cross-repository coordination (handle manually)
- When golems are still actively working — monitor first, merge when green
