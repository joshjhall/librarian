# Next Issue — CI Monitor & Review Protocol

Companion to `ship-issue/SKILL.md`, loaded for the **Option 1 (Branch + PR)**
post-creation steps: CI monitoring + failure triage, the multi-cycle PR review
loop, and filing deferred review findings. These steps run after the PR is
created (and after the auto-merge fast path is NOT taken). Environment variables
(`LIBRARIAN_CI_WAIT_TIMEOUT`, `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS`,
`LIBRARIAN_CI_INFRA_STEPS`, `LIBRARIAN_CI_INFRA_RETRIES`, `REVIEW_MAX_CYCLES`,
`REVIEW_STRICT`) are defined in `ship-protocol.md` § Environment Variables.

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

Run the loop with `cycle = 1` and `cap = REVIEW_MAX_CYCLES` (default 3):

a. **Gather the changed scope** (now includes any CI fixes):

```bash
git diff --name-only origin/main...HEAD   # -> files
git diff origin/main...HEAD               # -> diff
```

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
  files: [<changed files>],
  diff: "<diff text>",
  prComments: [<normalized comments>],
  issue: { number: {N}, title: "{title}" }
}
```

`diff` is the **authoritative bytes the reviewers read** (byte-faithful
`git diff` from step a) — the manifest step no longer transcribes it, so pass the
full diff here (#267). Omitting `diff` is supported but makes each reviewer derive
it in-agent (`git diff origin/main...HEAD`), which costs extra tool calls; prefer
supplying it.

It returns `{ blocking[], deferrable[], comments_addressed[], summary,
budget_exhausted, dimensions_skipped[], clean }`. `dimensions_skipped` names any
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
  in the working tree and stage. When `REVIEW_STRICT=true`, MEDIUM-certainty
  findings are blocking too.
- For each `deferrable` finding (and any comment triaged `deferrable`): file
  it via "File deferred review findings" below, then reply to the
  originating PR review comment (if any) with the new issue link so the
  comment is **resolved-or-deferred**, not dropped.

e. **If any fixes were applied this cycle**: commit
`fix(review): address cycle {cycle} findings`, `git push`, and re-run the
CI-monitor sub-step above (wait for green, auto-fix via `ci-fixer`).

f. **Terminate the loop — green + clean** when ALL of the following hold:

- `clean` is true (no blocking findings remain), **and**
- CI is green, **and**
- every PR comment is resolved-or-deferred (none left unaddressed), **and**
- `budget_exhausted` is false — the cycle was **complete** (no dimension in
  `dimensions_skipped`).

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

Otherwise `cycle++`; if `cycle` exceeds `cap`, the PR is **not** green + clean —
this is a **dead-end** (`orchestrate/autonomy-levels.md` § dead-end rule; #181).
**STOP at every level, L4 included** — the merge invariant forbids merging an
unclean PR, so there is nothing safe to auto-decide. Emit the **dead-end summary
template** (`orchestrate/autonomy-levels.md` § *The dead-end summary template*):
*why it's a dead-end* (review still has blocking findings after `cap` cycles, so
"review is clean" cannot be met), *what was attempted* (the fixes applied across
the `cap` cycles and which findings resisted), *options that remain* (keep
fixing manually, re-scope, or defer specific findings — never merge unclean).
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

## File deferred review findings

For each deferrable finding collected in the pre-PR pass (Step 3.5 item 6) and
every loop cycle above:

- Preferred: invoke **`/file-issue`** with the finding's title, severity,
  category, and description as the seed (its auto-labeling and scope checks
  apply). In autonomous mode, pre-answer `/file-issue`'s questions from the
  finding fields so it does not prompt.
- Autonomous fallback (to avoid a nested interactive skill): create the
  issue directly with the same label taxonomy `/file-issue` uses. Pass the
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
