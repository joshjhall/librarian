# Orchestrate — Phase D: Dispatch

Companion to `orchestrate/SKILL.md`, split out of it in #973 when that file
passed its skill-definition prose budget. It carries **Phase D** in full: golem
launch across the three execution modes, preflight, worktree creation, the
autonomy-level decision, and the dispatch report.

Phase D is by far the longest phase in the skill and the only one that starts
processes, which is what makes it the seam — the surrounding phases (P, M, R, T)
each already delegate to their own companion, so SKILL.md is a dispatch table
plus per-phase pointers, and Phase D was the last phase still inlined.

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

   **Preflight also probes plugin resolvability (#946).** The same run reports
   whether `workflow@librarian` still resolves with a non-zero skill count. The
   marketplace registration has been observed to **vanish mid-session**: golems
   already running keep working (they loaded their skills at startup), so nothing
   surfaces the loss until the next dispatch — where the new golem dies at its
   first prompt on `Unknown command: /workflow:next-issue` and idles. Gate-watch
   classifies that pane as **idle**, so a four-lane run silently becomes a
   three-lane one. `launch` therefore **refuses** (exit 3) on an unresolvable
   plugin, naming the re-register commands; `preflight` and `print` only warn.
   Re-register with `claude plugin marketplace add joshjhall/librarian` (or the
   baked `/opt/librarian` directory in a container), then re-dispatch.

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

   **A multi-question `AskUserQuestion` form takes DIFFERENT keystrokes (#467).**
   That `1 Enter` send assumes a single-question prompt: in the multi-question
   tabbed widget a digit does nothing or lands on the wrong question, and the
   review screen will `Submit` a **partially-answered** form — resolving the gate
   wrongly rather than failing visibly. So a broker must **branch on
   single-vs-multi**, which is why the gate-watch labels that class distinctly
   (*"escalation (multi-question form) — forward-order only, never a digit"*).
   Answer it forward-order with `↑/↓`+`Enter`, letting the widget auto-advance,
   and submit only once every question shows `☒`; fall back to cancel-then-text-
   directive if an earlier answer needs revising — `monitor-protocol.md` § *A
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
