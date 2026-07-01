# Next Issue — Pre-Ship Validation (Step 3.5)

Companion to `ship-issue/SKILL.md`, loaded for **Step 3.5**. Before
executing the chosen shipping mode (Step 4), run these safety checks. Autonomous
behavior is noted inline per check; environment variables referenced here
(`PRE_REVIEW_STRICT`, `REVIEW_MAX_CYCLES`, `REVIEW_STRICT`) are defined in
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

1. **Adversarial pre-PR review** (Option 1 only) — run a multi-dimension
   adversarial review of the changes **before** the PR is opened, so the PR's
   first impression is review-clean. This complements the deterministic
   pre-review gates above with LLM reviewers (security, correctness, tests,
   CLAUDE.md conventions, scope-drift) plus a fresh judge and gatekeeper.

   a. Compute the review scope from the diff against `main`:

   ```bash
   git fetch origin main
   git diff --name-only origin/main...HEAD   # -> files
   git diff origin/main...HEAD               # -> diff (context)
   ```

   If there are no committed changes yet (work is staged but not committed),
   stage and make the implementation commit first (Step 4 Option 1 steps 1-3),
   then compute the scope — the review needs a diff to read.

   b. **Invoke the `Workflow` tool** with the script bundled alongside this
   skill at `~/.claude/skills/ship-issue/workflow.js`, passing:

   ```text
   args: {
     phase: "pre-pr",
     cycle: 1,
     maxCycles: <REVIEW_MAX_CYCLES, default 3>,
     files: [<changed files>],
     diff: "<diff text>",
     issue: { number: {N}, title: "{title}" }
   }
   ```

   The harness fans the dimensions as one parallel barrier under a single
   token budget, re-scores certainty with a fresh judge, and returns
   `{ blocking[], deferrable[], summary, budget_exhausted, clean }`. The review
   agents are **read-only** — applying fixes and filing deferrals is this
   skill's job (below).

   c. **Resolve the blocking findings**: for each finding in `blocking`, make
   the fix in the working tree, then amend or add a commit. Re-run step (b)
   (incrementing `cycle`) until `clean` is true or `cycle` exceeds
   `REVIEW_MAX_CYCLES`. When `REVIEW_STRICT=true`, also treat MEDIUM-certainty
   findings as blocking.

   d. **Collect the deferrables**: keep the `deferrable` list for filing
   **after** the PR exists (so the filed issues can link the PR) — see Option 1
   "File deferred review findings".

   e. **Cap / budget exhaustion**: `REVIEW_MAX_CYCLES` (default 3) is the
   review action's threshold — the cut-short/extend checkpoint for review, the
   analogue of `LIBRARIAN_CI_WAIT_TIMEOUT` for the CI-wait loop. If `cycle`
   exceeds `REVIEW_MAX_CYCLES` or `budget_exhausted` is true with blocking
   findings still open:

   - **Interactive**: ask — **Fix remaining blocking findings now, ship anyway,
     or defer them?** (cut short the review vs. extend it by raising
     `REVIEW_MAX_CYCLES`).
   - **Autonomous**: do NOT prompt. Proceed to open the PR, but record the
     remaining blocking findings as a STOP note for the completion summary
     (Option 1 "Autonomous completion summary" → "Review status").

   **Graceful degradation**: if the `Workflow` tool or
   `~/.claude/skills/ship-issue/workflow.js` is unavailable, skip this
   step with a note: "Adversarial pre-PR review skipped (harness not
   available)." Never block shipping due to harness errors.
