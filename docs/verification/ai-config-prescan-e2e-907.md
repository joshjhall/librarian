# ai-config pre-scan — end-to-end verification (#907)

Evidence for issue #907, "nothing enforces the biweekly convention-audit
cadence". Everything below marked **VERIFIED — live** was executed in-session on
2026-09-05 and the output is transcribed as observed. The single **DEFERRED**
item cannot be exercised before merge, for a structural reason stated below.

## What landed

A scheduled workflow running `check-ai-config`'s **deterministic pre-scan
only**, as a ratchet against a checked-in baseline:

| file                                       | role                                  |
| ------------------------------------------ | ------------------------------------- |
| `bin/ai-config-prescan.sh`                  | the mechanism (scan, diff, report)    |
| `tests/ai-config-prescan.baseline`          | the 11 known findings, deferred       |
| `.github/workflows/ai-config-prescan.yml`   | the schedule + dispatch escape hatch  |
| `tests/validate-ai-config-prescan.sh`       | behavior gate (12 cases)              |

## AC#1 — a decision is recorded on which approach

**Satisfied before implementation**, by the operator's decision comment on #907
(2026-09-05): *"a scheduled workflow running `check-ai-config`'s deterministic
pre-scan only"*. The issue **body** framed the choice as
reminder-vs-`claude -p`-vs-accept-the-gap on the premise that only an LLM can
run the sweep; the comment records that premise as incomplete and supersedes it.
The rejected alternatives and their reasons are restated in
`bin/ai-config-prescan.sh`'s header so they are not re-litigated later.

## AC#2 — equivalent coverage actually RUNS on the documented cadence

Satisfied for the **deterministic half**, which is the half a cron job can
genuinely perform. The judgment half remains an operator ritual and is
documented as such (see AC#3 and `convention-cadence.md`).

**VERIFIED — live.** Baseline state, 119 tracked `plugins/**/*.md` files:

```console
$ bash bin/ai-config-prescan.sh; echo "exit=$?"
## ai-config pre-scan (deterministic half)

Ran check-ai-config's deterministic pre-scan over 119 tracked `plugins/**/*.md` files.

- findings in tree: **11**
- new (not baselined): **0**
- baselined but now absent: **0**
...
No findings outside the baseline.
exit=0
```

The 11 are all MEDIUM `skill-frontmatter` / "No structural section found",
matching the operator's independent measurement exactly.

**VERIFIED — live. The armed failure.** A green run proves nothing on its own,
so the 12th finding was induced by stripping the level-2 (`##`) headings from
`plugins/workflow/skills/file-issue/SKILL.md` (restored immediately after):

```console
- findings in tree: **12**
- new (not baselined): **1**

### NEW findings (1) — this run FAILS

- `plugins/workflow/skills/file-issue/SKILL.md` — skill-frontmatter: No structural section found ...
exit=1
```

**VERIFIED — live. The opposite direction.** Adding a `## Workflow` heading to a
baselined file reports it as fixed and stays green (`baselined but now absent:
**1**`, `exit=0`) — the ratchet only ever tightens.

### DEFERRED — the scheduled workflow's own first run

`.github/workflows/ai-config-prescan.yml` **cannot be executed before merge**:
GitHub evaluates `schedule:` only on the repository's default branch, and
`workflow_dispatch` likewise only lists a workflow once it exists on `main`.
This is a property of the platform, not of the change.

**Recipe for whoever closes this out** — after the PR merges:

```bash
gh workflow run "ai-config pre-scan"
gh run list --workflow "ai-config pre-scan" --limit 1
gh run view <run-id> --log
```

Expect: the job named **ai-config pre-scan (deterministic half)** completes
green, and its step summary reports `findings in tree: 11` /
`new (not baselined): 0`. Append the observed output to this file and mark this
item VERIFIED. If it reports a different count, the tree has drifted since
2026-09-05 — re-baseline deliberately with
`bash bin/ai-config-prescan.sh --regen` and say why in the commit message.

## AC#3 — no workflow whose name implies a check it does not perform

**VERIFIED — live**, in four places:

1. The workflow is `name: ai-config pre-scan`; its job is
   `ai-config pre-scan (deterministic half)`. Neither says "convention audit".
2. The script's report states, in its own output: *"This job covers the
   **deterministic half only**. The LLM-judgment half of the convention sweep
   ... is not run here and remains an operator ritual"*.
3. `tests/validate-ai-config-prescan.sh::test_output_disclaims_the_judgment_half`
   asserts that sentence is present and that the output never claims the full
   sweep ran. It anchors on the full disclaimer sentence, **not** on the phrase
   "deterministic half" alone — the report heading carries that phrase too, so
   the looser assertion stayed green with the whole disclaimer deleted. A
   mutation caught it; see below.
4. `convention-cadence.md`'s opening section is **split**, not blanket-corrected:
   deterministic half enforced on a schedule, judgment half still operator-driven.

## Gate results

**VERIFIED — live.**

```console
$ bash tests/validate-ai-config-prescan.sh
Total: 12   Passed: 12   Failed: 0   Skipped: 0

$ bash tests/run-all.sh > /tmp/run.log 2>&1; echo "RUN_ALL_EXIT=$?"
RUN_ALL_EXIT=0
   -> "All test stages passed"; new stage "ai-config pre-scan ratchet behavior" (1s)
```

Targeted gates, all exit 0: `lint-shellcheck`, `lint-shell-portability`,
`lint-prose-budget`, `lint-command-refs`, `lint-action-pins` (the new workflow's
`uses:` passes the SHA-pin + version-comment format), `lint-worktree-recipes`.

## Mutation round

Nine mutations against `bin/ai-config-prescan.sh`, each run against the suite.
Reported as failing-assertion counts, not exit codes (a harness keyed on exit
code alone reads every mutation as a survivor).

| # | mutation                                       | failing assertions |
| - | ---------------------------------------------- | ------------------ |
| 1 | ratchet neutered (`NEW_FINDINGS=""`)            | 3                  |
| 2 | missing-baseline guard removed                  | 7                  |
| 3 | missing-scanner guard removed                   | 9                  |
| 4 | empty-corpus guard removed                      | 1                  |
| 5 | unknown-arg rejection removed                   | 1                  |
| 6 | baseline key includes the line number            | 6                  |
| 7 | scanner exit code ignored                       | **0 → survivor**   |
| 8 | the `cd "$REPO_ROOT"` fix reverted               | 5                  |
| 9 | disclaimer sentence deleted from output          | **0 → survivor**   |

Both survivors were real gaps, and both are now killed (**M7 → 1**, **M9 → 2**):

- **M7**: the only scanner-failure case *deleted* `patterns.sh`, which
  short-circuits on the `-f` existence guard and never reaches the exit-code
  check. Added `test_failing_scanner_fails_loud`, which leaves a scanner in
  place that exits 2 and prints nothing — the shape a broken runtime actually
  has, and the one where zero rows must not read as a clean tree.
- **M9**: described above under AC#3.

## A real bug the fixtures caught

The first run of the new suite failed 5 cases with "0 findings" against a corpus
that demonstrably had one. Cause: `bin/ai-config-prescan.sh` invoked the scanner
**without `cd`-ing to the scanned root**, so the repo-relative paths in the file
list resolved only by accident of the caller's cwd. From the repo root it looked
perfect; from anywhere else — including a sandbox — it scanned nothing, emitted
zero rows, and exited 0.

That is precisely the inert-gate failure this script exists to prevent, and the
corpus guard could not catch it: the file list was non-empty, the paths simply
did not resolve. Fixed by running the scan in a `(cd "$REPO_ROOT" && …)`
subshell; mutation **M8** confirms the suite now catches its return.

## Deliberately out of scope

- **Fixing the 11 baselined findings.** Per-skill prose work, unrelated to
  making the cadence run. The baseline records them as known-and-deferred rather
  than hiding them; `--regen` tightens the ratchet as they are fixed. Worth a
  follow-up issue.
- **Restoring per-PR conventions review.** #551 moved that coverage off the
  per-PR path deliberately; the new scanner is therefore **not** registered in
  `tests/run-all.sh` (only its behavior test is).
- **Any `claude -p` / API-credential work.** Explicitly rejected on #907.
