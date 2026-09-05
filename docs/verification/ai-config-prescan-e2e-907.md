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

## Review cycle 1 — corpus scope (the finding that mattered)

The adversarial review's top blocking finding was correct and material, and it
is worth recording because a green run had already been observed before it:

> The corpus is markdown-only, so 3 of `check-ai-config`'s 6 categories can
> never fire in the scheduled job.

**Confirmed by reading the detectors** (`patterns.py`): `check_mcp_config` gates
on `*.json`, `check_hook_safety` on `*.json`/`*.sh`, `check_harness_logic` on
`*workflow.js`, and `check_claude_md_drift` on `*/CLAUDE.md`/`*/AGENTS.md` —
which this repo keeps at the **root**, outside the scanned `plugins/`. So those
categories returned clean *by construction*, which is the same inert-gate shape
the script's own guards exist to prevent, reached through the corpus instead of
the runtime.

**Then measured before choosing a remedy**, rather than reflexively broadening.
Corpus widened to `plugins/**/*.{json,sh}` + `plugins/**/workflow.js` + the root
`CLAUDE.md`/`AGENTS.md` (192 files vs 119):

| corpus        | rows | composition                                        |
| ------------- | ---- | -------------------------------------------------- |
| markdown-only | 11   | 11 `skill-frontmatter`, all genuine                 |
| broadened     | 42   | the same 11, +25 `hook-safety`, +6 `mcp-misconfiguration` |

**All 31 additional rows are false positives**, and none is a near miss:

- `hook-safety` matches `rm -rf` on **comment lines** (16 of 25), on
  `bash-guard.sh`'s own **deny-list string literals** — the guard whose purpose
  is to block those very commands — and on teardown of the scanners' own
  `mktemp -d` sandboxes.
- `mcp-misconfiguration` flags the `$schema` key of six JSON Schema files, whose
  `http://json-schema.org/draft-07/schema#` is an opaque **identifier**, never
  fetched.
- `harness-logic` found nothing across all six `workflow.js`.

31 FPs to 0 TPs is "not at this tier". Broadening would mean baselining 31 false
rows, which trains the reader to ignore the ledger — and a ratchet is worth only
as much as the baseline someone is willing to read.

**Resolution: keep the narrow corpus, but state the narrowing** (the finding's
own second suggested branch) — in `bin/ai-config-prescan.sh`'s header with the
full measurement, and in `convention-cadence.md`, whose category list is now
marked **sched** vs **manual only** per category. The claim that each category
"is reached by both halves" was removed; it was true only for
`skill-frontmatter`/`agent-frontmatter`.

`test_corpus_is_markdown_only` pins it: a `.json` and a `.sh` carrying content
those detectors *would* flag are dropped into the fixture corpus and must
produce no findings. Widening the filter fails that case and forces a
re-measurement. Mutation **M10** (filter widened to `md|json|sh`) → 4 failing
assertions.

Two other blocking findings, both fixed: a comment claiming the scanner emits
exit 2 (both its runtimes only ever exit 0 or 1 — corrected), and the deferred
AC#2 end-to-end run (already recorded above as DEFERRED with its recipe).

Two deferrable test-coverage findings were also taken rather than filed, since
both were cheap and both closed real blind spots: the `GITHUB_STEP_SUMMARY`
write path (CI-only, previously never executed — mutation **M11** → 2) and
`--regen` bootstrap with no pre-existing baseline (mutation **M12** → 2). Suite
is now 15 cases.

## Deliberately out of scope

- **Fixing the 11 baselined findings.** Per-skill prose work, unrelated to
  making the cadence run. The baseline records them as known-and-deferred rather
  than hiding them; `--regen` tightens the ratchet as they are fixed. Worth a
  follow-up issue.
- **Restoring per-PR conventions review.** #551 moved that coverage off the
  per-PR path deliberately; the new scanner is therefore **not** registered in
  `tests/run-all.sh` (only its behavior test is).
- **Any `claude -p` / API-credential work.** Explicitly rejected on #907.
