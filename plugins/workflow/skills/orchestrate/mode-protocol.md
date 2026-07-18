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
--level 4`, which invokes `/ship-issue` in-turn → Branch + PR) unattended to
a green, review-clean PR. Golems are not a new isolation mechanism — they are
the **existing Mode 2 or Mode 3** with an autonomous payload and a PR exit.

The launch is **interactive** in tmux with `--permission-mode auto` passed
**explicitly** (never headless `claude -p`, never
`--dangerously-skip-permissions`; see the `golem-supervised-auto-mode` memory and
issues #570, #585). The explicit flag is required because a fresh worktree is untrusted,
so Claude Code does not load its copied `settings.local.json` `defaultMode: auto`
and would otherwise fall back to `default`. The harness `--permission-mode auto`
is distinct from the `/next-issue` `--level {N}` skill flag (the autonomy dial) —
both are needed.
An L4 `/next-issue` invokes `/ship-issue` in-turn, so the single prompt
reaches a PR on its own. A `;`-chained second prompt is the resume backstop:

```bash
claude --permission-mode auto "/workflow:next-issue <N> --level 4" ; claude --permission-mode auto "/workflow:ship-issue"
```

— so that a premature turn-exit after `/next-issue` still ships: the second
prompt re-reads the state file and delivers (a near no-op if the first already
pushed a PR). Use `;`, NOT `&&`: the backstop must run even when the first prompt
exits non-zero before shipping, which is exactly the case `&&` would skip.

### Plan gate by level

Whether a golem skips the plan checkpoint is decided by its **autonomy level**,
**not** its effort labels (the level model, #174/#175, replaced the old
effort-based rule — an L4 golem on an `effort/medium` issue now skips the plan,
which under the binary model it would not have). `/next-issue` resolves this via
`${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh` (#190), which derives the
`plan_gated` disposition from the level; dispatch does not recompute it:

```text
plan_gated == false (level 4, critical cap did not fire):
  → fully autonomous — golem runs straight through to a PR, no plan stop.
plan_gated == true (level 1-3, incl. a capped severity/critical):
  → plan-gated — golem builds the plan and BLOCKS at ExitPlanMode awaiting a
    human. It shows BLOCKED in `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`; the operator runs
    `${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`, refines + approves the plan in-session, and the
    SAME session then continues autonomously (implement → review → push/PR)
    with the refined plan in-context — so the refinements inform implementation
    AND the antagonistic pre-PR review, not just the first edit.
```

The launch command does not change — the policy lives in `/next-issue`; dispatch
just **expects** a golem dispatched below L4 (or a capped critical) to block at
the plan step. To change a golem's behavior, dispatch it at a different
`--level {N}`: L4 runs fully autonomous with no plan stop, L3 keeps the plan gate
while auto-passing routine gates. A `severity/critical` issue cannot exceed L3 —
the critical cap always keeps its plan gate human, whatever level is requested.

**Plan approval is broker-then-send: human decides, orchestrator sends the
keystroke (#29).** At the golem's `ExitPlanMode` prompt the two "yes" options
diverge under the auto-mode classifier:

- **Option 1 — "Yes, and use auto mode"** is the one that lets the SAME session
  continue autonomously to a PR, but it *switches the golem into auto mode*, and
  that switch trips the classifier (`[Create Unsafe Agents]`) when an agent
  relays it as an **undirected** send (nothing authorizing it).
- **Option 2 — "Yes, manually approve edits"** approves the plan WITHOUT the
  auto-mode switch (an agent *can* select it), but then the golem gates on
  **every subsequent edit** and does NOT run unattended to a PR.

So the flow is **broker → human decides → the orchestrator sends option 1
itself**: the orchestrator presents the plan in-session (e.g. `AskUserQuestion`),
and once the operator approves it runs `tmux send-keys -t golem-{N} 1 Enter`. The
operator's explicit approval is what clears the classifier for that directed
send — it is denied only as an *undirected* relay, not after the operator has
authorized the gate. The human's role is the **decision**, not the physical
keypress; do not hand the keystroke back to the operator to paste.

Worked example: `AskUserQuestion "approve plan for #{N}?"` → operator approves →
orchestrator runs `tmux send-keys -t golem-{N} 1 Enter` → verify the golem left
plan mode (`⏵⏵ auto mode on`, branch name in the status bar).

**Fallback:** if the directed send is still classifier-blocked, attach the real
TTY (`${CLAUDE_PLUGIN_ROOT}/scripts/golem-attach.sh {N}`) and press option 1
there. To skip the gate entirely on a medium issue, dispatch it at `--level 4`
(full autonomy, no plan checkpoint). The `#29` "not agent-drivable" claim is
**settled** (#281): it was only ever about an agent relaying option 1 *through
the auto-mode classifier* (the undirected send), never the directed
`tmux send-keys` — which a live batch verified drives option-1 approval reliably
(4/4). What remains open is the narrower **classifier non-determinism** on these
sends, tracked in #282 — the reason the attach-and-press fallback above still
earns its place.

| Realization        | Built on | Payload (process)                         | Exit                            |
| ------------------ | -------- | ----------------------------------------- | ------------------------------- |
| **Worktree golem** | Mode 2   | `claude --permission-mode auto "/workflow:next-issue <N> --level 4" ; claude --permission-mode auto "/workflow:ship-issue"` in a worktree shell | autonomous ship → Branch + PR (plan-gated golems block at plan first — see below) |
| **Container golem** | Mode 3  | same chained pipeline in the container's tmux Claude | same → PR (merge is the level-aware routine gate: auto at L3–L4 after green CI + clean review) |

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
${CLAUDE_PLUGIN_ROOT}/scripts/golem-launch.sh launch {N} --level {L}
```

where `{L}` is the run's chosen autonomy level (L1–L4). Omit `--level` and the
launcher defaults to `4` (`GOLEM_LEVEL` is the env fallback). It runs exactly
the bare new-session below (one issue per call), with `{L}` substituted for the
level:

```bash
tmux new-session -d -s golem-{N} -c .worktrees/issue-{N} -e GOLEM_ID=golem-{N} \
  "claude --permission-mode auto '/workflow:next-issue {N} --level {L}' ; claude --permission-mode auto '/workflow:ship-issue'"
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
`golem-launch.sh launch {N} --level {L}` is called **once per issue** (one Bash
tool call each) — never one looping call. (Use `golem-launch.sh print {N}
--level {L}` to emit only the launch line.)

**Allow-list ≠ classifier; retry a launch denial (#282).** The three `Bash(tmux
…)` allow rules and the auto-mode **safety classifier** (`[Create Unsafe
Agents]`) are **separate gates**. Authorizing the allow rules (and
`golem-launch.sh preflight` confirming them) removes the *allow-list* denial but
does **not** preempt the classifier, which re-evaluates each `tmux new-session`
launch on its own judgment and is **non-deterministic** on this shape — the same
byte-identical launch can be denied then approved on immediate retry. The correct
response to a `[Create Unsafe Agents]` denial on a **launch** is therefore to
**retry the identical `golem-launch.sh launch {N}` command** — it typically
passes next try — **not** to fall back to a manual `!` paste. This is the same
classifier non-determinism as the plan-gate `send-keys` case above; the two are
different code paths (launch vs. option-1 send) sharing one root cause. A
dedicated launcher entrypoint the classifier could be taught to trust remains
open under #282.

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
| `dead-end`   | An **escalation whose only auto-resolution would violate the merge invariant** (CI still red after `ci-fixer` exhausts, a contradictory conflict `rebase-agent` can't union, an unclean review that can't be mechanically fixed — issue #180). Unlike a plain `escalation` it blocks at **every level, L4 included**, and carries a structured why/attempted/remaining summary. Emitted with a message beginning `DEAD-END:`, labelled *"dead-end — …"* in the BLOCKED list. See `orchestrate/autonomy-levels.md` § *The dead-end summary template*. | **Yes**, while latest + fresh; labelled distinctly. |
| `blocked`    | **Legacy** kind written before issue #600 (every notification was `blocked`). Honored as a `gate` for backward compatibility. | Yes (treated as `gate`). |

Classification is case-insensitive on the message and **defaults to `gate`** for
an unrecognized message, so a new notification kind surfaces (fail loud) rather
than being silently dropped. The `dead-end` and `escalation` markers are matched
before the `gate` default (and `dead-end` before `escalation`, as the more
specific kind), so neither is ever misfiled as a plain permission gate.

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
`monitor-protocol.md` § *Proactive gate-watch*). It is the single source of truth
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
  them. It also catches an **`AskUserQuestion` escalation fork** (issue #257) by
  its `Enter to select` selection-modal footer — a gate category the pane channel
  previously dropped entirely — labelling it *"escalation — …"* like the feed's
  escalation lines. The fork is the **last-resort** match — plan-gate and generic
  permission-gate are checked first, so a plan overlay or a routine permission
  menu that also paints an `Enter to select` footer is classified as itself, not
  downgraded to an escalation — and the footer match is anchored to the pane's
  bottom lines (like the liveness classifier's #246 fix) so scrolled text
  mentioning the phrase does not self-trip it. Relies on the alt-screen overlay
  exception documented in the *Monitor (TTY-free)* bullet above.

**Notifies:** a real permission `gate` (feed: latest line per golem is a fresh
`gate`/legacy `blocked` within `GOLEM_BLOCK_TTL`; pane: a prompt overlay is
present), a mid-flight `escalation` (feed: latest line is a fresh `escalation`,
labelled *"escalation — …"* — issue #176; also caught on the pane channel via
the `Enter to select` fork footer and labelled the same — issue #257), a
`dead-end` (feed: latest line is a fresh `dead-end`, labelled *"dead-end — …"* —
issue #180; the one block that holds even at L4), and a plan-gate `ExitPlanMode`
(a `gate` in the feed, distinctly labeled on the pane channel).

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

### Status-sweep cadence

The gate-watch above is a **push** surface, event-driven — it fires on the
*transition into* a fresh gate. Its **pull** complement is the periodic **status
sweep**: `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh --watch`, a rolling
at-a-glance re-render of every golem's row on a fixed interval. It is **on by
default at every level (L1–L4)** — the orchestrator arms it on entering
`monitor`/`watch` without asking (the old "would you like a sweep?" opt-in prompt
is removed, #304); the operator may silence or re-cadence it.

The interval **scales by autonomy level** (higher level → less frequent sweep,
since golems run longer without oversight). The mapping is owned by
`${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh sweep-interval --level N`
(single source of truth for per-level dispositions, #190) — **L1 180s / L2 300s /
L3 480s / L4 900s**. Precedence when `golem-status.sh --watch` resolves its
cadence: an explicit `--interval S` → the `GOLEM_SWEEP_INTERVAL` env override →
the resolver's level-scaled default. In a **mixed-level batch** (tracks at
different levels), key off the **lowest level present** — tightest oversight wins
— by passing `--level <min active level>`. The sweep loop carries no empty-poll
exit (mirrors `golem-gate-watch.sh --stream*`): a transient zero-golem handoff
window renders "No active golems" and keeps sweeping, stopping only when the
operator/harness kills it.

### Slow-review takeover contract

A golem's `/ship-issue` pre-PR `next-issue-review` sometimes runs long. The
question the monitor must answer is **not** "is this review slow?" but "is this
golem **unrecoverably wedged**, warranting an orchestrator takeover kill?" — and
the answer is **almost always no**. The default is **surface-and-wait**, not
decide-and-kill (see `monitor-protocol.md` § *Slow pre-PR reviews*).

**Why the old signal was wrong.** The retired heuristic flagged a wedge on a
frozen `N/6 agents` sub-workflow counter + ~15 min wall-time. That conflates a
genuine wedge with **three benign states**, each of which resolves on its own:

- **Classifier-outage self-retry** — the external review-classifier API is down;
  the golem is correctly retrying, sub-workflow tokens grow slowly (batch-7
  golem-243 → later shipped PR #349).
- **A genuinely slow multi-dimension review** that is about to complete — a 6th
  review agent can legitimately run 30+ min (golem-254, held at 5/6 for ~30 min,
  then opened its PR unaided; golem-328 had already PR'd in the exact
  decision→kill window).
- **Top-level post-review work** — the golem is doing real finalization
  (portability probes, commit hooks) at the top level while the sub-workflow
  review line sits stale; **top-level** token growth means it is never wedged.

Across batch-7 (2026-07-16, golems #243/#254/#328/#265) this produced a ~75%+
false-positive rate on borderline calls and **zero** confirmed-unrecoverable
wedges — even the one case flagged genuine (#265) was killed before it could be
observed to self-resolve, and golem-254 proves a frozen 6th agent can still
finish given time. A false-positive takeover is **costly** (interrupts legit
work, the amend-classifier friction, the reap-cwd hazard); a truly wedged review
is **cheap** (bounded by the golem's own budget, corrupts no state). So the cost
asymmetry favors waiting.

**When a takeover may even be *offered*.** Never automatically; only as an
operator **offer**. A **crashed/exited golem process is definitive on its own** —
there is no ambiguity to rule out for a dead process, so offer the takeover after
the mandatory pre-kill PR check alone (no wall-time floor, no corroboration
needed). **Otherwise** — the process is still alive and the review is merely
slow/frozen — offer a takeover only after **every** applicable one of these
holds (any one missing ⇒ keep waiting and keep surfacing):

- **Frozen top-level token counter for 45–60 min.** No growth in the
  **top-level** counter for at least a **45–60 min** window of elapsed wall time,
  sampled on each status sweep (so **≥2** frozen readings, however many sweeps the
  level's cadence fits into that window — see § Status-sweep cadence; the window,
  not a fixed sweep count, is the bar). This window is the load-bearing wait — it
  necessarily starts well past the ~25–30 min at which a slow review first becomes
  worth *surfacing*, so there is no separate short-time floor to check. A frozen
  *sub-workflow* counter with top-level growth is real work, not a wedge — the
  distinction is the whole point. (The crashed-process case above short-circuits
  this — a dead process needs no token-freeze window.)
- **Cross-golem corroboration — only when sibling golems are active.** In a
  multi-golem batch, a sibling golem's review advancing in the same window proves
  the classifier is up, ruling out a shared external outage; require it before
  declaring a per-golem stall. This is **necessary but not sufficient** — a
  per-golem stall is not the same as an *unrecoverable* one. In a **solo-golem
  run** (batch of one — no sibling exists) this condition is **inapplicable** and
  does not block the offer; lean harder on the top-level-freeze window instead.
- **Mandatory pre-kill PR check (always).** Run `gh pr list --state open --head
  feature/issue-{N}` immediately before any kill — including the crashed-process
  case. A slow review can push + open its PR in the decision→kill window
  (golem-328); if a PR exists, **skip the takeover entirely and just merge it**.

**Takeover recipe (only once the above all hold and the operator accepts).**
`tmux kill-session -t golem-{N}`; commit any uncommitted golem refinements as a
**fresh** commit (not `git commit --amend` — the auto-mode classifier denies
amending a golem-authored commit as `[Git Destructive]`); `git rebase
origin/main` (disjoint work → clean); `bash tests/run-all.sh`; then
`git push --force-with-lease` + `gh pr create`. This mirrors #327's golem-side
mechanical wall-time bound (`workflow-wall-timeout.sh`) — that is the golem's own
internal budget; this contract is the **orchestrator-side judgment** used when
monitoring from outside.

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
golem's branch into its own — a golem's own `/ship-issue` merges its PR as the
**level-aware routine gate** (auto at L3–L4, human at L1–L2, always subject to the
green-CI + clean-review merge invariant); humans merge whatever a golem leaves for
them. See `SKILL.md` Phases D / M / R.

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

## Bounding a Workflow invocation in wall-time (#224)

Every orchestrate phase that drives `workflow.js` and **fans out subagents** can
hang the same way ship-issue's review fan-out can: the sandbox bans clocks and
timers so the harness cannot self-deadline, and a *spinning* subagent emits no
tokens, so the shared token budget bounds *cost* but never *latency*. A single
stuck `agent()` runs the whole sweep unbounded even far below the token cap. The
bound is the **caller's** job (`dev-core:workflow-authoring` § *No Clock in the
Sandbox*) — apply it here exactly as ship-issue's `pre-ship-validation.md`
Step 3.5 b bounds its pre-PR review:

- Invoke the `Workflow` tool as a **background** task and poll `TaskOutput` with
  a finite per-poll timeout, accumulating elapsed wall-time. The tool result
  carries the run's `transcriptDir`.
- Once cumulative wait crosses `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` minutes
  (default 20), do NOT keep waiting blindly. **L1–L2**: prompt — **cut short**
  (treat this sweep as partial) or **extend** (another interval). **L3–L4**:
  auto-extend up to `LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS` times (default 1 →
  40 min ceiling), then `TaskStop` the run. Never hang.
- A `TaskStop`-ped sweep is **partial**: never treat a timed-out `poll`,
  `poll+rebase`, or `train` invocation as complete. Recovery here is **not**
  `recover-journal-partials.sh` — unlike ship-issue's review fan-out, these
  modes emit no finding-shaped journal partials (they produce `pr_status[]` and
  train-graph state, not `severity`/`file`/`line_start`/`category`/`title`
  findings, so the recover script would only ever return `[]`). Recover via
  **checkpoint-resume / re-run** instead: a `poll` / `poll+rebase` resumes from
  its per-PR checkpoint, and `train` is re-run to recompute the order. Carry a
  `timed_out` note into the status surface.

**Applies only to the subagent-fanning modes** — `poll` and `poll+rebase`
(Phase M / Phase R, the PR-status reads and `rebase-agent` dispatch) and `train`
(Phase T, the per-PR file-list fetch). The `pool` and `tracks` modes are **pure
computation** (they never call `agent()`), so they cannot hang on a spinning
agent and need no wall bound.

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
