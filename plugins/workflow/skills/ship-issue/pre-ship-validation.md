# Next Issue — Pre-Ship Validation (Step 3.5)

Companion to `ship-issue/SKILL.md`, loaded for **Step 3.5**. Before
executing the chosen shipping mode (Step 4), run these safety checks. Autonomous
behavior is noted inline per check; environment variables referenced here
(`PRE_REVIEW_STRICT`, `REVIEW_MAX_CYCLES`) are defined in
`ship-protocol.md` § Environment Variables.

1. **Run test suite** — auto-detect the project's test runner (see
   `orchestrate/merge-protocol.md` § Test Runner Detection for the detection
   order: `package.json` → `pyproject.toml` → `go.mod` → `Cargo.toml` →
   `Gemfile` → `Package.swift` → `Makefile` → `build.gradle`).

   - If tests **pass**: proceed to Step 4
   - If tests **fail**:
     - Show the failure summary to the user
     - Ask: **Fix failures now, or ship anyway?**
     - **Option 1 (Branch + PR)**: test failure is **blocking** — do NOT
       create a PR with failing tests. The user must fix first or switch to
       Option 3 (commit only)
     - **Option 2/3**: test failure is **advisory** — warn but allow commit
     - **When autonomous** (always Option 1): test failure stays **blocking**
       — never open a PR with red tests — but do NOT prompt. Attempt an
       autonomous fix in a capped loop (cap at 3 attempts), re-running tests
       each time. If still failing after the cap, STOP and emit the
       structured completion summary (see Option 1 "Autonomous completion
       summary") reporting the test failure, rather than asking
   - If **no test runner detected**: skip this check and note it in the output

1. **Verify git status** — check for untracked files that look like they
   should be staged (new source files, new test files). Warn if found.

1. **Check branch freshness** (Option 1 only) — if on a feature branch,
   check if main has advanced:

   ```bash
   git fetch origin main
   git rev-list --count HEAD..origin/main
   ```

   If count > 0, warn: "Main has {N} new commits since this branch was
   created. Consider rebasing before PR."

   When autonomous, do not prompt — branch freshness is advisory; record the
   warning as a note for the completion summary and proceed.

1. **Check for plan drift** (optional) — fetch the issue body and check for
   "Affected Files" or "Acceptance Criteria" sections. If either exists,
   run drift analysis (see `drift-detect` skill for full workflow):

   - Compare planned files from the issue against actual files from
     `git diff --name-only origin/main...HEAD`
   - Check acceptance criteria checkboxes for unaddressed items
   - **If HIGH-severity drift found**: warn and ask — "Fix drift now,
     ship anyway, or skip?"
   - **If only MEDIUM/LOW drift**: show summary, proceed automatically
   - **If no plan sections found in issue**: skip this check silently

   This check is advisory — the user can always choose to ship anyway.

   When autonomous, do not prompt — drift is advisory; record any findings as
   notes for the completion summary and proceed.

1. **Pre-review gates** (advisory by default) — run deterministic quality
   scanning on changed files to catch mechanical issues before review:

   a. Generate file list from the diff:

   ```bash
   git diff --name-only origin/main...HEAD > /tmp/pre-review-files.txt
   ```

   b. Run the pre-review scanner (locate `pre-review-gates.sh` in the same
   directory as the skill file):

   ```bash
   bash pre-review-gates.sh /tmp/pre-review-files.txt
   ```

   c. Parse TSV output — each line: `file\tline\tcategory\tevidence\tcertainty`

   **Categories detected:**

   | Category              | What it catches                                  | Certainty |
   | --------------------- | ------------------------------------------------ | --------- |
   | `ai-slop`             | Hedging phrases, buzzword inflation, filler text | HIGH      |
   | `debug-statement`     | print(), console.log, debugger, breakpoint       | HIGH      |
   | `missing-test-file`   | Source files with no corresponding test file     | HIGH      |
   | `untested-public-api` | Public functions not referenced in any test file | HIGH      |

   **Handling findings:**

   - **No findings**: proceed silently to Step 4
   - **Findings exist (advisory mode — the default)**:
     - Show a summary table: category, count, top examples
     - For HIGH certainty `ai-slop` or `debug-statement` findings: offer to
       auto-fix (remove debug lines, trim AI slop phrases) before committing
     - For `missing-test-file` / `untested-public-api`: note these in the PR
       description (Option 1) so reviewers are aware
     - Proceed to Step 4 regardless of findings
   - **Strict mode** (`PRE_REVIEW_STRICT=true` in environment):
     - HIGH certainty findings **block Option 1** (PR creation) — the user
       must fix them or explicitly choose "ship anyway"
     - Options 2/3 remain advisory (warn only)

   **PR description integration** (Option 1 only): if findings remain after
   auto-fix, append a "Pre-review findings" section to the PR body:

   ```markdown
   ## Pre-review findings

   - 2x debug-statement (src/handler.py:42, src/utils.py:18)
   - 1x missing-test-file (src/new_module.py)
   ```

   **Autonomous mode**: never prompt. Apply auto-fixes as in advisory mode and
   record any remaining findings as notes for the completion summary (and in
   the PR description as above). Pre-review stays advisory unless
   `PRE_REVIEW_STRICT=true`, in which case HIGH certainty findings still block
   Option 1 — but the run STOPS and emits the structured completion summary
   (see Option 1 "Autonomous completion summary") rather than prompting.

   **Graceful degradation**: if `pre-review-gates.sh` is not found or fails
   to execute, skip this check with a note: "Pre-review gates skipped
   (scanner not available)." Never block shipping due to scanner errors.

   **Keep the parsed TSV for item 6 (#556).** Retain the rows as
   `[{file, line, category, evidence, certainty}]` and pass them to the review
   harness as `args.preScan` — including any auto-fixed ones, which the reviewer
   can then confirm as resolved. Without this the scan runs, its output is
   discarded, and five reviewers re-derive the same mechanical findings by
   shelling out (the single largest source of duplicated work in the fan-out).
   The harness logs `pre-scan: none supplied` when the handoff is missing.

   They are passed as **candidates, not findings** — the harness prompts
   reviewers to confirm or dismiss each one. That framing is deliberate: the
   scanner is a regex matcher and cannot see cross-directory tests or project
   conventions, so it produces real false positives (#555). Never pre-file a
   pre-scan row as a confirmed review finding.

   **Also harvest the repo's lint gates into the same list (#557).** Run
   whichever of the project's own linters are available on the changed files and
   append their output as `preScan` rows with a `lint:<tool>` category:

   ```bash
   rumdl check <changed .md>            # -> lint:rumdl
   shellcheck --severity=warning <.sh>  # -> lint:shellcheck
   typos <changed files>                # -> lint:typos
   ruff check <changed .py>             # -> lint:ruff
   ```

   Measured on the baseline run, the `conventions` reviewer spent **164 of its
   207 Bash calls** hand-measuring what these tools compute — including six
   consecutive `awk` one-liners re-deriving a line-length check, then re-running
   `rumdl` and `shellcheck` itself. Supplying the results turns that into a read.
   Each tool is **optional**: if it is not installed, skip its rows silently and
   pass the rest. Never fail the ship because a linter is missing.

   **Distill a conventions digest (#557).** Read the repo-root `CLAUDE.md` /
   `AGENTS.md`, any directory-level `CLAUDE.md` covering the changed paths, and
   `.claude/memory/*.md` **once**, and pass a short rule summary (~4000 chars
   max, the harness caps it) as `args.conventionsDigest`. Without it every
   reviewer in the fan-out re-reads those files. Keep it to rules a reviewer
   could actually violate in a diff — banned/required patterns, naming, scopes,
   version pinning — not prose.

1. **Adversarial pre-PR review** (all shipping modes) — run a multi-dimension
   adversarial review of the changes **before** they are pushed/merged, so the
   delivered code is review-clean regardless of how it ships. This complements the
   deterministic pre-review gates above with LLM reviewers (security, correctness,
   tests, CLAUDE.md conventions, scope-drift) plus a fresh judge and gatekeeper.

   **Runs on Options 1, 2, and 3 alike** — the review is a property of the
   *change*, not the delivery mechanism, so a commit-only (Option 3) or
   commit-to-main (Option 2) ship must not be a way to skip it. All three modes
   commit before delivering, so a committed `git diff origin/main...HEAD` exists
   for the reviewers to read in every mode (see the ordering note in step a).

   a. Compute the review scope from the diff against `main`:

   ```bash
   git fetch origin main
   git diff --name-only origin/main...HEAD   # -> files
   git diff origin/main...HEAD               # -> diff (context)
   ```

   If there are no committed changes yet (work is staged but not committed),
   stage and make the implementation commit first (Step 4 Option 1 steps 1-3),
   then compute the scope — the review needs a diff to read.

   **Ordering by shipping mode** — commit first, review, *then* deliver:

   - **Option 1 (Branch + PR)** and **Option 3 (commit only)** — the commit is
     local and `origin/main` does not advance, so `origin/main...HEAD` stays
     non-empty; run the review at this point in Step 3.5, before the push (Option 1)
     or before finishing (Option 3).
   - **Option 2 (commit to main + push)** — commit to main first, then run this
     review **BEFORE `git push origin main`** (Step 4 Option 2's push step). Once
     pushed, `origin/main` fast-forwards to your commit and the three-dot
     `origin/main...HEAD` diff **empties**, leaving the reviewers nothing to read.
     If a blocking finding requires a fix, amend/add the commit and re-review, all
     before the push.

   b. **Invoke the `Workflow` tool** with the script bundled alongside this
   skill at `~/.claude/skills/ship-issue/workflow.js`, passing:

   > This call is **already opted in** — `/workflow:ship-issue` is a slash
   > command whose instructions direct it. See `ship-protocol.md`
   > § *Workflow authority* (#637); do not re-derive the permission question.

   ```text
   args: {
     phase: "pre-pr",
     cycle: 1,
     maxCycles: <REVIEW_MAX_CYCLES, default 5>,
     files: [<changed files, FULL scope>],
     diff: "<diff text, FULL scope>",
     issue: { number: {N}, title: "{title}" },
     tokenCeiling: <REVIEW_TOKEN_CEILING if set; OMIT otherwise (default)>,
     preScan: [<pre-review-gates.sh TSV rows + lint-gate rows from item 5>],
     conventionsDigest: "<distilled CLAUDE.md/AGENTS.md/memory rules>"
   }
   ```

   `diff` is the **authoritative bytes the reviewers read** (byte-faithful
   `git diff` from step a) — the manifest step no longer transcribes it, so pass
   the full diff here (#267). Omitting `diff` is supported but makes each reviewer
   derive it in-agent (`git diff origin/main...HEAD`), which costs extra tool
   calls; prefer supplying it. A cycle with **neither** `diff` nor `deltaDiff`
   logs a `WARNING:` at cycle start — it still reviews (each reviewer derives the
   diff), but the line is there because a **dropped** `diff` key and an
   intentionally omitted one are indistinguishable from inside the harness.

   **Unknown top-level `args` keys are rejected — the harness throws, naming the
   offending key(s) (#597).** The accepted set is exactly the keys shown in the
   blocks here and in `ci-review-protocol.md`: `phase`, `cycle`, `maxCycles`,
   `files`, `diff`, `prComments`, `issue`, `tokenCeiling`, `preScan`,
   `conventionsDigest`, `deltaDiff`, `deltaFiles`, `priorBlockingDimensions`.
   Every one is read by name with an empty-default fallback, so a mistyped key
   was previously **dropped in silence** and its input simply went missing —
   which on `diff` meant five reviewers scanning an empty diff and returning
   `clean: true`, a vacuous pass byte-identical to a real one (measured on #567,
   where an `argsFile` key dropped `diff`, `preScan` **and**
   `conventionsDigest`). Since `clean` is half the merge invariant, that would
   auto-merge at L4. A typo'd key is always a caller bug, so it fails loud at
   dispatch: read the key name out of the error, fix it, re-dispatch.

   **`tokenCeiling` is OPT-IN and OFF by default (#553) — measure before you
   arm it.** It bounds **output tokens for one cycle**, measured as a delta from
   harness start, so each cycle of a `REVIEW_MAX_CYCLES` loop gets its own full
   ceiling. When `REVIEW_TOKEN_CEILING` is unset (the default), omit the arg
   entirely and the cycle is unbounded.

   **A ceiling set below where output actually lands is worse than no ceiling.**
   Hitting it degrades the cycle exactly like budget exhaustion — remaining
   dimensions land in `dimensions_skipped`, `budget_exhausted` is set, and `clean`
   is forced false. That is correct for safety (a truncated review can never
   terminate the loop as clean) but it means the skill will `cycle++` and re-run.
   A too-low ceiling therefore does not save tokens: it spends its full budget on
   every cycle, never reaches clean, exhausts `REVIEW_MAX_CYCLES`, and **dead-ends
   the PR** for a human. Worked example from the #471/#472 run (cycle output 173k
   / 281k / 207k, terminated clean at 660k): a 150k ceiling would truncate all
   three cycles, spend 450k, and still dead-end.

   So size it from **observed** data, not a guess. Every cycle returns a
   `token_report` — `{ output_tokens, ceiling, bound, dimensions_run }` — and logs
   `cycle output: N tokens across M dimensions`, on bounded and unbounded runs
   alike. Collect that across a handful of real issues, then set
   `REVIEW_TOKEN_CEILING` comfortably **above** the observed p95 so it catches
   runaways without truncating normal reviews. If a runtime turn budget *is* armed
   it takes precedence and `tokenCeiling` is ignored.

   The `token bound:` line at cycle start says which bound is live
   (`runtime` / `caller ceiling N` / `none (default)`).

   **Re-review narrowing on cycle > 1 (#492).** Cycle 1 is a full review (no
   delta args). When step (c) below re-runs the harness after a fix, pass the
   **fix-commit delta since the last reviewed HEAD** so the harness re-reviews
   only what changed instead of re-scanning the whole diff every cycle:

   ```text
   args: {
     phase: "pre-pr",
     cycle: <cycle>,
     maxCycles: <REVIEW_MAX_CYCLES>,
     files: [<changed files, FULL scope>],     // unchanged — scope-drift + summary
     diff: "<diff text, FULL scope>",          // unchanged — scope-drift reads this
     issue: { number: {N}, title: "{title}" },
     tokenCeiling: <REVIEW_TOKEN_CEILING if set; OMIT otherwise (default)>,
     preScan: [<pre-review-gates.sh TSV rows + lint-gate rows from item 5>],
     conventionsDigest: "<distilled CLAUDE.md/AGENTS.md/memory rules>",
     deltaFiles: [<git diff --name-only lastReviewedSha...HEAD>],
     deltaDiff: "<git diff lastReviewedSha...HEAD>",
     priorBlockingDimensions: [<dimensions that blocked last cycle>]
   }
   ```

   Capture `lastReviewedSha = git rev-parse HEAD` for the diff you just reviewed
   **before** amending/adding the cycle's fix commit; the next cycle's delta is
   everything committed since it. Derive `priorBlockingDimensions` from the
   previous cycle's `blocking[]` findings' `dimension`/`category`. The full
   `files`/`diff` stay in play on narrowed cycles — `scope-drift` reads the full
   `diff` (whole-change AC-completeness lens), and a delta-local dimension
   re-included via the prior-blocking carry-over also reads the full `diff` (it
   must re-confirm a finding that may live outside the delta); only a dimension
   pulled in because the delta *touches* its file types reads `deltaDiff` (the
   saving). The delta args are additive and default-off: omit them (or on cycle 1)
   for the pre-#492 full review. Narrowing never sets `budget_exhausted` /
   `dimensions_skipped`, so a narrowed cycle can still return `clean`.

   The harness fans the dimensions as one parallel barrier under a single
   token budget, re-scores certainty and characterizes each finding with a fresh
   judge, computes each disposition from that characterization
   (`ci-review-protocol.md` § How a finding is classified), and returns
   `{ blocking[], deferrable[], summary, budget_exhausted, dimensions_skipped[],
   clean }`. `dimensions_skipped` names any dimensions that did not run this cycle
   (budget floor or mid-barrier failure); a non-empty list means the cycle is
   **partial** and `clean` is forced false. The review agents are **read-only** —
   applying fixes and filing deferrals is this skill's job (below).

   **Bound the invocation in wall-time** (#224, #327). The harness is
   budget-bounded but has **no wall-clock bound of its own** — the `workflow.js`
   sandbox bans clocks/timers, and a *spinning* reviewer agent emits no tokens so
   it never advances the token budget. So a single stuck agent can run the
   invocation unbounded (observed: a >1h pre-PR review). Bound it from here, the
   way the CI-wait loop bounds pending CI — but do **not** re-derive the
   threshold/extension arithmetic in your head. That prose-only bound is exactly
   what let three golems wedge (#327); the stop **decision** now lives in a
   bundled helper you **call** each poll, so it cannot drift:

   - Invoke the `Workflow` tool as a **background** task and poll `TaskOutput`
     with a finite per-poll timeout, accumulating elapsed wall-time (whole
     minutes). The tool result carries the run's `transcriptDir`.
   - At each poll, ask the helper what to do — pass the accumulated minutes, the
     run's autonomy level, and how many extensions it has already granted:

     ```bash
     "${CLAUDE_PLUGIN_ROOT}/scripts/workflow-wall-timeout.sh" check \
       --elapsed-min "$elapsed" --level "$level" --extensions-used "$ext"
     # -> verdict=continue|extend|stop|checkpoint
     #    ceiling_min=<hard cap>  next_deadline_min=<poll to here>  extensions_used=<K'>
     ```

     It reads `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` (default 20) and
     `LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS` (default 1 → 40 min ceiling) itself.
     Act on `verdict`: **continue** — keep polling; **extend** (L3–L4 past a
     checkpoint with headroom) — carry the returned `extensions_used` forward and
     poll to the new `next_deadline_min`; **checkpoint** (L1–L2 past a checkpoint)
     — prompt the human **cut short** (treat this cycle as partial) vs **extend**
     (wait another interval); **stop** (the ceiling, at any level incl. L4) —
     `TaskStop` the run and recover partials below.
   - On a stop (cut-short or the `stop` verdict), **recover the findings already
     produced** with
     `${CLAUDE_PLUGIN_ROOT}/scripts/recover-journal-partials.sh <transcriptDir>/journal.jsonl`
     — it prints a JSON array of the finding-shaped results collected before the
     stop (empty `[]` if none; a non-zero exit means the journal was
     missing/unreadable — fall back to "review timed out; findings not
     recoverable" rather than treating it as clean). Treat the cycle as
     **partial → `clean` forced false**, identical to `budget_exhausted`: it can
     never terminate the review loop as clean, and its recovered findings feed
     the resolve-or-defer step below. Carry a `timed_out` STOP note into the
     completion summary.

   c. **Resolve the blocking findings**: for each finding in `blocking`, make
   the fix in the working tree, then amend or add a commit. Re-run step (b)
   (incrementing `cycle`) until `clean` is true **and** the convergence predicate
   says stop, or the predicate stops at the `REVIEW_MAX_CYCLES` cap. On each
   re-run pass the fix-commit delta args
   (`deltaFiles`/`deltaDiff`/`priorBlockingDimensions`) from step (b)'s cycle > 1
   block so the re-review narrows to what the fix changed (#492).

   **Consult the predicate once per cycle** — the cycle counter is the ceiling,
   not the stop signal (#596). Same helper and same call shape the PR-side loop
   uses; the full rule list and its per-verdict composition with the merge
   invariant are documented once in `ci-review-protocol.md` § "Multi-cycle PR
   review loop" step (f), and in the script header:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/review-convergence.sh" check \
     --cycle "$cycle" --max-cycles "$cap" \
     --result "$cycle_result_json" \
     --delta-lines "$delta_lines" \
     [--prev-result "$prior_cycle_json" ...] \
     [--prev-delta-lines "$prev_delta_lines"] \
     [--delta-files "$delta_files_list"] \
     --partial "<true if budget_exhausted or wall-timed-out, else false>"
   # -> verdict=continue|stop  rule=C1-cap|…|C8-novel  reason=<slug>
   ```

   **`--delta-lines` is the surface this cycle REVIEWED**, captured when you
   compute the review scope — the line count of the diff passed to the harness
   (`deltaDiff` on a narrowed cycle, the full `diff` on cycle 1). Do **not**
   recompute it from `lastReviewedSha`...`HEAD` after making the cycle's fix
   commit: that measures the fix rather than the reviewed surface, and on a
   **clean** cycle (no fix, so `HEAD` has not moved) it is always `0`, which reads
   as maximally narrow and fires `C3` on a review that had genuinely converged.
   Carry the value forward as the next cycle's `--prev-delta-lines`.

   Pass `--partial true` on a `budget_exhausted` **or** wall-timed-out cycle: the
   predicate then refuses to converge (rule `C2`), matching the existing rule that
   a partial cycle can never read as clean. The one case that **adds** a cycle is
   `C3` — a zero-finding cycle on a delta narrower than its predecessor does not
   terminate, because a zero over a fraction of the previous surface says nothing
   about the rest (#568). Extra cycles never weaken the pre-PR gate.

   **Graceful degradation**: if the helper is missing or exits non-zero, fall
   back to the plain `cycle` vs `REVIEW_MAX_CYCLES` comparison with a one-line
   note — the same posture as a missing `workflow-wall-timeout.sh`. The loop
   stays bounded either way; it just loses the early-stop and the narrow-zero
   protection.

   > **Standing rule — `blocking: []` is not a merge signal** (#580). Read every
   > finding on merit, including the deferrables, and fix anything that is a live
   > defect in code this PR itself wrote. The disposition is a rule list over a
   > judge's characterization (`ci-review-protocol.md` § How a finding is
   > classified); a mischaracterized finding lands in the wrong bucket silently.

   d. **Collect the deferrables**: keep the `deferrable` list for filing after
   delivery. **Option 1** files them **after the PR exists** so the filed issues
   can link the PR (see Option 1 "File deferred review findings"). **Options 2/3**
   have no PR to link — file the deferrables after the commit lands (Option 2:
   after the push; Option 3: after the local commit), linking the commit SHA
   instead of a PR number.

   e. **Cap / budget exhaustion / wall-timeout**: `REVIEW_MAX_CYCLES` (default 5)
   caps the number of review **cycles**; `LIBRARIAN_WORKFLOW_WALL_TIMEOUT`
   (default 20 min, step b) caps the **wall-time of one cycle**. Both are the
   review action's thresholds — the cut-short/extend checkpoints, the analogues of
   `LIBRARIAN_CI_WAIT_TIMEOUT` for the CI-wait loop. A `budget_exhausted` cycle
   **and** a wall-timed-out cycle are both **partial regardless of their
   findings**: `clean` is false even with zero blocking findings (some dimension
   in `dimensions_skipped` never ran, or the run was stopped mid-flight), so
   neither terminates the loop as clean — it must be re-run (fresh budget) or, at
   the cap, hit the dead-end below. Never merge on a partial cycle. If `cycle`
   exceeds `REVIEW_MAX_CYCLES`, or `budget_exhausted` is true, or the cycle was
   wall-timed-out (whether or not blocking findings remain):

   - **Interactive**: ask — **Fix remaining blocking findings now, ship anyway,
     or defer them?** (cut short the review vs. extend it by raising
     `REVIEW_MAX_CYCLES`).
   - **Autonomous**: do NOT prompt. Proceed to deliver, **subject to each mode's
     review gate** — open the PR for Option 1 (it is parked, not merged, by the
     merge invariant); for Option 2 apply the **Option 2 review gate**
     (`execute-protocol.md`) — a cap-exhausted cycle with blocking findings left
     IS `stopped-with-blocking`, so it must **not** push to `main` and falls back
     to Option 3; finish the local commit for Option 3. Record the remaining
     blocking findings as a STOP note for the completion summary (Option 1
     "Autonomous completion summary" → "Review status"). Delivering is never a
     licence to bypass a gate: it means take each mode as far as its gate allows,
     then stop for a human (#637).

   **Graceful degradation — mechanical failure only (#637)**: skip this step
   **only** when the harness genuinely cannot run, which means exactly one of:
   (1) `~/.claude/skills/ship-issue/workflow.js` is **absent from disk**, or
   (2) the `Workflow` tool **errors on invocation**. Skip with the note
   "Adversarial pre-PR review skipped (harness not available)" and surface it as
   `Review status: skipped: {reason}` in the completion summary. That status
   **gates delivery in every shipping mode** (see `execute-protocol.md`): Option 1
   parks the PR instead of merging, and Option 2 must **not** push to `main` —
   it falls back to Option 3 (commit only) and stops for a human, since a push
   to `main` has no PR to park and no remedy but a revert. Never block shipping
   due to harness errors.

   Two things are **not** grounds to skip:

   - **"I believe I lack permission to call `Workflow`" is excluded.** The call
     is authorized — `/workflow:ship-issue` is a slash command whose instructions
     direct it (`ship-protocol.md` § *Workflow authority*). Permission doubt is
     not unavailability; invoke the harness.
   - **Never substitute a hand-rolled review.** If the harness is genuinely
     unavailable, record the skip and proceed to delivery. Do **not** re-implement
     the review yourself — reading the diff serially in-context is slower and
     weaker than the harness fan-out, and worse, it *reports as a review having
     run*, so the skip never surfaces. An observed run burned hours of wall time
     this way. A loud skip beats a quiet substitute.

   If only
   `workflow-wall-timeout.sh` is missing or errors (non-zero exit), do **not**
   skip the review — fall back to the inline bound (checkpoint at
   `LIBRARIAN_WORKFLOW_WALL_TIMEOUT`, auto-extend up to
   `LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS` at L3–L4, then `TaskStop`) with a
   one-line note, so a stuck agent is still bounded.
