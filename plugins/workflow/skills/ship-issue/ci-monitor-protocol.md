# Next Issue — CI Monitor Protocol

Companion to `ship-issue/ci-review-protocol.md`, split out of it in #973 when
that file passed its prose budget. It carries the **first half** of the Option 1
post-creation sequence: monitoring CI checks after the PR is created, triaging
failures, and driving the `ci-fixer` harness. The **second half** — the
multi-cycle PR review loop, finding classification, and filing deferred findings
— stays in `ci-review-protocol.md`.

The split is along the seam the protocol already had: CI must be green *before*
the review loop starts, so the two halves are sequential phases that share only
that boundary, not interleaved concerns. Load this one when CI is red or
unfinished; load the other when it is green.

Environment variables (`LIBRARIAN_CI_WAIT_TIMEOUT`,
`LIBRARIAN_CI_WAIT_MAX_EXTENSIONS`, `LIBRARIAN_CI_INFRA_STEPS`,
`LIBRARIAN_CI_INFRA_RETRIES`) are defined in `ship-protocol.md` § Environment
Variables.

**Two kinds of variable appear below, and the difference is load-bearing.** The
`LIBRARIAN_CI_WAIT_*` pair is read by `scripts/ci-wait-timeout.sh`, which you
**call** — set it and it provably takes effect. The `LIBRARIAN_CI_INFRA_*` pair
is **agent-interpreted**: no script reads it, and it takes effect only because
you honor it while triaging below (#588).

## Monitor CI and remediate failures

Advisory; the `ci-fixer` Workflow harness caps fixes at 3 attempts per check.
Before labeling the issue, optionally monitor CI checks and auto-fix failures.
Ask the user:

- **Wait for CI** — monitor checks and auto-fix failures if possible
- **Skip CI monitoring** — proceed to labeling immediately

At **L3–L4**, do not prompt — ALWAYS wait for CI and auto-fix (proceed
as if the user chose "Wait for CI"). **L1–L2** asks. (The CI-wait is a routine
gate; `<skill-base-dir>/../../scripts/autonomy-resolve.sh gate routine --level {N}`
→ `disposition=auto|human` is the shared source of the L3–L4-auto cutoff, #190.)

If the user chooses to wait:

a. **Poll for check completion** against a wait threshold (so a stuck or
slow CI run never blocks indefinitely):

- GitHub: `gh pr checks {pr_number} --json name,state,conclusion`
  (poll every 30 seconds until no checks have `state: "pending"`)
- GitLab: `glab ci status` (check for completion)
- **Threshold checkpoint** — track cumulative wait time, but do **not**
  re-derive the threshold/extension arithmetic in your head (that drift wedged
  three golems on the sibling wall-timeout, #327). **Call** the helper each
  poll and act on its verdict:

  ```bash
  # substitute <skill-base-dir>: next-issue/worktree-safe-recipes.md (#815)
  <skill-base-dir>/../../scripts/ci-wait-timeout.sh check \
      --elapsed-min {cumulative} --level {N} --extensions-used {K}
  ```

  It reads `LIBRARIAN_CI_WAIT_TIMEOUT` (default `15`) and
  `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` (default `2` → a 45 min ceiling) and
  returns `verdict`, `ceiling_min`, `next_deadline_min`, and
  `extensions_used`:

  | `verdict` | Do |
  | --- | --- |
  | `continue` | Keep polling every 30 s, up to `next_deadline_min`. |
  | `extend` | L3–L4 auto-grant: carry the returned `extensions_used` into the next call and keep polling. |
  | `checkpoint` | L1–L2 only: prompt — **Cut short** (stop waiting; proceed to labeling, noting CI was still pending) or **Extend** (re-call with `--extensions-used` incremented). |
  | `stop` | Stop waiting at the ceiling — proceed to the completion summary with a STOP note ("CI still pending after `{ceiling_min}` min — not waited further"), mirroring the L3–L4 CI-failure STOP below. |

  Never hang waiting on a prompt at L3–L4. The `stop` verdict is a machine
  timer for **pending CI**, not a human gate — the never-time-out rule governs
  human gates, not this bounded wait.

b. **If all checks pass** (CI green): inform the user and proceed to the
multi-cycle review loop below; green CI is one half of the merge invariant, and
the merge gate (SKILL.md Step 4) fires only once the review loop is also clean.

c. **If checks fail — triage infra-flake vs real regression FIRST**
(classification, not a new retry layer). Before handing anything to
`ci-fixer`, classify each failing check so a known infra/setup flake is not
surfaced as a code regression, and collapse cascade failures to their root
cause:

- **Fetch the failing STEP name and the PR's changed-file set:**

  ```bash
  gh pr checks {pr_number} --json name,state,conclusion,link \
    | jq '[.[] | select(.conclusion == "failure")]'
  gh run view {run_id} --json jobs \
    --jq '.jobs[] | select(.conclusion=="failure")
          | {job:.name, step:([.steps[] | select(.conclusion=="failure") | .name] | first)}'
  git diff --name-only origin/main...HEAD     # the PR's changed files
  ```

- **Classify each failure:**
  - **Likely infra/flake** — the failing step matches a known
    setup/provisioning step (the env-overridable, **agent-interpreted** list
    `LIBRARIAN_CI_INFRA_STEPS`, default
    `Set up Docker Buildx|Checkout|checkout|Login|login|cache|Cache|Set up job`),
    OR the failing job type cannot be affected by the PR's changed files
    (e.g. a Docker `Build` job on a docs/tests-only diff). → **auto-retry
    once**: `gh run rerun --failed`, then re-poll from (a) and re-evaluate;
    escalate only if it **re-fails**. This auto-retry is bounded by
    `LIBRARIAN_CI_INFRA_RETRIES` (default `1`, also agent-interpreted) and is
    INDEPENDENT of — it does not consume or duplicate — the `ci-fixer` 3-attempt
    cap (that cap covers *code* fixes; this covers *re-running* an unchanged
    infra step).
  - **Likely real** — the failing step exercises the change (a test / lint /
    build step touching the diff). → skip the retry; go straight to the
    `ci-fixer` handoff below (today's behavior).
- **Collapse cascade failures.** An aggregation/summary job (e.g.
  `PR Tier > Summarize`) that failed only because an upstream job it depends
  on failed is NOT an independent failure — attribute it to its upstream
  root cause and report it once, under that cause, rather than as a second
  failing check.
- **Degrade gracefully.** If step names or the changed-file set can't be
  fetched (API error, unrecognized step), do NOT hard-fail and do NOT auto-
  retry blindly — fall through to the `ci-fixer` handoff and, when
  autonomous, record an escalate-with-note ("CI triage unavailable —
  classified as real") in the completion summary. Never block shipping on the
  triage step itself.

For any failure classified **real** (or an infra failure that re-failed after
its bounded retry), hand it to the `ci-fixer` Workflow harness, which owns the
code-fix retry loop (hard-capped at 3 attempts per check) and fans independent
checks in parallel under one shared token budget — you no longer track an
iteration counter by hand.

- Collect every failing check into a `checks` array. For each one, grab the
  name and its run-failed logs:

  ```bash
  gh pr checks {pr_number} --json name,state,conclusion,link \
    | jq '[.[] | select(.conclusion == "failure")]'
  gh run view {run_id} --log-failed 2>&1 | tail -200   # one per failing check
  ```

- **Stage the `ci-fixer` harness**, then **Invoke the `Workflow` tool** on the
  `path=` it prints — **already opted in**, like every harness call this skill
  mandates (`ship-protocol.md` § *Workflow authority*, #637). Same staging
  requirement and same reason as the review harness (#973):

  ```bash
  <skill-base-dir>/../../scripts/harness-stage.sh stage ci-fixer
  # -> path=…  source=…  staged=true|false
  ```

  Run bare, read `path=`, never `eval "$(…)"` (#815). Pass it as `scriptPath`,
  passing
  `args: { checks: [{ name, logs, pr: {pr_number} }, …] }`. The harness runs
  a capped `parse → fix → verify` loop per check and returns
  `{ results: [{ check, fixed, summary, files_changed, remainingFailures, … }] }`.
  **Bound this invocation in wall-time** exactly as the pre-PR review does
  (`pre-ship-validation.md` Step 3.5 b, `LIBRARIAN_WORKFLOW_WALL_TIMEOUT`): the
  `ci-fixer` harness is budget-bounded but not wall-clock-bounded, and a stuck
  fixer agent would otherwise hang the ship (#224). Invoke it as a background
  task — **register it** with `golem-work.sh` (`register workflow`/`complete`;
  runnable recipe in `golem/background-work.md`), since a backgrounded harness is
  the shape #890 measured as a false idle — and, at each poll, **call**
  `${CLAUDE_PLUGIN_ROOT}/scripts/workflow-wall-timeout.sh check --elapsed-min
  <acc> --level {N} --extensions-used <k>` for the stop `verdict` rather than
  re-deriving the threshold in prose (#327) — on `stop`, `TaskStop` it. Treat a
  stopped run as **no fix applied** for any check whose result never arrived
  (those `check`s stay red → the dead-end path below), and record a `timed_out`
  STOP note. Agents never push — applying the commits is your job:

  - For each result with `fixed: true`: stage its `files_changed`, then make
    one commit `fix(ci): {summary}` (combine multiple fixed checks into a
    single commit when convenient), `git push`, and go back to (a) to
    re-check CI. **Before staging, hard-filter `files_changed` against the
    CI-config denylist** — drop any path matching `.github/workflows/`,
    `.gitlab-ci.yml`, `.github/actions/`, or `*/action.yml`. The `ci-fixer`
    agent is instructed not to touch CI config, but it has tree-wide edit
    access, so enforce it here rather than trusting the guardrail: if a
    result's `files_changed` contains a denylisted path, do NOT stage that
    path, and surface it to the user (autonomous: record as a STOP note in
    the completion summary) as "ci-fixer attempted a CI-config edit
    ({path}) — skipped; manual review required." Never let an automated CI
    fix rewrite the CI definition that gates it.
  - For each result with `fixed: false`: red CI that `ci-fixer` cannot resolve
    is a **dead-end** — the merge invariant forbids merging it at every level,
    L4 included, so **no path merges here**. Emit the **dead-end summary
    template** (`orchestrate/autonomy-levels.md` § *The dead-end summary
    template*) — the three sections *why it's a dead-end* (this CI check is red
    after `ci-fixer` exhausted its cap and the failure exercises the diff, not
    infra), *what was attempted* (the fix attempts + infra-flake triage already
    run, so the human does not redo them), and *options that remain* (e.g. the
    test expectation may be wrong; re-scope; ship-with-failing-CI is NOT an
    option). Surface it on the feed as a `dead-end` event so the orchestrator
    flags it distinctly (message begins `DEAD-END:`):

    ```bash
    printf '%s' '{"message":"DEAD-END: CI check {check} red after ci-fixer cap — see summary"}' \
      | <skill-base-dir>/../../hooks/golem-notify.sh
    ```

    Substitute `<skill-base-dir>` per `next-issue/worktree-safe-recipes.md`
    (#815). The feed's *reader* (the orchestrator) is in the main checkout; its
    **writer — this golem — is isolated**, so the plain spelling is refused here.

    At **L1–L2** additionally ask the user, after presenting the summary: **Fix
    manually now, or ship with failing CI (no merge)?** If fix manually, pause
    then go back to (a); if ship-as-is, push the branch and stop for a human (the
    PR is parked, not merged). At **L3–L4**: do NOT prompt — STOP with the
    dead-end summary folded into the completion summary (see "Completion summary"
    in SKILL.md). In all cases leave the PR parked with `status/pr-pending`, do
    not merge, do not leave the run in a prompting state, and **wait indefinitely
    for the human** — never lapse-and-default (`autonomy-levels.md` § *Standing
    rule*).

    `status/pr-pending` is correct **while** the PR is parked — it is exactly the
    "awaiting merge" signal. Say in the hand-off that it must come **off** once
    the PR eventually lands: the merge happens after this run has exited, so no
    step of ship is left to clean it up and the squash commit closes the issue
    with the label still attached (#654). `/workflow:golem --teardown {N}` owns
    the sweep on a golem run; a human finishing by hand runs
    `gh issue edit {N} --remove-label "status/pr-pending"`
    (GitLab: `glab issue update {N} --unlabel "status/pr-pending"`).

The harness stops on its own once the per-check cap or the shared budget is
reached, so there is no separate "after 3 attempts" step — surface any
still-failing results to the user as above.

**Graceful degradation**: If `gh pr checks` is unavailable or errors,
skip CI monitoring with a note and proceed to labeling. CI monitoring
never blocks shipping.
