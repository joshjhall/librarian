---
description: Master orchestrator for PR-per-golem parallel work. Dispatch golems (one issue/branch/worktree/PR each) running the next-issue → ship-issue pipeline at a chosen autonomy level (L1–L4), monitor PR + issue-label state, surface progress, rebase across PRs, and run an integration train that lands a batch of green PRs (merge→rebase→merge) with one approval. Use when running 2+ independent issues in parallel, watching golem PRs, or integrating agent work. Local-merge topology preserved as opt-in.
---

# Orchestrate

The default topology is **PR-per-golem**: the orchestrator is a **live
interactive session** that dispatches **golems** (each a PROCESS owning one
issue → branch → worktree → PR, running the `/next-issue` → `/ship-issue`
pipeline at a chosen **autonomy level** — L1–L4, per
`autonomy-levels.md`; passed as `--level {N}`),
then monitors, surfaces, and rebases across their PRs. **The orchestrator never
merges golem branches into its own** — a golem's own `/ship-issue` merges its PR
as the **level-aware routine gate** (auto at L3–L4, human at L1–L2, always
subject to the green-CI + clean-review merge invariant); the humans in the loop
merge anything a golem leaves for them.

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
- **Never time out a human gate.** Every gate kept for a human — the track-setup
  approval flow (propose → approve → choose L1–L4), a golem's plan-approval
  checkpoint, a mid-flight command or escalation, and a dead-end at any level —
  **waits indefinitely for the answer; never lapse-and-default because the
  operator stepped away.** Only genuine level auto-passing (routine at L3–L4,
  escalation at L4) resolves a gate without a human; a dead-end waits even at L4.
  See `autonomy-levels.md` § *Standing rule: wait indefinitely at a human gate*.

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
| `/orchestrate tracks [N]` | Phase P — Compose 2–4 ordered, low-collision tracks, then run the setup flow (propose → approve → choose L1–L4 → dispatch) |
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

> **Track setup flow feeds dispatch.** When dispatch follows a `/orchestrate
> tracks` composition, the issues and their **autonomy level** come from the
> approved setup flow (`pool-train-protocol.md` § *The setup flow*) — the
> operator has already approved the lanes and chosen L1–L4 (offered as L1–L3 for
> a track holding a `severity/critical` issue). Dispatch one golem per **track
> head** and pass the level in as `--level {N}` on its `/next-issue` prompt so
> the run's state file records it. A plain `/orchestrate dispatch <N…>` without a
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
   # `--permission-mode auto` is distinct from the `/next-issue` `--level {N}`
   # skill flag (the autonomy dial) — both are needed.
   # An L4 /next-issue invokes /ship-issue in-turn, so the first prompt
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

   **Never wrap N launches in a shell `for` loop.** The allow rule matches a
   *bare* `tmux new-session …` command, but a `for golem in …; do tmux
   new-session …; done` makes the whole Bash invocation a for-loop **string**
   that does NOT match `Bash(tmux new-session:*)` → re-denied by the classifier.
   To dispatch a batch, call `golem-launch.sh launch {N} --level {L}` once per
   issue (one Bash tool call each), never a single looping call.
   (`golem-launch.sh print {N} --level {L}` emits just the launch line if you
   want to run the bare `tmux new-session` yourself.)

   **Plan gate (from the golem's autonomy level).** `--level 4` is **not** a blanket
   plan-skip beyond its own level — whether a golem stops for plan approval is set
   by its **level** (the rules-of-engagement chosen at setup), **not** its effort
   labels. `/next-issue` resolves it through
   `${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh` (#190), which derives the
   `plan_gated` disposition from the level (see `next-issue/SKILL.md` § Autonomy
   Levels):

   - **`plan_gated == false` (an L4 golem, critical cap did not fire)** →
     fully autonomous, no plan stop. The launch above runs unattended to a PR.
   - **`plan_gated == true` (dispatched below L4, or a capped `severity/critical`)**
     → **plan-gated**: the golem builds the plan and BLOCKS at
     `ExitPlanMode` awaiting human approval (shown BLOCKED in
     `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`). The operator attaches via
     `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`, refines and approves the
     plan in-session — then the SAME session continues autonomously through
     implement → review → push/PR with the refined plan in-context.

   **Plan approval is broker → human decides → orchestrator sends the
   keystroke.** The human's role at a plan-gated golem is the *decision*, not the
   physical keypress. The orchestrator presents the plan in-session (e.g. via
   `AskUserQuestion`); once the operator approves, **the orchestrator itself runs
   `tmux send-keys -t golem-{N} 1 Enter`** to select option 1 ("Yes, and use auto
   mode") — the only option that lets the SAME session continue autonomously to a
   PR. Never hand that keystroke back to the operator to paste after they have
   already approved.

   The `#29` caveat is **narrower** than "a human must physically type the key":
   what the auto-mode classifier blocks is an agent **relaying option 1 as an
   *undirected* send** — the send is denied when nothing authorizes it, but is
   accepted once the operator explicitly authorizes the gate (e.g. approves it
   in-session, or "approve all plan gates"). So the orchestrator's directed
   `tmux send-keys` after that approval is the default path. **Fallback:** if the
   send is still classifier-blocked, attach the real TTY
   (`${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`) and press option 1 there.
   After sending, verify the golem left plan mode (`⏵⏵ auto mode on`, branch in
   the status bar). A **directed** `tmux send-keys` after operator approval **is**
   agent-drivable — verified in a live batch (4/4 plan gates approved this way)
   and settled in #281: the `#29` "not agent-drivable" caveat was only ever about
   an agent relaying option 1 *through the auto-mode classifier* (the undirected
   send above), a distinct path, never `send-keys` itself. The residual concern is
   narrower — the classifier's **non-determinism** on these sends, tracked in #282
   (which is what keeps the attach-and-press fallback meaningful). See
   `mode-protocol.md` § *Plan gate by level* for the full option-1-vs-option-2
   classifier contract.

   The launch command is identical either way (the policy lives in
   `/next-issue`); dispatch only needs to **expect** a golem dispatched below L4
   (or a capped critical) to block at the plan step. To change a golem's behavior,
   dispatch it at a different `--level {N}`: an L4 golem runs fully autonomous with
   no plan stop, an L3 golem keeps the plan gate but auto-passes routine gates.
   A `severity/critical` golem cannot exceed its plan gate — the critical cap holds
   it at L3 regardless of the requested level.

   The pipeline runs unattended to a green, review-clean PR (after plan approval
   for a plan-gated golem below L4); its own `/ship-issue` then merges as the
   level-aware routine gate — **auto at L3–L4**, **human at L1–L2** — always
   subject to the green-CI + clean-review merge invariant.

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
`pool.json` for the next sweep. When **tracks** are active (composed via
`/orchestrate tracks`), refill is **lane-aware**: a freed slot pulls its own
track's next queued issue and only falls back to the global collision-aware pick
once that track is exhausted — see `pool-train-protocol.md` § Lane-aware serial
refill.

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

1. **Loop** (for `monitor`/`watch`): the periodic status sweep is **on by
   default at every level — arm it automatically, do NOT ask** ("would you like a
   sweep?" is gone; #304). On entering `monitor`/`watch`, start the rolling
   at-a-glance sweep and re-poll on its interval, surfacing changes. Between
   sweeps, accept mid-flight commands (see Surface below). The operator can
   silence or re-cadence it, but the default is armed.

   Run the sweep TTY-free via the bundled script so it works host / bare-linux /
   container identically (no `just`):

   ```text
   Monitor({                                       # rolling status sweep
     command: "${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh --watch --level N",
     description: "periodic golem status sweep (level-scaled)",
     persistent: true,
   })
   ```

   **Cadence scales by autonomy level** — higher levels assume golems run longer
   without oversight, so they sweep less often (the exact seconds live in
   `autonomy-resolve.sh sweep-interval --level N`, the single source of truth,
   #190/#304 — the skill does not re-derive them):

   | Level | Default sweep interval |
   |-------|------------------------|
   | L1    | ~3 min (180s)          |
   | L2    | ~5 min (300s)          |
   | L3    | ~8 min (480s)          |
   | L4    | ~15 min (900s)         |

   The interval is **env-overridable** via `GOLEM_SWEEP_INTERVAL` (seconds; beats
   the level default). In a **mixed-level batch** (tracks at different levels),
   key the sweep off the **lowest level present** — tightest oversight wins — i.e.
   pass `--level <min active level>`. This is a *pull* rolling sweep; it
   complements, and does not replace, the *push* gate-watch below (which fires on
   gate transitions, not on a rolling cadence).

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

**Plan-gated golems block early, by design.** A golem dispatched **below L4**
(or a capped `severity/critical`, see Phase D step 3) pauses
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

1. **Report** `rebases[]` (auto-resolved, with strategy) and surface
   `escalations[]` **verbatim** to the human. A contradictory conflict the
   `rebase-agent` could not union is a **dead-end** — emit it with the dead-end
   summary template (`autonomy-levels.md` § *The dead-end summary template*) and
   a `dead-end` feed event (message begins `DEAD-END:`) so it surfaces distinctly
   and blocks at every level; the `rebase-agent`'s `escalated[]` entry already
   carries the why/attempted/remaining content to fold in.

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

**Companion file**: the container/worktree golem lifecycle lives in
`container-protocol.md` in this skill directory — load it only for
`/orchestrate spawn <N>` (prerequisites → `/provision-agent` → assign issues →
report access commands) or `/orchestrate teardown <agent>` (Mode 2 worktree golem
via `worktree-rm.sh`, which removes worktree + branch + tmux session in one step;
Mode 3 container golem via `docker compose stop`/`rm` + worktree removal + cache
clean). Tear down only after the golem's PR is merged or abandoned.

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
