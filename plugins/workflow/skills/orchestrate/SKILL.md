---
description: Master orchestrator for PR-per-golem parallel work. Dispatch golems (one issue/branch/worktree/PR each) running the next-issue → ship-issue pipeline at a chosen autonomy level (L1–L4), monitor PR + issue-label state, surface progress, rebase across PRs, and run an integration train that lands a batch of green PRs (merge→rebase→merge) with one approval. Use when running 2+ independent issues in parallel, watching golem PRs, or integrating agent work. Local-merge topology preserved as opt-in.
---

# Orchestrate

The default topology is **PR-per-golem**: the orchestrator is a **live
interactive session** that dispatches **golems** (each a PROCESS owning one
issue → branch → worktree → PR, running the `/workflow:next-issue` → `/workflow:ship-issue`
pipeline at a chosen **autonomy level** — L1–L4, per
`autonomy-levels.md`; passed as `--level {N}`),
then monitors, surfaces, and rebases across their PRs. **The orchestrator never
merges golem branches into its own** — a golem's own `/workflow:ship-issue` merges its PR
as the **level-aware routine gate** (auto at L3–L4, human at L1–L2, always
subject to the green-CI + clean-review merge invariant); the humans in the loop
merge anything a golem leaves for them.

**Hard constraints** (architecture — do not violate):

- **Golems are processes, never Workflow subagents.** Each golem's
  `/workflow:ship-issue` owns the single permitted Workflow nesting level (its review
  harness), so a golem MUST be its own OS process — a container
  (`/workflow:provision-agent`) or worktree-bound shell, never a Workflow/Task subagent
  (which consumes that level and makes the harness throw). Full rationale:
  `ship-issue/ship-protocol.md` § *Golem Execution Model*; dispatch mechanics:
  `mode-protocol.md` § Golem Dispatch Modes.
- **The orchestrator session is live/interactive, not a workflow.** It surfaces
  progress and takes commands mid-flight. It uses the Workflow harness
  (`workflow.js`) ONLY for bounded fan-out: the monitor poll and the cross-PR
  rebase dispatch.
- **PR + issue-label state are authoritative**; `.worktrees/.status/*.json` is a
  fast cache consulted only to fill display gaps. Why the `feed.jsonl` + `Monitor`
  gate-watch is the golem→orchestrator baseline (and how an optional HTTP sink
  would extend it to container golems without replacing it) is recorded in
  [`docs/adr/0001-golem-event-bus-multi-sink-emission.md`](../../docs/adr/0001-golem-event-bus-multi-sink-emission.md).
- **Never time out a human gate.** Every gate kept for a human — the track-setup
  approval flow, a golem's plan-approval checkpoint, a mid-flight command or
  escalation, and a dead-end at any level — **waits indefinitely; never
  lapse-and-default because the operator stepped away.** Full rule:
  `autonomy-levels.md` § *Standing rule: wait indefinitely at a human gate*.

**Companion files** (load before the matching phase):

- `mode-protocol.md` — execution + golem dispatch modes, decision tree
- `monitor-protocol.md` — Phase M (monitor) full protocol: event-driven push
  gate-watch (the default surface), the opt-in / cron-scheduled rolling status
  sweep, slow-review posture
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
| `/workflow:orchestrate dispatch <N…>` or `dispatch <count>` | Phase D — Dispatch golems |
| `/workflow:orchestrate pool <N>` | Phase P — Worker pool (set size, refill from backlog) |
| `/workflow:orchestrate tracks [N]` | Phase P — Compose 2–4 ordered, low-collision tracks, then run the setup flow (propose → approve → choose L1–L4 → dispatch) |
| `/workflow:orchestrate tracks [N] --runbook` | Phase P — Same setup flow, stopping **before** dispatch: bank the plan and render an operator runbook to launch lanes by hand, one at a time (#673) |
| `/workflow:orchestrate drain` / `pause` / `resume` | Phase P — Pool refill controls |
| `/workflow:orchestrate` or `/workflow:orchestrate status` | Phase M — Monitor (one-shot status sweep, on demand) |
| `/workflow:orchestrate monitor` / `watch` | Phase M — Monitor loop (event-driven push gate-watch by default; rolling sweep opt-in) |
| `/workflow:orchestrate rebase` or `rebase <N>` | Phase R — Cross-PR rebase |
| `/workflow:orchestrate train` or `train <N…>` | Phase T — Integration train (land a batch) |
| `/workflow:orchestrate mode` | Phase 0 — Mode selection |
| `/workflow:orchestrate spawn <N>` / `teardown <agent>` | Phase 5 — Container mgmt |
| `/workflow:orchestrate merge <N>` / `merge all` / `sync` | Local-merge (OPT-IN, legacy) |
| `/workflow:orchestrate review` | Local-merge review (OPT-IN, legacy) |

## Phase D — Dispatch

Spin up N golems, each owning one issue end-to-end. Golems are **processes**;
dispatch is sequential and cheap — **not** workflow-driven.

> **Track setup flow feeds dispatch.** When dispatch follows a `/workflow:orchestrate
> tracks` composition, the issues and their **autonomy level** come from the
> approved setup flow (`pool-train-protocol.md` § *The setup flow*) — the
> operator has already approved the lanes and chosen L1–L4 (offered as L1–L3 for
> a track holding a `severity/critical` issue). Dispatch one golem per **track
> head** and pass the level in as `--level {N}` on its `/workflow:next-issue` prompt so
> the run's state file records it. A plain `/workflow:orchestrate dispatch <N…>` without a
> composition selects by priority as below and asks the L1–L4 question itself.

1. **Select issues** by priority using the ordering in
   `next-issue/state-format.md` (exclude issues already labeled
   `status/in-progress`, `status/pr-pending`, `status/commit-pending`,
   `status/on-hold`). Accept explicit issue numbers if provided. **Read each
   selected issue's `severity/*` label now** — a `severity/critical` issue is
   **capped at L3**, so it always keeps its plan gate regardless of the level
   requested (step 3). The **autonomy level** (not the effort labels) decides
   whether the golem's plan checkpoint is auto-passed: skipped only at L4,
   kept at L1–L3.

1. **Choose the dispatch mode** per issue from `mode-protocol.md`:

   - **Container golem** (Mode 3, primary) — `batch_size ≥ 2` or session at
     capacity. Invoke `/workflow:provision-agent` (Phase 5 Spawn).
   - **Worktree golem** (Mode 2) — 1–2 issues with session capacity.
     `git worktree add .worktrees/issue-{N} -b feat/issue-{N}` and launch the
     pipeline in a worktree-bound shell process.

1. **Preflight the launch permissions (once, before the first dispatch).** The
   documented worktree-golem launch is a bare `tmux new-session …`, which the
   auto-mode classifier **denies** (`[Create Unsafe Agents]`) unless the host
   has authorized the launch rules — a hard, opaque wall on the very first
   `/workflow:orchestrate dispatch`. Because the launch shape is fixed, detect this in
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

   **The allow-list is necessary, not sufficient — the classifier is a separate
   gate (#282).** Preflight only asserts the three `Bash(tmux …)` allow rules are
   present; it does **not** and **cannot** vouch that a launch will clear the
   auto-mode **safety classifier** (`[Create Unsafe Agents]`). That classifier is
   a distinct layer that re-evaluates each `tmux new-session` launch on its own
   judgment, and it is **non-deterministic** on this launch shape — the same
   byte-identical command can be denied once and approved on immediate retry. So
   the correct response to a `[Create Unsafe Agents]` denial on a **launch** is to
   **retry the identical `golem-launch.sh launch {N}` command** (it typically
   passes on the next try) — **not** to fall back to a manual `!` paste, which the
   retry makes unnecessary. This is the launch-side face of the same classifier
   non-determinism that the plan-gate `send-keys` note (below, #282) describes; a
   dedicated classifier-stable launcher entrypoint the classifier could be taught
   to trust remains open under #282, not built yet.

1. **Launch the autonomous pipeline** as a process in each golem:

   ```bash
   # Inside the golem's container tmux or worktree shell — launch INTERACTIVE
   # with `--permission-mode auto` passed EXPLICITLY (never headless `claude -p`,
   # never --dangerously-skip-permissions — see golem-supervised-auto-mode / #570).
   # The explicit flag is required: a fresh worktree is untrusted, so Claude Code
   # does NOT load its copied settings.local.json `defaultMode: auto` and would
   # fall back to `default` and prompt-storm (#585). The harness
   # `--permission-mode auto` is distinct from the `/workflow:next-issue` `--level {N}`
   # skill flag (the autonomy dial) — both are needed.
   # An L4 /workflow:next-issue invokes /workflow:ship-issue in-turn, so the first prompt
   # reaches Branch + PR on its own. The `;`-chained second prompt is a resume
   # backstop, NOT `&&`: it must run even if the first exits non-zero before
   # shipping. If the first already shipped (state file deleted), the second is a
   # near no-op ("No in-progress issue found" → stop):
   claude --permission-mode auto "/workflow:next-issue {N} --level 4" ; claude --permission-mode auto "/workflow:ship-issue"
   ```

   For a **worktree golem** the process is started by a `tmux new-session`.
   **Emit ONE standalone `tmux new-session` per golem** — use the bundled helper
   once per issue:

   ```bash
   # One bare new-session per golem (matches Bash(tmux new-session:*)).
   # Pass the run's chosen autonomy level so the golem runs at it (not L4).
   ${CLAUDE_PLUGIN_ROOT}/scripts/golem-launch.sh launch {N} --level {L}
   ```

   **Pass `--level {L}`** — the level the operator chose at setup (L1–L4). Omit
   it and the launcher defaults to `4` (the pre-#301 behavior); `GOLEM_LEVEL` in
   the environment is the fallback when the flag is absent. Threading the chosen
   level is what lets a plan-gated (L1–L3) golem actually stop at `ExitPlanMode`
   — see the plan-gate note below.

   **Optional `GOLEM_MODEL` env knob** — set `GOLEM_MODEL` in the environment
   (e.g. `GOLEM_MODEL=sonnet`) to pass `--model` to every golem's `claude`
   invocation (both the next-issue and ship-issue calls), running the whole
   multi-hour pipeline on a cheaper model. Unset (the default) emits no `--model`
   and the golem inherits the operator/session default (typically Opus) — the
   launch line is byte-identical to the pre-knob behavior.

   **Never wrap N launches in a shell `for` loop.** The allow rule matches a
   *bare* `tmux new-session …` command, but a `for golem in …; do tmux
   new-session …; done` makes the whole Bash invocation a for-loop **string**
   that does NOT match `Bash(tmux new-session:*)` → re-denied by the classifier.
   To dispatch a batch, call `golem-launch.sh launch {N} --level {L}` once per
   issue (one Bash tool call each), never a single looping call.
   (`golem-launch.sh print {N} --level {L}` emits just the launch line if you
   want to run the bare `tmux new-session` yourself.)

   **Plan gate (from the golem's autonomy level).** Whether a golem stops for
   plan approval is set by its **level**, not its effort labels: an **L4** golem
   (critical cap not fired) runs fully autonomous to a PR with no plan stop; a
   golem **below L4** (or a capped `severity/critical`) is **plan-gated** — it
   builds the plan and BLOCKS at `ExitPlanMode` awaiting human approval (shown
   BLOCKED in `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`), then continues
   autonomously through implement → review → push/PR once approved. The launch
   command is identical either way (the policy lives in `/workflow:next-issue`); dispatch
   only needs to **expect** a below-L4 golem to block at the plan step.

   Plan approval is **broker → human decides → orchestrator sends the keystroke**:
   present the plan in-session, and once the operator approves run
   `tmux send-keys -t golem-{N} 1 Enter` (option 1 — the SAME-session auto-mode
   continuation), then `${CLAUDE_PLUGIN_ROOT}/scripts/golem-resolve.sh {N}` to
   clear the now-stale BLOCKED gate. The full broker-send contract — the
   option-1-vs-option-2 classifier divergence, the `#29`/#281/#282 non-determinism
   and the attach-and-press fallback — lives in `mode-protocol.md` § *Plan gate by
   level*.

   **A multi-question `AskUserQuestion` form is NOT single-`send-keys`-brokerable
   (#467).** That `1 Enter` send assumes a single-question prompt; a golem raising
   2+ questions in one form paints a tabbed widget where a digit lands on the
   wrong question and the review screen will `Submit` a **partially-answered**
   form — resolving the gate wrongly rather than failing visibly. The gate-watch
   labels that class distinctly (*"escalation (multi-question form) —
   cancel-then-relay, do NOT send-keys"*); broker it by cancelling the form and
   relaying every decision as one text directive — `monitor-protocol.md` § *A
   multi-question form is brokered differently*.

   The pipeline runs unattended to a green, review-clean PR (after plan approval
   for a plan-gated golem below L4); its own `/workflow:ship-issue` then merges as the
   level-aware routine gate — **auto at L3–L4**, **human at L1–L2** — always
   subject to the green-CI + clean-review merge invariant.

1. **Label + cache**: ensure each dispatched issue is `status/in-progress`
   (the autonomous `/workflow:next-issue` does this) and write the initial golem cache
   entry to `.worktrees/.status/{golem}.json` (schema:
   `schemas/golem-status.schema.json`). **Stamp `started`** (ISO-8601 Z, e.g.
   `date -u +%FT%TZ`) in that initial write — it is the ELAPSED source for the
   status-checkpoint table (`golem-status.sh --checkpoint`, #283); a worktree
   (Mode 2) golem has no other writer for it, so an omitted `started` renders
   ELAPSED as `—`. The Mode-3 container entrypoint already sets it in its
   `write_status` (`provision-agent/provision-protocol.md`).

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
— `size` and the three-state `queue` (`accepting`/`draining`/`paused`). The
refill loop advances on each Phase M sweep (no daemon) via `workflow.js`
(`mode: "pool"`); live controls (`pool <N>`/`drain`/`pause`/`resume`) flip
`pool.json` for the next sweep. When **tracks** are active (composed via
`/workflow:orchestrate tracks`), refill is **lane-aware**: a freed slot pulls its own
track's next queued issue and only falls back to the global collision-aware pick
once that track is exhausted — see `pool-train-protocol.md` § Lane-aware serial
refill.

## Phase M — Monitor

**Companion file**: `monitor-protocol.md` (load before this phase) carries the
full monitor protocol — the authoritative PR + issue-label status sweep and live
table, the CI-failure triage mirroring, the level-scaled sweep cadence and its
compact **per-track status+burn checkpoint** (`golem-status.sh --checkpoint`,
issue #283), supervised pre-PR live golems, the plan-gated early-block, the
never-kill
slow-review posture, the proactive push gate-watch (feed + pane channels), and
**brokered gate resolution** (§ *Resolve a brokered gate centrally*): relaying an
escalation/dead-end decision back into a golem via `golem-inbox.sh` from this
session — present the payload once with `AskUserQuestion`, `answer` it into the
golem's inbox, no `golem-attach` per golem (#227). A plan-gate is **not** brokered
this way — it stays on the directed `tmux send-keys` broker (§ Phase D, #281/#29).
Authoritative status comes from **PR + issue-label state**; the
`.worktrees/.status/*.json` cache only fills display gaps.

## Phase R — Cross-PR Rebase

When an earlier PR merges, later PRs touching the same files fall behind base.
Detect and rebase them — without merging anything into the orchestrator branch.

1. **Resolve each PR's worktree** before invoking the harness. The rebase-agent
   must be told an explicit working directory — it must never improvise a
   `git checkout` in the orchestrator's own root checkout (that mutates the live
   session's tree and, since git refuses a branch already live in another
   worktree, also just fails). For every PR in the set, look its head branch up
   in the golem worktrees and pass the path as `prs[].worktree`:

   ```bash
   git worktree list --porcelain
   # match "branch refs/heads/<pr-branch>" → the preceding "worktree <path>" line
   ```

   A PR whose branch has **no** worktree: **omit** `worktree` for it — do NOT
   guess a path. The harness escalates any PR with no resolvable worktree as a
   whole-PR manual-rebase review (`no resolvable worktree context`) rather than
   dispatch the agent without an execution context.

1. **Invoke the Workflow tool** on `~/.claude/skills/orchestrate/workflow.js`
   with `mode: "poll+rebase"` (same `prs`/`base` args as Phase M, each `prs`
   entry now carrying the resolved `worktree` from the step above). The harness:

   - polls all PRs, then loops over the `behind_base` subset (loop-until-dry,
     resumable),
   - classifies each PR's conflict overlap (`none` / `trivial-only` /
     `has-logic`),
   - dispatches the **`rebase-agent`** (`agentType`) for trivial-only conflicts
     (lockfiles, generated files, imports, versions, whitespace — see
     `merge-protocol.md` § Conflict Classification),
   - escalates `has-logic` (same-function / add-add / delete-modify) conflicts.

   **Bound this invocation in wall-time (#224)** — the poll + `rebase-agent`
   dispatch fans out subagents; invoke it as a background task and apply the
   caller-side timeout. A timed-out rebase sweep is **partial** — re-queue the
   behind-base remainder on the next `poll+rebase` sweep. See `mode-protocol.md`
   § *Bounding a Workflow invocation in wall-time*.

1. **Report** `rebases[]` (auto-resolved, with strategy) and surface
   `escalations[]` **verbatim** to the human. A contradictory conflict the
   `rebase-agent` could not union is a **dead-end** — emit it with the dead-end
   summary template (`autonomy-levels.md` § *The dead-end summary template*) and
   a `dead-end` feed event (message begins `DEAD-END:`) so it surfaces distinctly
   and blocks at every level; the `rebase-agent`'s `escalated[]` entry already
   carries the why/attempted/remaining content to fold in.

   Also surface `rebase_skipped[]` — behind-base PRs the sweep never attempted
   because it hit an early exit (`reason: 'max-rebases cap' | 'budget
   exhausted'`). These are **neither resolved nor escalated**, just deferred:
   re-queue them on the next `poll+rebase` sweep (raise `maxRebases` or let the
   next sweep pick them up) rather than treating them as done. Not a dead-end —
   no human keystroke required — but do not drop them silently.

1. **Push rebased branches** (the harness never pushes): for each PR whose
   `rebases[]` entry has **`rebased: true`** (a complete mechanical resolution —
   empty `escalated[]`), the orchestrator pushes under human supervision:

   ```bash
   git push --force-with-lease origin <branch>
   ```

   **Never push a partial rebase.** An entry with `rebased: false` (non-empty
   `escalated[]`) is an incomplete rebase — its branch may still hold conflict
   markers or a half-applied rebase — and MUST NOT be force-pushed. It belongs to
   the escalation/dead-end path in step 2 above; surface it there with the
   branch's git state noted (the `rebase-agent` leaves it aborted/restored on
   escalation), never here.

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
`AskUserQuestion` batch approval (the train's escalation gate — auto-passed only
at L4) → compute `{ independents, chains, waves, order }` from pairwise
file-overlap → drive the merge/rebase/merge loop wave by wave, honoring the
`pool.json` drain signal. Below L4 the batch approval stays human; the batch
merges themselves are the routine gate (auto at L3–L4). A genuine conflict is a
dead-end that **stops the train and waits for a human at every level, L4
included**. The orchestrator still never merges a golem branch into its own.

## Surface — Mid-Flight Commands

At any point during monitor/watch, the live session accepts:

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

1. **Execute**: Mode 1a/1b → run `/workflow:next-issue` directly; Mode 2 → worktree
   golem (Phase D); Mode 3 → container golem via `/workflow:provision-agent`.

## Phase 5 — Container Management

**Companion file**: the container/worktree golem lifecycle lives in
`container-protocol.md` in this skill directory — load it only for
`/workflow:orchestrate spawn <N>` (prerequisites → `/workflow:provision-agent` → assign issues →
report access commands) or `/workflow:orchestrate teardown <agent>` (Mode 2 worktree golem
via `worktree-rm.sh`, which removes worktree + branch + tmux session in one step;
Mode 3 container golem via `docker compose stop`/`rm` + worktree removal + cache
clean). Tear down only after the golem's PR is merged or abandoned.

## Local-Merge (OPT-IN, Legacy)

**Companion file**: the full local-merge protocol lives in `merge-protocol.md` §
*Local-Merge (OPT-IN, Legacy)*. Load it only when explicitly requested
(`/workflow:orchestrate merge`, `review`, `sync`).

> **OPT-IN LEGACY MODE.** The default topology is PR-per-golem (Phases D/M/R).
> Use local-merge ONLY for tightly-coupled work where golems push to no remote.
> The orchestrator merging golem branches into its own branch — and syncing back
> — is exactly what PR-per-golem replaces.

Its three legacy phases — **Merge**, **Review**, and **Sync** — are documented
step-by-step in `merge-protocol.md` § *Local-Merge (OPT-IN, Legacy)*.

## When to Use

- Running 2+ independent issues in parallel as golems (`/workflow:orchestrate dispatch`)
- Watching golem PRs through CI + review to green (`/workflow:orchestrate monitor`)
- Rebasing later PRs after an earlier PR merges (`/workflow:orchestrate rebase`)
- Landing a batch of green, approved PRs end-to-end with one approval
  (`/workflow:orchestrate train`)
- Running a fixed-size worker pool that daisy-chains a backlog and drains on
  command (`/workflow:orchestrate pool <N>`, `drain`/`pause`/`resume`)
- Composing the backlog into 2–4 ordered, low-collision tracks before dispatch
  (`/workflow:orchestrate tracks [N]`)
- Selecting an execution mode for a new task (`/workflow:orchestrate mode`)
- Spawning / tearing down container golems (`/workflow:orchestrate spawn`, `teardown`)
- Tightly-coupled worktree work with no PRs (opt-in local-merge)

## When NOT to Use

- Single-issue work — run `/workflow:next-issue` directly, no orchestration needed
- Cross-repository coordination (handle manually)
- When golems are still actively working — monitor first, merge when green
