# Disposition-policy recall tally — issue #613

Running measurement for
[#613](https://github.com/joshjhall/librarian/issues/613)
("verify the new disposition policy's recall"). Follow-up to
[#580](https://github.com/joshjhall/librarian/issues/580), which replaced an
unsatisfiable prose policy with the `dispositionOf` rule list.

**Status: OPEN — accumulating.** The instrument and method landed with the PR
that created this file; the tally itself is **not complete** and carries **no
verdict yet**. See § Status for the count and § Verdict for what is still
missing. Adding rows over subsequent review cycles is the remaining work on the
issue.

## What is being measured, and why

`dispositionOf` is proven correct offline — totality, rule order, reachability,
and a mutation-checked calibration gate in `tests/workflow-helpers/ship-issue.mjs`.
What is **not** proven is recall in production, because the policy keys off a
`nature` value the judge supplies and nothing validates that value.

A finding characterized `improvement` when it is really `defect-in-new-code`
lands in the deferrable bucket with **no error and no signal**. The old failure
was an *unsatisfiable policy*; the candidate new failure is a *systematic miscall
of `nature`*. Both look identical from outside: a healthy-looking `blocking: []`.

The offline gate cannot catch this — it feeds `dispositionOf` fixture natures
directly, bypassing the judge. Only live data shows whether the judge assigns
`nature` sensibly. And #580's defect went unnoticed for 26 cycles precisely
because no one was counting.

## Method

One row per **review cycle** (not per issue — a re-review cycle gets its own
row), same shape as the #567 batch it follows.

Every cycle's harness result reports both distributions directly, so no row is
hand-derived:

```bash
jq '{cycle, by_nature: .summary.by_nature, by_rule: .summary.by_rule,
     total: .summary.total_findings, blocking: .summary.by_disposition.blocking}' \
  "$cycle_result_json"
```

`ci-review-protocol.md` step (d) directs the loop to append a row at the point
the standing-rule read already happens.

### The four measures

| Measure | Source | What an unhealthy value looks like |
| --- | --- | --- |
| `nature` distribution | `summary.by_nature` | `improvement` dominating a diff full of new code |
| blocking rate | `summary.by_disposition` | ~1.5% was the #580 bug; ~100% dead-ends every cycle at the cap |
| `disposition_rule` distribution | `summary.by_rule` | a rule that never fires is dead or mis-ordered |
| **deferred-defect check** | manual read | a `yes` — the deferrable bucket held a real new-code defect |

The fourth is the one that matters and the only one no aggregate can answer. A
systematic `nature` miscall produces perfectly healthy-looking counts; the check
is the same manual read that caught all six misses in the #567 batch.

Both distributions pre-seed every key at zero, so "never fired" is
distinguishable from "not measured". `sum(by_nature)` may be **less than**
`total_findings` — that gap means the judge did not characterize every finding
(an omitted `ref`, or a null-judge cycle), and is itself worth noticing rather
than smoothing over.

## Status

**Cycles tallied: 4 of ~10.** The instrument landed with this file, so the first
rows are the review cycles of the PR that introduced it — which also means they
are not a neutral sample (see § Reading these four rows together).

| # | issue | tier | files | +/- | cycle | total | blocking | `by_nature` | `by_rule` | deferred defect? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 613 | small code+test+docs | 4 | +366/-10 | 1 | 3 | 0 | improvement 3 | R2 1, R4 2 | **no** — 3 real improvements, all fixed anyway |
| 1 | 613 | (re-review) | 4 delta | +242 delta | 2 | 1 | 0 | improvement 1 | R4 1 | **no** — a real, self-documented coverage gap |
| 2 | 613 | (re-review, narrow) | 1 delta | +61 delta | 3 | 0 | 0 | (none) | (none) | n/a — zero findings, `C3` uninformative |
| 3 | 613 | (re-review, FULL) | 5 | +647 full | 4 | 1 | 0 | improvement 1 | R4 1 | **no** — but see below |

### Row 0 notes

The instrument's first live run, on its own PR — which is also the first evidence
it works: `by_nature` and `by_rule` came back populated and internally consistent
(`R2 1 + R4 2 = 3 = total_findings`, and `sum(by_nature) == total_findings`, so
the judge characterized every finding).

`blocking: []` with `clean: true`, and per the standing rule all three
deferrables were read on merit anyway. **None was a defect in new code** — the
deferred-defect check is a genuine `no`, not a miss:

1. `tallyBy` used a plain `{}` accumulator with LLM-supplied keys. Judged
   `improvement` at LOW certainty (0.2) and framed as prototype pollution.
   Confirmed real on a different axis than the finding argued: on `{}` a
   `__proto__` value is **silently swallowed** by the inherited setter (no own
   key, no count, no error) and `constructor` string-concatenates into
   `"function Object() { [native code] }1"`. That is data loss in a counting
   function. Fixed with `Object.create(null)`.
2. The live composition of `by_nature`/`by_rule` was untested — it sat past
   `ORCH_BOUNDARY` where `extractHelpers` cannot reach. Extracted to
   `summarizeJudgeObservations` and unit-tested. A residual gap remains and is
   documented at the test site rather than implied away.
3. This file's name did not match the documented `<skill>-e2e-<issue>.md`
   pattern. It genuinely is a running tally rather than an e2e report, so
   `CLAUDE.md` now documents both artifact shapes.

**One row proves nothing about recall** — a `no` on a diff this size is the
expected outcome, and finding 1 in particular is the kind an `improvement` call
fits reasonably well. Recorded as a baseline, not as evidence.

### Row 1 notes

The re-review of the cycle-1 fix commit. One finding, `improvement` at **HIGH**
0.85: the `...summarizeJudgeObservations(rawFindings)` spread on the live return
path is past `ORCH_BOUNDARY` and has no automated coverage — replacing it with
`tallyBy([], …)` leaves the suite green.

Correctly characterized. It is a real gap and the certainty is well-calibrated,
but it is not a defect in shipped behavior, and the fix it asks for needs a way
to unit-test past `ORCH_BOUNDARY` that the harness does not have. The actionable
half — do not let the volume of nearby tests imply coverage that is absent — was
taken: it is now disclosed in the PR body.

Worth noting for calibration: this is the first row where `nature` was assigned
to a finding the author had **already self-documented** as a known gap, and the
judge still called it `improvement` rather than `incomplete-work`. That is the
right call (the PR does what it claims; the gap is a limitation, not an
unaddressed AC), and it is a small point of evidence that the boundary between
those two natures is being drawn sensibly.

### Row 2 notes

Zero findings on a 61-line delta against the previous cycle's 242 — under the
50% comparability ratio, so `review-convergence.sh` returned
`continue` / `C3-narrow-zero` and the loop did **not** terminate. Reading this
zero as convergence would have been the #568 mistake exactly. Recorded for
completeness; it contributes nothing to the recall question, which is the point
of the `C3` rule.

### Row 3 notes — the most informative row so far

The deliberate full-diff re-read that `C3` forced. It found something the three
narrower cycles had not: the pre-existing `dispositionOf` totality/reachability
grid in `tests/workflow-helpers/ship-issue.mjs` kept its own hand-maintained
`NATURES`/`RULES` arrays, never cross-checked against the `NATURE_VALUES` /
`DISPOSITION_RULES` constants this very PR introduced to prevent that class of
desync. Judged `improvement`, MEDIUM 0.55.

**Two things make this row worth more than its `improvement` label.**

First, on the deferred-defect check it is a defensible `no` but the closest call
in the batch. The duplicate lists are not *wrong* today — they are identical to
the exports — so nothing is currently miscomputed, which is what keeps it out of
`defect-in-new-code`. But the defect it enables is real and latent: add a ninth
rule, update the exports, miss the copy, and the reachability grid keeps passing
over a stale set while the tally already counts the new key. Judging it
`improvement` is right on the letter of the definition ("not as nice as it could
be" rather than "wrong"). It is also the first row where a reasonable reviewer
could have argued the other way.

Second, it is an instance of a documented recurring failure in this repo —
harden one knob and leave a sibling unguarded. The PR added the constants
precisely to stop schema/policy/tally drift, asserted that property for the
schema, and did not notice an existing third copy two hundred lines down in the
file it was already editing.

Fixed by pointing the grid at the exported constants, which removes the
duplication rather than asserting it away — there is no second list left to drift.
Verified non-tautological: adding a ninth rule to `DISPOSITION_RULES` alone fails
three assertions, including the reachability grid, so the grid did not become
self-referential.

### Reading these four rows together

All four cycles: `blocking: []`, `clean: true`, deferred-defect check `no`.
Taken at face value that is a **0% blocking rate over 5 findings** — but five
findings on one small PR is far too thin to say anything about the rate, and
every one was a genuine `improvement`, which is exactly what `R4` exists to
defer. Nothing here yet distinguishes "the policy is well-calibrated" from "this
diff happened not to contain a new-code defect for it to miss."

The `by_rule` distribution is already showing its intended value, though: across
5 findings only **`R2` (1) and `R4` (4)** ever fired. Six of eight rules have
never fired. That is expected this early and is not yet evidence of a dead rule —
but it is exactly the observation #613 wanted countable, and it was not
countable at all before this PR.

What these rows *do* establish is that the instrument works end to end: every
cycle returned populated, internally consistent distributions
(`sum(by_rule) == sum(by_nature) == total_findings` throughout), which is the
first thing the measurement needed.

**A caveat about this batch specifically.** These four cycles reviewed the PR
that *built* the instrument, so they are not a neutral sample: the reviewers were
handed a conventions digest saying the partial delivery was by design, which
correctly suppressed spurious `incomplete-work` calls but also means this batch
cannot speak to how `incomplete-work` is assigned in the general case. Rows from
unrelated issues are needed before the `nature` distribution means much.

## Verdict

**Not yet reached — deliberately.** Both ACs the verdict depends on are open:

- **Is the blocking rate plausible?** Needs enough rows to distinguish a rate
  from noise. Neither extreme is healthy, and a handful of cycles cannot separate
  "blocking fires appropriately" from "this batch happened to be clean".
- **Did any cycle defer a confirmed new-code defect?** One `yes` is the signal;
  a short run of `no` is not yet evidence of good recall.

A verdict from two or three rows would be exactly the error #613 was filed to
correct — reasoning where measurement was called for. Two cautions carried
forward from the #567 notes, both of which cost that batch time:

- **Zero-finding trivial cycles are not evidence.** A comment-only diff *should*
  find nothing. Recall gets tested on medium-tier diffs and on re-review cycles
  over fix commits.
- **A fix commit invalidates the prior cycle's clean read.** In the #567 batch a
  cycle-1 `blocking: []` was followed by a real defect *introduced by the cycle-1
  fix*. Each cycle is its own row for this reason.

## What happens when the tally completes

Per AC 3, if `nature` turns out to be systematically miscalled, the follow-up is
on the judge prompt (`judgePrompt` in
`plugins/workflow/skills/ship-issue/workflow.js`, where the four definitions
live) or on validating `nature` against the changed-file list — the judge already
receives that list, so the check is available without new plumbing.

That follow-up is **not** filed in advance. Which of the two it should be depends
on what the data shows, and filing it now would be guessing at a finding the
measurement has not made.

## Backstop while this runs

The standing rule #580 documented — **`blocking: []` is not a merge signal** —
holds regardless of what this measurement finds. It is stated at
`ci-review-protocol.md` step (d) and is what protects the merge gate while recall
is still unverified.
