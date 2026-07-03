# Orchestrate — Mode Protocol

Reference companion for `SKILL.md`. Load this when selecting an execution mode
for a task or batch of tasks. Documents the four execution modes, decision
tree, and tradeoff explanations.

---

## Four Execution Modes

| Mode | Name               | Description                                   | Concurrency |
| ---- | ------------------ | --------------------------------------------- | ----------- |
| 1a   | Current branch     | Work directly on the current branch           | 1 (serial)  |
| 1b   | New branch         | Create branch, work, merge or PR              | 1 (serial)  |
| 2    | Ephemeral worktree | `git worktree add` in current session         | 2-3 max     |
| 3    | Container agent    | Headless container with own worktree and tmux | 3-5 agents  |

### Mode 1a: Current Branch

Work directly on the current branch. Simplest path — no branch management
overhead.

**Best for**: Trivial fixes, single-file changes, `effort/trivial` issues.

**Tradeoffs**: No isolation, no clean diff. If something goes wrong, `git stash`
or `git reset` is the recovery path.

### Mode 1b: New Branch

Create a feature branch, work, then merge or PR.

**Best for**: Focused work needing a clean diff, `effort/small` issues, work
that will be reviewed via PR.

**Tradeoffs**: Branch management overhead is minimal. Conflicts possible if
other work lands on main while working.

### Mode 2: Ephemeral Worktree

Create a git worktree in `.worktrees/issue-{N}/` and work there using the
`Task` tool with `isolation: "worktree"` or a direct shell in the worktree.

**Best for**: Parallel tangent work without disrupting current session. 2-3
concurrent tasks in the same container.

**Tradeoffs**: Shares process space with main session (memory, /tmp, ports).
Limited to 2-3 concurrent due to VSCode memory ceiling (~3-4GB per Claude
instance). Worktree cleanup needed after merge.

**Lifecycle**:

```bash
# Create — scripts/worktree-new.sh wraps `git worktree add .worktrees/issue-{N}
# -b feature/issue-{N} origin/main` AND copies the machine-local files a push
# needs (GOLEM_WORKTREE_LOCAL_FILES — by default .env,
# .claude/settings.local.json) which are gitignored and so absent from a fresh
# worktree. Doing the bare `git worktree add` instead leaves those out and any
# pre-push hook that reads them fails.
${CLAUDE_PLUGIN_ROOT}/scripts/worktree-new.sh {N}

# Work (in a Task or subshell)
cd .worktrees/issue-{N}
# ... make changes, commit ...

# Merge (via /orchestrate merge)
git checkout main
git merge feature/issue-{N}

# Cleanup — removes the worktree and its feature/issue-{N} branch.
${CLAUDE_PLUGIN_ROOT}/scripts/worktree-rm.sh {N}
```

### Mode 3: Container Agent

Spin up a headless container with its own worktree, environment, and Claude
Code instance running in a tmux session.

**Best for**: Deep parallelization, batch issue processing (5+ issues),
heavy work where session memory pressure matters.

**Tradeoffs**: First build can be slow (30+ min for heavy stacks like Rust).
Higher cost (API usage per agent). Requires docker access. Human reviews at
merge points add context-switching overhead.

**Container access**: The orchestrator uses `docker exec` to interact with
agents. Claude Code runs in a named tmux session — the human can attach
directly:

```bash
docker exec -it project-agent01-1 tmux attach -t claude
```

**Lifecycle**: See `/provision-agent` skill for create/teardown.

---

## Golem Dispatch Modes

A **golem** is a per-issue sub-orchestrator: a PROCESS that owns one issue →
branch → worktree → PR and runs the autonomous pipeline (`/next-issue <N>
--autonomous`, which invokes `/ship-issue` in-turn → Branch + PR) unattended to
a green, review-clean PR. Golems are not a new isolation mechanism — they are
the **existing Mode 2 or Mode 3** with an autonomous payload and a PR exit.

The launch is **interactive** in tmux with `--permission-mode auto` passed
**explicitly** (never headless `claude -p`, never
`--dangerously-skip-permissions`; see the `golem-supervised-auto-mode` memory and
issues #570, #585). The explicit flag is required because a fresh worktree is untrusted,
so Claude Code does not load its copied `settings.local.json` `defaultMode: auto`
and would otherwise fall back to `default`. The harness `--permission-mode auto`
is distinct from the `/next-issue` `--autonomous` skill flag (deprecated alias
`--auto`) — both are needed.
Autonomous `/next-issue` invokes `/ship-issue` in-turn, so the single prompt
reaches a PR on its own. A `;`-chained second prompt is the resume backstop:

```bash
claude --permission-mode auto "/workflow:next-issue <N> --autonomous" ; claude --permission-mode auto "/workflow:ship-issue --autonomous"
```

— so that a premature turn-exit after `/next-issue` still ships: the second
prompt re-reads the state file and delivers (a near no-op if the first already
pushed a PR). Use `;`, NOT `&&`: the backstop must run even when the first prompt
exits non-zero before shipping, which is exactly the case `&&` would skip.

### Plan gate by effort/severity

`--autonomous` skips the plan checkpoint **conditionally**, not always. `/next-issue`
reads the issue's labels and chooses (see `next-issue/SKILL.md` § Autonomous
Mode):

```text
IF (effort/trivial OR effort/small) AND NOT severity/critical:
  → fully autonomous — golem runs straight through to a PR, no plan stop.
ELSE (effort/medium | effort/large | severity/critical | no effort label):
  → plan-gated — golem builds the plan and BLOCKS at ExitPlanMode awaiting a
    human. It shows BLOCKED in `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`; the operator runs
    `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`, refines + approves the plan in-session, and the
    SAME session then continues autonomously (implement → review → push/PR)
    with the refined plan in-context — so the refinements inform implementation
    AND the antagonistic pre-PR review, not just the first edit.
```

This mirrors the `--ship` effort gate, which is likewise restricted to
`effort/trivial`/`small`. The launch command does not change — the policy lives
in `/next-issue`; dispatch just **expects** medium+/critical golems to block at
the plan step. Per-golem overrides: append `--plan-gate` to force the checkpoint
on a small issue, or `--force-auto` to force full autonomy on a medium+/critical
one.

**Plan approval is a human keystroke, not agent-drivable (#29).** At the golem's
`ExitPlanMode` prompt the two "yes" options diverge under the auto-mode
classifier:

- **Option 1 — "Yes, and use auto mode"** is the one that lets the SAME session
  continue autonomously to a PR, but it *switches the golem into auto mode*, and
  that switch **itself trips the classifier** (`[Create Unsafe Agents]`) when an
  orchestrating agent relays it — so an agent cannot press option 1 for the
  golem.
- **Option 2 — "Yes, manually approve edits"** approves the plan WITHOUT the
  auto-mode switch (an agent *can* select it), but then the golem gates on
  **every subsequent edit** and does NOT run unattended to a PR.

So the documented "human approves plan → golem continues autonomously to PR"
flow works **only when a human presses option 1 in a real TTY** (attach via
`${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`); it is not something the orchestrator can
answer on the human's behalf. To skip the gate entirely on a medium issue, use
`--force-auto` (full autonomy, no plan checkpoint).

| Realization        | Built on | Payload (process)                         | Exit                            |
| ------------------ | -------- | ----------------------------------------- | ------------------------------- |
| **Worktree golem** | Mode 2   | `claude --permission-mode auto "/workflow:next-issue <N> --autonomous" ; claude --permission-mode auto "/workflow:ship-issue --autonomous"` in a worktree shell | autonomous ship → Branch + PR (plan-gated golems block at plan first — see below) |
| **Container golem** | Mode 3  | same chained pipeline in the container's tmux Claude | same → PR (or auto-merge: needs `AUTOMERGE=1` + `AUTOMERGE_AUTONOMOUS=1`) |

> **Hard constraint — golems are processes, never Workflow subagents.** The
> Workflow tool permits one nesting level, and each golem's `/ship-issue`
> already owns it (its review harness fans out the `code-reviewer` agent).
> Dispatching a golem via the Workflow/Task tool with workflow nesting consumes
> that level and makes the golem's review harness throw. Dispatch golems as OS
> processes only — containers (`/provision-agent`) or worktree-bound shells.
> (See `ship-issue` SKILL.md § Golem Execution Model.)

### Supervised launch & central feed

Golems run **interactive in tmux with `--permission-mode auto` passed
explicitly** — never `--dangerously-skip-permissions`, never forced
`acceptEdits`. `auto`'s safety classifier auto-approves routine reads/edits/bash
and prompts only on the genuinely risky class, so a prompt then means something.
(The repo's `.claude/settings.local.json` also pins `git push` / `gh pr create` /
`gh pr merge` to `ask`, so outward actions still gate even under `auto` — once
the worktree is trusted; `scripts/worktree-new.sh` seeds that trust.) The flag must be
explicit: a fresh worktree is untrusted, so its copied `defaultMode: auto` is not
loaded on its own and the session would silently fall back to `default` (#585).

Launch a worktree golem (after `${CLAUDE_PLUGIN_ROOT}/scripts/worktree-new.sh {N}`) with
**one standalone `tmux new-session` per golem**, via the bundled helper:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/golem-launch.sh launch {N}
```

which runs exactly the bare new-session below (one issue per call):

```bash
tmux new-session -d -s golem-{N} -c .worktrees/issue-{N} -e GOLEM_ID=golem-{N} \
  "claude --permission-mode auto '/workflow:next-issue {N} --autonomous' ; claude --permission-mode auto '/workflow:ship-issue --autonomous'"
```

**Permission preflight + one-per-golem (#29).** This bare `tmux new-session` is
denied by the auto-mode classifier (`[Create Unsafe Agents]`) unless the host
has authorized the launch rules `Bash(tmux new-session:*)`, `Bash(tmux ls:*)`,
and `Bash(tmux kill-session:*)`. Run `${CLAUDE_PLUGIN_ROOT}/scripts/golem-launch.sh preflight`
once before the first dispatch (it checks BOTH `.claude/settings.local.json` and
`~/.claude/settings.json`); if the rules are absent in both it prints the exact
rules + the scope choice — **suggest + ask, never write settings silently**
(adding settings is itself permission-gated; the operator authorizes it, with
always-allow writing the rule or allow-once proceeding this run). Critically,
the allow rule matches only a *bare* `tmux new-session …`: wrapping N launches
in a `for` loop turns the whole Bash invocation into a for-loop **string** that
does NOT match `Bash(tmux new-session:*)` and is re-denied. So
`golem-launch.sh launch {N}` is called **once per issue** (one Bash tool call
each) — never one looping call. (Use `golem-launch.sh print {N}` to emit only
the launch line.)

`-e GOLEM_ID=golem-{N}` stamps the golem id into the session environment. The
`Notification` hook reads `$GOLEM_ID` first — the only cwd- and tmux-independent
source — so the blocked-golem feed records the correct `golem-{N}` even when the
hook fires from a subdirectory or a review-harness subagent (the hook also falls
back to the git worktree-root basename, never bare `pwd`).

**Do NOT run golems headless** (`claude -p --output-format stream-json`). A
headless session has no TTY, so there is nothing to attach to and no way to
answer a permission prompt — it forces skip-all and throws away supervision to
gain a feed. Monitoring and intervention are separate channels:

- **Monitor (TTY-free):** an interactive golem's TUI paints an alternate screen
  buffer, so `tmux capture-pane` / `tail -f` are blank for scrolling **work
  output** — do not scrape that for progress. Derive status from observable
  state instead — git commits vs `origin/main`, PR/MR state, the `next-issue`
  state files (`phase`), and the `.worktrees/.status/*.json` cache — plus a
  `Notification` hook (`.claude/hooks/golem-notify.sh`) that appends a classified
  event line to `.worktrees/.status/feed.jsonl` whenever a golem awaits a
  decision. `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh` renders the table AND the BLOCKED list from these (see
  **Feed event vocabulary** below for how a block clears). **Exception — the
  modal prompt overlay IS scrapeable.** The "blank until exit" limit is about
  scrolling work output; a permission/plan **prompt overlay**
  (`Do you want to proceed?`, the `ExitPlanMode` plan prompt) renders *over* the
  alt-screen and `tmux capture-pane` returns it reliably. That makes pane-state a
  legitimate co-equal gate channel — see **Gate-watch contract** below.
- **Intervene (on demand):** when `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh` flags a golem BLOCKED, run
  `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}` to attach its real TTY (worktree session `golem-{N}`,
  or a container golem's `claude` session via `docker exec`), answer the
  high-risk prompt — **or, for a plan-gated golem (medium+/critical), review,
  refine, and approve the plan at its `ExitPlanMode` checkpoint** — and detach.

### Feed event vocabulary

Each line in `.worktrees/.status/feed.jsonl` is one JSON object:
`{ts, golem, event, message}`. `golem-notify.sh` classifies every
`Notification` it receives into an `event` kind so the reader can separate a
real block from noise:

| `event`      | Meaning                                                          | Surfaces in BLOCKED?                          |
| ------------ | ---------------------------------------------------------------- | --------------------------------------------- |
| `gate`       | A permission decision is pending — a human must answer (e.g. the `git push` / `gh pr create` `ask` rule: *"Claude needs your permission to ..."*). | **Yes**, while it is the golem's latest line and within the freshness window. |
| `idle`       | A transient between-turn idle (*"Claude is waiting for your input"*) — also fires while a sub-agent runs mid-work. Noise, not a block. | No. |
| `escalation` | A genuine **judgement call carrying options** — a mid-flight architectural/directional fork, or a wall with more than one viable path forward (issue #176). A human decision at L1–L3, auto-resolved (agent picks its recommendation) at L4. Distinct from a routine permission `gate`: emitted with a message beginning `ESCALATION:`, and labelled *"escalation — …"* in the BLOCKED list so it is not lost among permission gates. See `next-issue/escalation-protocol.md`. | **Yes**, while latest + fresh; labelled distinctly. |
| `blocked`    | **Legacy** kind written before issue #600 (every notification was `blocked`). Honored as a `gate` for backward compatibility. | Yes (treated as `gate`). |

Classification is case-insensitive on the message and **defaults to `gate`** for
an unrecognized message, so a new notification kind surfaces (fail loud) rather
than being silently dropped. The `escalation` marker is matched before the `gate`
default, so an escalation is never misfiled as a plain permission gate.

**How a block clears (no resolution event).** The feed is append-only and
chronological, so `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh` takes only each golem's **most-recent** line as
its current state. When a golem resumes after a gate, its next between-turn
`idle` becomes the latest line and supersedes the earlier `gate` — the golem
drops off the BLOCKED list with no explicit "unblocked" event. A `gate` left
behind by a golem that has since exited is additionally dropped once it ages out
of the freshness window (`GOLEM_BLOCK_TTL` seconds, default `3600`).

### Gate-watch contract

`${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh` is a **pull** surface (the operator runs it). The proactive
**push** complement is `${CLAUDE_PLUGIN_ROOT}/scripts/golem-gate-watch.sh`, which the live session arms via
the `Monitor` tool at dispatch and a human can run as `${CLAUDE_PLUGIN_ROOT}/scripts/golem-watch.sh` (see
`SKILL.md` Phase M § *Proactive gate-watch*). It is the single source of truth
for "which golem is at a gate" — the `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh` BLOCKED list calls its `--once`
mode, so the pull and push surfaces can never disagree. Two **co-equal** channels
(neither is "secondary"):

- **Feed** (`--once` / `--stream`) — the classified `feed.jsonl`. TTY-free, so it
  covers **all** golems including headless/container ones, and carries golem-id
  attribution (#587). Reuses the **Feed event vocabulary** above verbatim.
- **Pane prompt-overlay** (`--once-panes` / `--stream-panes`) —
  `tmux capture-pane` on live `golem-*` sessions matched against the modal prompt
  overlay. Covers live worktree golems only, and is the better catcher of
  **plan-gate `ExitPlanMode`** prompts (which the feed records only as a generic
  `gate`); it labels those distinctly so the operator knows it is a plan to
  review. The plan-gate signatures it matches are `Here is Claude's plan`,
  `Would you like to proceed`, `Ready to code`, and the `Yes, and use auto mode`
  option line — any one is enough, since a given overlay may show only one of
  them. Relies on the alt-screen overlay exception documented in the
  *Monitor (TTY-free)* bullet above.

**Notifies:** a real permission `gate` (feed: latest line per golem is a fresh
`gate`/legacy `blocked` within `GOLEM_BLOCK_TTL`; pane: a prompt overlay is
present), a mid-flight `escalation` (feed: latest line is a fresh `escalation`,
labelled *"escalation — …"* — issue #176), and a plan-gate `ExitPlanMode` (a
`gate` in the feed, distinctly labeled on the pane channel).

**Suppressed:** a transient `idle` (feed noise); a `gate` superseded by a later
`idle`/`gate` line; a `gate` aged past `GOLEM_BLOCK_TTL`; and — crucially for a
stream — a **standing** gate already reported (see re-notify).

**Re-notify (cleared/resumed).** The streaming modes emit only on the
**transition into** a fresh gate, tracking the last-emitted state per golem: a
standing gate is reported once, not every poll tick. When a golem clears (feed:
an `idle` supersedes; pane: the overlay disappears) it is forgotten, so when a
**new** gate later appears for that golem it is a fresh transition and
**re-fires**. No explicit resolution event is needed on either channel — the same
append-only/latest-line rule from *How a block clears* drives both. `--stream`
also **primes** past any pre-existing gates on startup so they are not replayed
as new.

**Survives the zero-golem handoff window (#621).** The streaming modes carry no
"no golems remain → stop" exit: an empty poll — no live `golem-*` sessions and
no fresh feed line — emits nothing and the loop polls again. This matters
because dispatch routinely produces a one-poll **handoff window** where zero
golems exist (an old golem's session is killed as its PR merges and the next is
created a beat later); a watch that stopped on the first empty reading would
silently miss every gate after that point. The watch therefore stops only when
the operator/harness kills it — there is deliberately **no** "sustained absence"
countdown, because an unconditionally surviving loop is simpler and strictly
safer than any empty-poll timer.

### Dispatch Decision Sub-Tree

```text
IF batch_size >= 2 OR session at capacity (>= 3 worktrees):
  → Container golems (Mode 3) via /provision-agent — primary for parallel work
ELIF batch_size in 1..2 AND session has capacity:
  → Worktree golems (Mode 2)
ELSE (single issue):
  → Run /next-issue directly, no orchestration
```

The master orchestrator (a live interactive session) dispatches golems, then
monitors PR + issue-label state and rebases across PRs. It NEVER merges a
golem's branch into its own — humans merge PRs (or per-golem auto-merge, which
for an autonomous golem requires both `AUTOMERGE=1` and `AUTOMERGE_AUTONOMOUS=1`).
See `SKILL.md` Phases D / M / R.

### Worker Pool (fixed-size, self-refilling)

Phase D dispatches a fixed **set** of golems once and the batch runs to
completion. The **worker pool** (SKILL.md Phase P) keeps that footprint **fixed
at N** instead: maintain up to N concurrent golems, and as each one's PR merges
and its worktree is pruned, refill the freed slot from the backlog — a bounded
worktree footprint (bounded disk / container load) with continuous throughput.
The pool feeds work in; the integration train (Phase T) lands it.

The pool changes **when and which** golems launch, not **how** — every golem is
still a Mode 2 / Mode 3 process with the same autonomous payload and PR exit; the
hard constraints above are unchanged.

**Refill policy** lives in `.worktrees/.status/pool.json` (`size` +
`accepting`), authoritative for operator policy:

| `accepting`  | Refill behavior                                                        | Set by    |
| ------------ | --------------------------------------------------------------------- | --------- |
| `accepting`  | A free slot pulls the next non-colliding backlog issue into a fresh worktree. | `resume`  |
| `draining`   | Stop refills; in-flight golems finish to idle. One-way wind-down (context reset / restart / EOD). | `drain`   |
| `paused`     | Freeze refills without draining — slots held open, resumable.          | `pause`   |

`pool <N>` resizes live: grow fills free slots on the next sweep; shrink leaves
the excess golems to **drain** (never killed).

**Collision-aware refill.** Before claiming a backlog issue for a free slot, the
pool predicts its file overlap with in-flight golems (the issue's
`## Affected Files` section + area/component labels vs each live golem's changed
files) and prefers a **non-colliding** issue, holding the slot if only colliding
candidates remain — keeping the merge train (#602) conflict-light. The scheduler
is the **pure-computation `pool` mode of `workflow.js`** (mirroring `train`
mode): it returns the collision-free `picks` / `held` / `excess`; the live
orchestrator executes the `scripts/worktree-new.sh` + Phase D dispatch under the
existing `ask` gates. The harness never launches a golem.

The pool advances on each Phase M monitor sweep — there is **no background
daemon**; the existing monitor cadence is the clock.

---

## CI-failure triage contract

When a golem's PR CI fails, classify the failure **before** surfacing it as a
regression or escalating to the human. This is a triage/classification step plus
cascade-collapse — **not** a new retry layer (the `ci-fixer` harness already
caps code-fix attempts; the CI-wait loop already never blocks shipping). It runs
inside each golem's `/ship-issue` CI-wait (Step 4 Option 1, "If checks fail
— triage"); the orchestrator's Phase M monitor mirrors the result when it
surfaces a failing PR.

**Inputs:** the failing **step** name (`gh run view <run_id> --json jobs`) and
the PR's changed-file set (`git diff --name-only origin/main...HEAD`).

**Classes:**

| Class | Signal | Action |
| ----- | ------ | ------ |
| **infra/flake** | failing step matches `LIBRARIAN_CI_INFRA_STEPS` (e.g. `Set up Docker Buildx`, checkout, login, cache), OR the failing job type cannot be affected by the diff (e.g. a Docker `Build` job on a docs/tests-only PR) | **auto-retry once** (`gh run rerun --failed`), re-poll, re-evaluate; escalate only on re-fail |
| **real** | failing step exercises the change (test / lint / build touching the diff) | escalate immediately — hand to `ci-fixer` (today's behavior) |
| **cascade** | an aggregation/summary job (e.g. `PR Tier > Summarize`) that failed only because an upstream job failed | attribute to the upstream root cause; report **once**, not as a second independent failure |

**Bounds (all env-overridable; mirror `REVIEW_MAX_CYCLES`'s `${VAR:-default}`
posture):**

- `LIBRARIAN_CI_INFRA_STEPS` — `|`-separated regex of known infra step names.
- `LIBRARIAN_CI_INFRA_RETRIES` — infra-flake auto-retry count, default `1`.
  **Independent of** the `ci-fixer` 3-attempt cap (that caps code fixes; this
  re-runs an unchanged infra step). `0` disables infra auto-retry.

**Degrade gracefully — never hard-fail.** If step names or the changed-file set
can't be fetched (API error, unknown step), do not auto-retry blindly: fall
through to the normal `ci-fixer` handoff and, when autonomous, record an
escalate-with-note ("CI triage unavailable — classified as real") in the
completion summary. The triage never blocks shipping.

---

## Decision Tree

Inputs for mode selection:

| Signal              | How to Detect                                              |
| ------------------- | ---------------------------------------------------------- |
| Effort label        | Issue labels: `effort/trivial`, `small`, `medium`, `large` |
| Session load        | `git worktree list \| wc -l`, running containers count     |
| Container available | `docker images -q project:agent-runner` (non-empty = yes)  |
| Build cost estimate | Count INCLUDE\_\* flags in devcontainer config             |
| File overlap risk   | Compare issue's likely files with current working set      |
| Batch size          | Number of issues to process                                |

### Selection Logic

```text
IF effort/trivial AND no file overlap:
  → Mode 1a (current branch)
  "Trivial fix, working directly on current branch."

ELIF effort/small OR clean diff needed:
  → Mode 1b (new branch)
  "Small scope, creating a feature branch for clean diff."

ELIF batch_size == 1 AND session has capacity (< 3 worktrees):
  → Mode 2 (ephemeral worktree)
  "One parallel task, session has capacity. Using ephemeral worktree."

ELIF batch_size >= 2 OR session at capacity (>= 3 worktrees):
  → Mode 3 (container agent)
  IF NOT container_available:
    "Mode 3 recommended: {batch_size} issues. First build ~{estimate}min
     ({features} stack). Subsequent agents instant. Proceed?"
  ELSE:
    "Mode 3 recommended: {batch_size} issues, image ready.
     Estimated {serial_time} serial vs {parallel_time} parallel. Proceed?"

ELSE:
  → Mode 1b (new branch, safe default)
```

### Batch Processing Guidance

For batches of 5+ well-defined issues (e.g., audit cleanup):

1. Use Mode 3 with 3-5 container agents
1. Assign issues round-robin by estimated effort
1. Orchestrator reviews at merge points (human in the loop)
1. Expect: 20-30 issues/afternoon with 5 agents

**Warning**: Batch processing is exhausting for the human (heavy context
switching at merge points) and expensive (5x API cost). Best suited for
well-defined bugs and audit issues, not architectural work.

---

## Tradeoff Explanation Templates

When recommending a mode, explain the tradeoff clearly:

**Mode 1a**:

> Working directly on current branch. No overhead, but no isolation either.

**Mode 1b**:

> Creating branch `{branch}`. Clean diff for review. Merge when done.

**Mode 2**:

> Creating ephemeral worktree at `.worktrees/issue-{N}/`. Runs in this
> session — limited to {available} more concurrent tasks.

**Mode 3 (first build)**:

> Spinning up container agent. First build estimated ~{minutes}min
> ({feature_count} features: {feature_list}). Subsequent agents reuse the
> image. Agent runs Claude Code in tmux — attach with:
> `docker exec -it {container} tmux attach -t claude`

**Mode 3 (image ready)**:

> Spinning up container agent (image ready, ~30s startup). Agent runs
> Claude Code in tmux — attach with:
> `docker exec -it {container} tmux attach -t claude`
