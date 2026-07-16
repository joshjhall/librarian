# Ship Issue Protocol

Companion to `ship-issue/SKILL.md`. Reference material loaded alongside the
skill: the golem execution model (for orchestrators) and the full environment-
variable contract that toggles non-default ship behavior.

## Golem Execution Model (for orchestrators)

A golem running this skill is an OS **process**, never itself a Workflow
subagent. This skill drives the adversarial review harness
(`ship-issue/workflow.js`, Step 3.5 item 6 and the Step 4 multi-cycle
loop), which in turn fans out the `code-reviewer` agent. The Workflow tool
permits only **one level of nesting** (`workflow()` inside a workflow throws),
and that nesting level is reserved for the review harness's own fan-out — so a
golem MUST be its own process and own the single Workflow invocation tree.

Orchestrators (e.g. the master-orchestrator in #524) MUST spawn golems as
**processes** (subprocess / container / worktree), NOT as Workflow subagents.
Spawning a golem as a Workflow subagent would consume the one nesting level and
make the review harness invocation throw.

## Environment Variables

### The merge invariant (all levels)

**Never merge unless CI is green *and* the PR review loop terminated clean.** This
is uncrossable at **every** level, L4 included — no env var, flag, or level
crosses it (`orchestrate/autonomy-levels.md` § merge invariant). Merge is a
**routine gate**: the level decides whether merging needs a human keystroke
(L3–L4 auto, L1–L2 human), never whether an un-green or un-reviewed PR may merge.
If the CI-wait + review loop cannot reach green + clean, that is a **dead-end**
(#181) — park the PR and wait for a human at every level. The merge itself lives
in SKILL.md Step 4 (the level-aware merge gate), after the review loop.

### Toggles

These env vars toggle non-default behavior; all are opt-in:

- `PRE_REVIEW_STRICT=true` — pre-review gates (Step 3.5) block Option 1 PR
  creation on HIGH certainty findings instead of warning only.
- `REVIEW_MAX_CYCLES` — integer, default `3`. Caps the post-CI multi-cycle
  adversarial review loop (Option 1). The cap lives in this skill, not in
  `workflow.js`, which runs exactly one review cycle per invocation.
- `REVIEW_STRICT=true` — treat MEDIUM-certainty findings as blocking in the
  adversarial review (Step 3.5 item 6 and the Step 4 loop), in addition to the
  default HIGH-certainty blocking set. Parallels `PRE_REVIEW_STRICT`.
- `LIBRARIAN_CI_WAIT_TIMEOUT` — integer **minutes**, default `15`. Threshold for
  the "Wait for CI" poll loop (Step 4 Option 1): once cumulative wait crosses
  this, the loop hits a **checkpoint** instead of polling forever. At **L1–L2**
  (interactive): prompt **cut short** vs **extend** (another interval). At
  **L3–L4**: extend automatically up to `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` times,
  then STOP — see the CI-monitor sub-step. The 30 s poll cadence is unchanged;
  this only bounds total wait.
- `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` — integer, default `2`. At **L3–L4**, how
  many extra `LIBRARIAN_CI_WAIT_TIMEOUT` intervals the CI-wait loop adds before
  giving up (default `15` + 2×`15` = 45 min total), so a headless golem polling a
  stuck CI run cannot hang. Ignored at L1–L2 (the human chooses cut-short/extend
  at each checkpoint).
- `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` — integer **minutes**, default `20`. Max
  wall-time the skill awaits a **single `Workflow` tool invocation** (the pre-PR /
  post-PR review fan-out, `ci-fixer`) before hitting a checkpoint — the
  wall-clock analogue of `LIBRARIAN_CI_WAIT_TIMEOUT`, for #224. The `workflow.js`
  sandbox bans clocks/timers (`Date.now`/`new Date` throw; no `setTimeout`/
  `AbortSignal`), and a *spinning* agent emits no tokens so it never advances the
  harness token budget — so a harness cannot self-deadline. The skill bounds the
  wait instead: invoke the harness as a background task and poll `TaskOutput`
  against this threshold. The threshold/extension **arithmetic is not re-derived
  in prose** (that drift wedged three golems, #327) — the skill **calls**
  `scripts/workflow-wall-timeout.sh check --elapsed-min N --level L
  --extensions-used K` each poll, which reads this var and returns a
  `continue|extend|stop|checkpoint` verdict. At **L1–L2** (interactive): a
  checkpoint verdict prompts **cut short** vs **extend** (another interval). At
  **L3–L4**: the helper auto-extends up to `LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS`
  times, then returns `stop` → the skill `TaskStop`s the run and proceeds with
  recovered partials — see the review/ci-fixer sub-steps.
- `LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS` — integer, default `1`. At **L3–L4**,
  how many extra `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` intervals a hung `Workflow`
  invocation is granted before it is `TaskStop`-ped (default `20` + 1×`20` = 40
  min ceiling), so a headless golem whose review agent spins cannot hang the ship.
  Ignored at L1–L2 (the human chooses cut-short/extend at each checkpoint). Read
  by `scripts/workflow-wall-timeout.sh` alongside `LIBRARIAN_WORKFLOW_WALL_TIMEOUT`
  to compute the ceiling (`TIMEOUT × (MAX_EXTENSIONS + 1)`); `0` makes the first
  checkpoint the ceiling (no auto-extend, even at L4).
- `LIBRARIAN_CI_INFRA_STEPS` — `|`-separated regex of known infra/setup step
  names that mark a CI failure as a **likely flake** rather than a code
  regression (CI-failure triage, Step 4 Option 1). Default:
  `Set up Docker Buildx|Checkout|checkout|Login|login|cache|Cache|Set up job`.
  A failure whose failing step matches this — or whose failing job type cannot
  be affected by the PR's changed files — is auto-retried once before any
  escalation. Override per repo to teach the triage that repo's setup steps.
- `LIBRARIAN_CI_INFRA_RETRIES` — integer, default `1`. How many times an
  infra-classified failure is `gh run rerun --failed` before escalating to
  `ci-fixer`/the human. This bound is **independent of** the `ci-fixer` 3-attempt
  cap (which covers code fixes) — it only re-runs an unchanged infra step. Set
  `0` to disable infra auto-retry (every failure goes straight to ci-fixer/human).
  Degrades gracefully: if classification data can't be fetched, the triage falls
  through to the normal ci-fixer handoff with an escalate-with-note, never a
  hard-fail.

> **Review thresholds — two independent bounds.** `REVIEW_MAX_CYCLES` (above)
> caps the number of review **cycles** (cost/iterations); it gives the
> cut-short/extend + non-interactive-fallback semantics *across* cycles (L1–L2
> prompt to fix/ship/defer at the cap; L3–L4 defers). It does **not** bound the
> **wall-time of one cycle** — a single harness invocation whose reviewer agent
> spins runs unbounded even far below the token budget (#224). That latency is
> bounded separately by `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` (above), applied by the
> skill around each `Workflow` invocation. The two are orthogonal: the cycle cap
> bounds *how many* reviews, the wall timeout bounds *how long any one* review may
> hang. A wall-timed-out cycle is **partial** — it can never read as `clean`,
> exactly like `budget_exhausted`.

## Step 5 — Context Reset & Continue

Loaded from SKILL.md Step 5 (the interactive loop-back).

At **L2–L4**, skip this step entirely — an L3–L4 run already merged and exited,
and an L2 run already emitted its completion summary (see `execute-protocol.md`
Option 1 "Completion summary") and stops for a human merge. A single golem owns
one issue; looping is the orchestrator's responsibility and out of scope here.
Only an **L1** interactive run reaches the prompt below.

After shipping, tell the user:

> Issue #{N} shipped. Run `/clear` to start fresh, then `/next-issue` to
> pick up the next issue.

Then ask with `AskUserQuestion`:

- **Pick next issue** — invoke `/next-issue` to select and plan the next one
- **Stop** — end the session

**Agent worktree mode**: When running on an agent branch (`^agent`), this
behavior persists across invocations — `/ship-issue` will always
auto-select commit-only mode (Option 3) without prompting.
