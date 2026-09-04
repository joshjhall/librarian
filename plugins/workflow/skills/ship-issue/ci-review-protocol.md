# Next Issue — CI Monitor & Review Protocol

Companion to `ship-issue/SKILL.md`, loaded for the **Option 1 (Branch + PR)**
post-creation steps: CI monitoring + failure triage, the multi-cycle PR review
loop, and filing deferred review findings. These steps run after the PR is
created (and after the auto-merge fast path is NOT taken). Environment variables
(`LIBRARIAN_CI_WAIT_TIMEOUT`, `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS`,
`LIBRARIAN_CI_INFRA_STEPS`, `LIBRARIAN_CI_INFRA_RETRIES`, `REVIEW_MAX_CYCLES`,
`REVIEW_MAX_ATTEMPTS`) are defined in `ship-protocol.md` § Environment Variables.

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

- **Invoke the `Workflow` tool** with the script at
  `~/.claude/agents/ci-fixer/workflow.js` (it ships bundled with the
  `ci-fixer` agent) — **already opted in**, like every harness call this skill
  mandates (`ship-protocol.md` § *Workflow authority*, #637) — passing
  `args: { checks: [{ name, logs, pr: {pr_number} }, …] }`. The harness runs
  a capped `parse → fix → verify` loop per check and returns
  `{ results: [{ check, fixed, summary, files_changed, remainingFailures, … }] }`.
  **Bound this invocation in wall-time** exactly as the pre-PR review does
  (`pre-ship-validation.md` Step 3.5 b, `LIBRARIAN_WORKFLOW_WALL_TIMEOUT`): the
  `ci-fixer` harness is budget-bounded but not wall-clock-bounded, and a stuck
  fixer agent would otherwise hang the ship (#224). Invoke it as a background
  task and, at each poll, **call**
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

## Multi-cycle PR review loop (after green CI)

Re-review the PR after fixes land, because resolving one finding (or a CI fix)
can silently introduce another. Each cycle re-runs the adversarial review
harness **and** folds in open PR review comments, then resolves-or-defers
everything. This loop **always runs before any merge** — it is the "review is
clean" half of the merge invariant, and there is no path that skips it.

Run the loop with `cycle = 1`, `cap = REVIEW_MAX_CYCLES` (default 5), `attempt =
1`, and `attempt_cap = REVIEW_MAX_ATTEMPTS` (default `2 × cap`). `cycle` counts
cycles that produced a review; `attempt` counts every trip including crashed ones
— see step (f) (#616):

a. **Gather the changed scope** (now includes any CI fixes):

```bash
WORK=$(mktemp -d)                                     # not a fixed /tmp name
git diff --name-only origin/main...HEAD > "$WORK/files.txt"
git diff origin/main...HEAD > "$WORK/diff.txt"        # -> diff (FULL PR scope)
# Route this cycle (#550); pass `route` as `reviewRoute` in step (c). Feed it
# the diff size too, or the R5-max-lines ceiling can never fire:
<skill-base-dir>/../../scripts/review-route.sh check --files "$WORK/files.txt" \
  --diff-lines "$(command wc -l < "$WORK/diff.txt")" \
  --prescan-categories "<comma list of HIGH pre-scan categories, if any>"
```

**Re-review narrowing (#492) — but only when the previous cycle said to (#656).**
Narrowing re-reviews only what changed instead of re-scanning the whole PR every
cycle (worst case 5× the full review at `REVIEW_MAX_CYCLES=5`). It is **not**
applied on every cycle after the first: **narrow iff the previous cycle's
`next_scope` was `narrow`.** On cycle 1, and whenever the predecessor returned
`next_scope=full`, **omit all three delta args** and review the full diff.

> **Why this is conditional.** Narrowing and `C3-narrow-zero` (#568) compose
> badly: a narrowed cycle is narrow *by construction*, so a zero-finding result
> is under the surface ratio and `C3` withholds termination — the cycle is
> **structurally incapable of ending the loop** whatever it finds. Measured on
> PR #655: cycle 2, narrowed to 244 lines against cycle 1's 1855, cost 45k output
> tokens and could not have returned `stop`. The same shape already terminated a
> loop on a meaningless zero at the cap boundary (#635, PR #634 cycle 5:
> `C1-cap capped_over=C3-narrow-zero`). `next_scope` resolves it: a cycle with
> **blocking** findings advises `narrow` (a fix must be re-checked, so another
> cycle is coming regardless and the saving is free), while a **clean or
> deferrable-only** cycle advises `full` (the next cycle is a candidate
> terminator and must be able to converge). Do **not** re-derive that rule here —
> read `next_scope` from step (f), the same helper that owns the stop decision.

**`--delta-lines` must move WITH the scope** — they are two halves of one
statement about the surface. On a `full` cycle the surface is the whole diff, so
`--delta-lines` is the full diff's line count; passing a fix-delta count there
while reviewing the full diff re-creates the very C3 misfire this fixes, one
input earlier. See step (f), which pairs the two.

When the previous cycle advised `narrow`, compute the **fix-commit delta since
the last cycle**. Capture the HEAD SHA the harness actually reviewed this cycle
**at step (c) time, before step (e) commits any fixes**
(`git rev-parse HEAD` → `lastReviewedSha`); on the next cycle the delta is
everything committed since it — the `fix(review): …` and any `fix(ci): …` commits
from steps (e) / the CI-monitor loop:

```bash
git diff --name-only "$lastReviewedSha"...HEAD   # -> deltaFiles
git diff "$lastReviewedSha"...HEAD               # -> deltaDiff
```

Also derive `priorBlockingDimensions` — the distinct `dimension` (equivalently
`category`) values of the previous cycle's `blocking[]` findings — so a dimension
that blocked last cycle is always re-run to confirm the fix. On **cycle 1** there
is no prior SHA and no prior blocking set: omit all three delta args (full
review). Omit them equally whenever the previous cycle returned
`next_scope=full` — that is the same full-review path, reached by a different
route, and it needs no special handling beyond not passing the delta args.

b. **Gather open PR review comments** and normalize unresolved review-thread
comments + issue-style PR comments into a `prComments` array of
`{ id, author, path?, line?, body, url? }`:

```bash
gh pr view {pr_number} --json reviews,comments
```

**Comment `id` contract.** `gh pr view` emits `id` fields as **numbers**; the
harness compares comment ids as **strings** on both sides (`String(a) ===
String(b)`), so pass ids through verbatim — no caller-side stringify is needed.
The harness will not silently drop a comment whose id type differs from its
triaged disposition: an unresolved comment always keeps `clean` false regardless
of numeric-vs-string origin (#261).

c. **Invoke the `Workflow` tool** with
`~/.claude/skills/ship-issue/workflow.js` — **already opted in**
(`ship-protocol.md` § *Workflow authority*, #637) — passing:

```text
args: {
  phase: "pr-cycle",
  cycle: <cycle>,
  maxCycles: <cap>,
  files: [<changed files, FULL PR scope>],
  diff: "<diff text, FULL PR scope>",
  prComments: [<normalized comments>],
  issue: { number: {N}, title: "{title}" },
  // Token ceiling (#553) — OPT-IN, off by default. Omit unless
  // REVIEW_TOKEN_CEILING is set; size it from observed token_report data,
  // since a too-low ceiling truncates every cycle and dead-ends the PR:
  tokenCeiling: <REVIEW_TOKEN_CEILING if set; OMIT otherwise (default)>,
  // Pre-scan candidates (#556) — reviewers confirm-or-dismiss instead of
  // re-deriving them. Re-run pre-review-gates.sh on the current scope, passing
  // the `git diff --numstat` sidecar as its 2nd arg so the sizing rows stay
  // growth-graded (#695) rather than degrading to informational-only:
  preScan: [<pre-review-gates.sh TSV rows + lint-gate rows>],
  // Conventions digest (#557) — distilled ONCE by the caller so reviewers
  // don't each re-read CLAUDE.md / AGENTS.md / .claude/memory:
  conventionsDigest: "<distilled project-convention rules>",
  reviewRoute: "<route from review-route.sh; OMIT if unavailable>",
  // Re-review narrowing (#492) — omit ALL THREE unless the PREVIOUS cycle
  // advised next_scope=narrow (#656; see step a). Cycle 1 always omits them:
  deltaFiles: [<changed files since lastReviewedSha>],
  deltaDiff: "<diff since lastReviewedSha>",
  priorBlockingDimensions: [<dimension names that blocked last cycle>]
}
```

`diff`/`files` stay the **FULL PR scope** (byte-faithful `git diff
origin/main...HEAD` from step a, per #267), load-bearing on narrowed cycles too
(see below); `files` also sizes the result summary. Omitting `diff` is supported
but costs extra tool calls (`pre-ship-validation.md` Step 3.5 b). **No key has a
path/file variant — pass everything INLINE regardless of size (#722):**
`diffPath`/`argsPath` are the observed inventions; the sandbox cannot read a path.

`deltaFiles`/`deltaDiff`/`priorBlockingDimensions` (#492) carry the **fix-commit
delta** from step a, present **iff the previous cycle advised
`next_scope=narrow`** — not merely because `cycle > 1`, the pre-#656 trigger: a
cycle 3 whose predecessor returned `next_scope=full` omits them. When present the
harness narrows the delta-local dimensions (security, correctness, tests,
conventions), running each only if it blocked last cycle or the delta touches a
file type it reviews. The conditional specialists (database, devops) follow the
same include rule with their own "touches" signal — `manifest.needs.*` (whether
the delta still classifies a file of that type) — **plus** the prior-blocking
carry-over, so `priorBlockingDimensions` closes the AC#3 gap for specialists
too. **Which diff a re-run reads depends on why it was included:** a dimension
pulled in because the delta *touches* its types reads only the fix delta (the
saving); a dimension pulled in via the *prior-blocking* carry-over reads the
**full** diff, because the finding it must re-confirm may live outside the fix
delta — handing it only the delta would blind it and let a still-unresolved
finding silently vanish. A dimension that is both touched and prior-blocking
reads the full diff (re-confirmation wins). `scope-drift` always reads the full
`diff` — its AC-completeness check is a whole-change lens. Omitting the delta
args (or on cycle 1) yields the pre-#492 full review — additive, default-off.
A dimension dropped for lack of a touch — or by a `cheap`
`reviewRoute` (#550) — is **not** a partial cycle: neither narrowing nor routing
sets `budget_exhausted` / `dimensions_skipped`, so both can still return `clean`.

It returns `{ blocking[], deferrable[], comments_addressed[], summary,
budget_exhausted, dimensions_skipped[], no_review_signal, clean }`.
`no_review_signal` is true when **no dimension reported although the cycle owed
a review** — the manifest step failed before the fan-out; every dispatched
dimension failed; or the budget floor skipped every candidate *before* dispatch,
leaving nothing to run. Either way the cycle produced no review signal and must
not be charged against `cap`, see step (f) (#616). The "owed a review" half
matters: a narrowed cycle whose delta touches no dimension's types legitimately
selects nothing and is **complete**, not no-signal — it is indistinguishable
from the budget-wipeout case by dimension count alone, and only the presence of
a budget-floor skip separates them. It can also be true on a cycle that
**returned findings**: comment triage survives a budget level that already
starved the dimension fan-out, so a PR-comment finding can arrive from a cycle
in which nothing read the diff. Do not treat a non-empty `blocking`/`deferrable`
as proof a review happened. Note this is strictly narrower than
`budget_exhausted`: an ordinary partial cycle had *some* dimension report, so
its findings are real evidence and it still charges the cap via `C2-partial`;
only a total wipeout is uncharged. `dimensions_skipped` names any review
dimensions that did not run this cycle (skipped at the budget floor or failed
mid-barrier); a non-empty list means `budget_exhausted` is true and the cycle is
**partial**.

**Bound this invocation in wall-time** exactly as the pre-PR review does
(`pre-ship-validation.md` Step 3.5 b, `LIBRARIAN_WORKFLOW_WALL_TIMEOUT`): invoke
the harness as a background task and, at each poll, **call**
`${CLAUDE_PLUGIN_ROOT}/scripts/workflow-wall-timeout.sh check --elapsed-min <acc>
--level {N} --extensions-used <k>` for the stop `verdict` rather than re-deriving
the threshold in prose (#327); on `stop`, `TaskStop` it and recover partials with
`${CLAUDE_PLUGIN_ROOT}/scripts/recover-journal-partials.sh <transcriptDir>/journal.jsonl`.
A wall-timed-out cycle is **partial → `clean` forced false**, identical to
`budget_exhausted` — it never terminates the review loop as clean (#224).

d. **Resolve or defer**:

- For each `blocking` finding (and any comment triaged `blocking`): fix it
  in the working tree and stage. Each carries a `disposition_rule` naming the
  rule that decided it (see § How a finding is classified).
- For each `deferrable` finding (and any comment triaged `deferrable`): file
  it via "File deferred review findings" below, then reply to the
  originating PR review comment (if any) with the new issue link so the
  comment is **resolved-or-deferred**, not dropped.

> **Standing rule — `blocking: []` is not a merge signal** (#580). Read every
> finding on merit, including the deferrables, and fix anything that is a live
> defect in code this PR itself wrote. This holds regardless of how well the
> classifier is calibrated: it is a policy over a judge's characterization, and
> a mischaracterized finding lands in the wrong bucket without any error. It
> was filed after a 26-cycle batch in which six cycles returned `blocking: []`
> over a deferrable bucket holding a confirmed defect.

**The deferrable read is mandatory on every cycle.** Answer, explicitly: *does
the deferrable bucket still hold a real defect in code this PR wrote?* This is
the same manual read that caught all six misses in the #567 batch, and it is the
one thing no aggregate can answer — a systematic `nature` miscall produces a
perfectly healthy-looking set of counts. Fix anything it surfaces before merging.

The #613 recall measurement that this read was once tallied for is **complete**
(`docs/verification/disposition-recall-tally-613.md`): no rows are collected any
more, and nothing needs appending. Its finding is *no evidence of a systematic
`nature` miscall* — which is a reason to keep doing this read, not to stop. A
well-calibrated policy is precisely the condition under which a miscall is
hardest to notice, and the measurement's own row 6 is a cycle where reading the
bucket on merit changed the outcome.

The instrument itself is permanent: every harness result still reports
`summary.by_nature` and `summary.by_rule`, so a fresh batch can be tallied at any
time should a cycle ever raise a real suspicion about how `nature` is assigned.

e. **If any fixes were applied this cycle**: commit
`fix(review): address cycle {cycle} findings`, `git push`, and re-run the
CI-monitor sub-step above (wait for green, auto-fix via `ci-fixer`).

f. **Consult the convergence predicate** — do NOT decide "have reviewers run out
of material?" by hand, and do NOT read the cycle counter as that answer. Call the
bundled helper once per cycle, exactly as the wall-time bound is called in
`pre-ship-validation.md` step (b):

**`--delta-lines` is the surface THIS cycle reviewed — capture it in step (a),
before any fix commit.** It is the line count of the diff you fed the harness
(`deltaDiff` narrowed, the full `diff` on cycle 1), not recomputed here:

```bash
# In step (a). There `$lastReviewedSha` still holds the PREVIOUS cycle's SHA
# (step (c) has not re-captured it) — exactly the "since last cycle" boundary:
delta_lines=$(git diff "$lastReviewedSha"...HEAD | command wc -l)   # narrowed cycle
delta_lines=$(git diff origin/main...HEAD | command wc -l)          # full cycle
```

Which line applies is decided by **scope, not cycle number** (#656): the full-diff
form is used on cycle 1 **and** on any cycle the previous `next_scope` set to
`full`. Keying it off `cycle > 1` instead would hand a fix-delta line count to a
cycle that reviewed the whole diff, making a genuinely full cycle look narrow to
`C3` — the same misfire as the one below, from the other direction.

**The timing is the whole point** — the same expression means different things at
different steps. Do **not** recompute it at step (f) time: by then step (c) has
re-captured `lastReviewedSha` to this cycle's HEAD and step (e) has committed the
fix on top, so it measures the **fix you just applied** rather than the surface
you reviewed. It breaks worst on exactly the case the predicate exists to judge: a
**clean** cycle applies no fix, so the SHA still equals `HEAD`, the diff is empty,
and `--delta-lines` is `0` — which reads as maximally narrow and fires `C3`
(continue) on a review that had genuinely converged, defeating #596's early stop.

Carry the value forward as the next cycle's `--prev-delta-lines`.

```bash
# substitute <skill-base-dir>: next-issue/worktree-safe-recipes.md (#815)
<skill-base-dir>/../../scripts/review-convergence.sh check \
  --cycle "$cycle" --max-cycles "$cap" \
  --attempt "$attempt" --max-attempts "$attempt_cap" \
  --result "$cycle_result_json" \
  --delta-lines "$delta_lines" \
  [--prev-result "$prior_cycle_json" ...] \
  [--prev-delta-lines "$prev_delta_lines"] \
  [--delta-files "$delta_files_list"] \
  --partial "<true if budget_exhausted or wall-timed-out, else false>"
# -> verdict=continue|stop  rule=C0-attempt-cap|…|C8-novel  capped_over=<rule|>
#    reason=<slug>  findings=N novel=N duplicate=N refuted=N recursive=N
#    next_scope=full|narrow
```

**`next_scope` (#656)** is the scope advice for the **next** cycle, emitted on
every verdict (never empty, so never test for its presence — the same contract as
`capped_over`). Carry it forward exactly as `--prev-delta-lines` is carried: when
`verdict=continue`, it decides whether step (a) narrows. It is **advisory only** —
it changes no verdict and no rule, and the loop's termination guarantee still
rests entirely on `verdict`. Pair it with `--delta-lines`: a `full` cycle passes
the full diff's line count, a `narrow` cycle passes the fix delta's.

**Two counters, not one (#616).** `attempt` counts every trip through this loop;
`cycle` counts only the trips that **produced a review**. Increment `attempt`
unconditionally, and `cycle` only when the harness result has
`no_review_signal: false`:

```bash
attempt=$((attempt + 1))
if [ "$(jq -r '.no_review_signal // false' "$cycle_result_json")" = "true" ]; then
    : # crashed before any dimension ran — do NOT advance $cycle
else
    cycle=$((cycle + 1))
fi
```

`attempt_cap` is `REVIEW_MAX_ATTEMPTS` (default `2 × cap`). A cycle that crashed
before any dimension ran is not evidence about convergence, so charging it to
`cap` would make it indistinguishable from a substantive cycle: three infra
flakes would exhaust the cap and dead-end the PR with a summary reading "review
could not reach clean in N cycles", implying findings that were never produced.
Rule `C0b-no-signal` returns `continue` for that case and `C0-attempt-cap` — the
new absolute ceiling — is what still guarantees termination.

**`capped_over` disambiguates a `C1-cap` stop (#635).** `verdict=stop` alone
cannot distinguish `C4-zero` (reviewers found nothing on a comparable surface —
genuine convergence) from `C1-cap` (the loop ran out of budget). When
`rule=C1-cap`, `capped_over` names the rule that *would* have decided:

- `capped_over=C4-zero`/`C5`/`C6`/`C7` — the cap coincided with a real
  convergence signal. The stop is corroborated; treat it as a normal stop.
- `capped_over=C3-narrow-zero` or `C8-novel` — the loop stopped on a cycle the
  policy considers **uninformative or still-productive**. This is a budget
  artifact, not convergence. Do **not** present it as a converged review: say so
  explicitly in the completion summary, and if the PR is otherwise green + clean,
  note that the merge rests on the cycle cap rather than on a convergence signal.

The field is empty for every rule but `C1-cap`, so a caller can read it
unconditionally.

**Graceful degradation**: if `review-convergence.sh` is missing or exits
non-zero, fall back to the plain `cycle` vs `cap` comparison **plus** the
`attempt` vs `attempt_cap` one, with a one-line note — the same posture as a
missing `workflow-wall-timeout.sh`. Keep both comparisons: without the attempts
bound, a fallback that also stops charging crashed cycles would be unbounded. The
loop stays bounded either way; it only loses the early-stop, the narrow-zero
protection, and the `capped_over` disambiguation.

Write each cycle's harness result to a file so the next cycle can pass it as
`--prev-result` (repeatable — duplicate detection is against **all** earlier
cycles, not just the previous one). On cycle 1 omit `--prev-result` and
`--prev-delta-lines`.

The helper owns the decision; the loop acts on `verdict` (#596). It replaced the
bare `cycle >= cap` counter, which #567's 26-cycle batch showed is **both** too
low — #533's only `blocking` finding of the entire batch (security, 0.92) arrived
in **cycle 4**, past the old default of 3, and would have shipped — **and** too
high, since #564 was verifiably clean at cycle 1 and cycles 2–3 were pure cost.
The rule list, why each rule exists, and which observed cycle motivated it are
documented in the script header; the deciding rule comes back as `rule` so a
terminated review is attributable, and `tests/validate-review-convergence.sh`
pins the table.

**`verdict=stop` is not a merge signal.** It answers only "stop looking",
and composes with the termination test below in one direction each:

- **`stop` + green + clean** → terminate normally (below).
- **`stop` + not clean** → the **dead-end** path at the end of this step. Never
  merge an unclean PR because the predicate said reviewers were done.
- **`continue` + clean** → keep going: `cycle++` and re-run. This is rule `C3`,
  the case the issue turns on — a zero-finding cycle on a delta **narrower** than
  its predecessor says nothing about the material still unreviewed (#568 cycle 2
  returned zero across five dimensions on a test-only delta, and the next cycle
  found a 0.88-certainty real defect). Withholding termination only ever **adds**
  cycles, so it cannot weaken the merge invariant.
- **`continue` + not clean** → the ordinary `cycle++` path.

A `stop` whose `rule` is `C1-cap` is the cycle ceiling — it fires regardless of
every convergence signal, and `capped_over` tells you which one it concealed. A
`stop` whose rule is `C0-attempt-cap` is the absolute ceiling that guarantees
termination even when crashed cycles are not charging `cap`.

g. **Terminate the loop — green + clean** when ALL of the following hold:

- `clean` is true (no blocking findings remain), **and**
- CI is green, **and**
- every PR comment is resolved-or-deferred (none left unaddressed), **and**
- `budget_exhausted` is false — the cycle was **complete** (no dimension in
  `dimensions_skipped`), **and**
- the convergence predicate returned `verdict=stop` (step f) — so a `C3` narrow-
  surface zero re-runs instead of terminating.

The harness already folds the last clause into `clean` (a budget-truncated cycle
returns `clean: false` even when the dimensions that *did* run found nothing), so
`clean` alone is sufficient — but state it explicitly: a **budget-truncated
"clean" cycle does NOT terminate the loop**. A review that mostly did not run is
partial, not clean. Treat it like an unclean cycle: `cycle++` and re-run (each
invocation gets a fresh budget), and if it keeps truncating past `cap`, take the
dead-end below — **never merge on a partial review**.

This green + clean state is exactly the **merge invariant** precondition. On
reaching it, hand control back to SKILL.md Step 4's **level-aware merge gate**:
at **L3–L4** ship auto-merges (squash; branch cleanup is worktree-aware) then
prunes; at **L1–L2**
it stops for a human merge with the completion summary. The merge decision has a
**single site** (Step 4) — this loop only establishes green + clean and never
merges directly.

Otherwise `cycle++`; if the predicate returned `verdict=stop` (whether at the cap
or on a convergence signal) and the PR is **not** green + clean, this is a
**dead-end** (`orchestrate/autonomy-levels.md` § dead-end rule; #181).
**STOP at every level, L4 included** — the merge invariant forbids merging an
unclean PR, so there is nothing safe to auto-decide. Emit the **dead-end summary
template** (`orchestrate/autonomy-levels.md` § *The dead-end summary template*):
*why it's a dead-end* (review still has blocking findings after `cap` cycles, so
"review is clean" cannot be met), *what was attempted* (the fixes applied across
the `cap` cycles and which findings resisted), *options that remain* (keep
fixing manually, re-scope, or defer specific findings — never merge unclean).

**The summary MUST distinguish cycles that reviewed from attempts that did not**
(#616). "Review could not reach clean in N cycles" is a claim about findings, and
it is false if some attempts never produced one. State both counts and name the
no-signal attempts explicitly:

> Reviewed N cycles across M attempts. Attempts 2 and 4 produced **no review
> signal** (harness failed before any dimension ran) and are not evidence about
> convergence.

If the loop ended at `C0-attempt-cap`, say so plainly — that is "the harness kept
crashing", a fundamentally different dead-end from "reviewers kept finding
problems", and it points at infrastructure rather than at the code. Likewise, if
it ended at `C1-cap` with a `capped_over` of `C3-narrow-zero` or `C8-novel`, note
that the review was still productive when the budget ran out (#635).
Surface it on the feed as a `dead-end` event (message begins `DEAD-END:`):

```bash
printf '%s' '{"message":"DEAD-END: review still blocking after {cap} cycles — see summary"}' \
  | <skill-base-dir>/../../hooks/golem-notify.sh
```

At **L1–L2** (interactive): after presenting the summary, ask **Keep fixing,
ship as-is, or defer the rest?** At **L3–L4**: do NOT prompt — STOP, leave the PR
parked with `status/pr-pending`, and fold the dead-end summary into the
completion summary (Review status: stopped-with-blocking). Never merge past this
point, and **wait indefinitely for the human** — never lapse-and-default.

The cap and budget bound the loop: `workflow.js` runs one cycle per
invocation and returns partial results if its shared budget is exhausted, so
the loop always terminates.

**Graceful degradation — mechanical failure only (#637)**: skip this loop
**only** when the harness genuinely cannot run — the harness script is **absent
from disk**, or the `Workflow` tool **errors on invocation**. Skip with a note
("Multi-cycle review skipped (harness not available)"), carry it into the
completion summary as `Review status: skipped: {reason}`, and proceed to
labeling. Review never blocks shipping due to harness errors.

The same two exclusions as the pre-PR clause apply verbatim
(`pre-ship-validation.md` Step 3.5 item 6):

- **"I believe I lack permission to call `Workflow`" is excluded** — the call is
  authorized (`ship-protocol.md` § *Workflow authority*). Permission doubt is not
  unavailability.
- **Never substitute a hand-rolled review.** Record the skip and move on; do not
  re-read the PR diff serially in-context. A substitute is slower, weaker, and
  invisible — it reports as a review having run.

## How a finding is classified

The harness splits findings into `blocking` and `deferrable` in two steps. The
**judge** (one fresh agent that did not produce the findings) reports two
**observations** per finding — a re-scored `certainty`, and a `nature`:

| `nature`                     | Meaning                                                        |
| ---------------------------- | -------------------------------------------------------------- |
| `defect-in-new-code`         | A real defect in code this PR wrote or changed                 |
| `defect-in-preexisting-code` | A real defect, but in code this PR did not touch               |
| `incomplete-work`            | The PR does not do what it claims (an AC is unaddressed)       |
| `improvement`                | A valid suggestion that is not a defect (style, perf, scope)   |

`dispositionOf` in `workflow.js` then computes the disposition from those
observations plus the finding's own `severity` / `category` / `effort`, as an
**ordered first-match rule list** — the first rule that matches decides, and the
last has no condition, so the policy is total and non-overlapping:

| Rule                     | Condition                                | Disposition |
| ------------------------ | ---------------------------------------- | ----------- |
| `R1-critical`            | `severity=critical` and certainty ≠ LOW  | blocking    |
| `R2-low-certainty`       | certainty = LOW                          | deferrable  |
| `R3-security-high`       | `category=security` and certainty = HIGH | blocking    |
| `R4-improvement`         | `nature=improvement`                     | deferrable  |
| `R5-preexisting`         | `nature=defect-in-preexisting-code`      | deferrable  |
| `R6-incomplete`          | `nature=incomplete-work`                 | blocking    |
| `R7-large-effort`        | `effort=large`                           | deferrable  |
| `R8-defect-in-new-code`  | (everything else)                        | blocking    |

The deciding rule is stamped on each finding as `disposition_rule`, and the
judge's observation as `nature` (#613). Both are also aggregated per cycle into
`summary.by_nature` / `summary.by_rule`, with every key present at zero so a rule
that never fires is visible as `0` rather than absent.

`nature` is retained even though nothing downstream reads it, because
`disposition_rule` cannot be reversed into it: only `R4`/`R5`/`R6` name a nature,
while `R2` and `R8` — the two highest-volume rules — decide without reference to
one. Without the stamp the majority of findings carry no recoverable
characterization, which is what makes a **systematic miscall of `nature`** the
natural successor to the failure #580 fixed: both present as a healthy-looking
`blocking: []`, and neither raises an error.

**Severity is deliberately not the primary axis** — it appears only in the R1
carve-out. The policy this replaced gated blocking on
`severity ∈ {critical, high}` while deferring on `severity ∈ {medium, low}`; since
producers emit medium/low almost exclusively, `blocking` fired once in 67
findings across 26 cycles and the merge gate was effectively unguarded (#580).
The discriminator that the missed defects actually shared was "a live defect in
code this PR just wrote" — which is `nature`.

`tests/workflow-helpers/ship-issue.mjs` pins this table: rule order, totality,
reachability of every rule, and — the assertion that makes the gate meaningful —
that a **medium-severity, MEDIUM-certainty `defect-in-new-code` blocks**. Changing
the rule order without updating that gate fails the suite.

## File deferred review findings

For each deferrable finding collected in the pre-PR pass (Step 3.5 item 6) and
every loop cycle above:

- Preferred: invoke **`/workflow:file-issue`** with the finding's title, severity,
  category, and description as the seed (its auto-labeling and scope checks
  apply). In autonomous mode, pre-answer `/workflow:file-issue`'s questions from the
  finding fields so it does not prompt.
- Autonomous fallback (to avoid a nested interactive skill): create the
  issue directly with the same label taxonomy `/workflow:file-issue` uses. Pass the
  body via `--body-file`, **never** by interpolating `{finding.description}`
  into a `--body "..."` argument: the description is LLM-generated and may
  contain backticks, `$(...)`, quotes, or newlines that would break out of
  the quoted string and execute in the shell — and this path runs unattended
  at **L4** with no human gate. Use the **`Write` tool** to write the
  body to a temp file (so the content never passes through a shell at all),
  then reference it:

  1. `Write` the body to `/tmp/deferred-finding-{n}.md` — the finding's
     description followed by `\n\nDeferred from PR #{pr_number} (review
     finding).`
  2. Create the issue from that file:

     ```bash
     gh issue create --title "{finding.title}" \
       --body-file /tmp/deferred-finding-{n}.md \
       --label "type/{type},severity/{sev},component/{comp}"
     ```

Keep `--title` short and free of shell metacharacters (it is a finding
name); if a title could contain them, write it into the body and use a
generic title.

- After filing, link the deferred issues on the PR in one comment:

  ```bash
  gh pr comment {pr_number} --body "Deferred review findings filed: #{A}, #{B}. Addressed on this PR: {count} blocking finding(s) across {cycles} review cycle(s)."
  ```

- Append a "Review findings" section to the PR body (mirrors the
  "Pre-review findings" convention), listing fixed-on-PR vs deferred-to-#.

Nothing is silently dropped: every confirmed finding is either fixed on the
PR or filed as a linked issue.
