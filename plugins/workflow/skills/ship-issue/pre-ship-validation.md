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

   a. Generate the file list AND the growth sidecar from the diff:

   ```bash
   git diff --name-only origin/main...HEAD > /tmp/pre-review-files.txt
   git diff --numstat   origin/main...HEAD > /tmp/pre-review-numstat.txt
   ```

   The `--numstat` sidecar is what makes the sizing scanner **growth-aware**
   (#695): it carries added/deleted counts per file, so a one-line touch to a
   pre-existing oversized file is reported as informational rather than as this
   PR's debt. Omitting it does not break the scan — sizing still runs, but with
   no growth signal every over-threshold file is reported LOW/informational, so
   the size lens silently stops finding anything actionable. Generate it.

   **`$1` is the `--name-only` list, never the diff itself.** The two commands
   above differ by one flag and both write to `/tmp`, so handing the diff to
   `$1` is an easy slip — and it used to be a silent one: every diff line was
   read as a path, matched nothing, and the scan exited 0 with no output,
   indistinguishable from a clean result on a pre-ship gate (#809 recorded
   exactly that false "clean"). The scanner now refuses a diff loudly (#816),
   and warns when nothing in a non-empty list resolves. If you see either
   message, fix the input and re-run — do not read the refusal as a pass.

   b. Run the pre-review scanner (locate `pre-review-gates.sh` in the same
   directory as the skill file):

   ```bash
   bash pre-review-gates.sh /tmp/pre-review-files.txt /tmp/pre-review-numstat.txt
   ```

   c. Parse TSV output — each line: `file\tline\tcategory\tevidence\tcertainty`

   **Categories detected:**

   | Category              | What it catches                                   | Certainty    |
   | --------------------- | ------------------------------------------------- | ------------ |
   | `ai-slop`             | Hedging phrases, buzzword inflation, filler text  | HIGH         |
   | `debug-statement`     | print(), console.log, debugger, breakpoint        | HIGH         |
   | `missing-test-file`   | Source files with no corresponding test file      | HIGH         |
   | `untested-public-api` | Public functions not referenced in any test file  | HIGH         |
   | `file-length`         | Production LOC over the **review-lens** threshold | HIGH/MED/LOW |
   | `ai-file-bloat`       | An agent/skill/companion/CLAUDE.md/memory file over its per-type budget | HIGH/MED/LOW |
   | `doc-file-bloat`      | A `docs/*.md` page over its per-type budget       | HIGH/MED/LOW |
   | `decomposition-seam`  | A language-shaped split shape, or a reasoned decline | MED/LOW   |
   | `hardcoded-secret` / `injection-risk` / `xss-risk` / `insecure-crypto` / `command-injection` / `insecure-deserialization` / `weak-randomness` / `tls-verification-disabled` / `permissive-cors` / `jwt-unverified` / `xxe-risk` | The `check-security` detectors (#708), delegated at runtime | HIGH |
   | `security-scan-unavailable` | The security scan DID NOT RUN — never a clean result | HIGH |
   | `okf-*` (missing-type, unparseable-frontmatter, reserved-file-structure, version-drift) / `memory-*` (orphan, dangling-index, multi-index, stale, missing-why) | Memory-bundle schema floor + graph health, from `check-okf-conformance` (#699), delegated at runtime | HIGH/MED/LOW |

   The two `*-bloat` rows are the **prose** half of the size lens (#724). A
   markdown file the scanner can classify by path — an `agents/*.md`, a
   `SKILL.md`, a skill companion, a `CLAUDE.md`, a memory index/concept, a
   `docs/*.md` — is sized against its own budget from
   `check-decomposition/thresholds.yml` § `bloat_thresholds` (the same table the
   audit lens reads, measured on **total lines** because these files load whole
   into context) and gets **exactly one** size verdict: a bloat row *instead of*
   `file-length`, never both. Unclassified markdown keeps the production-LOC
   path. Certainty is growth-graded exactly like `file-length`, so a one-line
   touch to a pre-existing over-budget agent file stays `LOW`.

   **Verifying a split mechanically.** When a diff *performs* a decomposition —
   a file shrank sharply and siblings appeared, or prose moved into new linked
   docs — `split-verify.sh` proves it lost nothing, rather than leaving a
   reviewer to eyeball it:

   ```bash
   WORK=$(mktemp -d)
   git show origin/main:path/to/file.md > "$WORK/before.md"
   bash split-verify.sh "$WORK/before.md" path/to/file.md path/to/detail.md
   ```

   `mktemp -d`, not a fixed `/tmp` name: a predictable path in a world-writable
   directory is a symlink race, and `split-verify.sh` itself uses `mktemp` for
   every scratch file it creates.

   The first argument is the **pre-split snapshot**, the second the **post-split
   original**, and the rest are the files content moved **into**. It checks
   production-LOC conservation, unit preservation, dangling callers, and — for
   markdown — that every moved heading is still reachable by a link from the
   original. A `split-verified` row means the split is provably non-lossy; the
   `split-*` rows name exactly what went missing otherwise. This is what makes a
   suggested split cheap enough to accept, so cite it in the finding rather than
   asserting the split looks fine.

   The last two come from the sizing scanner (#695) and are **growth-graded**,
   which is the whole point of the review lens: `HIGH`/`MEDIUM` means *this diff*
   pushed the file over a threshold or added materially to one already over;
   `LOW` means pre-existing size the diff barely touched. Treat a `LOW` sizing
   row as informational — never ask the author to split a file their PR merely
   brushed against. A `decomposition-seam` row reading `declined: <reason>` is a
   **result**, not a problem: it records that the file was examined and found
   legitimately long.

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

   **The security arm is the ONE exception, and it is deliberate (#708).** The
   sentence above covers this gate being absent; it does NOT cover the security
   pre-scan inside it. `check-security/patterns.sh` ships with `review-audit`,
   which installs independently of `workflow`, so the gate resolves it at
   runtime — and when it cannot, it **exits non-zero**, prints an actionable
   message naming the missing scanner and `claude plugin install
   review-audit@librarian`, and emits a `security-scan-unavailable` row. It never
   degrades to zero rows, because a security scan finding nothing *because it did
   not run* is byte-identical to a clean scan (the #538/#571 inert-gate shape).
   So: **zero security rows plus exit 0 means clean; a refusal means unknown.**
   Read the refusal as "not scanned", never as "nothing found" — and do not pipe
   this gate, which discards the exit code that carries the distinction (#854).

   **The memory arm is delegated too, but degrades QUIETLY (#699)** — an absent
   OKF scanner emits no rows and leaves the exit code alone, because a memory
   bundle is *optional*. Full rationale, the diff-scoping rule, and why the
   disposition differs from the security arm: `review-routing.md` § "Memory-bundle
   conformance rows".

   **Keep the parsed TSV for item 6 (#556).** Retain the rows as
   `[{file, line, category, evidence, certainty}]` and pass them to the review
   harness as `args.preScan` — including any auto-fixed ones, which the reviewer
   can then confirm as resolved. Without this the scan runs, its output is
   discarded, and six reviewers re-derive the same mechanical findings by
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
   adversarial review of the committed diff **before** it is pushed or merged,
   so the delivered code is review-clean regardless of how it ships.

   **The full step is `adversarial-review-step.md`** in this skill directory
   (#973) — load it and follow it. It carries the route decision, the
   `harness-stage.sh` staging recipe, the `args` contract, the multi-cycle fix
   loop, the wall-time bound, and the degradation clause.

   The artifact is the `ship-issue/workflow.js` harness, run via the `Workflow`
   tool. It is the longest check here and the only one that fans out subagents;
   do **not** attempt it from memory, and do **not** substitute a hand-rolled
   review or a single `dev-core:code-reviewer` subagent for it — that is a
   plausible-looking subset of what the harness does, and it fails silently
   (#681).
