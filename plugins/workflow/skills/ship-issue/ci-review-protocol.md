# Next Issue — CI Monitor & Review Protocol

Companion to `ship-issue/SKILL.md`, loaded for the **Option 1 (Branch + PR)**
post-creation steps: CI monitoring + failure triage, the multi-cycle PR review
loop, and filing deferred review findings. These steps run after the PR is
created (and after the auto-merge fast path is NOT taken). Environment variables
(`LIBRARIAN_CI_WAIT_TIMEOUT`, `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS`,
`LIBRARIAN_CI_INFRA_STEPS`, `LIBRARIAN_CI_INFRA_RETRIES`, `REVIEW_MAX_CYCLES`,
`REVIEW_MAX_ATTEMPTS`) are defined in `ship-protocol.md` § Environment Variables.

## Monitor CI and remediate failures

Advisory; the `ci-fixer` Workflow harness caps fixes at 3 attempts per check.
Before labeling the issue, optionally monitor CI checks and auto-fix failures.
Ask the user:

- **Wait for CI** — monitor checks and auto-fix failures if possible
- **Skip CI monitoring** — proceed to labeling immediately

At **L3–L4**, do not prompt — ALWAYS wait for CI and auto-fix (proceed
as if the user chose "Wait for CI"). **L1–L2** asks. (The CI-wait is a routine
gate; `${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh gate routine --level {N}`
→ `disposition=auto|human` is the shared source of the L3–L4-auto cutoff, #190.)

If the user chooses to wait:

a. **Poll for check completion** against a wait threshold (so a stuck or
slow CI run never blocks indefinitely):

- GitHub: `gh pr checks {pr_number} --json name,state,conclusion`
  (poll every 30 seconds until no checks have `state: "pending"`)
- GitLab: `glab ci status` (check for completion)
- **Threshold checkpoint** — track cumulative wait time. Once it crosses
  `LIBRARIAN_CI_WAIT_TIMEOUT` minutes (default 15), do NOT keep polling
  blindly:
  - **L1–L2** (interactive): prompt — **Cut short** (stop waiting; proceed to
    labeling, noting CI was still pending) or **Extend** (wait another
    `LIBRARIAN_CI_WAIT_TIMEOUT` minutes, then re-checkpoint).
  - **L3–L4**: do NOT prompt. Auto-extend up to
    `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` times (default 2 → 45 min total), then
    **STOP** — proceed to the completion summary with a STOP note ("CI still
    pending after {total} min — not waited further"), mirroring the
    L3–L4 CI-failure STOP below. Never hang waiting on a prompt.

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
    setup/provisioning step (the env-overridable list
    `LIBRARIAN_CI_INFRA_STEPS`, default:
    `Set up Docker Buildx|Checkout|checkout|Login|login|cache|Cache|Set up job`),
    OR the failing job type cannot be affected by the PR's changed files
    (e.g. a Docker `Build` job on a docs/tests-only diff). → **auto-retry
    once**: `gh run rerun --failed`, then re-poll from (a) and re-evaluate;
    escalate only if it **re-fails**. This auto-retry is bounded by
    `LIBRARIAN_CI_INFRA_RETRIES` (default `1`) and is INDEPENDENT of — it does
    not consume or duplicate — the `ci-fixer` 3-attempt cap (that cap covers
    *code* fixes; this covers *re-running* an unchanged infra step).
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
  `ci-fixer` agent), passing
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
      | "${CLAUDE_PLUGIN_ROOT}/hooks/golem-notify.sh"
    ```

    At **L1–L2** additionally ask the user, after presenting the summary: **Fix
    manually now, or ship with failing CI (no merge)?** If fix manually, pause
    then go back to (a); if ship-as-is, push the branch and stop for a human (the
    PR is parked, not merged). At **L3–L4**: do NOT prompt — STOP with the
    dead-end summary folded into the completion summary (see "Completion summary"
    in SKILL.md). In all cases leave the PR parked with `status/pr-pending`, do
    not merge, do not leave the run in a prompting state, and **wait indefinitely
    for the human** — never lapse-and-default (`autonomy-levels.md` § *Standing
    rule*).

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
git diff --name-only origin/main...HEAD   # -> files (FULL PR scope)
git diff origin/main...HEAD               # -> diff  (FULL PR scope)
```

**Re-review narrowing (#492).** After cycle 1, also compute the **fix-commit
delta since the last cycle** so the harness can re-review only what changed
instead of re-scanning the whole PR every cycle (worst case 5× the full review
at `REVIEW_MAX_CYCLES=5`). Capture the HEAD SHA the harness actually reviewed
this cycle **at step (c) time, before step (e) commits any fixes**
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
is no prior SHA and no prior blocking set: omit all three delta args (full review).

b. **Gather open PR review comments** and normalize unresolved review-thread
comments + issue-style PR comments into a `prComments` array of
`{ id, author, path?, line?, body, url? }`:

```bash
gh pr view {pr_number} --json reviews,comments
```

**Comment `id` contract.** `gh pr view` emits `id` fields as **numbers**; the
harness compares comment ids as **strings** on both sides (`String(a) ===
String(b)`), so you may pass ids through verbatim — no caller-side stringify or
coercion is required. The harness will not silently drop a comment whose id type
differs from its triaged disposition: an unresolved comment always keeps `clean`
false regardless of numeric-vs-string origin (#261).

c. **Invoke the `Workflow` tool** with
`~/.claude/skills/ship-issue/workflow.js`, passing:

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
  // re-deriving them. Re-run pre-review-gates.sh on the current scope:
  preScan: [<pre-review-gates.sh TSV rows + lint-gate rows>],
  // Conventions digest (#557) — distilled ONCE by the caller so five reviewers
  // don't each re-read CLAUDE.md / AGENTS.md / .claude/memory:
  conventionsDigest: "<distilled project-convention rules>",
  // Re-review narrowing (#492) — omit ALL THREE on cycle 1 (full review):
  deltaFiles: [<changed files since lastReviewedSha>],
  deltaDiff: "<diff since lastReviewedSha>",
  priorBlockingDimensions: [<dimension names that blocked last cycle>]
}
```

`diff`/`files` stay the **FULL PR scope** (byte-faithful `git diff
origin/main...HEAD` from step a) — the manifest step no longer transcribes it, so
pass the full diff here (#267). They remain load-bearing on narrowed cycles too:
`scope-drift` reads the full `diff` (its acceptance-criteria-completeness check is
a whole-change lens), and `files` sizes the result summary. Omitting `diff` is
supported but makes each reviewer derive it in-agent (`git diff
origin/main...HEAD`), which costs extra tool calls; prefer supplying it.

`deltaFiles`/`deltaDiff`/`priorBlockingDimensions` (#492) carry the **fix-commit
delta** from step a. When present on `cycle > 1` the harness narrows the
delta-local dimensions (security, correctness, tests, conventions) and runs each
only if it blocked last cycle or the delta touches a file type it reviews. The
conditional specialists (database, devops) follow the same include rule with their
own "touches" signal — `manifest.needs.*` (whether the delta still classifies a
file of that type) — **plus** the prior-blocking carry-over, so
`priorBlockingDimensions` closes the AC#3 gap for specialists too. **Which diff a
re-run reads depends on why it was included:** a dimension pulled in because the
delta *touches* its types reads only the fix delta (the saving); a dimension
pulled in via the *prior-blocking* carry-over reads the **full** diff, because the
finding it must re-confirm may live outside the fix delta — handing it only the
delta would blind it and let a still-unresolved finding silently vanish. A
dimension that is both touched and prior-blocking reads the full diff
(re-confirmation wins). `scope-drift` always reads the full `diff`. Omitting the
delta args (or on the first cycle) yields the pre-#492 full review — they are
additive and default-off. A dimension the harness drops because the delta doesn't
touch it is **not** a partial cycle: narrowing never sets `budget_exhausted` /
`dimensions_skipped`, so a narrowed cycle can still return `clean`.

It returns `{ blocking[], deferrable[], comments_addressed[], summary,
budget_exhausted, dimensions_skipped[], no_review_signal, clean }`.
`no_review_signal` is true only when the cycle died before **any** dimension ran
(e.g. the manifest step failed) — that cycle produced no review signal and must
not be charged against `cap`, see step (f) (#616). `dimensions_skipped` names any
review dimensions that did not run this cycle (skipped at the budget floor or
failed mid-barrier); a non-empty list means `budget_exhausted` is true and the
cycle is **partial**.

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

**Record the cycle for the recall measurement** (#613). While the tally in
`docs/verification/disposition-recall-tally-613.md` is still accumulating,
append one row per cycle from the harness result — no re-derivation needed,
since the summary reports both distributions directly:

```bash
jq '{cycle, by_nature: .summary.by_nature, by_rule: .summary.by_rule,
     total: .summary.total_findings, blocking: .summary.by_disposition.blocking}' \
  "$cycle_result_json"
```

Then answer, in one line on the row, **the check the measurement actually turns
on**: *does the deferrable bucket still hold a real defect in code this PR
wrote?* That is the same manual read that caught all six misses in the #567
batch, and it is the one thing no aggregate can answer — a systematic `nature`
miscall produces a perfectly healthy-looking set of counts. You have already
done this read as part of the standing rule above; the row just records what it
found. A `yes` is the finding #613 exists to detect, and is worth surfacing
immediately rather than at the end of the batch.

e. **If any fixes were applied this cycle**: commit
`fix(review): address cycle {cycle} findings`, `git push`, and re-run the
CI-monitor sub-step above (wait for green, auto-fix via `ci-fixer`).

f. **Consult the convergence predicate** — do NOT decide "have reviewers run out
of material?" by hand, and do NOT read the cycle counter as that answer. Call the
bundled helper once per cycle, exactly as the wall-time bound is called in
`pre-ship-validation.md` step (b):

**`--delta-lines` is the surface THIS cycle reviewed — capture it in step (a),
before any fix commit.** It is the line count of the diff you fed the harness
(`deltaDiff` on a narrowed cycle, the full `diff` on cycle 1), not something to
recompute here:

```bash
# In step (a), on the SAME line count as deltaDiff just above — and note that at
# step (a) time `$lastReviewedSha` still holds the PREVIOUS cycle's SHA (step (c)
# has not yet re-captured it to this cycle's HEAD), which is precisely the
# "since the last cycle" boundary this wants:
delta_lines=$(git diff "$lastReviewedSha"...HEAD | command wc -l)   # cycle > 1
delta_lines=$(git diff origin/main...HEAD | command wc -l)          # cycle 1
```

**The timing is the whole point** — the same expression means different things at
different steps. Do **not** recompute it at step (f) time: by then step (c) has
re-captured `lastReviewedSha` to this cycle's HEAD and step (e) has committed the
fix on top, so it measures the **fix you just applied** rather than the surface
you reviewed. It breaks worst on exactly the case the predicate exists to judge: a
**clean** cycle applies no fix, so the SHA still equals `HEAD`, the diff is empty,
and `--delta-lines` is `0` — which reads as maximally narrow and fires `C3`
(continue) on a review that had genuinely converged, looping to the cap and
defeating the early-stop half of #596.

Carry the value forward as the next cycle's `--prev-delta-lines`.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/review-convergence.sh" check \
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
```

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
at **L3–L4** ship auto-merges (squash, delete-branch) then prunes; at **L1–L2**
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
  | "${CLAUDE_PLUGIN_ROOT}/hooks/golem-notify.sh"
```

At **L1–L2** (interactive): after presenting the summary, ask **Keep fixing,
ship as-is, or defer the rest?** At **L3–L4**: do NOT prompt — STOP, leave the PR
parked with `status/pr-pending`, and fold the dead-end summary into the
completion summary (Review status: stopped-with-blocking). Never merge past this
point, and **wait indefinitely for the human** — never lapse-and-default.

The cap and budget bound the loop: `workflow.js` runs one cycle per
invocation and returns partial results if its shared budget is exhausted, so
the loop always terminates.

**Graceful degradation**: if the `Workflow` tool or the harness script is
unavailable, skip this loop with a note ("Multi-cycle review skipped
(harness not available)") and proceed to labeling. Review never blocks
shipping due to harness errors.

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
