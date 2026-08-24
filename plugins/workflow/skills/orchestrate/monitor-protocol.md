# Orchestrate — Monitor Protocol

Companion to `orchestrate/SKILL.md`. Load before **Phase M** (monitor). It
carries the full monitor protocol: the authoritative PR + issue-label status
sweep and live table, the CI-failure triage mirroring, the level-scaled sweep
cadence, supervised pre-PR live golems, the plan-gated early-block, the
never-kill slow-review posture, and the proactive push gate-watch (feed + pane
channels).

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

   Map each PR to its issue via the `Closes #N` line that `/workflow:ship-issue`
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

   **Bound this invocation in wall-time (#224)** — it fans out subagents; invoke
   it as a background task and apply the caller-side timeout. A timed-out poll is
   **partial**, resumed on the next sweep. See `mode-protocol.md` § *Bounding a
   Workflow invocation in wall-time*.

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
   regression.** Each golem's own `/workflow:ship-issue` CI-wait already runs this
   triage (classify by failing-step name vs the PR's changed files; auto-retry a
   known infra/setup flake once via `gh run rerun --failed`; collapse a cascade
   aggregation failure to its upstream root cause — see `ship-issue`
   SKILL.md § "If checks fail — triage" and `mode-protocol.md` § *CI-failure
   triage contract*). When surfacing a failing PR in the monitor table, mirror
   that classification: report a cascade failure once under its root cause, and
   distinguish "infra flake — retried" from "real failure — escalated" so the
   operator is not flagged to investigate a buildx flake as if it were a code
   regression. The triage adds no new hard bound — its retry is env-overridable
   (`LIBRARIAN_CI_INFRA_RETRIES`, default `1`; **agent-interpreted**, read from
   the environment by the triaging agent rather than by any script — see
   `ship-issue/ship-protocol.md` § Environment Variables) and degrades to
   escalate-with-note, never blocking shipping.

1. **Loop** (for `monitor`/`watch`): the default surface is **event-driven** —
   arm the two **push** gate-watch channels below and act on the transitions they
   emit. Do **NOT** auto-arm the persistent rolling `--checkpoint --watch` sweep
   (this **supersedes** the #304 "arm the sweep automatically, do NOT ask"
   default). The push gate-watch already fires on every actionable transition
   (gate / escalation / dead-end / PR-ready) and costs ~nothing between events, so
   a rolling pull sweep on a fixed cadence is redundant burn: it re-drives the
   full token-scrape + PR/label render every interval and drops a checkpoint into
   the live agent's context whether or not anything changed. On entering
   `monitor`/`watch`, arm the gate-watch channels (see **Proactive gate-watch**
   below) and accept mid-flight commands (see Surface below).

   **Act on transitions — do not reactively re-poll.** Each emitted gate-watch
   line is a *decision* to make (approve a plan, triage CI, resolve an
   escalation), not a trigger to re-run `gh pr list` + `capture-pane` across every
   golem. The live agent should spend tokens on decisions, not on re-rendering an
   at-a-glance table on a timer. A rolling checkpoint (when explicitly armed
   below) is a **glance**, never a prompt to sweep everything again.

   **The rolling status table is opt-in, not auto-armed.** Two ways to get it
   without paying for it every interval in live context:

   - **One-shot, on demand** — `/workflow:orchestrate status` runs a single
     `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh --checkpoint` (no `--watch`)
     and renders once. Use it when you actually want the burn/velocity read.
   - **Periodic, out-of-band via `CronCreate`** — schedule that same one-shot at a
     modest off-minute interval and **redirect its output to a file** (a
     `> status.txt` on the shared filesystem), so the render runs *outside* the
     live agent's context and its cost is not paid in live tokens. This is the
     home for a standing rolling table on a long batch. (A richer host
     command-center sink is possible but out of scope — its shape is the
     still-open consumption question in ADR-0001.)

   **Exception — a Worker Pool / train still needs a periodic cadence as its
   refill clock.** The event-driven default is right for a *fixed* batch (dispatch
   N golems, watch them to done), where gate-watch catches everything actionable.
   But Phase P's **pool refill** advances *on each Phase M sweep* — "the existing
   cadence is the clock" (`pool-train-protocol.md` § Refill loop): the sweep is
   what periodically detects a merged PR, frees the slot, and refills from the
   backlog. Gate-watch fires only on gate *transitions*, never on "PR merged / CI
   green / slot freed," so with **no** periodic cadence a pool would never refill.
   Therefore, when `pool.queue == "accepting"` (a live worker pool), **do** arm a
   periodic cadence — the opt-in sweep below, or an equivalent `CronCreate`
   `/workflow:orchestrate status` render — as the refill clock. A plain fixed-batch
   dispatch does not need it.

   If you *do* want the sweep armed inside the session (a running Worker Pool, or
   a short, closely watched batch), arm it explicitly — it is no longer automatic.
   Run it TTY-free via the bundled script so it works host / bare-linux /
   container identically (no `just`):

   ```text
   Monitor({                                       # OPT-IN rolling status sweep
     command: "${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh --checkpoint --watch --level N",
     description: "periodic golem status+burn checkpoint (level-scaled)",
     persistent: true,
   })
   ```

   The **`--checkpoint`** flag (#283) selects the compact **status-checkpoint
   table** — one row per golem **grouped by track** (joined from `tracks.json`),
   with the columns `TRACK · GOLEM · ISSUE · STAGE · ELAPSED · TOKENS(Δ) · PR ·
   CI · REVIEW · STATE` and a **batch-totals footer** (`Σtokens`, per-sweep
   burn `Δ`, aggregate `rate/hr`, and `live/blocked/shipped` counts). It gives the
   operator a rolling burn/velocity read without polling. Drop `--checkpoint` to
   fall back to the verbose multi-section render (pool header, flat golem table,
   BLOCKED list, liveness, per-golem TOP-LEVEL TOKENS, per-golem CONTEXT BUDGET,
   and a one-line **recent
   feed count** — not a raw JSON tail, #488). The two are
   **mutually exclusive per sweep** — both re-drive the same token scrape, so
   running both in one sweep would reset the burn-Δ baseline. (This
   "status-checkpoint table" is distinct from the plan checkpoint at
   `ExitPlanMode` and the poll harness's per-PR resumability checkpoint.)

   **No-op sweeps are suppressed (#488).** In `--watch` mode the checkpoint
   render collapses a sweep whose **actionable state is unchanged** (per-golem
   `STATE` cell — incl. `⚠ BLOCKED`/`⚠ CI`/`⚠ gone` — plus the pool header) to a
   single `— no change since HH:MM (N golem(s))` heartbeat instead of re-printing
   the whole table, so a batch of quietly-working golems does not flood live
   context with byte-identical repaints. Volatile fields (`ELAPSED`, `TOKENS(Δ)`,
   the `rate/hr` footer) are deliberately **excluded** from the change check —
   they move every sweep and would defeat suppression — but the token
   scrape/persist still runs each sweep, so the burn baseline never drifts. A
   real `STATE` transition re-emits the full table promptly; a one-shot
   `--checkpoint` (no `--watch`) always renders in full.

   **Cadence scales by autonomy level** — *when the sweep is armed* (opt-in, or
   the `CronCreate` render's schedule), higher levels assume golems run longer
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

   The checkpoint's **`TOKENS(Δ)`** column and footer `rate/hr` are honest only
   across sweeps: `Δ = tokens since the previous sweep`, and the aggregate rate is
   `Σ Δ ÷ this sweep's interval` — so the **first** sweep after arming (and any
   one-shot `--checkpoint` with no `--watch`) prints `rate=—` rather than a
   fabricated number. Per-sweep **Δ / rate** stay a **worktree-golem (Mode 2)**
   signal (they need golem-status's own prior sample); a container golem (Mode 3)
   POSTs its cumulative top-level count into the cache (#390), so its `TOKENS(Δ)`
   shows the count with a `(frozen)` tag — folded into `Σtokens` but not the Δ —
   or `n/a` until that POST lands.

   **A cycling golem is not a stalled golem (#784).** The `CONTEXT BUDGET` block
   reports each golem's current context size against the derived handoff
   threshold. When one reads `HANDOFF DUE`, expect its session to end and a fresh
   one to start — and expect the two signals that normally mean trouble to fire
   benignly as it does: the top-level token counter **drops** (a fresh session is
   a new transcript, which golem-status classifies `reset`), and the liveness
   proxy goes quiet across the gap. Neither is a stall, and neither warrants a
   takeover: check the `CONTEXT BUDGET` row before acting on a freeze or a
   liveness gap, because a golem that just handed off looks exactly like one that
   wedged. The work is preserved in the issue's `next-issue-{N}.json` checkpoint;
   the resumed session picks up from `next_action`. A golem still frozen with an
   `ok` budget and no fresh session is the real thing. See
   `next-issue/handoff-protocol.md`.

   **Attention markers ride the `STATE` column**
   as plain text (`⚠ BLOCKED`
   at a gate, `⚠ CI` on a failing check, `⚠ gone` when the tmux session vanished)
   — never ANSI colour, so the table stays legible in a log or pipe. **PR/CI/Review
   are cache mirrors** (golem-status is `gh`-free); the authoritative CI/review
   values are the live `pr_status[]` poll above, which the checkpoint defers to.
   The **`ELAPSED`** column reads the golem cache's `started` — stamped by the
   Phase D "Label + cache" step (worktree golems) or the container entrypoint
   (Mode 3); a golem whose initial cache write omitted `started` renders ELAPSED
   as `—` (no fabricated age).

   **This is purely about *how status is surfaced*.** Making the rolling sweep
   opt-in changes nothing about gate handling: the **never-time-out human-gate**
   guarantee (every kept gate waits indefinitely for a human) and the
   **never-kill slow-review** posture (below) are unchanged — the push gate-watch
   is precisely what enforces them, and it is now the always-on default.

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

**Slow pre-PR reviews — surface, don't kill (default never-kill).** A golem's
`/workflow:ship-issue` pre-PR review can legitimately run **25–30+ min**; the default
posture is **surface-and-wait**, not decide-and-kill. **Do NOT auto-kill** on
the old signal (a frozen `N/6 agents` sub-workflow counter + ~15 min): it
conflated three benign states with a real wedge (~75%+ false positives; batch-7,
2026-07-16 = **zero** confirmed wedges). A takeover is an **operator offer,
never automatic**: a **crashed/exited process** qualifies on its own (after the
pre-kill PR check); **otherwise** offer only once the **top-level** token counter
has been frozen for a **45–60 min** window (sub-workflow growth doesn't count)
**and**, in a multi-golem batch, a sibling review is advancing (cross-golem
corroboration — inapplicable in a solo run). The freeze reading is mechanical for
**both modes** — `golem-status.sh`'s `TOP-LEVEL TOKENS` section renders
`frozen Xm` per golem each sweep: a **worktree golem (Mode 2)** is scraped from
its host transcript (#371), and a **container golem (Mode 3)** renders the same
`frozen Xm` from the top-level usage it POSTs back into the host cache (#390)
(only a container that has not POSTed yet shows `awaiting token push`). Always run
the pre-kill check
(`gh pr list --state open --head <the golem's branch>` — realization-specific:
`feature/issue-{N}` for a worktree golem, `agent{N}` for a container golem) before
**any** kill — if a PR exists, **skip** the takeover and merge (golem-328 PR'd in
the decision→kill window). See `mode-protocol.md` § *Slow-review takeover
contract* for the exact per-mode command, rationale, benign-state evidence, and
the takeover recipe.

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
Monitor({                                       # modes: plan-mode drift (#659)
  command: "${CLAUDE_PLUGIN_ROOT}/scripts/golem-mode-check.sh --watch --fix",
  description: "golem permission-mode drift (auto-corrected, reported loudly)",
  persistent: true,
})
```

The **mode channel** is a third co-equal watch, and it catches a failure the
other two structurally cannot: a golem left in **plan mode past plan approval**
is not at a gate at all. It is working — narrating file writes, prompting on
each one — so neither the feed nor the pane-overlay matchers ever fire, while
the run silently degrades from its dispatched level to L1 (#659). It emits on
drift and on each correction; a **recurring** correction for the same golem is
itself the signal that the root cause is still live, so surface it rather than
filing it as noise. Because it is phase-gated (drift only when plan mode
coexists with evidence of post-planning work), a golem legitimately designing in
plan mode produces no line and is never corrected — a correction there would
skip the very gate its level exists to enforce.

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
  renders over the alt-screen and is reliably scrapeable. It also catches an
  **`AskUserQuestion` escalation fork** by its `Enter to select` footer (as a
  last-resort match, after plan-gate and generic-gate), labelled
  *"escalation — …"* like the feed's escalation lines (#257). Finally — the true
  last-resort branch, after all three modal matchers — it surfaces a
  **turn-ended / idle-at-prompt** golem (#447): a session whose turn ended and
  now sits at an empty prompt awaiting human input (e.g. commit signing halted on
  a locked vault) paints only the ordinary `⏵⏵ auto mode on` footer with **no**
  `esc to interrupt` run-spinner — not a modal overlay, so the three matchers
  above miss it, yet the very stall class that silently parks an L4 run. It is
  labelled *"⚠ idle at prompt — turn ended, awaiting input"* and, like every pane
  line, fires once on the transition into that state and re-fires only after it
  clears. Unlike the modal matchers it is **confirmed across two consecutive
  polls** before it fires (a golem momentarily between turns can paint the idle
  footer for a single tick), so a genuine stall surfaces one poll interval after
  it begins — never on a normal turn boundary. A transient
  **zero-golem handoff window** (one session killed, the next not yet created) is
  a no-op poll, not a reason to terminate — the watch runs until the operator
  stops it (#621). See `mode-protocol.md` § *Gate-watch contract* for the prompt
  signatures and the capture-pane caveats.

A human operator gets the same proactive surface with **`${CLAUDE_PLUGIN_ROOT}/scripts/golem-watch.sh`**
(streams both channels). See `mode-protocol.md` § *Gate-watch contract* for the
notify/suppress/re-notify rules, and #600 (feed classification) / #587 (golem-id
attribution).

**Receive a container golem's gate — the optional HTTP listener (#407).** Both
channels above are **file-mediated**: the feed channel tails a `feed.jsonl` on
the orchestrator's own filesystem, and the pane channel scrapes a host-visible
`tmux`. A **container golem** shares neither — its feed is trapped inside the
container (the transport gap tracked in containers#735) — so its gate is
invisible to both until the next PR/issue-label sweep. To close that gap without
a shared filesystem, arm the **optional receiver**
`${CLAUDE_PLUGIN_ROOT}/scripts/golem-event-listener.sh` alongside the two
`Monitor`s above (a `Monitor`/background invocation), when supervising container
golems:

```text
Monitor({                                       # optional: receive container-golem POSTs
  command: "${CLAUDE_PLUGIN_ROOT}/scripts/golem-event-listener.sh",
  description: "golem HTTP event receiver → feed.jsonl (container golems)",
  persistent: true,
})
```

The listener is the **consumption half** of the multi-sink event bus
(ADR-0001 Decision 3): #406's `golem-notify.sh` already POSTs each classified
event — a body **byte-identical to a `feed.jsonl` line** — to every
`GOLEM_EVENT_SINKS` endpoint. A container golem points its `GOLEM_EVENT_SINKS`
at this host listener (via the containers#735 transport; see
`container-protocol.md`), and the listener **appends each received POST into the
orchestrator's own `feed.jsonl`** — so its gate then surfaces through the **same
feed channel `--stream` above, identically to a worktree golem's**
(gate/escalation/dead-end classification + golem-id attribution preserved; no
new surfacing path). It binds **loopback** by default (`GOLEM_EVENT_LISTEN_ADDR`
/ `GOLEM_EVENT_LISTEN_PORT`, see the plugin README's env table). It is **purely
additive**: when it is not armed, the feed + pane floor stands exactly as above,
and worktree golems — which share the orchestrator's filesystem — never need it.
The GitHub PR/issue-label poll is untouched.

**Resolve a brokered gate centrally (the inbox — #227).** For an **escalation**
or **dead-end** line (not a routine permission `gate`, and not a plan-gate — see
the data-only invariant below), you can relay the decision back into the golem
from **this** session instead of `golem-attach`'ing into its TTY:

1. **Parse the gate-id.** The golem embeds a `[gate-<epoch>-<rand>]` token in its
   `ESCALATION:`/`DEAD-END:` message, so the emitted `golem-{N}\t<message>` line
   already carries it. Extract it:

   ```bash
   gate_id="$(printf '%s' "$message" | command grep -oE 'gate-[0-9]+-[0-9a-z]+' | command head -n1)"
   ```

2. **Present the payload once, centrally.** Read the full decision payload
   (decision + options + recommendation) from the golem's **issue comment**
   (posted at escalation time, prefixed with the same gate-id) and present it to
   the operator via **one** `AskUserQuestion` — the options are the escalation's
   own options, plus a *"let me attach instead"* escape hatch.

3. **Relay the answer down.** On the operator's choice, write it to the golem's
   inbox:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/golem-inbox.sh" answer "golem-{N}" "$gate_id" "<chosen-option>" \
     [--note "<optional one-liner>"]
   ```

   The golem's `consume` loop reads it and proceeds — **no attach required**.
   Attribution is two-layer (inbox filename keyed by golem-id + in-record `gate`
   filter), so the answer can never reach the wrong golem or the wrong gate.

**Auto-relay across many golems.** Because the feed `--stream` above emits one
line per *fresh* escalation, the natural monitor loop is: on each emitted
`escalation`/`dead-end` line, run steps 1–3 — present via `AskUserQuestion`,
`answer` into the inbox — then return to the stream. One operator supervising N
golems thus **batch-answers** each blocked golem from this session in turn,
never hopping between N TTYs. `golem-attach.sh {N}` stays available as the manual
fallback for any gate the operator would rather handle in-session.

**See which gates are still unanswered (#395).** `${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh`
annotates each escalation/dead-end line in its BLOCKED list with the inbox state
— `[inbox: awaiting]` (no decision written yet), `[inbox: answered]` (a decision
is waiting for the golem to consume), or `[inbox: consumed]` (the golem has taken
it). Read this before answering: an `awaiting` line still needs a decision, while
an `answered`/`consumed` one is already handled — so an operator sweeping a batch
does not **double-answer** a gate the golem hasn't consumed yet. The annotation
is a read-only snapshot (`golem-inbox.sh state <golem> <gate-id>`), point-in-time
like the rest of the status view; a routine permission `gate` or plan-gate
carries no gate-id and is left un-annotated (it is not inbox-brokered — the
data-only invariant below).

**Data-only invariant — do NOT broker a plan-gate this way.** A plan-gate
`ExitPlanMode` (feed: a generic `gate`; pane: the plan-approval overlay) resolves
an **auto-mode** transition, which the inbox must never carry. Plan approval
stays on the compliant directed `tmux send-keys` broker (`SKILL.md` § Phase D and
`mode-protocol.md` § *Plan gate by level*, settled in #281): present the plan,
and on approval **the orchestrator sends the keystroke**, a human-authorized
directed action — never an inbox `answer`. The inbox is for escalation/dead-end
**data** only. See `mode-protocol.md` § *Reverse channel (the inbox)* for the
full #29 rationale.
