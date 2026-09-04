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

## Workflow authority — the review harness call is already opted in (#637)

The harness that runs this skill restricts the `Workflow` tool to cases where
the user explicitly opted into multi-agent orchestration. **That opt-in is
already satisfied here, and this is the one place that says so** — the tool's
own description lists as valid opt-in:

> The user invoked a skill or slash command whose instructions tell you to call
> Workflow.

`/workflow:ship-issue` is exactly that: a slash command whose instructions
direct the `Workflow` call. Every harness invocation this skill mandates — the
Step 3.5 adversarial pre-PR review, the Step 4 multi-cycle PR loop, and the
`ci-fixer` harness — is therefore **authorized by the operator's invocation of
the command**, not something to weigh against the restriction.

So: **do not re-derive this per run, and do not treat the restriction as a
reason to skip.** A golem that re-litigates the question on every ship pays for
the same resolution forever; one that resolves it *wrongly* degrades the review
(see the graceful-degradation clauses in `pre-ship-validation.md` and
`ci-review-protocol.md`, which exclude permission doubt as a skip reason and
forbid substituting a hand-rolled review). The invocation sites cross-reference
this section rather than restating it — keep the authority here, in one place.

**What the substitute actually costs — measured (#645).** The worst resolution
is not skipping; it is skipping the harness *while still spawning subagents*,
which takes the cost of both and the benefit of neither. Measured on PR #642:

| | Wall time | Shape |
| --- | --- | --- |
| **Harness cycle** | **5.4 min** | 7 agents, 5 dimensions in one parallel barrier, 50k output tokens |
| **Serial substitute** | **9–61 min per cycle**, 8 cycles, **~2.5 h** | one general-purpose subagent per cycle |

The serial cycles also **lost the pre-scan handoff, the conventions digest, and
the judge**, and each re-derived the manifest from scratch — so the substitute
is not a cheaper version of the harness, it is a different and much worse thing.
(Source: librarian's own `CLAUDE.md` § *`ship-issue`'s review step runs the
Workflow harness*, which carries the same rule as repo-level session guidance;
this section is its counterpart for consuming repos, which never load that file.)

## State reconstruction (missing-state-file fallback)

Loaded from SKILL.md Step 1. The Phase 1/2 state write can legitimately be
absent — e.g. an older `/workflow:next-issue` run that entered plan mode before the write
ordering was fixed (issue #409), or a `/clear` that dropped an in-context-only
state. When the Step 1 glob finds no `next-issue-*.json`, reconstruct a minimal
state from the branch + issue before giving up:

1. **Parse the issue number from the branch.** Match the current branch against
   the `next-issue/state-format.md` § Branch Naming convention
   (`{prefix}/issue-{N}-{slug}`):

   ```bash
   CURRENT_BRANCH=$(git branch --show-current)
   # Require the trailing `-{slug}` (or a bare `issue-{N}` branch) so a typo
   # like `fix/issue-409extra` does not mis-parse as #409.
   N=$(printf '%s\n' "$CURRENT_BRANCH" \
     | command grep -oE '^(fix|feature|docs|test|refactor|chore)/issue-[0-9]+(-|$)' \
     | command grep -oE '[0-9]+')
   ```

   No match (not an issue branch) ⇒ reconstruction is impossible; fall through
   to the "nothing to ship" stop.
1. **Confirm the issue is open and in-progress.** Fetch state + labels and
   require `OPEN` **and** a `status/in-progress` label — the marker that
   `/workflow:next-issue` did select and start this issue:

   ```bash
   # GitHub
   gh issue view "$N" --json number,title,state,labels \
     --jq 'select(.state=="OPEN" and (.labels|any(.name=="status/in-progress")))'
   # GitLab: glab issue view "$N" --output json  (check state + labels the same way)
   ```

   Not open, or not `status/in-progress` ⇒ do not reconstruct (this branch is
   not a live ship target); fall through to the stop.
1. **Write the reconstructed state.** Detect the platform **now** with the
   Step 2 rule (`git remote -v` → `github`/`gitlab`) — Step 2 has not run yet
   and there is no state file to read it from, so resolve it inline here. Then
   write all schema-required fields
   (`next-issue/schemas/next-issue-state.schema.json`): `version: 2`,
   `issue: {N}`, `title` (from the fetch above), `phase: "implement"`,
   `started` (today's date), `platform`, plus `branch` and `autonomy_level: 1`
   (the reconstructed path had no persisted level, so it defaults to the L1
   disposition — every gate asks, the safe default). Write it to
   `.claude/memory/tmp/next-issue-{N}.json` with the Write tool, then continue
   Step 1 (and Step 2, which will now find the `platform` field) as if the file
   had been found. **Tell the user** the state was reconstructed
   (`Reconstructed missing state for #{N} from branch {branch}`), so the
   recovery is visible, not silent.

This mirrors how this session's PR #408 recovered by hand; it degrades
gracefully (a non-issue branch or a closed/not-in-progress issue simply falls
through to the existing stop, never a hard error).

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
- `REVIEW_MAX_CYCLES` — integer, default `5`. The **hard ceiling** on the
  post-CI multi-cycle adversarial review loop (Option 1). It is no longer the
  stop *signal* — it is the backstop that guarantees termination when the
  convergence predicate (below) has not fired. The cap lives in this skill, not
  in `workflow.js`, which runs exactly one review cycle per invocation.

  The default moved `3` → `5` in #596. #567's 26-cycle batch measured 3 as wrong
  in both directions: #533 and #498 each kept finding confirmed defects through
  cycle 5, and #533's **only** `blocking` finding of the whole batch (security,
  0.92) arrived in **cycle 4** — under a cap of 3 it would have shipped. The cost
  of the higher ceiling is paid back by the predicate, which now ends a converged
  review early (#564 was verifiably clean at cycle 1, where cycles 2–3 were pure
  cost).
- `REVIEW_CONVERGENCE_SURFACE_RATIO` — integer percent 1–100, default `50`. The
  threshold at which a cycle's reviewed surface counts as **comparable** to the
  previous cycle's, used by
  `${CLAUDE_PLUGIN_ROOT}/scripts/review-convergence.sh` to decide whether a
  zero-finding cycle is real convergence.

  A zero-finding cycle terminates the loop only when
  `delta_lines >= prev_delta_lines × RATIO`. Below it the zero is treated as
  uninformative and the loop continues (rule `C3`). This is the refinement #596
  turns on: #568 cycle 2 returned zero across five dimensions on a **test-only**
  delta and the very next cycle found a 0.88-certainty real defect — a zero over
  a fraction of the previous surface says nothing about the material still
  unreviewed. Lowering the ratio makes zeros terminate more readily (cheaper,
  less thorough); raising it demands a more comparable surface before trusting a
  zero. It only ever governs whether a cycle is **added**, so it cannot weaken
  the merge invariant, and `REVIEW_MAX_CYCLES` bounds it regardless.

  The loop calls the helper once per cycle instead of comparing `cycle` to the
  cap by hand — the same "script owns the decision, model performs the action"
  split as `workflow-wall-timeout.sh` (#327), and for the same reason: a
  threshold a model re-derives each cycle drifts. The full ordered rule list
  (`C1-cap` … `C8-novel`) is documented in the script header and in
  `ci-review-protocol.md` § "Multi-cycle PR review loop" step (f), and pinned by
  `tests/validate-review-convergence.sh`.
- `REVIEW_TOKEN_CEILING` — integer, **unset by default** (no ceiling). Output-token
  ceiling for **one** review cycle, passed to `workflow.js` as `args.tokenCeiling`
  (#553). Opt-in like its neighbors: unset ⇒ the arg is omitted and the cycle is
  unbounded, which is the shipped default.

  Hitting the ceiling degrades the cycle exactly like budget exhaustion
  (`dimensions_skipped` populated, `budget_exhausted` set, `clean` forced false),
  so it can never turn a truncated review into a clean one. That safety property
  has a cost consequence worth understanding before arming it: a `clean: false`
  cycle makes the loop `cycle++` and re-run. **A ceiling below where output
  actually lands therefore does not save tokens** — it truncates every cycle,
  spends its full budget each time, exhausts `REVIEW_MAX_CYCLES`, and dead-ends
  the PR for a human. Worked example from the #471/#472 run (per-cycle output
  173k / 281k / 207k, terminated clean at 660k total): a 150k ceiling would
  truncate all three cycles, spend 450k, and still dead-end.

  Size it from measurement, not a guess. Every cycle returns `token_report`
  (`{ output_tokens, ceiling, bound, dimensions_run }`) and logs
  `cycle output: N tokens across M dimensions` whether or not a ceiling is armed;
  collect that over several real issues and set the ceiling above the observed
  p95, so it catches runaways without truncating normal reviews. Being per-cycle,
  it composes with `REVIEW_MAX_CYCLES`: worst case
  `REVIEW_TOKEN_CEILING × REVIEW_MAX_CYCLES`.
- `REVIEW_MAX_ATTEMPTS` — integer, default `2 × REVIEW_MAX_CYCLES`. The absolute
  ceiling on review-loop **attempts**, as distinct from `REVIEW_MAX_CYCLES`'s
  ceiling on cycles that actually produced a review. A cycle whose harness died
  before any dimension ran (`no_review_signal`) produces no review signal, so it
  does not charge a cycle — rule `C0b-no-signal` in `review-convergence.sh`
  returns `continue` (#616). This variable is what still guarantees termination
  in that case: rule `C0-attempt-cap` outranks everything, so a persistently
  crashing harness stops after `REVIEW_MAX_ATTEMPTS` tries rather than looping
  forever. Raise it only if genuine infra flakiness is exhausting it; a value
  below `REVIEW_MAX_CYCLES` makes the cycle cap unreachable.
- `LIBRARIAN_REVIEW_ROUTE` — `auto` | `full`, default `auto`. Set `full` to
  disable doc/config-only review routing (#550) and always run the complete
  fan-out. Any value other than `auto` is treated as `full`, so a typo disables
  the optimization rather than silently enabling it — the same fail-safe
  direction the router applies to every other ambiguity.

  Routing skips the source-reading dimensions when
  `scripts/review-route.sh` proves a diff contains no source file, leaving
  `scope-drift` (the acceptance-criteria lens) to run alone. Such a cycle is
  **complete-by-design, not partial**: it sets neither `budget_exhausted` nor
  `dimensions_skipped`, so it can still return `clean` — which is sound only
  because safety rests on the classifier, never on the reviewers. The full
  contract, the ordered rule list, and the two rejected trigger designs are in
  `review-routing.md`.
- `LIBRARIAN_REVIEW_ROUTE_MAX_LINES` — integer, default `2000`. Diff-line
  ceiling above which the cheap path is refused even for a doc-only diff: a
  5,000-line docs rewrite is a real review surface. It can only ever force
  `full`, never produce `cheap`, so lowering it is always the conservative
  direction.
- `LIBRARIAN_CI_WAIT_TIMEOUT` — integer **minutes**, default `15`. Threshold for
  the "Wait for CI" poll loop (Step 4 Option 1): once cumulative wait crosses
  this, the loop hits a **checkpoint** instead of polling forever. At **L1–L2**
  (interactive): prompt **cut short** vs **extend** (another interval). At
  **L3–L4**: extend automatically up to `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` times,
  then STOP — see the CI-monitor sub-step. The 30 s poll cadence is unchanged;
  this only bounds total wait. As with its `LIBRARIAN_WORKFLOW_WALL_*` siblings
  below, the threshold/extension **arithmetic is not re-derived in prose** — the
  skill **calls** `scripts/ci-wait-timeout.sh check --elapsed-min N --level L
  --extensions-used K` each poll, which reads this var and returns a
  `continue|extend|stop|checkpoint` verdict. Until #588 this pair was read by no
  code at all: the bound was whatever the shipping model did by hand, so setting
  it carried no guarantee it took. It now does.
- `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` — integer, default `2`. At **L3–L4**, how
  many extra `LIBRARIAN_CI_WAIT_TIMEOUT` intervals the CI-wait loop adds before
  giving up (default `15` + 2×`15` = 45 min total), so a headless golem polling a
  stuck CI run cannot hang. Ignored at L1–L2 (the human chooses cut-short/extend
  at each checkpoint). Read by `scripts/ci-wait-timeout.sh` alongside
  `LIBRARIAN_CI_WAIT_TIMEOUT` to compute the ceiling
  (`TIMEOUT × (MAX_EXTENSIONS + 1)`); `0` makes the first checkpoint the ceiling
  (no auto-extend, even at L4).
- `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` — integer **minutes**, default `20`. Max
  wall-time the skill awaits a **single `Workflow` tool invocation** (the pre-PR /
  post-PR review fan-out, `ci-fixer`) before hitting a checkpoint — the
  wall-clock analogue of `LIBRARIAN_CI_WAIT_TIMEOUT` (both helper-backed, and for
  the same reason), for #224. The `workflow.js`
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
- `LIBRARIAN_CI_INFRA_STEPS` — **agent-interpreted, not script-read** (#588; see
  the note below the list). `|`-separated regex of known infra/setup step
  names that mark a CI failure as a **likely flake** rather than a code
  regression (CI-failure triage, Step 4 Option 1), default
  `Set up Docker Buildx|Checkout|checkout|Login|login|cache|Cache|Set up job`.
  A failure whose failing step matches this — or whose failing job type cannot
  be affected by the PR's changed files — is auto-retried once before any
  escalation. Override per repo to teach the triage that repo's setup steps.
- `LIBRARIAN_CI_INFRA_RETRIES` — **agent-interpreted, not script-read** (#588).
  Integer, default `1`. How many times an
  infra-classified failure is `gh run rerun --failed` before escalating to
  `ci-fixer`/the human. This bound is **independent of** the `ci-fixer` 3-attempt
  cap (which covers code fixes) — it only re-runs an unchanged infra step. Set
  `0` to disable infra auto-retry (every failure goes straight to ci-fixer/human).
  Degrades gracefully: if classification data can't be fetched, the triage falls
  through to the normal ci-fixer handoff with an escalate-with-note, never a
  hard-fail.

> **Agent-interpreted, by design (#588).** Unlike every other variable in this
> section, the `LIBRARIAN_CI_INFRA_*` pair is read by **no script** — it is read
> by *you*, from the environment, while triaging. That is deliberate rather than
> a gap: the classification these feed is a judgment over `gh run view` JSON and
> the PR's changed-file set ("can this job type be affected by this diff?"), so
> a helper could own only the retry count, not the decision. The operator is
> passing **intent into a prompt**, and it takes effect exactly insofar as you
> honor it. Two consequences worth stating plainly: an operator cannot verify
> from outside that a setting took, and these defaults are kept honest by
> `tests/lint-env-var-drift.sh` (which allowlists these two and asserts every
> file stating a default agrees) rather than by execution.

---

> **Review thresholds — three independent bounds.** `REVIEW_MAX_CYCLES` (above)
> caps the number of review **cycles** (cost/iterations); it gives the
> cut-short/extend + non-interactive-fallback semantics *across* cycles (L1–L2
> prompt to fix/ship/defer at the cap; L3–L4 defers). It does **not** bound the
> **wall-time of one cycle** — a single harness invocation whose reviewer agent
> spins runs unbounded even far below the token budget (#224). That latency is
> bounded separately by `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` (above), applied by the
> skill around each `Workflow` invocation. The third is the **convergence
> predicate** (`review-convergence.sh`, gated by
> `REVIEW_CONVERGENCE_SURFACE_RATIO`), which decides whether reviewers still have
> material *at all*. The three are orthogonal: the cycle cap bounds *how many*
> reviews, the wall timeout bounds *how long any one* review may hang, and the
> predicate decides *whether another one is worth running*. A wall-timed-out
> cycle is **partial** — it can never read as `clean`, exactly like
> `budget_exhausted`, and the predicate likewise refuses to converge on it (rule
> `C2`), so a truncated review can never end the loop by either route.

## Step 5 — Context Reset & Continue

Loaded from SKILL.md Step 5 (the interactive loop-back).

At **L2–L4**, skip this step entirely — an L3–L4 run already merged and exited,
and an L2 run already emitted its completion summary (see `execute-protocol.md`
Option 1 "Completion summary") and stops for a human merge. A single golem owns
one issue; looping is the orchestrator's responsibility and out of scope here.
Only an **L1** interactive run reaches the prompt below.

After shipping, tell the user:

> Issue #{N} shipped. Run `/clear` to start fresh, then `/workflow:next-issue` to
> pick up the next issue.

Then ask with `AskUserQuestion`:

- **Pick next issue** — invoke `/workflow:next-issue` to select and plan the next one
- **Stop** — end the session

**Agent worktree mode**: When running on an agent branch (`^agent`), this
behavior persists across invocations — `/workflow:ship-issue` will always
auto-select commit-only mode (Option 3) without prompting.
