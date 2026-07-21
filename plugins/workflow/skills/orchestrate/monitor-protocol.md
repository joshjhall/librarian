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
   BLOCKED list, liveness, per-golem TOP-LEVEL TOKENS, recent feed). The two are
   **mutually exclusive per sweep** — both re-drive the same token scrape, so
   running both in one sweep would reset the burn-Δ baseline. (This
   "status-checkpoint table" is distinct from the plan checkpoint at
   `ExitPlanMode` and the poll harness's per-PR resumability checkpoint.)

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

   The checkpoint's **`TOKENS(Δ)`** column and footer `rate/hr` are honest only
   across sweeps: `Δ = tokens since the previous sweep`, and the aggregate rate is
   `Σ Δ ÷ this sweep's interval` — so the **first** sweep after arming (and any
   one-shot `--checkpoint` with no `--watch`) prints `rate=—` rather than a
   fabricated number. Per-sweep **Δ / rate** stay a **worktree-golem (Mode 2)**
   signal (they need golem-status's own prior sample); a container golem (Mode 3)
   POSTs its cumulative top-level count into the cache (#390), so its `TOKENS(Δ)`
   shows the count with a `(frozen)` tag — folded into `Σtokens` but not the Δ —
   or `n/a` until that POST lands. **Attention markers ride the `STATE` column**
   as plain text (`⚠ BLOCKED`
   at a gate, `⚠ CI` on a failing check, `⚠ gone` when the tmux session vanished)
   — never ANSI colour, so the table stays legible in a log or pipe. **PR/CI/Review
   are cache mirrors** (golem-status is `gh`-free); the authoritative CI/review
   values are the live `pr_status[]` poll above, which the checkpoint defers to.
   The **`ELAPSED`** column reads the golem cache's `started` — stamped by the
   Phase D "Label + cache" step (worktree golems) or the container entrypoint
   (Mode 3); a golem whose initial cache write omitted `started` renders ELAPSED
   as `—` (no fabricated age).

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
`/ship-issue` pre-PR review can legitimately run **25–30+ min**; the default
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
