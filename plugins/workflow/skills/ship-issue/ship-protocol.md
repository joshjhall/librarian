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

> **Review threshold:** the adversarial **review** loop is bounded by
> `REVIEW_MAX_CYCLES` (above), not a wall-clock timer — that cap, plus the
> harness's token budget, already gives the issue's cut-short/extend +
> non-interactive-fallback semantics (L1–L2 prompt to fix/ship/defer at the cap;
> L3–L4 defers). There is intentionally no separate review timeout var.
