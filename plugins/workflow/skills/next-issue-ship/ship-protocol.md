# Next Issue — Ship Protocol

Companion to `next-issue-ship/SKILL.md`. Reference material loaded alongside the
skill: the golem execution model (for orchestrators) and the full environment-
variable contract that toggles non-default ship behavior.

## Golem Execution Model (for orchestrators)

A golem running this skill is an OS **process**, never itself a Workflow
subagent. This skill drives the adversarial review harness
(`next-issue-ship/workflow.js`, Step 3.5 item 6 and the Step 4 multi-cycle
loop), which in turn fans out the `code-reviewer` agent. The Workflow tool
permits only **one level of nesting** (`workflow()` inside a workflow throws),
and that nesting level is reserved for the review harness's own fan-out — so a
golem MUST be its own process and own the single Workflow invocation tree.

Orchestrators (e.g. the master-orchestrator in #524) MUST spawn golems as
**processes** (subprocess / container / worktree), NOT as Workflow subagents.
Spawning a golem as a Workflow subagent would consume the one nesting level and
make the review harness invocation throw.

## Environment Variables

These env vars toggle non-default behavior; all are opt-in:

- `AUTOMERGE=1` — in Option 1 (Branch + PR), queue the PR for GitHub's
  native auto-merge via `gh pr merge --auto --squash --delete-branch`
  immediately after PR creation and exit, skipping the CI-wait loop. Because
  the fast path exits before the post-CI multi-cycle review loop, it
  **intentionally skips that loop** — `AUTOMERGE=1` is the per-invocation
  escape hatch from the review gate. GitHub only. Skipped for
  `severity/critical` issues. Falls through to the normal CI-wait loop if
  `gh pr merge --auto` fails (e.g., auto-merge not enabled on the repo). See
  Option 1 "Auto-merge fast path" in SKILL.md. The orchestrate **integration
  train** (`orchestrate` § Phase T) is the batch consumer of this same
  `gh pr merge --auto` settle-on-green path: it lands a set of PRs with one
  up-front approval, relying on `--auto` to merge each as its (already-green)
  checks settle rather than a manual merge + wait per PR.
- `AUTOMERGE_AUTONOMOUS=1` — **required second consent** to allow the
  `AUTOMERGE=1` fast path *while autonomous*. Auto-merge skips the entire
  adversarial review loop, and an autonomous golem sets autonomy from the
  environment — so `AUTOMERGE=1` alone in an autonomous run would merge to the
  default branch unreviewed and unseen. To prevent that, when the run is
  autonomous the auto-merge fast path is taken ONLY if BOTH `AUTOMERGE=1` and
  `AUTOMERGE_AUTONOMOUS=1` are set. If `AUTOMERGE=1` is set but
  `AUTOMERGE_AUTONOMOUS=1` is not, the run ignores auto-merge and falls through
  to the normal CI-wait loop + review, stopping at green CI for human merge.
  Has no effect in non-autonomous runs (interactive `AUTOMERGE=1` is unchanged
  — the human is already in the loop). **Operational note:** the two-variable
  scheme is a real consent gate only if the variables come from *separate*
  sources — setting both in the same `.env` block, compose `environment:`, or
  CI secret group defeats the "second consent" intent (one copy-paste enables
  unreviewed merges). Inject `AUTOMERGE_AUTONOMOUS=1` from a distinct
  configuration source (e.g. a separate 1Password entry / secret group) than
  `AUTOMERGE=1`, and only for golem environments that are meant to auto-merge.
  The integration train does **not** weaken this: its single batch approval
  authorizes the *sequence* of merges, but each PR's auto-merge still requires
  BOTH `AUTOMERGE=1` and `AUTOMERGE_AUTONOMOUS=1` when the train runs autonomously.
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
  this, the loop hits a **checkpoint** instead of polling forever. Interactive:
  prompt **cut short** vs **extend** (another interval). Autonomous: extend
  automatically up to `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` times, then STOP — see
  the CI-monitor sub-step. The 30 s poll cadence is unchanged; this only bounds
  total wait.
- `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` — integer, default `2`. In autonomous runs,
  how many extra `LIBRARIAN_CI_WAIT_TIMEOUT` intervals the CI-wait loop adds
  before giving up (default `15` + 2×`15` = 45 min total), so a headless golem
  polling a stuck CI run cannot hang. Ignored interactively (the human chooses
  cut-short/extend at each checkpoint).
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
> non-interactive-fallback semantics (prompt to fix/ship/defer at the cap;
> autonomous defers). There is intentionally no separate review timeout var.
